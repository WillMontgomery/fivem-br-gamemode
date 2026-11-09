/**
 * UI V2'S BROADCAST SQUAD PANEL (#429): THE SQUAD PANEL AS A TV GRAPHICS
 * PACKAGE, BUILT FROM THE BROADCAST KIT (#431, src/ui/broadcast).
 *
 * The owner's pick for #429, ported from his preview
 * (previews/squad/broadcast/SquadPanel.tsx). Today's panel (SquadPanel.tsx)
 * stays as it is beside this one, as Market v2 and Locker v2 sit beside
 * theirs: today's HUD draws today's panel, and UI v2's HUD (hud/v2/HudV2.tsx)
 * draws this one in its squad slot, whose anchor stands down for its rows
 * (hud/v2/Anchor.tsx, `ownable`), so each row plays its own way in and out.
 *
 * The loading screen's Broadcast theme carried into the HUD. Every shape leans
 * on its one slant (15 degrees): each mate is a slanted plate, their color is
 * the hard edge down its left side, the name sits in the top band and health
 * and shield sit under it as bars with Anton numerals in a darker score cell
 * at the right. Dense, near opaque, high contrast: a lower third per mate.
 *
 * THE KIT DRAWS IT. Each row is a kit Plate (deck, the mate's color as its
 * edge and band wash, a lower score cell), its bars are kit Bars (slant, the
 * step feed), its numbers kit Numerals, DOWN a kit Tag, OUT a kit Stamp, the
 * DOWN alarm and the OUT plate kit Plate.Swaps, the red line a kit Plate.Foot,
 * its light kit LightSweeps, and every color, length, curve and duration is a
 * kit token. squadV2.css holds only what the kit has no piece for (the stack,
 * the on-air light's timing, the live landing, the name group, the cover's
 * line, the key mark), under the panel's own bsq- prefix. The root carries
 * bc-kit, the class the kit's tokens are declared on.
 *
 * ON AIR, OFF AIR (#431). Each row is a kit presence of its own (usePresence,
 * order = its place in the stack) inside the panel's PresenceScope, which
 * names the Broadcast preset in ONE place, whatever the HUD's style:
 *
 *   on air    the HUD comes up (the curtain lifts, the player lands, the ride
 *             or the gun-shop menu ends) or the panel first gets a squad: the
 *             edge rises, the plate opens from it, the face slides in, top
 *             mate first and 80 ms apart; a light crosses each plate as its
 *             face arrives, and every number TICKS IN (the kit Numeral's
 *             reveal: each place drops into place already its true digit)
 *   off air   the HUD goes away (the bus, the lobby, the ambulance, the match
 *             decided, the gun-shop menu) or the squad goes: the face goes,
 *             the plate closes toward its edge, the edge drops, bottom mate
 *             first, 40 ms apart, in about a third of a second
 *   the map, the pause menu, a scope   the layer's 150 ms quick hide, no
 *             stagger (the kit's QuickHide above us): a row going on air
 *             finishes underneath, so the return is the fade alone
 *
 * The squad going is an absence, like a mate leaving: the roster simply stops
 * having one. So the panel keeps its last frame with a squad and draws it on
 * the way off air; once every row is gone it draws nothing, today's rule.
 *
 * THE MOTION IS THE PACKAGE'S, AND EACH EVENT HAS ITS OWN MOVE. All of it is
 * CSS keyframes and transitions on transform and opacity, started by a VALUE
 * changing (useBeats: one counter per kind of change, from ./mateEvents, used
 * as a React key or an A/B class so a keyframe restarts). A timer starts one
 * motion, the owner's wait for a key that comes with its death, and ends
 * three, the nets under the animation clock (below); they run on the presence
 * clock (the kit's: monotonic in game, a harness's own in a preview), so slow
 * motion and seek() still hold every frame.
 *
 *   hit, big hit     the digits that changed tick down into place and burn
 *                    white, the new number whole from its first frame; the
 *                    bar drops at once and a white ghost lags then follows;
 *                    the plate flashes and the row jolts, both scaled to the
 *                    hit; a big hit (a quarter of the bar or more) also sends
 *                    a light sweep across the plate
 *   shield hit       a glint runs the shield bar, a shield-blue flash, a
 *                    smaller jolt, the ghost; the digits tick down
 *   shield breaks    the bar flashes white and SHATTERS (shards along what
 *                    was left of it), the new 0 slams in, a harder jolt
 *   heal, refill     a bright fill sweeps from the old value to the new; the
 *                    digits tick up and the numeral punches
 *   kill             a stinger (the theme's two slabs, in the mate's color)
 *                    crosses the plate, the color edge flares, the row punches
 *   down             the vitals band is covered by a red alarm plate that
 *                    slams in on the diagonal and keeps pulsing (capped and
 *                    graded: it burns at the far end and never goes solid,
 *                    and the clock always sits on dark red), the bleed clock
 *                    ticks inside it, a red DOWN tag wipes in, the color
 *                    edge pulses
 *   revived          the alarm plate wipes off, a burst runs out from the
 *                    color edge, the bars fill from 0
 *   dies             flash, the bars DRAIN (700 ms, slower than any damage
 *                    move), then the OUT plate replaces the band like a lower
 *                    third being swapped, OUT drops in, the row settles faded
 *   key drops        the red line slides in along the foot; the key drops in.
 *                    A key that comes before OUT's beat waits for it
 *   key retrieved    the key slams down with weight, an accent ring bursts
 *                    behind it, the row thuds, the line zips away in accent
 *   back in          the OUT plate wipes off, burst, bars fill to 100
 *   talking          VoiceMark's own pulse, plus a live level meter under the
 *                    name (paused, never restarted, between words)
 *   voice off        the mark switches on like a TV picture (a squash)
 *   bounty, Yubikey  the marks spin or drop in over a flash tag; the Yubikey
 *                    also sends an accent glint along the name band
 *   leaves           the row slides out on the diagonal, the rows under it
 *                    slide up, and every mate recolored by the leave gets
 *                    their color edge repainted
 *
 * Everything today's panel rules on is kept: the roster is the only source,
 * the voice mark sits beside the name, downed and dead never look alike (a
 * pulsing red alarm with a clock against a dark, hatched, still OUT plate), a
 * dead mate with a key is faded only to 0.7 and carries the key mark and the
 * draining red line at the foot of the card, health and shield are numbers as
 * well as bars, a number is whole and readable from the first frame it
 * changes (a row whose numbers change while it is still going on air lands at
 * once), and there is no new text.
 *
 * WHAT THE PORT CHANGED:
 *   - the imports point into src: the kit at ui/broadcast, Fit and the voice
 *     and mark glyphs where they live, and the mate events and the beats at
 *     ./mateEvents, where node pins them (scripts/test-mate-events.mjs)
 *   - the props are declared here, and they are today's panel's
 *   - the root carries bc-kit
 *   - THE NETS (#252): three steps ended on the browser's animation clock
 *     alone, and each now has a net on the JS clock (after(), below)
 *   - THE OWNER'S ORDER FOR A DEATH (decision 3): the key mark and its red
 *     line wait for OUT's beat when they come before it (useWaited)
 *   - A DIFFERENT SQUAD IS A NEW ONE ON AIR (the walkthrough's staged squad
 *     over the player's): the panel's scope is keyed by the squad's id
 * scripts/test-broadcast.mjs (section 10) pins the last five, and that the
 * sheet cascades after the kit.
 */
