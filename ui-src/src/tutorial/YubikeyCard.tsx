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
 * count and no button: the words are his and nothing else is said.
 *
 * ═══ HIS HEADINGS, AND HIS WORDS AFTER THE KEY (round 6, owner 2026-10-07) ═══
 *
 * 'make "You found a Yubikey!" H1 please, and "Please read this entire
 * message." H3', and "Where it has the Enter gylph, please append "to dismiss" (spelling-ok: his words)
 * next to that." So the card is an <h1> (copy first_pickup_title), an <h3>
 * (first_pickup_subtitle), the body (first_pickup), and the Enter cap with
 * first_pickup_dismiss beside it -- the cap, a gap, the words, as the
 * walkthrough's own key hints are drawn (AnnotationCard's KeyHint, `.tut-key`).
 *
 * ═══ IN THE LOWER QUARTER, AS THE WALKTHROUGH'S CARDS ARE ═══
 *
 * "move the card to the lower 1/4 as we've done with other tutorial cards."
 * Those are the steps with `place: 'quarter'`, which TutorialLayer puts through
 * cardPlacement.ts's `centred` at BAND.quarter -- so this card is too, through
 * the same function and the same band, with nothing re-derived here: its own
 * box MEASURED (offsetWidth / offsetHeight, the layout box, which the arrival's
 * scale does not touch) with the root font size in the same breath, before
 * paint, and measured again when the words, the interface or text scale, or
 * the viewport change -- TutorialLayer's invalidation set, less the step.
 *
 * ═══ NOTHING HERE TAKES IT DOWN ═══
 *
 * It takes no focus and has nothing to click (no `interactive`): the player
 * keeps moving and shooting. Lua owns whether it is up (BR.Nui.YUBIKEY_CARD),
 * reads Enter as a control -- the only key it takes, and only while no screen
 * holds the keyboard -- and sends `show: false` when it is pressed. No timer,
 * nothing else. The one timeout below staggers the text's arrival, as
 * AnnotationCard's does; it never removes anything. The one listener is the
 * window's resize, which only measures again.
 *
 * Where it is drawn (App.tsx) is where Lua takes Enter for it: in a match,
 * with no screen over the HUD.
 */

import { useEffect, useLayoutEffect, useRef, useState } from 'react'

import { emphasize } from './AnnotationCard'
import { BAND, centred, sameBox, type CardBox } from './cardPlacement' // spelling-ok: the kernel's own name
import { KeyCap } from '../ui/KeyCap'
import { useUi } from '../store'
import type { YubikeyCardWords } from '../bridge/types'

export default function YubikeyCard({ card }: { card: YubikeyCardWords }) {
  const [landed, setLanded] = useState(false)
  useEffect(() => {
    const t = setTimeout(() => setLanded(true), 180)
    return () => clearTimeout(t)
  }, [])

  // ── its own box, measured (TutorialLayer's way, cardPlacement.ts's why) ──
  const cardRef = useRef<HTMLDivElement | null>(null)
  const [box, setBox] = useState<CardBox | null>(null)
  const [viewportTick, setViewportTick] = useState(0)
  const uiScale = useUi((st) => st.settings.uiScale)
  const textScale = useUi((st) => st.settings.textScale)
  useEffect(() => {
    const bump = () => setViewportTick((n) => n + 1)
    window.addEventListener('resize', bump)
    return () => window.removeEventListener('resize', bump)
  }, [])
  useLayoutEffect(() => {
    const el = cardRef.current
    if (el === null) return
    const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
    const next = { w: el.offsetWidth, h: el.offsetHeight, rem }
    setBox((prev) => (sameBox(prev, next) ? prev : next))
  }, [card, uiScale, textScale, viewportTick])

  const { left, top } = centred(box, window.innerWidth, window.innerHeight, BAND.quarter) // spelling-ok: the kernel's own name
  const shown = landed ? ' tut-in' : ''

  return (
    <div className="yubikey-card-slot">
      <div
        ref={cardRef}
        className="tut-card yubikey-card panel tscale"
        style={{
          left,
          top,
          // THROWN FROM THE KEY'S CORNER, the HUD's bottom right, where the
          // icon it explains is drawn.
          ['--from-x' as string]: '1.75rem',
          ['--from-y' as string]: '1.75rem',
        }}
        role="dialog"
        aria-live="polite"
      >
        {card.title !== '' && <h1 className={`yubikey-card-h1 tut-title${shown}`}>{card.title}</h1>}
        {card.subtitle !== '' && <h3 className={`yubikey-card-h3 tut-title${shown}`}>{card.subtitle}</h3>}
        <p className={`tut-body${shown}`}>{emphasize(card.text)}</p>
        <div className="tut-foot yubikey-card-foot">
          <span className="tut-acts">
            <span className="tut-key">
              <KeyCap label="Enter" fs="0.78rem" />
              {card.dismiss}
            </span>
          </span>
        </div>
      </div>
    </div>
  )
}
