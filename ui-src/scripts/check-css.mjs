// Fails the build if the bundle contains CSS that FiveM's CEF cannot parse.
//
// The CEF in FiveM reports Chrome 103. Modern colour functions are not merely
// unsupported there -- an unparseable declaration is DROPPED, so the element
// renders with no colour at all. That failure looks identical to "the
// stylesheet did not load", which is what made it expensive to diagnose the
// first time: a health bar reading 100 with nothing behind it.
//
// This exists because the dependency tree can reintroduce these without any
// change on our side. A minor bump to a component library that switches its
// palette to oklch would silently break every screen it renders, and nothing in
// a typecheck or a unit test would notice.
//
// Run automatically as part of `npm run build`, once per output: bare for
// br_ui, `check-css.mjs terminal` for the Season 2 terminal app (#396), which
// vite.terminal.config.ts writes into the vendored cuchi_computer, and
// `check-css.mjs pages` for the pages nobody builds (#413): the DUI pages, the
// loading screen, cuchi_computer's desktop and pma-voice's page.
//
// CEF 144 (#413) IS COMING, AND THIS STAYS AT 103 UNTIL EVERY CLIENT HAS IT.
// Cfx moves FiveM from CEF 103 to 144 (Canary first, then every channel); a
// player not yet moved still renders a 144-only declaration as nothing. The
// list below grows with what 144 added that 103 drops, and docs/platform.md
// says when the bans can go. Until then the dual-safe form is `@supports`
// around the new syntax, which this counts as guarded (scripts/css-guard.mjs).
//
// `--has` lists every :has() selector, so the rules that start applying on
// CEF 144 can be looked at on a Canary client.

