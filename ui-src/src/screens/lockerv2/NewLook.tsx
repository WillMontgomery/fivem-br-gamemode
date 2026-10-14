import { memo, useState } from 'react'
import Icon from '@cloudscape-design/components/icon'
import Select from '@cloudscape-design/components/select'
import Spinner from '@cloudscape-design/components/spinner'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import { play } from '../../audio/cues'
import { useUi } from '../../store'
import { CARD, SEX_LABEL } from './copy'

/**
 * NEW (owner, 2026-10-12): "Let's make the creation flow have 2 options,
 * custom and "Stock GTA Peds" (custom is the default) and the custom card
 * itself has a dropdown within to select male or female." Then: "actually
 * lets call the card "Stock GTA Looks" to match our copy."
 *
 * Two cards. Custom is the default: first, lit as the one to press, and the
 * keyboard's (it takes focus); its own dropdown picks the body, and a press
 * anywhere else on the card starts a new custom look of that body -- the core
 * randomized, no extras (LOCKER2_NEW, LockerV2.tsx). Stock GTA Looks opens the
 * stock roster.
 */

const SEX_OPTIONS = [
  { value: 'm', label: SEX_LABEL.m },
  { value: 'f', label: SEX_LABEL.f },
]

/** The body last picked, for the session. */
let lastSex: 'm' | 'f' = 'm'

export function NewChoice({ blocked, onCustom, onStock }: {
  blocked: boolean
  onCustom: (sex: 'm' | 'f') => void
  onStock: () => void
}) {
  const [sex, setSex] = useState<'m' | 'f'>(lastSex)
  return (
    <div className="lk2-choices">
      <div className="lk2-choice">
        {/* The card's plate stands behind it rather than around it: a plate
            clips what it holds, and the dropdown opens past the card. */}
        <span className="plate lk2-choice-plate is-active" aria-hidden="true" />
        <button type="button" className="btn lk2-choice-main" disabled={blocked} autoFocus
          onClick={() => { play('ui.select'); onCustom(sex) }}>
          <span className="lk2-choice-title">{CARD.custom}</span>
        </button>
        <div className="lk2-choice-sub">
          <Select
            selectedOption={SEX_OPTIONS.find((o) => o.value === sex) ?? null}
            options={SEX_OPTIONS}
            expandToViewport={false}
            disabled={blocked}
            onChange={({ detail }) => {
              const v = detail.selectedOption.value === 'f' ? 'f' : 'm'
              play('ui.select')
              lastSex = v
              setSex(v)
            }}
          />
        </div>
      </div>
      <div className="lk2-choice">
        <span className="plate lk2-choice-plate" aria-hidden="true" />
        <button type="button" className="btn lk2-choice-main" disabled={blocked}
          onClick={() => { play('ui.select'); onStock() }}>
          <span className="lk2-choice-title">{CARD.stock}</span>
        </button>
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
      <span className="lk2-tile-name">{name}</span>
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
