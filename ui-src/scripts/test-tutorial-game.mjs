#!/usr/bin/env node
/**
 * THE IN-GAME WALKTHROUGH'S PREVIOUS, PICKUP AND MAP CARDS (#405, part 2).
 *
 * Owner, 2026-10-11:
 *   "For the in-game tutorial, step 15 back button doesn't work."
 *   "the 'pick up 2 things' should actually require 2 weapons. If they pickup 1
 *    weapon and 1 item that doesn't take a slot like ammo, then direct them
 *    accordingly."
 *   2026-10-12, after a medkit did not count: "Things like that should satisfy
 *    the requirement. Anything that takes a slot."
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
  asRevisited, boxIn, canGoBack, carried, mapGoneTo, pickupState, slotsSince,
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

// ─── TWO THINGS THAT TAKE A SLOT ────────────────────────────────────────────
console.log('pickup')
const pickup = step('game-pickup')
check('the pickup card wants two slots filled', pickup.slots, 2)
check('its body asks for two things, verbatim', pickup.body,
  'Stand over anything on the ground and hold {key:brinteract} to pick it up. **Take two things** from the crates. Nothing you pick up in warmup comes with you into the match.')
check('its ammo direction, verbatim', pickup.ammoNote,
  '**Ammo** does not take a slot, so it does not count - grab something else.')

const gun = (id, pool) => ({ id, kind: 'weapon', count: 1, pool })
const inv = (slots, ammo = {}) => carried({ slots: [...slots, null, null, null, null, null].slice(0, 5), ammo })
/**
 * THE CARD'S COUNT, AS THE LAYER KEEPS IT: slots against the card's baseline
 * (`slotsSince`), boxes one inventory update at a time (`boxIn` against the
 * update before). Each argument after the first is one push from the server,
 * which sends the whole inventory once per item given (BR.Inv.give).
 */
const run = (start, ...updates) => {
  let last = start
  let boxes = 0
  for (const u of updates) {
    if (boxIn(last, u)) boxes += 1
    last = u
  }
  return pickupState(pickup, { slots: slotsSince(start, last), ammo: boxes })
}

