/**
 * Browser development harness.
 *
 * The entire UI runs in a normal browser via `npm run dev`, driven by the fake
 * envelopes below. This is the fastest iteration loop on the project and it is
 * worth keeping honest: build screens here, not by restarting a game client.
 *
 * Nothing in this file ships meaningfully -- isBrowser is false in game, so the
 * driver never starts and mockFetch is never imported.
 */

import { dispatch } from './nui'
import type {
  CallbackName, ChatMessage, Envelope, WireEnvelope,
} from './types'

let seq = 0

/** Push a fake envelope through the real dispatcher. */
export function emit<E extends Envelope>(env: E): void {
  dispatch({ t: 'br', v: 1, s: ++seq, ...env } as WireEnvelope)
}

/**
 * SYNTHETIC PROGRESSION AND CATALOGUE.
 *
 * Neither system exists server-side yet -- see screens/Progress.tsx and
 * screens/Market.tsx, which say so in full. This is what makes the screens
 * arguable before anybody writes the persistence half: real numbers, real
 * prices, real level costs, all invented here and nowhere else, so deleting
 * this block is the entire act of switching to the real thing.
 */
const MOCK_PROGRESS = { level: 14, xp: 2380, needed: 4000 }

const MOCK_MARKET = {
  balance: 7450,
  items: [
    { id: 'ped_juggalo',  name: 'Juggalo',    sub: 'Character',  kind: 'character' as const, price: 1500, rarity: 2 as const },
    { id: 'ped_clown',    name: 'Clown',      sub: 'Character',  kind: 'character' as const, price: 2500, rarity: 3 as const },
    { id: 'ped_trooper',  name: 'Trooper',    sub: 'Character',  kind: 'character' as const, price: 4000, rarity: 4 as const, owned: true },
    { id: 'ped_yeti',     name: 'Yeti',       sub: 'Character',  kind: 'character' as const, price: 9000, rarity: 5 as const },
    { id: 'ped_diver',    name: 'Diver',      sub: 'Character',  kind: 'character' as const, price: 1500, rarity: 2 as const },
    { id: 'ped_agent',    name: 'Agent',      sub: 'Character',  kind: 'character' as const, price: 3000, rarity: 3 as const },
    { id: 'trail_ember',  name: 'Ember',      sub: 'Chute trail', kind: 'trail' as const, price: 800,  rarity: 2 as const },
    { id: 'trail_void',   name: 'Void',       sub: 'Chute trail', kind: 'trail' as const, price: 2000, rarity: 4 as const },
    { id: 'trail_gold',   name: 'Bullion',    sub: 'Chute trail', kind: 'trail' as const, price: 6000, rarity: 5 as const },
    { id: 'ban_storm',    name: 'Stormchaser', sub: 'Banner',    kind: 'banner' as const, price: 1200, rarity: 3 as const },
    { id: 'ban_first',    name: 'Day One',    sub: 'Banner',     kind: 'banner' as const, price: 0,    rarity: 5 as const, owned: true },
    { id: 'vd_royale',    name: 'Victory Royale', sub: 'Verdict', kind: 'verdict' as const, price: 0, rarity: 1 as const, owned: true },
    { id: 'vd_lastone',   name: 'Last One Standing', sub: 'Verdict', kind: 'verdict' as const, price: 3500, rarity: 4 as const },
  ],
}

/** Mirrors br_lib/config/peds.lua closely enough to lay the screen out. */
const MOCK_PEDS = [
  { id: 'streetguy', name: 'Street' }, { id: 'streetgirl', name: 'Downtown' },
  { id: 'hiker', name: 'Hiker' },      { id: 'runner', name: 'Runner' },
  { id: 'biker', name: 'Biker' },      { id: 'mechanic', name: 'Mechanic' },
  { id: 'pilot', name: 'Pilot' },      { id: 'diver', name: 'Diver' },
  { id: 'trooper', name: 'Trooper' },  { id: 'agent', name: 'Agent' },
  { id: 'chef', name: 'Chef' },        { id: 'clown', name: 'Clown' },
  { id: 'juggalo', name: 'Juggalo' },  { id: 'surfer', name: 'Surfer' },
  { id: 'exec', name: 'Executive' },   { id: 'yeti', name: 'Yeti' },
]

