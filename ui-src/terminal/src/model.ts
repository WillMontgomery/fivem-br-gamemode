/**
 * THE APP'S PURE PARTS: copy lookups, the pages and their addresses, what a
 * card says about a function, and the panel's clocks. No React, no DOM.
 *
 * ═══ EVERY WORD IS THE COPY BLOCK'S ═══
 *
 * The owner writes or approves every player-facing line (#396), so the app
 * says nothing of its own: `line` looks a key up in the copy br_core sends
 * (br_lib/config/terminals.lua), and a key with no line is nothing -- never
 * the key, never a default. scripts/check-terminal.mjs holds the JSX to it.
 * The only characters this file makes are digits, colons and separators.
 */

import type { Copy, FunctionDef, FunctionState } from './bridge'

/** A line of the copy, or nothing. */
export function line(copy: Copy, key: string | null | undefined): string {
  if (!key) return ''
  const v = copy[key]
  return typeof v === 'string' ? v : ''
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

/** Where the app is. Every page has an address and a breadcrumb trail. */
export type Route =
  | { page: 'functions'; category: string | null; query: string }
  | { page: 'function'; id: string }
  | { page: 'howto' }
  | { page: 'login' }

export const HOME: Route = { page: 'functions', category: null, query: '' }

export function sameRoute(a: Route, b: Route): boolean {
  return JSON.stringify(a) === JSON.stringify(b)
}

/**
 * The fictional address the browser's address bar shows for a page, e.g.
 * https://terminal.blitz/functions/storm-reveal. The host and each section's
 * segment are copy; a function's segment is its id, hyphenated as a URL is.
 */
export function addressOf(route: Route, copy: Copy): string {
  const host = line(copy, 'address_host')
  const fns = line(copy, 'path_functions')
  switch (route.page) {
    case 'functions': {
      const params: string[] = []
      if (route.category) params.push(`category=${route.category}`)
      if (route.query) params.push(`q=${encodeURIComponent(route.query)}`)
      return `${host}/${fns}${params.length > 0 ? '?' + params.join('&') : ''}`
    }
    case 'function':
      return `${host}/${fns}/${route.id.replace(/_/g, '-')}`
    case 'howto':
      return `${host}/${line(copy, 'path_howto')}`
    case 'login':
      return `${host}/${line(copy, 'path_login')}`
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
    case 'login':
      return '#login'
  }
}

/** The page an in-app href names, or null for one this app never made. */
export function routeOfHref(href: string): Route | null {
  if (href === '#home') return HOME
  if (href === '#howto') return { page: 'howto' }
  if (href === '#login') return { page: 'login' }
  const cat = /^#cat:([a-z][a-z0-9_]{0,31})$/.exec(href)?.[1]
  if (cat) return { page: 'functions', category: cat, query: '' }
  const fn = /^#fn:([a-z][a-z0-9_]{0,31})$/.exec(href)?.[1]
  if (fn) return { page: 'function', id: fn }
  return null
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

// -------------------------------------------------------------- functions ---

/** What a card says about a function now: the four the owner named. */
export type Status = 'available' | 'used' | 'not_here' | 'offline'

/**
 * A function's status, from the server's reason. Offline is a function not
 * built yet, or a terminal the storm has taken; used is the squad's one use
 * spent; not here is everything else that stops it at this terminal now.
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
export function matches(def: FunctionDef, copy: Copy, query: string): boolean {
  const q = query.trim().toLowerCase()
  if (q === '') return true
  const hay = [
    line(copy, `${def.id}_name`),
    line(copy, `${def.id}_summary`),
    line(copy, `category_${def.category}`),
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
