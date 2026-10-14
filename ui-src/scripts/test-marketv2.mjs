#!/usr/bin/env node
/**
 * THE SEASON 2 MARKET'S TESTS (#411): the page's rules, its copy, its wiring,
 * its chunk -- and Season 1's Market, byte for byte.
 *
 * Owner, 2026-10-13: "nothing we re-do in the shop should ever show on season
 * 1." src/screens/marketv2/model.ts decides everything the Season 2 Market
 * does before it draws, with no runtime imports, so node's type stripping
 * loads it as-is (test-lockerv2.mjs's shape); copy.ts, look.ts and
 * tutorial/steps.ts the same. These hold each rule to #411 and the owner's
 * notes on the preview (2026-10-14):
 *
 *   TABS      one for each kind with items, in Season 1's order, verdicts
 *             never, the dances only while the season has emotes; the tab
 *             picked kept while it exists, else the first; three designs,
 *             picked by name or number, `bar` by default.
 *   CARDS     Season 1's actions, kind for kind and state for state; a dance
 *             is Unequip on the wheel, Equip off it -- on a full wheel the
 *             replace dialog; the edge equipped, then owned, then rarity; a
 *             dance has no art.
 *   REPLACE   the dialog lists the wheel in slot order, closes when the grid
 *             overtakes it, and its Replace is the existing swap.
 *   PREVIEW   only a dance owned or affordable, only on the dances' tab, sent
 *             to Lua each time it changes, stopped by Done, Escape, a tab
 *             change and the screen going.
 *   CONFIRM   "Are you sure?" and "Buy Crimson canopy for 1,200 Volts?",
 *             every kind; a price press opens it or is refused; a confirm the
 *             grid has overtaken is never drawn, and closes.
 *   COPY      every line marked SEASON 1, OWNER or WRITTEN, and true to it.
 *   TUTORIAL  the Market card's Season 2 line on the Season 2 Market only.
 *
 * And what a unit test cannot see, read from the source and the build:
 *
 *   SEASON 1  screens/Market.tsx is byte-for-byte the finished product, and
 *             App.tsx draws it whenever the envelope does not say `v2`; the
 *             chunk is not even fetched until it does.
 *   BUY       the screen's one MARKET_BUY is the confirm's Buy; a price press
 *             goes through buyPress; nothing on the screen writes the store.
 *   NEW       gone: no badge, no `isNew`, anywhere.
 *   ESCAPE    asks for an open dropdown first, closes a dialog alone, and
 *             holds for a walkthrough card (escapeHeld), in the capture phase.
 *   CORNERS   `is-active` once -- the selected tab; every other corner in the
 *             island square.
 *   BORDERS   the grid's region is the only box that clips, inset GUTTER on
 *             every side, every row inset the same; the island never clips.
 *   NO WRAP   every label on one line, and the grid takes as many columns as
 *             fit at CARD_MIN -- fewer on a narrow screen.
 *   BUTTONS   hover brightens and speaks, a press travels -- the dialogs'
 *             too; a price too dear or a Preview that cannot play does none.
 *   ANCHOR    Done keeps `data-tut="market-done"`, stepped out of the zoom.
 *   PED       a light scrim measured from the panel, ending a short way past
 *             it, so the lobby character stays in view.
 *   CHUNK     assets/MarketV2.{js,css}; the main bundle never imports a chunk
 *             statically and carries none of Cloudscape; every stylesheet the
 *             Market's preload names (its own and the shared Cloudscape one)
 *             is Cloudscape's scoped rules and the Market's, nothing global;
 *             the three tab designs ship.
 *
 * The Lua half (the gate, the grid, the envelope, the Preview's refusals and
 * `brmarkettabs`) is tools/test_market2.lua; the lobby ped's half of the
 * Preview is tools/test_lobbyseq.lua's last block.
 *
 * Run: npm run test:marketv2   (and as part of npm run build, after vite)
 */

import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  DEFAULT_TAB_DESIGN, TAB_DESIGNS, TAB_ORDER, WHEEL_SLOTS, buyPress, canPreview, cardAction, confirmShown, confirmStale,
  edgeOf, hasArt, onWheel, previewShown, replaceChoices, shownTab, swapStale, tabDesign, tabsFor, wheelCount,
} from '../src/screens/marketv2/model.ts'
import {
  BTN, CONFIRM_TITLE, EQUIPPED, KIND_NOUN, NOT_FOR_SALE, REPLACE_TITLE, TAB_LABEL, TITLE, WHEEL_LABEL, amount,
  closedLabel, confirmBody,
} from '../src/screens/marketv2/copy.ts'
import { CARD_MIN, FADE, GAP, GUTTER, PANEL_W, SCRIM } from '../src/screens/marketv2/look.ts'
import { LOBBY_STEPS, bodyFor } from '../src/tutorial/steps.ts'

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
const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/^\s*\/\/.*$/gm, '').replace(/\{\/\*[\s\S]*?\*\/\}/g, '')

// A Season 2 grid as Lua sends it (tools/test_market2.lua holds Lua to it).
const it = (id, kind, extra = {}) => ({ id, name: id, kind, price: 1000, rarity: 2, ...extra })
const S2 = [
  it('chute_rainbow', 'chute', { price: 0, owned: true }), it('chute_azure', 'chute', { owned: true, equipped: true }),
  it('trail_ember', 'trail'), it('wtint_gold', 'weapon', { price: 5000 }),
  it('emote_shuffle', 'emote', { price: 250, owned: true, equipped: true, slot: 1 }),
]
const S1 = [...S2.filter((i) => i.kind !== 'emote'),
  it('ped_yeti', 'character', { price: 9000 }), it('ban_first', 'banner', { price: 0, owned: true })]

// ── TABS ─────────────────────────────────────────────────────────────────────
eq('tabs: one for each kind with real items, in Season 1\'s order',
  tabsFor(S2, true), ['chute', 'trail', 'weapon', 'emote'])
eq('tabs: no Characters or Banners tab without their tiles -- and one for any kind that has some',
  [tabsFor(S2, true).includes('character'), tabsFor(S1, false)], [false, ['chute', 'trail', 'weapon', 'character', 'banner']])
eq('tabs: the dances only while the season has emotes, whatever the grid carries',
  tabsFor(S2, false), ['chute', 'trail', 'weapon'])
