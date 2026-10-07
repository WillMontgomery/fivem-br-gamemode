/**
 * THE APP'S PURE PARTS: copy lookups, the pages and their addresses, what a
 * card says about a function, and the panel's clocks. No React, no DOM.
 *
 * ═══ EVERY WORD IS THE COPY BLOCK'S ═══
 *
 * The owner writes or approves every player-facing line (#396), so the app
 * says nothing of its own: `speaker` looks a key up in the copy br_core sends
 * (br_lib/config/terminals.lua), and a key with no line is nothing -- never
 * the key, never a default. scripts/check-terminal.mjs holds the JSX to it.
 * The only characters this file makes are digits, colons and separators.
 *
 * ═══ "SQUAD" ONLY IN A SQUAD MATCH (owner, 2026-10-05, round 2) ═══
 *
 * A line that says squad has a `<key>_solo` sibling that does not, and
 * `speaker` -- THE APP'S ONE PICKER, the server's BR.TerminalSolve.pick on
 * this side -- reads the sibling whenever the server says the player is not
 * in a squad match. Every word the app shows goes through a speaker;
 * scripts/check-terminal.mjs fails a component that reads the copy another way.
 */

import type { Catalog, Copy, FunctionDef, FunctionState, OptionDef, RunningInfo, TabNote } from './bridge'

/** Every word the app says: a key in, the line (or nothing) out. */
export type Say = (key: string | null | undefined) => string

/**
 * The app's one way to read the copy: the line, or -- outside a squad match
 * -- its `_solo` sibling when it has one (an empty sibling is nothing, which
 * hides the row it labels).
 */
export function speaker(copy: Copy, squadMatch: boolean): Say {
  return (key) => {
    if (!key) return ''
    if (!squadMatch) {
      const solo = copy[`${key}_solo`]
      if (typeof solo === 'string') return solo
    }
    const v = copy[key]
    return typeof v === 'string' ? v : ''
  }
}

/**
 * A Volts figure as every other Volts display writes it: grouped, then the
 * currency's name (config/market.lua's, handed over in the catalog) --
 * "1,250 Volts", BR.ShopSolve.priceLine's shape.
 */
export function voltsText(n: number, currency: string): string {
  const figure = Math.floor(n).toLocaleString('en-US')
  return currency ? `${figure} ${currency}` : figure
}

/**
 * The place a map pick found, as its confirm box shows it (round 4): the
 * game's own name for it -- its street and area, no line of ours -- or, where
 * the game has none, its map coordinates, whole meters, in digits.
 */
export function placeText(at: { x: number; y: number }, place: string): string {
  if (place.trim() !== '') return place
  return `${Math.round(at.x)}, ${Math.round(at.y)}`
}

