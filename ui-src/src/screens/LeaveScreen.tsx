/**
 * The voluntary-leave interstitial.
 *
 * A quiet cousin of the verdict screen: solid black, one line rising gently
 * -- leaving is a sad event, so it gets the fly-up, never the slam -- with
 * the loading ring and busy line below it, matching the loadscreen's
 * language (user call, 2026-08-04). Its real job is opaque coverage: the
 * teleport home and the island swap happen unseen beneath it, and Lua drops
 * the flag only once the vista genuinely exists.
 *
 * ALWAYS MOUNTED, driven by opacity: unmounting on the flag popped the
 * black away instantly -- the exit is a 600ms fade to the lobby waiting
 * underneath, so the menu appears to fade in from black.
 */

import Ring from '../hud/Ring'

export default function LeaveScreen({ show }: { show: boolean }) {
  return (
    <div
      className="fixed inset-0 z-50 flex flex-col items-center justify-center gap-6 bg-black transition-opacity duration-[600ms]"
      style={{ opacity: show ? 1 : 0, pointerEvents: 'none' }}
      aria-hidden={!show}
    >
      {/* Remount the fly-up per showing so it replays each leave. */}
      {show && (
        <h1 className="leave-line text-6xl font-black tracking-tight text-white/90">
          Leaving the match
        </h1>
      )}
      <div className="flex items-center gap-3">
        {/* The shared ring, so there is ONE loading indicator in the game rather
            than a bespoke spinner per screen. Indeterminate: nothing here has an
            honest percentage -- we are waiting on collision to stream. */}
        <Ring size={1.6} stroke={0.18} label="Leaving the match" />
        <span className="text-sm uppercase tracking-[0.18em] text-white/40">
          Cleaning up the world…
        </span>
      </div>
    </div>
  )
}
