import { useRef } from 'react'
import { HotCard, HotTime } from './HotCard'
import { useCountdownText } from './useCountdownText'

/**
 * Warmup countdown.
 *
 * Warmup is the one state where the player is standing around with nothing to
 * do and no idea how long it lasts. Without a number on screen it is impossible
 * to tell a warmup from a stuck server -- which is the same complaint the queue
 * screen had before it showed its counts.
 *
 * The value is derived locally from `endsAt`; the server sends that once per
 * transition and never ticks a countdown over the bridge. It can also move
 * EARLIER, when a full lobby cuts the wait short, which arrives as an ordinary
 * state rebroadcast and needs no special handling here.
 *
 * Like StormBar, the digits are written straight to a DOM node from one
 * requestAnimationFrame loop rather than through setState -- a re-render per
 * frame for a two-character number is exactly the tax the HUD rules exist to
 * avoid. And like StormBar, the placard around them is `HotCard` rather than a
 * fourth hand-written copy of the same box.
 *
 * ═══ IT DRAWS WHAT IT IS GIVEN, AND ITS CALLER DECIDES WHEN (#431) ═══
 *
 * `endsAt` is the match's deadline and `offset` the server clock's, both
 * passed in, and whether the card is up at all is decided where it is mounted:
 * Hud.tsx, with the walkthrough's rule beside it. This used to read the store
 * and return null on its own condition, which is right for today's HUD and
 * wrong for a layer that holds an element's last frame through its way out.
 * UI v2's HUD does (#431), and a card that re-reads the store as it leaves
 * renders empty and pops. The markup is the same, element for element.
 */
export default function WarmupTimer({ endsAt, offset }: { endsAt: number; offset: number }) {
  const timeRef = useRef<HTMLSpanElement>(null)

  // ONE SHARED, DRIFT-CORRECTED SCHEDULER (#319, shared with StormBar). This was
  // a requestAnimationFrame loop that recomputed the number every frame and
  // wrote it to `timeRef` only on a change -- the screen ticked once a second
  // while the loop woke sixty times a second for as long as warmup lasted.
  // `useCountdownText` arms one timer to the next displayed-second boundary,
  // recomputes `endsAt - (now + offset)` from the server clock on each wake, and
  // stops at zero. The card is mounted only while it shows, so its unmount tears
  // the timer down the instant it hides, and a new `endsAt` re-arms it if
  // warmup is re-broadcast earlier (a full lobby cutting the wait short arrives
  // as an ordinary state rebroadcast and needs no handling here). Same digits,
  // same immediate reaction, no loop.
  useCountdownText(timeRef, endsAt, offset)

  // THE SAME OBJECT AS THE STORM BAR (owner's call, 2026-08-09). Both are the
  // top-centre clock -- one before the match, one during it -- and they were
  // two different widgets: a flat `.panel` reading label-number-caption on one
  // line, and a `.panel-hot` placard with a coloured cap over a big numeral.
  // Sharing the placard means a player learns to read the top of the screen
  // once, and the handover from warmup to storm is the same card changing what
  // it counts rather than one widget being replaced by another. That sharing is
  // now literal -- both draw `HotCard` -- rather than two copies of the markup
  // that happened to match.
  //
  // Its cap is neutral: nothing about warmup is urgent, and the cap colour is
  // what the storm bar uses to say that something is. The literal is the storm
  // bar's own neutral, deliberately: these two hand over to each other in the
  // same place on screen, so the grey they hold has to be one grey.
  //
  // NO `key` HERE, unlike the storm bar. There is no state for this card to
  // swap into -- it counts one thing and then unmounts -- so there is nothing
  // for a drop-in replay to mark.
  return (
    // data-tut ON A WRAPPER, NOT ON <HotCard>. TypeScript does not type-check
    // hyphenated JSX attributes, so one written on a component that does not
    // spread its props compiles clean and then vanishes (#261). `inline-block`
    // because a wrapper with no layout box measures 0x0 and the ring draws in
    // the corner.
    <span data-tut="hud-timer" className="inline-block">
    <HotCard hot="rgba(120,132,160,0.85)" cap="Dropping in" minWidth="13rem">
      <>
        {/* 1.4rem rather than `HotTime`'s 2rem default: that is the bleed-out
            card's numeral. This is the storm bar's, because this card hands
            over to the storm bar and a size change at that handover would read
            as the widget being replaced. */}
        <HotTime ref={timeRef} fs="1.4rem" />
        <span className="text-[0.55rem] font-semibold uppercase tracking-[0.18em] text-white/50">
          warmup
        </span>
      </>
    </HotCard>
    </span>
  )
}
