/**
 * LOCKER V2'S SCREEN, RENDERED WITHOUT A BROWSER (#28 review), for
 * scripts/test-lockerv2.mjs.
 *
 * The review reverted agreed pieces of the screen one at a time and half of
 * them went unnoticed, because the tests read the source for a string: a card
 * whose press no longer wore the look still "called LOCKER2_WEAR". So the
 * screen's real components are rendered here, their real handlers pressed,
 * and what they draw and send is read back.
 *
 * HOW. esbuild bundles the components with the few things a page needs from
 * outside swapped for stand-ins:
 *
 *   Cloudscape    every component is a named leaf, `cs:<name>`, that keeps
 *                 its props -- the label, the items, the handlers;
 *   the bridge    fetchNui records each call in `calls`;
 *   the store     useUi reads `state`, which the test sets (from the browser
 *                 harness's own pushes, parsed as App.tsx parses them);
 *   sound, CSS    nothing.
 *
 * and a small renderer here plays React's part: it calls each component with
 * a hooks dispatcher of its own, keeps state between renders by the
 * component's place in the tree, runs effects, and re-renders until nothing
 * changes. No DOM: host elements come back as `{ type, props, children }`.
 * Frames and timers are queued, and run when the test says (`frames()`).
 */

import { build } from 'esbuild'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

const STUBS = {
  nui: `
    const S = globalThis.__lk2r
    export function fetchNui(cb, data) { S.calls.push([cb, data ?? null]); return Promise.resolve({}) }
    export function reportError() {}
    export function subscribe() { return () => {} }
    export const isBrowser = true`,
  useNuiEvent: 'export function useNuiEvent() {}',
  cues: 'export function play() {}',
  store: `
    const S = globalThis.__lk2r
    export function useUi(sel) { return sel(S.state) }
    useUi.getState = () => S.state
    useUi.setState = (p) => { S.state = { ...S.state, ...(typeof p === 'function' ? p(S.state) : p) } }
    useUi.subscribe = () => () => {}`,
  globalStyles: 'export const Mode = { Light: "light", Dark: "dark" }; export function applyMode() {}',
  theming: 'export function generateThemeStylesheet() { return "" }',
  css: '',
}

const ENTRY = `
export * as React from 'react'
export { default as LockerV2 } from './src/screens/LockerV2.tsx'
export { Home } from './src/screens/lockerv2/Home.tsx'
export { NewChoice, StockList } from './src/screens/lockerv2/NewLook.tsx'
export { Editor } from './src/screens/lockerv2/Editor.tsx'
export { CameraStage, CLUSTER_X } from './src/screens/lockerv2/Camera.tsx'
export { keepPal } from './src/screens/lockerv2/palette.ts'
export { keepTats } from './src/screens/lockerv2/tattooLists.ts'
`

/** Bundle the screen with its stand-ins and load it. */
export async function loadScreen() {
  const out = await build({
    stdin: { contents: ENTRY, resolveDir: ROOT, loader: 'ts', sourcefile: 'lockerv2-render-entry.ts' },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'neutral',
    mainFields: ['module', 'main'],
    jsx: 'automatic',
    logLevel: 'silent',
    define: { 'process.env.NODE_ENV': '"production"', 'import.meta.env.DEV': 'false' },
    plugins: [{
      name: 'lockerv2-stand-ins',
      setup(b) {
        const stub = (path) => () => ({ path, namespace: 'stub' })
        b.onResolve({ filter: /^@cloudscape-design\/components\/theming$/ }, stub('theming'))
        b.onResolve({ filter: /^@cloudscape-design\/components\/[\w-]+$/ }, (a) => ({ path: a.path.split('/').pop(), namespace: 'cs' }))
        b.onResolve({ filter: /^@cloudscape-design\/global-styles$/ }, stub('globalStyles'))
        b.onResolve({ filter: /(^|\/)bridge\/nui$/ }, stub('nui'))
        b.onResolve({ filter: /(^|\/)bridge\/useNuiEvent$/ }, stub('useNuiEvent'))
        b.onResolve({ filter: /(^|\/)audio\/cues$/ }, stub('cues'))
        b.onResolve({ filter: /^(\.\.\/)+store$/ }, stub('store'))
        b.onResolve({ filter: /\.css$/ }, stub('css'))
        b.onLoad({ filter: /.*/, namespace: 'stub' }, (a) => ({ contents: STUBS[a.path], loader: 'js', resolveDir: ROOT }))
        b.onLoad({ filter: /.*/, namespace: 'cs' }, (a) => ({
          contents: `import { createElement } from 'react'
            export default function Cs(props) { return createElement('cs:${a.path}', props) }`,
          loader: 'js',
          resolveDir: ROOT,
        }))
      },
    }],
  })
  globalThis.__lk2r ??= { state: {}, calls: [] }
  const text = out.outputFiles[0].text
  return import(`data:text/javascript;base64,${Buffer.from(text).toString('base64')}`)
}

