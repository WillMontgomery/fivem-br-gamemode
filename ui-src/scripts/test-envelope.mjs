#!/usr/bin/env node
/**
 * THE NUI GUARD'S TESTS (#281).
 *
 * An external audit found that the window `message` listener in bridge/nui.ts
 * dispatched anything envelope-shaped, from anywhere -- including the two
 * script-capable iframes this interface embeds. The headline case is at the
 * bottom of this file: the audit's own reproduction, posted from a child frame,
 * asserted to reach nothing and to leave the sequence number where it was.
 *
 * WHY node RUNS A .ts FILE DIRECTLY. bridge/envelope.ts has no runtime imports,
 * so node's type stripping (on by default since 22.18) loads it as-is. The
 * alternative was a DOM test runner -- jsdom, vitest -- which would have been a
 * new dependency and a new vocabulary in a repo whose every other suite is a
 * plain script that prints ok or FAIL. This file is the same shape as
 * js-src/br_ddb/scripts/test.mjs on purpose.
 *
 * WHAT THIS CANNOT REACH, and it is worth stating rather than implying: there is
 * no real DOM here, so `route()` below MODELS bridge/nui.ts's listener. That
 * model is only worth something while nui.ts still routes every inbound message
 * through admit() first -- which is why check-ui.mjs rule R14 exists. The two
 * are a pair; do not delete one and keep the other.
 *
 * Run: npm run test:envelope   (and as part of npm run build)
 */

import {
  admit,
  createSeqGate,
  isEmbeddedFrame,
  isSelfOrAncestor,
  FRAME_SCAN_MAX,
  SEQ_MAX,
  STALE_RUN_LIMIT,
} from '../src/bridge/envelope.ts'

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

/**
 * A stand-in Window.
 *
 * `length` and indexed access are the whole of the interface isEmbeddedFrame
 * uses, and they are the whole of it precisely because they are the two things
 * readable on a cross-origin frame. So a plain object is not a weakened model
 * here -- it is the same surface.
 */
function win(...children) {
  const w = { length: children.length }
  children.forEach((c, i) => { w[i] = c })
  for (const c of children) if (c && typeof c === 'object') c.parent = w
  if (w.parent === undefined) w.parent = w   // a top window is its own parent
  return w
}

/**
 * The real arrangement, from citizenfx/fivem: FiveM's own root.html holds every
 * resource page in an iframe and forwards SendNUIMessage into it with
 * `contentWindow.postMessage`. So `us` is the page, `root` is the parent, and
 * a genuine envelope arrives with `ev.source === root`.
 *
 * THIS IS THE FIXTURE THE WHOLE FILE TURNS ON. Model it as a top-level page --
 * which is what the obvious `ev.source === window` check assumes -- and every
 * test here passes over a guard that would black out the game.
 */
function nuiPage(...ourFrames) {
  const us = win(...ourFrames)
  const root = win(us)
  return { root, us }
}

// ------------------------------------------------------------ frame walk ---

console.log('\nwhere a real envelope comes from')

{
  const help = win()
  const { root, us } = nuiPage(help)

  // If this one is ever wrong the interface is black and the console is empty.
  check('the root page is an ancestor', isSelfOrAncestor(us, root), true)
  check('so a real envelope is not an embedded frame', isEmbeddedFrame(us, root), false)
  check('we are our own ancestor', isSelfOrAncestor(us, us), true)
  check('an absent source counts as ours', isSelfOrAncestor(us, null), true)
  check('our own frame is not an ancestor', isSelfOrAncestor(us, help), false)
  check('and it IS an embedded frame', isEmbeddedFrame(us, help), true)

  // A sibling resource's page. Neither ours nor above us -- the deny-list lets
  // it through, and the header says so rather than pretending otherwise.
  const sibling = win()
  sibling.parent = root
  check('a sibling resource is not an ancestor', isSelfOrAncestor(us, sibling), false)
  check('but the deny-list does not stop it', isEmbeddedFrame(us, sibling), false)

  // The starvation attack on the guard itself: hundreds of frames so the walk
  // hits its cap. A real envelope must still get in, because it never walks.
  const many = win(...Array.from({ length: FRAME_SCAN_MAX + 10 }, () => win()))
  const outerRoot = win(many)
  check('a flooded frame tree still admits the parent', isEmbeddedFrame(many, outerRoot), false)
}

