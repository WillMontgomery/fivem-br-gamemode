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
  /**
   * MY OWN PED SAYS IT HAS TOUCHED DOWN, which is not the same claim as
   * `state`.
   *
   * `state` is the SERVER's word, and it becomes 'alive' only once the landing
   * report has made its round trip -- a message with a documented history of
   * going missing, which is why it has a retry loop and a server-side rescue
   * net behind it. Until it lands, the panels below hide themselves and the
   * player stands on the ground with no inventory bar and no squad panel,
   * occasionally until the match itself reaches 'playing' (#126).
   *
   * That was read as slowness once and answered with speed. It is not
   * slowness: the systems are off, and this is the second fact that turns them
   * on. Only presentation reads it -- nothing here decides anything the server
   * owns.
   */
  landed?: boolean
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
  /** Eliminations by this member. Summed for the squad total on the HUD. */
  kills?: number
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
  /** WITHDRAWN. The sender readied up (or otherwise stopped being somewhere an
   *  acceptance could land), so the card comes off the screen rather than
   *  waiting to be clicked and then refused. The other fields are absent on a
   *  cancel -- it is a verb, not a state. */
  cancel?: boolean
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
  /** The ITEM ID when a player did it (`carbinerifle`), so the row can draw
   *  the weapon. The CAUSE when the world did it (`storm`, `fall`) -- the two
   *  never collide, because the cause wording only renders when there is no
   *  killer. */
  weapon: string
  headshot: boolean
  /** I got this kill. */
  mine: boolean
  /** I am the one who died. The opposite piece of news from `mine`, and it
   *  used to share the flag with it -- so the line where you were eliminated
   *  was drawn in the same colour as the line where you eliminated someone. */
  died?: boolean
}

/**
 * YOU connected.
 *
 * Two senders, deliberately. DAMAGE_FEED (the shooter's private damage channel,
 * one per bullet) carries amount/headshot and drives the marker. KILL_FEED
 * carries the victim's NAME and drives the banner -- it is the only event that
 * knows it, and widening the per-bullet channel to include a name would put one
 * on the wire hundreds of times a match to be used once.
 */
