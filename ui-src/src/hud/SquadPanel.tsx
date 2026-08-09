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

function Row({ m, talking }: { m: SquadMember; talking: boolean }) {
  const { phase, flash } = useDeathSequence(m)

  const dead = phase === 'dead'
  const dying = phase === 'dying'
  const downed = phase === 'down'

  // Draining to zero is what the eye actually reads as death; the numbers are
  // already gone from the payload by then, so the phase drives it.
  const hp = dead || dying ? 0 : Math.max(0, Math.min(1, m.hp / 100))
  const sh = dead || dying ? 0 : Math.max(0, Math.min(1, (m.armour ?? 0) / 100))

  // A MATE IS A PLATE. Each row is its own object carrying that player's
  // colour on its edge, rather than a stripe inside one shared box -- so a
  // four-stack reads as four people at a glance instead of as a list, and the
  // colour is on the thing rather than beside it.
  //
  // `m.colour` IS THAT PLAYER'S BLIP COLOUR, and both the edge and the tab
  // wear it. It used to be the squad's shared colour, which made all four
  // rows identical -- see the note in br_core/client/state.lua. The tab and
  // the outline being the same colour as the dot on the minimap is the whole
  // point: one teammate, one colour, everywhere they appear.
  return (
    <div
      className="plate relative flex items-center gap-2 px-2 py-1.5"
      style={{
        ['--edgec' as string]: dead ? 'rgba(255,255,255,0.14)' : m.colour,
        ['--plate-fill' as string]: downed
          ? 'rgba(52,20,24,0.92)' : 'rgba(20,23,33,0.90)',
        ['--cut-max' as string]: '0.45rem',
        opacity: dead ? 0.34 : 1,
        transition: 'opacity 460ms ease',
      }}
    >
      {flash > 0 && <div key={flash} className="mate-flash" />}

      <span
        className={`w-[0.3rem] self-stretch rounded-sm shrink-0${
          downed ? ' mate-pulse' : ''}`}
        style={{ background: m.colour }}
      />

      <div className="flex-1 min-w-0">
        <div className="flex items-baseline justify-between gap-2">
          <span className="flex items-center gap-1 min-w-0">
            {/* SPEAKING. Voice had no visual at all -- somebody talks and
                nothing on screen says who (owner, 2026-08-09). The name is
                where it belongs: this panel is already the list of who your
                squad IS, and a mark beside a name needs no legend.
                It sits BEFORE the name so it never moves the name around as
                it appears, and it is a filled dot rather than a glyph -- read
                peripherally, in a corner, at 0.72rem. */}
            {talking && (
              <span
                className="shrink-0 rounded-full mate-talk"
                style={{
                  width: '0.34rem', height: '0.34rem',
                  background: 'var(--color-royale-accent)',
                }}
                title={`${m.name} is speaking`}
              />
            )}
            <span className="text-[0.72rem] font-semibold truncate">{m.name}</span>
          </span>
          {(dead || downed) && (
            <span
              key={dead ? 'out' : 'down'}
              className="mate-stamp font-display text-[0.62rem] tracking-[0.18em]"
              style={{ color: dead ? 'rgba(255,255,255,0.5)' : 'var(--color-danger)' }}
            >
              {dead ? 'OUT' : 'DOWN'}
            </span>
          )}
        </div>

        {!dead && (
          <>
            {/* 0.4rem, and it has been raised twice. These began as 1px
                hairlines, went to 0.2rem, and were STILL too thin to read at
                a glance (user, 2026-08-08 -- "this was true before we
                started"). A squadmate's health is something you check in the
                middle of a fight, with your eyes mostly elsewhere; a line you
                have to look at twice is a line you stop looking at. At 0.4rem
                the fill has enough body to carry its colour, which is what
                actually does the reading -- green, red, or nearly gone. */}
            <div className="h-[0.4rem] mt-1 rounded-full bg-black/55 overflow-hidden">
              <div
                className={`bar-fill h-full rounded-full${dying ? ' mate-drain' : ''}`}
                style={{
                  width: '100%',
                  transform: `scaleX(${hp})`,
                  background: downed ? 'var(--color-danger)' : 'var(--color-hp)',
                }}
              />
            </div>
            <div className="h-[0.4rem] mt-[0.2rem] rounded-full bg-black/55 overflow-hidden">
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

export default function SquadPanel({ squad, talking = [] }:
  { squad: SquadPayload; talking?: number[] }) {
  // Unchanged and load-bearing: a solo player has no squad panel, and the
  // party-vs-squad fallback that feeds this channel is what made the worst M2
  // bug. Do not widen this test.
  if (!squad.id || squad.members.length <= 1) return null

  // Read AFTER the early return so a solo player subscribes to nothing --
  // this store field changes whenever anybody starts or stops speaking.
  const talkingSet = new Set(talking)

  // No outer .panel: each row is its own plate now, so a shared box around
  // them was a second frame doing nothing but adding an edge.
  return (
    <div className="flex flex-col gap-1">
      {squad.members.map((m) => (
        <Row key={m.src} m={m} talking={talkingSet.has(m.src)} />
      ))}
    </div>
  )
}
