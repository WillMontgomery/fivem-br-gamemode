/**
 * UI state.
 *
 * Zustand with selector subscriptions, deliberately not React Context: Context
 * re-renders every consumer in the subtree on any change, and this store updates
 * ten times a second during a match.
 *
 * Everything here is a MIRROR of server state. Nothing in the UI decides who is
 * alive, what the storm is doing, or whether a hit landed.
 */

import { create } from 'zustand'
import type {
  ChatMessage, DbnoPayload, FeedEntry, FocusPayload, HudPayload,
  InvPayload, InvitePayload, LobbyPayload, MatchPayload, ScreenPayload,
  SpectatePayload, SquadPayload, StormPayload, SummaryPayload,
  SettingsPayload, ToastPayload, WireInvPayload,
} from '../bridge/types'
import { applySettings, DEFAULT_SETTINGS } from '../settings/apply'

/** Kill feed and chat are capped so a long match cannot grow the DOM forever. */
const FEED_MAX = 8
const CHAT_MAX = 60

/** How long a kill-feed entry lives. KillFeed times its fade to this. */
export const FEED_TTL_MS = 7000

export interface UiState {
  match: MatchPayload
  hud: HudPayload
  squad: SquadPayload
  inv: InvPayload
  storm: StormPayload | null
  dbno: DbnoPayload
  spectate: SpectatePayload | null
  summary: SummaryPayload | null
  feed: FeedEntry[]
  chat: ChatMessage[]
  /** The on-screen notice stack: party events, action results, match alerts.
   *  Newest last; each expires on its own timer. `ms` is that timer, kept on
   *  the notice so the fly-in/fade-out animation can match it exactly. */
  notices: (ToastPayload & {
    id: number
    ms: number
    /** How many times this notice has fired. Rendered as xN from 2 up. */
    count: number
    /** Its removal timer, so a coalesced repeat can reset the clock. */
    timer: number
  })[]
  /** Notices that arrived while the pause menu was open. They display on
   *  unpause -- unless they sat here longer than PAUSE_QUEUE_MS, in which
   *  case the moment has passed and they are dropped silently. */
  pendingNotices: (ToastPayload & { queuedAt: number })[]
  focus: FocusPayload['screen']

  /** The player's preferences, as Lua last confirmed them. Never written
   *  optimistically: a save round-trips and this is set from the ECHO, so a
   *  value the game clamped visibly snaps rather than sitting here as a
   *  number that was never stored. */
  settings: SettingsPayload
  /** Whether the settings screen is up. Local to the page -- Lua is told, so
   *  it can grant the cursor, but the screen is not Lua's to own. */
  settingsOpen: boolean

  /** Real screen metrics from the game -- including the minimap rectangle the
   *  bars, chat and notices anchor to. Null in the browser dev harness until
   *  the mock provides one. */
  screen: ScreenPayload | null

  /** Whether the game world is streamed in behind the lobby. Carried by the
   *  screen envelope but stored SEPARATELY with a boot-safe default: in game
   *  this starts FALSE, so the menu can only ever appear on a genuine
   *  worldReady=true -- sent exactly once, at the boot choreography's flip.
   *  Defaulting true raced the ready-handshake envelope and produced the
   *  filmed appear/vanish/reappear flap (2026-08-04). Dev harness starts
   *  true: the browser has no world to wait for. */
  worldReady: boolean
  /** True while a sniper scope scaleform is up. The HUD hides for it and only
   *  for it -- aiming a pistol draws no overlay, so blanking the interface
   *  would just cost the player their health bar in a fight. */
  scoped: boolean

  /** True from the moment ESC is pressed in the lobby until Lua hands the
   *  lobby its focus back after the pause menu closes -- the menu fades out
   *  under GTA's pause screen and back in afterwards. */
  pauseHiding: boolean

  /** True while the voluntary-leave interstitial covers the screen: black
   *  plus a quiet "Leaving the match" while the world swaps underneath. */
  leaving: boolean

  /** Queue progress while WAITING. Null until the server reports. */
  lobby: LobbyPayload | null

