/**
 * THE ONE LINE THAT SAYS WHAT THE PAGE IS SHOWING (#252).
 *
 * The owner's log for "the lobby UI doesn't go away" had every Lua step of the
 * ready-up in order and nothing from the page at all, so the one question that
 * mattered -- did the page apply warmup and fail to DRAW it, or never apply it?
 * -- could only be argued, never read. This is the page's half of the answer.
 * br_ui adds the other half -- what Lua last SENT, and what br_core's own state
 * says it should have sent -- and prints one line:
 *
 *   [br_ui] screen after curtain down -- ok | wanted hud, showing hud
 *   | page warmup/warmup, lua warmup/warmup | lobby off (0 hidden)
 *   | hud on (1) | curtain off (0, transition) | ui on (1) | pages none
 *   | focus none | 72 frames in 500ms | page visible, focused | seq 812, 0 stale
 *   | up 87m12s
 *
 * The verdict after `--` is br_ui's (br_ui/client/nui.lua composes it); the
 * list of readings is in that file, beside the code that prints them.
 *
 * ONE INSTANT, NEVER MID-FADE (#252 round 3). Round 2 read the page at the end
 * of a 500ms frame count, so a curtain that started lifting inside that window
 * -- on the owner's own timings, every time -- was read half way down and
 * called WRONG. The reading is now taken at a single instant, and only once no
 * layer it reads is inside its fade (`settle` below); frames are counted after
 * it, without reading anything again.
 *
 * WHEN is bridge/useScreenReport.ts. NO RUNTIME IMPORTS, so node runs this file
 * as-is (scripts/test-fade.mjs).
 */

import type { FadeEnd } from '../ui/fade'

/**
 * The sub-screens (ui/Page.tsx), by the focus name that raises each. A page is
 * reported under that name.
 */
export const PAGE_SCREENS: ReadonlySet<string> = new Set([
  'settings', 'locker', 'market', 'players', 'help', 'admin', 'pause',
])

/**
 * The sub-screens that exist only over the lobby -- the lobby wearing another
 * panel, opened from its menu column and nowhere else. One of these drawn over
 * the warmup HUD is left over from the lobby, whatever focus says.
 */
export const LOBBY_ONLY_PAGES: ReadonlySet<string> = new Set(['locker', 'market'])

/** The screens this line can name: a layer, a sub-screen by name, or nothing. */
export type ScreenName = 'curtain' | 'lobby' | 'hud' | 'nothing' | (string & {})

/** One layer's computed style, read off the DOM. */
export interface LayerReading {
  opacity: number
  /** Computed `visibility`; 'missing' when the element is not in the page. */
  visibility: string
  /** How its fade ended, if it ended within this report's burst. */
  end?: FadeEnd
}

/** One mounted sub-screen wrapper (ui/Page.tsx). */
export interface PageReading extends LayerReading {
  name: string
  /** Entering or shown ('in'), or on its way out ('out'). */
  phase: 'in' | 'out'
}

/**
 * What the page holds, for deciding whether something changed that a ready-up
 * or a return to the lobby is made of.
 */
export interface ScreenKey {
  match: string
  me: string
  leaving: boolean
  focus: string
  showLobby: boolean
}

/** The match states and own states either side of the lobby's border. */
const LOBBY_EDGE_MATCH = new Set(['waiting', 'warmup'])
const LOBBY_EDGE_ME = new Set(['lobby', 'warmup'])

/**
 * What changed between two renders that arms a report -- every page-side step
 * of a ready-up (#252 round 2: round 1 armed only on the lobby flipping, so a
 * page that never got the warmup never flipped and never said a word).
 *
 *   curtain up / down  LEAVING arrived
 *   match a>b, me a>b  a state change at the lobby's border; the drop's own
 *                      states (bus, freefall...) do not arm, or a match would
 *                      print a line per jump
 *   lobby on / off     App's own decision flipped
 *   focus a>b          the lobby took or gave up focus
 *
 * ('black', the curtain reaching opaque, is armed from bridge/cover.ts.)
 * The first reading arms nothing: the boot is not a transition.
 */
export function screenChanges(a: ScreenKey | null, b: ScreenKey): string[] {
  if (a === null) return []
  const out: string[] = []
  if (a.leaving !== b.leaving) out.push(b.leaving ? 'curtain up' : 'curtain down')
  if (a.focus !== b.focus && (a.focus === 'lobby' || b.focus === 'lobby')) {
    out.push(`focus ${a.focus}>${b.focus}`)
  }
  if (a.match !== b.match && (LOBBY_EDGE_MATCH.has(a.match) || LOBBY_EDGE_MATCH.has(b.match))) {
    out.push(`match ${a.match}>${b.match}`)
  }
  if (a.me !== b.me && (LOBBY_EDGE_ME.has(a.me) || LOBBY_EDGE_ME.has(b.me))) {
    out.push(`me ${a.me}>${b.me}`)
  }
  if (a.showLobby !== b.showLobby) out.push(b.showLobby ? 'lobby on' : 'lobby off')
  return out
}

