#!/usr/bin/env node
/**
 * THE LOBBY TRACK'S TESTS (#423).
 *
 * The loading screen's song plays on into the lobby, and it must not play past
 * the moment the ped stops walking and the Locker unlocks (owner, 2026-10-30).
 * br_loadscreen posts where its copy is on br_core's exit cue;
 * `src/audio/lobbyTrackPlan.ts` makes every call about it, lobbyTrack.ts
 * applies them to an <audio> element and keeps the timers, and
 * lobbyTrackInstall.ts wires it to the page. Three parts, the same three here:
 *
 *   THE PLAN, loaded straight into node -- lobbyTrackPlan.ts imports nothing,
 *   so node's type stripping takes it as it is, the shape of test-music.mjs.
 *   Which handoff is taken, where the song should be, how a copy off the mark
 *   is brought back onto it, and when the fade starts and the stop lands --
 *   with the deadline far off, inside the tail, already here, and gone.
 *
 *   THE CONTROLLER AND ITS WIRING, ON A FAKE BROWSER. #423's review mutated
 *   the half that holds the timers and the element, and 9 of 10 changes passed
 *   a suite that pinned only the plan: a release that kept its timers, a
 *   re-plan that stacked them, a cut that went up instead of down. So
 *   lobbyTrack.ts and the install are bundled here with esbuild (they import
 *   the plan as the page does, without an extension, which node cannot load)
 *   and run against a browser stepped by hand: its two clocks, its timers,
 *   fetch, blob URLs and a model <audio> element. Only the store and the
 *   bridge's isBrowser are stand-ins, the way scripts/lockerv2-render.mjs
 *   stands them in. Every ending is held to a full release.
 *
 *   WHAT CANNOT RUN, read off the source the way test-cef.mjs reads its own:
 *   main.tsx installs it before the first render, LockerPayload carries
 *   unlockInMs, and the file it fetches is one br_loadscreen ships.
 *
 * WHAT THIS CANNOT REACH, stated rather than implied: the sound -- that CEF
 * seeks a blob to the sample, that the two copies cross without a step in
 * loudness, how a rate change sounds. The model element plays at its rate from
 * where it was put, after a start-up it is told; the real one is the
 * playtest's.
 *
 * Run: npm run test:lobbytrack   (and as part of npm run build)
 */

