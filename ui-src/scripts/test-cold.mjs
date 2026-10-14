#!/usr/bin/env node
/**
 * THE FIRST ACTION AFTER AN IDLE, AND THE SWITCHES THAT TELL ITS CAUSES APART
 * (#252, round 4).
 *
 * Owner, 2026-10-13: the action and its sound happen at once, "but the UI
 * reaction itself ... takes several seconds. This gets worse the longer I let
 * my PC sit between actions." src/bridge/coldProbe.ts splits that wait into
 * marks and reports one line per cold action; br_ui/client/idle.lua prints
 * it (its half -- Lua's stamps, the line, the commands -- is pinned in
 * tools/test_client.lua).
 *
 * WHAT THIS PINS, each with the revert that fails it:
 *   * THE THRESHOLD: 30 s of no input and no DOM change, not 29.999 (change
 *     COLD_IDLE_MS, or stop a DOM change counting as activity);
 *   * THE MATH: A + B + C + D is the total, each from the mark it names (move a
 *     mark, or take `start` from the handler instead of the input's timeStamp);
 *   * ONE LINE PER COLD ACTION: a window at a time, never a line from frames
 *     alone, and the next only after another idle (open a window per input);
 *   * THE ACTION, NOT ITS SIDE EFFECTS: a DOM change before the call to Lua is
 *     provisional and the action's own commit replaces it; the page's own
 *     callbacks are never the action;
 *   * A PUSH WITH NO INPUT is a line too, by the envelope that caused it;
 *   * EVERY SWITCH OFF BY DEFAULT, AND NOTHING INSTALLED WHILE OFF: a `diag`
 *     envelope that says nothing installs no listener, observer, tap or timer
 *     (install anything at createDiag, or default a switch on);
 *   * THE SWITCHES ARE NOT ACTIVITY: a warm beat's own DOM changes do not hold
 *     off the cold line it is being A/B'd against.
 *
 * WHAT THIS CANNOT REACH: the real listeners, the dot outside <body> and the
 * observer on <body> (bridge/diag.ts) -- check-ui rule R37.
 *
 * Run: npm run test:cold   (and as part of npm run build)
 */

import {
  CAUSE_MS, COLD_COMMIT_MS, COLD_FRAMES_MS, COLD_IDLE_MS, COLD_PRESENT_MS, DIAG_OFF, FETCH_AFTER_INPUT_MS,
  PAINT_DEFAULT_MS, coldPayload, createColdTracker, createDiag, fmtMs, idleInventory, parseDiag,
} from '../src/bridge/coldProbe.ts'

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

const IGNORE = new Set(['br/sfx', 'br/ui/screen', 'br/cover', 'br/ui/cold', 'br/ui/idle'])
const ctx = (now) => ({ now, presentable: true, longtasks: [], heapMB: null })

// ── the threshold ────────────────────────────────────────────────────────────
console.log('cold means 30 s of no input and no DOM change')
{
  const t = createColdTracker(0, IGNORE)
  check('an input 29.999 s after arming is not cold', t.input('pointerdown', 29_999, 29_999), false)
  check('...and opens nothing', t.window, null)
  check('an input 30 s after the last one is', t.input('pointerdown', 59_999, 59_999), true)
  t.take()

  const u = createColdTracker(0, IGNORE)
  check('a DOM change outside a window is activity', u.mutation(20_000), false)
  check('so an input 30 s after arming but 29 s after it is not cold', u.input('click', 49_000, 49_000), false)
  check('the idle clock is the later of the two', u.lastActivity, 49_000)
}

