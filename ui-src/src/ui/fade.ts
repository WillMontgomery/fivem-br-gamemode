/**
 * A FADE THAT ENDS WHERE IT WAS GOING, WHETHER THE ANIMATION CLOCK DOES OR NOT
 * (#252).
 *
 * Owner, 2026-10-03: "the lobby UI doesn't go away when getting into warmup -
 * it only happens if you sit AFK in lobby for a long time, like 30+ minutes or
 * so". His log had the whole Lua side of the ready-up in order, and the page
 * alive enough to answer the curtain's handshake -- so the page HAD the warmup
 * state. What it did not do was take the lobby off the screen.
 *
 * THE LOBBY CAME DOWN BY A CSS TRANSITION AND BY NOTHING ELSE. Its root went to
 * `opacity: 0` over 200ms, and `visibility: hidden` was itself a transition,
 * delayed by those 200ms. Both are run by the browser's animation clock. JS
 * timers, fetch and message delivery are not -- and in this page they are the
 * things that kept working. Stop that clock in a real Chromium and the page
 * does what the owner saw: the store says warmup, `aria-hidden` says true, and
 * the menu stays drawn with nothing in any log for as long as you care to wait.
 * The curtain is worse, because its "I am black" report has a timer fallback:
 * Lua is told the screen is covered while the curtain is still at opacity 0.
 *
 * SO THE END OF A FADE IS NOW APPLIED BY A TIMER, NOT REACHED BY ONE. Once a
 * fade's own duration (plus a margin) has passed on the JS clock, the layer
 * drops its `transition` and is simply given its final value. In a healthy
 * page the transition finished a hundred milliseconds earlier and nothing
 * moves. In a page whose animation clock has stopped, a pending transition is
 * cancelled by that same style change and the final value lands on the next
 * frame. The fade in front of it is untouched: every layer still dissolves
 * exactly as it did.
 *
 * WHAT THIS CANNOT REACH, said plainly: a page that is producing no frames at
 * all. Nothing on this side draws a frame the compositor will not take. The
 * screen report (bridge/useScreenReport.ts) counts frames for that reason.
 *
 * NO RUNTIME IMPORTS, so node runs this file as-is (scripts/test-fade.mjs).
 */

/** How long past a fade's own duration before its end state is applied outright. */
export const FADE_SETTLE_MARGIN_MS = 100

/**
 * One layer's fade, as a level rather than an edge.
 *
 * `want` is fed the LATEST value on every render and does nothing unless that
 * value changed -- so a layer re-rendering ten times a second cannot hold its
 * own fade open, and a change always restarts the window from the moment it
 * was seen. `poll` is asked by the timer AND by every envelope that arrives
 * while the fade is open, so a timer that never fired is not the end of it.
 */
export interface FadeClock {
  /** The value the layer is going to. */
  readonly shown: boolean
  /** True once that value has been held for the whole window. */
  readonly settled: boolean
  /** Feed the latest wanted value. True if it changed, which reopens the window. */
  want(shown: boolean): boolean
  /** Settle if the window has passed. Returns whether it is settled. */
  poll(): boolean
  /** Milliseconds until the window passes; 0 once due or settled. */
  remaining(): number
}

/**
 * The fade clock's default: MONOTONIC, never the wall clock.
 *
 * It was `Date.now`, and a fallback that exists for long idles is the worst
 * place for a wall clock: a long idle is when Windows resyncs the system time.
 * Stepped back, the settle would wait out the step; stepped forward, a healthy
 * fade would be cut short. `performance.now` only moves forward, at the rate
 * time passes (round 1's review, #252).
 */
export const monotonicNow = (): number => performance.now()

/**
 * @param shown     the value the layer starts at -- settled, since a layer is
 *                  not mid-fade on the frame it mounts
 * @param windowMs  the fade's duration plus FADE_SETTLE_MARGIN_MS
 * @param now       the clock, injectable so the suite can idle for 87 minutes
 *                  without waiting for them
 */
export function createFadeClock(
  shown: boolean,
  windowMs: number,
  now: () => number = monotonicNow,
): FadeClock {
  let target = shown
  let settled = true
  let since = now()

  return {
    get shown() { return target },
    get settled() { return settled },

    want(next) {
      if (next === target) return false
      target = next
      settled = false
      since = now()
      return true
    },

    poll() {
      if (!settled && now() - since >= windowMs) settled = true
      return settled
    },

    remaining() {
      return settled ? 0 : Math.max(0, windowMs - (now() - since))
    },
  }
}

/** A full-screen layer that both fades and stops being a hit target. */
export interface FadeStyle {
  opacity: number
  visibility: 'visible' | 'hidden'
  transition: string
}

/**
 * The lobby root's three properties, for every point of its fade.
 *
 * WHILE THE FADE RUNS, exactly what the lobby has always drawn: opacity over
 * `ms`, and on the way out `visibility` held for the length of the fade so the
 * menu dissolves instead of popping (see the note in Lobby.tsx).
 *
 * ONCE SETTLED, the same final values with no transition at all. That is the
 * whole of the fix: the end state stops depending on an animation finishing.
 */
export function fadeStyle(shown: boolean, settled: boolean, ms: number): FadeStyle {
  if (settled) {
    return {
      opacity: shown ? 1 : 0,
      visibility: shown ? 'visible' : 'hidden',
      transition: 'none',
    }
  }
  return shown
    ? { opacity: 1, visibility: 'visible', transition: `opacity ${ms}ms linear` }
    : {
        opacity: 0,
        visibility: 'hidden',
        transition: `opacity ${ms}ms linear, visibility 0s linear ${ms}ms`,
      }
}
