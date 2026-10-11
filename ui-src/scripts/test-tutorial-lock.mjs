#!/usr/bin/env node
/**
 * THE LOBBY WALKTHROUGH'S LOCKS (#405).
 *
 * Owner, 2026-10-11: step 2 "disable all buttons except the one we want them to
 * press, and 'Previous'"; step 3 "release only the Settings button"; step 4
 * "lock the Save and Cancel buttons"; "Unlock the save button only after the
 * completion of step 11"; step 13 "lock all buttons except Locker"; step 15
 * "unlock only the market button"; "Lock the Back button during step 17, and
 * unlock it once they've progressed to step 18"; step 19 "all buttons should be
 * unlocked, except ready up".
 *
 * Each of those is DATA on a step in src/tutorial/steps.ts and one rule in
 * src/tutorial/lock.ts reads it. This loads both and asks the rule about the
 * real controls, by the anchors each one actually sits inside -- so it fails if a
 * step's data is reverted and if the rule is.
 *
 * THE STEP NUMBERS ARE THE OWNER'S, which count the cards as they were when he
 * wrote them. The steps are looked up by id, so a card added later (the Market's,
 * in this same round) does not move what a number below means.
 *
 * WHAT THIS CANNOT REACH: that App mounts the lock and main.tsx installs the
 * keyboard guard. That is check-ui rule R29.
 *
 * Run: npm run test:tutoriallock   (and as part of npm run build)
 */

import { LOBBY_STEPS } from '../src/tutorial/steps.ts'
import { holdsEscape, isLocked, lockCss, lockSelector } from '../src/tutorial/lock.ts'

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

/**
 * The lobby's controls, each as the `data-tut` anchors it sits inside, innermost
 * first -- what lockGuard.ts reads off the page. The lobby's own buttons sit in
 * `lobby-menu`; a sub-screen's sit in its Page wrapper, `page-<name>`.
 */
const C = {
  squads:    ['mode-squad', 'mode-picker', 'lobby-menu'],
  solo:      ['mode-solo', 'mode-picker', 'lobby-menu'],
  party:     ['lobby-menu'],
  toggle:    ['tutorial-continue', 'lobby-menu'],
  ready:     ['ready', 'lobby-menu'],
  locker:    ['locker', 'lobby-menu'],
  market:    ['market', 'lobby-menu'],
  help:      ['help', 'lobby-menu'],
  settings:  ['settings', 'lobby-menu'],
  save:      ['settings-save', 'page-settings'],
  cancel:    ['settings-cancel', 'page-settings'],
  uiscale:   ['settings-uiscale', 'page-settings'],
  graphics:  ['settings-display', 'page-settings'],
  tabGen:    ['settings-tab-general', 'settings-tabs', 'page-settings'],
  tabCtl:    ['settings-tab-controls', 'settings-tabs', 'page-settings'],
  tabAcc:    ['settings-tab-accessibility', 'settings-tabs', 'page-settings'],
  lockerRow: ['page-locker'],
  lockerDone:['locker-done', 'page-locker'],
  helpBack:  ['help-back', 'page-help'],
  helpCopy:  ['help-body', 'page-help'],
}
const LOBBY = ['squads', 'solo', 'party', 'toggle', 'ready', 'locker', 'market', 'help', 'settings']

const step = (id) => {
  const s = LOBBY_STEPS.find((x) => x.id === id)
  if (!s) throw new Error(`no lobby step '${id}'`)
  return s
}
const locked = (id, control) => isLocked(step(id), C[control])
/** The lobby's buttons that answer on this card, by name. */
const liveOnLobby = (id) => LOBBY.filter((c) => !locked(id, c)).join(',')

// ── EVERY CARD SAYS WHAT IS LIVE ─────────────────────────────────────────────
for (const s of LOBBY_STEPS) {
  check(`'${s.id}' names its locks (live or locked)`,
    s.live !== undefined || (s.locked ?? []).length > 0, true)
}

// ── THE OWNER'S LIST, CARD BY CARD ───────────────────────────────────────────
check('step 1 (welcome): nothing on the lobby answers -- the option in focus is Next',
  liveOnLobby('welcome'), '')
check('step 2 (mode): only Squads', liveOnLobby('mode'), 'squads')
check('step 3 (settings): only Settings', liveOnLobby('settings'), 'settings')

