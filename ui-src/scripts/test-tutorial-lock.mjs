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
 * IT ALSO RUNS THE KEYBOARD'S HALF (#405's review): lockGuard.ts itself, loaded
 * with the store swapped for a stand-in and driven with events on a stand-in
 * page -- and it walks every state the Settings cards can reach, so Previous
 * can never land on a card whose control is on another tab.
 *
 * WHAT THIS CANNOT REACH: that App mounts the lock and main.tsx installs the
 * keyboard guard (check-ui rule R29), and that every screen a lock reaches asks
 * before it closes on Escape (R35).
 *
 * Run: npm run test:tutoriallock   (and as part of npm run build)
 */

import { existsSync, readFileSync } from 'node:fs'
import { registerHooks } from 'node:module'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

import { LOBBY_STEPS, LOBBY_WAYS_BACK } from '../src/tutorial/steps.ts'
import { holdsEscape, isLocked, lockCss, lockSelector } from '../src/tutorial/lock.ts'
import { AWAY_ATTR, asRevisited, canGoBack, targetMissing } from '../src/tutorial/progress.ts'

const SRC = join(dirname(fileURLToPath(import.meta.url)), '..', 'src')

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
check('step 2: a hand points at Squads at five seconds -- "5+ seconds", and no later',
  step('mode').hand === 5000 && step('mode').target === 'mode-squad', true)
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
check('...even while a card waits on Settings under it', holdsEscape(step('settings-display'), 'pause'), false)
check('Escape mid-walkthrough opens the pause menu, and its way back is Back to lobby',
  LOBBY_WAYS_BACK.pause, 'pause-back')
check('...which no card can lock: no card\'s sheet reaches the pause menu',
  LOBBY_STEPS.some((x) => (lockSelector(x) ?? '').includes('pause')), false)

