import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import { fadeEnd } from '../ui/useFade'
import { onCoverReported } from './cover'
import { bridgeStats, fetchNui } from './nui'
import { CB } from './types'
import { screenChanges, screenPayload, type LayerReading, type ScreenKey, type ScreenName } from './screenReport'

/**
 * Report what is on screen after every page-side step of a ready-up or a
 * return to the lobby (#252).
 *
 * See bridge/screenReport.ts for the line and how to read it. This is only the
 * WHEN and the measuring:
 *
 *   * ON EVERY STEP, NOT ONLY THE LOBBY FLIPPING. Round 1 armed on `showLobby`
 *     alone, so the failure it most needed to name -- a page that never got the
 *     warmup, whose lobby therefore never flipped -- printed nothing at all.
 *     Now LEAVING arriving, the curtain reaching black, the curtain coming down,
 *     a state change at the lobby's border, the lobby flipping and the lobby
 *     taking or giving up focus each arm it (screenChanges), and br_ui compares
 *     the page's state with what Lua sent.
 *   * ONE LINE PER BURST. A ready-up is five of those steps inside a second; a
 *     report goes QUIET_MS after the last of them (by which time every fade has
 *     settled), or MAX_WAIT_MS after the first if they keep coming. A healthy
 *     ready-up prints two: under the curtain, and after it lifts.
 *   * FRAMES ARE COUNTED BY A TIMER-CLOSED WINDOW. The case this exists to see
 *     is a page producing no frames, and a count that waited on a frame to end
 *     would never be sent in exactly that case.
 */

/** After the last step: the curtain's 600ms fade and the settle margin, with room. */
const QUIET_MS = 1000
/** Sent by now whatever keeps changing. */
const MAX_WAIT_MS = 5000
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

function readLayer(name: string): LayerReading {
  const el = document.querySelector<HTMLElement>(`[data-layer="${name}"]`)
  if (!el) return { opacity: 0, visibility: 'missing' }
  const cs = getComputedStyle(el)
  return { opacity: parseFloat(cs.opacity), visibility: cs.visibility, end: fadeEnd(name) }
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

  // What App wants RIGHT NOW, read when the report is taken rather than when it
  // was scheduled.
  const live = useRef({ showLobby, hudShown, leaving })
  live.current = { showLobby, hudShown, leaving }

  const prev = useRef<ScreenKey | null>(null)
  const pending = useRef<{ why: string[]; first: number } | null>(null)
  const timer = useRef(0)

  // One stable function for the life of the page, so the cover listener below
  // and the effects share the same pending report.
  const arm = useRef((why: string[]) => {
    const now = performance.now()
    const p = pending.current ?? (pending.current = { why: [], first: now })
    for (const w of why) if (!p.why.includes(w)) p.why.push(w)
    window.clearTimeout(timer.current)
    const at = Math.min(now + QUIET_MS, p.first + MAX_WAIT_MS)
    timer.current = window.setTimeout(take, Math.max(0, at - now))
  }).current

  function take() {
    const p = pending.current
    pending.current = null
    if (!p) return
    void countFrames(FRAME_WINDOW_MS).then((frames) => {
      const want = live.current
      const s = useUi.getState()
      const wanted: ScreenName = s.frontendUp ? 'nothing'
        : want.leaving ? 'curtain'
        : want.showLobby ? 'lobby'
        : want.hudShown && !s.scoped ? 'hud'
        : 'nothing'
      const b = bridgeStats()
      void fetchNui(CB.SCREEN, screenPayload({
        why: p.why,
        match: s.match.state,
        me: s.hud.state,
        focus: s.focus,
        leaving: s.leaving,
        wanted,
        lobby: readLayer('lobby'),
        hud: readLayer('hud'),
        curtain: readLayer('curtain'),
        ui: readLayer('ui'),
        frames,
        frameMs: FRAME_WINDOW_MS,
        pageVisible: document.visibilityState,
        focused: document.hasFocus(),
        upMs: performance.now(),
        seq: b.seq,
        stale: b.stale,
        unheard: b.unheard,
      }))
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
