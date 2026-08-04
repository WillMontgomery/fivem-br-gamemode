import { useEffect, useRef, useState } from 'react'

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

export default function Vitals({ hp, armour, stamina = 100 }:
  { hp: number; armour: number; stamina?: number }) {
  // THE HIT FLASH. Storm ticks drain health silently, one point at a time,
  // and a slim bar quietly getting shorter is easy to miss entirely (user
  // report, 2026-08-04). Every DROP in hp remounts a red overlay over the
  // health bar (key change restarts the animation) -- rate-limited to 1Hz
  // (second user call, same day): faster damage retriggers read as a
  // strobe, and the 650ms burn already covers the second.
  const prevHp = useRef(hp)
  const lastFlash = useRef(0)
  const [hit, setHit] = useState(0)
  useEffect(() => {
    const now = Date.now()
    if (hp < prevHp.current - 0.5 && now - lastFlash.current >= 1000) {
      lastFlash.current = now
      setHit((h) => h + 1)
    }
    prevHp.current = hp
  }, [hp])

  return (
    <div>
      <div className="flex gap-[3px] items-stretch h-[0.6rem]">
        <div className="basis-[62%] relative" title="Health">
          <Fill value={hp} colour="var(--color-hp)" />
          {hit > 0 && <div key={hit} className="vitals-hit-flash" />}
        </div>
        <div className="basis-[38%]" title="Shield">
          <Fill value={armour} colour="var(--color-shield)" />
        </div>
      </div>
      {/* Sprint stamina: its own full-width bar UNDER the vitals (user
          call, 2026-08-04 -- the hair-thin strip above them was invisible).
          Fades away entirely at full, Fortnite-style. */}
      <div
        className="h-[0.35rem] mt-[3px] rounded-full bg-black/50 border border-white/10 overflow-hidden transition-opacity duration-300"
        style={{ opacity: stamina >= 99.5 ? 0 : 1 }}
        title="Stamina"
      >
        <div
          className="bar-fill h-full rounded-full bg-white/90"
          style={{ transform: `scaleX(${Math.max(0, Math.min(1, stamina / 100))})`, width: '100%' }}
        />
      </div>
    </div>
  )
}
