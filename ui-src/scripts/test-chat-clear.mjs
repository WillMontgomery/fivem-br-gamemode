#!/usr/bin/env node
/**
 * THE CHAT-CLEAR TESTS (#365).
 *
 * Owner, 2026-09-23: "clear all text chat history client-side on match
 * cleanup", and then of the players CLEANUP never reaches: "it should clear
 * client-side when transitioning to lobby". `src/store/chatClear.ts` decides
 * what the log holds after a state payload lands, and setMatch in the store
 * writes whatever it returns. These pin the ways that goes wrong: clearing on
 * the wrong state, not clearing at all, and clearing only some of the channels.
 *
 * WHY node RUNS A .ts FILE DIRECTLY. chatClear.ts has only a type import, which
 * node's type stripping erases, so it loads as-is -- the same shape as
 * test-countdown.mjs. The store cannot be loaded that way (it imports the
 * settings module without an extension and reads import.meta.env).
 *
 * WHAT THIS CANNOT REACH, stated rather than implied: that setMatch actually
 * calls this with the previous state, the new one and the live log. That half
 * is check-ui rule R23. The two are a pair; do not delete one and keep the
 * other.
 *
 * Run: npm run test:chatclear   (and as part of npm run build)
 */

import { chatAfterState } from '../src/store/chatClear.ts'

let failed = 0
let ran = 0

function check(label, got, expected) {
  ran++
  const ok = JSON.stringify(got) === JSON.stringify(expected)
  if (!ok) failed++
  console.log(
    ok
      ? `  ok    ${label}`
      : `  FAIL  ${label}\n          got      ${JSON.stringify(got)}\n          expected ${JSON.stringify(expected)}`,
  )
}

function checkTrue(label, got) {
  ran++
  if (got !== true) failed++
  console.log(got === true ? `  ok    ${label}` : `  FAIL  ${label}\n          got      ${got}`)
}

// Every match state bridge/types.ts declares. If one is added there, add it here.
const STATES = ['waiting', 'warmup', 'bus', 'playing', 'ended', 'cleanup']

// The two states whose ARRIVAL empties the log.
const CLEARS = ['cleanup', 'waiting']

/** One line on every channel, so a clear that filters by channel is visible. */
function log() {
  return [
    { channel: 'global', from: 3, name: 'Kestrel', text: 'gg', at: 1 },
    { channel: 'squad',  from: 4, name: 'Rook',    text: 'on me', at: 2 },
    { channel: 'system', from: 0, name: 'System',  text: 'restart soon', at: 3 },
  ]
}

// ── the edge into CLEANUP or WAITING empties every channel ──────────────────
// WAITING from each of the others is a real way home: WARMUP and BUS are a match
// dissolving, PLAYING is Leave Match or brforce, ENDED a leave before the sweep,
// CLEANUP the ordinary end.
for (const now of CLEARS) {
  for (const was of STATES.filter((s) => s !== now)) {
    const before = log()
    const after = chatAfterState(was, now, before)
    check(`${was} -> ${now} empties the log`, after, [])
    check(`${was} -> ${now} leaves no channel behind`,
      ['global', 'squad', 'system'].filter((c) => after.some((m) => m.channel === c)), [])
    // A new array, and the old one untouched: zustand wakes subscribers on a new
    // reference, and something else may still be holding the old one.
    checkTrue(`${was} -> ${now} hands back a new array`, after !== before)
    check(`${was} -> ${now} does not mutate the log it was given`, before.length, 3)
  }
}

// ── every other pair keeps the log, as the SAME array ───────────────────────
// ENDED is the verdict and WARMUP is the next match -- neither clears. CLEANUP ->
// CLEANUP and WAITING -> WAITING are a payload repeating the state, not the edge.
for (const was of STATES) {
  for (const now of STATES) {
    if (CLEARS.includes(now) && was !== now) continue
    const before = log()
    checkTrue(`${was} -> ${now} keeps the log as the same array`,
      chatAfterState(was, now, before) === before)
  }
}

// ── one whole match, fed through the way setMatch feeds it ──────────────────
{
  let state = 'playing'
  let chat = log()
  const seen = {}
  for (const next of ['ended', 'cleanup', 'waiting', 'warmup', 'bus', 'playing']) {
    chat = chatAfterState(state, next, chat)
    state = next
    seen[next] = chat.length
    // A line landing during CLEANUP is still the finished match's, and the lobby
    // must not open on it. A line landing in the lobby belongs to the lobby, and
    // must survive the rest of the walk.
    if (next === 'cleanup') chat = [...chat, { channel: 'system', from: 0, name: 'System', text: 'bye', at: 4 }]
    if (next === 'waiting') chat = [...chat, { channel: 'global', from: 9, name: 'Nyx', text: 'q?', at: 5 }]
  }
  check('a match: the verdict keeps the log, cleanup and the lobby empty it, nothing else clears',
    seen, { ended: 3, cleanup: 0, waiting: 0, warmup: 1, bus: 1, playing: 1 })
}

// ── the ways home that never see CLEANUP ────────────────────────────────────
// Leave Match (alive or spectating), a match dissolving in warmup or the flight,
// brforce waiting: each is this client's match state going straight to WAITING.
for (const [label, walk] of [
  ['Leave Match mid-match', ['warmup', 'bus', 'playing', 'waiting']],
  ['a match dissolving in warmup', ['warmup', 'waiting']],
  ['a match dissolving in the flight', ['warmup', 'bus', 'waiting']],
]) {
  let state = 'waiting'
  let chat = []
  for (const next of walk) {
    chat = chatAfterState(state, next, chat)
    state = next
    if (next !== 'waiting') chat = [...chat, ...log()]
  }
  check(`${label}: the lobby opens on an empty log`, chat.length, 0)
}

// ── result ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error(`\ntest-chat-clear: ${failed} failure(s) of ${ran} checks`)
  process.exit(1)
}
console.log(`test-chat-clear: ok, ${ran} checks`)