eq('tabs: verdicts are never a tab', tabsFor([it('vd_x', 'verdict')], true), [])
eq('tabs: Season 1\'s order, verdicts left out', TAB_ORDER, ['chute', 'trail', 'weapon', 'character', 'banner', 'emote'])
eq('tabs: the one picked while it exists, else the first, null with none',
  [shownTab('weapon', ['chute', 'weapon']), shownTab('emote', ['chute', 'weapon']), shownTab(null, ['trail']), shownTab('chute', [])],
  ['weapon', 'chute', 'trail', null])
eq('tabs: three designs -- bar, rail, folder -- and bar unless one is asked for',
  [TAB_DESIGNS, DEFAULT_TAB_DESIGN, tabDesign(null), tabDesign(undefined), tabDesign('')], [['bar', 'rail', 'folder'], 'bar', 'bar', 'bar', 'bar'])
eq('tabs: a design by name or by number from 1, anything else the default',
  [tabDesign('rail'), tabDesign(' FOLDER '), tabDesign('1'), tabDesign('2'), tabDesign('3'), tabDesign('0'), tabDesign('4'), tabDesign('1.5'), tabDesign('plates')],
  ['rail', 'folder', 'bar', 'rail', 'folder', 'bar', 'bar', 'bar', 'bar'])

// ── CARDS ────────────────────────────────────────────────────────────────────
const full = Array.from({ length: WHEEL_SLOTS }, (_, k) => it(`e${k}`, 'emote', { owned: true, equipped: true, slot: k + 1 }))
eq('cards: equipped is a fact, owned is Equip, a closed season says so, else the price',
  [cardAction(it('a', 'chute', { owned: true, equipped: true }), 0, false),
    cardAction(it('a', 'chute', { owned: true }), 0, false),
    cardAction(it('a', 'chute', { locked: true, season: 'Founders' }), 99999, false),
    cardAction(it('a', 'chute', { locked: true }), 99999, false),
    cardAction(it('a', 'chute'), 1000, false), cardAction(it('a', 'chute'), 999, false)],
  [{ do: 'equipped' }, { do: 'equip' }, { do: 'closed', season: 'Founders' }, { do: 'closed', season: null },
    { do: 'buy', afford: true }, { do: 'buy', afford: false }])
eq('cards: a dance -- Unequip on the wheel, Equip off it (the replace dialog on a full wheel), else its price',
  [cardAction(full[0], 0, true), cardAction(full[0], 0, false),
    cardAction(it('x', 'emote', { owned: true }), 0, true), cardAction(it('x', 'emote', { owned: true }), 0, false),
    cardAction(it('x', 'emote', { price: 250 }), 250, true), cardAction(it('x', 'emote', { price: 250 }), 249, true)],
  [{ do: 'unequip' }, { do: 'unequip' }, { do: 'equipDance', swap: true }, { do: 'equipDance', swap: false },
    { do: 'buy', afford: true }, { do: 'buy', afford: false }])
eq('cards: the edge is equipped, then owned, then rarity',
  [edgeOf(it('a', 'chute', { owned: true, equipped: true })), edgeOf(it('a', 'chute', { owned: true })), edgeOf(it('a', 'chute'))],
  ['equipped', 'owned', 'rarity'])
eq('cards: "emotes shouldn\'t really have a thumbnail" -- every other kind keeps its art',
  ['emote', 'chute', 'trail', 'weapon', 'character', 'banner'].map((k) => hasArt(it('a', k))), [false, true, true, true, true, true])
eq('cards: the wheel counts dances with a slot, and says so as "8/8"',
  [onWheel(full), onWheel(S2), wheelCount(full), wheelCount(S2)], [8, 1, '8/8', '1/8'])

// ── REPLACE ──────────────────────────────────────────────────────────────────
const waiting = it('x', 'emote', { owned: true })
eq('replace: the dialog lists the dances on the wheel in slot order, and nothing else',
  replaceChoices([waiting, { ...full[3] }, it('c', 'chute', { equipped: true }), { ...full[0] }, { ...full[7] }]).map((i) => i.slot),
  [1, 4, 8])
eq('replace: a dialog the grid overtakes closes (room again, gone, unowned, or already on)',
  [swapStale('x', [...full, waiting], true), swapStale('x', [...full.slice(1), waiting], true), swapStale('x', full, true),
    swapStale('x', [...full, { ...waiting, owned: false }], true), swapStale('x', [...full, { ...waiting, slot: 3 }], true),
    swapStale(null, [], true)],
  [false, true, true, true, true, false])
eq('replace: ...and so does one left up when the season closes the dances (none up, nothing to close)',
  [swapStale('x', [...full, waiting], false), swapStale(null, [...full, waiting], false)], [true, false])

// ── PREVIEW ──────────────────────────────────────────────────────────────────
eq('preview: a dance owned, or on sale and affordable -- never one the player cannot pay for, nor any other kind',
  [canPreview(it('x', 'emote', { owned: true, price: 250 }), 0), canPreview(it('x', 'emote', { price: 250 }), 250),
    canPreview(it('x', 'emote', { price: 250 }), 249), canPreview(it('x', 'emote', { price: 250, locked: true }), 9e9),
    canPreview(it('x', 'emote', { owned: true, locked: true }), 0), canPreview(it('c', 'chute', { owned: true }), 9e9)],
  [true, true, false, false, true, false])
{
  const d = it('d', 'emote', { price: 250 })
  eq('preview: the one playing is the one asked for, on the dances\' tab, while the latest grid allows it',
    [previewShown(null, 'emote', [d], 9e9), previewShown('d', 'emote', [d], 250), previewShown('d', 'chute', [d], 9e9),
      previewShown('d', 'emote', [d], 249), previewShown('d', 'emote', [], 9e9), previewShown('d', null, [d], 9e9),
      previewShown('d', 'emote', [{ ...d, owned: true }], 0)],
    [null, 'd', null, null, null, null, 'd'])
}

// ── CONFIRM ──────────────────────────────────────────────────────────────────
eq('confirm: a price press asks first when it can be paid, and is refused when it cannot',
  [buyPress(it('a', 'chute', { price: 6500 }), 6500), buyPress(it('a', 'chute', { price: 6500 }), 6499)], ['confirm', 'refuse'])
