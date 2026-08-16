import { useCallback, useEffect, useRef, useState } from 'react'
import { useUi } from '../store'
import { play } from '../audio/cues'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'

/** How long the level-up burst runs. Must match .lvlup-word in index.css. */
const LEVEL_BURST_MS = 1500

/** The bar's travel, and the counter running beside it. */
const FILL_MS = 1400

/** The level box's 3D roll. Must match .lvl-prism.is-rolling in index.css. */
const ROLL_MS = 560

/** How long the ripple stays on screen after the roll hands over to it.
 *  Must cover .lvl-ripple.two, which is the later and longer of the pair. */
const RIPPLE_MS = 150 + 880

/** The beat between the bar reaching the end and the box rolling over.
 *  The pause is the point: an instant flip throws away the one moment the
 *  whole progression system is built to produce. */
const LEVEL_HOLD_MS = 1200

/** The blue earned figure dissolving into the grey running total.
 *  Must match the transition on `.xp-readout > *` in index.css. */
const SWAP_MS = 480

/**
 * When the award has finished MOVING, measured from the fill starting.
 *
 * Two numbers because a level-up is a different animation, not a longer one:
 * the plain case is the fill plus a beat to read it, and the level case has to
 * carry the hold, the roll, the ripple and the refill of the NEW level's bar
 * (which starts 420ms into the burst and takes another FILL_MS) before
 * anything is at rest.
 */
const SETTLE_MS = FILL_MS + 700
const SETTLE_LEVEL_MS = FILL_MS + LEVEL_HOLD_MS + 420 + FILL_MS + 180

/**
 * The whole award, end to end. Lua holds the teardown for this, so it is a
 * number both sides can point at (br_core/client/spawn.lua waits on XP_BUSY,
 * capped at 6s so a page that never says "done" cannot strand anybody).
 *
 * IT IS NOT THE COVER REPORT AND MUST NEVER BECOME IT. The verdict tells Lua
 * the screen is black off `.end-backdrop`, ~3.4s after the screen mounts, and
 * the world is dismantled on that -- not on this. Lengthening the award makes
 * the player look at a finished verdict for longer; it does not move the
 * moment the match is torn down. That separation is #124 and it is the one
 * thing in this file that is not a matter of taste.
 */
const awardTotalMs = (levelled: boolean) =>
  (levelled ? SETTLE_LEVEL_MS : SETTLE_MS) + SWAP_MS


/**
 * LEVEL AND XP.
 *
 * EVERY NUMBER IT DRAWS BELONGS TO THE SERVER. This file reads `progress` and
 * `xpAward` and renders them; it does not add the award to the profile, derive
 * a level, or work out a span. That is not a stylistic rule -- it is the fix
 * for #91 and #130, where the verdict screen did all three and produced a
 * level-up shown as 0 XP and a bar reading 3,472 / 2,450.
 *
 * The two payloads are deliberately separate. `progress` is where the bar IS,
 * pushed by MARKET_STATE on connect and by MATCH_EARNED at the end of a match.
 * `xpAward` is where it WAS, and exists only for the length of one animation --
 * which is why a reconnect restores the bar without replaying a celebration.
 *
 * THE DESIGN, in three moments:
 *
 *   1. AT REST, in the lobby. A level chip and a bar. It is the first thing
 *      on the screen because it is the answer to "what did all that playing
 *      get me", and burying that under a menu is how a progression system
 *      stops motivating anyone.
 *
 *   2. THE AWARD, after a match. The bar FILLS from where it was, with the
 *      earned amount counting up beside it. Deliberately slower than the eye
 *      expects (1.4s): the fill is the reward, and rushing it throws away the
 *      only moment the system has.
 *
 *   3. THE LEVEL UP. The bar reaches the end, holds, and then the level box
 *      ROLLS -- a prism turning downward to reveal the new number, with a
 *      ripple leaving its edge as it lands and the bar refilling underneath
 *      (owner's spec, #91, built in #106). It is the one place in the lobby
 *      that gets gold, which is otherwise reserved for a Victory Royale --
 *      levelling is the other thing worth celebrating.
 *
 *      AND ONLY WHEN THE LEVEL ACTUALLY CHANGED. Every match pays; almost none
 *      cross a boundary. A roll on an ordinary match spends the one genuinely
 *      special moment the system has on nothing, and it is the same mistake
 *      the old StagedAward made when it fabricated a level-up every time.
 *
 * The bar is a scaleX transform, not a width: this animates for a second and a
 * half and there is no reason for it to be on the layout thread.
 */

