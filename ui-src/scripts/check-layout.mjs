#!/usr/bin/env node
/**
 * EVERY BORDER DRAWN WHOLE, EVERY LABEL ON ONE LINE: the interface measured in
 * a real browser, at the game's window sizes and the player's text sizes.
 *
 * Owner, 2026-10-14, over a Market card whose right border its scrolling grid
 * cut off: "please put in some change to ensure the borders always draw
 * around everything which should have a border. this happens on other pages
 * too, including locker v2." And: "text wrapping should not be allowed. if
 * you can't fit the text, don't draw it."
 *
 * Neither is visible to a unit test or to a read of the source -- a border is
 * cut by an ancestor three files away, at one size in four -- so this opens
 * the page the browser mock draws (scripts/lib/headless.mjs: a build of src/
 * with the mock in it, served to headless Edge or Chrome), puts up every
 * screen in SCREENS below the way Lua would (scripts/lib/layout-driver.js),
 * and measures it (scripts/lib/layout-probe.js) at
 *
 *   SIZES   1280x720, 1920x1080, 2560x1440 and 3840x2160 -- the root font is
 *           clamped (index.css), so each is its own layout, not a zoom;
 *   TEXT    the Text size slider's ends and its default: 90%, 100%, 115%.
 *
 * TWO RULES, both failing the build:
 *
 *   EDGE  an element with a visible border, outline or ring whose drawn box an
 *         ancestor cuts -- overflow hidden/auto/scroll/clip, paint
 *         containment or clip-path -- or the screen does, by any amount over
 *         half a pixel. A scroll region is measured along its scroll as what
 *         scrolling can reach, so a card below the fold is not cut and one
 *         against the region's edge is.
 *   LINE  a single-line label -- any text not marked as prose -- that wraps,
 *         ends in an ellipsis, or is cut. Prose opts in: `data-wrap` on it or
 *         an ancestor, or the `.body-text` class. A `<br>` is a line the
 *         author wrote and is not a wrap. A label that cannot fit is hidden by
 *         `.fit` (ui/Fit.tsx) and listed, never failed: that is the rule.
 *
 * Each failure names its screen, the sizes it fails at, the element's path and
 * the pixels cut. A NEW SCREEN OPTS IN by adding a row to SCREENS: a name and
 * the steps that put it up, through `__br` (the driver's emit, click, lobby,
 * match...). Its prose opts out of LINE with `data-wrap`.
 *
 * WHAT MAKES IT TRUSTWORTHY. It checks its own eyes first (selfCheck: a
 * planted 1 px cut and an unmarked wrap must fail, prose must not, and a real
 * button squeezed past its label must hide it). Every screen is measured from
 * a fresh page with the text size already set, so nothing is an artifact of a
 * change mid-screen unless a row asks for one. And the browser runs CSS zoom on
 * CEF 103's rule, not Chromium 128's (scripts/lib/headless.mjs), because Locker
 * v2's Cloudscape island is zoomed and measures its menus inside the zoom.
 *
 * WHAT IT CANNOT SEE: pseudo-elements (the plate's chamfers are inside its own
 * box, so a cut plate is caught by its border), a glyph's ink above or below
 * its line (a label is measured across, at its ends), and what overlaps what.
 *
 *   node scripts/check-layout.mjs              every screen, every size
 *   ... --only=market --size=1280x720 --text=1 one corner of it
 *   ... --shots=<dir>                          and a screenshot of each
 *   ... --jobs=N                               N browser windows (cores - 2)
 *   ... --dist=<dir>                           a mock build already made
 *
 * Run: npm run check:layout   (and as part of npm run build)
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { availableParallelism } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildMock, launch, serve } from './lib/headless.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const uiRoot = resolve(here, '..')
const PROBE = readFileSync(join(here, 'lib', 'layout-probe.js'), 'utf8')
const DRIVER = readFileSync(join(here, 'lib', 'layout-driver.js'), 'utf8')

export const SIZES = [[1280, 720], [1920, 1080], [2560, 1440], [3840, 2160]]
/** br_ui/client/settings.lua's RANGE.textScale, and its default. */
export const TEXT = [0.9, 1, 1.15]

