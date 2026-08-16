import { useEffect, useState } from 'react'
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
 *   CANOPIES     the parachute design. Seen for ninety seconds at the start of
 *                a match, by everybody, which is exactly why they sell.
 *   TRAILS       the parachute smoke colour, which the squad system already
 *                draws. Announces your position, if anything.
 *   FINISHES     the weapon tint.
 *   BANNERS      the card shown beside your name in the kill feed and on the
 *                verdict screen. Seen by other people, never by you mid-fight.
 *   VERDICTS     the words that slam on a Victory Royale. A trophy.
 *   SPRAYS       an emote/tag. Costs the player a second of standing still,
 *                which is a mild DISADVANTAGE, which is the correct direction.
 *
 * AND WHAT IS DELIBERATELY NOT: tracer colours, anything that alters a hitbox,
 * and anything at all that could be read as pay-to-win by somebody who just
 * lost a fight.
 *
 * WEAPON FINISHES USED TO BE ON THAT LIST, and this comment is the record of
 * the reversal rather than a quiet edit. The exclusion said "weapon skins that
 * change a silhouette in a scope" -- and that reasoning is sound, which is why
 * it still bars anything that changes a silhouette. A tint does not: it is a
 * texture swap on untouched geometry, so two players with different finishes
 * present the same target from every angle. The one directional worry, that
 * gold and platinum are brighter and therefore easier to see, points at a
 * self-disadvantage -- the correct direction for anything sold.
 *
 * THE CURRENCY IS EARNED, NEVER BOUGHT. It has to be, or the paragraph above
 * is decoration -- and it is now a property rather than a promise: exactly one
 * writer can increase a balance, and it is the end-of-match stats write.
 *
 * NO LONGER SYNTHETIC. Balance, ownership and equipped state all come from the
 * server, and nothing on this page is written optimistically: a purchase asks,
 * the server writes conditionally, and the answer arrives as a whole new state.
 * The page can lag by one round trip. It cannot claim you own something the
 * database refused.
 */

const TABS: { id: MarketItem['kind']; label: string }[] = [
  { id: 'chute',     label: 'Canopies' },
  { id: 'trail',     label: 'Trails' },
  { id: 'weapon',    label: 'Finishes' },
  { id: 'character', label: 'Characters' },
  { id: 'banner',    label: 'Banners' },
  // VERDICTS ARE NOT FOR SALE (owner, 2026-08-12). The words that slam on a
  // Victory Royale are the reward for winning, and selling them makes the
  // trophy purchasable — which is the one thing this catalogue's rule about
  // not selling advantage was written to protect against in spirit.
]

export default function Market() {
  const market = useUi((s) => s.market)
  const [tab, setTab] = useState<MarketItem['kind']>('chute')

  const close = () => { void fetchNui(CB.MARKET_FOCUS, { open: false }) }
  const items = market.items.filter((i) => i.kind === tab)

  // Escape closes, the same as the locker and the settings screen. This page
  // shipped without it and was the only lobby screen you could not back out
  // of with the key everybody tries first (user, 2026-08-09).
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== 'Escape') return
      e.preventDefault()
      e.stopPropagation()
      play('ui.back')
      close()
    }
    window.addEventListener('keydown', onKey, true)
    return () => window.removeEventListener('keydown', onKey, true)
  })

  return (
    <div
      // A COLUMN THAT FILLS THE VIEWPORT, not a page that scrolls as a whole.
      // The grid is the only thing that scrolls; the title, the balance, the
      // tabs and Done all stay put. Scrolling the whole page pushed Done below
      // the fold the moment a season had more than a dozen items -- so the way
      // out of the screen moved depending on how much was for sale.
      className="interactive fixed inset-0 z-50 flex flex-col"
      style={{ backgroundColor: 'rgba(8, 9, 14, 0.985)' }}
    >
      <div
        className="mx-auto flex min-h-0 flex-1 flex-col pt-10"
        style={{ width: '68rem', maxWidth: '92vw' }}
      >
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
            <span className="micro-label">{market.currency ?? 'volts'}</span>
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

        {/* THE ONLY SCROLLING REGION. min-h-0 is load-bearing: a flex child
            defaults to min-height:auto and refuses to shrink below its content,
            so without it this grows past the viewport and takes Done with it. */}
        <div className="min-h-0 flex-1 overflow-y-auto thin-scroll pr-1">
          {/* Inside the scroller on purpose: it belongs to the trail grid, and
              pinning it above would cost every other tab the vertical space. */}
          {tab === 'trail' && <TrailHelp />}
          {items.length === 0 ? (
            <p className="micro-label">Nothing here yet.</p>
          ) : (
            <div className="grid grid-cols-4 gap-3 pb-2">
              {items.map((it) => (
                <Card key={it.id} item={it} balance={market.balance} />
              ))}
            </div>
          )}
        </div>

        <div className="shrink-0 py-6">
          <Btn variant="primary" size="lg" cue="ui.back" onPress={close}>
            Done
          </Btn>
        </div>
      </div>
    </div>
  )
}

