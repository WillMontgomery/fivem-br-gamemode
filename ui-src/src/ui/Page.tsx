import { useEffect, useRef, useState } from 'react'

/**
 * A lobby sub-screen, with an entrance and an exit.
 *
 * THE EXIT IS THE WHOLE REASON THIS EXISTS. Rendering a screen with
 * `{open && <Locker />}` gives you a transition in one direction only: the
 * page arrives nicely and then vanishes in a single frame when it closes,
 * which reads worse than having no transition at all, because the eye has
 * been taught to expect one.
 *
 * So the child stays MOUNTED for the length of its exit animation and is
 * dropped afterwards. That is the only trick here; the motion itself lives in
 * index.css (.page-in / .page-out) with the rest of the vocabulary.
 *
 * Nothing is kept alive longer than EXIT_MS. A screen that failed to unmount
 * would sit invisible over the lobby swallowing clicks -- .page-out turns
 * pointer events off for exactly that reason, but a timer that never fires
 * would still leak one element per open.
 */

/** Must match .page-out's duration in index.css. */
const EXIT_MS = 200

export default function Page({
  show, children,
}: { show: boolean; children: React.ReactNode }) {
  const [mounted, setMounted] = useState(show)
  // The last children seen while OPEN. During the exit the caller has usually
  // already stopped supplying them (the screen is conditional on focus), and
  // rendering `null` mid-exit would blank the page and animate an empty box.
  const held = useRef<React.ReactNode>(children)
  if (show) held.current = children

  useEffect(() => {
    if (show) { setMounted(true); return }
    const t = window.setTimeout(() => setMounted(false), EXIT_MS)
    return () => window.clearTimeout(t)
  }, [show])

  if (!mounted) return null

  // `.page` IS NOT COSMETIC AND MUST NOT BE REMOVED.
  //
  // This wrapper carries an animated TRANSFORM, and a transformed element
  // becomes the CONTAINING BLOCK for every `position: fixed` descendant --
  // they stop resolving against the viewport and resolve against this div
  // instead. Every screen in here is `fixed inset-0`, and this div, as a bare
  // block in App's fragment, is zero-height at the top of the document. So
  // each one collapsed to a 0x0 box and rendered off the top of the screen
  // (user, 2026-08-09: "way above our vertical draw space", "opens a blank
  // page").
  //
  // `.page` makes the wrapper the viewport rect itself, so a fixed child
  // resolves to exactly the box it would have had anyway. The transform stays
  // and the children never learn about any of this.
  return (
    <div className={`page ${show ? 'page-in' : 'page-out'}`}>{held.current}</div>
  )
}
