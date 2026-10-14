// THE BUILD HALF OF src/cef/zoomRect.ts (#413): every `.getBoundingClientRect()`
// in a @cloudscape-design/* module becomes `.__brZoomRect()`, and the module
// imports the file that defines it, so it is defined before anything calls it.
//
// Why: Cloudscape measures boxes and writes the numbers back as CSS px inside
// Locker v2's zoomed island. CEF 103 measured in the island's own px; CEF 144
// (Chromium 128+, standardized zoom) measures in screen px, so every size came
// out multiplied by the zoom. zoomRect.ts answers as 103 did on both engines.
//
// br_ui only (vite.config.ts): the Rollup plugin for `vite build`, and the
// esbuild one for the dev server's pre-bundled dependencies, which Rollup
// plugins never see -- so `npm run dev` in a desktop Chrome (128+, like CEF
// 144) measures as the game does. scripts/test-cef.mjs runs rewriteRects, and
// check-cef C9 holds vite.config.ts to both plugins.

import { readFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const HELPER = fileURLToPath(new URL('../src/cef/zoomRect.ts', import.meta.url)).replace(/\\/g, '/')
const CLOUDSCAPE = /[\\/]node_modules[\\/]@cloudscape-design[\\/][^?]*\.m?js(\?|$)/
const CALL = /\.getBoundingClientRect\(\s*\)/g

/** The rewrite itself: null when the module measures nothing. */
export function rewriteRects(code, helper = HELPER) {
  CALL.lastIndex = 0
  if (!CALL.test(code)) return null
  CALL.lastIndex = 0
  return `import ${JSON.stringify(helper)};\n${code.replace(CALL, '.__brZoomRect()')}`
}

export function isCloudscape(id) {
  return CLOUDSCAPE.test(id)
}

/** `vite build`. */
export function zoomRectPlugin() {
  return {
    name: 'br-zoom-rect',
    enforce: 'pre',
    transform(code, id) {
      if (!isCloudscape(id)) return null
      const out = rewriteRects(code)
      return out === null ? null : { code: out, map: null }
    },
  }
}

/** The dev server's dependency pre-bundle (optimizeDeps.esbuildOptions.plugins). */
export function zoomRectEsbuild() {
  return {
    name: 'br-zoom-rect',
    setup(build) {
      build.onLoad({ filter: /[\\/]@cloudscape-design[\\/].*\.m?js$/ }, async (args) => {
        const out = rewriteRects(await readFile(args.path, 'utf8'))
        return out === null ? undefined : { contents: out, loader: 'js' }
      })
    },
  }
}