// ── the math, on the owner's click ──────────────────────────────────────────
console.log('a saved look picked after five idle minutes: the parts add up to the total')
{
  const t = createColdTracker(0, IGNORE)
  check('pointerdown after 300 s opens the window', t.input('pointerdown', 299_998, 300_000), true)
  t.fetch('br/sfx', 300_090)                       // the page talking about itself
  t.input('click', 300_098, 300_100)
  t.fetch('br/locker2/wear', 300_101)
  t.envelope(812, 'locker2', 300_110)
  t.envelope(813, 'locker2', 300_111)
  check('the first DOM change after the call to Lua is the commit', t.mutation(300_112), true)
  check('a second one is not', t.mutation(300_113), false)
  t.setMark('brcold-1')
  check('the first frame after the commit', t.raf(301_900), 1)
  t.work(301_905)
  check('the next frame', t.raf(301_935), 2)
  check('a third is nobody\'s', t.raf(301_950), 0)
  check('a presentation time for another marker is not the commit\'s', t.presented('brcold-0', 301_920), false)
  check('the commit\'s is', t.presented('brcold-1', 301_930), true)
  check('due once both frames and the presentation are in', t.due(301_936, true), true)
  const w = t.take()
  const p = coldPayload(w, ctx(301_940))
  check('by the click that made the call, not the pointerdown', p.by, 'click')
  check('the callback is the action, not the page\'s own sound', p.cb, 'br/locker2/wear')
  check('A: the click\'s timeStamp -> the call to Lua', p.a, 3)
  check('B: the call -> the commit', p.b, 11)
  check('C: the commit -> the first frame', p.c, 1788)
  check('D: the first frame -> the next', p.d, 35)
  check('the total runs from the click\'s timeStamp to the second frame', p.total, 1837)
  check('A + B + C + D = the total', Math.round((p.a + p.b + p.c + p.d) * 10) / 10, p.total)
  check('E: the call -> the first envelope after it', p.e, 9)
  check('idle is whole seconds', p.idleS, 300)
  check('the envelopes after the call, relative to it', p.msgs, [{ s: 812, k: 'locker2', t: 9 }, { s: 813, k: 'locker2', t: 10 }])
  check('age: the call -> this report', p.age, 1839)
  has('the evidence has the first frame\'s main-thread work', p.detail, 'frame work 5.0')
  has('...and the commit\'s presentation, past the last rAF', p.detail, 'commit->presented 1818')
  has('...and the DOM changes', p.detail, '2 DOM changes')
  has('...and the first envelopes', p.detail, 'msgs locker2 #812 +9.0, locker2 #813 +10')
  check('fmtMs: one decimal under 10 ms, whole above, - unknown', [fmtMs(0.44), fmtMs(9.96), fmtMs(1837.4), fmtMs(-1)],
    ['0.4', '10.0', '1837', '-'])
}

// ── one line per cold action ────────────────────────────────────────────────
console.log('one line per cold action, never one per frame')
{
  const t = createColdTracker(0, IGNORE)
  check('frames with no window are nobody\'s', [t.raf(10), t.raf(20)], [0, 0])
  check('...and nothing is due', t.due(40_000, false), false)
  t.input('pointerdown', 40_000, 40_000)
  check('a second input inside the window opens nothing', t.input('pointerdown', 40_500, 40_500), false)
  t.take()
  check('an input 1 s after a cold action is not cold', t.input('pointerdown', 41_000, 41_000), false)
  check('nor 29 s after it', t.input('pointerdown', 70_000, 70_000), false)
  check('only another 30 s of idle opens the next', t.input('pointerdown', 100_000, 100_000), true)
}

// ── the action, not its side effects ────────────────────────────────────────
console.log('a change before the call to Lua is provisional; the action\'s own commit replaces it')
{
  const t = createColdTracker(0, IGNORE)
  t.input('pointerdown', 60_000, 60_000)
  check('pointerdown\'s own DOM change commits provisionally', t.mutation(60_002), true)
  t.setMark('brcold-1')
  t.raf(60_010); t.raf(60_020)
  check('not due while a call to Lua may still follow the input', t.due(60_500, false), false)
  t.input('click', 60_100, 60_100)
  check('the call replaces it', t.fetch('br/locker2/wear', 60_101), true)
  check('...and its frames and marker go with it', [t.window.commit, t.window.raf1, t.window.mark], [null, null, ''])
  t.envelope(9, 'locker2', 60_120)
  check('the push\'s change is the commit', t.mutation(60_121), true)
  t.raf(62_000); t.raf(62_030)
  const p = coldPayload(t.take(), { ...ctx(62_040), presentable: false })
  check('measured from the click to the push\'s frames', [p.a, p.b, p.total], [1, 20, 1930])
  has('a browser with no presentation timing says so', p.detail, 'presented n/a')

  const u = createColdTracker(0, IGNORE)
  u.input('pointerdown', 60_000, 60_000)
  u.input('click', 60_090, 60_090)
  u.mutation(60_091)
  u.raf(60_100); u.raf(60_110)
  check('a page-only answer is due once no call can follow', [u.due(61_089, false), u.due(61_091, false)], [false, true])
  const q = coldPayload(u.take(), ctx(61_091))
  check('...by the click, with no call and no E', [q.by, q.cb, q.a, q.b, q.e], ['click', '', 0, 1, -1])

  const v = createColdTracker(0, IGNORE)
  v.input('click', 60_000, 60_000)
  check('a call long after the input is not its action', v.fetch('br/locker2/wear', 60_000 + FETCH_AFTER_INPUT_MS + 1), false)
  check('the page\'s own callbacks never are', [v.fetch('br/ui/screen', 60_010), v.window.cb], [false, ''])
}

