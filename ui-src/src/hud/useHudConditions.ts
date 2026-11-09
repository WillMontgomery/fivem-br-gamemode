/**
 * ONE COPY OF THE HUD'S CONDITIONS (#431).
 *
 * The warmup card, the talking line and the spectate hint draw what they are
 * given, and when each is up is decided here, from the store, for both HUDs:
 * today's (hud/Hud.tsx) and UI v2's (hud/v2/HudV2.tsx), which holds an
 * element's last frame through its way out. Each HUD used to carry its own
 * copy of the three, and a copy is a condition that can drift from the one
 * the build checks: scripts/test-hud-conditions.mjs renders both HUDs over the
 * real store and reads back what each draws. The same shape as the vitals
 * strip's one hook (hud/useVitalsPlacement.ts).
 *
 * WHAT IT COSTS A HUD'S RENDERS: nothing it did not already pay. Every field
 * read here was read by both HUDs before, and `clockOffset` is written only by
 * setMatch, in the same set as the match itself, `talkingNames` only beside
 * `talking`, which both read for the squad panel. The walkthrough's step moves
 * once a card and `spectate` at a session's few edges.
 */

import { useUi } from '../store'

export interface HudConditions {
  /** The warmup card is up. */
  warmup: boolean
  /** The server clock's offset, which the card counts the deadline down on. */
  clockOffset: number
  /** The talking line is up. */
  talking: boolean
  /** Every name heard, in the order heard. */
  talkingNames: string[]
  /** The spectate hint is up. */
  spectating: boolean
  /** Who is being watched, as the server named them: '' for nobody. */
  spectateName: string
}

export function useHudConditions(): HudConditions {
  const matchState = useUi((s) => s.match.state)
  const tutorialRun = useUi((s) => s.tutorialGameRun)
  const tutorialStep = useUi((s) => s.tutorialGameStep)
  const clockOffset = useUi((s) => s.clockOffset)
  const talkingNames = useUi((s) => s.talkingNames)
  const spectate = useUi((s) => s.spectate)

  return {
    // THE WARMUP CARD IS HIDDEN FOR THE WHOLE WALKTHROUGH, REVEALED BY ITS OWN
    // CARD.
    //
    // Owner, 2026-09-07: "don't display the timer card until they get to the
    // last step (which tells them about the card)." The server is holding this
    // match's warmup for as long as a learner is in it (BR.Match.tutorialHold),
    // so during the walkthrough this would draw a countdown to a departure a
    // day away -- which is worse than no countdown, because it is a lie with a
    // number on it.
    //
    // BOTH ENDS MOVE ON THE SAME EDGE. Reaching `game-timer` tells Lua to
    // release the hold, so the moment this appears it is counting a real
    // warmup down.
    warmup: matchState === 'warmup' && (!tutorialRun || tutorialStep === 'game-timer'),
    clockOffset,
    // Nothing to say when nobody is speaking, and an id the roster has not
    // named yet is nobody: the store keeps names apart from ids (setTalking),
    // and a line reading "Currently Talking: " is worse than no line.
    talking: talkingNames.length > 0,
    talkingNames,
    // TRUTHY, NOT `=== true`: the hint's old `!spectate?.active`, exactly. As a
    // boolean, so a falsy `active` that is not false (a 0) is never drawn as
    // text by an `&&` downstream.
    spectating: Boolean(spectate?.active),
    spectateName: spectate?.name ?? '',
  }
}
