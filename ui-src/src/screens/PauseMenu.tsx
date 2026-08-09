import { useEffect, useState } from 'react'
import { useUi, selSquad } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import Settings from './Settings'
import { play } from '../audio/cues'
import Progress from './Progress'

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

type Tab = 'main' | 'settings'

/** Actions that end something. `confirm` gates the ones you cannot undo. */
const EXITS: {
  id: 'lobby' | 'squad' | 'server' | 'quit'
  label: string
  sub: string
  variant: 'default' | 'danger'
  confirm?: string
  squadOnly?: boolean
}[] = [
  {
    id: 'lobby', label: 'Back to lobby', variant: 'default',
    sub: 'Forfeits this match. Your squad plays on.',
    confirm: 'Leave the match? You will be eliminated.',
  },
  {
    id: 'squad', label: 'Leave squad', variant: 'default', squadOnly: true,
    // Deliberately NOT immediate: pulling someone out of a squad mid-match
    // would strip their teammates' health bars and blips in the middle of a
    // fight, which punishes three people for one person's decision.
    sub: 'You stay with them for this match, then split at the end.',
  },
  {
    id: 'server', label: 'Leave server', variant: 'danger',
    sub: 'Disconnects you from FiveM Royale.',
    confirm: 'Disconnect from the server?',
  },
  // QUIT FIVEM IS NOT HERE, and cannot be. The client's own `quit` console
  // command is restricted -- "Access denied" -- and there is no server-side
  // equivalent: a server can drop you from itself, not close your game. An
  // option that cannot work is worse than one that is absent, so it is
  // absent (user, 2026-08-09). Alt+F4 and FiveM's own menu still exist.
]

export default function PauseMenu() {
  const [tab, setTab] = useState<Tab>('main')
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
              {tab === 'main' ? 'Match' : 'Settings'}
            </h2>
          </div>
          {/* LEVEL AND XP, VISIBLE MID-MATCH. The lobby is not the only
              place a player wonders where they are -- and the pause menu is
              the one screen they can reach without dying. */}
          <div className="flex items-end gap-6">
            <div style={{ width: '20rem' }}><Progress /></div>
          <div className="flex gap-2">
            {(['main', 'settings'] as Tab[]).map((t) => (
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
                {t === 'main' ? 'Match' : 'Settings'}
              </button>
            ))}
            {/* THE MAP IS A DESTINATION, so it sits with the other two --
                and it is not a tab, because it hands the screen to the game
                rather than swapping a pane. SetBigmapActive draws GTA's full
                map over live gameplay with no frontend and no pause; the
                same key that opened this menu closes it again. */}
            <button
              type="button"
              className="btn plate px-4 py-2 font-display uppercase tracking-[0.12em]
                         text-[0.8rem]"
              style={{
                ['--edgec' as string]: 'rgba(255,255,255,0.16)',
                ['--plate-fill' as string]: 'rgba(24,28,40,0.92)',
                ['--cut-max' as string]: '0.45rem',
              }}
              onPointerEnter={() => play('ui.hover')}
              onClick={() => {
                play('ui.select')
                void fetchNui(CB.PAUSE_ACTION, { action: 'map' })
              }}
            >
              Map
            </button>
          </div>
          </div>
        </div>

        {tab === 'main' ? (
          <>
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
                  <div className="font-display text-[1.15rem] uppercase tracking-[0.08em]">
                    {e.label}
                  </div>
                  <div className="micro-label" style={{ textTransform: 'none' }}>
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
                          Yes
                        </Btn>
                        <Btn variant="default" size="sm" cue="ui.back"
                             onPress={() => setConfirming(null)}>
                          Cancel
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
                        {e.confirm ? 'Continue' : e.label}
                      </Btn>
                    </div>
                  )}
                </div>
              ))}
            </div>

            {/* RESUME IS THE ONLY PRIMARY, AND IT IS ALONE.
                It sat next to Map wearing the brand colour, which made two
                unrelated things look like a pair of equals -- one closes this
                menu, the other opens a different view (user, 2026-08-09).
                Map has moved up beside the tabs, where destinations live. */}
            <div className="mt-6">
              <Btn variant="primary" size="lg" cue="ui.back" onPress={close}>
                Resume
              </Btn>
            </div>
          </>
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
