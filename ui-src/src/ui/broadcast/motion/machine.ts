/**
 * BROADCAST KIT: THE PRESENCE MACHINE (#431). Pure: no DOM, no React, no
 * runtime imports, so node runs it as-is (scripts/test-broadcast.mjs), as it
 * does ui/fade.ts.
 * (Named machine.ts, not presence.ts: on Windows a presence.ts beside
 * Presence.tsx is the same module to the resolver.)
 *
 * A PRESENCE is one anchor of a screen -- the squad panel's row, the counters,
 * a placard -- on its way in and out. It has four phases:
 *
 *   hidden    unmounted, or mounted and held (hidden values, layer-off)
 *   entering  the preset's in-half is running toward the shown values
 *   shown     at rest
 *   leaving   the out-half is running toward the hidden values
 *
 * The motion itself is CSS TRANSITIONS on transform and opacity, so a change of
 * mind mid-way retargets from wherever the element is: a leave mid-enter and an
 * enter mid-leave both end on target, and nothing ever jumps. The machine only
 * decides the phase, the stagger offset and when a phase is over.
 *
 * WHAT EVERY CHANGE OF MOMENT DOES (the README's table):
 *   want false while entering   leave from the current value, at once (an
 *                               anchor caught mid-way never pauses there)
 *   want true while leaving     enter from the current value, at once
 *   want false when shown       leave on its turn: the stagger backwards
 *   want false in a quick hide  straight to hidden, unseen, no offAir
 *   quick hide while entering   the entrance completes underneath (the layer
 *                               root does the hiding; this machine never sees it)
 *   held while entering         hidden at once (under the curtain)
 *   a late joiner               starts at max(0, scopeStart + order x step - now):
 *                               it never waits and never restarts the scope
 *   a leave its scope drove     ends hidden but PARKED (still mounted, still
 *     ends while others in       holding its box) until the scope's last leave
 *     the scope still leave      ends: one unmounting mid-close reflowed the
 *                               page around the rest, still on screen
 */

import type { Channel, PresetSpec, Timings } from './tokens'

export type Phase = 'hidden' | 'entering' | 'shown' | 'leaving'

/** What the machine is told on every render. */
export interface Inputs {
  /** Should be on screen: the scope wants it, it wants itself, nothing holds it. */
  wanted: boolean
  /** Held (the curtain is up): mounted, hidden, layer-off. */
  held: boolean
  /** Inside a quick-hidden layer (GTA's map, the pause menu). */
  quick: boolean
  /** Stays mounted while hidden. */
  keep: boolean
}

export interface PresenceState {
  phase: Phase
  mounted: boolean
  /** Mounted hidden this commit: the hook reads its style once, then begins
   *  the entrance (no @starting-style on Chromium 103). */
  pending: boolean
  /** Transitions off: an instant change, or a stalled entrance landed. */
  land: boolean
  /** Clock time the current phase began. */
  since: number
  /** This anchor's offset in the stagger for the current phase, ms. */
  base: number
  /** Entrances so far (a numeral keys its reveal on it). */
  epoch: number
  /** Hidden after a leave its scope drove, and kept mounted (its box held)
   *  until the scope's last leave ends (release). */
  parked: boolean
  inputs: Inputs
}

/** Where the anchor sits in its screen. */
export interface StaggerCtx {
  now: number
  order: number
  /** The in-stagger step for this anchor (scope, option or preset). */
  step: number
  /** When the scope's current reveal began; NaN outside a scope. */
  scopeStart: number
  /** The highest order in the scope, for a reversed way out. */
  maxOrder: number
  spec: PresetSpec
}

export function sameInputs(a: Inputs, b: Inputs): boolean {
  return a.wanted === b.wanted && a.held === b.held && a.quick === b.quick && a.keep === b.keep
}

/** An anchor's turn on the way in: its slot in the scope's reveal, or now if
 *  that slot has passed (a late joiner never waits and never restarts it). */
export function enterBase(scopeStart: number, order: number, step: number, now: number): number {
  const start = Number.isFinite(scopeStart) ? scopeStart : now
  return Math.max(0, Math.round(start + order * step - now))
}

/** An anchor's turn on the way out: last in, first out when reversed. */
export function leaveBase(order: number, maxOrder: number, leaveStep: number, reverse: boolean): number {
  const k = reverse ? Math.max(0, maxOrder - order) : Math.max(0, order)
  return Math.round(k * leaveStep)
}

/** The first state. A presence that mounts wanted plays its entrance (from a
 *  hidden first frame) unless `appear` is off; one that mounts unwanted is
 *  absent, or present and hidden when held or kept. */
export function initialState(inputs: Inputs, appear: boolean, now: number): PresenceState {
  const base: PresenceState = {
    phase: 'hidden', mounted: false, pending: false, land: true, since: now, base: 0, epoch: 0, parked: false, inputs,
  }
  if (inputs.wanted) {
    return appear
      ? { ...base, mounted: true, pending: true, land: false }
      : { ...base, phase: 'shown', mounted: true, land: false }
  }
  return { ...base, mounted: inputs.held || inputs.keep }
}

function hiddenAtOnce(s: PresenceState, inputs: Inputs, now: number): PresenceState {
  return {
    ...s, inputs, phase: 'hidden', pending: false, land: true, since: now, base: 0,
    mounted: inputs.held || inputs.keep, parked: false,
  }
}

