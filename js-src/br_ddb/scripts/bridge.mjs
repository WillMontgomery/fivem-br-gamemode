/**
 * Load src/index.js the way FXServer does, and hand the tests its handlers.
 *
 * ═══ WHAT WAS MISSING, AND WHAT THIS IS FOR ═══
 *
 * src/index.js is twenty `on('br:ddb:...', handler)` registrations and nothing
 * else -- the whole file is side effects. Every extracted builder it calls has
 * cases in scripts/test.mjs; not one CALL SITE did, because importing the file
 * meant importing the AWS SDK. That gap shipped `buildStatsUpdate(d)` to a live
 * server on 2026-08-30 against a parameter named `deltas`, and nothing in this
 * repository could have caught it: the bundler leaves an unbound identifier
 * alone, the fingerprint gate hashes bytes, and the suite never ran the line.
 *
 * So: FiveM's three globals are stubbed here, the SDK is stubbed next door in
 * aws_stub.mjs, and the real source is imported. A handler that references a
 * name which is not in scope now throws where a test can see it.
 *
 * ═══ THE GLOBALS ═══
 *
 * `on`, `emit` and `GetConvar` are injected by the FXServer runtime and are the
 * only three this file uses (`console` and `setTimeout` are Node's). They must
 * exist BEFORE the import, because `GetConvar` is called at module scope --
 * REGION, the table prefixes and the artifact spool are all read on load.
 *
 * ═══ TIMERS ARE UNREF'D ═══
 *
 * `withTimeout` races every send against a 3000ms `setTimeout` and never clears
 * it, so a suite that drove twenty handlers would sit for three seconds after
 * its last assertion waiting for timers whose result nobody wants. Unref'ing
 * them lets the process leave when the work is done. Nothing else about them
 * changes, and the timeout still fires and still rejects if a test waits that
 * long. Tests that need to yield use `setImmediate`, which is NOT unref'd.
 */

import { register } from 'node:module'
import { mkdtempSync, rmSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { calls, replies, reset as resetSdk } from './aws_stub.mjs'

/**
 * `module.register` is Node 20.6 / 18.19 and later. A box older than that gets
 * a FAILURE rather than a skip -- #218's lesson is that a gate which excuses
 * itself is a gate nobody notices is gone, and "the handlers were not run" is
 * exactly the state this file exists to end.
 */
export const HOOKS_SUPPORTED = typeof register === 'function'

/** Everything the bridge has emitted back at Lua, oldest first. */
export const emitted = []

/** Whatever the bridge printed during the last `call`. */
export const logs = []

const handlers = new Map()

let spoolDir = null
let loaded = null

/**
 * @returns {Promise<object>} the bridge, with its handlers reachable by name
 */
export async function loadBridge() {
  if (loaded) return loaded
  if (!HOOKS_SUPPORTED) {
    throw new Error('node:module register() is unavailable -- needs Node 20.6 or later')
  }

  register(new URL('./aws_stub_hooks.mjs', import.meta.url))

  // The artifact handlers spool to disk before uploading. Point them somewhere
  // disposable; everything else keeps its shipped default, so the table names
  // the assertions pin (`br-players`, `ringmaster-incidents`) are the real ones.
  spoolDir = mkdtempSync(join(tmpdir(), 'br_ddb-test-'))
  const CONVARS = { br_artifacts_dir: spoolDir }

  globalThis.GetConvar = (key, fallback) =>
    Object.hasOwn(CONVARS, key) ? CONVARS[key] : fallback
  globalThis.on = (name, fn) => handlers.set(name, fn)
  globalThis.emit = (name, ...args) => emitted.push({ name, args })

  const realSetTimeout = globalThis.setTimeout
  globalThis.setTimeout = (...args) => {
    const t = realSetTimeout(...args)
    if (t && typeof t.unref === 'function') t.unref()
    return t
  }

  // The module logs a ready line on load. It is not what is under test and it
  // would sit in the middle of the assertions.
  const quiet = capture()
  try {
    await import(new URL('../src/index.js', import.meta.url).href)
  } finally {
    quiet()
  }

  loaded = {
    handlers,
    emitted,
    logs,
    calls,
    spoolDir,
    call,
    reply,
    settle,
    reset,
    cleanup,
  }
  return loaded
}

function capture() {
  const real = console.log
  console.log = (...args) => logs.push(args.map(String).join(' '))
  return () => {
    console.log = real
  }
}

/**
 * Invoke one handler the way `TriggerEvent` does.
 *
 * RETURNS THE THROW RATHER THAN PROPAGATING IT. A ReferenceError escaping into
 * the suite would abort the run at the first bad handler and report itself as a
 * crash; returned, it becomes one named failing assertion with the message in
 * it -- which is how `d is not defined` should have read the first time.
 *
 * @returns {Error|null}
 */
function call(name, ...args) {
  const fn = handlers.get(name)
  if (!fn) return new Error(`no handler registered for ${name}`)
  logs.length = 0
  const quiet = capture()
  try {
    fn(...args)
    return null
  } catch (e) {
    return e
  } finally {
    quiet()
  }
}

/** Queue one answer for the next `send`. An Error is rejected, not returned. */
function reply(answer) {
  replies.push(answer)
  return answer
}

/**
 * Let the promise chains inside a handler run.
 *
 * `setImmediate`, not `setTimeout`: the timers this file unref'd cannot hold
 * the loop open, and a zero-delay one might not be enough to keep the process
 * alive to hear its own answer.
 */
function settle() {
  const quiet = capture()
  return new Promise((r) => setImmediate(r)).then(() => {
    quiet()
  })
}

function reset() {
  resetSdk()
  emitted.length = 0
  logs.length = 0
}

/** The last answer emitted on `name`, or null. */
export function lastEmit(name) {
  for (let i = emitted.length - 1; i >= 0; i--) {
    if (emitted[i].name === name) return emitted[i]
  }
  return null
}

function cleanup() {
  if (spoolDir) rmSync(spoolDir, { recursive: true, force: true })
  spoolDir = null
}
