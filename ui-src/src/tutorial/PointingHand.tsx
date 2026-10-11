/**
 * The animated hand that points at a card's control (#405).
 *
 * Owner, 2026-10-11, on Solo or Squads: "if they sit there for 5+ seconds, place
 * an animated hand pointing to the 'Squads' button." `Step.hand` says when; this
 * is the hand.
 *
 * DRAWN HERE, IN SVG, AND NOT AN IMAGE. A cartoon pointer of rounded rects -- an
 * index finger up, three knuckles, a thumb and a cuff in the accent -- outlined
 * as ONE shape by drawing every piece twice: once stroked and fat, then once
 * filled on top, so the strokes between the pieces are covered and only the
 * silhouette keeps its edge.
 *
 * THE FINGERTIP IS THE ANCHOR. The layer places this element's top-left on the
 * point to touch, and `.tut-hand svg`'s offsets put the tip (13, 2 in the
 * viewBox) exactly there, so the tap and the tilt in index.css pivot on it.
 */

/** The pieces, in the 40 x 52 viewBox. */
const PARTS: { x: number; y: number; w: number; h: number; r: number; rot?: number }[] = [
  { x: 9, y: 2, w: 8, h: 26, r: 4 },          // index finger, pointing
  { x: 16.5, y: 17, w: 7.5, h: 13, r: 3.75 }, // middle knuckle
  { x: 23.5, y: 19, w: 7, h: 12, r: 3.5 },    // ring knuckle
  { x: 30, y: 21.5, w: 6.5, h: 10.5, r: 3.25 }, // little knuckle
  { x: 8, y: 23, w: 29, h: 19, r: 7 },        // palm
  { x: 2, y: 24, w: 8, h: 15, r: 4, rot: -28 }, // thumb
]

function Part(p: (typeof PARTS)[number]) {
  return (
    <rect
      x={p.x} y={p.y} width={p.w} height={p.h} rx={p.r}
      transform={p.rot ? `rotate(${p.rot} ${p.x + p.w / 2} ${p.y + p.h / 2})` : undefined}
    />
  )
}

export default function PointingHand({ x, y }: { x: number; y: number }) {
  return (
    <div className="tut-hand" style={{ left: x, top: y }} aria-hidden>
      <svg viewBox="0 0 40 52">
        {/* THE OUTLINE: every piece, stroked wide. */}
        <g style={{ fill: '#04222a', stroke: '#04222a', strokeWidth: 3.2, strokeLinejoin: 'round' }}>
          {PARTS.map((p, n) => <Part key={n} {...p} />)}
          <rect x={10.5} y={41} width={26} height={9} rx={1.5} />
        </g>
        {/* THE FILL, on top, so the joins between pieces disappear. */}
        <g style={{ fill: '#ffffff' }}>
          {PARTS.map((p, n) => <Part key={n} {...p} />)}
        </g>
        <rect x={10.5} y={41} width={26} height={9} rx={1.5}
              style={{ fill: 'var(--color-royale-accent)' }} />
      </svg>
    </div>
  )
}
