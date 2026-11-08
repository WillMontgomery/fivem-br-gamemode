import { useContext, type CSSProperties, type ReactNode } from 'react'
import { QuickCtx } from './context'
import type { PresenceTag } from './Presence'
import { usePresence } from './usePresence'

/**
 * THE QUICK HIDE: A LAYER STATE (#431), applied once at a layer root -- the ui
 * gate for GTA's map and menus, the HUD root for pause and the scope. It fades
 * the layer's opacity over --bc-t-quick (150 ms) each way, never unmounts and
 * never replays an entrance.
 *
 * The presences under it IGNORE it and finish underneath: an entrance the map
 * interrupts completes unseen, so the return is only the 150 ms fade. Only a
 * presence whose want goes false WHILE the layer is hidden changes: it goes
 * straight to hidden, unseen, with no offAir.
 *
 * Both layers can key on one edge: give the ui gate and the HUD root the same
 * `hidden` (or nest two), and chat, notices and the HUD return together.
 */
export function QuickHide({ hidden, as = 'div', className, style, children }: {
  hidden: boolean
  as?: PresenceTag
  className?: string
  style?: CSSProperties
  children?: ReactNode
}) {
  // `hidden === false`, never the negation with a bang in front: Tailwind reads
  // this file as text, and to it that spelling is an important `hidden` rule
  // the bundle would then carry (scripts/test-broadcast.mjs).
  const p = usePresence(hidden === false, { preset: 'quickHide', keepMounted: true, appear: false, scoped: false })
  const parent = useContext(QuickCtx)
  const quick = parent || p.phase === 'leaving' || p.phase === 'hidden'
  const Tag = as
  const cls = [className, p.rootProps.className].filter(Boolean).join(' ') || undefined
  return (
    <QuickCtx.Provider value={quick}>
      <Tag {...p.rootProps} className={cls} style={{ ...style, ...p.rootProps.style }}>
        {children}
      </Tag>
    </QuickCtx.Provider>
  )
}
