import { useEffect, type ReactNode } from 'react'
import { Fit, play } from './deps'
import { Presence } from './motion/Presence'
import { Plate } from './Plate'

/**
 * DIALOGFRAME (#431): a scrim, a deck, an Anton header strap, a body, and the
 * actions at the right of the footer. As wide as its contents, 20 to 40 kit
 * units. It arrives on the broadcast preset (onAir) and leaves on offAir; the
 * scrim fades.
 *
 * ESCAPE CLOSES THE DIALOG ONLY: its listener is in the capture phase and
 * stops the key there, so the screen behind it never sees it. ITS WORDS ARE
 * HELD THROUGH ITS LEAVE (Presence keeps the last children), so it never
 * empties while it goes.
 *
 * It fills the nearest positioned box (the Market's island), never the
 * viewport: a presence is never a fixed box.
 */
export function DialogFrame({ open, title, onClose, actions, children, scrim = true }: {
  open: boolean
  /** Existing words only. */
  title: ReactNode
  onClose: () => void
  /** Buttons, primary last (on the right). */
  actions?: ReactNode
  /** The body: prose goes in `.body-text`. */
  children?: ReactNode
  scrim?: boolean
}) {
  useEffect(() => {
    if (!open) return undefined
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      play('ui.back')
      onClose()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  }, [open, onClose])

  return (
    <div className="bc-dialog-layer">
      {scrim && <Presence show={open} preset="fade" className="bc-dialog__scrim" />}
      <Presence show={open} preset="broadcast" as="section" className="bc-dialog" role="dialog">
        <div className="bc-dialog__surface bc-ch-surface" />
        <div className="bc-dialog__head">
          <Plate variant="strap" height={2.2}>
            <Plate.Line cy={1.1} ch={0.55} lh={2.2}>
              <Fit className="bc-dialog__title">{title}</Fit>
            </Plate.Line>
          </Plate>
        </div>
        <div className="bc-dialog__content bc-ch-content">
          {children}
          {actions !== undefined && <div className="bc-dialog__foot">{actions}</div>}
        </div>
      </Presence>
    </div>
  )
}
