/**
 * The browser half of the cold line and the idle switches (#252, round 4).
 *
 * bridge/coldProbe.ts decides everything -- when an action is cold, what the
 * marks are, which switch runs what -- and touches nothing. This is the only
 * file that touches the page for it: the input listeners, the DOM observer,
 * the long-task and Element Timing observers, nui.ts's taps, the heartbeat's
 * dot and the store's warm beat.
 *
 * NOTHING HERE RUNS UNTIL LUA ARMS IT. installDiag() subscribes to the `diag`
 * envelope and does nothing else; br_ui/client/idle.lua sends one only in dev
 * mode, and every switch is off until it says otherwise.
 *
 * THE PROBE'S OWN NODES LIVE OUTSIDE <body> (children of <html>, which still
 * render), and the DOM observer watches <body>: the heartbeat's dot and the
 * Element Timing marker are never activity and never a commit. That is what
 * lets a cold line print with `bruipaint` on, which is the A/B.
 */

import { fetchNui, setBridgeTap, subscribe } from './nui'
import { CB } from './types'
import { useUi } from '../store'
import {
  createDiag, parseDiag, type DiagEnv, type InputKind, type PageInventory, type PaintMode,
} from './coldProbe'

const INPUTS: InputKind[] = ['pointerdown', 'pointerup', 'click', 'keydown']

/** One pixel in the corner, at 2-3% black: there for the compositor, not for the player. */
const DOT_CSS = 'position:fixed;left:0;top:0;width:1px;height:1px;pointer-events:none;'
  + 'z-index:2147483647;margin:0;padding:0;border:0;'
const MARK_CSS = 'position:fixed;left:0;top:0;font:4px/4px sans-serif;color:rgba(255,255,255,0.02);'
  + 'pointer-events:none;z-index:2147483647;margin:0;padding:0;white-space:nowrap;'

interface Memory { usedJSHeapSize: number; totalJSHeapSize: number }
const memory = (): Memory | undefined => (performance as unknown as { memory?: Memory }).memory
const MB = 1024 * 1024