import {
  memo, useCallback, useContext, useEffect, useLayoutEffect, useRef, useState,
} from 'react'
import { onEnvelope } from '../bridge/nui'
import type { SquadMember, SquadPayload } from '../bridge/types'
import { useUi } from '../store'
import {
  Bar, Clock, LightSweep, Numeral, Plate, PresencePhaseCtx, PresenceScope, Stamp, Tag,
  EASE, STEP, T, ab, u, usePresence, vars,
} from '../ui/broadcast'
import Fit from '../ui/Fit'
import { createFadeClock, FADE_SETTLE_MARGIN_MS } from '../ui/fade'
import {
  OUT_PLATE_AT, OUT_PLATE_MS, OUT_WORD_AT, phaseOf, step, ZERO, type Beats, type Silence,
} from './mateEvents'
import VoiceMark from './VoiceMark'
import { BountyMark, YubikeyMark } from './YubikeyIcon'
import './squadV2.css'

/** What the panel takes: today's panel's props (SquadPanel.tsx), off the same
 *  selectors. */
export interface SquadPanelProps {
  squad: SquadPayload
  talking?: number[]
  /** THIS CLIENT's verdict, not anybody else's, straight off the voice
   *  envelope. */
  voiceSilent?: boolean
  /** ...and the player asked for it: the 'off' preference, or spectating. */
  voiceChosen?: boolean
}

const clamp = (v: number) => Math.max(0, Math.min(100, Math.round(v)))

/** The bleed clock's text ("120s"), as today's RowClock writes it. Module
 *  level, so the kit Clock's countdown is not re-armed on every render. */
const SECONDS = (s: number): string => `${s}s`

/** A dead mate with a key is faded only this far (one without settles at the
 *  kit's --bc-dim). */
const KEY_FADE = 0.7

/** The panel's presentational glints: the Yubikey's along the name band, and
 *  the light that crosses a plate going on air. */
const GLINT = 0.7

/** The squad's last frame, kept to take the rows off air with. */
interface Frame { squad: SquadPayload; talking: number[]; own: Silence }

