#!/usr/bin/env node
/**
 * THE WARMUP CARD, THE TALKING LINE AND THE SPECTATE HINT: WHEN THE HUD DRAWS
 * THEM, AND WITH WHAT (#431).
 *
 * Each of the three used to read the store and return null on its own
 * condition. The HUD decides now and hands each one what it draws, so that UI
 * v2's HUD can hold an element's last frame through its way out. Nothing else
 * in the build holds that decision: check-layout measures borders and lines,
 * not what should be on screen; test-tutorial-game reads the walkthrough's
 * data; the Lua checks read strings. A condition dropped or loosened, a
 * deadline or a name not passed, a box added between the mark and the line:
 * each passed every one of them. So the real HUD is rendered here, over the
 * real store moved by its own setters (the ones App.tsx's handlers call, and
 * the walkthrough's step), and what it draws is read back:
 *
 *   THE WARMUP CARD    in warmup and in no other state, counting down to the
 *                      match's deadline on the server's clock. Hidden on every
 *                      card of the in-match walkthrough but game-timer, the one
 *                      that rings it (owner, 2026-09-07: "don't display the
 *                      timer card until they get to the last step").
 *   THE TALKING LINE   while a name is heard, with every name; nothing while
 *                      nobody is, ids without names included. The mark and the
 *                      line are their row's own two flex items: no element
 *                      between them, so the row's gap still spaces them.
 *   THE SPECTATE HINT  while a session runs, an admin's too, naming its
 *                      target, and for a truthy `active` that is not true (the
 *                      hint's old test, `!spectate?.active`); nothing before
 *                      one or once it ends, and nothing for a falsy `active`
 *                      that is not false (`0 && <X />` would draw the 0).
 *
 * NOTHING IS NOTHING AT ALL. Where a push must draw nothing, the whole tree is
 * compared with the one drawn before it, so an empty box or a stray character
 * fails as surely as the element would.
 *
 * BOTH HUDS, ONE COPY OF THE CONDITIONS. The three are decided once, in
 * hud/useHudConditions.ts, which both HUDs call, and every check runs twice:
 * on today's HUD, drawn as the page draws it with every UI v2 piece off, and
 * on UI v2's (#431, #436), drawn with the store's `uiv2` holding the hud
 * piece. Each is picked the way App.tsx picks it, by one ternary on the piece.
 * A HUD that keeps a copy of a condition again, and lets it drift, fails here
 * on that HUD's half. Today's half is today's checks, as they were.
 *
 * UI v2's anchors hold what they last drew through their way out and come in
 * on the Broadcast wipe, so its half reads the HUD once every presence has
 * settled: after each push the presences' clock (performance.now, which their
 * phases end on: ui/fade.ts monotonicNow) is moved past every way in and out,
 * and the timers due are run. Date.now, the countdown's clock, never moves.
 *
 * HOW. esbuild bundles the HUDs with the store and the walkthrough's steps,
 * and scripts/lockerv2-render.mjs's renderer plays React: it runs the effects,
 * so the countdown writes its first digits. The clock is held still --
 * Date.now fixed, and no timer fires unless the test runs it (audio/music.ts
 * arms one at load) -- so a number read here is the one the deadline gives.
 * No DOM, no browser.
 *
 * Run: npm run test:hudconditions   (and as part of npm run build)
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { blankComments } from './cef-rules.mjs'
import { fakePage, hasClass, mount, textOf } from './lockerv2-render.mjs'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

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

// ── the page ────────────────────────────────────────────────────────────────

const out = await build({
  stdin: {
    contents: [
      "export * as React from 'react'",
      "export { default as Hud } from './src/hud/Hud.tsx'",
      "export { HudLayer } from './src/hud/v2/HudLayer.tsx'",
      "export { useUIv2 } from './src/ui/useUIv2'",
      "export { useUi } from './src/store'",
      "export { GAME_STEPS } from './src/tutorial/gameSteps'",
    ].join('\n'),
    resolveDir: ROOT,
    loader: 'ts',
    sourcefile: 'test-hud-conditions-entry.ts',
  },
  bundle: true,
  write: false,
  format: 'esm',
  platform: 'neutral',
  mainFields: ['module', 'main'],
  jsx: 'automatic',
  loader: { '.css': 'empty' },
  define: { 'process.env.NODE_ENV': '"production"', 'import.meta.env.DEV': 'false' },
  logLevel: 'silent',
})

// The clock, held still once esbuild is done with it: one instant for every
// Date.now, and timers that are armed and run only when a half says so.
const NOW = 1_800_000_000_000
let page = fakePage()
Date.now = () => NOW
/** The page's timers, the fake page's queue: bare and on `window` alike. */
const timers = () => {
  globalThis.setTimeout = globalThis.window.setTimeout
  globalThis.clearTimeout = globalThis.window.clearTimeout
}
timers()
globalThis.setInterval = () => 0
globalThis.clearInterval = () => {}
// THE PRESENCES' CLOCK, moved by UI v2's half alone (settle below).
let perf = 0
performance.now = () => perf
// WHAT UI V2'S PRESENCES ASK OF AN ELEMENT (ui/broadcast/motion/usePresence.ts
// and motion/label.ts), for the renderer's stand-ins: one that never runs a
// transition, so each phase ends on the clock, and sits inside nothing.
Object.assign(globalThis.Node.prototype, {
  parentElement: null,
  closest() { return null },
  addEventListener() {},
  removeEventListener() {},
  getAnimations() { return [] },
})

