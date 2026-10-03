#!/usr/bin/env node
/**
 * THE EMOTE MUSIC'S TESTS (#215).
 *
 * Owner, 2026-10-02 ("Scope v2"): "One license-free .ogg per dance", heard by
 * the people near the dancer, at the player's "Music volume". Lua sends the
 * page every audible dance ten times a second; `src/audio/musicPlan.ts` turns
 * each message plus what is already playing into steps, and music.ts applies
 * them to <audio> elements. These pin the decisions: what starts, what stops,
 * when a drifting voice is re-seeked, how loud each one is, and when the page
 * gives up on a sender that went quiet.
 *
 * WHY node RUNS A .ts FILE DIRECTLY. musicPlan.ts has only type imports, which
 * node's type stripping erases -- the same shape as test-chat-clear.mjs.
 * music.ts cannot be loaded this way (it builds HTMLAudioElements).
 *
 * WHAT THIS CANNOT REACH, stated rather than implied: that music.ts still asks
 * this plan and still runs the watchdog, and that App.tsx and apply.ts still
 * feed it. That half is check-ui rule R24. The two are a pair; do not delete
 * one and keep the other.
 *
 * Run: npm run test:music   (and as part of npm run build)
 */

import {
  planTracks,
  musicGain,
  staleStop,
  DRIFT_MS,
  STALE_MS,
} from '../src/audio/musicPlan.ts'

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

const NONE = new Set()
const T = (src, track, pos, g) => ({ src, track, pos, g })
const V = (src, track, currentMs, lengthMs, volume) => ({ src, track, currentMs, lengthMs, volume })
const A = 'emotes/emote_shuffle.ogg'
const B = 'emotes/emote_jumper.ogg'

console.log('musicGain')
check('(0.5, 1) is the slider squared: 0.25', musicGain(0.5, 1), 0.25)
check('(1, 0.5) is the falloff: 0.5', musicGain(1, 0.5), 0.5)
check('a volume over 1 clamps to 1', musicGain(3, 1), 1)
check('a negative volume clamps to 0', musicGain(-1, 1), 0)
check('a falloff over 1 clamps to 1', musicGain(1, 4), 1)
check('a negative falloff clamps to 0', musicGain(1, -0.5), 0)
check('NaN volume is silence', musicGain(NaN, 1), 0)
check('NaN falloff is silence', musicGain(1, NaN), 0)
check('Infinity is silence, not full', musicGain(Infinity, 1), 0)

console.log('the empty list ends everything')
{
  const playing = [V(7, A, 1000, 12000, 0.25), V(3, B, 0, 12000, 0.25)]
  check('a non-array stops every voice, ascending src',
    planTracks(undefined, playing, NONE, 0.5),
    [{ op: 'stop', src: 3 }, { op: 'stop', src: 7 }])
  check("Lua's empty table, arriving as {}, is the empty list",
    planTracks({}, playing, NONE, 0.5),
    [{ op: 'stop', src: 3 }, { op: 'stop', src: 7 }])
  check('[] is the empty list',
    planTracks([], playing, NONE, 0.5),
    [{ op: 'stop', src: 3 }, { op: 'stop', src: 7 }])
  check('nothing playing and nothing asked is no step', planTracks([], [], NONE, 0.5), [])
}

console.log('starting')
check('a new src starts at its pos, at musicGain',
  planTracks([T(4, A, 3500, 1)], [], NONE, 0.5),
  [{ op: 'start', src: 4, track: A, atMs: 3500, volume: 0.25 }])
check('a missing track is skipped (it never asks twice)',
  planTracks([T(4, A, 0, 1)], [], new Set([A]), 0.5), [])
check('a missing track that is playing is stopped',
  planTracks([T(4, A, 0, 1)], [V(4, A, 0, 12000, 0.25)], new Set([A]), 0.5),
  [{ op: 'stop', src: 4 }])
check('g = 0 is out of earshot: skipped',
  planTracks([T(4, A, 0, 0)], [], NONE, 0.5), [])
check('g = 0 for a playing voice stops it',
  planTracks([T(4, A, 0, 0)], [V(4, A, 0, 12000, 0.25)], NONE, 0.5),
  [{ op: 'stop', src: 4 }])
check('a malformed entry is ignored, its neighbour is not',
  planTracks([T('x', A, 0, 1), T(5, '', 0, 1), T(6, A, -1, 1), T(7, A, NaN, 1),
              T(8, A, 0, 'loud'), null, 4, T(9, B, 100, 1)], [], NONE, 1),
  [{ op: 'start', src: 9, track: B, atMs: 100, volume: 1 }])

console.log('a track change is a stop, then a start')
check('same src, different track',
  planTracks([T(4, B, 2000, 1)], [V(4, A, 2000, 12000, 1)], NONE, 1),
  [{ op: 'stop', src: 4 }, { op: 'start', src: 4, track: B, atMs: 2000, volume: 1 }])

