/**
 * The lobby walkthrough's locks, drawn (#405).
 *
 * ONE STYLE SHEET, REWRITTEN WHEN THE CARD MOVES ON. The rule is tutorial/lock.ts's
 * and the data is each step's `live` and `locked` in steps.ts; this component
 * only puts the selector on the page while the lobby walkthrough runs, which is
 * the whole of how a locked control looks disabled and cannot be pressed. The
 * keyboard's half -- focus included, when the card moves on -- is lockGuard.ts.
 *
 * NOTHING PER FRAME. The browser matches the selector against whatever is on
 * screen, so the controls that arrive under a card -- the party panel, a
 * Settings tab's body, the Locker's rows -- are covered with no observer and no
 * walk of the page.
 */

import { useUi } from '../store'
import { lockCss } from './lock'
import { LOBBY_STEPS } from './steps'

export default function TutorialLock() {
  const heading = useUi((s) => s.tutorialHeading)
  const step = LOBBY_STEPS.find((st) => st.id === heading) ?? null
  const css = lockCss(step)
  return css === '' ? null : <style data-tut-lock="">{css}</style>
}
