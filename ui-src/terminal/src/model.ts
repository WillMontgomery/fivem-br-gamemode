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

import type { Catalog, Copy, FunctionDef, FunctionState, RunningInfo, TabNote } from './bridge'

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

/** A line with its `{token}`s filled. An unknown token is left as written. */
export function fill(text: string, vars: Record<string, string | number>): string {
  return text.replace(/\{(\w+)\}/g, (m, k: string) => (k in vars ? String(vars[k]) : m))
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
 * its heading still counts the functions. A function's own page stays under
 * /functions. PRIVACY (the same day): the made-up policy, in the side
 * navigation after How to.
 */
export type Route =
  | { page: 'functions'; category: string | null; query: string }
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
 * https://controltower.blitz/home, or .../functions/storm-reveal. The host and
 * each section's segment are copy; a function's segment is its id, hyphenated
 * as a URL is.
 */
export function addressOf(route: Route, say: Say): string {
  const host = say('address_host')
  switch (route.page) {
    case 'functions': {
      const params: string[] = []
      if (route.category) params.push(`category=${route.category}`)
      if (route.query) params.push(`q=${encodeURIComponent(route.query)}`)
      return `${host}/${say('path_home')}${params.length > 0 ? '?' + params.join('&') : ''}`
    }
    case 'function':
      return `${host}/${say('path_functions')}/${route.id.replace(/_/g, '-')}`
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

/** Replace where the player is without a new entry (a filter typed in place). */
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
 * NOT NAVIGATIONS, so never a load: typing in the cards' filter (it rewrites
 * the page's own entry, `rewrite`), Match stats opening and closing, the
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

/** The page's own entry rewritten in place (a filter typed): no load, no history entry. */
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
