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
  InvPayload, InvitePayload, LobbyPayload, MatchPayload, SpectatePayload, SquadPayload,
  StormPayload, SummaryPayload, ToastPayload,
} from '../bridge/types'

/** Kill feed and chat are capped so a long match cannot grow the DOM forever. */
const FEED_MAX = 8
const CHAT_MAX = 60

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
  toast: (ToastPayload & { id: number }) | null
  focus: FocusPayload['screen']

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
  setInv: (i: InvPayload) => void
  setStorm: (s: StormPayload) => void
  setDbno: (d: DbnoPayload) => void
  setSpectate: (s: SpectatePayload | null) => void
  setSummary: (s: SummaryPayload | null) => void
  setFocus: (f: FocusPayload['screen']) => void
  setLobby: (l: LobbyPayload) => void
  setInvite: (i: InvitePayload) => void
  clearInvite: () => void
  pushFeed: (f: FeedEntry) => void
  pushChat: (c: ChatMessage) => void
  showToast: (t: ToastPayload) => void
  openChat: (channel: ChatMessage['channel']) => void
  closeChat: () => void
  hydrate: (s: {
    match: MatchPayload; hud: HudPayload; squad: SquadPayload
    inv: InvPayload; storm: StormPayload | null; chat: ChatMessage[]
  }) => void
}

const emptyMatch: MatchPayload = {
  state: 'waiting', mode: 'solo', endsAt: 0, serverNow: 0,
}
const emptyHud: HudPayload = {
  hp: 100, armour: 0, alive: 0, squadsAlive: 0, kills: 0, state: 'lobby',
}
const emptyInv: InvPayload = {
  slots: [null, null, null, null, null], ammo: {}, active: 1,
}
const emptyDbno: DbnoPayload = {
  downed: false, bleedEndsAt: 0, reviverName: null, revivePct: 0,
}

let toastId = 0
let toastTimer: ReturnType<typeof setTimeout> | null = null

/** How long a toast stays up when the sender does not specify. */
const TOAST_MS = 4000

export const useUi = create<UiState>((set) => ({
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
  toast: null,
  focus: 'none',
  lobby: null,
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
  setHud:      (hud) => set({ hud }),
  setSquad:    (squad) => set({ squad }),
  setInv:      (inv) => set({ inv }),
  setStorm:    (storm) => set({ storm }),
  setDbno:     (dbno) => set({ dbno }),
  setSpectate: (spectate) => set({ spectate }),
  setSummary:  (summary) => set({ summary }),
  setFocus:    (focus) => set({ focus }),
  setLobby:    (lobby) => set({ lobby }),
  setInvite:   (invite) => set({ invite }),
  clearInvite: () => set({ invite: null }),

  pushFeed: (entry) => set((s) => ({
    feed: [entry, ...s.feed].slice(0, FEED_MAX),
  })),

  pushChat: (msg) => set((s) => ({
    chat: [...s.chat, msg].slice(-CHAT_MAX),
  })),

  // Toasts expire on their own. Without this they were sticky: "Invite sent."
  // stayed on the lobby panel indefinitely, so the next thing you did looked
  // like it had produced no response at all.
  //
  // The timer is module-level rather than per-toast so a newer toast cancels
  // the older one's expiry -- otherwise the first toast's timeout would clear
  // the second one early.
  showToast: (t) => {
    const id = ++toastId
    if (toastTimer) clearTimeout(toastTimer)
    toastTimer = setTimeout(() => {
      toastTimer = null
      set((s) => (s.toast?.id === id ? { toast: null } : {}))
    }, t.ms ?? TOAST_MS)
    set({ toast: { ...t, id } })
  },

  openChat:  (chatChannel) => set({ chatOpen: true, chatChannel }),
  closeChat: () => set({ chatOpen: false }),

  hydrate: (s) => set({
    match: s.match,
    hud: s.hud,
    squad: s.squad,
    inv: s.inv,
    storm: s.storm,
    chat: s.chat.slice(-CHAT_MAX),
  }),
}))

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
