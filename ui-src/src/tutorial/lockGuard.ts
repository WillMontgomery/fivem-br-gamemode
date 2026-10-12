/**
 * The keyboard's half of the walkthrough's locks (#405).
 *
 * tutorial/lock.ts decides; TutorialLock.tsx draws the decision as a style sheet,
 * which takes the POINTER away from a locked control. This takes the KEYBOARD:
 * a locked control cannot keep focus, and a key cannot press one.
 *
 * ═══ INSTALLED ONCE, BEFORE THE FIRST SCREEN MOUNTS ═══
 *
 * A capture listener on `window` added from main.tsx runs ahead of every
 * screen's own, however often they re-register -- so a key that would press a
 * locked control is stopped here before anything else hears it.
 *
 * ═══ ESCAPE IS NOT STOPPED HERE, BUT FOR ONE FROZEN SCREEN ═══
 *
 * It was: a card waiting on a screen held Escape for that screen by stopping it
 * outright, and that took Escape from everything else on the screen too. A
 * Controls row the card itself says to click ("Click any row to rebind it")
 * could no longer be canceled -- the next key pressed was bound -- and in the
 * Season 2 Locker, Escape stopped closing its dialogs. Only the screen CLOSING
 * is held now: each screen's own close-on-Escape asks `escapeHeld()` first, and
 * every other use of Escape on it carries on as it always did. The exception is
 * Season 1's Locker, which may not be edited to ask -- see `guardHoldsEscape`.
 * scripts/check-ui.mjs (R35) holds every screen a lock reaches to that, and
 * scripts/test-tutorial-lock.mjs runs this file against a stand-in page.
 */

import { useUi } from '../store'
import { CONTROLS, LOCK_SURFACES, guardHoldsEscape, holdsEscape, isLocked } from './lock'
import { LOBBY_STEPS, type Step } from './steps'

const SURFACES = LOCK_SURFACES.join(', ')

/** The lobby card the locks follow, or null when no lobby walkthrough runs. */
export function headingStep(): Step | null {
  const s = useUi.getState()
  if (!s.tutorialRun || s.tutorialHeading === null) return null
  return LOBBY_STEPS.find((st) => st.id === s.tutorialHeading) ?? null
}

/**
 * Is the walkthrough holding the screen on top open?
 *
 * WHILE A CARD LIVES ON IT, YES -- see `holdsEscape`. Asked by each screen's own
 * Escape handler, which then does not close. Nothing else about Escape changes.
 */
export function escapeHeld(): boolean {
  return holdsEscape(headingStep(), useUi.getState().focus)
}

/** Every `data-tut` value on the element and its ancestors. */
function anchorsOf(el: Element): string[] {
  const out: string[] = []
  for (let p: Element | null = el; p !== null; p = p.parentElement) {
    const a = p.getAttribute('data-tut')
    if (a) out.push(a)
  }
  return out
}

/** Is this the inside of a control the step has locked? */
export function lockedControl(t: EventTarget | null, step: Step | null): boolean {
  if (step === null || !(t instanceof Element)) return false
  const c = t.closest(CONTROLS)
  if (c === null || c.closest(SURFACES) === null) return false
  return isLocked(step, anchorsOf(c))
}

/** The keys that operate a focused control -- press it, or move a slider. */
const OPERATES = new Set([
  'Enter', ' ', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight',
  'Home', 'End', 'PageUp', 'PageDown',
])

/** Let go of the focused control if the card has locked it. */
function releaseLocked(step: Step | null): void {
  const a = document.activeElement
  if (a instanceof HTMLElement && lockedControl(a, step)) a.blur()
}

let installed = false

export function installLockGuard(): void {
  if (installed) return
  installed = true

  window.addEventListener('keydown', (e) => {
    const step = headingStep()
    if (e.key === 'Escape') {
      const s = useUi.getState()
      if (guardHoldsEscape(step, s.focus, s.locker2.on)) {
        e.preventDefault()
        e.stopImmediatePropagation()
      }
      return
    }
    if (OPERATES.has(e.key) && lockedControl(document.activeElement, step)) {
      e.preventDefault()
      e.stopImmediatePropagation()
    }
  }, true)

  // A LOCKED CONTROL CANNOT HOLD FOCUS. Tab skips it by losing it at once, and
  // nothing else in this file then has to stop a key reaching it.
  window.addEventListener('focusin', (e) => {
    if (e.target instanceof HTMLElement && lockedControl(e.target, headingStep())) {
      e.target.blur()
    }
  }, true)

  // THE CONTROL THE PLAYER JUST PRESSED KEEPS THE FOCUS, and it is usually
  // locked by the card it moved them on to -- Squads, the moment Settings is the
  // only live control. Let go of it the moment the locks move, so the keyboard
  // is not left on a lock. One comparison per store update, and nothing else.
  useUi.subscribe((s, prev) => {
    if (s.tutorialHeading !== prev.tutorialHeading || s.tutorialRun !== prev.tutorialRun) {
      releaseLocked(headingStep())
    }
  })
}
