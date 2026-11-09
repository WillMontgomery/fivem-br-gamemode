import {
  useCallback, useContext, useEffect, useLayoutEffect, useRef, useState, type PointerEvent as ReactPointerEvent,
  type ReactNode,
} from 'react'
import { play } from '../../audio/cues'
import { fetchNui } from '../../bridge/nui'
import { CB, RARITY } from '../../bridge/types'
import type { InvPayload, InvSlot } from '../../bridge/types'
import { gaugeShare } from '../../hud/gaugeShare'
import ItemIcon from '../../hud/ItemIcon'
import { selInv, useUi } from '../../store'
import {
  Bar, Button, CardAction, HALF, Numeral, Plate, Presence, PresencePhaseCtx, Tag, registerPreset, u, vars,
} from '../../ui/broadcast'
import Fit from '../../ui/Fit'
import { keyOf, useBagFx, type BarFx } from './fx'
import { InvPresence } from './presence'
import { SlotKey } from './SlotKey'
import './inventory.css'

/**
 * UI V2'S TAB PAGE, IN BROADCAST (#431): src/screens/InventoryPanel.tsx rebuilt
 * from the kit (src/ui/broadcast), the owner's pick from his preview
 * (previews/inventory/BroadcastPage.tsx), with today's contract exactly: no
 * props, the bag from the store, and every control a REQUEST (fetchNui
 * CB.INV_SELECT, INV_SWAP, INV_USE, INV_DROP, today's five with today's
 * payloads): nothing here mutates the store, the cards move when INV_SET comes
 * back. Today's panel stays as it is beside it; ./PageSlot.tsx is what App
 * draws for the inventory piece of UI v2, the box this page sits in and its
 * scope.
 *
 * WHAT IT IS MADE OF: the dialog's anatomy without its scrim or its Escape (this
 * is a keep-input screen over a live match, and Lua owns opening and closing
 * it): a deck surface under an Anton header strap with the page's one word,
 * five slot cards in the kit Card's anatomy (an art well with its top rule in
 * the edge color, a slanted name plate, the actions), and under a rule the
 * ammo: the owner's word for the section, then the five pools, each a plate
 * with its count in a score cell and its Drop under it.
 *
 * EVERYTHING TODAY'S PAGE SHOWS, in its words: the slot's key (SlotKey), the
 * rarity (its name on a chip in its color, the pips in the colorblind modes),
 * the art, the label, the line that says what a slot eats or what it is (the
 * pool's word or the kind, the stack, the clip), Use for a consumable, Drop,
 * the can's gauge, Empty, the five pools with their figures and a Drop that is
 * off for an empty pool. The card in hand is lit (the kit Card's rule: the
 * accent outranks the rarity on the edge, and the rarity keeps its chip).
 *
 * AN ITEM MOVES BY DRAG AND DROP (the owner, 2026-11-03: "the left/right arrows
 * can be removed if you'll build something that allows us to drag and drop to
 * reorder the items"): SlotCards, below. The arrows are gone; a click on a card
 * is still today's select.
 *
 * ITS MOTION IS THE KIT'S: the page, each card and the pools are presences in
 * the page's own scope (PageSlot's, the kit's page preset: broadcast at twice
 * the speed), so TAB brings it on air card by card and takes it off air in
 * reverse.
 */

/**
 * THE PAGE'S WAY OUT WHEN THE PAUSE MENU TAKES ITS PLACE. Focus is one screen
 * at a time, so the pause menu over an open page REPLACES it: the page goes on
 * the quick hide's timing (the kit's HALF.quick, 150 ms), as one fade of the
 * whole page -- never a pop, never its way off air. It moves no channel, so an
 * entrance still running runs on under the fade and nothing snaps. PageSlot
 * names it on the page's scope from the moment the pause menu takes the
 * page's focus until the page is next opened (usePageExit); its hidden value
 * is inventory.css's.
 */
export const PAGE_QUICK = 'binvQuick'
registerPreset({
  name: PAGE_QUICK, enter: HALF.quick, leave: HALF.quick, step: 0, leaveStep: 0, reverse: false, layer: false,
})

/** InventoryPanel.tsx's AMMO_LABEL: every caption is a word the owner wrote. */
const AMMO_LABEL: Record<string, string> = {
  light: 'Light',
  smg: 'SMG',
  medium: 'Medium',
  shells: 'Shells',
  heavy: 'Heavy',
}
/** Its pools, in its order (one column per key, as today). */
const POOLS = Object.keys(AMMO_LABEL)

