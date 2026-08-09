import type { SettingsPayload } from '../bridge/types'
import { setUiVolume } from '../audio/cues'

/**
 * Settings -> the document.
 *
 * ONE PLACE THAT TOUCHES THE ROOT ELEMENT. Every setting in this project is a
 * CSS custom property or an attribute on `:root`, and they are all written
 * here -- so "why is the interface this size" has exactly one answer, and a
 * component can never quietly opt itself out of a player's preference.
 *
 * Written to the ELEMENT rather than into a stylesheet: the values come from a
 * player dragging a slider, and rewriting a rule per frame is how you make a
 * settings screen that stutters.
 *
 * Volume is the odd one out because it is not a paint: it goes to the audio
 * module, which is the only tier a slider can reach at all. Engine audio
 * (PlaySoundFrontend) has no per-cue volume, which is a large part of why the
 * interface cues are synthesised in the browser in the first place.
 */

export const DEFAULT_SETTINGS: SettingsPayload = {
  uiScale: 1,
  textScale: 1,
  colourblind: 'off',
  volUi: 0.7,
  voiceMode: 'squad',
  volVoice: 0.8,
  volMusic: 0.5,
  gamertag: '',
}

export function applySettings(s: SettingsPayload): void {
  const root = document.documentElement

  root.style.setProperty('--ui-scale', String(s.uiScale))
  root.style.setProperty('--text-scale', String(s.textScale))

  // An ATTRIBUTE, not a class: the colourblind palettes are written as
  // :root[data-cb="..."] blocks, which is the Chrome 103-safe way to swap a
  // whole set of custom properties at once. The alternative -- a parent
  // selector reaching down into components -- would need :has(), which this
  // CEF build does not have.
  //
  // 'off' removes the attribute entirely rather than setting data-cb="off",
  // so there is no rule to match and the base palette applies with nothing
  // overriding it.
  if (s.colourblind === 'off') root.removeAttribute('data-cb')
  else root.setAttribute('data-cb', s.colourblind)

  setUiVolume(s.volUi)
}