// ── a push with no input ────────────────────────────────────────────────────
console.log('a change Lua pushed after an idle is a line too')
{
  const t = createColdTracker(0, IGNORE)
  t.envelope(900, 'hud', 45_000)
  check('the envelope just before the change is its cause', t.mutation(45_000.4), true)
  t.raf(46_800); t.raf(46_830)
  const p = coldPayload(t.take(), ctx(46_840))
  check('by the push, with no input part', [p.by, p.cause, p.a], ['lua hud #900', 900, -1])
  check('B is the dispatch -> commit; the total runs from the arrival', [p.b, p.total], [0.4, 1830])
  check('age runs from the arrival, for Lua\'s transport arithmetic', p.age, 1840)

  const u = createColdTracker(0, IGNORE)
  u.envelope(901, 'lobby', 45_000)
  u.mutation(45_000 + CAUSE_MS + 1)
  check('an envelope too long before is not the cause', u.window.by, 'page')
}

// ── what a dead page still says ─────────────────────────────────────────────
console.log('a change that never comes, or never draws, is still one line')
{
  const t = createColdTracker(0, IGNORE)
  t.input('click', 50_000, 50_000)
  t.fetch('br/lobby/queue', 50_001)
  check('no commit: due at the window\'s limit, not before', [t.due(50_000 + COLD_COMMIT_MS - 1, true), t.due(50_000 + COLD_COMMIT_MS, true)], [false, true])
  const p = coldPayload(t.take(), ctx(65_000))
  check('every part after the handler unknown', [p.total, p.b, p.c, p.d], [-1, -1, -1, -1])
  has('and it says why', p.detail, 'no change within 15s')

  const u = createColdTracker(0, IGNORE)
  u.input('click', 50_000, 50_000)
  u.mutation(50_010)
  u.input('click', 50_010, 50_010)
  check('a commit and no frame: due at the frames\' limit', [u.due(50_010 + COLD_FRAMES_MS - 1, false), u.due(50_010 + COLD_FRAMES_MS, false)], [false, true])
  has('...saying so', coldPayload(u.take(), ctx(65_010)).detail, 'no frame within 15s of the commit')

  const v = createColdTracker(0, IGNORE)
  v.input('click', 50_000, 50_000)
  v.fetch('br/lobby/queue', 50_001)
  v.mutation(50_002); v.raf(50_010); v.raf(50_020)
  check('presentation that never comes is waited for only so long',
    [v.due(50_020 + COLD_PRESENT_MS - 1, true), v.due(50_020 + COLD_PRESENT_MS, true)], [false, true])
  has('...and named unknown', coldPayload(v.take(), ctx(53_020)).detail, 'presented ?')
}

// ── the switches: off by default, nothing installed while off ───────────────
console.log('every switch is off by default, and an unarmed page installs nothing')
{
  check('no envelope is all off', parseDiag(undefined), { ...DIAG_OFF, ask: null })
  check('an empty one is all off', parseDiag({}), { ...DIAG_OFF, ask: null })
  check('a malformed one is all off', parseDiag({ cold: 'yes', paint: { ms: 'x', mode: 'raster' }, warm: true }),
    { ...DIAG_OFF, ask: null })
  check('a paint period out of range is off, not clamped', parseDiag({ paint: { ms: 50, mode: 'raster' } }).paint, null)
  check('an unknown paint mode is off', parseDiag({ paint: { ms: 500, mode: 'blink' } }).paint, null)
  check('a warm period out of range is off', parseDiag({ warm: 100 }).warm, null)
  check('what is said is read', parseDiag({ cold: true, paint: { ms: PAINT_DEFAULT_MS, mode: 'comp' }, warm: 5000, ask: 3 }),
    { cold: true, paint: { ms: 500, mode: 'comp' }, warm: 5000, ask: 3 })
}

