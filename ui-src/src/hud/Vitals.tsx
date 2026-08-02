/**
 * Health and shield bars.
 *
 * Both bars animate with `transform: scaleX()`, never `width`. Width animates on
 * the layout thread and costs real frames every time damage lands, which is
 * precisely when frames matter most. The CSS transition does the interpolation,
 * so React only re-renders when the server pushes a new value (~10 Hz), not per
 * frame.
 */
function Bar({
  value, max, colour, label,
}: { value: number; max: number; colour: string; label: string }) {
  const pct = Math.max(0, Math.min(1, value / max))

  return (
    <div className="mb-1.5">
      <div className="flex justify-between items-baseline mb-0.5">
        <span className="text-[0.625rem] uppercase tracking-[0.18em] text-white/45">
          {label}
        </span>
        <span className="text-sm font-semibold tabular-nums text-white/90">
          {Math.round(value)}
        </span>
      </div>
      <div className="h-2.5 rounded-full bg-black/55 border border-white/10 overflow-hidden">
        <div
          className="bar-fill h-full rounded-full"
          style={{
            transform: `scaleX(${pct})`,
            width: '100%',
            // The shading is a black overlay rather than color-mix(), which
            // FiveM's CEF may not parse. An unparseable background is not a
            // fallback -- the declaration is dropped and the bar renders
            // invisible, which is exactly what happened: health read 100 with
            // no green bar behind it.
            backgroundColor: colour,
            backgroundImage:
              'linear-gradient(90deg, rgba(0,0,0,0.45) 0%, rgba(0,0,0,0) 60%)',
          }}
        />
      </div>
    </div>
  )
}

export default function Vitals({ hp, armour }: { hp: number; armour: number }) {
  return (
    <div className="panel px-3.5 py-3">
      <Bar value={armour} max={100} colour="var(--color-shield)" label="Shield" />
      <Bar value={hp}     max={100} colour="var(--color-hp)"     label="Health" />
    </div>
  )
}
