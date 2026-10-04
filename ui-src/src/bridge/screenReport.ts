/**
 * THE ONE LINE THAT SAYS WHAT THE PAGE IS SHOWING (#252).
 *
 * The owner's log for "the lobby UI doesn't go away" had every Lua step of the
 * ready-up in order and nothing from the page at all, so the one question that
 * mattered -- did the page apply warmup and fail to DRAW it, or never apply it?
 * -- could only be argued, never read. This is the page's half of the answer.
 * br_ui adds the other half -- what Lua last SENT -- and prints one line:
 *
 *   [br_ui] screen after curtain down -- ok | wanted hud, showing hud
 *   | page warmup/warmup, lua warmup/warmup | lobby off (0 hidden, transition)
 *   | hud on (1, transition) | curtain off (0, transition) | ui on (1) | focus none
 *   | 72 frames in 500ms | page visible, focused | seq 812, 0 stale | up 87m12s
 *
 * THE VERDICT after `--` is the reading (br_ui/client/nui.lua composes it):
 *
 *   ok        the page holds what Lua sent, draws what that wants, and is
 *             producing frames. If the lobby is still on the monitor while
 *             the line says ok, the game is showing an old frame of the page.
 *   forced    as ok, but a fade never finished on its own: the animation
 *             clock had stopped and ui/fade.ts put the screen right.
 *   0 frames  nothing is being drawn at all -- CEF/GPU, not the page.
 *   WRONG     the page's state is not what Lua sent (a dropped envelope), or
 *             its styles are not what its state wants. The reason follows.
 *
 * WHEN is bridge/useScreenReport.ts. NO RUNTIME IMPORTS, so node runs this file
 * as-is (scripts/test-fade.mjs).
 */

import type { FadeEnd } from '../ui/useFade'

/** The screens this line can name, topmost first. */
export type ScreenName = 'curtain' | 'lobby' | 'hud' | 'nothing'

/** One layer's computed style, read off the DOM. */
export interface LayerReading {
  opacity: number
  /** Computed `visibility`; 'missing' when the element is not in the page. */
  visibility: string
  /** How its last fade ended, if it has had one. */
  end?: FadeEnd
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

export interface ScreenReading {
  /** What armed it, in order, from screenChanges and the cover report. */
  why: string[]
  /** The store's match.state and hud.state -- what the page was told. */
  match: string
  me: string
  /** The store's focus screen and curtain flag. */
  focus: string
  leaving: boolean
  /** What that state wants on screen. */
  wanted: ScreenName
  lobby: LayerReading
  hud: LayerReading
  curtain: LayerReading
  /** The whole interface's gate under GTA's own menu (App.tsx). */
  ui: LayerReading
  /** requestAnimationFrame callbacks counted over `frameMs`. */
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

/** The topmost of our layers that is drawn, which is what the player sees. */
export function showing(r: ScreenReading): ScreenName {
  // The gate first: under it, nothing of ours is drawn whatever each layer says.
  // A page with no gate element at all is read as open -- it is not the gate's
  // absence this report is about.
  if (r.ui.visibility !== 'missing' && !drawn(r.ui)) return 'nothing'
  if (drawn(r.curtain)) return 'curtain'
  if (drawn(r.lobby)) return 'lobby'
  if (drawn(r.hud)) return 'hud'
  return 'nothing'
}

/** Did any layer's last fade have to be finished by the JS clock? */
export function anyForced(r: ScreenReading): boolean {
  return [r.lobby, r.hud, r.curtain, r.ui].some((l) => l.end === 'forced')
}

function layer(name: string, l: LayerReading, withVisibility: boolean): string {
  const state = drawn(l) ? 'on' : 'off'
  const parts = [String(Math.round(l.opacity * 100) / 100)]
  if (withVisibility || l.visibility !== 'visible') parts[0] += ` ${l.visibility}`
  if (l.end) parts.push(l.end)
  return `${name} ${state} (${parts.join(', ')})`
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
    frames: r.frames,
    match: r.match,
    me: r.me,
    leaving: r.leaving,
    focus: r.focus,
    seq: r.seq,
    detail: screenDetail(r),
  }
}
