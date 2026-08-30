import { artifactNames, ARTIFACT_PREFIX, isSpoolFile } from '../src/artifacts.js'
import { isActive } from '../src/ban.js'
import { buildIncidentClose, CLOSE_LIMITS } from '../src/close.js'
import { buildIncidentItem, LIMITS } from '../src/incident.js'
import { spendCost, spendUpdate, SPEND_MAX } from '../src/spend.js'
import { buildStatsUpdate } from '../src/stats.js'
import { projectVerdict, verdictWord } from '../src/verdict.js'

// NOT `../src/`. These two drive src/index.js itself -- the twenty handlers,
// which until 2026-08-30 nothing here ran. See scripts/bridge.mjs.
import { writeFileSync } from 'node:fs'
import { join } from 'node:path'

import { unmarshall } from './aws_stub.mjs'
import { loadBridge, lastEmit } from './bridge.mjs'

/**
 * Tests for the decisions in br_ddb that are pure arithmetic on data, and
 * therefore the ones that can be wrong for weeks without anybody noticing.
 *
 *   the ban rule       decides whether a player gets into the server
 *   the incident item  decides what a moderation record says about a person
 *   artifact names     decide which IAM statement applies and which files the
 *                      sweeper may delete
 *
 * None needs a network, and none should ever be changed without a case here
 * changing with it.
 */

let failed = 0
let ran = 0

function check(label, got, expected) {
  ran++
  const ok = JSON.stringify(got) === JSON.stringify(expected)
  if (!ok) failed++
  console.log(
    ok
      ? `  ok    ${label}`
      : `  FAIL  ${label}\n          got      ${JSON.stringify(got)}\n          expected ${JSON.stringify(expected)}`,
  )
}

// ---------------------------------------------------------------- ban rule ---

const NOW = 1_700_000_000_000
const HOUR = 3_600_000

const banCases = [
  // [label, ban, expected]
  ['no row at all', null, false],
  ['undefined row', undefined, false],

  ['permanent, never lifted', { expiresAt: null, liftedAt: null }, true],
  ['permanent, expiresAt absent entirely', { liftedAt: null }, true],

  ['temporary, still running', { expiresAt: NOW + HOUR, liftedAt: null }, true],
  ['temporary, expired an hour ago', { expiresAt: NOW - HOUR, liftedAt: null }, false],
  [
    'temporary, expiring exactly now counts as served',
    { expiresAt: NOW, liftedAt: null },
    false,
  ],

  ['lifted beats a live expiry', { expiresAt: NOW + HOUR, liftedAt: NOW - HOUR }, false],
  ['lifted beats permanent', { expiresAt: null, liftedAt: NOW - HOUR }, false],

  // The shape DynamoDB actually returns for an absent attribute, which is the
  // one that bit the ingest schema: absent is not null, and neither is false.
  ['liftedAt absent, not null', { expiresAt: null }, true],
]

console.log('ban rule')
for (const [label, ban, expected] of banCases) {
  check(`${label} -> ${expected}`, isActive(ban, NOW), expected)
}

// ----------------------------------------------------------- incident item ---

const ID = '11111111-2222-3333-4444-555555555555'
const LIC = 'license:abc123'

/** The shape br_ringmaster sends for a refusal cluster, already realised. */
function refusalPayload(over = {}) {
  return {
    kind: 'anticheat',
    category: 'system',
    state: 'pending_review',
    severity: 'high',
    subjectLicense: LIC,
    subjectName: 'Someone',
    subjects: [{ license: LIC, name: 'Someone', squadId: 3, left: false }],
    matchId: 7,
    summary: '8 shots refused in 10s -- weapon is not one this gamemode issues',
    openedAt: NOW,
    refusal: {
      count: 8,
      windowMs: 10000,
      reason: 'weapon is not one this gamemode issues',
      reasons: { 'weapon is not one this gamemode issues': 8 },
      action: 'incident',
    },
    evidence: [
      {
        license: LIC,
        name: 'Someone',
        matchId: 7,
        squadId: 3,
        openedAt: NOW - 60000,
        left: false,
        chat: [{ text: 'hello', channel: 'all', at: NOW - 30000 }],
        kills: [
          {
            killer: 'Someone',
            victim: 'Else',
            cause: 'headshot',
            weapon: 'carbine',
            headshot: true,
            at: NOW - 20000,
          },
        ],
      },
    ],
    ...over,
  }
}

console.log('\nincident item')

// REFUSALS, not defaults. Each of these would produce a record that names the
// wrong person or nobody at all, which is worse than producing none.
check(
  'no incidentId is refused',
  buildIncidentItem('', refusalPayload(), NOW),
  { error: 'no incidentId' },
)
check(
  'no payload is refused',
  buildIncidentItem(ID, null, NOW),
  { error: 'no payload' },
)
check(
  'no subject license is refused -- a case that names nobody cannot be closed',
  buildIncidentItem(ID, refusalPayload({ subjectLicense: undefined }), NOW),
  { error: 'no subject license' },
)
check(
  'an EMPTY subject license is refused too, not stored as ""',
  buildIncidentItem(ID, refusalPayload({ subjectLicense: '' }), NOW),
  { error: 'no subject license' },
)

const built = buildIncidentItem(ID, refusalPayload(), NOW)
const it = built.item

check('the id is the one passed in', it.incidentId, ID)
check('state defaults to pending_review', it.state, 'pending_review')
check('severity survives', it.severity, 'high')
check('openedAt is the realised timestamp, not the write time', it.openedAt, NOW)
check('matchId is carried', it.matchId, 7)

// LUA NIL DOES NOT SURVIVE SERIALISATION, so these have to be written rather
// than passed through. The console tests `reporterLicense === null` to decide
// whether the system filed a case.
check('reporterLicense is an explicit null', it.reporterLicense, null)
check('reporterName is an explicit null', it.reporterName, null)
check('note is null -- no free text ever reaches this row', it.note, null)

check('the opened event is stamped at openedAt', it.events[0].at, NOW)
check('the opened event names the anticheat', it.events[0].byName, 'Anticheat')
check('there is exactly one event on a fresh incident', it.events.length, 1)
check('an unresolved incident has no resolution', it.resolution, null)

check('subjects survive with their squad', it.subjects, [
  { license: LIC, name: 'Someone', squadId: 3, left: false },
])
check(
  'subjectLicenses mirrors subjects, for the index that comes later',
  it.subjectLicenses,
  [LIC],
)
check('evidence is kept whole when it is small', it.evidence.length, 1)
check('chat rows survive', it.evidence[0].chat, [
  { text: 'hello', channel: 'all', at: NOW - 30000 },
])
check('nothing was truncated', it.evidenceTruncated, false)

// An auto-resolved incident -- the shape a player drop will file (task 12).
const auto = buildIncidentItem(ID, refusalPayload({ state: 'resolved' }), NOW).item
check('resolved state survives', auto.state, 'resolved')
check('resolved gets a resolvedAt', auto.resolvedAt, NOW)
check('resolved gets two events, opened then resolved', auto.events.length, 2)
check('the second event is the resolution', auto.events[1].kind, 'resolved')
check('the resolution is attributed to the system', auto.events[1].byName, 'System')

// A REPORT, where the reporter is a real person. Same builder, different caller.
const report = buildIncidentItem(
  ID,
  refusalPayload({
    kind: 'report',
    category: 'teaming',
    severity: 'normal',
    reporterLicense: 'license:reporter',
    reporterName: 'Reporter',
    refusal: undefined,
  }),
  NOW,
).item
check('a report keeps its reporter', report.reporterLicense, 'license:reporter')
check('the opened event is attributed to the reporter', report.events[0].byName, 'Reporter')
check('a report has no refusal block', report.refusal, null)
check('the category is not forced to system', report.category, 'teaming')

// LUA'S EMPTY-TABLE AMBIGUITY. An empty Lua table can arrive as `{}` rather than
// `[]`, and `{}.map` throws in the UI. Every list has to be coerced.
const empties = buildIncidentItem(
  ID,
  refusalPayload({
    evidence: {},
    subjects: {},
    priorIncidentIds: {},
  }),
  NOW,
).item
check('an object where evidence was expected becomes []', empties.evidence, [])
check('an object where priorIncidentIds was expected becomes []', empties.priorIncidentIds, [])
check(
  'subjects falls back to the subject itself rather than being empty',
  empties.subjects,
  [{ license: LIC, name: 'Someone', squadId: null, left: false }],
)

// TRUNCATION IS FLAGGED, NOT SILENT. A short evidence log that looks complete
// reads as "this is everything they said" when it is not.
const manyChat = Array.from({ length: LIMITS.MAX_CHAT_ROWS + 25 }, (_, i) => ({
  text: `line ${i}`,
  channel: 'all',
  at: NOW - 1000 * i,
}))
const big = buildIncidentItem(
  ID,
  refusalPayload({
    evidence: [{ license: LIC, name: 'Someone', chat: manyChat, kills: [] }],
  }),
  NOW,
).item
check('chat is capped', big.evidence[0].chat.length, LIMITS.MAX_CHAT_ROWS)
check('and the cap is admitted', big.evidenceTruncated, true)
check(
  'the rows KEPT are the most recent ones -- they explain the incident',
  big.evidence[0].chat[big.evidence[0].chat.length - 1].text,
  `line ${manyChat.length - 1}`,
)

