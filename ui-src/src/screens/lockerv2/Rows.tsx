import { useEffect, useRef, useState } from 'react'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Slider from '@cloudscape-design/components/slider'
import SpaceBetween from '@cloudscape-design/components/space-between'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2CountRow, Locker2SliderRow } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, rowLabel } from './copy'
import { counterText } from './model'

/**
 * ONE ROW OF THE CUSTOM TABS (#28).
 *
 * "say if shoes has 39 options, we should give them a next/last button for
 * the shoes, which also shows them which one is actively being shown on the
 * ped. Getting to 39 and clicking next should cycle back through to 1 and vice
 * versa. There should also be a reset button which sets the value back to 1."
 * (owner). And "for an item which has multiple colors available, we show a
 * button "Next color"".
 *
 * THE PAGE NEVER STEPS A VALUE ITSELF. Each press asks Lua (step, set, color),
 * which wraps, applies it to the ped and sends the row back; what is drawn is
 * always what the ped is wearing.
 */

const unknown = new Set<string>()

/** A row's name; a key the page has no word for is reported once and drawn
 *  without one, never as Lua's key. */
function label(k: string): string | null {
  const l = rowLabel(k)
  if (l === null && !unknown.has(k)) {
    unknown.add(k)
    console.warn(`[locker2] no label for row "${k}"`)
  }
  return l
}

export function CountRow({ row, disabled, onTouch }: {
  row: Locker2CountRow
  disabled: boolean
  /** The row was pressed: the camera follows it. */
  onTouch: () => void
}) {
  const step = (d: 1 | -1) => {
    play('ui.select')
    void fetchNui(CB.LOCKER2_STEP, { k: row.k, d })
  }
  const name = label(row.k)
  return (
    <div onPointerDown={onTouch}>
      <SpaceBetween size="xxxs">
        {name !== null && <Box variant="awsui-key-label">{name}</Box>}
        <SpaceBetween direction="horizontal" size="xs" alignItems="center">
          <Button variant="icon" iconName="angle-left" ariaLabel={BTN.last}
            disabled={disabled} onClick={() => step(-1)} />
          <span style={{ display: 'inline-block', minWidth: '5.5ch', textAlign: 'center' }}>
            <Box variant="span">{counterText(row.v, row.n)}</Box>
          </span>
          <Button variant="icon" iconName="angle-right" ariaLabel={BTN.next}
            disabled={disabled} onClick={() => step(1)} />
          <Button variant="icon" iconName="undo" ariaLabel={BTN.reset}
            disabled={disabled || row.v === 1}
            onClick={() => {
              play('ui.select')
              void fetchNui(CB.LOCKER2_SET, { k: row.k, v: 1 })
            }} />
          {row.colors > 1 && (
            <Button disabled={disabled}
              onClick={() => {
                play('ui.select')
                void fetchNui(CB.LOCKER2_COLOR, { k: row.k })
              }}>
              {BTN.nextColor}
            </Button>
          )}
        </SpaceBetween>
      </SpaceBetween>
    </div>
  )
}

/** How often a dragged slider tells Lua, at most. A drag fires an input per
 *  frame; the ped does not need sixty appearance applies a second. */
const SEND_MS = 60
/** How long after the last touch the slider stops ignoring Lua's echo. */
const HOLD_MS = 400

export function SliderRow({ row, disabled, onTouch }: {
  row: Locker2SliderRow
  disabled: boolean
  onTouch: () => void
}) {
  const [local, setLocal] = useState(row.v)
  const lastTouch = useRef(0)
  const lastSent = useRef(0)
  const pending = useRef<number | null>(null)
  const timer = useRef<number | null>(null)

  // Lua's value wins, except mid-drag, where its echo of a value the handle
  // has already left would make the handle jump back.
  useEffect(() => {
    if (Date.now() - lastTouch.current > HOLD_MS) setLocal(row.v)
  }, [row.v])
  useEffect(() => () => { if (timer.current !== null) window.clearTimeout(timer.current) }, [])

  const send = (v: number) => {
    lastSent.current = Date.now()
    pending.current = null
    void fetchNui(CB.LOCKER2_SET, { k: row.k, v })
  }
  const change = (v: number) => {
    lastTouch.current = Date.now()
    setLocal(v)
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
  return (
    <div onPointerDown={onTouch}>
      <SpaceBetween size="xxxs">
        {name !== null && <Box variant="awsui-key-label">{name}</Box>}
        <div style={{ display: 'flex', alignItems: 'center', gap: '0.5em' }}>
          <div style={{ flex: '1 1 auto', minWidth: 0 }}>
            <Slider value={local} min={row.min} max={row.max} step={1}
              disabled={disabled} ariaLabel={name ?? undefined}
              onChange={({ detail }) => change(detail.value)} />
          </div>
          <Button variant="icon" iconName="undo" ariaLabel={BTN.reset}
            disabled={disabled || local === row.def}
            onClick={() => {
              play('ui.select')
              lastTouch.current = 0
              setLocal(row.def)
              send(row.def)
            }} />
        </div>
      </SpaceBetween>
    </div>
  )
}
