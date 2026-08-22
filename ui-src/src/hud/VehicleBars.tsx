import { Fill } from './Vitals'
import type { VehiclePayload } from '../bridge/types'

/**
 * One pill in the strip.
 *
 * `value` IS ALLOWED TO BE undefined so that a bar backed by an OPTIONAL field
 * on VehiclePayload can be listed unconditionally and simply not render until
 * the payload carries it. That is the seam #203's boost bar arrives through:
 * one more entry in `bars` below, reading `vehicle.boost`, with no branch
 * anywhere in this file.
 */
type VehicleBar = {
  /** React key, and the tooltip. Distinct from `label`, which is the caption. */
  title: string
  /** The caption drawn inside the pill. */
  label: string
  /** 0..100, or undefined when this vehicle has nothing to report. */
  value: number | undefined
  /** A palette token from index.css. One colour, one meaning, game-wide. */
  colour: string
}

/**
 * The car you are in: condition, fuel, and whatever else is listed below.
 *
 *   "We need to develop some new health bars, using the same graphical style
 *    as the existing ones. They should be for vehicle health and fuel level,
 *    which are shown on all players' screens while in a vehicle, regardless of
 *    which seat they're in."   -- the owner, 2026-08-21
 *
 * ═══ THE SAME BAR, NOT A BAR THAT LOOKS THE SAME ═══
 *
 * `Fill` is imported from Vitals rather than reimplemented, so the pill, the
 * border, the darkening gradient and the scaleX animation are literally the
 * ones health and shield use. Two copies would agree today and drift at the
 * first tweak to either.
 *
 * The proportions are Vitals' too -- the same 1.05rem row height and the same
 * 3px gutter -- so the two strips read as one family even though they sit in
 * different corners.
 *
 * ═══ A CAPTION AND A NUMERAL IN EACH PILL, BECAUSE THE FIRST PLAYTEST ASKED
 *     FOR BOTH ═══
 *
 *   "The vehicle bars have nothing telling us what they actually indicate, and
 *    they should have a number or percentage built in as well."
 *                                                    -- the owner, 2026-08-22
 *
 * The first draft passed neither, on the standing rule that interface text is
 * the owner's wording and none had been given. It has been now, so both go in:
 * this is a request, not an invention.
 *
 * THE WORDS ARE THE ONES THIS FILE WAS ALREADY USING. The two `title`
 * attributes below have said "Vehicle condition" and "Fuel" since the strip was
 * written -- they were just invisible, because nothing hovers a HUD in a game.
 * The captions are those, one word each, so nothing new was named.
 *
 * ═══ THE FUEL NUMBER IS A PERCENTAGE OF A TANK, NOT METRES OF RANGE ═══
 *
 * The ledger is metres and stays metres (br_lib/shared/fuel_solve.lua's header
 * argues that at length, and it is right about the SERVER's unit). What goes on
 * the bar is the fraction, for three reasons and one piece of evidence:
 *
 *   * THE EVIDENCE. Raw metres is what the pump prompt used to show, and the
 *     owner's verdict on it was "not helpful - it just says '6000m'". That was
 *     a different surface, but it is the only reading anybody has of how this
 *     number lands, and it lands badly.
 *   * NOTHING ON SCREEN IS IN METRES. A player has no distance readout to
 *     compare "2,400 m" against -- not the storm, not the map, not the
 *     waypoint. "40" against a bar that is 40% full is self-describing; 2,400
 *     needs you to know the tank is 6,000 before it means anything, and then it
 *     is the percentage anyway with two extra steps.
 *   * THE BAR BESIDE IT IS A PERCENTAGE. Condition is 0..100. Two identical
 *     pills, three millimetres apart, holding two different units is a reading
 *     error waiting to happen -- and it would cost a unit suffix on the fuel
 *     one to prevent, which is glyphs this pill does not have room for.
 *
 * NO `%` SIGN, for the same reason health and shield have none: a bare 0..100
 * over a proportional fill is the numeric treatment this HUD already has, and
 * the caption removes the only ambiguity a bare number could have had.
 *
 * ═══ THE STRIP IS A LIST, NOT TWO HAND-PLACED PILLS ═══
 *
 * A third bar is coming -- vehicle boost, #203 -- and the owner wants it here
 * beside these two. So the layout below is one entry per bar and a map over
 * them, rather than markup that has to be reopened and re-split to add one.
 *
 * EACH BAR IS A FIXED 9rem AND THE ROW IS AS WIDE AS THE BARS IN IT. The first
 * draft was `w-[18rem]` split `basis-[50%]`, which is the shape where adding a
 * third bar silently makes all three a third narrower -- and a third narrower
 * is where "CONDITION" stops fitting beside its numeral. Fixing the BAR and
 * letting the ROW follow means the geometry inside a pill is the same whether
 * there are two of them or four, so the caption treatment can be copied rather
 * than re-measured. Two bars come to 18.05rem, which is where this already was.
 *
 * NO VERTICAL COST. The bars are siblings in one row, so a third widens the
 * strip and does not grow the column at all: the row is 1.05rem tall with two
 * and 1.05rem tall with three. Measured at 1280x720, the three-bar strip is
 * 298px wide under a 357px inventory bar and the column is unchanged.
 *
 * ═══ WHY THE BOTTOM RIGHT ═══
 *
 * Every other edge is spoken for, and the two obvious homes are both worse:
 *
 *   under the vitals strip   there is no room. Vitals sit at
 *                            `--map-bottom - --vitals-drop`, which at 1280x720
 *                            is about 21px off the bottom of the viewport for a
 *                            17px row -- a sliver, not a slot for more bars.
 *   bottom centre            TalkingBar sits ON the bottom safe edge with
 *                            VoiceNotice and SpectateHint stacked above it in a
 *                            column that owns its own clearance. Adding a third
 *                            surface to a stack another change just finished
 *                            de-conflicting is how they end up drawn on top of
 *                            each other.
 *
 * So this goes in the bottom-right column, ABOVE the inventory bar and inside
 * the same flex-col -- not floating over it with a hand-measured offset. That
 * matters because the inventory bar's height is DATA: the ammo panel appears
 * only for a weapon with a clip, so anything anchored above it by arithmetic
 * would jump every time the player selected a bandage. Stacking in the same
 * column means the browser does the measuring.
 *
 * ═══ TEXT SCALE ═══
 *
 * THE CAPTIONS HONOUR IT, THE NUMERALS DO NOT, and that split is the HUD's
 * existing rule rather than a compromise. index.css puts the player's text-size
 * multiplier on prose and captions -- things that can grow without pushing
 * something off screen -- and keeps it off fixed-size plates, where the extra
 * line height simply clips. A caption is the first; a numeral sized to be
 * legible mid-fight is the second, and health and shield have never scaled
 * theirs either. See the `label` note in Vitals.tsx for the `.ts` / `--fs`
 * spelling, which is the only one that survives an element declaring its own
 * size. The bars themselves follow `--ui-scale` like everything else in rem.
 */
