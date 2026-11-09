import type { CSSProperties, ReactNode } from 'react'
import { Fit } from './deps'
import { ScoreCell } from './ScoreCell'
import { ab, rgba, u, vars } from './util'

/**
 * PLATE (#431): the slanted surface with its color edge -- the Broadcast
 * package's one shape, on its one slant (-15deg); a square plate (shape) has
 * none.
 *
 * THREE JOBS, carried over from index.css's three surfaces, so not every
 * readout becomes a deck and something can still be louder than something
 * else:
 *   deck    HARDWARE: the loading screen's plate (squad rows, counters, slots,
 *           cards, the balance)
 *   strap   RECEDES: one flat teal (Volts, ammo, kill-feed rows, notices)
 *   hot     DEMANDS: a cap strap in --hot over a near-black body, its slab
 *           breathing (the warmup, storm, DBNO and rescue placards)
 *
 * GEOMETRY IS ARITHMETIC. A plate is skewed about its foot (or its head), so
 * every upright line steps in by tan(15) at its own height: Plate.Line does
 * it. Heights are kit units (--bc-u: a rem on the HUD, an em in an island).
 * A square plate (shape) sets the slant and its tan to 0 on itself, so the
 * same arithmetic stands it upright and its lines step in by nothing.
 *
 * CHANNELS (motion.css): the slab is the EDGE, the deck and the cover are the
 * SURFACE, the face and the cover face are the CONTENT. Under a presence the
 * plate arrives as the preset says; outside one it is simply shown.
 *
 * BEATS NEVER FIRE ON MOUNT: every keyed effect (flash, shake, burst,
 * recolor, flare) takes a counter that starts at 0 (util useBeat), and nothing
 * fires because a presence entered.
 */

export type PlateVariant = 'deck' | 'strap' | 'hot'
export type PlateState = 'rest' | 'active' | 'alarm' | 'dim' | 'out'
export type FlashKind = 'hit' | 'shield' | 'down' | 'die'
export type ShakeKind = 'jolt' | 'knock' | 'punch' | 'rise' | 'thud'

const DEFAULT_H: Record<PlateVariant, number> = { deck: 3.4, strap: 1.6, hot: 4.8 }

export interface PlateProps {
  variant?: PlateVariant
  /** The kit's slant (the default), or square: the plate stands upright, and
   *  so does everything in it (its lines, chips, sweeps and bars all lean by
   *  --bc-slant and step in by --bc-tan, both 0 on a square plate), a plate
   *  set inside it included: that one is square too, whatever shape it names
   *  (the one value a nested plate takes from its parent, kit.css). The
   *  hotbar's slots (the owner, 2026-11-03: square, "cohesive with the
   *  still-square full page"). */
  shape?: 'slant' | 'square'
  /** The slab's color (a CSS color or token). Default: the mate, the hot
   *  color, else the accent. */
  edge?: string
  /** The slab on the lead (left) or trail (right) side. */
  edgeSide?: 'lead' | 'trail'
  /** Lean about the foot, or about the head (a right-anchored plate whose
   *  outer corner sits on the margin). The edge rises from the pivot. */
  pivot?: 'foot' | 'head'
  /** Kit units. Default 3.4 (deck), 1.6 (strap), 4.8 (hot). */
  height?: number
  /** The name band's height, kit units (deck): a hairline under it, the band
   *  washed in the mate's color, the rest darker. */
  band?: number
  /** A score cell: under the band, or the full height. */
  cell?: 'lower' | 'full'
  cellWidth?: number
  /** Where the cell sits: 'end' or 'start'. Default: opposite the slab (a
   *  squad row); a counter puts it beside its slab. */
  cellSide?: 'start' | 'end'
  /** A squad mate's color (#rrggbb, data from BR.SquadColours): the slab, and
   *  the band's wash at .3. */
  mate?: string
  /** The hot plate's color (--hot). */
  hot?: string
  /** The hot plate's cap: existing words only. */
  cap?: ReactNode
  /** Kit units (default 1.05). */
  capHeight?: number
  state?: PlateState
  /** The opacity a dim or out plate settles at (default --bc-dim, .34). */
  fade?: number
  /** ms before an out plate's slab darkens (hold it through a dying sequence). */
  outDelay?: number
  /** A flash over the plate, keyed by n. */
  flash?: { n: number; kind: FlashKind; power: number }
  /** The plate's one shake channel, keyed by n; amp in kit units. */
  shake?: { n: number; kind: ShakeKind; amp: number }
  /** A burst out of the slab, keyed by its count. */
  burst?: number
  burstColor?: string
  /** The slab was recolored: the old color retracts. */
  recolor?: { n: number; prev: string }
  /** The slab flares across the plate, keyed by its count. */
  flare?: number
  /** The on-air meter under the band (present when defined; runs while true). */
  meter?: boolean
  /** More one-shot accents in the deck, above the base, under the cell
   *  (LightSweep). */
  fx?: ReactNode
  /** The cover's band: Plate.Swap plates that replace everything under the
   *  name band. */
  cover?: ReactNode
  /** Along the cover's foot: Plate.Foot, Plate.Zip. */
  coverFoot?: ReactNode
  /** Upright content over the cover (a clock, OUT, a mark): Plate.Line. */
  coverFace?: ReactNode
  className?: string
  style?: CSSProperties
  /** The walkthrough's anchor (data-tut). */
  tut?: string
  /** The face: Plate.Line rows. */
  children?: ReactNode
}

