import { randomUUID } from 'node:crypto'
import { mkdir, readdir, readFile, rm, stat as fsStat } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import {
  BatchWriteItemCommand,
  DynamoDBClient,
  GetItemCommand,
  PutItemCommand,
  UpdateItemCommand,
} from '@aws-sdk/client-dynamodb'
import { S3Client, PutObjectCommand } from '@aws-sdk/client-s3'
import { marshall, unmarshall } from '@aws-sdk/util-dynamodb'

import { artifactNames, isSpoolFile } from './artifacts.js'
import { isActive } from './ban.js'
import { buildIncidentItem } from './incident.js'
import { projectVerdict } from './verdict.js'

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
 * WITH ONE DELIBERATE EXCEPTION, ADDED 2026-08-14: `ringmaster-incidents` is
 * APPENDABLE from here. The game may file a case, and still has no access at all
 * to grants, bans or the audit log.
 *
 * That is the narrowest grant that makes the pipeline work, and the narrowness is
 * the point. The alternative was sending incidents to the console over the event
 * channel and letting it write -- but that channel drops batches silently after
 * four attempts, and an incident lost that way is unrecoverable because the
 * evidence buffer behind it is discarded at match end. So the game writes the row
 * and the event carries only an id.
 *
 * AND SINCE 2026-08-17 IT CAN READ ONE BACK, but only the verdict, and only by an
 * id it minted itself. See `br:ddb:incidentVerdict` near the bottom of this file:
 * that verb is the entire second exception, it names the one table it touches,
 * and it projects four attributes off the row rather than fetching it. The
 * sentence that used to sit here -- "the game may file a case and cannot read one
 * back" -- is no longer true, and it was load-bearing enough in the console's
 * docs/aws-setup.md that it is worth saying so plainly rather than quietly
 * editing it out.
 *
 * AND SINCE 2026-08-20 IT ALSO REACHES S3, which is the first thing in this file
 * that is not a database at all. `s3:PutObject` on
 * `royale-incidents-bucket/incidents/*` -- write only, one bucket, one prefix --
 * carries the screenshots an incident is captured with. See the artifacts
 * section near the bottom for why it lives in this resource and not another one,
 * and src/artifacts.js for why the game cannot choose a key.
 *
 * WHAT A COMPROMISED GAME BOX CAN DO WITH THIS: file noise, read the verdicts on
 * cases it filed, and write up to nine images per case it filed into a prefix it
 * cannot leave. What it still cannot do: enumerate open cases (there is no Query
 * or Scan in this file), read who is an admin, discover who is banned, alter a
 * verdict, overwrite an existing incident -- the write is conditional on the id
 * being absent -- or read back, list or delete a single object in that bucket.
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

/**
 * A number, or zero. Used everywhere data crosses the Lua boundary.
 *
 * Lua numbers arrive as JS numbers, but a nil arrives as undefined and a
 * malformed field arrives as whatever it was -- and DynamoDB refuses NaN with a
 * serialisation error that takes the whole write with it. Coercing at the edge
 * means one bad field costs that field rather than the item.
 */
const num = (v) => (Number.isFinite(Number(v)) ? Number(v) : 0)

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
 * GetItem rather than Query or Scan, deliberately: every question this resource
 * asks is about one specific key it already holds -- a license, or an incident id
 * it minted itself. On the `ringmaster-*` family the game box's IAM policy grants
 * GetItem (broadly, since 2026-08-17) and PutItem on `ringmaster-incidents`
 * alone. THERE IS STILL NO QUERY AND NO SCAN ANYWHERE IN THIS FILE, which is the
 * property that stops a compromised box enumerating anything, and it is worth
 * more than the table list now that the read grant is wider than the code. If
 * this ever needs a Query, that is a conversation about the policy, not a change
 * to this function.
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
 * MATCH HISTORY: one item per participant per match, written as one batch.
 *
 * WHY IT CANNOT RIDE IN THE ADD ABOVE. `statsApply` targets ONE item -- the
 * player's `sk = 'profile'` aggregate -- and DynamoDB has no way to update that
 * item and create a different one in the same operation. So this is a second
 * write, and the two can diverge: the aggregate can land while this fails.
 *
 * THAT DIVERGENCE IS ACCEPTED ON PURPOSE, and the direction of the dependency
 * is the whole design. The aggregate stays the source of truth for the profile
 * numbers a player sees; the history row is a RECORD, and a missing record is a
 * gap in a moderation aid rather than a player losing progression. Nothing here
 * can fail a match, fail the aggregate, or make the caller wait -- same rule
 * br_stats has always run on.
 *
 * KEYED `{pk: license, sk: 'match#<endedAt>#<matchId>'}`, under the same
 * partition as the profile. That makes "this player's recent matches, newest
 * first" a plain Query with `ScanIndexForward: false` and a `Limit` -- no
 * secondary index to provision, no scan, and one partition per player so the
 * read is as cheap as the profile lookup beside it.
 *
 * BATCHED, BECAUSE THE DATA ALREADY ARRIVES AS AN ARRAY. `BR.Match.publishResults`
 * builds every participant's row and fires them together, so the caller has the
 * whole match in hand and there is nothing to cache or accumulate. A 48-player
 * match costs TWO calls here (25 + 23) instead of 48.
 *
 * RETRYING UNPROCESSED ITEMS IS SAFE HERE AND WOULD NOT BE ABOVE. #132 exists
 * because an atomic ADD has no compensating write, so a retry that lands twice
 * doubles somebody's XP. These are PutItems under a key derived entirely from
 * the match -- writing the same row twice produces the same row. Idempotent by
 * construction, so DynamoDB's own "I was too busy, here are the ones I did not
 * take" answer can simply be handed back to it.
 */
