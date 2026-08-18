import { useEffect, useRef, useState } from 'react'
import { useUi, selMatch } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import Settings from './Settings'
import { play } from '../audio/cues'
import Progress from './Progress'
import NoticeLog from './NoticeLog'
import PartyCard from './PartyCard'
import Help from './Help'

/**
 * The pause menu.
 *
 * THE FRONT PAGE IS THE WAY OUT, and everything else is behind a tab. A pause
 * menu whose first screen is a settings tree is a pause menu that fails the
 * only thing anybody opens it in a hurry for: leaving. The four exits are the
 * first four objects on the screen, in increasing order of how much they cost
 * you -- back to the lobby, out of your squad, off the server, out of the
 * game -- and the two that cannot be undone ask again.
 *
 * IT REPLACES GTA'S PAUSE MENU RATHER THAN LAYERING OVER IT. The engine's
 * frontend is a scaleform, not a NUI layer: nothing we draw can cover it and
 * nothing we draw can be covered BY it, so the two cannot both be up. Lua
 * captures the key and raises this instead (br_ui/client/pause.lua).
 *
 * THE MAP IS THE ONE THING WE HAND BACK. GTA's map is a scaleform we cannot
 * reproduce and would not want to -- re-rendering Los Santos in CEF costs real
 * frames, which is the same reason the minimap is the engine's. So "Map" drops
 * our menu and opens the engine's, on its map page.
 *
 * SETTINGS IS THE SAME COMPONENT AS THE LOBBY'S, not a second copy. A pause
 * menu with its own settings screen is two settings screens that drift; this
 * one embeds the real thing, so a control added there appears here for free.
 *
 * IT OPENS FROM THE LOBBY TOO, SINCE #83, and half of this file's conditions
 * are about that. The owner asked for the way off the server to live here
 * rather than on the lobby's front page -- so this menu has to make sense on a
 * screen where there is no match to pause, no map worth opening and nothing to
 * leave except the server itself. Each of those is handled at the point it
 * matters rather than by a second lobby-flavoured copy of the menu.
 */

type Tab = 'main' | 'notices' | 'help' | 'settings'

const TAB_LABEL: Record<Tab, string> = {
  main: 'Match',
  notices: 'Notifications',
  help: 'Help',
  settings: 'Settings',
}

/** Actions that end something. `confirm` gates the ones you cannot undo. */
const EXITS: {
  id: 'lobby' | 'squad' | 'server' | 'quit'
  label: string
  sub: string
  variant: 'default' | 'danger'
  /** What the button says. Falls back to the card's own title. */
  action?: string
  confirm?: string
  /** The two answers to `confirm`, both naming what they do. */
  yes?: string
  no?: string
  squadOnly?: boolean
}[] = [
  // THE BUTTON SAYS WHAT IT DOES, at every step. Both of the confirmed rows
  // used to open with a button reading "Continue", which is a word that
  // commits you to something without naming it (user, 2026-08-09). The first
  // press states the action, the confirm restates it, and the way out is
  // never "Cancel" -- it is what staying actually means.
  {
    id: 'lobby', label: 'Back to lobby', variant: 'default',
    action: 'Leave match',
    sub: 'Forfeits this match. Your squad plays on.',
    confirm: 'Leave the match? You will be eliminated.',
    yes: 'Leave match', no: 'Keep playing',
  },
  // LEAVE SQUAD IS GONE (owner, 2026-08-09: "same as leave party"). It was --
  // it fired SQUAD_LEAVE, the same event the party card's button fires, so
  // the front page offered one action twice under two names. The party card
  // is the honest home for it: the squad is this round's team and cannot be
  // left mid-match, the party is what you keep, and that is what the button
  // was ever really doing.
  {
    id: 'server', label: 'Leave server', variant: 'danger',
    action: 'Disconnect',
    sub: 'Disconnects you from Blitz Royale.',
    confirm: 'Disconnect from the server?',
    yes: 'Disconnect', no: 'Stay connected',
  },
  // QUIT FIVEM IS NOT HERE, and cannot be. The client's own `quit` console
  // command is restricted -- "Access denied" -- and there is no server-side
  // equivalent: a server can drop you from itself, not close your game. An
  // option that cannot work is worse than one that is absent, so it is
  // absent (user, 2026-08-09). Alt+F4 and FiveM's own menu still exist.
]

