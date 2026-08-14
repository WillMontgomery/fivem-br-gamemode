import { isActive } from '../src/ban.js'
import { buildIncidentItem, LIMITS } from '../src/incident.js'

/**
 * Tests for the two decisions in br_ddb that are pure arithmetic on data, and
 * therefore the two that can be wrong for weeks without anybody noticing.
 *
 *   the ban rule       decides whether a player gets into the server
 *   the incident item  decides what a moderation record says about a person
 *
 * Neither needs a network, and neither should ever be changed without a case
 * here changing with it.
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

if (failed) {
  console.error(`\nbr_ddb: ${failed} of ${ran} case(s) failed`)
  process.exit(1)
}
console.log(`\nbr_ddb: ${ran} cases pass`)