const manyRecords = Array.from({ length: LIMITS.MAX_EVIDENCE_RECORDS + 3 }, () => ({
  license: LIC,
  name: 'Someone',
  chat: [],
  kills: [],
}))
const overRecords = buildIncidentItem(
  ID,
  refusalPayload({ evidence: manyRecords }),
  NOW,
).item
check('records are capped', overRecords.evidence.length, LIMITS.MAX_EVIDENCE_RECORDS)
check('and that is admitted too', overRecords.evidenceTruncated, true)

// The chat budget is shared across records, because the limit being defended is
// the item's total size rather than any one record's.
const twoBig = buildIncidentItem(
  ID,
  refusalPayload({
    evidence: [
      { license: LIC, name: 'A', chat: manyChat, kills: [] },
      { license: LIC, name: 'B', chat: manyChat, kills: [] },
    ],
  }),
  NOW,
).item
check(
  'two full records still total the cap, not twice it',
  twoBig.evidence.reduce((n, r) => n + r.chat.length, 0),
  LIMITS.MAX_CHAT_ROWS,
)

check(
  'more than four subjects are capped',
  buildIncidentItem(
    ID,
    refusalPayload({
      subjects: Array.from({ length: 9 }, (_, i) => ({ license: `license:${i}` })),
    }),
    NOW,
  ).item.subjects.length,
  LIMITS.MAX_SUBJECTS,
)

// A GAME-CLOCK TIMESTAMP THAT NEVER GOT REALISED would render as 1970. Falling
// back to the write time is off by milliseconds instead.
check(
  'a missing openedAt falls back to now, never to zero',
  buildIncidentItem(ID, refusalPayload({ openedAt: undefined }), NOW).item.openedAt,
  NOW,
)
check(
  'a nonsense severity becomes normal rather than being stored',
  buildIncidentItem(ID, refusalPayload({ severity: 'catastrophic' }), NOW).item.severity,
  'normal',
)
check(
  'a nonsense state becomes pending_review -- never silently resolved',
  buildIncidentItem(ID, refusalPayload({ state: 'closed' }), NOW).item.state,
  'pending_review',
)

// ----------------------------------------------------------------- verdict ---
//
// THE RULE THAT DECIDES WHETHER 250 VOLTS ARE PAID TO A STRANGER, and the one
// place in this repository that can be tested against the console's contract
// without a table. The cases below are the contract's own edge list: absent is
// not 'none', a pending row is not a decision, and a missing row is not a
// verdict of any kind.

console.log('\nverdict reader\n')

const resolvedRow = (verdict) => ({
  incidentId: ID,
  state: 'resolved',
  resolvedAt: NOW,
  ...(verdict === undefined ? {} : { verdict }),
})

const shape = (row) => {
  const v = projectVerdict(row)
  return { found: v.found, settled: v.settled, payable: v.payable, word: v.word }
}

check(
  'a permanent ban pays, and the sentence says banned',
  shape(resolvedRow({ action: 'ban', expiresAt: null })),
  { found: true, settled: true, payable: true, word: 'banned' },
)
check(
  'a temporary ban pays exactly the same -- the expiry is not a discount',
  shape(resolvedRow({ action: 'ban', expiresAt: NOW + HOUR })),
  { found: true, settled: true, payable: true, word: 'banned' },
)
check(
  'a kick pays, and the sentence says kicked',
  shape(resolvedRow({ action: 'kick' })),
  { found: true, settled: true, payable: true, word: 'kicked' },
)
check(
  "an admin who decided 'no action' is settled and pays nobody",
  shape(resolvedRow({ action: 'none' })),
  { found: true, settled: true, payable: false, word: null },
)

// THE CASE THE WHOLE FIELD EXISTS FOR. A resolved row with no verdict is a
// legacy row or a system auto-resolution -- nobody decided anything -- and it is
// NOT 'none'. It must not pay, and it must not be left on the queue forever
// either, because no verdict is ever coming.
check(
  'a resolved row with the verdict attribute absent is settled and pays nobody',
  shape(resolvedRow(undefined)),
  { found: true, settled: true, payable: false, word: null },
)
check(
  'an explicit null verdict is the same state as an absent one',
  shape(resolvedRow(null)),
  { found: true, settled: true, payable: false, word: null },
)
check(
  'absent is reported as action null, never coerced to none',
  projectVerdict(resolvedRow(undefined)).action,
  null,
)

// A PENDING ROW IS NOT A DECISION, however tempting the verdict field looks.
// The console writes state and verdict in one update, so this shape should never
// exist -- and if it ever does, waiting is the only safe reading of it.
check(
  'a pending row is not settled and pays nobody',
  shape({ incidentId: ID, state: 'pending_review', verdict: null }),
  { found: true, settled: false, payable: false, word: null },
)
check(
  'a verdict on a row still marked pending is refused rather than paid',
  shape({ incidentId: ID, state: 'pending_review', verdict: { action: 'ban', expiresAt: null } }),
  { found: true, settled: false, payable: false, word: null },
)

// A ROW THAT IS NOT THERE IS NOT SETTLED. Reporting it as settled would drop the
// claim; the sweep's age cap is what ends it instead.
check(
  'a missing row is not found, not settled, and not payable',
  shape(null),
  { found: false, settled: false, payable: false, word: null },
)
check(
  'undefined is treated the same as a missing row',
  shape(undefined),
  { found: false, settled: false, payable: false, word: null },
)

// A MALFORMED VERDICT IS NOT A VERDICT. An action this reader does not
// recognise reads as absent, which pays nobody and does not guess.
check(
  'an unrecognised action pays nobody',
  shape(resolvedRow({ action: 'warn' })),
  { found: true, settled: true, payable: false, word: null },
)
check(
  'a verdict that is a string rather than an object pays nobody',
  shape(resolvedRow('ban')),
  { found: true, settled: true, payable: false, word: null },
)

// expiresAt IS READ ONLY THROUGH action, never beside it.
check(
  'expiresAt is carried for a temporary ban',
  projectVerdict(resolvedRow({ action: 'ban', expiresAt: NOW + HOUR })).expiresAt,
  NOW + HOUR,
)
check(
  'expiresAt is null for a permanent ban, and for a kick that never had one',
  [
    projectVerdict(resolvedRow({ action: 'ban', expiresAt: null })).expiresAt,
    projectVerdict(resolvedRow({ action: 'kick' })).expiresAt,
  ],
  [null, null],
)

check('the word for a ban is past tense and lower case', verdictWord('ban'), 'banned')
check('the word for a kick is past tense and lower case', verdictWord('kick'), 'kicked')
check('there is no word for no action', verdictWord('none'), null)
check('there is no word for an absent verdict', verdictWord(null), null)

// -------------------------------------------------------- artifact names ---

/**
 * EVERY CASE HERE IS A SECURITY CASE, not a formatting one. The key decides
 * which IAM statement applies -- the grant is `PutObject` on
 * `royale-incidents-bucket/incidents/*` and nothing else -- and the file name
 * decides what the spool sweeper is willing to delete off the game box's disk.
 * Both are built from values that arrived over an event boundary from Lua.
 */
console.log('\nartifact names')

const AID = '0f9c1e2a-3b4c-4d5e-8f60-112233445566'

check(
  'the key is the prefix, the id, the two-digit frame and the extension',
  artifactNames(AID, 1, 'webp').key,
  `incidents/${AID}/01.webp`,
)
check('frame 9 pads to two digits like every other', artifactNames(AID, 9, 'webp').key,
  `incidents/${AID}/09.webp`)
check(
  'the local file is flat, so the sweeper never leaves an empty directory',
  artifactNames(AID, 3, 'webp').file,
  `${AID}-03.webp`,
)
check('webp is stored as image/webp, so a browser draws it rather than downloading it',
  artifactNames(AID, 1, 'webp').contentType, 'image/webp')
check('jpg maps to image/jpeg, not image/jpg',
  artifactNames(AID, 1, 'jpg').contentType, 'image/jpeg')

// THE KEY CANNOT LEAVE THE PREFIX. This is the assertion that pins the grant:
// a key outside `incidents/` is refused by IAM, which would present as every
// upload failing at once with no clue why.
check(
  'every accepted key starts inside the granted prefix',
  ['webp', 'jpg', 'png'].every((e) =>
    artifactNames(AID, 5, e).key.startsWith(ARTIFACT_PREFIX),
  ),
  true,
)

