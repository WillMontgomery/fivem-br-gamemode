import { useEffect, useRef } from 'react'
import { useUi, selDbno } from '../store'

/**
 * How long the ambulance has (#191 step 6).
 *
 * Owner, 2026-08-28: "let's add an on-screen timer showing their time to revive
 * please".
 *
 * ═══ WHY THIS DOES NOT CONTRADICT "THE ONLY NOTIFICATION" ═══
 *
 * #191 says two things that look opposed and are not:
 *
 *   "A single DUI: 'press [interact key] to call a medic'. This is the only
 *    notification in the entire cycle. Nothing else may be shown at any point."
 *   "A timer is shown to the player: the timeout, derived from the estimated
 *    driving time for that route."
 *
 * The first governs NOTIFICATIONS -- things that arrive on an event, say a
 * sentence and leave. There is still exactly one of those, it is the CPR row on
 * the bleed-out card, and nothing was added to dispatch, arrival, the ambulance
 * being destroyed or a recovery firing. This is a READOUT: a number that sits in
 * one place for exactly as long as the state it describes, the way the storm
 * clock and the warmup clock do. The owner has now asked for it by name.
 *
 * IF YOU ARE HERE TO DELETE THIS FILE citing "the only notification", read both
 * quotes again. br_core/client/rescue.lua carries the same note at the top,
 * because that is the other place the argument would be had.
 *
 * ═══ IT IS MOUNTED OUTSIDE THE HUD, WHICH IS THE WHOLE DESIGN ═══
 *
 * The ride hides the entire HUD -- also the owner's, the same day: "while in the
 * ambulance, our HUD should be hidden just like in the bus". So this readout has
 * to be an exception to a rule he also asked for, and there were two ways to
 * build it:
 *
 *   1. MAKE THE SUPPRESSION SELECTIVE -- let `Hud` stay mounted and teach the
 *      surfaces inside it which of them survive a ride. Rejected. `hudUp` is one
 *      boolean that turns off vitals, counters, kill feed, squad panel,
 *      inventory, chat, the TAB panel and the bleed-out card, and its value is
 *      that it cannot miss one. Turning it into "everything except..." starts a
 *      list, and lists grow: the next surface added to the HUD would inherit
 *      whichever answer its author happened to think about.
 *
 *   2. DRAW IT OUTSIDE THE HIDDEN TREE. Taken. `hudUp` keeps meaning exactly
 *      what it meant, hiding the HUD still hides all of it, and this is a
 *      sibling of `Hud` in App.tsx rather than a child.
 *
 * That is not a new pattern here: DeathVerdict sits beside `Hud` for the same
 * reason -- "it is not HUD chrome and must not inherit its visibility".
 *
 * ═══ WHERE IT SITS ═══
 *
 * Top centre, on --safe-y: the slot Hud.tsx describes as "whichever clock
 * matters right now", shared by the warmup countdown and the storm bar. During a
 * ride that slot is empty, because the HUD that owns it is hidden -- so this
 * lands in the place the interface already puts clocks rather than inventing a
 * position for the one screen nothing else is on. A centred surface needs no
 * ultrawide correction (Hud.tsx: the engine's layout box is itself centred), and
 * the camera is a chase shot of the ambulance, which lives in the middle of the
 * frame and below.
 *
 * ═══ WHAT IT COUNTS DOWN TO, AND WHY THAT IS "TIME TO REVIVE" ═══
 *
 * `rideEndsAt` is the server's `rec.deadlineAt`, carried to the client on
 * RESCUE_BEGIN and parked on its ride record. Nothing is derived here: a second
 * deadline computed in the browser could disagree with the one that actually
 * ends the journey, and the player would be watching the wrong clock.
 *
 * AND ZERO IS NOT A THREAT. server/rescue.lua's tick reads
 * `if now >= rec.deadlineAt then if rec.everMoved then finish(src, true, ...)`
 * -- a moving ambulance whose deadline lands DELIVERS. So this is an upper bound
 * on the wait, which is exactly the thing the owner asked to see, and beating it
 * is the normal case: `etaSlack` is 1.8, so a drive that goes to plan ends with
 * a little under half the clock left. The one case where zero is fatal is an
 * ambulance that never moved at all, which is a ride that was already broken and
 * not a race the player could have run differently.
 *
 * THAT IS WHY NOTHING HAPPENS IN THE LAST SECONDS. No red, no pulse, no growing
 * numeral. Escalation would be a lie about what zero means, and this project has
 * a standing rule against flourish nobody asked for. It is a `.panel`, not the
 * `.panel-hot` the other clocks wear, for the same reason: that placard has a
 * demanding cap and a border that breathes, and neither is true here.
 *
 * ═══ AND NO WORDS ═══
 *
 * A timer is a number. There is no cap, no caption and no unit -- m:ss is what
 * makes it read as a clock rather than as a score, and it is a format rather
 * than a sentence. It is held at m:ss BELOW a minute too, where the storm and
 * warmup clocks drop to bare seconds: those two have a cap saying what they are
 * and this one deliberately has nothing, so `0:07` is doing work that `7` would
 * not, and the width never jumps at the minute boundary.
 *
 * The digits are written straight to the node from one requestAnimationFrame
 * loop, like every other countdown in the HUD -- a re-render per frame for four
 * characters is the tax those rules exist to avoid.
 */
export default function RescueTimer({ show }: { show: boolean }) {
  const dbno = useUi(selDbno)
  const offset = useUi((s) => s.clockOffset)
  const timeRef = useRef<HTMLSpanElement>(null)

  // Zero means no clock: Lua zeroes it the instant the ride ends, and a server
  // that never sends it leaves it undefined. Either way there is nothing to
  // count and nothing is drawn.
  const endsAt = dbno.rideEndsAt ?? 0
  const showing = show && endsAt > 0

  useEffect(() => {
    if (!showing) return
    let raf = 0

    const tick = () => {
      const node = timeRef.current
      if (node) {
        // A SERVER timestamp. The browser's wall clock shares no origin with
        // it, so `clockOffset` is what makes the comparison mean anything --
        // the rule StormBar, WarmupTimer and the bleed-out card all follow.
        const left = Math.max(0, endsAt - (Date.now() + offset))
        const total = Math.ceil(left / 1000)
        const next = `${Math.floor(total / 60)}:${String(total % 60).padStart(2, '0')}`
        if (node.textContent !== next) node.textContent = next
      }
      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [showing, endsAt, offset])

  // Nothing at all off a ride -- not an empty container. This is the only thing
  // on the screen while it is up, and a zero-height box in the clock slot is one
  // more thing for the next layout question to trip over.
  if (!showing) return null

  return (
    <div
      className="fixed left-1/2 -translate-x-1/2 pointer-events-none"
      style={{ top: 'var(--safe-y)' }}
      aria-hidden
    >
      <div className="panel px-4 py-1.5">
        <span
          ref={timeRef}
          className="font-display block leading-none tabular-nums text-white/95"
          style={{ fontSize: '1.4rem', textShadow: 'var(--shadow-text)' }}
        >
          {/* The same placeholder the warmup and bleed-out countdowns ship,
              for the same one frame before the first rAF lands -- and in
              practice never seen, because a ride opens behind a screen fade.
              `0:00` would be worse than a dash: it reads as expired. */}
          --
        </span>
      </div>
    </div>
  )
}
