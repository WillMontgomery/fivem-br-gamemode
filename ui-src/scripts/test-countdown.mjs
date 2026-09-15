#!/usr/bin/env node
/**
 * THE TEXT-COUNTDOWN SCHEDULER'S TESTS (#319).
 *
 * StormBar and WarmupTimer replaced two per-frame requestAnimationFrame loops
 * with one shared, drift-corrected scheduler: `src/hud/countdown.ts` computes
 * the displayed text and the delay to the next displayed-second boundary, and
 * `startCountdown` drives a timer to those boundaries until the deadline passes.
 * These are the deterministic proofs that the arithmetic and the driver behave
 * -- boundary timing, cleanup, a changed deadline/offset, zero, minute
 * formatting, and a throttled timer that wakes late.
 *
 * WHY node RUNS A .ts FILE DIRECTLY. countdown.ts has no runtime imports, so
 * node's type stripping (on by default since 22.18) loads it as-is -- the same
 * reason and the same shape as scripts/test-envelope.mjs, which loads
 * bridge/envelope.ts. No DOM, no jsdom, no vitest: the timer API is injected
 * into `startCountdown`, so a hand-wound fake clock drives it here exactly as
 * `setTimeout`/`Date.now` drive it in the browser.
 *
 * WHAT THIS CANNOT REACH, stated rather than implied: there is no React and no
 * DOM here, so the hook `useCountdownText.ts` -- the ~10 lines that pass the ref
 * writer and the real timer functions into this driver -- is not exercised. It
 * is glue with no branches of its own; everything with a decision in it lives in
 * countdown.ts and is covered below.
 *
 * Run: npm run test:countdown   (and as part of npm run build)
 */

import {
  msRemaining,
  displayedSeconds,
  formatCountdown,
  msToNextBoundary,
  countdownStep,
  startCountdown,
} from '../src/hud/countdown.ts'

let failed = 0
let ran = 0

function ok(name, cond, detail) {
  ran++
  if (cond) return
  failed++
  console.error(`FAIL  ${name}${detail ? `\n      ${detail}` : ''}`)
}

function eq(name, actual, expected) {
  ok(name, actual === expected, `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`)
}

/**
 * A single-slot fake scheduler on a clock the test winds by hand.
 *
 * `startCountdown` only ever has ONE timer pending at a time (it arms the next
 * only after the previous fires), so one slot models it exactly. `advanceTo`
 * winds the clock and fires the pending callback if its deadline has been
 * reached -- and it loops, so winding far past several boundaries in one jump
 * (a throttled or backgrounded tab) fires each successive re-arm in turn, which
 * is precisely the case the drift correction exists for.
 */
function fakeClock(start = 0) {
  let t = start
  let pending = null // { cb, at }
  return {
    now: () => t,
    setTimer: (cb, ms) => { pending = { cb, at: t + ms }; return 1 },
    clearTimer: () => { pending = null },
    // test controls
    advanceTo(ms) {
      t = ms
      // Fire every timer whose deadline is now due. Each callback may arm the
      // next one, so keep going until the pending timer is in the future.
      while (pending && pending.at <= t) {
        const cb = pending.cb
        pending = null
        cb()
      }
    },
    pendingAt: () => (pending ? pending.at : null),
    hasPending: () => pending !== null,
  }
}

/** Record every text a countdown writes, in order. */
function recorder() {
  const writes = []
  return { write: (s) => writes.push(s), writes }
}

// ── msRemaining: the server-corrected clock ────────────────────────────────
eq('msRemaining plain', msRemaining(10_000, 0, 0), 10_000)
eq('msRemaining applies offset', msRemaining(10_000, 3_000, 500), 6_500)
eq('msRemaining floors at zero', msRemaining(1_000, 5_000, 0), 0)
eq('msRemaining negative offset (server ahead)', msRemaining(10_000, 2_000, -1_000), 9_000)

// ── displayedSeconds: round up, and the exact boundary ──────────────────────
eq('displayedSeconds rounds up', displayedSeconds(1), 1)
eq('displayedSeconds 999ms', displayedSeconds(999), 1)
eq('displayedSeconds exactly 1000ms', displayedSeconds(1_000), 1)
eq('displayedSeconds just over 1000ms', displayedSeconds(1_001), 2)
eq('displayedSeconds zero', displayedSeconds(0), 0)

