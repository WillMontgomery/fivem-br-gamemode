import { memo, useCallback, useDeferredValue, useEffect, useRef, useState } from 'react'
import Button from '@cloudscape-design/components/button'
import Spinner from '@cloudscape-design/components/spinner'
import Toggle from '@cloudscape-design/components/toggle'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2CountRow, Locker2Edit, Locker2PalPayload, Locker2Row } from '../../bridge/types'
import { play } from '../../audio/cues'
import { useUi } from '../../store'
import { BTN, CAT_LABEL, GROUP_LABEL } from './copy'
import {
  FACE_GROUPS, TATTOOS_CAT, addableExtras, groupMoved, isExtra, listedCats, panelOf, panelRows, summaryOf,
} from './model'
import { askPal, usePal } from './palette'
import { askTats, useTats } from './tattooLists'
import { CountRow, IconBtn, SliderRow } from './Rows'
import { TattooSection } from './Tattoos'

/**
 * THE EDITOR (owner, 2026-10-13): "what if I get overwhelmed with the
 * extensive list of options? ... presented with a choice to add
 * customizations for each category".
 *
 *   THE STRIP   Randomize ("a randomize button for the whole ped ... Having
 *               random buttons for each item seems like a lot of extra buttons
 *               on the screen. Our screen real estate is precious!"), Undo and
 *               Redo. Each asks Lua, which holds the draft and its history.
 *   THE LIST    on the left, it SUMMARIZES the look, one line per category:
 *               the core always, then each extra on the look with a trash
 *               icon, in the order put on, and "Add more" at its foot for the
 *               extras that are not. A line's summary is the item's place in
 *               its list; one that does not fit beside its label is not drawn
 *               (owner, 2026-10-14: "text wrapping should not be allowed. if
 *               you can't fit the text, don't draw it").
 *   THE PANEL   on the right, ONLY the category pressed: its rows, and the
 *               camera goes there (LOCKER2_CAT, as before). Face is a few
 *               starting faces, the eyes, and "Fine-tune", which shows the
 *               grouped features.
 *
 * A NEW DRAFT OPENS ON NO CATEGORY, the camera home on the whole look and the
 * panel empty: the list is the overview. Lua's `cat` is followed once it
 * names one (a tattoo zone pressed is Tattoos'), and a line's press shows its
 * panel at once, the panel's contents drawn in a transition behind it.
 *
 * A PUSH DRAWS LITTLE. Every press brings a push, and a slider's drag one
 * every 60 ms; each line and each row is memoized on what it shows, and a push
 * hands back the same object for everything it did not change (model.ts
 * share), so a press redraws its own row and its own line.
 */

/** One summary line: its category, what the look wears there, and for an
 *  extra the trash icon that takes it off. */
const Line = memo(function Line({ cat, text, chip, on, extra, disabled, onOpen, onRemove }: {
  cat: string
  text: string
  /** The palette color worn, as `#rrggbb`, or null. */
  chip: string | null
  on: boolean
  extra: boolean
  disabled: boolean
  onOpen: (cat: string) => void
  onRemove: (cat: string) => void
}) {
  // A line lit from outside the list -- an extra just put on from "+ Add",
  // which stands below the scrolling lines -- is scrolled into view.
  const self = useRef<HTMLDivElement>(null)
  useEffect(() => { if (on) self.current?.scrollIntoView?.({ block: 'nearest' }) }, [on])
  return (
    <div ref={self} className={`plate lk2-line${on ? ' is-active' : ''}`}>
      <button type="button" className="btn lk2-line-main" aria-pressed={on} onClick={() => onOpen(cat)}>
        <span className="lk2-line-label lk2-fit"><span>{CAT_LABEL[cat] ?? ''}</span></span>
        <span className="lk2-line-sum lk2-fit">
          <span className="lk2-line-fits">
            {chip !== null && <span className="lk2-chip" style={{ background: chip }} />}
            <span className="lk2-line-text">{text}</span>
          </span>
        </span>
      </button>
      {extra && <span className="lk2-line-div" aria-hidden="true" />}
      {extra && <IconBtn icon="remove" label={BTN.remove} disabled={disabled} onPress={() => onRemove(cat)} />}
    </div>
  )
})

/** The Face panel's starting faces: one tile each, the worn one lit. */
const FaceTiles = memo(function FaceTiles({ row, disabled }: { row: Locker2CountRow; disabled: boolean }) {
  return (
    <div className="lk2-faces" role="group">
      {Array.from({ length: row.n }, (_, i) => i + 1).map((v) => (
        <button key={v} type="button" disabled={disabled}
          className={`plate btn lk2-face${v === row.v ? ' is-active' : ''}`} aria-pressed={v === row.v}
          onClick={() => {
            if (v === row.v) return
            play('ui.select')
            void fetchNui(CB.LOCKER2_SET, { k: row.k, v })
          }}>
          {v}
        </button>
      ))}
    </div>
  )
})

