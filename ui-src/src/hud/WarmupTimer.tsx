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

  // THE SAME OBJECT AS THE STORM BAR (owner's call, 2026-08-09). Both are the
  // top-centre clock -- one before the match, one during it -- and they were
  // two different widgets: a flat `.panel` reading label-number-caption on one
  // line, and a `.panel-hot` placard with a coloured cap over a big numeral.
  // Sharing the placard means a player learns to read the top of the screen
  // once, and the handover from warmup to storm is the same card changing what
  // it counts rather than one widget being replaced by another.
  //
  // Its cap is neutral: nothing about warmup is urgent, and the cap colour is
  // what the storm bar uses to say that something is.
  return (
    <div
      className="panel-hot"
      style={{
        minWidth: '13rem',
        ['--hot' as string]: 'rgba(120,132,160,0.85)',
      }}
    >
      <div className="cap">Dropping in</div>
      <div className="hotbody">
        <span
          ref={timeRef}
          className="font-display block leading-none tabular-nums"
          style={{ fontSize: '1.4rem', textShadow: 'var(--shadow-text)' }}
        >
          --
        </span>
        <span className="text-[0.55rem] font-semibold uppercase tracking-[0.18em] text-white/50">
          warmup
        </span>
      </div>
    </div>
  )
}
