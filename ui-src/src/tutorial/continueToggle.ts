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
