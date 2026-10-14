import { useEffect, useRef, useState } from 'react'
import Button from '@cloudscape-design/components/button'
import Tabs from '@cloudscape-design/components/tabs'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { MarketItem } from '../bridge/types'
import { play } from '../audio/cues'
import { escapeHeld } from '../tutorial/lockGuard'
import { escapeAction, popupOpen } from './lockerv2/model'
import { useCloudscapeScope, useIslandZoom, usePortalZoom } from './lockerv2/scope'
import { BTN, ON_WHEEL, TAB_LABEL, TITLE } from './marketv2/copy'
import { BALANCE_PLATE, GOLD_INK, TABS_STYLE, WHEEL_EDGE, tabPlate } from './marketv2/look'
import {
  buyPress, confirmShown, onWheel, shownTab, swapStale, tabsFor, WHEEL_SLOTS, type TabKind,
} from './marketv2/model'
import { Card, type CardHandlers } from './marketv2/Card'
import { BuyConfirm } from './marketv2/Confirm'
import './marketv2/market.css'

/**
 * THE SEASON 2 MARKET (#411). Season 1's is screens/Market.tsx, untouched;
 * App.tsx picks between them on the MARKET envelope's `v2`, which is
 * BR.Season.has('market2') -- owner, 2026-10-13: "nothing we re-do in the shop
 * should ever show on season 1."
 *
 * WHAT IT IS, from the proposal the owner picked from:
 *
 *   TABS     Cloudscape tabs, one for each kind with real items (model.ts
 *            tabsFor); their every state is set in marketv2/look.ts, "We'll
 *            likely do a couple rounds of tuning".
 *   CARDS    four across: art, name, then the same price, Equip or Equipped
 *            as today; the edge says equipped, then owned, then rarity; the
 *            emote wheel's swap works as it does now (#215).
 *   CONFIRM  every purchase asks first (marketv2/Confirm.tsx): "Today one
 *            stray click can spend 6,500 Volts."
 *   NEW      on this season's items, which Lua marks.
 *   CORNERS  "let's keep 'em cut where they are today": the selected tab and
 *            an emote swap's Cancel; everything else square.
 *
 * THE LOBBY CHARACTER STAYS IN VIEW. Season 1's Market covers the screen; this
 * one is a panel on the left like Locker v2's, with the scrim behind it, and
 * the right of the screen is the lobby -- your character, where the lobby
 * camera already has them. Owner: "Silent previews are fine, but not sure how
 * we'd implement that given the shop is full screen today." This is the room
 * for one; see PREVIEW below.
 *
 * LUA OWNS EVERY NUMBER. The balance, ownership, the wheel and what is New
 * come from the server's grid; a press asks (MARKET_BUY / EQUIP / UNEQUIP, an
 * id) and the answer arrives as a whole new grid. Nothing here is written
 * optimistically, so the page can lag by one round trip and never claim a
 * purchase the database refused.
 *
 * THE ISLAND. As in Locker v2: everything Cloudscape renders sits inside one
 * element zoomed by root px / 14, so its 14 px text is one rem and the
 * interface-size slider reaches it; lengths inside it are in em.
 */
