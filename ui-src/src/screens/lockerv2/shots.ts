import { useSyncExternalStore } from 'react'
import { fetchNui } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import { useUi } from '../../store'
import { canvasImage, imgOk, shotKey, shotStorable } from './model'

/**
 * THE HEADSHOTS ON MY PEDS (#28; contract section 6 with the skeptic's 6).
 *
 * "in the list of saved peds we should display a headshot using
 * RegisterPedHeadshot - if we can display it in NUI and store it in DDB"
 * (owner). Lua takes the shot -- at Save from the player's own ped, or from a
 * local clone for a saved ped that has none stored -- and hands the page the
 * texture's name. The page draws it to a 64 px canvas, keeps the webp for the
 * session under `id@up`, sends it to be stored (LOCKER2_SHOT, within 8 KB)
 * and tells Lua it is done with the texture (LOCKER2_SHOTDONE).
 *
 * NOT OVER-INVESTED IN, as asked: any failure -- no texture, a canvas that
 * will not encode, three seconds with no image -- leaves a plain card, and
 * nothing is asked for twice.
 *
 * A STORED PICTURE COMES THE SAME WAY, ONCE: Lua answers the ask with the
 * server's webp (`img`, no texture), kept here under `id@up` like a new one.
 * It never rides on the locker2 push, which goes out on every press (#28
 * review).
 */

const cache = new Map<string, string>()
const asked = new Set<string>()
const listeners = new Set<() => void>()
let version = 0
let nonce = 0

const SIZE = 64
const WAIT_MS = 3000
/** Lower qualities only if the first does not fit in 8 KB. */
const QUALITIES = [0.9, 0.75, 0.6, 0.45]

function changed() {
  version++
  for (const fn of listeners) fn()
}

/** Re-render on any cache change. */
export function useShotCache(): ReadonlyMap<string, string> {
  useSyncExternalStore(
    (fn) => { listeners.add(fn); return () => { listeners.delete(fn) } },
    () => version,
  )
  return cache
}

export const cachedKeys = (): ReadonlySet<string> => new Set(cache.keys())
export const askedKeys = (): ReadonlySet<string> => asked
export function markAsked(keys: string[]): void { for (const k of keys) asked.add(k) }

/** The picture for a saved ped: the stored one, else this session's. */
export function shotFor(p: { id: string; up: number; img?: unknown }, c: ReadonlyMap<string, string>) {
  if (imgOk(p.img)) return p.img
  return c.get(shotKey(p.id, p.up)) ?? null
}

/** A saved ped's stored picture, from Lua: kept for the session. */
export function keepShot(id: unknown, up: unknown, img: unknown): void {
  if (typeof id !== 'string' || typeof up !== 'number' || !imgOk(img)) return
  cache.set(shotKey(id, up), img)
  changed()
}

/** A texture is ready in Lua: draw it, keep it, send it to be stored. */
export function takeShot(id: unknown, txd: unknown): void {
  if (typeof id !== 'string' || typeof txd !== 'string') return
  let settled = false
  const finish = (ok: boolean) => {
    if (settled) return
    settled = true
    window.clearTimeout(timer)
    void fetchNui(CB.LOCKER2_SHOTDONE, { id, ok })
  }
  const timer = window.setTimeout(() => finish(false), WAIT_MS)
  // A texture dictionary is a plain name; anything else is not one of Lua's.
  if (!/^[A-Za-z0-9_-]{1,64}$/.test(txd)) { finish(false); return }

  const img = new Image()
  img.onerror = () => finish(false)
  img.onload = () => {
    try {
      const canvas = document.createElement('canvas')
      canvas.width = SIZE
      canvas.height = SIZE
      const ctx = canvas.getContext('2d')
      if (!ctx) { finish(false); return }
      ctx.drawImage(img, 0, 0, SIZE, SIZE)
      let data = ''
      for (const q of QUALITIES) {
        data = canvas.toDataURL('image/webp', q)
        if (shotStorable(data)) break
      }
      if (!imgOk(data)) { finish(false); return }
      // Keyed by the `up` the page has for it now; a ped saved again gets a
      // new `up` and so a new picture.
      const ped = useUi.getState().locker2.peds.find((p) => p.id === id)
      if (ped) { cache.set(shotKey(ped.id, ped.up), data); changed() }
      if (shotStorable(data)) void fetchNui(CB.LOCKER2_SHOT, { id, img: data })
      finish(true)
    } catch {
      finish(false)
    }
  }
  // THE NONCE IS NOT DECORATION: Lua reuses headshot texture names, and CEF
  // caches nui-img by URL, so without it a new picture shows as the old one.
  // canvasImage asks for it with CORS, or the canvas above could not be read.
  nonce++
  canvasImage(img, `https://nui-img/${txd}/${txd}?v=${nonce}`)
}
