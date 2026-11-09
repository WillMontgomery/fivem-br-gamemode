#!/usr/bin/env node
/**
 * NOTICES WAIT WHILE NOBODY CAN SEE THEM (#431).
 *
 * A notice is on screen for its few seconds and then gone, so one that
 * arrives where it cannot be seen must wait, or it runs out its time unseen.
 * The store has always held them under GTA's menu (`hud.paused`) and let them
 * go when it closes, less any that waited past PAUSE_QUEUE_MS, a sticky one
 * excepted. UI v2's HUD (#431, #436) quick-hides its notices under OUR pause
 * menu too (hud/v2/HudLayer.tsx), so with the hud piece on they wait there as
 * well, by the same rules, and go when it closes. Today's notices show through
 * our pause menu, so with the piece off nothing about it changes.
 *
 * The real store (store/index.ts) is bundled with esbuild and driven by its
 * own setters, the ones App.tsx's handlers call: setHud (GTA's menu, on the
 * `hud` envelope), setFocus (our pause menu, on `focus`), setUIv2 (the piece,
 * on `uiv2`) and pushNotice (`toast`). Date.now is held, and moved by the
 * test; a notice's own removal timer never fires. Only settings/apply is stood
 * in: its audio starts a timer at load. What each setter writes is read back
 * as well: one that lets the notices go must still write the change that let
 * them go (the hud, the focus and its tab, the piece), or GTA's menu would
 * stay paused in the store, or the tab /help asked for would outlive its menu.
 *
 * Run: npm run test:noticewait   (and as part of npm run build)
 */

import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'

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

// ── the store, on a stand-in page ───────────────────────────────────────────

const STUBS = {
  apply: 'export const DEFAULT_SETTINGS = {}\nexport function applySettings() {}',
}
const out = await build({
  stdin: { contents: "export { useUi } from './src/store'", resolveDir: ROOT, loader: 'ts', sourcefile: 'test-notice-wait-entry.ts' },
  bundle: true,
  write: false,
  format: 'esm',
  platform: 'neutral',
  mainFields: ['module', 'main'],
  define: { 'import.meta.env.DEV': 'false' },
  logLevel: 'silent',
  plugins: [{
    name: 'notice-wait-stand-ins',
    setup(b) {
      b.onResolve({ filter: /^\.\.\/settings\/apply$/ }, () => ({ path: 'apply', namespace: 'stub' }))
      b.onLoad({ filter: /.*/, namespace: 'stub' }, (a) => ({ contents: STUBS[a.path], loader: 'js', resolveDir: ROOT }))
    },
  }],
})

// A notice's removal timer is armed and never fires: what is on screen stays
// until the test reads it.
let seq = 0
globalThis.window = { setTimeout: () => ++seq, clearTimeout: () => {} }
let now = 1_800_000_000_000
Date.now = () => now

const { useUi } = await import(`data:text/javascript;base64,${Buffer.from(out.outputFiles[0].text).toString('base64')}`)
const store = () => useUi.getState()
const FRESH = useUi.getState()

/** A fresh page: the store as it loads, every piece off. */
function fresh() {
  useUi.setState(FRESH, true)
  now = 1_800_000_000_000
}
/** The texts on screen, and the texts waiting. */
const shown = () => store().notices.map((n) => n.text)
const waiting = () => store().pendingNotices.map((n) => n.text)
const toast = (text, over = {}) => store().pushNotice({ text, ...over })
/** GTA's menu up or down: the `hud` envelope's `paused`, the rest as it is. */
const gtaMenu = (up) => store().setHud({ ...store().hud, paused: up })
/** Our pause menu open or closed: the `focus` envelope. */
const ourMenu = (open) => store().setFocus(open ? 'pause' : 'none')
const hudPiece = (on) => store().setUIv2(on ? { hud: true } : null)

// ── with the piece off: today's rule, exactly ───────────────────────────────

