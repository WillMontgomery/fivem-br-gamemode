import { useEffect, useRef } from 'react'
import { useUi } from '../store'
import { HotCard, HotTime } from './HotCard'
import type { StormPayload } from '../bridge/types'

/**
 * Storm readout: a label and a countdown. Nothing else, deliberately --
 * the arrow this used to carry pointed relative to the PED, not the camera,
 * which read as wrong more often than right; direction now lives on the
 * minimap itself (a purple centre blip that clamps to the minimap's edge
 * when the circle is off-screen), and phase/radius numbers were dashboard
 * detail nobody rotates by.
 *
 * The countdown updates every frame but does NOT go through React: one
 * requestAnimationFrame loop writes to a DOM node via a ref. The value is
 * computed locally from `endsAt`, a server timestamp, against the synced
 * clock offset -- the server never ticks a countdown over the bridge.
 *
 * THE PLACARD COMES FROM `HotCard`, like the bleed-out card and the ride's
 * clock. Nothing on screen changed when it did: this file used to hand-write
 * the same `.panel-hot` / `.cap` / `.hotbody` box, and four copies of one piece
 * of markup only agree for as long as everyone remembers to change all four.
 * What is shared is the BOX; the arrangement inside it, the two states and the
 * decision about which number is worth showing are all still this file's.
 */
export default function StormBar({ storm }: { storm: StormPayload | null }) {
  const timeRef = useRef<HTMLSpanElement>(null)
  const offset = useUi((s) => s.clockOffset)
  const endsAt = storm?.endsAt ?? 0

  useEffect(() => {
    if (!endsAt) return
    let raf = 0

    const tick = () => {
      const node = timeRef.current
      if (node) {
        // endsAt is a SERVER timestamp, same contract as the warmup timer --
        // comparing it to the raw browser clock would be comparing two
        // unrelated origins.
        const left = Math.max(0, endsAt - (Date.now() + offset))
        const total = Math.ceil(left / 1000)
        const m = Math.floor(total / 60)
        const sec = total % 60
        // NO TRAILING `s`, to match the warmup clock (owner's call,
        // 2026-08-09). Two clocks in the same place on the screen formatting
        // the same quantity differently is the kind of inconsistency that
        // reads as a bug even when nobody can say why.
        const next = m > 0 ? `${m}:${String(sec).padStart(2, '0')}` : `${sec}`
        // Only touch the DOM when the rendered text actually changes.
        if (node.textContent !== next) node.textContent = next
      }
      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [endsAt, offset])

  if (!storm) return null

  const shrinking = storm.phaseState === 'shrinking'
  const hurting = storm.edgeDistance > 0 && (storm.dps ?? 0) > 0

  // THE BAR IS ALWAYS ON (user call, 2026-08-05). It used to hide through the
  // long phase-1 hold, with toasts announcing "the storm is coming in 2
  // minutes" every thirty seconds instead -- two systems saying the same thing
  // badly, and the toasts could only ever land on a 30-second slot while the
  // timer they were approximating was exact. One countdown, from the first
  // moment there is a storm to count down to.

  // The label tells you what the number MEANS -- a bare "10s" told nobody
  // anything. Holding: time until the wall starts moving. Shrinking: time
  // until it stops.
  const label = shrinking ? 'Storm closing now' : 'Storm moving in'

  // TWO SURFACES, NOT ONE RESTYLED (user call, 2026-08-04, rebuilt 2026-08-08).
  //
  // Safe is a `.panel` and it recedes: a label and a countdown. Caught out is a
  // `.panel-hot` -- a structurally different object with a cap bar and an
  // inverted label, which drops in from above rather than fading. Recolouring
  // one box red is something any element could do; growing a header is
  // something only the urgent surface does, so it survives peripheral vision
  // and colourblind modes both.
  //
  // The number also changes, because the useful one changes. Inside, it is the
  // wall's schedule. Caught out, the schedule is irrelevant -- what matters is
  // how far you have to run.
  // ONE SURFACE, TWO STATES (user, 2026-08-08: "we should be using that for
  // storm moving in too"). The placard was only appearing when caught out,
  // which meant the readout a player looks at for the whole match was a plain
  // panel and the good one was reserved for the rare case.
  //
  // What changes between them is the CAP COLOUR and the NUMBER -- red and your
  // distance when you are in it, storm magenta and the wall's schedule when
  // you are not. The arrangement is the same, so the swap reads as the same
  // object changing its mind rather than as two different widgets.
  //
  // `--hot` drives the cap fill and the border together; the drop-in animation
  // is keyed off the state so it replays on the swap and only on the swap. The
  // `key` goes on `HotCard` because remounting the component remounts the
  // `.panel-hot` div the animation is on -- the same element it sat on when
  // this file drew that div itself.
  return (
    <HotCard
      key={hurting ? 'out' : 'in'}
      hot={hurting
        ? 'var(--color-danger)'
        : shrinking ? 'var(--color-storm)' : 'rgba(120,132,160,0.85)'}
      cap={hurting ? 'Get out of the storm' : label}
      minWidth="13rem"
    >
      {hurting ? (
        <>
          {/* The wall's schedule is useless when you are already in it. The
              number that matters is how far you have to run.

              SPELLED OUT RATHER THAN `HotTime`, and that is the honest way
              round: `HotTime` renders the `--` placeholder and hands back the
              node because every clock in this HUD is written by a rAF loop
              through a ref. This number is not a clock -- React already has it,
              it re-renders with the envelope, and there is no placeholder frame
              to cover. Same type, size and shadow; different mechanism. */}
          <span
            className="font-display block leading-none tabular-nums"
            style={{ fontSize: '1.4rem', textShadow: 'var(--shadow-text)' }}
          >
            {Math.max(0, Math.round(storm.edgeDistance))}m
          </span>
          <span className="text-[0.55rem] font-semibold uppercase tracking-[0.18em] text-white/50">
            outside the circle
          </span>
        </>
      ) : (
        // 1.4rem, not `HotTime`'s 2rem default: that is the bleed-out card's
        // numeral, and this one shares the top of the screen with a cap and a
        // caption rather than owning its corner.
        <HotTime ref={timeRef} fs="1.4rem" />
      )}
    </HotCard>
  )
}
