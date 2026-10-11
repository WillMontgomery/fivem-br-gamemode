/**
 * The lobby walkthrough's locks, drawn (#405).
 *
 * ONE STYLE SHEET, REWRITTEN WHEN THE CARD MOVES ON. The rule is tutorial/lock.ts's
 * and the data is each step's `live` and `locked` in steps.ts; this component
 * only puts the selector on the page while the lobby walkthrough runs, which is
 * the whole of how a locked control looks disabled and cannot be pressed. The
 * keyboard's half is lockGuard.ts.
 *
 * NOTHING PER FRAME. The browser matches the selector against whatever is on
 * screen, so the controls that arrive under a card -- the party panel, a
 * Settings tab's body, the Locker's rows -- are covered with no observer and no
 * walk of the page.
 */

import { useEffect } from 'react'

import { useUi } from '../store'
import { lockCss } from './lock'
import { lockedControl } from './lockGuard'
import { LOBBY_STEPS } from './steps'

export default function TutorialLock() {
  const heading = useUi((s) => s.tutorialHeading)
  const step = LOBBY_STEPS.find((st) => st.id === heading) ?? null

  // THE CONTROL THE PLAYER JUST PRESSED KEEPS THE FOCUS, and it is usually
  // locked by the card it moved them on to -- Squads, the moment Settings is the
  // only live control. Let go of it, so the keyboard is not left on a lock.
  useEffect(() => {
    const a = document.activeElement
    if (a instanceof HTMLElement && lockedControl(a, step)) a.blur()
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [heading])

  const css = lockCss(step)
  return css === '' ? null : <style data-tut-lock="">{css}</style>
}