/**
 * What a trail actually does, said where trails are bought.
 *
 * THERE IS NO KEY, AND THAT IS THE WHOLE ANSWER (#131). The report was "it is
 * unclear how to use them -- show me the keybind", and the honest reply is that
 * there is no keybind to show: a trail is not an ability. skydive.lua sets the
 * colour once per drop, in the window between the parachute model override and
 * TaskParachute, and clears it again on landing. Nothing anywhere in that path
 * reads an input. Help text naming a key would have been a lie that takes a
 * whole match to catch, and this project has shipped enough of those.
 *
 * SO THE COPY LEADS WITH THE ABSENCE. "No key needed" is the sentence that
 * stops the player hunting for a button; everything after it is detail. The
 * alternative -- inventing a deploy-the-trail bind to satisfy the request --
 * would have added an input to a cosmetic purely so the help text had something
 * to name.
 *
 * THE ONE KEY NAMED IS A CLOCK, NOT A TRIGGER. "Which key" is really "when does
 * this happen", and the answer is "from the jump", so the jump key is named --
 * carefully, as the start of the drop rather than as something that emits
 * smoke. It also gives the rebinding advice something true to point at, which
 * is what the issue actually asks to be able to check.
 *
 * AND IT COMES FROM THE LIVE BINDING, never a hard-coded 'SPACE'. Keys are
 * rebindable from Settings > Controls, and the raw layer can hold a different
 * default from the engine's -- so a literal letter here would be wrong for
 * exactly the player who cared enough to change it. That is the bug that had
 * every world prompt still saying E long after interact moved to R.
 *
 * THE SQUAD LINE IS NOT A FOOTNOTE. A bought trail loses to the squad colour by
 * design, because finding your squadmate's smoke is a gameplay read and the
 * purchase is decoration (br_lib/config/market.lua argues this at length). The
 * consequence is that a player who buys Void and drops with a squad sees the
 * squad colour and concludes the item is broken -- the same "it does not work"
 * this issue is about, arriving one step later. Saying it here is cheaper than
 * answering it again.
 */
function TrailHelp() {
  // The drop key, from the table Lua pushes on br:ui:ready. Two absences are
  // possible and they are different: the envelope has not arrived yet (no row
  // at all), or the player has deliberately cleared the binding (a row with an
  // empty key). Neither may render as a gap in the middle of a sentence.
  const deploy = useUi((s) => s.keybinds.find((k) => k.command === 'brdeploy'))

  return (
    <div
      className="plate px-4 py-3 mb-3 flex flex-col gap-1.5"
      style={{
        ['--edgec' as string]: 'var(--color-royale-accent)',
        ['--plate-fill' as string]: 'rgba(12,40,50,0.94)',
        ['--cut-max' as string]: '0.5rem',
      }}
    >
      <div className="micro-label">No key needed</div>
      <p className="ts" style={{ ['--fs' as string]: '0.85rem', lineHeight: 1.5 }}>
        Your trail is automatic. It starts when you jump from the bus and burns
        until you land — there is nothing to press in the air.
      </p>
      {deploy && (
        <p className="ts" style={{ ['--fs' as string]: '0.85rem', lineHeight: 1.5 }}>
          The jump itself is your{' '}
          <span className="font-semibold">{deploy.label}</span> key, currently{' '}
          <span className="font-semibold">{deploy.key || 'not bound'}</span>. Change
          it in the pause menu under{' '}
          <span className="font-semibold">Settings › Controls</span>.
        </p>
      )}
      <p
        className="ts"
        style={{ ['--fs' as string]: '0.85rem', lineHeight: 1.5, opacity: 0.75 }}
      >
        In a squad your squad&apos;s colour replaces it, so your team can find each
        other in the air. Your own trail shows when you drop solo.
      </p>
    </div>
  )
}