  /**
   * serverNow - Date.now(), captured whenever the server reports its clock.
   *
   * Every `endsAt` in this app is a server GetGameTimer value, which shares no
   * origin with the browser's wall clock -- the raw difference between them is
   * meaningless. Countdowns must be computed against Date.now() + clockOffset.
   */
  clockOffset: number

  /** A pending party invite. Expires server-side, so it is transient here too. */
  invite: InvitePayload | null

  /** True while the chat input is open; the HUD dims slightly to make it readable. */
  chatOpen: boolean
  chatChannel: ChatMessage['channel']

  setMatch: (m: MatchPayload) => void
  setHud: (h: HudPayload) => void
  setSquad: (s: SquadPayload) => void
  setInv: (i: WireInvPayload) => void
  setStorm: (s: StormPayload | null) => void
  setDbno: (d: DbnoPayload) => void
  setSpectate: (s: SpectatePayload | null) => void
  setSummary: (s: SummaryPayload | null) => void
  setFocus: (f: FocusPayload['screen']) => void
  setPauseHiding: (v: boolean) => void
  setLeaving: (v: boolean) => void
  setLobby: (l: LobbyPayload) => void
  setScreen: (s: ScreenPayload) => void
  setInvite: (i: InvitePayload) => void
  clearInvite: () => void
  pushFeed: (f: FeedEntry) => void
  pushChat: (c: ChatMessage) => void
  pushNotice: (t: ToastPayload) => void
  setSettings: (s: SettingsPayload) => void
  setSettingsOpen: (open: boolean) => void
  openChat: (channel: ChatMessage['channel']) => void
  closeChat: () => void
  hydrate: (s: {
    match: MatchPayload; hud: HudPayload; squad: SquadPayload
    inv: WireInvPayload; storm: StormPayload | null; chat: ChatMessage[]
  }) => void
}

const emptyMatch: MatchPayload = {
  state: 'waiting', mode: 'solo', endsAt: 0, serverNow: 0,
}
const emptyHud: HudPayload = {
  hp: 100, armour: 0, alive: 0, squadsAlive: 0, kills: 0, state: 'lobby',
}
const emptyInv: InvPayload = {
  slots: [null, null, null, null, null], ammo: {}, active: 1, using: null,
}

/** Lua sends an empty slot as `false` (nil does not survive serialisation in an
 *  array, and slot POSITION is the whole model). Spell it one way from here on. */
function normaliseInv(d: WireInvPayload): InvPayload {
  return {
    slots: (d.slots ?? []).map((s) => (s ? s : null)),
    ammo: d.ammo ?? {},
    active: d.active ?? 1,
    using: d.using ?? null,
  }
}
const emptyDbno: DbnoPayload = {
  downed: false, bleedEndsAt: 0, reviverName: null, revivePct: 0,
}

let noticeId = 0

/** How long a notice stays up when the sender does not specify. */
const TOAST_MS = 4000

/** The stack is capped: a burst (whole party leaving at once) must not build a
 *  wall of text over the game. Oldest fall off first. */
const NOTICES_MAX = 5

/** How long a notice may wait out a pause before it stops being news. */
const PAUSE_QUEUE_MS = 30_000

/** The longest a notice may live. A sender that forgets to clear a sticky
 *  notice must not be able to park a line on the player's screen for the rest
 *  of the match -- so `sticky` means "outlives its own event", not "forever". */
const STICKY_MAX_MS = 10 * 60_000

/** Grace after an endsAt countdown lands, so the row is not yanked away on the
 *  same frame the number reaches zero. */
const COUNTDOWN_TAIL_MS = 900