const lobby = (o = '') => `__br.lobby(${o})`
const press = (label) => `__br.click('button', ${JSON.stringify(label)})`
const focus = (screen, extra = '') => `__br.emit('focus', { screen: '${screen}'${extra} })`
const wait = (text, within = 'body', ms = 6000) =>
  `await __br.until(() => __br.has(${JSON.stringify(text)}, ${JSON.stringify(within)}), ${ms}, ${JSON.stringify(text)})`
const L2 = '[data-page=locker]'

/** A Market tab with more than the grid can show, so it scrolls. */
const BIG_MARKET = `__br.emit('market', { balance: 7450, items: Array.from({ length: 22 }, (_, i) => ({
  id: 'chute_' + i, name: ['Midnight', 'Sunburst', 'Quillon Longest Canopy Name', 'Ash'][i % 4], sub: 'Canopy',
  kind: 'chute', price: 400 + i * 350, rarity: (i % 5) + 1, owned: i % 6 === 1, equipped: i === 0,
  ...(i === 5 ? { locked: true, season: 'Season 1' } : {}) })) })`

const PLAYERS = `__br.emit('players', { players: [
  { id: '1', name: 'You', state: 'alive', left: false, you: true },
  { id: '2', name: 'Kestrel', state: 'alive', left: false },
  { id: '3', name: 'Quillon_the_Longest_Name', state: 'dead', left: false },
  { id: '4', name: 'Vandal', state: 'dbno', left: false },
  { id: '5', name: 'Rook', state: 'alive', left: true }],
  categories: [{ id: 'cheat', label: 'Cheating', default: true }, { id: 'abuse', label: 'Abusive chat' },
    { id: 'grief', label: 'Griefing teammates' }],
  defaultCategory: 'cheat', maxTargets: 3 })`

/** The warmup pad: a match forming, this player on the ground in it. */
const WARMUP = `__br.emit('state', { state: 'warmup', mode: 'squad', endsAt: Date.now() + 45000, serverNow: Date.now(), participant: true });
  __br.emit('hud', { hp: 100, armour: 0, alive: 24, squadsAlive: 8, kills: 0, state: 'warmup' }) /* wire names: spelling-ok */`

/** Four kills in the feed, the longest name the harness has among them. */
const FEED = `for (let i = 1; i <= 4; i++) __br.emit('feed', { id: i, killer: i % 2 ? 'Quillon_the_Longest_Name' : 'Kestrel',
  victim: 'Vandal', weapon: 'Carbine Rifle', headshot: i === 2, mine: i === 3 })`

/** The keybinds the mock sends, with rebinding available (`raw`). */
const RAW_KEYS = `__br.emit('keybinds', { actions: window.brStore.getState().keybinds, raw: true })`

/** Locker v2 open on its saved peds, once its mock has sent them. */
const L2_OPEN = ['await __br.lockerV2()', wait('Nightshift', L2)]
const L2_PICK = [...L2_OPEN, `__br.clickText('Nightshift', '${L2}')`]
const L2_MALE = [...L2_OPEN, press('Custom (male)'), wait('Skin tone', L2)]
const L2_DIRTY = [...L2_MALE, `__br.click('${L2} button[aria-label="Next"]')`]

/**
 * EVERY SCREEN THE MOCK CAN SHOW. `steps` run in order in the page, each
 * followed by the page settling; a `{ probe }` step measures there and then,
 * a `{ walk }` step measures every card of a walkthrough as it moves it on,
 * and the end of the steps always measures. `query` is added to the page's
 * address (`season=1` puts the mock on Season 1's locker).
 */