export interface ProgressData {
  level: number
  /** XP into the current level. */
  xp: number
  /** XP the current level requires. */
  needed: number
}

/** Counts a number up to a target over `ms`, straight to the DOM. */
function useCountUp(target: number, ms: number, enabled: boolean) {
  const ref = useRef<HTMLSpanElement>(null)
  useEffect(() => {
    const node = ref.current
    if (!node) return

    // IT GOES BACK TO ZERO WHEN THERE IS NOTHING TO COUNT, and that matters
    // now that this element stays mounted between awards instead of being
    // torn down with the animation (see .xp-readout -- keeping it is what lets
    // the two numbers cross-fade at all). Left alone it holds the LAST match's
    // figure: invisible, but it sets the width of the readout for the rest of
    // the session, and it is what the next award would show for the frame
    // before its first tick lands.
    if (!enabled) {
      node.textContent = '+0 XP'
      return
    }
    let raf = 0
    const t0 = performance.now()
    const tick = (now: number) => {
      const k = Math.min(1, (now - t0) / ms)
      // Ease-out: the number should decelerate into its final value rather
      // than stopping dead, which reads as the counter being cut off.
      const eased = 1 - Math.pow(1 - k, 3)
      node.textContent = `+${Math.round(target * eased).toLocaleString()} XP`
      if (k < 1) raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [target, ms, enabled])
  return ref
}

/**
 * The resting readout: level, bar, and how far to the next one.
 *
 * `award` turns it into the post-match moment. Passing it re-runs the fill
 * from the PREVIOUS value, which is why the component takes the award rather
 * than the caller pre-adding it.
 */
/**
 * The spark field, authored once at module scope.
 *
 * FIXED, NOT RANDOM. Randomising per mount would make the effect different
 * every match for no gain, and `Math.random()` in a render is a re-render
 * hazard. Twelve directions weighted forward and slightly up -- sparks thrown
 * off a moving edge go the way the edge is going -- with varied durations and
 * delays so they never pulse in unison.
 */
const SPARKS = Array.from({ length: 12 }, (_, i) => {
  // Fan from roughly -55deg to +40deg, biased forward (positive x).
  const a = (-55 + (i * 95) / 11) * (Math.PI / 180)
  const reach = 0.55 + (i % 4) * 0.18
  return {
    x: `${(Math.cos(a) * reach).toFixed(2)}rem`,
    y: `${(Math.sin(a) * reach * 0.8).toFixed(2)}rem`,
    delay: `${(i * 53) % 620}ms`,
    dur: `${560 + (i % 5) * 70}ms`,
  }
})

export default function Progress({
  compact = false,
}: { compact?: boolean }) {
  const p = useUi((s) => s.progress)
  const award = useUi((s) => s.xpAward)
  const clearAward = useUi((s) => s.clearXpAward)

  // Where the bar starts the animation from. With no award this is simply
  // where it is; with one, it is where it WAS.
  const [filled, setFilled] = useState(p.xp / Math.max(1, p.needed))
  const [levelling, setLevelling] = useState(false)

  // THE THREE BEATS OF A LEVEL-UP, each one its own flag because each one is
  // driven by a different thing finishing.
  //
  //   rolling   the box is mid-roll. Ends on the roll's own animationend.
  //   rippling  the ring leaving the box, which the roll HANDS OVER to.
  //   settled   the blue earned figure has said what it had to say, and the
  //             grey running total takes the slot back.
  const [rolling, setRolling] = useState(false)
  const [rippling, setRippling] = useState(false)
  const [settled, setSettled] = useState(false)

  // The number on the FRONT face of the chip. During a roll the back face
  // carries the new one; this becomes it the instant the roll lands, in the
  // same commit that takes the rotation away, so the two states show the same
  // digits and the handover is invisible.
  const shown = useRef(p.level)

  const counter = useCountUp(award?.xp ?? 0, FILL_MS, award != null)

  const fillRef = useRef<HTMLDivElement>(null)
  const emitterRef = useRef<HTMLDivElement>(null)

  // THE EMITTER FOLLOWS THE REAL EDGE, measured every frame.
  //
  // The fill moves under a CSS transition, so its leading edge is a value only
  // the compositor knows -- there is no way to hand it to a sibling in CSS,
  // and computing it from the target percentage would put the sparks where
  // the bar is GOING rather than where it is. getBoundingClientRect on the
  // fill is the actual answer, and it costs one read per frame for the ~1.4s
  // an award lasts.
  useEffect(() => {
    if (!award) return
    let raf = 0
    const tick = () => {
      const fill = fillRef.current
      const em = emitterRef.current
      if (fill && em) {
        em.style.transform = `translate3d(${fill.getBoundingClientRect().width}px, 0, 0)`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [award])

  // What the roll is rolling TO, remembered when it starts rather than read
  // when it ends: the level that was correct at the moment the box began to
  // turn is the level that must be on the face when it stops, whatever the
  // store does in between.
  const rollTo = useRef(0)
  const rollingRef = useRef(false)

  // THE ROLL HANDS OVER TO THE RIPPLE, and it hands over on its own event.
  //
  // #106: "Chaining on `animationend` is more reliable than a hardcoded delay,
  // because the roll's duration will get tuned and a magic number will silently
  // desynchronise." So this is called BY the animation ending, not by a clock.
  //
  // It is idempotent, and it has a timer behind it, for the reason bridge/
  // cover.ts spells out at length: a browser is allowed to skip an animation it
  // considers unnecessary and then no `animationend` ever fires. Without the
  // net the chip would sit rolled through the rest of the teardown showing the
  // OLD level -- a level-up whose last act is to display the level you had
  // before it. The flag lives in a ref as well as in state because the timer
  // that backs this up is scheduled BEFORE the roll begins, so a closure over
  // the render's `rolling` would always read false and give up.
  const landRoll = useCallback(() => {
    if (!rollingRef.current) return
    rollingRef.current = false
    shown.current = rollTo.current
    setRolling(false)
    setRippling(true)
  }, [])

  useEffect(() => {
    if (!award) {
      setFilled(p.xp / Math.max(1, p.needed))
      shown.current = p.level
      // NO AWARD MEANS NOTHING IS MID-CELEBRATION, and saying so here is what
      // makes the level moment impossible to strand.
      //
      // The roll is landed by its own animationend, with a timer behind it --
      // and that timer belongs to the award's effect, so clearing the award
      // cancels it. Every normal timeline lands the roll a second and a half
      // before the award clears, but "normal timeline" is doing real work in
      // that sentence: a browser that coalesces timers under load can reorder
      // them, and the failure it produces is a chip left rotated 180 degrees
      // for the rest of the teardown. Resetting on the way out costs nothing
      // and removes the whole class.
      rollingRef.current = false
      setRolling(false)
      setRippling(false)
      setLevelling(false)
      return
    }

    // A NEW AWARD IS A NEW ANIMATION, so nothing may be left dressed for the
    // last one -- `settled` in particular, which would otherwise start this
    // award with the earned figure already faded out.
    setSettled(false)

    // Start where the player left off, then fill. The rAF below is what
    // guarantees the browser paints the starting value before the transition
    // begins -- setting both in one frame animates from nothing.
    setFilled(award.fromXp / Math.max(1, award.fromNeeded))
    shown.current = award.fromLevel

    // THE ONE TEST FOR "DID THEY LEVEL UP", and it is the server's word:
    // where the bar is now, against where the award says it started. The
    // client works nothing out (#91/#130). A player who did not cross a
    // boundary must see no roll, no ripple and no gold -- #106 is explicit
    // that spending that moment on an ordinary match is the same mistake the
    // old StagedAward made when it fabricated a level-up every single time.
    const levelled = p.level > award.fromLevel
    const timers: number[] = []

    const raf = requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        setFilled(levelled ? 1 : p.xp / Math.max(1, p.needed))
        if (levelled) {
          // Run the bar to full, hold a beat, then reset it and roll the box.
          timers.push(window.setTimeout(() => {
            setLevelling(true)
            rollTo.current = p.level
            rollingRef.current = true
            setRolling(true)
            play('ui.ready')
            setFilled(0)
            // The bar refills 420ms in, under the burst -- so by the time the
            // gold clears, the new level's progress is already sitting there
            // rather than starting from nothing afterwards.
            timers.push(window.setTimeout(
              () => setFilled(p.xp / Math.max(1, p.needed)), 420))
            // ...and `levelling` runs the full length of the burst. It used to
            // clear at 420ms, which cut the animation off at the exact moment
            // it became interesting.
            timers.push(window.setTimeout(() => setLevelling(false), LEVEL_BURST_MS))
            // The net under the animationend chain. See landRoll.
            timers.push(window.setTimeout(landRoll, ROLL_MS + 220))
            timers.push(window.setTimeout(
              () => setRippling(false), ROLL_MS + RIPPLE_MS + 220))
          }, FILL_MS + LEVEL_HOLD_MS))
        }
      })
    })

    // AND THEN THE BLUE FIGURE HANDS THE SLOT BACK.
    //
    // Owner, 2026-08-16 (#91): "the blue (added) XP instantly cuts to the grey
    // (current) XP number on the verdict screen. That should instead have some
    // fade effect." This is the moment that used to be a cut. Everything the
    // award had to say has been said by now -- the counter has stopped, the bar
    // has stopped, and on a level-up the box has rolled and rippled -- so the
    // two numbers cross-fade and the readout goes back to being a running
    // total. See `.xp-readout` in index.css for why they can cross-fade at all.
    const settleAt = levelled ? SETTLE_LEVEL_MS : SETTLE_MS
    timers.push(window.setTimeout(() => setSettled(true), settleAt))

    // THE WORLD WAITS FOR THIS, so the world has to be told.
    //
    // The teardown holds a black screen for a fixed time and then teleports
    // home. That was a guess against this animation's length, and a guess is
    // how the last beat -- the level flip -- kept getting cut off. Lua now
    // waits for `busy` to clear instead, with its own cap so a stuck
    // interface cannot strand anybody (br_core/client/spawn.lua).
    void fetchNui(CB.XP_BUSY, { busy: true })
    timers.push(window.setTimeout(() => {
      clearAward()
      void fetchNui(CB.XP_BUSY, { busy: false })
    }, awardTotalMs(levelled)))

    return () => {
      cancelAnimationFrame(raf)
      for (const t of timers) window.clearTimeout(t)
    }
  }, [award, p.level, p.xp, p.needed, clearAward, landRoll])

  const pct = Math.max(0, Math.min(1, filled))

  return (
    <div className={`relative ${compact ? '' : 'w-full'}`}>
      {/* THE MOMENT. Rendered over the card, keyed on the level so it plays
          exactly once per level gained, and `pointer-events: none` so it
          cannot eat a click on the way past. See .lvlup in index.css for what
          the four layers are doing and why they are gold.

          KEYED ON THE LEVEL BEING CELEBRATED, NOT ON THE ONE THE CHIP IS
          SHOWING, and the difference only appeared once the chip started
          rolling. `shown` is the FRONT face: it holds the OLD number for the
          length of the roll and becomes the new one when the roll lands --
          which is 560ms into a 1500ms burst. Keyed on that, React would see
          the key change mid-burst, throw the whole thing away and start the
          flash, the rings and the rays again from nothing. It would also have
          spent the first third of the celebration announcing the level the
          player had before it. */}
      {levelling && (
        <div className="lvlup" key={`lvl-${rollTo.current}`} aria-hidden>
          <div className="lvlup-flash" />
          <div className="lvlup-ring" />
          <div className="lvlup-ring two" />
          {/* Eight spokes at 45 degrees. Written out rather than generated:
              the array would be the same length as the markup and one more
              thing to read. */}
          {[0, 45, 90, 135, 180, 225, 270, 315].map((a) => (
            <div key={a} className="lvlup-ray" style={{ ['--a' as string]: `${a}deg` }} />
          ))}
          <div className="lvlup-word">Level {rollTo.current}</div>
        </div>
      )}

      <div className="flex items-end gap-3">
        {/* THE LEVEL CHIP, WHICH IS A PRISM ON THE ONE MATCH IN FIFTY THAT
            EARNS IT.

            Owner, #91: "the entire level indicator box should do a 3D prism
            animation (rolling down to reveal the new level up)" -- and #106 is
            equally clear that it must not do that on any other match. So the
            second face exists ONLY while a roll is running: no level-up, no
            back face, nothing to roll, and the chip is the same flat plate it
            has always been in the lobby and the pause menu.

            The stage carries the perspective, the prism carries the rotation,
            and the ripple hangs off the stage rather than the prism so it does
            not turn with the box it is leaving. See index.css. */}
        <div className="lvl-stage">
          <div
            className={`lvl-prism${rolling ? ' is-rolling' : ''}`}
            // Filtered by NAME, not by target: the chip is a .plate, which
            // transitions its own clip-path and border, and the burst overhead
            // runs four more animations that all bubble through here. Only the
            // roll ending means the roll has ended.
            onAnimationEnd={(e) => { if (e.animationName === 'lvlRoll') landRoll() }}
          >
            <LevelChip level={shown.current} gold={levelling} />
            {rolling && <LevelChip level={rollTo.current} gold next />}
          </div>
          {rippling && (
            <>
              <span className="lvl-ripple" aria-hidden />
              <span className="lvl-ripple two" aria-hidden />
            </>
          )}
        </div>

        <div className="flex-1 min-w-0 pb-0.5">
          <div className="flex items-baseline justify-between mb-1">
            <span className="micro-label">
              {levelling ? 'Level up' : 'Progress'}
            </span>
            {/* BOTH NUMBERS ARE ALWAYS HERE, AND THAT IS THE FIX FOR #91's
                LAST HALF.

                Owner, 2026-08-16: "the blue (added) XP instantly cuts to the
                grey (current) XP number on the verdict screen. That should
                instead have some fade effect."

                It cut because this was a ternary: the blue node was REMOVED
                and the grey one INSERTED on the frame the award was cleared,
                and two different elements swapping places is not something any
                transition can smooth. Both are rendered at all times now,
                stacked in a single grid cell, and only opacity moves -- so the
                same instant is a cross-fade in both directions, in and out.

                Keeping the blue one mounted even at rest also holds the cell's
                width and baseline still, which is what stops the whole
                right-hand column twitching when the award ends. */}
            <span className="xp-readout text-[0.72rem] tabular-nums text-white/45">
              <span
                ref={counter}
                className={`font-display text-[0.95rem]${
                  award && !settled ? '' : ' xp-readout__gone'}`}
                style={{ color: 'var(--color-royale-accent)' }}
                aria-hidden={!award}
              >
                +0 XP
              </span>
              {/* "3280 / 4000" is a ratio of nothing. The unit is the thing
                  that makes it a sentence (user, 2026-08-09), and the
                  thousands separator is what makes it readable at a glance
                  once the numbers get long. */}
              <span className={award && !settled ? 'xp-readout__gone' : ''}>
                {p.xp.toLocaleString()} / {p.needed.toLocaleString()} XP
              </span>
            </span>
          </div>

          {/* NOT `overflow-hidden` any more: the sparks are supposed to leave
              the bar, and a clip would eat the entire effect. The fill is a
              scaleX on a full-width child, so it never overflows on its own. */}
          <div className="relative h-[0.5rem] rounded-full bg-black/55">
            <div
              ref={fillRef}
              className="h-full rounded-full origin-left"
              style={{
                width: '100%',
                transform: `scaleX(${pct})`,
                background: levelling
                  ? 'var(--color-royale-accent2)'
                  : 'var(--color-royale-accent)',
                // 1.4s, and slower than feels natural on purpose: the fill IS
                // the reward. The reset after a level-up is quick, because
                // that one is bookkeeping rather than celebration.
                transition: `transform ${pct === 0 ? 320 : FILL_MS}ms var(--ease-out),`
                          + ' background 300ms ease',
              }}
            />

            {/* THE SPARKS, only while an award is actually filling. The
                emitter is moved every frame from the fill's MEASURED width --
                the fill is under a CSS transition and its leading edge is not
                a number any stylesheet can hand to a sibling. */}
            {award && (
              <div ref={emitterRef} className="xp-emitter">
                <span className="xp-head" />
                {SPARKS.map((s, i) => (
                  <span
                    key={i}
                    className="xp-spark"
                    style={{
                      ['--sx' as string]: s.x,
                      ['--sy' as string]: s.y,
                      animationDelay: s.delay,
                      animationDuration: s.dur,
                    }}
                  />
                ))}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  )
}

/**
 * One face of the level chip.
 *
 * IT IS A COMPONENT BECAUSE THERE ARE TWO OF IT, and they must be identical.
 * The prism reveals the new level by turning the old face away and bringing
 * this one up from underneath -- if the two ever drift apart in padding, edge
 * colour or type size, the roll stops reading as one object rotating and
 * starts reading as one box being replaced by a slightly different box, which
 * is exactly the glitch the animation was added to remove.
 *
 * `next` is the face that starts pre-flipped and is otherwise invisible;
 * `gold` is the victory colour, borrowed for the one other thing in the game
 * worth celebrating.
 */
function LevelChip({
  level, gold, next = false,
}: { level: number; gold: boolean; next?: boolean }) {
  return (
    <div
      className={`lvl-face${next ? ' lvl-face--next' : ''}`
        + ` plate px-2.5 py-1 flex flex-col items-center leading-none`
        + `${gold ? ' is-active' : ''}`}
      style={{
        ['--edgec' as string]: gold
          ? 'var(--color-royale-accent2)' : 'var(--color-royale-accent)',
        ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
        ['--cut-max' as string]: '0.4rem',
      }}
    >
      <span className="micro-label" style={{ letterSpacing: '0.18em' }}>Lvl</span>
      <span
        className="font-display text-[1.5rem] tabular-nums leading-none mt-0.5"
        style={{ color: gold ? 'var(--color-royale-accent2)' : '#ffffff' }}
      >
        {level}
      </span>
    </div>
  )
}
