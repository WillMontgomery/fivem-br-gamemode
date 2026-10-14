#!/usr/bin/env node
/**
 * THE CEF 144 GATE (#413): nothing that FiveM's move from CEF 103 to 144
 * removes or changes may come back into a page we ship.
 *
 * check-css.mjs keeps out what CEF 103 cannot parse; this keeps out what CEF
 * 144 took away. The rules, each with its reason, are scripts/cef-rules.mjs;
 * scripts/test-cef.mjs proves every one of them fails on a banned use.
 *
 * WHAT IS READ
 *   Source, as written: ui-src/src, ui-src/terminal, ui-src/index.html, and
 *   every .html/.htm/.js/.mjs/.css/.vue under resources/ outside the built
 *   outputs and server code -- the DUI pages, the loading screen,
 *   cuchi_computer's desktop, pma-voice's page and its Vue source.
 *   Built output (what a dependency can bring in): br_ui/ui, the terminal
 *   app, and pma-voice's compiled ui/js.
 *   Every fxmanifest.lua, and any __resource.lua.
 *
 * Run: npm run check:cef   (and as part of npm run build)
 */

import { existsSync, readdirSync, readFileSync, statSync } from 'node:fs'
import { join, relative, extname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { checkZoomShim, scanBundle, scanManifests, scanSource } from './cef-rules.mjs'

const UI = fileURLToPath(new URL('..', import.meta.url))
const REPO = join(UI, '..')
const RES = join(REPO, 'resources')
const rel = (p) => relative(REPO, p).replace(/\\/g, '/')

function walk(dir, out = []) {
  if (!existsSync(dir)) return out
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('.')) continue
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}

const WEB = new Set(['.html', '.htm', '.js', '.mjs', '.css', '.vue'])
const CODE = new Set(['.ts', '.tsx', '.css', '.html'])

/** Built output: scanned with the bundle rules, never the source ones. */
const BUILT = [
  /^resources\/\[fivem-royale\]\/br_ui\/ui\//,
  /^resources\/\[computer\]\/cuchi_computer\/nui\/apps\/terminal\//,
  /^resources\/\[voice\]\/pma-voice\/ui\/js\//,
]
/** Not a page at all: Node and server code. */
const NOT_A_PAGE = [/\/server\//, /^resources\/\[fivem-royale\]\/br_ddb\//, /\/(?:babel|vue)\.config\.js$/]

const sources = [
  ...walk(join(UI, 'src')).filter((f) => CODE.has(extname(f))),
  ...walk(join(UI, 'terminal')).filter((f) => CODE.has(extname(f))),
  join(UI, 'index.html'),
]
const bundles = []
for (const f of walk(RES)) {
  const r = rel(f)
  if (!WEB.has(extname(f)) || NOT_A_PAGE.some((re) => re.test(r))) continue
  if (BUILT.some((re) => re.test(r))) bundles.push(f)
  else sources.push(f)
}

const findings = []
for (const f of sources) findings.push(...scanSource(readFileSync(f, 'utf8'), rel(f)))
for (const f of bundles) findings.push(...scanBundle(readFileSync(f, 'utf8'), rel(f)))

const all = walk(RES)
findings.push(...scanManifests(
  all.filter((f) => f.endsWith('fxmanifest.lua')).map((f) => ({ file: rel(f), text: readFileSync(f, 'utf8') })),
  all.filter((f) => f.endsWith('__resource.lua')).map(rel),
))

const locker = join(RES, '[fivem-royale]', 'br_ui', 'ui', 'assets', 'LockerV2.js')
findings.push(...checkZoomShim({
  viteConfig: readFileSync(join(UI, 'vite.config.ts'), 'utf8'),
  helper: readFileSync(join(UI, 'src', 'cef', 'zoomRect.ts'), 'utf8'),
  lockerBundle: existsSync(locker) ? readFileSync(locker, 'utf8') : null,
}))

if (sources.length < 100 || bundles.length < 3) {
  // A checker that reads nothing is green and worthless (check-ui.mjs's note).
  console.error(`check-cef: read only ${sources.length} source and ${bundles.length} built files -- the paths are wrong`)
  process.exit(1)
}

for (const f of findings) {
  console.error(`check-cef FAIL  [${f.rule}] ${f.file}:${f.line}\n                ${f.msg}`)
}
if (findings.length > 0) {
  console.error(`\ncheck-cef: ${findings.length} failure(s). CEF 144 removed or changed these; see scripts/cef-rules.mjs.`)
  process.exit(1)
}
console.log(`check-cef: ok, ${sources.length} source and ${bundles.length} built files clear of what CEF 144 removed`)
