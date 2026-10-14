/**
 * THE SEASON 2 MARKET'S DECISIONS (#411), with nothing to render and no
 * runtime imports.
 *
 * Every rule the page applies before it draws -- which tabs exist, which tab is
 * shown, what a card's edge and its one action are, when a press asks to buy
 * and when a confirm that is up no longer means what it says -- lives here, so
 * scripts/test-marketv2.mjs can load this file with node's type stripping and
 * hold each rule to the owner's words. MarketV2.tsx asks; it never decides.
 *
 * THE SERVER IS THE AUTHORITY. Nothing here writes a balance or an ownership:
 * a purchase asks (MARKET_BUY, an id), and the answer arrives as a whole new
 * grid. These rules only keep the page from offering what the grid it holds
 * already says is pointless.
 */

import type { MarketItem } from '../../bridge/types'

export type Kind = MarketItem['kind']
/** Every kind that can be a tab: all but verdicts, which are not for sale. */
export type TabKind = Exclude<Kind, 'verdict'>

/**
 * The tabs, left to right. Season 1's order (screens/Market.tsx's TABS, then
 * its Emotes tab); a kind that has nothing on the grid gets no tab at all.
 * VERDICTS ARE NOT FOR SALE (owner, 2026-08-12) and never get one.
 */
export const TAB_ORDER: readonly TabKind[] = ['chute', 'trail', 'weapon', 'character', 'banner', 'emote']

/** "Up to 8 equipped" (owner, 2026-10-02): the wheel's segments. */
export const WHEEL_SLOTS = 8

/**
 * THE TABS ON SCREEN: "Show only real items ... A tab will only appear for
 * kinds that have real items, so players stop hitting buttons that don't work"
 * (#411's proposal, picked by the owner). Lua already sends Season 2 no
 * placeholder kinds; this is the page agreeing, so an empty kind can never be
 * a tab whatever arrives.
 *
 * THE DANCES' TAB EXISTS ONLY WHILE THE SEASON HAS EMOTES (#215, #388) -- the
 * `emotes` envelope, as on Season 1's screen -- even if a grid carrying them
 * lands first.
 */
export function tabsFor(items: readonly MarketItem[], emotesOn: boolean): TabKind[] {
  return TAB_ORDER.filter((k) => (k !== 'emote' || emotesOn) && items.some((i) => i.kind === k))
}

/** The tab drawn: the one picked while it still exists, else the first. A tab
 *  that goes away under the player (a season switch) never stays selected
 *  over an empty grid. Null only while there is nothing to show. */
export function shownTab(picked: TabKind | null, tabs: readonly TabKind[]): TabKind | null {
  if (picked !== null && tabs.includes(picked)) return picked
  return tabs[0] ?? null
}

/** The dances on the wheel. */
export const onWheel = (items: readonly MarketItem[]): number =>
  items.filter((i) => i.kind === 'emote' && typeof i.slot === 'number').length

/**
 * A PENDING SWAP THE GRID HAS OVERTAKEN IS DROPPED (#215, Season 1's rule). A
 * new grid can land between the two presses: once the dance waiting to come in
 * is on the wheel, or no longer owned, or the wheel has room again, every
 * "Replace" it would draw is a press that no longer means what it says.
 */
export function swapStale(swapFor: string | null, items: readonly MarketItem[]): boolean {
  if (swapFor === null) return false
  const pending = items.find((i) => i.id === swapFor)
  return onWheel(items) < WHEEL_SLOTS || !pending || pending.owned !== true || typeof pending.slot === 'number'
}

/** The card's one edge: "equipped first, then owned, then rarity" (#411). */
export type Edge = 'equipped' | 'owned' | 'rarity'
export function edgeOf(item: MarketItem): Edge {
  if (item.equipped === true) return 'equipped'
  if (item.owned === true) return 'owned'
  return 'rarity'
}

/**
 * A CARD'S ONE ACTION, Season 1's three states and the wheel's four (#215):
 *
 *   equipped  a fact, not a button -- every other kind has one slot
 *   equip     owned: put it on
 *   closed    a closed season's item: its owners still wear it; nobody buys it
 *   buy       the price; pressing it asks first (buyPress), and is refused
 *             with the error cue when the balance is short
 *
 * A DANCE IS ONE OF EIGHT, so equipped is a button there: Unequip, or Replace
 * while another dance waits to come in on a full wheel; an owned dance off the
 * wheel is Equip (on a full wheel, the first of the swap's two presses), and
 * Cancel while it is the one waiting -- the press that backs out of the swap.
 */
export type CardAction =
  | { do: 'equipped' }
  | { do: 'equip' }
  | { do: 'closed'; season: string | null }
  | { do: 'buy'; afford: boolean }
  | { do: 'replace' }
  | { do: 'unequip' }
  | { do: 'cancel' }
  | { do: 'equipDance'; swap: boolean }

export function cardAction(
  item: MarketItem, balance: number, swapFor: string | null, wheelFull: boolean,
): CardAction {
  const owned = item.owned === true
  const equipped = item.equipped === true
  if (item.kind === 'emote') {
    if (equipped && swapFor !== null && swapFor !== item.id) return { do: 'replace' }
    if (equipped) return { do: 'unequip' }
    if (owned && swapFor === item.id) return { do: 'cancel' }
    if (owned) return { do: 'equipDance', swap: wheelFull }
  } else if (equipped) {
    return { do: 'equipped' }
  } else if (owned) {
    return { do: 'equip' }
  }
  if (item.locked === true) return { do: 'closed', season: item.season ?? null }
  return { do: 'buy', afford: balance >= item.price }
}

/**
 * THE ONE PLACE A PRICE PRESS GOES (#411): "a dialog with the art, name,
 * price, Cancel and Buy. Today one stray click can spend 6,500 Volts." An
 * affordable price opens the confirm, and only the confirm's Buy sends
 * MARKET_BUY. A short balance is refused with the error cue, as on Season 1.
 */
export function buyPress(item: MarketItem, balance: number): 'confirm' | 'refuse' {
  return balance >= item.price ? 'confirm' : 'refuse'
}

/**
 * A CONFIRM THE GRID HAS OVERTAKEN CLOSES. The dialog reads the item from the
 * latest grid, not from the press: once the server says it is owned (a grant,
 * another session), its season has closed, it has left the grid, or the
 * balance can no longer cover it, Buy would ask for something the server will
 * refuse -- so the dialog goes rather than offer it.
 */
export function confirmStale(item: MarketItem | undefined, balance: number): boolean {
  return !item || item.owned === true || item.locked === true || balance < item.price
}

/** The card's art: Season 1's convention, `market/<id>.png`, copied verbatim by
 *  Vite; a missing file falls back to the monogram. */
export const artUrl = (id: string): string => `market/${id}.png`
export const monogram = (name: string): string => name.slice(0, 2).toUpperCase()
