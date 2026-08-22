import { Fill } from './Vitals'
import type { VehiclePayload } from '../bridge/types'

/**
 * The car you are in: condition on the left, fuel on the right.
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
 * ═══ NO NUMBERS, AND NO WORDS AT ALL ═══
 *
 * `num` is deliberately not passed. Health and shield carry numerals because a
 * player checks those two figures mid-fight without looking away from what they
 * are shooting at; neither of these is that. Fuel's honest unit is METRES OF
 * RANGE (the owner chose metres), which cannot go on a bar without a unit
 * beside it, and a unit is copy. The standing rule is that interface text is
 * the owner's wording and none was given here, so this strip says nothing --
 * it is exactly the two bars that were asked for.
 *
 * ═══ WHY THE BOTTOM RIGHT ═══
 *
 * Every other edge is spoken for, and the two obvious homes are both worse:
 *
 *   under the vitals strip   there is no room. Vitals sit at
 *                            `--map-bottom - --vitals-drop`, which at 1280x720
 *                            is about 21px off the bottom of the viewport for a
 *                            17px row -- a sliver, not a slot for two more bars.
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
 * There is none to honour, and that is the same answer Vitals gives. index.css:
 * the player's text-size multiplier rides on `.tscale` and belongs "only on
 * elements that can grow without pushing something else off screen -- never on
 * a fixed-size plate". A bar is a fixed-size plate. It follows `--ui-scale`
 * like everything else in rem, and nothing here scales independently.
 */
export default function VehicleBars({ vehicle }: { vehicle: VehiclePayload | null }) {
  // UNMOUNTED, NOT HIDDEN. Lua sends `show: false` the moment the ped is out of
  // a vehicle -- by any route, including the car exploding under them -- and
  // the column below has to lose the row's height with it, or the inventory bar
  // would sit one row high for the rest of the match.
  if (!vehicle || !vehicle.show) return null

  return (
    <div className="w-[18rem] flex gap-[3px] items-stretch h-[1.05rem]">
      {/* Condition. Lua sends the WORST of body, engine and petrol-tank health
          rather than the body alone, because a pristine shell with a dying
          engine is a car about to stop -- see healthPct in client/fuel.lua. */}
      <div className="basis-[50%]" title="Vehicle condition">
        <Fill value={vehicle.health} colour="var(--color-vehicle)" />
      </div>
      {/* Fuel. Fills gradually while the driver holds the interact key at a
          station: the value is the server's ledger, pushed as it climbs, so the
          bar rises over the refuel rather than snapping to full at the end. */}
      <div className="basis-[50%]" title="Fuel">
        <Fill value={vehicle.fuel} colour="var(--color-fuel)" />
      </div>
    </div>
  )
}
