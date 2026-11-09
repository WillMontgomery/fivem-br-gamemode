#!/usr/bin/env node
/**
 * THE SQUAD PANEL'S MATE EVENTS (#429): what UI v2's Broadcast squad panel
 * plays for each change to a mate, pinned.
 *
 * src/hud/mateEvents.ts reads two readings of the same mate and decides what
 * happened (diffMate) and which beats the panel plays (step): a hit, and the
 * big hit's light at a quarter of the bar; the shield's hit, break and refill;
 * a heal; down, revived, died and back in; a kill's stinger; the revive key's
 * three readings, its red line and the line's zip; the marks, the voice cut,
 * the level and the recolor. These drive it the way the game does: one
 * reading a second, each a new object. So a reading with nothing new in it
 * must play nothing, and each beat must play on the push it belongs to and on
 * no other -- which is why most checks read WHICH beats a push moved, not
 * only their values.
 *
 * THE OWNER'S ORDER (decision 3). The game mints a revive key on the death's
 * own edge, so the key and its line usually come in the same push as the
 * death. They wait for OUT's beat, after the drain and the OUT plate, as in
 * the sequence he approved, where the key came a second later; and a key in
 * a later push that still comes before OUT's beat waits for what is left of
 * it, so each push here has a time on the panel's clock.
 *
 * WHY node RUNS A .ts FILE DIRECTLY: mateEvents.ts imports types alone, which
 * node's type stripping erases (the shape of test-fade.mjs).
 *
 * WHAT THIS CANNOT REACH: what the panel draws from these beats, and what the
 * game puts in a reading. The panel's half of the owner's order (the key mark
 * and the line drawn only once their beat's wait is over) is read in
 * hud/SquadPanelV2.tsx by scripts/test-broadcast.mjs, section 10.
 *
 * Run: npm run test:mateevents   (and as part of npm run build)
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { diffMate, OUT_PLATE_AT, OUT_PLATE_MS, OUT_WORD_AT, phaseOf, step, ZERO } from '../src/hud/mateEvents.ts'

const here = dirname(fileURLToPath(import.meta.url))

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

/** Every number rounded to three places, so 0.35 + 1.3 * 0.1 reads 0.48. */
const r3 = (v) => JSON.parse(JSON.stringify(v), (_, x) => (typeof x === 'number' ? Math.round(x * 1000) / 1000 : x))

/** Frozen all the way down: step builds new beats and never writes to the
 *  ones it was given, or to a reading. A write throws here (a module is
 *  strict), and the suite stops on it. */
function frozen(v) {
  if (v !== null && typeof v === 'object' && !Object.isFrozen(v)) {
    for (const x of Object.values(v)) frozen(x)
    Object.freeze(v)
  }
  return v
}
frozen(ZERO)

const TEAL = '#2DD4BF'
const AMBER = '#FBBF24'
const T0 = 5_000_000 // a pickup's deadline, on the server's clock
const T1 = 5_400_000
const BLEED = 4_900_000

/** One reading of a mate, a new object every time, as the game sends them.
 *  `armour` and `colour` are the wire's names, written through the property
 *  so this file's own words stay American. */
function mate(o = {}) {
  const m = { src: 7, name: o.name ?? 'Rook', state: o.state ?? 'alive', hp: o.hp ?? 100 }
  m.armour = o.armor ?? 0
  m.colour = o.color ?? TEAL
  for (const k of ['kills', 'level', 'bleedEndsAt', 'voiceOff', 'reviveKey', 'reviveKeyEndsAt', 'yubikey', 'bounty']) {
    if (o[k] !== undefined) m[k] = o[k]
  }
  return m
}
const dead = (o = {}) => mate({ ...o, state: 'dead', hp: 0 })

/** Every change this suite plays, kept for the last section's check. */
const seen = []

/** The beats after one change, from a row that has played nothing yet, its
 *  push at 0 on the panel's clock. */
function one(a, z, was = null, now = null) {
  const b = frozen(step(ZERO, frozen(a), frozen(z), was, now, 0))
  seen.push([a, z, ZERO, b])
  return b
}

/** The beats after each reading in turn. The first reading is a mount, so its
 *  beats are ZERO; `silences` is the row's silence at each (null if left out),
 *  and `times` when each push came, in ms on the panel's clock: a second
 *  apart if left out, the SLOW loop's rate. */
