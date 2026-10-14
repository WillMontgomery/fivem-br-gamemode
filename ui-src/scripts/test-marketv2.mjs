#!/usr/bin/env node
/**
 * THE SEASON 2 MARKET'S TESTS (#411): the page's rules, its copy, its wiring,
 * its chunk -- and Season 1's Market, byte for byte.
 *
 * Owner, 2026-10-13: "nothing we re-do in the shop should ever show on season
 * 1." src/screens/marketv2/model.ts decides everything the Season 2 Market
 * does before it draws, with no runtime imports, so node's type stripping
 * loads it as-is (test-lockerv2.mjs's shape); copy.ts and tutorial/steps.ts
 * the same. These hold each rule to #411:
 *
 *   TABS      one for each kind with items, in Season 1's order, verdicts
 *             never, the dances only while the season has emotes; the tab
 *             picked kept while it exists, else the first.
 *   CARDS     Season 1's actions, kind for kind and state for state, the
 *             wheel's swap included (dropped when the grid overtakes it or the
 *             season closes the dances); the edge equipped, then owned, then
 *             rarity.
 *   CONFIRM   a price press opens the confirm or is refused; a confirm the
 *             grid has overtaken is never drawn, and closes.
 *   COPY      every WRITTEN line marked; every Season 1 label word for word.
 *   TUTORIAL  the Market card's Season 2 line on the Season 2 Market only.
 *
 * And what a unit test cannot see, read from the source and the build:
 *
 *   SEASON 1  screens/Market.tsx is byte-for-byte the finished product, and
 *             App.tsx draws it whenever the envelope does not say `v2`; the
 *             chunk is not even fetched until it does.
 *   BUY       the screen's one MARKET_BUY is the confirm's Buy; a price press
 *             goes through buyPress; nothing on the screen writes the store.
 *   NEW       on the card, only where Lua marked `isNew`.
 *   ESCAPE    asks for an open dropdown first, closes the confirm alone, and
 *             holds for a walkthrough card (escapeHeld), in the capture phase.
 *   CORNERS   `is-active` twice: the selected tab's label, the swap's Cancel;
 *             every other corner in the island square.
 *   BUTTONS   hover brightens and speaks, a press travels -- the confirm's
 *             too; a price too dear does none of it.
 *   ANCHOR    Done keeps `data-tut="market-done"`, stepped out of the zoom.
 *   PED       no full-screen fill: a scrim that fades out, a panel at most
 *             64vw, so the lobby character stays in view.
 *   CHUNK     assets/MarketV2.{js,css}; the main bundle never imports a chunk
 *             statically and carries none of Cloudscape; every stylesheet the
 *             Market's preload names (its own and the shared Cloudscape one)
 *             is Cloudscape's scoped rules and the Market's, nothing global.
 *
 * The Lua half (the gate, the grid, the envelope) is tools/test_market2.lua.
 *
 * Run: npm run test:marketv2   (and as part of npm run build, after vite)
 */

import { createHash } from 'node:crypto'
import { existsSync, readFileSync, readdirSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  TAB_ORDER, WHEEL_SLOTS, buyPress, cardAction, confirmShown, confirmStale, edgeOf, onWheel, shownTab, swapStale, tabsFor,
} from '../src/screens/marketv2/model.ts'
import { BTN, EQUIPPED, NEW, NOT_FOR_SALE, ON_WHEEL, TAB_LABEL, TITLE, closedLabel, confirmTitle } from '../src/screens/marketv2/copy.ts'
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
  it('emote_shuffle', 'emote', { price: 250, owned: true, equipped: true, slot: 1, isNew: true }),
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

// ── CARDS ────────────────────────────────────────────────────────────────────
const full = Array.from({ length: WHEEL_SLOTS }, (_, k) => it(`e${k}`, 'emote', { owned: true, equipped: true, slot: k + 1 }))
eq('cards: equipped is a fact, owned is Equip, a closed season says so, else the price',
  [cardAction(it('a', 'chute', { owned: true, equipped: true }), 0, null, false),
    cardAction(it('a', 'chute', { owned: true }), 0, null, false),
    cardAction(it('a', 'chute', { locked: true, season: 'Founders' }), 99999, null, false),
    cardAction(it('a', 'chute', { locked: true }), 99999, null, false),
    cardAction(it('a', 'chute'), 1000, null, false), cardAction(it('a', 'chute'), 999, null, false)],
  [{ do: 'equipped' }, { do: 'equip' }, { do: 'closed', season: 'Founders' }, { do: 'closed', season: null },
    { do: 'buy', afford: true }, { do: 'buy', afford: false }])
