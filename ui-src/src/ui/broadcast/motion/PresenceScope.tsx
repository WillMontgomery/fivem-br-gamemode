import { useCallback, useContext, useMemo, useRef, useState, type ReactNode } from 'react'
import { ClockCtx, ScopeCtx, type Drain, type Now, type ScopeValue } from './context'

/**
 * A SCREEN'S PRESENCES, AS ONE REVEAL (#431). A React context, no element.
 *
 *   want     the screen is wanted (the HUD is up). A presence's own want is
 *            ANDed with it, so the scope going off takes every anchor off.
 *   hold     mounted, hidden, layer-off (the curtain is up). The reveal plays
 *            when it is released: key it on the curtain's `leaving` going
 *            true -> false, never on hudUp, so the HUD is complete under the
 *            curtain and arrives as the curtain lifts.
 *   preset   the ONE place a screen picks its motion: every presence under it
 *            that names none takes this one.
 *   step     the stagger between anchors, if not the preset's.
 *
 * Place the HUD's scope inside the ui gate and ABOVE both Hud and its App-level
 * siblings, so chat, notices, the rescue clock and the death word join one
 * reveal. A presence that mounts mid-reveal (the squad slot and the inventory
 * column on landed) takes its slot if it is still ahead, or goes at once.
 *
 * ITS WAY OUT IS ONE (context.ts Drain): the outermost scope keeps the drain
 * and every scope inside it shares it. A presence whose leave the scope drove
 * stays mounted, hidden, holding its box, until the last leave in the drain
 * ends; then they all go together. A page's head, foot and cards each end
 * their leave at their own time, and one unmounting mid-close reflowed the
 * cards still fading (a jump of up to 128 px).
 */
export function PresenceScope({ want = true, hold = false, preset, step, children }: {
  want?: boolean
  hold?: boolean
  preset?: string
  step?: number
  children?: ReactNode
}) {
  const parent = useContext(ScopeCtx)
  const now: Now = useContext(ClockCtx)
  const effWant = parent.want && want
  const effHold = parent.hold || hold
  const live = effWant && !effHold

  // When the current reveal began: the moment `live` last went true.
  const [rec, setRec] = useState(() => ({ live, start: live ? now() : Number.NaN }))
  let start = rec.start
  if (rec.live !== live) {
    start = live ? now() : rec.start
    setRec({ live, start })
  }

  const orders = useRef(new Map<number, number>())
  const seq = useRef(0)
  const register = useCallback((order: number) => {
    const id = ++seq.current
    orders.current.set(id, order)
    return () => { orders.current.delete(id) }
  }, [])
  const maxOrder = useCallback(() => {
    let m = 0
    for (const o of orders.current.values()) if (o > m) m = o
    return m
  }, [])

  // The drain: the outermost scope's, shared by every scope inside it.
  const own = useRef<Drain | null>(null)
  if (parent.drain === null && own.current === null) own.current = { leaving: new Set(), parked: new Map() }
  const drain = parent.drain ?? own.current

  const value = useMemo<ScopeValue>(() => ({
    want: effWant,
    hold: effHold,
    preset: preset ?? parent.preset,
    step: step ?? parent.step,
    start,
    register,
    maxOrder,
    drain,
  }), [effWant, effHold, preset, parent.preset, step, parent.step, start, register, maxOrder, drain])

  return <ScopeCtx.Provider value={value}>{children}</ScopeCtx.Provider>
}

/** The settle clock for everything under it: a harness passes its virtual
 *  clock, so slow motion and seek() hold the settle with the CSS. */
export function PresenceClock({ now, children }: { now: Now; children?: ReactNode }) {
  return <ClockCtx.Provider value={now}>{children}</ClockCtx.Provider>
}
