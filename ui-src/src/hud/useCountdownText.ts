import { useEffect } from 'react'
import type { RefObject } from 'react'
import { startCountdown } from './countdown'

/**
 * WRITE A DRIFT-CORRECTED TEXT COUNTDOWN INTO A DOM NODE (#319).
 *
 * The shared glue between the storm bar and the warmup timer. Both used to carry
 * their own `requestAnimationFrame` loop that recomputed a two-character number
 * every frame and wrote it to a node through a ref; both are now this one hook,
 * which arms a single `setTimeout` to the next displayed-second boundary and
 * lets `startCountdown` recompute from the real clock on every wake. The number
 * on screen is identical; the loop between updates is gone.
 *
 * ═══ WHY A REF AND NOT setState ═══
 *
 * Unchanged from the loops it replaces, and it is the reason they existed: a
 * re-render per tick to move two characters is exactly the tax the HUD rules
 * avoid. The node is written directly, only when the text actually changes, so
 * React never re-renders for the clock. `HotTime` renders the `--` placeholder
 * and hands its element back through the ref; this hook owns the digits from
 * there.
 *
 * ═══ WHAT DRIVES A RE-ARM ═══
 *
 * The effect depends on `endsAt`, `offset` and `enabled`, so a new server
 * deadline (warmup cut short by a full lobby, a fresh storm phase), a re-synced
 * clock offset, or the surface being shown/hidden all tear down the pending
 * timer and start again immediately -- the same immediate reaction the RAF
 * dependency arrays gave. `endsAt === 0` means "no deadline yet" and arms
 * nothing, matching the `if (!endsAt) return` guard both components had.
 *
 * `Date.now`, `setTimeout` and `clearTimeout` are passed to the pure driver
 * here; the driver itself has no timer API of its own, which is what keeps it
 * testable without a DOM.
 */
export function useCountdownText<T extends HTMLElement>(
  ref: RefObject<T | null>,
  endsAt: number,
  offset: number,
  enabled = true,
): void {
  useEffect(() => {
    if (!enabled || !endsAt) return
    return startCountdown(
      endsAt,
      offset,
      (text) => {
        const node = ref.current
        // Only touch the DOM when the rendered text actually changes -- the
        // write-guard the loops carried, kept for the same reason.
        if (node && node.textContent !== text) node.textContent = text
      },
      Date.now,
      (cb, ms) => setTimeout(cb, ms),
      (handle) => clearTimeout(handle),
    )
  }, [ref, endsAt, offset, enabled])
}
