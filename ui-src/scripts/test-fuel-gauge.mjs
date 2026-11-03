#!/usr/bin/env node
/**
 * A JERRY CAN NEVER LOOKS EMPTY WHILE IT HOLDS ANYTHING (#217).
 *
 * hud/gaugeShare.ts decides how much of the gauge on a can's plate is lit, and
 * hud/FuelGauge.tsx draws exactly that. This holds both halves:
 *
 *   - THE RULE: the fill itself, but at least SLIVER (8% of the gauge) for any
 *     fill above 0, and 0 only for 0. The server sends a can that still holds
 *     anything as at least a thousandth (server/inventory.lua's canFill), and a
 *     thousandth drawn as it is was a twentieth of a pixel: an empty-looking can
 *     that still took the one place a player may carry one (#217's second
 *     review).
 *   - THE WIRING: FuelGauge's height comes from gaugeShare(slot.fill) and from
 *     nothing else, so the rule above is the one the plates draw.
 *
 * WHY node RUNS A .ts FILE DIRECTLY: test-vitals-placement.mjs says it -- no
 * runtime imports there, so node's type stripping loads it as-is, and no DOM
 * runner is needed. What this cannot reach is a real layout: the gauge's
 * pixels are the playtest's.
 *
 * Run: npm run test:fuelgauge   (and as part of npm run build)
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { gaugeShare, SLIVER } from '../src/hud/gaugeShare.ts'

const here = dirname(fileURLToPath(import.meta.url))

let failed = 0
let ran = 0

function check(label, got, expected) {
  ran++
  const ok = Object.is(got, expected)
  if (!ok) failed++
  console.log(
    ok
      ? `  ok    ${label}`
      : `  FAIL  ${label}\n          got      ${JSON.stringify(got)}\n          expected ${JSON.stringify(expected)}`,
  )
}

// ─── THE RULE ────────────────────────────────────────────────────────────────
check('the sliver is 8% of the gauge', SLIVER, 0.08)
check('a full can is a full gauge', gaugeShare(1), 1)
check('half a can is half the gauge', gaugeShare(0.5), 0.5)
check('the sliver itself draws as it is', gaugeShare(0.08), 0.08)
check('just above the sliver draws as it is', gaugeShare(0.081), 0.081)
check('a thousandth -- the least the wire sends for a can with any left -- draws the sliver',
  gaugeShare(0.001), SLIVER)
check('so does a hundredth', gaugeShare(0.01), SLIVER)
check('and anything above 0, however small', gaugeShare(Number.MIN_VALUE), SLIVER)
check('0 draws nothing', gaugeShare(0), 0)
check('nor does a negative', gaugeShare(-0.2), 0)
check('nor a value that is not a number', gaugeShare(Number.NaN), 0)
check('nor infinity', gaugeShare(Number.POSITIVE_INFINITY), 0)
check('nor no value at all', gaugeShare(undefined), 0)
check('nor null', gaugeShare(null), 0)
check('past a whole can is a full gauge', gaugeShare(1.5), 1)

// MONOTONE: more in the can never draws less of the gauge.
let last = -1
let monotone = true
for (let i = 0; i <= 1000; i++) {
  const share = gaugeShare(i / 1000)
  if (share < last) monotone = false
  last = share
}
check('more in the can never draws less of the gauge, 0 to 1 by thousandths', monotone, true)

// ─── THE WIRING ──────────────────────────────────────────────────────────────
const src = readFileSync(join(here, '..', 'src', 'hud', 'FuelGauge.tsx'), 'utf8')
const code = src.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
check('FuelGauge imports the rule', /import \{ gaugeShare \} from '\.\/gaugeShare'/.test(code), true)
check('and its height is gaugeShare(slot.fill), to a tenth of a percent',
  /height: `\$\{Math\.round\(gaugeShare\(slot\.fill\) \* 1000\) \/ 10\}%`/.test(code), true)
check('and nothing else in it reads slot.fill but its own null test',
  (code.match(/slot\.fill/g) || []).length, 2)

if (failed) {
  console.error(`\nfuel gauge: ${failed} of ${ran} case(s) failed`)
  process.exit(1)
}
console.log(`\nfuel gauge: ${ran} cases pass`)
