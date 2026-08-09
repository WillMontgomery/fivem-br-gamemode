import { useEffect, useState } from 'react'
import { useNuiEvent } from '../bridge/useNuiEvent'
import type { ScreenPayload } from '../bridge/types'

/**
 * Applies the game's real screen metrics to CSS custom properties.
 *
 * Everything in the HUD positions against --safe-x / --safe-y and sizes against
 * --radar-w / --radar-h, so writing them here is enough to relayout the whole
 * interface. No component needs to know the resolution.
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
    root.setProperty('--safe-x', `${d.safeX}%`)
    root.setProperty('--safe-y', `${d.safeY}%`)
    root.setProperty('--radar-w', `${d.radarW}rem`)
    root.setProperty('--radar-h', `${d.radarH}rem`)
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
    root.setProperty('--hud-top', `${d.safeY}%`)
  })

  // Ultrawide handling, such as it can be.
  //
  // GTA's safe zone already pulls the HUD in from the edges on wide panels, so
  // respecting it gets most of the way there. What it does not do is stop
  // anchored elements sitting so far apart that the player has to physically
  // turn their head to read them. Past roughly 21:9 we cap the usable width.
  //
  // This is a judgement call rather than something the engine tells us -- the
  // base game does not do it -- so it is deliberately mild and only ever pulls
  // elements inward, never pushes them out.
  //
  // THE ENGINE'S ASPECT WINS. This used to derive its own from
  // window.innerWidth/innerHeight while `aspect` sat unread in the screen
  // envelope -- typed, mocked, published, and consumed by nothing. The engine
  // value is the authority: it is what GTA itself lays the safe zone out
  // against, and it survives a resolution change that the window may report
  // late or not at all. The window ratio stays as the fallback for the browser
  // harness, where there is no engine to ask.
  const engineAspect = metrics?.aspect
  useEffect(() => {
    const apply = () => {
      const aspect = engineAspect && engineAspect > 0
        ? engineAspect
        : window.innerWidth / window.innerHeight
      const usable = aspect > 2.1 ? `${((2.1 / aspect) * 100).toFixed(2)}%` : '100%'
      document.documentElement.style.setProperty('--usable-w', usable)
    }
    apply()
    window.addEventListener('resize', apply)
    return () => window.removeEventListener('resize', apply)
  }, [engineAspect])

  return metrics
}
