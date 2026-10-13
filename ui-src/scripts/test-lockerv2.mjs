#!/usr/bin/env node
/**
 * LOCKER V2'S TESTS (#28): the page's rules, its copy, its wiring, its chunk.
 *
 * src/screens/lockerv2/model.ts decides everything the Season 2 locker does
 * before it draws, and it has no runtime imports, so node's type stripping
 * loads it as-is (the same shape as test-continue-toggle.mjs). copy.ts the
 * same. These hold each rule to the owner's words in #28:
 *
 *   SAVE      the three shapes: plain with nothing saved, Create new / Replace
 *             existing (every saved ped by name) with something saved, and a
 *             split button that updates while editing; lit only while dirty.
 *   SLIDE     d = sign(new - old); the old body leaves toward +d, the new one
 *             arrives from -d.
 *   TABS      My peds only once something is saved (or while the saved peds
 *             load), opening on it if so and on Stock if not; dirty locks every
 *             other tab WITH the hover card, a busy ped locks them without one.
 *   NAMES     letters and digits only, 1 to 24, filtered as typed.
 *   DONE      dirty asks first and does nothing else; then `close`, then
 *             LOCKER_FOCUS { open: false }, in that order. Escape closes an open
 *             dialog alone.
 *   FOLLOW    the page moves its tab on the press, and shows Lua's once a push
 *             has seen its latest request; it draws a draft only under the
 *             tab of its sex; a slider shows Lua's value once untouched.
 *   CAMERA    every category touch is sent; a new draft lights no anchor.
 *   PICTURES  every image drawn to a canvas is asked for with CORS; a stored
 *             picture arrives on its own and is kept, never on the push.
 *   TATTOOS   each sex's list made safe to draw (the body's zones in order,
 *             whole items, a name only if it is one), the section's anchors
 *             only once the list has come, Lua's rows made safe to draw (a
 *             list that starts empty), 10 a zone, Add off at 10, a row's list
 *             leaving out what the zone's other rows hold, the words, and the
 *             wiring (2026-10-12, "attribute editor"): asked once drawn, one
 *             AttributeEditor a zone under its heading, compact, each item one
 *             row whose one field is a filtered Select of the zone's tattoos
 *             by the game's names, a choice a LOCKER2_TAT_SET of its row, the
 *             editor's Add a LOCKER2_TAT_ADD of its zone and its own Remove a
 *             LOCKER2_TAT_DEL of that row, no label, no empty-state or helper
 *             text, no cards, arrows or selection, the nameless numbered among
 *             themselves, and the first Remove kept level with its Select.
 *
 * And what a unit test cannot see, read from the source and the build:
 *
 *   WIRED     LockerV2.tsx asks these rules rather than deciding for itself, and
 *             App.tsx picks it only when the season's flag is on.
 *   SEASON 1  screens/Locker.tsx is byte-for-byte the finished product.
 *   CHUNK     Cloudscape ships in assets/LockerV2.{js,css} and nowhere in the
 *             main bundle; that CSS is Cloudscape's own scoped rules (.awsui_*
 *             selectors, `--*` properties, awsui keyframes) and nothing global:
 *             no @font-face, no body or html rule, none of global-styles --
 *             but the Tattoos section's one rule, under `.lk2-tats`.
 *
 * Run: npm run test:lockerv2   (and as part of npm run build, after vite)
 */

import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  SLIDER_HOLD_MS, activeAnchor, anchorId, canvasImage, categoriesOf, counterText, dataUrlBytes,
  doneSteps, editFor, escapeAction, filterName, followTab, imgOk, nameOk, needShots, openingTab,
  parseLocker2, parseTats, saveVariant, shotKey, shotStorable, sliderShown, slideDir, slideEnds, tabOptions,
  tabsShown, TATTOOS_PER_ZONE, TATTOO_ZONES, canAddTattoo, sameTatRows, tattooCats, tattooChoices, wrapStep, zoneOfCat,
  zoneRows, zoomFor,
} from '../src/screens/lockerv2/model.ts'
import {
  BTN, CAT_LABEL, LOCKED_TAB, MODAL, ROW_LABEL, TAB_LABEL, TATTOOS, ZONE_LABEL, rowLabel, tattooFallback, tattooLabels,
  updateLabel,
} from '../src/screens/lockerv2/copy.ts'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = join(ROOT, 'src')
const OUT = join(ROOT, '..', 'resources', '[fivem-royale]', 'br_ui', 'ui', 'assets')

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

// ── SAVE ─────────────────────────────────────────────────────────────────────
const PEDS = [{ id: 'a1', name: 'Nightshift' }, { id: 'b2', name: 'Ranger' }]
eq('Save: nothing saved, nothing edited -> a plain button that asks for a name',
  saveVariant({ dirty: true, editing: null, peds: [] }), { kind: 'plain', enabled: true })
eq('Save: saved peds, not editing -> Create new / Replace existing, every ped by name',
  saveVariant({ dirty: true, editing: null, peds: PEDS }),
  { kind: 'menu', enabled: true, replace: PEDS })
eq('Save: editing a saved ped -> the split button, updating that ped by default',
  saveVariant({ dirty: true, editing: 'b2', peds: PEDS }),
  { kind: 'split', enabled: true, id: 'b2', name: 'Ranger' })
