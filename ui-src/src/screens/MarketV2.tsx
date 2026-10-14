import { useEffect, useRef, useState } from 'react'
import Button from '@cloudscape-design/components/button'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { MarketItem } from '../bridge/types'
import { play } from '../audio/cues'
import { escapeHeld } from '../tutorial/lockGuard'
import { escapeAction, popupOpen } from './lockerv2/model'
import { useCloudscapeScope, useIslandZoom, usePortalZoom } from './lockerv2/scope'
import { BTN, TITLE, WHEEL_LABEL } from './marketv2/copy'
import { BALANCE_PLATE, GOLD_INK, GRID, GUTTER, ONE_LINE, PANEL_W, SCRIM, wheelPlate } from './marketv2/look'
import {
  buyPress, confirmShown, onWheel, previewShown, replaceChoices, shownTab, swapStale, tabDesign, tabsFor,
  wheelCount, WHEEL_SLOTS, type TabKind,
} from './marketv2/model'
import { Card, type CardHandlers } from './marketv2/Card'
import { BuyConfirm } from './marketv2/Confirm'
import { ReplaceDialog } from './marketv2/Replace'
import { TabStrip } from './marketv2/TabStrip'
import './marketv2/market.css'

/**
 * THE SEASON 2 MARKET (#411). Season 1's is screens/Market.tsx, untouched;
 * App.tsx picks between them on the MARKET envelope's `v2`, which is
 * BR.Season.has('market2') -- owner, 2026-10-13: "nothing we re-do in the shop
 * should ever show on season 1."
 *
 * WHAT IT IS, from the proposal the owner picked and his notes on it
 * (2026-10-14):
 *
 *   TABS     one for each kind with real items (model.ts tabsFor), named as
 *            he asked ("Smoke trails", "Weapon finishes"), in one of three
 *            designs to compare (marketv2/TabStrip.tsx, market.css).
 *   CARDS    as many columns as fit, four at most, so no label ever wraps:
 *            art, name, then the same price, Equip or Equipped as today; the
 *            edge says equipped, then owned, then rarity. A dance has no art,
 *            and has Preview.
 *   CONFIRM  every purchase asks first: "Are you sure?", "Buy Crimson canopy
 *            for 1,200 Volts?" (marketv2/Confirm.tsx).
 *   REPLACE  Equip on a full wheel opens a dialog of the eight on it, each
 *            with Replace (marketv2/Replace.tsx).
 *   PREVIEW  the lobby character plays the dance, silently, while the Market
 *            is open (MARKET_PREVIEW; br_core/client/lobbyped.lua).
 *   CORNERS  "let's keep 'em cut where they are today": the selected tab;
 *            everything else square.
 *
 * THE LOBBY CHARACTER STAYS IN VIEW. A panel on the left, with a light scrim
 * that ends a short way past it (look.ts SCRIM: "too opaque and goes too
 * right, kinda obstructs the view of the ped"), and the rest of the screen is
 * the lobby -- the character the preview dances on.
 *
 * LUA OWNS EVERY NUMBER. The balance, ownership and the wheel come from the
 * server's grid; a press asks (MARKET_BUY / EQUIP / UNEQUIP, an id) and the
 * answer arrives as a whole new grid. Nothing here is written optimistically,
 * so the page can lag by one round trip and never claim a purchase the
 * database refused.
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
  const design = tabDesign(useUi((s) => s.marketTabs))
  const [picked, setPicked] = useState<TabKind | null>(null)
  // Equip on a full wheel: the dance to bring in, which opens the replace
  // dialog (#411); null while it is closed.
  const [swapFor, setSwapFor] = useState<string | null>(null)
  // The item a price press asked about. The dialog reads it from the latest
  // grid, never from the press (model.ts confirmShown).
  const [confirmId, setConfirmId] = useState<string | null>(null)
  // The dance a Preview press asked for (model.ts previewShown).
  const [previewId, setPreviewId] = useState<string | null>(null)
  const [modalRoot, setModalRoot] = useState<HTMLDivElement | null>(null)

  const tabs = tabsFor(market.items, emotesOn)
  const tab = shownTab(picked, tabs)
  const items = tab === null ? [] : market.items.filter((i) => i.kind === tab)
  const wheel = onWheel(market.items)
  const wheelFull = wheel >= WHEEL_SLOTS

  // A replace the grid has overtaken, or a season that closed the dances,
  // closes.
  const stale = swapStale(swapFor, market.items, emotesOn)
  useEffect(() => { if (stale) setSwapFor(null) }, [stale])
  const replacing = swapFor !== null && !stale

  // The confirm drawn is the latest grid's item, or none (model.ts
  // confirmShown); a press the grid has overtaken is then forgotten.
  const confirming = confirmShown(confirmId, market.items, market.balance)
  const confirmGone = confirmId !== null && confirming === null
  useEffect(() => { if (confirmGone) setConfirmId(null) }, [confirmGone])

  // THE PREVIEW ON THE LOBBY CHARACTER (#411). Whatever previewShown says is
  // what Lua is told, each time it changes -- a press, its press again,
  // another dance's, a tab change, a grid that took it away -- and once more,
  // empty, as the screen goes. br_core also stops it the moment the Market
  // loses the focus, so a screen that never got to say so stops it too.
  const previewing = previewShown(previewId, tab, market.items, market.balance)
  const told = useRef<string | null>(null)
  useEffect(() => {
    if (told.current === previewing) return
    told.current = previewing
    void fetchNui(CB.MARKET_PREVIEW, { id: previewing })
  }, [previewing])
  useEffect(() => () => {
    if (told.current !== null) void fetchNui(CB.MARKET_PREVIEW, { id: null })
  }, [])

  const close = () => {
    setPreviewId(null)
    if (told.current !== null) { told.current = null; void fetchNui(CB.MARKET_PREVIEW, { id: null }) }
    void fetchNui(CB.MARKET_FOCUS, { open: false })
  }

  // ESCAPE closes a dialog alone, else the Market. Capture phase, so it is
  // ours before Cloudscape's own handlers or the lobby's pause key see it --
  // except while a dropdown is open, which takes it for itself (Locker v2's
  // rule, check-ui R36), and while a walkthrough card waits on this screen,
  // whose own control is the way out (#405).
  const screen = useRef<HTMLDivElement>(null)
  const live = useRef({ dialog: false, close })
  live.current = { dialog: confirming !== null || replacing, close }
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      const act = escapeAction(live.current.dialog, escapeHeld(), popupOpen(screen.current))
      if (act === 'pass') return
      e.preventDefault()
      e.stopPropagation()
      if (act === 'modal') { play('ui.back'); setConfirmId(null); setSwapFor(null); return }
      if (act === 'done') { play('ui.back'); live.current.close() }
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
    onSwap: (it) => { setSwapFor(it.id) },
    onPreview: (it) => { setPreviewId(previewing === it.id ? null : it.id) },
  }

  // THE ONLY MARKET_BUY ON THIS SCREEN, and only the confirm's Buy reaches it.
  const buy = (it: MarketItem) => {
    play('ui.select')
    setConfirmId(null)
    void fetchNui(CB.MARKET_BUY, { id: it.id })
  }

  // THE ONLY REPLACE: the dialog's, the existing swap -- MARKET_EQUIP with the
  // dance coming in and the one it takes the place of (#215).
  const replace = (out: MarketItem) => {
    if (swapFor === null) return
    void fetchNui(CB.MARKET_EQUIP, { id: swapFor, replace: out.id })
    setSwapFor(null)
  }

  // GUTTER: the one region that clips is the grid's, and every row is inset by
  // the same amount so its edges line up with the cards' (look.ts GUTTER).
  const row = { paddingInline: GUTTER }

  return (
    <div ref={screen} className="interactive fixed inset-0 z-50">
      {/* THE SCRIM: as wide as the panel and a short fade past it. */}
      <div className="absolute inset-y-0 left-0 pointer-events-none" style={SCRIM} />
      <div
        className="absolute inset-y-0 left-0 px-[3rem] py-[3rem] flex flex-col pointer-events-none"
        style={{ width: PANEL_W }}
      >
        {/* `mk2`: market.css squares every corner in here, the dialogs'
            included (#411: "let's keep 'em cut where they are today"). NOT
            overflow-hidden: nothing bordered may sit on a clipping edge. */}
        <div
          className="mk2 br-cs flex min-h-0 flex-1 flex-col pointer-events-auto"
          style={{ zoom: z, fontSize: `calc(1rem / ${z})` }}
        >
          <div style={{ ...row, display: 'flex', alignItems: 'flex-end', justifyContent: 'space-between', gap: '1em', flex: '0 0 auto', marginBottom: '1.25em' }}>
            <h2 className="font-display uppercase" style={{ ...ONE_LINE, fontSize: '2.6em', letterSpacing: '0.1em', lineHeight: 1, margin: 0 }}>
              {TITLE}
            </h2>
            {/* THE BALANCE, ALWAYS IN VIEW: a shop that makes you hunt for what
                you can afford makes every price meaningless. */}
            <div className="plate" style={{ ...BALANCE_PLATE, ...ONE_LINE, padding: '0.6em 1em', display: 'flex', alignItems: 'baseline', gap: '0.5em' }}>
              <span className="font-display tabular-nums" style={{ fontSize: '1.5em', lineHeight: 1, color: GOLD_INK }}>
                {market.balance.toLocaleString('en-US')}
              </span>
              <span className="uppercase" style={{ fontSize: '0.62em', fontWeight: 600, letterSpacing: '0.2em', opacity: 0.6 }}>
                {market.currency ?? 'volts'}
              </span>
            </div>
          </div>
          {tab !== null && (
            <div style={{ ...row, flex: '0 0 auto' }}>
              <TabStrip
                tabs={tabs}
                tab={tab}
                design={design}
                onPick={(k) => {
                  play('ui.select')
                  setPicked(k)
                  setSwapFor(null)
                  setPreviewId(null)
                }}
              />
            </div>
          )}
          <div role="tabpanel" style={{ display: 'flex', flexDirection: 'column', flex: '1 1 auto', minHeight: 0, paddingTop: '0.9em' }}>
            {/* HOW FULL THE WHEEL IS (#215), on the dances' tab only: "Equipped"
                and "8/8" (owner, 2026-10-14), one card wide and in the cards'
                column, its words centered top to bottom. */}
            {tab === 'emote' && (
              <div style={{ ...row, ...GRID, flex: '0 0 auto', marginBottom: '0.6em' }}>
                <div
                  className="plate"
                  data-mk2-wheel
                  style={{
                    ...wheelPlate(wheelFull), ...ONE_LINE,
                    display: 'flex', alignItems: 'center', justifyContent: 'center', gap: '0.75em',
                    padding: '0.45em 0.75em',
                  }}
                >
                  <span className="uppercase" style={{ fontSize: '0.62em', fontWeight: 600, letterSpacing: '0.2em', opacity: 0.6, lineHeight: 1 }}>
                    {WHEEL_LABEL}
                  </span>
                  <span className="font-display tabular-nums" style={{ fontSize: '1.1em', lineHeight: 1 }}>
                    {wheelCount(market.items)}
                  </span>
                </div>
              </div>
            )}
            {/* THE ONLY SCROLLING REGION, and the only box on this screen that
                clips: inset GUTTER on every side, so a card's border is never
                on its edge. The title, the balance, the tabs and Done stay
                put, so the way out never moves with how much is for sale. */}
            <div
              className="thin-scroll"
              data-mk2-scroll
              style={{ flex: '1 1 auto', minHeight: 0, overflowX: 'hidden', overflowY: 'auto', padding: GUTTER }}
            >
              <div style={{ ...GRID, paddingBottom: '0.5em' }}>
                {items.map((it) => (
                  <Card key={it.id} item={it} balance={market.balance} wheelFull={wheelFull} previewing={previewing} h={h} />
                ))}
              </div>
            </div>
          </div>
          <div style={{ ...row, flex: '0 0 auto', paddingTop: '1.25em', paddingBottom: GUTTER }}>
            {/* DONE'S TUTORIAL ANCHOR STEPS OUT OF THE ZOOM, as Locker v2's
                does: the walkthrough's Market card (#405) rings
                `[data-tut="market-done"]` and waits on the press, and on CEF
                103 a box inside a zoomed element is reported in its px. */}
            <span data-tut="market-done" style={{ display: 'inline-block', zoom: 1 / z }}>
              <span className="mk2-act" style={{ display: 'inline-block', zoom: z }} onPointerEnter={() => play('ui.hover')}>
                <Button variant="primary" onClick={() => { play('ui.back'); close() }}>
                  <span className="font-display uppercase" style={{ ...ONE_LINE, letterSpacing: '0.1em', fontWeight: 400 }}>{BTN.done}</span>
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
      <ReplaceDialog
        choices={replaceChoices(market.items)}
        open={replacing}
        root={modalRoot}
        onReplace={replace}
        onCancel={() => { play('ui.back'); setSwapFor(null) }}
      />
    </div>
  )
}
