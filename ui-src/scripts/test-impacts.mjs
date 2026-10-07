#!/usr/bin/env node
/**
 * THE PERSISTENT NOTICES' ROWS (#396, round 4, owner 2026-10-06: "a persistent
 * notification with a timer explaining what the impact is and when it will be
 * over").
 *
 * src/hud/impactRows.ts shape-checks the `impacts` envelope br_core sends; its
 * clock is countdown.ts's formatClock, whose schedule and wording
 * test-countdown.mjs holds. This proves the parse: a list or nothing, every row
 * a line of text with a finite end or its tail, the caps, and the React keys.
 * And, by text, that the HUD draws them with the shared once-a-second clock and
 * never a frame loop, and that the stack and the store are wired to them.
 *
 * WHY node RUNS A .ts FILE DIRECTLY: impactRows.ts has no imports (the shape of
 * test-countdown.mjs and test-envelope.mjs).
 *
 * Run: npm run test:impacts   (and as part of npm run build)
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { IMPACTS_MAX, IMPACT_TEXT_MAX, impactKeys, parseImpacts } from '../src/hud/impactRows.ts'

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

// ── the list ────────────────────────────────────────────────────────────────
eq(parseImpacts(undefined).length, 0, 'no payload: no rows')
eq(parseImpacts(null).length, 0, 'null: no rows')
eq(parseImpacts({}).length, 0, 'no list: no rows')
eq(parseImpacts({ list: {} }).length, 0, "Lua's empty table as an object: no rows")
eq(parseImpacts({ list: 'x' }).length, 0, 'a list that is not one: no rows')
eq(parseImpacts('impacts').length, 0, 'a payload that is not an object: no rows')

// ── a row ───────────────────────────────────────────────────────────────────
{
  const rows = parseImpacts({ list: [
    { key: 'impact_emp', text: 'EMP: any vehicle you drive stalls.', endsAt: 123456.7 },
    { key: 'impact_storm', text: 'Storm control: the storm will end where another player chose.', tail: 'Until the match ends' },
  ] })
  eq(rows.length, 2, 'two rows')
  ok(rows[0].key === 'impact_emp' && rows[0].endsAt === 123456 && rows[0].tail === undefined,
    'a timed row: its end, floored, and no tail', rows[0])
  ok(rows[1].endsAt === undefined && rows[1].tail === 'Until the match ends',
    'a row for the rest of the match: its tail, and no end', rows[1])
}
{
  const rows = parseImpacts({ list: [
    { key: 'a', text: '', endsAt: 1 },
    { key: 'b', text: '   ', endsAt: 1 },
    { key: 'c', endsAt: 1 },
    { key: 'd', text: 7, endsAt: 1 },
    null,
    'row',
    { key: 'e', text: 'Kept.', endsAt: Infinity, tail: 'Tail.' },
    { key: 'f', text: 'Kept too.', endsAt: 'soon' },
    { text: 'No key.', endsAt: 5 },
  ] })
  eq(rows.length, 3, 'a row with no text, blank text, or that is not a row, is dropped')
  ok(rows[0].endsAt === undefined && rows[0].tail === 'Tail.', 'an end that is not finite: the tail instead', rows[0])
  ok(rows[1].endsAt === undefined && rows[1].tail === undefined, 'neither: drawn with nothing on its right', rows[1])
  eq(rows[2].key, '', 'a row with no key keeps an empty one')
}
{
  const long = 'x'.repeat(IMPACT_TEXT_MAX + 50)
  const rows = parseImpacts({ list: Array.from({ length: IMPACTS_MAX + 5 }, (_, i) => ({ key: `k${i}`, text: long, endsAt: i })) })
  eq(rows.length, IMPACTS_MAX, `at most ${IMPACTS_MAX} rows`)
  eq(rows[0].text.length, IMPACT_TEXT_MAX, `a line cut to ${IMPACT_TEXT_MAX}`)
}

// ── the React keys ──────────────────────────────────────────────────────────
{
  const keys = impactKeys([{ key: 'a', text: 'x' }, { key: 'b', text: 'y' }, { key: 'a', text: 'z' }])
  eq(keys.join(' '), 'i:a i:b i:a:1', 'one key per row, unique even if the server sent one twice')
}

// ── the wiring, by text ─────────────────────────────────────────────────────
{
  const here = dirname(fileURLToPath(import.meta.url))
  const read = (p) => readFileSync(join(here, '..', p), 'utf8')
  const strip = (s) => s.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
  const rows = strip(read('src/hud/Impacts.tsx'))
  ok(rows.includes('useCountdownText(') && rows.includes('formatClock'),
    'each row counts down with the shared once-a-second clock, as a clock')
  ok(!/requestAnimationFrame|setInterval/.test(rows), 'and nothing per frame: no frame loop, no interval')
  ok(rows.includes('clockOffset'), 'against the server clock (the clock offset every countdown uses)')
  const notices = strip(read('src/hud/Notices.tsx'))
  ok(notices.includes('selImpacts') && notices.includes('<ImpactRows'),
    'the notice stack draws them, below the passing notices')
  const app = strip(read('src/App.tsx'))
  ok(/useNuiEvent\('impacts'/.test(app) && app.includes('parseImpacts'), 'the envelope is parsed into the store')
  ok(app.includes('clearImpacts'), 'and a match leaving play clears them on the page too')
}

if (failed) {
  console.error(`\ntest-impacts: ${failed} failure(s) of ${ran} checks`)
  process.exit(1)
}
console.log(`test-impacts: ok, ${ran} checks`)
