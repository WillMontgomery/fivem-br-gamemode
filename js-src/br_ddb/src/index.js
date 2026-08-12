import {
  DynamoDBClient,
  GetItemCommand,
  UpdateItemCommand,
} from '@aws-sdk/client-dynamodb'
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb'

import { isActive } from './ban.js'

/**
 * br_ddb -- the game server's read-only window onto DynamoDB.
 *
 * WHY THIS EXISTS AT ALL. The ban list lives in DynamoDB because Ringmaster
 * owns it, and the game server has to answer "is this license banned" at the
 * moment somebody connects. Routing that question through Ringmaster would make
 * every player's connection depend on a web console in another region being
 * awake -- so the game asks the database directly, and Ringmaster being down
 * costs you the admin panel rather than the server.
 *
 * IT EXPOSES A SHORT, NAMED LIST OF VERBS, and that is a security boundary
 * rather than a convenience. There is deliberately no generic "run this query"
 * primitive: a general-purpose DynamoDB bridge sitting inside the game server
 * is one careless commit away from a write path into the tables that decide who
 * is banned and who is an admin. Adding a verb here should feel like a
 * decision, because it is one.
 *
 * THE SPLIT THAT MATTERS IS NOT READ-VERSUS-WRITE, IT IS WHOSE TABLE.
 * Everything touching `ringmaster-*` -- bans, grants, the maintenance window --
 * is read-only here, because the console owns that data and the game server
 * only ever needs to ask it questions. Everything touching `br-*` is the game's
 * own, and it reads and writes freely: the server must never be unable to run
 * a match because a web console in another region is down.
 *
 * NO CREDENTIALS ANYWHERE. The SDK's default provider chain finds the EC2
 * instance role through IMDS on its own. Same rule as the Ringmaster box: if
 * this file ever needs an access key, something has gone wrong upstream.
 *
 * THE BUNDLE IS COMMITTED, THE SOURCE IS NOT SHIPPED. FXServer will not install
 * dependencies, and a `package.json` inside the resource makes its Node 16
 * build toolchain try to build the thing -- so the resource contains one
 * pre-bundled file and no manifest of its own. tools/pre-commit guards the
 * source and bundle drifting apart, the same way it does for the NUI.
 */

const REGION = GetConvar('br_ddb_region', 'us-east-2')
const TABLE_PREFIX = GetConvar('br_ddb_table_prefix', 'ringmaster-')

/**
 * The GAME's own tables, separate from Ringmaster's.
 *
 * The prefixes differ because the ownership does: `ringmaster-*` is the
 * console's data, which this resource only reads; `br-*` is the server's own,
 * which it reads and writes. Keeping them apart lets an IAM policy say exactly
 * that, rather than granting write on a wildcard that also covers the ban list
 * and the audit log.
 */
const TABLE_PREFIX_GAME = GetConvar('br_ddb_game_prefix', 'br-')

/**
 * How long a single lookup may take before we give up on it.
 *
 * LOAD-BEARING FOR THE CONNECT GATE. The ban check runs inside a FiveM
 * deferral, and a deferral that never resolves leaves the player staring at a
 * connecting screen forever -- a worse outcome than any ban decision. The
 * caller has its own timeout as well; this one exists so the SDK cannot sit on
 * a socket long after anybody stopped caring.
 */
const TIMEOUT_MS = 3000

let client = null

function ddb() {
  if (!client) {
    client = new DynamoDBClient({
      region: REGION,
      maxAttempts: 2,
      requestHandler: { requestTimeout: TIMEOUT_MS },
    })
  }
  return client
}

/** Reject rather than hang. */
function withTimeout(promise, ms) {
  return Promise.race([
    promise,
    new Promise((_, reject) =>
      setTimeout(() => reject(new Error(`timed out after ${ms}ms`)), ms),
    ),
  ])
}

/**
 * One point lookup, keyed on license.
 *
 * GetItem rather than Query or Scan, deliberately: the only question this
 * resource ever asks is about one specific license, and the IAM policy on the
 * game box grants GetItem alone. If this ever needs a Query, that is a
 * conversation about the policy, not a change to this function.
 */
async function getByKey(table, key, prefix) {
  const out = await withTimeout(
    ddb().send(
      new GetItemCommand({
        // The prefix is passed explicitly because the two table families have
        // different owners. Defaulting it silently made the first version of
        // profileFetch read the CONSOLE's table instead of the game's.
        TableName: `${prefix || TABLE_PREFIX}${table}`,
        Key: marshall(key),
        ConsistentRead: false,
      }),
    ),
    TIMEOUT_MS,
  )

  return out.Item ? unmarshall(out.Item) : null
}

