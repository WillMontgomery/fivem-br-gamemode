import { useEffect, useRef, useState } from 'react'
import { useUi, selSettings } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { SettingsPayload } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'
import { DEFAULT_SETTINGS } from '../settings/apply'
import Keybinds from './Keybinds'

/**
 * Settings.
 *
 * FULL SCREEN, AND OPAQUE, WHICH IS A DEPARTURE. Every other surface in this
 * project is translucent because it is drawn over a running game and hiding
 * the game is the cardinal sin. This one is the exception on purpose: you are
 * not playing while you are in here, the controls need contrast to be judged
 * against, and half the settings CHANGE HOW THINGS LOOK -- you cannot evaluate
 * a colourblind palette through a window onto a jungle.
 *
 * EVERY CONTROL PREVIEWS ITSELF, IMMEDIATELY. Dragging the interface scale
 * resizes this screen while you drag it, because the only useful question is
 * "is this the size I want" and a preview that waits for Apply cannot answer
 * it. The save is what persists; the preview is what decides.
 *
 * LUA IS THE AUTHORITY ON THE VALUES. A save sends the whole object and this
 * screen renders the ECHO -- so a value outside the accepted range visibly
 * snaps to what was actually stored, rather than a slider sitting on a number
 * the game never agreed to. That is also why there is no local "dirty" state
 * to reconcile: the store is the truth and it is one round trip away.
 */

type Draft = SettingsPayload

const CB_MODES: { id: Draft['colourblind']; label: string; sub: string }[] = [
  { id: 'off',    label: 'Off',           sub: 'Standard palette' },
  { id: 'deuter', label: 'Deuteranopia',  sub: 'Green-weak — the most common' },
  { id: 'protan', label: 'Protanopia',    sub: 'Red-weak' },
  { id: 'tritan', label: 'Tritanopia',    sub: 'Blue-yellow' },
]

/**
 * A slider that is legible at a glance.
 *
 * `<input type=range>` in CEF renders as the OS control, which on Windows is a
 * thin grey line that does not belong to anything else on this screen -- so
 * the track and the fill are drawn, and the native input sits on top of them
 * at zero opacity doing the dragging. That keeps the keyboard and the drag
 * behaviour the browser already implements correctly, which is the part worth
 * having, and none of the appearance, which is the part that is wrong.
 */
function Slider({
  label, value, min, max, step, format, onChange, dflt,
}: {
  label: string
  value: number
  min: number
  max: number
  step: number
  format: (v: number) => string
  onChange: (v: number) => void
  /** Where this control sits when nobody has touched it. */
  dflt: number
}) {
  const pct = ((value - min) / (max - min)) * 100
  // Floats, so compared with a tolerance rather than ==. A control sitting a
  // hundredth off its default because of a drag is still at its default as
  // far as anybody looking at the screen is concerned.
  const moved = Math.abs(value - dflt) > 0.001

  return (
    <label className="block">
      <div className="flex items-baseline justify-between mb-1.5 gap-2">
        <span className="text-[0.82rem] text-white/70 tscale">{label}</span>

        {/* RESET APPEARS ONLY ON A CONTROL THAT HAS MOVED.
            A row of reset buttons next to untouched controls is noise, and it
            makes "did I change this?" a thing you have to work out by reading
            numbers. Showing it only where it applies makes the affordance
            answer that question by existing (user, 2026-08-09).

            It occupies no layout when hidden -- the value sits in a
            fixed-width cell to its right, so nothing shifts when it appears. */}
        <span className="flex items-baseline gap-2 shrink-0">
          {moved && (
            <button
              type="button"
              className="btn plate px-1.5 py-0.5 text-[0.6rem] font-display
                         uppercase tracking-[0.12em]"
              style={{
                ['--edgec' as string]: 'rgba(255,255,255,0.22)',
                ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
                ['--cut-max' as string]: '0.25rem',
                color: 'rgba(255,255,255,0.6)',
              }}
              title={`Back to ${format(dflt)}`}
              onPointerEnter={() => play('ui.hover')}
              onClick={(e) => { e.preventDefault(); play('ui.back'); onChange(dflt) }}
            >
              Reset
            </button>
          )}
          <span
            className="font-display text-[0.95rem] tabular-nums text-right"
            style={{
              minWidth: '3.4rem',
              color: moved ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.9)',
            }}
          >
            {format(value)}
          </span>
        </span>
      </div>
      <div className="relative h-[1.1rem] flex items-center">
        <div className="absolute inset-x-0 h-[0.34rem] rounded-full bg-black/55" />
        <div
          className="absolute h-[0.34rem] rounded-full"
          style={{ width: `${pct}%`, background: 'var(--color-royale-accent)' }}
        />
        <div
          className="absolute w-[0.85rem] h-[0.85rem] rounded-full shadow"
          style={{
            left: `calc(${pct}% - 0.425rem)`,
            background: '#ffffff',
          }}
        />
        <input
          type="range"
          min={min} max={max} step={step} value={value}
          onChange={(e) => onChange(Number(e.target.value))}
          className="absolute inset-0 w-full opacity-0 cursor-pointer"
          style={{ height: '1.1rem' }}
        />
      </div>
    </label>
  )
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section>
      <h3 className="font-display text-[0.95rem] uppercase tracking-[0.2em] text-white/40 mb-3">
        {title}
      </h3>
      <div className="flex flex-col gap-4">{children}</div>
    </section>
  )
}