const HISTORY_TABLE = `${TABLE_PREFIX_GAME}players`

/** DynamoDB's hard limit on one BatchWriteItem. Not a tuning knob. */
const HISTORY_BATCH = 25

/**
 * An ALLOWLIST, like the deltas above and for the same reason: this data
 * crossed a runtime boundary, and a typo'd key should be dropped rather than
 * quietly creating an attribute nobody reads and nobody knows is there.
 */
const HISTORY_NUMBERS = [
  'matchId',
  'endedAt',
  'placement',
  'total',
  'kills',
  'downs',
  'revives',
  'damage',
  'survivedMs',
  'xpEarned',
  'voltsEarned',
]

/**
 * One row -> one item, or null if it is not keyable.
 *
 * A ROW WITH NO LICENSE IS DROPPED RATHER THAN GUESSED AT. The same rule
 * br_stats applies before it gets here: a record filed under a key somebody
 * invented is worse than no record.
 */
function historyItem(r) {
  const license = typeof r?.license === 'string' ? r.license : ''
  const sk = typeof r?.sk === 'string' ? r.sk : ''

  // The prefix is asserted rather than built here, because the CALLER owns the
  // sort-key format -- it is the thing the console's Query does begins_with on.
  // Building it in two places is how the two come to disagree.
  if (license === '' || !sk.startsWith('match#')) return null

  const item = {
    pk: license,
    sk,
    mode: String(r.mode ?? ''),
    // NOT `placement === 1`. The last squad standing can be taken by the storm:
    // they place first and they died, and a match with no survivors has no
    // winner (#133). The caller decides this from the `died` flag it already
    // carries, so there is one implementation of the rule rather than three.
    won: r.won === true,
  }
  for (const k of HISTORY_NUMBERS) item[k] = num(r[k])

  return item
}

/**
 * One batch, with a single retry of whatever DynamoDB declined to take.
 *
 * `UnprocessedItems` is the NORMAL answer under throttling, not an error -- the
 * call succeeds and hands back the leftovers. Ignoring it would lose rows
 * silently on exactly the busy evening when the most matches are ending.
 *
 * @returns {Promise<number>} how many items are still unwritten
 */
async function writeHistoryBatch(items) {
  let pending = items

  for (let attempt = 0; attempt < 2 && pending.length > 0; attempt++) {
    const out = await withTimeout(
      ddb().send(
        new BatchWriteItemCommand({
          RequestItems: {
            [HISTORY_TABLE]: pending.map((Item) => ({ PutRequest: { Item } })),
          },
        }),
      ),
      TIMEOUT_MS,
    )

    const left = out.UnprocessedItems?.[HISTORY_TABLE] ?? []
    pending = left.map((w) => w.PutRequest.Item)
  }

  return pending.length
}

