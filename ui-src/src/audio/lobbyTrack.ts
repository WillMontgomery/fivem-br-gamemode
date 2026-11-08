import {
  CUT_MS, alignStep, deadlineIn, fallbackTail, opening, planTail, playhead, rateDone,
  readHandoff, riseCanFinish, seamLost, songOver, tooLate, type Handoff, type Tail,
} from './lobbyTrackPlan'

/**
 * THE LOADING SCREEN'S SONG, CARRIED ON INTO THE LOBBY (#423).
 *
 * The song keeps going through the lobby's walk-in, and it must not play past
 * the moment the ped stops walking and the Locker unlocks (owner, 2026-10-30).
 * br_loadscreen can neither call Lua nor reach this page's store, but it is a
 * sibling frame: on br_core's exit cue it posts
 * `{brTrackHandoff: {v, position, at, endsAt, muted, volume}}` to every frame
 * beside it and fades its own copy out over 350 ms. This starts a copy of its
 * own at the same point and has it silent before the deadline:
 *
 *   the cue's, which the handoff carries as endsAt (Lua's musicEndsInMs);
 *   Lua's exact one, off every 'locker' push that has one (setDeadlineIn),
 *     each replacing the last;
 *   and under both, THE NET: the unlock itself, or the player leaving the
 *     lobby, cuts whatever is still sounding in 200 ms.
 *
 * Every decision is lobbyTrackPlan.ts's; this file does what the plan says to
 * one <audio> element and keeps the timers. NO STORE IN HERE, so
 * scripts/test-lobby-track.mjs can bundle this file alone and drive it on a
 * fake browser. audio/lobbyTrackInstall.ts is the wiring.
 *
 * IT WANTS A FORMAT THAT SEEKS TO THE SAMPLE: Ogg (Vorbis or Opus), WAV, or a
 * constant-bitrate MP3. A variable-bitrate MP3 seeks by estimate and can land
 * tens of milliseconds off.
 */

/** How often a ramp moves the volume: the loading screen's own step. */
const RAMP_STEP_MS = 16
/** The first look at the gap, once the copy has been playing this long. */
const ALIGN_AFTER_MS = 250
/** The next look after a seek, once it has landed and started again. */
const SEEK_SETTLE_MS = 400
/** How often the gap is watched while a rate runs. */
const RATE_WATCH_MS = 25
/** The gap is read once more this long after alignment ends, for the stats. */
const SETTLED_AFTER_MS = 300

/**
 * THIS PAGE'S CLOCK, MONOTONIC. Everything after the handoff lands is timed on
 * it -- the fades, the deadline, the playhead -- because a wall clock resynced
 * mid-song would step a fade back up or hold it open (#423's review stepped it
 * back 2 s mid-tail, and the song rose past the handed level). Date.now() is
 * read only where the handoff lands, to date it against the loading screen's
 * own reading: it is the one clock the two frames share.
 */
const now = (): number => performance.now()

export interface LobbyTrackOptions {
  /** The track. Fetched once, whole, and played from memory. */
  src: string
  /** This copy's rise, under the loading screen's 350 ms fall. Default 300. */
  fadeInMs?: number
  /** The fade to silence before the deadline. Default 5000. */
  tailMs?: number
  /** Silent this long before the deadline, for timer slop. Default 250. */
  marginMs?: number
  /** A handoff older than this is not the one the cue just sent. Default 3000. */
  maxAgeMs?: number
  /** Called once, when the song is silent for good and everything it held has
   *  been let go, with the stats as they ended. */
  onDone?: (stats: LobbyTrackStats) => void
}

export type LobbyTrackPhase =
  /** No handoff yet; the file loads meanwhile. */
  | 'waiting'
  /** A handoff taken; seeking and starting. */
  | 'starting'
  /** Sounding, and rising under the loading screen's fall. */
  | 'rising'
  /** At the handed level; the tail, if one is planned, waits on its timer. */
  | 'playing'
  /** Fading to silence before the deadline. */
  | 'falling'
  /** The net's 200 ms cut. */
  | 'cutting'
  /** Silent for good, and everything it held let go. */
  | 'done'

/**
 * A copy of where the track is and how it got there. Its times are on this
 * page's performance.now(): ms since the page loaded.
 */
