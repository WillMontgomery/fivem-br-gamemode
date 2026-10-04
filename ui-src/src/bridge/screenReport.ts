/**
 * THE ONE LINE THAT SAYS WHAT THE PAGE IS SHOWING (#252).
 *
 * The owner's log for "the lobby UI doesn't go away" had every Lua step of the
 * ready-up in order and nothing from the page at all, so the one question that
 * mattered -- did the page apply warmup and fail to DRAW it, or never apply it?
 * -- could only be argued, never read. This is the answer, printed to F8 by
 * br_ui a second after the lobby comes down or goes back up:
 *
 *   screen after warmup/warmup: wanted hud, showing hud -- ok | lobby off (0 hidden, transition)
 *   | hud on (1, transition) | curtain off (0, transition) | focus none
 *   | 72 frames in 500ms | page visible, focused | up 87m12s
 *
 * Read left to right: what the store holds (match state / my own state), the
 * screen that state wants, the screen the page's computed styles actually
 * show, and the evidence under it. `forced` on a layer means its fade did not
 * finish on its own and ui/fade.ts had to put it there -- the animation clock
 * had stopped. `0 frames` means nothing is being drawn at all, which no page
 * can fix: the styles can be right and the screen still old.
 *
 * NO RUNTIME IMPORTS, so node runs this file as-is (scripts/test-fade.mjs).
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

export interface ScreenReading {
  /** The store's match.state and hud.state -- what the page was told. */
  match: string
  me: string
  /** The store's focus screen. */
  focus: string
  /** What that state wants on screen. */
  wanted: ScreenName
  lobby: LayerReading
  hud: LayerReading
  curtain: LayerReading
  /** requestAnimationFrame callbacks counted over `frameMs`. */
  frames: number
  frameMs: number
  /** document.visibilityState and document.hasFocus(). */
  pageVisible: string
  focused: boolean
  /** How long this page has been loaded. A reload resets it. */
  upMs: number
}

/** Is this layer drawing anything at all? */
export function drawn(l: LayerReading): boolean {
  return l.visibility !== 'missing' && l.visibility !== 'hidden' && l.opacity > 0.01
}

/** The topmost of our layers that is drawn, which is what the player sees. */
export function showing(r: ScreenReading): ScreenName {
  if (drawn(r.curtain)) return 'curtain'
  if (drawn(r.lobby)) return 'lobby'
  if (drawn(r.hud)) return 'hud'
  return 'nothing'
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

/** The line, without the `[br_ui]` prefix Lua puts on it. */
export function formatScreenLine(r: ScreenReading): string {
  const is = showing(r)
  const verdict = is === r.wanted
    ? `wanted ${r.wanted}, showing ${is} -- ok`
    : `wanted ${r.wanted}, showing ${is.toUpperCase()} -- WRONG`
  return [
    `screen after ${r.match}/${r.me}: ${verdict}`,
    layer('lobby', r.lobby, true),
    layer('hud', r.hud, false),
    layer('curtain', r.curtain, false),
    `focus ${r.focus}`,
    `${r.frames} frames in ${r.frameMs}ms${r.frames === 0 ? ' (nothing is being drawn)' : ''}`,
    `page ${r.pageVisible}, ${r.focused ? 'focused' : 'unfocused'}`,
    `up ${duration(r.upMs)}`,
  ].join(' | ')
}
