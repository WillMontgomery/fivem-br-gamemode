import { useLayoutEffect, useRef, useState, type ReactNode, type RefObject } from 'react'
import type { InvPayload, InvSlot, InvUsing } from '../../bridge/types'
import { gaugeShare } from '../../hud/gaugeShare'
import ItemIcon from '../../hud/ItemIcon'
import { useUi } from '../../store'
import { Bar, LightSweep, Numeral, Plate, PlateFoot, PlateZip, Tag, u, vars } from '../../ui/broadcast'
import { countOf, edgeOf, useBagFx, type SlotFx } from './fx'
import { InvPresence } from './presence'
import { SlotKey } from './SlotKey'
import './inventory.css'

/** No native drag of the bar's pictures (inventory.css says why). */
const noNativeDrag = (e: { preventDefault(): void }) => e.preventDefault()

/**
 * UI V2'S INVENTORY BAR, IN BROADCAST (#431): src/hud/InventoryBar.tsx rebuilt
 * from the kit (src/ui/broadcast), the owner's pick from his preview
 * (previews/inventory/BroadcastBar.tsx), a drop-in with today's props (`inv`,
 * `volts`, `currency`) and one of its own (`turn`, below). Today's bar stays as
 * it is beside it, as the v2 squad panel sits beside today's: the inventory
 * piece of UI v2 picks which one a HUD draws.
 *
 * WHAT IT IS MADE OF, all the kit's:
 *   a slot       a deck Plate, SQUARE (the owner, 2026-11-03: "possible we
 *                don't need to slant the inventory slots in the corner, which
 *                would be cohesive with the still-square full page"), its slab
 *                (the color edge) the item's rarity, the art in the band, its
 *                label under it, and a foot strip under the band: the slot's key
 *                (SlotKey, the binding's own cap) and the count in a ScoreCell
 *                beside the slab
 *   an empty     the same deck with its key alone and a quiet slab, as
 *                today's empty slot is the same plate with a faint edge
 *   the fists    a deck with the fist art, a quiet slab, no key (as today)
 *   in hand      the deck goes teal (the kit's `active`), the plate lifts, and
 *                the key lights in the accent and pops; an item keeps its
 *                rarity slab, the fists and an empty slot light the accent one
 *   the ammo     a strap with the gun's rarity as its slab: clip / reserve,
 *                Numerals that tick
 *   Volts        a strap in the Volts gold (the owner's pick), the balance a
 *                Numeral in the gold
 *   using        the kit's Bar along the plate's foot, filled by one Web
 *                Animation over the use's time (no frame loop); when the use
 *                ends the line zips away in accent (Plate.Zip)
 *   the can      a slim kit Bar parallel to the slab, filling from the foot: a
 *                pour drops it at once and the ghost follows
 *
 * SQUARE IS THE KIT'S OWN: each slot's Plate is shape="square", which sets the
 * slant and its tan to 0 on the plate, so every line, chip, sweep and bar in
 * it stands upright by the kit's own arithmetic. The straps above the row keep
 * the slant (the vitals' family).
 *
 * EVERY PIECE OF TODAY'S INFORMATION, in today's words: the slot keys 1-5
 * (the default bindings, as today), the fists, an empty slot, the item in hand,
 * the rarity (the slab, and the pips in the colorblind modes), the label, a
 * weapon's magazine and a stack's count, the `ammo` hint, clip / reserve (the
 * sent reserve, the pool as the fallback), the can's fill (never empty while
 * any is left: gaugeShare), the use progress over a slot that keeps what it
 * holds, and Volts with the currency's name.
 *
 * ITS MOTION IS THE KIT'S. Every slot and strap is a presence in the scope the
 * bar is drawn in, at `turn` and a quarter-turn apart from the screen edge
 * inward, so the reveal wipes in from the corner; a late joiner (the column
 * mounts on landing) goes at once. A number that changes while its plate is
 * still entering lands that plate at once (`data-binv-live`), so it is never
 * half shown. One-shot accents are keyed beats (./fx.ts): nothing fires on a
 * mount or because a presence entered.
 *
 * ITS ROOT CARRIES bc-kit, the class the kit's tokens are declared on.
 */

// ---------------------------------------------------------------------------
// GEOMETRY, kit units. One slot is TILE_H tall; the band holds the art and the
// label, the strip under it the key and the count.
// ---------------------------------------------------------------------------

/** The foot strip holds the slot's key: KeyCap is 1.6 of its type tall (line
 *  1.4, padding .1 a side) plus its 1 px border, at --bc-fs-num-sm (.86, the
 *  count's size beside it), so 1.38 units and 2 px; the strip gives it .1 a
 *  side. (It was 1.3, under a 0.86 chip.) */
