import { useEffect, useState } from 'react'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { KeybindAction } from '../bridge/types'
import { play } from '../audio/cues'

/**
 * Key bindings, rebindable HERE.
 *
 * Every key in this game goes through RegisterKeyMapping, which is correct
 * platform citizenship and a terrible player experience: the list ends up four
 * levels deep in GTA's own pause menu, sorted by resource, and nothing in our
 * interface hints that it exists (user, 2026-08-09: "which are very obscure
 * for these settings btw - they're buried").
 *
 * WHAT TRAVELS IS A VIRTUAL-KEY CODE, not a key name. The first version sent
 * FiveM key names for its `bind` console command and nothing applied; Lua now
 * reads the key itself with IS_RAW_KEY_PRESSED, which takes a Windows VK code.
 * `event.keyCode` IS that code in Chrome, which is the one thing the
 * deprecated property is still good for and exactly why it is used here.
 *
 * PRESS-A-KEY CAPTURE, not a dropdown of key names. A dropdown asks the player
 * to know what their keyboard calls a key; capture asks them to press it. The
 * row goes into a listening state, the next keydown wins, and Escape cancels
 * -- which is why Escape can never itself be captured, and why every row has a
 * reset: it is the only way back to a default Escape holds.
 *
 * TWO SLOTS PER ACTION, as in GTA's own controls screen. Either key fires it.
 * Lua owns both; this sends a slot number and renders what comes back, so a
 * conflict resolving in favour of the new binding (the loser is left unbound,
 * which is what every game does) shows up as the other row emptying without
 * this component modelling it.
 */

/** Codes this screen refuses to hand over, and why. */
const RESERVED: Record<number, string> = {
  0x1B: 'Escape',   // cancels the capture, and opens our pause menu
  0x0D: 'Enter',    // the chat input needs it
  0x74: 'F7',       // FiveM's own console toggle on some builds
  0x78: 'F8',       // the console. Taking it would be unrecoverable.
}

/** A capture in progress: which row, and which of its two slots. */
type Listening = { command: string; slot: 1 | 2 }

export default function Keybinds() {
  const actions = useUi((s) => s.keybinds)
  const rawActive = useUi((s) => s.keybindsRaw)
  const [listening, setListening] = useState<Listening | null>(null)
  const [rejected, setRejected] = useState<string | null>(null)

  useEffect(() => {
    if (!listening) return

    const reject = (why: string) => {
      play('ui.error')
      setRejected(why)
      window.setTimeout(() => setRejected(null), 2400)
    }

    const onKey = (e: KeyboardEvent) => {
      // Capture phase and stopped hard: while a row is listening, the key
      // belongs to the row. Without this, Escape would also reach the
      // settings screen's own handler and close it.
      e.preventDefault()
      e.stopPropagation()

      const code = e.keyCode
      if (code === 0x1B) { play('ui.back'); setListening(null); return }

      if (RESERVED[code]) { reject(`${RESERVED[code]} is reserved and cannot be bound.`); return }

      play('ui.ready')
      void fetchNui(CB.KEYBIND_SET, {
        command: listening.command, vk: code, slot: listening.slot,
      })
      setListening(null)
    }

    // MOUSE BUTTONS CANNOT BE BOUND, and saying so where somebody tries is
    // worth more than leaving them clicking. FiveM's raw-key natives read
    // GTA's own KEYBOARD state array -- 256 slots indexed by virtual-key code,
    // fed from keyboard messages (InputNatives.cpp). The mouse never enters
    // that array and there is no raw-mouse native, so a binding on mouse 4
    // would save, display, and never fire once. A capture that silently
    // accepted it would be the worst version of this.
    const onMouse = (e: MouseEvent) => {
      e.preventDefault()
      e.stopPropagation()
      reject('Mouse buttons cannot be bound — the game only reports keyboard keys.')
      setListening(null)
    }

    window.addEventListener('keydown', onKey, true)
    window.addEventListener('mousedown', onMouse, true)
    return () => {
      window.removeEventListener('keydown', onKey, true)
      window.removeEventListener('mousedown', onMouse, true)
    }
  }, [listening])

  if (actions.length === 0) {
    return <p className="micro-label">Loading controls…</p>
  }

  // Grouped, because eighteen undifferentiated rows is a list nobody reads.
  const groups: string[] = []
  for (const a of actions) if (!groups.includes(a.group)) groups.push(a.group)

  return (
    <div className="flex flex-col gap-4">
      {/* THE HONEST CAVEAT, and only when it applies. If Lua's raw-key layer
          could not start, rebinding here would do nothing at all -- so the
          screen says so and points at the list that still works, rather than
          offering controls that silently fail. */}
      {!rawActive && (
        <div
          className="plate px-3 py-2 text-[0.8rem] tscale"
          style={{
            ['--edgec' as string]: 'var(--color-danger-edge)',
            ['--plate-fill' as string]: 'rgba(52,20,24,0.92)',
            ['--cut-max' as string]: '0.45rem',
          }}
        >
          Rebinding is unavailable on this client — the keys below are what the
          game is using. They can still be changed in GTA&apos;s own key
          bindings.
        </div>
      )}

      {/* NARROW, NOT FULL WIDTH. A settings pane is ~60rem and these rows are
          a short label and a key -- stretched across all of it, the label and
          its key ended up so far apart that reading across was guesswork
          (user, 2026-08-09). The rows alternate so the eye can hold a line. */}
      {groups.map((g) => (
        <div key={g} style={{ width: '38rem', maxWidth: '100%' }}>
          <div className="flex items-baseline justify-between mb-1.5">
            <div className="micro-label">{g}</div>
            <div className="micro-label" style={{ opacity: 0.5 }}>
              Key&nbsp;&nbsp;/&nbsp;&nbsp;Alternate
            </div>
          </div>
          <div className="flex flex-col">
            {actions.filter((a) => a.group === g).map((a, i) => (
              <Row
                key={a.command}
                action={a}
                zebra={i % 2 === 1}
                enabled={rawActive}
                listening={listening?.command === a.command ? listening.slot : null}
                onListen={(slot) => { play('ui.select'); setListening({ command: a.command, slot }) }}
              />
            ))}
          </div>
        </div>
      ))}

      <p className="micro-label" style={{ textTransform: 'none' }}>
        {listening
          ? 'Press a key — Escape cancels.'
          : rejected
            ? rejected
            : 'Click a key to rebind it. Every action can hold two; either one fires it.'}
      </p>

      {/* THE ONE THING A PLAYER WILL OTHERWISE FIND OUT THE CONFUSING WAY.
          GTA's own key-bindings list keeps showing the defaults this project
          registered, because nothing can change the engine's stored mapping
          from script -- so after rebinding here, that list disagrees and is
          not what the game is reading (user, 2026-08-09: "FiveM's keybinds
          haven't been changed"). Saying so is cheaper than letting somebody
          discover it and conclude the rebinder is broken. */}
      {rawActive && (
        <p className="micro-label" style={{ opacity: 0.75, textTransform: 'none' }}>
          This list is what the game uses. GTA&apos;s own key bindings screen
          still shows its defaults and no longer affects play.
        </p>
      )}
    </div>
  )
}

