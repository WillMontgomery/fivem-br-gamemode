/**
 * What the walkthrough decides about moving between cards, without a page (#405).
 *
 * PURE, AND NO RUNTIME IMPORTS, so scripts/test-tutorial-game.mjs can load it
 * with node's type stripping beside gameSteps.ts -- the same arrangement lock.ts
 * has with steps.ts. TutorialLayer is the only caller.
 *
 * ═══ PREVIOUS IS A PAGE TURN, NOT AN UNDO ═══
 *
 * Owner, 2026-10-11: "For the in-game tutorial, step 15 back button doesn't
 * work." It did work, for a frame. Previous on "The full inventory" landed on
 * "What you are carrying", which ends when the player switches slots -- and
 * they already had, on the way through. The layer kept that card's old
 * baseline so a reader turning back would not be asked for the work twice
 * (owner, 2026-09-08: "I have to open a new crate to move back to 12 lol"), and
 * a kept baseline is an advance that is already satisfied: the card moved them
 * straight back to step 15, and the arrow looked dead.
 *
 * So a card the player has stepped BACK onto is shown as a page: it says what
 * it said, and Next (the button, or the right arrow in game) is the way on.
 * Nothing it was waiting for is waited for again, and nothing moves by itself.
 *
 * A REAL CONTROL STILL HAS TO BE PRESSED. A `click` card asks for its control
 * again after Previous (owner, 2026-09-05, "the 'last' button doesn't seem to
 * return to the last step", fixed by forgetting the press) and the lobby's
 * locks are built on that, so `click` keeps its own advance. `next` and
 * `dismiss` are already pages.
 */

import type { Advance, Step } from './steps'

/**
 * May this card step back to the one before it?
 *
 * ONE ANSWER FOR THE BUTTON AND FOR BOTH ARROWS. The card's Previous used this
 * rule and the arrows did not: they skipped the doorway test, so the left arrow
 * moved where no Previous was shown. On "Everybody in the match" it stepped back
 * onto the chat card, which had already been answered and sent them straight
 * forward again; on "Reporting somebody" it closed the player list behind them.
 * Back across a doorway is now refused the same way on every input.
 *
 * NO WAY BACK ACROSS A DOORWAY. Owner, 2026-09-04: a card on another screen
 * than the one before it has no Previous, because Previous cannot reopen the
 * screen the player has left. `noBack` is the same refusal for a doorway the
 * `screen` field cannot see.
 *
 * ...AND A TAB IS A DOORWAY TOO (#405). Owner, 2026-09-04: "For the first
 * instruction on each page like step 10, no 'last' button should be available."
 * That was one `noBack`, on step 10, and step 12 -- the first card on the
 * Accessibility tab -- never got one. From it, Previous twice landed on step 10
 * with the Controls tab locked and closed, its control nowhere on screen, and
 * the run ended 1.2 seconds later. `view` names the part of the screen a card
 * is shown over, and a change of view is refused the way a change of screen is.
 */
export function canGoBack(steps: readonly Step[], i: number): boolean {
  const here = steps[i]
  const prev = i > 0 ? steps[i - 1] : undefined
  if (here === undefined || prev === undefined) return false
  if (here.noBack === true) return false
  return prev.screen === here.screen && prev.view === here.view
}

/** The advances that are already a page, or that ask for a real control. */
const KEEPS: ReadonlySet<Advance> = new Set<Advance>(['next', 'click', 'dismiss'])

/**
 * A card as it is shown once the player has stepped back onto it.
 *
 * See the header: anything it was waiting for has been done, so it ends on Next.
 */
export function asRevisited(step: Step): Step {
  return KEEPS.has(step.advance) ? step : { ...step, advance: 'next' }
}

/** One slot of the inventory payload, as far as this file reads it. */
export interface CarriedSlot {
  id: string
  kind: string
  count?: number
  pool?: string
}

/** What a player is carrying, counted the way the pickup card asks. */
export interface Carried {
  /** Weapon SLOTS by weapon id -- a second SNS Pistol is a second slot. */
  weapons: Map<string, number>
  /** The pool each carried weapon draws from, by weapon id. */
  pools: Map<string, string>
  /** Rounds in reserve, by pool. */
  ammo: Map<string, number>
}

/**
 * Read a carried inventory for the pickup card.
 *
 * @param inv  the store's `inv` -- empty slots are null
 */
export function carried(inv: {
  slots: ReadonlyArray<CarriedSlot | null>
  ammo?: Record<string, number> | null
}): Carried {
  const weapons = new Map<string, number>()
  const pools = new Map<string, string>()
  for (const s of inv.slots) {
    if (!s || s.kind !== 'weapon') continue
    weapons.set(s.id, (weapons.get(s.id) ?? 0) + 1)
    if (s.pool) pools.set(s.id, s.pool)
  }
  const ammo = new Map<string, number>(Object.entries(inv.ammo ?? {}))
  return { weapons, pools, ammo }
}

/**
 * What the pickup card has seen arrive since it opened.
 *
 * ═══ TWO WEAPONS, NOT TWO THINGS ═══
 *
 * Owner, 2026-10-11: "the 'pick up 2 things' should actually require 2
 * weapons. If they pickup 1 weapon and 1 item that doesn't take a slot like
 * ammo, then direct them accordingly." The card after this one is about
 * switching between slots, and a box of rounds gives them nothing to switch to.
 *
 *   weapons  weapon slots that arrived. A second copy of a gun they already
 *            hold is a second slot and counts.
 *   ammo     pools that rose with NO GUN OF THAT POOL ARRIVING -- a box picked
 *            up, which takes no slot. A gun fills its own pool as it lands, and
 *            that is the gun, not a second pickup.
 *
 * Under-counting `ammo` is the safe direction: it only decides whether the card
 * explains itself, never whether it ends.
 */
export function pickupSince(before: Carried, now: Carried): { weapons: number; ammo: number } {
  let weapons = 0
  const gunPools = new Set<string>()
  for (const [id, n] of now.weapons) {
    const rose = n - (before.weapons.get(id) ?? 0)
    if (rose <= 0) continue
    weapons += rose
    const pool = now.pools.get(id)
    if (pool) gunPools.add(pool)
  }
  let ammo = 0
  for (const [pool, n] of now.ammo) {
    if (n <= (before.ammo.get(pool) ?? 0)) continue
    if (gunPools.has(pool)) continue
    ammo += 1
  }
  return { weapons, ammo }
}

/**
 * Has the pickup card got what it asked for, and if not, does it need to say why?
 *
 * `short` is the owner's case: still short of weapons, with rounds taken that
 * did not count. The card shows its `ammoNote` while it is true.
 */
export function pickupState(
  step: Pick<Step, 'weapons'>,
  got: { weapons: number; ammo: number },
): { done: boolean; short: boolean } {
  const want = step.weapons ?? 1
  const done = got.weapons >= want
  return { done, short: !done && got.ammo > 0 }
}

/**
 * Where a card about the open map goes when the map is closed under it.
 *
 * Only a card that is being READ goes anywhere (`next`): the waypoint card
 * waits with its toast, and the close card's advance is the map going. A
 * reader goes back to the card that opens the map -- the nearest one before it
 * that advances on `map` -- which is the instruction they need next. Null when
 * there is none, and the card waits.
 */
export function mapGoneTo(steps: readonly Step[], i: number): number | null {
  const here = steps[i]
  if (here === undefined || here.overMap !== true || here.advance !== 'next') return null
  for (let j = i - 1; j >= 0; j--) {
    if (steps[j]!.advance === 'map') return j
  }
  return null
}
