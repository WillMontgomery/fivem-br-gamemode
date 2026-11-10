#!/usr/bin/env node
/**
 * TODAY'S TAB INVENTORY: EVERY PRESS ENDS, AND A RELEASE IS ITS OWN PRESS'S
 * (#440).
 *
 * src/screens/InventoryPanel.tsx moves an item by press and release: a press
 * on a card holds what is in it (the card dims), a release on the card it went
 * down on is a click, today's select (INV_SELECT {slot}), and a release on
 * another card swaps the two (INV_SWAP {from, to}). The press used to end only
 * on a card's own release, so:
 *
 *   HELD FOR GOOD   an item pressed and let go anywhere that is not a card --
 *                   beside the panel, on its header, in the gap between two
 *                   cards, on the ammo strip, on a card's buttons -- stayed
 *                   held, its card dimmed, and the next click on an empty slot
 *                   moved it there;
 *   NOT ITS PRESS   a release over a card selected that card whatever its
 *                   press had been: one that went down beside the panel, on
 *                   its header, on an empty card, on a button, or before the
 *                   panel opened.
 *
 * So this presses the real panel each of those ways, and pins:
 *
 *   EVERY PRESS ENDS on its release wherever it lands, on a cancel, and on the
 *   window losing focus, and nothing is held after it: no card dimmed, and
 *   nothing a later release can move or select.
 *   EVERY PRESS STARTS FROM NOTHING, a release the page never heard (let go
 *   outside the window) included: a press on an empty card, on a button or off
 *   the cards holds nothing.
 *   A SELECT only where the release is on the card its press went down on,
 *   whatever gesture came before it.
 *   A SWAP only from a card that held an item, let go on another card.
 *   A PICTURE IS ITS CARD'S: the panel refuses Chromium's native drag of an
 *   item's picture, which would take the pointer and, in FiveM, the release,
 *   so an item grabbed by its picture swaps and selects as any press does.
 *   TODAY'S BUTTONS are their own: Use, Drop, the arrows and a pool's Drop
 *   send what they always sent, and a press on one is never its card's.
 *   THE WINDOW hears every press, release and cancel in its capture phase, so
 *   a button that stops one cannot hide it, and only its own blur; closing the
 *   panel takes every listener it gave.
 *
 * HOW. As scripts/test-inventory-fx.mjs presses UI v2's page: esbuild bundles
 * the panel with the store, fetchNui records what it is asked, and
 * scripts/lockerv2-render.mjs's renderer plays React (no DOM, no browser). A
 * pointer event goes where a browser sends it: to the window's capture-phase
 * listeners, then to React's handlers on the element under the pointer and on
 * each one above it, nearest first, until one stops it, then to the window's
 * other listeners if none did. The panel takes no pointer capture, so a
 * release lands on whatever is under it. A browser runs microtasks between two
 * listeners, where React may render, so the panel is rendered there too: no
 * handler may read the press off a render.
 *
 * Run: npm run test:inventorydrag   (and as part of npm run build)
 */

import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
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

// ── the panel ───────────────────────────────────────────────────────────────

