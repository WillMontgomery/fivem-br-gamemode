/**
 * Which lobby controls answer while a walkthrough card is up (#405).
 *
 * ═══ ONE RULE, AND EVERY STEP IS DATA FOR IT ═══
 *
 * Owner, 2026-10-11: on step 2 "disable all buttons except the one we want them
 * to press, and Previous", on step 3 "release only the Settings button", on step
 * 4 "lock the Save and Cancel buttons", and so on down the lobby half. Each of
 * those is a fact about ONE step, so each is written on that step in steps.ts
 * (`live` and `locked`) and this file is the only thing that reads them.
 *
 *   live    the only controls that answer. Absent: every control answers.
 *   locked  controls that do not answer even so. Wins over `live`.
 *
 * A control belongs to every `data-tut` anchor it sits inside, so naming a
 * screen's anchor (`page-settings`) makes the whole screen live and naming one
 * button inside it (`settings-save`) takes that button back out.
 *
 * THE CARD'S OWN BUTTONS ARE NEVER IN REACH OF THIS. The walkthrough draws
 * outside the page's `data-layer="ui"` root (App.tsx), and LOCK_SURFACES below
 * names only the lobby and the screens it visits -- so Next, Previous and
 * Dismiss cannot be locked by any step.
 *
 * PURE, AND NO RUNTIME IMPORTS, so scripts/test-tutorial-lock.mjs can load it
 * with node's type stripping, beside steps.ts.
 */

/** What one step says about the lobby's controls. See `Step.live`. */
export interface LockSpec {
  live?: readonly string[]
  locked?: readonly string[]
}

/**
 * Where a lock reaches: the lobby and the four screens the walkthrough walks
 * through. NOT the pause menu, the admin console or anything in a match -- a
 * player who presses Escape mid-walkthrough gets a whole menu, and the way out
 * of it is pointed at rather than locked (see LOBBY_WAYS_BACK in steps.ts).
 */
export const LOCK_SURFACES: readonly string[] = [
  '[data-layer="lobby"]',
  '[data-page="settings"]',
  '[data-page="locker"]',
  '[data-page="market"]',
  '[data-page="help"]',
]

/**
 * What counts as a control. Elements a press or a key can operate -- and
 * deliberately no bare `[tabindex]`, which a scrolling pane carries and which
 * would dim a whole screen rather than a button on it.
 */
export const CONTROLS =
  'button, input, select, textarea, a[href], [role="switch"], [role="button"], [role="tab"]'

/** Is a control locked, given every `data-tut` anchor it sits inside? */
export function isLocked(spec: LockSpec | null | undefined, anchors: readonly string[]): boolean {
  if (!spec) return false
  if (spec.locked?.some((a) => anchors.includes(a))) return true
  if (spec.live === undefined) return false
  return !spec.live.some((a) => anchors.includes(a))
}

/** `[data-tut="a"]` and everything inside it, for each name. */
function within(names: readonly string[]): string {
  return names.map((n) => `[data-tut="${n}"], [data-tut="${n}"] *`).join(', ')
}

/**
 * The same rule as one CSS selector, or null when the step locks nothing.
 *
 * ═══ THE BROWSER APPLIES IT, SO NOTHING HAS TO WATCH THE PAGE ═══
 *
 * The controls a step locks come and go under it -- the party panel appears the
 * moment Squads is picked, a Settings tab swaps its whole body, the Locker fills
 * in as its rows arrive. A selector covers whatever is on screen now and
 * whatever arrives next, with no observer, no per-frame walk and no attribute
 * written into a React-owned element.
 */
export function lockSelector(spec: LockSpec | null | undefined): string | null {
  if (!spec) return null
  const locked = spec.locked ?? []
  if (spec.live === undefined && locked.length === 0) return null
  const scoped = (extra: string) =>
    LOCK_SURFACES.map((s) => `${s} :is(${CONTROLS})${extra}`)
  const parts: string[] = []
  if (spec.live !== undefined) {
    parts.push(...scoped(spec.live.length > 0 ? `:not(${within(spec.live)})` : ''))
  }
  if (locked.length > 0) parts.push(...scoped(`:is(${within(locked)})`))
  return parts.join(',\n')
}

/**
 * The style sheet a lock is, or '' when the step locks nothing.
 *
 * `.btn--off`'S LOOK, which is how every disabled control in this interface
 * already reads (index.css) -- the owner's "locked controls look disabled the
 * way the UI already shows disabled controls". `pointer-events: none` is what
 * makes it a lock rather than a look: no press, no hover, no hover sound, and a
 * slider that cannot be dragged. It costs the not-allowed cursor, which a
 * control that ignores the pointer cannot show.
 */
export function lockCss(spec: LockSpec | null | undefined): string {
  const sel = lockSelector(spec)
  if (sel === null) return ''
  return `${sel} {\n  opacity: 0.4 !important;\n  pointer-events: none !important;\n  filter: none !important;\n}\n`
}

/**
 * Does the walkthrough hold Escape on this screen?
 *
 * WHILE A CARD LIVES ON THE SCREEN, YES. Every one of these screens closes on
 * Escape, and a card that waits on the screen it is about would be left waiting
 * for a screen the player can no longer reopen -- the lobby's own buttons are
 * locked to the card. So the way off a walkthrough screen is the control the card
 * points at, which is the whole of step 1's "click the options in focus".
 *
 * A screen the player opened on their own -- Settings from the last card, when
 * everything is live again -- keeps its Escape.
 */
export function holdsEscape(step: { screen?: string } | null | undefined, focus: string): boolean {
  return step?.screen !== undefined && step.screen === focus
}