/** The common case: bans and grants are both keyed on license. */
function getByLicense(table, license) {
  return getByKey(table, { license })
}

/**
 * Ban check. Answers on `br:ddb:banResult` with the same `req` it was given.
 *
 * FAILS OPEN, ALWAYS. Every error path -- no credentials, no network, a
 * throttle, a timeout, a malformed row -- answers `banned = false` and reports
 * the reason in `error`. A database that cannot be reached must not become a
 * server nobody can join: the failure mode of "a banned player gets in until
 * the link recovers" is strictly better than "nobody gets in at all", and the
 * caller logs the error loudly so it is not silent.
 */
on('br:ddb:banCheck', (req, license) => {
  const answer = (banned, extra) => {
    emit('br:ddb:banResult', req, banned, extra ?? {})
  }

  if (typeof license !== 'string' || license === '') {
    answer(false, { error: 'no license' })
    return
  }

  getByLicense('bans', license)
    .then((row) => {
      const now = Date.now()
      if (!isActive(row, now)) {
        answer(false, {})
        return
      }
      answer(true, {
        reason: String(row.reason ?? 'No reason recorded'),
        expiresAt: row.expiresAt ?? null,
        byName: String(row.byName ?? 'an admin'),
      })
    })
    .catch((e) => {
      console.log(`[br_ddb] ban check failed for ${license}: ${e.message}`)
      answer(false, { error: e.message })
    })
})

/**
 * Grants lookup, for the in-game admin surface that will consume it.
 *
 * READ-ONLY AND ADVISORY. The web console's authorisation happens entirely
 * console-side, against this same table; this exists so that admin actions
 * taken IN GAME have a permission source without inventing a second one. It is
 * not a cache with invalidation -- callers ask when they need to know.
 */
on('br:ddb:grantsFetch', (req, license) => {
  const answer = (scopes, extra) => {
    emit('br:ddb:grantsResult', req, scopes, extra ?? {})
  }

  if (typeof license !== 'string' || license === '') {
    answer([], { error: 'no license' })
    return
  }

  getByLicense('grants', license)
    .then((row) => {
      answer(Array.isArray(row?.scopes) ? row.scopes : [], {})
    })
    .catch((e) => {
      console.log(`[br_ddb] grants fetch failed for ${license}: ${e.message}`)
      answer([], { error: e.message })
    })
})

/**
 * The maintenance window, for the drain gate.
 *
 * POLLED, NOT PUSHED, and that is the whole reason this is a table read rather
 * than a command on the SSH channel. A pushed "start draining" flag lives in
 * memory and is forgotten the moment FXServer restarts — and a server that
 * restarted mid-window would quietly start accepting players again with nothing
 * anywhere to notice. Reading the row means the game re-derives the truth on
 * every poll and heals itself after any restart, on either side.
 *
 * Same table family, same read-only GetItem, same fail-open rule as the ban
 * check: an unreadable maintenance row means no drain, not a locked server.
 */
on('br:ddb:maintenance', (req) => {
  const answer = (w, extra) => {
    emit('br:ddb:maintenanceResult', req, w, extra ?? {})
  }

  getByKey('maintenance', { id: 'current' })
    .then((row) => {
      if (!row) {
        answer(null, {})
        return
      }
      // Projected to exactly what the game needs. The row carries more —
      // who cancelled it, when it was forced, the deploy mode — and none of
      // that changes what the server does at the door.
      answer(
        {
          state: String(row.state || ''),
          note: String(row.note || ''),
          drainStartsAt: Number(row.drainStartsAt || 0),
          createdByName: String(row.createdByName || 'an admin'),
          updateAvailable: Number(row.updateAvailable || 0),
        },
        {},
      )
    })
    .catch((e) => {
      console.log('[br_ddb] maintenance read failed: ' + e.message)
      answer(null, { error: e.message })
    })
})

/**
 * A player's stats profile.
 *
 * THE GAME OWNS THIS TABLE, unlike everything else br_ddb touches. `br-players`
 * is gameplay data the server both produces and depends on, so it reads and
 * writes directly and never asks Ringmaster — the console is a companion to the
 * server, not something the server can be made to need.
 *
 * PURCHASES ARE A SEPARATE ITEM under the same key. They are irreplaceable
 * (somebody paid), they are read on the connect path where latency strands
 * people on a loading screen, and they must not share a write path with
 * counters that update at the end of every match. `pk = license` /
 * `sk = 'profile' | 'purchases'` keeps them in one table without one write ever
 * touching the other.
 */
