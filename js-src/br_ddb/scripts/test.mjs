import { isActive } from '../src/ban.js'

/**
 * Tests for the rule that decides whether a player gets into the server.
 *
 * THE CASE TABLE IS THE CONTRACT. docs/ban-contract.md lists the same cases in
 * prose, and the console's lib/bans.ts implements the same rule in TypeScript.
 * If a case here changes, all three change together — the failure mode of them
 * disagreeing is a player the console shows as banned walking straight past the
 * connect gate, which nobody would notice until it mattered.
 */

const NOW = 1_700_000_000_000
const HOUR = 3_600_000

const cases = [
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

let failed = 0
for (const [label, ban, expected] of cases) {
  const got = isActive(ban, NOW)
  const ok = got === expected
  if (!ok) failed++
  console.log(
    `${ok ? '  ok  ' : '  FAIL'}  ${label} -> ${got} (expected ${expected})`,
  )
}

if (failed) {
  console.error(`\nbr_ddb ban rule: ${failed} case(s) failed`)
  process.exit(1)
}
console.log(`\nbr_ddb ban rule: ${cases.length} cases pass`)
