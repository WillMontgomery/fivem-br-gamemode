import { Spinner } from '@heroui/react'
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
export default function EndScreen({ summary }: { summary: SummaryPayload }) {
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
              className="end-slam text-7xl font-black tracking-tight"
              style={{ color: 'var(--color-royale-accent)' }}
            >
              VICTORY ROYALE
            </h1>
          ) : (
            <h1 className="end-slam text-8xl font-black tracking-tight text-white/95">
              ELIMINATED
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
          <span className="text-sm text-white/60">Cleaning up the map…</span>
        </div>
      </div>
    </div>
  )
}