for (const id of ['settings-uiscale', 'settings-textscale', 'settings-display',
                  'settings-volui', 'settings-voice', 'settings-controls',
                  'settings-controls-body', 'settings-accessibility']) {
  check(`${id}: Save locked`, locked(id, 'save'), true)
  check(`${id}: Cancel locked`, locked(id, 'cancel'), true)
  check(`${id}: the rest of Settings answers`, locked(id, 'uiscale') || locked(id, 'graphics'), false)
}
check('step 9 (open Controls): the Controls tab answers', locked('settings-controls', 'tabCtl'), false)
check('step 9: the other tabs do not', locked('settings-controls', 'tabGen') && locked('settings-controls', 'tabAcc'), true)
check('step 11 (open Accessibility): its tab answers', locked('settings-accessibility', 'tabAcc'), false)
check('step 4: no tab can take the slider off the screen',
  locked('settings-uiscale', 'tabCtl') && locked('settings-uiscale', 'tabAcc'), true)

check('step 12 (after 11 is done): Save answers', locked('settings-done', 'save'), false)
check('step 12: Cancel still does not', locked('settings-done', 'cancel'), true)

check('step 13 (locker): only Locker', liveOnLobby('locker'), 'locker')
check('step 14 (inside the Locker): the whole Locker answers, Done too',
  locked('locker-inside', 'lockerRow') || locked('locker-inside', 'lockerDone'), false)
check('step 15 (market): only Market', liveOnLobby('market'), 'market')
check('inside the Market there is a card, scoped to it, on Done',
  `${step('market-inside').screen}/${step('market-inside').target}/${step('market-inside').advance}`,
  'market/market-done/click')
check('...it follows the Market card directly',
  LOBBY_STEPS.findIndex((x) => x.id === 'market-inside')
    - LOBBY_STEPS.findIndex((x) => x.id === 'market'), 1)
check('...and the whole Market answers under it, Done too',
  isLocked(step('market-inside'), ['market-done', 'page-market'])
    || isLocked(step('market-inside'), ['page-market']), false)
check('...and it holds Escape on the Market', holdsEscape(step('market-inside'), 'market'), true)
check('step 1 has its interactive-demo section', typeof step('welcome').note, 'string')
check('step 2: a hand points at Squads after five seconds or more',
  step('mode').hand >= 5000 && step('mode').target === 'mode-squad', true)
check('...and no other card has one',
  LOBBY_STEPS.filter((x) => x.hand !== undefined).map((x) => x.id).join(','), 'mode')
check('step 16 (help): only Help', liveOnLobby('help'), 'help')
check('step 17 (help-inside): Back locked', locked('help-inside', 'helpBack'), true)
check('step 17: the rest of Help answers', locked('help-inside', 'helpCopy'), false)
check('step 18 (help-back): Back answers', locked('help-back', 'helpBack'), false)
check('step 19 (ready): everything but Ready up',
  liveOnLobby('ready'), 'squads,solo,party,toggle,locker,market,help,settings')

// ── THE RULE ON ITS OWN ──────────────────────────────────────────────────────
check('no spec locks nothing', isLocked(undefined, C.save), false)
check('`locked` wins over `live`',
  isLocked({ live: ['page-settings'], locked: ['settings-save'] }, C.save), true)
check('a step that names neither has no style sheet', lockSelector({}), null)
check('...and no CSS', lockCss({}), '')
check('the sheet names a live anchor and everything inside it',
  lockSelector({ live: ['mode-squad'] }).includes('[data-tut="mode-squad"] *'), true)
check('the sheet reaches the lobby and never the pause menu',
  lockSelector({ live: [] }).includes('[data-layer="lobby"]')
    && !lockSelector({ live: [] }).includes('pause'), true)
check('the sheet is .btn--off\'s look and takes the pointer away',
  /opacity: 0\.4 !important;[\s\S]*pointer-events: none !important;/.test(lockCss({ live: [] })), true)

// ── ESCAPE ───────────────────────────────────────────────────────────────────
check('a card on Settings holds Escape on Settings', holdsEscape(step('settings-display'), 'settings'), true)
check('a card on Help holds Escape on Help (Back is the way out)', holdsEscape(step('help-back'), 'help'), true)
check('the last card does not hold Escape on a screen they opened themselves',
  holdsEscape(step('ready'), 'settings'), false)
check('nor on the pause menu', holdsEscape(step('mode'), 'pause'), false)

if (failed) {
  console.error(`\ntest-tutorial-lock: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-tutorial-lock: ok, ${ran} checks`)
