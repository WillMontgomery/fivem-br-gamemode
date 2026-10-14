/**
 * WHERE THE SECONDS GO ON THE FIRST ACTION AFTER AN IDLE (#252, round 4).
 *
 * Owner, 2026-10-13: "I leave the page open on literally anything, wait a few
 * minutes, then select some element on the page ... The action it performs
 * ... happens and the sound plays instantly, as expected - but the UI reaction
 * itself ... takes several seconds. This gets worse the longer I let my PC sit
 * between actions."
 *
 * Measured on his PC the same day: across the lag neither browser process uses
 * CPU, and the GPU process faults in ~18 MB and lets it go ~10 s later. So the
 * browser WAITS, and this splits the wait. One F8 line per cold action, dev
 * mode only (br_ui/client/idle.lua composes and prints it):
 *
 *   [br_ui] cold <total>ms after <idle>s idle: input->handler A,
 *     handler->commit B, commit->rAF C, rAF->next rAF D, msg arrival lag E
 *     | by <input or push> | lua <Lua's own stamps> | <the page's evidence>
 *
 * THE MARKS, on the page clock (performance.now), and A + B + C + D = total:
 *
 *   start    the input event's own timeStamp (the click), or for a change Lua
 *            pushed with no input, the push's arrival
 *   handler  the action's call to Lua (THE ACTION below), or the input's
 *            listener when the page answered with no call; a push's arrival
 *   commit   THE REACTION: the last DOM change the action's pushes or input
 *            made before the DOM went quiet for QUIET_MS -- not the first:
 *            a Locker pick shows a loading ring at once and the new choice
 *            only with the push after the model loads
 *   rAF      the first animation frame after that change; `next rAF` the one
 *            after it. A frame the GPU process cannot finish holds the next
 *            one back, so a cold draw shows as C or D.
 *
 *   E        the two message legs alone: handler -> the arrival of the push
 *            the reaction landed with, less Lua's own work between the call
 *            and that push (Lua knows it; idle.lua narrows E). A part of B.
 *
 * WHAT COUNTS AS IDLE: no input (pointerdown, pointerup, click, keydown) for
 * COLD_IDLE_MS. DOM changes do not reset it -- a screen with a ticking clock
 * still gets its line, and the line says how long the DOM had been still, so
 * it can refute the leading suspect as well as point at it. An input that came
 * to nothing (no call, no change) does not reset it either. With no input, a
 * change after COLD_IDLE_MS of no input AND no DOM change is a line of its own
 * (a push, or the page's own clock); the next input ends it.
 *
 * THE ACTION is the first call to Lua made in an input's own task (or within
 * FETCH_AFTER_INPUT_MS of one, for a handler that awaits first). Until the
 * window has a call or a change, the input it came from is whichever one made
 * it (an Alt-tab back, then the click). A call of another name takes the window over while the
 * action has changed nothing (a drag-spin, then a pick); once it has, that
 * call ends the reaction instead (a new action, warm, not measured). The same
 * name again is counted (`later`, so Lua picks the right stamp): a re-click.
 *
 * CAUSES: a DOM change is a push's when it lands in that push's task, or in a
 * task its handlers queued before the task ended (React's deferred render);
 * an input's when it lands in the input's task; otherwise it is a later task
 * (a timer, the page's own clock). Only pushes and inputs make the reaction;
 * when there are none, the first later-task change after the call stands in,
 * and says so.
 *
 * THE EVIDENCE: push->commit (the page's own time from the push to the
 * change), the frame's main-thread work, commit->presented (an Element Timing
 * marker; self-tested once when the probe is armed, so "n/a" and "?" are told
 * apart), the first change when it is another (with its own frames -- the
 * first frame after the idle), the frame clock after the input, the first
 * pointer move after the idle (a hover repaints before the click), long tasks,
 * heap, how long the DOM had been still, the changes, and the envelopes after
 * the call with their largest burst.
 *
 * AND THE SWITCHES (each off by default, each a dev F8 command in idle.lua):
 *
 *   paint  every N ms a real frame: `raster` repaints a 1 px near-transparent
 *          dot (raster + draw in the GPU process), `comp` flips the opacity of
 *          a dot on its own layer (draw, no raster), `raf` only asks for an
 *          animation frame (the frame clock, no damage -- the clean control).
 *          raster and comp both keep the GPU process's drawing context busy,
 *          so if both take the lag away it is that process's idle cleanup,
 *          not raster against draw.
 *   warm   every N ms re-render the whole tree with nothing changed. Render
 *          functions only: no handler, no dispatch, no DOM change, no frame --
 *          so a lag that stays with it on does not clear cold JavaScript.
 *
 * NOTHING RUNS UNTIL LUA ARMS IT: the page installs no listener, observer,
 * timer or tap until a `diag` envelope says so, and a `diag` envelope is sent
 * only in dev mode.
 *
 * NO RUNTIME IMPORTS, so node runs this file as-is (scripts/test-cold.mjs). The
 * browser half -- the real listeners, the dot, the store -- is bridge/diag.ts.
 */

// ── the thresholds ──────────────────────────────────────────────────────────

