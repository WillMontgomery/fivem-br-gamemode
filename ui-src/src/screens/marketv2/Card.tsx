import { useState, type ReactNode } from 'react'
import Box from '@cloudscape-design/components/box'
import Button from '@cloudscape-design/components/button'
import type { MarketItem } from '../../bridge/types'
import { play } from '../../audio/cues'
import { BTN, EQUIPPED, NOT_FOR_SALE, amount, closedLabel } from './copy'
import { ONE_LINE, actionColor, actionStyle, cardPlate, edgeColor, previewStyle } from './look'
import { artUrl, canPreview, cardAction, edgeOf, hasArt, monogram, type CardAction } from './model'

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

/** The lobby's button voice inside a Cloudscape button: Anton, upper case,
 *  and never on two lines. */
function Label({ children }: { children: ReactNode }) {
  return (
    <span className="font-display uppercase" style={{ ...ONE_LINE, letterSpacing: '0.12em', fontWeight: 400 }}>
      {children}
    </span>
  )
}

export interface CardHandlers {
  /** A price pressed: model.ts buyPress decides, and the confirm opens. */
  onPrice: (item: MarketItem) => void
  onEquip: (item: MarketItem) => void
  onUnequip: (item: MarketItem) => void
  /** Equip on a full wheel: the replace dialog, for this dance (#411). */
  onSwap: (item: MarketItem) => void
  /** Preview pressed: this dance on the lobby character, or off again. */
  onPreview: (item: MarketItem) => void
}

/** One action's control. Hover and press speak, as every lobby button does. */
function Action({ a, item, h }: { a: CardAction; item: MarketItem; h: CardHandlers }) {
  const color = actionColor(a)
  if (a.do === 'equipped') {
    return (
      <div className="font-display uppercase" style={{ ...ONE_LINE, textAlign: 'center', letterSpacing: '0.14em', fontSize: '0.8em', padding: '0.35em 0', color }}>
        {EQUIPPED}
      </div>
    )
  }
  if (a.do === 'closed') {
    return (
      <div style={{ ...ONE_LINE, textAlign: 'center', padding: '0.35em 0', opacity: 0.55 }}>
        <Box variant="small" color="text-body-secondary">{a.season !== null ? closedLabel(a.season) : NOT_FOR_SALE}</Box>
      </div>
    )
  }

  let label: ReactNode
  let press: () => void
  switch (a.do) {
    case 'buy':
      label = <span className="font-display tabular-nums">{amount(item.price)}</span>
      press = () => h.onPrice(item)
      break
    case 'unequip': label = BTN.unequip; press = () => { play('ui.select'); h.onUnequip(item) }; break
    case 'equipDance':
      label = BTN.equip
      press = () => { play('ui.select'); if (a.swap) h.onSwap(item); else h.onEquip(item) }
      break
    default:
      label = BTN.equip
      press = () => { play('ui.select'); h.onEquip(item) }
      break
  }
  // HOVER AND PRESS, AS EVERY LOBBY BUTTON (index.css `.btn`, check-ui R3):
  // it brightens, travels and speaks (`mk2-act`, market.css). A price the
  // balance cannot cover does none of it, as Season 1's `btn--off`.
  const quiet = a.do === 'buy' && !a.afford
  return (
    <span className={quiet ? undefined : 'mk2-act'} style={{ display: 'block' }} onPointerEnter={() => { if (!quiet) play('ui.hover') }}>
      <Button fullWidth style={actionStyle(color)} onClick={press}><Label>{label}</Label></Button>
    </span>
  )
}

/**
 * PREVIEW (#411): the lobby character plays this dance, silently, while the
 * Market is open. Pressed again it stops. Spent -- disabled, still and silent
 * -- on a dance the player neither owns nor can afford (model.ts canPreview),
 * which br_ui's Lua refuses as well.
 */
function Preview({ item, balance, playing, h }: {
  item: MarketItem; balance: number; playing: boolean; h: CardHandlers
}) {
  const able = canPreview(item, balance)
  return (
    <span className={able ? 'mk2-act' : undefined} style={{ display: 'block' }} onPointerEnter={() => { if (able) play('ui.hover') }}>
      <Button
        fullWidth
        disabled={!able}
        style={previewStyle(playing)}
        onClick={() => { play('ui.select'); h.onPreview(item) }}
      >
        <Label>{BTN.preview}</Label>
      </Button>
    </span>
  )
}

export function Card({ item, balance, wheelFull, previewing, h }: {
  item: MarketItem
  balance: number
  wheelFull: boolean
  /** The dance on the lobby character now, or null. */
  previewing: string | null
  h: CardHandlers
}) {
  const a = cardAction(item, balance, wheelFull)
  const art = hasArt(item)
  return (
    <div
      // SQUARE: a card is a plate at rest, never `is-active` (#411's corners).
      className="plate"
      data-mk2-card={item.id}
      style={{
        ...cardPlate(edgeColor(edgeOf(item), item.rarity)),
        padding: '0.75em', display: 'flex', flexDirection: 'column', gap: '0.5em', minWidth: 0,
        minHeight: art ? '11em' : undefined,
      }}
    >
      {/* "emotes shouldn't really have a thumbnail" (owner, 2026-10-14): a
          dance's card is its name, Preview and its action. */}
      {art && (
        <div style={{ flex: '1 1 auto', minHeight: '5em', display: 'flex' }}>
          <Art item={item} />
        </div>
      )}
      <div style={{ minWidth: 0 }}>
        <div className="tscale" style={{ ...ONE_LINE, lineHeight: 1.2 }}>{item.name}</div>
        {item.sub && <div style={ONE_LINE}><Box variant="small" color="text-body-secondary">{item.sub}</Box></div>}
      </div>
      {item.kind === 'emote' && <Preview item={item} balance={balance} playing={previewing === item.id} h={h} />}
      <Action a={a} item={item} h={h} />
    </div>
  )
}
