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

/** What the curtain is covering. Lua names it; the wording lives here. */
export type CurtainKind = 'leaving' | 'dropping'

const COPY: Record<CurtainKind, { title: string; sub: string }> = {
  leaving:  { title: 'Leaving the match', sub: 'Cleaning up the world…' },
  dropping: { title: 'Dropping in',       sub: 'Building the island…' },
}

export default function LeaveScreen({
  show, kind = 'leaving',
}: { show: boolean; kind?: CurtainKind }) {
  const copy = COPY[kind] ?? COPY.leaving
  return (
    <div
      className="fixed inset-0 z-[60] flex flex-col items-center justify-center gap-6
                 bg-black transition-opacity duration-[600ms]"
      style={{ opacity: show ? 1 : 0, pointerEvents: 'none' }}
      aria-hidden={!show}
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
