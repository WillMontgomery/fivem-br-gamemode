/**
 * THE APP'S ONLY DOOR: postMessage with the desktop around it.
 *
 * The app lives in the iframe of cuchi_computer's terminal window. It never
 * calls a NUI callback and never learns the resource name: the desktop
 * (cuchi_computer/nui/br.js) relays both ways, and client/shell.lua relays to
 * br_core, which asks the server. docs/terminals.md is the whole contract.
 *
 *   app -> desktop   { brTerminal: 1, type: 'ready' }
 *                    { brTerminal: 1, type: 'run', functionId, options?, at? }
 *                      at: the spot picked on the big map, for a function
 *                      run at one (round 4)
 *                    { brTerminal: 1, type: 'pick', functionId }
 *                      "Set location": the desktop hides, the big map opens,
 *                      and a `picked` comes back when it closes
 *                    { brTerminal: 1, type: 'escape' }
 *                    { brTerminal: 1, type: 'loading', on: true, ms }
 *                    { brTerminal: 1, type: 'loading', on: false }
 *                      a page load under way for `ms`, or over: the
 *                      window's tab, which is the desktop's, shows a loading
 *                      symbol while one is (owner, 2026-10-06; model.ts says
 *                      what a load is)
 *   desktop -> app   { brTerminal: 1, type: 'state', state, copy?, catalog? }
 *                    { brTerminal: 1, type: 'result', result }
 *                    { brTerminal: 1, type: 'picked', picked }
 *                      what the map pick found: { functionId, at, place }
 *
 * The light/dark mode is the app's alone since round 2 (owner, 2026-10-05:
 * "dark/light mode should not influence the browser's appearance, only the
 * website"), so the desktop is no longer told it.
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

/**
 * A standing teammate an option can name (round 5: Gear Up's "given to a
 * teammate"): the server id it is chosen by, as a string, and the name the
 * squad panel shows. Only in a squad match; never the player.
 */
