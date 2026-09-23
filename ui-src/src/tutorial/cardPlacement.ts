/**
 * THE TUTORIAL CARD PLACEMENT KERNEL (#358).
 *
 * The edge-avoidance arithmetic for tutorial/TutorialLayer.tsx -- which side of
 * its subject a card sits on, and the clamps that keep it on the screen --
 * pulled out of the layer so there is ONE definition of each, imported by the
 * effect that measures and exercised directly by scripts/test-card-placement.mjs.
 * The pair is the same shape as hud/vitalsPlacement.ts +
 * scripts/test-vitals-placement.mjs: no runtime imports here, so node's type
 * stripping loads this file as-is and the suite needs no DOM runner and no new
 * dependency.
 *
 * NOTHING HERE READS THE DOM. The measurement -- the card's own box and the
 * root font size -- stays in TutorialLayer.tsx, because it must run against a
 * real layout. What lives here is only what can be decided from those numbers.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * AND NOTHING HERE KNOWS HOW BIG THE CARD IS, WHICH IS THE POINT OF THE FILE
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * The layer used to carry the size as pixels:
 *
 *     const CARD_W = 304   // "kept in step with .tut-card"
 *     const CARD_H = 172
 *
 * `.tut-card` is `width: 19rem` (index.css) and the root font size is
 * `clamp(11px, calc(1.481vh * var(--ui-scale)), 28px)`. 304 is 19 x 16, so the
 * constant was correct at 1080p with the interface slider at 1 and NOWHERE
 * ELSE. At 2160p the root clamps to its 28px ceiling and the real card is
 * 19 x 28 = 532px: a 228px under-measure, with `max-width: 34vw` far too wide
 * to rescue it (1305px at 3840). Every clamp read the stale number, so the
 * right-edge test fired 228px late and the flip to the other side landed short
 * -- real players reported tutorial steps drawing off the screen. It was wrong
 * at 1440p too (405 against 304), just less visibly. The HEIGHT was never right
 * at any resolution: a card's height is its own prose, and 172 was a guess at
 * one step's worth of it.
 *
 * So the size ARRIVES AS AN ARGUMENT -- `CardBox`, measured from the mounted
 * element -- and this file cannot re-derive it. Deliberately NOT
 * `19 * rootFontSize` either: that is the same coupling in a second place, and
 * the next person to edit `19rem` breaks it again identically. The constant does
 * not get to be smarter; it gets to stop existing.
 *
 * ═══ THE KNOWLEDGE WAS ALREADY IN THE FILE AND DID NOT CROSS THE BRANCH ═══
 *
 * BAND below has always said, in as many words, that an unanchored card is
 * placed by FRACTIONS because "the card's own height moves with the player's
 * interface scale" -- while the anchored path a few lines away trusted a
 * constant. One branch knew the card scales and the other did not. That is why
 * this shipped instead of being caught in review: the file read as though
 * somebody had already thought about scaling, and somebody had, once, on the
 * path that happens to be correct.
 */

/** A box in viewport pixels: a target, a clip box, a card. */
export type Rect = { x: number; y: number; w: number; h: number }

/**
 * The card as MEASURED -- its own box, and the root font size it was measured
 * at, read in the same breath so the two cannot describe different layouts.
 *
 * `rem` is here because the gaps below are rem multiples too (see GAP_REM), and
 * a gap resolved against a different root font size than the card it separates
 * would be the same class of mistake in miniature.
 */
export type CardBox = { w: number; h: number; rem: number }

/**
 * Where the card goes, and which way it faces. The vector points FROM the card
 * TOWARD its subject, which is what the arrival animation consumes.
 */
export type Placement = { left: number; top: number; fromX: number; fromY: number }

/**
 * How far the card sits off its subject: 1.125rem.
 *
 * IN REM FOR THE REASON IN THE HEADER. It was 18 unscaled pixels, which is a
 * gap that looks deliberate at 1080p and looks like a touching card at 2160p,
 * where everything either side of it is 1.75x larger. 1.125rem is exactly 18px
 * at a 16px root, so nothing moves at the resolution this was authored on.
 */
