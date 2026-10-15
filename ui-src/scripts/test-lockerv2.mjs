#!/usr/bin/env node
/**
 * LOCKER V2'S TESTS (#28, "My Looks"): the page's rules, its copy, its theme,
 * its wiring, the browser harness's half of Lua, and its chunk.
 *
 * src/screens/lockerv2/model.ts decides everything the Season 2 locker does
 * before it draws, and it has no runtime imports, so node's type stripping
 * loads it as-is; copy.ts and theme.ts the same. bridge/mockLocker2.ts -- the
 * stand-in for br_core that the preview runs on, and the reference for the
 * wiring round -- is driven here too, through a resolver that finds its
 * extensionless imports. Each block holds one piece of the owner's design
 * (#28, 2026-10-12/13) and fails when that piece is reverted:
 *
 *   FLOW      My Looks / New / Stock GTA Looks / the editor: the view follows
 *             Lua once a push has seen the page's latest numbered request;
 *             Back goes one level up, the editor's asks first if unsaved, My
 *             Looks' is Done (close, then the focus); Escape is an open
 *             dropdown's, then a dialog's, then Back -- and under a
 *             walkthrough card it never closes the locker.
 *   NAMES     letters, digits and single spaces; no space first; the ends
 *             trimmed when used; 1 to 24.
 *   SAVE      a new look is named; a saved one's dialog has Save (update, with
 *             the name typed), and Save as new only when it was opened from
 *             My Looks; Save is lit for a new look, and for a saved one only
 *             with changes.
 *   EXTRAS    the core always listed, the extras on the look after it in the
 *             order they were put on, "Add more" offering the rest; a trash
 *             icon takes one off.
 *   SUMMARY   one line a category: the item's place in its list (`v/n`) --
 *             no names unless a category is switched on; a color chip;
 *             Tattoos, how many.
 *   SWATCHES  hair and makeup colors as swatches, sending the color itself;
 *             an item's own colors a swatch button, never "Next color".
 *   NEW       a card press selects; Create goes on with the one selected.
 *   TATTOOS   one list grouped by zone; one "Add more" asking the zone, then
 *             the tattoo.
 *   HOLD      a held arrow: the press, 400 ms, then quicker to a 50 ms floor.
 *   HISTORY   Undo / Redo, a drag or a hold one step.
 *   SHARE     a push hands back unchanged parts as the same objects.
 *   COPY      a label is OWNER only if it is on the list of his; the rest are
 *             WRITTEN, each with its marker.
 *   CORNERS   every radius token at 0, and the stylesheet squares the rest.
 *   MOCK      the harness plays New, the history, the extras (in order), the
 *             palettes, the face groups, a tattoo by zone and tattoo,
 *             Randomize over the extras, and both saves the way the page
 *             expects; every kind of change is one Undo step, undone exactly.
 *   RENDERED  the screen's own components, drawn by lockerv2-render.mjs,
 *             pressed through their own handlers and answered by the harness:
 *             a card press wears and marks; New's Custom first, focused and
 *             lit, a card press selecting and Create going on; the
 *             walkthrough's ring on Done alone, Done away elsewhere; the
 *             strip, one category at a time, Fine-tune closed, no random
 *             button on a row, "Add more" outside the scroll box with a menu
 *             of its own; an item's colors behind a swatch button; the tattoo
 *             list and its one "Add more"; the camera row and its hints;
 *             every plate the lobby's, lit when selected; and no word that is
 *             not copy.ts's or the look's.
 *   FIT       no text wraps or ends in "...": a line that does not fit is not
 *             drawn; every border is inside its clip.
 *   WIRING    the screen asks these rules, opens with LOCKER2_OPEN alone,
 *             builds the theme once, draws the preloaded chunk outright, and
 *             subscribes to the fields it draws.
 *   SEASON 1  screens/Locker.tsx is byte-for-byte the finished product.
 *   CHUNK     Cloudscape and this screen's CSS ship in assets/LockerV2.*, the
 *             CSS all scoped -- nothing global.
 *
 * Run: npm run test:lockerv2   (and as part of npm run build, after vite)
 */

import { spawnSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { register } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import {
  COALESCE_MS, CORE_CATS, EXTRA_CATS, FACE_GROUPS, HISTORY_MAX, HOLD_FIRST_MS, HOLD_MIN_MS, NAMED_CATS, NAME_MAX,
  NEW_DEFAULT, OPEN_POPUP, PRIMARY_ROW, SLIDER_HOLD_MS, TATTOOS_PER_ZONE, TATTOO_ZONES,
  addZones, addableExtras, backSteps, canAddMore, canAddTattoo, canvasImage, cleanName, counterText, createStep,
  dataUrlBytes, escapeAction, filterName, followView, groupMoved, holdDelay, holdSteps, imgOk, isExtra, listedCats,
  nameOk, nameShown, needShots, newHistory, newRowChoices, orderedExtras, panelOf, panelRows, parseLocker2, parsePal,
  parseTats, popupOpen, record, redoStep, sameTatRows, saveDialogFor, saveEnabled, saveRequest, share, shotKey,
  shotStorable, sliderShown, summaryOf, swatchOf, swatchRequest, swatchesShown, tatGroups, tattooChoices,
  tattooFilter, textureFace, textureOf, textureRequest, texturesShown, undoStep, wrapStep, zoneRows, zoomFor,
} from '../src/screens/lockerv2/model.ts'
import {
  BTN, CAM, CARD, CAT_LABEL, GROUP_LABEL, MODAL, ROW_LABEL, SEX_LABEL, TITLE, ZONE_LABEL, deleteTitle, rowLabel,
  swatchLabel, tattooFallback, tattooLabels,
} from '../src/screens/lockerv2/copy.ts'
import { LOCKER_THEME } from '../src/ui/cloudscape/theme.ts'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = join(ROOT, 'src')
const L2 = join(SRC, 'screens', 'lockerv2')
const OUT = join(ROOT, '..', 'resources', '[fivem-royale]', 'br_ui', 'ui', 'assets')

// A RUN THAT NEVER ENDS FAILS (#28 review: a trash icon broken on purpose kept
// one of the loops below going for good, and the build with it). The suite
// runs as a child of itself, given RUN_MS.
const RUN_MS = 300000
if (process.env.LK2_TEST_CHILD !== '1') {
  const r = spawnSync(process.execPath, [fileURLToPath(import.meta.url), ...process.argv.slice(2)], {
    stdio: 'inherit', timeout: RUN_MS, env: { ...process.env, LK2_TEST_CHILD: '1' },
  })
  if (r.error || r.signal) {
    console.log(`\ntest-lockerv2: no end after ${RUN_MS / 1000} s -- a loop that never ends (${r.error?.code ?? r.signal})`)
    process.exit(1)
  }
  process.exit(r.status ?? 1)
}

let failed = 0
let ran = 0
function check(label, ok, detail = '') {
  ran++
  if (!ok) failed++
  console.log(ok ? `  ok    ${label}` : `  FAIL  ${label}${detail ? `\n          ${detail}` : ''}`)
}
const eq = (label, got, want) => {
  const g = JSON.stringify(got)
  const w = JSON.stringify(want)
  check(label, g === w, `got ${g}\n          want ${w}`)
}
const read = (p) => readFileSync(p, 'utf8').replace(/\r\n/g, '\n')
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '')

// ── FLOW ─────────────────────────────────────────────────────────────────────
// "let's get rid of the top left/right select bar, and move to a new flow"
eq('view: a push that has seen the latest request follows Lua -- a draft up is the editor',
  [followView('home', true, 4, 4), followView('new', true, 4, 4)], ['edit', 'edit'])
eq('view: no draft once Lua has answered takes the editor home (a New Lua refused)',
  followView('edit', false, 5, 5), 'home')
eq('view: no draft leaves the other views where they are',
  [followView('new', false, 5, 5), followView('stock', false, 5, 5)], ['new', 'stock'])
eq('view: a push older than the latest request is not followed (the press stays)',
  [followView('edit', false, 4, 5), followView('home', true, 4, 5), followView('home', true, null, 1)],
  ['edit', 'home', 'home'])
eq('Back: the editor with changes asks first, and nothing else', backSteps('edit', true, false), [{ do: 'confirm' }])
eq('Back: the editor once Discard is pressed, or with nothing to lose, leaves',
  [backSteps('edit', true, true), backSteps('edit', false, false)], [[{ do: 'leave' }], [{ do: 'leave' }]])
eq('Back: Stock GTA Looks to New, New to My Looks',
  [backSteps('stock', false, false), backSteps('new', false, false)],
  [[{ do: 'view', to: 'new' }], [{ do: 'view', to: 'home' }]])
eq('Done on My Looks: close, then the focus', backSteps('home', false, false), [{ do: 'close' }, { do: 'unfocus' }])
// "when I click "custom" or "stock gta looks" it should have a create button,
// or not have either card selected by default" (owner, 2026-10-14)
eq('New: Custom is selected as it opens; Create makes a custom look, or opens the stock roster',
  [NEW_DEFAULT, createStep('custom'), createStep('stock')], ['custom', { do: 'new' }, { do: 'view', to: 'stock' }])
eq('Escape: an open dropdown has it first, whatever else is up',
  [escapeAction('edit', true, false, true), escapeAction('home', false, true, true)], ['pass', 'pass'])
eq('Escape: then an open dialog, alone', [escapeAction('edit', true), escapeAction('home', true, true)], ['modal', 'modal'])
eq('Escape: then the view\'s Back', ['home', 'new', 'stock', 'edit'].map((v) => escapeAction(v, false)),
  ['back', 'back', 'back', 'back'])
// The Season 2 Market (#411) shares it with no views of its own: the last step closes it.
eq('Escape on a screen with no views (the Market): a dropdown, a dialog, then Done -- held under a card',
  [escapeAction(false, false, true), escapeAction(true), escapeAction(false), escapeAction(false, true)],
  ['pass', 'modal', 'done', 'none'])
// #405: a walkthrough card waiting on the locker holds its CLOSING only.
eq('Escape under a walkthrough card: My Looks does not close; inside, Back still works',
  [escapeAction('home', false, true), escapeAction('edit', false, true), escapeAction('stock', false, true)],
  ['none', 'back', 'back'])
{
  const asked = []
  const root = (hit) => ({ querySelector: (s) => { asked.push(s); return hit ? {} : null } })
  const SEL = 'button[aria-haspopup][aria-expanded="true"]'
  eq('a dropdown is open when the screen has a trigger with a popup, expanded; none without a screen',
    [popupOpen(root(true)), popupOpen(root(false)), popupOpen(null), asked], [true, false, false, [SEL, SEL]])
  eq('that selector is OPEN_POPUP, and a trigger button only', OPEN_POPUP, SEL)
}

// ── NAMES ────────────────────────────────────────────────────────────────────
// "we need to allow spaces in the ped names." (owner, 2026-10-12)
eq('name: spaces kept, one at a time, none first; everything but letters, digits and spaces dropped',
  [filterName('Night Owl'), filterName('  Night   Owl_2!'), filterName('Zoë  Q')], ['Night Owl', 'Night Owl2', 'Zo Q'])
eq('name: a space last is kept while typing, so a second word can follow', filterName('Night '), 'Night ')
eq('name: capped at 24, spaces counted', [filterName('A '.repeat(20)).length, NAME_MAX], [24, 24])
eq('name: used with its ends trimmed and doubled spaces made one',
  [cleanName('  Night  Owl '), cleanName('Night\tOwl')], ['Night Owl', 'Night Owl'])
eq('name: words of letters and digits, one space between, 1 to 24',
  [nameOk('Night Owl'), nameOk('A'), nameOk('A'.repeat(24)), nameOk('A'.repeat(25)), nameOk(' Owl'),
    nameOk('Owl '), nameOk('Night  Owl'), nameOk(''), nameOk('Zoë')],
  [true, true, true, false, false, false, false, false, false])

// ── SAVE ─────────────────────────────────────────────────────────────────────
// "Save updates an existing look; "Save as new" lives in the save dialog"
const PEDS = [{ id: 'a1', name: 'Nightshift' }, { id: 'b2', name: 'Ranger' }]
eq('Save on a new look: the name dialog', [saveDialogFor(null, PEDS, false), saveDialogFor(null, PEDS, true)],
  [{ kind: 'name' }, { kind: 'name' }])
// "say I create a new look and save it - why do I have save and save as new?"
eq('Save on a look opened from My Looks: its dialog, with its name, and Save as new',
  saveDialogFor('b2', PEDS, true), { kind: 'save', id: 'b2', name: 'Ranger', asNew: true })
eq('Save on a look made with New and saved once: its name and Save alone, no Save as new',
  saveDialogFor('b2', PEDS, false), { kind: 'save', id: 'b2', name: 'Ranger', asNew: false })
eq('Save on a look deleted from under the edit: a new look again', saveDialogFor('zz', PEDS, true), { kind: 'name' })
eq('the save dialog\'s Save updates that look, with the name typed, cleaned',
  saveRequest({ kind: 'save', id: 'b2', name: 'Ranger', asNew: true }, 'update', ' Lone  Ranger '),
  { op: 'update', id: 'b2', name: 'Lone Ranger' })
eq('and its Save as new makes a new look by that name',
  saveRequest({ kind: 'save', id: 'b2', name: 'Ranger', asNew: true }, 'new', 'Ranger 2'), { op: 'new', name: 'Ranger 2' })
eq('the name dialog only ever saves new', saveRequest({ kind: 'name' }, 'update', 'Night Owl'), { op: 'new', name: 'Night Owl' })
eq('Save lit: a new look always (never saved), a saved one with changes, never while a write is in flight',
  [saveEnabled(null, false, false), saveEnabled('a1', false, false), saveEnabled('a1', true, false),
    saveEnabled(null, true, true)], [true, false, true, false])

// ── EXTRAS ───────────────────────────────────────────────────────────────────
// "presented with a choice to add customizations for each category"
eq('the core, always, in order', CORE_CATS, ['face', 'skin', 'hair', 'top', 'legs', 'shoes'])
eq('the extras, today\'s optional rows', EXTRA_CATS,
  ['hat', 'glasses', 'earrings', 'mask', 'vest', 'bag', 'watch', 'bracelet', 'decals', 'accessory', 'makeup', 'tattoos'])
