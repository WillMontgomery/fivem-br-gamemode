import { createHash } from 'node:crypto'
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

import * as esbuild from 'esbuild'

/**
 * Bundle br_ddb into the one file the resource ships.
 *
 * FXSERVER INSTALLS NOTHING. There is no npm install on the game box and no
 * build step in the deploy -- resources are rsynced and run. So the AWS SDK has
 * to be flattened into a single file here, on a developer machine, and
 * committed.
 *
 * `--check` verifies the committed bundle matches what the current source would
 * produce, without writing. That is what tools/pre-commit and verify.sh call:
 * source and bundle drifting apart presents as "my change did nothing", with
 * nothing wrong in any log, which is precisely the failure the NUI bundle guard
 * already exists to prevent.
 */

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, '..')
const repoRoot = resolve(root, '..', '..')
const outFile = join(
  repoRoot,
  'resources',
  '[fivem-royale]',
  'br_ddb',
  'dist',
  'server.js',
)

const check = process.argv.includes('--check')

const result = await esbuild.build({
  entryPoints: [join(root, 'src', 'index.js')],
  bundle: true,
  // FXServer's server runtime is Node. node_version '22' in the manifest opts
  // into the modern one; targeting node18 keeps the output conservative enough
  // to survive a runtime downgrade without silently emitting syntax it cannot
  // parse.
  target: 'node18',
  platform: 'node',
  /**
   * IIFE, NOT CJS, AND THIS IS NOT A STYLE CHOICE.
   *
   * FXServer evaluates server scripts into a SHARED global scope rather than
   * per-module scopes. A CJS bundle puts its declarations at top level, and
   * minified top-level names are short — so the first load produced
   *
   *   SyntaxError: Identifier '_v' has already been declared
   *
   * on a real server, with the Lua half of the resource loading fine and the
   * JS half silently absent. Wrapping everything in an IIFE puts every
   * declaration inside a function, so the bundle contributes exactly nothing
   * to global scope and cannot collide with another resource, a future second
   * bundle, or the runtime itself.
   *
   * Nothing needs to be exported: the script's whole job is registering event
   * handlers as a side effect.
   */
  format: 'iife',
  minify: true,
  // FiveM's globals (on, emit, GetConvar) are injected by the runtime and must
  // NOT be resolved or shimmed.
  external: [],
  write: false,
  legalComments: 'none',
  banner: {
    js: '/* br_ddb -- GENERATED. Edit js-src/br_ddb and run `npm run build`. */',
  },
})

const built = result.outputFiles[0].text
const sha = (s) => createHash('sha256').update(s).digest('hex').slice(0, 12)

/**
 * The bundle must contribute nothing to global scope.
 *
 * ASSERTED RATHER THAN TRUSTED, because getting this wrong is silent on a
 * developer machine and fatal on the server. Built as CJS this bundle put 1909
 * minified names into the shared scope FXServer evaluates server scripts in,
 * and the server refused it with
 *
 *   SyntaxError: Identifier '_v' has already been declared
 *
 * while the resource's Lua half loaded perfectly — so the resource appeared to
 * start and simply never answered. A one-line structural check is cheap
 * insurance against a format regression reintroducing that.
 */
const firstCode = built.split('\n').find((l) => l && !l.startsWith('/*')) ?? ''
if (!/^\(\s*(\(\)\s*=>|function)/.test(firstCode.trim())) {
  console.error('br_ddb: bundle is not IIFE-wrapped — it would leak into')
  console.error("        FXServer's shared global scope. Check `format` in this file.")
  process.exit(1)
}

if (check) {
  if (!existsSync(outFile)) {
    console.error('br_ddb: no committed bundle at', outFile)
    process.exit(1)
  }
  const committed = readFileSync(outFile, 'utf8')
  if (committed !== built) {
    console.error('br_ddb: committed bundle does not match source.')
    console.error(`  committed ${sha(committed)}, source would produce ${sha(built)}`)
    console.error('  Fix:  cd js-src/br_ddb && npm run build')
    process.exit(1)
  }
  console.log(`br_ddb: bundle matches source (${sha(built)})`)
  process.exit(0)
}

mkdirSync(dirname(outFile), { recursive: true })
writeFileSync(outFile, built)
console.log(
  `br_ddb: wrote ${outFile} (${(built.length / 1024).toFixed(0)} KB, ${sha(built)})`,
)