eq('confirm: closes once the grid says owned, closed, gone, or too dear; stays otherwise',
  [confirmStale(it('a', 'chute', { owned: true }), 9e9), confirmStale(it('a', 'chute', { locked: true }), 9e9),
    confirmStale(undefined, 9e9), confirmStale(it('a', 'chute'), 999), confirmStale(it('a', 'chute'), 1000)],
  [true, true, true, true, false])
{
  const a = it('a', 'chute')
  eq('confirm: the one drawn is the latest grid\'s item, and never a stale one -- not for a single render',
    [confirmShown(null, [a], 9e9), confirmShown('a', [a], 1000), confirmShown('a', [a], 999),
      confirmShown('a', [{ ...a, owned: true }], 9e9), confirmShown('a', [{ ...a, locked: true }], 9e9), confirmShown('a', [], 9e9),
      confirmShown('a', [{ ...a, price: 1200 }], 1200)],
    [null, a, null, null, null, null, { ...a, price: 1200 }])
}
eq('confirm: "Are you sure?" -- and "Buy [name] canopy for [amount] Volts?", every kind, a comma every three digits',
  [CONFIRM_TITLE, confirmBody('Crimson', 'chute', 1200, 'Volts'), confirmBody('Patriot', 'trail', 1500, 'Volts'),
    confirmBody('Platinum', 'weapon', 6500, 'Volts'), confirmBody('Shuffle', 'emote', 250, 'Volts'), amount(1234567)],
  ['Are you sure?', 'Buy Crimson canopy for 1,200 Volts?', 'Buy Patriot smoke trail for 1,500 Volts?',
    'Buy Platinum weapon finish for 6,500 Volts?', 'Buy Shuffle emote for 250 Volts?', '1,234,567'])

// ── COPY ─────────────────────────────────────────────────────────────────────
const copy = read(join(SRC, 'screens', 'marketv2', 'copy.ts'))
const code = copy.split('\n').filter((l) => !/^\s*(\*|\/\*\*|\/\/)/.test(l))
const lineOf = (s) => code.find((l) => l.includes(s))
const marked = (s, mark) => { const l = lineOf(s); return l !== undefined && l.includes(`// ${mark}`) }
for (const s of ["cancel: 'Cancel'", "buy: 'Buy'", "emote: 'emote'", "character: 'character'", "banner: 'banner'", "'Replace which emote?'"]) {
  check(`WRITTEN marker beside ${s}`, marked(s, 'WRITTEN (proposal for the owner)'))
}
for (const s of ["'Smoke trails'", "'Weapon finishes'", "preview: 'Preview'", "WHEEL_LABEL = 'Equipped'", "'Are you sure?'",
  "chute: 'canopy'", "trail: 'smoke trail'", "weapon: 'weapon finish'", '`Buy ${name} ']) {
  check(`OWNER marker beside ${s}`, marked(s, 'OWNER'))
}
check('every amount is written en-US: a comma every three digits whatever the machine\'s locale',
  copy.includes("export const amount = (n: number): string => n.toLocaleString('en-US')"))
const writtenLines = code.filter((l) => l.includes('// WRITTEN')).length
check('and no other WRITTEN line in the Market\'s copy (6)', writtenLines === 6, String(writtenLines))
eq('the owner\'s words, verbatim: the tabs, Preview, the wheel\'s label, the dialogs\' titles',
  [TAB_LABEL.trail, TAB_LABEL.weapon, BTN.preview, WHEEL_LABEL, CONFIRM_TITLE, REPLACE_TITLE, KIND_NOUN.chute],
  ['Smoke trails', 'Weapon finishes', 'Preview', 'Equipped', 'Are you sure?', 'Replace which emote?', 'canopy'])
const s1 = strip(read(join(SRC, 'screens', 'Market.tsx')))
const s1Words = [TITLE, TAB_LABEL.chute, TAB_LABEL.character, TAB_LABEL.banner, TAB_LABEL.emote, BTN.done, BTN.equip,
  BTN.unequip, BTN.replace, BTN.cancelSwap, EQUIPPED, NOT_FOR_SALE]
const missing = s1Words.filter((w) => !s1.includes(w))
check('every SEASON 1 label is Season 1\'s word for word', missing.length === 0, missing.join(', '))
const s1Marked = code.filter((l) => l.includes('// SEASON 1')).length
check('...and every line marked SEASON 1 is one of them (13)', s1Marked === 13, String(s1Marked))
check('the closed line is Season 1\'s', closedLabel('Founders') === 'Founders — closed' && s1.includes('— closed'))
check('"On wheel" and "New" are gone from the Season 2 Market\'s words',
  !/'On wheel'|'New'/.test(copy) && !/\bON_WHEEL\b|\bNEW\b/.test(copy))

// ── TUTORIAL ─────────────────────────────────────────────────────────────────
const card = LOBBY_STEPS.find((s) => s.id === 'market-inside')
eq('the Market card: Season 1 keeps the old line, the Season 2 Market reads its own',
  [bodyFor(card, false), bodyFor(card, true)],
  ["It may look a bit empty in here for now as we're still working on things.", 'Have a look around, then press **Done**.'])
eq('and it is still on Done, scoped to the Market, waiting on the press',
  [card.target, card.screen, card.advance], ['market-done', 'market', 'click'])
eq('no other card has a Season 2 line', LOBBY_STEPS.filter((s) => s.v2Body !== undefined).map((s) => s.id), ['market-inside'])
const steps = read(join(SRC, 'tutorial', 'steps.ts'))
check('WRITTEN marker beside the Season 2 line',
  steps.split('\n').some((l) => l.includes("v2Body: 'Have a look around") && l.includes('// WRITTEN (proposal for the owner)')))
const layer = strip(read(join(SRC, 'tutorial', 'TutorialLayer.tsx')))
check('the layer draws bodyFor(step, the Market\'s card on the Season 2 Market)',
  layer.includes("body={bodyFor(step, step.screen === 'market' && market2)}")
  && layer.includes('const market2 = useUi((st) => st.market.v2 === true)') && !layer.includes('body={step.body}'))

