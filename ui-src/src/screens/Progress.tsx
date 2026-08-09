import { useEffect, useRef, useState } from 'react'
import { useUi } from '../store'
import { play } from '../audio/cues'

/**
 * LEVEL AND XP.
 *
 * WHAT THIS IS AND IS NOT, because the honesty matters more than the pixels:
 * there is no XP system in this game yet. There is no persistence, no server
 * ledger, no economy. `SummaryPayload.xpEarned` has existed on the wire since
 * M2 and nothing has ever written a non-zero value into it.
 *
 * So this is the INTERFACE for one, built against synthetic data, so the shape
 * of it can be argued about before anyone writes the server half. The store
 * seeds a plausible profile in the browser harness and Lua will send a real
 * one when there is a real one; nothing in this file knows the difference.
 *
 * THE DESIGN, in three moments:
 *
 *   1. AT REST, in the lobby. A level chip and a bar. It is the first thing
 *      on the screen because it is the answer to "what did all that playing
 *      get me", and burying that under a menu is how a progression system
 *      stops motivating anyone.
 *
 *   2. THE AWARD, after a match. The bar FILLS from where it was, with the
 *      earned amount counting up beside it. Deliberately slower than the eye
 *      expects (1.4s): the fill is the reward, and rushing it throws away the
 *      only moment the system has.
 *
 *   3. THE LEVEL UP. The bar reaches the end, empties, the chip flips to the
 *      new number and punches. It is the one place in the lobby that gets
 *      gold, which is otherwise reserved for a Victory Royale -- levelling is
 *      the other thing worth celebrating.
 *
 * The bar is a scaleX transform, not a width: this animates for a second and a
 * half and there is no reason for it to be on the layout thread.
 */

export interface ProgressData {
  level: number
  /** XP into the current level. */
  xp: number
  /** XP the current level requires. */
  needed: number
}

/** Counts a number up to a target over `ms`, straight to the DOM. */
function useCountUp(target: number, ms: number, enabled: boolean) {
  const ref = useRef<HTMLSpanElement>(null)
  useEffect(() => {
    if (!enabled) return
    const node = ref.current
    if (!node) return
    let raf = 0
    const t0 = performance.now()
    const tick = (now: number) => {
      const k = Math.min(1, (now - t0) / ms)
      // Ease-out: the number should decelerate into its final value rather
      // than stopping dead, which reads as the counter being cut off.
      const eased = 1 - Math.pow(1 - k, 3)
      node.textContent = `+${Math.round(target * eased)}`
      if (k < 1) raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [target, ms, enabled])
  return ref
}

/**
 * The resting readout: level, bar, and how far to the next one.
 *
 * `award` turns it into the post-match moment. Passing it re-runs the fill
 * from the PREVIOUS value, which is why the component takes the award rather
 * than the caller pre-adding it.
 */
export default function Progress({
  compact = false,
}: { compact?: boolean }) {
  const p = useUi((s) => s.progress)
  const award = useUi((s) => s.xpAward)
  const clearAward = useUi((s) => s.clearXpAward)

  // Where the bar starts the animation from. With no award this is simply
  // where it is; with one, it is where it WAS.
  const [filled, setFilled] = useState(p.xp / Math.max(1, p.needed))
  const [levelling, setLevelling] = useState(false)
  const shown = useRef(p.level)

  const counter = useCountUp(award?.xp ?? 0, 1400, award != null)

  useEffect(() => {
    if (!award) {
      setFilled(p.xp / Math.max(1, p.needed))
      shown.current = p.level
      return
    }

    // Start where the player left off, then fill. The rAF below is what
    // guarantees the browser paints the starting value before the transition
    // begins -- setting both in one frame animates from nothing.
    setFilled(award.fromXp / Math.max(1, award.fromNeeded))
    shown.current = award.fromLevel

    const raf = requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        const levelled = p.level > award.fromLevel
        setFilled(levelled ? 1 : p.xp / Math.max(1, p.needed))
        if (levelled) {
          // Run the bar to full, hold a beat, then reset it and flip the
          // number. The pause is the point -- an instant flip loses the
          // moment the whole system exists to produce.
          window.setTimeout(() => {
            setLevelling(true)
            play('ui.ready')
            shown.current = p.level
            setFilled(0)
            window.setTimeout(() => {
              setFilled(p.xp / Math.max(1, p.needed))
              setLevelling(false)
            }, 420)
          }, 1500)
        }
      })
    })

    const done = window.setTimeout(() => clearAward(), 5200)
    return () => { cancelAnimationFrame(raf); window.clearTimeout(done) }
  }, [award, p.level, p.xp, p.needed, clearAward])

  const pct = Math.max(0, Math.min(1, filled))

  return (
    <div className={compact ? '' : 'w-full'}>
      <div className="flex items-end gap-3">
        {/* THE LEVEL CHIP. A plate, like everything else that is an object
            rather than a surface -- and it takes the victory gold only while
            it is actually levelling up. */}
        <div
          className={`plate px-2.5 py-1 flex flex-col items-center leading-none${
            levelling ? ' is-active' : ''}`}
          style={{
            ['--edgec' as string]: levelling
              ? 'var(--color-royale-accent2)' : 'var(--color-royale-accent)',
            ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
            ['--cut-max' as string]: '0.4rem',
            animation: levelling ? 'punch 420ms var(--ease-snap)' : undefined,
          }}
        >
          <span className="micro-label" style={{ letterSpacing: '0.18em' }}>Lvl</span>
          <span
            className="font-display text-[1.5rem] tabular-nums leading-none mt-0.5"
            style={{ color: levelling ? 'var(--color-royale-accent2)' : '#ffffff' }}
          >
            {shown.current}
          </span>
        </div>

        <div className="flex-1 min-w-0 pb-0.5">
          <div className="flex items-baseline justify-between mb-1">
            <span className="micro-label">
              {levelling ? 'Level up' : 'Progress'}
            </span>
            <span className="text-[0.72rem] tabular-nums text-white/45">
              {award ? (
                <span
                  ref={counter}
                  className="font-display text-[0.95rem]"
                  style={{ color: 'var(--color-royale-accent)' }}
                >
                  +0
                </span>
              ) : (
                `${p.xp} / ${p.needed}`
              )}
            </span>
          </div>

          <div className="h-[0.5rem] rounded-full bg-black/55 overflow-hidden">
            <div
              className="h-full rounded-full origin-left"
              style={{
                width: '100%',
                transform: `scaleX(${pct})`,
                background: levelling
                  ? 'var(--color-royale-accent2)'
                  : 'var(--color-royale-accent)',
                // 1.4s, and slower than feels natural on purpose: the fill IS
                // the reward. The reset after a level-up is quick, because
                // that one is bookkeeping rather than celebration.
                transition: `transform ${pct === 0 ? 320 : 1400}ms var(--ease-out),`
                          + ' background 300ms ease',
              }}
            />
          </div>
        </div>
      </div>
    </div>
  )
}
