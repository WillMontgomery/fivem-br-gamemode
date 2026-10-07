import { useRef } from 'react'
import { useUi } from '../store'
import { formatClock } from './countdown'
import { useCountdownText } from './useCountdownText'
import { impactKeys, type ImpactRow } from './impactRows'
import { KeyText } from '../ui/KeyCap'

/**
 * THE PERSISTENT NOTICES (#396, round 4).
 *
 * Owner, 2026-10-06: "Anything that a player is being impacted by, which
 * happened as a result of another player's actions at a terminal, should show a
 * persistent notification with a timer explaining what the impact is and when
 * it will be over."
 *
 * ROWS OF THE NOTICE STACK, AT ITS FOOT, THAT DO NOT PASS. Each is drawn as a
 * notice is -- the same plate, the same blade, the same KeyText sentence --
 * in the warning tone, because each says something another player is doing to
 * you. Unlike a notice it neither flies in nor times out: the server sends this
 * player's whole list when it changes (br_core's server/terminalfx.lua), and a
 * row is up exactly while it is in that list. Nothing here decides what is
 * true.
 *
 * THE CLOCK IS THE SHARED ONE. `endsAt` is the server's clock; the row counts
 * down against it with the store's clockOffset through useCountdownText -- one
 * timer to the next displayed second, written straight into the node, no
 * re-render and nothing per frame -- as a clock (formatClock: `2:59`, `0:07`).
 * A row for the rest of the match shows its `tail` in that place instead.
 */
function ImpactLine({ row, tone }: { row: ImpactRow; tone: string }) {
  const timeRef = useRef<HTMLSpanElement>(null)
  const offset = useUi((s) => s.clockOffset)
  useCountdownText(timeRef, row.endsAt ?? 0, offset, row.endsAt != null, formatClock)
  return (
    <div
      className="plate ts px-3.5 py-1.5 text-white/90 flex items-start gap-2"
      style={{
        // NoticeRow's plate, and for its reasons: a notice is an event, and
        // events are plates -- near-opaque, square, the tone on a bright edge
        // and on a blade down the leading side, read peripherally.
        ['--fs' as string]: '0.8125rem',
        ['--edgec' as string]: tone,
        ['--plate-fill' as string]: 'rgba(18,21,30,0.94)',
        ['--cut-max' as string]: '0.3rem',
        borderLeft: `2px solid ${tone}`,
      }}
    >
      <span className="min-w-0 break-words">
        {/* KeyText, as a notice's sentence is drawn: these lines name no
            player, so there is no name to set in bold (NoticeText's half). */}
        <KeyText text={row.text} fs="0.95rem" />
      </span>
      {row.endsAt != null ? (
        // Anton and tabular, NoticeRow's countdown: a number read while doing
        // something else must not reflow the row as it shrinks.
        <span
          ref={timeRef}
          className="font-display text-[0.85rem] tabular-nums leading-none ml-auto pl-1"
          style={{ color: tone }}
        >
          --
        </span>
      ) : row.tail ? (
        <span
          className="font-display text-[0.85rem] leading-none ml-auto pl-1 whitespace-nowrap"
          style={{ color: tone }}
        >
          {row.tail}
        </span>
      ) : null}
    </div>
  )
}

/**
 * Every row, in the server's order, keyed for React by impactKeys, in the tone
 * the stack hands down (Notices.tsx: its warning tone).
 */
export default function ImpactRows({ rows, tone }: { rows: ImpactRow[]; tone: string }) {
  const keys = impactKeys(rows)
  return (
    <>
      {rows.map((r, i) => <ImpactLine key={keys[i]} row={r} tone={tone} />)}
    </>
  )
}
