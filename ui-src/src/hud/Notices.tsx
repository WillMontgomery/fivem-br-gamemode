import { useUi, selNotices } from '../store'
import type { ToastPayload } from '../bridge/types'

/**
 * The notification stack.
 *
 * One place for everything that happens TO the player: party events, action
 * results, match alerts. Before this there was a single toast slot buried in
 * the party panel -- so a notice arriving during a match had nowhere to render,
 * and two notices in quick succession showed only the second.
 *
 * Rendered over BOTH the lobby and the HUD, because the events it carries do
 * not care which screen is up: "Kestrel declined your invite" can land while
 * you are already dropping.
 *
 * pointer-events: none -- notices are never interactive, so they must never
 * steal a click from the game or the lobby beneath them.
 */

const TONE_COLOUR: Record<NonNullable<ToastPayload['tone']>, string> = {
  info:    'rgba(255, 255, 255, 0.45)',
  success: 'var(--color-hp)',
  warn:    '#FFB020',
  danger:  'var(--color-danger)',
}

export default function Notices() {
  const notices = useUi(selNotices)
  if (notices.length === 0) return null

  return (
    <div
      className="fixed left-1/2 -translate-x-1/2 flex flex-col items-center gap-1.5"
      style={{ bottom: '18%', pointerEvents: 'none', zIndex: 40 }}
    >
      {notices.map((n) => (
        <div
          key={n.id}
          className="rise panel px-3.5 py-1.5 text-[0.8125rem] text-white/85"
          style={{ borderLeft: `2px solid ${TONE_COLOUR[n.tone ?? 'info']}` }}
        >
          {n.text}
        </div>
      ))}
    </div>
  )
}
