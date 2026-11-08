import { vars } from './util'

/**
 * LIGHTSWEEP (#431): a one-shot crossing, from one width left of its box to
 * just past its right edge (the bcCross family). Put it in a plate's `fx`
 * (inside the skewed deck, so it leans and is clipped) or in a bar's track.
 *
 *   kind   'sweep'    white light, 520 ms (a big hit)
 *          'stinger'  the theme's two slabs in the edge color, 560 ms on the
 *                     wipe curve (a kill)
 *          'glint'    a narrow light, 380 ms (a shield hit)
 *          'name'     an accent glint along the name band, 600 ms (a Yubikey)
 *   beat   a counter: a new value is a new crossing; 0 draws nothing
 *   power  its opacity (scale it to the event)
 *   color  the stinger's color (default: the plate's edge)
 *
 * It ends invisible and holds no state, and nothing it does is a number.
 */
export function LightSweep({ kind = 'sweep', beat, power = 1, color }: {
  kind?: 'sweep' | 'stinger' | 'glint' | 'name'
  beat: number
  power?: number
  color?: string
}) {
  if (!beat) return null
  return (
    <div
      key={beat}
      className={`bc-sweep${kind !== 'sweep' ? ` bc-sweep--${kind}` : ''}`}
      style={vars({ opacity: power, '--bc-sweep-c': color })}
      aria-hidden
    >
      <i />
      {kind === 'stinger' && <b />}
    </div>
  )
}
