import { useState } from 'react'
import { useUi, selInv } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB, RARITY } from '../bridge/types'
import type { InvSlot } from '../bridge/types'

/**
 * The TAB panel.
 *
 * Opened and closed by Lua (the `inventory` keybind pushes NUI focus), which
 * is why there is no open/close state here -- App renders this whenever focus
 * says 'inventory'. Focus is granted with KEEP-INPUT: the match does not stop
 * while it is up, so this is not a menu to hide in.
 *
 * Every control is a REQUEST. Nothing below mutates the store; the slot moves
 * when INV_SET comes back, which is also why a refused action reads as
 * "nothing happened" rather than as a UI that undid itself.
 */

const AMMO_LABEL: Record<string, string> = {
  light: 'Light',
  smg: 'SMG',
  medium: 'Medium',
  shells: 'Shells',
  heavy: 'Heavy',
}

function SlotCard({
  index, slot, active, dragging, onDragStart, onDrop,
}: {
  index: number
  slot: InvSlot | null
  active: boolean
  dragging: number | null
  onDragStart: (i: number) => void
  onDrop: (i: number) => void
}) {
  const hex = slot ? RARITY[slot.rarity].hex : 'rgba(255,255,255,0.15)'

  return (
    <div
      draggable={!!slot}
      onDragStart={() => onDragStart(index)}
      onDragOver={(e) => e.preventDefault()}
      onDrop={(e) => {
        e.preventDefault()
        onDrop(index)
      }}
      onClick={() => void fetchNui(CB.INV_SELECT, { slot: index })}
      className="relative rounded-lg p-3 flex flex-col gap-2 cursor-pointer
                 transition-colors duration-100"
      style={{
        backgroundColor: active ? 'rgba(255,255,255,0.12)' : 'rgba(0,0,0,0.45)',
        border: `1px solid ${active ? '#ffffff' : hex}`,
        opacity: dragging === index ? 0.45 : 1,
        minHeight: '7.5rem',
      }}
    >
      <div className="flex items-baseline justify-between">
        <span className="text-[0.7rem] font-bold tabular-nums text-white/50">
          {index}
        </span>
        {slot && (
          <span
            className="text-[0.55rem] uppercase tracking-[0.14em]"
            style={{ color: hex }}
          >
            {RARITY[slot.rarity].label}
          </span>
        )}
      </div>

      {slot ? (
        <>
          <div className="flex-1">
            <div className="text-sm font-semibold leading-tight">{slot.label}</div>
            <div className="text-[0.6rem] uppercase tracking-wide text-white/40 mt-0.5">
              {slot.kind}
              {slot.count > 1 && ` · x${slot.count}`}
              {slot.clip != null && ` · ${slot.clip} in clip`}
            </div>
          </div>

          <div className="flex gap-1.5">
            {slot.kind === 'consumable' && (
              <button
                type="button"
                className="flex-1 rounded px-2 py-1 text-[0.6rem] uppercase
                           tracking-wider bg-white/15 hover:bg-white/25"
                onClick={(e) => {
                  e.stopPropagation()
                  void fetchNui(CB.INV_USE, { slot: index })
                }}
              >
                Use
              </button>
            )}
            <button
              type="button"
              className="flex-1 rounded px-2 py-1 text-[0.6rem] uppercase
                         tracking-wider bg-white/10 hover:bg-white/20"
              onClick={(e) => {
                e.stopPropagation()
                void fetchNui(CB.INV_DROP, { slot: index })
              }}
            >
              Drop
            </button>
          </div>
        </>
      ) : (
        <div className="flex-1 flex items-center justify-center">
          <span className="text-[0.6rem] uppercase tracking-[0.18em] text-white/20">
            Empty
          </span>
        </div>
      )}
    </div>
  )
}

export default function InventoryPanel() {
  const inv = useUi(selInv)
  const [dragging, setDragging] = useState<number | null>(null)

  const onDrop = (to: number) => {
    const from = dragging
    setDragging(null)
    if (from == null || from === to) return
    void fetchNui(CB.INV_SWAP, { from, to })
  }

  return (
    // Pointer events on the panel only: the rest of the screen stays playable,
    // which is the entire reason this screen holds keep-input focus.
    <div className="fixed inset-0 z-40 flex items-center justify-center pointer-events-none">
      <div
        className="panel pointer-events-auto px-6 py-5 w-[44rem] max-w-[92vw]"
        style={{ backgroundColor: 'rgba(10,8,20,0.88)' }}
      >
        <div className="flex items-baseline justify-between mb-4">
          <h2 className="text-lg font-black uppercase tracking-[0.18em]">
            Inventory
          </h2>
          <span className="text-[0.6rem] uppercase tracking-[0.16em] text-white/35">
            drag to reorder · click to equip
          </span>
        </div>

        <div className="grid grid-cols-5 gap-2">
          {inv.slots.map((slot, i) => (
            <SlotCard
              key={i}
              index={i + 1}
              slot={slot}
              active={inv.active === i + 1}
              dragging={dragging}
              onDragStart={setDragging}
              onDrop={onDrop}
            />
          ))}
        </div>

        <div className="mt-4 pt-3 border-t border-white/10 flex gap-5">
          {Object.keys(AMMO_LABEL).map((pool) => (
            <div key={pool} className="text-right">
              <div className="text-sm font-bold tabular-nums leading-none">
                {inv.ammo[pool] ?? 0}
              </div>
              <div className="text-[0.5rem] uppercase tracking-[0.16em] text-white/40 mt-0.5">
                {AMMO_LABEL[pool]}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
