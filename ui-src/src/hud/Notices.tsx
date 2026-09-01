import { useUi, selNotices, selScreen } from '../store'
import type { NoticePart, ToastPayload } from '../bridge/types'
import NoticeRow from './NoticeRow'
import { KeyText } from '../ui/KeyCap'

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

/** Exported because the pause menu's history draws the same rows: one tone
 *  table, so a line cannot mean one thing live and another in the log. */
export const TONE_COLOUR: Record<NonNullable<ToastPayload['tone']>, string> = {
  info:    'rgba(255, 255, 255, 0.45)',
  success: 'var(--color-hp)',
  warn:    '#FFB020',
  danger:  'var(--color-danger)',
}

/**
 * A NOTICE'S SENTENCE, WITH ANY PLAYER IT NAMES IN BOLD.
 *
 * Owner, 2026-08-31: "Any time we mention a player by name in a toast their name
 * should be bold." That is EVERY toast that names somebody, not only the new
 * ones -- so this is the single component both surfaces that draw a notice go
 * through, and adding a name to a sentence anywhere in Lua makes it bold here
 * with nothing else to remember.
 *
 * ═══ A NAME IS A REACT TEXT CHILD, AND THAT IS THE SECURITY PROPERTY ═══
 *
 * `{p.b}` is rendered as a text node. React escapes it, no markup is parsed, and
 * -- this is the part that is easy to lose -- it does NOT go through KeyText. A
 * player who calls themselves `{key:brptt}` gets those nine characters drawn,
 * not a key cap. The prose halves still go through KeyText, because the `{key:}`
 * token belongs to sentences we wrote and several of them have one.
 *
 * See NoticePart in bridge/types.ts for why the split happens in Lua rather than
 * this component parsing a marked-up string. The short version: the name is the
 * one part of a notice a player writes, so it must never be inside a grammar.
 *
 * NO PARTS IS THE COMMON CASE and costs nothing -- the flat `text` through
 * KeyText, which is exactly what every notice did before this existed.
 *
 * `.notice-name` CARRIES THE WEIGHT, NOT AN INLINE STYLE. index.css has the
 * argument for 700 over 600 and for inheriting size and colour; it is a
 * design-system fact rather than this component's opinion, and it is also what
 * tools/check_notice_names.lua grips to prove the shipped bundle is the one
 * built from this file.
 */
export function NoticeText({ text, parts, fs }: {
  text: string
  parts?: NoticePart[]
  fs?: string
}) {
  if (!parts || parts.length === 0) return <KeyText text={text} fs={fs} />
  return (
    <>
      {parts.map((p, i) => ('b' in p
        // Keyed on the index because a part has no identity of its own and the
        // list is rebuilt whole on every push -- there is no reordering for a
        // stable key to protect.
        ? <b key={i} className="notice-name">{p.b}</b>
        : <KeyText key={i} text={p.t} fs={fs} />))}
    </>
  )
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
      style={{
        ...pos,
        pointerEvents: 'none',
        zIndex: 40,
        // A CEILING, SO THE TEXT CAN WRAP. The stack had no width at all, so
        // every notice was one line however long it was -- a long one ran off
        // toward the middle of the screen and, anchored right of the radar,
        // straight out of it (user, 2026-08-09).
        //
        // 22rem is about forty characters at this size: wide enough that
        // ordinary notices stay on one line, narrow enough that the stack
        // never becomes a column of prose over the game.
        maxWidth: '22rem',
      }}
    >
      {[...notices].reverse().map((n) => (
        <NoticeRow
          // n.id, NOT n.key. A keyed notice updating in place must keep the
          // SAME React element or the row unmounts and flies in again -- which
          // is exactly the stutter a countdown must not have. The store already
          // guarantees one id per key.
          key={n.id}
          tone={TONE_COLOUR[n.tone ?? 'info']}
          lifeMs={n.ms}
          endsAt={n.endsAt}
          sticky={n.sticky}
        >
          {/* min-w-0 so the flex child may actually shrink, break-words so a
              long unbroken token cannot force the row wider than the stack.

              NoticeText, NOT the raw string. It is KeyText plus the owner's
              bold-name rule: a notice whose sentence names a KEY -- the
              once-a-session voice notice, the sticky one over the big map --
              carries a `{key:command}` hole and gets a plate; one that names a
              PLAYER arrives pre-split and gets that name in 700. A notice with
              neither is returned untouched and renders exactly as it did. */}
          <span className="min-w-0 break-words">
            {/* ABOVE THE ROW'S OWN PROSE (0.8125rem), not below it. It was
                0.75rem, so the key was drawn smaller than the sentence naming
                it -- 8.25px of Anton at 1280x720. The cap is a control, and a
                control set smaller than the words around it reads as a
                footnote. Costs 1.4-2.6px of line height, measured. */}
            <NoticeText text={n.text} parts={n.parts} fs="0.95rem" />
          </span>
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
