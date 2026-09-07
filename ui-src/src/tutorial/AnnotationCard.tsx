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

import Btn from '../ui/Btn'
import { KeyCap } from '../ui/KeyCap'

/**
 * One "← Last" hint: the key, then what it does.
 *
 * NOT A BUTTON AND NOT PRETENDING TO BE ONE. It carries no press handler, no
 * hover and no focus ring -- the same call hud/SpectateHint.tsx makes, whose own
 * header says "IT LOOKS LIKE A BUTTON AND IS NOT ONE". A thing that looks
 * pressable and is not is the cruellest control on a screen with no pointer.
 */
function KeyHint(p: { cap: string; children: React.ReactNode }) {
  return (
    <span className="tut-key">
      {/* THE PROJECT'S OWN GLYPH, so an arrow in the footer and a key named in
          a sentence are visibly the same object. `label` rather than `command`
          because these three are raw GTA controls read in Lua, not bindings --
          there is nothing to look up and nothing that can ever rebind them.

          IT IS ALSO WHY THE ARROWS ARE HEAVY NOW. Owner, 2026-09-06: "the black
          font used in your left/right/up/down arrow SVGs needs much more
          weight. It's far too thin. Perhaps 3x." They were text in a hand-rolled
          box; KeyCap draws Anton on a filled plate, which is both the weight he
          asked for and what every other key in this game already looks like. */}
      <KeyCap label={p.cap} fs="0.78rem" />
      {p.children}
    </span>
  )
}

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
  // FOUR MARKS, AND THE ORDER IS THE RULE. `**` is tested before `*` because a
  // single-mark rule applied first reads `**x**` as an italic containing a
  // literal asterisk. The other two cannot collide with anything.
  //
  //   **bold**       the owner's emphasis
  //   *italic*       the owner's other emphasis
  //   {key:command}  THE PROJECT'S OWN TOKEN, rendered by the project's own
  //                  KeyCap -- the same glyph the notice stack and the settings
  //                  page draw. Owner, 2026-09-06: "why are all these {keys}
  //                  not in our glyphs?" They were being substituted into bold
  //                  prose before this. The COMMAND reaches the renderer rather
  //                  than a substituted letter, which is what lets a cap on
  //                  screen follow a live rebind (#209) -- a substituted letter
  //                  is a photograph of the binding at the moment it was made.
  //   ~Volts~        the currency, in the currency's own colour. Owner,
  //                  2026-09-06: "the '250 Volts' text needs to be our
  //                  signature volts color."
  //
  // ═══ AND IT RECURSES, WHICH IS WHY THE TOKENS WERE INERT ═══
  //
  // Five of the six key tokens in the scripts are written inside `**...**`. The
  // bold branch emitted its captured text RAW, so a token wrapped in bold never
  // reached any rule that could render it -- the first version of this grammar
  // looked correct and did nothing on almost every card that used it.
  //
  // BOUNDED AT DEPTH 2 BY THE PATTERN ITSELF: `[^*]+` cannot contain an
  // asterisk, so a bold run can hold a key or a currency mark and nothing else,
  // and neither of those recurses.
  const pattern = /\*\*([^*]+)\*\*|\*([^*]+)\*|\{key:([A-Za-z0-9_]+)\}|~([^~]+)~/gu
  let last = 0
  let m: RegExpExecArray | null

  while ((m = pattern.exec(text)) !== null) {
    if (m.index > last) out.push(text.slice(last, m.index))
    if (m[1] !== undefined) {
      out.push(
        <b key={out.length} style={{ fontWeight: 'var(--font-tutorial-head)' }}>
          {emphasise(m[1])}
        </b>,
      )
    } else if (m[2] !== undefined) {
      out.push(<i key={out.length}>{emphasise(m[2])}</i>)
    } else if (m[3] !== undefined) {
      out.push(<KeyCap key={out.length} command={m[3]} fs="0.9rem" />)
    } else {
      out.push(<span key={out.length} className="tut-volts">{m[4]}</span>)
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
  /**
   * Null on a step that wants the player to press the REAL control.
   *
   * Owner, 2026-09-04: "don't have a next button on that one actually because
   * we want them to click Settings... Really any navigational steps should not
   * have a Next button." A card that both says "open Settings" and offers a way
   * past Settings is asking for one thing and accepting another.
   */
  onNext: (() => void) | null
  /** Null on the first step, and null across a doorway -- see TutorialLayer. */
  onBack: (() => void) | null
  /** Set only on the final card, which ends the run rather than advancing. */
  onDismiss: (() => void) | null
  /** What that button says. "Dismiss" unless the step overrides it. */
  dismissLabel?: string
  /**
   * An extra button that does the thing the card is describing.
   *
   * THE ESCAPE HATCH. A card advanced only by a key the player physically
   * cannot press is a card that traps them -- owner, 2026-09-04, on the player
   * list: "give them a button which will open it for them. This is best for
   * players who may not have realized their keyboard layout doesn't allow them
   * to use tilde or they need to make a macro."
   */
  action: { label: string; onPress: () => void } | null
  /** Raised by the layer one frame before it unmounts, to play the exit. */
  leaving: boolean
  /**
   * Show which KEY does each thing, instead of a button that does it.
   *
   * ═══ THE IN-GAME CARDS HAVE NOTHING TO CLICK WITH ═══
   *
   * Owner, 2026-09-05: "In-game we should actually get rid of the mouse pointer
   * for these cards altogether I think and use left/right arrow keys instead."
   * They take no NUI focus, so there is no cursor at all -- a `Btn` there would
   * be a control nobody can reach, which is worse than no control.
   *
   * SAME SLOTS, SAME ORDER, SAME WORDS. The hints sit exactly where the buttons
   * sit and read the same, so the two halves of the walkthrough do not feel like
   * two products; only the way you answer them differs.
   */
  keys?: boolean
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
      // `panel interactive tscale` -- THE PROJECT'S OWN VOCABULARY, and two of
      // those three are load-bearing rather than cosmetic:
      //
      //   `panel`       the same surface every other card in the game uses.
      //                 Owner, 2026-09-04: "our whole tutorial [needs] to
      //                 follow the same visual and button structure as the
      //                 existing UI". The FONT is the one sanctioned exception
      //                 and it stays; the box is not, and a bespoke one was
      //                 wrong.
      //   `interactive` pointer-events: auto. The page root is
      //                 pointer-events: none and only this class takes clicks
      //                 back -- which is why the first version DREW and could
      //                 not be pressed (owner: "the buttons don't work").
      //   `tscale`      the player's text-size preference, as every surface
      //                 takes it.
      className={`tut-card panel interactive tscale${p.leaving ? ' tut-card--leaving' : ''}`}
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
      {/* THE BEAK IS GONE. It was a 2px gradient meant to point from the card
          to its subject, and because it was positioned at the card's own
          centre it drew as a short blue line THROUGH the middle of the text
          (owner, 2026-09-04: "There seems to be a blue line though the center
          of the cards right in the center, kinda small. Not sure what that
          is."). A connector nobody can identify is not a connector.

          NOT REPOSITIONED, REMOVED. The ring around the subject already says
          which control the card is about, and it says it at the subject rather
          than asking the eye to follow a line. Two indicators for one fact was
          the mistake underneath the bug. */}
      <div className={`tut-title${landed ? ' tut-in' : ''}`}>{p.title}</div>
      <p className={`tut-body${landed ? ' tut-in' : ''}`}>{emphasise(p.body)}</p>

      <div className="tut-foot">
        {/* THE COUNT IS NOT DECORATION. "How much of this is left" is the first
            thing anybody wants from a walkthrough, and without it the honest
            answer is "unknowable", which is how a player decides to skip. */}
        <span className="tut-count">
          {p.index} of {p.total}
        </span>

        {/* THE PROJECT'S OWN BUTTON, NOT A BESPOKE ONE. `Btn` carries the
            variants, the sizes, the hover and press cues and the disabled
            treatment that every other control in the game already has, so
            these read and sound like the rest of the interface instead of
            like a web widget that wandered in.

            `ghost` for Skip and `default` for Last, because Next is the one
            loud object on the card and `primary` is reserved for exactly one
            per screen -- the same rule the lobby's Ready up follows. */}
        {/* NO SKIP. Owner, 2026-09-04: "let's remove the skip button." The way
            out is the walkthrough's own end, the Escape the rest of the
            interface already answers, or simply not starting it -- the
            checkbox is opt-out before it begins, which is the moment a player
            actually decides. */}
        <span className="tut-acts">
          {p.action ? (
            p.keys ? (
              // UP, BECAUSE THE ACTION OPENS SOMETHING. See the NAV table in
              // br_core/client/tutorial.lua for why this key and not another.
              <KeyHint cap="↑">{p.action.label}</KeyHint>
            ) : (
              <Btn variant="default" size="sm" cue="ui.select" onPress={p.action.onPress}>
                {p.action.label}
              </Btn>
            )
          ) : null}
          {p.onBack ? (
            p.keys ? (
              <KeyHint cap="←">Last</KeyHint>
            ) : (
              <Btn variant="default" size="sm" cue="ui.select" onPress={p.onBack}>
                Last
              </Btn>
            )
          ) : null}
          {/* ABSENT ON A NAVIGATIONAL STEP, which is the owner's rule: the
              only way past "open Settings" is to open Settings. The card is
              then the instruction and the ringed control is the only live
              thing on screen, which is the whole point of pointing at it. */}
          {p.onNext ? (
            p.keys ? (
              <KeyHint cap="→">Next</KeyHint>
            ) : (
              <Btn variant="primary" size="sm" cue="ui.select" onPress={p.onNext}>
                Next
              </Btn>
            )
          ) : null}
          {/* THE END. Owner, 2026-09-04: the last card "should only have a
              'Dismiss button' and the lobby tutorial is now over. This is when
              the 'ready up' button should release." */}
          {p.onDismiss ? (
            p.keys ? (
              <KeyHint cap="→">{p.dismissLabel ?? 'Dismiss'}</KeyHint>
            ) : (
              <Btn variant="primary" size="sm" cue="ui.select" onPress={p.onDismiss}>
                {p.dismissLabel ?? 'Dismiss'}
              </Btn>
            )
          ) : null}
        </span>
      </div>
    </div>
  )
}
