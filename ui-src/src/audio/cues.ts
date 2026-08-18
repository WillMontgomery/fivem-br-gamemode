/**
 * OUR OWN SOUNDS.
 *
 * Everything the player hears from the interface is synthesised here, in the
 * browser, from oscillators and filtered noise. Not one of these is a GTA
 * frontend sound.
 *
 * WHY NOT GTA'S. The engine's frontend sounds are the sound of GTA Online's
 * menus. Every player who has spent an hour in that game recognises them
 * instantly, and hearing them here does not read as "polished", it reads as
 * "this is a GTA menu" -- which is exactly the association a standalone game
 * mode is trying not to make. They are also fixed: no volume control, no
 * variation, and no way to make a Legendary pickup sound different from a
 * Common one.
 *
 * WHAT STAYS NATIVE. Per-bullet combat feedback, and only that. `PlaySoundFrontend`
 * is mixed by the engine, so a hitmarker ducks correctly against gunfire; the
 * same sound fired from CEF sits on top of a firefight at full volume forever.
 * That is a real advantage and it only matters for cues that fire during
 * shooting. Menus, verdicts and full-screen moments have nothing to duck
 * against, so they are ours.
 *
 * THE DESIGN RULES, arrived at by getting them wrong first:
 *
 *   * NOTHING ARPEGGIATES AND NOTHING WALKS A SCALE. Stepped diatonic runs are
 *     what make a cue sound like a platformer, and they carry a key, so they
 *     fight whatever music is playing. Partials are STRUCK together and use
 *     INHARMONIC (bell-like) ratios, so there is no major or minor and
 *     therefore no tune.
 *   * MEANING IS CARRIED BY BRIGHTNESS, NOT MELODY. A filter opening = gained,
 *     forward, acquired. A filter closing = lost, back, refused.
 *   * `select` and `back` are pulled far apart -- high/crisp/short against
 *     low/soft/longer. An earlier cut made them the same note with opposite
 *     filter sweeps, which is elegant on paper and indistinguishable in
 *     practice.
 *
 * AUTOPLAY. Browsers -- CEF included -- refuse to start an AudioContext until
 * the page has been interacted with. The context is created lazily on the first
 * cue and resumed on the first pointer event, so the first sound a player
 * triggers is the one that unlocks it.
 */

let ctx: AudioContext | null = null
let master: GainNode | null = null
let volume = 0.7

