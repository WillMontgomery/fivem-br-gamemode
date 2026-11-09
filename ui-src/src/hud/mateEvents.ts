/**
 * THE SQUAD PANEL'S MATE EVENTS, PURE (#429): what happened to a mate, read off
 * two readings of the same mate, and the beats UI v2's Broadcast squad panel
 * plays for them.
 *
 * THE PANEL IS NEVER TOLD AN EVENT. It is told a squad, again and again: the
 * game re-sends the whole SquadPayload every second as NEW objects, changed or
 * not (br_core/client/state.lua, pushSquadOrParty on BR.Loop.SLOW). So every
 * motion comes from comparing VALUES with the last reading of the same mate
 * (the same `src`), never from a new object, which would replay the last hit
 * once a second. diffMate() is that comparison, and step() turns it into the
 * beats: one counter per kind of change, which the panel keys an element by
 * (or flips an A/B class on) so its keyframe starts again, carrying what the
 * motion needs: how hard, from where to where, and how long to wait. A reading
 * that mounts is not an event: every counter starts at ZERO's 0, so a row that
 * goes on air downed plays no knock.
 *
 * ONE PUSH, ONE DIFF. Whatever happened inside the second between two pushes
 * is one change (inferred from that cadence): two hits are one bigger hit and
 * can cross the big-hit line, a hit and a heal in the same second net out, and
 * two kills are one stinger.
 *
 * FROM THE BROADCAST SQUAD PREVIEW (#429): phaseOf and diffMate are its
 * shared/mateEvents.ts, the beats are its broadcast/SquadPanel.tsx's, moved
 * here so node can pin them. Our own names are American (armor, color; the
 * wire keeps `armour` and `colour`), and the revive key and its line say when
 * they play (THE OWNER'S ORDER, at step()).
 *
 * NO RUNTIME IMPORTS: node loads this .ts as it is (scripts/test-mate-events.mjs,
 * the shape of test-fade.mjs), so both imports are types, which node erases.
 */
import type { SquadMember } from '../bridge/types'
import type { FlashKind, ShakeKind } from '../ui/broadcast'

export type MatePhase = 'alive' | 'down' | 'dead'

/** Today's SquadPanel rule (hud/SquadPanel.tsx): 'left' draws as dead; every
 *  other state but dbno (the bus, freefall, glide) as alive. */
export function phaseOf(m: SquadMember): MatePhase {
  if (m.state === 'dead' || m.state === 'left') return 'dead'
  if (m.state === 'dbno') return 'down'
  return 'alive'
}

export interface MateDiff {
  from: MatePhase
  to: MatePhase
  /** Signed health change while alive both times (a knock or a revive moves
   *  hp too, and is not a hit or a heal). */
  hp: number
  /** The same as a fraction of the bar, 0..1, for scaling a hit. */
  hpFrac: number
  /** The shield (the wire's `armour`), the same way. */
  armor: number
  armorFrac: number
  /** The shield went from something to 0, alive both times. */
  shieldBroke: boolean
  /** How many kills were added (SquadMember.kills; a reading without it
   *  counts 0). */
  kills: number
  downed: boolean
  revived: boolean
  died: boolean
  /** dead -> alive: back in, with a key spent at an ambulance. */
  backIn: boolean
  /** reviveKey: absent -> false (a key exists, not ours yet). */
  keyDropped: boolean
  /** reviveKey: anything else -> true (the squad holds it). */
  keyHeld: boolean
  /** The pickup window (reviveKeyEndsAt) appeared, or ended. */
  windowOpened: boolean
  windowClosed: boolean
  bountyOn: boolean
  bountyOff: boolean
  yubikeyOn: boolean
  yubikeyOff: boolean
  voiceOffOn: boolean
  voiceOffOff: boolean
  /** The level arrived or changed. */
  level: boolean
  /** The color changed: a mate before this one left, and colors are given
   *  by position. */
  color: boolean
  any: boolean
}

const has = (s: string | undefined) => typeof s === 'string' && s !== ''