export const SCREENS = [
  // ── THE HUD, in a match ────────────────────────────────────────────────
  { name: 'hud', steps: ['__br.match()'] },
  {
    // Names as long as a platform name runs, in the squad panel.
    name: 'hud/long-names', steps: ['__br.match()', `__br.emit('squad', { id: 'sq_1', you: 1, members: [
      { src: 1, name: 'Quillon_the_Longest_Name', state: 'alive', hp: 82, armour: 45, colour: '#6EE7F9', level: 42 }, // wire names: spelling-ok
      { src: 2, name: 'Marrow_of_the_Long_Night', state: 'dbno', hp: 12, armour: 0, colour: '#2DD4BF', bleedEndsAt: Date.now() + 40000, level: 100 }, // wire names: spelling-ok
      { src: 3, name: 'Vandal_Who_Never_Stops', state: 'dead', hp: 0, armour: 0, colour: '#FBBF24', reviveKey: true }] }) /* wire names: spelling-ok */`],
  },
  { name: 'hud/vehicle', steps: ['__br.match()', `__br.emit('vehicle', { show: true, health: 64, fuel: 38, boost: 80 })`] },
  { name: 'hud/vehicle-passenger', steps: ['__br.match()', `__br.emit('vehicle', { show: true, fuel: 38 })`] },
  {
    name: 'hud/storm-outside', steps: ['__br.match()',
      `__br.emit('storm', { phase: 5, phaseState: 'shrinking', endsAt: Date.now() + 30000, radius: 300, edgeDistance: 140, bearing: 90, dps: 12 })`],
  },
  {
    name: 'hud/spectating', steps: ['__br.match({ state: "dead", hp: 0, armour: 0 })', // wire names: spelling-ok
      `__br.emit('spectate', { active: true, admin: false, name: 'Quillon_the_Longest_Name' })`],
  },
  { name: 'hud/death', steps: ['__br.match()', `__br.emit('death', { show: true, byPlayer: false, cause: 'storm' })`] },
  {
    name: 'hud/downed', steps: ['__br.match({ state: "dbno", hp: 12 })',
      `__br.emit('dbno', { downed: true, bleedEndsAt: Date.now() + 40000, reviverName: 'Quillon_the_Longest_Name', revivePct: 40 })`],
  },
  {
    name: 'hud/ambulance', steps: ['__br.match({ state: "dbno", hp: 12 })',
      `__br.emit('dbno', { downed: true, bleedEndsAt: Date.now() + 40000, reviverName: null, revivePct: 0, riding: true, rideEndsAt: Date.now() + 30000 })`],
  },
  {
    name: 'hud/voice', steps: ['__br.match()',
      `__br.emit('voice', { talking: [4, 2, 3, 9, 11, 12, 13], names: ['Nyx', 'Kestrel', 'Vandal', 'Halcyon', 'Rook', 'Marrow', 'Quillon_the_Longest_Name'] })`],
  },
  {
    name: 'hud/voice-notice', steps: ['__br.match()',
      `__br.emit('voice', { talking: [], names: [], mode: 'squad', radio: null, joined: 0, mates: 0, status: 'nosquad', silent: true, chosen: false, headline: 'Squad voice: you have no squad', detail: 'Squad voice carries your squad and nobody else.' })`],
  },
  {
    name: 'hud/notices', steps: ['__br.match()',
      `__br.emit('toast', { text: 'Storm closing in 30 seconds', tone: 'warn', ms: 60000 })`,
      `__br.emit('toast', { text: 'Quillon_the_Longest_Name picked up your key', tone: 'success', ms: 60000 })`,
      `__br.emit('impacts', { list: [{ key: 'scan', text: 'Your position is being scanned', endsAt: Date.now() + 30000 }, { key: 'emp', text: 'Your radar is jammed', tail: 'until the storm moves' }] })`],
  },
  {
    // The Text size slider moved with notices up, from Settings mid-match.
    name: 'hud/notices-rescaled', steps: ['__br.match()',
      `__br.emit('toast', { text: 'Storm closing in 30 seconds', tone: 'warn', ms: 60000 })`,
      `__br.emit('settings', { ...__br.SETTINGS, textScale: 1.15 })`],
  },
  { name: 'hud/chat', steps: ['__br.match()', focus('chat', ", channel: 'squad'")] },
  { name: 'hud/inventory', steps: ['__br.match()', focus('inventory')] },
  {
    name: 'hud/feed', steps: ['__br.match()', FEED,
      `__br.emit('hit', { amount: 40, headshot: true, killed: true, name: 'Quillon_the_Longest_Name' })`],
  },
  {
    name: 'hud/yubikey', steps: ['__br.match()',
      `__br.emit('yubikeycard', { show: true, title: 'You found a key', subtitle: 'A YubiKey', text: 'Take it to a terminal to use it.', dismiss: 'Press Enter to close' })`],
  },
  {
    name: 'hud/warmup', steps: [WARMUP, `__br.emit('shopplate', { show: true })`],
  },
  { name: 'players', steps: ['__br.match()', PLAYERS, focus('players')] },
  { name: 'players/report', steps: ['__br.match()', PLAYERS, focus('players'), press('Report player')] },
  {
    name: 'hud/end-won', steps: ['__br.match()',
      `__br.emit('state', { state: 'ended', mode: 'squad', endsAt: Date.now() + 10000, serverNow: Date.now(), participant: true })`,
      `__br.emit('summary', { placement: 1, total: 48, kills: 7, won: true })`],
  },
  {
    name: 'hud/end-lost', steps: ['__br.match()',
      `__br.emit('state', { state: 'ended', mode: 'squad', endsAt: Date.now() + 10000, serverNow: Date.now(), participant: true })`,
      `__br.emit('summary', { placement: 17, total: 48, kills: 2, won: false, cause: 'storm', byPlayer: false })`],
  },
  { name: 'hud/leaving', steps: ['__br.match()', `__br.emit('leaving', { show: true, kind: 'lobby' })`] },

  // ── THE LOBBY and what opens from it ───────────────────────────────────
  { name: 'lobby', steps: [lobby()] },
  { name: 'lobby/squad-random', steps: [lobby(), `__br.click('[data-tut=mode-squad]')`] },
  { name: 'lobby/squad-create', steps: [lobby(), `__br.click('[data-tut=mode-squad]')`, press('create')] },
  {
    name: 'lobby/squad-picked', steps: [lobby(), `__br.click('[data-tut=mode-squad]')`, press('create'),
      `__br.clickText('Kestrel', '[data-tut=lobby-menu]')`, `__br.clickText('Quillon_the_Longest_Name', '[data-tut=lobby-menu]')`],
  },
  {
    // A control in a scroll region with the keyboard's focus ring on it.
    name: 'lobby/squad-create-focused', steps: [lobby(), `__br.click('[data-tut=mode-squad]')`, press('create'),
      `document.querySelector('[data-tut=lobby-menu] .thin-scroll button').focus()`],
  },
  { name: 'lobby/squad-join', steps: [lobby(), `__br.click('[data-tut=mode-squad]')`, press('join')] },
  { name: 'lobby/party', steps: [lobby('{ mode: "squad", party: true }')] },
  {
    name: 'lobby/invite', steps: [lobby('{ mode: "squad" }'),
      `__br.emit('invite', { partyId: 'p_9', kind: 'invite', from: 5, name: 'Quillon_the_Longest_Name', size: 3, max: 4 })`],
  },
  { name: 'lobby/searching', steps: [lobby(), `__br.click('[data-tut=ready] button')`] },
  {
    name: 'lobby/match-running', steps: [lobby(),
      `__br.emit('state', { state: 'playing', mode: 'solo', endsAt: Date.now() + 60000, serverNow: Date.now(), participant: false })`],
  },
  { name: 'lobby/tutorial-offer', steps: [lobby(), `__br.emit('tutorial', { run: false, offer: true, offerable: true })`] },

  { name: 'market/canopies', steps: [lobby(), focus('market')] },
  { name: 'market/canopies-full', steps: [lobby(), BIG_MARKET, focus('market')] },
  { name: 'market/trails', steps: [lobby(), focus('market'), press('Trails')] },
  { name: 'market/finishes', steps: [lobby(), focus('market'), press('Finishes')] },
  { name: 'market/characters', steps: [lobby(), focus('market'), press('Characters')] },
  { name: 'market/banners', steps: [lobby(), focus('market'), press('Banners')] },
  { name: 'market/emotes', steps: [lobby(), focus('market'), press('Emotes')] },
  { name: 'market/emotes-swap', steps: [lobby(), focus('market'), press('Emotes'), press('Equip')] },

  { name: 'settings/general', steps: [lobby(), focus('settings')] },
  {
    name: 'settings/general-focused', steps: [lobby(), focus('settings'),
      `document.querySelector('[data-page=settings] .pane button').focus()`],
  },
  { name: 'settings/controls', steps: [lobby(), focus('settings'), press('Controls')] },
  { name: 'settings/controls-listening', steps: [lobby(), RAW_KEYS, focus('settings'), press('Controls'), press('TAB')] },
  { name: 'settings/accessibility', steps: [lobby(), focus('settings'), press('Accessibility')] },

  { name: 'help', steps: [lobby(), focus('help')] },

  { name: 'pause/lobby', steps: [lobby(), focus('pause')] },
  { name: 'pause/match', steps: ['__br.match()', focus('pause')] },
  { name: 'pause/confirm-leave', steps: ['__br.match()', focus('pause'), press('Leave match')] },
  { name: 'pause/confirm-disconnect', steps: ['__br.match()', focus('pause'), press('Disconnect')] },
  {
    name: 'pause/notices', steps: ['__br.match()',
      `__br.emit('toast', { text: 'Quillon_the_Longest_Name picked up your key', tone: 'success', ms: 4000 })`,
      `__br.emit('toast', { text: 'Storm closing in 30 seconds', tone: 'warn', ms: 4000 })`,
      focus('pause', ", tab: 'notices'")],
  },
  { name: 'pause/help', steps: ['__br.match()', focus('pause', ", tab: 'help'")] },
  { name: 'pause/settings', steps: ['__br.match()', focus('pause', ", tab: 'settings'")] },
  { name: 'admin', steps: [lobby(), focus('admin'), 'await __br.wait(1100)'] },

  { name: 'locker/season1', query: 'season=1', steps: [lobby(), focus('locker')] },
  { name: 'locker/peds', steps: L2_OPEN },
  { name: 'locker/peds-picked', steps: L2_PICK },
  { name: 'locker/rename', steps: [...L2_PICK, press('Rename')] },
  { name: 'locker/delete', steps: [...L2_PICK, press('Delete')] },
  { name: 'locker/stock', steps: [...L2_OPEN, press('Stock peds')] },
  { name: 'locker/male', steps: L2_MALE },
  { name: 'locker/female', steps: [...L2_OPEN, press('Custom (female)'), wait('Skin tone', L2)] },
  { name: 'locker/save-menu', steps: [...L2_DIRTY, press('Save')] },
  { name: 'locker/name', steps: [...L2_DIRTY, press('Save'), `__br.clickText('Create new', '${L2}')`] },
  { name: 'locker/discard', steps: [...L2_DIRTY, press('Done')] },
  {
    name: 'locker/edit-saved', steps: [...L2_PICK, press('Edit'), wait('Skin tone', L2),
      `__br.click('${L2} button[aria-label="Next"]')`, `__br.click('${L2} button[aria-label="Save"]')`],
  },
  { name: 'locker/tattoos', steps: [...L2_MALE, wait('Left arm', L2), press('Add'), press('Add')] },

  // ── THE WALKTHROUGHS, card by card ─────────────────────────────────────
  {
    name: 'tutorial/lobby', steps: [lobby(), `__br.emit('tutorial', { run: true, offer: false, offerable: true })`,
      { walk: 'tutorial/lobby', min: 20, max: 40 }],
  },
  {
    name: 'tutorial/match', steps: [WARMUP, FEED, PLAYERS,
      `__br.emit('toast', { text: 'Quillon_the_Longest_Name picked up your key', tone: 'success', ms: 600000 })`,
      `__br.emit('tutorial', { run: false, game: true })`,
      { walk: 'tutorial/match', min: 21, max: 40 }],
  },
  {
    name: 'tutorial/decline', steps: [lobby(), `__br.emit('tutorial', { run: false, offer: false, offerable: true })`,
      'window.brStore.getState().setTutorialDeclineCard(true)'],
  },
]

