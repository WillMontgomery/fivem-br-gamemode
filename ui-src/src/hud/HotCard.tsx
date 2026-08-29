import type { ReactNode, Ref } from 'react'

/**
 * THE PLACARD, AND THE NUMERAL INSIDE IT.
 *
 * Owner, 2026-08-29: "Please rebuild the revive timer UI to be the same card as
 * the bleed out card and timer."
 *
 * ═══ WHY THIS IS A COMPONENT AND NOT A LINE IN Hud.tsx ═══
 *
 * The two surfaces he is asking to look alike cannot live in the same place in
 * the tree, and that is not an accident of how they were built -- it is the
 * whole reason the ride's clock exists at all:
 *
 *   DbnoOverlay   is drawn INSIDE `Hud`, which the ride hides. "I need you to
 *                 make the bleed out timer completely go away while in the
 *                 ambulance" (2026-08-28) is enforced by `hudUp` in App.tsx and
 *                 by nothing inside the card.
 *   RescueTimer   is a SIBLING of `Hud`, because it is the one readout that
 *                 survives that suppression -- "while in the ambulance, our HUD
 *                 should be hidden just like in the bus", plus "let's add an
 *                 on-screen timer showing their time to revive please", the
 *                 same day.
 *
 * So "make it the same card" cannot be answered by moving the timer next to the
 * card. tools/test_rescue.lua asserts that Hud.tsx never renders RescueTimer,
 * and it should keep asserting it: the value of `hudUp` is that it is one
 * boolean with no exceptions in it, and the moment the HUD tree contains
 * something that hides itself back in, the next surface added to that tree
 * inherits whichever answer its author happened to think about.
 *
 * What CAN be shared is the appearance, and that is all this is: the placard
 * and the numeral, with no position, no gating and no opinion about which
 * subtree it is mounted in. Both callers keep their own wrapper and their own
 * visibility rule, and the thing the owner actually pointed at -- the object on
 * screen -- is now one piece of markup rather than two that agree by memory.
 *
 * ═══ THE CAP IS OPTIONAL, AND THAT IS THE POINT OF THE PROP ═══
 *
 * `.panel-hot`'s defining feature is a solid cap bar carrying an inverted
 * label, and index.css says so. It is still optional here, because the ride has
 * no label to put in one: DbnoOverlay's cap says "You are down", which is false
 * in an ambulance, and inventing a replacement would be exactly the unsolicited
 * UI copy this project has a standing rule against. A card with no cap is the
 * same object with its heading left off; a card with a heading nobody asked for
 * is a different bug.
 *
 * ═══ STORMBAR AND WARMUPTIMER ARE NOT CONVERTED, DELIBERATELY ═══
 *
 * They are the same shape and they are obvious candidates. They are also two
 * surfaces nobody reported, in a round that is about the ride's clock and a
 * double verdict, and a diff that touches the storm placard is a diff the owner
 * has to look at in game. Left for their own change.
 */

/**
 * The placard. Position is the caller's -- this draws no wrapper.
 *
 * @param hot      the `--hot` colour. It drives the border, the cap fill and
 *                 the border's pulse together, so there is one variable to set
 *                 and no way to end up with a cap that disagrees with its edge.
 * @param cap      the heading, if this card has earned one. Omitted means no
 *                 cap element at all, not an empty one.
 * @param minWidth so a countdown does not resize its own placard as the digits
 *                 change. In rem, like every other size in the interface.
 */
export function HotCard({
  hot,
  cap,
  minWidth,
  children,
}: {
  hot: string
  cap?: ReactNode
  minWidth: string
  children: ReactNode
}) {
  return (
    <div
      className="panel-hot"
      style={{
        minWidth,
        ['--hot' as string]: hot,
      }}
    >
      {/* NO `tscale` HERE, and that is deliberate rather than an omission:
          `.panel-hot > .cap` is (0,2,0) and would beat it, so the class would
          sit in the markup implying a behaviour it does not have. The text
          slider is applied inside the .cap rule itself -- see index.css. */}
      {cap !== undefined && <div className="cap">{cap}</div>}
      <div className="hotbody">{children}</div>
    </div>
  )
}

/**
 * The big number in a placard's body.
 *
 * WRITTEN THROUGH THE REF, NEVER THROUGH A PROP. Every countdown in this
 * interface drives its digits from one requestAnimationFrame loop straight into
 * the node, because a re-render per frame to move four characters is the tax
 * those loops exist to avoid. So this renders the placeholder and hands the
 * caller the element; the caller owns the clock.
 *
 * `--` AND NOT `0:00`. It is on screen for the single frame before the first
 * rAF lands. A zero reads as expired; a dash reads as not yet known, which is
 * what it is.
 *
 * THE FORMAT IS THE CALLER'S TOO, and the two callers legitimately differ: a
 * bleed runs 40-120s and reads as `93s`, while a drive across the map is
 * minutes and reads as `2:47`. Sharing the format would mean either `167s` on
 * an ambulance or a clock that jumps width at the minute boundary. What is
 * shared is the type, the size, the tracking and the shadow -- which is what
 * "the same timer" means when you are looking at the screen.
 */
export function HotTime({
  ref,
  fs = '2rem',
}: {
  ref?: Ref<HTMLSpanElement>
  fs?: string
}) {
  return (
    <span
      ref={ref}
      className="font-display block leading-none tabular-nums"
      style={{ fontSize: fs, textShadow: 'var(--shadow-text)' }}
    >
      --
    </span>
  )
}