console.log('duplicate srcs: the last wins')
check('two entries for one src start the last',
  planTracks([T(4, A, 100, 1), T(4, B, 900, 0.5)], [], NONE, 1),
  [{ op: 'start', src: 4, track: B, atMs: 900, volume: 0.5 }])
check('a last duplicate with g = 0 means out of earshot',
  planTracks([T(4, A, 100, 1), T(4, A, 100, 0)], [], NONE, 1), [])

console.log('drift')
check(`100 ms off is under DRIFT_MS (${DRIFT_MS}): no seek`,
  planTracks([T(4, A, 5100, 1)], [V(4, A, 5000, 12000, 1)], NONE, 1), [])
check('400 ms off is over it: seek to pos',
  planTracks([T(4, A, 5400, 1)], [V(4, A, 5000, 12000, 1)], NONE, 1),
  [{ op: 'seek', src: 4, atMs: 5400 }])
check('a dance longer than its file is compared modulo the length (no seek)',
  planTracks([T(4, A, 12000 + 5100, 1)], [V(4, A, 5000, 12000, 1)], NONE, 1), [])
check('modulo the length, still drifted (seek)',
  planTracks([T(4, A, 12000 + 5600, 1)], [V(4, A, 5000, 12000, 1)], NONE, 1),
  [{ op: 'seek', src: 4, atMs: 17600 }])
check('the element just wrapped, Lua just before the loop point: 40 ms, no seek',
  planTracks([T(4, A, 19990, 1)], [V(4, A, 30, 10000, 1)], NONE, 1), [])
check('the element just before the loop point, Lua just wrapped: 40 ms, no seek',
  planTracks([T(4, A, 10030, 1)], [V(4, A, 9990, 10000, 1)], NONE, 1), [])
check('around the loop, still drifted (seek)',
  planTracks([T(4, A, 19900, 1)], [V(4, A, 300, 10000, 1)], NONE, 1),
  [{ op: 'seek', src: 4, atMs: 19900 }])
check('an unknown length compares pos directly',
  planTracks([T(4, A, 5600, 1)], [V(4, A, 5000, null, 1)], NONE, 1),
  [{ op: 'seek', src: 4, atMs: 5600 }])
check('no metadata yet (currentMs null): never a seek',
  planTracks([T(4, A, 9000, 1)], [V(4, A, null, null, 1)], NONE, 1), [])

console.log('volume')
check('a gain change over 0.01 is a volume step',
  planTracks([T(4, A, 0, 0.5)], [V(4, A, 0, 12000, 1)], NONE, 1),
  [{ op: 'volume', src: 4, volume: 0.5 }])
check('a gain change of 0.01 or less is not',
  planTracks([T(4, A, 0, 0.995)], [V(4, A, 0, 12000, 1)], NONE, 1), [])
check('the slider is part of the gain',
  planTracks([T(4, A, 0, 1)], [V(4, A, 0, 12000, 1)], NONE, 0.5),
  [{ op: 'volume', src: 4, volume: 0.25 }])

console.log('ordering is deterministic')
{
  const playing = [
    V(9, A, 0, 12000, 1),        // gone -> stop
    V(2, A, 0, 12000, 1),        // track change -> stop + start
    V(6, A, 0, 12000, 1),        // drifted and quieter -> volume + seek
    V(1, A, 0, 12000, 1),        // gone -> stop
    V(4, A, 0, 12000, 0.25),     // quieter only -> volume
  ]
  const asked = [T(6, A, 3000, 0.5), T(8, B, 0, 1), T(2, B, 0, 1), T(4, A, 0, 0.1), T(5, A, 0, 1)]
  const plan = planTracks(asked, playing, NONE, 1)
  check('stops, then starts, then corrections; ascending src in each',
    plan,
    [
      { op: 'stop', src: 1 }, { op: 'stop', src: 2 }, { op: 'stop', src: 9 },
      { op: 'start', src: 2, track: B, atMs: 0, volume: 1 },
      { op: 'start', src: 5, track: A, atMs: 0, volume: 1 },
      { op: 'start', src: 8, track: B, atMs: 0, volume: 1 },
      { op: 'volume', src: 4, volume: 0.1 },
      { op: 'volume', src: 6, volume: 0.5 },
      { op: 'seek', src: 6, atMs: 3000 },
    ])
  check('the same input in another order plans the same steps',
    planTracks([...asked].reverse(), [...playing].reverse(), NONE, 1), plan)
}

console.log('staleStop')
check(`(2001, 1000, 1): over STALE_MS (${STALE_MS}) with a voice -> stop`, staleStop(2001, 1000, 1), true)
check('(1500, 1000, 1): inside the window -> keep', staleStop(1500, 1000, 1), false)
check('(5000, 0, 0): nothing playing -> nothing to stop', staleStop(5000, 0, 0), false)
check('exactly STALE_MS is not yet stale', staleStop(2000, 1000, 1), false)

console.log(`\n${ran - failed}/${ran} passed`)
if (failed) process.exit(1)