function Row({
  action, listening, enabled, zebra, onListen,
}: {
  action: KeybindAction
  /** Which slot is capturing, or null. */
  listening: 1 | 2 | null
  enabled: boolean
  /** Alternate row shading, so a long list can be read across. */
  zebra: boolean
  onListen: (slot: 1 | 2) => void
}) {
  return (
    <div
      className="flex items-center gap-2 px-2 py-1 rounded-sm"
      style={{ background: zebra ? 'rgba(255,255,255,0.035)' : 'transparent' }}
    >
      <span className="text-[0.82rem] text-white/70 tscale flex-1 min-w-0 truncate">
        {action.label}
      </span>

      <Slot label={action.key} enabled={enabled}
            listening={listening === 1}
            onListen={() => onListen(1)}
            onClear={() => { void fetchNui(CB.KEYBIND_SET, { command: action.command, vk: 0, slot: 1 }) }} />

      {/* The alternate reads as SECONDARY: dimmer when empty, same size when
          set. A second slot that looked identical to the first would suggest
          an action needs two keys, and almost none of them do. */}
      <Slot label={action.altKey} enabled={enabled} secondary
            listening={listening === 2}
            onListen={() => onListen(2)}
            onClear={() => { void fetchNui(CB.KEYBIND_SET, { command: action.command, vk: 0, slot: 2 }) }} />

      {/* RESET, and it is not a nicety. Escape cancels a capture, so Escape
          can never be typed into one -- and the pause menu's default IS
          Escape. Without this, rebinding it once would be a one-way door. */}
      <button
        type="button"
        data-plain
        className="text-[0.8rem] px-1 leading-none"
        style={{
          color: action.custom && enabled ? 'rgba(255,255,255,0.35)' : 'transparent',
          pointerEvents: action.custom && enabled ? 'auto' : 'none',
        }}
        title="Reset to default"
        onClick={() => {
          play('ui.back')
          void fetchNui(CB.KEYBIND_SET, { command: action.command, reset: true })
        }}
      >
        &#8635;
      </button>
    </div>
  )
}

/** One of the two key buttons, with its own clear. */
function Slot({
  label, listening, enabled, secondary, onListen, onClear,
}: {
  label: string
  listening: boolean
  enabled: boolean
  secondary?: boolean
  onListen: () => void
  onClear: () => void
}) {
  const unbound = !label
  return (
    <div className="flex items-center">
      <button
        type="button"
        disabled={!enabled}
        className={`btn plate px-3 py-1 font-display text-[0.78rem] tracking-[0.1em]
                    text-center${listening ? ' is-active' : ''}${
                      enabled ? '' : ' btn--off'}`}
        style={{
          minWidth: '5.5rem',
          ['--edgec' as string]: listening
            ? 'var(--color-royale-accent)'
            : unbound ? 'rgba(255,255,255,0.10)' : 'rgba(255,255,255,0.22)',
          ['--plate-fill' as string]: listening
            ? 'rgba(12,58,72,0.94)'
            : secondary ? 'rgba(24,27,38,0.94)' : 'rgba(30,34,48,0.94)',
          ['--cut-max' as string]: '0.3rem',
          color: listening
            ? 'var(--color-royale-accent)'
            : unbound ? 'rgba(255,255,255,0.25)'
              : secondary ? 'rgba(255,255,255,0.8)' : '#ffffff',
        }}
        onPointerEnter={() => { if (!listening && enabled) play('ui.hover') }}
        onClick={onListen}
      >
        {/* The listening state has to be UNMISTAKABLE -- a row waiting for a
            key that looks like a row not waiting for one swallows the next
            thing the player types. */}
        {listening ? 'Press…' : unbound ? (secondary ? '+' : 'Unbound') : label}
      </button>

      {/* Clearing is its own affordance rather than a modifier on the capture:
          "press nothing" is not a gesture, and a player who wants a key gone
          should not have to guess at one. */}
      <button
        type="button"
        data-plain
        className="text-[0.7rem] px-1"
        style={{
          color: unbound || !enabled ? 'transparent' : 'rgba(255,255,255,0.3)',
          pointerEvents: unbound || !enabled ? 'none' : 'auto',
        }}
        title="Clear this binding"
        onClick={() => { play('ui.back'); onClear() }}
      >
        &times;
      </button>
    </div>
  )
}