/** No input for this long, and the next one is cold. */
export const COLD_IDLE_MS = 30_000
/** A call this long after an input, outside its task, is not that input's action. */
export const FETCH_AFTER_INPUT_MS = 1_000
/** The reaction is over once the DOM has been still this long after its last change. */
export const QUIET_MS = 5_000
/** How long after the call a change can still be the reaction (and a window waits for one). */
export const COLD_COMMIT_MS = 15_000
/** How long a change waits for its two frames. */
export const COLD_FRAMES_MS = 15_000
/** How long a change, past its second frame, waits for its presentation time. */
export const COLD_PRESENT_MS = 15_000
/** How long the self-test waits for its marker's entry. */
export const SELFTEST_MS = 15_000
/** The self-test's Element Timing id. */
export const SELFTEST_ID = 'brcold-self'
/** Long tasks kept for the line. */
export const LONGTASK_KEEP = 64
/** Envelopes after the call kept for the line (the count goes on). */
export const ENV_KEEP = 256
/** A burst: envelopes landing within this of each other. */
export const BURST_MS = 20

/** The paint heartbeat's bounds and default (below Skia's 1 s idle purge). */
export const PAINT_MIN_MS = 100
export const PAINT_MAX_MS = 60_000
export const PAINT_DEFAULT_MS = 500
/** The keep-warm heartbeat's bounds and default. */
export const WARM_MIN_MS = 500
export const WARM_MAX_MS = 60_000
export const WARM_DEFAULT_MS = 5_000

export type PaintMode = 'raster' | 'comp' | 'raf'
export const PAINT_MODES: readonly PaintMode[] = ['raster', 'comp', 'raf']

export type InputKind = 'pointerdown' | 'pointerup' | 'click' | 'keydown'
/** What the listeners hear: the inputs, and pointer moves (evidence, never activity). */
export type ListenKind = InputKind | 'pointermove'

// ── what Lua says (the `diag` envelope) ─────────────────────────────────────

export interface PaintCfg { ms: number; mode: PaintMode }

export interface DiagState {
  /** The cold line is armed. */
  cold: boolean
  paint: PaintCfg | null
  /** The keep-warm period, or null when off. */
  warm: number | null
}

export const DIAG_OFF: DiagState = { cold: false, paint: null, warm: null }

function inRange(v: unknown, lo: number, hi: number): v is number {
  return typeof v === 'number' && Number.isFinite(v) && v >= lo && v <= hi
}

/**
 * Read a `diag` envelope. ANYTHING NOT SAID IS OFF: a missing, malformed or
 * out-of-range field leaves its switch off, never on at a default.
 */
export function parseDiag(d: unknown): DiagState & { ask: number | null } {
  const o = (d !== null && typeof d === 'object' ? d : {}) as Record<string, unknown>
  const p = (o.paint !== null && typeof o.paint === 'object' ? o.paint : null) as Record<string, unknown> | null
  const paint = p && inRange(p.ms, PAINT_MIN_MS, PAINT_MAX_MS) && PAINT_MODES.includes(p.mode as PaintMode)
    ? { ms: p.ms, mode: p.mode as PaintMode } : null
  return {
    cold: o.cold === true,
    paint,
    warm: inRange(o.warm, WARM_MIN_MS, WARM_MAX_MS) ? o.warm : null,
    ask: typeof o.ask === 'number' ? o.ask : null,
  }
}

// ── the cold tracker ────────────────────────────────────────────────────────

export interface InputStamp { kind: InputKind; ts: number; run: number }
export interface Msg { s: number; k: string; t: number }

/** What made a DOM change, known only when it landed in that input's or push's task. */
export type Cause = { input: InputStamp; push: null } | { input: null; push: Msg } | null

/** A change (or an input, or a pointer move) and the frames after it. */
export interface Watch {
  /** Its Element Timing marker, '' when it has none. */
  id: string
  at: number
  raf1: number | null
  /** The MessageChannel posted from the first frame landed (that frame's main-thread work done). */
  work: number | null
  raf2: number | null
  presented: number | null
  /** Measure the first frame's work. */
  probe: boolean
}

export type WindowKind = 'input' | 'push' | 'page'

/** One cold action, from the input (or push) that opened it to its reaction's frames. */
export interface ColdWindow {
  kind: WindowKind
  opened: number
  /** No input for this long before it (a push or page window: and no DOM change). */
  idleMs: number
  /** How long the DOM had been still when it opened; `stillSinceArm` when it had not changed since arming. */
  stillMs: number
  stillSinceArm: boolean
  /** The input kind that led to the handler, or `lua <kind> #<seq>` / `page`. */
  by: string
  /** The input event's timeStamp, when there was an input and it is on this clock. */
  inputTs: number | null
  handler: number | null
  /** The action's callback, '' when none. */
  cb: string
  /** Calls of `cb` after the measured one (re-clicks, a drag's stream): Lua counts back by it. */
  later: number
  /** Of those, made in an input's own task. */
  reclicks: number
  inputs: number
  /** A callback this one took the window over from (it had changed nothing). */
  tookOver: string
  /** A call of another name after the reaction began: nothing after it is the reaction. */
  frozen: { at: number; cb: string } | null
  /** A push or page window ended by an input. */
  cut: number | null
  /** A push with no input: the envelope's sequence. */
  cause: number
  /** The first pointer move after the idle, the input's own frames, the first change, the reaction. */
  hover: Watch | null
  wake: Watch | null
  first: Watch | null
  firstVia: string
  reaction: Watch | null
  reactionVia: string
  /** The push the reaction landed with (`pushSame`), or for a later-task change the last push before it. */
  push: Msg | null
  pushSame: boolean
  /** The reaction landed in a push's or an input's task. */
  attributed: boolean
  /** The reaction is the page's own answer before any call; a call replaces it. */
  provisional: boolean
  changes: number
  /** Changes in later tasks (timers, the page's clock), not the reaction's. */
  laterTask: number
  /** Changes a push made before the action's call: not the action's. */
  preCall: number
  /** Changes past the window (after `frozen`, or COLD_COMMIT_MS after the call). */
  ignored: number
  /** Envelopes after the handler, at absolute page times, and how many in all. */
  envs: Msg[]
  envCount: number
  /** The input idle clock before this window, put back if it comes to nothing. */
  idleFrom: number
  /** Nothing came of it: no line, and the idle goes on. */
  dropped: boolean
}

