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
 *   TRAILS       the parachute smoke colour. Announces your position, if
 *                anything.
 *   FINISHES     the weapon tint.
 *   BANNERS      the card shown beside your name in the kill feed and on the
 *                verdict screen. Seen by other people, never by you mid-fight.
 *   VERDICTS     the words that slam on a Victory Royale. A trophy.
 *   SPRAYS       an emote/tag. Costs the player a second of standing still,
 *                which is a mild DISADVANTAGE, which is the correct direction.
 *   EMOTES       the dances on the Left Alt wheel (#215). Same direction as a
 *                spray, more so: a dance ends the moment you move or aim, so
 *                it is only ever done by somebody not fighting.
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

/**
 * THE DANCES' TAB (#215, "Scope v2"), and it is not in TABS on purpose. It
 * exists only while the owner's one config line says so -- "Everything is
 * devMode-required behind one config line" (owner, 2026-10-02) -- and Lua says
 * so through the `emotes` envelope. With the gate closed there is no tab to
 * click, and tools/check_emote_gate.lua fails the build if 'emote' ever lands
 * in TABS itself.
 */
const EMOTE_TAB = { id: 'emote' as const, label: 'Emotes' }

/** "Up to 8 equipped" (owner, 2026-10-02): the wheel's segments. */
const WHEEL_SLOTS = 8

export default function Market() {
  const market = useUi((s) => s.market)
  const emotesOn = useUi((s) => s.emotesOn)
  const [tab, setTab] = useState<MarketItem['kind']>('chute')
  // A full wheel's Equip picks the dance to bring in; the next press, on a
  // dance already on the wheel, names the one it replaces (#215).
  const [swapFor, setSwapFor] = useState<string | null>(null)

  const tabs = emotesOn ? [...TABS, EMOTE_TAB] : TABS

  // THE GATE CAN CLOSE WITH THE TAB OPEN (a dev box turning dev mode off), and
  // a tab that no longer exists must not stay selected over an empty grid.
  useEffect(() => { if (!emotesOn && tab === 'emote') setTab('chute') }, [emotesOn, tab])
  useEffect(() => { if (!emotesOn) setSwapFor(null) }, [emotesOn])

  const close = () => { void fetchNui(CB.MARKET_FOCUS, { open: false }) }
  const items = market.items.filter((i) => i.kind === tab)
  const onWheel = market.items.filter((i) => i.kind === 'emote' && typeof i.slot === 'number').length
  const wheelFull = onWheel >= WHEEL_SLOTS

  // A PENDING SWAP THE GRID HAS OVERTAKEN IS DROPPED (#215). A new state can
  // land between the two presses (a grant, a buy, a reconnect): once the dance
  // waiting to come in is on the wheel, or no longer owned, or the wheel has a
  // free segment again, every "Replace" it would draw is a press that no
  // longer means what it says.
  const pending = swapFor === null ? null : market.items.find((i) => i.id === swapFor)
  const swapStale = swapFor !== null
    && (!wheelFull || !pending || pending.owned !== true || typeof pending.slot === 'number')
  useEffect(() => { if (swapStale) setSwapFor(null) }, [swapStale])

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
          {tabs.map((t) => (
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
              onClick={() => { play('ui.select'); setTab(t.id); setSwapFor(null) }}
            >
              {t.label}
            </button>
          ))}
        </div>

        {/* HOW FULL THE WHEEL IS (#215), on the dances' tab only. Eight fit,
            owning more is fine, and the ninth goes on by replacing one. */}
        {tab === 'emote' && (
          <div
            className="plate px-4 py-2 mb-4 flex items-baseline gap-3 self-start"
            style={{
              ['--edgec' as string]: wheelFull
                ? 'var(--color-royale-accent2)' : 'rgba(255,255,255,0.16)',
              ['--plate-fill' as string]: 'rgba(24,28,40,0.94)',
              ['--cut-max' as string]: '0.45rem',
            }}
          >
            <span className="micro-label">On wheel</span>
            <span className="font-display text-[1.1rem] tabular-nums leading-none">
              {`${onWheel} / ${WHEEL_SLOTS}`}
            </span>
          </div>
        )}

        {/* THE ONLY SCROLLING REGION. min-h-0 is load-bearing: a flex child
            defaults to min-height:auto and refuses to shrink below its content,
            so without it this grows past the viewport and takes Done with it. */}
        {/* THE TRAILS TAB HAD AN EXPLAINER BOX ABOVE ITS GRID AND IT IS GONE
            (owner, 2026-08-20: "Please remove the explainer box at the top of
            the trails page in Market"). It was three paragraphs on how a trail
            lights itself, which key toggles it, and what Squad Colour was for --
            written across #131's several lives, and never asked for. Nothing
            replaces it: the descent already names the key on screen, at the
            moment the key is worth pressing. */}
        <div className="min-h-0 flex-1 overflow-y-auto thin-scroll pr-1">
          {items.length === 0 ? (
            <p className="body-text">Nothing here yet.</p>
          ) : (
            <div className="grid grid-cols-4 gap-3 pb-2">
              {items.map((it) => (
                <Card
                  key={it.id} item={it} balance={market.balance}
                  swapFor={swapFor} setSwapFor={setSwapFor} wheelFull={wheelFull}
                />
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

interface CardProps {
  item: MarketItem
  balance: number
  /** EMOTES ONLY (#215): the dance waiting to replace one on a full wheel. */
  swapFor: string | null
  setSwapFor: (id: string | null) => void
  wheelFull: boolean
}

/** The plate-button look every card action shares, in one edge colour. */
function actionStyle(color: string) {
  return {
    ['--edgec' as string]: color,
    ['--plate-fill' as string]: 'rgba(30,34,48,0.94)',
    ['--cut-max' as string]: '0.35rem',
    color,
  }
}

/**
 * A dance's action (#215), or null when it has none of its own and the card's
 * ordinary price / closed-season line applies.
 *
 * EQUIPPED IS A BUTTON HERE, AND THAT IS THE RULE BELOW BROKEN ON PURPOSE.
 * Every other kind has one slot and a default to fall back to, so "Equipped" is
 * a fact. A dance is one of eight, and the owner asked for the hand on it:
 * "The market manages them: equip, unequip, and swap one for another when more
 * than 8 are owned" (owner, 2026-10-02). Every button still does something.
 */
function emoteAction(
  item: MarketItem, swapFor: string | null,
  setSwapFor: (id: string | null) => void, wheelFull: boolean,
) {
  const owned = item.owned === true
  const equipped = item.equipped === true
  const press = (fn: () => void) => () => { play('ui.select'); fn() }

  if (equipped && swapFor !== null && swapFor !== item.id) {
    return (
      <button
        type="button" className="btn plate w-full py-1.5 font-display uppercase tracking-[0.12em] text-[0.75rem]"
        style={actionStyle('var(--color-royale-accent2)')}
        onPointerEnter={() => play('ui.hover')}
        onClick={press(() => {
          void fetchNui(CB.MARKET_EQUIP, { id: swapFor, replace: item.id })
          setSwapFor(null)
        })}
      >
        Replace
      </button>
    )
  }
  if (equipped) {
    return (
      <button
        type="button" className="btn plate w-full py-1.5 font-display uppercase tracking-[0.12em] text-[0.75rem]"
        style={actionStyle('var(--color-royale-accent)')}
        onPointerEnter={() => play('ui.hover')}
        onClick={press(() => { void fetchNui(CB.MARKET_UNEQUIP, { id: item.id }) })}
      >
        Unequip
      </button>
    )
  }
  if (owned && swapFor === item.id) {
    return (
      <button
        type="button" className="btn plate is-active w-full py-1.5 font-display uppercase tracking-[0.12em] text-[0.75rem]"
        style={actionStyle('rgba(255,255,255,0.6)')}
        onPointerEnter={() => play('ui.hover')}
        onClick={press(() => setSwapFor(null))}
      >
        Cancel
      </button>
    )
  }
  if (owned) {
    return (
      <button
        type="button" className="btn plate w-full py-1.5 font-display uppercase tracking-[0.12em] text-[0.75rem]"
        style={actionStyle('var(--color-hp)')}
        onPointerEnter={() => play('ui.hover')}
        onClick={press(() => {
          if (wheelFull) setSwapFor(item.id)
          else void fetchNui(CB.MARKET_EQUIP, { id: item.id })
        })}
      >
        Equip
      </button>
    )
  }
  return null
}

function Card({ item, balance, swapFor, setSwapFor, wheelFull }: CardProps) {
  const owned = item.owned === true
  const equipped = item.equipped === true
  const afford = balance >= item.price
  const dance = item.kind === 'emote' ? emoteAction(item, swapFor, setSwapFor, wheelFull) : null

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
          broken rather than that they had already done the thing.
          A DANCE IS THE EXCEPTION (#215): see emoteAction. */}
      {dance ? dance : equipped ? (
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
