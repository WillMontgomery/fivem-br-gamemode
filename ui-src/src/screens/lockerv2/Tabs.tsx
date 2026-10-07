import { useEffect, useRef } from 'react'
import AnchorNavigation from '@cloudscape-design/components/anchor-navigation'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Cards from '@cloudscape-design/components/cards'
import SpaceBetween from '@cloudscape-design/components/space-between'
import Tiles from '@cloudscape-design/components/tiles'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2Edit, Locker2Payload, Locker2Ped } from '../../bridge/types'
import { play } from '../../audio/cues'
import Ring from '../../hud/Ring'
import { BTN, CAT_LABEL } from './copy'
import { activeAnchor, anchorId, categoriesOf, needShots, shotKey } from './model'
import { askedKeys, cachedKeys, markAsked, shotFor, useShotCache } from './shots'
import { CountRow, SliderRow } from './Rows'

/** Wear a stock or a saved ped. "a pick applies at once with no Save" (the
 *  owner's confirmed assumption, #28), and the last press wins in Lua. */
function wear(k: 's' | 'p', id: string) {
  play('ui.select')
  void fetchNui(CB.LOCKER2_WEAR, { k, id })
}

/**
 * STOCK PEDS: "The stock peds options should continue to serve all of our
 * existing options today" (owner, #28). Season 1's roster, with its loading
 * marker on the one streaming in and every tile off while the entrance walk
 * holds the ped -- the same two states screens/Locker.tsx draws.
 */
export function StockTab({ st, z }: { st: Locker2Payload; z: number }) {
  const value = st.worn?.k === 's' ? st.worn.id : null
  return (
    <div className="thin-scroll min-h-0 flex-1 overflow-y-auto" style={{ paddingRight: '0.5em' }}>
      <Tiles
        columns={2}
        value={value}
        onChange={({ detail }) => wear('s', detail.value)}
        items={st.stock.map((p) => ({
          value: p.id,
          disabled: st.locked === true,
          label: (
            <span style={{ display: 'inline-flex', alignItems: 'center', gap: '0.5em' }}>
              {p.name}
              {/* The interface's own loading ring, in rem -- so it steps out
                  of the island's zoom rather than being scaled twice. */}
              {st.loading === p.id && (
                <span style={{ display: 'inline-flex', zoom: 1 / z }}>
                  <Ring size={0.85} stroke={0.16} label="Loading" />
                </span>
              )}
            </span>
          ),
        }))}
      />
    </div>
  )
}

/** A saved ped's card: its picture when there is one, and its name. */
function Card({ ped, shots }: { ped: Locker2Ped; shots: ReadonlyMap<string, string> }) {
  const src = shotFor(ped, shots)
  return (
    <span style={{ display: 'flex', alignItems: 'center', gap: '0.75em' }}>
      {src !== null && (
        <img src={src} alt="" width={56} height={56}
          style={{ borderRadius: '0.25em', flex: '0 0 auto' }} />
      )}
      <span>{ped.name}</span>
    </span>
  )
}

/**
 * MY PEDS: "a vertical stack of cards to select from existing peds, with
 * buttons below for edit, rename, create, and delete functions" (owner, #28).
 * Pressing a card wears it; the worn ped is the selected card, and the one the
 * buttons act on.
 */
