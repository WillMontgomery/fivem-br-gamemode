import { useEffect } from 'react'
import { useNuiEvent } from './bridge/useNuiEvent'
import { fetchNui } from './bridge/nui'
import { CB } from './bridge/types'
import { play } from './audio/cues'
import { useUi } from './store'
import Hud from './hud/Hud'
import Chat from './chat/Chat'
import Lobby from './screens/Lobby'
import EndScreen from './screens/EndScreen'
import DeathVerdict from './hud/DeathVerdict'
import LeaveScreen from './screens/LeaveScreen'
import InventoryPanel from './screens/InventoryPanel'
import Notices from './hud/Notices'
import RescueTimer from './hud/RescueTimer'
import Settings from './screens/Settings'
import Locker from './screens/Locker'
import Market from './screens/Market'
import PlayerList from './screens/PlayerList'
import PauseMenu from './screens/PauseMenu'
import Help from './screens/Help'
import TutorialLayer from './tutorial/TutorialLayer'
import { GAME_STEPS } from './tutorial/gameSteps'
import { DECLINE_STEPS } from './tutorial/steps'
import Admin from './screens/Admin'
import Page from './ui/Page'

/**
 * Screens that take the whole screen while the lobby is behind them. The base
 * menu recedes under any of them.
 *
 * `pause` JOINED THE LIST WITH #83, because the pause menu is now reachable
 * from the lobby and everything else here was already true of it: it is opaque,
 * it is full-screen, and the lobby carrying on at full strength underneath is
 * the "two screens stacked instead of one navigating" reading that put the
 * others here in the first place.
 *
 * `admin` JOINED WITH #23, for exactly the same three reasons -- and it belongs
 * here rather than being in-match only because it is reached THROUGH the pause
 * menu, which the lobby has had since #83. An admin wanting the console between
 * rounds is the likeliest case there is: it is where you go to deal with the
 * player you just saw.
 */
