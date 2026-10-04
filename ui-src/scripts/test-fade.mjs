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
 * the F8 line: which steps of a ready-up arm it, what it carries, and (round 3)
 * when it may be read -- never with a fade in flight, which the owner's own
 * ready-up timings are replayed against -- what a sub-screen over warmup reads
 * as, and that 'forced' belongs to the burst it happened in. br_ui's half -- the
 * comparison with what Lua sent and what br_core holds, the verdict, the
 * watchdog -- is pinned in tools/test_client.lua.
 *
 * WHY node RUNS .ts FILES DIRECTLY. Both have no runtime imports, so node's type
 * stripping loads them as-is -- the same shape as test-chat-clear.mjs.
 *
 * WHAT THIS CANNOT REACH: that the lobby, the curtain and the HUD actually draw
 * from this, and that the report is read and sent the way these decide. That
 * half is check-ui rules R26-R26c. The two are a pair; do not delete one and
 * keep the other.
 *
 * Run: npm run test:fade   (and as part of npm run build)
 */

import { createFadeClock, createFadeRegistry, fadeStyle, FADE_SETTLE_MARGIN_MS, monotonicNow } from '../src/ui/fade.ts'
import {
  AFTERMATH_MS, dueAt, MAX_WAIT_MS, moving, QUIET_MS, RETRY_MS, screenChanges, screenPayload, settle,
  SETTLE_GIVE_UP_MS, showing, wantedScreen,
} from '../src/bridge/screenReport.ts'

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
  ui: { opacity: 1, visibility: 'visible' }, pages: [], settling: [],
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

// ── round 3: never judged mid-fade ──────────────────────────────────────────
console.log('a reading waits for every fade to settle (round 3)')
{
  const none = moving([], 0)
  check('nothing moving: read now', settle({ why: [], first: 0 }, none, 1000), { read: true, settling: [] })

  const fading = moving([{ name: 'curtain', end: 'fading', at: 900, remaining: 420 }], 1000)
  check('a fade in its window is moving, and is waited out to its end plus the aftermath',
    fading, { names: ['curtain'], waitMs: 420 + AFTERMATH_MS })
  check('...so the reading is not taken', settle({ why: [], first: 0 }, fading, 1000),
    { read: false, waitMs: 420 + AFTERMATH_MS })

  check('a fade that ended 10ms ago is still moving -- its re-render and follow-up effect',
    moving([{ name: 'page:market', end: 'forced', at: 990, remaining: 0 }], 1000),
    { names: ['page:market'], waitMs: AFTERMATH_MS - 10 })
  check('...and one that ended a while ago is not',
    moving([{ name: 'lobby', end: 'transition', at: 100, remaining: 0 }], 1000), { names: [], waitMs: 0 })
  check('a fade already due waits the shortest retry, never zero',
    settle({ why: [], first: 0 }, moving([{ name: 'hud', end: 'fading', at: 0, remaining: 0 }], 1000), 1000),
    { read: false, waitMs: RETRY_MS })

  const b = { why: ['curtain up'], first: 0 }
  settle(b, fading, 1000)
  check('a layer still moving 3s after the reading fell due: read anyway, marked settling, not judged',
    settle(b, fading, 1000 + SETTLE_GIVE_UP_MS), { read: true, settling: ['curtain'] })
  check('...and not a moment before', settle({ ...b, due: 1000 }, fading, 999 + SETTLE_GIVE_UP_MS).read, false)

  check('due QUIET_MS after the latest step', dueAt({ why: [], first: 0 }, 400), 400 + QUIET_MS)
  check('...but never later than MAX_WAIT_MS after the first', dueAt({ why: [], first: 0 }, 4800), MAX_WAIT_MS)
}

/**
 * The page's side of a ready-up, on a fake clock: the layers with their real
 * fade lengths, the registry useFade keeps, and the report's own scheduling
 * (dueAt / moving / settle) -- driven by the steps in Lua's order. A reading
 * records what each layer draws AT THAT INSTANT: its final value once its fade
 * clock has settled, half way while it is still fading.
 */