// ─────────────────────────────────────────────────────────────────────────────

const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(a)
  return m ? [m[1], m[2] ?? true] : [a, true]
}))
const only = args.only ? new RegExp(args.only) : null
const sizes = args.size ? SIZES.filter(([w, h]) => `${w}x${h}` === args.size) : SIZES
const texts = args.text ? TEXT.filter((t) => String(t) === String(args.text)) : TEXT
const shots = typeof args.shots === 'string' ? resolve(args.shots) : null
if (shots) mkdirSync(shots, { recursive: true })

const SETTLE = `(async () => {
  await document.fonts.ready
  const done = () => {
    for (const a of document.getAnimations()) {
      try {
        const t = a.effect && a.effect.getComputedTiming()
        if (t && Number.isFinite(t.endTime) && a.playState !== 'finished') a.finish()
      } catch { /* an animation that cannot finish is left running */ }
    }
  }
  // Two frames, or 100 ms if the page is not being given frames.
  const frame = () => new Promise((r) => {
    const t = setTimeout(r, 100)
    requestAnimationFrame(() => requestAnimationFrame(() => { clearTimeout(t); r() }))
  })
  const end = Date.now() + %MS%
  do { done(); await frame() } while (Date.now() < end)
  done(); await frame()
})()`
const settle = (tab, ms) => tab.eval(SETTLE.replace('%MS%', String(ms)))