/** A line with its `{token}`s filled. An unknown token is left as written. */
export function fill(text: string, vars: Record<string, string | number>): string {
  return text.replace(/\{(\w+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m))
}

/**
 * EVERY MENTION OF VOLTS IN THE VOLTS STYLE (owner, 2026-10-06, round 4: "Any
 * mention of volts must use our proper font for that and the gold color").
 *
 * A line cut into its pieces, each saying whether it is Volts: a `{token}`
 * named in `amounts` -- {volts}, {cost}, {balance} -- becomes that figure and
 * the currency's word ("1,250 Volts"), and the currency's word wherever the
 * line itself writes it ("You don't have enough Volts.") is a Volts piece
 * too. Any other token is left as written (fill it first). Volts.tsx draws
 * the Volts pieces in the game's display face and gold; scripts/
 * check-terminal.mjs T12 fails a Volts amount drawn any other way.
 */
export interface Piece {
  text: string
  volts: boolean
}

export function voltsParts(text: string, currency: string, amounts: Record<string, number> = {}): Piece[] {
  const out: Piece[] = []
  const plain = (t: string) => {
    if (t === '') return
    if (currency === '') {
      out.push({ text: t, volts: false })
      return
    }
    const word = new RegExp(`\\b${currency.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}\\b`, 'g')
    let at = 0
    for (const m of t.matchAll(word)) {
      const i = m.index ?? 0
      if (i > at) out.push({ text: t.slice(at, i), volts: false })
      out.push({ text: m[0], volts: true })
      at = i + m[0].length
    }
    if (at < t.length) out.push({ text: t.slice(at), volts: false })
  }
  let at = 0
  for (const m of text.matchAll(/\{(\w+)\}/g)) {
    const k = m[1] ?? ''
    if (!(k in amounts)) continue
    const i = m.index ?? 0
    plain(text.slice(at, i))
    out.push({ text: voltsText(amounts[k] ?? 0, currency), volts: true })
    at = i + m[0].length
  }
  plain(text.slice(at))
  return out
}

/** A line that is a list: one entry per '\n'-separated piece. */
export function lines(text: string): string[] {
  return text.split('\n').map((s) => s.trim()).filter((s) => s !== '')
}

// ------------------------------------------------------------------ pages ---

/**
 * Where the app is. Every page has an address and a breadcrumb trail.
 *
 * HOME (owner, 2026-10-06: "the functions page should be called Home in the
 * URL, sidebar, and breadcrumbs"): the cards page, `functions` here, is Home
 * at /home, in the side navigation and at the head of every trail it starts;
 * its heading, Tools, counts them. A tool's own page is under /tools (round
 * 5). PRIVACY (the same day): the made-up policy, in the side navigation
 * after How to.
 */
export type Route =
  | { page: 'functions'; category: string | null; query: string; filters?: CardFilters }
  | { page: 'function'; id: string }
  | { page: 'howto' }
  | { page: 'privacy' }
  | { page: 'login' }

export const HOME: Route = { page: 'functions', category: null, query: '' }

export function sameRoute(a: Route, b: Route): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}

/**
 * The fictional address the browser's address bar shows for a page, e.g.
 * https://controltower.blitz/home, or .../tools/storm-reveal (round 5: 'Rename
 * the "Functions" to "Tools"'). The host and each section's segment are copy;
 * a tool's segment is its id, hyphenated as a URL is.
 */
export function addressOf(route: Route, say: Say): string {
  const host = say('address_host')
  switch (route.page) {
    case 'functions': {
      const params: string[] = []
      if (route.category) params.push(`category=${route.category}`)
      const f = filtersOf(route)
      for (const k of FILTER_KEYS) {
        const v = f[k]
        if (v !== null) params.push(`${k}=${v}`)
      }
      if (route.query) params.push(`q=${encodeURIComponent(route.query)}`)
      return `${host}/${say('path_home')}${params.length > 0 ? '?' + params.join('&') : ''}`
    }
    case 'function':
      return `${host}/${say('path_tools')}/${route.id.replace(/_/g, '-')}`
    case 'howto':
      return `${host}/${say('path_howto')}`
    case 'privacy':
      return `${host}/${say('path_privacy')}`
    case 'login':
      return `${host}/${say('path_login')}`
  }
}

/**
 * The in-app href a link carries. Never followed -- every link's onFollow
 * prevents it and navigates the app instead -- but a hash, so even a link
 * that slipped through only changes the fragment of this one document.
 */
export function hrefOf(route: Route): string {
  switch (route.page) {
    case 'functions':
      return route.category ? `#cat:${route.category}` : '#home'
    case 'function':
      return `#fn:${route.id}`
    case 'howto':
      return '#howto'
    case 'privacy':
      return '#privacy'
    case 'login':
      return '#login'
  }
}

/** The page an in-app href names, or null for one this app never made. */
export function routeOfHref(href: string): Route | null {
  if (href === '#home') return HOME
  if (href === '#howto') return { page: 'howto' }
  if (href === '#privacy') return { page: 'privacy' }
  if (href === '#login') return { page: 'login' }
  const cat = /^#cat:([a-z][a-z0-9_]{0,31})$/.exec(href)?.[1]
  if (cat) return { page: 'functions', category: cat, query: '' }
  const fn = /^#fn:([a-z][a-z0-9_]{0,31})$/.exec(href)?.[1]
  if (fn) return { page: 'function', id: fn }
  return null
}

