#!/usr/bin/env node
/**
 * THE TERMINAL APP'S GATE (#396): what #385 found about Cloudscape on CEF 103,
 * and the copy rule, held over ui-src/terminal and its build.
 *
 * check-css.mjs already fails the build on any color CEF 103 cannot parse and
 * reports Cloudscape's :has() rules as the warnings they are. These are the
 * findings it cannot see, each a way the app would work in a desktop browser
 * and fail in the game:
 *
 *   T1 spinner     Cloudscape's Spinner animates forever, disableMotion or not,
 *                  and each frame it animates repaints the NUI over the game.
 *                  No Spinner, no `loading`, no spinning status types.
 *   T2 components  Steps (subgrid, Chrome 117), AppLayoutToolbar, Link (a real
 *                  target=_blank anchor), CopyToClipboard (no clipboard in
 *                  NUI) and the file inputs (fivem#3091) are not imported.
 *                  AppLayout and SideNavigation ARE, since 2026-10-05: #385
 *                  banned AppLayout for painting an opaque page OVER THE GAME,
 *                  and this app's page is inside the computer's window, where
 *                  an opaque page is what a browser shows (the owner asked for
 *                  one); SideNavigation's 103 problem is only its collapsed
 *                  mode, which the app never turns on.
 *   T3 mode        applyMode never targets <html>; the color-scheme rule
 *                  global-styles keys off it would black out the game on CEF 105+.
 *   T4 scheme      the built CSS pins html{color-scheme:normal!important}.
 *   T5 one bundle  no dynamic import() and no importMessages (i18n's dynamic
 *                  loader); the output is index.html, one script, one stylesheet.
 *   T6 copy        no words in the JSX. Every player-facing line is a key into
 *                  br_core's copy block (br_lib/config/terminals.lua); text
 *                  written between two tags here is a line the owner never saw.
 *   T7 speaker     every line goes through ONE picker, model.ts's `speaker`,
 *                  which reads a line's `_solo` sibling outside a squad match
 *                  (owner, 2026-10-05, round 2: "squad" only in a squad
 *                  match). A component that indexes the copy, or a `line`
 *                  helper that bypasses the speaker, fails.
 *   T8 risk        the Run button's colors are the risk badge's own tokens
 *                  (terminal.css): every Cloudscape variable it names must be
 *                  defined in the built CSS, or a Cloudscape bump would leave
 *                  Run on its fallback while the badge moved.
 *   T9 chrome      the browser around the site looks the same in both modes
 *                  (round 2): Browser.tsx takes no Cloudscape control (whose
 *                  colors are the mode's), terminal.css gives the toolbar no
 *                  per-mode rule, and nothing tells the desktop the mode.
 *   T10 page loads every navigation but back and forward loads for 1-3 s
 *                  (owner, 2026-10-06), and the tab's loading symbol is the
 *                  one animation anywhere in the computer's own styles: in
 *                  br.css only under .br-loading, never paused in place, and
 *                  terminal.css animates nothing -- T1's rule, that nothing
 *                  may animate forever, for the symbol that replaces a
 *                  Spinner. The one other (round 4): the storm's close's
 *                  CRT power-off, in br.css only under .br-crt, run once for
 *                  br.js's CRT_MS, on the blue screen br.js removes from the
 *                  page when it ends (and when an opening comes first).
 *                  In App.tsx back and forward step the history at
 *                  once (model.ts `step`), reload loads (`nav`), and nothing
 *                  pushes a page but a load's end (`arrive`). br.js takes the
 *                  class off on every way out, and caps how long it stays.
 *                  What they do is test-terminal-model.mjs's and
 *                  test-terminal-desktop.mjs's.
 *   T11 depth      shadows on surfaces only, and never on text (owner,
 *                  2026-10-06: "not sure why these buttons have shadows",
 *                  and "If they don't have shadows on the text we shouldn't
 *                  either"). terminal.css draws a box-shadow in ONE rule,
 *                  whose selectors are SURFACES below -- every one of them,
 *                  and nothing else -- and none names a control; no other
 *                  shadow property is set; the sources set no boxShadow or
 *                  textShadow; and every text-shadow in the built CSS is
 *                  `none` (Cloudscape's own resets). And Cloudscape's own
 *                  shades: every box-shadow in the built CSS that is offset
 *                  or blurred, its tokens resolved, is placed by the class it
 *                  is on (and the Cloudscape component that owns the class)
 *                  as a surface (STOCK_SURFACES) or a control, and every
 *                  control's is taken off by terminal.css's one
 *                  `box-shadow: none` rule, which names nothing else (the
 *                  preferences' toggle knobs kept a 1 px shade until this).
 *   T12 volts      every Volts amount and every mention of the word in the
 *                  Volts style -- the Volts gold (round 4), in the page's own
 *                  font (round 5) -- drawn by Volts.tsx and composed nowhere
 *                  else: a closed list of the reads of the currency's word
 *                  and a Volts figure (see T12 below).
 *   T13 squads     "Squads!" only on a squadWide row and only in a squad
 *                  match, by the state's own squadMatch (round 4).
 *   T14 home       Home has the five filters and no text search of its own
 *                  (owner, 2026-10-06, round 5: "please remove the search bar
 *                  within the Functions (soon to be "Tools") section - we have
 *                  a search at the top anyway. Just the filters can remain."):
 *                  no TextFilter, the five Selects, and the top bar's search
 *                  still there and still finding a tool.
 *   T15 wrap       a status wraps between its words (owner, 2026-10-07,
 *                  round 7: "can you wrap this text better?" -- a card read
 *                  "No armed opponent" then "s"): every `word-break:
 *                  break-all` in the built CSS (Cloudscape's StatusIndicator)
 *                  is taken off by terminal.css's one `word-break: normal
 *                  !important` rule, which names nothing else.
 *
 * STATIC, LIKE check-ui.mjs. It reads source with comments and strings
 * blanked, so prose that names a banned thing never trips it.
 *
 * Run: npm run build:terminal (and so npm run build).
 */

