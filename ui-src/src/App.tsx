import { useEffect } from 'react'
import { useNuiEvent } from './bridge/useNuiEvent'
import { fetchNui } from './bridge/nui'
import { CB } from './bridge/types'
import { useUi } from './store'
import Hud from './hud/Hud'
import Chat from './chat/Chat'
import Lobby from './screens/Lobby'
import EndScreen from './screens/EndScreen'
import LeaveScreen from './screens/LeaveScreen'
import InventoryPanel from './screens/InventoryPanel'
import Notices from './hud/Notices'

/**
 * Root.
 *
 * Screens are mounted once and toggled by visibility rather than being mounted
 * and unmounted. Remounting the HUD mid-fight would drop every CSS transition
 * and cost a layout pass at the worst possible moment.
 *
 * All envelope routing happens here, in one place, so there is a single list of
 * what the UI reacts to.
 */
export default function App() {
  const s = useUi()

  useNuiEvent('snapshot', (d) => s.hydrate(d))
  useNuiEvent('state',    (d) => {
    s.setMatch(d)
    // The result screen lives exactly as long as the teardown does.
    if (d.state === 'waiting') s.setSummary(null)
    // The storm exists only while a match is live. Clearing it HERE -- off
    // the state transition the UI already receives -- is what removes the
    // card between matches; Lua never sends a "no storm" message (a nil
    // payload crosses the bridge as {}, which once rendered as a ghost
    // "PHASE UNDEFINED" card during warmup).
    if (d.state !== 'playing') s.setStorm(null)
  })
  useNuiEvent('hud',      (d) => s.setHud(d))
  useNuiEvent('squad',    (d) => s.setSquad(d))
  useNuiEvent('inv',      (d) => s.setInv(d))
  useNuiEvent('storm',    (d) => s.setStorm(d))
  useNuiEvent('dbno',     (d) => s.setDbno(d))
  useNuiEvent('spectate', (d) => s.setSpectate(d))
  useNuiEvent('summary',  (d) => s.setSummary(d))
  useNuiEvent('lobby',    (d) => s.setLobby(d))
  // One channel, two verbs: an invite arriving, and an invite being taken
  // back. A card that offers to join a party the sender has already left
  // behind is a button that lies.
  useNuiEvent('invite',   (d) => (d.cancel ? s.clearInvite() : s.setInvite(d)))
  useNuiEvent('feed',     (d) => s.pushFeed(d))
  useNuiEvent('chat',     (d) => s.pushChat(d))
  useNuiEvent('toast',    (d) => s.pushNotice(d))
  // Also consumed by useScreenMetrics (CSS variables); the store copy is for
  // components that need to REASON about the layout -- chat and notices pick
  // their anchor by whether the radar is on screen.
  useNuiEvent('screen',   (d) => s.setScreen(d))
  useNuiEvent('leaving',  (d) => s.setLeaving(d.show))

  // Lua owns focus. When it hands focus to chat, the input opens; when it takes
  // focus away, the input closes. The UI never decides this on its own.
  useNuiEvent('focus', (d) => {
    s.setFocus(d.screen)
    // Focus returning to the lobby is the pause round-trip completing.
    if (d.screen === 'lobby') s.setPauseHiding(false)
    if (d.screen === 'chat') {
      s.openChat(d.channel ?? s.chatChannel)
    } else if (s.chatOpen) {
      s.closeChat()
    }
  })

  // ESC IN THE LOBBY -> GTA'S PAUSE MENU. The engine never sees the key
  // while NUI holds focus, so the page captures it: fade the menu out
  // immediately (pauseHiding), then ask Lua to drop focus and raise the
  // pause screen. The fallback timer covers a failed round-trip -- a menu
  // that faded out and never came back would be a soft lock.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      const st = useUi.getState()
      if (st.focus !== 'lobby' || st.pauseHiding || !st.worldReady) return
      st.setPauseHiding(true)
      void fetchNui(CB.PAUSE, {})
      window.setTimeout(() => {
        const cur = useUi.getState()
        if (cur.pauseHiding && !cur.hud.paused) cur.setPauseHiding(false)
      }, 1500)
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // WARMUP is not a lobby. Players are standing in the world on the warmup pad,
  // so they get the HUD -- an earlier version hid it, which combined with the
  // Lobby only rendering when focus === 'lobby' (which nothing ever set) left
  // the screen completely empty for the whole warmup countdown.
  //
  // The lobby shows when the MATCH is waiting -- or when this player
  // personally is in the lobby while a match runs without them (left it, or
  // never readied up). The match state alone stopped being the right test the
  // moment leaving a match became possible. `hud.state` is the server's word
  // on OUR state, so this stays a mirror, not a local decision.
  //
  // Visible whether or not Lua has granted focus: a queue screen you cannot
  // see is worse than one you cannot yet click.
  // The result interstitial owns the teardown: from the moment the match is
  // decided until the state machine is back at WAITING, players see won-or-
  // lost and "cleaning up" -- not the find-a-match card pretending a match
  // could form.
  const tearingDown = s.match.state === 'ended' || s.match.state === 'cleanup'
  // Participant-gated twice over: Lua only sends a summary to players who
  // were in the round, and this refuses to slam a verdict over a bystander
  // even if a stale summary is somehow still in the store.
  const showEnd = tearingDown && s.summary !== null && s.match.participant !== false

  // NEVER the lobby during teardown -- FOR PARTICIPANTS. The server flips
  // everyone to the LOBBY state the instant the match is decided, but the
  // verdict payload follows ~half a second later (it waits for the placement
  // deltas), and "own state is lobby" showing the menu in that gap was a
  // one-frame lobby flash before the slam. The gap shows nothing: the
  // frozen world, then the verdict lands on it.
  //
  // A BYSTANDER -- someone in the lobby while other people's match ends --
  // keeps their menu through the whole teardown: the slam is not theirs
  // (no summary is even sent to them), and hiding their lobby left them
  // staring at somebody else's wasted screen.
  const showLobby = (!tearingDown || !s.match.participant)
    && (s.match.state === 'waiting' || s.hud.state === 'lobby')

  // The bus ride is a cutscene: no vitals, no counters, no kill feed.
  // Notices still render -- "doors open" IS one.
  const ridingBus = s.hud.state === 'bus'

  // Whether the vitals strip is on screen -- chat and notices fall back to
  // its position when the radar is hidden, so they need to know.
  const hudUp = !showLobby && !ridingBus && !tearingDown

  return (
    <>
      {/* Always mounted; visibility follows match state so transitions cost no
          mount work mid-fight. Hidden under the pause menu -- the fullscreen
          map does not need our chrome floating over it. */}
      <Hud visible={hudUp && !s.hud.paused} />
      {/* Chat vanishes with the rest of the in-match chrome the instant the
          match is decided -- a lingering kill-chatter log under the verdict
          slam reads as UI debris -- and it does NOT render under the lobby
          menu either: last round's log bleeding through the find-a-match
          card was just noise. The store keeps the messages; it is only
          unmounted, and remounts blank-slate clean at the next warmup. */}
      {!tearingDown && !showLobby && <Chat barsVisible={hudUp} />}
      <Lobby visible={showLobby && !s.pauseHiding} />
      {showEnd && s.summary && <EndScreen summary={s.summary} />}
      {/* The voluntary-leave interstitial covers EVERYTHING -- including
          the lobby that mounts underneath it mid-trip -- until Lua says
          the vista is real, then fades out over the waiting menu. Always
          mounted so the exit is a fade, not a pop. */}
      <LeaveScreen show={s.leaving} />
      {/* The TAB panel. Lua owns whether it is open -- the `inventory` keybind
          pushes NUI focus and this follows -- so there is no local toggle to
          drift out of agreement with the cursor. Keep-input focus means the
          match keeps running underneath, which is the point: this is a thing
          you do DURING a fight, not a place to hide from one. */}
      {s.focus === 'inventory' && hudUp && <InventoryPanel />}
      {/* Over the WORLD, never the menu: in-match alerts land wherever the
          player is looking, but the lobby has its own feedback (chips
          resolve, panels update) and floating toasts over it read as
          clutter (user call, 2026-08-03). The pause menu is a menu too --
          while it is open, new notices queue in the store and flush on
          unpause (dropped after 30s of waiting). */}
      {!showLobby && !s.hud.paused && <Notices barsVisible={hudUp} />}
    </>
  )
}
