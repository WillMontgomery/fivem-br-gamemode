/**
 * The guided first run, lobby half — the layer that drives it (#261).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * IT RENDERS INSIDE THE UI ROOT, AND THAT IS LOAD-BEARING
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Owner, 2026-09-04: "If/when they select buttons to open the big map or the
 * GTA V pause menu, our annotations should hide and come back when the rest of
 * the UI does too."
 *
 * That is free, and only free, if this is a child of the root App.tsx already
 * fades on `frontendUp` — opacity 0, pointerEvents none, aria-hidden, driven by
 * the `frontend` message br_ui/client/pause.lua sends. So THIS MUST NEVER BE
 * PORTALLED TO document.body. A portal would put it outside that subtree and it
 * would be the one thing left on screen over the pause menu, which is the exact
 * bug he asked to avoid.
 *
 * ═══ THE TARGET IS MEASURED EVERY FRAME, NOT STORED ═══
 *
 * He also asked for the tutorial to walk a player through changing the
 * interface and text size, and to respect aspect ratio "the same way we do with
 * everything else". Both of those mean the thing a card points at MOVES AND
 * RESIZES WHILE THE CARD IS ON SCREEN.
 *
 * A stored coordinate cannot survive that. A rect measured on a rAF loop
 * survives all of it — a slider drag, a 16:9 to 32:9 change, a panel opening
 * underneath — with no resize listener, no breakpoint list and no knowledge of
 * what caused the move. The cost is one getBoundingClientRect per frame against
 * one element, and state is only written when the rect actually changes, so the
 * React tree is not re-rendered sixty times a second while nothing moves.
 *
 * ═══ THE PLAYER PRESSES THE REAL CONTROL ═══
 *
 * Owner, 2026-09-02: "For each one the player actually clicks it and the
 * function runs as normal." So for a `click` step this listens in the CAPTURE
 * phase, notes that the press happened, and does not interfere: the button's
 * own onPress runs exactly as it always does. The layer never calls a handler
 * and never blocks one.
 */

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from 'react'

import { fetchNui } from '../bridge/nui'
import { useUi } from '../store'
import AnnotationCard from './AnnotationCard'
import PointingHand from './PointingHand'
import WayBack from './WayBack'
import {
  BAND, centred, place, sameBox, type CardBox, type Rect,
} from './cardPlacement'
import {
  asRevisited, boxIn, canGoBack, carried, mapGoneTo, pickupState, weaponsSince,
} from './progress'
import { LOBBY_STEPS, type Step } from './steps'

/**
 * THE CARD'S SIZE IS NOT HERE, AND THAT IS THE FIX (#358).
 *
 * It was: `CARD_W = 304`, `CARD_H = 172`, described as "kept in step with
 * .tut-card". They were not, and could not be -- `.tut-card` is `19rem` against
 * a root font size that runs from 11px to 28px, so 304 was 19 x 16 and correct
 * only at 1080p with the interface slider at 1. The card is MEASURED now, from
 * the mounted element, and the clamps take that measurement as an argument. See
 * cardPlacement.ts for the arithmetic and the whole reckoning, and `cardUp`
 * below for where the measuring happens.
 */

/**
 * The four staged kill-feed rows.
 *
 * NEGATIVE IDS, so they cannot collide with a real entry -- the server's ids are
 * positive and monotonic, and a demo row sharing one would evict a real death
 * from the list.
 *
 * PLACEHOLDER NAMES, and they are mine. The owner writes every player-visible
 * string in this project and has not written these. They read as ordinary
 * handles on purpose: a demo that says PLAYER_ONE teaches the shape of the row
 * and nothing about what it looks like in a match.
 */
/**
 * A staged squad, for the card that explains the panel.
 *
 * A SOLO PLAYER HAS NO PANEL AT ALL and a squad of one has a single plate, so on
 * the warmup pad this card usually points at nothing. Owner, 2026-09-04: "then
 * show a fake populated squad panel and point that out and what each piece
 * indicates in it."
 *
 * THREE MATES AND ONE OF THEM DOWN, deliberately: the plate states are half of
 * what the card is describing, and a panel of three healthy rows cannot show
 * what "down" looks like. Colours are BR.SquadColours in order, so they match
 * the real thing exactly.
 *
 * PLACEHOLDER NAMES, mine, unapproved -- the same four handles the feed uses, so
 * a player who reads both sees one cast rather than seven strangers.
 */
const DEMO_SQUAD = {
  id: 'tutorial',
  you: 1,
  members: [
    { src: 1, name: 'You',     state: 'alive' as const, hp: 100, armour: 50, colour: '#60A5FA', kills: 2 },
    { src: 2, name: 'Vance',   state: 'alive' as const, hp: 74,  armour: 0,  colour: '#4ADE80', kills: 1 },
    { src: 3, name: 'Okonkwo', state: 'dbno' as const,  hp: 0,   armour: 0,  colour: '#FBBF24', kills: 0 },
    { src: 4, name: 'Marlowe', state: 'alive' as const, hp: 100, armour: 100, colour: '#F87171', kills: 4 },
  ],
}

/**
 * The staged chat line.
 *
 * ONE LINE, FROM THE CAST THE OTHER DEMOS USE. The feed and the squad panel
 * share four handles on purpose -- a player who reads both sees one cast rather
 * than seven strangers -- and a fresh random name here would break that for no
 * gain. The owner asked for "a random player name"; this is that, drawn from
 * the names already on screen.
 *
 * `from: -1` FOR THE REASON THE FEED USES NEGATIVE IDS: real senders are
 * positive server ids and System is 0, so a demo can never be mistaken for
 * either.
 *
 * PLACEHOLDER COPY, mine and unapproved, like every other sentence here.
 */
const DEMO_CHAT = {
  channel: 'global' as const,
  from: -1,
  name: 'Vance',
  text: 'anyone got a shield? south building',
  at: 0,
}

/** The staged notification's key, so the same card can take it back down. */
const DEMO_NOTICE_KEY = 'tutorial-demo'

/**
 * The staged kill feed.
 *
 * ═══ READ THIS LIST BOTTOM TO TOP ═══
 *
 * The feed puts the NEWEST row at the top and grows downward, so push order is
 * chronology and the last entry here is the one the player's eye lands on. That
 * also answers the owner's question of 2026-09-06 -- "the kill feed seems to
 * fill from the bottom up?" -- which is the right observation about the wrong
 * end: it fills top-down and EMPTIES bottom-up, because the oldest row is the
 * lowest and is the one that fades out first.
 *
 * ONE OF THEM IS THEIRS, AND THAT IS THE POINT OF THE CARD. All four used to be
 * `mine: false`, so the demo drew four identical grey rows under a card that
 * promises "your own kills and deaths are picked out in color". It was
 * demonstrating the opposite of what it said. The player's own kill is LAST so
 * it lands at the top, in colour, where they are already looking.
 *
 * PLACEHOLDER NAMES, and they are mine and unapproved. `You` is DEMO_SQUAD's own
 * member name so both demos share one cast rather than seven strangers.
 */
const DEMO_FEED = [
  { killer: 'Vance',   victim: 'Reyes',   weapon: 'carbinerifle', headshot: true,  mine: false, died: false },
  { killer: '',        victim: 'Okonkwo', weapon: 'storm',        headshot: false, mine: false, died: false },
  { killer: 'Marlowe', victim: 'You',     weapon: 'pumpshotgun',  headshot: false, mine: false, died: true  },
  { killer: 'You',     victim: 'Marlowe', weapon: 'sniperrifle',  headshot: true,  mine: true,  died: false },
]

