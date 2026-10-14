#!/usr/bin/env node
/**
 * CEF 144 (#413): EVERY GUARD FAILS ON WHAT IT BANS, AND THE FIXES HOLD.
 *
 *   * cef-rules.mjs (check-cef): each rule C1-C9 on a banned use, and on the
 *     nearest allowed form -- including Help.tsx's and DiscordCard.tsx's copy
 *     routines exactly as they were before #413, which C3 must refuse;
 *   * css-guard.mjs (check-css): an @supports block that tests for a
 *     feature hides it, nested parentheses and all; `not` and `or` do not,
 *     and neither does a block guarded by something else;
 *   * zoom-rect.mjs: the Cloudscape rewrite and which modules get it;
 *   * bridge/coalesce.ts: the locker spin keeps one request in flight and
 *     loses no rotation; the error sink's per-message and per-minute limits.
 *
 * Run: npm run test:cef   (and as part of npm run build)
 */

import { blankComments, checkZoomShim, scanBundle, scanManifests, scanSource } from './cef-rules.mjs'
import { blankGuarded } from './css-guard.mjs'
import { isCloudscape, rewriteRects } from './zoom-rect.mjs'
import { createErrorGate, oneInFlight } from '../src/bridge/coalesce.ts'

let ran = 0
let failed = 0
function check(label, ok, detail = '') {
  ran++
  if (!ok) {
    failed++
    console.error(`FAIL  ${label}${detail ? `\n      ${detail}` : ''}`)
  }
}
const rules = (found) => found.map((f) => f.rule).sort()
function banned(label, src, file, rule) {
  const got = rules(scanSource(src, file))
  check(`${label} is refused (${rule})`, got.includes(rule), `got ${JSON.stringify(got)}`)
}
function allowed(label, src, file) {
  const got = scanSource(src, file)
  check(`${label} passes`, got.length === 0, JSON.stringify(got.map((f) => `${f.rule}:${f.line}`)))
}
const F = 'ui-src/src/screens/New.tsx'

// --- C1 dialogs -------------------------------------------------------------
banned('alert()', "if (x) alert('saved')", F, 'C1 dialog')
banned('window.confirm()', 'const ok = window.confirm("Delete?")', F, 'C1 dialog')
banned('prompt() in a DUI page', '<script>const n = prompt("name")</script>', 'resources/x/page.html', 'C1 dialog')
banned('globalThis.alert()', 'globalThis . alert(1)', 'resources/x/a.js', 'C1 dialog')
allowed('a local confirm()', 'const confirm = () => setOpen(false)\nonKey(() => confirm())', F)
allowed('a method named prompt', 'ui.prompt(3); store.alert("x")', F)
allowed('a confirm(){} method definition', 'const api = {\n  confirm(id) { return id },\n}', F)
allowed('a dialog named in a comment', '// alert() is gone in CEF 144\n/* confirm() too */', F)
check('the bundle rule sees a bare call', rules(scanBundle('a.b(),alert("x")', 'x.js')).includes('C1 dialog'))
check('the bundle rule leaves a method definition', scanBundle('{confirm(e){return e}}', 'x.js').length === 0)

// --- C2 mutation events -----------------------------------------------------
banned('DOMNodeInserted', "el.addEventListener('DOMNodeInserted', f)", F, 'C2 mutation-event')
banned('DOMSubtreeModified', "document.addEventListener('DOMSubtreeModified', f)", 'resources/x/a.js', 'C2 mutation-event')
banned('createEvent MutationEvents', "document.createEvent('MutationEvents')", F, 'C2 mutation-event')
allowed('a MutationObserver', 'new MutationObserver(f).observe(document.body, { childList: true })', F)
allowed("react-transition-group's findDOMNode", 'const n = ReactDOM.findDOMNode(this)', F)
check('a bundle with a mutation event is refused',
  rules(scanBundle('x.addEventListener("DOMNodeRemoved",f)', 'index.js')).includes('C2 mutation-event'))

// --- C3 execCommand ---------------------------------------------------------
const OLD_HELP = `  const copy = async () => {
    play('ui.select')
    let ok = false
    try {
      await navigator.clipboard.writeText(SITE)
      ok = true
    } catch {
      const el = document.createElement('textarea')
      el.value = SITE
      document.body.appendChild(el)
      el.select()
      try { ok = document.execCommand('copy') } catch { /* nothing left to try */ }
      el.remove()
    }`