export interface Mate {
  id: string
  name: string
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

/** The run this player has loading, as the server times it. */
export interface RunningInfo {
  functionId: string
  runMs: number
  leftMs: number
}

/** What br_core opens the computer with, and pushes again once a second. */
export interface TerminalState {
  terminalId: string
  functions: FunctionState[]
  keyHeld: boolean
  squadUsed: boolean
  /**
   * Is the player actively in a squad match? Every line that says squad is
   * picked by it (model.ts `speaker`), and the squad-only functions shown.
   */
  squadMatch: boolean
  /** The player's Volts, as every other Volts display shows them; null when not sent. */
  volts: number | null
  /** A run of theirs that is loading, or null. */
  running: RunningInfo | null
  /** The player's gamertag, the app's signed-in username. */
  player: string | null
  match: MatchInfo | null
  /**
   * The standing teammates an option with `source: 'mates'` offers (round 5),
   * live with every push; empty outside a squad match.
   */
  mates: Mate[]
}

/**
 * One option a function takes: its id, its choices, and the default -- and,
 * for one offered only under another option's choice (round 4: Time &
 * weather's time OR weather), `when`: { otherOptionId: choice }. Round 5:
 * `source` 'mates' for one whose choices are the state's standing teammates
 * (no choices or default of its own), and `dropdown` to draw it as a
 * dropdown rather than radio buttons.
 */
export interface OptionDef {
  id: string
  choices: string[]
  default: string
  when: Record<string, string> | null
  source: 'mates' | null
  dropdown: boolean
  /**
   * Each choice's loot rarity, 1 (common) to 5 (legendary), for an option
   * whose choices are items (round 6: Gear Up's item list, "add it's rarity
   * with the colored font. Sorted by most rare at the top"), or null. The
   * registry fills it from each item's own `rarity` (br_lib/config/
   * terminals.lua, the gearUp block).
   */
  rarity: Record<string, number> | null
}

/**
 * One loot rarity as the game draws it (BR.RarityInfo, br_lib/shared/
 * enums.lua -- the one source every rarity color in the game is read from):
 * its tier (1 common .. 5 legendary), its key (whose `rarity_<key>` copy line
 * is its name) and its color.
 */
export interface Rarity {
  tier: number
  key: string
  hex: string
}

/**
 * A price by choice (round 5: Gear Up's "for a charge of 200 volts the whole
 * team can get them"): the option it depends on, and the Volts each listed
 * choice costs; any other choice costs the row's `cost`.
 */
export interface CostBy {
  option: string
  choices: Record<string, number>
}

/** One registry row (br_lib/config/terminals.lua). */
export interface FunctionDef {
  id: string
  category: string
  risk: 'low' | 'medium' | 'high'
  implemented: boolean
  options: OptionDef[]
  /** Volts a run costs; 0 is free. */
  cost: number
  /** A price that depends on an option's choice (round 5), or null. */
  costBy: CostBy | null
  /** Only listed in a squad match. */
  squadOnly: boolean
  /** The category it is listed under outside a squad match, or null. */
  soloCategory: string | null
  /**
   * Who a run puts a bounty on, as its card says (round 4): the runner
   * (Scan), another player (Contract), or nobody.
   */
  bounty: 'runner' | 'target' | null
  /** Its effect reaches the runner's whole squad: "Squads!" in a squad match (round 4). */
  squadWide: boolean
  /**
   * Run at a spot picked on the big map (round 4: Storm control, Supply
   * drop): its confirm box has a "Set location" step, and Run waits for it.
   * True for a row that ever is -- always, or only under `spotWhen`.
   */
  spot: boolean
  /**
   * Round 6: run at a spot ONLY while the options carry these choices
   * ({ optionId: choice }; Power outage's area 'spot'), or null for a row run
   * at one every time. The registry's `spot = { when = { ... } }`; model.ts
   * `needsSpot` and the server's BR.TerminalSolve.spotWanted read it alike.
   */
  spotWhen: Record<string, string> | null
  /**
   * The lobby is not told when it runs (round 4, owner 2026-10-06: "Field
   * medic should not notify everyone"), so its page leaves out risk_notice.
   */
  quiet: boolean
}

/** A spot on the map, in world meters. */
export interface Spot {
  x: number
  y: number
}

/**
 * What the map pick found (round 4): the function it was for, the spot or
 * none (no waypoint set when the map closed), and the game's own name for
 * the place -- its street and area -- which is no line of ours.
 */
export interface PickResult {
  functionId: string
  at: Spot | null
  place: string
}

/** The registry as the app reads it. */
export interface Catalog {
  functions: FunctionDef[]
  categories: string[]
  /** The currency's name (config/market.lua), written after a Volts figure. */
  currency: string
  /**
   * How long the browser takes to load a page (pageMinMs..pageMaxMs in
   * br_lib/config/terminals.lua, owner 2026-10-06), or null when not sent.
   */
  pageLoad: { minMs: number; maxMs: number } | null
  /** The loot rarities, rarest last, as the game colors them (round 6); empty when not sent. */
  rarities: Rarity[]
}

/**
 * What the desktop's tab is told: a page load of `ms` started (or replaced
 * the one under way), or the load is over; null is nothing to tell.
 */
export type TabNote = { on: true; ms: number } | { on: false } | null

/** The longest page load the app accepts from a catalog. */
const PAGE_LOAD_MAX_MS = 10000

/**
 * The server's answer to a run. `code` names the copy line to show:
 * 'running' (accepted, loading for runMs), 'done', or why not. `cost` and
 * `balance` come with no_volts; `balance` with a paid run's done.
 */
export interface RunResult {
  functionId: string
  ok: boolean
  code: string | null
  runMs: number | null
  cost: number | null
  balance: number | null
}

/** Every player-facing line, keyed; from br_lib/config/terminals.lua. */
export type Copy = Readonly<Record<string, string>>

const ID = /^[a-z][a-z0-9_]{0,31}$/
const CHOICE = /^[a-z0-9_]{1,32}$/
/** The longest teammate name taken from the state. */
const NAME_MAX = 64
/** The most Volts a price may be (owner, round 2: "no more than 200"). */
const COST_MAX = 200

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
  let running: RunningInfo | null = null
  if (isObj(v.running)) {
    const fid = code(v.running.functionId)
    const runMs = num(v.running.runMs)
    const leftMs = num(v.running.leftMs)
    if (fid !== null && runMs !== null && runMs > 0 && leftMs !== null) {
      running = { functionId: fid, runMs, leftMs: Math.max(0, Math.min(runMs, leftMs)) }
    }
  }
  return {
    terminalId: v.terminalId,
    functions,
    keyHeld: v.keyHeld === true,
    squadUsed: v.squadUsed === true,
    squadMatch: v.squadMatch === true,
    volts: num(v.volts),
    running,
    player: str(v.player),
    match: parseMatch(v.match),
    mates: parseMates(v.mates),
  }
}

