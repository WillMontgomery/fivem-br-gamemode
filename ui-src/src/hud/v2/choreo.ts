import { EASE, getPreset, registerPreset, type Timing } from '../../ui/broadcast'

/**
 * UI V2'S HUD: THE BROADCAST WIPE (#431, #436), the owner's pick for how the
 * HUD arrives. Which turn each element takes in the reveal, and which of the
 * kit's channels moves it. One table, read by every anchor (./Anchor.tsx).
 *
 * THE MOTION IS THE KIT'S. The `broadcast` preset (onAir in, offAir out) moves
 * every anchor, at the kit's step (80 ms a turn); the way out runs the turns
 * backwards at its 40 ms, the inventory first.
 *
 * EVERY PLATE WIPES IN FROM THE SCREEN EDGE IT HANGS OFF: the right column
 * opens from the right (the surface channel), the notice plates from the left,
 * the top cards unroll down from the top and the bottom lines up from the
 * bottom (the edge channel). Out, each closes back toward the same edge.
 *
 * A WINDOW, NEVER A STRETCH (MASK, ./hud2.css). Each plate keeps its true size
 * and a window travels in over it from that edge, on the channel's own timing
 * and curve, so no digit or word is ever squeezed on the way in or out.
 *
 * THE WIPE IS ITS CHANNEL ALONE, ON PURPOSE. Under onAir the content channel
 * is at opacity 0 until 160 ms into an anchor's turn, by which time the edge is
 * nearly unrolled and the surface well open; under offAir the content is gone
 * by 140 ms, when the edge has hardly begun to close. A wipe channel wrapped
 * round a content channel would never be seen, so each of today's upright
 * elements, which have one face, moves on the one channel that IS its wipe,
 * opaque, and the number it shows is never faded out under the motion.
 *
 * WHAT STAYS ON CONTENT (a slide from its edge and a fade): the kill feed and
 * the car's bars (their Fit labels: Fit judges its label once, and a squeezed
 * box judges it at no width), the squad slot (names), and chat, which is prose
 * over the world rather than a plate.
 *
 * THE KIT'S SLANTED VITALS MOVE THEMSELVES: their plates carry the kit's
 * channels (the slab the edge, the strap and its bar track the surface, the
 * face the content, the numerals .bc-whole), so the preset reaches them with
 * no wrapper, and their anchor takes no channel of its own. A wrapper channel
 * over them would compound with theirs.
 *
 * STAGGERED FROM THE SQUAD PANEL OUTWARD, one turn a ring, ordered by when
 * each element is first SEEN (the edge moves at its turn, the surface 80 ms
 * after it, the content 160 ms after it): a wave from the top-left corner to
 * the bottom-right, landed by about 1.2 s.
 *
 * LATE JOINERS NEED NOTHING: the squad slot and the inventory column mount on
 * landing and the storm card when the match goes live; an anchor whose turn has
 * passed goes at once (the kit's late-joiner rule).
 */

/** Every HUD element the v2 HUD wraps, by the corner it lives in. */
export type AnchorId =
  | 'squad'      // top-left: the squad slot (#br-squad-slot); a kit panel's rows are presences of their own
  | 'counters'   // top-right: Elims and Alive
  | 'feed'       // top-right: the kill feed, under the counters
  | 'placard'    // top: the warmup timer
  | 'storm'      // top: the storm card
  | 'vitals'     // bottom-left: health and shield, under the radar or above it
  | 'chat'       // bottom-left: the chat column, above the radar (App level, fixed)
  | 'notices'    // bottom-left: the notice stack, right of the radar (App level, fixed)
  | 'yubikey'    // bottom-right: the Yubikey icon
  | 'vehicle'    // bottom-right: the vehicle bars
  | 'inventory'  // bottom-right: Volts, ammo and the slots
  | 'talking'    // bottom: "Currently Talking"
  | 'voice'      // bottom: the voice notice
  | 'spectate'   // bottom: "SPECTATING NAME" and its keys
  | 'dbno'       // bottom: the bleed-out card (its own hotDrop is its entrance)

export type Side =
  | 'top-left' | 'top' | 'top-right'
  | 'bottom-left' | 'bottom' | 'bottom-right'