/**
 * Run one screen at one size and one text size, from a fresh page: the text
 * size is the player's before the screen is opened, as it would be in game.
 */
async function runScreen(tab, origin, screen, [w, h], text) {
  const results = []
  await tab.size(w, h)
  await tab.go(`${origin}/?still${screen.query ? `&${screen.query}` : ''}`)
  await tab.eval(`new Promise((ok, fail) => {
    const end = Date.now() + 10000
    const f = () => window.brEmit ? ok(1) : Date.now() > end ? fail(new Error('the mock never started')) : setTimeout(f, 20)
    f()
  })`)
  await tab.eval(DRIVER)
  await tab.eval(PROBE)
  await tab.eval(`__br.emit('settings', { ...__br.SETTINGS, textScale: ${text} })`)
  const measure = async (label) => {
    await settle(tab, 60)
    const r = await tab.eval('window.__brProbe()')
    results.push({ screen: label, size: `${w}x${h}`, text, ...r })
    if (shots) {
      const img = await tab.send('Page.captureScreenshot', { format: 'png' })
      writeFileSync(join(shots, `${label.replace(/[^\w-]+/g, '_')}_${w}x${h}_${text}.png`), Buffer.from(img.data, 'base64'))
    }
  }
  const steps = [...screen.steps]
  const last = steps[steps.length - 1]
  if (!steps.length || typeof last !== 'object') steps.push({ probe: screen.name })
  for (const step of steps) {
    if (typeof step === 'string') {
      await tab.eval(`(async () => { ${step} })()`)
      await settle(tab, 300)
    } else if (step.probe) {
      await measure(step.probe)
    } else if (step.walk) {
      // A walkthrough: measure every card it shows, then move it on.
      // The cards it did measure are kept when it stops short, as is why.
      let i = 0
      let stopped = null
      while (await tab.eval('__br.nextCard()')) {
        if (++i > step.max) { stopped = `ran past ${step.max} cards`; break }
        const title = await tab.eval(`document.querySelector('.tut-card:not(.tut-card--leaving) .tut-title').textContent`)
        await measure(`${step.walk} ${i} (${title})`)
        if (!await tab.eval('__br.advance()')) { stopped = `stuck on card ${i} (${title})`; break }
        await settle(tab, 200)
      }
      if (!stopped && i < step.min) stopped = `showed ${i} cards, expected at least ${step.min}`
      if (stopped) results.push({ screen: step.walk, size: `${w}x${h}`, text, error: stopped, failures: [], hidden: [] })
    }
  }
  return results
}