// ── formatCountdown: bare seconds under a minute, m:ss at/above ─────────────
eq('format zero', formatCountdown(0), '0')
eq('format 7s', formatCountdown(7), '7')
eq('format 59s (still bare)', formatCountdown(59), '59')
eq('format 60s (minute boundary)', formatCountdown(60), '1:00')
eq('format 61s', formatCountdown(61), '1:01')
eq('format 125s', formatCountdown(125), '2:05')
eq('format 600s', formatCountdown(600), '10:00')
eq('format 3599s', formatCountdown(3599), '59:59')
eq('format negative clamps to 0', formatCountdown(-5), '0')

// ── msToNextBoundary: THE CRITICAL ARITHMETIC (mutation target) ─────────────
// The wait is always in (0, 1000] while time remains: a partial second first,
// full seconds after. Zero once expired, so the caller stops scheduling.
eq('boundary from 1500ms', msToNextBoundary(1_500), 500)
eq('boundary from a full second', msToNextBoundary(1_000), 1_000)
eq('boundary from 2000ms', msToNextBoundary(2_000), 1_000)
eq('boundary from 2001ms', msToNextBoundary(2_001), 1)
eq('boundary from 1ms', msToNextBoundary(1), 1)
eq('boundary from 999ms', msToNextBoundary(999), 999)
eq('boundary at zero is zero', msToNextBoundary(0), 0)
eq('boundary below zero is zero', msToNextBoundary(-50), 0)
// Property: for every ms in a wide range the wait lands in (0, 1000] and the
// display one boundary later is exactly one lower. This is the invariant a
// mutation to the formula (an off-by-one, a wrong multiplier, >= for >) breaks.
{
  let boundedOk = true
  let stepOk = true
  for (let ms = 1; ms <= 5_000; ms++) {
    const d = msToNextBoundary(ms)
    if (!(d > 0 && d <= 1_000)) { boundedOk = false; break }
    // After waiting exactly d ms, the displayed second must have dropped by one.
    if (displayedSeconds(ms) - 1 !== displayedSeconds(ms - d)) { stepOk = false; break }
  }
  ok('boundary is always within (0, 1000]', boundedOk)
  ok('waiting one boundary drops the display by exactly one', stepOk)
}

// ── countdownStep: the whole per-wake reading ───────────────────────────────
{
  const s = countdownStep(3_200, 0, 0)
  eq('step text', s.text, '4')
  eq('step delay', s.delayMs, 200)
  ok('step not done', s.done === false)
}
{
  const s = countdownStep(1_000, 5_000, 0) // already expired
  eq('expired step text', s.text, '0')
  ok('expired step done', s.done === true)
  eq('expired step delay', s.delayMs, 0)
}

// ── startCountdown: writes immediately, before any timer is armed ───────────
{
  const c = fakeClock(0)
  const r = recorder()
  startCountdown(3_200, 0, r.write, c.now, c.setTimer, c.clearTimer)
  eq('immediate first write', r.writes[0], '4')
  eq('first timer armed to the partial-second boundary', c.pendingAt(), 200)
}

// ── startCountdown: the exact visible sequence, boundary by boundary ────────
{
  const c = fakeClock(0)
  const r = recorder()
  const dispose = startCountdown(3_200, 0, r.write, c.now, c.setTimer, c.clearTimer)
  c.advanceTo(200)   // -> 3000ms left -> "3"
  c.advanceTo(1_200) // -> 2000ms left -> "2"
  c.advanceTo(2_200) // -> 1000ms left -> "1"
  c.advanceTo(3_200) // -> 0ms left    -> "0", done
  eq('visible sequence', r.writes.join(','), '4,3,2,1,0')
  ok('no timer pending after reaching zero', c.hasPending() === false)
  dispose()
}

// ── startCountdown: stops at zero, never loops past it ──────────────────────
{
  const c = fakeClock(0)
  const r = recorder()
  startCountdown(1_500, 0, r.write, c.now, c.setTimer, c.clearTimer)
  c.advanceTo(1_500) // reaches zero exactly
  eq('last text is zero', r.writes[r.writes.length - 1], '0')
  ok('no re-arm past zero', c.hasPending() === false)
  const countAtZero = r.writes.length
  c.advanceTo(10_000) // wind far past: nothing should fire
  eq('no writes after zero', r.writes.length, countAtZero)
}

