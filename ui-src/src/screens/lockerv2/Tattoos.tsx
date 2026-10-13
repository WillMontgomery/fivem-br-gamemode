import { useState } from 'react'
import type { SyntheticEvent } from 'react'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Cards from '@cloudscape-design/components/cards'
import SpaceBetween from '@cloudscape-design/components/space-between'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2TatRow, Locker2TatsPayload } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, TATTOOS, ZONE_LABEL, tattooLabels } from './copy'
import { TATTOOS_CAT, anchorId, canAddTattoo, selectedRow, tattooCat, zoneRows } from './model'

/**
 * THE TATTOOS SECTION OF THE CUSTOM TABS (owner, 2026-10-12): "How about a
 * list, starting empty, with add and remove buttons. When I click add, create
 * a new row with a left/right arrow and the title of the tattoo in between.
 * Allow me to select each row and remove if I want to. You can just make it
 * max 10 per category."
 *
 * Per body zone: its rows, then Add and Remove under them, as My peds puts its
 * buttons under its cards. A row is a card -- the left arrow, the tattoo's
 * name, the right arrow -- and pressing it anywhere but an arrow selects it,
 * lit as My peds lights the worn ped's card: one row in the whole section at a
 * time. Remove takes the selected row out; Add stops at TATTOOS_PER_ZONE.
 *
 * As with every row, the page never decides: Add, an arrow and Remove each ask
 * Lua, which picks the tattoo (the zone's first one no row holds; the next
 * such each way, wrapping), puts it on the ped and sends the rows back. Any
 * press in a zone also sends its category, so the camera goes to that part of
 * the ped. Keyboard: Cloudscape's own -- Tab to a button and Enter or Space; a
 * card's radio takes Space, and the arrow keys move between a zone's cards.
 */

/** An arrow's press is the arrow's alone: never the card's select, which
 *  would also take the focus off the arrow. */
const own = (e: SyntheticEvent) => e.stopPropagation()

function RowHead({ row, label, disabled }: { row: Locker2TatRow; label: string; disabled: boolean }) {
  const step = (d: 1 | -1) => {
    play('ui.select')
    void fetchNui(CB.LOCKER2_TAT_STEP, { r: row.r, d })
  }
  return (
    <span style={{ display: 'flex', alignItems: 'center', gap: '0.5em' }}>
      <span onClick={own}>
        <Button variant="icon" iconName="angle-left" ariaLabel={BTN.last}
          disabled={disabled} onClick={() => step(-1)} />
      </span>
      <span style={{ flex: '1 1 auto', minWidth: 0, textAlign: 'center' }}>{label}</span>
      <span onClick={own}>
        <Button variant="icon" iconName="angle-right" ariaLabel={BTN.next}
          disabled={disabled} onClick={() => step(1)} />
      </span>
    </span>
  )
}

export function TattooSection({ tats, rows, disabled, onTouch }: {
  tats: Locker2TatsPayload
  /** Lua's rows, zone by zone. */
  rows: readonly Locker2TatRow[]
  disabled: boolean
  /** A zone was pressed: the camera follows it. */
  onTouch: (cat: string) => void
}) {
  // The selected row, by its id: one in the whole section at a time.
  const [sel, setSel] = useState<number | null>(null)
  return (
    <div id={anchorId(TATTOOS_CAT)}>
      <SpaceBetween size="s">
        <Box variant="h4">{TATTOOS}</Box>
        {tats.zones.map((zone) => {
          const cat = tattooCat(zone.z)
          const mine = zoneRows(rows, zone.z)
          const picked = selectedRow(mine, sel)
          // Each tattoo's name: the game's own, a nameless one numbered among
          // the nameless of its zone -- never its key.
          const names = new Map(tattooLabels(zone.items).map(([t, label]) => [t.i, label]))
          return (
            <div key={zone.z} id={anchorId(cat)} onPointerDown={() => onTouch(cat)}>
              <SpaceBetween size="xs">
                <Box variant="h5">{ZONE_LABEL[zone.z] ?? ''}</Box>
                {mine.length > 0 && (
                  <Cards
                    items={mine}
                    trackBy="r"
                    cardsPerRow={[{ cards: 1 }]}
                    selectionType="single"
                    entireCardClickable
                    selectedItems={picked ? [picked] : []}
                    isItemDisabled={() => disabled}
                    onSelectionChange={({ detail }) => {
                      const row = detail.selectedItems[0]
                      if (row) { play('ui.select'); setSel(row.r) }
                    }}
                    cardDefinition={{
                      header: (row) => <RowHead row={row} label={names.get(row.i) ?? ''} disabled={disabled} />,
                    }}
                  />
                )}
                <SpaceBetween direction="horizontal" size="xs">
                  <Button disabled={disabled || !canAddTattoo(mine.length, zone.items.length)}
                    onClick={() => {
                      play('ui.select')
                      void fetchNui(CB.LOCKER2_TAT_ADD, { z: zone.z })
                    }}>
                    {BTN.add}
                  </Button>
                  <Button disabled={disabled || picked === null}
                    onClick={() => {
                      if (!picked) return
                      play('ui.select')
                      setSel(null)
                      void fetchNui(CB.LOCKER2_TAT_DEL, { r: picked.r })
                    }}>
                    {BTN.remove}
                  </Button>
                </SpaceBetween>
              </SpaceBetween>
            </div>
          )
        })}
      </SpaceBetween>
    </div>
  )
}
