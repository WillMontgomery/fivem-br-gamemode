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
 * in. So it is a card down one side, the game stays visible behind it, and the
 * root is pointer-events:none -- a click outside the card reaches the game
 * rather than being swallowed by an invisible full-screen div.
 *
 * THE LEFT SIDE, on the owner's call after playing with it on the right
 * (2026-08-16). Nothing about the shape changed; it is the side that changed.
 * `.page-in` already enters from translate3d(-1.4rem, ...), so on this side the
 * existing animation reads as the card sliding in from the edge it lives on --
 * which is why there is no new keyframe here.
 *
 * IT SITS OVER THE CHAT, and that falls out of the z ladder rather than from a
 * number chosen here: this renders inside a `.page` (z-index 50, "above the HUD
 * (40) and below the black curtain (60)" -- index.css), and the chat column is
 * HUD chrome with no z-index at all. On the right the two never met. On the
 * left they overlap in the lower corner, so the ladder is now load-bearing and
 * is written down instead of assumed.
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
 * THE PANEL OWNS THE CURSOR, AND YOU STAND STILL WHILE IT DOES (#135).
 *
 * For one day it did not. View mode was granted focus WITH keep-input so the
 * roster could be read on the move, and the owner described the result exactly
 * (2026-08-16): "the pointer is available for use while the menu is open, but
 * doesn't prevent game control. So moving the mouse still moves the camera, and
 * I'm able to walk as well while it's open. That should be changed."
 *
 * That is the whole mechanism. The clicks were arriving all along -- keep-input
 * does not take them away -- but the mouse was also the camera and the mouse
 * buttons were also the trigger, so reaching for a checkbox turned the view away
 * from it and pressing one fired the gun. A cursor you cannot aim is not a
 * cursor, which is why the first report of this reads as "doesn't capture mouse
 * input".
 *
 * The inventory keeps game input and is clickable anyway, but only because
 * br_core/client/inventory.lua disables LOOK_LR, LOOK_UD, ATTACK and AIM every
 * frame while its panel is up. That suppressor is what an entry in
 * BR.FocusKeepsInput actually costs, and this panel never had one. It could have
 * been given one -- and if standing still turns out to be the worse half of the
 * trade, that is the change to make -- but it asks for far more pointing than
 * five slot cards do, and it is a latching panel opened deliberately rather than
 * glanced at mid-burst. So it takes plain focus and accepts the cost.
 *
 * WHICH IS WHY THIS FILE NO LONGER TELLS LUA ITS MODE. It had to for a day:
 * report mode pushed a second focus screen, `playersReport`, purely to give up
 * game input for the note field. Both modes now hold the same focus, so
 * `reporting` below is local state and nothing more, and the second screen has
 * been deleted rather than left inert.
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

  /**
   * The only thing this panel asks Lua for. STATE, NOT A TOGGLE -- `open:
   * false` rather than "flip it" -- so a message lost on a busy frame costs one
   * stale frame instead of leaving the panel and the cursor permanently
   * disagreeing about which of them exists.
   */
  const close = () => { void fetchNui(CB.PLAYERS_FOCUS, { open: false }) }

  // SWITCHING MODES IS A LOCAL EVENT NOW. It used to be a focus change as well,
  // because report mode needed a screen that gave game input back up; both
  // modes hold the same focus since #135, so there is nothing to tell Lua.
  const enterReport = () => {
    setReporting(true)
  }

  const leaveReport = () => {
    setReporting(false)
    setPicked({})
    setNote('')
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
      {/* THE SAME BOX THE HUD LAYS OUT IN, so the panel follows the player's
          safe-zone slider and the ultrawide clamp instead of pinning itself to
          the physical edge of the glass. On a 32:9 panel an element anchored to
          the raw viewport sits a head-turn away from everything else on screen
          (#20), and this card is meant to be read at a glance during a fight.
          That is also why the side swap below is one property and not a
          rewrite: both edges of this box are already the right edges. */}
      <div className="hud-safe">
        {/* THE ANCHOR IS THIS DIV AND NOT THE PLATE, and that is the whole fix
            rather than a tidy-up (owner, 2026-08-16: "you got your X coords
            mixed up").

            `.plate` declares `position: relative` -- it has to, because its
            two redrawn chamfers are absolutely positioned children of it. But
            index.css opens with `@tailwind utilities`, so every utility class
            is emitted ABOVE `.plate` in the sheet. `.absolute` and `.plate`
            are both one class of specificity, so the later rule wins and the
            card was `position: relative` with `right`/`top` doing nothing but
            nudging it out of normal flow -- 22px LEFT of the document origin,
            hanging off the left edge of the screen with most of the panel cut
            off. It rendered on the wrong side of the screen entirely.

            Anchoring on a plain div sidesteps the collision instead of
            fighting it, and it takes the translate off the plate as well --
            `.plate` transitions `transform`, and a positioning transform on a
            surface that animates transform is a trap waiting for whoever adds
            the next state to this card.

            AND THE SIDE IS THIS ONE LINE, which is the point of having fixed
            the anchor properly first. `left` instead of `right`, against the
            same safe-zone inset, on the same box -- no negative margins, no
            second transform, and nothing that has to know how wide the card
            is in either mode. */}
        <div
          className="absolute top-1/2 -translate-y-1/2"
          style={{ left: 'var(--safe-x)' }}
        >
          <div
            className="interactive plate flex max-h-[74vh] flex-col"
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
      </div>
    </div>
  )
}
