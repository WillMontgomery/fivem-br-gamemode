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

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

import { fetchNui } from '../bridge/nui'
import { useUi } from '../store'
import AnnotationCard from './AnnotationCard'
import { LOBBY_STEPS, type Step } from './steps'

/** Card size, kept in step with .tut-card so edge-avoidance can do arithmetic. */
const CARD_W = 304
const CARD_H = 172
/** How far the card sits off its subject. */
const GAP = 18
/** Never closer than this to the viewport edge. */
const MARGIN = 16

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

/** Windows VK for the backtick/tilde key. */
const VK_TILDE = 0xc0

/**
 * Put the player's ACTUAL keys into a card's prose.
 *
 * ═══ THE BINDING, NEVER THE DEFAULT ═══
 *
 * `{key:brplayers}` becomes whatever that command is bound to on THIS machine.
 * A walkthrough that prints the default tells a player who rebound it to press
 * a key that does nothing, and this one is the walkthrough they are taking
 * BECAUSE they do not know the game yet.
 *
 * `{tilde:brplayers}` adds "(above TAB on your keyboard)" and ONLY when that
 * command is still on tilde -- owner, 2026-09-04. Tilde is the one default here
 * a player may genuinely be unable to find: on a good many non-US layouts it is
 * moved, dead, or somewhere else entirely. So the suffix is a LOCATION rather
 * than a name, and it disappears the moment the key is not that key.
 *
 * UNBOUND READS AS "unbound" rather than as an empty gap, because a sentence
 * that says "press  to open" is a sentence that looks broken. The card's own
 * action button is what actually gets that player through.
 */
function withKeys(body: string, binds: Array<{ command: string; key?: string; vk?: number }>): string {
  return body
    // ═══ IT NO LONGER TOUCHES {key:...} AND THAT IS THE POINT ═══
    //
    // This used to replace the token with the bound letter, which made the key a
    // word in a sentence. It is drawn as the project's own KeyCap now -- see
    // AnnotationCard's `emphasise` -- so the COMMAND has to survive all the way
    // to the renderer.
    //
    // THAT IS NOT ONLY COSMETIC. KeyCap subscribes to the binding, so a cap on
    // screen follows a rebind (#209); a substituted letter is a photograph of
    // the binding at the moment the substitution ran. The card that says "press
    // this to open the map" is up for as long as the player wants it to be.
    //
    // (The old substitution also could not match `brslot1`..`brslot5`: its
    // pattern took letters only, so the two commands with digits in their names
    // printed as raw tokens on the card that explains switching weapons.)
    .replace(/\{tilde:([a-z0-9]+)\}/gu, (_m, cmd: string) =>
      binds.find((b) => b.command === cmd)?.vk === VK_TILDE
        ? ' (above TAB on your keyboard)'
        : '')
}

type Rect = { x: number; y: number; w: number; h: number }

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
 * Where the card goes, and which way it faces.
 *
 * PREFERRED SIDE FIRST, THEN WHATEVER FITS. Right of the subject reads best for
 * the lobby's left-hand column; a target near the right edge flips to the left,
 * and one that fits neither goes below. The returned vector points FROM the
 * card TOWARD the subject, which is what the arrival animation and the beak
 * both consume.
 */
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

function place(r: Rect, vw: number, vh: number) {
  let left = r.x + r.w + GAP
  let fromX = -1
  let fromY = 0

  if (left + CARD_W > vw - MARGIN) {
    left = r.x - CARD_W - GAP
    fromX = 1
  }
  // Neither side fits -- a wide target on a narrow viewport. Go underneath and
  // point up, which is the only remaining direction that cannot cover it.
  if (left < MARGIN) {
    left = Math.min(Math.max(r.x + r.w / 2 - CARD_W / 2, MARGIN), vw - CARD_W - MARGIN)
    fromX = 0
    fromY = -1
  }

  const wantTop = fromY === -1 ? r.y + r.h + GAP : r.y + r.h / 2 - CARD_H / 2
  const top = Math.min(Math.max(wantTop, MARGIN), Math.max(vh - CARD_H - MARGIN, MARGIN))

  return { left, top, fromX, fromY }
}

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
}