export function diffMate(prev: SquadMember, next: SquadMember): MateDiff {
  const from = phaseOf(prev)
  const to = phaseOf(next)
  const alive = from === 'alive' && to === 'alive'
  const hp = alive ? Math.round(next.hp) - Math.round(prev.hp) : 0
  const armor = alive ? Math.round(next.armour ?? 0) - Math.round(prev.armour ?? 0) : 0
  const kills = (next.kills ?? 0) - (prev.kills ?? 0)
  const d: MateDiff = {
    from,
    to,
    hp,
    hpFrac: Math.min(1, Math.abs(hp) / 100),
    armor,
    armorFrac: Math.min(1, Math.abs(armor) / 100),
    shieldBroke: alive && (prev.armour ?? 0) > 0 && (next.armour ?? 0) <= 0,
    kills: kills > 0 ? kills : 0,
    downed: from === 'alive' && to === 'down',
    revived: from === 'down' && to === 'alive',
    died: from !== 'dead' && to === 'dead',
    backIn: from === 'dead' && to === 'alive',
    keyDropped: prev.reviveKey === undefined && next.reviveKey === false,
    keyHeld: prev.reviveKey !== true && next.reviveKey === true,
    windowOpened: !prev.reviveKeyEndsAt && !!next.reviveKeyEndsAt,
    windowClosed: !!prev.reviveKeyEndsAt && !next.reviveKeyEndsAt,
    bountyOn: !has(prev.bounty) && has(next.bounty),
    bountyOff: has(prev.bounty) && !has(next.bounty),
    yubikeyOn: !has(prev.yubikey) && has(next.yubikey),
    yubikeyOff: has(prev.yubikey) && !has(next.yubikey),
    voiceOffOn: prev.voiceOff !== true && next.voiceOff === true,
    voiceOffOff: prev.voiceOff === true && next.voiceOff !== true,
    level: prev.level !== next.level,
    color: prev.colour !== next.colour,
    any: false,
  }
  d.any = from !== to || hp !== 0 || armor !== 0 || d.kills > 0
    || d.keyDropped || d.keyHeld || d.windowOpened || d.windowClosed
    || prev.reviveKey !== next.reviveKey
    || d.bountyOn || d.bountyOff || d.yubikeyOn || d.yubikeyOff
    || d.voiceOffOn || d.voiceOffOff || d.level || d.color
    || prev.bleedEndsAt !== next.bleedEndsAt
    || prev.name !== next.name
  return d
}

// ---------------------------------------------------------------------------
// THE BEATS: what the panel plays for a change.
// ---------------------------------------------------------------------------

/** A row's silence, as VoiceMark draws it: 'chosen' (the viewer's own from
 *  the voice envelope, a mate's from `voiceOff`), 'fault' (the viewer's own
 *  row only), or null while voice carries. */
export type Silence = 'chosen' | 'fault' | null

/** THE DYING SEQUENCE, in ms after the push that brings the death, in the
 *  kit's own numbers: the bars drain for --bc-t-drain, the OUT plate comes in
 *  as they finish, and OUT drops in after it. The panel times its OUT plate
 *  and OUT by these two, not by copies of them (the preview keeps its own). */
export const OUT_PLATE_AT = 700
export const OUT_WORD_AT = 860
/** The OUT plate's own slide in (the kit's --bc-t-plate-in-slow): it has
 *  landed OUT_PLATE_AT + OUT_PLATE_MS after the push, which is when the row
 *  settles and starts to fade. The panel's net for that settle reads it. */
export const OUT_PLATE_MS = 340

/** A big hit, a quarter of the bar or more, also sends a light across the
 *  plate. */
const BIG_HIT = 0.25

