import { useEffect, useState } from 'react'
import { useUi, selSquad } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import Settings from './Settings'
import { play } from '../audio/cues'
import Progress from './Progress'
import NoticeLog from './NoticeLog'
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
  {
    id: 'squad', label: 'Leave squad', variant: 'default', squadOnly: true,
    action: 'Leave squad',
    // Deliberately NOT immediate: pulling someone out of a squad mid-match
    // would strip their teammates' health bars and blips in the middle of a
    // fight, which punishes three people for one person's decision.
    sub: 'You stay with them for this match, then split at the end.',
  },
  {
    id: 'server', label: 'Leave server', variant: 'danger',
    action: 'Disconnect',
    sub: 'Disconnects you from FiveM Royale.',
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
  const squad = useUi(selSquad)
  const inSquad = squad.members.length > 1

  const close = () => { void fetchNui(CB.PAUSE_FOCUS, { open: false }) }

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
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
    // Leaving the squad keeps you in the match, so the menu shuts and play
    // resumes. Everything else is about to take the screen away anyway.
    if (id === 'squad') close()
  }

  return (
    <div
      className="interactive fixed inset-0 z-[55] overflow-y-auto thin-scroll"
      style={{ backgroundColor: 'rgba(6, 8, 14, 0.965)' }}
    >
      <div className="mx-auto py-10" style={{ width: '68rem', maxWidth: '92vw' }}>
        <div className="flex items-end justify-between mb-8">
          <div>
            <div className="micro-label">Paused</div>
            <h2 className="font-display text-[3rem] uppercase tracking-[0.1em] leading-none mt-1">
              {TAB_LABEL[tab]}
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
                {TAB_LABEL[t]}
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
                have to be found. */}
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
                <div className="micro-label mt-1.5" style={{ textTransform: 'none' }}>
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

            <div className="grid grid-cols-2 gap-3">
              {EXITS.filter((e) => !e.squadOnly || inSquad).map((e) => (
                <div
                  key={e.id}
                  className="plate p-4 flex flex-col gap-2"
                  style={{
                    ['--edgec' as string]: e.variant === 'danger'
                      ? 'var(--color-danger-edge)' : 'rgba(255,255,255,0.16)',
                    ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
                    ['--cut-max' as string]: '0.6rem',
                  }}
                >
                  {/* tscale, like every other line of prose in the interface.
                      These cards were plain rem, so the text-size preference
                      moved the HUD and the settings screen and left the pause
                      menu exactly as it was (user, 2026-08-09). A card grows
                      with its content, which is precisely the shape that can
                      honour it. */}
                  <div className="font-display text-[1.15rem] uppercase tracking-[0.08em] tscale">
                    {e.label}
                  </div>
                  <div className="micro-label tscale" style={{ textTransform: 'none' }}>
                    {e.sub}
                  </div>

                  {confirming === e.id ? (
                    <div className="mt-1">
                      <div
                        className="text-[0.8rem] mb-2 tscale"
                        style={{ color: 'var(--color-danger)' }}
                      >
                        {e.confirm}
                      </div>
                      <div className="flex gap-2">
                        <Btn variant="danger" size="sm" cue="ui.select"
                             onPress={() => act(e.id)}>
                          {e.yes ?? e.label}
                        </Btn>
                        <Btn variant="default" size="sm" cue="ui.back"
                             onPress={() => setConfirming(null)}>
                          {e.no ?? 'Cancel'}
                        </Btn>
                      </div>
                    </div>
                  ) : (
                    <div className="mt-1">
                      <Btn
                        variant={e.variant}
                        size="md"
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
            <div className="mt-6">
              <Btn variant="primary" size="lg" cue="ui.back" onPress={close}>
                Resume
              </Btn>
            </div>
          </>
        ) : tab === 'notices' ? (
          <NoticeLog />
        ) : tab === 'help' ? (
          <Help />
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