const OLD_DISCORD = `  const copy = async () => {
    const was = document.activeElement as HTMLElement | null
    let ok = false
    try {
      await navigator.clipboard.writeText(invite)
      ok = true
    } catch {
      const el = document.createElement('textarea')
      el.value = invite
      el.style.position = 'fixed'
      el.style.opacity = '0'
      document.body.appendChild(el)
      el.select()
      try { ok = document.execCommand('copy') } catch { ok = false }
      el.remove()
      was?.focus?.()
    }`
banned("Help.tsx's copy before #413", OLD_HELP, 'ui-src/src/screens/Help.tsx', 'C3 exec-command')
banned("DiscordCard.tsx's copy before #413 (focus only after)", OLD_DISCORD, 'ui-src/src/ui/DiscordCard.tsx', 'C3 exec-command')
banned('a focus in ANOTHER function', `function a() { el.focus() }
function b() {
  el.select()
  document.execCommand('copy')
}`, F, 'C3 exec-command')
allowed('focus, select, then execCommand', `export async function copyText(text: string): Promise<boolean> {
  const el = document.createElement('textarea')
  try {
    el.focus({ preventScroll: true })
    el.select()
    ok = document.execCommand('copy')
  } catch {
    ok = false
  }
}`, F)

// --- C4 zoom ----------------------------------------------------------------
banned('a style object with zoom', '<div style={{ zoom: 1.5 }} />', F, 'C4 zoom')
banned('style.zoom =', "el.style.zoom = '2'", F, 'C4 zoom')
banned("setProperty('zoom')", "el.style.setProperty('zoom', '2')", F, 'C4 zoom')
banned('zoom in a stylesheet', '.card { zoom: 1.25; }', 'ui-src/src/index.css', 'C4 zoom')
banned('zoom in a DUI page', '<style>.k{zoom:2}</style>', 'resources/[fivem-royale]/br_ui/dui/prompt.html', 'C4 zoom')
allowed("Locker v2's island (allowed, with its reason)", '<div style={{ zoom: z }} />', 'ui-src/src/screens/LockerV2.tsx')
allowed('currentCSSZoom and zoomFor()', 'const z = el.currentCSSZoom; setZ(zoomFor(px)); const zoom = 2', F)
check('zoom in a built stylesheet is refused', rules(scanBundle('.a{zoom:2}', 'index.css')).includes('C4 zoom'))
check('a built stylesheet without zoom passes', scanBundle('.a{color:red}.zoom-in{opacity:1}', 'index.css').length === 0)

// --- C5 URLs from data ------------------------------------------------------
banned('a player name in a URL', 'fetch(`https://ringmaster.example/p/${player.name}`)', F, 'C5 url-data')
banned('a callback name from data in a new file', 'fetch(`https://${resourceName()}/${name}`)', F, 'C5 url-data')
banned('concatenation', "img.src = 'https://nui-img/' + tex", F, 'C5 url-data')
banned('new URL(input)', 'const u = new URL(input)', F, 'C5 url-data')
banned('a nui:// URL from data', 'const u = `nui://br_ui/dui/${page}.html`', 'resources/x/a.js', 'C5 url-data')
allowed('the resource name and an escaped value', 'fetch(`https://${resourceName()}/x?q=${encodeURIComponent(q)}`)', F)
allowed('fetchNui in bridge/nui.ts (allowed, with its reason)', 'fetch(`https://${resourceName()}/${name}`)', 'ui-src/src/bridge/nui.ts')
allowed('a template that is not a URL', 'const s = `${a}://${b}`; const t = `calc(1rem / ${z})`', F)
allowed('GetParentResourceName()', 'fetch(`https://${GetParentResourceName()}/exit`)', 'resources/[computer]/cuchi_computer/nui/scripts/script.js')

// --- C6 blocked APIs ----------------------------------------------------------
banned('Picture-in-Picture', 'await video.requestPictureInPicture()', F, 'C6 blocked-api')
banned('documentPictureInPicture', 'documentPictureInPicture.requestWindow()', F, 'C6 blocked-api')
banned('WebUSB', 'navigator.usb.requestDevice({ filters: [] })', F, 'C6 blocked-api')
banned('WebHID', 'navigator . hid.getDevices()', 'resources/x/a.js', 'C6 blocked-api')
banned('the microphone from a page', 'navigator.mediaDevices.getUserMedia({ audio: true })', F, 'C6 blocked-api')
banned('printing', 'window.print()', F, 'C6 blocked-api')
allowed("React's disablePictureInPicture attribute", '<video disablePictureInPicture />', F)
check('a bundle using PiP is refused', rules(scanBundle('v.requestPictureInPicture()', 'index.js')).includes('C6 blocked-api'))
check("React DOM's attribute list passes", scanBundle('case"disablePictureInPicture":case"x":', 'index.js').length === 0)

