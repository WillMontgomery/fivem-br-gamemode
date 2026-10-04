import { useEffect, useReducer, useRef, type RefObject } from 'react'
import { onEnvelope } from '../bridge/nui'
import type { FadeRecord } from '../bridge/screenReport'
import { createFadeClock, createFadeRegistry, FADE_SETTLE_MARGIN_MS, type FadeClock, type FadeEnd } from './fade'

export type { FadeEnd } from './fade'

/** Every named layer's latest fade, with when (ui/fade.ts, #252 round 3). */
const fades = createFadeRegistry()

/**
 * How the named layer's fade ended, if it ended at or after `since` -- or that
 * it is still fading, whenever it started.
 */
export function fadeEnd(layer: string, since = -Infinity): FadeEnd | undefined {
  return fades.end(layer, since)
}

/** Every named fade as it stands now, for the screen report's settle check. */
export function fadeRecords(): FadeRecord[] {
  return fades.records()
}

export interface FadeOptions {
  /**
   * The layer's entrance plays from its first frame. A sub-screen (ui/Page.tsx)
   * mounts AS it opens, so its window opens at mount rather than starting
   * settled the way a layer that is simply there on the first frame does.
   */
  enterOnMount?: boolean
}

/**
 * Whether `shown` has been held long enough that the layer should drop its
 * transition and simply BE its final value. See ui/fade.ts for why.
 *
 * ALSO WHAT TELLS A LAYER IT IS OFF FOR GOOD: `settled && !shown` is a layer
 * nobody can see, which is when it adds `layer-off` and stops animating
 * (index.css, #252).
 *
 * @param layer   a name for the screen report, or null for a fade it does not read
 * @param shown   the value the layer is going to, from the latest state
 * @param fadeMs  the layer's own fade duration
 * @param ref     the faded element, read once at the deadline to tell a fade
 *                the browser finished from one the timer had to finish
 */
export function useFade(
  layer: string | null,
  shown: boolean,
  fadeMs: number,
  ref?: RefObject<HTMLElement | null>,
  opts?: FadeOptions,
): boolean {
  const clock = useRef<FadeClock | null>(null)
  if (clock.current === null) {
    clock.current = createFadeClock(opts?.enterOnMount ? false : shown, fadeMs + FADE_SETTLE_MARGIN_MS)
  }
  const c = clock.current
  // EVERY RENDER, NOT ONLY THE EDGE. Idempotent: only a change of value reopens
  // the window, so this render already draws the fade rather than the settled
  // style of the value it is leaving.
  c.want(shown)

  const [, rerender] = useReducer((n: number) => n + 1, 0)
  const owner = useRef({}).current

  useEffect(() => {
    if (c.poll()) return
    if (layer) fades.open(layer, c, owner)

    let done = false
    let timer = 0
    let off = () => {}

    const finish = () => {
      done = true
      window.clearTimeout(timer)
      off()
      // Read BEFORE the re-render drops the transition: this is the one moment
      // the element still shows whether the browser got there on its own.
      if (layer) {
        const el = ref?.current
        if (el) {
          const at = parseFloat(getComputedStyle(el).opacity)
          fades.close(layer, Math.abs(at - (c.shown ? 1 : 0)) > 0.01 ? 'forced' : 'transition', c, owner)
        } else {
          fades.forget(layer)
        }
      }
      rerender()
    }
    // The timer re-arms if the window was reopened under it; a tick only ever
    // settles a fade that is already due.
    const onTimer = () => {
      if (done) return
      if (c.poll()) finish()
      else timer = window.setTimeout(onTimer, Math.max(1, c.remaining()))
    }
    const onTick = () => {
      if (!done && c.poll()) finish()
    }

    timer = window.setTimeout(onTimer, Math.max(1, c.remaining()))
    // THE TIMER'S OWN FALLBACK: every envelope from Lua re-checks the clock.
    off = onEnvelope(onTick)
    return () => {
      done = true
      window.clearTimeout(timer)
      off()
      // A fade cut off by its layer unmounting (a sub-screen gone at the end of
      // its exit) is not in flight any more: left 'fading', the screen report
      // would wait on it until it gave up. A change of value re-registers below.
      if (layer) fades.drop(layer, owner)
    }
    // `shown` is the edge; the clock and the ref are stable for the life of the layer.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [shown])

  return c.settled
}
