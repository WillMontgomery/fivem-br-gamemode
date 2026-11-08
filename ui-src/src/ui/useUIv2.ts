/**
 * Is UI v2's `piece` on here (#436)?
 *
 * The answer br_core's client holds, as br_ui told the page (bridge/uiv2.ts):
 * it moves in the lobby or as a match starts, and mid-match only as a first
 * answer (after a `restart br_core`). Every piece is off until told, so a
 * piece off draws today's screen, exactly. UI v2 is separate from the season.
 *
 * A PRIMITIVE SELECTOR, so a component re-renders only when its own piece
 * flips -- the shape check-ui R20 asks of the root.
 */

import { useUi } from '../store'
import type { UIv2Piece } from '../bridge/types'

export function useUIv2(piece: UIv2Piece): boolean {
  return useUi((s) => s.uiv2[piece] === true)
}
