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
 *            pushed with no input, the envelope's arrival
 *   handler  the action's fetchNui to Lua (the first one after the input that
 *            is not the page talking about itself), or the input listener if
 *            the page changed with no call to Lua; a push's dispatch
 *   commit   the first DOM change after the handler (a MutationObserver
 *            batch, so after React's commit)
 *   rAF      the first animation frame after the commit; `next rAF` the one
 *            after it. A frame the GPU process cannot finish holds the next
 *            one back, so a cold draw shows as C or D.
 *
 *   E        handler -> the first envelope after it, which Lua narrows to the
 *            transport alone (it knows its own work); a part of B, not a fifth
 *            term
 *
 * THE EVIDENCE: the main thread's own work for the first frame (a
 * MessageChannel posted from rAF 1 lands when style, layout and paint are
 * done), commit -> presented (the frame's presentation time, read off an
 * Element Timing marker added with the commit -- the one look past the last
 * rAF the page has, where CEF reports it), long tasks in the window, the JS
 * heap, the DOM changes and the first envelopes after the handler.
 *
 * WHAT COUNTS AS IDLE: no input and no DOM change for COLD_IDLE_MS. The lobby's
 * three envelopes a second change nothing on screen, so they are not activity;
 * the switches below are not either -- with `bruipaint` on, a cold line is
 * still printed, and it is the A/B.
 *
 * AND THE SWITCHES (each off by default, each a dev F8 command in idle.lua):
 *
 *   paint  every N ms a real frame: `raster` repaints a 1 px near-transparent
 *          dot (raster + draw in the GPU process), `comp` flips the opacity of
 *          a dot on its own layer (draw, no raster), `raf` only asks for an
 *          animation frame (the frame clock, no damage). Whichever makes the
 *          lag vanish names the stage that goes cold.
 *   warm   every N ms re-render the whole tree with nothing changed: the code
 *          paths the first action runs, kept compiled. No DOM change, no frame.
 *
 * NOTHING RUNS UNTIL LUA ARMS IT: the page installs no listener, observer,
 * timer or tap until a `diag` envelope says so, and a `diag` envelope is sent
 * only in dev mode.
 *
 * NO RUNTIME IMPORTS, so node runs this file as-is (scripts/test-cold.mjs). The
 * browser half -- the real listeners, the dot, the store -- is bridge/diag.ts.
 */

// ── the thresholds ──────────────────────────────────────────────────────────

/** No input and no DOM change for this long, and the next action is cold. */
export const COLD_IDLE_MS = 30_000
/** A fetch this long after the last input is not that input's action. */
export const FETCH_AFTER_INPUT_MS = 1_000
/** A DOM change this soon after an envelope is that envelope's (a push with no input). */
export const CAUSE_MS = 1_000
/** How long a cold action waits for its change to commit before it reports what it has. */
export const COLD_COMMIT_MS = 15_000
/** ...and for its two frames after the commit. */
export const COLD_FRAMES_MS = 15_000
/** ...and, where CEF reports presentation, for the commit's presentation time after the second frame. */
export const COLD_PRESENT_MS = 3_000
/** The envelopes after the handler a line carries. */
export const COLD_MSGS = 8
/** Long tasks kept for the line. */
export const LONGTASK_KEEP = 16

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

export interface Msg { s: number; k: string; t: number }

/** One cold action, from the input (or push) that opened it to its second frame. */
export interface ColdWindow {
  opened: number
  idleMs: number
  /** The input kind that led to the handler, or `lua <kind> #<seq>` / `page`. */
  by: string
  /** The input event's timeStamp, when there was an input and it is on this clock. */
  inputTs: number | null
  handler: number | null
  /** The action's callback, '' when none. */
  cb: string
  commit: number | null
  /** The commit came before any action (a page-only answer); a later action replaces it. */
  provisional: boolean
  raf1: number | null
  work: number | null
  raf2: number | null
  presented: number | null
  /** The Element Timing marker added with the commit. */
  mark: string
  /** A push with no input: the envelope's sequence. */
  cause: number
  /** Envelopes after the handler, at absolute page times. */
  msgs: Msg[]
  mutations: number
}

