import { useRef, type CSSProperties, type ReactNode } from 'react'
import { PresencePhaseCtx } from './context'
import { usePresence, type PresenceOptions } from './usePresence'

export type PresenceTag = 'div' | 'span' | 'section' | 'aside' | 'li' | 'ul'

export interface PresenceProps extends Omit<PresenceOptions, 'scoped'> {
  /** Wanted on screen (default true; the scope's want and hold still apply). */
  show?: boolean
  as?: PresenceTag
  id?: string
  className?: string
  style?: CSSProperties
  /** The walkthrough's anchor (data-tut), when a card points at it. */
  tut?: string
  /** An ARIA role for the wrapper (a dialog). */
  role?: string
  children?: ReactNode
}

/**
 * ONE ANCHOR, AS ITS OWN WRAPPER (#431). Always a wrapper of its own: never
 * `.hud-safe` (check-ui R12), never a fixed box or an ancestor of one (R9),
 * never a -translate-x-1/2 centering box, never an element with a transform of
 * its own (the active slot, the hitmarker, the elim banner). Put the centering
 * or the fixed position on the element outside it.
 *
 * THE WORDS ARE HELD THROUGH THE WAY OUT: by the time `show` is false the
 * caller has usually stopped supplying its children, and an empty box would
 * animate off (ui/Page.tsx's rule). A leave driven by the scope keeps the
 * children live.
 */
export function Presence({ show = true, as = 'div', id, className, style, tut, role, children, ...opts }: PresenceProps) {
  const p = usePresence(show, opts)
  const last = useRef<ReactNode>(children)
  if (show) last.current = children
  if (!p.mounted) return null
  const Tag = as
  const cls = [className, p.rootProps.className].filter(Boolean).join(' ') || undefined
  return (
    <PresencePhaseCtx.Provider value={p.info}>
      <Tag
        {...p.rootProps}
        id={id}
        role={role}
        data-tut={tut}
        className={cls}
        style={{ ...style, ...p.rootProps.style }}
      >
        {show ? children : last.current}
      </Tag>
    </PresencePhaseCtx.Provider>
  )
}
