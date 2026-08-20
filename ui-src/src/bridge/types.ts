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

/**
 * The one import in this file, and it is type-only.
 *
 * `squadcue` carries a cue NAME, and the set of legal names is the cue table's
 * to define -- so the envelope references it rather than restating it as a
 * string. audio/cues.ts imports nothing, so this cannot become a cycle, and
 * `import type` is erased at build time either way.
 */
import type { Cue } from '../audio/cues'

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
  /**
   * WHEN THIS MATE BLEEDS OUT. A SERVER timestamp, on the same clock as every
   * other `endsAt` in this file, so it is only comparable to
   * `Date.now() + clockOffset` -- never to a bare Date.now().
   *
   * Set only while `state === 'dbno'`, and OPTIONAL BECAUSE LUA DOES NOT SEND
   * IT YET. `dbnoUntil` is explicitly marked non-public in br_core's
   * roster.lua ("the client is TOLD its own downed state on BR.Net.DBNO_SET,
   * and other players learn about it only from the `state` field"), so the
   * squad payload assembled in br_core/client/state.lua carries no deadline at
   * all -- see the note in hud/SquadPanel.tsx for exactly what has to change.
   *
   * The panel renders NO TIMER when this is absent rather than starting one of
   * its own. A browser-side countdown seeded from the first frame it saw a mate
   * go down would be wrong by however late that frame was, would reset on a
   * br_ui restart, and -- the one that matters -- would keep counting down
   * while enemy fire SHORTENS the real bleed, telling a squad they have time to
   * make the pickup when they do not.
   */
  bleedEndsAt?: number
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

/**
 * The verdict: what happened to you, not what you were paid.
 *
 * `xpEarned`, `damage` and `survivedMs` USED TO BE HERE and were removed. Lua
 * sent all three as a hardcoded 0 from the day the payload was written, nothing
 * ever rendered them, and they sat on the wire next to the XP bug looking for
 * all the world like the thing that fed it (owner, #91). What a match paid
 * arrives on EarnedPayload, from br_stats, computed from the values actually
 * written to the database. Two payloads, one of which is a fact.
 */
export interface SummaryPayload {
  placement: number
  total: number
  kills: number
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
  /**
   * Voice routing, SAVED ONCE PER KIND OF MATCH: 'squad' uses the squad radio
   * the server granted, 'nearby' declines it and stays on proximity, 'off'
   * stops transmitting. It can only ever DECLINE a room -- the server decides
   * which exist.
   *
   * TWO FIELDS BECAUSE ONE COULD NOT BE RIGHT FOR BOTH. A player who picks
   * Squad and then queues a solo used to carry Squad into a match with no
   * squads, which is total silence by design and identical to a fault (#157).
   *
   * WHICH ONE IS IN FORCE IS LUA'S ANSWER, not this page's -- br_core derives
   * it from the match kind (BR.VoiceModeFor, br_lib/shared/enums.lua) and
   * sends the result back on the voice envelope as `VoicePayload.mode`. This
   * page renders the two SAVED preferences and never computes the live one.
   *
   * 'squad' IS NOT A LEGAL VALUE FOR THE SOLO SLOT -- the type says so, and
   * Lua coerces it away regardless. See the solos row in Settings.tsx.
   */
  voiceModeSolo: 'nearby' | 'off'
  voiceModeSquad: 'squad' | 'nearby' | 'off'
  /** Proposed to the server; empty means "use my platform name". */
  gamertag: string
}

/**
 * WHO IS SPEAKING, AND WHY YOU MIGHT BE HEARING NOBODY.
 *
 * `talking`/`names` are the bottom-centre indicator: ids for the squad panel's
 * markers and names in the SAME ORDER for the bar. The names have to be on the
 * wire because proximity voice carries anyone in the match and the interface
 * has no other way to name a player who is not a squadmate.
 *
 * EVERYTHING ELSE IS THE STATUS, AND IT IS THE HALF THIS CHANNEL WAS MISSING.
 * Squad voice is a pma-voice RADIO with its own push-to-talk, and a player in
 * squad mode with no squad hears nothing at all -- both correct, both
 * completely invisible, and between them they produced a week of "squad voice
 * is broken" (#157). Lua computes the sentence and sends it; the page renders
 * it and does not compose its own, so there is exactly one place the wording
 * lives and it is next to the code that decides it (br_core/client/voice.lua,
 * BR.Voice.statusFor).
 */
