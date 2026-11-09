/**
 * ONE PLACEMENT FOR BOTH HUDS (#431).
 *
 * This lived in hud/Hud.tsx. UI v2's HUD (#436) is to draw the same strip
 * against the same radar, and a second copy of this hook would be a second
 * effect whose keys could drift from PLACEMENT_INPUTS -- the regression
 * check-ui R21 exists to catch, and could not see in a file it does not read.
 * So it is one module that each HUD calls: R21 reads it here, requires Hud.tsx
 * to call it, and fails any other file in src that defines a
 * useVitalsPlacement, names fitsBelow or nextFit (under any alias), repeats
 * the comparison or the rounding, or writes --vitals-lift. The code moved
 * verbatim: the same effects, the same keys and the same kernel calls
 * (hud/vitalsPlacement.ts).
 */

import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { fitsBelow, roundStrip, nextFit, vitalsLift } from './vitalsPlacement'

/**
 * Below the radar, or above it -- decided from the safe zone the game actually
 * reports, re-decided whenever it moves.
 *
 * ═══ THE RULE ═══
 *
 *   "if the safezone size doesn't allow our health/shield bars to be displayed
 *    below the minimap (because they'd get cut off) then we should display them
 *    on top of the minimap instead and bump the chat up"   -- owner, 2026-08-23
 *
 * ═══ WHY IT CANNOT BE ANSWERED FROM THE ASPECT RATIO ═══
 *
 * The radar is anchored to the safe zone's BOTTOM-left corner, so the strip's
 * usual place -- --vitals-drop below the radar's lower edge -- is not inside
 * the safe zone at all. It is in the margin underneath it. That margin is
 * whatever the player's safe-zone slider left there, and at the top of the
 * slider's range there is none: the bars run off the bottom of the screen.
 *
 * That happens on a 16:9 monitor. It is not an ultrawide symptom and a test
 * that keyed on the aspect ratio would miss it entirely -- which is the whole
 * reason #231 says this must be MEASURED.
 *
 * ═══ WHAT IS MEASURED, AND WHY IT IS MEASURED THIS WAY ═══
 *
 * Two zero-width hidden probes, sized in the same CSS variables the layout is
 * written in, and read back in pixels:
 *
 *   space  height: var(--map-bottom)   the margin below the radar
 *   drop   height: var(--vitals-drop)  how much of it the strip needs
 *
 * Reading a probe rather than doing the arithmetic in TypeScript is what keeps
 * this honest. Nothing here knows that --vitals-drop is 0.85rem, that a rem is
 * 1.481vh, that the root font size is clamped at both ends, or that the
 * interface-size slider multiplies it -- change any of those, in any unit, and
 * the measurement follows. A hardcoded rem would be a second copy of a number
 * that is already declared once, and it would be the copy that is wrong.
 *
 * ═══ RE-DECIDED, NOT DECIDED ONCE -- AND KEYED, NOT EVERY-RENDER (#319) ═══
 *
 * The read is re-run whenever, and only whenever, one of the three things the
 * measurement actually depends on can have changed: the safe-zone/minimap
 * metric (mapBottom, which is what writes --map-bottom), the interface-size
 * slider (uiScale, which is what writes --ui-scale and so scales rem), and the
 * viewport height (a resize, via viewportTick). Those are the complete set --
 * see vitalsPlacement.ts, PLACEMENT_INPUTS -- because the space probe is sized
 * --map-bottom and the drop probe and the strip are both rem multiples, and
 * nothing else feeds any of them.
 *
 * It USED to carry no dependency array and run after every render of the HUD.
 * That was correct but wasteful: the HUD re-renders several times a second
 * while anyone is shooting or speaking, and each of those renders spent three
 * getBoundingClientRect reads to reach an answer that had not moved since the
 * last safe-zone or resolution change. Keying the effect on its real inputs
 * keeps the SAME answer at every instant -- each input still lands in the same
 * commit as the CSS variable it drives, so a player dragging the safe-zone or
 * interface-size slider mid-match still watches the strip change places on that
 * frame -- while dropping the reads that only ever confirmed nothing changed.
 *
 * DELIBERATELY NOT A ResizeObserver, which is the obvious tool. Its callbacks
 * ride the rendering lifecycle, so they arrive only while frames are being
 * produced -- and in the headless browser this was verified in, which composites
 * nothing, it did not fire once: not for the probes, and not for a plain visible
 * div whose height was being changed underneath it. That is a property of that
 * browser rather than of CEF, and it is exactly the point: a measurement that
 * cannot be exercised where the work is done is a measurement nobody can check.
 * The render path can be, and nextFit is guarded, so a re-read that finds
 * nothing new costs one comparison and no render.
 *
 * The window listener (viewportTick) is what re-measures on a resolution
 * change, in game as in the harness. mapBottom is a percentage of the screen
 * (safeB, br_core/client/screen.lua), so a new resolution at the same safe
 * zone republishes the same number and the keyed effect does not run for it,
 * though the pixels have moved: --map-bottom is written in vh and rem is
 * clamped, so a strip that fit under the radar at 1080p can be cut off at
 * 720p. check-ui R21 requires the listener.
 *
 * The strip's own height is measured too, and only for the chat column: it is
 * published as --vitals-lift so chat can move up by exactly the space the strip
 * took, which is the "bump the chat up" half of the rule.
 */