function play(readings, silences = [], times = []) {
  const out = [ZERO]
  for (let i = 1; i < readings.length; i++) {
    out.push(frozen(step(out[i - 1], frozen(readings[i - 1]), frozen(readings[i]), silences[i - 1] ?? null,
      silences[i] ?? null, times[i] ?? i * 1000)))
    seen.push([readings[i - 1], readings[i], out[i - 1], out[i]])
  }
  return out
}

/** Which beats a change played: the ones whose value moved, sorted. */
const moved = (a, z) => Object.keys(z).filter((k) => JSON.stringify(a[k]) !== JSON.stringify(z[k])).sort()

// ── a mate's phase ──────────────────────────────────────────────────────────
console.log("a mate's phase, as today's panel draws it")
check('the bus, freefall, glide and every standing state draw as alive',
  ['lobby', 'warmup', 'bus', 'freefall', 'glide', 'alive'].map((s) => phaseOf(mate({ state: s }))),
  ['alive', 'alive', 'alive', 'alive', 'alive', 'alive'])
check('dbno is down; dead and left are dead', ['dbno', 'dead', 'left'].map((s) => phaseOf(mate({ state: s }))), ['down', 'dead', 'dead'])

// ── nothing new ─────────────────────────────────────────────────────────────
console.log('the same values again, a new object, are no change')
{
  const counters = Object.values(ZERO).map((v) => (typeof v === 'number' ? v : v.n))
  check('a row that mounts has played nothing: every counter starts at 0', [counters.length, counters.filter((n) => n !== 0)], [21, []])
  const standing = { hp: 82, armor: 45, kills: 2, level: 42, bounty: '$', yubikey: 'Y' }
  const outWithKey = { kills: 2, level: 42, voiceOff: true, reviveKey: false, reviveKeyEndsAt: T0 }
  for (const [what, a, z] of [
    ['standing', mate(standing), mate(standing)],
    ['down, its clock running', mate({ state: 'dbno', hp: 0, bleedEndsAt: BLEED }), mate({ state: 'dbno', hp: 0, bleedEndsAt: BLEED })],
    ['out with a key on the ground', dead(outWithKey), dead(outWithKey)],
    ['out with the key held', dead({ reviveKey: true }), dead({ reviveKey: true })],
  ]) {
    check(`${what}: diffMate sees no change, and step plays no beat`, [diffMate(a, z).any, moved(ZERO, one(a, z, 'chosen', 'chosen'))], [false, []])
  }
  check('a fraction of a point is no hit (health is read whole)', moved(ZERO, one(mate({ hp: 100 }), mate({ hp: 99.6 }))), [])
  check('...on both readings, and the shield the same: 50 to 49.6, and 50.4 to 49.6, draw 50 both times',
    [moved(ZERO, one(mate({ hp: 50.4 }), mate({ hp: 49.6 }))), moved(ZERO, one(mate({ armor: 50 }), mate({ armor: 49.6 }))),
      moved(ZERO, one(mate({ armor: 50.4 }), mate({ armor: 49.6 })))],
    [[], [], []])
  const fire = [mate({ state: 'dbno', hp: 0, bleedEndsAt: BLEED }), mate({ state: 'dbno', hp: 0, bleedEndsAt: BLEED - 2000 })]
  const kept = [dead({ reviveKey: true }), dead({ reviveKey: false })]
  check('a name, a bleed deadline moved by fire, or a held key read false again is a change with no beat of its own',
    [[diffMate(mate(), mate({ name: 'Rook2' })).any, diffMate(fire[0], fire[1]).any, diffMate(kept[0], kept[1]).any],
      moved(ZERO, one(mate(), mate({ name: 'Rook2' }))), moved(ZERO, one(fire[0], fire[1])), moved(ZERO, one(kept[0], kept[1]))],
    [[true, true, true], [], [], []])
}

// ── a hit ───────────────────────────────────────────────────────────────────
console.log('a hit, and the big-hit line at a quarter of the bar')
{
  const b = one(mate({ hp: 100 }), mate({ hp: 90 }))
  check('a hit flashes the plate and jolts the row, and plays nothing else', moved(ZERO, b), ['flash', 'shake'])
  check('...both scaled to the hit: a tenth of the bar', r3([b.flash, b.shake]),
    [{ n: 1, kind: 'hit', power: 0.48 }, { n: 1, kind: 'jolt', amp: 0.11 }])
  const b24 = one(mate({ hp: 100 }), mate({ hp: 76 }))
  const b25 = one(mate({ hp: 100 }), mate({ hp: 75 }))
  check('24 points is not a big hit: no light crosses the plate', moved(ZERO, b24), ['flash', 'shake'])
  check('25 points is: the light crosses it as well', [moved(ZERO, b25), r3(b25.sweep)], [['flash', 'shake', 'sweep'], { n: 1, power: 0.7 }])
  check('two hits inside one second are one bigger hit, and cross the line together (30 points)',
    r3(one(mate({ hp: 100 }), mate({ hp: 70 })).sweep), { n: 1, power: 0.75 })
  const heavy = one(mate({ hp: 100 }), mate({ hp: 1 }))
  check('most of the bar in one push caps the flash and the light at 1', r3([heavy.flash.power, heavy.sweep.power]), [1, 1])
}

