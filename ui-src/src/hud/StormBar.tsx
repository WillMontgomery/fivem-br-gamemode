import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import type { StormPayload } from '../bridge/types'

/**
 * Storm phase readout and countdown.
 *
 * The countdown is the clearest example of the performance rule in this project:
 * it updates every frame, but it does NOT go through React. One requestAnimationFrame
 * loop writes directly to a DOM node via a ref. Driving it with setState would
 * re-render this component 60 times a second for a number that occupies about
 * forty pixels.
 *
 * The value is computed locally from `endsAt`, a server timestamp. The server
 * sends that once per phase change -- it never ticks a countdown over the bridge.
 */
export default function StormBar({ storm }: { storm: StormPayload | null }) {
  const timeRef = useRef<HTMLSpanElement>(null)
  const arrowRef = useRef<HTMLDivElement>(null)
  const offset = useUi((s) => s.clockOffset)
  const endsAt = storm?.endsAt ?? 0
  const bearing = storm?.bearing ?? 0

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
      if (arrowRef.current) {
        arrowRef.current.style.transform = `rotate(${bearing}deg)`
      }
      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [endsAt, bearing])

  if (!storm) return null

  const shrinking = storm.phaseState === 'shrinking'
  const outside = storm.edgeDistance > 0

  return (
    <div className="panel px-4 py-2 flex items-center gap-3 min-w-[15rem]">
      <div
        ref={arrowRef}
        className="w-5 h-5 shrink-0 transition-transform duration-150"
        style={{ color: outside ? 'var(--color-danger)' : 'var(--color-storm)' }}
        title="Direction to the safe zone"
      >
        <svg viewBox="0 0 24 24" fill="currentColor" aria-hidden>
          <path d="M12 2 L19 20 L12 16 L5 20 Z" />
        </svg>
      </div>

      <div className="flex-1">
        <div className="flex items-baseline justify-between gap-3">
          <span className="text-[0.625rem] uppercase tracking-[0.18em] text-white/45">
            {shrinking ? 'Storm closing' : `Phase ${storm.phase}`}
          </span>
          <span
            ref={timeRef}
            className="text-lg font-bold tabular-nums leading-none"
            style={{ color: shrinking ? 'var(--color-storm)' : 'white' }}
          >
            --
          </span>
        </div>
        <div className="text-[0.6875rem] text-white/55 mt-0.5">
          {outside
            ? <span style={{ color: 'var(--color-danger)' }}>
                {Math.round(storm.edgeDistance)}m outside &mdash; move
              </span>
            : <span>{Math.round(-storm.edgeDistance)}m inside &middot; r {Math.round(storm.radius)}m</span>}
        </div>
      </div>
    </div>
  )
}