function simulate(events, { endAt = 20000 } = {}) {
  let t = 0
  const now = () => t
  const reg = createFadeRegistry(now)
  const owner = {}
  const layers = {
    curtain: { ms: 600, shown: false }, lobby: { ms: 200, shown: true },
    hud: { ms: 200, shown: false }, ui: { ms: 120, shown: true },
  }
  for (const l of Object.values(layers)) l.clock = createFadeClock(l.shown, l.ms + FADE_SETTLE_MARGIN_MS, now)
  const state = { match: 'waiting', me: 'lobby', leaving: false, focus: 'lobby' }
  const readings = []
  let pending = null
  let due = Infinity

  const setLayer = (name, shown) => {
    const l = layers[name]
    if (l.clock.want(shown)) reg.open(name, l.clock, owner)
  }
  const closeDue = () => {
    for (const [name, l] of Object.entries(layers)) {
      if (reg.end(name) === 'fading' && l.clock.poll()) reg.close(name, 'transition', l.clock, owner)
    }
  }
  const arm = (why) => {
    pending ??= { why: [], first: t }
    pending.why.push(...why)
    due = dueAt(pending, t)
  }
  const take = () => {
    closeDue()
    const step = settle(pending, moving(reg.records(), t), t)
    if (!step.read) { due = t + step.waitMs; return }
    const show = (name) => {
      const l = layers[name]
      const op = l.clock.poll() ? (l.clock.shown ? 1 : 0) : 0.5
      return { opacity: op, visibility: op > 0 ? 'visible' : 'hidden', end: reg.end(name, pending.first) }
    }
    const showLobby = state.match === 'waiting' || state.me === 'lobby'
    const r = {
      ...reading({}), why: pending.why, ...state,
      wanted: wantedScreen({ frontendUp: false, leaving: state.leaving, focus: state.focus, showLobby,
        hudShown: !showLobby, scoped: false }),
      lobby: show('lobby'), hud: show('hud'), curtain: show('curtain'), ui: show('ui'),
      settling: step.settling,
    }
    readings.push({ t, fading: Object.keys(layers).filter((n) => !layers[n].clock.poll()), ...screenPayload(r) })
    pending = null
    due = Infinity
  }
  const queue = [...events].sort((a, b) => a.t - b.t)
  while (t <= endAt) {
    const next = Math.min(queue.length ? queue[0].t : Infinity, due)
    if (next === Infinity) break
    t = next
    closeDue()
    if (queue.length && queue[0].t === t) queue.shift().run({ state, setLayer, arm })
    else take()
  }
  return readings
}

/** Lua's ready-up, as the page receives it. */
function readyUp(coverMs, liftAfterHudMs) {
  const release = coverMs + 5
  return [
    { t: 0, run: ({ state, setLayer, arm }) => {
      state.leaving = true; state.focus = 'none'; setLayer('curtain', true); arm(['curtain up', 'focus lobby>none'])
    } },
    { t: coverMs, run: ({ arm }) => arm(['black']) },
    { t: release, run: ({ state, setLayer, arm }) => {
      state.match = 'warmup'; state.me = 'warmup'; setLayer('lobby', false); setLayer('hud', true)
      arm(['match waiting>warmup', 'me lobby>warmup', 'lobby off'])
    } },
    { t: release + liftAfterHudMs, run: ({ state, setLayer, arm }) => {
      state.leaving = false; setLayer('curtain', false); arm(['curtain down'])
    } },
  ]
}

console.log("the owner's ready-up on his own timings: two readings, both ok, neither mid-fade")
// His logs: the cover acknowledged 393-659ms in; the curtain lifting 1.25-1.36s
// after the HUD envelope (spawn.lua lowers it 250ms after 'in').
for (const [cover, lift] of [[393, 1250], [520, 1310], [659, 1360], [659, 1250], [393, 1360]]) {
  const rs = simulate(readyUp(cover, lift))
  check(`cover ${cover}ms, lift ${lift}ms after the HUD: two lines`, rs.length, 2)
  check('...each read with no fade in flight', rs.map((r) => r.fading), [[], []])
  check('...under the curtain, then on the HUD',
    rs.map((r) => [r.wanted, r.showing]), [['curtain', 'curtain'], ['hud', 'hud']])
  check('...neither forced on a healthy clock', rs.map((r) => r.forced), [false, false])
}

console.log('a reading that falls due mid-fade waits for it')
{
  // The curtain flapping every 400ms keeps re-arming until MAX_WAIT_MS forces
  // the reading due -- with the last toggle's fade still running.
  const flaps = []
  for (let i = 1; i <= 12; i++) {
    const up = i % 2 === 1
    flaps.push({ t: i * 400, run: ({ state, setLayer, arm }) => {
      state.leaving = up; setLayer('curtain', up); arm([up ? 'curtain up' : 'curtain down'])
    } })
  }
  const rs = simulate(flaps)
  const first = rs[0]
  check('the first reading is not taken at MAX_WAIT_MS, when the curtain is mid-fade',
    first.t > 400 + MAX_WAIT_MS, true)
  check('...it is taken once the fade has settled, with nothing in flight', first.fading, [])
  check('...and so it reads true: the curtain down, the lobby back', [first.wanted, first.showing],
    ['lobby', 'lobby'])
  check('...no sooner than the last fade settled and its aftermath passed',
    first.t >= 12 * 400 + 600 + FADE_SETTLE_MARGIN_MS + AFTERMATH_MS, true)
}
{
  // A layer that never stops moving: read at the give-up, marked settling.
  const forever = [{ t: 0, run: ({ arm }) => arm(['curtain up']) }]
  for (let i = 0; i < 60; i++) {
    forever.push({ t: 500 + i * 150, run: ({ setLayer }) => setLayer('hud', i % 2 === 0) })
  }
  const rs = simulate(forever, { endAt: 12000 })
  check('a layer that never settles is read SETTLE_GIVE_UP_MS after the reading fell due',
    rs[0]?.t, QUIET_MS + SETTLE_GIVE_UP_MS)
  check('...marked settling, naming it', rs[0]?.settling, 'hud')
}

