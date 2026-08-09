import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import type { DbnoPayload } from '../bridge/types'

/**
 * Downed-but-not-out placard.
 *
 * A `.panel-hot`, not a `.panel`, and that is the whole visual argument. This
 * was written in M2 as scaffolding and nothing ever pushed a `dbno` envelope,
 * so it was the one surface in the interface the M6b pass never saw -- it kept
 * the old rounded panel and its pill bars while every other readout became a
 * square placard with an inverted cap. It is also, by some distance, the most
 * urgent thing that can be on screen, which makes it the surface `.panel-hot`
 * was designed for.
 *
 * ONE SURFACE, TWO STATES, the same way StormBar is one placard for "moving in"
 * and "get out". Bleeding is danger-red with a countdown; somebody reaching you
 * flips `--hot` to the health colour and the cap says so. The arrangement never
 * changes, so it reads as the same object changing its mind rather than as two
 * widgets swapping. `key` on the placard replays the drop-in on that swap and
 * only on that swap -- and it sits on the inner element deliberately, so the
 * refs below survive the remount.
 *
 * TWO THINGS THE TIMER HAS TO GET RIGHT, both of which it got wrong while
 * nothing was feeding it:
 *
 * `bleedEndsAt` is a SERVER timestamp. The server's clock and the browser's
 * share no origin, so it is only comparable to `Date.now() + clockOffset` --
 * the rule StormBar and WarmupTimer already follow. Read against a bare
 * Date.now() it is wrong by however much the two happen to differ, which is a
 * number nobody can predict and everybody would report as a broken timer.
 *
 * And the bar's denominator is the FIRST reading of this knock, held in a ref.
 * Enemy fire SHORTENS the bleed -- that is what shooting a downed player does
 * -- so recomputing the total from the time remaining would refill the bar to
 * full every time somebody shot them. Held still, a burst visibly tears a
 * chunk out of it, which is the only reason the bar is there.
 */
export default function DbnoOverlay({ dbno }: { dbno: DbnoPayload }) {
  const timeRef = useRef<HTMLSpanElement>(null)
  const barRef = useRef<HTMLDivElement>(null)
  const reviveRef = useRef<HTMLDivElement>(null)
  const offset = useUi((s) => s.clockOffset)
  const endsAt = dbno.bleedEndsAt
  const reviving = !!dbno.reviverName

  // Seeded on the first frame of THIS knock. The component is mounted only
  // while `downed` is true, so a fresh knock brings a fresh ref with it.
  const totalRef = useRef(0)

  useEffect(() => {
    if (!endsAt) return
    let raf = 0

    const tick = () => {
      const left = Math.max(0, endsAt - (Date.now() + offset))
      if (totalRef.current <= 0) totalRef.current = Math.max(1, left)

      if (timeRef.current) {
        const txt = `${Math.ceil(left / 1000)}s`
        if (timeRef.current.textContent !== txt) timeRef.current.textContent = txt
      }
      if (barRef.current) {
        barRef.current.style.transform =
          `scaleX(${Math.min(1, left / totalRef.current)})`
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [endsAt, offset])

  // Written straight to the node for the same reason the countdown is: it
  // arrives at 4Hz from the server, and re-rendering the placard for each one
  // would be four renders a second to move one transform.
  useEffect(() => {
    if (reviveRef.current) {
      reviveRef.current.style.transform =
        `scaleX(${Math.min(1, Math.max(0, dbno.revivePct / 100))})`
    }
  }, [dbno.revivePct])

  return (
    <div className="absolute inset-x-0 bottom-40 flex justify-center">
      <div
        key={reviving ? 'up' : 'down'}
        className="panel-hot"
        style={{
          minWidth: '14rem',
          // --color-hp rather than a literal green: it is one of the four
          // tokens the colourblind modes remap, so the one moment in a match
          // where colour carries the whole message follows the setting.
          ['--hot' as string]: reviving
            ? 'var(--color-hp)'
            : 'var(--color-danger)',
        }}
      >
        {/* NO `tscale` HERE, and that is deliberate rather than an omission:
            `.panel-hot > .cap` is (0,2,0) and would beat it, so the class would
            sit in the markup implying a behaviour it does not have. The text
            slider is applied inside the .cap rule itself -- see index.css. */}
        <div className="cap">
          {reviving ? `${dbno.reviverName} is picking you up` : 'You are down'}
        </div>

        <div className="hotbody">
          <span
            ref={timeRef}
            className="font-display block leading-none tabular-nums"
            style={{ fontSize: '2rem', textShadow: 'var(--shadow-text)' }}
          >
            --
          </span>
          <span className="text-[0.55rem] font-semibold uppercase tracking-[0.18em] text-white/50">
            {reviving ? 'hold on' : 'until you bleed out'}
          </span>

          {/* SQUARE, like every other bar inside a placard -- the pill shape
              belonged to the panel this used to be.

              AND SIZED IN rem, NOT PIXELS. The root font size is
              `clamp(11px, 1.481vh * var(--ui-scale), 28px)`, so rem is the
              only unit the interface-size slider can reach: a bar in px stays
              a 3px hairline at every setting, on every resolution, while the
              placard around it doubles. This was the one px size in the whole
              HUD and it was in this file. */}
          <div className="mt-2 h-[0.2rem] w-full bg-black/60 overflow-hidden">
            <div
              ref={barRef}
              className="bar-fill h-full"
              style={{ width: '100%', background: 'var(--color-danger)' }}
            />
          </div>

          {/* The revive's own progress keeps its own track rather than
              recolouring the bleed bar: they run in opposite directions and
              one bar cannot say both. */}
          {reviving && (
            <div className="mt-1 h-[0.2rem] w-full bg-black/60 overflow-hidden">
              <div
                ref={reviveRef}
                className="bar-fill h-full"
                style={{ width: '100%', background: 'var(--color-hp)' }}
              />
            </div>
          )}
        </div>
      </div>
    </div>
  )
}
