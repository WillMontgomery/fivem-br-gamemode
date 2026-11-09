import { useMemo, useState } from 'react'
import type { InvPayload, InvSlot } from '../../bridge/types'

/**
 * WHAT CHANGED IN THE BAG (#431): the Broadcast bar's and page's beats.
 *
 * The bar is never told an event, only a new bag: BR.Inv.push sends the whole
 * inventory on every mutation (a shot, a pickup, a swap, a use beginning and
 * ending). So every effect is derived by comparing this reading with the last
 * one, slot by slot, and kept as a COUNTER that starts at 0 (the kit's beat
 * rule: a mount animates nothing, and a presence entering fires nothing).
 *
 *   arrive   one new item landed here (a pickup): the slab bursts in its
 *            rarity and the art drops in
 *   punch    a swap moved it: the plate shoves toward where it went
 *   sweep    a new bag landed (three slots or more at once: a spectate switch):
 *            a light crosses the plate instead
 *   recolor  the slab's color changed (picked up, dropped, used up, the hand):
 *            the old color retracts
 *   pick     it became the slot in hand: the number wipes in
 *   pop      its stack grew
 *   use      a use began here: the foot line slides in and fills
 *   done     a use ended here: the line zips away in accent from where it was
 *
 * Pure but for the clock read that dates a use's end, so the zip starts from
 * the fraction the bar had reached: snapOf and nextFx are the derivation
 * itself, and scripts/test-inventory-fx.mjs drives them reading by reading.
 */

export const FIST_EDGE = 'var(--bc-rule-quiet)'
export const EMPTY_EDGE = 'var(--bc-rule-quiet)'
export const HELD_EDGE = 'var(--bc-accent)'

/** The slab a plate shows: the rarity; the accent for the fists or an empty
 *  slot in hand (an item in hand keeps its rarity: the teal deck says held). */
export function edgeOf(index: number, slot: InvSlot | null, held: boolean): string {
  if (index !== 0 && slot) return `var(--bc-rarity-${slot.rarity})`
  return held ? HELD_EDGE : index === 0 ? FIST_EDGE : EMPTY_EDGE
}

/** The number a slot shows: a weapon its magazine, anything else its stack
 *  when there is more than one (InventoryBar.tsx's rule). */
export function countOf(slot: InvSlot | null): number | null {
  if (!slot) return null
  if (slot.kind === 'weapon') return slot.clip ?? null
  return slot.count > 1 ? slot.count : null
}

interface SlotSnap {
  key: string | null
  edge: string
  count: number
}

export interface Snap {
  /** Index 0 is the fists, 1..5 the slots. */
  slots: SlotSnap[]
  active: number
  useSlot: number
  useEnds: number
  useMs: number
  /** The weapon in hand, for the ammo strap. */
  gun: string | null
  gunEdge: string
  clip: number
}

export interface SlotFx {
  arrive: number
  punch: { n: number; dir: number }
  sweep: number
  recolor: { n: number; prev: string }
  pick: number
  pop: number
  use: number
  done: { n: number; from: number }
}

export interface BarFx {
  slots: SlotFx[]
  /** The ammo strap's slab took another gun's rarity. */
  gunRecolor: { n: number; prev: string }
  /** A reload: the clip rose on the same gun. */
  reload: number
}

/** What a slot holds, as one item: the same item at the same rarity is the
 *  same (two alike are one), whatever its stack, clip or fill. A change of it
 *  is an item landing in the slot, and to the page's drag (Page.tsx) the held
 *  item gone. */
export const keyOf = (s: InvSlot | null): string | null => (s ? `${s.id}:${s.rarity}` : null)