// ── round 3: 'forced' belongs to the burst it happened in ──────────────────
console.log("a fade counts only in its own burst's line (round 3)")
{
  let t = 0
  const reg = createFadeRegistry(() => t)
  const owner = {}
  const gate = createFadeClock(true, 220, () => t)
  gate.want(false)
  reg.open('ui', gate, owner)
  check('a fade in flight is fading whatever the burst', reg.end('ui', 999), 'fading')
  t = 220
  reg.close('ui', 'forced', gate, owner)
  check("GTA's menu gate forced at 220ms counts in a burst that began before it", reg.end('ui', 100), 'forced')
  t = 60 * 60 * 1000
  check('...and not in a burst an hour later', reg.end('ui', t - 1000), undefined)
  check('...so that line is not marked forced',
    screenPayload(reading({ ui: { opacity: 1, visibility: 'visible', end: reg.end('ui', t - 1000) } })).forced, false)
  check('the records carry the time and what is left of a window',
    reg.records(), [{ name: 'ui', end: 'forced', at: 220, remaining: 0 }])

  const twin = {}
  const page = createFadeClock(false, 360, () => t)
  page.want(true)
  reg.open('page:help', page, owner)
  reg.drop('page:help', twin)
  check("a twin unmounting does not clear another layer's fade", reg.end('page:help'), 'fading')
  reg.drop('page:help', owner)
  check('a layer unmounting mid-fade clears its own, so the report does not wait on it',
    reg.end('page:help'), undefined)
}

// ── round 3: the sub-screens ────────────────────────────────────────────────
console.log('a sub-screen is part of what the page shows (round 3)')
{
  const want = (over) => wantedScreen({ frontendUp: false, leaving: false, focus: 'none', showLobby: false,
    hudShown: true, scoped: false, ...over })
  check('warmup with nothing open wants the HUD', want({}), 'hud')
  check('the pause menu over warmup is wanted while focus names it', want({ focus: 'pause' }), 'pause')
  check('the market over the lobby is wanted', want({ focus: 'market', showLobby: true, hudShown: false }), 'market')
  check("...but the market over warmup is not, whatever focus says -- it is the lobby's",
    want({ focus: 'market' }), 'hud')
  check('...nor the locker', want({ focus: 'locker' }), 'hud')
  check('the curtain is wanted over any sub-screen', want({ focus: 'pause', leaving: true }), 'curtain')
  check("GTA's menu wants nothing of ours", want({ frontendUp: true, focus: 'pause' }), 'nothing')
  check('the lobby wants the lobby', want({ focus: 'lobby', showLobby: true, hudShown: false }), 'lobby')

  const market = (over) => ({ name: 'market', phase: 'in', opacity: 1, visibility: 'visible', ...over })
  const left = reading({ pages: [market({})] })
  check('a sub-screen drawn over warmup is what shows, named', showing(left), 'market')
  const p = screenPayload(left)
  check('...so the line has it against the HUD it wanted', [p.wanted, p.showing], ['hud', 'market'])
  has('...and lists it in the evidence', p.detail, 'pages market on in (1)')
  check('one still on its way out, held at its first frame, is drawn too',
    showing(reading({ pages: [market({ phase: 'out' })] })), 'market')
  check('one at opacity 0 is not', showing(reading({ pages: [market({ opacity: 0 })] })), 'hud')
  check('the last mounted is the one on top',
    showing(reading({ pages: [market({}), { ...market({}), name: 'pause' }] })), 'pause')
  check('the curtain is over every sub-screen',
    showing(reading({ pages: [market({})], curtain: { opacity: 1, visibility: 'visible' } })), 'curtain')
  has('no sub-screen says so', screenPayload(reading({})).detail, 'pages none')
  check('a forced sub-screen entrance in this burst marks the line forced',
    screenPayload(reading({ pages: [market({ end: 'forced' })], wanted: 'market' })).forced, true)
  check('a reading taken anyway mid-fade carries the names for br_ui',
    screenPayload(reading({ settling: ['curtain', 'page:market'] })).settling, 'curtain, page:market')
  check('...and a normal one carries none', screenPayload(reading({})).settling, '')
}

// ── result ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error(`\ntest-fade: ${failed} failure(s) of ${ran} checks`)
  process.exit(1)
}
console.log(`test-fade: ok, ${ran} checks`)
