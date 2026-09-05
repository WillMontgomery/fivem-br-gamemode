/**
 * One annotation card (#261).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * IT IS THE ONE THING IN THE INTERFACE THAT IS ALLOWED TO SOUND DIFFERENT
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Owner, 2026-09-02: the flyouts "should feel more casual than our existing
 * fonts -- the flyouts are a deliberate exception to the rest of the UX and
 * should read as one". So this file is the only consumer of `--font-tutorial`
 * (Nunito), and the exception is declared in index.css beside the rule it
 * breaks rather than hidden in a component.
 *
 * HIS TWO WEIGHTS, THROUGH TOKENS: `--font-tutorial-head` (700) on the title
 * and `--font-tutorial-body` (350) on the prose. 350 reads as a typo at a use
 * site, which is exactly why it is named.
 *
 * ═══ EVERYTHING MOVES, AND IT MOVES ON THE COMPOSITOR ═══
 *
 * Owner, 2026-09-04: "let's make sure we've got some animations on these
 * annotations... get creative. We don't want this looking boring or we'll lose
 * their attention."
 *
 * Every animation here is `transform` and `opacity` ONLY. Not a house style
 * preference: this page shares a frame with the game, the lobby camera is
 * flying while these are on screen, and anything that lays out or paints per
 * frame is a stutter in the one moment a new player is forming an opinion.
 *
 *   * THE CARD ARRIVES FROM ITS SUBJECT. `--from-x` / `--from-y` are set by the
 *     layer to the direction the target lies in, so the card looks thrown from
 *     the thing it is about rather than fading in from nowhere. It overshoots
 *     and settles on --ease-snap.
 *   * THE BEAK DRAWS ITSELF AFTER the card has landed, so the connection reads
 *     as a consequence of the card arriving.
 *   * THE TITLE AND BODY ARRIVE SEPARATELY, 60ms apart. Cheap, and it is the
 *     difference between a card appearing and a card being delivered.
 *   * IT LEAVES THE WAY IT CAME, scaling down toward its subject.
 *
 * ═══ NO SIZE OF ITS OWN ═══
 *
 * The card is sized in `rem` and inherits the root font size, which the HUD's
 * uiScale already multiplies -- so it grows and shrinks with the player's
 * interface preference with no code here. `.tscale` carries the separate text
 * preference the same way every other surface takes it. That is what makes the
 * settings walkthrough possible: the card the player is reading resizes under
 * them as they drag the slider, which is the demonstration.
 */

import { useEffect, useState } from 'react'

/**
 * Split the owner's two emphasis marks into elements.
 *
 * ═══ A GRAMMAR, NOT A PARSER, AND CERTAINLY NOT HTML ═══
 *
 * He asked for "italic or bold (700 weight) if needed" and these strings are
 * HIS. `dangerouslySetInnerHTML` on owner-authored copy would make this the one
 * place in the interface where pasting a tag changes the page, and the strings
 * live in a file that is meant to be easy for him to edit. So the grammar is
 * two marks wide -- `**bold**` and `*italic*` -- and everything else is text.
 *
 * BOLD IS TESTED FIRST because `**` starts with `*`, and a single-mark rule
 * applied first would read `**x**` as an italic containing a literal asterisk.
 */
function emphasise(text: string): React.ReactNode[] {
  const out: React.ReactNode[] = []
  const pattern = /\*\*([^*]+)\*\*|\*([^*]+)\*/gu
  let last = 0
  let m: RegExpExecArray | null

  while ((m = pattern.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index))
    if (m[1] !== undefined) {
      out.push(
        <b key={out.length} style={{ fontWeight: 'var(--font-tutorial-head)' }}>
          {m[1]}
        </b>,
      )
    } else {
      out.push(<i key={out.length}>{m[2]}</i>)
    }
    last = m.index + m[0].length
  }
  if (last < text.length) out.push(text.slice(last))
  return out
}

export type CardProps = {
  title: string
  body: string
  /** 1-based, for the "3 of 9" line. */
  index: number
  total: number
  /** Absolute position, in px, already resolved by the layer. */
  left: number
  top: number
  /**
   * Unit vector from the card toward its target, so the arrival animation
   * comes from the right direction and the beak points the right way.
   */
  fromX: number
  fromY: number
  /** Null while the step is waiting for the player to press the real control. */
  onNext: (() => void) | null
  /** Null on the first step, which has nothing behind it. */
  onBack: (() => void) | null
  onSkip: () => void
  /** Raised by the layer one frame before it unmounts, to play the exit. */
  leaving: boolean
}

export default function AnnotationCard(p: CardProps) {
  // THE TITLE AND BODY ARRIVE SEPARATELY, and this is what staggers them. A
  // state flip on a timer rather than a CSS delay, because the card can be
  // re-pointed at a new target without unmounting and the stagger has to
  // restart when it is.
  const [landed, setLanded] = useState(false)
  useEffect(() => {
    const t = setTimeout(() => setLanded(true), 180)
    return () => clearTimeout(t)
  }, [])

  return (
    <div
      className={`tut-card tscale${p.leaving ? ' tut-card--leaving' : ''}`}
      style={{
        left: p.left,
        top: p.top,
        ['--from-x' as string]: `${p.fromX * 2.5}rem`,
        ['--from-y' as string]: `${p.fromY * 2.5}rem`,
      }}
      role="dialog"
      aria-live="polite"
      aria-label={p.title}
    >
      {/* THE BEAK. Drawn after the card lands, rotated to face the subject.
          aria-hidden because it is a line, and the card's own label already
          says what this is about. */}
      <span
        aria-hidden
        className="tut-beak"
        style={{
          // DEGREES, COMPUTED HERE. See the note over @keyframes tutBeak: CSS
          // atan2() is Chrome 111 and this bundle targets Chrome 103.
          ['--beak-deg' as string]:
            `${(Math.atan2(p.fromY, p.fromX) * 180) / Math.PI}deg`,
        }}
      />

      <div className={`tut-title${landed ? ' tut-in' : ''}`}>{p.title}</div>
      <p className={`tut-body${landed ? ' tut-in' : ''}`}>{emphasise(p.body)}</p>

      <div className="tut-foot">
        {/* THE COUNT IS NOT DECORATION. "How much of this is left" is the first
            thing anybody wants from a walkthrough, and without it the honest
            answer is "unknowable", which is how a player decides to skip. */}
        <span className="tut-count">
          {p.index} of {p.total}
        </span>

        <span className="tut-acts">
          <button type="button" className="tut-btn tut-btn--quiet" onClick={p.onSkip}>
            Skip
          </button>
          {p.onBack ? (
            <button type="button" className="tut-btn" onClick={p.onBack}>
              Last
            </button>
          ) : null}
          {/* ABSENT, NOT DISABLED, while the step waits for the real control.
              A greyed Next invites a click that does nothing; no Next at all
              leaves the only live thing on screen being the button the card is
              pointing at, which is the instruction. */}
          {p.onNext ? (
            <button type="button" className="tut-btn tut-btn--go" onClick={p.onNext}>
              Next
            </button>
          ) : null}
        </span>
      </div>
    </div>
  )
}
