import { useContext, useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type RefObject } from 'react'
import { formatCountdown, startCountdown } from './deps'
import { PresencePhaseCtx, type PhaseInfo } from './motion/context'
import { cameBack, inLabel, runs, wayOf, wayStart, type Way } from './motion/label'
import { COUNT, REVEAL_PLACE_MS } from './motion/tokens'
import { ab, toneColor, vars, type Tone } from './util'

/**
 * NUMERAL (#431): a scoreboard's digits. Fixed columns, one per place, so
 * figures line up; at rest PLAIN STATIC TEXT -- no strip, no clip.
 *
 * A NUMBER IS NEVER HIDDEN AT THE MOMENT IT CHANGES. A place whose digit
 * changes is a fresh element holding the NEW digit, whole and opaque from its
 * first frame: it ticks into place (down when the number fell, up when it
 * rose) and a white copy over it burns off, so the place that changed is the
 * one that lights. A slam (a shield's new 0) is the whole number's move: no
 * place ticks, every place burns, held to --bc-slam inside its plate.
 *
 * UNDER A PRESENCE a numeral is `.bc-whole`: it appears when its content lands
 * and goes the moment its content leaves, so it is never seen half-faded or
 * moving. One that CHANGES while its presence is still entering shows at once.
 *
 * A NUMBER IN A LABEL LEAVES WITH ITS WORDS (motion/label.ts reads which side
 * it is on after every render; it carries `data-bc-run`): one with words or a
 * glyph beside it in its box ("Send 2 reports", "7,450 VOLTS", "8/8"), in a
 * box that says it is a label (data-bc-label: a strike or a chip drawn in
 * CSS), or that is a button's or a tag's whole label, keeps its opacity
 * through the leave, so it fades and slides exactly as its words do and they
 * never read "SEND REPORTS". It still lands with its content and ticks in. A
 * leave that begins before it has landed finds nothing on screen to take
 * out: it is hidden as a number alone is, and its entrance never lands
 * mid-leave. If its presence turns round while it is still showing, that
 * entrance neither hides it nor ticks it in again (useWay).
 *
 *   reveal 'tick'   THE DEFAULT, THE OWNER'S PICK (2026-11-03): its places
 *                   tick in, one after another, as it lands, each already
 *                   showing its true digit
 *          'none'   it appears whole when its content lands
 *          'count'  it counts up in at most ten discrete writes, ending on its
 *                   true value; a change mid-count jumps to the new true value,
 *                   and the count is dropped while hidden. (Not picked.)
 * Outside a presence nothing reveals: a numeral there is simply shown.
 */

type Kind = 'fall' | 'rise' | 'flat' | 'reveal' | 'still'
interface Col { k: number; kind: Kind }

const SIZE = {
  sm: 'var(--bc-fs-num-sm)',
  md: 'var(--bc-fs-num-md)',
  lg: 'var(--bc-fs-num-lg)',
} as const

export interface NumeralProps {
  value: number
  /** Fixed columns, blank-padded (3 lines health and shield up). */
  places?: number
  tone?: Tone | (string & {})
  size?: keyof typeof SIZE
  /** A size of your own (a CSS length). */
  fs?: string
  /** A punch, keyed by n: 'pop' (1.22x) or 'slam' (from 1.4x). */
  beat?: { n: number; kind: 'pop' | 'slam' }
  /** Draw nothing for 0 (health and shield: the empty bar says it). */
  blankZero?: boolean
  /** How it arrives under a presence. Default 'tick' (the owner's pick). */
  reveal?: 'none' | 'tick' | 'count'
  /** The heavier shadow, for a numeral on a fill (the vitals pill). */
  heavy?: boolean
  /** How the value is written (default: its digits). A separator is a column
   *  of its own width (the Market's 7,450). */
  format?: (v: number) => string
  className?: string
  style?: CSSProperties
}

const padTo = (text: string, width: number): string[] => text.padStart(width, ' ').split('')

