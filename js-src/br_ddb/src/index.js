import { DynamoDBClient, GetItemCommand } from '@aws-sdk/client-dynamodb'
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
 * IT EXPOSES EXACTLY TWO VERBS, BOTH READS, and that is a security boundary
 * rather than a convenience. There is deliberately no generic "run this query"
 * primitive: a general-purpose DynamoDB bridge sitting inside the game server
 * is one careless commit away from a write path into the tables that decide who
 * is banned and who is an admin. Adding a verb here should feel like a
 * decision, because it is one.
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
async function getByKey(table, key) {
  const out = await withTimeout(
    ddb().send(
      new GetItemCommand({
        TableName: `${TABLE_PREFIX}${table}`,
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
  `[br_ddb] ready -- region ${REGION}, tables ${TABLE_PREFIX}*, read-only (bans, grants)`,
)
