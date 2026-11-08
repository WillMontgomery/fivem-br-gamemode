#!/usr/bin/env node
/**
 * UI V2 ON THE PAGE (#436).
 *
 * br_ui/client/uiv2.lua tells the page which UI v2 pieces this machine holds:
 * as the page reports its environment, just before br:ui:ready, and on every
 * move of the held answer. The page keeps it in the store (`uiv2`), and each
 * piece reads its own with useUIv2. What is held here:
 *
 *   EVERY PIECE OFF UNTIL TOLD. The store's default, and the reason a page
 *   that has heard nothing -- or any page on a box with br_uiv2 unset -- draws
 *   today's screens. One key per UIv2Piece (bridge/types.ts).
 *
 *   ON ONLY FOR `true`. setUIv2 takes `=== true` per piece, so a payload that
 *   is malformed, empty or absent turns nothing on.
 *
 *   A PUSH THAT LANDS BEFORE REACT HAS SUBSCRIBED. Lua's answer to the
 *   environment report can arrive before React's first effects run, and the
 *   dispatcher drops an envelope nobody is subscribed to. installUiv2()
 *   subscribes at module load (main.tsx, before reportEnvironment()), so that
 *   push is in the store when the first render reads it. Here it is posted
 *   through the bridge's own window listener into a page with no component
 *   at all; the same push into a page without the install is dropped and
 *   counted, which is the failure the install exists for.
 *
 *   A SNAPSHOT NEVER TOUCHES IT. hydrate, which follows every br:ui:ready,
 *   keeps what the push said.
 *
 * bridge/uiv2.ts, the real bridge/nui.ts and the real store are bundled with
 * esbuild (they import without extensions, which node cannot load) and run
 * over a stand-in window. Only settings/apply is stood in: its audio starts a
 * timer at load. What cannot run is read off the source: main.tsx's order,
 * App's routing, the hook's selector and the harness's parameter.
 *
 * Run: npm run test:uiv2   (and as part of npm run build)
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { blankComments } from './cef-rules.mjs'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

let failed = 0
let ran = 0

function check(label, got, expected) {
  ran++
  const ok = JSON.stringify(got) === JSON.stringify(expected)
  if (!ok) failed++
  console.log(
    ok
      ? `  ok    ${label}`
      : `  FAIL  ${label}\n          got      ${JSON.stringify(got)}\n          expected ${JSON.stringify(expected)}`,
  )
}

const code = (p) => blankComments(readFileSync(join(ROOT, p), 'utf8'))

// ── the pieces, as bridge/types.ts declares them ────────────────────────────

const types = code('src/bridge/types.ts')
const decl = /export type UIv2Piece\s*=\s*([^\n]*(?:\n\s*\|[^\n]*)*)/.exec(types)
const PIECES = decl === null ? [] : [...decl[1].matchAll(/'([a-z][a-z0-9]*)'/g)].map((m) => m[1]).sort()
const ALL_OFF = Object.fromEntries(PIECES.map((p) => [p, false]))
const only = (p) => ({ ...ALL_OFF, [p]: true })

console.log('the pieces')
check('bridge/types.ts declares UIv2Piece, and hud is one', PIECES.includes('hud'), true)
check("the envelope union carries `uiv2` with UIv2Payload",
  /\|\s*\{\s*k:\s*'uiv2';\s*d:\s*UIv2Payload\s*\}/.test(types), true)

// ── the bridge, the store and the install, on a stand-in page ───────────────

/** esbuild's bundle of one entry, as text node can import. */
async function bundle(contents, plugins = []) {
  const out = await build({
    stdin: { contents, resolveDir: ROOT, loader: 'ts', sourcefile: 'test-uiv2-entry.ts' },
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'neutral',
    mainFields: ['module', 'main'],
    define: { 'import.meta.env.DEV': 'false' },
    logLevel: 'silent',
    plugins,
  })
  return out.outputFiles[0].text
}

// settings/apply reaches the audio, whose music clock starts an interval at
// load; the harness's mock is never reached with DEV false. Both stood in.
const STUBS = {
  apply: 'export const DEFAULT_SETTINGS = {}\nexport function applySettings() {}',
  mock: 'export async function mockFetch() { return null }',
}
const standIns = {
  name: 'uiv2-stand-ins',
  setup(b) {
    b.onResolve({ filter: /^\.\.\/settings\/apply$/ }, () => ({ path: 'apply', namespace: 'stub' }))
    b.onResolve({ filter: /^\.\/mock$/ }, () => ({ path: 'mock', namespace: 'stub' }))
    b.onLoad({ filter: /.*/, namespace: 'stub' }, (a) => ({ contents: STUBS[a.path], loader: 'js', resolveDir: ROOT }))
  },
}

const PAGE_JS = await bundle([
  "export { installUiv2 } from './src/bridge/uiv2'",
  "export { bridgeStats } from './src/bridge/nui'",
  "export { useUi } from './src/store'",
].join('\n'), [standIns])

/**
 * The page's window as the bridge sees it in game: invokeNative there (so not
 * the browser harness), no embedded frame, and its `message` listeners kept so
 * an envelope can be posted the way Lua's arrive -- from above this page.
 */
