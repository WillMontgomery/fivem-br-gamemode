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
    // reasons. It keeps them at the SAME height as each other (they read as
    // one row, and a squad panel sitting higher than the counters looked
    // accidental), and it leaves the band immediately under the safe-zone top
    // free -- which is where GTA draws its own instructional/help prompts, on
    // the left, underneath ours (user, 2026-08-05).
    //
    // It is built from the player's safe zone, so it follows their margin
    // slider exactly as the vitals strip does; HELP_BAND is the height of the
    // engine's prompt band, which is a fraction of screen height and so is
    // expressed in vh.
    const HELP_BAND = 7.5
    root.setProperty('--hud-top', `calc(${d.safeY}% + ${HELP_BAND}vh)`)
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
  useEffect(() => {
    const apply = () => {
      const aspect = window.innerWidth / window.innerHeight
      const usable = aspect > 2.1 ? `${((2.1 / aspect) * 100).toFixed(2)}%` : '100%'
      document.documentElement.style.setProperty('--usable-w', usable)
    }
    apply()
    window.addEventListener('resize', apply)
    return () => window.removeEventListener('resize', apply)
  }, [])

  return metrics
}
