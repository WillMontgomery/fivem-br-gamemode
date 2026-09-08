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

// NUNITO IS THE TUTORIAL'S VOICE AND NOTHING ELSE'S (#261). Owner, 2026-09-04,
// on the guided first run: the flyout cards "should feel more casual than our
// existing fonts -- the flyouts are a deliberate exception to the rest of the
// UX and should read as one".
//
// THE VARIABLE CUT, AND THAT IS FORCED RATHER THAN PREFERRED. He asked for
// "font weight 700 on the titles/headers, and font weight 350 on the body", and
// 350 is not a weight Fontsource ships as a static file -- the static package
// stops at 200/300/400/... So this is @fontsource-variable, whose axis is
// 200-1000 in steps of 1 and therefore has a real 350 rather than a browser
// faking one by smearing 300 and 400.
//
// FIVE @font-face BLOCKS, ONE DOWNLOAD. `wght.css` declares latin, latin-ext,
// cyrillic, cyrillic-ext and vietnamese, each behind its own unicode-range, so
// a player fetches only the subset their text actually needs. The other four
// ship in the resource and are never read; that is how the format works and is
// cheaper than hand-writing an @font-face against a hashed filename.
//
// FONTSOURCE, LIKE THE OTHER TWO, so this stays a self-hosted OFL font in the
// bundle rather than a request to Google on a machine that may have no route to
// it -- and so it costs nothing, which is the standing rule on UI dependencies.
import '@fontsource-variable/nunito/wght.css'

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
  const w = window as unknown as {
    brcues: (c?: string) => void
    brsound: () => void
  }
  w.brcues = (c) => {
    if (c) { a.play(c as never); return }
    a.CUE_NAMES.forEach((name, i) => {
      setTimeout(() => { console.log('cue:', name); a.play(name) }, i * 700)
    })
  }
  // WHAT THE AUDIO GRAPH ACTUALLY IS. Interface sound being quiet on one
  // machine and right on another (user, 2026-08-09) is not something this
  // code can see -- sample rate, channel count and the context's own state
  // differ per client and are invisible any other way. `brsound()` on both
  // machines turns "it is quiet" into two lines that can be compared.
  w.brsound = () => console.log('[br_ui] sound', a.soundReport())
})

createRoot(root).render(
  <StrictMode>
    <HeroUIProvider>
      <App />
    </HeroUIProvider>
  </StrictMode>,
)
