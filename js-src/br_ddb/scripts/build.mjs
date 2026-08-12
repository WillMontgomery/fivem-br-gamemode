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
  format: 'cjs',
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
