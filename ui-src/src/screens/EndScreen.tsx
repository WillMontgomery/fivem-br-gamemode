import Ring from '../hud/Ring'
import Progress from './Progress'
import { useUi } from '../store'
import { useEffect, useState } from 'react'
import type { SummaryPayload } from '../bridge/types'
import { useCoverReport } from '../bridge/cover'

/**
 * When the backdrop below reaches solid black, in ms from this screen mounting.
 * MUST match `.end-backdrop` in index.css (2000ms fade, 1400ms delay) -- it is
 * the fallback deadline for the cover report, not a second copy of the timing.
 */
const BACKDROP_MS = 1400 + 2000

/**
 * When the supporting lines arrive, in ms from mount.
 *
 * MUST match `.end-late`'s animation-delay in index.css. It is not a second
 * copy of that number for the CSS's benefit -- the bar and the placement line
 * are still animated by the stylesheet. It is here because the eliminations
 * and Volts lines flip in on their own (#106) and have to agree with their
 * neighbours to the frame, and because the award below is timed against it.
 */
const LINES_MS = 3600

/**
 * When the XP award starts, in ms from mount.
 *
 * IT WAS 1600, AND EVERYTHING IT DID WAS INVISIBLE. `.end-late` holds its
 * `from` keyframe for the whole 3600ms delay -- that is what `both` means --
 * so the XP bar's opacity is flatly ZERO until 3.6s. The award fired at 1.6s,
 * the counter finished counting at 3.0s and the bar finished filling at 3.0s,
 * and the screen only became visible six hundred milliseconds after all of it
 * had already happened.
 *
 * THAT IS WHY #91's LAST SYMPTOM LOOKED THE WAY IT DID. The owner reported "the
 * blue (added) XP instantly cuts to the grey (current) XP number", and the
 * reason he described a static blue number rather than a counter is that the
 * count-up had run and stopped behind a transparent element. He was seeing the
 * last frame of an animation nobody had ever watched, and then a hard cut.
 * Fixing the cut alone would have left the reward itself unseen.
 *
 * So the award now starts after the bar has arrived and had a beat to settle,
 * which is also what #106 means by "these need to read as one sequence rather
 * than two things happening near each other": the lines flip in, the bar rises,
 * and THEN it fills.
 */
const AWARD_AT_MS = LINES_MS + 800

/**
 * The between-rounds interstitial: won or lost, then "cleaning up".
 *
 * Choreography, per design: the verdict SLAMS in first, huge, over a
 * transparent background -- the dying world (already fading to black
 * underneath) is the backdrop for the impact frame. Only then does the dim
 * gradient fade in, and the supporting lines arrive last. Timing lives in
 * index.css (.end-slam / .end-backdrop / .end-late), all transform/opacity.
 *
 * Shows from the moment the match is decided until the state machine
 * reaches WAITING and the find-a-match card takes over. This is the
 * placeholder M7's full Victory Royale screen replaces -- placement and
 * kills are real, the rest of the summary payload arrives with stats.
 */
/**
 * What the slam says when you lost, by how you lost.
 *
 * "ELIMINATED" is reserved for another player doing it -- getting outrun by
 * a wall of purple or stepping off a cliff is not an elimination and reads
 * as a lie when the screen calls it one. Everything else gets the energy of
 * a GTA death with the honesty of a cause, and the generic environmental
 * fallback is the franchise's own word for it.
 */
function slamText(summary: SummaryPayload): string {
  if (summary.byPlayer) return 'ELIMINATED'
  switch (summary.cause) {
    // Nobody finished them; the clock did. Distinct from ELIMINATED on
    // purpose -- being left on the floor and being shot are different stories,
    // and only one of them has somebody to blame.
    case 'bledout':   return 'BLED OUT'
    case 'storm':     return 'COOKED BY THE STORM'
    case 'fall':      return 'GRAVITY WINS'
    case 'drowned':   return 'SLEPT WITH THE FISHES'
    case 'burned':    return 'EXTRA CRISPY'
    case 'explosion': return 'BLOWN TO BITS'
    case 'roadkill':  return 'SPEED BUMP'
    default:          return 'WASTED'
  }
}