eq('cards: a dance -- Unequip on the wheel, Replace while another waits, Cancel on the one waiting, Equip (a swap on a full wheel)',
  [cardAction(full[0], 0, null, true), cardAction(full[0], 0, 'x', true),
    cardAction(it('x', 'emote', { owned: true }), 0, 'x', true),
    cardAction(it('x', 'emote', { owned: true }), 0, null, true), cardAction(it('x', 'emote', { owned: true }), 0, null, false),
    cardAction(it('x', 'emote', { price: 250 }), 250, null, true)],
  [{ do: 'unequip' }, { do: 'replace' }, { do: 'cancel' }, { do: 'equipDance', swap: true },
    { do: 'equipDance', swap: false }, { do: 'buy', afford: true }])
eq('cards: the edge is equipped, then owned, then rarity',
  [edgeOf(it('a', 'chute', { owned: true, equipped: true })), edgeOf(it('a', 'chute', { owned: true })), edgeOf(it('a', 'chute'))],
  ['equipped', 'owned', 'rarity'])
const waiting = it('x', 'emote', { owned: true })
eq('cards: a swap the grid overtakes is dropped (room again, gone, unowned, or already on)',
  [swapStale('x', [...full, waiting], true), swapStale('x', [...full.slice(1), waiting], true), swapStale('x', full, true),
    swapStale('x', [...full, { ...waiting, owned: false }], true), swapStale('x', [...full, { ...waiting, slot: 3 }], true),
    swapStale(null, [], true)],
  [false, true, true, true, true, false])
eq('cards: ...and so is one left waiting when the season closes the dances (none waiting, nothing to drop)',
  [swapStale('x', [...full, waiting], false), swapStale(null, [...full, waiting], false)], [true, false])
eq('cards: the wheel counts dances with a slot', [onWheel(full), onWheel(S2)], [8, 1])

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

// ── COPY ─────────────────────────────────────────────────────────────────────
const copy = read(join(SRC, 'screens', 'marketv2', 'copy.ts'))
const marker = (s) => {
  const line = copy.split('\n').find((l) => l.includes(s))
  return line !== undefined && line.includes('// WRITTEN (proposal for the owner)')
}
for (const s of ["cancel: 'Cancel'", "buy: 'Buy'", "NEW = 'New'", '`Buy ${name}?`']) {
  check(`WRITTEN marker beside ${s}`, marker(s))
}
eq('the new words', [BTN.cancel, BTN.buy, NEW, confirmTitle('Platinum')], ['Cancel', 'Buy', 'New', 'Buy Platinum?'])
const writtenLines = copy.split('\n').filter((l) => !/^\s*\*/.test(l) && l.includes('// WRITTEN')).length
check('and no other WRITTEN line in the Market\'s copy (4)', writtenLines === 4, String(writtenLines))
const s1 = strip(read(join(SRC, 'screens', 'Market.tsx')))
const s1Words = [TITLE, ...Object.values(TAB_LABEL), BTN.done, BTN.equip, BTN.unequip, BTN.replace, BTN.cancelSwap,
  EQUIPPED, ON_WHEEL, NOT_FOR_SALE]
const missing = s1Words.filter((w) => !s1.includes(w))
check('every SEASON 1 label is Season 1\'s word for word', missing.length === 0, missing.join(', '))
check('the closed line is Season 1\'s', closedLabel('Founders') === 'Founders — closed' && s1.includes('— closed'))

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
}

