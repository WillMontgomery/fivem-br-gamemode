import type { FeedEntry } from '../bridge/types'

/**
 * Elimination feed.
 *
 * Entries are capped in the store (8) and keyed by id so React reuses the DOM
 * nodes instead of rebuilding the list. An uncapped feed in a 20-minute match is
 * how a HUD quietly accumulates hundreds of nodes.
 */
export default function KillFeed({ entries }: { entries: FeedEntry[] }) {
  return (
    <div className="flex flex-col gap-1 items-end">
      {entries.map((e) => (
        <div
          key={e.id}
          className="rise panel px-2.5 py-1 text-[0.6875rem] flex items-center gap-1.5 max-w-full"
          style={e.mine ? { borderColor: 'color-mix(in oklch, var(--color-royale-accent) 60%, transparent)' } : undefined}
        >
          <span className="font-semibold truncate max-w-[5rem]"
                style={{ color: e.mine ? 'var(--color-royale-accent2)' : 'white' }}>
            {e.killer}
          </span>
          {e.headshot && <span title="Headshot" className="text-[0.625rem]">&#9679;</span>}
          <span className="text-white/35">&rarr;</span>
          <span className="truncate max-w-[5rem] text-white/70">{e.victim}</span>
        </div>
      ))}
    </div>
  )
}
