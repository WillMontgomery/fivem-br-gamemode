#!/usr/bin/env node
/**
 * THE LOBBY COMES DOWN WITHOUT THE ANIMATION CLOCK (#252).
 *
 * Owner, 2026-10-03: "the lobby UI doesn't go away when getting into warmup -
 * it only happens if you sit AFK in lobby for a long time, like 30+ minutes or
 * so". The page had the warmup state and kept the menu drawn, because the only
 * thing that took it off the screen was a CSS transition -- run by the
 * browser's animation clock, not by the JS timers and messages that were still
 * working. Stopping that clock in a real Chromium reproduces it exactly.
 *
 * src/ui/fade.ts is the decision: when a layer's fade has had its time on the
 * JS clock, and what the layer looks like before and after. These drive it the
 * way the owner's session did -- shown for 87 minutes, then hidden -- with a
 * fake clock and NO animation event of any kind, which is the point: nothing
 * here can be waiting on one -- and on the default clock, which must be the
 * monotonic one (round 2). And src/bridge/screenReport.ts is the page's half of
 * the F8 line: which steps of a ready-up arm it, and what it carries. br_ui's
 * half -- the comparison with what Lua sent, the verdict, the NO ANSWER
 * watchdog -- is pinned in tools/test_client.lua.
 *
 * WHY node RUNS .ts FILES DIRECTLY. Both have no runtime imports, so node's type
 * stripping loads them as-is -- the same shape as test-chat-clear.mjs.
 *
 * WHAT THIS CANNOT REACH: that the lobby, the curtain and the HUD actually draw
 * from this, and that the report is sent. That half is check-ui rule R26. The
 * two are a pair; do not delete one and keep the other.
 *
 * Run: npm run test:fade   (and as part of npm run build)
 */

import { createFadeClock, fadeStyle, FADE_SETTLE_MARGIN_MS, monotonicNow } from '../src/ui/fade.ts'
import { screenChanges, screenPayload, showing } from '../src/bridge/screenReport.ts'

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

function has(label, line, part) {
  ran++
  const ok = typeof line === 'string' && line.includes(part)
  if (!ok) failed++
  console.log(ok ? `  ok    ${label}` : `  FAIL  ${label}\n          line     ${line}\n          missing  ${part}`)
}

/** A clock the suite moves by hand. */
function fakeClock(start = 0) {
  let t = start
  return { now: () => t, wait: (ms) => { t += ms } }
}

const LOBBY_MS = 200                                 // Lobby.tsx's LOBBY_FADE_MS
const WINDOW = LOBBY_MS + FADE_SETTLE_MARGIN_MS

// ── the owner's session ─────────────────────────────────────────────────────
console.log('the lobby after an 87-minute idle, with no animation event ever delivered')
{
  const t = fakeClock()
  const lobby = createFadeClock(true, WINDOW, t.now)
  check('a layer is settled on the frame it mounts', lobby.settled, true)
  check('...and draws its final style with no transition',
    fadeStyle(true, lobby.settled, LOBBY_MS),
    { opacity: 1, visibility: 'visible', transition: 'none' })

  t.wait(87 * 60 * 1000)
  check('the ready-up is a change of value', lobby.want(false), true)
  check('the fade out is the one the lobby always drew',
    fadeStyle(false, lobby.settled, LOBBY_MS),
    { opacity: 0, visibility: 'hidden', transition: 'opacity 200ms linear, visibility 0s linear 200ms' })

  t.wait(LOBBY_MS)
  check('at the end of the fade itself it is not yet forced -- a healthy fade finishes first',
    lobby.poll(), false)
  t.wait(FADE_SETTLE_MARGIN_MS)
  check('one margin later it is settled, by the JS clock alone', lobby.poll(), true)
  check('...and the lobby is hidden with NOTHING left for an animation clock to hold',
    fadeStyle(false, lobby.settled, LOBBY_MS),
    { opacity: 0, visibility: 'hidden', transition: 'none' })
}

