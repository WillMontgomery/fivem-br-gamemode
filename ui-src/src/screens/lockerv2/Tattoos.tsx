import { memo, useMemo, useState } from 'react'
import Button from '@cloudscape-design/components/button'
import Select from '@cloudscape-design/components/select'
import type { SelectProps } from '@cloudscape-design/components/select'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2TatRow, Locker2TatsPayload } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, ZONE_LABEL, tattooLabels } from './copy'
import {
  addZones, canAddMore, newRowChoices, sameTatRows, tatGroups, tattooCat, tattooChoices, tattooFilter,
} from './model'
import { IconBtn } from './Rows'

/**
 * THE TATTOOS EXTRA (owner, 2026-10-12): "a list, starting empty, with add
 * and remove buttons ... You can just make it max 10 per category." Then
 * (2026-10-14): "on the tattoos screen - starting with a bunch of add buttons
 * is not intuitive, especially having to use a dropdown to navigate between
 * them. fix that".
 *
 * ONE LIST, ONE "ADD MORE". The tattoos on the look stand grouped under their
 * body zone's name, in the zones' order -- a zone with none draws nothing --
 * each row its tattoo's picker and a trash icon. "Add more" puts a new row at
 * the foot that asks first which zone (a zone already at 10 is offered off),
 * then -- its picker appearing once the zone is chosen -- which tattoo of it;
 * only then is anything sent (LOCKER2_TAT_ADD
 * { z, i }), and the row takes its place under its zone. Its trash icon
 * drops it unsent. Tattoos opens on that new row while the look has none.
 *
 * As with every row, the page never decides: an add, a choice and a removal
 * each ask Lua (LOCKER2_TAT_ADD, _SET, _DEL), which holds every rule -- 10 a
 * zone, no tattoo twice in a zone, only the zone's and the sex's -- puts the
 * tattoo on the ped at once and sends the rows back. A press in a zone, and a
 * zone picked for a new row, also send its category, so the camera goes to
 * that part of the ped.
 *
 * Each picker is a Cloudscape Select of the game's names, filtered by the
 * name alone as typed (model.ts tattooFilter), its list scrolling virtually;
 * it opens inside the island, and while it is open Escape is its own
 * (LockerV2.tsx). The section wears Cloudscape's compact density
 * (`awsui-compact-mode`, scoped to it). A push redraws a zone only when its
 * rows changed.
 */

/** A tattoo's option: its id in the list and what a Select draws. */
type TatOpt = { i: number, option: Required<Pick<SelectProps.Option, 'value' | 'label'>> }

/** A picker of tattoos: the options given, narrowed as typed by the name
 *  alone. The typed text is this Select's own: Cloudscape sends '' through
 *  onLoadItems as it opens again. */
function TattooPick({ value, options, disabled, onPick }: {
  value: SelectProps.Option | null
  options: readonly TatOpt['option'][]
  disabled: boolean
  onPick: (i: number) => void
}) {
  const [typed, setTyped] = useState('')
  return (
    <Select
      selectedOption={value}
      options={tattooFilter(options, typed)}
      filteringType="manual"
      onLoadItems={({ detail }) => setTyped(detail.filteringText)}
      expandToViewport={false}
      virtualScroll
      disabled={disabled}
      onChange={({ detail }) => {
        const i = Number(detail.selectedOption.value)
        if (Number.isInteger(i)) onPick(i)
      }}
    />
  )
}

/** One zone's tattoos under its name. Drawn again only when its rows, its
 *  list or `disabled` change -- `onTouch` is the editor's stable camera call. */