// Rejections. Each of these is a value a compromised or merely broken game side
// could send, and none of them may reach a path or a key.
const bad = [
  ['a traversal in the id', () => artifactNames('../../etc/passwd', 1, 'webp')],
  ['a slash in the id', () => artifactNames(`${AID}/x`, 1, 'webp')],
  ['an id that is not a UUID at all', () => artifactNames('hello', 1, 'webp')],
  ['a v1 UUID -- this resource only ever mints v4', () =>
    artifactNames('0f9c1e2a-3b4c-1d5e-8f60-112233445566', 1, 'webp')],
  ['an empty id', () => artifactNames('', 1, 'webp')],
  ['a non-string id', () => artifactNames(42, 1, 'webp')],
  ['frame 0', () => artifactNames(AID, 0, 'webp')],
  ['frame 10 -- nine is the cap and the namespace', () => artifactNames(AID, 10, 'webp')],
  ['a negative frame', () => artifactNames(AID, -1, 'webp')],
  ['a fractional frame', () => artifactNames(AID, 1.5, 'webp')],
  ['a frame that is not a number', () => artifactNames(AID, 'one', 'webp')],
  ['an encoding with a dot in it', () => artifactNames(AID, 1, '../sh')],
  ['an encoding nobody asked for', () => artifactNames(AID, 1, 'gif')],
  ['no encoding', () => artifactNames(AID, 1, undefined)],
]
for (const [label, fn] of bad) {
  const got = fn()
  check(`refused: ${label}`, typeof got.error === 'string' && !got.key, true)
}

// -------------------------------------------------------- the sweep guard ---

/**
 * `br_artifacts_dir` is a convar. A typo could point it at a directory that
 * matters, so the sweeper deletes only names this module could have produced --
 * which makes the worst case "the spool fills up" rather than "something else
 * was emptied".
 */
console.log('\nspool sweep guard')

check('a name this module produced is sweepable',
  isSpoolFile(artifactNames(AID, 4, 'webp').file), true)
check('and so is one with a jpg extension', isSpoolFile(`${AID}-04.jpg`), true)

const notOurs = [
  'server.cfg',
  'cache',
  '.env',
  'id_rsa',
  `${AID}.webp`,
  `${AID}-4.webp`,
  `${AID}-00.webp`,
  `${AID}-10.webp`,
  `${AID}-04.webp.bak`,
  `../${AID}-04.webp`,
  '0f9c1e2a-3b4c-1d5e-8f60-112233445566-04.webp',
  '',
]
for (const name of notOurs) {
  check(`not swept: ${JSON.stringify(name)}`, isSpoolFile(name), false)
}
check('not swept: a non-string', isSpoolFile(null), false)


// ------------------------------------------------------- the match timeline ---
//
// #30. An incident should show the match around it. These cases are about the
// two things that are expensive to get wrong and invisible when they are:
//
//   * WHICH ATTRIBUTES THE CLOSE TOUCHES. The IAM statement this write needs is
//     an attribute allowlist, so a new attribute appearing in the
//     UpdateExpression is a write that will start failing with
//     AccessDeniedException in production and passing in every test that does
//     not look. The assertions below read the expression itself.
//
//   * WHETHER A TRUNCATED TIMELINE ADMITS IT. A kill list that stops early and
//     reports itself complete tells an admin "this is everything they did" when
//     it is not.

const CLOSE_TABLE = 'ringmaster-incidents'

const killAt = (at, victimLicense, extra = {}) => ({
  at,
  kind: 'kill',
  killerLicense: 'license:subject',
  killerName: 'Subject',
  victimLicense,
  victimName: 'V',
  weapon: 'WEAPON_CARBINERIFLE',
  cause: 'gunshot',
  ...extra,
})

const closeOk = (payload) => {
  const r = buildIncidentClose('inc-1', payload, CLOSE_TABLE)
  if (r.error) throw new Error(`expected a close, got ${r.error}`)
  return r.params
}

// --- the attributes it may touch, which is the IAM contract -----------------

{
  const p = closeOk({
    matchEndedAt: 1_700_000_500_000,
    matchTimeline: [killAt(1_700_000_400_000, 'license:v1'), { at: 1_700_000_500_000, kind: 'match_end' }],
    matchTimelineComplete: true,
    matchKillsSeen: 1,
  })

  const expr = p.UpdateExpression

  // THE ALLOWLIST, ASSERTED AS A SET. Sorted so a reordering of the expression
  // is not a failure but an ADDITION is.
  //
  // FOUR, BECAUSE THIS PAYLOAD CARRIES NO START. That is the narrow form -- the
  // one a match that dissolved on the warmup pad produces, and byte for byte the
  // update this file made before `matchStartedAt` and `matchEndsBy` joined it,
  // so it is still permitted by an IAM policy nobody has widened yet. The wide
  // form is pinned separately below.
  const touched = [...expr.matchAll(/\b(match[A-Za-z]+)\s*=/g)].map((m) => m[1]).sort()
  check('close touches exactly the four game-owned attributes', touched, [
    'matchEndedAt',
    'matchKillsSeen',
    'matchTimeline',
    'matchTimelineComplete',
  ])

  // THE LINE THAT MUST NOT MOVE. `events` is the console's timeline and
  // `verdict`/`state` are an admin's decision. A close that could write any of
  // them would make the game box able to edit a moderation record.
  for (const forbidden of [
    'events',
    'state',
    'verdict',
    'resolvedAt',
    'resolvedByLicense',
    'resolvedByName',
    'resolution',
    'closedByBan',
    'subjectLicense',
    'reporterLicense',
  ]) {
    check(`close cannot write ${forbidden}`, expr.includes(forbidden), false)
  }

  check(
    'close refuses to create a row that is not there',
    p.ConditionExpression,
    'attribute_exists(incidentId)',
  )
  check('close reads nothing back', p.ReturnValues, 'NONE')
  check('close is keyed on the incident id alone', p.Key, { incidentId: 'inc-1' })
  check('close targets the incidents table', p.TableName, CLOSE_TABLE)

  // `if_not_exists` is what makes a row filed by an older game version closable
  // rather than a failed update.
  check(
    'close appends rather than replacing the timeline',
    expr.includes('list_append(if_not_exists(matchTimeline, :empty), :entries)'),
    true,
  )
}

// --- the two attributes a WARMUP-filed case is still missing ----------------
//
// A case filed on the warmup pad is filed before its match has a `startedAt`, so
// its row carries a null start and -- since the deadline is derived from the
// start -- a null `matchEndsBy` too. Both are known by the time the close
// happens, and the close was happening anyway.
//
// THIS IS THE HALF THAT NEEDS A WIDER IAM POLICY THAN THE ONE IN PRODUCTION
// TODAY, which is why the expression is asserted as a SET rather than by
// substring: `dynamodb:Attributes` is evaluated against the whole request, so an
// attribute appearing here that the policy does not name does not lose itself --
// it loses the entire UpdateItem, end timestamp and timeline included.

{
  const p = closeOk({
    matchEndedAt: 1_700_000_500_000,
    matchStartedAt: 1_700_000_100_000,
    matchEndsBy: 1_700_003_700_000,
    matchTimeline: [{ at: 1_700_000_500_000, kind: 'match_end' }],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })

  const touched = [...p.UpdateExpression.matchAll(/\b(match[A-Za-z]+)\s*=/g)]
    .map((m) => m[1])
    .sort()
  check('a close that knows the start writes exactly six attributes', touched, [
    'matchEndedAt',
    'matchEndsBy',
    'matchKillsSeen',
    'matchStartedAt',
    'matchTimeline',
    'matchTimelineComplete',
  ])

  check(
    'and the start it writes is the one it was given',
    p.ExpressionAttributeValues[':start'],
    1_700_000_100_000,
  )
  check(
    'and the deadline likewise',
    p.ExpressionAttributeValues[':endsBy'],
    1_700_003_700_000,
  )

  // NOT `matchCreatedAt`. When the match was FORMED is written once, by the
  // PutItem, onto a row that has it from the first moment. A close restating it
  // would be an eighth attribute on an allowlist for a fact that cannot change.
  check(
    'a close says nothing about when the match was formed',
    p.UpdateExpression.includes('matchCreatedAt'),
    false,
  )
}

// OMITTED, NEVER NULLED. A match that dissolved on the pad ended without ever
// starting. Writing a null would be the same shape as writing a value the row
// does not have -- and if a caller ever failed to pass the start for a match
// that DID run, an unconditional SET would erase a correct value on an ordinary
// case. So a missing start is a smaller update, not a destructive one.
{
  const p = closeOk({
    matchEndedAt: 1_700_000_500_000,
    matchTimeline: [{ at: 1_700_000_500_000, kind: 'match_end' }],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })
  check(
    'a match that never started has no start written over its row',
    p.UpdateExpression.includes('matchStartedAt'),
    false,
  )
  check(
    'and no deadline either',
    p.UpdateExpression.includes('matchEndsBy'),
    false,
  )
  check(
    'and no dangling value for either',
    [':start', ':endsBy'].filter((k) => k in p.ExpressionAttributeValues),
    [],
  )
}

// A START WITHOUT A DEADLINE, which is the shape a br_ringmaster that failed to
// convert the duration would send. Each attribute is decided on its own value,
// so a half-filled payload writes the half it has rather than all or nothing.
{
  const p = closeOk({
    matchEndedAt: 1_700_000_500_000,
    matchStartedAt: 1_700_000_100_000,
    matchTimeline: [],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })
  check(
    'a start with no deadline still writes the start',
    p.UpdateExpression.includes('matchStartedAt = :start'),
    true,
  )
  check(
    'and does not invent a deadline for it',
    p.UpdateExpression.includes('matchEndsBy'),
    false,
  )
}

// --- an incident whose match never ends -------------------------------------