import { existsSync, readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { blankComments } from './cef-rules.mjs'
import {
  readHandoff, playhead, opening, songOver, tooLate, tooOld, seamLost, riseCanFinish, alignStep,
  rateDone, planTail, fallbackTail, deadlineIn,
  SKEW_MS, LOADSCREEN_FALL_MS, SEEK_BEYOND_MS, DONE_WITHIN_MS, RATE_BEHIND, RATE_AHEAD,
  CLOSED_WITHIN_MS, GIVE_UP_MS, MIN_FADE_MS, NO_DEADLINE_FADE_MS,
} from '../src/audio/lobbyTrackPlan.ts'

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

const NOW = 1_800_000_000_000
const MAX_AGE = 3000
const TAIL = 5000
const MARGIN = 250

/** The handoff exactly as br_loadscreen/index.html posts it, 20 ms in flight. */
const shipped = { v: 1, position: 42.5, at: NOW - 20, endsAt: NOW + 19000, muted: false, volume: 0.5 }
const msg = (over = {}) => ({ brTrackHandoff: { ...shipped, ...over } })
const take = (over = {}) => readHandoff(msg(over), NOW, MAX_AGE)
const taken = (over = {}) => {
  const h = { ...shipped, ...over }
  return { position: h.position, at: h.at, endsAt: h.endsAt ?? null, muted: h.muted, volume: h.volume }
}

console.log('readHandoff: what is taken')
check('the shipped shape is taken: its numbers and the mute',
  take(), taken())
check('a URL in the message is never read -- the five fields and nothing else',
  take({ src: 'https://cfx-nui-elsewhere/other.ogg', url: 'nui://x/y.ogg' }), taken())
check('endsAt null (the cue carried no deadline) is a handoff with none',
  take({ endsAt: null }), taken({ endsAt: null }))
{
  const { endsAt: _gone, ...rest } = shipped
  check('endsAt absent is a handoff with none',
    readHandoff({ brTrackHandoff: rest }, NOW, MAX_AGE), taken({ endsAt: null }))
}
check('muted is still a handoff (taken, then kept silent)',
  take({ muted: true }), taken({ muted: true }))
check('position 0 is taken', take({ position: 0 }), taken({ position: 0 }))
check('a volume over 1 clamps to 1', take({ volume: 1.5 }), taken({ volume: 1 }))
check('a negative volume clamps to 0', take({ volume: -0.2 }), taken({ volume: 0 }))

console.log('readHandoff: stale, and from the future')
check(`exactly maxAgeMs old (${MAX_AGE}) is still taken`,
  take({ at: NOW - MAX_AGE }), taken({ at: NOW - MAX_AGE }))
check('a millisecond older is stale: refused', take({ at: NOW - MAX_AGE - 1 }), null)
check('a minute old is refused', take({ at: NOW - 60000 }), null)
check('read this very millisecond is taken', take({ at: NOW }), taken({ at: NOW }))
check(`dated SKEW_MS (${SKEW_MS}) ahead -- two processes' clocks -- is taken`,
  take({ at: NOW + SKEW_MS }), taken({ at: NOW + SKEW_MS }))
check('dated a millisecond further ahead is from the future: refused',
  take({ at: NOW + SKEW_MS + 1 }), null)
check('dated a second ahead is refused', take({ at: NOW + 1000 }), null)
check('tooOld: maxAgeMs after the read is still the cue\'s', tooOld(NOW - MAX_AGE, NOW, MAX_AGE), false)
check('tooOld: a millisecond later it is not', tooOld(NOW - MAX_AGE - 1, NOW, MAX_AGE), true)

console.log('readHandoff: what is refused')
check('no v', take({ v: undefined }), null)
check('v 2', take({ v: 2 }), null)
check("v '1'", take({ v: '1' }), null)
check('a negative position', take({ position: -0.01 }), null)
check('a NaN position', take({ position: NaN }), null)
check('an Infinity position', take({ position: Infinity }), null)
check('a position as a string', take({ position: '42.5' }), null)
check('at as a string', take({ at: String(NOW) }), null)
check('a NaN at', take({ at: NaN }), null)
check('endsAt as a string', take({ endsAt: '19000' }), null)
check('a NaN endsAt', take({ endsAt: NaN }), null)
check('an Infinity endsAt', take({ endsAt: Infinity }), null)
check("muted 'true'", take({ muted: 'true' }), null)
check('muted 1', take({ muted: 1 }), null)
check('muted absent', take({ muted: undefined }), null)
check('a NaN volume', take({ volume: NaN }), null)
check('a volume as a string', take({ volume: '0.5' }), null)
check('no data', readHandoff(null, NOW, MAX_AGE), null)
check('a string', readHandoff('brTrackHandoff', NOW, MAX_AGE), null)
check('a number', readHandoff(42, NOW, MAX_AGE), null)
check('an empty object', readHandoff({}, NOW, MAX_AGE), null)
check('brTrackHandoff null', readHandoff({ brTrackHandoff: null }, NOW, MAX_AGE), null)
check('brTrackHandoff a string', readHandoff({ brTrackHandoff: 'x' }, NOW, MAX_AGE), null)
check("one of Lua's envelopes, which shares the window",
  readHandoff({ t: 'br', v: 1, k: 'locker', d: { peds: [], chosen: '' }, s: 3 }, NOW, MAX_AGE), null)
check("FiveM's own loading event", readHandoff({ eventName: 'loadProgress', loadFraction: 0.5 }, NOW, MAX_AGE), null)

console.log('seamLost: a copy starts under the loading screen\'s fall, or not at all')
check(`started exactly LOADSCREEN_FALL_MS (${LOADSCREEN_FALL_MS}) after the read: still the seam`,
  seamLost(NOW, NOW + LOADSCREEN_FALL_MS), false)
check('a millisecond later the loading screen is silent: the seam is gone', seamLost(NOW, NOW + LOADSCREEN_FALL_MS + 1), true)
check('at once: the seam', seamLost(NOW, NOW + 2), false)

console.log('playhead')
check('at the moment it was read: the handed position', playhead({ position: 42.5, at: NOW }, NOW), 42.5)
check('250 ms on: a quarter second further', playhead({ position: 42.5, at: NOW }, NOW + 250), 42.75)
check('1500 ms on', playhead({ position: 42.5, at: NOW }, NOW + 1500), 44)
check('read 125 ms "in the future" (clock skew): that far behind it',
  playhead({ position: 42.5, at: NOW + 125 }, NOW), 42.375)

console.log('opening: play, or stay silent')
const H = taken()
check('a deadline 19 s off: play', opening(H, NOW + 19000, NOW, MARGIN), { op: 'play' })
check('no deadline known: play', opening(H, null, NOW, MARGIN), { op: 'play' })
check('muted on the loading screen: silent, whatever the deadline',
  opening(taken({ muted: true }), NOW + 19000, NOW, MARGIN), { op: 'silent', why: 'muted' })
check('muted with no deadline: silent', opening(taken({ muted: true }), null, NOW, MARGIN), { op: 'silent', why: 'muted' })
check(`silence due exactly MIN_FADE_MS (${MIN_FADE_MS}) from now: play`,
  opening(H, NOW + MARGIN + MIN_FADE_MS, NOW, MARGIN), { op: 'play' })
check('a millisecond less: too late, silent',
  opening(H, NOW + MARGIN + MIN_FADE_MS - 1, NOW, MARGIN), { op: 'silent', why: 'too late' })
check('the deadline already gone: too late, silent',
  opening(H, NOW - 1000, NOW, MARGIN), { op: 'silent', why: 'too late' })
check('tooLate: 150 ms of room is enough', tooLate(NOW + 400, NOW, MARGIN), false)
check('tooLate: 149 ms is not', tooLate(NOW + 399, NOW, MARGIN), true)

console.log('riseCanFinish: the crossfade gives way to a deadline that cannot wait for it')
check('the rise ends with the shortest fade and the margin still to come: it runs whole',
  riseCanFinish(NOW + 300 + MIN_FADE_MS + MARGIN, NOW + 300, MARGIN), true)
check('a millisecond less: it turns around', riseCanFinish(NOW + 300 + MIN_FADE_MS + MARGIN - 1, NOW + 300, MARGIN), false)
check('unlockInMs 0 mid-rise: it turns around', riseCanFinish(NOW + 60, NOW + 300, MARGIN), false)
check("the cue's 19 s: it runs whole", riseCanFinish(NOW + 19000, NOW + 330, MARGIN), true)

console.log('songOver: never play() from the end, which starts again at 0:00')
check('at the end: over', songOver(114.8, 114.8), true)
check('past the end: over', songOver(120, 114.8), true)
check('just short of it: not over', songOver(114.79, 114.8), false)
check('an unknown length (NaN) cannot say: not over', songOver(10, NaN), false)
check('an unbounded length (Infinity) cannot say: not over', songOver(10, Infinity), false)

console.log('alignStep')
check('on the mark: done', alignStep(0, 0), { op: 'done', why: 'aligned' })
check(`DONE_WITHIN_MS (${DONE_WITHIN_MS}) behind: done`, alignStep(-DONE_WITHIN_MS, 0), { op: 'done', why: 'aligned' })
check('the same ahead: done', alignStep(DONE_WITHIN_MS, 0), { op: 'done', why: 'aligned' })
check(`40 ms behind: run fast (${RATE_BEHIND})`, alignStep(-40, 0), { op: 'rate', rate: RATE_BEHIND })
check(`40 ms ahead: run slow (${RATE_AHEAD})`, alignStep(40, 0), { op: 'rate', rate: RATE_AHEAD })
check('5.5 ms behind: run fast', alignStep(-5.5, 0), { op: 'rate', rate: RATE_BEHIND })
check(`exactly SEEK_BEYOND_MS (${SEEK_BEYOND_MS}) behind: still by speed`,
  alignStep(-SEEK_BEYOND_MS, 0), { op: 'rate', rate: RATE_BEHIND })
check('a millisecond beyond it: seek', alignStep(-SEEK_BEYOND_MS - 1, 0), { op: 'seek' })
check('300 ms ahead: seek', alignStep(300, 0), { op: 'seek' })
check(`GIVE_UP_MS (${GIVE_UP_MS}) after the first look: given up, gap or not`,
  alignStep(-100, GIVE_UP_MS), { op: 'done', why: 'gave up' })
check('a seek that late is given up too', alignStep(-400, GIVE_UP_MS), { op: 'done', why: 'gave up' })
check('a millisecond before it: still closing', alignStep(-100, GIVE_UP_MS - 1), { op: 'rate', rate: RATE_BEHIND })
check('a gap that cannot be read: given up', alignStep(NaN, 0), { op: 'done', why: 'gave up' })

console.log('rateDone')
check('fast, 10 ms behind: keep going', rateDone(-10, RATE_BEHIND, 100), false)
check(`fast, CLOSED_WITHIN_MS (${CLOSED_WITHIN_MS}) behind: back to 1`, rateDone(-CLOSED_WITHIN_MS, RATE_BEHIND, 100), true)
check('fast, 2.5 ms behind: keep going', rateDone(-2.5, RATE_BEHIND, 100), false)
check('fast, overshot to 3 ms ahead: back to 1', rateDone(3, RATE_BEHIND, 100), true)
check('slow, 10 ms ahead: keep going', rateDone(10, RATE_AHEAD, 100), false)
check('slow, 2 ms ahead: back to 1', rateDone(CLOSED_WITHIN_MS, RATE_AHEAD, 100), true)
check('slow, overshot to 1 ms behind: back to 1', rateDone(-1, RATE_AHEAD, 100), true)
check('out of time with the gap still open: back to 1', rateDone(-30, RATE_BEHIND, GIVE_UP_MS), true)
check('a gap that cannot be read: back to 1', rateDone(NaN, RATE_BEHIND, 100), true)

console.log(`planTail (tail ${TAIL}, margin ${MARGIN})`)
const tail = (endsIn, now = NOW) => planTail(now + endsIn, now, TAIL, MARGIN)
check("the cue's deadline at a boot, 19 s: fade from 13.75 s, silent 250 ms early, stop on it",
  tail(19000), { startInMs: 13750, fadeMs: 5000, stopInMs: 19000 })
check("Lua's walk-start push, 18 s", tail(18000), { startInMs: 12750, fadeMs: 5000, stopInMs: 18000 })
check('exactly a tail and a margin away: the whole fade, from now',
  tail(TAIL + MARGIN), { startInMs: 0, fadeMs: 5000, stopInMs: 5250 })
check('a millisecond further: the whole fade, a millisecond on',
  tail(TAIL + MARGIN + 1), { startInMs: 1, fadeMs: 5000, stopInMs: 5251 })
check('the deadline inside the tail, 3 s: what is left, from now',
  tail(3000), { startInMs: 0, fadeMs: 2750, stopInMs: 3000 })
check('silence due exactly MIN_FADE_MS away: that fade, the stop on the deadline',
  tail(MARGIN + MIN_FADE_MS), { startInMs: 0, fadeMs: 150, stopInMs: 400 })
check('the deadline inside the margin, 300 ms: the shortest fade, the stop on the deadline',
  tail(300), { startInMs: 0, fadeMs: 150, stopInMs: 300 })
check('unlockInMs 0, the deadline here: the shortest fade, and the stop waits for it',
  tail(0), { startInMs: 0, fadeMs: 150, stopInMs: 150 })
check('the deadline a second gone: the same', tail(-1000), { startInMs: 0, fadeMs: 150, stopInMs: 150 })
check('no entrance (the cue says 1350), planned as the 350 ms rise ends: 750 ms of fade',
  planTail(NOW + 1350, NOW + 350, TAIL, MARGIN), { startInMs: 0, fadeMs: 750, stopInMs: 1000 })
check('no margin: the fade ends on the deadline itself',
  planTail(NOW + 19000, NOW, TAIL, 0), { startInMs: 14000, fadeMs: 5000, stopInMs: 19000 })
{
  // THE RULE ITSELF, over every deadline with room for the shortest fade:
  // silent exactly marginMs before it, never a fade longer than the tail, the
  // stop on the deadline.
  const bad = []
  for (let endsIn = MARGIN + MIN_FADE_MS; endsIn <= 30000; endsIn += 37) {
    const t = tail(endsIn)
    if (t.startInMs + t.fadeMs !== endsIn - MARGIN || t.fadeMs > TAIL || t.startInMs < 0
        || t.stopInMs !== endsIn) bad.push(endsIn)
  }
  check('every deadline with room: silent marginMs before it, stop on it', bad, [])
}
check(`fallbackTail: NO_DEADLINE_FADE_MS (${NO_DEADLINE_FADE_MS}) from now, the stop a margin after`,
  fallbackTail(MARGIN), { startInMs: 0, fadeMs: NO_DEADLINE_FADE_MS, stopInMs: NO_DEADLINE_FADE_MS + MARGIN })

console.log('deadlineIn: a duration from now as a deadline')
check('18000', deadlineIn(18000, NOW), NOW + 18000)
check('0: the deadline is now', deadlineIn(0, NOW), NOW)
check('negative: already here, never in the past', deadlineIn(-5, NOW), NOW)
check('NaN: not a duration', deadlineIn(NaN, NOW), null)
check('Infinity: not a duration', deadlineIn(Infinity, NOW), null)
check('a string: not a duration', deadlineIn('18000', NOW), null)
check('absent: not a duration', deadlineIn(undefined, NOW), null)
check('null: not a duration', deadlineIn(null, NOW), null)

console.log('a first join, through the plan')
{
  const T = NOW
  // T: the cue (musicEndsInMs 19000); the loading screen stamps and posts.
  const h = readHandoff({ brTrackHandoff: { ...shipped, at: T, endsAt: T + 19000 } }, T + 2, MAX_AGE)
  check('the handoff lands 2 ms later and is taken, with the cue\'s deadline',
    h === null ? null : h.endsAt, T + 19000)
  check('it plays', h === null ? null : opening(h, h.endsAt, T + 2, MARGIN), { op: 'play' })
  // T+350: the rise is over, and the tail is planned from the cue's deadline.
  check('planned at T+350: the fade from T+13750',
    T + 350 + tail(19000 - 350, T + 350).startInMs, T + 13750)
  // T+1070: the walk starts; br_core pushes unlockInMs 18000, which replaces it.
  const lua = deadlineIn(18000, T + 1070)
  const t = planTail(lua, T + 1070, TAIL, MARGIN)
  check("re-planned on Lua's push: silent at T+18820, 250 ms before the planned unlock",
    [T + 1070 + t.startInMs + t.fadeMs - T, lua - (T + 1070 + t.startInMs + t.fadeMs)], [18820, 250])
  // ~T+14.9 s: the camera lands with the walk not begun, and Lua says 0.
  const now = T + 14900
  const z = planTail(deadlineIn(0, now), now, TAIL, MARGIN)
  check('then unlockInMs 0 at the landing: silent within MIN_FADE_MS, from now', z, { startInMs: 0, fadeMs: 150, stopInMs: 150 })
}

// ── a browser, faked ─────────────────────────────────────────────────────────

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC_URL = 'https://cfx-nui-br_loadscreen/audio/loadingscreen.ogg'
const WALL0 = 1_800_000_000_000
const real = {
  dateNow: Date.now, perfNow: performance.now, create: URL.createObjectURL, revoke: URL.revokeObjectURL,
  info: console.info, fetch: globalThis.fetch, window: globalThis.window, Audio: globalThis.Audio,
}
const settle = async () => {
  await new Promise((r) => setImmediate(r))
  await new Promise((r) => setImmediate(r))
}
const abortError = (m) => Object.assign(new Error(m), { name: 'AbortError' })

/**
 * The page's world, stepped by hand. Nothing in here is the code under test.
 *
 *   two clocks       performance.now() (`mono`) and Date.now(), which runs
 *                    `wallLead` ahead of it and can be stepped on its own;
 *   timers           the page's (counted: a release must leave none) and the
 *                    element's own, fired in order as the clock is run on;
 *   fetch            answered, refused or aborted when the test says;
 *   blob URLs        made and revoked, counted;
 *   <audio>          plays at its rate from where it was put, once it has
 *                    started (`startMs` after play(), the output `outputMs`
 *                    after that) -- the start-up the alignment exists for;
 *                    a seek freezes it `seekMs`; volume throws outside 0..1
 *                    as the real one does; load() resets it as the spec's load
 *                    algorithm does, the rate included;
 *   frames           this page beside the loading screen under FiveM's root
 *                    page, and whatever this page embeds (`embed()`).
 */
function fakeBrowser(cfg = {}) {
  const c = { metaMs: 20, startMs: 30, outputMs: 20, seekMs: 15, skipMs: 0, duration: 114.8, refuse: false, broken: false, ...cfg }
  const e = {
    mono: 5_000,
    wallLead: WALL0 - 5_000,
    page: new Map(),
    inner: new Map(),
    nextId: 1,
    peak: 0,
    fetches: [],
    blobs: { made: 0, live: new Set() },
    audios: [],
    errors: [],
    rejections: [],
    listeners: new Set(),
  }
  Date.now = () => e.mono + e.wallLead
  performance.now = () => e.mono

  const add = (map, fn, ms, every) => {
    const id = e.nextId++
    const d = Math.max(0, Number(ms) || 0)
    map.set(id, { due: e.mono + d, fn, every: every ? Math.max(1, d) : 0 })
    if (map === e.page) e.peak = Math.max(e.peak, e.page.size)
    return id
  }

  const win = {
    setTimeout: (fn, ms) => add(e.page, fn, ms, false),
    setInterval: (fn, ms) => add(e.page, fn, ms, true),
    clearTimeout: (id) => { e.page.delete(id) },
    clearInterval: (id) => { e.page.delete(id) },
    addEventListener: (k, fn) => { if (k === 'message') e.listeners.add(fn) },
    removeEventListener: (k, fn) => { if (k === 'message') e.listeners.delete(fn) },
    length: 0,
  }
  // FiveM's root page holds the loading screen and this page side by side.
  const root = { length: 2 }
  root.parent = root
  e.loadscreen = { length: 0, parent: root }
  root[0] = e.loadscreen
  root[1] = win
  win.parent = root
  globalThis.window = win
  e.win = win
  /** A frame this page puts inside itself: the manual, the Ringmaster console. */
  e.embed = () => {
    const child = { length: 0, parent: win }
    win[win.length] = child
    win.length++
    return child
  }
  /** A window message, from the loading screen unless the test says who. */
  e.post = (data, source = e.loadscreen) => {
    for (const fn of [...e.listeners]) fn({ data, source, origin: 'nui://br_loadscreen' })
  }

  /** Run the clocks on to `target` (performance.now()), firing what falls due in order. */
  e.runTo = async (target) => {
    for (;;) {
      await settle()
      let next = null
      for (const map of [e.page, e.inner]) {
        for (const [id, t] of map) {
          if (t.due <= target && (next === null || t.due < next.t.due || (t.due === next.t.due && id < next.id))) {
            next = { map, id, t }
          }
        }
      }
      if (next === null) {
        e.mono = Math.max(e.mono, target)
        await settle()
        return
      }
      e.mono = Math.max(e.mono, next.t.due)
      if (next.t.every) next.t.due = e.mono + next.t.every
      else next.map.delete(next.id)
      try { next.t.fn() } catch (err) { e.errors.push(err) }
    }
  }
  e.run = (ms) => e.runTo(e.mono + ms)

  globalThis.fetch = (url, init = {}) => {
    const f = { url, signal: init.signal ?? null, settled: false }
    e.fetches.push(f)
    return new Promise((resolve, reject) => {
      const end = (fn) => {
        if (f.settled) return
        f.settled = true
        fn()
      }
      f.signal?.addEventListener('abort', () => end(() => reject(abortError('The user aborted a request.'))))
      f.answer = (status = 200) => end(() => resolve({
        ok: status >= 200 && status < 300,
        status,
        blob: () => (f.signal?.aborted
          ? Promise.reject(abortError('The user aborted a request.'))
          : Promise.resolve({ size: 5_528_645 })),
      }))
      f.refuse = () => end(() => reject(new TypeError('Failed to fetch')))
    })
  }

  URL.createObjectURL = () => {
    const u = `blob:https://cfx-nui-br_ui/${++e.blobs.made}`
    e.blobs.live.add(u)
    return u
  }
  URL.revokeObjectURL = (u) => { e.blobs.live.delete(u) }

  class FakeAudio {
    constructor(...args) {
      e.audios.push(this)
      this.args = args
      this._src = ''
      this.preload = ''
      this.readyState = 0
      this.duration = NaN
      this.paused = true
      this._volume = 1
      this._rate = 1
      this.base = 0
      this.anchor = e.mono
      this.frozenTo = e.mono
      this.running = false
      this.on = new Map()
      this.pending = new Set()
      this.playP = null
      this.endId = null
      this.log = { volume: [], rate: [], seeks: [], srcs: [], plays: 0, loads: 0 }
    }
    soon(ms, fn) {
      const id = add(e.inner, () => { this.pending.delete(id); fn() }, ms, false)
      this.pending.add(id)
      return id
    }
    halt() {
      for (const id of this.pending) e.inner.delete(id)
      this.pending.clear()
      this.endId = null
      if (this.playP) {
        const p = this.playP
        this.playP = null
        p.reject(abortError('The play() request was interrupted.'))
      }
    }
    reset() {
      this.halt()
      this.base = 0
      this.running = false
      this.paused = true
      this.readyState = 0
      this.duration = NaN
      this._rate = 1
    }
    get src() { return this._src }
    set src(v) {
      this._src = String(v)
      this.log.srcs.push(this._src)
      this.reset()
      if (!this._src) return
      this.soon(c.metaMs, () => {
        if (c.broken) {
          this.emit('error')
          return
        }
        this.readyState = 1
        this.duration = c.duration
        this.emit('loadedmetadata')
      })
    }
    removeAttribute(name) { if (name === 'src') this._src = '' }
    load() {
      this.log.loads++
      this.reset()
      if (this._src) this.src = this._src
    }
    get volume() { return this._volume }
    set volume(v) {
      if (typeof v !== 'number' || !(v >= 0 && v <= 1)) {
        const err = new RangeError(`volume ${v} is outside 0..1`)
        e.errors.push(err)
        throw err
      }
      this._volume = v
      this.log.volume.push([e.mono, v])
    }
    get playbackRate() { return this._rate }
    set playbackRate(r) {
      this.base = this.currentTime
      this.anchor = e.mono
      this._rate = r
      this.log.rate.push([e.mono, r])
      this.scheduleEnd()
    }
    get currentTime() {
      if (!this.running) return this.base
      return this.base + Math.max(0, e.mono - Math.max(this.anchor, this.frozenTo)) * this._rate / 1000
    }
    set currentTime(v) {
      this.log.seeks.push([e.mono, v])
      this.base = v
      this.anchor = e.mono
      if (this.running) this.frozenTo = e.mono + c.seekMs
      this.scheduleEnd()
    }
    play() {
      this.log.plays++
      if (!this._src) return Promise.reject(Object.assign(new Error('no source'), { name: 'NotSupportedError' }))
      if (c.refuse) return Promise.reject(Object.assign(new Error('refused'), { name: 'NotAllowedError' }))
      this.paused = false
      return new Promise((resolve, reject) => {
        this.playP = { resolve, reject }
        this.soon(c.startMs, () => {
          this.running = true
          this.anchor = e.mono
          this.frozenTo = e.mono + c.outputMs
          this.base += c.skipMs / 1000
          this.scheduleEnd()
          const p = this.playP
          this.playP = null
          this.emit('playing')
          p?.resolve()
        })
      })
    }
    pause() {
      this.base = this.currentTime
      this.running = false
      this.paused = true
      this.halt()
    }
    scheduleEnd() {
      if (this.endId !== null) {
        e.inner.delete(this.endId)
        this.pending.delete(this.endId)
        this.endId = null
      }
      if (!this.running || !Number.isFinite(this.duration)) return
      const wait = Math.max(0, Math.max(this.anchor, this.frozenTo) - e.mono)
      const left = (this.duration - this.currentTime) * 1000 / this._rate
      this.endId = this.soon(wait + Math.max(0, left), () => {
        this.endId = null
        if (this.running && this.currentTime >= this.duration - 1e-9) {
          this.base = this.duration
          this.running = false
          this.paused = true
          this.emit('ended')
        } else {
          this.scheduleEnd()
        }
      })
    }
    addEventListener(type, fn, opts) {
      if (!this.on.has(type)) this.on.set(type, [])
      this.on.get(type).push({ fn, once: !!opts?.once })
    }
    removeEventListener(type, fn) {
      const l = this.on.get(type)
      if (!l) return
      const i = l.findIndex((x) => x.fn === fn)
      if (i >= 0) l.splice(i, 1)
    }
    emit(type) {
      for (const x of [...(this.on.get(type) ?? [])]) {
        if (x.once) this.removeEventListener(type, x.fn)
        try { x.fn({ type }) } catch (err) { e.errors.push(err) }
      }
    }
  }
  globalThis.Audio = FakeAudio

  const onRejection = (r) => { e.rejections.push(r) }
  process.on('unhandledRejection', onRejection)
  e.end = async () => {
    await settle()
    process.off('unhandledRejection', onRejection)
    Date.now = real.dateNow
    performance.now = real.perfNow
    URL.createObjectURL = real.create
    URL.revokeObjectURL = real.revoke
    console.info = real.info
    globalThis.fetch = real.fetch
    globalThis.window = real.window
    globalThis.Audio = real.Audio
  }
  return e
}

/**
 * Everything a release must let go of, as what is still held; [] when clean.
 * `e.ended` is what was recorded the moment it let go (onDone, or the
 * install's line): a timer still running then is one the release missed, even
 * if it stops itself a tick later.
 */
function held(e, phase, ended = e.ended ?? []) {
  const a = e.audios[0]
  const out = []
  if (phase !== 'done') out.push(`phase ${phase}`)
  for (const x of ended) if (x?.timersAtEnd) out.push(`${x.timersAtEnd} timer(s) still running as it let go`)
  if (e.page.size) out.push(`${e.page.size} timer(s) still set`)
  if (a.src !== '') out.push('the element kept its src')
  if (a.log.loads < 1) out.push('load() never called: the decoder stays')
  if (!a.paused) out.push('still playing')
  if (a.playbackRate !== 1) out.push(`rate ${a.playbackRate}`)
  if (e.blobs.live.size) out.push(`${e.blobs.live.size} blob URL(s) not revoked`)
  if (e.fetches.some((f) => !f.signal?.aborted)) out.push('the fetch never aborted')
  out.push(...played(e))
  return out
}

/** What a page must never do, at any moment: [] when it has not. */
function played(e) {
  const out = []
  for (const a of e.audios) {
    if (a.args.length) out.push(`an element made on a URL: ${JSON.stringify(a.args)}`)
    const plain = a.log.srcs.filter((u) => u !== '' && !u.startsWith('blob:'))
    if (plain.length) out.push(`played from a plain URL, which starts at 0:00: ${plain.join(', ')}`)
  }
  if (e.errors.length) out.push(`errors: ${e.errors.map(String).join('; ')}`)
  if (e.rejections.length) out.push(`unhandled rejections: ${e.rejections.map((r) => `${r?.name}: ${r?.message}`).join('; ')}`)
  return out
}

const near = (v, x, tol) => typeof v === 'number' && Math.abs(v - x) <= tol + 1e-9
/** The loudest the element was set to, from `from` on. */
const peak = (a, from = -Infinity) => Math.max(0, ...a.log.volume.filter(([t]) => t >= from).map(([, v]) => v))
/** The first time after `from` the volume went UP, or null: the song coming back. */
function rose(a, from) {
  const log = a.log.volume.filter(([t]) => t >= from)
  for (let i = 1; i < log.length; i++) if (log[i][1] > log[i - 1][1] + 1e-12) return log[i]
  return null
}
/** When the song last went silent: the first 0 after it last sounded; null if it never sounded. */
function quietAt(a) {
  const log = a.log.volume
  let loud = -1
  for (let i = 0; i < log.length; i++) if (log[i][1] > 0) loud = i
  if (loud < 0) return null
  const z = log.slice(loud + 1).find(([, v]) => v === 0)
  return z ? z[0] : null
}
/** A ramp moves the volume every 16 ms, so silence lands up to one step after it is due. */
const STEP = 16
const within = (t, from, to) => typeof t === 'number' && t >= from && t <= to

/** The handoff exactly as br_loadscreen posts it, read now on the fake's wall clock. */
function cue(over = {}) {
  const at = Date.now()
  return { brTrackHandoff: { v: 1, position: 42.5, at, endsAt: at + 19000, muted: false, volume: 0.5, ...over } }
}

/** esbuild's bundle of one entry, as text node can import. */
async function bundle(entry, plugins = []) {
  const out = await build({
    entryPoints: [join(ROOT, entry)],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'neutral',
    mainFields: ['module', 'main'],
    logLevel: 'silent',
    plugins,
  })
  return out.outputFiles[0].text
}
let loads = 0
/** A module instance of its own: the install keeps its once-only flag per load. */
const load = (text) => import(`data:text/javascript;base64,${Buffer.from(`${text}\n// ${++loads}\n`).toString('base64')}`)

// THE STORE AND isBrowser, STOOD IN: zustand's own vanilla store with only the
// fields the install reads, calling subscribers with (state, prev) as useUi
// does; and a flag the test sets before each load.
const STUBS = {
  store: `
    import { createStore } from 'zustand/vanilla'
    const T = globalThis.__lobbyTrackTest
    const store = createStore(() => ({ locker: { peds: [], chosen: '' }, worldReady: false, leaving: false }))
    T.live = new Set()
    export const useUi = {
      getState: store.getState,
      setState: store.setState,
      subscribe(fn) {
        const off = store.subscribe(fn)
        const k = {}
        T.live.add(k)
        return () => { T.live.delete(k); off() }
      },
    }
    T.store = useUi`,
  nui: 'export const isBrowser = globalThis.__lobbyTrackTest.isBrowser === true',
}
const standIns = {
  name: 'lobby-track-stand-ins',
  setup(b) {
    b.onResolve({ filter: /^\.\.\/store$/ }, () => ({ path: 'store', namespace: 'stub' }))
    b.onResolve({ filter: /^\.\.\/bridge\/nui$/ }, () => ({ path: 'nui', namespace: 'stub' }))
    b.onLoad({ filter: /.*/, namespace: 'stub' }, (a) => ({ contents: STUBS[a.path], loader: 'js', resolveDir: ROOT }))
  },
}

const TRACK_JS = await bundle('src/audio/lobbyTrack.ts')
const INSTALL_JS = await bundle('src/audio/lobbyTrackInstall.ts', [standIns])
const LT = await load(TRACK_JS)

/** A track whose file was in memory long before the cue, as at every boot; T is the cue. */
async function booted(cfg = {}, opts = {}) {
  const e = fakeBrowser(cfg)
  const ended = []
  const track = LT.createLobbyTrack({ src: SRC_URL, onDone: (s) => ended.push({ ...s, timersAtEnd: e.page.size }), ...opts })
  e.ended = ended
  const a = e.audios[0]
  await e.run(80)
  e.fetches[0].answer(200)
  await e.run(4920)
  return { e, track, a, ended, T: e.mono }
}

/** A track whose fetch is still out when the test starts. */
function loading(cfg = {}) {
  const e = fakeBrowser(cfg)
  const ended = []
  const track = LT.createLobbyTrack({ src: SRC_URL, onDone: (s) => ended.push({ ...s, timersAtEnd: e.page.size }) })
  e.ended = ended
  return { e, track, a: e.audios[0], ended, T: e.mono }
}

// ── the controller ───────────────────────────────────────────────────────────

console.log('the controller: an ordinary first join')
{
  const { e, track, a, ended, T } = await booted()
  check('it fetches the file it was given, once', e.fetches.map((f) => f.url), [SRC_URL])
  check('and loads it from memory', [a.log.srcs.length, a.log.srcs[0]?.startsWith('blob:')], [1, true])
  track.onMessage({ data: cue() })
  check('the handoff is taken: seeked to the handed position at once, and play() asked', [a.log.seeks[0], a.log.plays], [[T, 42.5], 1])
  await e.runTo(T + 30 + 150)
  check('it rises in a straight line under the loading screen\'s fall: half the level halfway up',
    near(a.volume, 0.25, 0.5 * STEP / 300), true)
  await e.runTo(T + 400)
  check("to the handoff's level: the loading screen's, not a slider's", a.volume, 0.5)
  await e.runTo(T + 1000)
  track.worldReady()
  await e.runTo(T + 1070)
  track.setDeadlineIn(18000)
  await e.runTo(T + 3000)
  check('50 ms behind after its start-up: run 8% fast, then back to normal speed',
    [a.log.rate.map(([, r]) => r), a.playbackRate], [[1.08, 1], 1])
  check('...and pulled onto the mark', near(track.stats().driftAfterMs, 0, 3), true)
  check('...with only the tail and the stop still set', e.page.size, 2)
  await e.runTo(T + 13800)
  check('the level holds until the tail', a.volume, 0.5)
  await e.runTo(T + 13820 + 2500)
  check('the tail is a straight line: half the level halfway down', near(a.volume, 0.25, 0.5 * STEP / 5000), true)
  await e.runTo(T + 19100)
  check("silent 250 ms before Lua's deadline (T+19070)", within(quietAt(a), T + 18820, T + 18820 + STEP), true)
  check('never louder than the handed level', peak(a), 0.5)
  track.unlocked()
  const s = track.stats()
  check('the unlock finds it silent, and the stats say how long before',
    [s.why, within(s.silentBeforeUnlockMs, 280 - STEP, 280)], ['faded out before the deadline', true])
  check('onDone came once, with the stats as they ended',
    [ended.length, ended[0]?.phase, ended[0]?.why], [1, 'done', 'faded out before the deadline'])
  check('and it let go of everything', held(e, s.phase), [])
  await e.end()
}

console.log('the controller: Lua re-sending the deadline')
{
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue() })
  await e.runTo(T + 400)
  e.peak = e.page.size
  for (let k = 0, t = 400; t < 17500; k++, t += 37) {
    await e.runTo(T + t)
    track.setDeadlineIn(T + 18000 - e.mono + (k % 3) - 1)
  }
  await e.runTo(T + 20000)
  check('every 37 ms, for 17 s: never more than the tail, the stop, the alignment and one more', e.peak <= 4, true)
  check('the song never comes back up once it has started down', rose(a, T + 12000), null)
  check('silent 250 ms before the last deadline', within(quietAt(a), T + 17750 - 1, T + 17750 + 1 + STEP), true)
  check('and let go', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue() })
  await e.runTo(T + 1070)
  track.setDeadlineIn(9000)
  await e.runTo(T + 2000)
  track.setDeadlineIn(18000)
  await e.runTo(T + 11000)
  check("a later deadline cancels the earlier one's tail (due T+4820) and stop (T+10070)",
    [track.stats().phase, a.volume], ['playing', 0.5])
  await e.runTo(T + 20100)
  check('...and it falls silent on the later one', within(quietAt(a), T + 19750, T + 19750 + STEP), true)
  await e.end()
}