export interface ColdTracker {
  readonly window: ColdWindow | null
  readonly lastActivity: number
  /** An input listener ran. True when it opened a cold window. */
  input(kind: InputKind, ts: number, now: number): boolean
  /** fetchNui started. True when it became the action and replaced a provisional commit. */
  fetch(name: string, now: number): boolean
  envelope(s: number, k: string, now: number): void
  /** A DOM change (not the probe's own). True when it is the window's commit. */
  mutation(now: number): boolean
  /** The commit's Element Timing marker. */
  setMark(id: string): void
  /** An animation frame: 1 for the first after the commit, 2 for the next, else 0. */
  raf(now: number): 0 | 1 | 2
  /** The MessageChannel posted from the first frame. */
  work(now: number): void
  /** A presentation time for a marker. True when it is the commit's. */
  presented(id: string, renderTime: number): boolean
  /** Has the window got everything it is going to get? */
  due(now: number, presentable: boolean): boolean
  /** Close the window and hand it over. */
  take(): ColdWindow | null
}

/**
 * The cold action's marks, on whatever clock it is given. One window at a time,
 * opened only after COLD_IDLE_MS of no input and no DOM change, so ONE LINE PER
 * COLD ACTION: everything that happens while a window is open is part of it, and
 * the window's own input and changes are activity, so the next line needs
 * another idle.
 */
