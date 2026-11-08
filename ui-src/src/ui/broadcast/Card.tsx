import type { ReactNode } from 'react'
import { Fit } from './deps'
import { Plate } from './Plate'
import { vars } from './util'

/**
 * CARD (#431): a store or locker item. Its ONE edge says the most important
 * true thing about it: equipped (cyan) outranks owned (hp), which outranks
 * rarity -- with the rarity pips in the colorblind modes, a rarity you can
 * count. An art well with a monogram fallback (never a broken image), a
 * one-line name (text size reaches it), a sub caption, and one action. Never
 * is-active: a card is not a control.
 *
 *   shape 'slant'   Broadcast: the well upright, its top rule in the edge
 *                   color, then a slanted name plate with the edge as its slab
 *         'square'  today's Market: a square plate edged in the edge color
 *                   (the owner: keep them cut where they are today)
 */
export function Card({ name, sub, rarity = 1, owned = false, equipped = false, art, action, shape = 'slant' }: {
  /** Data: the item's name. */
  name: string
  /** Data: its kind's caption. */
  sub?: string
  rarity?: 1 | 2 | 3 | 4 | 5
  owned?: boolean
  equipped?: boolean
  /** The artwork (an <img> that falls back on its own); default the monogram. */
  art?: ReactNode
  /** One CardAction (or an Equipped mark). */
  action?: ReactNode
  shape?: 'slant' | 'square'
}) {
  const edge = equipped ? 'var(--bc-accent)' : owned ? 'var(--bc-hp)' : `var(--bc-rarity-${rarity})`
  const tint = `var(--bc-rarity-${rarity})`
  const well = (
    <div className="bc-card__well">
      {art ?? <span className="bc-card__mono">{name.slice(0, 2).toUpperCase()}</span>}
    </div>
  )
  const pips = (
    <span className="rarity-pips" style={{ color: tint }} aria-hidden>
      {Array.from({ length: rarity }, (_, i) => <i key={i} />)}
    </span>
  )
  const nameEl = (
    <Fit className="bc-card__name ts" style={vars({ '--fs': 'var(--bc-fs-card-name)' })}>{name}</Fit>
  )
  const subEl = (
    <span className="bc-card__sub">
      {sub !== undefined && <Fit className="micro-label">{sub}</Fit>}
      {pips}
    </span>
  )
  const style = vars({ '--bc-card-edge': edge, '--bc-card-mono': tint })

  if (shape === 'square') {
    return (
      <div className="bc-card bc-card--square" style={style}>
        {well}
        <div className="bc-card__text">{nameEl}{subEl}</div>
        {action}
      </div>
    )
  }
  return (
    <div className="bc-card bc-card--slant" style={style}>
      {well}
      <Plate variant="deck" edge={edge} height={2.6}>
        <Plate.Line cy={0.82} ch={0.42} lh={1.1}>{nameEl}</Plate.Line>
        <Plate.Line cy={1.86} ch={0.3} lh={0.8}>{subEl}</Plate.Line>
      </Plate>
      {action}
    </div>
  )
}

/** As many columns as fit at 9.5 kit units, four at most. */
export function CardGrid({ children }: { children: ReactNode }) {
  return <div className="bc-cardgrid">{children}</div>
}
