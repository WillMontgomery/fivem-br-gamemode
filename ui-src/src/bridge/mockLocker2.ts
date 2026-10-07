/**
 * LOCKER V2 IN THE BROWSER HARNESS (#28): a stand-in for br_core's
 * client/locker2.lua, so the Season 2 locker can be built and looked at in
 * `npm run dev` with no game behind it.
 *
 * DEV ONLY, like the rest of bridge/mock.ts: production never imports it.
 *
 * It plays Lua's part closely enough to exercise every state the screen
 * draws -- the saved peds arriving after a moment (the loading indicator),
 * both sexes' rows, wrapping counters, Next color, sliders, dirty locking the
 * tabs, every Save shape, rename, delete, the stock loading marker -- and no
 * further. The numbers of options are roughly the freemode peds' and are not
 * a reference for anything.
 *
 * `?season=1` in the address puts the harness on Season 1's locker instead.
 */

import type { CallbackName, Envelope, Locker2Payload, Locker2Row, Locker2Tab } from './types'
import { wrapStep } from '../screens/lockerv2/model'

type Emit = (env: Envelope) => void
type Sex = 'm' | 'f'

interface CountDef { k: string; cat: string; kind: 'count'; n: [number, number]; colors: [number, number] | 'tex'; def?: number }
interface SliderDef { k: string; cat: string; kind: 'slider'; min: number; max: number; def: number }
type Def = CountDef | SliderDef

const FF = Array.from({ length: 20 }, (_, i): SliderDef => ({
  k: `ff${i}`, cat: 'face', kind: 'slider', min: i >= 18 ? 0 : -100, max: 100, def: 0,
}))

/** Contract section 2's rows, with "Next color" wherever there are colors. */
const DEFS: Def[] = [
  { k: 'sk', cat: 'face', kind: 'count', n: [46, 46], colors: [1, 1] },
  { k: 'e', cat: 'face', kind: 'count', n: [31, 31], colors: [1, 1] },
  ...FF,
  { k: 'c2', cat: 'hair', kind: 'count', n: [80, 84], colors: [64, 64] },
  { k: 'h1', cat: 'hair', kind: 'count', n: [64, 64], colors: [1, 1] },
  { k: 'o2', cat: 'hair', kind: 'count', n: [34, 34], colors: [64, 64] },
  { k: 'o2op', cat: 'hair', kind: 'slider', min: 0, max: 100, def: 100 } as SliderDef,
  { k: 'o1', cat: 'hair', kind: 'count', n: [30, 30], colors: [64, 64] },
  { k: 'o1op', cat: 'hair', kind: 'slider', min: 0, max: 100, def: 100 } as SliderDef,
  { k: 'o4', cat: 'makeup', kind: 'count', n: [76, 76], colors: [64, 64] },
  { k: 'o4op', cat: 'makeup', kind: 'slider', min: 0, max: 100, def: 100 } as SliderDef,
  { k: 'o5', cat: 'makeup', kind: 'count', n: [8, 8], colors: [64, 64] },
  { k: 'o5op', cat: 'makeup', kind: 'slider', min: 0, max: 100, def: 100 } as SliderDef,
  { k: 'o8', cat: 'makeup', kind: 'count', n: [11, 11], colors: [64, 64] },
  { k: 'o8op', cat: 'makeup', kind: 'slider', min: 0, max: 100, def: 100 } as SliderDef,
  { k: 'o0', cat: 'skin', kind: 'count', n: [25, 25], colors: [1, 1] },
  { k: 'o3', cat: 'skin', kind: 'count', n: [16, 16], colors: [1, 1] },
  { k: 'o6', cat: 'skin', kind: 'count', n: [13, 13], colors: [1, 1] },
  { k: 'o7', cat: 'skin', kind: 'count', n: [12, 12], colors: [1, 1] },
  { k: 'o9', cat: 'skin', kind: 'count', n: [19, 19], colors: [1, 1] },
  { k: 'o11', cat: 'body', kind: 'count', n: [13, 13], colors: [1, 1] },
  { k: 'o12', cat: 'body', kind: 'count', n: [3, 3], colors: [1, 1] },
  { k: 'o10', cat: 'body', kind: 'count', n: [18, 18], colors: [64, 64] },
  { k: 'p0', cat: 'headwear', kind: 'count', n: [191, 190], colors: 'tex' },
  { k: 'p1', cat: 'headwear', kind: 'count', n: [51, 53], colors: 'tex' },
  { k: 'p2', cat: 'headwear', kind: 'count', n: [42, 23], colors: 'tex' },
  { k: 'c1', cat: 'headwear', kind: 'count', n: [204, 204], colors: 'tex' },
  { k: 'c11', cat: 'tops', kind: 'count', n: [392, 413], colors: 'tex' },
  { k: 'c8', cat: 'tops', kind: 'count', n: [189, 232], colors: 'tex' },
  { k: 'c3', cat: 'tops', kind: 'count', n: [196, 241], colors: 'tex' },
  { k: 'c9', cat: 'vests', kind: 'count', n: [58, 58], colors: 'tex' },
  { k: 'c10', cat: 'vests', kind: 'count', n: [160, 175], colors: 'tex' },
  { k: 'c7', cat: 'accessories', kind: 'count', n: [161, 128], colors: 'tex' },
  { k: 'p6', cat: 'accessories', kind: 'count', n: [44, 34], colors: 'tex' },
  { k: 'p7', cat: 'accessories', kind: 'count', n: [9, 17], colors: 'tex' },
  { k: 'c5', cat: 'bags', kind: 'count', n: [111, 111], colors: 'tex' },
  { k: 'c4', cat: 'legs', kind: 'count', n: [161, 175], colors: 'tex' },
  { k: 'c6', cat: 'shoes', kind: 'count', n: [39, 39], colors: 'tex' },
]