// ── a heal ──────────────────────────────────────────────────────────────────
console.log('a heal')
{
  const b = one(mate({ hp: 40 }), mate({ hp: 70 }))
  check('a heal fills from the old value to the new and punches the numeral: no flash, no shake',
    [moved(ZERO, b), b.hpUp, b.hpPop], [['hpPop', 'hpUp'], { n: 1, from: 40, to: 70 }, 1])
  check('...from and to the whole numbers the bar draws', one(mate({ hp: 40.4 }), mate({ hp: 70.6 })).hpUp, { n: 1, from: 40, to: 71 })
}

// ── the shield ──────────────────────────────────────────────────────────────
console.log('the shield: a hit, a break, a refill')
{
  const hit = one(mate({ armor: 50 }), mate({ armor: 30 }))
  check('a shield hit glints the bar, flashes shield-blue and jolts less than a hit',
    [moved(ZERO, hit), r3(hit.shHit), r3(hit.flash), r3(hit.shake)],
    [['flash', 'shHit', 'shake'], { n: 1, power: 0.73 }, { n: 1, kind: 'shield', power: 0.4 }, { n: 1, kind: 'jolt', amp: 0.09 }])
  const brk = one(mate({ armor: 30 }), mate({ armor: 0 }))
  check('the shield breaks from where it was: shards along 30, the 0 slams in, a harder jolt',
    [moved(ZERO, brk), brk.shBreak, brk.shPop, r3(brk.flash), r3(brk.shake)],
    [['flash', 'shBreak', 'shPop', 'shake'], { n: 1, from: 30 }, { n: 1, kind: 'slam' }, { n: 1, kind: 'shield', power: 0.85 }, { n: 1, kind: 'jolt', amp: 0.22 }])
  const up = one(mate({ armor: 0 }), mate({ armor: 50 }))
  check('a refill fills from the old value to the new and pops the numeral',
    [moved(ZERO, up), up.shUp, up.shPop], [['shPop', 'shUp'], { n: 1, from: 0, to: 50 }, { n: 1, kind: 'pop' }])
  check('...the fill and the shards from the whole numbers the bar draws',
    [one(mate({ armor: 10.4 }), mate({ armor: 50.6 })).shUp, one(mate({ armor: 30.4 }), mate({ armor: 0 })).shBreak],
    [{ n: 1, from: 10, to: 51 }, { n: 1, from: 30 }])
  const heavy = one(mate({ armor: 100 }), mate({ armor: 10 }))
  check('a heavy shield hit: the glint caps at 1 and the flash at 0.6, under the break\'s 0.85',
    [moved(ZERO, heavy), r3(heavy.shHit), r3(heavy.flash), r3(heavy.shake)],
    [['flash', 'shHit', 'shake'], { n: 1, power: 1 }, { n: 1, kind: 'shield', power: 0.6 }, { n: 1, kind: 'jolt', amp: 0.265 }])
  const burst = one(mate({ hp: 100, armor: 30 }), mate({ hp: 80, armor: 0 }))
  check('a burst that breaks the shield and hurts is one push: the strongest flash and shake win, the break\'s',
    [moved(ZERO, burst), r3(burst.flash), r3(burst.shake)],
    [['flash', 'shBreak', 'shPop', 'shake'], { n: 1, kind: 'shield', power: 0.85 }, { n: 1, kind: 'jolt', amp: 0.22 }])
  const both = one(mate({ hp: 100, armor: 60 }), mate({ hp: 40, armor: 20 }))
  check('the strongest, not the last: a big hit outflashes and outshakes the shield hit that comes after it, whose glint still plays, capped at 1',
    [r3(both.flash), r3(both.shake), r3(both.shHit)], [{ n: 1, kind: 'hit', power: 1 }, { n: 1, kind: 'jolt', amp: 0.36 }, { n: 1, power: 1 }])
  check('a shield lost in a knock or a death is no break: diffMate reads the shield only while standing',
    [diffMate(mate({ armor: 50 }), mate({ state: 'dbno', hp: 0 })).shieldBroke, diffMate(mate({ armor: 50 }), dead()).shieldBroke,
      diffMate(mate({ armor: 30 }), mate({ armor: 0 })).shieldBroke],
    [false, false, true])
}