/** Lazily create the graph. Returns null when Web Audio is unavailable. */
function ac(): AudioContext | null {
  if (ctx) {
    if (ctx.state === 'suspended') void ctx.resume()
    return ctx
  }
  const C = window.AudioContext
    ?? (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext
  if (!C) return null
  ctx = new C()
  master = ctx.createGain()
  master.gain.value = gainFor(volume)
  master.connect(ctx.destination)
  return ctx
}

/**
 * THE UNLOCK, and why the lobby only made a sound *sometimes*.
 *
 * A context created outside a user gesture starts SUSPENDED, and `resume()` is
 * asynchronous. Creating it lazily inside the first `play()` therefore loses
 * that first cue and any that land in the millisecond or two before the resume
 * settles -- so hovering a button made a noise, or did not, depending on
 * whether anything had unlocked the context yet. The result feels like a flaky
 * sound system rather than a missing one, which is much harder to report.
 *
 * Fixed by resuming from a real input event, once, before any cue is asked
 * for. `pointerdown` and `keydown` both count as gestures; the listeners
 * remove themselves.
 */
function unlock() {
  const a = ac()
  if (a && a.state === 'suspended') void a.resume()
  window.removeEventListener('pointerdown', unlock)
  window.removeEventListener('keydown', unlock)
}
if (typeof window !== 'undefined') {
  window.addEventListener('pointerdown', unlock)
  window.addEventListener('keydown', unlock)
}

/**
 * HEADROOM, AND A CURVE.
 *
 * The slider used to be the gain directly, which gave the top of the range a
 * ceiling of 1.0 and no way past it -- so a client that is quiet for any
 * reason outside this file (a multi-channel output that mixes CEF into one
 * speaker, a different device, the engine's own mix) could not be turned up
 * (user, 2026-08-09: "really quiet on one client... changing the volume does
 * nothing").
 *
 * Two changes. The slider is now SQUARED, which is much closer to how loudness
 * is actually perceived -- a linear gain slider spends most of its travel in a
 * range that all sounds the same. And full is 2.0, not 1.0, so the top of the
 * slider has somewhere to go. Nothing clips: every cue peaks well under 0.3
 * and they are short.
 */
const MAX_GAIN = 2.0

function gainFor(v: number): number {
  const x = Math.max(0, Math.min(1, v))
  return x * x * MAX_GAIN
}

export function setUiVolume(v: number) {
  volume = Math.max(0, Math.min(1, v))
  if (!master || !ctx) return
  // setTargetAtTime rather than an assignment: a jumped gain on a graph that
  // is mid-cue is an audible click, and a slider makes a lot of small jumps.
  master.gain.setTargetAtTime(gainFor(volume), ctx.currentTime, 0.01)
}

/**
 * What the audio graph actually is, for a client that sounds wrong.
 *
 * Printed to the console rather than shown, because the person who needs it is
 * looking at F8 and comparing two machines. Sample rate and channel count are
 * the two things that differ between clients and neither is visible any other
 * way.
 */
export function soundReport(): Record<string, unknown> {
  const a = ac()
  return {
    context: a ? a.state : 'unavailable',
    sampleRate: a?.sampleRate ?? null,
    channels: a?.destination.channelCount ?? null,
    maxChannels: a?.destination.maxChannelCount ?? null,
    slider: volume,
    gain: master ? master.gain.value : null,
  }
}

interface VoiceOpts {
  f: number
  /** Glide target. */
  f2?: number
  type?: OscillatorType
  len?: number
  /** Peak gain. */
  g?: number
  /** Attack, seconds. A slow attack removes the stab from a swell. */
  atk?: number
  /** Start offset, seconds. */
  at?: number
  /** Lowpass cutoff, and its sweep target. Brightness is the expressive axis. */
  lp?: number
  lp2?: number
  q?: number
  det?: number
}

function voice(o: VoiceOpts) {
  const a = ac()
  if (!a || !master) return
  const t0 = a.currentTime + (o.at ?? 0)
  const len = o.len ?? 0.1

  const osc = a.createOscillator()
  const g = a.createGain()
  osc.type = o.type ?? 'sine'
  osc.frequency.setValueAtTime(o.f, t0)
  if (o.f2) osc.frequency.exponentialRampToValueAtTime(Math.max(1, o.f2), t0 + len)
  if (o.det) osc.detune.setValueAtTime(o.det, t0)

  const peak = o.g ?? 0.25
  g.gain.setValueAtTime(0.0001, t0)
  g.gain.exponentialRampToValueAtTime(peak, t0 + (o.atk ?? 0.006))
  g.gain.exponentialRampToValueAtTime(0.0001, t0 + len)

  osc.connect(g)
  if (o.lp) {
    const f = a.createBiquadFilter()
    f.type = 'lowpass'
    f.Q.value = o.q ?? 0.7
    f.frequency.setValueAtTime(o.lp, t0)
    if (o.lp2) f.frequency.exponentialRampToValueAtTime(Math.max(60, o.lp2), t0 + len)
    g.connect(f)
    f.connect(master)
  } else {
    g.connect(master)
  }
  osc.start(t0)
  osc.stop(t0 + len + 0.02)
}

function noise(o: {
  hz?: number; type?: BiquadFilterType; len?: number; g?: number; at?: number
}) {
  const a = ac()
  if (!a || !master) return
  const t0 = a.currentTime + (o.at ?? 0)
  const len = o.len ?? 0.06

  const buf = a.createBuffer(1, Math.ceil(a.sampleRate * len), a.sampleRate)
  const d = buf.getChannelData(0)
  for (let i = 0; i < d.length; i++) d[i] = Math.random() * 2 - 1

  const src = a.createBufferSource()
  src.buffer = buf
  const f = a.createBiquadFilter()
  f.type = o.type ?? 'highpass'
  f.frequency.value = o.hz ?? 1400
  const g = a.createGain()
  g.gain.setValueAtTime(o.g ?? 0.2, t0)
  g.gain.exponentialRampToValueAtTime(0.0001, t0 + len)

  src.connect(f); f.connect(g); g.connect(master)
  src.start(t0); src.stop(t0 + len)
}

/** Struck-metal partials. Inharmonic on purpose: no key, so no tune. */
const BELL = [1, 2.02, 2.79, 4.13, 5.42]
/** Open stack -- fifths and octaves, no third, so it has no mood to clash. */
const FIFTHS = [1, 1.5, 2, 3, 4]

function struck(root: number, o: {
  ratios?: number[]; n?: number; type?: OscillatorType; len?: number
  g?: number; atk?: number; at?: number; lp?: number; lp2?: number; q?: number
} = {}) {
  const set = o.ratios ?? BELL
  const n = o.n ?? set.length
  for (let i = 0; i < n && i < set.length; i++) {
    voice({
      f: root * set[i]!,
      type: o.type ?? 'triangle',
      len: (o.len ?? 0.5) * (1 - i * 0.07),
      g: (o.g ?? 0.12) / (1 + i * 0.55),
      atk: o.atk ?? 0.006,
      at: o.at ?? 0,
      lp: o.lp, lp2: o.lp2, q: o.q,
      det: i ? (i % 2 ? 7 : -7) : 0,
    })
  }
}

export type Cue =
  | 'ui.hover' | 'ui.select' | 'ui.back' | 'ui.toggle' | 'ui.ready' | 'ui.error'
  | 'loot' | 'loot.rare' | 'loot.legendary'
  | 'elim' | 'downed' | 'storm.phase' | 'victory' | 'defeat'
  // WHAT HAPPENED TO SOMEBODY ELSE ON YOUR SQUAD. The names are written
  // literally in br_core/client/dbno.lua's MATE_CUE table, which is the only
  // thing that sends them; if you rename one here, rename it there.
  | 'squad.down' | 'squad.out' | 'squad.revived'

const CUES: Record<Cue, () => void> = {
  'ui.hover':  () => { noise({ hz: 5200, type: 'bandpass', len: 0.028, g: 0.055 }) },

  // Pulled a long way from `back`: high, crisp, 65ms, filter opening.
  'ui.select': () => {
    noise({ hz: 6500, type: 'highpass', len: 0.018, g: 0.11 })
    voice({ f: 660, type: 'triangle', len: 0.065, g: 0.15, lp: 1600, lp2: 7000, q: 1.5 })
  },
  // Low, soft, 150ms, filter closing. Different on pitch, register, waveform,
  // length AND direction -- not just the sweep.
  'ui.back':   () => {
    noise({ hz: 600, type: 'lowpass', len: 0.045, g: 0.09 })
    voice({ f: 150, type: 'sine', len: 0.15, g: 0.22, lp: 1200, lp2: 260, q: 1.1 })
  },
  'ui.toggle': () => {
    noise({ hz: 3000, type: 'bandpass', len: 0.026, g: 0.1 })
    voice({ f: 330, type: 'square', len: 0.035, g: 0.05, lp: 2400 })
  },
  // A struck open stack plus air. Confident, and with no third it has no mood
  // to fight whatever is playing behind it.
  'ui.ready':  () => {
    struck(110, { ratios: FIFTHS, type: 'sawtooth', len: 0.85, g: 0.15, atk: 0.012, lp: 600, lp2: 6000 })
    noise({ hz: 2600, type: 'bandpass', len: 0.7, g: 0.05, at: 0.02 })
    voice({ f: 55, type: 'sine', len: 0.9, g: 0.22 })
  },
  'ui.error':  () => {
    voice({ f: 98, type: 'sawtooth', len: 0.22, g: 0.13, lp: 900, lp2: 180 })
    voice({ f: 98, det: 22, type: 'sawtooth', len: 0.22, g: 0.11, lp: 900, lp2: 180 })
  },

  // LOOT ASCENDS BY RARITY, across pickups and never within one cue. A warm
  // harmonic body with a short decay -- bell partials ring like glass, which
  // is literally how you synthesise a wine glass.
  'loot':           () => lootCue(0),
  'loot.rare':      () => lootCue(2),
  'loot.legendary': () => lootCue(4),

  // PERCUSSIVE, NOT MUSICAL. A kill should not ring: a crack, a body that
  // pitches down and lands, sub weight, short tail.
  'elim': () => {
    noise({ hz: 5200, type: 'highpass', len: 0.045, g: 0.24 })
    voice({ f: 240, f2: 62, type: 'sawtooth', len: 0.3, g: 0.32, lp: 3000, lp2: 380 })
    voice({ f: 48, type: 'sine', len: 0.55, g: 0.36 })
    voice({ f: 120, type: 'square', len: 0.2, g: 0.09, lp: 1500 })
    noise({ hz: 800, type: 'bandpass', len: 0.34, g: 0.11, at: 0.02 })
  },
  'downed': () => {
    struck(82, { n: 3, type: 'sawtooth', len: 0.65, g: 0.17, lp: 1800, lp2: 160 })
    noise({ hz: 300, type: 'lowpass', len: 0.5, g: 0.12, at: 0.04 })
  },

  // ── THE SQUAD SET ─────────────────────────────────────────────────────────
  //
  // ABOUT SOMEBODY ELSE, AND THEY HAVE TO SOUND LIKE IT. `downed` above is what
  // the player who went down hears; these are what the rest of the squad hears,
  // and the server picks the audience so the subject never gets one. If a mate
  // going down sounded like YOU going down, the first thing every player would
  // do is check their own health -- so the family is the same struck stack an
  // octave up, at about two thirds the level, and shorter. Related, clearly not
  // yours.
  //
  // THE THREE READ AS ONE PROGRESSION BY BRIGHTNESS, which is this file's whole
  // expressive axis: down closes part-way, out closes to nothing and goes
  // lower, revived opens. No pitch walks, no arpeggios, no third anywhere, so
  // none of them carries a key.

  // Part-way closed, and short. Something happened and it is not over.
  'squad.down': () => {
    struck(164, { n: 3, type: 'triangle', len: 0.42, g: 0.1, lp: 2400, lp2: 520 })
    noise({ hz: 500, type: 'lowpass', len: 0.3, g: 0.07, at: 0.03 })
  },

  // Closed to nothing, lower, longer. The same gesture finishing.
  'squad.out': () => {
    struck(110, { n: 3, type: 'sawtooth', len: 0.85, g: 0.12, lp: 2000, lp2: 120 })
    voice({ f: 55, type: 'sine', len: 0.9, g: 0.14, atk: 0.02 })
    noise({ hz: 380, type: 'lowpass', len: 0.6, g: 0.08, at: 0.05 })
  },

  // OPEN, and the only one of the three that is. Fifths rather than bell
  // partials, for the same reason `ui.ready` uses them -- an open stack reads
  // as resolved without having a mood to fight the music. Deliberately much
  // shorter and higher than `victory`: getting a mate back up is good news in
  // the middle of a fight, not the end of the match.
  'squad.revived': () => {
    struck(147, { ratios: FIFTHS, type: 'triangle', len: 0.6, g: 0.1, atk: 0.008, lp: 900, lp2: 7000 })
    noise({ hz: 4200, type: 'bandpass', len: 0.45, g: 0.03, at: 0.03 })
  },

  // ~3s, NO pitch movement anywhere and no closing hit -- it swells and is
  // left hanging, which is what makes it read as a challenge rather than as an
  // announcement that has finished speaking.
  'storm.phase': () => {
    struck(36.7, { ratios: FIFTHS, type: 'sawtooth', len: 3.0, g: 0.24, atk: 0.45, lp: 220, lp2: 2600, q: 1.1 })
    voice({ f: 36.7, type: 'sine', len: 3.1, g: 0.3, atk: 0.4 })
    noise({ hz: 300, type: 'bandpass', len: 2.4, g: 0.075, at: 0.2 })
    noise({ hz: 1200, type: 'bandpass', len: 1.6, g: 0.065, at: 1.3 })
    noise({ hz: 3200, type: 'bandpass', len: 1.1, g: 0.05, at: 2.05 })
  },

  // Victory and defeat are the SAME struck stack. One throws its filter wide
  // open and rings; the other closes down to nothing. Triumph and loss as
  // brightness, not as up and down.
  'victory': () => {
    struck(110, { ratios: FIFTHS, type: 'sawtooth', len: 2.2, g: 0.16, atk: 0.015, lp: 700, lp2: 9000 })
    voice({ f: 55, type: 'sine', len: 2.4, g: 0.22 })
    noise({ hz: 5200, type: 'bandpass', len: 1.8, g: 0.035, at: 0.06 })
    struck(220, { ratios: BELL, n: 4, type: 'triangle', len: 1.9, g: 0.07, at: 0.1, lp: 2000, lp2: 11000 })
  },
  'defeat': () => {
    struck(110, { ratios: FIFTHS, type: 'sawtooth', len: 1.8, g: 0.15, atk: 0.02, lp: 5000, lp2: 130 })
    voice({ f: 55, type: 'sine', len: 2.0, g: 0.18 })
    noise({ hz: 600, type: 'lowpass', len: 1.4, g: 0.09, at: 0.05 })
  },
}

/** Roots step up a tier at a time. The rise happens ACROSS pickups. */
const LOOT_ROOT = [196, 233, 277, 330, 392]
function lootCue(tier: number) {
  const root = LOOT_ROOT[Math.max(0, Math.min(4, tier))]!
  voice({ f: root, type: 'triangle', len: 0.2 + tier * 0.03, g: 0.17, atk: 0.005, lp: 1100 + tier * 900, q: 0.9 })
  voice({ f: root * 2, type: 'sine', len: 0.16 + tier * 0.03, g: 0.075 + tier * 0.01, atk: 0.005 })
  voice({ f: root * 1.5, type: 'sine', len: 0.14 + tier * 0.02, g: 0.045 + tier * 0.008, atk: 0.006 })
  voice({ f: root / 2, type: 'sine', len: 0.22 + tier * 0.04, g: 0.1 + tier * 0.012 })
  noise({ hz: 1400 + tier * 500, type: 'bandpass', len: 0.035, g: 0.09 })
  if (tier >= 3) noise({ hz: 2600, type: 'bandpass', len: 0.28, g: 0.03, at: 0.05 })
}

/** Rate limits, ms. Hover fires on every pointer crossing. */
const MIN_GAP: Partial<Record<Cue, number>> = { 'ui.hover': 45 }
const lastAt: Partial<Record<Cue, number>> = {}

/** Play an interface cue. Unknown or throttled cues are dropped, never queued. */
export function play(cue: Cue) {
  const gap = MIN_GAP[cue]
  if (gap) {
    const now = Date.now()
    if (now - (lastAt[cue] ?? -Infinity) < gap) return
    lastAt[cue] = now
  }
  CUES[cue]?.()
}

/** Every cue name, for the audition screen and for tests. */
export const CUE_NAMES = Object.keys(CUES) as Cue[]