/** A link the side navigation or a breadcrumb draws: its words and where it goes. */
export interface PageLink {
  text: string
  href: string
}

/**
 * The side navigation's pages, above its categories: Home, How to, and
 * Privacy, in that order.
 */
export function pageLinks(say: Say): PageLink[] {
  return [
    { text: say('nav_home'), href: hrefOf(HOME) },
    { text: say('nav_howto'), href: hrefOf({ page: 'howto' }) },
    { text: say('nav_privacy'), href: hrefOf({ page: 'privacy' }) },
  ]
}

/**
 * A page's breadcrumb trail. Home, then a category when the cards are
 * narrowed to one; a function's page is Home, its category, its name. The
 * how-to and the privacy page are their own one crumb; the login screen has
 * none (round 2: the app's name is in the top bar only). `categoryOf` is the
 * category a function is shown under, or undefined for one this player is not
 * shown.
 */
export function trailOf(route: Route, say: Say, categoryOf: (id: string) => string | undefined): PageLink[] {
  const crumbs: PageLink[] = []
  switch (route.page) {
    case 'functions':
      crumbs.push({ text: say('nav_home'), href: hrefOf(HOME) })
      if (route.category) crumbs.push({ text: say(`category_${route.category}`), href: hrefOf(route) })
      break
    case 'function': {
      crumbs.push({ text: say('nav_home'), href: hrefOf(HOME) })
      const category = categoryOf(route.id)
      if (category) {
        crumbs.push({ text: say(`category_${category}`), href: hrefOf({ page: 'functions', category, query: '' }) })
      }
      crumbs.push({ text: say(`${route.id}_name`), href: hrefOf(route) })
      break
    }
    case 'howto':
      crumbs.push({ text: say('nav_howto'), href: hrefOf(route) })
      break
    case 'privacy':
      crumbs.push({ text: say('nav_privacy'), href: hrefOf(route) })
      break
    case 'login':
      break
  }
  return crumbs
}

// -------------------------------------------------------------- history ---

/** The browser's history: the pages visited, and where in them the player is. */
export interface History {
  stack: Route[]
  index: number
}

export function startHistory(route: Route): History {
  return { stack: [route], index: 0 }
}

export function current(h: History): Route {
  return h.stack[h.index] ?? HOME
}

/** Go somewhere: forward history is dropped, as a browser drops it. */
export function push(h: History, route: Route): History {
  if (sameRoute(current(h), route)) return h
  const stack = h.stack.slice(0, h.index + 1)
  stack.push(route)
  return { stack, index: stack.length - 1 }
}

/** Replace where the player is without a new entry (a filter set in place). */
export function replace(h: History, route: Route): History {
  const stack = h.stack.slice()
  stack[h.index] = route
  return { stack, index: h.index }
}

export function canBack(h: History): boolean {
  return h.index > 0
}

export function canForward(h: History): boolean {
  return h.index < h.stack.length - 1
}

export function back(h: History): History {
  return canBack(h) ? { stack: h.stack, index: h.index - 1 } : h
}

export function forward(h: History): History {
  return canForward(h) ? { stack: h.stack, index: h.index + 1 } : h
}

// ------------------------------------------------------------ page loads ---

