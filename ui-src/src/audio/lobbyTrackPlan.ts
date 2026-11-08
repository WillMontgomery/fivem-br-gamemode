/**
 * THE LOBBY TRACK'S DECISIONS, WITH NO AUDIO IN THEM (#423).
 *
 * The loading screen's song plays on into the lobby, and it must not play past
 * the moment the ped stops walking and the Locker unlocks (owner, 2026-10-30).
 * br_loadscreen posts where its copy is on br_core's exit cue; lobbyTrack.ts
 * starts a copy of its own there and takes it down to silence in time. Every
 * call that takes is made here: whether a message is a handoff to take, where
 * the song should be now, what to do about a copy running off that mark, and
 * when the fade to silence starts and how long it lasts.
 *
 * PURE ON PURPOSE, with no imports at all, so node's type stripping loads it as
 * it is and scripts/test-lobby-track.mjs can pin every decision without a
 * browser -- the shape of musicPlan.ts and test-music.mjs. lobbyTrack.ts asks
 * this file rather than deciding for itself; the two are a pair.
 *
 * TWO CLOCKS, AND WHICH IS WHICH. The handoff is dated on Date.now(), the only
 * clock the two frames share, and readHandoff and tooOld judge it on that.
 * lobbyTrack.ts moves it onto this page's performance.now() as it lands and
 * times everything after on that clock, which no wall-clock resync can step
 * (the fade clock's own reason, ui/fade.ts). Lua's GetGameTimer is neither,
 * which is why Lua sends durations and the pages turn them into times as they
 * arrive. Everything else here takes whichever clock its caller is on, so long
 * as every time in one call is on the same one. The song's own position is in
 * seconds, because <audio>'s currentTime is.
 */

/** The handoff's format, as br_loadscreen/index.html writes it. */
export const HANDOFF_V = 1

/**
 * HOW FAR AHEAD OF THIS PAGE'S CLOCK A HANDOFF MAY BE DATED and still be the
 * one the cue just sent.
 *
 * The loading screen stamps `at` with its own Date.now() and this page reads
 * the age off its own. The two frames are different sites, so they can live in
 * two renderer processes, and two processes can read the wall clock a few
 * milliseconds apart. A strict `age >= 0` would turn away a real handoff
 * whenever this page reads a little behind the loading screen: the feature
 * dead for that join, with nothing in the console. A handoff dated further
 * ahead than this is not ours.
 */
export const SKEW_MS = 50

/**
 * The loading screen's fall at the cue: its copy goes from its level to silent
 * in a straight line over this long (`track.fadeOut(350)` in
 * br_loadscreen/index.html). The seam is this page's copy rising under it.
 */
export const LOADSCREEN_FALL_MS = 350

/**
 * A copy further than this from where the song should be is seeked back onto
 * the mark; inside it, the gap is closed by speed (see alignStep).
 */
export const SEEK_BEYOND_MS = 250

/** A gap this small is left alone: well inside where two copies of one song
 *  stop sounding like one. */
export const DONE_WITHIN_MS = 5

/** Behind the mark, the copy runs 8% fast; ahead of it, 8% slow. */
export const RATE_BEHIND = 1.08
export const RATE_AHEAD = 0.92

/** Back to normal speed once the gap is this small, or crossed. */
export const CLOSED_WITHIN_MS = 2

/** Alignment gives up this long after its first look, whatever is left. */
export const GIVE_UP_MS = 3000

/** The shortest fade to silence: anything shorter is a cut, not a fade. */
export const MIN_FADE_MS = 150

/** The fade when the lobby is uncovered and no deadline is known. */
export const NO_DEADLINE_FADE_MS = 5000

/** THE NET: the Locker unlocked, or the player left the lobby, with the song
 *  still sounding. Whatever is left goes in this. */
export const CUT_MS = 200

const finite = (v: unknown): v is number => typeof v === 'number' && Number.isFinite(v)

/** A handoff taken: numbers and the player's mute, nothing else. */
export interface Handoff {
  /** Where the loading screen's copy was, in seconds into the song. */
  position: number
  /** When it read that, on Date.now(). */
  at: number
  /** When the song must be silent, on Date.now(); null when Lua said nothing. */
  endsAt: number | null
  /** The player's M on the loading screen. */
  muted: boolean
  /** The loading screen's listening level, 0..1. */
  volume: number
}

/**
 * The handoff in a window message's data, or null when it is not one to take.
 *
 * NUMBERS AND THE MUTE, NEVER A URL. Any frame beside this one on FiveM's root
 * page can post to it, so what a message may carry is where the song is, when
 * it ends, how loud, and whether the player muted it -- the five fields of
 * Handoff and nothing more. The track is the page's own
 * (lobbyTrackInstall.ts), whatever a message names.
 *
 * STALE OR FROM THE FUTURE, NOT OURS. The cue's handoff lands as it is sent;
 * one older than maxAgeMs is not it, and neither is one dated more than SKEW_MS
 * ahead of this page's clock.
 *
 * WELL-FORMED OR NOTHING. The sender is br_loadscreen/index.html, in this repo,
 * and it writes every field every time: `endsAt` null when the cue carried no
 * deadline, a number otherwise. A message that disagrees about any of them is
 * not that page's, and turning it away costs a song, never a wrong one.
 */
