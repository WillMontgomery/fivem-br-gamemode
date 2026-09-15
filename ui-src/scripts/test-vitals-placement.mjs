#!/usr/bin/env node
/**
 * THE VITALS-PLACEMENT TESTS (#319).
 *
 * The dependency-free measurement effect in hud/Hud.tsx moved its decision and
 * loop guards into hud/vitalsPlacement.ts and its trigger from "after every
 * render" to a keyed invalidation set. This suite guards both halves:
 *
 *   - the DECISION and guards are byte-for-byte the behaviour the inline code
 *     had (fitsBelow's `>=`, roundStrip's 1/100 px, nextFit's same-object
 *     bail, vitalsLift's exact string);
 *   - the INVALIDATION SET is complete and minimal -- a model of the effect's
 *     dependency key must change when any of {mapBottom, uiScale, viewportTick}
 *     changes (MISSING INVALIDATION would drop a re-measure) and must NOT change
 *     for an unrelated field like hp (an UNNECESSARY READ would be a regression
 *     back to reading on every combat render).
 *
 * WHY node RUNS A .ts FILE DIRECTLY. hud/vitalsPlacement.ts has no runtime
 * imports, so node's type stripping (on by default since 22.18) loads it as-is.
 * The alternative was a DOM test runner -- jsdom, vitest -- which would have
 * been a new dependency in a repo whose every other suite is a plain script
 * that prints ok or FAIL. This file is the same shape as test-envelope.mjs on
 * purpose.
 *
 * WHAT THIS CANNOT REACH, stated rather than implied: there is no DOM here, so
 * it does not read a real getBoundingClientRect and cannot prove the effect is
 * wired to these inputs. That half is check-ui rule R21, which asserts Hud.tsx
 * keys the measurement effect on exactly PLACEMENT_INPUTS. The two are a pair;
 * do not delete one and keep the other.
 *
 * Run: npm run test:placement   (and as part of npm run build)
 */

import {
  fitsBelow,
  roundStrip,
  nextFit,
  vitalsLift,
  PLACEMENT_INPUTS,
} from '../src/hud/vitalsPlacement.ts'

let failed = 0
let ran = 0

function check(label, got, expected) {
  ran++
  const ok = JSON.stringify(got) === JSON.stringify(expected)
  if (!ok) failed++
  console.log(
    ok
      ? `  ok    ${label}`
      : `  FAIL  ${label}\n          got      ${JSON.stringify(got)}\n          expected ${JSON.stringify(expected)}`,
  )
}

// A truthy/identity assert for the cases JSON round-tripping cannot express
// (same-object reference, a thrown key difference).
function checkTrue(label, got) {
  ran++
  if (got !== true) failed++
  console.log(got === true ? `  ok    ${label}` : `  FAIL  ${label}\n          expected true, got ${JSON.stringify(got)}`)
}

// ─── THE DECISION: fitsBelow ───────────────────────────────────────────────
// `>=`, so a margin exactly equal to the drop still fits -- the boundary the
// inline `spacePx >= dropPx` drew, and the one a `>` would have shifted by a
// pixel at the very moment the strip is deciding whether to jump the radar.
check('exactly enough room fits below', fitsBelow(10, 10), true)
check('a hair more room fits below', fitsBelow(10.5, 10), true)
check('a hair too little goes above', fitsBelow(9.99, 10), false)
check('no room at all goes above', fitsBelow(0, 12), false)

// ─── THE SUB-PIXEL GUARD: roundStrip ───────────────────────────────────────
// Two decimals kept, the rest dropped -- so a height that jitters below 0.01px
// reads as unchanged and cannot spin the render loop, while a real 0.01px move
// still counts.
check('rounds to 1/100 px', roundStrip(11.554999), 11.55)
check('keeps a real hundredth', roundStrip(11.56), 11.56)
checkTrue('sub-pixel flicker collapses to one value',
  roundStrip(11.550001) === roundStrip(11.554999))

// ─── THE STATE-WRITE GUARD: nextFit ────────────────────────────────────────
// The load-bearing property is REFERENCE identity: an unchanged answer returns
// the very same object, which is what makes React's setState bail and stops the
// keyed effect from looping if it ever runs on an unchanged layout.
const base = { below: true, strip: 11.55 }
checkTrue('unchanged answer returns the same object',
  nextFit(base, true, 11.55) === base)
checkTrue('a flipped side is a new object',
  nextFit(base, false, 11.55) !== base)
check('a flipped side carries the new value',
  nextFit(base, false, 11.55), { below: false, strip: 11.55 })
checkTrue('a changed strip height is a new object',
  nextFit(base, true, 12.01) !== base)

// ─── THE PUBLISHED LIFT: vitalsLift ────────────────────────────────────────
// Below the radar chat lifts by nothing; above it, by the strip height plus the
// SYMBOLIC gap, so the two surfaces cannot drift apart.
check('below the radar publishes 0px', vitalsLift({ below: true, strip: 11.55 }), '0px')
check('above the radar publishes the symbolic calc',
  vitalsLift({ below: false, strip: 11.55 }), 'calc(11.55px + var(--vitals-gap))')

// ─── THE INVALIDATION SET: PLACEMENT_INPUTS ────────────────────────────────
// The spec that the measurement re-runs on these and only these. Complete AND
// minimal: any addition here without a matching Hud dependency (or vice versa)
// is caught by check-ui R21; this asserts the list itself has not drifted.
check('the invalidation set is exactly the three geometry inputs',
  [...PLACEMENT_INPUTS], ['mapBottom', 'uiScale', 'viewportTick'])

// A model of the effect's dependency key, built from the same spec, to make the
// behavioural property concrete: changing each named input MUST change the key
// (or a re-measure is missed), and changing anything else must NOT (or we are
// back to reading on every render).
function depKey(state) {
  return PLACEMENT_INPUTS.map((k) => state[k]).join('|')
}
const world = { mapBottom: 3.2, uiScale: 1, viewportTick: 0, hp: 100, armour: 50 }
for (const k of PLACEMENT_INPUTS) {
  const moved = { ...world, [k]: world[k] + 1 }
  checkTrue(`changing ${k} re-measures (missing-invalidation guard)`,
    depKey(moved) !== depKey(world))
}
checkTrue('changing hp does NOT re-measure (unnecessary-read guard)',
  depKey({ ...world, hp: 1 }) === depKey(world))
checkTrue('changing armour does NOT re-measure (unnecessary-read guard)',
  depKey({ ...world, armour: 0 }) === depKey(world))

if (failed) {
  console.error(`\nvitals placement: ${failed} of ${ran} case(s) failed`)
  process.exit(1)
}
console.log(`\nvitals placement: ${ran} cases pass`)
