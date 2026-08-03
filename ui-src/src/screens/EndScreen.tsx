import { Spinner } from '@heroui/react'
import type { SummaryPayload } from '../bridge/types'

/**
 * The between-rounds interstitial: won or lost, then "cleaning up".
 *
 * Shows from the moment the match is decided (the screen fades to black
 * underneath it, the trip back to the lobby island happens behind that)
 * until the state machine reaches WAITING and the find-a-match card takes
 * over. This is the placeholder M7's full Victory Royale screen replaces --
 * placement and kills are real, the rest of the summary payload arrives
 * with the stats milestone.
 */
export default function EndScreen({ summary }: { summary: SummaryPayload }) {
  return (
    <div
      className="fixed inset-0 flex flex-col items-center justify-center gap-6"
      style={{
        background:
          'radial-gradient(ellipse at 50% 40%, rgba(20, 12, 40, 0.55), rgba(6, 8, 14, 0.85))',
      }}
    >
      <div className="text-center">
        {summary.won ? (
          <h1
            className="text-5xl font-black tracking-tight"
            style={{ color: 'var(--color-royale-accent)' }}
          >
            VICTORY ROYALE
          </h1>
        ) : (
          <>
            <h1 className="text-4xl font-black tracking-tight text-white/90">
              ELIMINATED
            </h1>
            {summary.placement > 0 && (
              <p className="text-lg text-white/55 mt-1">
                #{summary.placement}
              </p>
            )}
          </>
        )}
        <p className="text-sm text-white/45 mt-3">
          {summary.kills} elimination{summary.kills === 1 ? '' : 's'}
        </p>
      </div>

      <div className="flex items-center gap-3">
        <Spinner size="sm" />
        <span className="text-sm text-white/60">Cleaning up the map…</span>
      </div>
    </div>
  )
}
