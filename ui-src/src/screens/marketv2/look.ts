import type { BadgeProps } from '@cloudscape-design/components/badge'
import type { ButtonProps } from '@cloudscape-design/components/button'
import type { TabsProps } from '@cloudscape-design/components/tabs'
import type { CSSProperties } from 'react'
import type { CardAction, Edge } from './model'

/**
 * THE SEASON 2 MARKET'S LOOK, IN ONE PLACE (#411).
 *
 * Owner, on the tabs: "yes some kind of tabs. I'm not married to any
 * particular type or style. We'll likely do a couple rounds of tuning." So
 * every state of a tab -- and of the cards, their buttons and the New badge --
 * is set here and nowhere else, and a tuning round is an edit to this file.
 * What every Cloudscape screen shares (the fonts, the panel, the cyan, the
 * radii) is the one theme, ui/cloudscape/theme.ts; this is only what is the
 * Market's own, in Season 1's colors.
 *
 * CORNERS ARE CUT WHERE THEY ARE TODAY: "let's keep 'em cut where they are
 * today" (owner). On Season 1 only `.plate.is-active` is cut -- the selected
 * tab, and an emote swap's Cancel -- and everything else is square. The cut is
 * the lobby's own (index.css's `.plate` and its clip-path), worn by a wrapper:
 * the selected tab's label, and the span around Cancel. Lengths are in em,
 * because inside the Cloudscape island an em is a rem on screen (LockerV2.tsx).
 *
 * Every color a hex, an rgba or one of index.css's tokens: CEF 103 has no
 * oklch or color-mix (scripts/check-css.mjs).
 */

const CYAN = 'var(--color-royale-accent)'
const GOLD = 'var(--color-royale-accent2)'
const GREEN = 'var(--color-hp)'
const QUIET = 'rgba(255, 255, 255, 0.16)'
const OFF = 'rgba(255, 255, 255, 0.35)'

// ═══ THE TABS ═══

/**
 * Cloudscape's own tab chrome, stood down: the plate in the label carries the
 * look (tabPlate below), so the trigger is transparent, unpadded and has no
 * underline or separators. Cloudscape keeps what it is for -- the tablist, the
 * arrow keys, the focus ring, the overflow scroll.
 */
export const TABS_STYLE: TabsProps.Style = {
  tab: {
    backgroundColor: { default: 'transparent', hover: 'transparent', active: 'transparent', disabled: 'transparent' },
    borderColor: { default: 'transparent', hover: 'transparent', active: 'transparent', disabled: 'transparent' },
    borderWidth: '0',
    color: { default: 'rgba(255, 255, 255, 0.70)', hover: '#ffffff', active: '#ffffff', disabled: OFF },
    paddingBlock: '0',
    paddingInline: '0',
    activeIndicator: { color: 'transparent', width: '0' },
    focusRing: { borderColor: CYAN, borderRadius: '0', borderWidth: '2px' },
  },
  tabSeparator: { color: 'transparent', width: '0' },
}

/** A tab's label plate: Season 1's tab, square at rest, cut when selected. */
export function tabPlate(active: boolean): CSSProperties {
  return {
    ['--edgec' as string]: active ? CYAN : QUIET,
    ['--plate-fill' as string]: active ? 'rgba(12, 58, 72, 0.94)' : 'rgba(24, 28, 40, 0.92)',
    ['--cut-max' as string]: '0.45em',
    display: 'inline-block',
    padding: '0.5em 1em',
    fontSize: '0.8em',
    letterSpacing: '0.12em',
    lineHeight: 1.2,
  }
}

// ═══ THE CARDS ═══

/** "The card edge still shows equipped first, then owned, then rarity." */
export function edgeColor(edge: Edge, rarity: number | undefined): string {
  if (edge === 'equipped') return CYAN
  if (edge === 'owned') return GREEN
  return `var(--rarity-${rarity ?? 1})`
}

/** A card: a square plate, Season 1's fill. */
export function cardPlate(edge: string): CSSProperties {
  return {
    ['--edgec' as string]: edge,
    ['--plate-fill' as string]: 'rgba(24, 28, 40, 0.94)',
    ['--cut-max' as string]: '0.6em',
  }
}

/** The color each card action speaks in -- Season 1's, action for action. */
export function actionColor(a: CardAction): string {
  switch (a.do) {
    case 'buy': return a.afford ? GOLD : OFF
    case 'replace': return GOLD
    case 'unequip': return CYAN
    case 'cancel': return 'rgba(255, 255, 255, 0.6)'
    case 'equip':
    case 'equipDance': return GREEN
    case 'equipped': return CYAN
    case 'closed': return OFF
  }
}

/** A card's button, in its action's color: an edge and ink, the fill dark. */
export function actionStyle(color: string): ButtonProps.Style {
  return {
    root: {
      background: { default: 'rgba(30, 34, 48, 0.94)', hover: 'rgba(30, 34, 48, 0.94)', active: 'rgba(30, 34, 48, 0.94)' },
      borderColor: { default: color, hover: color, active: color },
      color: { default: color, hover: color, active: color },
      borderRadius: '0',
      borderWidth: '1px',
    },
  }
}

/**
 * The cut around the emote swap's Cancel: the lobby's plate, worn by the span
 * around the button so its clip-path cuts the button's corners and its two
 * diagonals redraw the cut edge in the button's color. The span itself draws
 * no fill and no border of its own.
 */
export function cutWrap(color: string): CSSProperties {
  return {
    ['--edgec' as string]: color,
    ['--cut-max' as string]: '0.35em',
    display: 'block',
    background: 'none',
    borderWidth: 0,
  }
}

/** The New badge (#411). */
export const NEW_BADGE: BadgeProps.Style = {
  root: {
    background: GOLD,
    borderColor: GOLD,
    borderRadius: '0',
    color: '#1a1204',
    paddingInline: '0.5em',
  },
}

/** The balance readout: Season 1's, a square plate edged in gold. */
export const BALANCE_PLATE: CSSProperties = {
  ['--edgec' as string]: GOLD,
  ['--plate-fill' as string]: 'rgba(24, 28, 40, 0.94)',
  ['--cut-max' as string]: '0.45em',
}
export const GOLD_INK = GOLD
export const WHEEL_EDGE = (full: boolean): string => (full ? GOLD : QUIET)