check(
  'a close with no end timestamp is refused',
  buildIncidentClose('inc-1', { matchTimeline: [] }, CLOSE_TABLE).error,
  'no matchEndedAt',
)
check(
  'and refusing it is not worth retrying',
  buildIncidentClose('inc-1', { matchTimeline: [] }, CLOSE_TABLE).retryable,
  undefined,
)
check(
  'a close with no id is refused',
  buildIncidentClose('', { matchEndedAt: 1 }, CLOSE_TABLE).error,
  'no incidentId',
)

// --- a Lua boolean that arrived as a NUMBER ---------------------------------
//
// The `0` half of this hazard is a Lua problem and is tested on the Lua side,
// where `0` is truthy. THE JS HALF IS THE OPPOSITE VALUE: a runtime that hands
// a BOOL back as `1` produces a number that is truthy here, so `=== true` and a
// bare truthy test agree about `0` and disagree about `1`.
//
// These cases therefore assert on `1`, which is the only value that can tell
// the two implementations apart -- asserting on `0` passes under both and
// proves nothing, which is how a test re-encodes the code's own assumption and
// reports a green tick for it.
//
// STRICT IS THE SAFE DIRECTION HERE. Reading `1` as "not a headshot" and "not
// complete" understates the record; reading it as "complete" would put "this is
// everything they did" on a case where it is false.

{
  const p = closeOk({
    matchEndedAt: 2000,
    matchTimeline: [killAt(1000, 'license:v1', { headshot: 1 })],
    matchTimelineComplete: true,
    matchKillsSeen: 1,
  })
  check(
    'a headshot of 1 is not accepted as a boolean true',
    p.ExpressionAttributeValues[':entries'][0].headshot,
    false,
  )
}

// ---------------------------------------------------------------------------
// weaponIssued -- the field the console turns into an accusation
// ---------------------------------------------------------------------------
//
// WHAT IS AT STAKE. The console renders `weaponIssued === false` in red and
// says it is high confidence of cheating, against a named player, with no
// human in the loop. Every one of the three states is pinned here, and the two
// that must NOT produce a claim get more attention than the one that must.

const entryOf = (extra) =>
  closeOk({
    matchEndedAt: 2000,
    matchTimeline: [killAt(1000, 'license:v1', extra)],
    matchTimelineComplete: true,
    matchKillsSeen: 1,
  }).ExpressionAttributeValues[':entries'][0]

{
  const e = entryOf({ weaponIssued: true, weaponLabel: 'Carbine Rifle' })
  check('an issued weapon is stored as issued', e.weaponIssued, true)
  check('and carries its display label', e.weaponLabel, 'Carbine Rifle')
}
{
  const e = entryOf({ weaponIssued: false })
  check('a weapon we do not issue is stored as not issued', e.weaponIssued, false)
  check('and has no label to show for it', e.weaponLabel, null)
}

// ABSENT MUST SURVIVE AS ABSENT. This is the one that would ship quietly: a
// spread default, or an `e.weaponIssued === true` written straight into the
// object, turns every storm death and every case filed before the field
// existed into `false` -- which the console reads as cheating.
{
  const e = entryOf({})
  check(
    'a kill with no weapon claim stores no weaponIssued key at all',
    Object.prototype.hasOwnProperty.call(e, 'weaponIssued'),
    false,
  )
}

// TRUTHINESS IS NOT ACCEPTED IN EITHER DIRECTION, the same discipline the
// headshot check above applies, and for the same reason: `0` is truthy in Lua,
// so a future producer sending one must not be read as an answer.
{
  const e = entryOf({ weaponIssued: 0 })
  check('a weaponIssued of 0 is not an answer', Object.prototype.hasOwnProperty.call(e, 'weaponIssued'), false)
}
{
  const e = entryOf({ weaponIssued: 1 })
  check('a weaponIssued of 1 is not an answer either', Object.prototype.hasOwnProperty.call(e, 'weaponIssued'), false)
}
{
  const e = entryOf({ weaponIssued: 'false' })
  check('nor is the string "false"', Object.prototype.hasOwnProperty.call(e, 'weaponIssued'), false)
}

// THE HASH FORM. The gunshot path stores data.weaponType, a number, and str()
// answers null for a number -- so before this was fixed the commonest kill in
// the game recorded nothing about what did it.
{
  const e = entryOf({ weapon: -2084633992, weaponIssued: false })
  check('a numeric weapon identifier is kept, not dropped', e.weapon, '-2084633992')
}
{
  const e = entryOf({ weapon: 'carbinerifle' })
  check('and a string identifier is untouched', e.weapon, 'carbinerifle')
}

{
  const p = closeOk({
    matchEndedAt: 2000,
    matchTimeline: [{ at: 2000, kind: 'match_end' }],
    matchTimelineComplete: 1,
    matchKillsSeen: 0,
  })
  check(
    'a complete flag of 1 is not accepted as complete',
    p.ExpressionAttributeValues[':complete'],
    false,
  )
}
{
  const p = closeOk({
    matchEndedAt: 2000,
    matchTimeline: [{ at: 2000, kind: 'match_end' }],
    matchTimelineComplete: 0,
    matchKillsSeen: 0,
  })
  check(
    'and a complete flag of 0 certainly does not',
    p.ExpressionAttributeValues[':complete'],
    false,
  )
}
{
  const p = closeOk({
    matchEndedAt: 2000,
    matchTimeline: [{ at: 2000, kind: 'match_end' }],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })
  check(
    'and a real true still means complete',
    p.ExpressionAttributeValues[':complete'],
    true,
  )
}

// --- truncation is reported, never silent -----------------------------------

{
  // The Lua side already dropped rows: it saw 40 kills and is sending 3.
  const p = closeOk({
    matchEndedAt: 9000,
    matchTimeline: [killAt(1, 'license:a'), killAt(2, 'license:b'), { at: 9000, kind: 'match_end' }],
    matchTimelineComplete: false,
    matchKillsSeen: 40,
  })
  check(
    'a timeline the game already truncated stays truncated',
    p.ExpressionAttributeValues[':complete'],
    false,
  )
  check(
    'and it carries how many kills really happened',
    p.ExpressionAttributeValues[':seen'],
    40,
  )
}

// --- the volume bound -------------------------------------------------------

{
  const many = []
  for (let i = 0; i < 400; i++) many.push(killAt(1000 + i, `license:v${i}`))
  many.push({ at: 99_000, kind: 'match_end' })

  const p = closeOk({
    matchEndedAt: 99_000,
    matchTimeline: many,
    matchTimelineComplete: true,
    matchKillsSeen: 400,
  })

  const entries = p.ExpressionAttributeValues[':entries']
  check('a close is bounded', entries.length, CLOSE_LIMITS.MAX_CLOSE_ENTRIES)
  check(
    'and keeps the RECENT end of the match',
    entries[entries.length - 1],
    { at: 99_000, kind: 'match_end' },
  )
  // Dropping rows and still claiming completeness is the exact failure the flag
  // exists to prevent.
  check(
    'a bounded close does not claim to be complete',
    p.ExpressionAttributeValues[':complete'],
    false,
  )

  // THE BACKSTOP HAS TO SIT ABOVE WHAT THE LUA SIDE CAN LEGITIMATELY SEND, or
  // it is not a backstop -- it is this file deleting the oldest rows of every
  // large close. The Lua ceiling is MAX_TIMELINE_KILLS + MAX_TIMELINE_STRIPS +
  // MAX_TIMELINE_CHAT + the match_end; those three constants live in
  // br_lib/shared/incident_build.lua and are 250, 60 and 60.
  check(
    'and the bound is above the largest close the game can build',
    CLOSE_LIMITS.MAX_CLOSE_ENTRIES >= 250 + 60 + 60 + 1,
    true,
  )
}

// --- an unissued weapon in the hand -----------------------------------------
//
// THE ENTRY KIND ADDED FOR THE STRIP REPORT. `timelineEntry` drops kinds it does
// not know, deliberately, so the failure mode of getting this wrong is silence:
// the Lua side builds the entries, this side discards every one of them, and
// both suites stay green. That is why the spelling is asserted rather than
// assumed.

{
  const p = closeOk({
    matchEndedAt: 9000,
    matchTimeline: [
      { at: 6000, kind: 'weapon_strip', weapon: 2210333304 },
      { at: 7000, kind: 'weapon_strip' },
      { at: 9000, kind: 'match_end' },
    ],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })
  const entries = p.ExpressionAttributeValues[':entries']

  check('a strip entry survives the projection', entries.length, 3)
  check('and keeps its kind', entries[0].kind, 'weapon_strip')

  // THE HASH IS THE ONLY IDENTIFIER ANYBODY HAS for a weapon this gamemode has
  // never heard of, and `str()` answers null for a number -- so without the
  // coercion every strip would store `weapon: null`, which is the whole content
  // of the finding thrown away. Exactly the bug the kill path already had.
  check('the weapon hash reaches the row as a string', entries[0].weapon, '2210333304')
  check('a strip with no weapon stores null, not a lie', entries[1].weapon, null)

  // NO SECOND-PARTY FIELDS. A strip has no victim and no killer; the row's own
  // subjectLicense is who it is about.
  check('a strip names nobody but the subject', entries[0].victimLicense, undefined)
  check('and carries no weaponIssued -- the kind IS the claim',
    Object.prototype.hasOwnProperty.call(entries[0], 'weaponIssued'), false)

  check(
    'a timeline of strips is still complete when nothing was dropped',
    p.ExpressionAttributeValues[':complete'],
    true,
  )
}

