import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import { RARITY } from '../bridge/types'
import type { InvPayload, InvSlot } from '../bridge/types'
import ItemIcon, { FistIcon } from './ItemIcon'

/**
 * The always-on inventory bar.
 *
 * Five slots, matching the slot1..slot5 keybinds one for one -- the number on
 * the slot is the number on the keyboard, whatever the player has rebound
 * (the digits are the DEFAULT binding, and the panel behind TAB is the path
 * for anyone who has moved them).
 *
 * Read-only, like every other HUD component: it renders what INV_SET said and
 * nothing here decides what is in a slot.
 */

const KIND_HINT: Record<InvSlot['kind'], string> = {
  weapon: '',
  ammo: 'ammo',
  consumable: '',
  throwable: '',
}

function Slot({
  index, slot, active, using,
}: {
  index: number
  slot: InvSlot | null
  active: boolean
  using: { endsAt: number; ms: number } | null
}) {
  const hex = slot ? RARITY[slot.rarity].hex : 'rgba(255,255,255,0.18)'
  const fillRef = useRef<HTMLDivElement>(null)
  const offset = useUi((s) => s.clockOffset)

  // The use-progress fill runs on requestAnimationFrame straight to the DOM,
  // the same contract as the storm countdown: `endsAt` is a SERVER timestamp,
  // so it is compared against the offset-corrected clock, and React is not
  // re-rendered sixty times a second to move a bar.
  useEffect(() => {
    if (!using) return
    let raf = 0
    const tick = () => {
      const node = fillRef.current
      if (node) {
        const left = Math.max(0, using.endsAt - (Date.now() + offset))
        const pct = using.ms > 0 ? 1 - left / using.ms : 1
        node.style.transform = `scaleX(${Math.min(1, Math.max(0, pct))})`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [using, offset])

  return (
    // Sized up from 3.6rem: at the old size the labels were unreadable at a
    // glance, which is the only thing this bar is for (user, 2026-08-05).
    // rem is tied to viewport height, so this scales with resolution.
    <div
      className="relative w-[5.2rem] h-[5.2rem] rounded-md overflow-hidden"
      style={{
        // No color-mix() and no oklch(): CEF is Chrome 103 and drops what it
        // cannot parse, which makes the slot silently invisible.
        backgroundColor: active ? 'rgba(52,44,80,0.92)' : 'rgba(14,11,24,0.88)',
        border: `1px solid ${active ? '#ffffff' : hex}`,
        boxShadow: active ? '0 0 0 1px rgba(255,255,255,0.35)' : 'none',
      }}
    >
      <div
        className="absolute top-0 left-0 px-1 text-[0.7rem] font-bold tabular-nums"
        style={{ color: 'rgba(255,255,255,0.55)' }}
      >
        {index}
      </div>

      {slot && (
        <>
          {/* A rarity band rather than an icon: there are 39 weapons and no
              vanilla icon set that covers them, and the colour is the thing
              players actually read at a glance. */}
          <div
            className="absolute bottom-0 left-0 right-0 h-[0.2rem]"
            style={{ backgroundColor: hex }}
          />
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-0.5 px-1">
            {/* Same light plate as the panel: the weapon renders are dark grey
                on transparency and vanish against a near-black slot. Lifting
                the artwork rather than the whole slot keeps the white label
                readable (user, 2026-08-06). */}
            <div
              className="rounded px-1.5 py-0.5"
              style={{
                color: hex,
                backgroundColor: 'rgba(226,226,236,0.16)',
              }}
            >
              <ItemIcon slot={slot} size="2.3rem" />
            </div>
            <span
              className="text-[0.6rem] leading-tight text-center uppercase tracking-wide"
              style={{ color: 'rgba(255,255,255,0.75)' }}
            >
              {slot.label}
            </span>
          </div>
          {/* A weapon shows its magazine, everything else its stack. Both were
              missing before -- a weapon with clip 24 and count 1 fell through
              the count > 1 test and showed no number at all. */}
          {(slot.kind === 'weapon' ? slot.clip != null : slot.count > 1) && (
            <div className="absolute bottom-0 right-0 px-1 text-[0.85rem] font-bold tabular-nums">
              {slot.kind === 'weapon' ? slot.clip : slot.count}
            </div>
          )}
          {KIND_HINT[slot.kind] && (
            <div className="absolute top-0 right-0 px-1 text-[0.55rem] uppercase text-white/40">
              {KIND_HINT[slot.kind]}
            </div>
          )}
        </>
      )}

      {using && (
        <div className="absolute bottom-0 left-0 right-0 h-[0.28rem] bg-black/60">
          <div
            ref={fillRef}
            className="h-full origin-left"
            style={{ backgroundColor: '#ffffff', transform: 'scaleX(0)' }}
          />
        </div>
      )}
    </div>
  )
}

export default function InventoryBar({ inv }: { inv: InvPayload }) {
  const active = inv.slots[inv.active - 1] ?? null
  const reserve = active?.pool ? (inv.ammo[active.pool] ?? 0) : 0

  return (
    <div className="flex flex-col items-end gap-1">
      {/* Ammo for the weapon actually in hand. Nothing is shown for an empty
          hand or a consumable -- a "0 / 0" under a bandage is noise. */}
      {/* MELEE HAS NO AMMO PANEL. A machete carries no clip, and `clip == null`
          is exactly how the server says so -- printing "0 / 0" under a hatchet
          is the same noise the comment above warns about for consumables. */}
      {active && active.kind === 'weapon' && active.clip != null && (
        <div className="panel px-2.5 py-1 flex items-baseline gap-1.5">
          <span className="text-2xl font-bold tabular-nums leading-none">
            {active.clip ?? 0}
          </span>
          <span className="text-base tabular-nums text-white/45 leading-none">
            / {reserve}
          </span>
        </div>
      )}

      <div className="flex gap-1">
        {/* SLOT ZERO: FISTS. Left of slot 1, always there, never fillable.
            Part of the scroll ring, so putting the gun away is one flick
            rather than a thing you have to drop something to do. */}
        <div
          className="relative w-[5.2rem] h-[5.2rem] rounded-md overflow-hidden
                     flex flex-col items-center justify-center gap-0.5"
          style={{
            backgroundColor: inv.active === 0
              ? 'rgba(52,44,80,0.92)' : 'rgba(14,11,24,0.88)',
            border: `1px solid ${inv.active === 0
              ? '#ffffff' : 'rgba(255,255,255,0.18)'}`,
            boxShadow: inv.active === 0
              ? '0 0 0 1px rgba(255,255,255,0.35)' : 'none',
          }}
        >
          <div
            className="rounded px-1.5 py-0.5"
            style={{
              color: 'rgba(255,255,255,0.85)',
              backgroundColor: 'rgba(226,226,236,0.16)',
            }}
          >
            <FistIcon size="2.3rem" />
          </div>
          <span
            className="text-[0.6rem] leading-tight uppercase tracking-wide"
            style={{ color: 'rgba(255,255,255,0.6)' }}
          >
            Fists
          </span>
        </div>

        {inv.slots.map((slot, i) => (
          <Slot
            key={i}
            index={i + 1}
            slot={slot}
            active={inv.active === i + 1}
            using={inv.using && inv.using.slot === i + 1 ? inv.using : null}
          />
        ))}
      </div>
    </div>
  )
}
