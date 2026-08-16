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
import Settings from './screens/Settings'
import Locker from './screens/Locker'
import Market from './screens/Market'
import PlayerList from './screens/PlayerList'
import PauseMenu from './screens/PauseMenu'
import Help from './screens/Help'
import Page from './ui/Page'

/** The lobby's sub-screens. The base menu recedes under any of them. */
const LOBBY_SUBSCREENS = new Set(['settings', 'locker', 'market', 'help'])

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
  useNuiEvent('party',    (d) => s.setParty(d))
  useNuiEvent('voice',    (d) => s.setTalking(d.talking ?? []))
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
  useNuiEvent('leaving',  (d) => s.setLeaving(d.show, d.kind))
  // Pushed on every br:ui:ready, not only the first: br_ui restarting
  // mid-match hands CEF a fresh page at default scale, and without a re-push
  // the player's interface would silently revert for the rest of the session.
  useNuiEvent('settings', (d) => s.setSettings(d))
  useNuiEvent('locker',   (d) => s.setLocker(d))
  useNuiEvent('progress', (d) => s.setProgress(d))
  useNuiEvent('market',   (d) => s.setMarket(d))
  useNuiEvent('players',  (d) => s.setPlayers(d))
  useNuiEvent('report',   (d) => s.setReportResult(d))
  useNuiEvent('keybinds', (d) => s.setKeybinds(d.actions, d.raw === true))
  // Separate from 'progress' on purpose: a reconnect restores the bar, it
  // does not replay a celebration.
  useNuiEvent('xp',       (d) => s.awardXp(d))
  useNuiEvent('earned',   (d) => s.setEarned(d))

  // Lua owns focus. When it hands focus to chat, the input opens; when it takes
  // focus away, the input closes. The UI never decides this on its own.
  useNuiEvent('focus', (d) => {
    s.setFocus(d.screen, d.tab)
    // Focus returning to the lobby is the pause round-trip completing.
    if (d.screen === 'lobby') s.setPauseHiding(false)
    if (d.screen === 'chat') {
      s.openChat(d.channel ?? s.chatChannel)
    } else if (s.chatOpen) {
      s.closeChat()
    }
  })

  // ESC IN THE LOBBY OPENS OUR SETTINGS.
  //
  // It used to raise GTA'S pause menu, which was the right answer when we did
  // not have one of our own -- and is now the wrong one twice over: the
  // engine's menu opened and immediately closed again (br_core suppresses the
  // frontend now that Escape is ours), so the key appeared to flicker and do
  // nothing (user, 2026-08-09).
  //
  // In the lobby there is no match to pause, so the useful destination is the
  // settings screen -- which is what a player pressing Escape at a menu is
  // reaching for anyway. In a MATCH, Escape is the pause menu and br_core
  // routes it; this handler deliberately only fires on the lobby.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      const st = useUi.getState()
      if (st.focus !== 'lobby' || !st.worldReady) return
      e.preventDefault()
      void fetchNui(CB.SETTINGS_FOCUS, { open: true })
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
      {/* THE LOBBY STEPS ASIDE FOR ITS SUB-SCREENS rather than sitting behind
          them. The locker's scrim only covers the left half (the right half
          IS the character), and the market's is lighter still -- so the base
          menu was visible underneath both of them, reading as two screens
          stacked rather than one navigating (user, 2026-08-09). */}
      <Lobby
        visible={showLobby && !s.pauseHiding}
        under={LOBBY_SUBSCREENS.has(s.focus)}
      />
      {showEnd && s.summary && <EndScreen summary={s.summary} />}
      {/* The voluntary-leave interstitial covers EVERYTHING -- including
          the lobby that mounts underneath it mid-trip -- until Lua says
          the vista is real, then fades out over the waiting menu. Always
          mounted so the exit is a fade, not a pop. */}
      <LeaveScreen show={s.leaving} kind={s.curtain} />
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
      {/* LAST, SO IT IS ON TOP OF EVERYTHING. Settings is opaque and full
          screen, and it opens from a keybind mid-match as well as from the
          lobby -- so it has to cover the HUD, not sit under it.

          DRIVEN BY FOCUS, like the inventory panel, and for the same reason:
          the thing that decides whether the screen is up and the thing that
          owns the cursor must be the same thing, or they drift apart and the
          player ends up with a menu they cannot click or a cursor over no
          menu. Both routes in ask Lua; neither opens it locally. */}
      <Page show={s.focus === 'settings'}><Settings /></Page>
      {/* The locker is the lobby wearing a different panel: the camera and
          the ped are already there, so this screen is a list and a scrim.
          Same focus rule as everything else. */}
      <Page show={s.focus === 'locker'}><Locker /></Page>
      {/* The market is the third face of the same screen. It has no ped to
          show, so it takes the whole width. */}
      <Page show={s.focus === 'market'}><Market /></Page>
      <Page show={s.focus === 'players'}><PlayerList /></Page>
      {/* The manual, from the lobby. The same component the pause menu
          embeds, in its own frame. */}
      <Page show={s.focus === 'help'}><Help /></Page>
      {/* The pause menu REPLACES GTA's, so it sits above everything our own
          screens draw and below only the curtain. */}
      <Page show={s.focus === 'pause'}><PauseMenu /></Page>
    </>
  )
}