export function Plate(p: PlateProps) {
  const variant = p.variant ?? 'deck'
  const side = p.edgeSide ?? 'lead'
  const pivot = p.pivot ?? 'foot'
  const H = p.height ?? DEFAULT_H[variant]
  const capH = p.capHeight ?? 1.05
  const band = variant === 'hot' ? capH : p.band
  const state = p.state ?? 'rest'
  const shake = p.shake

  const style = vars({
    '--bc-h': u(H),
    '--bc-band': band !== undefined ? u(band) : undefined,
    '--bc-edge-c': p.edge ?? p.mate,
    '--bc-mate': p.mate,
    '--bc-mate-tint': p.mate ? rgba(p.mate, 0.3) : undefined,
    '--bc-hot': p.hot,
    '--bc-fade': p.fade !== undefined ? String(p.fade) : undefined,
    '--bc-cell-width': p.cellWidth !== undefined ? u(p.cellWidth) : undefined,
    '--bc-slab-out-delay': p.outDelay ? `${p.outDelay}ms` : undefined,
    '--bc-burst-c': p.burstColor,
  })
  const cls = [
    'bc-plate', `bc-plate--${variant}`, `bc-plate--${side}`, `bc-plate--${pivot}`,
    p.shape === 'square' ? 'bc-plate--square' : '',
    band !== undefined && variant === 'deck' ? 'bc-plate--banded' : '',
    state !== 'rest' ? `is-${state}` : '',
    p.className ?? '',
  ].filter(Boolean).join(' ')
  const slabFill = state === 'alarm' ? 'mate-pulse' : variant === 'hot' ? 'bc-hot-pulse' : undefined

  return (
    <div className={cls} style={{ ...style, ...p.style }} data-tut={p.tut}>
      <div
        className={`bc-plate__shake${shake ? ab(`is-${shake.kind}`, shake.n) : ''}`}
        style={shake && shake.n > 0 ? vars({ '--amp': u(shake.amp) }) : undefined}
      >
        <div className="bc-plate__deck" aria-hidden>
          <div className="bc-plate__surface bc-ch-surface">
            <div className="bc-plate__base" />
            <div className="bc-plate__redden" />
            {p.flash && p.flash.n > 0 && (
              <div
                key={`f${p.flash.n}`}
                className={`bc-flash bc-flash--${p.flash.kind}`}
                style={{ opacity: p.flash.power }}
              >
                <i />
                {p.flash.kind === 'die' && <b />}
              </div>
            )}
            {p.fx}
            {p.burst ? <div key={`b${p.burst}`} className="bc-burst" /> : null}
            {p.cell && <ScoreCell span={p.cell} side={p.cellSide ?? (side === 'lead' ? 'end' : 'start')} />}
            {p.meter !== undefined && <div className={`bc-meter${p.meter ? ' is-on' : ''}`}><i /></div>}
          </div>
          <div className="bc-plate__slab bc-ch-edge"><i className={slabFill} /><b /></div>
          {p.recolor && p.recolor.n > 0 && (
            <div key={`c${p.recolor.n}`} className="bc-plate__retract" style={{ background: p.recolor.prev }} />
          )}
          {p.flare ? <div key={`e${p.flare}`} className="bc-plate__flare" /> : null}
        </div>

        <div className="bc-plate__face bc-ch-content">
          {variant === 'hot' && p.cap !== undefined && (
            <PlateLine cy={capH / 2} ch={0.26} lh={capH} center>
              <Fit center className="bc-cap">{p.cap}</Fit>
            </PlateLine>
          )}
          {p.children}
        </div>

        {(p.cover || p.coverFoot) && (
          <div className="bc-plate__cover" aria-hidden>
            <div className="bc-plate__cover-in bc-ch-surface">
              <div className="bc-plate__band">{p.cover}</div>
              {p.coverFoot}
            </div>
          </div>
        )}
        {p.coverFace && <div className="bc-plate__face bc-ch-content">{p.coverFace}</div>}
      </div>
    </div>
  )
}

