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
 * reads the key itself with IS_RAW_KEY_JUST_PRESSED, which takes a Windows VK
 * code. `event.keyCode` IS that code in Chrome, which is the one thing the
 * deprecated property is still good for and exactly why it is used here.
 *
 * PRESS-A-KEY CAPTURE, not a dropdown of key names. A dropdown asks the player
 * to know what their keyboard calls a key; capture asks them to press it. The
 * row goes into a listening state, the next keydown wins, and Escape cancels
 * -- which is why Escape can never itself be bound.
 *
 * LUA IS THE AUTHORITY: this sends a command and a code and renders whatever
 * comes back. So a conflict resolving in favour of the new binding (the loser
 * is left unbound, which is what every game does) shows up as the other row
 * emptying, without this component modelling it.
 */

/** Codes this screen refuses to hand over, and why. */
const RESERVED: Record<number, string> = {
  0x1B: 'Escape',   // cancels the capture, and opens GTA's own menu
  0x0D: 'Enter',    // the chat input needs it
  0x74: 'F7',       // FiveM's own console toggle on some builds
  0x78: 'F8',       // the console. Taking it would be unrecoverable.
}

export default function Keybinds() {
  const actions = useUi((s) => s.keybinds)
  const rawActive = useUi((s) => s.keybindsRaw)
  const [listening, setListening] = useState<string | null>(null)
  const [rejected, setRejected] = useState<string | null>(null)

  useEffect(() => {
    if (!listening) return

    const onKey = (e: KeyboardEvent) => {
      // Capture phase and stopped hard: while a row is listening, the key
      // belongs to the row. Without this, Escape would also reach the
      // settings screen's own handler and close it.
      e.preventDefault()
      e.stopPropagation()

      const code = e.keyCode
      if (code === 0x1B) { play('ui.back'); setListening(null); return }

      if (RESERVED[code]) {
        play('ui.error')
        setRejected(RESERVED[code]!)
        window.setTimeout(() => setRejected(null), 1800)
        return
      }

      play('ui.ready')
      void fetchNui(CB.KEYBIND_SET, { command: listening, vk: code })
      setListening(null)
    }

    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
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
          (user, 2026-08-09). 30rem puts them within one eye movement, and the
          rows alternate so the eye can hold a line. */}
      {groups.map((g) => (
        <div key={g} style={{ width: '30rem', maxWidth: '100%' }}>
          <div className="micro-label mb-1.5">{g}</div>
          <div className="flex flex-col">
            {actions.filter((a) => a.group === g).map((a, i) => (
              <Row
                key={a.command}
                action={a}
                zebra={i % 2 === 1}
                enabled={rawActive}
                listening={listening === a.command}
                onListen={() => { play('ui.select'); setListening(a.command) }}
              />
            ))}
          </div>
        </div>
      ))}

      <p className="micro-label">
        {listening
          ? 'Press a key — Escape cancels.'
          : rejected
            ? `${rejected} is reserved and cannot be bound.`
            : 'Click a key to rebind it. Taking a key clears whatever held it.'}
      </p>
    </div>
  )
}

function Row({
  action, listening, enabled, zebra, onListen,
}: {
  action: KeybindAction
  listening: boolean
  enabled: boolean
  /** Alternate row shading, so a long list can be read across. */
  zebra: boolean
  onListen: () => void
}) {
  const unbound = !action.key
  return (
    <div
      className="flex items-center gap-3 px-2 py-1 rounded-sm"
      style={{ background: zebra ? 'rgba(255,255,255,0.035)' : 'transparent' }}
    >
      <span className="text-[0.82rem] text-white/70 tscale flex-1 min-w-0 truncate">
        {action.label}
      </span>

      <button
        type="button"
        disabled={!enabled}
        className={`btn plate px-3 py-1 font-display text-[0.78rem] tracking-[0.1em]
                    text-center${listening ? ' is-active' : ''}${
                      enabled ? '' : ' btn--off'}`}
        style={{
          minWidth: '6rem',
          ['--edgec' as string]: listening
            ? 'var(--color-royale-accent)'
            : unbound ? 'rgba(255,255,255,0.12)' : 'rgba(255,255,255,0.22)',
          ['--plate-fill' as string]: listening
            ? 'rgba(12,58,72,0.94)' : 'rgba(30,34,48,0.94)',
          ['--cut-max' as string]: '0.3rem',
          color: listening
            ? 'var(--color-royale-accent)'
            : unbound ? 'rgba(255,255,255,0.3)' : '#ffffff',
        }}
        onPointerEnter={() => { if (!listening && enabled) play('ui.hover') }}
        onClick={onListen}
      >
        {/* The listening state has to be UNMISTAKABLE -- a row waiting for a
            key that looks like a row not waiting for one swallows the next
            thing the player types. */}
        {listening ? 'Press…' : unbound ? 'Unbound' : action.key}
      </button>

      {/* Clearing is its own affordance rather than a modifier on the capture:
          "press nothing" is not a gesture, and a player who wants a key gone
          should not have to guess at one. */}
      <button
        type="button"
        data-plain
        className="text-[0.7rem] px-1"
        style={{ color: unbound || !enabled ? 'transparent' : 'rgba(255,255,255,0.3)' }}
        disabled={unbound || !enabled}
        title="Clear this binding"
        onClick={() => {
          play('ui.back')
          void fetchNui(CB.KEYBIND_SET, { command: action.command, vk: 0 })
        }}
      >
        &times;
      </button>
    </div>
  )
}
