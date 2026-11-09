#!/usr/bin/env node
/**
 * UI V2'S INVENTORY (#431): the Broadcast bar's and page's beats, and the TAB
 * page's drag, pinned. Nothing mounts either yet; the inventory piece of UI
 * v2 will (#436).
 *
 * 1. THE BEATS (src/screens/inventoryv2/fx.ts). The bar and the page are
 *    never told an event, only a new bag: BR.Inv.push sends the whole
 *    inventory on every change. fx.ts compares each reading with the last and
 *    keeps a counter per beat, so these drive snapOf and nextFx reading by
 *    reading, as the pushes come: a reading with nothing new plays nothing
 *    (the first one included: a mount animates nothing), a pickup is an
 *    arrival, a swap or a move punches both plates toward where each went,
 *    three slots or more at once are a new bag (a light sweeps, nothing
 *    arrives) and two are not, a use begins and ends where it runs (its zip
 *    from how far it came, never past full or below empty) and one that starts
 *    over on its slot does both, a reload is the same gun's clip rising in the
 *    same hand, and the hand coming to a slot picks it.
 *
 * 2. THE DRAG (src/screens/inventoryv2/Page.tsx, in PageSlot as App will draw
 *    it). The real page, rendered by scripts/lockerv2-render.mjs's renderer (no
 *    DOM, no browser), with fetchNui and the cues recording what they are
 *    asked, pressed the way a pointer presses it: the press on a card, its
 *    capture (or a capture refused), the moves to whichever card holds the
 *    capture or else the one under the pointer, the release and the cancel on
 *    the window, a lost capture on the card that had it. The window keeps its
 *    listeners as a browser does, by phase. The cards' rects are laid out by
 *    hand: five cards in a row, 100 px wide and 10 apart.
 *
 *    #440 is today's page: a drag let go off the cards stayed held, and the
 *    next click on an empty slot moved the item there; a release on a card
 *    with no press of its own selected that card. So, on the Broadcast page:
 *
 *      EVERY PRESS ENDS on its release, its cancel, its lost capture, the
 *      window losing focus, a move that says the button came up, or the page
 *      going off air (TAB, or the HUD going down), wherever the pointer is,
 *      and nothing is held after it: no ghost, no dimmed card, no lit one. The
 *      window hears the release and the cancel in its capture phase.
 *      A SELECT only where the release is on the card the press began on, and
 *      only from the main button.
 *      A SWAP only from another card, onto one the server would take it to.
 *      A NEW PRESS STARTS FROM NOTHING: an empty card never inherits an item.
 *      ANOTHER POINTER'S EVENTS ARE ITS OWN: its press, moves, release and
 *      lost capture leave the held item where it is.
 *      A PRESS HOLDS ONLY THE ITEM IT WENT DOWN ON: one that lands in its
 *      slot before it moves never comes up, nor does anything after, and the
 *      bag taking a held item away (a use beginning on it, its slot emptied,
 *      or traded for another in one push) ends the press for good: the bag
 *      changing back brings nothing back, and the release moves nothing. A
 *      push that keeps the item leaves it held, and a press that never moved
 *      is still a click.
 *
 *    each with the capture held and with it refused (a pointer no longer
 *    down), where only the window hears the release. And the server's lock
 *    (#271): while a use runs, the slot it runs on and the slot in hand never
 *    lift or light.
 *
 * 3. PAGESLOT: the page is wanted only while the HUD is up and the focus is
 *    the inventory (today's line); each open gives the window the page's
 *    three listeners and each close takes them; the page leaves on the kit's
 *    page preset, or on its quick way out (PAGE_QUICK) when the pause menu
 *    takes its focus, until it is next opened; and its cards come on air
 *    PAGE_STEP apart even inside a scope with a stagger of its own.
 *
 * 4. THE OTHER THREE REQUESTS, pressed like a pointer: Use, Drop and a pool's
 *    Drop, a press on a card's button never a press of the card.
 *
 *    What a request is and what it carries is check-ui R41's (today's five,
 *    today's shapes); what the server makes of one is the server's.
 *
 * WHY node RUNS fx.ts DIRECTLY: its imports are React (for useBagFx, not
 * called here) and types, which node's type stripping erases.
 *
 * Run: npm run test:inventoryfx   (and as part of npm run build)
 */

import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { emptyFx, nextFx, snapOf } from '../src/screens/inventoryv2/fx.ts'
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

// ── the items ───────────────────────────────────────────────────────────────

const RIFLE = { id: 'carbinerifle', label: 'Carbine Rifle', kind: 'weapon', rarity: 3, count: 1, clip: 30, pool: 'medium' }
const SMG = { id: 'smg', label: 'SMG', kind: 'weapon', rarity: 4, count: 1, clip: 20, pool: 'smg' }
const PISTOL = { id: 'pistol', label: 'Pistol', kind: 'weapon', rarity: 1, count: 1, clip: 12, pool: 'light' }
const SHOTGUN = { id: 'pumpshotgun', label: 'Pump Shotgun', kind: 'weapon', rarity: 2, count: 1, clip: 8, pool: 'shells' }
const MEDKIT = { id: 'medkit', label: 'Med Kit', kind: 'consumable', rarity: 2, count: 2 }
const BANDAGE = { id: 'bandage', label: 'Bandage', kind: 'consumable', rarity: 1, count: 3 }
const AMMO = { light: 24, smg: 0, medium: 60, shells: 0, heavy: 0 }
const bag = (slots, more = {}) => ({ slots, ammo: AMMO, reserve: null, active: 0, using: null, ...more })

