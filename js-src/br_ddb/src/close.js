/**
 * Closing an incident's match timeline (#30).
 *
 * SEPARATE FROM index.js SO IT CAN BE TESTED, the same split as incident.js and
 * ban.js. The network call is untestable without a table; the shape of the
 * update is the part that has to be right, and it has to be right against a
 * consumer in another repository that will never see this code.
 *
 * ═══ WHAT THIS WRITE IS, AND WHY IT IS THE ONLY DEFERRED ONE ═══
 *
 * An incident carries the match around it: when the match started, every kill
 * the subject landed, when it ended. All but the last two of those are already
 * true at filing time and ride the PutItem in incident.js at no extra cost.
 * That the match ENDED is not knowable then, and neither are the kills after the
 * report -- so they need a write of their own, and this is it.
 *
 * ONE PER INCIDENT. A match that produced no incident produces no call to this
 * function at all: br_core only emits a close for cases it actually filed. Cost
 * is proportional to incidents, not to matches, kills or players.
 *
 * ═══ THE ATTRIBUTES THIS TOUCHES ARE THE GAME'S OWN, AND THAT IS DELIBERATE ═══
 *
 * `matchTimeline` is NOT `events`. The console owns `events` -- it is where an
 * admin's notes, the corroborations and the resolution go, via the same
 * `list_append` in src/lib/incidents.ts -- and nothing the game can do should be
 * able to write there. The game owns `matchTimeline` and the three scalars
 * beside it, and nothing the console does writes those.
 *
 * That split is what lets the game's IAM grant be stated as an attribute
 * allowlist: this update names five attributes and an admin's timeline is not
 * among them, so a policy that permits exactly these five permits nothing about
 * a moderation decision. See docs/aws-setup.md -- the same reasoning the
 * handoff table was split out for.
 *
 * The console renders one timeline by merging the two lists on `at`. Two
 * writers, two attributes, one view.
 */

/** Mirrors incident.js. A Lua nil is absent, not null; an empty Lua table may
 *  arrive as `{}` rather than `[]`; Lua numbers are floats. */
const list = (v) => (Array.isArray(v) ? v : [])
const str = (v, max) => (typeof v === 'string' && v !== '' ? v.slice(0, max ?? 128) : null)
const int = (v) => (Number.isFinite(Number(v)) ? Math.round(Number(v)) : null)

/**
 * The most entries one close may append.
 *
 * A DYNAMODB ITEM IS 400KB AND THIS IS THE HALF A PLAYER INFLUENCES. The Lua
 * side caps the timeline before it ever gets here; this is the backstop for a
 * caller that did not, and it fails towards the smaller number rather than
 * towards a rejected write. A kill entry marshals to roughly 200 bytes.
 *
 * IT HAS TO SIT ABOVE THE LUA SIDE'S OWN CEILING, NOT BELOW IT, and that is why
 * this number moved when strips joined the timeline. A close now carries up to
 * MAX_TIMELINE_KILLS (250) plus MAX_TIMELINE_STRIPS (60) plus the match_end, and
 * `tail()` below keeps the LAST n -- so a backstop set under 311 would not be a
 * backstop at all, it would be this file quietly deleting the oldest rows of
 * every large close and marking the result incomplete. 320 is that ceiling with
 * the same ten rows of slack the old 260 carried over 250.
 */
const MAX_CLOSE_ENTRIES = 320

/**
 * Take the LAST n, because the recent ones explain the incident -- the same
 * direction as the evidence buffer's overflow rule and the outbox's.
 */
function tail(rows, n) {
  const l = list(rows)
  return l.length > n ? l.slice(l.length - n) : l
}

/**
 * One timeline entry, projected.
 *
 * DISCRIMINATED ON `kind`, AND UNKNOWN KINDS ARE DROPPED RATHER THAN STORED.
 * The list is heterogeneous on purpose -- it is what lets #34 add an
 * `artifact` entry later without a migration or a reshape of anything already
 * written -- but "open to new kinds" is not the same as "open to anything a
 * caller happens to send". A kind this function does not know is a bug on the
 * Lua side, and storing it would put a row on a moderation record that no
 * console version can render.
 */