export interface Beats {
  /** The row's one shake channel: the strongest shake in the last change. */
  shake: { n: number; kind: ShakeKind; amp: number }
  /** The plate's one flash: the strongest flash in the last change. */
  flash: { n: number; kind: FlashKind; power: number }
  /** A big hit's light sweep. */
  sweep: { n: number; power: number }
  /** A fill sweep, from the old value to the new (heal, revive, back in). */
  hpUp: { n: number; from: number; to: number }
  shUp: { n: number; from: number; to: number }
  /** The numeral's punch. */
  hpPop: number
  shPop: { n: number; kind: 'pop' | 'slam' }
  shHit: { n: number; power: number }
  /** The shield broke from `from` (where the shards spread along). */
  shBreak: { n: number; from: number }
  elim: number
  downed: number
  /** Back up: from down (revive) or from dead (a key spent). */
  rise: { n: number; kind: 'revive' | 'backIn' }
  /** The deaths so far, the phase the last one came from, and when its push
   *  came (`at`, on the panel's clock): OUT drops OUT_WORD_AT after that. */
  death: { n: number; from: MatePhase; at: number }
  /** The key's pickup window opened: the red line slides in, `delay` ms
   *  after its push. */
  lineIn: { n: number; delay: number }
  /** The key mark drops in (a key exists) or slams down (the squad holds
   *  it), `delay` ms after its push. */
  keyAnim: { n: number; kind: 'drop' | 'slam'; delay: number }
  /** The key was retrieved during death number `death`: the line zips. */
  zip: { n: number; death: number }
  bounty: number
  yubikey: number
  voiceCut: number
  color: { n: number; prev: string }
  level: number
}

export const ZERO: Beats = {
  shake: { n: 0, kind: 'jolt', amp: 0 },
  flash: { n: 0, kind: 'hit', power: 0 },
  sweep: { n: 0, power: 0 },
  hpUp: { n: 0, from: 0, to: 0 },
  shUp: { n: 0, from: 0, to: 0 },
  hpPop: 0,
  shPop: { n: 0, kind: 'pop' },
  shHit: { n: 0, power: 0 },
  shBreak: { n: 0, from: 0 },
  elim: 0,
  downed: 0,
  rise: { n: 0, kind: 'revive' },
  death: { n: 0, from: 'alive', at: 0 },
  lineIn: { n: 0, delay: 0 },
  keyAnim: { n: 0, kind: 'drop', delay: 0 },
  zip: { n: 0, death: 0 },
  bounty: 0,
  yubikey: 0,
  voiceCut: 0,
  color: { n: 0, prev: '' },
  level: 0,
}

const clamp = (v: number) => Math.max(0, Math.min(100, Math.round(v)))
const hasLevel = (m: SquadMember) => typeof m.level === 'number' && m.level >= 1

/**
 * The beats after one more reading of the same mate: `b` the beats so far,
 * `prev` and `next` the last reading and this one, `wasSilent` and `silent`
 * the row's silence at each, and `at` when this reading's push came, on the
 * panel's clock (ms). It returns new beats and never writes to `b`.
 *
 * THE OWNER'S ORDER FOR A DEATH (decision 3). The sequence he approved has
 * the key arrive after the death: the bars drain, the OUT plate comes in, OUT
 * drops in, and then the key and its red line (the preview sent the key a
 * second later). The game mints the key on the death's own edge, above the
 * state change (br_core/server/combat.lua), so the key and its line usually
 * arrive in the SAME push as the death; then both wait for OUT's beat. One
 * that arrives a push later waits for what is left of it: the death comes off
 * the roster and the key off the squad beacon (br_core/client/state.lua,
 * pushSquadOrParty), and pushes are not always a second apart, since a kill
 * in the squad pushes at once (#439). One that comes at OUT's beat or after
 * it plays at once.
 *
 * THE PANEL'S HALF of that order: it keys the line and the key mark by their
 * beat's `n` (lineIn is an object here, where the preview's was a number, so
 * `pl${b.lineIn}` still compiles, and keys every line alike), and keeps both
 * hidden for their `delay` before they play. This file's test cannot see the
 * panel do either; the panel's own check must.
 */
