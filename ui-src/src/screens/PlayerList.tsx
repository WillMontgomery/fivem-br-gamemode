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
 * alive, who has gone. Pressing "Report player" turns the same rows into a form
 * -- each row becomes a tick target, a category picker appears under the ones
 * you tick, and a Send appears once at least one is ticked.
 *
 * That is one surface rather than two because the list IS the form's subject.
 * A separate report dialog would mean picking a name twice: once to find them,
 * once to accuse them.
 *
 * STRIPPED BACK IN #142, and every removal is the owner's, so they are recorded
 * here rather than argued for:
 *
 *   the ALIVE COUNT      "that's already in the top right corner of the
 *                        screen." It was, and a second copy of a number that
 *                        moves is a second number to disbelieve.
 *   the REPORT ALLOWANCE "We don't need to tell a player how many people they
 *                        can report, or how many reports are left." The limits
 *                        are untouched and still enforced server-side; they
 *                        stopped being advertised, which also took `remaining`
 *                        off the wire entirely -- see br_core/server/players.lua.
 *   the CLOSE BUTTON     "Having a 'close' button is not necessary." It was
 *                        only ever there because the key that opened this could
 *                        not close it; that is fixed below, so the workaround
 *                        goes with the problem.
 *   the NOTE FIELD       "We don't need a custom text field for reports. Just
 *                        the dropdown." It had never reached anywhere either:
 *                        br_ddb writes `note: null` unconditionally.
 *
 * NOTHING HERE IS AUTHORITATIVE. The bucket was resolved server-side, the
 * categories arrived with the list, and every rule this screen appears to
 * enforce is enforced again on submit. A modified client can tick anything it
 * likes and gets the same answer an honest one does.
 *
 * WHAT IS DELIBERATELY NOT SHOWN: positions, health, inventory, and the match
 * id. The roster projection already withholds them; this does not ask.
 */
