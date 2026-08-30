import { CB, type SettingsPayload } from '../bridge/types'
import { setUiVolume } from '../audio/cues'
import { fetchNui } from '../bridge/nui'

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
  // BOTH MUST MATCH BR.VoiceModeDefault in br_lib/shared/enums.lua. These are
  // the values the screen renders before Lua's push lands, so a disagreement
  // shows the player a mode they are not on. TypeScript cannot read the Lua
  // table, so tools/verify.sh compares the spellings and fails if they drift --
  // which is how the single field this pair replaced was found sitting on
  // 'squad' while Lua said 'nearby'.
  voiceModeSolo: 'nearby',
  voiceModeSquad: 'nearby',
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

  // ═══ AND THE RESOLVED GREEN, BACK TO LUA, FOR THE DUI PROMPTS ═══
  //
  // The world prompts are a SEPARATE DOCUMENT (br_ui/dui/prompt.html) rendered
  // into a runtime texture. It shares no stylesheet with this page, so it
  // cannot read a custom property off this `:root` -- and the shop's price line
  // has to be --color-hp (owner, 2026-08-29: the price "needs to be increased
  // in font size and make it green").
  //
  // WHY THIS IS READ BACK OUT OF THE DOCUMENT RATHER THAN LOOKED UP. The
  // obvious alternatives both duplicate the palette: a hex in Lua, or a second
  // copy of the :root[data-cb] blocks inside prompt.html. Either one is a
  // second representation of index.css's four accessibility tokens, and the day
  // somebody retunes the green, one of the two goes stale in silence.
  //
  // getComputedStyle asks the browser what --color-hp IS, one line after the
  // attribute that decides it -- so deuteranopia's teal, protanopia's teal and
  // the default green all arrive here without this file knowing any of them.
  // index.css stays the only place a green is written.
  //
  // FIRE AND FORGET. A failed post leaves the prompt on its existing colour,
  // which is a price in the wrong green rather than no price at all -- and this
  // runs on every settings apply, so the next one corrects it.
  const hp = getComputedStyle(root).getPropertyValue('--color-hp').trim()
  if (hp) {
    void fetchNui(CB.PALETTE, { hp }).catch(() => {})
  }
}
