/**
 * LOCKER V2'S STYLESHEET, ON ONLY WHILE THE LOCKER IS UP (#28; the lag
 * report, cause 6).
 *
 * The chunk's CSS (assets/LockerV2.css: Cloudscape's 594 KB, this screen's
 * own rules) is linked the moment the season's preload fetches the chunk
 * (Gate.tsx), and a linked sheet is a live one: it put some 1,000 custom
 * properties on <body> for the rest of the session and made every full
 * restyle in the lobby 17% dearer. So the link is DISABLED as soon as the
 * chunk has loaded and enabled only while a Locker v2 screen is mounted --
 * in the same frame as its dark mode and theme (scope.ts).
 *
 * In the main bundle on purpose, and with no imports: Gate.tsx calls it, and
 * anything Cloudscape here would drag Cloudscape into every page. In `vite
 * dev` the CSS arrives as <style> tags, not a link, so this finds nothing
 * and does nothing.
 */

/** The chunk's <link>s: vite names the chunk's CSS after the screen. */
function links(): HTMLLinkElement[] {
  return Array.from(document.querySelectorAll<HTMLLinkElement>('link[rel="stylesheet"]'))
    .filter((l) => /\/LockerV2[^/]*\.css(\?|$)/.test(l.href))
}

/** How many mounted screens want the sheet on. */
let users = 0

/** A screen mounts (true) or unmounts (false). The sheet is on while any is. */
export function holdSheet(on: boolean): void {
  users = Math.max(0, users + (on ? 1 : -1))
  for (const l of links()) l.disabled = users === 0
}

/** The chunk has loaded: its sheet goes off, unless a screen is already up. */
export function sheetLoaded(): void {
  if (users === 0) for (const l of links()) l.disabled = true
}
