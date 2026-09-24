/**
 * WHEN THE CHAT LOG EMPTIES (#365).
 *
 * Owner, 2026-09-23: "clear all text chat history client-side on match
 * cleanup". Nothing emptied `chat` before this. App.tsx unmounts the log for
 * the teardown and the lobby, but the store kept every line, so the last
 * match's chatter was the first thing the next warmup drew.
 *
 * ═══ CLEANUP, NOT ENDED ═══
 *
 * Both are the teardown and the verdict screen stays up through both. Chat is
 * not drawn in either (App.tsx takes it down the instant the match is decided),
 * so today the two look the same on screen. CLEANUP is the one the owner named,
 * and it is the later one: anything that ever wants the log during the verdict
 * still has it for all of ENDED.
 *
 * ═══ AND AGAIN ON THE WAY INTO THE LOBBY ═══
 *
 * Owner, 2026-09-23, on the players CLEANUP never reaches: "yes clear them too.
 * it should clear client-side when transitioning to lobby." Leave Match detaches
 * a player on the spot, and a match that dissolves in warmup or the flight, or
 * is forced to waiting, is destroyed without a CLEANUP -- so none of them hear
 * one. What every way home does share is WAITING: a player in no match gets the
 * lobby digest, and that is how this client's mirror settles back
 * (server/broadcast.lua). A finished match passes through it too, after
 * CLEANUP, which costs nothing.
 *
 * NOT THE PLAYER'S OWN LOBBY STATE, which is what App.tsx's showLobby also
 * reads. The server flips that at ENDED to send everyone home under the verdict,
 * so keying on it would empty the log before CLEANUP. For a leaver it can land
 * half a second before their WAITING digest, but they are detached from the
 * match on the same server tick, so no line of it can arrive in between.
 *
 * ═══ EVERY CHANNEL, BECAUSE IT IS ONE LIST ═══
 *
 * Global, squad and system lines share the array. Nothing here filters by
 * channel, and scripts/test-chat-clear.mjs holds one of each to keep it so.
 *
 * ═══ THIS PAGE'S COPY ONLY ═══
 *
 * A report carries targets and categories and nothing from this log -- the
 * evidence is the server's own buffer (server/evidence.lua), and so is a
 * refused line's case. Emptying this changes what the player sees and nothing
 * anyone reviews.
 *
 * ═══ NO BYSTANDER GATE, UNLIKE THE STORM ═══
 *
 * The storm gates on the player's own state because a lobby bystander once
 * shared the match state. Since parallel matches they do not: a player in no
 * match hears no match's STATE, and the digest gives them WAITING
 * (server/broadcast.lua). The client that sees CLEANUP is one still attached to
 * that match -- its own players, who keep their matchId through the teardown.
 *
 * ═══ WHY THIS FILE HAS NO RUNTIME IMPORTS ═══
 *
 * So scripts/test-chat-clear.mjs can load it under node's type stripping, the
 * way test-countdown.mjs loads hud/countdown.ts. The store itself cannot be
 * loaded that way. check-ui rule R23 pins setMatch to this function.
 */

import type { ChatMessage, MatchState } from '../bridge/types'

/**
 * The chat log once a state payload has landed.
 *
 * ON THE EDGE INTO CLEANUP OR WAITING, the same way the warmup reset in setMatch
 * fires on the edge into WARMUP: once per arrival, not on every payload that
 * repeats it. A snapshot or a participation change re-sends the same state.
 *
 * THE SAME ARRAY OTHERWISE, not a copy. setMatch runs on every state payload,
 * and a fresh array would wake everything subscribed to `chat` for nothing.
 */
export function chatAfterState(
  was: MatchState,
  now: MatchState,
  chat: ChatMessage[],
): ChatMessage[] {
  const clears = now === 'cleanup' || now === 'waiting'
  return clears && was !== now ? [] : chat
}