// ---------------------------------------------------------------------------
// THE NETS UNDER THE ANIMATION CLOCK (#252, ui/fade.ts). Three steps here
// end on an event of the browser's animation clock: a mate who left is
// dropped on its leave's animationend, a death settles (the row starts to
// fade) on the OUT plate's, and the rows under a gap slide up on a Web
// Animation. A clock that stalls fires none of them. So each has a net on the
// JS clock, the kit's way (usePresence's settle): its own window plus
// FADE_SETTLE_MARGIN_MS, then the step taken. In a healthy page the event
// came a margin earlier and the net does nothing.
//
// WHAT THE NETS REACH, said plainly. The leave's net drops the departed row
// and the FLIP's cancels the slide, so a stalled clock no longer leaves a row
// behind or the rows offset. The death's net settles the row's state, so the
// row never waits on the plate's event, and that is all it does: what a death
// draws is the kit's CSS (the flash, the OUT plate and OUT are animations,
// the drain and the fade transitions), and a stalled clock holds every piece
// of it where it began, as it holds today's panel's flash, OUT stamp and fade
// (SquadPanel.tsx). None of the kit's one-shots has a net of its own.
// ---------------------------------------------------------------------------

/** How long to wait before looking again at a clock that is not moving (a
 *  harness's seek), as the kit's presences do. */
const STALLED_MS = 250

/**
 * `fn`, once `ms` have passed on `now`: a fade clock over that window
 * (createFadeClock), looked at by a timer and again by every envelope from
 * Lua, so a timer that never fired is not the end of it. Returns the cancel.
 */
function after(ms: number, now: () => number, fn: () => void): () => void {
  const fc = createFadeClock(false, ms, now)
  fc.want(true)
  let done = false
  let timer = 0
  let last = now()
  let off: () => void = () => {}
  const finish = () => {
    if (done) return
    done = true
    window.clearTimeout(timer)
    off()
    fn()
  }
  const look = () => {
    if (done) return
    if (fc.poll()) { finish(); return }
    const t = now()
    const stalled = t === last
    last = t
    timer = window.setTimeout(look, stalled ? STALLED_MS : Math.max(16, fc.remaining()))
  }
  off = onEnvelope(() => { if (!done && fc.poll()) finish() })
  timer = window.setTimeout(look, Math.max(1, fc.remaining()))
  return () => {
    done = true
    window.clearTimeout(timer)
    off()
  }
}

/**
 * THE OWNER'S ORDER FOR A DEATH (decision 3; the beats' half is
 * mateEvents.ts step()). The game mints a revive key on the death's own edge,
 * so the key and its red line usually come in the same push as the death, and
 * they wait for OUT's beat, as in the sequence he approved; one in a later
 * push that still comes before OUT's beat waits for what is left of it. Their
 * beat carries the wait as its `delay`. Here a beat that waits is not drawn
 * until its delay has passed on the presence clock; its element is keyed by
 * the beat's `n`, so it mounts fresh and plays as it is drawn. A beat with no
 * delay is drawn at once, and one that has waited stays drawn.
 */
function useWaited(beat: { n: number; delay: number }, now: () => number): boolean {
  const { n, delay } = beat
  const [played, setPlayed] = useState(n)
  const due = delay <= 0 || played === n
  useLayoutEffect(() => {
    if (due) return undefined
    return after(delay, now, () => setPlayed(n))
  }, [due, n, delay, now])
  return due
}

/**
 * TODAY'S RULE, KEPT: the panel draws rows for a squad with an id and more
 * than one member, and nothing for no squad or a squad of one
 * (SquadPanel.tsx). UI v2's HUD keys its squad anchor on it too
 * (hud/v2/HudV2.tsx): this is when the rows the anchor stands down for come.
 */
export function hasSquad(squad: SquadPayload): boolean {
  return !!squad.id && squad.members.length > 1
}

export default function SquadPanelV2({
  squad, talking = [], voiceSilent = false, voiceChosen = false,
}: SquadPanelProps) {
  // No squad, or a squad of one, draws nothing (hasSquad). A panel that HAD a
  // squad first takes it off air, drawing its last frame with one.
  const has = hasSquad(squad)
  // The viewer's own row takes the voice envelope's verdict (VoiceMark.tsx).
  const own: Silence = voiceSilent ? (voiceChosen ? 'chosen' : 'fault') : null
  const kept = useRef<Frame | null>(null)
  useEffect(() => { if (has) kept.current = { squad, talking, own } })
  const frame = has ? { squad, talking, own } : kept.current
  if (frame === null) return null
  // THE ONE PLACE THE PANEL NAMES ITS MOTION. The scope takes want, hold and
  // the quick hides from the HUD's scopes above it; it keeps the Broadcast
  // preset and its 80 ms step in every HUD style (the panel's own on-air
  // entrance), and its reveal starts when it goes live, so a squad that forms
  // mid-match goes on air top mate first too.
  //
  // A DIFFERENT SQUAD IS A NEW ONE ON AIR, so the scope is keyed by the
  // squad's id. The rows are read by server id, and a squad drawn over
  // another (the walkthrough's staged one over the player's: TutorialLayer.tsx,
  // selHudSquad) is no change to anybody in it: read as one, a row that shared
  // a server id played a hit, a shield break, a knock or a kill nobody took,
  // and a row that did not left on the diagonal under the new rows, as a mate
  // who left does. Keyed, the squad drawn goes at once and the new one goes on
  // air top mate first, its own reveal.
  return (
    <PresenceScope key={frame.squad.id} want={has} preset="broadcast" step={STEP}>
      <Board squad={frame.squad} talking={frame.talking} own={frame.own} on={has} />
    </PresenceScope>
  )
}

