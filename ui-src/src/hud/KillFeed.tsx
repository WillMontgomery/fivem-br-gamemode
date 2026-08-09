import { FEED_TTL_MS } from '../store'
import type { FeedEntry } from '../bridge/types'

/**
 * Elimination feed.
 *
 * Entries remove themselves from the store after FEED_TTL_MS and fade out
 * just before they go -- a permanent ledger in the corner reads as clutter
 * by the third elimination. Keyed by id so React reuses DOM nodes.
 *
 * Environmental deaths have no killer, so "→ name" with an empty left side
 * told you nothing. They get a phrase instead, GTA-flavoured to match the
 * verdict slams.
 */

const CAUSE_PHRASE: Record<string, string> = {
  storm:       'got cooked by the storm',
  fall:        'fought gravity and lost',
  drowned:     'went for a swim',
  burned:      'burned out',
  explosion:   'blew up',
  roadkill:    'became a speed bump',
  left:        'left the match',
  admin:       'was smitten by an admin',
}

const FADE_MS = 500

export default function KillFeed({ entries }: { entries: FeedEntry[] }) {
  return (
    <div className="flex flex-col gap-1 items-end">
      {entries.map((e) => (
        <div
          key={e.id}
          className="panel px-3 py-1.5 text-[0.8125rem] flex items-center gap-1.5 max-w-full"
          style={{
            // .panel has no border any more, so an own-kill is marked with a
            // blade on the leading edge rather than a border colour that
            // would now silently do nothing.
            ...(e.mine ? {
              borderLeft: '2px solid var(--color-royale-accent)',
              borderRadius: '0 var(--r-panel) var(--r-panel) 0',
            } : {}),
            animation: `noticeIn 200ms ease-out both, `
                     + `noticeOut ${FADE_MS}ms ease-in ${FEED_TTL_MS - FADE_MS}ms both`,
          }}
        >
          {e.killer ? (
            <>
              <span className="font-semibold truncate max-w-[11rem]"
                    style={{ color: e.mine ? 'var(--color-royale-accent)' : 'white' }}>
                {e.killer}
              </span>
              {e.headshot && <span title="Headshot" className="text-[0.6875rem]">&#9679;</span>}
              <span className="text-white/35">&rarr;</span>
              <span className="truncate max-w-[11rem] text-white/70">{e.victim}</span>
            </>
          ) : (
            <>
              <span className="font-semibold truncate max-w-[11rem]"
                    style={{ color: e.mine ? 'var(--color-royale-accent)' : 'white' }}>
                {e.victim}
              </span>
              <span className="text-white/55">
                {CAUSE_PHRASE[e.weapon] ?? 'was wasted'}
              </span>
            </>
          )}
        </div>
      ))}
    </div>
  )
}
