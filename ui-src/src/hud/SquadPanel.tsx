import type { SquadPayload } from '../bridge/types'

/**
 * Squad status.
 *
 * Squad membership and each member's state come from the server roster, never
 * from enumerating nearby players -- a squadmate across the map is out of scope
 * and would simply be missing.
 */
export default function SquadPanel({ squad }: { squad: SquadPayload }) {
  if (!squad.id || squad.members.length <= 1) return null

  return (
    <div className="panel px-3 py-2 flex flex-col gap-1.5">
      {squad.members.map((m) => {
        const dead = m.state === 'dead' || m.state === 'left'
        const downed = m.state === 'dbno'

        // Bars, not numbers: a glance says "hurt / shielded / down", which
        // is all a squadmate readout is for -- the digits were noise.
        return (
          <div key={m.src} className="flex items-center gap-2" style={{ opacity: dead ? 0.35 : 1 }}>
            <span
              className="w-1.5 h-6 rounded-full shrink-0"
              style={{ background: m.colour }}
            />
            <div className="flex-1 min-w-0">
              <div className="flex items-baseline justify-between gap-2">
                <span className="text-[0.6875rem] font-semibold truncate">{m.name}</span>
                {(dead || downed) && (
                  <span className="text-[0.625rem] text-white/50">
                    {dead ? 'OUT' : 'DOWN'}
                  </span>
                )}
              </div>
              {!dead && (
                <>
                  <div className="h-1 mt-0.5 rounded-full bg-black/55 overflow-hidden">
                    <div
                      className="bar-fill h-full rounded-full"
                      style={{
                        width: '100%',
                        transform: `scaleX(${Math.max(0, Math.min(1, m.hp / 100))})`,
                        background: downed ? 'var(--color-danger)' : 'var(--color-hp)',
                      }}
                    />
                  </div>
                  <div className="h-1 mt-0.5 rounded-full bg-black/55 overflow-hidden">
                    <div
                      className="bar-fill h-full rounded-full"
                      style={{
                        width: '100%',
                        transform: `scaleX(${Math.max(0, Math.min(1, (m.armour ?? 0) / 100))})`,
                        background: 'var(--color-shield)',
                      }}
                    />
                  </div>
                </>
              )}
            </div>
          </div>
        )
      })}
    </div>
  )
}
