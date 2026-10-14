import { useState, type ReactNode } from 'react'
import Badge from '@cloudscape-design/components/badge'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import type { MarketItem } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, EQUIPPED, NEW, NOT_FOR_SALE, closedLabel } from './copy'
import { actionColor, actionStyle, cardPlate, cutWrap, edgeColor, NEW_BADGE } from './look'
import { artUrl, cardAction, edgeOf, monogram, type CardAction } from './model'

/**
 * ARTWORK IS OPTIONAL AND ITS ABSENCE IS NOT A BROKEN IMAGE (Season 1's rule):
 * `market/<id>.png`, and the monogram in the rarity's color when there is none.
 */
export function Art({ item }: { item: MarketItem }) {
  const [art, setArt] = useState(true)
  return (
    <div
      style={{
        width: '100%', height: '100%', display: 'flex', alignItems: 'center', justifyContent: 'center',
        overflow: 'hidden', background: 'rgba(0, 0, 0, 0.35)',
      }}
    >
      {art ? (
        <img
          src={artUrl(item.id)}
          alt=""
          style={{ width: '100%', height: '100%', objectFit: 'contain' }}
          onError={() => setArt(false)}
        />
      ) : (
        <span
          className="font-display"
          style={{ fontSize: '1.6em', opacity: 0.4, color: `var(--rarity-${item.rarity ?? 1})` }}
        >
          {monogram(item.name)}
        </span>
      )}
    </div>
  )
}

/** The lobby's button voice inside a Cloudscape button: Anton, upper case. */
function Label({ children }: { children: ReactNode }) {
  return (
    <span className="font-display uppercase" style={{ letterSpacing: '0.12em', fontWeight: 400 }}>
      {children}
    </span>
  )
}

export interface CardHandlers {
  /** A price pressed: model.ts buyPress decides, and the confirm opens. */
  onPrice: (item: MarketItem) => void
  onEquip: (item: MarketItem) => void
  onUnequip: (item: MarketItem) => void
  /** Replace the dance on this card with the one waiting (#215). */
  onReplace: (item: MarketItem) => void
  /** The swap's first press on a full wheel, and its Cancel (null). */
  setSwapFor: (id: string | null) => void
}

/** One action's control. Hover and press speak, as every lobby button does. */
function Action({ a, item, h }: { a: CardAction; item: MarketItem; h: CardHandlers }) {
  const color = actionColor(a)
  if (a.do === 'equipped') {
    return (
      <div className="font-display uppercase" style={{ textAlign: 'center', letterSpacing: '0.14em', fontSize: '0.8em', padding: '0.35em 0', color }}>
        {EQUIPPED}
      </div>
    )
  }
  if (a.do === 'closed') {
    return (
      <div style={{ textAlign: 'center', padding: '0.35em 0', opacity: 0.55 }}>
        <Box variant="small" color="text-body-secondary">{a.season !== null ? closedLabel(a.season) : NOT_FOR_SALE}</Box>
      </div>
    )
  }

  let label: ReactNode
  let press: () => void
  switch (a.do) {
    case 'buy':
      label = <span className="font-display tabular-nums">{item.price.toLocaleString()}</span>
      press = () => h.onPrice(item)
      break
    case 'replace': label = BTN.replace; press = () => { play('ui.select'); h.onReplace(item) }; break
    case 'unequip': label = BTN.unequip; press = () => { play('ui.select'); h.onUnequip(item) }; break
    case 'cancel': label = BTN.cancelSwap; press = () => { play('ui.select'); h.setSwapFor(null) }; break
    case 'equipDance':
      label = BTN.equip
      press = () => { play('ui.select'); if (a.swap) h.setSwapFor(item.id); else h.onEquip(item) }
      break
    default:
      label = BTN.equip
      press = () => { play('ui.select'); h.onEquip(item) }
      break
  }
  const quiet = a.do === 'buy' && !a.afford
  const button = (
    <span style={{ display: 'block' }} onPointerEnter={() => { if (!quiet) play('ui.hover') }}>
      <Button fullWidth style={actionStyle(color)} onClick={press}><Label>{label}</Label></Button>
    </span>
  )
  // THE ONE CUT ON A CARD: the emote swap's Cancel, cut today (`plate is-active`).
  if (a.do === 'cancel') {
    return <span className="plate is-active" style={cutWrap(color)}>{button}</span>
  }
  return button
}

export function Card({ item, balance, swapFor, wheelFull, h }: {
  item: MarketItem
  balance: number
  swapFor: string | null
  wheelFull: boolean
  h: CardHandlers
}) {
  const a = cardAction(item, balance, swapFor, wheelFull)
  return (
    <div
      // SQUARE: a card is a plate at rest, never `is-active` (#411's corners).
      className="plate"
      style={{
        ...cardPlate(edgeColor(edgeOf(item), item.rarity)),
        padding: '0.75em', display: 'flex', flexDirection: 'column', gap: '0.5em', minHeight: '11em',
      }}
    >
      <div style={{ flex: '1 1 auto', minHeight: '5em', display: 'flex' }}>
        <Art item={item} />
      </div>
      <div>
        <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: '0.4em' }}>
          <span className="tscale" style={{ lineHeight: 1.2 }}>{item.name}</span>
          {item.isNew === true && <Badge style={NEW_BADGE}>{NEW}</Badge>}
        </div>
        {item.sub && <Box variant="small" color="text-body-secondary">{item.sub}</Box>}
      </div>
      <Action a={a} item={item} h={h} />
    </div>
  )
}
