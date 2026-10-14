/**
 * THE MARKET IN THE BROWSER HARNESS (#411): a stand-in for br_ui's
 * client/market.lua and br_core's server/market.lua, so both Markets can be
 * looked at in `npm run dev` with no game behind them.
 *
 * DEV ONLY, like the rest of bridge/mock.ts: production never imports it.
 *
 * THE GRID IS THE REAL ONE: the catalog below is what client/market.lua
 * sends, dumped from the Lua (br_lib/config/market.lua and config/emotes.lua)
 * on 2026-10-13, so the screen is laid out against real names, prices and
 * rarities. Season 2 (the default) is the Season 2 Market: `v2`, no
 * placeholder kinds, New on the dances, the Emotes tab on. `?season=1` is
 * Season 1's: its envelope as it always was, the placeholders, no dances.
 *
 * IT ANSWERS AS THE SERVER DOES: a buy, equip or unequip changes nothing until
 * a whole new grid arrives a moment later -- the page is never written to
 * optimistically, here or in game. A buy the server would refuse (already
 * owned, short, a placeholder, a closed season) answers with nothing new.
 *
 * The owned set starts with a full wheel and a ninth dance off it, so the swap
 * (Equip, then Replace or the cut Cancel) can be reached at once.
 */

import type { Envelope, MarketItem, MarketPayload } from './types'

type Emit = (env: Envelope) => void

interface Row {
  id: string; name: string; sub: string; kind: MarketItem['kind']; price: number
  rarity: NonNullable<MarketItem['rarity']>; season?: string; def?: boolean
}

const F = 'Founders'

