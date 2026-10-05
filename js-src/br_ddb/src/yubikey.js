/**
 * The Yubikey on the profile row (#396, Season 2).
 *
 * ═══ THE OWNER'S RULES, 2026-10-04 ═══
 *
 * An OWNED item, at most one per player, that "carries with them to another
 * match if they choose not to use it", and is gone after one use or when its
 * holder is killed. So it is a fact about the ACCOUNT, and it lives on the
 * profile row beside balance, xp and the tutorial state: one more attribute
 * the connect read (`inventoryFetch`) already returns, at no extra cost.
 *
 * ═══ TWO ATTRIBUTES ═══
 *
 *   yubikey      N, 1 or 0. Whether this account holds a key right now.
 *   yubikeySeen  BOOL. Whether it has ever held one -- the first pickup's
 *                explanation is shown once per player, ever, and this is the
 *                "once". Set by the same write that grants the key, so the
 *                two cannot disagree about the first one.
 *
 * ═══ THE CAP OF ONE IS A CONDITION, NOT A HOPE ═══
 *
 * br_core's server refuses a second pickup from its own session cache, which
 * is what the player sees. This is the storage half: a grant is conditional on
 * the row NOT already holding one, and a spend on it holding one, so two
 * servers (or a stale cache) can never write a second key or spend one that
 * is not there. A refused condition is an answer, not an error -- `refused`
 * says which -- and br_core logs it rather than undoing anything, because
 * either way the row ends in the state br_core asked for.
 *
 * THE ROW IS CREATED IF IT IS NOT THERE on a grant, the same call
 * `tutorialSet` makes: a key can be picked up in somebody's very first match,
 * before the match-end write has ever made their profile row.
 */

/**
 * The UpdateItem for `held`, or null for anything that is not a boolean.
 *
 * ALREADY AttributeValues, like `ownedAddUpdate` in emotes.js, so the caller
 * passes them straight through rather than marshalling them a second time.
 * @param {unknown} held
 * @returns {null | {UpdateExpression: string, ConditionExpression: string,
 *   ExpressionAttributeNames: Record<string, string>,
 *   ExpressionAttributeValues: Record<string, object>}}
 */
export function yubikeyUpdate(held) {
  if (held === true) {
    return {
      UpdateExpression: 'SET #k = :one, #seen = :t',
      ConditionExpression: 'attribute_not_exists(#k) OR #k = :zero',
      ExpressionAttributeNames: { '#k': 'yubikey', '#seen': 'yubikeySeen' },
      ExpressionAttributeValues: { ':one': { N: '1' }, ':zero': { N: '0' }, ':t': { BOOL: true } },
    }
  }
  if (held === false) {
    return {
      UpdateExpression: 'SET #k = :zero',
      ConditionExpression: '#k = :one',
      ExpressionAttributeNames: { '#k': 'yubikey' },
      ExpressionAttributeValues: { ':one': { N: '1' }, ':zero': { N: '0' } },
    }
  }
  return null
}

/**
 * What a refused condition means, for the answer's `refused` field.
 * @param {boolean} held  what was asked for
 * @returns {string}
 */
export function yubikeyRefusal(held) {
  return held ? 'already held' : 'not held'
}

/**
 * The two fields as inventoryFetch hands them to Lua: plain booleans, never
 * absent, because nil does not survive the trip as a table field.
 * @param {Record<string, unknown> | null | undefined} row  unmarshalled
 * @returns {{yubikey: boolean, yubikeySeen: boolean}}
 */
export function yubikeyFields(row) {
  return {
    yubikey: Number(row?.yubikey ?? 0) === 1,
    yubikeySeen: row?.yubikeySeen === true,
  }
}
