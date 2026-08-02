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

export default function Counters({
  alive, squads, kills,
}: { alive: number; squads: number; kills: number }) {
  return (
    <div className="panel px-4 py-2.5 flex gap-5">
      <Stat value={kills} label="Kills" />
      <Stat value={squads} label="Squads" />
      <Stat value={alive} label="Alive" />
    </div>
  )
}