/** A drawable's texture count: made up, but steady for a given option. */
const texOf = (v: number) => ((v * 7) % 5) + 1

type Look = Record<string, { v: number; t: number }>

function defaultLook(): Look {
  const out: Look = {}
  for (const d of DEFS) out[d.k] = { v: d.kind === 'slider' ? d.def : (d.def ?? 1), t: 0 }
  return out
}

/** An overlay row at 1 is none (every overlay but the eyebrows, as in Lua):
 *  no Next color, and its opacity slider is off. */
const noneOverlay = (k: string, look: Look) => /^o\d+$/.test(k) && k !== 'o2' && (look[k]?.v ?? 1) === 1
const opacityOff = (k: string, look: Look) => {
  const m = /^(o\d+)op$/.exec(k)
  return m !== null && noneOverlay(m[1] ?? '', look)
}

function rowsOf(sex: Sex, look: Look): Locker2Row[] {
  const i = sex === 'm' ? 0 : 1
  return DEFS.map((d): Locker2Row => {
    const cur = look[d.k] ?? { v: 1, t: 0 }
    if (d.kind === 'slider') {
      return {
        k: d.k, cat: d.cat, kind: 'slider', v: cur.v, min: d.min, max: d.max, def: d.def,
        ...(opacityOff(d.k, look) ? { off: true } : {}),
      }
    }
    const colors = noneOverlay(d.k, look) ? 1 : d.colors === 'tex' ? texOf(cur.v) : d.colors[i]
    return { k: d.k, cat: d.cat, kind: 'count', v: cur.v, n: d.n[i], colors }
  })
}

const same = (a: Look, b: Look) => DEFS.every((d) => a[d.k]?.v === b[d.k]?.v && a[d.k]?.t === b[d.k]?.t)

interface Saved { id: string; name: string; up: number; img?: string; sex: Sex; look: Look }