eq('a new look lists the core and nothing else', listedCats([]), [...CORE_CATS])
// "cards should be added in the list in the order the player adds them"
eq('the extras on a look follow the core IN THE ORDER PUT ON, and only known ones, each once',
  listedCats(['tattoos', 'hat', 'nope', 'makeup', 'hat']), [...CORE_CATS, 'tattoos', 'hat', 'makeup'])
eq('Lua\'s order is kept as it crosses the bridge', orderedExtras(['earrings', 'tattoos', 7, 'earrings']), ['earrings', 'tattoos'])
eq('"Add more" offers every extra not on the look', addableExtras(['hat', 'tattoos']),
  EXTRA_CATS.filter((c) => c !== 'hat' && c !== 'tattoos'))
eq('"Add more" is empty once all are on', addableExtras([...EXTRA_CATS]), [])
eq('only an extra has a trash icon', [isExtra('hat'), isExtra('tattoos'), isExtra('face'), isExtra('shoes')],
  [true, true, false, false])
eq('a tattoo zone\'s camera category is the Tattoos panel\'s', [panelOf('tat_torso'), panelOf('hair'), panelOf(null)],
  ['tattoos', 'hair', null])
check('every category but Tattoos has a row its summary line reads',
  [...CORE_CATS, ...EXTRA_CATS].filter((c) => c !== 'tattoos').every((c) => typeof PRIMARY_ROW[c] === 'string'))
check('every category has a label', [...CORE_CATS, ...EXTRA_CATS].every((c) => typeof CAT_LABEL[c] === 'string'))

// ── SUMMARY AND PANELS ───────────────────────────────────────────────────────
{
  const rows = [
    { k: 'shape', cat: 'face', kind: 'count', v: 3, n: 6, colors: 1 },
    { k: 'e', cat: 'face', kind: 'count', v: 7, n: 31, colors: 1 },
    { k: 'ff0', cat: 'face', kind: 'slider', v: 20, min: -100, max: 100, def: 0 },
    { k: 'ff1', cat: 'face', kind: 'slider', v: 0, min: -100, max: 100, def: 0 },
    { k: 'c2', cat: 'hair', kind: 'count', v: 9, n: 80, colors: 64, name: 'Buzz Cut', pal: 'hair', c: 12 },
    { k: 'c11', cat: 'top', kind: 'count', v: 37, n: 392, colors: 3 },
    { k: 'o4', cat: 'makeup', kind: 'count', v: 1, n: 76, colors: 1, pal: 'makeup', c: 0 },
  ]
  // "All or nothing on that": the game names some items and not others.
  eq('no category shows the game\'s names', [...NAMED_CATS], [])
  eq('a summary line: the item\'s place in its list even where the game names it, and the color chip of a palette item',
    summaryOf('hair', rows, 0), { text: '9/80', chip: { pal: 'hair', i: 12 } })
  eq('...and where it does not: never "Top 37"', summaryOf('top', rows, 0), { text: '37/392', chip: null })
  eq('no caption under a row either', [nameShown(rows[4]), nameShown(rows[5])], [null, null])
  eq('the face: the starting face', summaryOf('face', rows, 0).text, '3/6')
  eq('an item that is none shows no chip (its color is on nothing)', summaryOf('makeup', rows, 0).chip, null)
  eq('Tattoos: how many', summaryOf('tattoos', rows, 4), { text: '4', chip: null })
  eq('a panel draws its category\'s rows -- never the starting face, never the features (Fine-tune has those)',
    panelRows(rows, 'face').map((r) => r.k), ['e'])
  eq('the features grouped by what they are, each once',
    FACE_GROUPS.flatMap((g) => g.ks).sort(), Array.from({ length: 20 }, (_, i) => `ff${i}`).sort())
  eq('the groups, in order', FACE_GROUPS.map((g) => g.id), ['nose', 'brows', 'cheeks', 'eyeslips', 'jaw', 'chin', 'neck'])
  eq('a group\'s reset is lit while one of its sliders is off its default',
    [groupMoved(rows, ['ff0', 'ff1']), groupMoved(rows, ['ff1'])], [true, false])
  check('every group has a label', FACE_GROUPS.every((g) => typeof GROUP_LABEL[g.id] === 'string'))
}

// ── SWATCHES ─────────────────────────────────────────────────────────────────
// "hair and makeup colors as a swatch grid instead of "Next color""
{
  const hair = { k: 'c2', cat: 'hair', kind: 'count', v: 9, n: 80, colors: 64, pal: 'hair', c: 12 }
  const hi = { k: 'h1', cat: 'hair', kind: 'count', v: 5, n: 64, colors: 1, pal: 'hair' }
  const lip = { k: 'o8', cat: 'makeup', kind: 'count', v: 1, n: 11, colors: 1, pal: 'makeup', c: 0 }
  const top = { k: 'c11', cat: 'top', kind: 'count', v: 4, n: 392, colors: 3 }
  eq('the color worn: an item\'s `c`; the highlight is its own value',
    [swatchOf(hair), swatchOf(hi), swatchOf(top)], [12, 4, null])
  eq('swatches for a palette item with colors, and always for the highlight; none for an overlay of none',
    [swatchesShown(hair), swatchesShown(hi), swatchesShown(lip), swatchesShown(top)], [true, true, false, false])
  // "any button showing "next color" should have a button for a color swatch instead"
  eq('an item\'s own colors (textures) behind a swatch button: an item with more than one and no palette',
    [texturesShown(top), texturesShown(hair), texturesShown({ ...top, colors: 1 })], [true, false, false])
  eq('the texture worn: its `c`, else the first; a `c` past its colors is the first',
    [textureOf({ ...top, c: 2 }), textureOf(top), textureOf({ ...top, c: 9 })], [2, 0, 0])
  eq('a texture swatch shows its color where Lua sends the item\'s colors, else its place among them',
    [textureFace({ ...top, sw: ['#111111', '#222222', '#333333'] }, 1), textureFace(top, 1)], [{ color: '#222222' }, { n: 2 }])
  eq('a texture swatch sends LOCKER2_COLOR { k, c }, 0-based', textureRequest(top, 2), { k: 'c11', c: 2 })
  eq('a swatch sends its color: the item\'s by index (LOCKER2_COLOR), the highlight\'s as its place (LOCKER2_SET)',
    [swatchRequest(hair, 30), swatchRequest(hi, 30)],
    [{ cb: 'color', data: { k: 'c2', c: 30 } }, { cb: 'set', data: { k: 'h1', v: 31 } }])
  eq('the palettes: #rrggbb only, 64 at most, nothing else is a palette',
    [parsePal({ hair: ['#112233', 'red', 7, '#abcdef'], makeup: {} }), parsePal({ hair: [], makeup: [] }),
      parsePal(null), parsePal({ hair: Array(80).fill('#000000') }).hair.length],
    [{ hair: ['#112233', '#abcdef'], makeup: [] }, null, null, 64])
  eq('a swatch\'s name', swatchLabel(12), 'Color 12')
}

// ── HOLD TO SCROLL ───────────────────────────────────────────────────────────
// "next/last stays, with hold-to-scroll (a held arrow repeats, accelerating)"
eq('a held arrow waits 400 ms, then repeats every 160 ms, each quicker',
  [holdDelay(1), holdDelay(2), holdDelay(3), holdDelay(4)], [400, 160, 136, 116])
check('the repeats never get quicker than 50 ms, and get there',
  holdDelay(100) === HOLD_MIN_MS && Array.from({ length: 40 }, (_, i) => holdDelay(i + 1)).every((d, i, a) => i === 0 || d <= a[i - 1])
  && HOLD_FIRST_MS === 400)
eq('a tap is one step; held a second, seven; held three, past forty',
  [holdSteps(100), holdSteps(399), holdSteps(1000), holdSteps(3000) > 40], [1, 1, 7, true])

// ── HISTORY ──────────────────────────────────────────────────────────────────
// Undo / Redo: "yes" (owner, 2026-10-13). Lua runs these; the mock does too.
{
  let h = newHistory()
  h = record(h, 'A', 'c11', 1000)
  h = record(h, 'B', 'c11', 1000 + COALESCE_MS - 1) // the same row again: one step
  h = record(h, 'C', 'c4', 3000)
  eq('touches of one row closer than the merge window are one step; another row is another',
    h.past, ['A', 'C'])
  const u1 = undoStep(h, 'D')
  eq('Undo: the look before, the present kept for Redo', [u1.value, u1.h.past, u1.h.future], ['C', ['A'], ['D']])
  const r1 = redoStep(u1.h, u1.value)
  eq('Redo: forward again', [r1.value, r1.h.past, r1.h.future], ['D', ['A', 'C'], []])
  const fresh = record(u1.h, 'C', 'p0', 9000)
  eq('a new change after Undo clears Redo', fresh.future, [])
  eq('nothing to undo or redo is no step', [undoStep(newHistory(), 'x'), redoStep(newHistory(), 'x')], [null, null])
  const later = record(record(newHistory(), 'A', 'c11', 0), 'B', 'c11', COALESCE_MS + 1)
  eq('the same row after the window is a new step', later.past, ['A', 'B'])
  const blind = record(record(newHistory(), 'A', null, 0), 'B', null, 1)
  eq('Randomize, an extra, a group\'s reset (no key) never merge', blind.past, ['A', 'B'])
  let big = newHistory()
  for (let i = 0; i < HISTORY_MAX + 5; i++) big = record(big, i, null, i)
  eq('the history keeps the last 50', [big.past.length, big.past[0]], [50, 5])
  // Undo then a slider drag of the row just undone: a step of its own.
  const u2 = undoStep(record(newHistory(), 'A', 'ff0', 0), 'B')
  eq('after Undo, the same row\'s next touch is a new step', record(u2.h, 'A', 'ff0', 10).past, ['A'])
}

// ── SHARE (the lag report, cause 3) ──────────────────────────────────────────
{
  const a = parseLocker2({ on: true, peds: [{ id: 'a', name: 'A', up: 1 }], edit: { sex: 'm', rows: [
    { k: 'c11', cat: 'top', kind: 'count', v: 1, n: 9, colors: 1 },
    { k: 'c4', cat: 'legs', kind: 'count', v: 1, n: 9, colors: 1 },
  ] } })
  const b = parseLocker2({ on: true, peds: [{ id: 'a', name: 'A', up: 1 }], edit: { sex: 'm', rows: [
    { k: 'c11', cat: 'top', kind: 'count', v: 2, n: 9, colors: 1 },
    { k: 'c4', cat: 'legs', kind: 'count', v: 1, n: 9, colors: 1 },
  ] } })
  const s = share(a, b)
  check('a push that changed one row: that row is new, every other part is the same object',
    s !== a && s.edit.rows[0] !== a.edit.rows[0] && s.edit.rows[0].v === 2 && s.edit.rows[1] === a.edit.rows[1]
    && s.peds === a.peds && s.stock === a.stock)
  check('a push that changed nothing is the same object', share(a, parseLocker2(JSON.parse(JSON.stringify(a)))) === a)
  check('a list that grew is new', share([1, 2], [1, 2, 3]).length === 3)
}

// ── ROWS, TATTOOS, PICTURES, THE ENVELOPE ────────────────────────────────────
eq('counter: "12/39"', counterText(12, 39), '12/39')
eq('counter: 39 then next is 1, and 1 then last is 39', [wrapStep(39, 39, 1), wrapStep(1, 39, -1)], [1, 39])
eq('slider: its own value while touched, Lua\'s once the hold is over',
  [sliderShown(40, 100, 1000, 1000 + SLIDER_HOLD_MS - 1), sliderShown(40, 100, 1000, 1000 + SLIDER_HOLD_MS + 1)], [40, 100])
eq('row names: an overlay\'s opacity is "<row> opacity"; a key with no word gets none',
  [rowLabel('o2op'), rowLabel('c6'), rowLabel('c99'), rowLabel('o99op')], ['Eyebrows opacity', 'Shoes', null, null])
