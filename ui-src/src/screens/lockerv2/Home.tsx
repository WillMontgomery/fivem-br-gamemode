import { memo, useEffect } from 'react'
import ButtonDropdown from '@cloudscape-design/components/button-dropdown'
import Icon from '@cloudscape-design/components/icon'
import Spinner from '@cloudscape-design/components/spinner'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2Ped } from '../../bridge/types'
import { play } from '../../audio/cues'
import { useUi } from '../../store'
import { BTN } from './copy'
import { needShots, shotKey } from './model'
import { askedKeys, cachedKeys, markAsked, shotFor, useShotCache } from './shots'

/**
 * MY LOOKS (owner, 2026-10-13): the saved looks as cards with their
 * headshots, the worn one marked; a press wears it ("a pick applies at once
 * with no Save", the owner's confirmed assumption, #28); Edit, Rename and
 * Delete in a small "..." menu on each card; New at the top (LockerV2.tsx).
 *
 * A card with no picture asks Lua for one, once per `id@up` (shots.ts). Lua
 * answers a stored one as a `locker2shot` -- the wiring round sends each
 * card's on its own, when asked (LOCKER2_IMG in the lag report), rather than
 * every picture with the server's state.
 */

export type CardAction = 'edit' | 'rename' | 'delete'

/** One saved look. Memoized on what it draws: a push that changed nothing
 *  about this card leaves it alone. */
const LookCard = memo(function LookCard({ ped, src, worn, loading, blocked, onWear, onAction }: {
  ped: Locker2Ped
  src: string | null
  worn: boolean
  loading: boolean
  blocked: boolean
  onWear: (p: Locker2Ped) => void
  onAction: (p: Locker2Ped, a: CardAction) => void
}) {
  return (
    <div className="lk2-card">
      {/* The card's face is the lobby's plate, and the worn one is lit as the
          lobby lights a selected plate: its corners open (`is-active`). */}
      <button type="button" className={`plate btn lk2-card-main${worn ? ' is-active' : ''}`} disabled={blocked}
        aria-pressed={worn}
        onClick={() => { if (!worn) onWear(ped) }}>
        <span className="lk2-card-shot">
          {src !== null && <img src={src} alt="" />}
        </span>
        <span className="lk2-card-name lk2-fit"><span>{ped.name}</span></span>
      </button>
      {worn && <span className="lk2-card-mark"><Icon name="check" /></span>}
      {loading && <span className="lk2-card-ring"><Spinner /></span>}
      <span className="lk2-card-menu">
        <ButtonDropdown
          variant="icon"
          ariaLabel={BTN.more}
          disabled={blocked}
          expandToViewport={false}
          items={[
            { id: 'edit', text: BTN.edit },
            { id: 'rename', text: BTN.rename },
            { id: 'delete', text: BTN.delete },
          ]}
          onItemClick={({ detail }) => onAction(ped, detail.id as CardAction)}
        />
      </span>
    </div>
  )
})

export function Home({ blocked, onAction }: {
  blocked: boolean
  onAction: (p: Locker2Ped, a: CardAction) => void
}) {
  const peds = useUi((s) => s.locker2.peds)
  const worn = useUi((s) => (s.locker2.worn?.k === 'p' ? s.locker2.worn.id : null))
  const loading = useUi((s) => s.locker2.loading ?? null)
  const fetching = useUi((s) => s.locker2.fetching === true)
  const shots = useShotCache()

  // The cards with no picture yet ask Lua for one, once per `id@up`.
  useEffect(() => {
    const ids = needShots(peds, cachedKeys(), askedKeys())
    if (ids.length === 0) return
    markAsked(peds.filter((p) => ids.includes(p.id)).map((p) => shotKey(p.id, p.up)))
    void fetchNui(CB.LOCKER2_SHOTS, { ids })
  }, [peds])

  if (fetching) return <div className="lk2-wait"><Spinner size="large" /></div>
  return (
    <div className="lk2-cards thin-scroll">
      {peds.map((p) => (
        <LookCard key={p.id} ped={p} src={shotFor(p, shots)} worn={p.id === worn} loading={p.id === loading}
          blocked={blocked} onWear={wear} onAction={onAction} />
      ))}
    </div>
  )
}

/** Wear a saved look; the last press wins in Lua. */
function wear(p: Locker2Ped) {
  play('ui.select')
  void fetchNui(CB.LOCKER2_WEAR, { k: 'p', id: p.id })
}
