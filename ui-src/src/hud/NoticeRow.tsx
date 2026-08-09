import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useUi } from '../store'

/**
 * One notice, and the two reasons it is its own component.
 *
 * 1. THE EXIT.
 *
 * A notice that fades out leaves its space behind for the length of the fade,
 * and then the space vanishes in a single frame -- so everything below it
 * SNAPS upward. It is a small thing that reads as cheap, and it is the
 * difference between a stack that settles and a stack that twitches.
 *
 * Animating the height to zero makes the gap close over the same 260ms the
 * opacity takes, so the rest of the stack slides. Height is a layout property
 * and this is the one place in the interface that animates one -- justified
 * because the notice stack is at most five short rows, is never on the 60fps
 * combat path, and there is no transform that closes a gap in flow.
 *
 * The height is MEASURED rather than assumed: notices wrap to two lines when
 * the text is long, and a fixed height would clip them.
 *
 * 2. THE COUNTDOWN.
 *
 * `endsAt` turns the row into a live one. The number is written straight to a
 * DOM node from one requestAnimationFrame loop -- the same discipline the
 * storm bar and the warmup timer follow -- so a counting notice costs no
 * re-renders at all, and the alternative (a notice per second) never has to
 * exist. THIRTY LINES SAYING THE SAME THING WITH A DIFFERENT NUMBER IS NOT A
 * NOTIFICATION SYSTEM.
 *
 * `endsAt` is a SERVER timestamp. clockOffset is what makes it comparable to
 * Date.now(); without it every countdown in the game is wrong by whatever the
 * two clocks happen to disagree by, which is not a small number.
 */
export default function NoticeRow({
  children,
  tone,
  lifeMs,
  endsAt,
  sticky,
}: {
  children: React.ReactNode
  tone: string
  /** When the store will drop this notice. The collapse starts just before. */
  lifeMs: number
  /** Server deadline for the in-line countdown, if this notice has one. */
  endsAt?: number
  /** Persistent: no self-collapse, because nothing is coming to remove it
   *  except an explicit clear -- and that unmounts the row outright. */
  sticky?: boolean
}) {
  const bodyRef = useRef<HTMLDivElement>(null)
  const timeRef = useRef<HTMLSpanElement>(null)
  const offset = useUi((s) => s.clockOffset)
  const [h, setH] = useState<number | null>(null)
  const [leaving, setLeaving] = useState(false)

  // Measure before paint, so the row never renders at its natural height for
  // a frame and then jumps to the animated one.
  useLayoutEffect(() => {
    if (bodyRef.current) setH(bodyRef.current.offsetHeight)
  }, [children])

  useEffect(() => {
    // A sticky notice has no scheduled end, so scheduling its collapse would
    // fade out a line that is still true and leave it on screen at zero
    // opacity -- present in layout, invisible, unremovable.
    if (sticky) { setLeaving(false); return }

    // Start collapsing slightly BEFORE the store removes it, so the gap is
    // already closed when the element disappears. Removal is then invisible
    // rather than being the thing that moves the stack.
    //
    // Re-armed when lifeMs changes: an updated notice has a new deadline, and
    // a collapse already queued against the OLD one would close the row while
    // its replacement was still counting.
    setLeaving(false)
    const t = window.setTimeout(() => setLeaving(true), Math.max(0, lifeMs - 280))
    return () => window.clearTimeout(t)
  }, [lifeMs, sticky])

  useEffect(() => {
    if (endsAt == null) return
    let raf = 0
    const tick = () => {
      const node = timeRef.current
      if (node) {
        const left = Math.max(0, endsAt - (Date.now() + offset))
        const secs = Math.ceil(left / 1000)
        const next = secs >= 60
          ? `${Math.floor(secs / 60)}:${String(secs % 60).padStart(2, '0')}`
          : `${secs}s`
        if (node.textContent !== next) node.textContent = next
      }
      raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [endsAt, offset])

  return (
    <div
      className="notice-row"
      style={{
        height: h == null ? undefined : leaving ? 0 : h,
        opacity: leaving ? 0 : 1,
        marginTop: leaving ? 0 : undefined,
      }}
    >
      <div
        ref={bodyRef}
        // `tscale`: a notice is a line of prose in a box that grows with it,
        // which is exactly the shape that can honour a text-size preference
        // without clipping. The HUD plates cannot, and deliberately do not.
        className="plate ts px-3.5 py-1.5 text-white/90 flex items-center gap-2"
        style={{
          // A PLATE, NOT A PANEL, and that is the design system's own rule
          // rather than a preference: `.panel` is the surface that RECEDES --
          // translucent, borderless, rounded -- and a notice is an EVENT. It
          // announces something. Events are plates: near-opaque, square, with
          // a bright edge that carries the tone.
          //
          // It shipped as a rounded panel and stayed that way through the
          // whole overhaul (user, 2026-08-09: "still using rounded corners.
          // Not the square ones you spec'd ages ago").
          ['--fs' as string]: '0.8125rem',
          ['--edgec' as string]: tone,
          ['--plate-fill' as string]: 'rgba(18,21,30,0.94)',
          ['--cut-max' as string]: '0.3rem',
          // The tone also rides a blade on the leading edge -- the edge alone
          // is a hairline, and this is read peripherally.
          borderLeft: `2px solid ${tone}`,
        }}
      >
        {children}
        {endsAt != null && (
          // Anton and tabular: this is a number the player reads while doing
          // something else, and it must not reflow the row as it shrinks
          // through 10.
          <span
            ref={timeRef}
            className="font-display text-[0.85rem] tabular-nums leading-none ml-auto pl-1"
            style={{ color: tone }}
          >
            --
          </span>
        )}
      </div>
    </div>
  )
}
