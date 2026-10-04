import { useEffect, useReducer, useRef, type RefObject } from 'react'
import { onEnvelope } from '../bridge/nui'
import { createFadeClock, FADE_SETTLE_MARGIN_MS, type FadeClock } from './fade'

/**
 * How a layer's last fade came to rest, for the screen report (#252).
 *
 *   transition -- the browser finished it; the timer found nothing to do
 *   forced     -- the timer found the layer still short of its final value and
 *                 applied it. A healthy page never says this; a page whose
 *                 animation clock has stopped says it every time.
 *   fading     -- still inside its window
 */
export type FadeEnd = 'transition' | 'forced' | 'fading'

const ends = new Map<string, FadeEnd>()

/** How the named layer's last fade ended, if it has had one. */
export function fadeEnd(layer: string): FadeEnd | undefined {
  return ends.get(layer)
}

/**
 * Whether `shown` has been held long enough that the layer should drop its
 * transition and simply BE its final value. See ui/fade.ts for why.
 *
 * @param layer   a name for the screen report
 * @param shown   the value the layer is going to, from the latest state
 * @param fadeMs  the layer's own fade duration
 * @param ref     the faded element, read once at the deadline to tell a fade
 *                the browser finished from one the timer had to finish
 */
export function useFade(
  layer: string,
  shown: boolean,
  fadeMs: number,
  ref?: RefObject<HTMLElement | null>,
): boolean {
  const clock = useRef<FadeClock | null>(null)
  if (clock.current === null) clock.current = createFadeClock(shown, fadeMs + FADE_SETTLE_MARGIN_MS)
  const c = clock.current
  // EVERY RENDER, NOT ONLY THE EDGE. Idempotent: only a change of value reopens
  // the window, so this render already draws the fade rather than the settled
  // style of the value it is leaving.
  c.want(shown)

  const [, rerender] = useReducer((n: number) => n + 1, 0)

  useEffect(() => {
    if (c.poll()) return
    ends.set(layer, 'fading')

    let done = false
    let timer = 0
    let off = () => {}

    const finish = () => {
      done = true
      window.clearTimeout(timer)
      off()
      // Read BEFORE the re-render drops the transition: this is the one moment
      // the element still shows whether the browser got there on its own.
      const el = ref?.current
      if (el) {
        const at = parseFloat(getComputedStyle(el).opacity)
        ends.set(layer, Math.abs(at - (c.shown ? 1 : 0)) > 0.01 ? 'forced' : 'transition')
      } else {
        ends.delete(layer)
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
    }
    // `shown` is the edge; the clock and the ref are stable for the life of the layer.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [shown])

  return c.settled
}
