import { timelineEntry } from './close.js'

/**
 * Building the DynamoDB item for an incident.
 *
 * SEPARATE FROM index.js SO IT CAN BE TESTED, the same split as ban.js. The
 * network call is untestable without a table; the shape of the row is the part
 * that has to be right, and it has to be right against a consumer in another
 * repository that will never see this code.
 *
 * THE CONSUMER IS RINGMASTER'S `Incident` INTERFACE (src/lib/incidents.ts). The
 * console does not map or rename anything on the way in -- it reads the row this
 * function wrote. So every field name here is a contract.
 *
 * WHAT CROSSES THE BOUNDARY INTO HERE IS LUA, WHICH CHANGES THE RULES:
 *
 *   * A Lua table key set to nil is not sent as null -- it is absent. Every
 *     optional field therefore has to be defaulted explicitly, and the console's
 *     `reporterLicense === null` test only means "the system filed this" because
 *     this function writes the null.
 *   * An EMPTY Lua table is ambiguous once serialised: it can arrive as an empty
 *     object rather than an empty array. So every list is coerced with
 *     Array.isArray rather than trusted, or DynamoDB stores `{}` where the
 *     console expects `[]` and the UI throws on `.map`.
 *   * Lua numbers are floats. Ids and timestamps are rounded rather than stored
 *     as 1.7e12, which is the same value and a different string in every log.
 */

/**
 * A DynamoDB item may not exceed 400KB, and an incident is the one row in this
 * system whose size a player influences -- fifty chat lines each, per session,
 * across up to four subjects.
 *
 * CAPPED WITH A FLAG RATHER THAN SILENTLY, which is the house rule the snapshot's
 * `truncated` already establishes. An evidence log that stops early and looks
 * complete is the one failure a moderation record must not produce: it reads as
 * "this is everything they said" when it is not.
 */
const MAX_CHAT_ROWS = 120
const MAX_KILL_ROWS = 80
const MAX_EVIDENCE_RECORDS = 8
const MAX_SUBJECTS = 4
const MAX_TEXT = 512

const list = (v) => (Array.isArray(v) ? v : [])
const str = (v, max) => (typeof v === 'string' && v !== '' ? v.slice(0, max ?? 128) : null)
const int = (v) => (Number.isFinite(Number(v)) ? Math.round(Number(v)) : null)

/**
 * Take the LAST n rows, because the recent ones explain the incident.
 *
 * Same direction as the evidence buffer's own overflow rule and the outbox's:
 * when a record is full, the rows describing what is happening now are worth
 * more than the ones describing the bus ride.
 */
function tail(rows, n) {
  const l = list(rows)
  return l.length > n ? l.slice(l.length - n) : l
}

function chatRow(c) {
  return {
    text: str(c?.text, MAX_TEXT) ?? '',
    channel: str(c?.channel, 32) ?? 'all',
    at: int(c?.at),
  }
}

function killRow(k) {
  return {
    killer: str(k?.killer, 128),
    victim: str(k?.victim, 128),
    cause: str(k?.cause, 64),
    weapon: str(k?.weapon, 64),
    headshot: k?.headshot === true,
    at: int(k?.at),
  }
}

function evidenceRecord(r, budget) {
  const chat = tail(r?.chat, Math.max(0, budget.chat))
  const kills = tail(r?.kills, Math.max(0, budget.kills))
  budget.chat -= chat.length
  budget.kills -= kills.length

  return {
    license: str(r?.license),
    name: str(r?.name),
    matchId: int(r?.matchId),
    squadId: int(r?.squadId),
    openedAt: int(r?.openedAt),
    leftAt: int(r?.leftAt),
    left: r?.left === true,
    chat: chat.map(chatRow),
    kills: kills.map(killRow),
  }
}

function subjectRow(s) {
  return {
    license: str(s?.license),
    name: str(s?.name),
    squadId: int(s?.squadId),
    left: s?.left === true,
  }
}

