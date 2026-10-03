import type { EmoteAudioPayload } from '../bridge/types'
import { planTracks, staleStop, musicGain, type Voice } from './musicPlan'

/**
 * THE EMOTE MUSIC (#215, "Scope v2").
 *
 * Owner, 2026-10-02: "One license-free .ogg per dance, supplied by the owner
 * later." Lua (br_core/client/emotes.lua) sends `emoteaudio` about ten times a
 * second with every dance this player can hear, and this module keeps one
 * looping <audio> per dancer in step with it. Every decision -- start, stop,
 * re-seek, re-gain -- is musicPlan.ts's; this file only does what it says.
 *
 * MODULE STATE, NO REACT. The envelope is fire-and-forget like `squadcue`:
 * nothing on screen reads it, and routing ten payloads a second through the
 * store would re-render its subscribers for a sound (check-ui R20).
 *
 * A MISSING FILE IS THE PATH IN USE TODAY. No starter track exists yet, so the
 * first load of each fails, lands in `missing`, and that dance plays in silence
 * for the rest of the session. It is deliberately NOT reported through
 * reportError: an absent track is the expected state, not a fault, and sixteen
 * of them would bury the errors that are.
 */

interface Playing {
  el: HTMLAudioElement
  track: string
  g: number
  lastTry: number
}

const voices = new Map<number, Playing>()
const missing = new Set<string>()
let volume = 0.5
let lastMsgAt = 0

/** How often a paused voice may retry play(). CEF 103's autoplay policy for
 *  a page nobody clicked is unconfirmed, so a refusal is retried rather than
 *  believed, but not every frame. */
const RETRY_MS = 1000

/** Put an element at `atMs` into its (looping) file, once its length is known. */
function seekTo(el: HTMLAudioElement, atMs: number): void {
  const d = el.duration
  if (!Number.isFinite(d) || d <= 0) return
  el.currentTime = (atMs / 1000) % d
}

function stopOne(src: number): void {
  const v = voices.get(src)
  if (!v) return
  v.el.pause()
  // Dropping the source releases the decoder; pause() alone keeps it.
  v.el.removeAttribute('src')
  v.el.load()
  voices.delete(src)
}

function stopAll(): void {
  for (const src of [...voices.keys()]) stopOne(src)
}

function startOne(src: number, track: string, atMs: number, gain: number, g: number): void {
  const el = new Audio(track)
  el.loop = true
  el.preload = 'auto'
  el.volume = gain
  const v: Playing = { el, track, g, lastTry: performance.now() }
  el.addEventListener('loadedmetadata', () => {
    if (voices.get(src) !== v) return
    seekTo(el, atMs)
    el.play().catch(() => { /* autoplay refused: retried below */ })
  })
  el.addEventListener('error', () => {
    // Asked once per session, then silence. No reportError: see the header.
    missing.add(track)
    if (voices.get(src) === v) voices.delete(src)
  })
  voices.set(src, v)
}

/**
 * The player's "Music volume" slider (Settings, shown only while emotes are
 * on), from applySettings. Re-applied to every voice at once, so a saved
 * change is heard on the dances already playing rather than the next ones.
 */
export function setMusicVolume(v: number): void {
  volume = Number.isFinite(v) ? v : 0
  for (const p of voices.values()) p.el.volume = musicGain(volume, p.g)
}

/** One `emoteaudio` envelope. */
export function syncEmoteTracks(d: EmoteAudioPayload | undefined): void {
  lastMsgAt = performance.now()

  const now: Voice[] = []
  for (const [src, p] of voices) {
    now.push({
      src,
      track: p.track,
      currentMs: p.el.readyState >= 1 ? p.el.currentTime * 1000 : null,
      lengthMs: Number.isFinite(p.el.duration) ? p.el.duration * 1000 : null,
      volume: p.el.volume,
    })
  }

  const tracks: unknown = d?.tracks
  const gOf = new Map<number, number>()
  if (Array.isArray(tracks)) {
    for (const t of tracks as Array<{ src?: unknown; g?: unknown }>) {
      if (typeof t?.src === 'number' && typeof t.g === 'number') gOf.set(t.src, t.g)
    }
  }

  for (const step of planTracks(tracks, now, missing, volume)) {
    switch (step.op) {
      case 'stop':
        stopOne(step.src)
        break
      case 'start':
        startOne(step.src, step.track, step.atMs, step.volume, gOf.get(step.src) ?? 0)
        break
      case 'volume': {
        const p = voices.get(step.src)
        if (p) p.el.volume = step.volume
        break
      }
      case 'seek': {
        const p = voices.get(step.src)
        if (p) seekTo(p.el, step.atMs)
        break
      }
    }
  }

  // The falloff each voice is at, so a slider drag re-gains it correctly.
  for (const [src, p] of voices) p.g = gOf.get(src) ?? p.g

  // A voice the browser refused to start (autoplay) is retried at most once a
  // second, and only once it has enough data to play.
  const t = performance.now()
  for (const p of voices.values()) {
    if (p.el.paused && p.el.readyState >= 2 && t - p.lastTry >= RETRY_MS) {
      p.lastTry = t
      p.el.play().catch(() => { /* retried next second */ })
    }
  }
}

// THE STALE-VOICE WATCHDOG. If the Lua sender dies (BR.Loop suspends a loop
// after five errors) or never sends its final empty list, the music stops after
// a second instead of looping forever.
setInterval(() => {
  if (staleStop(performance.now(), lastMsgAt, voices.size)) stopAll()
}, 500)