/** The pools' section label, the owner's word as he wrote it (2026-11-03: "we
 *  need somewhere to say "ammo" under the line break"). Its style sets it in
 *  capitals, as the page's own label is. */
const AMMO_TITLE = 'ammo'

/** Kit units. The title is --bc-fs-btn-xl (1.6) tall: half of it clears the slant. */
const HEAD_H = 2.2
const TITLE_CH = 0.8
/** The kit Card's name plate (Card.tsx): the same plate, the same two lines. */
const NAME_H = 2.6
const POOL_H = 2.4
const POOL_CELL = 3.2
/** A card's key cap: it scales with the text setting here, as KeyCap does in
 *  a sentence (the well has the room). */
const KEY_FS = 'var(--bc-fs-body)'

/** How far a press travels before the item comes up, in screen pixels (the
 *  hand's own jitter, not a length on the page): a press that stays inside it
 *  is a click, today's select. */
const LIFT_PX = 6

const stop = (e: ReactPointerEvent<HTMLElement>) => e.stopPropagation()
const pipsOf = (n: number): ReactNode => Array.from({ length: n }, (_, i) => <i key={i} />)

/** What it eats, not what it is (InventoryPanel.tsx, word for word). */
function subLine(slot: InvSlot): string {
  return `${(slot.pool && AMMO_LABEL[slot.pool]) || slot.kind}`
    + `${slot.count > 1 ? ` · x${slot.count}` : ''}`
    + `${slot.clip != null ? ` · ${slot.clip} in clip` : ''}`
}

/**
 * THE SERVER'S RULE FOR A MOVE (br_core/server/inventory.lua: INV_SWAP refuses
 * `channelled(inv, from) or channelled(inv, to)`, #271): while a use runs, the
 * slot it runs on and the slot in hand stay put, at either end of a swap; a
 * swap between two other slots still goes. The page reads it off the bag it
 * was sent, so a drag the server would refuse never lifts or lights. The
 * request still goes as it always has, and the server still decides.
 * scripts/check-ui.mjs R41 holds the two slots named here to the server's.
 */
function locked(inv: InvPayload, i: number): boolean {
  const use = inv.using
  return use != null && (use.slot === i || inv.active === i)
}

/** An item the player may pick up now. */
function movable(inv: InvPayload, i: number): boolean {
  return inv.slots[i - 1] != null && !locked(inv, i)
}

type PointerHandler = (e: ReactPointerEvent<HTMLDivElement>) => void