export const GAP_REM = 1.125

/**
 * Never closer than this to the viewport edge: 1rem, formerly 16 unscaled px.
 */
export const MARGIN_REM = 1

/**
 * How much room a card always leaves below itself: 4.5rem, formerly 72 px.
 *
 * Owner, 2026-09-07: "step 12/18 card should never touch the bottom of the
 * screen." MARGIN is the general edge gap and is small enough that a card
 * anchored to the inventory bar -- which is ITSELF at the bottom -- was pushed
 * flat against the edge. This is the floor for the vertical clamp only, so the
 * horizontal gap is unchanged.
 *
 * IT SCALES BECAUSE THE BAR DOES. The clearance exists to clear the inventory
 * bar, and that bar is sized in rem like everything else: 72px cleared it at
 * 1080p and cleared half of it at 2160p.
 */
export const FLOOR_REM = 4.5

/**
 * Where the CENTRE of an unanchored card sits, as a fraction of the viewport.
 *
 * See `Step.place`. Fractions rather than pixels because the card's own height
 * moves with the player's interface scale, and a pixel authored here would be
 * right at one setting only.
 */
export const BAND = { half: 0.64, quarter: 0.80 }

/**
 * The card's size and the scaled gaps, from a measurement that may not have
 * happened yet.
 *
 * ═══ AN UNMEASURED CARD IS A POINT, NOT A GUESS ═══
 *
 * `null` is the one commit between the card mounting and the layout effect
 * reading it -- a commit the browser never paints, because the effect runs
 * before paint and the corrected placement lands in the same frame (see
 * TutorialLayer.tsx). The arithmetic still has to produce numbers, and the
 * honest number for a size nobody has measured is zero: the card is treated as
 * a point at its own top-left corner, so it lands against its subject rather
 * than at a plausible-looking distance from it.
 *
 * DELIBERATELY NOT A FALLBACK SIZE. Any default here would be a new CARD_W
 * waiting to be believed -- and it would be believed exactly once, on the frame
 * where somebody removes the measurement.
 */
function metrics(box: CardBox | null) {
  const rem = box === null ? 0 : box.rem
  return {
    w: box === null ? 0 : box.w,
    h: box === null ? 0 : box.h,
    gap: GAP_REM * rem,
    margin: MARGIN_REM * rem,
    floor: FLOOR_REM * rem,
  }
}

/**
 * Where an ANCHORED card goes, and which way it faces.
 *
 * PREFERRED SIDE FIRST, THEN WHATEVER FITS. Right of the subject reads best for
 * the lobby's left-hand column; a target near the right edge flips to the left,
 * and one that fits neither goes below. The returned vector points FROM the
 * card TOWARD the subject, which is what the arrival animation consumes.
 */
export function place(r: Rect, box: CardBox | null, vw: number, vh: number): Placement {
  const { w, h, gap, margin, floor } = metrics(box)
  let left = r.x + r.w + gap
  let fromX = -1
  let fromY = 0

  if (left + w > vw - margin) {
    left = r.x - w - gap
    fromX = 1
  }
  // Neither side fits -- a wide target on a narrow viewport. Go underneath and
  // point up, which is the only remaining direction that cannot cover it.
  if (left < margin) {
    left = Math.min(Math.max(r.x + r.w / 2 - w / 2, margin), vw - w - margin)
    fromX = 0
    fromY = -1
  }

  const wantTop = fromY === -1 ? r.y + r.h + gap : r.y + r.h / 2 - h / 2
  // FLOOR, NOT MARGIN, ON THE BOTTOM. A card anchored to the inventory bar sits
  // against the bottom of the screen otherwise -- the bar is already there --
  // and two consecutive cards on the same anchor landed at visibly different
  // heights because one of them hit the clamp and the other did not.
  const top = Math.min(Math.max(wantTop, margin), Math.max(vh - h - floor, margin))

  return { left, top, fromX, fromY }
}

