import { Component, lazy, Suspense, useEffect, type ReactNode } from 'react'
import { fetchNui, reportError } from '../../bridge/nui'
import { CB } from '../../bridge/types'

/**
 * THE DOOR TO THE SEASON 2 MARKET (#411), and the one part of it in the main
 * bundle -- Locker v2's door (screens/lockerv2/Gate.tsx), for the Market.
 *
 * The screen is Cloudscape, loaded as its own chunk: `assets/MarketV2.js` and
 * its CSS, which br_ui/fxmanifest.lua's `ui/assets/*.js` and `*.css` globs
 * already serve. A Season 1 page never fetches it -- its Market is
 * screens/Market.tsx, untouched -- and nothing here can strand the player:
 *
 *   * the chunk is fetched as soon as Lua says the season has it
 *     (usePreloadMarketV2), so a failure is an F8 line at the lobby rather
 *     than a surprise at the first press;
 *   * a chunk that fails, or a screen that throws, gives the cursor back
 *     (MARKET_FOCUS { open: false }) and reports once, instead of leaving an
 *     invisible screen holding the focus;
 *   * a chunk that never answers does the same after LOAD_MS.
 */

const LOAD_MS = 5000

let loading: Promise<typeof import('../MarketV2')> | null = null

function load() {
  if (!loading) loading = import('../MarketV2')
  return loading
}

const MarketV2 = lazy(load)

/** Fetch the chunk the moment the season has the feature. */
export function usePreloadMarketV2(on: boolean): void {
  useEffect(() => {
    if (!on) return
    load().catch((err: unknown) => reportError('market v2 chunk', err))
  }, [on])
}

/** Give the cursor back. The only way out of a screen that cannot draw. */
function bail(context: string, err: unknown) {
  reportError(context, err)
  void fetchNui(CB.MARKET_FOCUS, { open: false })
}

class Boundary extends Component<{ children: ReactNode }, { failed: boolean }> {
  state = { failed: false }
  static getDerivedStateFromError() { return { failed: true } }
  componentDidCatch(err: unknown) { bail('market v2', err) }
  render() { return this.state.failed ? null : this.props.children }
}

/** Shown only while the chunk is still on its way. */
function Waiting() {
  useEffect(() => {
    const t = window.setTimeout(() => {
      bail('market v2 chunk', new Error(`not loaded after ${LOAD_MS} ms`))
    }, LOAD_MS)
    return () => window.clearTimeout(t)
  }, [])
  return null
}

export default function MarketV2Gate() {
  return (
    <Boundary>
      <Suspense fallback={<Waiting />}>
        <MarketV2 />
      </Suspense>
    </Boundary>
  )
}