export interface HitPayload {
  amount?: number
  headshot?: boolean
  /** The hit was fatal. Punctuates the marker. */
  killed?: boolean
  /** Present only on the KILL_FEED sender: whose name the banner shows. */
  name?: string
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
  /** 'maintenance' outranks the rest: it is not about the queue being too
   *  small, and no number of extra players will clear it. */
  reason: 'players' | 'squads' | 'party' | 'maintenance'
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

/**
 * One notice.
 *
 * A NOTICE IS ADDRESSABLE. Everything below `tone` exists so a sender can talk
 * about a notice that is already on screen instead of only ever adding another
 * one -- which is the difference between a notification system and a list of
 * things that happened.
 *
 * The failing case that drove this: a sticky bomb goes inert for thirty
 * seconds. Without identity, saying so costs either one line that lies for
 * twenty-nine seconds, or thirty lines that shove everything else off the
 * stack. With it, it is ONE line that counts itself down and then leaves.
 */
export interface ToastPayload {
  text: string
  tone?: 'info' | 'warn' | 'danger' | 'success'
  /** Lifetime in ms. Ignored when `endsAt` or `sticky` is set. */
  ms?: number
  /**
   * IDENTITY. A second notice with the same key REPLACES the first in place --
   * new text, new tone, new deadline, same row, no fly-in. It does not
   * coalesce into a x2, because an update is one event changing rather than
   * the same event happening twice.
   *
   * Keyless notices keep the old behaviour: matched on their text and counted.
   */
  key?: string
  /**
   * A SERVER deadline, in the same clock `endsAt` uses everywhere else. The
   * row renders a live countdown beside the text -- one notice with a moving
   * number, driven from rAF, never a message per second -- and removes itself
   * when it lands. Requires `key` to be updatable; useful without one.
   */
  endsAt?: number
  /** Never expires on its own. Only an explicit `clear` takes it away, so this
   *  is for STATE ("you are outside the storm"), not for events. Requires a
   *  key, or nothing could ever remove it. */
  sticky?: boolean
  /** Remove the notice with this key, now. A verb: no other field is read. */
  clear?: boolean
}

/**
 * The player's own preferences.
 *
 * LUA IS THE AUTHORITY, not this page. The page sends the whole object and
 * renders whatever comes back -- so a value outside the accepted range visibly
 * snaps to what was actually stored, instead of the slider keeping a number
 * the game never agreed to.
 *
 * Ranges live in br_ui/client/settings.lua and are enforced there. The ones
 * quoted here are documentation, not validation.
 */
export interface SettingsPayload {
  /** 0.80 .. 1.30. Multiplies the root font size INSIDE its clamp. */
  uiScale: number
  /** 0.90 .. 1.15. Opt-in, via the .tscale class. */
  textScale: number
  colourblind: 'off' | 'deuter' | 'protan' | 'tritan'
  /** 0 .. 1. Reaches the browser cue palette, which is the only audio tier a
   *  slider CAN reach -- PlaySoundFrontend has no per-cue volume. */
  volUi: number
  volMusic: number
  /** Voice routing: 'squad' uses the squad room the server granted, 'nearby'
   *  declines it and stays on proximity, 'off' stops transmitting. It can only
   *  ever DECLINE a room -- the server decides which exist. */
  voiceMode: 'squad' | 'nearby' | 'off'
  /** Proposed to the server; empty means "use my platform name". */
  gamertag: string
}

/**
 * The character roster.
 *
 * NAMES ONLY, NO ARTWORK. This project is vanilla-assets-only, so there is no
 * thumbnail set to ship and nothing to draw a grid of portraits from -- which
 * is exactly why the locker shows the REAL ped in the world instead of a
 * preview pane. The list is the index; the character standing in front of the
 * camera is the picture.
 */
export interface LockerPayload {
  peds: { id: string; name: string }[]
  chosen: string
  /** The id currently being streamed in, if any. A model that is not already
   *  in memory takes a moment, and until this existed the button looked like
   *  it had not registered the click. */
  loading?: string | null
}

/**
 * LEVEL AND XP.
 *
 * There is no XP system in this game yet -- no persistence, no server ledger.
 * `SummaryPayload.xpEarned` has been on the wire since M2 and nothing has ever
 * written a non-zero value into it. This is the CONTRACT for one, so the
 * interface can be argued about before the server half is written; Lua sends a
 * real profile when there is one and the browser harness seeds a plausible one
 * meanwhile. Nothing in the UI knows the difference.
 */
export interface ProgressPayload {
  level: number
  /** XP into the current level, not lifetime. */
  xp: number
  /** What the current level costs. */
  needed: number
}

/** The post-match award, which is what animates the bar. Carries where the
 *  player WAS, because the fill has to start from there. */
/** What one match actually paid. Server-computed, from the same numbers
 *  written to the database -- not a client-side guess. */
/** One row of the in-game player list. Everything here is already in
 *  PUBLIC_FIELDS - no position, no health, no matchId. */
export interface ListedPlayer {
  src: number
  name: string
  state: PlayerState
  squadId: string | null
  /** They disconnected mid-match. Still listed, and still reportable - somebody
   *  who ragequits after cheating is exactly who you want to report. */
  left: boolean
  /** This is you. No checkbox is rendered. */
  you?: boolean
}

export interface ReportCategory {
  id: string
  label: string
  default?: boolean
}

export interface PlayersPayload {
  players: ListedPlayer[]
  /** THE RULES ARRIVE WITH THE DATA. The panel does not own the category list
   *  or the limit, and must not hardcode one that drifts from the server. */
  categories: ReportCategory[]
  defaultCategory: string
  maxTargets: number
  /** Reports left this match. Zero disables submission. */
  remaining: number
}

/** The answer to a submitted report. */
export interface ReportResult {
  ok: boolean
  filed: number
  refused?: string
}

export interface EarnedPayload {
  xp: number
  volts: number
  /** Level AFTER the match. */
  level: number
  levelUp: boolean
}

export interface XpAward {
  xp: number
  fromLevel: number
  fromXp: number
  fromNeeded: number
}

/**
 * One thing on sale.
 *
 * COSMETIC ONLY, ENFORCED BY THE CATALOGUE rather than by this type: `kind`
 * has no member that could affect a fight, and adding one would be the
 * decision, not an accident. See screens/Market.tsx for the reasoning per
 * category.
 */
export interface MarketItem {
  id: string
  name: string
  sub?: string
  kind: 'character' | 'chute' | 'trail' | 'weapon' | 'banner' | 'verdict'
  price: number
  rarity?: Rarity
  owned?: boolean
  /** Exactly one item per `kind` carries this. The server decides it; the page
   *  never infers it, because "what am I wearing" has to survive a reconnect
   *  and only one side of this connection can promise that. */
  equipped?: boolean
  /** From a season that has ended. Renders for its owners, cannot be bought. */
  locked?: boolean
  /** Which season it came from, for the card's provenance line. */
  season?: string
}

export interface MarketPayload {
  /** Earned, never bought. */
  balance: number
  /** What the currency is called. Sent by Lua so the name lives in one place. */
  currency?: string
  items: MarketItem[]
}

/** One rebindable action, from br_ui/client/keybinds.lua. */
export interface KeybindAction {
  group: string
  /** The RegisterCommand name, which is what Lua keys its binding table on. */
  command: string
  label: string
  /** Windows virtual-key code, or absent when unbound. This is what travels:
   *  Lua reads the key with IS_RAW_KEY_PRESSED, which takes a VK code. */
  vk?: number
  /** Readable name for that code, resolved by Lua. '' when unbound. */
  key: string
  default: string
  /** True when the player has changed this row. Drives the reset affordance,
   *  which is the ONLY way back for a default the capture cannot type --
   *  Escape cancels a capture, so Escape can never be pressed into one. */
  custom?: boolean
}

/** What the black curtain is covering. See screens/LeaveScreen.tsx. */
export type CurtainKind = 'leaving' | 'dropping'

/** Which screen currently owns NUI focus. Lua is the authority. */
export interface FocusPayload {
  /** `players` and `playersReport` are one panel in two modes. They are two
   *  screens because they hold different focus -- see BR.FocusKeepsInput. */
  screen: 'none' | 'lobby' | 'squad' | 'inventory' | 'summary' | 'chat'
        | 'settings' | 'locker' | 'market' | 'pause' | 'help'
        | 'players' | 'playersReport'
  /** Which channel a chat focus should open in. Rides along here rather than
   *  needing its own envelope kind. */
  channel?: ChatChannel
  /** Which tab a pause focus should land on. Same trick as `channel` above:
   *  /help has to say both "open the pause menu" and "on Help", and two
   *  envelopes would be a race for which arrives first. */
  tab?: string
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
  // The PARTY, always, alongside whatever `squad` is carrying. Mid-match they
  // are different groups -- the squad is this round's team, the party is who
  // you keep -- and one channel can only describe one of them.
  | { k: 'party';    d: SquadPayload }
  // Who is speaking right now, by server id. Voice was the one system in the
  // game with no visual at all.
  | { k: 'voice';    d: { talking: number[] } }
  | { k: 'inv';      d: WireInvPayload }
  | { k: 'feed';     d: FeedEntry }
  | { k: 'hit';      d: HitPayload }
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
  | { k: 'leaving';  d: { show: boolean; kind?: CurtainKind } }
  | { k: 'settings'; d: SettingsPayload }
  | { k: 'locker';   d: LockerPayload }
  | { k: 'progress'; d: ProgressPayload }
  | { k: 'market';   d: MarketPayload }
  | { k: 'keybinds'; d: { actions: KeybindAction[]; raw?: boolean } }
  | { k: 'xp';       d: XpAward }
  | { k: 'earned';   d: EarnedPayload }
  | { k: 'players';  d: PlayersPayload }
  | { k: 'report';   d: ReportResult }

export type EnvelopeKind = Envelope['k']

/** The full wire message, including the fields the router consumes. */
export type WireEnvelope = Envelope & { t: 'br'; v: number; s: number }

/** NUI -> Lua callback names. Mirrors BR.NuiCb. */
export const CB = {
  QUEUE:        'br/lobby/queue',
  QUEUE_LEAVE:  'br/lobby/leave',
  MODE_SET:     'br/lobby/mode',
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
  /** Menu audio. The UI names a CUE; Lua owns the table and the throttle. */
  SFX:          'br/sfx',
  SETTINGS_SAVE:  'br/settings/save',
  SETTINGS_FOCUS: 'br/settings/focus',
  KEYBINDS:       'br/settings/keybinds',
  LOCKER_PICK:    'br/locker/pick',
  LOCKER_SPIN:    'br/locker/spin',
  LOCKER_FOCUS:   'br/locker/focus',
  MARKET_FOCUS:   'br/market/focus',
  MARKET_BUY:     'br/market/buy',
  MARKET_EQUIP:   'br/market/equip',
  PLAYERS_FOCUS:  'br/players/focus',
  REPORT_SUBMIT:  'br/report/submit',
  PAUSE_FOCUS:    'br/pause/focus',
  HELP_FOCUS:     'br/help/focus',
  VOICE_SETTINGS: 'br/voice/settings',
  XP_BUSY:        'br/xp/busy',
  PAUSE_ACTION:   'br/pause/action',
  KEYBIND_SET:    'br/settings/keybind',
  /**
   * "I am now fully black."
   *
   * The other half of every transition. Lua covers the screen and then changes
   * the world underneath -- and until this existed it could only GUESS when the
   * cover had finished going up, because the cover is a CSS transition in CEF
   * and the change is a Citizen.Wait in another process. It guessed wrong
   * consistently, and the player saw the cut the cover was added to hide
   * (#124). See `bridge/cover.ts`.
   */
  COVERED:        'br/cover',
  ERROR:        'br/err',
  ENV:          'br/ui/env',
} as const

export type CallbackName = (typeof CB)[keyof typeof CB]
