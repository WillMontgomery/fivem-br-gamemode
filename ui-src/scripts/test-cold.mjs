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
 * EVERYTHING HERE GOES THROUGH THE CONTROLLER on a fake browser (inputs, taps,
 * DOM changes, tasks, frames, presentation entries, timers), with LITERAL
 * times: no threshold is imported, so changing one fails a check. What it
 * pins, each with the revert that fails it:
 *
 *   * IDLE IS INPUT IDLE: 30 s, not 29.999; a ticking DOM does not hold the
 *     line off and is reported ("DOM still"); an input that came to nothing
 *     (a key on the way back from Alt-tab) does not reset it;
 *   * THE REACTION IS THE LAST CHANGE THE ACTION MADE, not the first: the
 *     Locker's loading ring, then the new choice 1.8 s later; the line waits
 *     5 s of quiet (not 3, not 1); later-task ticks neither end nor extend it;
 *   * THE ACTION: a call in the input's own task however slow the handler
 *     (not "within 1 s"); a drag-spin that changed nothing is taken over by
 *     the pick; a re-click is counted (`later`) and the first click stays;
 *     another action after the reaction ends it;
 *   * CAUSES: a change is a push's only in that push's task -- a lobby
 *     envelope 0.3 s before a page tick is not its cause -- and the next
 *     input ends a window no input opened, then gets its own;
 *   * PAST THE LAST FRAME: presentation is waited for 15 s (an entry 4 s
 *     after the second frame is taken), renderTime 0 is refused, and the
 *     self-test tells "n/a" (never reported) from "?" (late);
 *   * EVERY EVIDENCE FIELD: push->commit, frame work, the first change and
 *     its frames, the frame clock after the input, the first pointer move,
 *     long tasks inside the window only (and at most 64 kept), DOM still,
 *     the burst, the input's timeStamp only when it is on the page clock;
 *   * NO MARKER LEAKS: every Element Timing marker added is taken away;
 *   * EVERY SWITCH OFF BY DEFAULT, AND NOTHING INSTALLED WHILE OFF; warm
 *     beats never overlap; the inventory's rates are per second over at
 *     least one.
 *
 * WHAT THIS CANNOT REACH: the real listeners, the dot outside <body>, the
 * observer on <body> and the task-end message (bridge/diag.ts) -- check-ui
 * rule R37.
 *
 * Run: npm run test:cold   (and as part of npm run build)
 */

