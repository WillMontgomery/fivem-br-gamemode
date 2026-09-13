import { useEffect, useRef, useState } from 'react'
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

  // READ BEFORE THE EARLY RETURN, because the shockwave below is a hook and
  // hooks cannot sit under `if (!storm) return null`. `storm?.` rather than
  // `storm.` is the whole of the difference from where this used to be
  // computed; with no storm there is no phase, and `present` below is what
  // tells that apart from a storm that is merely holding.
  const shrinking = storm?.phaseState === 'shrinking'
  const present = storm != null

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

  // THE CLOSING SHOCKWAVE (owner, 2026-09-12): "a one-time ripple effect that
  // explodes from the border of the card, in the shape of the card, like a
  // shockwave ... when the timer changes from 'STORM MOVING IN' to 'STORM
  // CLOSING NOW' ... for 0.5 seconds." Then, on seeing it: "can you make it take
  // twice as long?" -- which is one number in index.css and nothing here.
  //
  // A COUNTER, NOT A BOOLEAN, and that is what makes it one-time. A `shrinking`
  // boolean in the markup is true for the whole of the closing phase, and the
  // storm envelope lands four times a second -- so anything gated on it directly
  // is either up permanently or restarted on every payload. `shock` changes ONCE
  // per edge, the element is keyed by it, and a key change is the only thing in
  // React that restarts a CSS animation. Between edges the span re-renders with
  // the same key and the browser leaves the animation exactly where it was.
  const [shock, setShock] = useState(0)

  // SEEDED FROM THE PHASE THIS COMPONENT FIRST SAW, never from `false`. A ref
  // that starts false makes MOUNTING during the closing phase look identical to
  // the transition into it, and this component mounts mid-match every time the
  // HUD comes back from the ride or a resource restart. `null` is "no storm yet"
  // and is deliberately not `false`: the first envelope of a match can arrive
  // already shrinking, and that is a HUD opening late, not a wall starting to
  // move.
  const seen = useRef<boolean | null>(present ? shrinking : null)
  useEffect(() => {
    const now = present ? shrinking : null
    if (now === true && seen.current === false) setShock((n) => n + 1)
    seen.current = now
  }, [present, shrinking])

  if (!storm) return null

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
  // is keyed off the state so it replays on the swap and only on the swap.
  //
  // THE `key` IS BACK ON `HotCard`. It spent one commit on the wrapper, for the
  // continuous ring that used to live there: that ring needed the card and
  // itself to remount on the same frame or their two 1.6s breaths came apart.
  // The ring is gone and the shockwave has no beat to stay in step with, so the
  // key belongs on the element whose animation it exists to replay -- and a
  // wrapper that no longer remounts is what stops a state swap mid-shockwave
  // from restarting a one-time effect.
  return (
    // `relative` so the shockwave has the card's box to explode from. It is a
    // SIBLING of the card and not a child because `.panel-hot` is
    // `overflow: hidden` for its cap bar, and that clip would cut the ripple off
    // at the card's own edge -- which is the entire distance it travels.
    //
    // No `inline-block` here, unlike WarmupTimer's wrapper: this one holds a
    // block-level card that already stretches to the slot, and an inline-block
    // would put this card and the warmup card side by side in the shared
    // top-centre slot rather than one under the other.
    <div className="relative">
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
    {/* MOUNTED ONLY AFTER AN EDGE HAS HAPPENED, and keyed by which one. `shock`
        is 0 for a HUD that opened mid-phase and for the whole holding phase, so
        there is nothing in the tree to animate; the first transition mounts it
        and every later one replaces it. Nothing here is a word or a numeral --
        the card below already says "Storm closing now". */}
    {shock > 0 && <span key={shock} className="storm-shock" aria-hidden="true" />}
    </div>
  )
}
