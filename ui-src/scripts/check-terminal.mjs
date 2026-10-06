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
 *                  `none` (Cloudscape's own resets).
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
// A selector naming any of these reaches a control. `awsui_flash_` is the
// progress bar's class as much as the flash's (round 2's rule shadowed the
// bar through it); the flash itself is `awsui_flash-type-`.
const CONTROL = /button|badge|progress|input|toggle|pagination|radio|checkbox|select|segmented|icon|utility|trigger|link|awsui_flash_/i
// The only shadow-valued properties terminal.css may set besides the one rule's
// box-shadow: the two values per mode.
const SHADOW_VALUES = new Set(['--terminal-raise', '--terminal-raise-strong'])
{
  for (const s of SURFACES) {
    if (CONTROL.test(s)) fail('T11 depth', 'scripts/check-terminal.mjs', `the surface ${s} names a control`)
  }
  const css = code(readFileSync(join(SRC, 'src', 'terminal.css'), 'utf8'), false)
  const shadowRules = []
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
  for (const f of sources) {
    if (/\b(boxShadow|textShadow)\b/.test(code(readFileSync(f, 'utf8'), false))) {
      fail('T11 depth', rel(f), 'sets a boxShadow or textShadow -- shadows are terminal.css\'s, on surfaces only')
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
    const ours = [...css.matchAll(/([^{}]+)\{([^{}]*box-shadow\s*:[^;}]*var\(--terminal-[^{}]*)\}/g)]
    if (ours.length !== 1 || !/box-shadow:\s*var\(--terminal-surface,\s*var\(--terminal-raise\)\)\s*!important/.test(ours[0]?.[2] ?? '')) {
      fail('T11 depth', `${rel(OUT)}/${s}`, `${ours.length} built rule(s) draw our box-shadow -- the surfaces are one rule`)
    }
  }
}

if (failures > 0) {
  console.error(`\ncheck-terminal: ${failures} failure(s)`)
  process.exit(1)
}
console.log(`check-terminal: ok, ${sources.length} source file(s) and the build`)