globalThis.__drag = { calls: [], open: true }
const STUBS = {
  nui: `
    const S = globalThis.__drag
    export function fetchNui(cb, data) { S.calls.push([cb, data ?? null]); return Promise.resolve({}) }
    export function onEnvelope() { return () => {} }
    export function subscribe() { return () => {} }
    export function reportError() {}
    export function dispatch() {}
    export const isBrowser = true`,
  cues: `
    export function play() {}
    export function setUiVolume() {}
    export function soundReport() { return {} }
    export const CUE_NAMES = []`,
}
const out = await build({
  stdin: {
    contents: [
      "export * as React from 'react'",
      "export { default as InventoryPanel } from './src/screens/InventoryPanel.tsx'",
      "export { CB } from './src/bridge/types'",
      "export { useUi } from './src/store'",
    ].join('\n'),
    resolveDir: ROOT,
    loader: 'ts',
    sourcefile: 'test-inventory-drag-entry.ts',
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
  plugins: [{
    name: 'inventory-drag-stand-ins',
    setup(b) {
      b.onResolve({ filter: /(^|\/)bridge\/nui$/ }, () => ({ path: 'nui', namespace: 'stub' }))
      b.onResolve({ filter: /(^|\/)audio\/cues$/ }, () => ({ path: 'cues', namespace: 'stub' }))
      b.onLoad({ filter: /.*/, namespace: 'stub' }, (a) => ({ contents: STUBS[a.path], loader: 'js', resolveDir: ROOT }))
    },
  }],
})

// Timers that run only when asked (the panel asks for none), as the other
// renderer tests keep them.
fakePage()
const timers = () => {
  globalThis.setTimeout = globalThis.window.setTimeout
  globalThis.clearTimeout = globalThis.window.clearTimeout
}
timers()
globalThis.setInterval = () => 0
globalThis.clearInterval = () => {}

const { React, InventoryPanel, CB, useUi } = await import(
  `data:text/javascript;base64,${Buffer.from(out.outputFiles[0].text).toString('base64')}`)
const store = () => useUi.getState()
const FRESH = useUi.getState()
const NAME = Object.fromEntries(Object.entries(CB).map(([k, v]) => [v, k]))

/** App.tsx's line for the panel: drawn while the inventory has the focus and
 *  the HUD is up (`__drag.open`, which a scenario turns off to close it). */
function Place() {
  return globalThis.__drag.open ? React.createElement(InventoryPanel) : null
}

// ── the bag ─────────────────────────────────────────────────────────────────

const RIFLE = { id: 'carbinerifle', label: 'Carbine Rifle', kind: 'weapon', rarity: 3, count: 1, clip: 30, pool: 'medium' }
const MEDKIT = { id: 'medkit', label: 'Med Kit', kind: 'consumable', rarity: 2, count: 2 }
const PISTOL = { id: 'pistol', label: 'Pistol', kind: 'weapon', rarity: 1, count: 1, clip: 12, pool: 'light' }
const AMMO = { light: 24, smg: 0, medium: 60, shells: 0, heavy: 0 }
/** The rifle in slot 1 (in hand), the med kit in 3, the pistol in 5; 2 and 4 empty. */
const START = { slots: [RIFLE, null, MEDKIT, null, PISTOL], ammo: AMMO, reserve: null, active: 1, using: null }

// ── where a pointer can be ──────────────────────────────────────────────────
// Each is read off the tree as it is drawn when the event comes, and gives the
// element under the pointer with its ancestors; null is off the panel, where
// nothing of React's is on the event's way.

/** Card i (1-5): the element its handlers are on. */
const card = (i) => (v) => v.all((n) => hasClass(n, 'plate') && hasClass(n, 'cursor-pointer'))[i - 1] ?? null
/** Inside card i, under something drawn there that is not a button: its number. */
const numberOn = (i) => (v) => {
  const c = card(i)(v)
  return c && (v.all((n) => n.type === 'span' && textOf(n) === String(i)).find((x) => x.parents.includes(c.node)) ?? null)
}
/** Inside card i, its item's picture (ItemIcon's <img>). */
const pictureOn = (i) => (v) => {
  const c = card(i)(v)
  return c && (v.all((n) => n.type === 'img').find((x) => x.parents.includes(c.node)) ?? null)
}
/** A button on card i, by its words. */
const buttonOn = (i, words) => (v) => {
  const c = card(i)(v)
  return c && (v.all((n) => n.type === 'button' && textOf(n) === words).find((x) => x.parents.includes(c.node)) ?? null)
}
/** The panel's header, the gap between the cards (their grid) and the ammo strip. */
const header = (v) => v.all((n) => n.type === 'h2')[0] ?? null
const gap = (v) => v.all((n) => hasClass(n, 'grid') && hasClass(n, 'grid-cols-5'))[0] ?? null
const strip = (v) => v.all((n) => hasClass(n, 'border-t'))[0] ?? null
/** Pool k's Drop, on the ammo strip (0 light, 1 smg, ...). */
const poolDrop = (k) => (v) => {
  const s = strip(v)
  return s && (v.all((n) => n.type === 'button' && textOf(n) === 'Drop').filter((x) => x.parents.includes(s.node))[k] ?? null)
}
const BESIDE = () => null

/**
 * ONE SCENARIO: the page fresh, the bag in the store, the panel drawn as App
 * draws it, and a pointer to press it with.
 */
function scenario(inv = START) {
  useUi.setState(FRESH, true)
  fakePage()
  timers()
  // THE WINDOW'S LISTENERS, kept as a browser keeps them (fakePage's window
  // ignores the phase): one per type, function and phase, and a removal takes
  // only the one that matches all three.
  const win = []
  const capturing = (o) => (typeof o === 'boolean' ? o : !!o?.capture)
  Object.assign(globalThis.window, {
    addEventListener(kind, fn, o) {
      const capture = capturing(o)
      if (!win.some((l) => l.kind === kind && l.fn === fn && l.capture === capture)) win.push({ kind, fn, capture })
    },
    removeEventListener(kind, fn, o) {
      const capture = capturing(o)
      const i = win.findIndex((l) => l.kind === kind && l.fn === fn && l.capture === capture)
      if (i >= 0) win.splice(i, 1)
    },
  })
  globalThis.__drag.calls = []
  globalThis.__drag.open = true
  store().setInv(inv)
  const view = mount(React, React.createElement(Place))

  const HANDLER = {
    pointerdown: 'onPointerDown', pointerup: 'onPointerUp', pointercancel: 'onPointerCancel', click: 'onClick',
    dragstart: 'onDragStart',
  }
  /**
   * A pointer event of `type` at `where` (one of the places above), as a
   * browser sends it: the window's capture-phase listeners, a render, React's
   * handlers from the element under the pointer up, nearest first, until one
   * stops it, a render, and the window's other listeners unless it was stopped.
   * Gives whether a handler prevented its default (a dragstart's, refused).
   */
  const fire = (type, where) => {
    let stopped = false
    let prevented = false
    const e = {
      type, pointerId: 1, button: 0, buttons: type === 'pointerdown' ? 1 : 0,
      preventDefault() { prevented = true }, stopPropagation() { stopped = true },
    }
    const windowHears = (capture) => view.act(() => {
      for (const l of win.filter((x) => x.kind === type && x.capture === capture)) l.fn(e)
    })
    windowHears(true)
    const hit = where(view)
    if (hit) {
      view.act(() => {
        for (const n of [hit.node, ...[...hit.parents].reverse()]) {
          if (stopped) break
          const h = n.props[HANDLER[type]]
          if (typeof h === 'function') h({ ...e, nativeEvent: e, target: hit.node, currentTarget: n })
        }
      })
    }
    if (!stopped) windowHears(false)
    return prevented
  }
  const p = {
    down: (where) => fire('pointerdown', where),
    up: (where) => fire('pointerup', where),
    /** A cancel (the browser taking the pointer). No release follows it. */
    cancel: (where = BESIDE) => fire('pointercancel', where),
    /** Chromium's offer of a native drag at `where` (a dragstart): whether the
     *  page refused it. */
    dragstart: (where) => fire('dragstart', where),
    /**
     * A press at `from` that moves past Chromium's drag threshold before its
     * release at `to`. Over a picture, Chromium offers a native drag first. If
     * the page refuses it the press goes on, and the release comes as any
     * other. If not, the drag takes the pointer (a pointercancel) and its own
     * loop takes the release: in FiveM that loop is DoDragDrop, and while it
     * runs FiveM hands the button's release to it, never to the page
     * (citizenfx/fivem master, nui-core's CefDragDropHandler.cpp and
     * CefOleHandler.cpp). So no release reaches the page.
     */
    moved: (from, to) => {
      fire('pointerdown', from)
      if (from(view)?.node.type === 'img' && !fire('dragstart', from)) {
        fire('pointercancel', from)
        return
      }
      fire('pointerup', to)
    },
    /** The window losing focus (alt-tab): its own blur, heard in either phase. */
    blur: () => view.act(() => { for (const l of win.filter((x) => x.kind === 'blur')) l.fn({ type: 'blur' }) }),
    /** A press and its release, both at `where`. */
    click: (where) => { fire('pointerdown', where); fire('pointerup', where) },
    /** A press at `from` and its release at `to` (the panel follows no move, so none is sent). */
    drag: (from, to) => { fire('pointerdown', from); fire('pointerup', to) },
  }
  return {
    p,
    /** A button pressed and let go where it is drawn, then its click: what the
     *  press dimmed, what was sent, and what is dimmed after. */
    tap: (where) => {
      globalThis.__drag.calls = []
      fire('pointerdown', where)
      const during = dimmed()
      fire('pointerup', where)
      fire('click', where)
      return [during, sent(), dimmed()]
    },
    sent: () => sent(),
    clear: () => { globalThis.__drag.calls = [] },
    /** The cards drawn dimmed: the item held. */
    dimmed: () => dimmed(),
    cards: () => view.all((n) => hasClass(n, 'plate') && hasClass(n, 'cursor-pointer')).length,
    /** What the window listens to for a press, and in which phase. */
    listening: () => Object.fromEntries(['pointerdown', 'pointerup', 'pointercancel', 'blur']
      .map((k) => [k, win.filter((l) => l.kind === k).map((l) => (l.capture ? 'capture' : 'target or bubble'))])),
    /** App's line turned off: TAB, Esc or a right-click closes the panel. */
    close: () => view.act(() => { globalThis.__drag.open = false }),
  }

  function dimmed() {
    return view.all((n) => hasClass(n, 'plate') && hasClass(n, 'cursor-pointer'))
      .map((c, k) => (c.node.props.style?.opacity === 0.45 ? k + 1 : 0)).filter(Boolean)
  }
  function sent() {
    return globalThis.__drag.calls.map(([cb, data]) => [NAME[cb] ?? cb, data])
  }
}

const NONE = []

console.log("1. today's gestures, as they were")
{
  const s = scenario()
  check('the panel: five cards, and nothing dimmed', [s.cards(), s.dimmed()], [5, NONE])
  s.p.down(card(1))
  check('a press on the rifle (slot 1) dims its card, and only its', s.dimmed(), [1])
  s.p.up(card(1))
  check("...and its release there is a click: today's select of slot 1, and nothing dimmed after",
    [s.sent(), s.dimmed()], [[['INV_SELECT', { slot: 1 }]], NONE])
  s.clear()
  s.p.click(card(2))
  check("a click on the empty slot 2: today's select of it, and nothing dims", [s.sent(), s.dimmed()], [[['INV_SELECT', { slot: 2 }]], NONE])
  s.clear()
  s.p.drag(card(1), numberOn(1))
  check('a press on the rifle let go on its number (inside the card it began on): its select too', s.sent(), [['INV_SELECT', { slot: 1 }]])
  s.clear()
  s.p.drag(card(1), card(2))
  check('the rifle pressed and let go on the empty slot 2: INV_SWAP {from 1, to 2}, and nothing dimmed after',
    [s.sent(), s.dimmed()], [[['INV_SWAP', { from: 1, to: 2 }]], NONE])
  s.clear()
  s.p.drag(numberOn(1), numberOn(3))
  check("...and pressed on its number, let go on the med kit's (slot 3): INV_SWAP {from 1, to 3}", s.sent(), [['INV_SWAP', { from: 1, to: 3 }]])
}
// GRABBED BY ITS PICTURE, the natural place to take a card: Chromium offers a
// native drag of the <img>, and the panel refuses it, so the press goes on.
{
  const s = scenario()
  check("the panel refuses a native drag of each card's picture: the rifle's, the med kit's and the pistol's",
    [1, 3, 5].map((i) => s.p.dragstart(pictureOn(i))), [true, true, true])
  s.p.moved(pictureOn(1), card(3))
  check('the rifle grabbed by its picture and let go on the med kit (slot 3): INV_SWAP {from 1, to 3}, and nothing dimmed after',
    [s.sent(), s.dimmed()], [[['INV_SWAP', { from: 1, to: 3 }]], NONE])
  s.clear()
  s.p.moved(pictureOn(5), card(2))
  check('the pistol grabbed by its picture and let go on the empty slot 2: INV_SWAP {from 5, to 2}', s.sent(), [['INV_SWAP', { from: 5, to: 2 }]])
  s.clear()
  s.p.moved(pictureOn(3), pictureOn(3))
  check('the med kit grabbed by its picture, moved and let go on its own card: its select (INV_SELECT {slot 3})',
    [s.sent(), s.dimmed()], [[['INV_SELECT', { slot: 3 }]], NONE])
}

console.log('2. a press let go off the cards ends there (#440)')
for (const [where, at] of [
  ['beside the panel', BESIDE],
  ["on the panel's header", header],
  ['in the gap between two cards', gap],
  ['on the ammo strip', strip],
  ["on the med kit's Drop (a button that stops the release)", buttonOn(3, 'Drop')],
  ["on its own card's ▶", buttonOn(1, '▶')],
]) {
  const s = scenario()
  s.p.down(card(1))
  s.p.up(at)
  check(`the rifle pressed and let go ${where}: nothing sent, and nothing held (no card dimmed)`, [s.sent(), s.dimmed()], [NONE, NONE])
  s.p.click(card(4))
  check('...then a click on the empty slot 4 is its select, and never moves the rifle there', s.sent(), [['INV_SELECT', { slot: 4 }]])
}

console.log('3. a release over a card is nothing unless its press went down on a card (#440)')
for (const [where, at] of [
  ['beside the panel', BESIDE],
  ["on the panel's header", header],
  ['in the gap between two cards', gap],
  ['on the empty slot 2', card(2)],
  ["on the med kit's own Drop (the button's press, never its card's)", buttonOn(3, 'Drop')],
]) {
  const s = scenario()
  s.p.down(at)
  s.p.up(card(3))
  check(`a press ${where} let go over the med kit (slot 3): nothing sent, nothing dimmed`, [s.sent(), s.dimmed()], [NONE, NONE])
}
{
  const s = scenario()
  s.p.up(card(3))
  check('a release over slot 3 with no press of its own (the button already down as the panel opened): nothing sent',
    s.sent(), NONE)
}
// AFTER AN EARLIER GESTURE, let go on a card or off the cards. Every release
// hands over the press it ended, none included, so a later release over a card
// never acts on an earlier gesture's press, whether a card's release read it or
// none did. The last gesture joins #440's two halves: the rifle let go beside
// the panel, then a press off the cards let go over the med kit.
for (const [before, gesture, did] of [
  ['a click on the rifle (its select)', (s) => s.p.click(card(1)), [['INV_SELECT', { slot: 1 }]]],
  ['the rifle let go on the empty slot 2 (a swap)', (s) => s.p.drag(card(1), card(2)), [['INV_SWAP', { from: 1, to: 2 }]]],
  ['the rifle let go beside the panel (nothing)', (s) => s.p.drag(card(1), BESIDE), NONE],
]) {
  for (const [where, at] of [
    ['beside the panel', BESIDE],
    ["on the panel's header", header],
    ["on the med kit's own Drop", buttonOn(3, 'Drop')],
  ]) {
    const s = scenario()
    gesture(s)
    const first = s.sent()
    s.clear()
    s.p.down(at)
    s.p.up(card(3))
    check(`${before}, then a press ${where} let go over the med kit (slot 3): nothing sent, nothing dimmed`,
      [first, s.sent(), s.dimmed()], [did, NONE, NONE])
  }
}

console.log('4. every other end, and every press from nothing')
for (const [what, end] of [
  ['a cancel (the browser taking the pointer)', (s) => s.p.cancel(card(1))],
  ['the window losing focus (alt-tab)', (s) => s.p.blur()],
]) {
  const s = scenario()
  s.p.down(card(1))
  end(s)
  check(`the rifle pressed, then ${what}: nothing sent, and nothing held`, [s.sent(), s.dimmed()], [NONE, NONE])
  s.p.up(card(4))
  check('...and a release over the empty slot 4 after it sends nothing: the press is gone, not only its dim', s.sent(), NONE)
  s.p.click(card(4))
  check('...then a click on the empty slot 4 is its select, and never moves the rifle there', s.sent(), [['INV_SELECT', { slot: 4 }]])
}
// A RELEASE THE PAGE NEVER HEARD (let go outside the window, with no blur): the
// next press is all there is.
{
  const s = scenario()
  s.p.down(card(1))
  s.p.down(card(4))
  check('the rifle pressed, its release never heard, then a press on the empty slot 4: no card dimmed (an empty card inherits nothing)',
    [s.dimmed(), s.sent()], [NONE, NONE])
  s.p.up(card(4))
  check("...and its release there is slot 4's select, never a move", s.sent(), [['INV_SELECT', { slot: 4 }]])
}
for (const [where, at] of [
  ['beside the panel', BESIDE],
  ["on the med kit's Drop (a button that stops the press)", buttonOn(3, 'Drop')],
]) {
  const s = scenario()
  s.p.down(card(1))
  s.p.down(at)
  check(`the rifle pressed, its release never heard, then a press ${where}: no card dimmed`, s.dimmed(), NONE)
  s.p.up(card(4))
  check('...and its release over the empty slot 4 sends nothing', s.sent(), NONE)
}
{
  const s = scenario()
  s.p.down(card(1))
  s.p.down(card(5))
  check('the rifle pressed, its release never heard, then a press on the pistol (slot 5): only its card dimmed', s.dimmed(), [5])
  s.p.up(card(2))
  check('...and let go on the empty slot 2: the pistol moves there, INV_SWAP {from 5, to 2}', s.sent(), [['INV_SWAP', { from: 5, to: 2 }]])
}

console.log("5. today's buttons, as they were")
{
  const s = scenario()
  // [dimmed while pressed, sent, dimmed after]: a press on a button is the
  // button's, so its card never dims and its release is no select.
  check('Use on the med kit: INV_USE {slot 3}', s.tap(buttonOn(3, 'Use')), [NONE, [['INV_USE', { slot: 3 }]], NONE])
  check('Drop on the rifle: INV_DROP {slot 1}', s.tap(buttonOn(1, 'Drop')), [NONE, [['INV_DROP', { slot: 1 }]], NONE])
  check('▶ on the rifle: INV_SWAP {from 1, to 2}', s.tap(buttonOn(1, '▶')), [NONE, [['INV_SWAP', { from: 1, to: 2 }]], NONE])
  check('◀ on the pistol: INV_SWAP {from 5, to 4}', s.tap(buttonOn(5, '◀')), [NONE, [['INV_SWAP', { from: 5, to: 4 }]], NONE])
  check("the light pool's Drop: INV_DROP {pool light}", s.tap(poolDrop(0)), [NONE, [['INV_DROP', { pool: 'light' }]], NONE])
  check("an empty pool's Drop (smg): nothing", s.tap(poolDrop(1)), [NONE, NONE, NONE])
}

console.log('6. the window')
{
  const s = scenario()
  // The capture phase, so nothing on an event's way (a card's buttons stop
  // their presses and releases) can hide it. The blur in its own phase only:
  // a capture listener would also hear a button inside the page losing focus
  // to the next press, and end that press.
  check('open: the window hears every press, release and cancel in its capture phase, and its own blur',
    s.listening(), { pointerdown: ['capture'], pointerup: ['capture'], pointercancel: ['capture'], blur: ['target or bubble'] })
  s.close()
  check('closed: every listener the panel gave the window is gone',
    s.listening(), { pointerdown: NONE, pointerup: NONE, pointercancel: NONE, blur: NONE })
}

console.log(`\n${ran - failed}/${ran} passed${failed ? `, ${failed} FAILED` : ''}`)
process.exit(failed ? 1 : 0)
