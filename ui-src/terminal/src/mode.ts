/**
 * LIGHT OR DARK, REMEMBERED PER PLAYER -- LIGHT UNTIL THEY CHOOSE.
 *
 * Owner, 2026-10-05: "It should also include a light/dark mode toggle." And in
 * round 2: "Make light mode the default, and dark/light mode should not
 * influence the browser's appearance, only the website."
 *
 * LIGHT BY DEFAULT, UNDER A NEW KEY. The first round remembered the choice
 * under 'blitz-terminal-mode:' with dark as the default, so a tester who
 * toggled anything has a value there; reading a new key starts everyone on
 * light once, and the choice is remembered from then on. The old key is never
 * read again.
 *
 * THE SITE ONLY. Cloudscape's mode is a class on <body>, which every part of
 * the site -- the top navigation, the side navigation, the cards, the pages,
 * the panels, and the dialogs and dropdowns Cloudscape renders into <body> --
 * reads its colors from. The browser around it is drawn with fixed colors and
 * none of Cloudscape's: its toolbar (Browser.tsx, terminal.css's
 * `.browser-toolbar`) here, and the window's frame and tab in the desktop
 * (cuchi_computer's br.css), which the app no longer tells about its mode.
 *
 * ON <body>, NEVER ON <html> (#385). applyMode's default target is
 * document.body; global-styles ships `html:has(body.awsui-dark-mode)
 * {color-scheme:dark}`, which Chromium 103 drops and a CEF of 105 or later
 * would honour by painting the canvas opaque -- terminal.css pins
 * color-scheme back to normal either way.
 *
 * REMEMBERED IN THIS PAGE'S localStorage, keyed by the player's gamertag, so
 * two players sharing a PC keep their own. NUI localStorage belongs to the
 * resource name on the player's machine (VENDOR.json's BR-PATCH 7 says why that
 * mattered for upstream's theme); this key is the app's own and nothing else
 * reads it. EVERY ACCESS IS WRAPPED: storage that throws or comes back empty
 * is the default, light.
 */

import { applyMode, Mode } from '@cloudscape-design/global-styles'

export type UiMode = 'light' | 'dark'

const KEY = 'control-tower-mode:'

export function loadMode(player: string | null): UiMode {
  try {
    const v = window.localStorage.getItem(KEY + (player ?? ''))
    return v === 'dark' ? 'dark' : 'light'
  } catch {
    return 'light'
  }
}

export function saveMode(player: string | null, mode: UiMode): void {
  try {
    window.localStorage.setItem(KEY + (player ?? ''), mode)
  } catch {
    // Not remembered; still applied.
  }
}

/** Put the mode on <body>: the site's colors, and nothing of the browser's. */
export function showMode(mode: UiMode): void {
  applyMode(mode === 'dark' ? Mode.Dark : Mode.Light)
}
