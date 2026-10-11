/**
 * The keyboard's half of the walkthrough's locks (#405).
 *
 * tutorial/lock.ts decides; TutorialLock.tsx draws the decision as a style sheet,
 * which takes the POINTER away from a locked control. This takes the KEYBOARD:
 * a locked control cannot keep focus, a key cannot press one, and Escape cannot
 * close a screen a card is waiting on.
 *
 * ═══ INSTALLED ONCE, BEFORE THE FIRST SCREEN MOUNTS, AND THAT ORDER IS THE POINT ═══
 *
 * Settings, Help, the Locker and the Market each close on Escape from their own
 * capture listener on `window`, and Settings re-adds its listener on every render.
 * A listener installed from main.tsx, ahead of all of them, runs first however
 * often they re-register -- so `stopImmediatePropagation` here is the one place
 * that can hold Escape for all four, and no screen has to know a walkthrough
 * exists.
 */

import { useUi } from '../store'
import { CONTROLS, LOCK_SURFACES, holdsEscape, isLocked } from './lock'
import { LOBBY_STEPS, type Step } from './steps'

const SURFACES = LOCK_SURFACES.join(', ')

/** The lobby card the locks follow, or null when no lobby walkthrough runs. */
export function headingStep(): Step | null {
  const s = useUi.getState()
  if (!s.tutorialRun || s.tutorialHeading === null) return null
  return LOBBY_STEPS.find((st) => st.id === s.tutorialHeading) ?? null
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

let installed = false

export function installLockGuard(): void {
  if (installed) return
  installed = true

  window.addEventListener('keydown', (e) => {
    const step = headingStep()
    if (step === null) return
    if (e.key === 'Escape' && holdsEscape(step, useUi.getState().focus)) {
      e.preventDefault()
      e.stopImmediatePropagation()
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
}