/**
 * THE BROWSER LOADS ITS PAGES (owner, 2026-10-06): "please make an artificial
 * page load time when navigating in the web browser between pages, except if
 * they use the forward/back buttons. The time should be random between 1 and 3
 * seconds, and the tab icon should change to a loading symbol to indicate it's
 * loading."
 *
 *   a navigation   anything that changes the page -- the side navigation
 *                  (Home, How to, Privacy, a category), a card or its title,
 *                  a breadcrumb, the how-to in the user menu, the top bar's
 *                  name, a search result, and the reload button -- starts a LOAD of a uniform pick in the range
 *                  (br_lib/config/terminals.lua pageMinMs..pageMaxMs, in the
 *                  catalog), a fresh pick every time
 *   while it loads THE PAGE ON SCREEN STAYS, address and all, as a browser
 *                  keeps the page you clicked on until the next one arrives;
 *                  the history moves only when the new page shows
 *   a new one      replaces the load under way, with its own fresh pick
 *   back/forward   at once, and a load under way is dropped
 *   the tab        a loading symbol from the first moment of a load to the
 *                  last (`TabNote`, which the app hands the desktop): on when
 *                  a load starts, off when its page shows or it is dropped
 *
 * NOT NAVIGATIONS, so never a load: setting one of the cards' filters (it
 * rewrites the page's own entry, `rewrite`), Match stats opening and closing, the
 * light/dark switch, Run and its bar, and the cards' pagination and
 * preferences (state inside the page, with no address of its own).
 */

/** The range a page load is picked from, in milliseconds. */
export interface LoadRange {
  minMs: number
  maxMs: number
}

/** Where a navigation goes: a page, or the page on screen again (reload). */
export type NavTarget = { kind: 'page'; route: Route } | { kind: 'reload' }

/** A page load under way: its number, where it goes, and how long it takes. */
export interface PageLoad {
  seq: number
  target: NavTarget
  ms: number
}

/** The browser: where it has been, and the load under way, if any. */
export interface Browsing {
  history: History
  load: PageLoad | null
  /** The last load's number, so a load replaced or dropped is never mistaken for the current one. */
  seq: number
}

export function startBrowsing(route: Route): Browsing {
  return { history: startHistory(route), load: null, seq: 0 }
}

/**
 * How long a load takes: uniform in the range, rounded to the millisecond.
 * `rnd` is Math.random in the app. No range (a catalog that did not carry
 * one) is no wait.
 */
export function loadMs(range: LoadRange | null, rnd: () => number): number {
  if (!range) return 0
  const r = Math.min(1, Math.max(0, rnd()))
  return Math.round(range.minMs + r * (range.maxMs - range.minMs))
}

/** A browser step and what the tab is to be told about it. */
export interface BrowseStep {
  browsing: Browsing
  tab: TabNote
}

/**
 * A navigation. Starts a load of `ms`, replacing any load under way, and
 * turns the tab's loading symbol on (again, for the new length). A page that
 * is already the one on screen, with nothing loading, is not a navigation: a
 * link to where the player already is does nothing, as it did before loads.
 */
export function navigate(b: Browsing, target: NavTarget, ms: number): BrowseStep {
  if (target.kind === 'page' && b.load === null && sameRoute(target.route, current(b.history))) {
    return { browsing: b, tab: null }
  }
  const seq = b.seq + 1
  return { browsing: { ...b, seq, load: { seq, target, ms } }, tab: { on: true, ms } }
}

/**
 * The load `seq` is over: its page shows -- pushed onto the history, or, for
 * a reload, the same page again (`reload`: the app re-asks and remounts) --
 * and the tab is itself again. A load that was replaced or dropped since is
 * nothing.
 */
export function arrive(b: Browsing, seq: number): BrowseStep & { reload: boolean; shown: boolean } {
  if (b.load === null || b.load.seq !== seq) return { browsing: b, tab: null, reload: false, shown: false }
  const t = b.load.target
  const history = t.kind === 'page' ? push(b.history, t.route) : b.history
  return { browsing: { ...b, history, load: null }, tab: { on: false }, reload: t.kind === 'reload', shown: true }
}

/**
 * The back or the forward button: AT ONCE (the owner's exception), and a load
 * under way is dropped -- its page never shows, and the tab stops loading.
 */
export function step(b: Browsing, dir: 'back' | 'forward'): BrowseStep {
  const history = dir === 'back' ? back(b.history) : forward(b.history)
  return { browsing: { ...b, history, load: null }, tab: b.load !== null ? { on: false } : null }
}

/** The page's own entry rewritten in place (a filter set): no load, no history entry. */
export function rewrite(b: Browsing, route: Route): Browsing {
  return { ...b, history: replace(b.history, route) }
}