/** A row that is no longer in the roster. `off`: it vanished while the panel
 *  was already off air, so it only finishes going off air; otherwise it leaves
 *  on the diagonal, the panel's own leave. */
interface Gone { m: SquadMember; off: boolean }

/**
 * The stack. It owns the one motion no row can make for itself: a mate who
 * LEAVES is an absence, not an event -- their `src` is simply gone from the
 * roster. So the last reading of a vanished `src` is kept and drawn on its way
 * out, dropped when its exit ends, and the rows under it then slide up into
 * the room (a FLIP: first read the moment the departed row is dropped, last
 * read after the stack changes, animated with the Web Animations API, which
 * seek() holds like any CSS animation).
 *
 * A slot keeps its height while its row is off air with the HUD (an empty
 * box, as today's panel stayed mounted under the hidden HUD); the stack itself
 * draws nothing once the squad has gone and its last row has left.
 */
function Board({ squad, talking, own, on }: {
  squad: SquadPayload
  talking: number[]
  own: Silence
  on: boolean
}) {
  const silentFor = (m: SquadMember): Silence => {
    if (squad.you !== undefined && m.src === squad.you) return own
    return m.voiceOff === true ? 'chosen' : null
  }

  // Which rows are on screen (their presence mounted), by src: only a row that
  // can be seen has a way out to draw, and the stack knows when its last row
  // has gone off air.
  const [aired, setAired] = useState<ReadonlySet<number>>(() => new Set())
  const onAired = useCallback((src: number, up: boolean) => {
    setAired((s) => {
      if (s.has(src) === up) return s
      const n = new Set(s)
      if (up) n.add(src)
      else n.delete(src)
      return n
    })
  }, [])

  const last = useRef(squad.members)
  useEffect(() => { last.current = squad.members })
  const order = squad.members.map((m) => m.src).join(',')
  const [exits, setExits] = useState(() => ({ order, on, gone: [] as Gone[] }))
  let gone = exits.gone
  if (exits.order !== order || exits.on !== on) {
    const here = new Set(squad.members.map((m) => m.src))
    // A row nobody can see (the HUD away, or its way off air already over)
    // simply goes: there is nothing to draw on its way out.
    const left: Gone[] = exits.order === order
      ? []
      : last.current
        .filter((m) => !here.has(m.src) && aired.has(m.src))
        .map((m) => ({ m, off: !exits.on }))
    gone = [
      ...exits.gone.filter((g) => !here.has(g.m.src) && !left.some((l) => l.m.src === g.m.src)),
      ...left,
    ]
    setExits({ order, on, gone })
  }

  const box = useRef<HTMLDivElement>(null)
  const tops = useRef(new Map<string, number>())
  const drop = useCallback((src: number) => {
    // FLIP's FIRST, read at the last moment: where every row is laid out now,
    // with the departed one still in place. A reading kept from the last
    // change of the stack goes stale whenever the HUD's rem moves (a
    // resolution or interface-scale change), and the rows under the gap would
    // then slide the wrong distance.
    if (box.current) tops.current = topsOf(box.current)
    setExits((s) => (s.gone.some((g) => g.m.src === src)
      ? { ...s, gone: s.gone.filter((g) => g.m.src !== src) }
      : s))
  }, [])

  // The squad is gone and its last row has left: the stack draws nothing, as
  // for a solo player, and forgets where its rows were, so a squad that
  // arrives later goes on air in place rather than sliding from the old one's.
  const empty = !on && aired.size === 0
  useLayoutEffect(() => { if (empty) tops.current = new Map() }, [empty])

  const rows = [
    ...squad.members.map((m) => ({ m, out: false, off: false })),
    ...gone.map((g) => ({ m: g.m, out: !g.off, off: g.off })),
  ].sort((a, b) => a.m.src - b.m.src)

  // The clock the FLIP's net runs on: the presence clock of the anchor the
  // panel sits in (outside one, the kit's own, monotonic).
  const now = useContext(PresencePhaseCtx).now
  // Every FLIP still in play, until the net has seen it end.
  const flips = useRef<Animation[]>([])
  const shape = rows.map((r) => r.m.src).join(',')
  useLayoutEffect(() => {
    const el = box.current
    if (!el) return undefined
    const next = topsOf(el)
    for (const child of Array.from(el.children)) {
      if (!(child instanceof HTMLElement) || !child.dataset.src) continue
      const top = next.get(child.dataset.src)
      const was = tops.current.get(child.dataset.src)
      if (top !== undefined && was !== undefined && was !== top) {
        flips.current.push(child.animate(
          [{ transform: `translateY(${was - top}px)` }, { transform: 'translateY(0px)' }],
          { duration: T.flip, easing: EASE.out },
        ))
      }
    }
    tops.current = next
    // THE FLIP'S NET: an animation the browser never advances holds its row
    // on its first frame, offset by the gap. Once the newest has had T.flip
    // and the margin on the JS clock, every one still unfinished is canceled,
    // and its row is simply where it is laid out.
    flips.current = flips.current.filter((a) => a.playState !== 'finished')
    if (flips.current.length === 0) return undefined
    return after(T.flip + FADE_SETTLE_MARGIN_MS, now, () => {
      for (const a of flips.current) if (a.playState !== 'finished') a.cancel()
      flips.current = []
    })
  }, [shape, now])

  if (empty) return null

  return (
    <div ref={box} className="bc-kit bsq-panel" style={vars({ '--bsq-t-leave': `${T.rowLeave}ms` })}>
      {rows.map(({ m, out, off }, i) => (
        <Slot
          key={m.src}
          m={m}
          order={i}
          out={out}
          off={off}
          talking={!out && !off && talking.includes(m.src)}
          silent={out || off ? null : silentFor(m)}
          onDrop={drop}
          onAired={onAired}
        />
      ))}
    </div>
  )
}

