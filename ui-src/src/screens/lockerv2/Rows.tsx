import { memo, useEffect, useRef, useState } from 'react'
import Icon from '@cloudscape-design/components/icon'
import Slider from '@cloudscape-design/components/slider'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2CountRow, Locker2PalPayload, Locker2SliderRow } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, rowLabel, swatchLabel } from './copy'
import {
  SLIDER_HOLD_MS, counterText, nameShown, sliderShown, swatchOf, swatchRequest, swatchesShown, textureFace, textureOf,
  textureRequest, texturesShown,
} from './model'
import { useHold } from './hold'

/**
 * ONE ROW OF THE EDITOR (#28).
 *
 * "say if shoes has 39 options, we should give them a next/last button for
 * the shoes, which also shows them which one is actively being shown on the
 * ped. Getting to 39 and clicking next should cycle back through to 1 and vice
 * versa. There should also be a reset button which sets the value back to 1."
 * (owner). With My Looks (2026-10-13): the arrows repeat while held,
 * accelerating; hair and makeup colors are a swatch grid, not "Next color".
 * Then (2026-10-14): an item's own colors are a swatch button too ("any
 * button showing "next color" should have a button for a color swatch
 * instead"), and no item shows the game's name for it unless its category
 * does (model.ts NAMED_CATS: "All or nothing on that").
 *
 * THE PAGE NEVER STEPS A VALUE ITSELF. Each press asks Lua (step, set, color),
 * which wraps, applies it to the ped and sends the row back; what is drawn is
 * always what the ped is wearing.
 *
 * EVERY ROW IS MEMOIZED ON ITS ROW. A push hands back the same row object for
 * every row it did not change (model.ts share), so a press redraws its own
 * row and nothing else.
 */

const unknown = new Set<string>()

/** A row's name; a key the page has no word for is reported once and drawn
 *  without one, never as Lua's key. */
export function label(k: string): string | null {
  const l = rowLabel(k)
  if (l === null && !unknown.has(k)) {
    unknown.add(k)
    console.warn(`[locker2] no label for row "${k}"`)
  }
  return l
}

/** A square plate with one icon: the lobby's button language, in the
 *  island's em. `hold` repeats it while pressed. */
export function IconBtn({ icon, label: aria, disabled, onPress, hold = false }: {
  icon: 'angle-left' | 'angle-right' | 'refresh' | 'remove'
  label: string
  disabled: boolean
  onPress: () => void
  hold?: boolean
}) {
  const held = useHold(onPress, undefined, disabled)
  const press = hold ? held : { onClick: () => { if (!disabled) onPress() } }
  return (
    <button type="button" className={`plate btn lk2-icon${disabled ? ' btn--off' : ''}`}
      aria-label={aria} aria-disabled={disabled} {...press}>
      <Icon name={icon} />
    </button>
  )
}

/** A palette's swatches, the worn one ringed. 64 at most. */
const Swatches = memo(function Swatches({ colors, chosen, disabled, onPick }: {
  colors: readonly string[]
  chosen: number | null
  disabled: boolean
  onPick: (i: number) => void
}) {
  return (
    <div className="lk2-swatches" role="group">
      {colors.map((c, i) => (
        <button key={i} type="button" data-plain
          className={`lk2-swatch${i === chosen ? ' is-on' : ''}`}
          style={{ background: c }}
          aria-label={swatchLabel(i + 1)} aria-pressed={i === chosen} disabled={disabled}
          onClick={() => onPick(i)} />
      ))}
    </div>
  )
})

/**
 * AN ITEM'S COLORS (its textures): the button wears the color on -- its
 * swatch where Lua sends the item's colors, else its place among them -- and
 * opens the item's colors under the row, the one on lit. A press there sends
 * LOCKER2_COLOR { k, c }; the grid stays open to try another, and the button
 * closes it.
 */
const TextureButton = memo(function TextureButton({ row, open, disabled, onToggle }: {
  row: Locker2CountRow
  open: boolean
  disabled: boolean
  onToggle: () => void
}) {
  const c = textureOf(row)
  const face = textureFace(row, c)
  return (
    <button type="button" className="plate btn lk2-icon lk2-texbtn" aria-label={swatchLabel(c + 1)}
      aria-expanded={open} aria-disabled={disabled} onClick={() => { if (!disabled) onToggle() }}>
      {'color' in face ? <span className="lk2-texchip" style={{ background: face.color }} /> : face.n}
    </button>
  )
})

const TextureGrid = memo(function TextureGrid({ row, disabled }: { row: Locker2CountRow; disabled: boolean }) {
  const on = textureOf(row)
  return (
    <div className="lk2-texgrid" role="group">
      {Array.from({ length: row.colors }, (_, i) => {
        const face = textureFace(row, i)
        return 'color' in face ? (
          <button key={i} type="button" data-plain className={`lk2-swatch${i === on ? ' is-on' : ''}`}
            style={{ background: face.color }} aria-label={swatchLabel(i + 1)} aria-pressed={i === on}
            disabled={disabled} onClick={() => pickTexture(row, i)} />
        ) : (
          <button key={i} type="button" className={`plate btn lk2-tex${i === on ? ' is-active' : ''}`}
            aria-label={swatchLabel(i + 1)} aria-pressed={i === on} disabled={disabled}
            onClick={() => pickTexture(row, i)}>
            {face.n}
          </button>
        )
      })}
    </div>
  )
})

function pickTexture(row: Locker2CountRow, i: number) {
  if (i === textureOf(row)) return
  play('ui.select')
  void fetchNui(CB.LOCKER2_COLOR, textureRequest(row, i))
}