const STRIP = 1.7
/** The band is as it was: the art and a two-line label. */
const BAND = 4.3
const TILE_H = BAND + STRIP
/** A square slot is as wide as it is tall. */
const TILE_W = TILE_H
const CELL_W = 1.7
const ART_W = 3.9
const ART_H = 2.4
const ART_CY = 1.5
const LABEL_CY = 3.52
const LABEL_CH = 0.7
const STRIP_CY = BAND + STRIP / 2
/** Half the key cap's height (above). */
const KEY_CH = 0.75
/** The cap's type: the count's numeral size, so the strip reads as one line. */
const KEY_FS = 'var(--bc-fs-num-sm)'
/** Half the count's height (a numeral is 1em of --bc-fs-num-sm). Its own line,
 *  so the taller cap beside it does not step it in. */
const COUNT_CH = 0.43
/** One place of the count's numeral: --bc-numcol (.5em) of --bc-fs-num-sm
 *  (.86). The cell is sized for two places and grows by one of these for each
 *  place past two (the Combat MGs' 100, the Minigun's 150), so a count always
 *  sits on its cell. */
const NUM_COL = 0.43
/** The Volts and ammo straps: the kit gallery's Volts strap. */
const STRAP_H = 2.1
const NUM_CH = 0.75
/** How far a swap shoves a plate, kit units. */
const PUNCH = 0.3

/** A quarter turn between the bar's plates, from the screen edge inward. */
const QUARTER = 0.25

/** A pickup's sweep power, and a reload's glint: accents, not news. */
const SWEEP_POWER = 0.55
const GLINT_POWER = 0.8

/** InventoryBar.tsx's KIND_HINT: the one kind that says what it is. */
const KIND_HINT: Record<InvSlot['kind'], string> = { weapon: '', ammo: 'ammo', consumable: '', throwable: '' }

/** The fists have no item; ItemIcon fetches their art by name (items/fists.png),
 *  as FistIcon does, and draws the same `missing` frame if it fails. */
const FISTS: InvSlot = { id: 'fists', label: 'Fists', kind: 'weapon', rarity: 1, count: 1 }

/** The balance as today writes it (toLocaleString: 1,250). Module level, so a
 *  numeral's format is one function. */
const VOLTS = (v: number): string => v.toLocaleString()

// ---------------------------------------------------------------------------
// THE USE PROGRESS: one Web Animation over the use's own time.
// ---------------------------------------------------------------------------

/**
 * THE BAR OVER A SLOT IN USE. `endsAt` is a SERVER time, so how far the use has
 * come is read against the offset-corrected clock once, when it begins, and the
 * fill runs the rest as one linear animation from there: no frame loop (today's
 * fill is written every frame from requestAnimationFrame). The animation is put
 * in `anim`, so the zip that takes the line away starts from what the fill
 * SHOWS (shownFraction), whatever the wall clock says.
 */
function UseFill({ using, offset, anim }: {
  using: InvUsing
  offset: number
  anim: RefObject<Animation | null>
}) {
  const ref = useRef<HTMLDivElement>(null)
  const { endsAt, ms } = using
  useLayoutEffect(() => {
    const el = ref.current
    if (!el) return undefined
    const total = Math.max(1, ms)
    const left = Math.max(0, endsAt - (Date.now() + offset))
    const a = el.animate(
      [{ transform: 'scaleX(0)' }, { transform: 'scaleX(1)' }],
      { duration: total, delay: -Math.min(total, total - left), fill: 'both', easing: 'linear' },
    )
    anim.current = a
    return () => {
      if (anim.current === a) anim.current = null
      a.cancel()
    }
  }, [endsAt, ms, offset, anim])
  return (
    <span className="binv-use">
      {/* OUT OF THE SURFACE CHANNEL: the cover it rides in (Plate.Foot) is the
          surface channel already, and a second one would square its scale. */}
      <Bar value={0} tone="ink" drive="ref" fillRef={ref} feed="ramp" channel={false} />
    </span>
  )
}

/** How far a use's fill has come AS DRAWN (its keyframes are scaleX 0 to 1 on
 *  a linear curve, so its progress is its scale); `fallback` without one. */
function shownFraction(a: Animation | null, fallback: number): number {
  const p = a?.effect?.getComputedTiming().progress
  return typeof p === 'number' ? Math.min(1, Math.max(0, p)) : fallback
}