/** Each row's layout top (offsetTop: unscaled here and in game), by src. */
function topsOf(el: HTMLElement): Map<string, number> {
  const out = new Map<string, number>()
  for (const child of Array.from(el.children)) {
    if (child instanceof HTMLElement && child.dataset.src) out.set(child.dataset.src, child.offsetTop)
  }
  return out
}

/** What a row draws as numbers. Downed and dead draw 0 UNDER the plate that
 *  covers the band, so a revive or a key spent fills from 0. */
function drawn(m: SquadMember): { hp: number; sh: number; level: number | null } {
  const alive = phaseOf(m) === 'alive'
  return {
    hp: alive ? clamp(m.hp) : 0,
    sh: alive ? clamp(m.armour ?? 0) : 0,
    level: typeof m.level === 'number' && m.level >= 1 ? m.level : null,
  }
}

function numbersOf(m: SquadMember): string {
  const d = drawn(m)
  return `${d.hp}|${d.sh}|${d.level ?? ''}`
}

interface SlotProps {
  m: SquadMember
  order: number
  out: boolean
  off: boolean
  talking: boolean
  silent: Silence
  onDrop: (src: number) => void
  onAired: (src: number, up: boolean) => void
}

/**
 * ONE MATE'S PLACE IN THE STACK: three boxes, so no two motions share a
 * transform.
 *   .bsq-slot   the layout box; the FLIP moves it
 *   .bsq-air    the row's kit presence (data-bc-phase): on air, off air
 *   .bsq-move   the panel's own leave, when the mate leaves the squad
 * A presence that has gone leaves its slot empty (it keeps its height).
 */
function Slot({ m, order, out, off, talking, silent, onDrop, onAired }: SlotProps) {
  const p = usePresence(!off, { order })
  const mounted = p.mounted
  const gone = out || off
  const src = m.src
  const now = p.info.now

  useLayoutEffect(() => {
    if (!mounted) return undefined
    onAired(src, true)
    return () => onAired(src, false)
  }, [mounted, src, onAired])
  // A departed row whose presence has gone (it finished going off air, or the
  // HUD went away first) has nothing left to draw: dropped before the empty
  // slot is ever painted, so the rows under it slide up from where they were.
  useLayoutEffect(() => { if (gone && !mounted) onDrop(src) }, [gone, mounted, src, onDrop])
  // THE LEAVE'S NET: a mate who left is dropped on the leave's animationend
  // (below), or by the JS clock once the leave (T.rowLeave, the panel's
  // --bsq-t-leave) and the margin have passed.
  useEffect(() => {
    if (!out || !mounted) return undefined
    return after(T.rowLeave + FADE_SETTLE_MARGIN_MS, now, () => onDrop(src))
  }, [out, mounted, now, src, onDrop])

  // A NUMBER IS NEVER HIDDEN AT THE MOMENT IT CHANGES. The kit Numeral shows
  // itself at once when it changes while its presence is still entering, but
  // the face it sits in is still sliding and fading in. So a row whose
  // health, shield or level changes while it is entering lands at once
  // (data-bsq-live, squadV2.css), as UI v2's HUD lands an anchor. The test is
  // the Numeral's own (a true change during the entering phase), so the row
  // and its numerals always land together. Once landed, nothing in the row is
  // left waiting to tick in for the rest of that entrance (data-bsq-landed): a
  // place whose digit did not change would otherwise sit a tick low under its
  // white copy until the content would have landed, then tick in late.
  const nums = numbersOf(m)
  const epoch = p.info.epoch
  const [live, setLive] = useState({ nums, epoch: -1 })
  let liveEpoch = live.epoch
  if (live.nums !== nums) {
    liveEpoch = p.phase === 'entering' ? epoch : live.epoch
    setLive({ nums, epoch: liveEpoch })
  }
  const landedHere = liveEpoch === epoch
  const landed = p.phase === 'entering' && landedHere

  const cls = `bsq-slot${out ? ' is-leaving' : ''}`
  if (!mounted) return <div data-src={src} className={cls} />
  const rp = p.rootProps
  // A MATE WHO LEAVES slides out on the panel's own keyframes while the row's
  // presence stays shown, so the slot names its exit to the kit
  // (data-bc-exit): its numbers, each standing alone (the level, the bars',
  // the bleed clock), go as the exit starts, never seen riding it.
  return (
    <div data-src={src} className={cls} data-bc-exit={out ? '' : undefined}>
      <div
        {...rp}
        className={rp.className ? `bsq-air ${rp.className}` : 'bsq-air'}
        data-bsq-live={landed ? '' : undefined}
        data-bsq-landed={landedHere ? '' : undefined}
      >
        <PresencePhaseCtx.Provider value={p.info}>
          <div
            className="bsq-move"
            onAnimationEnd={out
              ? (e) => { if (e.target === e.currentTarget && e.animationName === 'bsqLeave') onDrop(src) }
              : undefined}
          >
            <Row m={m} talking={talking} silent={silent} air={epoch} now={now} />
          </div>
        </PresencePhaseCtx.Provider>
      </div>
    </div>
  )
}

