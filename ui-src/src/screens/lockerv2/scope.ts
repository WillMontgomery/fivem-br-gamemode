import { useEffect, useLayoutEffect, useState } from 'react'
import { applyMode, Mode } from '@cloudscape-design/global-styles'
import { applyTheme } from '@cloudscape-design/components/theming'
import { useUi } from '../../store'
import { LOCKER_THEME } from '../../ui/cloudscape/theme'
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
 * THE TWO THINGS CLOUDSCAPE PUTS IN <body> WEAR THE ISLAND'S ZOOM.
 *
 * The locked tab's hover card and the slider's value are portalled into a
 * fresh <div> on <body>, outside the zoomed island: unzoomed they are drawn at
 * 14 px on a 4K screen beside text twice that size, and placed from a box
 * Cloudscape measures in the island's px. While the locker is up, every
 * Cloudscape container that appears on <body> is given the island's zoom.
 *
 * ON EVERY ENGINE (#413). Cloudscape measures in zoomed px on CEF 144 too
 * (src/cef/zoomRect.ts), so the card is placed and sized as on CEF 103; this
 * used to stand down on an engine with standardized zoom, which left the card
 * in the right place at half size on 4K.
 */
export function usePortalZoom(z: number): void {
  useEffect(() => {
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
