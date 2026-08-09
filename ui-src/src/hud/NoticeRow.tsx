import { useEffect, useLayoutEffect, useRef, useState } from 'react'

/**
 * One notice, and the reason it is its own component: THE EXIT.
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
 */
export default function NoticeRow({
  children,
  tone,
  lifeMs,
}: {
  children: React.ReactNode
  tone: string
  /** When the store will drop this notice. The collapse starts just before. */
  lifeMs: number
}) {
  const bodyRef = useRef<HTMLDivElement>(null)
  const [h, setH] = useState<number | null>(null)
  const [leaving, setLeaving] = useState(false)

  // Measure before paint, so the row never renders at its natural height for
  // a frame and then jump to the animated one.
  useLayoutEffect(() => {
    if (bodyRef.current) setH(bodyRef.current.offsetHeight)
  }, [children])

  useEffect(() => {
    // Start collapsing slightly BEFORE the store removes it, so the gap is
    // already closed when the element disappears. Removal is then invisible
    // rather than being the thing that moves the stack.
    const t = window.setTimeout(() => setLeaving(true), Math.max(0, lifeMs - 280))
    return () => window.clearTimeout(t)
  }, [lifeMs])

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
        className="panel px-3.5 py-1.5 text-[0.8125rem] text-white/85 flex items-center gap-2"
        style={{
          // .panel has no border any more, so the tone rides a blade on the
          // leading edge and the radius squares off on that side.
          borderLeft: `2px solid ${tone}`,
          borderRadius: '0 var(--r-panel) var(--r-panel) 0',
        }}
      >
        {children}
      </div>
    </div>
  )
}
