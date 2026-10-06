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
 *                  Spinner. In App.tsx back and forward step the history at
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
  for (const m of brCss.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    // Every selector in the list must need the class, so a :not() is taken out
    // first: `:not(.br-loading)` names the class and animates everything else.
    const loading = m[1].split(',').every((s) => /\.br-loading(?![\w-])/.test(s.replace(/:not\([^()]*\)/g, ' ')))
    if (/(^|[;\s])animation(-name)?\s*:/.test(m[2]) && !loading) {
      fail('T10 page loads', 'cuchi_computer/nui/br.css', `${m[1].trim()} animates outside .br-loading`)
    }
  }
  if (/animation-play-state/.test(brCss)) {
    fail('T10 page loads', 'cuchi_computer/nui/br.css', 'pauses an animation in place -- take its class off instead')
  }
  const brJs = code(readFileSync(join(ROOT, '..', 'resources', '[computer]', 'cuchi_computer', 'nui', 'br.js'), 'utf8'), false)
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

// The build.
if (!existsSync(OUT)) {
  fail('T5 one bundle', rel(OUT), 'no build output -- run the build first')
} else {
  const files = walk(OUT).map((f) => relative(OUT, f).replace(/\\/g, '/')).sort()
  const scripts = files.filter((f) => f.endsWith('.js'))
  const sheets = files.filter((f) => f.endsWith('.css'))
  const other = files.filter((f) => !f.endsWith('.js') && !f.endsWith('.css') && f !== 'index.html')
  if (!files.includes('index.html')) fail('T5 one bundle', rel(OUT), 'no index.html')
  if (scripts.length !== 1) fail('T5 one bundle', rel(OUT), `${scripts.length} scripts: ${scripts.join(', ')}`)
  if (sheets.length !== 1) fail('T5 one bundle', rel(OUT), `${sheets.length} stylesheets: ${sheets.join(', ')}`)
  if (other.length > 0) fail('T5 one bundle', rel(OUT), `unexpected files: ${other.join(', ')}`)
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
  }
}

if (failures > 0) {
  console.error(`\ncheck-terminal: ${failures} failure(s)`)
  process.exit(1)
}
console.log(`check-terminal: ok, ${sources.length} source file(s) and the build`)
