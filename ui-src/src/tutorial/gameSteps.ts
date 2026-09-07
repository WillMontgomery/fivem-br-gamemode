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
    body: 'One plate per squadmate, in their own color - the same color as their dot on the radar.',
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
    body: 'Health on top, **shield** underneath. When a mate goes **down** the bars are replaced by a countdown - that is how long you have to reach them before they are out for good.',
    advance: 'next',
  },
  {
    id: 'game-notice',
    // THE STACK ITSELF, not the counters. Owner, 2026-09-06: "Step 7/8 card is
    // not positioned near the notification and is outlining the alive/elims
    // section." It was, because this named the counters as a placeholder.
    target: 'hud-notices',
    title: 'Notifications',
    // The card is about what a notification looks like, so it stages one and
    // holds it until they move on.
    stage: 'notice',
    body: 'Anything the game needs to tell you arrives like this - a squadmate going down, a purchase, a reward. They stack up in the pause menu if you miss one.',
    advance: 'next',
  },
  {
    id: 'game-chat',
    // ═══ THE CHAT SECTION (#261), AND IT STAGES A LINE TO POINT AT ═══
    //
    // Owner, 2026-09-06: "generate a random player name and send a fake message
    // in the chat under that name, then call their attention to the chat and
    // tell them to press {chatkey} to open it."
    //
    // STAGED, for the reason the feed and the squad panel are: a new player's
    // chat log is empty, and a card pointing at a blank corner teaches nothing.
    target: 'hud-chat',
    stage: 'chat',
    title: 'Chat',
    body: 'Messages from other players land here. Press {key:brchat} to say something to everyone, or {key:brchatsquad} to talk to just your squad.',
    // ENDS WHEN CHAT OPENS. The page sees the focus change, which is the same
    // fact one step later and needs no new wire -- the player-list card works
    // the same way.
    advance: 'screen',
    awaitScreen: 'chat',
  },
  {
    id: 'game-chat-send',
    // SCOPED TO THE CHAT SCREEN, and it has to be: the moment chat opens the
    // focus becomes `chat`, and every un-scoped card hides itself.
    target: 'hud-chat',
    screen: 'chat',
    stage: 'chat',
    title: 'Say something',
    // [[Tab]] IS A LITERAL CAP, NOT A BINDING, and that is not a shortcut.
    // There is no change-channel command in this game: keybinds.lua has exactly
    // two chat rows, `brchat` and `brchatsquad`, and the channel is switched by
    // a hardcoded Tab inside the composer and by the ALL/SQUAD button. A
    // {key:...} token would have to name a command that does not exist.
    body: 'Press [[Tab]] to switch between **all** and **squad**, then type anything and press [[Enter]] to send it.',
    advance: 'chatsent',
    noBack: true,
  },
  {
    id: 'game-players',
    // THE ALIVE PLATE ON ITS OWN. "Everybody still playing" is literally what
    // that number is, and ringing one plate rather than the pair is the owner's
    // rule for anything smaller than a whole surface.
    // NO ANCHOR. It named the Alive plate because "everybody still playing" is
    // literally that number -- but the card is about a KEY, and the owner's
    // answer settles it: "step 8 of 18 card should not be outlining the top
    // right panel" (2026-09-07). A card about a keypress has no control on
    // screen to ring.
    //
    place: 'quarter',
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
    // THE WALKTHROUGH CLOSES WHAT IT OPENED. There used to be a card telling
    // them to close the list again -- owner, 2026-09-07: "let's just remove step
    // 10 and close the player list for them and move on." A screen the
    // walkthrough opened is the walkthrough's to close, and a whole card spent
    // on housekeeping is a card spent on nothing.
    onLeave: { cb: 'br/players/focus', data: { open: false } },
    body: 'If a player is **cheating**, or is abusive in voice or chat, press **Report player** and pick them from this list. An admin reads every one, and every correct report is awarded ~100 Volts~.',
    advance: 'next',
  },
  {
    id: 'game-crates',
    // NO ANCHOR, AND THAT IS THE HONEST ANSWER. This card is about four boxes
    // standing on the pad; it used to borrow the inventory, so the ring outlined
    // the slots while the words said "crates" (owner, 2026-09-06: "Step 11
    // shouldn't say 'crates' while outlining inventory"). There is no HUD
    // element for a thing in the world, so it draws centred with no ring, and
    // the four rarity cones over the crates are what points at the subject.
    title: 'Crates',
    body: "There are four practice crates on the pad - look for the marker on your map. These are special crates which refill automatically when you walk away. The **colored beam** over each one shows the rarity of what's inside. **Go and open one.**",
    // NO NEXT BUTTON: the card sends them somewhere, so the only way past it is
    // going (owner, 2026-09-05). The escape hatch after 45s is in TutorialLayer
    // and exists so a miscount cannot trap anybody -- see `stuck`.
    advance: 'crate',
    crates: 1,
    place: 'quarter',
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
    id: 'game-invpanel',
    target: 'hud-inventory',
    title: 'The full inventory',
    body: 'Press **{key:brinventory}** to open it properly - you can move things between slots and drop what you do not want.',
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
    id: 'game-map',
    // THE MINIMAP. A rectangle over the engine's own radar exists for this --
    // see Hud.tsx -- because there is no DOM for a radar the game draws itself,
    // and this card was ringing the Elims/Alive plates instead.
    target: 'hud-minimap',
    title: 'The map',
    body: 'Press {key:brmap} to open the full map.',
    // AND IT ENDS WHEN THE MAP OPENS. It ended on Next before, so the card said
    // "press this" and took anything (owner, 2026-09-06). `map` also removes the
    // Next button for free -- only `next` grants one.
    advance: 'map',
  },
  {
    id: 'game-map-waypoint',
    // THE ONE CARD IN THE GAME THAT DRAWS OVER THE BIG MAP. See App.tsx: the
    // page normally hides behind every engine screen, and this subtree opts out
    // for the map alone -- owner, 2026-09-04, "allow ONLY this tutorial to shine
    // through".
    //
    // NO ANCHOR: the subject is the whole map surface. Every HUD element it
    // could have borrowed is underneath a full-screen scaleform, so a ring would
    // outline a rectangle nobody can see.
    title: 'Waypoints',
    body: 'Double click anywhere on the map to drop a **waypoint** - double click on it again to remove it. You will see this marker within the game too. In **squads** waypoints are visible to the whole team. **Try it yourself now.**',
    // ENDS ON A WAYPOINT ACTUALLY BEING PLACED. Owner, 2026-09-07: "should not
    // have a next/last button but instead encourage them to try it and only
    // proceed after they've placed a waypoint at least once."
    advance: 'waypoint',
    noBack: true,
    place: 'quarter',
  },
  {
    id: 'game-map-close',
    // STILL OVER THE MAP, and it is the card that gets them out of it. The
    // waypoint card ends the moment one is placed, which leaves the player
    // holding an open map with nothing telling them what to do next -- so this
    // is the other half of that gesture rather than an extra step.
    title: 'Nicely done',
    body: 'Great job! Now press [[Esc]] to close the map.',
    advance: 'mapclose',
    noBack: true,
    place: 'quarter',
  },
  {
    id: 'game-shop',
    // NO ANCHOR, AND THIS ONE ENDED THE OWNER'S RUN. It named `hud-volts`, which
    // is mounted only while the player is standing within a few metres of a shop
    // car and never after they have spent -- so on the pad it does not exist,
    // and a card whose anchor is missing for 1.2s abandons the walkthrough:
    // "[tutorial] step \"game-shop\" wants [data-tut=\"hud-volts\"] and nothing on
    // screen has it -- ending the run" (2026-09-06).
    //
    // The card is about a car parked somewhere on the pad, which is a thing in
    // the world like the crates. Centred, no ring.
    title: 'The shop',
    body: 'Items on the pad can be purchased with ~Volts~ and brought into the match with you. **One purchase is allowed per match and it is not refundable.**',
    place: 'quarter',
    // NO WAY BACK FROM HERE. The card before it is the one that closed the map;
    // stepping back would ask the player to close a map that is already closed.
    noBack: true,
    // THE OWNER'S FRAMING OF THE SHOP CAR, surveyed by him (2026-09-07). The
    // camera flies here over 1.5s while this card is up and flies home when it
    // goes; the ped is frozen for the whole of it, because the player cannot see
    // the body their inputs would be moving.
    cam: { x: 4498.79, y: -4503.22, z: 5.45, heading: 14.6 },
    advance: 'next',
  },
  {
    id: 'game-timer',
    // THE END OF THE WHOLE THING, both halves. Owner, 2026-09-04: "So, are you
    // ready to start?", and "when they click yes, they're put into whatever
    // match type they selected in the lobby and the warmup timer begins."
    //
    // ANCHORED ON THE COUNTDOWN, WHICH APPEARS FOR THIS CARD AND NO EARLIER.
    // The server has been holding this match's warmup for the whole walkthrough
    // (BR.Match.tutorialHold) and the page has not drawn the clock at all;
    // reaching this step releases the hold and reveals it together, so the card
    // and its subject arrive on the same frame. Owner, 2026-09-07: "THIS is when
    // matchmaking should take place and the timer appears for the first time on
    // their screen."
    target: 'hud-timer',
    title: 'Tutorial complete',
    body: 'That is the countdown to your flight. When it runs out you drop with everyone else - so use what is left to grab what you want. Good luck out there.',
    advance: 'dismiss',
    // AND IT LEAVES BY ITSELF. Owner, 2026-09-07: "hide the card automatically
    // after 10 seconds." Nothing is left to ask for and the countdown behind it
    // is already running.
    autoDismissMs: 10000,
    dismissLabel: "I'm ready",
    // NO BACK BUTTON PAST THE END. Stepping backwards out of the final card is
    // the one move that would let a player re-dismiss it, and the reward is
    // idempotent at the database rather than here -- so the second press would
    // cost them nothing and teach them the button is broken.
    noBack: true,
  },
]