eq('row names: the twenty face features', Object.keys(ROW_LABEL).filter((k) => /^ff\d+$/.test(k)).length, 20)
{
  const t = parseTats({ sex: 'm', zones: [
    { z: 'torso', items: [{ i: 5, name: 'Skull' }, { i: 7 }, { i: 0, name: 'bad' }, 'junk'] },
    { z: 'head', items: [{ i: 1, name: 'Star' }] }, { z: 'nope', items: [{ i: 3 }] },
  ] })
  eq('tattoo list: the body\'s zones in order, whole items', [t.zones.map((z) => z.z), t.zones[1].items],
    [['head', 'torso'], [{ i: 5, name: 'Skull' }, { i: 7 }]])
  const rows = [{ r: 1, z: 'torso', i: 5 }, { r: 2, z: 'torso', i: 9 }]
  eq('max 10 a zone; Add off at 10 or once every tattoo has a row',
    [TATTOOS_PER_ZONE, canAddTattoo(9, 76), canAddTattoo(10, 76), canAddTattoo(3, 3)], [10, true, false, false])
  eq('a row\'s list leaves out what the zone\'s other rows hold',
    tattooChoices([{ i: 5 }, { i: 7 }, { i: 9 }], rows, rows[0]).map((x) => x.i), [5, 7])
  eq('a picker filters by the name alone', tattooFilter([{ value: '15', label: 'Dragon' }, { value: '5', label: 'Tattoo 2' }], '5')
    .map((o) => o.value), [])
  eq('a zone\'s rows and its redraw rule', [zoneRows(rows, 'torso').length, sameTatRows(rows, rows.map((r) => ({ ...r })))],
    [2, true])
  eq('the nameless numbered among themselves', tattooLabels([{ i: 1 }, { i: 2, name: 'Skull' }, { i: 3 }]).map(([, l]) => l),
    ['Tattoo 1', 'Skull', 'Tattoo 2'])
  // "starting with a bunch of add buttons is not intuitive ... fix that"
  const zs = [{ z: 'head', items: [{ i: 1 }] }, { z: 'torso', items: [{ i: 5 }, { i: 7 }, { i: 9 }] }]
  const full = Array.from({ length: 10 }, (_, k) => ({ r: 20 + k, z: 'torso', i: 100 + k }))
  eq('one list: the rows grouped under their zones, in the zones\' order, a zone with none not drawn',
    tatGroups(TATTOO_ZONES, [{ r: 3, z: 'torso', i: 5 }, { r: 4, z: 'head', i: 1 }, { r: 5, z: 'torso', i: 9 }])
      .map((g) => [g.z, g.rows.map((x) => x.r)]), [['head', [4]], ['torso', [3, 5]]])
  eq('"Add more" asks the zone: every zone, a full one offered off',
    [addZones(zs, rows), addZones(zs, full)],
    [[{ z: 'head', open: true }, { z: 'torso', open: true }], [{ z: 'head', open: true }, { z: 'torso', open: false }]])
  eq('...then the tattoo: the zone\'s, none a row of it holds', newRowChoices(zs[1].items, rows, 'torso').map((t) => t.i), [7])
  eq('"Add more" is off once no zone has room', [canAddMore(zs, rows), canAddMore([zs[1]], full)], [true, false])
  eq('every zone has a word', TATTOO_ZONES.every((z) => typeof ZONE_LABEL[z] === 'string'), true)
}
{
  class StubImage {
    constructor() { this._co = null; this.corsAtRequest = undefined }
    set crossOrigin(v) { this._co = v }
    get crossOrigin() { return this._co }
    set src(v) { this._src = v; this.corsAtRequest = this._co }
    get src() { return this._src }
  }
  eq('a canvas image is requested WITH CORS: crossOrigin set before src',
    canvasImage(new StubImage(), 'https://nui-img/x/x?v=1').corsAtRequest, 'anonymous')
  const SHOT = `data:image/webp;base64,${'A'.repeat(100)}`
  eq('a picture is a base64 image data URL and nothing else',
    [imgOk(SHOT), imgOk('https://evil.example/x.png'), imgOk('javascript:alert(1)')], [true, false, false])
  eq('a shot is stored only as webp within 8 KB',
    [shotStorable(SHOT), shotStorable(`data:image/webp;base64,${'A'.repeat(11000)}`)], [true, false])
  eq('data URL size counts decoded bytes', dataUrlBytes('data:image/webp;base64,AAAA'), 3)
  eq('shots are asked for once, only for looks with no stored or cached picture',
    needShots([{ id: 'a', up: 1 }, { id: 'b', up: 1, img: SHOT }, { id: 'c', up: 2 }], new Set([shotKey('c', 2)]), new Set()),
    ['a'])
}
{
  const p = parseLocker2({ on: true, tab: 'nope', stock: {}, peds: {}, worn: { k: 'x', id: 1 }, edit: {
    sex: 'f', editing: '', dirty: true, cat: 'hair', undo: true, redo: 'yes',
    extras: ['tattoos', 'nope', 'hat'],
    rows: [
      { k: 'c2', cat: 'hair', kind: 'count', v: 3, n: 80, colors: 64, name: 'Bun', pal: 'hair', c: 7 },
      { k: 'c11', cat: 'top', kind: 'count', v: 3, n: 9, colors: 2, name: '', pal: 'paint', c: -1 },
      { k: 'c4', cat: 'legs', kind: 'count', v: 1, n: 9, colors: 2, c: 1, sw: ['#112233', '#445566'] },
      { k: 'c6', cat: 'shoes', kind: 'count', v: 1, n: 9, colors: 3, sw: ['#112233', 'red', '#445566'] },
      { k: 'bad', cat: 'face', kind: 'count', v: 'x' }, 'junk',
    ],
  } })
  eq('envelope: {} lists are empty lists, an unknown tab is Stock, a malformed worn is none',
    [p.stock, p.peds, p.tab, p.worn], [[], [], 'stock', null])
  eq('envelope: the extras on the look, known ones only, in Lua\'s order', p.edit.extras, ['tattoos', 'hat'])
  eq('envelope: undo and redo are booleans', [p.edit.undo, p.edit.redo], [true, false])
  eq('envelope: a row\'s name, palette and color only when they are one',
    p.edit.rows.map((r) => [r.k, r.name ?? null, r.pal ?? null, r.c ?? null]),
    [['c2', 'Bun', 'hair', 7], ['c11', null, null, null], ['c4', null, null, 1], ['c6', null, null, null]])
  eq('envelope: an item\'s colors only whole -- one #rrggbb a texture -- else none',
    p.edit.rows.map((r) => r.sw ?? null), [null, null, ['#112233', '#445566'], null])
  eq('envelope: nothing at all is Season 1, and no extras', [parseLocker2(undefined).on,
    parseLocker2({ edit: { sex: 'm', rows: [] } }).edit.extras], [false, []])
}
eq('zoom: root px / 14, and 1 for nonsense', [zoomFor(28), zoomFor(Number.NaN)], [2, 1])