const { React, Hud, HudLayer, useUIv2, useUi, GAME_STEPS } = await import(
  `data:text/javascript;base64,${Buffer.from(out.outputFiles[0].text).toString('base64')}`)
const store = () => useUi.getState()
/** The store as the page loads it, for each half to start from. */
const FRESH = useUi.getState()

/** App.tsx's HUD place: one ternary on the hud piece (App.tsx `hud2On`). */
function Place() {
  return useUIv2('hud')
    ? React.createElement(HudLayer, { up: true })
    : React.createElement(Hud, { visible: true })
}

/** A `state` envelope's payload, as the server sends one. */
const match = (state, over = {}) => ({
  state, mode: 'squad', endsAt: NOW + 45_000, serverNow: NOW, participant: true, ...over,
})

// ── reading what is drawn ───────────────────────────────────────────────────

/** The tree as drawn: every element with its props, and every string, in order. */
const shape = (list) => list.map((n) => (typeof n === 'string' ? n : {
  type: n.type,
  props: Object.fromEntries(Object.entries(n.props)
    .filter(([k, x]) => k !== 'children' && k !== 'ref' && typeof x !== 'function')),
  children: shape(n.children),
}))
const named = (n) => (n === undefined ? 'nothing' : typeof n === 'string' ? JSON.stringify(n)
  : `<${n.type}${n.props.className ? ` class="${String(n.props.className).split(/\s+/)[0]}"` : ''}>`)
/** Where the tree drawn now first parts from `was`, or null where it does not. */
function parted(now, was, at = 'the HUD') {
  for (let i = 0; i < Math.max(now.length, was.length); i++) {
    const a = now[i]
    const b = was[i]
    if (JSON.stringify(a) === JSON.stringify(b)) continue
    const same = typeof a === 'object' && typeof b === 'object' && a.type === b.type
      && JSON.stringify(a.props) === JSON.stringify(b.props)
    return same ? parted(a.children, b.children, `${at} > ${named(a)}`) : `${at}: ${named(a)} where ${named(b)} was`
  }
  return null
}

/**
 * ONE HALF: the page fresh, the hud piece as `v2` says, the HUD App.tsx would
 * draw for it mounted, and every check run against what it draws.
 */