console.log('the controller: a deadline already here (unlockInMs 0 at the landing)')
for (const ms of [0, -500, 100, 400]) {
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue() })
  await e.runTo(T + 3000)
  track.setDeadlineIn(ms)
  await e.run(2000)
  check(`setDeadlineIn(${ms}) while playing: the shortest fade, silent within ${MIN_FADE_MS} ms`,
    within(quietAt(a), T + 3000 + MIN_FADE_MS - STEP, T + 3000 + MIN_FADE_MS + STEP), true)
  check('...and let go', held(e, track.stats().phase), [])
  await e.end()
}

console.log('the controller: a deadline landing mid-rise')
{
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue() })
  await e.runTo(T + 60)
  check('at T+60 the copy is rising', track.stats().phase, 'rising')
  const at = a.volume
  track.setDeadlineIn(0)
  await e.run(1000)
  check('unlockInMs 0 mid-rise turns the rise around at once: silent 150 ms on, not after the rise',
    within(quietAt(a), T + 60 + MIN_FADE_MS - STEP, T + 60 + MIN_FADE_MS + STEP), true)
  check('...never louder than when it landed', at > 0 && peak(a, T + 60) <= at, true)
  check('...and let go', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue() })
  await e.runTo(T + 100)
  track.setDeadlineIn(2000)
  await e.runTo(T + 3000)
  check('a deadline mid-rise that can wait lets the rise finish', peak(a), 0.5)
  check('...then fades over what is left: silent 250 ms before it',
    within(quietAt(a), T + 2100 - MARGIN, T + 2100 - MARGIN + STEP), true)
  await e.end()
}
{
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue({ endsAt: Date.now() + 600 }) })
  await e.runTo(T + 1000)
  check("the cue's own deadline too close for any rise: the copy never comes up", peak(a), 0)
  check('...stands down', [track.stats().phase, track.stats().why], ['done', 'faded out before the deadline'])
  check('...and lets go', held(e, track.stats().phase), [])
  await e.end()
}

