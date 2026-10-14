/**
 * THE SEASON 2 MARKET'S DECISIONS (#411), with nothing to render and no
 * runtime imports.
 *
 * Every rule the page applies before it draws -- which tabs exist, which tab is
 * shown and in which design, what a card's edge and its one action are, when a
 * press asks to buy, what a full wheel offers to replace, which dance may be
 * previewed, and when a dialog that is up no longer means what it says --
 * lives here, so scripts/test-marketv2.mjs can load this file with node's type
 * stripping and hold each rule to the owner's words. MarketV2.tsx asks; it
 * never decides.
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

/**
 * THE TAB DESIGNS (#411, owner 2026-10-14: "i also don't know if I like the
 * current tab designs") -- three, each in the lobby's square-and-cut language,
 * and one switch to compare them: `?tabs=` in the browser harness and
 * `brmarkettabs` on a dev box (br_ui/client/market.lua), by name or by number.
 *
 *   bar     one joined strip; the selected segment is the lit plate, cut
 *   rail    bare words on a hairline; a cut cyan blade under the selected one
 *   folder  index tabs on a cyan line; the selected one opens into the grid
 *           below it, its top corner cut
 *
 * `bar` is the default: it reads as one control at a glance, it is the lobby's
 * own plate, and its segments share the panel's width, so the row ends where
 * the grid does.
 */
export const TAB_DESIGNS = ['bar', 'rail', 'folder'] as const
export type TabDesign = typeof TAB_DESIGNS[number]
export const DEFAULT_TAB_DESIGN: TabDesign = 'bar'

/** The design asked for -- a name, or its number from 1 -- else the default. */
export function tabDesign(asked: string | null | undefined): TabDesign {
  const a = String(asked ?? '').trim().toLowerCase()
  const byName = TAB_DESIGNS.find((d) => d === a)
  if (byName) return byName
  const n = a === '' ? NaN : Number(a)
  return (Number.isInteger(n) ? TAB_DESIGNS[n - 1] : undefined) ?? DEFAULT_TAB_DESIGN
}

/** The dances on the wheel. */
export const onWheel = (items: readonly MarketItem[]): number =>
  items.filter((i) => i.kind === 'emote' && typeof i.slot === 'number').length

/** The wheel's count, "8/8", as the owner wrote it (2026-10-14). */
export const wheelCount = (items: readonly MarketItem[]): string => `${onWheel(items)}/${WHEEL_SLOTS}`

/**
 * THE REPLACE DIALOG'S ROWS (#411, owner 2026-10-14: "the flow of replacing an
 * emote on the wheel is... really unintuitive. I have nothing telling me what
 * to do."). Equip on a full wheel opens a dialog that lists the dances on it,
 * each with its own Replace, in wheel order -- segment 1 first.
 */
export function replaceChoices(items: readonly MarketItem[]): MarketItem[] {
  return items
    .filter((i) => i.kind === 'emote' && typeof i.slot === 'number')
    .sort((a, b) => (a.slot ?? 0) - (b.slot ?? 0))
}

/**
 * A REPLACE THE GRID HAS OVERTAKEN CLOSES (#215, Season 1's rule). A new grid
 * can land while the dialog is up: once the dance waiting to come in is on
 * the wheel, or no longer owned, or the wheel has room again, every Replace
 * it offers is a press that no longer means what it says. So does a season
 * that closes the dances (`emotesOn` off): their tab is gone, and a dialog
 * left up would come back with them.
 */
export function swapStale(swapFor: string | null, items: readonly MarketItem[], emotesOn: boolean): boolean {
  if (swapFor === null) return false
  if (!emotesOn) return true
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
 * A CARD'S ONE ACTION, Season 1's three states and the wheel's two (#215):
 *
 *   equipped  a fact, not a button -- every other kind has one slot
 *   equip     owned: put it on
 *   closed    a closed season's item: its owners still wear it; nobody buys it
 *   buy       the price; pressing it asks first (buyPress), and is refused
 *             with the error cue when the balance is short
 *
 * A DANCE IS ONE OF EIGHT, so equipped is a button there: Unequip. An owned
 * dance off the wheel is Equip, and on a full wheel (`swap`) that press opens
 * the replace dialog (replaceChoices) -- not, as on Season 1, the first of two
 * presses on two different cards, which is the flow the owner could not find
 * his way through.
 */
export type CardAction =
  | { do: 'equipped' }
  | { do: 'equip' }
  | { do: 'closed'; season: string | null }
  | { do: 'buy'; afford: boolean }
  | { do: 'unequip' }
  | { do: 'equipDance'; swap: boolean }

export function cardAction(item: MarketItem, balance: number, wheelFull: boolean): CardAction {
  const owned = item.owned === true
  const equipped = item.equipped === true
  if (item.kind === 'emote') {
    if (equipped) return { do: 'unequip' }
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
 * THE ONE PLACE A PRICE PRESS GOES (#411): "Today one stray click can spend
 * 6,500 Volts." An affordable price opens the confirm, and only the confirm's
 * Buy sends MARKET_BUY. A short balance is refused with the error cue, as on
 * Season 1.
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

/**
 * THE CONFIRM ON SCREEN: the item a price press asked about, read from the
 * latest grid -- or null, when nothing was asked about or the grid has
 * overtaken it (confirmStale). Never a stale one, not even for the one render
 * before the press is forgotten.
 */
export function confirmShown(
  confirmId: string | null, items: readonly MarketItem[], balance: number,
): MarketItem | null {
  if (confirmId === null) return null
  const item = items.find((i) => i.id === confirmId)
  return item === undefined || confirmStale(item, balance) ? null : item
}

/**
 * MAY THIS DANCE PLAY ON THE LOBBY CHARACTER? (#411, owner 2026-10-14: "let's
 * have a way for them to preview the emote while in market, but shouldn't work
 * if they can't afford it".) One the player owns, or one on sale they can pay
 * for now. br_ui/client/market.lua asks the same of its own copy of the grid
 * and refuses the rest, so a page that disagreed would still play nothing.
 */
export function canPreview(item: MarketItem, balance: number): boolean {
  if (item.kind !== 'emote') return false
  if (item.owned === true) return true
  return item.locked !== true && balance >= item.price
}

/**
 * THE PREVIEW PLAYING: the dance a Preview press asked for, while the dances'
 * tab is the one shown and the latest grid still allows it (canPreview) -- or
 * null. MarketV2.tsx sends MARKET_PREVIEW each time this changes, so every way
 * a preview ends (its own press again, another dance's, a tab change, a grid
 * that took it away) is the same one message.
 */
export function previewShown(
  previewId: string | null, tab: TabKind | null, items: readonly MarketItem[], balance: number,
): string | null {
  if (previewId === null || tab !== 'emote') return null
  const item = items.find((i) => i.id === previewId)
  return item !== undefined && canPreview(item, balance) ? item.id : null
}

/** The card's art: Season 1's convention, `market/<id>.png`, copied verbatim by
 *  Vite; a missing file falls back to the monogram. A dance has none: "emotes
 *  shouldn't really have a thumbnail" (owner, 2026-10-14). */
export const artUrl = (id: string): string => `market/${id}.png`
export const monogram = (name: string): string => name.slice(0, 2).toUpperCase()
export const hasArt = (item: MarketItem): boolean => item.kind !== 'emote'