const ZoneGroup = memo(function ZoneGroup({ z, rows, opts, disabled, onTouch }: {
  z: string
  /** This zone's rows, in Lua's order. */
  rows: readonly Locker2TatRow[]
  opts: readonly TatOpt[]
  disabled: boolean
  onTouch: (cat: string) => void
}) {
  const byI = useMemo(() => new Map(opts.map((o) => [o.i, o.option])), [opts])
  return (
    <div className="lk2-tatzone" onPointerDown={() => onTouch(tattooCat(z))}>
      <div className="lk2-row-label lk2-fit"><span>{ZONE_LABEL[z] ?? ''}</span></div>
      {rows.map((row) => (
        <div key={row.r} className="lk2-tatrow">
          <TattooPick value={byI.get(row.i) ?? null} options={tattooChoices(opts, rows, row).map((o) => o.option)}
            disabled={disabled}
            onPick={(i) => {
              if (i === row.i) return
              play('ui.select')
              void fetchNui(CB.LOCKER2_TAT_SET, { r: row.r, i })
            }} />
          <IconBtn icon="remove" label={BTN.remove} disabled={disabled}
            onPress={() => {
              play('ui.select')
              void fetchNui(CB.LOCKER2_TAT_DEL, { r: row.r })
            }} />
        </div>
      ))}
    </div>
  )
}, (a, b) => a.z === b.z && a.opts === b.opts && a.disabled === b.disabled && a.onTouch === b.onTouch
  && sameTatRows(a.rows, b.rows))

/** The row "Add more" put at the foot: its zone, then its tattoo. */
function NewRow({ tats, rows, opts, z, disabled, onZone, onDone }: {
  tats: Locker2TatsPayload
  rows: readonly Locker2TatRow[]
  opts: ReadonlyMap<string, readonly TatOpt[]>
  z: string | null
  disabled: boolean
  onZone: (z: string) => void
  onDone: () => void
}) {
  const zones = addZones(tats.zones, rows).map((x) => ({ value: x.z, label: ZONE_LABEL[x.z] ?? '', disabled: !x.open }))
  return (
    <div className="lk2-tatrow lk2-tatnew">
      <div className="lk2-tatzonepick">
        <Select
          selectedOption={zones.find((o) => o.value === z) ?? null}
          options={zones}
          expandToViewport={false}
          disabled={disabled}
          onChange={({ detail }) => {
            const v = detail.selectedOption.value
            if (typeof v !== 'string' || v === z) return
            play('ui.select')
            onZone(v)
          }}
        />
      </div>
      {z !== null && (
        <TattooPick key={z} value={null} options={newRowChoices(opts.get(z) ?? [], rows, z).map((o) => o.option)}
          disabled={disabled}
          onPick={(i) => {
            play('ui.select')
            void fetchNui(CB.LOCKER2_TAT_ADD, { z, i })
            onDone()
          }} />
      )}
      <IconBtn icon="remove" label={BTN.remove} disabled={false} onPress={() => { play('ui.select'); onDone() }} />
    </div>
  )
}

export function TattooSection({ tats, rows, disabled, onTouch }: {
  tats: Locker2TatsPayload
  /** Lua's rows, zone by zone. */
  rows: readonly Locker2TatRow[]
  disabled: boolean
  /** A zone was pressed or picked: the camera follows it. */
  onTouch: (cat: string) => void
}) {
  // The row being added, by the zone picked for it (null: none yet). A look
  // with no tattoo opens on one.
  const [adding, setAdding] = useState<{ z: string | null } | null>(() => (rows.length === 0 ? { z: null } : null))
  // Each zone's options, once per list: the game's names, a nameless tattoo
  // numbered among the nameless of its zone -- never its key.
  const opts = useMemo(() => new Map(tats.zones.map((zone) => [zone.z, tattooLabels(zone.items).map(([t, label]) => ({
    i: t.i, option: { value: String(t.i), label },
  }))])), [tats])
  const groups = tatGroups(tats.zones.map((zone) => zone.z), rows)
  return (
    <div className="lk2-tats awsui-compact-mode">
      {groups.map((g) => (
        <ZoneGroup key={g.z} z={g.z} rows={g.rows} opts={opts.get(g.z) ?? []} disabled={disabled} onTouch={onTouch} />
      ))}
      {adding !== null && (
        <NewRow tats={tats} rows={rows} opts={opts} z={adding.z} disabled={disabled}
          onZone={(z) => { setAdding({ z }); onTouch(tattooCat(z)) }}
          onDone={() => setAdding(null)} />
      )}
      <div className="lk2-tatadd">
        <Button iconName="add-plus" wrapText={false} disabled={disabled || adding !== null || !canAddMore(tats.zones, rows)}
          onClick={() => { play('ui.select'); setAdding({ z: null }) }}>
          {BTN.addMore}
        </Button>
      </div>
    </div>
  )
}