/** One face group under "Fine-tune": its sliders, and its one reset. */
const FaceGroup = memo(function FaceGroup({ id, rows, disabled, onTouch }: {
  id: string
  rows: readonly Locker2Row[]
  disabled: boolean
  onTouch: (cat: string) => void
}) {
  const ks = FACE_GROUPS.find((g) => g.id === id)?.ks ?? []
  const mine = rows.filter((r) => ks.includes(r.k))
  return (
    <div className="lk2-group">
      <div className="lk2-group-head">
        <span className="lk2-group-label lk2-fit"><span>{GROUP_LABEL[id] ?? ''}</span></span>
        <IconBtn icon="refresh" label={BTN.reset} disabled={disabled || !groupMoved(mine, ks)}
          onPress={() => {
            play('ui.select')
            void fetchNui(CB.LOCKER2_DEFAULTS, { ks })
          }} />
      </div>
      {mine.map((r) => (r.kind === 'slider'
        ? <SliderRow key={r.k} row={r} disabled={disabled} onTouch={onTouch} bare />
        : null))}
    </div>
  )
}, (a, b) => a.id === b.id && a.disabled === b.disabled && a.onTouch === b.onTouch
  && a.rows.length === b.rows.length && a.rows.every((r, i) => r === b.rows[i]))

/** The rows of one category. */
function Panel({ cat, edit, pal, tune, setTune, disabled, onTouch }: {
  cat: string
  edit: Locker2Edit
  pal: Locker2PalPayload | null
  tune: boolean
  setTune: (on: boolean) => void
  disabled: boolean
  onTouch: (cat: string) => void
}) {
  const tats = useTats(cat === TATTOOS_CAT ? edit.sex : null)
  useEffect(() => { if (cat === TATTOOS_CAT) askTats(edit.sex) }, [cat, edit.sex])

  if (cat === TATTOOS_CAT) {
    return tats ? <TattooSection tats={tats} rows={edit.tats} disabled={disabled} onTouch={onTouch} /> : null
  }
  const rows = panelRows(edit.rows, cat).map((r) => (r.kind === 'slider'
    ? <SliderRow key={r.k} row={r} disabled={disabled} onTouch={onTouch} />
    : <CountRow key={r.k} row={r} pal={pal} disabled={disabled} onTouch={onTouch} />))
  if (cat !== 'face') return <div className="lk2-rows">{rows}</div>

  const shape = edit.rows.find((r): r is Locker2CountRow => r.k === 'shape' && r.kind === 'count')
  const features = edit.rows.filter((r) => /^ff\d+$/.test(r.k))
  return (
    <div className="lk2-rows">
      {shape && <FaceTiles row={shape} disabled={disabled} />}
      {rows}
      {features.length > 0 && (
        <div className="lk2-row">
          <Toggle checked={tune} onChange={({ detail }) => { play('ui.select'); setTune(detail.checked) }}>
            {BTN.fineTune}
          </Toggle>
        </div>
      )}
      {tune && FACE_GROUPS.map((g) => (
        <FaceGroup key={g.id} id={g.id} rows={features} disabled={disabled} onTouch={onTouch} />
      ))}
    </div>
  )
}

/**
 * "ADD MORE" (owner, 2026-10-14: "the plus button is too small. also change
 * the add button to say "add more"", and "why is the "add" dropdown wider
 * than it's parent button?"). The lobby's button with Cloudscape's own plus
 * at the size of its text, and the editor's own menu of the extras not on the
 * look -- not Cloudscape's ButtonDropdown, whose menu sizes itself to its
 * items and a minimum of its own. The menu opens IN THE LIST'S COLUMN, under
 * the button and exactly its width: the lines above give it the room (they
 * scroll), so it is never cut off and never measured. A pick, a press outside
 * it or Escape closes it -- Escape is its own while the button says it is
 * expanded (model.ts OPEN_POPUP; the screen leaves the key alone).
 */
