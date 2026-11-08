/**
 * THE KIT'S ONE DOOR INTO THE REST OF THE GAME UI (#431).
 *
 * Everything the kit reuses from src/ comes through this file and no other;
 * scripts/test-broadcast.mjs holds every other kit file to its siblings and
 * React.
 *
 * REUSED, NEVER REWRITTEN: the one-line label rule (Fit), the drift-corrected
 * countdown, the #252 fade clock and its envelope tick, and the interface
 * cues. A screen built on the kit imports the rest of src/ (KeyCap, the item
 * art, the voice and mark glyphs) from where it lives.
 */

export { default as Fit } from '../Fit'
export { formatCountdown, startCountdown } from '../../hud/countdown'
export { createFadeClock, FADE_SETTLE_MARGIN_MS, monotonicNow } from '../fade'
export { onEnvelope } from '../../bridge/nui'
export { play } from '../../audio/cues'
export type { Cue } from '../../audio/cues'
