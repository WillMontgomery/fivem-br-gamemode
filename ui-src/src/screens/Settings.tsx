import { useEffect, useRef, useState } from 'react'
import { useUi, selSettings } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { SettingsPayload } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'

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
  label, value, min, max, step, format, onChange,
}: {
  label: string
  value: number
  min: number
  max: number
  step: number
  format: (v: number) => string
  onChange: (v: number) => void
}) {
  const pct = ((value - min) / (max - min)) * 100
  return (
    <label className="block">
      <div className="flex items-baseline justify-between mb-1.5">
        <span className="text-[0.82rem] text-white/70 tscale">{label}</span>
        <span className="font-display text-[0.95rem] tabular-nums text-white/90">
          {format(value)}
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

function Toggle({
  label, sub, on, onChange,
}: {
  label: string
  sub?: string
  on: boolean
  onChange: (v: boolean) => void
}) {
  return (
    <button
      type="button"
      className={`btn plate w-full px-3 py-2.5 flex items-center gap-3 text-left${
        on ? ' is-active' : ''}`}
      style={{
        ['--edgec' as string]: on
          ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)',
        ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
        ['--cut-max' as string]: '0.45rem',
      }}
      onPointerEnter={() => play('ui.hover')}
      onClick={() => { play('ui.toggle'); onChange(!on) }}
    >
      <span
        className="w-[2.1rem] h-[1.1rem] rounded-full shrink-0 relative"
        style={{
          background: on ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)',
          transition: 'background 160ms ease',
        }}
      >
        <span
          className="absolute top-[0.15rem] w-[0.8rem] h-[0.8rem] rounded-full bg-white"
          style={{
            left: on ? 'calc(100% - 0.95rem)' : '0.15rem',
            transition: 'left 160ms var(--ease-out)',
          }}
        />
      </span>
      <span className="min-w-0">
        <span className="block text-[0.85rem] tscale">{label}</span>
        {sub && (
          <span className="block micro-label mt-0.5">{sub}</span>
        )}
      </span>
    </button>
  )
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mb-8">
      <h3 className="font-display text-[0.95rem] uppercase tracking-[0.2em] text-white/40 mb-3">
        {title}
      </h3>
      <div className="flex flex-col gap-4">{children}</div>
    </section>
  )
}

export default function Settings() {
  const stored = useUi(selSettings)
  const setSettings = useUi((s) => s.setSettings)
  // CLOSING IS RELEASING FOCUS, and nothing else. This screen is rendered
  // because Lua says it owns the cursor, so a local "closed" flag would be a
  // second opinion about the same fact -- which is how you end up with a
  // cursor over no menu.
  const close = () => { void fetchNui(CB.SETTINGS_FOCUS, { open: false }) }

  // The draft is seeded from the store and pushed straight back into it on
  // every change -- which is what makes the preview live. It is NOT a
  // pending-changes buffer: there is no state in here that the rest of the
  // interface is not already showing.
  const [draft, setDraft] = useState<Draft>(stored)
  const [saving, setSaving] = useState(false)

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
    play('ui.ready')
    const res = await fetchNui<Draft, { ok: boolean; settings?: SettingsPayload }>(
      CB.SETTINGS_SAVE, draft)
    if (res?.settings) setSettings(res.settings)
    setSaving(false)
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
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      cancel()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  return (
    <div
      className="interactive fixed inset-0 z-50 overflow-y-auto thin-scroll"
      style={{
        // OPAQUE, unlike every other surface. See the note at the top.
        backgroundColor: 'rgba(8, 9, 14, 0.985)',
      }}
    >
      <div
        className="mx-auto py-10"
        style={{ width: '62rem', maxWidth: '92vw' }}
      >
        <div className="flex items-baseline justify-between mb-8">
          <h2 className="font-display text-[2.6rem] uppercase tracking-[0.14em] leading-none">
            Settings
          </h2>
          <span className="micro-label">Esc to go back</span>
        </div>

        <div className="grid grid-cols-2 gap-x-10">
          <div>
            <Section title="Interface">
              <Slider
                label="Interface size" value={draft.uiScale}
                min={0.8} max={1.3} step={0.01}
                format={(v) => `${Math.round(v * 100)}%`}
                onChange={(v) => set('uiScale', v)}
              />
              <Slider
                label="Text size" value={draft.textScale}
                min={0.9} max={1.15} step={0.01}
                format={(v) => `${Math.round(v * 100)}%`}
                onChange={(v) => set('textScale', v)}
              />
              {/* The one control that explains itself by existing: turn it on
                  and the box the HUD lives in is drawn, which is the only way
                  to answer "is my HUD cut off, or is that where it goes". */}
              <Toggle
                label="Show safe area"
                sub="Draws the box the HUD lays out inside"
                on={draft.safeArea}
                onChange={(v) => set('safeArea', v)}
              />
            </Section>

            <Section title="Audio">
              <Slider
                label="Interface sounds" value={draft.volUi}
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
                label="Music" value={draft.volMusic}
                min={0} max={1} step={0.01}
                format={(v) => (v === 0 ? 'Muted' : `${Math.round(v * 100)}%`)}
                onChange={(v) => set('volMusic', v)}
              />
              <p className="micro-label">
                Music is not in the game yet — this is stored for when it is.
              </p>
            </Section>
          </div>

          <div>
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

            <Section title="Identity">
              <label className="block">
                <span className="block text-[0.82rem] text-white/70 mb-1.5 tscale">
                  Display name
                </span>
                <input
                  value={draft.gamertag}
                  maxLength={20}
                  placeholder="Your platform name"
                  onChange={(e) => set('gamertag', e.target.value)}
                  onKeyDown={(e) => e.stopPropagation()}
                  className="plate w-full px-3 py-2 bg-transparent outline-none
                             text-[0.9rem] placeholder:text-white/25"
                  style={{
                    ['--edgec' as string]: 'rgba(255,255,255,0.16)',
                    ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
                    ['--cut-max' as string]: '0.45rem',
                  }}
                />
              </label>
              <p className="micro-label">
                3–20 characters. Applied in the lobby only — renaming mid-match
                would rewrite the kill feed everyone else is reading. Leave it
                empty to use your platform name.
              </p>
            </Section>

            <Section title="Controls">
              <Btn
                variant="default"
                size="md"
                full
                cue="ui.select"
                onPress={() => { void fetchNui(CB.KEYBINDS, {}) }}
              >
                Open key bindings
              </Btn>
              <p className="micro-label">
                Every key in this game is rebindable, and they live in GTA&apos;s
                own pause menu under Settings &rarr; Key Bindings &rarr; FiveM.
                A rebinder in here would be a second list that disagrees with
                the one the game actually reads.
              </p>
            </Section>
          </div>
        </div>

        <div className="flex gap-3 mt-4">
          <Btn variant="primary" size="lg" cue="ui.ready" onPress={save}>
            {saving ? 'Saving…' : 'Save'}
          </Btn>
          <Btn variant="default" size="lg" cue="ui.back" onPress={cancel}>
            Cancel
          </Btn>
        </div>
      </div>
    </div>
  )
}
