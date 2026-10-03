/**
 * THE EMOTE MUSIC'S DECISIONS, WITH NO AUDIO IN THEM (#215).
 *
 * Owner, 2026-10-02 ("Scope v2"): "One license-free .ogg per dance", heard by
 * the people near the dancer. Lua sends the page `{ tracks }` about ten times a
 * second -- which dance, how far into it, and how loud at this distance -- and
 * this file turns that list plus what is already playing into a list of steps.
 * music.ts applies the steps to real <audio> elements.
 *
 * PURE ON PURPOSE, with type-only imports, so node's type stripping loads it
 * as-is and scripts/test-music.mjs can pin every decision without a browser:
 * what starts, what stops, when a voice has drifted far enough to seek, and
 * when the page gives up on a sender that went quiet. check-ui rule R24 pins
 * that music.ts still asks this file rather than deciding for itself; the two
 * are a pair.
 */

/** A playing voice further than this from where the dance says it should be
 *  is re-seeked. Under it, the correction would be a louder glitch than the
 *  drift. */
export const DRIFT_MS = 250

/** No message for this long while anything plays -> stop everything. Lua sends
 *  ten a second and one empty list at the end; a sender that died (BR.Loop
 *  suspends a loop after five errors) or never sent the empty list must not
 *  leave a dance looping forever. */
export const STALE_MS = 1000

function clamp01(v: number): number {
  if (!Number.isFinite(v)) return 0
  return v < 0 ? 0 : v > 1 ? 1 : v
}

/**
 * The element volume for one voice: the player's music slider on the same
 * squared curve the interface cues use (a linear slider sounds like it does
 * nothing for its top half), times the distance falloff Lua sent.
 */
export function musicGain(volume: number, g: number): number {
  const v = clamp01(volume)
  return clamp01(v * v * clamp01(g))
}

/** Has the sender gone quiet while something is still playing? */
export function staleStop(now: number, lastMsgAt: number, voices: number): boolean {
  return voices > 0 && now - lastMsgAt > STALE_MS
}

/** What music.ts has playing for one dancer, as this file needs to see it. */
export interface Voice {
  src: number
  track: string
  /** Where the element is, or null before its metadata has loaded. */
  currentMs: number | null
  /** The file's length, or null while it is unknown. */
  lengthMs: number | null
  /** The element volume last applied. */
  volume: number
}

export type Step =
  | { op: 'stop'; src: number }
  | { op: 'start'; src: number; track: string; atMs: number; volume: number }
  | { op: 'volume'; src: number; volume: number }
  | { op: 'seek'; src: number; atMs: number }

interface Wanted {
  src: number
  track: string
  pos: number
  g: number
}

/** The usable entries of one message, keyed by src; the last duplicate wins. */
function parse(tracks: unknown): Map<number, Wanted> {
  const out = new Map<number, Wanted>()
  // LUA'S EMPTY TABLE ARRIVES AS `{}`, NOT `[]`, so anything that is not an
  // array is the empty list -- which is also the message that ends the music.
  if (!Array.isArray(tracks)) return out
  for (const t of tracks as unknown[]) {
    if (typeof t !== 'object' || t === null) continue
    const e = t as Record<string, unknown>
    const { src, track, pos, g } = e
    if (typeof src !== 'number' || !Number.isFinite(src)) continue
    if (typeof track !== 'string' || track === '') continue
    if (typeof pos !== 'number' || !Number.isFinite(pos) || pos < 0) continue
    if (typeof g !== 'number' || !Number.isFinite(g)) continue
    out.set(src, { src, track, pos, g })
  }
  return out
}

/**
 * The steps that take `voices` to what `tracks` asks for.
 *
 * A MISSING FILE IS SKIPPED, NEVER RETRIED. Every starter track is absent
 * today, so this is the path in use: the first failed load puts the track in
 * `missing`, and from then on that dance plays in silence for the session.
 *
 * Order is deterministic: stops, then starts, then the volume and seek
 * corrections, ascending src within each group (volume before seek for one
 * src). A track change is a stop and a start for the same src.
 */
export function planTracks(
  tracks: unknown,
  voices: Voice[],
  missing: ReadonlySet<string>,
  volume: number,
): Step[] {
  const wanted = new Map<number, Wanted>()
  for (const [src, w] of parse(tracks)) {
    if (w.g > 0 && !missing.has(w.track)) wanted.set(src, w)
  }

  const bySrc = (a: { src: number }, b: { src: number }) => a.src - b.src
  const stops: Step[] = []
  const starts: Step[] = []
  const fixes: Step[] = []
  const kept = new Map<number, Voice>()

  for (const v of [...voices].sort(bySrc)) {
    const w = wanted.get(v.src)
    if (!w || w.track !== v.track) stops.push({ op: 'stop', src: v.src })
    else kept.set(v.src, v)
  }

  for (const w of [...wanted.values()].sort(bySrc)) {
    const gain = musicGain(volume, w.g)
    const v = kept.get(w.src)
    if (!v) {
      starts.push({ op: 'start', src: w.src, track: w.track, atMs: w.pos, volume: gain })
      continue
    }
    if (Math.abs(gain - v.volume) > 0.01) fixes.push({ op: 'volume', src: w.src, volume: gain })
    if (v.currentMs !== null) {
      // The tracks LOOP, so a dance longer than its file is somewhere inside
      // the file rather than past its end -- and the distance is measured
      // around the loop: an element that has just wrapped to 30 ms while Lua
      // says 9990 ms of a 10 s file is 40 ms behind, not 9960 ms (#215).
      const expected = v.lengthMs ? w.pos % v.lengthMs : w.pos
      const d = Math.abs(expected - v.currentMs)
      const drift = v.lengthMs ? Math.min(d, v.lengthMs - d) : d
      if (drift > DRIFT_MS) {
        fixes.push({ op: 'seek', src: w.src, atMs: w.pos })
      }
    }
  }

  return [...stops, ...starts, ...fixes]
}