export function Numeral({
  value, places = 1, tone = 'ink', size = 'sm', fs, beat, blankZero = false, reveal = 'tick', heavy = false,
  format, className, style,
}: NumeralProps) {
  const info = useContext(PresencePhaseCtx)
  const ref = useRef<HTMLSpanElement>(null)
  const v = Math.max(0, Math.round(value))
  const pop = beat?.n ?? 0
  const popKind = beat?.kind ?? 'pop'

  const [s, setS] = useState(() => ({
    text: blankZero && v === 0 ? '' : (format ?? String)(v),
    num: v, trueV: v, pop, cols: [] as Col[], liveEpoch: -1, revEpoch: -1, revDelay: 0,
  }))
  const run = useInLabel(ref)
  const way = useWay(info, run, s.liveEpoch)
  const back = cameBack(way)
  const shown = useCountUp(v, reveal === 'count' && !back, info)
  const text = blankZero && shown.value === 0 ? '' : (format ?? String)(shown.value)
  let cur = s
  const revealNow = reveal === 'tick' && info.phase === 'entering' && info.epoch !== s.revEpoch && !back
  if (s.text !== text || s.pop !== pop || revealNow || s.trueV !== v) {
    const width = Math.max(places, text.length, s.text.length)
    const was = padTo(s.text, width)
    const now = padTo(text, width)
    const slam = s.pop !== pop && popKind === 'slam'
    const kind: Kind = shown.counting ? 'still' : slam ? 'flat' : shown.value < s.num ? 'fall' : 'rise'
    const cols: Col[] = []
    for (let p = 0; p < width; p++) {
      const i = width - 1 - p
      const c = s.cols[p] ?? { k: 0, kind: 'still' }
      if (revealNow) cols[p] = { k: c.k + 1, kind: 'reveal' }
      else if (kind !== 'still' && (slam || was[i] !== now[i])) cols[p] = { k: c.k + 1, kind }
      else cols[p] = c
    }
    cur = {
      text,
      num: shown.value,
      trueV: v,
      pop,
      cols,
      // A true change while entering: show it now, never hide it.
      liveEpoch: s.trueV !== v && info.phase === 'entering' ? info.epoch : s.liveEpoch,
      revEpoch: revealNow ? info.epoch : s.revEpoch,
      revDelay: revealNow ? Math.max(0, Math.round(info.landAt - info.now())) : s.revDelay,
    }
    setS(cur)
  }

  const width = Math.max(places, text.length)
  const chars = padTo(text, width)
  const live = info.phase === 'entering' && cur.liveEpoch === info.epoch
  const cls = [
    'bc-num', 'bc-whole', heavy ? 'bc-num--heavy' : '',
    ab(popKind === 'slam' ? 'is-slam' : 'is-pop', pop).trim(), className ?? '',
  ].filter(Boolean).join(' ')

  return (
    <span
      ref={ref}
      className={cls}
      data-bc-run={runs(run, way) ? '' : undefined}
      data-bc-live={live ? '' : undefined}
      style={{ ...vars({ '--bc-num-fs': fs ?? SIZE[size], '--bc-num-c': toneColor(tone) }), ...style }}
      aria-label={text === '' ? undefined : text}
    >
      {chars.map((ch, i) => {
        const p = width - 1 - i
        const c = cur.cols[p] ?? { k: 0, kind: 'still' as Kind }
        const digit = ch === ' ' ? null : ch
        const animated = c.k > 0 && c.kind !== 'still'
        const delay = c.kind === 'reveal' ? `${cur.revDelay + i * REVEAL_PLACE_MS}ms` : undefined
        const sep = digit !== null && !/[0-9]/.test(digit)
        const colCls = `bc-col${sep ? ' bc-col--sep' : ''}${animated ? ` is-${c.kind}` : ''}`
        return (
          <span key={`${p}.${c.k}`} className={colCls} style={delay ? { animationDelay: delay } : undefined} aria-hidden>
            {digit}
            {animated && digit !== null && (
              <i className={`bc-hot${c.kind === 'reveal' ? ' is-reveal' : ''}`} style={delay ? { animationDelay: delay } : undefined}>
                {digit}
              </i>
            )}
          </span>
        )
      })}
    </span>
  )
}

/**
 * WHICH SIDE OF THE RULE IT IS ON (motion/label.ts): in a label, or alone.
 * Read after every render, before paint: the words beside a number come and
 * go with its parent's (a struck price, a currency), and the rule must be
 * right on the leave's first frame.
 */
function useInLabel(ref: RefObject<Element | null>): boolean {
  const [run, setRun] = useState(false)
  useLayoutEffect(() => {
    const el = ref.current
    const r = el !== null && inLabel(el)
    if (r !== run) setRun(r)
  })
  return run
}

/**
 * THE WAY OUT AND BACK (motion/label.ts wayOf), read on every render. A
 * number in a label leaves with its words only if it was showing as the
 * leave began (landed, live, or come back still showing); otherwise it is
 * hidden as a number alone is, so its pending entrance never lands mid-leave.
 * A presence that turns round while it is still showing finds it so: that
 * entrance neither hides it nor reveals it again (its tick-in would drop it a
 * tick low under a white copy until the content landed), and it does not
 * count up. `liveEpoch`: the entrance it last changed in and showed at once.
 */