/** The kit's channels (ui/broadcast/motion.css). `root` is the anchor's own
 *  wrapper (the preset's --bc-pre-root-* values); the other three are wrapper
 *  divs around the element, outermost first, carrying .bc-ch-<name>:
 *    edge     scaleY about the anchor's origin, and opacity
 *    surface  scaleX about the anchor's origin, and opacity
 *    content  translateX by --bc-dir x the preset's slide, and opacity
 *  Under the mask the edge and the surface open as a window from that same
 *  edge instead (translate, never scale: ./hud2.css). */
export type ChannelName = 'edge' | 'surface' | 'content'

/** One anchor's part in the wipe. What is left out takes the defaults below. */
export interface AnchorFx {
  /** Its turn in the reveal: it starts order x step ms after the reveal does.
   *  The way out runs the turns backwards at the preset's leaveStep. */
  order?: number
  /** Which channel wrappers move it, outermost first. [] moves only the root
   *  (a preset whose root channel moves: `fade`). Default: content. */
  channel?: ChannelName[]
  /** The content slide's direction: 1 in from the left, -1 from the right,
   *  0 none. Default: by side (left 1, right -1, center 0). */
  dir?: 1 | 0 | -1
  /** A preset for this anchor alone. Default: the scope's (PRESET). */
  preset?: string
  /** Play the entrance when it mounts wanted. Default true. The bleed-out card
   *  is false: its hotDrop is its entrance, and the anchor only takes it away. */
  appear?: boolean
  /** The transform-origin of its scales, as CSS (`0% 100%`). Default: by side,
   *  or the element's own corner for the full-stage anchors (chat, notices,
   *  the bleed-out card). */
  origin?: string
}

/** Where each anchor lives. The HUD's layout, not the wipe's to change. */
export const ANCHORS: Record<AnchorId, { side: Side; fill?: true; origin?: string }> = {
  squad: { side: 'top-left' },
  counters: { side: 'top-right' },
  feed: { side: 'top-right' },
  placard: { side: 'top' },
  storm: { side: 'top' },
  vitals: { side: 'bottom-left' },
  // FULL-STAGE ANCHORS. Chat and the notice stack are `position: fixed` at App
  // level and the bleed-out card positions itself, so their anchor is a box the
  // size of the screen and their own corner is the origin of any scale. Chat's
  // corner is Chat.tsx's own bottom: over the radar, the gap, and the vitals
  // strip's bump when the strip sits above the radar.
  chat: {
    side: 'bottom-left', fill: true,
    origin: 'var(--map-left) calc(100% - var(--map-bottom) - var(--map-h) - var(--vitals-gap) - var(--vitals-lift))',
  },
  notices: {
    side: 'bottom-left', fill: true,
    origin: 'calc(var(--map-left) + var(--map-w)) calc(100% - var(--map-bottom))',
  },
  yubikey: { side: 'bottom-right' },
  vehicle: { side: 'bottom-right' },
  inventory: { side: 'bottom-right' },
  talking: { side: 'bottom' },
  voice: { side: 'bottom' },
  spectate: { side: 'bottom' },
  dbno: { side: 'bottom', fill: true, origin: '50% calc(100% - 10rem)' },
}

export const ANCHOR_IDS = Object.keys(ANCHORS) as AnchorId[]

/** THE ONE PLACE THE HUD'S MOTION IS NAMED: the kit's own Broadcast preset,
 *  at its own step. Every scope of the v2 HUD (./HudLayer.tsx) takes it. */
export const PRESET = 'broadcast'

/** EVERY EDGE AND SURFACE CHANNEL BELOW OPENS AS A WINDOW. */
const MASK = true

/**
 * THE TURNS: the kit's suggested order (clockwise from where the eye starts:
 * the squad first, then the counters, the top placard, the feed, the radar's
 * column, the inventory, the bottom line) with the wipe's own on top of it,
 * merged into one table.
 */
const WIPE: Record<AnchorId, AnchorFx> = {
  // The left column, top to bottom under the squad. The slanted vitals are
  // the wipe as they are: no channel of the anchor's own.
  squad: { order: 0 },
  chat: { order: 1 },
  vitals: { order: 3, channel: [] },
  notices: { order: 4, channel: ['surface'] },
  // The top center: unroll down from the top edge.
  placard: { order: 3, channel: ['edge'] },
  storm: { order: 3, channel: ['edge'] },
  // The bottom center: unroll up from the bottom edge.
  voice: { order: 5, channel: ['edge'] },
  spectate: { order: 5, channel: ['edge'] },
  talking: { order: 5, channel: ['edge'] },
  // The right column, top to bottom: open from the right edge.
  counters: { order: 6, channel: ['surface'] },
  feed: { order: 6 },
  yubikey: { order: 7, channel: ['surface'] },
  vehicle: { order: 7 },
  inventory: { order: 8, channel: ['surface'] },
  // ITS hotDrop IS ITS ENTRANCE (index.css .panel-hot), so it never plays one
  // of ours; it fades out with the HUD (the ambulance) or on a revive.
  dbno: { order: 0, preset: 'fade', channel: [], appear: false },
}