import {
  DIAG_OFF, coldPayload, createDiag, fmtMs, idleInventory, parseDiag,
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

function lacks(label, line, part) {
  ran++
  const ok = typeof line === 'string' && !line.includes(part)
  if (!ok) failed++
  console.log(ok ? `  ok    ${label}` : `  FAIL  ${label}\n          line     ${line}\n          has      ${part}`)
}

const IGNORE = new Set(['br/sfx', 'br/ui/screen', 'br/cover', 'br/ui/cold', 'br/ui/idle'])

/** A browser that records what is done to it, with tasks, frames and timers stepped by hand. */
function fakeEnv({ elementTiming = true } = {}) {
  const e = {
    clock: 0,
    on: { listen: 0, observe: 0, longtasks: 0, presentation: 0 },
    off: { listen: 0, observe: 0, longtasks: 0, presentation: 0 },
    tapSet: null, listener: null, mutate: null, present: null, longtask: null,
    intervals: new Map(), nextId: 1, rafs: [], laters: [], afters: [], ends: [], settles: [],
    dots: [], flips: 0, warms: 0, marked: [], unmarked: [], live: new Set(), maxLive: 0, sent: [],
    env: null,
  }
  const arm = (k, on, fn) => { (on ? e.on : e.off)[k]++; return on ? fn : null }
  e.env = {
    now: () => e.clock,
    ignore: IGNORE,
    listen: (on, fn) => { e.listener = arm('listen', on, fn) },
    observe: (on, fn) => { e.mutate = arm('observe', on, fn) },
    longtasks: (on, fn) => { e.longtask = arm('longtasks', on, fn) },
    presentation: (on, fn) => { e.present = arm('presentation', on, fn); return on && elementTiming },
    tap: (t) => { e.tapSet = t },
    raf: (fn) => { e.rafs.push(fn) },
    afterFrame: (fn) => { e.afters.push(fn) },
    taskEnd: (fn) => { e.ends.push(fn) },
    settle: (fn) => { e.settles.push(fn) },
    every: (ms, fn) => { const id = e.nextId++; e.intervals.set(id, { ms, fn }); return id },
    stop: (id) => { e.intervals.delete(id) },
    later: (ms, fn) => { e.laters.push({ at: e.clock + ms, fn }) },
    mark: (id) => { e.marked.push(id); e.live.add(id); e.maxLive = Math.max(e.maxLive, e.live.size) },
    unmark: (id) => { e.unmarked.push(id); e.live.delete(id) },
    dot: (mode) => { e.dots.push(mode) },
    flip: () => { e.flips++ },
    warm: () => { e.warms++; if (e.mutate) e.mutate() },   // React re-rendering into a DOM change
    heapMB: () => 23.4,
    inventory: () => ({ heapMB: 23.4, heapTotalMB: 31, nodes: 2314, animations: [], visible: 'visible', focused: true }),
    send: (what, payload) => { e.sent.push({ what, payload, at: e.clock }) },
  }
  /** The current task is over: its task-end messages run. */
  e.endTask = () => { for (const f of e.ends.splice(0)) f() }
  /** Time passing between tasks, firing timers as they fall due. */
  e.advance = (ms) => {
    e.endTask()
    const end = e.clock + ms
    for (;;) {
      const due = e.laters.filter((l) => l.at <= end).sort((a, b) => a.at - b.at)[0]
      if (!due) break
      e.laters.splice(e.laters.indexOf(due), 1)
      e.clock = Math.max(e.clock, due.at)
      due.fn()
      e.endTask()
    }
    e.clock = end
  }
  /** Time passing inside a task (a slow handler, a render). */
  e.busy = (ms) => { e.clock += ms }
  /** An animation frame: its callbacks, then (workMs later) the work probe's message. */
  e.frame = (workMs = 0) => {
    e.endTask()
    for (const f of e.rafs.splice(0)) f()
    e.clock += workMs
    for (const f of e.afters.splice(0)) f()
  }
  e.input = (kind, ts = e.clock) => e.listener(kind, ts)
  e.move = () => e.listener('pointermove', e.clock)
  e.call = (name) => e.tapSet.fetch(name)
  e.push = (s, k) => e.tapSet.envelope(s, k)
  /** A push whose handler changes the DOM in its own task, `renderMs` later. */
  e.pushChange = (s, k, renderMs = 2) => { e.push(s, k); e.busy(renderMs); e.mutate(); e.endTask() }
  /** pointerdown, pointerup, click; the click's handler calls `name` in its own task (left open). */
  e.click = (name) => {
    e.input('pointerdown'); e.endTask()
    e.input('pointerup'); e.endTask()
    e.input('click')
    if (name) e.call(name)
  }
  e.presentLive = (renderTime) => { for (const id of [...e.live]) if (id !== 'brcold-self') e.present(id, renderTime) }
  e.lines = () => e.sent.filter((s) => s.what === 'cold')
  e.last = () => e.lines().at(-1)?.payload
  return e
}

/** Armed, with the Element Timing self-test answered. */
function armed(opts) {
  const e = fakeEnv(opts)
  const d = createDiag(e.env)
  d.apply(parseDiag({ cold: true }))
  if (e.present && e.live.has('brcold-self')) e.present('brcold-self', 16)
  return { e, d }
}

// ── idle is input idle ──────────────────────────────────────────────────────
console.log('cold means 30 s of no input; the DOM can tick')
{
  const { e, d } = armed()
  e.advance(29_999)
  e.input('pointerdown')
  check('an input 29.999 s after arming is not cold', d.tracker.window, null)
  e.advance(30_000)
  e.input('pointerdown')
  check('an input 30 s after the last one is', d.tracker.window?.kind, 'input')
}
{
  const { e, d } = armed()
  for (let t = 0; t < 300_000; t += 5_000) { e.advance(5_000); e.mutate(); e.endTask() }
  e.advance(100)
  e.click('br/locker/pick')
  check('a DOM ticking every 5 s does not hold the line off', d.tracker.window?.kind, 'input')
  e.push(500, 'locker'); e.busy(2); e.mutate(); e.endTask()
  e.frame(); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  has('...and the line says how long the DOM had been still', e.last()?.detail, 'DOM still 0.1s before')
  check('...and the ticks made no line of their own', e.lines().length, 1)
  check('...with the idle since the last input', e.last()?.idleS, 300)
}

// ── the owner's pick: the reaction is the last change, not the first ───────
console.log('a Locker pick after five idle minutes: the ring at once, the new choice 1.8 s later')
{
  const { e, d } = armed()
  e.advance(300_000)
  const t0 = e.clock
  e.input('pointerdown', t0 - 2); e.endTask()
  e.busy(98)
  e.input('pointerup'); e.endTask()
  e.input('click', e.clock - 2)
  e.call('br/sfx')                                   // the page talking about itself
  e.busy(1)
  e.call('br/locker/pick')                           // the action, in the click's task
  e.endTask()
  e.advance(4)
  e.pushChange(500, 'locker', 3)                     // the loading ring
  e.advance(2); e.frame(2); e.advance(16); e.frame()
  e.present('brcold-1', e.clock)
  e.advance(1774)
  e.pushChange(501, 'locker', 2)                     // the new choice
  const hl = e.clock
  e.advance(30); e.frame(5); e.advance(16); e.frame()
  e.presentLive(e.clock + 8)
  e.advance(4999 - (e.clock - hl))
  check('nothing sent until the DOM has been quiet 5 s', e.lines().length, 0)
  e.advance(1)
  check('...and the line at exactly 5 s', [e.lines().length, e.lines()[0]?.at - hl], [1, 5000])
  const p = e.last()
  check('by the click that made the call, not the pointerdown', [p.by, p.cb], ['click', 'br/locker/pick'])
  check('A: the click\'s timeStamp -> the call to Lua', p.a, 3)
  check('B: the call -> the NEW CHOICE\'s change, not the ring\'s', p.b, 1803)
  check('C, D: that change\'s frames', [p.c, p.d], [30, 21])
  check('the total runs from the click\'s timeStamp to its second frame', p.total, 1857)
  check('A + B + C + D = the total', Math.round((p.a + p.b + p.c + p.d) * 10) / 10, p.total)
  check('E is the page\'s round trip to the push the change landed with', [p.e, p.push], [1801, { s: 501, k: 'locker', t: 1801 }])
  check('idle is whole seconds of no input', p.idleS, 300)
  has('push->commit: the page\'s own time from that push to its change', p.detail, 'push->commit 2.0 (locker #501)')
  has('the frame\'s main-thread work', p.detail, 'frame work 5.0')
  has('the change\'s presentation, past the last rAF', p.detail, 'commit->presented 59')
  has('the first change, with its own frames: the first frame after the idle', p.detail,
    'first change +10 (locker #500): rAF 2.0, next 18, presented 20')
  has('the frame clock after the input', p.detail, 'input->rAF')
  has('no pointer move before the click, said', p.detail, 'no pointer move first')
  has('the changes', p.detail, '2 DOM changes')
  has('the envelopes after the call, with the largest burst', p.detail, '2 envelopes after the call (locker 2), at most 1 within 20ms at +4.0')
  has('three inputs, one action', p.detail, '3 inputs')
  check('every marker it added was taken away', [e.live.size, e.marked.length > 2], [0, true])
}

// ── the action ──────────────────────────────────────────────────────────────
console.log('the action: a slow handler, a re-click, a drag-spin, another action after')
{
  const { e } = armed()
  e.advance(60_000)
  e.input('click')
  e.busy(1_200)                                      // a cold handler: 1.2 s of JavaScript before the call
  e.call('br/locker/pick')
  e.endTask()
  e.advance(5)
  e.pushChange(10, 'locker', 5)
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  const p = e.last()
  check('a call made in the input\'s task is its action, however slow', [p?.cb, p?.a, p?.b], ['br/locker/pick', 1200, 10])
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(4); e.pushChange(500, 'locker')          // the ring
  e.advance(794)
  e.click('br/locker/pick'); e.endTask()             // nothing seen yet: the owner clicks again
  e.advance(1001); e.pushChange(501, 'locker')       // the new choice
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  const p = e.last()
  check('a re-click: the first click stays the action, and Lua is told one more call followed', [p?.later, p?.b], [1, 1803])
  has('...and it is said', p?.detail, 're-clicked 1x')
}
{
  const { e } = armed()
  e.advance(300_000)
  e.input('pointerdown'); e.endTask()
  for (let i = 0; i < 20; i++) { e.advance(i === 0 ? 100 : 50); e.call('br/locker/spin'); e.endTask() }  // from pointermove
  e.advance(1_050)
  e.input('pointerup'); e.endTask()
  e.advance(1_000)
  e.input('pointerdown'); e.endTask()
  e.advance(50)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(70, 'locker', 4)
  e.frame(); e.advance(10); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  const p = e.last()
  check('a drag-spin that changed nothing: the pick takes the window over', [p?.cb, p?.by, p?.b, p?.later], ['br/locker/pick', 'click', 9, 0])
  has('...and says so', p?.detail, 'took over from br/locker/spin')
}
{
  const { e, d } = armed()
  e.advance(60_000)
  e.input('click'); e.endTask()
  e.advance(999)
  e.call('br/locker/pick'); e.endTask()              // a handler that awaited first: outside the click's task
  check('a call 0.999 s after the input, outside its task, is still its action', d.tracker.window?.cb, 'br/locker/pick')
}
{
  const { e, d } = armed()
  e.advance(60_000)
  e.input('click'); e.endTask()
  e.advance(1_001)
  e.call('br/locker/pick'); e.endTask()
  check('...1.001 s after it, not', d.tracker.window?.cb, '')
  e.advance(15_000)
  check('...and the input, having led to nothing, prints nothing', e.lines().length, 0)
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(1_800); e.pushChange(501, 'locker')
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(1_000)
  e.click('br/lobby/ready'); e.endTask()             // another action, warm
  e.advance(3); e.pushChange(502, 'lobby')
  check('another action after the reaction ends it: the line goes at once', e.lines().length, 1)
  const p = e.last()
  check('...measuring the first action only', [p?.cb, p?.b], ['br/locker/pick', 1802])
  has('...and says what ended it', p?.detail, 'ended by br/lobby/ready')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(1_800); e.pushChange(501, 'locker')      // its frames still to come
  e.advance(8)
  e.click('br/lobby/ready'); e.endTask()
  e.advance(3); e.pushChange(502, 'lobby')           // the other action's change, while the window waits on frames
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  const p = e.last()
  check('a change after the other action is not the reaction, even with the window still open', [e.lines().length, p?.b], [1, 1802])
  has('...it is counted past the window', p?.detail, '2 DOM changes, 1 past the window')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.input('click'); e.endTask()                      // a handler that awaits before its call
  e.advance(100); e.pushChange(90, 'party')          // meanwhile a push changes the page
  e.advance(100); e.call('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(91, 'locker')
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  const p = e.last()
  check('a push\'s change before the call is not the action\'s', [p?.cb, p?.b, p?.push?.s], ['br/locker/pick', 7, 91])
  has('...it is counted apart', p?.detail, '2 DOM changes, 1 by a push before the call')
}

// ── causes ──────────────────────────────────────────────────────────────────
console.log('a change is a push\'s only in that push\'s task')
{
  const { e } = armed()
  for (let t = 0; t < 59_900; t += 333) { e.advance(333); e.push(100 + t, 'lobby'); e.endTask() }  // chatter, changing nothing
  e.advance(60_000 - e.clock)
  e.mutate(); e.endTask()                            // a page tick, 0.3 s after a lobby envelope
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(400 - 16)
  e.click('br/locker/pick'); e.endTask()
  check('the click ends that window: its line goes first', e.lines().length, 1)
  const w = e.lines()[0]?.payload
  check('...by the page\'s own clock, not the lobby envelope before it', [w?.by, w?.cause, w?.cb], ['page', 0, ''])
  has('...cut by the input', w?.detail, 'cut by an input at +400')
  e.advance(4); e.pushChange(900, 'locker', 2)
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  const p = e.last()
  check('and the click gets a line of its own, its action intact', [e.lines().length, p?.by, p?.cb, p?.b], [2, 'click', 'br/locker/pick', 6])
  has('...saying the page had just changed', p?.detail, 'DOM still 0.4s before')
}
{
  const { e } = armed()
  e.advance(45_000)
  e.pushChange(900, 'hud', 1)                        // a push, its change in its own task
  e.advance(1_800); e.frame(); e.advance(30); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  const p = e.last()
  check('a change Lua pushed after an idle is a line by that push', [p?.by, p?.cause, p?.a, p?.cb], ['lua hud #900', 900, -1, ''])
  check('B is its arrival -> its change; the total runs from the arrival', [p?.b, p?.total], [1, 1831])
  check('...sent 5 s after its change, age running from the arrival', [e.lines()[0]?.at, p?.age], [50_001, 5001])
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  for (let i = 0; i < 3; i++) { e.advance(1_000); e.mutate(); e.endTask() }  // a clock ticking every second
  e.advance(500); e.pushChange(501, 'locker')
  const hl = e.clock
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(1_000); e.mutate(); e.endTask()
  e.advance(1_000); e.mutate(); e.endTask()
  e.advance(4_999 - (e.clock - hl))
  check('ticks in later tasks: no line a millisecond before 5 s of quiet after the push\'s change', e.lines().length, 0)
  e.advance(1)
  check('...nor after it: they neither end the reaction nor extend it', [e.lines().length, e.lines()[0]?.at - hl], [1, 5000])
  const p = e.last()
  check('...the reaction is the push\'s change', p?.b, 3502)
  has('...and the ticks are counted apart', p?.detail, '6 DOM changes, 5 in later tasks')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(14_000); e.pushChange(501, 'locker')     // 14 s: still the reaction (its frames late)
  e.advance(1_016); e.pushChange(502, 'locker')      // 15.02 s: past the window
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  const p = e.last()
  check('a change more than 15 s after the call is not the reaction', [e.lines().length, p?.b], [1, 14002])
  has('...it is counted as past the window', p?.detail, '2 DOM changes, 1 past the window')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(14_000); e.pushChange(501, 'locker')
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(74_999 - e.clock)
  check('the quiet is cut short at 15 s after the call: not before', e.lines().length, 0)
  e.advance(1)
  check('...then the line', [e.lines().length, e.lines()[0]?.at - 60_000], [1, 15000])
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker2/wear'); e.endTask()
  e.advance(6); e.push(77, 'locker2'); e.endTask()
  e.advance(1); e.mutate(); e.endTask()              // the change only in a later task
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  const p = e.last()
  has('with no push or input change, the first later-task change stands in, and says so', p?.detail,
    'commit in a later task, 1.0 after locker2 #77')
  check('...with the push before it for Lua', p?.push, { s: 77, k: 'locker2', t: 6 })
}

// ── nothing, or nothing yet ─────────────────────────────────────────────────
console.log('an input that came to nothing; a call that changed nothing; a page-only answer')
{
  const { e, d } = armed()
  e.advance(299_000)
  e.move()                                           // back at the desk
  e.frame(); e.advance(16); e.frame()
  e.advance(1_000 - 16)
  e.input('keydown'); e.endTask()                    // Alt, on the way back
  e.advance(15_000)
  check('a key that changed nothing prints nothing', e.lines().length, 0)
  e.advance(1_000)
  e.click('br/locker/pick')
  check('...and does not reset the idle: a click 16 s later is still cold', d.tracker.window?.idleMs, 316_000)
  check('...nor lose the first pointer move after it', d.tracker.window?.hover?.at, 299_000)
}
{
  const { e, d } = armed()
  e.advance(300_000)
  e.input('keydown'); e.endTask()
  e.advance(2_000)
  e.click('br/locker/pick'); e.endTask()
  check('a click 2 s after it becomes the window\'s opener', [d.tracker.window?.by, d.tracker.window?.inputTs], ['click', e.clock])
}
{
  const { e, d } = armed()
  e.advance(60_000)
  e.click('br/lobby/queue'); e.endTask()
  const at = e.clock
  e.advance(14_999)
  check('a call that changed nothing: not before 15 s', e.lines().length, 0)
  e.advance(1)
  check('...then one line', [e.lines().length, e.lines()[0]?.at - at], [1, 15000])
  has('...saying so', e.last()?.detail, 'no change within 15s')
  check('...every part after the handler unknown', [e.last()?.total, e.last()?.b, e.last()?.c, e.last()?.d], [-1, -1, -1, -1])
  e.advance(20_000)
  e.click('br/locker/pick')
  check('...and the next click is still cold', d.tracker.window?.kind, 'input')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.input('pointerdown')
  e.busy(1); e.mutate(); e.endTask()                 // the page answers in the input's own task, no call
  const ch = e.clock
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(4_999 - (e.clock - ch))
  check('a page-only answer waits out the quiet', e.lines().length, 0)
  e.advance(1)
  const p = e.last()
  check('...then is a line by that input, with no call and no E', [p?.by, p?.cb, p?.a, p?.b, p?.e], ['pointerdown', '', 0, 1, -1])
  has('...made by the input', p?.detail, 'commit by input pointerdown')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.input('pointerdown'); e.endTask()
  e.advance(2); e.mutate(); e.endTask()              // a later-task change first
  e.input('pointerup'); e.busy(1); e.mutate()        // the input's own answer: provisional, its own marker
  e.endTask()
  const liveBefore = e.live.size
  e.input('click'); e.call('br/locker/pick'); e.endTask()
  check('a call replaces the page\'s provisional answer, and its marker goes', [liveBefore, e.live.size], [2, 1])
  e.advance(4); e.pushChange(5, 'locker')
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  check('...the line by the call', [e.last()?.cb, e.last()?.by], ['br/locker/pick', 'click'])
  check('...and no marker left', e.live.size, 0)
}

// ── past the last frame ─────────────────────────────────────────────────────
console.log('presentation: waited for 15 s, and "?" told from "n/a"')
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker', 3)
  e.frame(); e.advance(17); e.frame()
  const raf2 = e.clock
  const id = [...e.live].find((x) => x !== 'brcold-self')
  e.advance(6_000)
  e.present(id, 0)
  check('renderTime 0 is refused', e.lines().length, 0)
  e.present(id, e.clock)
  check('an entry 6 s after the second frame is taken, and the line goes then', [e.lines().length, e.lines()[0]?.at - raf2], [1, 6000])
  has('...with it', e.last()?.detail, 'commit->presented 6017')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker', 3)
  e.frame(); e.advance(17); e.frame()
  const raf2 = e.clock
  e.advance(14_999)
  check('no entry: not given up before 15 s past the second frame', e.lines().length, 0)
  e.advance(1)
  check('...then the line', [e.lines().length, e.lines()[0]?.at - raf2], [1, 15000])
  has('...saying it waited, not that it cannot', e.last()?.detail, 'presented ? (none in 15s)')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker', 3)
  e.frame(); e.advance(17); e.frame()
  e.present('brcold-99', e.clock)                    // somebody else's marker
  e.advance(5_000)
  check('an entry for another marker is not the change\'s', e.lines().length, 0)
  e.presentLive(e.clock)
  has('...its own is', e.last()?.detail, 'commit->presented 5017')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  for (let i = 0; i < 4; i++) { e.advance(300); e.pushChange(10 + i, 'locker') }  // four changes, each the reaction in turn
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  check('a reaction replaced lets its marker go: never more than two alive, none after', [e.maxLive, e.live.size, e.marked.length], [2, 0, 5])
  check('...and the reaction is the last of them', e.last()?.b, 1208)
}
{
  const { e } = armed()
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker')
  const ch = e.clock
  e.advance(14_999)
  check('no frame at all: not given up before 15 s after the change', e.lines().length, 0)
  e.advance(1)
  has('...then said', e.last()?.detail, 'no frame within 15s of the commit')
}
{
  const e = fakeEnv()
  const d = createDiag(e.env)
  d.apply(parseDiag({ cold: true }))
  check('arming marks the self-test once', e.marked, ['brcold-self'])
  e.advance(14_999)
  check('...and waits 15 s for it', d.selftest.state, 'waiting')
  e.advance(1)
  check('...no entry: Element Timing is not reported here', [d.selftest.state, e.live.has('brcold-self')], ['none', false])
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker')
  e.frame(); e.advance(16); e.frame()
  e.advance(5_000)
  check('...so a line adds no marker and does not wait', [e.marked.length, e.lines().length], [1, 1])
  has('...and says n/a, and why', e.last()?.detail, 'presented n/a (self-test: no entry in 15s)')
  d.apply(parseDiag({ ask: 1, cold: true }))
  has('bruiidle shows the self-test', e.sent.find((s) => s.what === 'idle')?.payload.text, 'element timing: self-test: no entry in 15s')
}
{
  const { e, d } = armed()
  check('a self-test entry: works', [d.selftest.state, d.selftest.ms], ['ok', 16])
  d.apply(parseDiag({ ask: 1, cold: true }))
  has('...in bruiidle', e.sent.find((s) => s.what === 'idle')?.payload.text, 'element timing: self-test ok, presented +16')
}
{
  const { e } = armed({ elementTiming: false })
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker')
  e.frame(); e.advance(16); e.frame()
  e.advance(5_000)
  check('no Element Timing: never a marker', e.marked, [])
  has('...and n/a, with why', e.last()?.detail, 'presented n/a (no Element Timing)')
}

// ── the evidence ────────────────────────────────────────────────────────────
console.log('every piece of evidence on the line')
{
  const { e, d } = armed()
  e.advance(100_000)
  e.longtask(98_000, 300)                           // before the window: not this action's
  e.move()                                           // back at the desk: a hover repaints first
  e.advance(40); e.frame(); e.advance(16); e.frame()
  e.advance(1_944)
  e.click('br/locker/pick')
  const click = e.clock
  e.endTask()
  e.advance(30); e.frame(); e.advance(700); e.frame()  // the frame clock after the input
  e.longtask(click + 100, 120)
  e.advance(1_000)
  e.push(599, 'lobby'); e.endTask(); e.advance(30)                                  // 30 ms before: not in it
  for (let i = 0; i < 5; i++) { e.push(600 + i, 'lobby'); e.endTask(); e.advance(4) }  // a burst
  e.pushChange(606, 'locker', 3)
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  const p = e.last()
  has('the first pointer move after the idle, and its frames', p?.detail, 'pointer moved 2.0s before: rAF 40, next 16')
  has('the frame clock after the input', p?.detail, 'input->rAF 30, next 700')
  has('long tasks inside the window only', p?.detail, 'long tasks 1 (120)')
  has('the heap', p?.detail, 'heap 23.4MB')
  has('a burst of envelopes, and when', p?.detail, '7 envelopes after the call (lobby 6, locker 1), at most 6 within 20ms at +1760')
  check('long tasks kept: at most 64', (() => { for (let i = 0; i < 70; i++) e.longtask(i, 60); return [d.stats.longtasks.length, d.stats.longtasks[0][0]] })(), [64, 6])
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(700, 'locker')
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  has('the next idle with no move says so: the last one is not carried over', e.last()?.detail, 'no pointer move first')
}
{
  const { e } = armed()
  e.advance(10_000)
  e.input('click'); e.endTask()                      // not cold: 10 s after arming
  e.advance(1_000)
  e.move()                                           // 1 s after an input: not after an idle
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker')
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  has('a move that was not after an idle is not the first move after one', e.last()?.detail, 'no pointer move first')
}
{
  const { e } = armed()
  e.advance(60_000)
  e.input('click', 1.7e12)                           // a timeStamp on another clock
  e.call('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker')
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  check('a timeStamp not on the page clock is not used: A unknown, total from the call', [e.last()?.a, e.last()?.total], [-1, 23])
}
{
  const { e } = armed()
  e.advance(120_000)
  e.input('click', e.clock - 61_000)                 // ...nor one a minute old
  e.call('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker')
  e.frame(); e.advance(16); e.frame(); e.presentLive(e.clock)
  e.advance(5_000)
  check('...nor one more than a minute before its listener ran', e.last()?.a, -1)
}
check('fmtMs: one decimal under 10 ms, whole above, - unknown', [fmtMs(0.44), fmtMs(9.96), fmtMs(1837.4), fmtMs(-1)],
  ['0.4', '10.0', '1837', '-'])

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
  check('what is said is read', parseDiag({ cold: true, paint: { ms: 500, mode: 'comp' }, warm: 5000, ask: 3 }),
    { cold: true, paint: { ms: 500, mode: 'comp' }, warm: 5000, ask: 3 })
}
{
  const e = fakeEnv()
  const d = createDiag(e.env)
  check('creating it installs nothing', [e.on, e.tapSet, e.intervals.size], [{ listen: 0, observe: 0, longtasks: 0, presentation: 0 }, null, 0])
  d.apply(parseDiag({}))
  check('an envelope that says nothing installs nothing',
    [e.on, e.tapSet, e.intervals.size, e.rafs.length, e.laters.length, e.dots, e.sent.length, e.marked],
    [{ listen: 0, observe: 0, longtasks: 0, presentation: 0 }, null, 0, 0, 0, [], 0, []])
  e.advance(600_000)
  check('ten idle minutes later: no timer ran, no frame was asked for, nothing was sent',
    [e.flips, e.warms, e.rafs.length, e.sent.length], [0, 0, 0, 0])

  d.apply(parseDiag({ cold: true }))
  check('arming the cold line installs the listeners, the observers and the taps',
    [e.on, e.tapSet !== null], [{ listen: 1, observe: 1, longtasks: 1, presentation: 1 }, true])
  check('...and no interval and no frame request', [e.intervals.size, e.rafs.length], [0, 0])
  d.apply(parseDiag({ cold: true }))
  check('the same envelope again installs nothing twice', e.on.listen, 1)
  e.present('brcold-self', e.clock + 16)
  e.advance(60_000)
  e.click('br/locker/pick'); e.endTask()
  e.advance(5); e.pushChange(10, 'locker')
  check('a window open with its marker', e.live.size, 1)
  d.apply(parseDiag({}))
  check('disarming takes every one of them away, markers too',
    [e.off, e.tapSet, e.live.size], [{ listen: 1, observe: 1, longtasks: 1, presentation: 1 }, null, 0])
  e.advance(60_000)
  check('...and sends nothing after', e.lines().length, 0)

  d.apply(parseDiag({ paint: { ms: 500, mode: 'raster' } }))
  const [paint] = [...e.intervals.values()]
  check('bruipaint on: one interval at its period, and its dot', [e.intervals.size, paint?.ms, e.dots], [1, 500, [null, 'raster']])
  paint.fn(); paint.fn()
  check('each beat is one flip of the dot', e.flips, 2)
  d.apply(parseDiag({ paint: { ms: 250, mode: 'raf' } }))
  const [raf] = [...e.intervals.values()]
  const asked = e.rafs.length
  raf.fn()
  check('raf mode: no dot, one frame request a beat', [e.intervals.size, e.dots.at(-1), e.rafs.length - asked, e.flips], [1, null, 1, 2])
  e.rafs.length = 0
  d.apply(parseDiag({}))
  check('bruipaint off: the interval and the dot are gone', [e.intervals.size, e.dots.at(-1)], [0, null])

  d.apply(parseDiag({ cold: true, warm: 5000 }))
  e.present?.('brcold-self', e.clock + 16)
  const [warm] = [...e.intervals.values()]
  check('bruiwarm on: one interval at its period', [e.intervals.size, warm?.ms], [1, 5000])
  const before = d.tracker.lastChangeAt
  e.clock += 40_000
  warm.fn()
  check('a beat re-renders the tree once', e.warms, 1)
  warm.fn()
  check('a beat while the last has not settled does nothing', e.warms, 1)
  e.settles.splice(0).forEach((f) => f())
  check('...and the DOM change it caused is the switch\'s, not the page\'s',
    [d.tracker.lastChangeAt, d.stats.warmMutations, d.stats.warmBeats], [before, 1, 1])
  e.mutate()
  check('a real change after it is the page\'s again', d.tracker.lastChangeAt, e.clock)
  d.apply(parseDiag({}))
  check('bruiwarm off: the interval is gone', e.intervals.size, 0)

  d.apply(parseDiag({ cold: true, paint: { ms: 500, mode: 'comp' }, warm: 5000, ask: 1 }))
  const idle = e.sent.find((s) => s.what === 'idle')
  has('bruiidle answers once, with the switches it runs', idle?.payload.text, 'paint comp every 500ms: 0 beats')
  has('...and what the page holds', idle?.payload.text, 'heap 23.4/31.0MB, 2314 nodes')
  check('...and only when asked', e.sent.filter((s) => s.what === 'idle').length, 1)
  d.apply(parseDiag({}))
}

