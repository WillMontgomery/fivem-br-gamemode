import { useEffect, useRef, useState } from 'react'
import { useUi } from '../store'
import { fetchNui, reportError } from '../bridge/nui'
import { CB } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'

/**
 * Ringmaster, in the pause menu (#23).
 *
 * A FULL PAGE, NOT A TAB BODY, on the owner's call: "the one in /help is much
 * larger and would be most appropriate size-wise for Ringmaster". A board of
 * bans, incidents and a player table does not fit the pause menu's tab well. The
 * Admin tab is therefore a DOOR -- pressing it asks Lua for a focus screen of
 * this component's own, exactly as the lobby's Help button does.
 *
 * ═══ THE COMMON CASE COSTS NOTHING, AND THAT IS THE DESIGN ═══
 *
 * The frame opens at the plain console origin every single time. CEF's cookie
 * jar outlives the frame being destroyed and recreated, so a session that is
 * still good simply renders: no token, no round trip, no spinner. The owner
 * opens this repeatedly, and the mint path below is the EXCEPTION -- a first
 * open, or one after the console's two-hour idle window has lapsed.
 *
 * ═══ HOW WE LEARN WE NEED A TOKEN ═══
 *
 * We cannot read a cross-origin frame's URL or its content, so there is no way
 * to see that this particular open landed on the login page. The console says
 * so instead: its login page posts one message to its parent, and that message
 * is the only trigger for minting.
 *
 * WHICH MAKES THE ORIGIN CHECK LOAD-BEARING RATHER THAN A FORMALITY. This
 * listener's entire job is to make the game server mint an admin session for
 * whoever is sitting at this machine. A handler that accepted `message` from
 * any origin would be one that any other page NUI ever loads -- an embedded
 * video, a map, a future screen nobody has written yet -- could drive into
 * minting. So: `===` against the origin the SERVER sent us. Never `includes`,
 * never `endsWith`, never a regex, and never a value this page made up.
 *
 * ═══ WHAT IS DELIBERATELY NOT HERE ═══
 *
 * NO PAGE RESTORATION. Every open lands on the live players page, by the
 * owner's decision. Remembering where somebody was would mean holding a console
 * route in game state and re-entering it across a session boundary that may have
 * changed underneath.
 *
 * NO COPY FOR THE FAILURE STATES. The console answers with machine codes and
 * says in as many words that the in-game wording is this side's decision. It is
 * the owner's decision, not this file's, so a failure shows the CODE and the way
 * out. Inventing a sentence per code would be putting words in the product's
 * mouth in the one place they are hardest to notice and hardest to remove.
 */

/**
 * How long to wait for the game server's answer before giving up.
 *
 * DELIBERATELY LONGER THAN THE SERVER'S OWN DEADLINE, and it is not a second
 * opinion about the same thing. br_ringmaster gives the mint 3s and answers on
 * every path including its own expiry, so in every ordinary failure the answer
 * arrives here well inside this window and this timer is simply cancelled. What
 * it covers is the case that has no owner: Lua never answering at all -- the
 * resource stopped, the event lost, an error in a handler. Without it the
 * indicator would spin forever, which is the one outcome worse than a failure.
 */
const MINT_WAIT_MS = 6000

/**
 * How many times one open may ask for a token.
 *
 * TWO, AND THE CAP IS NOT COSMETIC. A redeem that fails -- an expired token, a
 * race lost to a second frame -- lands back on the login page, which posts
 * `signed-out` again, which would ask for another token, forever. That loop
 * costs the console's rate limiter (six per admin per minute) and burns a token
 * per turn. One retry covers the genuine race the console documents: a
 * double-clicked button mints twice and the first frame loses.
 */
const MINT_MAX = 2