export const useUi = create<UiState>((set, get) => {
  /**
   * The actual display push. Both the live path and the unpause flush land
   * here, so a queued notice gets the same lifetime and animation as one that
   * never waited.
   *
   * FOUR PATHS, IN THIS ORDER, AND THE ORDER MATTERS:
   *
   *   1. `clear` -- a verb. Remove the keyed notice and stop.
   *   2. keyed and already on screen -- UPDATE IN PLACE. Same row, same id,
   *      new text/tone/deadline, no fly-in and no x2. An update is one event
   *      changing state, not the same event twice, and animating it as an
   *      arrival makes a countdown look like a stutter.
   *   3. keyless and the same TEXT is on screen -- coalesce and count.
   *   4. otherwise -- a new row.
   *
   * Path 3 is the old behaviour and it stays, because most notices in this
   * game are fire-and-forget and giving every one of them a key would be
   * ceremony for nothing. Four ammo pickups is still one line reading x4.
   */
  const showNotice = (t: ToastPayload) => {
    // 1. Withdrawal.
    //
    // With no key this is THE BROOM: every persistent notice, and only those.
    // Lua fires it when the player lands back in the lobby, because a sticky
    // notice describes a state that is still true and none of them are once
    // the match is behind you -- and a player who leaves mid-flight walks out
    // from under whichever sender was going to withdraw its own. It cannot
    // swallow an unread event, because an event always has an expiry and this
    // only touches the ones that do not.
    if (t.clear) {
      const doomed = t.key
        ? get().notices.filter((n) => n.key === t.key)
        : get().notices.filter((n) => n.sticky)
      if (doomed.length === 0) return
      doomed.forEach((n) => window.clearTimeout(n.timer))
      set((s) => ({ notices: s.notices.filter((n) => !doomed.includes(n)) }))
      return
    }

    // A COUNTDOWN'S DEADLINE IS ITS LIFETIME. Sending both `endsAt` and a
    // shorter `ms` would leave the row showing a number that never reaches
    // zero, which reads as a frozen interface rather than as a notice that
    // left early. The deadline wins.
    //
    // `endsAt` is a SERVER timestamp; clockOffset is what makes it comparable
    // to Date.now(). Getting this wrong does not look like a clock bug, it
    // looks like every countdown being wildly wrong or already expired.
    const untilDeadline = t.endsAt != null
      ? Math.max(0, t.endsAt - (Date.now() + get().clockOffset)) + COUNTDOWN_TAIL_MS
      : null
    const ms = t.sticky
      ? STICKY_MAX_MS
      : untilDeadline ?? t.ms ?? TOAST_MS

    const arm = (id: number) => window.setTimeout(() => {
      set((s) => (s.notices.some((n) => n.id === id)
        ? { notices: s.notices.filter((n) => n.id !== id) }
        : {}))
    }, ms)

    // 2. Update in place.
    if (t.key) {
      const live = get().notices.find((n) => n.key === t.key)
      if (live) {
        window.clearTimeout(live.timer)
        const timer = arm(live.id)
        set((s) => ({
          notices: s.notices.map((n) => (n.id === live.id
            ? { ...n, ...t, id: live.id, ms, timer, count: n.count }
            : n)),
        }))
        return
      }
    }

    // 3. Coalesce repeats.
    //
    // Three ammo pickups in two seconds is ONE notice reading x3, not three
    // lines racing each other off the top of the stack. Without this, a burst
    // of loot evicts everything else -- including a storm warning, which is a
    // gameplay bug wearing a UI costume.
    if (!t.key) {
      const existing = get().notices.find((n) => !n.key && n.text === t.text)
      if (existing) {
        window.clearTimeout(existing.timer)
        const timer = arm(existing.id)
        set((s) => ({
          notices: s.notices.map((n) => (n.id === existing.id
            ? { ...n, count: (n.count ?? 1) + 1, ms, timer }
            : n)),
        }))
        return
      }
    }

    // 4. A new row.
    const id = ++noticeId
    const timer = arm(id)

    set((s) => {
      const next = [...s.notices, { ...t, id, ms, count: 1, timer }]
      if (next.length <= NOTICES_MAX) return { notices: next }
      // PRIORITY PUSHES, IT DOES NOT QUEUE. When the stack is full the oldest
      // COSMETIC notice is evicted, never a warning and never a persistent
      // one -- losing "the storm is closing" behind three loot pickups is
      // exactly the failure the cap was meant to prevent, and a sticky notice
      // is describing a state that is still true, so it cannot be "old news".
      //
      // next.length > NOTICES_MAX here, so next[0] always exists -- but the
      // compiler cannot know that from `find`, and asserting is cheaper than
      // pretending the array might be empty.
      const evictable = (n: typeof next[number]) =>
        !n.sticky && n.endsAt == null && n.tone !== 'warn' && n.tone !== 'danger'
      const victim = next.find(evictable) ?? next[0]!
      window.clearTimeout(victim.timer)
      return { notices: next.filter((n) => n !== victim) }
    })
  }

  return {
  match: emptyMatch,
  hud: emptyHud,
  squad: { id: null, members: [] },
  inv: emptyInv,
  storm: null,
  dbno: emptyDbno,
  spectate: null,
  summary: null,
  feed: [],
  chat: [],
  notices: [],
  pendingNotices: [],
  focus: 'none',
  settings: DEFAULT_SETTINGS,
  settingsOpen: false,
  lobby: null,
  screen: null,
  scoped: false,
  worldReady: import.meta.env.DEV,
  pauseHiding: false,
  leaving: false,
  invite: null,
  clockOffset: 0,
  chatOpen: false,
  chatChannel: 'global',

  // The state payload is the only regular carrier of the server clock, so the
  // offset is refreshed here. Transitions are infrequent, but drift over a
  // 45-second warmup is far below one second -- well inside what a countdown
  // rounded to whole seconds can show.
  setMatch: (match) => set(
    match.serverNow
      ? { match, clockOffset: match.serverNow - Date.now() }
      : { match }
  ),
  // Unpausing flushes the notice queue: whatever arrived under the pause
  // menu shows now -- except entries older than PAUSE_QUEUE_MS, whose
  // moment has passed (user call, 2026-08-04).
  setHud: (hud) => {
    const wasPaused = get().hud.paused
    if (wasPaused && !hud.paused) {
      const now = Date.now()
      // A STICKY NOTICE CANNOT GO STALE, because it is not describing
      // something that happened -- it is describing something that is still
      // true. "You are outside the storm" is not less relevant for having
      // been raised while the map was up. Events age out; state does not.
      const held = get().pendingNotices
        .filter((p) => p.sticky || now - p.queuedAt <= PAUSE_QUEUE_MS)
      set({ hud, pendingNotices: [] })
      held.forEach(({ queuedAt: _dropped, ...t }) => showNotice(t))
      return
    }
    set({ hud })
  },
  setSquad:    (squad) => set({ squad }),
  setInv:      (inv) => set({ inv: normaliseInv(inv) }),
  // Normalised at the boundary: an empty or shapeless payload (a nil that
  // crossed the Lua bridge becomes {}) must read as "no storm", never as a
  // storm whose every field is undefined.
  setStorm:    (storm) => set({ storm: storm && storm.phase != null ? storm : null }),
  setDbno:     (dbno) => set({ dbno }),
  setSpectate: (spectate) => set({ spectate }),
  setSummary:  (summary) => set({ summary }),
  setFocus:    (focus) => set({ focus }),
  setPauseHiding: (pauseHiding) => set({ pauseHiding }),
  setLeaving: (leaving) => set({ leaving }),
  setLobby:    (lobby) => set({ lobby }),
  // THE SCOPE FLAG NEVER TOUCHES THE METRICS.
  //
  // Two senders share this envelope: the 1Hz publish carries the full minimap
  // rectangle, and the scope watcher sends `{ scoped }` alone the instant it
  // changes. Merging that one-field message into `screen` was enough to break
  // the layout -- if it arrived while `screen` was still null it created an
  // object with a scoped flag and NO rectangle, so every panel anchored to
  // --map-* fell back to the document origin and the inventory bar rendered in
  // the top-left before snapping down (user, 2026-08-08).
  //
  // So `scoped` is lifted out and stored on its own, and `screen` is only
  // touched by a payload that actually carries metrics. `width` is the tell:
  // the metrics publish always sends it and the scope watcher never does.
  setScreen:   (screen) => set((s) => ({
    screen: screen.width !== undefined
      ? ({ ...(s.screen ?? {}), ...screen } as typeof s.screen)
      : s.screen,
    worldReady: screen.worldReady !== undefined ? screen.worldReady : s.worldReady,
    scoped: screen.scoped !== undefined ? screen.scoped : s.scoped,
  })),
  setInvite:   (invite) => set({ invite }),
  clearInvite: () => set({ invite: null }),

  // Feed entries expire like notices do: the component fades them at the
  // same deadline, so removal lands as opacity reaches zero. Before this,
  // eliminations sat in the corner for the rest of the match.
  pushFeed: (entry) => {
    setTimeout(() => {
      set((s) => (s.feed.some((f) => f.id === entry.id)
        ? { feed: s.feed.filter((f) => f.id !== entry.id) }
        : {}))
    }, FEED_TTL_MS)
    set((s) => ({ feed: [entry, ...s.feed].slice(0, FEED_MAX) }))
  },

  pushChat: (msg) => set((s) => ({
    chat: [...s.chat, msg].slice(-CHAT_MAX),
  })),

  // Notices stack instead of replacing each other. The single-slot version
  // meant two events in quick succession -- "Kestrel joined" then "Rook
  // declined" -- showed only the second, and the first might as well never
  // have happened. Each notice removes ITSELF by id, so an expiring older
  // notice can never take a newer one down with it.
  //
  // While the pause menu is open, notices QUEUE instead of showing: the
  // fullscreen map is not a place for toasts. The queue is bounded like the
  // live stack; the unpause flush in setHud decides what is still worth
  // saying.
  // IDENTITY APPLIES TO THE QUEUE TOO. A keyed notice that updates itself
  // twice a second -- a countdown, a revive progress line -- would otherwise
  // fill the pause queue with thirty copies of itself and flush every one of
  // them on unpause, evicting everything that actually happened while the map
  // was up. Keyed entries REPLACE their predecessor in the queue, and a clear
  // takes both the queued copy and any live row with it.
  pushNotice: (t) => {
    if (get().hud.paused) {
      if (t.key) {
        set((s) => {
          const rest = s.pendingNotices.filter((p) => p.key !== t.key)
          return {
            pendingNotices: t.clear
              ? rest
              : [...rest, { ...t, queuedAt: Date.now() }].slice(-NOTICES_MAX),
          }
        })
        // A clear still has to reach the live stack: a sticky notice raised
        // before the pause is on screen underneath it.
        if (t.clear) showNotice(t)
        return
      }
      set((s) => ({
        pendingNotices: [...s.pendingNotices, { ...t, queuedAt: Date.now() }]
          .slice(-NOTICES_MAX),
      }))
      return
    }
    showNotice(t)
  },

  // APPLIED HERE, not in a component effect. A component that applies
  // settings only applies them while it is mounted -- and the settings screen
  // is the one component guaranteed NOT to be mounted for most of the
  // session. Lua pushes on every br:ui:ready, which is also what re-applies
  // the player's scale after br_ui restarts mid-match.
  setSettings: (settings) => {
    applySettings(settings)
    set({ settings })
  },
  setSettingsOpen: (settingsOpen) => set({ settingsOpen }),

  openChat:  (chatChannel) => set({ chatOpen: true, chatChannel }),
  closeChat: () => set({ chatOpen: false }),

  hydrate: (s) => set({
    match: s.match,
    hud: s.hud,
    squad: s.squad,
    inv: normaliseInv(s.inv),
    storm: s.storm,
    chat: s.chat.slice(-CHAT_MAX),
  }),
  }
})

// Selectors. Components subscribe to the narrowest slice they need so a hud
// update at 10 Hz does not re-render the chat log.
export const selHud      = (s: UiState) => s.hud
export const selStorm    = (s: UiState) => s.storm
export const selMatch    = (s: UiState) => s.match
export const selSquad    = (s: UiState) => s.squad
export const selInv      = (s: UiState) => s.inv
export const selFeed     = (s: UiState) => s.feed
export const selChat     = (s: UiState) => s.chat
export const selDbno     = (s: UiState) => s.dbno
export const selFocus    = (s: UiState) => s.focus
export const selChatOpen = (s: UiState) => s.chatOpen
export const selLobby    = (s: UiState) => s.lobby
export const selNotices  = (s: UiState) => s.notices
export const selScreen   = (s: UiState) => s.screen
export const selSettings = (s: UiState) => s.settings
