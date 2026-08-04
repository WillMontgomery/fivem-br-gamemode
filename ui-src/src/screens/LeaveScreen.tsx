/**
 * The voluntary-leave interstitial.
 *
 * A quiet cousin of the verdict screen: solid black, one line rising gently
 * -- leaving is a sad event, so it gets the fly-up, never the slam (user
 * call, 2026-08-04). Its real job is opaque coverage: underneath it the
 * teleport home and the island swap happen unseen, and Lua drops the flag
 * only once the vista genuinely exists.
 */
export default function LeaveScreen() {
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black leave-in">
      <h1 className="leave-line text-6xl font-black tracking-tight text-white/90">
        Leaving the match
      </h1>
    </div>
  )
}