/**
 * The beats for one mate (mateEvents.ts step), derived during render (React's
 * "information from previous renders" pattern): the row is memoized on its
 * VALUES, so the 1 Hz re-push of an unchanged squad never reaches here, and a
 * real change costs one comparison and no effect. Mount-time state is not an
 * event: every counter starts at 0, and a row going on air is a mount (its
 * presence remounts it), so it fires none. Each change is read at its time on
 * the row's presence clock, `now`, the clock its waits run on (useWaited).
 */
function useBeats(m: SquadMember, silent: Silence, now: () => number): Beats {
  const [s, setS] = useState(() => ({ m, silent, b: ZERO }))
  if (s.m !== m || s.silent !== silent) {
    const b = step(s.b, s.m, m, s.silent, silent, now())
    setS({ m, silent, b })
    return b
  }
  return s.b
}

function sameMember(a: SquadMember, b: SquadMember): boolean {
  return a === b || (
    a.src === b.src && a.name === b.name && a.state === b.state
    && a.hp === b.hp && a.armour === b.armour && a.colour === b.colour
    && a.kills === b.kills && a.leader === b.leader && a.level === b.level
    && a.bleedEndsAt === b.bleedEndsAt && a.voiceOff === b.voiceOff
    && a.reviveKey === b.reviveKey && a.reviveKeyEndsAt === b.reviveKeyEndsAt
    && a.yubikey === b.yubikey && a.bounty === b.bounty
  )
}

// ---------------------------------------------------------------------------
// ONE MATE: a kit Plate.
//
//   deck       the plate and what happens TO it: the kit's flash, shake,
//              burst, recolor and flare beats, the on-air meter, and the
//              light (fx: the on-air glint, a big hit's sweep, a kill's
//              stinger, a Yubikey's name glint), under the score cell, so the
//              numerals are always on near-black
//   face       the name line and the two bars, upright, each line stepped in
//              along the slant (Plate.Line)
//   cover      what REPLACES the vitals band (the DOWN alarm, the OUT plate,
//              as Plate.Swaps) and the key's red line along the foot
//   coverFace  what those plates carry: the bleed clock, OUT and the key mark
// ---------------------------------------------------------------------------

interface RowProps {
  m: SquadMember
  talking: boolean
  silent: Silence
  /** The row's entrances so far (its presence's epoch): each one sends the
   *  on-air light across the plate. */
  air: number
  /** The row's presence clock (its PhaseInfo's now): the death's net and the
   *  owner's wait run on it. */
  now: () => number
}

