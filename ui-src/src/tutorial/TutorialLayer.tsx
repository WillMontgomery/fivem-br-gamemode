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

import { useCallback, useEffect, useRef, useState } from 'react'

import AnnotationCard from './AnnotationCard'
import { LOBBY_STEPS, type Step } from './steps'

/** Card size, kept in step with .tut-card so edge-avoidance can do arithmetic. */
const CARD_W = 304
const CARD_H = 172
/** How far the card sits off its subject. */
const GAP = 18
/** Never closer than this to the viewport edge. */
const MARGIN = 16

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
  /** Every step finished. The award, when there is one, is the caller's. */
  onDone: () => void
  /** Skip, or a step whose target no longer exists. */
  onAbandon: (why: 'skipped' | 'missing') => void
}

export default function TutorialLayer(p: TutorialLayerProps) {
  const [i, setI] = useState(0)
  const [rect, setRect] = useState<Rect | null>(null)
  const [leaving, setLeaving] = useState(false)
  const [clicked, setClicked] = useState(false)
  const rectRef = useRef<Rect | null>(null)

  const steps: Step[] = LOBBY_STEPS
  const step = steps[i]

  // ── the measure loop ────────────────────────────────────────────────────
  useEffect(() => {
    if (!step) return
    let raf = 0

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
        setRect(next)
      }
      raf = requestAnimationFrame(tick)
    }

    raf = requestAnimationFrame(tick)
    return () => cancelAnimationFrame(raf)
  }, [step])

  // ── the real click, observed and never intercepted ──────────────────────
  useEffect(() => {
    if (!step || step.advance !== 'click') return
    setClicked(false)

    const onClick = (ev: MouseEvent) => {
      const t = ev.target
      if (!(t instanceof Element)) return
      // `closest`, because the press lands on whatever is inside the button --
      // a label, an icon -- and the attribute is on the control.
      if (t.closest(`[data-tut="${step.target}"]`)) setClicked(true)
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

  // A CLICK STEP ADVANCES ITSELF once the player has pressed the real control.
  useEffect(() => {
    if (step && step.advance === 'click' && clicked) go(i + 1)
  }, [clicked, step, i, go])

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
  const waitingForScreen = step !== undefined
    && step.screen !== undefined
    && step.screen !== p.screen
  const missing = step !== undefined && rect === null && !waitingForScreen
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

  if (!step || rect === null) return null
  // A step scoped to a child screen waits until that screen is actually on top.
  if (step.screen !== undefined && step.screen !== p.screen) return null

  const vw = window.innerWidth
  const vh = window.innerHeight
  const { left, top, fromX, fromY } = place(rect, vw, vh)

  return (
    <>
      <div
        className={`tut-ring${step.advance === 'click' ? ' tut-ring--click' : ''}`}
        style={{
          left: rect.x - 4,
          top: rect.y - 4,
          width: rect.w + 8,
          height: rect.h + 8,
        }}
      />
      <AnnotationCard
        key={step.id}
        title={step.title}
        body={step.body}
        index={i + 1}
        total={steps.length}
        left={left}
        top={top}
        fromX={fromX}
        fromY={fromY}
        leaving={leaving}
        onNext={step.advance === 'next' ? () => go(i + 1) : null}
        onBack={i > 0 ? () => go(i - 1) : null}
        onSkip={() => onAbandonRef.current('skipped')}
      />
    </>
  )
}
