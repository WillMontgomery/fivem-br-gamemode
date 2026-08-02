import { execSync } from 'node:child_process'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
// Tailwind 3 runs through PostCSS (see postcss.config.js), not a Vite plugin.

// WHY THIS PROJECT LIVES OUTSIDE resources/
//
// FXServer automatically builds any resource containing a package.json, using
// its own bundled yarn and Node 16. This toolchain needs Node >= 18, so the
// server would try to build an already-built resource and fail:
//
//   error tar@7.5.22: The engine "node" is incompatible with this module.
//   Expected version ">=18". Got "16.9.1"
//   Building resource br_ui failed.
//
// The resource does not need building on the server -- ui/ is committed. So the
// build project sits outside resources/, which is the only tree FXServer scans,
// and writes its output into the resource.
//
// Build config below is shaped by NUI's constraints, not by web defaults.
// Build stamp.
//
// Four fixes were shipped for one bug without any way to confirm the client was
// running any of them. "Did my change actually reach the game?" is not a
// question that should ever need guessing at, and re-testing against a stale
// bundle wastes a whole round trip.
// NOTE ON THE REV: it is the commit the build was made FROM, not the commit
// containing the bundle -- the build necessarily happens before the commit that
// records it, so the hash always reads one behind. The timestamp is the
// unambiguous half; use it to confirm a bundle is current.
const BUILD_STAMP = (() => {
  const t = new Date().toISOString().replace('T', ' ').slice(0, 19)
  let rev = 'nogit'
  try {
    rev = execSync('git rev-parse --short HEAD', { encoding: 'utf8' }).trim()
  } catch { /* building outside a repo is fine */ }
  return `built ${t} (from ${rev})`
})()

export default defineConfig({
  plugins: [react()],

  define: {
    __BUILD_STAMP__: JSON.stringify(BUILD_STAMP),
  },

  // NUI serves from the nui:// scheme, so every asset reference must be
  // relative. An absolute '/assets/...' resolves to nothing and the page is blank.
  base: './',

  build: {
    // Writes into the resource, which is where fxmanifest.lua serves from.
    outDir: '../resources/[fivem-royale]/br_ui/ui',
    // Required because outDir is outside this project root; without it Vite
    // refuses to clean the directory.
    emptyOutDir: true,

    // MEASURED, not guessed: the in-game probe reports Chrome 103. This only
    // constrains JS syntax -- CSS is handled by Tailwind 3 plus autoprefixer,
    // and enforced by scripts/check-css.mjs.
    target: 'chrome103',

    // Inlining assets as data URIs bloats the single bundle and has caused
    // trouble with the nui:// scheme; keep them as real files instead.
    assetsInlineLimit: 0,

    // Not needed in-game and roughly doubles the build output.
    sourcemap: false,

    rollupOptions: {
      output: {
        // ONE bundle. Dynamic imports and code-splitting under nui:// are a
        // recurring source of silent load failures -- the page renders blank
        // with no console error. A battle royale HUD is small enough that
        // splitting buys nothing anyway.
        manualChunks: undefined,

        // Stable filenames. fxmanifest lists these, and stable names keep the
        // manifest honest; refresh with `restart br_ui`, not a hash change.
        entryFileNames: 'assets/[name].js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name][extname]',
      },
    },
  },

  server: {
    // `npm run dev` runs the whole UI in a normal browser against mocked NUI
    // events (see src/bridge/mock.ts). This is the fast iteration loop -- the
    // game does not need to be running to build screens.
    port: 3000,
    strictPort: false,
  },
})