// ── a level, not an edge ────────────────────────────────────────────────────
console.log('the clock follows the latest value')
{
  const t = fakeClock()
  const c = createFadeClock(true, WINDOW, t.now)
  c.want(false)
  // App re-renders the lobby on every store change, ten times a second in a
  // match. A clock that restarted on each of those would never settle.
  for (let i = 0; i < 3; i++) { t.wait(100); c.want(false) }
  check('re-asserting the same value on every render does not hold the fade open', c.poll(), true)

  c.want(true)
  t.wait(100)
  c.want(false)
  t.wait(WINDOW - 1)
  check('a change inside the window restarts it from the change', c.poll(), false)
  t.wait(1)
  check('...and it settles on the LATEST value', [c.poll(), c.shown], [true, false])

  c.want(true)
  check('remaining() is what the timer is armed with', c.remaining(), WINDOW)
  t.wait(120)
  check('...and counts down', c.remaining(), WINDOW - 120)
  t.wait(10 * 60 * 1000)
  check('a fade asked late -- by the next envelope, with the timer never fired -- settles',
    c.poll(), true)
  check('...and a settled clock has nothing remaining', c.remaining(), 0)
  check('the fade in, settled, is fully drawn with no transition',
    fadeStyle(true, c.settled, LOBBY_MS), { opacity: 1, visibility: 'visible', transition: 'none' })
  check('the fade in, running, is the one the lobby always drew',
    fadeStyle(true, false, LOBBY_MS), { opacity: 1, visibility: 'visible', transition: 'opacity 200ms linear' })
}
{
  const c = createFadeClock(false, WINDOW, fakeClock().now)
  check('a layer mounted hidden is hidden and settled at once', [c.settled,
    fadeStyle(false, c.settled, LOBBY_MS).visibility], [true, 'hidden'])
}

// ── the clock is monotonic ──────────────────────────────────────────────────
console.log('the default clock is performance.now, not the wall clock')
{
  // A real wait, and a synchronous one: this file has no event loop to spare.
  const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms)
  const realNow = Date.now
  // The wall clock is replaced BEFORE either clock is made, so a default that
  // reads Date.now would be reading this one.
  let wall = realNow()
  Date.now = () => wall
  try {
    const ahead = createFadeClock(true, WINDOW)
    ahead.want(false)
    wall += 60 * 60 * 1000
    check('the wall clock stepping an hour FORWARD does not cut a fade short', ahead.poll(), false)

    const behind = createFadeClock(true, WINDOW)
    behind.want(false)
    wall -= 2 * 60 * 60 * 1000
    pause(WINDOW + 30)
    check('...and stepping an hour BACK does not hold a fade open past its time', behind.poll(), true)
  } finally {
    Date.now = realNow
  }
  const a = monotonicNow()
  check('monotonicNow is performance.now', Math.abs(a - performance.now()) < 50, true)
}

// ── what arms a report ──────────────────────────────────────────────────────
console.log('every step of a ready-up arms the screen report')

const key = (over) => ({ match: 'waiting', me: 'lobby', leaving: false, focus: 'lobby', showLobby: true, ...over })
{
  check('the first reading is the boot, not a transition', screenChanges(null, key({})), [])
  check('a re-render that changes nothing arms nothing', screenChanges(key({}), key({})), [])

  // Lua's order on a ready-up: the curtain, focus, then STATE + the forced HUD.
  let k = key({})
  const steps = []
  const step = (over) => { const n = { ...k, ...over }; steps.push(...screenChanges(k, n)); k = n }
  step({ leaving: true })
  step({ focus: 'none' })
  step({ match: 'warmup', me: 'warmup', showLobby: false })
  step({ leaving: false })
  check('...the curtain, the focus, both states, the lobby and the curtain lifting', steps,
    ['curtain up', 'focus lobby>none', 'match waiting>warmup', 'me lobby>warmup', 'lobby off', 'curtain down'])

  // THE PAGE-STATE MISS: STATE and HUD never arrive. The lobby never flips --
  // which is all round 1 armed on -- and the curtain still arms twice.
  k = key({})
  steps.length = 0
  step({ leaving: true })
  step({ focus: 'none' })
  step({ leaving: false })
  check('a page that never got the warmup still reports, on the curtain', steps,
    ['curtain up', 'focus lobby>none', 'curtain down'])

  check('the drop\'s own states do not arm -- no line per jump',
    screenChanges(key({ match: 'playing', me: 'bus', showLobby: false }),
                  key({ match: 'playing', me: 'freefall', showLobby: false })), [])
  check('...but walking home does',
    screenChanges(key({ match: 'playing', me: 'alive', showLobby: false }),
                  key({ match: 'playing', me: 'lobby', showLobby: true })), ['me alive>lobby', 'lobby on'])
  check('a bystander\'s match starting arms (the lobby stays, the state moved)',
    screenChanges(key({}), key({ match: 'warmup' })), ['match waiting>warmup'])
  check('TAB in a match arms nothing -- focus away from the lobby is not a step of it',
    screenChanges(key({ match: 'playing', me: 'alive', focus: 'none', showLobby: false }),
                  key({ match: 'playing', me: 'alive', focus: 'inventory', showLobby: false })), [])
  check('the market opening over the lobby arms',
    screenChanges(key({}), key({ focus: 'market' })), ['focus lobby>market'])
}