console.log('the controller: the net')
for (const [phase, at] of [['rising', 100], ['playing', 3000], ['falling', 16000]]) {
  for (const how of ['unlocked', 'leftLobby']) {
    const { e, track, a, T } = await booted()
    track.onMessage({ data: cue() })
    await e.runTo(T + at)
    const was = track.stats().phase
    track[how]()
    await e.run(1000)
    const why = how === 'unlocked' ? 'cut at the unlock' : 'cut as the player left the lobby'
    check(`${how}() while ${phase}: silent within ${200} ms, never louder on the way, ${why}`,
      [was, within(quietAt(a), T + at + 200 - STEP, T + at + 200 + STEP), rose(a, T + at), track.stats().why],
      [phase, true, null, why])
    check('...and let go', held(e, track.stats().phase), [])
    await e.end()
  }
}
{
  const { e, track, a, T } = await booted({ outputMs: 150 })
  track.onMessage({ data: cue() })
  await e.runTo(T + 400)
  check('180 ms behind, the copy is still running fast at T+400', a.playbackRate, 1.08)
  track.unlocked()
  check('the unlock records the song still sounding', track.stats().silentBeforeUnlockMs, 0)
  await e.run(1000)
  check('cut mid-alignment: the rate watcher stops with it, the rate back to 1', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a, T } = loading()
  track.onMessage({ data: cue() })
  track.unlocked()
  await e.run(1000)
  check('the unlock before the song started: never starts', [a.log.plays, track.stats().why], [0, 'the Locker unlocked before the song started'])
  check('...and lets go', held(e, track.stats().phase), [])
  await e.end()
}

