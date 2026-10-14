/**
 * LOCKER V2'S DECISIONS (#28), with nothing to render and no runtime imports.
 *
 * Every rule the page applies before it draws -- which view it is on, what
 * Back and Escape do and in which order, what a name may hold, which save a
 * dialog makes, which categories the editor lists and what "Add more" offers,
 * how a held arrow repeats, what a swatch sends, how a draft's history steps
 * -- lives here, so scripts/test-lockerv2.mjs can load this file with node's
 * type stripping and hold each rule to the owner's words. The components ask;
 * they never decide.
 *
 * LUA IS THE AUTHORITY. Every callback this page sends is revalidated in
 * br_core (contract section 4), so a rule here is the page agreeing with Lua
 * ahead of the round trip, never the only thing standing between a player and
 * a refused action. The history rules (record/undoStep/redoStep) are the one
 * piece the page does not run itself: Lua holds the draft, so Lua holds its
 * history -- the browser harness (bridge/mockLocker2.ts) runs these, and the
 * wiring round mirrors them in Lua.
 */

import type {
  Locker2CountRow, Locker2Edit, Locker2PalName, Locker2PalPayload, Locker2Payload, Locker2Ped, Locker2Row,
  Locker2TatRow, Locker2Tattoo, Locker2TatsPayload, Locker2Tab, Locker2Worn,
} from '../../bridge/types'

// ═══ THE VIEWS (owner, 2026-10-12: "let's get rid of the top left/right
// select bar, and move to a new flow") ═══

/**
 * `home` is My Looks (the saved looks as cards), `new` the two cards Custom
 * and Stock GTA Looks, `stock` the stock roster, `edit` the editor.
 */
export type View = 'home' | 'new' | 'stock' | 'edit'

/**
 * THE VIEW SHOWN, ONCE LUA HAS ANSWERED. The page moves on the press -- to
 * the editor for New and Edit, home for Back -- and numbers each request that
 * starts or ends a draft (LOCKER2_NEW, _EDIT, _LEAVE). Lua echoes the last one
 * it has seen (`tabSeq`). Once that is the page's latest, Lua's draft is the
 * truth: a draft up is the editor; none, and the page leaves the editor for
 * home (a New Lua refused). Until then a push is older than the press and the
 * page keeps what it shows.
 */
export function followView(shown: View, hasDraft: boolean, luaSeq: number | null, sent: number): View {
  if (luaSeq === null || luaSeq !== sent) return shown
  if (hasDraft) return 'edit'
  return shown === 'edit' ? 'home' : shown
}

/**
 * NEW'S TWO CARDS (owner, 2026-10-14: "when I click "custom" or "stock gta
 * looks" it should have a create button, or not have either card selected by
 * default ... we need to fix that"). A press on a card only SELECTS it --
 * Custom is selected as the view opens -- and Create goes on with the one
 * selected: a new custom look of the body its dropdown shows (LOCKER2_NEW),
 * or the stock roster.
 */
export type NewPick = 'custom' | 'stock'
export const NEW_DEFAULT: NewPick = 'custom'

export function createStep(pick: NewPick): { do: 'new' } | { do: 'view'; to: View } {
  return pick === 'stock' ? { do: 'view', to: 'stock' } : { do: 'new' }
}

/** One thing Back (or Done, or Escape) does, in order. */
export type BackStep =
  | { do: 'confirm' }
  | { do: 'leave' }
  | { do: 'view'; to: View }
  | { do: 'close' }
  | { do: 'unfocus' }

/**
 * BACK, ONE LEVEL UP. In the editor: "Back asks if unsaved" (owner) -- the
 * discard prompt and nothing else, then once confirmed (or with nothing to
 * lose) LOCKER2_LEAVE, which drops the draft and wears the worn look again.
 * Stock GTA Looks goes back to New, New to My Looks, and My Looks is Done:
 * `close` first, so Lua puts the worn look back while it still owns the
 * screen, then LOCKER_FOCUS { open: false } to give the cursor back.
 */