export default function Admin() {
  const admin = useUi((s) => s.admin)
  const origin = admin.origin
  const mint = admin.mint

  /**
   * What the frame is pointed at. Seeded from the plain origin ONCE, on mount.
   *
   * An iframe reloads whenever its `src` changes, so this must never be
   * recomputed during a render -- the frame would re-fetch on every parent
   * update and the console would flicker permanently. Same lazy-initialiser
   * discipline Help.tsx uses for its cache-buster, and for the same reason.
   */
  const [src, setSrc] = useState<string | undefined>(origin)

  /** Waiting on the server. Drives the indicator, and only ever on this path. */
  const [minting, setMinting] = useState(false)
  const [failed, setFailed] = useState<string | null>(null)

  /** Mints asked for during this open. Reset only by closing and reopening. */
  const asked = useRef(0)
  /** The last `mint.seq` acted on, so one answer is consumed exactly once. */
  const seen = useRef(mint?.seq ?? 0)

  const close = () => {
    play('ui.back')
    void fetchNui(CB.ADMIN_FOCUS, { open: false })
  }

  /**
   * The origin arriving late is normal, not exceptional.
   *
   * The tab cannot be pressed before the server has sent an origin -- it is not
   * drawn until then -- so in practice this is set at mount. It is handled
   * anyway because `src` is seeded from a value that is optional at the type
   * level, and a frame pointed at `undefined` renders a blank rectangle that is
   * indistinguishable from every other way this can fail.
   */
  useEffect(() => {
    if (src === undefined && origin !== undefined) setSrc(origin)
  }, [origin, src])

  /**
   * THE LISTENER. Reads nothing it was not sent, and acts on almost nothing.
   *
   * Bound to `origin` so it is rebuilt if the console ever moves, and torn down
   * with the screen -- a listener that outlived this component would be one
   * that mints in the background with nothing on screen to receive it.
   */
  useEffect(() => {
    if (origin === undefined) return

    const onMessage = (e: MessageEvent) => {
      // EXACT COMPARE, FIRST, BEFORE ANYTHING ELSE IS READ. `e.data` is
      // attacker-controlled until this line passes.
      if (e.origin !== origin) return

      const d = e.data as { source?: unknown; state?: unknown } | null
      if (!d || typeof d !== 'object') return
      if (d.source !== 'ringmaster') return
      if (d.state !== 'signed-out') return

      // Already asking. The console posts once per login-page render, but a
      // frame that reloads underneath a request in flight would otherwise
      // stack a second one on top of it.
      if (asked.current >= MINT_MAX) return
      asked.current += 1

      setFailed(null)
      setMinting(true)
      void fetchNui(CB.ADMIN_MINT, {})
    }

    window.addEventListener('message', onMessage)
    return () => window.removeEventListener('message', onMessage)
  }, [origin])

  /** The answer. One `seq`, consumed once. */
  useEffect(() => {
    if (!mint) return
    if (mint.seq <= seen.current) return
    seen.current = mint.seq

    setMinting(false)

    if (mint.url) {
      setFailed(null)
      setSrc(mint.url)
      return
    }

    const code = mint.error ?? 'unknown'
    setFailed(code)
    // To the F8 console and, through the error sink, to the server log. The
    // code is the whole diagnostic, and it is the half a screenshot loses.
    reportError('admin console handoff', new Error(code))
  }, [mint])

  /** The spinner cannot spin forever. See MINT_WAIT_MS. */
  useEffect(() => {
    if (!minting) return
    const t = window.setTimeout(() => {
      setMinting(false)
      setFailed('no-answer')
    }, MINT_WAIT_MS)
    return () => window.clearTimeout(t)
  }, [minting])

  /**
   * Escape closes, like every other full page here.
   *
   * IT ONLY WORKS WHILE OUR DOCUMENT HAS THE KEY, and that is a real limitation
   * rather than an oversight: once the admin clicks inside the frame, the
   * console's document has focus and its keystrokes never reach this listener.
   * Nothing can change that from this side -- a cross-origin frame does not
   * forward key events. The Back button below is the exit that always works,
   * which is why it is a button and not a hint.
   */
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      close()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  return (
    <div
      className="interactive fixed inset-0 z-[55] overflow-hidden"
      style={{ backgroundColor: 'rgba(6, 8, 14, 0.965)' }}
    >
      <div className="mx-auto py-10" style={{ width: '68rem', maxWidth: '92vw' }}>
        <div className="flex items-end justify-between mb-6">
          <div>
            <div className="micro-label">Ringmaster</div>
            <h2 className="font-display text-[3rem] uppercase tracking-[0.1em] leading-none mt-1">
              Admin
            </h2>
          </div>

          {/* THE INDICATOR, AND IT IS NOT COPY. The owner asked for something
              to look at while a token is being fetched and explicitly not for
              helper text. This is on screen only during a mint -- never on the
              ordinary reopen, which has nothing to wait for. */}
          {minting && (
            <div className="flex items-center gap-3" aria-live="polite">
              <div
                className="rounded-full"
                style={{
                  width: '1rem',
                  height: '1rem',
                  border: '2px solid rgba(255,255,255,0.18)',
                  borderTopColor: 'var(--color-royale-accent)',
                  // `ringRotate` already exists in index.css and is exactly a
                  // 360-degree turn. A second keyframe called `spin` doing the
                  // same thing is the kind of duplication that survives for
                  // years because nobody notices it twice.
                  animation: 'ringRotate 700ms linear infinite',
                }}
              />
            </div>
          )}

          {/* THE FAILURE IS A CODE, ON PURPOSE. See the header: the wording for
              each of these is the owner's and is not invented here. The code is
              what makes the difference between "role-revoked" (their Discord
              role went away) and "no-account" (they have never signed in to the
              console in a browser) visible at all, and those have completely
              different fixes. */}
          {failed !== null && !minting && (
            <div
              className="plate px-4 py-2 ts"
              style={{
                ['--fs' as string]: '0.85rem',
                ['--edgec' as string]: 'var(--color-danger)',
                ['--plate-fill' as string]: 'rgba(30,16,20,0.94)',
                ['--cut-max' as string]: '0.4rem',
              }}
            >
              <span className="font-display uppercase tracking-[0.08em]">{failed}</span>
            </div>
          )}
        </div>

        {/* A FIXED-HEIGHT WELL, and the console scrolls INSIDE it. An iframe
            cannot be measured cross-origin, so letting it size to its content
            is not available -- and this is the `/help` full-page height rather
            than the pause menu's tab height, which is the whole point of the
            screen existing. */}
        <div
          className="plate overflow-hidden"
          style={{
            ['--edgec' as string]: 'rgba(255,255,255,0.14)',
            ['--plate-fill' as string]: '#ffffff',
            ['--cut-max' as string]: '0.5rem',
            height: 'calc(100vh - 14rem)',
            minHeight: '20rem',
          }}
        >
          {src !== undefined && (
            <iframe
              src={src}
              title="Ringmaster admin console"
              /* NO `sandbox`, AND THIS IS THE ONE PLACE IT WOULD BE WRONG.
                 Help.tsx sandboxes its frame because the manual is read-only
                 documentation. This is an application the admin signs in to and
                 acts in: it needs its own cookies and its own origin, and
                 `allow-same-origin` alongside `allow-scripts` is documented as
                 not being a boundary anyway. What actually constrains this frame
                 is on the console's side -- its CSP, its CSRF origin check, and
                 the fact that its destructive actions need typed confirmations
                 rather than a click. */
              style={{ width: '100%', height: '100%', border: 0 }}
            />
          )}
        </div>

        {/* THE WAY OUT SITS UNDER THE THING IT LEAVES, the same placement Help
            uses. It is the only control on this screen that is ours, and it is
            the exit that works after the frame has taken the keyboard. */}
        <div className="mt-5">
          <Btn variant="primary" size="md" cue="ui.back" onPress={close}>
            Back
          </Btn>
        </div>
      </div>
    </div>
  )
}
