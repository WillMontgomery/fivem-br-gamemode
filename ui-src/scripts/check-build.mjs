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
 * Rebuild the shipped NUI -- br_ui and the Season 2 terminal app -- and prove
 * both are byte-for-byte current without leaving the worktree changed.
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

/**
 * EVERY OUTPUT `npm run build` WRITES, each with the variable that carries its
 * stamp. br_ui is the HUD; the terminal is the Season 2 app (#396), which
 * vite.terminal.config.ts writes into the vendored cuchi_computer. Each output
 * holds exactly one stamp of its own -- they are built at different moments --
 * and is rebuilt with that one, so one `npm run build` reproduces both.
 */
const OUTPUTS = [
  {
    name: 'br_ui',
    dir: join(repoRoot, 'resources', '[fivem-royale]', 'br_ui', 'ui'),
    env: 'BR_BUILD_STAMP',
  },
  {
    name: 'terminal',
    dir: join(repoRoot, 'resources', '[computer]', 'cuchi_computer', 'nui', 'apps', 'terminal'),
    env: 'BR_TERMINAL_BUILD_STAMP',
  },
]

for (const out of OUTPUTS) {
  if (!existsSync(out.dir)) {
    console.error(`${out.name}: committed output is missing: ${out.dir}`)
    process.exit(1)
  }
}

const scratch = mkdtempSync(join(tmpdir(), 'br-ui-build-check-'))
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

function committedStamp(name, root) {
  const found = []
  for (const file of walk(root)) {
    if (extname(file) !== '.js') continue
    const source = readFileSync(join(root, file), 'utf8')
    for (const match of source.matchAll(stampPattern)) found.push(match[0])
  }
  if (found.length !== 1) {
    throw new Error(`${name}: expected one committed build stamp, found ${found.length}`)
  }
  return found[0]
}

function compareTrees(wantRoot, gotRoot) {
  const wantFiles = walk(wantRoot)
  const gotFiles = existsSync(gotRoot) ? walk(gotRoot) : []
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
const saved = []
try {
  const env = { ...process.env }
  for (const out of OUTPUTS) {
    const original = join(scratch, out.name)
    cpSync(out.dir, original, { recursive: true })
    saved.push({ out, original })
    env[out.env] = committedStamp(out.name, original)
  }

  const npm = process.platform === 'win32' ? 'npm.cmd' : 'npm'
  const built = spawnSync(npm, ['run', 'build'], {
    cwd: uiRoot,
    env,
    stdio: 'inherit',
    // npm.cmd is a batch file, and Node refuses to spawn one without a shell
    // since the 2024 argument-injection fix. The arguments are constants.
    shell: process.platform === 'win32',
  })

  if (built.error) throw built.error
  if (built.status !== 0) {
    console.error(`br_ui: build failed with status ${built.status}`)
  } else {
    let clean = true
    for (const { out, original } of saved) {
      const differences = compareTrees(original, out.dir)
      if (differences.length === 0) {
        console.log(`${out.name}: committed bundle matches source`)
      } else {
        clean = false
        console.error(`${out.name}: committed bundle does not match source:`)
        for (const difference of differences) console.error(`  ${difference}`)
      }
    }
    if (clean) status = 0
    else console.error('Fix: cd ui-src && npm run build')
  }
} catch (error) {
  console.error(`br_ui: build check failed: ${error instanceof Error ? error.message : error}`)
} finally {
  for (const { out, original } of saved) {
    rmSync(out.dir, { recursive: true, force: true })
    if (existsSync(original)) cpSync(original, out.dir, { recursive: true })
  }
  rmSync(scratch, { recursive: true, force: true })
}

process.exit(status)
