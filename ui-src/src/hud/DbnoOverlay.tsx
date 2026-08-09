import { useEffect, useRef } from 'react'
import type { DbnoPayload } from '../bridge/types'

/**
 * Downed-but-not-out overlay.
 *
 * Like the storm countdown, the bleed-out timer is driven by one rAF loop
 * writing to refs rather than by React state.
 */
export default function DbnoOverlay({ dbno }: { dbno: DbnoPayload }) {
  const timeRef = useRef<HTMLSpanElement>(null)
  const barRef = useRef<HTMLDivElement>(null)
  const endsAt = dbno.bleedEndsAt

  useEffect(() => {
    if (!endsAt) return
    let raf = 0
    const total = Math.max(1, endsAt - Date.now())

    const tick = () => {
      const left = Math.max(0, endsAt - Date.now())
      if (timeRef.current) {
        const s = Math.ceil(left / 1000)
        const txt = `${s}s`
        if (timeRef.current.textContent !== txt) timeRef.current.textContent = txt
      }
      if (barRef.current) {
        barRef.current.style.transform = `scaleX(${left / total})`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [endsAt])

  return (
    <div className="absolute inset-x-0 bottom-40 flex justify-center">
      <div
        className="panel px-6 py-3 text-center"
        style={{ borderColor: 'var(--color-danger-edge)' }}
      >
        <div className="text-[0.625rem] uppercase tracking-[0.24em] text-white/50">
          You are down
        </div>

        <div className="font-display text-4xl my-1 tabular-nums" style={{ color: 'var(--color-danger)' }}>
          <span ref={timeRef}>--</span>
        </div>

        <div className="h-1.5 w-52 rounded-full bg-black/55 overflow-hidden">
          <div
            ref={barRef}
            className="h-full rounded-full"
            style={{
              width: '100%',
              transformOrigin: 'left center',
              background: 'var(--color-danger)',
            }}
          />
        </div>

        {dbno.reviverName && (
          <div className="mt-2 text-xs text-white/80">
            {dbno.reviverName} is reviving you &mdash; {Math.round(dbno.revivePct)}%
          </div>
        )}
      </div>
    </div>
  )
}