eq('Save: editing a ped that is gone -> a new ped again (the menu)',
  saveVariant({ dirty: true, editing: 'zz', peds: PEDS }).kind, 'menu')
eq('Save: off while there is nothing to save, in every shape',
  [saveVariant({ dirty: false, editing: null, peds: [] }).enabled,
    saveVariant({ dirty: false, editing: null, peds: PEDS }).enabled,
    saveVariant({ dirty: false, editing: 'a1', peds: PEDS }).enabled], [false, false, false])
eq('Save menu wording: "Update <name>" and "Save as new"; the owner\'s "Create new" / "Replace existing"',
  [updateLabel('Ranger'), BTN.saveAsNew, BTN.createNew, BTN.replaceExisting],
  ['Update Ranger', 'Save as new', 'Create new', 'Replace existing'])

// ── SLIDE ────────────────────────────────────────────────────────────────────
eq('slide: center tab to the right tab -> d = +1 ("slide out right ... slide in right")',
  slideDir('stock', 'male'), 1)
eq('slide: right to left -> d = -1', slideDir('female', 'stock'), -1)
eq('slide: My peds is leftmost', [slideDir('peds', 'stock'), slideDir('stock', 'peds')], [1, -1])
eq('slide: the same tab does not move', slideDir('male', 'male'), 0)
eq('slide: the old body exits toward +d, the new enters from -d',
  [slideEnds(1), slideEnds(-1)], [{ enter: -1, exit: 1 }, { enter: 1, exit: -1 }])

// ── TABS ─────────────────────────────────────────────────────────────────────
eq('tabs: My peds only once something is saved',
  [tabsShown(0), tabsShown(2)],
  [['stock', 'male', 'female'], ['peds', 'stock', 'male', 'female']])
eq('tabs: My peds while the saved peds are still loading (owner, 2026-10-07)',
  tabsShown(0, true), ['peds', 'stock', 'male', 'female'])
eq('opening tab: My peds if any are saved, else Stock, and My peds while loading',
  [openingTab(3), openingTab(0), openingTab(0, true)], ['peds', 'stock', 'peds'])
eq('tabs: unsaved changes disable every other tab, each with the hover card',
  tabOptions({ pedCount: 1, current: 'male', dirty: true, blocked: false }),
  [{ id: 'peds', disabled: true, explained: true },
    { id: 'stock', disabled: true, explained: true },
    { id: 'male', disabled: false, explained: false },
    { id: 'female', disabled: true, explained: true }])
eq('tabs: no changes -> every tab open',
  tabOptions({ pedCount: 0, current: 'stock', dirty: false, blocked: false }).map((o) => o.disabled),
  [false, false, false])
eq('tabs: a locked, loading or busy ped disables the others with no card',
  tabOptions({ pedCount: 0, current: 'stock', dirty: false, blocked: true })
    .map((o) => [o.id, o.disabled, o.explained]),
  [['stock', false, false], ['male', true, false], ['female', true, false]])
eq('tab labels are the owner\'s', TAB_LABEL,
  { peds: 'My peds', stock: 'Stock peds', male: 'Custom (male)', female: 'Custom (female)' })
eq('the hover card', LOCKED_TAB, 'Save or reset your changes first.')

// ── FOLLOWING LUA (#28 review) ───────────────────────────────────────────────
// The page moved to Custom (female) on the press; Lua refused it (the male
// model still streaming in) and the page stayed there, drawing the male rows.
eq('follow: a push that has seen the latest press is the truth (a refusal goes back)',
  followTab('female', 'male', 7, 7), 'male')
eq('follow: a push older than the latest press is not (the slide is not undone mid-flight)',
  followTab('female', 'male', 6, 7), 'female')
eq('follow: Edit -- Lua moves to the saved ped\'s tab with no press -- is followed',
  followTab('peds', 'female', 3, 3), 'female')
eq('follow: before this opening has asked anything, nothing is followed',
  [followTab('stock', 'peds', null, -1), followTab('stock', 'peds', 4, -1)], ['stock', 'stock'])
{
  const male = { sex: 'm', editing: null, dirty: false, cat: null, rows: [] }
  eq('a draft is drawn only under the Custom tab of its sex',
    [editFor('female', male), editFor('male', male) === male, editFor('stock', male), editFor('peds', male), editFor('male', null)],
    [null, true, null, null, null])
}
eq('slider: its own value while touched, Lua\'s once the hold is over (a refused set goes back)',
  [sliderShown(40, 100, 1000, 1000 + SLIDER_HOLD_MS - 1), sliderShown(40, 100, 1000, 1000 + SLIDER_HOLD_MS + 1)],
  [40, 100])

// ── THE CAMERA'S ANCHOR (#28 review) ─────────────────────────────────────────
eq('anchor: Lua\'s category is the one lit', activeAnchor('face'), `#${anchorId('face')}`)
check('anchor: with the camera home none is lit -- and never "", which Cloudscape reads as "track the window\'s scroll"',
  activeAnchor(null) === '#' && activeAnchor(null) !== '' && !['face', 'shoes'].some((c) => activeAnchor(null) === `#${anchorId(c)}`))