/** The standing teammates: each a well-formed choice and a name; anything else dropped. */
function parseMates(v: unknown): Mate[] {
  const out: Mate[] = []
  for (const m of list(v)) {
    if (!isObj(m) || typeof m.id !== 'string' || !CHOICE.test(m.id) || typeof m.name !== 'string') continue
    out.push({ id: m.id, name: m.name.slice(0, NAME_MAX) })
  }
  return out
}

/** A price by choice, or null when it is not one: an option id and figures 0..200. */
function parseCostBy(v: unknown): CostBy | null {
  if (!isObj(v) || typeof v.option !== 'string' || !ID.test(v.option) || !isObj(v.choices)) return null
  const choices: Record<string, number> = {}
  let n = 0
  for (const [k, c] of Object.entries(v.choices)) {
    const figure = num(c)
    if (!CHOICE.test(k) || figure === null || figure < 0 || figure > COST_MAX) return null
    choices[k] = Math.floor(figure)
    n++
  }
  return n > 0 ? { option: v.option, choices } : null
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
      if (oid === null) continue
      const dropdown = o.dropdown === true
      if (o.source === 'mates') {
        // ROUND 5: ITS CHOICES ARE THE STATE'S STANDING TEAMMATES, no list here.
        options.push({
          id: oid, choices: [], default: '', when: parseWhen(o.when), source: 'mates', dropdown, rarity: null,
        })
        continue
      }
      const choices = list(o.choices).filter((c): c is string => typeof c === 'string' && CHOICE.test(c))
      if (choices.length === 0) continue
      const def = typeof o.default === 'string' && choices.includes(o.default) ? o.default : (choices[0] ?? '')
      options.push({
        id: oid, choices, default: def, when: parseWhen(o.when), source: null, dropdown,
        rarity: parseTiers(o.rarity, choices),
      })
    }
    const cost = num(f.cost)
    // A SPOT ALWAYS (`spot = true`), OR ONLY UNDER A CHOICE (round 6: `spot = {
    // when = { ... } }`). A `when` that is not one is no spot at all, as the
    // server's BR.TerminalSolve.spotRule reads it.
    const spotWhen = isObj(f.spot) ? parseWhen(f.spot.when) : null
    functions.push({
      id, category, risk, implemented: f.implemented === true, options,
      cost: cost !== null && cost > 0 ? Math.floor(cost) : 0,
      costBy: parseCostBy(f.costBy),
      squadOnly: f.squadOnly === true,
      soloCategory: code(f.soloCategory),
      bounty: f.bounty === 'runner' || f.bounty === 'target' ? f.bounty : null,
      squadWide: f.squadWide === true,
      spot: f.spot === true || spotWhen !== null,
      spotWhen,
      quiet: f.quiet === true,
    })
  }
  const categories = list(v.categories).filter((c): c is string => typeof c === 'string' && ID.test(c))
  return {
    functions, categories, currency: typeof v.currency === 'string' ? v.currency : '',
    pageLoad: parsePageLoad(v.pageLoad),
    rarities: parseRarities(v.rarities),
  }
}

/** The highest loot tier (BR.Rarity.LEGENDARY). */
const TIER_MAX = 5
/** A rarity's color: #rrggbb, nothing else (it is drawn as text and a tint). */
const HEX = /^#[0-9a-fA-F]{6}$/

/** A tier: a whole number 1..5, or null. */
function tier(v: unknown): number | null {
  const n = num(v)
  return n !== null && Number.isInteger(n) && n >= 1 && n <= TIER_MAX ? n : null
}

/**
 * Each listed choice's tier, or null when the option carries none. A choice
 * whose tier is not one is left out (drawn with no rarity), never guessed.
 */
function parseTiers(v: unknown, choices: string[]): Record<string, number> | null {
  if (!isObj(v)) return null
  const out: Record<string, number> = {}
  let n = 0
  for (const c of choices) {
    const t = tier(v[c])
    if (t === null) continue
    out[c] = t
    n++
  }
  return n > 0 ? out : null
}

/**
 * The rarities: each a tier, a key and a #rrggbb color, at most one per tier,
 * in tier order. Lua sends BR.RarityInfo's rows as a list.
 */
