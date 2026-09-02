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
 * An incident carries the match around it: when the match was formed, when it
 * started, every kill the subject landed, when it ended. Most of that is already
 * true at filing time and rides the PutItem in incident.js at no extra cost.
 * That the match ENDED is not knowable then, neither are the kills after the
 * report, and neither is when the match STARTED for a case filed during warmup
 * -- so they need a write of their own, and this is it.
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
 * allowlist: every attribute this update names is one the game owns and an
 * admin's timeline is not among them, so a policy that permits exactly this list
 * permits nothing about a moderation decision. See docs/aws-setup.md -- the same
 * reasoning the handoff table was split out for. The list is spelled out at the
 * UpdateExpression below, together with the order the policy and this code have
 * to be deployed in.
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
 * this number moved when strips joined the timeline and why it has moved again
 * for refused chat. A close now carries up to MAX_TIMELINE_KILLS (250) plus
 * MAX_TIMELINE_STRIPS (60) plus MAX_TIMELINE_CHAT (60) plus the match_end, and
 * `tail()` below keeps the LAST n -- so a backstop set under 371 would not be a
 * backstop at all, it would be this file quietly deleting the oldest rows of
 * every large close and marking the result incomplete. 380 is that ceiling with
 * the same slack 320 carried over 311 and 260 carried over 250.
 *
 * THE SIZE STILL FITS. A chat entry is the largest row on this list -- 200 bytes
 * of text plus its keys, call it 300 marshalled -- so sixty of them is about
 * 18KB, on top of the kills' 50KB, against a 400KB item.
 */