/** The foot of a plate: the use line while it runs, the zip once it ends. */
function footOf(using: InvUsing | null, fx: SlotFx, offset: number,
  anim: RefObject<Animation | null>, zipFrom: number): ReactNode {
  if (using) {
    return (
      <PlateFoot key={`u${fx.use}`} fresh={fx.use > 0}>
        <UseFill using={using} offset={offset} anim={anim} />
      </PlateFoot>
    )
  }
  return fx.done.n > 0 ? <PlateZip key={`z${fx.done.n}`} from={zipFrom} /> : undefined
}

const pipsOf = (n: number): ReactNode => Array.from({ length: n }, (_, i) => <i key={i} />)

// ---------------------------------------------------------------------------
// A SLOT
// ---------------------------------------------------------------------------

function Tile({ index, slot, held, using, offset, fx, order, last }: {
  index: number
  slot: InvSlot | null
  held: boolean
  using: InvUsing | null
  offset: number
  fx: SlotFx
  order: number
  last: number
}) {
  const fists = index === 0
  const filled = fists || slot !== null
  const edge = edgeOf(index, slot, held)
  // An item in hand keeps its rarity on the slab (the teal deck says held); the
  // fists and an empty slot take the kit's lit slab from `active` itself.
  const slab = slot ? edge : held ? undefined : edge
  const tint = slot ? edge : undefined
  const count = countOf(slot)
  const places = count !== null ? Math.max(2, String(count).length) : 2
  const item = slot ?? FISTS

  // THE ZIP STARTS WHERE THE FILL IS: read once, in the render where the use
  // ends, while the use line (and its animation) is still mounted.
  const fill = useRef<Animation | null>(null)
  const [zip, setZip] = useState({ n: 0, from: 1 })
  let zipFrom = zip.from
  if (fx.done.n !== zip.n) {
    zipFrom = shownFraction(fill.current, fx.done.from)
    setZip({ n: fx.done.n, from: zipFrom })
  }

  return (
    <InvPresence
      id={fists ? 'fists' : `slot-${index}`}
      order={order}
      last={last}
      live={[count ?? '', slot?.fill ?? '']}
      className={`binv-tile${held ? ' is-held' : ''}`}
    >
      <div className="binv-lift">
        <Plate
          variant="deck"
          shape="square"
          edge={slab}
          edgeSide="trail"
          pivot="head"
          height={TILE_H}
          band={BAND}
          cell={count !== null ? 'lower' : undefined}
          cellWidth={CELL_W + (places - 2) * NUM_COL}
          cellSide="end"
          state={held ? 'active' : 'rest'}
          burst={fx.arrive}
          burstColor={edge}
          recolor={fx.recolor}
          shake={fx.punch.n > 0 ? { n: fx.punch.n, kind: 'punch', amp: PUNCH * fx.punch.dir } : undefined}
          fx={<LightSweep kind="sweep" beat={fx.sweep} power={SWEEP_POWER} />}
          coverFoot={footOf(using, fx, offset, fill, zipFrom)}
        >
          {filled && (
            <Plate.Line cy={ART_CY} ch={ART_H / 2} lh={ART_H} center>
              <span className={`binv-art${fists ? ' binv-art--fists' : ''}`} style={tint ? { color: tint } : undefined}>
                <Tag variant="holder" tone={edge} enter="drop" beat={fx.arrive}>
                  <span className="binv-art__box" style={{ width: u(ART_W), height: u(ART_H) }}>
                    <ItemIcon slot={item} size="100%" />
                  </span>
                </Tag>
              </span>
            </Plate.Line>
          )}
          {filled && (
            <Plate.Line cy={LABEL_CY} ch={LABEL_CH} lh={LABEL_CH * 2} center>
              <span className={`binv-label${fists ? ' binv-label--fists' : ''}`} data-wrap="">{item.label}</span>
            </Plate.Line>
          )}
          <Plate.Line cy={STRIP_CY} ch={KEY_CH} lh={STRIP}>
            <span className="binv-strip">
              {!fists && <SlotKey index={index} held={held} fs={KEY_FS} beat={fx.pick} fixed />}
              {slot && <span className="rarity-pips" style={{ color: tint }}>{pipsOf(slot.rarity)}</span>}
              {slot && KIND_HINT[slot.kind] && <span className="micro-label binv-hint">{KIND_HINT[slot.kind]}</span>}
            </span>
          </Plate.Line>
          {count !== null && (
            <Plate.Line cy={STRIP_CY} ch={COUNT_CH} lh={STRIP} end>
              <Numeral value={count} places={places} size="sm" beat={{ n: fx.pop, kind: 'pop' }} />
            </Plate.Line>
          )}
          {slot?.fill != null && (
            <span className="binv-gauge">
              <Bar value={gaugeShare(slot.fill) * 100} tone={edge} axis="y" feed="step" />
            </span>
          )}
        </Plate>
      </div>
    </InvPresence>
  )
}

