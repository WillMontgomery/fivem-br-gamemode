import Ring from '../hud/Ring'
import Progress from './Progress'
import { useUi } from '../store'
import { useEffect, useState } from 'react'
import type { SummaryPayload } from '../bridge/types'

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

  return (
    <div className="fixed inset-0">
      {/* The backdrop is its own layer so the slam happens over nothing --
          and it is SOLID BLACK, not a tint: the screen goes fully dark
          behind the verdict and stays dark until the lobby fades in at
          WAITING (the game-side fade holds underneath to match). */}
      <div className="end-backdrop absolute inset-0" style={{ background: '#000' }} />

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

  useEffect(() => {
    // THE GUARD GOES INSIDE THE TIMER, NOT AROUND THE EFFECT.
    //
    // Guarding the effect body with a ref looks like the obvious way to fire
    // once -- and it fires NEVER under StrictMode, which mounts, cleans up,
    // and mounts again: the first pass sets the ref and its cleanup cancels
    // the timer, and the second pass returns early, so nothing is left
    // running. Caught by testing it rather than by reading it.
    //
    // AND THE GUARD IS IN THE STORE, NOT IN A REF, because a ref is per mount
    // and this component remounts whenever App's `showEnd` flickers -- and
    // `earned` was never cleared, so each remount replayed the same award.
    // `stageEarned` claims the payload once and returns null to everybody
    // afterwards.
    const t = window.setTimeout(() => {
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
    }, 1600)

    return () => window.clearTimeout(t)
    // Mount only. Re-running this on a progress change would re-award.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  return null
}
