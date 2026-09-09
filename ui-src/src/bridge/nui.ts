/**
 * NUI transport.
 *
 * Two directions, both narrow on purpose:
 *   Lua  -> UI : a single window 'message' listener, dispatching by envelope kind
 *   UI   -> Lua: fetchNui(), a POST to https://<resource>/<callback>
 */

import type { CallbackName, EnvelopeKind, WireEnvelope } from './types'
import { ENVELOPE_VERSION } from './types'
import { admit, createSeqGate, type Refusal } from './envelope'

/** True when running under `npm run dev` in a normal browser. */
export const isBrowser = !(window as unknown as { invokeNative?: unknown }).invokeNative

/** The resource name, needed to address callbacks. */
export function resourceName(): string {
  const w = window as unknown as { GetParentResourceName?: () => string }
  return typeof w.GetParentResourceName === 'function'
    ? w.GetParentResourceName()
    : 'br_ui'
}

type Handler = (data: unknown) => void

const handlers = new Map<EnvelopeKind, Set<Handler>>()

/**
 * Highest sequence number seen, so late-arriving stale messages are dropped.
 *
 * Lives in bridge/envelope.ts rather than as a `let` here because the freeze it
 * can cause (#281) is the thing worth testing, and a module-scoped variable in a
 * file that touches `window` at load cannot be driven from a test. See that
 * file's STALE_RUN_LIMIT for why the gate re-seeds itself.
 */
const seq = createSeqGate()

export function subscribe(kind: EnvelopeKind, fn: Handler): () => void {
  let set = handlers.get(kind)
  if (!set) {
    set = new Set()
    handlers.set(kind, set)
  }
  set.add(fn)
  return () => { set!.delete(fn) }
}

/** Feed an envelope through the dispatcher. Exported so mock.ts can drive it. */
export function dispatch(msg: WireEnvelope): void {
  if (!msg || msg.t !== 'br') return

  if (msg.v !== ENVELOPE_VERSION) {
    console.warn(`[br_ui] envelope version ${msg.v}, expected ${ENVELOPE_VERSION}`)
  }

  // Snapshots re-seed everything, so they reset the sequence rather than being
  // dropped as stale -- otherwise a resource restart would leave the UI frozen.
  if (msg.k === 'snapshot') {
    seq.reseed(msg.s)
  } else if (!seq.fresh(msg.s)) {
    return
  }

  const set = handlers.get(msg.k)

  // Do NOT advance the sequence for an envelope nobody is listening for.
  //
  // The window listener is attached at module load; React does not subscribe
  // until after the first render. Consuming the sequence here meant envelopes
  // arriving in that gap were dropped AND counted as delivered, so the resend
  // that followed looked stale and was discarded too. The UI then sat on
  // defaults until something unrelated happened to push state again.
  if (!set || set.size === 0) return

  if (msg.k !== 'snapshot') seq.commit(msg.s)
  for (const fn of set) {
    try {
      fn(msg.d)
    } catch (err) {
      // One bad handler must not stop the others, and must not kill the
      // listener -- a thrown error here would silently freeze the whole UI.
      reportError(`handler for "${msg.k}"`, err)
    }
  }
}

/**
 * Refusal reasons already reported, so a hostile page cannot flood the log.
 *
 * Four possible values, so this Set is bounded by the type, not by a counter.
 */
const refusalsSeen = new Set<Refusal>()

/**
 * THE ONLY DOOR INTO THE DISPATCHER FROM THE PAGE (#281).
 *
 * `bridge/envelope.ts` holds the decision and the reasoning. What lives here is
 * the reporting, and it is not decoration: if this guard is ever wrong about a
 * real FiveM build the symptom is a dead interface over a healthy game, with
 * nothing in the console -- the exact failure reportError() was written for. One
 * line per reason, to F8 and through the error sink to the server log, is the
 * difference between a five-minute answer and an evening.
 *
 * ONLY ENVELOPE-SHAPED REFUSALS ARE REPORTED. A NUI page hears every
 * postMessage on the window, including ordinary chatter from the Ringmaster
 * console frame that Admin.tsx's own listener consumes. Logging those would
 * bury the one line that matters under traffic that is working exactly as
 * designed.
 */
window.addEventListener('message', (ev: MessageEvent) => {
  const verdict = admit(window, ev.source, ev.data)

  if (!verdict.ok) {
    const looksLikeOurs =
      ev.data !== null
      && typeof ev.data === 'object'
      && (ev.data as { t?: unknown }).t === 'br'

    if (looksLikeOurs && !refusalsSeen.has(verdict.why)) {
      refusalsSeen.add(verdict.why)
      reportError(
        'nui message refused',
        new Error(
          `${verdict.why} -- an envelope-shaped message was turned away. If the`
          + ' interface is not updating, this is why; see bridge/envelope.ts.',
        ),
      )
    }
    return
  }

  dispatch(verdict.env)
})

/**
 * Call a Lua callback and await its reply.
 *
 * Every RegisterNUICallback on the Lua side must call its resolve function on
 * every path, including errors. A missing resolve leaves this promise pending
 * forever, which presents as a UI control that simply stops working with nothing
 * in the console -- the classic silent NUI freeze. The timeout below converts
 * that into a visible error instead of an infinite hang.
 */
