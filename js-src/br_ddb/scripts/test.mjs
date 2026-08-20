import { artifactNames, ARTIFACT_PREFIX, isSpoolFile } from '../src/artifacts.js'
import { isActive } from '../src/ban.js'
import { buildIncidentClose, CLOSE_LIMITS } from '../src/close.js'
import { buildIncidentItem, LIMITS } from '../src/incident.js'
import { projectVerdict, verdictWord } from '../src/verdict.js'

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
  // Dropping 141 rows and still claiming completeness is the exact failure the
  // flag exists to prevent.
  check(
    'a bounded close does not claim to be complete',
    p.ExpressionAttributeValues[':complete'],
    false,
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
  check('and an empty timeline', item.matchTimeline, [])
  check('and does not claim completeness it cannot have', item.matchTimelineComplete, false)
}

if (failed) {
  console.error(`\nbr_ddb: ${failed} of ${ran} case(s) failed`)
  process.exit(1)
}
console.log(`\nbr_ddb: ${ran} cases pass`)
