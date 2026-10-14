/**
 * EVERY WORD THE SEASON 2 MARKET PUTS ON SCREEN (#411), and nowhere else.
 *
 * Two kinds, marked line by line:
 *
 *   SEASON 1  today's label on screens/Market.tsx, kept word for word.
 *   WRITTEN   a proposal for the owner (#411 asked for the confirm's words and
 *             "New"). Each one carries `// WRITTEN (proposal for the owner)`
 *             and is listed in the build's report so he meets every one before
 *             a player does. The walkthrough's Season 2 line is in
 *             tutorial/steps.ts, with the rest of the walkthrough's words.
 *
 * No runtime imports, so scripts/test-marketv2.mjs loads this file directly and
 * holds every WRITTEN line to its marker.
 */

import type { TabKind } from './model'

export const TITLE = 'Market' // SEASON 1: today's label

export const TAB_LABEL: Record<TabKind, string> = {
  chute: 'Canopies',      // SEASON 1: today's label
  trail: 'Trails',        // SEASON 1: today's label
  weapon: 'Finishes',     // SEASON 1: today's label
  character: 'Characters', // SEASON 1: today's label
  banner: 'Banners',      // SEASON 1: today's label
  emote: 'Emotes',        // SEASON 1: today's label
}

export const BTN = {
  done: 'Done',           // SEASON 1: today's label
  equip: 'Equip',         // SEASON 1: today's label
  unequip: 'Unequip',     // SEASON 1: today's label
  replace: 'Replace',     // SEASON 1: today's label
  cancelSwap: 'Cancel',   // SEASON 1: today's label (the emote swap's)
  cancel: 'Cancel',       // WRITTEN (proposal for the owner): the confirm's way out
  buy: 'Buy',             // WRITTEN (proposal for the owner): the confirm's Buy
} as const

export const EQUIPPED = 'Equipped' // SEASON 1: today's label
export const ON_WHEEL = 'On wheel' // SEASON 1: today's label
export const NOT_FOR_SALE = 'Not for sale' // SEASON 1: today's label
export const closedLabel = (season: string): string => `${season} — closed` // SEASON 1: today's label

/** The badge on this season's items: "A 'New' badge on this season's items, so
 *  new cards stand out after an update" (#411). */
export const NEW = 'New' // WRITTEN (proposal for the owner)

/** The buy confirm's title. Its body is the item itself -- the art, the name
 *  and the price -- and no sentence. */
export const confirmTitle = (name: string): string => `Buy ${name}?` // WRITTEN (proposal for the owner)