// ════════════════════════════════════════════════════════════════════════════
// 1. THE BEATS
// ════════════════════════════════════════════════════════════════════════════
console.log('1. the beats (fx.ts)')
{
  const NOW = 1_800_000_000_000
  /** The beats a run of readings plays, from the first (a mount). */
  const run = (...readings) => {
    let snap = snapOf(readings[0])
    let fx = emptyFx(snap.slots.length)
    const out = [fx]
    for (const r of readings.slice(1)) {
      const next = snapOf(r)
      fx = nextFx(snap, next, fx, r.now ?? NOW)
      snap = next
      out.push(fx)
    }
    return out
  }
  /** Which slots moved which beats from one reading to the next. */
  const moved = (a, b) => {
    const out = []
    b.slots.forEach((f, i) => {
      const w = a.slots[i]
      for (const k of ['arrive', 'sweep', 'pick', 'pop', 'use']) if (f[k] !== w[k]) out.push(`${i}:${k}`)
      if (f.punch.n !== w.punch.n) out.push(`${i}:punch${f.punch.dir > 0 ? '+' : '-'}`)
      if (f.recolor.n !== w.recolor.n) out.push(`${i}:recolor`)
      if (f.done.n !== w.done.n) out.push(`${i}:done`)
    })
    if (b.reload !== a.reload) out.push('reload')
    if (b.gunRecolor.n !== a.gunRecolor.n) out.push('gunRecolor')
    return out
  }

  const first = bag([RIFLE, null, MEDKIT, null, PISTOL], { active: 1 })
  {
    const [fx0, fx1] = run(first, { ...first })
    const zero = fx0.slots.every((f) => f.arrive + f.sweep + f.pick + f.pop + f.use + f.punch.n + f.recolor.n + f.done.n === 0)
    check('the first reading plays nothing (a mount animates nothing): every beat 0, the fists and five slots',
      [fx0.slots.length, zero, fx0.reload, fx0.gunRecolor.n], [6, true, 0, 0])
    check('a reading with nothing new in it (a new object, the same bag) plays nothing', moved(fx0, fx1), [])
  }
  {
    const [a, b] = run(first, { ...first, slots: [RIFLE, SMG, MEDKIT, null, PISTOL] })
    check('a pickup into slot 2: the item arrives there, and its slab takes its rarity (recolor)', moved(a, b), ['2:arrive', '2:recolor'])
  }
  {
    const [a, b] = run(first, { ...first, slots: [MEDKIT, null, RIFLE, null, PISTOL] })
    check('a swap of slots 1 and 3: both punch toward where each went (1 leftward, 3 rightward), nothing arrives',
      moved(a, b).filter((x) => !x.endsWith('recolor')), ['1:punch-', '3:punch+'])
  }
  {
    const [a, b] = run(first, { ...first, slots: [null, RIFLE, MEDKIT, null, PISTOL] })
    check('a move into the empty slot 2: the rifle punches toward it, and slot 1 goes quiet (recolor), nothing arrives',
      moved(a, b), ['1:recolor', '2:punch+', '2:recolor'])
  }
  {
    const [a, b] = run(first, { ...first, slots: [SMG, BANDAGE, null, MEDKIT, PISTOL] })
    check('three slots or more at once are a new bag (a spectate switch): a light sweeps each filled one, nothing arrives or punches, and the ammo strap takes the new gun\'s rarity',
      moved(a, b).filter((x) => !x.endsWith(':recolor')), ['1:sweep', '2:sweep', '4:sweep', 'gunRecolor'])
  }
  {
    const [a, b] = run(first, { ...first, slots: [SMG, BANDAGE, MEDKIT, null, RIFLE] })
    check('...three exactly is one too: each of the three sweeps, and nothing arrives',
      moved(a, b).filter((x) => !x.endsWith(':recolor')), ['1:sweep', '2:sweep', '5:sweep', 'gunRecolor'])
  }
  {
    const [a, b] = run(first, { ...first, slots: [RIFLE, BANDAGE, MEDKIT, SMG, PISTOL] })
    check('two slots at once are not (two pickups in one push): each arrives, and nothing sweeps',
      moved(a, b), ['2:arrive', '2:recolor', '4:arrive', '4:recolor'])
  }
  {
    const using = { slot: 3, endsAt: 1_800_000_004_000, ms: 4000 }
    const [a, b, c] = run(
      { ...first, active: 3 },
      { ...first, active: 3, using, now: 1_800_000_000_000 },
      { ...first, active: 3, slots: [RIFLE, null, { ...MEDKIT, count: 1 }, null, PISTOL], now: 1_800_000_003_000 },
    )
    check('a use beginning on slot 3: its line slides in there, and only there', moved(a, b), ['3:use'])
    check('...and ending a second early: the line zips away there, from three quarters (how far the use came)',
      [moved(b, c), c.slots[3].done.from], [['3:done'], 0.75])
  }
  {
    // A USE THAT STARTS OVER ON ITS SLOT: the next reading has a use on the
    // same slot with a new end, and no reading between without one.
    const one = { slot: 3, endsAt: 1_800_000_004_000, ms: 4000 }
    const two = { slot: 3, endsAt: 1_800_000_008_000, ms: 4000 }
    const [a, b] = run(
      { ...first, active: 3, using: one },
      { ...first, active: 3, using: two, slots: [RIFLE, null, { ...MEDKIT, count: 1 }, null, PISTOL], now: 1_800_000_004_000 },
    )
    check('a use that starts over on slot 3 (a new end, with no reading between): the old line zips away whole, and the new one slides in',
      [moved(a, b), b.slots[3].done.from], [['3:use', '3:done'], 1])
  }
  {
    // THE ZIP STARTS FROM HOW FAR THE USE CAME, never past either end: an end
    // heard after the use's own end, and one heard as it began with the clock
    // a little behind it.
    const using = { slot: 3, endsAt: 1_800_000_004_000, ms: 4000 }
    const over = { ...first, active: 3, slots: [RIFLE, null, { ...MEDKIT, count: 1 }, null, PISTOL] }
    const [, late] = run({ ...first, active: 3, using }, { ...over, now: 1_800_000_005_000 })
    const [, early] = run({ ...first, active: 3, using }, { ...over, now: 1_799_999_999_900 })
    check('an end heard a second late zips from full, never past it; one heard as the use began, the clock a tenth of a second behind, from empty, never below it',
      [late.slots[3].done.from, early.slots[3].done.from], [1, 0])
  }
  {
    const shot = { ...first, slots: [{ ...RIFLE, clip: 29 }, null, MEDKIT, null, PISTOL] }
    const [a, b, c] = run(first, shot, first)
    check('a shot (the clip falls) plays nothing; a reload (the same gun\'s clip rises) glints the ammo strap',
      [moved(a, b), moved(b, c)], [[], ['reload']])
  }
  {
    // Two rifles alike (the same item, the same rarity), the second with the
    // fuller clip: the gun in hand is "the same" by its key, and its clip rose.
    const twins = bag([{ ...RIFLE, clip: 10 }, { ...RIFLE, clip: 30 }, MEDKIT, null, PISTOL], { active: 1 })
    const [a, b] = run(twins, { ...twins, active: 2 })
    check('the hand going to a second rifle alike with a fuller clip picks slot 2, and is never a reload', moved(a, b), ['2:pick'])
  }
  {
    const [a, b] = run(first, { ...first, active: 5 })
    check('the hand coming to slot 5: slot 5 is picked, and the ammo strap takes the pistol\'s rarity', moved(a, b), ['5:pick', 'gunRecolor'])
  }
  {
    const [a, b] = run(first, { ...first, slots: [RIFLE, null, { ...MEDKIT, count: 3 }, null, PISTOL] })
    check('a stack that grows pops its count', moved(a, b), ['3:pop'])
  }
}