// ------------------------------------------------------- the first load ---

/**
 * THE APP'S FIRST PAGE LOADS TOO (owner, 2026-10-06, round 4): "The initial
 * page load should also take time, and be shown as a white page during that
 * time while the tab shows the loading icon."
 *
 *   waiting   the app is up (opened from its desktop icon, so a fresh
 *             document) and the catalog with its page-load range has not
 *             come yet: a white page under the browser's toolbar
 *   loading   the catalog came: a fresh pick in its range, the same as any
 *             navigation's (`loadMs`), still white, and the tab is told a
 *             load of that length is under way
 *   null      the first page shows, and the tab is itself again
 *
 * The desktop's tab wears its loading symbol from the icon's click (the
 * app's own document loading included) until the app says the page showed
 * (cuchi_computer's br.js). Nothing navigates while the first page loads:
 * back and forward have nowhere to go, and reload and links wait for it.
 */
export type Opening = { phase: 'waiting' } | { phase: 'loading'; ms: number } | null

export function startOpening(): Opening {
  return { phase: 'waiting' }
}

/**
 * A catalog arrived: a first page still waiting starts its load. Anything
 * else -- a load under way, or the first page shown -- is unchanged, and
 * the tab is told nothing.
 */
export function openingStarts(o: Opening, range: LoadRange | null, rnd: () => number): { opening: Opening; tab: TabNote } {
  if (o === null || o.phase !== 'waiting') return { opening: o, tab: null }
  const ms = loadMs(range, rnd)
  return { opening: { phase: 'loading', ms }, tab: { on: true, ms } }
}

/** The first page's load is over: it shows, and the tab is itself again. */
export function openingEnds(o: Opening): { opening: Opening; tab: TabNote } {
  if (o === null || o.phase !== 'loading') return { opening: o, tab: null }
  return { opening: null, tab: { on: false } }
}

// -------------------------------------------------------------- functions ---

/**
 * The functions this player is shown, in the registry's order: outside a
 * squad match, without the squad-only ones (Reboot, Comms blackout) and with
 * a `soloCategory` in place of the category (Ghost). The server lists and
 * runs the same set.
 */
export function shownFunctions(catalog: Catalog, squadMatch: boolean): FunctionDef[] {
  return catalog.functions
    .filter((f) => squadMatch || !f.squadOnly)
    .map((f) => (!squadMatch && f.soloCategory ? { ...f, category: f.soloCategory } : f))
}

/**
 * THE OPTIONS A FUNCTION OFFERS UNDER THESE CHOICES (round 4, owner,
 * 2026-10-06: Time & weather's "either time or weather to be set. Not
 * both"): every option with no `when`, and each whose `when` holds -- the
 * other option's choice, or its default while the player has not touched it.
 * The server drops the rest (BR.Terminal.options), so the page shows exactly
 * what a run can carry.
 */
export function shownOptions(def: FunctionDef, choice: Readonly<Record<string, string>>): OptionDef[] {
  const now = (id: string): string | undefined =>
    choice[id] ?? def.options.find((o) => o.id === id)?.default
  return def.options.filter((o) => !o.when || Object.entries(o.when).every(([k, v]) => now(k) === v))
}

/**
 * What a run sends: the choice of every option offered, the player's own or
 * its default, and nothing for an option that is not offered -- a choice for
 * one the server would refuse the whole run over.
 */
export function runChoices(def: FunctionDef, choice: Readonly<Record<string, string>>): Record<string, string> {
  const out: Record<string, string> = {}
  for (const o of shownOptions(def, choice)) out[o.id] = choice[o.id] ?? o.default
  return out
}

/**
 * A function's risks, in the order its page lists them: risk_notice first --
 * the lobby is told who ran what -- then its own `<id>_risks` lines. A QUIET
 * row (round 4: Field medic, "should not notify everyone") tells the lobby
 * nothing, so its page does not say it does.
 */