/**
 * True once `ms` have passed since the calling screen mounted.
 *
 * THE BEAT HAS TO COME FROM THE SCREEN, not from a CSS delay on each line.
 * A CSS animation-delay is measured from the moment the ELEMENT appears, and
 * the Volts line appears when br_stats answers -- which is a DynamoDB round
 * trip, arriving anywhere from immediately to a second or two after the verdict
 * lands. A 3.6s delay on that element would mean 3.6s after the payload, so the
 * two lines that are supposed to flip in together would drift apart by exactly
 * however slow the database was that match.
 */
function useBeat(ms: number): boolean {
  const [passed, setPassed] = useState(false)
  useEffect(() => {
    const t = window.setTimeout(() => setPassed(true), ms)
    return () => window.clearTimeout(t)
  }, [ms])
  return passed
}

export default function EndScreen({ summary }: { summary: SummaryPayload }) {
  const slam = slamText(summary)

  // The supporting lines' beat. Shared by the two that flip rather than fly.
  const lines = useBeat(LINES_MS)

  // The teardown line tells a small two-act story: progress is "saved"
  // first (true in spirit; literally true from M7), then the map is being
  // cleaned. The five seconds are counted from when the line becomes
  // VISIBLE -- .end-late flies in 3.6s after mount -- not from mount, which
  // cut the first act to about a second on screen.
  const [busy, setBusy] = useState('Saving progress…')
  useEffect(() => {
    const t = window.setTimeout(() => setBusy('Cleaning up the map…'), 3600 + 5000)
    return () => window.clearTimeout(t)
  }, [])

  // THE BACKDROP IS THE COVER FOR THE END OF A MATCH, so it reports when it
  // has reached solid black -- and the world is only dismantled after that.
  //
  // This is #124's second half. The server used to sweep everyone home the
  // instant the match was decided, which froze the player, took away the car
  // they were driving and switched the storm off while this slam was still
  // playing over a live world. It now waits for this report. Nothing about the
  // screen's own choreography changes; it simply says when it is finished.
  const onCovered = useCoverReport('verdict', true, BACKDROP_MS + 200)

  return (
    <div className="fixed inset-0">
      {/* The backdrop is its own layer so the slam happens over nothing --
          and it is SOLID BLACK, not a tint: the screen goes fully dark
          behind the verdict and stays dark until the lobby fades in at
          WAITING (the game-side fade holds underneath to match). */}
      <div
        className="end-backdrop absolute inset-0"
        style={{ background: '#000' }}
        onAnimationEnd={onCovered}
      />

      <div className="absolute inset-0 flex flex-col items-center justify-center gap-8">
        <div className="text-center">
          {summary.won ? (
            <h1
              // GOLD, AND GOLD ONLY HERE. The brand is cyan; victory is the one
              // thing in the game allowed this colour, which is what makes it
              // mean something when it appears.
              className="end-slam font-display text-8xl tracking-tight"
              style={{
                color: 'var(--color-royale-accent2)',
                textShadow: '0 0 3rem rgba(250,204,21,0.35)',
              }}
            >
              VICTORY ROYALE
            </h1>
          ) : (
            <h1
              className={`end-slam font-display tracking-tight text-white/95 ${
                slam.length > 12 ? 'text-6xl' : 'text-8xl'
              }`}
              style={{ textShadow: 'var(--shadow-text)' }}
            >
              {slam}
            </h1>
          )}

          {!summary.won && summary.placement > 0 && (
            <p className="end-late text-xl text-white/55 mt-2">#{summary.placement}</p>
          )}

          {/* THE TWO LINES THAT FLIP RATHER THAN FLY.
              Owner's spec in #91, carried into #106: `animate__flipInX` on the
              elimination count and on the Volts. They are the only two lines on
              this screen that are a RESULT rather than a caption, and turning
              them in on their own axis is what separates them from the block of
              supporting text they used to be part of.

              They are no longer inside `.end-late`. Nesting a flip inside a
              fly-up multiplies the two opacity ramps together, which reads as
              neither gesture -- the line arrives dim and late and the flip is
              lost inside it. `.end-wait` holds their space until their beat, so
              the centred column below the slam never jumps. */}

          {/* THE ONE NUMBER THE PLAYER CAME FOR, AND IT WAS THE DIMMEST
              THING ON THE SCREEN. #136 was raised about the pause menu, and
              the shade it complained about is the same one that was hand
              typed here as `text-white/45` -- so the fix had to reach this
              screen too or the verdict would have been left as the last
              place in the interface still too dark to read. It reads the
              token now, and moves when the token moves. */}
          <p
            className={`${lines ? 'end-flip' : 'end-wait'} text-sm mt-3`}
            style={{ color: 'var(--color-text-dim)' }}
          >
            {summary.kills} elimination{summary.kills === 1 ? '' : 's'}
          </p>

          {/* WHAT THE MATCH PAID, on the screen that earned it.
              Volts were previously invisible until the player wandered into
              the market and noticed a bigger number — which is a reward
              nobody experiences as one. Only rendered when the server
              actually said so: no payload, no claim. */}
          <VoltsEarned show={lines} />
        </div>

        {/* THE AWARD, WHERE THE MATCH ACTUALLY ENDS.
            This is the moment a progression system exists for: you have just
            finished, the verdict is on screen, and the bar fills while you
            are still looking at it. Putting it only on the lobby card meant
            the reward arrived after a fade, a teleport and a menu -- three
            screens away from the thing that earned it (user, 2026-08-09).

            `end-late`, so it flies in with the supporting lines rather than
            competing with the slam. It fills over the teardown, which is
            dead time the player is already waiting through.

            AND `.end-late` IS ALREADY #106's `animate__fadeInUp` -- opacity
            from nothing, rising off a translateY, on this project's own curve
            (see `endFlyUp` in index.css). A second keyframe with an imported
            name would be the same gesture written twice, and #106 asks for the
            motion rather than the library. What changed is not this line: it is
            that the award no longer starts while this element is still at
            opacity 0. See AWARD_AT_MS. */}
        <div className="end-late" style={{ width: '26rem', maxWidth: '80vw' }}>
          <Progress />
        </div>
        <StagedAward />

        <div className="end-late flex items-center gap-3">
          <Ring size={1.3} stroke={0.15} label="Cleaning up" />
          <span key={busy} className="rise text-sm text-white/60">{busy}</span>
        </div>
      </div>
    </div>
  )
}