console.log('with the hud piece off, the rule is GTA\'s menu alone, as it was')
{
  fresh()
  gtaMenu(true)
  toast('Storm closing in 30 seconds')
  check("under GTA's menu a notice waits", [shown(), waiting()], [[], ['Storm closing in 30 seconds']])
  gtaMenu(false)
  check('GTA\'s menu closed: it shows, and nothing waits', [shown(), waiting()], [['Storm closing in 30 seconds'], []])
  check("...and the hud that closed it is written: not paused", store().hud.paused, false)
}
{
  fresh()
  store().setFocus('pause', 'help')
  check('our pause menu opened on a tab (/help): the focus and its tab, written', [store().focus, store().focusTab], ['pause', 'help'])
  ourMenu(false)
  check('...and closed: the tab goes with it', [store().focus, store().focusTab ?? null], ['none', null])
}
{
  fresh()
  ourMenu(true)
  toast('Kestrel picked up your key')
  check('under our pause menu a notice shows at once: today\'s notices show through it',
    [shown(), waiting()], [['Kestrel picked up your key'], []])
  let changes = 0
  const off = useUi.subscribe(() => { changes++ })
  ourMenu(false)
  off()
  check('closing our pause menu is the one plain write it always was', [changes, store().focus, shown()],
    [1, 'none', ['Kestrel picked up your key']])
}
{
  fresh()
  gtaMenu(true)
  toast('An old event')
  toast('Outside the storm', { sticky: true })
  now += 20_000
  toast('A newer event')
  now += 10_001
  gtaMenu(false)
  check('after 30 s an event has passed and is dropped; a sticky notice and a newer event show',
    shown(), ['Outside the storm', 'A newer event'])
}
{
  fresh()
  gtaMenu(true)
  toast('Exactly thirty')
  now += 30_000
  gtaMenu(false)
  check('one that waited exactly 30 s still shows', shown(), ['Exactly thirty'])
}
{
  fresh()
  store().pushNotice({ text: 'Reviving 10%', key: 'revive' })
  gtaMenu(true)
  store().pushNotice({ text: 'Reviving 40%', key: 'revive' })
  store().pushNotice({ text: 'Reviving 80%', key: 'revive' })
  check('a keyed notice replaces its own copy in the queue', waiting(), ['Reviving 80%'])
  store().pushNotice({ text: '', key: 'revive', clear: true })
  check('a clear takes the queued copy and the live row with it', [waiting(), shown()], [[], []])
}

// ── with the piece on: our pause menu holds them too ────────────────────────

console.log('with the hud piece on, our pause menu holds them too, by the same rules')
{
  fresh()
  hudPiece(true)
  ourMenu(true)
  toast('Kestrel picked up your key')
  check('under our pause menu a notice waits', [shown(), waiting()], [[], ['Kestrel picked up your key']])
  ourMenu(false)
  check('our pause menu closed: it shows, and nothing waits', [shown(), waiting(), store().focus],
    [['Kestrel picked up your key'], [], 'none'])
}
{
  fresh()
  hudPiece(true)
  store().setFocus('pause', 'help')
  toast('Waited on the Help tab')
  check('under our pause menu opened on a tab, a notice waits', [shown(), waiting(), store().focusTab],
    [[], ['Waited on the Help tab'], 'help'])
  ourMenu(false)
  check('...and closed: it shows, and the tab goes with the menu',
    [shown(), store().focus, store().focusTab ?? null], [['Waited on the Help tab'], 'none', null])
}
{
  fresh()
  hudPiece(true)
  ourMenu(true)
  toast('An old event')
  toast('Outside the storm', { sticky: true })
  now += 30_001
  toast('A newer event')
  ourMenu(false)
  check('the same aging on our menu\'s close: a sticky notice and a newer event show, an old event is dropped',
    shown(), ['Outside the storm', 'A newer event'])
}
{
  fresh()
  hudPiece(true)
  ourMenu(true)
  gtaMenu(true)
  toast('Under both')
  gtaMenu(false)
  check("GTA's menu closed back into ours: still waiting", [shown(), waiting()], [[], ['Under both']])
  ourMenu(false)
  check('...and ours closed: it shows', [shown(), waiting()], [['Under both'], []])
}
{
  fresh()
  hudPiece(true)
  ourMenu(true)
  gtaMenu(true)
  toast('Under both')
  ourMenu(false)
  check("ours closed with GTA's still up: still waiting", [shown(), waiting()], [[], ['Under both']])
  gtaMenu(false)
  check("...and GTA's closed: it shows", [shown(), waiting()], [['Under both'], []])
  check("...and the hud that closed it is written: not paused", store().hud.paused, false)
}
{
  fresh()
  hudPiece(true)
  store().pushNotice({ text: 'Reviving 10%', key: 'revive' })
  ourMenu(true)
  store().pushNotice({ text: 'Reviving 40%', key: 'revive' })
  store().pushNotice({ text: 'Reviving 80%', key: 'revive' })
  check('a keyed notice replaces its own copy in the queue', waiting(), ['Reviving 80%'])
  store().pushNotice({ text: '', key: 'revive', clear: true })
  check('a clear takes the queued copy and the live row with it', [waiting(), shown()], [[], []])
}
{
  fresh()
  hudPiece(true)
  ourMenu(true)
  toast('Waited for the settings')
  store().setFocus('settings')
  check('our pause menu left for another screen: it no longer hides the notices, and they go',
    [shown(), waiting()], [['Waited for the settings'], []])
}
{
  fresh()
  hudPiece(true)
  ourMenu(true)
  toast('Waited for today\'s notices')
  hudPiece(false)
  check("the piece turned off under our pause menu: today's notices show through it, and they go",
    [shown(), waiting(), store().uiv2.hud], [["Waited for today's notices"], [], false])
}
{
  fresh()
  hudPiece(true)
  toast('In the open')
  check('with no menu up a notice shows at once', [shown(), waiting()], [['In the open'], []])
}

console.log(`\n${ran - failed}/${ran} passed`)
process.exit(failed ? 1 : 0)
