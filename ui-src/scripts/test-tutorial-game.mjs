#!/usr/bin/env node
/**
 * THE IN-GAME WALKTHROUGH'S PREVIOUS, PICKUP AND MAP CARDS (#405, part 2).
 *
 * Owner, 2026-10-11:
 *   "For the in-game tutorial, step 15 back button doesn't work."
 *   "the 'pick up 2 things' should actually require 2 weapons. If they pickup 1
 *    weapon and 1 item that doesn't take a slot like ammo, then direct them
 *    accordingly."
 *   "In-game step 17 - show them how they can see the storm area and plane
 *    route."
 *
 * Loads src/tutorial/gameSteps.ts and src/tutorial/progress.ts (node's type
 * stripping, as test-tutorial-lock.mjs does) and asks the rules about the real
 * script, so it fails if a step's data is reverted and if a rule is.
 *
 * THE BACK BUTTON IS A CLASS. Every card that offers Previous -- the button or
 * the left arrow -- must land on a card that does not move on by itself. A
 * card whose advance is a thing the player does (switch slots, open a crate,
 * send a chat line, open a screen) was already done on the way through, so
 * landing on it as it was is landing on an advance that is already met.
 *
 * WHAT THIS CANNOT REACH: that TutorialLayer uses these for the button, both
 * arrow paths, the revisit, the pickup advance and the map gate. That is
 * check-ui rule R34.
 *
 * Run: npm run test:tutorialgame   (and as part of npm run build)
 */

import { GAME_STEPS } from '../src/tutorial/gameSteps.ts'
import { LOBBY_STEPS } from '../src/tutorial/steps.ts'
import {
  asRevisited, canGoBack, carried, mapGoneTo, pickupSince, pickupState,
} from '../src/tutorial/progress.ts'

let failed = 0
let ran = 0

function check(label, got, expected) {
  ran++
  const ok = got === expected
  if (!ok) failed++
  console.log(
    ok
      ? `  ok    ${label}`
      : `  FAIL  ${label}\n          got      ${got}\n          expected ${expected}`,
  )
}

const at = (id) => {
  const n = GAME_STEPS.findIndex((s) => s.id === id)
  if (n < 0) throw new Error(`no in-game step '${id}'`)
  return n
}
const step = (id) => GAME_STEPS[at(id)]

// ─── PREVIOUS, CARD BY CARD ─────────────────────────────────────────────────
// The owner's step 15 is "The full inventory". Every card that can go back,
// and none other. The two player-list cards cannot: the card before each is on
// another screen, and the arrows used to ignore that.
console.log('previous')
const BACK = new Set([
  'game-counters', 'game-feed', 'game-squad', 'game-squad-name', 'game-squad-bars',
  'game-notice', 'game-chat', 'game-invpanel', 'game-map',
])
check('"The full inventory" is the owner\'s step 15', at('game-invpanel') + 1, 15)
for (let i = 0; i < GAME_STEPS.length; i++) {
  const id = GAME_STEPS[i].id
  check(`${id}: Previous ${BACK.has(id) ? 'offered' : 'not offered'}`,
    canGoBack(GAME_STEPS, i), BACK.has(id))
}

// ─── ...AND WHERE IT LANDS DOES NOT SEND THEM STRAIGHT BACK ─────────────────
const STILL = new Set(['next', 'click', 'dismiss'])
for (const [name, steps] of [['in game', GAME_STEPS], ['lobby', LOBBY_STEPS]]) {
  for (let i = 0; i < steps.length; i++) {
    if (!canGoBack(steps, i)) continue
    const landed = asRevisited(steps[i - 1])
    check(`${name}: Previous from ${steps[i].id} lands on a card that waits to be read or pressed`,
      STILL.has(landed.advance), true)
  }
}
check('Previous from step 15 lands on "What you are carrying" with a Next',
  asRevisited(step('game-inventory')).advance, 'next')
check('...which keeps its words', asRevisited(step('game-inventory')).body,
  step('game-inventory').body)
check('Previous from "The map" lands on step 15 with a Next, not on TAB again',
  asRevisited(step('game-invpanel')).advance, 'next')
check('a lobby card that wants its control pressed still wants it',
  asRevisited(LOBBY_STEPS.find((s) => s.id === 'mode')).advance, 'click')
check('a card reached going forward is not touched',
  step('game-inventory').advance, 'slotswitch')

