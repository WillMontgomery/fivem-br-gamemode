import { useUi, selNotices, selScreen } from '../store'
import type { ToastPayload } from '../bridge/types'
import NoticeRow from './NoticeRow'

/**
 * The notification stack.
 *
 * One place for everything that happens TO the player: party events, action
 * results, match alerts. Rendered over BOTH the lobby and the HUD, because the
 * events it carries do not care which screen is up.
 *
 * WHERE IT SITS -- the ladder, per design:
 *   1. Minimap on screen: tucked against its bottom-right corner, growing
 *      upward. The rect comes from the game (--map-* variables).
 *   2. Minimap hidden but the vitals strip showing: above the strip, aligned
 *      to the minimap's left edge.
 *   3. Both hidden: on the strip's own line.
 *
 * Each notice FLIES IN from the left and FADES OUT at the end of its own
 * lifetime -- the animation length is driven by the same `ms` the store uses
 * to remove it, so nothing ever blinks out mid-fade.
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


export default function Notices({ barsVisible = true }: { barsVisible?: boolean }) {
  const notices = useUi(selNotices)
  const screen = useUi(selScreen)
  if (notices.length === 0) return null

  const radarOn = screen?.radarOn ?? true

  const pos = radarOn
    ? {
        left: 'calc(var(--map-left) + var(--map-w) + 0.6rem)',
        bottom: 'var(--map-bottom)',
      }
    : {
        left: 'var(--map-left)',
        bottom: barsVisible
          ? 'calc(var(--map-bottom) + 1.6rem)'
          : 'var(--map-bottom)',
      }

  return (
    <div
      className="fixed flex flex-col-reverse items-start gap-1.5"
      style={{ ...pos, pointerEvents: 'none', zIndex: 40 }}
    >
      {[...notices].reverse().map((n) => (
        <NoticeRow key={n.id} tone={TONE_COLOUR[n.tone ?? 'info']} lifeMs={n.ms}>
          <span>{n.text}</span>
          {/* COALESCED REPEATS. Four ammo pickups is one line reading x4, not
              four lines shoving each other off the stack. */}
          {n.count > 1 && (
            <span
              key={n.count}
              className="font-display text-[0.85rem] leading-none"
              style={{
                color: TONE_COLOUR[n.tone ?? 'info'],
                animation: 'punch 320ms var(--ease-out) both',
              }}
            >
              &times;{n.count}
            </span>
          )}
        </NoticeRow>
      ))}
    </div>
  )
}
