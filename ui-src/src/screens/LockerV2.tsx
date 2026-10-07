import { useEffect, useRef, useState } from 'react'
import { AnimatePresence, motion, type Variants } from 'framer-motion'
import Box from '@cloudscape-design/components/box'
import SegmentedControl from '@cloudscape-design/components/segmented-control'
import Spinner from '@cloudscape-design/components/spinner'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import { useNuiEvent } from '../bridge/useNuiEvent'
import { play } from '../audio/cues'
import { LOCKED_TAB, TAB_LABEL } from './lockerv2/copy'
import {
  doneSteps, editFor, escapeAction, followTab, isCustom, openingTab, saveVariant, slideDir,
  slideEnds, tabOptions, tabsShown, type Tab,
} from './lockerv2/model'
import { useCloudscapeScope, useIslandZoom, usePortalZoom } from './lockerv2/scope'
import { keepShot, takeShot } from './lockerv2/shots'
import { CustomTab, PedsTab, StockTab } from './lockerv2/Tabs'
import { Footer } from './lockerv2/Footer'
import { LockerModal, type ModalState } from './lockerv2/Modals'

/**
 * LOCKER V2 (#28): Season 2's locker. Season 1's is screens/Locker.tsx, the
 * finished product, untouched; App.tsx picks between them on the `locker2`
 * envelope's `on`, which is BR.Season.has('locker2').
 *
 * The owner's picture, in his words: "a segmented control component at the top
 * where they have the options of "Stock peds", "Custom (male)" and "Custom
 * (female)" - any non-selected tab must be disabled while unsaved changes are
 * present. Selecting a disabled tab must show a hover card explaining why it's
 * disabled." Then My peds once anything is saved; the edited ped's name under
 * the control; the body sliding toward the tab picked; Save and Reset pinned
 * where Done sits; and Done asking before it throws changes away.
 *
 * THE RIGHT OF THE SCREEN IS STILL THE PED, as in Season 1: the panel and its
 * scrim take the left, and a drag anywhere else turns the character
 * (LOCKER_SPIN, reused).
 *
 * THE ISLAND. Cloudscape draws in px; this interface is in rem. Everything
 * Cloudscape renders sits inside one element zoomed by root px / 14 (contract
 * section 5), so its 14 px text is one rem and the interface-size slider
 * reaches it. Inside the island lengths are in em -- the island's font size is
 * 1rem / z, so one em there is one rem on screen -- because rem inside a zoom
 * is counted twice. The island clips its overflow: that is the bound
 * Cloudscape's Save menu measures its room against.
 *
 * LUA OWNS EVERYTHING DRAWN. Rows, the worn ped, the saved list: the page
 * asks (LOCKER2_* callbacks) and renders what comes back. The one thing it
 * moves ahead of Lua is the tab, so the slide starts on the press; each
 * request is numbered, and once a push says Lua has seen the latest, the page
 * shows Lua's tab (model.ts followTab) -- a refusal takes it back, and Edit's
 * move to the saved ped's tab is followed the same way.
 */

/** The page's LOCKER2_TAB requests, numbered across every opening, so a push
 *  from an earlier opening can never pass for an answer to this one. */
let tabRequests = 0

/** The slide: transform and opacity only (contract section 5, check-ui R7). */
const SLIDE: Variants = {
  enter: (d: -1 | 0 | 1) => ({ x: `${slideEnds(d).enter * 14}%`, opacity: 0 }),
  center: { x: '0%', opacity: 1 },
  exit: (d: -1 | 0 | 1) => ({ x: `${slideEnds(d).exit * 14}%`, opacity: 0 }),
}

