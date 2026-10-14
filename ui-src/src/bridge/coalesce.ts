/**
 * NETWORK HYGIENE FOR CEF 144 (#413), the two pure halves; scripts/test-cef.mjs
 * runs both.
 *
 * Cfx's note for the CEF 103 -> 144 move: network requests are throttled under
 * heavy volume. Every NUI callback is a request, so the two places this page
 * could send one per event are bounded here rather than left to find the
 * throttle on a player's machine.
 */

/**
 * ONE REQUEST IN FLIGHT, AND EVERYTHING THAT ARRIVES MEANWHILE ADDED UP.
 *
 * The locker's drag-to-turn sent a request on every pointermove: 60 to 240 a
 * second while a mouse is moving. Here the first delta goes at once; while it
 * is out, later deltas are summed, and the sum goes the moment the answer is
 * back. Nothing is dropped -- the ped turns exactly as far as the mouse moved,
 * in as many requests as the round trip allows (about one a frame), and a
 * release sends nothing extra because the remainder is already queued.
 *
 * `send` may reject; the next send still goes.
 */
export interface Accumulator {
  add(delta: number): void
}

export function oneInFlight(send: (total: number) => Promise<unknown>): Accumulator {
  let pending = 0
  let busy = false
  const pump = (): void => {
    if (busy || pending === 0) return
    const total = pending
    pending = 0
    busy = true
    const done = (): void => { busy = false; pump() }
    send(total).then(done, done)
  }
  return {
    add(delta: number): void {
      if (!Number.isFinite(delta) || delta === 0) return
      pending += delta
      pump()
    },
  }
}

/**
 * THE ERROR SINK'S OWN LIMIT.
 *
 * bridge/nui.ts's reportError posted every error to Lua, one request each, and
 * a fetchNui that times out reports itself -- so under the throttle, slow
 * callbacks made error reports that made callbacks slower. Now one report of a
 * given context and message per window, and at most `limit` reports of any kind
 * per window; whatever is held back is counted, and the count rides on the next
 * report that goes (or on the summary nui.ts sends when the window closes).
 */
export interface ErrorGate {
  /** true: send this report. false: counted and held back. */
  admit(key: string, now: number): boolean
  /** How many were held back since the last call, and reset to zero. */
  takeHeld(): number
}

export function createErrorGate(limit = 10, windowMs = 60_000): ErrorGate {
  let start = Number.NEGATIVE_INFINITY
  let sent = 0
  let held = 0
  const last = new Map<string, number>()
  return {
    admit(key: string, now: number): boolean {
      if (now - start >= windowMs) {
        start = now
        sent = 0
        for (const [k, t] of last) if (now - t >= windowMs) last.delete(k)
      }
      const prev = last.get(key)
      if ((prev !== undefined && now - prev < windowMs) || sent >= limit) {
        held++
        return false
      }
      sent++
      last.set(key, now)
      return true
    },
    takeHeld(): number {
      const n = held
      held = 0
      return n
    },
  }
}