// ════════════════════════════════════════════════════════════════════════════
// 2. THE DRAG
// ════════════════════════════════════════════════════════════════════════════

globalThis.__inv = { calls: [], cues: [] }
const STUBS = {
  nui: `
    const S = globalThis.__inv
    export function fetchNui(cb, data) { S.calls.push([cb, data ?? null]); return Promise.resolve({}) }
    export function onEnvelope() { return () => {} }
    export function subscribe() { return () => {} }
    export function reportError() {}
    export function dispatch() {}
    export const isBrowser = true`,
  cues: `
    const S = globalThis.__inv
    export function play(cue) { S.cues.push(cue) }
    export function setUiVolume() {}
    export function soundReport() { return {} }
    export const CUE_NAMES = []`,
}
const out = await build({
  stdin: {
    contents: [
      "export * as React from 'react'",
      "export { default as InventoryPageSlot } from './src/screens/inventoryv2/PageSlot.tsx'",
      "export { PAGE_QUICK } from './src/screens/inventoryv2/Page.tsx'",
      "export { PAGE_PRESET, PAGE_STEP, PresenceScope, STEP } from './src/ui/broadcast'",
      "export { CB } from './src/bridge/types'",
      "export { useUi } from './src/store'",
    ].join('\n'),
    resolveDir: ROOT,
    loader: 'ts',
    sourcefile: 'test-inventory-fx-entry.ts',
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
    name: 'inventory-stand-ins',
    setup(b) {
      b.onResolve({ filter: /(^|\/)bridge\/nui$/ }, () => ({ path: 'nui', namespace: 'stub' }))
      b.onResolve({ filter: /(^|\/)audio\/cues$/ }, () => ({ path: 'cues', namespace: 'stub' }))
      b.onLoad({ filter: /.*/, namespace: 'stub' }, (a) => ({ contents: STUBS[a.path], loader: 'js', resolveDir: ROOT }))
    },
  }],
})

// The clock, held still (test-squad-elims.mjs's): one instant for every
// Date.now, timers that run when a scenario says, and the presences' clock
// (performance.now) moved by settle().
const NOW = 1_800_000_000_000
let page = fakePage()
Date.now = () => NOW
const timers = () => {
  globalThis.setTimeout = globalThis.window.setTimeout
  globalThis.clearTimeout = globalThis.window.clearTimeout
}
timers()
globalThis.setInterval = () => 0
globalThis.clearInterval = () => {}
let perf = 0
performance.now = () => perf
// What the kit's presences ask of an element (no transition ever runs, so
// each phase ends on the clock), and a style for the drag's ghost to be
// written into.
Object.assign(globalThis.Node.prototype, {
  parentElement: null,
  children: [],
  closest() { return null },
  addEventListener() {},
  removeEventListener() {},
  getAnimations() { return [] },
})
Object.defineProperty(globalThis.Node.prototype, 'style', {
  configurable: true,
  get() { return (this._style ??= {}) },
})

const { React, InventoryPageSlot, PAGE_QUICK, PAGE_PRESET, PAGE_STEP, PresenceScope, STEP, CB, useUi } = await import(
  `data:text/javascript;base64,${Buffer.from(out.outputFiles[0].text).toString('base64')}`)
const store = () => useUi.getState()
const FRESH = useUi.getState()
const NAME = Object.fromEntries(Object.entries(CB).map(([k, v]) => [v, k]))

/** PageSlot as App will draw it, given App's hudUp (`__inv.up`, which a
 *  scenario turns over to bring the HUD down or up again). */
function Slot() {
  return React.createElement(InventoryPageSlot, { up: globalThis.__inv.up })
}

/** Card i's rect: five in a row, 100 px wide, 10 apart, from x 20. */
const rect = (i) => {
  const left = 20 + (i - 1) * 110
  return { left, right: left + 100, top: 50, bottom: 250, width: 100, height: 200, x: left, y: 50 }
}
const mid = (i) => ({ x: rect(i).left + 50, y: 150 })
/** Off every card: under the row. */
const OFF = { x: 300, y: 400 }

/**
 * ONE SCENARIO: the page fresh, the bag `inv` in the store, the TAB focus up,
 * PageSlot mounted as App will mount it (`up`: the HUD up), every presence
 * settled on air, and a pointer to press it with. `refuse`: the card refuses
 * the capture. `up` and `focus`: App's hudUp and Lua's focus to start from.
 * `outer`: the props of a scope to draw PageSlot inside.
 */
