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
 *
 * EXPORTED BECAUSE A SECOND STRIP NOW USES IT. hud/VehicleBars.tsx draws
 * vehicle condition and fuel, and the owner's brief for those was "using the
 * same graphical style as the existing ones". The strongest reading of that is
 * not "copy these styles" but "be these styles": a duplicated pill with its own
 * gradient literals is the same look on the day it is written and a different
 * one after the first tweak to either. So the component is shared, and only the
 * colours and the split differ.
 */
export function Fill({ value, colour, segments = 0, num, label }: {
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
  /**
   * A caption INSIDE the pill, naming what the bar measures.
   *
   * ═══ HEALTH AND SHIELD DO NOT PASS ONE, AND THAT IS NOT AN OVERSIGHT ═══
   *
   * They are the two bars every player of this genre already knows on sight,
   * in the position GTA's own vitals occupied, and a caption on them would be
   * telling somebody the thing they are looking at is health. The vehicle
   * strip is different and the owner said so:
   *
   *   "The vehicle bars have nothing telling us what they actually indicate,
   *    and they should have a number or percentage built in as well."
   *                                                 -- owner, 2026-08-22
   *
   * Two unlabelled bars in a corner nobody had bars in before are two mystery
   * meters. So the caption is opt-in, it exists because it was asked for, and
   * it goes nowhere it was not.
   *
   * IN THE PILL, NOT ABOVE IT. A caption row would add a fourth surface to the
   * bottom-right column and push the inventory bar up by its height; putting it
   * where the numeral already lives keeps the strip one object, exactly as tall
   * as it was.
   */
  label?: string
}) {
  const pct = Math.max(0, Math.min(1, value / 100))

  // A LABELLED BAR HAS TO READ AT ZERO, AND AN UNLABELLED ONE MUST NOT START.
  //
  // `num && value > 0` was the rule and it is right for health and shield: 0
  // there means dead and means no shield, two states the empty bar says by
  // itself, and a lone "0" floating in an empty pill reads as debris.
  //
  // An empty TANK is the one reading a driver most needs, and it sits beside a
  // caption -- so the same blank would read as the number having failed rather
  // than as a zero. The caption is what changes the answer, so the caption is
  // what the condition asks about.
  const showNum = num === true && (value > 0 || label !== undefined)

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
      {label !== undefined && (
        // THE CAPTION LAYER'S TYPE SPEC, BORROWED WHOLE. `.micro-label` is
        // index.css's caption class -- "a short noun phrase naming the thing
        // beside or below it" -- and it owns the size, the weight, the 0.2em
        // tracking and the uppercase. Restating any of that here would be a
        // second copy of the project's smallest type style.
        //
        // `.ts` WITH AN EXPLICIT --fs, NEVER BARE `tscale`. `.micro-label`
        // declares its own font-size, and `.tscale` multiplies 1em -- the
        // PARENT's size -- so `micro-label tscale` ignores the player's text
        // slider entirely. index.css records that exact pair biting. This is
        // the shape that survives it, and it is what makes the caption honour
        // the preference while the numeral beside it stays fixed: prose scales,
        // a numeral read under pressure is a fixed-size plate.
        //
        // COLOUR AND SHADOW ARE OVERRIDDEN, and only those two. `.micro-label`
        // is dim because it normally sits on a near-black plate; this one sits
        // ON a saturated fill, so it takes the numeral's separation treatment
        // instead -- a step under white, over the same heavy shadow.
        //
        // `right` RESERVES THE NUMERAL'S CORNER so the two can never overlap:
        // 2.4rem covers "100" at 0.88rem Anton plus its 0.375rem inset. The
        // pill already clips, so a caption that outgrows what is left is cut
        // off rather than escaping the bar.
        <span
          className="micro-label ts absolute left-1.5 top-1/2 leading-none
                     whitespace-nowrap overflow-hidden"
          style={{
            ['--fs' as string]: '0.62rem',
            right: '2.4rem',
            transform: 'translateY(-50%)',
            color: 'rgba(255,255,255,0.88)',
            textShadow: '0 1px 3px rgba(0,0,0,0.98), 0 0 6px rgba(0,0,0,0.7)',
          }}
        >
          {label}
        </span>
      )}
      {showNum && (
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
