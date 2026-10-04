import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import { fadeEnd } from '../ui/useFade'
import { fetchNui } from './nui'
import { CB } from './types'
import { formatScreenLine, type LayerReading, type ScreenName } from './screenReport'

/**
 * Report what is on screen once the lobby has come down, or gone back up (#252).
 *
 * See bridge/screenReport.ts for the line and how to read it. This is only the
 * WHEN and the measuring:
 *
 *   * ON A FLIP OF THE LOBBY, NOT ON EVERY STATE. Twice a match: into warmup
 *     and back to the lobby. That is the transition #252 is about, and a line
 *     per HUD state would bury it.
 *   * AFTER THE CURTAIN. A ready-up takes the lobby down behind the curtain, so
 *     a reading taken then would only ever say "curtain". The report waits for
 *     the curtain to come down and for its fade to settle -- and is sent at the
 *     deadline regardless, so a curtain that never lifts is reported too.
 *   * FRAMES ARE COUNTED BY A TIMER-CLOSED WINDOW. The case this exists to see
 *     is a page producing no frames, and a count that waited on a frame to end
 *     would never be sent in exactly that case.
 */

/** After the curtain is down: its 600ms fade and the settle margin, with room. */
const REPORT_AFTER_MS = 1000
/** Sent by now whatever the curtain is doing -- past br_core's 15s curtain lift. */
const REPORT_DEADLINE_MS = 20000
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
  // What App wants RIGHT NOW, read when the report is taken rather than when it
  // was scheduled.
  const live = useRef({ showLobby, hudShown, leaving })
  live.current = { showLobby, hudShown, leaving }

  const last = useRef<boolean | null>(null)
  const since = useRef<number | null>(null)

  // A flip arms a report. The first render is not a flip: the lobby at boot is
  // the page's default, not a transition.
  useEffect(() => {
    if (last.current !== null && last.current !== showLobby) since.current = Date.now()
    last.current = showLobby
  }, [showLobby])

  useEffect(() => {
    if (since.current === null) return
    const left = Math.max(0, REPORT_DEADLINE_MS - (Date.now() - since.current))
    const t = window.setTimeout(() => {
      since.current = null
      void countFrames(FRAME_WINDOW_MS).then((frames) => {
        const want = live.current
        const s = useUi.getState()
        const wanted: ScreenName = want.leaving ? 'curtain'
          : want.showLobby ? 'lobby'
          : want.hudShown && !s.scoped ? 'hud'
          : 'nothing'
        const line = formatScreenLine({
          match: s.match.state,
          me: s.hud.state,
          focus: s.focus,
          wanted,
          lobby: readLayer('lobby'),
          hud: readLayer('hud'),
          curtain: readLayer('curtain'),
          frames,
          frameMs: FRAME_WINDOW_MS,
          pageVisible: document.visibilityState,
          focused: document.hasFocus(),
          upMs: performance.now(),
        })
        void fetchNui(CB.SCREEN, { line })
      })
    }, leaving ? left : Math.min(REPORT_AFTER_MS, left))
    return () => window.clearTimeout(t)
  }, [showLobby, leaving])
}