console.log('\nframe walk')

{
  const child = win()
  const host = win(child)
  check('a direct child is embedded', isEmbeddedFrame(host, child), true)
  check('the host itself is not', isEmbeddedFrame(host, host), false)
  check('null source is not', isEmbeddedFrame(host, null), false)
  check('absent source is not', isEmbeddedFrame(host, undefined), false)
  check('an unrelated window is not', isEmbeddedFrame(host, win()), false)
}

{
  // THE ADMIN CONSOLE'S CASE. That frame is deliberately unsandboxed, so it can
  // build an iframe of its own and have that call top.postMessage -- whose
  // ev.source is a grandchild and would sail straight past a one-level check.
  const grandchild = win()
  const child = win(grandchild)
  const host = win(child)
  check('a grandchild is embedded', isEmbeddedFrame(host, grandchild), true)
}

{
  // A frame can hold a frame pointing back up. The walk must not follow that
  // forever -- a message listener that hangs is a frozen interface.
  const host = win()
  const child = win()
  host.length = 1
  host[0] = child
  child.parent = host
  child.length = 1
  child[0] = host
  check('a cycle terminates', isEmbeddedFrame(host, win()), false)
  check('and still finds the child', isEmbeddedFrame(host, child), true)
}

{
  // Reading a cross-origin frame is allowed but not guaranteed pleasant. A
  // throw here used to be a throw inside the message listener, which is the
  // shape that kills the whole bridge for the session.
  const angry = {
    get length() { throw new Error('cross-origin') },
  }
  const host = win(angry)
  check('a throwing frame does not throw out', isEmbeddedFrame(host, win()), false)
  check('and the angry frame is still found', isEmbeddedFrame(host, angry), true)
}

{
  // Past the scan cap the answer is "embedded", which is the fail-closed half of
  // FRAME_SCAN_MAX. Reachable only by a page that built hundreds of frames.
  const many = win(...Array.from({ length: FRAME_SCAN_MAX + 10 }, () => win()))
  check('exhausting the scan cap refuses', isEmbeddedFrame(many, win()), true)
}

// --------------------------------------------------------------- envelope ---

console.log('\nenvelope shape')

const { root: ROOT, us: HOST } = nuiPage(win())
const FRAME = HOST[0]

const good = { t: 'br', v: 1, k: 'toast', d: { text: 'hi' }, s: 4 }
const why = (v) => (v.ok ? 'ok' : v.why)

check('a real envelope from the root page is admitted', why(admit(HOST, ROOT, good)), 'ok')
check('the same envelope from this page itself', why(admit(HOST, HOST, good)), 'ok')
check('the same envelope with no source at all', why(admit(HOST, null, good)), 'ok')
check('the same envelope from the frame is not', why(admit(HOST, FRAME, good)), 'embedded-frame')

check('null data', why(admit(HOST, HOST, null)), 'not-an-envelope')
check('a string', why(admit(HOST, HOST, 'br')), 'not-an-envelope')
check('a number', why(admit(HOST, HOST, 7)), 'not-an-envelope')
check('no t', why(admit(HOST, HOST, { k: 'toast', s: 1 })), 'not-an-envelope')
check('the wrong t', why(admit(HOST, HOST, { ...good, t: 'nui' })), 'not-an-envelope')

check('no k', why(admit(HOST, HOST, { t: 'br', s: 1 })), 'bad-kind')
check('an empty k', why(admit(HOST, HOST, { ...good, k: '' })), 'bad-kind')
check('a non-string k', why(admit(HOST, HOST, { ...good, k: 3 })), 'bad-kind')

// THE FRAME TEST RUNS FIRST, before a field of the payload is read. Asserted
// because "check the sender before you read the message" is the property, not
// an implementation detail: reordering it would leave a listener that parses
// attacker-controlled data for a living.
check(
  'a frame is refused before the shape is judged',
  why(admit(HOST, FRAME, 'not even an object')),
  'embedded-frame',
)