// ── a page without a browser ─────────────────────────────────────────────────
/** Queued frames and timers, run by `frames()`; listeners kept by name. */
export function fakePage() {
  const queue = []
  const listeners = new Map()
  const el = () => ({
    style: { cssText: '', setProperty() {}, removeProperty() {} },
    setAttribute() {}, appendChild(c) { return c }, remove() {}, children: [],
    getBoundingClientRect: () => ({ left: 0, top: 0, width: 0, height: 0 }), querySelector: () => null,
  })
  const doc = { createElement: el, head: el(), body: el(), documentElement: el(), querySelectorAll: () => [], querySelector: () => null }
  let id = 0
  const later = (fn) => { queue.push({ id: ++id, fn }); return id }
  const cancel = (n) => { const i = queue.findIndex((q) => q.id === n); if (i >= 0) queue.splice(i, 1) }
  globalThis.document = doc
  globalThis.getComputedStyle = () => ({ fontSize: '14px', visibility: 'visible' })
  globalThis.MutationObserver = class { observe() {} disconnect() {} }
  globalThis.window = {
    ...(globalThis.window ?? {}),
    location: { search: '' },
    setTimeout: later, clearTimeout: cancel, requestAnimationFrame: later, cancelAnimationFrame: cancel,
    addEventListener: (k, fn) => { listeners.set(k, [...(listeners.get(k) ?? []), fn]) },
    removeEventListener: (k, fn) => { listeners.set(k, (listeners.get(k) ?? []).filter((f) => f !== fn)) },
  }
  return {
    /** Run everything queued, and what that queues, up to a bound. */
    frames(max = 200) { for (let n = 0; n < max && queue.length; n++) queue.shift().fn(0) },
    listeners,
  }
}

// ── the renderer ─────────────────────────────────────────────────────────────
const ELEMENT = new Set([Symbol.for('react.transitional.element'), Symbol.for('react.element')])
const FRAGMENT = Symbol.for('react.fragment')
const MEMO = Symbol.for('react.memo')
const FORWARD = Symbol.for('react.forward_ref')
const CONTEXT = Symbol.for('react.context')

const changed = (a, b) => !a || !b || a.length !== b.length || a.some((x, i) => !Object.is(x, b[i]))

/**
 * Mount `element` and render it until nothing changes. Returns the live tree
 * and ways to read it and act on it; every act re-renders.
 */