function scenario(inv, { refuse = false, up = true, focus = 'inventory', outer = null } = {}) {
  useUi.setState(FRESH, true)
  page = fakePage()
  timers()
  // THE WINDOW'S LISTENERS, kept as a browser keeps them (fakePage's window
  // ignores the phase): one per type, function and phase, and a removal takes
  // only the one that matches all three, so one added in the capture phase
  // and removed without it stays.
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
  globalThis.__inv.calls = []
  globalThis.__inv.cues = []
  globalThis.__inv.up = up
  store().setInv(inv)
  store().setFocus(focus)
  const slot = React.createElement(Slot)
  const view = mount(React, outer ? React.createElement(PresenceScope, outer, slot) : slot)
  const settle = () => {
    for (let i = 0; i < 4; i++) {
      perf += 5_000
      page.frames()
      view.render()
    }
  }
  settle()

  // THE POINTER. A capture is held by one card per pointer; a capture that
  // goes (released, or taken by the release itself) is reported to the card
  // that had it, after the event that ended it, as a browser does.
  const owner = new Map()
  const lost = []
  const cards = {}
  for (let i = 1; i <= 5; i++) {
    cards[i] = {
      slot: i,
      dataset: { binvSlot: String(i) },
      getBoundingClientRect: () => rect(i),
      setPointerCapture(id) {
        if (refuse) throw new Error('InvalidPointerId')
        const was = owner.get(id)
        if (was && was !== this) lost.push([was, id])
        owner.set(id, this)
      },
      hasPointerCapture(id) { return owner.get(id) === this },
      releasePointerCapture(id) {
        if (owner.get(id) !== this) return
        owner.delete(id)
        lost.push([this, id])
      },
    }
  }
  const box = () => view.all((n) => hasClass(n, 'binv-page__cards'))[0]?.node ?? null
  const lay = () => {
    const b = box()
    if (!b?.el) return
    Object.assign(b.el, {
      offsetWidth: 600,
      getBoundingClientRect: () => ({ left: 0, top: 0, right: 600, bottom: 400, width: 600, height: 400, x: 0, y: 0 }),
      querySelectorAll: () => [1, 2, 3, 4, 5].map((i) => cards[i]),
    })
  }
  lay()
  const cardNode = (i) => view.all((n) => n.props['data-binv-slot'] === i)[0]?.node ?? null
  const under = ({ x, y }) => [1, 2, 3, 4, 5].map((i) => cards[i])
    .find((c) => x >= rect(c.slot).left && x < rect(c.slot).right && y >= rect(c.slot).top && y < rect(c.slot).bottom) ?? null
  const ev = (o) => ({ button: 0, buttons: 1, pointerId: 1, clientX: 0, clientY: 0, preventDefault() {}, stopPropagation() {}, ...o })
  const flushLost = () => {
    while (lost.length) {
      const [card, id] = lost.shift()
      const n = cardNode(card.slot)
      if (n?.props.onLostPointerCapture) view.act(() => n.props.onLostPointerCapture(ev({ pointerId: id, currentTarget: card, target: card })))
    }
  }
  // The window is the first and the last stop of every event's path: its
  // capture-phase listeners hear it first, the others last.
  const windowHears = (kind, e) => view.act(() => {
    for (const l of [...win.filter((x) => x.kind === kind && x.capture), ...win.filter((x) => x.kind === kind && !x.capture)]) l.fn(e)
  })
  const p = {
    /** A press on card i at `at` (its middle by default); `more`: the event's
     *  other fields (another button). */
    down(i, at = mid(i), id = 1, more = {}) {
      const n = cardNode(i)
      view.act(() => n.props.onPointerDown(ev({ pointerId: id, clientX: at.x, clientY: at.y, currentTarget: cards[i], target: cards[i], ...more })))
      lay()
      flushLost()
    },
    /**
     * A press that lands on `hit` (a node from view.all, with its ancestors),
     * as React delivers it: pointerdown on that element, then on each one
     * above it, nearest first, until a handler stops it. A card's handler
     * sees its card as the element it is on.
     */
    pressOn(hit, at, id = 1) {
      let stopped = false
      const e = ev({ pointerId: id, clientX: at.x, clientY: at.y, stopPropagation() { stopped = true } })
      view.act(() => {
        for (const n of [hit.node, ...[...hit.parents].reverse()]) {
          if (stopped) break
          if (!n.props.onPointerDown) continue
          const i = n.props['data-binv-slot']
          n.props.onPointerDown({ ...e, currentTarget: i ? cards[i] : n, target: hit.node })
        }
      })
      lay()
      flushLost()
    },
    /** A move to `at`: heard by the card holding the capture, or else the one under it. */
    move(at, { id = 1, buttons = 1 } = {}) {
      const to = owner.get(id) ?? under(at)
      if (to) view.act(() => cardNode(to.slot).props.onPointerMove(ev({ pointerId: id, buttons, clientX: at.x, clientY: at.y, currentTarget: to, target: to })))
      flushLost()
    },
    /** The release at `at`, on the window (wherever it lands); the capture goes with it. */
    up(at, id = 1, more = {}) {
      windowHears('pointerup', ev({ pointerId: id, buttons: 0, clientX: at.x, clientY: at.y, target: owner.get(id) ?? under(at), ...more }))
      const had = owner.get(id)
      if (had) { owner.delete(id); lost.push([had, id]) }
      flushLost()
    },
    /** A lost capture of pointer `id`, reported on card i. */
    lostOn(i, id) {
      view.act(() => cardNode(i).props.onLostPointerCapture(ev({ pointerId: id, currentTarget: cards[i], target: cards[i] })))
    },
    cancel(id = 1) {
      windowHears('pointercancel', ev({ pointerId: id, buttons: 0 }))
      const had = owner.get(id)
      if (had) { owner.delete(id); lost.push([had, id]) }
      flushLost()
    },
    /** The capture taken away from the card that has it, the press still down. */
    loseCapture(id = 1) {
      const had = owner.get(id)
      if (had) { owner.delete(id); lost.push([had, id]) }
      flushLost()
    },
    blur() { windowHears('blur', {}) },
    /** A press and its release on card i, with no move: a click. */
    click(i, id = 1) { p.down(i, mid(i), id); p.up(mid(i), id) },
    /** Card i picked up and carried to `to`, still held. */
    lift(i, to, id = 1) {
      p.down(i, mid(i), id)
      p.move({ x: mid(i).x + 20, y: mid(i).y }, { id })
      p.move(to, { id })
    },
  }
  return {
    view,
    settle,
    p,
    /** App's hudUp turned over (the HUD going down, or coming up). */
    setUp: (v) => view.act(() => { globalThis.__inv.up = v }),
    /** What was asked of the game: each request by its name, with its payload. */
    sent: () => globalThis.__inv.calls.map(([cb, data]) => [NAME[cb] ?? cb, data]),
    cues: () => [...globalThis.__inv.cues],
    clear: () => { globalThis.__inv.calls = []; globalThis.__inv.cues = [] },
    /** What is drawn held: the ghost, a dimmed card, a lit one. */
    held: () => ({
      ghost: view.all((n) => hasClass(n, 'binv-ghost')).length,
      dragging: [1, 2, 3, 4, 5].filter((i) => cardNode(i) && hasClass(cardNode(i), 'is-dragging')),
      lit: [1, 2, 3, 4, 5].filter((i) => cardNode(i) && hasClass(cardNode(i), 'is-target')),
    }),
    /** The cards drawn, by slot. */
    drawn: () => [1, 2, 3, 4, 5].filter((i) => cardNode(i)),
    /** The page's root (its presence): its phase and its preset, or null. */
    root: () => {
      const n = view.all((x) => hasClass(x, 'binv-page'))[0]?.node
      return n ? { phase: n.props['data-bc-phase'], preset: n.props['data-bc-preset'] } : null
    },
    /** What the window listens to for a press's end, and in which phase. */
    listening: () => Object.fromEntries(['pointerup', 'pointercancel', 'blur']
      .map((k) => [k, win.filter((l) => l.kind === k).map((l) => (l.capture ? 'capture' : 'target or bubble'))])),
    /** A button by its words, inside card i (or inside the pools, for `pool`),
     *  with its ancestors. */
    hit: (words, within) => view.all((n) => n.type === 'button' && textOf(n) === words)
      .find((x) => x.parents.some(within)) ?? null,
    cardIs: (i) => (n) => n.props['data-binv-slot'] === i,
    owner,
  }
}

