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
 * PRESS-A-KEY CAPTURE, not a dropdown of key names. A dropdown asks the player
 * to know what their keyboard calls a key; capture asks them to press it.
 * The row goes into a listening state, the next keydown wins, and Escape
 * cancels -- which is why Escape can never itself be bound.
 *
 * LUA IS THE AUTHORITY, as everywhere else: this sends a command and a key and
 * renders whatever comes back. So a conflict resolving in favour of the new
 * binding (the loser is left unbound, which is what every game does) shows up
 * as the other row emptying, without this component having to model it.
 */

const CANNOT_BIND = new Set([
  // Escape cancels the capture, so binding it would make the capture
  // unexitable. It is also GTA's own pause key.
  'Escape',
  // The chat input and the settings screen both need these to be typing keys.
  'Enter', 'Tab',
])

/** Browser key name -> what FiveM's `bind` command expects. */
function toFiveMKey(e: KeyboardEvent): string | null {
  const k = e.key
  if (CANNOT_BIND.has(k)) return null

  // Letters and digits are themselves, uppercased.
  if (/^[a-zA-Z0-9]$/.test(k)) return k.toUpperCase()
  // F1..F12 come through as-is.
  if (/^F([1-9]|1[0-2])$/.test(k)) return k.toUpperCase()

  const NAMED: Record<string, string> = {
    ' ': 'SPACE',
    ArrowUp: 'UP', ArrowDown: 'DOWN', ArrowLeft: 'LEFT', ArrowRight: 'RIGHT',
    Control: 'LCONTROL', Shift: 'LSHIFT', Alt: 'LMENU',
    Backspace: 'BACK', Delete: 'DELETE', Insert: 'INSERT',
    Home: 'HOME', End: 'END', PageUp: 'PRIOR', PageDown: 'NEXT',
    '-': 'MINUS', '=': 'EQUALS', '[': 'LBRACKET', ']': 'RBRACKET',
    ';': 'SEMICOLON', "'": 'APOSTROPHE', ',': 'COMMA', '.': 'PERIOD',
    '/': 'SLASH', '\\': 'BACKSLASH', '`': 'GRAVE',
  }
  return NAMED[k] ?? null
}

export default function Keybinds() {
  const actions = useUi((s) => s.keybinds)
  const [listening, setListening] = useState<string | null>(null)
  const [rejected, setRejected] = useState<string | null>(null)

  useEffect(() => {
    if (!listening) return

    const onKey = (e: KeyboardEvent) => {
      // Capture phase and stopped hard: while a row is listening, the key
      // belongs to the row. Without this, pressing Escape to cancel would
      // also reach the settings screen's own Escape handler and close it.
      e.preventDefault()
      e.stopPropagation()

      if (e.key === 'Escape') { play('ui.back'); setListening(null); return }

      const key = toFiveMKey(e)
      if (!key) {
        play('ui.error')
        setRejected(e.key)
        window.setTimeout(() => setRejected(null), 1600)
        return
      }

      play('ui.ready')
      void fetchNui(CB.KEYBIND_SET, { command: listening, key })
      setListening(null)
    }

    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [listening])

  if (actions.length === 0) {
    return <p className="micro-label">Loading controls…</p>
  }

  // Grouped, because thirteen undifferentiated rows is a list nobody reads.
  const groups: string[] = []
  for (const a of actions) if (!groups.includes(a.group)) groups.push(a.group)

  return (
    <div className="flex flex-col gap-4">
      {groups.map((g) => (
        <div key={g}>
          <div className="micro-label mb-1.5">{g}</div>
          <div className="flex flex-col gap-1">
            {actions.filter((a) => a.group === g).map((a) => (
              <Row
                key={a.command}
                action={a}
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

      {/* THE ESCAPE HATCH, kept deliberately. Rebinding here goes through
          FiveM's `bind` console command, which is a real documented API but
          one this project has not yet proven on a live client -- and if it
          ever fails, a player with no working keys needs somewhere to go that
          does not depend on the thing that broke. GTA's own list always
          works. Small and last, because it is insurance, not the feature. */}
      <button
        type="button"
        data-plain
        className="micro-label text-left underline decoration-white/20 underline-offset-2"
        onClick={() => { play('ui.select'); void fetchNui(CB.KEYBINDS, {}) }}
      >
        Open GTA&apos;s own key bindings
      </button>
    </div>
  )
}

function Row({
  action, listening, onListen,
}: {
  action: KeybindAction
  listening: boolean
  onListen: () => void
}) {
  const unbound = !action.key
  return (
    <div className="flex items-center gap-3">
      <span className="text-[0.82rem] text-white/70 tscale flex-1 min-w-0 truncate">
        {action.label}
      </span>

      <button
        type="button"
        className={`btn plate px-3 py-1 font-display text-[0.78rem] tracking-[0.1em]
                    text-center${listening ? ' is-active' : ''}`}
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
        onPointerEnter={() => { if (!listening) play('ui.hover') }}
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
        style={{ color: unbound ? 'transparent' : 'rgba(255,255,255,0.3)' }}
        disabled={unbound}
        title="Clear this binding"
        onClick={() => {
          play('ui.back')
          void fetchNui(CB.KEYBIND_SET, { command: action.command, key: '' })
        }}
      >
        &times;
      </button>
    </div>
  )
}
