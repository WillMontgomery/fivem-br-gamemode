import { Spinner } from '@heroui/react'
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
          </div>
        </div>

        <div className="end-late flex items-center gap-3">
          <Spinner size="sm" />
          <span key={busy} className="rise text-sm text-white/60">{busy}</span>
        </div>
      </div>
    </div>
  )
}
