#!/usr/bin/env node
/**
 * THE TERMINAL APP'S PURE PARTS, ROUND 2 (#396, owner 2026-10-05).
 *
 * model.ts and bridge.ts decide what the app says and shows from what the
 * server sends, with no React and no DOM: the speaker that reads a line's
 * `_solo` sibling outside a squad match, the functions and categories a
 * player is shown, a Volts figure as every other display writes it, the
 * status words, and the shape checks on the state, the catalog and a run's
 * answer (the balance, the run that is loading, the cost and the new
 * balance). Each is asserted here against the real modules. And round 3
 * (owner, 2026-10-06): the browser's page loads -- a fresh pick in the
 * config's 1-3 s for every navigation, the page on screen kept while it
 * loads, a newer navigation replacing it, back and forward at once and
 * dropping it, and what the window's tab is told at each step. And the
 * polish (owner, 2026-10-06): the cards page is Home -- its address, its link
 * and the head of its trail and every function's -- and the Privacy page has
 * its link after How to, its address, its crumb, and loads like any page.
 *
 * WHY node RUNS A .ts FILE DIRECTLY. model.ts has only type imports and
 * bridge.ts none, so node's type stripping (on by default since 22.18) loads
 * them as-is -- the shape of scripts/test-envelope.mjs. What a browser has to
 * show (the bar filling, the colors, the chrome in both modes) was checked in
 * a browser for #396's round-2 report, not here.
 *
 * Run: npm run build:terminal (and so npm run build), or node scripts/test-terminal-model.mjs
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import {
  HOME, NO_FILTERS, addressOf, arrive, bountyOf, canBack, canForward, cardsFor, costOf, current, filtersOf, hrefOf,
  indicatorOf, loadMs, matches, narrowed, navigate, openingEnds, openingStarts, pageLinks, passes, placeText,
  progressAfter, rewrite, routeOfHref, runChoices, sameRoute, showsSquads, shownCategories, shownFunctions,
  shownOptions, speaker, startBrowsing, startOpening, statusOf, step, trailOf, voltsParts, voltsText, withFilters,
} from '../terminal/src/model.ts'
import { parseCatalog, parsePicked, parseResult, parseState, tellTab } from '../terminal/src/bridge.ts'

let failed = 0
let ran = 0
const ok = (cond, name, detail) => {
  ran++
  if (!cond) {
    failed++
    console.error(`FAIL ${name}${detail !== undefined ? `\n     ${JSON.stringify(detail)}` : ''}`)
  }
}
const eq = (got, want, name) => ok(got === want, name, { got, want })

// ── the speaker ──────────────────────────────────────────────────────────────
{
  const copy = { a: 'Your squad', a_solo: 'You', b: 'Plain', e: 'Squads', e_solo: '' }
  const squad = speaker(copy, true)
  const solo = speaker(copy, false)
  eq(squad('a'), 'Your squad', 'in a squad match: the line')
  eq(solo('a'), 'You', 'outside one: its _solo sibling')
  eq(solo('b'), 'Plain', 'a line with no sibling is itself either way')
  eq(solo('e'), '', 'an empty sibling is nothing: the row it labels goes')
  eq(squad('zz'), '', 'a key with no line is nothing, never the key')
  eq(solo(null), '', 'no key is nothing')
}

// ── the registry's own copy: no word "squad" reaches a solo player ──────────
{
  // The fixture is the real copy block, as Lua writes it (tools/test_terminal.lua
  // holds the same rule on the Lua side); here only the shape of the rule.
  const here = dirname(fileURLToPath(import.meta.url))
  const lua = readFileSync(join(here, '..', '..', 'resources', '[fivem-royale]', 'br_lib', 'config', 'terminals.lua'), 'utf8')
  const keys = new Map()
  for (const m of lua.matchAll(/^\s+([a-z_]+) = (['"])(.*)\2,$/gm)) keys.set(m[1], m[3])
  ok(keys.size > 300, 'the copy block was read', keys.size)
  const squadOnly = new Set(['reboot', 'comms_blackout'])
  const solo = speaker(Object.fromEntries(keys), false)
  for (const [k, v] of keys) {
    if (k.endsWith('_solo') || !/squad/i.test(v)) continue
    const id = [...squadOnly].find((s) => k.startsWith(`${s}_`))
    if (id || k === 'category_squad') continue
    ok(!/squad/i.test(solo(k)), `the speaker's line for ${k} outside a squad match has no "squad"`, solo(k))
  }
}

// ── the functions and categories a player is shown ──────────────────────────
{
  const catalog = parseCatalog({
    functions: [
      { id: 'scan', category: 'intel', risk: 'high', implemented: true, cost: 200 },
      { id: 'reboot', category: 'squad', risk: 'medium', implemented: false, cost: 150, squadOnly: true },
      { id: 'ghost', category: 'squad', risk: 'low', implemented: false, soloCategory: 'disruption',
        options: [{ id: 'duration', choices: ['120', '240'], default: '120' }] },
      { id: 'emp', category: 'disruption', risk: 'medium', implemented: false },
    ],
    categories: ['intel', 'storm', 'disruption', 'supply', 'squad'],
    currency: 'Volts',
  })
  eq(catalog.currency, 'Volts', 'the catalog carries the currency word')
  eq(catalog.functions[0].cost, 200, 'a row\'s cost')
  eq(catalog.functions[3].cost, 0, 'no cost is free')
  ok(catalog.functions[1].squadOnly === true && catalog.functions[2].soloCategory === 'disruption', 'squadOnly and soloCategory')
  const inSquad = shownFunctions(catalog, true)
  eq(inSquad.map((f) => f.id).join(','), 'scan,reboot,ghost,emp', 'in a squad match: every function')
  eq(inSquad.find((f) => f.id === 'ghost').category, 'squad', 'Ghost under Squad')
  eq(shownCategories(catalog, inSquad).join(','), 'intel,disruption,squad', 'only categories with something in them')
  const alone = shownFunctions(catalog, false)
  eq(alone.map((f) => f.id).join(','), 'scan,ghost,emp', 'outside one: no squad-only function')
  eq(alone.find((f) => f.id === 'ghost').category, 'disruption', 'Ghost under its solo category')
  eq(shownCategories(catalog, alone).join(','), 'intel,disruption', 'and no Squad category')
  const say = speaker({ ghost_name: 'Ghost', category_disruption: 'Disruption' }, false)
  ok(matches(alone[1], say, 'disruption'), 'the search finds Ghost by its solo category')
}

// ── round 4: an option offered only under another's choice (owner, 2026-10-06:
//    Time & weather's "either time or weather to be set. Not both") ─────────
{
  const catalog = parseCatalog({
    functions: [
      { id: 'time_weather', category: 'disruption', risk: 'low', implemented: true,
        options: [
          { id: 'change', choices: ['time', 'weather'], default: 'time' },
          { id: 'time', when: { change: 'time' }, choices: ['day', 'night'], default: 'night' },
          { id: 'weather', when: { change: 'weather' }, choices: ['fog', 'snow'], default: 'fog' },
          { id: 'bad', when: { 'Not An Id': 'x' }, choices: ['a', 'b'], default: 'a' },
        ] },
    ],
    categories: ['disruption'],
    currency: 'Volts',
  })
  const def = catalog.functions[0]
  ok(def.options[1].when && def.options[1].when.change === 'time', 'a `when` crosses the bridge')
  eq(def.options[0].when, null, 'an option without one has none')
  eq(def.options[3].when, null, 'a `when` that is not one is none: the option is offered always')
  const ids = (list) => list.map((o) => o.id).join(',')
  eq(ids(shownOptions(def, {})), 'change,time,bad', 'nothing touched: the default change, and its own option')
  eq(ids(shownOptions(def, { change: 'weather' })), 'change,weather,bad', 'the weather chosen: the weather offered, never the time')
  eq(ids(shownOptions(def, { change: 'time', weather: 'snow' })), 'change,time,bad',
    'a weather picked earlier is not offered once the time is chosen again')
  const sent = runChoices(def, { change: 'weather', time: 'day', weather: 'snow' })
  ok(sent.change === 'weather' && sent.weather === 'snow' && !('time' in sent),
    'a run carries the weather and nothing for the time, whatever was picked before', sent)
  const defaults = runChoices(def, {})
  ok(defaults.change === 'time' && defaults.time === 'night' && !('weather' in defaults),
    'untouched, a run carries the defaults of what is offered', defaults)
}

// ── round 4: the map pick's answer, and a row run at a spot (owner, 2026-10-06) ─
{
  const cat = parseCatalog({
    functions: [
      { id: 'storm_control', category: 'storm', risk: 'medium', implemented: true, cost: 150, spot: true },
      { id: 'scan', category: 'intel', risk: 'high', implemented: true, spot: 'yes' },
    ],
    categories: ['storm', 'intel'],
  })
  ok(cat.functions[0].spot === true && cat.functions[1].spot === false, 'a row is run at a spot only when it says so, true')
  const good = parsePicked({ functionId: 'storm_control', at: { x: 120.5, y: -900 }, place: 'Elgin Ave, Downtown' })
  ok(good && good.at.x === 120.5 && good.at.y === -900 && good.place === 'Elgin Ave, Downtown', 'a pick with a spot and its place', good)
  const none = parsePicked({ functionId: 'storm_control', at: null, place: 'ignored' })
  ok(none && none.at === null && none.place === '', 'a pick with no spot: none, and no place', none)
  for (const at of [{ x: 'a', y: 1 }, { x: 1 }, { x: Infinity, y: 0 }, { x: 0, y: -1e9 }, 'here', [1, 2]]) {
    const p = parsePicked({ functionId: 'storm_control', at, place: 'x' })
    ok(p && p.at === null, 'a spot that is not one is none', at)
  }
  eq(parsePicked({ functionId: 'Not An Id', at: { x: 1, y: 1 } }), null, 'a pick for no well-formed function is nothing')
  eq(parsePicked({ functionId: 'storm_control', at: { x: 1, y: 1 }, place: 'P'.repeat(300) }).place.length, 120,
    'a place name is cut to 120')
  eq(placeText({ x: 1, y: 2 }, 'Elgin Ave, Downtown'), 'Elgin Ave, Downtown', 'the place, by the game\'s name')
  eq(placeText({ x: 120.5, y: -900.4 }, '  '), '121, -900', 'and with no name, its coordinates in digits')
}

// ── Volts ───────────────────────────────────────────────────────────────────
eq(voltsText(1250, 'Volts'), '1,250 Volts', 'grouped, then the currency word')
eq(voltsText(200, 'Volts'), '200 Volts', 'a cost')
eq(voltsText(12500.9, 'Volts'), '12,500 Volts', 'a whole number')
eq(voltsText(50, ''), '50', 'no word: the figure alone')

// ── the status words ────────────────────────────────────────────────────────
{
  const def = { id: 'x', category: 'intel', risk: 'low', implemented: true, options: [], cost: 0, squadOnly: false, soloCategory: null }
  eq(statusOf({ id: 'x', available: true, reason: null }, def), 'available', 'available')
  eq(statusOf({ id: 'x', available: false, reason: 'squad_used' }, def), 'used', 'used')
  eq(statusOf({ id: 'x', available: false, reason: 'offline' }, def), 'offline', 'a terminal outside the storm: Not available')
  eq(statusOf({ id: 'x', available: false, reason: 'fn_offline' }, def), 'offline', 'not built: Not available')
  eq(statusOf({ id: 'x', available: false, reason: 'no_key' }, def), 'not_here', 'anything else: Not available at this terminal')
  ok(['available', 'used', 'not_here', 'offline'].every((s) => indicatorOf(s) !== 'loading'), 'no status spins (#385)')
}

// ── the state and a run's answer ────────────────────────────────────────────
{
  const st = parseState({ terminalId: 't', functions: [], keyHeld: true, squadUsed: false, squadMatch: true,
    volts: 1250, running: { functionId: 'scan', runMs: 4000, leftMs: 2500 }, player: 'p', match: null })
  ok(st && st.squadMatch === true && st.volts === 1250, 'squadMatch and the balance')
  ok(st.running && st.running.functionId === 'scan' && st.running.runMs === 4000 && st.running.leftMs === 2500, 'the run that is loading')
  const bare = parseState({ terminalId: 't', functions: [] })
  ok(bare.squadMatch === false && bare.volts === null && bare.running === null, 'a state that does not say: not a squad match, no balance, nothing loading')
  const clamp = parseState({ terminalId: 't', functions: [], running: { functionId: 'scan', runMs: 4000, leftMs: 9000 } })
  eq(clamp.running.leftMs, 4000, 'time left never exceeds the run')
  eq(parseState({ terminalId: 't', functions: [], running: { functionId: 'Bad id', runMs: 4000, leftMs: 1 } }).running, null, 'a malformed run is dropped')
  const running = parseResult({ functionId: 'scan', ok: true, code: 'running', runMs: 4200 })
  ok(running.code === 'running' && running.runMs === 4200, 'running carries runMs')
  const short = parseResult({ functionId: 'scan', ok: false, code: 'no_volts', cost: 200, balance: 150 })
  ok(short.cost === 200 && short.balance === 150, 'no_volts carries the cost and the balance')
  const done = parseResult({ functionId: 'scan', ok: true, code: 'done', balance: 1050 })
  ok(done.balance === 1050 && done.cost === null && done.runMs === null, 'a paid done carries the new balance')
  eq(parseResult({ functionId: 'scan', ok: true, code: 'done', balance: 'x' }).balance, null, 'a balance that is not a number is dropped')
}

// ── the bar follows the server (review of round 2) ──────────────────────────
{
  const run = { functionId: 'scan', runMs: 4000, leftMs: 1000 }
  const drawn = progressAfter(null, run, 10000)
  ok(drawn && drawn.functionId === 'scan' && drawn.runMs === 4000 && drawn.startedAt === 7000,
    'an app opened again while it loads draws the bar where the server clock puts it', drawn)
  const bar = { functionId: 'scan', runMs: 4000, startedAt: 9000 }
  eq(progressAfter(bar, run, 10000), bar, 'a bar already drawn is kept as it is')
  eq(progressAfter(bar, null, 10000), null,
    'the server says nothing is loading: no bar, and Run is not left disabled (the answer went to a toast)')
  eq(progressAfter(null, null, 10000), null, 'nothing loading, nothing drawn')
}

// ── the browser's page loads (owner, 2026-10-06) ────────────────────────────
{
  // THE RANGE IS THE CONFIG'S, handed over in the catalog: "random between 1
  // and 3 seconds".
  const here = dirname(fileURLToPath(import.meta.url))
  const lua = readFileSync(join(here, '..', '..', 'resources', '[fivem-royale]', 'br_lib', 'config', 'terminals.lua'), 'utf8')
  const lo = Number(/^\s+pageMinMs = (\d+),$/m.exec(lua)?.[1])
  const hi = Number(/^\s+pageMaxMs = (\d+),$/m.exec(lua)?.[1])
  eq(lo, 1000, 'pageMinMs is 1 s')
  eq(hi, 3000, 'pageMaxMs is 3 s')
  const client = readFileSync(join(here, '..', '..', 'resources', '[fivem-royale]', 'br_core', 'client', 'terminal.lua'), 'utf8')
  ok(client.includes('pageLoad = { minMs = C.pageMinMs, maxMs = C.pageMaxMs }'),
    'br_core\'s client hands the range to the app in the catalog')

  const cat = parseCatalog({ functions: [], categories: [], currency: 'Volts', pageLoad: { minMs: lo, maxMs: hi } })
  ok(cat.pageLoad && cat.pageLoad.minMs === 1000 && cat.pageLoad.maxMs === 3000, 'the catalog carries the range')
  eq(parseCatalog({ functions: [], categories: [] }).pageLoad, null, 'a catalog without one: none')
  for (const bad of [{ minMs: 3000, maxMs: 1000 }, { minMs: -1, maxMs: 10 }, { minMs: 0, maxMs: 60000 }, { minMs: 'x', maxMs: 1 }, 7]) {
    eq(parseCatalog({ functions: [], categories: [], pageLoad: bad }).pageLoad, null, `a range that is not one is dropped: ${JSON.stringify(bad)}`)
  }

  // UNIFORM IN THE RANGE, a fresh pick each time.
  const range = cat.pageLoad
  eq(loadMs(range, () => 0), 1000, 'the bottom of the range')
  eq(loadMs(range, () => 0.999999), 3000, 'the top of the range')
  eq(loadMs(range, () => 0.5), 2000, 'and the middle in between')
  eq(loadMs(range, () => 7), 3000, 'a pick never leaves the range')
  eq(loadMs(null, () => 0.5), 0, 'no range: no wait')
  const picks = new Set()
  let inRange = true
  for (let i = 0; i < 400; i++) {
    const ms = loadMs(range, Math.random)
    picks.add(ms)
    if (ms < 1000 || ms > 3000) inRange = false
  }
  ok(inRange, 'four hundred real picks all between 1 and 3 seconds')
  ok(picks.size > 200, 'and a fresh length nearly every time', picks.size)

  // A NAVIGATION LOADS: the page on screen stays, the tab loads.
  const FN = { page: 'function', id: 'scan' }
  const HOWTO = { page: 'howto' }
  let b = startBrowsing(HOME)
  let r = navigate(b, { kind: 'page', route: FN }, 2400)
  b = r.browsing
  ok(b.load && b.load.ms === 2400 && b.load.target.route === FN, 'a navigation starts a load of the picked length')
  ok(r.tab && r.tab.on === true && r.tab.ms === 2400, 'and the tab is told it is loading, for that long')
  eq(current(b.history), HOME, 'the page on screen stays while it loads')
  const say = speaker({ address_host: 'https://controltower.blitz', path_home: 'home', path_functions: 'functions', path_howto: 'how-to' }, true)
  eq(addressOf(current(b.history), say), 'https://controltower.blitz/home',
    'and so does its address: the bar changes when the page shows')
  r = arrive(b, b.load.seq)
  b = r.browsing
  eq(current(b.history), FN, 'when it ends, the page shows')
  ok(r.shown && r.tab && r.tab.on === false, 'and the tab is itself again')
  eq(b.load, null, 'nothing loads')
  eq(b.history.stack.length, 2, 'one new entry in the history')

  // A NEW NAVIGATION REPLACES THE LOAD UNDER WAY.
  r = navigate(b, { kind: 'page', route: HOWTO }, 1200)
  const first = r.browsing.load.seq
  r = navigate(r.browsing, { kind: 'page', route: HOME }, 2900)
  b = r.browsing
  ok(b.load.seq !== first && b.load.target.route === HOME && b.load.ms === 2900,
    'a second navigation replaces the first, with its own fresh length')
  ok(r.tab && r.tab.on === true && r.tab.ms === 2900, 'and the tab is told the new length')
  r = arrive(b, first)
  ok(!r.shown && r.tab === null && r.browsing === b, 'the replaced load\'s end shows nothing and tells the tab nothing')
  eq(current(b.history), FN, 'the page on screen is still the one before both')
  r = arrive(b, b.load.seq)
  b = r.browsing
  eq(current(b.history), HOME, 'the newer load\'s page shows')
  eq(b.history.stack.map((x) => x.page).join(','), 'functions,function,functions', 'the replaced page never entered the history')

  // BACK AND FORWARD: AT ONCE.
  r = step(b, 'back')
  eq(current(r.browsing.history), FN, 'back: the page before, at once')
  eq(r.tab, null, 'with no load to stop, the tab is told nothing')
  b = r.browsing
  r = step(b, 'forward')
  eq(current(r.browsing.history), HOME, 'forward: at once')
  b = r.browsing

  // BACK OR FORWARD DURING A LOAD DROPS IT.
  r = navigate(b, { kind: 'page', route: HOWTO }, 2000)
  b = r.browsing
  const dropped = b.load.seq
  r = step(b, 'back')
  eq(current(r.browsing.history), FN, 'back during a load goes back at once')
  eq(r.browsing.load, null, 'and the load is dropped')
  ok(r.tab && r.tab.on === false, 'and the tab stops loading')
  b = r.browsing
  r = arrive(b, dropped)
  ok(!r.shown && r.tab === null, 'the dropped load\'s timer, if it fired, shows nothing')
  eq(current(b.history), FN, 'and the page stays where back put it')
  r = navigate(b, { kind: 'page', route: HOWTO }, 2000)
  r = step(r.browsing, 'forward')
  ok(r.browsing.load === null && r.tab && r.tab.on === false, 'forward during a load drops it too')

  // RELOAD IS A LOAD OF THE SAME PAGE.
  b = startBrowsing(HOME)
  r = navigate(b, { kind: 'reload' }, 1500)
  ok(r.browsing.load && r.tab && r.tab.on === true, 'reload loads')
  r = arrive(r.browsing, r.browsing.load.seq)
  ok(r.shown && r.reload === true && current(r.browsing.history) === HOME && r.browsing.history.stack.length === 1,
    'and ends on the same page, asked for again, with no new history entry')

  // NOT NAVIGATIONS.
  b = startBrowsing(HOME)
  r = navigate(b, { kind: 'page', route: { page: 'functions', category: null, query: '' } }, 2000)
  ok(r.browsing === b && r.tab === null, 'a link to the page already on screen loads nothing')
  const typed = rewrite(b, { page: 'functions', category: null, query: 'scan' })
  ok(typed.load === null && typed.history.stack.length === 1 && current(typed.history).query === 'scan',
    'typing in the cards\' filter rewrites the page in place: no load, no entry')

  // WHAT THE DESKTOP IS TOLD, on the wire.
  const sent = []
  const saved = globalThis.window
  globalThis.window = { parent: { postMessage: (m) => sent.push(m) } }
  tellTab({ on: true, ms: 2412.6 })
  tellTab({ on: false })
  tellTab(null)
  globalThis.window = saved
  eq(JSON.stringify(sent), JSON.stringify([
    { brTerminal: 1, type: 'loading', on: true, ms: 2413 },
    { brTerminal: 1, type: 'loading', on: false },
  ]), 'the tab is told { loading, on, ms } as a load starts and { loading, off } as it ends; nothing to tell sends nothing')
}

// ── Home and Privacy (owner, 2026-10-06) ─────────────────────────────────────
{
  // The real copy block, as Lua writes it.
  const here = dirname(fileURLToPath(import.meta.url))
  const lua = readFileSync(join(here, '..', '..', 'resources', '[fivem-royale]', 'br_lib', 'config', 'terminals.lua'), 'utf8')
  const copy = {}
  for (const m of lua.matchAll(/^\s+([a-z_]+) = (['"])(.*)\2,$/gm)) copy[m[1]] = m[3].replace(/\\n/g, '\n')
  const say = speaker(copy, true)
  const PRIVACY = { page: 'privacy' }
  const HOWTO = { page: 'howto' }
  const FN = { page: 'function', id: 'storm_reveal' }

  // THE ADDRESSES: "called Home in the URL".
  eq(addressOf(HOME, say), 'https://controltower.blitz/home', 'the cards page is /home')
  eq(addressOf({ page: 'functions', category: 'intel', query: 'scan' }, say),
    'https://controltower.blitz/home?category=intel&q=scan', 'narrowed, it is still /home, with its query')
  eq(addressOf(FN, say), 'https://controltower.blitz/functions/storm-reveal', 'a function\'s page stays under /functions')
  eq(addressOf(HOWTO, say), 'https://controltower.blitz/how-to', 'the how-to is /how-to')
  eq(addressOf(PRIVACY, say), 'https://controltower.blitz/privacy', 'the Privacy page is /privacy')
  eq(routeOfHref(hrefOf(PRIVACY))?.page, 'privacy', 'the Privacy link leads to the Privacy page')
  eq(routeOfHref(hrefOf(HOME))?.page, 'functions', 'and the Home link to the cards')

  // THE SIDE NAVIGATION: Home, How to, then Privacy.
  const links = pageLinks(say)
  eq(links.map((l) => l.text).join(' | '), 'Home | How to | Privacy', 'the side navigation says Home, How to, Privacy')
  eq(links.map((l) => routeOfHref(l.href)?.page).join(','), 'functions,howto,privacy', 'and each goes to its page')
  ok(!links.some((l) => l.text === 'Functions'), 'no link calls the cards page Functions')

  // THE TRAILS: Home first, for the cards and every function.
  const catOf = (id) => (id === 'storm_reveal' ? 'storm' : undefined)
  const trail = (r) => trailOf(r, say, catOf).map((c) => c.text).join(' > ')
  eq(trail(HOME), 'Home', 'Home\'s trail is Home')
  eq(trail({ page: 'functions', category: 'storm', query: '' }), `Home > ${copy.category_storm}`, 'a category under Home')
  eq(trail(FN), `Home > ${copy.category_storm} > ${copy.storm_reveal_name}`, 'a function\'s trail starts at Home')
  eq(trailOf(FN, say, catOf)[0].href, hrefOf(HOME), 'and its Home crumb leads home')
  eq(trailOf({ page: 'function', id: 'not_shown' }, say, catOf).length, 2,
    'a function this player is not shown has no category crumb')
  eq(trail(HOWTO), 'How to', 'the how-to\'s trail')
  eq(trail(PRIVACY), 'Privacy', 'the Privacy page\'s trail is "Privacy"')
  eq(trailOf(PRIVACY, say, catOf)[0].href, hrefOf(PRIVACY), 'and the crumb is the page itself')
  eq(trailOf({ page: 'login' }, say, catOf).length, 0, 'the login screen has none')
  eq(copy.functions_heading, 'Functions', 'the cards\' heading still says Functions')

  // THE PAGE IS THE OWNER'S WORDS: a title and two paragraphs, no squad.
  eq(say('privacy_title'), 'Privacy Policy', 'the title')
  const paras = say('privacy_body').split('\n')
  eq(paras.length, 2, 'two paragraphs')
  ok(paras[0].startsWith('Control Tower is proudly sponsored by Lifeinvader,') && paras[0].endsWith('a USB stick we found on the ground.'),
    'the first is his', paras[0].slice(0, 60))
  ok(paras[1].startsWith('We take your privacy extremely seriously,') && paras[1].endsWith('you are legally entitled to nothing.'),
    'the second is his', paras[1].slice(0, 60))
  ok(!/squad/i.test(say('privacy_body')) && speaker(copy, false)('privacy_body') === say('privacy_body'),
    'it says no squad, so a solo player reads the same words')

  // PRIVACY LOADS LIKE ANY PAGE; BACK AND FORWARD ARE INSTANT.
  let b = startBrowsing(HOME)
  let r = navigate(b, { kind: 'page', route: PRIVACY }, 1700)
  b = r.browsing
  ok(b.load && b.load.ms === 1700 && r.tab && r.tab.on === true && r.tab.ms === 1700,
    'the Privacy link starts a load, and the tab shows it')
  eq(current(b.history), HOME, 'Home stays on screen while it loads')
  r = arrive(b, b.load.seq)
  b = r.browsing
  eq(current(b.history).page, 'privacy', 'then the Privacy page shows')
  eq(addressOf(current(b.history), say), 'https://controltower.blitz/privacy', 'at /privacy')
  ok(r.tab && r.tab.on === false, 'and the tab stops loading')
  r = step(b, 'back')
  eq(current(r.browsing.history), HOME, 'back: Home, at once')
  ok(r.browsing.load === null && r.tab === null, 'with no load and nothing for the tab')
  b = r.browsing
  ok(canForward(b.history), 'forward is open')
  r = step(b, 'forward')
  eq(current(r.browsing.history).page, 'privacy', 'forward: Privacy again, at once')
  b = r.browsing
  r = navigate(b, { kind: 'page', route: HOME }, 2600)
  ok(r.browsing.load && r.tab && r.tab.on === true && r.tab.ms === 2600, 'the Home link from Privacy loads')
  r = arrive(r.browsing, r.browsing.load.seq)
  eq(addressOf(current(r.browsing.history), say), 'https://controltower.blitz/home', 'and arrives at /home')
  ok(canBack(r.browsing.history), 'with Privacy behind it')
  r = navigate(r.browsing, { kind: 'page', route: HOME }, 2000)
  ok(r.tab === null, 'the Home link on Home loads nothing')

  // EVERY KEY THE APP NAMES IS A LINE IN THE COPY BLOCK: a key the app reads
  // that the block lacks is a blank on screen (Home's and Privacy's new ones
  // included).
  const src = join(here, '..', 'terminal', 'src')
  const missing = []
  const files = ['App.tsx', 'FunctionCards.tsx', 'FunctionPage.tsx', 'HowTo.tsx', 'Login.tsx', 'MatchPanel.tsx', 'Privacy.tsx',
    'Squads.tsx', 'Volts.tsx', 'model.ts']
  let named = 0
  for (const f of files) {
    const text = readFileSync(join(src, f), 'utf8')
    for (const m of text.matchAll(/\bsay\('([a-z_]+)'\)/g)) {
      named++
      if (!(m[1] in copy)) missing.push(`${f}: ${m[1]}`)
    }
  }
  ok(named > 60, 'the app\'s keys were read', named)
  eq(missing.join(', '), '', 'every say(\'key\') in the app is in br_lib/config/terminals.lua')
}

// ── the first page loads, as a white page (owner, 2026-10-06, round 4) ───────
{
  // "The initial page load should also take time, and be shown as a white
  // page during that time while the tab shows the loading icon."
  const range = { minMs: 1000, maxMs: 3000 }
  const o = startOpening()
  eq(o && o.phase, 'waiting', 'a fresh app starts on its white page, waiting for the catalog')
  let r = openingStarts(o, range, () => 0.5)
  ok(r.opening && r.opening.phase === 'loading' && r.opening.ms === 2000,
    'the catalog comes: a pick in its range, still white', r.opening)
  ok(r.tab && r.tab.on === true && r.tab.ms === 2000, 'and the tab is told a load of that length is under way')
  ok(openingStarts(o, range, () => 0).opening.ms === 1000 && openingStarts(o, range, () => 1).opening.ms === 3000,
    'the pick spans the range, 1 to 3 s')
  const again = openingStarts(r.opening, range, () => 0.9)
  ok(again.opening === r.opening && again.tab === null, 'a later catalog (an update, a reload) starts nothing new')
  r = openingEnds(r.opening)
  ok(r.opening === null && r.tab && r.tab.on === false, 'the load ends: the first page shows, the tab is itself')
  const after = openingStarts(null, range, () => 0.5)
  ok(after.opening === null && after.tab === null, 'once shown, no catalog brings the white page back')
  ok(openingEnds(null).tab === null && openingEnds(startOpening()).tab === null,
    'nothing ends that was not loading')
  const none = openingStarts(startOpening(), null, () => 0.5)
  ok(none.opening.ms === 0 && none.tab.ms === 0, 'a catalog with no range: no wait')
}

// ── round 4: the cards, the filters, Volts and Squads! (owner, 2026-10-06) ────
{
  // The real copy block and registry, as Lua writes them.
  const here = dirname(fileURLToPath(import.meta.url))
  const lua = readFileSync(join(here, '..', '..', 'resources', '[fivem-royale]', 'br_lib', 'config', 'terminals.lua'), 'utf8')
  const copy = {}
  for (const m of lua.matchAll(/^\s+([a-z_]+) = (['"])(.*)\2,$/gm)) copy[m[1]] = m[3].replace(/\\n/g, '\n')
  const squad = speaker(copy, true)
  const solo = speaker(copy, false)

  // THE REGISTRY'S NEW FIELDS, as the app reads them.
  const catalog = parseCatalog({
    functions: [
      { id: 'scan', category: 'intel', risk: 'high', implemented: true, cost: 200, bounty: 'runner', squadWide: true },
      { id: 'storm_reveal', category: 'intel', risk: 'low', implemented: true, squadWide: true },
      { id: 'storm_control', category: 'storm', risk: 'medium', implemented: true, cost: 150 },
      { id: 'disarm', category: 'disruption', risk: 'high', implemented: true, cost: 200 },
      { id: 'contract', category: 'disruption', risk: 'medium', implemented: true, bounty: 'target' },
      { id: 'max_ammo', category: 'supply', risk: 'low', implemented: true, squadWide: true },
      { id: 'emp', category: 'disruption', risk: 'medium', implemented: false, bounty: 'everyone', squadWide: 'yes' },
    ],
    categories: ['intel', 'storm', 'disruption', 'supply', 'squad'],
    currency: 'Volts',
  })
  const fn = Object.fromEntries(catalog.functions.map((f) => [f.id, f]))
  ok(fn.scan.bounty === 'runner' && fn.contract.bounty === 'target' && fn.storm_reveal.bounty === null,
    'bounty: runner, target, or none')
  ok(fn.emp.bounty === null && fn.emp.squadWide === false, 'a bounty or squadWide that is not one is dropped')
  ok(fn.scan.squadWide && fn.storm_reveal.squadWide && fn.max_ammo.squadWide && !fn.disarm.squadWide, 'squadWide')

  // "The cards should show cost in volts and bounty".
  eq(costOf(fn.scan), 'paid', 'Scan costs Volts')
  eq(costOf(fn.storm_reveal), 'free', 'Storm reveal is free')
  eq(squad(`bounty_${bountyOf(fn.scan)}`), 'You get one', 'Scan\'s card: you get the bounty')
  eq(squad(`bounty_${bountyOf(fn.contract)}`), 'Another player gets one', 'Contract\'s card: another player does')
  eq(squad(`bounty_${bountyOf(fn.storm_reveal)}`), 'None', 'every other card: none')
  eq(squad('cost_free'), 'Free', 'a free card says Free')
  ok(squad('card_cost') === 'Cost' && squad('card_bounty') === 'Bounty', 'the sections\' names, in the preferences too')

  // "Any mention of volts must use our proper font for that and the gold color".
  const parts = (text, amounts) => voltsParts(text, 'Volts', amounts).map((p) => (p.volts ? `[${p.text}]` : p.text)).join('')
  eq(parts(squad('no_volts'), { cost: 200, balance: 150 }),
    'You don\'t have enough [Volts]. This costs [200 Volts], and your balance is [150 Volts].',
    'no_volts: the word, the cost and the balance, each in the Volts style')
  eq(parts(squad('balance_new'), { volts: 1050 }), 'Your new balance is: [1,050 Volts].', 'the new balance')
  eq(parts(squad('cost_line_volts'), { volts: 150 }), '[150 Volts], your Yubikey and your squad\'s one terminal use this match',
    'a page\'s cost')
  eq(parts(squad('confirm_body_volts'), { volts: 200 }),
    'This uses [200 Volts], your Yubikey and your squad\'s terminal use for this match. It can\'t be undone.', 'the box')
  ok(parts(squad('privacy_body')).includes('your [Volts] balance'), 'the privacy policy\'s "your Volts balance", the word alone')
  eq(parts('Run {name}? {volts}', { volts: 5 }), 'Run {name}? [5 Volts]', 'any other token is left as written')
  eq(parts('No Voltsy words.'), 'No Voltsy words.', 'only the whole word')
  ok(voltsParts('5 Volts', '').every((p) => !p.volts), 'no currency word: nothing to style by word')
  eq(voltsParts(squad('cost_line'), 'Volts').filter((p) => p.volts).length, 0, 'a line without Volts has no Volts pieces')

  // SQUADS!: on a squadWide row, in a squad match -- and nowhere else.
  ok(showsSquads(fn.scan, true), 'Scan, in a squad match: Squads!')
  ok(!showsSquads(fn.scan, false), 'Scan, outside one: none')
  ok(!showsSquads(fn.disarm, true), 'Disarm, not squad-wide: none, even in a squad match')
  eq(squad('squads_link'), 'Squads!', 'its words, verbatim')
  eq(squad('squads_popover'), 'This function will apply to your entire squad.', 'and its box\'s, verbatim')
  ok(solo('squads_link') === '' && solo('squads_popover') === '', 'outside a squad match the speaker says neither')

  // THE FILTERS, each alone, then together with the text search.
  const states = new Map([
    ['scan', { id: 'scan', available: true, reason: null }],
    ['storm_reveal', { id: 'storm_reveal', available: false, reason: 'squad_used' }],
    ['storm_control', { id: 'storm_control', available: false, reason: 'no_key' }],
    ['disarm', { id: 'disarm', available: true, reason: null }],
    ['contract', { id: 'contract', available: true, reason: null }],
    ['max_ammo', { id: 'max_ammo', available: true, reason: null }],
  ])
  const funcs = catalog.functions
  const home = HOME
  const ids = (route) => cardsFor(route, funcs, states, squad).items.map((f) => f.id).join(',')
  const f = (over) => withFilters(home, { ...NO_FILTERS, ...over })
  eq(ids(home), 'scan,storm_reveal,storm_control,disarm,contract,max_ammo,emp', 'no filter: every card')
  eq(ids({ ...home, category: 'disruption' }), 'disarm,contract,emp', 'category')
  eq(ids(f({ risk: 'high' })), 'scan,disarm', 'risk')
  eq(ids(f({ cost: 'free' })), 'storm_reveal,contract,max_ammo,emp', 'cost: free')
  eq(ids(f({ cost: 'paid' })), 'scan,storm_control,disarm', 'cost: paid')
  eq(ids(f({ bounty: 'runner' })), 'scan', 'bounty: the runner gets one')
  eq(ids(f({ bounty: 'target' })), 'contract', 'bounty: another player does')
  eq(ids(f({ bounty: 'none' })), 'storm_reveal,storm_control,disarm,max_ammo,emp', 'bounty: none')
  eq(ids(f({ status: 'available' })), 'scan,disarm,contract,max_ammo', 'status: available')
  eq(ids(f({ status: 'used' })), 'storm_reveal', 'status: used')
  eq(ids(f({ status: 'not_here' })), 'storm_control', 'status: not available at this terminal')
  eq(ids(f({ status: 'offline' })), 'emp', 'status: not available')
  eq(ids({ ...f({ cost: 'paid', status: 'available' }), category: 'disruption' }), 'disarm', 'several together')
  eq(ids({ ...f({ cost: 'paid' }), query: 'storm' }), 'storm_control',
    'a filter with the text search: both narrow (paid, and "storm" in its name, summary or category)')
  eq(ids({ ...f({ risk: 'low' }), query: 'zzz' }), '', 'nothing left is nothing')
  const counted = cardsFor({ ...f({ cost: 'paid' }), category: 'disruption' }, funcs, states, squad)
  ok(counted.items.length === 1 && counted.all === 3, 'the heading counts what is left of the category\'s', counted.all)

  // In the route: no load, no new entry, the address says them, and an empty
  // set is no set at all.
  eq(filtersOf(home), NO_FILTERS, 'Home filters nothing')
  ok(sameRoute(withFilters(home, NO_FILTERS), home), 'every filter back to Any is Home again')
  ok(!narrowed(home) && narrowed(f({ risk: 'low' })) && narrowed({ ...home, query: 'x' }) && narrowed({ ...home, category: 'intel' }),
    'narrowed: by a filter, the search or a category')
  eq(addressOf({ ...f({ risk: 'high', cost: 'paid', bounty: 'runner', status: 'available' }), category: 'intel', query: 'scan' }, squad),
    'https://controltower.blitz/home?category=intel&risk=high&cost=paid&bounty=runner&status=available&q=scan',
    'the address carries every filter')
  let b = startBrowsing(home)
  b = rewrite(b, f({ status: 'available' }))
  ok(b.load === null && b.history.stack.length === 1 && filtersOf(current(b.history)).status === 'available',
    'a filter rewrites the page\'s own entry: no load, no new entry')
  const r = navigate(b, { kind: 'page', route: { page: 'function', id: 'scan' } }, 1000)
  const there = arrive(r.browsing, r.browsing.load.seq).browsing
  const back = step(there, 'back').browsing
  eq(filtersOf(current(back.history)).status, 'available', 'back from a function: the filters are as they were')
  ok(passes(fn.scan, states.get('scan'), NO_FILTERS), 'Any passes everything')
}

if (failed > 0) {
  console.error(`\ntest-terminal-model: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-terminal-model: ok, ${ran} assertions`)
