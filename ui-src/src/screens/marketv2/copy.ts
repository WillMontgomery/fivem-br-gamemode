/**
 * EVERY WORD THE SEASON 2 MARKET PUTS ON SCREEN (#411), and nowhere else.
 *
 * Three kinds, marked line by line:
 *
 *   SEASON 1  today's label on screens/Market.tsx, kept word for word.
 *   OWNER     the owner's own words, verbatim (#411, 2026-10-14).
 *   WRITTEN   a proposal for the owner. Each one carries
 *             `// WRITTEN (proposal for the owner)` and is listed in the
 *             build's report so he meets every one before a player does. The
 *             walkthrough's Season 2 line is in tutorial/steps.ts, with the
 *             rest of the walkthrough's words.
 *
 * No runtime imports, so scripts/test-marketv2.mjs loads this file directly and
 * holds every line to its marker.
 */

import type { Kind, TabKind } from './model'

export const TITLE = 'Market' // SEASON 1: today's label

export const TAB_LABEL: Record<TabKind, string> = {
  chute: 'Canopies',           // SEASON 1: today's label
  trail: 'Smoke trails',       // OWNER: "nobody knows what "trails" means - change it to "smoke trails""
  weapon: 'Weapon finishes',   // OWNER: "same for "weapon finishes""
  character: 'Characters',     // SEASON 1: today's label
  banner: 'Banners',           // SEASON 1: today's label
  emote: 'Emotes',             // SEASON 1: today's label
}

export const BTN = {
  done: 'Done',           // SEASON 1: today's label
  equip: 'Equip',         // SEASON 1: today's label
  unequip: 'Unequip',     // SEASON 1: today's label
  replace: 'Replace',     // SEASON 1: today's label
  cancelSwap: 'Cancel',   // SEASON 1: today's label (the emote swap's)
  cancel: 'Cancel',       // WRITTEN (proposal for the owner): the confirm's way out
  buy: 'Buy',             // WRITTEN (proposal for the owner): the confirm's Buy
  preview: 'Preview',     // OWNER: "let's have a way for them to preview the emote"
} as const

export const EQUIPPED = 'Equipped' // SEASON 1: today's label
/** The wheel's count plate: "Equipped" and "8/8". */
export const WHEEL_LABEL = 'Equipped' // OWNER: ""on wheel" ... let's show it as - "equipped""
export const NOT_FOR_SALE = 'Not for sale' // SEASON 1: today's label
export const closedLabel = (season: string): string => `${season} — closed` // SEASON 1: today's label

/** The buy confirm (#411, owner 2026-10-14): ""buy" prompts should have a title
 *  of "Are you sure?" and content with no photo and just "Buy [name] canopy for
 *  [amount] Volts?" etc." */
export const CONFIRM_TITLE = 'Are you sure?' // OWNER: verbatim

/** What one of a kind is called in a sentence. Canopy is the owner's; smoke
 *  trail and weapon finish are his tab names; the rest follow them. */
export const KIND_NOUN: Record<Exclude<Kind, 'verdict'>, string> = {
  chute: 'canopy',            // OWNER: "Buy [name] canopy for [amount] Volts?"
  trail: 'smoke trail',       // OWNER: his "smoke trails"
  weapon: 'weapon finish',    // OWNER: his "weapon finishes"
  emote: 'emote',             // WRITTEN (proposal for the owner)
  character: 'character',     // WRITTEN (proposal for the owner)
  banner: 'banner',           // WRITTEN (proposal for the owner)
}

/** A price as the screen writes it: 1,200 -- a comma every three digits,
 *  whatever the machine's locale says. */
export const amount = (n: number): string => n.toLocaleString('en-US')

/** "Buy Crimson canopy for 1,200 Volts?" -- the owner's format, every kind. */
export const confirmBody = (name: string, kind: Kind, price: number, currency: string): string =>
  `Buy ${name} ${kind === 'verdict' ? '' : `${KIND_NOUN[kind]} `}for ${amount(price)} ${currency}?` // OWNER: his format

/** The replace dialog's title (#411): Equip on a full wheel opens it, and its
 *  rows are the eight dances on the wheel, each with Replace, then Cancel. */
export const REPLACE_TITLE = 'Replace which emote?' // WRITTEN (proposal for the owner)