export function AddMore({ items, disabled, onPick }: {
  items: readonly string[]
  disabled: boolean
  onPick: (cat: string) => void
}) {
  const [wanted, setOpen] = useState(false)
  const box = useRef<HTMLDivElement>(null)
  // With nothing left to add, or the page blocked, it is off and never open.
  const off = disabled || items.length === 0
  const open = wanted && !off
  useEffect(() => { if (off) setOpen(false) }, [off])
  useEffect(() => {
    if (!open) return
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') setOpen(false) }
    const onDown = (e: PointerEvent) => {
      if (!(e.target instanceof Node) || !box.current?.contains(e.target)) setOpen(false)
    }
    window.addEventListener('keydown', onKey)
    window.addEventListener('pointerdown', onDown, true)
    return () => {
      window.removeEventListener('keydown', onKey)
      window.removeEventListener('pointerdown', onDown, true)
    }
  }, [open])
  return (
    <div ref={box} className={`lk2-addmore${open ? ' is-open' : ''}`}>
      <Button iconName="add-plus" fullWidth wrapText={false} disabled={off} ariaHaspopup="menu" ariaExpanded={open}
        onClick={() => { if (off) return; play('ui.select'); setOpen((o) => !o) }}>
        {BTN.addMore}
      </Button>
      {open && (
        <div className="lk2-menu thin-scroll" role="menu">
          {items.map((c) => (
            <button key={c} type="button" role="menuitem" className="btn lk2-menu-item"
              onClick={() => { setOpen(false); onPick(c) }}>
              <span className="lk2-fit"><span>{CAT_LABEL[c] ?? ''}</span></span>
            </button>
          ))}
        </div>
      )}
    </div>
  )
}

/** Fine-tune stays as the player left it, for the session. */
let tuneOpen = false

export function Editor({ blocked }: { blocked: boolean }) {
  const edit = useUi((s) => s.locker2.edit ?? null)
  const pal = usePal()
  useEffect(() => { askPal() }, [])

  // The panel shown: the line last pressed, else where Lua's camera is.
  const luaPanel = panelOf(edit?.cat ?? null)
  const [chosen, setChosen] = useState<string | null>(luaPanel)
  useEffect(() => { if (luaPanel !== null) setChosen(luaPanel) }, [luaPanel])
  const listed = edit ? listedCats(edit.extras) : []
  const open = chosen !== null && listed.includes(chosen) ? chosen : null
  // The line lights on the press; the panel's rows follow a frame behind.
  const panel = useDeferredValue(open)

  const [tune, setTuneState] = useState(tuneOpen)
  const setTune = useCallback((on: boolean) => { tuneOpen = on; setTuneState(on) }, [])

  /** Every category touch is sent; Lua decides whether the camera moves. */
  const toCat = useCallback((cat: string) => { void fetchNui(CB.LOCKER2_CAT, { cat }) }, [])
  const onOpen = useCallback((cat: string) => {
    play('ui.select')
    setChosen(cat)
    void fetchNui(CB.LOCKER2_CAT, { cat })
  }, [])
  const onRemove = useCallback((cat: string) => {
    play('ui.select')
    void fetchNui(CB.LOCKER2_EXTRA, { id: cat, on: false })
  }, [])
  const onAdd = useCallback((cat: string) => {
    play('ui.select')
    void fetchNui(CB.LOCKER2_EXTRA, { id: cat, on: true })
    setChosen(cat)
    void fetchNui(CB.LOCKER2_CAT, { cat })
  }, [])

  if (!edit) return <div className="lk2-wait"><Spinner size="large" /></div>

  const addable = addableExtras(edit.extras)
  return (
    <div className="lk2-editor">
      <div className="lk2-strip">
        <Button disabled={blocked} onClick={() => { play('ui.select'); void fetchNui(CB.LOCKER2_RANDOM) }}>
          {BTN.randomize}
        </Button>
        <Button iconName="undo" disabled={blocked || !edit.undo}
          onClick={() => { play('ui.select'); void fetchNui(CB.LOCKER2_UNDO) }}>
          {BTN.undo}
        </Button>
        <Button iconName="redo" disabled={blocked || !edit.redo}
          onClick={() => { play('ui.select'); void fetchNui(CB.LOCKER2_REDO) }}>
          {BTN.redo}
        </Button>
      </div>
      <div className="lk2-cols">
        <div className="lk2-list">
          {/* THE LINES SCROLL; "Add more" DOES NOT. Inside the scroll box
              its menu was cut off at the list's edge (#28 review); below the
              box it opens over the list, and stays at the list's foot however
              many extras there are. */}
          <div className="lk2-lines thin-scroll">
            {listed.map((cat) => {
              const s = summaryOf(cat, edit.rows, edit.tats.length)
              const chip = s.chip !== null ? pal?.[s.chip.pal][s.chip.i] ?? null : null
              return (
                <Line key={cat} cat={cat} text={s.text} chip={chip} on={cat === open} extra={isExtra(cat)}
                  disabled={blocked} onOpen={onOpen} onRemove={onRemove} />
              )
            })}
          </div>
          <div className="lk2-add">
            <AddMore items={addable} disabled={blocked} onPick={onAdd} />
          </div>
        </div>
        <div className="lk2-panel thin-scroll">
          {panel !== null && (
            <Panel cat={panel} edit={edit} pal={pal} tune={tune} setTune={setTune}
              disabled={blocked} onTouch={toCat} />
          )}
        </div>
      </div>
    </div>
  )
}