/** A stand-in headshot: a colored square with the ped's initial, as webp. */
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
  /** The last `seq` of a tab request seen, echoed as Lua does. */
  let tabSeq: number | null = null
  let loading: string | null = null
  let busy = false
  // The draft: what a Custom tab is showing.
  let draft: { sex: Sex; editing: string | null; base: Look; look: Look; cat: string | null } | null = null

  const seedSaved = () => {
    const mk = (name: string, sex: Sex, hue: number, tweak: Partial<Look>, shot = true): Saved => {
      const look = { ...defaultLook(), ...tweak } as Look
      return { id: newId(), name, up: Date.now() - hue * 1000, sex, look, ...(shot ? { img: fakeShot(name, hue) } : {}) }
    }
    saved.push(
      mk('Nightshift', 'm', 200, { c11: { v: 15, t: 0 }, c4: { v: 22, t: 1 }, c6: { v: 12, t: 0 } }),
      mk('Ranger', 'f', 30, { c11: { v: 40, t: 2 }, p0: { v: 6, t: 0 } }),
      // No picture stored: the page asks Lua for one, which the harness
      // cannot take, so this card stays plain -- the failure path.
      mk('Ghost42', 'm', 300, { c1: { v: 8, t: 0 } }, false),
    )
  }

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
    edit: draft && (tab === 'male' || tab === 'female')
      ? {
        sex: draft.sex,
        editing: draft.editing,
        dirty: !same(draft.look, draft.base),
        cat: draft.cat,
        rows: rowsOf(draft.sex, draft.look),
      }
      : null,
  })
  const push = () => emit({ k: 'locker2', d: state() })

  const startDraft = (sex: Sex, from: Saved | null) => {
    const base = from ? { ...from.look } : defaultLook()
    // No category, the camera home, as Lua starts a draft.
    draft = { sex, editing: from?.id ?? null, base, look: { ...base }, cat: null }
  }

  /** Answer one locker2 callback. Returns false for a name it does not own. */
  function handle(name: CallbackName, data: unknown): boolean {
    const d = (data ?? {}) as Record<string, unknown>
    switch (name) {
      case 'br/locker2/open':
        tabSeq = null
        // The fetch takes a moment, so the loading indicator is seen.
        if (fetching && !seeding) {
          seeding = true
          window.setTimeout(() => { seedSaved(); fetching = false; push() }, 900)
        }
        push()
        return true
      case 'br/locker2/close':
        draft = null
        tab = 'stock'
        push()
        return true
      case 'br/locker2/tab': {
        const t = d.tab as Locker2Tab
        if (typeof d.seq === 'number') tabSeq = d.seq
        // Refused while dirty -- and, as in Lua, answered with the tab it keeps.
        if (draft && !same(draft.look, draft.base) && t !== tab) { push(); return true }
        tab = t
        if (t === 'male' || t === 'female') startDraft(t === 'male' ? 'm' : 'f', null)
        else draft = null
        push()
        return true
      }
      case 'br/locker2/wear': {
        const k = d.k === 'p' ? 'p' : 's'
        const id = String(d.id ?? '')
        if (k === 's') {
          loading = id
          push()
          window.setTimeout(() => { loading = null; worn = { k, id }; push() }, 600)
        } else {
          worn = { k, id }
          push()
        }
        return true
      }
      case 'br/locker2/step':
      case 'br/locker2/set':
      case 'br/locker2/color': {
        if (!draft) return true
        const k = String(d.k ?? '')
        const def = DEFS.find((x) => x.k === k)
        const cur = draft.look[k]
        if (!def || !cur) return true
        const i = draft.sex === 'm' ? 0 : 1
        if (name === 'br/locker2/step' && def.kind === 'count') {
          draft.look[k] = { v: wrapStep(cur.v, def.n[i], Number(d.d) || 1), t: 0 }
        } else if (name === 'br/locker2/set' && !opacityOff(k, draft.look)) {
          draft.look[k] = { v: Number(d.v), t: def.kind === 'count' ? 0 : cur.t }
        } else if (name === 'br/locker2/color' && def.kind === 'count' && !noneOverlay(k, draft.look)) {
          const colors = def.colors === 'tex' ? texOf(cur.v) : def.colors[i]
          draft.look[k] = { v: cur.v, t: (cur.t + 1) % Math.max(1, colors) }
        }
        push()
        return true
      }
      case 'br/locker2/cat':
        if (draft && typeof d.cat === 'string' && d.cat !== draft.cat) { draft.cat = d.cat; push() }
        return true
      case 'br/locker2/reset':
        if (draft) { draft.look = { ...draft.base }; push() }
        return true
      case 'br/locker2/save': {
        if (!draft) return true
        busy = true
        push()
        const op = d.op
        window.setTimeout(() => {
          busy = false
          const now = Date.now()
          if (op === 'new') {
            const nm = String(d.name ?? '')
            const s: Saved = { id: newId(), name: nm, up: now, sex: draft!.sex, look: { ...draft!.look }, img: fakeShot(nm, (now / 10) % 360) }
            saved.push(s)
            draft = { ...draft!, editing: s.id, base: { ...draft!.look } }
            worn = { k: 'p', id: s.id }
          } else {
            const s = saved.find((x) => x.id === d.id)
            if (s) {
              s.look = { ...draft!.look }
              s.sex = draft!.sex
              s.up = now
              s.img = fakeShot(s.name, (now / 10) % 360)
              draft = { ...draft!, editing: s.id, base: { ...draft!.look } }
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
        if (saved.length === 0 && tab === 'peds') tab = 'stock'
        push()
        return true
      }
      case 'br/locker2/edit': {
        const s = saved.find((x) => x.id === d.id)
        if (s) {
          tab = s.sex === 'm' ? 'male' : 'female'
          startDraft(s.sex, s)
          push()
        }
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
      default:
        return false
    }
  }

  return { push, handle }
}
