import { useState } from 'react'
import { useUi } from '../store'
import { fetchNui } from '../bridge/nui'
import { CB } from '../bridge/types'
import type { MarketItem } from '../bridge/types'
import Btn from '../ui/Btn'
import { play } from '../audio/cues'

/**
 * The market.
 *
 * NOTHING IN HERE MAY CHANGE HOW A FIGHT GOES. That is the one rule, and it is
 * not a style preference -- a battle royale that sells advantage stops being a
 * test of skill, and every item below is chosen so that a player who has
 * bought everything and a player who has bought nothing arrive at the same
 * gunfight equal.
 *
 * WHAT IS ON SALE, and why each is safe:
 *
 *   CHARACTERS   the locker roster, extended. Pure silhouette. The one thing
 *                to watch: hitboxes are per-BONE in this game (M6 validates
 *                damage from bone components server-side), so a smaller model
 *                is not a smaller target -- but a model that is visually
 *                harder to see in foliage WOULD be an advantage, which is why
 *                the roster is curated rather than "every ped in GTA".
 *   TRAILS       the parachute smoke colour, which the squad system already
 *                draws. Announces your position, if anything.
 *   BANNERS      the card shown beside your name in the kill feed and on the
 *                verdict screen. Seen by other people, never by you mid-fight.
 *   VERDICTS     the words that slam on a Victory Royale. A trophy.
 *   SPRAYS       an emote/tag. Costs the player a second of standing still,
 *                which is a mild DISADVANTAGE, which is the correct direction.
 *
 * AND WHAT IS DELIBERATELY NOT: weapon skins that change a silhouette in a
 * scope, tracer colours, anything that alters a hitbox, and anything at all
 * that could be read as pay-to-win by somebody who just lost a fight.
 *
 * THE CURRENCY IS EARNED, NEVER BOUGHT. It has to be, or the paragraph above
 * is decoration. See the notes on the issue.
 *
 * SYNTHETIC UNTIL THERE IS A SERVER. Like Progress, this is the interface for
 * a system nobody has written yet: it renders whatever Lua sends and the
 * browser harness seeds a plausible catalogue. Purchases go through a callback
 * that currently does nothing.
 */

const TABS: { id: MarketItem['kind']; label: string }[] = [
  { id: 'character', label: 'Characters' },
  { id: 'trail',     label: 'Trails' },
  { id: 'banner',    label: 'Banners' },
  { id: 'verdict',   label: 'Verdicts' },
]

export default function Market() {
  const market = useUi((s) => s.market)
  const [tab, setTab] = useState<MarketItem['kind']>('character')

  const close = () => { void fetchNui(CB.MARKET_FOCUS, { open: false }) }
  const items = market.items.filter((i) => i.kind === tab)

  return (
    <div
      className="interactive fixed inset-0 z-50 overflow-y-auto thin-scroll"
      style={{ backgroundColor: 'rgba(8, 9, 14, 0.985)' }}
    >
      <div className="mx-auto py-10" style={{ width: '68rem', maxWidth: '92vw' }}>
        <div className="flex items-end justify-between mb-8">
          <div>
            <div className="micro-label">Market</div>
            <h2 className="font-display text-[3rem] uppercase tracking-[0.1em] leading-none mt-1">
              Store
            </h2>
          </div>
          {/* THE BALANCE IS THE FIRST THING ON SCREEN AFTER THE TITLE. A shop
              that makes you hunt for what you can afford is a shop that makes
              every price meaningless. */}
          <div
            className="plate px-4 py-2.5 flex items-baseline gap-2"
            style={{
              ['--edgec' as string]: 'var(--color-royale-accent2)',
              ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
              ['--cut-max' as string]: '0.45rem',
            }}
          >
            <span
              className="font-display text-[1.5rem] tabular-nums leading-none"
              style={{ color: 'var(--color-royale-accent2)' }}
            >
              {market.balance.toLocaleString()}
            </span>
            <span className="micro-label">credits</span>
          </div>
        </div>

        <div className="flex gap-2 mb-6">
          {TABS.map((t) => (
            <button
              key={t.id}
              type="button"
              className={`btn plate px-4 py-2 font-display uppercase tracking-[0.12em]
                          text-[0.8rem]${tab === t.id ? ' is-active' : ''}`}
              style={{
                ['--edgec' as string]: tab === t.id
                  ? 'var(--color-royale-accent)' : 'rgba(255,255,255,0.16)',
                ['--plate-fill' as string]: tab === t.id
                  ? 'rgba(12,58,72,0.94)' : 'rgba(24,28,40,0.92)',
                ['--cut-max' as string]: '0.45rem',
              }}
              onPointerEnter={() => play('ui.hover')}
              onClick={() => { play('ui.select'); setTab(t.id) }}
            >
              {t.label}
            </button>
          ))}
        </div>

        {items.length === 0 ? (
          <p className="micro-label">Nothing here yet.</p>
        ) : (
          <div className="grid grid-cols-4 gap-3">
            {items.map((it) => (
              <Card key={it.id} item={it} balance={market.balance} />
            ))}
          </div>
        )}

        <div className="mt-8">
          <Btn variant="primary" size="lg" cue="ui.back" onPress={close}>
            Done
          </Btn>
        </div>
      </div>
    </div>
  )
}

function Card({ item, balance }: { item: MarketItem; balance: number }) {
  const owned = item.owned === true
  const afford = balance >= item.price

  return (
    <div
      className="plate p-3 flex flex-col gap-2"
      style={{
        ['--edgec' as string]: owned
          ? 'var(--color-hp)' : `var(--rarity-${item.rarity ?? 1})`,
        ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
        ['--cut-max' as string]: '0.6rem',
        minHeight: '10rem',
      }}
    >
      {/* NO ARTWORK, AND THAT IS AN HONEST GAP rather than a placeholder: this
          project is vanilla-assets-only, so there is no image set to draw a
          storefront from. A character is previewed by BUYING it and looking at
          it in the locker, which is the same argument that screen makes. When
          there is art, it goes here. */}
      <div
        className="flex-1 flex items-center justify-center rounded-sm"
        style={{ background: 'rgba(0,0,0,0.35)' }}
      >
        <span
          className="font-display text-[1.6rem] opacity-40"
          style={{ color: `var(--rarity-${item.rarity ?? 1})` }}
        >
          {item.name.slice(0, 2).toUpperCase()}
        </span>
      </div>

      <div>
        <div className="text-[0.88rem] tscale leading-tight">{item.name}</div>
        {item.sub && <div className="micro-label mt-0.5">{item.sub}</div>}
      </div>

      {owned ? (
        <div
          className="text-[0.72rem] font-display uppercase tracking-[0.14em] text-center py-1"
          style={{ color: 'var(--color-hp)' }}
        >
          Owned
        </div>
      ) : (
        <button
          type="button"
          disabled={!afford}
          className={`btn plate w-full py-1.5 font-display uppercase tracking-[0.12em]
                      text-[0.75rem]${afford ? '' : ' btn--off'}`}
          style={{
            ['--edgec' as string]: afford
              ? 'var(--color-royale-accent2)' : 'rgba(255,255,255,0.16)',
            ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
            ['--cut-max' as string]: '0.35rem',
            color: afford ? 'var(--color-royale-accent2)' : 'rgba(255,255,255,0.35)',
          }}
          onPointerEnter={() => { if (afford) play('ui.hover') }}
          onClick={() => {
            if (!afford) { play('ui.error'); return }
            play('ui.select')
            void fetchNui(CB.MARKET_BUY, { id: item.id })
          }}
        >
          {item.price.toLocaleString()}
        </button>
      )}
    </div>
  )
}
