import type { Theme } from '@cloudscape-design/components/theming'

/**
 * CLOUDSCAPE, IN THE LOBBY'S CLOTHES (#28): "we need to tune the visual look
 * to our buttons to match the rest of our lobby UI. Same for the other
 * elements of Cloudscape that we're using - colors, click animations, and
 * gradients aren't quite right. And corners - remember our Lobby UI has no
 * rounded edges." (owner, 2026-10-13)
 *
 * WHAT THE TOKENS CAN DO, THEY DO HERE: the lobby's colors, taken from its own
 * buttons (ui/Btn.tsx's VARIANT and index.css's `.plate`), and every radius
 * Cloudscape lets a theme set at 0 -- test-lockerv2.mjs reads the installed
 * Cloudscape's token list and fails if one is missing or not 0px. What tokens
 * cannot do -- the plates' gradient, Anton in capitals, the press travel, the
 * corners Cloudscape draws without a token -- is lockerv2.css.
 *
 * HOVER IS NOT A NEW COLOR. A lobby button brightens under the mouse (a
 * filter, lockerv2.css) and keeps its colors, so each hover and active token
 * is its default's. Every color is a hex or an rgba, because CEF 103 drops
 * oklch and color-mix outright (scripts/check-css.mjs).
 *
 * DARK ONLY. applyMode(Dark) is on <body> while the locker is up, so these are
 * the dark values; the theme and the mode both come off again as it closes.
 */

const BG = '#0b0c12'
const PANEL = '#1d1e2b'
const EDGE = '#33354a'
const CYAN = '#22d3ee'
const CYAN_EDGE = '#67e8f9'
const INK = '#04222a'
const TEXT = '#ffffff'
const DIM = 'rgba(255, 255, 255, 0.58)'
const BODY = 'rgba(255, 255, 255, 0.70)'
/** ui/Btn.tsx's `default` plate and edge. */
const PLATE = 'rgba(32, 36, 50, 0.94)'
const PLATE_EDGE = 'rgba(255, 255, 255, 0.30)'
/** index.css's `.plate` fill: what a list line, a card or a tile rests on. */
const PLATE_DARK = 'rgba(12, 14, 22, 0.97)'
const SELECTED = 'rgba(12, 58, 72, 0.94)'

/** Every radius token the installed Cloudscape has, at 0. */
const SQUARE = {
  borderRadiusActionCardDefault: '0px',
  borderRadiusActionCardEmbedded: '0px',
  borderRadiusAlert: '0px',
  borderRadiusBadge: '0px',
  borderRadiusButton: '0px',
  borderRadiusCalendarDayFocusRing: '0px',
  borderRadiusCardDefault: '0px',
  borderRadiusCardEmbedded: '0px',
  borderRadiusChatBubble: '0px',
  borderRadiusContainer: '0px',
  borderRadiusControlCircularFocusRing: '0px',
  borderRadiusControlDefaultFocusRing: '0px',
  borderRadiusDialog: '0px',
  borderRadiusDropdown: '0px',
  borderRadiusDropzone: '0px',
  borderRadiusFlashbar: '0px',
  borderRadiusInput: '0px',
  borderRadiusItem: '0px',
  borderRadiusPopover: '0px',
  borderRadiusSideNavigationItem: '0px',
  borderRadiusSideNavigationItemCollapsed: '0px',
  borderRadiusStatusIndicator: '0px',
  borderRadiusSupportPrompt: '0px',
  borderRadiusTabsFocusRing: '0px',
  borderRadiusTiles: '0px',
  borderRadiusToken: '0px',
  borderRadiusTokenInline: '0px',
  borderRadiusTutorialPanelItem: '0px',
} as const

