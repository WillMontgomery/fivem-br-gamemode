/**
 * Health and shield, drawn where GTA's own minimap strip used to be.
 *
 * The stock bars are hidden game-side (SETUP_HEALTH_ARMOUR on the minimap
 * scaleform -- they also disagreed with our numbers, because they draw the
 * raw engine range). These render in their place: same layout language as
 * the original -- health left, shield right, one slim row spanning the
 * minimap's width -- in our own visual style, anchored to the real minimap
 * rectangle via the --map-* variables so the safe-zone slider moves us with
 * the radar.
 *
 * Both fills animate with `transform: scaleX()`, never `width`. Width
 * animates on the layout thread and costs real frames every time damage
 * lands, which is precisely when frames matter most.
 */
function Fill({ value, colour }: { value: number; colour: string }) {
  const pct = Math.max(0, Math.min(1, value / 100))
  return (
    <div className="h-full w-full rounded-full bg-black/60 border border-white/10 overflow-hidden">
      <div
        className="bar-fill h-full rounded-full"
        style={{
          transform: `scaleX(${pct})`,
          width: '100%',
          // Black overlay shading, not color-mix() -- FiveM's CEF drops what
          // it cannot parse and the bar simply vanishes.
          backgroundColor: colour,
          backgroundImage:
            'linear-gradient(90deg, rgba(0,0,0,0.45) 0%, rgba(0,0,0,0) 60%)',
        }}
      />
    </div>
  )
}

export default function Vitals({ hp, armour }: { hp: number; armour: number }) {
  return (
    <div className="flex gap-[3px] items-stretch h-[0.6rem]">
      <div className="basis-[62%]" title="Health">
        <Fill value={hp} colour="var(--color-hp)" />
      </div>
      <div className="basis-[38%]" title="Shield">
        <Fill value={armour} colour="var(--color-shield)" />
      </div>
    </div>
  )
}
