import { useState } from 'react'
import { useUi, selInv } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB, RARITY } from '../bridge/types'
import type { InvSlot } from '../bridge/types'
import ItemIcon from '../hud/ItemIcon'
import { play } from '../audio/cues'

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
  index, slot, active, dragging, onDragStart, onDrop, onMove, canLeft, canRight,
}: {
  index: number
  slot: InvSlot | null
  active: boolean
  dragging: number | null
  onDragStart: (i: number) => void
  onDrop: (i: number) => void
  onMove: (from: number, to: number) => void
  canLeft: boolean
  canRight: boolean
}) {
  const hex = slot ? RARITY[slot.rarity].hex : 'rgba(255,255,255,0.15)'

  return (
    // POINTER EVENTS, NOT HTML5 DRAG-AND-DROP.
    //
    // The draggable/onDrop version did nothing at all in game: CEF's HTML5
    // drag support depends on dataTransfer being populated and on a drag image
    // the embedded browser never produces, so `drop` simply never fired (user,
    // 2026-08-05). Pointer down/up needs none of that and behaves identically
    // in the browser harness and in the game.
    //
    // pointerUp on the SOURCE slot is a click (select); pointerUp on a
    // DIFFERENT slot is a swap.
    <div
      onPointerDown={() => { if (slot) onDragStart(index) }}
      onPointerUp={() => onDrop(index)}
      // A CARD IS A PLATE, same as the bar. Square at rest; the held slot
      // takes .is-active, which cuts its corners open -- so the panel and the
      // bar say "this one is in your hands" the same way, and a player only
      // learns the language once.
      className={`plate relative p-3 flex flex-col gap-2 cursor-pointer${
        active ? ' is-active' : ''}`}
      style={{
        ['--edgec' as string]: active ? '#ffffff' : hex,
        // Lifted off near-black so the dark weapon renders read without a
        // second panel behind each one.
        ['--plate-fill' as string]: active
          ? 'rgba(46,52,70,0.95)' : 'rgba(32,36,50,0.94)',
        ['--cut-max' as string]: '1rem',
        opacity: dragging === index ? 0.45 : 1,
        minHeight: '11rem',
      }}
    >
      <div className="flex items-baseline justify-between">
        <span className="font-display text-base tabular-nums text-white/50">
          {index}
        </span>
        {slot && (
          <span
            className="text-[0.75rem] uppercase tracking-[0.14em] flex items-center gap-1.5"
            style={{ color: hex }}
          >
            {/* PIPS ARE A COUNT, and a count works for a player who cannot
                tell two of these colours apart. Hidden by CSS unless a
                colourblind mode is on -- five dots on every slot is clutter
                for everyone who does not need them. */}
            <span className="rarity-pips">
              {Array.from({ length: slot.rarity }, (_, i) => <i key={i} />)}
            </span>
            {RARITY[slot.rarity].label}
          </span>
        )}
      </div>

      {slot ? (
        <>
          <div className="flex-1">
            {/* NO PLATE BEHIND THE ARTWORK. The weapon renders are dark and
                needed lifting off a near-black card -- now solved by lifting
                the CARD (--plate-fill), which was always the right layer. A
                rounded box inside a square card is a box in a box (user,
                2026-08-08). */}
            <div
              className="mb-2 flex items-center justify-center py-2"
              style={{ color: hex }}
            >
              <ItemIcon slot={slot} size="3.4rem" />
            </div>
            <div className="text-lg font-semibold leading-tight">{slot.label}</div>
            <div className="text-[0.8rem] uppercase tracking-wide text-white/45 mt-1">
              {slot.kind}
              {slot.count > 1 && ` · x${slot.count}`}
              {slot.clip != null && ` · ${slot.clip} in clip`}
            </div>
          </div>

          {/* ARROWS, because the drag never LOOKS like a drag.
              CEF gives no drag image and no ghost element, so press-and-
              release across two cards works but reads as nothing happening
              until it is over (user, 2026-08-05). These do the same job with
              no ambiguity, and the press-release gesture still works for
              anyone who finds it. */}
          {/* stopPropagation on the pointer events, not just the click: the
              CARD owns press-and-release as a swap gesture, so without it
              nudging an item left also starts dragging the card. */}
          <div className="flex gap-1 mb-1">
            {([-1, 1] as const).map((dir) => (
              <button
                key={dir}
                type="button"
                disabled={dir < 0 ? !canLeft : !canRight}
                className={`btn plate flex-1 py-1 text-sm leading-none${
                  (dir < 0 ? !canLeft : !canRight) ? ' btn--off' : ''}`}
                style={{
                  ['--edgec' as string]: 'rgba(255,255,255,0.22)',
                  ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
                  ['--cut-max' as string]: '0.35rem',
                }}
                onPointerDown={(e) => e.stopPropagation()}
                onPointerUp={(e) => e.stopPropagation()}
                onPointerEnter={() => play('ui.hover')}
                onClick={(e) => {
                  e.stopPropagation()
                  play('ui.select')
                  onMove(index, index + dir)
                }}
              >
                {dir < 0 ? '◀' : '▶'}
              </button>
            ))}
          </div>

          <div className="flex gap-1.5">
            {slot.kind === 'consumable' && (
              <button
                type="button"
                className="btn plate flex-1 px-2 py-1.5 font-display text-[0.8rem]
                           uppercase tracking-[0.1em]"
                style={{
                  ['--edgec' as string]: 'var(--color-hp)',
                  ['--plate-fill' as string]: 'rgba(18,46,30,0.94)',
                  ['--cut-max' as string]: '0.4rem',
                }}
                onPointerDown={(e) => e.stopPropagation()}
                onPointerUp={(e) => e.stopPropagation()}
                onPointerEnter={() => play('ui.hover')}
                onClick={(e) => {
                  e.stopPropagation()
                  play('ui.select')
                  void fetchNui(CB.INV_USE, { slot: index })
                }}
              >
                Use
              </button>
            )}
            <button
              type="button"
              className="btn plate flex-1 px-2 py-1.5 font-display text-[0.8rem]
                         uppercase tracking-[0.1em]"
              style={{
                ['--edgec' as string]: 'rgba(255,255,255,0.22)',
                ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
                ['--cut-max' as string]: '0.4rem',
              }}
              onPointerDown={(e) => e.stopPropagation()}
              onPointerUp={(e) => e.stopPropagation()}
              onPointerEnter={() => play('ui.hover')}
              onClick={(e) => {
                e.stopPropagation()
                play('ui.back')
                void fetchNui(CB.INV_DROP, { slot: index })
              }}
            >
              Drop
            </button>
          </div>
        </>
      ) : (
        <div className="flex-1 flex items-center justify-center">
          <span className="text-[0.8rem] uppercase tracking-[0.18em] text-white/20">
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

  // Releasing on the slot you pressed is a SELECT; releasing on a different
  // one is a SWAP. One gesture, no modifier keys, and it works with a mouse
  // that CEF will not give us a drag image for.
  const onMove = (from: number, to: number) => {
    if (to < 1 || to > inv.slots.length) return
    void fetchNui(CB.INV_SWAP, { from, to })
  }

  const onDrop = (to: number) => {
    const from = dragging
    setDragging(null)
    if (from == null) {
      void fetchNui(CB.INV_SELECT, { slot: to })
      return
    }
    if (from === to) {
      void fetchNui(CB.INV_SELECT, { slot: to })
      return
    }
    void fetchNui(CB.INV_SWAP, { from, to })
  }

  return (
    // Pointer events on the panel only: the rest of the screen stays playable,
    // which is the entire reason this screen holds keep-input focus.
    <div className="fixed inset-0 z-40 flex items-center justify-center pointer-events-none">
      {/* A PLATE, NOT A PANEL, AND THAT IS THE WHOLE OF THE OWNER'S REPORT --
          twice: "non-rounded corners and a correct background to match our
          current UI".

          `.panel` is the RECEDING surface (index.css): borderless, translucent,
          and `border-radius: var(--r-panel)` = 0.7rem. Every card INSIDE this
          box is a `.plate`, and the file's own note forty lines down says why --
          "A CARD IS A PLATE, same as the bar". So the container was the one
          object in the inventory speaking the other language, with round
          corners around five square ones.

          THE INLINE backgroundColor WAS NOT REPLACING THE BACKGROUND EITHER,
          which is the "wrong background color/gradient" half. `.panel` paints
          `linear-gradient(180deg, rgba(255,255,255,0.05), transparent 42%)` OVER
          `rgba(8,9,14,0.70)` -- two layers of the `background` shorthand.
          `backgroundColor` only replaces the second one, so the panel kept
          wearing the white top-lit wash the rest of the in-match chrome does
          not, and the declared 0.90 was composited under it.

          THE FILL AND THE EDGE ARE COPIED OFF PlayerList.tsx, not invented: that
          is the other panel this interface draws over live gameplay, and being
          the same object as it is what "match our current UI" means here. Its
          `blur(6px)` is deliberately NOT copied -- index.css bans
          backdrop-filter (CEF flicker, and it is expensive), and this box is
          five times the area.

          No --cut-max is set: `.plate` is perfectly square at rest and only
          opens its bevels under `.is-active`, which nothing puts here. */}
      <div
        className="plate pointer-events-auto px-8 py-7 w-[62rem] max-w-[95vw]"
        style={{
          ['--plate-fill' as string]: 'rgba(10,12,18,0.90)',
          ['--edgec' as string]: 'rgba(255,255,255,0.14)',
        }}
      >
        {/* NO INSTRUCTIONS. The arrows are arrows, a card is a thing you
            click, and the key that opened this closes it -- a line of text
            explaining that is a line admitting the screen does not explain
            itself (owner, 2026-08-09). The gestures have not changed; only
            the caption telling you about them is gone. */}
        <div className="mb-4">
          <h2 className="font-display text-3xl uppercase tracking-[0.18em]">
            Inventory
          </h2>
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
              onMove={onMove}
              canLeft={i > 0}
              canRight={i < inv.slots.length - 1}
            />
          ))}
        </div>

        <div className="mt-4 pt-3 border-t border-white/10 flex gap-5">
          {Object.keys(AMMO_LABEL).map((pool) => (
            <div key={pool} className="text-right">
              <div className="font-display text-xl tabular-nums leading-none">
                {inv.ammo[pool] ?? 0}
              </div>
              <div className="text-[0.7rem] uppercase tracking-[0.16em] text-white/40 mt-1">
                {AMMO_LABEL[pool]}
              </div>
            </div>
          ))}
        </div>
      </div>
    </div>
  )
}
