/**
 * THE APP'S ONLY DOOR: postMessage with the desktop around it.
 *
 * The app lives in the iframe of cuchi_computer's terminal window. It never
 * calls a NUI callback and never learns the resource name: the desktop
 * (cuchi_computer/nui/br.js) relays both ways, and client/shell.lua relays to
 * br_core, which asks the server. docs/terminals.md is the whole contract.
 *
 *   app -> desktop   { brTerminal: 1, type: 'ready' }
 *                    { brTerminal: 1, type: 'run', functionId, options? }
 *                    { brTerminal: 1, type: 'escape' }
 *                    { brTerminal: 1, type: 'mode', mode }
 *   desktop -> app   { brTerminal: 1, type: 'state', state, copy?, catalog? }
 *                    { brTerminal: 1, type: 'result', result }
 *
 * The copy and the catalog come with the opening (and again on 'ready'); the
 * once-a-second update is the state alone, and the app keeps what it has.
 *
 * EVERYTHING ARRIVING IS CHECKED FOR SHAPE, because it is rendered: a field of
 * the wrong type is dropped rather than shown, and a message from anywhere but
 * the parent window is ignored. Nothing here is a permission -- the server
 * decides every run and checks every option.
 */

/** One row of the terminal's function list, as the server sees it now. */
export interface FunctionState {
  id: string
  available: boolean
  /** Why not, as a code ('no_key', 'squad_used', 'fn_offline', ...); null when available. */
  reason: string | null
}

/** A squadmate on the match panel. */
export interface MateInfo {
  name: string
  state: 'alive' | 'downed' | 'out'
  me: boolean
}

/** The storm on the match panel. */
export interface StormInfo {
  stage: number | null
  stages: number | null
  state: string | null
  leftMs: number | null
}

/** The match as the server shows it to this player (BR.Terminal.matchInfo). */
export interface MatchInfo {
  tag: string | null
  mode: string | null
  phase: string | null
  elapsedMs: number | null
  storm: StormInfo | null
  players: number | null
  squads: number | null
  squad: MateInfo[]
  terminals: { online: number; total: number } | null
  bounties: { name: string; leftMs: number }[]
}

/** What br_core opens the computer with, and pushes again once a second. */
export interface TerminalState {
  terminalId: string
  functions: FunctionState[]
  keyHeld: boolean
  squadUsed: boolean
  /** The player's gamertag, the app's signed-in username. */
  player: string | null
  match: MatchInfo | null
}

/** One option a function takes: its id, its choices, and the default. */
export interface OptionDef {
  id: string
  choices: string[]
  default: string
}

/** One registry row (br_lib/config/terminals.lua). */
export interface FunctionDef {
  id: string
  category: string
  risk: 'low' | 'medium' | 'high'
  implemented: boolean
  options: OptionDef[]
}

