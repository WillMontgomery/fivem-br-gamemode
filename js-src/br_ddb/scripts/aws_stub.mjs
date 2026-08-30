/**
 * A DynamoDB and an S3 that record instead of calling.
 *
 * ═══ WHY THIS EXISTS ═══
 *
 * Everything in src/index.js that is NOT a pure function -- the twenty event
 * handlers -- was untestable for one reason: importing it pulls in
 * `@aws-sdk/client-dynamodb`, which needs js-src/br_ddb/node_modules, which
 * (per tools/br_ddb_fingerprint.sh, and #218 before it) nobody has. So the
 * suite tested the builders and left every CALLER of them unexercised, and on
 * 2026-08-30 a caller shipped `buildStatsUpdate(d)` against a parameter named
 * `deltas`. It bundled, it passed the JS suite, it passed verify.sh, and it
 * threw `ReferenceError: d is not defined` on every match end on the live
 * server -- losing XP, Volts, balance and match stats for as long as it ran.
 *
 * The fix for the TYPO is one word. The fix for the GAP is this file: the
 * handlers now run.
 *
 * ═══ THE REAL src/index.js IS IMPORTED, BYTE FOR BYTE ═══
 *
 * scripts/aws_stub_hooks.mjs redirects the three `@aws-sdk/*` specifiers here
 * through a module resolve hook, so nothing rewrites, patches or re-implements
 * the source under test. The file the test drives is the file the build
 * bundles. That is the whole point -- a harness that edited the source would
 * be testing something the game box never runs.
 *
 * ═══ THE MARSHALLER IS REAL, NOT AN IDENTITY FUNCTION ═══
 *
 * An identity `marshall` would let a handler send `{N: undefined}` and the
 * assertions would happily agree with it. This one produces genuine attribute
 * values and REFUSES an undefined without `removeUndefinedValues`, the same way
 * the SDK does -- so the shape the handlers build is actually checked, and the
 * values can be unmarshalled back and applied to a row.
 *
 * It is not a complete DynamoDB. It models the value kinds this bridge writes
 * and throws, loudly, on anything else: a value the fake cannot express is a
 * value the assertions are not really testing. Same rule as `fakeUpdate` in
 * scripts/test.mjs.
 */

/** Every command the bridge has sent, oldest first. */
export const calls = []

/**
 * Answers, queued. Each `send` shifts one; an `Error` is thrown back at the
 * caller rather than returned, which is how the failure paths get exercised.
 * An empty queue answers `{}` -- the "no such item" shape.
 */
export const replies = []

export function reset() {
  calls.length = 0
  replies.length = 0
}

class FakeClient {
  constructor(config) {
    this.config = config
  }

  send(command) {
    calls.push(command)
    const next = replies.shift()
    if (next instanceof Error) return Promise.reject(next)
    return Promise.resolve(next ?? {})
  }
}

export class DynamoDBClient extends FakeClient {}
export class S3Client extends FakeClient {}

/**
 * Commands keep their input and nothing else, which is all the assertions want:
 * the question is what the handler ASKED for, not what the SDK would do with it.
 */
class Command {
  constructor(input) {
    this.input = input
    this.kind = this.constructor.name
  }
}

export class GetItemCommand extends Command {}
export class PutItemCommand extends Command {}
export class UpdateItemCommand extends Command {}
export class BatchWriteItemCommand extends Command {}
export class PutObjectCommand extends Command {}

function attr(v, drop, path) {
  if (v === null) return { NULL: true }
  if (typeof v === 'boolean') return { BOOL: v }
  if (typeof v === 'number') {
    // The SDK refuses these too. A NaN reaching a counter would land as a
    // corrupt number rather than as an error, which is the failure mode the
    // `num()` coercions all over src/ exist to prevent.
    if (!Number.isFinite(v)) throw new Error(`marshall: ${path} is ${v}`)
    return { N: String(v) }
  }
  if (typeof v === 'string') return { S: v }
  if (Array.isArray(v)) return { L: v.map((x, i) => attr(x, drop, `${path}[${i}]`)) }
  if (v instanceof Set) {
    const members = [...v]
    if (members.length === 0) throw new Error(`marshall: ${path} is an empty set`)
    return members.every((m) => typeof m === 'number')
      ? { NS: members.map(String) }
      : { SS: members.map(String) }
  }
  if (typeof v === 'object') return { M: marshall(v, { removeUndefinedValues: drop }) }
  throw new Error(`marshall: ${path} is a ${typeof v}, which this fake cannot express`)
}

/**
 * @param {Record<string, unknown>} value
 * @param {{ removeUndefinedValues?: boolean }} [opts]
 */
export function marshall(value, opts = {}) {
  const drop = opts.removeUndefinedValues === true
  const out = {}
  for (const [k, v] of Object.entries(value ?? {})) {
    if (v === undefined) {
      if (drop) continue
      // The SDK's own wording, near enough: an undefined that is not explicitly
      // dropped is a bug in the caller and must not become a missing attribute.
      throw new Error(
        `marshall: '${k}' is undefined -- pass removeUndefinedValues to drop it`,
      )
    }
    out[k] = attr(v, drop, k)
  }
  return out
}

function plain(a, path) {
  if (a === null || typeof a !== 'object') {
    throw new Error(`unmarshall: ${path} is not an attribute value`)
  }
  if ('NULL' in a) return null
  if ('BOOL' in a) return a.BOOL
  if ('N' in a) return Number(a.N)
  if ('S' in a) return a.S
  if ('L' in a) return a.L.map((x, i) => plain(x, `${path}[${i}]`))
  if ('M' in a) return unmarshall(a.M)
  if ('SS' in a) return new Set(a.SS)
  if ('NS' in a) return new Set(a.NS.map(Number))
  throw new Error(`unmarshall: ${path} has no kind this fake knows`)
}

/** @param {Record<string, unknown>} item */
export function unmarshall(item) {
  const out = {}
  for (const [k, v] of Object.entries(item ?? {})) out[k] = plain(v, k)
  return out
}