/**
 * `weaponIssued`, present only when the game actually made a claim.
 *
 * THREE STATES, AND THE ABSENT ONE IS NOT A DEFAULT -- IT IS AN ANSWER. The
 * game sends `true` for a weapon it issues, `false` for one it does not, and
 * NOTHING AT ALL for a death that is not a weapon claim: a fall, a drowning,
 * the storm. A Lua key set to nil does not appear in the payload, and that
 * absence has to survive into DynamoDB rather than being flattened to false.
 *
 * WHY IT MATTERS THAT ABSENT NEVER BECOMES FALSE. The console paints
 * `weaponIssued === false` red and calls it high confidence of cheating. If
 * this spread a default into every entry, every incident filed before the
 * field existed -- and every storm death since -- would arrive as an
 * accusation against a named player. So the key is omitted unless the value is
 * exactly true or exactly false, and `=== ` is used rather than truthiness
 * because a `0` across the Lua boundary is truthy on the other side.
 */
function weaponIssuedOf(e) {
  const v = e?.weaponIssued
  if (v === true) return { weaponIssued: true }
  if (v === false) return { weaponIssued: false }
  return {}
}

export function timelineEntry(e) {
  const at = int(e?.at)
  if (at === null) return null

  const kind = str(e?.kind, 32)

  if (kind === 'match_start' || kind === 'match_end') {
    return { at, kind }
  }

  /**
   * A WEAPON THE GAMEMODE NEVER ISSUED, TAKEN OUT OF THE OFFENDER'S HAND.
   *
   * THE SPELLING OF THIS STRING IS LOAD-BEARING ACROSS TWO LANGUAGES. The Lua
   * side names it once, as STRIP_KIND in br_lib/shared/incident_build.lua, and
   * an entry whose kind this function does not recognise is DROPPED by the
   * `return null` at the bottom -- silently and on purpose. So a typo here does
   * not fail anything: both sides pass their own tests, and the entries simply
   * never arrive on any record. tools/verify.sh compares the two literals,
   * because that is the only place the two languages can be made to agree
   * mechanically.
   *
   * NO LICENCES, NO NAMES. Unlike a kill there is no second party -- a strip is
   * a fact about the subject's own ped, and the row already carries
   * `subjectLicense`.
   *
   * `weapon` IS THE SAME COERCION THE KILL PATH USES and for the same reason:
   * Lua sends a HASH, `str()` answers null for a number, and the raw hash is the
   * only identifier anybody has for a weapon this gamemode has never heard of.
   * There is deliberately no `weaponLabel` beside it -- we have no name for what
   * we do not hand out, and inventing one would dress up the finding.
   *
   * AND NO `weaponIssued`. The kind IS the claim: an entry of this kind exists
   * precisely because the weapon was not one we issue, so a flag repeating that
   * would be a second place for the same fact to be stored and to rot.
   */
  if (kind === 'weapon_strip') {
    return {
      at,
      kind,
      weapon: str(e?.weapon, 64) ?? (Number.isFinite(e?.weapon) ? String(e.weapon) : null),
    }
  }

  if (kind === 'kill') {
    return {
      at,
      kind,
      /**
       * THE LICENCES ARE THE PROFILE LINKS. The console keys player profiles by
       * licence, and a display name is neither unique nor stable. Both sides of
       * the kill travel because the buffer records a kill against the killer AND
       * the victim -- a subject's own deaths are context a reviewer needs -- and
       * the console decides which way to render it by comparing against the
       * row's `subjectLicense`.
       *
       * NULL IS A REAL ANSWER HERE. A killer who had already disconnected, or a
       * storm death with no killer at all, resolves to nothing -- and the
       * console must render "died to the storm" rather than linking a profile
       * that does not exist.
       */
      killerLicense: str(e?.killerLicense),
      killerName: str(e?.killerName),
      victimLicense: str(e?.victimLicense),
      victimName: str(e?.victimName),
      /**
       * A STRING EVEN WHEN LUA SENT A NUMBER, AND THAT IS A FIX RATHER THAN A
       * TIDY-UP. `lastHitWeapon` is not one type: the gunshot path stores
       * `data.weaponType`, which is a HASH, and the explosive path stores an
       * item id, which is a string. `str()` answers null for a number, so
       * before this line every ordinary shooting stored `weapon: null` -- the
       * single most common kill in the game, with nothing recorded about what
       * did it.
       *
       * The raw hash is kept rather than dropped because on the one case that
       * matters most -- a weapon we do not issue -- it is the only identifier
       * anybody has. There is no label for a weapon the gamemode has never
       * heard of, so an admin reading a flagged kill gets the number the cheat
       * actually used, which is evidence. For everything else `weaponLabel`
       * below carries the readable name and this field is not what gets shown.
       */
      weapon: str(e?.weapon, 64) ?? (Number.isFinite(e?.weapon) ? String(e.weapon) : null),
      /**
       * The display name, resolved on the game side against the weapon config
       * -- 'Marksman Rifle', not 'marksmanrifle' and not a hash. Null when the
       * weapon is not one we issue, because we have no name for something we
       * do not hand out and inventing one would dress up the finding.
       */
      weaponLabel: str(e?.weaponLabel, 64),
      cause: str(e?.cause, 64),
      // STRICTLY BOOLEAN, never a truthy 0 from across the Lua boundary.
      headshot: e?.headshot === true,
      ...weaponIssuedOf(e),
    }
  }

  return null
}

