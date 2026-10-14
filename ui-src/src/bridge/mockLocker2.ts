/**
 * LOCKER V2 IN THE BROWSER HARNESS (#28): a stand-in for br_core's
 * client/locker2.lua, so the Season 2 locker -- "My Looks" -- can be built and
 * looked at in `npm run dev` with no game behind it.
 *
 * DEV ONLY, like the rest of bridge/mock.ts: production never imports it.
 *
 * It plays Lua's part closely enough to exercise every state the screen
 * draws, and it plays the parts Lua DOES NOT HAVE YET, which the wiring round
 * builds (bridge/types.ts marks each callback NEW or CHANGED):
 *
 *   * a new custom look (LOCKER2_NEW): the core categories randomized, no
 *     extras; Randomize (LOCKER2_RANDOM) over everything on the look;
 *   * the draft's history (LOCKER2_UNDO / _REDO), run on model.ts's record,
 *     undoStep and redoStep -- a slider's drag or a held arrow one step;
 *   * the extras (LOCKER2_EXTRA): present or not, and pushed as `edit.extras`;
 *   * a face group's reset (LOCKER2_DEFAULTS), the starting faces (`shape`);
 *   * the palettes (LOCKER2_PAL, a `locker2pal`) and a swatch's color
 *     (LOCKER2_COLOR { k, c }); the rows' `pal` and `c`;
 *   * item names (`name`), patchy as the game's shop data is: most tops and
 *     hair, half the legs and shoes, a third of undershirts, no vests, bags
 *     or arms. MADE UP HERE, and only to lay the caption out;
 *   * the arms following the top -- the game's forced-component data -- for
 *     most tops, the Arms row left as the override. Made up too: the real
 *     table is the game's (GET_FORCED_COMPONENT);
 *   * the camera cluster (LOCKER2_CAM), which only bridge/mock.ts's log sees;
 *   * a saved look's name with spaces, and Save's update carrying a name.
 *
 * The numbers of options are roughly the freemode peds' and are not a
 * reference for anything; the palettes are drawn here, not read from the
 * game. `?season=1` in the address puts the harness on Season 1's locker.
 */

import type { CallbackName, Envelope, Locker2Payload, Locker2Row, Locker2Tab, Locker2TatRow } from './types'
import {
  EXTRA_CATS, TATTOOS_PER_ZONE, TATTOO_ZONES, newHistory, record, redoStep, undoStep, wrapStep,
  type History,
} from '../screens/lockerv2/model'

type Emit = (env: Envelope) => void
type Sex = 'm' | 'f'

interface CountDef {
  k: string; cat: string; kind: 'count'; n: [number, number]
  /** Its colors: a texture count per item, a palette, or one. */
  colors: 'tex' | 'hair' | 'makeup' | 'one'
  /** Its first option is none. */
  none?: boolean
}
interface SliderDef { k: string; cat: string; kind: 'slider'; min: number; max: number; def: number }
type Def = CountDef | SliderDef

const count = (k: string, cat: string, n: [number, number], colors: CountDef['colors'], none = false): CountDef =>
  ({ k, cat, kind: 'count', n, colors, ...(none ? { none: true } : {}) })
const opacity = (k: string, cat: string): SliderDef => ({ k: `${k}op`, cat, kind: 'slider', min: 0, max: 100, def: 100 })
const FF = Array.from({ length: 20 }, (_, i): SliderDef => ({
  k: `ff${i}`, cat: 'face', kind: 'slider', min: i >= 18 ? 0 : -100, max: 100, def: 0,
}))

