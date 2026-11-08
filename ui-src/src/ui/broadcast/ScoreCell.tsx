import { u, vars } from './util'

/**
 * SCORECELL (#431): the near-black cell in a plate's deck plane, drawn ABOVE
 * the plate's flashes, sweeps and stinger, so a numeral keeps its backing at
 * the moment it changes. Plate draws one for `cell`; place it yourself only
 * inside a deck surface (it is absolute, in the skewed plane).
 *
 *   span   'lower' under the name band (squad vitals), 'full' the whole height
 *   side   'end' (opposite a lead slab) or 'start' (opposite a trail slab)
 *   width  kit units (default --bc-cell-w, 1.85)
 */
export function ScoreCell({ span = 'lower', side = 'end', width }: {
  span?: 'lower' | 'full'
  side?: 'start' | 'end'
  width?: number
}) {
  return (
    <div
      className={`bc-cell${span === 'full' ? ' bc-cell--full' : ''}${side === 'start' ? ' bc-cell--start' : ''}`}
      style={width !== undefined ? vars({ '--bc-cell-width': u(width) }) : undefined}
    />
  )
}
