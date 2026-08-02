import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import App from './App'
import { installErrorSinks, isBrowser } from './bridge/nui'
import './index.css'

// Install these BEFORE rendering. A crash during the first render is exactly the
// case where a blank screen with no console output is most likely, and this is
// what turns that into a line in the F8 console and the server log.
installErrorSinks()

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

createRoot(root).render(
  <StrictMode>
    <App />
  </StrictMode>,
)
