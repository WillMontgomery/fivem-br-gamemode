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
  /** SLOTS by item id, whatever the item -- a second SNS Pistol is a second slot. */
  items: Map<string, number>
  /** Weapon SLOTS by weapon id, for telling a gun's own reserve from a box. */
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
  const items = new Map<string, number>()
  const weapons = new Map<string, number>()
  const pools = new Map<string, string>()
  for (const s of inv.slots) {
    if (!s) continue
    items.set(s.id, (items.get(s.id) ?? 0) + 1)
    if (s.kind !== 'weapon') continue
    weapons.set(s.id, (weapons.get(s.id) ?? 0) + 1)
    if (s.pool) pools.set(s.id, s.pool)
  }
  const ammo = new Map<string, number>(Object.entries(inv.ammo ?? {}))
  return { items, weapons, pools, ammo }
}

/**
 * Slots filled since the pickup card opened.
 *
 * ═══ ANYTHING THAT TAKES A SLOT ═══
 *
 * Owner, 2026-10-11: "the 'pick up 2 things' should actually require 2
 * weapons. If they pickup 1 weapon and 1 item that doesn't take a slot like
 * ammo, then direct them accordingly." Then, 2026-10-12, after a medkit did
 * not count: "Things like that should satisfy the requirement. Anything that takes a slot." The card after this
 * one is about switching between slots, and a box of rounds gives them nothing
 * to switch to -- but a medkit does.
 *
 * A NEW SLOT, NOT A BIGGER STACK: a second copy of something that lands in a
 * slot of its own counts; one that tops up a stack already carried takes no
 * new slot. AGAINST THE CARD'S BASELINE, deliberately: something dropped and
 * picked up again is the same one thing, and nets to nothing.
 */
export function slotsSince(before: Carried, now: Carried): number {
  let slots = 0
  for (const [id, n] of now.items) {
    const rose = n - (before.items.get(id) ?? 0)
    if (rose > 0) slots += rose
  }
  return slots
}

/**
 * Did this ONE inventory update bring a box of rounds?
 *
 * ═══ ONE UPDATE AGAINST THE ONE BEFORE IT, NEVER AGAINST THE BASELINE (#405) ═══
 *
 * A gun fills its own pool as it lands, and that is the gun, not a second
 * pickup. Measured from the card's baseline, though, a pistol and then a box of
 * pistol rounds is ONE rise in one pool with a pistol arriving -- so the box was
 * read as the pistol's own reserve and the card never said why it was still
 * waiting, in exactly the owner's case: a crate's ammo is dealt from its own
 * deck, apart from its weapons, so a box that matches the gun is common.
 *
 * The server sends the whole inventory once per item given (server/inventory.lua,
 * BR.Inv.give: one push for a gun and the reserve it lands with, one for a box),
 * so within one update the two cannot be confused: a pool that rose with no gun
 * of that pool arriving in the SAME update is a box.
 */
export function boxIn(prev: Carried, now: Carried): boolean {
  const gunPools = new Set<string>()
  for (const [id, n] of now.weapons) {
    if (n <= (prev.weapons.get(id) ?? 0)) continue
    const pool = now.pools.get(id)
    if (pool) gunPools.add(pool)
  }
  for (const [pool, n] of now.ammo) {
    if (n > (prev.ammo.get(pool) ?? 0) && !gunPools.has(pool)) return true
  }
  return false
}

/**
 * Has the pickup card got what it asked for, and if not, does it need to say why?
 *
 * `short` is the owner's case: still short of slots, with rounds taken that
 * did not count. The card shows its `ammoNote` while it is true.
 *
 * @param got  `slots` from `slotsSince`; `ammo` the boxes `boxIn` has
 *             counted, one update at a time, since the card opened
 */
export function pickupState(
  step: Pick<Step, 'slots'>,
  got: { slots: number; ammo: number },
): { done: boolean; short: boolean } {
  const want = step.slots ?? 1
  const done = got.slots >= want
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

/**
 * THE ATTRIBUTE A SCREEN PUTS UP WHILE A CARD'S CONTROL IS AWAY (#28).
 *
 * Its value names the `data-tut` targets that are away, space-separated. The
 * Season 2 Locker's "Press Done" card is about Done, which is on My Looks
 * only: inside a look the way out is Back, which goes one view up and must not
 * end the card. So inside, Done is away -- the card and its ring wait, and come
 * back with Done.
 */
export const AWAY_ATTR = 'data-tut-away'

/**
 * Has a card lost its control -- the run's "missing", which ends it?
 *
 * Not while its screen is not up (it has not started), and not while the
 * screen says the control is away (`AWAY_ATTR`): both wait. Only a control
 * that is simply not there is missing.
 */
export function targetMissing(
  step: Pick<Step, 'target'> | undefined,
  found: boolean,
  waitingForScreen: boolean,
  away: boolean,
): boolean {
  return step !== undefined && step.target !== undefined && !found && !waitingForScreen && !away
}