function useWay(info: PhaseInfo, run: boolean, liveEpoch: number): Way {
  const [w, setW] = useState(() => wayStart(info))
  const next = wayOf(w, info, info.now(), run, liveEpoch === w.epoch)
  if (next !== w) setW(next)
  return next
}

/**
 * THE COUNT-UP: at most COUNT.writes discrete writes (timers, not frames),
 * from the moment the content lands, the last one the true value.
 */
function useCountUp(v: number, enabled: boolean, info: PhaseInfo): { value: number; counting: boolean } {
  const [c, setC] = useState<{ v: number; epoch: number; k: number; value: number }>(
    () => ({ v, epoch: info.epoch, k: COUNT.writes, value: v }),
  )
  let cur = c
  if (enabled && info.phase === 'entering' && info.epoch !== c.epoch && v > 0) {
    cur = { v, epoch: info.epoch, k: 0, value: 0 }
    setC(cur)
  } else if (v !== c.v) {
    cur = { v, epoch: info.phase === 'entering' ? info.epoch : c.epoch, k: COUNT.writes, value: v }
    setC(cur)
  } else if (c.k < COUNT.writes && (info.phase === 'leaving' || info.phase === 'hidden')) {
    cur = { ...c, k: COUNT.writes, value: v }
    setC(cur)
  }
  const counting = cur.k < COUNT.writes
  const { landAt, now } = info
  const k = cur.k
  const epoch = cur.epoch
  useEffect(() => {
    if (!counting) return undefined
    const dt = COUNT.ms / (COUNT.writes - 1)
    const due = landAt + k * dt
    let t = 0
    let last = now()
    const write = () => {
      const at = now()
      const left = due - at
      if (left > 1) {
        // A clock that has not moved (a harness's seek): look again later.
        t = window.setTimeout(write, at === last ? 250 : Math.max(16, left))
        last = at
        return
      }
      setC((x) => {
        if (x.k >= COUNT.writes || x.epoch !== epoch || x.k !== k) return x
        const next = x.k + 1
        return { ...x, k: next, value: next >= COUNT.writes ? x.v : Math.round((x.v * next) / COUNT.writes) }
      })
    }
    t = window.setTimeout(write, Math.max(0, due - now()))
    return () => window.clearTimeout(t)
  }, [counting, k, epoch, landAt, now])
  return { value: cur.value, counting }
}

const CLOCK_SIZE = {
  sm: 'var(--bc-fs-clock-sm)',
  md: 'var(--bc-fs-clock-md)',
  lg: 'var(--bc-fs-clock-lg)',
} as const

/**
 * CLOCK: a server deadline written through a ref ('--' until the first
 * write), on the drift-corrected countdown (one wake per displayed second, no
 * frame loop). `beat` punches each new second after the first: a shot clock's
 * beat, never on mount. In a label it leaves with its words, as a Numeral
 * does (and, as a Numeral does, only if it was showing as the leave began).
 */
export function Clock({
  endsAt, offset = 0, format = formatCountdown, beat = true, size = 'sm', fs, tone = 'ink', className, style,
}: {
  /** Server ms (0: no deadline yet, '--'). */
  endsAt: number
  /** The store's clockOffset. */
  offset?: number
  /** Whole seconds to text (formatCountdown, formatClock or your own). */
  format?: (totalSeconds: number) => string
  beat?: boolean
  size?: keyof typeof CLOCK_SIZE
  fs?: string
  tone?: Tone | (string & {})
  className?: string
  style?: CSSProperties
}) {
  const info = useContext(PresencePhaseCtx)
  const ref = useRef<HTMLSpanElement>(null)
  useEffect(() => {
    if (!endsAt) return undefined
    let first = true
    return startCountdown(
      endsAt,
      offset,
      (text) => {
        const el = ref.current
        if (el && el.textContent !== text) {
          el.textContent = text
          if (beat && !first) el.setAttribute('data-p', el.getAttribute('data-p') === '0' ? '1' : '0')
        }
        first = false
      },
      Date.now,
      (cb, ms) => window.setTimeout(cb, ms),
      (h) => window.clearTimeout(h),
      format,
    )
  }, [endsAt, offset, format, beat])
  const run = useInLabel(ref)
  const way = useWay(info, run, -1)
  return (
    <span
      ref={ref}
      className={`bc-clock bc-whole${className ? ` ${className}` : ''}`}
      data-bc-run={runs(run, way) ? '' : undefined}
      style={{ ...vars({ '--bc-num-fs': fs ?? CLOCK_SIZE[size], '--bc-num-c': toneColor(tone) }), ...style }}
    >
      --
    </span>
  )
}
