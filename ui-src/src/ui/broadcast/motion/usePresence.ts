import {
  useCallback, useContext, useEffect, useLayoutEffect, useMemo, useRef, useState, type CSSProperties,
} from 'react'
import { createFadeClock, FADE_SETTLE_MARGIN_MS, onEnvelope } from '../deps'
import { ClockCtx, QuickCtx, ScopeCtx, type PhaseInfo } from './context'
import {
  begin, drained, initialState, landAt, release, rootVars, sameInputs, settle, timingsFor, update, windowOf,
  type Inputs, type Phase, type PresenceState, type StaggerCtx,
} from './machine'
import { getPreset } from './presets'

export interface PresenceOptions {
  /** A preset name (presets.ts). Default: the scope's, else 'broadcast'. */
  preset?: string
  /** This anchor's place in its scope's stagger (0 first). */
  order?: number
  /** Mounted, hidden and layer-off while true; it enters when released. */
  hold?: boolean
  /** Play the entrance when it mounts wanted (default true; a layer, false). */
  appear?: boolean
  /** Stay mounted while hidden (default false: unmounted once its leave ends). */
  keepMounted?: boolean
  /** The settle clock. Default: <PresenceClock>, else the monotonic clock. */
  now?: () => number
  /** Override the in-stagger step, ms. */
  step?: number
  /** A layer root ignores the scope it sits in (QuickHide). Default true. */
  scoped?: boolean
}

/** Spread on the presence's own wrapper element. */
export interface PresenceRootProps {
  ref: (el: HTMLElement | null) => void
  'data-bc-phase': Phase
  'data-bc-preset': string
  className: string | undefined
  style: CSSProperties
  'aria-hidden': true | undefined
  inert: true | undefined
}

export interface PresenceResult {
  /** Render the root at all. */
  mounted: boolean
  phase: Phase
  held: boolean
  rootProps: PresenceRootProps
  /** For <PresencePhaseCtx.Provider value={info}> (Presence does this). */
  info: PhaseInfo
}

/** How long to wait before looking again at a clock that is not moving. */
const STALLED_MS = 250

/** Each presence's name in its scope's drain. */
let presenceSeq = 0

/** The elements a presence moves (motion.css), and its root. */
const CHANNEL_CLASSES = ['bc-ch-edge', 'bc-ch-surface', 'bc-ch-content', 'bc-whole']

function ownChannel(el: Element, root: HTMLElement): boolean {
  if (el.closest('[data-bc-phase]') !== root) return false
  if (el === root) return true
  return CHANNEL_CLASSES.some((c) => el.classList.contains(c))
}

/** This presence's channel transitions still in play (a nested presence's are
 *  its own business). Transitions in their delay count. */
function ownTransitions(root: HTMLElement): Animation[] {
  const out: Animation[] = []
  for (const a of root.getAnimations({ subtree: true })) {
    if (!('transitionProperty' in a)) continue
    const target = (a.effect as KeyframeEffect | null)?.target
    if (target instanceof Element && ownChannel(target, root)) out.push(a)
  }
  return out
}

/**
 * ONE ANCHOR ON ITS WAY IN AND OUT (#431). The machine is machine.ts; this is
 * its React and DOM half.
 *
 * THE FIRST FRAME IS HIDDEN. A presence that mounts wanted renders its hidden
 * values, reads its style once in a layout effect (so they become the
 * transitions' starting point), and begins its entrance before the browser
 * paints. Chromium 103 has no @starting-style, and a rAF flip is a frame late.
 *
 * EVERY PHASE ENDS ON THE JS CLOCK (#252, ui/fade.ts). An entrance or a leave
 * ends on its last channel's transitionend, with the clock as the net at the
 * window plus FADE_SETTLE_MARGIN_MS, re-checked on every envelope. An entrance
 * the clock had to end that is still short of its target lands outright
 * (transitions off); a healthy one is not touched. The clock is injectable, so
 * a harness's slow motion and seek() hold the settle too.
 *
 * A SCOPE'S WAY OUT IS ONE (context.ts Drain). A leave the scope drove that
 * ends while others in the scope are still leaving parks the presence:
 * hidden, still mounted, holding its box. The last leave to end releases
 * every parked one, so a page never reflows around what is still on screen.
 */
