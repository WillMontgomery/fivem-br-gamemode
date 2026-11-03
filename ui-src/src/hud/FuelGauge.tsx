import type { InvSlot } from '../bridge/types'
import { gaugeShare } from './gaugeShare'

/**
 * A JERRY CAN'S FILL, ON ITS PLATE (#217).
 *
 * Owner, 2026-11-02: "held as an item in an inventory slot. partial use of a
 * can should be possible." So a can is not always a whole can. A pour that
 * tops up a car at 90% keeps the rest in the can, a pour cut short keeps what
 * it had not poured, and without this a can with a sliver left would look
 * exactly like a full one until it was pressed.
 *
 * DRAWN, NEVER WRITTEN. A slim bar down the plate's right inner edge, filling
 * from the bottom the way a fuel gauge reads, with no number, no percent and
 * no new string: the plate already says what the item is, and this says only
 * how much of it is left.
 *
 * NEVER EMPTY WHILE THE CAN HOLDS ANYTHING. The height is hud/gaugeShare.ts's:
 * the fill, but at least a sliver of the gauge for any fill above 0 -- a
 * thousandth drawn as it is would be a twentieth of a pixel, and a can that
 * looks empty still takes the one place a player may carry one.
 *
 * THE VARIABLE, NOT A HEX (#392), as everywhere else on a plate: the slot's
 * own --rarity-N, so the colorblind modes repaint the gauge with the band and
 * the pips. The track is the one the use-progress bar runs on (black at 60%),
 * so what has been poured still reads as part of the gauge, and the bar reads
 * as a quantity rather than as a stripe of color.
 *
 * DRAWN WHENEVER `fill` IS THERE, a full can included. The server sends it on
 * every can slot and on no other (bridge/types.ts), so a full gauge is simply
 * what a can looks like, rather than a mark that turns up once one has been
 * used.
 *
 * NO ANIMATION. The server moves `fill` on the wire when a pour ends, not per
 * slice -- while one runs, every push carries the fill it started from -- so it
 * changes once per pour, and the use-progress bar has already shown that pour
 * as it ran. A transition here would only replay it.
 *
 * WHERE IT STANDS IS THE CALLER'S. The HUD bar's plate and the TAB panel's
 * card keep different furniture in their corners -- the slot number, the bevel
 * a held plate cuts, the count corner, the rarity band, the progress bar, the
 * pips -- so each passes the insets that clear its own, and this owns the look.
 */
export default function FuelGauge({ slot, className }: {
  slot: InvSlot
  /** Tailwind insets that place the bar on this plate: top, bottom and right. */
  className: string
}) {
  if (slot.fill == null) return null
  return (
    <div className={`absolute w-[0.2rem] bg-black/60 ${className}`}>
      <div
        className="absolute bottom-0 left-0 right-0"
        style={{
          height: `${Math.round(gaugeShare(slot.fill) * 1000) / 10}%`,
          backgroundColor: `var(--rarity-${slot.rarity})`,
        }}
      />
    </div>
  )
}