/** The rows, by My Looks' categories (model.ts CORE_CATS and EXTRA_CATS). */
const DEFS: Def[] = [
  count('shape', 'face', [6, 6], 'one'),
  count('e', 'face', [31, 31], 'one'),
  ...FF,
  count('sk', 'skin', [46, 46], 'one'),
  count('o0', 'skin', [25, 25], 'one', true), opacity('o0', 'skin'),
  count('o3', 'skin', [16, 16], 'one', true), opacity('o3', 'skin'),
  count('o6', 'skin', [13, 13], 'one', true), opacity('o6', 'skin'),
  count('o7', 'skin', [12, 12], 'one', true), opacity('o7', 'skin'),
  count('o9', 'skin', [19, 19], 'one', true), opacity('o9', 'skin'),
  count('o11', 'skin', [13, 13], 'one', true), opacity('o11', 'skin'),
  count('o12', 'skin', [3, 3], 'one', true), opacity('o12', 'skin'),
  count('c2', 'hair', [80, 84], 'hair'),
  count('h1', 'hair', [64, 64], 'hair'),
  count('o2', 'hair', [34, 34], 'hair'), opacity('o2', 'hair'),
  count('o1', 'hair', [30, 30], 'hair', true), opacity('o1', 'hair'),
  count('o10', 'hair', [18, 18], 'hair', true), opacity('o10', 'hair'),
  count('c11', 'top', [392, 413], 'tex'),
  count('c8', 'top', [189, 232], 'tex'),
  count('c3', 'top', [196, 241], 'tex'),
  count('c4', 'legs', [161, 175], 'tex'),
  count('c6', 'shoes', [39, 39], 'tex'),
  count('p0', 'hat', [191, 190], 'tex', true),
  count('p1', 'glasses', [51, 53], 'tex', true),
  count('p2', 'earrings', [42, 23], 'tex', true),
  count('c1', 'mask', [204, 204], 'tex', true),
  count('c9', 'vest', [58, 58], 'tex', true),
  count('c5', 'bag', [111, 111], 'tex', true),
  count('p6', 'watch', [44, 34], 'tex', true),
  count('p7', 'bracelet', [9, 17], 'tex', true),
  count('c10', 'decals', [160, 175], 'tex', true),
  count('c7', 'accessory', [161, 128], 'tex', true),
  count('o4', 'makeup', [76, 76], 'makeup', true), opacity('o4', 'makeup'),
  count('o5', 'makeup', [8, 8], 'makeup', true), opacity('o5', 'makeup'),
  count('o8', 'makeup', [11, 11], 'makeup', true), opacity('o8', 'makeup'),
]
const defOf = (k: string) => DEFS.find((d) => d.k === k)

/** A drawable's texture count: made up, but steady for a given option. */
const texOf = (v: number) => ((v * 7) % 5) + 1

// ── the palettes, drawn here (the game's come from GetPed*RgbColor) ─────────
function hex(h: number, s: number, l: number): string {
  const a = s * Math.min(l, 1 - l)
  const f = (n: number) => {
    const k = (n + h / 30) % 12
    const c = l - a * Math.max(-1, Math.min(k - 3, 9 - k, 1))
    return Math.round(c * 255).toString(16).padStart(2, '0')
  }
  return `#${f(0)}${f(8)}${f(4)}`
}
const HAIR_PAL = Array.from({ length: 64 }, (_, i) => {
  if (i < 29) return hex(30 + i * 0.6, 0.35 + i * 0.012, 0.06 + i * 0.022)
  if (i < 38) return hex(8 + (i - 29) * 3, 0.65, 0.22 + (i - 29) * 0.03)
  return hex(((i - 38) * 360) / 26, 0.7, 0.45)
})
const MAKEUP_PAL = Array.from({ length: 64 }, (_, i) => {
  if (i < 24) return hex(340 + i * 1.2, 0.55 + (i % 4) * 0.08, 0.25 + (i % 6) * 0.08)
  if (i < 40) return hex(18 + (i - 24) * 2, 0.45, 0.3 + (i - 24) * 0.025)
  return hex(((i - 40) * 360) / 24, 0.6, 0.45)
})
const NATURAL_HAIR = 29