export interface ColdTracker {
  readonly window: ColdWindow | null
  readonly lastInputAt: number
  readonly lastChangeAt: number | null
  setPresentable(on: boolean): void
  /** An input listener ran (capture phase). */
  input(kind: InputKind, ts: number, now: number): void
  /** A pointer move. True when it is the first after an idle (and wants frames). */
  move(now: number): boolean
  /** fetchNui started; `cause` is the task it runs in. */
  fetch(name: string, now: number, cause: Cause): void
  envelope(s: number, k: string, now: number): void
  /** A DOM change (not the probe's own); `cause` is the task it landed in. */
  change(now: number, cause: Cause): void
  /** An animation frame. True when a watch took it as its first and wants the work probe. */
  frame(now: number): boolean
  /** The work probe posted from the last frame landed. */
  work(now: number): void
  /** A presentation time for a marker. True when it is a watched change's. */
  presented(id: string, renderTime: number): boolean
  needsFrame(): boolean
  /** Is a window ready to hand over? */
  due(now: number): boolean
  /** When to look again: now when due, null when nothing is waiting. */
  wakeAt(now: number): number | null
  /** The next finished window, or null. */
  take(now: number): ColdWindow | null
  /** Markers to add and take away since the last drain. */
  drain(): { mark: string[]; unmark: string[] }
  /** Disarming: every window dropped, every marker taken away (see drain). */
  abort(): void
}

/**
 * The cold action's marks, on whatever clock it is given. One window at a
 * time; see the header for when one opens, what the action and the reaction
 * are, and what a change's cause is.
 */
