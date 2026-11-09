/**
 * BROADCAST KIT: THE MOTION NUMBERS (#431), ONCE.
 *
 * The presence choreography (onAir, offAir, the stagger, the quick hide) is
 * timed here and nowhere else: the JS settle clock needs the durations, and
 * the Web Animations API cannot read var(), so the curves are literals. Each
 * presence root receives its numbers as custom properties (machine.ts
 * rootVars), so CSS never repeats them.
 *
 * Every curve and every duration that ALSO appears in CSS (tokens.css
 * --bc-ease-*, --bc-t-*, --bc-step) is pinned to it by
 * scripts/test-broadcast.mjs, and --bc-ease-out / --bc-ease-snap are pinned
 * through to src/index.css.
 *
 * NO RUNTIME IMPORTS, so node runs this file as-is (scripts/test-broadcast.mjs).
 */

/** The curves, as literals (tokens.css --bc-ease-*). */
export const EASE = {
  out: 'cubic-bezier(0.22, 1, 0.36, 1)',
  snap: 'cubic-bezier(0.16, 1.1, 0.3, 1)',
  wipe: 'cubic-bezier(0.65, 0, 0.35, 1)',
  sweep: 'cubic-bezier(0.45, 0, 0.55, 1)',
  exit: 'cubic-bezier(0.55, 0, 0.75, 0.2)',
  fly: 'cubic-bezier(0.2, 0.9, 0.3, 1)',
  fall: 'cubic-bezier(0.2, 0.8, 0.3, 1)',
  linear: 'linear',
} as const

/** Durations the TS side needs (tokens.css --bc-t-*, pinned). */
export const T = {
  quick: 150,
  fade: 200,
  tick: 120,
  burn: 360,
  flip: 420,
  rowLeave: 440,
  hotDrop: 620,
} as const

/** Between anchors on the way in; a leave runs back at half. */
export const STEP = 80
export const LEAVE_STEP = 40

/** A numeral's count-up (an option, for the owner's call): at most ten discrete
 *  timer writes, the last one the true value. */
export const COUNT = { ms: 400, writes: 10 } as const

/** A numeral's tick-in reveal: one place after another. */
export const REVEAL_PLACE_MS = 40

// ---------------------------------------------------------------------------
// THE PRESET SHAPE. Four channels: the presence root itself, and the three a
// plate is built from -- the EDGE (its slab), the SURFACE (the plate and its
// cover) and the CONTENT (the upright face). A preset says, per channel, how
// long it takes, when it starts after its anchor's turn, and on what curve.
// ---------------------------------------------------------------------------

export type Channel = 'root' | 'edge' | 'surface' | 'content'
export const CHANNELS: readonly Channel[] = ['root', 'edge', 'surface', 'content']

export interface Timing {
  /** Duration, ms. 0 is "this channel does not move". */
  ms: number
  /** Start, ms after the anchor's own turn in the stagger. */
  at: number
  /** A literal curve (WAAPI-safe). */
  ease: string
}

export type Timings = Record<Channel, Timing>

export interface PresetSpec {
  name: string
  enter: Timings
  leave: Timings
  /** ms between anchors on the way in. */
  step: number
  /** ms between anchors on the way out. */
  leaveStep: number
  /** The way out runs the stagger backwards (last in, first out). */
  reverse: boolean
  /** A LAYER preset (quickHide): one opacity channel on a layer root, which
   *  never unmounts and never replays an entrance. */
  layer: boolean
}

const OFF: Timing = { ms: 0, at: 0, ease: EASE.linear }

const only = (root: Timing): Timings => ({ root, edge: OFF, surface: OFF, content: OFF })

/** The halves presets are made of. A preset is an in-half and an out-half. */
export const HALF = {
  /** ON AIR: the edge rises, the plate opens from its slab, the content slides
   *  in (the loading screen's lower third: spine, plates, then text). */
  onAir: {
    root: OFF,
    edge: { ms: 360, at: 0, ease: EASE.out },
    surface: { ms: 420, at: 80, ease: EASE.out },
    content: { ms: 480, at: 160, ease: EASE.out },
  },
  /** OFF AIR: the content goes, the plate closes toward its slab, the edge drops. */
  offAir: {
    root: OFF,
    content: { ms: 140, at: 0, ease: EASE.exit },
    surface: { ms: 260, at: 60, ease: EASE.exit },
    edge: { ms: 200, at: 120, ease: EASE.exit },
  },
  /** THE QUICK HIDE: a layer's opacity, the same each way. */
  quick: only({ ms: T.quick, at: 0, ease: EASE.linear }),
  /** today's hotDrop (the overshoot comes from the snap curve). */
  dropIn: only({ ms: T.hotDrop, at: 0, ease: EASE.snap }),
  /** today's HUD root fade. */
  fade: only({ ms: T.fade, at: 0, ease: EASE.linear }),
  /** noticeIn's fly. */
  slideIn: only({ ms: 220, at: 0, ease: EASE.fly }),
  none: only(OFF),
} satisfies Record<string, Timings>

/** A half at twice the speed: every duration and every start halved, the
 *  curves kept, so the choreography is the same, only faster. */
function twice(t: Timings): Timings {
  const out = { ...t }
  for (const c of CHANNELS) out[c] = { ...t[c], ms: t[c].ms / 2, at: t[c].at / 2 }
  return out
}

/** THE PAGE PRESET'S NAME, for the page's scope to name, as it names
 *  PAGE_STEP: a name nobody registered falls back to broadcast without a word
 *  (presets.ts getPreset), so a misspelled literal would play at full speed. */
export const PAGE_PRESET = 'page'

/** THE PAGE'S STAGGER, in and out: the leave step halved (20 ms). A page's
 *  scope names it as well: a scope that names no step takes the one above
 *  it, which would outrank the preset's. */
export const PAGE_STEP = LEAVE_STEP / 2

/** The presets every screen can name. Others plug in (presets.ts registerPreset). */
export const BUILT_IN: readonly PresetSpec[] = [
  { name: 'broadcast', enter: HALF.onAir, leave: HALF.offAir, step: STEP, leaveStep: LEAVE_STEP, reverse: true, layer: false },
  // THE PAGE: broadcast at twice the speed, for the pages over a match, the
  // TAB page and the player list (the owner, 2026-11-04: "make the inventory
  // page appear and disappear 2x the speed"; the player list matches it). In
  // 320 ms, out in 160; its hidden values are broadcast's (motion.css).
  { name: PAGE_PRESET, enter: twice(HALF.onAir), leave: twice(HALF.offAir), step: PAGE_STEP, leaveStep: PAGE_STEP, reverse: true, layer: false },
  { name: 'quickHide', enter: HALF.quick, leave: HALF.quick, step: 0, leaveStep: 0, reverse: false, layer: true },
  { name: 'drop', enter: HALF.dropIn, leave: HALF.fade, step: STEP, leaveStep: LEAVE_STEP, reverse: true, layer: false },
  { name: 'fade', enter: HALF.fade, leave: HALF.fade, step: 0, leaveStep: 0, reverse: false, layer: false },
  { name: 'slide', enter: HALF.slideIn, leave: HALF.fade, step: LEAVE_STEP, leaveStep: 0, reverse: false, layer: false },
  { name: 'none', enter: HALF.none, leave: HALF.none, step: 0, leaveStep: 0, reverse: false, layer: false },
]