/** Stand-in for Lua callbacks while running in a browser. */
export async function mockFetch<Res>(name: CallbackName, data?: unknown): Promise<Res> {
  // eslint-disable-next-line no-console
  console.info('[mock] fetchNui', name, data)

  if (name === 'br/chat/send') {
    const d = data as { channel: ChatMessage['channel']; text: string }
    emit({
      k: 'chat',
      d: {
        channel: d.channel,
        from: 1,
        name: 'You',
        text: d.text,
        at: Date.now(),
      },
    })
  }

  // FOCUS IS LUA'S, so the harness has to play Lua. Settings is rendered off
  // `focus === 'settings'` rather than off a local flag, which means without
  // this the browser's Settings button would open nothing at all -- and the
  // difference between "the button is broken" and "the mock does not answer"
  // is not visible from the screen.
  const FOCUS_CB: Record<string, 'settings' | 'locker' | 'market' | 'pause'> = {
    'br/settings/focus': 'settings',
    'br/locker/focus': 'locker',
    'br/market/focus': 'market',
    'br/pause/focus': 'pause',
  }
  if (FOCUS_CB[name]) {
    const open = (data as { open?: boolean } | undefined)?.open === true
    emit({ k: 'focus', d: { screen: open ? FOCUS_CB[name]! : 'lobby' } })
    return { ok: true } as Res
  }

  // Picking a character has no ped to swap in a browser, so the harness does
  // the one part it CAN: echo the new roster. Without it the selection never
  // moves and the list looks like it is ignoring clicks -- which is exactly
  // the bug this screen would have if the Lua push were forgotten.
  if (name === 'br/locker/pick') {
    const id = String((data as { id?: string } | undefined)?.id ?? '')
    emit({ k: 'locker', d: { peds: MOCK_PEDS, chosen: id } })
    return { ok: true } as Res
  }

  // SETTINGS ECHO. Lua clamps and returns what it actually stored, and the
  // screen renders the echo rather than its own draft -- so a mock that
  // returns nothing would make the browser harness behave differently from
  // the game in exactly the place the design is subtle. The clamps here
  // mirror br_ui/client/settings.lua.
  if (name === 'br/settings/save') {
    const d = (data ?? {}) as Record<string, unknown>

    // A REFUSAL IS PART OF THE CONTRACT, so the harness has to be able to
    // produce one. The real rule is BR.ValidateName in br_lib -- shared by
    // the client and the server, and unit tested there. This is a stub of it
    // that exists only so the screen's error state is reachable in a browser;
    // it is deliberately crude, because duplicating the real list here would
    // create a second one to keep in step.
    const tag = String(d.gamertag ?? '').trim()
    const folded = tag.toLowerCase().replace(/[^a-z]/g, '')
    if (tag.length > 0 && tag.length < 3) {
      return { ok: false, field: 'gamertag', reason: 'Too short — 3 characters minimum.' } as Res
    }
    if (/fuck|shit|poop|admin/.test(folded)) {
      return { ok: false, field: 'gamertag', reason: 'That name is not available.' } as Res
    }

    const num = (k: string, lo: number, hi: number, dflt: number) => {
      const v = Number(d[k])
      return Number.isFinite(v) ? Math.max(lo, Math.min(hi, v)) : dflt
    }
    return {
      ok: true,
      settings: {
        uiScale: num('uiScale', 0.8, 1.3, 1),
        textScale: num('textScale', 0.9, 1.15, 1),
        colourblind: ['off', 'deuter', 'protan', 'tritan']
          .includes(String(d.colourblind)) ? d.colourblind : 'off',
        volUi: num('volUi', 0, 1, 0.7),
        volMusic: num('volMusic', 0, 1, 0.5),
        gamertag: String(d.gamertag ?? '').trim().slice(0, 20),
      },
    } as Res
  }

  return {} as Res
}

const NAMES = ['Kestrel', 'Vandal', 'Nyx', 'Rook', 'Ember', 'Halcyon', 'Wraith']

