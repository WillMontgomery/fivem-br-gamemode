/**
 * Locker v2's saved peds and worn ped (#28, Season 2).
 *
 * ═══ WHERE THEY LIVE ═══
 *
 * One item per saved ped in `br-players`, under the player's own partition:
 *
 *   { pk: <license>, sk: 'ped#<id>', n, a, cr, up, img? }
 *
 *   id   eleven base36 characters: nine of milliseconds, two random, so the
 *        ids sort by creation (br_lib/shared/appearance.lua mints them)
 *   n    the name, letters and digits, 1 to 24 (only its owner sees it)
 *   a    the appearance, its canonical JSON string, 2048 bytes at most
 *   cr   created, epoch ms; up  last written, epoch ms
 *   img  the headshot as a webp data URL, a few KB
 *
 * One item per ped rather than a list on the profile row: the owner set no
 * limit on saved peds, and an item is capped at 400 KB.
 *
 * The worn ped is one string attribute on the profile row, `locker2`.
 *
 * ═══ THE KEY IS BUILT HERE, NEVER TAKEN ═══
 *
 * Every ped verb takes (license, id) and builds `ped#<id>` itself after
 * checking the id's shape, the way historyItem asserts `match#`. So a write or
 * a delete can only ever reach a `ped#` row: never `profile` or `purchases`,
 * which is where Volts and bought items live.
 *
 * ═══ THE ONE QUERY ═══
 *
 * Listing a player's peds is a Query on their own partition with
 * `begins_with(sk, 'ped#')` -- the key the game box already holds, the prefix
 * fixed here. It cannot reach another player's rows, and it cannot reach the
 * profile or the match history either. docs/security.md records it.
 */

export const PED_PREFIX = 'ped#'
export const ID_LEN = 11
export const NAME_MAX = 24
export const APPEARANCE_MAX = 2048
/** A webp data URL: the prefix, then base64 of at most 8 KB. */
export const IMG_PREFIX = 'data:image/webp;base64,'
export const IMG_MAX = IMG_PREFIX.length + Math.ceil(8192 / 3) * 4
/** The worn record: an appearance plus a little. */
export const WORN_MAX = APPEARANCE_MAX + 64
/** Pages a listing reads at most. A page is 1 MB; this is far past any list. */
export const QUERY_PAGES = 20

/** @param {unknown} id */
export function isPedId(id) {
  return typeof id === 'string' && id.length === ID_LEN && /^[0-9a-z]+$/.test(id)
}

/** @param {unknown} n */
export function isName(n) {
  return typeof n === 'string' && /^[A-Za-z0-9]{1,24}$/.test(n)
}

/** @param {unknown} a */
export function isAppearance(a) {
  return typeof a === 'string' && a.length > 0 && a.length <= APPEARANCE_MAX && a.startsWith('{"v":1,')
}

/** @param {unknown} img */
export function isImage(img) {
  return typeof img === 'string' && img.length <= IMG_MAX && img.startsWith(IMG_PREFIX)
    && /^[A-Za-z0-9+/]+={0,2}$/.test(img.slice(IMG_PREFIX.length))
}

/** @param {unknown} w */
export function isWorn(w) {
  return typeof w === 'string' && w.length > 0 && w.length <= WORN_MAX && w.startsWith('{"k":')
}

/**
 * The key of one saved ped, or null. The sort key is built here and its prefix
 * asserted, so no caller can name another row.
 * @param {unknown} license
 * @param {unknown} id
 * @returns {{pk: string, sk: string} | null}
 */
export function pedKey(license, id) {
  if (typeof license !== 'string' || license === '' || !isPedId(id)) return null
  const sk = PED_PREFIX + id
  if (!sk.startsWith(PED_PREFIX) || sk.length !== PED_PREFIX.length + ID_LEN) return null
  return { pk: license, sk }
}

/**
 * The PutItem for a saved ped, or null. `isNew` writes only where no item is;
 * an update only where one is, so a ped deleted elsewhere is not brought back.
 * @param {string} table
 * @param {unknown} license
 * @param {unknown} id
 * @param {{n: unknown, a: unknown, cr: unknown, up: unknown}} rec
 * @param {boolean} isNew
 */
