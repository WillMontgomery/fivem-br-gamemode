/**
 * THE BROADCAST KIT (#431): one import for a screen.
 *
 *   import { Plate, Numeral, Bar, Presence, PresenceScope, ... } from '<kit>'
 *
 * Importing it brings the stylesheets, in the order they cascade: the tokens,
 * the primitives, the presence channels with the built-in presets, then the
 * plug-in presets. They land after src/index.css (the project's tokens, which
 * the kit's point at) because main.tsx imports it above App; a screen's own
 * sheet comes after this import.
 *
 * A screen built on the kit carries `bc-kit` on its own root: the tokens are
 * declared there and nowhere else (tokens.css).
 */
import './tokens.css'
import './kit.css'
import './motion.css'
import './motion/drop.css'
import './motion/fade.css'
import './motion/slide.css'

// The primitives
export {
  Plate, PlateLine, PlateSwap, PlateFoot, PlateZip,
  type PlateProps, type PlateVariant, type PlateState, type FlashKind, type ShakeKind,
} from './Plate'
export { ScoreCell } from './ScoreCell'
export { Numeral, Clock, type NumeralProps } from './Numeral'
export { Bar, type BarProps } from './Bar'
export { Vitals, VITAL_H, VITALS_H } from './Vitals'
export { Stamp } from './Stamp'
export { Tag, Badge } from './Tag'
export { LightSweep } from './LightSweep'
export { Button, CardAction, type ButtonVariant, type ButtonSize } from './Button'
export { Tab, TabStrip, type TabItem } from './Tab'
export { Card, CardGrid } from './Card'
export { ListRow } from './ListRow'
export { DialogFrame } from './DialogFrame'

// Motion
export { Presence, type PresenceProps, type PresenceTag } from './motion/Presence'
export { PresenceScope, PresenceClock } from './motion/PresenceScope'
export { QuickHide } from './motion/QuickHide'
export {
  usePresence, type PresenceOptions, type PresenceResult, type PresenceRootProps,
} from './motion/usePresence'
export { PresencePhaseCtx, type PhaseInfo } from './motion/context'
export { registerPreset, getPreset, presetNames, DEFAULT_PRESET } from './motion/presets'
export {
  EASE, T, STEP, LEAVE_STEP, PAGE_PRESET, PAGE_STEP, COUNT, HALF, BUILT_IN, CHANNELS,
  type PresetSpec, type Timing, type Timings, type Channel,
} from './motion/tokens'
export type { Phase } from './motion/machine'

// Helpers
export { ab, clamp, rgba, slantInsets, toneColor, u, useBeat, vars, type Tone } from './util'