export default function PauseMenu() {
  // WHERE IT OPENS CAN BE ASKED FOR. `/help` in the chat box raises this menu
  // ON the Help tab, which is the whole point of the command -- a player who
  // types /help wants the manual, not a menu with a Help button on it.
  const asked = useUi((s) => s.focusTab)
  const [tab, setTab] = useState<Tab>('main')

  // The menu is kept MOUNTED between openings (Page holds it through the exit
  // animation), so the initial state is not enough: a second /help would find
  // the component already alive and sitting on whatever tab was last used.
  // Lua clears the request after sending it, so this reads as a real change
  // each time rather than as an echo.
  useEffect(() => {
    if (asked === 'help' || asked === 'notices' || asked === 'settings') {
      setTab(asked)
    }
  }, [asked])
  const [confirming, setConfirming] = useState<string | null>(null)
  const match = useUi(selMatch)
  // The PARTY, not the squad: "leave squad" is the wrong words for a group
  // you keep, and leaving the match takes it with you.
  const party = useUi((s) => s.party)
  const inParty = party.members.length > 1

  // AM I LOOKING AT THIS FROM THE LOBBY? (#83)
  //
  // Deliberately the SAME TEST App.tsx uses to decide whether to draw the lobby
  // at all, rather than a second reading of the same fact: what this menu
  // offers and what is behind it have to agree, and two expressions for "in the
  // lobby" would eventually disagree on some frame and offer "Leave match" to
  // somebody with no match to leave. `hud.state` is the server's word on OUR
  // state, so it stays a mirror -- the second half of the test is what covers a
  // player sitting in the lobby while other people's match runs.
  const hudState = useUi((s) => s.hud.state)
  const inLobby = match.state === 'waiting' || hudState === 'lobby'

  const close = () => { void fetchNui(CB.PAUSE_FOCUS, { open: false }) }

  // THE MATCH CAN START WHILE THIS MENU IS UP, and it must not come with us.
  //
  // Queue, then open this menu to read the notifications, and the match forms
  // underneath -- you would arrive in it looking at a pause menu, holding the
  // cursor, unable to move. br_core pops `settings`, `locker` and `lobby` off
  // the focus stack on that transition and not `pause`, which is the same shape
  // as the bug that used to bring the menu back after readying up ("was brought
  // back to the pause menu where I could not close the UI", 2026-08-09).
  //
  // Asked of Lua rather than hidden locally, like every other open and close in
  // this file: the focus stack is what decides the screen is gone.
  //
  // ONE DIRECTION ONLY. Going the other way -- a match ENDING under the menu,
  // or "Back to lobby" -- is already sequenced behind the curtain by br_core,
  // which closes this through br:ui:pauseClose once the screen is black. Firing
  // here as well would take the menu away in front of the player, which is the
  // exact cut #124 exists to prevent.
  const wasInLobby = useRef(inLobby)
  useEffect(() => {
    if (wasInLobby.current && !inLobby) close()
    wasInLobby.current = inLobby
  }, [inLobby])

  /**
   * The Match tab is not a match tab in the lobby, and calling it one reads as
   * a menu that was written for somewhere else and left lying around.
   */
  const tabLabel = (t: Tab) => (t === 'main' && inLobby ? 'Menu' : TAB_LABEL[t])

  // F1 CLOSES IT TOO, because the lobby's handler opens it on F1 and the map
  // card two hundred lines down promises "the same key that opened this menu
  // closes it again". A menu that answers a key on the way in and ignores it on
  // the way out is the kind of small lie players stop trusting the rest of the
  // screen over.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape' && e.key !== 'F1') return
      e.preventDefault()
      e.stopPropagation()
      play('ui.back')
      // Escape backs OUT one level rather than closing outright: a confirm
      // that cannot be cancelled with Escape is a confirm people click
      // through by reflex.
      if (confirming) { setConfirming(null); return }
      if (tab !== 'main') { setTab('main'); return }
      close()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  const act = (id: string) => {
    play('ui.select')
    void fetchNui(CB.PAUSE_ACTION, { action: id })
    setConfirming(null)
    // Everything left here takes the screen away by itself, so nothing needs
    // to close the menu on the way out.
  }

  return (
    <div
      className="interactive fixed inset-0 z-[55] overflow-y-auto thin-scroll"
      style={{ backgroundColor: 'rgba(6, 8, 14, 0.965)' }}
    >
      <div className="mx-auto py-10" style={{ width: '68rem', maxWidth: '92vw' }}>
        <div className="flex items-end justify-between mb-8">
          <div>
            {/* NOTHING IS PAUSED IN THE LOBBY. The word is accurate mid-match
                and simply wrong on a screen where no round is running, and a
                menu that opens claiming to have stopped something that was
                never going is a menu people distrust. */}
            <div className="micro-label">{inLobby ? 'Lobby' : 'Paused'}</div>
            <h2 className="font-display text-[3rem] uppercase tracking-[0.1em] leading-none mt-1">
              {tabLabel(tab)}
            </h2>
          </div>
          {/* LEVEL AND XP, VISIBLE MID-MATCH. The lobby is not the only
              place a player wonders where they are -- and the pause menu is
              the one screen they can reach without dying. */}
          <div className="flex items-end gap-6">
            <div style={{ width: '20rem' }}><Progress /></div>
          {/* THE MAP IS NOT UP HERE ANY MORE. It was a small plate wedged
              among the tabs, which is where a secondary destination goes --
              and the map is the single most likely reason anybody opens this
              menu at all (user, 2026-08-09). It is the hero of the Match tab
              now; these are just the tabs. */}
          <div className="flex gap-2">
            {(['main', 'notices', 'help', 'settings'] as Tab[]).map((t) => (
              <button
                key={t}
                type="button"
                className={`btn plate px-4 py-2 font-display uppercase tracking-[0.12em]
                            text-[0.8rem]${tab === t ? ' is-active' : ''}`}
                style={{
                  ['--edgec' as string]: tab === t
                    ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)',
                  ['--plate-fill' as string]: tab === t
                    ? 'rgba(12,58,72,0.94)' : 'rgba(24,28,40,0.92)',
                  ['--cut-max' as string]: '0.45rem',
                }}
                onPointerEnter={() => play('ui.hover')}
                onClick={() => { play('ui.select'); setTab(t) }}
              >
                {tabLabel(t)}
              </button>
            ))}
          </div>
          </div>
        </div>

        {tab === 'main' ? (
          <>
            {/* THE MAP, FRONT AND CENTRE.
                Full width, above the exits, and the only primary on the
                screen. Everything else on this tab ends something; this is the
                one thing a player opens the menu to LOOK at, and it should not
                have to be found.

                NOT IN THE LOBBY, AND THE REASON IS #122 RATHER THAN TASTE. The
                map route raises GTA's own frontend (BR.Pause.openFrontendMap),
                and unlike the settings handover it does NOT announce the
                frontend to this page -- it never needed to, because until #83
                it could only be reached from a match, where every screen of
                ours follows focus and goes quiet by itself. The lobby does not:
                it is drawn from match state, so it would have carried on
                painting straight over the scaleform, which is the precise
                report #122 was filed for. There is also nothing on the map
                worth opening from a lobby you have not dropped into yet. */}
            {!inLobby && (
            <div
              className="plate p-5 mb-4 flex items-center gap-6"
              style={{
                ['--edgec' as string]: 'var(--color-royale-accent)',
                ['--plate-fill' as string]: 'rgba(12,40,50,0.94)',
                ['--cut-max' as string]: '0.8rem',
              }}
            >
              <div className="flex-1 min-w-0">
                <div className="font-display text-[1.6rem] uppercase tracking-[0.08em] leading-none">
                  Map
                </div>
                <div className="body-text mt-1.5">
                  The full-screen map. The same key that opened this menu closes it again.
                </div>
              </div>
              <Btn
                variant="primary"
                size="lg"
                cue="ui.select"
                onPress={() => {
                  play('ui.select')
                  void fetchNui(CB.PAUSE_ACTION, { action: 'map' })
                }}
              >
                Open map
              </Btn>
            </div>
            )}

            {/* THERE WAS A "GRAPHICS & DISPLAY" ROW HERE AND IT IS GONE (#145).
                #122 put it on this page because GTA's own settings were hard to
                find, and it worked -- the owner's follow-up is not that the
                handover was wrong but that this is the wrong page for it:
                "Graphics and display do not need to be a front-page option in
                the pause menu on the Match tab."

                THE ROUTE IS NOT REMOVED, ONLY THIS SHORTCUT TO IT. The same
                handover still lives in Settings, under a heading that says
                Graphics, which is where somebody who has stopped playing to
                change their texture quality is already looking. What this page
                is for is the things you do WITHOUT stopping -- the map, your
                party, the exits -- and every row that is not one of those makes
                the ones that are harder to find. */}

            {/* THE PARTY, SQUADS ONLY. In solo there is no squad to recruit
                from and no party that would outlive the match, so the card is
                absent rather than empty.

                AND NOT IN THE LOBBY, where the lobby's own party panel is
                already on screen behind this menu and is the fuller of the two.
                Two party controls one keypress apart, disagreeing the moment a
                roster update reaches one before the other, is how "doesn't seem
                like anything is working other than leave party" starts. */}
            {match.mode === 'squad' && !inLobby && <PartyCard />}

            {/* ONE CARD, THREE ROWS, FULL WIDTH (owner's call, 2026-08-09).
                Three separate plates gave three ways of leaving the same
                visual weight as the map and ate half the screen -- which is
                backwards, because leaving is the thing a player does once and
                the map is the thing they do constantly. As rows they read as
                one list of exits, in increasing order of what they cost you,
                and the whole block is shorter than any two of the old cards. */}
            <div
              className="plate px-5 py-2"
              style={{
                ['--edgec' as string]: 'rgba(255,255,255,0.16)',
                ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
                ['--cut-max' as string]: '0.6rem',
              }}
            >
              {/* "BACK TO LOBBY" IS NOT ON OFFER IN THE LOBBY (#83).
                  It forfeits a match, and from here there is no match to
                  forfeit -- br_core would refuse it, so the row would be a
                  button that confirms something destructive and then does
                  nothing, which is worse than the button being absent. What
                  remains is Leave server, which is the row this issue is
                  about and the only exit that means anything from here.

                  The list is filtered rather than the row being hidden inside
                  the map, so `i === 0` still picks out the genuinely first row
                  and the card does not open with a divider above nothing. */}
              {EXITS.filter((e) => !(inLobby && e.id === 'lobby')).map((e, i) => (
                <div
                  key={e.id}
                  className="flex items-center gap-6 py-3"
                  style={{
                    borderTop: i === 0 ? undefined : '1px solid rgba(255,255,255,0.07)',
                  }}
                >
                  <div className="flex-1 min-w-0">
                    {/* `.ts` AND AN EXPLICIT --fs, not `tscale`. tscale
                        multiplies 1em, which is the PARENT's size -- so on
                        text that declares its own it either loses (a later
                        rule wins, which is what happened to every
                        micro-label) or silently discards the declared size.
                        Twice now the text-size preference moved the HUD and
                        the settings screen and left these cards alone (user,
                        2026-08-09). See the note on .ts in index.css. */}
                    <div
                      className="font-display uppercase tracking-[0.08em] ts"
                      style={{ ['--fs' as string]: '1.05rem' }}
                    >
                      {e.label}
                    </div>
                    {/* The confirm REPLACES the description rather than
                        appearing under it: the row keeps its height, so
                        answering a confirm never shoves the rows below it. */}
                    <div
                      className="body-text mt-0.5"
                      style={{
                        color: confirming === e.id ? 'var(--color-danger)' : undefined,
                      }}
                    >
                      {confirming === e.id
                      ? (e.id === 'lobby' && inParty
                          ? `${e.confirm} You will also leave your party.`
                          : e.confirm)
                      : e.sub}
                    </div>
                  </div>

                  {confirming === e.id ? (
                    <div className="flex gap-2 shrink-0">
                      <Btn variant="danger" size="sm" cue="ui.select"
                           onPress={() => act(e.id)}>
                        {e.yes ?? e.label}
                      </Btn>
                      <Btn variant="default" size="sm" cue="ui.back"
                           onPress={() => setConfirming(null)}>
                        {e.no ?? 'Cancel'}
                      </Btn>
                    </div>
                  ) : (
                    <div className="shrink-0">
                      <Btn
                        variant={e.variant}
                        size="sm"
                        cue={e.variant === 'danger' ? 'ui.back' : 'ui.select'}
                        onPress={() => {
                          if (e.confirm) { play('ui.back'); setConfirming(e.id); return }
                          act(e.id)
                        }}
                      >
                        {e.action ?? e.label}
                      </Btn>
                    </div>
                  )}
                </div>
              ))}
            </div>

            {/* RESUME IS BLUE (owner's call, 2026-08-09). It and Map are the
                two things on this screen that do not end anything, and they
                read as a pair -- which is the argument for both being loud
                rather than for neither being. The Esc hint is gone: the key
                is the same one that opened the menu, and a player who got
                here knows it. */}
            {/* AND IT SAYS "BACK TO LOBBY" IN THE LOBBY, because there is
                nothing to resume there -- the same reason the eyebrow above
                does not say "Paused". There is no collision with the match
                exit of that name: that row is filtered out on this screen, so
                the words are free and they are the truest ones available. */}
            <div className="mt-6">
              <Btn variant="primary" size="lg" cue="ui.back" onPress={close}>
                {inLobby ? 'Back to lobby' : 'Resume'}
              </Btn>
            </div>
          </>
        ) : tab === 'notices' ? (
          <NoticeLog />
        ) : tab === 'help' ? (
          // THE FULL PAGE, not a cramped tab body (owner's call, 2026-08-09:
          // "make the pause menu help back to full page"). `onDone` is what
          // makes Back work here -- it hands the close to this menu instead of
          // releasing a focus that was never taken.
          <Help onDone={() => setTab('main')} />
        ) : (
          // THE LOBBY'S SETTINGS SCREEN, EMBEDDED. `inline` drops its own
          // full-screen backdrop and its Cancel/Save footer closes the tab
          // rather than the whole menu.
          <Settings inline onDone={() => setTab('main')} />
        )}
      </div>
    </div>
  )
}
