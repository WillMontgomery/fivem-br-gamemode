import { useEffect, useRef } from 'react'
import type React from 'react'
import { holdDelay } from './model'

/**
 * A BUTTON THAT REPEATS WHILE HELD (owner's point 1, 2026-10-13: "next/last
 * stays, with hold-to-scroll").
 *
 * The press acts at once; held, it acts again after `delay(1)`, then after
 * `delay(2)`, and so on -- model.ts holdDelay, which waits, then accelerates
 * to a floor -- until the pointer lets go, leaves the button, or is taken
 * away. A keyboard press (Enter, Space: a click with no pointer down before
 * it) acts once.
 *
 * Returns the props to spread on the <button>.
 */
export function useHold(
  act: (n: number) => void, delay: (n: number) => number = holdDelay, disabled = false,
) {
  const live = useRef(act)
  live.current = act
  const timer = useRef<number | null>(null)

  const stop = () => {
    if (timer.current !== null) window.clearTimeout(timer.current)
    timer.current = null
  }
  useEffect(() => stop, [])
  useEffect(() => { if (disabled) stop() }, [disabled])

  /** The nth repeat (n >= 1) is due after delay(n). */
  const repeat = (n: number) => {
    timer.current = window.setTimeout(() => {
      live.current(n)
      repeat(n + 1)
    }, delay(n))
  }

  return {
    onPointerDown: (e: React.PointerEvent) => {
      if (disabled || e.button !== 0) return
      stop()
      live.current(0)
      repeat(1)
    },
    onPointerUp: stop,
    onPointerLeave: stop,
    onPointerCancel: stop,
    onClick: (e: React.MouseEvent) => {
      // A pointer's click (detail 1 and up) was acted on at its press; a
      // click with no pointer (detail 0) is the keyboard's.
      if (!disabled && e.detail === 0) live.current(0)
    },
  }
}
