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
