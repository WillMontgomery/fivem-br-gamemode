import { useEffect, useRef, useState } from 'react'
import type { SquadMember, SquadPayload } from '../bridge/types'

/**
 * Squad status.
 *
 * Squad membership and each member's state come from the server roster, never
 * from enumerating nearby players -- a squadmate across the map is out of scope
 * and would simply be missing.
 *
 * A MATE DYING IS A SEQUENCE, NOT AN OPACITY CHANGE. Fading a row out is the
 * least legible thing a HUD can do: it reads as a render glitch rather than as
 * something happening. It now flashes, the bars DRAIN (slower than a damage
 * move, so it reads as dying rather than as a large hit), then OUT stamps in.
 *
 * DOWNED AND DEAD MUST NEVER LOOK ALIKE. Downed pulses the colour tag and turns
 * the health bar red -- it is recoverable and the player has a decision to
 * make. Dead is finished and still.
 */

type Phase = 'alive' | 'down' | 'dying' | 'dead'

function phaseOf(m: SquadMember): Exclude<Phase, 'dying'> {
  if (m.state === 'dead' || m.state === 'left') return 'dead'
  if (m.state === 'dbno') return 'down'
  return 'alive'
}

/**
 * Holds a member in a transient `dying` phase for the length of the drain, so
 * the bars have something to animate to before the row goes flat. Without it
 * the row is already at zero on the frame the state arrives and there is
 * nothing to see.
 */
function useDeathSequence(m: SquadMember) {
  const target = phaseOf(m)
  const [phase, setPhase] = useState<Phase>(target)
  const [flash, setFlash] = useState(0)
  const prev = useRef(target)

  useEffect(() => {
    if (target === prev.current) return
    const from = prev.current
    prev.current = target

    // Any transition INTO a bad state is worth a flash -- taking a knee and
    // being finished are both news.
    if (target !== 'alive') setFlash((f) => f + 1)

    if (target === 'dead' && from !== 'dead') {
      setPhase('dying')
      const t = window.setTimeout(() => setPhase('dead'), 640)
      return () => window.clearTimeout(t)
    }
    setPhase(target)
  }, [target])

  return { phase, flash }
}

function Row({ m }: { m: SquadMember }) {
  const { phase, flash } = useDeathSequence(m)

  const dead = phase === 'dead'
  const dying = phase === 'dying'
  const downed = phase === 'down'

  // Draining to zero is what the eye actually reads as death; the numbers are
  // already gone from the payload by then, so the phase drives it.
  const hp = dead || dying ? 0 : Math.max(0, Math.min(1, m.hp / 100))
  const sh = dead || dying ? 0 : Math.max(0, Math.min(1, (m.armour ?? 0) / 100))

  return (
    <div className="relative flex items-center gap-2" style={{ opacity: dead ? 0.34 : 1,
      transition: 'opacity 460ms ease' }}>
      {flash > 0 && <div key={flash} className="mate-flash" />}

      <span
        className={`w-1.5 h-6 rounded-full shrink-0${downed ? ' mate-pulse' : ''}`}
        style={{ background: m.colour }}
      />

      <div className="flex-1 min-w-0">
        <div className="flex items-baseline justify-between gap-2">
          <span className="text-[0.6875rem] font-semibold truncate">{m.name}</span>
          {(dead || downed) && (
            <span
              key={dead ? 'out' : 'down'}
              className="mate-stamp text-[0.625rem] font-semibold tracking-wider"
              style={{ color: dead ? 'rgba(255,255,255,0.5)' : 'var(--color-danger)' }}
            >
              {dead ? 'OUT' : 'DOWN'}
            </span>
          )}
        </div>

        {!dead && (
          <>
            <div className="h-1 mt-0.5 rounded-full bg-black/55 overflow-hidden">
              <div
                className={`bar-fill h-full rounded-full${dying ? ' mate-drain' : ''}`}
                style={{
                  width: '100%',
                  transform: `scaleX(${hp})`,
                  background: downed ? 'var(--color-danger)' : 'var(--color-hp)',
                }}
              />
            </div>
            <div className="h-1 mt-0.5 rounded-full bg-black/55 overflow-hidden">
              <div
                className={`bar-fill h-full rounded-full${dying ? ' mate-drain' : ''}`}
                style={{
                  width: '100%',
                  transform: `scaleX(${sh})`,
                  background: 'var(--color-shield)',
                }}
              />
            </div>
          </>
        )}
      </div>
    </div>
  )
}

export default function SquadPanel({ squad }: { squad: SquadPayload }) {
  // Unchanged and load-bearing: a solo player has no squad panel, and the
  // party-vs-squad fallback that feeds this channel is what made the worst M2
  // bug. Do not widen this test.
  if (!squad.id || squad.members.length <= 1) return null

  return (
    <div className="panel px-3 py-2 flex flex-col gap-1.5">
      {squad.members.map((m) => <Row key={m.src} m={m} />)}
    </div>
  )
}
