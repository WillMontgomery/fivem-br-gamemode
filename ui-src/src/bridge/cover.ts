/**
 * TELLING LUA WHEN THE SCREEN IS ACTUALLY BLACK.
 *
 * A screen transition is three steps in a fixed order: cover the screen, change
 * the world, uncover. Only the first and third happen in this page; the middle
 * one happens in Lua. Until this module existed there was no way for Lua to
 * know when step one had finished, so it started a timer and hoped -- and the
 * hope failed, every time, on the owner's machine:
 *
 *   "I press ready up, get accepted into a match, then the lobby UI goes away
 *    and cuts immediately to the in-game HUD/minimap/teleports my player, and
 *    THEN the fade to black happens."  (owner, 2026-08-16, #124)
 *
 * It could not have worked. A `Citizen.Wait(450)` in Lua and a 600ms CSS
 * opacity transition in CEF are two clocks in two processes with two frame
 * budgets, and three rounds of adjusting the number did not change that. The
 * page is the only thing that knows when its own paint has landed, so the page
 * says so.
 *
 * THE SIGNAL IS THE DOM'S, NOT A TIMER'S. `transitionend` and `animationend`
 * fire when the browser has finished the thing -- that is the whole point of
 * using them rather than counting milliseconds a second time on this side.
 *
 * THE FALLBACK IS A TIMER, and it has to be. A browser is allowed to skip a
 * transition it considers unnecessary (an element that was never painted at the
 * start value, a reduced-motion preference, a frame budget blown by a hitch),
 * in which case no event ever fires. Missing the report entirely would leave
 * the game waiting out its own deadline for every transition, so a slightly
 * early "covered" beats a silent one -- and Lua's deadline is the net under
 * this net.
 *
 * STATE, NEVER A TOGGLE. Same rule the focus flags and the pause flag follow
 * (br_ui/client/players.lua has the long version): the page reports the state
 * it is in, so a message lost on a busy frame costs one stale reading that the
 * next one corrects, instead of leaving the two sides permanently inverted.
 */

import { useEffect } from 'react'
import { fetchNui } from './nui'
import { CB } from './types'

/** Which cover. Lua waits on these by name. */
export type CoverKind = 'curtain' | 'verdict'

/**
 * What we last told Lua, per kind.
 *
 * Module scope rather than component state on purpose: `animationend` can fire
 * more than once for one visual event (two animations on one element, a replay
 * on a key change), and Lua does not need to hear the same fact three times.
 * A CHANGE is always sent, so nothing here can swallow a real transition.
 */
const reported: Partial<Record<CoverKind, boolean>> = {}

/** Report a cover's state to Lua, unless Lua already knows it. */
export function reportCover(kind: CoverKind, covered: boolean): void {
  if (reported[kind] === covered) return
  reported[kind] = covered
  void fetchNui(CB.COVERED, { kind, covered })
}

/**
 * Report `kind`'s cover state, and hand back the handler that says "the paint
 * has landed".
 *
 * @param kind     which cover this is
 * @param active   whether the cover is meant to be up at all
 * @param settleMs how long the cover's own animation takes. Used ONLY for the
 *                 fallback described at the top of this file -- the real signal
 *                 is the returned handler. Give it the animation's real
 *                 duration plus a little, not a guess at the frame budget.
 */
export function useCoverReport(
  kind: CoverKind,
  active: boolean,
  settleMs: number,
): () => void {
  useEffect(() => {
    if (!active) {
      // Uncovering is instant to report and must be: Lua treats "covered" as
      // permission to take the world away, and it stops being true the moment
      // the cover starts to leave.
      reportCover(kind, false)
      return
    }

    const t = window.setTimeout(() => reportCover(kind, true), settleMs)
    return () => {
      window.clearTimeout(t)

      // GOING AWAY IS NEWS TOO, AND THIS IS THE HALF THAT WOULD HAVE ROTTED.
      //
      // The verdict screen does not toggle `active` -- it UNMOUNTS when the
      // match reaches WAITING. Without this, Lua would still be holding
      // "verdict: covered" from the last match, and the next match's teardown
      // would see a screen that was already black, sweep the world away
      // instantly, and reproduce the exact bug this was built to fix -- while
      // looking, from here, like it was working.
      reportCover(kind, false)
    }
  }, [kind, active, settleMs])

  return () => {
    // The honest signal. Ignored while the cover is on its way OUT -- a
    // transition ending is also what happens when it fades away, and reporting
    // "black" at the end of an exit animation would be exactly backwards.
    if (active) reportCover(kind, true)
  }
}