// --- a chat line the server would not carry ---------------------------------
//
// THE ENTRY KIND ADDED FOR THE CHAT SCREEN, and the same silence applies:
// `timelineEntry` drops what it does not know, so a spelling that disagrees with
// br_lib/shared/incident_build.lua's CHAT_KIND fails nothing here or there and
// simply means no refused line ever reaches a moderation record.
//
// THIS IS THE FIRST PLAYER-AUTHORED PROSE ON THIS LIST. Everything else is a
// fact the server measured; `text` is what somebody typed, which is why it is
// capped and why what it does with hostile input is asserted rather than assumed.

{
  const p = closeOk({
    matchEndedAt: 9000,
    matchTimeline: [
      {
        at: 6000,
        kind: 'chat_block',
        text: 'join evilserver.com now',
        reason: 'link',
        channel: 'global',
      },
      { at: 7000, kind: 'chat_block', text: 'привет', reason: 'script', channel: 'squad' },
      { at: 9000, kind: 'match_end' },
    ],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })
  const entries = p.ExpressionAttributeValues[':entries']

  check('a refused chat entry survives the projection', entries.length, 3)
  check('and keeps its kind', entries[0].kind, 'chat_block')
  check(
    'THE CHAT CONTENT REACHES THE ROW -- the whole point of the feature',
    entries[0].text,
    'join evilserver.com now',
  )
  check('which rule refused it travels too', entries[0].reason, 'link')
  check('and the channel it was sent on', entries[0].channel, 'global')
  check('a non-Latin line is stored as it was written', entries[1].text, 'привет')
  check('with its own reason', entries[1].reason, 'script')
  // A rival server advertised to the whole lobby and one whispered to three
  // squadmates are different facts about intent.
  check('a squad whisper is distinguishable from a lobby advert', entries[1].channel, 'squad')

  // NO SECOND-PARTY FIELDS, like a strip: a refused line is a fact about the
  // subject's own message and the row already names them.
  check('a refused line names nobody but the subject', entries[0].victimLicense, undefined)
  check(
    'and carries no weaponIssued, which would paint it red on the console',
    Object.prototype.hasOwnProperty.call(entries[0], 'weaponIssued'),
    false,
  )
}

// --- what the text field does with input chosen to break something -----------
//
// A PLAYER PICKS THIS STRING. The console renders timeline entries as React text
// children and escapes structurally, so the job here is a bound and a type --
// not an escape, which would double-encode on the page.

{
  const long = 'x'.repeat(500)
  const p = closeOk({
    matchEndedAt: 9000,
    matchTimeline: [
      { at: 1000, kind: 'chat_block', text: long, reason: 'link' },
      { at: 2000, kind: 'chat_block', text: '<script>alert(1)</script>', reason: 'link' },
      { at: 3000, kind: 'chat_block', text: '', reason: 'link' },
      { at: 4000, kind: 'chat_block', reason: 'link' },
      { at: 5000, kind: 'chat_block', text: { evil: true }, reason: 'link' },
      { at: 6000, kind: 'chat_block', text: 'ok', reason: 'made up by a client' },
      { at: 9000, kind: 'match_end' },
    ],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })
  const e = p.ExpressionAttributeValues[':entries']

  // 200 IS BR.ChatLimits.maxLength -- the length the server already refuses to
  // deliver past -- rather than a new number invented for storage.
  check('an over-long line is capped at the length chat itself allows', e[0].text.length, 200)
  check(
    'markup is stored verbatim as TEXT, never escaped here',
    e[1].text,
    '<script>alert(1)</script>',
  )
  check('an empty line stores null rather than a blank accusation', e[2].text, null)
  check('an absent line stores null too', e[3].text, null)
  check('a non-string cannot become "[object Object]"', e[4].text, null)
  check('an unrecognised reason is stored, bounded, for a human to read', e[5].reason.length <= 32, true)

  // THE KIND IS STILL DROPPED IF IT IS NOT ONE OF OURS -- the property the whole
  // discrimination rests on, asserted beside the kind that was just added.
  const q = closeOk({
    matchEndedAt: 9000,
    matchTimeline: [
      { at: 1000, kind: 'chat_blocked', text: 'nearly right' },
      { at: 9000, kind: 'match_end' },
    ],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })
  check(
    'a kind one letter off is dropped, silently, exactly as designed',
    q.ExpressionAttributeValues[':entries'].length,
    1,
  )
  check(
    'and the close then reports itself INCOMPLETE rather than whole',
    q.ExpressionAttributeValues[':complete'],
    false,
  )
}

// --- a match that was formed but had not started ----------------------------
//
// THE SAME SILENT-DROP HAZARD AS THE STRIP KIND, AND THE REASON THIS ENTRY
// EXISTS AT ALL. `startedAt` is stamped on entering PLAYING, so a case filed on
// the warmup pad has no `match_start` to anchor its timeline on. The rejected
// alternative was to put the creation time in `matchStartedAt`, which would have
// made `match_start` mean "the lobby opened" on some rows and "the match began"
// on others -- one field, two facts, no way for a reader to tell them apart.

{
  const p = closeOk({
    matchEndedAt: 9000,
    matchTimeline: [
      { at: 500, kind: 'match_created' },
      { at: 6000, kind: 'weapon_strip', weapon: 2210333304 },
      { at: 9000, kind: 'match_end' },
    ],
    matchTimelineComplete: true,
    matchKillsSeen: 0,
  })
  const entries = p.ExpressionAttributeValues[':entries']

  check('a match_created entry survives the projection', entries.length, 3)
  check('and keeps its kind', entries[0].kind, 'match_created')
  check('and its time', entries[0].at, 500)

  // A BOOKEND, NOT A KILL. It carries the two fields every entry carries and
  // nothing else -- there is no subject, no weapon and no second party in "a
  // lobby opened".
  check('and carries nothing else', Object.keys(entries[0]).sort(), ['at', 'kind'])

  check(
    'a timeline anchored on a formed match is still complete',
    p.ExpressionAttributeValues[':complete'],
    true,
  )
}

// --- the shape the console reads --------------------------------------------

{
  const p = closeOk({
    matchEndedAt: 5000,
    matchTimeline: [
      killAt(4000, 'license:victim'),
      { at: 4500, kind: 'thing-from-the-future' },
      { at: 5000, kind: 'match_end' },
    ],
    matchTimelineComplete: true,
    matchKillsSeen: 1,
  })
  const entries = p.ExpressionAttributeValues[':entries']

  // A KIND NOBODY CAN RENDER IS NOT STORED. Heterogeneous-by-`kind` is what
  // makes #34's artifact entry free later; it is not a licence to store
  // anything a caller sends onto a moderation record.
  check('an unknown entry kind is dropped', entries.length, 2)
  check(
    'a dropped entry means the timeline is not complete',
    p.ExpressionAttributeValues[':complete'],
    false,
  )

  // THE PROFILE LINK #30 ASKS FOR. A display name is neither unique nor stable;
  // the console keys profiles by licence.
  check('a kill carries the victim licence', entries[0].victimLicense, 'license:victim')
  check('and the killer licence', entries[0].killerLicense, 'license:subject')
  check('and a name to render before the profile loads', entries[0].victimName, 'V')
}

// --- what the FILING writes, which costs no extra write ---------------------

{
  const item = buildIncidentItem(
    'inc-2',
    {
      subjectLicense: 'license:subject',
      subjectName: 'Subject',
      matchId: 7,
      matchStartedAt: 1_700_000_000_000,
      matchEndsBy: 1_700_003_600_000,
      matchTimeline: [
        { at: 1_700_000_000_000, kind: 'match_start' },
        killAt(1_700_000_100_000, 'license:v1'),
      ],
      matchTimelineComplete: true,
      matchKillsSeen: 1,
      atGameMs: 1_700_000_200_000,
      openedAt: 1_700_000_200_000,
    },
    NOW,
  ).item

  check('the filing records when the match started', item.matchStartedAt, 1_700_000_000_000)
  // THE WHOLE OF "STILL IN PROGRESS". Written at filing time so it survives the
  // game box never coming back.
  check('and when it is expected to be over by', item.matchEndsBy, 1_700_003_600_000)
  // ABSENT MEANS UNKNOWN, NOT ENDED. The close write is the only thing that
  // fills this in.
  check('and does not claim the match has ended', item.matchEndedAt, null)
  check('the seed timeline is on the row', item.matchTimeline.length, 2)
  check('starting with the match start', item.matchTimeline[0].kind, 'match_start')
  check('then the kill', item.matchTimeline[1].kind, 'kill')
  check(
    'with the licence the profile link needs',
    item.matchTimeline[1].victimLicense,
    'license:v1',
  )
}