export interface LobbyTrackStats {
  phase: LobbyTrackPhase
  /** Why it went silent for good, once it has. */
  why: string | null
  /** The file: still loading, in memory, or failed (and then silent). */
  source: 'loading' | 'memory' | 'failed'
  /** The handed position, s; null until a handoff is taken. */
  handedAt: number | null
  /** How old the handoff was when it landed, ms, on the clock both frames share. */
  flightMs: number | null
  /** The deadline in force; null while none is known. */
  endsAt: number | null
  /** Where the last plan put the start of the fade, ms from that plan. */
  tailStartsInMs: number | null
  /** How many times alignment seeked. */
  seeks: number
  /** The gap at the first look and after alignment, ms; negative is behind. */
  driftBeforeMs: number | null
  driftAfterMs: number | null
  /** When it fell silent. */
  silentAt: number | null
  /** When the Locker unlocked. */
  unlockedAt: number | null
  /** How long before the unlock it was already silent; 0 when the net had to
   *  cut it. Null while there has been no unlock, or nothing sounded. */
  silentBeforeUnlockMs: number | null
  /** The element as it is now -- position (s), volume, rate -- while it exists. */
  position: number | null
  volume: number | null
  rate: number | null
}

export interface LobbyTrack {
  /** A window message. The first valid brTrackHandoff starts the song. */
  onMessage(ev: { data: unknown }): void
  /** Lua's exact deadline, ms from now. Replaces any earlier one and plans
   *  the tail again, canceling whatever tail or stop was already set. */
  setDeadlineIn(ms: number): void
  /** The lobby is uncovered. */
  worldReady(): void
  /** THE NET: the Locker unlocked. */
  unlocked(): void
  /** The player is leaving the lobby. */
  leftLobby(): void
  /** A snapshot, for diagnostics and tests. */
  stats(): LobbyTrackStats
}

/** An option's value, or its default when it is not a duration. */
function msOr(v: number | undefined, dflt: number): number {
  return typeof v === 'number' && Number.isFinite(v) && v >= 0 ? v : dflt
}

/** HTMLMediaElement.volume throws outside 0..1, and NaN is neither. */
const clamp01 = (v: number): number => (v > 0 ? (v < 1 ? v : 1) : 0)