export function readHandoff(data: unknown, now: number, maxAgeMs: number): Handoff | null {
  if (typeof data !== 'object' || data === null) return null
  const h = (data as { brTrackHandoff?: unknown }).brTrackHandoff
  if (typeof h !== 'object' || h === null) return null
  const { v, position, at, endsAt, muted, volume } = h as Record<string, unknown>
  if (v !== HANDOFF_V) return null
  if (!finite(position) || position < 0) return null
  if (!finite(at)) return null
  if (at - now > SKEW_MS || tooOld(at, now, maxAgeMs)) return null
  if (endsAt !== null && endsAt !== undefined && !finite(endsAt)) return null
  if (typeof muted !== 'boolean') return null
  if (!finite(volume)) return null
  return {
    position,
    at,
    endsAt: finite(endsAt) ? endsAt : null,
    muted,
    volume: volume < 0 ? 0 : volume > 1 ? 1 : volume,
  }
}

/**
 * Was this read longer ago than maxAgeMs? Then it is not the handoff the cue
 * just sent: a post from one frame to its sibling lands in milliseconds.
 */
export function tooOld(at: number, now: number, maxAgeMs: number): boolean {
  return now - at > maxAgeMs
}

/**
 * Has the seam gone by? A copy that starts once the loading screen's has
 * fallen silent comes in out of silence: the lobby starting a song of its own,
 * not carrying one on. So a copy not started by then stays silent, and the song
 * ends at the cue as it did before #423. `at` is the handoff's read.
 */
export function seamLost(at: number, now: number): boolean {
  return now - at > LOADSCREEN_FALL_MS
}

/**
 * Where the song should be now, in seconds.
 *
 * EXACT, NOT CLOSE. The time the message spent in flight -- read off the wall
 * clock both pages share -- and every moment since are added back to the
 * position the loading screen read. `at` and `now` on one clock: lobbyTrack.ts
 * passes the read moved onto its own as the handoff landed.
 */
export function playhead(h: Pick<Handoff, 'position' | 'at'>, now: number): number {
  return h.position + (now - h.at) / 1000
}

/**
 * Has the song already run out at this position? An element put at its end
 * and told to play() starts again from 0:00 -- the one thing this must never
 * do -- so a handoff with no song left stays silent. An unknown length cannot
 * say, and does not stop it.
 */
export function songOver(position: number, durationS: number): boolean {
  return Number.isFinite(durationS) && position >= durationS
}

/**
 * Is this deadline too close to start the song at all? Silence would be due
 * before even the shortest fade could run, so a copy started now would be a
 * blip under the loading screen's own fade-out: better never started.
 */
export function tooLate(endsAt: number, now: number, marginMs: number): boolean {
  return endsAt - marginMs - now < MIN_FADE_MS
}

export type Opening =
  | { op: 'play' }
  | { op: 'silent'; why: 'muted' | 'too late' }

/**
 * What to do with a handoff just taken, given the deadline in force.
 *
 * MUTED STAYS MUTED. The handoff carries the player's choice, not how far a
 * mute's fade had got (br_loadscreen/index.html), so an M pressed just before
 * the cue still counts here.
 */
export function opening(h: Handoff, endsAt: number | null, now: number, marginMs: number): Opening {
  if (h.muted) return { op: 'silent', why: 'muted' }
  if (endsAt !== null && tooLate(endsAt, now, marginMs)) return { op: 'silent', why: 'too late' }
  return { op: 'play' }
}

/**
 * Can this copy's rise run whole before its fade? Yes while the shortest fade,
 * begun as the rise ends, would still be silent marginMs before the deadline.
 *
 * THE CROSSFADE GIVES WAY TO THE DEADLINE, AND TO NOTHING ELSE. The rise is the
 * seam, so a tail that can start after it waits for it. A deadline that cannot
 * -- unlockInMs 0 landing mid-rise -- turns the rise around where it is, and
 * the copy falls from there on planTail's schedule, planned at once. The
 * loading screen's copy is falling too, so the two go down together.
 */
export function riseCanFinish(endsAt: number, riseEndsAt: number, marginMs: number): boolean {
  return !tooLate(endsAt, riseEndsAt, marginMs)
}

export type AlignStep =
  | { op: 'seek' }
  | { op: 'rate'; rate: number }
  | { op: 'done'; why: 'aligned' | 'gave up' }

