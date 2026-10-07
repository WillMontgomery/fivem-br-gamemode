/**
 * THE FIRST-PICKUP CARD (#396, round 5).
 *
 * The owner's own words on the Yubikey ("I've still not seen the tutorial-style
 * card which tells them how to use it and requires manual dismissal using the
 * return key"), the first time a player EVER gets one: a real pickup or
 * `bryubikey give`, once per account (br_core/server/yubikey.lua, the profile
 * row's yubikeySeen).
 *
 * ═══ THE TUTORIAL'S CARD, AND ONLY ITS LOOK ═══
 *
 * The same surface and type the guided first run's cards wear -- `tut-card
 * panel tscale`, the tutorial face, `tut-body`, AnnotationCard's `emphasize`
 * for the owner's **bold** -- and the key it waits for drawn the way those
 * cards draw theirs: the project's KeyCap in the footer, a literal Enter cap
 * (`label`, as `[[Enter]]` is), since Enter is not a rebindable command. No
 * title, no count and no button: the text is his and nothing else is said.
 *
 * ═══ NOTHING HERE TAKES IT DOWN ═══
 *
 * It takes no focus and has nothing to click (no `interactive`): the player
 * keeps moving and shooting. Lua owns whether it is up (BR.Nui.YUBIKEY_CARD),
 * reads Enter as a control -- the only key it takes, and only while no screen
 * holds the keyboard -- and sends `show: false` when it is pressed. No timer,
 * nothing else. The one timeout below staggers the text's arrival, as
 * AnnotationCard's does; it never removes anything.
 *
 * Where it is drawn (App.tsx) is where Lua takes Enter for it: in a match,
 * with no screen over the HUD.
 */

import { useEffect, useState } from 'react'

import { emphasize } from './AnnotationCard'
import { KeyCap } from '../ui/KeyCap'

export default function YubikeyCard({ text }: { text: string }) {
  const [landed, setLanded] = useState(false)
  useEffect(() => {
    const t = setTimeout(() => setLanded(true), 180)
    return () => clearTimeout(t)
  }, [])

  return (
    <div className="yubikey-card-slot">
      <div
        className="tut-card yubikey-card panel tscale"
        style={{
          // THROWN FROM THE KEY'S CORNER, the HUD's bottom right, where the
          // icon it explains is drawn.
          ['--from-x' as string]: '1.75rem',
          ['--from-y' as string]: '1.75rem',
        }}
        role="dialog"
        aria-live="polite"
      >
        <p className={`tut-body${landed ? ' tut-in' : ''}`}>{emphasize(text)}</p>
        <div className="tut-foot yubikey-card-foot">
          <span className="tut-acts">
            <span className="tut-key">
              <KeyCap label="Enter" fs="0.78rem" />
            </span>
          </span>
        </div>
      </div>
    </div>
  )
}