export function createLobbyTrack(opts: LobbyTrackOptions): LobbyTrack {
  const fadeInMs = msOr(opts.fadeInMs, 300)
  const tailMs = msOr(opts.tailMs, 5000)
  const marginMs = msOr(opts.marginMs, 250)
  const maxAgeMs = msOr(opts.maxAgeMs, 3000)

  const st: Omit<LobbyTrackStats, 'position' | 'volume' | 'rate'> = {
    phase: 'waiting',
    why: null,
    source: 'loading',
    handedAt: null,
    flightMs: null,
    endsAt: null,
    tailStartsInMs: null,
    seeks: 0,
    driftBeforeMs: null,
    driftAfterMs: null,
    silentAt: null,
    unlockedAt: null,
    silentBeforeUnlockMs: null,
  }

  let audio: HTMLAudioElement | null = new Audio()
  let blobUrl: string | null = null
  /** The handoff taken, its read moved onto this page's clock as it landed. */
  let handoff: Pick<Handoff, 'position' | 'at'> | null = null
  /** The handoff's level, which this copy rises to. */
  let level = 0
  /** The deadline in force, on this page's clock: the cue's, then each of Lua's. */
  let deadline: number | null = null
  /** worldReady came with no deadline known: the fallback fade is wanted. */
  let fallback = false
  let began = false
  /** When the rise is due to be over. */
  let riseEndsAt = 0
  let alignFrom: number | null = null

  let rampTimer: number | null = null
  let rateTimer: number | null = null
  let tailTimer: number | null = null
  let stopTimer: number | null = null
  const timers = new Set<number>()
  const abort = new AbortController()

  const sounding = (): boolean =>
    st.phase === 'rising' || st.phase === 'playing' || st.phase === 'falling' || st.phase === 'cutting'

  function snapshot(): LobbyTrackStats {
    const a = audio
    return {
      ...st,
      position: a === null ? null : a.currentTime,
      volume: a === null ? null : a.volume,
      rate: a === null ? null : a.playbackRate,
    }
  }

  function later(ms: number, fn: () => void): number {
    const id = window.setTimeout(() => {
      timers.delete(id)
      fn()
    }, Math.max(0, ms))
    timers.add(id)
    return id
  }

  function cancel(id: number | null): null {
    if (id !== null) {
      window.clearTimeout(id)
      timers.delete(id)
    }
    return null
  }

  function stopRamp(): void {
    if (rampTimer !== null) {
      window.clearInterval(rampTimer)
      rampTimer = null
    }
  }

  function stopRate(): void {
    if (rateTimer !== null) {
      window.clearInterval(rateTimer)
      rateTimer = null
    }
  }

  /** A straight line in volume from wherever it is now to `to`, over `ms`. */
  function rampTo(to: number, ms: number, done: () => void): void {
    stopRamp()
    const a = audio
    if (a === null) return
    if (!(ms > 0)) {
      a.volume = clamp01(to)
      done()
      return
    }
    const from = a.volume
    const t0 = now()
    rampTimer = window.setInterval(() => {
      // Clamped as well as monotonic: a line that ran outside its own ends
      // would carry the volume past both of them.
      const k = clamp01((now() - t0) / ms)
      a.volume = clamp01(from + (to - from) * k)
      if (k >= 1) {
        stopRamp()
        done()
      }
    }, RAMP_STEP_MS)
  }

  /**
   * SILENT FOR GOOD: let go of everything. Every timer stops, the element
   * pauses and drops its source -- which releases the decoder, where pause()
   * alone keeps it -- the blob's URL is revoked so its 5.5 MB can go, and a
   * fetch still in flight is aborted.
   */
  function release(why: string): void {
    if (st.phase === 'done') return
    if (sounding() && st.silentAt === null) st.silentAt = Math.round(now())
    st.phase = 'done'
    st.why = why
    stopRamp()
    stopRate()
    for (const id of timers) window.clearTimeout(id)
    timers.clear()
    tailTimer = null
    stopTimer = null
    abort.abort()
    const a = audio
    audio = null
    if (a !== null) {
      a.volume = 0
      a.playbackRate = 1
      a.pause()
      a.removeAttribute('src')
      a.load()
    }
    if (blobUrl !== null) {
      URL.revokeObjectURL(blobUrl)
      blobUrl = null
    }
    opts.onDone?.(snapshot())
  }

  // THE WHOLE FILE IN MEMORY, BECAUSE THE HANDOFF IS A SEEK. A media file is
  // seekable only when its server answers range requests, and FiveM's NUI
  // file handler does not: it always answers 200 with the whole file, so
  // Chromium treats a cfx-nui audio URL as a stream it cannot seek. A blob
  // always can, so the file is fetched once and played from memory -- and
  // NEVER from the plain URL as a fallback, which would start the song at
  // 0:00 in the middle of a fade. A fetch that fails is a song that stays
  // silent: the loading screen's copy fades at the cue as it always did.
  const el = audio
  el.preload = 'auto'
  el.volume = 0
  // THE SONG PLAYS ONCE, like the loading screen's copy: its fade-in and
  // fade-out are mixed into the file, so it does not loop.
  el.addEventListener('ended', () => release('the song ended'))
  el.addEventListener('error', () => release('the file would not play'))

  void fetch(opts.src, { signal: abort.signal })
    .then((r) => {
      if (!r.ok) throw new Error(`HTTP ${r.status}`)
      return r.blob()
    })
    .then((b) => {
      if (st.phase === 'done' || audio === null) return
      blobUrl = URL.createObjectURL(b)
      audio.src = blobUrl
      st.source = 'memory'
      whenReady()
    }, (e: unknown) => {
      if (st.phase === 'done') return
      st.source = 'failed'
      release(`the file did not load (${e instanceof Error ? e.message : String(e)})`)
    })

  /** Start once the handoff is taken AND the file is in memory with its metadata. */
  function whenReady(): void {
    const a = audio
    if (st.phase !== 'starting' || a === null || blobUrl === null || began) return
    if (a.readyState >= 1) begin()
    else a.addEventListener('loadedmetadata', begin, { once: true })
  }

  function begin(): void {
    const a = audio
    const h = handoff
    if (st.phase !== 'starting' || a === null || h === null || began) return
    began = true
    const t = now()
    // A file that came in late can find the seam gone, or the deadline.
    if (seamLost(h.at, t)) {
      release('the file was ready after the seam')
      return
    }
    if (deadline !== null && tooLate(deadline, t, marginMs)) {
      release('the walk-in was over before the file was ready')
      return
    }
    const at = playhead(h, t)
    if (songOver(at, a.duration)) {
      release('the song was already over')
      return
    }
    a.currentTime = at
    a.addEventListener('playing', rise, { once: true })
    a.play().catch((e: unknown) => {
      release(`play refused (${e instanceof Error ? e.name : String(e)})`)
    })
  }

  // THE SEAM IS A CROSSFADE BETWEEN TWO COPIES OF ONE MOMENT. The loading
  // screen's copy falls in a straight line over 350 ms from the cue, and this
  // one rises in a straight line over fadeInMs. Straight, both of them: two
  // in-phase copies sum flat only when both fades are.
  //
  // TO THE LOADING SCREEN'S LEVEL, NOT THE MUSIC SLIDER'S. The handoff carries
  // the level its copy was playing at, and the two copies have to match
  // through the crossfade or the seam is a step in loudness. volMusic is the
  // emote music's slider, a different sound, and nothing the player set on
  // the loading screen ever reached it.
  function rise(): void {
    if (st.phase !== 'starting') return
    st.phase = 'rising'
    riseEndsAt = now() + fadeInMs
    rampTo(level, fadeInMs, () => {
      if (st.phase !== 'rising') return
      st.phase = 'playing'
      plan()
    })
    later(ALIGN_AFTER_MS, look)
    // A deadline already known that cannot wait out the rise turns it now.
    plan()
  }

  /**
   * Plan the tail from the deadline in force, or the fallback fade, canceling
   * whatever tail or stop was set. Once the rise is over, as a rule: the
   * crossfade runs whole, and the plan made at its end counts from there. A
   * deadline that cannot wait for it (riseCanFinish) is planned at once, and
   * the copy falls from wherever the rise had got to.
   */
  function plan(): void {
    if (st.phase === 'rising') {
      if (deadline === null || riseCanFinish(deadline, riseEndsAt, marginMs)) return
    } else if (st.phase !== 'playing' && st.phase !== 'falling') {
      return
    }
    let t: Tail | null = null
    if (deadline !== null) t = planTail(deadline, now(), tailMs, marginMs)
    else if (fallback) t = fallbackTail(marginMs)
    if (t === null) return
    tailTimer = cancel(tailTimer)
    stopTimer = cancel(stopTimer)
    st.tailStartsInMs = Math.round(t.startInMs)
    const fadeMs = t.fadeMs
    if (t.startInMs > 0) {
      // A LATER DEADLINE MID-FADE HOLDS THE LEVEL WHERE IT HAS GOT TO, and the
      // fade starts again from there on the new time. The song never comes
      // back up once it has started down.
      if (st.phase === 'falling') {
        stopRamp()
        st.phase = 'playing'
      }
      tailTimer = later(t.startInMs, () => {
        tailTimer = null
        fall(fadeMs)
      })
    } else {
      fall(fadeMs)
    }
    stopTimer = later(t.stopInMs, () => {
      stopTimer = null
      release(deadline !== null ? 'stopped at the deadline' : 'stopped at the end of the fade')
    })
  }

  function fall(ms: number): void {
    if (st.phase !== 'rising' && st.phase !== 'playing' && st.phase !== 'falling') return
    st.phase = 'falling'
    rampTo(0, ms, () => {
      release(deadline !== null ? 'faded out before the deadline' : 'faded out, no deadline known')
    })
  }

  /** The 200 ms cut. True when something was sounding to cut. */
  function cut(why: string, before: string): boolean {
    if (st.phase === 'starting') {
      release(before)
      return false
    }
    if (st.phase !== 'rising' && st.phase !== 'playing' && st.phase !== 'falling') return false
    tailTimer = cancel(tailTimer)
    stopTimer = cancel(stopTimer)
    st.phase = 'cutting'
    rampTo(0, CUT_MS, () => release(why))
    return true
  }

  /** This copy's position less where the song should be, ms; NaN when unknown. */
  function gap(): number {
    const a = audio
    const h = handoff
    if (a === null || h === null) return NaN
    return (a.currentTime - playhead(h, now())) * 1000
  }

  // PULLED INTO LINE ON THE SAME CLOCK. A copy that has just started runs
  // behind by its own start-up, so once it is playing it is measured against
  // the playhead and caught up -- by speed inside SEEK_BEYOND_MS, by a seek
  // beyond it. lobbyTrackPlan.ts alignStep says which, and what this does and
  // does not buy the seam.
  function look(): void {
    const a = audio
    const h = handoff
    if (a === null || h === null || !sounding() || st.phase === 'cutting') return
    const t = now()
    if (alignFrom === null) alignFrom = t
    const from = alignFrom
    const d = gap()
    if (st.driftBeforeMs === null && Number.isFinite(d)) st.driftBeforeMs = Math.round(d)
    const step = alignStep(d, t - from)
    if (step.op === 'seek') {
      st.seeks++
      a.currentTime = playhead(h, now())
      later(SEEK_SETTLE_MS, look)
      return
    }
    if (step.op === 'done') {
      settled()
      return
    }
    const rate = step.rate
    a.playbackRate = rate
    rateTimer = window.setInterval(() => {
      if (!rateDone(gap(), rate, now() - from)) return
      stopRate()
      if (audio !== null) audio.playbackRate = 1
      settled()
    }, RATE_WATCH_MS)
  }

  function settled(): void {
    later(SETTLED_AFTER_MS, () => {
      const d = gap()
      if (Number.isFinite(d)) st.driftAfterMs = Math.round(d)
    })
  }

  return {
    onMessage(ev) {
      if (st.phase !== 'waiting') return
      const wall = Date.now()
      const h = readHandoff(ev.data, wall, maxAgeMs)
      if (h === null) return
      // ONTO THIS PAGE'S CLOCK AS IT LANDS: the read, and the cue's deadline.
      // The flight between the frames is the one span measured on Date.now().
      const t = now()
      const read = t - (wall - h.at)
      handoff = { position: h.position, at: read }
      level = h.volume
      st.handedAt = h.position
      st.flightMs = wall - h.at
      // The cue's deadline is the newest word, if it has one; if it has none,
      // one Lua already sent stands.
      if (h.endsAt !== null) deadline = deadlineIn(h.endsAt - wall, t)
      st.endsAt = deadline === null ? null : Math.round(deadline)
      const o = opening(h, deadline, t, marginMs)
      if (o.op === 'silent') {
        release(o.why === 'muted' ? 'muted on the loading screen' : 'the walk-in was already over')
        return
      }
      // Fresh enough to be the cue's, and still too late to carry the song:
      // the loading screen's copy has fallen silent (begin() asks the same of
      // a file that comes in late).
      if (seamLost(read, t)) {
        release('the handoff landed after the seam')
        return
      }
      st.phase = 'starting'
      whenReady()
    },

    setDeadlineIn(ms) {
      if (st.phase === 'done' || st.phase === 'cutting') return
      const t = now()
      const at = deadlineIn(ms, t)
      if (at === null) return
      deadline = at
      st.endsAt = Math.round(at)
      if (st.phase === 'starting' && tooLate(at, t, marginMs)) {
        release('the walk-in was over before the song started')
        return
      }
      plan()
    },

    // AT A BOOT THE HANDOFF LANDS ABOUT A SECOND BEFORE THIS, so a track with
    // none by now has none coming, and it lets go of the file. One that has a
    // song and no deadline fades it out over NO_DEADLINE_FADE_MS from here,
    // after the rise if the rise is still running; a deadline that comes
    // later still replaces that.
    worldReady() {
      if (st.phase === 'waiting') {
        release('no handoff before worldReady')
        return
      }
      if (st.phase === 'done' || st.phase === 'cutting' || deadline !== null || fallback) return
      fallback = true
      plan()
    },

    unlocked() {
      const t = Math.round(now())
      if (st.unlockedAt === null) st.unlockedAt = t
      if (st.silentBeforeUnlockMs === null) {
        if (st.silentAt !== null) st.silentBeforeUnlockMs = t - st.silentAt
        else if (sounding()) st.silentBeforeUnlockMs = 0
      }
      cut('cut at the unlock', 'the Locker unlocked before the song started')
    },

    leftLobby() {
      cut('cut as the player left the lobby', 'the player left the lobby before the song started')
    },

    stats: snapshot,
  }
}
