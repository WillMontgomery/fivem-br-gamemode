import '@cloudscape-design/global-styles/index.css'
import './terminal.css'
import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { applyMode, disableMotion, Mode } from '@cloudscape-design/global-styles'
import { App } from './App'

// DARK MODE ON <body>, NEVER ON <html> (#385). global-styles ships
// `html:has(body.awsui-dark-mode){color-scheme:dark}`; Chromium 103 drops it,
// a CEF of 105 or later would honor it, and terminal.css pins color-scheme
// back to normal either way. applyMode's default target is document.body.
applyMode(Mode.Dark)
// Fewer animations, fewer repainted frames over the game.
disableMotion(true)

// THE BUILD STAMP, on F8 and nowhere on screen: "did my change reach the
// game?" is answered here. scripts/check-build.mjs rebuilds with this exact
// string to prove the committed bundle is current.
console.info(`[terminal] ${__TERMINAL_BUILD_STAMP__}`)

const root = document.getElementById('root')
if (root) {
  createRoot(root).render(
    <StrictMode>
      <App />
    </StrictMode>,
  )
}
