/**
 * A LABEL THAT CANNOT FIT IS NOT DRAWN (owner, 2026-10-14: "text wrapping
 * should not be allowed. if you can't fit the text, don't draw it").
 *
 * A single-line label never wraps and never ends in an ellipsis. It is drawn
 * whole or not at all, and it is never shrunk to make it fit: the project's
 * sizes are the sizes. ui/Fit.tsx is the component; this is the rule and the
 * one observer behind every instance of it.
 *
 *   <span class="fit">          the room: as wide as the layout gives it
 *     <span class="fit-in">     the label: as wide as its text, on one line
 *
 * `data-unfit` goes on the room while the label is wider than it, and index.css
 * hides the label (visibility, so nothing around it moves). The room keeps its
 * box, so a label that fits again -- a wider window, a shorter name -- comes
 * back by itself.
 *
 * ONE ResizeObserver FOR THE WHOLE PAGE. It wakes only when a room or a label
 * changes size -- the label's text changing is its box changing -- so a HUD
 * repainting ten times a second costs it nothing, and the answer lands before
 * the frame is painted: a label never shows for one frame cut or overflowing.
 * No timers, no polling, nothing CEF 103 lacks (ResizeObserver is Chrome 64).
 */

/** Sub-pixel layout: a label within half a pixel of its room fits it. */
export const FIT_SLACK = 0.5

/** Does a label `need` px wide fit a room `room` px wide? */
export function fits(need: number, room: number): boolean {
  return need <= room + FIT_SLACK
}

/** The attribute that hides a label with no room (index.css `.fit[data-unfit]`). */
export const UNFIT = 'data-unfit'

/** Measure one room against its label and mark it. Returns whether it fits. */
export function judge(room: Element): boolean {
  const label = room.firstElementChild
  if (!label) return true
  // Both boxes through the same transform, so a pressed button's scale
  // cancels out of the comparison.
  const ok = fits(label.getBoundingClientRect().width, room.getBoundingClientRect().width)
  if (ok === room.hasAttribute(UNFIT)) room.toggleAttribute(UNFIT, !ok)
  return ok
}

let observer: ResizeObserver | null = null
const roomOf = new WeakMap<Element, Element>()

/**
 * Keep `room` marked for as long as it is mounted. Returns the release.
 * The first judgment is made at once, so a label that never fits is never
 * drawn at all.
 */
export function watchFit(room: Element): () => void {
  const label = room.firstElementChild
  if (!label || typeof ResizeObserver === 'undefined') return () => {}
  if (!observer) {
    observer = new ResizeObserver((entries) => {
      const seen = new Set<Element>()
      for (const e of entries) {
        const r = roomOf.get(e.target)
        if (r && !seen.has(r)) { seen.add(r); judge(r) }
      }
    })
  }
  roomOf.set(room, room)
  roomOf.set(label, room)
  observer.observe(room)
  observer.observe(label)
  judge(room)
  return () => {
    observer?.unobserve(room)
    observer?.unobserve(label)
    roomOf.delete(room)
    roomOf.delete(label)
  }
}
