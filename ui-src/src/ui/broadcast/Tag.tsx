import type { ReactNode } from 'react'
import { toneColor, vars, type Tone } from './util'

/**
 * TAG (#431): a slanted filled chip. The skew is on ::before only; the Anton
 * word stays upright. Existing words only (DOWN, HS, a level).
 *
 *   variant 'word'    the DOWN tag: white ink on the tone
 *           'chip'    the kill feed's HS: dark ink, tighter tracking
 *           'holder'  carries an icon mark (YubikeyMark, BountyMark) over a
 *                     flash in the tone
 *   enter   'wipe' (word, chip: the tag wipes in, its word stamped 80 ms
 *           later), 'drop' or 'spin' (holder), or 'none'
 *   beat    0: drawn still (it was already there at mount); a new value
 *           plays the entrance again
 */
export function Tag({ children, tone = 'danger', ink = 'light', variant = 'word', enter = 'none', beat = 0, className }: {
  children: ReactNode
  tone?: Tone | (string & {})
  ink?: 'light' | 'dark'
  variant?: 'word' | 'chip' | 'holder'
  enter?: 'wipe' | 'drop' | 'spin' | 'none'
  beat?: number
  className?: string
}) {
  const play = beat > 0 && enter !== 'none'
  const extra = className ? ` ${className}` : ''
  if (variant === 'holder') {
    return (
      <span
        key={beat}
        className={`bc-tag bc-tag--holder${play ? ` is-${enter}` : ''}${extra}`}
        style={vars({ '--bc-tag-c': toneColor(tone) })}
      >
        <i className="bc-tag__flash" />
        <span className="bc-tag__mark">{children}</span>
      </span>
    )
  }
  return (
    <span
      key={beat}
      className={`bc-tag${variant === 'chip' ? ' bc-tag--chip' : ''}${play ? ' is-wipe' : ''}${extra}`}
      style={vars({
        '--bc-tag-c': toneColor(tone),
        '--bc-tag-ink': ink === 'dark' ? 'var(--bc-ink-on-chip)' : undefined,
      })}
    >
      <span className="bc-tag__word">{children}</span>
    </span>
  )
}

/**
 * BADGE (#431): a count mark drawn OUTSIDE a clipped plate (a clip would slice
 * it; put it in the plate's positioned wrapper, not in the plate).
 *
 *   kind  'delta'  +N (or -N) floating up off a counter, 950 ms; keyed by
 *                  beat, nothing at 0 (it ends invisible)
 *         'count'  xN beside a repeated notice, punching on each beat
 *   at    'top-end' | 'top-start' | 'end'  (delta only)
 */
export function Badge({ kind = 'delta', value, tone = 'accent', beat = 0, at = 'top-end' }: {
  kind?: 'delta' | 'count'
  value: number
  tone?: Tone | (string & {})
  beat?: number
  at?: 'top-end' | 'top-start' | 'end'
}) {
  const style = vars({ '--bc-badge-c': toneColor(tone) })
  if (kind === 'delta') {
    if (!beat) return null
    return (
      <span key={beat} className={`bc-badge bc-badge--delta bc-badge--${at}`} style={style}>
        {value > 0 ? `+${value}` : String(value)}
      </span>
    )
  }
  return (
    <span key={beat} className={`bc-badge bc-badge--count${beat > 0 ? ' is-beat' : ''}`} style={style}>
      &times;{value}
    </span>
  )
}
