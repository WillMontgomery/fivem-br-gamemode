/**
 * THE SEASON 2 SCREENS' STYLESHEETS, ON ONLY WHILE ONE IS UP (#28; the lag
 * report, cause 6; #411).
 *
 * Locker v2 and the Market are each a chunk with its CSS, and the Cloudscape
 * both reach is a third (vite.config.ts): assets/LockerV2.css, MarketV2.css
 * and index2.css. Each is linked the moment the season's preload fetches its
 * chunk (both Gate.tsx files), and a linked sheet is a live one: Cloudscape's
 * put some 1,000 custom properties on <body> for the rest of the session and
 * made every full restyle in the lobby 17% dearer. So every one is DISABLED as
 * soon as its chunk has loaded and enabled only while a Locker v2 or Market
 * screen is mounted -- in the same frame as its dark mode and theme
 * (scope.ts useCloudscapeScope, which both screens use).
 *
 * WHICH: every stylesheet <link> but the page's own, assets/index.css, which
 * index.html links before anything runs. Only the Season 2 chunks are lazy, so
 * any other is one of theirs, whatever name Rollup gives the shared one.
 *
 * In the main bundle on purpose, and with no imports: the Gates call it, and
 * anything Cloudscape here would drag Cloudscape into every page. In `vite
 * dev` the CSS arrives as <style> tags, not links, so this finds nothing and
 * does nothing.
 */

/** A lazy chunk's sheet: any stylesheet link but the main bundle's. */
export const isChunkSheet = (href: string): boolean => !/\/assets\/index\.css(\?|#|$)/.test(href)

function links(): HTMLLinkElement[] {
  return Array.from(document.querySelectorAll<HTMLLinkElement>('link[rel="stylesheet"]'))
    .filter((l) => isChunkSheet(l.href))
}

/** How many mounted screens want the sheets on. */
let users = 0

/** A screen mounts (true) or unmounts (false). The sheets are on while any is. */
export function holdSheet(on: boolean): void {
  users = Math.max(0, users + (on ? 1 : -1))
  for (const l of links()) l.disabled = users === 0
}

/** A chunk has loaded: its sheets go off, unless a screen is already up. */
export function sheetLoaded(): void {
  if (users === 0) for (const l of links()) l.disabled = true
}