/** A browser that records what is done to it. */
function fakeEnv() {
  const e = {
    clock: 0,
    on: { listen: 0, observe: 0, longtasks: 0, presentation: 0 },
    off: { listen: 0, observe: 0, longtasks: 0, presentation: 0 },
    tapSet: null, input: null, mutate: null, present: null,
    intervals: new Map(), nextId: 1, rafs: [], laters: [], afters: [], settles: [],
    dots: [], flips: 0, warms: 0, marks: [], unmarks: [], sent: [],
    env: null,
  }
  const arm = (k, on, fn) => { (on ? e.on : e.off)[k]++; return on ? fn : null }
  e.env = {
    now: () => e.clock,
    ignore: IGNORE,
    listen: (on, fn) => { e.input = arm('listen', on, fn) },
    observe: (on, fn) => { e.mutate = arm('observe', on, fn) },
    longtasks: (on) => { arm('longtasks', on, null) },
    presentation: (on, fn) => { e.present = arm('presentation', on, fn); return on },
    tap: (t) => { e.tapSet = t },
    raf: (fn) => { e.rafs.push(fn) },
    afterFrame: (fn) => { e.afters.push(fn) },
    settle: (fn) => { e.settles.push(fn) },
    every: (ms, fn) => { const id = e.nextId++; e.intervals.set(id, { ms, fn }); return id },
    stop: (id) => { e.intervals.delete(id) },
    later: (ms, fn) => { e.laters.push({ at: e.clock + ms, fn }) },
    mark: (id) => { e.marks.push(id) },
    unmark: (id) => { e.unmarks.push(id) },
    dot: (mode) => { e.dots.push(mode) },
    flip: () => { e.flips++ },
    warm: () => { e.warms++; if (e.mutate) e.mutate() },   // React re-rendering into a DOM change
    heapMB: () => 23.4,
    inventory: () => ({ heapMB: 23.4, heapTotalMB: 31, nodes: 2314, animations: [], visible: 'visible', focused: true }),
    send: (what, payload) => { e.sent.push({ what, payload }) },
  }
  /** Move the clock, firing timers and frames as they fall due. */
  e.advance = (ms) => {
    const end = e.clock + ms
    for (;;) {
      const due = e.laters.filter((l) => l.at <= end).sort((a, b) => a.at - b.at)[0]
      if (!due) break
      e.laters.splice(e.laters.indexOf(due), 1)
      e.clock = Math.max(e.clock, due.at)
      due.fn()
    }
    e.clock = end
  }
  e.frame = () => {
    const fns = e.rafs.splice(0)
    for (const f of fns) f()
    for (const f of e.afters.splice(0)) f()
  }
  return e
}

{
  const e = fakeEnv()
  const d = createDiag(e.env)
  check('creating it installs nothing', [e.on, e.tapSet, e.intervals.size], [{ listen: 0, observe: 0, longtasks: 0, presentation: 0 }, null, 0])
  d.apply(parseDiag({}))
  check('an envelope that says nothing installs nothing',
    [e.on, e.tapSet, e.intervals.size, e.rafs.length, e.laters.length, e.dots, e.sent.length],
    [{ listen: 0, observe: 0, longtasks: 0, presentation: 0 }, null, 0, 0, 0, [], 0])
  e.advance(600_000)
  check('ten idle minutes later: no timer ran, no frame was asked for, nothing was sent',
    [e.flips, e.warms, e.rafs.length, e.sent.length], [0, 0, 0, 0])

  d.apply(parseDiag({ cold: true }))
  check('arming the cold line installs the listeners, the observers and the taps',
    [e.on, e.tapSet !== null], [{ listen: 1, observe: 1, longtasks: 1, presentation: 1 }, true])
  check('...and no timer and no frame request', [e.intervals.size, e.laters.length, e.rafs.length], [0, 0, 0])
  d.apply(parseDiag({ cold: true }))
  check('the same envelope again installs nothing twice', e.on.listen, 1)
  d.apply(parseDiag({}))
  check('disarming takes every one of them away', [e.off, e.tapSet], [{ listen: 1, observe: 1, longtasks: 1, presentation: 1 }, null])

  d.apply(parseDiag({ paint: { ms: 500, mode: 'raster' } }))
  const [paint] = [...e.intervals.values()]
  check('bruipaint on: one interval at its period, and its dot', [e.intervals.size, paint?.ms, e.dots], [1, 500, [null, 'raster']])
  paint.fn(); paint.fn()
  check('each beat is one flip of the dot', e.flips, 2)
  d.apply(parseDiag({ paint: { ms: 250, mode: 'raf' } }))
  const [raf] = [...e.intervals.values()]
  raf.fn()
  check('raf mode: no dot, one frame request a beat', [e.intervals.size, e.dots.at(-1), e.rafs.length, e.flips], [1, null, 1, 2])
  e.rafs.length = 0
  d.apply(parseDiag({}))
  check('bruipaint off: the interval and the dot are gone', [e.intervals.size, e.dots.at(-1)], [0, null])

  d.apply(parseDiag({ cold: true, warm: 5000 }))
  const [warm] = [...e.intervals.values()]
  check('bruiwarm on: one interval at its period', [e.intervals.size, warm?.ms], [1, 5000])
  const before = d.tracker.lastActivity
  e.clock += 40_000
  warm.fn()
  check('a beat re-renders the tree once', e.warms, 1)
  e.settles.splice(0).forEach((f) => f())
  check('...and the DOM change it caused is the switch\'s, not activity',
    [d.tracker.lastActivity, d.stats.warmMutations, d.stats.warmBeats], [before, 1, 1])
  e.mutate()
  check('a real change after it is activity again', d.tracker.lastActivity, e.clock)
  d.apply(parseDiag({}))
  check('bruiwarm off: the interval is gone', e.intervals.size, 0)

  d.apply(parseDiag({ cold: true, paint: { ms: 500, mode: 'comp' }, warm: 5000, ask: 1 }))
  const idle = e.sent.find((s) => s.what === 'idle')
  has('bruiidle answers once, with the switches it runs', idle?.payload.text, 'paint comp every 500ms: 0 beats')
  has('...and what the page holds', idle?.payload.text, 'heap 23.4/31.0MB, 2314 nodes')
  check('...and only when asked', e.sent.filter((s) => s.what === 'idle').length, 1)
  d.apply(parseDiag({}))
}

