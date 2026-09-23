#!/usr/bin/env node
/**
 * THE TUTORIAL CARD PLACEMENT TESTS (#358).
 *
 * Real players reported tutorial steps drawing off the screen at 4K. The layer
 * held the card's size as pixels -- `CARD_W = 304`, which is 19rem x 16px --
 * while `.tut-card` is 19rem against a root font size that clamps up to 28px,
 * so the card is really 532px wide at 2160p and every edge test was reading a
 * number 228px too small. tutorial/cardPlacement.ts now takes the MEASURED box
 * as an argument and this suite drives it.
 *
 * ═══ EVERY CASE THAT MATTERS RUNS AT A NON-16px ROOT ═══
 *
 * That is the whole point of the file. A suite that only ever asks about a 16px
 * root would pass at 1080p forever, exactly as the shipping code did -- the bug
 * was invisible precisely because the resolution it was authored on is the one
 * resolution where the constant was true. So the fixtures are three roots: the
 * clamp's 11px floor, the 16px that shipped, and the 28px ceiling a 4K screen
 * actually resolves to.
 *
 * WHAT THIS CANNOT REACH, stated rather than implied: there is no DOM here, so
 * it does not read a real offsetWidth and cannot prove the layer is wired to
 * these inputs or that it measures before paint. That half is check-ui rule R22,
 * which asserts TutorialLayer.tsx keys its layout effect on exactly CARD_INPUTS
 * and measures with offset*. The two are a pair; do not delete one and keep the
 * other.
 *
 * WHY node RUNS A .ts FILE DIRECTLY. tutorial/cardPlacement.ts has no runtime
 * imports, so node's type stripping (on by default since 22.18) loads it as-is.
 * The alternative was a DOM test runner -- jsdom, vitest -- which would have
 * been a new dependency in a repo whose every other suite is a plain script that
 * prints ok or FAIL. This file is the same shape as test-vitals-placement.mjs on
 * purpose.
 *
 * Run: npm run test:cardplacement   (and as part of npm run build)
 */

import {
  place,
  centred,
  sameBox,
  BAND,
  GAP_REM,
  MARGIN_REM,
  FLOOR_REM,
  CARD_INPUTS,
} from '../src/tutorial/cardPlacement.ts'

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

/**
 * A placement, rounded to 1/100 px for comparison.
 *
 * `2160 * 0.64` is not 1382.4 in binary and a hundredth of a pixel is not a
 * placement difference, so the fixtures below are written as the numbers a
 * person would work out by hand and compared at that precision.
 */
function r2(at) {
  const p = (n) => Math.round(n * 100) / 100
  return { left: p(at.left), top: p(at.top), fromX: at.fromX, fromY: at.fromY }
}

function checkTrue(label, got) {
  ran++
  if (got !== true) failed++
  console.log(got === true ? `  ok    ${label}` : `  FAIL  ${label}\n          expected true, got ${JSON.stringify(got)}`)
}

/**
 * The card as the browser would measure it, at a given root font size.
 *
 * WIDTH IS `min(19rem, 34vw)` because that is what index.css says -- 19rem with
 * a 34vw cap. It is spelled out here rather than imported because the kernel is
 * not allowed to know it: a helper in the test may model the CSS, since a
 * measurement it gets wrong makes a case unrealistic, while a constant in the
 * kernel makes the product wrong.
 *
 * HEIGHT IS A PARAMETER IN REMS, because a card's height is its own prose. The
 * retired CARD_H = 172 was one step's worth of text at one root size, and the
 * cases below run short cards and long ones at the same root to prove the clamps
 * follow the card rather than a number.
 */
function measured(rem, vw, heightRem) {
  return { w: Math.min(19 * rem, 0.34 * vw), h: heightRem * rem, rem }
}

/**
 * THE RETIRED ARITHMETIC, ENTIRE.
 *
 * `rem: 16` is not an oversight, it is the second half of the bug: the layer
 * passed a 304 x 172 card AND unscaled 18/16/72 gaps at every resolution, so a
 * 4K screen got 1080p's numbers throughout. Handing this box to the kernel
 * reproduces the shipped placement exactly, which is what the witnesses below
 * compare the real card against.
 */
