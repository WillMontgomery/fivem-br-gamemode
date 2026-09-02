import { useEffect, useRef, useState } from 'react'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import DiscordCard from '../ui/DiscordCard'
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

/* The manual's own domain, on the owner's instruction (2026-08-17). It replaces
   the GitHub Pages address the site was published to while it had no domain of
   its own; nothing else in the client pointed at that URL -- the remaining
   `fivem-br-gamemode` strings in the repo are the git REPOSITORY and the ops
   checkout path (tools/deploy.sh, tools/dispatch.sh, DEPLOY.md), which are a
   different thing that happens to share a name. */
const SITE = 'https://blitz-royale.com'

/**
 * The same URL, with a cache-buster, for the FRAME only.
 *
 * BEING CORRECTABLE WITHOUT A CLIENT BUILD IS THE WHOLE POINT of pointing this
 * at the real site -- and it quietly stopped being true. CEF caches the page,
 * the iframe does not re-fetch unless its `src` changes, and a client that had
 * the manual open once went on showing that copy. The site was rewritten and
 * every player in game kept reading the old one, with nothing anywhere to
 * indicate a stale document. GitHub Pages sends `max-age=600`, so this was
 * never going to resolve itself within a session either.
 *
 * COMPUTED ONCE PER MOUNT, held in state. Putting `Date.now()` straight in the
 * JSX would change the `src` on every render, and an iframe whose src changes
 * reloads -- so the manual would flicker and re-download forever.
 *
 * SITE ITSELF STAYS CLEAN. It is what the copy-link button puts on the
 * clipboard, and nobody wants to paste a URL with a timestamp in it.
 */
function frameSrc(): string {
  return `${SITE}?t=${Date.now()}`
}

/** How long to wait for `onload` before assuming it is not coming. */
const TIMEOUT_MS = 8000