export function step(
  b: Beats, prev: SquadMember, next: SquadMember, wasSilent: Silence, silent: Silence, at: number,
): Beats {
  const d = diffMate(prev, next)
  const o: Beats = { ...b }
  const shakes: [ShakeKind, number][] = []
  const flashes: [FlashKind, number][] = []
  const sh0 = clamp(prev.armour ?? 0)
  const hp1 = clamp(next.hp)
  const sh1 = clamp(next.armour ?? 0)

  if (d.hp < 0) {
    flashes.push(['hit', Math.min(1, 0.35 + 1.3 * d.hpFrac)])
    shakes.push(['jolt', 0.06 + 0.5 * d.hpFrac])
    if (d.hpFrac >= BIG_HIT) o.sweep = { n: b.sweep.n + 1, power: Math.min(1, 0.45 + d.hpFrac) }
  } else if (d.hp > 0) {
    o.hpUp = { n: b.hpUp.n + 1, from: clamp(prev.hp), to: hp1 }
    o.hpPop = b.hpPop + 1
  }
  if (d.armor < 0) {
    if (d.shieldBroke) {
      o.shBreak = { n: b.shBreak.n + 1, from: sh0 }
      o.shPop = { n: b.shPop.n + 1, kind: 'slam' }
      flashes.push(['shield', 0.85])
      shakes.push(['jolt', 0.22])
    } else {
      o.shHit = { n: b.shHit.n + 1, power: Math.min(1, 0.45 + 1.4 * d.armorFrac) }
      flashes.push(['shield', Math.min(0.6, 0.2 + d.armorFrac)])
      shakes.push(['jolt', 0.04 + 0.25 * d.armorFrac])
    }
  } else if (d.armor > 0) {
    o.shUp = { n: b.shUp.n + 1, from: sh0, to: sh1 }
    o.shPop = { n: b.shPop.n + 1, kind: 'pop' }
  }
  if (d.kills > 0) {
    o.elim = b.elim + 1
    shakes.push(['punch', 0.16])
  }
  if (d.downed) {
    o.downed = b.downed + 1
    flashes.push(['down', 0.95])
    shakes.push(['knock', 0.18])
  }
  if (d.revived || d.backIn) {
    // The bars were drawn at 0 while covered, so they fill from 0.
    o.rise = { n: b.rise.n + 1, kind: d.revived ? 'revive' : 'backIn' }
    o.hpUp = { n: o.hpUp.n + 1, from: 0, to: hp1 }
    o.hpPop = o.hpPop + 1
    if (sh1 > 0) {
      o.shUp = { n: o.shUp.n + 1, from: 0, to: sh1 }
      o.shPop = { n: o.shPop.n + 1, kind: 'pop' }
    }
    shakes.push(['rise', 0.5])
  }
  if (d.died) {
    o.death = { n: b.death.n + 1, from: d.from, at }
    flashes.push(['die', 1])
    shakes.push(['knock', 0.12])
  }
  // The key and its line wait for OUT's beat when they come before it: all of
  // it in the death's own push, what is left of it in a later one. A row that
  // went on air out saw no death, and nothing drops OUT on it.
  const keyDelay = o.death.n > 0 ? Math.max(0, o.death.at + OUT_WORD_AT - at) : 0
  if (d.windowOpened) o.lineIn = { n: b.lineIn.n + 1, delay: keyDelay }
  if (d.keyDropped) o.keyAnim = { n: b.keyAnim.n + 1, kind: 'drop', delay: keyDelay }
  if (d.keyHeld) {
    o.keyAnim = { n: o.keyAnim.n + 1, kind: 'slam', delay: keyDelay }
    // The line zips away only if there was a line: a key bought after its
    // pickup expired has none.
    if (d.windowClosed) o.zip = { n: b.zip.n + 1, death: o.death.n }
    shakes.push(['thud', 0.1])
  }
  if (d.bountyOn) o.bounty = b.bounty + 1
  if (d.yubikeyOn) o.yubikey = b.yubikey + 1
  // The row's own silence, as VoiceMark draws it: the envelope on the viewer's
  // row, `voiceOff` on a mate's. Going silent is the beat; coming back is not.
  if (silent !== null && silent !== wasSilent) o.voiceCut = b.voiceCut + 1
  if (d.color) o.color = { n: b.color.n + 1, prev: prev.colour }
  if (d.level && hasLevel(next)) o.level = b.level + 1

  const shake = shakes.reduce<[ShakeKind, number] | null>((a, s) => (!a || s[1] > a[1] ? s : a), null)
  if (shake) o.shake = { n: b.shake.n + 1, kind: shake[0], amp: shake[1] }
  const flash = flashes.reduce<[FlashKind, number] | null>((a, f) => (!a || f[1] > a[1] ? f : a), null)
  if (flash) o.flash = { n: b.flash.n + 1, kind: flash[0], power: flash[1] }
  return o
}