// ── item names, made up and patchy ──────────────────────────────────────────
const COLOR_WORD = ['Black', 'White', 'Navy', 'Tan', 'Red', 'Olive', 'Gray', 'Blue']
const NOUNS: Record<string, string[]> = {
  c11: ['Hoodie', 'Bomber Jacket', 'Tee', 'Polo Shirt', 'Blazer', 'Puffer Jacket', 'Tank Top', 'Flannel Shirt'],
  c8: ['Undershirt', 'Vest Top', 'Crew Tee'],
  c4: ['Jeans', 'Cargo Pants', 'Shorts', 'Track Pants', 'Chinos'],
  c6: ['Sneakers', 'Boots', 'Loafers', 'High Tops'],
  c2: ['Buzz Cut', 'Faux Hawk', 'Slicked Back', 'Long Waves', 'Bun', 'Braids', 'Mohawk', 'Curly Crop'],
  p0: ['Beanie', 'Snapback', 'Fedora', 'Bucket Hat'],
  p1: ['Aviators', 'Sport Shades', 'Round Glasses'],
  p2: ['Studs', 'Hoops', 'Drops'],
  c1: ['Hockey Mask', 'Bandana', 'Skull Mask'],
  p6: ['Field Watch', 'Gold Watch', 'Digital Watch'],
  p7: ['Chain Bracelet', 'Cuff', 'Bangle'],
  c7: ['Chain', 'Scarf', 'Tie'],
}
/** Whether the made-up shop data names this item: patchy, as the game's is. */
function named(k: string, v: number): boolean {
  switch (k) {
    case 'c11': return v % 4 !== 0
    case 'c2': return v > 1
    case 'c4': case 'c6': return v % 2 === 0
    case 'c8': return v % 3 === 0
    case 'p0': case 'p1': case 'p2': case 'c1': case 'p6': case 'p7': case 'c7': return v % 3 !== 0
    default: return false
  }
}
function nameOf(def: CountDef, v: number, t: number): string | undefined {
  const nouns = NOUNS[def.k]
  if (!nouns || (def.none && v === 1) || !named(def.k, v)) return undefined
  const noun = nouns[v % nouns.length] ?? ''
  return def.colors === 'tex' ? `${COLOR_WORD[t % COLOR_WORD.length]} ${noun}` : noun
}

// ── the look ────────────────────────────────────────────────────────────────
type Look = Record<string, { v: number; t: number }>
/** Everything Undo puts back: the rows, the extras on the look, the tattoos. */
interface Snap { look: Look; extras: string[]; tats: Locker2TatRow[] }
const copySnap = (s: Snap): Snap => ({
  look: Object.fromEntries(Object.entries(s.look).map(([k, x]) => [k, { ...x }])),
  extras: [...s.extras],
  tats: s.tats.map((r) => ({ ...r })),
})
const sameSnap = (a: Snap, b: Snap) => DEFS.every((d) => a.look[d.k]?.v === b.look[d.k]?.v && a.look[d.k]?.t === b.look[d.k]?.t)
  && a.extras.join() === b.extras.join() && a.tats.map((r) => r.i).join() === b.tats.map((r) => r.i).join()

function defaultLook(): Look {
  const out: Look = {}
  for (const d of DEFS) out[d.k] = { v: d.kind === 'slider' ? d.def : 1, t: 0 }
  return out
}

const rand = (lo: number, hi: number) => lo + Math.floor(Math.random() * (hi - lo + 1))
const nOf = (d: CountDef, sex: Sex) => d.n[sex === 'm' ? 0 : 1]

/** An overlay at 1 is none (every one but the eyebrows); a prop or a
 *  component with `none` at 1 is off: no color shows on either. */
const isNone = (d: CountDef, look: Look) => d.none === true && (look[d.k]?.v ?? 1) === 1
const opacityOff = (k: string, look: Look) => {
  const m = /^(o\d+)op$/.exec(k)
  const d = m ? defOf(m[1] ?? '') : undefined
  return d !== undefined && d.kind === 'count' && isNone(d, look)
}
function colorsOf(d: CountDef, look: Look): number {
  if (isNone(d, look)) return 1
  if (d.colors === 'tex') return texOf(look[d.k]?.v ?? 1)
  if (d.colors === 'hair') return HAIR_PAL.length
  if (d.colors === 'makeup') return MAKEUP_PAL.length
  return 1
}

/** THE ARMS FOLLOW THE TOP where the game's data says (made up here: about
 *  nine tops in ten); otherwise they stay as they are. */
const forcedArms = (top: number): number | null => (top % 9 === 0 ? null : ((top * 5) % 16) + 1)
function setTop(look: Look, v: number, t: number) {
  look.c11 = { v, t }
  const arms = forcedArms(v)
  if (arms !== null) look.c3 = { v: arms, t: 0 }
}