{
  // NO MATCH, NO TIMELINE. A `brrefuse` from a console carries none, and
  // inventing one would put a match on the record that never happened.
  const item = buildIncidentItem(
    'inc-3',
    { subjectLicense: 'license:subject', openedAt: 1 },
    NOW,
  ).item
  check('a case filed outside a match has no match start', item.matchStartedAt, null)
  check('and no deadline', item.matchEndsBy, null)
  check('nor any hint of a match having been formed', item.matchCreatedAt, null)
  check('and an empty timeline', item.matchTimeline, [])
  check('and does not claim completeness it cannot have', item.matchTimelineComplete, false)
}

// --- what a case filed during WARMUP writes ---------------------------------
//
// THE SHAPE THIS WHOLE CHANGE IS ABOUT. A weapon this gamemode never issued,
// taken out of a hand on the warmup pad: filed before the match has a
// `startedAt`, and until now filed with no match context of any kind. The row
// carries a matchId, so "filed outside a match" -- which is what the console
// reads from a null start -- is false about it.

{
  const item = buildIncidentItem(
    'inc-4',
    {
      subjectLicense: 'license:subject',
      subjectName: 'Subject',
      matchId: 7,
      // NO matchStartedAt AND NO matchEndsBy. The match has not begun.
      matchCreatedAt: 1_700_000_000_000,
      matchTimeline: [
        { at: 1_700_000_000_000, kind: 'match_created' },
        { at: 1_700_000_050_000, kind: 'weapon_strip', weapon: 2210333304 },
      ],
      matchTimelineComplete: true,
      matchKillsSeen: 0,
      openedAt: 1_700_000_050_000,
    },
    NOW,
  ).item

  check('a warmup case records when its match was formed', item.matchCreatedAt, 1_700_000_000_000)

  // THE LINE THAT MUST NOT MOVE. The creation time is a different fact from the
  // start, and the moment one is allowed to stand in for the other, every reader
  // of `matchStartedAt` -- the console header, `matchEndsBy`, the `match_start`
  // entry -- inherits an ambiguity nothing on the row can resolve.
  check('and still says the match has not started', item.matchStartedAt, null)
  check('and offers no deadline derived from a start it does not have', item.matchEndsBy, null)
  check('and does not claim the match has ended', item.matchEndedAt, null)

  // AND THE CASE IS ABOUT A MATCH, which is the fact the old shape lost.
  check('the row still names the match it belongs to', item.matchId, 7)

  check('the timeline is anchored on the formation', item.matchTimeline[0].kind, 'match_created')
  check('at the time the match was formed', item.matchTimeline[0].at, 1_700_000_000_000)
  // THE EVIDENCE ITSELF. A warmup filing used to send an EMPTY timeline, so the
  // strip that opened the case reached the row nowhere at all -- the evidence
  // records carry chat and kills, and a strip is neither.
  check('and the strip that opened the case is on it', item.matchTimeline[1].kind, 'weapon_strip')
  check('with the hash the client reported', item.matchTimeline[1].weapon, '2210333304')
}

// ------------------------------------------------------------------ spend ---
//
// ═══ A FAKE DYNAMODB, AND WHY THERE IS ONE HERE ═══
//
// `br:ddb:spend`'s whole feature is a ConditionExpression -- "DynamoDB must
// refuse an overspend, not our code" -- and a test that only inspected the
// string would prove that a string exists. So the block below EVALUATES the
// expression the source produced, against a row, and asserts what happens to
// the row. An overspend has to actually be refused for these to pass.
//
// THE FAKE IS IN THE TEST AND MUST NEVER MIGRATE INTO src/. A second
// implementation of a rule is this repository's signature defect when it ships;
// in a test it is the standard way to drive a database that is not present, and
// tools/test_stats.lua already stubs br_ddb the same way for the award sweep.
//
// IT UNDERSTANDS `>` AS WELL AS `>=` ON PURPOSE. If it only knew the operator
// the source happens to use, weakening `>=` to `>` would make the evaluator
// throw and the failure would be about the fake rather than about the rule.
// Knowing both means the boundary case -- spending a balance down to exactly
// zero -- is what tells the two apart, which is the discrimination that matters.

/**
 * Apply one UpdateItem-shaped command to a plain row.
 *
 * Supports exactly the two clause forms this file's verbs produce: a condition
 * `#name <op> :value`, and an `ADD #a :x, #b :y` update. Anything else throws,
 * loudly, rather than being silently ignored -- a clause the fake cannot read is
 * a clause the assertions below are not really testing.
 *
 * @returns {{ ok: boolean, row: object }}  ok=false is ConditionalCheckFailed
 */
