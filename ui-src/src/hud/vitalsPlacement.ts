/**
 * THE VITALS-PLACEMENT KERNEL (#319).
 *
 * The decision that puts the health/shield strip below the radar or above it,
 * and the loop guards around it, pulled out of hud/Hud.tsx so there is ONE
 * definition of each -- imported by the effect that measures, and exercised
 * directly by scripts/test-vitals-placement.mjs. The pair is the same shape as
 * bridge/envelope.ts + scripts/test-envelope.mjs: no runtime imports here, so
 * node's type stripping loads this file as-is and the suite needs no DOM runner
 * and no new dependency.
 *
 * NOTHING HERE READS THE DOM. The measurement -- three getBoundingClientRect
 * heights -- stays in Hud.tsx, because it must run against a real layout. What
 * lives here is only what can be decided from those three numbers, which is
 * exactly what a plain script can check.
 */

/** Where the strip sits, and how tall it measured. `below` is the radar rule;
 *  `strip` is the strip's own height, published to the chat column. */
export type VitalsFit = { below: boolean; strip: number }

/**
 * FITS BELOW ⟺ THE STRIP'S LOWER EDGE IS STILL ON THE SCREEN.
 *
 * The strip is bottom-anchored, so its lower edge is --map-bottom minus
 * --vitals-drop, measured up from the bottom of the viewport. It fits when the
 * margin under the radar (spacePx, sized --map-bottom) is at least what the
 * strip needs to drop (dropPx, sized --vitals-drop). `>=`, so a margin that is
 * exactly the drop still counts as fitting -- unchanged from the inline form
 * this replaced.
 */
export function fitsBelow(spacePx: number, dropPx: number): boolean {
  return spacePx >= dropPx
}

/**
 * ROUNDED TO 1/100 px, AND THAT IS THE LOOP GUARD. The measuring effect writes
 * state, so a raw sub-pixel height flickering in its last decimal place would
 * defeat the equality check below and spin the render loop silently. Two
 * decimals is enough to keep a real one-pixel change while swallowing the
 * flicker.
 */
export function roundStrip(rawPx: number): number {
  return Math.round(rawPx * 100) / 100
}

/**
 * THE STATE-WRITE GUARD. An unchanged answer returns the SAME object, so
 * setState bails and no render follows -- which is what makes it safe to run
 * the measurement without spinning. Identical semantics to the inline updater
 * it replaced: compare both fields, keep the previous object when neither moved.
 */
export function nextFit(prev: VitalsFit, below: boolean, strip: number): VitalsFit {
  return prev.below === below && prev.strip === strip ? prev : { below, strip }
}

/**
 * WHAT THE CHAT COLUMN READS. When the strip is below the radar it lifts chat
 * by nothing; when it has moved above, chat rises by exactly the strip's height
 * plus the shared gap. `calc` with the gap left symbolic (var(--vitals-gap)) so
 * the two surfaces cannot drift apart.
 */
export function vitalsLift(fit: VitalsFit): string {
  return fit.below ? '0px' : `calc(${fit.strip}px + var(--vitals-gap))`
}

/**
 * ═══ THE COMPLETE INVALIDATION SET (#319) ═══
 *
 * The three measured lengths are a pure function of these inputs and NOTHING
 * else, so the measurement must re-run when one of them changes and need not
 * run otherwise:
 *
 *   space probe = --map-bottom   = f(mapBottom-vh, viewport height)
 *   drop  probe = --vitals-drop  = 0.85rem = f(rem) = f(viewport height, uiScale)
 *   strip       = 1.05rem row    = f(rem) = f(viewport height, uiScale)
 *
 * where rem = clamp(11px, 1.481vh * uiScale, 28px) (index.css).
 *
 *   mapBottom     the safe-zone / minimap metric -- arrives on a `screen`
 *                 envelope, which is also what writes --map-bottom.
 *   uiScale       the interface-size slider -- multiplies rem, and is what
 *                 writes --ui-scale (settings/apply.ts).
 *   viewportTick  a counter bumped on window resize; stands in for the viewport
 *                 height that both vh-based lengths resolve against.
 *
 * DELIBERATELY NOT IN THE SET, each because it cannot move any of the three:
 *   - textScale: the strip row is a fixed 1.05rem and its numerals and captions
 *     are out of flow, so text size never changes the container's height (see
 *     Vitals.tsx: "11.55px high ... at every text scale"); the probes carry no
 *     text at all.
 *   - visibility (visible / scoped): toggles opacity only. .hud-safe and the
 *     strip stay laid out, so geometry is unchanged.
 *   - hp / armour / stamina / storm / feed / squad / voice / vehicle / ...:
 *     none feed a measured length. These are the renders whose reads #319 drops.
 *
 * check-ui rule R21 asserts Hud.tsx's measurement effect is keyed on exactly
 * these names, and scripts/test-vitals-placement.mjs asserts this list, so the
 * spec has one home.
 */
export const PLACEMENT_INPUTS = ['mapBottom', 'uiScale', 'viewportTick'] as const
