import { useNuiEvent } from '../bridge/useNuiEvent'
import { useState } from 'react'
import type { ScreenPayload } from '../bridge/types'

/**
 * Applies the game's real screen metrics to CSS custom properties.
 *
 * Everything in the HUD positions against the safe-zone rectangle
 * (--safe-x/--safe-y/--safe-r/--safe-b) and the minimap rectangle (--map-*),
 * so writing them here is enough to relayout the whole interface. No component
 * needs to know the resolution, and nothing works out a margin of its own.
 *
 * FOUR EDGES, NOT TWO. Lua asks the engine for each corner of the safe zone
 * rather than deriving one inset from GetSafeZoneSize, because the horizontal
 * and vertical insets are not the same number on anything but 16:9 (#231).
 * Older payloads carry only safeX/safeY; the right and bottom fall back to
 * them, which is exactly the old behaviour and no worse.
 *
 * Until the first screen envelope arrives -- and always, in the browser dev
 * harness -- the fallbacks in index.css apply, so the HUD is never unstyled.
 */
export function useScreenMetrics(): ScreenPayload | null {
  const [metrics, setMetrics] = useState<ScreenPayload | null>(null)

  useNuiEvent('screen', (d) => {
    // METRICS ONLY. The screen envelope has a second sender: the scope watcher
    // publishes `{ scoped }` alone the instant a scope opens or closes, and
    // that payload carries no safe zone at all.
    //
    // Without this guard those writes became `--safe-x: undefined%`, which is
    // not a length -- so `bottom: var(--safe-y)` stopped resolving, every
    // absolutely-positioned panel fell back to the document origin, and the
    // inventory bar rendered in the top-left until the next 1Hz metrics
    // publish put the real numbers back. That is the snap (user, 2026-08-08,
    // reported twice: the first fix was in the store, and the store is not
    // what writes these).
    if (d.safeX == null || d.safeY == null) return

    setMetrics(d)
    const root = document.documentElement.style
    root.setProperty('--safe-x', `${d.safeL ?? d.safeX}%`)
    root.setProperty('--safe-y', `${d.safeT ?? d.safeY}%`)
    root.setProperty('--safe-r', `${d.safeR ?? d.safeX}%`)
    root.setProperty('--safe-b', `${d.safeB ?? d.safeY}%`)
    // The minimap rectangle, in viewport percentages. Everything that anchors
    // to the radar -- our health/shield strip, the chat column, the notice
    // stack -- reads these, so the whole lower-left interface follows the
    // player's safe-zone slider without any component knowing about it.
    if (d.mapLeft != null)   root.setProperty('--map-left',   `${d.mapLeft}vw`)
    if (d.mapBottom != null) root.setProperty('--map-bottom', `${d.mapBottom}vh`)
    if (d.mapW != null)      root.setProperty('--map-w',      `${d.mapW}vw`)
    if (d.mapH != null)      root.setProperty('--map-h',      `${d.mapH}vh`)

    // THE TOP ROW'S OWN BASELINE.
    //
    // Both top panels hang off this rather than off --safe-y directly, for two
    // reasons. It keeps them at the SAME height as each other -- a squad panel
    // sitting higher than the counters looked accidental -- and it is built
    // from the player's safe zone, so it follows their margin slider exactly
    // as the vitals strip does.
    //
    // THE HELP-BAND OFFSET IS GONE. This used to add 7.5vh to clear the band
    // where GTA draws its own instructional prompts. That is no longer needed:
    // the HUD is hidden outright during freefall and glide, which is when
    // those prompts appear, and scope hiding covers the other overlay case --
    // so the corners now sit level with the storm bar (user, 2026-08-07).
    //
    // Note this line, not index.css, is what actually decides: the stylesheet
    // fallback only applies until the first metrics envelope arrives, and
    // setting --hud-top there while still adding an offset here meant the
    // panels never moved at all.
    root.setProperty('--hud-top', `${d.safeT ?? d.safeY}%`)
  })

  // ═══ THE ULTRAWIDE CLAMP IS GONE, AND THAT IS HALF OF #231 ═══
  //
  // There used to be a --usable-w here: past roughly 21:9 the HUD's box was
  // narrowed and centred, on the judgement that anchored elements otherwise sit
  // far enough apart to need a head turn. It is deleted for two reasons, and
  // either one alone would be enough.
  //
  // IT ONLY EVER MOVED HALF THE HUD. The clamp lives on `.hud-safe`, so the
  // health bars (inside it) moved and the chat column and notice stack (both
  // rendered at App level, outside it) did not -- three surfaces that are all
  // meant to sit on the minimap's left edge, pulled apart by the thing that
  // was supposed to tidy them up. Measured at 32:9: 305px of disagreement.
  //
  // AND THE ENGINE ALREADY DOES IT. The clamp was hand-rolling the inward pull
  // that GTA's own safe zone performs on a wide panel -- which we now read
  // instead of guessing at (citizenfx/fivem#2719: the engine keeps the minimap
  // "in the center(ish) of the screen as if it was following a 16:9 aspect
  // ratio"). Doing it twice, to some of the elements, from two different
  // numbers, is what the ultrawide screenshots actually show.
  //
  // Narrowing `.hud-safe` also meant TRANSFORMING it, and a transformed
  // ancestor becomes the containing block for `position: fixed` descendants --
  // which quietly captured the vitals strip. index.css and check-ui's R12
  // carry that half.
  return metrics
}