// --- C7 unload --------------------------------------------------------------
banned('an unload listener', "window.addEventListener('unload', save)", F, 'C7 unload')
banned('onunload', 'window.onunload = save', 'resources/x/a.js', 'C7 unload')
allowed('pagehide', "window.addEventListener('pagehide', save)", F)

// --- C8 manifests -----------------------------------------------------------
const man = (file, text) => ({ file, text })
check('adamant is refused', rules(scanManifests([man('r/a/fxmanifest.lua', "fx_version 'adamant'\ngame 'gta5'")], [])).includes('C8 manifest'))
check('bodacious is refused', scanManifests([man('r/a/fxmanifest.lua', 'fx_version "bodacious"')], []).length === 1)
check('a manifest with no fx_version is refused', scanManifests([man('r/a/fxmanifest.lua', "game 'gta5'")], []).length === 1)
check('a commented-out cerulean does not count', scanManifests([man('r/a/fxmanifest.lua', "-- fx_version 'cerulean'\nfx_version 'adamant'")], []).length === 1)
check('__resource.lua is refused', rules(scanManifests([], ['r/a/__resource.lua'])).includes('C8 manifest'))
check('cerulean passes', scanManifests([man('r/a/fxmanifest.lua', "fx_version 'cerulean'\ngame 'gta5'")], []).length === 0)

// --- C9 the zoom shim -------------------------------------------------------
const CFG = 'plugins: [zoomRectPlugin(), react()],\noptimizeDeps: { esbuildOptions: { plugins: [zoomRectEsbuild()] } },'
const HELPER = "const METHOD = '__brZoomRect'; const z = el.currentCSSZoom"
check('the wired shim passes', checkZoomShim({ viteConfig: CFG, helper: HELPER, lockerBundle: 'a.__brZoomRect()' }).length === 0)
check('a config without the build plugin is refused',
  checkZoomShim({ viteConfig: CFG.replace('zoomRectPlugin(), ', ''), helper: HELPER, lockerBundle: null }).length === 1)
check('a plugin left only in a comment is refused',
  checkZoomShim({ viteConfig: `// zoomRectPlugin()\n${CFG.replace('zoomRectPlugin(), ', '')}`, helper: HELPER, lockerBundle: null }).length === 1)
check('a helper that ignores currentCSSZoom is refused',
  checkZoomShim({ viteConfig: CFG, helper: "const METHOD = '__brZoomRect'", lockerBundle: null }).length === 1)
check('a built locker without the shim is refused',
  checkZoomShim({ viteConfig: CFG, helper: HELPER, lockerBundle: 'a.getBoundingClientRect()' }).length === 1)

// --- comments ---------------------------------------------------------------
{
  const src = "a // alert('x')\nconst u = 'https://x/y' // ok\n/* zoom: 2 */ b"
  const out = blankComments(src)
  check('blankComments keeps length and lines', out.length === src.length && out.split('\n').length === 3)
  check('blankComments keeps https:// in a string', out.includes("'https://x/y'") && !out.includes('alert') && !out.includes('zoom'))
}

