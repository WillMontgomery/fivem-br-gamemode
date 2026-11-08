/**
 * WHICH SIDE OF THE RULE A NUMBER FALLS ON (#431): alone, or in a label.
 *
 * A NUMBER STANDING ALONE (a score in its cell, a bar's numeral, a level, a
 * price on its own) goes the moment its content starts to leave, so it is
 * never seen moving (motion.css `.bc-whole`).
 *
 * A NUMBER IN A LABEL is one of the label's words, so it leaves with them
 * (motion.css `.bc-whole[data-bc-run]`). Gone on its own it left a hole in
 * its words: "Send 2 reports" read "SEND   REPORTS" for the frames its words
 * took to fade. It is in a label when
 *   - the box that holds it has words or a glyph beside it: "Send 2 reports",
 *     "7,450 VOLTS", "8/8", "2,050" beside its struck "2,600", a clock glyph
 *     and its time; or
 *   - a box in its own presence says it is one (`data-bc-label`): its company
 *     is one the DOM cannot show -- a strike drawn across a price by its
 *     ::after, a chip's plate drawn by its ::before, or a struck total in the
 *     box beside it (a price and its struck total are one label); or
 *   - it is a control's whole label: a button, a link, a checkbox, a tab or
 *     the kit's Tag, inside its own presence, whose only words are the number
 *     (a price that is its buy button's label) -- a button is never seen
 *     empty. A number on a clickable card that has words of its own elsewhere
 *     (a tile's name over its price) is not its label: it stands alone.
 * An effect layer beside it (a light sweep, an empty cell) is not company.
 *
 * Read from the DOM after every render (Numeral, Clock): the words beside a
 * number can come and go with its parent's. No runtime imports and no globals,
 * only the element it is handed, so scripts/test-broadcast.mjs checks it in
 * node on stand-ins.
 *
 * THE WAY OUT AND BACK (wayOf, below) is the other half: a number in a label
 * leaves with its words only if it was SHOWING when the leave began (its
 * content had landed, it had changed and shown at once, or it had come back
 * still showing). One whose entrance had not landed yet is not on screen to
 * take out: it leaves as a number alone does (hidden), so its entrance, still
 * pending, never lands in the middle of the leave. A presence that turns
 * round finds it as it left it: still showing (no hide, no tick-in again), or
 * hidden (it lands and ticks in as ever).
 */

import type { Phase } from './machine'

/** A control or a tag: its label is words, whatever it says. */
export const CONTROL = 'button, a[href], [role="button"], [role="checkbox"], [role="tab"], .bc-tag'

/** A box that draws a number's company in CSS says so. */
export const LABEL = '[data-bc-label]'

const TEXT = 3
const ELEMENT = 1

/** Words or a glyph: what keeps a number company. */
function company(n: Node): boolean {
  if (n.nodeType === TEXT) return /\S/.test(n.nodeValue ?? '')
  if (n.nodeType !== ELEMENT) return false
  const e = n as Element
  return /\S/.test(e.textContent ?? '') || e.localName === 'svg' || e.localName === 'img' || e.querySelector('svg, img') !== null
}

/** Words anywhere in `n` but inside `skip`. */
function wordsBut(n: Node, skip: Node): boolean {
  for (const k of Array.from(n.childNodes)) {
    if (k === skip) continue
    if (k.nodeType === TEXT ? /\S/.test(k.nodeValue ?? '') : k.nodeType === ELEMENT && wordsBut(k, skip)) return true
  }
  return false
}

/** True when the number drawn by `el` sits in a label (above). */
export function inLabel(el: Element): boolean {
  const box = el.parentElement
  if (box !== null) {
    for (const n of Array.from(box.childNodes)) if (n !== el && company(n)) return true
  }
  // Only a box or a control inside the number's own presence: a presence
  // mounted in one leaves inside it, and the box is not what is leaving.
  const root = el.closest('[data-bc-phase]')
  const ours = (e: Element | null): boolean => e !== null && (root === null || root.contains(e))
  if (ours(el.closest(LABEL))) return true
  const control = el.closest(CONTROL)
  if (control === null || wordsBut(control, el)) return false
  return ours(control)
}

/** What a number sees of its presence (PhaseInfo, without its clock). */
export interface Moment {
  phase: Phase
  /** Entrances so far. */
  epoch: number
  /** Clock time the content lands on this entrance. */
  landAt: number
}

/** THE WAY OUT AND BACK: what a number remembers of its presence's moments. */
export interface Way {
  phase: Phase
  epoch: number
  /** When the entrance it last saw lands its content (clock ms). */
  landAt: number
  /** This leave takes it out with its words: it was showing as it began. */
  keep: boolean
  /** The entrance that turned round with it still showing (-1: none). */
  back: number
}

/** The first reading. A number that mounts mid-leave is drawn with its words. */
export function wayStart(m: Moment): Way {
  return { phase: m.phase, epoch: m.epoch, landAt: m.landAt, keep: m.phase === 'leaving', back: -1 }
}

/**
 * The next reading, on every render. `now` is the presence's clock, `run`
 * the side read off the DOM (inLabel), `live` that the number changed and
 * showed at once in the entrance `w` last saw (Numeral's data-bc-live).
 * Showing, as a phase ends: shown; or entering and landed (now at its
 * landing), live, or come back still showing; or leaving with its words.
 */
export function wayOf(w: Way, m: Moment, now: number, run: boolean, live: boolean): Way {
  if (w.phase === m.phase && w.epoch === m.epoch) return w.landAt === m.landAt ? w : { ...w, landAt: m.landAt }
  const showing = w.phase === 'shown'
    || (w.phase === 'entering' && (w.back === w.epoch || live || now >= w.landAt))
    || (w.phase === 'leaving' && w.keep)
  const next = { phase: m.phase, epoch: m.epoch, landAt: m.landAt, keep: false, back: w.back }
  if (m.phase === 'leaving') return { ...next, keep: run && showing }
  if (m.phase === 'entering' && w.phase === 'leaving' && w.keep) return { ...next, back: m.epoch }
  return next
}

/** Draw `data-bc-run` now: in a label, and not on a leave it is not showing for. */
export function runs(run: boolean, w: Way): boolean {
  return run && (w.phase !== 'leaving' || w.keep)
}

/** This entrance found it still showing: not hidden, not ticked in, not counted up. */
export function cameBack(w: Way): boolean {
  return w.phase === 'entering' && w.back === w.epoch
}
