/**
 * LOCKER V2'S DECISIONS (#28), with nothing to render and no runtime imports.
 *
 * Every rule the page applies before it draws -- which tabs exist, which are
 * locked, which way the body slides, which Save the player gets, what a name
 * may hold, what Done does and in which order -- lives here, so
 * scripts/test-lockerv2.mjs can load this file with node's type stripping and
 * hold each rule to the owner's words. The components ask; they never decide.
 *
 * LUA IS THE AUTHORITY. Every callback this page sends is revalidated in
 * br_core (contract section 4), so a rule here is the page agreeing with Lua
 * ahead of the round trip, never the only thing standing between a player and
 * a refused action.
 */

import type {
  Locker2Edit, Locker2Payload, Locker2Ped, Locker2Row, Locker2Worn,
} from '../../bridge/types'

/** The four pages. `peds` is "My peds"; `male` and `female` are the Custom tabs. */
export type Tab = 'peds' | 'stock' | 'male' | 'female'

/** Left to right, as the segmented control draws them. */
export const TAB_ORDER: readonly Tab[] = ['peds', 'stock', 'male', 'female']

export const isCustom = (t: Tab): boolean => t === 'male' || t === 'female'

/**
 * "If they've saved any peds, they should have an additional tab called "My
 * peds"" (owner, #28): the tabs on screen, in order.
 *
 * WHILE THE SAVED PEDS ARE STILL BEING FETCHED, My peds is there too, holding
 * the loading indicator: "We should do a query and show a loading icon while
 * we wait for the results" (owner, 2026-10-07). If the answer is none, it goes.
 */
export function tabsShown(pedCount: number, fetching = false): Tab[] {
  return TAB_ORDER.filter((t) => t !== 'peds' || pedCount > 0 || fetching)
}

/** "The locker opens on My peds if the player has saved peds, otherwise Stock"
 *  (owner's decisions, #28) -- and on My peds while that is not known yet. The
 *  draft is never restored (the skeptic's owner call: close discards it), so
 *  nothing else decides this. */
export function openingTab(pedCount: number, fetching = false): Tab {
  return pedCount > 0 || fetching ? 'peds' : 'stock'
}

/**
 * The slide's direction: d = sign(new - old), by position in TAB_ORDER.
 *
 * "if I'm on the center tab and I click the right tab, the content on the
 * current page would slide out right and the new content would slide in
 * right" (owner, #28). Contract section 5: the old body exits toward +d and
 * the new one enters from -d, so both travel the same way.
 */
export function slideDir(from: Tab, to: Tab): -1 | 0 | 1 {
  const d = TAB_ORDER.indexOf(to) - TAB_ORDER.indexOf(from)
  return d > 0 ? 1 : d < 0 ? -1 : 0
}

/** Where a body starts when it enters and where it goes when it leaves, as a
 *  multiple of the travel distance. */
export function slideEnds(d: -1 | 0 | 1): { enter: number; exit: number } {
  return { enter: -d, exit: d }
}

export interface TabOption {
  id: Tab
  disabled: boolean
  /** True when the reason is unsaved changes, which is the only lock the
   *  owner asked to have explained ("Selecting a disabled tab must show a
   *  hover card explaining why it's disabled"). */
  explained: boolean
}

/**
 * Each tab, and whether it can be pressed.
 *
 * DIRTY LOCKS THE PLAYER TO THEIR TAB: "any non-selected tab must be disabled
 * while unsaved changes are present" (owner, #28). Those carry the hover card.
 *
 * `blocked` (the entrance walk's lock, a stock ped streaming in, or a write in
 * flight) disables every tab with no card: Lua refuses a `tab` then anyway,
 * and a press the page let through would leave it showing a tab Lua never
 * switched to.
 */
export function tabOptions(s: {
  pedCount: number; fetching?: boolean; current: Tab; dirty: boolean; blocked: boolean
}): TabOption[] {
  return tabsShown(s.pedCount, s.fetching === true).map((id) => {
    const other = id !== s.current
    const dirtyLock = s.dirty && other
    return { id, disabled: dirtyLock || (s.blocked && other), explained: dirtyLock }
  })
}

export interface SavedPed { id: string; name: string }

/** The three shapes of Save (contract section 5, with the skeptic's 7). */
export type SaveVariant =
  /** No saved peds and nothing being edited: a plain button that names it. */
  | { kind: 'plain'; enabled: boolean }
  /** Saved peds exist, nothing being edited: Create new, or Replace existing
   *  with every saved ped listed by name. */
  | { kind: 'menu'; enabled: boolean; replace: SavedPed[] }
  /** Editing a saved ped: a split button whose main action updates it, with
   *  Update <name> and Save as new in the menu ("please show a dropdown for
   *  that one and default it to update existing", owner, #28). */
  | { kind: 'split'; enabled: boolean; id: string; name: string }

