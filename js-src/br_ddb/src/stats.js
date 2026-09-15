/**
 * The match-result write, as an expression rather than as a network call.
 *
 * WHY IT MOVED OUT OF index.js. Everything in this file is arithmetic on a
 * table and can therefore be wrong for weeks without anybody noticing -- which
 * is the rule src/ban.js, src/incident.js and src/close.js already live by. The
 * expression this builds decides what a player's career says, and until now the
 * only way to see it was to read it.
 *
 * ═══ THE ADD LIST IS AN ALLOWLIST AND IT IS ALWAYS WRITTEN IN FULL ═══
 *
 * A typo'd key must be dropped rather than quietly creating an attribute nobody
 * reads, so the payload is never looped over -- these fourteen names are, and a
 * caller who names something else contributes nothing. `ADD x 0` on an absent
 * attribute creates it at zero, which is why every counter is listed on every
 * write: a profile row's shape does not depend on what happened in one match.
 *
 * ⚠ AND A COUNTER THAT IS NOT ON THIS LIST DOES NOT EXIST ON THE PROFILE ROW,
 * WHICH IS A SILENT FAILURE AND HAS ALREADY HAPPENED ONCE. `voltsSpent` landed
 * on HISTORY_NUMBERS in 03cce2d -- the per-match rows -- and not here, so every
 * per-match figure was recorded and the lifetime total did not exist. Nothing
 * errors, nothing is missing from a payload, and a board that ranks on the
 * attribute reads zero for everybody. Adding the field to a caller is half the
 * change; the allowlist is the other half.
 *
 * ═══ THE SET LIST IS NOT, AND THAT IS THE FIX ═══
 *
 * `name` and `lastMatchAt` REPLACE rather than accumulate, and the first version
 * of this wrote them unconditionally with `num()`/`String()` fallbacks -- so a
 * caller that did not supply them wrote an empty name and lastMatchAt 0 over
 * whatever was there. For the match payout that is invisible, because a payout
 * always supplies them. For any OTHER caller of the same verb it is silent data
 * loss, and there is a second caller now: `brvolts` grants Volts through this
 * exact write (see br_core/server/debug.lua) and has no business claiming the
 * player just finished a match.
 *
 * So a field that is absent is not written. Present-and-zero is still a value
 * and is still written -- `lastMatchAt = 0` from a caller that means it is a
 * caller's bug, not this function's.
 *
 * ═══ `level` USED TO BE THE THIRD SET FIELD AND IS NOT WRITTEN AT ALL (#116) ═══
 *
 * `xp` is a fact: it accumulates through the ADD below, so concurrent match ends
 * compose and it cannot race. `level` was `levelFor(xp)` -- a pure function of
 * the attribute sitting beside it, computed in Lua and replaced here from a
 * read-modify-write. Two representations of one truth, and only the derived one
 * can be wrong. It was: 3558 lifetime XP stored as level 2.
 *
 * Every surface derives it at read time already (the lobby chip, the Ringmaster
 * profile, `brprofile`), so the stored attribute could no longer be right by
 * accident and could still be wrong. It is left in place on rows that already
 * carry it -- deleting it is not worth a migration -- and simply stops moving.
 *
 * A caller that still sends `level` contributes nothing, exactly like a typo'd
 * ADD key. That is the allowlist doing its job, and it is asserted rather than
 * assumed in scripts/test.mjs.
 */

/**
 * Everything that accumulates. Order is load-bearing only in that it fixes the
 * expression's text, which is what makes the pin in the tests meaningful.
 */
export const STATS_ADDS = [
  'xp',
  // CURRENCY IS EARNED HERE AND NOWHERE ELSE except `awardPay`, which says so
  // at its own definition. `br:ddb:spend` can only ever reduce a balance.
  'balance',
  // ═══ WHAT THEY HAVE SPENT, FOR THE LIFETIME OF THE PROFILE (#293) ═══
  //
  // The owner asked for a BIGGEST SPENDERS board, and a board ranks on an
  // attribute of the `sk=profile` row. This is that attribute.
  //
  // NOT THE COMPLEMENT OF `balance`, WHICH IS WHY IT IS ITS OWN COLUMN. A
  // balance is a position and this is a flow: a player who has earned 40k and
  // spent 39k holds the same 1k as somebody who earned 1k and bought nothing,
  // and only one of them is a big spender. The two cannot be derived from each
  // other in either direction.
  //
  // IT IS NOT A SECOND WRITER OF THE DEBIT EITHER. `br:ddb:spend` moves the
  // money, conditionally, at the moment of the purchase; this is a COUNTER of
  // what that verb took, accumulated at match end out of the same per-match
  // figure the history row already carries. A write that lost this one would
  // cost a leaderboard column and could never cost anybody Volts.
  'voltsSpent',
  'matches',
  'wins',
  'top10s',
  'kills',
  'deaths',
  'downs',
  'revives',
  'damageDealt',
  'playtimeSec',
  'soloMatches',
  'squadMatches',
]

/**
 * Everything that replaces: the caller's field name, the placeholder it gets,
 * and the attribute it lands on. Three separate names because the attribute is
 * `lastMatchAt` and the caller calls it `at`.
 *
 * `level` was the first entry here until #116. See the header for why nothing
 * derived belongs on this list.
 */
export const STATS_SETS = [
  { field: 'name', ph: '#nm', vh: ':nm', attr: 'name', kind: 'string' },
  { field: 'at', ph: '#ls', vh: ':ls', attr: 'lastMatchAt', kind: 'number' },
]

/** A number, or zero -- the same coercion the rest of the bridge uses. */
const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0)

/**
 * Did the caller actually say anything about this field?
 *
 * `undefined` is what a missing Lua table key arrives as, and `null` is what an
 * explicit nil crossing a runtime boundary can become. An empty string is
 * treated as absent for `name` specifically, because '' is exactly the value
 * the old unconditional write produced from a missing one -- so accepting it
 * would preserve the bug this distinction exists to remove.
 */
function supplied(v, kind) {
  if (v === undefined || v === null) return false
  if (kind === 'string') return String(v) !== ''
  return true
}

/**
 * Build the one UpdateItem a match result becomes.
 *
 * Returns plain JS values, NOT marshalled: this module knows nothing about the
 * AWS SDK, which is what lets the test suite import it with no node_modules at
 * all. The caller marshalls.
 *
 * @param {object} deltas
 * @returns {{ UpdateExpression: string,
 *             ExpressionAttributeNames: Record<string,string>,
 *             ExpressionAttributeValues: Record<string,number|string> }}
 */
export function buildStatsUpdate(deltas) {
  const d = deltas || {}

  const names = {}
  const values = {}

  const sets = []
  for (const s of STATS_SETS) {
    if (!supplied(d[s.field], s.kind)) continue
    names[s.ph] = s.attr
    values[s.vh] = s.kind === 'string' ? String(d[s.field]) : num(d[s.field])
    sets.push(`${s.ph} = ${s.vh}`)
  }

  const adds = []
  for (const k of STATS_ADDS) {
    names[`#${k}`] = k
    values[`:${k}`] = num(d[k])
    adds.push(`#${k} :${k}`)
  }

  // SET first, then ADD -- DynamoDB accepts the clauses in any order and this
  // one is the order the expression has always been written in.
  const expr = (sets.length > 0 ? `SET ${sets.join(', ')} ` : '')
    + `ADD ${adds.join(', ')}`

  return {
    UpdateExpression: expr,
    ExpressionAttributeNames: names,
    ExpressionAttributeValues: values,
  }
}