function parseRarities(v: unknown): Rarity[] {
  const out: Rarity[] = []
  for (const r of list(v)) {
    if (!isObj(r)) continue
    const t = tier(r.tier)
    if (t === null || typeof r.key !== 'string' || !ID.test(r.key) || typeof r.hex !== 'string' || !HEX.test(r.hex)) continue
    if (out.some((x) => x.tier === t)) continue
    out.push({ tier: t, key: r.key, hex: r.hex })
  }
  return out.sort((a, b) => a.tier - b.tier)
}

/**
 * An option's `when`, or null: { optionId: choice }, each a well-formed id
 * and choice. One that is not one is null -- the option offered always -- since
 * the server, which drops an option whose `when` does not hold, is the one
 * that decides what a run carries.
 */
function parseWhen(v: unknown): Record<string, string> | null {
  if (!isObj(v)) return null
  const out: Record<string, string> = {}
  let n = 0
  for (const [k, c] of Object.entries(v)) {
    if (!ID.test(k) || typeof c !== 'string' || !CHOICE.test(c)) return null
    out[k] = c
    n++
  }
  return n > 0 ? out : null
}

/** The page-load range, or null when it is not one: 0 <= min <= max <= 10 s. */
function parsePageLoad(v: unknown): { minMs: number; maxMs: number } | null {
  if (!isObj(v)) return null
  const lo = num(v.minMs)
  const hi = num(v.maxMs)
  if (lo === null || hi === null || lo < 0 || hi < lo || hi > PAGE_LOAD_MAX_MS) return null
  return { minMs: lo, maxMs: hi }
}

export function parseResult(v: unknown): RunResult | null {
  if (!isObj(v)) return null
  const functionId = code(v.functionId)
  if (functionId === null) return null
  return {
    functionId, ok: v.ok === true, code: code(v.code),
    runMs: num(v.runMs), cost: num(v.cost), balance: num(v.balance),
  }
}

/** The longest place name taken from the desktop. */
const PLACE_MAX = 120
/** How far from the map's middle a spot may be, on either axis (shape only). */
const SPOT_MAX = 100000

/** A spot: two finite numbers within SPOT_MAX, or null. */
function parseSpot(v: unknown): Spot | null {
  if (!isObj(v)) return null
  const x = num(v.x)
  const y = num(v.y)
  if (x === null || y === null || Math.abs(x) > SPOT_MAX || Math.abs(y) > SPOT_MAX) return null
  return { x, y }
}

export function parsePicked(v: unknown): PickResult | null {
  if (!isObj(v)) return null
  const functionId = code(v.functionId)
  if (functionId === null) return null
  const at = parseSpot(v.at)
  return { functionId, at, place: at && typeof v.place === 'string' ? v.place.slice(0, PLACE_MAX) : '' }
}

function post(msg: Record<string, unknown>): void {
  window.parent.postMessage({ brTerminal: 1, ...msg }, '*')
}

/**
 * Ask to run a function with the player's choices -- and, for one run at a
 * spot, the spot picked (round 4). The server answers.
 */
export function run(functionId: string, options: Record<string, string>, at?: Spot | null): void {
  if (!ID.test(functionId)) return
  const clean: Record<string, string> = {}
  for (const [k, v] of Object.entries(options)) {
    if (ID.test(k) && CHOICE.test(v)) clean[k] = v
  }
  const msg: Record<string, unknown> = { type: 'run', functionId }
  if (Object.keys(clean).length > 0) msg.options = clean
  const spot = at ? parseSpot(at) : null
  if (spot) msg.at = spot
  post(msg)
}

/**
 * "Set location" (round 4): ask for a spot on the big map for this function.
 * The desktop is hidden while the map is up; the answer is a `picked`.
 */
export function pick(functionId: string): void {
  if (!ID.test(functionId)) return
  post({ type: 'pick', functionId })
}

/** Ask the desktop for everything again: the toolbar's reload. */
export function reload(): void {
  post({ type: 'ready' })
}

/** Close the computer: Escape, or Sign out. */
export function signOut(): void {
  post({ type: 'escape' })
}

/** Tell the desktop's tab a page load started, or is over. */
export function tellTab(note: TabNote): void {
  if (note === null) return
  post(note.on ? { type: 'loading', on: true, ms: Math.round(note.ms) } : { type: 'loading', on: false })
}

export interface Listeners {
  state(state: TerminalState, copy: Copy | null, catalog: Catalog | null): void
  result(result: RunResult): void
  /** What a map pick found (round 4), as the desktop comes back. */
  picked(picked: PickResult): void
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
    } else if (d.type === 'picked') {
      const picked = parsePicked(d.picked)
      if (picked) on.picked(picked)
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