function fakeUpdate(row, cmd) {
  const names = cmd.ExpressionAttributeNames || {}
  const values = cmd.ExpressionAttributeValues || {}
  const out = { ...row }

  if (cmd.ConditionExpression) {
    const m = /^\s*(#\w+)\s*(>=|>|<=|<|=)\s*(:\w+)\s*$/.exec(cmd.ConditionExpression)
    if (!m) throw new Error(`fakeUpdate cannot read condition: ${cmd.ConditionExpression}`)
    const attr = names[m[1]]
    const want = values[m[3]]
    if (attr === undefined || want === undefined) {
      throw new Error(`fakeUpdate: unbound placeholder in ${cmd.ConditionExpression}`)
    }
    const have = out[attr]
    // DYNAMODB'S OWN RULE: a comparison against an attribute that is not there
    // is FALSE, not zero. A row that never earned anything cannot spend.
    let pass = false
    if (have !== undefined && have !== null) {
      if (m[2] === '>=') pass = have >= want
      else if (m[2] === '>') pass = have > want
      else if (m[2] === '<=') pass = have <= want
      else if (m[2] === '<') pass = have < want
      else pass = have === want
    }
    if (!pass) return { ok: false, row }
  }

  const add = /(?:^|\s)ADD\s+(.+)$/.exec(cmd.UpdateExpression || '')
  if (!add) throw new Error(`fakeUpdate cannot read update: ${cmd.UpdateExpression}`)
  for (const term of add[1].split(',')) {
    const t = /^\s*(#\w+)\s+(:\w+)\s*$/.exec(term)
    if (!t) throw new Error(`fakeUpdate cannot read ADD term: ${term}`)
    const attr = names[t[1]]
    const delta = values[t[2]]
    if (attr === undefined || delta === undefined) {
      throw new Error(`fakeUpdate: unbound placeholder in ADD ${term}`)
    }
    out[attr] = (out[attr] ?? 0) + delta
  }
  return { ok: true, row: out }
}

console.log('\nspend: the amount')
check('a plain cost is taken', spendCost(750), 750)
check('a string from Lua still coerces', spendCost('750'), 750)
// THE MINT THAT MUST NOT EXIST. A debit verb that accepted a negative amount
// would ADD to the balance, and "the currency is earned, never bought" would
// stop being a property of the system.
check('a negative amount is refused outright', spendCost(-750), null)
check('and so is zero -- charging nothing is a caller bug', spendCost(0), null)
check('a fraction is refused rather than rounded', spendCost(12.5), null)
check('NaN is refused', spendCost('nonsense'), null)
check('and so is an absurd amount', spendCost(SPEND_MAX + 1), null)
check('but the ceiling itself is allowed', spendCost(SPEND_MAX), SPEND_MAX)

console.log('\nspend: the condition refuses an overspend')
{
  const cmd = spendUpdate(750)

  // THE HAPPY PATH, so the failures below mean something.
  const rich = fakeUpdate({ balance: 1000, owned: new Set(['chute_azure']) }, cmd)
  check('an affordable spend applies', rich.ok, true)
  check('and debits exactly the cost', rich.row.balance, 250)

  // ═══ THE CASE THIS VERB EXISTS FOR ═══
  const poor = fakeUpdate({ balance: 700 }, cmd)
  check('a balance short of the cost is REFUSED', poor.ok, false)
  check('and nothing is taken from it', poor.row.balance, 700)

  // The boundary, which is also what tells `>=` from `>`. Spending your last
  // Volt on a car is a purchase, not an overdraft -- the same rule
  // BR.ShopSolve.canBuy states on the cache side.
  const exact = fakeUpdate({ balance: 750 }, cmd)
  check('a balance of exactly the cost is allowed', exact.ok, true)
  check('and lands on zero', exact.row.balance, 0)

  // A row that has never earned anything. Absent is not zero.
  const fresh = fakeUpdate({}, cmd)
  check('a row with no balance attribute cannot spend', fresh.ok, false)
  check('and no balance is invented for it', fresh.row.balance, undefined)

  // Twice over is twice charged -- this verb is deliberately NOT idempotent,
  // which is the whole difference from `purchase`.
  const once = fakeUpdate({ balance: 1600 }, cmd)
  const twice = fakeUpdate(once.row, cmd)
  check('a repeatable spend is repeatable', twice.ok, true)
  check('and charges again', twice.row.balance, 100)
  check('a third refuses on the remainder', fakeUpdate(twice.row, cmd).ok, false)

  // ═══ NO `owned` SET, WHICH IS WHY `purchase` COULD NOT BE REUSED ═══
  check('the debit touches one attribute', Object.keys(cmd.ExpressionAttributeNames), ['#bal'])
  check('and that attribute is the balance', cmd.ExpressionAttributeNames['#bal'], 'balance')
  check('nothing is marked owned', /own/i.test(JSON.stringify(cmd)), false)

  // The two placeholders, which must not be collapsed into one.
  check('the update adds the negative', cmd.ExpressionAttributeValues[':neg'], -750)
  check('the condition compares the positive', cmd.ExpressionAttributeValues[':cost'], 750)
}

// ------------------------------------------------------------ stats writes ---
//
// The payout's expression is load-bearing and this file had no opinion about it
// until `brvolts` became a second caller of the same verb. Two properties:
// the payout's own write must not have moved, and a caller that does not claim
// to be a match must not blank the fields a match sets.

/**
 * A whole match result, in the shape br_stats/server/persist.lua builds it.
 *
 * NAMED RATHER THAN INLINE because the handler block at the bottom of this file
 * sends this exact payload through `br:ddb:statsApply` and pins the same
 * expression coming out the other side. Two payloads that were meant to be the
 * same and drifted would make the second block agree with a bug in the first.
 */
const MATCH_PAYOUT = {
  xp: 1048, balance: 1200, matches: 1, wins: 1, top10s: 1, kills: 3,
  deaths: 0, downs: 1, revives: 2, damageDealt: 450, playtimeSec: 900,
  soloMatches: 1, squadMatches: 0,
  level: 12, name: 'Epyc', at: 1_700_000_000_000,
}

/** What that payload must become, byte for byte. */
const PAYOUT_EXPRESSION =
  'SET #lvl = :lvl, #nm = :nm, #ls = :ls ADD #xp :xp, #balance :balance,'
  + ' #matches :matches, #wins :wins, #top10s :top10s, #kills :kills,'
  + ' #deaths :deaths, #downs :downs, #revives :revives,'
  + ' #damageDealt :damageDealt, #playtimeSec :playtimeSec,'
  + ' #soloMatches :soloMatches, #squadMatches :squadMatches'

console.log('\nstats: the match payout writes what it always wrote')
{
  const payout = buildStatsUpdate(MATCH_PAYOUT)

  // PINNED AS A STRING, because this is the one assertion that says "the money
  // path did not move when the SET clause became conditional".
  check(
    'the expression is byte for byte the one it shipped with',
    payout.UpdateExpression,
    PAYOUT_EXPRESSION,
  )
  check('the level it derived is written', payout.ExpressionAttributeValues[':lvl'], 12)
  check('the name it saw is written', payout.ExpressionAttributeValues[':nm'], 'Epyc')
  check('and the match end is stamped', payout.ExpressionAttributeValues[':ls'], 1_700_000_000_000)

  // Applied to a row, it is still an ADD and still atomic in the sense that
  // matters here: it composes with whatever was already there.
  const after = fakeUpdate({ balance: 300, kills: 40 }, payout)
  check('the balance accumulates rather than replacing', after.row.balance, 1500)
  check('and so does every other counter', after.row.kills, 43)
}

console.log('\nstats: a grant is not a match')
{
  // What `brvolts` sends: an amount, and no claim about anything else.
  const grant = buildStatsUpdate({ balance: 5000 })

  check(
    'a caller that names no match fields writes no SET clause at all',
    grant.UpdateExpression.startsWith('ADD '),
    true,
  )
  // ═══ THE THREE FIELDS A GRANT MUST NOT TOUCH ═══
  //
  // The first version of this wrote all three unconditionally with `num()` and
  // `String()` fallbacks, so THIS payload would have set the player to level 0,
  // blanked their name, and stamped lastMatchAt 0 -- silently, on a live
  // profile row, every time somebody granted themselves Volts to test the shop.
  check('no level is claimed', grant.ExpressionAttributeValues[':lvl'], undefined)
  check('no name is written', grant.ExpressionAttributeValues[':nm'], undefined)
  check('and no match end is stamped', grant.ExpressionAttributeValues[':ls'], undefined)

  const before = { balance: 120, level: 12, name: 'Epyc', lastMatchAt: 1_700_000_000_000 }
  const after = fakeUpdate(before, grant).row
  check('the grant lands on the balance', after.balance, 5120)
  check('the level survives it', after.level, 12)
  check('the name survives it', after.name, 'Epyc')
  check('and so does the last match', after.lastMatchAt, 1_700_000_000_000)

  // Present-and-zero is a value, not an absence. A caller that means level 0
  // has a bug of its own and this function is not the place to hide it.
  const explicit = buildStatsUpdate({ balance: 1, level: 0 })
  check('an explicit zero is still written', explicit.ExpressionAttributeValues[':lvl'], 0)
  // ...and the empty string is treated as absent, because '' is exactly what
  // the old unconditional write produced from a missing name.
  const blank = buildStatsUpdate({ balance: 1, name: '' })
  check('but an empty name is an absent one', blank.ExpressionAttributeValues[':nm'], undefined)
}

// -------------------------------------------------------------- handlers ---
//
// ═══ EVERYTHING ABOVE THIS LINE TESTS A FUNCTION. NOTHING ABOVE IT RAN A
//     HANDLER, AND THAT COST THE OWNER A NIGHT OF PLAYER DATA ═══
//
// On 2026-08-29, aafe22a moved the stats expression out of src/index.js into
// src/stats.js, where `deltas` is rebound as a local `d`. The CALL SITE kept the
// old name:
//
//     on('br:ddb:statsApply', (req, license, deltas) => {
//       ...
//       const built = buildStatsUpdate(d)      // `d` is not in this scope
//
// Every check in this file went green, `verify.sh` went green, the fingerprint
// gate went green, and the bundle built without a murmur -- esbuild treats an
// unbound identifier as a global and says nothing. The first thing that
// noticed was a live server, where every match end threw
//
//     ReferenceError: d is not defined   @br_ddb/dist/server.js:60
//
// BEFORE the UpdateItem was sent, so XP, Volts, balance and every career
// counter stopped persisting entirely -- while `br:market:credited` had already
// moved br_core's session cache, so the players were shown numbers the database
// never received.
//
// The gap was not "no test for statsApply". It was that a file which is
// twenty event registrations and nothing else had never been IMPORTED here,
// because importing it means importing the AWS SDK. scripts/bridge.mjs and
// scripts/aws_stub.mjs remove that reason. The handlers run now.

const bridge = await loadBridge()

/**
 * The nth command a handler sent, or an empty stand-in.
 *
 * A HANDLER THAT SENT NOTHING MUST NOT CRASH THE SUITE. That is not
 * hypothetical politeness -- it is what the 2026-08-30 bug does: it throws
 * before the send, so `calls[0]` is undefined and every assertion after it
 * would die on a TypeError instead of reporting. The failures below are the
 * evidence; losing eighty of them to the first one is how a suite stops being
 * read.
 */
const sent = (i) => bridge.calls[i] ?? { kind: null, input: {} }

/**
 * A throw, as a line worth reading.
 *
 * `check` compares with JSON.stringify and an Error stringifies to `{}` -- so
 * the one assertion that mattered on 2026-08-30 would have reported "got {}".
 * The message IS the finding here: it is the sentence the live server printed.
 */
const why = (e) => (e === null ? null : `${e.name}: ${e.message}`)

/** What a verb answered on its result channel, in the three parts it has. */
const answer = (verb) => {
  const e = lastEmit(verb)
  return { req: e?.args[0], ok: e?.args[1], extra: e?.args[2] ?? {} }
}

console.log('\nstats: the handler, not just the expression it builds')
{
  bridge.reset()
  bridge.reply({}) // DynamoDB accepts the write

  const threw = bridge.call('br:ddb:statsApply', 41, LIC, MATCH_PAYOUT)

  // ═══ THE ASSERTION THIS BLOCK EXISTS FOR ═══
  //
  // Red against the bug, with the production message in the `got` line.
  check(
    'the handler runs -- no free variable in its body',
    why(threw),
    null,
  )

  // ...and red against a "fix" that made it run without carrying anything.
  check('one UpdateItem reached DynamoDB', bridge.calls.length, 1)

  const cmd = sent(0)
  check('it is an UpdateItem', cmd.kind, 'UpdateItemCommand')
  // The GAME's table, not the console's. Defaulting the prefix is how the first
  // version of profileFetch read `ringmaster-players`.
  check('against the game table', cmd.input.TableName, 'br-players')
  check('keyed on the profile row for that licence', cmd.input.Key, {
    pk: { S: LIC },
    sk: { S: 'profile' },
  })

  // THE SAME PIN AS THE BLOCK ABOVE, TAKEN OFF THE WIRE INSTEAD OF OFF THE
  // BUILDER. That is the whole difference: this one can only pass if the
  // handler actually passed the caller's deltas to the builder.
  check(
    'the expression on the wire is the payout expression',
    cmd.input.UpdateExpression,
    PAYOUT_EXPRESSION,
  )

  const values = unmarshall(cmd.input.ExpressionAttributeValues)
  // `buildStatsUpdate({})` would still produce a valid ADD of thirteen zeroes,
  // which is a shape a passing test could easily accept and a player would
  // experience as a match that paid nothing. So the NUMBERS are asserted, and
  // they are the caller's.
  check("the caller's XP is on the wire", values[':xp'], 1048)
  check('and the Volts the match paid', values[':balance'], 1200)
  check('and the level br_stats derived', values[':lvl'], 12)
  check('and the name it saw', values[':nm'], 'Epyc')

  // End to end: the command the handler built, applied to a profile row.
  // Guarded, because `fakeUpdate` throws on an expression it cannot read and a
  // handler that sent nothing has no expression at all.
  const applied = typeof cmd.input.UpdateExpression === 'string'
    ? fakeUpdate({ balance: 300, kills: 40 }, {
      UpdateExpression: cmd.input.UpdateExpression,
      ExpressionAttributeNames: cmd.input.ExpressionAttributeNames,
      ExpressionAttributeValues: values,
    })
    : { row: {} }
  check('a profile row moves by exactly the match', applied.row.balance, 1500)
  check('and every other counter with it', applied.row.kills, 43)

  await bridge.settle()
  // The `req` must come back untouched: br_stats keys `pending[req]` on it and
  // an answer under the wrong number is an answer nobody is listening for.
  check('br_stats is told the write landed', lastEmit('br:ddb:statsResult')?.args, [41, true, {}])
}

console.log('\nstats: a failed write answers and never throws into the match')
{
  bridge.reset()
  bridge.reply(new Error('ProvisionedThroughputExceededException'))

  // "A STATS FAILURE MUST NEVER STOP A MATCH" is stated at the handler and was
  // true of every path it could reach -- except the one that threw before the
  // send, which is exactly the one that happened.
  const threw = bridge.call('br:ddb:statsApply', 42, LIC, MATCH_PAYOUT)
  check('nothing is thrown back at br_stats', why(threw), null)

  await bridge.settle()
  const res = answer('br:ddb:statsResult')
  check('the failure is reported rather than swallowed', res.ok, false)
  check('with the reason attached', res.extra.error, 'ProvisionedThroughputExceededException')
  check(
    'and logged against the licence',
    bridge.logs.some((l) => l.includes('stats write failed for ' + LIC)),
    true,
  )
}

console.log('\nstats: brvolts rides the same handler')
{
  bridge.reset()
  bridge.reply({})

  // What br_core/server/debug.lua sends: an amount, and no claim about a match.
  const threw = bridge.call('br:ddb:statsApply', 43, LIC, { balance: 5000 })
  check('the grant runs too', why(threw), null)

  const cmd = sent(0)
  check(
    'a grant sends no SET clause',
    String(cmd.input.UpdateExpression ?? '').startsWith('ADD '),
    true,
  )

  const values = unmarshall(cmd.input.ExpressionAttributeValues)
  check('so no name is blanked on the row', values[':nm'], undefined)
  check('and no level is claimed', values[':lvl'], undefined)
  check('while the Volts are on the wire', values[':balance'], 5000)
}

console.log('\nspend: the debit reaches DynamoDB with its condition intact')
{
  bridge.reset()
  bridge.reply({ Attributes: { balance: { N: '250' } } })

  const threw = bridge.call('br:ddb:spend', 44, LIC, 750)
  check('the handler runs', why(threw), null)

  const cmd = sent(0)
  // THE CONDITION IS THE WHOLE FEATURE (src/spend.js). A handler that built it
  // and forgot to put it on the command would debit unconditionally, and every
  // assertion in the spend block above would still pass.
  check('the condition is on the command', cmd.input.ConditionExpression, '#bal >= :cost')
  check('and so is the debit', cmd.input.UpdateExpression, 'ADD #bal :neg')
  check('the balance after is asked for', cmd.input.ReturnValues, 'UPDATED_NEW')

  await bridge.settle()
  const res = answer('br:ddb:spendResult')
  check('the buyer is told what it cost', res.extra.spent, 750)
  check('and what is left', res.extra.balance, 250)
}

console.log('\nspend: a refusal is not a failure')
{
  bridge.reset()
  const refused = new Error('The conditional request failed')
  refused.name = 'ConditionalCheckFailedException'
  bridge.reply(refused)
  bridge.reply({ Item: { balance: { N: '700' } } }) // the follow-up read

  bridge.call('br:ddb:spend', 45, LIC, 750)
  await bridge.settle()
  await bridge.settle()

  const res = answer('br:ddb:spendResult')
  check('an overspend is refused, not errored', res.extra.refused, 'not enough currency')
  check('and no error is reported for it', res.extra.error, undefined)
  check('the real balance is read back for the message', res.extra.balance, 700)
}

// ------------------------------------------------- no free variables, ever ---
//
// The block above pins one verb because one verb broke. This one is the ratchet
// for the CLASS: every handler in src/index.js is invoked with a payload that
// gets past its guards, and a name that is not in scope becomes a named failure
// instead of a live incident.
//
// IT IS A SMOKE TEST AND IT IS NOT ASHAMED OF THAT. It does not assert what any
// of these verbs write -- only that their bodies run. That is precisely the
// property the suite was missing, and it is the property an extract-a-function
// refactor breaks.
//
// A VERB WITH NO PAYLOAD HERE IS A FAILURE, not a quiet gap: the check below
// compares this table against what src/index.js actually registered, so adding
// a verb and not driving it goes red naming the verb.

console.log('\nevery verb runs: no free variables anywhere in the bridge')
{
  // A REAL v4, unlike the `ID` the incident cases use: src/artifacts.js pins
  // the version and variant nibbles, so a made-up id turns artifactBegin and
  // artifactPut round at their first guard and this block would be driving two
  // verbs that never leave their preludes.
  const UUID = '11111111-2222-4333-8444-555555555555'
  const MATCH_ROW = {
    license: LIC, sk: 'match#0001700000000#7', matchId: 7,
    endedAt: 1_700_000_000_000, mode: 'solo', placement: 3, total: 48,
    kills: 2, downs: 1, revives: 0, damage: 400, survivedMs: 90_000,
    xpEarned: 100, voltsEarned: 200, won: false,
  }

  // artifactPut reads the frame off the spool before uploading it, so put one
  // there -- otherwise the verb turns round at its first `stat` and the S3 half
  // of it goes unexercised.
  const frame = artifactNames(UUID, 1, 'png')
  writeFileSync(join(bridge.spoolDir, frame.file), Buffer.from('not really a png'))

  const PAYLOADS = {
    'br:ddb:banCheck': [1, LIC],
    'br:ddb:grantsFetch': [2, LIC],
    'br:ddb:maintenance': [3],
    'br:ddb:profileFetch': [4, LIC],
    'br:ddb:statsApply': [5, LIC, MATCH_PAYOUT],
    'br:ddb:historyPut': [6, [MATCH_ROW]],
    'br:ddb:inventoryFetch': [7, LIC],
    'br:ddb:purchase': [8, LIC, 'chute_azure', 750],
    'br:ddb:spend': [9, LIC, 750],
    'br:ddb:equip': [10, LIC, 'chute', 'chute_azure', false],
    'br:ddb:putIncident': [11, 'token-1', refusalPayload()],
    'br:ddb:incidentClose': [12, {
      incidentId: UUID,
      matchEndedAt: 1_700_000_500_000,
      matchStartedAt: 1_700_000_000_000,
      verdict: 'upheld',
      byName: 'Admin',
      byLicense: LIC,
    }],
    'br:ddb:incidentVerdict': [13, UUID],
    'br:ddb:artifactBegin': [14, UUID, 1, 'png'],
    'br:ddb:artifactPut': [15, UUID, 1, 'png', 1_700_000_000_000],
    'br:ddb:awardClaim': [16, UUID, LIC],
    'br:ddb:awardQueue': [17],
    'br:ddb:awardPay': [18, LIC, UUID, 500],
    'br:ddb:awardSettle': [19, UUID],
    'br:ddb:selftest': [20],
  }

  check(
    'every verb src/index.js registers is driven here',
    [...bridge.handlers.keys()].filter((n) => !Object.hasOwn(PAYLOADS, n)),
    [],
  )
  check(
    'and nothing here drives a verb that no longer exists',
    Object.keys(PAYLOADS).filter((n) => !bridge.handlers.has(n)),
    [],
  )

  // ONE reset, before the loop. The answers accumulate on purpose -- the last
  // assertion in this block reads all of them at once.
  bridge.reset()

  for (const [verb, args] of Object.entries(PAYLOADS)) {
    const threw = bridge.call(verb, ...args)
    check(verb, why(threw), null)
  }

  await bridge.settle()
  await bridge.settle()

  // ═══ AND THE ASYNCHRONOUS HALF ═══
  //
  // A free variable inside a `.then` does NOT throw where the loop above can
  // see it: every one of these handlers ends in a `.catch` that turns any
  // failure into an answer. So the answers are where a late ReferenceError
  // surfaces, and this is the only place it would ever have been visible.
  check(
    'no verb answered with a ReferenceError',
    bridge.emitted
      .filter((e) => /is not defined/.test(JSON.stringify(e.args)))
      .map((e) => e.name),
    [],
  )
}

bridge.cleanup()

if (failed) {
  console.error(`\nbr_ddb: ${failed} of ${ran} case(s) failed`)
  process.exit(1)
}
console.log(`\nbr_ddb: ${ran} cases pass`)
