import { useCallback, useRef } from 'react'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import Modal from '@cloudscape-design/components/modal'
import SpaceBetween from '@cloudscape-design/components/space-between'
import type { MarketItem } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, confirmTitle } from './copy'
import { GOLD_INK } from './look'
import { Art } from './Card'

/**
 * THE BUY CONFIRM (#411): "a dialog with the art, name, price, Cancel and Buy.
 * Today one stray click can spend 6,500 Volts."
 *
 * Every purchase on this screen comes through here: a price press opens it
 * (model.ts buyPress), and only its Buy sends MARKET_BUY -- an id, nothing
 * else. Nothing changes on the card until the server's new grid says so.
 *
 * INTO THE ISLAND, NOT <body>, as Locker v2's dialogs are (getModalRoot): it
 * wears the island's zoom and theme. Escape closes the dialog alone
 * (MarketV2.tsx's key handler), never the screen behind it.
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

  const getRoot = useCallback(async () => {
    if (!root) throw new Error('market confirm root missing')
    return root
  }, [root])
  const keepRoot = useCallback(() => { /* the island owns it */ }, [])

  if (!root) return null

  return (
    <Modal
      visible={item !== null}
      onDismiss={onCancel}
      getModalRoot={getRoot}
      removeModalRoot={keepRoot}
      closeAriaLabel={BTN.cancel}
      size="small"
      header={shown ? confirmTitle(shown.name) : ''}
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
      {shown && (
        <div style={{ display: 'flex', alignItems: 'center', gap: '1em' }}>
          <div style={{ width: '7em', height: '5em', flex: '0 0 auto' }}>
            <Art item={shown} />
          </div>
          <div>
            <Box variant="h3">{shown.name}</Box>
            <div style={{ display: 'flex', alignItems: 'baseline', gap: '0.4em' }}>
              <span
                className="font-display tabular-nums"
                style={{ fontSize: '1.5em', lineHeight: 1, color: GOLD_INK }}
              >
                {shown.price.toLocaleString()}
              </span>
              <Box variant="small" color="text-body-secondary">{currency}</Box>
            </div>
          </div>
        </div>
      )}
    </Modal>
  )
}
