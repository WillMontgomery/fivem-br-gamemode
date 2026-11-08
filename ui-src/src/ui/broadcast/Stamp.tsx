import { toneColor, vars, type Tone } from './util'

/**
 * STAMP (#431): a word that lands once per beat and holds its last frame
 * solid. Its word comes from data or an existing string (DOWN, OUT, the
 * verdict and death words): the kit adds no words.
 *
 *   size   'tag' (.6, in a Tag), 'band' (OUT: 1.05 at .32em), 'screen' (2.2)
 *   kind   'stamp' (2x to .92 to 1, 320 ms), 'drop' (OUT's fall, 420 ms),
 *          'slam' (the verdict's endSlam, 1.2 s)
 *   beat   0 draws it still (a word that was already there at mount); a new
 *          value plays it again
 *   delay  ms (OUT lands after the plate under it: 860)
 */
export function Stamp({ word, tone, size = 'band', kind = 'stamp', beat = 0, delay = 0, className }: {
  word: string
  tone?: Tone | (string & {})
  size?: 'tag' | 'band' | 'screen'
  kind?: 'stamp' | 'drop' | 'slam'
  beat?: number
  delay?: number
  className?: string
}) {
  const play = beat > 0
  return (
    <span
      key={beat}
      className={`bc-stamp bc-stamp--${size}${play ? ` is-${kind}` : ''}${className ? ` ${className}` : ''}`}
      style={vars({
        '--bc-stamp-c': tone ? toneColor(tone) : undefined,
        '--bc-stamp-delay': play && delay ? `${delay}ms` : undefined,
      })}
    >
      {word}
    </span>
  )
}