const SHIPPED = { w: 304, h: 172, rem: 16 }

// ─── THE SCALED LENGTHS: parity at the root size this was authored on ──────
// GAP, MARGIN and FLOOR were unscaled pixels for the same reason the card size
// was: they are rem multiples now, and these three products are what shipped.
// So nothing about a 1080p screen moves, and everything about a 4K one does.
check('1.125rem is the 18px gap at a 16px root', GAP_REM * 16, 18)
check('1rem is the 16px edge margin at a 16px root', MARGIN_REM * 16, 16)
check('4.5rem is the 72px floor at a 16px root', FLOOR_REM * 16, 72)

// ─── 1080p IS UNCHANGED ────────────────────────────────────────────────────
// The numbers on the right are the ones the retired arithmetic produced with
// CARD_W = 304, CARD_H = 172, GAP = 18, MARGIN = 16: left = 100 + 200 + 18,
// top = 400 + 60/2 - 172/2. A fix that moves a card at the resolution the owner
// plays at is a fix that has to be re-reviewed by eye, so it does not.
{
  const card = { w: 304, h: 172, rem: 16 }
  const r = { x: 100, y: 400, w: 200, h: 60 }
  check('1080p, room on the right: byte-for-byte the old placement',
    place(r, card, 1920, 1080), { left: 318, top: 344, fromX: -1, fromY: 0 })
}

// ─── 2160p, A TARGET NEAR THE RIGHT EDGE: THE REPORTED BUG ─────────────────
// At a 28px root the card is 532 wide. The old right-edge test asked whether
// 304 would fit and was told yes, so the card never flipped to the other side
// of its subject and ran off the screen. The flip has to fire on the real width.
{
  const rem = 28
  const card = measured(rem, 3840, 10.5)   // 532 x 294
  const r = { x: 3200, y: 600, w: 200, h: 60 }
  const at = place(r, card, 3840, 2160)
  check('4K right edge: the card flips to the left of its subject',
    r2(at), { left: 2636.5, top: 483, fromX: 1, fromY: 0 })
  checkTrue('4K right edge: the whole card is inside the margin',
    at.left >= MARGIN_REM * rem && at.left + card.w <= 3840 - MARGIN_REM * rem)

  // THE WITNESS. Run the retired arithmetic against the same target and ask where
  // the card it actually draws ends up: 126px past the right edge of the screen,
  // because the flip never fired. That is the shipped bug in one line, and it is
  // what gives the assertions above teeth.
  const stale = place(r, SHIPPED, 3840, 2160)
  checkTrue('the retired arithmetic does not flip, and the real 532px card hangs off screen',
    stale.fromX === -1 && stale.left + card.w > 3840 - MARGIN_REM * rem)
}

// ─── 2160p, A TARGET NEAR THE BOTTOM ───────────────────────────────────────
// The bottom clamp under-measured by the same 120px of card plus 54px of floor.
// Owner, 2026-09-07: "step 12/18 card should never touch the bottom of the
// screen" -- at 4K it went straight through it.
{
  const rem = 28
  const card = measured(rem, 3840, 10.5)   // 532 x 294
  const r = { x: 100, y: 2000, w: 200, h: 60 }
  const at = place(r, card, 3840, 2160)
  check('4K bottom: the card is clamped to the floor, not to a remembered height',
    r2(at), { left: 331.5, top: 1740, fromX: -1, fromY: 0 })
  check('4K bottom: its lower edge sits exactly on the 4.5rem floor',
    at.top + card.h, 2160 - FLOOR_REM * rem)

  const stale = place(r, SHIPPED, 3840, 2160)
  checkTrue('the retired arithmetic leaves the real card off the bottom of the screen',
    stale.top + card.h > 2160)
}

