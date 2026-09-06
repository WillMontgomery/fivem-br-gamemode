/**
 * The guided first run, IN-GAME half — what it says and what it points at (#261).
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * THE SAME MACHINE, POINTED AT THE HUD
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * `TutorialLayer` takes this list instead of the lobby's. Everything that
 * differs between the two halves is DATA — which control, which sentence, what
 * ends the step — so there is one sequencer, one placement rule and one
 * step-skipping fix rather than two of each.
 *
 * ═══ IT RUNS INSIDE THE WARMUP HOLD ═══
 *
 * Owner, 2026-09-04: "if they're in the tutorial, they're not actively on any
 * warmup timer at all until the tutorial is complete." That hold is already
 * built and server-authoritative (`BR.Roster.setTutorial`), so nothing here has
 * to think about a clock running out mid-card. The last step is what releases
 * it — "when they click yes, they're put into whatever match type they selected
 * in the lobby and the warmup timer begins".
 *
 * ═══ THE REWARD HANGS ON FINISHING THIS HALF ═══
 *
 * The 500 Volts is paid for the whole thing, lobby and match, and the lobby's
 * last card says so. Nothing here pays out; the award belongs to whatever
 * observes this list completing.
 *
 * ═══════════════════════════════════════════════════════════════════════════
 * WHAT IS HERE AND WHAT IS STAGED
 * ═══════════════════════════════════════════════════════════════════════════
 *
 * The steps below are the ones that point at something already on screen. The
 * owner's spec also calls for staged demonstrations — four simulated kill-feed
 * events, a fake populated squad panel, a persistent notification, the map with
 * its waypoint explanation, the four warmup crates, the inventory menu and the
 * shop. Each of those needs a mechanism this file cannot express yet:
 *
 *   * a step that STAGES something before it draws (fake feed, fake squad);
 *   * a step that ends on a KEY PRESS rather than a click (map, inventory);
 *   * a step that ends on a GAME EVENT (a crate opened, two items picked up);
 *   * a card that draws over the big map, which today nothing may do.
 *
 * They are deliberately absent rather than present-and-broken: a step naming an
 * anchor nothing renders ends the run 1.2 seconds in, which is exactly the fault
 * this feature already shipped once (2026-09-04). Each lands with its mechanism.
 */

import type { Step } from './steps'

/**
 * The key the player has bound to an action, ready to print.
 *
 * ═══ THE BINDING, NOT THE DEFAULT ═══
 *
 * Owner, 2026-09-04, on the player list: "tell them to 'press {player list key}'
 * or give them a button which will open it for them. This is best for players
 * who may not have realized their keyboard layout doesn't allow them to use
 * tilde or they need to make a macro for example, so they don't get stuck in the
 * tutorial."
 *
 * So the sentence is built from what Lua actually reports for that command, and
 * the card offers a button as well — a walkthrough that can only be advanced by
 * a key the player physically cannot press is a walkthrough that traps them.
 */
export type Keybinds = Array<{ command: string; key?: string; vk?: number }>

/** Windows VK for the backtick/tilde key. */
export const VK_TILDE = 0xc0

export function keyFor(binds: Keybinds, command: string): string | null {
  const b = binds.find((x) => x.command === command)
  if (!b || !b.key) return null
  return b.key
}

/**
 * Is this action still on tilde?
 *
 * Owner: "If the key is still bound to tilde at this point in time, include a
 * suffix to that sentence '(above TAB on your keyboard)'." Tilde is the one
 * default in the game a player may genuinely be unable to find — it is missing,
 * moved or dead on a good many non-US layouts — so the suffix is a location
 * rather than a name.
 */
export function isTilde(binds: Keybinds, command: string): boolean {
  return binds.find((x) => x.command === command)?.vk === VK_TILDE
}

/**
 * The steps that need no staging.
 *
 * PLACEHOLDER PROSE, as in the lobby half: every `body` is mine and none of it
 * is approved. Real sentences rather than lorem, because length and tone are
 * what he reacts to and filler cannot be judged for either.
 */