// ── PICTURES (#28 review) ────────────────────────────────────────────────────
{
  // An image as a browser loads one: the request goes out when `src` is set,
  // with whatever `crossOrigin` was by then. Without it a canvas that draws
  // the image is tainted and toDataURL throws -- every headshot was lost so.
  class StubImage {
    constructor() { this._co = null; this.corsAtRequest = undefined }
    set crossOrigin(v) { this._co = v }
    get crossOrigin() { return this._co }
    set src(v) { this._src = v; this.corsAtRequest = this._co }
    get src() { return this._src }
  }
  const img = canvasImage(new StubImage(), 'https://nui-img/pedmugshot_01/pedmugshot_01?v=1')
  eq('a canvas image is requested WITH CORS: crossOrigin set before src',
    [img.corsAtRequest, img.src], ['anonymous', 'https://nui-img/pedmugshot_01/pedmugshot_01?v=1'])
}

// ── NAMES ────────────────────────────────────────────────────────────────────
eq('name: everything but A-Z, a-z and 0-9 is dropped as typed',
  filterName('Night Owl_2!-ö'), 'NightOwl2')
eq('name: capped at 24', filterName('A'.repeat(30)).length, 24)
eq('name: 1 to 24 letters and digits, nothing else',
  [nameOk(''), nameOk('a'), nameOk('A'.repeat(24)), nameOk('A'.repeat(25)), nameOk('a b'), nameOk('Zoë')],
  [false, true, true, false, false, false])

// ── DONE AND ESCAPE ──────────────────────────────────────────────────────────
eq('Done with unsaved changes: the discard prompt, and nothing else',
  doneSteps(true, false), [{ do: 'confirm' }])
eq('Done after Discard: close, then the focus', doneSteps(true, true),
  [{ do: 'close' }, { do: 'unfocus' }])
eq('Done with nothing to lose: close, then the focus', doneSteps(false, false),
  [{ do: 'close' }, { do: 'unfocus' }])
eq('Escape: an open dialog alone, else Done', [escapeAction(true), escapeAction(false)], ['modal', 'done'])
// #405's review: a walkthrough card waiting on the locker held Escape for the
// whole screen, so a dialog no longer closed on it. Only Done is held.
eq('Escape under a walkthrough card: a dialog still closes, Done is held',
  [escapeAction(true, true), escapeAction(false, true)], ['modal', 'none'])
eq('dialog wording', [MODAL.name, MODAL.rename, MODAL.discard, BTN.keepEditing, BTN.discard],
  ['Name your ped', 'Rename ped', 'Discard changes?', 'Keep editing', 'Discard'])

// ── ROWS ─────────────────────────────────────────────────────────────────────
eq('counter: "12/39"', counterText(12, 39), '12/39')
eq('counter: 39 then next is 1, and 1 then last is 39',
  [wrapStep(39, 39, 1), wrapStep(1, 39, -1), wrapStep(5, 39, 1)], [1, 39, 6])
eq('"Next color" is the owner\'s button', BTN.nextColor, 'Next color')
eq('anchors in the contract\'s order; none for a category with no rows; unknown last',
  categoriesOf([{ cat: 'shoes' }, { cat: 'face' }, { cat: 'zzz' }, { cat: 'hair' }, { cat: 'face' }]),
  ['face', 'hair', 'shoes', 'zzz'])
eq('every category named', Object.keys(CAT_LABEL).length, 12)
eq('row names: an overlay\'s companions are "<row> opacity" and "<row> color"',
  [rowLabel('o2op'), rowLabel('o1col'), rowLabel('c6'), rowLabel('ff19')],
  ['Eyebrows opacity', 'Facial hair color', 'Shoes', 'Neck thickness'])
eq('row names: a key with no word gets none, never the key itself',
  [rowLabel('c99'), rowLabel('o99op')], [null, null])
eq('row names: the twenty face features', Object.keys(ROW_LABEL).filter((k) => /^ff\d+$/.test(k)).length, 20)

// ── HEADSHOTS ────────────────────────────────────────────────────────────────
const SHOT = `data:image/webp;base64,${'A'.repeat(100)}`
eq('a picture is a base64 image data URL and nothing else',
  [imgOk(SHOT), imgOk('https://evil.example/x.png'), imgOk('javascript:alert(1)'),
    imgOk('data:text/html;base64,AAAA'), imgOk(42)], [true, false, false, false, false])
eq('a shot is stored only as webp within 8 KB',
  [shotStorable(SHOT), shotStorable(`data:image/webp;base64,${'A'.repeat(11000)}`),
    shotStorable(`data:image/png;base64,${'A'.repeat(100)}`)], [true, false, false])
eq('data URL size counts decoded bytes', dataUrlBytes('data:image/webp;base64,AAAA'), 3)
eq('shots are asked for once, only for peds with no stored or cached picture',
  needShots([{ id: 'a', up: 1 }, { id: 'b', up: 1, img: SHOT }, { id: 'c', up: 2 }, { id: 'd', up: 3 }],
    new Set([shotKey('c', 2)]), new Set([shotKey('d', 3)])), ['a'])
eq('a ped saved again needs a new picture', needShots([{ id: 'c', up: 9 }], new Set([shotKey('c', 2)]), new Set()), ['c'])

