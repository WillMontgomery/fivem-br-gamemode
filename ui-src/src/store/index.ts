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
  SpectatePayload, SquadPayload, StormPayload, SummaryPayload, ToastPayload,
  WireInvPayload,
} from '../bridge/types'

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
  notices: (ToastPayload & { id: number; ms: number })[]
  /** Notices that arrived while the pause menu was open. They display on
   *  unpause -- unless they sat here longer than PAUSE_QUEUE_MS, in which
   *  case the moment has passed and they are dropped silently. */
  pendingNotices: (ToastPayload & { queuedAt: number })[]
  focus: FocusPayload['screen']

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

export const useUi = create<UiState>((set, get) => {
  /** The actual display push: id, self-removal timer, stack cap. Both the
   *  live path and the unpause flush land here, so queued notices get the
   *  same lifetime and animation as ones that never waited. */
  const showNotice = (t: ToastPayload) => {
    const id = ++noticeId
    const ms = t.ms ?? TOAST_MS
    setTimeout(() => {
      set((s) => (s.notices.some((n) => n.id === id)
        ? { notices: s.notices.filter((n) => n.id !== id) }
        : {}))
    }, ms)
    set((s) => ({ notices: [...s.notices, { ...t, id, ms }].slice(-NOTICES_MAX) }))
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
  lobby: null,
  screen: null,
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
      const held = get().pendingNotices
        .filter((p) => now - p.queuedAt <= PAUSE_QUEUE_MS)
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
  setScreen:   (screen) => set((s) => ({
    screen,
    worldReady: screen.worldReady !== undefined ? screen.worldReady : s.worldReady,
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
  pushNotice: (t) => {
    if (get().hud.paused) {
      set((s) => ({
        pendingNotices: [...s.pendingNotices, { ...t, queuedAt: Date.now() }]
          .slice(-NOTICES_MAX),
      }))
      return
    }
    showNotice(t)
  },

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
