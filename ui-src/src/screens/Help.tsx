import { useEffect, useState } from 'react'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'

/**
 * The manual.
 *
 * ONE COMPONENT, TWO FRAMES. It is a tab in the pause menu during a match and
 * a full page from the lobby, because "how does this game work" is a question
 * asked in both places and a second copy of the screen is a second copy to
 * keep in step.
 *
 * IT IS THE REAL SITE, IN AN IFRAME, not a bundled copy. A copy goes stale the
 * first time the site is edited, and being correctable without shipping a
 * client build is the entire point of the pages site.
 *
 * IT CAN FAIL, AND FAILURE IS SILENT. A cross-origin iframe tells us almost
 * nothing: `onerror` does not fire for an HTTP error inside it, and its
 * document cannot be read. So the only honest signal is `onload` -- if that
 * has not fired by the time a slow connection reasonably would have, the panel
 * says so and offers the link. A blank white rectangle with no explanation is
 * the outcome worth engineering against, because it is indistinguishable from
 * a broken menu.
 */

const SITE = 'https://willmontgomery.github.io/fivem-br-gamemode/'

/** How long to wait for `onload` before assuming it is not coming. */
const TIMEOUT_MS = 8000

export default function Help({ inline = false, onDone }:
  { inline?: boolean; onDone?: () => void }) {
  const [loaded, setLoaded] = useState(false)
  const [slow, setSlow] = useState(false)
  const [copied, setCopied] = useState(false)

  useEffect(() => {
    if (loaded) return
    const t = window.setTimeout(() => setSlow(true), TIMEOUT_MS)
    return () => window.clearTimeout(t)
  }, [loaded])

  // THE LINK GOES TO THE CLIPBOARD, because nothing can launch a browser.
  // The game client has no native for opening a URL and CEF's window.open
  // goes nowhere useful from a nui:// page -- so the honest version of "open
  // it externally" is to hand over the address in one click and let the
  // player paste it wherever they like. A button that promised to open
  // Chrome and did nothing would be worse than no button.
  const copy = async () => {
    play('ui.select')
    try {
      await navigator.clipboard.writeText(SITE)
    } catch {
      // Clipboard permission is not guaranteed inside CEF. execCommand is
      // deprecated everywhere and still works here, which is exactly the
      // situation it is kept around for.
      const el = document.createElement('textarea')
      el.value = SITE
      document.body.appendChild(el)
      el.select()
      try { document.execCommand('copy') } catch { /* nothing left to try */ }
      el.remove()
    }
    setCopied(true)
    window.setTimeout(() => setCopied(false), 2400)
  }

  const body = (
    <div className="flex flex-col gap-3">
      <div className="flex items-center justify-between gap-4">
        {/* 1.15rem and tscale, up from a micro-label. This is the heading of
            a page, not a caption for one -- at label size it read as a stray
            line above a white rectangle (user, 2026-08-09). */}
        <div className="font-display text-[1.15rem] uppercase tracking-[0.08em] tscale">
          {loaded ? 'Player guide' : slow ? 'Could not load the guide' : 'Loading the guide…'}
        </div>
        <Btn variant="ghost" size="sm" cue="ui.select" onPress={copy}>
          {copied ? 'Link copied' : 'Copy link'}
        </Btn>
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
          The guide could not be reached — this client may be offline or
          blocking outside pages. Copy the link and open it in your browser.
        </div>
      )}

      {/* A FIXED-HEIGHT WELL, and the site scrolls INSIDE it. Letting the frame
          grow to its content would push the tabs off the top of the screen,
          and an iframe cannot be measured cross-origin anyway. Sized off the
          viewport so it fits at 720p and uses the room at 4K. */}
      <div
        className="plate overflow-hidden"
        style={{
          ['--edgec' as string]: 'rgba(255,255,255,0.14)',
          ['--plate-fill' as string]: '#ffffff',
          ['--cut-max' as string]: '0.5rem',
          height: inline ? 'calc(100vh - 22rem)' : 'calc(100vh - 16rem)',
          minHeight: '20rem',
        }}
      >
        <iframe
          src={SITE}
          title="FiveM Royale guide"
          onLoad={() => setLoaded(true)}
          // Read-only documentation: nothing in it should be able to navigate
          // the menu out from under the player.
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

  if (inline) return body

  return (
    <div
      className="interactive fixed inset-0 z-[52] overflow-y-auto thin-scroll"
      style={{ backgroundColor: 'rgba(6, 8, 14, 0.965)' }}
    >
      <div className="mx-auto py-8" style={{ width: '68rem', maxWidth: '92vw' }}>
        <div className="flex items-end justify-between mb-5">
          <div>
            <div className="micro-label">FiveM Royale</div>
            <h2 className="font-display text-[3rem] uppercase tracking-[0.1em] leading-none mt-1">
              Help
            </h2>
          </div>
          <Btn variant="default" size="md" cue="ui.back"
               onPress={() => {
                 void fetchNui(CB.HELP_FOCUS, { open: false })
                 onDone?.()
               }}>
            Back
          </Btn>
        </div>
        {body}
      </div>
    </div>
  )
}