/**
 * The UpdateItem for one close, or a reason there is not one.
 *
 * @param {string} incidentId  minted at filing, echoed back by br_core
 * @param {object} payload     as sent by br_ringmaster
 * @param {string} tableName
 * @returns {{params: object}|{error: string, retryable?: boolean}}
 */
export function buildIncidentClose(incidentId, payload, tableName) {
  if (typeof incidentId !== 'string' || incidentId === '') {
    return { error: 'no incidentId' }
  }
  if (!payload || typeof payload !== 'object') {
    return { error: 'no payload' }
  }

  const matchEndedAt = int(payload.matchEndedAt)
  if (matchEndedAt === null) {
    // WITHOUT AN END THERE IS NOTHING TO SAY. The whole point of this write is
    // to replace "we cannot tell whether this match is still running" with a
    // timestamp; one without an end would clear nothing and cost a write.
    return { error: 'no matchEndedAt' }
  }

  const entries = tail(payload.matchTimeline, MAX_CLOSE_ENTRIES)
    .map(timelineEntry)
    .filter((e) => e !== null)

  const seen = int(payload.matchKillsSeen) ?? 0

  /**
   * TRUNCATION IS REPORTED, NEVER SILENT -- the house rule the evidence log's
   * `truncated` flag already sets. A timeline that stops early and looks
   * complete tells an admin "this is everything they did" when it is not, which
   * is the one failure a moderation record must not produce.
   *
   * `=== true` RATHER THAN A TRUTHY TEST, because this crosses the Lua boundary
   * where `0` is truthy and a bare check would call a dropped-rows timeline
   * complete.
   */
  const complete =
    payload.matchTimelineComplete === true &&
    entries.length === list(payload.matchTimeline).length

  return {
    params: {
      TableName: tableName,
      Key: { incidentId },

      /**
       * `if_not_exists` ON THE LIST, because a row filed by an older game
       * version has no `matchTimeline` at all and `list_append` against a
       * missing attribute fails the whole update. That is a real case: the
       * close for a match that was already running when the server was updated.
       *
       * NOTHING HERE TOUCHES `events`, `state`, `verdict`, `resolvedAt`,
       * `resolvedBy*`, `resolution` OR `closedByBan`. Verdicts are final and
       * incidents cannot be re-opened; this update is the game adding match
       * facts to a case, and it must not be able to express an opinion about
       * one. The attribute list here is exactly the allowlist the IAM statement
       * in docs/aws-setup.md should name.
       */
      UpdateExpression:
        'SET matchEndedAt = :end, ' +
        'matchTimelineComplete = :complete, ' +
        'matchKillsSeen = :seen, ' +
        'matchTimeline = list_append(if_not_exists(matchTimeline, :empty), :entries)',

      /**
       * THE ROW MUST ALREADY EXIST. A close for a case whose PutItem was lost
       * has nothing to attach to, and without this the update would CREATE a
       * bare row -- an incident with a match timeline, no subject, no reporter
       * and no state, sitting in a queue naming nobody. The console scans this
       * table and reads every row as an incident.
       */
      ConditionExpression: 'attribute_exists(incidentId)',

      ExpressionAttributeValues: {
        ':end': matchEndedAt,
        ':complete': complete,
        ':seen': seen,
        ':entries': entries,
        ':empty': [],
      },

      /**
       * NONE, AND THE IAM POLICY SHOULD REQUIRE IT. An attribute allowlist on
       * `dynamodb:Attributes` restricts what an update may WRITE; `ReturnValues`
       * is how the same request could still READ back the rest of the row. The
       * game box has no business reading a verdict off the row it is closing,
       * and it does not need to.
       */
      ReturnValues: 'NONE',
    },
  }
}

export const CLOSE_LIMITS = { MAX_CLOSE_ENTRIES }