function Card({ item, balance }: { item: MarketItem; balance: number }) {
  const owned = item.owned === true
  const equipped = item.equipped === true
  const afford = balance >= item.price

  // ARTWORK IS OPTIONAL AND ITS ABSENCE IS NOT A BROKEN IMAGE. Same convention
  // as public/items: a PNG named after the item id, copied verbatim by Vite.
  // A missing file falls back to the monogram below rather than to the little
  // torn-page icon, so the set can be filled in a few at a time.
  const [art, setArt] = useState(true)

  // The edge colour says the most important true thing about the card, and
  // there is only one edge: equipped outranks owned, which outranks rarity.
  const edge = equipped
    ? 'var(--color-royale-accent)'
    : owned
      ? 'var(--color-hp)'
      : `var(--rarity-${item.rarity ?? 1})`

  return (
    <div
      className="plate p-3 flex flex-col gap-2"
      style={{
        ['--edgec' as string]: edge,
        ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
        ['--cut-max' as string]: '0.6rem',
        minHeight: '10rem',
      }}
    >
      <div
        className="flex-1 flex items-center justify-center rounded-sm overflow-hidden"
        style={{ background: 'rgba(0,0,0,0.35)' }}
      >
        {art ? (
          <img
            src={`market/${item.id}.png`}
            alt=""
            className="w-full h-full"
            style={{ objectFit: 'contain' }}
            onError={() => setArt(false)}
          />
        ) : (
          <span
            className="font-display text-[1.6rem] opacity-40"
            style={{ color: `var(--rarity-${item.rarity ?? 1})` }}
          >
            {item.name.slice(0, 2).toUpperCase()}
          </span>
        )}
      </div>

      <div>
        <div className="text-[0.88rem] tscale leading-tight">{item.name}</div>
        {item.sub && <div className="micro-label mt-0.5">{item.sub}</div>}
      </div>

      {/* THREE STATES, AND EQUIPPED IS NOT A BUTTON. A control that does
          nothing when pressed is worse than no control: the player presses it,
          nothing changes, and the reasonable conclusion is that the page is
          broken rather than that they had already done the thing. */}
      {equipped ? (
        <div
          className="text-[0.72rem] font-display uppercase tracking-[0.14em] text-center py-1"
          style={{ color: 'var(--color-royale-accent)' }}
        >
          Equipped
        </div>
      ) : owned ? (
        <button
          type="button"
          className="btn plate w-full py-1.5 font-display uppercase tracking-[0.12em] text-[0.75rem]"
          style={{
            ['--edgec' as string]: 'var(--color-hp)',
            ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
            ['--cut-max' as string]: '0.35rem',
            color: 'var(--color-hp)',
          }}
          onPointerEnter={() => play('ui.hover')}
          onClick={() => {
            play('ui.select')
            void fetchNui(CB.MARKET_EQUIP, { id: item.id })
          }}
        >
          Equip
        </button>
      ) : item.locked === true ? (
        // A closed season. Its owners still see it equipped and equippable;
        // everybody else sees why they cannot have it, which is more use than
        // hiding it and letting people wonder where it went.
        <div className="micro-label text-center py-1" style={{ opacity: 0.55 }}>
          {item.season ? `${item.season} — closed` : 'Not for sale'}
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