// ─── THE UNANCHORED CARD: CENTRED MEANS CENTRED ────────────────────────────
// This branch always used fractions for its band -- its comment is where the
// knowledge that the card scales already lived -- but it centred a 532px card by
// halving 304, so it was 114px right of centre at 4K.
{
  const rem = 28
  const card = measured(rem, 3840, 10.5)
  const at = centred(card, 3840, 2160, BAND.half)
  check('4K unanchored: centred on the viewport, in the lower band',
    r2(at), { left: 1654, top: 1235.4, fromX: 0, fromY: 0 })
  check('4K unanchored: the card\'s own centre is the screen\'s centre',
    at.left + card.w / 2, 3840 / 2)

  const stale = centred(SHIPPED, 3840, 2160, BAND.half)
  check('the retired arithmetic put the real card 114px right of centre',
    stale.left + card.w / 2 - 3840 / 2, 114)
}

// ─── A CARD'S HEIGHT IS ITS OWN PROSE ──────────────────────────────────────
// Two steps, one root size, different amounts of text. The clamps have to follow
// the card. CARD_H could not express this at any resolution, which is the half
// of the bug that was never about 4K at all.
{
  const rem = 16
  const short = measured(rem, 1920, 10.75)   // 172 tall, the old constant
  const tall = measured(rem, 1920, 25)       // 400 tall, a wordy step
  const shortAt = centred(short, 1920, 1080, BAND.quarter)
  const tallAt = centred(tall, 1920, 1080, BAND.quarter)
  check('a short card sits in its band', r2(shortAt).top, 778)
  check('a tall card is lifted off the floor instead', r2(tallAt).top, 608)
  checkTrue('and both end above the floor',
    shortAt.top + short.h <= 1080 - FLOOR_REM * rem
      && tallAt.top + tall.h <= 1080 - FLOOR_REM * rem)
}

// ─── NEITHER SIDE FITS: UNDERNEATH, POINTING UP ────────────────────────────
// A target 3000px wide leaves no room either side of it at any root size, so the
// card goes below and the arrival vector points up. The horizontal clamp keeps
// it inside the margins on the way.
{
  const rem = 28
  const card = measured(rem, 3840, 10.5)
  const r = { x: 400, y: 200, w: 3000, h: 80 }
  const at = place(r, card, 3840, 2160)
  check('a target too wide for either side puts the card underneath it',
    r2(at), { left: 1634, top: 311.5, fromX: 0, fromY: -1 })
  checkTrue('and it is still inside both margins',
    at.left >= MARGIN_REM * rem && at.left + card.w <= 3840 - MARGIN_REM * rem)
}

// ─── THE SWEEP: NO CARD, ANYWHERE, LEAVES THE VIEWPORT ─────────────────────
// Every root size the clamp can resolve to, every resolution the owner's players
// use, short prose and long, and a target in each corner and edge. The property
// is the one the issue is about and the one no single case can state: the card
// is fully on screen.
//
// COMBINATIONS THAT CANNOT FIT ARE SKIPPED, NOT ASSERTED. A card wider than the
// viewport minus its margins has no placement that satisfies this, and pretending
// otherwise would mean weakening the clamp to make the test pass.
const ROOTS = [11, 16, 28]
const SCREENS = [[1920, 1080], [2560, 1440], [3840, 2160]]
const PROSE = [4, 10.75, 20]

function sweep(boxFor) {
  const bad = []
  for (const rem of ROOTS) {
    const margin = MARGIN_REM * rem
    const floor = FLOOR_REM * rem
    for (const [vw, vh] of SCREENS) {
      for (const heightRem of PROSE) {
        const real = measured(rem, vw, heightRem)
        if (real.w + 2 * margin > vw) continue
        if (real.h + floor + margin > vh) continue
        const box = boxFor(real)
        for (const tx of [0, 0.25, 0.5, 0.75, 1]) {
          for (const ty of [0, 0.25, 0.5, 0.75, 1]) {
            const r = {
              x: Math.round(tx * (vw - 200)),
              y: Math.round(ty * (vh - 60)),
              w: 200,
              h: 60,
            }
            for (const at of [place(r, box, vw, vh), centred(box, vw, vh, BAND.half),
                              centred(box, vw, vh, BAND.quarter)]) {
              const where = `rem ${rem}, ${vw}x${vh}, prose ${heightRem}rem, target ${r.x},${r.y}`
              if (at.left < margin - 0.001) bad.push(`${where}: left ${at.left}`)
              if (at.left + real.w > vw - margin + 0.001) {
                bad.push(`${where}: right ${at.left + real.w} past ${vw - margin}`)
              }
              if (at.top < margin - 0.001) bad.push(`${where}: top ${at.top}`)
              if (at.top + real.h > vh - floor + 0.001) {
                bad.push(`${where}: bottom ${at.top + real.h} past ${vh - floor}`)
              }
            }
          }
        }
      }
    }
  }
  return bad
}

