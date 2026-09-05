/**
 * The guided first run, lobby half — what it says and what it points at (#261).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * ONE LIST, AND IT IS THE WHOLE SCRIPT
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * Every sentence a new player reads is here. Nothing in the layer or the card
 * invents prose, and nothing else in the interface may either — the same rule
 * `BR.Config.ReviveKey.copy` holds on the Lua side, for the same reason: the
 * owner can rewrite every word this feature says by editing one file, without
 * opening a component.
 *
 * ═══ THE TARGET IS A `data-tut` ATTRIBUTE, NOT A REF OR A POSITION ═══
 *
 * A step names a string; the layer finds `[data-tut="<that>"]` and measures it
 * with getBoundingClientRect at the moment it draws. Three consequences, and
 * each of them is a requirement the owner stated:
 *
 *   * UI SCALE AND FONT SIZE are followed for free. He asked for the tutorial
 *     to walk a player through changing both, which means the card has to
 *     survive the thing it is pointing at moving and resizing WHILE IT IS ON
 *     SCREEN. A measured rect does; a stored coordinate does not.
 *   * ASPECT RATIO is followed for the same reason, at 16:9 and at 32:9, with
 *     no breakpoint list of its own.
 *   * A BUTTON THAT MOVES IN A REFACTOR takes its annotation with it, and a
 *     button that is renamed away fails LOUDLY rather than pointing at empty
 *     screen — see `missingTarget` in TutorialLayer.
 *
 * ═══ HE CLICKS IT HIMSELF ═══
 *
 * Owner, 2026-09-02: "For each one the player actually clicks it and the
 * function runs as normal." So a step does not simulate anything and the layer
 * never calls a handler. `advanceOn` says what ends the step: `next` is the
 * button on the card, `click` means the player has to press the real control
 * and the card waits until they do.
 *
 * ═══ EMPHASIS IS MARKUP, DELIBERATELY, AND THERE ARE EXACTLY TWO ═══
 *
 * Owner, 2026-09-04: "we can make any key details italic or bold (700 weight)
 * if needed." `*word*` is italic and `**word**` is 700. A tiny grammar rather
 * than raw HTML because these strings are his and must never become a place
 * where a tag can be pasted; see `emphasise` in AnnotationCard.
 */

/** What ends a step and moves to the next one. */
export type Advance =
  /** The card's own Next button. For anything with nothing to press. */
  | 'next'
  /**
   * The real control. The card waits, the player presses the thing being
   * described, and its normal handler runs untouched.
   */
  | 'click'

export type Step = {
  /** Stable id. Persisted progress and every log line key on this. */
  id: string
  /** `data-tut` value of the control this card is about. */
  target: string
  /** 700-weight heading. Short — it is a label, not a sentence. */
  title: string
  /**
   * The card's prose, at weight 350. `*italic*` and `**bold**` are the only
   * markup, and both are the owner's own allowance.
   */
  body: string
  advance: Advance
  /**
   * Steps that only exist once the player has opened a child page. The layer
   * runs these when `screen` matches what is actually on top, which is how
   * "a second round of annotations explains everything inside it" works
   * without the list needing to know how navigation is done.
   */
  screen?: string
}

/**
 * PLACEHOLDER PROSE, AND IT IS MARKED AS SUCH ON PURPOSE.
 *
 * The owner has written the SHAPE of this feature in detail and has not yet
 * written its words. Every `body` below is mine, and every one of them is a
 * sentence he has not approved — which by the standing rule means none of them
 * may ship to a player as final copy.
 *
 * THEY ARE REAL SENTENCES RATHER THAN LOREM, because a card full of filler
 * cannot be judged for length, tone or line count, and those are exactly what
 * he will want to react to. They are written to be replaced.
 *
 * See the issue comment on #261 for the list handed to him.
 */
export const LOBBY_STEPS: Step[] = [
  {
    id: 'welcome',
    target: 'lobby-root',
    title: 'Welcome to Blitz Royale',
    body: 'This is the lobby. Everything you do between matches happens on this screen, and this walkthrough covers all of it. Press **Next** to begin.',
    advance: 'next',
  },
  {
    id: 'mode',
    target: 'mode-picker',
    title: 'Pick how you play',
    body: '**Solo** is one life against everybody. **Squads** puts you in a team of up to four who can revive each other. You can change this any time before you ready up.',
    advance: 'next',
  },
  {
    id: 'settings',
    target: 'settings',
    title: 'Make it readable first',
    body: 'Open **Settings**. Before anything else it is worth setting the interface and text size to suit your screen — everything in this walkthrough will follow along as you change them.',
    advance: 'click',
  },
  {
    id: 'settings-scale',
    target: 'settings-uiscale',
    title: 'Interface size',
    body: 'This scales every panel in the game. Drag it and watch this card move with it — *that is what it will look like in a match*.',
    advance: 'next',
    screen: 'settings',
  },
  {
    id: 'settings-text',
    target: 'settings-textscale',
    title: 'Text size',
    body: 'This one scales the words on their own, on top of the interface size. Set both so you can read a toast without leaning in.',
    advance: 'next',
    screen: 'settings',
  },
  {
    id: 'locker',
    target: 'locker',
    title: 'Your character',
    body: 'The **Locker** is where you choose who you look like. It changes nothing about how you play — nobody has an advantage here.',
    advance: 'click',
  },
  {
    id: 'market',
    target: 'market',
    title: 'Spending Volts',
    body: 'Volts are what you earn for playing well. The **Market** is the only place to spend them, and everything in it is cosmetic.',
    advance: 'click',
  },
  {
    id: 'help',
    target: 'help',
    title: 'The manual',
    body: '**Help** explains every system in the game and it is always here. You can also restart this walkthrough from that page at any time.',
    advance: 'click',
  },
  {
    id: 'ready',
    target: 'ready',
    title: 'That is the lobby',
    body: 'That covers this screen. When you are ready, **Ready up** puts you in the queue for the next match.',
    advance: 'next',
  },
]