// ---------------------------------------------------------------------------
// THE BAR
// ---------------------------------------------------------------------------

export default function InventoryBarV2({ inv, volts, currency, turn }: {
  inv: InvPayload
  /** The balance while the shop's plate or the gun-shop menu is up; null
   *  otherwise (Hud.tsx resolves it, as for today's bar). */
  volts?: number | null
  /** BR.Config.Market.currency, by way of the market payload. */
  currency?: string
  /** THE BAR'S TURN in the reveal of the scope it is drawn in: the HUD's
   *  choreography's inventory turn (UI v2's wipe puts it at 8,
   *  hud/v2/choreo.ts). Its plates take the turns after it, a quarter apart,
   *  so its last is turn + slots x QUARTER. Under a scope that never staggers
   *  (the `none` preset: today's HUD pops the column in whole) every turn is
   *  the same instant. */
  turn: number
}) {
  const offset = useUi((s) => s.clockOffset)
  const fx = useBagFx(inv, offset)
  const n = inv.slots.length
  const lastTurn = turn + n * QUARTER

  const held = inv.slots[inv.active - 1] ?? null
  const gun = held && held.kind === 'weapon' && held.clip != null ? held : null
  // THE RESERVE IS SENT, AND THE POOL IS ONLY THE FALLBACK (InventoryBar.tsx):
  // `??`, because 0 is a real reserve.
  const reserve = inv.reserve ?? (held?.pool ? (inv.ammo[held.pool] ?? 0) : 0)

  return (
    <div
      className="bc-kit binv-bar"
      onDragStart={noNativeDrag}
      style={vars({
        '--binv-tile-w': u(TILE_W),
        '--binv-tile-h': u(TILE_H),
        '--binv-strip': u(STRIP),
      })}
    >
      {/* THE VOLTS YOU HAVE, AT THE SHOP: today's readout on a strap, in the
          Volts gold, the currency's own name after it. */}
      <InvPresence
        id="volts"
        tut="hud-volts"
        order={turn + 2 * QUARTER}
        last={lastTurn}
        show={volts != null}
        live={[volts ?? '']}
        className="binv-strap binv-strap--volts"
      >
        <Plate variant="strap" edge="var(--bc-volts)" edgeSide="trail" pivot="head" height={STRAP_H}>
          <Plate.Line cy={STRAP_H / 2} ch={NUM_CH} lh={STRAP_H} end>
            <span className="binv-volts">
              <Numeral value={volts ?? 0} size="md" tone="volts" format={VOLTS} />
              <span className="micro-label">{currency ?? 'Volts'}</span>
            </span>
          </Plate.Line>
        </Plate>
      </InvPresence>

      {/* AMMO FOR THE GUN IN HAND: nothing for an empty hand, a consumable or a
          melee weapon (`clip == null`), as today. */}
      <InvPresence
        id="ammo"
        order={turn + QUARTER}
        last={lastTurn}
        show={gun !== null}
        live={gun ? [gun.clip ?? '', reserve] : ['', '']}
        className="binv-strap binv-strap--ammo"
      >
        <Plate
          variant="strap"
          edge={gun ? `var(--bc-rarity-${gun.rarity})` : undefined}
          edgeSide="trail"
          pivot="head"
          height={STRAP_H}
          recolor={fx.gunRecolor}
          fx={<LightSweep kind="glint" beat={fx.reload} power={GLINT_POWER} />}
        >
          <Plate.Line cy={STRAP_H / 2} ch={NUM_CH} lh={STRAP_H} end>
            <span className="binv-ammo">
              <Numeral value={gun?.clip ?? 0} places={2} size="md" />
              <span className="binv-ammo__of">/</span>
              <Numeral value={reserve} places={2} fs="var(--bc-fs-body)" tone="faint" />
            </span>
          </Plate.Line>
        </Plate>
      </InvPresence>

      {/* SLOT ZERO, THE FISTS, then the five slots, matching slot1..slot5. */}
      <div className="binv-row">
        <Tile
          index={0}
          slot={null}
          held={inv.active === 0}
          using={null}
          offset={offset}
          fx={fx.slots[0]!}
          order={turn + n * QUARTER}
          last={lastTurn}
        />
        {inv.slots.map((slot, i) => (
          <Tile
            key={i}
            index={i + 1}
            slot={slot}
            held={inv.active === i + 1}
            using={inv.using && inv.using.slot === i + 1 ? inv.using : null}
            offset={offset}
            fx={fx.slots[i + 1]!}
            order={turn + (n - 1 - i) * QUARTER}
            last={lastTurn}
          />
        ))}
      </div>
    </div>
  )
}
