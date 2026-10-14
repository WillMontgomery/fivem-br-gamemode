/**
 * CLOUDSCAPE MEASURES A ZOOMED BOX THE WAY CEF 103 DOES, ON EVERY ENGINE (#413).
 *
 * Locker v2 draws its Cloudscape island under `zoom` (LockerV2.tsx, so
 * Cloudscape's 14 px text is one rem). Chromium before 128 -- FiveM's CEF 103 --
 * returned getBoundingClientRect inside a zoomed element in that element's own
 * zoomed px: the box divided by its zoom. 128 standardized zoom and returns
 * what is drawn, in screen px. Cloudscape measures with one and writes the
 * result as CSS px inside the same zoom, so on CEF 144 every size it computes
 * is applied twice: measured at 2560x1440 (zoom 1.52), the Save menu was given
 * 238 px and drew 363, and its 1225 px height cap drew about 1866 -- past the
 * panel's clipped edge, with the last rows of a long list out of reach.
 *
 * So no Cloudscape module calls getBoundingClientRect. scripts/zoom-rect.mjs
 * rewrites every `.getBoundingClientRect()` in @cloudscape-design/* to
 * `.__brZoomRect()` at build time (vite.config.ts, br_ui only -- the terminal
 * app has no zoom), and the method below gives back what CEF 103 would:
 *
 *   - `currentCSSZoom` exists only where zoom is standardized (128+). Absent --
 *     CEF 103 -- it is the native call, byte for byte.
 *   - Present, the native box is divided by the element's effective zoom,
 *     which is exactly what the old engine did. Outside any zoom that is 1, so
 *     the box is the native one.
 *
 * Measured in Chromium 152 at 2560x1440 (zoom 1.52), the dev harness: a tattoo
 * picker drew 497 px wide under a 326 px trigger and ran 135 px past the
 * panel's clip without this; with it, 326 px and inside the clip. The Save
 * menu fits its rows (238 px) and stops above the panel's top. The portalled
 * hover card and slider tooltip take the island's zoom on both engines
 * (scope.ts usePortalZoom), as they always did on 103.
 *
 * Our own code is never rewritten and keeps the engine's native answer.
 */

const METHOD = '__brZoomRect'

function zoomRect(this: Element): DOMRect {
  const rect = this.getBoundingClientRect()
  const z = (this as Element & { currentCSSZoom?: unknown }).currentCSSZoom
  if (typeof z !== 'number' || !(z > 0) || z === 1) return rect
  return new DOMRect(rect.x / z, rect.y / z, rect.width / z, rect.height / z)
}

/** A Range has no zoom of its own; rewritten code that measures one gets the native box. */
function rangeRect(this: Range): DOMRect {
  return this.getBoundingClientRect()
}

for (const [proto, fn] of [[Element.prototype, zoomRect], [Range.prototype, rangeRect]] as const) {
  if (!Object.prototype.hasOwnProperty.call(proto, METHOD)) {
    Object.defineProperty(proto, METHOD, { value: fn, configurable: true, writable: true })
  }
}

export {}