console.log('\nsequence numbers')

check('an absent s is allowed', why(admit(HOST, HOST, { t: 'br', k: 'toast', d: {} })), 'ok')
check('s = 0', why(admit(HOST, HOST, { ...good, s: 0 })), 'ok')
check('s at the ceiling', why(admit(HOST, HOST, { ...good, s: SEQ_MAX })), 'ok')

// The audit's exact value. It is inside Number.MAX_SAFE_INTEGER and outside
// anything Lua's counter could reach, and it is the number that froze the UI.
check(
  'MAX_SAFE_INTEGER is refused',
  why(admit(HOST, HOST, { ...good, s: Number.MAX_SAFE_INTEGER })),
  'bad-seq',
)
check('past the ceiling', why(admit(HOST, HOST, { ...good, s: SEQ_MAX + 1 })), 'bad-seq')
check('negative', why(admit(HOST, HOST, { ...good, s: -1 })), 'bad-seq')
check('fractional', why(admit(HOST, HOST, { ...good, s: 1.5 })), 'bad-seq')
check('NaN', why(admit(HOST, HOST, { ...good, s: NaN })), 'bad-seq')
check('Infinity', why(admit(HOST, HOST, { ...good, s: Infinity })), 'bad-seq')
check('a numeric string', why(admit(HOST, HOST, { ...good, s: '5' })), 'bad-seq')

// ------------------------------------------------------------- seq gate ---

console.log('\nthe sequence gate')

{
  const g = createSeqGate()
  check('starts behind everything', g.last, -1)
  check('the first envelope is fresh', g.fresh(1), true)
  g.commit(1)
  check('and is recorded', g.last, 1)
  check('the same one again is stale', g.fresh(1), false)
  check('an older one is stale', g.fresh(0), false)
  check('a newer one is fresh', g.fresh(2), true)
}

{
  // A kind nobody is listening to must not consume the sequence. This is the
  // rule bridge/nui.ts already carried in a comment -- the mount gap between the
  // listener attaching and React subscribing -- and commit() is where it lives
  // now, so it gets an assertion rather than a paragraph.
  const g = createSeqGate()
  g.fresh(5)
  check('freshness alone advances nothing', g.last, -1)
  g.commit(5)
  check('delivery advances it', g.last, 5)
}

{
  const g = createSeqGate()
  g.fresh(3)
  g.commit(3)
  g.reseed(0)
  check('a snapshot re-seeds', g.last, 0)
  check('and what followed it is fresh again', g.fresh(1), true)
  g.reseed(undefined)
  check('a snapshot with no s re-seeds to zero', g.last, 0)
}

{
  // THE DENIAL OF SERVICE, AND THE RECOVERY FROM IT.
  //
  // Before #281 this loop never ended: one envelope with a sequence beyond
  // anything Lua counts to, and every genuine envelope after it was stale
  // forever. admit() now refuses MAX_SAFE_INTEGER outright, but a forged number
  // just under the ceiling passes -- so the range check is not the fix, this is.
  const g = createSeqGate()
  g.fresh(SEQ_MAX - 1)
  g.commit(SEQ_MAX - 1)

  const dropped = []
  for (let i = 1; i <= STALE_RUN_LIMIT; i++) dropped.push(g.fresh(i))

  check(
    'a poisoned sequence drops exactly STALE_RUN_LIMIT - 1 envelopes',
    dropped,
    [...Array(STALE_RUN_LIMIT - 1).fill(false), true],
  )
  check('and then the gate lets go of the bad number', g.last, -1)

  g.commit(STALE_RUN_LIMIT)
  check('the session carries on from the real counter', g.last, STALE_RUN_LIMIT)
  check('and normal freshness is back', g.fresh(STALE_RUN_LIMIT), false)
  check('with the run cleared', g.staleRun, 1)
}