/**
 * A counter row: Last / `v/n` / Next, both arrows held to scroll; Reset; the
 * item's colors as a swatch button, or its palette's swatches. The highlight
 * is a color and nothing else: swatches alone.
 */
export const CountRow = memo(function CountRow({ row, pal, disabled, onTouch }: {
  row: Locker2CountRow
  pal: Locker2PalPayload | null
  disabled: boolean
  /** The row was pressed: the camera follows it. */
  onTouch: (cat: string) => void
}) {
  const [texOpen, setTexOpen] = useState(false)
  const step = (d: 1 | -1) => {
    play('ui.select')
    void fetchNui(CB.LOCKER2_STEP, { k: row.k, d })
  }
  const name = label(row.k)
  const caption = nameShown(row)
  const textures = texturesShown(row)
  const colors = row.pal !== undefined ? pal?.[row.pal] ?? null : null
  const swatches = colors !== null && colors.length > 0 && swatchesShown(row)
  const colorOnly = row.k === 'h1'
  const pick = (i: number) => {
    play('ui.select')
    const req = swatchRequest(row, i)
    void fetchNui(req.cb === 'set' ? CB.LOCKER2_SET : CB.LOCKER2_COLOR, req.data)
  }
  return (
    <div className="lk2-row" onPointerDown={() => onTouch(row.cat)}>
      {name !== null && <div className="lk2-row-label lk2-fit"><span>{name}</span></div>}
      {!(colorOnly && swatches) && (
        <div className="lk2-stepper">
          <IconBtn icon="angle-left" label={BTN.last} disabled={disabled} hold onPress={() => step(-1)} />
          <span className="lk2-count">{counterText(row.v, row.n)}</span>
          <IconBtn icon="angle-right" label={BTN.next} disabled={disabled} hold onPress={() => step(1)} />
          <IconBtn icon="refresh" label={BTN.reset} disabled={disabled || row.v === 1}
            onPress={() => {
              play('ui.select')
              void fetchNui(CB.LOCKER2_SET, { k: row.k, v: 1 })
            }} />
          {textures && (
            <TextureButton row={row} open={texOpen} disabled={disabled}
              onToggle={() => { play('ui.select'); setTexOpen((o) => !o) }} />
          )}
        </div>
      )}
      {caption !== null && <div className="lk2-caption lk2-fit"><span>{caption}</span></div>}
      {textures && texOpen && <TextureGrid row={row} disabled={disabled} />}
      {swatches && (
        <Swatches colors={colors} chosen={swatchOf(row)} disabled={disabled} onPick={pick} />
      )}
    </div>
  )
})

/** How often a dragged slider tells Lua, at most. A drag fires an input per
 *  frame; the ped does not need sixty appearance applies a second. */
const SEND_MS = 60

export const SliderRow = memo(function SliderRow({ row, disabled, onTouch, bare = false }: {
  row: Locker2SliderRow
  disabled: boolean
  onTouch: (cat: string) => void
  /** In a face group: the group has the one reset (owner, 2026-10-13). */
  bare?: boolean
}) {
  const [local, setLocal] = useState(row.v)
  const lastTouch = useRef(0)
  const lastSent = useRef(0)
  const pending = useRef<number | null>(null)
  const timer = useRef<number | null>(null)
  // Re-renders once a touch's hold is over, so what is drawn goes back to
  // Lua's value even when Lua never sent a new one (a set it refused).
  const [, settle] = useState(0)
  const settleTimer = useRef<number | null>(null)

  // Lua's value wins, except while the handle is being touched, where its
  // echo of a value the handle has already left would make it jump back.
  const shown = sliderShown(local, row.v, lastTouch.current, Date.now())
  useEffect(() => () => {
    if (timer.current !== null) window.clearTimeout(timer.current)
    if (settleTimer.current !== null) window.clearTimeout(settleTimer.current)
  }, [])

  const send = (v: number) => {
    lastSent.current = Date.now()
    pending.current = null
    void fetchNui(CB.LOCKER2_SET, { k: row.k, v })
  }
  /** The handle is at `v` now: drawn there through the hold, then Lua's. */
  const touch = (v: number) => {
    lastTouch.current = Date.now()
    setLocal(v)
    if (settleTimer.current !== null) window.clearTimeout(settleTimer.current)
    settleTimer.current = window.setTimeout(() => {
      settleTimer.current = null
      settle((n) => n + 1)
    }, SLIDER_HOLD_MS + 20)
  }
  const change = (v: number) => {
    touch(v)
    const wait = SEND_MS - (Date.now() - lastSent.current)
    if (wait <= 0) { send(v); return }
    pending.current = v
    if (timer.current === null) {
      timer.current = window.setTimeout(() => {
        timer.current = null
        if (pending.current !== null) send(pending.current)
      }, wait)
    }
  }

  const name = label(row.k)
  // An opacity of an overlay that is none moves nothing on the ped.
  const off = disabled || row.off === true
  return (
    <div className="lk2-row" onPointerDown={() => onTouch(row.cat)}>
      {name !== null && <div className="lk2-row-label lk2-fit"><span>{name}</span></div>}
      <div className="lk2-slider">
        <div className="lk2-slider-track">
          <Slider value={shown} min={row.min} max={row.max} step={1}
            disabled={off} ariaLabel={name ?? undefined}
            onChange={({ detail }) => change(detail.value)} />
        </div>
        {!bare && (
          <IconBtn icon="refresh" label={BTN.reset} disabled={off || shown === row.def}
            onPress={() => {
              play('ui.select')
              touch(row.def)
              send(row.def)
            }} />
        )}
      </div>
    </div>
  )
})