export default function TutorialLayer(p: TutorialLayerProps) {
  const [i, setI] = useState(0)
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
   * That rule is right and it is not a licence to trap anybody. The owner sat on
   * `game-pickup` with the requirement already met by a counter that was asking
   * the wrong question, and there was no way out of the walkthrough at all. So
   * after STUCK_MS the button appears -- late enough that nobody who is getting
   * on with it will ever see one, and early enough that a miscount costs a
   * confusing card rather than the run.
   */
  const [stuck, setStuck] = useState(false)

  const steps: Step[] = p.steps ?? LOBBY_STEPS
  const step = steps[i]

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
      const next: Rect | null = el
        ? (() => {
            const b = el.getBoundingClientRect()
            return { x: b.left, y: b.top, w: b.width, h: b.height }
          })()
        : null

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

  // ── the arrow keys, arriving from Lua ───────────────────────────────────
  //
  // ACTED ON WHEN THE SEQUENCE MOVES, never on `dir`: two presses of Next are
  // two identical payloads and only the counter tells them apart. The first
  // render must not act at all, so the baseline is whatever the counter already
  // read when this layer mounted.
  const nav = useUi((st) => st.tutorialNav)
  const navSeen = useRef(nav.seq)
  useEffect(() => {
    if (nav.seq === navSeen.current) return
    navSeen.current = nav.seq
    if (!step || !p.keyDriven || step.screen !== undefined) return

    if (nav.dir === 'next') {
      // ONLY WHERE A BUTTON WOULD HAVE BEEN. An arrow must not walk past a card
      // that is waiting for the player to do something -- that is the owner's
      // rule about Next buttons, and a key is a Next button with no pixels.
      if (step.advance === 'next') go(i + 1)
      else if (step.advance === 'dismiss') go(steps.length)
      else if (stuck) go(i + 1)
    } else if (nav.dir === 'back') {
      if (i > 0 && !step.noBack && steps[i - 1] !== undefined) go(i - 1)
    } else if (nav.dir === 'action' && step.action) {
      // `{ open: true }`, NOT `{}`. br_ui/client/players.lua reads
      // `data.open == true` and its own header states the rule -- "STATE, NOT
      // TOGGLES. The page sends what it wants to be true" -- so an empty payload
      // says CLOSE, and closing an already-closed panel early-returns and does
      // nothing at all. That was the whole of "the button doesn't work" (owner,
      // 2026-09-06): in game only this key path runs, and only this path was
      // sending the wrong thing. The click path below has always sent it.
      void fetchNui(step.action.cb, { open: true })
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [nav])

  // ── the way out of a step that is waiting on the player ─────────────────
  useEffect(() => {
    setStuck(false)
    if (!step || (step.advance !== 'pickup' && step.advance !== 'crate'
                  && step.advance !== 'map')) return
    const t = setTimeout(() => setStuck(true), STUCK_MS)
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

  const go = useCallback(
    (to: number) => {
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
        else setI(Math.max(0, to))
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
  const keybinds = useUi((st) => st.keybinds)
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
  const pushNotice = useUi((st) => st.pushNotice)

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

  // ── picking things up ends the step ─────────────────────────────────────
  //
  // COUNTED FROM WHERE THEY STARTED, not from zero: a player reaching this card
  // may already be carrying something they found on the way to the crates, and
  // a card that asks for two and is satisfied by what is already in their hands
  // has taught them nothing.
  // COUNTING FILLED SLOTS WAS THE WRONG QUESTION, and it trapped the owner on
  // this very card (2026-09-05: "I took 2 things from the crate and the next
  // step never appeared after that"). Two of the three things a warmup crate
  // drops cannot raise the slot count at all:
  //
  //   * AMMO OCCUPIES NO SLOT. br_core/server/inventory.lua's `give` opens with
  //     "Ammo never occupies a slot" and returns before the slot code runs.
  //   * A SECOND CONSUMABLE TOPS UP THE FIRST. The same function fills existing
  //     stacks before opening a new one, so two bandages are one slot.
  //
  // A crate rolls three items at 55/18/21/6 weapon/ammo/consumable/throwable, so
  // "take two things" routinely moves the slot count by one, or by none.
  //
  // THE FIX IS PAGE-SIDE AND NEEDS NO WIRE. The payload already carries
  // `slots[i].count` and an `ammo` map, so this side can ask the right question
  // from what it already receives -- rather than adding a counter to the
  // protocol that only a walkthrough would ever read.
  const inv = useUi((st) => st.inv)

  /**
   * Everything they are carrying, by id, so two of a thing is two.
   *
   * AMMO IS COUNTED AS ONE PICKUP PER POOL, NOT PER ROUND. One ammo box adds
   * thirty to a pool, and a card that says "take two things" must not be
   * satisfied by a single box. So a pool that rose is worth exactly 1, and
   * everything else is worth however much of it arrived.
   */
  const tally = useMemo(() => {
    const m = new Map<string, number>()
    for (const s of inv.slots) {
      if (!s) continue
      m.set(s.id, (m.get(s.id) ?? 0) + (s.count ?? 1))
    }
    for (const [pool, n] of Object.entries(inv.ammo ?? {})) {
      m.set('@' + pool, n)
    }
    return m
  }, [inv])

  const startedWith = useRef(tally)
  useEffect(() => {
    if (step?.advance === 'pickup') startedWith.current = tally
    // Only when the STEP changes -- re-running this on every pickup would move
    // the baseline up with them and the card would never be satisfied.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [step])

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

  useEffect(() => {
    if (!step || step.advance !== 'pickup') return
    const before = startedWith.current
    let got = 0
    for (const [k, n] of tally) {
      const was = before.get(k) ?? 0
      if (n <= was) continue
      // A POOL THAT ROSE IS ONE PICKUP. See `tally`.
      got += k.startsWith('@') ? 1 : n - was
    }
    if (got >= (step.pickups ?? 1)) go(i + 1)
  }, [step, tally, i, go])

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
  // say while the Locker is covering it.
  //
  // `none` IS THE BARE LOBBY -- store/index.ts's initial `focus`.
  const waitingForScreen = step !== undefined
    && (step.screen !== undefined
      ? step.screen !== p.screen
      : p.subscreenUp === true)
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
  if (!step || waitingForScreen || settledFor !== step.id) return null
  if (step.target !== undefined && rect === null) return null

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
  // KEYED ON THE STEP AND THE VIEWPORT. A resize genuinely invalidates it --
  // the whole point of `place` is that a card cannot be pushed off screen --
  // so the latch is dropped when either changes, and only then.
  const vw = window.innerWidth
  const vh = window.innerHeight
  const latchKey = `${step.id}|${vw}x${vh}`
  if (placedRef.current?.key !== latchKey) {
    placedRef.current = {
      key: latchKey,
      // LOW AND CENTRED, ARRIVING FROM NOWHERE IN PARTICULAR.
      //
      // Owner, 2026-09-07: "step 11 and any other step that currently draws in
      // the middle center of the screen should be moved to the lower 1/3 in the
      // middle." Dead centre is where a card about the WORLD does the most
      // damage -- it sits exactly over the four crates it is telling the player
      // to go and look at. Low and centred is where a game puts a subtitle, and
      // it leaves the middle of the screen to the thing being described.
      //
      // CLAMPED, so a tall card on a short viewport cannot be pushed off the
      // bottom -- the same floor `place` applies to an anchored one.
      //
      // The arrival vector is zero: a card with no subject has no direction to
      // be thrown from, so it simply scales up in place.
      at: rect === null
        ? {
            left: (vw - CARD_W) / 2,
            top: Math.min(vh * 0.72 - CARD_H / 2,
                          Math.max(vh - CARD_H - MARGIN, MARGIN)),
            fromX: 0,
            fromY: 0,
          }
        : place(rect, vw, vh),
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
          }}
        />
      )}
      <AnnotationCard
        key={step.id}
        title={step.title}
        body={withKeys(step.body, keybinds)}
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
        keys={p.keyDriven === true && step.screen === undefined}
        // ...OR AFTER A LONG WAIT ON A STEP THAT HAS NO OTHER WAY OUT. See
        // `stuck`. Never on a `click` or `screen` step: those name a control
        // that is on screen and working, so a second route past them is the
        // "asking for one thing and accepting another" the owner ruled out.
        onNext={
          step.advance === 'next'
          || (stuck && (step.advance === 'pickup' || step.advance === 'crate'
                        || step.advance === 'map'))
            ? () => go(i + 1)
            : null
        }
        // ═══ NO WAY BACK ACROSS A DOORWAY ═══
        //
        // Owner, 2026-09-04: "if they just came from a different menu, like
        // going from Settings/Controls to Locker, we shouldn't have a Last
        // button either." Last would have to reopen the screen the player has
        // just left and put them where they were in it, and it does not do
        // that -- so it would take them back to a card describing a control
        // that is no longer on screen.
        onBack={
          i > 0 && !step.noBack && steps[i - 1] !== undefined
            && steps[i - 1]!.screen === step.screen
            ? () => go(i - 1)
            : null
        }
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