// ── the report ──────────────────────────────────────────────────────────────
console.log('the screen report')

const off = (end) => ({ opacity: 0, visibility: 'hidden', end })
const on = (end) => ({ opacity: 1, visibility: 'visible', end })
const reading = (over) => ({
  why: ['curtain down'],
  match: 'warmup', me: 'warmup', focus: 'none', leaving: false, wanted: 'hud',
  lobby: off('transition'), hud: on('transition'), curtain: { opacity: 0, visibility: 'visible', end: 'transition' },
  ui: { opacity: 1, visibility: 'visible' },
  frames: 58, frameMs: 500, pageVisible: 'visible', focused: true, upMs: (87 * 60 + 12) * 1000,
  seq: 812, stale: 0, unheard: 0,
  ...over,
})

{
  const p = screenPayload(reading({}))
  check('a healthy warmup: what it wants, what it shows, and the state it holds',
    [p.why, p.wanted, p.showing, p.match, p.me, p.leaving, p.focus, p.seq, p.forced, p.frames],
    ['curtain down', 'hud', 'hud', 'warmup', 'warmup', false, 'none', 812, false, 58])
  has('...the lobby off, hidden, by its own transition', p.detail, 'lobby off (0 hidden, transition)')
  has('...the HUD on', p.detail, 'hud on (1, transition)')
  has('...the gate open', p.detail, 'ui on (1)')
  has('...the frame count', p.detail, '58 frames in 500ms')
  has('...the gate\'s sequence and the silent drops', p.detail, 'seq 812, 0 stale')
  has('...and how long the page has been up, so a reload cannot hide', p.detail, 'up 87m12s')
  check('one line, always', /[\r\n]/.test(p.detail), false)
  check('short enough that br_ui never has to cut it', p.detail.length < 420, true)
}
{
  // What the page looked like on 2026-10-03 under a stopped animation clock,
  // before round 1: the transition still pending, the menu fully drawn.
  const p = screenPayload(reading({ lobby: on('fading'), hud: { opacity: 0, visibility: 'visible', end: 'fading' } }))
  check('the #252 picture shows the lobby where the HUD was wanted', [p.wanted, p.showing], ['hud', 'lobby'])
  has('...with the lobby still on and its fade never finished', p.detail, 'lobby on (1 visible, fading)')
}
{
  const p = screenPayload(reading({ lobby: off('forced'), hud: on('forced') }))
  check('a fade the JS clock had to finish is flagged forced', [p.showing, p.forced], ['hud', true])
  check('...from any layer, the gate included',
    screenPayload(reading({ ui: { opacity: 1, visibility: 'visible', end: 'forced' } })).forced, true)
}
{
  const p = screenPayload(reading({ frames: 0 }))
  has('a page drawing no frames says so -- right styles, old screen', p.detail,
    '0 frames in 500ms (nothing is being drawn)')
  check('...and carries the count for br_ui\'s verdict', p.frames, 0)
}
{
  const r = reading({ match: 'waiting', me: 'lobby', wanted: 'lobby', lobby: on('transition'), hud: off('transition'),
    curtain: { opacity: 1, visibility: 'visible' } })
  check('a curtain still up is what the player sees, over everything', showing(r), 'curtain')
}
{
  const r = reading({ ui: { opacity: 0, visibility: 'visible', end: 'transition' }, wanted: 'nothing' })
  check('under GTA\'s menu nothing of ours is drawn, whatever the layers say', showing(r), 'nothing')
  check('a page with no gate element is read as open',
    showing(reading({ ui: { opacity: 0, visibility: 'missing' } })), 'hud')
}
{
  const r = reading({ lobby: { opacity: 0, visibility: 'missing' }, hud: { opacity: 0, visibility: 'missing' },
    curtain: { opacity: 0, visibility: 'missing' } })
  check('a page with none of the layers shows nothing', showing(r), 'nothing')
}
{
  check('several reasons are listed in order',
    screenPayload(reading({ why: ['curtain up', 'black', 'me lobby>warmup'] })).why, 'curtain up, black, me lobby>warmup')
  check('a stale drop and an unheard one are counted in the line',
    screenPayload(reading({ stale: 2, unheard: 1 })).detail.includes('seq 812, 2 stale, 1 unheard'), true)
}

// ── result ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error(`\ntest-fade: ${failed} failure(s) of ${ran} checks`)
  process.exit(1)
}
console.log(`test-fade: ok, ${ran} checks`)