export function backSteps(view: View, dirty: boolean, confirmed: boolean): BackStep[] {
  switch (view) {
    case 'edit': return dirty && !confirmed ? [{ do: 'confirm' }] : [{ do: 'leave' }]
    case 'stock': return [{ do: 'view', to: 'new' }]
    case 'new': return [{ do: 'view', to: 'home' }]
    default: return [{ do: 'close' }, { do: 'unfocus' }]
  }
}

/**
 * ESCAPE. An open dropdown has it first ('pass': the page leaves the key alone
 * and the dropdown closes itself -- a tattoo or zone picker and a card's "..."
 * menu are Cloudscape's, "Add more"'s menu is the editor's own); then an open
 * dialog closes alone; then it is the view's Back. A walkthrough
 * card waiting on the locker (#405) holds only the CLOSING: on My Looks Escape
 * is nothing, and the card's Done is the way out; inside, Back still works.
 */
export function escapeAction(
  view: View, modalOpen: boolean, held = false, popupOpen = false,
): 'pass' | 'modal' | 'back' | 'none' {
  if (popupOpen) return 'pass'
  if (modalOpen) return 'modal'
  if (view === 'home' && held) return 'none'
  return 'back'
}

/** An open Cloudscape dropdown, by its trigger: a Select's and a
 *  ButtonDropdown's are buttons with aria-haspopup, and aria-expanded="true"
 *  while open (test-lockerv2.mjs holds the installed Cloudscape to that). A
 *  button: a Select's filter is an input that says aria-expanded="true"
 *  always, and stays in the page once its picker has opened. */
export const OPEN_POPUP = 'button[aria-haspopup][aria-expanded="true"]'

/** Is a dropdown open anywhere under `root` (the screen)? */
export const popupOpen = (root: ParentNode | null): boolean =>
  root !== null && root.querySelector(OPEN_POPUP) !== null

// ═══ NAMES (owner, 2026-10-12: "we need to allow spaces in the ped names") ═══

/** 1 to 24 characters. */
export const NAME_MAX = 24

/**
 * What the name box keeps of a keystroke or a paste: letters A-Z and a-z,
 * digits 0-9 and spaces -- no space first, never two together -- the first 24
 * of them. A space last is kept while typing, so a second word can follow it;
 * cleanName takes it off when the name is used.
 */
export function filterName(raw: string): string {
  return raw.replace(/[^A-Za-z0-9 ]/g, '').replace(/ {2,}/g, ' ').replace(/^ +/, '').slice(0, NAME_MAX)
}

/** The name as it is saved: the ends trimmed, doubled spaces made one. */
export function cleanName(raw: string): string {
  return raw.replace(/\s+/g, ' ').trim()
}

/** The server's rule, which the page mirrors so a dialog's confirm is never
 *  lit for a name Lua would refuse: words of letters and digits, one space
 *  between them, 1 to 24 in all. */
export function nameOk(n: string): boolean {
  return n.length >= 1 && n.length <= NAME_MAX && /^[A-Za-z0-9]+( [A-Za-z0-9]+)*$/.test(n)
}

// ═══ SAVING: Save updates an existing look, and "Save as new" lives in the
// save dialog -- the save flow the owner agreed on 2026-10-13 ═══

export interface SavedLook { id: string; name: string }

/**
 * The dialog Save opens. A new look is named, and has Save alone. A saved one
 * shows its name with Save (update) -- and "Save as new" only when the player
 * opened it from My Looks with Edit (owner, 2026-10-14: "say I create a new
 * look and save it - why do I have save and save as new?"): a look made in
 * this editor and saved once is still his new look, and Save keeps updating
 * it. A look deleted from under the edit is a new look again: there is
 * nothing left to update.
 */
export type SaveDialog = { kind: 'name' } | { kind: 'save'; id: string; name: string; asNew: boolean }

export function saveDialogFor(editing: string | null, peds: readonly SavedLook[], opened: boolean): SaveDialog {
  const p = editing !== null ? peds.find((x) => x.id === editing) : undefined
  return p ? { kind: 'save', id: p.id, name: p.name, asNew: opened } : { kind: 'name' }
}

/** Save is lit for a new look always (it has never been saved), for a saved
 *  one only while it has changes -- and never while a write is in flight. */
