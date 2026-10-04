#!/usr/bin/env node
/**
 * THE CONTINUE TOGGLE'S TESTS (#387).
 *
 * Owner, 2026-10-03: "Seems after getting paid for the tutorial, after finishing
 * the match, the tutorial continue toggle is still in lobby."
 *
 * src/tutorial/continueToggle.ts decides whether the lobby draws "Continue
 * tutorial into the first match". These pin the report, every case the toggle
 * was kept for before it, and that nothing changed for a player who has not
 * finished.
 *
 * WHY node RUNS A .ts FILE DIRECTLY. continueToggle.ts has no runtime imports,
 * so node's type stripping loads it as-is -- the same shape as
 * test-chat-clear.mjs.
 *
 * WHAT THIS CANNOT REACH: that Lobby.tsx asks this function, and that the
 * `tutorial` envelope's `done` reaches the store it reads. That half is check-ui
 * rule R25, and Lua publishing `done` is tools/test_tutorial.lua. The three are
 * a set; do not delete one and keep the others.
 *
 * Run: npm run test:continuetoggle   (and as part of npm run build)
 */

import { showContinueToggle } from '../src/tutorial/continueToggle.ts'

let failed = 0
let ran = 0

function check(label, got, expected) {
  ran++
  const ok = got === expected
  if (!ok) failed++
  console.log(
    ok
      ? `  ok    ${label}`
      : `  FAIL  ${label}\n          got      ${got}\n          expected ${expected}`,
  )
}

/** A page with nothing raised: a fresh load, nobody offered anything. */
const BASE = {
  done: false, offerable: false, declineCard: false,
  gameOn: true,   // the store's default -- the toggle starts on
  step: null, offered: false,
}
const at = (over) => ({ ...BASE, ...over })

// ── THE REPORT ──────────────────────────────────────────────────────────────
// Finished the in-game half with the box left on (the normal path), paid, played
// the match out, back in the lobby. `offerable` is down -- finish() lowers it --
// but the box is still on and the session latch is still up.
check('#387: finished and paid, box left on, back in the lobby -> hidden',
  showContinueToggle(at({ done: true, offered: true })), false)

// The same player, had they declined on the way and taken it back: the box is
// on and `offerable` is down, exactly as for the take-back below. Only `done`
// tells them apart.
check('#387: finished after taking a decline back -> hidden',
  showContinueToggle(at({ done: true, offered: true, gameOn: true })), false)

// ── EVERY CASE IT WAS KEPT FOR ──────────────────────────────────────────────
check('first-timer on the `ready` card -> shown (2026-09-04: "immediately after'
  + ' they come back from the Help page")',
  showContinueToggle(at({ offerable: true, step: 'ready' })), true)

check('the last card dismissed -> still shown, it outlives the run',
  showContinueToggle(at({ offerable: true, offered: true })), true)

check('in-game half abandoned or warmup left mid-way -> shown (2026-09-07:'
  + ' "great, keep it"; 2026-09-08)',
  showContinueToggle(at({ offerable: true, offered: true })), true)

check('unticked: the decline card is up and anchored on it -> shown',
  showContinueToggle(at({ declineCard: true, gameOn: false, offered: true })), true)

check('decline taken back: re-ticked, card gone -> shown, not pulled from under'
  + ' the finger (2026-09-08)',
  showContinueToggle(at({ gameOn: true, offered: true })), true)

check('unticked and the card dismissed -> gone',
  showContinueToggle(at({ gameOn: false, offered: true })), false)

check('never reached the `ready` card this session -> not shown',
  showContinueToggle(at({ offerable: true })), false)

check('/brtutorial after a finish: Lua clears `done` and raises `offerable` -> shown',
  showContinueToggle(at({ offerable: true, offered: true })), true)

// ── `done` IS A VETO, AND IT IS THE ONLY CHANGE ─────────────────────────────
// Every combination of the other five inputs, both ways. With `done` down the
// answer must be exactly what Lobby.tsx drew before #387; with it up, nothing.
const before = (s) => (s.offerable || s.declineCard || s.gameOn)
  && (s.step === 'ready' || s.offered)
let combos = 0
let vetoBroken = 0
let drift = 0
for (const offerable of [false, true]) {
  for (const declineCard of [false, true]) {
    for (const gameOn of [false, true]) {
      for (const step of [null, 'ready', 'help']) {
        for (const offered of [false, true]) {
          const s = { offerable, declineCard, gameOn, step, offered }
          combos++
          if (showContinueToggle({ ...s, done: true }) !== false) vetoBroken++
          if (showContinueToggle({ ...s, done: false }) !== before(s)) drift++
        }
      }
    }
  }
}
check(`finished hides it in all ${combos} combinations`, vetoBroken, 0)
check(`not finished: identical to the old rule in all ${combos} combinations`, drift, 0)

if (failed) {
  console.error(`\ntest-continue-toggle: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-continue-toggle: ok, ${ran} checks`)