// ── THE ENVELOPE ─────────────────────────────────────────────────────────────
{
  // An empty Lua list crosses the bridge as {}.
  const p = parseLocker2({ on: true, tab: 'nope', stock: {}, peds: {}, worn: { k: 'x', id: 1 }, edit: {
    sex: 'f', editing: '', dirty: true, cat: 'hair',
    rows: [
      { k: 'c6', cat: 'shoes', kind: 'count', v: 3, n: 39, colors: 4 },
      { k: 'ff0', cat: 'face', kind: 'slider', v: 0, min: -100, max: 100, def: 0 },
      { k: 'bad', cat: 'face', kind: 'count', v: 'x' },
      'junk',
    ],
  } })
  eq('envelope: {} lists are empty lists', [p.stock, p.peds], [[], []])
  eq('envelope: an unknown tab is Stock, a malformed worn is none', [p.tab, p.worn], ['stock', null])
  eq('envelope: malformed rows dropped, whole rows kept', p.edit.rows.map((r) => r.k), ['c6', 'ff0'])
  eq('envelope: flags are booleans, editing "" is none',
    [p.on, p.busy, p.locked, p.fetching, p.edit.editing, p.edit.sex], [true, false, false, false, null, 'f'])
  eq('envelope: a picture that is not an image data URL is dropped',
    parseLocker2({ peds: [{ id: 'a', name: 'A', up: 1, img: 'https://x/y.png' }] }).peds, [{ id: 'a', name: 'A', up: 1 }])
  eq('envelope: nothing at all is Season 1', parseLocker2(undefined).on, false)
  eq('envelope: a draft with no category is the camera home -- no anchor, never Face by default',
    parseLocker2({ edit: { sex: 'm', rows: [] } }).edit.cat, null)
  eq('envelope: tabSeq is Lua\'s echo, null when absent',
    [parseLocker2({ tabSeq: 3 }).tabSeq, parseLocker2({}).tabSeq], [3, null])
  eq('envelope: an opacity of none is `off`, the rest are not',
    parseLocker2({ edit: { sex: 'm', rows: [
      { k: 'o1op', cat: 'hair', kind: 'slider', v: 100, min: 0, max: 100, def: 100, off: true },
      { k: 'o2op', cat: 'hair', kind: 'slider', v: 100, min: 0, max: 100, def: 100 },
    ] } }).edit.rows.map((r) => r.off === true), [true, false])
}

eq('zoom: root px / 14, and 1 for nonsense', [zoomFor(28), zoomFor(14), zoomFor(Number.NaN)], [2, 1, 1])