export function saveEnabled(editing: string | null, dirty: boolean, busy: boolean): boolean {
  return !busy && (editing === null || dirty)
}

/** What the dialog's two saves send (LOCKER2_SAVE): the name cleaned, an
 *  update by its id, a new look by name. A `name` dialog only ever saves new. */
export function saveRequest(
  d: SaveDialog, choice: 'update' | 'new', typed: string,
): { op: 'new'; name: string } | { op: 'update'; id: string; name: string } {
  const name = cleanName(typed)
  if (d.kind === 'save' && choice === 'update') return { op: 'update', id: d.id, name }
  return { op: 'new', name }
}

// ═══ THE EDITOR'S CATEGORIES (owner, 2026-10-13: "presented with a choice to
// add customizations for each category") ═══

/**
 * ALWAYS ON THE LOOK, in the summary list's order, and randomized when a new
 * custom look opens. Today's rows map onto them so:
 *   face   the starting face (`shape`, new), the eyes, the 20 face features
 *          behind "Fine-tune"
 *   skin   the skin tone, then the skin's overlays -- blemishes, aging,
 *          complexion, sun damage, moles, and the body's two blemish rows
 *   hair   the hair (its color and highlight as swatches), eyebrows, facial
 *          hair and chest hair, each with its color and opacity
 *   top    top, undershirt and arms (the arms follow the top where the game
 *          says so; the row stays as an override)
 *   legs, shoes
 */
export const CORE_CATS = ['face', 'skin', 'hair', 'top', 'legs', 'shoes'] as const

/**
 * ABSENT UNTIL ADDED, from the one "Add more" menu at the foot of the list,
 * each with a trash icon to take it off again: today's optional rows, one
 * extra each, and Makeup (makeup, blush, lipstick) and Tattoos as groups.
 */
export const EXTRA_CATS = [
  'hat', 'glasses', 'earrings', 'mask', 'vest', 'bag', 'watch', 'bracelet', 'decals', 'accessory', 'makeup',
  'tattoos',
] as const

const isKnownExtra = (c: unknown): c is string => (EXTRA_CATS as readonly unknown[]).includes(c)

/**
 * The extras on a look IN THE ORDER THEY WERE PUT ON (owner, 2026-10-14:
 * "cards should be added in the list in the order the player adds them:
 * adding earrings after adding tattoos should not show tattoos on the bottom
 * of the list"): Lua's order, kept -- an extra this page does not know, or
 * one named twice, left out.
 */
export function orderedExtras(raw: readonly unknown[]): string[] {
  const out: string[] = []
  for (const c of raw) if (isKnownExtra(c) && !out.includes(c)) out.push(c)
  return out
}

/** The summary list: the core, then the extras on the look in the order they
 *  were put on. */
export function listedCats(extras: readonly string[]): string[] {
  return [...CORE_CATS, ...orderedExtras(extras)]
}

/** "Add more"'s list: every extra not on the look, in EXTRA_CATS's order.
 *  Empty, it is off. */
export function addableExtras(extras: readonly string[]): string[] {
  return EXTRA_CATS.filter((c) => !extras.includes(c))
}

export const isExtra = (cat: string): boolean => (EXTRA_CATS as readonly string[]).includes(cat)

/** The panel a camera category belongs to: a tattoo zone's is Tattoos'. */
export function panelOf(cat: string | null): string | null {
  if (cat === null) return null
  return cat.startsWith('tat_') ? TATTOOS_CAT : cat
}

/** The row a category's summary line reads. */
export const PRIMARY_ROW: Readonly<Record<string, string>> = {
  face: 'shape', skin: 'sk', hair: 'c2', top: 'c11', legs: 'c4', shoes: 'c6',
  hat: 'p0', glasses: 'p1', earrings: 'p2', mask: 'c1', vest: 'c9', bag: 'c5', watch: 'p6', bracelet: 'p7',
  decals: 'c10', accessory: 'c7', makeup: 'o4',
}

