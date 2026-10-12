import { memo } from 'react'
import Box from '@cloudscape-design/components/box'
import Checkbox from '@cloudscape-design/components/checkbox'
import SpaceBetween from '@cloudscape-design/components/space-between'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2TatsPayload } from '../../bridge/types'
import { play } from '../../audio/cues'
import { TATTOOS, ZONE_LABEL, tattooLabels } from './copy'
import { TATTOOS_CAT, anchorId, tattooCat } from './model'

/**
 * THE TATTOOS SECTION OF THE CUSTOM TABS (owner, 2026-10-11): "No cap on
 * tattoos per ped, and yes whatever the game has include DLC sets. They're all
 * free just like the rest of the locker."
 *
 * Every tattoo the game has for this sex, by body zone, each one a checkbox:
 * on puts it on the ped, off takes it off, and any number may be on. As with
 * every row, the page never decides: each press asks Lua (LOCKER2_TAT), which
 * puts it on the ped and sends back which are on, so what is ticked is what
 * the ped wears. A press also sends the zone's category, so the camera goes to
 * that part of the ped, as a row's press does.
 *
 * Some 750 boxes: each is memoized on what it draws, so a push -- one per
 * press, and one every 60 ms while a slider is dragged -- re-renders only the
 * box that changed.
 */

const TattooBox = memo(function TattooBox({ i, label, checked, disabled, cat, onTouch }: {
  i: number
  label: string
  checked: boolean
  disabled: boolean
  cat: string
  onTouch: (cat: string) => void
}) {
  return (
    <div onPointerDown={() => onTouch(cat)}>
      <Checkbox
        checked={checked}
        disabled={disabled}
        onChange={({ detail }) => {
          play('ui.select')
          void fetchNui(CB.LOCKER2_TAT, { i, on: detail.checked })
        }}
      >
        {label}
      </Checkbox>
    </div>
  )
}, (a, b) => a.i === b.i && a.label === b.label && a.checked === b.checked
  && a.disabled === b.disabled && a.cat === b.cat)

export function TattooSection({ tats, on, disabled, onTouch }: {
  tats: Locker2TatsPayload
  on: ReadonlySet<number>
  disabled: boolean
  /** A box was pressed: the camera follows its zone. */
  onTouch: (cat: string) => void
}) {
  return (
    <div id={anchorId(TATTOOS_CAT)}>
      <SpaceBetween size="s">
        <Box variant="h4">{TATTOOS}</Box>
        {tats.zones.map((zone) => {
          const cat = tattooCat(zone.z)
          return (
            <div key={zone.z} id={anchorId(cat)}>
              <SpaceBetween size="xxs">
                <Box variant="h5">{ZONE_LABEL[zone.z] ?? ''}</Box>
                {tattooLabels(zone.items).map(([t, label]) => (
                  <TattooBox key={t.i} i={t.i} label={label}
                    checked={on.has(t.i)} disabled={disabled} cat={cat} onTouch={onTouch} />
                ))}
              </SpaceBetween>
            </div>
          )
        })}
      </SpaceBetween>
    </div>
  )
}
