/**
 * THE CURTAIN.
 *
 * Opaque black NUI over everything, with one line rising gently and the shared
 * loading ring beneath it. Its real job is COVERAGE: a teleport, an island
 * swap, a camera being handed back to the game -- all of it happens unseen
 * underneath, and Lua drops the flag only once the world genuinely exists on
 * the far side.
 *
 * IT COVERS THE HUD AND THE MINIMAP TOO, which a game-side screen fade cannot:
 * `DoScreenFadeOut` blacks the WORLD, and the HUD is drawn over the world by
 * us and the radar by the engine, so a game fade alone leaves both floating on
 * a black rectangle. That is what "the HUD shows during the transition" was
 * (user, 2026-08-09). The two are used together -- the curtain for the
 * interface, the game fade so nothing renders a teleport underneath it.
 *
 * TWO USES, ONE COMPONENT: leaving a match, and dropping into one. They are
 * the same shape of moment -- the world is being rebuilt and there is nothing
 * to look at -- so they get the same object with different words rather than
 * two interstitials that drift apart. `leaving` gets the fly-up because
 * leaving is a sad event; `dropping` gets the same rise, because a slam
 * belongs to the verdict screen and nowhere else.
 *
 * ALWAYS MOUNTED, driven by opacity: unmounting on the flag popped the black
 * away instantly, and the exit is a fade to whatever is waiting underneath --
 * the lobby, or the warmup pad.
 */

import { useEffect, useRef } from 'react'
import Ring from '../hud/Ring'
import { useCoverReport } from '../bridge/cover'
import { useFade } from '../ui/useFade'

/** What the curtain is covering. Lua names it; the wording lives here. */
export type CurtainKind = 'leaving' | 'dropping' | 'disconnecting'

/**
 * The opacity transition's own duration, in ms, and it MUST match the class
 * below. The fade's settle is read off it, and the settle is the cover
 * report's fallback (see below and bridge/cover.ts) -- not a second place the
 * fade is timed.
 */
const FADE_MS = 600

const COPY: Record<CurtainKind, { title: string; sub: string }> = {
  leaving:  { title: 'Leaving the match', sub: 'Cleaning up the world…' },
  dropping: { title: 'Dropping in',       sub: 'Building the island…' },
  // A THIRD KIND RATHER THAN REUSING `leaving`, because the words would be a
  // lie: somebody disconnecting from the lobby is not leaving a match, and
  // there is no world to clean up. Same component, same shape of moment --
  // something irreversible is under way and there is nothing to look at --
  // which is the whole argument for one curtain with three vocabularies
  // instead of three interstitials that drift apart.
  disconnecting: { title: 'Leaving the server', sub: 'Disconnecting…' },
}

