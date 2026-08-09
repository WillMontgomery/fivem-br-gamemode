import { useEffect, useRef, useState } from 'react'

/**
 * Top-right readout.
 *
 * ALIVE IS THE HERO NUMBER. It defines a battle royale, and it used to sit at
 * the same size as everything beside it. Squads is subordinate to it (they
 * answer the same question at different resolutions), and kills moves out into
 * its own plate because it is YOURS -- not a third statistic about the match.
 *
 * The squad count is SQUADS-ONLY. In solo every squad is one player, so the
 * panel read "12 squads / 12 alive" -- two numbers that are always equal, one
 * of them naming a thing the mode does not have (user, 2026-08-05).
 *
 * A COUNTER CHANGE IS AN EVENT, NOT AN UPDATE. A number that changes silently
 * did not happen. Each one punches, flashes toward the colour that says who
 * caused it, and leaves a floating delta.
 */

/** The most recent change to a value, or null. `id` restarts the animation. */
function useBump(value: number) {
  const prev = useRef(value)
  const seq = useRef(0)
  const [bump, setBump] = useState<{ id: number; delta: number } | null>(null)

  useEffect(() => {
    if (value === prev.current) return
    const delta = value - prev.current
    prev.current = value
    seq.current += 1
    setBump({ id: seq.current, delta })
  }, [value])

  return bump
}

/**
 * One counter. The delta is rendered OUTSIDE the plate: `.plate` is clipped by
 * a polygon, and anything drawn inside it gets sliced off by the chamfer.
 */
function Counter({
  value, label, sub, colour, big,
}: {
  value: number
  label: string
  sub?: string
  /** What the flash and the delta mean: cyan is yours, white is the world. */
  colour: string
  big?: boolean
}) {
  const bump = useBump(value)

  return (
    <div className="relative">
      <div className={`plate ${big ? 'px-4 py-2 min-w-[6.5rem]' : 'px-3 py-2'} text-right`}>
        <span
          // key restarts the punch: remounting is how every other animation in
          // this project is retriggered, and mixing in a second mechanism is
          // how they drift.
          key={bump?.id ?? 0}
          className={`font-display leading-none tabular-nums block${bump ? ' counted' : ''}`}
          style={{
            fontSize: big ? '2.4rem' : '1.5rem',
            color: '#ffffff',
            textShadow: 'var(--shadow-text)',
            ['--flashc' as string]: colour,
          }}
        >
          {value}
        </span>
        <div className="text-[0.55rem] font-semibold uppercase tracking-[0.2em] text-white/45 mt-0.5">
          {label}
        </div>
        {sub && (
          <div className="text-[0.6rem] font-semibold text-white/50 mt-1 tracking-wide">
            {sub}
          </div>
        )}
      </div>

      {bump && (
        <span key={bump.id} className="count-delta" style={{ color: colour, fontSize: '1rem' }}>
          {bump.delta > 0 ? `+${bump.delta}` : bump.delta}
        </span>
      )}
    </div>
  )
}

export default function Counters({
  alive, squads, kills, mode, squadKills,
}: {
  alive: number; squads: number; kills: number; mode: string
  /** The squad's total, YOURS INCLUDED. Undefined in solo, and undefined
   *  rather than 0 when there is no squad to total -- a "Squad 0" beside your
   *  own count would read as a team that has done nothing rather than as a
   *  team that does not exist. */
  squadKills?: number
}) {
  return (
    <div className="flex items-start gap-2">
      <Counter
        value={kills}
        label="Elims"
        // Cyan: you did this. The colour answers "was that me?" without words.
        colour="var(--color-royale-accent)"
        // THE SQUAD'S TOTAL, subordinate to your own (user, 2026-08-09). It
        // rides the same slot the alive counter uses for "N squads": a second
        // number that qualifies the first rather than competing with it, so
        // the hero numeral is still the one you are personally responsible
        // for. Hidden when it equals your own -- "3 / squad 3" is noise.
        sub={squadKills != null && squadKills !== kills
          ? `${squadKills} squad`
          : undefined}
      />
      <Counter
        value={alive}
        label="Alive"
        // NOT GATED ON `mode` ALONE. It read "1 squads" in a solo match (user,
        // 2026-08-08) -- whatever the match reported, the mode string was not
        // what this assumed. So the test is now about the NUMBER, which cannot
        // lie: a squad count only tells you something when there is more than
        // one of them AND it differs from the alive count. In solo those are
        // equal, so it disappears on its own with no mode check at all.
        // Pluralised too, because "1 squads" was wrong even when it was right.
        sub={mode === 'squad' && squads > 1 && squads !== alive
          ? `${squads} squads`
          : undefined}
        // White: the world moved. Someone died and it was not your doing.
        colour="#ffffff"
        big
      />
    </div>
  )
}
