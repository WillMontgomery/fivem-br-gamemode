import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { HeroUIProvider } from '@heroui/react'
import App from './App'
import { installErrorSinks, isBrowser, reportEnvironment } from './bridge/nui'
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

createRoot(root).render(
  <StrictMode>
    <HeroUIProvider>
      <App />
    </HeroUIProvider>
  </StrictMode>,
)