// ── the inventory ───────────────────────────────────────────────────────────
console.log('the inventory says what it cannot count, and counts per second over at least one')
{
  const page = { heapMB: null, heapTotalMB: null, nodes: 10, animations: ['spin on leave-spinner'], visible: 'visible', focused: false }
  const stats = { armedAt: 0, envelopes: new Map(), mutations: 0, longtasks: [], paintOn: 0, paintBeats: 0, paintMs: 0,
    warmOn: 0, warmBeats: 0, warmMs: 0, warmMutations: 0 }
  const text = idleInventory(DIAG_OFF, stats, null, 1000, page, { state: 'off' })
  has('the cold probe off: no counts', text, 'cold probe off (no counts)')
  has('a running animation is named', text, '1 running animations (spin on leave-spinner)')
  has('the switches off', text, 'paint off | warm off')
}
{
  const e = fakeEnv()
  const d = createDiag(e.env)
  d.apply(parseDiag({ cold: true }))
  e.push(1, 'lobby'); e.push(2, 'lobby'); e.push(3, 'lobby'); e.endTask()
  e.advance(100)
  d.apply(parseDiag({ cold: true, ask: 1 }))
  const text = e.sent.find((s) => s.what === 'idle')?.payload.text
  has('three envelopes 0.1 s after arming are 3 a second, not 30', text, 'lobby 3.0/s')
  has('...with the input idle and how long the DOM has been still', text, 'no input 0s, DOM still 0s (since armed)')
}