{
  const bad = sweep((real) => real)
  ran++
  if (bad.length === 0) {
    console.log('  ok    measured: every card at every root size stays on screen')
  } else {
    failed++
    console.log(`  FAIL  measured: ${bad.length} card(s) left the viewport`)
    for (const line of bad.slice(0, 6)) console.log(`          ${line}`)
  }

  // THE TEETH. The same sweep, told the card is 304 x 172 when it is not -- the
  // arithmetic the layer shipped. It must fail, and loudly: if this ever comes
  // back green, the assertions above have stopped measuring anything and the
  // suite is decoration.
  const stale = sweep(() => SHIPPED)
  checkTrue(`the retired constants leave the viewport (${stale.length} case(s)), so the sweep has teeth`,
    stale.length > 0)
}

// ─── THE STATE-WRITE GUARD: sameBox ────────────────────────────────────────
// offsetWidth and offsetHeight are integers, so a real one-pixel change must
// count; only the parsed root font size gets a tolerance.
{
  const box = { w: 532, h: 292, rem: 28 }
  checkTrue('an identical box is not written back', sameBox(box, { ...box }))
  checkTrue('a one-pixel wider card is', !sameBox(box, { ...box, w: 533 }))
  checkTrue('a one-pixel taller card is', !sameBox(box, { ...box, h: 293 }))
  checkTrue('a root font size wobbling in its last decimal is not',
    sameBox(box, { ...box, rem: 27.999 }))
  checkTrue('a real scale change is', !sameBox(box, { ...box, rem: 22.4 }))
  checkTrue('nothing measured yet is never the same as a measurement',
    !sameBox(null, box))
}

// ─── THE INVALIDATION SET: CARD_INPUTS ─────────────────────────────────────
// The spec that the measurement re-runs on these and only these. `cardUp` is in
// it because a card becomes visible on a state change of its own, in a commit
// where nothing else moved -- without it the first measurement of a card can be
// skipped, which is the bug back. check-ui R22 holds the layer's dependency
// array to this list; this asserts the list itself has not drifted.
check('the invalidation set is exactly the five inputs the box depends on',
  [...CARD_INPUTS], ['cardUp', 'stepId', 'uiScale', 'textScale', 'viewportTick'])

function depKey(state) {
  return CARD_INPUTS.map((k) => state[k]).join('|')
}
const world = {
  cardUp: true, stepId: 'lobby-ready', uiScale: 1, textScale: 1, viewportTick: 0,
  stuck: false, crates: 0,
}
for (const k of CARD_INPUTS) {
  const moved = { ...world, [k]: typeof world[k] === 'number' ? world[k] + 1 : `${world[k]}!` }
  checkTrue(`changing ${k} re-measures (missing-invalidation guard)`,
    depKey(moved) !== depKey(world))
}
checkTrue('changing `stuck` does NOT re-measure (unnecessary-read guard)',
  depKey({ ...world, stuck: true }) === depKey(world))
checkTrue('opening a crate does NOT re-measure (unnecessary-read guard)',
  depKey({ ...world, crates: 3 }) === depKey(world))

if (failed) {
  console.error(`\ncard placement: ${failed} of ${ran} case(s) failed`)
  process.exit(1)
}
console.log(`\ncard placement: ${ran} cases pass`)