const NOTHING = { ghost: 0, dragging: [], lit: [] }
const START = bag([RIFLE, null, MEDKIT, null, PISTOL], { active: 1 })

console.log('2. the drag (Page.tsx, in PageSlot)')
{
  const s = scenario(START)
  check('the page is on air: five cards, each a press target, and nothing held',
    [[1, 2, 3, 4, 5].filter((i) => s.view.all((n) => n.props['data-binv-slot'] === i).length === 1), s.held()],
    [[1, 2, 3, 4, 5], NOTHING])
  // The release and the cancel in the window's capture phase: it hears them
  // before anything on their way, which could stop them. The blur in its
  // own phase only: a capture listener would also hear every element inside
  // the page losing focus (a blur does not bubble, but it is captured).
  check('...and the window hears the release and the cancel in its capture phase (every press ends on one), and its own blur',
    s.listening(), { pointerup: ['capture'], pointercancel: ['capture'], blur: ['target or bubble'] })
}

for (const refuse of [false, true]) {
  const how = refuse ? 'the capture refused' : 'the capture held'
  console.log(`2. the drag, ${how}`)

  {
    const s = scenario(START, { refuse })
    s.p.click(3)
    check(`${how}: a click on a card (press and release on it, no move) is today's select of it`, s.sent(), [['INV_SELECT', { slot: 3 }]])
    s.clear()
    s.p.click(2)
    check(`${how}: ...an empty card's too`, s.sent(), [['INV_SELECT', { slot: 2 }]])
  }
  {
    // THE MAIN BUTTON ONLY: a right-click is br_core's way to close the page.
    const s = scenario(START, { refuse })
    s.p.down(3, mid(3), 1, { button: 2, buttons: 2 })
    check(`${how}: a right-button press on card 3 is no press of it: no capture taken`, s.owner.size, 0)
    s.p.up(mid(3), 1, { button: 2 })
    check(`${how}: ...and its release there selects nothing, and nothing is held`, [s.sent(), s.held()], [[], NOTHING])
  }
  {
    const s = scenario(START, { refuse })
    s.p.lift(1, mid(2))
    check(`${how}: an item picked up and carried over the empty slot 2: the ghost, the rifle's card dimmed, slot 2 lit`,
      s.held(), { ghost: 1, dragging: [1], lit: [2] })
    s.p.up(mid(2))
    check(`${how}: ...let go there: INV_SWAP {from 1, to 2}, with the arrows' cue, and nothing held after`,
      [s.sent(), s.cues().filter((c) => c === 'ui.select').length, s.held()],
      [[['INV_SWAP', { from: 1, to: 2 }]], 1, NOTHING])
  }
  {
    // #440, the way today's page does it.
    const s = scenario(START, { refuse })
    s.p.lift(1, mid(2))
    s.p.move(OFF)
    // Without the capture no card hears a move off the cards, so slot 2 stays
    // lit until the release, which the window hears and reads where it lands.
    check(`${how}: carried off every card: ${refuse ? 'unheard, slot 2 still lit' : 'nothing lit'}`, s.held().lit, refuse ? [2] : [])
    s.p.up(OFF)
    check(`${how}: let go off every card: nothing sent, and NOTHING HELD (#440): no ghost, no dimmed card, no lit one`,
      [s.sent(), s.held()], [[], NOTHING])
    s.p.click(4)
    check(`${how}: ...then a click on the empty slot 4 is a select of slot 4, and never moves the rifle there (#440)`,
      s.sent(), [['INV_SELECT', { slot: 4 }]])
  }
  {
    const s = scenario(START, { refuse })
    s.p.lift(1, mid(2))
    s.p.move(mid(1))
    check(`${how}: carried back over the card it came from: nothing lit`, s.held(), { ghost: 1, dragging: [1], lit: [] })
    s.p.up(mid(1))
    check(`${how}: ...let go there: nothing sent (a drag is never a select), nothing held`, [s.sent(), s.held()], [[], NOTHING])
  }
  {
    // A RELEASE WHOSE PRESS BEGAN ELSEWHERE. Pressed 4 px inside card 1's
    // right edge and let go 5 px on, in the 10 px gap: under LIFT_PX (6), so
    // not a drag, and not on the card either. Then pressed on card 1 and let
    // go on card 2 with no move heard between (crossing the gap, which no
    // card hears without the capture): still a press that never moved.
    const s = scenario(START, { refuse })
    const edge = rect(1).right
    s.p.down(1, { x: edge - 4, y: 150 })
    s.p.up({ x: edge + 1, y: 150 })
    check(`${how}: a press on card 1 let go in the gap beside it, under LIFT_PX away: nothing sent, nothing held`,
      [s.sent(), s.held()], [[], NOTHING])
    s.p.down(1)
    s.p.up(mid(2))
    check(`${how}: a press on card 1 let go on card 2 with no move heard between: no select of either card, nothing held`,
      [s.sent(), s.held()], [[], NOTHING])
  }
  {
    // A RELEASE WITH NO PRESS OF ITS OWN: the button already down as the page
    // came up, or pressed somewhere else on the screen.
    const s = scenario(START, { refuse })
    s.p.up(mid(3))
    check(`${how}: a release over card 3 with no press of its own: nothing sent`, s.sent(), [])
    s.p.down(1)
    s.p.up(mid(1), 2)
    check(`${how}: a release by another pointer over the pressed card: nothing sent, and the press still holds`,
      [s.sent(), s.owner.size], [[], refuse ? 0 : 1])
    s.p.up(mid(1))
    check(`${how}: ...until its own release, a select of card 1`, s.sent(), [['INV_SELECT', { slot: 1 }]])
  }
  {
    const s = scenario(START, { refuse })
    s.p.lift(1, mid(2))
    s.p.down(4, mid(4), 2)
    s.p.up(mid(4), 2)
    check(`${how}: a second finger pressing and letting go of the empty slot 4 mid-drag: nothing sent, and the rifle stays held over slot 2`,
      [s.sent(), s.held()], [[], { ghost: 1, dragging: [1], lit: [2] }])
    // Every other event of another pointer is that pointer's alone: a move
    // over slot 5 (with its button down, and then up) and a lost capture
    // reported on the held card.
    s.p.move(mid(5), { id: 2 })
    s.p.move(mid(5), { id: 2, buttons: 0 })
    s.p.lostOn(1, 2)
    check(`${how}: ...nor do its moves over slot 5, or a lost capture of its own on the rifle's card: the rifle stays held over slot 2`,
      [s.sent(), s.held()], [[], { ghost: 1, dragging: [1], lit: [2] }])
    s.p.move(mid(4))
    s.p.up(mid(4))
    check(`${how}: ...and the first lets it go over slot 4: INV_SWAP {from 1, to 4}, nothing held`,
      [s.sent(), s.held()], [[['INV_SWAP', { from: 1, to: 4 }]], NOTHING])
  }
  {
    const s = scenario(START, { refuse })
    s.p.lift(1, mid(2))
    s.p.down(4)
    check(`${how}: the same pointer pressing again (its release never came): the item goes down, and the empty slot 4 inherits nothing`,
      [s.held(), s.sent()], [NOTHING, []])
    s.p.up(mid(4))
    check(`${how}: ...that press is a click of its own: a select of slot 4, never a swap`, s.sent(), [['INV_SELECT', { slot: 4 }]])
  }

  // EVERY OTHER WAY A PRESS ENDS: nothing sent, nothing held, and the next
  // release (where it would have dropped) sends nothing either. After the
  // page goes off air the release comes while it leaves, when the window
  // still hears one: once the page has left, its listeners are gone with it.
  const LEAVING = ' (its release heard while the page leaves)'
  const ends = [
    ['a cancel', (s) => s.p.cancel()],
    ['the window losing focus (alt-tab)', (s) => s.p.blur()],
    ['a move that says the button came up', (s) => { s.p.move(mid(2)); s.p.move(mid(3), { buttons: 0 }) }],
    ['the page going off air (TAB)', (s) => s.view.act(() => store().setFocus('none')), LEAVING],
    ['the HUD going down (App\'s hudUp)', (s) => s.setUp(false), LEAVING],
  ]
  if (!refuse) ends.push(['the capture taken away', (s) => s.p.loseCapture()])
  for (const [what, end, after = ''] of ends) {
    const s = scenario(START, { refuse })
    s.p.lift(1, mid(2))
    end(s)
    s.p.up(mid(2))
    check(`${how}: ${what} mid-drag ends it${after}: nothing sent, nothing held`, [s.sent(), s.held()], [[], NOTHING])
  }
  {
    // A CLICK CAUGHT BY THE WAY OUT: a press on a card, TAB, and its release
    // on the same card while the page leaves.
    const s = scenario(START, { refuse })
    s.p.down(3)
    s.view.act(() => store().setFocus('none'))
    if (!refuse) check(`${how}: a press on card 3 as TAB takes the page off air ends there: its capture is let go at once`, s.owner.size, 0)
    s.p.up(mid(3))
    check(`${how}: ...and its release on card 3, as the page leaves, selects nothing`, [s.root()?.phase, s.sent()], ['leaving', []])
  }

  {
    // THE BAG TAKING A HELD ITEM AWAY (every push is the whole bag) ENDS THE
    // PRESS, as a release off the cards does, and for good: the button still
    // down, the bag changing back brings nothing back, and the release moves
    // nothing. First a use beginning on the held med kit, and then ending.
    const s = scenario(START, { refuse })
    s.p.lift(3, mid(2))
    s.view.act(() => store().setInv({ ...START, using: { slot: 3, endsAt: NOW + 4000, ms: 4000 } }))
    check(`${how}: a use beginning on the held med kit mid-drag ends the press: nothing drawn held, no capture kept`,
      [s.held(), s.owner.size], [NOTHING, 0])
    s.view.act(() => store().setInv({ ...START, slots: [RIFLE, null, { ...MEDKIT, count: 1 }, null, PISTOL] }))
    s.p.move(mid(4))
    check(`${how}: ...and the use ending, the button still down, brings nothing back: nothing drawn held over the empty slot 4`,
      s.held(), NOTHING)
    s.p.up(mid(4))
    check(`${how}: ...and letting go there sends nothing`, s.sent(), [])
  }
  {
    // The held slot emptied, and then an SMG landing in it.
    const s = scenario(START, { refuse })
    s.p.lift(5, mid(2))
    s.view.act(() => store().setInv({ ...START, slots: [RIFLE, null, MEDKIT, null, null] }))
    check(`${how}: the held slot emptied mid-drag (a push with nothing in slot 5) ends the press: nothing drawn held, no capture kept`,
      [s.held(), s.owner.size], [NOTHING, 0])
    s.view.act(() => store().setInv({ ...START, slots: [RIFLE, null, MEDKIT, null, SMG] }))
    s.p.move(mid(4))
    check(`${how}: ...and an SMG landing in slot 5, the button still down, is never held: nothing drawn held over slot 4`,
      s.held(), NOTHING)
    s.p.up(mid(4))
    check(`${how}: ...and letting go there sends nothing: the SMG, never pressed, stays where it landed`, s.sent(), [])
  }
  {
    // The held slot traded for another item in one push: a full bag's pickup
    // trades the hand (br_core/server/inventory.lua, swapSlot).
    const full = bag([RIFLE, BANDAGE, MEDKIT, SMG, PISTOL], { active: 1 })
    const s = scenario(full, { refuse })
    s.p.lift(1, mid(2))
    s.view.act(() => store().setInv({ ...full, slots: [SHOTGUN, BANDAGE, MEDKIT, SMG, PISTOL] }))
    s.p.move(mid(4))
    check(`${how}: the rifle in hand traded for a shotgun mid-drag (a full bag's pickup, one push) ends the press: nothing drawn held over slot 4, no capture kept`,
      [s.held(), s.owner.size], [NOTHING, 0])
    s.p.up(mid(4))
    check(`${how}: ...and letting go there sends nothing: the shotgun, never pressed, stays in hand`, s.sent(), [])
  }
  {
    // A PUSH THAT KEEPS THE HELD ITEM: its stack topped up, a bandage picked
    // up into slot 2 under it, the rifle's clip changed.
    const s = scenario(START, { refuse })
    s.p.lift(3, mid(2))
    s.view.act(() => store().setInv({ ...START, slots: [{ ...RIFLE, clip: 12 }, BANDAGE, { ...MEDKIT, count: 3 }, null, PISTOL] }))
    check(`${how}: a push that keeps the held med kit (its stack topped up, a pickup into slot 2, the rifle's clip): it stays held over slot 2`,
      s.held(), { ghost: 1, dragging: [3], lit: [2] })
    s.p.up(mid(2))
    check(`${how}: ...and let go there: INV_SWAP {from 3, to 2}`, s.sent(), [['INV_SWAP', { from: 3, to: 2 }]])
  }
  {
    // AN ITEM LANDING UNDER A PRESS BEFORE IT MOVES never comes up with it,
    // and the press lifts nothing after: the pistol traded for an SMG (and
    // back), and the empty slot 2 filled. A press that never moved is still a
    // click.
    const s = scenario(START, { refuse })
    s.p.down(5)
    s.view.act(() => store().setInv({ ...START, slots: [RIFLE, null, MEDKIT, null, SMG] }))
    s.p.move({ x: mid(5).x - 20, y: mid(5).y })
    s.p.move(mid(4))
    check(`${how}: a press on the pistol, an SMG in its place before it moves: the move lifts nothing`, s.held(), NOTHING)
    s.view.act(() => store().setInv(START))
    s.p.move({ x: mid(4).x + 10, y: mid(4).y })
    check(`${how}: ...nor does the pistol coming back, the button still down: nothing drawn held over slot 4`, s.held(), NOTHING)
    s.p.up(mid(4))
    check(`${how}: ...and letting go there sends nothing: the pistol never came up`, s.sent(), [])
    s.clear()
    s.p.down(2)
    s.view.act(() => store().setInv({ ...START, slots: [RIFLE, BANDAGE, MEDKIT, null, SMG] }))
    s.p.move({ x: mid(2).x + 20, y: mid(2).y })
    s.p.move(mid(4))
    check(`${how}: a press on the empty slot 2, a bandage landing there before it moves: the move lifts nothing (an empty card never inherits an item)`,
      s.held(), NOTHING)
    s.p.up(mid(4))
    check(`${how}: ...and letting go over slot 4 sends nothing`, s.sent(), [])
    s.clear()
    s.p.down(5)
    s.view.act(() => store().setInv({ ...START, slots: [RIFLE, BANDAGE, MEDKIT, null, PISTOL] }))
    s.p.up(mid(5))
    check(`${how}: a press on the SMG, the pistol back in its place before its release there: still a click, today's select of slot 5`,
      s.sent(), [['INV_SELECT', { slot: 5 }]])
  }

  {
    // THE SERVER'S LOCK (#271): a med kit running in slot 3, the rifle in hand.
    const busy = { ...START, using: { slot: 3, endsAt: NOW + 4000, ms: 4000 } }
    const s = scenario(busy, { refuse })
    s.p.lift(1, mid(2))
    s.p.up(mid(2))
    s.p.lift(3, mid(4))
    s.p.up(mid(4))
    check(`${how}: during a use, the hand (slot 1) and the slot in use (slot 3) never lift, and nothing is sent`,
      [s.held(), s.sent()], [NOTHING, []])
    s.p.lift(5, mid(3))
    check(`${how}: ...the pistol lifts, but slot 3 (in use) is never lit under it`, s.held(), { ghost: 1, dragging: [5], lit: [] })
    s.p.up(mid(3))
    check(`${how}: ...and let go there sends nothing`, s.sent(), [])
    s.p.lift(5, mid(1))
    check(`${how}: ...nor is the hand (slot 1)`, s.held().lit, [])
    s.p.move(mid(4))
    s.p.up(mid(4))
    check(`${how}: ...but slot 4 is, and the pistol goes there: INV_SWAP {from 5, to 4}`, s.sent(), [['INV_SWAP', { from: 5, to: 4 }]])
  }
}