// ── a payload built by hand: Lua's fields ───────────────────────────────────
console.log('what Lua is handed')
{
  const w = {
    kind: 'input', opened: 1000, idleMs: 61_000, stillMs: 50_000, stillSinceArm: false, by: 'click', inputTs: 998,
    handler: 1001, cb: 'br/locker/pick', later: 2, reclicks: 2, inputs: 3, tookOver: '', frozen: null, cut: null,
    cause: 0, hover: null, wake: null, first: null, firstVia: '', reaction: null, reactionVia: '', push: null,
    pushSame: false, attributed: false, provisional: false, changes: 0, laterTask: 0, ignored: 0, envs: [],
    envCount: 0, idleFrom: 0, dropped: false,
  }
  const at = { id: 'brcold-9', at: 2804, raf1: 2820, work: 2822, raf2: 2836, presented: null, probe: true }
  const p = coldPayload({ ...w, reaction: at, first: at, push: { s: 501, k: 'locker', t: 2802 }, pushSame: true, attributed: true },
    { now: 9000, presentable: true, why: '', longtasks: [], heapMB: null })
  check('later, push and age: what idle.lua counts back by and narrows E with',
    [p.later, p.push, p.e, p.age, p.cause], [2, { s: 501, k: 'locker', t: 1801 }, 1801, 7999, 0])
}

console.log(`\n${ran - failed}/${ran} passed`)
if (failed > 0) {
  console.error(`test-cold: ${failed} failed`)
  process.exit(1)
}
