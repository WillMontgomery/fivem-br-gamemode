/**
 * THE APP'S ONLY DOOR: postMessage with the desktop around it.
 *
 * The app lives in the iframe of cuchi_computer's terminal window. It never
 * calls a NUI callback and never learns the resource name: the desktop
 * (cuchi_computer/nui/br.js) relays both ways, and client/shell.lua relays to
 * br_core, which asks the server. docs/terminals.md is the whole contract.
 *
 *   app -> desktop   { brTerminal: 1, type: 'ready' }
 *                    { brTerminal: 1, type: 'run', functionId }
 *                    { brTerminal: 1, type: 'escape' }
 *   desktop -> app   { brTerminal: 1, type: 'state', state, copy }
 *                    { brTerminal: 1, type: 'result', result }
 *
 * EVERYTHING ARRIVING IS CHECKED FOR SHAPE, because it is rendered: a field of
 * the wrong type is dropped rather than shown, and a message from anywhere but
 * the parent window is ignored. Nothing here is a permission -- the server
 * decides every run.
 */

/** One row of the terminal's function list, as the server sees it. */
export interface FunctionState {
  id: string
  available: boolean
  /** Why not, as a code ('no_key', 'squad_used', 'offline', ...); null when available. */
  reason: string | null
}

/** What br_core opens the computer with, and sends again when it changes. */
export interface TerminalState {
  terminalId: string
  functions: FunctionState[]
  keyHeld: boolean
  squadUsed: boolean
}

/** The server's answer to a run. `code` names the copy line to show. */
export interface RunResult {
  functionId: string
  ok: boolean
  code: string | null
}

/** Every player-facing line, keyed; from br_lib/config/terminals.lua. */
export type Copy = Readonly<Record<string, string>>

const ID = /^[a-z][a-z0-9_]{0,31}$/

const isObj = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

const code = (v: unknown): string | null =>
  typeof v === 'string' && ID.test(v) ? v : null

/** Lua sends an empty table for an empty list, which JSON makes `{}`. */
const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : [])

export function parseState(v: unknown): TerminalState | null {
  if (!isObj(v) || typeof v.terminalId !== 'string') return null
  const functions: FunctionState[] = []
  for (const f of list(v.functions)) {
    if (!isObj(f)) continue
    const id = code(f.id)
    if (id === null) continue
    const available = f.available === true
    functions.push({ id, available, reason: available ? null : code(f.reason) })
  }
  return {
    terminalId: v.terminalId,
    functions,
    keyHeld: v.keyHeld === true,
    squadUsed: v.squadUsed === true,
  }
}

export function parseCopy(v: unknown): Copy {
  const out: Record<string, string> = {}
  if (!isObj(v)) return out
  for (const [k, s] of Object.entries(v)) {
    if (typeof s === 'string') out[k] = s
  }
  return out
}

export function parseResult(v: unknown): RunResult | null {
  if (!isObj(v)) return null
  const functionId = code(v.functionId)
  if (functionId === null) return null
  return { functionId, ok: v.ok === true, code: code(v.code) }
}

function post(msg: Record<string, unknown>): void {
  window.parent.postMessage({ brTerminal: 1, ...msg }, '*')
}

/** Ask to run a function. The server answers with a result, or nothing. */
export function run(functionId: string): void {
  if (ID.test(functionId)) post({ type: 'run', functionId })
}

export interface Listeners {
  state(state: TerminalState, copy: Copy): void
  result(result: RunResult): void
}

/**
 * Listen to the desktop, and tell it this app is ready for its state.
 * Also forwards Escape: a keydown inside this frame never reaches the
 * desktop's document, and Escape is how the player leaves the computer.
 * Returns the unsubscribe.
 */
export function connect(on: Listeners): () => void {
  const onMessage = (e: MessageEvent) => {
    if (e.source !== window.parent || e.source === window) return
    const d: unknown = e.data
    if (!isObj(d) || d.brTerminal !== 1) return
    if (d.type === 'state') {
      const state = parseState(d.state)
      if (state) on.state(state, parseCopy(d.copy))
    } else if (d.type === 'result') {
      const result = parseResult(d.result)
      if (result) on.result(result)
    }
  }
  const onKey = (e: KeyboardEvent) => {
    if (e.key === 'Escape') {
      e.preventDefault()
      post({ type: 'escape' })
    }
  }
  window.addEventListener('message', onMessage)
  window.addEventListener('keydown', onKey)
  post({ type: 'ready' })
  return () => {
    window.removeEventListener('message', onMessage)
    window.removeEventListener('keydown', onKey)
  }
}
