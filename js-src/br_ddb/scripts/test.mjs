import { artifactNames, ARTIFACT_PREFIX, isSpoolFile } from '../src/artifacts.js'
import { isActive } from '../src/ban.js'
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
check('captureKeys is an array, not an empty object', it.captureKeys, [])

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

if (failed) {
  console.error(`\nbr_ddb: ${failed} of ${ran} case(s) failed`)
  process.exit(1)
}
console.log(`\nbr_ddb: ${ran} cases pass`)
