/**
 * What "banned" means, as one function.
 *
 * ITS OWN MODULE SO IT CAN BE TESTED. Buried inside the event handler it was
 * only reachable through a live DynamoDB call, which meant the rule that
 * decides whether a player gets into the server had no test at all.
 *
 * DUPLICATED FROM THE CONSOLE'S lib/bans.ts, deliberately. The two halves must
 * agree on what "banned" means, and the alternative to duplicating a dozen
 * lines is publishing a shared package to a game server that cannot install
 * dependencies. docs/ban-contract.md is the written contract; both sides point
 * at it, and both sides have tests over the same table of cases.
 */

/**
 * Is this ban in force at `now`?
 *
 * Lifted beats everything -- a lifted ban stays on the record precisely so
 * "has this person been banned before" remains answerable, so the row existing
 * is not the same as the ban applying. An expiry at or before `now` is served.
 * A null/absent expiry is permanent.
 */
export function isActive(ban, now) {
  if (!ban) return false
  if (ban.liftedAt) return false
  if (ban.expiresAt !== null && ban.expiresAt !== undefined && ban.expiresAt <= now) {
    return false
  }
  return true
}

/**
 * Given every ban row a connection's identifiers turned up, which one applies?
 *
 * THE GATE ASKS ABOUT TWO KEYS NOW, NOT ONE. `ringmaster-bans` is keyed on a
 * qualified identifier, and blitz-bot files a ban under `discord:<snowflake>`
 * when an admin bans somebody in Discord whom the game has never met. That row
 * was a record of a decision and not a door: the gate looked up the license and
 * nothing else, so a banned stranger walked in. It now looks up both, which
 * means it can hold two rows and needs a rule for reconciling them.
 *
 * THE OWNER'S RULING, SETTLED: an ACTIVE ban always takes precedence over a
 * lifted one. Nothing here looks at the KIND of identifier — a rule that
 * preferred the license row by kind would read an old, lifted license ban and
 * open the door to somebody Discord-banned this morning. The first row that is
 * in force wins; a row that is not in force never beats one that is.
 *
 * THE ORDER OF `rows` IS THE TIE-BREAK AND THE CALLER OWNS IT. Two rows both in
 * force refuse the same person either way, so all the order decides is which
 * `reason` reaches the connecting screen. index.js passes the LICENSE row
 * first, because that is the row the console's profile page shows an admin.
 *
 * DUPLICATED FROM THE CONSOLE'S lib/bans.ts, like `isActive` above and for the
 * same reason. docs/ban-contract.md is the written rule; both sides have a case
 * table over it.
 */
export function effective(rows, now) {
  for (const row of rows) {
    if (row && isActive(row, now)) return row
  }
  return null
}
