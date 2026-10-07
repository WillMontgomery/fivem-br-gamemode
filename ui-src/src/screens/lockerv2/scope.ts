import { useEffect, useLayoutEffect, useState } from 'react'
import { applyMode, Mode } from '@cloudscape-design/global-styles'
import { applyTheme } from '@cloudscape-design/components/theming'
import { useUi } from '../../store'
import { LOCKER_THEME } from './theme'
import { zoomFor } from './model'

/**
 * CLOUDSCAPE, FOR AS LONG AS THE LOCKER IS UP, AND NOT A MOMENT LONGER (#28).
 *
 * Nothing else in br_ui uses Cloudscape, so its mode and theme are put on when
 * the screen mounts and taken off when it unmounts (contract section 5):
 *
 *   MODE   applyMode(Dark) on <body>, never on <html> -- global-styles keys a
 *          `color-scheme: dark` off <html>, and a CEF that honors it paints the
 *          canvas over the game black (#385, vite.terminal.config.ts). The
 *          JavaScript only: global-styles' CSS is never imported.
 *   THEME  applyTheme, our tokens, as one <style> element it removes again.
 *
 * Both are global rather than scoped to the screen's element because two of
 * Cloudscape's pieces render into <body> whatever they are told: the hover
 * card on a locked tab (SegmentedControl's disabledReason) and a slider's value
 * tooltip. Scoped, those two would be drawn in Cloudscape's own light colors.
 */
export function useCloudscapeScope(): void {
  useLayoutEffect(() => {
    applyMode(Mode.Dark)
    const theme = applyTheme({ theme: LOCKER_THEME })
    return () => {
      theme.reset()
      applyMode(Mode.Light)
    }
  }, [])
}

/** The root font size, in px, which carries resolution and the interface-size
 *  slider (index.css's `clamp(11px, calc(1.481vh * var(--ui-scale)), 28px)`). */
function rootPx(): number {
  return parseFloat(getComputedStyle(document.documentElement).fontSize)
}

/**
 * The island's zoom: root px / 14, so Cloudscape's 14 px body text is one rem
 * (contract section 5). Re-read when the window resizes and when the settings
 * change, which is when the root font size can move.
 */
export function useIslandZoom(): number {
  const settings = useUi((s) => s.settings)
  const [z, setZ] = useState(() => zoomFor(rootPx()))
  useEffect(() => { setZ(zoomFor(rootPx())) }, [settings])
  useEffect(() => {
    const on = () => setZ(zoomFor(rootPx()))
    window.addEventListener('resize', on)
    return () => window.removeEventListener('resize', on)
  }, [])
  return z
}

/**
 * DOES THIS ENGINE REPORT A ZOOMED ELEMENT'S BOX IN ITS OWN ZOOMED PX?
 *
 * Chromium before 128 (FiveM's CEF is 103) did: getBoundingClientRect inside
 * `zoom: 2` came back halved, and a `left` written there is doubled on screen,
 * so a read and a write in the same zoom agree. 128 standardized zoom and
 * reports what is drawn. Cloudscape positions its tooltips from one element's
 * box and writes the result into another, so which of the two this engine
 * does decides whether the tooltip's own container must wear the same zoom.
 * Measured once, on a probe, rather than guessed from a version string.
 */
let legacy: boolean | null = null
export function legacyZoom(): boolean {
  if (legacy !== null) return legacy
  const outer = document.createElement('div')
  outer.style.cssText = 'position:absolute;visibility:hidden;left:0;top:0;zoom:2'
  const inner = document.createElement('div')
  inner.style.cssText = 'width:10px;height:10px'
  outer.appendChild(inner)
  document.body.appendChild(outer)
  legacy = Math.abs(inner.getBoundingClientRect().width - 10) < 0.5
  outer.remove()
  return legacy
}

/**
 * THE TWO THINGS CLOUDSCAPE PUTS IN <body> WEAR THE ISLAND'S ZOOM.
 *
 * The locked tab's hover card and the slider's value are portalled into a
 * fresh <div> on <body>, outside the zoomed island: unzoomed they are drawn at
 * 14 px on a 4K screen beside text twice that size, and on CEF 103 placed from
 * a box measured in the island's px. While the locker is up, every Cloudscape
 * container that appears on <body> is given the island's zoom -- on an engine
 * that measures in zoomed px only, since on one that does not, the zoom would
 * move the card rather than fix it.
 */
export function usePortalZoom(z: number): void {
  useEffect(() => {
    if (!legacyZoom()) return
    const zoomed = new Set<HTMLElement>()
    const take = (el: HTMLElement) => {
      if (el.id === 'root' || zoomed.has(el)) return
      if (!el.querySelector('[class*="awsui_"]')) return
      el.style.setProperty('zoom', String(z))
      zoomed.add(el)
    }
    const scan = () => {
      for (const el of Array.from(document.body.children)) {
        if (el instanceof HTMLDivElement) take(el)
      }
    }
    // The container is appended empty and filled a render later, so a node
    // that arrives bare is looked at again on the next frame.
    const obs = new MutationObserver((records) => {
      for (const r of records) {
        for (const n of Array.from(r.addedNodes)) {
          if (!(n instanceof HTMLDivElement)) continue
          take(n)
          if (!zoomed.has(n)) window.requestAnimationFrame(() => take(n))
        }
      }
    })
    scan()
    obs.observe(document.body, { childList: true })
    return () => {
      obs.disconnect()
      for (const el of zoomed) el.style.removeProperty('zoom')
    }
  }, [z])
}