export interface VoicePayload {
  talking: number[]
  names?: string[]
  /** The mode actually in force on this client, which is not necessarily the
   *  one the settings screen last drew a button for. */
  mode?: 'squad' | 'nearby' | 'off'
  /** The squad radio channel the SERVER granted, or null for none. */
  radio?: number | null
  /** What this client last asked pma-voice to join. 0 means "no radio". */
  joined?: number | null
  /** How many squadmates the server named. */
  mates?: number
  /** A short machine-readable verdict: 'nearby' | 'silenced' | 'nosquad' |
   *  'alone' | 'radio'. Style on this, never parse the prose. */
  status?: string
  /** Nothing can reach this player and nothing they say can leave. */
  silent?: boolean
  /** They ASKED for the silence ('off'). Do not alarm them about it. */
  chosen?: boolean
  /** One short line for the HUD. Absent when there is nothing to say. */
  headline?: string | null
  /** The longer version, for the settings screen. */
  detail?: string | null
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

/** One row of the in-game player list. Everything here is already in
 *  PUBLIC_FIELDS - no position, no health, no matchId. */
export interface ListedPlayer {
  /**
   * WHO THIS ROW IS ABOUT, AS AN OPAQUE PER-MATCH TOKEN (#172).
   *
   * It was `src: number` -- the player's server id -- and it could not stay
   * one, because the rows that matter most now include players who have LEFT
   * and a server id does not survive a disconnect. FiveM recycles them within
   * the minute, so a departed row keyed by its old id resolves to whoever holds
   * that slot now: the report would be filed against a stranger, and inside one
   * match two rows could have collided on the same key.
   *
   * NOT A LICENSE WITH THE PREFIX TRIMMED, WHICH WAS THE PROPOSAL THIS
   * REPLACED. `license:` is a constant, so removing it is a rename rather than
   * obfuscation, and what would be left is the durable identifier this project
   * files bans and moderation under. The server mints this instead, keeps the
   * mapping, and drops it when the match ends -- so the page holds a string
   * that means nothing anywhere else and never sees a license.
   *
   * SEND IT BACK EXACTLY AS IT ARRIVED. It is the row's React key, the key of
   * the tick map, and the only thing REPORT_SUBMIT carries about a target.
   */
  id: string
  name: string
  state: PlayerState
  /**
   * `squadId` USED TO BE HERE AND IS NOW STRIPPED BEFORE THE ENVELOPE IS SENT
   * (owner, 2026-08-17: "I don't want players to be able to tell how many
   * squads are left ... 38 players and 18 squads").
   *
   * It was a stable per-squad string, one per row, for every player in the
   * match -- so counting distinct values is the squad count, exactly, with no
   * inference needed. The `squad` tag PlayerList drew off it is gone for the
   * same reason (see the long note there for what the tag actually meant), and
   * removing only the tag would have left the number on the wire for anything
   * that reads the envelope.
   *
   * Deleted rather than made optional: a field nothing sends and nothing reads
   * is how a contract grows a member nobody can delete, which is the argument
   * `remaining` below was removed under. br_ui/client/players.lua is where the
   * strip happens.
   */
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
  /** How many players one submission may name. Read by the panel only to stop
   *  a sixth tick taking; the server refuses the same submission for the same
   *  reason, and costs the player nothing when it does. */
  maxTargets: number
  /**
   * `remaining` USED TO BE HERE and was deleted with #142, not merely stopped
   * being rendered. It carried the reports left this match for one line of
   * text -- "2 left" -- and the owner's instruction was that the panel does not
   * say it: "We don't need to tell a player how many people they can report, or
   * how many reports are left."
   *
   * The LIMIT is untouched. What went is the advertisement, and with it the
   * field: br_core stopped computing it, br_ui stopped forwarding it, and this
   * stopped declaring it, in one change. A payload member that survives the
   * last thing that read it is how this project has arrived at twelve confirmed
   * subsystems wired to nothing.
   */
}

/** The answer to a submitted report. */
export interface ReportResult {
  ok: boolean
  filed: number
  refused?: string
}

/**
 * What one match actually paid, and BOTH ENDS OF THE BAR.
 *
 * Every number here is evaluated on the server, by BR.Xp, against the lifetime
 * total either side of this match. The page renders them and derives nothing.
 *
 * IT USED TO CARRY ONLY `xp` AND `level`, and the verdict screen worked out
 * where the bar should stop by adding the award to whatever it was showing.
 * That is the whole of #91 and #130: the value it added to had ALREADY been
 * credited by the MARKET_STATE that lands the same tick, so the sum was
 * double-counted; on a level-up it then subtracted the wrong level's span and
 * clamped at zero, which is exactly how a player who gained 1048 XP was shown
 * 0; and it kept the old span as the denominator, so a bar could read
 * "3,472 / 2,450" and never reset.
 */
export interface EarnedPayload {
  xp: number
  volts: number
  /** Level AFTER the match. */
  level: number
  /** XP into that level after the match. Server-derived; do not recompute. */
  into: number
  /** What that level costs. Never zero -- the server floors it at 1. */
  needed: number
  /** Where the bar has to start the fill from: the level, the XP into it, and
   *  its span, all as they were BEFORE this match. */
  fromLevel: number
  fromXp: number
  fromNeeded: number
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
export type CurtainKind = 'leaving' | 'dropping' | 'disconnecting'

/** Which screen currently owns NUI focus. Lua is the authority. */
export interface FocusPayload {
  /** `playersReport` was briefly a member here: the player list held different
   *  focus in its two modes, because report mode had to give up game input for
   *  its note field. View mode gave up game input as well in #135, so the two
   *  modes collapsed into one screen and the name is deleted rather than left
   *  in the union for a value Lua can no longer send. */
  screen: 'none' | 'lobby' | 'squad' | 'inventory' | 'summary' | 'chat'
        | 'settings' | 'locker' | 'market' | 'pause' | 'help'
        | 'players'
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
  // Who is speaking right now: ids for the squad panel's markers, and their
  // names in the SAME ORDER for the bottom-centre indicator. The names have to
  // be on the wire because proximity voice carries anyone in the match, and
  // the interface has no other way to name a player who is not a squadmate.
  | { k: 'voice';    d: VoicePayload }
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
  /** GTA's own menu owns the screen; this page must not draw. Lua is the
   *  authority and holds it true for as long as the frontend is up -- see the
   *  note on BR.Nui.FRONTEND in br_lib/shared/protocol.lua. */
  | { k: 'frontend'; d: { up: boolean } }
  | { k: 'settings'; d: SettingsPayload }
  | { k: 'locker';   d: LockerPayload }
  | { k: 'progress'; d: ProgressPayload }
  | { k: 'market';   d: MarketPayload }
  | { k: 'keybinds'; d: { actions: KeybindAction[]; raw?: boolean } }
  | { k: 'xp';       d: XpAward }
  | { k: 'earned';   d: EarnedPayload }
  | { k: 'players';  d: PlayersPayload }
  | { k: 'report';   d: ReportResult }
  /** A SQUADMATE changed phase, and this is the sound everybody else hears.
   *
   *  NOT IN BR.Nui, deliberately, and it is the one kind here that is not. The
   *  sender (br_core/client/dbno.lua) writes the string literally, next to the
   *  cue table it has to agree with -- adding a constant for it would create a
   *  name with no caller, which is a shape this project has shipped often
   *  enough to have a rule about.
   *
   *  THE SERVER DECIDES THE AUDIENCE. `src` and `name` identify the mate for a
   *  visual that does not exist yet; today only `cue` is read. They are on the
   *  wire because the sender already had them, not because anything wants them.
   */
  | { k: 'squadcue'; d: { cue: Cue; src?: number; name?: string } }

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
  /* `PAUSE` was removed with its Lua callback (#138): it raised GTA's frontend
     without announcing it to this page, and no component ever called it. */
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
  /** The same handover as VOICE_SETTINGS, for a player who wants graphics
   *  rather than a microphone. Separate name so the button can say so. */
  GAME_SETTINGS:  'br/game/settings',
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