export default function Help({ inline = false, onDone }:
  { inline?: boolean; onDone?: () => void }) {
  const [loaded, setLoaded] = useState(false)
  const [slow, setSlow] = useState(false)
  const [copied, setCopied] = useState(false)
  /** The "Link copied" hold, so a re-press cannot be cut short by the previous
   *  press's timer and closing the panel mid-hold does not set state on an
   *  unmounted component. */
  const copyTimer = useRef<number | null>(null)
  // Lazy initialiser: evaluated once, on mount, and never again for this
  // instance -- so the frame re-fetches each time the manual is opened and
  // never mid-render.
  const [src] = useState(frameSrc)

  useEffect(() => {
    if (loaded) return
    const t = window.setTimeout(() => setSlow(true), TIMEOUT_MS)
    return () => window.clearTimeout(t)
  }, [loaded])

  // ONE CLOSE, AND WHOEVER OWNS THE SCREEN GETS IT. The Back button used to
  // call HELP_FOCUS directly, which is right for the page raised by /help and
  // does nothing at all inside the pause menu -- focus is 'pause' there, so
  // popping 'help' pops something that was never pushed (user, 2026-08-09).
  //
  // `onDone` is the owner: the pause menu passes one and gets its tab back,
  // the standalone page passes none and this releases its own focus. Note
  // that is INDEPENDENT of `inline`, which is only about the frame -- the
  // pause menu wants the full page AND its own close.
  const close = () => {
    play('ui.back')
    if (onDone) { onDone(); return }
    void fetchNui(CB.HELP_FOCUS, { open: false })
  }

  // Escape closes, the same key every other page here answers to. Not when
  // embedded: the pause menu owns Escape there, and two handlers capturing
  // the same key means one of them wins by accident.
  useEffect(() => {
    if (inline) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      close()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  useEffect(() => () => {
    if (copyTimer.current !== null) window.clearTimeout(copyTimer.current)
  }, [])

  // THE LINK GOES TO THE CLIPBOARD, because nothing can launch a browser.
  // The game client has no native for opening a URL and CEF's window.open
  // goes nowhere useful from a nui:// page -- so the honest version of "open
  // it externally" is to hand over the address in one click and let the
  // player paste it wherever they like. A button that promised to open
  // Chrome and did nothing would be worse than no button.
  //
  // AND IT SAYS SO ONLY IF IT WORKED. This used to call setCopied(true)
  // unconditionally and throw execCommand's return value away, so the button
  // reported success whether or not anything reached the clipboard -- which
  // meant nothing in this project knew whether copying works in CEF at all. The
  // boolean is the whole answer and it was already being computed.
  const copy = async () => {
    play('ui.select')
    let ok = false
    try {
      await navigator.clipboard.writeText(SITE)
      ok = true
    } catch {
      // Clipboard permission is not guaranteed inside CEF. execCommand is
      // deprecated everywhere and still works here, which is exactly the
      // situation it is kept around for.
      const el = document.createElement('textarea')
      el.value = SITE
      document.body.appendChild(el)
      el.select()
      try { ok = document.execCommand('copy') } catch { /* nothing left to try */ }
      el.remove()
    }
    if (!ok) return
    // HELD IN A REF, CLEARED BEFORE RESCHEDULING. Without it a second press
    // leaves the first timeout armed, and the label goes back to "Copy link"
    // 2.4s after the FIRST press -- under a player who has just pressed again.
    if (copyTimer.current !== null) window.clearTimeout(copyTimer.current)
    setCopied(true)
    copyTimer.current = window.setTimeout(() => {
      setCopied(false)
      copyTimer.current = null
    }, 2400)
  }

  const body = (
    <div className="flex flex-col gap-3">
      {/* `flex-wrap` AND A shrink-0 RIGHT-HAND GROUP. Three things share this
          line now and the third can grow (see below), so the failure mode worth
          engineering against is the address being squeezed into a four-character
          column rather than the row taking a second line. Wrapping is the
          cheaper outcome and this page's root scrolls. */}
      <div className="flex items-center justify-between gap-4 flex-wrap">
        {/* 1.15rem via .ts, up from a micro-label. This is the heading of
            a page, not a caption for one -- at label size it read as a stray
            line above a white rectangle (user, 2026-08-09). */}
        <div className="font-display uppercase tracking-[0.08em] ts" style={{ ['--fs' as string]: '1.15rem' }}>
          {loaded ? 'Player guide' : slow ? 'Could not load the guide' : 'Loading the guide…'}
        </div>
        {/* THE DISCORD INVITE LANDED HERE ON 2026-08-31, off the pause menu's
            front page and out of the lobby, because the owner played the plate
            it used to be and said so: "the card in the pause menu is HUGE. we
            don't need that. Find a better place for it. Perhaps on the Help
            page only."

            AND IT IS BESIDE Copy link RATHER THAN ANYWHERE ELSE ON THE PAGE,
            because that button is this exact gesture aimed at the other
            address -- the manual's. Two addresses a player can take away with
            them, copied the same way, on the same line. It is built to this
            button's height so it reads as part of the row and not as a thing
            sitting next to it; ui/DiscordCard.tsx carries the sizes.

            IT CAN REMOVE ITSELF, TWICE OVER -- on a server that publishes no
            invite, and for a player the server has confirmed is already in the
            Discord. (It used to remove itself for the rest of the session once
            a copy had landed; that rule was withdrawn on 2026-08-31 and the
            membership check replaced it. ui/DiscordCard.tsx has the exchange.)
            Neither leaves a gap: the group is a flex row with a gap, so the
            button simply becomes the only thing in it. Do not reserve space
            for something that is designed to go away. */}
        <div className="flex items-center gap-3 shrink-0">
          <DiscordCard />
          <Btn variant="ghost" size="sm" cue="ui.select" onPress={copy}>
            {copied ? 'Link copied' : 'Copy link'}
          </Btn>
        </div>
      </div>

      {slow && !loaded && (
        <div
          className="plate px-4 py-3 ts"
          style={{
            ['--fs' as string]: '0.85rem',
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
          src={src}
          title="Blitz Royale player manual"
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

      {/* THE WAY OUT SITS UNDER THE THING IT LEAVES, bottom left, rather than
          up in a header (owner's call, 2026-08-09) -- it is where the eye
          lands after reading down the page. Blue because on this screen it is
          the ONLY action: there is nothing here to compete with it. */}
      {!inline && (
        <div>
          <Btn variant="primary" size="md" cue="ui.back" onPress={close}>
            Back
          </Btn>
        </div>
      )}
    </div>
  )

  if (inline) return body

  return (
    <div
      className="interactive fixed inset-0 z-[52] overflow-y-auto thin-scroll"
      style={{ backgroundColor: 'rgba(6, 8, 14, 0.965)' }}
    >
      <div className="mx-auto py-8" style={{ width: '68rem', maxWidth: '92vw' }}>
        <div className="mb-5">
          <div className="micro-label">Blitz Royale</div>
          <h2 className="font-display text-[3rem] uppercase tracking-[0.1em] leading-none mt-1">
            Help
          </h2>
        </div>
        {body}
      </div>
    </div>
  )
}