/**
 * The Volts line under the verdict.
 *
 * Reads the same `earned` envelope the award does, and renders nothing at all
 * when it is absent — a match whose stats failed to record should not claim to
 * have paid anything.
 *
 * `show` is the screen's beat rather than this line's own clock, for the reason
 * on `useBeat`: this element appears whenever br_stats answers, so a delay
 * measured from its own arrival would drift by however slow the database was.
 * A payload that lands AFTER the beat flips in the moment it gets here, which
 * is the honest behaviour -- it is late, not cancelled.
 */
function VoltsEarned({ show }: { show: boolean }) {
  const earned = useUi((s) => s.earned)
  if (!earned || earned.volts <= 0) return null

  return (
    <p
      className={`${show ? 'end-flip' : 'end-wait'} text-sm mt-1`}
      // 140ms behind the elimination count. The two are the same gesture, and
      // playing them in unison reads as one wide element turning rather than as
      // two facts arriving.
      style={{ color: 'var(--color-royale-accent2)', animationDelay: '140ms' }}
    >
      +{earned.volts.toLocaleString()} Volts
      {/* Same shade, same token, same reason as the elimination line above. */}
      {earned.levelUp && (
        <span style={{ color: 'var(--color-text-dim)' }}> · level {earned.level}</span>
      )}
    </p>
  )
}

/**
 * The post-match XP award, staged here.
 *
 * WHY IT IS IN THE COMPONENT AND NOT IN LUA. It was: br_ui's market.lua heard
 * the SUMMARY net event and pushed an award a couple of seconds later. It was
 * reported as never animating, twice, and the reason it is hard to see is that
 * every part of it is timing against a screen it cannot observe -- the verdict
 * exists only while the match tears down, and a delay tuned against that
 * window is a delay that misses it whenever teardown is quick.
 *
 * THIS COMPONENT ONLY EXISTS WHILE THE VERDICT IS ON SCREEN. Firing the award
 * from its own mount removes the guess entirely: there is no window to miss,
 * because the thing that starts the clock is the thing that would have to be
 * there to see it.
 *
 * IT OWNS THE TIMING AND NOTHING ELSE. It used to own the arithmetic too --
 * first by fabricating an award outright, then by deriving where the bar should
 * stop from where it happened to be. Both were the same mistake in different
 * clothes: a progression number computed anywhere except the server is a number
 * that will eventually disagree with the database, and the player believes the
 * screen. All this does now is decide WHEN, and hand two server-issued
 * snapshots to Progress.
 */