/** The registry as the app reads it. */
export interface Catalog {
  functions: FunctionDef[]
  categories: string[]
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
const CHOICE = /^[a-z0-9_]{1,32}$/

const isObj = (v: unknown): v is Record<string, unknown> =>
  typeof v === 'object' && v !== null && !Array.isArray(v)

const code = (v: unknown): string | null =>
  typeof v === 'string' && ID.test(v) ? v : null

/** Lua sends an empty table for an empty list, which JSON makes `{}`. */
const list = (v: unknown): unknown[] => (Array.isArray(v) ? v : [])

const num = (v: unknown): number | null =>
  typeof v === 'number' && Number.isFinite(v) ? v : null

const str = (v: unknown): string | null => (typeof v === 'string' ? v : null)

function parseMatch(v: unknown): MatchInfo | null {
  if (!isObj(v)) return null
  const storm = isObj(v.storm)
    ? { stage: num(v.storm.stage), stages: num(v.storm.stages), state: str(v.storm.state), leftMs: num(v.storm.leftMs) }
    : null
  const squad: MateInfo[] = []
  for (const m of list(v.squad)) {
    if (!isObj(m) || typeof m.name !== 'string') continue
    const state = m.state === 'downed' || m.state === 'out' ? m.state : 'alive'
    squad.push({ name: m.name, state, me: m.me === true })
  }
  const bounties: { name: string; leftMs: number }[] = []
  for (const b of list(v.bounties)) {
    if (!isObj(b) || typeof b.name !== 'string') continue
    bounties.push({ name: b.name, leftMs: num(b.leftMs) ?? 0 })
  }
  const t = isObj(v.terminals) ? v.terminals : null
  const online = t ? num(t.online) : null
  const total = t ? num(t.total) : null
  return {
    tag: str(v.tag),
    mode: str(v.mode),
    phase: str(v.phase),
    elapsedMs: num(v.elapsedMs),
    storm,
    players: num(v.players),
    squads: num(v.squads),
    squad,
    terminals: online !== null && total !== null ? { online, total } : null,
    bounties,
  }
}

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
    player: str(v.player),
    match: parseMatch(v.match),
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

export function parseCatalog(v: unknown): Catalog | null {
  if (!isObj(v)) return null
  const functions: FunctionDef[] = []
  for (const f of list(v.functions)) {
    if (!isObj(f)) continue
    const id = code(f.id)
    const category = code(f.category)
    if (id === null || category === null) continue
    const risk = f.risk === 'high' || f.risk === 'medium' ? f.risk : 'low'
    const options: OptionDef[] = []
    for (const o of list(f.options)) {
      if (!isObj(o)) continue
      const oid = code(o.id)
      const choices = list(o.choices).filter((c): c is string => typeof c === 'string' && CHOICE.test(c))
      if (oid === null || choices.length === 0) continue
      const def = typeof o.default === 'string' && choices.includes(o.default) ? o.default : (choices[0] ?? '')
      options.push({ id: oid, choices, default: def })
    }
    functions.push({ id, category, risk, implemented: f.implemented === true, options })
  }
  const categories = list(v.categories).filter((c): c is string => typeof c === 'string' && ID.test(c))
  return { functions, categories }
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

/** Ask to run a function with the player's choices. The server answers. */
export function run(functionId: string, options: Record<string, string>): void {
  if (!ID.test(functionId)) return
  const clean: Record<string, string> = {}
  for (const [k, v] of Object.entries(options)) {
    if (ID.test(k) && CHOICE.test(v)) clean[k] = v
  }
  post(Object.keys(clean).length > 0
    ? { type: 'run', functionId, options: clean }
    : { type: 'run', functionId })
}

/** Ask the desktop for everything again: the toolbar's reload. */
export function reload(): void {
  post({ type: 'ready' })
}

/** Close the computer: Escape, or Sign out. */
export function signOut(): void {
  post({ type: 'escape' })
}

/** Tell the desktop the app went light or dark, so the window's tab follows. */
export function tellMode(mode: 'light' | 'dark'): void {
  post({ type: 'mode', mode })
}

export interface Listeners {
  state(state: TerminalState, copy: Copy | null, catalog: Catalog | null): void
  result(result: RunResult): void
  /**
   * Whether Escape should close the computer now. False while the app has a
   * use for it of its own -- a dialog closes first.
   */
  canEscape(): boolean
}

/**
 * Is a dialog, a menu or a dropdown list open on screen? Each closes itself on
 * Escape (the preferences dialog, the user menu, the search's list), so while
 * one is up Escape is its, not the computer's. Hidden ones -- display none, or
 * TopNavigation's off-screen measuring copy -- do not count.
 */
function overlayOpen(): boolean {
  for (const node of document.querySelectorAll('[role="dialog"], [role="menu"], [role="listbox"]')) {
    const el = node as HTMLElement
    if (el.getClientRects().length === 0) continue
    if (window.getComputedStyle(el).visibility === 'hidden') continue
    return true
  }
  return false
}

/**
 * Listen to the desktop, and tell it this app is ready for its state.
 * Also forwards Escape: a keydown inside this frame never reaches the
 * desktop's document, and Escape is how the player leaves the computer --
 * unless a dropdown or a dialog in the app took it first.
 * Returns the unsubscribe.
 */
export function connect(on: Listeners): () => void {
  const onMessage = (e: MessageEvent) => {
    if (e.source !== window.parent || e.source === window) return
    const d: unknown = e.data
    if (!isObj(d) || d.brTerminal !== 1) return
    if (d.type === 'state') {
      const state = parseState(d.state)
      if (state) {
        on.state(state, 'copy' in d ? parseCopy(d.copy) : null,
          'catalog' in d ? parseCatalog(d.catalog) : null)
      }
    } else if (d.type === 'result') {
      const result = parseResult(d.result)
      if (result) on.result(result)
    }
  }
  // IN THE CAPTURE PHASE, so the question is asked before any component has
  // handled the key: a dialog closes itself on Escape in React's own
  // handler, and asked afterwards the app would already say nothing is open.
  const onKey = (e: KeyboardEvent) => {
    if (e.key !== 'Escape') return
    const el = document.activeElement
    if (el && el.getAttribute('aria-expanded') === 'true') return
    if (overlayOpen()) return
    if (!on.canEscape()) return
    e.preventDefault()
    post({ type: 'escape' })
  }
  window.addEventListener('message', onMessage)
  window.addEventListener('keydown', onKey, true)
  post({ type: 'ready' })
  return () => {
    window.removeEventListener('message', onMessage)
    window.removeEventListener('keydown', onKey, true)
  }
}