export default function MarketV2() {
  useCloudscapeScope()
  const z = useIslandZoom()
  usePortalZoom(z)

  const market = useUi((s) => s.market)
  const emotesOn = useUi((s) => s.emotesOn)
  const [picked, setPicked] = useState<TabKind | null>(null)
  // A full wheel's Equip picks the dance to bring in; the next press, on a
  // dance already on the wheel, names the one it replaces (#215).
  const [swapFor, setSwapFor] = useState<string | null>(null)
  // The item a price press asked about. The dialog reads it from the latest
  // grid, never from the press (model.ts confirmStale).
  const [confirmId, setConfirmId] = useState<string | null>(null)
  const [modalRoot, setModalRoot] = useState<HTMLDivElement | null>(null)

  const tabs = tabsFor(market.items, emotesOn)
  const tab = shownTab(picked, tabs)
  const items = tab === null ? [] : market.items.filter((i) => i.kind === tab)
  const wheel = onWheel(market.items)
  const wheelFull = wheel >= WHEEL_SLOTS

  // A swap the grid has overtaken, or a season that closed the dances, drops.
  const stale = swapStale(swapFor, market.items, emotesOn)
  useEffect(() => { if (stale) setSwapFor(null) }, [stale])

  // The confirm drawn is the latest grid's item, or none (model.ts
  // confirmShown); a press the grid has overtaken is then forgotten.
  const confirming = confirmShown(confirmId, market.items, market.balance)
  const confirmGone = confirmId !== null && confirming === null
  useEffect(() => { if (confirmGone) setConfirmId(null) }, [confirmGone])

  const close = () => { void fetchNui(CB.MARKET_FOCUS, { open: false }) }

  // ESCAPE closes the confirm alone, else the Market. Capture phase, so it is
  // ours before Cloudscape's own handlers or the lobby's pause key see it --
  // except while a dropdown is open, which takes it for itself (Locker v2's
  // rule, check-ui R36), and while a walkthrough card waits on this screen,
  // whose own control is the way out (#405).
  const screen = useRef<HTMLDivElement>(null)
  const live = useRef({ confirming: false })
  live.current = { confirming: confirming !== null }
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      const act = escapeAction(live.current.confirming, escapeHeld(), popupOpen(screen.current))
      if (act === 'pass') return
      e.preventDefault()
      e.stopPropagation()
      if (act === 'modal') { play('ui.back'); setConfirmId(null); return }
      if (act === 'done') { play('ui.back'); close() }
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [])

  const h: CardHandlers = {
    // THE ONE PLACE A PRICE GOES: the confirm, or the error cue when short.
    onPrice: (it) => {
      if (buyPress(it, market.balance) === 'refuse') { play('ui.error'); return }
      play('ui.select')
      setConfirmId(it.id)
    },
    onEquip: (it) => { void fetchNui(CB.MARKET_EQUIP, { id: it.id }) },
    onUnequip: (it) => { void fetchNui(CB.MARKET_UNEQUIP, { id: it.id }) },
    onReplace: (it) => {
      if (swapFor === null) return
      void fetchNui(CB.MARKET_EQUIP, { id: swapFor, replace: it.id })
      setSwapFor(null)
    },
    setSwapFor,
  }

  // THE ONLY MARKET_BUY ON THIS SCREEN, and only the confirm's Buy reaches it.
  const buy = (it: MarketItem) => {
    play('ui.select')
    setConfirmId(null)
    void fetchNui(CB.MARKET_BUY, { id: it.id })
  }

  const grid = (
    <div style={{ display: 'flex', flexDirection: 'column', height: '100%', minHeight: 0, paddingTop: '0.9em' }}>
      {/* HOW FULL THE WHEEL IS (#215), on the dances' tab only. */}
      {tab === 'emote' && (
        <div
          className="plate"
          style={{
            ['--edgec' as string]: WHEEL_EDGE(wheelFull),
            ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
            alignSelf: 'flex-start', display: 'flex', alignItems: 'baseline', gap: '0.75em',
            padding: '0.4em 1em', marginBottom: '0.9em', flex: '0 0 auto',
          }}
        >
          <span className="uppercase" style={{ fontSize: '0.62em', fontWeight: 600, letterSpacing: '0.2em', opacity: 0.6 }}>
            {ON_WHEEL}
          </span>
          <span className="font-display tabular-nums" style={{ fontSize: '1.1em', lineHeight: 1 }}>
            {`${wheel} / ${WHEEL_SLOTS}`}
          </span>
        </div>
      )}
      {/* THE ONLY SCROLLING REGION: the title, the balance, the tabs and Done
          all stay put, so the way out never moves with how much is for sale. */}
      <div className="thin-scroll" style={{ flex: '1 1 auto', minHeight: 0, overflowY: 'auto', paddingRight: '0.25em' }}>
        <div style={{ display: 'grid', gridTemplateColumns: 'repeat(4, minmax(0, 1fr))', gap: '0.75em', paddingBottom: '0.5em' }}>
          {items.map((it) => (
            <Card key={it.id} item={it} balance={market.balance} swapFor={swapFor} wheelFull={wheelFull} h={h} />
          ))}
        </div>
      </div>
    </div>
  )

  return (
    <div ref={screen} className="interactive fixed inset-0 z-50">
      {/* THE SCRIM: the left for the panel, the rest for the lobby. */}
      <div
        className="absolute inset-y-0 left-0 w-[62%] pointer-events-none"
        style={{
          background: 'linear-gradient(90deg, rgba(6,8,14,0.95) 0%, '
                    + 'rgba(6,8,14,0.88) 64%, rgba(6,8,14,0) 100%)',
        }}
      />
      {/* PREVIEW. The right of the screen is the lobby character, and nothing
          here covers it. A silent preview plugs in without moving anything:
          a card gains a Preview press that sends a MARKET_PREVIEW { id }; br_ui
          forwards it to br_core's lobby ped (client/lobbyped.lua already
          follows this screen's focus), which plays the dance with no music or
          puts the canopy or finish on show beside the ped; another press, a
          tab change, Done or Escape sends { id: null } and the ped goes back.
          Not built in #411 -- emotes and music come later. */}
      <div className="absolute inset-y-0 left-0 w-[50rem] max-w-[64vw] px-[3.5rem] py-[3rem] flex flex-col pointer-events-none">
        {/* `mk2`: market.css squares every corner in here, the confirm's
            included (#411: "let's keep 'em cut where they are today"). */}
        <div
          className="mk2 br-cs flex min-h-0 flex-1 flex-col overflow-hidden pointer-events-auto"
          style={{ zoom: z, fontSize: `calc(1rem / ${z})` }}
        >
          <div style={{ display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', flex: '0 0 auto', marginBottom: '1.25em' }}>
            <h2 className="font-display uppercase" style={{ fontSize: '2.6em', letterSpacing: '0.1em', lineHeight: 1, margin: 0 }}>
              {TITLE}
            </h2>
            {/* THE BALANCE, ALWAYS IN VIEW: a shop that makes you hunt for what
                you can afford makes every price meaningless. */}
            <div className="plate" style={{ ...BALANCE_PLATE, padding: '0.6em 1em', display: 'flex', alignItems: 'baseline', gap: '0.5em' }}>
              <span className="font-display tabular-nums" style={{ fontSize: '1.5em', lineHeight: 1, color: GOLD_INK }}>
                {market.balance.toLocaleString()}
              </span>
              <span className="uppercase" style={{ fontSize: '0.62em', fontWeight: 600, letterSpacing: '0.2em', opacity: 0.6 }}>
                {market.currency ?? 'volts'}
              </span>
            </div>
          </div>
          <div style={{ flex: '1 1 auto', minHeight: 0 }}>
            {tab !== null && (
              <Tabs
                className="mk2-tabs"
                fitHeight
                disableContentPaddings
                style={TABS_STYLE}
                activeTabId={tab}
                onChange={({ detail }) => {
                  play('ui.select')
                  setPicked(detail.activeTabId as TabKind)
                  setSwapFor(null)
                }}
                tabs={tabs.map((k) => ({
                  id: k,
                  // THE SELECTED TAB IS CUT, the rest square: the lobby's plate,
                  // `is-active` on the one shown (#411's corners).
                  label: (
                    <span
                      className={`plate font-display uppercase${k === tab ? ' is-active' : ''}`}
                      style={tabPlate(k === tab)}
                      onPointerEnter={() => play('ui.hover')}
                    >
                      {TAB_LABEL[k]}
                    </span>
                  ),
                  content: k === tab ? grid : null,
                }))}
              />
            )}
          </div>
          <div style={{ flex: '0 0 auto', paddingTop: '1.25em' }}>
            {/* DONE'S TUTORIAL ANCHOR STEPS OUT OF THE ZOOM, as Locker v2's
                does: the walkthrough's Market card (#405) rings
                `[data-tut="market-done"]` and waits on the press, and on CEF
                103 a box inside a zoomed element is reported in its px. */}
            <span data-tut="market-done" style={{ display: 'inline-block', zoom: 1 / z }}>
              <span className="mk2-act" style={{ display: 'inline-block', zoom: z }} onPointerEnter={() => play('ui.hover')}>
                <Button variant="primary" onClick={() => { play('ui.back'); close() }}>
                  <span className="font-display uppercase" style={{ letterSpacing: '0.1em', fontWeight: 400 }}>{BTN.done}</span>
                </Button>
              </span>
            </span>
          </div>
          <div ref={setModalRoot} className="pointer-events-auto" />
        </div>
      </div>
      <BuyConfirm
        item={confirming}
        currency={market.currency ?? 'volts'}
        root={modalRoot}
        onCancel={() => { play('ui.back'); setConfirmId(null) }}
        onBuy={buy}
      />
    </div>
  )
}