export function createColdTracker(now0: number, ignore: ReadonlySet<string>): ColdTracker {
  let lastActivity = now0
  let lastInput: { kind: InputKind; ts: number; run: number } | null = null
  let lastEnv: Msg | null = null
  let win: ColdWindow | null = null

  const open = (now: number, by: string): ColdWindow => ({
    opened: now, idleMs: now - lastActivity, by, inputTs: null, handler: null, cb: '',
    commit: null, provisional: false, raf1: null, work: null, raf2: null, presented: null,
    mark: '', cause: 0, msgs: [], mutations: 0,
  })
  /** The input's own timeStamp, if it is on this clock; else when its listener ran. */
  const stamp = (i: { ts: number; run: number }) =>
    Number.isFinite(i.ts) && i.ts <= i.run + 1 && i.run - i.ts < 60_000 ? i.ts : null
  const resetFrames = (w: ColdWindow) => {
    w.commit = null; w.provisional = false; w.raf1 = null; w.work = null; w.raf2 = null
    w.presented = null; w.mark = ''
  }

  return {
    get window() { return win },
    get lastActivity() { return lastActivity },

    input(kind, ts, now) {
      lastInput = { kind, ts, run: now }
      let opened = false
      if (win === null && now - lastActivity >= COLD_IDLE_MS) {
        win = open(now, kind)
        win.inputTs = stamp(lastInput)
        opened = true
      }
      lastActivity = now
      return opened
    },

    fetch(name, now) {
      const w = win
      if (w === null || ignore.has(name) || w.cause !== 0 || lastInput === null) return false
      if (w.handler !== null && !w.provisional) return false
      if (now - lastInput.run > FETCH_AFTER_INPUT_MS) return false
      const replaced = w.provisional
      if (replaced) resetFrames(w)
      w.handler = now
      w.cb = name
      w.by = lastInput.kind
      w.inputTs = stamp(lastInput)
      w.msgs = []
      return replaced
    },

    envelope(s, k, now) {
      lastEnv = { s, k, t: now }
      const w = win
      if (w !== null && w.cb !== '' && w.msgs.length < COLD_MSGS) w.msgs.push({ s, k, t: now })
    },

    mutation(now) {
      let commit = false
      const w = win
      if (w !== null) {
        if (w.commit === null) {
          if (w.handler === null) {
            // The page answered the input before any call to Lua -- or this is
            // the input's own side effect and the action is still to come.
            // Provisional: a fetch inside FETCH_AFTER_INPUT_MS takes its place.
            w.provisional = true
            if (lastInput !== null) {
              w.handler = lastInput.run
              w.by = lastInput.kind
              w.inputTs = stamp(lastInput)
            } else {
              w.handler = now
            }
          }
          w.commit = now
          commit = true
        }
        w.mutations++
      } else if (now - lastActivity >= COLD_IDLE_MS) {
        // A change nobody clicked for: Lua pushed it (the envelope just before
        // it), or the page did it on its own clock.
        const e = lastEnv !== null && now - lastEnv.t <= CAUSE_MS ? lastEnv : null
        const n = open(now, e ? `lua ${e.k} #${e.s}` : 'page')
        n.handler = e ? e.t : now
        n.cause = e ? e.s : 0
        n.commit = now
        n.mutations = 1
        win = n
        commit = true
      }
      lastActivity = now
      return commit
    },

    setMark(id) { if (win !== null) win.mark = id },

    raf(now) {
      const w = win
      if (w === null || w.commit === null) return 0
      if (w.raf1 === null) { w.raf1 = now; return 1 }
      if (w.raf2 === null) { w.raf2 = now; return 2 }
      return 0
    },

    work(now) {
      if (win !== null && win.raf1 !== null && win.work === null) win.work = now
    },

    presented(id, renderTime) {
      const w = win
      if (w === null || w.commit === null || id !== w.mark || w.presented !== null) return false
      if (!(renderTime > 0)) return false
      w.presented = renderTime
      return true
    },

    due(now, presentable) {
      const w = win
      if (w === null) return false
      if (w.commit === null) return now - w.opened >= COLD_COMMIT_MS
      if (w.raf2 === null) return now - w.commit >= COLD_FRAMES_MS
      if (w.provisional && lastInput !== null && now - lastInput.run < FETCH_AFTER_INPUT_MS) return false
      if (presentable && w.presented === null) return now - w.raf2 >= COLD_PRESENT_MS
      return true
    },

    take() {
      const w = win
      win = null
      return w
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

/** What is POSTed to br/ui/cold. Durations in ms, -1 where not measured. */
export interface ColdPayload {
  by: string
  idleS: number
  total: number
  a: number
  b: number
  c: number
  d: number
  /** handler -> the first envelope after it (the page's round trip), -1 none. */
  e: number
  cb: string
  /** Envelopes after the handler, `t` ms after it. */
  msgs: Msg[]
  /** A push with no input: its sequence; else 0. */
  cause: number
  /** handler -> this post, for Lua's transport arithmetic. */
  age: number
  detail: string
}

export interface ColdContext {
  now: number
  presentable: boolean
  /** Long tasks seen, as [start, duration]. */
  longtasks: ReadonlyArray<readonly [number, number]>
  heapMB: number | null
}

const span = (from: number | null, to: number | null) =>
  from !== null && to !== null ? r1(to - from) : -1

export function coldPayload(w: ColdWindow, ctx: ColdContext): ColdPayload {
  const handler = w.handler
  const start = w.inputTs ?? handler
  const msgs = handler === null ? [] : w.msgs.map((m) => ({ s: m.s, k: m.k, t: r1(m.t - handler) }))
  const from = start ?? w.opened
  const long = ctx.longtasks.filter(([s, dur]) => s + dur >= from && s <= ctx.now)
  const longMs = long.reduce((n, [, dur]) => n + dur, 0)

  const detail: string[] = []
  if (w.commit === null) detail.push(`no change within ${COLD_COMMIT_MS / 1000}s`)
  else if (w.raf2 === null) detail.push(`no frame within ${COLD_FRAMES_MS / 1000}s of the commit`)
  if (w.raf1 !== null && w.work !== null) detail.push(`frame work ${fmtMs(w.work - w.raf1)}`)
  if (w.commit !== null) {
    detail.push(w.presented !== null ? `commit->presented ${fmtMs(w.presented - w.commit)}`
      : ctx.presentable ? 'presented ?' : 'presented n/a')
  }
  detail.push(`long tasks ${long.length}${long.length > 0 ? ` (${fmtMs(longMs)})` : ''}`)
  if (ctx.heapMB !== null) detail.push(`heap ${ctx.heapMB.toFixed(1)}MB`)
  detail.push(`${w.mutations} DOM change${w.mutations === 1 ? '' : 's'}`)
  if (msgs.length > 0) {
    detail.push(`msgs ${msgs.slice(0, 4).map((m) => `${m.k} #${m.s} +${fmtMs(m.t)}`).join(', ')}`
      + (msgs.length > 4 ? ` +${msgs.length - 4} more` : ''))
  }

  return {
    by: w.by,
    idleS: Math.floor(w.idleMs / 1000),
    total: w.raf2 !== null && start !== null ? r1(w.raf2 - start) : -1,
    a: w.inputTs !== null && handler !== null && w.cause === 0 ? r1(handler - w.inputTs) : -1,
    b: span(handler, w.commit),
    c: span(w.commit, w.raf1),
    d: span(w.raf1, w.raf2),
    e: w.cb !== '' && msgs[0] !== undefined ? msgs[0].t : -1,
    cb: w.cb,
    msgs,
    cause: w.cause,
    age: handler !== null ? r1(ctx.now - handler) : -1,
    detail: detail.join(' | '),
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
  /** Install or remove the capture-phase input listeners. */
  listen(on: boolean, fn: (kind: InputKind, ts: number) => void): void
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

export interface Diag {
  apply(next: DiagState & { ask?: number | null }): void
  readonly state: DiagState
  readonly stats: DiagStats
  readonly tracker: ColdTracker | null
}

export function createDiag(env: DiagEnv): Diag {
  let state: DiagState = DIAG_OFF
  let tracker: ColdTracker | null = null
  let presentable = false
  let paintId = 0
  let warmId = 0
  let warming = false
  let markN = 0
  const stats: DiagStats = {
    armedAt: 0, envelopes: new Map(), mutations: 0, longtasks: [],
    paintOn: 0, paintBeats: 0, paintMs: 0, warmOn: 0, warmBeats: 0, warmMs: 0, warmMutations: 0,
  }

  function check() {
    const t = tracker
    if (t === null || !t.due(env.now(), presentable)) return
    const w = t.take()
    if (w === null) return
    if (w.mark !== '') env.unmark(w.mark)
    env.send('cold', coldPayload(w, {
      now: env.now(), presentable, longtasks: stats.longtasks, heapMB: env.heapMB(),
    }))
  }
  const poke = (ms: number) => env.later(ms, check)

  function onFrame() {
    const t = tracker
    if (t === null) return
    const n = t.raf(env.now())
    if (n === 1) {
      env.afterFrame(() => { tracker?.work(env.now()) })
      env.raf(onFrame)
    } else if (n === 2) {
      poke(0)
      poke(COLD_PRESENT_MS + 1)
      poke(FETCH_AFTER_INPUT_MS + 1)
    }
  }

  function onCommit() {
    const t = tracker
    if (t === null) return
    const id = `brcold-${++markN}`
    t.setMark(id)
    if (presentable) env.mark(id)
    env.raf(onFrame)
    poke(COLD_FRAMES_MS + 1)
  }

  const onInput = (kind: InputKind, ts: number) => {
    if (tracker !== null && tracker.input(kind, ts, env.now())) poke(COLD_COMMIT_MS + 1)
  }
  const onMutation = () => {
    if (warming) { stats.warmMutations++; return }
    stats.mutations++
    if (tracker !== null && tracker.mutation(env.now())) onCommit()
  }
  const onLongtask = (start: number, dur: number) => {
    stats.longtasks.push([start, dur])
    if (stats.longtasks.length > LONGTASK_KEEP) stats.longtasks.shift()
  }
  const onPresented = (id: string, renderTime: number) => {
    if (tracker !== null && tracker.presented(id, renderTime)) poke(0)
  }
  const tap: BridgeTap = {
    fetch(name) {
      const t = tracker
      if (t === null) return
      const old = t.window?.mark ?? ''
      if (t.fetch(name, env.now()) && old !== '') env.unmark(old)
    },
    envelope(seq, kind) {
      stats.envelopes.set(kind, (stats.envelopes.get(kind) ?? 0) + 1)
      tracker?.envelope(seq, kind, env.now())
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
      env.tap(tap)
    } else {
      const w = tracker?.take()
      if (w && w.mark !== '') env.unmark(w.mark)
      tracker = null
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
        env.send('idle', { text: idleInventory(state, stats, tracker, env.now(), env.inventory()) })
      }
    },
    get state() { return state },
    get stats() { return stats },
    get tracker() { return tracker },
  }
}

// ── the inventory (`bruiidle`) ──────────────────────────────────────────────

/** Per second, over at least a second (a probe armed a moment ago is not 3,000 a second). */
const rate = (n: number, ms: number) => n / (Math.max(ms, 1000) / 1000)

/** One line: what the page receives, changes and keeps while it sits, and what the switches cost. */
export function idleInventory(
  state: DiagState, stats: DiagStats, tracker: ColdTracker | null, now: number, page: PageInventory,
): string {
  const parts: string[] = []
  if (tracker !== null) {
    const ms = now - stats.armedAt
    const kinds = [...stats.envelopes.entries()].sort((a, b) => b[1] - a[1])
    parts.push(`idle ${Math.floor((now - tracker.lastActivity) / 1000)}s`)
    parts.push(`cold probe on ${Math.floor(ms / 1000)}s: `
      + (kinds.length === 0 ? 'no envelopes'
        : kinds.slice(0, 6).map(([k, n]) => `${k} ${rate(n, ms).toFixed(1)}/s`).join(', '))
      + `, ${(rate(stats.mutations, ms) * 60).toFixed(1)} DOM changes/min`
      + `, ${stats.longtasks.length} long tasks`)
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