console.log('the controller: a file that comes in late')
for (const [late, plays] of [[100, true], [330, true], [331, false]]) {
  const { e, track, a, T } = loading()
  track.onMessage({ data: cue() })
  await e.runTo(T + late)
  e.fetches[0].answer(200)
  await e.run(1000)
  if (plays) {
    const ready = T + late + 20
    check(`in memory ${late} ms after the read, ready 20 ms on: it starts at the playhead then`,
      a.log.seeks[0], [ready, 42.5 + (ready - T) / 1000])
    check('...and sounds', peak(a) > 0, true)
  } else {
    check(`in memory ${late} ms after the read: the loading screen is silent by then, so this stays silent`,
      [a.log.plays, track.stats().why], [0, 'the file was ready after the seam'])
    check('...and lets go', held(e, track.stats().phase), [])
  }
  track.leftLobby()
  await e.run(1000)
  await e.end()
}
for (const [flight, plays] of [[LOADSCREEN_FALL_MS, true], [LOADSCREEN_FALL_MS + 1, false]]) {
  const { e, track, a } = await booted()
  const wall = Date.now()
  track.onMessage({ data: cue({ at: wall - flight, endsAt: wall - flight + 19000 }) })
  await e.run(1000)
  check(plays
    ? `a handoff ${flight} ms in flight, the file in memory: still the seam, it plays`
    : `${flight} ms in flight: fresh enough to be the cue's, too late for the seam: silent, and says which`,
  [a.log.plays, track.stats().why], plays ? [1, null] : [0, 'the handoff landed after the seam'])
  track.leftLobby()
  await e.run(1000)
  if (!plays) check('...holding nothing', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a, T } = loading()
  track.onMessage({ data: cue() })
  track.setDeadlineIn(100)
  await e.run(1000)
  e.fetches[0].answer(200)
  await e.run(1000)
  check('a deadline too close while the file still loads: stands down, never starts',
    [a.log.plays, track.stats().why], [0, 'the walk-in was over before the song started'])
  check('...and lets go, the fetch aborted', held(e, track.stats().phase), [])
  await e.end()
}