on('br:ddb:profileFetch', (req, license) => {
  const answer = (profile, extra) => {
    emit('br:ddb:profileResult', req, profile, extra ?? {})
  }

  if (typeof license !== 'string' || license === '') {
    answer(null, { error: 'no license' })
    return
  }

  getByKey('players', { pk: license, sk: 'profile' }, TABLE_PREFIX_GAME)
    .then((row) => answer(row ?? null, {}))
    .catch((e) => {
      console.log('[br_ddb] profile read failed: ' + e.message)
      answer(null, { error: e.message })
    })
})

/**
 * Apply a match result: add the deltas, stamp the new totals.
 *
 * AN ATOMIC ADD RATHER THAN READ-MODIFY-WRITE. Several matches end close
 * together on a busy server, and a read-then-write would have two of them load
 * the same totals and write back over each other — losing one match's worth of
 * everything, silently, in a way that only shows up as a player insisting they
 * had more kills than the profile says. DynamoDB's ADD does the arithmetic
 * server-side, so concurrent updates compose instead of racing.
 *
 * XP AND LEVEL ARE NOT COMPUTED HERE. The curve lives in Lua, where the summary
 * screen also needs it; this adds the earned XP and stores the level the caller
 * derived. One implementation of the curve rather than two that can disagree.
 *
 * A STATS FAILURE MUST NEVER STOP A MATCH — the rule br_stats has always run on,
 * carried over intact. Every failure path answers and logs; nothing throws into
 * the caller.
 */
on('br:ddb:statsApply', (req, license, deltas) => {
  const answer = (ok, extra) => {
    emit('br:ddb:statsResult', req, ok, extra ?? {})
  }

  if (typeof license !== 'string' || license === '') {
    answer(false, { error: 'no license' })
    return
  }

  const d = deltas || {}
  const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0)

  /**
   * An ALLOWLIST, not a loop over the payload. This runs on data that crossed
   * a runtime boundary, and a typo'd key should be dropped rather than quietly
   * creating an attribute nobody reads and nobody knows is there.
   */
  const adds = {
    xp: num(d.xp),
    // CURRENCY IS EARNED HERE AND NOWHERE ELSE, which is what keeps the market
    // honest: there is no path that adds balance except finishing a match. The
    // moment a second writer exists, "the currency is earned, never bought" is
    // a claim rather than a property.
    balance: num(d.balance),
    matches: num(d.matches),
    wins: num(d.wins),
    top10s: num(d.top10s),
    kills: num(d.kills),
    deaths: num(d.deaths),
    downs: num(d.downs),
    revives: num(d.revives),
    damageDealt: num(d.damageDealt),
    playtimeSec: num(d.playtimeSec),
    soloMatches: num(d.soloMatches),
    squadMatches: num(d.squadMatches),
  }

  const names = { '#lvl': 'level', '#nm': 'name', '#ls': 'lastMatchAt' }
  const values = {
    ':lvl': num(d.level),
    ':nm': String(d.name || ''),
    ':ls': num(d.at),
  }
  const addParts = []
  for (const [k, v] of Object.entries(adds)) {
    names[`#${k}`] = k
    values[`:${k}`] = v
    addParts.push(`#${k} :${k}`)
  }

  withTimeout(
    ddb().send(
      new UpdateItemCommand({
        TableName: `${TABLE_PREFIX_GAME}players`,
        Key: marshall({ pk: license, sk: 'profile' }),
        // SET for values that replace, ADD for values that accumulate.
        UpdateExpression: `SET #lvl = :lvl, #nm = :nm, #ls = :ls ADD ${addParts.join(', ')}`,
        ExpressionAttributeNames: names,
        ExpressionAttributeValues: marshall(values),
      }),
    ),
    TIMEOUT_MS,
  )
    .then(() => answer(true, {}))
    .catch((e) => {
      console.log('[br_ddb] stats write failed for ' + license + ': ' + e.message)
      answer(false, { error: e.message })
    })
})