export function useVitalsPlacement(mapBottom: number | undefined, uiScale: number) {
  const stripRef = useRef<HTMLDivElement>(null)
  const spaceRef = useRef<HTMLDivElement>(null)
  const dropRef = useRef<HTMLDivElement>(null)
  // `below` starts true, which is where the strip has always been: until the
  // probes have been read once, nothing moves.
  const [fit, setFit] = useState({ below: true, strip: 0 })
  // Bumped by a viewport change, purely to force the measurement below to run
  // again when the window resizes: a new resolution republishes the same
  // mapBottom, so none of the other keys moves.
  const [viewportTick, setViewportTick] = useState(0)

  // KEYED ON ITS REAL INPUTS, NOT ON EVERY RENDER (#319). The three reads are a
  // pure function of mapBottom (--map-bottom), uiScale (rem) and the viewport
  // height (viewportTick) -- see vitalsPlacement.ts -- so the measurement runs
  // in exactly the commits where one of those changed and is skipped in the
  // combat/voice renders that never move it. Each input lands in the same
  // commit as the CSS variable it drives, so the answer is same-frame identical
  // to the every-render version. nextFit is still the loop guard: an unchanged
  // answer returns the same state object and no render follows.
  //
  // R21 INVALIDATION SET -- keep in sync with vitalsPlacement.ts PLACEMENT_INPUTS
  // and check-ui rule R21.
  useLayoutEffect(() => {
    const strip = stripRef.current
    const space = spaceRef.current
    const drop = dropRef.current
    if (!strip || !space || !drop) return

    const spacePx = space.getBoundingClientRect().height
    const dropPx = drop.getBoundingClientRect().height
    // The strip's own height, rounded to swallow sub-pixel flicker (roundStrip)
    // so the state-write guard below cannot be defeated into a render loop.
    const stripPx = roundStrip(strip.getBoundingClientRect().height)
    const below = fitsBelow(spacePx, dropPx)
    setFit((p) => nextFit(p, below, stripPx))
  }, [mapBottom, uiScale, viewportTick])

  useEffect(() => {
    const bump = () => setViewportTick((n) => n + 1)
    window.addEventListener('resize', bump)
    return () => window.removeEventListener('resize', bump)
  }, [])

  // Published for the chat column, which has no other way to know.
  useLayoutEffect(() => {
    document.documentElement.style.setProperty('--vitals-lift', vitalsLift(fit))
  }, [fit.below, fit.strip])

  return { fit, stripRef, spaceRef, dropRef }
}