// ── a kill ──────────────────────────────────────────────────────────────────
console.log('a kill')
{
  const b = one(mate({ kills: 0 }), mate({ kills: 1 }))
  check('a kill sends the stinger across the plate and punches the row',
    [moved(ZERO, b), b.elim, r3(b.shake)], [['elim', 'shake'], 1, { n: 1, kind: 'punch', amp: 0.16 }])
  check('the first kill on a reading that carried none is a kill', one(mate(), mate({ kills: 1 })).elim, 1)
  check('two kills in one push are one stinger, though diffMate counts both',
    [one(mate({ kills: 1 }), mate({ kills: 3 })).elim, diffMate(mate({ kills: 1 }), mate({ kills: 3 })).kills], [1, 2])
  check('a reading without kills after one with is no kill', moved(ZERO, one(mate({ kills: 2 }), mate())), [])
  const k = one(mate({ hp: 100, kills: 0 }), mate({ hp: 50, kills: 1 }))
  check("a kill and a big hit in one push: the stinger plays, and the hit's jolt, the stronger, is the shake",
    [k.elim, r3(k.shake)], [1, { n: 1, kind: 'jolt', amp: 0.31 }])
}

// ── down, revived, died, back in ────────────────────────────────────────────
console.log('down, revived, died, back in')
{
  const down = one(mate({ hp: 64, armor: 20 }), mate({ state: 'dbno', hp: 0, bleedEndsAt: BLEED }))
  check('down: the alarm slams in with a red flash and a knock; the health it lost is no hit, the shield no break',
    [moved(ZERO, down), down.downed, r3(down.flash), r3(down.shake)],
    [['downed', 'flash', 'shake'], 1, { n: 1, kind: 'down', power: 0.95 }, { n: 1, kind: 'knock', amp: 0.18 }])
  const rev = one(mate({ state: 'dbno', hp: 0 }), mate({ hp: 30 }))
  check('revived: the alarm wipes off, the health fills from 0 (it was drawn at 0 under the alarm), the row rises',
    [moved(ZERO, rev), rev.rise, rev.hpUp, rev.hpPop, r3(rev.shake)],
    [['hpPop', 'hpUp', 'rise', 'shake'], { n: 1, kind: 'revive' }, { n: 1, from: 0, to: 30 }, 1, { n: 1, kind: 'rise', amp: 0.5 }])
  const revSh = one(mate({ state: 'dbno', hp: 0 }), mate({ hp: 30, armor: 20 }))
  check('...and a shield it comes back with fills from 0 too', [revSh.shUp, revSh.shPop], [{ n: 1, from: 0, to: 20 }, { n: 1, kind: 'pop' }])
  const died = one(mate({ hp: 70, armor: 40 }), dead())
  check('died standing: the die flash and a knock, remembered as from alive; the bars drain, so no hit and no break',
    [moved(ZERO, died), died.death, r3(died.flash), r3(died.shake)],
    [['death', 'flash', 'shake'], { n: 1, from: 'alive', at: 0 }, { n: 1, kind: 'die', power: 1 }, { n: 1, kind: 'knock', amp: 0.12 }])
  check('bled out from down: remembered as from down, so the alarm drains before OUT',
    one(mate({ state: 'dbno', hp: 0 }), dead()).death, { n: 1, from: 'down', at: 0 })
  check('leaving the match draws as a death; dead to left is not a second one',
    [one(mate(), mate({ state: 'left', hp: 0 })).death, moved(ZERO, one(dead(), mate({ state: 'left', hp: 0 })))], [{ n: 1, from: 'alive', at: 0 }, []])
  const back = one(dead({ reviveKey: true }), mate({ state: 'freefall', hp: 100 }))
  check('back in (a key spent, through the sky): the OUT plate wipes off, the bars fill from 0, the row rises; the key goes quietly',
    [moved(ZERO, back), back.rise, back.hpUp, back.hpPop], [['hpPop', 'hpUp', 'rise', 'shake'], { n: 1, kind: 'backIn' }, { n: 1, from: 0, to: 100 }, 1])
  const flags = (a, z) => { const d = diffMate(a, z); return [d.downed, d.revived, d.died, d.backIn, d.any] }
  check('diffMate names each phase change once, and each is a change: down, revived, died standing or from down, back in',
    [flags(mate(), mate({ state: 'dbno', hp: 0 })), flags(mate({ state: 'dbno', hp: 0 }), mate({ hp: 30 })), flags(mate(), dead()),
      flags(mate({ state: 'dbno', hp: 0 }), dead()), flags(dead(), mate({ state: 'freefall' }))],
    [[true, false, false, false, true], [false, true, false, false, true], [false, false, true, false, true],
      [false, false, true, false, true], [false, false, false, true, true]])
}

