import { useCallback, useRef, type ReactNode } from 'react'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Modal from '@cloudscape-design/components/modal'
import SpaceBetween from '@cloudscape-design/components/space-between'
import type { MarketItem } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, CONFIRM_TITLE, confirmBody } from './copy'
import { ONE_LINE } from './look'

/**
 * A DIALOG IN THE ISLAND, NOT IN <body>, as Locker v2's are (getModalRoot): it
 * wears the island's zoom and theme, and market.css squares its corners.
 * Escape closes it alone (MarketV2.tsx's key handler), never the screen
 * behind it. Both of the Market's dialogs are this one.
 */
export function IslandModal({ visible, root, header, onDismiss, footer, children }: {
  visible: boolean
  root: HTMLElement | null
  header: string
  onDismiss: () => void
  footer: ReactNode
  children: ReactNode
}) {
  const getRoot = useCallback(async () => {
    if (!root) throw new Error('market dialog root missing')
    return root
  }, [root])
  const keepRoot = useCallback(() => { /* the island owns it */ }, [])
  if (!root) return null
  return (
    <Modal
      visible={visible}
      onDismiss={onDismiss}
      getModalRoot={getRoot}
      removeModalRoot={keepRoot}
      closeAriaLabel={BTN.cancel}
      size="small"
      header={<span style={ONE_LINE}>{header}</span>}
      footer={footer}
    >
      {children}
    </Modal>
  )
}

/**
 * THE BUY CONFIRM (#411). Owner, 2026-10-14: ""buy" prompts should have a
 * title of "Are you sure?" and content with no photo and just "Buy [name]
 * canopy for [amount] Volts?" etc. things like that, in that format."
 *
 * Every purchase on this screen comes through here: a price press opens it
 * (model.ts buyPress), and only its Buy sends MARKET_BUY -- an id, nothing
 * else. Nothing changes on the card until the server's new grid says so.
 */
export function BuyConfirm({ item, currency, root, onCancel, onBuy }: {
  /** The item, read from the latest grid; null when no confirm is up. */
  item: MarketItem | null
  currency: string
  root: HTMLElement | null
  onCancel: () => void
  onBuy: (item: MarketItem) => void
}) {
  // The dialog keeps its words while it fades out, rather than emptying the
  // moment it is dismissed.
  const last = useRef<MarketItem | null>(item)
  if (item) last.current = item
  const shown = last.current

  return (
    <IslandModal
      visible={item !== null}
      root={root}
      header={CONFIRM_TITLE}
      onDismiss={onCancel}
      footer={(
        <Box float="right">
          <SpaceBetween direction="horizontal" size="xs">
            {/* Hover speaks and a press travels, as on every lobby button
                (market.css `.mk2-act`). */}
            <span className="mk2-act" onPointerEnter={() => play('ui.hover')}>
              <Button variant="link" onClick={onCancel}>{BTN.cancel}</Button>
            </span>
            <span className="mk2-act" onPointerEnter={() => play('ui.hover')}>
              <Button variant="primary" onClick={() => { if (item) onBuy(item) }}>{BTN.buy}</Button>
            </span>
          </SpaceBetween>
        </Box>
      )}
    >
      {shown && <Box variant="p"><span style={ONE_LINE}>{confirmBody(shown.name, shown.kind, shown.price, currency)}</span></Box>}
    </IslandModal>
  )
}
