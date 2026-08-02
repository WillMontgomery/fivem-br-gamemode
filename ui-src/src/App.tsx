import { useNuiEvent } from './bridge/useNuiEvent'
import { useUi } from './store'
import Hud from './hud/Hud'
import Chat from './chat/Chat'
import Lobby from './screens/Lobby'

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
  useNuiEvent('state',    (d) => s.setMatch(d))
  useNuiEvent('hud',      (d) => s.setHud(d))
  useNuiEvent('squad',    (d) => s.setSquad(d))
  useNuiEvent('inv',      (d) => s.setInv(d))
  useNuiEvent('storm',    (d) => s.setStorm(d))
  useNuiEvent('dbno',     (d) => s.setDbno(d))
  useNuiEvent('spectate', (d) => s.setSpectate(d))
  useNuiEvent('summary',  (d) => s.setSummary(d))
  useNuiEvent('lobby',    (d) => s.setLobby(d))
  useNuiEvent('feed',     (d) => s.pushFeed(d))
  useNuiEvent('chat',     (d) => s.pushChat(d))
  useNuiEvent('toast',    (d) => s.showToast(d))

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
  // WAITING is the only genuinely pre-match state, and the lobby shows there
  // whether or not Lua has granted focus: a queue screen you cannot see is worse
  // than one you cannot yet click.
  const waiting = s.match.state === 'waiting'
  const inMatch = !waiting

  return (
    <>
      {/* Always mounted; visibility follows match state so transitions cost no
          mount work mid-fight. */}
      <Hud visible={inMatch} />
      <Chat />
      <Lobby visible={waiting} />
    </>
  )
}
