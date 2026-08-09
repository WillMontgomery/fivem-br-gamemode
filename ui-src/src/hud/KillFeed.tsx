import { FEED_TTL_MS } from '../store'
import type { FeedEntry } from '../bridge/types'
import ItemIcon from './ItemIcon'

/**
 * Elimination feed.
 *
 * A KILL FEED ANSWERS "WHAT AM I UP AGAINST", not just "somebody died". This
 * one used to be two names and an arrow, which answers neither -- the corner
 * of the screen filled with rows that all looked the same and told you nothing
 * you could act on (user, 2026-08-08).
 *
 * Three things carry the meaning now, in the order the eye takes them:
 *
 *   COLOUR   -- whose news is it. Your kill is cyan, your death is red,
 *               everyone else's is white. `mine` used to be true for BOTH of
 *               yours, so the best and worst moments of a match were drawn
 *               identically.
 *   WEAPON   -- what did it, between the names. The server has known this
 *               since M6 took over damage; the feed simply never carried it.
 *               A row of sniper icons is a fact about the lobby you can plan
 *               around.
 *   MOTION   -- your own rows arrive with a punch. Everyone else's slide in
 *               quietly. Two hundred eliminations a match cannot all be
 *               events.
 *
 * Entries remove themselves from the store after FEED_TTL_MS and fade just
 * before they go -- a permanent ledger in the corner reads as clutter by the
 * third elimination. Keyed by id so React reuses DOM nodes.
 *
 * Environmental deaths have no killer, so "-> name" with an empty left side
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

/** Causes that are the WORLD rather than a weapon, so the row words it. */
function isCause(weapon: string): boolean {
  return weapon in CAUSE_PHRASE || weapon === 'unknown' || weapon === ''
}

const FADE_MS = 500

export default function KillFeed({ entries }: { entries: FeedEntry[] }) {
  return (
    <div className="flex flex-col gap-1 items-end">
      {entries.map((e) => {
        // Your kill and your death are opposite news and get opposite
        // colours. Everything else is somebody else's business.
        const accent = e.mine
          ? 'var(--color-royale-accent)'
          : e.died ? 'var(--color-danger)' : null

        return (
          <div
            key={e.id}
            className="panel px-3 py-1.5 text-[0.8125rem] flex items-center gap-1.5 max-w-full"
            style={{
              // .panel has no border any more, so a row that concerns you is
              // marked with a blade on the leading edge rather than a border
              // colour that would now silently do nothing.
              ...(accent ? {
                borderLeft: `2px solid ${accent}`,
                borderRadius: '0 var(--r-panel) var(--r-panel) 0',
                // A touch of the accent behind your own rows, so they read
                // even out of the corner of your eye.
                backgroundColor: e.mine
                  ? 'rgba(14, 60, 72, 0.86)' : 'rgba(64, 20, 24, 0.86)',
              } : {}),
              // Yours punches; everyone else's arrives quietly. Both are
              // transform/opacity only -- the feed sits on the 60fps path.
              animation: `${accent ? 'punch 260ms var(--ease-snap)' : 'noticeIn 200ms ease-out'} both, `
                       + `noticeOut ${FADE_MS}ms ease-in ${FEED_TTL_MS - FADE_MS}ms both`,
            }}
          >
            {e.killer ? (
              <>
                <span className="font-semibold truncate max-w-[11rem]"
                      style={{ color: e.mine ? 'var(--color-royale-accent)' : 'white' }}>
                  {e.killer}
                </span>

                {/* THE WEAPON, NOT AN ARROW. The arrow only ever said
                    "killed", which the row's existence already said. When
                    the server could not attribute a weapon there is nothing
                    honest to draw, so the arrow comes back rather than a
                    guessed icon. */}
                {isCause(e.weapon) ? (
                  <span className="text-white/35 px-0.5">&rarr;</span>
                ) : (
                  <span
                    className="px-0.5 shrink-0"
                    style={{ color: accent ?? 'rgba(255,255,255,0.75)' }}
                    title={e.weapon}
                  >
                    <ItemIcon
                      slot={{
                        id: e.weapon, label: e.weapon, kind: 'weapon',
                        rarity: 1, count: 1,
                      }}
                      size="1.15rem"
                    />
                  </span>
                )}

                {/* Headshots read as a discipline, not a footnote -- and it
                    goes AFTER the weapon, where it modifies it. */}
                {e.headshot && (
                  <span
                    className="font-display text-[0.6rem] tracking-[0.1em] leading-none
                               px-1 py-0.5 rounded-sm shrink-0"
                    style={{
                      color: '#0b0c12',
                      backgroundColor: accent ?? 'rgba(255,255,255,0.75)',
                    }}
                    title="Headshot"
                  >
                    HS
                  </span>
                )}

                <span className="truncate max-w-[11rem]"
                      style={{ color: e.died ? 'var(--color-danger)' : 'rgba(255,255,255,0.7)' }}>
                  {e.victim}
                </span>
              </>
            ) : (
              <>
                <span className="font-semibold truncate max-w-[11rem]"
                      style={{ color: e.died ? 'var(--color-danger)' : 'white' }}>
                  {e.victim}
                </span>
                <span className="text-white/55">
                  {CAUSE_PHRASE[e.weapon] ?? 'was wasted'}
                </span>
              </>
            )}
          </div>
        )
      })}
    </div>
  )
}