/**
 * ITEM NAMES, ALL OR NOTHING (owner, 2026-10-14: "seems you don't have names
 * for everything that shows on the cards, such as tops which shows 24/392 or
 * "black tee" for 26/392. All or nothing on that."). The game names some
 * items and not others -- tops about three in four, legs half, bags none --
 * so no category shows names: every summary line and every row is the item's
 * place in its list. A category put in this set shows the game's name for its
 * item wherever Lua sends one (`name`), on its summary line and under its
 * counter -- the switch for a category whose names turn out to be whole.
 */
export const NAMED_CATS: ReadonlySet<string> = new Set<string>()

/** The game's name for a row's item, where its category shows names. */
export const nameShown = (r: Locker2CountRow): string | null =>
  NAMED_CATS.has(r.cat) && r.name !== undefined ? r.name : null

/** One summary line's right-hand side: the item's place in its list
 *  (`12/80`); a color chip where the item wears a palette color; Tattoos,
 *  how many. */
export interface Summary { text: string; chip: { pal: Locker2PalName; i: number } | null }

export function summaryOf(cat: string, rows: readonly Locker2Row[], tatCount: number): Summary {
  if (cat === TATTOOS_CAT) return { text: String(tatCount), chip: null }
  const k = PRIMARY_ROW[cat]
  const r = rows.find((x) => x.k === k)
  if (!r || r.kind !== 'count') return { text: '', chip: null }
  const i = swatchOf(r)
  return {
    text: nameShown(r) ?? counterText(r.v, r.n),
    chip: r.pal !== undefined && i !== null && swatchesShown(r) ? { pal: r.pal, i } : null,
  }
}

/** The face features, grouped "by what the existing face features are", one
 *  reset each (owner, 2026-10-13), in the order drawn under "Fine-tune". */
export const FACE_GROUPS: readonly { id: string; ks: readonly string[] }[] = [
  { id: 'nose', ks: ['ff0', 'ff1', 'ff2', 'ff3', 'ff4', 'ff5'] },
  { id: 'brows', ks: ['ff6', 'ff7'] },
  { id: 'cheeks', ks: ['ff8', 'ff9', 'ff10'] },
  { id: 'eyeslips', ks: ['ff11', 'ff12'] },
  { id: 'jaw', ks: ['ff13', 'ff14'] },
  { id: 'chin', ks: ['ff15', 'ff16', 'ff17', 'ff18'] },
  { id: 'neck', ks: ['ff19'] },
]

/** A group's reset is lit while any of its sliders is off its default. */
export function groupMoved(rows: readonly Locker2Row[], ks: readonly string[]): boolean {
  return rows.some((r) => r.kind === 'slider' && ks.includes(r.k) && r.v !== r.def)
}

/** The rows a category's panel draws, in Lua's order -- the face's features
 *  only behind "Fine-tune", and never the starting face, which is drawn as
 *  its own tiles. */
export function panelRows(rows: readonly Locker2Row[], cat: string): Locker2Row[] {
  return rows.filter((r) => r.cat === cat && r.k !== 'shape' && !/^ff\d+$/.test(r.k))
}

// ═══ COLORS (owner's point 1: "hair and makeup colors as a swatch grid
// instead of Next color") ═══

/** The color a palette row wears, 0-based: the highlight's own value, else
 *  the row's `c`; null when it has none. */
export function swatchOf(r: Locker2CountRow): number | null {
  if (r.pal === undefined) return null
  if (r.k === 'h1') return r.v - 1
  return typeof r.c === 'number' ? r.c : null
}

/** A row draws its swatch grid when it has a palette and a color shows: the
 *  highlight always, an item while it has more than one color (an overlay of
 *  none has one, and its color shows on nothing). */
export const swatchesShown = (r: Locker2CountRow): boolean =>
  r.pal !== undefined && (r.k === 'h1' || r.colors > 1)

/**
 * AN ITEM'S OWN COLORS -- its textures -- are a swatch button, not "Next
 * color" (owner, 2026-10-14: "any button showing "next color" should have a
 * button for a color swatch instead"): the button wears the color on, and
 * opens the item's colors as a grid of its own. Drawn for a row with more
 * than one color and no palette.
 */
export const texturesShown = (r: Locker2CountRow): boolean => r.pal === undefined && r.colors > 1

