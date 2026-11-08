import { useState, type CSSProperties } from 'react'

/** BROADCAST KIT: SMALL HELPERS (#431), graduated from the Broadcast squad panel. */

/** Custom properties in an inline style. */
export const vars = (o: Record<string, string | number | undefined>): CSSProperties => {
  const out: Record<string, string | number> = {}
  for (const [k, v] of Object.entries(o)) if (v !== undefined) out[k] = v
  return out as unknown as CSSProperties
}

/** A length in kit units: `u(3.4)` is 3.4 x --bc-u (a rem on the HUD, an em in
 *  an island). */
export const u = (n: number): string => `calc(var(--bc-u) * ${Number(n.toFixed(4))})`

/** `#rrggbb` (or `#rgb`) at an alpha: no color-mix on Chromium 103. A value
 *  that is not a hex comes back transparent rather than invalid. */
export function rgba(color: string, a: number): string {
  const hex = color.trim().replace(/^#/, '')
  const full = hex.length === 3 ? hex.split('').map((c) => c + c).join('') : hex
  if (!/^[0-9a-fA-F]{6}$/.test(full)) return 'rgba(0, 0, 0, 0)'
  const n = parseInt(full, 16)
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`
}

/** ' fooA' / ' fooB' by a counter's parity: swapping the animation name
 *  restarts a keyframe on an element that stays mounted. Nothing at 0, so a
 *  mount animates nothing. */
export function ab(prefix: string, n: number): string {
  return n > 0 ? ` ${prefix}${n % 2 ? 'A' : 'B'}` : ''
}

/**
 * A change counter: 0 on mount, +1 each time `value` changes after that (the
 * "information from previous renders" pattern; no effect, no extra commit).
 * Use it as a React key or with ab(): a beat never fires on mount, and nothing
 * here fires one because a presence entered.
 */
export function useBeat<T>(value: T, same: (a: T, b: T) => boolean = Object.is): number {
  const [s, setS] = useState({ value, n: 0 })
  if (!same(s.value, value)) {
    const next = { value, n: s.n + 1 }
    setS(next)
    return next.n
  }
  return s.n
}

/**
 * How far an upright line of text must step in from a slanted plate's edges,
 * in kit units. A plate leans 15 degrees, so at a height y from its top its
 * left edge sits tan(15) x (H - y) in from the slot and its right edge tan(15)
 * x y in. A line centered at `cy` whose content is `ch` either side of it is
 * clear of both at its own height; the slab and the insets go on its side.
 *
 * The shape is the same parallelogram for both pivots (the outer corner on the
 * margin), so the pivot does not move the text; it is taken so a caller never
 * has to know that.
 */
export function slantInsets(
  H: number, cy: number, ch: number, _pivot: 'foot' | 'head' = 'foot',
  side: 'lead' | 'trail' = 'lead',
  slab = 0.34, insetLead = 0.2, insetTrail = 0.14,
): { left: number; right: number } {
  const tan = 0.26795
  const left = (H - cy + ch) * tan
  const right = (cy + ch) * tan
  return side === 'lead'
    ? { left: left + slab + insetLead, right: right + insetTrail }
    : { left: left + insetTrail, right: right + slab + insetLead }
}

export const clamp = (v: number, lo = 0, hi = 100): number => Math.max(lo, Math.min(hi, v))

/** The palette by role. A primitive's `tone` is one of these names, or any CSS
 *  color (a mate's color, a rarity token) passed straight through. */
export type Tone =
  | 'ink' | 'body' | 'dim' | 'faint' | 'soft' | 'accent' | 'victory' | 'volts' | 'hp' | 'shield'
  | 'danger' | 'storm' | 'warn' | 'fuel' | 'vehicle' | 'boost'

const TONE: Record<Tone, string> = {
  ink: 'var(--bc-ink)',
  body: 'var(--bc-ink-body)',
  dim: 'var(--bc-ink-dim)',
  faint: 'var(--bc-ink-faint)',
  soft: 'var(--bc-ink-soft)',
  accent: 'var(--bc-accent)',
  victory: 'var(--bc-victory)',
  volts: 'var(--bc-volts)',
  hp: 'var(--bc-hp)',
  shield: 'var(--bc-shield)',
  danger: 'var(--bc-danger)',
  storm: 'var(--bc-storm)',
  warn: 'var(--bc-warn)',
  fuel: 'var(--bc-fuel)',
  vehicle: 'var(--bc-vehicle)',
  boost: 'var(--bc-boost)',
}

/** A tone name to its token, or a CSS color as it is. */
export function toneColor(t: Tone | (string & {})): string {
  return (TONE as Record<string, string>)[t] ?? t
}
