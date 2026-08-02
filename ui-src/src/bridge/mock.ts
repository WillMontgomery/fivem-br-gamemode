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
  return {} as Res
}

const NAMES = ['Kestrel', 'Vandal', 'Nyx', 'Rook', 'Ember', 'Halcyon', 'Wraith']

/** Seed a plausible mid-match state and keep it moving. */
export function startMockDriver(): void {
  const now = Date.now()

  emit({
    k: 'snapshot',
    d: {
      match: { state: 'playing', mode: 'squad', endsAt: now + 95_000, serverNow: now },
      hud: { hp: 82, armour: 45, alive: 23, squadsAlive: 8, kills: 3, state: 'alive' },
      squad: {
        id: 'sq_1',
        members: [
          { src: 1, name: 'You',     state: 'alive', hp: 82,  armour: 45, colour: '#6EE7F9' },
          { src: 2, name: 'Kestrel', state: 'alive', hp: 100, armour: 80, colour: '#A78BFA' },
          { src: 3, name: 'Vandal',  state: 'dbno',  hp: 12,  armour: 0,  colour: '#FBBF24' },
          { src: 4, name: 'Nyx',     state: 'dead',  hp: 0,   armour: 0,  colour: '#F472B6' },
        ],
      },
      inv: {
        slots: [
          { id: 'carbinerifle', label: 'Carbine Rifle', kind: 'weapon', rarity: 3, count: 1, clip: 24 },
          { id: 'pumpshotgun',  label: 'Pump Shotgun',  kind: 'weapon', rarity: 2, count: 1, clip: 6 },
          { id: 'heavysniper',  label: 'Heavy Sniper',  kind: 'weapon', rarity: 5, count: 1, clip: 4 },
          { id: 'shield',       label: 'Shield Potion', kind: 'consumable', rarity: 3, count: 2 },
          null,
        ],
        ammo: { light: 84, smg: 0, medium: 172, shells: 22, heavy: 9 },
        active: 1,
      },
      storm: {
        phase: 4, phaseState: 'shrinking', endsAt: now + 42_000,
        radius: 520, edgeDistance: -180, bearing: 214,
      },
      chat: [
        { channel: 'system', from: 0, name: 'System', text: 'Storm closing in 30s', at: now - 30_000 },
        { channel: 'global', from: 7, name: 'Halcyon', text: 'gg that drop was rough', at: now - 20_000 },
        { channel: 'squad',  from: 2, name: 'Kestrel', text: 'rotating north, need meds', at: now - 8_000 },
      ],
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
        radius, edgeDistance: edge, bearing: (Date.now() / 90) % 360,
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