/** The texture worn, 0-based: the row's `c`, else the first. */
export const textureOf = (r: Locker2CountRow): number =>
  typeof r.c === 'number' && r.c < r.colors ? r.c : 0

/**
 * What a texture swatch shows: its color where Lua sends the item's colors
 * (`sw`, one `#rrggbb` a texture), else its place among them -- the game has
 * no color for a texture, only its picture.
 */
export function textureFace(r: Locker2CountRow, i: number): { color: string } | { n: number } {
  const c = r.sw?.[i]
  return c !== undefined ? { color: c } : { n: i + 1 }
}

/** A texture swatch's press: LOCKER2_COLOR { k, c }, `c` 0-based. */
export const textureRequest = (r: Locker2CountRow, i: number): { k: string; c: number } => ({ k: r.k, c: i })

/** What a swatch press sends: the highlight is a row of colors, set by its
 *  1-based place (LOCKER2_SET); any other row's color is set by index
 *  (LOCKER2_COLOR { k, c }). */
export function swatchRequest(r: Locker2CountRow, i: number):
  { cb: 'set'; data: { k: string; v: number } } | { cb: 'color'; data: { k: string; c: number } } {
  return r.k === 'h1' ? { cb: 'set', data: { k: r.k, v: i + 1 } } : { cb: 'color', data: { k: r.k, c: i } }
}

const HEX = /^#[0-9a-fA-F]{6}$/
/** The palettes as the page may draw them: `#rrggbb` strings only, 64 at most
 *  each; anything else is no palette. */
export function parsePal(raw: unknown): Locker2PalPayload | null {
  const d = obj(raw)
  if (!d) return null
  const pal = (v: unknown) => list(v).filter((c): c is string => typeof c === 'string' && HEX.test(c)).slice(0, 64)
  const out = { hair: pal(d.hair), makeup: pal(d.makeup) }
  return out.hair.length > 0 || out.makeup.length > 0 ? out : null
}

// ═══ HOLD TO SCROLL (owner's point 1: "next/last stays, with hold-to-scroll") ═══

/** A held arrow steps once on the press, waits HOLD_FIRST_MS, then repeats --
 *  first every HOLD_START_MS, each repeat HOLD_ACCEL of the one before, never
 *  quicker than HOLD_MIN_MS (Lua applies each step; twenty a second is the
 *  slider's own pace). */
export const HOLD_FIRST_MS = 400
export const HOLD_START_MS = 160
export const HOLD_ACCEL = 0.85
export const HOLD_MIN_MS = 50

/** How long before the nth repeat (n >= 1) of a held arrow. */
export function holdDelay(n: number): number {
  if (n <= 1) return HOLD_FIRST_MS
  return Math.max(HOLD_MIN_MS, Math.round(HOLD_START_MS * HOLD_ACCEL ** (n - 2)))
}

/** How many steps a hold of `ms` makes, the press's own included. */
export function holdSteps(ms: number): number {
  let n = 1
  let t = 0
  for (;;) {
    t += holdDelay(n)
    if (t > ms) return n
    n++
  }
}

/** A held rotate button turns the look this many degrees a tick, every
 *  SPIN_TICK_MS (LOCKER_SPIN); one press turns it SPIN_STEP. */
export const SPIN_TICK_MS = 33
export const SPIN_TICK = 4
export const SPIN_STEP = 22.5

// ═══ THE DRAFT'S HISTORY (Undo / Redo: "yes", owner, 2026-10-13) ═══
//
// Lua holds it, as it holds the draft. Each change records the look as it was
// before; Undo puts that back and keeps the present for Redo; a new change
// clears Redo. A slider's drag (a set every 60 ms) and a held arrow (a step
// per repeat) are one change: touches of the same row closer than
// COALESCE_MS record nothing new.

export interface History<T> { past: T[]; future: T[]; key: string | null; at: number }
export const HISTORY_MAX = 50
export const COALESCE_MS = 800

export const newHistory = <T>(): History<T> => ({ past: [], future: [], key: null, at: 0 })

/** A change is about to be made to the look `before`, by row `key` (null for
 *  one that is never merged: Randomize, an extra, a group's reset). */
