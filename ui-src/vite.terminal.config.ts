import { execSync } from 'node:child_process'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

// THE SEASON 2 TERMINAL APP (#396): a SECOND build out of this one project.
//
// React + @cloudscape-design/components, built with the same toolchain, the
// same lockfile and the same Chromium 103 target as br_ui (vite.config.ts), and
// written into the vendored cuchi_computer, whose desktop window frames it.
// Its own config rather than a second input in vite.config.ts because the two
// pages share nothing: br_ui is one bundle for the HUD and must stay one, and
// the terminal app is a separate document in a separate resource. One project
// rather than its own package because a second lockfile is a second set of
// versions to keep in step, and CI's `npm run build:check` already proves every
// byte of whatever `npm run build` writes.
//
// CEF 103 FINDINGS (#385) THIS BUILD RESPECTS, and scripts/check-terminal.mjs
// holds: no Spinner or `loading` (it animates forever), dark mode on <body> and
// color-scheme pinned normal, arrays rather than Fragments into layout
// components, no Link / CopyToClipboard / FileUpload / FileInput / FileDropzone
// / Steps / AppLayout / SideNavigation, no dynamic import. Cloudscape's ~65
// :has() rules are dropped by 103 and degrade polish only; scripts/check-css.mjs
// reports them as warnings, and fails on any unparseable color.

// Same shape as vite.config.ts's stamp, under its own name, so check-build.mjs
// can rebuild each output with the stamp that output was committed with.
const BUILD_STAMP = process.env.BR_TERMINAL_BUILD_STAMP ?? (() => {
  const t = new Date().toISOString().replace('T', ' ').slice(0, 19)
  let rev = 'nogit'
  try {
    rev = execSync('git rev-parse --short HEAD', { encoding: 'utf8' }).trim()
  } catch { /* building outside a repo is fine */ }
  return `built ${t} (from ${rev})`
})()

export default defineConfig({
  root: fileURLToPath(new URL('./terminal', import.meta.url)),
  plugins: [react()],

  define: {
    __TERMINAL_BUILD_STAMP__: JSON.stringify(BUILD_STAMP),
  },

  // nui:// and https://cfx-nui-* both need relative asset paths.
  base: './',

  build: {
    outDir: fileURLToPath(
      new URL('../resources/[computer]/cuchi_computer/nui/apps/terminal', import.meta.url),
    ),
    // The output directory is the app's alone; nothing of upstream's is in it.
    emptyOutDir: true,
    target: 'chrome103',
    assetsInlineLimit: 0,
    sourcemap: false,
    rollupOptions: {
      output: {
        // ONE bundle, as br_ui does: a chunk that fails to load under nui://
        // is a blank page with no error.
        inlineDynamicImports: true,
        entryFileNames: 'assets/terminal.js',
        chunkFileNames: 'assets/[name].js',
        assetFileNames: 'assets/[name][extname]',
      },
    },
  },
})