// ── PREVIOUS NEVER LANDS ON A CARD WHOSE CONTROL IS OFF THE SCREEN ───────────
//
// #405's review: card 12 is the first card on the Accessibility tab and had a
// Previous; Previous twice from it landed on card 10 over Accessibility, with
// the Controls tab locked and card 10's control nowhere -- and the run ended
// 1.2 seconds later (`missing`). A CLASS, so this walks it rather than naming
// the one route: every state the Settings cards can reach -- Next, the card's
// own press, Previous, and any tab the card leaves live -- with the REAL locks
// (lock.ts), the REAL Previous (progress.ts), and which control renders on which
// tab read out of screens/Settings.tsx itself. In every one of them, the card's
// control has to be on screen.
console.log('previous, across Settings\' tabs')
{
  const src = readFileSync(join(SRC, 'screens', 'Settings.tsx'), 'utf8')
  // The tab bodies, in source order: `{tab === 'x' && (` up to the next one,
  // and the last up to the footer (Save). Anchors outside every body render on
  // every tab -- the tabs themselves, Save and Cancel.
  const marks = [...src.matchAll(/\{tab === '(\w+)' && \(/g)].map((m) => ({ tab: m[1], at: m.index }))
  const footer = src.indexOf('data-tut="settings-save"')
  const anchorsIn = (from, to) =>
    [...src.slice(from, to).matchAll(/\b(?:data-tut|tut)="([\w-]+)"/g)].map((m) => m[1])
  const onTab = new Map()
  marks.forEach((m, k) => {
    for (const a of anchorsIn(m.at, k + 1 < marks.length ? marks[k + 1].at : footer)) onTab.set(a, m.tab)
  })
  const tabs = marks.map((m) => m.tab)
  check('Settings.tsx: three tab bodies, then the footer', `${tabs.join(',')}|${footer > (marks.at(-1)?.at ?? Infinity)}`,
    'general,accessibility,controls|true')
  check('...and the controls the cards name are where the cards say',
    ['settings-uiscale', 'settings-voice', 'settings-controls-body'].map((a) => onTab.get(a)).join(','),
    'general,general,controls')
  const rendered = (anchor, tab) => !onTab.has(anchor) || onTab.get(anchor) === tab
  const tabAnchors = (t) => [`settings-tab-${t}`, 'settings-tabs', 'page-settings']

  const first = LOBBY_STEPS.findIndex((s) => s.screen === 'settings')
  const seen = new Set()
  const bad = []
  const queue = [[first, 'general', false]]
  while (queue.length > 0) {
    const [i, tab, back] = queue.shift()
    const key = `${i}|${tab}|${back}`
    if (seen.has(key)) continue
    seen.add(key)
    const scripted = LOBBY_STEPS[i]
    if (scripted?.screen !== 'settings') continue
    const s = back ? asRevisited(scripted) : scripted
    if (s.target !== undefined && !rendered(s.target, tab)) bad.push(`${s.id} over ${tab}`)
    if (s.advance === 'next') queue.push([i + 1, tab, false])
    if (s.advance === 'click') {
      const opens = /^settings-tab-(\w+)$/.exec(s.target ?? '')
      queue.push([i + 1, opens ? opens[1] : tab, false])
    }
    if (canGoBack(LOBBY_STEPS, i)) queue.push([i - 1, tab, true])
    // ANY OTHER TAB THE CARD LEAVES LIVE. The tab a `click` card points at is
    // its press, above, which moves the card on as it opens.
    for (const t of tabs) {
      const press = s.advance === 'click' && s.target === `settings-tab-${t}`
      if (t !== tab && !press && !isLocked(s, tabAnchors(t))) queue.push([i, t, back])
    }
  }
  check('no state the Settings cards can reach has a card whose control is off the screen',
    [...new Set(bad)].join('; '), '')
  check('...and the walk saw every Settings card',
    new Set([...seen].map((k) => k.split('|')[0]).filter((n) => LOBBY_STEPS[n]?.screen === 'settings')).size,
    LOBBY_STEPS.filter((s) => s.screen === 'settings').length)
  const at = (id) => LOBBY_STEPS.findIndex((s) => s.id === id)
  check('the first card on Controls has no Previous', canGoBack(LOBBY_STEPS, at('settings-controls-body')), false)
  check('the first card on Accessibility has no Previous', canGoBack(LOBBY_STEPS, at('settings-done')), false)
  check('a card on the same tab as the one before it keeps Previous',
    canGoBack(LOBBY_STEPS, at('settings-accessibility')) && canGoBack(LOBBY_STEPS, at('settings-textscale')), true)
}

// ── THE KEYBOARD'S HALF, RUN: lockGuard.ts against a stand-in page ──────────
//
// #405's review: four mutations of the keyboard's half -- the guard reaching the
// pause menu, no blur on focus, Enter missing from the keys, no blur when the
// card moves on -- survived every suite, because nothing ran that code. This
// loads the REAL lockGuard.ts, with the store swapped for a stand-in and a page
// of stand-in elements, and drives it with events.
//
// And the review's second finding: the guard held Escape for a walkthrough
// screen by stopping it outright, so a Controls row the card says to click could
// not be canceled. A listener added after the guard must hear Escape.
console.log('the keyboard')
{
  const store = {
    state: { tutorialRun: false, tutorialHeading: null, focus: 'lobby', locker2: { on: false } },
    subs: [],
    set(p) {
      const prev = store.state
      store.state = { ...prev, ...p }
      for (const f of store.subs) f(store.state, prev)
    },
  }
  globalThis.__tutLockStore = store
  registerHooks({
    resolve(spec, ctx, next) {
      if (spec === '../store' && ctx.parentURL?.includes('/src/tutorial/')) {
        return { url: 'tutlock:store', shortCircuit: true }
      }
      if (spec.startsWith('.') && ctx.parentURL?.includes('/src/') && !/\.[cm]?[jt]sx?$/.test(spec)) {
        const u = new URL(`${spec}.ts`, ctx.parentURL)
        if (existsSync(fileURLToPath(u))) return { url: u.href, shortCircuit: true }
      }
      return next(spec, ctx)
    },
    load(url, ctx, next) {
      if (url === 'tutlock:store') {
        return {
          format: 'module',
          shortCircuit: true,
          source: 'const s = globalThis.__tutLockStore\n'
            + 'export const useUi = { getState: () => s.state, subscribe: (f) => { s.subs.push(f); return () => {} } }\n',
        }
      }
      return next(url, ctx)
    },
  })

  // A STAND-IN PAGE. `matches` knows the selector shapes lock.ts uses -- a tag,
  // attribute tests, comma lists -- and throws on anything else, so a new shape
  // in CONTROLS or LOCK_SURFACES is a failure here rather than a silent miss.
  const blurred = []
  class El {
    constructor(tag, attrs = {}, kids = []) {
      this.tag = tag
      this.attrs = attrs
      this.parentElement = null
      for (const k of kids) k.parentElement = this
    }
    getAttribute(n) { return this.attrs[n] ?? null }
    matches(sel) {
      return sel.split(',').some((part) => {
        const m = /^([a-z]+)?((?:\[[\w-]+(?:="[^"]*")?\])*)$/.exec(part.trim())
        if (!m) throw new Error(`stand-in page cannot match '${part.trim()}'`)
        if (m[1] && m[1] !== this.tag) return false
        return [...m[2].matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)]
          .every(([, n, v]) => (v === undefined ? n in this.attrs : this.attrs[n] === v))
      })
    }
    closest(sel) {
      for (let e = this; e !== null; e = e.parentElement) if (e.matches(sel)) return e
      return null
    }
  }
  class HEl extends El {
    blur() {
      blurred.push(this)
      if (globalThis.document.activeElement === this) globalThis.document.activeElement = page
    }
  }
  globalThis.Element = El
  globalThis.HTMLElement = HEl
  const btn = () => new HEl('button')
  const tut = (name, kid, tag = 'span') => new HEl(tag, { 'data-tut': name }, [kid])
  const squads = btn(); const ready = btn(); const settingsBtn = btn()
  const save = btn(); const slider = new HEl('input', { type: 'range' }); const row = btn()
  const pauseBack = btn()
  const page = new HEl('body', {}, [
    new HEl('div', { 'data-layer': 'lobby' }, [
      new HEl('div', { 'data-tut': 'lobby-menu' }, [
        tut('mode-picker', tut('mode-squad', squads, 'div'), 'div'),
        tut('ready', ready), tut('settings', settingsBtn, 'div'),
      ]),
    ]),
    new HEl('div', { 'data-page': 'settings', 'data-tut': 'page-settings' }, [
      tut('settings-save', save), tut('settings-uiscale', slider, 'div'),
      tut('settings-controls-body', row, 'section'),
    ]),
    new HEl('div', { 'data-page': 'pause', 'data-tut': 'page-pause' }, [tut('pause-back', pauseBack)]),
  ])
  globalThis.document = { activeElement: page }

  const listeners = []
  globalThis.window = { addEventListener: (type, fn) => listeners.push({ type, fn }) }
  const fire = (type, init) => {
    const ev = {
      type, ...init, prevented: false, stopped: false,
      preventDefault() { this.prevented = true },
      stopImmediatePropagation() { this.stopped = true },
      stopPropagation() {},
    }
    for (const l of [...listeners]) {
      if (l.type !== type) continue
      l.fn(ev)
      if (ev.stopped) break
    }
    return ev
  }
  const key = (k, on) => { globalThis.document.activeElement = on; return fire('keydown', { key: k }) }
  const focusOn = (el) => {
    blurred.length = 0
    globalThis.document.activeElement = el
    fire('focusin', { target: el })
    return blurred.includes(el)
  }

  const G = await import('../src/tutorial/lockGuard.ts')
  G.installLockGuard()

  // What a screen does with Escape: Settings closes on it (asking first, #405),
  // and a Controls row that is listening cancels on it. Both added AFTER the
  // guard, as every screen's are.
  let closed = false
  let listening = false
  window.addEventListener('keydown', (e) => {
    if (e.key !== 'Escape') return
    if (typeof G.escapeHeld === 'function' && G.escapeHeld()) return
    closed = true
  })
  window.addEventListener('keydown', (e) => { if (listening && e.key === 'Escape') listening = false })

  check('no walkthrough: Enter on Ready up goes through', key('Enter', ready).stopped, false)
  check('no walkthrough: nothing loses focus', focusOn(ready), false)

  store.set({ tutorialRun: true, tutorialHeading: 'mode', focus: 'lobby' })
  for (const k of ['Enter', ' ', 'ArrowRight', 'Home']) {
    const ev = key(k, ready)
    check(`step 2: '${k}' on a focused, locked Ready up is stopped`, ev.stopped && ev.prevented, true)
  }
  check('step 2: Enter on Squads, the live control, goes through', key('Enter', squads).stopped, false)
  check('step 2: Tab onto Ready up loses it at once', focusOn(ready), true)
  check('step 2: Squads keeps focus', focusOn(squads), false)
  check('the pause menu is no lock\'s: Back to lobby keeps focus', focusOn(pauseBack), false)
  check('...and Enter presses it', key('Enter', pauseBack).stopped, false)
  check('Tab itself is never stopped', key('Tab', ready).stopped, false)

  blurred.length = 0
  globalThis.document.activeElement = squads
  store.set({ tutorialHeading: 'settings' })
  check('the card moves on: the Squads just pressed is let go', blurred.includes(squads), true)
  blurred.length = 0
  globalThis.document.activeElement = settingsBtn
  store.set({ tutorialHeading: 'settings-uiscale', focus: 'settings' })
  check('...and Settings, the moment its screen is up', blurred.includes(settingsBtn), true)
  blurred.length = 0
  globalThis.document.activeElement = slider
  store.set({ tutorialHeading: 'settings-textscale' })
  check('...but not a control the next card leaves live', blurred.includes(slider), false)
  check('step 4: Save is locked to the keyboard', key('Enter', save).stopped, true)
  check('step 4: the slider answers its arrows', key('ArrowRight', slider).stopped, false)

  store.set({ tutorialHeading: 'settings-controls-body' })
  check('a card on Settings holds the screen open', typeof G.escapeHeld === 'function' && G.escapeHeld(), true)
  listening = true
  closed = false
  const esc = key('Escape', row)
  check('Escape is not stopped by the guard', esc.stopped, false)
  check('...so a listening Controls row hears it and cancels (#405 review)', listening, false)
  check('...and Settings does not close under the card', closed, false)

  // THE LOCKER CARD. Season 2's Locker asks, so its dialogs still close on
  // Escape; Season 1's is frozen byte-for-byte (#28) and cannot ask, so the
  // guard holds the key for it -- its only use of Escape is closing.
  store.set({ tutorialHeading: 'locker-inside', focus: 'locker', locker2: { on: true } })
  check('Season 2\'s Locker: Escape reaches it (a dialog closes on it)', key('Escape', page).stopped, false)
  check('...and it is asked to stay open', G.escapeHeld?.(), true)
  store.set({ locker2: { on: false } })
  const s1 = key('Escape', page)
  check('Season 1\'s Locker, which cannot ask: the guard holds Escape for it', s1.stopped && s1.prevented, true)
  store.set({ tutorialHeading: 'ready' })
  check('...and only while a card waits on it', key('Escape', page).stopped, false)
  store.set({ tutorialHeading: 'settings-controls-body', focus: 'settings' })
  check('no other screen has Escape taken by the guard', key('Escape', row).stopped, false)

  store.set({ focus: 'pause' })
  check('the pause menu is never held', G.escapeHeld?.(), false)
  store.set({ tutorialHeading: 'ready', focus: 'settings' })
  check('Settings opened from the last card is not held', G.escapeHeld?.(), false)
  store.set({ tutorialRun: false, tutorialHeading: null })
  check('no walkthrough, nothing held', G.escapeHeld?.(), false)
}

// ── A CONTROL THAT IS AWAY IS NOT MISSING (#28 review) ───────────────────────
// The Locker card's ring is on Done, which Season 2's Locker draws on My Looks
// only; inside a look the way out is Back, and a press on Back must not end the
// card. So inside, the Locker says Done is away, and the card waits for it
// rather than ending the run as "missing" (test-lockerv2.mjs renders the
// Locker's half: the ring on Done alone, the away mark in every other view).
{
  const card = step('locker-inside')
  check('the Locker card waits on Done', `${card.target}/${card.advance}`, 'locker-done/click')
  check('a control that is simply not there is missing (the run ends, loudly)',
    targetMissing(card, false, false, false), true)
  check('...not while it is on screen', targetMissing(card, true, false, false), false)
  check('...not while its screen is not up', targetMissing(card, false, true, false), false)
  check('...and not while the screen says it is away', targetMissing(card, false, false, true), false)
  check('a card with no control is never missing', targetMissing({ target: undefined }, false, false, false), false)
  check('the mark is data-tut-away', AWAY_ATTR, 'data-tut-away')
  const layer = readFileSync(join(SRC, 'tutorial', 'TutorialLayer.tsx'), 'utf8').replace(/\r\n/g, '\n')
  check('the layer asks targetMissing, with what it measured and the away mark',
    /const missing = targetMissing\(step, rect !== null, waitingForScreen, away\)/.test(layer)
    && layer.includes('document.querySelector(`[${AWAY_ATTR}~="${step.target}"]`) !== null')
    && /if \(rectRef\.current === null && !awayRef\.current\) \{/.test(layer), true)
}

if (failed) {
  console.error(`\ntest-tutorial-lock: ${failed} of ${ran} failed`)
  process.exit(1)
}
console.log(`test-tutorial-lock: ok, ${ran} checks`)
