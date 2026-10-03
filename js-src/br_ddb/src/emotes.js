/**
 * The emote wheel's two writes: take a dance off a slot, and hand one over.
 *
 * Owner, 2026-10-02 (#215, "Scope v2"): "Up to 8 equipped", managed from the
 * Market, 250 Volts each, and a console command that grants them on the dev
 * box. Everything else about emotes lives in Lua; these are the only two things
 * the database has to be told that it could not be told before.
 *
 * ═══ EIGHT SLOTS, AND EACH ONE IS A FLAT ATTRIBUTE ═══
 *
 * `equip_emote1` .. `equip_emote8`, for exactly the reason `equip_chute` is flat
 * rather than a key inside a map: DynamoDB cannot SET a path inside a map that
 * does not exist yet, so a nested `emotes[3]` would need the parent seeded first
 * -- a second write, and a race on a brand-new player. Slot k IS wheel segment
 * k, and positions are stable: nothing ever compacts them, so a dance the player
 * put on segment 5 is on segment 5 next session.
 *
 * `br:ddb:equip` already writes a slot (SET #eq = :id, conditioned on owning the
 * id), so equipping an emote is that verb with a kind of 'emote3'. What it could
 * not do is EMPTY one -- every other kind falls back to a default and has no
 * un-equip -- which is `unequipUpdate` below.
 *
 * ═══ ownedAdd IS NOT `purchase`, AND IT IS NOT CALLED "grant" ═══
 *
 * `purchase` debits the balance in the same write, so it cannot hand over
 * something nobody paid for. `ownedAdd` adds an id to the `owned` string set and
 * touches nothing else: it is what the `bremotegrant` console command uses. Not
 * named "grant" because `br:ddb:grantsFetch` already exists for capability
 * grants, and "grant" in this project means BR.Grants (docs/terminology.md).
 *
 * IT CANNOT ADD A CHUTE, A TRAIL OR VOLTS. `addableId` refuses anything that is
 * not an `emote_` id, and the update has no balance in it, so there is no
 * argument that turns this verb into a way to give somebody a paid cosmetic or
 * mint currency.
 *
 * PLAIN DATA, NO AWS IMPORTS, in the shape of src/spend.js: scripts/test.mjs
 * imports this module with no node_modules and drives it against a fake row.
 * `ownedAddUpdate` hands back raw AttributeValues, as `purchase` builds its own
 * in src/index.js, because a string SET has no plain-JS spelling that marshall
 * would turn into an SS rather than an L.
 */

/** The eight wheel slots, as `br:ddb:equip` kinds. Slot k is segment k. */
export const EMOTE_SLOTS = Object.freeze([
  'emote1', 'emote2', 'emote3', 'emote4',
  'emote5', 'emote6', 'emote7', 'emote8',
])

/**
 * What an emote id looks like: br_lib/config/emotes.lua's rowProblem allows
 * `emote_` plus at most 48 more characters (54 in all), and so does this.
 */
export const EMOTE_ID = /^emote_[a-z0-9_]{1,48}$/

/**
 * Is `kind` one of the eight wheel slots?
 * @param {unknown} kind
 * @returns {boolean}
 */
export function isEmoteSlot(kind) {
  return typeof kind === 'string' && EMOTE_SLOTS.includes(kind)
}

/**
 * The id `ownedAdd` will add, or null.
 *
 * EMOTES ONLY. A chute id, an empty string and an over-long id are all refused
 * before anything is sent -- see the header for why that is the whole safety
 * argument of this verb.
 *
 * @param {unknown} itemId
 * @returns {string|null}
 */
export function addableId(itemId) {
  if (typeof itemId !== 'string') return null
  return EMOTE_ID.test(itemId) ? itemId : null
}

/**
 * The UpdateItem an `ownedAdd` becomes, minus the table and the key.
 *
 * THE CONDITION MAKES A SECOND GRANT AN ANSWER RATHER THAN A NO-OP. ADDing an
 * id already in a string set changes nothing, which is fine for the row and
 * useless for the console: `bremotegrant ... all` has to be able to say
 * "already owned" for the ones that were. ConditionalCheckFailedException is
 * that answer.
 *
 * @param {string} id  a value that has already been through addableId
 */
export function ownedAddUpdate(id) {
  return {
    UpdateExpression: 'ADD #own :idset',
    ConditionExpression: 'attribute_not_exists(#own) OR NOT contains(#own, :id)',
    ExpressionAttributeNames: { '#own': 'owned' },
    ExpressionAttributeValues: { ':idset': { SS: [id] }, ':id': { S: id } },
  }
}

/**
 * The UpdateItem that empties one wheel slot, or null for anything that is not
 * a wheel slot.
 *
 * NULL FOR 'chute', AND THAT IS THE POINT. Every other kind has a default to
 * fall back to; REMOVEing `equip_chute` would leave a row the inventory read
 * fills from config anyway, and a verb that could do it would be a verb whose
 * only effect on those kinds is a surprise.
 *
 * @param {unknown} kind
 */
export function unequipUpdate(kind) {
  return isEmoteSlot(kind)
    ? { UpdateExpression: 'REMOVE #eq', ExpressionAttributeNames: { '#eq': `equip_${kind}` } }
    : null
}
