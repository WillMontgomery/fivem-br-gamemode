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
  for (const s of sheets) {
    const css = readFileSync(join(OUT, s), 'utf8')
    if (!/html\{color-scheme:normal!important\}/.test(css)) {
      fail('T4 scheme', `${rel(OUT)}/${s}`, 'html{color-scheme:normal!important} is not in the built CSS')
    }
  }
}

if (failures > 0) {
  console.error(`\ncheck-terminal: ${failures} failure(s)`)
  process.exit(1)
}
console.log(`check-terminal: ok, ${sources.length} source file(s) and the build`)