// ── TATTOOS (owner, 2026-10-11) ──────────────────────────────────────────────
// "No cap on tattoos per ped, and yes whatever the game has include DLC sets."
{
  const t = parseTats({ sex: 'm', zones: [
    { z: 'torso', items: [{ i: 5, name: 'Skull' }, { i: 7 }, { i: 0, name: 'bad' }, 'junk', { i: 2.5 }, { i: 9, name: '' }] },
    { z: 'head', items: [{ i: 1, name: 'Star' }] },
    { z: 'nope', items: [{ i: 3 }] },
    { z: 'lleg', items: {} },
    { z: 'head', items: [{ i: 4 }] },
  ] })
  eq('tattoo list: the body\'s zones in order; unknown, empty and repeated zones dropped',
    t.zones.map((z) => z.z), ['head', 'torso'])
  eq('tattoo list: whole items kept, a name only when it is one', t.zones[1].items, [{ i: 5, name: 'Skull' }, { i: 7 }, { i: 9 }])
  eq('tattoo list: not a sex, or nothing, is no list', [parseTats({ sex: 'x', zones: [] }), parseTats(null)], [null, null])
  eq('tattoo anchors: none before the list has come, then the section and each zone it has',
    [tattooCats(null), tattooCats(t)], [[], ['tattoos', 'tat_head', 'tat_torso']])
  eq('tattoo anchors: an empty list has none', tattooCats({ sex: 'm', zones: [] }), [])
  eq('a zone\'s anchor sits one level in; nothing else does',
    [zoneOfCat('tat_head'), zoneOfCat('tat_rleg'), zoneOfCat('tattoos'), zoneOfCat('face'), zoneOfCat('tat_nope')],
    ['head', 'rleg', null, null, null])
  // THE ROWS (owner, 2026-10-12): "a list, starting empty, with add and remove
  // buttons ... You can just make it max 10 per category."
  const p = parseLocker2({ edit: { sex: 'm', rows: [], tats: [
    { r: 1, z: 'torso', i: 5 }, { r: 2, z: 'torso', i: 9 }, { r: 3, z: 'head', i: 1 },
    { r: 0, z: 'head', i: 2 }, { r: 4, z: 'nope', i: 3 }, { r: 5, z: 'head', i: 1.5 }, 'x', { r: 6, i: 4 },
  ] } })
  eq('envelope: whole tattoo rows kept in Lua\'s order; no id, no zone drawn or no tattoo dropped', p.edit.tats,
    [{ r: 1, z: 'torso', i: 5 }, { r: 2, z: 'torso', i: 9 }, { r: 3, z: 'head', i: 1 }])
  eq('envelope: no rows crosses as {} -- the list starts empty',
    parseLocker2({ edit: { sex: 'f', rows: [], tats: {} } }).edit.tats, [])
  const torsoRows = zoneRows(p.edit.tats, 'torso')
  eq('a zone\'s rows, in Lua\'s order, and only its own', [torsoRows.map((r) => r.r), zoneRows(p.edit.tats, 'lleg')], [[1, 2], []])
  eq('max 10 per zone', TATTOOS_PER_ZONE, 10)
  eq('Add: lit below 10, off at 10 -- and off once every tattoo of the zone has a row',
    [canAddTattoo(0, 76), canAddTattoo(9, 76), canAddTattoo(10, 76), canAddTattoo(11, 76), canAddTattoo(3, 3)],
    [true, true, false, false, false])
  // A ROW'S LIST ("attribute editor", 2026-10-12): the zone's tattoos, but
  // none another row of the zone holds, so a zone never has one twice.
  const torsoItems = [{ i: 5 }, { i: 7 }, { i: 9 }, { i: 11 }]
  eq('a row\'s list: the zone\'s tattoos in order, its own kept, the other row\'s left out',
    tattooChoices(torsoItems, torsoRows, torsoRows[0]).map((t) => t.i), [5, 7, 11])
  eq('and the other row\'s list leaves out the first row\'s',
    tattooChoices(torsoItems, torsoRows, torsoRows[1]).map((t) => t.i), [7, 9, 11])
  eq('a zone\'s only row is offered every tattoo of the zone',
    tattooChoices(torsoItems, [torsoRows[0]], torsoRows[0]).map((t) => t.i), [5, 7, 9, 11])
  eq('a zone redraws only when a row comes, goes, moves or changes its tattoo', [
    sameTatRows(torsoRows, torsoRows.map((r) => ({ ...r }))),
    sameTatRows(torsoRows, [torsoRows[0], { ...torsoRows[1], i: 7 }]),
    sameTatRows(torsoRows, [torsoRows[0]]),
    sameTatRows(torsoRows, [torsoRows[1], torsoRows[0]]),
    sameTatRows(torsoRows, [torsoRows[0], { ...torsoRows[1], r: 8 }]),
  ], [true, false, false, false, false])
  eq('tattoo words', [TATTOOS, ZONE_LABEL.head, ZONE_LABEL.torso, ZONE_LABEL.larm, ZONE_LABEL.rarm, ZONE_LABEL.lleg,
    ZONE_LABEL.rleg, tattooFallback(3), BTN.add, BTN.remove],
  ['Tattoos', 'Head', 'Torso', 'Left arm', 'Right arm', 'Left leg', 'Right leg', 'Tattoo 3', 'Add', 'Remove'])
  eq('every zone Lua sends has a word', TATTOO_ZONES.every((z) => typeof ZONE_LABEL[z] === 'string'), true)
  // #28 review: the one tattoo the game has no text for (TAT_AW_000) sits last
  // of Torso's hundreds, and read "Tattoo 326". The nameless are numbered
  // among themselves.
  const torso = [...Array.from({ length: 325 }, (_, k) => ({ i: k + 1, name: `N${k}` })), { i: 999 }]
  eq('the one nameless tattoo at the foot of a zone is "Tattoo 1"', tattooLabels(torso).at(-1), [{ i: 999 }, 'Tattoo 1'])
  eq('nameless ones count only themselves; named ones are the game\'s text',
    tattooLabels([{ i: 1 }, { i: 2, name: 'Skull' }, { i: 3 }]).map(([t, l]) => `${t.i}:${l}`),
    ['1:Tattoo 1', '2:Skull', '3:Tattoo 2'])
}