const LOBBY_SUBSCREENS = new Set(['settings', 'locker', 'market', 'help', 'pause', 'admin'])

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
  useNuiEvent('voice',    (d) => s.setVoice(d))
  useNuiEvent('inv',      (d) => s.setInv(d))
  useNuiEvent('storm',    (d) => s.setStorm(d))
  // The car under you, in any seat. Lua sends `show: false` on every way of
  // leaving one -- on foot, pulled out, dead, or the vehicle destroyed -- so
  // there is nothing to clear off a state transition the way the storm is.
  useNuiEvent('vehicle',  (d) => s.setVehicle(d))
  useNuiEvent('dbno',     (d) => s.setDbno(d))
  useNuiEvent('spectate', (d) => s.setSpectate(d))
  // Your own death, mid-match. Lua owns how long it stays -- it sends `show`
  // false when the window closes, on the same clock that releases the spectate
  // camera -- so there is nothing to time here.
  useNuiEvent('death',    (d) => s.setDeath(d))
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
  // GTA'S OWN MENU IS ON SCREEN AND WE MUST NOT DRAW OVER IT (#122). Lua holds
  // this true for as long as the engine's frontend is up, because Lua is the
  // only thing that can see the frontend at all.
  useNuiEvent('frontend', (d) => {
    s.setFrontendUp(d.up === true)
    s.setFrontendReason(d.reason === 'map' ? 'map' : 'menu')
  })
  useNuiEvent('tutorial', (d) => {
    s.setTutorialRun(d.run === true)
    if (d.offer !== undefined) s.setTutorialOffer(d.offer === true)
    if (d.offerable !== undefined) s.setTutorialOfferable(d.offerable === true)
    if (d.game !== undefined) s.setTutorialGameRun(d.game === true)
    if (d.crates !== undefined) s.setTutorialCrates(d.crates)
    if (d.waypoints !== undefined) s.setTutorialWaypoints(d.waypoints)
    if (d.slots !== undefined) s.setTutorialSlots(d.slots)
  })
  // THE ARROWS, READ IN LUA. These cards take no NUI focus, so CEF never sees a
  // keypress -- see the `tutorialnav` envelope for why this is the one key in
  // the interface that travels as data.
  useNuiEvent('tutorialnav', (d) => {
    if (typeof d?.seq === 'number') s.setTutorialNav({ dir: d.dir, seq: d.seq })
  })
  // Pushed on every br:ui:ready, not only the first: br_ui restarting
  // mid-match hands CEF a fresh page at default scale, and without a re-push
  // the player's interface would silently revert for the rest of the session.
  useNuiEvent('settings', (d) => s.setSettings(d))
  useNuiEvent('locker',   (d) => s.setLocker(d))
  useNuiEvent('progress', (d) => s.setProgress(d))
  useNuiEvent('market',   (d) => s.setMarket(d))
  // The warmup shop's plate, which is the ONLY thing that puts a Volts figure
  // on the HUD. A flag, not a balance -- see the envelope's note.
  useNuiEvent('shopplate', (d) => s.setShopPlate(d.show === true))
  useNuiEvent('players',  (d) => s.setPlayers(d))
  useNuiEvent('report',   (d) => s.setReportResult(d))
  // The Admin tab's availability, and any mint answer. Sent to one player, only
  // when the server has decided that player may have it.
  useNuiEvent('admin',    (d) => s.setAdmin(d))
  // Where our Discord is. Sent to EVERY player on br:ready -- an invite is a
  // public address -- and `{}` is a real answer meaning there is none, which is
  // what takes the card back down if an operator clears it and restarts.
  useNuiEvent('community', (d) => s.setCommunity(d))
  // A SQUADMATE WENT DOWN, OUT, OR CAME BACK UP -- and nothing here was
  // listening. Lua has sent `squadcue` since the squad audio landed and this
  // handler did not exist, so all three sounds were dropped by the router with
  // no error anywhere: the envelope arrived, matched no subscriber, and was
  // discarded. It presents as "the squad sounds don't work", which is
  // indistinguishable from them never having been written.
  //
  // NOT IN THE STORE, the same call HitFeedback.tsx makes: this is a
  // fire-and-forget event with no state any component reads, and routing it
  // through zustand would re-render every subscriber to play a sound.
  useNuiEvent('squadcue', (d) => play(d.cue))
  useNuiEvent('keybinds', (d) => s.setKeybinds(d.actions, d.raw === true))
  // Separate from 'progress' on purpose: a reconnect restores the bar, it
  // does not replay a celebration.
  useNuiEvent('xp',       (d) => s.awardXp(d))
  useNuiEvent('earned',   (d) => s.setEarned(d))

  // Lua owns focus. When it hands focus to chat, the input opens; when it takes
  // focus away, the input closes. The UI never decides this on its own.
  useNuiEvent('focus', (d) => {
    s.setFocus(d.screen, d.tab)
    // RECONCILED AGAINST THE FOCUS STACK, the same way pause.lua reconciles
    // `open` against it and for the same reason: a flag that says the screen
    // is not ours, left set by a message that never arrived, is a page that is
    // invisible with no cursor and a reconnect as the only way out. That is
    // the worst outcome this file can produce, so it gets a second way back.
    //
    // Lua granting focus to a real screen is proof the frontend is down --
    // nothing pushes focus while the engine owns the screen, and the restore
    // in br_core fires on exactly that transition. `none` is NOT proof: the
    // handover empties the stack on its way into the frontend, so treating it
    // as the frontend closing would clear the flag the moment it was set.
    if (d.screen !== 'none') s.setFrontendUp(false)
    if (d.screen === 'chat') {
      s.openChat(d.channel ?? s.chatChannel)
    } else if (s.chatOpen) {
      s.closeChat()
    }
  })

  // ESC IN THE LOBBY OPENS THE PAUSE MENU. THIS HANDLER IS THE ONLY THING THAT
  // CAN (#83).
  //
  // The owner's report was "there is no way to leave the server from within the
  // lobby pause menu" (2026-08-16), and the answer to it is not a button. The
  // pause menu has had a Leave server row all along. What the lobby did not
  // have was the MENU: neither key route into it exists on this screen.
  //
  //   * The engine's binding needs the GAME to receive the key. In the lobby
  //     NUI holds the cursor with keep-input off, so the game receives nothing.
  //   * br_core's raw key layer reads the keyboard directly and is the thing
  //     that normally survives that -- but its own frontend suppressor records
  //     that "the raw layer cannot see Escape while CEF holds the cursor"
  //     (br_core/client/natives.lua), and the lobby is the screen that holds
  //     it.
  //
  // The page, though, has DOM focus by definition while the cursor is ours, so
  // this listener is the one thing on the lobby that is certain to see a
  // keypress. It already existed and already fired reliably -- it was simply
  // pointed at the wrong screen, opening Settings instead of the menu the
  // player was asking for.
  //
  // The first fix for #83 put a Leave server button on the lobby instead, and
  // the owner rejected the shape: "the leave button shouldn't be on the front
  // page, but rather in the pause menu." That button is gone; this is what
  // replaces it.
  //
  // SETTINGS LOSES ITS ESCAPE SHORTCUT AND KEEPS EVERYTHING ELSE. It is still
  // a button on the lobby and still a tab inside the pause menu, so nothing
  // became unreachable -- and Escape now means the same thing in the lobby as
  // it does in a match, which it did not before.
  //
  // F1 TOO, BECAUSE IT IS WHAT PEOPLE REACH FOR. It is the pause menu's
  // engine-side default and is inert on any client running the raw key layer
  // (br_core gates the RegisterKeyMapping handlers off while it runs), so
  // pressing it does nothing anywhere. Answering it here costs one comparison
  // and means the habit works on the screen this issue is about.
  //
  // ASKS LUA, NEVER OPENS LOCALLY -- the same rule the locker, market and
  // settings buttons follow. The focus stack decides what is on screen.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' && e.key !== 'F1') return
      const st = useUi.getState()
      // Gated on the lobby holding focus, so this cannot fire under a
      // sub-screen (which has its own back key) or over the loading screen,
      // where there is nothing behind the menu to come back to.
      if (st.focus !== 'lobby' || !st.worldReady) return
      e.preventDefault()
      void fetchNui(CB.PAUSE_FOCUS, { open: true })
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [])

  // ═══ THE WALKTHROUGH CROSSING FROM THE LOBBY INTO THE MATCH (#261) ═══
  //
  // Owner, 2026-09-05: "when in the lobby and the tutorial is complete, the
  // 'continue' toggle is on but it doesn't start the game tutorial when I get
  // into warmup." It did not, because `tutorialGameOn` was an offer nothing
  // read -- this project's orphaned-subsystem pattern, for the third time in
  // this one feature. This is the line that reads it.
  //
  // ON THE EDGE INTO WARMUP, NOT ON BEING IN IT. Warmup is a state the page
  // sees on every payload for forty-five seconds; the transition happens once,
  // which is how often a walkthrough should start.
  //
  // AND THE OFFER IS SPENT BY TAKING IT. Without that, walking out of a match
  // and into the next one would start the walkthrough again for somebody who
  // has already had it -- and the 500 Volts is paid once, so the second run
  // would be twenty minutes for nothing.
  //
  // ASKS LUA RATHER THAN SETTING THE FLAG HERE. Lua owns whether either half is
  // running (see br_core/client/tutorial.lua) and it has work to do on the way
  // in that the page cannot: the cursor, and the markers over the crates.
  useEffect(() => {
    if (s.match.state !== 'warmup') return
    // ARMED, NOT TICKED. This read `tutorialGameOn` -- the CHECKBOX -- which
    // defaults to ticked, so every player who entered warmup on a freshly loaded
    // page started the walkthrough whether or not they had ever seen the lobby
    // half (owner, 2026-09-06: "the in-game tutorial shows up every time I hop
    // in a match until I `brtutorial off`"). The checkbox says what the player
    // WOULD like; `tutorialGameArmed` says they finished the lobby half with it
    // ticked, and only that may start anything. See the store.
    if (!s.tutorialGameArmed || s.tutorialGameRun) return
    // A BYSTANDER IS NOT IN THIS MATCH. `participant === false` is a player
    // sitting in the lobby while somebody else's round runs, and starting a HUD
    // walkthrough over a lobby they are still looking at would point every card
    // at nothing.
    if (s.match.participant === false) return
    s.setTutorialGameArmed(false)
    void fetchNui(CB.TUTORIAL_SET, { game: true })
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [s.match.state, s.match.participant, s.tutorialGameArmed, s.tutorialGameRun])

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
  //
  // ...UNLESS THIS PLAYER'S OWN PED SAYS IT IS STANDING ON THE GROUND, AND
  // THIS IS THE GATE THE FIRST ATTEMPT AT #126 MISSED.
  //
  // That attempt taught the three "what to draw" tests in Hud.tsx about
  // `hud.landed` and stopped here, one level too low. This line feeds `hudUp`,
  // which is the master switch for the ENTIRE HUD -- vitals, counters, kill
  // feed, squad panel, inventory bar, chat and the TAB panel all hang off it --
  // and it had no way to hear about a touchdown at all. So a player whose own
  // state still reads `bus` (the jump registered on the server but the roster
  // delta carrying FREEFALL never arrived, or the report went missing on the
  // way back) stood in a POI with a completely blank screen, and the thing that
  // eventually rescued them was the match reaching `playing`. That is the
  // owner's sentence almost word for word: "the inventory/loot/HUD still do not
  // appear upon landing until game state changes to playing".
  //
  // A ped on the ground is not riding a bus. The cutscene rule is about the
  // flight, and the flight is over.
  const ridingBus = s.hud.state === 'bus' && !s.hud.landed

  // ═══ AND THE AMBULANCE IS THE SECOND CUTSCENE (#191) ═══
  //
  // Owner, 2026-08-28: "while in the ambulance, our HUD should be hidden just
  // like in the bus".
  //
  // THE SAME RULE, ONE LINE LOWER, RATHER THAN A SECOND MECHANISM. The two
  // rides are the same shape: the player has no controls, no weapon and no
  // decisions, a scripted camera is on their own body, and every readout on
  // screen is about a game they are not currently playing. `hudUp` is the
  // master switch that already expresses that for the bus, so the ambulance is
  // made to look like the bus to it.
  //
  // WHY THE FACT COMES OFF THE DBNO PAYLOAD AND NOT `hud.state`. There is no
  // player state for "on the ambulance" and there must not be one: the server
  // keeps this player DBNO for the whole journey, because a failed rescue puts
  // them straight back on the floor with a bleed clock that was only ever
  // suspended (server/combat.lua, 37ef178). Inventing a state to hide a HUD
  // would put a presentation concern into the roster.
  //
  // AND THIS IS ALSO THE ANSWER TO THE OTHER HALF OF HIS MESSAGE: "I need you
  // to make the bleed out timer completely go away while in the ambulance.
  // That time should not be relevant anymore once the ambulance takes over."
  // DbnoOverlay is drawn INSIDE Hud, so hiding the HUD takes the whole card
  // with it -- which is the right amount to take. "YOU ARE DOWN" is false once
  // an ambulance has you, and a card reduced to a true heading over no content
  // would be furniture. There is deliberately no `hideTimer` prop and no branch
  // in DbnoOverlay: one flag, one rule, one thing to reason about.
  //
  // ═══ AND THE ONE THING THE RIDE PUTS BACK, WITHOUT TOUCHING THIS RULE ═══
  //
  // Owner, later the same day: "let's add an on-screen timer showing their time
  // to revive please" -- #191 step 6, which the issue asks for in the same
  // breath as "this is the only notification in the entire cycle". Those two
  // lines are about different things (a readout versus an interruption) and
  // both hold; hud/RescueTimer.tsx carries the argument in full.
  //
  // WHAT MATTERS HERE IS THAT `hudUp` DID NOT LEARN AN EXCEPTION. The obvious
  // build is to keep the HUD up and teach the surfaces inside it which of them
  // survive a ride -- and that turns the master switch into "everything
  // except...", a list that the next surface added to the HUD joins by
  // accident. So the readout is drawn OUTSIDE the hidden tree instead, as a
  // sibling of `Hud` below, exactly the way DeathVerdict already is. Hiding the
  // HUD still hides every part of the HUD.
  //
  // IT IS THE SAME BIT, NOT A SECOND TEST. `ridingAmbulance` is what turns the
  // HUD off and what turns this on, passed down rather than re-derived, so the
  // two can never end up disagreeing about whether a ride is happening.
  const ridingAmbulance = s.dbno.riding === true

  // Whether the vitals strip is on screen -- chat and notices fall back to
  // its position when the radar is hidden, so they need to know.
  const hudUp = !showLobby && !ridingBus && !ridingAmbulance && !tearingDown

  return (
    /* THE WHOLE INTERFACE, BEHIND ONE GATE (#122).
     *
     * While GTA's own menu is up, EVERYTHING of ours has to stop drawing --
     * not just the screen that asked for the handover. The engine's frontend
     * is a scaleform: nothing we draw can sit under it, so anything still
     * painting is on top of the menu the player was sent to use.
     *
     * ONE WRAPPER RATHER THAN A CONDITION ON EACH SCREEN, because the list of
     * things that draw is not the list of things that follow focus -- the
     * lobby comes from match state, the HUD from `hudUp` -- and the previous
     * fix missed the lobby for exactly that reason. A gate around all of it
     * cannot miss a screen, and cannot be missed by a screen added later.
     *
     * OPACITY, NOT UNMOUNTING. Screens are mounted once and toggled by
     * visibility so a transition never costs mount work mid-fight; tearing the
     * tree down here would throw that away and remount the HUD every time
     * somebody checked their resolution. Opacity 0 paints nothing, which is
     * all the scaleform needs, and pointer-events off means a page that is
     * invisible cannot also be quietly swallowing clicks.
     */
    <>
    <div
      style={{
        opacity: s.frontendUp ? 0 : 1,
        pointerEvents: s.frontendUp ? 'none' : undefined,
        transition: 'opacity 120ms linear',
      }}
      aria-hidden={s.frontendUp || undefined}
    >
      {/* Always mounted; visibility follows match state so transitions cost no
          mount work mid-fight. Hidden under the pause menu -- the fullscreen
          map does not need our chrome floating over it. */}
      <Hud visible={hudUp && !s.hud.paused} />
      {/* THE AMBULANCE CLOCK, AND IT IS A SIBLING OF THE HUD RATHER THAN A
          CHILD OF IT ON PURPOSE (#191 step 6, owner 2026-08-28).

          The ride hides the HUD -- also his call -- so this is an exception to
          a rule he asked for, and the way the two are kept from fighting is
          that the rule has no exception in it: `hudUp` still turns off
          everything inside `Hud`, and this is not inside `Hud`. See the note on
          `ridingAmbulance` above and the file itself.

          IT DRAWS NOTHING UNLESS A RIDE IS RUNNING, so a `show` of false is not
          an empty box in the clock slot; and it takes no props but that one bit
          -- the deadline comes off the same payload the bit does.

          ...AND NOT WHILE THE MATCH IS BEING DECIDED, which is the second half
          of the 2026-08-29 double-verdict report. A ride does not end by a
          message: client/rescue.lua's `rescue.sanity` sweep runs at 1 Hz and
          nils the ride when the match stops being PLAYING, so `dbno.riding`
          stays true for up to a second after the round is over -- and the
          verdict screen mounts 500ms in. `tearingDown` is on this client the
          instant the transition arrives, so this is the term that closes that
          window. It is the same rule DeathVerdict is now under below: the
          verdict is the end of the match and owns the screen. */}
      <RescueTimer show={ridingAmbulance && !tearingDown} />
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
        visible={showLobby}
        under={LOBBY_SUBSCREENS.has(s.focus)}
      />
      {/* YOUR OWN DEATH, MID-MATCH -- the word only, over a world that is still
          running, for the ~10s before the spectator camera takes the screen.

          MOUNTED ALONGSIDE THE VERDICT SCREEN AND NEVER WITH IT -- AND NOW
          THAT IS ENFORCED HERE RATHER THAN ASSUMED.

          It used to be assumed, in this comment, in these words: "they cannot
          coincide -- Lua takes this down on MatchState.ENDED, which is the same
          transition that raises `showEnd`". That is true of a death that has
          already happened when the match ends. It says nothing about a death
          that happens AFTER it, and one exists:

          Owner, 2026-08-29: "When one player is in the ambulance and the only
          other remaining player(s) die, the verdict shown is 'VICTORY ROYALE'
          along with ALSO the cause of DBNO on top of it."

          A player on the ambulance is DBNO, and DBNO is `isInMatch` -- so they
          are the last squad standing, the match ends, and they are awarded the
          win. Then server/rescue.lua's tick drops the rescue flag (the match is
          no longer PLAYING), server/combat.lua's bleed clock is un-suspended
          with a deadline that expired mid-ride, and they are eliminated a beat
          LATER -- which raised this word over the verdict screen, after the one
          dismissal that would have taken it down had already run. The cause is
          fixed there, in server/combat.lua: a bleed clock belongs to a live
          match and does not finish anybody after one is over.

          This line is the rule the fix leaves behind, stated where the two
          surfaces actually meet. `tearingDown` is "the match is decided", which
          is precisely the moment the verdict screen becomes the surface for it.
          Nothing that arrives after that gets to draw a second one.

          STILL OUTSIDE the `Hud` wrapper, and this is NOT `hudUp` creeping in:
          `hudUp` is four terms and would take this down for a ride, a bus and
          the lobby as well. This is one of them, and it is the one that means
          the thing this surface is about. */}
      {!tearingDown && <DeathVerdict />}
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
      {/* ONE PANEL, ONE FOCUS SCREEN. This gate used to read `'players' ||
          'playersReport'`, because report mode pushed a second screen purely to
          give up game input for its note field and the panel would otherwise
          have unmounted the moment it was used. View mode gave up game input
          too in #135, so both modes hold the same focus and the second name is
          gone from here, from the Lua side and from FocusPayload. */}
      <Page show={s.focus === 'players'}>
        <PlayerList />
      </Page>
      {/* The manual, from the lobby. The same component the pause menu
          embeds, in its own frame. */}
      <Page show={s.focus === 'help'}><Help /></Page>

      {/* ═══ THE GUIDED FIRST RUN (#261) ═══

          HERE AND NOT IN Lobby.tsx, and the reason is the settings half of the
          walkthrough: those cards have to draw while SETTINGS is the screen on
          top, not the lobby, so a mount inside the lobby would unmount the
          sequencer the moment the player did what it asked. `screen` is
          `s.focus`, which is the same name the steps are scoped by.

          INSIDE THIS ROOT, WHICH IS THE WHOLE OF HOW IT HIDES. The wrapper
          above already fades everything here on `frontendUp` -- opacity 0,
          pointer-events off, aria-hidden -- so the big map and the GTA V pause
          menu take the annotations with them and give them back, with no code
          of its own (owner, 2026-09-04). It must never be portalled out.

          LAST IN SOURCE ORDER so it paints over the screens it points at.

          NOTHING BUT /brtutorial STARTS IT TODAY. The first-match checkbox and
          the persisted one-time offer are still to come; they will raise this
          same flag. */}
      {/* BOTH ENDINGS RELEASE THE SERVER-SIDE HOLD, and both have to: a player
          left flagged as in-tutorial is a player matchmaking will never touch
          again for the life of the connection. `onAbandon` is the one that
          matters -- it fires when a step's target has gone, which is a fault,
          and a fault that ALSO stranded somebody outside the queue would be far
          worse than the fault itself. */}
      {/* The manual, from the lobby. The same component the pause menu
          embeds, in its own frame. */}
      <Page show={s.focus === 'help'}><Help /></Page>

      {/* ═══ THE GUIDED FIRST RUN (#261) ═══

          HERE AND NOT IN Lobby.tsx, and the reason is the settings half of the
          walkthrough: those cards have to draw while SETTINGS is the screen on
          top, not the lobby, so a mount inside the lobby would unmount the
          sequencer the moment the player did what it asked. `screen` is
          `s.focus`, which is the same name the steps are scoped by.

          INSIDE THIS ROOT, WHICH IS THE WHOLE OF HOW IT HIDES. The wrapper
          above already fades everything here on `frontendUp` -- opacity 0,
          pointer-events off, aria-hidden -- so the big map and the GTA V pause
          menu take the annotations with them and give them back, with no code
          of its own (owner, 2026-09-04). It must never be portalled out.

          LAST IN SOURCE ORDER so it paints over the screens it points at.

          NOTHING BUT /brtutorial STARTS IT TODAY. The first-match checkbox and
          the persisted one-time offer are still to come; they will raise this
          same flag. */}
      {/* BOTH ENDINGS RELEASE THE SERVER-SIDE HOLD, and both have to: a player
          left flagged as in-tutorial is a player matchmaking will never touch
          again for the life of the connection. `onAbandon` is the one that
          matters -- it fires when a step's target has gone, which is a fault,
          and a fault that ALSO stranded somebody outside the queue would be far
          worse than the fault itself. */}
      {/* ═══ THE IN-GAME HALF (#261) ═══

          THE SAME LAYER, A DIFFERENT SCRIPT. It points at the HUD rather than
          the lobby, so it carries no `subscreenUp`: the HUD is what is on screen
          during warmup, and a sub-screen covering it is the player opening
          something the walkthrough is about to ask them to open anyway.

          THE LAST CARD IS WHAT ENDS IT, and ending it is what pays the 500
          Volts -- see BR.Net.TUTORIAL_DONE. Only `onDone` pays; `onAbandon`
          fires when an anchor has gone, which is a fault rather than a finish.

          ⚠ THE WARMUP CLOCK IS STILL RUNNING UNDERNEATH IT. The hold the owner
          asked for exists (BR.Roster.setTutorial) but is granted only from a
          standing start -- LOBBY, no match -- and this half runs on the pad, in
          a match. So a long reader can be put on the bus mid-card today. See
          the ⚠ over BR.Net.TUTORIAL_SET for what closing it would take. */}
      {/* THE ADMIN CONSOLE (#23), IN THE FRAME `/help` GETS AND NOT THE PAUSE
          MENU'S TAB WELL -- which is the owner's call and the reason it is a
          screen at all: "the one in /help is much larger and would be most
          appropriate size-wise for Ringmaster".

          ABOVE PauseMenu IN SOURCE ORDER SO IT SITS UNDER IT, which is what we
          want: the two are never both up (pushing `admin` closes the menu, see
          br_ui/client/pause.lua) and if a focus race ever put them together,
          the menu is the screen with the way out. */}
      <Page show={s.focus === 'admin'}><Admin /></Page>
      {/* The pause menu REPLACES GTA's, so it sits above everything our own
          screens draw and below only the curtain. */}
      <Page show={s.focus === 'pause'}><PauseMenu /></Page>
    </div>

      {/* ═══════════════════════════════════════════════════════════════════
          THE GUIDED FIRST RUN, OUTSIDE THE FADE (#261)
          ═══════════════════════════════════════════════════════════════════

          IT USED TO LIVE INSIDE THE WRAPPER ABOVE, which fades everything on
          `frontendUp` -- and that was right, and is still right for every
          engine screen but one. The exception is the owner's, 2026-09-04: the
          walkthrough has to explain WAYPOINTS, which means it has to be legible
          while the big map is open. "This last point will break our current rule
          of 'don't show any NUI on the map' so you may need to change some code
          structure to allow ONLY this tutorial to shine through."

          SO THE RULE IS RESTATED HERE RATHER THAN WEAKENED THERE. Everything
          else in this page still disappears behind every frontend, unchanged;
          this one subtree opts out for exactly one of them, and says so.

          `reason` IS WHY THAT IS EXPRESSIBLE AT ALL. Lua now reports which
          engine screen went up, because the page is the only side that knows
          what a tutorial is -- br_ui/client/pause.lua holds no opinion about it.

          AND ONLY THE IN-GAME HALF ESCAPES. The lobby walkthrough has nothing to
          say over a map and hides like everything else; a card about the Locker
          drawn over the world map would be the #122 overlay again wearing a
          different hat. */}
      <div
        style={{
          opacity: s.frontendUp && !(s.frontendReason === 'map' && s.tutorialGameRun) ? 0 : 1,
          pointerEvents:
            s.frontendUp && !(s.frontendReason === 'map' && s.tutorialGameRun)
              ? 'none' : undefined,
          transition: 'opacity 120ms linear',
        }}
        aria-hidden={
          s.frontendUp && !(s.frontendReason === 'map' && s.tutorialGameRun)
            ? true : undefined
        }
      >
      {s.tutorialGameRun && (
        <TutorialLayer
          steps={GAME_STEPS}
          screen={s.focus}
          // ═══ ANY SCREEN THE STEP DID NOT ASK FOR TAKES THE CARDS DOWN ═══
          //
          // Owner, 2026-09-05: "if they press ESC through any of this to open
          // the settings menu all other cards should be hidden until the
          // settings page is dismissed."
          //
          // OUR pause menu is a React screen, not the engine's, so `frontendUp`
          // is false while it is open and the fade above never fired -- the
          // cards sat on top of it. This is the same rule the lobby half has
          // always had, applied to the HUD's screens, and it costs nothing: a
          // step that WANTS a screen names it in `screen`, and the layer
          // compares that instead (see `waitingForScreen`).
          //
          // `none` IS THE BARE HUD. The walkthrough itself takes no focus, so
          // anything else on the stack is genuinely something the player opened
          // over the controls these cards point at.
          subscreenUp={s.focus !== 'none'}
          // AND THE CARDS ARE DRIVEN BY THE ARROW KEYS, not by a cursor there
          // is no longer any way to produce. See `keyDriven`.
          keyDriven
          onStep={(id) => {
            s.setTutorialGameStep(id)

            // ═══ THE CAMERA FOLLOWS THE CARD ═══
            //
            // This line existed, and a later edit to this handler dropped it --
            // which is the whole of "the scripted camera for step 19 didn't
            // happen" (owner, 2026-09-08). Nothing else in the chain was broken;
            // `Step.cam` was authored and read by nobody.
            //
            // `false` AND NOT `null` FOR THE COME-HOME CASE, and this is the
            // load-bearing detail. br_ui's callback gates on `data.cam ~= nil`,
            // and a JSON null decodes to Lua nil -- so a null would fail that
            // guard and the camera would stay parked on the shop car for the
            // rest of the walkthrough. `false` clears the guard, is not a table,
            // and falls through to the come-home branch.
            //
            // SENT ON EVERY STEP, which costs nineteen no-op posts and buys the
            // absence of a transition table. camTo's home branch early-returns
            // when no camera is live.
            const cam = (id && GAME_STEPS.find((st) => st.id === id)?.cam) || false
            // `step` RIDES THE SAME POST. br_core turns the crate blip on for
            // exactly one card and off for every other -- see br:tutorial:step.
            // `false` for "no card", for the same Lua-nil reason `cam` uses.
            void fetchNui(CB.TUTORIAL_SET, { cam, step: id ?? false })
            // ═══ THE CLOCK STARTS ON THE LAST CARD, NOT AFTER IT ═══
            //
            // Owner, 2026-09-07: "THIS is when matchmaking should take place and
            // the timer appears for the first time on their screen." That card
            // is ABOUT the countdown, so the countdown has to be running while
            // they read it -- pointing at a timer frozen a day out is pointing
            // at nothing.
            //
            // `hold`, NOT `game`: dropping `game` would take the card off the
            // screen at the exact moment it appeared. See BR.Tutorial.hold.
            if (id === 'game-timer') void fetchNui(CB.TUTORIAL_SET, { hold: false })
          }}
          onDone={() => {
            s.setTutorialGameRun(false)
            s.setTutorialGameStep(null)
            void fetchNui(CB.TUTORIAL_SET, { game: false, done: true })
          }}
          onAbandon={() => {
            s.setTutorialGameRun(false)
            s.setTutorialGameStep(null)
            // NO `done`. This fires when a card's anchor has gone, which is a
            // fault -- paying for it would pay a learner for the walkthrough
            // breaking under them. The flag still drops, because a player left
            // holding it keeps the cursor and the layer with nothing driving
            // either.
            void fetchNui(CB.TUTORIAL_SET, { game: false })
          }}
        />
      )}

      {/* THE DECLINE CARD, which is not a walkthrough and has no steps to run --
          one card, dismissed, gone. It lives here rather than inside Lobby for
          the reason every other card does: the layer is mounted at the root so a
          screen change cannot unmount the thing explaining the screen. */}
      {s.tutorialDeclineCard && (
        <TutorialLayer
          steps={DECLINE_STEPS}
          screen={s.focus}
          onDone={() => s.setTutorialDeclineCard(false)}
          onAbandon={() => s.setTutorialDeclineCard(false)}
        />
      )}

      {s.tutorialRun && (
        <TutorialLayer
          screen={s.focus}
          subscreenUp={LOBBY_SUBSCREENS.has(s.focus)}
          onDone={() => {
            s.setTutorialRun(false)
            void fetchNui(CB.TUTORIAL_SET, { run: false })
            // FINISHING THE LOBBY HALF WITH THE BOX TICKED IS WHAT ARMS THE
            // MATCH HALF. Not the box on its own, and not `onAbandon` below --
            // a run that died on a missing anchor did not end with the player
            // agreeing to anything.
            if (s.tutorialGameOn) s.setTutorialGameArmed(true)
          }}
          onAbandon={() => { s.setTutorialRun(false); void fetchNui(CB.TUTORIAL_SET, { run: false }) }}
          onStep={s.setTutorialStep}
        />
      )}
      </div>
    </>
  )
}