function rowsOf(sex: Sex, look: Look): Locker2Row[] {
  return DEFS.map((d): Locker2Row => {
    const cur = look[d.k] ?? { v: 1, t: 0 }
    if (d.kind === 'slider') {
      return {
        k: d.k, cat: d.cat, kind: 'slider', v: cur.v, min: d.min, max: d.max, def: d.def,
        ...(opacityOff(d.k, look) ? { off: true } : {}),
      }
    }
    const pal = d.colors === 'hair' || d.colors === 'makeup' ? d.colors : undefined
    const name = nameOf(d, cur.v, cur.t)
    return {
      k: d.k, cat: d.cat, kind: 'count', v: cur.v, n: nOf(d, sex), colors: colorsOf(d, look),
      ...(name !== undefined ? { name } : {}),
      ...(pal !== undefined ? { pal } : {}),
      ...(pal !== undefined && d.k !== 'h1' ? { c: cur.t } : {}),
    }
  })
}

/** The extras a saved look wears: any of its rows off none, or a tattoo. */
function extrasOf(look: Look, tats: Locker2TatRow[]): string[] {
  return EXTRA_CATS.filter((c) => (c === 'tattoos'
    ? tats.length > 0
    : DEFS.some((d) => d.cat === c && d.kind === 'count' && (look[d.k]?.v ?? 1) > 1)))
}

/** A random item for a count row, with a texture or color of its own. */
function randomRow(look: Look, d: CountDef, sex: Sex, lo = d.none ? 2 : 1) {
  const v = rand(lo, nOf(d, sex))
  const t = d.colors === 'tex' ? rand(0, texOf(v) - 1) : d.colors === 'one' ? 0 : rand(0, NATURAL_HAIR - 1)
  if (d.k === 'c11') setTop(look, v, t)
  else look[d.k] = { v, t }
}

/** RANDOMIZE: the core, and every extra on the look; tattoos are left be. */
function randomize(look: Look, sex: Sex, extras: readonly string[]) {
  look.shape = { v: rand(1, 6), t: 0 }
  look.e = { v: rand(1, 8), t: 0 }
  look.sk = { v: rand(1, 46), t: 0 }
  for (const f of FF) look[f.k] = { v: rand(f.min === 0 ? 0 : -35, 35), t: 0 }
  const hair = rand(0, NATURAL_HAIR - 1)
  look.c2 = { v: rand(2, nOf(defOf('c2') as CountDef, sex)), t: hair }
  look.h1 = { v: rand(0, NATURAL_HAIR - 1) + 1, t: 0 }
  look.o2 = { v: rand(1, 34), t: hair }
  look.o1 = sex === 'm' && Math.random() < 0.5 ? { v: rand(2, 30), t: hair } : { v: 1, t: 0 }
  for (const k of ['c11', 'c8', 'c4', 'c6']) randomRow(look, defOf(k) as CountDef, sex)
  for (const c of extras) {
    for (const d of DEFS) {
      if (d.cat !== c || d.kind !== 'count') continue
      if (c === 'makeup') { look[d.k] = { v: rand(1, nOf(d, sex)), t: rand(0, MAKEUP_PAL.length - 1) }; continue }
      randomRow(look, d, sex)
    }
  }
}

/** The tattoos on a look, held as rows. */
const mockTats = (sex: Sex) => ({
  sex,
  zones: TATTOO_ZONES.map((z, zi) => ({
    z, items: Array.from({ length: sex === 'm' ? 14 : 12 }, (_, n) => ({ i: zi * 20 + n + 1 })),
  })),
})
let tatRowSeq = 0

interface Saved { id: string; name: string; up: number; img?: string; sex: Sex; snap: Snap }

/** A stand-in headshot: a colored square with the look's initial, as webp. */
function fakeShot(name: string, hue: number): string | undefined {
  try {
    const c = document.createElement('canvas')
    c.width = 64
    c.height = 64
    const g = c.getContext('2d')
    if (!g) return undefined
    g.fillStyle = `hsl(${hue}, 45%, 32%)`
    g.fillRect(0, 0, 64, 64)
    g.fillStyle = '#ffffff'
    g.font = 'bold 34px sans-serif'
    g.textAlign = 'center'
    g.textBaseline = 'middle'
    g.fillText(name.slice(0, 1).toUpperCase(), 32, 35)
    return c.toDataURL('image/webp', 0.8)
  } catch {
    return undefined
  }
}

let seq = 0
const newId = () => `${Date.now().toString(36).padStart(9, '0')}${(seq++ % 36).toString(36)}x`

