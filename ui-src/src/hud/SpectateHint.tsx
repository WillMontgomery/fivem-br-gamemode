import { useUi } from '../store'

/**
 * WHO YOU ARE WATCHING, AND WHICH KEYS MOVE YOU ON.
 *
 * Owner, from the playtest: "There's no pointers to tell me what buttons to
 * press for next/last spectate target. That should be shown at the bottom
 * center (not overlapping with our 'Currently talking' text and scaling
 * properly with our player's preferences) and look like a button but not have a
 * mouse required. Also some text that says 'SPECTATING X' would be helpful
 * above those buttons."
 *
 * Every clause of that is a constraint and each is answered below.
 *
 * ═══ BOTTOM CENTRE, ABOVE THE TALKING LINE, WITHOUT MOVING ═══
 *
 * Bottom centre already belongs to `TalkingBar`, which sits ON the bottom safe
 * edge. This stacks above it, clearing exactly one talking line -- `--talkline-h`
 * in index.css, derived from the same font size that component reads, so the
 * two cannot drift into an overlap.
 *
 * THE CLEARANCE IS UNCONDITIONAL, and that is deliberate rather than lazy.
 * `TalkingBar` renders NOTHING when nobody is speaking, so a clearance that
 * collapsed when the line was absent would drop this block a line every time
 * the room went quiet and lift it every time somebody spoke -- a hint that
 * moves while you are reading it, which is the exact failure TalkingBar's own
 * note argues against ("moves the thing you are reading while you are reading
 * it"). A fixed anchor with a gap under it is the cheaper mistake.
 *
 * ═══ IT LOOKS LIKE A BUTTON AND IS NOT ONE ═══
 *
 * `.plate` is the same hardware treatment the Keybinds screen puts its capture
 * buttons in, so a key drawn here reads as the same object the player rebinds
 * there. What it is NOT is a real button element: no element here is focusable,
 * nothing has a click handler, `pointer-events` is off for the whole block and
 * there is no hover state. "not have a mouse required" is the requirement, and a
 * spectating player has no cursor at all -- this is not a screen on the focus
 * stack (see client/spectate.lua on why it must never join one), so a control
 * that needed pointing at could not be reached.
 *
 * ═══ THE KEYS ARE THE REAL BINDINGS ═══
 *
 * Read out of `keybinds`, the same rows the rebinder screen draws, matched by
 * COMMAND NAME rather than by position. Lua pushes that list at start and again
 * on every rebind, so moving Spectate next off the right arrow updates this
 * hint with no further plumbing. Nothing here hardcodes an arrow -- the arrows
 * are rebindable, and a hint naming a key the player no longer has is worse
 * than no hint.
 *
 * AN UNBOUND ACTION IS DRAWN AS A DASH rather than hidden. `key` is '' when
 * nothing is bound, which is a state a player can reach by rebinding something
 * else onto the arrow (keybinds.lua resolves conflicts in favour of the new
 * binding and leaves the loser unbound). Hiding the row would make the feature
 * look absent; a dash says the key is gone, which is the truth and is
 * recoverable from the Controls screen.
 *
 * ═══ SCALING ═══
 *
 * `.ts` with an explicit `--fs`, never bare `.tscale` -- these elements declare
 * their own size, and `.tscale` multiplies 1em, the PARENT's size, which throws
 * the declared value away. That is #159, and this file is deliberately not the
 * fourteenth entry on it.
 */

/** The two rows this draws, in the order they are pressed. */
const KEYS = [
  { command: 'brspecprev', label: 'Previous' },
  { command: 'brspecnext', label: 'Next' },
] as const

export default function SpectateHint() {
  const spectate = useUi((s) => s.spectate)
  const keybinds = useUi((s) => s.keybinds)

  // Nothing at all when no session is running. Not an empty plate: the bottom
  // of the screen is shared with the talking line and the inventory bar, and
  // reserving space for a hint that does not apply is chrome for its own sake.
  if (!spectate?.active) return null

  const keyFor = (command: string) =>
    keybinds.find((k) => k.command === command)?.key || ''

  return (
    <div
      className="flex flex-col items-center gap-1 pointer-events-none"
      // NOT POSITIONED HERE. Hud.tsx owns the bottom-centre column this sits
      // in, and that column is what holds the clearance over the talking line.
      // See the note above on why the clearance is unconditional.
      aria-hidden
    >
      {/* THE OWNER'S STRING, VERBATIM AND UPPER CASE: "SPECTATING X". The name
          is the server's -- this client is told one target at a time and never
          a candidate list -- and it truncates rather than pushing the row wide
          enough to reach the inventory bar. */}
      <span
        className="ts font-display tracking-[0.14em] truncate max-w-[46vw]"
        style={{
          ['--fs' as string]: '0.95rem',
          lineHeight: 1.4,
          color: 'var(--color-royale-accent)',
          textShadow: 'var(--shadow-text)',
        }}
      >
        SPECTATING {(spectate.name ?? '').toUpperCase()}
      </span>

      <div className="flex items-center gap-3">
        {KEYS.map(({ command, label }) => {
          const key = keyFor(command)
          return (
            <span key={command} className="flex items-center gap-1.5">
              {/* The cap. `.plate` and `font-display` are what the Keybinds
                  screen uses for the same object, so the player is looking at
                  the thing they would go and change. */}
              <span
                className="plate ts font-display text-center"
                style={{
                  ['--fs' as string]: '0.8rem',
                  ['--edgec' as string]: key
                    ? 'rgba(255,255,255,0.22)'
                    : 'rgba(255,255,255,0.12)',
                  ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
                  ['--cut-max' as string]: '0.3rem',
                  color: key ? '#ffffff' : 'rgba(255,255,255,0.3)',
                  minWidth: '2.6rem',
                  padding: '0.15rem 0.5rem',
                  lineHeight: 1.4,
                }}
              >
                {key || '--'}
              </span>
              <span
                className="ts"
                style={{
                  ['--fs' as string]: '0.85rem',
                  lineHeight: 1.4,
                  color: 'rgba(255,255,255,0.78)',
                  textShadow: 'var(--shadow-text)',
                }}
              >
                {label}
              </span>
            </span>
          )
        })}
      </div>
    </div>
  )
}
