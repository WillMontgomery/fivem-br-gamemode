import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { HeroUIProvider } from '@heroui/react'
import App from './App'
import { installErrorSinks, isBrowser, reportEnvironment } from './bridge/nui'

// FONTS, SELF-HOSTED. Never a CDN: CEF has no network on a cold boot, and a
// font that fails to arrive is worse than one that was never asked for -- it
// falls back silently and the layout still looks plausible, so nobody notices
// the game is set in the operating system's UI font.
//
// LATIN SUBSETS ONLY, and only the weights actually used. The full packages
// carry latin-ext and vietnamese, which is ~3x the bytes for glyphs no screen
// in this project renders.
//
// Vite emits these into ui/assets/ with content hashes, which is why
// br_ui/fxmanifest.lua globs 'ui/assets/*.woff2' rather than naming them.
import '@fontsource/anton/latin-400.css'
import '@fontsource/barlow/latin-400.css'
import '@fontsource/barlow/latin-500.css'
import '@fontsource/barlow/latin-600.css'
import '@fontsource/barlow/latin-700.css'

import './index.css'

// Install these BEFORE rendering. A crash during the first render is exactly the
// case where a blank screen with no console output is most likely, and this is
// what turns that into a line in the F8 console and the server log.
installErrorSinks()

// Report what this CEF build can actually render. Colour functions in
// particular differ enough between CEF versions to make a correct stylesheet
// render as no styling at all.
reportEnvironment()

if (import.meta.env.DEV && isBrowser) {
  // Running under `npm run dev`: drive the UI with fake envelopes so screens can
  // be built without the game open. Compiled out of production builds entirely.
  void import('./bridge/mock').then((m) => m.startMockDriver())
  document.body.style.background =
    'linear-gradient(135deg, #10131c 0%, #1a1230 60%, #0c1420 100%)'
  // The dev page needs clicks; in game the root stays click-through.
  document.body.style.pointerEvents = 'auto'
}

const root = document.getElementById('root')
if (!root) {
  throw new Error('#root missing from index.html')
}

// HeroUI 2 resolves its theme from a class on an ancestor. Without `dark` here
// it falls back to the light theme, which over a game world is actively wrong
// rather than merely unstyled.
document.documentElement.classList.add('dark')

// AUDITIONING OUR OWN CUES.
//
// /brsfx in Lua can only play the native combat cues -- everything else is
// synthesised in the browser and Lua cannot reach it. Exposed on window so the
// palette can be heard from the F8 console with:
//
//     brcues()            play every cue, 700ms apart
//     brcues('ui.back')   play one
void import('./audio/cues').then((a) => {
  ;(window as unknown as { brcues: (c?: string) => void }).brcues = (c) => {
    if (c) { a.play(c as never); return }
    a.CUE_NAMES.forEach((name, i) => {
      setTimeout(() => { console.log('cue:', name); a.play(name) }, i * 700)
    })
  }
})

createRoot(root).render(
  <StrictMode>
    <HeroUIProvider>
      <App />
    </HeroUIProvider>
  </StrictMode>,
)