/**
 * The row, or a reason there is not one.
 *
 * REFUSES RATHER THAN GUESSES on anything that would make the record wrong about
 * a person. A missing subject license is the case that matters: DynamoDB would
 * happily store the row, the console would happily list it, and it would name
 * nobody -- an open case that can never be closed because there is no profile to
 * attach it to.
 *
 * @param {string} incidentId  minted by the caller, never accepted from Lua
 * @param {object} payload     as sent by br_ringmaster
 * @param {number} now         Date.now(), passed so this is testable
 * @returns {{item: object}|{error: string}}
 */
export function buildIncidentItem(incidentId, payload, now) {
  if (typeof incidentId !== 'string' || incidentId === '') {
    return { error: 'no incidentId' }
  }
  if (!payload || typeof payload !== 'object') {
    return { error: 'no payload' }
  }

  const subjectLicense = str(payload.subjectLicense)
  if (!subjectLicense) return { error: 'no subject license' }

  const state = payload.state === 'resolved' ? 'resolved' : 'pending_review'
  const resolved = state === 'resolved'

  /**
   * `openedAt` IS A REAL TIMESTAMP OR THIS ROW IS UNREADABLE. br_ringmaster
   * converts the game clock before sending; this falls back to the write time if
   * that produced nothing. A case timestamped "now" is off by milliseconds; one
   * timestamped 4281003 renders as January 1970 and sorts to the bottom of every
   * list forever.
   */
  const openedAt = int(payload.openedAt) ?? now

  /**
   * The budget is shared ACROSS records rather than per record, because the limit
   * being defended is the item's total size. Four subjects at a per-record cap
   * would be four times the row this cap was chosen for.
   */
  const budget = { chat: MAX_CHAT_ROWS, kills: MAX_KILL_ROWS }
  const rawEvidence = list(payload.evidence)
  const offered = {
    chat: rawEvidence.reduce((n, r) => n + list(r?.chat).length, 0),
    kills: rawEvidence.reduce((n, r) => n + list(r?.kills).length, 0),
  }
  const evidence = rawEvidence
    .slice(0, MAX_EVIDENCE_RECORDS)
    .map((r) => evidenceRecord(r, budget))

  const kept = {
    chat: evidence.reduce((n, r) => n + r.chat.length, 0),
    kills: evidence.reduce((n, r) => n + r.kills.length, 0),
  }
  const truncated =
    rawEvidence.length > MAX_EVIDENCE_RECORDS ||
    kept.chat < offered.chat ||
    kept.kills < offered.kills

  const rawSubjects = list(payload.subjects)
  const subjects = (
    rawSubjects.length > 0
      ? rawSubjects
      : [{ license: subjectLicense, name: payload.subjectName }]
  )
    .slice(0, MAX_SUBJECTS)
    .map(subjectRow)
    .filter((s) => s.license !== null)

  const reporterLicense = str(payload.reporterLicense)
  const reporterName = str(payload.reporterName)

  const item = {
    incidentId,

    kind: str(payload.kind, 32) ?? 'anticheat',
    category: str(payload.category, 32) ?? 'system',
    state,

    subjectLicense,
    subjectName: str(payload.subjectName) ?? 'Unknown',

    // Explicit nulls, not absent keys -- see the note about Lua nil above.
    reporterLicense,
    reporterName,

    openedAt,
    summary: str(payload.summary, 256) ?? 'Incident',

    /**
     * NO FREE-TEXT NOTE, EVER, FROM THE GAME (owner call, 2026-08-14). A player
     * report carries a category from a fixed list and nothing they typed, so
     * there is no player-supplied prose anywhere in this row. That removes the
     * injection surface rather than guarding it -- the only free text in the
     * whole pipeline is an admin's own resolution, written console-side.
     */
    note: null,
    linkedLicense: str(payload.linkedLicense),

    /**
     * A triage hint, not an instruction. The game forms no opinion about what
     * should happen to the player; this says how loudly a human should be asked
     * to look. See br_lib/shared/incident_build.lua for the tiers.
     */
    severity: ['low', 'normal', 'high'].includes(payload.severity)
      ? payload.severity
      : 'normal',

    matchId: int(payload.matchId),

    /**
     * Denormalised onto the row rather than written as index rows in the same
     * transaction. The subject index table does not exist yet, and a
     * TransactWriteItems naming a table that is not there fails the WHOLE write
     * -- losing the incident in order to protect an index, which is exactly
     * backwards. So the data the index needs travels with the row, and building
     * the index later is a migration over rows that already carry it.
     */
    subjects,
    subjectLicenses: subjects.map((s) => s.license),

    refusal: payload.refusal
      ? {
          count: int(payload.refusal.count),
          windowMs: int(payload.refusal.windowMs),
          reason: str(payload.refusal.reason, 128),
          reasons:
            payload.refusal.reasons && typeof payload.refusal.reasons === 'object'
              ? payload.refusal.reasons
              : null,
          action: str(payload.refusal.action, 32),
        }
      : null,

    evidence,
    evidenceTruncated: truncated,

    priorIncidentIds: list(payload.priorIncidentIds)
      .map((v) => str(v, 64))
      .filter(Boolean),

    /**
     * ═══ THE MATCH AROUND THE CASE (#30) ═══
     *
     * WRITTEN HERE BECAUSE IT IS FREE HERE. Match start and every kill the
     * subject had landed by the time the case was filed are both already known
     * -- the match registry knows when it started, and the evidence buffer has
     * been holding the kills in RAM all along -- so they ride this PutItem and
     * cost no write of their own. A match that never produces an incident never
     * reaches this function and therefore writes nothing at all.
     *
     * `matchEndedAt` IS ABSENT UNTIL THE MATCH ENDS, which is the single fact
     * that cannot be known now. close.js fills it with one UpdateItem.
     *
     * `matchEndsBy` IS HOW AN ABSENT END STOPS MEANING "STILL RUNNING". The game
     * states, at filing time, when it expects this match to be over by. The
     * console then reads three states rather than two:
     *
     *   matchEndedAt present        -> ended, at that time
     *   absent, now <  matchEndsBy  -> STILL IN PROGRESS
     *   absent, now >= matchEndsBy  -> the end was never reported
     *
     * The third is a crashed or restarted server, and an admin must not read it
     * as the second. Written now rather than later precisely so that it survives
     * the game box disappearing.
     *
     * NULL WHEN THERE WAS NO MATCH. An anticheat trip in the lobby or a
     * `brrefuse` from a console carries no match, and the console shows no match
     * context rather than an invented one.
     */
    matchStartedAt: int(payload.matchStartedAt),
    matchEndedAt: null,
    matchEndsBy: int(payload.matchEndsBy),

    /**
     * A LIST DISCRIMINATED BY `kind`, and that is what makes #34 free later: an
     * artifact frame becomes `{ at, kind: 'artifact', ... }` with no new
     * attribute and no migration of rows already written.
     *
     * IT IS NOT `events`. The console owns `events`; the game owns this. Neither
     * writes the other's, which is what lets the game's UpdateItem grant be an
     * attribute allowlist that cannot express an opinion about a verdict. The
     * console merges the two on `at` at render time.
     */
    matchTimeline: list(payload.matchTimeline).map(timelineEntry).filter(Boolean),

    /**
     * TRUNCATION IS REPORTED, NEVER SILENT, the same house rule as
     * `evidenceTruncated` above and for the same reason: a kill list that stops
     * early and looks complete tells an admin "this is everything they did"
     * when it is not. `matchKillsSeen` is every kill the buffer was ever
     * offered for this player, including ones its caps dropped.
     */
    matchTimelineComplete: payload.matchTimelineComplete === true,
    matchKillsSeen: int(payload.matchKillsSeen) ?? 0,

    events: [
      {
        at: openedAt,
        kind: 'opened',
        byLicense: reporterLicense,
        byName: reporterName ?? 'Anticheat',
      },
    ],

    resolvedAt: resolved ? openedAt : null,
    resolvedByLicense: null,
    resolvedByName: resolved ? 'System' : null,
    resolution: resolved ? 'Handled automatically' : null,
  }

  if (resolved) {
    item.events.push({
      at: openedAt,
      kind: 'resolved',
      byLicense: null,
      byName: 'System',
      text: 'Handled automatically -- no action needed from an admin.',
    })
  }

  return { item }
}

export const LIMITS = {
  MAX_CHAT_ROWS,
  MAX_KILL_ROWS,
  MAX_EVIDENCE_RECORDS,
  MAX_SUBJECTS,
}