// ── SEASON 1, UNTOUCHED ──────────────────────────────────────────────────────
// "nothing we re-do in the shop should ever show on season 1." Recorded at
// 156636d5 (Market.tsx last changed at 2c9ec58d).
{
  const SEASON1_MARKET = 'a1f2ae401fa4741da768c4b987d1cc4dd8363de45e818de3d91b2cf7629b2cfa'
  const got = createHash('sha256').update(read(join(SRC, 'screens', 'Market.tsx'))).digest('hex')
  check('screens/Market.tsx is byte-for-byte Season 1\'s', got === SEASON1_MARKET, `sha256 ${got}`)
  const app = read(join(SRC, 'App.tsx'))
  check('App.tsx draws Season 2\'s Market only when the envelope says v2, Season 1\'s otherwise',
    app.includes('<Page name="market" show={focus === \'market\'}>{market2On ? <MarketV2Gate /> : <Market />}</Page>')
    && app.includes('const market2On        = useUi((s) => s.market.v2 === true)'))
  check('App.tsx never imports the Cloudscape screen itself (it is a chunk)', !/from '\.\/screens\/MarketV2'/.test(app))
  check('and fetches the chunk only once the season has it', app.includes('usePreloadMarketV2(market2On)'))
  const gate = read(join(SRC, 'screens', 'marketv2', 'Gate.tsx'))
  // #411's review: without the early return, a Season 1 page downloads
  // MarketV2 and all of Cloudscape at the lobby.
  check('...and the preload fetches nothing while it is off: Season 1 never downloads Cloudscape',
    /export function usePreloadMarketV2\(on: boolean\): void \{\s*useEffect\(\(\) => \{\s*if \(!on\) return\s*load\(\)\.catch\([^\n]*\)\s*\}, \[on\]\)\s*\}/.test(strip(gate))
    && (strip(gate).match(/(?<!function )\bload\(\)/g) ?? []).length === 1)
  check('the screen is loaded as a chunk: lazy(import(\'../MarketV2\'))',
    gate.includes("import('../MarketV2')") && /lazy\(load\)/.test(gate))
  check('a chunk that fails or never loads gives the cursor back',
    gate.includes('CB.MARKET_FOCUS, { open: false }') && gate.includes('componentDidCatch') && gate.includes('LOAD_MS'))
  check('the tab design reaches the store from its own envelope, routed in App.tsx',
    /useNuiEvent\('markettabs', \(d\) => dispatch\(\)\.setMarketTabs\(typeof d\.design === 'string' \? d\.design : null\)\)/.test(strip(app)))
}