export function PedsTab({ st, blocked, onEdit, onCreate, onRename, onDelete }: {
  st: Locker2Payload
  blocked: boolean
  onEdit: (p: Locker2Ped) => void
  onCreate: () => void
  onRename: (p: Locker2Ped) => void
  onDelete: (p: Locker2Ped) => void
}) {
  const shots = useShotCache()
  const worn = st.worn
  const selected = worn?.k === 'p' ? st.peds.find((p) => p.id === worn.id) ?? null : null

  // The cards with no picture yet ask Lua for one, once per `id@up`.
  useEffect(() => {
    const ids = needShots(st.peds, cachedKeys(), askedKeys())
    if (ids.length === 0) return
    markAsked(st.peds.filter((p) => ids.includes(p.id)).map((p) => shotKey(p.id, p.up)))
    void fetchNui(CB.LOCKER2_SHOTS, { ids })
  }, [st.peds])

  const off = blocked || selected === null
  return (
    <div className="flex min-h-0 flex-1 flex-col" style={{ gap: '1em' }}>
      <div className="thin-scroll min-h-0 flex-1 overflow-y-auto" style={{ paddingRight: '0.5em' }}>
        <Cards
          items={st.peds}
          trackBy="id"
          cardsPerRow={[{ cards: 1 }]}
          selectionType="single"
          entireCardClickable
          selectedItems={selected ? [selected] : []}
          isItemDisabled={() => blocked}
          onSelectionChange={({ detail }) => {
            const p = detail.selectedItems[0]
            if (p && p.id !== selected?.id) wear('p', p.id)
          }}
          cardDefinition={{ header: (p) => <Card ped={p} shots={shots} /> }}
        />
      </div>
      <SpaceBetween direction="horizontal" size="xs">
        <Button disabled={off} onClick={() => { if (selected) { play('ui.select'); onEdit(selected) } }}>
          {BTN.edit}
        </Button>
        <Button disabled={off} onClick={() => { if (selected) { play('ui.select'); onRename(selected) } }}>
          {BTN.rename}
        </Button>
        <Button disabled={blocked} onClick={() => { play('ui.select'); onCreate() }}>
          {BTN.create}
        </Button>
        <Button disabled={off} onClick={() => { if (selected) { play('ui.select'); onDelete(selected) } }}>
          {BTN.delete}
        </Button>
      </SpaceBetween>
    </div>
  )
}

/**
 * CUSTOM (MALE / FEMALE): "an anchor navigation on the left for all categories
 * of items which can be customized, and when selected, the camera should move
 * to focus on which part of the ped is being customized" (owner, #28). The rows
 * stack on the right and scroll inside the lobby's frame.
 *
 * The camera follows the anchor pressed AND any row pressed (contract section
 * 5), so it is always on the part being changed. Every press is sent, the same
 * category or not: Lua knows where the camera is and moves it only if it is
 * not there, where a check here against the page's copy of `cat` once kept
 * Face from ever moving it (#28 review). A new draft lights no anchor, with
 * the camera home on the whole ped.
 */
export function CustomTab({ edit, disabled }: { edit: Locker2Edit | null | undefined; disabled: boolean }) {
  const scroller = useRef<HTMLDivElement>(null)
  if (!edit) return null

  const cats = categoriesOf(edit.rows)
  const toCat = (cat: string) => {
    void fetchNui(CB.LOCKER2_CAT, { cat })
  }
  const scrollTo = (cat: string) => {
    const box = scroller.current
    const el = document.getElementById(anchorId(cat))
    // offsetTop against the scroller itself (it is the offset parent), so the
    // read and the write are both in the island's zoomed px.
    if (box && el) box.scrollTo({ top: el.offsetTop, behavior: 'smooth' })
  }

  return (
    <div className="flex min-h-0 flex-1" style={{ gap: '1em' }}>
      <div className="thin-scroll min-h-0 overflow-y-auto" style={{ flex: '0 0 30%' }}>
        <AnchorNavigation
          anchors={cats.map((c) => ({ text: CAT_LABEL[c] ?? '', href: `#${anchorId(c)}`, level: 1 }))}
          activeHref={activeAnchor(edit.cat)}
          onFollow={(e) => {
            e.preventDefault()
            const cat = cats.find((c) => `#${anchorId(c)}` === e.detail.href)
            if (cat === undefined) return
            play('ui.select')
            toCat(cat)
            scrollTo(cat)
          }}
        />
      </div>
      <div ref={scroller} className="thin-scroll min-h-0 flex-1 overflow-y-auto"
        style={{ position: 'relative', paddingRight: '0.5em' }}>
        <SpaceBetween size="l">
          {cats.map((cat) => (
            <div key={cat} id={anchorId(cat)}>
              <SpaceBetween size="s">
                <Box variant="h4">{CAT_LABEL[cat] ?? ''}</Box>
                {edit.rows.filter((r) => r.cat === cat).map((r) => (r.kind === 'slider'
                  ? <SliderRow key={r.k} row={r} disabled={disabled} onTouch={() => toCat(r.cat)} />
                  : <CountRow key={r.k} row={r} disabled={disabled} onTouch={() => toCat(r.cat)} />))}
              </SpaceBetween>
            </div>
          ))}
        </SpaceBetween>
      </div>
    </div>
  )
}
