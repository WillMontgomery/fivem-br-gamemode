/**
 * NETWORK HYGIENE FOR CEF 144 (#413), the pure halves; scripts/test-cef.mjs
 * runs each one, and holds bridge/nui.ts and settings/apply.ts to using them.
 *
 * Cfx's note for the CEF 103 -> 144 move: network requests are throttled under
 * heavy volume. Every NUI callback is a request, so the three places this page
 * could send one per input event are bounded here rather than left to find the
 * throttle on a player's machine: the locker spin, the error sink, and the
 * palette a Settings slider re-sent at every step.
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

/**
 * SENT ONLY WHEN IT CHANGED.
 *
 * settings/apply.ts reports the resolved palette (the green and the volts
 * orange) to Lua on every settings apply, and a Settings slider applies at
 * every step: 100 steps on a volume slider, one request each, at the speed of
 * the drag, for a value only the colorblind mode can change. Here a value
 * goes when its key differs from the last one that went.
 *
 * Two ways back to sending the same value again, so a dedup never strands a
 * reader on a stale one:
 *   - a send that fails or answers nothing (fetchNui's null) forgets it, so
 *     the next apply retries -- as every apply did before;
 *   - `forget()`, for the caller that knows a reader needs it again (Lua's
 *     settings push, which is also br_core's answer after its own restart).
 */
export interface ChangeGate<T> {
  offer(value: T): void
  forget(): void
}

export function changesOnly<T>(
  keyOf: (value: T) => string,
  send: (value: T) => Promise<unknown>,
): ChangeGate<T> {
  let last: string | null = null
  return {
    offer(value: T): void {
      const key = keyOf(value)
      if (key === last) return
      last = key
      const lost = (): void => { if (last === key) last = null }
      send(value).then((answer) => { if (answer === null || answer === undefined) lost() }, lost)
    },
    forget(): void {
      last = null
    },
  }
}