/** What App has decided to draw, as of the last committed render. */
export interface ScreenWant {
  frontendUp: boolean
  leaving: boolean
  focus: string
  showLobby: boolean
  /** `hudUp && !hudPaused` */
  hudShown: boolean
  scoped: boolean
}

/**
 * The one screen that state wants on top. A sub-screen is wanted while focus
 * names it -- except the lobby's own (LOBBY_ONLY_PAGES) once the lobby is gone,
 * so the market left up over warmup reads WRONG naming the market (#252 round
 * 3; round 2's line never looked at a sub-screen at all).
 */
export function wantedScreen(w: ScreenWant): ScreenName {
  if (w.frontendUp) return 'nothing'
  if (w.leaving) return 'curtain'
  if (PAGE_SCREENS.has(w.focus) && (w.showLobby || !LOBBY_ONLY_PAGES.has(w.focus))) return w.focus
  if (w.showLobby) return 'lobby'
  if (w.hudShown && !w.scoped) return 'hud'
  return 'nothing'
}

// ── when to read ────────────────────────────────────────────────────────────

/** After the last step: the curtain's 600ms fade and the settle margin, with room. */
export const QUIET_MS = 1000
/** Due by now whatever keeps changing. */
export const MAX_WAIT_MS = 5000
/**
 * How long past its end a fade still counts as moving: the re-render that drops
 * its transition, and an effect that follows that render (a sub-screen's
 * `.page-shown` swap), land inside it.
 */
export const AFTERMATH_MS = 50
/** The shortest wait before trying again. */
export const RETRY_MS = 50
/**
 * How long a due reading waits for its fades to stop before it is taken anyway
 * and marked `settling` rather than judged. Every fade here settles on the JS
 * clock within ~800ms, so only a layer that keeps flipping gets this far.
 */
export const SETTLE_GIVE_UP_MS = 3000

/** One named fade, as ui/useFade.ts keeps it. */
export interface FadeRecord {
  name: string
  end: FadeEnd
  /** When the window opened ('fading'), or when the fade ended. */
  at: number
  /** Milliseconds until a 'fading' window is due. */
  remaining: number
}

/** What is still moving at `now`, and how long to wait for all of it to stop. */
export interface Moving {
  names: string[]
  waitMs: number
}

/**
 * The fades a reading taken now would catch in flight: every one still inside
 * its window (its duration plus the settle margin), and every one that ended
 * less than AFTERMATH_MS ago.
 */
export function moving(fades: FadeRecord[], now: number): Moving {
  const names: string[] = []
  let waitMs = 0
  for (const f of fades) {
    if (f.end === 'fading') {
      names.push(f.name)
      waitMs = Math.max(waitMs, f.remaining + AFTERMATH_MS)
    } else if (now - f.at < AFTERMATH_MS) {
      names.push(f.name)
      waitMs = Math.max(waitMs, AFTERMATH_MS - (now - f.at))
    }
  }
  return { names, waitMs }
}

/** The steps a report is waiting to describe. */
export interface Burst {
  why: string[]
  /** When the first step arrived. A fade counts as this burst's only if it ended after this. */
  first: number
  /** When the reading first fell due, once it has. */
  due?: number
}

/** When a burst's reading is due: QUIET_MS after its latest step, MAX_WAIT_MS after its first at most. */
export function dueAt(b: Burst, lastStep: number): number {
  return Math.min(lastStep + QUIET_MS, b.first + MAX_WAIT_MS)
}

export type Decision =
  | { read: true; settling: string[] }
  | { read: false; waitMs: number }

/**
 * At a due time: read now, or wait for what is still moving. NEVER A READING
 * TAKEN MID-FADE: it waits for every fade to settle, and if one is still moving
 * SETTLE_GIVE_UP_MS after the reading fell due, the reading goes out marked
 * `settling`, which br_ui prints as that and does not judge.
 */
export function settle(b: Burst, m: Moving, now: number): Decision {
  if (m.names.length === 0) return { read: true, settling: [] }
  const due = b.due ?? (b.due = now)
  if (now - due >= SETTLE_GIVE_UP_MS) return { read: true, settling: m.names }
  return { read: false, waitMs: Math.max(RETRY_MS, m.waitMs) }
}

// ── the reading ─────────────────────────────────────────────────────────────