function SlotCard({
  index, slot, active, arrive, canMove, lifted, target, onDown, onMove, onLost,
}: {
  index: number
  slot: InvSlot | null
  active: boolean
  /** An item landed here (./fx.ts: a pickup, a move or a swap): the art drops in. */
  arrive: number
  /** It can be picked up now (`movable`, the page on air). */
  canMove: boolean
  /** It is the one held. */
  lifted: boolean
  /** The held item lands here if it is let go now. */
  target: boolean
  onDown: (i: number, e: ReactPointerEvent<HTMLDivElement>) => void
  onMove: PointerHandler
  onLost: PointerHandler
}) {
  const tint = slot ? `var(--bc-rarity-${slot.rarity})` : 'var(--bc-rule-quiet)'
  const edge = active ? 'var(--bc-accent)' : tint
  const cls = [
    'binv-card', active ? 'is-held' : '', canMove ? 'is-movable' : '', lifted ? 'is-dragging' : '',
    target ? 'is-target' : '', slot ? '' : 'is-empty',
  ].filter(Boolean).join(' ')
  return (
    // POINTER EVENTS, NOT HTML5 DRAG AND DROP (InventoryPanel.tsx: CEF never
    // fired `drop`): the press captures the pointer, so every move comes back
    // to this card wherever it happens, and the release is heard wherever it
    // lands (SlotCards).
    <div
      className={cls}
      data-binv-slot={index}
      style={vars({ '--binv-edge': edge })}
      onPointerDown={(e) => onDown(index, e)}
      onPointerMove={onMove}
      onLostPointerCapture={onLost}
    >
      <div className="binv-card__well bc-ch-surface">
        <span className="binv-card__top">
          <SlotKey index={index} held={active} fs={KEY_FS} />
          {slot && (
            <span className="binv-card__rarity">
              <span className="rarity-pips" style={{ color: tint }}>{pipsOf(slot.rarity)}</span>
              <Tag variant="chip" ink="dark" tone={tint}>{RARITY[slot.rarity].label}</Tag>
            </span>
          )}
        </span>
        {slot ? (
          <>
            <span className="binv-card__art" style={{ color: tint }}>
              <Tag variant="holder" tone={tint} enter="drop" beat={arrive}>
                <span className="binv-card__artbox"><ItemIcon slot={slot} size="100%" /></span>
              </Tag>
            </span>
            {slot.fill != null && (
              <span className="binv-card__gauge">
                <Bar value={gaugeShare(slot.fill) * 100} tone={tint} axis="y" feed="step" />
              </span>
            )}
          </>
        ) : (
          <span className="binv-card__empty">Empty</span>
        )}
      </div>
      {slot && (
        <>
          <Plate variant="deck" edge={edge} height={NAME_H} state={active ? 'active' : 'rest'}>
            <Plate.Line cy={0.82} ch={0.42} lh={1.1}>
              <Fit className="binv-card__name ts" style={vars({ '--fs': 'var(--bc-fs-card-name)' })}>{slot.label}</Fit>
            </Plate.Line>
            <Plate.Line cy={1.86} ch={0.3} lh={0.8}>
              <Fit className="micro-label">{subLine(slot)}</Fit>
            </Plate.Line>
          </Plate>
          {/* The actions: a press on one stops here, so it is the button's and
              never a press of the card's (the card owns the press and the
              drag; the window hears every release, SlotCards). */}
          <div className="binv-card__acts bc-ch-content" onPointerDown={stop}>
            <div className="binv-card__row">
              {slot.kind === 'consumable' && (
                <CardAction tone="hp" onPress={() => { void fetchNui(CB.INV_USE, { slot: index }) }}>Use</CardAction>
              )}
              <Button size="sm" full cue="ui.back" onPress={() => { void fetchNui(CB.INV_DROP, { slot: index }) }}>
                Drop
              </Button>
            </div>
          </div>
        </>
      )}
    </div>
  )
}

/** A card's rect, in client px. */
interface CardRect { i: number; r: DOMRect }

/** A press while it is down. A ref, not state: moves are many, and the render
 *  hears only of a lift, a change of the card under the pointer, and the end. */
interface Hold {
  pointer: number
  from: number
  /** The item it went down on (fx.ts's keyOf), or null on an empty card: the
   *  only item this press may lift or move. */
  key: string | null
  /** Where it went down, client px. */
  x: number
  y: number
  /** The card it went down on: it holds the capture. */
  el: HTMLElement
  /** Past LIFT_PX: not a click any more. */
  moved: boolean
  /** A move has reported the button held. From then on a move without it is
   *  a release this page never heard (let go outside the window, or while the
   *  window was away), and the item goes down. Read off the moves alone: an
   *  embedder that sends its moves without the button never sets it. */
  pressed: boolean
  /** ...and the item came up (the one it went down on, which the server
   *  would move, the page on air). */
  lifted: boolean
  /** The render has been told of the lift. */
  drawn: boolean
  /** The card under the pointer (any card), or none. */
  over: number | null
  /** Read once at the lift: client px per px of the cards' own box (1 in
   *  game: nothing above it scales), that box's origin, and every card's. */
  k: number
  left: number
  top: number
  cards: readonly CardRect[]
  /** The ghost's place, in the cards' box's px. */
  gx: number
  gy: number
}

/** The press still has its item: its slot holds the item it went down on, and
 *  the server would move it now. */
function holds(inv: InvPayload, h: Pick<Hold, 'from' | 'key'>): boolean {
  return keyOf(inv.slots[h.from - 1] ?? null) === h.key && movable(inv, h.from)
}

/** Every card's rect, read now. */
function cardsIn(b: HTMLElement): CardRect[] {
  return Array.from(b.querySelectorAll<HTMLElement>('[data-binv-slot]'), (c) => ({
    i: Number(c.dataset.binvSlot), r: c.getBoundingClientRect(),
  }))
}

function cardAt(cards: readonly CardRect[], x: number, y: number): number | null {
  for (const c of cards) {
    if (x >= c.r.left && x < c.r.right && y >= c.r.top && y < c.r.bottom) return c.i
  }
  return null
}

