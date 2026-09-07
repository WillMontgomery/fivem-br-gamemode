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

import type { CallbackName } from '../bridge/types'

/** What ends a step and moves to the next one. */
export type Advance =
  /** The card's own Next button. For anything with nothing to press. */
  | 'next'
  /**
   * The real control. The card waits, the player presses the thing being
   * described, and its normal handler runs untouched.
   *
   * NO NEXT BUTTON ON THESE. Owner, 2026-09-04: "Really any navigational steps
   * should not have a Next button." The ringed control is the only way on.
   */
  | 'click'
  /**
   * The end. One button, Dismiss, and the walkthrough is over -- which is also
   * the moment Ready up is released.
   */
  | 'dismiss'
  /**
   * A screen opening. The card waits until `awaitScreen` is what is on top.
   *
   * FOR THE THINGS A KEY OPENS. The player list and the inventory menu are
   * reached by a keypress, and the page cannot read game keys -- but it can see
   * the screen that keypress produces, which is the same fact one step later
   * and needs no new wire. It also means the card's own button and the player's
   * keyboard advance it identically, which is the point: owner, 2026-09-04,
   * "tell them to 'press {player list key}' or give them a button which will
   * open it for them... so they don't get stuck in the tutorial."
   */
  | 'screen'
  /**
   * The player picking things up. The card waits until they are carrying
   * `pickups` MORE items than when it opened.
   *
   * OBSERVED, NOT REPORTED. Owner, 2026-09-04: "Upon opening one, they should
   * get an instruction to pick up 2 loot items." The inventory is already in
   * this store, pushed on every change, so this needs no new wire and no new
   * event -- and it is the same fact the player can see, which is what the card
   * is asking them to do.
   *
   * IT COUNTS ITEMS, NOT SLOTS, and it used to count slots. That was the bug
   * the owner walked into on 2026-09-05 ("I took 2 things from the crate and the
   * next step never appeared"): br_core/server/inventory.lua's `give` opens with
   * "Ammo never occupies a slot", and fills existing stacks before opening a new
   * one -- so of the three things a warmup crate drops, two kinds routinely
   * arrive without the slot count moving at all. A card asking for two items was
   * unsatisfiable by the loot it was pointing at.
   *
   * AMMO IS ONE PICKUP PER POOL. A box adds thirty rounds, and "take two things"
   * must not be answered by one box. See `tally` in TutorialLayer.
   */
  | 'pickup'
  /**
   * The player opening one of the four warmup crates.
   *
   * Owner, 2026-09-05: "'go and open one' should not have a 'next' button as
   * we're waiting for their action as we've directed them."
   *
   * TOLD, NOT OBSERVED, AND IT IS THE ONLY ONE. Every other advance in this file
   * reads state the page already holds. Opening a crate changes nothing the page
   * can see -- nothing lands in the inventory, no NUI message is sent, and the
   * server's whole receipt is the crate being re-announced as its husk in Lua.
   * So br_core counts them and the count rides the walkthrough's own envelope.
   */
  | 'crate'
  /**
   * The engine's own full-screen map coming up.
   *
   * Owner, 2026-09-06: "While on step 14, opening the full map like it tells me
   * to doesn't progress to step 15." It did not, because that card advanced on
   * Next like any other -- so the card said "press this" and accepted anything.
   *
   * A RISING EDGE, not a level: see the map effect in TutorialLayer. A map that
   * is somehow already open must not skip the card on its first frame, which is
   * the same class as the `clickedFor` step-skipping bug.
   */
  | 'map'

