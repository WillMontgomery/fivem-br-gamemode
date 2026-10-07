import type { Theme } from '@cloudscape-design/components/theming'

/**
 * CLOUDSCAPE, IN OUR CLOTHES (#28): "Can we use Cloudscape components for the
 * ped picker, just styled to match our style?" (owner).
 *
 * The contract's five values (section 5) and nothing invented around them:
 * Barlow, the panel #1d1e2b, its edge #33354a, the cyan #22d3ee, and #04222a,
 * the ink that sits on cyan. Every color is a hex or an rgba, because CEF 103
 * drops oklch and color-mix outright (scripts/check-css.mjs).
 *
 * DARK ONLY. applyMode(Dark) is on <body> while the locker is up, so these are
 * the dark values; the theme and the mode both come off again as it closes.
 */

const PANEL = '#1d1e2b'
const EDGE = '#33354a'
const CYAN = '#22d3ee'
const INK = '#04222a'
const BG = '#0b0c12'
const TEXT = '#ffffff'
const DIM = 'rgba(255, 255, 255, 0.58)'
const BODY = 'rgba(255, 255, 255, 0.70)'

export const LOCKER_THEME: Theme = {
  tokens: {
    fontFamilyBase: "'Barlow', 'Segoe UI', system-ui, sans-serif",
    fontFamilyHeading: "'Barlow', 'Segoe UI', system-ui, sans-serif",
    fontFamilyDisplay: "'Barlow', 'Segoe UI', system-ui, sans-serif",

    // Surfaces.
    colorBackgroundContainerContent: PANEL,
    colorBackgroundContainerHeader: PANEL,
    colorBackgroundCard: PANEL,
    colorBackgroundDialog: PANEL,
    colorBackgroundPopover: PANEL,
    colorBackgroundDropdownItemDefault: PANEL,
    colorBackgroundDropdownItemHover: '#26283a',
    colorBackgroundInputDefault: BG,
    colorBackgroundItemSelected: 'rgba(12, 58, 72, 0.94)',
    colorBackgroundBackdrop: 'rgba(6, 8, 14, 0.72)',

    // Edges.
    colorBorderDividerDefault: EDGE,
    colorBorderDividerSecondary: EDGE,
    colorBorderCard: EDGE,
    colorBorderContainerTop: EDGE,
    colorBorderDialog: EDGE,
    colorBorderPopover: EDGE,
    colorBorderDropdownContainer: EDGE,
    colorBorderInputDefault: EDGE,
    colorBorderInputFocused: CYAN,
    colorBorderItemFocused: CYAN,
    colorBorderItemSelected: CYAN,
    colorBorderControlDefault: EDGE,

    // The primary button: cyan, with the ink on it.
    colorBackgroundButtonPrimaryDefault: CYAN,
    colorBackgroundButtonPrimaryHover: '#67e8f9',
    colorBackgroundButtonPrimaryActive: '#06b6d4',
    colorBorderButtonPrimaryDefault: CYAN,
    colorBorderButtonPrimaryHover: '#67e8f9',
    colorBorderButtonPrimaryActive: '#06b6d4',
    colorTextButtonPrimaryDefault: INK,
    colorTextButtonPrimaryHover: INK,
    colorTextButtonPrimaryActive: INK,

    // The normal button: a plate with a cyan edge, as the market's are.
    colorBackgroundButtonNormalDefault: 'rgba(24, 28, 40, 0.92)',
    colorBackgroundButtonNormalHover: 'rgba(12, 58, 72, 0.94)',
    colorBackgroundButtonNormalActive: 'rgba(12, 58, 72, 0.94)',
    colorBorderButtonNormalDefault: 'rgba(255, 255, 255, 0.16)',
    colorBorderButtonNormalHover: CYAN,
    colorBorderButtonNormalActive: CYAN,
    colorTextButtonNormalDefault: TEXT,
    colorTextButtonNormalHover: CYAN,
    colorTextButtonNormalActive: CYAN,

    // The segmented control: the market's tab plates.
    colorBackgroundSegmentDefault: 'rgba(24, 28, 40, 0.92)',
    colorBackgroundSegmentHover: 'rgba(12, 58, 72, 0.94)',
    colorBackgroundSegmentActive: CYAN,
    colorBackgroundSegmentWrapper: 'rgba(24, 28, 40, 0.92)',
    colorTextSegmentDefault: BODY,
    colorTextSegmentHover: CYAN,
    colorTextSegmentActive: INK,
    colorBorderSegmentWrapper: EDGE,

    // Sliders, radios, the anchor navigation's line.
    colorBackgroundSliderRangeDefault: CYAN,
    colorBackgroundSliderRangeActive: '#67e8f9',
    colorBackgroundSliderHandleDefault: CYAN,
    colorBackgroundSliderHandleActive: '#67e8f9',
    colorBackgroundSliderTrackDefault: EDGE,
    colorBackgroundControlChecked: CYAN,
    colorBackgroundControlDefault: BG,

    // Ink.
    colorTextBodyDefault: TEXT,
    colorTextBodySecondary: BODY,
    colorTextHeadingDefault: TEXT,
    colorTextHeadingSecondary: DIM,
    colorTextFormDefault: TEXT,
    colorTextLabel: BODY,
    colorTextAccent: CYAN,
    colorTextLinkDefault: CYAN,
    colorTextLinkHover: '#67e8f9',
    colorTextInteractiveDefault: BODY,
    colorTextInteractiveHover: CYAN,
    colorTextInteractiveActive: CYAN,
    colorTextDropdownItemDefault: TEXT,
    colorTextDropdownItemHighlighted: CYAN,
    colorTextGroupLabel: DIM,

    // Our plates are cut, not pills: small radii everywhere.
    borderRadiusButton: '4px',
    borderRadiusContainer: '4px',
    borderRadiusDropdown: '4px',
    borderRadiusInput: '4px',
    borderRadiusItem: '4px',
    borderRadiusTiles: '4px',
  },
}