// ── THE SCREEN ───────────────────────────────────────────────────────────────
{
  const v2 = strip(read(join(SRC, 'screens', 'MarketV2.tsx')))
  const dir = join(SRC, 'screens', 'marketv2')
  const parts = readdirSync(dir).filter((f) => /\.tsx?$/.test(f)).map((f) => [f, strip(read(join(dir, f)))])
  const all = [['MarketV2.tsx', v2], ...parts]
  const part = (f) => parts.find(([n]) => n === f)?.[1] ?? ''
  const confirm = part('Confirm.tsx')
  const cardSrc = part('Card.tsx')
  const replaceSrc = part('Replace.tsx')
  const strip_ = part('TabStrip.tsx')

  // BUY: one MARKET_BUY, and it is the confirm's.
  const buys = all.flatMap(([f, t]) => [...t.matchAll(/CB\.MARKET_BUY/g)].map(() => f))
  check('the screen sends MARKET_BUY in one place', buys.length === 1 && buys[0] === 'MarketV2.tsx', buys.join(', '))
  check('...the confirm\'s Buy: `buy` sends it and goes only to BuyConfirm\'s onBuy',
    /const buy = \(it: MarketItem\) => \{\s*play\('ui\.select'\)\s*setConfirmId\(null\)\s*void fetchNui\(CB\.MARKET_BUY, \{ id: it\.id \}\)\s*\}/.test(v2)
    && (v2.match(/\bbuy\b(?!Press)/g) ?? []).length === 2 && v2.includes('onBuy={buy}'))
  check('...and the confirm\'s Buy button is what calls onBuy',
    /<Button variant="primary" onClick=\{\(\) => \{ if \(item\) onBuy\(item\) \}\}>\{BTN\.buy\}<\/Button>/.test(confirm))
  check('the confirm is the owner\'s: "Are you sure?" over his sentence, and no art',
    confirm.includes('header={CONFIRM_TITLE}')
    && confirm.includes('{shown && <Box variant="p"><span style={ONE_LINE}>{confirmBody(shown.name, shown.kind, shown.price, currency)}</span></Box>}')
    && !/<Art\b|\bArt\b/.test(confirm))
  check('a price press goes through buyPress: the confirm, or the error cue',
    /onPrice: \(it\) => \{\s*if \(buyPress\(it, market\.balance\) === 'refuse'\) \{ play\('ui\.error'\); return \}\s*play\('ui\.select'\)\s*setConfirmId\(it\.id\)/.test(v2))
  check('a card\'s price is that press, and nothing on a card can buy',
    /case 'buy':[\s\S]*?press = \(\) => h\.onPrice\(item\)/.test(cardSrc) && !/fetchNui/.test(cardSrc))
  check('the confirm drawn is confirmShown\'s, and a stale one is forgotten',
    v2.includes('const confirming = confirmShown(confirmId, market.items, market.balance)')
    && v2.includes('const confirmGone = confirmId !== null && confirming === null')
    && v2.includes('useEffect(() => { if (confirmGone) setConfirmId(null) }, [confirmGone])')
    && v2.includes('item={confirming}') && !/confirmStale/.test(v2))

  // REPLACE: Equip on a full wheel opens the dialog; its Replace is the swap.
  check('Equip on a full wheel opens the replace dialog for that dance, and nothing else does',
    /case 'equipDance':\s*label = BTN\.equip\s*press = \(\) => \{ play\('ui\.select'\); if \(a\.swap\) h\.onSwap\(item\); else h\.onEquip\(item\) \}/.test(cardSrc)
    && v2.includes('onSwap: (it) => { setSwapFor(it.id) },')
    && (v2.match(/setSwapFor\(it\.id\)/g) ?? []).length === 1)
  check('the dialog is the wheel in slot order, open while a swap waits and the grid has not overtaken it',
    v2.includes('choices={replaceChoices(market.items)}') && v2.includes('open={replacing}')
    && v2.includes('const replacing = swapFor !== null && !stale')
    && v2.includes('const stale = swapStale(swapFor, market.items, emotesOn)')
    && v2.includes('useEffect(() => { if (stale) setSwapFor(null) }, [stale])'))
  const replaces = all.flatMap(([f, t]) => [...t.matchAll(/MARKET_EQUIP[^\n]*\breplace\b/g)].map(() => f))
  check('its Replace is the existing swap -- MARKET_EQUIP { id, replace } -- and the only one',
    /const replace = \(out: MarketItem\) => \{\s*if \(swapFor === null\) return\s*void fetchNui\(CB\.MARKET_EQUIP, \{ id: swapFor, replace: out\.id \}\)\s*setSwapFor\(null\)\s*\}/.test(v2)
    && replaces.join(',') === 'MarketV2.tsx' && v2.includes('onReplace={replace}'))
  check('each row\'s Replace calls onReplace with that dance; Cancel closes it',
    replaceSrc.includes("onClick={() => { play('ui.select'); onReplace(it) }}") && replaceSrc.includes('header={REPLACE_TITLE}')
    && /<Button variant="link" onClick=\{onCancel\}>\{BTN\.cancelSwap\}<\/Button>/.test(replaceSrc)
    && replaceSrc.includes('{rows.map((it) => ('))
  check('no card offers Replace or the old cut Cancel any more', !/BTN\.replace|BTN\.cancelSwap|is-active/.test(cardSrc))

  // PREVIEW.
  check('Preview is on a dance\'s card only, spent where canPreview says no, lit while it plays',
    cardSrc.includes("{item.kind === 'emote' && <Preview item={item} balance={balance} playing={previewing === item.id} h={h} />}")
    && cardSrc.includes('const able = canPreview(item, balance)') && cardSrc.includes('disabled={!able}')
    && cardSrc.includes('style={previewStyle(playing)}')
    && cardSrc.includes("<span className={able ? 'mk2-act' : undefined} style={{ display: 'block' }} onPointerEnter={() => { if (able) play('ui.hover') }}>"))
  check('its press asks for that dance, or for none when it is the one playing',
    v2.includes('onPreview: (it) => { setPreviewId(previewing === it.id ? null : it.id) },'))
  check('Lua is told previewShown\'s answer each time it changes, and nothing on first draw',
    v2.includes('const previewing = previewShown(previewId, tab, market.items, market.balance)')
    && /useEffect\(\(\) => \{\s*if \(told\.current === previewing\) return\s*told\.current = previewing\s*void fetchNui\(CB\.MARKET_PREVIEW, \{ id: previewing \}\)\s*\}, \[previewing\]\)/.test(v2)
    && v2.includes('const told = useRef<string | null>(null)'))
  check('...and stopped as the screen goes, by Done or Escape (close) and by the screen unmounting',
    /const close = \(\) => \{\s*setPreviewId\(null\)\s*if \(told\.current !== null\) \{ told\.current = null; void fetchNui\(CB\.MARKET_PREVIEW, \{ id: null \}\) \}\s*void fetchNui\(CB\.MARKET_FOCUS, \{ open: false \}\)\s*\}/.test(v2)
    && /useEffect\(\(\) => \(\) => \{\s*if \(told\.current !== null\) void fetchNui\(CB\.MARKET_PREVIEW, \{ id: null \}\)\s*\}, \[\]\)/.test(v2))
  const previews = all.flatMap(([f, t]) => [...t.matchAll(/CB\.MARKET_PREVIEW/g)].map(() => f))
  check('MARKET_PREVIEW is sent from those three places and no others', previews.length === 3 && previews.every((f) => f === 'MarketV2.tsx'), previews.join(', '))

  // NEW: gone.
  const badges = all.filter(([, t]) => /<Badge\b|\bisNew\b|\bNEW_BADGE\b/.test(t)).map(([f]) => f)
  check('New is gone: no badge and no `isNew` on the screen', badges.length === 0, badges.join(', '))
  check('...nor in the page\'s types or the harness', !/\bisNew\b/.test(read(join(SRC, 'bridge', 'types.ts')))
    && !/\bisNew\b/.test(read(join(SRC, 'bridge', 'mockMarket.ts'))))

  // A DANCE HAS NO ART.
  check('a card draws its art only where hasArt says so',
    cardSrc.includes('const art = hasArt(item)') && /\{art && \(\s*<div[^>]*>\s*<Art item=\{item\} \/>/.test(cardSrc))

  // HOVER AND PRESS (index.css `.btn`, check-ui R3).
  check('a card\'s button brightens, travels and speaks -- a price too dear does none of it',
    cardSrc.includes("<span className={quiet ? undefined : 'mk2-act'} style={{ display: 'block' }} onPointerEnter={() => { if (!quiet) play('ui.hover') }}>"))
  check('the confirm\'s Cancel and Buy speak on hover and travel on the press, as Done does',
    /<span className="mk2-act" onPointerEnter=\{\(\) => play\('ui\.hover'\)\}>\s*<Button variant="link" onClick=\{onCancel\}>/.test(confirm)
    && /<span className="mk2-act" onPointerEnter=\{\(\) => play\('ui\.hover'\)\}>\s*<Button variant="primary" onClick=\{\(\) => \{ if \(item\) onBuy\(item\) \}\}>/.test(confirm)
    && confirm.includes("import { play } from '../../audio/cues'"))
  check('...and the replace dialog\'s too',
    /<span className="mk2-act" onPointerEnter=\{\(\) => play\('ui\.hover'\)\}>\s*<Button variant="link" onClick=\{onCancel\}>/.test(replaceSrc)
    && /<span className="mk2-act" style=\{\{ flex: '0 0 auto' \}\} onPointerEnter=\{\(\) => play\('ui\.hover'\)\}>\s*<Button style=\{actionStyle\(GOLD_INK\)\}/.test(replaceSrc))
  const bare = all.filter(([, t]) => /toLocaleString\(\)/.test(t)).map(([f]) => f)
  check('...and nothing on the screen writes a number in the machine\'s locale', bare.length === 0, bare.join(', '))
  const writes = all.filter(([, t]) => /\bsetMarket\b|\bdispatch\(|useUi\.setState|\.getState\(\)\.set/.test(t)).map(([f]) => f)
  check('nothing on the screen writes the store: every number is the server\'s grid', writes.length === 0, writes.join(', '))

  // ESCAPE.
  check('Escape asks for an open dropdown first, closes a dialog alone, holds for a card -- in the capture phase',
    /e\.key !== 'Escape'\) return\s*const act = escapeAction\(live\.current\.dialog, escapeHeld\(\), popupOpen\(screen\.current\)\)\s*if \(act === 'pass'\) return\s*e\.preventDefault\(\)\s*e\.stopPropagation\(\)\s*if \(act === 'modal'\) \{ play\('ui\.back'\); setConfirmId\(null\); setSwapFor\(null\); return \}\s*if \(act === 'done'\) \{ play\('ui\.back'\); live\.current\.close\(\) \}/.test(v2)
    && v2.includes("window.addEventListener('keydown', onKey, true)")
    && v2.includes('<div ref={screen} className="interactive fixed inset-0 z-50">')
    && v2.includes('live.current = { dialog: confirming !== null || replacing, close }'))
  check('both dialogs render into the island (getModalRoot)',
    confirm.includes('getModalRoot={getRoot}') && /<IslandModal\b/.test(replaceSrc) && v2.includes('root={modalRoot}'))

  // TABS: our own tablist, in the design the store names.
  check('the tabs are TabStrip, one for each kind tabsFor gives, in the design tabDesign names',
    v2.includes('const tabs = tabsFor(market.items, emotesOn)') && v2.includes('const tab = shownTab(picked, tabs)')
    && v2.includes('const design = tabDesign(useUi((s) => s.marketTabs))')
    && /<TabStrip\s+tabs=\{tabs\}\s+tab=\{tab\}\s+design=\{design\}/.test(v2)
    && !/@cloudscape-design\/components\/tabs/.test(all.map(([, t]) => t).join('\n')))
  check('a tab change speaks, drops a waiting replace and stops the preview',
    /onPick=\{\(k\) => \{\s*play\('ui\.select'\)\s*setPicked\(k\)\s*setSwapFor\(null\)\s*setPreviewId\(null\)\s*\}\}/.test(v2))
  check('TabStrip is a tablist: role="tab", aria-selected, the selected one the only Tab stop, the arrows move along it',
    strip_.includes('role="tablist"') && strip_.includes('role="tab"') && strip_.includes('aria-selected={on}')
    && strip_.includes('tabIndex={on ? 0 : -1}') && /'ArrowRight'[\s\S]*'ArrowLeft'[\s\S]*'Home'[\s\S]*'End'/.test(strip_)
    && strip_.includes('className={`mk2-tabs mk2-tabs--${design}`}'))
  check('every tab is a lobby button and a plate, in Anton, with its label from copy.ts',
    strip_.includes("className={`mk2-tab btn plate font-display uppercase${on ? ' is-active' : ''}`}")
    && strip_.includes('{TAB_LABEL[k]}') && strip_.includes("onPointerEnter={() => play('ui.hover')}"))

  // CORNERS: `is-active` exactly where Season 1 has it.
  const actives = all.flatMap(([f, t]) => [...t.matchAll(/is-active/g)].map((m) => `${f}:${t.slice(Math.max(0, m.index - 80), m.index + 20).replace(/\s+/g, ' ')}`))
  check('one cut corner set and no more: the selected tab', actives.length === 1 && actives[0].startsWith('TabStrip.tsx'), actives.join('\n          '))
  check('...and a card is a plate at rest', cardSrc.includes('className="plate"'))
  check('no plate is given --cut directly', !all.some(([, t]) => /--cut'/.test(t) || /'--cut' as/.test(t)))
  check('...and everything else square: the island is `.mk2`, whose every corner market.css squares',
    v2.includes('className="mk2 br-cs flex min-h-0 flex-1 flex-col pointer-events-auto"')
    && /<div ref=\{setModalRoot\} className="pointer-events-auto" \/>\s*<\/div>\s*<\/div>\s*<BuyConfirm/.test(v2))

  // BORDERS: "please put in some change to ensure the borders always draw
  // around everything which should have a border" (owner, 2026-10-14).
  const clips = all.flatMap(([f, t]) => [...t.matchAll(/overflow[XY]?: '(?:auto|hidden|scroll)'|overflow-(?:hidden|auto|scroll)/g)].map((m) => `${f}:${m[0]}`))
  check('the grid\'s region is the only box on the screen that clips (the art frame aside, which has no border)',
    clips.sort().join(',') === "Card.tsx:overflow: 'hidden',MarketV2.tsx:overflowX: 'hidden',MarketV2.tsx:overflowY: 'auto'", clips.join(', '))
  check('...and it is inset GUTTER on every side',
    v2.includes("style={{ flex: '1 1 auto', minHeight: 0, overflowX: 'hidden', overflowY: 'auto', padding: GUTTER }}"))
  const g = /^(\d+(?:\.\d+)?)em$/.exec(GUTTER)
  check('GUTTER is wider than a border at the smallest em (11px root x 0.8): at least 2px',
    g !== null && Number(g[1]) * 11 * 0.8 >= 2, GUTTER)
  const rows = (v2.match(/\.\.\.row,/g) ?? []).length
  check('every other row -- the header, the tabs, the wheel\'s count, Done -- is inset the same, in line with the cards',
    v2.includes('const row = { paddingInline: GUTTER }') && rows === 4, String(rows))

  // NO WRAP: "text wrapping should not be allowed. if you can't fit the text,
  // don't draw it" (owner, 2026-10-14).
  check('the grid takes as many columns as fit at CARD_MIN -- fewer on a narrow screen, four at most',
    v2.split('...GRID').length === 3 && /^\d+(\.\d+)?em$/.test(CARD_MIN) && /^\d+(\.\d+)?em$/.test(GAP)
    && read(join(SRC, 'screens', 'marketv2', 'look.ts')).includes('gridTemplateColumns: `repeat(auto-fill, minmax(${CARD_MIN}, 1fr))`'))
  {
    // Four columns of CARD_MIN, with their gaps and the grid's gutters, fit in
    // the panel at its full 48rem less its padding: four across at 16:9.
    const em = (s) => Number(/^(\d+(?:\.\d+)?)em$/.exec(s)?.[1] ?? NaN)
    const four = 4 * em(CARD_MIN) + 3 * em(GAP) + 2 * em(GUTTER)
    check(`...four of them fit the panel at 16:9 (${four.toFixed(2)}em of 42em)`, PANEL_W === 'min(48rem, 64vw)' && four <= 42
      && v2.includes('className="absolute inset-y-0 left-0 px-[3rem] py-[3rem] flex flex-col pointer-events-none"'))
  }
  const oneLine = [
    ['Card.tsx', "<span className=\"font-display uppercase\" style={{ ...ONE_LINE, letterSpacing: '0.12em', fontWeight: 400 }}>"],
    ['Card.tsx', "<div className=\"tscale\" style={{ ...ONE_LINE, lineHeight: 1.2 }}>{item.name}</div>"],
    ['Card.tsx', '{item.sub && <div style={ONE_LINE}>'],
    ['Card.tsx', "style={{ ...ONE_LINE, textAlign: 'center', letterSpacing: '0.14em'"],
    ['Card.tsx', "<div style={{ ...ONE_LINE, textAlign: 'center', padding: '0.35em 0', opacity: 0.55 }}>"],
    ['Replace.tsx', '<span style={{ ...ONE_LINE, minWidth: 0 }}>{it.name}</span>'],
    ['Confirm.tsx', 'header={<span style={ONE_LINE}>{header}</span>}'],
    ['MarketV2.tsx', "style={{ ...ONE_LINE, fontSize: '2.6em'"],
    ['MarketV2.tsx', '...wheelPlate(wheelFull), ...ONE_LINE,'],
    ['MarketV2.tsx', "style={{ ...BALANCE_PLATE, ...ONE_LINE,"],
    ['MarketV2.tsx', "<span className=\"font-display uppercase\" style={{ ...ONE_LINE, letterSpacing: '0.1em', fontWeight: 400 }}>{BTN.done}</span>"],
  ]
  const loose = oneLine.filter(([f, s]) => !(f === 'MarketV2.tsx' ? v2 : part(f)).includes(s)).map(([f, s]) => `${f}: ${s.slice(0, 50)}`)
  check('every label is held to one line: names, kinds, buttons, the title, the balance, the count, the dialogs',
    loose.length === 0, loose.join('\n          '))

  // THE WHEEL'S COUNT: "Equipped" and "8/8", one card wide in the cards' grid.
  check('the wheel\'s count: "Equipped" and "8/8", on the dances\' tab, one card wide in the cards\' column, centered',
    /\{tab === 'emote' && \(\s*<div style=\{\{ \.\.\.row, \.\.\.GRID, flex: '0 0 auto', marginBottom: '0\.6em' \}\}>/.test(v2)
    && v2.includes("display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '0.75em',")
    && v2.includes('{WHEEL_LABEL}') && v2.includes('{wheelCount(market.items)}'))

  // THE WALKTHROUGH'S ANCHOR.
  check('Done keeps the walkthrough\'s anchor, stepped out of the zoom, and closes the Market',
    /<span data-tut="market-done" style=\{\{ display: 'inline-block', zoom: 1 \/ z \}\}>\s*<span className="mk2-act" style=\{\{ display: 'inline-block', zoom: z \}\} onPointerEnter=\{\(\) => play\('ui\.hover'\)\}>\s*<Button variant="primary" onClick=\{\(\) => \{ play\('ui\.back'\); close\(\) \}\}>/.test(v2))

  // THE LOBBY CHARACTER STAYS IN VIEW.
  {
    const bg = String(SCRIM.background)
    const alphas = [...bg.matchAll(/rgba\(6, 8, 14, ([\d.]+)\)/g)].map((m) => Number(m[1]))
    check('the scrim is lighter and ends a short way past the panel: no stop above 0.8, the last clear, its width the panel\'s plus FADE',
      alphas.length === 3 && Math.max(...alphas) <= 0.8 && alphas[2] === 0 && SCRIM.width === `calc(${PANEL_W} + ${FADE})`
      && /^\d+(\.\d+)?rem$/.test(FADE) && Number.parseFloat(FADE) <= 8, `${bg} / ${String(SCRIM.width)}`)
    check('...and it is the screen\'s only fill: the screen itself draws nothing, the panel is PANEL_W wide',
      !/className="interactive fixed inset-0 z-50"[^>]*style=/.test(v2)
      && v2.includes('<div className="absolute inset-y-0 left-0 pointer-events-none" style={SCRIM} />')
      && v2.includes('style={{ width: PANEL_W }}'))
  }

  // CLOUDSCAPE, AS LOCKER V2 HAS IT.
  check('the shared Cloudscape setup: mode and theme on while up, the island\'s zoom, portals zoomed',
    v2.includes('useCloudscapeScope()') && v2.includes('const z = useIslandZoom()') && v2.includes('usePortalZoom(z)')
    && v2.includes("style={{ zoom: z, fontSize: `calc(1rem / ${z})` }}"))
  const scope = read(join(SRC, 'screens', 'lockerv2', 'scope.ts'))
  check('one theme, shared: ui/cloudscape/theme.ts, and only the shared setup applies it',
    existsSync(join(SRC, 'ui', 'cloudscape', 'theme.ts')) && !existsSync(join(SRC, 'screens', 'lockerv2', 'theme.ts'))
    && scope.includes("from '../../ui/cloudscape/theme'"))
}

// ── THE HARNESS ──────────────────────────────────────────────────────────────
{
  const mock = read(join(SRC, 'bridge', 'mock.ts'))
  const mm = read(join(SRC, 'bridge', 'mockMarket.ts'))
  check('`?market` opens the Market in the harness', mock.includes('if (/[?&]market\\b/.test(window.location.search)) {'))
  check('`?season=1` is Season 1\'s Market there, Season 2\'s otherwise',
    mm.includes('const v2 = !/[?&]season=1\\b/.test(window.location.search)') && mm.includes('if (!v2) items.push(...PLACEHOLDERS)'))
  check('`?tabs=` picks the tab design there, through the envelope brmarkettabs sends',
    mm.includes("const tabs = new URLSearchParams(window.location.search).get('tabs')")
    && mm.includes("if (v2 && tabs !== null) emit({ k: 'markettabs', d: { design: tabs } })"))
  check('a Preview press is answered there', mock.includes("|| name === 'br/market/preview')") && mm.includes("if (name === 'br/market/preview') return true"))
}

// ── THE CHUNK (build output) ─────────────────────────────────────────────────
if (!existsSync(OUT)) {
  check('the build output exists (run the build first)', false, OUT)
} else {
  const js = join(OUT, 'MarketV2.js')
  const css = join(OUT, 'MarketV2.css')
  check('assets/MarketV2.js and assets/MarketV2.css are built', existsSync(js) && existsSync(css))
  const indexJs = read(join(OUT, 'index.js'))
  const indexCss = read(join(OUT, 'index.css'))
  check('the main bundle loads the chunk by name', indexJs.includes('./MarketV2.js'))
  const statics = [...indexJs.matchAll(/(?:^|[;}\n])\s*import\s*(?:[\w$]+|\{[^}]*\}|\*\s*as\s*[\w$]+)\s*from\s*"([^"]+)"/g)].map((m) => m[1])
  check('the main bundle imports no chunk statically -- Season 1 never loads Cloudscape', statics.length === 0, statics.join(', '))
  check('the main bundle and stylesheet carry none of Cloudscape', !/awsui_[a-z]/.test(indexJs) && !indexCss.includes('awsui'))
  // EVERY STYLESHEET THE MARKET BRINGS, not only its own (#411's review): the
  // Cloudscape both Season 2 screens reach is a shared chunk (index2.css,
  // vite.config.ts), which no other test read. Its names come from the main
  // bundle's preload list, `__vite__mapDeps([chunk, ...its deps])`, so a
  // renamed shared chunk is still read.
  const depFiles = (() => {
    const m = indexJs.match(/m\.f=(\[[^\]]*\])/)
    try { return m ? JSON.parse(m[1]) : [] } catch { return [] }
  })()
  const preloads = [...indexJs.matchAll(/__vite__mapDeps\(\[([\d,]+)\]\)/g)]
    .map((m) => m[1].split(',').map((n) => depFiles[Number(n)]))
  const marketCss = (preloads.find((d) => d[0] === './MarketV2.js') ?? []).filter((f) => /\.css$/.test(f ?? ''))
  check('the Market\'s preload names its stylesheet and the shared Cloudscape one',
    marketCss.includes('./MarketV2.css') && marketCss.length >= 2 && marketCss.every((f) => existsSync(join(OUT, f))),
    marketCss.join(', '))
  // test-lockerv2.mjs's rule, for every one of them: the element a selector
  // styles is its last compound, so `body.awsui-x {...}` styles <body> and
  // counts as global unless all it sets is custom properties (Cloudscape's
  // base theme); every other rule names a Cloudscape class, or is the
  // Market's own (`.mk2`, `.mk2-...`).
  const subject = (s) => s.trim().split(/\s*[\s>+~]\s*(?![^(]*\))(?![^[]*\])/).pop() ?? ''
  const ours = []
  for (const f of marketCss) {
    const p = join(OUT, f)
    if (!existsSync(p)) continue
    const text = read(p).replace(/\/\*[\s\S]*?\*\//g, '')
    const bad = []
    const globals = []
    let rules = 0
    const allowed = (sel, body) => {
      if (/^@keyframes\s+awsui[-_]/.test(sel)) return true
      if (/^@property\s+--/.test(sel)) return true
      if (sel.startsWith('@')) return false
      if (body.split(';').map((d) => d.trim()).filter(Boolean).every((d) => d.startsWith('--'))) return true
      const parts = sel.split(',')
      const isGlobal = (s) => /^(html|body|:root)(?![\w-])/.test(subject(s))
        || (/^\*/.test(subject(s)) && !/\.awsui[-_]|^\.mk2[\s-]/.test(s.trim()))
      if (parts.some(isGlobal)) { globals.push(sel.slice(0, 80)); return false }
      if (parts.every((s) => /^\.mk2[\s-]/.test(s.trim()))) { ours.push(`${sel}{${body}}`); return true }
      return parts.every((s) => /\.awsui[-_]/.test(s))
    }
    const walk = (t) => {
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
        if (/^@(media|supports|container|layer)\b/.test(sel)) walk(body)
        else { rules++; if (!allowed(sel, body)) bad.push(`${sel.slice(0, 80)} {${body.slice(0, 50)}`) }
        i = j
      }
    }
    walk(text)
    check(`${f.slice(2)}: no @font-face, nothing on html, body, :root or *, only Cloudscape's scoped rules and the Market's (${rules} rules)`,
      rules > 0 && !/@font-face/.test(text) && globals.length === 0 && bad.length === 0,
      [...globals, ...bad].slice(0, 3).join('\n          '))
  }
  // The Market's own rules (market.css), as they ship.
  const own = ours.join('\n')
  check('market.css ships: every corner in the island square',
    ours.some((r) => {
      const m = r.match(/^([^{]*)\{border-radius:\s*0(?:px)?\s*!important;?\}$/)
      const sel = m ? m[1].split(',').map((s) => s.trim().replace(/::/g, ':')).sort().join(',') : ''
      return sel === '.mk2 *,.mk2 *:after,.mk2 *:before'
    }), own)
  check('...a button brightens on hover and travels on the press, as index.css `.btn` does',
    /\.mk2-act \[class\*=['"]?awsui_button_['"]?\]:hover:not\(\[class\*=['"]?awsui_disabled_['"]?\]\)\{filter:\s*brightness\(1\.18\)\s*!important;?\}/.test(own)
    && /\.mk2-act \[class\*=['"]?awsui_button_['"]?\]:active:not\(\[class\*=['"]?awsui_disabled_['"]?\]\)\{transform:\s*translateY\(1px\)\s*scale\(0?\.975\)\s*!important;\s*filter:\s*brightness\(0?\.94\)\s*!important;?\}/.test(own),
    own)
  const designs = TAB_DESIGNS.filter((d) => !ours.some((r) => r.startsWith(`.mk2-tabs--${d}`)))
  check('...the three tab designs ship, each its own rules', designs.length === 0, designs.join(', '))
  check('...and the tab row never wraps, nor does a tab\'s label',
    ours.some((r) => /^\.mk2-tabs\{[^}]*flex-wrap:\s*nowrap/.test(r)) && ours.some((r) => /^\.mk2-tab\{[^}]*white-space:\s*nowrap/.test(r)), own.slice(0, 300))
}

console.log(`\ntest-marketv2: ${ran - failed}/${ran} passed`)
if (failed > 0) process.exit(1)
