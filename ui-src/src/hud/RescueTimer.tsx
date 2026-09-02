import { useEffect, useRef } from 'react'
import { useUi, selDbno } from '../store'
import { HotCard, HotTime } from './HotCard'

/**
 * How long the ambulance has (#191 step 6).
 *
 * Owner, 2026-08-28: "let's add an on-screen timer showing their time to revive
 * please".
 *
 * ═══ WHY THIS DOES NOT CONTRADICT "THE ONLY NOTIFICATION" ═══
 *
 * #191 says two things that look opposed and are not:
 *
 *   "A single DUI: 'press [interact key] to call a medic'. This is the only
 *    notification in the entire cycle. Nothing else may be shown at any point."
 *   "A timer is shown to the player: the timeout, derived from the estimated
 *    driving time for that route."
 *
 * The first governs NOTIFICATIONS -- things that arrive on an event, say a
 * sentence and leave. There is still exactly one of those, it is the CPR row on
 * the bleed-out card, and nothing was added to dispatch, arrival, the ambulance
 * being destroyed or a recovery firing. This is a READOUT: a number that sits in
 * one place for exactly as long as the state it describes, the way the storm
 * clock and the warmup clock do. The owner has now asked for it by name.
 *
 * IF YOU ARE HERE TO DELETE THIS FILE citing "the only notification", read both
 * quotes again. br_core/client/rescue.lua carries the same note at the top,
 * because that is the other place the argument would be had.
 *
 * ═══ IT IS MOUNTED OUTSIDE THE HUD, WHICH IS THE WHOLE DESIGN ═══
 *
 * The ride hides the entire HUD -- also the owner's, the same day: "while in the
 * ambulance, our HUD should be hidden just like in the bus". So this readout has
 * to be an exception to a rule he also asked for, and there were two ways to
 * build it:
 *
 *   1. MAKE THE SUPPRESSION SELECTIVE -- let `Hud` stay mounted and teach the
 *      surfaces inside it which of them survive a ride. Rejected. `hudUp` is one
 *      boolean that turns off vitals, counters, kill feed, squad panel,
 *      inventory, chat, the TAB panel and the bleed-out card, and its value is
 *      that it cannot miss one. Turning it into "everything except..." starts a
 *      list, and lists grow: the next surface added to the HUD would inherit
 *      whichever answer its author happened to think about.
 *
 *   2. DRAW IT OUTSIDE THE HIDDEN TREE. Taken. `hudUp` keeps meaning exactly
 *      what it meant, hiding the HUD still hides all of it, and this is a
 *      sibling of `Hud` in App.tsx rather than a child.
 *
 * That is not a new pattern here: DeathVerdict sits beside `Hud` for the same
 * reason -- "it is not HUD chrome and must not inherit its visibility".
 *
 * ═══ WHERE IT SITS ═══
 *
 * Top centre, on --safe-y: the slot Hud.tsx describes as "whichever clock
 * matters right now", shared by the warmup countdown and the storm bar. During a
 * ride that slot is empty, because the HUD that owns it is hidden -- so this
 * lands in the place the interface already puts clocks rather than inventing a
 * position for the one screen nothing else is on. A centred surface needs no
 * ultrawide correction (Hud.tsx: the engine's layout box is itself centred), and
 * the camera is a chase shot of the ambulance, which lives in the middle of the
 * frame and below.
 *
 * ═══ WHAT IT COUNTS DOWN TO, AND WHY THAT IS "TIME TO REVIVE" ═══
 *
 * `rideEndsAt` is the server's `rec.deadlineAt`, carried to the client on
 * RESCUE_BEGIN and parked on its ride record. Nothing is derived here: a second
 * deadline computed in the browser could disagree with the one that actually
 * ends the journey, and the player would be watching the wrong clock.
 *
 * AND ZERO IS NOT A THREAT. server/rescue.lua's tick reads
 * `if now >= rec.deadlineAt then if rec.everMoved then finish(src, true, ...)`
 * -- a moving ambulance whose deadline lands DELIVERS. So this is an upper bound
 * on the wait, which is exactly the thing the owner asked to see, and beating it
 * is the normal case: `etaSlack` is 1.8, so a drive that goes to plan ends with
 * a little under half the clock left. The one case where zero is fatal is an
 * ambulance that never moved at all, which is a ride that was already broken and
 * not a race the player could have run differently.
 *
 * THAT IS WHY NOTHING ESCALATES IN THE LAST SECONDS. No colour change, no
 * quickening, no growing numeral. Escalation would be a lie about what zero
 * means, and this project has a standing rule against flourish nobody asked for.
 *
 * ═══ IT IS THE BLEED-OUT CARD, IN FULL, AND THAT TOOK TWO PASSES ═══
 *
 * Owner, 2026-08-29: "Please rebuild the revive timer UI to be the same card as
 * the bleed out card and timer."
 *
 * It shipped first as a bare numeral on a `.panel` (d7272a6), then as a capless
 * `HotCard` -- and the argument for holding back both times is two paragraphs up
 * this file: `.panel-hot` demands a text cap, and a cap has to SAY something on
 * a card whose whole point is that there is nothing to announce. He looked at
 * the capless version and said so plainly:
 *
 *   "the revive timer is redone, but is not a proper card UI like the bleed out
 *    timer..... I want you to make it look exactly like the bleed out timer, but
 *    instead of RED use BLUE outlines."
 *
 * So it is the whole object now, in DbnoOverlay's own order: cap, numeral,
 * sub-label, bar. "Exactly like" is the spec, and a card missing three of its
 * four rows was the complaint.
 *
 * NOT BY MOVING IT INTO THE HUD. It is still a sibling of `Hud` in App.tsx and
 * Hud.tsx still must never render it -- the whole reason this component exists
 * is that the ride hides the HUD and this is the one thing that survives that.
 * What is shared is the appearance; hud/HotCard.tsx has the long version.
 *
 * ═══ THE WORDS ARE HIS, BECAUSE THEY HAD TO BE ═══
 *
 * "Medic en route" and "time to revive" were chosen by the owner from a list on
 * 2026-08-29, and they are the only two strings on this surface. That is not
 * ceremony: the standing rule here is that no helper copy, hint or caption gets
 * invented -- "it comes across as 'AI slop'" -- and a `.panel-hot` cap cannot be
 * left blank, so asking was the only way to give him the card he asked for
 * without writing UI text he never approved. "time to revive" is his own phrase
 * from the message that commissioned this timer.
 *
 * IF THESE STRINGS NEED TO CHANGE, that is an owner decision, not a tidy-up.
 *
 * ═══ BLUE, AND `--color-shield` IS WHAT BLUE MEANS HERE ═══
 *
 * "instead of RED use BLUE outlines" (owner, 2026-08-29). `.panel-hot` has no
 * neutral: `--hot` drives the border, the cap fill and the border's pulse
 * together, so setting it once is what stops a blue edge ending up with a red
 * cap.
 *
 * NOT A LITERAL #38bdf8. `--color-shield` is one of the four tokens the
 * colourblind modes remap -- index.css re-declares it under both -- so the one
 * readout a downed player is staring at follows the accessibility setting
 * instead of quietly ignoring it. It also already means "blue" everywhere else
 * in this interface, which is the other half of picking a token over a hex.
 *
 * AND IT REPLACES `--color-hp`, WHICH WAS A REASONED CHOICE AND IS NOW WRONG.
 * The capless version used the health colour on the argument that green is what
 * this card's OTHER state means -- DbnoOverlay flips to `--color-hp` when
 * somebody is picking you up, and an ambulance with you in the back is that
 * state. Recorded rather than quietly swapped: he asked for blue, blue is not
 * red, and the reasoning it replaces was sound rather than forgotten.
 *
 * ═══ THE BAR MEASURES THE SAME THING THE NUMBER DOES ═══
 *
 * On the bleed-out card the bar earns its place by DISAGREEING with the
 * countdown -- enemy fire shortens a bleed, so a burst visibly tears a chunk out
 * of it. Nothing shortens a ride, so here it is the countdown drawn a second
 * way, and on its own that would not be worth adding.
 *
 * It is here because "exactly like the bleed out timer" is the request and the
 * bar is a row of that card. The denominator is the first reading of THIS ride,
 * held in a ref, for the same reason DbnoOverlay holds one: recomputing the
 * total from the time remaining refills the bar every frame.
 *
 * ═══ THE FORMAT IS m:ss, WHICH IS THE ONE THING THAT DIFFERS ═══
 *
 * The bleed clock reads `93s`. A drive across the map is minutes, and `167s` is
 * not a clock. It is held at m:ss BELOW a minute too -- `0:07` reads as a clock
 * where `7` reads as a score, and the width never jumps at the minute boundary.
 *
 * The digits are written straight to the node from one requestAnimationFrame
 * loop, like every other countdown in the HUD -- a re-render per frame for four
 * characters is the tax those rules exist to avoid.
 *
 * ═══ AND IT STANDS DOWN WHEN THE MATCH IS DECIDED ═══
 *
 * `show` is `ridingAmbulance && !tearingDown` in App.tsx, and the second half is
 * not belt-and-braces -- see the note there. A ride does not end by a message:
 * client/rescue.lua's `rescue.sanity` sweep tears it down at 1 Hz when the match
 * stops being PLAYING, and the verdict screen mounts 500ms after the match ends.
 * The match-state bit is on this client the instant the transition arrives, so
 * gating on it is what stops this placard being on screen underneath
 * VICTORY ROYALE for the second in between.
 */
