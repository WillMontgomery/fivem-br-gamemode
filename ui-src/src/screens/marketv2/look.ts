import type { ButtonProps } from '@cloudscape-design/components/button'
import type { CSSProperties } from 'react'
import type { CardAction, Edge } from './model'

/**
 * THE SEASON 2 MARKET'S LOOK, IN ONE PLACE (#411).
 *
 * Owner, on the tabs: "yes some kind of tabs. I'm not married to any
 * particular type or style. We'll likely do a couple rounds of tuning." So
 * every color, size and inset the screen draws with is set here and nowhere
 * else, and a tuning round is an edit to this file (the three tab designs are
 * market.css's `.mk2-tabs--*`, which has no other job). What every Cloudscape
 * screen shares (the fonts, the panel, the cyan, the radii) is the one theme,
 * ui/cloudscape/theme.ts; this is only what is the Market's own, in Season 1's
 * colors.
 *
 * CORNERS ARE CUT WHERE THEY ARE TODAY: "let's keep 'em cut where they are
 * today" (owner). On Season 1 only `.plate.is-active` is cut -- the selected
 * tab -- and everything else is square. Lengths are in em, because inside the
 * Cloudscape island an em is a rem on screen (LockerV2.tsx).
 *
 * Every color a hex, an rgba or one of index.css's tokens: CEF 103 has no
 * oklch or color-mix (scripts/check-css.mjs).
 */

export const CYAN = 'var(--color-royale-accent)'
const GOLD = 'var(--color-royale-accent2)'
const GREEN = 'var(--color-hp)'
const QUIET = 'rgba(255, 255, 255, 0.16)'
const OFF = 'rgba(255, 255, 255, 0.35)'
const FILL = 'rgba(24, 28, 40, 0.94)'
const LIT = 'rgba(12, 58, 72, 0.94)'

// ═══ THE PANEL ═══

/**
 * THE PANEL AND ITS SCRIM. Owner, 2026-10-14: "the black gradient background
 * on the market is too opaque and goes too right, kinda obstructs the view of
 * the ped". The scrim is now measured from the panel, not the screen: it is as
 * wide as the panel plus FADE, so it ends a short way past the cards wherever
 * the panel stops (a narrow screen, a large interface size), and it is lighter
 * throughout. The cards keep their own near-opaque fill, so they read the same
 * over a lighter scrim.
 *
 * AND IT NEVER REACHES THE CHARACTER (review, 2026-10-14: at 4:3 with a large
 * interface size the fade still ran over its left side). PED_CLEAR is where
 * the scrim must end, on any screen: br_lib/config/match.lua's lobbyCam --
 * 1.83 m back, aimed 0.58 m to the ped's left, a 50-degree vertical lens --
 * puts the character's shoulder (0.26 m in from its middle) 18.8vh right of
 * the screen's middle, and PED_CLEAR stops a little short of that. In vh
 * because the lens is vertical: a narrower screen brings the character nearer
 * the panel in vw, never in vh. The cards themselves end 3rem inside the
 * panel, short of it on every screen from 5:4 out (test-marketv2.mjs).
 */
export const PANEL_W = 'min(48rem, 64vw)'
export const FADE = '6rem'
export const PED_CLEAR = 'calc(50vw + 16vh)'
export const SCRIM: CSSProperties = {
  width: `min(calc(${PANEL_W} + ${FADE}), ${PED_CLEAR})`,
  background: 'linear-gradient(90deg, rgba(6, 8, 14, 0.80) 0%, '
            + `rgba(6, 8, 14, 0.62) calc(100% - ${FADE} - 6rem), rgba(6, 8, 14, 0) 100%)`,
}

/**
 * THE GUTTER: "please put in some change to ensure the borders always draw
 * around everything which should have a border" (owner, 2026-10-14). The
 * cards' right borders were cut by the grid's scrolling region, whose edge they
 * sat on: a box that clips (overflow other than visible) cuts a border lying on
 * its edge as soon as the zoom puts that edge between two pixels. So nothing
 * bordered in this screen sits on a clipping edge: the one region that clips,
 * the grid's, is inset GUTTER on every side, and every other row is inset the
 * same so their edges stay in line with the cards'. The island itself does not
 * clip. GUTTER is more than the widest border (1px) at the smallest em (11px
 * root x 0.8 interface size).
 */
export const GUTTER = '0.3em'

/**
 * THE GRID: as many columns as fit at CARD_MIN, four at most (the panel's
 * width), fewer on a narrow screen or a large interface size -- "text wrapping
 * should not be allowed. if you can't fit the text, don't draw it" (owner, on
 * My Looks, 2026-10-14; the Market's prices and Equip wrapped at narrow
 * widths). CARD_MIN is the widest label a card carries ("Unequip", "Preview",
 * a closed season's line) with the card's own padding round it.
 */
export const CARD_MIN = '9.5em'
export const GAP = '0.75em'
export const GRID: CSSProperties = {
  display: 'grid',
  gridTemplateColumns: `repeat(auto-fill, minmax(${CARD_MIN}, 1fr))`,
  gap: GAP,
}

/** Every label in the Market stays on one line (see GRID). */
export const ONE_LINE: CSSProperties = { whiteSpace: 'nowrap' }

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
    ['--plate-fill' as string]: FILL,
    ['--cut-max' as string]: '0.6em',
  }
}

/** The color each card action speaks in -- Season 1's, action for action. */
export function actionColor(a: CardAction): string {
  switch (a.do) {
    case 'buy': return a.afford ? GOLD : OFF
    case 'unequip': return CYAN
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
      paddingInline: '0.6em',
    },
  }
}

/**
 * THE PREVIEW BUTTON (#411): quiet until it plays, lit while the lobby
 * character dances it, and spent -- no edge, no ink to speak of, no hover --
 * on a dance the player neither owns nor can pay for.
 */
export function previewStyle(playing: boolean): ButtonProps.Style {
  const ink = playing ? CYAN : 'rgba(255, 255, 255, 0.82)'
  const edge = playing ? CYAN : QUIET
  const fill = playing ? LIT : 'rgba(30, 34, 48, 0.94)'
  return {
    root: {
      background: { default: fill, hover: fill, active: fill, disabled: 'rgba(30, 34, 48, 0.6)' },
      borderColor: { default: edge, hover: edge, active: edge, disabled: 'rgba(255, 255, 255, 0.08)' },
      color: { default: ink, hover: ink, active: ink, disabled: OFF },
      borderRadius: '0',
      borderWidth: '1px',
      paddingInline: '0.6em',
    },
  }
}

/** The balance readout: Season 1's, a square plate edged in gold. */
export const BALANCE_PLATE: CSSProperties = {
  ['--edgec' as string]: GOLD,
  ['--plate-fill' as string]: FILL,
  ['--cut-max' as string]: '0.45em',
}
export const GOLD_INK = GOLD

/** The wheel's count plate: gold once all eight are taken. */
export function wheelPlate(full: boolean): CSSProperties {
  return {
    ['--edgec' as string]: full ? GOLD : QUIET,
    ['--plate-fill' as string]: FILL,
  }
}