export default function LockerV2() {
  useCloudscapeScope()
  const z = useIslandZoom()
  usePortalZoom(z)

  const st = useUi((s) => s.locker2)
  const fetching = st.fetching === true
  const [tab, setTab] = useState<Tab>(() => openingTab(st.peds.length, fetching))
  const [dir, setDir] = useState<-1 | 0 | 1>(0)
  const [modal, setModal] = useState<ModalState | null>(null)
  const [modalRoot, setModalRoot] = useState<HTMLDivElement | null>(null)

  const shownTab = useRef(tab)
  /** This opening's latest LOCKER2_TAB; -1 until it has sent one. */
  const sent = useRef(-1)
  const go = (t: Tab) => {
    const cur = shownTab.current
    if (cur === t) return
    shownTab.current = t
    setDir(slideDir(cur, t))
    setTab(t)
  }
  const request = (t: Tab) => {
    tabRequests++
    sent.current = tabRequests
    void fetchNui(CB.LOCKER2_TAB, { tab: t, seq: tabRequests })
  }
  const ask = (t: Tab) => {
    go(t)
    request(t)
  }

  // OPEN: Lua pushes the state and cleans and dries the ped ("Physically clean
  // and dry the ped using natives when they enter the new locker UI", owner),
  // then shows the ped for the tab this page opens on.
  useEffect(() => {
    void (async () => {
      await fetchNui(CB.LOCKER2_OPEN)
      request(shownTab.current)
    })()
  }, [])

  // LUA'S TAB, once it has seen this page's latest request: a refusal goes
  // back, Edit goes to the saved ped's Custom tab.
  useEffect(() => {
    go(followTab(shownTab.current, st.tab, st.tabSeq ?? null, sent.current))
  }, [st])

  // My peds went away under the player (the last one deleted, or the fetch
  // answered none): Stock, as the locker would have opened on.
  const shown = tabsShown(st.peds.length, fetching)
  useEffect(() => {
    if (!shown.includes(tab)) ask('stock')
  })

  // A headshot is ready in Lua: a texture to draw, or a stored picture.
  useNuiEvent('locker2shot', (d) => {
    if (d?.img !== undefined) keepShot(d.id, d.up, d.img)
    else takeShot(d?.id, d?.txd)
  })

  const edit = editFor(tab, st.edit)
  const dirty = edit?.dirty === true
  const busy = st.busy === true
  const blocked = st.locked === true || !!st.loading || busy
  const editingName = edit?.editing ? st.peds.find((p) => p.id === edit.editing)?.name ?? null : null

  // DONE, in model.ts's order: ask first if there is anything to lose; then
  // `close` (Lua discards the draft and puts the worn ped back), and only once
  // Lua has answered, the cursor back.
  const done = (confirmed: boolean) => {
    const steps = doneSteps(dirty, confirmed)
    if (steps[0]?.do === 'confirm') { setModal({ kind: 'discard' }); return }
    play('ui.back')
    void (async () => {
      for (const s of steps) {
        if (s.do === 'close') await fetchNui(CB.LOCKER2_CLOSE)
        else if (s.do === 'unfocus') await fetchNui(CB.LOCKER_FOCUS, { open: false })
      }
    })()
  }

  // ESCAPE closes the open dialog alone, else it is Done. Capture phase, so it
  // is ours before Cloudscape's own handlers or the lobby's pause key see it.
  const live = useRef({ modal, done })
  live.current = { modal, done }
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      if (escapeAction(live.current.modal !== null) === 'modal') { setModal(null); return }
      live.current.done(false)
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [])

  const confirmModal = (m: ModalState, name: string) => {
    setModal(null)
    play('ui.select')
    switch (m.kind) {
      case 'name': void fetchNui(CB.LOCKER2_SAVE, { op: 'new', name }); break
      case 'rename': void fetchNui(CB.LOCKER2_RENAME, { id: m.id, name }); break
      case 'replace': void fetchNui(CB.LOCKER2_SAVE, { op: 'replace', id: m.id }); break
      case 'delete': void fetchNui(CB.LOCKER2_DELETE, { id: m.id }); break
      case 'discard': done(true); break
    }
  }

  // Drag the empty side to turn the ped, exactly as Season 1 does.
  const dragging = useRef(false)
  const lastX = useRef(0)
  const onDown = (e: React.PointerEvent) => {
    dragging.current = true
    lastX.current = e.clientX
    try { e.currentTarget.setPointerCapture(e.pointerId) } catch { /* no capture */ }
  }
  const onMove = (e: React.PointerEvent) => {
    if (!dragging.current) return
    const dx = e.clientX - lastX.current
    lastX.current = e.clientX
    if (dx !== 0) void fetchNui(CB.LOCKER_SPIN, { delta: dx * 0.4 })
  }
  const onUp = (e: React.PointerEvent) => {
    dragging.current = false
    try { e.currentTarget.releasePointerCapture(e.pointerId) } catch { /* already gone */ }
  }

  const options = tabOptions({
    pedCount: st.peds.length, fetching, current: tab, dirty, blocked,
  }).map((o) => ({
    id: o.id,
    text: TAB_LABEL[o.id],
    disabled: o.disabled,
    disabledReason: o.explained ? LOCKED_TAB : undefined,
  }))

  let body: React.ReactNode
  if (tab === 'stock') {
    body = <StockTab st={st} z={z} />
  } else if (tab === 'peds') {
    body = fetching
      ? <div style={{ display: 'flex', justifyContent: 'center', paddingTop: '2em' }}><Spinner size="large" /></div>
      : (
        <PedsTab
          st={st}
          blocked={blocked}
          onEdit={(p) => { void fetchNui(CB.LOCKER2_EDIT, { id: p.id }) }}
          onCreate={() => ask('male')}
          onRename={(p) => setModal({ kind: 'rename', id: p.id, name: p.name })}
          onDelete={(p) => setModal({ kind: 'delete', id: p.id, name: p.name })}
        />
      )
  } else {
    body = <CustomTab edit={edit} disabled={blocked} />
  }

  return (
    <div className="interactive fixed inset-0 z-50">
      <div
        className="absolute inset-0 cursor-ew-resize"
        onPointerDown={onDown}
        onPointerMove={onMove}
        onPointerUp={onUp}
        onPointerCancel={onUp}
      />
      {/* Season 1's scrim, wider for the anchor column: the left for the
          panel, the rest for the character. */}
      <div
        className="absolute inset-y-0 left-0 w-[56%] pointer-events-none"
        style={{
          background: 'linear-gradient(90deg, rgba(6,8,14,0.94) 0%, '
                    + 'rgba(6,8,14,0.86) 60%, rgba(6,8,14,0) 100%)',
        }}
      />
      <div className="absolute inset-y-0 left-0 w-[42rem] max-w-[60vw] px-[3.5rem] py-[3rem] flex flex-col pointer-events-none">
        <div
          className="br-cs flex min-h-0 flex-1 flex-col overflow-hidden pointer-events-auto"
          style={{ zoom: z, fontSize: `calc(1rem / ${z})` }}
        >
          <div style={{ flex: '0 0 auto' }}>
            <SegmentedControl
              selectedId={tab}
              options={options}
              onChange={({ detail }) => {
                const t = detail.selectedId as Tab
                if (t === tab) return
                play('ui.select')
                ask(t)
              }}
            />
          </div>
          {editingName !== null && (
            <div style={{ flex: '0 0 auto', paddingTop: '0.75em' }}>
              <Box variant="h3">{editingName}</Box>
            </div>
          )}
          <div className="relative min-h-0 flex-1 overflow-hidden" style={{ marginTop: '1em' }}>
            <AnimatePresence initial={false} custom={dir}>
              <motion.div
                key={tab}
                custom={dir}
                variants={SLIDE}
                initial="enter"
                animate="center"
                exit="exit"
                transition={{ duration: 0.24, ease: [0.22, 1, 0.36, 1] }}
                className="absolute inset-0 flex flex-col"
              >
                {body}
              </motion.div>
            </AnimatePresence>
          </div>
          <Footer
            z={z}
            custom={isCustom(tab)}
            dirty={dirty}
            busy={blocked}
            save={saveVariant({ dirty, editing: edit?.editing ?? null, peds: st.peds })}
            onDone={() => done(false)}
            onReset={() => { play('ui.select'); void fetchNui(CB.LOCKER2_RESET) }}
            onName={() => { play('ui.select'); setModal({ kind: 'name' }) }}
            onUpdate={(id) => { play('ui.select'); void fetchNui(CB.LOCKER2_SAVE, { op: 'update', id }) }}
            onReplace={(id) => {
              const p = st.peds.find((x) => x.id === id)
              if (p) { play('ui.select'); setModal({ kind: 'replace', id: p.id, name: p.name }) }
            }}
          />
          <div ref={setModalRoot} className="pointer-events-auto" />
        </div>
      </div>
      <LockerModal modal={modal} root={modalRoot} onClose={() => setModal(null)} onConfirm={confirmModal} />
    </div>
  )
}
