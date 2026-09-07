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
 * warmup timer at all until the tutorial is complete."
 *
 * ⚠ THAT IS NOT TRUE YET, AND SAYING SO HERE IS THE POINT. The hold exists and
 * is server-authoritative (`BR.Roster.setTutorial`), but its B1 grants it only
 * from a STANDING START -- LOBBY, attached to no match -- and this half runs on
 * the pad, in WARMUP, inside one. So `/brtutorial game` asks for the hold, the
 * server prints a refusal, and the warmup clock goes on running under every
 * card below. A slow reader gets put on the bus mid-walkthrough.
 *
 * B1 IS NOT AN OVERSIGHT TO WIDEN: it is what stops the hold being a dodge
 * button for a fight or a results publish. Closing this properly means a
 * per-match warmup hold, in the shape `brwarmupfreeze` already has -- owner,
 * 2026-09-04: "when they click yes, they're put into whatever match type they
 * selected in the lobby and the warmup timer begins".
 *
 * ═══ THE REWARD HANGS ON FINISHING THIS HALF ═══
 *
 * The 500 Volts is paid for the whole thing, lobby and match, and the lobby's
 * last card says so. IT IS PAID WHEN THE FINAL CARD BELOW IS DISMISSED -- App
 * sends `done` alongside `game = false`, br_core claims it on
 * BR.Net.TUTORIAL_DONE and br_stats writes it. Abandoning on a missing anchor
 * pays nothing, on purpose.
 *
 * ONCE PER ACCOUNT, FOREVER, and the lock is the database rather than any of
 * this: br_ddb's `awardPay` credits and records in one conditional write. So
 * the Help page re-run pays nothing the second time, and neither does a client
 * that sends the claim without reading a word.
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
    body: 'Every elimination in the match shows up here, with the weapon that did it. **Your own** kills and deaths are picked out in color so you can find them at a glance. The storm counts as a killer too.',
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
    body: 'One plate per squadmate, in their own color — the same color as their dot on the radar.',
    advance: 'next',
  },
  {
    id: 'game-squad-name',
    // THE PARTS GET THEIR OWN BOXES. Owner, 2026-09-04: "for smaller things we
    // should draw a box around them to show what part is being described." A
    // ring around the whole panel while the card talks about one row in it is a
    // card pointing at four things and meaning one.
    target: 'squad-name',
    title: 'Who they are',
    // The staged squad is still up: `stage` is re-declared so the panel does not
    // blink out between these three cards.
    stage: 'squad',
    body: 'Their name, with a **speaker** beside it when they are talking and their **level** after it. The mark only appears while their voice is actually coming through.',
    advance: 'next',
  },
  {
    id: 'game-squad-bars',
    target: 'squad-bars',
    title: 'How they are doing',
    stage: 'squad',
    body: 'Health on top, **shield** underneath. When a mate goes **down** the bars are replaced by a countdown — that is how long you have to reach them before they are out for good.',
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
    // ON THE DOWN ARROW IN GAME, not a click: these cards take no cursor. The
    // card prints the key; see AnnotationCard's `keys`.
    action: { label: 'Open it for me', cb: 'br/players/focus' },
  },
  {
    id: 'game-report',
    // ═══ THE CARD THAT ONLY EXISTS INSIDE THE PLAYER LIST ═══
    //
    // Owner, 2026-09-05: "After clicking 'open it for me' they should see an
    // explanation of how to report players for cheating or harassment etc, then
    // a prompt to close the playerlist."
    //
    // SCOPED TO THE SCREEN, so it draws only while the list is actually up --
    // and points at the button rather than at the panel, which is the owner's
    // standing rule for anything smaller than a whole surface.
    target: 'players-report',
    screen: 'players',
    title: 'Reporting somebody',
    body: 'If a player is **cheating**, or is abusive in voice or chat, press **Report player** and pick them from this list. An admin reads every one, and every correct report is awarded ~100 Volts~.',
    advance: 'next',
  },
  {
    id: 'game-players-close',
    target: 'players-report',
    screen: 'players',
    title: 'Close it when you are done',
    // ENDS ON THE LIST GOING AWAY, which is the same key that opened it. There
    // is no `advance` kind for "a screen closed" because there did not need to
    // be: `screen` is whatever is on top, and the bare HUD is `none`.
    body: 'Press **{key:brplayers}** again, or **Escape**, to close the list.',
    advance: 'screen',
    awaitScreen: 'none',
    // NO BACK BUTTON ACROSS THE DOORWAY. Last would have to reopen a screen the
    // player is being asked to close.
    noBack: true,
  },
  {
    id: 'game-crates',
    // The markers over the four crates are what this card points at in the
    // world; on screen it anchors to the inventory, which is where the loot it
    // is about to talk about will land.
    target: 'hud-inventory',
    title: 'Crates',
    body: 'Those four marked crates on the pad are yours to practice on — they refill themselves, so take as long as you like. The **marker color is the rarity** of what is inside, and they get better left to right. **Go and open one.**',
    // NO NEXT BUTTON: the card sends them somewhere, so the only way past it is
    // going (owner, 2026-09-05). The escape hatch after 45s is in TutorialLayer
    // and exists so a miscount cannot trap anybody -- see `stuck`.
    advance: 'crate',
    crates: 1,
  },
  {
    id: 'game-pickup',
    target: 'hud-inventory',
    title: 'Take what you want',
    // OBSERVED, not reported: the store already knows what they are carrying.
    //
    // "Walk over anything on the ground to pick it up" was the first version and
    // it described a mechanic this game does not have -- loot is claimed by
    // holding the interact key against a prompt, not by walking through it. The
    // key is printed from the player's own binding, like every other key in this
    // script.
    body: 'Stand over anything on the ground and hold {key:brinteract} to pick it up. **Take two things** from the crate you opened. Nothing you pick up in warmup comes with you into the match.',
    advance: 'pickup',
    pickups: 2,
  },
  {
    id: 'game-inventory',
    target: 'hud-inventory',
    title: 'What you are carrying',
    body: 'Five slots, and the number beside a weapon is the **ammo in the magazine** over what is left in reserve. Press **{key:brslot1}** to **{key:brslot5}** to switch between them.',
    advance: 'next',
  },
  {
    id: 'game-map',
    target: 'hud-counters',
    title: 'The map',
    body: 'Press **{key:brmap}** to open the full map.',
    advance: 'next',
  },
  {
    id: 'game-map-waypoint',
    // THE ONE CARD IN THE GAME THAT DRAWS OVER THE BIG MAP. See App.tsx: the
    // page normally hides behind every engine screen, and this subtree opts out
    // for the map alone -- owner, 2026-09-04, "allow ONLY this tutorial to shine
    // through".
    target: 'hud-counters',
    title: 'Waypoints',
    body: 'Double click anywhere on the map to drop a **waypoint** — double click on it again to remove it. You will see this marker within the game too. In **squads** waypoints are visible to the whole team.',
    advance: 'next',
  },
  {
    id: 'game-shop',
    target: 'hud-volts',
    title: 'The shop',
    body: 'On the pad you can spend **Volts** on something to take into the match. **One purchase per match**, and it is **not refundable** — so buy it when you know what you want.',
    advance: 'next',
  },
  {
    id: 'game-invpanel',
    target: 'hud-inventory',
    title: 'The full inventory',
    body: 'Press **{key:brinventory}** to open it properly — you can move things between slots and drop what you do not want.',
    advance: 'screen',
    awaitScreen: 'inventory',
    // NO ACTION HERE, AND THE ASYMMETRY IS DELIBERATE. There is no callback that
    // opens the inventory -- the panel is client-side, opened by the key and
    // nothing else -- and inventing one to give this card a way through would be
    // plumbing built for a walkthrough rather than for the game.
    //
    // The escape hatch exists on the PLAYER LIST card because that key is tilde,
    // which a good many layouts do not have. This one is TAB, which every
    // keyboard has and every player can reach. If that ever stops being true the
    // callback is the fix, not a second default.
  },
  {
    id: 'game-ready',
    // THE END OF THE WHOLE THING, both halves. Owner, 2026-09-04: "So, are you
    // ready to start?", and "when they click yes, they're put into whatever
    // match type they selected in the lobby and the warmup timer begins."
    //
    // ANCHORED ON THE MATCH CLOCK, which is the thing the answer starts.
    target: 'hud-counters',
    title: 'That is everything',
    body: 'So — are you ready to start?',
    advance: 'dismiss',
    dismissLabel: "I'm ready",
    // NO BACK BUTTON PAST THE END. Stepping backwards out of the final card is
    // the one move that would let a player re-dismiss it, and the reward is
    // idempotent at the database rather than here -- so the second press would
    // cost them nothing and teach them the button is broken.
    noBack: true,
  },
]