function browserEnv(): DiagEnv {
  const inputs = new Map<InputKind, (e: Event) => void>()
  let mo: MutationObserver | null = null
  let lto: PerformanceObserver | null = null
  let eto: PerformanceObserver | null = null
  const marks = new Map<string, HTMLElement>()
  let dotEl: HTMLElement | null = null
  let dotMode: PaintMode | null = null
  let dotPhase = false

  return {
    now: () => performance.now(),
    ignore: new Set<string>([
      CB.SFX, CB.SCREEN, CB.COVERED, CB.ENV, CB.ERROR, CB.PALETTE, CB.COLD, CB.IDLE,
    ]),

    listen(on, fn) {
      for (const [k, h] of inputs) window.removeEventListener(k, h, true)
      inputs.clear()
      if (!on) return
      for (const k of INPUTS) {
        const h = (e: Event) => fn(k, e.timeStamp)
        inputs.set(k, h)
        window.addEventListener(k, h, { capture: true, passive: true })
      }
    },

    observe(on, fn) {
      mo?.disconnect()
      mo = null
      if (!on) return
      mo = new MutationObserver(() => fn())
      mo.observe(document.body, { subtree: true, childList: true, attributes: true, characterData: true })
    },

    longtasks(on, fn) {
      lto?.disconnect()
      lto = null
      if (!on) return
      try {
        const o = new PerformanceObserver((l) => {
          for (const e of l.getEntries()) fn(e.startTime, e.duration)
        })
        o.observe({ type: 'longtask' })
        lto = o
      } catch { /* no long-task timing on this build: the line says 0 */ }
    },

    presentation(on, fn) {
      eto?.disconnect()
      eto = null
      if (!on) return false
      const types = (PerformanceObserver as unknown as { supportedEntryTypes?: readonly string[] })
        .supportedEntryTypes ?? []
      if (!types.includes('element')) return false
      try {
        const o = new PerformanceObserver((l) => {
          for (const e of l.getEntries()) {
            const el = e as unknown as { identifier?: string; renderTime?: number }
            if (typeof el.identifier === 'string') fn(el.identifier, el.renderTime ?? 0)
          }
        })
        o.observe({ type: 'element', buffered: true })
        eto = o
        return true
      } catch {
        return false
      }
    },

    tap: (t) => setBridgeTap(t),
    raf: (fn) => { requestAnimationFrame(() => fn()) },
    afterFrame(fn) {
      const ch = new MessageChannel()
      ch.port1.onmessage = () => { ch.port1.close(); fn() }
      ch.port2.postMessage(0)
    },
    // React flushes a store change in a microtask; three hops land after it
    // and after the DOM observer's own callback for what it changed.
    settle: (fn) => { queueMicrotask(() => queueMicrotask(() => queueMicrotask(fn))) },
    every: (ms, fn) => window.setInterval(fn, ms),
    stop: (id) => window.clearInterval(id),
    later: (ms, fn) => { window.setTimeout(fn, ms) },

    mark(id) {
      const el = document.createElement('span')
      el.setAttribute('elementtiming', id)
      el.style.cssText = MARK_CSS
      el.textContent = '.'
      document.documentElement.appendChild(el)
      marks.set(id, el)
    },
    unmark(id) {
      marks.get(id)?.remove()
      marks.delete(id)
    },

    dot(mode) {
      dotEl?.remove()
      dotEl = null
      dotMode = mode
      dotPhase = false
      if (mode === null || mode === 'raf') return
      const el = document.createElement('div')
      // `comp` on a layer of its own, so an opacity change is the compositor's
      // alone; `raster` painted with whatever it sits on, so a change repaints.
      el.style.cssText = DOT_CSS + (mode === 'comp'
        ? 'will-change:opacity;background:#000;opacity:0.02;'
        : 'background:rgba(0,0,0,0.02);')
      document.documentElement.appendChild(el)
      dotEl = el
    },
    flip() {
      const el = dotEl
      if (!el) return
      dotPhase = !dotPhase
      if (dotMode === 'comp') el.style.opacity = dotPhase ? '0.03' : '0.02'
      else el.style.backgroundColor = dotPhase ? 'rgba(0,0,0,0.03)' : 'rgba(0,0,0,0.02)'
    },

    warm: () => useUi.getState().warmBeat(),

    heapMB() {
      const m = memory()
      return m ? m.usedJSHeapSize / MB : null
    },

    inventory(): PageInventory {
      const m = memory()
      let animations: string[] = []
      if (typeof document.getAnimations === 'function') {
        animations = document.getAnimations()
          .filter((a) => a.playState === 'running')
          .map((a) => {
            const named = a as Animation & { animationName?: string; transitionProperty?: string }
            const what = named.animationName ?? named.transitionProperty ?? 'animation'
            const target = (a.effect as KeyframeEffect | null)?.target
            const cls = target instanceof Element ? String(target.className || target.tagName).split(' ')[0] : '?'
            return `${what} on ${cls}`.slice(0, 48)
          })
      }
      return {
        heapMB: m ? m.usedJSHeapSize / MB : null,
        heapTotalMB: m ? m.totalJSHeapSize / MB : null,
        nodes: document.getElementsByTagName('*').length,
        animations,
        visible: document.visibilityState,
        focused: document.hasFocus(),
      }
    },

    send(what: 'cold' | 'idle', payload: unknown) {
      void fetchNui(what === 'cold' ? CB.COLD : CB.IDLE, payload)
    },
  }
}

/** Subscribe to the `diag` envelope. Called once, from main.tsx, before the page reports its environment. */
export function installDiag(): void {
  const diag = createDiag(browserEnv())
  subscribe('diag', (d) => diag.apply(parseDiag(d)))
}