/**
 * ONE ROW HOLDS THE WHOLE PLAYER, AND THAT IS A COST DECISION AS MUCH AS A
 * CORRECTNESS ONE.
 *
 * Balance, owned items, equipped choices and career stats all live on
 * `{pk: license, sk: 'profile'}` rather than being split across a `purchases`
 * row and a `profile` row. Two consequences, both wanted:
 *
 *   * CONNECT COSTS ONE READ. Everything the client needs to open the lobby
 *     arrives in a single GetItem. Split across two rows it would be two reads
 *     per join forever, on a project that is personally funded.
 *   * A PURCHASE IS ONE CONDITIONAL WRITE. Debiting the balance and granting
 *     the item are the same UpdateItem, so they cannot half-apply. Across two
 *     rows this would need a transaction to avoid charging somebody for an item
 *     they did not receive -- which is the worst outcome this path has.
 *
 * OWNERSHIP IS A STRING SET, so granting is idempotent at the storage layer:
 * ADDing an id that is already present is a no-op rather than a duplicate. The
 * condition below still refuses the second purchase, because being charged
 * twice for a no-op is exactly the bug this guards.
 */
const EQUIP_KINDS = ['character', 'chute', 'trail', 'weapon', 'banner', 'verdict']

/**
 * Everything about one player, in one read.
 *
 * FAILS TO AN EMPTY INVENTORY rather than to an error the caller has to think
 * about. A player whose row cannot be read gets the defaults -- which every
 * player owns implicitly anyway -- and plays a normal match. The alternative,
 * refusing to let somebody drop because DynamoDB was slow, is not a trade this
 * project makes anywhere else and will not start making here.
 */
on('br:ddb:inventoryFetch', (req, license) => {
  const answer = (inv, extra) => {
    emit('br:ddb:inventoryResult', req, inv, extra ?? {})
  }

  const empty = { balance: 0, owned: [], equipped: {}, level: 1, xp: 0 }

  if (typeof license !== 'string' || license === '') {
    answer(empty, { error: 'no license' })
    return
  }

  getByKey('players', { pk: license, sk: 'profile' }, TABLE_PREFIX_GAME)
    .then((row) => {
      if (!row) {
        answer(empty, {})
        return
      }

      // unmarshall turns a DynamoDB string set into a JS Set, which does not
      // survive the trip across the runtime boundary into Lua. Flatten it.
      const owned = row.owned instanceof Set ? Array.from(row.owned) : []

      const equipped = {}
      for (const kind of EQUIP_KINDS) {
        const v = row[`equip_${kind}`]
        if (typeof v === 'string' && v !== '') equipped[kind] = v
      }

      answer({
        balance: Number(row.balance ?? 0),
        owned,
        equipped,
        level: Number(row.level ?? 1),
        xp: Number(row.xp ?? 0),
      }, {})
    })
    .catch((e) => {
      console.log('[br_ddb] inventory read failed for ' + license + ': ' + e.message)
      answer(empty, { error: e.message })
    })
})

/**
 * Buy one item: debit and grant, atomically, or do neither.
 *
 * THE PRICE COMES FROM THE CALLER, AND THE CALLER IS THE SERVER. This file has
 * no access to BR.Config -- the catalogue is Lua -- so it cannot look a price
 * up. That is fine precisely because the only caller is server-side Lua, which
 * resolves the item through BR.Config.buyable() before it gets here. If a
 * client-supplied price ever reaches this function, the bug is upstream and it
 * is a serious one.
 *
 * THE CONDITION IS THE WHOLE FEATURE. Without it, two purchases racing would
 * both read an affordable balance and both succeed; with it, DynamoDB evaluates
 * affordability and non-ownership at write time and rejects the loser.
 */
