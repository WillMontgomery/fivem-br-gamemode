import { spawnSync } from 'node:child_process'
import {
  cpSync,
  existsSync,
  mkdtempSync,
  readdirSync,
  readFileSync,
  rmSync,
  statSync,
  writeFileSync,
} from 'node:fs'
import { tmpdir } from 'node:os'
import { dirname, extname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * Rebuild the shipped NUI and prove it is byte-for-byte current without leaving
 * the worktree changed.
 *
 * Normal builds carry a human-facing timestamp and source commit. Those values
 * are intentionally non-deterministic, so the check replaces the committed
 * stamp with a fixed marker and asks Vite to emit the same marker. Everything
 * else must match exactly: JavaScript, CSS, fonts, images, HTML and copied docs.
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
const expected = join(scratch, 'expected')
const fixedStamp = 'build-check'
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

function normalizeCommittedStamp(root) {
  let replaced = 0
  for (const file of walk(root)) {
    if (extname(file) !== '.js') continue
    const path = join(root, file)
    const source = readFileSync(path, 'utf8')
    const normalized = source.replace(stampPattern, () => {
      replaced++
      return fixedStamp
    })
    if (normalized !== source) writeFileSync(path, normalized)
  }
  if (replaced !== 1) {
    throw new Error(`expected one committed build stamp, found ${replaced}`)
  }
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
  cpSync(original, expected, { recursive: true })
  normalizeCommittedStamp(expected)

  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm'
  const built = spawnSync(npm, ['run', 'build'], {
    cwd: uiRoot,
    env: { ...process.env, BR_BUILD_STAMP: fixedStamp },
    stdio: 'inherit',
  })

  if (built.error) throw built.error
  if (built.status !== 0) {
    console.error(`br_ui: build failed with status ${built.status}`)
  } else {
    const differences = compareTrees(expected, output)
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
