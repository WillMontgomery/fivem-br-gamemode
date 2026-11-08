import { createContext } from 'react'
import { monotonicNow } from '../deps'
import type { Drain, Phase } from './machine'

export type { Drain } from './machine'

/** The clock every presence settles on: the monotonic JS clock (ui/fade.ts),
 *  or a harness's virtual one (<PresenceClock>), so slow motion and seek()
 *  hold the settle as they hold the CSS. */
export type Now = () => number

export const ClockCtx = createContext<Now>(monotonicNow)

/** What a PresenceScope hands its presences. */
export interface ScopeValue {
  /** The scope (and every scope above it) wants its presences shown. */
  want: boolean
  /** Something above holds them hidden (the curtain). */
  hold: boolean
  /** The preset name for every presence that does not name its own. */
  preset: string | undefined
  /** The in-stagger step, if the scope overrides the preset's. */
  step: number | undefined
  /** When the scope's current reveal began (clock ms); NaN outside a scope. */
  start: number
  /** A presence registers its order, for the reversed way out. */
  register: (order: number) => () => void
  maxOrder: () => number
  /** The way out shared with every scope around and inside this one; null
   *  outside any scope (a presence there unmounts as its own leave ends). */
  drain: Drain | null
}

const noop = () => {}

export const ScopeCtx = createContext<ScopeValue>({
  want: true,
  hold: false,
  preset: undefined,
  step: undefined,
  start: Number.NaN,
  register: () => noop,
  maxOrder: () => 0,
  drain: null,
})

/** True inside a quick-hidden layer (QuickHide). */
export const QuickCtx = createContext(false)

/** The nearest presence's phase, for what changes with it: a numeral's reveal,
 *  its count-up, and the rule that a number is never hidden as it changes. */
export interface PhaseInfo {
  phase: Phase
  /** Entrances so far. */
  epoch: number
  /** Clock time the content lands on this entrance. */
  landAt: number
  now: Now
}

export const PresencePhaseCtx = createContext<PhaseInfo>({
  phase: 'shown',
  epoch: 0,
  landAt: 0,
  now: monotonicNow,
})
