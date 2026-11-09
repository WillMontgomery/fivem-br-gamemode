import { useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { PresencePhaseCtx, usePresence } from '../../ui/broadcast'
import { LAST_TURN, TURNS, type AnchorId, type ChannelName, type Resolved } from './choreo'

/**
 * ONE HUD ELEMENT ON ITS WAY IN AND OUT (#431): the kit's presence (usePresence)
 * as the element's own wrapper, with the wipe's choreography on it.
 *
 *   <div class="hud-anchor"                    the presence root: data-bc-phase,
 *        data-hud-id data-hud-anchor           data-bc-preset, the kit's timing
 *        style="--hud-i --hud-j --bc-dir">     vars, layer-off/inert when hidden
 *     <div class="hud-ch bc-ch-content">       one wrapper per channel the wipe
 *       ...the game's element...               names (outermost first), always
 *                                              at least one
 *
 * WHERE IT GOES (the kit's rule): INSIDE the positioned, measured or centered
 * box, never on it. Never .hud-safe (check-ui R12), never a fixed box or a
 * -translate-x-1/2 box, never an element with a transform of its own. A
 * self-positioning element (the chat column, the notice stack and the bleed-out
 * card are `fixed` or `absolute` themselves) gets a FULL-STAGE anchor
 * (`.hud-fill`): a box the size of the screen whose transform, when it has one,
 * keeps the element exactly where it was.
 *
 * THE ELEMENT IS HELD THROUGH ITS WAY OUT. When `show` goes false the caller has
 * usually stopped rendering the element, so the anchor keeps the last children
 * it was given (the storm card with its last storm) until the leave ends.
 *
 * A NUMBER IS NEVER HIDDEN AT THE MOMENT IT CHANGES. `live` lists the numbers an
 * anchor shows; one that changes while the anchor is still entering (before its
 * turn, or mid-way) lands the whole anchor at once, as a kit Numeral does
 * (`data-bc-live`).
 *
 * A KIT PANEL OWNS ITS ROWS. The squad slot is `ownable`: when the panel inside
 * it renders presences of its own (Broadcast on the kit: one per row), the
 * anchor stands down and moves nothing, so the rows' reveal is the squad's.
 * Today's panel has none, and the anchor moves the slot as one piece.
 *
 * A WINDOW, NOT A SCALE, under the wipe's mask (./hud2.css): an edge or surface
 * wrapper opens over one child that holds the element still,
 *
 *     <div class="hud-ch bc-ch-surface hud-mask">   the window
 *       <div class="hud-mask__in">                  the counter-move
 *         ...the game's element...
 *
 * and a full-stage element sits in a frame the size of the screen inside that
 * (`.hud-mask__frame`), measured where it places itself when a phase begins.
 */
export interface AnchorProps {
  id: AnchorId
  /** The element's own gate (the storm exists, the line has names). */
  show?: boolean
  /** Stay mounted while hidden: what the HUD keeps mounted today. */
  keep?: boolean
  /** The numbers it shows: a change mid-entrance lands it at once. */
  live?: readonly unknown[]
  /** May hold a kit panel whose rows are presences of their own. */
  ownable?: boolean
  /** What an ownable panel's rows come and go with (the squad's size). The
   *  anchor looks for them when this changes or a phase begins, never on every
   *  render: in solo the panel draws no rows at all, and the HUD renders at
   *  its push rate for the whole match. */
  ownKey?: unknown
  children?: ReactNode
}

/**
 * THE LAST TURN, REGISTERED IN A SCOPE THAT DRAWS NOTHING FOR IT (#431).
 *
 * A presence's way out runs the turns backwards from the highest order its
 * scope has seen, and each PresenceScope keeps its own list. The HUD has four
 * scopes (the HUD, the squad slot inside it, chat, notices), so without this
 * each would count back from its own highest turn and the squad would leave
 * first instead of last. Every scope gets the choreography's last turn, and
 * they run their way out on one clock.
 */
export function ScopeFloor({ order }: { order: number }) {
  usePresence(true, { order, keepMounted: true, preset: 'none' })
  return null
}

/** A channel that opens as a window: the edge always has an edge to open
 *  from, the surface only on an anchor beside one (not a centered one). */
function windowed(fx: Resolved, ch: ChannelName | null | undefined): boolean {
  return fx.mask && (ch === 'edge' || (ch === 'surface' && fx.wx !== 0))
}

/**
 * A FULL-STAGE WINDOW IS ITS ELEMENT'S OWN SPAN (./hud2.css). The element
 * places itself (`fixed`), so it is read where it sits and the span written
 * straight onto each window above the frame, in px: one layout read when a
 * phase begins, nothing rendered. With nothing in the frame the window is the
 * whole screen again.
 */
function fitWindows(frame: HTMLElement): void {
  const f = frame.getBoundingClientRect()
  let l = Infinity
  let t = Infinity
  let r = -Infinity
  let b = -Infinity
  for (const el of Array.from(frame.children)) {
    const q = el.getBoundingClientRect()
    if (q.width < 0.5 || q.height < 0.5) continue
    l = Math.min(l, q.left)
    t = Math.min(t, q.top)
    r = Math.max(r, q.right)
    b = Math.max(b, q.bottom)
  }
  const found = l < r && t < b
  for (let w = frame.parentElement; w && !w.classList.contains('hud-anchor'); w = w.parentElement) {
    if (!w.classList.contains('hud-mask')) continue
    const span: [string, number][] = w.classList.contains('bc-ch-surface')
      ? [['--hud-mask-l', l - f.left], ['--hud-mask-r', f.right - r]]
      : [['--hud-mask-t', t - f.top], ['--hud-mask-b', f.bottom - b]]
    for (const [name, px] of span) {
      if (found) w.style.setProperty(name, `${px.toFixed(2)}px`)
      else w.style.removeProperty(name)
    }
  }
}

export function Anchor({ id, show = true, keep = false, live, ownable = false, ownKey, children }: AnchorProps) {
  const fx = TURNS[id]
  // AN ELEMENT THAT GOES ON ITS OWN GOES AT ONCE. The kit times every way out
  // by its reversed turn (the last in leaves first), which is right when the
  // whole HUD goes and wrong when only this element does: the storm card would
  // sit out the stagger of a leave nobody else is taking. While its own gate is
  // shut it takes the last turn, whose reversed turn is now.
  const order = show ? fx.order : LAST_TURN
  const p = usePresence(show, {
    order,
    preset: fx.preset,
    keepMounted: keep || ownable,
    appear: fx.appear,
  })
  const last = useRef<ReactNode>(children)
  if (show) last.current = children

  // A NUMBER THAT CHANGES WHILE ITS ANCHOR IS ENTERING LANDS IT.
  const liveKey = live === undefined ? '' : live.join('|')
  const seen = useRef(liveKey)
  const [liveEpoch, setLiveEpoch] = useState(-1)
  const phase = p.phase
  const epoch = p.info.epoch
  useLayoutEffect(() => {
    if (seen.current === liveKey) return
    seen.current = liveKey
    if (phase === 'entering') setLiveEpoch(epoch)
  }, [liveKey, phase, epoch])
  const landed = liveEpoch === epoch && phase === 'entering'

  // A KIT PANEL'S ROWS: once seen, the anchor stands down for good. Looked for
  // as a phase begins and when the panel's key moves (`ownKey`), which is when
  // rows can come: never on every render.
  const inner = useRef<HTMLDivElement>(null)
  const [own, setOwn] = useState(false)
  useLayoutEffect(() => {
    if (!ownable || own) return
    if (inner.current?.querySelector('[data-bc-phase]')) setOwn(true)
  }, [ownable, own, phase, epoch, ownKey])

  // A FULL-STAGE WINDOW, read where its element sits as each phase begins.
  const frame = useRef<HTMLDivElement>(null)
  useLayoutEffect(() => {
    if (phase !== 'shown' && frame.current) fitWindows(frame.current)
  }, [phase, epoch])

  if (!p.mounted && !own) return null

  const vars = {
    '--hud-i': String(fx.order),
    '--hud-j': String(fx.j),
    '--bc-dir': String(fx.dir),
    '--hud-ox': fx.ox,
    '--hud-oy': fx.oy,
    ...(fx.origin ? { '--hud-origin': fx.origin } : null),
    ...(fx.mask ? { '--hud-wx': String(fx.wx), '--hud-wy': String(fx.wy) } : null),
  } as CSSProperties
  const fill = fx.fill ? ' hud-fill' : ''
  const liveAttr = landed ? '' : undefined

  // The channel wrappers, outermost first; always at least one, and the same
  // number whether or not the anchor has stood down, so the element under them
  // never remounts (a window's own divs included: standing down only takes
  // their classes).
  const chans = fx.channel.length > 0 ? fx.channel : [null]
  let node: ReactNode = show ? children : last.current
  let framed = false
  for (let i = chans.length - 1; i >= 0; i--) {
    const ch = chans[i]
    const win = windowed(fx, ch)
    if (win) {
      if (fx.fill) {
        node = (
          <div ref={framed ? undefined : frame} className={own ? undefined : 'hud-mask__frame'}>
            {node}
          </div>
        )
        framed = true
      }
      node = <div className={own ? undefined : 'hud-mask__in'}>{node}</div>
    }
    node = (
      <div
        ref={i === chans.length - 1 ? inner : undefined}
        className={`hud-ch${fill}${!own && ch ? ` bc-ch-${ch}` : ''}${!own && win ? ' hud-mask' : ''}`}
        data-hud-live={own ? undefined : liveAttr}
      >
        {node}
      </div>
    )
  }

  if (own) {
    return (
      <PresencePhaseCtx.Provider value={p.info}>
        <div
          data-hud-id={id}
          data-hud-anchor={fx.side}
          data-hud-own=""
          className={`hud-anchor${fill}`}
          style={vars}
        >
          {node}
        </div>
      </PresencePhaseCtx.Provider>
    )
  }

  const rp = p.rootProps
  return (
    <PresencePhaseCtx.Provider value={p.info}>
      <div
        ref={rp.ref}
        data-bc-phase={rp['data-bc-phase']}
        data-bc-preset={rp['data-bc-preset']}
        aria-hidden={rp['aria-hidden']}
        inert={rp.inert}
        data-hud-id={id}
        data-hud-anchor={fx.side}
        data-hud-live={liveAttr}
        className={[`hud-anchor${fill}`, rp.className].filter(Boolean).join(' ')}
        style={{ ...vars, ...rp.style }}
      >
        {node}
      </div>
    </PresencePhaseCtx.Provider>
  )
}
