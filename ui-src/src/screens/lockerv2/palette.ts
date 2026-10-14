import { useSyncExternalStore } from 'react'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2PalPayload } from '../../bridge/types'
import { parsePal } from './model'

/**
 * THE TWO COLOR PALETTES (owner's point 1, 2026-10-13: hair and makeup colors
 * "as a swatch grid instead of "Next color""), kept for the session.
 *
 * The game knows each color as an index; only Lua can turn one into a color
 * (GetPedHairRgbColor, GetPedMakeupRgbColor). So Lua sends both palettes once,
 * when the editor first asks (LOCKER2_PAL), as a `locker2pal`, and every
 * swatch grid and summary chip reads them from here. A palette that has not
 * come yet draws no grid -- the row keeps its stepper -- and is asked for
 * again the next time the editor opens.
 */

let pal: Locker2PalPayload | null = null
let asked = false
const listeners = new Set<() => void>()

/** The palettes from Lua, made safe to draw and kept. */
export function keepPal(raw: unknown): void {
  const p = parsePal(raw)
  if (!p) return
  pal = p
  for (const fn of listeners) fn()
}

/** Ask Lua for the palettes, unless they are here or on their way. */
export function askPal(): void {
  if (pal || asked) return
  asked = true
  void fetchNui(CB.LOCKER2_PAL).finally(() => { asked = false })
}

/** The palettes, or null until they have come; re-renders when they do. */
export function usePal(): Locker2PalPayload | null {
  return useSyncExternalStore(
    (fn) => { listeners.add(fn); return () => { listeners.delete(fn) } },
    () => pal,
  )
}
