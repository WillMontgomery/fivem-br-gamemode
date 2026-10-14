import { useCallback, useEffect, useRef, useState } from 'react'
import Button from '@cloudscape-design/components/button'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { Locker2Ped } from '../bridge/types'
import { useNuiEvent } from '../bridge/useNuiEvent'
import { play } from '../audio/cues'
import { BTN, TITLE } from './lockerv2/copy'
import {
  NEW_DEFAULT, backSteps, createStep, escapeAction, followView, popupOpen, saveDialogFor, saveEnabled, saveRequest,
  type NewPick, type View,
} from './lockerv2/model'
import { useAfterPaint, useCloudscapeScope, useIslandZoom, usePortalZoom } from './lockerv2/scope'
import { keepShot, takeShot } from './lockerv2/shots'
import { keepTats } from './lockerv2/tattooLists'
import { keepPal } from './lockerv2/palette'
import { CameraStage } from './lockerv2/Camera'
import { Editor } from './lockerv2/Editor'
import { Home, type CardAction } from './lockerv2/Home'
import { NewChoice, StockList } from './lockerv2/NewLook'
import { LockerModal, type Choice, type ModalState } from './lockerv2/Modals'
import { escapeHeld } from '../tutorial/lockGuard'
import { AWAY_ATTR } from '../tutorial/progress'
import './lockerv2/lockerv2.css'

export { warmTheme } from './lockerv2/scope'

/**
 * LOCKER V2 (#28): Season 2's locker, "My Looks". Season 1's is
 * screens/Locker.tsx, the finished product, untouched; App.tsx picks between
 * them on the `locker2` envelope's `on`, which is BR.Season.has('locker2').
 *
 * THE OWNER'S FLOW (2026-10-12/13, recorded on #28): "let's get rid of the
 * top left/right select bar, and move to a new flow". Four views, each with
 * its heading at the top and its way out at the bottom left:
 *
 *   MY LOOKS   the saved looks as cards (lockerv2/Home.tsx); New at the top;
 *              Done closes the locker.
 *   NEW        Custom (selected as it opens, with a Male / Female dropdown)
 *              and Stock GTA Looks (lockerv2/NewLook.tsx): a press selects
 *              one, Create goes on with it; Back.
 *   STOCK      the stock roster, worn on a press; Back to New.
 *   EDITOR     Randomize / Undo / Redo, the summary list and one category's
 *              panel (lockerv2/Editor.tsx); Back, which asks if unsaved, and
 *              Save, which opens the save dialog -- with "Save as new" only
 *              for a look opened from My Looks (model.ts saveDialogFor).
 *
 * THE RIGHT OF THE SCREEN IS STILL THE PED, as in Season 1: the panel and its
 * scrim take the left, a drag anywhere else turns the character, the wheel
 * zooms, and the camera buttons stand in a row across the bottom, under the
 * ped (lockerv2/Camera.tsx).
 *
 * THE ISLAND. Cloudscape draws in px; this interface is in rem. Everything
 * Cloudscape renders sits inside one element zoomed by root px / 14 (contract
 * section 5), so its 14 px text is one rem and the interface-size slider
 * reaches it. Inside the island lengths are in em -- the island's font size is
 * 1rem / z, so one em there is one rem on screen -- because rem inside a zoom
 * is counted twice. The island clips its overflow: that is the bound
 * Cloudscape's dropdowns measure their room against.
 *
 * LUA OWNS EVERYTHING DRAWN. Rows, the worn look, the saved list: the page
 * asks (LOCKER2_* callbacks) and renders what comes back. The one thing it
 * moves ahead of Lua is the view, so the editor opens on the press; each
 * request that starts or ends a draft is numbered, and once a push says Lua
 * has seen the latest, Lua's draft decides (model.ts followView).
 *
 * IT OPENS FAST (the lag report, #28, 2026-10-13): the theme is built once
 * and only inserted (scope.ts), the preloaded chunk is drawn without
 * suspending (Gate.tsx), the chunk's stylesheet is off while the locker is
 * shut (sheet.ts), the open sends LOCKER2_OPEN alone, the screen subscribes
 * to the few fields it draws, and the views' bodies mount a frame after the
 * frame around them (useAfterPaint) so the fade-in plays.
 */

/** The page's numbered requests (LOCKER2_NEW, _EDIT, _LEAVE), across every
 *  opening, so a push from an earlier opening can never pass for an answer to
 *  this one. */
let requests = 0

/** The body last picked on New's Custom card, for the session. */
let lastSex: 'm' | 'f' = 'm'