// ── THE SCREEN ───────────────────────────────────────────────────────────────
{
  const v2 = strip(read(join(SRC, 'screens', 'MarketV2.tsx')))
  const dir = join(SRC, 'screens', 'marketv2')
  const parts = readdirSync(dir).filter((f) => /\.tsx?$/.test(f)).map((f) => [f, strip(read(join(dir, f)))])
  const all = [['MarketV2.tsx', v2], ...parts]

  // BUY: one MARKET_BUY, and it is the confirm's.
  const buys = all.flatMap(([f, t]) => [...t.matchAll(/CB\.MARKET_BUY/g)].map(() => f))
  check('the screen sends MARKET_BUY in one place', buys.length === 1 && buys[0] === 'MarketV2.tsx', buys.join(', '))
  check('...the confirm\'s Buy: `buy` sends it and goes only to BuyConfirm\'s onBuy',
    /const buy = \(it: MarketItem\) => \{\s*play\('ui\.select'\)\s*setConfirmId\(null\)\s*void fetchNui\(CB\.MARKET_BUY, \{ id: it\.id \}\)\s*\}/.test(v2)
    && (v2.match(/\bbuy\b(?!Press)/g) ?? []).length === 2 && v2.includes('onBuy={buy}'))
  const confirm = parts.find(([f]) => f === 'Confirm.tsx')?.[1] ?? ''
  check('...and the confirm\'s Buy button is what calls onBuy',
    /<Button variant="primary" onClick=\{\(\) => \{ if \(item\) onBuy\(item\) \}\}>\{BTN\.buy\}<\/Button>/.test(confirm))
  check('a price press goes through buyPress: the confirm, or the error cue',
    /onPrice: \(it\) => \{\s*if \(buyPress\(it, market\.balance\) === 'refuse'\) \{ play\('ui\.error'\); return \}\s*play\('ui\.select'\)\s*setConfirmId\(it\.id\)/.test(v2))
  const cardSrc = parts.find(([f]) => f === 'Card.tsx')?.[1] ?? ''
  check('a card\'s price is that press, and nothing else on a card can buy',
    /case 'buy':[\s\S]*?press = \(\) => h\.onPrice\(item\)/.test(cardSrc) && !/fetchNui/.test(cardSrc))
  check('the confirm drawn is confirmShown\'s, and a stale one is forgotten',
    v2.includes('const confirming = confirmShown(confirmId, market.items, market.balance)')
    && v2.includes('const confirmGone = confirmId !== null && confirming === null')
    && v2.includes('useEffect(() => { if (confirmGone) setConfirmId(null) }, [confirmGone])')
    && v2.includes('item={confirming}') && !/confirmStale/.test(v2))
  check('a swap is dropped by swapStale\'s rule, the season\'s dances included',
    v2.includes('const stale = swapStale(swapFor, market.items, emotesOn)')
    && v2.includes('useEffect(() => { if (stale) setSwapFor(null) }, [stale])'))

  // NEW: on the items Lua marks, and nowhere else.
  const badges = all.flatMap(([f, t]) => [...t.matchAll(/<Badge\b|\{NEW\}/g)].map(() => f))
  check('New is drawn only on an item Lua marks `isNew`, once, on the card',
    badges.join(',') === 'Card.tsx,Card.tsx'
    && cardSrc.includes('{item.isNew === true && <Badge style={NEW_BADGE}>{NEW}</Badge>}'), badges.join(', '))

  // HOVER AND PRESS (index.css `.btn`, check-ui R3: every lobby button
  // brightens, travels and speaks): `.mk2-act` on every button but a price
  // the balance cannot cover, which stays still and silent (Season 1's
  // `btn--off`).
  check('a card\'s button brightens, travels and speaks -- a price too dear does none of it',
    cardSrc.includes("<span className={quiet ? undefined : 'mk2-act'} style={{ display: 'block' }} onPointerEnter={() => { if (!quiet) play('ui.hover') }}>"))
  check('the confirm\'s Cancel and Buy speak on hover and travel on the press, as Done does',
    /<span className="mk2-act" onPointerEnter=\{\(\) => play\('ui\.hover'\)\}>\s*<Button variant="link" onClick=\{onCancel\}>/.test(confirm)
    && /<span className="mk2-act" onPointerEnter=\{\(\) => play\('ui\.hover'\)\}>\s*<Button variant="primary" onClick=\{\(\) => \{ if \(item\) onBuy\(item\) \}\}>/.test(confirm)
    && confirm.includes("import { play } from '../../audio/cues'"))
  const writes = all.filter(([, t]) => /\bsetMarket\b|\bdispatch\(|useUi\.setState|\.getState\(\)\.set/.test(t)).map(([f]) => f)
  check('nothing on the screen writes the store: every number is the server\'s grid', writes.length === 0, writes.join(', '))

  // ESCAPE.
  check('Escape asks for an open dropdown first, closes the confirm alone, holds for a card -- in the capture phase',
    /e\.key !== 'Escape'\) return\s*const act = escapeAction\(live\.current\.confirming, escapeHeld\(\), popupOpen\(screen\.current\)\)\s*if \(act === 'pass'\) return\s*e\.preventDefault\(\)\s*e\.stopPropagation\(\)\s*if \(act === 'modal'\) \{ play\('ui\.back'\); setConfirmId\(null\); return \}\s*if \(act === 'done'\) \{ play\('ui\.back'\); close\(\) \}/.test(v2)
    && v2.includes("window.addEventListener('keydown', onKey, true)")
    && v2.includes('<div ref={screen} className="interactive fixed inset-0 z-50">')
    && v2.includes('live.current = { confirming: confirming !== null }'))
  check('the confirm renders into the island (getModalRoot)', confirm.includes('getModalRoot={getRoot}'))

  // TABS.
  check('Cloudscape tabs, their look from marketv2/look.ts, one for each kind tabsFor gives',
    v2.includes("import Tabs from '@cloudscape-design/components/tabs'") && v2.includes('style={TABS_STYLE}')
    && v2.includes('const tabs = tabsFor(market.items, emotesOn)') && v2.includes('tabs={tabs.map((k) => ({')
    && v2.includes('activeTabId={tab}') && v2.includes('const tab = shownTab(picked, tabs)'))
  check('a tab change drops a pending swap and speaks', /onChange=\{\(\{ detail \}\) => \{\s*play\('ui\.select'\)\s*setPicked\(detail\.activeTabId as TabKind\)\s*setSwapFor\(null\)/.test(v2))

  // CORNERS: `is-active` exactly where Season 1 has it.
  const actives = all.flatMap(([f, t]) => [...t.matchAll(/is-active/g)].map((m) => `${f}:${t.slice(Math.max(0, m.index - 80), m.index + 20).replace(/\s+/g, ' ')}`))
  check('cut corners twice and no more: the selected tab and the swap\'s Cancel', actives.length === 2, actives.join('\n          '))
  check('...the selected tab: its label plate is `is-active` exactly when it is the tab shown',
    v2.includes("className={`plate font-display uppercase${k === tab ? ' is-active' : ''}`}"))
  check('...the swap\'s Cancel: the lobby\'s plate around the button, only for Cancel',
    /if \(a\.do === 'cancel'\) \{\s*return <span className="plate is-active" style=\{cutWrap\(color\)\}>\{button\}<\/span>/.test(cardSrc))
  check('...and a card is a plate at rest', /className="plate"\n/.test(cardSrc) || cardSrc.includes('className="plate"'))
  check('no plate is given --cut directly', !all.some(([, t]) => /--cut'/.test(t) || /'--cut' as/.test(t)))
  // #411's review: Cloudscape's own 4px radii showed on Done, the confirm and
  // its buttons. Everything else square means everything in the island,
  // the confirm included (it renders into the island, getModalRoot).
  check('...and everything else square: the island is `.mk2`, whose every corner market.css squares',
    v2.includes('className="mk2 br-cs flex min-h-0 flex-1 flex-col overflow-hidden pointer-events-auto"')
    && /<div ref=\{setModalRoot\} className="pointer-events-auto" \/>\s*<\/div>\s*<\/div>\s*<BuyConfirm/.test(v2))

  // THE WALKTHROUGH'S ANCHOR.
  check('Done keeps the walkthrough\'s anchor, stepped out of the zoom, and closes the Market',
    /<span data-tut="market-done" style=\{\{ display: 'inline-block', zoom: 1 \/ z \}\}>\s*<span className="mk2-act" style=\{\{ display: 'inline-block', zoom: z \}\} onPointerEnter=\{\(\) => play\('ui\.hover'\)\}>\s*<Button variant="primary" onClick=\{\(\) => \{ play\('ui\.back'\); close\(\) \}\}>/.test(v2)
    && v2.includes('const close = () => { void fetchNui(CB.MARKET_FOCUS, { open: false }) }'))

  // THE LOBBY CHARACTER STAYS IN VIEW.
  check('no full-screen fill: the screen itself draws nothing, the scrim fades to nothing, the panel stops at 64vw',
    !/className="interactive fixed inset-0 z-50"[^>]*style=/.test(v2)
    && v2.includes("'rgba(6,8,14,0.88) 64%, rgba(6,8,14,0) 100%)'") && v2.includes('max-w-[64vw]')
    && v2.includes('className="absolute inset-y-0 left-0 w-[62%] pointer-events-none"'))

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
}

console.log(`\ntest-marketv2: ${ran - failed}/${ran} passed`)
if (failed > 0) process.exit(1)
