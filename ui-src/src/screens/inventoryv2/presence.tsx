import { useLayoutEffect, useRef, useState, type CSSProperties, type ReactNode } from 'react'
import { PresencePhaseCtx, usePresence } from '../../ui/broadcast'

/**
 * ONE PLATE'S PRESENCE, WITH THE HUD'S LIVE RULE (#431): the kit's usePresence
 * as the plate's own wrapper (never a fixed, centered or transformed box), and
 * UI v2's HUD's rule (hud/v2/Anchor.tsx `live`) that a number which changes
 * while its plate is still entering lands that plate at once
 * (`data-binv-live`, inventory.css), so it
 * is never seen half shown. The kit's Numeral shows itself at once; this shows
 * the plate around it too.
 *
 * ONLY A NUMBER THAT IS SHOWN LANDS IT. `live` is the numbers the plate draws,
 * '' (or null) where it draws none. A change TO a shown value lands the plate;
 * a number that goes away (a dropped gun's magazine, the death box) has nothing
 * left to hide, so the plate keeps its entrance, as the kit's Numeral does (it
 * goes live on a change of its value, never on its unmount).
 *
 * THE MARK STAYS FOR THE REST OF THAT ENTRANCE (entering, then shown), until
 * the plate next moves: a landed plate's numerals are past their tick-in
 * (inventory.css), and taking the mark off at the settle would hand them back
 * the tail of a reveal the landing overtook. While shown it changes nothing
 * else: every value it forces is the shown one.
 *
 * AN ELEMENT LEAVING ON ITS OWN GOES AT ONCE: while its own gate is shut it
 * takes `last`, the scope's last turn, whose reversed turn is now (the ammo
 * strap when the hand holds no gun). Only a scope-wide way out runs the turns
 * backwards.
 *
 * Its words are held through its way out, as Presence holds them.
 */
export function InvPresence({
  id, order, last, show = true, live, className, style, tut, children,
}: {
  /** data-inv-id: the plate's name, for a test or a probe to find it by. */
  id: string
  order: number
  last: number
  show?: boolean
  /** The numbers it shows ('' or null for none). */
  live: readonly unknown[]
  className?: string
  style?: CSSProperties
  tut?: string
  children: ReactNode
}) {
  const p = usePresence(show, { order: show ? order : last })
  const held = useRef<ReactNode>(children)
  if (show) held.current = children
  const key = live.join('|')
  const seen = useRef<readonly unknown[]>(live)
  const [liveEpoch, setLiveEpoch] = useState(-1)
  const phase = p.phase
  const epoch = p.info.epoch
  useLayoutEffect(() => {
    const was = seen.current
    seen.current = live
    if (phase !== 'entering') return
    if (live.some((v, i) => v !== was[i] && v !== '' && v != null)) setLiveEpoch(epoch)
    // `key` stands for `live`, whose array is new on every render.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [key, phase, epoch])
  if (!p.mounted) return null
  const landed = liveEpoch === epoch && (phase === 'entering' || phase === 'shown')
  const rp = p.rootProps
  return (
    <PresencePhaseCtx.Provider value={p.info}>
      <div
        ref={rp.ref}
        data-bc-phase={rp['data-bc-phase']}
        data-bc-preset={rp['data-bc-preset']}
        aria-hidden={rp['aria-hidden']}
        inert={rp.inert}
        data-inv-id={id}
        data-tut={tut}
        data-binv-live={landed ? '' : undefined}
        className={[className, rp.className].filter(Boolean).join(' ') || undefined}
        style={{ ...style, ...rp.style }}
      >
        {show ? children : held.current}
      </div>
    </PresencePhaseCtx.Provider>
  )
}