/** Which Save the player gets. Enabled only while there is something to save. */
export function saveVariant(s: {
  dirty: boolean; editing: string | null; peds: SavedPed[]
}): SaveVariant {
  const enabled = s.dirty
  if (s.editing !== null) {
    const p = s.peds.find((x) => x.id === s.editing)
    // A ped deleted from under the edit (another session, a failed fetch) is
    // a new ped as far as Save is concerned: there is nothing left to update.
    if (p) return { kind: 'split', enabled, id: p.id, name: p.name }
  }
  if (s.peds.length === 0) return { kind: 'plain', enabled }
  return { kind: 'menu', enabled, replace: s.peds.map((p) => ({ id: p.id, name: p.name })) }
}

/** "roman characters and numbers only" (owner, #28), 1 to 24 of them. */
export const NAME_MAX = 24

/** What the name box keeps of a keystroke or a paste: letters A-Z and a-z and
 *  digits 0-9, the first 24 of them. Everything else is dropped as typed. */
export function filterName(raw: string): string {
  return raw.replace(/[^A-Za-z0-9]/g, '').slice(0, NAME_MAX)
}

/** The server's rule, which the page mirrors so Confirm is never lit for a
 *  name Lua would refuse. */
export function nameOk(n: string): boolean {
  return n.length >= 1 && n.length <= NAME_MAX && /^[A-Za-z0-9]+$/.test(n)
}

/** One thing Done (or Escape) does, in order. */
export type DoneStep =
  | { do: 'confirm' }
  | { do: 'close' }
  | { do: 'unfocus' }

/**
 * DONE, IN ORDER (contract section 5): "Clicking "back" should prompt the user
 * about unsaved changes if they've got any" (owner, #28). Dirty and not yet
 * confirmed: the discard prompt, and nothing else. Otherwise `close` first,
 * so Lua discards the draft and restores the worn ped while it still owns the
 * screen, then LOCKER_FOCUS { open: false } to give the cursor back.
 */
export function doneSteps(dirty: boolean, confirmed: boolean): DoneStep[] {
  if (dirty && !confirmed) return [{ do: 'confirm' }]
  return [{ do: 'close' }, { do: 'unfocus' }]
}

/** Escape closes only the open modal (the skeptic's correction 11); with none
 *  open it is Done. */
export function escapeAction(modalOpen: boolean): 'modal' | 'done' {
  return modalOpen ? 'modal' : 'done'
}

/** A counter's text: the 1-based position out of the total, as "12/39". */
export function counterText(v: number, n: number): string {
  return `${v}/${n}`
}

/** One step around a 1-based list of n: 39 then next is 1, and 1 then last is
 *  39 (owner, #28). Lua does this for real; the mock and the tests use it. */
export function wrapStep(v: number, n: number, d: number): number {
  if (n < 1) return 1
  return ((((v - 1 + d) % n) + n) % n) + 1
}

/** The anchor navigation's categories, in the contract's order (section 2). */
export const CAT_ORDER = [
  'face', 'hair', 'makeup', 'skin', 'body', 'headwear',
  'tops', 'vests', 'accessories', 'bags', 'legs', 'shoes',
] as const

/**
 * The categories that have rows, in CAT_ORDER, then any Lua sent that this
 * list does not know, in the order they first appear. A category with no rows
 * is not offered: an anchor that jumps to nothing is a broken anchor.
 */
export function categoriesOf(rows: { cat: string }[]): string[] {
  const present = new Set(rows.map((r) => r.cat))
  const known = CAT_ORDER.filter((c) => present.has(c)) as string[]
  const extra: string[] = []
  for (const r of rows) {
    if (!(CAT_ORDER as readonly string[]).includes(r.cat) && !extra.includes(r.cat)) extra.push(r.cat)
  }
  return [...known, ...extra]
}

/** The id an anchor and its section share. */
export const anchorId = (cat: string): string => `lk2-cat-${cat}`

// ═══ HEADSHOTS (contract section 6, with the skeptic's correction 6) ═══

/** The session cache's key: a ped's image is good until it is saved again. */
export const shotKey = (id: string, up: number): string => `${id}@${up}`

/** Stored headshots are webp, 8 KB at most, as the server stores them. */
export const SHOT_MAX_BYTES = 8192

const IMG_RE = /^data:image\/(webp|png|jpeg);base64,[A-Za-z0-9+/]+={0,2}$/

/** A picture the page will put in an <img>: a base64 data URL of an image
 *  type, and nothing else -- never a URL that could go anywhere. */
export function imgOk(s: unknown): s is string {
  return typeof s === 'string' && s.length < 16384 && IMG_RE.test(s)
}

