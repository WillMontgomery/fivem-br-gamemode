import { useEffect, useRef, useState } from 'react'

/**
 * The manual, in the pause menu.
 *
 * IT IS THE REAL SITE, IN AN IFRAME, not a copy of it. A second copy of the
 * rules inside the bundle is a copy that goes stale the first time the site is
 * edited, and the whole point of the pages site is that it can be corrected
 * without shipping a client build.
 *
 * IT CAN FAIL, AND FAILURE IS SILENT. A cross-origin iframe tells us almost
 * nothing: `onerror` does not fire for an HTTP error inside it, and we cannot
 * read its document to check. So the only honest signal is `onload` -- if it
 * has not fired by the time a slow connection reasonably would have, the panel
 * says so and offers the URL to open in a real browser. A blank white rectangle
 * with no explanation is the one outcome worth engineering against, because it
 * is indistinguishable from a broken menu.
 */

const SITE = 'https://willmontgomery.github.io/fivem-br-gamemode/'

/** How long to wait for `onload` before assuming it is not coming. */
const TIMEOUT_MS = 8000

export default function Help() {
  const [loaded, setLoaded] = useState(false)
  const [slow, setSlow] = useState(false)
  const frame = useRef<HTMLIFrameElement>(null)

  useEffect(() => {
    if (loaded) return
    const t = window.setTimeout(() => setSlow(true), TIMEOUT_MS)
    return () => window.clearTimeout(t)
  }, [loaded])

  return (
    <div className="flex flex-col gap-3">
      <div className="flex items-baseline justify-between">
        <div className="micro-label">
          {loaded ? 'Player guide' : slow ? 'Could not load the guide' : 'Loading the guide…'}
        </div>
        <div className="micro-label" style={{ opacity: 0.5, textTransform: 'none' }}>
          {SITE.replace(/^https:\/\//, '')}
        </div>
      </div>

      {slow && !loaded && (
        <div
          className="plate px-4 py-3 text-[0.85rem] tscale"
          style={{
            ['--edgec' as string]: 'rgba(255,255,255,0.16)',
            ['--plate-fill' as string]: 'rgba(20,24,34,0.94)',
            ['--cut-max' as string]: '0.5rem',
          }}
        >
          The guide could not be reached — the game client may be offline or
          blocking outside pages. It is readable in any browser at{' '}
          <span className="font-display">{SITE.replace(/^https:\/\//, '')}</span>.
        </div>
      )}

      {/* A FIXED-HEIGHT WELL, and the site scrolls INSIDE it. Letting the frame
          grow to its content would push the pause menu's own tabs off the top
          of the screen, and an iframe cannot be measured cross-origin anyway.
          Sized off the viewport so it fits at 720p and uses the room at 4K. */}
      <div
        className="plate overflow-hidden"
        style={{
          ['--edgec' as string]: 'rgba(255,255,255,0.14)',
          ['--plate-fill' as string]: '#ffffff',
          ['--cut-max' as string]: '0.5rem',
          height: 'calc(100vh - 20rem)',
          minHeight: '20rem',
        }}
      >
        <iframe
          ref={frame}
          src={SITE}
          title="FiveM Royale guide"
          onLoad={() => setLoaded(true)}
          // The frame is read-only documentation: no scripts of its own need
          // to reach us, and nothing in it should be able to navigate the
          // menu out from under the player.
          sandbox="allow-scripts allow-same-origin allow-popups"
          style={{
            width: '100%',
            height: '100%',
            border: 0,
            // Hidden rather than unmounted while it loads: unmounting on a
            // timeout would cancel a load that was merely slow.
            opacity: loaded ? 1 : 0,
            transition: 'opacity 200ms var(--ease-out)',
          }}
        />
      </div>
    </div>
  )
}
