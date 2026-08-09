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
function Fill({ value, colour, segments = 0, num }: {
  value: number
  colour: string
  /**
   * Segment count. Shield is segmented because a segmented shield is most of
   * why a shield reads as a resource rather than as a second health bar --
   * you can see at a glance how many potions' worth you have lost. Health is
   * continuous, because it is.
   */
  segments?: number
  /** Show the value on the bar. */
  num?: boolean
}) {
  const pct = Math.max(0, Math.min(1, value / 100))
  return (
    <div className="relative h-full w-full rounded-full bg-black/60 border border-white/10 overflow-hidden">
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
      {segments > 1 && (
        // Notches painted OVER the fill, so they do not move with it. A
        // repeating gradient rather than N elements: one paint, no layout,
        // and it costs nothing on the 60fps path.
        <div
          className="absolute inset-0 pointer-events-none"
          style={{
            backgroundImage: `repeating-linear-gradient(90deg,`
              + ` transparent 0 calc(${100 / segments}% - 1.5px),`
              + ` rgba(11,12,18,0.95) calc(${100 / segments}% - 1.5px) ${100 / segments}%)`,
          }}
        />
      )}
      {num && value > 0 && (
        <span
          className="absolute right-1.5 top-1/2 font-display leading-none tabular-nums"
          style={{
            transform: 'translateY(-50%)',
            // 0.88rem, up from 0.62. Health and shield are the two numbers a
            // player checks mid-fight without looking away from what they are
            // shooting at, and at 0.62rem they were unreadable "even in good
            // conditions" (user, 2026-08-09). The bar grew to hold them
            // rather than the number being moved out of it, so the strip
            // stays one object anchored where players have learned it is.
            fontSize: '0.88rem',
            // Heavier shadow to match: a bigger numeral over a bright fill
            // needs more separation, not less.
            textShadow: '0 1px 3px rgba(0,0,0,0.98), 0 0 6px rgba(0,0,0,0.7)',
          }}
        >
          {Math.round(value)}
        </span>
      )}
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

  // The container is BOTTOM-ANCHORED to the minimap's lower edge, so any
  // in-flow sibling grows the box UPWARD and shoves the health row over
  // the map (live report, 2026-08-04). The stamina bar is therefore
  // absolutely positioned BELOW the row -- out of flow, the health bar
  // exactly where it always was.
  return (
    <div className="relative">
      {/* 1.05rem, grown twice: 0.6, then 0.75 so the numerals would fit, and
          they still could not be read at a glance. The bar is the container
          for the number, so making the number legible means making the bar
          tall enough to hold it -- and the whole strip then moved DOWN, clear
          of the radar, because a bottom-anchored bar grows upward and this
          one had started covering the minimap. See --vitals-drop in Hud.tsx. */}
      <div className="flex gap-[3px] items-stretch h-[1.05rem]">
        <div className="basis-[62%] relative" title="Health">
          <Fill value={hp} colour="var(--color-hp)" num />
          {hit > 0 && <div key={hit} className="vitals-hit-flash" />}
        </div>
        <div className="basis-[38%]" title="Shield">
          {/* Four segments: the shield cap is 100 and a big potion is 50, so
              each notch is half a potion. The notches are the reason a
              shield reads as a resource you are spending. */}
          <Fill value={armour} colour="var(--color-shield)" segments={4} num />
        </div>
      </div>
      {/* Sprint stamina: full-width and the SAME HEIGHT as health and
          shield (user call, restated 2026-08-09 -- it had drifted thinner
          than both), hanging below the row. Fades away entirely at full,
          Fortnite-style -- hold SPRINT while running to drain it. */}
      <div
        className="absolute left-0 right-0 h-[1.05rem] transition-opacity duration-300"
        // ABOVE the row now, not below, and that swap is what let the health
        // strip come down off the minimap at all.
        //
        // There are only a couple of rem between the radar's bottom edge and
        // the safe margin -- not enough for the strip AND a bar hanging under
        // it. Something has to overlap the radar, and it should be the one
        // that is USUALLY NOT THERE: stamina fades out entirely at full, so
        // for most of a match this space is empty, while health and shield
        // are on screen every second of it.
        style={{ bottom: 'calc(100% + 3px)', opacity: stamina >= 99.5 ? 0 : 1 }}
        title="Stamina"
      >
        <Fill value={stamina} colour="rgba(255,255,255,0.9)" />
      </div>
    </div>
  )
}
