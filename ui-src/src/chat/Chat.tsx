import { useEffect, useRef, useState } from 'react'
import { useUi, selChat, selChatOpen, selScreen, selSquad } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { ChatChannel, ChatMessage } from '../bridge/types'

/**
 * In-game chat.
 *
 * FOCUS DISCIPLINE -- the important part of this file.
 *
 * Chat is the single most likely place in the whole UI to leak NUI focus, because
 * it is the only in-match screen that takes keyboard input. A leak means the
 * player cannot move, cannot shoot, and cannot fix it without reconnecting.
 *
 * The rules followed here:
 *   1. Lua owns focus. The UI never calls anything that grants itself focus; it
 *      is told via the 'focus' envelope that chat is now focused.
 *   2. Every exit path -- send, Escape, blur, unmount, and an error while
 *      sending -- notifies Lua to release focus. There is no path that closes
 *      the input without telling Lua.
 *   3. The release notification is fire-and-forget and wrapped, so a failure to
 *      reach Lua still closes the local input rather than leaving it stuck open.
 *
 * When closed, chat is a passive read-only log with pointer-events off, so it
 * cannot intercept clicks.
 */

// ALL was on accent2, which is now VICTORY GOLD -- and gold means victory and
// nothing else, or it stops meaning anything when it appears. Global chat is
// not an event, so it takes plain white; squad keeps the squad green; system
// moves off storm magenta for the same reason gold had to move, and takes a
// neutral grey because a system line is chrome, not a threat.
const CHANNEL_STYLE: Record<ChatChannel, { label: string; colour: string }> = {
  global: { label: 'ALL',    colour: 'rgba(255,255,255,0.75)' },
  squad:  { label: 'SQUAD',  colour: 'var(--color-hp)' },
  system: { label: 'SYSTEM', colour: 'rgba(160,168,190,0.9)' },
}

const MAX_LENGTH = 200

/** How long the log stays up after the last message before fading away. */
const FADE_AFTER_MS = 12_000

/** Resting opacity of the log while closed. Readable over bright ground -- the
 *  chat sits over the world, and grass and sand are the worst case, not the
 *  dark menus it is easy to design against. */
const RESTING_OPACITY = 0.94

function Line({ msg }: { msg: ChatMessage }) {
  const style = CHANNEL_STYLE[msg.channel]
  return (
    // `tscale`: chat is the single most text-size-sensitive thing on screen
    // and the log grows downward into empty space, so enlarging it costs
    // nothing but the room it takes.
    <div className="tscale text-[0.875rem] leading-snug py-[1px] break-words">
      <span
        className="text-[0.625rem] font-bold uppercase tracking-wider mr-1.5 align-middle"
        style={{ color: style.colour }}
      >
        {style.label}
      </span>
      {msg.channel !== 'system' && (
        <span className="font-semibold text-white mr-1">{msg.name}:</span>
      )}
      <span className="text-white/90">{msg.text}</span>
    </div>
  )
}