import { existsSync, readFileSync, readdirSync, statSync } from 'node:fs'
import { dirname, extname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const SRC = join(ROOT, 'terminal')
const OUT = join(ROOT, '..', 'resources', '[computer]', 'cuchi_computer', 'nui', 'apps', 'terminal')

let failures = 0
const rel = (f) => relative(ROOT, f).replace(/\\/g, '/')
function fail(rule, file, msg) {
  failures++
  console.error(`check-terminal FAIL  [${rule}] ${file}\n                     ${msg}`)
}

function walk(dir, out = []) {
  if (!existsSync(dir)) return out
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}

/** Comments blanked; with `strings`, string and template bodies blanked too. */
function code(text, strings) {
  let out = ''
  let i = 0
  while (i < text.length) {
    const c = text[i]
    const n = text[i + 1]
    if (c === '/' && n === '/') {
      while (i < text.length && text[i] !== '\n') { out += ' '; i++ }
    } else if (c === '/' && n === '*') {
      const end = text.indexOf('*/', i + 2)
      const stop = end < 0 ? text.length : end + 2
      out += text.slice(i, stop).replace(/[^\n]/g, ' ')
      i = stop
    } else if (c === '"' || c === "'" || c === '`') {
      let j = i + 1
      while (j < text.length && text[j] !== c) j += text[j] === '\\' ? 2 : 1
      const body = text.slice(i + 1, j)
      out += c + (strings ? body.replace(/[^\n]/g, ' ') : body) + (j < text.length ? c : '')
      i = j + 1
    } else {
      out += c
      i++
    }
  }
  return out
}

/**
 * Comments and every string's text blanked, but a template's `${...}` kept as
 * code -- `${f.cost} ${currency}` is two reads, which code(text, true) would
 * blank with the rest of the template (T12 (e)).
 */
function codeOnly(text) {
  let out = ''
  const holes = [] // for each open `${`: the braces opened inside it
  let inTemplate = false
  let i = 0
  while (i < text.length) {
    const c = text[i]
    const n = text[i + 1]
    if (inTemplate) {
      if (c === '\\') {
        out += text.slice(i, i + 2).replace(/[^\n]/g, ' ')
        i += 2
      } else if (c === '`') {
        out += c
        inTemplate = false
        i++
      } else if (c === '$' && n === '{') {
        out += '${'
        holes.push(0)
        inTemplate = false
        i += 2
      } else {
        out += c === '\n' ? '\n' : ' '
        i++
      }
    } else if (c === '/' && n === '/') {
      while (i < text.length && text[i] !== '\n') { out += ' '; i++ }
    } else if (c === '/' && n === '*') {
      const end = text.indexOf('*/', i + 2)
      const stop = end < 0 ? text.length : end + 2
      out += text.slice(i, stop).replace(/[^\n]/g, ' ')
      i = stop
    } else if (c === '"' || c === "'") {
      let j = i + 1
      while (j < text.length && text[j] !== c) j += text[j] === '\\' ? 2 : 1
      out += c + text.slice(i + 1, j).replace(/[^\n]/g, ' ') + (j < text.length ? c : '')
      i = j + 1
    } else if (c === '`') {
      out += c
      inTemplate = true
      i++
    } else if (c === '{' && holes.length > 0) {
      holes[holes.length - 1]++
      out += c
      i++
    } else if (c === '}' && holes.length > 0) {
      if (holes[holes.length - 1] === 0) {
        holes.pop()
        inTemplate = true
      } else {
        holes[holes.length - 1]--
      }
      out += c
      i++
    } else {
      out += c
      i++
    }
  }
  return out
}

/** The innermost bracket open around `at`: { ch, at }, or null. */
function opener(t, at) {
  let depth = 0
  for (let i = at - 1; i >= 0; i--) {
    const c = t[i]
    if (c === ')' || c === ']' || c === '}') depth++
    else if (c === '(' || c === '[' || c === '{') {
      if (depth === 0) return { ch: c, at: i }
      depth--
    }
  }
  return null
}

/** Where the bracket open at `at` closes, or -1. */
function closer(t, at) {
  let depth = 0
  for (let i = at; i < t.length; i++) {
    const c = t[i]
    if (c === '(' || c === '[' || c === '{') depth++
    else if (c === ')' || c === ']' || c === '}') {
      depth--
      if (depth === 0) return i
    }
  }
  return -1
}

/** The name called by the `(` at `at`, or ''. */
function calleeAt(t, at) {
  return /([\w$]+)\s*$/.exec(t.slice(Math.max(0, at - 80), at))?.[1] ?? ''
}

/** Every object pattern a name is bound by: `const { a, b } = x`, `({ a }: P)`, `({ a }) =>`. */
function patterns(t) {
  const out = []
  for (const m of t.matchAll(/\{[^{}]*\}/g)) {
    const before = t.slice(Math.max(0, m.index - 20), m.index)
    const after = t.slice(m.index + m[0].length, m.index + m[0].length + 20)
    const binding = /\b(const|let|var)\s*$/.test(before) && /^\s*(=(?![=>])|of\b|in\b)/.test(after)
    const param = /[(,]\s*$/.test(before) && /^\s*(:|\)\s*=>|=(?![=>]))/.test(after)
    if (binding || param) out.push({ at: m.index, text: m[0] })
  }
  return out
}

/** Is the name at `at` one bound by a plain pattern: `const { ..., name } = x` or `({ ..., name }: P)`? */
function destructured(t, at) {
  const o = opener(t, at)
  if (!o || o.ch !== '{') return false
  const close = closer(t, o.at)
  if (close < 0 || !/^\{[\s\w$,]*\}$/.test(t.slice(o.at, close + 1))) return false
  const before = t.slice(0, o.at)
  const after = t.slice(close + 1)
  return (/\b(const|let)\s*$/.test(before) && /^\s*=(?![=>])/.test(after)) || (/\(\s*$/.test(before) && /^\s*:/.test(after))
}

/** Every template `${...}`'s code: { at, text }. */
function interpolations(t) {
  const out = []
  for (let i = t.indexOf('${'); i >= 0; i = t.indexOf('${', i + 2)) {
    const close = closer(t, i + 1)
    out.push({ at: i, text: t.slice(i + 2, close < 0 ? t.length : close) })
  }
  return out
}

const sources = walk(SRC).filter((f) => ['.ts', '.tsx'].includes(extname(f)))
if (sources.length === 0) fail('setup', 'terminal/', 'no sources found -- a gate that reads nothing passes everything')

const BANNED = {
  spinner: 'T1 spinner',
  steps: 'T2 components',
  'app-layout-toolbar': 'T2 components',
  link: 'T2 components',
  'copy-to-clipboard': 'T2 components',
  'file-upload': 'T2 components',
  'file-input': 'T2 components',
  'file-dropzone': 'T2 components',
}

for (const f of sources) {
  const raw = readFileSync(f, 'utf8')
  const withStrings = code(raw, false)
  const bare = code(raw, true)

  for (const m of withStrings.matchAll(/from\s+['"]@cloudscape-design\/components(?:\/([a-z-]+))?['"]/g)) {
    if (m[1] === undefined) {
      fail('T2 components', rel(f), 'imports the package root -- import each component by its path')
    } else if (BANNED[m[1]]) {
      fail(BANNED[m[1]], rel(f), `imports @cloudscape-design/components/${m[1]}`)
    }
  }
  if (/\bloading\s*(=|:)/.test(bare)) fail('T1 spinner', rel(f), 'sets `loading` -- disable the control instead')
  if (/type\s*=\s*\{?\s*['"](loading|in-progress)['"]/.test(withStrings)) {
    fail('T1 spinner', rel(f), 'a status type that spins')
  }
  if (/applyMode\s*\([^)]*documentElement/.test(bare)) {
    fail('T3 mode', rel(f), 'applyMode on document.documentElement -- leave the target as <body>')
  }
  if (/\bimport\s*\(/.test(bare)) fail('T5 one bundle', rel(f), 'dynamic import()')
  if (/\bimportMessages\b/.test(bare)) fail('T5 one bundle', rel(f), 'importMessages loads its messages dynamically')

  if (extname(f) === '.tsx') {
    for (const m of bare.matchAll(/>([^<>{}]*)<\//g)) {
      const text = m[1].trim()
      if (/[A-Za-z]/.test(text)) {
        fail('T6 copy', rel(f), `"${text}" is written in the JSX -- make it a key into br_core's copy`)
      }
    }
    // T7: the copy is read through the speaker and nowhere else.
    if (/\bcopy\s*(\[|\.|\?\.)/.test(bare)) {
      fail('T7 speaker', rel(f), 'reads the copy directly -- every line goes through model.ts speaker')
    }
    if (/\bline\s*\(/.test(bare)) {
      fail('T7 speaker', rel(f), 'calls line() -- every line goes through model.ts speaker')
    }
  }
  if (rel(f).endsWith('/model.ts') && /export\s+function\s+line\b/.test(bare)) {
    fail('T7 speaker', rel(f), 'exports a line() reader beside the speaker -- one picker')
  }
  if (/type:\s*'mode'/.test(withStrings)) {
    fail('T9 chrome', rel(f), 'tells the desktop the mode -- the browser around the site has one look')
  }
}

// T7: the speaker exists, and picks the solo sibling.
{
  const model = readFileSync(join(SRC, 'src', 'model.ts'), 'utf8')
  if (!/export function speaker\(copy: Copy, squadMatch: boolean\): Say/.test(model)
      || !model.includes('copy[`${key}_solo`]')) {
    fail('T7 speaker', 'terminal/src/model.ts', 'no speaker(copy, squadMatch) reading `${key}_solo`')
  }
}

// T9: the browser's toolbar is the app's own drawing, in fixed colors.
{
  const browser = readFileSync(join(SRC, 'src', 'Browser.tsx'), 'utf8')
  for (const m of code(browser, false).matchAll(/from\s+['"]@cloudscape-design\/components\/([a-z-]+)['"]/g)) {
    if (m[1] !== 'icon') fail('T9 chrome', 'terminal/src/Browser.tsx', `imports ${m[1]} -- its colors follow the mode`)
  }
  const css = readFileSync(join(SRC, 'src', 'terminal.css'), 'utf8')
  if (/awsui-dark-mode[^{]*\.browser-/.test(code(css, false))) {
    fail('T9 chrome', 'terminal/src/terminal.css', 'a .browser- rule per mode -- the toolbar has one look')
  }
}

// T10: the page loads and the tab's symbol.
{
  const app = code(readFileSync(join(SRC, 'src', 'App.tsx'), 'utf8'), false)
  const browse = /const browse = \(dir: 'back' \| 'forward'\) => \{([\s\S]*?)\n  \}/.exec(app)?.[1] ?? ''
  if (!/\bstep\(/.test(browse) || /\bnavigate\(|setTimeout/.test(browse)) {
    fail('T10 page loads', 'terminal/src/App.tsx', 'back and forward must step the history at once (model.ts step), never load')
  }
  if (!/onBack=\{\(\) => browse\('back'\)\}/.test(app) || !/onForward=\{\(\) => browse\('forward'\)\}/.test(app)) {
    fail('T10 page loads', 'terminal/src/App.tsx', 'the back and forward buttons are not browse(\'back\') and browse(\'forward\')')
  }
  if (!/onReload=\{\(\) => nav\(\{ kind: 'reload' \}\)\}/.test(app)) {
    fail('T10 page loads', 'terminal/src/App.tsx', 'the reload button does not load (nav({ kind: \'reload\' }))')
  }
  if (/(?<![.\w])(push|back|forward|replace|startHistory)\(/.test(app)) {
    fail('T10 page loads', 'terminal/src/App.tsx', 'moves the history itself -- every page change goes through navigate, arrive, step or rewrite')
  }
  if (!/loadMs\(catalog\.pageLoad, Math\.random\)/.test(app)) {
    fail('T10 page loads', 'terminal/src/App.tsx', 'a load\'s length is not a fresh loadMs pick in the catalog\'s range')
  }
  const own = code(readFileSync(join(SRC, 'src', 'terminal.css'), 'utf8'), false)
  if (/\banimation\b|@keyframes/.test(own)) {
    fail('T10 page loads', 'terminal/src/terminal.css', 'animates something -- the app\'s only moving thing is the tab\'s symbol, in br.css')
  }
  const brCss = readFileSync(join(ROOT, '..', 'resources', '[computer]', 'cuchi_computer', 'nui', 'br.css'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
  const brJs = code(readFileSync(join(ROOT, '..', 'resources', '[computer]', 'cuchi_computer', 'nui', 'br.js'), 'utf8'), false)
  // Round 4 adds the one other thing allowed to move: the storm's close's CRT
  // power-off, under .br-crt -- on the blue screen br.js REMOVES from the page
  // when it ends -- run once, for br.js's CRT_MS.
  const crtMs = Number(/const CRT_MS = (\d+);/.exec(brJs)?.[1])
  for (const m of brCss.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (!/(^|[;\s])animation(-name)?\s*:/.test(m[2])) continue
    // Every selector in the list must need the class, so a :not() is taken out
    // first: `:not(.br-loading)` names the class and animates everything else.
    const needs = (cls) => m[1].split(',')
      .every((s) => new RegExp(`\\.${cls}(?![\\w-])`).test(s.replace(/:not\([^()]*\)/g, ' ')))
    if (needs('br-crt')) {
      const run = /animation\s*:([^;]*)/.exec(m[2])?.[1] ?? ''
      const secs = Number(/(?:^|\s)(\d*\.?\d+)s(?:\s|$)/.exec(run)?.[1])
      if (/infinite/.test(m[2]) || !/(?:^|\s)1(?:\s|$)/.test(run)) {
        fail('T10 page loads', 'cuchi_computer/nui/br.css', `${m[1].trim()}: the CRT power-off must run once (iteration 1, never infinite)`)
      }
      if (!Number.isFinite(crtMs) || Math.round(secs * 1000) !== crtMs) {
        fail('T10 page loads', 'cuchi_computer/nui/br.css', `${m[1].trim()} runs ${secs}s, not br.js CRT_MS (${crtMs} ms)`)
      }
    } else if (!needs('br-loading')) {
      fail('T10 page loads', 'cuchi_computer/nui/br.css', `${m[1].trim()} animates outside .br-loading and .br-crt`)
    }
  }
  if (/animation-play-state/.test(brCss)) {
    fail('T10 page loads', 'cuchi_computer/nui/br.css', 'pauses an animation in place -- take its class off instead')
  }
  // The storm's blue screen: taken off the page when the CRT has run, and by
  // an opening that arrives first -- its animation never outlives it.
  const dropBlue = /const dropBlue = \(tell\) => \{([\s\S]*?)\n    \};/.exec(brJs)?.[1] ?? ''
  if (!/removeChild\(blue\.el\)/.test(dropBlue) || !/setTimeout\(\(\) => dropBlue\(true\), CRT_MS\)/.test(brJs)
      || !/const open = \(msg\) => \{[^}]*?dropBlue\(false\);/.test(brJs)) {
    fail('T10 page loads', 'cuchi_computer/nui/br.js', 'the storm\'s blue screen is not removed from the page after CRT_MS and by an opening -- its animation would outlive it')
  }
  const unload = /const unload = \(\) => \{([\s\S]*?)\n    \};/.exec(brJs)?.[1] ?? ''
  if (!/tabLoading\(null\)/.test(unload)) {
    fail('T10 page loads', 'cuchi_computer/nui/br.js', 'unloading the app (its window\'s close, the computer\'s) leaves the tab\'s symbol on')
  }
  if (!/const TAB_LOAD_MAX_MS = \d+;/.test(brJs) || !/tabTimer = setTimeout\(/.test(brJs)) {
    fail('T10 page loads', 'cuchi_computer/nui/br.js', 'no backstop: an app that never says the page showed would leave the symbol spinning')
  }
}

// T11: the depth. THE SURFACES are the parts the page is built of (terminal.css
// says which is which); a control is anything that sits on one.
const SURFACES = [
  '.terminal-topnav',
  '.terminal-nav',
  '.terminal-raised',
  '.terminal-login',
  '.terminal-cards [class*="awsui_header-variant-cards"]',
  '.terminal-cards li[class*="awsui_card_"] > div',
  '[class*="awsui_dialog_"] [class*="awsui_container_"]',
  '.terminal [class*="awsui_flash-type-"]',
]
// A selector or class naming any of these reaches a control. `awsui_flash_` is
// the progress bar's class as much as the flash's (round 2's rule shadowed the
// bar through it); the flash itself is `awsui_flash-type-`. A handle is a
// toggle's knob or a drag handle; a stacked Flashbar's notification bar is a
// button the width of the stack.
const CONTROL = /button|badge|progress|input|toggle|pagination|radio|checkbox|select|segmented|icon|utility|trigger|link|handle|notification-bar|awsui_flash_/i
// The only shadow-valued properties terminal.css may set besides the one rule's
// box-shadow: the two values per mode.
const SHADOW_VALUES = new Set(['--terminal-raise', '--terminal-raise-strong'])
// What Cloudscape shades itself and is a surface: it floats over the page or
// is a part the page is built of. Keyed by the Cloudscape component that owns
// the class (its directory in @cloudscape-design/components) and the class.
// Every other Cloudscape shade in the build is a control's, and terminal.css's
// `box-shadow: none` rule must take it off.
const STOCK_SURFACES = {
  'popover/container-body': 'a popover, which floats',
  'popover/arrow-outer': 'a popover\'s tail',
  'dropdown/dropdown-content-wrapper': 'a dropdown (the search\'s, the user menu\'s), which floats',
  'modal/container': 'the dialog',
  'container/root': 'a container',
  'container/header-variant-cards': 'the cards\' heading block',
  'container/header-stuck': 'a container\'s heading once it sticks',
  'container/header-variant-full-page': 'a full-page heading once it sticks',
  'flashbar/flash': 'a flash (and each flash in a collapsed stack)',
  'app-layout/visual-refresh/mobile-toolbar': 'the layout\'s bar on a narrow page',
  'app-layout/visual-refresh/split-panel-bottom': 'a split panel',
  'internal/components/sortable-area/drag-overlay': 'an item being dragged',
}
// Filled from terminal.css's one `box-shadow: none` rule: the class names whose
// Cloudscape shade it takes off, as `class` or `class::after`.
const RESETS = []
/** `[class*=awsui_<class>_]` (quotes taken out), with any pseudo-element, as `class` or `class::after`; else null. */
function resetName(selector) {
  const m = /^\[class\*=awsui_([a-z0-9-]+)_\](::?(?:before|after))?$/.exec(selector)
  return m ? m[1] + (m[2] ? m[2].replace(/^:+/, '::') : '') : null
}
const resetSelector = (name) => {
  const [cls, pseudo] = name.split('::')
  return `[class*="awsui_${cls}_"]${pseudo ? `::${pseudo}` : ''}`
}
{
  for (const s of SURFACES) {
    if (CONTROL.test(s)) fail('T11 depth', 'scripts/check-terminal.mjs', `the surface ${s} names a control`)
  }
  for (const k of Object.keys(STOCK_SURFACES)) {
    if (CONTROL.test(k.split('/').pop())) fail('T11 depth', 'scripts/check-terminal.mjs', `the stock surface ${k} is a control`)
  }
  const css = code(readFileSync(join(SRC, 'src', 'terminal.css'), 'utf8'), false)
  const shadowRules = []
  const resetRules = []
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = m[1].split(',').map((s) => s.trim().replace(/\s+/g, ' ')).filter((s) => s !== '')
    for (const d of m[2].split(';')) {
      const colon = d.indexOf(':')
      if (colon < 0) continue
      const prop = d.slice(0, colon).trim().toLowerCase()
      const value = d.slice(colon + 1).replace(/!important/i, '').trim()
      if (prop === 'text-shadow' && value !== 'none') {
        fail('T11 depth', 'terminal/src/terminal.css', `${selectors.join(', ')} gives text a shadow -- no text has one`)
      } else if (prop === 'box-shadow' && value !== 'none') {
        shadowRules.push(selectors)
      } else if (prop === 'box-shadow') {
        resetRules.push(selectors)
      } else if (/shadow/.test(prop) && prop !== 'text-shadow' && prop !== 'box-shadow' && !SHADOW_VALUES.has(prop)) {
        fail('T11 depth', 'terminal/src/terminal.css', `${selectors.join(', ')} sets ${prop} -- a shadow by another name`)
      }
    }
  }
  if (shadowRules.length !== 1) {
    fail('T11 depth', 'terminal/src/terminal.css', `${shadowRules.length} rules draw a box-shadow -- the surfaces are one rule`)
  }
  for (const selectors of shadowRules) {
    for (const s of selectors) {
      if (CONTROL.test(s)) fail('T11 depth', 'terminal/src/terminal.css', `${s} puts a box-shadow on a control`)
      else if (!SURFACES.includes(s)) fail('T11 depth', 'terminal/src/terminal.css', `${s} has a box-shadow and is not a surface`)
    }
  }
  const drawn = shadowRules.flat()
  for (const s of SURFACES) {
    if (!drawn.includes(s)) fail('T11 depth', 'terminal/src/terminal.css', `the surface ${s} lost its shadow`)
  }
  // The one rule that takes a shadow away names Cloudscape's shaded controls by
  // class, and nothing else.
  if (resetRules.length > 1) {
    fail('T11 depth', 'terminal/src/terminal.css', `${resetRules.length} rules set box-shadow: none -- the controls Cloudscape shades are one rule`)
  }
  for (const s of resetRules.flat()) {
    const name = resetName(s.replace(/"/g, ''))
    if (name === null) {
      fail('T11 depth', 'terminal/src/terminal.css', `${s} takes a shadow away but is not [class*="awsui_<class>_"] -- the rule names Cloudscape's classes`)
    } else if (!CONTROL.test(name.split('::')[0])) {
      fail('T11 depth', 'terminal/src/terminal.css', `${s} takes a shadow away from what is not a control`)
    } else {
      RESETS.push(name)
    }
  }
  for (const f of sources) {
    if (/\b(boxShadow|textShadow)\b/.test(code(readFileSync(f, 'utf8'), false))) {
      fail('T11 depth', rel(f), 'sets a boxShadow or textShadow -- shadows are terminal.css\'s, on surfaces only')
    }
  }
}

// T11 over Cloudscape's own CSS: which of its box-shadows shade, and on what.

/** `text` split on `sep` outside parentheses and brackets. */
function topSplit(text, sep) {
  const out = []
  let depth = 0
  let start = 0
  for (let i = 0; i < text.length; i++) {
    const c = text[i]
    if (c === '(' || c === '[') depth++
    else if (c === ')' || c === ']') depth--
    else if (c === sep && depth === 0) {
      out.push(text.slice(start, i))
      start = i + 1
    }
  }
  out.push(text.slice(start))
  return out.map((s) => s.trim()).filter((s) => s !== '')
}

/**
 * Every value `value` can compute to, each var() resolved every way the CSS
 * allows: through each definition of the token anywhere in the sheet, and
 * through its fallback where it is not set. null is a value that computes to
 * nothing (a token never set, with no fallback), which for box-shadow is none.
 */
function computedValues(value, tokens, depth = 0) {
  const at = value.indexOf('var(')
  if (at < 0 || depth > 16) return [value]
  let level = 0
  let end = at + 3
  for (; end < value.length; end++) {
    if (value[end] === '(') level++
    else if (value[end] === ')' && --level === 0) break
  }
  const inner = value.slice(at + 4, end)
  const comma = inner.indexOf(',')
  const name = (comma < 0 ? inner : inner.slice(0, comma)).trim()
  const fallback = comma < 0 ? null : inner.slice(comma + 1).trim()
  const ways = []
  for (const def of tokens.get(name) ?? []) {
    for (const r of computedValues(def, tokens, depth + 1)) ways.push(r === null ? fallback : r)
  }
  ways.push(fallback)
  const out = new Set()
  for (const w of ways) {
    if (w === null) out.add(null)
    else for (const r of computedValues(value.slice(0, at) + w + value.slice(end + 1), tokens, depth + 1)) out.add(r)
  }
  return [...out]
}

/**
 * A SHADE: a layer offset or blurred off its box, or blurred inside it. A
 * spread with no offset or blur is a ring (Cloudscape's focus ring, a control's
 * edge) and an inset with no blur is a line (a dropdown option's divider);
 * neither is a shadow. A value that is not a shadow at all (Cloudscape's input
 * falls back to a bare token name) is invalid, and computes to none.
 */
function shades(value) {
  if (value === null) return false
  const v = value.replace(/!important/i, '').trim()
  if (/^(none|initial|unset|inherit|revert|)$/i.test(v)) return false
  const layers = topSplit(v, ',').map((layer) => {
    const parts = layer
      .replace(/\b(?:rgba?|hsla?)\([^()]*\)/gi, ' color ')
      .replace(/calc\((?:[^()]|\([^()]*\))*\)/gi, ' 1px ')
      .split(/\s+/)
      .filter((p) => p !== '')
    const lengths = []
    let inset = false
    for (const p of parts) {
      if (/^inset$/i.test(p)) inset = true
      else if (/^-?(?:\d*\.)?\d+[a-z%]*$/i.test(p)) lengths.push(parseFloat(p))
      else if (!/^#[0-9a-f]{3,8}$/i.test(p) && !/^[a-z]+$/i.test(p)) return null
    }
    return lengths.length < 2 || lengths.length > 4
      ? null
      : { inset, x: lengths[0], y: lengths[1], blur: lengths[2] ?? 0 }
  })
  if (layers.some((l) => l === null)) return false
  return layers.some((l) => (l.inset ? l.blur !== 0 : l.x !== 0 || l.y !== 0 || l.blur !== 0))
}

/** The Cloudscape component that owns each class name: its directory, then the class. */
function cloudscapeOwners() {
  const root = join(ROOT, 'node_modules', '@cloudscape-design', 'components')
  const owners = new Map()
  const visit = (dir) => {
    for (const e of readdirSync(dir, { withFileTypes: true })) {
      const p = join(dir, e.name)
      if (e.isDirectory()) visit(p)
      else if (e.name === 'styles.css.js') {
        const owner = relative(root, dir).replace(/\\/g, '/')
        for (const m of readFileSync(p, 'utf8').matchAll(/"([a-z0-9-]+)":\s*"(awsui_[a-z0-9_-]+)"/g)) {
          owners.set(m[2], `${owner}/${m[1]}`)
        }
      }
    }
  }
  if (existsSync(root)) visit(root)
  return owners
}

/** The box a selector styles: its last compound, `:not()`s dropped, and its pseudo-element. */
function subject(selector) {
  let s = selector
  for (let prev = ''; prev !== s;) {
    prev = s
    s = s.replace(/:not\([^()]*\)/g, '')
  }
  const compounds = s.split(/\s*[>+~]\s*|\s+/).filter((c) => c !== '')
  const last = compounds[compounds.length - 1] ?? ''
  const classes = [...last.matchAll(/\.(awsui_[a-z0-9_-]+?_[a-z0-9]{5}_[a-z0-9]{5}_\d+)/g)].map((m) => m[1])
  const pseudo = /::?(before|after)\b/.exec(last)?.[1]
  return { classes, pseudo: pseudo ? `::${pseudo}` : '' }
}

// T12: VOLTS IN THE VOLTS STYLE (owner, 2026-10-06, round 4: "Any mention of
// volts must use our proper font for that and the gold color"; round 5, the
// same day: "change the volts text once more, but this time back to the
// standard font for the browser instead of our volts font").
//
//   (a) a Volts amount is drawn by Volts.tsx (VoltsAmount, voltsLine,
//       voltsLines) and nowhere else: voltsText() -- the figure and the word
//       as a bare string -- is called only by model.ts and Volts.tsx, and once
//       by App.tsx for the top bar's balance, a TopNavigation utility's string,
//       which must be the bar's FIRST utility while App.tsx marks the bar
//       `terminal-topnav-volts`
//   (b) no fill() fills a Volts token ({volts}, {cost}, {balance}) or the
//       currency's word as text
//   (c) every line of the copy block that says Volts -- a Volts token, or the
//       currency's word (config/market.lua) -- is read only as
//       voltsLine(say(...)) or voltsLines(say(...)), by its key or, for a
//       function's own `<id>_<part>` line, by the template that reads it;
//       every such line is one it SEES read so (a Volts option label, read
//       by a template it cannot follow, fails); and the reader reads every
//       line of the block (a line written any other way than `key = '...',`
//       would be one it skips)
//   (d) the style is the Volts gold in the page's own font: `.terminal-volts`
//       and the top bar's utility in `--terminal-volts-color`, which is
//       br_ui's `--color-volts`, and NOTHING ELSE -- no font, weight, style
//       or spacing of their own, so a Volts amount is written in the text
//       around it -- and no face bundled for it: no @font-face in
//       terminal.css, and none and no font file in the build (its half is in
//       "The build", below)
//   (e) NOTHING ELSE COMPOSES ONE (review of round 4: `${f.cost} ${currency}`
//       and `<span>{f.cost.toLocaleString()} {currency}</span>` both got
//       past (a)-(d)). Outside model.ts and Volts.tsx, the currency's word
//       (`currency`, `.currency`) and a Volts figure (`.cost`, `.volts`,
//       `.balance`) are read ONLY where listed below -- a closed list, so a
//       new way to write one fails until it is one of these: handed to
//       VoltsAmount, voltsLine(s) or voltsText, passed down as
//       `currency={currency}`, compared with 0 or null, or parsed by
//       bridge.ts. No destructuring or ['...'] reads of them, no template,
//       `+`, String() or number formatting of them, and no string that
//       writes the currency's word.
{
  const R = 'T12 volts'
  const OK_TEXT = new Set(['terminal/src/model.ts', 'terminal/src/Volts.tsx'])
  for (const f of sources) {
    const r = rel(f)
    const withStrings = code(readFileSync(f, 'utf8'), false)
    const calls = [...withStrings.matchAll(/\bvoltsText\s*\(/g)].length
    if (r === 'terminal/src/App.tsx') {
      const pushes = [...withStrings.matchAll(/\butilities\.push\(([^\n]*)/g)].map((m) => m[1])
      if (calls !== 1 || !/^\{ type: 'button', text: voltsText\(/.test(pushes[0] ?? '')) {
        fail(R, r, 'voltsText() is App.tsx\'s only for the top bar\'s balance, its first utility -- draw a Volts amount with Volts.tsx')
      }
      if (!/const balanceShown = /.test(withStrings)
          || !/className=\{balanceShown \? 'terminal-topnav terminal-topnav-volts' : 'terminal-topnav'\}/.test(withStrings)) {
        fail(R, r, 'the top bar is not marked terminal-topnav-volts while it shows the balance -- the balance would not be in the Volts style')
      }
    } else if (!OK_TEXT.has(r) && calls > 0) {
      fail(R, r, 'draws a Volts amount with voltsText() -- use Volts.tsx (VoltsAmount, voltsLine)')
    }
    if (r !== 'terminal/src/model.ts') {
      // Each fill( call's own arguments, to its closing parenthesis.
      for (const m of withStrings.matchAll(/\bfill\(/g)) {
        let depth = 1
        let i = m.index + m[0].length
        for (; i < withStrings.length && depth > 0; i++) {
          if (withStrings[i] === '(') depth++
          else if (withStrings[i] === ')') depth--
        }
        if (/\b(volts|cost|balance|currency)\s*[:,}]/.test(withStrings.slice(m.index, i))) {
          fail(R, r, 'fills a Volts token or the currency\'s word with fill() -- voltsLine(text, currency, { volts }) draws it in the Volts style')
        }
      }
    }
  }

  // (c) The copy block's Volts lines, read only through voltsLine(s).
  const cfgDir = join(ROOT, '..', 'resources', '[fivem-royale]', 'br_lib', 'config')
  const lua = readFileSync(join(cfgDir, 'terminals.lua'), 'utf8')
  const currency = /BR\.Config\.Market\.currency\s*=\s*'([^']+)'/.exec(readFileSync(join(cfgDir, 'market.lua'), 'utf8'))?.[1]
  if (!currency) fail(R, 'br_lib/config/market.lua', 'no currency name found -- cannot tell which lines say Volts')
  const ids = [...lua.matchAll(/\{ id = '([a-z][a-z0-9_]*)'/g)].map((m) => m[1])
  const word = new RegExp(`\\b${currency ?? 'Volts'}\\b`)
  const LINE = /^\s+([a-z][a-z0-9_]*) = (['"])(.*)\2,$/
  const voltsKeys = new Set()
  for (const m of lua.matchAll(new RegExp(LINE.source, 'gm'))) {
    if (/\{(volts|cost|balance)\}/.test(m[3]) || word.test(m[3])) voltsKeys.add(m[1].replace(/_solo$/, ''))
  }
  if (!voltsKeys.has('no_volts') || !voltsKeys.has('balance_new')) {
    fail(R, 'br_lib/config/terminals.lua', 'the reader found no Volts lines -- it is broken, not the copy clean')
  }
  // THE READER READS EVERY LINE OF THE COPY BLOCK. A line written any other
  // way is one it would skip, Volts or not: round 4's first build left
  // `offline ='...'` (no space), and the reader read no key with a digit in
  // it (the options' `_60`, `_120`) until the review.
  const block = /^ {4}copy = \{\n([\s\S]*?)^ {4}\},$/m.exec(lua)?.[1]
  if (!block || block.split('\n').length < 100) {
    fail(R, 'br_lib/config/terminals.lua', 'no copy block found -- a reader that reads nothing passes everything')
  }
  for (const l of (block ?? '').split('\n')) {
    if (l.trim() === '' || /^\s*--/.test(l)) continue
    if (!LINE.test(l)) {
      fail(R, 'br_lib/config/terminals.lua', `a copy line the reader cannot read, so would not see Volts in: "${l.trim().slice(0, 60)}" -- write it as key = '...', on one line`)
    }
  }
  const tsx = sources.filter((f) => extname(f) === '.tsx').map((f) => [rel(f), code(readFileSync(f, 'utf8'), false)])
  const wrapped = (text, at) => /volts(Line|Lines)\(\s*$/.test(text.slice(Math.max(0, at - 40), at))
  for (const key of voltsKeys) {
    const id = ids.find((i) => key.startsWith(`${i}_`))
    const reads = [new RegExp(`say\\(\\s*'${key}'\\s*\\)`, 'g')]
    if (id) reads.push(new RegExp(`say\\(\\s*\`[^\`]*\\}${key.slice(id.length)}\`\\s*\\)`, 'g'))
    let seen = 0
    for (const [r, text] of tsx) {
      for (const re of reads) {
        for (const m of text.matchAll(re)) {
          if (!wrapped(text, m.index)) {
            fail(R, r, `${m[0]} says Volts (${key}) but is not read as voltsLine(say(...)) -- its Volts would not be in the Volts style`)
          } else {
            seen++
          }
        }
      }
    }
    // A line that says Volts must be one this rule SEES read through
    // voltsLine(s). One read some other way -- an option's label, by
    // `${id}_opt_${o.id}_${c}` -- would be drawn as plain text, unseen.
    if (seen === 0) {
      fail(R, 'br_lib/config/terminals.lua', `${key} says Volts, but nothing reads it as voltsLine(say('${key}')) or by its function's \`\${id}_<part>\` -- its Volts would not be in the Volts style`)
    }
  }

  // (d) The style itself.
  const volts = readFileSync(join(SRC, 'src', 'Volts.tsx'), 'utf8')
  const drawn = [...code(volts, false).matchAll(/className="terminal-volts"/g)].length
  if (drawn < 2) fail(R, 'terminal/src/Volts.tsx', 'VoltsAmount and voltsLine do not both draw className="terminal-volts"')
  const css = code(readFileSync(join(SRC, 'src', 'terminal.css'), 'utf8'), false)
  const gold = /--color-volts:\s*(#[0-9a-f]{6})/i.exec(readFileSync(join(ROOT, 'src', 'index.css'), 'utf8'))?.[1]
  const own = /--terminal-volts-color:\s*(#[0-9a-f]{6})/i.exec(css)?.[1]
  if (!gold || !own || gold.toLowerCase() !== own.toLowerCase()) {
    fail(R, 'terminal/src/terminal.css', `--terminal-volts-color (${own}) is not br_ui's --color-volts (${gold})`)
  }
  // THE PAGE'S FONT (round 5): no rule that styles a Volts amount -- the
  // Volts rule, or any other naming .terminal-volts or the top bar's balance
  // -- sets a font of its own, and no face is declared for one.
  const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
  const rule = rules.find((m) => m[1].split(',').map((s) => s.trim()).includes('.terminal-volts'))
  const sels = rule ? rule[1].split(',').map((s) => s.trim()) : []
  if (!rule || !/(^|[;\s])color:\s*var\(--terminal-volts-color\)\s*!important/.test(rule[2])) {
    fail(R, 'terminal/src/terminal.css', '.terminal-volts is not in the Volts gold (--terminal-volts-color)')
  } else if (!sels.includes('.terminal-topnav-volts [data-utility-index="0"] button')
      || !sels.includes('.terminal-topnav-volts [data-utility-index="0"] button *')) {
    fail(R, 'terminal/src/terminal.css', 'the top bar\'s balance (its first utility, under .terminal-topnav-volts) is not in the Volts rule')
  }
  const FONT_PROP = /(^|[;\s])(font(-family|-weight|-style|-size|-stretch|-variant)?|letter-spacing)\s*:/
  for (const m of rules) {
    if (!/\.terminal-volts|\.terminal-topnav-volts/.test(m[1])) continue
    if (FONT_PROP.test(m[2])) {
      fail(R, 'terminal/src/terminal.css', `${m[1].trim().slice(0, 80)} sets a font of its own -- Volts is written in the page's font (owner, round 5), in the gold only`)
    }
  }
  if (/@font-face|--terminal-volts-font|\banton\b/i.test(css)) {
    fail(R, 'terminal/src/terminal.css', 'declares a face (or names Anton) for Volts -- the page\'s own font is the one (round 5)')
  }

  // (e) Nothing else composes a Volts amount. Each read of the currency's
  // word or a Volts figure, in every source but the two that draw them, is
  // one of the reads listed here, or the build fails.
  const DRAWS = new Set(['terminal/src/model.ts', 'terminal/src/Volts.tsx'])
  const VOLTS_CALLS = new Set(['voltsLine', 'voltsLines', 'voltsText'])
  for (const f of sources) {
    const r = rel(f)
    if (DRAWS.has(r)) continue
    const raw = readFileSync(f, 'utf8')
    const t = codeOnly(raw)
    const bridge = r === 'terminal/src/bridge.ts'
    const lineAt = (at) => t.slice(t.lastIndexOf('\n', at - 1) + 1, (t.indexOf('\n', at) + 1 || t.length + 1) - 1)
    // bridge.ts's one read of the word: the catalog's currency, a string or ''.
    const parsesWord = (at) => bridge && /^\s*functions, categories, currency: typeof v\.currency === ' +' \? v\.currency : '',$/.test(lineAt(at))
    // Inside a voltsLine(s)( ... ) call's amounts: { volts: x.balance }.
    const inAmounts = (at) => {
      const brace = opener(t, at)
      if (!brace || brace.ch !== '{') return false
      const call = opener(t, brace.at)
      return call !== null && call.ch === '(' && ['voltsLine', 'voltsLines'].includes(calleeAt(t, call.at))
    }
    const wholeArg = (s, e) => /[(,]\s*$/.test(t.slice(0, s)) && /^\s*[,)]/.test(t.slice(e))
    const bad = (at, what) => {
      const n = t.slice(0, at).split('\n').length
      fail(R, `${r}:${n}`, `${what} -- a Volts amount is drawn by Volts.tsx (VoltsAmount, voltsLine) and composed nowhere else`)
    }

    // The word, bare: `currency`.
    for (const m of t.matchAll(/(?<![\w$.])currency\b/g)) {
      const s = m.index
      const e = s + m[0].length
      const before = t.slice(0, s)
      const after = t.slice(e)
      const call = opener(t, s)
      const ok =
        /^\??:\s*string\b/.test(after) // a type's member
        || /^:\s*''/.test(after) // the empty catalog's
        || /^=\{currency\}/.test(after) || (/\scurrency=\{$/.test(before) && /^\}/.test(after)) // passed down
        || (call !== null && call.ch === '(' && VOLTS_CALLS.has(calleeAt(t, call.at)) && wholeArg(s, e)
          && /,\s*$/.test(before)) // voltsLine(text, currency), voltsText(n, currency)
        || (/\bconst $/.test(before) && /^ = (catalog|props)\.currency\n/.test(after)) // const currency = props.currency
        || destructured(t, s) // const { ..., currency } = props, ({ say, currency }: ...)
        || parsesWord(s)
      if (!ok) bad(s, 'reads the currency\'s word here')
    }
    // A member: `.currency`, `.cost`, `.volts`, `.balance`.
    for (const m of t.matchAll(/\??\.\s*(currency|cost|volts|balance)\b/g)) {
      const s = m.index
      const e = s + m[0].length
      const before = t.slice(0, s)
      const after = t.slice(e)
      let ok
      if (m[1] === 'currency') {
        ok = /\bconst currency = (catalog|props)$/.test(before) && /^\n/.test(after) || parsesWord(s)
      } else {
        ok =
          /^\s*(>|>=|<|<=|===|!==)\s*(0|null)\b/.test(after) // compared with 0 or null
          || (/<VoltsAmount\s+n=\{\s*[\w$]+$/.test(before) && /^\s*\}/.test(after)) // <VoltsAmount n={f.cost}
          || (/\bvoltsText\(\s*[\w$]+$/.test(before) && /^\s*,/.test(after)) // voltsText(state.volts, ...)
          || (/[{,]\s*(volts|cost|balance):\s*[\w$]+$/.test(before) && /^(\s*\?\?\s*0)?\s*[,}]/.test(after)
            && inAmounts(s)) // voltsLine(text, currency, { volts: flash.balance })
          || (bridge && /\bnum\(\s*[\w$]+$/.test(before) && /^\s*\)/.test(after)) // bridge.ts: num(v.cost)
          || (m[1] === 'cost' && /\bfilters$/.test(before)) // the Cost filter's free/paid, not a figure
      }
      if (!ok) bad(s, `reads ${m[1] === 'currency' ? 'the currency\'s word' : `a Volts figure (.${m[1]})`} here`)
    }
    // Ways around a member read: destructuring and ['...'].
    for (const p of patterns(t)) {
      if (/\b(cost|volts|balance)\b/.test(p.text)) bad(p.at, 'destructures a Volts figure')
    }
    const withStrings = code(raw, false)
    for (const m of withStrings.matchAll(/\[\s*(['"`])(currency|cost|volts|balance)\1\s*\]/g)) {
      bad(m.index, `reads ['${m[2]}']`)
    }
    // Composing one from a local (bridge.ts's `cost`, say): a template, `+`,
    // String() or number formatting of a Volts name.
    for (const x of interpolations(t)) {
      if (/\b(currency|cost|volts|balance)\b/.test(x.text)) bad(x.at, 'writes a Volts name into a template')
    }
    const NAME = String.raw`[\w$.?]*\b(?:currency|cost|volts|balance)\b`
    for (const re of [
      new RegExp(String.raw`${NAME}\s*\+(?!\+)`, 'g'),
      new RegExp(String.raw`(?<!\+)\+\s*${NAME}`, 'g'),
      new RegExp(String.raw`${NAME}\s*\??\.\s*(toLocaleString|toString|toFixed|toPrecision|concat|padStart|padEnd)\b`, 'g'),
      new RegExp(String.raw`\bString\(\s*${NAME}`, 'g'),
      /\bIntl\s*\.\s*NumberFormat\b/g,
    ]) {
      for (const m of t.matchAll(re)) bad(m.index, `makes text of a Volts name: ${m[0].trim()}`)
    }
    // The word itself, written in a string (an import's path aside).
    const bare = code(raw, true)
    for (const m of withStrings.matchAll(new RegExp(`\\b${currency ?? 'Volts'}\\b`, 'g'))) {
      if (bare[m.index] !== ' ' && bare[m.index] !== '\n') continue // code, not a string
      const open = Math.max(withStrings.lastIndexOf("'", m.index), withStrings.lastIndexOf('"', m.index),
        withStrings.lastIndexOf('`', m.index))
      if (/\bfrom\s*$/.test(withStrings.slice(0, open))) continue
      bad(m.index, `writes "${currency}" in a string -- the word is the catalog's currency, drawn by Volts.tsx`)
    }
  }
}

// T13: "SQUADS!" ONLY ON A SQUAD-WIDE ROW, AND ONLY IN A SQUAD MATCH (owner,
// 2026-10-06, round 4; round 2's rule that a solo player is never told
// "squad"). Every <Squads> the app draws sits behind model.ts showsSquads(),
// which asks both; Squads.tsx draws nothing when the speaker gives it no words
// (the empty _solo lines); and its words are the owner's keys.
{
  const R = 'T13 squads'
  const model = code(readFileSync(join(SRC, 'src', 'model.ts'), 'utf8'), false)
  if (!/export function showsSquads\(def: FunctionDef, squadMatch: boolean\): boolean \{\s*return squadMatch && def\.squadWide === true\s*\}/.test(model)) {
    fail(R, 'terminal/src/model.ts', 'showsSquads does not ask both the squad match and the row\'s squadWide')
  }
  let drawn = 0
  for (const f of sources.filter((s) => extname(s) === '.tsx')) {
    const text = code(readFileSync(f, 'utf8'), false)
    for (const m of text.matchAll(/<Squads\b/g)) {
      drawn++
      const line = text.slice(text.lastIndexOf('\n', m.index) + 1, m.index)
      // The match's own answer, never a literal: `showsSquads(f, true)` would
      // pass a looser pattern (the review of round 4).
      if (!/showsSquads\((f|def), (state|props)\.squadMatch\) \? $/.test(line)) {
        fail(R, rel(f), '<Squads> is drawn without showsSquads(def, state.squadMatch) ? in front of it')
      }
    }
  }
  if (drawn < 2) fail(R, 'terminal/src', `<Squads> is drawn ${drawn} time(s) -- a card's title and a function page's title each draw it`)
  // And the squadMatch a page is handed is the state's, the speaker's own.
  const app = code(readFileSync(join(SRC, 'src', 'App.tsx'), 'utf8'), false)
  if (!/const squadMatch = state\?\.squadMatch === true\n/.test(app)) {
    fail(R, 'terminal/src/App.tsx', 'squadMatch is not the state\'s own')
  }
  for (const f of sources.filter((s) => extname(s) === '.tsx')) {
    for (const m of code(readFileSync(f, 'utf8'), false).matchAll(/\bsquadMatch=\{([^}]*)\}/g)) {
      if (m[1] !== 'squadMatch') fail(R, rel(f), `hands a page squadMatch={${m[1]}} -- only the state's squadMatch`)
    }
  }
  const squads = code(readFileSync(join(SRC, 'src', 'Squads.tsx'), 'utf8'), false)
  if (!/say\('squads_link'\)/.test(squads) || !/say\('squads_popover'\)/.test(squads)
      || !/if \(link === '' \|\| body === ''\) return null/.test(squads)) {
    fail(R, 'terminal/src/Squads.tsx', 'Squads does not draw the owner\'s squads_link and squads_popover, or draws them when the speaker gives none')
  }
}

// T14: HOME'S FILTERS, AND NO TEXT SEARCH OF ITS OWN (owner, 2026-10-06,
// round 5). The top bar's search is the one: it opens a tool's page, or, with
// what was typed, the cards that match it.
{
  const R = 'T14 home'
  const cards = code(readFileSync(join(SRC, 'src', 'FunctionCards.tsx'), 'utf8'), false)
  if (/@cloudscape-design\/components\/text-filter|<TextFilter\b|<Input\b|<Autosuggest\b/.test(cards)) {
    fail(R, 'terminal/src/FunctionCards.tsx', 'Home draws a text search of its own -- the owner asked for it gone (the top bar\'s is the one)')
  }
  const selects = [...cards.matchAll(/\bselect\('([a-z]+)',/g)].map((m) => m[1]).join(',')
  if (selects !== 'category,risk,cost,bounty,status') {
    fail(R, 'terminal/src/FunctionCards.tsx', `Home's filters are ${selects || 'none'} -- the five (category, risk, cost, bounty, status) remain`)
  }
  const app = code(readFileSync(join(SRC, 'src', 'App.tsx'), 'utf8'), false)
  if (!/<Autosuggest\b/.test(app) || !/search=\{searchBox\}/.test(app)
      || !/go\(\{ page: 'function', id: detail\.value \}\)/.test(app)) {
    fail(R, 'terminal/src/App.tsx', 'the top bar\'s search is gone, or no longer opens the tool it finds')
  }
}

// T15: A STATUS WRAPS BETWEEN ITS WORDS (owner, 2026-10-07, round 7: "can you
// wrap this text better?"). Cloudscape's StatusIndicator is `word-break:
// break-all`, which cuts a word at any letter -- a card's narrow Status column
// read "No armed opponent" and then "s". terminal.css takes it off in ONE
// rule, named by Cloudscape's classes, that sets `word-break: normal
// !important`; the build's half (below) holds every `break-all` Cloudscape
// draws to a name in it, and every name in it to a `break-all` still drawn.
// terminal.css itself breaks no word at any letter.
const WRAPS = []
{
  const R = 'T15 wrap'
  const css = code(readFileSync(join(SRC, 'src', 'terminal.css'), 'utf8'), false)
  const wrapRules = []
  for (const m of css.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const selectors = m[1].split(',').map((s) => s.trim().replace(/\s+/g, ' ')).filter((s) => s !== '')
    for (const d of m[2].split(';')) {
      const colon = d.indexOf(':')
      if (colon < 0) continue
      const prop = d.slice(0, colon).trim().toLowerCase()
      const value = d.slice(colon + 1).trim().toLowerCase()
      if (prop === 'word-break' && /break-all/.test(value)) {
        fail(R, 'terminal/src/terminal.css', `${selectors.join(', ')} breaks a word at any letter`)
      } else if (prop === 'word-break' && /^normal\s*!important$/.test(value)) {
        wrapRules.push(selectors)
      }
    }
  }
  if (wrapRules.length !== 1) {
    fail(R, 'terminal/src/terminal.css', `${wrapRules.length} rules set word-break: normal !important -- the rule that keeps words whole is one`)
  }
  for (const s of wrapRules.flat()) {
    const name = resetName(s.replace(/"/g, ''))
    if (name === null || name.includes('::')) {
      fail(R, 'terminal/src/terminal.css', `${s} keeps words whole but is not [class*="awsui_<class>_"] -- the rule names Cloudscape's classes`)
    } else {
      WRAPS.push(name)
    }
  }
}

// The build.
if (!existsSync(OUT)) {
  fail('T5 one bundle', rel(OUT), 'no build output -- run the build first')
} else {
  const files = walk(OUT).map((f) => relative(OUT, f).replace(/\\/g, '/')).sort()
  const scripts = files.filter((f) => f.endsWith('.js'))
  const sheets = files.filter((f) => f.endsWith('.css'))
  // NOTHING ELSE SHIPS: round 4's Volts face (Anton's woff2 and its license)
  // went with round 5's page font (T12).
  const other = files.filter((f) => !f.endsWith('.js') && !f.endsWith('.css') && f !== 'index.html')
  if (!files.includes('index.html')) fail('T5 one bundle', rel(OUT), 'no index.html')
  if (scripts.length !== 1) fail('T5 one bundle', rel(OUT), `${scripts.length} scripts: ${scripts.join(', ')}`)
  if (sheets.length !== 1) fail('T5 one bundle', rel(OUT), `${sheets.length} stylesheets: ${sheets.join(', ')}`)
  if (other.length > 0) fail('T5 one bundle', rel(OUT), `unexpected files: ${other.join(', ')}`)
  for (const f of files) {
    if (/\.(woff2?|ttf|otf)$|anton/i.test(f)) {
      fail('T12 volts', `${rel(OUT)}/${f}`, 'a font file in the build -- Volts is in the page\'s own font since round 5')
    }
  }
  for (const s of sheets) {
    const css = readFileSync(join(OUT, s), 'utf8')
    if (/font-family:\s*['"]?Anton\b/i.test(css)) {
      fail('T12 volts', `${rel(OUT)}/${s}`, 'the built CSS still names Anton -- Volts is in the page\'s own font since round 5')
    }
  }
  // T8: every Cloudscape token the Run button borrows is one Cloudscape defines.
  const own = readFileSync(join(SRC, 'src', 'terminal.css'), 'utf8')
  const borrowed = [...own.matchAll(/var\((--color-[a-z0-9-]+)/g)].map((m) => m[1])
  if (borrowed.length < 6) fail('T8 risk', 'terminal/src/terminal.css', 'the Run colors do not name the badge tokens')
  for (const s of sheets) {
    const css = readFileSync(join(OUT, s), 'utf8')
    if (!/html\{color-scheme:normal!important\}/.test(css)) {
      fail('T4 scheme', `${rel(OUT)}/${s}`, 'html{color-scheme:normal!important} is not in the built CSS')
    }
    for (const name of borrowed) {
      if (!css.includes(`${name}:`)) {
        fail('T8 risk', `${rel(OUT)}/${s}`, `${name} is not defined by Cloudscape's CSS -- Run and its badge would differ`)
      }
    }
    // T11: no text in the build has a shadow, ours or Cloudscape's.
    const texts = [...css.matchAll(/text-shadow\s*:\s*([^;}]*)/g)].map((m) => m[1].replace(/!important/, '').trim())
    const shaded = texts.filter((v) => v !== 'none')
    if (shaded.length > 0) {
      fail('T11 depth', `${rel(OUT)}/${s}`, `${shaded.length} text-shadow(s) other than none: ${[...new Set(shaded)].join(' | ')}`)
    }
    // ...and the one rule of ours that draws a box-shadow is the surfaces'.
    // (Every rule is read once, here: a pattern that scans the sheet for one
    // rule's body backtracks through every selector, seconds on 2 MB.)
    const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
    const ours = rules.filter((m) => /box-shadow\s*:[^;}]*var\(--terminal-/.test(m[2]))
    if (ours.length !== 1 || !/box-shadow:\s*var\(--terminal-surface,\s*var\(--terminal-raise\)\)\s*!important/.test(ours[0]?.[2] ?? '')) {
      fail('T11 depth', `${rel(OUT)}/${s}`, `${ours.length} built rule(s) draw our box-shadow -- the surfaces are one rule`)
    }
    // ...and every shade Cloudscape draws is a surface's, or one terminal.css
    // takes off a control. A focus ring and a divider are not shades.
    const owners = cloudscapeOwners()
    if (owners.size === 0) fail('T11 depth', 'node_modules/@cloudscape-design/components', 'no styles.css.js found -- cannot tell whose shade is whose')
    const tokens = new Map()
    for (const m of rules) {
      for (const d of m[2].matchAll(/(--[\w-]+)\s*:([^;}]*)/g)) {
        if (!tokens.has(d[1])) tokens.set(d[1], new Set())
        tokens.get(d[1]).add(d[2].trim())
      }
    }
    const shadedControls = new Set()
    let stockShades = 0
    for (const m of rules) {
      for (const d of m[2].matchAll(/(?:^|;)\s*box-shadow\s*:([^;}]*)/g)) {
        const value = d[1].trim()
        if (value.includes('var(--terminal-') || !computedValues(value, tokens).some(shades)) continue
        for (const sel of topSplit(m[1], ',')) {
          stockShades++
          const { classes, pseudo } = subject(sel)
          const keys = classes.map((c) => owners.get(c) ?? `?/${c}`)
          const where = `${rel(OUT)}/${s}`
          if (keys.length === 0 || keys[0].startsWith('?/')) {
            fail('T11 depth', where, `a shade on ${sel.slice(0, 120)}: no Cloudscape class owns it -- say whose it is`)
            continue
          }
          const stem = (k) => k.split('/').pop()
          const control = keys.find((k) => CONTROL.test(stem(k)))
          if (control) {
            const name = stem(control) + pseudo
            shadedControls.add(name)
            if (/!important/i.test(value)) {
              fail('T11 depth', where, `${control} shades a control with !important -- terminal.css cannot take it off`)
            } else if (!RESETS.includes(name)) {
              fail('T11 depth', 'terminal/src/terminal.css', `Cloudscape shades the control ${control}${pseudo} (${value.slice(0, 80)}) -- add ${resetSelector(name)} to the box-shadow: none rule`)
            }
          } else if (!keys.some((k) => STOCK_SURFACES[k])) {
            fail('T11 depth', where, `Cloudscape shades ${keys[0]}${pseudo} (${sel.slice(0, 100)}) -- a surface (STOCK_SURFACES) or a control (terminal.css's box-shadow: none rule)?`)
          }
        }
      }
    }
    if (stockShades === 0) fail('T11 depth', `${rel(OUT)}/${s}`, 'found no Cloudscape shade at all -- the reader is broken, not the build clean')
    for (const name of RESETS) {
      if (!shadedControls.has(name)) {
        fail('T11 depth', 'terminal/src/terminal.css', `${resetSelector(name)} takes off a shade Cloudscape no longer draws -- take it out of the rule`)
      }
    }
    // The rule reached the build, as one rule.
    const built = rules
      .filter((m) => m[2].trim() === 'box-shadow:none!important')
      .map((m) => topSplit(m[1], ',').map((x) => resetName(x.replace(/"/g, ''))).sort().join(','))
    if (RESETS.length > 0 && !built.includes([...RESETS].sort().join(','))) {
      fail('T11 depth', `${rel(OUT)}/${s}`, `terminal.css's box-shadow: none rule (${RESETS.join(', ')}) is not in the built CSS as one rule`)
    }
    // T15: every `word-break: break-all` Cloudscape draws is on a class the
    // words-whole rule names, and every name in it still breaks.
    const breaking = new Set()
    for (const m of rules) {
      if (!/(?:^|;)\s*word-break\s*:\s*break-all/.test(m[2])) continue
      for (const sel of topSplit(m[1], ',')) {
        const stems = subject(sel).classes.map((c) => (owners.get(c) ?? `?/${c}`).split('/').pop())
        for (const x of stems) breaking.add(x)
        if (!stems.some((x) => WRAPS.includes(x))) {
          fail('T15 wrap', 'terminal/src/terminal.css', `Cloudscape breaks words at any letter on ${sel.slice(0, 100)} -- add ${resetSelector(stems[stems.length - 1] ?? '?')} to the word-break: normal rule`)
        }
      }
    }
    for (const name of WRAPS) {
      if (!breaking.has(name)) {
        fail('T15 wrap', 'terminal/src/terminal.css', `${resetSelector(name)} keeps whole the words of what Cloudscape no longer breaks -- take it out of the rule`)
      }
    }
    if (WRAPS.length > 0 && !rules.some((m) => /word-break:normal!important/.test(m[2])
        && topSplit(m[1], ',').map((x) => resetName(x.replace(/"/g, ''))).sort().join(',') === [...WRAPS].sort().join(','))) {
      fail('T15 wrap', `${rel(OUT)}/${s}`, `terminal.css's word-break: normal rule (${WRAPS.join(', ')}) is not in the built CSS`)
    }
  }
}

if (failures > 0) {
  console.error(`\ncheck-terminal: ${failures} failure(s)`)
  process.exit(1)
}
console.log(`check-terminal: ok, ${sources.length} source file(s) and the build`)