/** Seed a plausible mid-match state and keep it moving. */
export function startMockDriver(): void {
  const now = Date.now()

  // Lua pushes this on br:ui:ready, and the lobby hides its Character button
  // until it arrives -- so a harness that never sends it is a harness where
  // the locker cannot be opened at all.
  emit({ k: 'locker', d: { peds: MOCK_PEDS, chosen: 'streetguy' } })
  emit({ k: 'progress', d: MOCK_PROGRESS })
  // Mirrors br_ui/client/keybinds.lua's ACTIONS table. Without it the
  // controls tab renders its empty state, which is a different screen from
  // the one that ships.
  emit({
    k: 'keybinds',
    d: {
      actions: [
        { group: 'Combat', command: 'brinventory', label: 'Inventory', key: 'TAB', default: 'TAB' },
        { group: 'Combat', command: 'brslot1', label: 'Slot 1', key: '1', default: '1' },
        { group: 'Combat', command: 'brslot2', label: 'Slot 2', key: '2', default: '2' },
        { group: 'World', command: 'brinteract', label: 'Interact / loot', key: 'E', default: 'E', custom: true },
        { group: 'World', command: 'brmarker', label: 'Place map marker', key: 'B', default: 'B' },
        { group: 'Social', command: 'brchat', label: 'Chat', key: 'T', default: 'T' },
        { group: 'Interface', command: 'brpausemenu', label: 'Pause menu', key: 'Escape', default: 'F1' },
        { group: 'Interface', command: 'brleave', label: 'Leave the match', key: '', default: '' },
      ],
    },
  })
  emit({ k: 'market', d: MOCK_MARKET })

  emit({
    k: 'snapshot',
    d: {
      match: { state: 'playing', mode: 'squad', endsAt: now + 95_000, serverNow: now },
      hud: { hp: 82, armour: 45, alive: 23, squadsAlive: 8, kills: 3, state: 'alive' },
      squad: {
        id: 'sq_1',
        members: [
          { src: 1, name: 'You',     state: 'alive', hp: 82,  armour: 45, colour: '#6EE7F9' },
          { src: 2, name: 'Kestrel', state: 'alive', hp: 100, armour: 80, colour: '#2DD4BF' },
          { src: 3, name: 'Vandal',  state: 'dbno',  hp: 12,  armour: 0,  colour: '#FBBF24' },
          { src: 4, name: 'Nyx',     state: 'dead',  hp: 0,   armour: 0,  colour: '#F472B6' },
        ],
      },
      inv: {
        // `false` rather than null in the empty slot, and `pool` on the
        // weapons: this mirrors what Lua actually puts on the wire, so the
        // store's normalisation is exercised in the browser rather than only
        // in the game (an earlier mock that sent the already-clean shape is
        // exactly how a boundary bug reaches production).
        slots: [
          { id: 'carbinerifle', label: 'Carbine Rifle', kind: 'weapon', rarity: 3, count: 1, clip: 24, pool: 'medium' },
          { id: 'pumpshotgun',  label: 'Pump Shotgun',  kind: 'weapon', rarity: 2, count: 1, clip: 6, pool: 'shells' },
          { id: 'heavysniper',  label: 'Heavy Sniper',  kind: 'weapon', rarity: 5, count: 1, clip: 4, pool: 'heavy' },
          { id: 'shield',       label: 'Shield Potion', kind: 'consumable', rarity: 3, count: 2 },
          false,
        ],
        ammo: { light: 84, smg: 0, medium: 172, shells: 22, heavy: 9 },
        active: 1,
        using: null,
      },
      storm: {
        phase: 4, phaseState: 'shrinking', endsAt: now + 42_000,
        radius: 520, edgeDistance: -180, bearing: 214, dps: 8,
      },
      chat: [
        { channel: 'system', from: 0, name: 'System', text: 'Storm closing in 30s', at: now - 30_000 },
        { channel: 'global', from: 7, name: 'Halcyon', text: 'gg that drop was rough', at: now - 20_000 },
        { channel: 'squad',  from: 2, name: 'Kestrel', text: 'rotating north, need meds', at: now - 8_000 },
      ],
    },
  })

  // Screen metrics as the game would report them at 1080p, default safe
  // zone -- so the minimap-anchored layout (bars/chat/notices) is exercised
  // in the browser too.
  emit({
    k: 'screen',
    d: {
      width: 1920, height: 1080, safeX: 2.2, safeY: 3.2,
      radarW: 25, radarH: 12.5, aspect: 16 / 9,
      mapLeft: 2.2, mapBottom: 3.2, mapW: 20.8, mapH: 19.5, radarOn: true,
    },
  })

  // Vitals drift, so the bars and their transitions can be seen working.
  let hp = 82, armour = 45, kills = 3, alive = 23
  window.setInterval(() => {
    hp = Math.max(6, Math.min(100, hp + (Math.random() * 18 - 9)))
    armour = Math.max(0, Math.min(100, armour + (Math.random() * 14 - 8)))
    if (Math.random() < 0.12) { alive = Math.max(1, alive - 1) }
    if (Math.random() < 0.05) { kills += 1 }
    emit({ k: 'hud', d: { hp, armour, alive, squadsAlive: Math.ceil(alive / 3), kills, state: 'alive' } })
  }, 900)

  // Storm ticks at the same 4 Hz the server would use.
  let radius = 520, edge = -180
  window.setInterval(() => {
    radius = Math.max(40, radius - 1.5)
    edge += Math.random() * 12 - 5
    emit({
      k: 'storm',
      d: {
        phase: 4, phaseState: 'shrinking', endsAt: Date.now() + 42_000,
        radius, edgeDistance: edge, bearing: (Date.now() / 90) % 360, dps: 8,
      },
    })
  }, 250)

  // Kill feed and chat traffic.
  let feedId = 0
  window.setInterval(() => {
    const a = NAMES[Math.floor(Math.random() * NAMES.length)]!
    const b = NAMES[Math.floor(Math.random() * NAMES.length)]!
    if (a === b) return
    emit({
      k: 'feed',
      d: {
        id: ++feedId, killer: a, victim: b,
        weapon: 'Carbine Rifle',
        headshot: Math.random() < 0.3,
        mine: Math.random() < 0.2,
      },
    })
  }, 3200)

  window.setInterval(() => {
    const who = NAMES[Math.floor(Math.random() * NAMES.length)]!
    emit({
      k: 'chat',
      d: {
        channel: Math.random() < 0.5 ? 'global' : 'squad',
        from: 9, name: who,
        text: ['pushing east', 'need shields', 'sniper on the ridge', 'nice shot'][
          Math.floor(Math.random() * 4)
        ]!,
        at: Date.now(),
      },
    })
  }, 5000)
}
