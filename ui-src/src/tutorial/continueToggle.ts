/**
 * Does the lobby draw "Continue tutorial into the first match"? (#261, #387)
 *
 * PURE, AND NO RUNTIME IMPORTS, so scripts/test-continue-toggle.mjs can load it
 * with node's type stripping. check-ui rule R25 is what holds Lobby.tsx to
 * asking this rather than deciding for itself.
 */
export interface ContinueToggleState {
  /** Lua's `done` -- the account finished the in-game half this session. */
  done: boolean
  /** Lua's `offerable` -- the account still has the offer to spend. */
  offerable: boolean
  /** The "are you sure?" card is on screen, anchored on this toggle. */
  declineCard: boolean
  /** The toggle's own position. Defaults to on. */
  gameOn: boolean
  /** The lobby card on screen, by id, or null. */
  step: string | null
  /** The session latch: the toggle has been shown once (`tutorialGameOffered`). */
  offered: boolean
}

export function showContinueToggle(s: ContinueToggleState): boolean {
  // ═══ A FINISHED PLAYER NEVER SEES IT AGAIN (#387) ═══
  //
  // Owner, 2026-10-03: "Seems after getting paid for the tutorial, after
  // finishing the match, the tutorial continue toggle is still in lobby."
  //
  // `offerable` was already false for them -- BR.Tutorial.finish lowers it --
  // but the line below ORs in `gameOn`, which keeps the toggle up for a player
  // who declined and then re-ticked the box (2026-09-08). `gameOn` defaults to
  // on and nothing moves it on a finish, and `offered` is a session latch
  // nothing lowers, so a player who finished with the box left on (the normal
  // path) matched that case exactly. A finish and a taken-back decline both
  // read `offerable = false`; only `done` tells them apart, so it is a veto
  // and not one more term in the OR.
  if (s.done) return false
  return (s.offerable || s.declineCard || s.gameOn)
    && (s.step === 'ready' || s.offered)
}

/** What the page knows as a match's warmup begins. See `matchHalfOnWarmup`. */
export interface WarmupState {
  /** `tutorialGameArmed` -- the lobby half finished, or a ready-up, with the box on. */
  armed: boolean
  /** `tutorialGameOn` -- the continue toggle's position right now. */
  gameOn: boolean
  /** `tutorialGameRun` -- the in-game half is already running. */
  running: boolean
  /** `match.participant` -- false for a bystander in the lobby. */
  participant: boolean | undefined
}

/**
 * Does the in-game half start as warmup begins? (#405)
 *
 *   start  start it, and spend the arm
 *   spend  spend the arm and start nothing
 *   wait   leave everything as it is
 *
 * ═══ THE TOGGLE TURNED OFF IS A NO, WHENEVER IT WAS TURNED OFF ═══
 *
 * Owner, 2026-10-11: "I just turned off the extended offer, went to warmup" and
 * the in-game walkthrough started anyway. The lobby half's last card ARMS the
 * match half when the toggle is on -- and turning the toggle off after that
 * (the decline: "Turning this off gives up the offer for good") never disarmed
 * it, so warmup started a walkthrough the player had just given up, for a
 * reward the card had told them was gone.
 *
 * So the toggle's position AT WARMUP is the answer. Off: the arm is spent and
 * nothing runs. On -- including a decline taken back while the card was up,
 * which the owner kept on 2026-09-08 -- it runs as before.
 */
export function matchHalfOnWarmup(s: WarmupState): 'start' | 'spend' | 'wait' {
  if (!s.armed || s.running) return 'wait'
  // A BYSTANDER IS NOT IN THIS MATCH, and their arm keeps for one they are in.
  if (s.participant === false) return 'wait'
  return s.gameOn ? 'start' : 'spend'
}