{
  // The run counts CONSECUTIVE refusals. One stale envelope in the middle of a
  // healthy session must not bring the session eight envelopes closer to a
  // re-seed it does not need.
  const g = createSeqGate()
  g.fresh(10)
  g.commit(10)
  for (let i = 0; i < STALE_RUN_LIMIT - 1; i++) g.fresh(1)
  check('a run builds', g.staleRun, STALE_RUN_LIMIT - 1)
  g.fresh(11)
  check('and one good envelope clears it', g.staleRun, 0)
}

// -------------------------------------------------------- the audit's case ---

console.log('\nthe reproduction from the issue')

/**
 * bridge/nui.ts's listener and dispatcher, in the order they run.
 *
 * Pinned by check-ui.mjs R14. If that rule ever fails, this model has drifted
 * from the code it is standing in for and this whole section is worthless until
 * they agree again.
 */
function route(host, source, data, gate, handlers) {
  const verdict = admit(host, source, data)
  if (!verdict.ok) return verdict.why

  const msg = verdict.env
  if (msg.k === 'snapshot') gate.reseed(msg.s)
  else if (!gate.fresh(msg.s)) return 'stale'

  const fns = handlers.get(msg.k)
  if (!fns || fns.length === 0) return 'unheard'

  if (msg.k !== 'snapshot') gate.commit(msg.s)
  for (const fn of fns) fn(msg.d)
  return 'delivered'
}

{
  const gate = createSeqGate()
  const heard = []
  const handlers = new Map([
    ['toast', [(d) => heard.push(['toast', d])]],
    ['state', [(d) => heard.push(['state', d])]],
  ])

  // A live session, a few envelopes in.
  route(HOST, ROOT, { t: 'br', v: 1, k: 'state', d: { phase: 'playing' }, s: 41 }, gate, handlers)
  check('the real bridge works', heard.length, 1)
  check('and the sequence stands at 41', gate.last, 41)

  // Step 2 of the issue's reproduction, verbatim, from the embedded page.
  const forged = {
    t: 'br',
    v: 1,
    k: 'toast',
    d: { text: 'forged', tone: 'warn' },
    s: Number.MAX_SAFE_INTEGER,
  }
  const outcome = route(HOST, FRAME, forged, gate, handlers)

  check('the forged envelope is refused', outcome, 'embedded-frame')
  check('no handler ran', heard.length, 1)
  check('lastSeq is unchanged', gate.last, 41)
  check('and no stale run was started', gate.staleRun, 0)

  // Step 4: the envelope that would have been eaten.
  route(HOST, ROOT, { t: 'br', v: 1, k: 'toast', d: { text: 'real' }, s: 42 }, gate, handlers)
  check('the next real envelope still lands', heard.length, 2)
  check('carrying its own payload', heard[1][1], { text: 'real' })
  check('and the sequence moves on', gate.last, 42)

  // The same forgery with a sequence number the range check cannot see through,
  // arriving from the root page rather than one of our frames -- the case that
  // would exist if the frame walk were ever wrong, or if a SIBLING resource's
  // page reached us. The session recovers by itself, which is the point: the
  // sequence half of this fix does not depend on knowing the sender at all.
  const sneaky = { ...forged, s: SEQ_MAX - 1 }
  check('a plausible forgery from the root page is admitted', route(HOST, ROOT, sneaky, gate, handlers), 'delivered')
  for (let i = 43; i < 43 + STALE_RUN_LIMIT - 1; i++) {
    route(HOST, ROOT, { t: 'br', v: 1, k: 'toast', d: { text: 'real' }, s: i }, gate, handlers)
  }
  check('it costs a handful of envelopes', heard.length, 3)
  route(HOST, ROOT, { t: 'br', v: 1, k: 'toast', d: { text: 'back' }, s: 99 }, gate, handlers)
  check('and then the interface comes back', heard.length, 4)
  check('with the payload it was sent', heard[3][1], { text: 'back' })
}

if (failed) {
  console.error(`\nnui guard: ${failed} of ${ran} case(s) failed`)
  process.exit(1)
}
console.log(`\nnui guard: ${ran} cases pass`)