// --- css-guard --------------------------------------------------------------
{
  const count = (css, re) => (blankGuarded(css, re).match(re) || []).length
  const MIX = /color-mix\(/g
  check('an unguarded color-mix counts', count('.a{color:color-mix(in srgb,red,blue)}', MIX) === 1)
  check('@supports (color: color-mix(...)) hides it, nested parentheses and all',
    count('@supports (color: color-mix(in srgb, red 50%, blue)) { .a { color: color-mix(in srgb, red, blue) } } .b{}', MIX) === 0)
  check('only that block: a use after it still counts',
    count('@supports (color: color-mix(in srgb,red,blue)) { .a{color:color-mix(in srgb,red,blue)} } .b{color:color-mix(in srgb,red,blue)}', MIX) === 1)
  check('@supports not (...) does not guard',
    count('@supports not (color: color-mix(in srgb,red,blue)) { .a{color:color-mix(in srgb,red,blue)} }', MIX) === 2)
  check('an `or` condition does not guard',
    count('@supports (color: color-mix(in srgb,red,blue)) or (display:grid) { .a{color:color-mix(in srgb,red,blue)} }', MIX) === 2)
  check('a block guarded by another feature does not guard this one',
    count('@supports (display: grid) { .a{color:color-mix(in srgb,red,blue)} }', MIX) === 1)
  check('selector(:has()) guards :has()',
    count('@supports selector(:has(a)) { .a:has(b){color:red} }', /:has\(/g) === 0)
  const css = '@supports (color: oklch(0 0 0)) {\n.a{color:oklch(0 0 0)}\n}\n.b{}'
  check('blanking keeps offsets and lines', blankGuarded(css, /oklch\(/g).length === css.length
    && blankGuarded(css, /oklch\(/g).split('\n').length === css.split('\n').length)
}

// --- zoom-rect --------------------------------------------------------------
{
  const out = rewriteRects('const r = el.getBoundingClientRect(); const s = a?.getBoundingClientRect( );', '/h.ts')
  check('every Cloudscape box read is rewritten', out !== null && !out.includes('getBoundingClientRect')
    && (out.match(/__brZoomRect\(\)/g) || []).length === 2, out)
  check('the helper is imported first', out.startsWith('import "/h.ts";'))
  check('a module that measures nothing is left alone', rewriteRects('const a = 1', '/h.ts') === null)
  check('the bound method is not touched', rewriteRects('const f = el.getBoundingClientRect.bind(el)', '/h.ts') === null)
  check('Cloudscape modules are matched (Windows and POSIX)',
    isCloudscape('C:/x/node_modules/@cloudscape-design/components/dropdown/dropdown-fit-handler.js')
    && isCloudscape('/x/node_modules/@cloudscape-design/component-toolkit/mjs/internal/direction/index.js')
    && isCloudscape('C:\\x\\node_modules\\@cloudscape-design\\components\\popover\\utils\\positions.js?v=1'))
  check('our own code and other packages are not',
    !isCloudscape('C:/x/ui-src/src/screens/lockerv2/scope.ts')
    && !isCloudscape('/x/node_modules/framer-motion/dist/es/index.mjs')
    && !isCloudscape('/x/node_modules/@cloudscape-design/components/internal/base-component/styles.scoped.css'))
}

// --- coalesce: the locker spin ----------------------------------------------
{
  const sent = []
  const waiting = []
  const acc = oneInFlight((total) => {
    sent.push(total)
    return new Promise((resolve) => waiting.push(resolve))
  })
  acc.add(4)
  acc.add(2); acc.add(-1); acc.add(0); acc.add(Number.NaN); acc.add(3)
  check('the first delta goes at once, the rest wait', JSON.stringify(sent) === '[4]', JSON.stringify(sent))
  waiting.shift()()
  await Promise.resolve(); await Promise.resolve()
  check('the answer releases the sum of what waited, as one request', JSON.stringify(sent) === '[4,4]', JSON.stringify(sent))
  waiting.shift()()
  await Promise.resolve(); await Promise.resolve()
  check('nothing more goes when nothing is owed', sent.length === 2)
  acc.add(-5)
  check('the next delta goes at once again', JSON.stringify(sent) === '[4,4,-5]')
  const total = sent.reduce((a, b) => a + b, 0)
  check('no rotation is lost', total === 4 + 2 - 1 + 3 - 5, String(total))
}
{
  const sent = []
  let reject
  const acc = oneInFlight((t) => { sent.push(t); return new Promise((_, r) => { reject = r }) })
  acc.add(1); acc.add(2)
  reject(new Error('timeout'))
  await Promise.resolve(); await Promise.resolve()
  check('a failed request still lets the next one go', JSON.stringify(sent) === '[1,2]', JSON.stringify(sent))
}

// --- coalesce: the error gate -----------------------------------------------
{
  const g = createErrorGate(3, 60_000)
  check('a first report goes', g.admit('cb|timeout', 0) === true)
  check('the same report within the minute is held', g.admit('cb|timeout', 10) === false)
  check('another report goes', g.admit('cb|other', 20) === true)
  check('a third goes', g.admit('render|x', 30) === true)
  check('a fourth kind is over the cap', g.admit('render|y', 40) === false)
  check('what was held is counted once', g.takeHeld() === 2 && g.takeHeld() === 0)
  check('a new minute opens again', g.admit('render|y', 60_040) === true)
  check('and the same report goes again a minute after it went', g.admit('cb|timeout', 60_050) === true)
  check('within the new minute it is held again', g.admit('cb|timeout', 60_060) === false)
}

if (failed > 0) {
  console.error(`\ntest-cef: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-cef: ok, ${ran} checks`)