/**
 * Where an UNANCHORED card goes: in its band, centred, arriving from nowhere in
 * particular.
 *
 * Owner, 2026-09-07: "step 11 and any other step that currently draws in the
 * middle center of the screen should be moved to the lower 1/3 in the middle."
 * Dead centre is where a card about the WORLD does the most damage -- it sits
 * exactly over the four crates it is telling the player to go and look at. Low
 * and centred is where a game puts a subtitle, and it leaves the middle of the
 * screen to the thing being described.
 *
 * CLAMPED, so a tall card on a short viewport cannot be pushed off the bottom --
 * the same floor `place` applies to an anchored one.
 *
 * The arrival vector is zero: a card with no subject has no direction to be
 * thrown from, so it simply scales up in place.
 */
export function centred(box: CardBox | null, vw: number, vh: number, band: number): Placement {
  const { w, h, margin, floor } = metrics(box)
  return {
    left: (vw - w) / 2,
    top: Math.min(vh * band - h / 2, Math.max(vh - h - floor, margin)),
    fromX: 0,
    fromY: 0,
  }
}

/**
 * THE STATE-WRITE GUARD. An unchanged measurement is not written back, so the
 * render it would have cost does not happen.
 *
 * EXACT EQUALITY ON w AND h, because they come from `offsetWidth`/`offsetHeight`
 * and those are integers -- there is no sub-pixel jitter to swallow, and an
 * epsilon would hide a genuine one-pixel change. The tolerance is on `rem`
 * alone, which is parsed from a computed style and can carry a trailing
 * fraction no layout can act on.
 */
export function sameBox(a: CardBox | null, b: CardBox): boolean {
  return a !== null && a.w === b.w && a.h === b.h && Math.abs(a.rem - b.rem) < 0.01
}

/**
 * ═══ THE COMPLETE INVALIDATION SET (#358) ═══
 *
 * The card's box is a pure function of these and nothing else, so the
 * measurement must re-run when one of them changes and need not run otherwise:
 *
 *   card width  = min(19rem, 34vw)           = f(rem, viewport width)
 *   card height = prose at rem, in that width = f(step, rem, viewport width)
 *   where rem   = clamp(11px, 1.481vh * uiScale, 28px)   (index.css)
 *
 *   cardUp        whether the card is mounted at all. It is in the set because
 *                 a card becomes visible on a state change of its own -- the
 *                 target settling, a sub-screen closing -- in a commit where
 *                 none of the others moved. Without it the FIRST measurement of
 *                 a card can be skipped entirely, which is the whole bug back.
 *   stepId        different step, different prose, different height. CARD_H was
 *                 only ever guessing at this one, at every resolution.
 *   uiScale       the interface-size slider -- multiplies rem, and is what
 *                 writes --ui-scale (settings/apply.ts).
 *   textScale     the text-size slider. `.tscale` is on the card itself, so
 *                 anything inside it that inherits a size grows with this. The
 *                 card's own title and body are authored in rem and should not
 *                 move -- but a re-measure that finds nothing costs one
 *                 comparison and no render, and ASSUMING a surface cannot move
 *                 is precisely the mistake this issue is about.
 *   viewportTick  a counter bumped on window resize; stands in for the viewport
 *                 that both the vh-based rem and the 34vw cap resolve against.
 *
 * DELIBERATELY NOT IN THE SET: everything else this layer subscribes to. The
 * demo feed, the staged squad, the waypoint and crate counters, `stuck` -- none
 * of them are inside the card, and the layer re-renders on several of them
 * while a card is up.
 *
 * NOT A ResizeObserver, for the reason Hud.tsx gives at length: its callbacks
 * ride the rendering lifecycle, and in the headless browser this project's
 * measurements are verified in it does not fire at all. A measurement that
 * cannot be exercised where the work is done is a measurement nobody can check.
 *
 * check-ui rule R22 asserts TutorialLayer.tsx's measurement effect is keyed on
 * exactly these names, and scripts/test-card-placement.mjs asserts this list, so
 * the spec has one home.
 */
export const CARD_INPUTS = ['cardUp', 'stepId', 'uiScale', 'textScale', 'viewportTick'] as const