export default function PlayerList() {
  const list = useUi((s) => s.players)
  const result = useUi((s) => s.reportResult)
  const setResult = useUi((s) => s.setReportResult)
  const keybinds = useUi((s) => s.keybinds)
  const rawKeys = useUi((s) => s.keybindsRaw)

  const [reporting, setReporting] = useState(false)
  const [picked, setPicked] = useState<Record<number, string>>({})

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
  }

  /**
   * WHICH KEYPRESS MEANS "SHUT THIS", BY VIRTUAL-KEY CODE.
   *
   * THE OPEN KEY HAS TO CLOSE IT AND ONLY THE PAGE CAN HEAR IT (#142, owner:
   * "Tilde must dismiss the panel while it is open. It currently does not").
   *
   * This was named as a risk when the panel stopped keeping game input in #135
   * and it turned out to be exactly right. Two Lua-side routes exist for a
   * keypress and NUI focus closes both:
   *
   *   * the engine's RegisterKeyMapping binding needs the GAME to receive the
   *     key, and with the cursor ours and keep-input off it receives nothing;
   *   * br_core's raw key layer reads the keyboard directly and is what
   *     normally survives that -- but its own frontend suppressor already
   *     records that "the raw layer cannot see Escape while CEF holds the
   *     cursor" (br_core/client/natives.lua), and this panel holds it.
   *
   * So the key that opened the panel is invisible to everything that could act
   * on it, which is why Escape and a Close button were the workarounds. The
   * page, though, has DOM focus by definition while the cursor is ours, so a
   * keydown listener here is the one thing certain to see the press. It then
   * asks Lua to close, exactly as #83 raises the pause menu from the lobby --
   * the callback it uses is the same one the (now deleted) Close button used,
   * so nothing on the Lua side had to learn a new message.
   *
   * BY CODE, NOT BY `e.key`, BECAUSE THE KEY IS REBINDABLE. br_core's binding
   * table is the authority and it travels on the keybinds envelope, which is
   * pushed on every `br:ui:ready` -- so `brplayers`.vk is present without the
   * player ever opening Settings. Comparing `e.keyCode` against it is the same
   * comparison Keybinds.tsx makes when CAPTURING a rebind, so a key bound
   * through that screen is a key recognised by this one, whatever it is.
   *
   * 0xC0 IS THE FALLBACK AND IS ONLY REACHED IN A GAP. It is the raw layer's
   * own default for this action (tilde), used for the frames between the page
   * mounting and the first keybinds envelope landing.
   *
   * F2 ONLY WHEN THE RAW LAYER IS OFF, because that is the only situation in
   * which F2 opens this panel: it is the ENGINE-side default, inert on every
   * client where the raw reader is running. Accepting it unconditionally would
   * mean F2 closing a panel it could not have opened.
   */
  const closeCodes = useMemo(() => {
    const codes = new Set<number>()
    const row = keybinds.find((k) => k.command === 'brplayers')
    codes.add(row?.vk ?? 0xc0)
    if (!rawKeys) codes.add(0x71)
    return codes
  }, [keybinds, rawKeys])

  // Escape backs out one step -- report mode first, then the panel. Two steps
  // because losing a five-name selection to a mis-hit Escape is the kind of
  // small cruelty that stops people reporting at all.
  //
  // THE OPEN KEY DOES NOT DO THAT, and the asymmetry is deliberate. Tilde is a
  // latch: it means "this panel, on or off", and a latch that only half
  // released on the second press would be the same complaint this issue is
  // about wearing a different shape. Escape is the careful way out; the key you
  // opened with is the blunt one.
  //
  // No dependency array on purpose -- the handler closes over `reporting`, and
  // a stale closure here would make Escape back out of a mode the player has
  // already left.
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        e.preventDefault()
        e.stopPropagation()
        play('ui.back')
        if (reporting) leaveReport()
        else close()
        return
      }
      if (!closeCodes.has(e.keyCode)) return
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
  // is a punishment for the wrong party. That matters more since #143: the
  // commonest refusal is now "you have already reported X in this match", and
  // the fix for it is to untick one row and send the rest.
  //
  // A successful one is cleared, because Lua closes the panel behind it.
  useEffect(() => {
    if (!result) return
    if (result.ok) {
      setPicked({})
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

  const toggle = (src: number) => {
    setPicked((prev) => {
      if (prev[src]) {
        play('ui.select')
        const next = { ...prev }
        delete next[src]
        return next
      }
      // THE CAP IS ENFORCED HERE AND NOW HAS TO BE AUDIBLE. It used to sit
      // beside an "n/5 picked" readout, so a sixth tick that did not take
      // explained itself; that readout went with the allowance text in #142, so
      // a silent refusal would now just look like a broken checkbox. The server
      // refuses the same submission for the same reason and costs the player
      // nothing when it does -- this is only about not sending it.
      if (Object.keys(prev).length >= list.maxTargets) {
        play('ui.error')
        return prev
      }
      play('ui.select')
      return { ...prev, [src]: list.defaultCategory }
    })
  }

  const submit = () => {
    if (selected.length === 0) { play('ui.error'); return }
    play('ui.select')
    void fetchNui(CB.REPORT_SUBMIT, {
      targets: selected.map((src) => ({ src, category: picked[src] })),
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
            {/* THE HEADER SAYS WHAT THIS IS AND NOTHING ELSE. It carried the
                alive count on the right, and #142 took it off: the HUD already
                draws that number in the top-right corner, and two copies of a
                figure that changes every elimination is one copy too many --
                the moment they disagree for a frame, neither is trusted. */}
            <div className="shrink-0 px-4 pt-3.5 pb-3">
              <div className="micro-label">This match</div>
              <h2 className="font-display text-[1.35rem] uppercase leading-none tracking-[0.09em]">
                {reporting ? 'Report' : 'Players'}
              </h2>
            </div>

            <div className="min-h-0 flex-1 overflow-y-auto thin-scroll px-2">
              {rows.length === 0 ? (
                <p className="micro-label px-2 pb-3">Nobody else is here.</p>
              ) : (
                <div className="flex flex-col gap-px pb-2">
                  {rows.map((p) => {
                    const on = picked[p.src] !== undefined
                    // You cannot report yourself, so no tick target is drawn.
                    // The server refuses it too, and so does
                    // BR.IncidentBuild.fromReport; this is only about not
                    // offering it.
                    const selectable = reporting && !p.you
                    const gone = p.left || p.state === 'dead'

                    const status = p.left
                      ? 'left'
                      : p.state === 'dead'
                        ? 'out'
                        : p.state === 'dbno'
                          ? 'down'
                          : p.squadId
                            ? 'squad'
                            : ''

                    const name = (
                      <span className="min-w-0 flex-1 truncate text-[0.9rem] tscale leading-tight">
                        {p.name}
                        {p.you && <span className="micro-label ml-1.5">you</span>}
                      </span>
                    )

                    return (
                      <div key={p.src}>
                        {selectable ? (
                          /* THE WHOLE ROW IS THE TICK TARGET, not a 0.875rem
                             box beside it. A name is the thing the player is
                             actually aiming at, and this panel takes the cursor
                             away from the game to be used -- so the hit area
                             should be the width of the card, not the width of a
                             checkbox.

                             role=checkbox on a button rather than an <input>,
                             which is what makes the drawn box below possible at
                             all: see the note there. Space and Enter both
                             activate a button, and `.btn` gives it the
                             focus-visible ring every other control here has, so
                             the keyboard route is the browser's rather than
                             something reimplemented. */
                          <button
                            type="button"
                            role="checkbox"
                            aria-checked={on}
                            onClick={() => toggle(p.src)}
                            className="btn flex w-full items-center gap-2.5 rounded-sm px-2 py-1.5 text-left"
                            style={{
                              background: on ? 'rgba(255,255,255,0.06)' : 'transparent',
                              opacity: gone ? 0.5 : 1,
                            }}
                          >
                            {/* DRAWN, BECAUSE A NATIVE CHECKBOX IN CEF IS A
                                WINDOWS CHECKBOX (owner, #142: the controls
                                "look nothing like the rest of the interface").

                                Chrome 103 renders <input type=checkbox> with
                                the platform's own control -- a grey box with a
                                blue system tick that belongs to the operating
                                system, sitting inside a panel built out of
                                chamfered near-black plates. `accent-color`
                                recolours the tick and nothing else, which is
                                why the old one still read as an OS widget.

                                `appearance: none` plus drawn states is the
                                usual answer and would have worked; not
                                rendering an <input> at all is simpler and
                                strictly better here, because the row already
                                had to be a button for the hit area above. One
                                control, one element, and no reset property
                                whose support has to be checked against a 2022
                                browser.

                                The tick is an inline SVG rather than a glyph:
                                a text checkmark is a font decision, and this
                                interface ships two faces neither of which is
                                guaranteed to have one. */}
                            <span
                              aria-hidden="true"
                              className="grid size-3.5 shrink-0 place-items-center"
                              style={{
                                border: `1px solid ${on
                                  ? 'var(--color-royale-accent)'
                                  : 'rgba(255,255,255,0.34)'}`,
                                background: on
                                  ? 'var(--color-royale-accent)'
                                  : 'rgba(6,8,13,0.85)',
                                transition: 'background 120ms ease, border-color 120ms ease',
                              }}
                            >
                              {on && (
                                <svg
                                  viewBox="0 0 10 10"
                                  className="size-2.5"
                                  fill="none"
                                  stroke="#04222a"
                                  strokeWidth="1.9"
                                  strokeLinecap="square"
                                >
                                  <path d="M1.6 5.2 L4 7.5 L8.4 2.6" />
                                </svg>
                              )}
                            </span>

                            {name}

                            <span className="micro-label shrink-0">{status}</span>
                          </button>
                        ) : (
                          <div
                            className="flex items-center gap-2.5 rounded-sm px-2 py-1.5"
                            style={{ opacity: gone ? 0.5 : 1 }}
                          >
                            {/* A STATE DOT INSTEAD OF A SENTENCE. At this width
                                "Eliminated" beside every dead player is most of
                                the panel; the colour carries it and the word
                                only appears on the right when it is not
                                "alive". */}
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
                            {name}
                            <span className="micro-label shrink-0">{status}</span>
                          </div>
                        )}

                        {/* THE CATEGORY PICKER ONLY APPEARS FOR A TICKED ROW,
                            and it gets its own lines rather than sharing one --
                            at this width a name and a category side by side
                            truncates the name to nothing, which is the one
                            field that must stay legible on a report.

                            IT IS DRAWN OPEN RATHER THAN BEING A DROPDOWN, and
                            that is not a preference. A native <select> POPUP is
                            rendered by the browser outside the page and cannot
                            be styled on any engine -- not with appearance:none,
                            not with a pseudo-element, not at all -- so on CEF it
                            arrives as a Windows combo list over a battle royale.
                            The only way to control it is not to have one.

                            AND A CUSTOM POPUP WOULD HAVE BEEN WORSE THAN THIS
                            ONE. The list it would open into is inside
                            `overflow-y: auto` (the roster scrolls), so an
                            absolutely positioned menu is clipped by its own
                            scroll container -- the fix for which is portalling
                            it to the root, on a page whose root is deliberately
                            pointer-events:none. An always-open group has none of
                            that, costs one click fewer, and is the shape the
                            settings screen already uses for voice routing and
                            colourblind modes.

                            PLAIN BUTTONS, NOT role=radio. ARIA radios promise
                            arrow-key navigation and a single tab stop, and a
                            role that promises behaviour the code does not
                            implement is worse for a screen reader than no role
                            -- so this is a labelled group of pressable buttons,
                            which is exactly what it is, and Tab reaches every
                            one of them. Same call the settings screen made. */}
                        {selectable && on && (
                          <div
                            role="group"
                            aria-label={`Why you are reporting ${p.name}`}
                            className="mb-1.5 ml-8 mr-2 flex flex-wrap gap-1"
                          >
                            {list.categories.map((c) => {
                              const chosen = picked[p.src] === c.id
                              return (
                                <button
                                  key={c.id}
                                  type="button"
                                  aria-pressed={chosen}
                                  className={`btn plate px-2 py-1 text-[0.72rem] tscale${
                                    chosen ? ' is-active' : ''}`}
                                  style={{
                                    ['--edgec' as string]: chosen
                                      ? 'var(--color-royale-accent)'
                                      : 'rgba(255,255,255,0.16)',
                                    ['--plate-fill' as string]: chosen
                                      ? 'rgba(12,58,72,0.94)'
                                      : 'rgba(24,28,40,0.92)',
                                    ['--cut-max' as string]: '0.3rem',
                                    color: chosen
                                      ? 'var(--color-royale-accent)'
                                      : 'rgba(255,255,255,0.8)',
                                  }}
                                  onPointerEnter={() => play('ui.hover')}
                                  onClick={() => {
                                    play('ui.select')
                                    setPicked((prev) => ({ ...prev, [p.src]: c.id }))
                                  }}
                                >
                                  {c.label}
                                </button>
                              )
                            })}
                          </div>
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
                </div>
              ) : (
                /* ONE BUTTON, AND IT NAMES ITS OBJECT (#142). "Report" on its
                   own reads as a verb with no target on a panel that is a list
                   of people; "Report player" says which of the two it means.
                   It no longer changes to "No reports left" either -- the
                   allowance is not the panel's to talk about, and a player who
                   has spent it is told so by the refusal, in the same toast
                   that would have carried any other reason. */
                <Btn variant="ghost" size="sm" cue="ui.select" onPress={enterReport}>
                  Report player
                </Btn>
              )}
            </div>
          </div>
        </div>
      </div>
    </div>
  )
}