export function createColdTracker(now0: number, ignore: ReadonlySet<string>): ColdTracker {
  const armedAt = now0
  let lastInputAt = now0
  let lastInput: InputStamp | null = null
  let lastChangeAt: number | null = null
  let lastEnv: Msg | null = null
  let hover: Watch | null = null
  let win: ColdWindow | null = null
  const finished: ColdWindow[] = []
  let presentable = false
  let markN = 0
  let outMark: string[] = []
  let outUnmark: string[] = []

  /** The input's own timeStamp, if it is on this clock; else null (A unknown). */
  const stampTs = (i: InputStamp) =>
    Number.isFinite(i.ts) && i.ts <= i.run + 1 && i.run - i.ts < 60_000 ? i.ts : null

  const watch = (at: number, marked: boolean): Watch => {
    const id = marked && presentable ? `brcold-${++markN}` : ''
    if (id !== '') outMark.push(id)
    return { id, at, raf1: null, work: null, raf2: null, presented: null, probe: marked }
  }
  const release = (x: Watch | null) => { if (x !== null && x.id !== '') outUnmark.push(x.id) }
  const releaseAll = (w: ColdWindow) => {
    release(w.first)
    if (w.reaction !== w.first) release(w.reaction)
  }

  const viaText = (c: Cause): string =>
    c === null ? 'later task' : c.push !== null ? `${c.push.k} #${c.push.s}` : `input ${c.input.kind}`

  const blank = (kind: WindowKind, now: number, by: string): ColdWindow => ({
    kind, opened: now, idleMs: now - lastInputAt,
    stillMs: now - (lastChangeAt ?? armedAt), stillSinceArm: lastChangeAt === null,
    by, inputTs: null, handler: null, cb: '', later: 0, reclicks: 0, inputs: 0, tookOver: '',
    frozen: null, cut: null, cause: 0, hover: null, wake: null, first: null, firstVia: '',
    reaction: null, reactionVia: '', push: null, pushSame: false, attributed: false, provisional: false,
    changes: 0, laterTask: 0, preCall: 0, ignored: 0, envs: [], envCount: 0, idleFrom: lastInputAt, dropped: false,
  })

  const begin = (w: ColdWindow, name: string, inp: InputStamp, now: number) => {
    w.handler = now
    w.cb = name
    w.later = 0
    w.reclicks = 0
    w.by = inp.kind
    w.inputTs = stampTs(inp)
    w.envs = []
    w.envCount = 0
  }

  /** Make `x` the reaction, letting the one it replaces go. */
  const place = (w: ColdWindow, x: Watch, cause: Cause) => {
    const old = w.reaction
    if (old !== null && old !== w.first && old !== x) release(old)
    w.reaction = x
    w.reactionVia = viaText(cause)
    w.attributed = cause !== null
    w.provisional = false
    w.push = cause !== null ? cause.push : lastEnv
    w.pushSame = cause !== null && cause.push !== null
  }
  const unplace = (w: ColdWindow) => {
    if (w.reaction !== null && w.reaction !== w.first) release(w.reaction)
    w.reaction = null
    w.reactionVia = ''
    w.attributed = false
    w.provisional = false
    w.push = null
    w.pushSame = false
  }

  const watches = (): Watch[] => {
    const list: Watch[] = []
    const add = (x: Watch | null) => { if (x !== null && !list.includes(x)) list.push(x) }
    add(hover)
    if (win !== null) { add(win.hover); add(win.wake); add(win.first); add(win.reaction) }
    return list
  }

  /** null when the window has everything it is going to get; else when to look again. */
  const nextAt = (w: ColdWindow, now: number): number | null => {
    if (w.cut !== null) return null
    const pend: number[] = []
    const until = (t: number) => { if (now < t) pend.push(t) }
    if (w.reaction === null) {
      // Nothing yet: a call or a change may still come.
      until(w.cb === '' ? (lastInput?.run ?? w.opened) + COLD_COMMIT_MS : (w.handler ?? w.opened) + COLD_COMMIT_MS)
    } else {
      // (A page-only answer needs no wait of its own for a call that could
      // replace it: the quiet, 5 s from the change, outlasts FETCH_AFTER_INPUT_MS.)
      if (w.frozen === null) {
        until(Math.min(w.reaction.at + QUIET_MS, (w.handler ?? w.opened) + COLD_COMMIT_MS))
      }
      for (const x of [w.first, w.reaction]) {
        if (x === null) continue
        if (x.raf2 === null) until(x.at + COLD_FRAMES_MS)
        else if (presentable && x.id !== '' && x.presented === null) until(x.raf2 + COLD_PRESENT_MS)
      }
    }
    return pend.length === 0 ? null : Math.min(...pend)
  }

  const close = (w: ColdWindow): ColdWindow => {
    releaseAll(w)
    return w
  }

  return {
    get window() { return win },
    get lastInputAt() { return lastInputAt },
    get lastChangeAt() { return lastChangeAt },
    setPresentable(on) { presentable = on },

    input(kind, ts, now) {
      const s: InputStamp = { kind, ts, run: now }
      // A window no input opened ends at the first input.
      if (win !== null && win.kind !== 'input') {
        win.cut = now
        finished.push(win)
        win = null
      }
      const w = win
      if (w === null) {
        if (now - lastInputAt >= COLD_IDLE_MS) {
          const n = blank('input', now, kind)
          n.inputTs = stampTs(s)
          n.inputs = 1
          n.hover = hover
          n.wake = watch(now, false)
          win = n
        }
      } else {
        // A later input before anything came of it (an Alt-tab back, then the
        // click): the call, or the page's answer, names the input it came from.
        w.inputs++
      }
      hover = null
      lastInput = s
      lastInputAt = now
    },

    move(now) {
      if (hover !== null || win !== null || now - lastInputAt < COLD_IDLE_MS) return false
      hover = watch(now, false)
      return true
    },

    fetch(name, now, cause) {
      const w = win
      if (w === null || w.kind !== 'input' || ignore.has(name)) return
      const own = cause !== null && cause.input !== null ? cause.input : null
      const inp = own ?? (lastInput !== null && now - lastInput.run <= FETCH_AFTER_INPUT_MS ? lastInput : null)
      if (w.cb === '') {
        if (inp === null) return
        // A page-only answer before it was not the action's.
        if (w.provisional) unplace(w)
        begin(w, name, inp, now)
        return
      }
      if (name === w.cb) {
        w.later++
        if (own !== null) w.reclicks++
        return
      }
      if (inp === null || w.frozen !== null) return
      if (w.reaction === null) {
        w.tookOver = w.cb
        begin(w, name, inp, now)
      } else {
        w.frozen = { at: now, cb: name }
      }
    },

    envelope(s, k, now) {
      const m: Msg = { s, k, t: now }
      lastEnv = m
      const w = win
      if (w !== null && w.handler !== null && now >= w.handler) {
        w.envCount++
        if (w.envs.length < ENV_KEEP) w.envs.push(m)
      }
    },

    change(now, cause) {
      const w = win
      if (w === null) {
        if (now - lastInputAt >= COLD_IDLE_MS && now - (lastChangeAt ?? armedAt) >= COLD_IDLE_MS) {
          const push = cause !== null ? cause.push : null
          const n = blank(push !== null ? 'push' : 'page', now, push !== null ? `lua ${push.k} #${push.s}` : 'page')
          n.idleMs = Math.min(n.idleMs, n.stillMs)
          n.handler = push !== null ? push.t : now
          n.cause = push !== null ? push.s : 0
          n.changes = 1
          n.first = watch(now, true)
          n.firstVia = viaText(cause)
          place(n, n.first, cause)
          win = n
        }
        lastChangeAt = now
        return
      }
      lastChangeAt = now
      w.changes++
      if ((w.frozen !== null && now >= w.frozen.at) || now - (w.handler ?? w.opened) > COLD_COMMIT_MS) {
        w.ignored++
        return
      }
      let x: Watch | null = null
      if (w.first === null) {
        x = w.first = watch(now, true)
        w.firstVia = viaText(cause)
      }
      const here = () => x ?? watch(now, true)
      if (w.kind === 'input' && w.cb === '') {
        // Before any call: the page's own answer, when the input's task made it.
        if (cause !== null && cause.input !== null) {
          place(w, here(), cause)
          w.provisional = true
          w.handler = cause.input.run
          w.by = cause.input.kind
          w.inputTs = stampTs(cause.input)
        } else if (cause !== null) {
          w.preCall++
        } else {
          w.laterTask++
        }
        return
      }
      if (cause !== null && (w.kind === 'input' || cause.push !== null)) {
        place(w, here(), cause)
      } else {
        w.laterTask++
        // No push or input has changed anything: the first later-task change stands in.
        if (w.reaction === null) place(w, here(), null)
      }
    },

    frame(now) {
      let probe = false
      for (const x of watches()) {
        if (x.raf1 === null) {
          x.raf1 = now
          if (x.probe) probe = true
        } else if (x.raf2 === null) {
          x.raf2 = now
        }
      }
      return probe
    },

    work(now) {
      for (const x of watches()) if (x.probe && x.raf1 !== null && x.work === null) x.work = now
    },

    presented(id, renderTime) {
      const w = win
      if (w === null || id === '' || !(renderTime > 0)) return false
      for (const x of [w.first, w.reaction]) {
        if (x !== null && x.id === id && x.presented === null) {
          x.presented = renderTime
          return true
        }
      }
      return false
    },

    needsFrame() {
      return watches().some((x) => x.raf2 === null)
    },

    due(now) {
      return finished.length > 0 || (win !== null && nextAt(win, now) === null)
    },

    wakeAt(now) {
      if (finished.length > 0) return now
      if (win === null) return null
      return nextAt(win, now) ?? now
    },

    take(now) {
      const f = finished.shift()
      if (f !== undefined) return close(f)
      const w = win
      if (w === null || nextAt(w, now) !== null) return null
      win = null
      if (w.reaction === null) {
        // It changed nothing: the idle goes on (and its first pointer move with
        // it), and with no call there is no line.
        lastInputAt = w.idleFrom
        if (hover === null) hover = w.hover
        w.dropped = w.cb === ''
      }
      return close(w)
    },

    drain() {
      const out = { mark: outMark, unmark: outUnmark }
      outMark = []
      outUnmark = []
      return out
    },

    abort() {
      for (const w of finished) releaseAll(w)
      finished.length = 0
      if (win !== null) releaseAll(win)
      win = null
      hover = null
    },
  }
}