/**
 * THE TABS.
 *
 * Settings was one long column of five sections, which at a small resolution
 * fully zoomed in overflowed and put a scroll bar on the whole page -- taking
 * the title, the tabs and the Save button with it (user, 2026-08-09).
 *
 * Splitting it is not only a scrolling fix. Five labelled destinations tell a
 * player what this screen CONTAINS before they have read any of it, which one
 * long column cannot do at any resolution. Controls in particular is a list of
 * eighteen rows that has no business sharing a viewport with three sliders.
 *
 * The order is the user's, and it is a good one: the things most people change
 * first (size, volume) before the things most people never change.
 */
const TABS = [
  // GENERAL absorbs Interface, Audio and Identity. Five tabs for what is
  // really eight controls made the screen look bigger than it is, and made
  // the player click three times to see three sliders (user, 2026-08-09).
  // Controls and Accessibility stay separate because each is genuinely its
  // own thing: one is a twenty-row table, the other is a decision with a
  // preview.
  { id: 'general',       label: 'General' },
  { id: 'controls',      label: 'Controls' },
  { id: 'accessibility', label: 'Accessibility' },
] as const

type Tab = typeof TABS[number]['id']

function Tabs({ tab, onTab }: { tab: Tab; onTab: (t: Tab) => void }) {
  return (
    <div className="flex gap-2 mb-6 flex-wrap">
      {TABS.map((t) => (
        <button
          key={t.id}
          type="button"
          className={`btn plate px-4 py-2 font-display uppercase tracking-[0.12em]
                      text-[0.8rem]${tab === t.id ? ' is-active' : ''}`}
          style={{
            ['--edgec' as string]: tab === t.id
              ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)',
            ['--plate-fill' as string]: tab === t.id
              ? 'rgba(12,58,72,0.94)' : 'rgba(24,28,40,0.92)',
            ['--cut-max' as string]: '0.45rem',
            color: tab === t.id ? 'var(--color-royale-accent)' : '#ffffff',
          }}
          onPointerEnter={() => play('ui.hover')}
          onClick={() => { play('ui.select'); onTab(t.id) }}
        >
          {t.label}
        </button>
      ))}
    </div>
  )
}

