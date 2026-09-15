/**
 * TEXT COUNTDOWN SCHEDULING, AS PURE ARITHMETIC (#319).
 *
 * The storm bar and the warmup timer each used to run a `requestAnimationFrame`
 * loop that recomputed a two-character number sixty times a second and wrote it
 * to a DOM node only when it changed. The write-guard meant the SCREEN updated
 * once a second, but the LOOP still woke every frame forever -- a perpetual
 * timer whose only job, 59 frames out of 60, was to decide it had nothing to do.
 *
 * A countdown's displayed value changes on a schedule that is known exactly the
 * moment you read the clock: it is `ceil(msLeft / 1000)`, and it steps down when
 * `msLeft` crosses the next whole-second boundary below it. So instead of a
 * frame loop, schedule ONE timer to that boundary, recompute from the
 * server-corrected clock when it fires, and schedule the next. That is
 * drift-corrected by construction -- every wake reads the real clock rather than
 * assuming the last timer fired on time -- so a late or throttled timer (a
 * backgrounded tab, a stalled frame) simply lands on the correct number and
 * carries on, rather than falling behind by the amount it was delayed.
 *
 * ═══ WHY THIS FILE HAS NO IMPORTS ═══
 *
 * Everything here is arithmetic over numbers and strings. It touches no DOM, no
 * React, no timer API -- those are injected into `startCountdown` by the caller.
 * That is what lets `scripts/test-countdown.mjs` load this `.ts` file directly
 * under node's type-stripping (on by default since 22.18), the same way
 * `test-envelope.mjs` loads `bridge/envelope.ts`. A DOM test runner would have
 * been a new dependency in a repo whose every other suite is a plain script.
 *
 * The React wiring -- a ref to write through, `setTimeout`, `Date.now` -- lives
 * in `useCountdownText.ts`, which is the one line of glue this cannot be tested
 * through.
 */

/**
 * Milliseconds remaining until `endsAt`, floored at zero, on the server clock.
 *
 * `endsAt` is a SERVER timestamp. The browser's wall clock shares no origin with
 * it, so `offset` (the store's `clockOffset`, `serverNow - Date.now()`) is what
 * makes the subtraction mean anything -- the rule StormBar, WarmupTimer, the
 * bleed-out card and the rescue timer all follow. Never compare `endsAt` to a
 * bare `Date.now()`.
 */
export function msRemaining(endsAt: number, now: number, offset: number): number {
  return Math.max(0, endsAt - (now + offset))
}

/**
 * The displayed whole-second count: seconds remaining, rounded UP.
 *
 * Rounding up is what the RAF loops did (`Math.ceil(left / 1000)`) and it is the
 * honest choice: while any part of a second is left, that second is still shown.
 * The value is `k` for `msLeft` in `((k-1)*1000, k*1000]`, and exactly `0` at
 * `msLeft === 0`.
 */
export function displayedSeconds(msLeft: number): number {
  return Math.ceil(msLeft / 1000)
}

/**
 * Format a whole-second count for the two top-centre clocks.
 *
 * Bare seconds below a minute (`7`, `59`), `m:ss` at a minute and above
 * (`1:00`, `2:05`). This is the exact rule both StormBar and WarmupTimer carried
 * inline -- StormBar wrote `m > 0 ? ... : \`${sec}\`` and WarmupTimer wrote
 * `total >= 60 ? ... : String(total)`, which are the same function of the same
 * number. The width never jumps at the boundary because below a minute there is
 * no colon to appear.
 *
 * Negative input is clamped to zero rather than rendering a `-1`; a countdown
 * that has been handed a bad number should read as expired, not as broken.
 */
export function formatCountdown(totalSeconds: number): string {
  const s = totalSeconds > 0 ? Math.floor(totalSeconds) : 0
  if (s >= 60) {
    const m = Math.floor(s / 60)
    return `${m}:${String(s % 60).padStart(2, '0')}`
  }
  return String(s)
}

/**
 * Milliseconds until the displayed second next changes, given ms remaining.
 *
 * The display shows `d = ceil(msLeft / 1000)` and steps to `d - 1` when `msLeft`
 * reaches `(d - 1) * 1000`. So the wait is `msLeft - (d - 1) * 1000`, which is
 * always in `(0, 1000]` for `msLeft > 0` -- a partial second the first time, a
 * full second thereafter.
 *
 * Returns `0` when `msLeft <= 0`: there is nothing left to count, so the caller
 * stops scheduling rather than arming a timer for a number that will not change.
 */
export function msToNextBoundary(msLeft: number): number {
  if (msLeft <= 0) return 0
  const d = Math.ceil(msLeft / 1000)
  return msLeft - (d - 1) * 1000
}

/** One reading of a countdown: what to show, whether it is over, when to wake next. */
export interface CountdownStep {
  /** The formatted text to display now. */
  text: string
  /** True once the deadline has passed -- show `text` ("0"/"0:00") and stop. */
  done: boolean
  /** Milliseconds until the display next changes; `0` when `done`. */
  delayMs: number
}

/**
 * Read the countdown once against the server-corrected clock.
 *
 * This is the whole per-wake computation, factored out so a test can assert the
 * text and the next delay together for any `(endsAt, now, offset)` without a
 * timer in sight.
 */
export function countdownStep(endsAt: number, now: number, offset: number): CountdownStep {
  const left = msRemaining(endsAt, now, offset)
  return {
    text: formatCountdown(displayedSeconds(left)),
    done: left <= 0,
    delayMs: msToNextBoundary(left),
  }
}

/**
 * Drive a text countdown to its displayed-second boundaries until it expires.
 *
 * The timer API is injected, not imported, so this same driver runs against real
 * `setTimeout`/`Date.now` in the browser (see `useCountdownText.ts`) and against
 * a hand-wound fake clock in the tests. The generic `H` is the timer handle type
 * -- a `number` for the fake, `ReturnType<typeof setTimeout>` in the browser.
 *
 * Behaviour, and every clause is asserted in `scripts/test-countdown.mjs`:
 *   - it writes the current text IMMEDIATELY, before arming any timer, so the
 *     `--` placeholder is replaced on the first commit rather than a frame late;
 *   - each wake recomputes `msLeft` from `now()`, so a timer that fires late or
 *     after the tab was throttled lands on the CORRECT number and reschedules to
 *     the next boundary -- it never replays the seconds it slept through;
 *   - when the deadline has passed it writes the terminal text ("0"/"0:00") and
 *     returns WITHOUT arming another timer -- no perpetual loop past zero;
 *   - the returned disposer clears any pending timer, which is the cleanup the
 *     React effect needs on unmount and on a changed deadline/offset.
 *
 * @returns a disposer that cancels the pending timer.
 */
export function startCountdown<H>(
  endsAt: number,
  offset: number,
  write: (text: string) => void,
  now: () => number,
  setTimer: (cb: () => void, ms: number) => H,
  clearTimer: (handle: H) => void,
): () => void {
  let handle: H | undefined
  let disposed = false

  const run = (): void => {
    const { text, done, delayMs } = countdownStep(endsAt, now(), offset)
    write(text)
    if (done || disposed) return
    handle = setTimer(run, delayMs)
  }

  run()

  return () => {
    disposed = true
    if (handle !== undefined) clearTimer(handle)
  }
}
