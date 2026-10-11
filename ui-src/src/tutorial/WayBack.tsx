/**
 * The way back to the walkthrough, ringed and focused (#405).
 *
 * Owner, 2026-10-11: "If at any point during the lobby tutorial they open the
 * menu using ESC, direct their focus to the 'back to lobby' button." Escape on
 * the lobby opens our pause menu, and the card waits under it the way every lobby
 * card waits under a screen it is not about. This is what waits with it: the
 * walkthrough's own ring around the control that leads back (LOBBY_WAYS_BACK in
 * steps.ts), and the keyboard's focus on that control, so Enter is the way back
 * too.
 *
 * NO CARD AND NO WORDS -- the ring is the direction. And no lock: the pause menu
 * keeps Leave server, so nobody is held in a walkthrough they want out of.
 *
 * MEASURED EVERY FRAME, LIKE THE CARD'S RING, for exactly as long as the menu is
 * up over a walkthrough. Focused once, on the first frame the control exists.
 */

import { useEffect, useRef, useState } from 'react'

import type { Rect } from './cardPlacement'
import { CONTROLS } from './lock'

export default function WayBack({ target }: { target: string }) {
  const [rect, setRect] = useState<Rect | null>(null)
  const last = useRef<Rect | null>(null)

  useEffect(() => {
    let raf = 0
    let focused = false
    const tick = () => {
      const el = document.querySelector<HTMLElement>(`[data-tut="${target}"]`)
      const b = el?.getBoundingClientRect()
      const next = el && b && b.width > 0 && b.height > 0
        ? { x: b.left, y: b.top, w: b.width, h: b.height }
        : null
      const prev = last.current
      if (next === null ? prev !== null
          : prev === null || Math.abs(prev.x - next.x) >= 0.5 || Math.abs(prev.y - next.y) >= 0.5
            || Math.abs(prev.w - next.w) >= 0.5 || Math.abs(prev.h - next.h) >= 0.5) {
        last.current = next
        setRect(next)
      }
      if (el && !focused) {
        const c = el.matches(CONTROLS) ? el : el.querySelector<HTMLElement>(CONTROLS)
        if (c) { c.focus(); focused = true }
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [target])

  if (rect === null) return null
  return (
    <div
      className="tut-ring tut-ring--click"
      style={{ left: rect.x - 4, top: rect.y - 4, width: rect.w + 8, height: rect.h + 8 }}
    />
  )
}
