import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import { fadeEnd, fadeRecords } from '../ui/useFade'
import { onCoverReported } from './cover'
import { bridgeStats, fetchNui } from './nui'
import { CB } from './types'
import {
  dueAt, moving, RETRY_MS, screenChanges, screenPayload, settle, wantedScreen,
  type Burst, type LayerReading, type PageReading, type ScreenKey, type ScreenReading, type ScreenWant,
} from './screenReport'

/**
 * Report what is on screen after every page-side step of a ready-up or a
 * return to the lobby (#252).
 *
 * See bridge/screenReport.ts for the line and how to read it. This is only the
 * WHEN and the measuring:
 *
 *   * ON EVERY STEP, NOT ONLY THE LOBBY FLIPPING. LEAVING arriving, the curtain
 *     reaching black, the curtain coming down, a state change at the lobby's
 *     border, the lobby flipping and the lobby taking or giving up focus each
 *     arm it (screenChanges), and br_ui compares the page's state with what Lua
 *     sent.
 *   * ONE LINE PER BURST. A ready-up is five of those steps inside a second; a
 *     reading falls due QUIET_MS after the last of them, or MAX_WAIT_MS after
 *     the first if they keep coming. A healthy ready-up prints two: under the
 *     curtain, and after it lifts.
 *   * ONE INSTANT, AND NEVER MID-FADE (round 3). When the reading falls due and
 *     any layer it reads is still inside its fade -- the curtain lifting, a
 *     sub-screen entering -- it waits for that fade to settle and tries again
 *     (screenReport.ts `settle`). Then state, layers and pages are all read at
 *     that one instant. Round 2 read them at the END of the frame count, and on
 *     the owner's timings the curtain was always half way up by then.
 *   * FRAMES ARE COUNTED AFTER THE READING, BY A TIMER-CLOSED WINDOW, and
 *     nothing is read again when it closes. The case this exists to see is a
 *     page producing no frames, and a count that waited on a frame to end
 *     would never be sent in exactly that case.
 *   * 'forced' IS THIS BURST'S. A layer's fade end counts only if it ended
 *     after the burst's first step.
 */

/** The frame-count window. */
const FRAME_WINDOW_MS = 500

function countFrames(ms: number): Promise<number> {
  return new Promise((resolve) => {
    let n = 0
    let open = true
    const tick = () => {
      if (!open) return
      n++
      requestAnimationFrame(tick)
    }
    requestAnimationFrame(tick)
    window.setTimeout(() => { open = false; resolve(n) }, ms)
  })
}

function readLayer(name: string, since: number): LayerReading {
  const el = document.querySelector<HTMLElement>(`[data-layer="${name}"]`)
  if (!el) return { opacity: 0, visibility: 'missing' }
  const cs = getComputedStyle(el)
  return { opacity: parseFloat(cs.opacity), visibility: cs.visibility, end: fadeEnd(name, since) }
}

function readPages(since: number): PageReading[] {
  return [...document.querySelectorAll<HTMLElement>('[data-page]')].map((el) => {
    const cs = getComputedStyle(el)
    const name = el.dataset.page ?? '?'
    return {
      name,
      phase: el.classList.contains('page-out') ? 'out' : 'in',
      opacity: parseFloat(cs.opacity),
      visibility: cs.visibility,
      end: fadeEnd(`page:${name}`, since),
    }
  })
}

/**
 * @param showLobby  App's own decision to draw the lobby
 * @param hudShown   ...and the HUD (`hudUp && !hudPaused`)
 * @param leaving    whether the curtain is wanted
 */
export function useScreenReport(showLobby: boolean, hudShown: boolean, leaving: boolean): void {
  const match = useUi((s) => s.match.state)
  const me = useUi((s) => s.hud.state)
  const focus = useUi((s) => s.focus)
  const frontendUp = useUi((s) => s.frontendUp)
  const scoped = useUi((s) => s.scoped)

  // What App had decided to draw as of the last commit whose effects have run.
  // Set in an effect, not in render: a reading only trusts the fade records
  // once the effects of the render that drew this state -- which open those
  // fades -- have run (`behind` below).
  const want = useRef<ScreenWant & { match: string; me: string } | null>(null)
  useEffect(() => {
    want.current = { frontendUp, leaving, focus, showLobby, hudShown, scoped, match, me }
  })

  const prev = useRef<ScreenKey | null>(null)
  const pending = useRef<Burst | null>(null)
  const timer = useRef(0)

  // One stable function for the life of the page, so the cover listener below
  // and the effects share the same pending report.
  const arm = useRef((why: string[]) => {
    const now = performance.now()
    const p = pending.current ?? (pending.current = { why: [], first: now })
    for (const w of why) if (!p.why.includes(w)) p.why.push(w)
    window.clearTimeout(timer.current)
    timer.current = window.setTimeout(take, Math.max(0, dueAt(p, now) - now))
  }).current

  /** The store has moved past what the last committed render (and its effects) drew. */
  function behind(): boolean {
    const w = want.current
    const s = useUi.getState()
    return !w || w.match !== s.match.state || w.me !== s.hud.state || w.focus !== s.focus
      || w.leaving !== s.leaving || w.frontendUp !== s.frontendUp || w.scoped !== s.scoped
  }

  function take() {
    const p = pending.current
    if (!p) return
    const now = performance.now()
    const m = moving(fadeRecords(), now)
    if (behind()) { m.names.push('render'); m.waitMs = Math.max(m.waitMs, RETRY_MS) }
    const step = settle(p, m, now)
    if (!step.read) {
      timer.current = window.setTimeout(take, step.waitMs)
      return
    }
    pending.current = null

    // ═══ ONE INSTANT ═══ Everything below is read together, before a single
    // frame is counted, and none of it is read again.
    const w = want.current ?? { frontendUp: false, leaving: false, focus: 'none', showLobby: false, hudShown: false, scoped: false }
    const s = useUi.getState()
    const b = bridgeStats()
    const reading: ScreenReading = {
      why: p.why,
      match: s.match.state,
      me: s.hud.state,
      focus: s.focus,
      leaving: s.leaving,
      wanted: wantedScreen(w),
      lobby: readLayer('lobby', p.first),
      hud: readLayer('hud', p.first),
      curtain: readLayer('curtain', p.first),
      ui: readLayer('ui', p.first),
      pages: readPages(p.first),
      settling: step.settling,
      frames: 0,
      frameMs: FRAME_WINDOW_MS,
      pageVisible: document.visibilityState,
      focused: document.hasFocus(),
      upMs: now,
      seq: b.seq,
      stale: b.stale,
      unheard: b.unheard,
    }
    void countFrames(FRAME_WINDOW_MS).then((frames) => {
      void fetchNui(CB.SCREEN, screenPayload({ ...reading, frames }))
    })
  }

  useEffect(() => {
    const key: ScreenKey = { match, me, leaving, focus, showLobby }
    const why = screenChanges(prev.current, key)
    prev.current = key
    if (why.length > 0) arm(why)
  }, [match, me, leaving, focus, showLobby, arm])

  // The curtain reaching black is a step too: it is the moment Lua is told it
  // may change the world, and the one round 1's review caught going out early.
  useEffect(() => onCoverReported((kind, covered) => {
    if (kind === 'curtain' && covered) arm(['black'])
  }), [arm])

  useEffect(() => () => window.clearTimeout(timer.current), [])
}
