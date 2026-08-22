/**
 * WHAT THE SLAM SAYS WHEN YOU LOST, BY HOW YOU LOST.
 *
 * ═══ WHY THIS IS A MODULE AND NOT A FUNCTION INSIDE EndScreen ═══
 *
 * It was one, and it was correct there while there was one surface. There are
 * two now, and they are two on purpose:
 *
 *   DeathVerdict  the moment you die, over the live world, ~10 seconds, then
 *                 gone as the spectator camera takes over.
 *   EndScreen     the match-end verdict screen -- backdrop, placement, Volts --
 *                 which is unchanged.
 *
 * "Upon dying, the verdict text ONLY should be shown for ~10 seconds then the
 * text can immediately disappear as we snap into spectating. Our typical
 * verdict screen should remain once the match is over." -- the owner. Two
 * moments, two surfaces, ONE WORD TABLE: a player who is told BLED OUT when
 * they die and ELIMINATED thirty seconds later has been told two different
 * stories about the same death, and a second copy of this switch is how that
 * happens. This repository's signature bug is two representations of one fact.
 *
 * ═══ THE WORDS ═══
 *
 * "ELIMINATED" is reserved for another player doing it -- getting outrun by a
 * wall of purple or stepping off a cliff is not an elimination and reads as a
 * lie when the screen calls it one. Everything else gets the energy of a GTA
 * death with the honesty of a cause, and the generic environmental fallback is
 * the franchise's own word for it.
 *
 * THE FALLBACK IS LOAD-BEARING RATHER THAN DEFENSIVE. The death moment can
 * genuinely reach this with no cause: the roster delta that makes a player DEAD
 * and the kill-feed message carrying the cause are separate wires with no
 * ordering between them, so the word goes up with whatever is known and is
 * corrected in place if the cause lands inside the window. 'WASTED' is what a
 * player sees for those few frames, and it is never wrong -- only less specific.
 */
export function verdictWord(
  cause: string | null | undefined,
  byPlayer: boolean | undefined,
): string {
  if (byPlayer) return 'ELIMINATED'
  switch (cause) {
    // Nobody finished them; the clock did. Distinct from ELIMINATED on
    // purpose -- being left on the floor and being shot are different stories,
    // and only one of them has somebody to blame.
    case 'bledout':   return 'BLED OUT'
    case 'storm':     return 'COOKED BY THE STORM'
    case 'fall':      return 'GRAVITY WINS'
    case 'drowned':   return 'SLEPT WITH THE FISHES'
    case 'burned':    return 'EXTRA CRISPY'
    case 'explosion': return 'BLOWN TO BITS'
    case 'roadkill':  return 'SPEED BUMP'
    default:          return 'WASTED'
  }
}