export const GAME_STEPS: Step[] = [
  {
    id: 'game-vitals',
    target: 'hud-vitals',
    title: 'Health and shield',
    body: 'Your **health** is the lower bar and your **shield** is the one above it. Shield takes damage first and is the only one you can top up mid-fight, from shield potions.',
    advance: 'next',
  },
  {
    id: 'game-counters',
    target: 'hud-counters',
    title: 'Who is left',
    body: '**Alive** counts everybody still in the match and **Elims** counts what you have done about it. In squads the line underneath tells you how many teams remain, which is the number that actually decides the match.',
    advance: 'next',
  },
  {
    id: 'game-feed',
    target: 'hud-feed',
    title: 'The kill feed',
    // STAGED, because a new player on the pad has an empty feed and a card
    // pointing at a blank corner teaches nothing.
    stage: 'killfeed',
    body: 'Every elimination in the match shows up here, with the weapon that did it. **Your own** kills and deaths are picked out in colour so you can find them at a glance. The storm counts as a killer too.',
    advance: 'next',
  },
  {
    id: 'game-squad',
    target: 'hud-squad',
    title: 'Your squad',
    // STAGED, for the same reason the feed is: a solo player has no panel and a
    // squad of one has a single plate, so on the pad this card usually points at
    // nothing. The staged squad has a downed mate in it on purpose -- the plate
    // states are half of what the card is describing.
    stage: 'squad',
    body: 'One plate per squadmate, in their own colour — the same colour as their dot on the radar. The bars are their **health** and **shield**, the number is their eliminations, and a plate goes dark with a countdown when that mate is **down** and can still be revived.',
    advance: 'next',
  },
  {
    id: 'game-notice',
    target: 'hud-counters',
    title: 'Notifications',
    // The card is about what a notification looks like, so it stages one and
    // holds it until they move on.
    stage: 'notice',
    body: 'Anything the game needs to tell you arrives like this — a squadmate going down, a crate you have opened, the storm about to move. They stack up in the pause menu if you miss one.',
    advance: 'next',
  },
  {
    id: 'game-players',
    target: 'hud-counters',
    title: 'Everybody in the match',
    // {key:…} becomes the player's ACTUAL binding, {tilde:…} adds the location
    // suffix only while that command is still on tilde. See `withKeys`.
    body: 'Press **{key:brplayers}**{tilde:brplayers} to see everyone still playing, and to report someone if you need to.',
    advance: 'screen',
    awaitScreen: 'players',
    // THE ESCAPE HATCH. A player whose layout has no usable tilde, or who needs
    // a macro, must not be stuck on this card.
    action: { label: 'Open it for me', cb: 'br/players/focus' },
  },
  {
    id: 'game-inventory',
    target: 'hud-inventory',
    title: 'What you are carrying',
    body: 'Five slots, and the number beside a weapon is the **ammo in the magazine** over what is left in reserve. Press **{key:brslot1}** to **{key:brslot5}** to switch between them.',
    advance: 'next',
  },
  {
    id: 'game-invpanel',
    target: 'hud-inventory',
    title: 'The full inventory',
    body: 'Press **{key:brinventory}** to open it properly — you can move things between slots and drop what you do not want.',
    advance: 'screen',
    awaitScreen: 'inventory',
    // NO BUTTON HERE, AND THE ASYMMETRY IS DELIBERATE. There is no callback that
    // opens the inventory -- the panel is client-side, opened by the key and
    // nothing else -- and inventing one to give this card a button would be
    // plumbing built for a walkthrough rather than for the game.
    //
    // The escape hatch exists on the PLAYER LIST card because that key is tilde,
    // which a good many layouts do not have. This one is TAB, which every
    // keyboard has and every player can reach. If that ever stops being true the
    // callback is the fix, not a second default.
  },
]