function fakeWindow() {
  const listeners = new Map()
  return {
    invokeNative: () => {},
    length: 0,
    setTimeout: (fn, ms) => setTimeout(fn, ms),
    clearTimeout: (t) => clearTimeout(t),
    addEventListener(type, fn) {
      if (!listeners.has(type)) listeners.set(type, [])
      listeners.get(type).push(fn)
    },
    removeEventListener() {},
    /** One envelope from Lua, through every `message` listener. */
    post(env) {
      for (const fn of listeners.get('message') ?? []) fn({ source: null, data: env })
    },
  }
}

let loads = 0
/** A fresh page: the module graph evaluated anew over a new window. */
async function page() {
  const win = fakeWindow()
  globalThis.window = win
  const mod = await import(`data:text/javascript;base64,${Buffer.from(`${PAGE_JS}\n// ${++loads}\n`).toString('base64')}`)
  let seq = 0
  const push = (d, k = 'uiv2') => win.post({ t: 'br', v: 1, k, d, s: ++seq })
  return { mod, win, push, store: mod.useUi }
}

console.log('every piece off until told')
{
  const { store } = await page()
  check('the store starts with every piece off', store.getState().uiv2, ALL_OFF)
  check('one key per UIv2Piece, and no other', Object.keys(store.getState().uiv2).sort(), PIECES)
}

console.log('a push that lands before React has subscribed')
{
  // THE FAILURE, FIRST: the install left out, as a subscription in a
  // component's effect would leave it until React had mounted.
  const { mod, push, store } = await page()
  push({ hud: true })
  check('without the install, the push is dropped: hud stays off', store.getState().uiv2, ALL_OFF)
  check('and the bridge counts it as unheard', mod.bridgeStats().unheard, 1)
}
{
  // AS main.tsx DOES: installed at module load, before the environment report
  // Lua answers. No component is mounted here at all.
  const { mod, push, store } = await page()
  mod.installUiv2()
  push({ hud: true })
  check('installed at load, the push before any render is kept', store.getState().uiv2, only('hud'))
  check('and nothing is counted as unheard', mod.bridgeStats().unheard, 0)
  push({ hud: false })
  check('a later move turns it off again', store.getState().uiv2, ALL_OFF)
}
{
  const { mod, push, store } = await page()
  mod.installUiv2()
  mod.installUiv2()
  let changes = 0
  store.subscribe(() => { changes++ })
  push({ hud: true })
  check('installed twice, a push is still taken once', changes, 1)
}

console.log('on only for `true`')
{
  const { mod, push, store } = await page()
  mod.installUiv2()
  const cases = [
    ['the string "true"', { hud: 'true' }],
    ['the number 1', { hud: 1 }],
    ['an empty payload', {}],
    ['an empty list (an empty Lua table)', []],
    ['null', null],
    ['no payload at all', undefined],
  ]
  for (const [label, d] of cases) {
    push({ hud: true })
    push(d)
    check(`${label}: every piece off`, store.getState().uiv2, ALL_OFF)
  }
  push({ hud: true, nosuch: true })
  check('a key that is no piece is not kept', store.getState().uiv2, only('hud'))
}

console.log('a snapshot never touches it')
{
  const { mod, push, store } = await page()
  mod.installUiv2()
  push({ hud: true })
  // A snapshot's shape, its parts empty: only uiv2 is read after it.
  store.getState().hydrate({
    match: { state: 'waiting', mode: 'solo', endsAt: 0, serverNow: 0 },
    hud: {},
    squad: { id: null, members: [] },
    inv: {},
    storm: null,
    chat: [],
  })
  check('hydrate after the push leaves hud on', store.getState().uiv2, only('hud'))
}

// ── what cannot run, read off the source ─────────────────────────────────────

console.log('the wiring')
{
  const main = code('src/main.tsx')
  const at = main.indexOf('installUiv2()')
  check('main.tsx installs it before reportEnvironment()', at >= 0 && at < main.indexOf('reportEnvironment()'), true)
  check('and before the first render', at >= 0 && at < main.indexOf('createRoot('), true)
  check("App does not route `uiv2` too: one handler, the install's",
    /useNuiEvent\(\s*'uiv2'/.test(code('src/App.tsx')), false)
  const install = code('src/bridge/uiv2.ts')
  check("the install subscribes `uiv2` to the store's setUIv2",
    /subscribe\(\s*'uiv2'\s*,\s*\(d\)\s*=>\s*useUi\.getState\(\)\.setUIv2\(/.test(install), true)
  check('useUIv2 is a primitive selector of its own piece',
    /useUi\(\(s\) => s\.uiv2\[piece\] === true\)/.test(code('src/ui/useUIv2.ts')), true)
  const mock = code('src/bridge/mock.ts')
  check("the harness sends `uiv2` once, and only under ?uiv2=",
    [(mock.match(/k: 'uiv2'/g) ?? []).length,
      /if \(uiv2 !== null\) \{[^}]*emit\(\{ k: 'uiv2'/.test(mock)], [1, true])
}

console.log(`\n${ran - failed}/${ran} passed`)
if (failed) process.exit(1)
