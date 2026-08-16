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

import Ring from '../hud/Ring'
import { useCoverReport } from '../bridge/cover'

/** What the curtain is covering. Lua names it; the wording lives here. */
export type CurtainKind = 'leaving' | 'dropping'

/**
 * The opacity transition's own duration, in ms, and it MUST match the class
 * below. It is the fallback deadline for the cover report -- see
 * bridge/cover.ts -- not a second place the fade is timed.
 */
const FADE_MS = 600

const COPY: Record<CurtainKind, { title: string; sub: string }> = {
  leaving:  { title: 'Leaving the match', sub: 'Cleaning up the world…' },
  dropping: { title: 'Dropping in',       sub: 'Building the island…' },
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
  // saying it has finished painting -- and the duration is only the fallback
  // for the case where it optimises the transition away entirely.
  const onCovered = useCoverReport('curtain', show, FADE_MS + 100)

  return (
    <div
      className="fixed inset-0 z-[60] flex flex-col items-center justify-center gap-6
                 bg-black transition-opacity duration-[600ms]"
      style={{ opacity: show ? 1 : 0, pointerEvents: 'none' }}
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