// ── WIRING (source) ──────────────────────────────────────────────────────────
{
  const app = read(join(SRC, 'App.tsx'))
  check('App.tsx renders Season 2\'s locker only when the flag is on, Season 1\'s otherwise',
    app.includes('<Page name="locker" show={focus === \'locker\'}>{locker2On ? <LockerV2Gate /> : <Locker />}</Page>'))
  check('App.tsx routes the locker2 envelope through the parser',
    app.includes("useNuiEvent('locker2',  (d) => dispatch().setLocker2(parseLocker2(d)))"))
  check('App.tsx never imports the Cloudscape screen itself (it is a chunk)',
    !/from '\.\/screens\/LockerV2'/.test(app))
  const gate = read(join(SRC, 'screens', 'lockerv2', 'Gate.tsx'))
  check('the screen is loaded as a chunk: lazy(import(\'../LockerV2\'))',
    gate.includes("import('../LockerV2')") && /lazy\(load\)/.test(gate))
  check('a chunk that fails or never loads gives the cursor back',
    gate.includes('CB.LOCKER_FOCUS, { open: false }') && gate.includes('componentDidCatch') && gate.includes('LOAD_MS'))

  const v2 = read(join(SRC, 'screens', 'LockerV2.tsx'))
  for (const fn of ['doneSteps(', 'escapeAction(', 'saveVariant(', 'slideDir(', 'tabOptions(', 'openingTab(', 'slideEnds(',
    'followTab(', 'editFor(']) {
    check(`LockerV2.tsx asks model.ts's ${fn.slice(0, -1)}`, v2.includes(fn))
  }
  check('every tab request is numbered', /fetchNui\(CB\.LOCKER2_TAB, \{ tab: t, seq: tabRequests \}\)/.test(v2)
    && (v2.match(/CB\.LOCKER2_TAB/g) ?? []).length === 1)
  check('the page follows Lua on every push', /useEffect\(\(\) => \{\s*go\(followTab\(shownTab\.current, st\.tab, st\.tabSeq \?\? null, sent\.current\)\)\s*\}, \[st\]\)/.test(v2))
  check('no draft is drawn by the tab alone', !/isCustom\(tab\) \? st\.edit/.test(v2))

  const tabs = read(join(SRC, 'screens', 'lockerv2', 'Tabs.tsx'))
  const toCat = /const toCat = \(cat: string\) => \{([\s\S]*?)\n  \}/.exec(tabs)?.[1] ?? ''
  check('every category touch is sent; Lua decides whether the camera moves',
    toCat.includes('fetchNui(CB.LOCKER2_CAT, { cat })') && !/edit\.cat/.test(toCat))
  check('the anchor lit is activeAnchor(edit.cat)', tabs.includes('activeHref={activeAnchor(edit.cat)}'))

  const rows = read(join(SRC, 'screens', 'lockerv2', 'Rows.tsx'))
  check('a slider draws sliderShown(...) and is off when Lua says so',
    rows.includes('value={shown}') && rows.includes('sliderShown(local, row.v, lastTouch.current, Date.now())')
    && rows.includes("row.off === true"))

  // EVERY IMAGE DRAWN TO A CANVAS GOES THROUGH canvasImage: in any file that
  // draws one, no image has its src set by hand.
  const walkSrc = (d) => readdirSync(d, { withFileTypes: true })
    .flatMap((e) => (e.isDirectory() ? walkSrc(join(d, e.name)) : [join(d, e.name)]))
  const drawers = walkSrc(SRC).filter((f) => /\.(tsx?)$/.test(f)).filter((f) => read(f).includes('drawImage('))
  const bare = drawers.filter((f) => {
    const t = read(f)
    return /\.src\s*=(?!=)/.test(t) || (t.includes('new Image(') && !t.includes('canvasImage('))
  })
  check(`every image drawn to a canvas is asked for with CORS (${drawers.length} file(s) draw one)`,
    drawers.length > 0 && bare.length === 0, bare.join(', '))

  // A stored picture comes as a locker2shot with `img`, once, and is kept;
  // the push no longer carries one (it goes out on every press).
  const shots = read(join(SRC, 'screens', 'lockerv2', 'shots.ts'))
  check('a stored picture from Lua is kept for the session, and only an image data URL',
    v2.includes('keepShot(d.id, d.up, d.img)')
    && /export function keepShot\([\s\S]*?!imgOk\(img\)\) return\s*cache\.set\(shotKey\(id, up\), img\)/.test(shots))
  check('Done awaits `close` before it gives the focus back',
    /await fetchNui\(CB\.LOCKER2_CLOSE\)[\s\S]{0,120}await fetchNui\(CB\.LOCKER_FOCUS, \{ open: false \}\)/.test(v2))
  check('the locked tabs carry the hover card as disabledReason',
    v2.includes('disabledReason: o.explained ? LOCKED_TAB : undefined'))
  check('Escape is taken in the capture phase', v2.includes("window.addEventListener('keydown', onKey, true)"))

  // THE TATTOOS SECTION'S WIRING.
  check('the Custom tab asks for its sex\'s tattoo list once it is drawn',
    /useEffect\(\(\) => \{ if \(sex !== null\) askTats\(sex\) \}, \[sex\]\)/.test(tabs))
  check('its anchors follow the row categories, from the list',
    tabs.includes('const cats = [...rowCats, ...tatCats]') && tabs.includes('const tatCats = tattooCats(tats)'))
  check('the section draws Lua\'s rows, and a press moves the camera as a row\'s does',
    tabs.includes('<TattooSection tats={tats} rows={edit.tats} disabled={disabled} onTouch={toCat} />'))
  const tat = read(join(SRC, 'screens', 'lockerv2', 'Tattoos.tsx'))
  // "dude why would we use a bajillion check boxes lol", then "This takes up
  // wayyyy too much real estate ... perhaps we use the thing that's literally
  // made for this - attribute editor" (owner, 2026-10-12).
  check('no checkbox list', !/checkbox/i.test(tat))
  check('no card list, no row arrows, no selection to keep',
    !/<Cards|angle-left|angle-right|selectionType|useState|LOCKER2_TAT_STEP/.test(tat))
  check('one AttributeEditor a zone, drawn for every zone of the list with that zone\'s rows',
    (tat.match(/<AttributeEditor\b/g) ?? []).length === 1
    && tat.includes('<ZoneEditor key={zone.z} zone={zone} rows={zoneRows(rows, zone.z)} disabled={disabled} onTouch={onTouch} />')
    && tat.includes('items={rows}'))
  check('under the zone\'s own heading and anchor',
    /<div id=\{anchorId\(cat\)\} onPointerDown=\{\(\) => onTouch\(cat\)\}>\s*<SpaceBetween size="xs">\s*<Box variant="h5">\{ZONE_LABEL\[zone\.z\] \?\? ''\}<\/Box>\s*<AttributeEditor/
      .test(tat))
  check('compact: the section wears Cloudscape\'s compact density, and only the section',
    tat.includes('className="lk2-tats awsui-compact-mode"')
    && (read(join(SRC, 'screens', 'LockerV2.tsx')) + tabs).indexOf('awsui-compact-mode') === -1)
  check('each item\'s one field is a Select, its Remove beside it on one line at every width',
    /definition=\{\[\{\s*control: \(row: Locker2TatRow\) => \(\s*<Select\b/.test(tat)
    && tat.includes("const ROW_LAYOUT: readonly AttributeEditorProps.GridLayout[] = [{ rows: [[1]], removeButton: { width: 'auto' } }]")
    && tat.includes('gridLayout={ROW_LAYOUT}'))
  check('no label, no empty-state, helper, info or constraint text, no placeholder',
    !/\blabel\s*:/.test(tat)
    && !/\b(empty|additionalInfo|i18nStrings|placeholder|filteringPlaceholder|filteringAriaLabel|noMatch|ariaLabel|removeButtonAriaLabel)=/.test(tat)
    && !/\b(description|info|constraintText|errorText|warningText)\s*:/.test(tat))
  check('the Select filters as typed and opens inside the island, off while the ped is held',
    tat.includes('filteringType="auto"') && tat.includes('expandToViewport={false}') && tat.includes('disabled={disabled}'))
  check('its options are the zone\'s tattoos by the game\'s names, a nameless one numbered among the nameless, never a key',
    tat.includes('const opts = useMemo(() => tattooLabels(zone.items).map(([t, label]) => ({')
    && tat.includes('i: t.i, option: { value: String(t.i), label },'))
  check('a row\'s Select offers none another row of its zone holds, and shows its own',
    tat.includes('options={tattooChoices(opts, rows, row).map((o) => o.option)}')
    && tat.includes('selectedOption={byI.get(row.i) ?? null}'))
  check('choosing asks Lua to put that tattoo in that row, nothing decided here',
    /const i = Number\(detail\.selectedOption\.value\)\s*if \(!Number\.isInteger\(i\) \|\| i === row\.i\) return\s*play\('ui\.select'\)\s*void fetchNui\(CB\.LOCKER2_TAT_SET, \{ r: row\.r, i \}\)/
      .test(tat))
  check('the editor\'s Add asks Lua for a row in its zone, and is off at the cap',
    tat.includes('addButtonText={BTN.add}')
    && /onAddButtonClick=\{\(\) => \{\s*play\('ui\.select'\)\s*void fetchNui\(CB\.LOCKER2_TAT_ADD, \{ z: zone\.z \}\)/.test(tat)
    && tat.includes('disableAddButton={disabled || !canAddTattoo(rows.length, zone.items.length)}'))
  check('the editor\'s own Remove asks Lua to take out that row, by its id',
    tat.includes('removeButtonText={BTN.remove}') && !/customRowActions|isItemRemovable/.test(tat)
    && /onRemoveButtonClick=\{\(\{ detail \}\) => \{\s*const row = rows\[detail\.itemIndex\]\s*if \(!row \|\| disabled\) return\s*play\('ui\.select'\)\s*void fetchNui\(CB\.LOCKER2_TAT_DEL, \{ r: row\.r \}\)/
      .test(tat))
  check('a push redraws a zone only when its rows or its state changed',
    tat.includes("}, (a, b) => a.zone === b.zone && a.disabled === b.disabled && sameTatRows(a.rows, b.rows))"))
  check('a press anywhere in a zone sends its category', tat.includes('onPointerDown={() => onTouch(cat)}'))
  // THE FIRST REMOVE, LEVEL: Cloudscape pads row 1's Remove down by a label's
  // height; with no label, the section's one rule takes that padding off.
  const tatCss = read(join(SRC, 'screens', 'lockerv2', 'tattoos.css'))
  check('the section loads its one rule, which levels the first Remove with its Select',
    tat.includes("import './tattoos.css'")
    && /\.lk2-tats \[class\*='awsui_remove-button-field-padding'\] \{\s*padding-block-start: 0 !important;\s*\}/.test(tatCss)
    && tatCss.replace(/\/\*[\s\S]*?\*\//g, '').match(/\{/g)?.length === 1)
  const aeCss = read(join(ROOT, 'node_modules', '@cloudscape-design', 'components', 'attribute-editor', 'styles.scoped.css'))
  check('the installed Cloudscape still pads the first Remove with that class, by a label\'s height',
    /\.awsui_remove-button-field-padding_\w+:not\(#\\9\) \{\s*padding-block-start: calc\(var\(--space-xxs-\w+, 4px\) \+ var\(--line-height-body-m-\w+, 20px\)\);\s*\}/
      .test(aeCss))
  check('the list arrives on its own envelope and is kept for the session',
    v2.includes("useNuiEvent('locker2tats', (d) => keepTats(d))")
    && /export function keepTats\(raw: unknown\): void \{\s*const t = parseTats\(raw\)/.test(
      read(join(SRC, 'screens', 'lockerv2', 'tattooLists.ts'))))

  const footer = read(join(SRC, 'screens', 'lockerv2', 'Footer.tsx'))
  check('every Save menu opens inside the island (expandToViewport={false})',
    (footer.match(/<ButtonDropdown/g) ?? []).length === 2
    && (footer.match(/expandToViewport=\{false\}/g) ?? []).length === 2)
  check('Done keeps the tutorial\'s anchor', footer.includes('data-tut="locker-done"'))
  const modals = read(join(SRC, 'screens', 'lockerv2', 'Modals.tsx'))
  check('dialogs render into the island (getModalRoot)', modals.includes('getModalRoot={getRoot}'))

  // Every WRITTEN line keeps its marker, so the owner can find each one.
  const copy = read(join(SRC, 'screens', 'lockerv2', 'copy.ts'))
  for (const s of ['Save or reset your changes first.', 'Name your ped', 'Rename ped', 'Discard changes?',
    "'Cancel'", "'Replace'", "'Keep editing'", "'Discard'", "'Save as new'", '`Update ${name}`',
    '`Replace ${name}?`', '`Delete ${name}?`', "'Skin tone'", "'Neck thickness'", "'Shoes'",
    '`${base} opacity`', '`${base} color`', "'Tattoos'", "'Head'", "'Torso'", "'Left arm'", "'Right arm'",
    "'Left leg'", "'Right leg'", '`Tattoo ${n}`', "'Add'", "'Remove'"]) {
    const line = copy.split('\n').find((l) => l.includes(s))
    check(`WRITTEN marker beside ${s}`, line !== undefined && line.includes('// WRITTEN (proposal for the owner)'))
  }

  // No global-styles CSS anywhere in the page.
  const walk = (d) => readdirSync(d, { withFileTypes: true })
    .flatMap((e) => (e.isDirectory() ? walk(join(d, e.name)) : [join(d, e.name)]))
  const globals = walk(SRC).filter((f) => /\.(tsx?|css)$/.test(f))
    .filter((f) => /@cloudscape-design\/global-styles\/[\w-]+\.css/.test(read(f)))
  check('no global-styles stylesheet is imported', globals.length === 0, globals.join(', '))
}

// ── SEASON 1, UNTOUCHED ──────────────────────────────────────────────────────
// "The existing Locker experience is our finished Season 1 product - make sure
// that stays in and remains untouched" (owner, #28). Recorded at 4af6bb48.
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
  check('the main stylesheet carries none of Cloudscape', !indexCss.includes('awsui'))
  check('the main bundle carries none of Cloudscape', !/awsui_[a-z]/.test(indexJs))
  check('the main bundle loads the chunk by name', indexJs.includes('LockerV2.js'))

  if (existsSync(css)) {
    const text = read(css).replace(/\/\*[\s\S]*?\*\//g, '')
    const bad = []
    const global = []
    const ours = []
    let rules = 0
    // The element a selector styles is its last compound. `body.awsui-x {...}`
    // names a Cloudscape class and still styles <body> -- the shape of
    // global-styles -- so a scoped-looking selector whose subject is the page
    // itself counts as global unless all it sets is custom properties.
    const subject = (s) => s.trim().split(/\s*[\s>+~]\s*(?![^(]*\))(?![^[]*\])/).pop() ?? ''
    const allowed = (sel, body) => {
      if (/^@font-face/.test(sel)) return false
      if (/^@keyframes\s+awsui[-_]/.test(sel)) return true
      if (/^@property\s+--/.test(sel)) return true
      if (sel.startsWith('@')) return false
      const declsOnlyVars = body.split(';').map((d) => d.trim()).filter(Boolean).every((d) => d.startsWith('--'))
      if (declsOnlyVars) return true
      const parts = sel.split(',')
      // `*` under a Cloudscape element (`.awsui_icon > svg *`) is scoped; a
      // bare `*`, or html, body or :root as the subject, is the whole page.
      const isGlobal = (s) => /^(html|body|:root)(?![\w-])/.test(subject(s))
        || (/^\*/.test(subject(s)) && !/\.awsui[-_]/.test(s))
      if (parts.some(isGlobal)) {
        global.push(`${sel.slice(0, 100)} {${body.slice(0, 60)}`)
        return false
      }
      // The Tattoos section's own rule (tattoos.css), inside the section only.
      if (parts.every((s) => /^\.lk2-tats\s/.test(s.trim()))) {
        ours.push(`${sel} {${body}}`)
        return true
      }
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
    check(`chunk CSS is Cloudscape's scoped rules only, and the Tattoos section's one (${rules} rules)`,
      rules > 100 && bad.length === 0, bad.slice(0, 5).join('\n          '))
    check('the Tattoos section\'s one rule ships in the chunk, and no other of ours',
      ours.length === 1
      && /^\.lk2-tats \[class\*=['"]?awsui_remove-button-field-padding['"]?\] \{padding-block-start:\s*0(px)?\s*!important;?\}$/.test(ours[0] ?? ''),
      ours.join('\n          '))
    check('and the class it takes the padding off is in the chunk, so it still applies',
      /\.awsui_remove-button-field-padding_\w+:not\(#[^)]*\)\s*\{padding-block-start:/.test(text))
    check('chunk CSS has no @font-face', !/@font-face/.test(text))
    check('chunk CSS styles no html, body, :root or * (global-styles\' shape)', global.length === 0,
      global.slice(0, 3).join('\n          '))
  }
}

console.log(`\ntest-lockerv2: ${ran - failed}/${ran} passed`)
if (failed > 0) process.exit(1)