// ── the payload ─────────────────────────────────────────────────────────────

const r1 = (x: number) => Math.round(x * 10) / 10

/** A duration as the line prints it: '-' unknown, one decimal under 10 ms, else whole. */
export function fmtMs(n: number): string {
  if (!(n >= 0)) return '-'
  return n < 10 ? n.toFixed(1) : String(Math.round(n))
}

const secs = (ms: number) => `${(Math.max(0, ms) / 1000).toFixed(1)}s`

/** What is POSTed to br/ui/cold. Durations in ms, -1 where not measured. */
export interface ColdPayload {
  by: string
  idleS: number
  total: number
  a: number
  b: number
  c: number
  d: number
  /** handler -> the arrival of `push` (the page's round trip), -1 none. */
  e: number
  cb: string
  /** Calls of `cb` after the measured one, before this report: Lua counts back by it. */
  later: number
  /** The push the reaction landed with (or the last before a later-task one), `t` ms after the handler. */
  push: Msg | null
  /** A push with no input: its sequence; else 0. */
  cause: number
  /** handler -> this post, for Lua's transport arithmetic. */
  age: number
  detail: string
}

export interface ColdContext {
  now: number
  /** Element Timing is there and its self-test has not failed. */
  presentable: boolean
  /** Why not, when it is not. */
  why: string
  /** Long tasks seen, as [start, duration]. */
  longtasks: ReadonlyArray<readonly [number, number]>
  heapMB: number | null
}

const span = (from: number | null, to: number | null) =>
  from !== null && to !== null ? r1(to - from) : -1

function presentText(x: Watch, ctx: ColdContext, label: string): string {
  if (x.presented !== null) return `${label} ${fmtMs(x.presented - x.at)}`
  if (!ctx.presentable) return `presented n/a (${ctx.why})`
  if (x.id === '') return 'presented n/a (not marked)'
  return x.raf2 === null ? 'presented ? (no frame)' : `presented ? (none in ${COLD_PRESENT_MS / 1000}s)`
}

function framesText(x: Watch): string {
  return `rAF ${fmtMs(span(x.at, x.raf1))}, next ${fmtMs(span(x.raf1, x.raf2))}`
}

function envText(w: ColdWindow, handler: number): string {
  const kinds = new Map<string, number>()
  for (const m of w.envs) kinds.set(m.k, (kinds.get(m.k) ?? 0) + 1)
  let best = 0
  let at = handler
  const ts = w.envs.map((m) => m.t)
  for (let i = 0, j = 0; i < ts.length; i++) {
    while ((ts[i] ?? 0) - (ts[j] ?? 0) > BURST_MS) j++
    if (i - j + 1 > best) { best = i - j + 1; at = ts[j] ?? handler }
  }
  const top = [...kinds.entries()].sort((a, b) => b[1] - a[1]).slice(0, 3).map(([k, n]) => `${k} ${n}`).join(', ')
  return `${w.envCount} envelope${w.envCount === 1 ? '' : 's'} after the ${w.kind === 'input' ? 'call' : 'push'}`
    + ` (${top}), at most ${best} within ${BURST_MS}ms at +${fmtMs(at - handler)}`
}