function half(v2) {
  const which = v2 ? "UI v2's HUD (the hud piece on)" : "today's HUD (every UI v2 piece off)"
  useUi.setState(FRESH, true)
  page = fakePage()
  timers()
  store().setUIv2(v2 ? { hud: true } : null)
  const view = mount(React, React.createElement(Place))
  /** UI v2's presences, settled: their clock past every way in and out, and
   *  every timer that is due run, a few rounds for what each one arms. */
  const settle = () => {
    for (let i = 0; i < 4; i++) {
      perf += 5_000
      page.frames()
      view.render()
    }
  }
  const act = (fn) => {
    view.act(fn)
    if (v2) settle()
  }
  if (v2) settle()

  /** Host elements `pred` picks, each with its ancestors. */
  const all = (pred) => view.all(pred)
  const drawn = () => shape(view.tree)
  /** The warmup card: the element the walkthrough's last card rings. */
  const card = () => all((n) => n.props['data-tut'] === 'hud-timer')
  /** Its numeral as the player reads it: what the countdown wrote, or HotTime's `--`. */
  const digits = () => {
    const [c] = card()
    if (!c) return null
    const [numeral] = all((n) => n.el !== undefined && textOf(n) === '--').filter((x) => x.parents.includes(c.node))
    return numeral ? (numeral.node.el.textContent ?? '--') : null
  }
  /** A line of text in its own box (ui/Fit.tsx), by how it starts. */
  const line = (start) => all((n) => hasClass(n, 'fit') && textOf(n).startsWith(start))
  const texts = (start) => line(start).map((x) => textOf(x.node))

  // ── which HUD this is ───────────────────────────────────────────────────

  console.log(which)
  {
    // A half that drew the other HUD would pass on that one's code: each says
    // which root it drew. One HUD root ever (check-ui R26d), today's bare and
    // UI v2's inside its layer.
    const roots = all((n) => n.props['data-layer'] === 'hud')
    check(v2 ? "one HUD root, UI v2's, inside its layer (.hud-v2)" : "one HUD root, today's, with no UI v2 layer anywhere",
      [roots.length, roots.length === 1 && roots[0].parents.some((p) => hasClass(p, 'hud-v2')),
        all((n) => hasClass(n, 'hud-v2')).length > 0],
      [1, v2, v2])
  }

  // ── the warmup card ───────────────────────────────────────────────────────

  console.log(`${which}: the warmup card`)
  {
    const types = blankComments(readFileSync(join(ROOT, 'src/bridge/types.ts'), 'utf8'))
    const decl = /export type MatchState\s*=\s*([^\n]*(?:\n\s*\|[^\n]*)*)/.exec(types)
    const STATES = decl === null ? [] : [...decl[1].matchAll(/'([a-z]+)'/g)].map((m) => m[1])
    check('bridge/types.ts declares MatchState, warmup and others in it',
      STATES.includes('warmup') && STATES.length > 1, true)
    for (const state of STATES) {
      act(() => store().setMatch(match(state)))
      check(`${state}: ${state === 'warmup' ? 'the card is up' : 'no card'}`, card().length, state === 'warmup' ? 1 : 0)
    }

    // The server's clock 20 s ahead of this machine's: its deadline is 45 s
    // off by this machine's clock and 25 s off by the server's.
    act(() => store().setMatch(match('warmup', { endsAt: NOW + 45_000, serverNow: NOW + 20_000 })))
    check("it counts the match's deadline on the server's clock: 25", digits(), '25')
    act(() => store().setMatch(match('warmup', { endsAt: NOW + 30_000, serverNow: NOW + 20_000 })))
    check('a deadline brought forward (a full lobby) is counted at once: 10', digits(), '10')
  }

  console.log(`${which}: the walkthrough's rule`)
  {
    const timer = GAME_STEPS.find((s) => s.id === 'game-timer')
    check('game-timer is the in-match walkthrough\'s last card, and it rings hud-timer',
      [GAME_STEPS.at(-1)?.id, timer?.target], ['game-timer', 'hud-timer'])

    act(() => store().setMatch(match('warmup')))
    act(() => { store().setTutorialGameRun(true); store().setTutorialGameStep(null) })
    check('the walkthrough running, no card up yet: no warmup card', card().length, 0)
    for (const step of GAME_STEPS) {
      act(() => store().setTutorialGameStep(step.id))
      const up = step.id === 'game-timer'
      check(`on ${step.id}: ${up ? 'the warmup card is up' : 'no warmup card'}`, card().length, up ? 1 : 0)
    }
    act(() => store().setMatch(match('playing')))
    check('on game-timer outside warmup: no warmup card', card().length, 0)

    act(() => {
      store().setMatch(match('warmup'))
      store().setTutorialGameStep(GAME_STEPS[0].id)
      store().setTutorialGameRun(false)
    })
    check('no walkthrough running, a step left in the store: the card is up', card().length, 1)
  }

  // ── the talking line ──────────────────────────────────────────────────────

  console.log(`${which}: the talking line`)
  {
    act(() => store().setMatch(match('playing')))
    const quiet = drawn()
    check('nobody speaking: no line', line('Currently Talking').length, 0)

    act(() => store().setVoice({ talking: [2], names: [] }))
    check('an id with no name: nothing drawn, not even an empty box', parted(drawn(), quiet), null)

    act(() => store().setVoice({ talking: [2], names: ['Kestrel'] }))
    check('one name heard: the line, with it', texts('Currently Talking'), ['Currently Talking: Kestrel'])

    const names = ['Nyx', 'Kestrel', 'Vandal', 'Halcyon', 'Rook', 'Marrow', 'Quillon_the_Longest_Name']
    act(() => store().setVoice({ talking: [4, 2, 3, 9, 11, 12, 13], names }))
    check('seven: every one of them, in the order heard', texts('Currently Talking'), [`Currently Talking: ${names.join(', ')}`])

    // TalkingBar's box is the one on the safe zone's bottom edge round the line.
    const [hit] = line('Currently Talking')
    const at = hit ? hit.parents.findLastIndex((p) => p.props.style?.bottom === 'var(--safe-b)') : -1
    const box = at < 0 ? null : hit.parents[at]
    check("the line's box stands on the safe zone's bottom edge, straight in .hud-safe",
      at > 0 && hasClass(hit.parents[at - 1], 'hud-safe'), true)
    const items = (row) => row && row.children.map((c) => (c === hit.node ? 'line' : typeof c === 'string' ? `text ${JSON.stringify(c)}`
      : c.props['aria-hidden'] ? 'mark' : `<${c.type}>`))
    if (v2) {
      // UI v2's anchor sits inside the box and holds the row through its way
      // out, so the row is a flex box of its own, inside the anchor.
      const row = hit ? hit.parents.at(-1) : null
      check("the mark and the line are their row's own two flex items, the row inside the box's anchor",
        [items(row), Boolean(row) && hasClass(row, 'flex') && hasClass(row, 'gap-2'),
          Boolean(row) && hit.parents.slice(at + 1).some((p) => hasClass(p, 'hud-anchor'))],
        [['mark', 'line'], true, true])
    } else {
      check("the mark and the line are the box's own two flex items", items(box), ['mark', 'line'])
    }

    act(() => store().setVoice({ talking: [], names: [] }))
    check('quiet again: what was drawn before anyone spoke', parted(drawn(), quiet), null)
  }

  // ── the spectate hint ─────────────────────────────────────────────────────

  console.log(`${which}: the spectate hint`)
  {
    act(() => store().setMatch(match('playing', { participant: false })))
    check('no session ever: no hint', line('SPECTATING').length, 0)
    const none = drawn()

    act(() => store().setSpectate({ active: true, admin: false, name: 'Quillon_the_Longest_Name' }))
    check('a session: the hint, naming its target', texts('SPECTATING'), ['SPECTATING QUILLON_THE_LONGEST_NAME'])
    act(() => store().setSpectate({ active: true, admin: true, name: 'Rook' }))
    check("an admin's session: the same hint", texts('SPECTATING'), ['SPECTATING ROOK'])
    act(() => store().setSpectate({ active: 1, admin: false, name: 'Kestrel' }))
    check('`active` 1, truthy but not true: a session, as the old test read it', texts('SPECTATING'), ['SPECTATING KESTREL'])
    act(() => store().setSpectate({ active: true, admin: false }))
    check('a session with no name: the word alone', texts('SPECTATING'), ['SPECTATING '])

    if (v2) {
      // WHY THE HUD DECIDES (#431): the hint's anchor holds the last frame it
      // drew while it leaves, and lets go of it once it has left.
      view.act(() => store().setSpectate({ active: true, admin: false, name: 'Rook' }))
      settle()
      view.act(() => store().setSpectate({ active: false, admin: false }))
      check('the session over: its way out holds the last frame drawn, naming its target', texts('SPECTATING'), ['SPECTATING ROOK'])
      settle()
    } else {
      act(() => store().setSpectate({ active: false, admin: false }))
    }
    check('the session over: nothing drawn', parted(drawn(), none), null)
    act(() => store().setSpectate({ active: false, admin: false, name: 'Ghost' }))
    check('a name with no session: nothing drawn', parted(drawn(), none), null)
    for (const [label, active] of [['0', 0], ['NaN', NaN]]) {
      act(() => store().setSpectate({ active, admin: false, name: 'Ghost' }))
      check(`\`active\` ${label}: nothing drawn, not the value`, parted(drawn(), none), null)
    }
  }
}

half(false)
half(true)

console.log(`\n${ran - failed}/${ran} passed`)
process.exit(failed ? 1 : 0)