/**
 * THE CHECK CHECKS ITSELF FIRST, on the lobby in the real bundle: a box cut
 * by 1 px and an unmarked label that wraps must both fail, prose marked
 * `data-wrap` must not, and a real button squeezed past its label (`Btn`,
 * through ui/Fit.tsx) must hide the label -- listed, not failed -- and show
 * it again given the room back. A probe that saw nothing would pass every
 * screen in the game; this is what stops that being a green build.
 */
async function selfCheck(tab, origin) {
  const problems = []
  await tab.size(1920, 1080)
  await tab.go(`${origin}/?still`)
  await tab.eval(`new Promise((ok) => { const f = () => window.brEmit ? ok(1) : setTimeout(f, 20); f() })`)
  // CEF 103's zoom, which scripts/lib/headless.mjs asks for (Locker v2).
  const zoomed = await tab.eval(`(() => {
    const o = document.createElement('div'); o.style.cssText = 'position:absolute;visibility:hidden;zoom:2'
    const i = document.createElement('div'); i.style.cssText = 'width:10px;height:10px'
    o.appendChild(i); document.body.appendChild(o)
    const w = i.getBoundingClientRect().width; o.remove(); return w
  })()`)
  if (Math.abs(zoomed - 10) > 0.5) problems.push('this browser measures CSS zoom as Chromium 128+ does, not as CEF 103 does')
  await tab.eval(DRIVER)
  await tab.eval(PROBE)
  await tab.eval(`__br.lobby()`)
  await settle(tab, 300)
  await tab.eval(`(() => {
    const box = document.createElement('div')
    box.style.cssText = 'position:fixed;left:20px;top:20px;width:240px;height:160px;overflow:hidden;'
      + 'z-index:2147483647;font:16px Barlow;color:#fff'
    box.innerHTML = '<div id="sc-edge" style="position:absolute;left:-1px;top:8px;width:60px;height:20px;border:1px solid #fff"></div>'
      + '<div id="sc-wrap" style="position:absolute;left:10px;top:40px;width:70px">A label that wraps</div>'
      + '<div id="sc-prose" data-wrap style="position:absolute;left:120px;top:40px;width:70px">Prose that may wrap</div>'
    document.body.appendChild(box)
    const m = document.querySelector('[data-tut=market]')
    m.dataset.was = m.style.flex
    m.style.flex = '0 0 14px'
  })()`)
  await settle(tab, 200)
  let r = await tab.eval('window.__brProbe()')
  const at = (id) => r.failures.filter((f) => f.path.includes(`#${id}`))
  if (!at('sc-edge').some((f) => f.rule === 'edge' && /left 1\.0px/.test(f.detail))) problems.push('a border cut by 1 px was not seen')
  if (!at('sc-wrap').some((f) => f.rule === 'line' && /wraps/.test(f.detail))) problems.push('a label that wraps was not seen')
  if (at('sc-prose').length) problems.push('prose marked data-wrap was failed')
  if (!r.hidden.some((h) => h.text === 'Market')) problems.push('a squeezed button did not hide its label')
  if (r.failures.some((f) => f.text === 'Market')) problems.push(`a squeezed button's label failed: ${r.failures.find((f) => f.text === 'Market').detail}`)
  await tab.eval(`(() => { const m = document.querySelector('[data-tut=market]'); m.style.flex = m.dataset.was })()`)
  await settle(tab, 200)
  r = await tab.eval('window.__brProbe()')
  if (r.hidden.some((h) => h.text === 'Market')) problems.push('a button given its room back did not show its label')
  return problems
}