const AMMO0 = { light: 0, medium: 0, shells: 0 }
const empty = inv([], AMMO0)
const pistol = (light, more = {}) => inv([gun('pistol', 'light')], { ...AMMO0, light, ...more })
{
  const s = run(empty, pistol(24))
  check('one gun (and the rounds it lands with): not done', s.done, false)
  check('...and nothing to explain', s.short, false)
  check('a gun landing with its reserve is not a box', boxIn(empty, pistol(24)), false)
}
{
  const s = run(empty, pistol(24), pistol(24, { medium: 30 }))
  check('one gun, then a box of other rounds: not done -- the owner\'s case', s.done, false)
  check('...and the card says why', s.short, true)
}
{
  // #405's review: the box matching the gun was read as the gun's own reserve,
  // because one pool rose and a gun of that pool had arrived since the card
  // opened. One update at a time, they are two pickups.
  const s = run(empty, pistol(24), pistol(54))
  check('one gun, then a box of ITS rounds: not done', s.done, false)
  check('...and the card says why (#405 review)', s.short, true)
  const t = run(empty, inv([], { ...AMMO0, light: 30 }), pistol(54))
  check('the box first, then the gun: the card says why too', t.short, true)
}
{
  const s = run(empty, pistol(24), inv([gun('pistol', 'light'), gun('pumpshotgun', 'shells')],
    { ...AMMO0, light: 24, shells: 8 }))
  check('two guns: done', s.done, true)
  check('...with nothing to explain', s.short, false)
}
{
  const s = run(empty, pistol(24), pistol(54), inv([gun('pistol', 'light'), gun('smg', 'medium')],
    { ...AMMO0, light: 54, medium: 30 }))
  check('a gun, a box and a second gun: done', s.done, true)
  check('...and a finished card has nothing to explain, box or no box', s.short, false)
}
{
  const s = run(empty, pistol(24), inv([gun('pistol', 'light'), gun('pistol', 'light')],
    { ...AMMO0, light: 48 }))
  check('the same gun twice is two slots: done', s.done, true)
  check('...and the second one\'s rounds are its own, not a box', s.short, false)
}
{
  const s = run(empty, inv([gun('pistol', 'light'), { id: 'bandage', kind: 'consumable', count: 2 }],
    { ...AMMO0, light: 24 }))
  check('a gun and a bandage: done -- anything that takes a slot (2026-10-12)', s.done, true)
  check('...with nothing to explain', s.short, false)
}
{
  // The owner's case, 2026-10-12: a box of rounds, then a medkit. The rounds
  // brought the ammo note; the medkit must count and end the card.
  const med = { id: 'medkit', kind: 'consumable', count: 1 }
  const s = run(empty, pistol(24), pistol(54), inv([gun('pistol', 'light'), med], { ...AMMO0, light: 54 }))
  check('a gun, a box of rounds, then a medkit: done (owner, 2026-10-12)', s.done, true)
  check('...and the ammo note is gone', s.short, false)
  const t = run(empty, inv([], { ...AMMO0, light: 30 }), inv([med], { ...AMMO0, light: 30 }))
  check('rounds and one medkit: not done', t.done, false)
  check('...and the card still says why', t.short, true)
}
{
  const s = run(empty, pistol(24), inv([gun('pistol', 'light'), { id: 'grenade', kind: 'throwable', count: 1 }],
    { ...AMMO0, light: 24 }))
  check('a gun and a grenade: done -- a grenade takes a slot', s.done, true)
}
{
  const band = (n) => ({ id: 'bandage', kind: 'consumable', count: n })
  const s = run(inv([band(1)], AMMO0), inv([band(2)], AMMO0))
  check('a second bandage that tops up the first takes no new slot: not done', s.done, false)
  const t = run(empty, inv([band(1)], AMMO0), inv([band(1), { id: 'medkit', kind: 'consumable', count: 1 }], AMMO0))
  check('a bandage and a medkit: done', t.done, true)
}
{
  const before = pistol(24)
  const s = run(before, inv([gun('pistol', 'light'), gun('smg', 'medium')], { ...AMMO0, light: 24, medium: 30 }))
  check('a gun carried before the card does not count: one more is not done', s.done, false)
  const t = run(before, pistol(54))
  check('a box of rounds for a gun already carried takes no slot: the card says so', t.short, true)
  const u = run(before, inv([], { ...AMMO0, light: 24 }), pistol(24))
  check('the carried gun dropped and picked up again is not a new weapon', u.done || u.short, false)
  const v = run(before, inv([], { ...AMMO0, light: 24 }), inv([gun('smg', 'medium')], { ...AMMO0, light: 24, medium: 30 }),
    inv([gun('smg', 'medium'), gun('pumpshotgun', 'shells')], { ...AMMO0, light: 24, medium: 30, shells: 8 }))
  check('the carried gun dropped, then two new ones: done -- a drop takes nothing off', v.done, true)
  const two = inv([gun('pistol', 'light'), gun('pistol', 'light')], { ...AMMO0, light: 48 })
  const w = run(two, pistol(48), inv([gun('pistol', 'light'), gun('smg', 'medium'), gun('pumpshotgun', 'shells')],
    { ...AMMO0, light: 48, medium: 30, shells: 8 }))
  check('...nor does one of two carried pistols dropped', w.done, true)
}

// ─── THE STORM AREA AND THE PLANE ROUTE ─────────────────────────────────────
console.log('map')
const storm = step('game-map-storm')
check('the storm and plane card is the owner\'s step 17', at('game-map-storm') + 1, 17)
check('...the first card after the map opens', GAME_STEPS[at('game-map-storm') - 1].advance, 'map')
check('its title, verbatim', storm.title, 'The storm and the plane')
check('its body, verbatim', storm.body,
  'Scroll to zoom out. The **purple area** is the first safe zone the storm closes in to, and the **blue line** is the route the plane will fly.')
check('it is read, and ends on Next', storm.advance, 'next')
for (const id of ['game-map-storm', 'game-map-waypoint', 'game-map-close']) {
  check(`${id} draws only over the open map`, step(id).overMap, true)
}
check('closing the map on it goes back to "Press M"', mapGoneTo(GAME_STEPS, at('game-map-storm')), at('game-map'))
check('closing it on the waypoint card does not (it waits, with its toast)',
  mapGoneTo(GAME_STEPS, at('game-map-waypoint')), null)
check('closing it on the close card does not (that is its advance)',
  mapGoneTo(GAME_STEPS, at('game-map-close')), null)
check('a card that is not about the map goes nowhere when it closes -- the shop card among them',
  GAME_STEPS.filter((x, n) => x.overMap !== true && mapGoneTo(GAME_STEPS, n) !== null).map((x) => x.id).join(','), '')

if (failed) {
  console.error(`\ntest-tutorial-game: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-tutorial-game: ok, ${ran} checks`)
