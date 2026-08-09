/**
 * The loading ring.
 *
 * CIRCULAR, ALWAYS -- never a horizontal bar. A bar implies a scale, and
 * almost nothing this game waits on has an honest denominator: "streaming the
 * world", "waiting for the server", "finding a match" have no percentage that
 * is not invented. A ring can be indeterminate without lying, and becomes
 * determinate without changing component when a real number does exist.
 *
 * PERFORMANCE. Indeterminate rotates the svg -- one composited transform, so a
 * ring spinning for four minutes costs nothing -- while the arc's dash grows
 * and shrinks. Determinate drives `stroke-dashoffset`, which is paint-only and
 * never triggers layout. Neither touches the layout thread.
 *
 * The animations live in index.css so the whole motion vocabulary stays in one
 * file; this component only computes geometry.
 */

export default function Ring({
  size = 2.4,
  stroke = 0.22,
  progress,
  label,
}: {
  /** Outer diameter in rem, so it scales with the rest of the interface. */
  size?: number
  /** Stroke width in rem. */
  stroke?: number
  /**
   * 0..1 for a determinate ring. Undefined or null means indeterminate --
   * which is the correct choice whenever the number would be invented.
   */
  progress?: number | null
  /** Accessible name; also what a screen reader announces. */
  label?: string
}) {
  const determinate = progress != null

  // Geometry is computed in a unitless viewBox and sized in rem by the <svg>
  // attributes, so one component covers inline (1.1rem) to loadscreen (5rem).
  const box = 100
  const r = (box - stroke / size * box) / 2
  const circ = 2 * Math.PI * r
  const half = box / 2

  const pct = determinate ? Math.max(0, Math.min(1, progress as number)) : 0

  return (
    <span
      className={`ring${determinate ? '' : ' is-indeterminate'}`}
      role="progressbar"
      aria-label={label ?? 'Loading'}
      aria-valuenow={determinate ? Math.round(pct * 100) : undefined}
      style={{ width: `${size}rem`, height: `${size}rem` }}
    >
      <svg
        width={`${size}rem`}
        height={`${size}rem`}
        viewBox={`0 0 ${box} ${box}`}
        // --circ is read by the ringDash keyframes. Set here rather than in
        // CSS because only this component knows the radius.
        style={{ ['--circ' as string]: circ.toFixed(2) }}
      >
        <circle
          className="ring-track"
          cx={half} cy={half} r={r}
          strokeWidth={(stroke / size) * box}
        />
        <circle
          className="ring-arc"
          cx={half} cy={half} r={r}
          strokeWidth={(stroke / size) * box}
          strokeDasharray={circ.toFixed(2)}
          // Determinate sweeps clockwise from twelve o'clock as the offset
          // falls to zero. Indeterminate leaves this alone -- the keyframes
          // own both dash properties, and the CSS transition is disabled so
          // the two cannot fight.
          strokeDashoffset={determinate ? circ * (1 - pct) : circ}
          transform={`rotate(-90 ${half} ${half})`}
        />
      </svg>
    </span>
  )
}