export default function LeaveScreen({
  show, kind = 'leaving',
}: { show: boolean; kind?: CurtainKind }) {
  const copy = COPY[kind] ?? COPY.leaving

  // AND IT TELLS LUA WHEN IT IS ACTUALLY BLACK.
  //
  // This is the acknowledgement the whole transition ordering hangs off (#124).
  // Lua raises the curtain and then waits HERE before changing anything: the
  // teleport, the island swap, the lobby menu being replaced by the HUD. It
  // used to sleep 450ms and assume, which is how the player ended up watching
  // the cut this component exists to cover.
  //
  // transitionend on the opacity above is the honest signal -- the browser
  // saying it has finished painting. The fallback for the case where it never
  // fires is NOT a timer here (`null`): it is the settle below.
  const onCovered = useCoverReport('curtain', show, null)

  // ═══ AND IT IS BLACK WHEN IT SAYS SO, WHETHER THE FADE RAN OR NOT (#252) ═══
  //
  // The report used to have its own 700ms timer, and on its own that let the
  // page tell Lua "black" about a curtain whose fade had never run and was
  // still at opacity 0. Stop the browser's animation clock and that is what
  // happens: the ready-up goes ahead in front of a lobby that is still drawn.
  // At that same deadline the fade is now dropped and the final opacity set
  // outright (ui/fade.ts), and a curtain on its way down cannot be left over
  // the world either.
  const rootRef = useRef<HTMLDivElement>(null)
  const settled = useFade('curtain', show, FADE_MS, rootRef)

  // ═══ THE FALLBACK "BLACK" GOES OUT ONLY ONCE THE BLACK HAS COMMITTED ═══
  //
  // Round 1 kept the 700ms timer and settled the fade at the same 700ms, and
  // the timer was registered first: the POST went out with the curtain's
  // computed opacity still 0 and the forced black a render behind it -- a race
  // against Lua's next tick (round 1's review measured opacity 0 at the POST in
  // all three stopped-clock runs). So the fallback IS the settle now: this runs
  // after the render that set `transition: none; opacity: 1` has committed, and
  // reports only what the element's own computed opacity says. A healthy fade
  // has already reported off transitionend at 600ms and this is a no-op.
  useEffect(() => {
    if (!show || !settled) return
    const el = rootRef.current
    if (el && parseFloat(getComputedStyle(el).opacity) >= 0.99) onCovered()
    // `onCovered` is this render's; `show` and `settled` are the edge.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [show, settled])

  // OFF FOR GOOD -- down, and its fade over -- IT STOPS ANIMATING (#252). The
  // curtain is always mounted, so its ring spun at opacity 0 for every minute
  // of every lobby: ~144 style recalcs a second headless, up to FiveM's 240 fps
  // cap in game, for the whole AFK. `layer-off` pauses it (index.css); it
  // resumes the moment the curtain is asked for again, before it is visible.
  const off = settled && !show

  return (
    <div
      ref={rootRef}
      data-layer="curtain"
      className={`fixed inset-0 z-[60] flex flex-col items-center justify-center gap-6
                 bg-black transition-opacity duration-[600ms]${off ? ' layer-off' : ''}`}
      // AN OPAQUE SCREEN SWALLOWS CLICKS -- while it is up, and only then.
      //
      // This was `'none'` unconditionally, which was harmless while there was
      // never anything clickable underneath. There is now: the pause menu is
      // held open on purpose while this curtain rises over it (#124, see
      // br_ui/client/pause.lua), so a second click during the fade would land
      // blind on a button the player can no longer see -- and the row directly
      // under "Leave match" is "Disconnect".
      //
      // Off again the moment it is down, because the page is click-through by
      // default (index.css) and a full-screen layer left at `auto` would eat
      // every click in the lobby underneath it. The trade it accepts: a curtain
      // that ever got STUCK up now takes the interface with it rather than
      // leaving the player clicking blindly at a black screen. That is the
      // better of two bad states, and it is already watched for from both sides
      // -- br_core lifts an abandoned curtain after 15s, and /brunstuck drops it
      // by hand.
      style={{
        opacity: show ? 1 : 0,
        pointerEvents: show ? 'auto' : 'none',
        // Over the class's transition once the fade has had its time.
        transition: settled ? 'none' : undefined,
      }}
      aria-hidden={!show}
      // THIS ELEMENT'S OWN OPACITY, AND NOTHING ELSE'S. transitionend bubbles,
      // so any child of this curtain that ever grows a transition would
      // otherwise report "the screen is black" the moment IT finished -- at
      // whatever opacity the curtain happened to be passing through. That is
      // precisely the class of mistake this handshake replaces, and it would be
      // invisible until someone restyled a child.
      onTransitionEnd={(e) => {
        if (e.target === e.currentTarget && e.propertyName === 'opacity') {
          onCovered()
        }
      }}
    >
      {/* Remount the fly-up per showing so it replays each time. Keyed by
          kind as well, or switching words mid-curtain would keep the old
          element and skip the animation. */}
      {show && (
        <h1 key={kind} className="leave-line text-6xl font-black tracking-tight text-white/90">
          {copy.title}
        </h1>
      )}
      <div className="flex items-center gap-3">
        {/* The shared ring, so there is ONE loading indicator in the game
            rather than a bespoke spinner per screen. Indeterminate: nothing
            here has an honest percentage -- we are waiting on collision. */}
        <Ring size={1.6} stroke={0.18} label={copy.title} />
        <span className="text-sm uppercase tracking-[0.18em] text-white/40">
          {copy.sub}
        </span>
      </div>
    </div>
  )
}
