/**
 * The Lua <-> NUI contract.
 *
 * This file MIRRORS br_lib/shared/protocol.lua. The two are hand-kept in sync
 * rather than generated: the union has a dozen members, and codegen for that is
 * more machinery than it saves. If you add a kind here, add it there too.
 *
 * Lua sends exactly one envelope shape, always:
 *     { t: 'br', v: 1, k: <kind>, d: <payload>, s: <seq> }
 * `s` is monotonic so stale or out-of-order messages can be dropped.
 */

export const ENVELOPE_VERSION = 1

// --- enums, mirroring br_lib/shared/enums.lua -------------------------------

export type MatchState =
  | 'waiting' | 'warmup' | 'bus' | 'playing' | 'ended' | 'cleanup'

export type PlayerState =
  | 'lobby' | 'warmup' | 'bus' | 'freefall' | 'glide'
  | 'alive' | 'dbno' | 'dead' | 'spectating' | 'left'

export type StormPhaseState = 'pre' | 'holding' | 'shrinking' | 'finished'

export type ChatChannel = 'global' | 'squad' | 'system'

/** Rarity is 1..5; index into RARITY below. */
export type Rarity = 1 | 2 | 3 | 4 | 5

export const RARITY: Record<Rarity, { key: string; label: string; hex: string }> = {
  1: { key: 'common',    label: 'Common',    hex: '#B0B0B0' },
  2: { key: 'uncommon',  label: 'Uncommon',  hex: '#4CD964' },
  3: { key: 'rare',      label: 'Rare',      hex: '#3B9BFF' },
  4: { key: 'epic',      label: 'Epic',      hex: '#B15BFF' },
  5: { key: 'legendary', label: 'Legendary', hex: '#FFB020' },
}

// --- payloads ---------------------------------------------------------------

export interface MatchPayload {
  state: MatchState
  mode: string
  /** Server timestamp. Countdowns are computed locally from this, never ticked
   *  over the bridge. */
  endsAt: number
  serverNow: number
}

export interface HudPayload {
  hp: number
  armour: number
  alive: number
  squadsAlive: number
  kills: number
  state: PlayerState
}

export interface StormPayload {
  phase: number
  phaseState: StormPhaseState
  /** Server timestamp at which the current sub-phase ends. */
  endsAt: number
  radius: number
  /** Metres outside the circle; negative means safe. */
  edgeDistance: number
  /** Compass bearing toward the circle centre, 0 = north. */
  bearing: number
}

export interface SquadMember {
  src: number
  name: string
  state: PlayerState
  hp: number
  armour: number
  colour: string
}

export interface SquadPayload {
  id: string | null
  members: SquadMember[]
}

export interface InvSlot {
  id: string
  label: string
  kind: 'weapon' | 'ammo' | 'consumable' | 'throwable'
  rarity: Rarity
  count: number
  clip?: number
}

export interface InvPayload {
  slots: (InvSlot | null)[]
  ammo: Record<string, number>
  active: number
}

export interface FeedEntry {
  id: number
  killer: string
  victim: string
  weapon: string
  headshot: boolean
  /** True when the local player was involved, for highlighting. */
  mine: boolean
}

export interface DbnoPayload {
  downed: boolean
  bleedEndsAt: number
  reviverName: string | null
  revivePct: number
}

export interface SpectatePayload {
  targetName: string
  targetSrc: number
  remaining: number
}

export interface SummaryPayload {
  placement: number
  total: number
  kills: number
  damage: number
  survivedMs: number
  xpEarned: number
  won: boolean
}

export interface ChatMessage {
  channel: ChatChannel
  from: number
  name: string
  text: string
  at: number
}

/**
 * Real screen metrics, read from the game.
 *
 * safeX/safeY are percentage insets derived from GetSafeZoneSize, which the
 * player controls in Settings > Display and which the engine varies with aspect
 * ratio. radarW/radarH describe the native minimap's footprint in rem.
 */
export interface ScreenPayload {
  width: number
  height: number
  safeX: number
  safeY: number
  radarW: number
  radarH: number
  aspect: number
}

/**
 * Queue progress.
 *
 * Exists so a waiting player can see WHY they are waiting. "Searching for
 * players" with no numbers behind it is indistinguishable from a broken queue --
 * which is exactly how it looked while the Play button was wired to nothing.
 */
export interface LobbyPayload {
  queued: number
  needed: number
  connected: number
  mode: string
  /** Whether THIS client is in the queue. Resolved by Lua from the id list, so
   *  the UI is told a boolean rather than asked to work it out. This is the
   *  authority on queue state -- local optimism only bridges the gap until the
   *  first payload arrives. */
  you: boolean
}

export interface ToastPayload {
  text: string
  tone?: 'info' | 'warn' | 'danger' | 'success'
  ms?: number
}

/** Which screen currently owns NUI focus. Lua is the authority. */
export interface FocusPayload {
  screen: 'none' | 'lobby' | 'squad' | 'inventory' | 'summary' | 'chat'
  /** Which channel a chat focus should open in. Rides along here rather than
   *  needing its own envelope kind. */
  channel?: ChatChannel
}

export interface SnapshotPayload {
  match: MatchPayload
  hud: HudPayload
  squad: SquadPayload
  inv: InvPayload
  storm: StormPayload | null
  chat: ChatMessage[]
}

// --- envelope ---------------------------------------------------------------

export type Envelope =
  | { k: 'snapshot'; d: SnapshotPayload }
  | { k: 'state';    d: MatchPayload }
  | { k: 'hud';      d: HudPayload }
  | { k: 'squad';    d: SquadPayload }
  | { k: 'inv';      d: InvPayload }
  | { k: 'feed';     d: FeedEntry }
  | { k: 'storm';    d: StormPayload }
  | { k: 'dbno';     d: DbnoPayload }
  | { k: 'spectate'; d: SpectatePayload }
  | { k: 'summary';  d: SummaryPayload }
  | { k: 'focus';    d: FocusPayload }
  | { k: 'toast';    d: ToastPayload }
  | { k: 'chat';     d: ChatMessage }
  | { k: 'screen';   d: ScreenPayload }
  | { k: 'lobby';    d: LobbyPayload }

export type EnvelopeKind = Envelope['k']

/** The full wire message, including the fields the router consumes. */
export type WireEnvelope = Envelope & { t: 'br'; v: number; s: number }

/** NUI -> Lua callback names. Mirrors BR.NuiCb. */
export const CB = {
  QUEUE:        'br/lobby/queue',
  QUEUE_LEAVE:  'br/lobby/leave',
  SQUAD_INVITE: 'br/squad/invite',
  SQUAD_LEAVE:  'br/squad/leave',
  INV_SWAP:     'br/inv/swap',
  INV_DROP:     'br/inv/drop',
  INV_USE:      'br/inv/use',
  INV_SELECT:   'br/inv/select',
  CLOSE:        'br/close',
  CHAT_SEND:    'br/chat/send',
  CHAT_FOCUS:   'br/chat/focus',
  ERROR:        'br/err',
  ENV:          'br/ui/env',
} as const

export type CallbackName = (typeof CB)[keyof typeof CB]
