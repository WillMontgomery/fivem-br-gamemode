/**
 * LIGHT OR DARK, REMEMBERED PER PLAYER.
 *
 * Owner, 2026-10-05: "It should also include a light/dark mode toggle."
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
 * is the default, dark.
 */

import { applyMode, Mode } from '@cloudscape-design/global-styles'
import { tellMode } from './bridge'

export type UiMode = 'light' | 'dark'

const KEY = 'blitz-terminal-mode:'

export function loadMode(player: string | null): UiMode {
  try {
    const v = window.localStorage.getItem(KEY + (player ?? ''))
    return v === 'light' ? 'light' : 'dark'
  } catch {
    return 'dark'
  }
}

export function saveMode(player: string | null, mode: UiMode): void {
  try {
    window.localStorage.setItem(KEY + (player ?? ''), mode)
  } catch {
    // Not remembered; still applied.
  }
}

/** Put the mode on <body> and tell the desktop, so the window's tab follows. */
export function showMode(mode: UiMode): void {
  applyMode(mode === 'dark' ? Mode.Dark : Mode.Light)
  tellMode(mode)
}