export type Step = {
  /** Stable id. Persisted progress and every log line key on this. */
  id: string
  /**
   * `data-tut` value of the control this card is about.
   *
   * OPTIONAL, AND AN ABSENT ONE IS A REAL KIND OF CARD. Some things a
   * walkthrough has to explain are not on the HUD at all -- crates standing in
   * the world, the whole surface of the open map, a shop car you are not next
   * to yet. Those used to borrow whatever anchor was nearest, which is how the
   * owner ended up with a card about crates outlining his inventory and three
   * more ringing the Elims/Alive plates (2026-09-06).
   *
   * A targetless card draws CENTRED with no ring, waits for nothing, and cannot
   * end the run by being unable to find itself.
   */
  target?: string
  /** 700-weight heading. Short — it is a label, not a sentence. */
  title: string
  /**
   * The card's prose, at weight 350. `*italic*` and `**bold**` are the only
   * markup, and both are the owner's own allowance.
   */
  body: string
  advance: Advance
  /** For `advance: 'screen'` -- the screen whose arrival ends the step. */
  awaitScreen?: string
  /** For `advance: 'pickup'` -- how many more ITEMS end the step. See `tally`. */
  pickups?: number
  /** For `advance: 'crate'` -- how many warmup crates end the step. Default 1. */
  crates?: number
  /**
   * For `advance: 'dismiss'` -- what the last button says, when "Dismiss" is
   * the wrong word for it.
   *
   * The lobby half ends on "Dismiss" because the owner asked for that word in
   * as many words. The in-game half ends on a QUESTION -- "are you ready to
   * start?" -- and Dismiss is not an answer to a question.
   */
  dismissLabel?: string
  /**
   * A demonstration staged when the card opens.
   *
   * SOME OF THIS WALKTHROUGH IS ABOUT THINGS THAT ARE NOT HAPPENING. A new
   * player on the warmup pad has an empty kill feed and, usually, no squad --
   * so pointing at either shows them a blank corner. The owner asked for the
   * feed to be demonstrated ("then should simulate 4 fake kill stream events
   * and point those out"), and a staged demo is the only way to point at
   * something that is not there.
   *
   * IT WRITES INTO THIS CLIENT'S OWN STORE AND NOWHERE ELSE. Nothing is sent,
   * nothing is recorded, and no other player can see it.
   */
  stage?: 'killfeed' | 'squad' | 'notice'
  /**
   * An extra button on the card that performs the thing being described.
   *
   * THE ESCAPE HATCH FOR A KEY THEY CANNOT PRESS. See `advance: 'screen'`.
   */
  action?: { label: string; cb: CallbackName }
  /**
   * Hide Last, even where the automatic rule would show it.
   *
   * FOR THE FIRST CARD ON A PAGE THE `screen` RULE CANNOT SEE. Settings' tabs
   * are all one `screen`, so the first card on the Controls tab looks like a
   * sibling of the card that opened it -- and Last there returns to "open
   * Controls", pointing at a tab that is already open, which does nothing when
   * pressed (owner, 2026-09-04: "For the first instruction on each page like
   * step 10, no 'last' button should be available. Currently, pressing it does
   * nothing.").
   */
  noBack?: boolean
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
    target: 'lobby-menu',
    title: 'Welcome to Blitz Royale',
    body: 'This is the lobby. Everything you do between matches happens on this screen, and this walkthrough covers all of it.',
    advance: 'next',
  },
  {
    id: 'mode',
    // SQUADS SPECIFICALLY, AND THE STEP WAITS FOR IT. Owner, 2026-09-04: "The
    // solos/squads demo should enforce that they select Squads to show them the
    // controls of parties." The party controls do not exist on this screen until
    // Squads is picked, so a card explaining them over a solo lobby is a card
    // pointing at nothing.
    target: 'mode-squad',
    title: 'Solo or Squads',
    body: '**Solo** is one life against everybody. Pick **Squads** — you are put in a team of up to four who can revive each other, and the party controls appear so you can bring friends in with you.',
    advance: 'click',
  },

  // ═══ SETTINGS ═══
  {
    id: 'settings',
    target: 'settings',
    title: 'Make it yours first',
    body: 'Open **Settings**. Before anything else it is worth making the game fit your screen and your ears.',
    advance: 'click',
  },
  {
    id: 'settings-uiscale',
    target: 'settings-uiscale',
    title: 'Interface size',
    body: 'This scales every panel in the game. Drag it and let go — *watch this card resize with it*.',
    advance: 'click',
    screen: 'settings',
  },
  {
    id: 'settings-textscale',
    target: 'settings-textscale',
    title: 'Text size',
    body: 'This scales the words on their own, on top of the interface size. Set both so you can read a toast without leaning in.',
    advance: 'click',
    screen: 'settings',
  },
  {
    id: 'settings-display',
    target: 'settings-display',
    title: 'Graphics and display',
    body: 'Resolution, fullscreen and the graphics quality are the *game’s own* settings, not ours — this panel points you at where GTA keeps them. Nothing to change here.',
    advance: 'next',
    screen: 'settings',
  },
  {
    id: 'settings-volui',
    target: 'settings-volui',
    title: 'Sound',
    body: 'Interface sounds are the clicks and cues these menus make. Drag it and let go to set them.',
    advance: 'click',
    screen: 'settings',
  },
  {
    id: 'settings-voice',
    target: 'settings-voice',
    title: 'Talking to people',
    // HIS WORDS, VERBATIM (2026-09-04).
    body: 'Voice chat is set separately for **solos** and **squads**, so you can hear your team without hearing strangers. You can change your input/output settings here as well.',
    advance: 'next',
    screen: 'settings',
  },
  {
    id: 'settings-controls',
    target: 'settings-tab-controls',
    title: 'Your keys',
    body: 'Open **Controls**.',
    advance: 'click',
    screen: 'settings',
  },
  {
    id: 'settings-controls-body',
    target: 'settings-controls-body',
    noBack: true,
    title: 'Every key, in one place',
    body: 'This is every key the game uses and what it does. Click any row to rebind it, and anything you change is yours from the next match on.',
    advance: 'next',
    screen: 'settings',
  },
  {
    id: 'settings-accessibility',
    target: 'settings-tab-accessibility',
    title: 'Accessibility',
    body: 'And **Accessibility** has color-blind modes, with a preview so you can see the difference before you commit to it.',
    advance: 'click',
    screen: 'settings',
  },
  {
    id: 'settings-done',
    target: 'settings-save',
    title: 'That is Settings',
    body: 'Press **Save** to keep your changes and close this screen.',
    advance: 'click',
    screen: 'settings',
  },

  // ═══ THE LOBBY'S OTHER DOORS ═══
  {
    id: 'locker',
    target: 'locker',
    title: 'Your character',
    body: 'Open the **Locker**.',
    advance: 'click',
  },
  {
    id: 'locker-inside',
    target: 'locker-done',
    title: 'Who you look like',
    body: 'Pick the character you want to drop in as. It is how other players see you and nothing more. Press **Done** when you are ready.',
    advance: 'click',
    screen: 'locker',
  },
  {
    id: 'market',
    target: 'market',
    title: 'Spending Volts',
    body: "Volts are the currency of the game. You can use them to buy things within the game, or within the **Market**, where you'll find cosmetics.",
    advance: 'click',
  },
  {
    id: 'help',
    target: 'help',
    title: 'The manual',
    body: 'Open **Help**.',
    advance: 'click',
  },
  {
    id: 'help-inside',
    target: 'help-body',
    title: 'Everything else',
    // HIS WORDING FOR THE DISCORD CLAUSE (2026-09-04).
    body: 'The player guide lives here and explains every system in the game. There is a button to copy its link if you would rather read it in a browser, and a link to our **Discord** where you can connect with the Blitz community.',
    advance: 'next',
    screen: 'help',
  },
  {
    id: 'help-back',
    // OUT THROUGH THE REAL DOOR. Owner: "Step 17 should also direct them to
    // click the back button on the bottom of the screen (under the iframe)
    // instead of next." A walkthrough that teaches a Next button teaches
    // nothing about the screen it is standing on.
    target: 'help-back',
    title: 'Back to the lobby',
    body: 'Press **Back** when you are done reading.',
    advance: 'click',
    screen: 'help',
  },
  {
    id: 'ready',
    target: 'ready',
    title: 'That is the lobby',
    // THE CONDITION ON THE REWARD IS STATED HERE AND NOWHERE ELSE. Owner:
    // "Step 18 should tell them the 500 Volts is only awarded if they continue
    // the tutorial into the first match." The toggle above Ready up offers the
    // second half; this is the only card that says the Volts depend on it.
    body: 'That covers the lobby. Leave **Continue tutorial into the first match** switched on and finish it in game to earn your **500 Volts** — the reward is only paid for the whole thing.',
    advance: 'dismiss',
  },
]