export function pedPutInput(table, license, id, rec, isNew) {
  const key = pedKey(license, id)
  if (!key || !rec || !isName(rec.n) || !isAppearance(rec.a)) return null
  const cr = Number(rec.cr)
  const up = Number(rec.up)
  if (!Number.isSafeInteger(cr) || !Number.isSafeInteger(up) || cr < 0 || up < 0) return null
  return {
    TableName: table,
    Item: { ...key, n: rec.n, a: rec.a, cr, up },
    ConditionExpression: isNew ? 'attribute_not_exists(pk)' : 'attribute_exists(pk)',
  }
}

/**
 * The UpdateItem renaming a saved ped, or null. Only where it exists.
 * ALREADY AttributeValues, like yubikeyUpdate.
 */
export function pedRenameInput(table, license, id, name, up) {
  const key = pedKey(license, id)
  const at = Number(up)
  if (!key || !isName(name) || !Number.isSafeInteger(at) || at < 0) return null
  return {
    TableName: table,
    Key: { pk: { S: key.pk }, sk: { S: key.sk } },
    UpdateExpression: 'SET #n = :n, #up = :up',
    ConditionExpression: 'attribute_exists(pk)',
    ExpressionAttributeNames: { '#n': 'n', '#up': 'up' },
    ExpressionAttributeValues: { ':n': { S: name }, ':up': { N: String(at) } },
  }
}

/** The UpdateItem giving a saved ped its headshot, or null. Only where it exists. */
export function pedShotInput(table, license, id, img) {
  const key = pedKey(license, id)
  if (!key || !isImage(img)) return null
  return {
    TableName: table,
    Key: { pk: { S: key.pk }, sk: { S: key.sk } },
    UpdateExpression: 'SET #img = :img',
    ConditionExpression: 'attribute_exists(pk)',
    ExpressionAttributeNames: { '#img': 'img' },
    ExpressionAttributeValues: { ':img': { S: img } },
  }
}

/** The BatchWriteItem deleting one saved ped, or null. A DeleteRequest, never DeleteItem. */
export function pedDeleteInput(table, license, id) {
  const key = pedKey(license, id)
  if (!key) return null
  return {
    RequestItems: {
      [table]: [{ DeleteRequest: { Key: { pk: { S: key.pk }, sk: { S: key.sk } } } }],
    },
  }
}

/** The UpdateItem writing the worn ped onto the profile row, or null. */
export function wornSetInput(table, license, worn) {
  if (typeof license !== 'string' || license === '' || !isWorn(worn)) return null
  return {
    TableName: table,
    Key: { pk: { S: license }, sk: { S: 'profile' } },
    UpdateExpression: 'SET #w = :w',
    ExpressionAttributeNames: { '#w': 'locker2' },
    ExpressionAttributeValues: { ':w': { S: worn } },
  }
}

/** One page of the listing: this player's `ped#` rows, oldest first. */
export function pedQueryInput(table, license, startKey) {
  if (typeof license !== 'string' || license === '') return null
  const input = {
    TableName: table,
    KeyConditionExpression: '#pk = :pk AND begins_with(#sk, :p)',
    ExpressionAttributeNames: { '#pk': 'pk', '#sk': 'sk' },
    ExpressionAttributeValues: { ':pk': { S: license }, ':p': { S: PED_PREFIX } },
    ScanIndexForward: true,
  }
  if (startKey) input.ExclusiveStartKey = startKey
  return input
}

/**
 * One listed item as Lua gets it, or null for a row this file did not write.
 * @param {Record<string, unknown>} item  unmarshalled
 */
export function pedFromItem(item) {
  const sk = typeof item?.sk === 'string' ? item.sk : ''
  if (!sk.startsWith(PED_PREFIX)) return null
  const id = sk.slice(PED_PREFIX.length)
  if (!isPedId(id) || !isName(item.n) || !isAppearance(item.a)) return null
  const out = { id, name: item.n, a: item.a, cr: Number(item.cr ?? 0), up: Number(item.up ?? 0) }
  if (isImage(item.img)) out.img = item.img
  return out
}

/** The worn record off the profile row: its string, or '' when there is none. */
export function wornFrom(row) {
  return isWorn(row?.locker2) ? row.locker2 : ''
}
