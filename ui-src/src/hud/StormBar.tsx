import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import type { StormPayload } from '../bridge/types'

/**
 * Storm readout: a label and a countdown. Nothing else, deliberately --
 * the arrow this used to carry pointed relative to the PED, not the camera,
 * which read as wrong more often than right; direction now lives on the
 * minimap itself (a purple centre blip that clamps to the minimap's edge
 * when the circle is off-screen), and phase/radius numbers were dashboard
 * detail nobody rotates by.
 *
 * The countdown updates every frame but does NOT go through React: one
 * requestAnimationFrame loop writes to a DOM node via a ref. The value is
 * computed locally from `endsAt`, a server timestamp, against the synced
 * clock offset -- the server never ticks a countdown over the bridge.
 */
export default function StormBar({ storm }: { storm: StormPayload | null }) {
  const timeRef = useRef<HTMLSpanElement>(null)
  const offset = useUi((s) => s.clockOffset)
  const endsAt = storm?.endsAt ?? 0

  useEffect(() => {
    if (!endsAt) return
    let raf = 0

    const tick = () => {
      const node = timeRef.current
      if (node) {
        // endsAt is a SERVER timestamp, same contract as the warmup timer --
        // comparing it to the raw browser clock would be comparing two
        // unrelated origins.
        const left = Math.max(0, endsAt - (Date.now() + offset))
        const total = Math.ceil(left / 1000)
        const m = Math.floor(total / 60)
        const sec = total % 60
        const next = m > 0 ? `${m}:${String(sec).padStart(2, '0')}` : `${sec}s`
        // Only touch the DOM when the rendered text actually changes.
        if (node.textContent !== next) node.textContent = next
      }
      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [endsAt, offset])

  if (!storm) return null

  const shrinking = storm.phaseState === 'shrinking'
  const hurting = storm.edgeDistance > 0 && (storm.dps ?? 0) > 0

  // The PHASE-1 hold with minutes on the clock is loot time, not
  // information -- the countdown notices carry it. From the moment the
  // first shrink begins, the bar is PERMANENT: every later hold and shrink
  // keeps the timer on screen (user call, 2026-08-04). The storm envelope
  // re-renders this at 4Hz, so the threshold crossing lands within a
  // quarter second.
  const msLeft = endsAt ? endsAt - (Date.now() + offset) : 0
  if (storm.phase === 1 && !shrinking && !hurting && msLeft > 60_000) return null

  // The label tells you what the number MEANS -- a bare "10s" told nobody
  // anything. Holding: time until the wall starts moving. Shrinking: time
  // until it stops.
  const label = shrinking ? 'Storm closing now' : 'Storm moving in'

  // TWO STATES, CROSSFADED (user call, 2026-08-04): inside, the label and
  // countdown; caught outside, a pulsing imperative and NO timer -- when
  // you are in the storm the number that matters is your health, not the
  // wall's schedule. The keyed swap restarts the fade both directions.
  return (
    <div className="panel px-4 py-2">
      {hurting ? (
        <div
          key="out"
          className="stormbar-swap storm-warning text-sm font-black uppercase tracking-[0.18em] leading-none"
        >
          Get out of the storm!
        </div>
      ) : (
        <div key="in" className="stormbar-swap flex items-baseline gap-3">
          <span
            className="text-[0.625rem] uppercase tracking-[0.18em]"
            style={{ color: 'rgba(255,255,255,0.45)' }}
          >
            {label}
          </span>
          <span
            ref={timeRef}
            className="text-lg font-bold tabular-nums leading-none"
            style={{ color: shrinking ? 'var(--color-storm)' : 'white' }}
          >
            --
          </span>
        </div>
      )}
    </div>
  )
}