// ── one line per cold action, through the whole controller ──────────────────
console.log('the controller sends one line per cold action, whatever the frames do')
{
  const e = fakeEnv()
  const d = createDiag(e.env)
  d.apply(parseDiag({ cold: true }))
  e.advance(300_000)
  e.input('pointerdown', e.clock - 2)
  e.advance(100)
  e.input('click', e.clock - 2)
  e.advance(1)
  e.tapSet.fetch('br/locker2/wear')
  e.advance(9)
  e.tapSet.envelope(812, 'locker2')
  e.mutate()
  check('the commit adds its marker and asks for a frame', [e.marks, e.rafs.length], [['brcold-1'], 1])
  e.advance(1788)
  e.frame()
  e.advance(35)
  e.frame()
  e.present('brcold-1', e.clock - 5)
  e.advance(0)
  const lines = () => e.sent.filter((s) => s.what === 'cold')
  check('one line, at the second frame and the presentation', lines().length, 1)
  check('...and its marker taken away', e.unmarks, ['brcold-1'])
  const p = lines()[0]?.payload
  check('carrying the parts', p && [p.by, p.a, p.b, p.c, p.d, p.total, p.idleS], ['click', 3, 9, 1788, 35, 1835, 300])
  for (let i = 0; i < 50; i++) { e.advance(16); e.frame(); e.input('click', e.clock); e.mutate() }
  e.advance(60_000)
  check('fifty busy frames, inputs and changes later: still one line', lines().length, 1)
  e.advance(COLD_IDLE_MS)
  e.input('keydown', e.clock)
  e.advance(COLD_COMMIT_MS + 2)
  check('the next cold action is the next line', lines().length, 2)
  has('...and one that changed nothing says so', lines()[1]?.payload.detail, 'no change within 15s')
  d.apply(parseDiag({}))
  check('every marker it added was taken away', e.marks.every((m) => e.unmarks.includes(m)), true)
}

// ── the inventory, unarmed ──────────────────────────────────────────────────
console.log('the inventory says what it cannot count')
{
  const page = { heapMB: null, heapTotalMB: null, nodes: 10, animations: ['spin on leave-spinner'], visible: 'visible', focused: false }
  const stats = { armedAt: 0, envelopes: new Map(), mutations: 0, longtasks: [], paintOn: 0, paintBeats: 0, paintMs: 0,
    warmOn: 0, warmBeats: 0, warmMs: 0, warmMutations: 0 }
  const text = idleInventory(DIAG_OFF, stats, null, 1000, page)
  has('the cold probe off: no counts', text, 'cold probe off (no counts)')
  has('a running animation is named', text, '1 running animations (spin on leave-spinner)')
  has('the switches off', text, 'paint off | warm off')
}

console.log(`\n${ran - failed}/${ran} passed`)
if (failed > 0) {
  console.error(`test-cold: ${failed} failed`)
  process.exit(1)
}