export function coldPayload(w: ColdWindow, ctx: ColdContext): ColdPayload {
  const handler = w.handler
  const start = w.kind === 'input' ? (w.inputTs ?? handler) : handler
  const from = start ?? w.opened
  const r = w.reaction
  const push = w.kind === 'input' && w.push !== null && handler !== null
    ? { s: w.push.s, k: w.push.k, t: r1(w.push.t - handler) } : null
  const long = ctx.longtasks.filter(([s, dur]) => s + dur >= from && s <= ctx.now)
  const longMs = long.reduce((n, [, dur]) => n + dur, 0)

  const d: string[] = []
  // What is missing, first.
  if (w.cut !== null) d.push(`cut by an input at +${fmtMs(w.cut - from)}`)
  if (r === null) {
    if (w.cb !== '') d.push(`no change within ${COLD_COMMIT_MS / 1000}s`)
  } else if (r.raf2 === null) {
    d.push(`no frame within ${COLD_FRAMES_MS / 1000}s of the commit`)
  }
  // The reaction: what it landed with, its frame's work, its presentation.
  if (r !== null) {
    if (w.pushSame && w.push !== null) d.push(`push->commit ${fmtMs(r.at - w.push.t)} (${w.push.k} #${w.push.s})`)
    else if (w.attributed) d.push(`commit by ${w.reactionVia}`)
    else {
      d.push('commit in a later task'
        + (w.push !== null ? `, ${fmtMs(r.at - w.push.t)} after ${w.push.k} #${w.push.s}` : ''))
    }
    if (r.raf1 !== null && r.work !== null) d.push(`frame work ${fmtMs(r.work - r.raf1)}`)
    d.push(presentText(r, ctx, 'commit->presented'))
  }
  // The first change after the input, when it is another: the first frame after the idle.
  const f = w.first
  if (f !== null && f !== r) {
    d.push(`first change +${fmtMs(f.at - from)} (${w.firstVia}): ${framesText(f)}, ${presentText(f, ctx, 'presented')}`)
  }
  if (w.wake !== null) d.push(`input->${framesText(w.wake)}`)
  if (w.hover !== null) d.push(`pointer moved ${secs(w.opened - w.hover.at)} before: ${framesText(w.hover)}`)
  else if (w.kind === 'input') d.push('no pointer move first')
  // The page's own work.
  d.push(`long tasks ${long.length}${long.length > 0 ? ` (${fmtMs(longMs)})` : ''}`)
  if (ctx.heapMB !== null) d.push(`heap ${ctx.heapMB.toFixed(1)}MB`)
  // The DOM and the messages.
  d.push(`DOM still ${secs(w.stillMs)} before${w.stillSinceArm ? ' (since armed)' : ''}`)
  d.push(`${w.changes} DOM change${w.changes === 1 ? '' : 's'}`
    + (w.laterTask > 0 ? `, ${w.laterTask} in later tasks` : '')
    + (w.preCall > 0 ? `, ${w.preCall} by a push before the call` : '')
    + (w.ignored > 0 ? `, ${w.ignored} past the window` : ''))
  if (handler !== null && w.envCount > 0) d.push(envText(w, handler))
  // What else happened in the window.
  if (w.inputs > 1) d.push(`${w.inputs} inputs`)
  if (w.reclicks > 0) d.push(`re-clicked ${w.reclicks}x`)
  if (w.tookOver !== '') d.push(`took over from ${w.tookOver}`)
  if (w.frozen !== null) d.push(`ended by ${w.frozen.cb} at +${fmtMs(w.frozen.at - from)}`)

  return {
    by: w.by,
    idleS: Math.floor(w.idleMs / 1000),
    total: r !== null && r.raf2 !== null && start !== null ? r1(r.raf2 - start) : -1,
    a: w.inputTs !== null && handler !== null ? r1(handler - w.inputTs) : -1,
    b: r !== null ? span(handler, r.at) : -1,
    c: r !== null ? span(r.at, r.raf1) : -1,
    d: r !== null ? span(r.raf1, r.raf2) : -1,
    e: push !== null ? push.t : -1,
    cb: w.cb,
    later: w.later,
    push,
    cause: w.cause,
    age: handler !== null ? r1(ctx.now - handler) : -1,
    detail: d.join(' | '),
  }
}

// ── the controller ──────────────────────────────────────────────────────────

/** nui.ts's two taps, installed only while the cold line is armed. */
export interface BridgeTap {
  fetch(name: string): void
  envelope(seq: number, kind: string): void
}

/** What the page can see of itself for `bruiidle`. */
export interface PageInventory {
  heapMB: number | null
  heapTotalMB: number | null
  nodes: number
  /** Running CSS animations and transitions, by a short name. */
  animations: string[]
  visible: string
  focused: boolean
}

/**
 * Everything the controller does to the browser, so the browser half
 * (bridge/diag.ts) is the only file that touches it and node can count what
 * an armed or unarmed page installs.
 */
export interface DiagEnv {
  now(): number
  /** The page's own callbacks, never "the action". */
  ignore: ReadonlySet<string>
  /** Install or remove the capture-phase listeners (the inputs and pointer moves). */
  listen(on: boolean, fn: (kind: ListenKind, ts: number) => void): void
  /** Install or remove the DOM observer (the probe's own nodes excluded). */
  observe(on: boolean, fn: () => void): void
  /** Install or remove the long-task observer. */
  longtasks(on: boolean, fn: (start: number, dur: number) => void): void
  /** Install or remove the Element Timing observer; true when this browser has it. */
  presentation(on: boolean, fn: (id: string, renderTime: number) => void): boolean
  /** nui.ts's taps. */
  tap(t: BridgeTap | null): void
  raf(fn: () => void): void
  /** A MessageChannel message: lands after the current frame's main-thread work. */
  afterFrame(fn: () => void): void
  /**
   * Run `fn` once the current task is over -- after its microtasks, and after
   * any task they queued with a message before it ended (React's deferred
   * render). What lands before it is that task's.
   */
  taskEnd(fn: () => void): void
  /** After React's flush of what was just set (a microtask chain). */
  settle(fn: () => void): void
  every(ms: number, fn: () => void): number
  stop(id: number): void
  later(ms: number, fn: () => void): void
  /** Add or remove an Element Timing marker. */
  mark(id: string): void
  unmark(id: string): void
  /** Make (or, with null, remove) the heartbeat's dot. */
  dot(mode: PaintMode | null): void
  /** One heartbeat on the dot. */
  flip(): void
  /** Re-render the whole tree with nothing changed. */
  warm(): void
  heapMB(): number | null
  inventory(): PageInventory
  send(what: 'cold', payload: ColdPayload): void
  send(what: 'idle', payload: { text: string }): void
}

/** What the switches and the probe have counted since they were turned on. */
export interface DiagStats {
  armedAt: number
  envelopes: Map<string, number>
  mutations: number
  longtasks: Array<[number, number]>
  paintOn: number
  paintBeats: number
  paintMs: number
  warmOn: number
  warmBeats: number
  warmMs: number
  /** DOM changes a warm beat caused (a render that is not a no-op). */
  warmMutations: number
}

