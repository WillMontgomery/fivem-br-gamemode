import { useUi } from '../store'

/**
 * WHO IS SPEAKING, along the bottom of the screen.
 *
 * Owner, 2026-08-16: "the 'currently talking' text appears at the top - can we
 * change that to be at the bottom center and our fonts/colors? Also instead of
 * wrapping text vertically (each player who speaks has their name on a
 * different line) we should extend the line horizontally to say 'Currently
 * Talking: Celdwist, Xeon, Cyan, Rypters'".
 *
 * ONE LINE, NOT A LIST. A name per row makes the block grow upward as more
 * people speak, which moves the thing you are reading while you are reading
 * it. Comma-separated on a single line grows sideways from a fixed baseline,
 * so the first name stays where the eye left it.
 *
 * BOTTOM CENTRE IS THE LAST FREE EDGE of the HUD: the radar owns bottom left,
 * the inventory bar bottom right, and the storm and warmup clocks share top
 * centre. It is also where a player is already looking during a fight.
 *
 * `.body-text` IS PROSE AND CARRIES ITS OWN SCALING (#148). It must NOT also
 * take `.tscale`/`.ts` -- the class already multiplies by --text-scale, and
 * both together would apply the player's size preference twice.
 */
export default function TalkingBar() {
  const names = useUi((s) => s.talkingNames)

  // Nothing to say when nobody is speaking, and the empty case is the common
  // one -- so this renders nothing at all rather than an empty plate that
  // would occupy the bottom of the screen for the whole match.
  if (names.length === 0) return null

  return (
    <div
      className="absolute left-1/2 -translate-x-1/2 flex items-center gap-2
                 max-w-[46%] pointer-events-none"
      style={{ bottom: 'var(--safe-y)' }}
    >
      {/* The same accent dot the squad panel puts beside a speaking mate, on
          the same slow pulse. Voice has one visual vocabulary and this is it;
          a second, different marker for the same fact would read as a second
          fact. */}
      <span
        className="shrink-0 rounded-full mate-talk"
        style={{
          width: '0.34rem',
          height: '0.34rem',
          background: 'var(--color-royale-accent)',
        }}
      />
      <span className="body-text truncate">
        Currently Talking: {names.join(', ')}
      </span>
    </div>
  )
}
