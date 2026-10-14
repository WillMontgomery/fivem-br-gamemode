import { useRef } from 'react'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import type { MarketItem } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, REPLACE_TITLE } from './copy'
import { IslandModal } from './Confirm'
import { GOLD_INK, ONE_LINE, actionStyle } from './look'

/**
 * THE REPLACE DIALOG (#411). Owner, 2026-10-14: "the flow of replacing an
 * emote on the wheel is... really unintuitive. I have nothing telling me what
 * to do."
 *
 * Equip on a full wheel opens this, for that dance: the eight on the wheel,
 * each with its own Replace, and Cancel. One press says which goes, and it is
 * the existing swap -- MARKET_EQUIP { id, replace } -- so the server decides
 * exactly as it did. A grid that overtakes the dialog closes it (model.ts
 * swapStale); Escape closes it alone.
 */
export function ReplaceDialog({ choices, open, root, onReplace, onCancel }: {
  /** The dances on the wheel, in wheel order (model.ts replaceChoices). */
  choices: readonly MarketItem[]
  open: boolean
  root: HTMLElement | null
  onReplace: (out: MarketItem) => void
  onCancel: () => void
}) {
  // Keeps its rows while it fades out, rather than emptying as it goes.
  const last = useRef<readonly MarketItem[]>(choices)
  if (open) last.current = choices
  const rows = last.current

  return (
    <IslandModal
      visible={open}
      root={root}
      header={REPLACE_TITLE}
      onDismiss={onCancel}
      footer={(
        <Box float="right">
          <span className="mk2-act" onPointerEnter={() => play('ui.hover')}>
            <Button variant="link" onClick={onCancel}>{BTN.cancelSwap}</Button>
          </span>
        </Box>
      )}
    >
      <div style={{ display: 'flex', flexDirection: 'column', gap: '0.45em' }}>
        {rows.map((it) => (
          <div
            key={it.id}
            data-mk2-replace={it.id}
            style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '1em' }}
          >
            <span style={{ ...ONE_LINE, minWidth: 0 }}>{it.name}</span>
            <span className="mk2-act" style={{ flex: '0 0 auto' }} onPointerEnter={() => play('ui.hover')}>
              <Button style={actionStyle(GOLD_INK)} onClick={() => { play('ui.select'); onReplace(it) }}>
                <span className="font-display uppercase" style={{ ...ONE_LINE, letterSpacing: '0.12em', fontWeight: 400 }}>
                  {BTN.replace}
                </span>
              </Button>
            </span>
          </div>
        ))}
      </div>
    </IslandModal>
  )
}