/** Element Timing's self-test, run once when the cold line is armed. */
export type SelfTest =
  | { state: 'off' } | { state: 'unsupported' } | { state: 'waiting'; since: number }
  | { state: 'ok'; ms: number } | { state: 'zero' } | { state: 'none' }

export function selfTestText(s: SelfTest): string {
  switch (s.state) {
    case 'off': return 'off'
    case 'unsupported': return 'no Element Timing'
    case 'waiting': return 'self-test waiting'
    case 'ok': return `self-test ok, presented +${fmtMs(s.ms)}`
    case 'zero': return 'self-test: renderTime 0'
    case 'none': return `self-test: no entry in ${SELFTEST_MS / 1000}s`
  }
}

export interface Diag {
  apply(next: DiagState & { ask?: number | null }): void
  readonly state: DiagState
  readonly stats: DiagStats
  readonly tracker: ColdTracker | null
  readonly selftest: SelfTest
}

export function createDiag(env: DiagEnv): Diag {
  let state: DiagState = DIAG_OFF
  let tracker: ColdTracker | null = null
  let presentable = false
  let selftest: SelfTest = { state: 'off' }
  let selfGen = 0
  /** The task we are in: an input's or a push's, until taskEnd says it is over. */
  let cur: { cause: Cause; n: number } | null = null
  let curN = 0
  let rafPending = false
  let checkAt: number | null = null
  let paintId = 0
  let warmId = 0
  let warming = false
  const stats: DiagStats = {
    armedAt: 0, envelopes: new Map(), mutations: 0, longtasks: [],
    paintOn: 0, paintBeats: 0, paintMs: 0, warmOn: 0, warmBeats: 0, warmMs: 0, warmMutations: 0,
  }

  const ctx = (): ColdContext => ({
    now: env.now(), presentable, why: selfTestText(selftest), longtasks: stats.longtasks, heapMB: env.heapMB(),
  })

  function tag(cause: Cause) {
    const n = ++curN
    cur = { cause, n }
    env.taskEnd(() => { if (cur !== null && cur.n === n) cur = null })
  }
  const cause = (): Cause => (cur !== null ? cur.cause : null)

  /** After anything the tracker heard: send what is finished, mark, ask for frames, and look again when due. */
  function sync() {
    const t = tracker
    if (t === null) return
    for (let w = t.take(env.now()); w !== null; w = t.take(env.now())) {
      if (!w.dropped) env.send('cold', coldPayload(w, ctx()))
    }
    const o = t.drain()
    for (const id of o.unmark) env.unmark(id)
    for (const id of o.mark) env.mark(id)
    if (!rafPending && t.needsFrame()) {
      rafPending = true
      env.raf(onFrame)
    }
    const now = env.now()
    const at = t.wakeAt(now)
    if (at !== null && (checkAt === null || at < checkAt || checkAt < now)) {
      checkAt = at
      env.later(Math.max(0, at - now), () => {
        if (checkAt === at) checkAt = null
        sync()
      })
    }
  }

  function onFrame() {
    rafPending = false
    const t = tracker
    if (t === null) return
    const at = env.now()
    if (t.frame(at)) {
      env.afterFrame(() => {
        tracker?.work(env.now())
        sync()
      })
    }
    sync()
  }

  const onInput = (kind: ListenKind, ts: number) => {
    const t = tracker
    if (t === null) return
    const now = env.now()
    if (kind === 'pointermove') {
      if (t.move(now)) sync()
      return
    }
    t.input(kind, ts, now)
    tag({ input: { kind, ts, run: now }, push: null })
    sync()
  }
  const onMutation = () => {
    if (warming) { stats.warmMutations++; return }
    stats.mutations++
    const t = tracker
    if (t === null) return
    t.change(env.now(), cause())
    sync()
  }
  const onLongtask = (start: number, dur: number) => {
    stats.longtasks.push([start, dur])
    if (stats.longtasks.length > LONGTASK_KEEP) stats.longtasks.shift()
  }

  function selfDone(renderTime: number | null) {
    if (selftest.state !== 'waiting') return
    const since = selftest.since
    env.unmark(SELFTEST_ID)
    selftest = renderTime === null ? { state: 'none' }
      : renderTime > 0 ? { state: 'ok', ms: renderTime - since } : { state: 'zero' }
    if (selftest.state !== 'ok') {
      presentable = false
      tracker?.setPresentable(false)
    }
    sync()
  }
  const onPresented = (id: string, renderTime: number) => {
    if (id === SELFTEST_ID) { selfDone(renderTime); return }
    if (tracker !== null && tracker.presented(id, renderTime)) sync()
  }

  const tap: BridgeTap = {
    fetch(name) {
      const t = tracker
      if (t === null) return
      t.fetch(name, env.now(), cause())
      sync()
    },
    envelope(seq, kind) {
      stats.envelopes.set(kind, (stats.envelopes.get(kind) ?? 0) + 1)
      const t = tracker
      if (t === null) return
      const now = env.now()
      t.envelope(seq, kind, now)
      tag({ input: null, push: { s: seq, k: kind, t: now } })
    },
  }

  function setCold(on: boolean) {
    if (on) {
      const now = env.now()
      tracker = createColdTracker(now, env.ignore)
      stats.armedAt = now
      stats.envelopes = new Map()
      stats.mutations = 0
      stats.longtasks = []
      env.listen(true, onInput)
      env.observe(true, onMutation)
      env.longtasks(true, onLongtask)
      presentable = env.presentation(true, onPresented)
      tracker.setPresentable(presentable)
      if (presentable) {
        // Once per arming: does this build report presentation for a marker
        // like ours at all? "n/a" on the line then means it does not, and "?"
        // that it was late.
        const gen = ++selfGen
        selftest = { state: 'waiting', since: now }
        env.mark(SELFTEST_ID)
        env.later(SELFTEST_MS, () => { if (gen === selfGen) selfDone(null) })
      } else {
        selftest = { state: 'unsupported' }
      }
      env.tap(tap)
    } else {
      const t = tracker
      if (t !== null) {
        t.abort()
        for (const id of t.drain().unmark) env.unmark(id)
      }
      if (selftest.state === 'waiting') env.unmark(SELFTEST_ID)
      selfGen++
      selftest = { state: 'off' }
      tracker = null
      cur = null
      env.tap(null)
      env.listen(false, onInput)
      env.observe(false, onMutation)
      env.longtasks(false, onLongtask)
      env.presentation(false, onPresented)
      presentable = false
    }
  }

  function setPaint(cfg: PaintCfg | null) {
    if (paintId !== 0) { env.stop(paintId); paintId = 0 }
    env.dot(null)
    if (cfg === null) return
    stats.paintOn = env.now()
    stats.paintBeats = 0
    stats.paintMs = 0
    if (cfg.mode !== 'raf') env.dot(cfg.mode)
    const noop = () => {}
    paintId = env.every(cfg.ms, () => {
      const t0 = env.now()
      if (cfg.mode === 'raf') env.raf(noop)
      else env.flip()
      stats.paintBeats++
      stats.paintMs += env.now() - t0
    })
  }

  function setWarm(ms: number | null) {
    if (warmId !== 0) { env.stop(warmId); warmId = 0 }
    if (ms === null) return
    stats.warmOn = env.now()
    stats.warmBeats = 0
    stats.warmMs = 0
    stats.warmMutations = 0
    warmId = env.every(ms, () => {
      if (warming) return
      const t0 = env.now()
      warming = true
      env.warm()
      env.settle(() => {
        warming = false
        stats.warmBeats++
        stats.warmMs += env.now() - t0
      })
    })
  }

  return {
    apply(next) {
      if (next.cold !== state.cold) setCold(next.cold)
      const p0 = state.paint
      const p1 = next.paint
      if ((p0 === null) !== (p1 === null) || (p0 && p1 && (p0.ms !== p1.ms || p0.mode !== p1.mode))) setPaint(p1)
      if (next.warm !== state.warm) setWarm(next.warm)
      state = { cold: next.cold, paint: next.paint, warm: next.warm }
      if (typeof next.ask === 'number') {
        env.send('idle', { text: idleInventory(state, stats, tracker, env.now(), env.inventory(), selftest) })
      }
    },
    get state() { return state },
    get stats() { return stats },
    get tracker() { return tracker },
    get selftest() { return selftest },
  }
}

