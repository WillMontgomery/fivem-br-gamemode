import Ring from '../hud/Ring'
import Progress from './Progress'
import { useUi } from '../store'
import { useEffect, useRef, useState } from 'react'
import type { SummaryPayload } from '../bridge/types'
import { useCoverReport } from '../bridge/cover'

/**
 * When the backdrop below reaches solid black, in ms from this screen mounting.
 * MUST match `.end-backdrop` in index.css (2000ms fade, 1400ms delay) -- it is
 * the fallback deadline for the cover report, not a second copy of the timing.
 */
const BACKDROP_MS = 1400 + 2000

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

export default function EndScreen({ summary }: { summary: SummaryPayload }) {
  const slam = slamText(summary)

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

          <div className="end-late">
            {!summary.won && summary.placement > 0 && (
              <p className="text-xl text-white/55 mt-2">#{summary.placement}</p>
            )}
            <p className="text-sm text-white/45 mt-3">
              {summary.kills} elimination{summary.kills === 1 ? '' : 's'}
            </p>
            {/* WHAT THE MATCH PAID, on the screen that earned it.
                Volts were previously invisible until the player wandered into
                the market and noticed a bigger number — which is a reward
                nobody experiences as one. Only rendered when the server
                actually said so: no payload, no claim. */}
            <VoltsEarned />
          </div>
        </div>

        {/* THE AWARD, WHERE THE MATCH ACTUALLY ENDS.
            This is the moment a progression system exists for: you have just
            finished, the verdict is on screen, and the bar fills while you
            are still looking at it. Putting it only on the lobby card meant
            the reward arrived after a fade, a teleport and a menu -- three
            screens away from the thing that earned it (user, 2026-08-09).

            `end-late`, so it flies in with the supporting lines rather than
            competing with the slam. It fills over the teardown, which is
            dead time the player is already waiting through. */}
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
 * IT IS SYNTHETIC AND IT IS STAGED. It poses the profile two thirds along the
 * level and awards exactly enough to reach a third of the next one, so the
 * interesting animation -- fill, hold, flip, refill -- happens every match
 * rather than one in four. DELETE THIS WHOLE COMPONENT when a server issues
 * real XP: the award then arrives on the wire and Progress renders it with no
 * staging at all.
 */
/**
 * The Volts line under the verdict.
 *
 * Reads the same `earned` envelope the award does, and renders nothing at all
 * when it is absent — a match whose stats failed to record should not claim to
 * have paid anything.
 */
function VoltsEarned() {
  const earned = useUi((s) => s.earned)
  if (!earned || earned.volts <= 0) return null

  return (
    <p className="text-sm mt-1" style={{ color: 'var(--color-royale-accent2)' }}>
      +{earned.volts.toLocaleString()} Volts
      {earned.levelUp && (
        <span className="text-white/45"> · level {earned.level}</span>
      )}
    </p>
  )
}

function StagedAward() {
  const progress = useUi((s) => s.progress)
  const awardXp = useUi((s) => s.awardXp)
  const setProgress = useUi((s) => s.setProgress)
  const fired = useRef(false)

  useEffect(() => {
    // THE GUARD GOES INSIDE THE TIMER, NOT AROUND THE EFFECT.
    //
    // Guarding the effect body with a ref looks like the obvious way to fire
    // once -- and it fires NEVER under StrictMode, which mounts, cleans up,
    // and mounts again: the first pass sets the ref and its cleanup cancels
    // the timer, and the second pass returns early, so nothing is left
    // running. Caught by testing it rather than by reading it.
    //
    // Setting the timer every time and claiming the award inside it is
    // correct under both: cancelled passes simply never reach the ref.
    const t = window.setTimeout(() => {
      if (fired.current) return

      // NO REAL AWARD, NO ANIMATION. This used to fabricate one every match --
      // it invented a level-up unconditionally, so the bar celebrated a
      // milestone that had not happened and animated to a number nothing had
      // persisted. A player who reconnected saw the real level and would
      // reasonably conclude they had been robbed.
      //
      // The numbers now arrive on the `earned` envelope from br_stats, which
      // computes them from the same values it writes to the database. If none
      // arrived -- br_ddb down, stats not recorded -- the correct behaviour is
      // silence.
      const e = useUi.getState().earned
      if (!e) return
      fired.current = true

      const fromLevel = progress.level
      const fromXp = progress.xp
      const fromNeeded = Math.max(1, progress.needed)

      // The new profile FIRST, then the award: the bar animates FROM where
      // the award says it was, TO where the profile says it is now.
      //
      // The server sends the level it landed on; everything else is derived
      // from where the bar already was, so the fill starts where the player
      // was actually looking.
      const carried = fromXp + e.xp
      setProgress({
        level: e.level,
        xp: e.levelUp ? Math.max(0, carried - fromNeeded) : carried,
        needed: fromNeeded,
      })
      awardXp({ xp: e.xp, fromLevel, fromXp, fromNeeded })
    }, 1600)

    return () => window.clearTimeout(t)
    // Mount only. Re-running this on a progress change would re-award.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return null
}
