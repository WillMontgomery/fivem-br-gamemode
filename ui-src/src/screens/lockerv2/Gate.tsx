import { Component, lazy, Suspense, useEffect, type ReactNode } from 'react'
import { fetchNui, reportError } from '../../bridge/nui'
import { CB } from '../../bridge/types'

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
 */

const LOAD_MS = 5000

let loading: Promise<typeof import('../LockerV2')> | null = null

function load() {
  if (!loading) loading = import('../LockerV2')
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
  return (
    <Boundary>
      <Suspense fallback={<Waiting />}>
        <LockerV2 />
      </Suspense>
    </Boundary>
  )
}
