import { useEffect, useMemo, useState } from 'react'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'

/**
 * Who is in this match, and the way to report them.
 *
 * TWO MODES ON ONE SCREEN. By default it is a list: who is here, who is still
 * alive, who has gone. Pressing "Report a player" turns the same rows into a
 * form -- checkboxes appear, a category dropdown appears beside each row you
 * tick, and a Submit appears once at least one is ticked.
 *
 * That is one screen rather than two because the list IS the form's subject.
 * A separate report dialog would mean picking a name twice: once to find them,
 * once to accuse them.
 *
 * NOTHING HERE IS AUTHORITATIVE. The bucket was resolved server-side, the
 * categories and the remaining allowance arrived with the list, and every rule
 * this screen appears to enforce is enforced again on submit. A modified client
 * can tick anything it likes and gets the same answer an honest one does.
 *
 * WHAT IS DELIBERATELY NOT SHOWN: positions, health, inventory, and the match
 * id. The roster projection already withholds them; this does not ask.
 */
export default function PlayerList() {
  const list = useUi((s) => s.players)
  const result = useUi((s) => s.reportResult)
  const setResult = useUi((s) => s.setReportResult)

  const [reporting, setReporting] = useState(false)
  const [picked, setPicked] = useState<Record<number, string>>({})
  const [note, setNote] = useState('')

  const close = () => { void fetchNui(CB.PLAYERS_FOCUS, { open: false }) }

  // Escape closes, the same key every other overlay answers to.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      play('ui.back')
      close()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  // A refused report leaves the form up so the selection is not lost -- the
  // reason is in a toast, and retyping five names because the server said no
  // is a punishment for the wrong party. A successful one is cleared, because
  // Lua closes the panel behind it.
  useEffect(() => {
    if (!result) return
    if (result.ok) {
      setPicked({})
      setNote('')
      setReporting(false)
    }
    setResult(null)
  }, [result, setResult])

  /**
   * REPORTABLE IS NOT THE SAME AS LISTED. You are in the list and cannot be
   * ticked; everyone else can, including players who have left.
   */
  const rows = list.players
  const selected = useMemo(() => Object.keys(picked).map(Number), [picked])
  const atCap = selected.length >= list.maxTargets
  const spent = list.remaining <= 0

  const toggle = (src: number) => {
    play('ui.select')
    setPicked((prev) => {
      if (prev[src]) {
        const next = { ...prev }
        delete next[src]
        return next
      }
      // The cap is enforced here so the checkbox simply does not take, rather
      // than accepting a sixth and refusing the whole submission later.
      if (Object.keys(prev).length >= list.maxTargets) return prev
      return { ...prev, [src]: list.defaultCategory }
    })
  }

  const submit = () => {
    if (selected.length === 0 || spent) { play('ui.error'); return }
    play('ui.select')
    void fetchNui(CB.REPORT_SUBMIT, {
      targets: selected.map((src) => ({ src, category: picked[src] })),
      note: note.trim() || undefined,
    })
  }

  return (
    <div
      className="interactive fixed inset-0 z-50 flex flex-col"
      style={{ backgroundColor: 'rgba(8, 9, 14, 0.985)' }}
    >
      <div
        className="mx-auto flex min-h-0 flex-1 flex-col pt-10"
        style={{ width: '46rem', maxWidth: '92vw' }}
      >
        <div className="flex items-end justify-between mb-6">
          <div>
            <div className="micro-label">This match</div>
            <h2 className="font-display text-[2.4rem] uppercase tracking-[0.1em] leading-none mt-1">
              Players
            </h2>
          </div>

          {!reporting ? (
            <Btn
              variant="ghost"
              size="sm"
              cue="ui.select"
              onPress={() => { if (!spent) setReporting(true) }}
            >
              {spent ? 'No reports left' : 'Report a player'}
            </Btn>
          ) : (
            <div className="micro-label">
              {selected.length}/{list.maxTargets} selected · {list.remaining} report
              {list.remaining === 1 ? '' : 's'} left
            </div>
          )}
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto thin-scroll pr-1">
          {rows.length === 0 ? (
            <p className="micro-label">Nobody else is here.</p>
          ) : (
            <div className="flex flex-col gap-1.5 pb-2">
              {rows.map((p) => {
                const on = picked[p.src] !== undefined
                // You cannot report yourself, so no checkbox is drawn. The
                // server refuses it too; this is only about not offering it.
                const selectable = reporting && !p.you

                return (
                  <div
                    key={p.src}
                    className="plate flex items-center gap-3 px-3 py-2"
                    style={{
                      ['--edgec' as string]: on
                        ? 'var(--color-royale-accent)'
                        : 'rgba(255,255,255,0.12)',
                      ['--plate-fill' as string]: 'rgba(24,28,40,0.92)',
                      ['--cut-max' as string]: '0.4rem',
                      opacity: p.left ? 0.55 : 1,
                    }}
                  >
                    {selectable && (
                      <input
                        type="checkbox"
                        checked={on}
                        disabled={!on && atCap}
                        onChange={() => toggle(p.src)}
                        className="size-4 shrink-0 accent-[var(--color-royale-accent)]"
                        aria-label={`Report ${p.name}`}
                      />
                    )}

                    <div className="min-w-0 flex-1">
                      <div className="text-[0.95rem] tscale leading-tight truncate">
                        {p.name}
                        {p.you && <span className="micro-label ml-2">you</span>}
                      </div>
                      <div className="micro-label mt-0.5">
                        {p.left
                          ? 'Left the match'
                          : p.state === 'dead'
                            ? 'Eliminated'
                            : p.state === 'dbno'
                              ? 'Downed'
                              : 'Alive'}
                        {p.squadId ? ' · in a squad' : ''}
                      </div>
                    </div>

                    {/* THE DROPDOWN ONLY APPEARS FOR A TICKED ROW. Showing one
                        per player would ask everybody to categorise everybody,
                        which is a form nobody finishes. */}
                    {selectable && on && (
                      <select
                        value={picked[p.src]}
                        onChange={(e) => {
                          play('ui.hover')
                          setPicked((prev) => ({ ...prev, [p.src]: e.target.value }))
                        }}
                        className="shrink-0 rounded-sm px-2 py-1 text-[0.8rem] tscale"
                        style={{
                          background: 'rgba(12,14,20,0.94)',
                          border: '1px solid rgba(255,255,255,0.18)',
                          color: '#fff',
                        }}
                      >
                        {list.categories.map((c) => (
                          <option key={c.id} value={c.id}>{c.label}</option>
                        ))}
                      </select>
                    )}
                  </div>
                )
              })}
            </div>
          )}
        </div>

        {/* SUBMIT LIVES BOTTOM-LEFT AND ONLY EXISTS WITH A SELECTION (owner).
            An always-present submit on a form with nothing in it is a button
            whose only function is to be refused. */}
        <div className="shrink-0 flex items-center gap-3 py-6">
          {reporting && selected.length > 0 && (
            <Btn variant="primary" size="lg" cue="ui.select" onPress={submit}>
              Submit {selected.length === 1 ? 'report' : `${selected.length} reports`}
            </Btn>
          )}

          {reporting ? (
            <Btn
              variant="ghost"
              size="lg"
              cue="ui.back"
              onPress={() => { setReporting(false); setPicked({}); setNote('') }}
            >
              Cancel
            </Btn>
          ) : (
            <Btn variant="primary" size="lg" cue="ui.back" onPress={close}>
              Close
            </Btn>
          )}

          {reporting && selected.length > 0 && (
            <input
              value={note}
              onChange={(e) => setNote(e.target.value)}
              placeholder="Anything else? (optional)"
              maxLength={300}
              className="flex-1 rounded-sm px-3 py-2 text-[0.85rem] tscale"
              style={{
                background: 'rgba(12,14,20,0.94)',
                border: '1px solid rgba(255,255,255,0.18)',
                color: '#fff',
              }}
            />
          )}
        </div>
      </div>
    </div>
  )
}