export function risksOf(def: FunctionDef, say: Say): string[] {
  return [...(def.quiet ? [] : [say('risk_notice')]), ...lines(say(`${def.id}_risks`))]
    .filter((s) => s !== '')
}

/** The categories with something in them, in the registry's order. */
export function shownCategories(catalog: Catalog, shown: FunctionDef[]): string[] {
  const used = new Set(shown.map((f) => f.category))
  return catalog.categories.filter((c) => used.has(c))
}

/**
 * What a card says about a function now: the four the owner named
 * (round 2's words: available, used, not available at this terminal, not
 * available).
 */
export type Status = 'available' | 'used' | 'not_here' | 'offline'

/**
 * A function's status, from the server's reason. Offline ("Not available") is
 * a function not built yet, or a terminal the storm has taken; used is the
 * squad's one use spent; not here ("Not available at this terminal") is
 * everything else that stops it at this terminal now.
 */
export function statusOf(fn: FunctionState | undefined, def: FunctionDef | undefined): Status {
  if (def && !def.implemented) return 'offline'
  if (!fn) return 'offline'
  if (fn.available) return 'available'
  switch (fn.reason) {
    case 'fn_offline':
    case 'offline':
      return 'offline'
    case 'squad_used':
      return 'used'
    default:
      return 'not_here'
  }
}

/**
 * Does this function's title carry "Squads!" (round 4, Squads.tsx)? Only on a
 * row whose effect reaches the runner's whole squad (`squadWide`), and only
 * in a squad match -- round 2's rule, no "squad" to a solo player.
 */
export function showsSquads(def: FunctionDef, squadMatch: boolean): boolean {
  return squadMatch && def.squadWide === true
}

/** The StatusIndicator type for a status. None of them spins (#385). */
export function indicatorOf(s: Status): 'success' | 'info' | 'warning' | 'stopped' {
  switch (s) {
    case 'available':
      return 'success'
    case 'used':
      return 'info'
    case 'not_here':
      return 'warning'
    case 'offline':
      return 'stopped'
  }
}

/** The Badge colour for a risk level. */
export function riskColor(r: FunctionDef['risk']): 'severity-low' | 'severity-medium' | 'severity-high' {
  return r === 'high' ? 'severity-high' : r === 'medium' ? 'severity-medium' : 'severity-low'
}

/** Does a function match the search box? Its name, summary or category. */
export function matches(def: FunctionDef, say: Say, query: string): boolean {
  const q = query.trim().toLowerCase()
  if (q === '') return true
  const hay = [
    say(`${def.id}_name`),
    say(`${def.id}_summary`),
    say(`category_${def.category}`),
  ].join(' ').toLowerCase()
  return q.split(/\s+/).every((word) => hay.includes(word))
}

// ---------------------------------------------------------- the filters ---

/**
 * HOME'S FILTERS (owner, 2026-10-06, round 4: "the "Functions" search should
 * have filters available for category, risk, Volts cost (free/paid), bounty,
 * and availability status"). Each narrows the cards to one value or, null,
 * filters nothing; all of them together with the top bar's search text (the
 * route's `query`, when a search brought the player here -- Home has no text
 * search of its own since round 5), and pagination over what is left. The CATEGORY filter is the
 * page's own category -- the side navigation's -- so it lives in the route's
 * `category`; the other four ride in the route's `filters`. Changing any of
 * them rewrites the page's own history entry, as typing does: no load, no new
 * entry (model.ts `rewrite`), and back and forward keep them.
 */
export interface CardFilters {
  risk: FunctionDef['risk'] | null
  cost: Cost | null
  bounty: Bounty | null
  status: Status | null
}

/** A function's cost, as the Cost filter reads it. */
export type Cost = 'free' | 'paid'
/** Who a function's run puts a bounty on, as its card and the Bounty filter say it. */
export type Bounty = 'runner' | 'target' | 'none'