export const LOCKER_THEME: Theme = {
  tokens: {
    fontFamilyBase: "'Barlow', 'Segoe UI', system-ui, sans-serif",
    fontFamilyHeading: "'Anton', 'Segoe UI', system-ui, sans-serif",
    fontFamilyDisplay: "'Anton', 'Segoe UI', system-ui, sans-serif",

    ...SQUARE,
    // The lobby's plates have a one-pixel edge.
    borderWidthButton: '1px',

    // Surfaces.
    colorBackgroundContainerContent: PANEL,
    colorBackgroundContainerHeader: PANEL,
    colorBackgroundCard: PLATE_DARK,
    colorBackgroundDialog: PANEL,
    colorBackgroundPopover: PANEL,
    colorBackgroundDropdownItemDefault: PANEL,
    colorBackgroundDropdownItemHover: '#26283a',
    colorBackgroundDropdownItemSelected: SELECTED,
    colorBackgroundInputDefault: BG,
    colorBackgroundItemSelected: SELECTED,
    colorBackgroundBackdrop: 'rgba(6, 8, 14, 0.72)',

    // Edges.
    colorBorderDividerDefault: EDGE,
    colorBorderDividerSecondary: EDGE,
    colorBorderCard: EDGE,
    colorBorderContainerTop: EDGE,
    colorBorderDialog: EDGE,
    colorBorderPopover: EDGE,
    colorBorderDropdownContainer: EDGE,
    colorBorderDropdownItemFocused: CYAN,
    colorBorderInputDefault: PLATE_EDGE,
    colorBorderInputFocused: CYAN,
    colorBorderItemFocused: CYAN,
    colorBorderItemSelected: CYAN,
    colorBorderControlDefault: PLATE_EDGE,

    // The primary button: the lobby's Ready up -- cyan, its lighter edge, the
    // ink on it, in every state.
    colorBackgroundButtonPrimaryDefault: CYAN,
    colorBackgroundButtonPrimaryHover: CYAN,
    colorBackgroundButtonPrimaryActive: CYAN,
    colorBackgroundButtonPrimaryDisabled: CYAN,
    colorBorderButtonPrimaryDefault: CYAN_EDGE,
    colorBorderButtonPrimaryHover: CYAN_EDGE,
    colorBorderButtonPrimaryActive: CYAN_EDGE,
    colorBorderButtonPrimaryDisabled: CYAN_EDGE,
    colorTextButtonPrimaryDefault: INK,
    colorTextButtonPrimaryHover: INK,
    colorTextButtonPrimaryActive: INK,
    colorTextButtonPrimaryDisabled: INK,

    // The normal button: the lobby's Locker, Market and Settings plates. A
    // disabled one is the same plate at the lobby's 40% (lockerv2.css).
    colorBackgroundButtonNormalDefault: PLATE,
    colorBackgroundButtonNormalHover: PLATE,
    colorBackgroundButtonNormalActive: PLATE,
    colorBackgroundButtonNormalDisabled: PLATE,
    colorBorderButtonNormalDefault: PLATE_EDGE,
    colorBorderButtonNormalHover: PLATE_EDGE,
    colorBorderButtonNormalActive: PLATE_EDGE,
    colorBorderButtonNormalDisabled: PLATE_EDGE,
    colorTextButtonNormalDefault: TEXT,
    colorTextButtonNormalHover: TEXT,
    colorTextButtonNormalActive: TEXT,
    colorTextButtonNormalDisabled: TEXT,
    colorTextButtonIconDisabled: DIM,
    colorTextButtonIconHover: CYAN,

    // Toggles, sliders, radios.
    colorBackgroundSliderRangeDefault: CYAN,
    colorBackgroundSliderRangeActive: CYAN_EDGE,
    colorBackgroundSliderHandleDefault: CYAN,
    colorBackgroundSliderHandleActive: CYAN_EDGE,
    colorBackgroundSliderTrackDefault: EDGE,
    colorBackgroundControlChecked: CYAN,
    colorBackgroundControlDefault: BG,
    colorBackgroundToggleDefault: EDGE,

    // Ink.
    colorTextBodyDefault: TEXT,
    colorTextBodySecondary: BODY,
    colorTextHeadingDefault: TEXT,
    colorTextHeadingSecondary: DIM,
    colorTextFormDefault: TEXT,
    colorTextLabel: BODY,
    colorTextAccent: CYAN,
    colorTextLinkDefault: CYAN,
    colorTextLinkHover: CYAN_EDGE,
    colorTextInteractiveDefault: BODY,
    colorTextInteractiveHover: CYAN,
    colorTextInteractiveActive: CYAN,
    colorTextDropdownItemDefault: TEXT,
    colorTextDropdownItemHighlighted: CYAN,
    colorTextGroupLabel: DIM,
  },
}

/*
 * ONE THEME, SHARED (#411). It moved here from screens/lockerv2/ because the
 * Season 2 Market wears it too: both screens put it on through
 * screens/lockerv2/scope.ts's useCloudscapeScope, and nothing else applies a
 * Cloudscape theme. The My Looks retheme (#28: radius 0, our colors, the
 * gradients, the click animation) lands in this file, once, for both screens.
 * What is the Market's alone -- its tabs, cards and badge -- is
 * screens/marketv2/look.ts.
 */