/*
 * ═══ A CARD'S BODY IS NO LONGER REWRITTEN ON ITS WAY TO THE RENDERER ═══
 *
 * There was a `withKeys(body, binds)` here, and a `VK_TILDE = 0xc0` above it.
 * Both of the substitutions it performed are gone, in this order:
 *
 * `{key:…}` STOPPED BEING SUBSTITUTED FIRST. It used to become the bound letter,
 * which made the key a word in a sentence. It is drawn as the project's own
 * KeyCap now -- see AnnotationCard's `emphasize` -- so the COMMAND has to
 * survive all the way to the renderer. That is not only cosmetic: KeyCap
 * subscribes to the binding, so a cap on screen follows a rebind (#209), where a
 * substituted letter is a photograph of the binding at the moment the
 * substitution ran. The card that says "press this to open the map" is up for as
 * long as the player wants it to be. (The old substitution also could not match
 * `brslot1`..`brslot5`: its pattern took letters only, so the two commands with
 * digits in their names printed as raw tokens on the card that explains
 * switching weapons.)
 *
 * `{tilde:…}` WENT ON 2026-09-08, AND TOOK THE FUNCTION WITH IT. It appended
 * "(above TAB on your keyboard)" to the player list card, and only while
 * `brplayers` was still on tilde -- owner, 2026-09-04, because tilde is the one
 * default here a player may genuinely be unable to find: on a good many non-US
 * layouts it is moved, dead, or somewhere else entirely. So the suffix taught a
 * LOCATION rather than a name. He removed it once the card drew the real glyph,
 * which already answers "which key" better than a parenthetical does; the whole
 * of that decision is recorded at `game-players` in gameSteps.ts.
 *
 * WITH THE LAST TOKEN GONE THE FUNCTION WAS THE IDENTITY on its first argument,
 * and a reason for this layer to subscribe to `keybinds` for nothing. Keeping an
 * empty rewriting hook "in case another token turns up" would be scaffolding
 * ahead of a caller, so the body is passed straight through instead and a future
 * token can reintroduce the hook along with the need for one.
 */

/**
 * The box that actually clips an anchor, or null when nothing does.
 *
 * ═══ A RING MUST NOT OUTLINE WHAT THE PAGE IS HIDING ═══
 *
 * Owner, 2026-09-07 and again 2026-09-08: "lobby tutorial step 10 outlines the
 * entire div, even though the div itself is scrollable... the blue outline
 * clipping through the top or bottom of the screen when the div is scrolled. The
 * outline should be placed behind the top/bottom nav components just like the
 * div it outlines."
 *
 * `getBoundingClientRect` answers the element's own border box and knows nothing
 * about an ancestor's `overflow`. The Controls list is twenty-two rows inside a
 * pane capped at `100vh - 18rem`, so the ring was drawn the height of the
 * CONTENT and hung past both ends of the pane, over the header and the Save row.
 *
 * WALKS UP TO THE FIRST SCROLLING ANCESTOR and stops. Anything above that clips
 * this one too, and the intersection of two boxes that already contain each
 * other is the inner one -- so one step up is the whole answer.
 */
function clipperOf(el: HTMLElement): Rect | null {
  let p = el.parentElement
  while (p && p !== document.body) {
    const o = getComputedStyle(p)
    // ═══ ONLY THE AXIS THAT IS ACTUALLY SCROLLING ═══
    //
    // Setting `overflow-y: auto` makes the browser compute `overflow-x` as auto
    // too, so a pane that scrolls vertically reports as clipping BOTH ways -- and
    // the anchor inside it is usually full width, so clipping horizontally ate
    // the ring's own 4px inflation and with it the left and right borders. Owner,
    // 2026-09-08: "settings page outlines are better, but now lack a visible left
    // border... the settings/controls page only shows a visible right border."
    //
    // The test is therefore whether the content OVERFLOWS on that axis, not what
    // the style says. An axis that fits is not hiding anything and must not clip.
    const overY = /(auto|scroll|hidden)/.test(o.overflowY) && p.scrollHeight > p.clientHeight
    const overX = /(auto|scroll|hidden)/.test(o.overflowX) && p.scrollWidth > p.clientWidth
    if (overY || overX) {
      const b = p.getBoundingClientRect()
      // A NON-SCROLLING AXIS IS OPENED RIGHT UP rather than left out, so the
      // caller needs no second flag: an inset computed against a box wider than
      // the viewport clamps to zero and cuts nothing.
      return {
        x: overX ? b.left : -1e5,
        y: overY ? b.top : -1e5,
        w: overX ? b.width : 2e5,
        h: overY ? b.height : 2e5,
      }
    }
    p = p.parentElement
  }
  return null
}

function sameRect(a: Rect | null, b: Rect | null): boolean {
  if (a === null || b === null) return a === b
  // A HALF PIXEL IS NOT A MOVE. Sub-pixel jitter from a scale transform would
  // otherwise re-render every frame of a slider drag for no visible change.
  return (
    Math.abs(a.x - b.x) < 0.5 &&
    Math.abs(a.y - b.y) < 0.5 &&
    Math.abs(a.w - b.w) < 0.5 &&
    Math.abs(a.h - b.h) < 0.5
  )
}

/**
 * How many identical frames make a target "settled" enough to place a card at.
 *
 * FIVE, which is ~83ms at 60fps -- long enough to outlast a panel's mount
 * transition and comfortably inside the 180ms exit the outgoing card is playing,
 * so the wait is invisible.
 */
const SETTLE_FRAMES = 5

/**
 * ...and how long to wait for that before placing anyway.
 *
 * A target that never holds still would otherwise mean a card that never draws.
 * Forty frames is two thirds of a second: past every transition in this
 * interface, and short enough that a genuinely animated anchor costs a beat
 * rather than the walkthrough.
 */
const SETTLE_DEADLINE = 40

/**
 * How long a step that waits on the player may wait before offering a Next.
 *
 * FORTY-FIVE SECONDS, which is longer than any of these tasks takes and shorter
 * than somebody's patience with a walkthrough that has stopped responding. It is
 * a safety net, not a shortcut: a player doing what the card asked will have
 * advanced long before it appears.
 */
const STUCK_MS = 45000

export type TutorialLayerProps = {
  /** Which sub-screen is on top, so `screen`-scoped steps can run. */
  screen?: string
  /**
   * Is a lobby SUB-screen covering the lobby right now?
   *
   * PASSED IN RATHER THAN DERIVED HERE, because App.tsx already owns the list
   * (`LOBBY_SUBSCREENS`) and a second copy would be a second answer. It exists
   * because "the lobby is on screen" is NOT `screen === 'none'` -- the lobby's
   * own focus values are `lobby` and `squad`, and reading it as `none` hid every
   * un-scoped card the moment the walkthrough started (owner, 2026-09-04:
   * "clicking the 'Start tutorial' button just greys out the 'ready up' button
   * and nothing else happens").
   */
  subscreenUp?: boolean
  /** Every step finished. The award, when there is one, is the caller's. */
  onDone: () => void
  /** A step whose target no longer exists. Skip is gone; see AnnotationCard. */
  onAbandon: (why: 'missing') => void
  /** Which step is on screen, by id. The lobby reads it -- see the store. */
  onStep?: (id: string | null) => void
  /**
   * Which step the walkthrough is on OR ON ITS WAY TO, by id, published the
   * moment a move is asked for rather than when the next card is built (#405).
   * The lobby's locks follow it -- see `tutorialHeading` in the store.
   */
  onHeading?: (id: string | null) => void
  /**
   * Are these cards driven by the arrow keys rather than by a cursor?
   *
   * TRUE FOR THE IN-GAME HALF ONLY. It takes no NUI focus -- so there is no
   * pointer to press a button with, and the presses arrive from Lua over the
   * `tutorialnav` envelope instead.
   *
   * IT IS NOT ABSOLUTE, AND THE EXCEPTION IS PER CARD. A step scoped to one of
   * OUR screens (`screen`, e.g. the player list) draws while that screen holds
   * the cursor on its own account -- and that same focus takes game input away,
   * so the arrows are dead there. Those cards get buttons.
   */
  keyDriven?: boolean
  /**
   * The script to run. Defaults to the lobby's.
   *
   * A PROP RATHER THAN A SECOND COMPONENT, because the in-game walkthrough is
   * the same machine pointed at different anchors: it measures a rect, places a
   * card, waits for a press. Everything that differs between the two halves is
   * DATA -- which control, which sentence, what ends the step -- and a second
   * copy of the sequencer would be a second place for the step-skipping bug to
   * live.
   */
  steps?: Step[]
  /**
   * Screens this script does not visit, and the control on each that leads
   * back to it -- ringed and focused while a card waits under that screen
   * (#405). See LOBBY_WAYS_BACK in steps.ts.
   */
  waysBack?: Record<string, string>
}

