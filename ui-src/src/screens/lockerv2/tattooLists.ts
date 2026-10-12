import { useSyncExternalStore } from 'react'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import type { Locker2TatsPayload } from '../../bridge/types'
import { parseTats } from './model'

/**
 * THE TATTOO LISTS (owner, 2026-10-11), one per sex, kept for the session.
 *
 * Lua sends a sex's list once, when the page asks (LOCKER2_TATS): some 750
 * names is far too much to ride on the locker2 push, which goes out on every
 * press. Every push then says only which tattoos are on (`edit.tats`). A list
 * that has not come yet is asked for again the next time a Custom tab of that
 * sex is drawn; Lua answers each ask from the one it built.
 */

const lists = new Map<'m' | 'f', Locker2TatsPayload>()
const listeners = new Set<() => void>()
let version = 0

/** A list from Lua, made safe to draw and kept. */
export function keepTats(raw: unknown): void {
  const t = parseTats(raw)
  if (!t) return
  lists.set(t.sex, t)
  version++
  for (const fn of listeners) fn()
}

/** Ask Lua for a sex's list, unless it is here already. */
export function askTats(sex: 'm' | 'f'): void {
  if (!lists.has(sex)) void fetchNui(CB.LOCKER2_TATS, { sex })
}

/** A sex's list, or null until it has come; re-renders when one does. */
export function useTats(sex: 'm' | 'f' | null): Locker2TatsPayload | null {
  useSyncExternalStore(
    (fn) => { listeners.add(fn); return () => { listeners.delete(fn) } },
    () => version,
  )
  return sex !== null ? lists.get(sex) ?? null : null
}
