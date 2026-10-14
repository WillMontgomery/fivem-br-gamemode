import { Component, lazy, Suspense, useEffect, type ComponentType, type ReactNode } from 'react'
import { fetchNui, reportError } from '../../bridge/nui'
import { CB } from '../../bridge/types'
import { sheetLoaded } from './sheet'

/**
 * THE DOOR TO LOCKER V2 (#28), and the one part of it in the main bundle.
 *
 * Season 2's locker is Cloudscape, and Cloudscape is loaded as its own chunk
 * (contract section 5): `assets/LockerV2.js` and `assets/LockerV2.css`, which
 * br_ui/fxmanifest.lua's `ui/assets/*.js` and `*.css` globs already serve. A
 * Season 1 page never fetches either -- its locker is screens/Locker.tsx,
 * untouched -- and its main bundle carries none of Cloudscape's CSS.
 *
 * A CHUNK THIS PROJECT HAS NOT SHIPPED BEFORE, and vite.config.ts and
 * bridge/nui.ts both record dynamic imports under nui:// as a source of silent
 * failures. So nothing here can strand the player:
 *
 *   * the chunk is fetched as soon as Lua says the season has it
 *     (usePreloadLockerV2), so a failure is an F8 line at the lobby rather
 *     than a surprise at the first press;
 *   * a chunk that fails, or a screen that throws, gives the cursor back
 *     (LOCKER_FOCUS { open: false }) and reports once, instead of leaving an
 *     invisible screen holding the focus;
 *   * a chunk that never answers does the same after LOAD_MS.
 *
 * THE PRELOADED SCREEN IS DRAWN DIRECTLY (the lag report, cause 2). React.lazy
 * suspends on its first render even when its import has long resolved, and
 * React 19 then holds the reveal for up to 300 ms: the first open of every
 * session waited that long on a chunk that was already here. The module the
 * preload resolved is kept, and the gate renders it outright; Suspense is
 * only the path for a chunk that has not arrived yet. Once loaded, the chunk's
 * stylesheet goes off until the locker opens (sheet.ts), and the theme is
 * built in idle time (scope.ts warmTheme), so the first open builds nothing.
 */

const LOAD_MS = 5000

type Screen = typeof import('../LockerV2')

let loading: Promise<Screen> | null = null
/** The screen, once its chunk has loaded. */
let Loaded: ComponentType | null = null

function load(): Promise<Screen> {
  if (!loading) {
    loading = import('../LockerV2').then((m) => {
      Loaded = m.default
      sheetLoaded()
      const idle = window.requestIdleCallback ?? ((fn: () => void) => window.setTimeout(fn, 200))
      idle(() => { m.warmTheme() })
      return m
    })
  }
  return loading
}

const LockerV2 = lazy(load)

/** Fetch the chunk the moment the season has the feature. */
export function usePreloadLockerV2(on: boolean): void {
  useEffect(() => {
    if (!on) return
    load().catch((err: unknown) => reportError('locker v2 chunk', err))
  }, [on])
}

/** Give the cursor back. The only way out of a screen that cannot draw. */
function bail(context: string, err: unknown) {
  reportError(context, err)
  void fetchNui(CB.LOCKER_FOCUS, { open: false })
}

class Boundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }
  static getDerivedStateFromError() { return { failed: true } }
  componentDidCatch(err: unknown) { bail('locker v2', err) }
  render() { return this.state.failed ? null : this.props.children }
}

/** Shown only while the chunk is still on its way. */
function Waiting() {
  useEffect(() => {
    const t = window.setTimeout(() => {
      bail('locker v2 chunk', new Error(`not loaded after ${LOAD_MS} ms`))
    }, LOAD_MS)
    return () => window.clearTimeout(t)
  }, [])
  return null
}

export default function LockerV2Gate() {
  const Ready = Loaded
  if (Ready) return <Boundary><Ready /></Boundary>
  return (
    <Boundary>
      <Suspense fallback={<Waiting />}>
        <LockerV2 />
      </Suspense>
    </Boundary>
  )
}