/** One anchor, resolved: its turn, its layout, and the window it opens. */
export interface Resolved {
  order: number
  /** Its place among the anchors on the same side (--hud-j). */
  j: number
  side: Side
  fill: boolean
  channel: ChannelName[]
  dir: 1 | 0 | -1
  preset: string | undefined
  appear: boolean
  ox: string
  oy: string
  origin: string | undefined
  /** The edge and the surface open as a window. */
  mask: boolean
  /** The window's edge, by side: the surface's from the right (1) or the
   *  left (-1), none from the middle (0: it keeps its scale); the edge's from
   *  the bottom (1) or the top (-1). */
  wx: 1 | 0 | -1
  wy: 1 | -1
}

function dirOf(side: Side): 1 | 0 | -1 {
  if (side.endsWith('left')) return 1
  if (side.endsWith('right')) return -1
  return 0
}

function resolve(table: Record<AnchorId, AnchorFx>): Record<AnchorId, Resolved> {
  const out = {} as Record<AnchorId, Resolved>
  for (const id of ANCHOR_IDS) {
    const own = table[id]
    const where = ANCHORS[id]
    const side = where.side
    out[id] = {
      order: own.order ?? 0,
      j: 0,
      side,
      fill: where.fill === true,
      channel: own.channel ?? ['content'],
      dir: own.dir ?? dirOf(side),
      preset: own.preset,
      appear: own.appear ?? true,
      ox: side.endsWith('left') ? '0%' : side.endsWith('right') ? '100%' : '50%',
      oy: side.startsWith('top') ? '0%' : '100%',
      origin: own.origin ?? where.origin,
      mask: MASK,
      wx: side.endsWith('left') ? -1 : side.endsWith('right') ? 1 : 0,
      wy: side.startsWith('top') ? -1 : 1,
    }
  }
  // --hud-j: the turn within a side, for CSS that staggers a corner itself.
  const sides = new Map<Side, AnchorId[]>()
  for (const id of ANCHOR_IDS) {
    const list = sides.get(out[id].side) ?? []
    list.push(id)
    sides.set(out[id].side, list)
  }
  for (const list of sides.values()) {
    list.sort((a, b) => out[a].order - out[b].order)
    list.forEach((id, i) => { out[id].j = i })
  }
  return out
}

/** Every anchor's part, resolved once: the HUD has one choreography. */
export const TURNS: Record<AnchorId, Resolved> = resolve(WIPE)

/** The highest turn, for the length of a reveal and every scope's floor. */
export const LAST_TURN: number = Math.max(...ANCHOR_IDS.map((id) => TURNS[id].order))

/** The HUD root's own preset: up at once, down only when the slowest anchor's
 *  way out can have ended (its turn counted back from the last one, plus its
 *  preset's longest leave). Nothing on screen moves on it: it times the root. */
export const ROOT_PRESET = 'hudRoot'

const OFF: Timing = { ms: 0, at: 0, ease: EASE.linear }

/** Register ROOT_PRESET's timings for `r` under `scopePreset`, and name it. */
export function registerRootPreset(r: Record<AnchorId, Resolved>, scopePreset: string): string {
  const max = Math.max(...ANCHOR_IDS.map((id) => r[id].order))
  const names = new Set<string>([scopePreset, ...ANCHOR_IDS.map((id) => r[id].preset ?? scopePreset)])
  let hold = 0
  for (const name of names) {
    const spec = getPreset(name)
    let win = 0
    for (const ch of Object.values(spec.leave)) if (ch.ms > 0) win = Math.max(win, ch.at + ch.ms)
    hold = Math.max(hold, max * spec.leaveStep + win)
  }
  registerPreset({
    name: ROOT_PRESET,
    enter: { root: OFF, edge: OFF, surface: OFF, content: OFF },
    leave: { root: { ms: hold, at: 0, ease: EASE.linear }, edge: OFF, surface: OFF, content: OFF },
    step: 0,
    leaveStep: 0,
    reverse: false,
    layer: false,
  })
  return ROOT_PRESET
}
