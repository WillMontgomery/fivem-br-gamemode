/**
 * NUI transport.
 *
 * Two directions, both narrow on purpose:
 *   Lua  -> UI : a single window 'message' listener, dispatching by envelope kind
 *   UI   -> Lua: fetchNui(), a POST to https://<resource>/<callback>
 */

import type { CallbackName, EnvelopeKind, WireEnvelope } from './types'
import { ENVELOPE_VERSION } from './types'

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

/** Highest sequence number seen, so late-arriving stale messages are dropped. */
let lastSeq = -1

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
    lastSeq = msg.s ?? 0
  } else if (typeof msg.s === 'number') {
    if (msg.s <= lastSeq) return
    lastSeq = msg.s
  }

  const set = handlers.get(msg.k)
  if (!set) return
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

window.addEventListener('message', (ev: MessageEvent) => {
  dispatch(ev.data as WireEnvelope)
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

/** Install global error sinks. Called once from main.tsx. */
export function installErrorSinks(): void {
  window.addEventListener('error', (ev) => {
    reportError('window.onerror', ev.error ?? ev.message)
  })
  window.addEventListener('unhandledrejection', (ev) => {
    reportError('unhandledrejection', ev.reason)
  })
}