/**
 * THE FIVE CARDS, AND MOVING AN ITEM: pick it up, drop it on another slot.
 *
 *   press   a pointer down on a card captures it (setPointerCapture), so every
 *           move comes back to that card wherever it happens: over another
 *           card, off the page, outside the window
 *   click   a release within LIFT_PX of the press, on the card it began on:
 *           INV_SELECT {slot}, today's
 *   lift    past LIFT_PX on an item the server would move, the one the press
 *           went down on: the card dims, a ghost of its art follows the
 *           pointer, and the card under the pointer that would take it lights
 *           (a swap, or a move into an empty slot). A slot in use, or the hand
 *           while a use runs, never lifts or lights (`locked`)
 *   drop    the release over a lit card: INV_SWAP {from, to}, the request
 *           today's arrows sent, with the arrows' cue. The cards change when
 *           INV_SET comes back, and the arts that moved drop in (fx.ts punch)
 *   cancel  a release anywhere else (off the cards, back on the card it came
 *           from, on one that cannot take it), a cancel, a lost capture, the
 *           page going off air, the window losing focus, a move that says the
 *           button came up where the page could not hear it, or the bag
 *           taking the held item away: nothing is sent
 *
 * EVERY PRESS ENDS, AND NOTHING OUTLIVES IT (#440 is today's page, where a
 * drag let go off the cards stayed held and the next click on an empty slot
 * moved the item there). The release and the cancel are heard on the window,
 * in its capture phase: the window is on the path of every pointer event the
 * page gets, so it hears each one first, before anything on its way can stop
 * it -- sent to the pressed card wherever it lands while the capture holds,
 * and to whatever is under it where the capture failed or was lost. So every
 * release ends the press it belongs to, a release is a select only on the
 * card its press began on and a swap only from another card, a release with
 * no press of its own (a button held down as the page opened) is nothing, and
 * a new press starts from nothing: an empty card never inherits an item.
 * scripts/test-inventory-fx.mjs presses the page each of these ways.
 *
 * A PRESS HOLDS ONLY THE ITEM IT WENT DOWN ON (`holds`). An item landing in
 * its slot before it moves never comes up with it, nor does anything after
 * (the lift is tried once), and the bag taking a held item away ends the
 * press, as a release off the cards does, and for good: its slot emptied,
 * traded for another item (a full bag's pickup trades the hand), or locked (a
 * use beginning on it, or on any slot while it is in hand). The bag changing
 * back brings nothing back, so a release never moves an item the player did
 * not pick up. A push that keeps the item (a top-up, a reload, a pickup in
 * another slot) leaves it held.
 *
 * POINTER EVENTS, NOT HTML5 DRAG AND DROP, so it behaves the same on Chromium
 * 103 and 144. NO FRAME LOOP: the ghost's transform is written from pointermove
 * while an item is held (input, which Chromium coalesces to the frame), and
 * React hears only of the lift, the card under it changing, and the end.
 *
 * It lives inside the page's presence, so it unmounts with the page: a drag
 * never outlives the page it began on.
 */