export function createLocker2Mock(stock: { id: string; name: string }[], emit: Emit) {
  const on = !/[?&]season=1\b/.test(window.location.search)

  const saved: Saved[] = []
  let fetching = true
  let seeding = false
  let worn: { k: 's' | 'p'; id: string } | null = { k: 's', id: stock[0]?.id ?? '' }
  let tab: Locker2Tab = 'stock'
  /** The last `seq` of a numbered request seen, echoed as Lua does. */
  let tabSeq: number | null = null
  let loading: string | null = null
  let busy = false
  /** The look being edited. `base` is null for a new one: never saved. */
  let draft: {
    sex: Sex; editing: string | null; base: Snap | null; snap: Snap; cat: string | null; hist: History<Snap>
  } | null = null

  const seedSaved = () => {
    const mk = (name: string, sex: Sex, hue: number, tweak: Look, shot = true): Saved => {
      const look = { ...defaultLook(), ...tweak }
      return {
        id: newId(), name, up: Date.now() - hue * 1000, sex, snap: { look, extras: extrasOf(look, []), tats: [] },
        ...(shot ? { img: fakeShot(name, hue) } : {}),
      }
    }
    saved.push(
      mk('Nightshift', 'm', 200, { c11: { v: 15, t: 0 }, c4: { v: 22, t: 1 }, c6: { v: 12, t: 0 }, c2: { v: 9, t: 3 } }),
      mk('Ranger', 'f', 30, { c11: { v: 40, t: 2 }, p0: { v: 6, t: 0 }, c2: { v: 14, t: 12 } }),
      // No picture stored: the page asks Lua for one, which the harness
      // cannot take, so this card stays plain -- the failure path.
      mk('Ghost Rider', 'm', 300, { c1: { v: 8, t: 0 } }, false),
    )
  }

  const dirty = () => draft !== null && (draft.base === null || !sameSnap(draft.snap, draft.base))

  const state = (): Locker2Payload => ({
    on,
    tab,
    tabSeq,
    stock,
    // No picture on the push, as in Lua: a stored one is sent when asked.
    peds: fetching ? [] : saved.map(({ id, name, up }) => ({ id, name, up })),
    worn,
    loading,
    locked: false,
    busy,
    fetching,
    edit: draft
      ? {
        sex: draft.sex,
        editing: draft.editing,
        dirty: dirty(),
        cat: draft.cat,
        rows: rowsOf(draft.sex, draft.snap.look),
        tats: draft.snap.tats,
        extras: draft.snap.extras,
        undo: draft.hist.past.length > 0,
        redo: draft.hist.future.length > 0,
      }
      : null,
  })
  const push = () => emit({ k: 'locker2', d: state() })
  const homeTab = (): Locker2Tab => (saved.length > 0 ? 'peds' : 'stock')

  /** A change to the draft, recorded first: `key` merges a drag or a hold. */
  const change = (key: string | null, fn: (s: Snap) => void) => {
    if (!draft) return
    draft.hist = record(draft.hist, copySnap(draft.snap), key, Date.now())
    fn(draft.snap)
  }

  const zoneItems = (z: string): number[] =>
    mockTats(draft?.sex ?? 'm').zones.find((x) => x.z === z)?.items.map((t) => t.i) ?? []

  /** Answer one locker2 callback. Returns false for a name it does not own. */
  function handle(name: CallbackName, data: unknown): boolean {
    const d = (data ?? {}) as Record<string, unknown>
    const numbered = () => { if (typeof d.seq === 'number') tabSeq = d.seq }
    switch (name) {
      case 'br/locker2/open':
        tabSeq = null
        draft = null
        tab = homeTab()
        // The fetch takes a moment, so the loading indicator is seen.
        if (fetching && !seeding) {
          seeding = true
          window.setTimeout(() => { seedSaved(); fetching = false; tab = homeTab(); push() }, 900)
        }
        push()
        return true
      case 'br/locker2/close':
        draft = null
        tab = homeTab()
        push()
        return true
      case 'br/locker2/new': {
        numbered()
        const sex: Sex = d.sex === 'f' ? 'f' : 'm'
        const look = defaultLook()
        randomize(look, sex, [])
        tab = sex === 'm' ? 'male' : 'female'
        draft = { sex, editing: null, base: null, snap: { look, extras: [], tats: [] }, cat: null, hist: newHistory() }
        push()
        return true
      }
      case 'br/locker2/edit': {
        numbered()
        const s = saved.find((x) => x.id === d.id)
        if (s && !dirty()) {
          tab = s.sex === 'm' ? 'male' : 'female'
          const snap = copySnap(s.snap)
          snap.tats = snap.tats.map((r) => ({ ...r, r: ++tatRowSeq }))
          draft = { sex: s.sex, editing: s.id, base: copySnap(snap), snap, cat: null, hist: newHistory() }
        }
        push()
        return true
      }
      case 'br/locker2/leave':
        numbered()
        draft = null
        tab = homeTab()
        push()
        return true
      // The old tabs and Reset: My Looks sends neither.
      case 'br/locker2/tab':
      case 'br/locker2/reset':
        push()
        return true
      case 'br/locker2/wear': {
        const k = d.k === 'p' ? 'p' : 's'
        const id = String(d.id ?? '')
        loading = id
        push()
        window.setTimeout(() => { loading = null; worn = { k, id }; push() }, k === 's' ? 600 : 300)
        return true
      }
      case 'br/locker2/step':
      case 'br/locker2/set':
      case 'br/locker2/color': {
        if (!draft) return true
        const k = String(d.k ?? '')
        const def = defOf(k)
        const cur = draft.snap.look[k]
        if (!def || !cur) return true
        const sex = draft.sex
        if (name === 'br/locker2/step' && def.kind === 'count') {
          const v = wrapStep(cur.v, nOf(def, sex), Number(d.d) || 1)
          change(k, (s) => { if (k === 'c11') setTop(s.look, v, 0); else s.look[k] = { v, t: def.colors === 'tex' ? 0 : cur.t } })
        } else if (name === 'br/locker2/set' && !opacityOff(k, draft.snap.look)) {
          const v = Number(d.v)
          if (!Number.isInteger(v)) return true
          // A counter's set puts its color back too, as Lua's reset does.
          change(k, (s) => {
            if (k === 'c11') setTop(s.look, v, 0)
            else s.look[k] = { v, t: def.kind === 'count' && def.colors !== 'one' && k !== 'h1' ? 0 : cur.t }
          })
        } else if (name === 'br/locker2/color' && def.kind === 'count' && !isNone(def, draft.snap.look)) {
          const n = colorsOf(def, draft.snap.look)
          const c = typeof d.c === 'number' ? d.c : (cur.t + 1) % Math.max(1, n)
          if (Number.isInteger(c) && c >= 0 && c < n) change(`${k}:c`, (s) => { s.look[k] = { v: cur.v, t: c } })
        }
        push()
        return true
      }
      case 'br/locker2/cat':
        if (draft && typeof d.cat === 'string' && d.cat !== draft.cat) { draft.cat = d.cat; push() }
        return true
      case 'br/locker2/random':
        if (draft) { const dr = draft; change(null, (s) => randomize(s.look, dr.sex, s.extras)) }
        push()
        return true
      case 'br/locker2/undo':
      case 'br/locker2/redo': {
        if (!draft) return true
        const step = name === 'br/locker2/undo' ? undoStep(draft.hist, copySnap(draft.snap)) : redoStep(draft.hist, copySnap(draft.snap))
        if (step) { draft.hist = step.h; draft.snap = step.value }
        push()
        return true
      }
      case 'br/locker2/extra': {
        const id = String(d.id ?? '')
        if (!draft || !(EXTRA_CATS as readonly string[]).includes(id)) return true
        const add = d.on === true
        if (add === draft.snap.extras.includes(id)) { push(); return true }
        change(null, (s) => {
          if (add) {
            s.extras = EXTRA_CATS.filter((c) => c === id || s.extras.includes(c))
            // An item extra goes on as its first item; Makeup and Tattoos
            // open with nothing on, to be chosen.
            const first = DEFS.find((x) => x.cat === id && x.kind === 'count')
            if (first && id !== 'makeup') s.look[first.k] = { v: 2, t: 0 }
          } else {
            s.extras = s.extras.filter((c) => c !== id)
            for (const x of DEFS) if (x.cat === id) s.look[x.k] = { v: x.kind === 'slider' ? x.def : 1, t: 0 }
            if (id === 'tattoos') s.tats = []
          }
        })
        push()
        return true
      }
      case 'br/locker2/defaults': {
        const ks = Array.isArray(d.ks) ? d.ks.filter((k): k is string => typeof k === 'string') : []
        if (draft) {
          change(null, (s) => {
            for (const k of ks) { const x = defOf(k); if (x?.kind === 'slider') s.look[k] = { v: x.def, t: 0 } }
          })
        }
        push()
        return true
      }
      case 'br/locker2/pal':
        emit({ k: 'locker2pal', d: { hair: HAIR_PAL, makeup: MAKEUP_PAL } })
        return true
      case 'br/locker2/cam':
        // The camera is the game's: bridge/mock.ts has logged the call.
        return true
      case 'br/locker2/save': {
        if (!draft) return true
        busy = true
        push()
        const op = d.op
        const nm = typeof d.name === 'string' ? d.name : ''
        window.setTimeout(() => {
          busy = false
          const dr = draft
          if (!dr) { push(); return }
          const now = Date.now()
          if (op === 'new') {
            const s: Saved = { id: newId(), name: nm, up: now, sex: dr.sex, snap: copySnap(dr.snap), img: fakeShot(nm, (now / 10) % 360) }
            saved.push(s)
            dr.editing = s.id
            dr.base = copySnap(dr.snap)
            worn = { k: 'p', id: s.id }
          } else {
            const s = saved.find((x) => x.id === d.id)
            if (s) {
              s.snap = copySnap(dr.snap)
              s.sex = dr.sex
              s.up = now
              if (nm !== '') s.name = nm
              s.img = fakeShot(s.name, (now / 10) % 360)
              dr.editing = s.id
              dr.base = copySnap(dr.snap)
              worn = { k: 'p', id: s.id }
            }
          }
          push()
        }, 400)
        return true
      }
      case 'br/locker2/rename': {
        const s = saved.find((x) => x.id === d.id)
        if (s) { s.name = String(d.name ?? s.name); push() }
        return true
      }
      case 'br/locker2/delete': {
        const at = saved.findIndex((x) => x.id === d.id)
        if (at >= 0) saved.splice(at, 1)
        if (worn?.k === 'p' && worn.id === d.id) worn = { k: 's', id: stock[0]?.id ?? '' }
        if (!draft) tab = homeTab()
        push()
        return true
      }
      case 'br/locker2/shots': {
        // A stored picture is sent once, on its own, as Lua does. No
        // RegisterPedheadshot in a browser: a card with none stays plain.
        const ids = Array.isArray(d.ids) ? d.ids : []
        for (const s of saved) {
          if (ids.includes(s.id) && s.img) emit({ k: 'locker2shot', d: { id: s.id, up: s.up, img: s.img } })
        }
        return true
      }
      case 'br/locker2/shot':
      case 'br/locker2/shotdone':
        return true
      case 'br/locker2/tats':
        if (d.sex === 'm' || d.sex === 'f') emit({ k: 'locker2tats', d: mockTats(d.sex) })
        return true
      // The tattoo rows, as Lua holds them: 10 a zone, no tattoo in two rows
      // of a zone, a row's choice only one of its zone's.
      case 'br/locker2/tatadd': {
        if (!draft || typeof d.z !== 'string') return true
        const z = d.z
        const rows = draft.snap.tats.filter((x) => x.z === z)
        const pick = zoneItems(z).find((i) => !rows.some((x) => x.i === i))
        if (rows.length < TATTOOS_PER_ZONE && pick !== undefined) {
          change(null, (s) => { s.tats = [...s.tats, { r: ++tatRowSeq, z, i: pick }] })
        }
        push()
        return true
      }
      case 'br/locker2/tatset': {
        const row = draft?.snap.tats.find((x) => x.r === d.r)
        const i = d.i
        if (draft && row && typeof i === 'number' && i !== row.i && zoneItems(row.z).includes(i)
          && !draft.snap.tats.some((x) => x.z === row.z && x.r !== row.r && x.i === i)) {
          change(null, (s) => { s.tats = s.tats.map((x) => (x.r === row.r ? { ...x, i } : x)) })
        }
        push()
        return true
      }
      case 'br/locker2/tatdel': {
        const row = draft?.snap.tats.find((x) => x.r === d.r)
        if (draft && row) change(null, (s) => { s.tats = s.tats.filter((x) => x.r !== row.r) })
        push()
        return true
      }
      default:
        return false
    }
  }

  return { push, handle }
}