function StagedAward() {
  const awardXp = useUi((s) => s.awardXp)
  const setProgress = useUi((s) => s.setProgress)
  const stageEarned = useUi((s) => s.stageEarned)

  // AT THE BEAT, OR WHEN THE PAYLOAD TURNS UP -- WHICHEVER IS LATER.
  //
  // This used to be one timer: fire at N milliseconds, and if br_stats had not
  // answered by then, nothing animated for the rest of the match. That is a
  // race against a DynamoDB write, and losing it silently costs the player the
  // only view they get of what the match paid.
  //
  // Two conditions instead. The beat below says the bar has arrived and is
  // ready to be filled; `earned` says there is something to fill it with. The
  // award goes when both are true, so a slow write is late rather than lost,
  // and `stageEarned` still guarantees it happens exactly once.
  //
  // IT IS ALSO WHAT MAKES `brxpsim` USABLE ON THIS SCREEN. The command poses a
  // real award at a connected player from the server console, and a fixed
  // window meant it only landed if it was typed within the first second and a
  // half of somebody's verdict. Now it can be run at any point while the
  // verdict is up.
  const beat = useBeat(AWARD_AT_MS)
  const earned = useUi((s) => s.earned)

  useEffect(() => {
    if (!beat || !earned) return

    {
      // THE GUARD IS IN THE STORE, NOT IN A REF, because a ref is per mount
      // and this component remounts whenever App's `showEnd` flickers -- and
      // `earned` was never cleared, so each remount replayed the same award.
      // `stageEarned` claims the payload once and returns null to everybody
      // afterwards. It survives StrictMode's mount/unmount/mount for the same
      // reason: the claim lives outside the component's lifetime.
      //
      // NO REAL AWARD, NO ANIMATION. This used to fabricate one every match --
      // it invented a level-up unconditionally, so the bar celebrated a
      // milestone that had not happened and animated to a number nothing had
      // persisted. A player who reconnected saw the real level and would
      // reasonably conclude they had been robbed.
      //
      // The numbers arrive on the `earned` envelope from br_stats, which
      // computes them from the same values it writes to the database. If none
      // arrived -- br_ddb down, stats not recorded -- the correct behaviour is
      // silence.
      const e = stageEarned()
      if (!e) return

      // EVERY NUMBER BELOW CAME OFF THE WIRE. Nothing here adds, subtracts or
      // clamps, and that is the fix for #91 and #130 rather than a style
      // preference.
      //
      // What used to be here: `carried = progress.xp + e.xp`, then on a
      // level-up `Math.max(0, carried - progress.needed)`, keeping the old
      // `needed` as the denominator. Three faults compounding:
      //
      //   1. DOUBLE COUNT. br_stats fires `br:market:credited` on the same
      //      tick as this award, which pushes MARKET_STATE carrying the
      //      already-credited total -- so `progress.xp` here was the POST
      //      match figure, and adding the award to it counted the match twice.
      //   2. CLAMPED TO ZERO ON A LEVEL-UP. Subtracting the old span from that
      //      doubled figure goes negative whenever the match was worth less
      //      than a level, and Math.max(0, ...) turned that into a confident
      //      "0 XP". A real case: 327 + 1048 - 2050 = -675, shown as 0, for a
      //      player who had just gained 1048.
      //   3. FROZEN DENOMINATOR. `needed: fromNeeded` kept the previous
      //      level's span forever, which is how a bar reads 3,472 / 2,450 and
      //      never resets.
      //
      // The server knows all of it -- it evaluated the curve to write the row.
      // So it sends both ends and this renders them.
      setProgress({ level: e.level, xp: e.into, needed: Math.max(1, e.needed) })
      awardXp({
        xp: e.xp,
        fromLevel: e.fromLevel,
        fromXp: e.fromXp,
        fromNeeded: Math.max(1, e.fromNeeded),
      })
    }
    // `earned` and the beat only. Depending on `progress` would re-run this
    // the instant it awards -- which is the shape of a loop, not a re-award,
    // because `stageEarned` refuses the second claim.
  }, [beat, earned, stageEarned, setProgress, awardXp])

  return null
}