export function usePresence(want: boolean, opts: PresenceOptions = {}): PresenceResult {
  const scope = useContext(ScopeCtx)
  const quickCtx = useContext(QuickCtx)
  const clockCtx = useContext(ClockCtx)
  const scoped = opts.scoped !== false
  const spec = getPreset(opts.preset ?? (scoped ? scope.preset : undefined))
  const now = opts.now ?? clockCtx
  const held = (scoped && scope.hold) || opts.hold === true
  const inputs: Inputs = {
    wanted: (scoped ? scope.want : true) && want && !held,
    held,
    quick: scoped && quickCtx,
    keep: opts.keepMounted === true || spec.layer,
  }
  const order = opts.order ?? 0
  const step = opts.step ?? (scoped ? scope.step : undefined) ?? spec.step

  const stagger = (t: number): StaggerCtx => ({
    now: t,
    order,
    step,
    spec,
    scopeStart: scoped ? scope.start : Number.NaN,
    maxOrder: scoped ? Math.max(order, scope.maxOrder()) : order,
  })
  // A leave the scope drove (its want is off) ends parked while others leave.
  const driven = scoped && !scope.want
  const latest = useRef({ stagger, now, driven })
  latest.current = { stagger, now, driven }

  const [st, setSt] = useState<PresenceState>(() => initialState(inputs, opts.appear ?? !spec.layer, now()))
  let s = st
  if (!sameInputs(st.inputs, inputs)) {
    s = update(st, inputs, stagger(now()))
    setSt(s)
  }

  // The scope learns this anchor's order, for a reversed way out.
  const register = scope.register
  useLayoutEffect(() => (scoped ? register(order) : undefined), [scoped, register, order])

  // THE DRAIN: this presence is counted while it leaves; parked, it waits for
  // the last leave in the drain to end, and the last one releases them all.
  const drain = scoped ? scope.drain : null
  const id = useRef(0)
  if (id.current === 0) id.current = ++presenceSeq
  const leavingNow = s.phase === 'leaving'
  useLayoutEffect(() => {
    if (drain === null || !leavingNow) return undefined
    const me = id.current
    drain.leaving.add(me)
    return () => { drain.leaving.delete(me); drained(drain) }
  }, [drain, leavingNow])
  useLayoutEffect(() => {
    if (drain === null || !s.parked) return undefined
    const me = id.current
    drain.parked.set(me, () => setSt((cur) => release(cur)))
    drained(drain)
    return () => { drain.parked.delete(me) }
  }, [drain, s.parked])

  const el = useRef<HTMLElement | null>(null)
  const setEl = useCallback((node: HTMLElement | null) => { el.current = node }, [])

  // THE HIDDEN FIRST FRAME, READ ONCE, THEN THE ENTRANCE.
  useLayoutEffect(() => {
    if (!s.pending) return
    const node = el.current
    if (node) void node.offsetWidth
    setSt((cur) => (cur.pending ? begin(cur, latest.current.stagger(latest.current.now())) : cur))
  }, [s.pending, s.since])

  // THE SETTLE: the last channel's transitionend, the clock as the net.
  useEffect(() => {
    if (s.phase !== 'entering' && s.phase !== 'leaving') return
    const phase = s.phase
    const since = s.since
    const win = windowOf(timingsFor(spec, phase), s.base)
    const node = el.current
    let done = false
    let timer = 0
    let off: () => void = () => {}

    function finish(byClock: boolean) {
      if (done) return
      done = true
      window.clearTimeout(timer)
      off()
      node?.removeEventListener('transitionend', onEnd)
      const stuck = byClock && phase === 'entering' && node !== null
        && ownTransitions(node).some((a) => a.playState === 'running')
      // Parked: a leave the scope drove, with another in the drain still leaving.
      const me = id.current
      const park = phase === 'leaving' && drain !== null && latest.current.driven
        && [...drain.leaving].some((other) => other !== me)
      setSt((cur) => (cur.phase === phase && cur.since === since ? settle(cur, stuck, park) : cur))
    }
    function onEnd(e: TransitionEvent) {
      const t = e.target
      if (done || !node || !(t instanceof Element) || !ownChannel(t, node)) return
      const left = ownTransitions(node).some((a) => a.playState === 'running' || a.playState === 'paused')
      if (!left) finish(false)
    }

    if (win === 0) {
      finish(false)
      return undefined
    }
    const clock = latest.current.now
    const fc = createFadeClock(false, win + FADE_SETTLE_MARGIN_MS, clock)
    fc.want(true)
    // A clock that has not moved since the last wake is held (a harness's
    // seek): look again in a while rather than spinning on it.
    let last = clock()
    const onTimer = () => {
      if (done) return
      if (fc.poll()) { finish(true); return }
      const t = clock()
      const stalled = t === last
      last = t
      timer = window.setTimeout(onTimer, stalled ? STALLED_MS : Math.max(16, fc.remaining()))
    }
    off = onEnvelope(() => { if (!done && fc.poll()) finish(true) })
    node?.addEventListener('transitionend', onEnd)
    timer = window.setTimeout(onTimer, Math.max(1, fc.remaining()))
    return () => {
      done = true
      window.clearTimeout(timer)
      off()
      node?.removeEventListener('transitionend', onEnd)
    }
    // A phase's spec and stagger are fixed when it begins; `since` names it.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [s.phase, s.since])

  const hidden = s.phase === 'hidden'
  const inert = hidden || held || s.phase === 'leaving'
  const style = {
    ...rootVars(spec, s),
    ...(inert ? { pointerEvents: 'none' } : null),
  } as unknown as CSSProperties

  const land = landAt(s, spec)
  const info = useMemo<PhaseInfo>(
    () => ({ phase: s.phase, epoch: s.epoch, landAt: land, now }),
    [s.phase, s.epoch, land, now],
  )

  return {
    mounted: s.mounted,
    phase: s.phase,
    held,
    info,
    rootProps: {
      ref: setEl,
      'data-bc-phase': s.phase,
      'data-bc-preset': spec.name,
      className: hidden || held ? 'layer-off' : undefined,
      style,
      'aria-hidden': hidden || held ? true : undefined,
      inert: inert ? true : undefined,
    },
  }
}