/**
 * One look at the gap between this copy and where the song should be.
 *
 * `driftMs` is this copy's position less the playhead: negative is behind.
 * `sinceMs` is the time since the first look.
 *
 * CAUGHT UP BY SPEED, NOT BY A SECOND SEEK. A copy that has just started runs
 * behind by its own seek and output start-up (13 to 53 ms, measured in
 * Chromium, the Ogg at the high end), which the loading screen's copy paid
 * long ago; seeking again would only pay it again. So inside SEEK_BEYOND_MS
 * this copy runs 8% fast (or slow), and rateDone WATCHES the gap rather than
 * timing it: a rate change lands late and a decoder warms up, so a computed
 * duration overshoots or falls short (one try left 19 ms of a 53 ms gap).
 *
 * IT LINES UP A COPY THAT IS ALREADY ALONE; IT DOES NOT LINE UP THE SEAM. The
 * first look comes 250 ms into this copy, near the top of its rise
 * (lobbyTrack.ts), and in #423's real-time run (Edge 156, 2026-10-31) the
 * correction ran from about 260 to 700 ms after the cue, at 86 to 100% of the
 * level, most of it after the loading screen's copy had gone silent at 350 ms.
 * So the crossfade is crossed with the two copies apart by this one's
 * start-up -- 10 ms, median, in that run. The same run found currentTime unsteady for
 * about 150 ms after a rate change (it read 18 to 28 ms low), so the loop
 * settles within about 10 ms rather than 2. This is the preview the owner
 * approved (loadscreen-previews/shared/lobby-track.js); whether the seam
 * wants more is for a listen in game, on CEF.
 */
export function alignStep(driftMs: number, sinceMs: number): AlignStep {
  if (!Number.isFinite(driftMs) || sinceMs >= GIVE_UP_MS) return { op: 'done', why: 'gave up' }
  const d = Math.abs(driftMs)
  if (d > SEEK_BEYOND_MS) return { op: 'seek' }
  if (d <= DONE_WITHIN_MS) return { op: 'done', why: 'aligned' }
  return { op: 'rate', rate: driftMs < 0 ? RATE_BEHIND : RATE_AHEAD }
}

/**
 * While a rate runs: back to normal speed now? Yes once the gap has closed to
 * CLOSED_WITHIN_MS or crossed it, and yes when alignment has run out of time.
 */
export function rateDone(driftMs: number, rate: number, sinceMs: number): boolean {
  if (!Number.isFinite(driftMs) || sinceMs >= GIVE_UP_MS) return true
  return rate > 1 ? driftMs >= -CLOSED_WITHIN_MS : driftMs <= CLOSED_WITHIN_MS
}

/** The fade to silence, as offsets from the moment it was planned. */
export interface Tail {
  /** When the fade starts; 0 is at once. */
  startInMs: number
  /** How long it lasts. */
  fadeMs: number
  /** When the hard stop lands, whatever the fade has done by then. */
  stopInMs: number
}

/**
 * The fade to silence before the deadline `endsAt`.
 *
 * THE TAIL ENDS ON THE DEADLINE; IT DOES NOT START ON IT. Silence is due
 * marginMs before endsAt -- timer slop, spent on the safe side -- after a fade
 * tailMs long, or after whatever time is left when that is less, MIN_FADE_MS
 * at the shortest.
 *
 * THE HARD STOP SITS ON endsAt ITSELF, under the fade in case its timer runs
 * late, and never lands before the shortest fade has run. A deadline that is
 * already here -- unlockInMs 0, "the unlock can come at any moment" -- still
 * gets a fade rather than a click, and that fade is shorter than the net's own
 * cut at the unlock.
 */
export function planTail(endsAt: number, now: number, tailMs: number, marginMs: number): Tail {
  const quietIn = endsAt - marginMs - now
  const startIn = quietIn - tailMs
  if (startIn > 0) return { startInMs: startIn, fadeMs: tailMs, stopInMs: endsAt - now }
  const fadeMs = Math.max(MIN_FADE_MS, quietIn)
  return { startInMs: 0, fadeMs, stopInMs: Math.max(endsAt - now, fadeMs) }
}

/**
 * The fade when the lobby is uncovered and nobody has said when the walk-in
 * ends: NO_DEADLINE_FADE_MS from now, so a song with no deadline still goes
 * somewhere sensible instead of playing on to its end. Its stop sits marginMs
 * after the fade, as a deadline's does.
 */
export function fallbackTail(marginMs: number): Tail {
  return { startInMs: 0, fadeMs: NO_DEADLINE_FADE_MS, stopInMs: NO_DEADLINE_FADE_MS + marginMs }
}

/**
 * A duration from now as a deadline on the caller's clock, or null for
 * anything that is not a duration: Lua's unlockInMs, and the cue's endsAt as it
 * lands. A negative one is a deadline already here.
 */
export function deadlineIn(ms: unknown, now: number): number | null {
  if (!finite(ms)) return null
  return now + (ms < 0 ? 0 : ms)
}
