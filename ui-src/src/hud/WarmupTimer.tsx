import { useEffect, useRef } from 'react'
import { useUi, selMatch } from '../store'

/**
 * Warmup countdown.
 *
 * Warmup is the one state where the player is standing around with nothing to
 * do and no idea how long it lasts. Without a number on screen it is impossible
 * to tell a warmup from a stuck server -- which is the same complaint the queue
 * screen had before it showed its counts.
 *
 * The value is derived locally from `endsAt`; the server sends that once per
 * transition and never ticks a countdown over the bridge. It can also move
 * EARLIER, when a full lobby cuts the wait short, which arrives as an ordinary
 * state rebroadcast and needs no special handling here.
 *
 * Like StormBar, the digits are written straight to a DOM node from one
 * requestAnimationFrame loop rather than through setState -- a re-render per
 * frame for a two-character number is exactly the tax the HUD rules exist to
 * avoid.
 */
export default function WarmupTimer() {
  const match = useUi(selMatch)
  const offset = useUi((s) => s.clockOffset)
  const timeRef = useRef<HTMLSpanElement>(null)

  const showing = match.state === 'warmup'
  const endsAt = match.endsAt

  useEffect(() => {
    if (!showing || !endsAt) return
    let raf = 0

    const tick = () => {
      const node = timeRef.current
      if (node) {
        // endsAt is a SERVER timestamp; comparing it to the browser's wall
        // clock directly would be comparing two unrelated origins.
        const left = Math.max(0, endsAt - (Date.now() + offset))
        const total = Math.ceil(left / 1000)
        const next = total >= 60
          ? `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
          : String(total)
        if (node.textContent !== next) node.textContent = next
      }
      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [showing, endsAt, offset])

  if (!showing) return null

  return (
    <div className="panel px-4 py-2 flex items-baseline gap-3">
      <span className="text-[0.625rem] uppercase tracking-[0.18em] text-white/45">
        Warmup
      </span>
      <span ref={timeRef} className="font-display text-lg tabular-nums leading-none">
        --
      </span>
      <span className="text-[0.6875rem] text-white/40">until drop</span>
    </div>
  )
}
