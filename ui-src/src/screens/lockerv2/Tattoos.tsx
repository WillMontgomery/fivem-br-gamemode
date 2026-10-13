import { memo, useMemo, useState } from 'react'
import AttributeEditor from '@cloudscape-design/components/attribute-editor'
import type { AttributeEditorProps } from '@cloudscape-design/components/attribute-editor'
import Box from '@cloudscape-design/components/box'
import Select from '@cloudscape-design/components/select'
import type { SelectProps } from '@cloudscape-design/components/select'
import SpaceBetween from '@cloudscape-design/components/space-between'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2TatRow, Locker2TatsPayload } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, TATTOOS, ZONE_LABEL, tattooLabels } from './copy'
import {
  TATTOOS_CAT, anchorId, canAddTattoo, sameTatRows, tattooCat, tattooChoices, tattooFilter, zoneRows,
} from './model'
import './tattoos.css'

/**
 * THE TATTOOS SECTION OF THE CUSTOM TABS (owner, 2026-10-12): "a list,
 * starting empty, with add and remove buttons ... You can just make it max 10
 * per category." Then, of a list of big cards: "This takes up wayyyy too much
 * real estate ... perhaps we use the thing that's literally made for this -
 * attribute editor."
 *
 * One Cloudscape AttributeEditor per body zone, under the zone's heading. Each
 * item is one row, its one field a Select of the zone's tattoos for this sex
 * by the game's names, filtered by name as typed; its Remove beside it; Add under the
 * rows, off at TATTOOS_PER_ZONE. A row's list never offers what another row of
 * its zone holds, so a zone never has one tattoo twice.
 *
 * As with every row, the page never decides: Add, a choice and Remove each ask
 * Lua (LOCKER2_TAT_ADD, _SET, _DEL), which holds every rule, puts the tattoo on
 * the ped at once and sends the rows back; Add's row starts on the zone's first
 * tattoo no row holds. Any press in a zone also sends its category, so the
 * camera goes to that part of the ped.
 *
 * COMPACT: the section wears Cloudscape's own compact density (its
 * `awsui-compact-mode` class, scoped to the section and nothing else in the
 * locker), so a row is a 28 px Select and its Remove, 16 px apart.
 *
 * The Select's list opens inside the island (expandToViewport false), as the
 * Save menu's does (Footer.tsx); while it is open, Escape is its own
 * (LockerV2.tsx). A push -- one per press, and one every 60 ms
 * while a slider is dragged -- re-renders a zone only when its rows changed.
 */

/** The editor's one field and its Remove on one line at every width; no
 *  field label (tattoos.css keeps the first row's Remove level with its
 *  Select, where Cloudscape leaves room for a label). */
const ROW_LAYOUT: readonly AttributeEditorProps.GridLayout[] = [{ rows: [[1]], removeButton: { width: 'auto' } }]

/** A tattoo's option: its id in the list and what the Select draws. */
type TatOpt = { i: number, option: Required<Pick<SelectProps.Option, 'value' | 'label'>> }

/** One row's field: a Select of the zone's tattoos no other row holds
 *  (tattooChoices), narrowed as typed by the name alone (tattooFilter, #28
 *  review -- Cloudscape's own filter also searches the hidden value, the
 *  tattoo's number in the list). The typed text is this Select's own:
 *  Cloudscape sends '' through onLoadItems as it opens again. */
function TattooPick({ row, rows, opts, byI, disabled }: {
  row: Locker2TatRow
  rows: readonly Locker2TatRow[]
  opts: readonly TatOpt[]
  byI: ReadonlyMap<number, TatOpt['option']>
  disabled: boolean
}) {
  const [typed, setTyped] = useState('')
  return (
    <Select
      selectedOption={byI.get(row.i) ?? null}
      options={tattooFilter(tattooChoices(opts, rows, row).map((o) => o.option), typed)}
      filteringType="manual"
      onLoadItems={({ detail }) => setTyped(detail.filteringText)}
      expandToViewport={false}
      disabled={disabled}
      onChange={({ detail }) => {
        const i = Number(detail.selectedOption.value)
        if (!Number.isInteger(i) || i === row.i) return
        play('ui.select')
        void fetchNui(CB.LOCKER2_TAT_SET, { r: row.r, i })
      }}
    />
  )
}

/** One zone: its heading, its anchor and its editor. Drawn again only when its
 *  rows or `disabled` change -- `onTouch` is CustomTab's toCat, a new function
 *  each render that always sends the same thing. The editor's own Remove has
 *  no off state: while the ped is held it sends nothing, and Lua refuses every
 *  change then anyway. */
const ZoneEditor = memo(function ZoneEditor({ zone, rows, disabled, onTouch }: {
  zone: Locker2TatsPayload['zones'][number]
  /** This zone's rows, in Lua's order. */
  rows: readonly Locker2TatRow[]
  disabled: boolean
  onTouch: (cat: string) => void
}) {
  const cat = tattooCat(zone.z)
  // Each tattoo's option: the game's name, a nameless one numbered among the
  // nameless of its zone -- never its key. Built once per list.
  const opts = useMemo(() => tattooLabels(zone.items).map(([t, label]) => ({
    i: t.i, option: { value: String(t.i), label },
  })), [zone.items])
  const byI = useMemo(() => new Map(opts.map((o) => [o.i, o.option])), [opts])
  return (
    <div id={anchorId(cat)} onPointerDown={() => onTouch(cat)}>
      <SpaceBetween size="xs">
        <Box variant="h5">{ZONE_LABEL[zone.z] ?? ''}</Box>
        <AttributeEditor
          items={rows}
          gridLayout={ROW_LAYOUT}
          definition={[{
            control: (row: Locker2TatRow) => (
              <TattooPick row={row} rows={rows} opts={opts} byI={byI} disabled={disabled} />
            ),
          }]}
          addButtonText={BTN.add}
          removeButtonText={BTN.remove}
          disableAddButton={disabled || !canAddTattoo(rows.length, zone.items.length)}
          onAddButtonClick={() => {
            play('ui.select')
            void fetchNui(CB.LOCKER2_TAT_ADD, { z: zone.z })
          }}
          onRemoveButtonClick={({ detail }) => {
            const row = rows[detail.itemIndex]
            if (!row || disabled) return
            play('ui.select')
            void fetchNui(CB.LOCKER2_TAT_DEL, { r: row.r })
          }}
        />
      </SpaceBetween>
    </div>
  )
}, (a, b) => a.zone === b.zone && a.disabled === b.disabled && sameTatRows(a.rows, b.rows))

export function TattooSection({ tats, rows, disabled, onTouch }: {
  tats: Locker2TatsPayload
  /** Lua's rows, zone by zone. */
  rows: readonly Locker2TatRow[]
  disabled: boolean
  /** A zone was pressed: the camera follows it. */
  onTouch: (cat: string) => void
}) {
  return (
    <div id={anchorId(TATTOOS_CAT)} className="lk2-tats awsui-compact-mode">
      <SpaceBetween size="s">
        <Box variant="h4">{TATTOOS}</Box>
        {tats.zones.map((zone) => (
          <ZoneEditor key={zone.z} zone={zone} rows={zoneRows(rows, zone.z)} disabled={disabled} onTouch={onTouch} />
        ))}
      </SpaceBetween>
    </div>
  )
}