// ─── TWO WEAPONS ────────────────────────────────────────────────────────────
console.log('pickup')
const pickup = step('game-pickup')
check('the pickup card wants two weapons', pickup.weapons, 2)
check('its body asks for two weapons, verbatim', pickup.body,
  'Stand over anything on the ground and hold {key:brinteract} to pick it up. **Take two weapons** from the crates. Nothing you pick up in warmup comes with you into the match.')
check('its ammo direction, verbatim', pickup.ammoNote,
  '**Ammo** does not take a slot, so it does not count - grab another **weapon**.')

const gun = (id, pool) => ({ id, kind: 'weapon', count: 1, pool })
const inv = (slots, ammo = {}) => carried({ slots: [...slots, null, null, null, null, null].slice(0, 5), ammo })
const after = (before, now) => pickupState(pickup, pickupSince(before, now))

const empty = inv([], { light: 0, medium: 0, shells: 0 })
{
  const s = after(empty, inv([gun('pistol', 'light')], { light: 24, medium: 0, shells: 0 }))
  check('one gun (and the rounds it lands with): not done', s.done, false)
  check('...and nothing to explain', s.short, false)
}
{
  const s = after(empty, inv([gun('pistol', 'light')], { light: 24, medium: 30, shells: 0 }))
  check('one gun and a box of rounds: not done -- the owner\'s case', s.done, false)
  check('...and the card says why', s.short, true)
}
{
  const s = after(empty, inv([gun('pistol', 'light'), gun('pumpshotgun', 'shells')],
    { light: 24, medium: 0, shells: 8 }))
  check('two guns: done', s.done, true)
  check('...with nothing to explain', s.short, false)
}
{
  const s = after(empty, inv([gun('pistol', 'light'), gun('pistol', 'light')],
    { light: 48, medium: 0, shells: 0 }))
  check('the same gun twice is two weapons: done', s.done, true)
}
{
  const s = after(empty, inv([gun('pistol', 'light'), { id: 'bandage', kind: 'consumable', count: 2 }],
    { light: 24, medium: 0, shells: 0 }))
  check('a gun and a bandage: not done', s.done, false)
  check('...and the bandage took a slot, so no ammo note', s.short, false)
}
{
  const s = after(empty, inv([gun('pistol', 'light'), { id: 'grenade', kind: 'throwable', count: 1 }],
    { light: 24, medium: 0, shells: 0 }))
  check('a gun and a grenade: not done', s.done, false)
}
{
  const before = inv([gun('pistol', 'light')], { light: 24, medium: 0, shells: 0 })
  const s = after(before, inv([gun('pistol', 'light'), gun('smg', 'smg')], { light: 24, medium: 0, shells: 0, smg: 30 }))
  check('a gun carried before the card does not count: one more is not done', s.done, false)
  const t = after(before, inv([gun('pistol', 'light')], { light: 54, medium: 0, shells: 0 }))
  check('a box of rounds for a gun already carried takes no slot: the card says so', t.short, true)
}

// ─── THE STORM AREA AND THE PLANE ROUTE ─────────────────────────────────────
console.log('map')
const storm = step('game-map-storm')
check('the storm and plane card is the owner\'s step 17', at('game-map-storm') + 1, 17)
check('...the first card after the map opens', GAME_STEPS[at('game-map-storm') - 1].advance, 'map')
check('its title, verbatim', storm.title, 'The storm and the plane')
check('its body, verbatim', storm.body,
  'Scroll to zoom out. The **purple circle** is the first safe zone the storm closes in to, and the **blue line** is the route the plane will fly.')
check('it is read, and ends on Next', storm.advance, 'next')
for (const id of ['game-map-storm', 'game-map-waypoint', 'game-map-close']) {
  check(`${id} draws only over the open map`, step(id).overMap, true)
}
check('closing the map on it goes back to "Press M"', mapGoneTo(GAME_STEPS, at('game-map-storm')), at('game-map'))
check('closing it on the waypoint card does not (it waits, with its toast)',
  mapGoneTo(GAME_STEPS, at('game-map-waypoint')), null)
check('closing it on the close card does not (that is its advance)',
  mapGoneTo(GAME_STEPS, at('game-map-close')), null)

if (failed) {
  console.error(`\ntest-tutorial-game: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-tutorial-game: ok, ${ran} checks`)
