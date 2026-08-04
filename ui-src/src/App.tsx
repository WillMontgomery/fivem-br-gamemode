import { useNuiEvent } from './bridge/useNuiEvent'
import { useUi } from './store'
import Hud from './hud/Hud'
import Chat from './chat/Chat'
import Lobby from './screens/Lobby'
import EndScreen from './screens/EndScreen'
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
  useNuiEvent('invite',   (d) => s.setInvite(d))
  useNuiEvent('feed',     (d) => s.pushFeed(d))
  useNuiEvent('chat',     (d) => s.pushChat(d))
  useNuiEvent('toast',    (d) => s.pushNotice(d))
  // Also consumed by useScreenMetrics (CSS variables); the store copy is for
  // components that need to REASON about the layout -- chat and notices pick
  // their anchor by whether the radar is on screen.
  useNuiEvent('screen',   (d) => s.setScreen(d))

  // Lua owns focus. When it hands focus to chat, the input opens; when it takes
  // focus away, the input closes. The UI never decides this on its own.
  useNuiEvent('focus', (d) => {
    s.setFocus(d.screen)
    if (d.screen === 'chat') {
      s.openChat(d.channel ?? s.chatChannel)
    } else if (s.chatOpen) {
      s.closeChat()
    }
  })

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
  const showEnd = tearingDown && s.summary !== null

  // NEVER the lobby during teardown -- not even before the summary arrives.
  // The server flips everyone to the LOBBY state the instant the match is
  // decided, but the verdict payload follows ~half a second later (it waits
  // for the placement deltas), and "own state is lobby" showing the menu in
  // that gap was a one-frame lobby flash before the slam. The gap shows
  // nothing: the frozen world, then the verdict lands on it.
  const showLobby = !tearingDown
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
      <Lobby visible={showLobby} />
      {showEnd && s.summary && <EndScreen summary={s.summary} />}
      {/* Over the WORLD, never the menu: in-match alerts land wherever the
          player is looking, but the lobby has its own feedback (chips
          resolve, panels update) and floating toasts over it read as
          clutter (user call, 2026-08-03). */}
      {!showLobby && <Notices barsVisible={hudUp} />}
    </>
  )
}