export default function TutorialLayer(p: TutorialLayerProps) {
  const [i, setI] = useState(0)
  /**
   * The current index, readable from a closure that was built before it moved.
   *
   * `go` is memoised on the script rather than on the step, so anything inside it
   * that needs to know WHERE WE ARE has to read it from here. See the note at
   * `leaving`.
   */
  const iRef = useRef(0)
  iRef.current = i
  const [rect, setRect] = useState<Rect | null>(null)
  const [leaving, setLeaving] = useState(false)
  // WHICH STEP THE PRESS WAS FOR, not whether one happened.
  //
  // THIS IS THE STEP-SKIPPING BUG. It was a boolean, and a boolean cannot tell
  // "the player clicked the thing this card is about" from "the player clicked
  // something a moment ago": advancing swaps `step`, React batches the state
  // updates, and the advance effect ran again against the NEW step before the
  // reset landed -- so one release on the interface-size slider walked past the
  // text-size card, and one press on Locker walked past two (owner, 2026-09-04:
  // "when using the interface size slider like it tells me to, upon releasing my
  // mouse it skips over the text size slider hint", and "I clicked Locker and it
  // immediately took me to step 12, then jumped to 13").
  //
  // Holding the step's OWN id makes the match exact and the race unrepresentable.
  const [clickedFor, setClickedFor] = useState<string | null>(null)
  const rectRef = useRef<Rect | null>(null)
  /** The scrolling box that hides part of the anchor, or null. See `clipperOf`. */
  const [clip, setClip] = useState<Rect | null>(null)
  const clipRef = useRef<Rect | null>(null)
  /** Where this step's card was placed, and what that placement was valid for. */
  const placedRef = useRef<{ key: string; at: ReturnType<typeof place> } | null>(null)
  /**
   * The step whose target has stopped moving, or null.
   *
   * ═══ THIS IS WHAT SHUFFLED EVERY CARD ON THE SCREEN ═══
   *
   * Latching the card's position (so it would stop sliding as the kill feed grew
   * under it) was right. Latching it on the FIRST RENDER OF A NEW STEP was not:
   * `rect` is state, the measure loop is an effect, and effects run AFTER render
   * -- so on the frame a step advanced, `rect` still held THE PREVIOUS STEP'S
   * TARGET. Every card was therefore pinned where its predecessor's control had
   * been, and pinned there for good.
   *
   * It read as eight unrelated faults. Owner, 2026-09-05: "the 'make it yours
   * first' card should be next to the settings button, not the squads button"
   * -- Settings is the step after Squads -- then steps 4, 7, 9, 10, 11, 12, 13
   * and 16 in the lobby and most of the in-game half. The ones that still looked
   * right were the ones whose predecessor's target happened to sit next to their
   * own: three settings sliders in a column hide this bug completely.
   *
   * HOLDING A STEP ID RATHER THAN A BOOLEAN IS THE WHOLE FIX. A boolean is still
   * true on the first render of the next step, which is exactly the frame that
   * must not be trusted. An id cannot be stale without being visibly wrong.
   */
  const [settledFor, setSettledFor] = useState<string | null>(null)
  /**
   * The index the player stepped BACK onto, shown as a page, or null.
   *
   * ═══ GOING BACK MUST NOT ASK FOR THE WORK AGAIN, AND MUST NOT BOUNCE ═══
   *
   * Owner, 2026-09-08: "after using the arrow keys to go from 12 back to 11, I
   * have to open a new crate to move back to 12 lol." That was answered by
   * keeping each step's first baseline -- and a kept baseline is an advance
   * that is already met, so the card sent them straight forward again. Owner,
   * 2026-10-11: "For the in-game tutorial, step 15 back button doesn't work."
   *
   * So a card reached by Previous is a page instead (see `asRevisited` in
   * progress.ts): it waits for nothing and ends on Next. Set in the same
   * update as `i`, so no frame shows the card with its old advance.
   */
  const [revisit, setRevisit] = useState<number | null>(null)
  /**
   * Has this step been waiting long enough that it is probably not coming?
   *
   * ═══ NO CARD MAY BE A DEAD END ═══
   *
   * A step that ends on something the player DOES -- opening a crate, picking
   * loot up -- deliberately has no Next button: the owner's rule is that a card
   * telling somebody to do a thing must not also offer a way past the thing
   * (2026-09-05, on the crate card: "should not have a 'next' button as we're
   * waiting for their action as we've directed them").
   *
   * That rule is right and it is not a license to trap anybody. The owner sat on
   * `game-pickup` with the requirement already met by a counter that was asking
   * the wrong question, and there was no way out of the walkthrough at all. So
   * after STUCK_MS the button appears -- late enough that nobody who is getting
   * on with it will ever see one, and early enough that a miscount costs a
   * confusing card rather than the run.
   */
  const [stuck, setStuck] = useState(false)

  const steps: Step[] = p.steps ?? LOBBY_STEPS
  const scripted = steps[i]
  // ONE OBJECT PER VISIT. Every effect below keys on `step`, so the page made
  // for a revisit is memoised rather than rebuilt each render.
  const step = useMemo(
    () => (scripted !== undefined && revisit === i ? asRevisited(scripted) : scripted),
    [scripted, revisit, i],
  )

  // ── the measure loop ────────────────────────────────────────────────────
  //
  // IT MEASURES FOREVER AND SETTLES ONCE. The ring has to follow its subject
  // every frame -- a target can arrive late, reflow, or grow -- but the CARD is
  // prose somebody is reading, and prose that slides out from under the eye is
  // worse than prose a few pixels off its subject.
  useEffect(() => {
    if (!step) return
    let raf = 0
    // THE PREVIOUS STEP'S MEASUREMENT IS NOT EVIDENCE ABOUT THIS ONE. Cleared
    // here rather than left to be overwritten, so there is no frame in which
    // `rect` and `step` describe two different controls.
    rectRef.current = null
    setRect(null)
    setSettledFor(null)
    placedRef.current = null

    // A CARD WITH NOTHING TO POINT AT IS READY IMMEDIATELY. There is no rect to
    // wait for, no ring to draw and nothing that can go missing -- so it settles
    // on the spot and the measure loop never starts. See `Step.target`.
    if (step.target === undefined) {
      setSettledFor(step.id)
      return
    }

    let same = 0
    let frames = 0

    const tick = () => {
      const el = document.querySelector<HTMLElement>(`[data-tut="${step.target}"]`)
      // ═══ NO RING AROUND NOTHING (#405) ═══
      //
      // An element can be laid out and not be seen. The lobby fades out to
      // `visibility: hidden` and stays mounted under the HUD, so the decline
      // card's toggle still answered a box -- and the owner got a ring drawn
      // around empty screen mid-left in warmup. A target with no box, or one
      // that is not visible, is not on screen: it is measured as absent, which
      // either waits for its screen or ends the run loudly, as `missing` says.
      const b = el?.getBoundingClientRect()
      const next: Rect | null = el && b && b.width > 0 && b.height > 0
        && getComputedStyle(el).visibility === 'visible'
        ? { x: b.left, y: b.top, w: b.width, h: b.height }
        : null

      // The clip box is measured on the same frame as the rect, so the two can
      // never describe different scroll positions.
      const nextClip = el ? clipperOf(el) : null
      if (!sameRect(clipRef.current, nextClip)) {
        clipRef.current = nextClip
        setClip(nextClip)
      }

      if (!sameRect(rectRef.current, next)) {
        rectRef.current = next
        same = 0
        setRect(next)
      } else if (next !== null) {
        same += 1
      }

      frames += 1
      // SETTLED: the same box for SETTLE_FRAMES running, which is long enough to
      // outlast a mount transition and short enough to sit inside the outgoing
      // card's 180ms exit.
      //
      // ...OR OUT OF PATIENCE. A target that never stops moving -- a spinner, a
      // ticking clock, an element with a looping animation -- would otherwise
      // mean a card that never draws at all, which is a worse failure than one
      // placed against a moving box. The deadline is the escape.
      if (next !== null && (same >= SETTLE_FRAMES || frames >= SETTLE_DEADLINE)) {
        setSettledFor(step.id)
      }
      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [step])

  // ── the arrow keys, read from the DOM over one of our screens ───────────
  //
  // ═══ TWO SOURCES, NEVER BOTH AT ONCE ═══
  //
  // The Lua path reads GTA controls, which are dead the moment one of our
  // screens takes game input -- which is why a screen-scoped card used to render
  // buttons. But a focused screen means CEF has DOM focus, so the PAGE can hear
  // the same keypress directly; App's own Escape listener relies on exactly that
  // and says so.
  //
  // So the card is arrow-driven everywhere (owner, 2026-09-08: "should only have
  // arrows"), and the source is whichever one can actually hear it: DOM while a
  // screen is up, Lua otherwise. The two are mutually exclusive by construction,
  // so a press cannot be counted twice.
  const navRef = useRef<(dir: 'next' | 'back' | 'action') => void>(() => {})
  useEffect(() => {
    if (!step || !p.keyDriven || step.screen === undefined) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'ArrowRight') navRef.current('next')
      else if (e.key === 'ArrowLeft') navRef.current('back')
      else if (e.key === 'ArrowUp') navRef.current('action')
      else return
      e.preventDefault()
    }
    window.addEventListener('keydown', onKey)
    return () => window.removeEventListener('keydown', onKey)
  }, [step, p.keyDriven])

  // ── the arrow keys, arriving from Lua ───────────────────────────────────
  //
  // ACTED ON WHEN THE SEQUENCE MOVES, never on `dir`: two presses of Next are
  // two identical payloads and only the counter tells them apart. The first
  // render must not act at all, so the baseline is whatever the counter already
  // read when this layer mounted.
  const nav = useUi((st) => st.tutorialNav)
  const navSeen = useRef(nav.seq)

  // THE BODY, SHARED BY BOTH SOURCES. One set of rules about what an arrow may
  // do -- and in particular one place where "an arrow must not walk past a card
  // that is waiting for the player" is enforced.
  navRef.current = (dir) => {
    if (!step) return
    if (dir === 'next') {
      // ONLY WHERE A BUTTON WOULD HAVE BEEN. An arrow must not walk past a card
      // that is waiting for the player to do something -- that is the owner's
      // rule about Next buttons, and a key is a Next button with no pixels.
      if (step.advance === 'next') go(i + 1)
      else if (step.advance === 'dismiss') go(steps.length)
      else if (stuck) go(i + 1)
    } else if (dir === 'back') {
      // THE CARD'S OWN RULE, NOT A LOOSER ONE (#405). See `canGoBack`: the
      // arrows used to skip the doorway test the button applies.
      if (canGoBack(steps, i)) go(i - 1, 'back')
    } else if (dir === 'action' && step.action) {
      // `{ open: true }`, NOT `{}`. br_ui/client/players.lua reads
      // `data.open == true` and its own header states the rule -- "STATE, NOT
      // TOGGLES. The page sends what it wants to be true" -- so an empty payload
      // says CLOSE, and closing an already-closed panel early-returns and does
      // nothing at all. That was the whole of "the button doesn't work" (owner,
      // 2026-09-06): in game only the key path runs, and only it was sending
      // the wrong thing.
      void fetchNui(step.action.cb, { open: true })
    }
  }

  useEffect(() => {
    if (nav.seq === navSeen.current) return
    navSeen.current = nav.seq
    // ARROWS ARE IGNORED OVER ONE OF OUR SCREENS, because that screen has taken
    // game input and the keys cannot reach Lua -- EXCEPT once `stuck` has opened
    // the escape, which must work everywhere or it is not an escape.
    if (!step || !p.keyDriven || (step.screen !== undefined && !stuck)) return
    // THE SAME BODY THE DOM ARROWS RUN, so the two sources cannot disagree.
    navRef.current(nav.dir)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nav])

  // ── the way out of a step that is waiting on the player ─────────────────
  useEffect(() => {
    setStuck(false)
    if (!step) return
    // EVERY ADVANCE THAT WAITS ON THE PLAYER, so none of them can be a dead end.
    // The escape is the arrow only -- see the nav handler -- and nothing on the
    // card says it exists.
    const waits = step.advance === 'pickup' || step.advance === 'crate'
      || step.advance === 'map' || step.advance === 'waypoint'
      || step.advance === 'mapclose' || step.advance === 'chatsent'
      || step.advance === 'slotswitch'
    if (!waits) return
    const t = setTimeout(() => setStuck(true), STUCK_MS)
    return () => clearTimeout(t)
  }, [step])

  // ── the hand, for a card that has waited long enough ────────────────────
  //
  // See `Step.hand`. ON A CLOCK FROM THE CARD ARRIVING, and from zero every
  // time it arrives -- Previous and back again is a fresh five seconds, not a
  // hand that is already there. Drawn only with the card and its ring, and gone
  // the moment the control is pressed (`clickedFor`) or the card starts to leave.
  const [handFor, setHandFor] = useState<string | null>(null)
  useEffect(() => {
    setHandFor(null)
    if (!step || step.hand === undefined) return
    const id = step.id
    const t = setTimeout(() => setHandFor(id), step.hand)
    return () => clearTimeout(t)
  }, [step])

  // ── the real click, observed and never intercepted ──────────────────────
  useEffect(() => {
    if (!step || step.advance !== 'click') return

    const onClick = (ev: MouseEvent) => {
      const t = ev.target
      if (!(t instanceof Element)) return
      // `closest`, because the press lands on whatever is inside the button --
      // a label, an icon -- and the attribute is on the control.
      if (t.closest(`[data-tut="${step.target}"]`)) setClickedFor(step.id)
    }

    // CAPTURE, AND PASSIVE. Capture so the note is taken even if the button
    // stops propagation; passive so this can never be mistaken for a handler
    // that might preventDefault. The button's own onPress runs untouched.
    document.addEventListener('click', onClick, { capture: true, passive: true })
    return () => document.removeEventListener('click', onClick, { capture: true })
  }, [step])

  // HOISTED ABOVE `go`, which closes over it: a zustand action is a stable
  // reference, but reading it below its own consumer is a trap for the next
  // person to move code in this file.
  const pushNotice = useUi((st) => st.pushNotice)

  const go = useCallback(
    // `how` IS 'back' ONLY FOR PREVIOUS, the button or the arrow. A card the
    // walkthrough itself returns to (`mapGoneTo`) asks for its work again.
    (to: number, how?: 'back') => {
      // ═══ A CARD CLOSES WHAT IT OPENED ═══
      //
      // See `Step.onLeave`. Fired here rather than in each advance path because
      // every one of them ends up in this function -- the arrow, the button, the
      // observed action -- and a tidy-up that only some exits performed would be
      // a screen left open on the others.
      // ═══ THE STEP BEING LEFT, READ FROM A REF ═══
      //
      // `go` is a useCallback whose deps are `[steps.length]` -- a constant for a
      // given script -- so it is built ONCE, on the first render, and the `i` it
      // closes over is frozen at its initial 0. `steps[i]` therefore read
      // `steps[0]` forever, which is why `onLeave` had never fired for any step
      // in this project's history and why the player list stayed open while the
      // card advanced: the owner had to close it by hand, twice reported.
      //
      // The same freeze would have silently eaten the end-of-tutorial toast,
      // which was written the same way an hour ago.
      //
      // A REF RATHER THAN A DEPENDENCY, because putting `i` in the deps rebuilds
      // `go` every step -- and `go` is captured by half a dozen effects whose own
      // deps include it, so each of those would re-run on every advance too.
      const leaving = steps[iRef.current]
      // THE LOCKS MOVE ON THE PRESS. See `onHeading`.
      onHeadingRef.current?.(to >= 0 && to < steps.length ? steps[to]!.id : null)
      if (leaving?.onLeave) {
        void fetchNui(leaving.onLeave.cb, leaving.onLeave.data ?? {})
      }
      // ...AND ANYTHING IT WANTED TO SAY ON THE WAY OUT. See `Step.leaveNotice`.
      if (leaving?.leaveNotice) {
        pushNotice({
          text: leaving.leaveNotice.text,
          tone: leaving.leaveNotice.tone ?? 'info',
          key: `tutorial.leave.${leaving.id}`,
          ms: leaving.leaveNotice.ms ?? 10000,
        })
      }
      setLeaving(true)
      // ═══ AND THE PRESS IS FORGOTTEN, WHICH IS WHAT MAKES "LAST" WORK ═══
      //
      // Owner, 2026-09-05: "the 'last' button doesn't seem to return to the last
      // step...." It did -- for one frame. `clickedFor` holds the id of the step
      // whose control was pressed and was never cleared, so stepping BACK onto a
      // `click` step landed on a card whose advance condition was already
      // satisfied by the press that left it in the first place. The layer sent
      // them straight forward again, and the button looked dead.
      //
      // Cleared for every move, not just backwards: a step reached twice is a
      // step whose control must be pressed twice.
      setClickedFor(null)
      // Let the exit animation play before the next card is built. 180ms is
      // tutOut's duration; a longer wait is dead air and a shorter one clips.
      setTimeout(() => {
        setLeaving(false)
        if (to >= steps.length) onDoneRef.current()
        else {
          // One update with `i`, so the revisited card never draws as itself.
          setRevisit(how === 'back' ? Math.max(0, to) : null)
          setI(Math.max(0, to))
        }
      }, 180)
    },
    [steps.length],
  )

  // The callbacks are held in refs so `go` does not need them as dependencies
  // and therefore does not change identity on every render of the caller.
  const onDoneRef = useRef(p.onDone)
  const onAbandonRef = useRef(p.onAbandon)
  useEffect(() => {
    onDoneRef.current = p.onDone
    onAbandonRef.current = p.onAbandon
  })

  // WHICH STEP IS ON SCREEN, published for the lobby. Cleared on the way out so
  // a finished run cannot leave the second toggle keyed to a step that is gone.
  const onStepRef = useRef(p.onStep)
  onStepRef.current = p.onStep
  useEffect(() => {
    onStepRef.current?.(step?.id ?? null)
    return () => onStepRef.current?.(null)
  }, [step])
  // ...AND WHERE IT IS HEADING, which `go` moves first. Said again for every
  // card, so the first card and a card reached any other way are heading-true
  // too; cleared only when the layer goes. A ref, like `onDoneRef`, because `go`
  // is built once and reads it.
  const onHeadingRef = useRef(p.onHeading)
  onHeadingRef.current = p.onHeading
  useEffect(() => { onHeadingRef.current?.(step?.id ?? null) }, [step])
  useEffect(() => () => onHeadingRef.current?.(null), [])

  // ── the staged demonstration ────────────────────────────────────────────
  //
  // Four kill-feed rows, written into THIS CLIENT'S OWN STORE. Nothing is sent
  // and nothing is recorded; no other player can see them and they expire on the
  // feed's normal timer like any other row.
  //
  // SPACED, NOT DUMPED. Four rows arriving in one frame is a block of text; four
  // arriving 700ms apart is a firefight happening somewhere, which is what the
  // card is describing. It is also how they really arrive.
  const pushFeed = useUi((st) => st.pushFeed)
  useEffect(() => {
    if (!step || step.stage !== 'killfeed') return
    const timers: number[] = []
    DEMO_FEED.forEach((row, n) => {
      timers.push(window.setTimeout(() => {
        // NEGATIVE IDS, so a staged row cannot collide with a real one -- the
        // server's are positive and monotonic, and a demo sharing one would
        // evict a real death from the list.
        //
        // THE IDS ARE FIXED PER ROW rather than counted up, which is what makes
        // re-entering this step safe: `Last` from the squad card comes straight
        // back here, and a fresh id each time would stack a second copy of the
        // whole demo on top of the first.
        // ...AND THE PUSH ITSELF IS GUARDED, because `pushFeed` prepends
        // unconditionally: a second entry with the same id would sit in the list
        // as a visible duplicate until the first one's TTL removed both.
        if (!useUi.getState().feed.some((f) => f.id === -1 - n)) {
          pushFeed({ ...row, id: -1 - n })
        }
      }, 250 + n * 700))
    })
    return () => timers.forEach((t) => window.clearTimeout(t))
  }, [step, pushFeed])

  // ── the staged squad, and the staged notification ───────────────────────
  //
  // BOTH ARE PUT BACK ON THE WAY OUT. A demo that outlives its card is a lie
  // the player carries into the match -- a squad they do not have, or a notice
  // nothing sent. The cleanup runs on every path out of the step, including the
  // run being abandoned, because that is what `useEffect`'s teardown is.
  //
  // AN OVERRIDE, NOT A SWAP, AND THAT IS THE BUG THIS SHAPE FIXES. It used to
  // save the real squad, write the demo into `squad`, and put the original back
  // on the way out -- and br_core pushes a fresh squad payload on a TICK, so the
  // next push overwrote the demo a fraction of a second after it appeared.
  // Owner, 2026-09-05: "the squad panel doesn't really show", followed by the
  // run ending on `squad-name` because the anchor it wanted had already gone.
  //
  // A separate field the HUD PREFERS means the bridge goes on writing `squad`
  // as often as it likes and cannot touch this. It also deletes the
  // save-and-restore entirely: there is nothing to put back, only something to
  // stop preferring.
  const setTutorialSquad = useUi((st) => st.setTutorialSquad)

  // THE STAGED CHAT LINE, taken back down by the same teardown the squad uses --
  // and it MUST be, because `pushChat` has no removal and a demo line left in
  // the log would follow the player into their match.
  const setTutorialChat = useUi((st) => st.setTutorialChat)
  const setTutorialChatSquad = useUi((st) => st.setTutorialChatSquad)
  useEffect(() => {
    if (!step || step.stage !== 'chat') return
    setTutorialChat(DEMO_CHAT)
    // AND THE SQUAD CHANNEL IS UNLOCKED FOR THE MOMENT. In solos it is refused
    // by two page-side lines in Chat; this lifts both, and Chat's own effect
    // forces the composer back to global the instant it clears.
    setTutorialChatSquad(true)
    return () => {
      setTutorialChat(null)
      setTutorialChatSquad(false)
    }
  }, [step, setTutorialChat, setTutorialChatSquad])

  useEffect(() => {
    if (!step || step.stage !== 'squad') return
    setTutorialSquad(DEMO_SQUAD)
    return () => setTutorialSquad(null)
  }, [step, setTutorialSquad])

  useEffect(() => {
    if (!step || step.stage !== 'notice') return
    // STICKY, because the card is about what a notification looks like and one
    // that expires while they are reading about it demonstrates the opposite.
    // Owner: "It should be persistent until they click next."
    pushNotice({ text: 'Hi! Thanks for taking the tutorial', tone: 'info',
                 key: DEMO_NOTICE_KEY, sticky: true })
    return () => pushNotice({ text: '', key: DEMO_NOTICE_KEY, clear: true })
  }, [step, pushNotice])

  // ── the engine's own map opening ends the step ──────────────────────────
  //
  // Owner, 2026-09-06: "While on step 14, opening the full map like it tells me
  // to doesn't progress to step 15." It advanced on Next like any other card, so
  // it asked for one thing and accepted another -- the exact rule the owner set
  // for navigational steps.
  //
  // A RISING EDGE, and the baseline is what makes it one. A map somehow already
  // up when the card appears must not walk straight past it; that is the same
  // class as the `clickedFor` step-skipping bug above.
  //
  // TWO PRIMITIVE SELECTORS RATHER THAN ONE OBJECT, which is the store's own
  // rule: a selector returning a fresh object re-renders on every push.
  const frontendUp = useUi((st) => st.frontendUp)
  const frontendReason = useUi((st) => st.frontendReason)
  const mapWasUp = useRef(false)
  useEffect(() => {
    if (step?.advance === 'map') mapWasUp.current = frontendUp && frontendReason === 'map'
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step])
  useEffect(() => {
    if (!step || step.advance !== 'map') return
    const up = frontendUp && frontendReason === 'map'
    if (up && !mapWasUp.current) go(i + 1)
    if (!up) mapWasUp.current = false
  }, [step, frontendUp, frontendReason, i, go])

  // ── a card that dismisses itself ────────────────────────────────────────
  //
  // See `Step.autoDismissMs`. It takes the same exit a press would -- `go` past
  // the end -- so the reward is claimed by the run ENDING and not by a button,
  // and there is no second way out to keep in step with the first.
  useEffect(() => {
    if (!step || !step.autoDismissMs) return
    const t = setTimeout(() => go(steps.length), step.autoDismissMs)
    return () => clearTimeout(t)
  }, [step, steps.length, go])


  // ── a card whose screen has gone, and which has nothing left to ask ─────
  //
  // See `Step.endOnScreenGone`. It waits for the screen to have been up at least
  // once, so a card cannot advance on the frame before its own screen opens.
  const sawScreen = useRef(false)
  useEffect(() => { sawScreen.current = false }, [step])
  useEffect(() => {
    if (!step || !step.endOnScreenGone || step.screen === undefined) return
    if (p.screen === step.screen) { sawScreen.current = true; return }
    if (sawScreen.current) go(i + 1)
  }, [step, p.screen, i, go])

  // ── switching inventory slots ends the step ─────────────────────────────
  //
  // Baselined on entry like every other count: the card before this one is the
  // PICKUP card, and a pickup puts a weapon in the hand, which moves the active
  // slot -- so without a baseline this would fire the instant it appeared.
  const slotSwitches = useUi((st) => st.tutorialSlots)
  const slotsAtStart = useRef(slotSwitches)
  useEffect(() => {
    if (step?.advance === 'slotswitch') slotsAtStart.current = slotSwitches
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step])
  useEffect(() => {
    if (!step || step.advance !== 'slotswitch') return
    if (slotSwitches > slotsAtStart.current) go(i + 1)
  }, [step, slotSwitches, i, go])

  // ── sending a chat message ends the step ───────────────────────────────────────────────────────────
  //
  // NO WIRE AND NO LUA. The page is the thing that sends, so it counts its own
  // sends -- see `noteChatSent` in Chat. Baselined on entry like every other
  // count, so a player who chatted on the way here does not walk past.
  const chatSent = useUi((st) => st.chatSent)
  const chatAtStart = useRef(chatSent)
  useEffect(() => {
    if (step?.advance === 'chatsent') chatAtStart.current = chatSent
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step])
  useEffect(() => {
    if (!step || step.advance !== 'chatsent') return
    if (chatSent > chatAtStart.current) go(i + 1)
  }, [step, chatSent, i, go])

  // ── the map going AWAY ends the step ────────────────────────────────────
  //
  // The mirror of `map` above, for the card that asks them to close it again.
  // No rising-edge guard is needed and none would be right: this card is only
  // ever reached WHILE the map is open -- the two before it require it -- so the
  // first frame it draws is a frame the map is up.
  useEffect(() => {
    if (!step || step.advance !== 'mapclose') return
    if (!(frontendUp && frontendReason === 'map')) go(i + 1)
  }, [step, frontendUp, frontendReason, i, go])

  // ── a card being read over the map, and the map closed under it ─────────
  //
  // See `mapGoneTo` (#405): the storm and plane card has nothing to wait for,
  // so a closed map takes the run back to "Press M to open the full map" --
  // which asks for the map again -- rather than leaving a card hidden with no
  // way on.
  useEffect(() => {
    if (!step || (frontendUp && frontendReason === 'map')) return
    const to = mapGoneTo(steps, i)
    if (to !== null && step.advance === 'next') go(to)
  }, [step, frontendUp, frontendReason, steps, i, go])

  // ── dropping a waypoint ends the step ───────────────────────────────────
  //
  // Owner, 2026-09-07: "encourage them to try it and only proceed after they've
  // placed a waypoint at least once." Baselined on entry like the crates, so a
  // player who pinged something on the way here does not walk straight past.
  const waypoints = useUi((st) => st.tutorialWaypoints)
  const wpAtStart = useRef(waypoints)
  useEffect(() => {
    if (step?.advance === 'waypoint') wpAtStart.current = waypoints
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step])
  useEffect(() => {
    if (!step || step.advance !== 'waypoint') return
    if (waypoints > wpAtStart.current) go(i + 1)
  }, [step, waypoints, i, go])

  // ── ...and closing the map without one puts the card away ───────────────
  //
  // Owner: "if they close the map instead without placing a waypoint, close the
  // cards and give them a toast instructing them to return to the map to finish
  // the tutorial (right now the card still shows)."
  //
  // THE CARD IS NOT ABANDONED, IT IS WAITING -- the same distinction `screen`
  // steps already make. It comes back when the map does, and the toast is what
  // stops a player wondering where the walkthrough went. Keyed, so returning to
  // the map twice does not stack two of them.
  const mapClosedRef = useRef(false)
  useEffect(() => {
    if (!step || step.advance !== 'waypoint') { mapClosedRef.current = false; return }
    const mapUp = frontendUp && frontendReason === 'map'
    if (mapUp) { mapClosedRef.current = false; return }
    if (mapClosedRef.current) return
    mapClosedRef.current = true
    pushNotice({
      text: 'Open the map again and drop a waypoint to carry on.',
      tone: 'info',
      key: 'tutorial.waypoint',
      ms: 8000,
    })
  }, [step, frontendUp, frontendReason, pushNotice])


  // ── picking things up ends the step ─────────────────────────────────────
  //
  // COUNTED FROM WHERE THEY STARTED, not from zero: a player reaching this card
  // may already be carrying something they found on the way to the crates, and
  // a card that asks for two and is satisfied by what is already in their hands
  // has taught them nothing.
  //
  // ═══ WEAPONS, AND NOTHING ELSE (#405) ═══
  //
  // Owner, 2026-10-11: "the 'pick up 2 things' should actually require 2
  // weapons." This counted THINGS, and three rounds went into counting them
  // right -- ammo takes no slot, a second bandage tops up the first, a gun fills
  // its own pool as it lands (2026-09-05 to 09-08) -- and a gun plus a box of
  // rounds still ended it, which leaves the next card ("switch between them")
  // one weapon to switch to. Weapon slots are what that card needs. See
  // `weaponsSince` in progress.ts.
  //
  // PAGE-SIDE AND NO WIRE: every slot already carries its `kind` and `pool`,
  // and the payload its `ammo` map.
  const inv = useUi((st) => st.inv)
  const have = useMemo(() => carried(inv), [inv])

  const startedWith = useRef(have)
  // THE BOXES OF ROUNDS THIS CARD HAS SEEN, counted ONE UPDATE AT A TIME (#405).
  // See `boxIn`: against the baseline, a box matching the gun that just landed
  // was read as that gun's own reserve, and the card never said why it waited.
  // State, not a ref, because the card's second section is drawn from it.
  const [boxes, setBoxes] = useState(0)
  const lastHave = useRef(have)
  useEffect(() => {
    if (step?.advance === 'pickup') { startedWith.current = have; setBoxes(0) }
    // Only when the STEP changes -- re-running this on every pickup would move
    // the baseline up with them and the card would never be satisfied.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step])
  // EVERY UPDATE MOVES `lastHave`, on the pickup card or not, so the update the
  // card compares is always the one just before it.
  useEffect(() => {
    const was = lastHave.current
    lastHave.current = have
    if (step?.advance === 'pickup' && boxIn(was, have)) setBoxes((n) => n + 1)
    // Only on an inventory update; `step` is this render's.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [have])

  // ── opening a warmup crate ends the step ────────────────────────────────
  //
  // THE ONE FACT THE WALKTHROUGH IS TOLD RATHER THAN OBSERVING. See the `crate`
  // Advance variant. Baselined the same way the pickup count is, so a player who
  // opened one on the way to the card does not walk straight past it.
  const crates = useUi((st) => st.tutorialCrates)
  const cratesAtStart = useRef(crates)
  useEffect(() => {
    if (step?.advance === 'crate') cratesAtStart.current = crates
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step])
  useEffect(() => {
    if (!step || step.advance !== 'crate') return
    if (crates - cratesAtStart.current >= (step.crates ?? 1)) go(i + 1)
  }, [step, crates, i, go])

  // READ IN THE EFFECT, after the baseline effect above has run for this step,
  // so the first commit of the card cannot be judged against the last one's.
  useEffect(() => {
    if (!step || step.advance !== 'pickup') return
    if (pickupState(step, { weapons: weaponsSince(startedWith.current, have), ammo: boxes }).done) go(i + 1)
  }, [step, have, boxes, i, go])

  // ...AND WHY A BOX OF ROUNDS DID NOT COUNT. Owner: "If they pickup 1 weapon
  // and 1 item that doesn't take a slot like ammo, then direct them
  // accordingly." The step's `ammoNote` replaces its section while that is so.
  // Read at render; the card is not drawn until its target has settled, which is
  // after the baseline above has been taken.
  const ammoShort = step !== undefined && step.advance === 'pickup'
    && step.ammoNote !== undefined
    && pickupState(step, { weapons: weaponsSince(startedWith.current, have), ammo: boxes }).short

  // ── a screen opening ends the step ──────────────────────────────────────
  //
  // The page cannot read a game key, but it can see the screen the key opened --
  // the same fact one step later, needing no new wire. The card's own button and
  // the player's keyboard therefore advance it identically.
  useEffect(() => {
    if (!step || step.advance !== 'screen') return
    if (step.awaitScreen !== undefined && p.screen === step.awaitScreen) go(i + 1)
  }, [step, p.screen, i, go])

  // A CLICK STEP ADVANCES ITSELF once the player has pressed the real control --
  // and only for the step the press was actually for.
  useEffect(() => {
    if (step && step.advance === 'click' && clickedFor === step.id) go(i + 1)
  }, [clickedFor, step, i, go])

  // ── a target that is not there ──────────────────────────────────────────
  //
  // FAIL LOUDLY AND STOP, rather than draw a card pointing at the corner of the
  // screen. A missing `data-tut` means a control was renamed or removed and
  // this script did not follow; the honest response is to end the walkthrough
  // and say so, because a tutorial that confidently points at nothing is worse
  // than one that admits it is broken. The caller decides whether that burns
  // the one-time offer.
  //
  // ...AND A STEP WAITING FOR ITS SCREEN IS NOT MISSING. This is what ended the
  // owner's run at "6 of 9" (2026-09-04): the settings-scoped steps kept
  // measuring while Settings was not the screen on top, found nothing -- because
  // nothing was rendered -- and the 1.2s timer killed the whole walkthrough.
  // A step whose screen is not up has not failed; it has not started.
  //
  // ═══ AND A LOBBY STEP WAITS FOR THE LOBBY TO BE BARE ═══
  //
  // A step with NO `screen` is about the lobby's own front page, so it must not
  // draw over a sub-screen the player has opened. That is what makes the Market
  // behave the way the owner asked: "if they click on the market button please
  // hide the tutorial until they come back to the main lobby screen. We don't
  // have much to show them in the market yet, so we'll leave them to their own
  // devices there." (2026-09-04)
  //
  // It is a general rule rather than a special case for the Market, because it
  // is true of every un-scoped step: a card explaining Ready up has nothing to
  // say while the Locker is covering it. (The Market has a card of its own now,
  // #405 -- scoped to it with `screen`, which is the other half of this rule.)
  //
  // `none` IS THE BARE LOBBY -- store/index.ts's initial `focus`.
  const waitingForScreen = step !== undefined
    && (step.screen !== undefined
      ? step.screen !== p.screen
      : p.subscreenUp === true)

  // A CARD ABOUT THE MAP DRAWS ONLY OVER THE MAP. Without this the waypoint
  // card followed the player back out to the HUD and sat there over a control
  // it says nothing about (owner, 2026-09-07: "right now the card still
  // shows"). Waiting, not failing: it returns when the map does. Every card
  // about the open map says so with `overMap` (#405).
  const waitingForMap = step !== undefined
    && step.overMap === true
    && !(frontendUp && frontendReason === 'map')
  const missing = step !== undefined && step.target !== undefined
    && rect === null && !waitingForScreen
  useEffect(() => {
    if (!missing) return
    const t = setTimeout(() => {
      if (rectRef.current === null) {
        // NAMED, LOUDLY. Silence here cost a debugging round on 2026-09-04: the
        // first step pointed at a `data-tut` nobody had added, so the run ended
        // 1.2 seconds in and the owner saw the command succeed and NOTHING
        // DRAW. "Nothing happened" is the one report this failure can produce,
        // so it has to say which target it could not find.
        console.warn(
          `[tutorial] step "${step.id}" wants [data-tut="${step.target}"] and ` +
            'nothing on screen has it -- ending the run. Either the control was ' +
            'renamed, or the anchor was never added.',
        )
        onAbandonRef.current('missing')
      }
    }, 1200)
    return () => clearTimeout(t)
  }, [missing, step, waitingForScreen])

  // NOT UNTIL THE BOX BELONGS TO THIS STEP AND HAS STOPPED MOVING. See
  // `settledFor` -- this one comparison is what keeps a card from being pinned
  // to the control the PREVIOUS card was about.
  //
  // A TARGETLESS CARD SKIPS THE RECT TEST, because it has none by design.
  //
  // ONE BOOLEAN RATHER THAN TWO EARLY RETURNS, because the measurement below has
  // to know whether the card is mounted and a hook cannot live after a `return`.
  // A second copy of the condition could drift from this one, and the two
  // disagreeing would mean measuring a card that is not there or never measuring
  // one that is.
  const cardUp = step !== undefined
    && !waitingForScreen && !waitingForMap
    && settledFor === step.id
    && (step.target === undefined || rect !== null)

  // ── the card's own size, measured ───────────────────────────────────────
  //
  // ═══ MEASURED, NEVER PREDICTED (#358) ═══
  //
  // Real players reported tutorial steps drawing off the screen at 4K. The card
  // is `19rem` wide against a root font size that clamps between 11px and 28px,
  // and the clamps below used to read a hard-coded 304 -- which is 19 x 16, and
  // so was the truth at 1080p and a 228px under-measure at 2160p. The full
  // reckoning is in cardPlacement.ts; this is the half that has to touch a real
  // layout.
  //
  // BEFORE PAINT, WHICH IS WHY THIS IS useLayoutEffect. The card must exist to
  // be measured, so the first commit of a new step places it from no measurement
  // at all -- as a point against its subject (see `metrics`). A layout effect
  // runs after that commit and before the browser paints, and the state it sets
  // is flushed in the same frame, so the corrected placement is what is drawn.
  // An ordinary useEffect here would trade an off-screen card for a card that
  // visibly jumps, which is a new bug rather than a fix.
  //
  // offsetWidth / offsetHeight, NOT getBoundingClientRect. The card arrives on a
  // `scale(0.86)` keyframe (index.css, tutIn) and a client rect includes
  // transforms, so measuring the animating box would report 86% of the card and
  // re-introduce exactly the under-measure this fixes, with a different cause.
  // The offset* pair is the layout box and ignores transforms, and it is stable
  // across the whole arrival: nothing in the landing animation touches layout.
  const cardRef = useRef<HTMLDivElement | null>(null)
  // THE MEASUREMENT IS KEPT BETWEEN STEPS, DELIBERATELY. Clearing it per step
  // would make every card's first commit an unmeasured one; the previous card's
  // box is the same width and close on height, so it is the best possible seed
  // for the commit that is about to be corrected anyway. Only the very first card
  // of a session has no measurement to start from.
  const [card, setCard] = useState<CardBox | null>(null)
  // Bumped by a viewport change, purely to force the measurement to run again.
  // It also gives an UNANCHORED card a re-render on resize, which it never had:
  // the latch keys on the viewport, and a card with no target has no measure
  // loop to re-render it, so one placed before a resolution change kept a
  // placement computed against the old screen.
  const [viewportTick, setViewportTick] = useState(0)
  const uiScale = useUi((st) => st.settings.uiScale)
  const textScale = useUi((st) => st.settings.textScale)
  const stepId = step?.id
  // THE CARD'S SECOND SECTION, which can change while the card is up: the
  // pickup card's direction arrives with the box of rounds (#405). It changes
  // the card's height, so it is an input to the measurement below.
  const note = step === undefined ? undefined : ammoShort ? step.ammoNote : step.note

  useEffect(() => {
    const bump = () => setViewportTick((n) => n + 1)
    window.addEventListener('resize', bump)
    return () => window.removeEventListener('resize', bump)
  }, [])

  // R22 INVALIDATION SET -- keep in sync with cardPlacement.ts CARD_INPUTS and
  // check-ui rule R22.
  useLayoutEffect(() => {
    const el = cardRef.current
    if (el === null) return
    // THE ROOT FONT SIZE IS READ, NOT COMPUTED, and it is read here because the
    // gaps are rem multiples too -- see GAP_REM. Nothing in this project knows
    // that a rem is 1.481vh, that it is clamped at both ends, or that the
    // interface slider multiplies it; the same call screens/PlayerList.tsx makes
    // for the same reason.
    const rem = parseFloat(getComputedStyle(document.documentElement).fontSize) || 16
    const next = { w: el.offsetWidth, h: el.offsetHeight, rem }
    setCard((prev) => (sameBox(prev, next) ? prev : next))
  }, [cardUp, stepId, note, uiScale, textScale, viewportTick])

  // ── a screen the walkthrough does not visit, and the way back from it ───
  //
  // See `waysBack` and WayBack.tsx. Only while the card is waiting because of
  // that screen, so it can never sit beside a card of its own.
  const wayBack = step !== undefined && waitingForScreen && p.screen !== undefined
    ? p.waysBack?.[p.screen]
    : undefined
  if (wayBack !== undefined) return <WayBack key={wayBack} target={wayBack} />

  if (!cardUp || !step) return null

  // ── where the card goes, decided ONCE per step ──────────────────────────
  //
  // THE RING TRACKS, THE CARD DOES NOT. Owner, 2026-09-05: "the kill feed card
  // moves around vertically when the kill feed div expands with the new
  // content. The card's position should be fixed."
  //
  // The measure loop runs every frame because a target can arrive late, move
  // under a layout change, or grow -- and the ring must follow it or it stops
  // outlining the thing it is about. The CARD is prose the player is reading,
  // and prose that slides out from under the eye as a list fills is worse than
  // prose slightly off its subject. So the placement is computed on the first
  // frame the target is measurable and then held.
  //
  // KEYED ON THE STEP, THE VIEWPORT AND THE CARD'S MEASURED BOX. A resize
  // genuinely invalidates it -- the whole point of `place` is that a card cannot
  // be pushed off screen -- and so does the measurement arriving, which is the
  // frame that corrects the placement the card was mounted at. The latch is
  // dropped when one of the three changes, and only then.
  const vw = window.innerWidth
  const vh = window.innerHeight
  const box = card === null ? 'unmeasured' : `${card.w}x${card.h}@${card.rem}`
  const latchKey = `${step.id}|${vw}x${vh}|${box}`
  if (placedRef.current?.key !== latchKey) {
    placedRef.current = {
      key: latchKey,
      // Both branches take the measured box and neither knows its size. See
      // cardPlacement.ts -- `centred` carries the owner's lower-third rule and
      // `place` the side-preference and the clamps.
      at: rect === null
        ? centred(card, vw, vh, BAND[step.place ?? 'half'])
        : place(rect, card, vw, vh),
    }
  }
  const { left, top, fromX, fromY } = placedRef.current.at

  return (
    <>
      {/* NO RING WITHOUT A SUBJECT. A targetless card is about something that
          is not on this screen; a rectangle drawn anyway would be the walkthrough
          pointing at nothing, which is the fault it is meant to prevent. */}
      {rect !== null && (
        <div
          className={`tut-ring${step.advance === 'click' ? ' tut-ring--click' : ''}`}
          style={{
            left: rect.x - 4,
            top: rect.y - 4,
            width: rect.w + 8,
            height: rect.h + 8,
            // ═══ CUT, DO NOT SHRINK ═══
            //
            // The ring keeps the anchor's true size -- shrinking it to the
            // visible slice would draw a border ACROSS the middle of a list that
            // continues, which reads as the list ending there. `clip-path`
            // removes the parts the pane is already hiding and leaves the rest
            // byte-for-byte as it was, so a fully visible anchor is unchanged
            // and a scrolled one simply runs off under the header the way its
            // own content does.
            //
            // INSETS ARE RELATIVE TO THIS ELEMENT'S OWN BOX, hence the offsets
            // against the inflated rect rather than against the anchor.
            // ═══ MEASURED AGAINST THE ANCHOR, NOT AGAINST THE RING ═══
            //
            // The insets used to be computed from the ring's own inflated box,
            // so an anchor sitting flush against the top of its pane -- which is
            // exactly what "scrolled to the top" means -- had its top border
            // clipped away: the border is OUTSIDE the anchor, so the pane's edge
            // fell 4px inside the ring. Owner, 2026-09-08: "when scrolling to the
            // top, I expect to see a top border where there is none visible
            // today. Same for scrolling down."
            //
            // Measured from the ANCHOR's edge instead, a flush edge cuts nothing
            // and keeps its border, and only content genuinely past the pane is
            // removed. The cost is that the border bleeds 4px over the header at
            // that one position, which is the trade the owner asked for: he wants
            // to see where the list begins and ends.
            clipPath: clip === null ? undefined : `inset(${
              Math.max(0, clip.y - rect.y)}px ${
              Math.max(0, (rect.x + rect.w) - (clip.x + clip.w))}px ${
              Math.max(0, (rect.y + rect.h) - (clip.y + clip.h))}px ${
              Math.max(0, clip.x - rect.x)}px)`,
          }}
        />
      )}
      {/* THE HAND (#405), on the control the card is waiting for. The fingertip
          lands just inside its lower half, toward the middle. */}
      {rect !== null && handFor === step.id && !leaving && clickedFor !== step.id && (
        <PointingHand x={rect.x + rect.w * 0.55} y={rect.y + rect.h * 0.62} />
      )}
      <AnnotationCard
        key={step.id}
        // THE HANDLE THE MEASUREMENT READS. See `cardUp` above: the size of this
        // element is the one thing the placement cannot be told in advance.
        ref={cardRef}
        title={step.title}
        // VERBATIM. The script's prose goes to the card exactly as written --
        // `{key:…}`, `[[Esc]]` and `~Volts~` are the renderer's to resolve, not
        // this layer's. See the note where `withKeys` used to be.
        body={step.body}
        // The pickup card's direction takes the section's place while it holds.
        note={note}
        index={i + 1}
        total={steps.length}
        left={left}
        top={top}
        fromX={fromX}
        fromY={fromY}
        leaving={leaving}
        // KEYS ON THE BARE HUD, BUTTONS OVER A SCREEN. A card scoped to one of
        // our own screens draws while that screen holds the cursor -- and that
        // focus has taken game input, so the arrows cannot reach Lua at all.
        // KEYS EVERYWHERE THE WALKTHROUGH IS KEY-DRIVEN, INCLUDING OVER OUR OWN
        // SCREENS. The gate used to exclude a screen-scoped card, which was the
        // one card in the script that then rendered a clickable button -- and it
        // contradicted the rest of this file, where the DOM listener is
        // registered for exactly those cards. Arrows were live; the card just
        // did not say so, and offered a button instead (owner, twice).
        keys={p.keyDriven === true}
        // NEVER ON A STEP THAT IS WAITING FOR THE PLAYER. Owner, 2026-09-07,
        // twice: "should not have a 'next' button but instead use arrow keys or
        // do it for them", "remove the next button from the card on this step
        // too". A card that tells somebody to do a thing must not also offer a
        // way past the thing.
        //
        // THE ANTI-TRAP ESCAPE SURVIVES AND IS INVISIBLE. `stuck` still opens
        // the RIGHT ARROW after STUCK_MS on those steps -- see the nav handler
        // -- so a miscount costs a confusing card rather than a run that cannot
        // end, and nothing on screen invites anybody to skip.
        onNext={step.advance === 'next' ? () => go(i + 1) : null}
        // ═══ NO WAY BACK ACROSS A DOORWAY ═══
        //
        // Owner, 2026-09-04: "if they just came from a different menu, like
        // going from Settings/Controls to Locker, we shouldn't have a Last
        // button either." Last would have to reopen the screen the player has
        // just left and put them where they were in it, and it does not do
        // that -- so it would take them back to a card describing a control
        // that is no longer on screen. One rule with the arrows: `canGoBack`.
        onBack={canGoBack(steps, i) ? () => go(i - 1, 'back') : null}
        // The last card ends the run rather than advancing into nothing.
        onDismiss={step.advance === 'dismiss' ? () => go(steps.length) : null}
        dismissLabel={step.dismissLabel}
        action={
          step.action
            ? { label: step.action.label,
                onPress: () => { void fetchNui(step.action!.cb, { open: true }) } }
            : null
        }
      />
    </>
  )
}
