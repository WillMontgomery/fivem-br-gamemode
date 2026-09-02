import { useUi } from '../store'
import { verdictWord } from './verdictWord'

/**
 * YOUR OWN DEATH, AS A WORD OVER THE LIVING WORLD.
 *
 * "Upon dying, the verdict text ONLY should be shown for ~10 seconds then the
 * text can immediately disappear as we snap into spectating. Our typical
 * verdict screen should remain once the match is over." -- the owner.
 *
 * ═══ THE TEXT ONLY -- WHICH IS THE ENTIRE DIFFERENCE FROM EndScreen ═══
 *
 * `EndScreen` is a SCREEN: it fades a backdrop to solid black, reports that
 * blackness to Lua so the world can be torn down behind it, and then flies in a
 * placement, an eliminations count and a Volts line. Every one of those is
 * wrong for a death mid-match -- the world is not being torn down, the player
 * has no placement yet, the match is still running, and in ten seconds they
 * will be watching a squadmate through it.
 *
 * So this draws the word and NOTHING ELSE. No backdrop, no cover report, no
 * supporting lines, and nothing that could still be on screen when the
 * spectator camera arrives.
 *
 * ═══ ONE WORD TABLE, TWO SURFACES ═══
 *
 * `verdictWord` is shared with EndScreen. A player told BLED OUT when they die
 * and ELIMINATED when the match ends has been given two accounts of one death,
 * and a second copy of that switch is exactly how that happens.
 *
 * THE WORD CAN CHANGE WHILE IT IS UP, and that is by design rather than a
 * glitch: the roster delta that makes a player DEAD and the kill-feed message
 * carrying the cause are separate wires with no ordering between them, so Lua
 * puts the word up with whatever it knows and re-sends if the cause lands
 * inside the window. WASTED becoming ELIMINATED is a correction; waiting for
 * both messages would risk a death with no word at all, which is the bug being
 * fixed.
 *
 * ═══ LUA OWNS THE CLOCK ═══
 *
 * There is no timer in this component. `show` goes true on the death and false
 * when BR.Config.Spectate.deathVerdictMs is up -- and the SAME deadline is what
 * holds client/spectate.lua's first request for a target. A countdown here
 * would be a second clock that agreed with that one only by coincidence, and
 * the two drifting apart is either dead air or a camera that cuts away
 * mid-sentence.
 *
 * ═══ IT IS NOT ON THE FOCUS STACK AND TAKES NO INPUT ═══
 *
 * Spectating deliberately never joins the focus stack (client/spectate.lua
 * argues why), and this is drawn over a live match a player is no longer in.
 * pointer-events off, aria-hidden, nothing focusable.
 */
export default function DeathVerdict() {
  const death = useUi((s) => s.death)

  // Nothing at all outside the window. Not an empty container: this sits over
  // the middle of the screen, and a zero-height element there is one more thing
  // between the player and the match they are watching.
  if (!death?.show) return null

  const word = verdictWord(death.cause, death.byPlayer)

  return (
    <div
      className="absolute inset-0 flex items-center justify-center
                 pointer-events-none"
      aria-hidden
    >
      {/* THE SAME SLAM ANIMATION THE VERDICT SCREEN USES, because it is the
          same word arriving with the same force -- and reusing `.end-slam`
          means the impact frame cannot drift between the two surfaces.

          THE SIZE STEPS DOWN FOR A LONG WORD on the same threshold EndScreen
          uses: "COOKED BY THE STORM" at text-8xl runs off a 16:9 screen, and
          this one has no backdrop to run off onto.

          NO `.ts` AND NO `tscale`, DELIBERATELY, and this is not a #159
          oversight. Those scale BODY text with the player's text-size
          preference; this is a display slam already sized in viewport-relative
          Tailwind steps, and multiplying it further would push the long causes
          off the screen at the large setting -- which is the failure the size
          step above exists to prevent. The verdict screen's own slam is sized
          the same way for the same reason. */}
      <h1
        className={`end-slam font-display tracking-tight text-white/95 ${
          word.length > 12 ? 'text-6xl' : 'text-8xl'
        }`}
        style={{ textShadow: 'var(--shadow-text)' }}
      >
        {word}
      </h1>
    </div>
  )
}