function SlotCards({ inv, fx }: { inv: InvPayload; fx: BarFx }) {
  const n = inv.slots.length
  const page = useContext(PresencePhaseCtx)
  const onAir = page.phase === 'entering' || page.phase === 'shown'
  const box = useRef<HTMLDivElement>(null)
  const ghost = useRef<HTMLDivElement | null>(null)
  const hold = useRef<Hold | null>(null)
  const latest = useRef({ inv, onAir })
  useLayoutEffect(() => { latest.current = { inv, onAir } })
  const [drag, setDrag] = useState<{ from: number; key: string | null; over: number | null } | null>(null)

  // What the render draws, against the bag as it is NOW: never an item the
  // press no longer holds, so the render that brings the bag never draws it,
  // and the bag's effect below ends the press before that frame is painted.
  const lift = onAir && drag && holds(inv, drag) ? drag : null
  const target = lift && lift.over !== null && lift.over !== lift.from && !locked(inv, lift.over) ? lift.over : null
  const item = lift ? inv.slots[lift.from - 1] ?? null : null

  const letGo = useCallback((h: Hold) => {
    hold.current = null
    try {
      if (h.el.hasPointerCapture(h.pointer)) h.el.releasePointerCapture(h.pointer)
    } catch { /* the pointer is gone already */ }
    setDrag(null)
  }, [])

  // The page going off air ends a press, so one can never come back with it.
  useLayoutEffect(() => {
    if (!onAir && hold.current) letGo(hold.current)
  }, [onAir, letGo])

  // THE BAG TAKING THE HELD ITEM AWAY ENDS THE PRESS (the header), in the
  // commit that brings the bag: before it is painted, and before a release
  // can be heard. Only a lifted press: one that never came up holds
  // nothing, and one that never moved is still a click, today's select.
  useLayoutEffect(() => {
    const h = hold.current
    if (h?.lifted && !holds(inv, h)) letGo(h)
  }, [inv, letGo])

  // THE END OF EVERY PRESS (the header): its release, its cancel, and the
  // window losing focus (alt-tab mid-drag, where the release may never reach
  // the page), each heard on the window. A release decides what it was, by
  // the card under it: the lift's rects for an item held (what the drag lit),
  // read at the release for a press that never lifted.
  useEffect(() => {
    const up = (e: PointerEvent) => {
      const h = hold.current
      if (!h || e.pointerId !== h.pointer) return
      letGo(h)
      const now = latest.current
      if (!h.moved) {
        // A PRESS THAT STAYED PUT IS A CLICK: today's select, of the card it
        // began on, and only where it ends on that card too.
        const b = box.current
        if (b && cardAt(cardsIn(b), e.clientX, e.clientY) === h.from) void fetchNui(CB.INV_SELECT, { slot: h.from })
        return
      }
      if (!h.lifted || !now.onAir) return
      const to = cardAt(h.cards, e.clientX, e.clientY)
      // A DROP OUTSIDE A SLOT CANCELS, as does one back on the card it came
      // from, on one the server would not move, or of an item the press no
      // longer holds.
      if (to === null || to === h.from || !holds(now.inv, h) || locked(now.inv, to)) return
      play('ui.select')
      void fetchNui(CB.INV_SWAP, { from: h.from, to })
    }
    const cancel = (e: PointerEvent) => {
      const h = hold.current
      if (h && e.pointerId === h.pointer) letGo(h)
    }
    const away = () => { if (hold.current) letGo(hold.current) }
    window.addEventListener('pointerup', up, true)
    window.addEventListener('pointercancel', cancel, true)
    window.addEventListener('blur', away)
    return () => {
      window.removeEventListener('pointerup', up, true)
      window.removeEventListener('pointercancel', cancel, true)
      window.removeEventListener('blur', away)
    }
  }, [letGo])

  // The ghost is placed as it mounts (before it paints); after that the moves
  // write it. React never writes its transform.
  const ghostRef = useCallback((el: HTMLDivElement | null) => {
    ghost.current = el
    const h = hold.current
    if (el && h) el.style.transform = `translate(${h.gx}px, ${h.gy}px)`
  }, [])

  const onDown = (i: number, e: ReactPointerEvent<HTMLDivElement>) => {
    if (e.button !== 0) return
    const was = hold.current
    // One item at a time: a second finger waits. The same pointer pressing
    // again means its last release never came (a mouse sends one press per
    // press), so that press is over, and this one starts from nothing.
    if (was && was.pointer !== e.pointerId) return
    if (was) letGo(was)
    const el = e.currentTarget
    // A capture can be refused (a pointer that is no longer down); the moves
    // over this card still come here, and the window still hears the release.
    try { el.setPointerCapture(e.pointerId) } catch { /* no live pointer */ }
    hold.current = {
      pointer: e.pointerId, from: i, key: keyOf(latest.current.inv.slots[i - 1] ?? null), x: e.clientX, y: e.clientY, el,
      moved: false, pressed: false, lifted: false, drawn: false, over: i, k: 1, left: 0, top: 0, cards: [], gx: 0, gy: 0,
    }
  }

  const onMove: PointerHandler = (e) => {
    const h = hold.current
    if (!h || e.pointerId !== h.pointer) return
    if ((e.buttons & 1) !== 0) h.pressed = true
    else if (h.pressed) {
      letGo(h)
      return
    }
    if (!h.moved) {
      if (Math.hypot(e.clientX - h.x, e.clientY - h.y) < LIFT_PX) return
      h.moved = true
      const now = latest.current
      const b = box.current
      if (!now.onAir || !b || !holds(now.inv, h)) return
      // THE LIFT: the geometry, read once; nothing moves the cards while an
      // item is held.
      const r = b.getBoundingClientRect()
      h.k = b.offsetWidth > 0 ? r.width / b.offsetWidth : 1
      h.left = r.left
      h.top = r.top
      h.cards = cardsIn(b)
      h.lifted = true
    }
    if (!h.lifted) return
    h.gx = (e.clientX - h.left) / h.k
    h.gy = (e.clientY - h.top) / h.k
    if (ghost.current) ghost.current.style.transform = `translate(${h.gx}px, ${h.gy}px)`
    const over = cardAt(h.cards, e.clientX, e.clientY)
    if (!h.drawn || over !== h.over) {
      h.drawn = true
      h.over = over
      setDrag({ from: h.from, key: h.key, over })
    }
  }

  // The card this press holds lost its capture (taken away, or the card gone):
  // the press is over. Only that card's: a press that ended unheard can lose
  // its old capture after the next press began on another card.
  const onLost: PointerHandler = (e) => {
    const h = hold.current
    if (h && e.pointerId === h.pointer && e.currentTarget === h.el) letGo(h)
  }

  return (
    <div ref={box} className="binv-page__cards">
      {inv.slots.map((slot, i) => {
        const at = i + 1
        const f = fx.slots[at]
        return (
          <InvPresence
            key={i}
            id={`card-${at}`}
            order={1 + i}
            last={1 + n}
            live={[slot && slot.count > 1 ? slot.count : '', slot?.clip ?? '', slot?.fill ?? '']}
            className="binv-cardp"
          >
            <SlotCard
              index={at}
              slot={slot}
              active={inv.active === at}
              arrive={(f?.arrive ?? 0) + (f?.punch.n ?? 0)}
              canMove={onAir && movable(inv, at)}
              lifted={lift?.from === at}
              target={target === at}
              onDown={onDown}
              onMove={onMove}
              onLost={onLost}
            />
          </InvPresence>
        )
      })}
      {lift && item && (
        <div
          ref={ghostRef}
          className="binv-ghost"
          style={vars({ '--binv-edge': `var(--bc-rarity-${item.rarity})` })}
          aria-hidden
        >
          <span className="binv-ghost__art" style={{ color: `var(--bc-rarity-${item.rarity})` }}>
            <ItemIcon slot={item} size="100%" />
          </span>
        </div>
      )}
    </div>
  )
}

