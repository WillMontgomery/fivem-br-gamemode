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
  /** True when THIS player is in the current round. A lobby bystander shares
   *  match.state with the fighters but must keep their menu through someone
   *  else's teardown. */
  participant?: boolean
}

export interface HudPayload {
  hp: number
  armour: number
  alive: number
  squadsAlive: number
  kills: number
  state: PlayerState
  /** True while GTA's pause menu is open; the HUD hides under it. */
  paused?: boolean
  /** Sprint stamina 0..100, client-computed. The bar hides at full. */
  stamina?: number
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
  /** Damage per second (display units) currently applied outside. */
  dps?: number
}

export interface SquadMember {
  src: number
  name: string
  /** True for the party leader. */
  leader?: boolean
  state: PlayerState
  hp: number
  armour: number
  colour: string
}

export interface SquadPayload {
  id: string | null
  /** Server id of the party leader. Only the leader may invite or remove. */
  leader?: number | null
  /** This client's own server id. Sent because the UI has no other way to know
   *  it, and without it "am I the leader?" collapses into "does this party have
   *  a leader?" -- true for everybody. */
  you?: number
  members: SquadMember[]
  /** Invites awaiting an answer. Party (lobby) payloads only -- an in-match
   *  squad cannot be invited into. */
  pending?: { src: number; name: string }[]
}

/** An incoming party invite -- or a join REQUEST, the same card reversed
 *  (kind 'joinreq': someone asking the leader to take them). Expires
 *  server-side after a minute either way. */
export interface InvitePayload {
  partyId?: string
  kind?: 'invite' | 'joinreq'
  from: number
  name: string
  size: number
  max: number
}

export interface InvSlot {
  id: string
  label: string
  kind: 'weapon' | 'ammo' | 'consumable' | 'throwable'
  rarity: Rarity
  count: number
  clip?: number
  /** Which ammo pool a weapon's reserve comes from ('light', 'heavy', ...).
   *  Sent by Lua rather than looked up here: the weapon table lives in br_lib
   *  and a hand-mirrored copy would go stale the first time a gun is added. */
  pool?: string
}

/** An in-progress consumable. Times out against the SERVER clock, like every
 *  other countdown here -- `endsAt` is a server timestamp, never Date.now(). */
export interface InvUsing {
  slot: number
  endsAt: number
  ms: number
}

export interface InvPayload {
  slots: (InvSlot | null)[]
  ammo: Record<string, number>
  /** 1-based, matching the slot1..slot5 keybinds. */
  active: number
  using?: InvUsing | null
}

/**
 * What Lua actually puts on the wire.
 *
 * An empty slot travels as `false`, not nil: a Lua array with a nil hole in it
 * does not survive serialisation as an array, and the whole inventory depends
 * on slot POSITION. `false` is normalised to `null` once, in the store's
 * setter, so no component ever sees both spellings of empty.
 */
export interface WireInvPayload extends Omit<InvPayload, 'slots'> {
  slots: (InvSlot | false | null)[]
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
  /** How this player died, when they did: 'storm', 'fall', 'drowned',
   *  'burned', 'explosion', 'roadkill', or undefined/unknown. Drives the
   *  verdict slam -- a storm death is not an "elimination". */
  cause?: string | null
  /** True when another player did it. */
  byPlayer?: boolean
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
  /** The native minimap's rectangle, in viewport percentages: left/bottom
   *  insets and width/height. Our health bars, the chat column and the
   *  notice stack all anchor to it -- it moves with the player's safe-zone
   *  slider, so nothing here is hardcodeable. */
  mapLeft?: number
  mapBottom?: number
  mapW?: number
  mapH?: number
  /** Whether the radar is currently drawn at all. */
  radarOn?: boolean
  /** False from first join until the world has streamed in around the ped.
   *  The lobby keeps an opaque loading backdrop up while false -- the menu
   *  is fully interactive over it -- and fades it out when this flips.
   *  Rides the screen envelope so a br_ui restart re-learns it. */
  worldReady?: boolean
  /** True while a sniper scope scaleform covers the screen. Sent on its own,
   *  the instant it changes -- which is why setScreen MERGES rather than
   *  replaces: this one-field envelope must not wipe the minimap rectangle. */
  scoped?: boolean
}

/**
 * Queue progress.
 *
 * Exists so a waiting player can see WHY they are waiting. "Searching for
 * players" with no numbers behind it is indistinguishable from a broken queue --
 * which is exactly how it looked while the Play button was wired to nothing.
 */
export interface LobbyPlayer {
  src: number
  name: string
  inParty: boolean
  queued: boolean
  /** Leading a real party (2+). The Join tab lists these. */
  leader?: boolean
  /** Currently in a running match; not offerable for create/join. */
  inMatch?: boolean
}

/**
 * Why the match has not started yet.
 *
 * Produced by the same server function that decides whether to start, so the
 * explanation can never describe a condition that is not the one actually
 * holding the match. Absent when nothing is blocking.
 */
export interface LobbyWait {
  reason: 'players' | 'squads' | 'party'
  have: number
  need: number
}

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
  /** Connected players, excluding this one. Lua filters us out so the UI is
   *  not asked to know its own server id. */
  players?: LobbyPlayer[]
  /** What the queue is waiting for, or absent when nothing is. */
  wait?: LobbyWait
  /** How much of THIS player's party has readied up. Absent when not in one. */
  party?: { ready: number; size: number }
  /** Server ids of everyone currently queued, so the party panel can mark
   *  which members are still holding the group. Already public knowledge --
   *  the same broadcast carries it to every client. */
  readyIds?: number[]
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
  /** Wire shape, like every other field here: the snapshot is what Lua sends,
   *  not what the store holds. `hydrate` normalises it. */
  inv: WireInvPayload
  storm: StormPayload | null
  chat: ChatMessage[]
}

// --- envelope ---------------------------------------------------------------

export type Envelope =
  | { k: 'snapshot'; d: SnapshotPayload }
  | { k: 'state';    d: MatchPayload }
  | { k: 'hud';      d: HudPayload }
  | { k: 'squad';    d: SquadPayload }
  | { k: 'inv';      d: WireInvPayload }
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
  | { k: 'invite';   d: InvitePayload }
  | { k: 'leaving';  d: { show: boolean } }

export type EnvelopeKind = Envelope['k']

/** The full wire message, including the fields the router consumes. */
export type WireEnvelope = Envelope & { t: 'br'; v: number; s: number }

/** NUI -> Lua callback names. Mirrors BR.NuiCb. */
export const CB = {
  QUEUE:        'br/lobby/queue',
  QUEUE_LEAVE:  'br/lobby/leave',
  SQUAD_INVITE: 'br/squad/invite',
  SQUAD_RESPOND: 'br/squad/respond',
  SQUAD_KICK:   'br/squad/kick',
  SQUAD_JOINREQ: 'br/squad/joinreq',
  SQUAD_JOINRESP: 'br/squad/joinresp',
  SQUAD_LEAVE:  'br/squad/leave',
  INV_SWAP:     'br/inv/swap',
  INV_DROP:     'br/inv/drop',
  INV_USE:      'br/inv/use',
  INV_SELECT:   'br/inv/select',
  CLOSE:        'br/close',
  CHAT_SEND:    'br/chat/send',
  CHAT_FOCUS:   'br/chat/focus',
  PAUSE:        'br/pause',
  ERROR:        'br/err',
  ENV:          'br/ui/env',
} as const

export type CallbackName = (typeof CB)[keyof typeof CB]