// ── COPY ─────────────────────────────────────────────────────────────────────
eq('the owner\'s words, verbatim', [TITLE.home, BTN.new, CARD.custom, CARD.stock, BTN.randomize, BTN.undo, BTN.redo,
  SEX_LABEL.m, SEX_LABEL.f, BTN.back, BTN.done],
['My Looks', 'New', 'Custom', 'Stock GTA Looks', 'Randomize', 'Undo', 'Redo', 'Male', 'Female', 'Back', 'Done'])
eq('a look, never a ped, in the dialogs', [MODAL.name, MODAL.rename, MODAL.save, MODAL.discard, deleteTitle('Ranger')],
  ['Name your look', 'Rename look', 'Save look', 'Discard changes?', 'Delete Ranger?'])
{
  const copy = read(join(L2, 'copy.ts'))
  const strings = [...strip(copy).matchAll(/'([^'\n]*)'|`([^`\n]*)`/g)].map((m) => m[1] ?? m[2])
  const peds = strings.filter((s) => /\bpeds?\b/i.test(s))
  check('no player-facing word says "ped"', peds.length === 0, peds.join(' | '))
  // #28 review: "Save as new" was marked OWNER with a quote he never wrote, so
  // it would never have been put to him. A label is his only if it is on this
  // list -- the labels he gave or named on #28 -- and every other is WRITTEN.
  const OWNER_LABELS = ['Add more', 'Back', 'Create', 'Custom', 'Delete', 'Done', 'Edit', 'Female', 'Last', 'Male',
    'My Looks', 'New', 'Next', 'Randomize', 'Redo', 'Rename', 'Reset', 'Save', 'Stock GTA Looks', 'Undo']
  const owned = [...new Set(copy.split('\n').filter((l) => l.includes('// OWNER'))
    .map((l) => /'([^']*)'/.exec(l)?.[1] ?? '?'))].sort()
  eq('a label marked OWNER is one he gave or named on #28, and no other', owned, OWNER_LABELS)
  const marked = copy.split('\n').filter((l) => /^\s+\w+: ['`]/.test(l) || /=> `/.test(l))
  const unmarked = marked.filter((l) => !l.includes('// OWNER') && !l.includes('// WRITTEN (proposal for the owner)'))
  check('every label is marked OWNER or WRITTEN', marked.length > 100 && unmarked.length === 0, unmarked.join(' | '))
  for (const s of ["'Save as new'", "'Fine-tune'", "'More'", "'Name your look'", "'Save look'", "'Rename look'",
    "'Rotate left'", "'Rotate right'", "'Turn around'", "'Zoom in'", "'Zoom out'", "'Reset view'", '`Color ${n}`',
    "'Nose'", "'Eyes and lips'", "'Neck'", "'Skin'", "'Top'", "'Accessory'", "'Tattoos'", "'Cancel'",
    "'Keep editing'", "'Discard'", '`Delete ${name}?`', '`${base} opacity`', '`Tattoo ${n}`']) {
    const line = copy.split('\n').find((l) => l.includes(s))
    check(`WRITTEN marker beside ${s}`, line !== undefined && line.includes('// WRITTEN (proposal for the owner)'))
  }
  eq('the camera buttons\' names', Object.values(CAM),
    ['Rotate left', 'Rotate right', 'Turn around', 'Zoom in', 'Zoom out', 'Reset view'])
  eq('"Add more" and "Create" as he gave them; "Next color" and "+ Add" gone',
    [BTN.addMore, BTN.create, 'nextColor' in BTN, 'addExtra' in BTN, 'add' in BTN], ['Add more', 'Create', false, false, false])
}

// ── CORNERS ("remember our Lobby UI has no rounded edges") ───────────────────
{
  const typings = read(join(ROOT, 'node_modules', '@cloudscape-design', 'components', 'internal', 'generated', 'theming',
    'index.d.ts'))
  const radii = [...new Set([...typings.matchAll(/\b(borderRadius[A-Za-z]+)\??:/g)].map((m) => m[1]))]
  const tokens = LOCKER_THEME.tokens
  const round = radii.filter((k) => tokens[k] !== '0px')
  check(`every radius token the installed Cloudscape has is 0px in the theme (${radii.length} tokens)`,
    radii.length > 20 && round.length === 0, round.join(', '))
  const css = strip(read(join(L2, 'lockerv2.css')))
  check('the stylesheet squares what no token reaches: everything in the island, and the slider\'s thumb',
    /\.br-cs \*,\s*\.br-cs \*::before,\s*\.br-cs \*::after \{\s*border-radius: 0 !important;\s*\}/.test(css)
    && /\.br-cs input\[type='range'\]::-webkit-slider-thumb \{\s*border-radius: 0 !important;\s*\}/.test(css))
  eq('the lobby\'s colors: the primary is cyan with the ink on it, the plate is Btn\'s default',
    [tokens.colorBackgroundButtonPrimaryDefault, tokens.colorTextButtonPrimaryDefault,
      tokens.colorBackgroundButtonNormalDefault, tokens.colorBorderButtonNormalDefault, tokens.borderWidthButton],
    ['#22d3ee', '#04222a', 'rgba(32, 36, 50, 0.94)', 'rgba(255, 255, 255, 0.30)', '1px'])
  check('hover is no new color (the lobby brightens instead)',
    tokens.colorBackgroundButtonNormalHover === tokens.colorBackgroundButtonNormalDefault
    && tokens.colorBackgroundButtonPrimaryHover === tokens.colorBackgroundButtonPrimaryDefault)
  check('the lobby\'s gradient, Anton in capitals, the press travel and the hover brightening, on Cloudscape\'s buttons',
    css.includes("background-image: linear-gradient(180deg, rgba(255, 255, 255, 0.1), rgba(255, 255, 255, 0.015) 46%) !important;")
    && /text-transform: uppercase !important;/.test(css)
    && /transform: translateY\(1px\) scale\(0\.975\) !important;\s*filter: brightness\(0\.94\) !important;/.test(css)
    && /filter: brightness\(1\.18\) !important;/.test(css))
  const index = read(join(SRC, 'index.css'))
  check('...which are the lobby\'s own numbers (index.css .plate and .btn)',
    index.includes('linear-gradient(180deg, rgba(255, 255, 255, 0.10), rgba(255, 255, 255, 0.015) 46%)')
    && index.includes('.btn:active { transform: translateY(1px) scale(0.975); filter: brightness(0.94); }')
    && index.includes('.btn:hover  { filter: brightness(1.18); }'))
}

// ── THE HARNESS (bridge/mockLocker2.ts, Lua's stand-in) ──────────────────────
register('data:text/javascript,' + encodeURIComponent(`
export async function resolve(spec, ctx, next) {
  try { return await next(spec, ctx) } catch (e) {
    if ((spec.startsWith('./') || spec.startsWith('../')) && !/\\.[cm]?[jt]sx?$/.test(spec)) return next(spec + '.ts', ctx)
    throw e
  }
}`))
{
  const timers = []
  globalThis.window = { location: { search: '' }, setTimeout: (fn) => { timers.push(fn); return timers.length } }
  const flush = () => { while (timers.length) timers.shift()() }
  const { createLocker2Mock } = await import(pathToFileURL(join(SRC, 'bridge', 'mockLocker2.ts')).href)
  const sent = []
  const m = createLocker2Mock([{ id: 'street', name: 'Street' }], (env) => sent.push(env))
  const last = () => [...sent].reverse().find((e) => e.k === 'locker2')?.d
  const h = (name, d) => m.handle(`br/locker2/${name}`, d)
  h('open')
  check('open: the saved looks are fetched first (the loading marker)', last().fetching === true && last().peds.length === 0)
  flush()
  check('then they arrive, with spaces in a name', last().fetching === false && last().peds.some((p) => p.name === 'Ghost Rider'))
  h('new', { sex: 'f', seq: 7 })
  let e = last().edit
  check('New: a female draft, numbered, no extras, unsaved, nothing to undo',
    last().tab === 'female' && last().tabSeq === 7 && e.sex === 'f' && e.extras.length === 0 && e.dirty && !e.undo && !e.redo)
  check('the core randomized: every core category has its rows and a starting face; the hair and the clothes off their defaults',
    CORE_CATS.every((c) => e.rows.some((r) => r.cat === c)) && e.rows.some((r) => r.k === 'shape')
    && e.rows.find((r) => r.k === 'c2').v >= 2
    && ['c11', 'c4', 'c6', 'sk', 'e'].some((k) => e.rows.find((r) => r.k === k).v > 1))
  const top0 = e.rows.find((r) => r.k === 'c11').v
  h('step', { k: 'c11', d: 1 })
  h('step', { k: 'c11', d: 1 })
  e = last().edit
  check('two quick steps of one row: one undo step', e.undo && e.rows.find((r) => r.k === 'c11').v !== top0)
  h('undo')
  e = last().edit
  check('Undo puts the top back, and Redo is lit', e.rows.find((r) => r.k === 'c11').v === top0 && e.redo && !e.undo)
  h('redo')
  check('Redo goes forward again', last().edit.rows.find((r) => r.k === 'c11').v !== top0)
  h('extra', { id: 'hat', on: true })
  e = last().edit
  check('+ Add: the hat is on the look, on its first item', e.extras.join() === 'hat' && e.rows.find((r) => r.k === 'p0').v === 2)
  h('extra', { id: 'hat', on: false })
  e = last().edit
  check('its trash icon: off the look, and back to none', e.extras.length === 0 && e.rows.find((r) => r.k === 'p0').v === 1)
  h('undo')
  check('and Undo brings it back', last().edit.extras.join() === 'hat')
  h('extra', { id: 'tattoos', on: true })
  h('extra', { id: 'earrings', on: true })
  eq('the extras keep the order they were put on: earrings after tattoos stays after them',
    last().edit.extras, ['hat', 'tattoos', 'earrings'])
  {
    // "the randomize button should randomize those additional categories too,
    // and add them to the list when it sets them" (owner, 2026-10-14)
    const seen = new Set()
    let kept = true
    let whole = true
    for (let n = 0; n < 40; n++) {
      const before = last().edit.extras
      h('random')
      const after = last().edit.extras
      for (const c of after) seen.add(c)
      const stayed = before.filter((c) => after.includes(c))
      if (after.slice(0, stayed.length).join() !== stayed.join()) kept = false
      const rows = last().edit.rows
      for (const c of after) {
        if (c === 'tattoos') { if (last().edit.tats.length === 0) whole = false; continue }
        if (c !== 'makeup' && !rows.some((x) => x.cat === c && x.kind === 'count' && x.v > 1)) whole = false
      }
    }
    check('Randomize puts extras on and takes them off', seen.size >= 6, [...seen].join())
    check('...each one it puts on wears something, and Tattoos some tattoos', whole)
    check('...the ones it keeps keep their places, the ones it adds join the end', kept)
    const before = JSON.stringify(last().edit)
    h('random')
    h('undo')
    const back = last().edit
    check('...and one Undo puts the whole look back, extras and tattoos with it',
      JSON.stringify({ ...back, undo: false, redo: false }) === JSON.stringify({ ...JSON.parse(before), undo: false, redo: false }))
    h('redo')
  }
  for (let n = 0; n < 20 && last().edit.extras.length > 0; n++) h('extra', { id: last().edit.extras[0], on: false })
  h('extra', { id: 'hat', on: true })
  h('color', { k: 'c2', c: 40 })
  check('a swatch sets that color', last().edit.rows.find((r) => r.k === 'c2').c === 40)
  h('set', { k: 'ff3', v: 60 })
  h('defaults', { ks: ['ff3'] })
  check('a face group\'s reset puts its sliders back', last().edit.rows.find((r) => r.k === 'ff3').v === 0)
  sent.length = 0
  h('pal')
  check('the palettes come once as a locker2pal, 64 colors each',
    sent.some((x) => x.k === 'locker2pal' && x.d.hair.length === 64 && x.d.makeup.length === 64))
  h('save', { op: 'new', name: 'Night Owl' })
  flush()
  e = last().edit
  const owl = last().peds.find((p) => p.name === 'Night Owl')
  check('Save, a new look: saved by name, now the look being edited, nothing unsaved', owl && e.editing === owl.id && !e.dirty)
  h('step', { k: 'c4', d: 1 })
  h('save', { op: 'update', id: owl.id, name: 'Night Owl 2' })
  flush()
  check('Save, a saved look: updated in place and renamed, no new look',
    last().peds.filter((p) => p.name.startsWith('Night Owl')).map((p) => p.name).join() === 'Night Owl 2'
    && !last().edit.dirty)
  h('step', { k: 'c4', d: 1 })
  h('save', { op: 'new', name: 'Owl Three' })
  flush()
  check('Save as new: a second look, the first untouched',
    last().peds.some((p) => p.name === 'Owl Three') && last().peds.some((p) => p.name === 'Night Owl 2'))
  h('leave', { seq: 8 })
  check('Leave: no draft, numbered', last().edit === null && last().tabSeq === 8)
  h('edit', { id: owl.id, seq: 9 })
  check('Edit: the saved look\'s draft, its extras as worn', last().edit?.editing === owl.id && last().tabSeq === 9
    && last().edit.extras.join() === 'hat')
}

// ── UNDO, EVERY KIND OF CHANGE (the harness) ─────────────────────────────────
// Undo / Redo across every kind of change (#28): each of these is one step,
// Undo puts the look back exactly as it was, and Redo brings the change back.
// The review turned a tattoo's Add and a face group's reset into changes that
// skipped the history, and nothing noticed.
{
  const timers = []
  globalThis.window = { location: { search: '' }, setTimeout: (fn) => { timers.push(fn); return timers.length } }
  const { createLocker2Mock } = await import(pathToFileURL(join(SRC, 'bridge', 'mockLocker2.ts')).href)
  const sent = []
  const m = createLocker2Mock([{ id: 'street', name: 'Street' }], (env) => sent.push(env))
  const h = (name, d) => m.handle(`br/locker2/${name}`, d)
  const last = () => [...sent].reverse().find((e) => e.k === 'locker2')?.d
  h('open')
  while (timers.length) timers.shift()()
  h('new', { sex: 'f', seq: 1 })
  h('tats', { sex: 'f' })
  const zones = [...sent].reverse().find((e) => e.k === 'locker2tats').d.zones
  const torso = zones.find((z) => z.z === 'torso').items.map((t) => t.i)
  const look = () => JSON.stringify({ rows: last().edit.rows, tats: last().edit.tats, extras: last().edit.extras })
  const row = (k) => last().edit.rows.find((r) => r.k === k)
  const tat = () => last().edit.tats[0]
  {
    const t = () => last().edit.tats
    h('tatadd', { z: 'torso' })
    h('tatadd', { z: 'torso', i: 999 })
    h('tatadd', { z: 'head', i: torso[0] })
    check('a tattoo is added only by its zone AND a tattoo of that zone', t().length === 0)
    h('tatadd', { z: 'torso', i: torso[2] })
    h('tatadd', { z: 'torso', i: torso[2] })
    eq('...once a zone: the same one twice is refused', t().map((x) => [x.z, x.i]), [['torso', torso[2]]])
    h('undo')
  }
  const CHANGES = [
    ['an arrow press', () => h('step', { k: 'c11', d: 1 })],
    ['an arrow held (a step a repeat)', () => { for (let i = 0; i < 12; i++) h('step', { k: 'c4', d: 1 }) }],
    ['a starting face', () => h('set', { k: 'shape', v: (row('shape').v % row('shape').n) + 1 })],
    ['a swatch', () => h('color', { k: 'c2', c: (row('c2').c + 7) % 64 })],
    ['a slider dragged', () => { for (const v of [10, 25, 40, 55]) h('set', { k: 'ff3', v }) }],
    ['an extra added', () => h('extra', { id: 'hat', on: true })],
    ['an extra removed (its trash icon)', () => h('extra', { id: 'hat', on: false })],
    ['Tattoos added', () => h('extra', { id: 'tattoos', on: true })],
    ['a tattoo added', () => h('tatadd', { z: 'torso', i: torso.find((i) => !last().edit.tats.some((t) => t.i === i)) })],
    ['a tattoo changed', () => h('tatset', { r: tat().r, i: torso.find((i) => i !== tat().i) })],
    ['a tattoo removed', () => h('tatdel', { r: tat().r })],
    ['a face group\'s reset', () => h('defaults', { ks: FACE_GROUPS[0].ks })],
    ['a texture swatch', () => h('color', { k: 'c11', c: (row('c11').c + 1) % row('c11').colors })],
    ['Randomize', () => h('random')],
  ]
  for (const [what, act] of CHANGES) {
    if (what === 'a tattoo changed' || what === 'a tattoo removed') {
      if (last().edit.tats.length === 0) h('tatadd', { z: 'torso', i: torso[0] })
    }
    if (what === 'a face group\'s reset') h('set', { k: 'ff0', v: 30 })
    if (what === 'a texture swatch') for (let n = 0; n < 40 && row('c11').colors < 2; n++) h('step', { k: 'c11', d: 1 })
    const before = look()
    act()
    const after = look()
    h('undo')
    const undone = look()
    h('redo')
    check(`Undo / Redo: ${what} is one step, undone exactly and redone`,
      after !== before && undone === before && look() === after, `changed ${after !== before}, undone ${undone === before}`)
  }
}

// ── THE SCREEN, RENDERED (#28 review) ────────────────────────────────────────
// The review reverted agreed pieces one at a time -- a card press that no
// longer wore the look, the worn mark, Fine-tune open from the start, the
// camera under the panel, Custom's focus, Randomize's label, a random button
// on every row, helper text under Custom -- and the source checks did not
// notice. So the screen's own components are rendered (lockerv2-render.mjs),
// pressed through their own handlers, and answered by the browser harness, as
// the preview runs them.
{
  const { loadScreen, fakePage, mount, textOf, hasClass, press } = await import('./lockerv2-render.mjs')
  const { AWAY_ATTR } = await import('../src/tutorial/progress.ts')
  const page = fakePage()
  const Scr = await loadScreen()
  const R = globalThis.__lk2r
  const { createLocker2Mock } = await import(pathToFileURL(join(SRC, 'bridge', 'mockLocker2.ts')).href)
  const env = []
  const STOCK = [{ id: 'street', name: 'Street' }, { id: 'diver', name: 'Diver' }, { id: 'medic', name: 'Medic' }]
  const mock = createLocker2Mock(STOCK, (e) => env.push(e))
  let delivered = 0
  let handled = 0
  /** What the page sent goes to the harness, and its answers to the store, until quiet. */
  const settle = (v) => {
    for (let n = 0; n < 30; n++) {
      for (; handled < R.calls.length; handled++) mock.handle(R.calls[handled][0], R.calls[handled][1] ?? {})
      page.frames()
      for (; delivered < env.length; delivered++) {
        const e = env[delivered]
        if (e.k === 'locker2') R.state = { ...R.state, locker2: share(R.state.locker2, parseLocker2(e.d)) }
        else if (e.k === 'locker2pal') Scr.keepPal(e.d)
        else if (e.k === 'locker2tats') Scr.keepTats(e.d)
      }
      v.render()
      if (handled === R.calls.length && delivered === env.length) return
    }
  }
  R.state = { settings: {}, focus: 'locker', tutorialRun: false, tutorialHeading: null, locker2: parseLocker2({ on: true }) }
  const v = mount(Scr.React, Scr.React.createElement(Scr.LockerV2))
  settle(v)

  const L2S = () => R.state.locker2
  const q = (pred) => v.all(pred)
  const first = (pred) => q(pred)[0]?.node
  const cls = (c) => (n) => hasClass(n, c)
  const csBtn = (label) => (n) => n.type === 'cs:button' && textOf(n) === label
  const within = (x, c) => x.parents.some((p) => hasClass(p, c))
  const subtree = (n) => [n, ...n.children.filter((c) => typeof c !== 'string').flatMap(subtree)]
  const plates = (n) => subtree(n).filter((x) => hasClass(x, 'plate'))
  const lit = (n) => plates(n).some((x) => hasClass(x, 'is-active'))
  const sentSince = (k) => R.calls.slice(k).map(([cb, d]) => [cb, d])
  const act = (fn) => { const k = R.calls.length; v.act(fn); const out = sentSince(k); settle(v); return out }
  const title = () => textOf(first(cls('lk2-title')) ?? { children: [] })
  const tut = (x) => [x.node, ...x.parents].some((p) => p.props['data-tut'] === 'locker-done')
  const awayMarks = () => q((n) => String(n.props[AWAY_ATTR] ?? '').split(/\s+/).includes('locker-done'))
  /** Every word drawn and every accessible name is copy.ts's, or the look's own data. */
  const COPY = new Set([TITLE, CARD, SEX_LABEL, BTN, MODAL, CAM, CAT_LABEL, GROUP_LABEL, ZONE_LABEL, ROW_LABEL]
    .flatMap((o) => Object.values(o)))
  const strayWords = () => {
    const d = L2S()
    const data = new Set([...d.peds.map((p) => p.name), ...d.stock.map((p) => p.name)])
    for (const r of d.edit?.rows ?? []) {
      if (r.name) data.add(r.name)
      if (r.kind === 'count') { data.add(counterText(r.v, r.n)); for (let i = 1; i <= r.n; i++) data.add(String(i)) }
      const l = rowLabel(r.k); if (l) data.add(l)
    }
    if (d.edit) for (const c of listedCats(d.edit.extras)) data.add(summaryOf(c, d.edit.rows, d.edit.tats.length).text)
    const stray = []
    for (const { node } of q(() => true)) {
      for (const c of node.children) if (typeof c === 'string' && c.trim() && !COPY.has(c) && !data.has(c)) stray.push(c)
      for (const a of ['aria-label', 'ariaLabel', 'placeholder', 'title', 'description']) {
        const s = node.props[a]
        if (typeof s === 'string' && !COPY.has(s) && !data.has(s) && !/^Color \d+$/.test(s)) stray.push(`${a}=${s}`)
      }
    }
    return stray
  }

  // MY LOOKS ------------------------------------------------------------------
  const cards = () => q(cls('lk2-card'))
  const cardOf = (name) => cards().find((x) => textOf(x.node) === name)
  check('My Looks: the heading, New at the top, and a card per saved look',
    title() === 'My Looks' && q(csBtn('New')).length === 1 && L2S().peds.length === 3
    && cards().map((x) => textOf(x.node)).join() === L2S().peds.map((p) => p.name).join())
  check('My Looks: no word on it that is not copy.ts\'s or the looks\' own', strayWords().length === 0, strayWords().join(' | '))
  const pick = L2S().peds[1]
  const mainOf = (name) => subtree(cardOf(name).node).find((n) => hasClass(n, 'lk2-card-main'))
  eq('My Looks: pressing a card wears that look, at once', act(() => press(mainOf(pick.name))),
    [['br/locker2/wear', { k: 'p', id: pick.id }]])
  const marks = () => q(cls('lk2-card-mark'))
  check('...and that card, and only it, is marked as worn',
    marks().length === 1 && within(marks()[0], 'lk2-card') && marks()[0].parents.some((p) => textOf(p) === pick.name)
    && cards().filter((x) => subtree(x.node).some((n) => hasClass(n, 'lk2-card-mark'))).map((x) => textOf(x.node)).join() === pick.name)
  eq('...and lit as the lobby lights a selected plate, it alone', cards().map((x) => lit(x.node)),
    L2S().peds.map((p) => p.id === pick.id))
  eq('...and pressing the worn card again sends nothing', act(() => press(mainOf(pick.name))), [])
  const menu = subtree(cardOf(pick.name).node).find((n) => n.type === 'cs:button-dropdown')
  eq('a card\'s "..." menu: Edit, Rename, Delete', menu?.props.items.map((i) => [i.id, i.text]),
    [['edit', 'Edit'], ['rename', 'Rename'], ['delete', 'Delete']])

  // THE WALKTHROUGH'S "PRESS DONE" CARD (#28 review) --------------------------
  // Its ring is on Done, and a press inside the ring ends the card. Back in
  // every inner view sat inside it, so Back from the editor walked the player
  // on to "Spending Volts" with the locker still open.
  const ring = () => q((n) => n.props['data-tut'] === 'locker-done')
  const ringed = () => ring().flatMap((x) => subtree(x.node).filter((n) => n.type === 'cs:button').map(textOf))
  check('My Looks: the walkthrough\'s ring is on Done, and on nothing else',
    ring().length === 1 && ringed().join() === 'Done' && awayMarks().length === 0, `ringed ${ringed().join()}`)
  const backIsOut = () => q(csBtn('Back')).length === 1 && q(csBtn('Back')).every((x) => !tut(x))
  act(() => press(first(csBtn('New'))))
  check('New: Back is outside the ring, and the screen says Done is away (the card waits for it)',
    title() === 'New' && ring().length === 0 && backIsOut() && awayMarks().length === 1)

  // NEW -----------------------------------------------------------------------
  // "custom and "Stock GTA Peds" (custom is the default) and the custom card
  // itself has a dropdown within to select male or female"; then (2026-10-14)
  // "when I click "custom" or "stock gta looks" it should have a create
  // button, or not have either card selected by default"
  const choices = () => q(cls('lk2-choice'))
  const cardBtn = (k) => subtree(choices()[k].node).find((n) => n.type === 'button')
  const create = () => first(csBtn(BTN.create))
  eq('New: two cards, Custom first, then Stock GTA Looks, and not a word more', choices().map((x) => textOf(x.node)),
    ['Custom', 'Stock GTA Looks'])
  const focused = q((n) => n.props.autoFocus === true)
  check('New: Custom is the default -- the one thing focused, its press the keyboard\'s',
    focused.length === 1 && within(focused[0], 'lk2-choice') && textOf(focused[0].node) === 'Custom')
  check('New: Custom is selected as it opens, lit, Stock GTA Looks is not',
    choices().length === 2 && lit(choices()[0].node) && !lit(choices()[1].node)
    && cardBtn(0).props['aria-checked'] === true && cardBtn(1).props['aria-checked'] === false)
  const sex = () => subtree(choices()[0].node).find((n) => n.type === 'cs:select')
  eq('New: Custom\'s own dropdown, Male / Female', sex()?.props.options.map((o) => o.label), ['Male', 'Female'])
  check('New: Create at the foot, beside Back', create() !== undefined && within(q((n) => n === create())[0], 'lk2-foot'))
  check('New: no word on it that is not copy.ts\'s', strayWords().length === 0, strayWords().join(' | '))
  eq('New: a press on Stock GTA Looks only selects it -- nothing sent, still New', act(() => press(cardBtn(1))), [])
  check('...and lights it, and not Custom', title() === 'New' && lit(choices()[1].node) && !lit(choices()[0].node))
  // THE DROPDOWN IS CUSTOM'S (#28 review: a pick in it with Stock GTA Looks
  // selected left Stock selected, and Create opened the roster). A pick in it
  // selects Custom, however it was opened; so does pressing it.
  const subBox = () => subtree(choices()[0].node).find((n) => hasClass(n, 'lk2-choice-sub'))
  v.act(() => sex().props.onChange({ detail: { selectedOption: { value: 'f', label: 'Female' } } }))
  settle(v)
  check('New: Female picked with Stock GTA Looks selected: Custom is selected',
    lit(choices()[0].node) && !lit(choices()[1].node) && cardBtn(0).props['aria-checked'] === true)
  v.act(() => sex().props.onChange({ detail: { selectedOption: { value: 'm', label: 'Male' } } }))
  act(() => press(cardBtn(1)))
  eq('...and pressing the dropdown, with Stock GTA Looks selected, selects Custom too: nothing sent',
    [act(() => press(subBox())), lit(choices()[0].node), lit(choices()[1].node)], [[], true, false])
  act(() => press(cardBtn(1)))

  // STOCK GTA LOOKS ------------------------------------------------------------
  eq('Create, Stock GTA Looks selected: the roster, nothing sent', act(() => press(create())), [])
  const tiles = () => q(cls('lk2-tile'))
  check('Stock GTA Looks: the roster, Back outside the ring, Done away',
    title() === 'Stock GTA Looks' && tiles().map((x) => textOf(x.node)).join() === STOCK.map((s) => s.name).join()
    && ring().length === 0 && backIsOut() && awayMarks().length === 1)
  eq('Stock GTA Looks: a press wears it at once', act(() => press(tiles()[2].node)), [['br/locker2/wear', { k: 's', id: 'medic' }]])
  check('...and it is the one lit', tiles().map((x) => lit(x.node)).join() === 'false,false,true')
  act(() => press(first(csBtn('Back'))))

  // THE EDITOR ------------------------------------------------------------------
  act(() => press(cardBtn(0)))
  v.act(() => sex().props.onChange({ detail: { selectedOption: { value: 'f', label: 'Female' } } }))
  check('New: picking Female sends nothing yet', title() === 'New' && q(cls('lk2-editor')).length === 0)
  const started = act(() => press(create()))
  check('Create, Custom and Female picked: a new female look (LOCKER2_NEW, numbered), and the editor',
    started[0]?.[0] === 'br/locker2/new' && started[0][1].sex === 'f' && typeof started[0][1].seq === 'number'
    && q(cls('lk2-editor')).length === 1 && L2S().edit?.sex === 'f')
  check('the editor: Back outside the ring, Done away', ring().length === 0 && backIsOut() && awayMarks().length === 1)
  const stripBtns = () => q((n) => n.type === 'cs:button').filter((x) => within(x, 'lk2-strip'))
  eq('the strip: Randomize, Undo, Redo', stripBtns().map((x) => textOf(x.node)), ['Randomize', 'Undo', 'Redo'])
  const lines = () => q(cls('lk2-line'))
  const lineLabel = (x) => textOf(subtree(x.node).find((n) => hasClass(n, 'lk2-line-label')))
  eq('the list: the core, one line each, nothing else on a new look', lines().map(lineLabel),
    CORE_CATS.map((c) => CAT_LABEL[c]))
  const randoms = () => q((n) => textOf(n) === BTN.randomize && n.children.every((c) => typeof c === 'string')
    || n.props['aria-label'] === BTN.randomize || n.props.ariaLabel === BTN.randomize)
  const rowLabels = () => q(cls('lk2-row-label')).filter((x) => within(x, 'lk2-panel') && !within(x, 'lk2-group'))
    .map((x) => textOf(x.node))
  for (const cat of CORE_CATS) {
    const line = () => lines().find((x) => lineLabel(x) === CAT_LABEL[cat])
    const sentNow = act(() => press(subtree(line().node).find((n) => hasClass(n, 'lk2-line-main'))))
    const want = panelRows(L2S().edit.rows, cat).map((r) => rowLabel(r.k)).filter(Boolean)
    check(`${CAT_LABEL[cat]}: pressing its line lights it, moves the camera, and shows its rows only`,
      sentNow.some(([cb, d]) => cb === 'br/locker2/cat' && d.cat === cat) && lit(line().node)
      && lines().filter((x) => lit(x.node)).length === 1 && rowLabels().join() === want.join(), rowLabels().join())
    check(`${CAT_LABEL[cat]}: Randomize is the strip's alone -- no random button on a row`, randoms().length === 1)
    check(`${CAT_LABEL[cat]}: no word that is not copy.ts's or the look's`, strayWords().length === 0, strayWords().join(' | '))
  }
  // "All or nothing on that": the harness names most tops and hair, as the
  // game does, and none of it is drawn.
  {
    const named = L2S().edit.rows.filter((r) => r.name !== undefined)
    const drawn = q(() => true).flatMap((x) => x.node.children.filter((c) => typeof c === 'string'))
    check(`the game's names, where it has them, are drawn nowhere (${named.length} named rows)`,
      named.length > 0 && named.every((r) => !drawn.includes(r.name)) && q(cls('lk2-caption')).length === 0)
    check('every summary line is the item\'s place in its list',
      lines().slice(1).every((x) => /^\d+\/\d+$/.test(textOf(subtree(x.node).find((n) => hasClass(n, 'lk2-line-text'))))))
  }

  // AN ITEM'S COLORS: a swatch button, never "Next color".
  {
    const topLine = () => lines().find((x) => lineLabel(x) === CAT_LABEL.top)
    act(() => press(subtree(topLine().node).find((n) => hasClass(n, 'lk2-line-main'))))
    for (let n = 0; n < 40 && L2S().edit.rows.find((r) => r.k === 'c11').colors < 3; n++) {
      act(() => press(q((n) => n.props['aria-label'] === BTN.next).find((x) => within(x, 'lk2-panel')).node))
    }
    const top = () => L2S().edit.rows.find((r) => r.k === 'c11')
    const texBtns = () => q(cls('lk2-texbtn'))
    check('Top: a swatch button for its colors, and no "Next color" anywhere',
      texBtns().length >= 1 && q((n) => textOf(n) === 'Next color' && n.children.every((c) => typeof c === 'string')).length === 0)
    const tb = () => texBtns()[0].node
    check('...wearing the color on (its place, the game having no color for it), named as that color',
      textOf(tb()) === String(top().c + 1) && tb().props['aria-label'] === `Color ${top().c + 1}` && tb().props['aria-expanded'] === false)
    act(() => press(tb()))
    const grid = () => q(cls('lk2-texgrid'))
    const tiles2 = () => subtree(grid()[0].node).filter((n) => n.type === 'button')
    check('...which opens the item\'s colors under the row, the one on lit',
      grid().length === 1 && tb().props['aria-expanded'] === true && tiles2().length === top().colors
      && tiles2().filter((n) => hasClass(n, 'is-active')).map(textOf).join() === String(top().c + 1))
    const other = (top().c + 1) % top().colors
    eq('...and a press on one sends that color, 0-based (LOCKER2_COLOR { k, c })', act(() => press(tiles2()[other])),
      [['br/locker2/color', { k: 'c11', c: other }]])
    check('...which the row then wears, the grid still open to try another',
      top().c === other && grid().length === 1 && textOf(tb()) === String(other + 1))
    act(() => press(tb()))
    check('...and the button closes it', grid().length === 0)
  }

  // FACE: starting faces, then "Fine-tune", closed until asked for.
  act(() => press(subtree(lines()[0].node).find((n) => hasClass(n, 'lk2-line-main'))))
  const faces = () => q(cls('lk2-face'))
  const shape = () => L2S().edit.rows.find((r) => r.k === 'shape')
  check('Face: one tile per starting face, the worn one lit',
    faces().length === shape().n && faces().filter((x) => lit(x.node)).map((x) => textOf(x.node)).join() === String(shape().v))
  const tune = () => first((n) => n.type === 'cs:toggle')
  check('Face: "Fine-tune" is there, and off -- the grouped sliders are hidden until it is pressed',
    tune()?.props.checked === false && textOf(tune()) === 'Fine-tune' && q(cls('lk2-group')).length === 0)
  v.act(() => tune().props.onChange({ detail: { checked: true } }))
  const groups = () => q(cls('lk2-group'))
  const resets = (g) => subtree(g.node).filter((n) => n.props['aria-label'] === BTN.reset)
  check('Fine-tune: seven groups, by what the features are, one reset each and no other',
    groups().map((g) => textOf(subtree(g.node).find((n) => hasClass(n, 'lk2-group-label')))).join()
      === FACE_GROUPS.map((g) => GROUP_LABEL[g.id]).join()
    && groups().every((g) => resets(g).length === 1))
  v.act(() => tune().props.onChange({ detail: { checked: false } }))

  // "ADD MORE" and the trash icon. "the plus button is too small. also change
  // the add button to say "add more"", and "why is the "add" dropdown wider
  // than it's parent button?"
  const add = () => q((n) => n.type === 'cs:button' && textOf(n) === BTN.addMore).find((x) => within(x, 'lk2-add'))?.node
  const menuItems = () => q((n) => n.props.role === 'menuitem')
  check('"Add more": the lobby\'s button with Cloudscape\'s own plus, saying it opens a menu, closed',
    add()?.props.iconName === 'add-plus' && add()?.props.ariaHaspopup === 'menu' && add()?.props.ariaExpanded === false
    && menuItems().length === 0 && q((n) => n.type === 'cs:button-dropdown').filter((x) => within(x, 'lk2-editor')).length === 0)
  act(() => press(add()))
  const addMenu = () => q(cls('lk2-menu'))
  eq('"Add more" opens its menu: every extra not on the look, in order', menuItems().map((x) => textOf(x.node)),
    addableExtras(L2S().edit.extras).map((c) => CAT_LABEL[c]))
  check('...in the list\'s column, under the button, inside the box that sizes the button -- so exactly its width',
    add()?.props.ariaExpanded === true && addMenu().length === 1 && within(addMenu()[0], 'lk2-addmore')
    && q((n) => n === add())[0].parents.some((p) => hasClass(p, 'lk2-addmore')) && within(addMenu()[0], 'lk2-add'))
  check('...and the screen leaves Escape to it while it is open (it says so: OPEN_POPUP)',
    add()?.props.ariaHaspopup !== undefined && add()?.props.ariaExpanded === true)
  {
    // A PRESS OUTSIDE IT SHUTS IT; one inside does not (#28 review: with that
    // gone the menu stayed open over the list).
    const down = (target) => { v.act(() => { for (const fn of page.listeners.get('pointerdown') ?? []) fn({ target }) }); settle(v) }
    const box = addMenu()[0].parents.find((p) => hasClass(p, 'lk2-addmore'))
    down(box.el)
    check('a press inside "Add more" keeps its menu open', menuItems().length > 0 && add()?.props.ariaExpanded === true)
    down(new globalThis.Node())
    check('...a press anywhere else shuts it', addMenu().length === 0 && add()?.props.ariaExpanded === false)
    act(() => press(add()))
  }
  {
    // ITS MENU IS NEVER CUT OFF (#28 review): inside the list's scroll box it
    // was cut off at the list's right edge, and scrolled it sideways.
    const css = strip(read(join(L2, 'lockerv2.css')))
    const scrollers = new Set([...css.matchAll(/\.br-cs \.([\w-]+) \{([^}]*)\}/g)]
      .filter((m) => /(^|\s|;)overflow(-[xy])?\s*:\s*(auto|scroll|hidden|clip)/.test(m[2])).map((m) => m[1]))
    scrollers.add('thin-scroll')
    const at = q((n) => n === add())[0]
    const box = at ? at.parents.slice(at.parents.findIndex((p) => hasClass(p, 'br-cs')) + 1)
      .filter((p) => String(p.props.className ?? '').split(/\s+/).some((c) => scrollers.has(c) || /^overflow-/.test(c))) : null
    check('"Add more" sits in no scroll box below the island, so its menu is not cut off', box !== null && box.length === 0,
      (box ?? []).map((p) => p.props.className).join(' | '))
    check('...its menu a plate\'s width of its box, never set wider (no width, min-width or inline-size of its own)',
      /\.br-cs \.lk2-menu \{[^}]*\}/.test(css) && !/(^|;|\s)(min-)?(width|inline-size)\s*:/.test(/\.br-cs \.lk2-menu \{([^}]*)\}/.exec(css)?.[1] ?? 'width:'))
  }
  const pickMenu = (label) => act(() => press(menuItems().find((x) => textOf(x.node) === label).node))
  const added = pickMenu('Hat')
  check('"Add more" Hat: on the look, its line after the core with a trash icon, its panel open, the menu shut',
    added.some(([cb, d]) => cb === 'br/locker2/extra' && d.id === 'hat' && d.on === true)
    && lines().map(lineLabel).join() === [...CORE_CATS.map((c) => CAT_LABEL[c]), 'Hat'].join()
    && lit(lines()[6].node) && subtree(lines()[6].node).some((n) => n.props['aria-label'] === BTN.remove)
    && menuItems().length === 0)
  check('...and its line is scrolled into view (the lines scroll; "Add more" stands below them)',
    lines()[6].node.el?.scrolled > 0)
  check('no line of the core has a trash icon', lines().slice(0, 6).every((x) => !subtree(x.node).some((n) => n.props['aria-label'] === BTN.remove)))
  // "adding earrings after adding tattoos should not show tattoos on the bottom of the list"
  act(() => press(add()))
  pickMenu('Tattoos')
  act(() => press(add()))
  pickMenu('Earrings')
  eq('extras listed in the order put on: Hat, Tattoos, then Earrings', lines().slice(6).map(lineLabel), ['Hat', 'Tattoos', 'Earrings'])
  for (const c of ['earrings', 'tattoos']) {
    act(() => press(subtree(lines().find((x) => lineLabel(x) === CAT_LABEL[c]).node).find((n) => n.props['aria-label'] === BTN.remove)))
  }
  const trash = subtree(lines()[6].node).find((n) => n.props['aria-label'] === BTN.remove)
  eq('its trash icon takes it off', act(() => press(trash)), [['br/locker2/extra', { id: 'hat', on: false }]])
  check('...and its line is gone', lines().length === 6)
  check('Undo lit after a change, and it asks Lua', stripBtns()[1].node.props.disabled === false
    && act(() => press(stripBtns()[1].node))[0]?.[0] === 'br/locker2/undo')
  {
    // "the randomize button should randomize those additional categories too,
    // and add them to the list when it sets them"
    let grew = false
    for (let n = 0; n < 20 && !grew; n++) {
      const sent = act(() => press(stripBtns()[0].node))
      if (sent.length !== 1 || sent[0][0] !== 'br/locker2/random') break
      grew = lines().length > 6 && lines().slice(6).map(lineLabel).join() === L2S().edit.extras.map((c) => CAT_LABEL[c]).join()
    }
    check('Randomize asks for the whole look, and the extras it puts on are listed, in its order', grew)
    for (let n = 0; n < 20 && lines().length > 6; n++) {
      act(() => press(subtree(lines()[6].node).find((n) => n.props['aria-label'] === BTN.remove)))
    }
  }
  {
    // EVERY EXTRA ON: "Add more" has nothing left to offer, so it is off, and
    // a press opens nothing (#28 review: it stayed lit and opened an empty menu).
    for (let n = 0; n < 20 && addableExtras(L2S().edit.extras).length > 0; n++) {
      act(() => press(add()))
      const item = menuItems()[0]
      if (!item) break
      act(() => press(item.node))
    }
    check('every extra on the look: "Add more" is off',
      addableExtras(L2S().edit.extras).length === 0 && lines().length === 6 + EXTRA_CATS.length && add()?.props.disabled === true)
    act(() => press(add()))
    check('...and a press on it opens no menu', addMenu().length === 0 && add()?.props.ariaExpanded === false)
    for (let n = 0; n < 20 && lines().length > 6; n++) {
      act(() => press(subtree(lines()[6].node).find((n) => n.props['aria-label'] === BTN.remove)))
    }
  }

  // TATTOOS: "starting with a bunch of add buttons is not intuitive,
  // especially having to use a dropdown to navigate between them. fix that"
  {
    act(() => press(add()))
    pickMenu('Tattoos')
    const tats = () => first(cls('lk2-tats'))
    const tatAdds = () => q((n) => n.type === 'cs:button' && textOf(n) === BTN.addMore).filter((x) => within(x, 'lk2-tats'))
    const newRow = () => q(cls('lk2-tatnew'))
    const zonePick = () => subtree(newRow()[0].node).find((n) => n.type === 'cs:select')
    const tatPicks = (x) => subtree(x).filter((n) => n.type === 'cs:select')
    check('Tattoos, none on: one "Add more", off, and a new row asking the zone alone',
      tats() !== undefined && tatAdds().length === 1 && tatAdds()[0].node.props.disabled === true
      && newRow().length === 1 && tatPicks(newRow()[0].node).length === 1
      && q((n) => n.type === 'cs:attribute-editor').length === 0)
    eq('...its zones the body\'s six, by name', zonePick().props.options.map((o) => o.label), TATTOO_ZONES.map((z) => ZONE_LABEL[z]))
    const pickZone = (label) => act(() => zonePick().props.onChange({ detail: { selectedOption: zonePick().props.options.find((o) => o.label === label) } }))
    const zoneSent = pickZone('Torso')
    check('a zone picked: the camera goes there, nothing added yet, and the tattoo picker appears',
      zoneSent.some(([cb, d]) => cb === 'br/locker2/cat' && d.cat === 'tat_torso') && !zoneSent.some(([cb]) => cb === 'br/locker2/tatadd')
      && tatPicks(newRow()[0].node).length === 2)
    const tatPick = () => tatPicks(newRow()[0].node)[1]
    const opt = tatPick().props.options[2]
    eq('a tattoo picked: LOCKER2_TAT_ADD { z, i }, and the row goes',
      act(() => tatPick().props.onChange({ detail: { selectedOption: opt } })).filter(([cb]) => cb === 'br/locker2/tatadd'),
      [['br/locker2/tatadd', { z: 'torso', i: Number(opt.value) }]])
    const zones = () => q(cls('lk2-tatzone'))
    const zoneName = (x) => textOf(subtree(x.node).find((n) => hasClass(n, 'lk2-row-label')))
    check('...and it stands under its zone\'s name; "Add more" lit again',
      newRow().length === 0 && zones().map(zoneName).join() === 'Torso' && tatAdds()[0].node.props.disabled === false
      && L2S().edit.tats.length === 1)
    act(() => press(tatAdds()[0].node))
    pickZone('Head')
    act(() => tatPick().props.onChange({ detail: { selectedOption: tatPick().props.options[0] } }))
    eq('rows grouped under their zones, in the body\'s order, whatever order they were added in', zones().map(zoneName), ['Head', 'Torso'])
    check('a zone\'s picker leaves out what the zone already has', (() => {
      act(() => press(tatAdds()[0].node))
      pickZone('Torso')
      const have = L2S().edit.tats.filter((t) => t.z === 'torso').map((t) => String(t.i))
      const ok = tatPick().props.options.every((o) => !have.includes(o.value))
      act(() => press(subtree(newRow()[0].node).find((n) => n.props['aria-label'] === BTN.remove)))
      return ok && newRow().length === 0
    })())
    const torsoRow = () => q(cls('lk2-tatrow')).find((x) => within(x, 'lk2-tatzone') && x.parents.some((p) => hasClass(p, 'lk2-tatzone') && zoneName({ node: p }) === 'Torso'))
    const r0 = L2S().edit.tats.find((t) => t.z === 'torso')
    eq('a row\'s trash icon removes it (LOCKER2_TAT_DEL { r })',
      act(() => press(subtree(torsoRow().node).find((n) => n.props['aria-label'] === BTN.remove))).filter(([cb]) => cb === 'br/locker2/tatdel'),
      [['br/locker2/tatdel', { r: r0.r }]])
    check('Tattoos: no word that is not copy.ts\'s or the look\'s', strayWords().length === 0, strayWords().join(' | '))
    act(() => press(subtree(lines().find((x) => lineLabel(x) === CAT_LABEL.tattoos).node).find((n) => n.props['aria-label'] === BTN.remove)))
  }

  // Back with changes asks; it does not leave, and it does not end the card.
  const k0 = R.calls.length
  v.act(() => press(first(csBtn('Back'))))
  check('Back with changes asks first: nothing sent, the discard dialog up',
    R.calls.length === k0 && q((n) => n.type === 'cs:modal' && n.props.visible === true).length === 1)

  // THE CAMERA ------------------------------------------------------------------
  // "let's put them horizontal and across the bottom of the screen, on the
  // right half where the ped would be", and "a hover hint would be nice"
  const cluster = first(cls('lk2-cam'))
  const left = String(cluster?.props.style?.left ?? '')
  check(`the camera row is centered in the screen's right half, under the ped (${left})`,
    /^\d+(\.\d+)?%$/.test(left) && parseFloat(left) >= 50 && parseFloat(left) <= 80)
  {
    const css = strip(read(join(L2, 'lockerv2.css')))
    const rule = /\n\.lk2-cam \{([^}]*)\}/.exec(css)?.[1] ?? ''
    check('...a row across the foot of the screen: no column, the bottom set, centered on its left',
      /bottom:\s*3rem/.test(rule) && !/flex-direction:\s*column/.test(rule) && !/(^|\s|;)top:/.test(rule)
      && /transform:\s*translateX\(-50%\)/.test(rule))
    check('...each hint shown only while its button is hovered or focused, on one line',
      /\.lk2-cam \.lk2-cam-tip \{[^}]*white-space: nowrap;[^}]*opacity: 0;/.test(css)
      && /\.lk2-cam \.lk2-cam-btn:hover \+ \.lk2-cam-tip,\s*\.lk2-cam \.lk2-cam-btn:focus-visible \+ \.lk2-cam-tip \{[^}]*opacity: 1;/.test(css))
  }
  const camBtns = subtree(cluster).filter((n) => n.type === 'button')
  eq('the cluster: six buttons, by their names', camBtns.map((n) => n.props['aria-label']), Object.values(CAM))
  eq('...each with its hover hint, its name, beside it', subtree(cluster).filter((n) => hasClass(n, 'lk2-cam-tip')).map(textOf),
    Object.values(CAM))
  check('rotate left and right turn while held', camBtns.slice(0, 2).every((n) => typeof n.props.onPointerDown === 'function')
    && camBtns.slice(2).every((n) => n.props.onPointerDown === undefined))
  eq('each button sends its move', camBtns.map((n) => { const k = R.calls.length; press(n); return R.calls.slice(k).map(([cb, d]) => `${cb.split('/').pop()}:${d.op ?? (d.delta < 0 ? 'left' : 'right')}${d.d ?? ''}` ).join() }),
    ['spin:left', 'spin:right', 'cam:turn', 'cam:zoom1', 'cam:zoom-1', 'cam:reset'])

  // THE LOBBY'S PLATE, SELECTED BEVELS (#28 review) ---------------------------
  // In the lobby a selected plate opens its cut corners (index.css
  // `.plate.is-active`); the locker drew selection as a cyan edge on square
  // corners. Every plate of this screen's own is the lobby's `.plate`, lit
  // with `.is-active` -- checked view by view above -- and draws nothing of
  // its own over it.
  {
    const css = strip(read(join(L2, 'lockerv2.css')))
    const PLATES = ['lk2-card-main', 'lk2-tile', 'lk2-line', 'lk2-choice-plate', 'lk2-face', 'lk2-icon', 'lk2-tex',
      'lk2-texbtn']
    const own = [...css.matchAll(/([^{}]+)\{([^}]*)\}/g)]
      .filter((m) => PLATES.some((p) => new RegExp(`\\.${p}(?![\\w-])[^\\s,]*\\s*(,|$)`).test(m[1].trim())))
      .filter((m) => /(^|;|\s)(background(-image|-color)?|border(-color)?|clip-path)\s*:/.test(m[2]))
    check('the screen\'s plates take their fill, edge and bevel from the lobby\'s .plate, overriding none of it',
      own.length === 0, own.map((m) => m[1].trim()).join(' | '))
    check('...whose bevel opens on .is-active (index.css)', read(join(SRC, 'index.css')).includes('.plate.is-active { --cut: var(--cut-max); }'))
    check('...in the island\'s em, and lit in the lobby\'s selected colors',
      /\.br-cs \.plate \{[^}]*--cut-max: [\d.]+em;/.test(css)
      && /\.br-cs \.plate\.is-active \{[^}]*--plate-fill: rgba\(12, 58, 72, 0\.94\);[^}]*--edgec: #22d3ee;/.test(css))
  }
}