// ── the inventory (`bruiidle`) ──────────────────────────────────────────────

/** Per second, over at least a second (a probe armed a moment ago is not 3,000 a second). */
const rate = (n: number, ms: number) => n / (Math.max(ms, 1000) / 1000)

/** One line: what the page receives, changes and keeps while it sits, and what the switches cost. */
export function idleInventory(
  state: DiagState, stats: DiagStats, tracker: ColdTracker | null, now: number, page: PageInventory,
  selftest: SelfTest,
): string {
  const parts: string[] = []
  if (tracker !== null) {
    const ms = now - stats.armedAt
    const kinds = [...stats.envelopes.entries()].sort((a, b) => b[1] - a[1])
    const still = tracker.lastChangeAt
    parts.push(`no input ${Math.floor((now - tracker.lastInputAt) / 1000)}s, DOM still `
      + (still === null ? `${Math.floor(ms / 1000)}s (since armed)` : `${Math.floor((now - still) / 1000)}s`))
    parts.push(`cold probe on ${Math.floor(ms / 1000)}s: `
      + (kinds.length === 0 ? 'no envelopes'
        : kinds.slice(0, 6).map(([k, n]) => `${k} ${rate(n, ms).toFixed(1)}/s`).join(', '))
      + `, ${(rate(stats.mutations, ms) * 60).toFixed(1)} DOM changes/min`
      + `, ${stats.longtasks.length} long tasks`)
    parts.push(`element timing: ${selfTestText(selftest)}`)
  } else {
    parts.push('cold probe off (no counts)')
  }
  parts.push(`heap ${page.heapMB !== null ? page.heapMB.toFixed(1) : '?'}/`
    + `${page.heapTotalMB !== null ? page.heapTotalMB.toFixed(1) : '?'}MB, ${page.nodes} nodes`)
  parts.push(`${page.animations.length} running animations`
    + (page.animations.length > 0 ? ` (${page.animations.slice(0, 4).join(', ')})` : ''))
  parts.push(`page ${page.visible}, ${page.focused ? 'focused' : 'unfocused'}`)
  parts.push(state.paint === null ? 'paint off'
    : `paint ${state.paint.mode} every ${state.paint.ms}ms: ${stats.paintBeats} beats, `
      + `${fmtMs(stats.paintBeats > 0 ? stats.paintMs / stats.paintBeats : 0)}ms JS each`)
  parts.push(state.warm === null ? 'warm off'
    : `warm every ${state.warm}ms: ${stats.warmBeats} beats, `
      + `${fmtMs(stats.warmBeats > 0 ? stats.warmMs / stats.warmBeats : 0)}ms JS each, `
      + `${stats.warmMutations} DOM changes`)
  return parts.join(' | ')
}
