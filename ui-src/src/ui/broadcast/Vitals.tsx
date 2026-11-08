import { useEffect, useRef, useState } from 'react'
import { Bar } from './Bar'
import { Fit } from './deps'
import { Plate } from './Plate'
import { toneColor, vars } from './util'

/**
 * VITALS (#431): THE PLAYER'S HEALTH AND SHIELD, SLANTED -- the owner's pick
 * (2026-11-03): "the kit's slanted vitals", like Broadcast, not today's pills.
 * The gallery's HUD board specimen ("vitals · slant"), promoted into the kit
 * so the HUD stage and the port draw the same one.
 *
 * Two straps, health over shield. Each: its slab in the bar's color, the
 * caption (today's two words, Health and Shield: the `title`s the row always
 * carried), a slanted bar on the RAMP feed (the 4-10 Hz push: .bar-fill's
 * 300 ms linear, never the squad's step), and the numeral after it in the bar's
 * color, which ticks in on the reveal (the kit's default). The shield is
 * notched in four: half a big potion a notch.
 *
 * TODAY'S RULES, KEPT (src/hud/Vitals.tsx):
 *   - a zero is not drawn: 0 health and 0 shield are what the empty bar says
 *   - every drop in health of half a point or more washes the health bar red,
 *     at most once a second (storm ticks drain silently; faster retriggers
 *     read as a strobe, 2026-08-04)
 *   - the caption takes the text-size slider; the numeral is a fixed plate
 *
 * ITS HEIGHT IS VITALS_H kit units, two straps and the gap between plates.
 * That is three times today's 1.05rem row: a bottom-anchored strip that tall
 * under the radar would climb over it, so the caller hangs it by its own height
 * (Hud.tsx's --vitals-drop) and the HUD's own rule decides (vitalsPlacement.ts,
 * the owner, 2026-08-23): under the radar when it fits there, otherwise above
 * it with the chat bumped up.
 *
 * Under a presence its plates move on their own channels (the slab is the
 * edge, the strap and the bar tracks the surface, the face the content), so
 * its anchor needs no channel wrapper of its own.
 */

/** One strap, kit units (the specimen's). */
export const VITAL_H = 1.5
/** Between the straps: --bc-gap (tokens.css), the gap between plates. */
const GAP = 0.3
/** The whole strip, kit units: what it needs below the radar. */
export const VITALS_H = 2 * VITAL_H + GAP

export function Vitals({ hp, armor }: { hp: number; armor: number }) {
  // THE HIT WASH, as today: every drop in hp re-keys a red wash over the
  // health bar, rate-limited to once a second.
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
    <div className="bc-vitalstrip">
      <Strap tone="hp" label="Health" value={hp} hit={hit} />
      <Strap tone="shield" label="Shield" value={armor} segments={4} />
    </div>
  )
}

function Strap({ tone, label, value, segments = 0, hit = 0 }: {
  tone: 'hp' | 'shield'
  /** Existing words only. */
  label: string
  value: number
  segments?: number
  hit?: number
}) {
  return (
    <Plate variant="strap" edge={toneColor(tone)} height={VITAL_H}>
      <Plate.Line cy={VITAL_H / 2} ch={0.4} lh={VITAL_H}>
        <Fit className="micro-label ts bc-vitalstrip__label" style={vars({ '--fs': 'var(--bc-fs-caption)' })}>
          {label}
        </Fit>
        <Bar value={value} tone={tone} feed="ramp" segments={segments} num hit={hit} />
      </Plate.Line>
    </Plate>
  )
}
