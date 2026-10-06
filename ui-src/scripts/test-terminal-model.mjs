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
 * balance). Each is asserted here against the real modules.
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
  indicatorOf, matches, shownCategories, shownFunctions, speaker, statusOf, voltsText,
} from '../terminal/src/model.ts'
import { parseCatalog, parseResult, parseState } from '../terminal/src/bridge.ts'

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

if (failed > 0) {
  console.error(`\ntest-terminal-model: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-terminal-model: ok, ${ran} assertions`)
