import { useEffect, useMemo, useState } from 'react'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'

/**
 * Who is in this match, and the way to report them.
 *
 * A PANEL, NOT A PAGE (owner, 2026-08-16). This was a full-screen sheet and it
 * was wrong for the same reason a full-screen map would be: the player is
 * standing in a battle royale while they read it. An opaque overlay means the
 * one thing they cannot do while checking who is left is see the fight they are
 * in. So it is a card on the right, the game stays visible behind it, and the
 * root is pointer-events:none -- a click outside the card reaches the game
 * rather than being swallowed by an invisible full-screen div.
 *
 * TWO MODES ON ONE CARD. By default it is a list: who is here, who is still
 * alive, who has gone. Pressing "Report" turns the same rows into a form --
 * checkboxes appear, a category dropdown appears beside each row you tick, and
 * a Submit appears once at least one is ticked.
 *
 * That is one surface rather than two because the list IS the form's subject.
 * A separate report dialog would mean picking a name twice: once to find them,
 * once to accuse them.
 *
 * THE TWO MODES HOLD DIFFERENT FOCUS, and that is the substantive half of the
 * change. Reading the list keeps game input -- you can still run while you
 * read. Reporting does not, because the note field is a text input and every
 * keystroke in it would otherwise also be a movement key. Lua owns both; this
 * only says which one it wants (see `wantFocus`).
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

  /**
   * Ask Lua for the focus this mode needs. Sent as the state we want rather
   * than as a toggle, so a dropped message cannot leave the two out of step.
   */
  const wantFocus = (report: boolean) => {
    void fetchNui(CB.PLAYERS_FOCUS, { open: true, report })
  }

  const enterReport = () => {
    setReporting(true)
    wantFocus(true)
  }

  const leaveReport = () => {
    setReporting(false)
    setPicked({})
    setNote('')
    wantFocus(false)
  }

  // Escape backs out one step -- report mode first, then the panel. Two steps
  // because losing a five-name selection to a mis-hit Escape is the kind of
  // small cruelty that stops people reporting at all.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      play('ui.back')
      if (reporting) leaveReport()
      else close()
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
  const alive = useMemo(
    () => rows.filter((p) => !p.left && p.state !== 'dead').length,
    [rows],
  )

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
    // NO BACKDROP AND NO POINTER EVENTS ON THE ROOT. The game is meant to show
    // through, and a full-screen interactive layer over a live match eats the
    // clicks that should have been shots.
    <div className="pointer-events-none fixed inset-0 z-50">
      <div
        className="interactive plate absolute right-8 top-1/2 flex max-h-[74vh] -translate-y-1/2 flex-col"
        style={{
          width: reporting ? '27rem' : '21rem',
          transition: 'width 140ms ease-out',
          ['--edgec' as string]: 'rgba(255,255,255,0.14)',
          ['--plate-fill' as string]: 'rgba(10,12,18,0.90)',
          backdropFilter: 'blur(6px)',
        }}
      >
        <div className="flex shrink-0 items-baseline justify-between px-4 pt-3.5 pb-3">
          <div>
            <div className="micro-label">This match</div>
            <h2 className="font-display text-[1.35rem] uppercase leading-none tracking-[0.09em]">
              {reporting ? 'Report' : 'Players'}
            </h2>
          </div>
          <div className="micro-label text-right">
            {reporting
              ? `${selected.length}/${list.maxTargets} picked`
              : `${alive} alive`}
          </div>
        </div>

        <div className="min-h-0 flex-1 overflow-y-auto thin-scroll px-2">
          {rows.length === 0 ? (
            <p className="micro-label px-2 pb-3">Nobody else is here.</p>
          ) : (
            <div className="flex flex-col gap-px pb-2">
              {rows.map((p) => {
                const on = picked[p.src] !== undefined
                // You cannot report yourself, so no checkbox is drawn. The
                // server refuses it too; this is only about not offering it.
                const selectable = reporting && !p.you
                const gone = p.left || p.state === 'dead'

                return (
                  <div key={p.src}>
                    <div
                      className="flex items-center gap-2.5 rounded-sm px-2 py-1.5"
                      style={{
                        background: on ? 'rgba(255,255,255,0.06)' : undefined,
                        opacity: gone ? 0.5 : 1,
                      }}
                    >
                      {selectable ? (
                        <input
                          type="checkbox"
                          checked={on}
                          disabled={!on && atCap}
                          onChange={() => toggle(p.src)}
                          className="size-3.5 shrink-0 accent-[var(--color-royale-accent)]"
                          aria-label={`Report ${p.name}`}
                        />
                      ) : (
                        // A STATE DOT INSTEAD OF A SENTENCE. At this width
                        // "Eliminated" beside every dead player is most of the
                        // panel; the colour carries it and the word only
                        // appears on the right when it is not "alive".
                        <span
                          className="size-1.5 shrink-0 rounded-full"
                          style={{
                            background:
                              p.state === 'dbno'
                                ? 'var(--color-royale-warn, #e0a33a)'
                                : gone
                                  ? 'rgba(255,255,255,0.3)'
                                  : 'var(--color-royale-accent)',
                          }}
                        />
                      )}

                      <span className="min-w-0 flex-1 truncate text-[0.9rem] tscale leading-tight">
                        {p.name}
                        {p.you && <span className="micro-label ml-1.5">you</span>}
                      </span>

                      <span className="micro-label shrink-0">
                        {p.left
                          ? 'left'
                          : p.state === 'dead'
                            ? 'out'
                            : p.state === 'dbno'
                              ? 'down'
                              : p.squadId
                                ? 'squad'
                                : ''}
                      </span>
                    </div>

                    {/* THE DROPDOWN ONLY APPEARS FOR A TICKED ROW, and it gets
                        its own line rather than sharing one -- at this width a
                        name and a category side by side truncates the name to
                        nothing, which is the one field that must stay legible
                        on a report. */}
                    {selectable && on && (
                      <select
                        value={picked[p.src]}
                        onChange={(e) => {
                          play('ui.hover')
                          setPicked((prev) => ({ ...prev, [p.src]: e.target.value }))
                        }}
                        className="mb-1 ml-8 w-[calc(100%-2.5rem)] rounded-sm px-2 py-1 text-[0.78rem] tscale"
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

        <div
          className="shrink-0 px-4 pt-3 pb-3.5"
          style={{ borderTop: '1px solid rgba(255,255,255,0.10)' }}
        >
          {reporting ? (
            <>
              {selected.length > 0 && (
                <input
                  value={note}
                  onChange={(e) => setNote(e.target.value)}
                  placeholder="Anything else? (optional)"
                  maxLength={300}
                  className="mb-2.5 w-full rounded-sm px-2.5 py-1.5 text-[0.82rem] tscale"
                  style={{
                    background: 'rgba(12,14,20,0.94)',
                    border: '1px solid rgba(255,255,255,0.18)',
                    color: '#fff',
                  }}
                />
              )}
              <div className="flex items-center gap-2">
                {/* SUBMIT ONLY EXISTS WITH A SELECTION. An always-present
                    submit on an empty form is a button whose only function is
                    to be refused. */}
                {selected.length > 0 && (
                  <Btn variant="primary" size="sm" cue="ui.select" onPress={submit}>
                    Send {selected.length === 1 ? 'report' : `${selected.length} reports`}
                  </Btn>
                )}
                <Btn variant="ghost" size="sm" cue="ui.back" onPress={leaveReport}>
                  Cancel
                </Btn>
                <span className="micro-label ml-auto">
                  {list.remaining} left
                </span>
              </div>
            </>
          ) : (
            <div className="flex items-center gap-2">
              <Btn
                variant="ghost"
                size="sm"
                cue="ui.select"
                onPress={() => { if (!spent) enterReport() }}
              >
                {spent ? 'No reports left' : 'Report'}
              </Btn>
              <Btn variant="ghost" size="sm" cue="ui.back" onPress={close}>
                Close
              </Btn>
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