const MAX_CLOSE_ENTRIES = 380

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
   * THE MATCH WAS FORMED. NOT THE SAME FACT AS `match_start`, AND THAT IS THE
   * ENTIRE REASON IT IS A THIRD KIND RATHER THAN A `match_start` WITH AN EARLIER
   * `at`.
   *
   * A match is minted into WARMUP and only stamps `startedAt` on entering
   * PLAYING (br_core/server/match.lua). Anything filed on the warmup pad -- a
   * weapon this gamemode never issued, taken out of a hand before the offender
   * has touched a real player -- therefore has no start to anchor its timeline
   * on. The obvious fix is to put the creation time in `matchStartedAt`, and it
   * is wrong: `match_start` would then mean "the lobby opened" on some rows and
   * "the match began" on others, with nothing on either row saying which. The
   * console cannot render an ambiguous field honestly, so it gets an unambiguous
   * one instead and can say "formed" where that is what happened.
   *
   * THE SPELLING IS LOAD-BEARING ACROSS TWO LANGUAGES, exactly as `weapon_strip`
   * is. The Lua side names it once, as MATCH_CREATED_KIND in
   * br_lib/shared/incident_build.lua, and the `return null` at the bottom of this
   * function drops what it does not recognise -- so a typo here fails nothing and
   * simply means the entries never arrive. tools/verify.sh compares the literals.
   */
  if (kind === 'match_created') {
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

  /**
   * A CHAT LINE THE SERVER ACCEPTED AND THEN DELIVERED TO NOBODY.
   *
   * THE SPELLING IS LOAD-BEARING ACROSS TWO LANGUAGES, as `weapon_strip` and
   * `match_created` are. The Lua side names it once, as CHAT_KIND in
   * br_lib/shared/incident_build.lua, and the `return null` at the bottom drops
   * what this function does not recognise -- so a typo here fails nothing and
   * simply means the entries never arrive. tools/verify.sh compares the
   * literals.
   *
   * ═══ THIS IS THE FIRST PLAYER-AUTHORED PROSE ON A MATCH TIMELINE ═══
   *
   * Everything else on this list is a fact the server measured: a timestamp, a
   * weapon hash, a licence it resolved itself. `text` is what somebody typed,
   * and it is here because the owner asked for it by name (2026-08-29):
   * "specifically save the chat content to the DDB entry and display on the
   * timeline in the incident".
   *
   * SO IT IS CAPPED HERE AS WELL AS ON THE LUA SIDE, at the same 200 -- which is
   * BR.ChatLimits.maxLength, the length the server already refuses to deliver
   * past. `str()` is the same coercion every other string on this row gets: a
   * non-string becomes null rather than `"[object Object]"`, and an empty string
   * becomes null rather than an entry that renders as a blank accusation.
   *
   * NOT ESCAPED, AND THAT IS DELIBERATE. The console renders timeline entries as
   * React text children, which escapes structurally; escaping here as well would
   * double-encode and put `&amp;` on a moderation record. The rule is that this
   * value is TEXT everywhere it is read -- if a consumer ever needs markup it
   * must escape at its own boundary, not ask for pre-escaped data here.
   *
   * `reason` IS A CLOSED SET FROM THE GAME -- `link` or `script` -- and it is
   * what tells a reviewer whether the finding was the domain in the line or the
   * alphabet it was written in. For a non-Latin line the text alone will not say.
   */
  if (kind === 'chat_block') {
    return {
      at,
      kind,
      text: str(e?.text, 200),
      reason: str(e?.reason, 32),
      channel: str(e?.channel, 32),
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
   * ═══ THE TWO ATTRIBUTES A WARMUP-FILED CASE IS MISSING ═══
   *
   * A case filed during WARMUP is filed before its match has a `startedAt` --
   * that is stamped on entering PLAYING -- so its row is written with a null
   * start and, because the deadline is derived from the start, a null
   * `matchEndsBy` too. Both are known by the time this write happens, and this
   * write was already happening, so they ride it.
   *
   * OMITTED RATHER THAN NULLED WHEN THEY ARE NOT KNOWN, and that is a guard
   * rather than a tidy-up. A match that dissolved on the pad ends without ever
   * having started, and a close that unconditionally SET these would write NULL
   * over whatever the row already said -- including, if a caller ever failed to
   * pass the start for a match that DID run, a correct value on an ordinary
   * case. The narrow update is also exactly the update this file made before
   * these two existed, so a close that has nothing to add is byte-for-byte the
   * write the old IAM policy already permitted.
   */
  const startedAt = int(payload.matchStartedAt)
  const endsBy = int(payload.matchEndsBy)

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

  /**
   * BUILT AS A LIST BECAUSE TWO OF THE SIX ARE CONDITIONAL. Order within a SET
   * is meaningless to DynamoDB; it is kept in the reading order a person would
   * want -- when it ended, when it started, when it was due to end, then the
   * three about the timeline.
   */
  const sets = ['matchEndedAt = :end']
  const values = {
    ':end': matchEndedAt,
    ':complete': complete,
    ':seen': seen,
    ':entries': entries,
    ':empty': [],
  }

  if (startedAt !== null) {
    sets.push('matchStartedAt = :start')
    values[':start'] = startedAt
  }
  if (endsBy !== null) {
    sets.push('matchEndsBy = :endsBy')
    values[':endsBy'] = endsBy
  }

  sets.push('matchTimelineComplete = :complete')
  sets.push('matchKillsSeen = :seen')
  sets.push('matchTimeline = list_append(if_not_exists(matchTimeline, :empty), :entries)')

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
       *
       * ═══ THAT LIST GREW, AND THE POLICY MUST GROW FIRST ═══
       *
       * `matchStartedAt` and `matchEndsBy` joined it so that a case filed during
       * WARMUP -- which has neither on its row, because neither existed when the
       * row was written -- receives them when the match actually starts and
       * ends. The seven the statement must now name:
       *
       *     incidentId, matchEndedAt, matchStartedAt, matchEndsBy,
       *     matchTimeline, matchTimelineComplete, matchKillsSeen
       *
       * WIDEN THE POLICY BEFORE DEPLOYING THIS CODE, NEVER AFTER. The two
       * orderings are not symmetrical:
       *
       *   policy first   harmless. The old code writes five attributes and a
       *                  seven-attribute allowlist permits all five.
       *   code first     every close fails. `dynamodb:Attributes` is enforced
       *                  per REQUEST, not per attribute, so DynamoDB refuses the
       *                  WHOLE UpdateItem -- the end timestamp and the
       *                  post-filing timeline are lost along with the two new
       *                  fields, on every case, for as long as the window lasts.
       *
       * `matchCreatedAt` IS DELIBERATELY NOT ON THIS LIST. It is written once,
       * by the PutItem in incident.js, which is not attribute-constrained. A
       * close has nothing to say about when a match was formed.
       */
      UpdateExpression: 'SET ' + sets.join(', '),

      /**
       * THE ROW MUST ALREADY EXIST. A close for a case whose PutItem was lost
       * has nothing to attach to, and without this the update would CREATE a
       * bare row -- an incident with a match timeline, no subject, no reporter
       * and no state, sitting in a queue naming nobody. The console scans this
       * table and reads every row as an incident.
       */
      ConditionExpression: 'attribute_exists(incidentId)',

      ExpressionAttributeValues: values,

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