console.log('the controller: standing down at worldReady, and other ways never to start')
{
  const { e, track, a, ended } = await booted()
  track.worldReady()
  check('worldReady with no handoff: it lets go of the file at once', [ended.length, track.stats().why], [1, 'no handoff before worldReady'])
  track.onMessage({ data: cue() })
  await e.run(1000)
  check('...and a handoff after that is not taken', a.log.plays, 0)
  check('...holding nothing', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track } = loading()
  await e.run(1000)
  track.worldReady()
  e.fetches[0].answer(200)
  await e.run(1000)
  check('worldReady with the fetch still out: aborted, no blob ever made',
    [e.fetches[0].signal.aborted, e.blobs.made], [true, 0])
  check('...holding nothing', held(e, track.stats().phase), [])
  await e.end()
}
for (const [label, fail, why] of [
  ['a 404', (f) => f.answer(404), 'the file did not load (HTTP 404)'],
  ['a refused fetch', (f) => f.refuse(), 'the file did not load (Failed to fetch)'],
]) {
  const { e, track, a } = loading()
  fail(e.fetches[0])
  await e.run(100)
  track.onMessage({ data: cue() })
  await e.run(1000)
  check(`${label}: silent, never the plain URL instead`, [track.stats().source, track.stats().why, a.log.plays, a.log.srcs], ['failed', why, 0, []])
  check('...holding nothing', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a } = await booted({ broken: true })
  track.onMessage({ data: cue() })
  await e.run(1000)
  check('a file the element will not play: silent', [a.log.plays, track.stats().why], [0, 'the file would not play'])
  check('...holding nothing', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a } = await booted()
  track.onMessage({ data: cue({ muted: true }) })
  await e.run(1000)
  check('muted on the loading screen: silent', [a.log.plays, track.stats().why], [0, 'muted on the loading screen'])
  check('...holding nothing', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a } = await booted({ refuse: true })
  track.onMessage({ data: cue() })
  await e.run(1000)
  check('play() refused: silent, and the rejection handled', track.stats().why, 'play refused (NotAllowedError)')
  check('...holding nothing', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a } = await booted({ duration: 42.5 })
  track.onMessage({ data: cue() })
  await e.run(1000)
  check('handed at the very end: never play() from there, which is 0:00', [a.log.plays, track.stats().why], [0, 'the song was already over'])
  await e.end()
}
{
  const { e, track, T } = await booted({ duration: 44 })
  track.onMessage({ data: cue() })
  await e.runTo(T + 3000)
  check('the song running out mid-lobby: let go', [track.stats().why, held(e, track.stats().phase)], ['the song ended', []])
  await e.end()
}
{
  const { e, track, a } = await booted()
  const wall = Date.now()
  track.onMessage({ data: cue({ at: wall - MAX_AGE - 1 }) })
  track.onMessage({ data: cue({ at: wall + SKEW_MS + 1 }) })
  check('a stale handoff and one from the future are not taken', [track.stats().phase, a.log.plays], ['waiting', 0])
  track.onMessage({ data: cue({ position: 10 }) })
  track.onMessage({ data: cue({ position: 90 }) })
  check('the first good one is, and only the first', [track.stats().handedAt, a.log.seeks.map(([, p]) => p)], [10, [10]])
  track.leftLobby()
  await e.run(1000)
  await e.end()
}