export default function Settings({
  inline = false, onDone,
}: {
  /** Embedded in another screen (the pause menu) rather than owning the
   *  viewport: drops the full-screen backdrop and the outer scroll, because
   *  the host already has both. */
  inline?: boolean
  /** Where Save and Cancel go when embedded. Without it they release focus,
   *  which would close the HOST as well. */
  onDone?: () => void
} = {}) {
  const stored = useUi(selSettings)
  const setSettings = useUi((s) => s.setSettings)
  // CLOSING IS RELEASING FOCUS, and nothing else. This screen is rendered
  // because Lua says it owns the cursor, so a local "closed" flag would be a
  // second opinion about the same fact -- which is how you end up with a
  // cursor over no menu.
  //
  // Unless it is EMBEDDED, in which case the host owns the focus and this is
  // a tab, not a screen -- releasing focus here would close the pause menu
  // out from under the player.
  const close = () => {
    if (onDone) { onDone(); return }
    void fetchNui(CB.SETTINGS_FOCUS, { open: false })
  }

  // The SERVER's rule, mirrored here so the field can explain itself. It
  // accepts a rename only while the player is in the LOBBY state -- see
  // BR.Roster.setName. `hud.state` is the server's word on where we are, so
  // this stays a mirror rather than a second opinion.
  const nameLocked = useUi((s) => s.hud.state !== 'lobby')

  // The draft is seeded from the store and pushed straight back into it on
  // every change -- which is what makes the preview live. It is NOT a
  // pending-changes buffer: there is no state in here that the rest of the
  // interface is not already showing.
  const [draft, setDraft] = useState<Draft>(stored)
  const [saving, setSaving] = useState(false)
  const [tab, setTab] = useState<Tab>('general')
  /** Why the last save refused the name, if it did. */
  const [nameError, setNameError] = useState<string | null>(null)

  // WHAT CANCEL GOES BACK TO. Captured once, when the screen opens -- and the
  // screen is conditionally rendered, so mounting IS opening.
  //
  // This started out as "the last value the store held", which is wrong in a
  // way that only shows up when you press Cancel: the live preview writes
  // through the store, so the baseline chased every slider drag and Cancel
  // restored the values it was supposed to be discarding (caught in the
  // browser harness, and it would have been invisible in a screenshot).
  const baseline = useRef<Draft>(stored)

  // Our own previews come back through the store; Lua's echo also comes back
  // through the store. Only the second is news. Comparing IDENTITY rather
  // than value because two settings objects can be equal and mean different
  // things -- a clamp that changed nothing is still Lua speaking.
  const mine = useRef<Draft | null>(null)
  useEffect(() => {
    if (stored === mine.current) return
    baseline.current = stored
    setDraft(stored)
  }, [stored])

  const set = <K extends keyof Draft>(key: K, value: Draft[K]) => {
    const next = { ...draft, [key]: value }
    mine.current = next
    setDraft(next)
    // Straight into the store, which applies it to the document. THIS is the
    // preview -- there is no separate preview path that could disagree with
    // what saving would actually do.
    setSettings(next)
  }

  const save = async () => {
    setSaving(true)
    setNameError(null)
    play('ui.ready')
    const res = await fetchNui<Draft, {
      ok: boolean; settings?: SettingsPayload; field?: string; reason?: string
    }>(CB.SETTINGS_SAVE, draft)
    setSaving(false)

    // A REFUSED NAME KEEPS THE SCREEN OPEN. Closing on a failed save would
    // discard the thing the player typed and tell them nothing -- the only
    // sign would be their old name still on the roster, which reads as the
    // save silently not working (user, 2026-08-09).
    if (res && res.ok === false) {
      play('ui.error')
      if (res.field === 'gamertag') {
        setNameError(res.reason ?? 'That name is not available.')
        setTab('general')
      }
      return
    }

    if (res?.settings) setSettings(res.settings)
    close()
  }

  const cancel = () => {
    play('ui.back')
    // Put back what was on screen when this opened, which undoes every live
    // preview in one step -- the reason the preview writes through the store
    // rather than to the document directly.
    mine.current = null
    setSettings(baseline.current)
    close()
  }

  // Escape closes, because it is the key everyone tries first and a
  // full-screen menu that ignores it feels broken.
  //
  // NOT WHEN EMBEDDED: the pause menu owns Escape there, and two capturing
  // handlers both calling preventDefault means whichever registered last
  // decides -- which is a race, not a design.
  useEffect(() => {
    if (inline) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      cancel()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  const body = (
    <>
      {!inline && (
        <div className="flex items-baseline justify-between mb-8">
          <h2 className="font-display text-[2.6rem] uppercase tracking-[0.14em] leading-none">
            Settings
          </h2>
          <span className="micro-label">Esc to go back</span>
        </div>
      )}

      <Tabs tab={tab} onTab={setTab} />

      {/* THE SCROLL LIVES IN THE PANE, NOT ON THE PAGE. At a small resolution
          fully zoomed in, the old single-column-of-everything overflowed and
          the whole screen scrolled -- so the title, the tabs and the Save
          button all slid away with it (user, 2026-08-09). Only the pane moves
          now; everything that orients you stays put. */}
      <div className="pane thin-scroll">
        {tab === 'general' && (
          <div className="flex flex-col gap-8">
          <Section title="Interface">
              <Slider
                label="Interface size" value={draft.uiScale} dflt={DEFAULT_SETTINGS.uiScale}
                min={0.8} max={1.3} step={0.01}
                format={(v) => `${Math.round(v * 100)}%`}
                onChange={(v) => set('uiScale', v)}
              />
              <Slider
                label="Text size" value={draft.textScale} dflt={DEFAULT_SETTINGS.textScale}
                min={0.9} max={1.15} step={0.01}
                format={(v) => `${Math.round(v * 100)}%`}
                onChange={(v) => set('textScale', v)}
              />
          </Section>

          <Section title="Audio">
              <Slider
                label="Interface sounds" value={draft.volUi} dflt={DEFAULT_SETTINGS.volUi}
                min={0} max={1} step={0.01}
                format={(v) => (v === 0 ? 'Muted' : `${Math.round(v * 100)}%`)}
                onChange={(v) => {
                  set('volUi', v)
                  // Audible immediately, at the new level. A volume slider
                  // that makes no sound while you drag it is a slider you
                  // have to set by guessing.
                  play('ui.hover')
                }}
              />
              <Slider
                label="Music" value={draft.volMusic} dflt={DEFAULT_SETTINGS.volMusic}
                min={0} max={1} step={0.01}
                format={(v) => (v === 0 ? 'Muted' : `${Math.round(v * 100)}%`)}
                onChange={(v) => set('volMusic', v)}
              />
              <p className="micro-label">
                Music is not in the game yet — this is stored for when it is.
              </p>
          </Section>
          <Section title="Identity">
              {/* LOCKED IN A MATCH, AND IT SAYS SO IN THREE WAYS: the field is
                  disabled, it wears a lock, and the line underneath explains
                  WHY rather than just that. The server already refuses a
                  rename outside the lobby (br_core/server/roster.lua), so
                  without this the player could type a new name, press Save,
                  and watch nothing happen with no explanation offered --
                  which reads as a broken field rather than as a rule (user,
                  2026-08-09). */}
              <label className="block">
                <span className="block text-[0.82rem] text-white/70 mb-1.5 tscale">
                  Display name
                </span>
                <div className="relative">
                  <input
                    value={draft.gamertag}
                    maxLength={20}
                    disabled={nameLocked}
                    placeholder={nameLocked ? '' : 'Your platform name'}
                    onChange={(e) => { setNameError(null); set('gamertag', e.target.value) }}
                    onKeyDown={(e) => e.stopPropagation()}
                    className={`plate w-full px-3 py-2 bg-transparent outline-none
                                text-[0.9rem] placeholder:text-white/25${
                                  nameLocked ? ' pr-9 cursor-not-allowed' : ''}`}
                    style={{
                      ['--edgec' as string]: nameError
                        ? 'var(--color-danger)' : 'rgba(255,255,255,0.16)',
                      ['--plate-fill' as string]: nameError
                        ? 'rgba(52,20,24,0.92)' : 'rgba(24,28,40,0.94)',
                      ['--cut-max' as string]: '0.45rem',
                      color: nameLocked ? 'rgba(255,255,255,0.4)' : undefined,
                    }}
                  />
                  {nameLocked && (
                    <span
                      className="absolute right-2.5 top-1/2 -translate-y-1/2 pointer-events-none"
                      style={{ color: 'rgba(255,255,255,0.35)' }}
                      aria-hidden="true"
                    >
                      {/* Drawn, not a glyph: there is no icon font here and a
                          unicode padlock renders as a different picture on
                          every platform. */}
                      <svg width="0.95rem" height="0.95rem" viewBox="0 0 24 24">
                        <path
                          fill="currentColor"
                          d="M12 2a5 5 0 0 0-5 5v3H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h12a2 2 0 0 0
                             2-2v-8a2 2 0 0 0-2-2h-1V7a5 5 0 0 0-5-5zm0 2a3 3 0 0 1 3 3v3H9V7a3 3
                             0 0 1 3-3zm0 11a2 2 0 0 1 1 3.73V20h-2v-1.27A2 2 0 0 1 12 15z"
                        />
                      </svg>
                    </span>
                  )}
                </div>
              </label>
              <p
                className={nameError ? 'text-[0.78rem] tscale' : 'micro-label'}
                style={nameError ? { color: 'var(--color-danger)' } : undefined}
              >
                {nameError
                  ? nameError
                  : nameLocked
                    ? 'Locked while you are in a match — your name is in the kill'
                      + ' feed everyone else is reading. It unlocks in the lobby.'
                    : '3–20 characters, and it has to be something everyone else'
                      + ' can be shown. Leave it empty to use your platform name.'}
              </p>
          </Section>
          </div>
        )}

        {tab === 'accessibility' && (
          <Section title="Accessibility">
              <div className="grid grid-cols-2 gap-2">
                {CB_MODES.map((m) => (
                  <button
                    key={m.id}
                    type="button"
                    className={`btn plate px-3 py-2.5 text-left${
                      draft.colourblind === m.id ? ' is-active' : ''}`}
                    style={{
                      ['--edgec' as string]: draft.colourblind === m.id
                        ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)',
                      ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
                      ['--cut-max' as string]: '0.45rem',
                    }}
                    onPointerEnter={() => play('ui.hover')}
                    onClick={() => { play('ui.select'); set('colourblind', m.id) }}
                  >
                    <span className="block text-[0.85rem] tscale">{m.label}</span>
                    <span className="block micro-label mt-0.5">{m.sub}</span>
                  </button>
                ))}
              </div>

              {/* THE PREVIEW IS THE POINT. Choosing a colourblind mode from a
                  list of names is choosing blind; the five rarities sitting
                  underneath repaint as you pick, which is the only way to
                  tell whether a mode actually helps YOU. */}
              <div>
                <div className="micro-label mb-2">Rarity, as you will see it</div>
                <div className="flex gap-2">
                  {[1, 2, 3, 4, 5].map((r) => (
                    <div
                      key={r}
                      className="plate flex-1 px-2 py-2 flex flex-col items-center gap-1.5"
                      style={{
                        ['--edgec' as string]: `var(--rarity-${r})`,
                        ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
                        ['--cut-max' as string]: '0.4rem',
                        color: `var(--rarity-${r})`,
                      }}
                    >
                      <span className="font-display text-[0.7rem] tracking-[0.1em]">
                        {['CMN', 'UNC', 'RAR', 'EPC', 'LEG'][r - 1]}
                      </span>
                      {/* Pips are a COUNT, and a count works for everybody.
                          Hidden by CSS when the mode is off. */}
                      <span className="rarity-pips">
                        {Array.from({ length: r }, (_, i) => <i key={i} />)}
                      </span>
                    </div>
                  ))}
                </div>
              </div>
          </Section>
        )}


        {tab === 'controls' && (
          <Section title="Controls">
            <Keybinds />
          </Section>
        )}
      </div>

        <div className="flex gap-3 mt-4">
          <Btn variant="primary" size="lg" cue="ui.ready" onPress={save}>
            {saving ? 'Saving…' : 'Save'}
          </Btn>
          <Btn variant="default" size="lg" cue="ui.back" onPress={cancel}>
            Cancel
          </Btn>
        </div>
    </>
  )

  // EMBEDDED: no backdrop, no viewport, no scroll container. The pause menu
  // supplies all three, and nesting a second `fixed inset-0` inside it would
  // cover the tabs that got you here.
  if (inline) return body

  return (
    <div
      className="interactive fixed inset-0 z-50 overflow-y-auto thin-scroll"
      style={{
        // OPAQUE, unlike every other surface. See the note at the top.
        backgroundColor: 'rgba(8, 9, 14, 0.985)',
      }}
    >
      <div className="mx-auto py-10" style={{ width: '62rem', maxWidth: '92vw' }}>
        {body}
      </div>
    </div>
  )
}