export function record<T>(h: History<T>, before: T, key: string | null, now: number): History<T> {
  if (key !== null && key === h.key && now - h.at < COALESCE_MS) return { ...h, at: now }
  return { past: [...h.past, before].slice(-HISTORY_MAX), future: [], key, at: now }
}

/** Undo: the last look before, with `current` kept for Redo; null with none. */
export function undoStep<T>(h: History<T>, current: T): { h: History<T>; value: T } | null {
  const value = h.past[h.past.length - 1]
  if (value === undefined) return null
  return { h: { past: h.past.slice(0, -1), future: [...h.future, current], key: null, at: 0 }, value }
}

/** Redo: the look Undo left, with `current` back on the past; null with none. */
export function redoStep<T>(h: History<T>, current: T): { h: History<T>; value: T } | null {
  const value = h.future[h.future.length - 1]
  if (value === undefined) return null
  return { h: { past: [...h.past, current], future: h.future.slice(0, -1), key: null, at: 0 }, value }
}

// ═══ PUSHES THAT CHANGE LITTLE (the lag report, cause 3) ═══

/**
 * `next` with every part that equals `prev`'s replaced BY `prev`'s, so a push
 * that changed one row hands every other row, list and look back as the same
 * object -- and a component that reads one of them, or is memoized on it,
 * does not draw again. Plain objects and arrays only; anything else is taken
 * from `next`.
 */
export function share<T>(prev: T, next: T): T {
  if (Object.is(prev, next)) return prev
  if (Array.isArray(prev) && Array.isArray(next)) {
    let same = prev.length === next.length
    const out = next.map((v, i) => {
      const s = share(prev[i], v)
      if (!Object.is(s, prev[i])) same = false
      return s
    })
    return (same ? prev : out) as T
  }
  const a = obj(prev)
  const b = obj(next)
  if (!a || !b) return next
  const keys = Object.keys(b)
  let same = keys.length === Object.keys(a).length
  const out: Record<string, unknown> = {}
  for (const k of keys) {
    const s = share(a[k], b[k])
    if (!Object.is(s, a[k]) || !(k in a)) same = false
    out[k] = s
  }
  return (same ? prev : out) as T
}

// ═══ ROWS ═══

/** How long after the last touch a slider shows its own value rather than
 *  Lua's: long enough for a drag's echoes, short enough that a set Lua
 *  refused shows Lua's value again. */
export const SLIDER_HOLD_MS = 400

/**
 * A slider's value on screen. The page applies a drag on the handle before
 * Lua answers it (#28 review's class: every action applied locally first), so
 * it shows its own value while it is being touched and Lua's once it is not.
 */
