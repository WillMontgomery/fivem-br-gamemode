/**
 * The module resolve hook that puts scripts/aws_stub.mjs where the AWS SDK
 * would be, so scripts/test.mjs can import the REAL src/index.js.
 *
 * A HOOK RATHER THAN A REWRITE. The alternative was reading index.js, swapping
 * its import specifiers and importing the result -- which tests a file the
 * build never sees. This resolves the untouched source; only the edge of it
 * moves.
 *
 * A PREFIX MATCH, NOT A LIST OF THREE. A NEW `@aws-sdk/*` import added to
 * src/index.js lands here too, and fails at link time on the export the stub
 * does not have -- which says "extend the fake" in one line. Falling through to
 * the real SDK instead would make the new code path quietly try to reach AWS
 * from the test suite, and only on machines that happen to have node_modules.
 *
 * NOTHING ELSE IS INTERCEPTED. `node:*`, `./stats.js` and the rest resolve
 * normally.
 */

const STUB = new URL('./aws_stub.mjs', import.meta.url).href

export function resolve(specifier, context, nextResolve) {
  if (specifier.startsWith('@aws-sdk/')) {
    return { url: STUB, shortCircuit: true }
  }
  return nextResolve(specifier, context)
}