export default function RescueTimer({ show }: { show: boolean }) {
  const dbno = useUi(selDbno)
  const offset = useUi((s) => s.clockOffset)
  const timeRef = useRef<HTMLSpanElement>(null)
  const barRef = useRef<HTMLDivElement>(null)

  // Seeded on the first frame of THIS ride and then held. The component is
  // mounted only while `show` is true, so a fresh ride brings a fresh ref --
  // the same lifecycle the bleed-out card's denominator relies on.
  const totalRef = useRef(0)

  // Zero means no clock: Lua zeroes it the instant the ride ends, and a server
  // that never sends it leaves it undefined. Either way there is nothing to
  // count and nothing is drawn.
  const endsAt = dbno.rideEndsAt ?? 0
  const showing = show && endsAt > 0

  useEffect(() => {
    if (!showing) return
    let raf = 0

    const tick = () => {
      // A SERVER timestamp. The browser's wall clock shares no origin with it,
      // so `clockOffset` is what makes the comparison mean anything -- the rule
      // StormBar, WarmupTimer and the bleed-out card all follow.
      const left = Math.max(0, endsAt - (Date.now() + offset))
      if (totalRef.current <= 0) totalRef.current = Math.max(1, left)

      const node = timeRef.current
      if (node) {
        const total = Math.ceil(left / 1000)
        const next = `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
        if (node.textContent !== next) node.textContent = next
      }
      if (barRef.current) {
        barRef.current.style.transform =
          `scaleX(${Math.min(1, left / totalRef.current)})`
      }
      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [showing, endsAt, offset])

  // Nothing at all off a ride -- not an empty container. This is the only thing
  // on the screen while it is up, and a zero-height box in the clock slot is one
  // more thing for the next layout question to trip over.
  if (!showing) return null

  return (
    <div
      className="fixed left-1/2 -translate-x-1/2 pointer-events-none"
      style={{ top: 'var(--safe-y)' }}
      aria-hidden
    >
      {/* `14rem` is DbnoOverlay's width, not a number picked for this content:
          the two are meant to read as one object, and a placard that is
          narrower here because it happens to hold fewer characters would read
          as a different one. The cap's uppercasing and tracking come from
          `.panel-hot > .cap`, so the string is written in sentence case here
          exactly as the bleed-out card's is. */}
      <HotCard hot="var(--color-shield)" cap="Medic en route" minWidth="14rem">
        <>
          <HotTime ref={timeRef} />
          <span className="text-[0.55rem] font-semibold uppercase tracking-[0.18em] text-white/50">
            time to revive
          </span>

          {/* SQUARE, and sized in rem, for the reason the bleed-out card's bar
              is: the root font size is clamp(11px, 1.481vh * var(--ui-scale),
              28px), and rem is the only unit the interface-size slider reaches.
              One bar, because there is only ever one process running here. */}
          <div className="mt-2 h-[0.2rem] w-full bg-black/60 overflow-hidden">
            <div
              ref={barRef}
              className="bar-fill h-full"
              style={{ width: '100%', background: 'var(--color-shield)' }}
            />
          </div>
        </>
      </HotCard>
    </div>
  )
}
