/**
 * THE LOBBY TRACK, WIRED TO THE PAGE (#423).
 *
 * audio/lobbyTrack.ts plays the loading screen's song on into the lobby and
 * knows nothing about the store; this tells it what is happening. Installed
 * once, from main.tsx, BEFORE React renders: br_loadscreen posts its handoff on
 * br_core's exit cue, and a post nobody is listening for is gone for good.
 *
 *   a window message     -> onMessage      the handoff, if it is one
 *   a 'locker' push      -> setDeadlineIn  its unlockInMs, as it lands
 *   locked true -> false -> unlocked       the net
 *   worldReady -> true   -> worldReady     the lobby is uncovered
 *   leaving -> true      -> leftLobby      the curtain is going up over it
 *
 * ONCE ITS WORK IS DONE IT LETS GO of the listener and the subscription, and
 * says in one console line how it went. That line is the only way a playtest
 * can tell "silent before the unlock" from "the net had to cut it" from "the
 * file never loaded". A song that went quiet on its own while the Locker is
 * still locked waits for the unlock, so the line can say how long before it
 * the song was silent; every other ending says so the moment it comes.
 */

import { useUi } from '../store'
import { isBrowser } from '../bridge/nui'
import { isEmbeddedFrame } from '../bridge/envelope'
import { createLobbyTrack } from './lobbyTrack'

/**
 * br_loadscreen's own copy of the song, fetched across resources.
 *
 * THE COUPLING, NAMED. br_loadscreen ships this file -- its fxmanifest.lua
 * lists 'audio/loadingscreen.ogg' -- and FiveM serves it under that resource's
 * name. It is the very bytes the loading screen played, so the two copies are
 * the same song to the sample through the crossfade, and one copy rather than
 * two keeps 5.5 MB off every player's download. br_loadscreen has no ui_page,
 * and this works anyway because FiveM registers cfx-nui-* for every resource
 * (see br_ui/fxmanifest.lua). Move or rename the file there and this fetch
 * answers 404: the song stops at the cue as it did before #423, and the
 * console line says why.
 */
const SRC = 'https://cfx-nui-br_loadscreen/audio/loadingscreen.ogg'

let installed = false

/** Called once, from main.tsx, before the first render. */
export function installLobbyTrack(): void {
  // Not in the browser harness: no loading screen hands anything over there,
  // and no cfx-nui host answers the fetch.
  if (installed || isBrowser) return
  installed = true

  const track = createLobbyTrack({ src: SRC, onDone: () => finish() })

  // THE FRAME FIRST, THEN THE PAYLOAD; NOT THE NUI GUARD, AND NOT THE ORIGIN.
  // check-ui rule R14 holds every inbound message to the NUI guard, and that
  // guard is for Lua's envelopes: this is not one (it has no `t: 'br'`). What
  // is taken from it is its first test, run before a field of the message is
  // read -- a frame this page embedded (the manual, the Ringmaster console) is
  // refused, as bridge/envelope.ts refuses it. That test cannot refuse the
  // loading screen, which sits beside this page under FiveM's root page, not
  // inside it. The check a reader expects next is `ev.origin`, and it is not
  // written, for the reason envelope.ts gives about its own: the loading
  // screen's origin (nui://br_loadscreen) is read out of FiveM's source and has
  // never been measured on a live client, and a wrong guess would silence the
  // song for every player with nothing in the console. So another resource's
  // frame can still post one, and the payload is judged instead: readHandoff
  // (lobbyTrackPlan.ts) takes the first well-formed, fresh handoff, and only
  // its numbers and its mute -- never a URL; the file is SRC above. A forged one
  // that landed first could start this song where it chose, or keep it silent,
  // the player's M included, and nothing more: once per page load, only before
  // worldReady, and still under Lua's deadlines and the net.
  const onMessage = (ev: MessageEvent): void => {
    if (isEmbeddedFrame(window, ev.source)) return
    track.onMessage(ev)
  }
  window.addEventListener('message', onMessage)

  /** The unlock, or the curtain over the lobby, has come. */
  let over = false
  let finished = false

  const unsubscribe = useUi.subscribe((s, prev) => {
    // LUA'S EXACT DEADLINE, CONVERTED ON RECEIPT. unlockInMs counts from the
    // push, and this runs in the task the push landed in -- setLocker writes the
    // store and the store calls this before it returns -- so the track's clock
    // here is as close to the push as the page can read. Every push replaces
    // the whole payload, so a new object is a new push, and one without the
    // field leaves the deadline as it was.
    if (s.locker !== prev.locker) {
      const ms = s.locker.unlockInMs
      if (typeof ms === 'number' && Number.isFinite(ms)) track.setDeadlineIn(ms)
    }

    // THE NET. A boot shows the page undefined, then false, then true, then
    // false (LockerPayload.locked), so an unlock is the true -> false edge and
    // nothing else.
    if (prev.locker.locked === true && s.locker.locked !== true) {
      over = true
      track.unlocked()
      finish()
    }

    if (s.worldReady && !prev.worldReady) track.worldReady()

    // THE PLAYER LEAVING THE LOBBY IS THE CURTAIN GOING UP OVER IT. Readying up
    // raises it ('dropping': br_core client/state.lua as the server names the
    // player a participant, and the warmup trip in client/spawn.lua), and it is
    // the first the page hears of the move. state.lua holds the new match state
    // back until the curtain has covered the screen, so `hud.state` and
    // `match.state` arrive after it -- and the Locker's own unlock later still:
    // the trip stops the entrance only once the screen is black, up to about
    // 2500 + 1200 ms on. Whatever raised it, a curtain covers the lobby, and a
    // song that belongs to the walk-in has nothing left to play under.
    if (s.leaving && !prev.leaving) {
      over = true
      track.leftLobby()
      finish()
    }
  })

  /** The console line, once the track is done and nothing it could still
   *  report is to come; then nothing of this stays installed. */
  function finish(): void {
    if (finished) return
    const st = track.stats()
    if (st.phase !== 'done') return
    if (!over && st.silentAt !== null && useUi.getState().locker.locked === true) return
    finished = true
    unsubscribe()
    window.removeEventListener('message', onMessage)
    // eslint-disable-next-line no-console
    console.info('[br_ui] lobby track', JSON.stringify(st))
  }
}