on('br:ddb:historyPut', (req, rows) => {
  const answer = (ok, extra) => {
    emit('br:ddb:historyResult', req, ok, extra ?? {})
  }

  if (!Array.isArray(rows) || rows.length === 0) {
    answer(true, { written: 0, dropped: 0 })
    return
  }

  // DUPLICATE KEYS FAIL THE WHOLE BATCH, not just the duplicate: DynamoDB
  // rejects a BatchWriteItem containing two writes to one key with a
  // ValidationException. One repeated license would therefore cost 25 rows, so
  // it is worth one Set to make that impossible.
  const seen = new Set()
  const items = []
  let dropped = 0

  for (const r of rows) {
    const item = historyItem(r)
    if (!item) {
      dropped++
      continue
    }
    const key = `${item.pk} ${item.sk}`
    if (seen.has(key)) {
      dropped++
      continue
    }
    seen.add(key)
    items.push(marshall(item, { removeUndefinedValues: true }))
  }

  if (items.length === 0) {
    answer(true, { written: 0, dropped })
    return
  }

  const batches = []
  for (let i = 0; i < items.length; i += HISTORY_BATCH) {
    batches.push(items.slice(i, i + HISTORY_BATCH))
  }

  // allSettled, NOT all. The batches are independent writes and a rejection in
  // the first must not throw away what the second reports -- "23 of 48 landed"
  // is a fact worth having in the log, and Promise.all would discard it.
  Promise.allSettled(batches.map((b) => writeHistoryBatch(b)))
    .then((results) => {
      let unwritten = 0
      let error = null

      results.forEach((res, i) => {
        if (res.status === 'fulfilled') {
          unwritten += res.value
        } else {
          unwritten += batches[i].length
          error = error ?? res.reason?.message ?? 'unknown'
        }
      })

      const written = items.length - unwritten
      if (unwritten > 0) {
        console.log(
          `[br_ddb] match history: ${written}/${items.length} rows written`
            + `, ${unwritten} lost${error ? ` -- ${error}` : ''}`,
        )
      }
      answer(unwritten === 0, { written, unwritten, dropped, error })
    })
    .catch((e) => {
      // Not reachable through allSettled, and here anyway: the one thing this
      // verb must never do is throw into a match-end handler.
      console.log('[br_ddb] match history write failed: ' + e.message)
      answer(false, { written: 0, unwritten: items.length, dropped, error: e.message })
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
 * THE ONE WRITE INTO A `ringmaster-*` TABLE, and the reasoning for every part of
 * it is in the header. Files an incident and answers with the id it was given.
 *
 * THE ID IS MINTED HERE AND NEVER ACCEPTED FROM THE CALLER, the same rule the
 * console's own `open()` states: a caller-supplied id is a way to overwrite
 * somebody else's case. Lua has no UUID source and could not be given one --
 * BR.Rng is xoshiro128** seeded deterministically on purpose, so that client and
 * server derive the same loot layout, which makes it precisely the wrong thing to
 * name a record with.
 *
 * THE TOKEN IS WHAT MAKES THE CALLER'S RETRY SAFE, and it is the subtle part.
 * br_ringmaster retries a failed write for ~30s, and the failure it is most
 * likely riding out is a LOST ANSWER rather than a lost write: the row landed and
 * the reply did not. A fresh UUID per attempt would file the same case five times
 * under five ids, and a reviewer would have no way to tell that from the player
 * doing it five times. So the caller passes a token that is stable across its own
 * retries, this memoises one UUID per token, and the write is conditional on that
 * id being absent -- so the second attempt is refused by DynamoDB and reported as
 * success, because the row it wanted is there.
 */
const idForToken = new Map()
const MAX_TOKENS = 256

function mintId(token) {
  const key = typeof token === 'string' && token !== '' ? token : null
  // No token means no idempotency -- correct rather than convenient: a caller
  // that did not identify its attempt cannot be given a guarantee about it.
  if (key === null) return randomUUID()

  const known = idForToken.get(key)
  if (known) return known

  const id = randomUUID()
  idForToken.set(key, id)

  // Bounded, oldest first. Map preserves insertion order, so this drops the
  // tokens whose retry windows are long closed. 256 is far more than the handful
  // of writes that can be in flight across a 30-second retry budget.
  if (idForToken.size > MAX_TOKENS) {
    idForToken.delete(idForToken.keys().next().value)
  }
  return id
}

on('br:ddb:putIncident', (req, token, payload) => {
  const answer = (ok, extra) => {
    emit('br:ddb:incidentResult', req, ok, extra ?? {})
  }

  const incidentId = mintId(token)
  const built = buildIncidentItem(incidentId, payload, Date.now())

  if (built.error) {
    // A MALFORMED PAYLOAD IS NOT WORTH RETRYING and the caller must be able to
    // tell. `retryable: false` stops br_ringmaster spending 30 seconds on a bug
    // that five more attempts cannot fix -- and the case is genuinely lost, which
    // is why the caller logs this one loudly.
    console.log(`[br_ddb] incident refused: ${built.error}`)
    answer(false, { error: built.error, retryable: false })
    return
  }

  withTimeout(
    ddb().send(
      new PutItemCommand({
        TableName: `${TABLE_PREFIX}incidents`,
        Item: marshall(built.item, { removeUndefinedValues: true }),
        // APPEND, NEVER OVERWRITE. Without this the verb could replace an
        // existing case -- including a resolved one, erasing a verdict and the
        // admin who made it. With it, the worst a repeat can do is be refused.
        ConditionExpression: 'attribute_not_exists(incidentId)',
      }),
    ),
    TIMEOUT_MS,
  )
    .then(() => answer(true, { incidentId }))
    .catch((e) => {
      if (e.name === 'ConditionalCheckFailedException') {
        // THE ROW IS ALREADY THERE, WHICH IS THE OUTCOME WE WANTED. Only
        // reachable via a memoised token, i.e. a retry after a lost answer.
        // Reporting this as failure would make the caller retry a write that has
        // already succeeded, forever.
        answer(true, { incidentId, duplicate: true })
        return
      }
      console.log(`[br_ddb] incident write failed for ${incidentId}: ${e.message}`)
      answer(false, { error: e.message, retryable: true })
    })
})

/**
 * ═══ THE SECOND READ INTO A `ringmaster-*` TABLE, AND THE ONLY ONE ═══
 *
 * THIS IS THE WHOLE OF THE NEW GRANT AND IT IS DELIBERATELY ONE FUNCTION.
 * The owner added `dynamodb:GetItem` on `ringmaster-*` on 2026-08-17, with the
 * words "this is deliberately broad, I know". That prefix covers `audit`,
 * `bans`, `grants`, `incidents`, `sessions`, `telemetry` and `to-gameserver`.
 * Nothing in this file reads six of those seven, and nothing should: the game
 * box previously held GetItem on `bans` and `grants` alone, and the reason that
 * exception was written down rather than buried is that a policy nobody can
 * summarise is a policy nobody can narrow.
 *
 * SO THE GRANT IS BROAD AND THE CODE IS NOT. Exactly one table is named here
 * and it is named once. When somebody comes to tighten the policy back to a
 * list of ARNs, the answer is this file's table list and nothing else:
 *
 *     ringmaster-bans        GetItem   the connect gate
 *     ringmaster-grants      GetItem   in-game admin scopes
 *     ringmaster-maintenance GetItem   the drain gate
 *     ringmaster-incidents   GetItem   THIS, and PutItem above
 *
 * IT IS NARROWER THAN THE GRANT IN THREE MORE WAYS, all of them enforced here
 * rather than promised:
 *
 *   * GetItem, keyed on `incidentId`. There is still no Query and no Scan
 *     anywhere in this file, so a compromised game box cannot enumerate cases.
 *   * BY AN ID IT MINTED ITSELF. Every id this verb is ever called with came
 *     back from `putIncident` on this same box. It cannot discover an id it did
 *     not file, so "read back cases whose ids it knows" means "read back its own".
 *   * A PROJECTION, NOT THE ROW. `ProjectionExpression` asks for four
 *     attributes. The evidence, the chat log, the kill log, the reporter, the
 *     subject, the admin's written resolution and the capture keys are all on
 *     that item and NONE of them crosses into the game server. What comes back
 *     is "decided or not, and did anything happen" -- which is the entire
 *     question #168 asks, and the projection is what makes that a fact rather
 *     than a description.
 *
 * WHAT IT COSTS, STATED PLAINLY so nobody has to rediscover it: the property
 * "there is no read of any kind on this table" is gone, and with it the
 * sentence in the console's docs/aws-setup.md that a compromised game box
 * "cannot alter a verdict" -- it still cannot alter one, but it can now see
 * one. That was the price of #168 and the owner paid it knowingly.
 *
 * FAILS CLOSED, unlike the ban gate. The ban check fails OPEN because an
 * unreachable database must not become a server nobody can join. Here the
 * opposite is right: an unreadable incident answers "not settled", the claim
 * stays on the queue, and the next sweep asks again. Paying on a failed read
 * would credit 250 Volts against a verdict nobody has seen.
 */
on('br:ddb:incidentVerdict', (req, incidentId) => {
  const answer = (ok, extra) => {
    emit('br:ddb:verdictResult', req, ok, extra ?? {})
  }

  const id = typeof incidentId === 'string' ? incidentId : ''
  if (id === '') {
    answer(false, { error: 'no incidentId' })
    return
  }

  withTimeout(
    ddb().send(
      new GetItemCommand({
        TableName: `${TABLE_PREFIX}incidents`,
        Key: marshall({ incidentId: id }),
        /**
         * FOUR ATTRIBUTES. `state` is a DynamoDB reserved word and has to be
         * aliased; the other three are not, and are named literally so this
         * list reads as the list it is.
         *
         * DELIBERATELY NOT `resolution`, `resolvedByName`, `reporterLicense`
         * or `subjectLicense`. The game already knows who it told us about;
         * what it must not gain is a way to read a moderator's prose or to
         * confirm an identity it did not already hold.
         */
        ProjectionExpression: 'incidentId, #st, verdict, resolvedAt',
        ExpressionAttributeNames: { '#st': 'state' },
        // Eventually consistent, like every other read here. A verdict that is
        // one sweep late is paid one sweep late.
        ConsistentRead: false,
      }),
    ),
    TIMEOUT_MS,
  )
    .then((out) => {
      const row = out.Item ? unmarshall(out.Item) : null
      answer(true, projectVerdict(row))
    })
    .catch((e) => {
      console.log(`[br_ddb] verdict read failed for ${id}: ${e.message}`)
      answer(false, { error: e.message })
    })
})

/**
 * ═══ ARTIFACTS -- THE ONLY THING IN THIS FILE THAT IS NOT DYNAMODB ═══
 *
 * WHY IT IS HERE AT ALL, since the resource is called br_ddb. Because the thing
 * that makes this resource able to reach AWS is not the DynamoDB client, it is
 * the EC2 instance role the SDK's provider chain finds through IMDS -- and a
 * second resource holding a second copy of the SDK to use the same role would
 * be a second bundle to keep current and a second place to audit. The owner's
 * framing on 2026-08-20: adding `s3:PutObject` scoped to one bucket and one
 * prefix "is the same pattern already in use, not a new class of trust."
 *
 * IT IS STILL TWO NAMED VERBS AND NOT A FILE BRIDGE. There is no verb here that
 * takes a path, a bucket, a key or a body. The game passes an incident id, a
 * frame number and an encoding; everything else is derived in artifacts.js and
 * validated before it is used. A compromised game box can write nine objects
 * per incident it filed, under names it cannot choose, into a prefix it cannot
 * leave -- and cannot read one back, because the grant is PutObject alone.
 *
 * ═══ THE IMAGE BYTES DO NOT CROSS THE LUA BOUNDARY ═══
 *
 * `screenshot-basic`'s server export takes a `fileName`, and when it is set the
 * client's upload is moved to that path on the game box instead of being handed
 * back as a base64 data URI. So the frame lands on disk, this file reads it, and
 * the only things that ever cross between Lua and JS are three short scalars.
 * Its own README says of the data-URI form: "Please don't send this through
 * _any_ server events."
 *
 * ═══ AND THE DISK IS BOUNDED, BECAUSE A FULL ONE IS WORSE THAN A LOST FRAME ═══
 *
 * The spool is swept on every request and wiped at start, only ever deletes
 * names artifacts.js could have produced, and refuses to hand out a path once it
 * is over its file or byte cap. Refusing costs a screenshot. Not refusing costs
 * the game server.
 */

/**
 * THE BUCKET, HARD-CODED, ON PURPOSE (operator, 2026-08-20): "Public access is
 * disabled so you can hard-code that bucket in." It is not a secret -- the name
 * grants nothing without credentials -- and the only thing that would make a
 * rename expensive is a literal at every call site, so there is exactly one.
 */
const ARTIFACT_BUCKET = GetConvar('br_artifacts_bucket', 'royale-incidents-bucket')

/**
 * Where a frame waits between landing on disk and reaching the bucket.
 *
 * A DEDICATED DIRECTORY, NEVER THE RESOURCE'S OWN. Resources are rsynced by
 * tools/deploy.sh and re-read on restart; a stray image inside one is a file the
 * deploy will argue with. The default is under the OS temp directory, which is
 * where a file whose whole life is measured in seconds belongs.
 */
const SPOOL_DIR = GetConvar('br_artifacts_dir', join(tmpdir(), 'br_artifacts'))

/**
 * The ceilings, and they are deliberately small.
 *
 * Nine frames per incident at a few hundred kilobytes each is a couple of
 * megabytes for the worst case the design allows, and the spool holds a file for
 * as long as one upload takes. Anything approaching these numbers means uploads
 * are failing or clients are delivering late, and in both of those states the
 * right answer is to stop taking pictures rather than to keep writing.
 */
const SPOOL_MAX_FILES = 32
const SPOOL_MAX_BYTES = 32 * 1024 * 1024

/**
 * A frame nobody is waiting for any more.
 *
 * THIS EXISTS BECAUSE `screenshot-basic` HAS NO TIMEOUT. Its server half holds
 * the upload token open forever, so a client that finally uploads three minutes
 * after the game side stopped waiting still writes a file here -- with no
 * callback left to consume it. Ninety seconds is comfortably past the game's own
 * 15-second wait and comfortably short of anything that could accumulate.
 */
const SPOOL_STALE_MS = 90_000

/** The largest frame we are willing to move. A webp screenshot is a fraction of
 * this; the cap is here so a client that uploads something absurd costs one
 * refused frame rather than the disk. */
const ARTIFACT_MAX_BYTES = 8 * 1024 * 1024

/**
 * Longer than the 3 seconds a DynamoDB point lookup gets.
 *
 * An artifact is a few hundred kilobytes leaving the box, not a keyed read, and
 * nothing is waiting on it -- no player is on a connecting screen and no match
 * tick is blocked. The game side has already stopped caring by the time this
 * matters.
 */
const ARTIFACT_TIMEOUT_MS = 15_000

let s3 = null

function s3client() {
  if (!s3) {
    // SAME REGION AND SAME CREDENTIAL CHAIN AS THE DYNAMODB CLIENT ABOVE.
    // No keys, no profile, no config file -- the instance role, found by the
    // provider chain, exactly as `ddb()` does it.
    s3 = new S3Client({
      region: REGION,
      maxAttempts: 2,
      requestHandler: { requestTimeout: ARTIFACT_TIMEOUT_MS },
    })
  }
  return s3
}

/**
 * Remove what nobody is coming back for, and report what is left.
 *
 * BY PATTERN, NOT BY DIRECTORY. `isSpoolFile` accepts only names this resource
 * could have produced, so a `br_artifacts_dir` pointed somewhere real by mistake
 * cannot delete anything that was not ours. That is the whole reason the check
 * is a function in artifacts.js with tests on it.
 *
 * @param {number} olderThanMs  delete files last modified more than this ago;
 *                              0 wipes every spool file, for a fresh start
 * @returns {Promise<{files: number, bytes: number, removed: number}>}
 *          `files` and `bytes` describe what SURVIVED
 */
async function sweepSpool(olderThanMs) {
  await mkdir(SPOOL_DIR, { recursive: true })

  let names = []
  try {
    names = await readdir(SPOOL_DIR)
  } catch {
    return { files: 0, bytes: 0, removed: 0 }
  }

  const cutoff = Date.now() - olderThanMs
  let files = 0
  let bytes = 0
  let removed = 0

  for (const name of names) {
    if (!isSpoolFile(name)) continue
    const path = join(SPOOL_DIR, name)
    try {
      const st = await fsStat(path)
      if (st.mtimeMs <= cutoff) {
        await rm(path, { force: true })
        removed += 1
        continue
      }
      files += 1
      bytes += st.size
    } catch {
      // Raced with its own upload deleting it. Nothing to count and nothing
      // to say.
    }
  }

  return { files, bytes, removed }
}

/**
 * NOTHING IN THE SPOOL SURVIVES A RESTART, and nothing should. Every file in
 * there belongs to a capture whose Lua-side callback died with the previous
 * process -- it will never be uploaded, and it will never be swept by age
 * because the sweeper only runs when a capture is requested. So the first thing
 * this resource does is empty it.
 */
sweepSpool(0)
  .then(({ removed }) => {
    if (removed > 0) {
      console.log(`[br_ddb] artifacts: cleared ${removed} orphaned frame(s) at start`)
    }
  })
  .catch((e) => {
    console.log(`[br_ddb] artifacts: spool unavailable at ${SPOOL_DIR}: ${e.message}`)
  })

/**
 * "Where do I put frame N of incident X?"
 *
 * ASKED BEFORE THE PICTURE IS TAKEN, so a spool that is full, missing or
 * unwritable costs a screenshot that was never requested rather than a file
 * with nowhere to go. The game treats a refusal here exactly as it treats a
 * client that never answers: one frame missing, which is a normal outcome.
 */
on('br:ddb:artifactBegin', (req, incidentId, index, encoding) => {
  const answer = (ok, extra) => {
    emit('br:ddb:artifactResult', req, ok, extra ?? {})
  }

  const names = artifactNames(incidentId, index, encoding)
  if (names.error) {
    answer(false, { error: names.error })
    return
  }

  sweepSpool(SPOOL_STALE_MS)
    .then(({ files, bytes }) => {
      if (files >= SPOOL_MAX_FILES || bytes >= SPOOL_MAX_BYTES) {
        // LOUD, because this one IS a fault. Everything else in this feature
        // fails quietly because it is somebody else's machine; a spool at its
        // ceiling means uploads are not draining on OURS.
        console.log(
          `[br_ddb] artifacts: spool full (${files} files, ${bytes} bytes) -- refusing`,
        )
        answer(false, { error: 'spool full' })
        return
      }
      answer(true, { key: names.key, path: join(SPOOL_DIR, names.file) })
    })
    .catch((e) => answer(false, { error: e.message }))
})

/**
 * "It landed. Put it in the bucket."
 *
 * THE PATH IS RE-DERIVED, NOT RECEIVED. The game is told a path by
 * `artifactBegin` so it can hand it to `screenshot-basic`, and it is never asked
 * for it back -- this rebuilds it from the same id, index and encoding. So there
 * is no way to name a file for this verb to read.
 *
 * THE LOCAL COPY IS DELETED EITHER WAY, and that is the decision worth stating.
 * A failed upload could be retried instead, but retrying means keeping the file,
 * and the case that accumulates silently is precisely the failing one -- a
 * bucket that is unreachable for an hour would leave an hour of frames on the
 * disk of a machine players are connected to. The frame is already the most
 * disposable thing in the pipeline: the incident row is durable without it, a
 * partial set is normal, and two more frames are scheduled behind this one. So
 * the disk wins and the frame is dropped.
 *
 * WHAT IS NOT DROPPED: the SDK's own two attempts, which cover the blip that a
 * retry loop would mostly be catching anyway.
 */
on('br:ddb:artifactPut', (req, incidentId, index, encoding, capturedAt) => {
  const answer = (ok, extra) => {
    emit('br:ddb:artifactResult', req, ok, extra ?? {})
  }

  const names = artifactNames(incidentId, index, encoding)
  if (names.error) {
    answer(false, { error: names.error })
    return
  }

  const path = join(SPOOL_DIR, names.file)

  /**
   * SERVER TIME, AND IT IS NOT DEFAULTED TO `Date.now()`.
   *
   * The whole reason this timestamp exists is that the subject's clock is not
   * evidence, and the game samples `os.time()` on this box at the moment it
   * decides to ask for the frame. Falling back to the upload time would quietly
   * replace "when the picture was asked for" with "when it finished arriving" --
   * two different facts, in one field, telling nobody which they had. A value
   * that did not survive the crossing is refused instead.
   */
  const at = Number(capturedAt)
  if (!Number.isFinite(at) || at <= 0) {
    rm(path, { force: true }).catch(() => {})
    answer(false, { error: 'bad capturedAt' })
    return
  }

  const cleanup = () => rm(path, { force: true }).catch(() => {})

  fsStat(path)
    .then((st) => {
      if (!st.isFile() || st.size === 0) throw new Error('empty frame')
      if (st.size > ARTIFACT_MAX_BYTES) throw new Error(`frame too large (${st.size})`)
      return readFile(path)
    })
    .then((body) =>
      withTimeout(
        s3client().send(
          new PutObjectCommand({
            Bucket: ARTIFACT_BUCKET,
            Key: names.key,
            Body: body,
            /**
             * SET, NOT INFERRED. S3 defaults an object with no type to
             * `application/octet-stream`, and the console renders these in an
             * `<img>` through a presigned GET -- a browser handed that type
             * offers a download instead of drawing the image, and the admin sees
             * what looks exactly like a screenshot that was never taken.
             */
            ContentType: names.contentType,
            /**
             * THE TIME TRAVELS WITH THE OBJECT, and this is the whole answer to
             * "where does the timestamp live".
             *
             * NOT IN DYNAMODB, because it cannot be: the game's grant on
             * `ringmaster-incidents` is PutItem conditional on the id being
             * absent, so it can file a case and cannot reach inside one. The
             * row's `captureKeys` is written `[]` at filing time and the game
             * has no way to add to it afterwards.
             *
             * NOT IN THE KEY, because a key carrying a timestamp is a key that
             * cannot be guessed -- and the console holds GetObject with no
             * ListBucket, so a key it cannot derive is a frame it cannot find.
             *
             * SO: METADATA. `s3:GetObject` covers HEAD as well as GET, so the
             * console reads the capture time from the same request that fetches
             * the image, with no second lookup and no second source of truth.
             * Values are ASCII decimal strings because that is all object
             * metadata carries.
             */
            Metadata: {
              'incident-id': incidentId,
              index: String(index),
              'captured-at': String(Math.trunc(at)),
            },
          }),
        ),
        ARTIFACT_TIMEOUT_MS,
      ).then(() => body.length),
    )
    .then((bytes) => {
      cleanup()
      answer(true, { key: names.key, bytes })
    })
    .catch((e) => {
      cleanup()
      console.log(`[br_ddb] artifact ${names.key} not stored: ${e.message}`)
      answer(false, { error: e.message })
    })
})

/**
 * ═══ THE REWARD LEDGER -- ALL OF IT ON THE GAME'S OWN TABLE ═══
 *
 * #168 pays 250 Volts to a reporter, and to every corroborator, when an
 * incident resolves with an action taken. The verdict arrives HOURS after the
 * report and often after a deploy, so "remember who to pay" cannot live in Lua
 * memory: a restart between the report and the admin's decision would lose the
 * debt silently, with nothing anywhere recording that it was owed. That is the
 * exact failure the console's own notes warn about, and it is the reason this
 * queue is durable.
 *
 * ONE ITEM HOLDS THE WHOLE QUEUE, and it is not a hot partition worth worrying
 * about: it is written once per report filed, which on a healthy server is a
 * handful a week.
 *
 *     {pk: 'br:reportaward', sk: 'queue'}
 *         ids                  SS   incidents awaiting a verdict
 *         p_<incidentId>       SS   the licenses owed for that incident
 *         t_<incidentId>       N    when it was first claimed, for the age cap
 *
 * WHY NOT ONE ITEM PER INCIDENT: because finding them again would need a Query,
 * and there is no Query anywhere in this file. Keeping the queue in one item
 * makes the sweep a single GetItem on a known key -- the same shape as every
 * other read here -- and the queue drains itself, so it does not grow.
 *
 * ADD ON A STRING SET IS IDEMPOTENT, which is what makes every write here safe
 * to repeat. Claiming the same payee twice is a no-op at the storage layer, so
 * the caller needs no dedupe of its own and a retry costs nothing.
 */
const AWARD_PK = 'br:reportaward'
const AWARD_SK = 'queue'

/** Per-incident attribute names. Aliased in every expression, so the ids in
 *  them never have to be a valid identifier. */
const payeesAttr = (id) => `p_${id}`
const claimedAtAttr = (id) => `t_${id}`

/**
 * A sanity ceiling on one award, checked here rather than trusted.
 *
 * The amount comes from the caller for the same reason a purchase price does --
 * this file cannot see BR.Config -- and for the same reason it is bounded here:
 * the only caller is server-side Lua, so a value outside this range is a bug on
 * that side and should be refused loudly rather than written to a balance.
 */
const AWARD_MAX = 5000

on('br:ddb:awardClaim', (req, incidentId, license) => {
  const answer = (ok, extra) => {
    emit('br:ddb:awardClaimResult', req, ok, extra ?? {})
  }

  const id = typeof incidentId === 'string' ? incidentId : ''
  if (id === '' || typeof license !== 'string' || license === '') {
    answer(false, { error: 'no incidentId or license' })
    return
  }

  withTimeout(
    ddb().send(
      new UpdateItemCommand({
        TableName: `${TABLE_PREFIX_GAME}players`,
        Key: marshall({ pk: AWARD_PK, sk: AWARD_SK }),
        // `if_not_exists` so a corroborator arriving an hour later does not
        // restart the age cap the first reporter's claim began.
        UpdateExpression: 'SET #t = if_not_exists(#t, :now) ADD #ids :idset, #p :licset',
        ExpressionAttributeNames: {
          '#ids': 'ids',
          '#p': payeesAttr(id),
          '#t': claimedAtAttr(id),
        },
        ExpressionAttributeValues: {
          ':idset': { SS: [id] },
          ':licset': { SS: [license] },
          ':now': { N: String(Date.now()) },
        },
      }),
    ),
    TIMEOUT_MS,
  )
    .then(() => answer(true, {}))
    .catch((e) => {
      // A LOST CLAIM COSTS ONE REWARD AND NOTHING ELSE. The report itself is
      // already durable in `ringmaster-incidents`; this is only the promise to
      // pay for it, so the failure is a log line and never touches the report
      // path that called it.
      console.log(`[br_ddb] award claim failed for ${id}: ${e.message}`)
      answer(false, { error: e.message })
    })
})

on('br:ddb:awardQueue', (req) => {
  const answer = (rows, extra) => {
    emit('br:ddb:awardQueueResult', req, rows, extra ?? {})
  }

  getByKey('players', { pk: AWARD_PK, sk: AWARD_SK }, TABLE_PREFIX_GAME)
    .then((row) => {
      if (!row) {
        answer([], {})
        return
      }

      // unmarshall turns a DynamoDB string set into a JS Set, which does not
      // survive the trip across the runtime boundary into Lua. Flatten every
      // one of them -- the same rule inventoryFetch applies to `owned`.
      const ids = row.ids instanceof Set ? Array.from(row.ids) : []

      answer(
        ids.map((id) => {
          const p = row[payeesAttr(id)]
          return {
            incidentId: id,
            licenses: p instanceof Set ? Array.from(p) : [],
            claimedAt: num(row[claimedAtAttr(id)]),
          }
        }),
        {},
      )
    })
    .catch((e) => {
      console.log('[br_ddb] award queue read failed: ' + e.message)
      answer([], { error: e.message })
    })
})

/**
 * Pay one payee for one incident, once, forever.
 *
 * ═══ THE IDEMPOTENCE, AND IT IS THE WHOLE OF IT ═══
 *
 * `reportRewards` is a string set of the incident ids this account has already
 * been paid for, and it lives on the SAME item as the balance. So the credit
 * and the record that it happened are one conditional UpdateItem: DynamoDB
 * evaluates "have I already paid this?" at write time and rejects the loser.
 * There is no window between deciding to pay and recording it, because there is
 * no second write.
 *
 * THAT IS THE `purchase` PATTERN, ON PURPOSE. The debit-and-grant above is one
 * conditional write for exactly the same reason -- it cannot half-apply -- and
 * this is its mirror image: credit-and-mark. Nothing else in this system needs
 * to know how many times the queue was swept, a resolution re-read, or the
 * resource restarted mid-sweep. The second attempt is refused by the database.
 *
 * A REFUSAL IS REPORTED AS SUCCESS, deliberately, and it is the opposite call
 * from `purchase` -- which reports its refusal as a failure because the player
 * asked for something and did not get it. Here nobody asked: the condition
 * failing means the money is already in the account, which is the outcome the
 * caller wanted. Reporting it as a failure would make the sweep retry a payment
 * that has already landed, forever.
 *
 * IT IS THE SECOND WRITER OF `balance`, AND THAT IS A REAL CHANGE. Until now
 * `statsApply` was the only path that could increase a balance, and
 * docs/progression.md leans on that: "there is exactly one writer". The
 * no-pay-to-win property survives intact -- this is still earned, still not
 * purchasable, and still not an admin grant -- but the one-writer sentence does
 * not, and whoever revises that document should revise it knowingly rather than
 * discover this here.
 */
on('br:ddb:awardPay', (req, license, incidentId, amount) => {
  const answer = (ok, extra) => {
    emit('br:ddb:awardPayResult', req, ok, extra ?? {})
  }

  const id = typeof incidentId === 'string' ? incidentId : ''
  const amt = Number(amount)

  if (typeof license !== 'string' || license === '') {
    answer(false, { error: 'no license' })
    return
  }
  if (id === '' || !Number.isFinite(amt) || amt <= 0 || amt > AWARD_MAX) {
    answer(false, { error: 'bad incident or amount' })
    return
  }

  withTimeout(
    ddb().send(
      new UpdateItemCommand({
        TableName: `${TABLE_PREFIX_GAME}players`,
        Key: marshall({ pk: license, sk: 'profile' }),
        UpdateExpression: 'ADD #bal :amt, #paid :idset',
        ConditionExpression: 'attribute_not_exists(#paid) OR NOT contains(#paid, :id)',
        ExpressionAttributeNames: { '#bal': 'balance', '#paid': 'reportRewards' },
        ExpressionAttributeValues: {
          ':amt': { N: String(Math.round(amt)) },
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
      // THE ROW IS CREATED IF IT IS NOT THERE, which is correct here and would
      // not be for a purchase: a player who reported somebody accurately and
      // has never finished a match still earned this.
      answer(true, { paid: true, balance: Number(after.balance ?? 0) })
    })
    .catch((e) => {
      if (e.name === 'ConditionalCheckFailedException') {
        answer(true, { paid: false, alreadyPaid: true })
        return
      }
      console.log(`[br_ddb] award pay failed for ${license}: ${e.message}`)
      answer(false, { error: e.message })
    })
})

/**
 * Take one incident off the queue.
 *
 * SEPARATE FROM THE PAYMENT, because it is a different question. A payment is
 * about one account; this says "nobody is owed anything more for this case",
 * and only the caller -- which watched every payee answer -- can know that.
 *
 * `DELETE` ON A SET AND `REMOVE` ON THE ATTRIBUTES, in one update, so a queue
 * entry cannot survive its own payee list. Both are `dynamodb:UpdateItem`; no
 * DeleteItem is granted to this box anywhere and none is needed here.
 */
on('br:ddb:awardSettle', (req, incidentId) => {
  const answer = (ok, extra) => {
    emit('br:ddb:awardSettleResult', req, ok, extra ?? {})
  }

  const id = typeof incidentId === 'string' ? incidentId : ''
  if (id === '') {
    answer(false, { error: 'no incidentId' })
    return
  }

  withTimeout(
    ddb().send(
      new UpdateItemCommand({
        TableName: `${TABLE_PREFIX_GAME}players`,
        Key: marshall({ pk: AWARD_PK, sk: AWARD_SK }),
        UpdateExpression: 'DELETE #ids :idset REMOVE #p, #t',
        ExpressionAttributeNames: {
          '#ids': 'ids',
          '#p': payeesAttr(id),
          '#t': claimedAtAttr(id),
        },
        ExpressionAttributeValues: { ':idset': { SS: [id] } },
      }),
    ),
    TIMEOUT_MS,
  )
    .then(() => answer(true, {}))
    .catch((e) => {
      // Harmless to fail: the payments are already idempotent, so the worst a
      // stuck queue entry costs is one wasted GetItem per sweep until the next
      // settle succeeds.
      console.log(`[br_ddb] award settle failed for ${id}: ${e.message}`)
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
  `[br_ddb] ready -- region ${REGION}, ${TABLE_PREFIX}* read-only (bans, grants, maintenance)`
    + ` + append + verdict-read (incidents),`
    + ` ${TABLE_PREFIX_GAME}* read/write (profile, inventory, stats, history, report awards)`,
)