export default function Chat({ barsVisible = true }: { barsVisible?: boolean }) {
  const messages = useUi(selChat)
  const open = useUi(selChatOpen)
  const channel = useUi((s) => s.chatChannel)
  const closeChat = useUi((s) => s.closeChat)
  const openChat = useUi((s) => s.openChat)
  const screen = useUi(selScreen)

  const [draft, setDraft] = useState('')
  const inputRef = useRef<HTMLInputElement>(null)
  const logRef = useRef<HTMLDivElement>(null)

  // Squad chat only exists when there is a squad (or party) to hear it --
  // solos get no toggle, no Tab switch, and never sit on the squad channel.
  const squad = useUi(selSquad)
  const canSquadChat = squad.members.length > 1
  useEffect(() => {
    if (open && channel === 'squad' && !canSquadChat) openChat('global')
  }, [open, channel, canSquadChat, openChat])

  /** The single exit path. Everything that closes chat goes through here. */
  const release = (send: boolean) => {
    const text = draft.trim()
    setDraft('')
    closeChat()

    // Local state is already closed before these fire, so even a total failure
    // to reach Lua cannot leave the input stuck open on screen.
    if (send && text.length > 0) {
      void fetchNui(CB.CHAT_SEND, { channel, text: text.slice(0, MAX_LENGTH) })
    }
    void fetchNui(CB.CHAT_FOCUS, { open: false })
  }

  // Focus the input when Lua opens chat. The rAF defers until after the element
  // is actually visible, otherwise .focus() lands on a hidden node and silently
  // does nothing.
  useEffect(() => {
    if (!open) return
    const raf = requestAnimationFrame(() => inputRef.current?.focus())
    return () => cancelAnimationFrame(raf)
  }, [open])

  // Unmount safety net. If this component ever goes away while focused -- a
  // hot reload, an error boundary above it -- focus must still be handed back.
  useEffect(() => {
    return () => { void fetchNui(CB.CHAT_FOCUS, { open: false }) }
  }, [])

  // Keep the log pinned to the newest message.
  useEffect(() => {
    const el = logRef.current
    if (el) el.scrollTop = el.scrollHeight
  }, [messages])

  // Fade the log out after a quiet spell, the way game chat is expected to
  // behave. Without this the last message sits on screen for the rest of the
  // match, permanently occupying a corner of the player's view.
  //
  // One timer, reset whenever a message arrives or chat opens -- not a ticking
  // interval. Nothing here should re-render on a clock.
  const [faded, setFaded] = useState(false)
  useEffect(() => {
    setFaded(false)
    if (open) return                    // never fade while typing
    const t = window.setTimeout(() => setFaded(true), FADE_AFTER_MS)
    return () => window.clearTimeout(t)
  }, [messages, open])

  const visible = messages.length > 0 || open
  const logOpacity = !visible ? 0 : open ? 1 : faded ? 0 : RESTING_OPACITY

  // WHERE THE CHAT SITS -- the ladder, per design:
  //   1. Minimap on screen: directly above it, left edges aligned. The
  //      minimap rect comes from the game (--map-* variables), so this
  //      follows the player's safe-zone slider.
  //   2. Minimap hidden but the vitals strip showing: just above the strip
  //      (which occupies the minimap's old lower edge).
  //   3. Both hidden: dropped to the strip's own line.
  // 0.3rem above the map: the same breathing room the vitals strip keeps
  // from the map's bottom edge, so the column reads as one unit.
  const radarOn = screen?.radarOn ?? true
  const bottom = radarOn
    ? 'calc(var(--map-bottom) + var(--map-h) + 0.3rem)'
    : barsVisible
      ? 'calc(var(--map-bottom) + 1.6rem)'
      : 'var(--map-bottom)'

  return (
    <div
      className="fixed w-[28.75rem] max-w-[38vw]"
      style={{
        left: 'var(--map-left)',
        bottom,
      }}
    >
      <div
        ref={logRef}
        className="thin-scroll overflow-y-auto max-h-40 px-3 pb-1"
        style={{
          opacity: logOpacity,
          // Slow when fading away so it is not distracting, quick when coming
          // back so a new message never feels delayed.
          transition: `opacity ${faded && !open ? 1200 : 150}ms ease`,
          maskImage: open ? undefined : 'linear-gradient(to bottom, transparent, black 28%)',
          // Text sits over the world, including bright grass and sand. A soft
          // shadow keeps it readable without needing an opaque panel behind it.
          textShadow: '0 1px 3px rgba(0, 0, 0, 0.9), 0 0 8px rgba(0, 0, 0, 0.6)',
        }}
      >
        {messages.map((m, i) => (
          <Line key={`${m.at}-${m.from}-${i}`} msg={m} />
        ))}
      </div>

      {open && (
        // `interactive` re-enables pointer events; the root is click-through.
        <div className="interactive panel mt-1 px-3 py-2 flex items-center gap-2 rise">
          <button
            type="button"
            // preventDefault on mousedown stops the button taking focus from the
            // input. Without it the input blurs, onBlur closes chat, and the
            // button is effectively unusable -- clicking it dismisses the very
            // thing it is meant to change. A synthetic .click() does not
            // reproduce this; only a real mouse press does.
            onMouseDown={(e) => e.preventDefault()}
            onClick={() => canSquadChat
              && openChat(channel === 'global' ? 'squad' : 'global')}
            className="btn plate text-[0.6rem] font-semibold uppercase tracking-[0.14em]
                       px-2 py-1 shrink-0"
            style={{
              color: CHANNEL_STYLE[channel].colour,
              ['--edgec' as string]: 'rgba(255,255,255,0.22)',
              ['--plate-fill' as string]: 'rgba(24,28,40,0.92)',
              ['--cut-max' as string]: '0.35rem',
            }}
            title={canSquadChat ? 'Switch channel (Tab)' : undefined}
          >
            {CHANNEL_STYLE[channel].label}
          </button>

          <input
            ref={inputRef}
            value={draft}
            maxLength={MAX_LENGTH}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={(e) => {
              // Stop keystrokes reaching the game underneath.
              e.stopPropagation()
              if (e.key === 'Enter') { e.preventDefault(); release(true) }
              else if (e.key === 'Escape') { e.preventDefault(); release(false) }
              else if (e.key === 'Tab') {
                e.preventDefault()
                if (canSquadChat) openChat(channel === 'global' ? 'squad' : 'global')
              }
            }}
            // Losing focus without closing would leave the player holding NUI
            // focus with no visible input -- unable to move, with no cause on
            // screen. But a blur to something INSIDE the chat widget (the
            // channel button) is not the user leaving, so it must not close.
            onBlur={(e) => {
              const next = e.relatedTarget as Node | null
              if (next && e.currentTarget.parentElement?.contains(next)) return
              if (open) release(false)
            }}
            placeholder={channel === 'squad' ? 'Message your squad…' : 'Message everyone…'}
            className="flex-1 bg-transparent outline-none text-sm placeholder:text-white/30"
          />

          <span className="text-[0.625rem] tabular-nums text-white/30 shrink-0">
            {draft.length}/{MAX_LENGTH}
          </span>
        </div>
      )}
    </div>
  )
}
