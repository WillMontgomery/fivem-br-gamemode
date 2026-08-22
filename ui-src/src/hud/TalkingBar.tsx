import { useUi } from '../store'
import VoiceMark from './VoiceMark'

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
 * THE LABEL IS BOLD AND THE NAMES ARE NOT. Owner, from the playtest: "can you
 * make it display such that 'Currently talking:' is bold, but the player's
 * names are not?" One line carrying two different things -- a fixed label the
 * eye learns to skip and a list that changes every few seconds -- should not be
 * set in one weight, or the reader parses the whole string every time somebody
 * new starts speaking. 700 and 400 are BOTH REAL LOADED WEIGHTS (main.tsx
 * imports Barlow 400/500/600/700), so neither is synthesised by the browser --
 * a faux-bold at this size over a moving world is exactly the sort of mush that
 * reads as "the font is wrong".
 *
 * ...WHICH IS THE OTHER HALF OF THE SAME REPORT: "it doesn't seem that our font
 * is right. Could just be me."
 *
 * THE FAMILY WAS NEVER WRONG -- measured in the harness, this line resolves to
 * Barlow, the same face as the squad panel and the kill feed. What was wrong is
 * that it was wearing `.body-text`, which is the PAUSE-MENU PROSE style (its
 * own note in index.css lists what it is for: "help text, descriptions, empty
 * states, confirmation bodies, the bulleted lists in Settings"). That class
 * brings three things this surface must not have:
 *
 *   ONE WEIGHT FOR EVERYTHING (600), which is why the label could not be bolder
 *   than the names -- the thing actually being asked for here.
 *
 *   --color-text-body, 70% white. Correct on an opaque settings plate; on the
 *   HUD it is the caption shade being used for the content, and every other
 *   piece of HUD text the player is meant to READ is plain white.
 *
 *   NO TEXT SHADOW. This is the only string in the entire HUD drawn over the
 *   bare game world -- the counters, the kill feed, the squad plates and the
 *   inventory all sit on a `.panel` or a `.plate`, and this sits on Los Santos.
 *   `--shadow-text` exists for exactly that case ("the desert at noon is the
 *   failing case and it is not rare"), and this line was the one place that
 *   needed it and did not have it. Thin grey letters over a bright sky do not
 *   look like the wrong colour to the person reading them; they look like the
 *   wrong font.
 *
 * SO THE SIZE IS THE ONE THING HELD STILL. `.ts` with an explicit `--fs` of
 * 1rem reproduces exactly what `.body-text` was computing here (measured: 1.000
 * rem at every root size), and keeps the player's text-size preference working
 * -- `.ts` is the documented way to scale text that declares its own size,
 * because bare `.tscale` multiplies 1em, the PARENT's size, and would silently
 * throw the 1rem away. Do not add `tscale` alongside it (#159).
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
      {/* THE SAME MARK THE SQUAD PANEL PUTS BESIDE A SPEAKING MATE, from the
          same component. Voice has one visual vocabulary and this is it; a
          second, different marker for the same fact would read as a second
          fact.

          THAT RULE IS WHY THIS LINE CHANGED AT ALL. The panel's mark became a
          glyph so it could have a second state to be distinguishable FROM
          (owner, 2026-08-22 -- see VoiceMark). Leaving the accent dot here
          would have been precisely the divergence this comment has always
          warned about, so both moved together and there is one definition.

          Sized off --talkline-fs, the same variable the text beside it reads,
          so the mark and the line grow together and --talkline-h -- which the
          spectate hint clears -- still describes this row. */}
      <VoiceMark fs="var(--talkline-fs)" talking />
      {/* min-w-0 with the truncate: a flex item defaults to `min-width: auto`,
          which refuses to shrink below its content -- so the line grew straight
          through the 46% cap the moment enough people spoke at once, and the
          ellipsis this asks for never appeared. */}
      <span
        className="ts truncate min-w-0"
        style={{
          // 1rem, VIA A VARIABLE, because the spectate hint stacks directly on
          // top of this line and has to know how tall it is to clear it. The
          // number is declared once in index.css (--talkline-fs) and the height
          // derived from it there; a literal here would drift out of agreement
          // with that clearance silently, and the overlap would only appear
          // while somebody was speaking.
          ['--fs' as string]: 'var(--talkline-fs)',
          lineHeight: 1.5,
          textShadow: 'var(--shadow-text)',
        }}
      >
        <span style={{ fontWeight: 700 }}>Currently Talking:</span>{' '}
        <span style={{ fontWeight: 400 }}>{names.join(', ')}</span>
      </span>
    </div>
  )
}