function enterNow(s: PresenceState, inputs: Inputs, c: StaggerCtx, atOnce = false): PresenceState {
  return {
    ...s, inputs, phase: 'entering', mounted: true, pending: false, land: false, since: c.now,
    base: atOnce ? 0 : enterBase(c.scopeStart, c.order, c.step, c.now), epoch: s.epoch + 1, parked: false,
  }
}

/** The inputs changed: the next state. */
export function update(s: PresenceState, inputs: Inputs, c: StaggerCtx): PresenceState {
  const { phase } = s
  const on = phase === 'entering' || phase === 'shown'

  // HELD: hidden at once, whatever it was doing. Nobody sees it (the curtain).
  if (inputs.held) {
    if (phase === 'hidden' && !s.pending && s.mounted) return { ...s, inputs }
    return hiddenAtOnce(s, inputs, c.now)
  }

  if (inputs.wanted) {
    if (on) return { ...s, inputs }
    // A change of mind turns round where it is, now: a transition given a
    // delay would hold the anchor still, half way, for that long.
    if (phase === 'leaving') return enterNow(s, inputs, c, true)
    // hidden: a mounted element already has its hidden values on screen, so it
    // can begin in this commit; a new one renders a hidden frame first.
    if (s.mounted && !s.pending) return enterNow(s, inputs, c)
    return { ...s, inputs, mounted: true, pending: true, land: false, since: c.now }
  }

  // Not wanted.
  if (on) {
    if (inputs.quick) return hiddenAtOnce(s, inputs, c.now)
    return {
      ...s, inputs, phase: 'leaving', pending: false, land: false, since: c.now,
      base: phase === 'entering' ? 0 : leaveBase(c.order, c.maxOrder, c.spec.leaveStep, c.spec.reverse),
    }
  }
  if (phase === 'hidden') {
    return { ...s, inputs, pending: false, mounted: s.mounted && (inputs.keep || inputs.held || s.parked) }
  }
  return { ...s, inputs }
}

/** The pending flip: the hidden frame has been read, the entrance begins. */
export function begin(s: PresenceState, c: StaggerCtx): PresenceState {
  if (!s.pending) return s
  return enterNow(s, s.inputs, c)
}

/** A phase's window is over (its transitions ended, or the clock says so).
 *  `stuck`: an entrance still short of its target -- land it outright.
 *  `park`: a leave its scope drove, with others in the scope still leaving --
 *  hidden, but kept mounted (its box held) until release(). */
export function settle(s: PresenceState, stuck: boolean, park = false): PresenceState {
  if (s.phase === 'entering') return { ...s, phase: 'shown', land: stuck }
  if (s.phase === 'leaving') {
    const kept = s.inputs.keep || s.inputs.held
    return { ...s, phase: 'hidden', land: true, mounted: kept || park, parked: park && !kept }
  }
  return s
}

/** The scope's last leave has ended: a parked presence goes, as its own leave
 *  would have taken it. Anything else is left as it is. */
export function release(s: PresenceState): PresenceState {
  if (s.phase !== 'hidden' || !s.parked) return s
  return { ...s, parked: false, mounted: s.inputs.keep || s.inputs.held }
}

/** A SCOPE'S WAY OUT, AS ONE (settle's `park`): shared by a scope and every
 *  scope inside it (PresenceScope). The presences now leaving, and the parked
 *  ones (a leave the scope drove that has ended: still mounted, holding their
 *  boxes), each with its release; the last leave to end releases them all,
 *  so a page never reflows around what is still on screen. */
export interface Drain {
  leaving: Set<number>
  parked: Map<number, () => void>
}

/** Release every parked presence once nothing in the drain is leaving. */
export function drained(d: Drain): void {
  if (d.leaving.size > 0 || d.parked.size === 0) return
  const all = [...d.parked.values()]
  d.parked.clear()
  for (const go of all) go()
}

/** The timings in force for a phase. */
export function timingsFor(spec: PresetSpec, phase: Phase): Timings {
  return phase === 'leaving' || phase === 'hidden' ? spec.leave : spec.enter
}

/** How long a phase runs, from its start: the latest channel end. */
export function windowOf(t: Timings, base: number): number {
  let end = 0
  for (const ch of Object.keys(t) as Channel[]) {
    const c = t[ch]
    if (c.ms > 0) end = Math.max(end, c.at + c.ms)
  }
  return end > 0 ? base + end : 0
}

/** When the content lands (clock time): where a numeral appears, and where a
 *  reveal or a count-up starts. */
export function landAt(s: PresenceState, spec: PresetSpec): number {
  const c = spec.enter.content
  const r = spec.enter.root
  const end = Math.max(c.ms > 0 ? c.at + c.ms : 0, r.ms > 0 ? r.at + r.ms : 0)
  return s.since + s.base + end
}

/** The presence root's custom properties: per channel its duration, delay and
 *  curve as plain strings (calc() on <time> is unverified on Chromium 103),
 *  and `--bc-tp: none` when landing (a running transition is canceled only by
 *  taking its property out of transition-property). */
export function rootVars(spec: PresetSpec, s: PresenceState): Record<string, string> {
  const t = timingsFor(spec, s.phase)
  const out: Record<string, string> = {}
  for (const ch of Object.keys(t) as Channel[]) {
    const c = t[ch]
    out[`--bc-${ch}-ms`] = `${c.ms}ms`
    out[`--bc-${ch}-delay`] = `${c.at + s.base}ms`
    out[`--bc-${ch}-ease`] = c.ease
  }
  if (s.land) out['--bc-tp'] = 'none'
  return out
}