export const NO_FILTERS: CardFilters = { risk: null, cost: null, bounty: null, status: null }
/** The four, in the order the address and the filter row put them. */
export const FILTER_KEYS = ['risk', 'cost', 'bounty', 'status'] as const
export const RISKS: readonly FunctionDef['risk'][] = ['low', 'medium', 'high']
export const COSTS: readonly Cost[] = ['free', 'paid']
export const BOUNTIES: readonly Bounty[] = ['none', 'runner', 'target']
export const STATUSES: readonly Status[] = ['available', 'used', 'not_here', 'offline']

export function costOf(def: FunctionDef): Cost {
  return def.cost > 0 ? 'paid' : 'free'
}

export function bountyOf(def: FunctionDef): Bounty {
  return def.bounty ?? 'none'
}

/** The cards page's four filters; none for any other page. */
export function filtersOf(route: Route): CardFilters {
  return route.page === 'functions' && route.filters ? route.filters : NO_FILTERS
}

/**
 * The cards page with these filters. A page that filters nothing carries no
 * `filters` at all, so it is the same page as one that never had any (Home
 * is Home, `sameRoute`).
 */
export function withFilters(route: Extract<Route, { page: 'functions' }>, f: CardFilters): Route {
  const { filters: _, ...rest } = route
  return FILTER_KEYS.some((k) => f[k] !== null) ? { ...rest, filters: { ...f } } : rest
}

/** Is the cards page narrowed by anything: a category, a filter or the top bar's search text? */
export function narrowed(route: Route): boolean {
  if (route.page !== 'functions') return false
  const f = filtersOf(route)
  return route.category !== null || route.query.trim() !== '' || FILTER_KEYS.some((k) => f[k] !== null)
}

/** Does a function pass the four filters, its status as the server says it now? */
export function passes(def: FunctionDef, fn: FunctionState | undefined, f: CardFilters): boolean {
  if (f.risk !== null && def.risk !== f.risk) return false
  if (f.cost !== null && costOf(def) !== f.cost) return false
  if (f.bounty !== null && bountyOf(def) !== f.bounty) return false
  if (f.status !== null && statusOf(fn, def) !== f.status) return false
  return true
}

/**
 * The cards the page shows, before pagination: the page's category, the text
 * search and the four filters, all together. `all` is the category's own
 * (what the heading counts when nothing else narrows it).
 */
export function cardsFor(route: Extract<Route, { page: 'functions' }>, functions: FunctionDef[],
  states: Map<string, FunctionState>, say: Say): { items: FunctionDef[]; all: number } {
  const inCategory = functions.filter((f) => route.category === null || f.category === route.category)
  const f = filtersOf(route)
  const items = inCategory.filter((d) => matches(d, say, route.query) && passes(d, states.get(d.id), f))
  return { items, all: inCategory.length }
}

// ----------------------------------------------------------------- clocks ---

/** A duration as the panel shows it: m:ss, or h:mm:ss past the hour. */
export function clock(ms: number | null): string {
  if (ms === null || !Number.isFinite(ms) || ms < 0) return '-'
  const total = Math.floor(ms / 1000)
  const h = Math.floor(total / 3600)
  const m = Math.floor((total % 3600) / 60)
  const s = total % 60
  const ss = String(s).padStart(2, '0')
  return h > 0 ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`
}

// ---------------------------------------------------------------- the run ---

/** A run that is loading, on this page's own clock. */
export interface Progress {
  functionId: string
  runMs: number
  startedAt: number
}

/**
 * THE BAR, AFTER A STATE: the run the server says is loading -- the bar
 * already drawn for it kept as it is, or one drawn where the server's clock
 * puts it (an app opened again while the run loads) -- and NO BAR when the
 * server says nothing is loading. The last is the review of round 2: an
 * answer this app will never get (it went to the player as a toast, because
 * the session that asked was replaced) must not leave a full bar and a
 * disabled Run behind it. A run's last state always comes just ahead of its
 * answer, so a bar is never taken down before the answer that ends it.
 */
export function progressAfter(was: Progress | null, running: RunningInfo | null, now: number): Progress | null {
  if (!running) return null
  return was ?? { functionId: running.functionId, runMs: running.runMs, startedAt: now - (running.runMs - running.leftMs) }
}
