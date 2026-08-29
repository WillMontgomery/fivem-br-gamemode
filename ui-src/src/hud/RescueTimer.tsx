import { useEffect, useRef } from 'react'
import { useUi, selDbno } from '../store'
import { HotCard, HotTime } from './HotCard'

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
 * a standing rule against flourish nobody asked for.
 *
 * ═══ IT IS THE BLEED-OUT CARD, AND THAT IS A CHANGE ═══
 *
 * Owner, 2026-08-29: "Please rebuild the revive timer UI to be the same card as
 * the bleed out card and timer."
 *
 * This shipped as a bare numeral on a `.panel` (d7272a6), and the argument for
 * that is one paragraph up this file: `.panel-hot` demands a cap and breathes
 * its border, and neither belongs on a deadline that ends in a delivery. He has
 * looked at it and asked for the placard anyway, so the placard is what it is --
 * `HotCard`, the same one DbnoOverlay draws, with DbnoOverlay's 2rem numeral in
 * the body.
 *
 * NOT BY MOVING IT INTO THE HUD. It is still a sibling of `Hud` in App.tsx and
 * Hud.tsx still must never render it -- the whole reason this component exists
 * is that the ride hides the HUD and this is the one thing that survives that.
 * What is shared is the appearance; hud/HotCard.tsx has the long version.
 *
 * ═══ THE COLOUR IS `--color-hp`, WHICH IS THE CARD'S OWN VOCABULARY ═══
 *
 * `.panel-hot` has no neutral: `--hot` drives the border and its pulse, and the
 * default is `--color-danger`. Red is the one thing this readout must not say --
 * zero is not a threat here, because a moving ambulance whose deadline lands
 * DELIVERS (server/rescue.lua's tick). So it takes the other colour the same
 * card already uses: DbnoOverlay flips to `--color-hp` when somebody is picking
 * you up, and an ambulance with you in the back is that state. One card, the
 * same two colours, meaning the same two things -- rather than a third colour
 * invented for this surface.
 *
 * ═══ AND STILL NO WORDS ═══
 *
 * A timer is a number. No cap, no caption and no unit: the card's heading would
 * have to say something, "YOU ARE DOWN" is false in an ambulance, and inventing
 * a replacement is exactly the unsolicited copy this project bans. `HotCard`
 * takes no `cap` here and draws no cap element at all.
 *
 * m:ss is a FORMAT rather than a sentence, which is why it is allowed to be the
 * one thing that differs from the bleed clock's `93s`: a drive across the map is
 * minutes, and `167s` is not a clock. It is held at m:ss BELOW a minute too --
 * `0:07` reads as a clock where `7` reads as a score, and the width never jumps
 * at the minute boundary.
 *
 * The digits are written straight to the node from one requestAnimationFrame
 * loop, like every other countdown in the HUD -- a re-render per frame for four
 * characters is the tax those rules exist to avoid.
 *
 * ═══ AND IT STANDS DOWN WHEN THE MATCH IS DECIDED ═══
 *
 * `show` is `ridingAmbulance && !tearingDown` in App.tsx, and the second half is
 * not belt-and-braces -- see the note there. A ride does not end by a message:
 * client/rescue.lua's `rescue.sanity` sweep tears it down at 1 Hz when the match
 * stops being PLAYING, and the verdict screen mounts 500ms after the match ends.
 * The match-state bit is on this client the instant the transition arrives, so
 * gating on it is what stops this placard being on screen underneath
 * VICTORY ROYALE for the second in between.
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
      {/* NO `cap`, so no cap element -- the card is the body alone. `14rem` is
          DbnoOverlay's width, not a number picked for this content: the two are
          meant to read as one object, and a placard that is narrower here
          because it happens to hold fewer characters would read as a different
          one. The placeholder `--` and the numeral's type, size and shadow all
          come from `HotTime`, which is the bleed-out card's own numeral. */}
      <HotCard hot="var(--color-hp)" minWidth="14rem">
        <HotTime ref={timeRef} />
      </HotCard>
    </div>
  )
}