console.log("3. PageSlot: when the page is wanted, its listeners, its way out and its stagger")
{
  // THE HUD DOWN: today's line draws the panel only while hudUp (App.tsx).
  const s = scenario(START, { up: false })
  check('the focus on the inventory with the HUD down (a ride, the lobby): no page, no card, and the window hears nothing for it',
    [s.root(), s.drawn(), s.listening()], [null, [], { pointerup: [], pointercancel: [], blur: [] }])
  s.p.up(mid(3))
  check('...so a release over where card 3 would be sends nothing', s.sent(), [])
  s.setUp(true)
  s.settle()
  check('...and the HUD coming up brings the page on air, with its five cards', [s.root()?.phase, s.drawn()], ['shown', [1, 2, 3, 4, 5]])
  s.setUp(false)
  s.settle()
  check('...and going down again takes it off air', [s.root(), s.drawn()], [null, []])
}
{
  // EVERY OPEN ADDS THE PAGE'S THREE LISTENERS, AND ITS CLOSE TAKES THEM.
  const s = scenario(START)
  s.view.act(() => store().setFocus('none'))
  s.settle()
  check('TAB closes the page: it is gone, and so is every listener it gave the window',
    [s.root(), s.listening()], [null, { pointerup: [], pointercancel: [], blur: [] }])
  s.view.act(() => store().setFocus('inventory'))
  s.settle()
  check('...and TAB opens it again with one of each, never one more',
    s.listening(), { pointerup: ['capture'], pointercancel: ['capture'], blur: ['target or bubble'] })
}
{
  // ITS WAY OUT (usePageExit). TAB, Esc, a right-click and the HUD going take
  // it off air on the kit's page preset; the pause menu taking its focus fades
  // it on the quick hide's timing (PAGE_QUICK), until it is next opened.
  const s = scenario(START)
  const seen = [s.root()]
  s.view.act(() => store().setFocus('pause'))
  seen.push(s.root())
  s.view.act(() => store().setFocus('none'))
  seen.push(s.root())
  s.settle()
  s.view.act(() => store().setFocus('inventory'))
  seen.push(s.root())
  s.settle()
  s.view.act(() => store().setFocus('none'))
  seen.push(s.root())
  check(`open on the page preset; the pause menu over it: out on ${PAGE_QUICK}; the pause closing mid-fade: still ${PAGE_QUICK}; opened again: the page preset; TAB: out on the page preset`,
    seen, [
      { phase: 'shown', preset: PAGE_PRESET },
      { phase: 'leaving', preset: PAGE_QUICK },
      { phase: 'leaving', preset: PAGE_QUICK },
      { phase: 'entering', preset: PAGE_PRESET },
      { phase: 'leaving', preset: PAGE_PRESET },
    ])
}
{
  // ITS STAGGER IS ITS OWN. A scope that names no step takes the one above it
  // (motion/tokens.ts PAGE_STEP), so the page's scope names the kit's page
  // stagger itself. Drawn inside a scope that names another (STEP, as the
  // squad panel's does), the cards still come on air PAGE_STEP apart.
  const s = scenario(START, { focus: 'none', outer: { step: STEP } })
  s.view.act(() => store().setFocus('inventory'))
  const delays = [1, 2, 3, 4, 5].map((i) => parseFloat(
    s.view.all((n) => n.props['data-inv-id'] === `card-${i}`)[0]?.node.props.style['--bc-root-delay']))
  check(`opened inside a scope with a stagger of its own (${STEP} ms): the five cards still come on air ${PAGE_STEP} ms apart`,
    delays.slice(1).map((d, k) => d - delays[k]), [PAGE_STEP, PAGE_STEP, PAGE_STEP, PAGE_STEP])
}