const Row = memo(function Row({ m, talking, silent, air, now }: RowProps) {
  const b = useBeats(m, silent, now)
  // The death sequence is "settled" once the OUT plate has landed (its
  // animationend, or the net below); until then the row holds full strength,
  // so the drain and the plate are seen whole, and the fade starts on that
  // landing. A key that drops a second after the death (the next beacon)
  // lands inside this window and cannot postpone the fade: it only decides
  // how far it goes (0.7, not the kit's 0.34).
  const [settled, setSettled] = useState(0)
  // The pickup line's last fraction, so a retrieved key zips the line away
  // from where it was rather than from full.
  const lineFrac = useRef(1)

  const phase = phaseOf(m)
  const alive = phase === 'alive'
  const down = phase === 'down'
  const dead = phase === 'dead'
  const dying = dead && b.death.n > settled
  const { hp, sh, level } = drawn(m)
  // `false` is a real reading (a key exists, not ours yet): never a truthiness test.
  const keyHeld = m.reviveKey === true
  const keyOut = m.reviveKey === false
  const hasKey = keyHeld || keyOut
  const yubikey = typeof m.yubikey === 'string' && m.yubikey !== '' ? m.yubikey : null
  const bounty = typeof m.bounty === 'string' && m.bounty !== '' ? m.bounty : null
  const deathN = b.death.n

  // THE DEATH'S NET: settled on the OUT plate's animationend (below), or by
  // the JS clock once the plate's landing (OUT_PLATE_AT, then its own slide,
  // OUT_PLATE_MS) and the margin have passed. It settles the state alone: the
  // fade it starts is the kit's transition, and a stalled clock holds it, the
  // OUT plate and OUT where they began (the nets' note, above).
  useEffect(() => {
    if (!dying) return undefined
    return after(OUT_PLATE_AT + OUT_PLATE_MS + FADE_SETTLE_MARGIN_MS, now, () => setSettled(deathN))
  }, [dying, deathN, now])

  // THE OWNER'S ORDER (useWaited): the key mark and the line's zip wait on
  // the key's beat, the red line on its own.
  const keyDue = useWaited(b.keyAnim, now)
  const lineDue = useWaited(b.lineIn, now)

  return (
    <Plate
      variant="deck"
      mate={m.colour}
      band={1.32}
      cell="lower"
      state={down ? 'alarm' : dead ? 'out' : 'rest'}
      fade={dying ? 1 : hasKey ? KEY_FADE : undefined}
      outDelay={dying ? OUT_PLATE_AT : 0}
      flash={b.flash}
      shake={b.shake}
      burst={b.rise.n}
      recolor={b.color}
      flare={b.elim}
      meter={talking}
      fx={(
        <>
          {/* ON AIR: a light crosses the plate as its face slides in
              (squadV2.css: timed by the presence itself). */}
          {air > 0 && (
            <div className="bsq-onair"><LightSweep kind="sweep" beat={air} power={GLINT} /></div>
          )}
          <LightSweep kind="sweep" beat={b.sweep.n} power={b.sweep.power} />
          <LightSweep kind="stinger" beat={b.elim} />
          <LightSweep kind="name" beat={b.yubikey} power={GLINT} />
        </>
      )}
      cover={(
        <>
          {/* The alarm's red is capped by its holder and graded by the shade
              over it, so the pulse inside can run at today's full
              .mate-pulse and the band still never goes solid. */}
          {down && <Plate.Swap key={`al${b.downed}`} kind="alarm" motion={b.downed > 0 ? 'in' : 'none'} />}
          {alive && b.rise.n > 0 && b.rise.kind === 'revive' && (
            <Plate.Swap key={`ra${b.rise.n}`} kind="alarm" motion="out" still />
          )}
          {/* Bleeding out from down: the red, held mid-pulse, drains away
              before OUT lands. */}
          {dead && deathN > 0 && b.death.from === 'down' && (
            <Plate.Swap key={`ad${deathN}`} kind="alarm" motion="none" still drain />
          )}
          {dead && (
            <Plate.Swap
              key={`op${deathN}`}
              kind="out"
              motion={deathN > 0 ? 'in' : 'none'}
              delay={OUT_PLATE_AT}
              onLanded={() => setSettled(deathN)}
            />
          )}
          {alive && b.rise.n > 0 && b.rise.kind === 'backIn' && (
            <Plate.Swap key={`ro${b.rise.n}`} kind="out" motion="out" />
          )}
        </>
      )}
      coverFoot={(
        <>
          {/* THE OWNER'S RED LINE (2026-09-02): the pickup window, along the
              card's foot, draining, its red pulsing. Only while there is
              something on the ground, and only once its beat's wait is over. */}
          {!!m.reviveKeyEndsAt && lineDue && (
            <PickupLine key={`pl${b.lineIn.n}`} endsAt={m.reviveKeyEndsAt} fresh={b.lineIn.n > 0} frac={lineFrac} />
          )}
          {dead && keyDue && b.zip.n > 0 && b.zip.death === deathN && (
            <Plate.Zip key={`z${b.zip.n}`} from={lineFrac.current} />
          )}
        </>
      )}
      coverFace={(
        <>
          {down && !!m.bleedEndsAt && (
            <Plate.Line cy={2.36} ch={0.5} lh={2.08} between className="bsq-big">
              <span key={`ck${b.downed}`} className={`bsq-clockwrap${b.downed > 0 ? ' is-new' : ''}`}>
                <BleedClock endsAt={m.bleedEndsAt} />
              </span>
            </Plate.Line>
          )}
          {dead && (
            <Plate.Line cy={2.36} ch={0.5} lh={2.08} between className="bsq-big">
              <Stamp word="OUT" size="band" kind="drop" beat={deathN} delay={OUT_WORD_AT} tone="var(--bc-ink-quiet)" />
              {hasKey && keyDue && (
                <KeyMark key={`km${b.keyAnim.n}`} held={keyHeld} anim={b.keyAnim.n > 0 ? b.keyAnim.kind : null} />
              )}
            </Plate.Line>
          )}
        </>
      )}
    >
      <Plate.Line cy={0.68} ch={0.44} lh={1.2} between>
        <span className="bsq-who">
          <span className={`bsq-voice${ab('is-cut', b.voiceCut)}`}>
            <VoiceMark fs={u(0.72)} talking={talking} silent={silent} />
          </span>
          <Fit inline tut="squad-name" className="bsq-name">{m.name}</Fit>
          {level !== null && (
            <span key={`lv${b.level}`} className={`bsq-level${b.level > 0 ? ' is-new' : ''}`}>
              <Numeral value={level} tone="dim" fs="var(--bc-fs-caption)" />
            </span>
          )}
          {yubikey !== null && (
            <Tag variant="holder" tone="accent" enter="drop" beat={b.yubikey}>
              <YubikeyMark glyph={yubikey} />
            </Tag>
          )}
          {bounty !== null && (
            <Tag variant="holder" tone="danger" enter="spin" beat={b.bounty}>
              <BountyMark glyph={bounty} />
            </Tag>
          )}
        </span>
        {down && <Tag beat={b.downed} enter="wipe">DOWN</Tag>}
      </Plate.Line>
      <Plate.Line cy={1.84} ch={0.44} lh={0.9}>
        <Bar value={hp} tone="hp" num zeroNum numBeat={{ n: b.hpPop, kind: 'pop' }} gain={b.hpUp} drain={dying} />
      </Plate.Line>
      <Plate.Line cy={2.86} ch={0.44} lh={0.9}>
        <Bar
          value={sh} tone="shield" num zeroNum numBeat={b.shPop} gain={b.shUp} glint={b.shHit}
          crack={b.shBreak} drain={dying}
        />
      </Plate.Line>
      {/* The walkthrough's "squad-bars" card rings the vitals band. */}
      <div data-tut="squad-bars" className="bsq-bars" aria-hidden />
    </Plate>
  )
}, (a, b) => a.talking === b.talking && a.silent === b.silent && a.air === b.air && a.now === b.now
  && sameMember(a.m, b.m))