export interface ScreenReading {
  /** What armed it, in order, from screenChanges and the cover report. */
  why: string[]
  /** The store's match.state and hud.state -- what the page was told. */
  match: string
  me: string
  /** The store's focus screen and curtain flag. */
  focus: string
  leaving: boolean
  /** What that state wants on screen (wantedScreen). */
  wanted: ScreenName
  lobby: LayerReading
  hud: LayerReading
  curtain: LayerReading
  /** The whole interface's gate under GTA's own menu (App.tsx). */
  ui: LayerReading
  /** Every mounted sub-screen, in document order (the last is on top). */
  pages: PageReading[]
  /** Fades still moving when the reading was finally taken anyway. Normally empty. */
  settling: string[]
  /** requestAnimationFrame callbacks counted over `frameMs`, after the reading. */
  frames: number
  frameMs: number
  /** document.visibilityState and document.hasFocus(). */
  pageVisible: string
  focused: boolean
  /** How long this page has been loaded. A reload resets it. */
  upMs: number
  /** The sequence gate's high-water mark and the silent drops (bridge/nui.ts). */
  seq: number
  stale: number
  unheard: number
}

/** Is this layer drawing anything at all? */
export function drawn(l: LayerReading): boolean {
  return l.visibility !== 'missing' && l.visibility !== 'hidden' && l.opacity > 0.01
}

/**
 * The topmost of our layers that is drawn, which is what the player sees: the
 * gate, the curtain (z 60), the sub-screens (z 50, the last mounted on top),
 * the lobby, the HUD.
 */
export function showing(r: ScreenReading): ScreenName {
  // The gate first: under it, nothing of ours is drawn whatever each layer says.
  // A page with no gate element at all is read as open -- it is not the gate's
  // absence this report is about.
  if (r.ui.visibility !== 'missing' && !drawn(r.ui)) return 'nothing'
  if (drawn(r.curtain)) return 'curtain'
  const page = [...r.pages].reverse().find(drawn)
  if (page) return page.name
  if (drawn(r.lobby)) return 'lobby'
  if (drawn(r.hud)) return 'hud'
  return 'nothing'
}

/**
 * Did a fade in THIS burst have to be finished by the JS clock? The ends are
 * already the burst's own (useScreenReport reads them since its first step), so
 * a fade forced on some earlier trip -- GTA's menu gate an hour ago -- does not
 * mark every later line (#252 round 3).
 */
export function anyForced(r: ScreenReading): boolean {
  return [r.lobby, r.hud, r.curtain, r.ui, ...r.pages].some((l) => l.end === 'forced')
}

function layer(name: string, l: LayerReading, withVisibility: boolean, phase?: string): string {
  const state = drawn(l) ? 'on' : 'off'
  const parts = [String(Math.round(l.opacity * 100) / 100)]
  if (withVisibility || l.visibility !== 'visible') parts[0] += ` ${l.visibility}`
  if (l.end) parts.push(l.end)
  return `${name} ${state}${phase ? ` ${phase}` : ''} (${parts.join(', ')})`
}

function duration(ms: number): string {
  const s = Math.max(0, Math.floor(ms / 1000))
  const m = Math.floor(s / 60)
  return m > 0 ? `${m}m${String(s % 60).padStart(2, '0')}s` : `${s}s`
}

/** The evidence: everything after the verdict, page state and Lua state. */
export function screenDetail(r: ScreenReading): string {
  return [
    layer('lobby', r.lobby, true),
    layer('hud', r.hud, false),
    layer('curtain', r.curtain, false),
    layer('ui', r.ui, false),
    r.pages.length === 0 ? 'pages none'
      : `pages ${r.pages.slice(-3).map((p) => layer(p.name, p, false, p.phase)).join(', ')}`,
    `focus ${r.focus}`,
    `${r.frames} frames in ${r.frameMs}ms${r.frames === 0 ? ' (nothing is being drawn)' : ''}`,
    `page ${r.pageVisible}, ${r.focused ? 'focused' : 'unfocused'}`,
    `seq ${r.seq}, ${r.stale} stale${r.unheard > 0 ? `, ${r.unheard} unheard` : ''}`,
    `up ${duration(r.upMs)}`,
  ].join(' | ')
}

/** What is POSTed to br/ui/screen. br_ui composes and prints the line. */
export interface ScreenPayload {
  why: string
  wanted: ScreenName
  showing: ScreenName
  forced: boolean
  /** The fades still moving at the reading, joined; '' when none (the normal case). */
  settling: string
  frames: number
  match: string
  me: string
  leaving: boolean
  focus: string
  seq: number
  detail: string
}

export function screenPayload(r: ScreenReading): ScreenPayload {
  return {
    why: r.why.length > 0 ? r.why.slice(0, 8).join(', ') : 'nothing',
    wanted: r.wanted,
    showing: showing(r),
    forced: anyForced(r),
    settling: r.settling.slice(0, 6).join(', '),
    frames: r.frames,
    match: r.match,
    me: r.me,
    leaving: r.leaving,
    focus: r.focus,
    seq: r.seq,
    detail: screenDetail(r),
  }
}