export function mount(React, element) {
  const shared = React.__CLIENT_INTERNALS_DO_NOT_USE_OR_WARN_USERS_THEY_CANNOT_UPGRADE
  const slots = new Map()
  /** A stand-in element per host element that takes a ref, kept across renders. */
  const els = new Map()
  let refs = []
  let dirty = false
  let effects = []
  let seen = new Set()
  let tree = []

  const dispatcher = (slot) => {
    let i = 0
    const hook = (make) => { const k = i++; if (!(k in slot.hooks)) slot.hooks[k] = make(); return slot.hooks[k] }
    const effect = (fn, deps) => {
      const h = hook(() => ({ fresh: true, cleanup: null }))
      if (h.fresh || deps === undefined || changed(h.deps, deps)) { h.fresh = false; h.deps = deps; effects.push({ h, fn }) }
    }
    const memo = (make, deps) => {
      const h = hook(() => ({}))
      if (!('v' in h) || changed(h.deps, deps)) { h.v = make(); h.deps = deps }
      return h.v
    }
    return {
      useState(init) {
        const h = hook(() => ({ v: typeof init === 'function' ? init() : init }))
        h.set ??= (n) => { const v = typeof n === 'function' ? n(h.v) : n; if (!Object.is(v, h.v)) { h.v = v; dirty = true } }
        return [h.v, h.set]
      },
      useReducer(r, init, f) {
        const h = hook(() => ({ v: f ? f(init) : init }))
        h.d ??= (a) => { h.v = r(h.v, a); dirty = true }
        return [h.v, h.d]
      },
      useRef: (v) => hook(() => ({ current: v })),
      useMemo: (make, deps) => memo(make, deps),
      useCallback: (fn, deps) => memo(() => fn, deps),
      useEffect: effect,
      useLayoutEffect: effect,
      useInsertionEffect: effect,
      useContext: (c) => c._currentValue,
      useDeferredValue: (v) => v,
      useTransition: () => [false, (fn) => fn()],
      useSyncExternalStore: (_sub, get) => get(),
      useId: () => hook(() => ({ id: `r${slots.size}-${i}` })).id,
      useImperativeHandle() {},
      useDebugValue() {},
      use: (x) => (x && x.$$typeof === CONTEXT ? x._currentValue : x),
    }
  }

  const call = (fn, args, path) => {
    seen.add(path)
    let slot = slots.get(path)
    if (!slot) slots.set(path, slot = { hooks: [] })
    const prev = shared.H
    shared.H = dispatcher(slot)
    let out
    try { out = fn(...args) } finally { shared.H = prev }
    return walk(out, path)
  }
  const renderType = (type, props, path) => {
    if (typeof type === 'string') {
      const node = { type, props, children: walk(props.children, `${path}/${type}`) }
      if (props.ref) refs.push([`${path}/${type}`, props.ref, node])
      return [node]
    }
    if (type === FRAGMENT) return walk(props.children, path)
    if (type && type.$$typeof === MEMO) return renderType(type.type, props, path)
    if (type && type.$$typeof === FORWARD) return call(type.render, [props, null], `${path}/fwd`)
    if (type && type.$$typeof === CONTEXT) return walk(props.children, path)
    if (typeof type === 'function') {
      if (type.prototype && type.prototype.isReactComponent) throw new Error(`class component ${type.name}`)
      return call(type, [props], `${path}/${type.displayName || type.name || 'anon'}`)
    }
    throw new Error(`cannot render ${String(type)}`)
  }
  function walk(node, path) {
    if (node === null || node === undefined || typeof node === 'boolean') return []
    if (typeof node === 'string' || typeof node === 'number') return [String(node)]
    if (Array.isArray(node)) {
      return node.flatMap((c, j) => walk(c, `${path}[${c && c.key != null ? `k${c.key}` : j}]`))
    }
    if (!ELEMENT.has(node.$$typeof)) throw new Error(`not a node: ${String(node)}`)
    return renderType(node.type, node.props, path)
  }

  const render = () => {
    for (let n = 0; n < 50; n++) {
      dirty = false
      effects = []
      refs = []
      seen = new Set()
      tree = walk(element, 'root')
      // Refs, as React attaches them: a callback is called with the element, an
      // object gets it as `current`.
      // The node keeps its element as `el`; a scroll into view is counted.
      for (const [p, ref, node] of refs) {
        if (!els.has(p)) {
          els.set(p, {
            scrolled: 0, querySelector: () => null, scrollIntoView() { this.scrolled++ },
            getBoundingClientRect: () => ({ left: 0, top: 0, width: 0, height: 0 }),
          })
        }
        node.el = els.get(p)
        if (typeof ref === 'function') ref(node.el); else ref.current = node.el
      }
      for (const [p, s] of slots) {
        if (seen.has(p)) continue
        for (const h of s.hooks) if (h && typeof h.cleanup === 'function') h.cleanup()
        slots.delete(p)
      }
      for (const { h, fn } of effects) {
        if (typeof h.cleanup === 'function') h.cleanup()
        const c = fn()
        h.cleanup = typeof c === 'function' ? c : null
      }
      if (!dirty) return tree
    }
    throw new Error('the screen never settled')
  }
  render()

  // ── reading the tree ──
  const nodes = () => {
    const out = []
    const visit = (list, parents) => {
      for (const n of list) {
        if (typeof n === 'string') continue
        out.push({ node: n, parents })
        visit(n.children, [...parents, n])
      }
    }
    visit(tree, [])
    return out
  }
  return {
    get tree() { return tree },
    render,
    /** Every host element that passes `pred(node)`, with its ancestors. */
    all: (pred) => nodes().filter((x) => pred(x.node)),
    /** Run `fn` (a press, a push), then render until nothing changes. */
    act(fn) { fn(); return render() },
  }
}

// ── node helpers ─────────────────────────────────────────────────────────────
/** The text a node draws: its strings, its children's, in order. */
export function textOf(n) {
  if (typeof n === 'string') return n
  return n.children.map(textOf).join('')
}
/** The node's classes. */
export const classes = (n) => String(n.props.className ?? '').split(/\s+/).filter(Boolean)
export const hasClass = (n, c) => classes(n).includes(c)
/** A press: the handler a real click would reach, with what React passes. */
export function press(n) {
  const e = { button: 0, detail: 1, preventDefault() {}, stopPropagation() {}, currentTarget: { setPointerCapture() {}, releasePointerCapture() {} } }
  if (n.props.onPointerDown) n.props.onPointerDown(e)
  if (n.props.onPointerUp) n.props.onPointerUp(e)
  if (n.props.onClick) n.props.onClick(e)
}