// ---------------------------------------------------------------------------
// TODAY'S CLOCKS, UNCHANGED IN DISCIPLINE: a server deadline against
// Date.now() + clockOffset.
// ---------------------------------------------------------------------------

/** RowClock as the kit's Clock: `Math.ceil(left / 1000)` and an `s`, as
 *  DbnoOverlay draws it, on the drift-corrected countdown (one wake per
 *  displayed second). Each new second after the first punches (the shot
 *  clock's beat); the first write is the state, not a tick. */
function BleedClock({ endsAt }: { endsAt: number }) {
  const offset = useUi((s) => s.clockOffset)
  return <Clock endsAt={endsAt} offset={offset} format={SECONDS} />
}

/** KeyDrain in a kit Plate.Foot: full when first seen, draining to the
 *  deadline on today's 250 ms interval, written straight to the node.
 *  `mate-pulse` fades the red, `bar-fill` owns the transform: two channels,
 *  as today. */
function PickupLine({ endsAt, fresh, frac }: { endsAt: number; fresh: boolean; frac: { current: number } }) {
  const ref = useRef<HTMLDivElement>(null)
  const offset = useUi((s) => s.clockOffset)
  const total = useRef(0)
  useEffect(() => {
    total.current = 0
    const tick = () => {
      const left = Math.max(0, endsAt - (Date.now() + offset))
      if (total.current <= 0) total.current = Math.max(1, left)
      const f = Math.min(1, left / total.current)
      frac.current = f
      if (ref.current) ref.current.style.transform = `scaleX(${f})`
    }
    tick()
    const id = window.setInterval(tick, 250) // cef-ok: today's clock discipline (KeyDrain)
    return () => window.clearInterval(id)
  }, [endsAt, offset, frac])
  return (
    <Plate.Foot fresh={fresh}>
      <div ref={ref} className="bar-fill mate-pulse bsq-pickup-fill" />
    </Plate.Foot>
  )
}

/** Today's key glyph (SquadPanel.tsx KEY_PATH, its cropped viewBox and size). */
const KEY_PATH =
  'M4.7 3.8a4.2 4.2 0 1 0 0 8.4a4.2 4.2 0 1 0 0-8.4Z'
  + 'M4.7 6.25a1.75 1.75 0 1 1 0 3.5a1.75 1.75 0 1 1 0-3.5Z'
  + 'M7.5 6.9H15.4V12.2H14.2V9.1H12.8V12.2H11.6V9.1H7.5Z'

function KeyMark({ held, anim }: { held: boolean; anim: 'drop' | 'slam' | null }) {
  return (
    <span className={`bsq-key${held ? ' is-held' : ''}${anim ? ` is-${anim}` : ''}`} aria-hidden>
      {anim === 'slam' && <i className="bsq-key-ring" />}
      <svg viewBox="0.5 3.8 14.9 8.4" className="bsq-key-svg" aria-hidden>
        <path d={KEY_PATH} fill="currentColor" />
      </svg>
    </span>
  )
}
