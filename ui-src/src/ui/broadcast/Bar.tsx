import { useState, type CSSProperties, type Ref } from 'react'
import { Fit } from './deps'
import { LightSweep } from './LightSweep'
import { Numeral } from './Numeral'
import { clamp, toneColor, vars, type Tone } from './util'

/**
 * BAR (#431): a fill moved by scaleX only (never width) over a black track.
 * Real denominators only: `value` is a percentage the caller worked out from
 * a real maximum.
 *
 *   shape  'slant'  the Broadcast track: skewed, with a white ghost under the
 *                   fill (the squad's health and shield)
 *          'pill'   today's vitals pill: rounded, a dark overlay on the fill,
 *                   notches, a caption inside and a numeral on the right
 *   feed   'ramp'   .bar-fill's 300 ms linear, for a 4-10 Hz feed that moves
 *                   in 250 ms server steps (the owner: "not a linear, smooth
 *                   animation" is what an ease-out did there)
 *          'step'   a fall drops at once and its ghost lags; a rise fills on
 *                   an ease-out (the 1 Hz squad push). Never on the vitals.
 *   drive  'value'  React draws the fill from `value`
 *          'ref'    a clock writes the fill's transform through `fillRef`
 *                   (bleed, revive, rescue, use-progress, the pickup line)
 *   axis   'y' for a vertical gauge (the jerry can)
 *
 * Effects, each keyed by its counter (0 on mount): gain (a bright fill from
 * the old value to the new), glint (a light along a shield bar), crack (a
 * break: a white flash and shards along what was left), hit (a red wash),
 * drain (a 700 ms ease-in: a death never reads as a big hit).
 *
 * Its track box is the SURFACE channel (it opens with its plate); the fill
 * keeps its own transform. The caption and the numeral sit outside it, so
 * they never scale.
 */

/** Where a broken bar's shards start (% of what was left) and where they fly. */
const SHARDS = [
  { x: 6, dx: -0.42, dy: 0.42, r: -70 },
  { x: 22, dx: -0.12, dy: -0.5, r: 45 },
  { x: 40, dx: 0.08, dy: 0.55, r: 100 },
  { x: 58, dx: 0.26, dy: -0.46, r: -55 },
  { x: 76, dx: 0.4, dy: 0.48, r: 120 },
  { x: 94, dx: 0.62, dy: -0.32, r: -95 },
] as const

export interface BarProps {
  /** 0-100. */
  value: number
  tone?: Tone | (string & {})
  shape?: 'slant' | 'pill'
  /** Notches drawn over the fill (the shield's 4). */
  segments?: number
  /** Default: 'step' for a slant bar, 'ramp' for a pill. */
  feed?: 'ramp' | 'step'
  drive?: 'value' | 'ref'
  fillRef?: Ref<HTMLDivElement>
  axis?: 'x' | 'y'
  /** A caption inside a pill (Fit: one line or not drawn). Existing words only. */
  label?: string
  /** Draw the value as a numeral: inside a pill, after a slant bar. */
  num?: boolean
  /** Draw 0 too (fuel); health and shield draw nothing at 0. */
  zeroNum?: boolean
  numPlaces?: number
  numBeat?: { n: number; kind: 'pop' | 'slam' }
  numTone?: Tone | (string & {})
  /** The numeral's reveal under a presence (Numeral reveal). Default 'tick',
   *  the owner's pick. */
  numReveal?: 'none' | 'tick' | 'count'
  gain?: { n: number; from: number; to: number }
  glint?: { n: number; power: number }
  crack?: { n: number; from: number }
  hit?: number
  drain?: boolean
  /** Take part in the presence's surface channel (default: horizontal bars). */
  channel?: boolean
  className?: string
  style?: CSSProperties
}

export function Bar({
  value, tone = 'hp', shape = 'slant', segments = 0, feed, drive = 'value', fillRef, axis = 'x', label, num = false,
  zeroNum = false, numPlaces = 3, numBeat, numTone, numReveal = 'tick', gain, glint, crack, hit, drain = false, channel,
  className, style,
}: BarProps) {
  const f = feed ?? (shape === 'pill' ? 'ramp' : 'step')
  const v = clamp(value) / 100
  // Which way it last moved: a fall drops fast and leaves its ghost behind.
  const [seen, setSeen] = useState({ v: value, dir: 0 })
  let dir = seen.dir
  if (seen.v !== value) {
    dir = value < seen.v ? -1 : 1
    setSeen({ v: value, dir })
  }
  const scale = axis === 'y' ? `scaleY(${v})` : `scaleX(${v})`
  const fill: CSSProperties | undefined = drive === 'value' ? { transform: scale } : undefined
  const inChannel = channel ?? axis === 'x'
  const showNum = num && (value > 0 || zeroNum)
  const numeral = showNum ? (
    <Numeral
      value={clamp(value)} places={numPlaces} tone={numTone ?? (shape === 'pill' ? 'ink' : tone)}
      size="sm" heavy={shape === 'pill'} beat={numBeat} reveal={numReveal}
    />
  ) : null

  return (
    <div
      className={[
        'bc-barline', `bc-barline--${shape}`, `bc-barline--${f}`, axis === 'y' ? 'bc-barline--y' : '', className ?? '',
      ].filter(Boolean).join(' ')}
      style={{ ...vars({ '--bc-bar-c': toneColor(tone) }), ...style }}
    >
      <div className={`bc-bar${inChannel ? ' bc-ch-surface' : ''}${drain ? ' is-drain' : ''}`} data-dir={dir}>
        <div className="bc-track">
          {f === 'step' && drive === 'value' && <div className="bc-ghost" style={fill} />}
          <div ref={fillRef} className={`bc-fill${f === 'ramp' ? ' bar-fill' : ''}`} style={fill} />
          {segments > 1 && <div className="bc-notches" style={vars({ '--bc-seg': `${100 / segments}%` })} />}
          {gain && gain.n > 0 && gain.to > gain.from && (
            <div key={`g${gain.n}`} className="bc-gain" style={{ left: `${gain.from}%`, width: `${gain.to - gain.from}%` }} />
          )}
          {glint && glint.n > 0 && <LightSweep kind="glint" beat={glint.n} power={glint.power} />}
          {crack && crack.n > 0 && <div key={`c${crack.n}`} className="bc-crack" />}
        </div>
        {crack && crack.n > 0 && (
          <div key={`x${crack.n}`} className="bc-shards">
            {SHARDS.map((s, i) => (
              <i
                key={i}
                style={vars({
                  left: `${(s.x * Math.max(8, crack.from)) / 100}%`,
                  '--dx': `calc(var(--bc-u) * ${s.dx})`,
                  '--dy': `calc(var(--bc-u) * ${s.dy})`,
                  '--r': `${s.r}deg`,
                })}
              />
            ))}
          </div>
        )}
        {hit ? <div key={`h${hit}`} className="bc-bar__hit" /> : null}
      </div>
      {shape === 'pill' && label !== undefined && (
        <Fit className="micro-label ts bc-bar__label" style={vars({ '--fs': 'var(--bc-fs-caption)' })}>{label}</Fit>
      )}
      {numeral && (shape === 'pill' ? <span className="bc-bar__num">{numeral}</span> : numeral)}
    </div>
  )
}