export async function fetchNui<Req = unknown, Res = unknown>(
  name: CallbackName,
  data?: Req,
  timeoutMs = 5000,
): Promise<Res | null> {
  // import.meta.env.DEV is replaced with a literal false in a production build,
  // so this whole branch -- and the mock module with it -- is eliminated rather
  // than shipped as a separate chunk. Dynamic imports under the nui:// scheme
  // fail silently, so the production bundle must not contain any.
  if (import.meta.env.DEV && isBrowser) {
    const { mockFetch } = await import('./mock')
    return mockFetch<Res>(name, data)
  }

  const controller = new AbortController()
  const timer = window.setTimeout(() => controller.abort(), timeoutMs)

  try {
    const res = await fetch(`https://${resourceName()}/${name}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(data ?? {}),
      signal: controller.signal,
    })
    if (!res.ok) {
      reportError(`callback ${name}`, new Error(`HTTP ${res.status}`))
      return null
    }
    return (await res.json()) as Res
  } catch (err) {
    // AbortError here means Lua never resolved the callback.
    reportError(`callback ${name}`, err)
    return null
  } finally {
    window.clearTimeout(timer)
  }
}

/**
 * Push an error back to Lua so it lands in the F8 console and the server log.
 *
 * Without this a CEF exception is invisible: the page just goes blank and there
 * is nowhere to look. This is the single highest-value thing in the bridge.
 */
export function reportError(context: string, err: unknown): void {
  const message = err instanceof Error ? err.message : String(err)
  const stack = err instanceof Error ? err.stack ?? '' : ''
  // eslint-disable-next-line no-console
  console.error(`[br_ui] ${context}:`, err)

  if (isBrowser) return
  // Deliberately raw fetch, not fetchNui -- if the error sink itself failed we
  // would recurse forever.
  void fetch(`https://${resourceName()}/br/err`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify({ context, message, stack: stack.slice(0, 1200) }),
  }).catch(() => { /* nothing left to do */ })
}

/**
 * Report what this browser can actually do, to the F8 console.
 *
 * FiveM's CEF is an embedded Chromium that lags mainstream Chrome, sometimes by
 * a lot. That matters more than it sounds: Tailwind v4 and HeroUI v3 emit
 * oklch(), oklab(), lch() and color-mix() throughout their colour system, and
 * all of those are Chrome 111+. On an older CEF every one of those declarations
 * fails to parse, so components render with no colour at all -- which looks like
 * "the CSS didn't load" rather than "this browser is too old".
 *
 * Guessing at that costs hours. Measuring it costs one function.
 */
export function reportEnvironment(): void {
  const supports = (prop: string, value: string) => {
    try { return CSS.supports(prop, value) } catch { return false }
  }

  const chromeMatch = /Chrom(?:e|ium)\/(\d+)/.exec(navigator.userAgent)
  const chromeVersion = chromeMatch?.[1] ? parseInt(chromeMatch[1], 10) : 0

  const env = {
    // Which bundle is actually running. Without this, "the fix did not work"
    // and "the fix never reached the client" look identical from the console.
    build: typeof __BUILD_STAMP__ !== 'undefined' ? __BUILD_STAMP__ : 'unknown',
    userAgent: navigator.userAgent,
    chromeVersion,
    css: {
      oklch:          supports('color', 'oklch(70% 0.1 200)'),
      oklab:          supports('color', 'oklab(70% 0.1 0.1)'),
      lch:            supports('color', 'lch(70% 40 200)'),
      colorMix:       supports('color', 'color-mix(in oklch, red, blue)'),
      colorMixSrgb:   supports('color', 'color-mix(in srgb, red, blue)'),
      atProperty:     typeof CSS !== 'undefined' && 'registerProperty' in CSS,
      has:            supports('selector', ':has(a)'),
      nesting:        supports('selector', '&'),
      containerType:  supports('container-type', 'inline-size'),
      backdropFilter: supports('backdrop-filter', 'blur(2px)'),
    },
    viewport: { w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio },

    // Whether this page is actually see-through.
    //
    // Reported because a black screen over a healthy game is otherwise
    // undiagnosable from in-game: every native check says the world is fine,
    // because it is -- the page is simply painted over it.
    //
    // colorScheme matters as much as the backgrounds. `dark` makes the browser
    // paint the CANVAS opaque, which is not any element's background-color, so
    // the two below can read fully transparent while the screen stays black.
    overlay: (() => {
      const html = getComputedStyle(document.documentElement)
      const body = getComputedStyle(document.body)
      const clear = (c: string) => c === 'rgba(0, 0, 0, 0)' || c === 'transparent'
      return {
        colorScheme: html.colorScheme,
        htmlBg: html.backgroundColor,
        bodyBg: body.backgroundColor,
        transparent:
          html.colorScheme !== 'dark' &&
          clear(html.backgroundColor) &&
          clear(body.backgroundColor),
      }
    })(),
  }

  // eslint-disable-next-line no-console
  console.info('[br_ui] environment', env)

  if (isBrowser) return
  void fetch(`https://${resourceName()}/br/ui/env`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json; charset=UTF-8' },
    body: JSON.stringify(env),
  }).catch(() => { /* the console line above is still useful */ })
}

/** Install global error sinks. Called once from main.tsx. */
export function installErrorSinks(): void {
  window.addEventListener('error', (ev) => {
    reportError('window.onerror', ev.error ?? ev.message)
  })
  window.addEventListener('unhandledrejection', (ev) => {
    reportError('unhandledrejection', ev.reason)
  })
}