import { readFileSync, readdirSync, statSync } from 'node:fs'
import { join, dirname, relative, extname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { blankGuarded } from './css-guard.mjs'
import { blankComments } from './cef-rules.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const resources = join(here, '..', '..', 'resources')
const OUTPUTS = {
  br_ui: ['[fivem-royale]', 'br_ui', 'ui', 'assets'],
  terminal: ['[computer]', 'cuchi_computer', 'nui', 'apps', 'terminal', 'assets'],
  pages: null,
}
const args = process.argv.slice(2)
const listHas = args.includes('--has')
const target = args.find((a) => !a.startsWith('--')) ?? 'br_ui'
if (!(target in OUTPUTS)) {
  console.error(`check-css: unknown output '${target}' (one of ${Object.keys(OUTPUTS).join(', ')})`)
  process.exit(1)
}

// SEVERITY DEPENDS ON *WHERE* THE UNSUPPORTED SYNTAX SITS, and conflating the
// two made this gate reject a build over a cosmetic rule.
//
//   error   -- unsupported VALUE functions. The browser drops the declaration
//              but keeps the rule, so the element renders with no colour at
//              all: a full health bar with nothing behind it. Invisible
//              content, and it looks like a build failure.
//
//   warn    -- unsupported SELECTORS, and the at-rules, units and properties a
//              library ships that we do not rely on. The browser drops that
//              rule or declaration alone, and the element misses that one
//              styling. CEF 144 applies them -- the other reason they are
//              listed: 103 and 144 clients differ there.
//
// Every entry is exempt inside an @supports block that tests for it.
const BANNED = [
  { re: /oklch\(/g,     since: 111, name: 'oklch()',     level: 'error' },
  { re: /oklab\(/g,     since: 111, name: 'oklab()',     level: 'error' },
  { re: /\blch\(/g,     since: 111, name: 'lch()',       level: 'error' },
  { re: /\blab\(/g,     since: 111, name: 'lab()',       level: 'error' },
  { re: /color-mix\(/g, since: 111, name: 'color-mix()', level: 'error' },
  { re: /\bcolor\(\s*(?:srgb|srgb-linear|display-p3|a98-rgb|prophoto-rgb|rec2020|xyz|xyz-d50|xyz-d65)\b/g,
    since: 111, name: 'color()', level: 'error' },
  { re: /\b(?:rgba?|hsla?|hwb|color)\(\s*from\s/g, since: 119, name: 'relative color', level: 'error' },
  { re: /light-dark\(/g, since: 123, name: 'light-dark()', level: 'error' },
  { re: /\banchor(?:-size)?\(/g, since: 125, name: 'anchor()', level: 'error' },
  { re: /calc-size\(/g, since: 129, name: 'calc-size()', level: 'error' },
  { re: /:has\(/g,      since: 105, name: ':has()',      level: 'warn' },
  { re: /@container\b/g, since: 105, name: '@container', level: 'warn' },
  { re: /\d(?:cqw|cqh|cqi|cqb|cqmin|cqmax)\b/g, since: 105, name: 'container units', level: 'warn' },
  { re: /\d(?:[dsl]vh|[dsl]vw|[dsl]vi|[dsl]vb|[dsl]vmin|[dsl]vmax)\b/g, since: 108, name: 'dvh/svh/lvh units', level: 'warn' },
  { re: /text-wrap\s*:\s*(?:balance|pretty)/g, since: 114, name: 'text-wrap balance/pretty', level: 'warn' },
  { re: /@starting-style\b/g, since: 117, name: '@starting-style', level: 'warn' },
  // On 121+ either property turns ::-webkit-scrollbar styling off for the
  // element it is set on: a scrollbar we style (.thin-scroll) would change.
  { re: /scrollbar-(?:color|width)\s*:/g, since: 121, name: 'scrollbar-color/width', level: 'warn' },
  { re: /field-sizing\s*:/g, since: 123, name: 'field-sizing', level: 'warn' },
]

const TARGET_CHROME = 103

/** The hand-written pages: every .html/.css under resources/ that no build writes. */
function pages() {
  const out = []
  const walk = (dir) => {
    for (const name of readdirSync(dir)) {
      if (name === 'node_modules' || name.startsWith('.')) continue
      const p = join(dir, name)
      if (statSync(p).isDirectory()) { walk(p); continue }
      const r = relative(resources, p).replace(/\\/g, '/')
      if (!['.html', '.htm', '.css'].includes(extname(p))) continue
      if (/^\[fivem-royale\]\/br_ui\/ui\/|^\[computer\]\/cuchi_computer\/nui\/apps\/terminal\/|\/server\//.test(r)) continue
      out.push({ name: r, path: p })
    }
  }
  walk(resources)
  return out
}

let files
try {
  if (target === 'pages') {
    files = pages()
  } else {
    const outDir = join(resources, ...OUTPUTS[target])
    files = readdirSync(outDir).filter((f) => f.endsWith('.css')).map((f) => ({ name: f, path: join(outDir, f) }))
  }
} catch {
  console.error(`check-css: no output for '${target}' -- run the build first`)
  process.exit(1)
}
if (files.length === 0) {
  console.error(`check-css: '${target}' has no stylesheets -- the paths are wrong`)
  process.exit(1)
}

let failures = 0
let warnings = 0

for (const { name, path } of files) {
  const raw = readFileSync(path, 'utf8')
  // A hand-written page explains itself in comments ("Chrome 103: no :has").
  const css = target === 'pages' ? blankComments(raw, { html: /\.html?$/.test(name) }) : raw
  const warned = []

  for (const { re, since, name: what, level } of BANNED) {
    if (!(css.match(re) || []).length) continue
    const bare = (blankGuarded(css, re).match(re) || []).length
    if (bare === 0) continue

    if (level === 'error') {
      console.error(`check-css ERROR  ${name}: ${bare} unguarded ${what} (needs Chrome ${since}, target is ${TARGET_CHROME})`)
      failures++
    } else {
      warned.push(`${what} x${bare} (${since})`)
    }
  }
  if (warned.length > 0) {
    warnings++
    console.warn(`check-css warn   ${name}: ${warned.join(', ')} -- dropped on 103, applied on 144`)
  }
  if (listHas) {
    for (const m of css.matchAll(/[^{}]*:has\([^{]*\{/g)) console.log(`  ${name}: ${m[0].trim().slice(0, -1).trim()}`)
  }
}

if (failures > 0) {
  console.error('')
  console.error("  Unsupported VALUE functions render as NO COLOUR on FiveM's CEF,")
  console.error('  not as a fallback -- the declaration is dropped and the element')
  console.error('  becomes invisible. Express it in hex/rgba, or wrap in @supports.')
  console.error('')
  console.error('  Confirm the CEF version from the in-game probe, printed at client')
  console.error('  startup as "[br_ui] ---- CEF environment ----".')
  process.exit(1)
}

const suffix = warnings > 0 ? `, ${warnings} with warnings` : ''
console.log(
  `check-css: ok, ${target}: ${files.length} stylesheet(s) safe for Chrome ${TARGET_CHROME}${suffix}`,
)