// ── the dying sequence ──────────────────────────────────────────────────────
console.log('the dying sequence: the drain, the OUT plate, OUT')
{
  const tokens = readFileSync(join(here, '..', 'src', 'ui', 'broadcast', 'tokens.css'), 'utf8')
  const drain = Number(/--bc-t-drain:\s*(\d+)ms/.exec(tokens)?.[1])
  check("the OUT plate comes in as the bars finish draining (the kit's --bc-t-drain, 700 ms)", [OUT_PLATE_AT, drain], [700, 700])
  check('OUT drops in at 860 ms, after its plate comes in', [OUT_WORD_AT, OUT_PLATE_AT < OUT_WORD_AT], [860, true])
  // The panel's net for the death's settle waits for the plate to land: its
  // own slide, after OUT_PLATE_AT. A copy that drifted short of the kit's
  // would settle a healthy row early, and its fade would start under the
  // plate still sliding in.
  const kitCss = readFileSync(join(here, '..', 'src', 'ui', 'broadcast', 'kit.css'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '')
  const plateIn = Number(/--bc-t-plate-in-slow:\s*(\d+)ms/.exec(tokens)?.[1])
  check("the OUT plate slides in on the kit's --bc-t-plate-in-slow (340 ms), and OUT_PLATE_MS is that",
    [OUT_PLATE_MS, plateIn, /\.bc-swap--out\s*\{[^}]*--bc-swap-in:\s*var\(--bc-t-plate-in-slow\)/.test(kitCss)], [340, 340, true])
  // ...and the kit plays the plate on exactly those: .bc-swap.is-in runs
  // bcPlateIn over var(--bc-swap-in), then the ease, after
  // var(--bc-swap-delay), which Plate.Swap's delay sets (the panel passes
  // OUT_PLATE_AT). Timed any other way, the plate could land after the net,
  // and nothing above would fail.
  const plateTsx = readFileSync(join(here, '..', 'src', 'ui', 'broadcast', 'Plate.tsx'), 'utf8')
  check("the kit plays the plate on them: .bc-swap.is-in runs bcPlateIn over var(--bc-swap-in) after var(--bc-swap-delay), which Plate.Swap's delay sets",
    [/\.bc-swap\.is-in\s*\{\s*animation:\s*bcPlateIn\s+var\(--bc-swap-in\)\s+var\(--bc-ease-snap\)\s+var\(--bc-swap-delay\)\s+both;\s*\}/.test(kitCss),
      /\bstyle=\{delay \? vars\(\{ '--bc-swap-delay': `\$\{delay\}ms` \}\) : undefined\}/.test(plateTsx)],
    [true, true])
}

// ── the revive key ──────────────────────────────────────────────────────────
console.log("the revive key's three readings, its line and the zip")
{
  const k = play([
    mate(), //                                                    0 on air
    dead(), //                                                    1 died, no key yet
    dead({ reviveKey: false, reviveKeyEndsAt: T0 }), //           2 the key a push later
    dead({ reviveKey: false, reviveKeyEndsAt: T0 }), //           3 the same again
    dead({ reviveKey: true }), //                                 4 fetched while its line was up
    dead({ reviveKey: true }), //                                 5 the same again
  ])
  check('absent to false, a push after the death: the mark drops in and the red line slides in, at once',
    [moved(k[1], k[2]), k[2].keyAnim, k[2].lineIn], [['keyAnim', 'lineIn'], { n: 1, kind: 'drop', delay: 0 }, { n: 1, delay: 0 }])
  check('false again is no new drop: false is a reading of its own, never a truthiness test', moved(k[2], k[3]), [])
  check('false to true with its line up: the mark slams, the row thuds, and the line zips away, for this death',
    [moved(k[3], k[4]), k[4].keyAnim, r3(k[4].shake), k[4].zip],
    [['keyAnim', 'shake', 'zip'], { n: 2, kind: 'slam', delay: 0 }, { n: 2, kind: 'thud', amp: 0.1 }, { n: 1, death: 1 }])
  check('true again is nothing', moved(k[4], k[5]), [])
  // Not a reading the game sends (a line comes with its death, so a death and
  // a line closing never share a push); the rule holds anyway.
  check('the zip names the death that is current after its push, one that came in it included',
    one(mate({ reviveKey: false, reviveKeyEndsAt: T0 }), dead({ reviveKey: true })).zip, { n: 1, death: 1 })

  const x = play([
    dead({ reviveKey: false, reviveKeyEndsAt: T0 }), //           0 on air out, a key on the ground
    dead({ reviveKey: false }), //                                1 the pickup expires: the key is still for sale at an ambulance
    dead({ reviveKey: true }), //                                 2 bought there
  ])
  check('THE ZIP ONLY WITH A LINE: the pickup expiring plays nothing, and the line just goes', moved(x[0], x[1]), [])
  check('...and a key bought after it slams with its thud, and nothing zips', [moved(x[1], x[2]), x[2].keyAnim, x[2].zip],
    [['keyAnim', 'shake'], { n: 1, kind: 'slam', delay: 0 }, ZERO.zip])
  check('absent to true in one push (fetched within the second it dropped): a slam, no drop, no line, no zip',
    [moved(ZERO, one(dead(), dead({ reviveKey: true }))), one(dead(), dead({ reviveKey: true })).keyAnim],
    [['keyAnim', 'shake'], { n: 1, kind: 'slam', delay: 0 }])
  check('true to false, true to absent (spent) and false to absent play nothing',
    [moved(ZERO, one(dead({ reviveKey: true }), dead({ reviveKey: false }))),
      moved(ZERO, one(dead({ reviveKey: true }), dead())),
      moved(ZERO, one(dead({ reviveKey: false }), dead()))],
    [[], [], []])
  check('diffMate keeps the three apart: absent to false drops, false to true is held, absent to true is held',
    [[diffMate(dead(), dead({ reviveKey: false })).keyDropped, diffMate(dead(), dead({ reviveKey: false })).keyHeld],
      [diffMate(dead({ reviveKey: false }), dead({ reviveKey: true })).keyDropped, diffMate(dead({ reviveKey: false }), dead({ reviveKey: true })).keyHeld],
      [diffMate(dead(), dead({ reviveKey: true })).keyDropped, diffMate(dead(), dead({ reviveKey: true })).keyHeld]],
    [[true, false], [false, true], [false, true]])
}

// ── the owner's order ───────────────────────────────────────────────────────
console.log("THE OWNER'S ORDER: a key that comes before OUT waits for it")
{
  const b = one(mate({ hp: 70 }), dead({ reviveKey: false, reviveKeyEndsAt: T0 }))
  check('the death plays at once; the key drops in and its line slides in at OUT\'s beat',
    [moved(ZERO, b), b.death, b.keyAnim, b.lineIn],
    [['death', 'flash', 'keyAnim', 'lineIn', 'shake'], { n: 1, from: 'alive', at: 0 }, { n: 1, kind: 'drop', delay: OUT_WORD_AT }, { n: 1, delay: OUT_WORD_AT }])
  check('...which is after the drain and the OUT plate, never before either', [b.keyAnim.delay > OUT_PLATE_AT, b.lineIn.delay > OUT_PLATE_AT, b.keyAnim.delay], [true, true, 860])
  const bled = one(mate({ state: 'dbno', hp: 0 }), dead({ reviveKey: false, reviveKeyEndsAt: T0 }))
  check('bleeding out with the key in the same push: the same wait', [bled.death.from, bled.keyAnim.delay, bled.lineIn.delay], ['down', 860, 860])
  const s = one(mate(), dead({ reviveKey: true }))
  check('a key fetched in the very push of the death (no line left): it slams at OUT\'s beat, nothing zips, and the shake is the death\'s knock',
    [s.keyAnim, s.zip, s.lineIn, r3(s.shake)], [{ n: 1, kind: 'slam', delay: 860 }, ZERO.zip, ZERO.lineIn, { n: 1, kind: 'knock', amp: 0.12 }])
  const later = play([mate(), dead({ reviveKey: false, reviveKeyEndsAt: T0 }), dead({ reviveKey: false, reviveKeyEndsAt: T0, voiceOff: true })], [null, null, 'chosen'])
  check('the wait stays with the beat it was given: the next push (the mate spectating, voice off) leaves the key and the line as they were',
    [moved(later[1], later[2]), later[2].keyAnim, later[2].lineIn], [['voiceCut'], later[1].keyAnim, later[1].lineIn])

  // A KEY IN A LATER PUSH THAT STILL COMES BEFORE OUT. The death comes off
  // the roster and the key off the squad beacon (br_core/client/state.lua,
  // pushSquadOrParty), so a key can come a push after its death; and a push
  // can come well inside a second of the last one, since a kill in the squad
  // pushes at once (#439). Played at once, the key mark and the red line
  // came over the draining bars, before the OUT plate and OUT.
  const soon = play([mate(), dead(), dead({ reviveKey: false, reviveKeyEndsAt: T0 })], [], [0, 1000, 1300])
  check("a key and its line in a push 300 ms after the death wait for what is left of OUT's beat",
    [moved(soon[1], soon[2]), soon[2].keyAnim, soon[2].lineIn],
    [['keyAnim', 'lineIn'], { n: 1, kind: 'drop', delay: OUT_WORD_AT - 300 }, { n: 1, delay: OUT_WORD_AT - 300 }])
  const grabbed = play([mate(), dead({ reviveKey: false, reviveKeyEndsAt: T0 }), dead({ reviveKey: true })], [], [0, 1000, 1500])
  check('...as does a key fetched inside it, so its slam and the zip never come before OUT either',
    [grabbed[2].keyAnim, grabbed[2].zip], [{ n: 2, kind: 'slam', delay: OUT_WORD_AT - 500 }, { n: 1, death: 1 }])
  const onBeat = play([mate(), dead(), dead({ reviveKey: false, reviveKeyEndsAt: T0 })], [], [0, 1000, 1000 + OUT_WORD_AT])
  check("...and a key at OUT's beat, or after it, plays at once", [onBeat[2].keyAnim.delay, onBeat[2].lineIn.delay], [0, 0])
  const aired = play([dead(), dead({ reviveKey: false, reviveKeyEndsAt: T0 })], [], [0, 300])
  check('a row that went on air out saw no death, and OUT never dropped on it: its key waits for nothing',
    [aired[1].death.n, aired[1].keyAnim.delay, aired[1].lineIn.delay], [0, 0, 0])
}

// ── the marks, the voice, the level, the color ──────────────────────────────
console.log('the marks, the voice cut, the level and the recolor')
{
  check('a bounty arriving spins its mark in; a Yubikey arriving drops its mark in',
    [moved(ZERO, one(mate(), mate({ bounty: '$' }))), moved(ZERO, one(mate(), mate({ yubikey: 'Y' })))], [['bounty'], ['yubikey']])
  check('either going plays nothing (the mark unmounts), and an empty glyph is no mark',
    [moved(ZERO, one(mate({ bounty: '$' }), mate())), moved(ZERO, one(mate({ yubikey: 'Y' }), mate({ yubikey: '' }))),
      one(mate({ bounty: '' }), mate({ bounty: '$' })).bounty],
    [[], [], 1])
  check('diffMate sees them go', [diffMate(mate({ bounty: '$' }), mate()).bountyOff, diffMate(mate({ yubikey: 'Y' }), mate()).yubikeyOff], [true, true])
  check('a mate going silent cuts the mark in', moved(ZERO, one(mate(), mate({ voiceOff: true }), null, 'chosen')), ['voiceCut'])
  check('coming back is not a beat', moved(ZERO, one(mate({ voiceOff: true }), mate(), 'chosen', null)), [])
  check("the viewer's own row: a silence off the voice envelope, the reading unchanged, still cuts",
    moved(ZERO, one(mate(), mate(), null, 'fault')), ['voiceCut'])
  check('one silence for another is a cut; the same one again is nothing',
    [one(mate(), mate(), 'fault', 'chosen').voiceCut, moved(ZERO, one(mate(), mate(), 'chosen', 'chosen'))], [1, []])
  check('diffMate reads voiceOff as === true', [diffMate(mate(), mate({ voiceOff: true })).voiceOffOn, diffMate(mate({ voiceOff: true }), mate()).voiceOffOff,
    diffMate(mate(), mate({ voiceOff: false })).voiceOffOn], [true, true, false])
  check('a level arriving, or changing, pops in', [moved(ZERO, one(mate(), mate({ level: 42 }))), one(mate({ level: 42 }), mate({ level: 43 })).level],
    [['level'], 1])
  check('level 1, the level of a player with no XP yet, is a level: arriving, it pops in too', moved(ZERO, one(mate(), mate({ level: 1 }))), ['level'])
  check('a level going, or one that is no level (0), plays nothing',
    [moved(ZERO, one(mate({ level: 43 }), mate())), moved(ZERO, one(mate(), mate({ level: 0 })))], [[], []])
  const re = one(mate({ color: TEAL }), mate({ color: AMBER }))
  check('a recolor (a mate above this one left) repaints the edge, retracting the old color', [moved(ZERO, re), re.color], [['color'], { n: 1, prev: TEAL }])
}

// ── a match ─────────────────────────────────────────────────────────────────
console.log('one mate through a match: every beat on its own push, and on no other')
{
  const m = play([
    mate({ hp: 100, armor: 50, level: 12 }), //                                   0 on air
    mate({ hp: 85, armor: 50, level: 12 }), //                                    1 a hit
    mate({ hp: 85, armor: 20, level: 12 }), //                                    2 a shield hit
    mate({ hp: 55, armor: 0, level: 12 }), //                                     3 the shield breaks under a big hit
    mate({ hp: 55, level: 12, kills: 1 }), //                                     4 a kill
    mate({ hp: 90, level: 12, kills: 1 }), //                                     5 a heal
    mate({ hp: 90, armor: 50, level: 12, kills: 1 }), //                          6 a refill
    mate({ state: 'dbno', hp: 0, level: 12, kills: 1, bleedEndsAt: BLEED }), //   7 down
    mate({ hp: 30, level: 12, kills: 1 }), //                                     8 revived
    mate({ state: 'dbno', hp: 0, level: 12, kills: 1, bleedEndsAt: BLEED }), //   9 down again
    dead({ level: 12, kills: 1, reviveKey: false, reviveKeyEndsAt: T0 }), //      10 bled out, the key with it
    dead({ level: 12, kills: 1, reviveKey: true }), //                            11 fetched
    mate({ state: 'freefall', hp: 100, level: 12, kills: 1 }), //                 12 back in
    mate({ hp: 100, level: 13, kills: 1 }), //                                    13 a level up
    dead({ level: 13, kills: 1 }), //                                             14 died standing
    dead({ level: 13, kills: 1, reviveKey: false, reviveKeyEndsAt: T1 }), //      15 the key a push later
    dead({ level: 13, kills: 1, reviveKey: true }), //                            16 fetched
  ])
  check('each push plays its own beats', m.slice(1).map((b, i) => moved(m[i], b)), [
    ['flash', 'shake'],
    ['flash', 'shHit', 'shake'],
    ['flash', 'shBreak', 'shPop', 'shake', 'sweep'],
    ['elim', 'shake'],
    ['hpPop', 'hpUp'],
    ['shPop', 'shUp'],
    ['downed', 'flash', 'shake'],
    ['hpPop', 'hpUp', 'rise', 'shake'],
    ['downed', 'flash', 'shake'],
    ['death', 'flash', 'keyAnim', 'lineIn', 'shake'],
    ['keyAnim', 'shake', 'zip'],
    ['hpPop', 'hpUp', 'rise', 'shake'],
    ['level'],
    ['death', 'flash', 'shake'],
    ['keyAnim', 'lineIn'],
    ['keyAnim', 'shake', 'zip'],
  ])
  const end = m[m.length - 1]
  check('...and each counted once: two deaths, each zip on its own death, four key moves, two lines',
    [end.death, end.zip, end.keyAnim, end.lineIn, end.downed, end.rise, end.elim, end.level, end.shake.n, end.flash.n],
    [{ n: 2, from: 'alive', at: 14000 }, { n: 2, death: 2 }, { n: 4, kind: 'slam', delay: 0 }, { n: 2, delay: 0 }, 2, { n: 2, kind: 'backIn' }, 1, 1, 12, 7])
  check('the first death came from down and held its key for OUT; the second did not need to',
    [m[10].death.from, m[10].keyAnim.delay, m[10].lineIn.delay, m[11].zip, m[15].keyAnim.delay], ['down', 860, 860, { n: 1, death: 1 }, 0])
}

// ── every beat is a change ──────────────────────────────────────────────────
console.log('every beat above comes from a change diffMate sees')
{
  const played = seen.filter(([, , b0, b1]) => moved(b0, b1).some((k) => k !== 'voiceCut'))
  check("each push in this suite that played a beat (the voice cut aside: that is the row's silence, not the reading) is one diffMate calls a change",
    [played.length > 50, played.filter(([a, z]) => !diffMate(a, z).any).map(([, , b0, b1]) => moved(b0, b1))], [true, []])
}

console.log(`\n${ran - failed}/${ran} passed${failed ? `, ${failed} FAILED` : ''}`)
process.exit(failed ? 1 : 0)