/** The bytes a base64 data URL decodes to. */
export function dataUrlBytes(url: string): number {
  const i = url.indexOf(',')
  if (i < 0) return Infinity
  const b64 = url.slice(i + 1)
  const pad = b64.endsWith('==') ? 2 : b64.endsWith('=') ? 1 : 0
  return Math.floor((b64.length * 3) / 4) - pad
}

/** True when a shot may go to the server to be stored: webp, within 8 KB. */
export function shotStorable(url: string): boolean {
  return url.startsWith('data:image/webp;base64,') && imgOk(url) && dataUrlBytes(url) <= SHOT_MAX_BYTES
}

/**
 * The saved peds that still need a picture taken: no stored image, none
 * cached this session under its `id@up`, and not already asked for. Asked
 * once and never again: "Any failure leaves a plain card, with no retry."
 */
export function needShots(
  peds: { id: string; up: number; img?: unknown }[],
  cached: ReadonlySet<string>,
  asked: ReadonlySet<string>,
): string[] {
  return peds
    .filter((p) => !imgOk(p.img))
    .filter((p) => !cached.has(shotKey(p.id, p.up)) && !asked.has(shotKey(p.id, p.up)))
    .map((p) => p.id)
}

/**
 * Cloudscape draws in px; the interface is in rem. The locker's Cloudscape
 * island is zoomed so its 14 px body text lands on one rem: root px / 14
 * (contract section 5), which carries the player's interface-size slider
 * with it. Clamped so a missing or absurd root size cannot shrink the screen
 * to nothing.
 */
export function zoomFor(rootPx: number): number {
  if (!Number.isFinite(rootPx) || rootPx <= 0) return 1
  return Math.min(4, Math.max(0.5, rootPx / 14))
}

// ═══ THE ENVELOPE, MADE SAFE TO DRAW ═══

const str = (v: unknown): v is string => typeof v === 'string'
const num = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)
/** A Lua list. AN EMPTY ONE CROSSES THE BRIDGE AS {} (App.tsx's `state`
 *  handler says so), so anything that is not an array is an empty list. */
const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : [])
const obj = (v: unknown): Record<string, unknown> | null =>
  v !== null && typeof v === 'object' && !Array.isArray(v) ? (v as Record<string, unknown>) : null

function row(v: unknown): Locker2Row | null {
  const r = obj(v)
  if (!r || !str(r.k) || !str(r.cat) || !num(r.v)) return null
  if (r.kind === 'count' && num(r.n)) {
    return { k: r.k, cat: r.cat, kind: 'count', v: r.v, n: r.n, colors: num(r.colors) ? r.colors : 1 }
  }
  if (r.kind === 'slider' && num(r.min) && num(r.max)) {
    return {
      k: r.k, cat: r.cat, kind: 'slider', v: r.v, min: r.min, max: r.max,
      def: num(r.def) ? r.def : r.min,
    }
  }
  return null
}

function edit(v: unknown): Locker2Edit | null {
  const e = obj(v)
  if (!e) return null
  return {
    sex: e.sex === 'f' ? 'f' : 'm',
    editing: str(e.editing) && e.editing !== '' ? e.editing : null,
    dirty: e.dirty === true,
    cat: str(e.cat) ? e.cat : 'face',
    rows: list(e.rows).map(row).filter((r): r is Locker2Row => r !== null),
  }
}

/**
 * The `locker2` envelope as the page may draw it: every list an array, every
 * flag a boolean, every row whole. A field Lua left out is its empty value,
 * never `undefined` reaching a component.
 */
export function parseLocker2(raw: unknown): Locker2Payload {
  const d = obj(raw) ?? {}
  const tab = (TAB_ORDER as readonly unknown[]).includes(d.tab) ? (d.tab as Tab) : 'stock'
  const worn = obj(d.worn)
  return {
    on: d.on === true,
    tab,
    stock: list(d.stock).map(obj)
      .filter((p): p is Record<string, unknown> => p !== null && str(p.id) && str(p.name))
      .map((p) => ({ id: p.id as string, name: p.name as string })),
    peds: list(d.peds).map(obj)
      .filter((p): p is Record<string, unknown> => p !== null && str(p.id) && str(p.name))
      .map((p): Locker2Ped => ({
        id: p.id as string,
        name: p.name as string,
        up: num(p.up) ? p.up : 0,
        ...(imgOk(p.img) ? { img: p.img } : {}),
      })),
    worn: worn && (worn.k === 's' || worn.k === 'p') && str(worn.id)
      ? ({ k: worn.k, id: worn.id } as Locker2Worn) : null,
    loading: str(d.loading) ? d.loading : null,
    locked: d.locked === true,
    busy: d.busy === true,
    fetching: d.fetching === true,
    edit: edit(d.edit),
  }
}
