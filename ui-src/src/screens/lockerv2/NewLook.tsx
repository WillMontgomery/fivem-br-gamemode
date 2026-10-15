import { memo } from 'react'
import Icon from '@cloudscape-design/components/icon'
import Select from '@cloudscape-design/components/select'
import Spinner from '@cloudscape-design/components/spinner'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import { play } from '../../audio/cues'
import { useUi } from '../../store'
import { CARD, SEX_LABEL } from './copy'
import type { NewPick } from './model'

/**
 * NEW (owner, 2026-10-12): "Let's make the creation flow have 2 options,
 * custom and "Stock GTA Peds" (custom is the default) and the custom card
 * itself has a dropdown within to select male or female." Then: "actually
 * lets call the card "Stock GTA Looks" to match our copy."
 *
 * Then (2026-10-14): "when I click "custom" or "stock gta looks" it should
 * have a create button, or not have either card selected by default ... weird
 * flow. we need to fix that", and "what happened to the alignment of text in
 * these boxes for the creation flow? also the gender dropdown is suuuuper
 * wide?". So a press on a card only SELECTS it (lit as the lobby lights a
 * selected plate); Custom is selected as the view opens; Create, at the foot
 * (LockerV2.tsx), goes on with the one selected (model.ts createStep). Both
 * titles stand at the same place, top left, and Custom's Male / Female
 * dropdown under its title is only as wide as its words.
 */

const SEX_OPTIONS = [
  { value: 'm', label: SEX_LABEL.m },
  { value: 'f', label: SEX_LABEL.f },
]

export function NewChoice({ blocked, pick, sex, onPick, onSex }: {
  blocked: boolean
  pick: NewPick
  sex: 'm' | 'f'
  onPick: (p: NewPick) => void
  onSex: (s: 'm' | 'f') => void
}) {
  const card = (p: NewPick, title: string) => (
    <>
      {/* The card's plate stands behind it rather than around it: a plate
          clips what it holds, and the dropdown opens past the card. */}
      <span className={`plate lk2-choice-plate${pick === p ? ' is-active' : ''}`} aria-hidden="true" />
      <button type="button" role="radio" aria-checked={pick === p} className="btn lk2-choice-main"
        disabled={blocked} autoFocus={p === pick}
        onClick={() => { if (pick !== p) { play('ui.select'); onPick(p) } }}>
        <span className="lk2-choice-title lk2-fit"><span>{title}</span></span>
      </button>
    </>
  )
  return (
    <div className="lk2-choices" role="radiogroup">
      <div className="lk2-choice">
        {card('custom', CARD.custom)}
        {/* The dropdown is Custom's: opening it selects Custom, and so does a
            pick in it, however it was opened (the keyboard presses nothing). */}
        <div className="lk2-choice-sub" onPointerDown={() => { if (pick !== 'custom') onPick('custom') }}>
          <Select
            selectedOption={SEX_OPTIONS.find((o) => o.value === sex) ?? null}
            options={SEX_OPTIONS}
            expandToViewport={false}
            disabled={blocked}
            onChange={({ detail }) => {
              play('ui.select')
              onSex(detail.selectedOption.value === 'f' ? 'f' : 'm')
              if (pick !== 'custom') onPick('custom')
            }}
          />
        </div>
      </div>
      <div className="lk2-choice">
        {card('stock', CARD.stock)}
      </div>
    </div>
  )
}

/** One stock look: its name, the worn one marked, the one streaming in with
 *  the loading marker. */
const StockTile = memo(function StockTile({ id, name, worn, loading, locked }: {
  id: string
  name: string
  worn: boolean
  loading: boolean
  locked: boolean
}) {
  return (
    <button type="button" className={`plate btn lk2-tile${worn ? ' is-active' : ''}`} disabled={locked}
      aria-pressed={worn}
      onClick={() => {
        if (worn) return
        play('ui.select')
        void fetchNui(CB.LOCKER2_WEAR, { k: 's', id })
      }}>
      <span className="lk2-tile-name lk2-fit"><span>{name}</span></span>
      {loading ? <Spinner /> : worn ? <Icon name="check" /> : null}
    </button>
  )
})

/**
 * STOCK GTA LOOKS: "The stock peds options should continue to serve all of
 * our existing options today" (owner, #28). Season 1's roster; a press wears
 * one at once, as it always has. Drawn only once this view is chosen (the lag
 * report: the stock looks mount only then).
 */
export function StockList() {
  const stock = useUi((s) => s.locker2.stock)
  const worn = useUi((s) => (s.locker2.worn?.k === 's' ? s.locker2.worn.id : null))
  const loading = useUi((s) => s.locker2.loading ?? null)
  const locked = useUi((s) => s.locker2.locked === true)
  return (
    <div className="lk2-tiles thin-scroll">
      {stock.map((p) => (
        <StockTile key={p.id} id={p.id} name={p.name} worn={p.id === worn} loading={p.id === loading}
          locked={locked} />
      ))}
    </div>
  )
}