/** One pool: its word, its figure in a score cell, and a Drop that puts the
 *  WHOLE pool down (the only quantity anything here has ever used). */
function Pool({ pool, held }: { pool: string; held: number }) {
  return (
    <div className="binv-pool">
      <Plate variant="deck" edge="var(--bc-rule)" height={POOL_H} cell="full" cellWidth={POOL_CELL}>
        <Plate.Line cy={POOL_H / 2} ch={0.3} lh={POOL_H}>
          <span className="micro-label binv-pool__label">{AMMO_LABEL[pool]}</span>
        </Plate.Line>
        <Plate.Line cy={POOL_H / 2} ch={0.75} lh={POOL_H} end>
          <Numeral value={held} places={2} size="md" />
        </Plate.Line>
      </Plate>
      <span className="binv-pool__drop bc-ch-content">
        <Button size="sm" full disabled={held <= 0} cue="ui.back" onPress={() => { void fetchNui(CB.INV_DROP, { pool }) }}>
          Drop
        </Button>
      </span>
    </div>
  )
}

export default function InventoryPageV2() {
  const inv = useUi(selInv)
  const offset = useUi((s) => s.clockOffset)
  const fx = useBagFx(inv, offset)
  const n = inv.slots.length

  return (
    <Presence id="binv-page" order={0} className="binv-page" style={vars({ '--binv-head-h': u(HEAD_H) })}>
      <div className="binv-page__surface bc-ch-surface" />
      <div className="binv-page__head">
        <Plate variant="strap" height={HEAD_H}>
          <Plate.Line cy={HEAD_H / 2} ch={TITLE_CH} lh={HEAD_H}>
            <Fit className="binv-page__title">Inventory</Fit>
          </Plate.Line>
        </Plate>
      </div>
      <SlotCards inv={inv} fx={fx} />
      <InvPresence
        id="pools"
        order={1 + n}
        last={1 + n}
        live={POOLS.map((pool) => inv.ammo[pool] ?? 0)}
        className="binv-pools"
      >
        <i className="binv-pools__rule bc-ch-surface" aria-hidden />
        <span className="binv-pools__head bc-ch-content">
          <Fit className="binv-pools__title">{AMMO_TITLE}</Fit>
        </span>
        {POOLS.map((pool) => <Pool key={pool} pool={pool} held={inv.ammo[pool] ?? 0} />)}
      </InvPresence>
    </Presence>
  )
}