on('br:ddb:purchase', (req, license, itemId, price) => {
  const answer = (ok, extra) => {
    emit('br:ddb:purchaseResult', req, ok, extra ?? {})
  }

  const id = String(itemId ?? '')
  const cost = Number(price)

  if (typeof license !== 'string' || license === '') {
    answer(false, { error: 'no license' })
    return
  }
  if (id === '' || !Number.isFinite(cost) || cost <= 0) {
    answer(false, { error: 'bad item or price' })
    return
  }

  withTimeout(
    ddb().send(
      new UpdateItemCommand({
        TableName: `${TABLE_PREFIX_GAME}players`,
        Key: marshall({ pk: license, sk: 'profile' }),
        UpdateExpression: 'ADD #bal :neg, #own :idset',
        // A missing `balance` attribute makes the comparison false rather than
        // treating it as zero, so a brand-new row cannot buy anything. Correct:
        // currency is earned by playing, and the first match seeds it.
        ConditionExpression:
          '#bal >= :cost AND (attribute_not_exists(#own) OR NOT contains(#own, :id))',
        ExpressionAttributeNames: { '#bal': 'balance', '#own': 'owned' },
        ExpressionAttributeValues: {
          ':neg': { N: String(-cost) },
          ':cost': { N: String(cost) },
          ':idset': { SS: [id] },
          ':id': { S: id },
        },
        ReturnValues: 'UPDATED_NEW',
      }),
    ),
    TIMEOUT_MS,
  )
    .then((out) => {
      const after = out.Attributes ? unmarshall(out.Attributes) : {}
      answer(true, { balance: Number(after.balance ?? 0) })
    })
    .catch((e) => {
      // A REFUSAL IS NOT A FAILURE, and the two must not read alike to the
      // player. The condition rejecting means "you cannot afford this" or "you
      // already own it"; anything else means the database is unhappy. One
      // extra read on the refusal path buys a message that is actually true.
      if (e.name === 'ConditionalCheckFailedException') {
        getByKey('players', { pk: license, sk: 'profile' }, TABLE_PREFIX_GAME)
          .then((row) => {
            const owned = row?.owned instanceof Set ? row.owned : new Set()
            if (owned.has(id)) {
              answer(false, { refused: 'already owned' })
            } else {
              answer(false, {
                refused: 'not enough currency',
                balance: Number(row?.balance ?? 0),
              })
            }
          })
          .catch(() => answer(false, { refused: 'cannot afford or already owned' }))
        return
      }
      console.log('[br_ddb] purchase failed for ' + license + ': ' + e.message)
      answer(false, { error: e.message })
    })
})

/**
 * Equip an owned item into its slot.
 *
 * SLOTS ARE FLAT ATTRIBUTES (`equip_chute`, `equip_trail`, ...) rather than a
 * nested map, because DynamoDB cannot SET a path inside a map that does not
 * exist yet -- so a nested `equipped.chute` would need the parent seeded first,
 * which is a second write and a race waiting to happen on a brand-new player.
 *
 * OWNERSHIP IS CHECKED AT WRITE TIME, not by the caller. `allowUnowned` exists
 * only for defaults, which every player owns implicitly and which therefore
 * appear in nobody's `owned` set. The caller establishes that from BR.Config;
 * the client never gets a say.
 */
on('br:ddb:equip', (req, license, kind, itemId, allowUnowned) => {
  const answer = (ok, extra) => {
    emit('br:ddb:equipResult', req, ok, extra ?? {})
  }

  const k = String(kind ?? '')
  const id = String(itemId ?? '')

  if (typeof license !== 'string' || license === '') {
    answer(false, { error: 'no license' })
    return
  }
  if (!EQUIP_KINDS.includes(k) || id === '') {
    answer(false, { error: 'bad slot or item' })
    return
  }

  const params = {
    TableName: `${TABLE_PREFIX_GAME}players`,
    Key: marshall({ pk: license, sk: 'profile' }),
    UpdateExpression: 'SET #eq = :id',
    ExpressionAttributeNames: { '#eq': `equip_${k}` },
    ExpressionAttributeValues: { ':id': { S: id } },
  }

  if (!allowUnowned) {
    params.ConditionExpression = 'contains(#own, :id)'
    params.ExpressionAttributeNames['#own'] = 'owned'
  }

  withTimeout(ddb().send(new UpdateItemCommand(params)), TIMEOUT_MS)
    .then(() => answer(true, {}))
    .catch((e) => {
      if (e.name === 'ConditionalCheckFailedException') {
        answer(false, { refused: 'not owned' })
        return
      }
      console.log('[br_ddb] equip failed for ' + license + ': ' + e.message)
      answer(false, { error: e.message })
    })
})

/**
 * A self-test, so "can this box reach DynamoDB at all" is one command rather
 * than a guess. Reads a license that will never exist -- a successful lookup
 * returning nothing proves credentials, network and permissions all work,
 * without depending on any particular row being present.
 */
on('br:ddb:selftest', (req) => {
  const started = Date.now()
  getByLicense('bans', 'license:0000000000000000000000000000000000000000')
    .then(() => {
      emit('br:ddb:selftestResult', req, true, {
        ms: Date.now() - started,
        region: REGION,
        prefix: TABLE_PREFIX,
      })
    })
    .catch((e) => {
      emit('br:ddb:selftestResult', req, false, {
        ms: Date.now() - started,
        region: REGION,
        prefix: TABLE_PREFIX,
        error: e.message,
      })
    })
})

console.log(
  `[br_ddb] ready -- region ${REGION}, ${TABLE_PREFIX}* read-only (bans, grants, maintenance),`
    + ` ${TABLE_PREFIX_GAME}* read/write (profile, inventory, stats)`,
)