export function sliderShown(local: number, lua: number, touchedAt: number, now: number): number {
  return now - touchedAt > SLIDER_HOLD_MS ? lua : local
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

// ═══ TATTOOS (owner, 2026-10-11 and 2026-10-12), now an extra ═══
//
// "whatever the game has include DLC sets. They're all free just like the
// rest of the locker." Lua sends each sex's list once (`locker2tats`, names
// from the game's own text) and, on every push, the rows (`edit.tats`): "a
// list, starting empty, with add and remove buttons ... You can just make it
// max 10 per category". Then (2026-10-14): "starting with a bunch of add
// buttons is not intuitive, especially having to use a dropdown to navigate
// between them. fix that" -- so ONE list, its rows grouped under their zones,
// and ONE "Add more", which asks the zone and then the tattoo (Tattoos.tsx).

/** The body zones, in the order drawn (br_lib/config/tattoos.lua's `zones`). */
export const TATTOO_ZONES = ['head', 'torso', 'larm', 'rarm', 'lleg', 'rleg'] as const

/** The Tattoos extra's own category, and a zone's: the ids Lua's
 *  `tattooCats` gives them, so LOCKER2_CAT moves the camera for both. */
export const TATTOOS_CAT = 'tattoos'
export const tattooCat = (zone: string): string => `tat_${zone}`

/**
 * One sex's list as the page may draw it: zones it knows, in its order, each
 * with its whole items -- an `i` that is a positive integer, a name only if it
 * is a non-empty string -- and none empty. Anything else is dropped.
 */
export function parseTats(raw: unknown): Locker2TatsPayload | null {
  const d = obj(raw)
  if (!d || (d.sex !== 'm' && d.sex !== 'f')) return null
  const byZone = new Map<string, Locker2Tattoo[]>()
  for (const z of list(d.zones).map(obj)) {
    if (!z || !str(z.z) || byZone.has(z.z)) continue
    const items = list(z.items).map(obj)
      .filter((t): t is Record<string, unknown> => t !== null && Number.isInteger(t.i) && (t.i as number) > 0)
      .map((t): Locker2Tattoo => (str(t.name) && t.name !== '' ? { i: t.i as number, name: t.name } : { i: t.i as number }))
    if (items.length > 0) byZone.set(z.z, items)
  }
  return {
    sex: d.sex,
    zones: TATTOO_ZONES.filter((z) => byZone.has(z)).map((z) => ({ z, items: byZone.get(z) ?? [] })),
  }
}

/** "max 10 per category" (owner, 2026-10-12): the most rows a zone takes.
 *  Lua's A.TATTOOS_PER_ZONE, which tools/test_locker2.lua holds equal to this;
 *  Lua refuses an 11th whatever the page sends. */
export const TATTOOS_PER_ZONE = 10

/** A zone's rows, in the order drawn. */
export const zoneRows = (rows: readonly Locker2TatRow[], z: string): Locker2TatRow[] =>
  rows.filter((r) => r.z === z)

/** A zone takes another tattoo below the cap, while it has one no row holds. */
export const canAddTattoo = (rowCount: number, itemCount: number): boolean =>
  rowCount < TATTOOS_PER_ZONE && rowCount < itemCount

/** The zones "Add more" may put a tattoo in: the list's zones, in order, each
 *  with its room (a full one is offered off). */
export function addZones(
  zones: readonly { z: string; items: readonly unknown[] }[], rows: readonly Locker2TatRow[],
): { z: string; open: boolean }[] {
  return zones.map((zone) => ({ z: zone.z, open: canAddTattoo(zoneRows(rows, zone.z).length, zone.items.length) }))
}

/** "Add more" is lit while some zone has room. */
export const canAddMore = (zones: readonly { z: string; items: readonly unknown[] }[], rows: readonly Locker2TatRow[]): boolean =>
  addZones(zones, rows).some((x) => x.open)

/** The tattoos a new row of zone `z` may take: the zone's, none a row of it
 *  holds. */
export function newRowChoices<T extends { i: number }>(items: readonly T[], rows: readonly Locker2TatRow[], z: string): T[] {
  const taken = new Set(zoneRows(rows, z).map((x) => x.i))
  return items.filter((t) => !taken.has(t.i))
}

/** The rows grouped under their zones, in the zones' order; a zone with no
 *  row draws nothing. */
export function tatGroups(zones: readonly string[], rows: readonly Locker2TatRow[]): { z: string; rows: Locker2TatRow[] }[] {
  return zones.map((z) => ({ z, rows: zoneRows(rows, z) })).filter((g) => g.rows.length > 0)
}

/**
 * A row's list: its zone's tattoos in the zone's order, but none another row
 * of the zone holds -- so a zone never has one tattoo twice. The row's own
 * stays in it. Lua refuses the rest whatever the page sends.
 */
export function tattooChoices<T extends { i: number }>(
  items: readonly T[], rows: readonly Locker2TatRow[], row: Locker2TatRow,
): T[] {
  const taken = new Set(rows.filter((x) => x.r !== row.r).map((x) => x.i))
  return items.filter((t) => !taken.has(t.i))
}

/**
 * A picker's list as typed: the options whose NAME holds the text, any case.
 * The name alone (#28 review): Cloudscape's own filter also searches each
 * option's value, the tattoo's number in the list, so typing "5" brought up
 * Tattoo 10 to 14 and every tattoo whose number has a 5 in it.
 */
export function tattooFilter<T extends { label: string }>(opts: readonly T[], text: string): T[] {
  const q = text.toLowerCase()
  return q === '' ? [...opts] : opts.filter((o) => o.label.toLowerCase().includes(q))
}

/** The same rows, each the same tattoo, in the same order: a zone that
 *  draws nothing new on a push. */
export const sameTatRows = (a: readonly Locker2TatRow[], b: readonly Locker2TatRow[]): boolean =>
  a.length === b.length && a.every((x, k) => x.r === b[k]?.r && x.i === b[k]?.i && x.z === b[k]?.z)

// ═══ HEADSHOTS (contract section 6, with the skeptic's correction 6) ═══

/**
 * AN IMAGE A CANVAS WILL READ BACK (#28 review). The headshot is
 * https://nui-img/..., another origin than the page's, and a canvas that has
 * drawn another origin's image WITHOUT CORS is tainted: toDataURL throws, and
 * every card stays a name. `crossOrigin` must be set before `src`, or the
 * request has already gone out without it. Every image drawn to a canvas is
 * made through here (scripts/test-lockerv2.mjs holds the source to that).
 */
export function canvasImage<T extends { crossOrigin: string | null; src: string }>(img: T, url: string): T {
  img.crossOrigin = 'anonymous'
  img.src = url
  return img
}

/** The session cache's key: a look's image is good until it is saved again. */
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
 * The saved looks that still need a picture taken: no stored image, none
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

const TABS: readonly Locker2Tab[] = ['peds', 'stock', 'male', 'female']

function row(v: unknown): Locker2Row | null {
  const r = obj(v)
  if (!r || !str(r.k) || !str(r.cat) || !num(r.v)) return null
  if (r.kind === 'count' && num(r.n)) {
    const colors = num(r.colors) ? r.colors : 1
    // An item's colors, one a texture: whole, or none at all.
    const sw = list(r.sw)
    const swOk = sw.length === colors && colors <= 64 && sw.every((c) => typeof c === 'string' && HEX.test(c))
    return {
      k: r.k, cat: r.cat, kind: 'count', v: r.v, n: r.n, colors,
      ...(str(r.name) && r.name !== '' ? { name: r.name } : {}),
      ...(r.pal === 'hair' || r.pal === 'makeup' ? { pal: r.pal } : {}),
      ...(Number.isInteger(r.c) && (r.c as number) >= 0 ? { c: r.c as number } : {}),
      ...(swOk && r.pal === undefined ? { sw: sw as string[] } : {}),
    }
  }
  if (r.kind === 'slider' && num(r.min) && num(r.max)) {
    return {
      k: r.k, cat: r.cat, kind: 'slider', v: r.v, min: r.min, max: r.max,
      def: num(r.def) ? r.def : r.min,
      ...(r.off === true ? { off: true } : {}),
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
    cat: str(e.cat) ? e.cat : null,
    rows: list(e.rows).map(row).filter((r): r is Locker2Row => r !== null),
    tats: list(e.tats).map(tatRow).filter((r): r is Locker2TatRow => r !== null),
    extras: orderedExtras(list(e.extras)),
    undo: e.undo === true,
    redo: e.redo === true,
  }
}

/** A tattoo row whole: a positive integer id and tattoo, in a zone drawn. */
function tatRow(v: unknown): Locker2TatRow | null {
  const t = obj(v)
  const id = (n: unknown): n is number => Number.isInteger(n) && (n as number) > 0
  if (!t || !id(t.r) || !id(t.i) || !str(t.z) || !(TATTOO_ZONES as readonly string[]).includes(t.z)) return null
  return { r: t.r, z: t.z, i: t.i }
}

/**
 * The `locker2` envelope as the page may draw it: every list an array, every
 * flag a boolean, every row whole. A field Lua left out is its empty value,
 * never `undefined` reaching a component.
 */
export function parseLocker2(raw: unknown): Locker2Payload {
  const d = obj(raw) ?? {}
  const tab = (TABS as readonly unknown[]).includes(d.tab) ? (d.tab as Locker2Tab) : 'stock'
  const worn = obj(d.worn)
  return {
    on: d.on === true,
    tab,
    tabSeq: num(d.tabSeq) ? d.tabSeq : null,
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
