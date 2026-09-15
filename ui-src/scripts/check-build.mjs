import { spawnSync } from 'node:child_process'
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, extname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * Rebuild the shipped NUI and prove it is byte-for-byte current without leaving
 * the worktree changed.
 *
 * Normal builds carry a human-facing timestamp and source commit. The checker
 * extracts that one exact committed stamp and asks Vite to rebuild with the same
 * value. Using the same compile-time string matters: esbuild's identifier
 * mangling is character-frequency-sensitive, so compiling with a short fixed
 * marker and replacing only the visible stamp afterwards can change unrelated
 * minified names. With the exact committed stamp, every shipped byte must match:
 * JavaScript, CSS, fonts, images, HTML and copied docs.
 */

const here = dirname(fileURLToPath(import.meta.url))
const uiRoot = resolve(here, '..')
const repoRoot = resolve(uiRoot, '..')
const output = join(
  repoRoot,
  'resources',
  '[fivem-royale]',
  'br_ui',
  'ui',
)

if (!existsSync(output)) {
  console.error(`br_ui: committed output is missing: ${output}`)
  process.exit(1)
}

const scratch = mkdtempSync(join(tmpdir(), 'br-ui-build-check-'))
const original = join(scratch, 'original')
const stampPattern = /built \d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2} \(from [^)]+\)/g

function walk(root, at = root) {
  const out = []
  for (const name of readdirSync(at)) {
    const path = join(at, name)
    if (statSync(path).isDirectory()) out.push(...walk(root, path))
    else out.push(relative(root, path))
  }
  return out.sort()
}

function committedStamp(root) {
  const found = []
  for (const file of walk(root)) {
    if (extname(file) !== '.js') continue
    const source = readFileSync(join(root, file), 'utf8')
    for (const match of source.matchAll(stampPattern)) found.push(match[0])
  }
  if (found.length !== 1) {
    throw new Error(`expected one committed build stamp, found ${found.length}`)
  }
  return found[0]
}

function compareTrees(wantRoot, gotRoot) {
  const wantFiles = walk(wantRoot)
  const gotFiles = walk(gotRoot)
  const names = [...new Set([...wantFiles, ...gotFiles])].sort()
  const differences = []

  for (const file of names) {
    const want = join(wantRoot, file)
    const got = join(gotRoot, file)
    if (!existsSync(want)) differences.push(`unexpected generated file: ${file}`)
    else if (!existsSync(got)) differences.push(`missing generated file: ${file}`)
    else if (!readFileSync(want).equals(readFileSync(got))) {
      differences.push(`content differs: ${file}`)
    }
  }
  return differences
}

let status = 1
try {
  cpSync(output, original, { recursive: true })
  const stamp = committedStamp(original)

  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm'
  const built = spawnSync(npm, ['run', 'build'], {
    cwd: uiRoot,
    env: { ...process.env, BR_BUILD_STAMP: stamp },
    stdio: 'inherit',
  })

  if (built.error) throw built.error
  if (built.status !== 0) {
    console.error(`br_ui: build failed with status ${built.status}`)
  } else {
    const differences = compareTrees(original, output)
    if (differences.length === 0) {
      console.log('br_ui: committed bundle matches source')
      status = 0
    } else {
      console.error('br_ui: committed bundle does not match source:')
      for (const difference of differences) console.error(`  ${difference}`)
      console.error('Fix: cd ui-src && npm run build')
    }
  }
} catch (error) {
  console.error(`br_ui: build check failed: ${error instanceof Error ? error.message : error}`)
} finally {
  rmSync(output, { recursive: true, force: true })
  if (existsSync(original)) cpSync(original, output, { recursive: true })
  rmSync(scratch, { recursive: true, force: true })
}

process.exit(status)