/** client/market.lua's grid, dumped from the Lua, without ownership. */
const CATALOG: Row[] = [
  { id: 'chute_rainbow', name: 'Rainbow', sub: 'Canopy', kind: 'chute', price: 0, rarity: 1, season: F, def: true },
  { id: 'chute_crimson', name: 'Crimson', sub: 'Canopy', kind: 'chute', price: 1200, rarity: 2, season: F },
  { id: 'chute_seaside', name: 'Seaside', sub: 'Canopy', kind: 'chute', price: 1500, rarity: 2, season: F },
  { id: 'chute_azure', name: 'Azure', sub: 'Canopy', kind: 'chute', price: 2200, rarity: 3, season: F },
  { id: 'chute_widowmaker', name: 'Widowmaker', sub: 'Canopy', kind: 'chute', price: 2500, rarity: 3, season: F },
  { id: 'chute_patriot', name: 'Patriot', sub: 'Canopy', kind: 'chute', price: 2500, rarity: 3, season: F },
  { id: 'chute_midnight', name: 'Midnight', sub: 'Canopy', kind: 'chute', price: 4000, rarity: 4, season: F },
  { id: 'chute_hornet', name: 'Hornet', sub: 'Canopy', kind: 'chute', price: 6000, rarity: 5, season: F },
  { id: 'trail_ember', name: 'Ember', sub: 'Smoke trail', kind: 'trail', price: 400, rarity: 2, season: F },
  { id: 'trail_ice', name: 'Ice', sub: 'Smoke trail', kind: 'trail', price: 400, rarity: 2, season: F },
  { id: 'trail_toxic', name: 'Toxic', sub: 'Smoke trail', kind: 'trail', price: 700, rarity: 3, season: F },
  { id: 'trail_rose', name: 'Rose', sub: 'Smoke trail', kind: 'trail', price: 700, rarity: 3, season: F },
  { id: 'trail_void', name: 'Void', sub: 'Smoke trail', kind: 'trail', price: 1000, rarity: 4, season: F },
  { id: 'trail_patriot', name: 'Patriot', sub: 'Smoke trail', kind: 'trail', price: 1500, rarity: 5, season: F },
  { id: 'wtint_normal', name: 'Standard', sub: 'Weapon finish', kind: 'weapon', price: 0, rarity: 1, season: F, def: true },
  { id: 'wtint_green', name: 'Verde', sub: 'Weapon finish', kind: 'weapon', price: 900, rarity: 2, season: F },
  { id: 'wtint_army', name: 'Army', sub: 'Weapon finish', kind: 'weapon', price: 900, rarity: 2, season: F },
  { id: 'wtint_orange', name: 'Sunset', sub: 'Weapon finish', kind: 'weapon', price: 1400, rarity: 3, season: F },
  { id: 'wtint_lspd', name: 'Bluesteel', sub: 'Weapon finish', kind: 'weapon', price: 1400, rarity: 3, season: F },
  { id: 'wtint_pink', name: 'Fuchsia', sub: 'Weapon finish', kind: 'weapon', price: 2200, rarity: 4, season: F },
  { id: 'wtint_gold', name: 'Gold', sub: 'Weapon finish', kind: 'weapon', price: 5000, rarity: 5, season: F },
  { id: 'wtint_platinum', name: 'Platinum', sub: 'Weapon finish', kind: 'weapon', price: 6500, rarity: 5, season: F },
  { id: 'emote_club_podium', name: 'Podium', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_club_groove', name: 'Groove', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_club_drop', name: 'Drop', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_shuffle', name: 'Shuffle', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_techno_karate', name: 'Techno Karate', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_techno_monkey', name: 'Monkey', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_beach_boxing', name: 'Shadowbox', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_jumper', name: 'Jumper', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_sand_trip', name: 'Sand Trip', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_casino_sway', name: 'Casino Sway', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_casino_bounce', name: 'Casino Bounce', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_beach_party', name: 'Beach Party', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_beach_party_2', name: 'Beach Party II', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_island_club', name: 'Island Club', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_uncle_disco', name: 'Uncle Disco', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
  { id: 'emote_the_woogie', name: 'The Woogie', sub: 'Dance', kind: 'emote', price: 250, rarity: 1, season: F },
]

/** client/market.lua's SYNTHETIC rows: Season 1's alone, never for sale. */
const PLACEHOLDERS: MarketItem[] = [
  { id: 'ped_juggalo', name: 'Juggalo', sub: 'Character', kind: 'character', price: 1500, rarity: 2 },
  { id: 'ped_clown', name: 'Clown', sub: 'Character', kind: 'character', price: 2500, rarity: 3 },
  { id: 'ped_trooper', name: 'Trooper', sub: 'Character', kind: 'character', price: 4000, rarity: 4, owned: true },
  { id: 'ped_yeti', name: 'Yeti', sub: 'Character', kind: 'character', price: 9000, rarity: 5 },
  { id: 'ban_storm', name: 'Stormchaser', sub: 'Banner', kind: 'banner', price: 1200, rarity: 3 },
  { id: 'ban_first', name: 'Day One', sub: 'Banner', kind: 'banner', price: 0, rarity: 5, owned: true },
]

const DELAY_MS = 350

export function createMarketMock(emit: Emit) {
  const v2 = !/[?&]season=1\b/.test(window.location.search)
  const emotes = v2

  let balance = 7450
  const owned = new Set<string>([
    'chute_azure', 'trail_ember',
    'emote_club_podium', 'emote_club_groove', 'emote_club_drop', 'emote_shuffle', 'emote_techno_karate',
    'emote_techno_monkey', 'emote_beach_boxing', 'emote_jumper', 'emote_sand_trip',
  ])
  const equipped: Partial<Record<MarketItem['kind'], string>> = {
    chute: 'chute_azure', trail: 'trail_ember', weapon: 'wtint_normal',
  }
  /** Segment k -> dance; '' is an empty segment. */
  const wheel: string[] = [
    'emote_club_podium', 'emote_club_groove', 'emote_club_drop', 'emote_shuffle',
    'emote_techno_karate', 'emote_techno_monkey', 'emote_beach_boxing', 'emote_jumper',
  ]

  const row = (id: string) => CATALOG.find((r) => r.id === id)
  const owns = (r: Row) => r.def === true || owned.has(r.id)

  function payload(): MarketPayload {
    const items: MarketItem[] = []
    for (const r of CATALOG) {
      if (r.kind === 'emote') {
        if (!emotes) continue
        const k = wheel.indexOf(r.id)
        items.push({
          id: r.id, name: r.name, sub: r.sub, kind: r.kind, price: r.price, rarity: r.rarity, season: r.season,
          owned: owned.has(r.id), equipped: k >= 0, slot: k >= 0 ? k + 1 : undefined, locked: false,
          isNew: v2 ? true : undefined,
        })
      } else {
        items.push({
          id: r.id, name: r.name, sub: r.sub, kind: r.kind, price: r.price, rarity: r.rarity, season: r.season,
          owned: owns(r), equipped: equipped[r.kind] === r.id, locked: false,
        })
      }
    }
    if (!v2) items.push(...PLACEHOLDERS)
    return v2 ? { balance, currency: 'Volts', items, v2: true } : { balance, currency: 'Volts', items }
  }

  const push = () => {
    emit({ k: 'market', d: payload() })
    emit({ k: 'emotes', d: { on: emotes } })
  }
  const later = (fn: () => void) => window.setTimeout(() => { fn(); push() }, DELAY_MS)
  const free = () => wheel.indexOf('')

  return {
    push,
    /** A Market callback, answered as br_ui and the server would. */
    handle(name: string, data: unknown): boolean {
      const d = (data ?? {}) as { id?: string; replace?: string }
      const r = row(String(d.id ?? ''))
      if (name === 'br/market/buy') {
        later(() => {
          if (!r || owns(r) || r.price > balance || (r.kind === 'emote' && !emotes)) return
          owned.add(r.id)
          balance -= r.price
          // BOUGHT MEANS WORN; a dance goes on the wheel if there is room.
          if (r.kind === 'emote') { const k = free(); if (k >= 0) wheel[k] = r.id } else equipped[r.kind] = r.id
        })
        return true
      }
      if (name === 'br/market/equip') {
        later(() => {
          if (!r || !owns(r)) return
          if (r.kind !== 'emote') { equipped[r.kind] = r.id; return }
          if (!emotes || wheel.includes(r.id)) return
          const k = d.replace ? wheel.indexOf(d.replace) : free()
          if (k >= 0) wheel[k] = r.id
        })
        return true
      }
      if (name === 'br/market/unequip') {
        later(() => {
          const k = r ? wheel.indexOf(r.id) : -1
          if (k >= 0) wheel[k] = ''
        })
        return true
      }
      return false
    },
  }
}