console.log("4. the page's other requests, pressed like a pointer")
{
  const s = scenario(START)
  // Read afresh each time: every act draws a new tree.
  const pools = () => s.view.all((n) => hasClass(n, 'binv-pool'))
  const poolDrop = (k) => s.hit('Drop', (p) => p === pools()[k]?.node)
  check('Use on the med kit, Drop on the rifle, and a Drop under each of the five pools',
    [!!s.hit('Use', s.cardIs(3)), !!s.hit('Drop', s.cardIs(1)), pools().length, [0, 1, 2, 3, 4].every((k) => !!poolDrop(k))],
    [true, true, 5, true])
  /** A button pressed where it is drawn (`at`: on its card, or under the
   *  cards for a pool), its release there, and then its click: what a press
   *  starts, if anything, and what is sent. */
  const tap = (find, at) => {
    s.clear()
    s.p.pressOn(find(), at)
    const took = s.owner.size
    s.p.up(at)
    s.view.act(() => find().node.props.onClick())
    return [took, s.sent()]
  }
  // A press on a card's button is the button's: the card never hears it, so
  // it takes no capture and its release is no select (today's buttons stop
  // the press for the same reason, InventoryPanel.tsx).
  check("Use, pressed on the med kit's card: INV_USE {slot}, and the press is the button's alone (no capture, no select)",
    tap(() => s.hit('Use', s.cardIs(3)), mid(3)), [0, [['INV_USE', { slot: 3 }]]])
  check("Drop, pressed on the rifle's card: INV_DROP {slot}, and the press is the button's alone",
    tap(() => s.hit('Drop', s.cardIs(1)), mid(1)), [0, [['INV_DROP', { slot: 1 }]]])
  check("a pool's Drop: INV_DROP {pool}; an empty pool's: nothing",
    [tap(() => poolDrop(0), OFF), tap(() => poolDrop(1), OFF)], [[0, [['INV_DROP', { pool: 'light' }]]], [0, []]])
}

console.log(`\n${ran - failed}/${ran} passed${failed ? `, ${failed} FAILED` : ''}`)
process.exit(failed ? 1 : 0)
