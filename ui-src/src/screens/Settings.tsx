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
/** Voice routing, in the order a player is most likely to want it. */
const VOICE_MODES: { id: Draft['voiceMode']; label: string; sub: string }[] = [
  { id: 'squad',  label: 'Squad',  sub: 'Only your team, at any distance' },
  { id: 'nearby', label: 'Nearby', sub: 'Anyone close enough to see' },
  { id: 'off',    label: 'Off',    sub: 'You are not transmitting' },
]

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
  // SQUAD VOICE ONLY EXISTS IN SQUADS. In solo there is no squad room to
  // route to, and an option that silently behaves as another one is a lie
  // the settings screen would be telling.
  const squadMode = useUi((s) => s.match.mode === 'squad')
  // The handover confirm. Local, not a store field: it is a question this
  // screen is asking, and nothing else in the interface needs to know it was
  // asked.
  const [voiceConfirm, setVoiceConfirm] = useState(false)
  // The same question for the graphics handover. A SECOND flag rather than one
  // shared "a handover is pending", so the confirm text can name what the
  // player is about to go and change -- the whole point of the confirm is that
  // a full-screen game menu appearing is something they chose.
  const [gfxConfirm, setGfxConfirm] = useState(false)

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

  // NO CUE FIRED HERE. `ui.ready` used to be, and it was wrong twice over: it
  // is the ready-up sound (reserved for that one button -- owner, 2026-08-17),
  // and Btn already plays its own `cue` on click, so pressing Save produced two
  // overlapping sounds. The button below carries the cue; this function is the
  // save, not the press. `ui.error` on a refusal stays -- that one is a second
  // event, not a second press.
  const save = async () => {
    setSaving(true)
    setNameError(null)
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

          {/* DISPLAY IS ITS OWN HEADING, and that is the entire discoverability
              half of #122 (owner, 2026-08-16: "no clear way to reach GTA's own
              graphics/display settings"). The handover already existed -- it
              was a button reading "Microphone & push-to-talk" at the bottom of
              the Voice section, which is not a place anybody looks for their
              resolution. A player scanning headings for where the graphics
              live needs to find a word that means graphics.

              IT SITS ABOVE AUDIO, next to Interface size, because "the game
              looks wrong" and "the interface is too small" are the same
              complaint arriving from two directions, and a player who came
              here for one should see the other. */}
          <Section title="Display">
              <div className="flex flex-col gap-1.5">
                <div className="micro-label">In the game&apos;s own menu</div>
                {/* THE LIST IN THE #148 SCREENSHOT. It was `micro-label` with
                    the uppercase locally cancelled -- four bulleted sentences
                    at 0.2em tracking, which is the exact text the owner held
                    up as hard to read. `.body-text` is the prose style; the
                    heading above it stays a caption. */}
                <ul
                  className="body-text"
                  style={{
                    listStyle: 'disc',
                    paddingLeft: '1.1rem',
                    lineHeight: 1.7,
                  }}
                >
                  <li>Resolution, refresh rate and screen type</li>
                  <li>Texture, shadow and reflection quality</li>
                  <li>Field of view</li>
                  <li>Brightness and safe-zone size</li>
                </ul>
              </div>

              {gfxConfirm ? (
                <div
                  className="plate px-4 py-3 flex flex-col gap-3"
                  style={{
                    ['--edgec' as string]: 'var(--color-royale-accent)',
                    ['--plate-fill' as string]: 'rgba(12,40,50,0.94)',
                    ['--cut-max' as string]: '0.5rem',
                  }}
                >
                  {/* WHAT IS ABOUT TO HAPPEN, in the same words the voice
                      handover uses. These are client settings no script can
                      read or write, and deep-linking the page does not work
                      (GoDeeper reaches the map, not Settings), so the player
                      walks the last two steps and is told which they are. */}
                  <p
                    className="ts"
                    style={{ ['--fs' as string]: '0.88rem', lineHeight: 1.5 }}
                  >
                    Graphics and display settings belong to GTA&nbsp;V itself.
                    Choose OK to open its menu, then go to the{' '}
                    <span className="font-semibold">Settings</span> tab and pick{' '}
                    <span className="font-semibold">Graphics</span> or{' '}
                    <span className="font-semibold">Display</span>. Close that
                    menu and you will come straight back here.
                  </p>
                  <div className="flex gap-2">
                    <Btn
                      variant="primary" size="sm" cue="ui.select"
                      onPress={() => {
                        setGfxConfirm(false)
                        void fetchNui(CB.GAME_SETTINGS, {})
                      }}
                    >
                      OK
                    </Btn>
                    <Btn variant="default" size="sm" cue="ui.back"
                         onPress={() => setGfxConfirm(false)}>
                      Stay here
                    </Btn>
                  </div>
                </div>
              ) : (
                <button
                  type="button"
                  className="btn plate px-4 py-2 self-start font-display uppercase
                             tracking-[0.12em] text-[0.78rem]"
                  style={{
                    ['--edgec' as string]: 'rgba(255,255,255,0.22)',
                    ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
                    ['--cut-max' as string]: '0.4rem',
                  }}
                  onPointerEnter={() => play('ui.hover')}
                  onClick={() => { play('ui.select'); setGfxConfirm(true) }}
                >
                  Graphics &amp; display
                </button>
              )}
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
              {/* THE MUSIC SLIDER IS GONE until there is music (owner,
                  2026-08-09). A control for a system that does not exist is a
                  control that can only ever do nothing, and its own caption
                  said so. The stored value stays in the schema, so turning it
                  back on is one component rather than a migration. */}
          </Section>

          <Section title="Voice">
              {/* WHO HEARS YOU. The server decides which rooms exist and who
                  may be in them; this only chooses which of the ones you were
                  given you actually use -- so it can decline a room, never
                  enter one. See br_core/client/voice.lua.

                  SQUAD IS ABSENT IN SOLO, because there is no squad room to
                  route to and an option that silently behaves as another one
                  is a lie the settings screen would be telling. */}
              <div className="flex flex-col gap-1.5">
                <div className="micro-label">Who hears you</div>
                <div className="flex gap-1.5">
                  {VOICE_MODES.filter((m) => m.id !== 'squad' || squadMode).map((m) => (
                    <button
                      key={m.id}
                      type="button"
                      className={`btn plate px-3 py-2 text-left flex-1${
                        draft.voiceMode === m.id ? ' is-active' : ''}`}
                      style={{
                        ['--edgec' as string]: draft.voiceMode === m.id
                          ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)',
                        ['--plate-fill' as string]: draft.voiceMode === m.id
                          ? 'rgba(12,58,72,0.94)' : 'rgba(24,28,40,0.92)',
                        ['--cut-max' as string]: '0.4rem',
                      }}
                      onPointerEnter={() => play('ui.hover')}
                      onClick={() => { play('ui.select'); set('voiceMode', m.id) }}
                    >
                      <span
                        className="block text-[0.9rem] ts"
                        style={{
                          ['--fs' as string]: '0.9rem',
                          color: draft.voiceMode === m.id
                            ? 'var(--color-royale-accent)' : '#ffffff',
                        }}
                      >
                        {m.label}
                      </span>
                      {/* A description, not a caption: --fs holds it under the
                          0.9rem label above it inside a narrow button. */}
                      <span
                        className="body-text block"
                        style={{ ['--fs' as string]: '0.72rem' }}
                      >
                        {m.sub}
                      </span>
                    </button>
                  ))}
                </div>
              </div>

              {/* NO VOICE VOLUME SLIDER, and the reason is stronger than "it
                  might not work".

                  There is no master output native, so the only way to build
                  one is MUMBLE_SET_VOLUME_OVERRIDE_BY_SERVER_ID across every
                  player -- and that native's own documentation says it "will
                  also bypass 3D audio and distance calculations". A blanket
                  override would therefore flatten every voice to one level
                  regardless of distance, which destroys proximity voice: the
                  thing the whole routing design is built on.

                  The output level lives in the game's own voice settings,
                  which the button below opens. */}

              {/* THE HANDOVER, WITH ITS CARDS ON THE TABLE.
                  These are CLIENT settings -- the same class as key bindings
                  -- and no script can read or write them. Deep-linking the
                  page was tried and does not work (GoDeeper reaches the map,
                  not Settings), so this opens the menu and the player walks
                  the last two steps.

                  Which means the screen owes them two things before it takes
                  it over: WHAT is behind the button, so the trip is worth
                  making, and WHAT IS ABOUT TO HAPPEN, so a full-screen game
                  menu appearing is something they chose rather than something
                  that happened to them (owner, 2026-08-09). */}
              <div className="flex flex-col gap-1.5">
                <div className="micro-label">In the game&apos;s own menu</div>
                <ul
                  className="body-text"
                  style={{
                    listStyle: 'disc',
                    paddingLeft: '1.1rem',
                    lineHeight: 1.7,
                  }}
                >
                  <li>Push-to-talk or voice activation</li>
                  <li>Microphone volume and sensitivity</li>
                  <li>Input device</li>
                  <li>Output device</li>
                  <li>Sound effects and music volume while someone is talking</li>
                </ul>
              </div>

              {voiceConfirm ? (
                <div
                  className="plate px-4 py-3 flex flex-col gap-3"
                  style={{
                    ['--edgec' as string]: 'var(--color-royale-accent)',
                    ['--plate-fill' as string]: 'rgba(12,40,50,0.94)',
                    ['--cut-max' as string]: '0.5rem',
                  }}
                >
                  <p
                    className="ts"
                    style={{ ['--fs' as string]: '0.88rem', lineHeight: 1.5 }}
                  >
                    These settings can only be changed from GTA&nbsp;V&apos;s own
                    pause menu. Choose OK to open it, then go to the{' '}
                    <span className="font-semibold">Settings</span> tab and pick{' '}
                    <span className="font-semibold">Voice Chat</span>.
                  </p>
                  <div className="flex gap-2">
                    <Btn
                      variant="primary" size="sm" cue="ui.select"
                      onPress={() => {
                        setVoiceConfirm(false)
                        // THE PAGE NO LONGER HIDES ITSELF HERE, and that is
                        // the fix rather than an omission (#122). It used to
                        // raise a flag on this line -- and lost, every time,
                        // to the focus envelopes Lua emits while collapsing
                        // its own stack a millisecond later, which the page
                        // read as the frontend having closed. Lua raises the
                        // flag now, after the collapse, and holds it until the
                        // frontend is genuinely down.
                        void fetchNui(CB.VOICE_SETTINGS, {})
                      }}
                    >
                      OK
                    </Btn>
                    <Btn variant="default" size="sm" cue="ui.back"
                         onPress={() => setVoiceConfirm(false)}>
                      Stay here
                    </Btn>
                  </div>
                </div>
              ) : (
                <button
                  type="button"
                  className="btn plate px-4 py-2 self-start font-display uppercase
                             tracking-[0.12em] text-[0.78rem]"
                  style={{
                    ['--edgec' as string]: 'rgba(255,255,255,0.22)',
                    ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
                    ['--cut-max' as string]: '0.4rem',
                  }}
                  onPointerEnter={() => play('ui.hover')}
                  onClick={() => { play('ui.select'); setVoiceConfirm(true) }}
                >
                  Microphone &amp; push-to-talk
                </button>
              )}
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
              {/* THE LINE THE OWNER NAMED IN #148: this was `micro-label`
                  with nothing cancelling it, so two sentences of help text
                  under the name field rendered in tracked-out capitals. It is
                  prose in both branches now -- the error only recolours it,
                  rather than being the one branch that got a readable size. */}
              <p
                className="body-text"
                style={nameError ? { color: 'var(--color-danger)' } : undefined}
              >
                {/* SHORT, BOTH WAYS. The locked line explained the reasoning
                    and the unlocked line explained the rule; neither is what
                    somebody standing at a text box wants to read (owner,
                    2026-08-09). Say what is true and stop. */}
                {nameError
                  ? nameError
                  : nameLocked
                    ? 'You cannot change this while in a match.'
                    : 'A preferred name. It can obscure other identifiers in game.'
                      + ' Leave it empty to use your platform name.'}
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
                    <span
                      className="block body-text mt-0.5"
                      style={{ ['--fs' as string]: '0.72rem' }}
                    >
                      {m.sub}
                    </span>
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
          {/* `ui.select`, NOT `ui.ready`. Saving a preference is an ordinary
              affirmative press; the ready-up swell is a 0.9s struck stack that
              announces a match starting, and hearing it for "Save" in the pause
              menu makes the one moment it belongs to mean nothing (owner,
              2026-08-17). Cancel keeps `ui.back` -- the pair reads correctly. */}
          <Btn variant="primary" size="lg" cue="ui.select" onPress={save}>
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