// ── startCountdown: an already-expired deadline writes 0 and arms nothing ───
{
  const c = fakeClock(5_000)
  const r = recorder()
  startCountdown(1_000, 0, r.write, c.now, c.setTimer, c.clearTimer)
  eq('expired writes 0 once', r.writes.join(','), '0')
  ok('expired arms no timer', c.hasPending() === false)
}

// ── startCountdown: minute formatting mid-run (crossing the 1:00 boundary) ──
{
  const c = fakeClock(0)
  const r = recorder()
  const dispose = startCountdown(61_200, 0, r.write, c.now, c.setTimer, c.clearTimer)
  eq('minutes: immediate write', r.writes[0], '1:02')
  c.advanceTo(200)     // 61000ms -> ceil 61 -> "1:01"
  c.advanceTo(1_200)   // 60000ms -> "1:00"
  c.advanceTo(2_200)   // 59000ms -> "59"  (drops the colon at the boundary)
  eq('minutes: crosses 1:00 then 59', r.writes.join(','), '1:02,1:01,1:00,59')
  dispose()
}

// ── cleanup: dispose clears the pending timer and stops all writes ──────────
{
  const c = fakeClock(0)
  const r = recorder()
  const dispose = startCountdown(5_000, 0, r.write, c.now, c.setTimer, c.clearTimer)
  eq('one write before dispose', r.writes.length, 1)
  ok('a timer is pending before dispose', c.hasPending() === true)
  dispose()
  ok('dispose clears the pending timer', c.hasPending() === false)
  c.advanceTo(10_000) // even if something lingered, nothing may fire
  eq('no writes after dispose', r.writes.length, 1)
}

// ── changed deadline / offset: re-arming lands on the new number at once ────
// This models the React effect tearing down and restarting when endsAt/offset
// change: dispose the old driver, start a new one with the new inputs.
{
  const c = fakeClock(0)
  const r = recorder()
  const dispose = startCountdown(5_000, 0, r.write, c.now, c.setTimer, c.clearTimer)
  eq('first deadline shows 5', r.writes[0], '5')
  c.advanceTo(1_000) // 4000ms -> "4"
  dispose()
  // A new, EARLIER deadline arrives (warmup cut short). Restart from the driver
  // -- it must reflect the new deadline immediately on the same clock.
  startCountdown(2_500, 0, r.write, c.now, c.setTimer, c.clearTimer)
  eq('re-armed to the new, earlier deadline at once', r.writes[r.writes.length - 1], '2')
  eq('new timer targets the new boundary', c.pendingAt(), 1_500) // now=1000, left=1500 -> +500
}
{
  // An offset re-sync (clock correction) with the same endsAt shifts the number.
  const c = fakeClock(0)
  const r = recorder()
  startCountdown(10_000, 2_000, r.write, c.now, c.setTimer, c.clearTimer)
  // left = 10000 - (0 + 2000) = 8000 -> "8"
  eq('offset shifts the displayed number', r.writes[0], '8')
}

// ── timer throttling: a late wake lands on the correct number, no catch-up ──
// A backgrounded tab may not fire the 1s timer for many seconds. When it finally
// does, drift correction must jump the display straight to the right value and
// re-arm a SINGLE timer -- not replay every second it slept through.
{
  const c = fakeClock(0)
  const r = recorder()
  const dispose = startCountdown(10_000, 0, r.write, c.now, c.setTimer, c.clearTimer)
  eq('throttle: start at 10', r.writes[0], '10')
  // The tab freezes. The first timer was armed for t=1000 (10000ms is a full
  // second, so boundary is 1000ms away). It does not fire until t=7300.
  c.advanceTo(7_300) // left = 2700ms -> ceil -> "3"
  // Exactly one catch-up write, straight to the correct value -- not 9,8,7,...,3.
  eq('throttle: writes so far', r.writes.join(','), '10,3')
  eq('throttle: re-armed to the next real boundary', c.pendingAt(), 7_300 + 700) // 2700 -> +700 to 2000
  c.advanceTo(8_000) // left = 2000 -> "2"
  eq('throttle: resumes cleanly after catch-up', r.writes.join(','), '10,3,2')
  dispose()
}

// ── result ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error(`\ntest-countdown: ${failed} failure(s) of ${ran} checks`)
  process.exit(1)
}
console.log(`test-countdown: ok, ${ran} checks`)
