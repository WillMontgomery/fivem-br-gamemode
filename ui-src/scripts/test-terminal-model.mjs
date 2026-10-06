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
 * dropping it, and what the window's tab is told at each step.
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
  HOME, addressOf, arrive, current, indicatorOf, loadMs, matches, navigate, progressAfter, rewrite,
  shownCategories, shownFunctions, speaker, startBrowsing, statusOf, step, voltsText,
} from '../terminal/src/model.ts'
import { parseCatalog, parseResult, parseState, tellTab } from '../terminal/src/bridge.ts'

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
  const say = speaker({ address_host: 'https://controltower.blitz', path_functions: 'functions', path_howto: 'how-to' }, true)
  eq(addressOf(current(b.history), say), 'https://controltower.blitz/functions',
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

if (failed > 0) {
  console.error(`\ntest-terminal-model: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-terminal-model: ok, ${ran} assertions`)
