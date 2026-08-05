function Stat({ value, label }: { value: number; label: string }) {
  return (
    <div className="text-right">
      <div className="text-2xl font-bold leading-none tabular-nums">{value}</div>
      <div className="text-[0.5625rem] uppercase tracking-[0.18em] text-white/45 mt-0.5">
        {label}
      </div>
    </div>
  )
}

/**
 * Top-right readout.
 *
 * The squad count is SQUADS-ONLY. In solo every squad is one player, so the
 * panel read "12 squads / 12 alive" -- two numbers that are always equal, one
 * of them naming a thing the mode does not have (user, 2026-08-05).
 */
export default function Counters({
  alive, squads, kills, mode,
}: { alive: number; squads: number; kills: number; mode: string }) {
  return (
    <div className="panel px-4 py-2.5 flex gap-5">
      <Stat value={kills} label="Kills" />
      {mode === 'squad' && <Stat value={squads} label="Squads" />}
      <Stat value={alive} label="Alive" />
    </div>
  )
}
