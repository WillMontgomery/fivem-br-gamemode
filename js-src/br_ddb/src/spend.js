/**
 * The durable debit: take Volts off a profile row, or take nothing.
 *
 * ═══ WHY THIS IS NOT `br:ddb:purchase` ═══
 *
 * `purchase` is one conditional write that debits the balance AND adds the item
 * to the profile's `owned` string set, refusing when the set already contains
 * it. That is exactly right for a canopy somebody owns forever and exactly
 * WRONG for a car bought again every match: the id would be marked owned on the
 * first purchase and the second one would be refused, permanently, with the
 * player's Volts intact and no car. Reusing it was the tempting shortcut and it
 * would have looked correct for precisely one match.
 *
 * So this verb has NO `owned` set, no item id, and nothing idempotent about it.
 * A repeatable spend is repeatable by construction; the caller is the thing that
 * decides how often, and the caller is server-side Lua.
 *
 * ═══ THE CONDITION IS THE WHOLE FEATURE ═══
 *
 * `#bal >= :cost` is evaluated by DYNAMODB at write time, against the real row,
 * which is the only place the question can be answered truthfully. Every other
 * candidate answer is a cache:
 *
 *   * the CLIENT's balance is whatever it was last told;
 *   * the SERVER's session cache (br_core/server/market.lua) is one read taken
 *     on connect, and a second server, a report award, or a console grant can
 *     move the row underneath it.
 *
 * Both are worth keeping as conveniences -- they refuse instantly and can say
 * how short somebody is -- but neither is the authority, and a spend that
 * trusted one would let a stale cache overdraw a real balance. So the affordable
 * case and the unaffordable case reach DynamoDB identically and DynamoDB picks.
 *
 * A MISSING `balance` ATTRIBUTE MAKES THE COMPARISON FALSE rather than treating
 * it as zero, which is DynamoDB's own rule and is the behaviour wanted here: a
 * row that has never earned anything cannot spend anything.
 *
 * ═══ WHAT IT DOES NOT DO ═══
 *
 * It cannot INCREASE a balance. `:neg` is derived from `:cost` inside this
 * function and `:cost` is refused unless it is a positive whole number, so
 * there is no argument that turns this verb into a way to mint currency. That
 * is a property worth stating out loud, because "the currency is earned, never
 * bought" (br_lib/config/market.lua) is a design promise and a debit verb that
 * accepted negative amounts would quietly end it.
 */

/** The largest single debit this verb will accept. */
export const SPEND_MAX = 1_000_000

/**
 * Coerce an amount to the cost this verb will charge, or null.
 *
 * WHOLE NUMBERS ONLY. A balance is an integer everywhere it is shown -- the
 * lobby, the verdict screen, `brprofile` -- and a fractional debit would make
 * the stored number disagree with every rendering of it. Rejected rather than
 * rounded: a caller asking to charge 12.5 has a bug, and rounding it hides the
 * bug while still taking the money.
 *
 * @param {unknown} amount
 * @returns {number|null}
 */
export function spendCost(amount) {
  const n = Number(amount)
  if (!Number.isFinite(n)) return null
  if (n <= 0) return null
  if (n !== Math.floor(n)) return null
  if (n > SPEND_MAX) return null
  return n
}

/**
 * The UpdateItem a debit becomes, minus the table and the key.
 *
 * PLAIN VALUES, NOT MARSHALLED, for the same reason as src/stats.js: this
 * module knows nothing about the AWS SDK, so scripts/test.mjs can import it
 * with no node_modules and drive the expression against a fake row. The caller
 * marshalls.
 *
 * @param {number} cost  a value that has already been through spendCost
 */
export function spendUpdate(cost) {
  return {
    UpdateExpression: 'ADD #bal :neg',
    ConditionExpression: '#bal >= :cost',
    ExpressionAttributeNames: { '#bal': 'balance' },
    // TWO PLACEHOLDERS FOR ONE NUMBER, and they must not be collapsed into one.
    // The condition compares against the POSITIVE cost and the update adds the
    // NEGATIVE of it; a single `:cost` used in both would make the condition
    // read `balance >= -750`, which every balance in the game satisfies -- the
    // expression would still parse, still debit, and never refuse anything.
    ExpressionAttributeValues: { ':neg': -cost, ':cost': cost },
  }
}