export default function LockerV2() {
  useCloudscapeScope()
  const z = useIslandZoom()
  usePortalZoom(z)
  const ready = useAfterPaint()

  // THE FIELDS THIS FRAME DRAWS, AND NO MORE: a push redraws it only when
  // one of them moves. The views read their own.
  const hasDraft = useUi((s) => s.locker2.edit != null)
  const dirty = useUi((s) => s.locker2.edit?.dirty === true)
  const editing = useUi((s) => s.locker2.edit?.editing ?? null)
  const tabSeq = useUi((s) => s.locker2.tabSeq ?? null)
  const busy = useUi((s) => s.locker2.busy === true)
  const blocked = useUi((s) => s.locker2.locked === true || s.locker2.loading != null || s.locker2.busy === true)
  const peds = useUi((s) => s.locker2.peds)

  const [view, setView] = useState<View>('home')
  const [pick, setPick] = useState<NewPick>(NEW_DEFAULT)
  const [sex, setSex] = useState<'m' | 'f'>(lastSex)
  /** The draft was opened from My Looks with Edit (not made with New): its
   *  save dialog has "Save as new". */
  const [opened, setOpened] = useState(false)
  const [modal, setModal] = useState<ModalState | null>(null)
  const [modalRoot, setModalRoot] = useState<HTMLDivElement | null>(null)

  /** This opening's latest numbered request; -1 until it has sent one. */
  const sent = useRef(-1)
  const ask = (cb: typeof CB.LOCKER2_NEW | typeof CB.LOCKER2_EDIT | typeof CB.LOCKER2_LEAVE,
    data: Record<string, unknown>) => {
    requests++
    sent.current = requests
    void fetchNui(cb, { ...data, seq: requests })
  }

  // OPEN: LOCKER2_OPEN, and nothing else. Lua pushes the state and cleans and
  // dries the ped ("Physically clean and dry the ped using natives when they
  // enter the new locker UI", owner).
  useEffect(() => { void fetchNui(CB.LOCKER2_OPEN) }, [])

  // LUA'S DRAFT, once it has seen this page's latest request.
  useEffect(() => {
    setView((v) => followView(v, hasDraft, tabSeq, sent.current))
  }, [hasDraft, tabSeq])

  // A headshot is ready in Lua: a texture to draw, or a stored picture.
  useNuiEvent('locker2shot', (d) => {
    if (d?.img !== undefined) keepShot(d.id, d.up, d.img)
    else takeShot(d?.id, d?.txd)
  })
  // A sex's tattoo list, and the color palettes, each the once it is asked for.
  useNuiEvent('locker2tats', (d) => keepTats(d))
  useNuiEvent('locker2pal', (d) => keepPal(d))

  // BACK, in model.ts's order: ask first if there is anything to lose; in the
  // editor LOCKER2_LEAVE; on My Looks `close` (Lua discards any draft and
  // puts the worn look back), and only once Lua has answered, the cursor back.
  const back = (confirmed: boolean) => {
    const steps = backSteps(view, dirty, confirmed)
    if (steps[0]?.do === 'confirm') { setModal({ kind: 'discard' }); return }
    play('ui.back')
    void (async () => {
      for (const s of steps) {
        if (s.do === 'leave') { setView('home'); ask(CB.LOCKER2_LEAVE, {}) }
        else if (s.do === 'view') setView(s.to)
        else if (s.do === 'close') await fetchNui(CB.LOCKER2_CLOSE)
        else if (s.do === 'unfocus') await fetchNui(CB.LOCKER_FOCUS, { open: false })
      }
    })()
  }

  // ESCAPE closes the open dialog alone, else it is the view's Back. Capture
  // phase, so it is ours before Cloudscape's own handlers or the lobby's pause
  // key see it -- except while a dropdown is open (a tattoo picker, a card's
  // menu, "+ Add"): then it is the dropdown's, and Cloudscape closes it.
  const screen = useRef<HTMLDivElement>(null)
  const live = useRef({ modal, back, view })
  live.current = { modal, back, view }
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      const act = escapeAction(live.current.view, live.current.modal !== null, escapeHeld(), popupOpen(screen.current))
      if (act === 'pass') return
      e.preventDefault()
      e.stopPropagation()
      if (act === 'modal') { setModal(null); return }
      if (act === 'back') live.current.back(false)
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [])

  const confirmModal = (m: ModalState, choice: Choice, name: string) => {
    setModal(null)
    play('ui.select')
    switch (m.kind) {
      case 'name': void fetchNui(CB.LOCKER2_SAVE, saveRequest({ kind: 'name' }, 'new', name)); break
      case 'save': void fetchNui(CB.LOCKER2_SAVE, saveRequest(m, choice === 'new' ? 'new' : 'update', name)); break
      case 'rename': void fetchNui(CB.LOCKER2_RENAME, { id: m.id, name }); break
      case 'delete': void fetchNui(CB.LOCKER2_DELETE, { id: m.id }); break
      case 'discard': back(true); break
    }
  }

  const onCard = useCallback((p: Locker2Ped, a: CardAction) => {
    play('ui.select')
    if (a === 'edit') { setOpened(true); setView('edit'); ask(CB.LOCKER2_EDIT, { id: p.id }) }
    else if (a === 'rename') setModal({ kind: 'rename', id: p.id, name: p.name })
    else setModal({ kind: 'delete', id: p.id, name: p.name })
    // `ask` and `setView` are this screen's own; nothing else here changes.
  }, [])

  const title = view === 'edit'
    ? peds.find((p) => p.id === editing)?.name ?? null
    : TITLE[view]

  // CREATE, on New: a new custom look of the body picked, or the roster.
  const create = () => {
    play('ui.select')
    const step = createStep(pick)
    if (step.do === 'view') { setView(step.to); return }
    setOpened(false)
    setView('edit')
    ask(CB.LOCKER2_NEW, { sex })
  }

  let body: React.ReactNode = null
  if (ready) {
    if (view === 'home') body = <Home blocked={blocked} onAction={onCard} />
    else if (view === 'new') {
      body = (
        <NewChoice blocked={blocked} pick={pick} sex={sex} onPick={setPick}
          onSex={(v) => { lastSex = v; setSex(v) }} />
      )
    } else if (view === 'stock') body = <StockList />
    else body = <Editor blocked={blocked} />
  }

  return (
    <div ref={screen} className="interactive fixed inset-0 z-50">
      <CameraStage />
      {/* Season 1's scrim, wider for the panel: the left for the panel, the
          rest for the character. */}
      <div
        className="absolute inset-y-0 left-0 w-[56%] pointer-events-none"
        style={{
          background: 'linear-gradient(90deg, rgba(6,8,14,0.94) 0%, '
                    + 'rgba(6,8,14,0.86) 60%, rgba(6,8,14,0) 100%)',
        }}
      />
      <div className="absolute inset-y-0 left-0 w-[44rem] max-w-[60vw] px-[3.5rem] py-[3rem] flex flex-col pointer-events-none">
        <div
          className="br-cs lk2 flex min-h-0 flex-1 flex-col overflow-hidden pointer-events-auto"
          style={{ zoom: z, fontSize: `calc(1rem / ${z})` }}
        >
          {/* A new look has no name yet: no heading, and the editor's strip
              takes its place. */}
          {title !== null && <div className="lk2-head">
            <h2 className="lk2-title lk2-fit"><span>{title}</span></h2>
            {view === 'home' && (
              <Button variant="primary" disabled={blocked}
                onClick={() => { play('ui.select'); setPick(NEW_DEFAULT); setView('new') }}>
                {BTN.new}
              </Button>
            )}
          </div>}
          <div className="lk2-body">{body}</div>
          {/* THE WALKTHROUGH'S "PRESS DONE" CARD rings Done, and a press
              inside its ring ends the card -- so the ring is on Done alone,
              on My Looks. Back, the way out of every other view, only goes up
              a view: inside, the foot says Done is away (AWAY_ATTR), and the
              card waits for it instead of moving on (#28 review: Back in the
              editor had walked the player on to the Market card). */}
          <div className="lk2-foot" {...(view === 'home' ? {} : { [AWAY_ATTR]: 'locker-done' })}>
            {/* DONE'S ANCHOR STEPS OUT OF THE ZOOM. The ring is drawn from
                `[data-tut="locker-done"]`'s box, and on CEF 103 a box inside
                a zoomed element is reported in that element's px. So the
                anchor wears 1/z inside the island -- a true zoom of 1 -- and
                the button inside it wears z again. */}
            {view === 'home' ? (
              <span data-tut="locker-done" style={{ display: 'inline-block', zoom: 1 / z }}>
                <span style={{ display: 'inline-block', zoom: z }}>
                  <Button onClick={() => back(false)}>{BTN.done}</Button>
                </span>
              </span>
            ) : (
              <Button onClick={() => back(false)}>{BTN.back}</Button>
            )}
            {view === 'new' && (
              <Button variant="primary" disabled={blocked} onClick={create}>{BTN.create}</Button>
            )}
            {view === 'edit' && (
              <Button variant="primary" disabled={!hasDraft || !saveEnabled(editing, dirty, busy)}
                onClick={() => {
                  play('ui.select')
                  setModal(saveDialogFor(editing, peds, opened))
                }}>
                {BTN.save}
              </Button>
            )}
          </div>
          <div ref={setModalRoot} className="pointer-events-auto" />
        </div>
      </div>
      <LockerModal modal={modal} root={modalRoot} onClose={() => setModal(null)} onConfirm={confirmModal} />
    </div>
  )
}