/** One reading of the bag, as the beats compare it. */
export function snapOf(inv: InvPayload): Snap {
  const slots: SlotSnap[] = [{ key: 'fists', edge: edgeOf(0, null, inv.active === 0), count: 0 }]
  inv.slots.forEach((s, i) => {
    slots.push({ key: keyOf(s), edge: edgeOf(i + 1, s, inv.active === i + 1), count: s ? s.count : 0 })
  })
  const held = inv.slots[inv.active - 1] ?? null
  const gun = held && held.kind === 'weapon' && held.clip != null ? held : null
  return {
    slots,
    active: inv.active,
    useSlot: inv.using?.slot ?? -1,
    useEnds: inv.using?.endsAt ?? 0,
    useMs: inv.using?.ms ?? 0,
    gun: keyOf(gun),
    gunEdge: gun ? `var(--bc-rarity-${gun.rarity})` : '',
    clip: gun?.clip ?? 0,
  }
}

function quiet(): SlotFx {
  return {
    arrive: 0, punch: { n: 0, dir: 0 }, sweep: 0, recolor: { n: 0, prev: '' }, pick: 0, pop: 0, use: 0,
    done: { n: 0, from: 0 },
  }
}

/** Every beat at 0: the first reading's, so a mount plays nothing. */
export function emptyFx(n: number): BarFx {
  return { slots: Array.from({ length: n }, quiet), gunRecolor: { n: 0, prev: '' }, reload: 0 }
}

/** The beats after reading `b` where the last reading was `a`. `now` is the
 *  server's time (a use's end is one). */
export function nextFx(a: Snap, b: Snap, fx: BarFx, now: number): BarFx {
  const changed: number[] = []
  for (let i = 1; i < b.slots.length; i++) if (a.slots[i]?.key !== b.slots[i]?.key) changed.push(i)
  const newBag = changed.length >= 3
  const slots = b.slots.map((cur, i) => {
    const was = a.slots[i]
    const f = fx.slots[i] ?? quiet()
    let next = f
    const edit = (patch: Partial<SlotFx>) => { next = { ...next, ...patch } }
    if (was && was.edge !== cur.edge) edit({ recolor: { n: f.recolor.n + 1, prev: was.edge } })
    if (i > 0 && was && was.key !== cur.key && cur.key !== null) {
      if (newBag) {
        edit({ sweep: f.sweep + 1 })
      } else {
        // A swap: the item here was in slot j, and what was here is there now.
        const j = changed.find((k) => k !== i && a.slots[k]?.key === cur.key && b.slots[k]?.key === was.key)
        if (j !== undefined) edit({ punch: { n: f.punch.n + 1, dir: Math.sign(i - j) } })
        else edit({ arrive: f.arrive + 1 })
      }
    }
    if (i > 0 && was && was.key === cur.key && cur.count > was.count) edit({ pop: f.pop + 1 })
    if (b.active === i && a.active !== i) edit({ pick: f.pick + 1 })
    if (b.useSlot === i && (a.useSlot !== i || a.useEnds !== b.useEnds)) edit({ use: f.use + 1 })
    if (a.useSlot === i && (b.useSlot !== i || b.useEnds !== a.useEnds)) {
      const from = a.useMs > 0 ? Math.min(1, Math.max(0, 1 - (a.useEnds - now) / a.useMs)) : 1
      edit({ done: { n: f.done.n + 1, from } })
    }
    return next
  })
  let gunRecolor = fx.gunRecolor
  let reload = fx.reload
  if (a.gun && b.gun && a.gunEdge !== b.gunEdge) gunRecolor = { n: gunRecolor.n + 1, prev: a.gunEdge }
  if (a.gun && a.gun === b.gun && b.clip > a.clip && a.active === b.active) reload += 1
  return { slots, gunRecolor, reload }
}

/** The beats for a bag, against the last reading of it. `offset` is the
 *  store's clockOffset (a use's end is a server time). */
export function useBagFx(inv: InvPayload, offset: number): BarFx {
  const snap = useMemo(() => snapOf(inv), [inv])
  const [st, setSt] = useState(() => ({ snap, fx: emptyFx(snap.slots.length) }))
  if (st.snap !== snap) {
    const next = { snap, fx: nextFx(st.snap, snap, st.fx, Date.now() + offset) }
    setSt(next)
    return next.fx
  }
  return st.fx
}