// ── FIT: NO WRAPPING, NO "...", EVERY BORDER DRAWN (owner, 2026-10-14) ───────
// "text wrapping should not be allowed. if you can't fit the text, don't draw
// it", and "please put in some change to ensure the borders always draw
// around everything which should have a border".
{
  const css = strip(read(join(L2, 'lockerv2.css')))
  // The two rules that wrap are the fit trick's own: .lk2-fit, and the same
  // trick on Cloudscape's option and picker labels.
  check('no rule ends text in "..." or lets a row of buttons or words wrap',
    !/text-overflow:\s*ellipsis/.test(css) && !/flex-wrap:\s*wrap/.test(css.replace(/\.br-cs \.lk2-fit \{[^}]*\}/, '')
      .replace(/\.br-cs \[class\*='awsui_label-content_'\],\s*\.br-cs button \[class\*='awsui_trigger_'\] \{[^}]*\}/, '')))
  check('a .lk2-fit box is one line tall, clips the rest, and moves text that does not fit, whole, onto the clipped line',
    /\.br-cs \.lk2-fit \{[^}]*display: flex;[^}]*flex-wrap: wrap;[^}]*height: calc\(var\(--fit-lh\) \* 1em\);[^}]*overflow: hidden;/.test(css)
    && /\.br-cs \.lk2-fit::before \{[^}]*content: '';[^}]*flex: 0 0 0px;/.test(css)
    && /\.br-cs \.lk2-fit > \* \{[^}]*flex: 0 0 auto;[^}]*white-space: nowrap;/.test(css))
  check('a button\'s words stay on one line', /\.br-cs \[class\*='awsui_button_'\] \{\s*white-space: nowrap !important;/.test(css))
  // Every text this screen writes is a .lk2-fit's own: the lines' labels and
  // summaries, the titles, the names, the row and group labels, the zones,
  // New's titles and the menu's items.
  const srcs = [join(SRC, 'screens', 'LockerV2.tsx'), ...['Editor.tsx', 'Rows.tsx', 'Home.tsx', 'NewLook.tsx', 'Tattoos.tsx'].map((f) => join(L2, f))]
    .map((f) => read(f)).join('\n')
  const FITTED = ['lk2-line-label', 'lk2-line-sum', 'lk2-title', 'lk2-card-name', 'lk2-tile-name', 'lk2-row-label',
    'lk2-group-label', 'lk2-choice-title', 'lk2-caption']
  const bare = FITTED.filter((c) => [...srcs.matchAll(new RegExp(`className=\\{?[\`"]([^\`"]*\\b${c}\\b[^\`"]*)[\`"]`, 'g'))]
    .some((m) => !/\blk2-fit\b/.test(m[1])) || !srcs.includes(c))
  check('every label, name and summary of the screen is a .lk2-fit', bare.length === 0, bare.join(', '))
  check('the menu\'s items are .lk2-fit text', /role="menuitem"[\s\S]{0,200}<span className="lk2-fit">/.test(read(join(L2, 'Editor.tsx'))))
  // Borders: the clip never shaves an edge, and no clipping box has one on its.
  check('the screen\'s plates are clipped a pixel outside their box, the bevel kept',
    /\.br-cs \.plate,\s*\.lk2-cam \.plate \{\s*clip-path: polygon\(\s*-1px -1px,\s*calc\(100% - var\(--cut\)\) -1px,\s*calc\(100% \+ 1px\) var\(--cut\),\s*calc\(100% \+ 1px\) calc\(100% \+ 1px\),\s*var\(--cut\) calc\(100% \+ 1px\),\s*-1px calc\(100% - var\(--cut\)\)\);/.test(css))
  check('the island keeps 3px of room inside its clip', /\.br-cs\.lk2 \{\s*padding: 3px;\s*\}/.test(css))
  const boxes = ['lk2-cards', 'lk2-tiles', 'lk2-lines', 'lk2-panel']
  const tight = boxes.filter((b) => {
    const body = new RegExp(`\\.br-cs \\.${b} \\{([^}]*)\\}`).exec(css)?.[1] ?? ''
    return !/overflow-y: auto;/.test(body) || !/margin: -3px/.test(body) || !/padding: 3px [^;]*3px 3px;/.test(body)
  })
  check('each scrolling box reaches 3px past its place with 3px of room inside', tight.length === 0, tight.join(', '))
  // EVERY menu in the island in its own em: Cloudscape's measured width came
  // out zoomed twice on the standard zoom model (CEF 144, today's Chrome) --
  // first on the pickers, then on a card's "..." menu (#28 review). What a
  // browser draws is test-lockerv2-menus.mjs's; this pins the rules' reach.
  check('every dropdown in the island is its picker\'s width, no narrower scope, its height capped in em',
    /\.br-cs \[class\*='awsui_dropdown_'\]\[class\*='awsui_open_'\] \{\s*inline-size: 100% !important;/.test(css)
    && /\.br-cs \[class\*='awsui_dropdown-content_'\] \{\s*max-block-size: 15em !important;/.test(css))
  check('...but an icon\'s menu (a card\'s "..."), as wide as its words',
    /\.br-cs \.lk2-card-menu \[class\*='awsui_dropdown_'\]\[class\*='awsui_open_'\] \{\s*inline-size: max-content !important;/.test(css))
  check('an option and a picker\'s choice on one line or not drawn, never "..."',
    /\.br-cs \[class\*='awsui_label-content_'\],\s*\.br-cs button \[class\*='awsui_trigger_'\] \{[^}]*flex-wrap: wrap !important;[^}]*overflow: hidden !important;[^}]*text-overflow: clip !important;/.test(css))
  check('a dialog is as wide as what it holds, its buttons on one line',
    /\.br-cs \[class\*='awsui_dialog_'\] \{\s*inline-size: max-content !important;/.test(css))
}

// ── WIRING (source) ──────────────────────────────────────────────────────────
{
  const walk = (d) => readdirSync(d, { withFileTypes: true })
    .flatMap((x) => (x.isDirectory() ? walk(join(d, x.name)) : [join(d, x.name)]))
  const app = read(join(SRC, 'App.tsx'))
  check('App.tsx renders Season 2\'s locker only when the flag is on, Season 1\'s otherwise',
    app.includes('<Page name="locker" show={focus === \'locker\'}>{locker2On ? <LockerV2Gate /> : <Locker />}</Page>'))
  check('App.tsx routes the locker2 envelope through the parser, and never imports the screen (a chunk)',
    app.includes("useNuiEvent('locker2',  (d) => dispatch().setLocker2(parseLocker2(d)))")
    && !/from '\.\/screens\/LockerV2'/.test(app))
  check('the store shares what a push did not change',
    read(join(SRC, 'store', 'index.ts')).includes('setLocker2: (locker2) => set((s) => ({ locker2: share(s.locker2, locker2) })),'))

  const gate = read(join(L2, 'Gate.tsx'))
  check('the chunk is still a lazy import, and a chunk that fails or never loads gives the cursor back',
    gate.includes("import('../LockerV2')") && /lazy\(load\)/.test(gate)
    && gate.includes('CB.LOCKER_FOCUS, { open: false }') && gate.includes('componentDidCatch') && gate.includes('LOAD_MS'))
  check('the preloaded screen is drawn outright -- no Suspense, so no 300 ms reveal hold on the first open',
    /Loaded = m\.default/.test(gate) && /const Ready = Loaded\s*if \(Ready\) return <Boundary><Ready \/><\/Boundary>/.test(gate))
  check('once loaded: the sheet goes off, and the theme is built in idle time',
    gate.includes('sheetLoaded()') && /idle\(\(\) => \{ m\.warmTheme\(\) \}\)/.test(gate))
  const scope = read(join(L2, 'scope.ts'))
  check('the theme is generated once a session and only inserted on open -- applyTheme rebuilt it every time',
    !/\bapplyTheme\b/.test(strip(scope))
    && /if \(themeCss === null\) themeCss = generateThemeStylesheet\(\{ theme: LOCKER_THEME \}\)/.test(scope)
    && /node\.textContent = warmTheme\(\)/.test(scope) && /node\.remove\(\)/.test(scope))
  check('the sheet, the mode and the theme go on and off together',
    /holdSheet\(true\)\s*applyMode\(Mode\.Dark\)/.test(scope) && /applyMode\(Mode\.Light\)\s*holdSheet\(false\)/.test(scope))
  const sheet = read(join(L2, 'sheet.ts'))
  check('sheet.ts is in the main bundle with no imports, and disables the chunk\'s link while no screen is up',
    !/^import /m.test(sheet) && /l\.disabled = users === 0/.test(sheet))
  {
    // BOTH SEASON 2 SCREENS' SHEETS (#28, #411): Locker v2's, the Market's and
    // the Cloudscape they share, off while neither screen is up; the page's
    // own never.
    const { holdSheet, sheetLoaded } = await import(pathToFileURL(join(L2, 'sheet.ts')).href)
    const links = ['index.css', 'LockerV2.css', 'MarketV2.css', 'index2.css']
      .map((f) => ({ href: `https://cfx-nui-br_ui/ui/assets/${f}`, disabled: false }))
    const was = globalThis.document
    globalThis.document = { querySelectorAll: () => links }
    const state = () => links.map((l) => l.disabled)
    sheetLoaded()
    const loaded = state()
    holdSheet(true)
    const one = state()
    holdSheet(true)
    holdSheet(false)
    const still = state()
    holdSheet(false)
    eq('a chunk loaded: the locker\'s, the Market\'s and the shared sheets off, the page\'s own on; on while a screen is up, off once none is',
      [loaded, one, still, state()],
      [[false, true, true, true], [false, false, false, false], [false, false, false, false], [false, true, true, true]])
    globalThis.document = was
  }
  check('the Market\'s Gate turns them off once its chunk loads, as the locker\'s does',
    /import\('\.\.\/MarketV2'\)\.then\(\(m\) => \{ sheetLoaded\(\); return m \}\)/.test(read(join(SRC, 'screens', 'marketv2', 'Gate.tsx'))))

  const v2 = read(join(SRC, 'screens', 'LockerV2.tsx'))
  for (const fn of ['followView(', 'backSteps(', 'escapeAction(', 'saveDialogFor(', 'saveEnabled(', 'saveRequest(',
    'useAfterPaint(']) {
    check(`LockerV2.tsx asks ${fn.slice(0, -1)}`, v2.includes(fn))
  }
  const pageFiles = [join(SRC, 'screens', 'LockerV2.tsx'), ...walk(L2).filter((f) => /\.tsx?$/.test(f))]
  const pageSrc = pageFiles.map((f) => strip(read(f))).join('\n')
  check('the open sends LOCKER2_OPEN alone: the page never sends LOCKER2_TAB (Lua answered a redundant one with a push)',
    /useEffect\(\(\) => \{ void fetchNui\(CB\.LOCKER2_OPEN\) \}, \[\]\)/.test(v2) && !pageSrc.includes('CB.LOCKER2_TAB')
    && !pageSrc.includes('CB.LOCKER2_RESET'))
  check('New, Edit and Leave are numbered, and the view follows Lua on its draft and its echo',
    v2.includes('void fetchNui(cb, { ...data, seq: requests })')
    && v2.includes("ask(CB.LOCKER2_NEW, { sex })") && v2.includes("ask(CB.LOCKER2_EDIT, { id: p.id })")
    && v2.includes("ask(CB.LOCKER2_LEAVE, {})")
    && /setView\(\(v\) => followView\(v, hasDraft, tabSeq, sent\.current\)\)\s*\}, \[hasDraft, tabSeq\]\)/.test(v2))
  check('Done awaits `close` before it gives the focus back',
    /await fetchNui\(CB\.LOCKER2_CLOSE\)\s*else if \(s\.do === 'unfocus'\) await fetchNui\(CB\.LOCKER_FOCUS, \{ open: false \}\)/.test(v2))
  check('Back with changes opens the discard prompt, and its Discard goes on',
    v2.includes("if (steps[0]?.do === 'confirm') { setModal({ kind: 'discard' }); return }")
    && v2.includes("case 'discard': back(true); break"))
  check('the save dialog\'s two saves: an update by id, a new look by name',
    v2.includes("saveRequest(m, choice === 'new' ? 'new' : 'update', name)"))
  check('Escape: capture phase, an open dropdown first, then the dialog, then Back',
    /const act = escapeAction\(live\.current\.view, live\.current\.modal !== null, escapeHeld\(\), popupOpen\(screen\.current\)\)\s*if \(act === 'pass'\) return/.test(v2)
    && v2.includes("window.addEventListener('keydown', onKey, true)"))
  check('Done carries the walkthrough\'s anchor (the rendered views above say where it is, and is not)',
    v2.includes('data-tut="locker-done"') && v2.includes("{ [AWAY_ATTR]: 'locker-done' }"))
  const whole = pageFiles.filter((f) => /useUi\(\(s\) => s\.locker2\)/.test(read(f)))
  check('no part of the screen subscribes to the whole locker2 push (each reads the fields it draws)',
    whole.length === 0, whole.join(', '))

  const ed = read(join(L2, 'Editor.tsx'))
  check('"Add more" lists the extras not on the look and puts the one picked on, its panel open',
    ed.includes('const addable = addableExtras(edit.extras)') && ed.includes('<AddMore items={addable}')
    && /void fetchNui\(CB\.LOCKER2_EXTRA, \{ id: cat, on: true \}\)\s*setChosen\(cat\)/.test(ed))
  check('"Add more"\'s menu closes on Escape and on a press outside it, and the screen leaves it the key',
    /if \(e\.key === 'Escape'\) setOpen\(false\)/.test(ed) && ed.includes("window.addEventListener('pointerdown', onDown, true)")
    && ed.includes('ariaHaspopup="menu" ariaExpanded={open}'))
  check('an extra\'s trash icon takes it off', ed.includes('void fetchNui(CB.LOCKER2_EXTRA, { id: cat, on: false })')
    && ed.includes('{extra && <IconBtn icon="remove" label={BTN.remove}'))
  check('the list is the core then the extras on the look', ed.includes('const listed = edit ? listedCats(edit.extras) : []'))
  check('Randomize, Undo and Redo ask Lua; Undo and Redo lit by the draft\'s history',
    ed.includes('void fetchNui(CB.LOCKER2_RANDOM)') && ed.includes('disabled={blocked || !edit.undo}')
    && ed.includes('void fetchNui(CB.LOCKER2_UNDO)') && ed.includes('disabled={blocked || !edit.redo}')
    && ed.includes('void fetchNui(CB.LOCKER2_REDO)'))
  check('a line pressed shows its panel and moves the camera', /setChosen\(cat\)\s*void fetchNui\(CB\.LOCKER2_CAT, \{ cat \}\)/.test(ed))
  check('the face: starting faces, then "Fine-tune", then its groups, each with one reset',
    ed.includes('<FaceTiles row={shape} disabled={disabled} />') && ed.includes('{BTN.fineTune}')
    && ed.includes('{tune && FACE_GROUPS.map((g) => (') && ed.includes('void fetchNui(CB.LOCKER2_DEFAULTS, { ks })')
    && ed.includes('<SliderRow key={r.k} row={r} disabled={disabled} onTouch={onTouch} bare />'))
  check('the tattoo editors mount only once Tattoos is on and opened',
    /if \(cat === TATTOOS_CAT\) \{\s*return tats \? <TattooSection/.test(ed) && !/<TattooSection/.test(v2))
  check('the palettes are asked for when the editor opens', ed.includes('useEffect(() => { askPal() }, [])'))

  const rows = read(join(L2, 'Rows.tsx'))
  check('Last and Next repeat while held', rows.includes('<IconBtn icon="angle-left" label={BTN.last} disabled={disabled} hold')
    && rows.includes('<IconBtn icon="angle-right" label={BTN.next} disabled={disabled} hold')
    && rows.includes('const held = useHold(onPress, undefined, disabled)'))
  check('a swatch sends its color through swatchRequest; a row draws swatches only when swatchesShown',
    rows.includes('const req = swatchRequest(row, i)') && rows.includes('swatchesShown(row)'))
  check('an item\'s colors: a swatch button when texturesShown, its grid sending textureRequest; no "Next color" left',
    rows.includes('const textures = texturesShown(row)') && rows.includes('<TextureButton row={row}')
    && rows.includes('void fetchNui(CB.LOCKER2_COLOR, textureRequest(row, i))') && !rows.includes('nextColor'))
  check('a caption only where its category shows names', rows.includes('const caption = nameShown(row)'))
  check('every row is memoized', (rows.match(/= memo\(function /g) ?? []).length >= 3)
  const hold = read(join(L2, 'hold.ts'))
  check('a hold acts on the press, then after holdDelay(1), holdDelay(2) ...; the keyboard acts once',
    hold.includes('delay: (n: number) => number = holdDelay') && /live\.current\(0\)\s*repeat\(1\)/.test(hold)
    && /\}, delay\(n\)\)/.test(hold) && hold.includes('if (!disabled && e.detail === 0) live.current(0)'))

  const modals = read(join(L2, 'Modals.tsx'))
  check('the name box filters as typed and confirms the cleaned name',
    modals.includes('onChange={({ detail }) => setName(filterName(detail.value))}')
    && modals.includes('const ready = !asksName || nameOk(cleanName(name))')
    && modals.includes('onConfirm(modal, choice, cleanName(name))'))
  check('"Save as new" is in the save dialog only, and only for a look opened from My Looks',
    /\{m\?\.kind === 'save' && m\.asNew && \(\s*<Button disabled=\{!ready\} onClick=\{\(\) => confirm\('new'\)\}>\{BTN\.saveAsNew\}<\/Button>/.test(modals)
    && v2.includes('setModal(saveDialogFor(editing, peds, opened))')
    && /if \(a === 'edit'\) \{ setOpened\(true\);/.test(v2) && /setOpened\(false\)\s*setView\('edit'\)\s*ask\(CB\.LOCKER2_NEW, \{ sex \}\)/.test(v2))
  check('dialogs render into the island', modals.includes('getModalRoot={getRoot}'))

  const home = read(join(L2, 'Home.tsx'))
  check('My Looks: a card press wears it; Edit, Rename and Delete in its "..." menu, opening inside the island',
    home.includes("void fetchNui(CB.LOCKER2_WEAR, { k: 'p', id: p.id })")
    && /variant="icon"\s*ariaLabel=\{BTN\.more\}/.test(home) && home.includes("{ id: 'edit', text: BTN.edit },")
    && home.includes("{ id: 'rename', text: BTN.rename },") && home.includes("{ id: 'delete', text: BTN.delete },")
    && home.includes('expandToViewport={false}'))
  const nl = read(join(L2, 'NewLook.tsx'))
  check('New: Custom first, its own Male / Female dropdown; a card press selects; Create goes on (LockerV2.tsx)',
    nl.indexOf("card('custom', CARD.custom)") < nl.indexOf("card('stock', CARD.stock)") && nl.includes("pick === p ? ' is-active' : ''")
    && nl.includes('options={SEX_OPTIONS}') && nl.includes("void fetchNui(CB.LOCKER2_WEAR, { k: 's', id })")
    && !/LOCKER2_NEW/.test(nl) && v2.includes('const step = createStep(pick)') && v2.includes('onClick={create}>{BTN.create}</Button>')
    && v2.includes('setPick(NEW_DEFAULT); setView(\'new\')'))
  const cam = read(join(L2, 'Camera.tsx'))
  check('the camera: rotate is LOCKER_SPIN, held; turn, zoom and reset are LOCKER2_CAM; the wheel zooms',
    cam.includes('void fetchNui(CB.LOCKER_SPIN, { delta })') && cam.includes("cam('turn')")
    && cam.includes("cam('zoom', 1)") && cam.includes("cam('zoom', -1)") && cam.includes("cam('reset')")
    && cam.includes("cam('zoom', e.deltaY < 0 ? 1 : -1)") && (cam.match(/ hold onPress=/g) ?? []).length === 2)
  {
    // check-cef's C4 lets Camera.tsx say 'zoom' -- LOCKER2_CAM's op, a word on
    // the wire -- so here its own rule reads the file with those words out,
    // and finds no CSS zoom (the cluster is outside the island, in rem).
    const { scanSource } = await import(pathToFileURL(join(ROOT, 'scripts', 'cef-rules.mjs')).href)
    const ops = cam.replace(/\bcam\('zoom'/g, 'cam(OP').replace("op: 'turn' | 'zoom' | 'reset'", 'op: OP')
    const css = scanSource(ops, 'ui-src/src/screens/lockerv2/camera-ops.tsx').filter((f) => f.rule === 'C4 zoom')
    check('the camera: \'zoom\' only as LOCKER2_CAM\'s op, never CSS zoom (check-cef C4 on the rest)',
      ops !== cam && css.length === 0, css.map((f) => `line ${f.line}`).join(', '))
  }
  const tat = read(join(L2, 'Tattoos.tsx'))
  check('a tattoo picker scrolls virtually, filters by name, and opens inside the island',
    tat.includes('virtualScroll') && tat.includes('filteringType="manual"') && tat.includes('expandToViewport={false}'))
  check('tattoos: one list grouped by zone, one "Add more", a new row sending LOCKER2_TAT_ADD { z, i } once both are picked',
    tat.includes('className="lk2-tats awsui-compact-mode"') && tat.includes('const groups = tatGroups(')
    && (tat.match(/\{BTN\.addMore\}/g) ?? []).length === 1 && tat.includes('void fetchNui(CB.LOCKER2_TAT_ADD, { z, i })')
    && !/attribute-editor/.test(tat) && !existsSync(join(L2, 'tattoos.css')))

  // Every callback the page and the harness name is in bridge/types.ts.
  const types = read(join(SRC, 'bridge', 'types.ts'))
  const used = [...new Set([...pageSrc.matchAll(/CB\.(LOCKER2_[A-Z_]+)/g)].map((x) => x[1]))]
  const missing = used.filter((k) => !new RegExp(`^\\s+${k}:\\s+'br/locker2/`, 'm').test(types))
  check(`every LOCKER2 callback the page sends is declared (${used.length})`, used.length > 15 && missing.length === 0,
    missing.join(', '))
  const mock = read(join(SRC, 'bridge', 'mockLocker2.ts'))
  const NEW = ['new', 'leave', 'random', 'undo', 'redo', 'extra', 'defaults', 'pal', 'cam']
  const unplayed = NEW.filter((n) => !mock.includes(`case 'br/locker2/${n}':`))
  check('the harness plays every new callback', unplayed.length === 0, unplayed.join(', '))
  check('and its history is model.ts\'s, which the wiring round mirrors in Lua',
    /draft\.hist = record\(draft\.hist, copySnap\(draft\.snap\), key, Date\.now\(\)\)/.test(mock)
    && mock.includes('undoStep(draft.hist, copySnap(draft.snap))') && mock.includes('redoStep(draft.hist, copySnap(draft.snap))'))

  // EVERY IMAGE DRAWN TO A CANVAS GOES THROUGH canvasImage.
  const drawers = walk(SRC).filter((f) => /\.(tsx?)$/.test(f)).filter((f) => read(f).includes('drawImage('))
  const bare = drawers.filter((f) => { const t = read(f); return /\.src\s*=(?!=)/.test(t) || (t.includes('new Image(') && !t.includes('canvasImage(')) })
  check(`every image drawn to a canvas is asked for with CORS (${drawers.length} file(s))`, drawers.length > 0 && bare.length === 0,
    bare.join(', '))
  const autoFilters = walk(SRC).filter((f) => /\.tsx?$/.test(f)).filter((f) => /filteringType=["{']*auto/.test(read(f)))
  check('no Cloudscape filter anywhere searches an option\'s value', autoFilters.length === 0, autoFilters.join(', '))
  const globals = walk(SRC).filter((f) => /\.(tsx?|css)$/.test(f))
    .filter((f) => /@cloudscape-design\/global-styles\/[\w-]+\.css/.test(read(f)))
  check('no global-styles stylesheet is imported', globals.length === 0, globals.join(', '))
}

// ── SEASON 1, UNTOUCHED ──────────────────────────────────────────────────────
{
  const SEASON1_LOCKER = '1481bce0ecc72672c29e2c38c5b7cac2e3898f4a6e3f88a31c986476c90052e8'
  const got = createHash('sha256').update(read(join(SRC, 'screens', 'Locker.tsx'))).digest('hex')
  check('screens/Locker.tsx is byte-for-byte Season 1\'s', got === SEASON1_LOCKER, `sha256 ${got}`)
}

// ── THE CHUNK (build output) ─────────────────────────────────────────────────
if (!existsSync(OUT)) {
  check('the build output exists (run the build first)', false, OUT)
} else {
  const js = join(OUT, 'LockerV2.js')
  const css = join(OUT, 'LockerV2.css')
  check('assets/LockerV2.js and assets/LockerV2.css are built', existsSync(js) && existsSync(css))
  const indexCss = read(join(OUT, 'index.css'))
  const indexJs = read(join(OUT, 'index.js'))
  check('the main stylesheet carries none of Cloudscape, nor this screen\'s rules',
    !indexCss.includes('awsui') && !indexCss.includes('lk2-'))
  check('the main bundle carries none of Cloudscape', !/awsui_[a-z]/.test(indexJs))
  check('the main bundle loads the chunk by name', indexJs.includes('LockerV2.js'))
  // EVERY FILE THE LOCKER BRINGS, not only its own: since the Season 2 Market
  // (#411) the Cloudscape both screens reach is a shared chunk (index2.js and
  // index2.css, vite.config.ts). Named by the main bundle's preload list,
  // `__vite__mapDeps([chunk, ...its deps])`, as test-marketv2.mjs reads it, so
  // a renamed shared chunk is still read.
  const depFiles = (() => {
    const m = indexJs.match(/m\.f=(\[[^\]]*\])/)
    try { return m ? JSON.parse(m[1]) : [] } catch { return [] }
  })()
  const deps = ([...indexJs.matchAll(/__vite__mapDeps\(\[([\d,]+)\]\)/g)]
    .map((m) => m[1].split(',').map((n) => depFiles[Number(n)]))
    .find((d) => d[0] === './LockerV2.js') ?? []).filter((f) => typeof f === 'string')
  const lockerCss = deps.filter((f) => /\.css$/.test(f))
  const lockerJs = deps.filter((f) => /\.js$/.test(f))
  check('the locker\'s preload names its stylesheet, its script and every chunk they share',
    lockerCss.includes('./LockerV2.css') && lockerJs.includes('./LockerV2.js')
    && deps.every((f) => existsSync(join(OUT, f))), deps.join(', '))

  if (existsSync(css)) {
    const text = lockerCss.filter((f) => existsSync(join(OUT, f))).map((f) => read(join(OUT, f))).join('\n')
      .replace(/\/\*[\s\S]*?\*\//g, '')
    const bad = []
    const global = []
    let ours = 0
    let rules = 0
    const subject = (s) => s.trim().split(/\s*[\s>+~]\s*(?![^(]*\))(?![^[]*\])/).pop() ?? ''
    const allowed = (sel, body) => {
      if (/^@font-face/.test(sel)) return false
      if (/^@keyframes\s+awsui[-_]/.test(sel)) return true
      if (/^@property\s+--/.test(sel)) return true
      if (sel.startsWith('@')) return false
      const declsOnlyVars = body.split(';').map((d) => d.trim()).filter(Boolean).every((d) => d.startsWith('--'))
      if (declsOnlyVars) return true
      const parts = sel.split(',').map((s) => s.trim())
      // THIS SCREEN'S RULES: every selector under the island (`.br-cs `) or
      // the island itself (`.br-cs.lk2`), or the camera cluster (`.lk2-cam`).
      if (parts.every((s) => /^\.br-cs\s/.test(s) || s === '.br-cs.lk2' || /^\.lk2-cam\b/.test(s))) { ours++; return true }
      const isGlobal = (s) => /^(html|body|:root)(?![\w-])/.test(subject(s))
        || (/^\*/.test(subject(s)) && !/\.awsui[-_]/.test(s))
      if (parts.some(isGlobal)) { global.push(`${sel.slice(0, 100)} {${body.slice(0, 60)}`); return false }
      return parts.every((s) => /\.awsui[-_]/.test(s))
    }
    const walkCss = (t) => {
      let i = 0
      while (i < t.length) {
        if (/\s/.test(t[i])) { i++; continue }
        const open = t.indexOf('{', i)
        const semi = t.indexOf(';', i)
        if (semi !== -1 && (open === -1 || semi < open)) { bad.push(t.slice(i, semi).trim()); i = semi + 1; continue }
        if (open === -1) break
        const sel = t.slice(i, open).trim()
        let depth = 1
        let j = open + 1
        while (j < t.length && depth > 0) { if (t[j] === '{') depth++; else if (t[j] === '}') depth--; j++ }
        const body = t.slice(open + 1, j - 1)
        if (/^@(media|supports|container|layer)\b/.test(sel)) walkCss(body)
        else { rules++; if (!allowed(sel, body)) bad.push(`${sel.slice(0, 100)} {${body.slice(0, 60)}`) }
        i = j
      }
    }
    walkCss(text)
    check(`chunk CSS is Cloudscape's scoped rules and this screen's, scoped to it (${rules} rules, ${ours} ours)`,
      rules > 100 && ours > 30 && bad.length === 0, bad.slice(0, 5).join('\n          '))
    check('chunk CSS has no @font-face, and styles no html, body, :root or bare *',
      !/@font-face/.test(text) && global.length === 0, global.slice(0, 3).join('\n          '))
    check('the square corners ship', /\.br-cs \*,\s*\.br-cs \*::?before,\s*\.br-cs \*::?after\s*\{\s*border-radius:\s*0\s*!important/.test(text))
    // The classes our rules reach for are still the installed Cloudscape's:
    // named on its elements, in the chunk's script.
    const chunkJs = lockerJs.filter((f) => existsSync(join(OUT, f))).map((f) => read(join(OUT, f))).join('\n')
    for (const cls of ['awsui_button_', 'awsui_variant-normal_', 'awsui_variant-primary_', 'awsui_variant-link_',
      'awsui_disabled_', 'awsui_labels_', 'awsui_header--text_', 'awsui_dropdown_', 'awsui_open_', 'awsui_dropdown-content_',
      'awsui_dialog_']) {
      check(`the chunk still names Cloudscape's ${cls}, which our stylesheet reaches for`, chunkJs.includes(cls))
    }
  }
}

console.log(`\ntest-lockerv2: ${ran - failed}/${ran} passed`)
if (failed > 0) process.exit(1)