/**
 * ONE UPRIGHT LINE OF A PLATE'S FACE, stepped in along the slant at its own
 * height so nothing touches a slanted edge. Kit units, from the plate's top:
 *   cy  the line's center    ch  half its content's height    lh  its box
 * e.g. the squad name line: cy .68, ch .44, lh 1.2; health: cy 1.84, ch .44,
 * lh .9; shield: cy 2.86 (plate 3.4, band 1.32).
 */
export function PlateLine({ cy, ch, lh, between, end, center, className, style, children }: {
  cy: number
  ch: number
  lh: number
  /** Space the children apart (a name left, a tag right). */
  between?: boolean
  end?: boolean
  center?: boolean
  className?: string
  style?: CSSProperties
  children?: ReactNode
}) {
  const cls = [
    'bc-line', between ? 'bc-line--between' : '', end ? 'bc-line--end' : '', center ? 'bc-line--center' : '',
    className ?? '',
  ].filter(Boolean).join(' ')
  return (
    <div className={cls} style={{ ...vars({ '--bc-cy': u(cy), '--bc-ch': u(ch), '--bc-lh': u(lh) }), ...style }}>
      {children}
    </div>
  )
}

/**
 * THE SWAP: a plate that slams in (or out) over the band on the diagonal,
 * a white edge riding it in. Key it by the event that brings it (a new key is
 * a new plate); keep the outgoing one mounted with motion="out" until the
 * next change.
 *   kind    'alarm' (DOWN: dark, a capped red pulse graded along the plate),
 *           'out' (OUT: dark, hatched, still) or 'deck' (a plain plate)
 *   motion  'in', 'out' or 'none' (a plate that is simply there: a mount)
 *   delay   ms (the OUT plate lands after the drain: 700)
 *   still   hold the alarm mid-pulse (the plate being taken away)
 *   drain   the red drains away (bleeding out)
 *   onLanded  its slide in ended (animationend), e.g. to start a fade
 */
export function PlateSwap({ kind = 'alarm', motion = 'in', delay = 0, rider = true, still = false, drain = false, onLanded }: {
  kind?: 'alarm' | 'out' | 'deck'
  motion?: 'in' | 'out' | 'none'
  delay?: number
  rider?: boolean
  still?: boolean
  drain?: boolean
  onLanded?: () => void
}) {
  const cls = [
    'bc-swap', `bc-swap--${kind}`, motion !== 'none' ? `is-${motion}` : '',
    still ? 'is-still' : '', drain ? 'is-drain' : '',
  ].filter(Boolean).join(' ')
  return (
    <div
      className={cls}
      style={delay ? vars({ '--bc-swap-delay': `${delay}ms` }) : undefined}
      onAnimationEnd={onLanded
        ? (e) => { if (e.target === e.currentTarget && e.animationName === 'bcPlateIn') onLanded() }
        : undefined}
    >
      {kind === 'alarm' && (
        <>
          <i className="bc-swap__glow"><i className={!still && !drain ? 'mate-pulse' : undefined} /></i>
          <i className="bc-swap__shade" />
        </>
      )}
      {rider && motion === 'in' && <b className="bc-edge" />}
    </div>
  )
}

/** A line along the plate's foot (the pickup window), slid in when `fresh`.
 *  Put a ref-driven fill in it (Bar drive="ref", or your own clock). */
export function PlateFoot({ fresh = false, children }: { fresh?: boolean; children?: ReactNode }) {
  return <div className={`bc-plate__foot${fresh ? ' is-new' : ''}`}>{children}</div>
}

/** The foot line zips away in accent, from the fraction it was at. Keyed. */
export function PlateZip({ from }: { from: number }) {
  return <div className="bc-zip" style={vars({ '--from': from.toFixed(3) })} />
}

Plate.Line = PlateLine
Plate.Swap = PlateSwap
Plate.Foot = PlateFoot
Plate.Zip = PlateZip