console.log('the controller: no deadline, and deadlines that come late')
{
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue({ endsAt: null }) })
  await e.runTo(T + 1000)
  track.worldReady()
  await e.runTo(T + 7000)
  check(`no deadline known at worldReady: faded out over ${NO_DEADLINE_FADE_MS} ms from there`,
    [within(quietAt(a), T + 6000, T + 6000 + STEP), track.stats().why], [true, 'faded out, no deadline known'])
  check('...holding nothing', held(e, track.stats().phase), [])
  await e.end()
}
{
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue({ endsAt: null }) })
  await e.runTo(T + 1000)
  track.worldReady()
  await e.runTo(T + 2500)
  const at = a.volume
  track.setDeadlineIn(18000)
  await e.runTo(T + 10000)
  check('a deadline mid-way through that fade holds the level where it had got to', a.volume, at)
  await e.runTo(T + 21000)
  check('...falls again on the new time', within(quietAt(a), T + 20250, T + 20250 + STEP), true)
  check('...and never comes back up', rose(a, T + 1300), null)
  await e.end()
}
{
  const { e, track, a, T } = await booted()
  track.setDeadlineIn(9000)
  track.onMessage({ data: cue({ endsAt: null }) })
  await e.runTo(T + 10000)
  check("a deadline Lua sent before the handoff stands when the handoff has none",
    within(quietAt(a), T + 8750, T + 8750 + STEP), true)
  await e.end()
}

console.log('the controller: the wall clock stepped mid-song')
for (const step of [-2000, 2000]) {
  const { e, track, a, T } = await booted()
  track.onMessage({ data: cue() })
  await e.runTo(T + 15000)
  e.wallLead += step
  await e.runTo(T + 19100)
  check(`Date.now() stepped ${step > 0 ? 'forward' : 'back'} 2 s mid-tail: the fade neither rises nor jumps`,
    [rose(a, T + 15000), within(quietAt(a), T + 18750, T + 18750 + STEP)], [null, true])
  await e.end()
}

console.log('the controller: alignment')
{
  const { e, track, a, T } = await booted({ skipMs: 80 })
  track.onMessage({ data: cue() })
  await e.runTo(T + 3000)
  check('30 ms ahead: run 8% slow, then back to normal speed', [a.log.rate.map(([, r]) => r), a.playbackRate], [[0.92, 1], 1])
  track.leftLobby()
  await e.run(1000)
  await e.end()
}
{
  const { e, track, a, T } = await booted({ outputMs: 400 })
  track.onMessage({ data: cue() })
  await e.runTo(T + 3000)
  check('400 ms behind: one seek back onto the mark, then speed for what the seek cost',
    [track.stats().seeks, a.log.rate.map(([, r]) => r), a.playbackRate], [1, [1.08, 1], 1])
  track.leftLobby()
  await e.run(1000)
  await e.end()
}
{
  const { e, track, a, T } = await booted({ outputMs: 1e9, seekMs: 1e9 })
  track.onMessage({ data: cue() })
  await e.runTo(T + 6000)
  check(`a copy that never moves: seeks give up ${GIVE_UP_MS} ms after the first look, no rate left`,
    [track.stats().seeks, a.log.rate.length, e.page.size], [8, 0, 2])
  track.leftLobby()
  await e.run(1000)
  check('...and the net still lets go', held(e, track.stats().phase), [])
  await e.end()
}

// ── the wiring ───────────────────────────────────────────────────────────────

/**
 * The install on a fake page, its file answered `status` well before the cue
 * (in memory, unless that is a failure); T is about to be the cue. `locked`
 * pushes the Locker locked first, as the entrance has it at every boot.
 */
async function installed({ isBrowser = false, cfg = {}, status = 200, locked = false } = {}) {
  const e = fakeBrowser(cfg)
  const T0 = { isBrowser }
  globalThis.__lobbyTrackTest = T0
  const lines = []
  e.ended = []
  console.info = (...args) => {
    lines.push(args.join(' '))
    e.ended.push({ timersAtEnd: e.page.size })
  }
  const mod = await load(INSTALL_JS)
  mod.installLobbyTrack()
  const store = T0.store
  const push = (locker) => store.setState({ locker: { peds: [], chosen: '', ...locker } })
  if (locked) {
    push({ locked: false })
    push({ locked: true })
  }
  await e.run(80)
  e.fetches[0]?.answer(status)
  await e.run(4920)
  const line = (i = 0) => (lines[i] === undefined ? null : JSON.parse(lines[i].replace('[br_ui] lobby track ', '')))
  return { e, mod, store, push, lines, line, live: () => T0.live.size, a: e.audios[0], T: e.mono }
}

console.log('the wiring: an ordinary first join')
{
  const { e, store, push, lines, line, live, a, T } = await installed()
  push({ locked: false })
  push({ locked: true })
  check('undefined -> false -> true is no unlock', [a.log.plays, lines.length], [0, 0])
  e.post(cue())
  check('the loading screen\'s handoff is heard: seeked to it', a.log.seeks[0], [T, 42.5])
  await e.runTo(T + 1000)
  store.setState({ worldReady: true })
  await e.runTo(T + 1070)
  push({ locked: true, unlockInMs: 18000 })
  await e.runTo(T + 19000)
  check("silent 250 ms before the deadline the walk's push set", within(quietAt(a), T + 18820, T + 18820 + STEP), true)
  check('the line waits for the unlock while the Locker is locked', lines.length, 0)
  await e.runTo(T + 19100)
  push({ locked: false })
  check('the unlock: one line, with how long before it the song went quiet',
    [lines.length, line()?.why, within(line()?.silentBeforeUnlockMs, 280 - STEP, 280)], [1, 'faded out before the deadline', true])
  check('...and nothing of it stays installed', [live(), e.listeners.size], [0, 0])
  push({ locked: true })
  push({ locked: false })
  check('a later lock and unlock say nothing more', lines.length, 1)
  check('...holding nothing', held(e, line()?.phase), [])
  await e.end()
}

