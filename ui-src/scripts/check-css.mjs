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
// Run automatically as part of `npm run build`.

import { readFileSync, readdirSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const outDir = join(here, '..', '..', 'resources', '[fivem-royale]', 'br_ui', 'ui', 'assets')

// SEVERITY DEPENDS ON *WHERE* THE UNSUPPORTED SYNTAX SITS, and conflating the
// two made this gate reject a build over a cosmetic rule.
//
//   error   -- unsupported VALUE functions. The browser drops the declaration
//              but keeps the rule, so the element renders with no colour at
//              all: a full health bar with nothing behind it. Invisible
//              content, and it looks like a build failure.
//
//   warn    -- unsupported SELECTORS. The browser drops the whole rule, which
//              is graceful: the element simply misses that one styling. A
//              disabled button not dimming to 60% is not worth failing a build,
//              especially when it comes from a dependency we do not control.
const BANNED = [
  { re: /oklch\(/g,     since: 111, name: 'oklch()',     level: 'error' },
  { re: /oklab\(/g,     since: 111, name: 'oklab()',     level: 'error' },
  { re: /\blch\(/g,     since: 111, name: 'lch()',       level: 'error' },
  { re: /\blab\(/g,     since: 111, name: 'lab()',       level: 'error' },
  { re: /color-mix\(/g, since: 111, name: 'color-mix()', level: 'error', guarded: true },
  { re: /:has\(/g,      since: 105, name: ':has()',      level: 'warn' },
]

const TARGET_CHROME = 103

let files
try {
  files = readdirSync(outDir).filter((f) => f.endsWith('.css'))
} catch {
  console.error(`check-css: no build output at ${outDir} -- run the build first`)
  process.exit(1)
}

let failures = 0
let warnings = 0

for (const file of files) {
  const path = join(outDir, file)
  const css = readFileSync(path, 'utf8')

  // Blank out @supports blocks before counting guarded patterns: inside one, an
  // unsupported function is deliberate progressive enhancement, not a bug.
  // Tailwind wraps all of its own color-mix use this way.
  const unguarded = css.replace(
    /@supports\s*\([^)]*\)\s*\{/g,
    (m) => ' '.repeat(m.length),
  )

  for (const { re, since, name, level, guarded } of BANNED) {
    const total = (css.match(re) || []).length
    if (total === 0) continue

    const bare = guarded ? (unguarded.match(re) || []).length : total
    if (bare === 0) continue

    const msg =
      `${file}: ${bare} unguarded ${name} ` +
      `(needs Chrome ${since}, target is ${TARGET_CHROME})`

    if (level === 'error') {
      console.error(`check-css ERROR  ${msg}`)
      failures++
    } else {
      console.warn(`check-css warn   ${msg} -- rule is dropped, degrades gracefully`)
      warnings++
    }
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

const suffix = warnings > 0 ? `, ${warnings} warning(s)` : ''
console.log(
  `check-css: ok, ${files.length} stylesheet(s) safe for Chrome ${TARGET_CHROME}${suffix}`,
)