export default function VehicleBars({ vehicle }: { vehicle: VehiclePayload | null }) {
  // UNMOUNTED, NOT HIDDEN. Lua sends `show: false` the moment the ped is out of
  // a vehicle -- by any route, including the car exploding under them -- and
  // the column below has to lose the row's height with it, or the inventory bar
  // would sit one row high for the rest of the match.
  if (!vehicle || !vehicle.show) return null

  // THE WHOLE LAYOUT. Adding a bar is adding a row here.
  const bars: VehicleBar[] = [
    {
      // Lua sends the WORST of body, engine and petrol-tank health rather than
      // the body alone, because a pristine shell with a dying engine is a car
      // about to stop -- see healthPct in client/fuel.lua.
      title: 'Vehicle condition',
      label: 'Condition',
      value: vehicle.health,
      colour: 'var(--color-vehicle)',
    },
    {
      // Fills gradually while the driver holds the interact key at a station:
      // the value is the server's ledger, pushed as it climbs, so the bar rises
      // over the refuel rather than snapping to full at the end.
      //
      // NOTHING HERE SMOOTHS OR CACHES THE NUMBER. The numeral is this
      // payload's, rounded and nothing else; the only easing in the strip is
      // `.bar-fill`'s 300ms linear transform, which is a render ramp between two
      // pushes and is indifferent to how fast they arrive. So a drain that
      // suddenly runs 1.5x faster reads as a bar moving 1.5x faster, which is
      // what it is.
      title: 'Fuel',
      label: 'Fuel',
      value: vehicle.fuel,
      colour: 'var(--color-fuel)',
    },
  ]

  return (
    <div className="flex gap-[3px] items-stretch h-[1.05rem]">
      {bars
        .filter((b) => typeof b.value === 'number' && isFinite(b.value))
        .map((b) => (
          <div key={b.title} className="w-[9rem]" title={b.title}>
            <Fill value={b.value as number} colour={b.colour}
                  label={b.label} num />
          </div>
        ))}
    </div>
  )
}