console.log('the wiring: the roads off the ordinary one')
{
  const { e, store, push, lines, line, live, a, T } = await installed()
  push({ locked: false })
  e.post(cue({ endsAt: Date.now() + 1350 }))
  await e.runTo(T + 650)
  store.setState({ worldReady: true })
  await e.runTo(T + 1200)
  check('no entrance (the Locker never locks): silent 250 ms before the cue\'s deadline',
    within(quietAt(a), T + 1100, T + 1100 + STEP), true)
  check('...and the line comes at once, with no unlock to wait for',
    [lines.length, line()?.why, live(), e.listeners.size], [1, 'faded out before the deadline', 0, 0])
  await e.end()
}
{
  const { e, store, lines, line, live, a } = await installed()
  store.setState({ worldReady: true })
  check('no handoff before worldReady: one line, and it lets go',
    [lines.length, line()?.why, live(), e.listeners.size, a.log.plays], [1, 'no handoff before worldReady', 0, 0, 0])
  check('...holding nothing', held(e, line()?.phase), [])
  await e.end()
}
{
  const { e, lines, line, live } = await installed({ locked: true })
  e.post(cue({ muted: true }))
  check('muted at the cue with the Locker locked: nothing sounded, so the line comes at once',
    [lines.length, line()?.why, live(), e.listeners.size], [1, 'muted on the loading screen', 0, 0])
  check('...holding nothing', held(e, line()?.phase), [])
  await e.end()
}
{
  const { e, lines, line, live } = await installed({ locked: true, status: 404 })
  check('the file missing (404) with the Locker locked: the line at once, saying so',
    [lines.length, line()?.why, live(), e.listeners.size], [1, 'the file did not load (HTTP 404)', 0, 0])
  check('...holding nothing', held(e, line()?.phase), [])
  await e.end()
}
{
  const { e, push, lines, line, a, T } = await installed()
  push({ locked: true })
  e.post(cue())
  await e.runTo(T + 1070)
  push({ locked: true, unlockInMs: 18000 })
  await e.runTo(T + 8000)
  push({ locked: false })
  check('an early unlock cuts: the line waits for the cut to end', lines.length, 0)
  await e.run(1000)
  check('...silent within 200 ms, and the line says the net cut it',
    [within(quietAt(a), T + 8200 - STEP, T + 8200 + STEP), line()?.why, line()?.silentBeforeUnlockMs], [true, 'cut at the unlock', 0])
  await e.end()
}
{
  const { e, store, push, lines, line, a, T } = await installed()
  push({ locked: true })
  e.post(cue())
  await e.runTo(T + 1070)
  push({ locked: true, unlockInMs: 18000 })
  await e.runTo(T + 6000)
  store.setState({ leaving: true, curtain: 'dropping' })
  await e.run(1000)
  check('readying up: the curtain cuts it in 200 ms, before the late unlock',
    [within(quietAt(a), T + 6200 - STEP, T + 6200 + STEP), line()?.why], [true, 'cut as the player left the lobby'])
  await e.runTo(T + 9700)
  push({ locked: false })
  check('...and the unlock after it says nothing more', lines.length, 1)
  await e.end()
}
{
  const { e, push, a, T } = await installed()
  e.post(cue())
  await e.runTo(T + 500)
  push({ locked: true })
  await e.runTo(T + 1070)
  push({ locked: true, unlockInMs: 18000 })
  await e.runTo(T + 15009)
  push({ locked: true, unlockInMs: 6050 })
  await e.runTo(T + 21200)
  check("a push with no unlockInMs leaves the deadline; the winner's flip moves it on",
    [within(quietAt(a), T + 21059 - MARGIN, T + 21059 - MARGIN + STEP), rose(a, T + 15009)], [true, null])
  await e.end()
}
{
  const { e, push, a, T } = await installed()
  push({ locked: true })
  e.post(cue())
  await e.runTo(T + 14911)
  push({ locked: true, unlockInMs: 0 })
  await e.run(1000)
  check('unlockInMs 0 as the camera lands mid-tail: silent within the shortest fade',
    within(quietAt(a), T + 14911 + MIN_FADE_MS - STEP, T + 14911 + MIN_FADE_MS + STEP), true)
  await e.end()
}

console.log('the wiring: who may hand the song over')
{
  const { e, a, T } = await installed()
  const manual = e.embed()
  let read = false
  e.post({ get brTrackHandoff() { read = true; return cue({ position: 10 }).brTrackHandoff } }, manual)
  check('a frame this page embedded is refused before a field of its message is read', [read, a.log.plays], [false, 0])
  e.post(cue())
  check('the loading screen, beside this page, is heard', a.log.seeks[0], [T, 42.5])
  await e.end()
}

console.log('the wiring: installed once, and only in game')
{
  const { e, mod } = await installed()
  mod.installLobbyTrack()
  check('a second install adds nothing', [e.fetches.length, e.listeners.size, e.audios.length], [1, 1, 1])
  await e.end()
}
{
  const { e, live } = await installed({ isBrowser: true })
  check('in the browser harness: nothing installed', [e.fetches.length, e.listeners.size, e.audios.length, live()], [0, 0, 0, 0])
  await e.end()
}

console.log('the page uses it')
{
  const read = (p) => readFileSync(new URL(p, import.meta.url), 'utf8')
  const code = (p) => blankComments(read(p))
  const track = code('../src/audio/lobbyTrack.ts')
  const install = code('../src/audio/lobbyTrackInstall.ts')
  const main = code('../src/main.tsx')
  const types = code('../src/bridge/types.ts')

  check("lobbyTrack.ts takes its decisions from './lobbyTrackPlan'",
    /\}\s*from\s*'\.\/lobbyTrackPlan'/.test(track), true)
  check('lobbyTrack.ts has no store and no bridge in it: the test bundles it alone',
    /from\s*'\.\.\/(?:store|bridge)\b/.test(track), false)
  const at = main.indexOf('installLobbyTrack()')
  check('main.tsx installs it before the first render', at >= 0 && at < main.indexOf('createRoot('), true)
  const locker = /export interface LockerPayload \{[\s\S]*?\n\}/.exec(types)
  check('LockerPayload carries unlockInMs', locker !== null && /\bunlockInMs\?\s*:\s*number\b/.test(locker[0]), true)

  // THE COUPLING, PINNED: the file is br_loadscreen's, so br_loadscreen must
  // ship it. A rename there is a song that silently stops at the cue.
  const src = /const\s+SRC\s*=\s*'https:\/\/cfx-nui-([\w-]+)\/([^']+)'/.exec(install)
  check('the install fetches a cfx-nui URL', src !== null, true)
  if (src !== null) {
    const [, res, path] = src
    const dir = `../../resources/[fivem-royale]/${res}/`
    const manifest = existsSync(new URL(`${dir}fxmanifest.lua`, import.meta.url))
      ? read(`${dir}fxmanifest.lua`).split('\n').filter((l) => !/^\s*--/.test(l)).join('\n')
      : ''
    // A files{} entry as FiveM reads it: `*` is anything but a slash.
    const literal = (p) => p.replace(/[.+?^$()|[\]{}\\]/g, '\\$&')
    const glob = (g) => new RegExp('^' + g.split('*').map(literal).join('[^/]*') + '$')
    check(`${res}'s fxmanifest.lua lists ${path}`,
      [...manifest.matchAll(/'([^']+)'/g)].some((m) => glob(m[1]).test(path)), true)
    check(`and ${res}/${path} is on disk`, existsSync(new URL(`${dir}${path}`, import.meta.url)), true)
  }
}

console.log(`\n${ran - failed}/${ran} passed`)
if (failed) process.exit(1)