const t0 = Date.now()
const chosen = SCREENS.filter((s) => !only || only.test(s.name))
if (chosen.length === 0) {
  console.error(`check-layout: no screen matches ${args.only}`)
  process.exit(1)
}

let status = 1
// `--dist=<dir>` measures a mock build already made (scripts/lib/headless.mjs
// buildMock), for iterating on this file; the build always makes its own.
const built = typeof args.dist === 'string' ? { dir: resolve(args.dist), remove: () => {} } : await buildMock(uiRoot)
const server = await serve(built.dir)
const browser = await launch()
try {
  const broken = await selfCheck(await browser.tab(1920, 1080), server.origin)
  if (broken.length) {
    for (const b of broken) console.error(`FAIL self-check: ${b}`)
    throw new Error('check-layout cannot see what it is for; nothing it says about the screens could be trusted')
  }
  // EVERY SCREEN AT EVERY SIZE AND TEXT SIZE IS ONE JOB, and a pool of
  // windows takes them longest first (a walkthrough is dozens of cards), each
  // from a fresh page. `--jobs=N` sets the pool; by default it is the
  // machine's cores less two, between 2 and 12.
  const jobs = []
  for (const s of chosen) for (const size of sizes) for (const text of texts) jobs.push({ s, size, text })
  jobs.sort((a, b) => (b.s.steps.some((x) => x.walk) ? 1 : 0) - (a.s.steps.some((x) => x.walk) ? 1 : 0))
  const workers = Math.max(1, Math.min(jobs.length,
    Number(args.jobs) || Math.max(2, Math.min(12, availableParallelism() - 2))))
  const all = []
  let next = 0
  await Promise.all(Array.from({ length: workers }, async () => {
    const tab = await browser.tab(1920, 1080)
    while (next < jobs.length) {
      const { s, size, text } = jobs[next++]
      let timer
      try {
        const limit = new Promise((_, fail) => { timer = setTimeout(() => fail(new Error('took over 90 s')), 90000) })
        all.push(...await Promise.race([runScreen(tab, server.origin, s, size, text), limit]))
      } catch (e) {
        all.push({ screen: s.name, size: `${size[0]}x${size[1]}`, text, error: e.message, failures: [], hidden: [] })
      } finally {
        clearTimeout(timer)
      }
    }
  }))
  const order = (r) => `${SIZES.findIndex(([w, h]) => `${w}x${h}` === r.size)}${TEXT.indexOf(r.text)}`
  all.sort((a, b) => order(a).localeCompare(order(b)))

  // Group: one line per element and complaint, with every size it fails at.
  const groups = new Map()
  const errors = []
  const hidden = new Map()
  for (const r of all) {
    if (r.error) { errors.push(`${r.screen} at ${r.size}@${r.text}: ${r.error}`); continue }
    for (const f of r.failures) {
      const key = `${r.screen}\u0000${f.rule}\u0000${f.path}\u0000${f.detail.replace(/[\d.]+px/g, 'Npx')}`
      if (!groups.has(key)) groups.set(key, { ...r, ...f, at: [] })
      const g = groups.get(key)
      g.at.push(`${r.size}@${r.text}`)
      if (f.px > g.px) { g.px = f.px; g.detail = f.detail }
    }
    for (const hd of r.hidden) {
      const key = `${r.screen}\u0000${hd.path}`
      if (!hidden.has(key)) hidden.set(key, { screen: r.screen, ...hd, at: [] })
      hidden.get(key).at.push(`${r.size}@${r.text}`)
    }
  }

  const probes = all.filter((r) => !r.error).length
  for (const h of hidden.values()) {
    console.log(`  hidden (no room)  ${h.screen}  "${h.text}"  ${h.path}  [${h.at.join(' ')}]`)
  }
  for (const e of errors) console.error(`FAIL could not draw ${e}`)
  for (const g of groups.values()) {
    console.error(`FAIL ${g.rule === 'edge' ? `${g.what} cut` : 'label'}  ${g.screen}  [${g.at.join(' ')}]`)
    console.error(`     ${g.path}${g.text ? `  "${g.text}"` : ''}`)
    console.error(`     ${g.detail}`)
  }
  const secs = ((Date.now() - t0) / 1000).toFixed(1)
  if (groups.size === 0 && errors.length === 0) {
    console.log(`check-layout: ${chosen.length} screens x ${sizes.length} sizes x ${texts.length} text sizes, `
      + `${probes} measurements, every border whole and every label on one line (${secs}s)`)
    status = 0
  } else {
    console.error(`check-layout: ${groups.size} failures, ${errors.length} screens not drawn, over ${probes} measurements (${secs}s)`)
  }
} finally {
  await browser.close()
  server.close()
  built.remove()
}
process.exit(status)
