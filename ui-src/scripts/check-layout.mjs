#!/usr/bin/env node
/**
 * EVERY BORDER DRAWN WHOLE, EVERY LABEL ON ONE LINE: the interface measured in
 * a real browser, at the game's window sizes and the player's interface and
 * text sizes.
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
 *   TEXT    the Text size slider's ends and its default: 90%, 100%, 115%;
 *   UI      the Interface size slider's ends, 80% and 130%, with Text size at
 *           both of its ends (settingsFor). Interface size multiplies rem and
 *           so the zoom of Locker v2's Cloudscape island; where the clamp
 *           makes one the same root px as 100% (80% at 720p, 130% at 4K) it is
 *           the same page, and measured once. `--full` measures every pair.
 *
 * THREE RULES, all failing the build:
 *
 *   EDGE  an element, or its ::before or ::after, with a visible border,
 *         outline or ring that does not stand a whole pixel inside every clip
 *         around it -- an ancestor's overflow hidden/auto/scroll/clip, paint
 *         containment or clip-path, and the screen. A border ON a clip's edge
 *         fails: the game's browser rounds a zoomed box either way, and flush
 *         is cut there. A scroll region is measured along its scroll as what
 *         scrolling can reach, so a card below the fold is not cut and one
 *         against the region's edge is.
 *   LINE  a single-line label -- any text not marked as prose -- that wraps,
 *         ends in an ellipsis, or is cut. Prose opts in: `data-wrap` on it or
 *         an ancestor, or the `.body-text` class. A `<br>` is a line the
 *         author wrote and is not a wrap. A label that cannot fit is hidden by
 *         `.fit` (ui/Fit.tsx) and listed, never failed: that is the rule...
 *   BLANK ...unless it was a control's only text: a button, tab, link or menu
 *         item whose every word is hidden is a blank box.
 *
 * UI V2'S ROWS CHECK MORE, in the page: every element of the Broadcast kit's
 * is drawn under a `.bc-kit` root, where its tokens are (V2_ROOTED), and in
 * the rows that ask, nothing overlaps the slanted vitals (v2ClearOfVitals),
 * the squad slot draws the Broadcast squad panel with its rows on air
 * (v2Squad), those rows take their own way out and back (v2SquadOut and
 * v2SquadBack: a motion, read the moment it starts), and a squad drawn over
 * another goes on air as a new one (v2SquadSwap).
 *
 * Each failure names its screen, the sizes it fails at, the element's path and
 * the pixels cut. A NEW SCREEN OPTS IN by adding a row to SCREENS: a name and
 * the steps that put it up, through `__br` (the driver's emit, click, mouse
 * for a control that opens on the press, lobby, match...). Its prose opts out
 * of LINE with `data-wrap`.
 *
 * WHAT MAKES IT TRUSTWORTHY. It checks its own eyes first (selfCheck: a
 * planted 1 px cut, a border flush with its clip, a cut outline, a cut ring,
 * a cut ::before and ::after, and an unmarked wrap must each fail, a border
 * a pixel clear and prose must not, a real button squeezed past its label
 * must hide it and fail as blank, and the Interface size must move rem).
 * Every screen is measured from a fresh page with both sizes already set, so
 * nothing is an artifact of a change mid-screen unless a row asks for one. And
 * the browser runs CSS zoom on CEF 103's rule, not Chromium 128's
 * (scripts/lib/headless.mjs), because Locker v2's Cloudscape island is zoomed
 * and measures its menus inside the zoom.
 *
 * WHAT IT CANNOT SEE: a pseudo-element with an edge laid out in the flow (it
 * has no box to place; one appearing fails the run, so it is never silently
 * skipped), what an element's own clip-path or overflow does to its own
 * drawing (on purpose: a plate's chamfer, a spinner's arc), a glyph's ink
 * above or below its line (a label is measured across, at its ends), what
 * overlaps what (but for the slanted vitals, above), and hover.
 *
 *   node scripts/check-layout.mjs              every screen, every size
 *   ... --only=market --size=1280x720 --text=1 --ui=1.3   one corner of it
 *   ... --full                                 every Interface x Text size pair
 *   ... --shots=<dir>                          and a screenshot of each
 *   ... --jobs=N                               N browser windows (cores, 6-12)
 *   ... --dist=<dir>                           a mock build already made
 *
 * Run: npm run check:layout   (and as part of npm run build)
 */
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs'
import { availableParallelism } from 'node:os'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildMock, launch, serve } from './lib/headless.mjs'
import { FIT_SLACK, UNFIT } from '../src/ui/labelFit.ts'
import { HALF, LEAVE_STEP, STEP } from '../src/ui/broadcast/motion/tokens.ts'

const here = dirname(fileURLToPath(import.meta.url))
const uiRoot = resolve(here, '..')
const PROBE = readFileSync(join(here, 'lib', 'layout-probe.js'), 'utf8')
const DRIVER = readFileSync(join(here, 'lib', 'layout-driver.js'), 'utf8')

export const SIZES = [[1280, 720], [1920, 1080], [2560, 1440], [3840, 2160]]
/** br_ui/client/settings.lua's RANGE.textScale, and its default. */
export const TEXT = [0.9, 1, 1.15]
/** RANGE.uiScale (the Interface size slider), and its default. */
export const UI = [0.8, 1, 1.3]

/** The root px at a window height and Interface size: index.css's clamp. */
export const remAt = (h, ui) => Math.min(28, Math.max(11, 0.01481 * h * ui))

/**
 * The [Interface size, Text size] pairs a window is measured at: Text size's
 * ends and default at the default Interface size, and both sliders' ends
 * together -- less an Interface size the clamp gives the same root px as the
 * default at that window, which is the same page. `full`: every pair.
 */
export function settingsFor([, h], full = false) {
  const pairs = full
    ? UI.flatMap((ui) => TEXT.map((t) => [ui, t]))
    : [...TEXT.map((t) => [1, t]), [0.8, 0.9], [0.8, 1.15], [1.3, 0.9], [1.3, 1.15]]
  return pairs.filter(([ui]) => ui === 1 || Math.abs(remAt(h, ui) - remAt(h, 1)) > 0.01)
}
/** How a pair is written in the report. */
const at = (size, ui, text) => `${size}@ui${ui}/tx${text}`

const lobby = (o = '') => `__br.lobby(${o})`
const press = (label) => `__br.click('button', ${JSON.stringify(label)})`
const focus = (screen, extra = '') => `__br.emit('focus', { screen: '${screen}'${extra} })`
const wait = (text, within = 'body', ms = 6000) =>
  `await __br.until(() => __br.has(${JSON.stringify(text)}, ${JSON.stringify(within)}), ${ms}, ${JSON.stringify(text)})`
const L2 = '[data-page=locker]'

/** A Market tab with more than the grid can show, so it scrolls, under the
 *  catalog's own names (the longest is mockMarket.ts's, Beach Party II). */
const BIG_MARKET = `__br.emit('market', { balance: 7450, items: Array.from({ length: 22 }, (_, i) => ({
  id: 'chute_' + i, name: ['Midnight', 'Stormchaser', 'Beach Party II', 'Ash'][i % 4], sub: 'Canopy',
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

/** Season 2's Market is up once its grid has drawn; a tab is pressed by name. */
const MK2 = `await __br.until(() => document.querySelector('[data-page=market] .mk2 [role=tab]'), 8000, 'the Season 2 Market')`
const tab2 = (label) => `__br.click('[data-page=market] [role=tab]', ${JSON.stringify(label)})`
/** The first price on the grid, which asks before it buys. */
const BUY2 = `[...document.querySelectorAll('[data-page=market] .mk2 button')]
  .find((b) => /^[0-9,]+$/.test(b.textContent.trim()) && !b.disabled).click()`

/** A squad of names as long as a platform name runs, in the squad panel. */
const LONG_NAMES = `__br.emit('squad', { id: 'sq_1', you: 1, members: [
      { src: 1, name: 'Quillon_the_Longest_Name', state: 'alive', hp: 82, armour: 45, colour: '#6EE7F9', level: 42 }, // wire names: spelling-ok
      { src: 2, name: 'Marrow_of_the_Long_Night', state: 'dbno', hp: 12, armour: 0, colour: '#2DD4BF', bleedEndsAt: Date.now() + 40000, level: 100 }, // wire names: spelling-ok
      { src: 3, name: 'Vandal_Who_Never_Stops', state: 'dead', hp: 0, armour: 0, colour: '#FBBF24', reviveKey: true }] }) /* wire names: spelling-ok */`

/**
 * UI V2'S HUD ON SCREEN, ITS WIPE LANDED (#431): the one HUD root on the page
 * is the v2 one and it is up, and none of the kit's presences is still
 * entering or leaving. Without the first half a row whose piece never took
 * would measure today's HUD and pass.
 */
const V2_LANDED = `await __br.until(() => {
  const roots = document.querySelectorAll('[data-layer="hud"]')
  return roots.length === 1 && roots[0].closest('.hud-v2') !== null && getComputedStyle(roots[0]).opacity === '1'
    && document.querySelector('.hud-v2 .hud-anchor[data-bc-phase="shown"]') !== null
    && document.querySelector('[data-bc-phase="entering"], [data-bc-phase="leaving"]') === null
}, 8000, "UI v2's HUD, its wipe landed")`

/**
 * EVERY ELEMENT OF THE KIT'S IS DRAWN UNDER A .bc-kit ROOT (#431). The kit's
 * tokens are declared on .bc-kit alone (ui/broadcast/tokens.css), so an
 * element its sheets land on -- a bc- class or a data-bc- attribute, as
 * scripts/test-broadcast.mjs counts them -- drawn outside every .bc-kit root
 * draws with each var(--bc-*) unset: no color, no size, no timing.
 * test-broadcast reads that per file and per root it names; this reads the
 * page, so a second bare root in one file, or a root that lost the class,
 * fails here.
 */
const V2_ROOTED = `{
  const kit = (e) => [...e.classList].some((c) => c.startsWith('bc-'))
    || [...e.attributes].some((a) => a.name.startsWith('data-bc-'))
  const bare = [...document.querySelectorAll('body *')].filter((e) => kit(e) && !e.closest('.bc-kit'))
  if (bare.length > 0) {
    const name = (e) => e.tagName.toLowerCase() + [...e.classList].map((c) => '.' + c).join('')
      + ['data-hud-id', 'data-bc-preset'].filter((a) => e.hasAttribute(a)).map((a) => '[' + a + '=' + e.getAttribute(a) + ']').join('')
    throw new Error(bare.length + " of the kit's elements drawn outside every .bc-kit root, its tokens unset: "
      + bare.slice(0, 3).map(name).join(', '))
  }
}`

/**
 * THE RADAR HIDDEN WITH THE HUD UP: the screen as it was sent, with radarOn
 * false (screen.lua sends `not IsRadarHidden()`). The game's own rule hides
 * the radar in the lobby, aboard the bus, during a trip or the curtain and
 * over a scope (natives.lua, wantRadar), and UI v2's strip is away in each of
 * those: not up, held, or quick-hidden. So this is the radar hidden some
 * other way with the strip on screen (inferred: a display setting of the
 * player's, if the game reports it there; not seen in game).
 */
const RADAR_OFF = `__br.emit('screen', { ...window.brStore.getState().screen, radarOn: false })`

/** A chat log as tall as it grows, open, and a full notice stack. */
const CHAT_AND_NOTICES = [
  `for (let i = 1; i <= 12; i++) __br.emit('chat', { channel: 'global', from: i,
    name: i % 2 ? 'Quillon_the_Longest_Name' : 'Kestrel', text: i % 3 ? 'gg' : 'on me', at: Date.now() })`,
  `for (const text of ['Storm closing in 30 seconds', 'Quillon_the_Longest_Name picked up your key',
    'Kestrel picked up your key', 'Rook picked up your key', 'Vandal picked up your key'])
    __br.emit('toast', { text, tone: 'success', ms: 600000 })`,
  `__br.emit('impacts', { list: [{ key: 'scan', text: 'Your position is being scanned', endsAt: Date.now() + 600000 }] })`,
  focus('chat', ", channel: 'squad'"),
]

/** What UI v2's vitals strip is measured against (v2ClearOfVitals). The
 *  radar's place is the walkthrough's minimap box, drawn radar or not. */
const RADAR_PLACE = ["the radar's place", '.hud-v2 [data-tut="hud-minimap"]']
const CHAT_COLUMN = ['the chat column', '#br-chat-column']
const NOTICE_STACK = ['the notice stack', '.hud-v2 [data-tut="hud-notices"]']

/**
 * UI V2'S VITALS STRIP CLEAR OF THE RADAR, THE CHAT COLUMN AND THE NOTICE
 * STACK (#431). The slanted strip is 3.3rem and hangs by all of it (HudV2.tsx's
 * --vitals-drop), so the one placement puts it under the radar only where the
 * margin there holds the whole strip, and above the radar everywhere else:
 * never over it, the owner's 2026-08-09 bug. Hung by today's 0.85rem it
 * "fits below" and covers the radar's lower part. And today's radar-hidden
 * places for the chat and the notices, sized for the 1.05rem pill under the
 * radar, stack them up into the strip; UI v2 keeps their radar-on places
 * instead (keepRadarPlace). This reads the strip and each box a row names
 * where they are drawn, and fails on any overlap, or on a box named that is
 * not drawn. (EDGE and LINE cannot see one: they measure each box alone.)
 */
const v2ClearOfVitals = (...boxes) => `{
  const box = (sel) => { const e = document.querySelector(sel); return e ? e.getBoundingClientRect() : null }
  const strip = box('.hud-v2 [data-tut="hud-vitals"]')
  if (!strip || strip.height < 1) throw new Error("UI v2's vitals strip is not drawn")
  const over = []
  for (const [name, sel] of ${JSON.stringify(boxes)}) {
    const r = box(sel)
    if (!r || r.height < 1) throw new Error(name + ' is not drawn')
    const x = Math.min(r.right, strip.right) - Math.max(r.left, strip.left)
    const y = Math.min(r.bottom, strip.bottom) - Math.max(r.top, strip.top)
    if (x > 0.5 && y > 0.5) over.push(name + ' covers ' + y.toFixed(1) + ' px of it')
  }
  if (over.length) throw new Error("UI v2's vitals strip is overlapped: " + over.join(', '))
}`

/** The curtain drawn over UI v2's HUD, and the HUD held under it (its hold is
 *  the curtain's own report: hud/v2/HudLayer.tsx), so the vitals the
 *  walkthrough's first card rings are not visible. */
const V2_UNDER_CURTAIN = [
  `__br.emit('leaving', { show: true, kind: 'dropping' })`,
  `await __br.until(() => {
    const e = document.querySelector('.hud-v2 [data-tut="hud-vitals"]')
    return e !== null && getComputedStyle(e).visibility !== 'visible'
  }, 8000, "UI v2's HUD held under the drawn curtain")`,
]

/** The in-match walkthrough still running after 2.5 s with UI v2's HUD hidden
 *  by `cause`. It ends a run 1.2 s after its target goes unseen, unless a
 *  screen says the target is away (TutorialLayer.tsx, AWAY_ATTR). */
const tutorialStillOn = (cause) => `await new Promise((r) => setTimeout(r, 2500))
  if (!window.brStore.getState().tutorialGameRun) {
    throw new Error("the in-match walkthrough ended under ${cause}: UI v2's HUD was hidden and did not say its targets were away")
  }`

/**
 * THE BROADCAST SQUAD PANEL IN UI V2'S SLOT, ON AIR (#429): the slot draws the
 * Broadcast panel, `n` rows, each a presence of its own and on air, and the
 * slot's anchor has stood down for them (hud/v2/Anchor.tsx, `ownable`):
 * nothing between the slot and the rows carries a phase or a channel of the
 * kit's. Without it a v2 row whose slot drew today's panel would measure that
 * and pass.
 */
const v2Squad = (n) => `{
  const slot = document.getElementById('br-squad-slot')
  if (!slot || !slot.closest('.hud-v2')) throw new Error("UI v2's squad slot is not drawn")
  if (!slot.querySelector('.bsq-panel')) throw new Error("UI v2's squad slot does not draw the Broadcast squad panel")
  const rows = [...slot.querySelectorAll('.bsq-air')]
  const aired = rows.filter((r) => r.getAttribute('data-bc-phase') === 'shown').length
  if (rows.length !== ${n} || aired !== ${n}) {
    throw new Error('the Broadcast squad panel draws ' + rows.length + ' rows, ' + aired + ' of them on air, not ${n}')
  }
  const anchor = slot.querySelector('[data-hud-id="squad"]')
  if (!anchor || !anchor.hasAttribute('data-hud-own')) throw new Error("the squad slot's anchor has not stood down for the panel's rows")
  const round = new Set()
  for (const r of rows) {
    for (let e = r.parentElement; e && e !== slot.parentElement; e = e.parentElement) {
      if (e.hasAttribute('data-bc-phase') || [...e.classList].some((c) => c.startsWith('bc-ch-'))) {
        round.add(e.tagName.toLowerCase() + [...e.classList].map((c) => '.' + c).join(''))
      }
    }
  }
  if (round.size) throw new Error('between the squad slot and its rows, a phase or a channel of the kit: ' + [...round].join(', '))
}`

/** What the squad steps below read: the panel's rows; per row its channels'
 *  [delay, ms] (content, surface, edge: the kit's presence vars, machine.ts
 *  rootVars); what is in play round the rows, up to the HUD's root (a
 *  transition or an animation there carries every row with it); and `when`,
 *  which reads the first moment all `n` rows are in a phase, after `go`, in
 *  a MutationObserver: before any timer or frame, so a slow page cannot let
 *  the moment pass. */
const SQUAD_READ = `
  const slot = document.getElementById('br-squad-slot')
  const root = document.querySelector('.hud-v2 [data-layer="hud"]')
  if (!slot || !root) throw new Error("UI v2's HUD and its squad slot are not drawn")
  const rows = () => [...slot.querySelectorAll('.bsq-air')]
  const ms = (e, name) => parseFloat(getComputedStyle(e).getPropertyValue(name))
  const timing = (r) => ['content', 'surface', 'edge'].map((c) => [ms(r, '--bc-' + c + '-delay'), ms(r, '--bc-' + c + '-ms')])
  const moving = () => {
    const out = new Set()
    for (const r of rows()) {
      for (let e = r.parentElement; e; e = e.parentElement) {
        for (const a of e.getAnimations()) {
          if (a.playState === 'running' || a.playState === 'paused' || a.pending) {
            out.add(e.tagName.toLowerCase() + [...e.classList].map((c) => '.' + c).join('')
              + ' (' + (a.transitionProperty || a.animationName || 'an animation') + ')')
          }
        }
        if (e === root) break
      }
    }
    return [...out]
  }
  const when = (n, phase, go, read) => new Promise((ok, fail) => {
    const all = () => { const rs = rows(); return rs.length === n && rs.every((r) => r.getAttribute('data-bc-phase') === phase) }
    const mo = new MutationObserver(() => { if (all()) { mo.disconnect(); clearTimeout(t); ok(read()) } })
    const t = setTimeout(() => { mo.disconnect(); fail(new Error('the squad rows never all went ' + phase)) }, 4000)
    mo.observe(slot, { subtree: true, childList: true, attributes: true, attributeFilter: ['data-bc-phase'] })
    go()
  })`

/**
 * THE SQUAD'S OWN WAY OUT (#429, #431). Round 1's look review found today's
 * panel leaving UI v2's slot in one 140 ms fade of its anchor's content
 * channel, on every way out, where the owner's pick closes the Broadcast
 * plates row by row, the bottom mate first, until about 600 ms. Read the
 * moment `go` starts it: every row leaving on the Broadcast way off air
 * (HALF.offAir) from its own turn, the bottom one first and each next one
 * LEAVE_STEP after it; nothing round the rows in play, so no fade or slide of
 * the anchor's cuts one short; and the HUD's root up until the last row has
 * gone: when the whole HUD goes (`whole`), its sentinel holds the root up at
 * least that long, and when only the slot's scope goes, the HUD stays.
 */
const v2SquadOut = (cause, go, whole) => `{${SQUAD_READ}
  // A row still on its way in turns round at once rather than on its turn.
  await __br.until(() => rows().every((r) => r.getAttribute('data-bc-phase') === 'shown'), 4000, 'the squad rows on air')
  const n = rows().length
  if (n < 2) throw new Error('the squad panel has ' + n + ' rows on air to take off (${cause})')
  const sentinel = root.querySelector('.hud-sentinel')
  const seen = await when(n, 'leaving', () => { ${go} }, () => ({
    timing: rows().map(timing), moving: moving(), sentinel: sentinel.getAttribute('data-bc-phase'),
    hold: ms(sentinel, '--bc-root-ms'), opacity: getComputedStyle(root).opacity,
  }))
  const OFF = ${JSON.stringify(HALF.offAir)}
  const want = seen.timing.map((_, i) => ['content', 'surface', 'edge'].map((c) => [(n - 1 - i) * ${LEAVE_STEP} + OFF[c].at, OFF[c].ms]))
  if (JSON.stringify(seen.timing) !== JSON.stringify(want)) {
    throw new Error('the squad rows do not leave as the Broadcast panel does (${cause}): per row, top first, '
      + '[delay, ms] of the content, surface and edge ' + JSON.stringify(seen.timing) + ', expected ' + JSON.stringify(want))
  }
  if (seen.moving.length) throw new Error('something round the squad rows moves as they leave (${cause}): ' + seen.moving.join(', '))
  const last = Math.max(...seen.timing.flat().map(([at, len]) => at + len))
  ${whole
    ? `if (seen.sentinel !== 'leaving' || seen.opacity !== '1' || !(seen.hold >= last)) {
    throw new Error("UI v2's HUD root goes before its squad rows have left (${cause}): its sentinel " + seen.sentinel
      + ' for ' + seen.hold + ' ms, opacity ' + seen.opacity + ', the last row gone at ' + last + ' ms')
  }`
    : `if (seen.sentinel !== 'shown' || seen.opacity !== '1') {
    throw new Error("UI v2's HUD goes with its squad rows (${cause}): its sentinel " + seen.sentinel + ', opacity ' + seen.opacity)
  }`}
}`

/** ...AND BACK ON AIR once they have gone: every row entering on the
 *  Broadcast way on air (HALF.onAir), the top mate first and each next one a
 *  STEP after it, with nothing round them in play. A turn is counted from the
 *  moment the panel's scope went live, and each row takes it when its
 *  presence begins, in one commit, so a slow commit makes every row late by
 *  the same few ms, and a turn already past is now (the kit's late joiner):
 *  row i's is max(0, i x STEP - late), one `late` for all, read off the
 *  bottom row, which is never at 0 but when every row comes back at once. */
const v2SquadBack = (cause, go) => `{${SQUAD_READ}
  await __br.until(() => rows().every((r) => r.getAttribute('data-bc-phase') !== 'leaving'), 4000, 'the squad rows off air')
  const n = slot.querySelectorAll('.bsq-slot').length
  const seen = await when(n, 'entering', () => { ${go} }, () => ({ timing: rows().map(timing), moving: moving() }))
  const ON = ${JSON.stringify(HALF.onAir)}
  const turns = seen.timing.map(([, , [edgeAt]]) => edgeAt - ON.edge.at)
  const lens = seen.timing.map((t) => t.map(([, len]) => len))
  const late = (n - 1) * ${STEP} - turns[n - 1]
  if (n < 2 || lens.some((l) => JSON.stringify(l) !== JSON.stringify([ON.content.ms, ON.surface.ms, ON.edge.ms]))
    || !(turns[n - 1] > 0) || late < -1 || turns.some((at, i) => Math.abs(at - Math.max(0, i * ${STEP} - late)) > 1)) {
    throw new Error('the squad rows do not come back as the Broadcast panel does (${cause}): per row, top first, '
      + '[delay, ms] of the content, surface and edge ' + JSON.stringify(seen.timing))
  }
  if (seen.moving.length) throw new Error('something round the squad rows moves as they come back (${cause}): ' + seen.moving.join(', '))
}`

/** One squad member as the wire spells it. */
const wireMate = (src, name, state, hp, armor, color, more = {}) =>
  ({ src, name, state, hp, armour: armor, colour: color, ...more }) // wire names: spelling-ok
/** The mock's squad (src/bridge/mock.ts): four mates, one down, one out. */
const MOCK_SQUAD = { id: 'sq_1', you: 1, members: [
  wireMate(1, 'You', 'alive', 82, 45, '#6EE7F9', { level: 42 }),
  wireMate(2, 'Kestrel', 'alive', 100, 80, '#2DD4BF', { level: 100 }),
  wireMate(3, 'Vandal', 'dbno', 12, 0, '#FBBF24', { level: 7 }),
  wireMate(4, 'Nyx', 'dead', 0, 0, '#F472B6', { reviveKey: true }),
] }
/** A stand-in for the walkthrough's staged squad (TutorialLayer.tsx
 *  DEMO_SQUAD): an id no server hands out, on server ids 1 to 4. */
const STAGED_SQUAD = { id: 'tutorial', you: 1, members: [
  wireMate(1, 'You', 'alive', 100, 50, '#60A5FA', { kills: 2 }),
  wireMate(2, 'Vance', 'alive', 74, 0, '#4ADE80', { kills: 1 }),
  wireMate(3, 'Okonkwo', 'dbno', 0, 0, '#FBBF24', { kills: 0 }),
  wireMate(4, 'Marlowe', 'alive', 100, 100, '#F87171', { kills: 4 }),
] }
/** A squad on server ids the staged one does not use, as a real one's are. */
const OTHER_SQUAD = { id: 'sq_7', you: 11, members: [
  wireMate(11, 'You', 'alive', 82, 45, '#6EE7F9', { level: 42 }),
  wireMate(12, 'Kestrel', 'alive', 100, 80, '#2DD4BF', { level: 100 }),
  wireMate(13, 'Vandal', 'alive', 60, 10, '#FBBF24', { level: 7 }),
  wireMate(14, 'Nyx', 'alive', 90, 0, '#F472B6'),
] }
const squadOf = (sq) => `__br.emit('squad', ${JSON.stringify(sq)})`
const staged = (sq) => `window.brStore.getState().setTutorialSquad(${JSON.stringify(sq)})`
/** The squad slot's `n` rows, each on air. */
const v2SquadOn = (n) => `await __br.until(() => {
  const rows = [...document.querySelectorAll('#br-squad-slot .bsq-air')]
  return rows.length === ${n} && rows.every((r) => r.getAttribute('data-bc-phase') === 'shown')
}, 4000, 'the ${n} squad rows on air')`

/**
 * THE SQUAD SLOT BACK WITH NO ROWS IN IT, ITS ANCHOR UP OVER IT: the player
 * goes solo, so the panel takes its rows off air; freefalls, which takes the
 * slot down; and lands, which brings it back with a new anchor, shown over an
 * empty slot, that has seen no row and so has not stood down.
 */
const V2_SLOT_EMPTY = [
  `${squadOf({ id: null, you: 1, members: [MOCK_SQUAD.members[0]] })}
  await __br.until(() => !document.querySelector('#br-squad-slot .bsq-air'), 4000, 'the squad rows off air (solo)')`,
  `__br.emit('hud', { ...window.brStore.getState().hud, state: 'freefall', landed: false })
  await __br.until(() => !document.getElementById('br-squad-slot'), 4000, 'the squad slot down in freefall')`,
  `__br.emit('hud', { ...window.brStore.getState().hud, state: 'alive', landed: true })
  await __br.until(() => document.querySelector('#br-squad-slot [data-hud-id="squad"][data-bc-phase="shown"]'), 4000,
    "the squad slot's anchor shown over an empty slot")`,
]

/** What a beat leaves on a row of the Broadcast squad panel, the kit's
 *  (src/ui/broadcast: Plate, Bar, LightSweep, Numeral, Stamp, Tag) and the
 *  panel's own (hud/squadV2.css): a flash, a burst, a recolor, a flare, a
 *  jolt or a knock, a light (but the on-air one, .bsq-onair), a bar's gain,
 *  crack, shards or hit, a plate swapped in or out (the DOWN alarm, the OUT
 *  plate), a zip, a numeral's punch or a digit's tick, a stamp's or a tag's
 *  entrance (OUT, DOWN, the marks), the red line's slide, the key's drop or
 *  slam, the level's pop, the clock's slam and the voice's cut. A row that
 *  goes on air has none: its first reading is no event (hud/mateEvents.ts). */
const SQUAD_BEATS = [
  '.bc-flash', '.bc-burst', '.bc-plate__retract', '.bc-plate__flare', '.bc-plate__shake[class*=" is-"]',
  '.bc-sweep', '.bc-gain', '.bc-crack', '.bc-shards', '.bc-bar__hit', '.bc-swap.is-in', '.bc-swap.is-out', '.bc-zip',
  '.bc-num[class*=" is-"]', '.bc-col.is-fall', '.bc-col.is-rise', '.bc-col.is-flat', '.bc-stamp[class*=" is-"]',
  '.bc-tag[class*=" is-"]', '.bc-plate__foot.is-new', '.bsq-key.is-drop', '.bsq-key.is-slam', '.bsq-level.is-new',
  '.bsq-clockwrap.is-new', '.bsq-voice[class*="is-cut"]',
].join(', ')

/**
 * A SQUAD DRAWN OVER ANOTHER IS A NEW ONE ON AIR (#429). The walkthrough's
 * squad cards stage a squad of their own over the player's (TutorialLayer.tsx,
 * the store's tutorialSquad, which only the HUD draws), and the panel reads
 * its rows by server id. Read from the swap `go` makes, in a MutationObserver,
 * until the rows of `squad`, the squad now drawn, are on air, its names in
 * them (the page draws a store change a moment later, so the rows on air
 * before it are the last squad's): none of them carries a beat (SQUAD_BEATS),
 * where a row read against the last squad's row of the same server id played
 * a hit, a shield break, a knock or a kill nobody took; the stack never holds
 * more rows than `squad` has, where a row of the last squad's left on the
 * diagonal under them, as a mate who leaves does; and they go on air as a
 * squad that forms does, the Broadcast way (HALF.onAir), top mate first and a
 * STEP apart (one lateness for all, as v2SquadBack reads it), with nothing
 * round them in play.
 */
const v2SquadSwap = (cause, squad, go) => {
  const n = squad.members.length
  const names = JSON.stringify([...squad.members].sort((a, b) => a.src - b.src).map((m) => m.name))
  return `{${SQUAD_READ}
  let tallest = 0
  let entered = null
  const look = () => {
    tallest = Math.max(tallest, slot.querySelectorAll('.bsq-slot').length)
    const rs = rows()
    if (!entered && rs.length === ${n} && rs.every((r) => r.getAttribute('data-bc-phase') === 'entering')) {
      entered = { timing: rs.map(timing), moving: moving() }
    }
  }
  const mo = new MutationObserver(look)
  mo.observe(slot, { subtree: true, childList: true, attributes: true, attributeFilter: ['data-bc-phase'] })
  const drawn = () => JSON.stringify(rows().map((r) => r.querySelector('.bsq-name')?.textContent ?? ''))
  try {
    ${go}
    look()
    await __br.until(() => drawn() === ${JSON.stringify(names)} && rows().every((r) => r.getAttribute('data-bc-phase') === 'shown'),
      4000, 'the ${n} rows of the squad drawn on air (${cause})')
  } finally {
    mo.disconnect()
  }
  const beats = []
  rows().forEach((r, i) => {
    for (const e of r.querySelectorAll(${JSON.stringify(SQUAD_BEATS)})) {
      if (!e.closest('.bsq-onair')) beats.push('row ' + (i + 1) + ' ' + e.tagName.toLowerCase() + [...e.classList].map((c) => '.' + c).join(''))
    }
  })
  if (beats.length) {
    throw new Error('a squad drawn over another plays beats on its rows (${cause}), events nobody had: ' + beats.slice(0, 6).join(', '))
  }
  if (tallest > ${n}) {
    throw new Error('the squad panel stacked ' + tallest + ' rows for a squad of ${n} (${cause}): the last squad left on the diagonal under it')
  }
  if (!entered) throw new Error('the squad drawn did not go on air as a new squad (${cause})')
  const ON = ${JSON.stringify(HALF.onAir)}
  const turns = entered.timing.map(([, , [edgeAt]]) => edgeAt - ON.edge.at)
  const lens = entered.timing.map((t) => t.map(([, len]) => len))
  const late = ${(n - 1) * STEP} - turns[${n - 1}]
  if (lens.some((l) => JSON.stringify(l) !== JSON.stringify([ON.content.ms, ON.surface.ms, ON.edge.ms]))
    || !(turns[${n - 1}] > 0) || late < -1 || turns.some((at, i) => Math.abs(at - Math.max(0, i * ${STEP} - late)) > 1)) {
    throw new Error('the squad drawn does not go on air as the Broadcast panel does (${cause}): per row, top first, '
      + '[delay, ms] of the content, surface and edge ' + JSON.stringify(entered.timing))
  }
  if (entered.moving.length) throw new Error('something round the squad rows moves as they go on air (${cause}): ' + entered.moving.join(', '))
}`
}

/** The keybinds the mock sends, with rebinding available (`raw`). */
const RAW_KEYS = `__br.emit('keybinds', { actions: window.brStore.getState().keybinds, raw: true })`

/** Locker v2 (My Looks, #28) open on its saved looks, once its mock has sent them. */
const L2_OPEN = ['await __br.lockerV2()', wait('Nightshift', L2)]
/** The first card's "..." menu, open. */
const L2_MENU = [...L2_OPEN, `__br.click('${L2} .lk2-card-menu button')`, wait('Rename', L2)]
const L2_NEW = [...L2_OPEN, press('New'), wait('Stock GTA Looks', L2)]
/** A new custom look in the editor: never saved, so Back asks first. */
const L2_EDIT = [...L2_NEW, press('Create'), wait('Randomize', L2)]
/** A line of the editor's list pressed: its panel. */
const line = (label) => `__br.clickText('${label}', '${L2} .lk2-lines')`
/** A Cloudscape Select: its option, pressed as a mouse does. */
const option = (label) => `await __br.mouse('${L2} [role=option]', ${JSON.stringify(label)})`
const L2_TATS = [...L2_EDIT, press('Add more'), `__br.clickText('Tattoos', '${L2} .lk2-menu')`, wait('Add more', `${L2} .lk2-tats`)]

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
  // THE VITALS STRIP ABOVE THE RADAR (#231, #319). The other rows sit at the
  // mock's default safe zone, where the strip always fits under the radar. At
  // 0.98 it cannot, so it goes above and the chat moves up; then the safe zone
  // and the Interface size are dragged across that line mid-match, which only
  // the placement's keys re-decide (hud/useVitalsPlacement.ts). A strip left
  // on the wrong side is cut by the bottom of the screen. `brScreen()` sends
  // the screen again, in case the mock's first one beat the page's listeners.
  { name: 'hud/safe-top', query: 'safe=0.98', steps: ['__br.match()', 'window.brScreen()'] },
  { name: 'hud/safe-drag', steps: ['__br.match()', "window.brScreen('window', 0.98)"] },
  {
    name: 'hud/ui-drag', query: 'safe=0.972', steps: ['__br.match()', 'window.brScreen()',
      `__br.emit('settings', { ...__br.SETTINGS, uiScale: 1.3 })`],
  },
  // Names as long as a platform name runs, in the squad panel.
  { name: 'hud/long-names', steps: ['__br.match()', LONG_NAMES] },
  // UI V2'S HUD (#431, #436): the first row and the long names again with the
  // hud piece on, the mock's `uiv2=hud` being a machine that holds it, told
  // first as br_ui tells the page. Measured once the wipe has landed, and
  // failed if any of the kit's elements is drawn outside a .bc-kit root, if
  // the slanted vitals and the radar overlap (v2ClearOfVitals), or if the
  // squad slot does not draw the Broadcast squad panel (#429), every row on
  // air, its anchor stood down (v2Squad): the mock's four mates, and the
  // three with long names.
  {
    name: 'hud/v2', query: 'uiv2=hud',
    steps: ['__br.match()', V2_LANDED, V2_ROOTED, v2ClearOfVitals(RADAR_PLACE), v2Squad(4)],
  },
  { name: 'hud/v2-long-names', query: 'uiv2=hud', steps: ['__br.match()', LONG_NAMES, V2_LANDED, V2_ROOTED, v2Squad(3)] },
  // THE SQUAD'S OWN WAY OUT AND BACK (#429, #431): the gun-shop menu takes the
  // Broadcast rows off air and brings them back on, boarding takes them with
  // the whole HUD, and each time they go row by row as the owner's pick does,
  // nothing round them cutting one short (v2SquadOut, v2SquadBack). Then the
  // HUD comes back, and is measured.
  {
    name: 'hud/v2-squad-out', query: 'uiv2=hud', steps: ['__br.match()', V2_LANDED, v2Squad(4),
      v2SquadOut('the gun-shop menu', `__br.emit('gunshopmenu', { open: true })`, false),
      v2SquadBack('the gun-shop menu closed', `__br.emit('gunshopmenu', { open: false })`),
      v2SquadOut('boarding', `__br.emit('hud', { ...window.brStore.getState().hud, state: 'bus' })`, true),
      '__br.match()', V2_LANDED, v2Squad(4)],
  },
  // THE ROWS ARRIVING UNDER THE SLOT'S ANCHOR, UP ALREADY (#429). The anchor
  // looks for the panel's rows as each of its phases begins and when the
  // panel's rule moves (ownKey, hasSquad); every row above brings the squad
  // in with a phase of the anchor's own. Here the slot comes back with no
  // rows (V2_SLOT_EMPTY), then four mates arrive with no id, which draws
  // nothing, and then their id: the rule moves, the size does not, and an
  // anchor that missed the rows would keep its content channel over them,
  // fading them in one go on every way out (v2Squad).
  {
    name: 'hud/v2-squad-forms', query: 'uiv2=hud', steps: ['__br.match()', V2_LANDED, v2Squad(4), ...V2_SLOT_EMPTY,
      squadOf({ ...MOCK_SQUAD, id: null }),
      "if (document.querySelector('#br-squad-slot .bsq-air')) throw new Error('the squad panel drew rows for a squad with no id')",
      `${squadOf(MOCK_SQUAD)}
      ${v2SquadOn(4)}`,
      v2Squad(4)],
  },
  // THE WALKTHROUGH'S SQUAD OVER THE PLAYER'S (#429): staged over a squad on
  // the same server ids, then taken off over a squad on other ones, and
  // staged over that, each time a new squad on air (v2SquadSwap). Measured as
  // the squad cards show it over a real squad.
  {
    name: 'hud/v2-squad-staged', query: 'uiv2=hud', steps: ['__br.match()', V2_LANDED, v2Squad(4),
      v2SquadSwap('the walkthrough over the squad, on the same server ids', STAGED_SQUAD, staged(STAGED_SQUAD)),
      squadOf(OTHER_SQUAD),
      v2SquadSwap('the walkthrough done, over a squad on other server ids', OTHER_SQUAD, staged(null)),
      v2SquadSwap('the walkthrough over a squad on other server ids', STAGED_SQUAD, staged(STAGED_SQUAD)),
      v2Squad(4)],
  },
  // The radar hidden with the hud piece on, a full chat open and a full notice
  // stack: none of them may meet the slanted vitals (v2ClearOfVitals).
  {
    name: 'hud/v2-radar-off', query: 'uiv2=hud',
    steps: ['__br.match()', RADAR_OFF, ...CHAT_AND_NOTICES, V2_LANDED, V2_ROOTED,
      v2ClearOfVitals(RADAR_PLACE, CHAT_COLUMN, NOTICE_STACK)],
  },
  // ...and at a safe zone of 0.9 (a 5% inset: the slider's low end, inferred),
  // where the margin under the radar holds the whole slanted strip from 1080p
  // up at the default Interface size and below it: there the strip hangs
  // under the radar, at 720p and at 130% above it, and never over it, with a
  // full chat open and a full notice stack clear of it on either side.
  {
    name: 'hud/v2-safe-low', query: 'uiv2=hud&safe=0.9',
    steps: ['__br.match()', 'window.brScreen()', ...CHAT_AND_NOTICES, V2_LANDED, V2_ROOTED,
      v2ClearOfVitals(RADAR_PLACE, CHAT_COLUMN, NOTICE_STACK)],
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

  // Season 1's Market (`?season=1`): the grid as it always was, no dances.
  { name: 'market1/canopies', query: 'season=1', steps: [lobby(), focus('market')] },
  { name: 'market1/canopies-full', query: 'season=1', steps: [lobby(), BIG_MARKET, focus('market')] },
  { name: 'market1/trails', query: 'season=1', steps: [lobby(), focus('market'), press('Trails')] },
  { name: 'market1/finishes', query: 'season=1', steps: [lobby(), focus('market'), press('Finishes')] },
  { name: 'market1/characters', query: 'season=1', steps: [lobby(), focus('market'), press('Characters')] },
  { name: 'market1/banners', query: 'season=1', steps: [lobby(), focus('market'), press('Banners')] },
  // Season 2's Market (#411), the mock's default: each tab design, each of its
  // tabs (real items only, so no Characters or Banners), the buy confirm, the
  // replace dialog on a full wheel, and Preview.
  { name: 'market2/canopies', steps: [lobby(), focus('market'), MK2] },
  { name: 'market2/rail', query: 'tabs=rail', steps: [lobby(), focus('market'), MK2] },
  { name: 'market2/folder', query: 'tabs=folder', steps: [lobby(), focus('market'), MK2] },
  { name: 'market2/trails', steps: [lobby(), focus('market'), MK2, tab2('Smoke trails')] },
  { name: 'market2/finishes', steps: [lobby(), focus('market'), MK2, tab2('Weapon finishes')] },
  { name: 'market2/emotes', steps: [lobby(), focus('market'), MK2, tab2('Emotes')] },
  { name: 'market2/confirm', steps: [lobby(), focus('market'), MK2, BUY2] },
  { name: 'market2/replace', steps: [lobby(), focus('market'), MK2, tab2('Emotes'), press('Equip')] },
  { name: 'market2/preview', steps: [lobby(), focus('market'), MK2, tab2('Emotes'), press('Preview')] },

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
  // Locker v2 is My Looks (#28): the saved looks, New, Stock GTA Looks, the
  // editor and its dialogs, and every Cloudscape menu open.
  { name: 'locker/looks', steps: L2_OPEN },
  { name: 'locker/card-menu', steps: L2_MENU },
  { name: 'locker/rename', steps: [...L2_MENU, `__br.clickText('Rename', '${L2} [role=menu]')`, wait('Rename look', L2)] },
  { name: 'locker/delete', steps: [...L2_MENU, `__br.clickText('Delete', '${L2} [role=menu]')`, wait('Delete Nightshift?', L2)] },
  { name: 'locker/new', steps: L2_NEW },
  { name: 'locker/new-sex', steps: [...L2_NEW, `await __br.mouse('${L2} .lk2-choice-sub button')`, wait('Female', `${L2} [role=listbox]`)] },
  { name: 'locker/stock', steps: [...L2_NEW, `__br.clickText('Stock GTA Looks', '${L2} .lk2-choices')`, press('Create'), wait('Back', L2)] },
  { name: 'locker/editor', steps: L2_EDIT },
  { name: 'locker/top', steps: [...L2_EDIT, line('Top')] },
  { name: 'locker/face', steps: [...L2_EDIT, line('Face'), `__br.clickText('Fine-tune', '${L2} .lk2-panel')`] },
  { name: 'locker/add-more', steps: [...L2_EDIT, press('Add more')] },
  { name: 'locker/tattoos', steps: [...L2_TATS, `await __br.mouse('${L2} .lk2-tatzonepick button')`] },
  {
    name: 'locker/tattoo-names', steps: [...L2_TATS, `await __br.mouse('${L2} .lk2-tatzonepick button')`, option('Torso'),
      `await __br.mouse('${L2} .lk2-tatnew > :not(.lk2-tatzonepick):not(.lk2-icon) button[aria-haspopup]')`],
  },
  { name: 'locker/save', steps: [...L2_EDIT, press('Save'), wait('Name your look', L2)] },
  { name: 'locker/discard', steps: [...L2_EDIT, press('Back'), wait('Discard changes?', L2)] },
  {
    name: 'locker/edit-saved', steps: [...L2_MENU, `__br.clickText('Edit', '${L2} [role=menu]')`, wait('Randomize', L2),
      line('Top'), `__br.click('${L2} .lk2-panel button[aria-label="Next"]')`, press('Save'), wait('Save as new', L2)],
  },

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
  // ...and with the hud piece on (#431), started where UI v2's HUD is away. A
  // held or quick-hidden presence is visibility: hidden, and the walkthrough
  // ends a run whose target it cannot see unless the HUD says its targets are
  // away (hud/v2/HudV2.tsx, V2 4). The walk alone never meets that: the map is
  // App's ui gate, an opacity, and the player list and the inventory page hide
  // nothing in the v2 layers (our pause menu, which it never opens, makes a
  // card wait anyway: App's subscreenUp). So the run starts as in game, on the
  // warmup under the drawn curtain, which holds the HUD, and outlasts the
  // walkthrough's 1.2 s there; then a scope quick-hides the HUD as long; then
  // every card, to the last.
  {
    name: 'tutorial/match-v2', query: 'uiv2=hud', steps: [WARMUP, FEED, PLAYERS,
      `__br.emit('toast', { text: 'Quillon_the_Longest_Name picked up your key', tone: 'success', ms: 600000 })`,
      V2_LANDED, V2_ROOTED, ...V2_UNDER_CURTAIN,
      `__br.emit('tutorial', { run: false, game: true })`,
      tutorialStillOn('the drawn curtain'),
      `__br.emit('leaving', { show: false })`,
      `__br.emit('screen', { scoped: true })`,
      tutorialStillOn('a scope'),
      `__br.emit('screen', { scoped: false })`,
      { walk: 'tutorial/match-v2', min: 21, max: 40 }],
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
const full = !!args.full
const pick = (pairs) => pairs.filter(([ui, t]) => (!args.ui || String(ui) === String(args.ui))
  && (!args.text || String(t) === String(args.text)))
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
 * READY TO MEASURE.
 *
 * A LOOP IS MEASURED AT ITS FIRST FRAME. A pulse or a halo that repeats for
 * ever would otherwise be caught wherever its clock happened to be -- a halo
 * half-grown past a clip in one run, faded out in the next -- and the same
 * page would pass and fail by chance. Its first frame is where every loop
 * here rests and restarts, so it is held there, paused, for the measurement.
 *
 * AND TWO REAL FRAMES FIRST. SETTLE gives up on a frame after 100 ms, which a
 * loaded machine can take. Here the frames are waited for, not timed.
 *
 * THEN EVERY FIT HAS ANSWERED, AND THE PROBE RUNS IN THAT SAME INSTANT.
 * ui/labelFit.ts hides a label from a ResizeObserver, which answers in a
 * frame's rendering steps after layout and before paint -- so the player never
 * sees a label it has not judged, but a measurement taken between a layout and
 * that answer does (a squad name, unmarked and cut 31 px by its own room,
 * failed runs on a loaded box twice, and passed every other). So a Fit whose mark
 * disagrees with its own boxes is waited for, a frame at a time, and the probe
 * runs in the same task as the last look, when every one agrees. One that
 * never does within MAX_FRAMES is measured as it is, and fails: that is the
 * rule not working, not timing.
 */
const MAX_FRAMES = 60
const MEASURE = `(async () => {
  for (const a of document.getAnimations()) {
    try {
      const t = a.effect && a.effect.getComputedTiming()
      if (t && !Number.isFinite(t.endTime)) { a.pause(); a.currentTime = 0 }
    } catch { /* left as it is */ }
  }
  const frame = () => new Promise((r) => requestAnimationFrame(() => r()))
  const waited = (p) => Promise.race([p, new Promise((_, fail) =>
    setTimeout(() => fail(new Error('the page was given no frame in 10 s')), 10000))])
  await waited((async () => { await frame(); await frame() })())
  // ui/labelFit.ts's own test, judge(): fits(label, room), marked ${UNFIT} when not.
  const agree = () => [...document.querySelectorAll('.fit')].every((room) => {
    const label = room.firstElementChild
    if (!label) return true
    const fits = label.getBoundingClientRect().width <= room.getBoundingClientRect().width + ${FIT_SLACK}
    return fits !== room.hasAttribute('${UNFIT}')
  })
  for (let i = 0; i < ${MAX_FRAMES} && !agree(); i++) await waited(frame())
  return window.__brProbe()
})()`

/**
 * Run one screen at one size, Interface size and Text size, from a fresh page:
 * both are the player's before the screen is opened, as they would be in game,
 * and a row that sends settings itself (`...__br.SETTINGS`) keeps them.
 */
async function runScreen(tab, origin, screen, [w, h], ui, text) {
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
  await tab.eval(`__br.SETTINGS = { ...__br.SETTINGS, uiScale: ${ui}, textScale: ${text} };
    __br.emit('settings', __br.SETTINGS)`)
  const measure = async (label) => {
    await settle(tab, 60)
    const r = await tab.eval(MEASURE)
    results.push({ screen: label, at: at(`${w}x${h}`, ui, text), ...r })
    if (shots) {
      const img = await tab.send('Page.captureScreenshot', { format: 'png' })
      writeFileSync(join(shots, `${label.replace(/[^\w-]+/g, '_')}_${w}x${h}_ui${ui}_tx${text}.png`), Buffer.from(img.data, 'base64'))
    }
  }
  const steps = [...screen.steps]
  const last = steps[steps.length - 1]
  if (!steps.length || typeof last !== 'object') steps.push({ probe: screen.name })
  for (const step of steps) {
    if (typeof step === 'string') {
      // A step is done when every press it asked for has happened (the driver's drain).
      await tab.eval(`(async () => { ${step} })().then(() => __br.drain())`)
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
      if (stopped) results.push({ screen: step.walk, at: at(`${w}x${h}`, ui, text), error: stopped, failures: [], hidden: [] })
    }
  }
  return results
}

/**
 * THE CHECK CHECKS ITSELF FIRST, on the lobby in the real bundle. Planted in a
 * clipping box: a border cut by 1 px, one flush with the clip's edge, one a
 * whole pixel clear, one flush with an `overflow: clip` whose clip margin
 * takes the cut out past it, an outline and a spread ring each cut by 1 px, a ::before
 * placed by `left`, an ::after placed by `right` and a ::before moved by a
 * transform, each cut by 1 px, a border flush with an ancestor's clip-path, an
 * unmarked label that wraps and prose marked `data-wrap`. Every one must be
 * judged as it is -- the clear border and the prose pass, the rest fail, each
 * by its own rule. Then a real button squeezed past its label (`Btn`, through
 * ui/Fit.tsx) must hide the label and fail as a blank control, and show it
 * again given the room back; and the Interface size must move rem, or every
 * pair measured at 80% and 130% would be the same page. A probe that saw
 * nothing would pass every screen in the game; this is what stops that being
 * a green build.
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

  // The Interface size moves rem (index.css), or 80% and 130% measure nothing new.
  const rems = await tab.eval(`(async () => {
    const rem = () => parseFloat(getComputedStyle(document.documentElement).fontSize)
    const was = rem()
    __br.emit('settings', { ...__br.SETTINGS, uiScale: 1.3 })
    await new Promise((r) => setTimeout(r, 100))
    const big = rem()
    __br.emit('settings', __br.SETTINGS)
    await new Promise((r) => setTimeout(r, 100))
    return [was, big, rem()]
  })()`)
  if (Math.abs(rems[1] - rems[0] * 1.3) > 0.1 || Math.abs(rems[2] - rems[0]) > 0.01) {
    problems.push(`the Interface size did not move rem: ${rems.join(' -> ')} px at 100%, 130%, 100%`)
  }

  const B = 'border:1px solid #fff'
  await tab.eval(`(() => {
    const css = document.createElement('style')
    css.textContent = '#sc-pseudo::before { content: ""; position: absolute; top: 2px; left: -331px; width: 10px; height: 10px; ${B} }'
      + '#sc-pseudo::after { content: ""; position: absolute; top: 2px; right: -31px; width: 10px; height: 10px; ${B} }'
      + '#sc-move::before { content: ""; position: absolute; top: 0; left: 0; width: 10px; height: 10px; ${B}; transform: translateX(-11px) }'
    document.head.appendChild(css)
    const box = document.createElement('div')
    box.style.cssText = 'position:fixed;left:20px;top:20px;width:400px;height:200px;overflow:hidden;'
      + 'z-index:2147483647;font:16px Barlow;color:#fff'
    const at = (id, css, extra = '') => '<div id="' + id + '" style="position:absolute;' + css + '"' + extra + '></div>'
    box.innerHTML = at('sc-edge', 'left:-1px;top:8px;width:60px;height:20px;${B}')
      + at('sc-flush', 'left:70px;top:0;width:60px;height:20px;${B}')
      + at('sc-clear', 'left:140px;top:1px;width:50px;height:20px;${B}')
      + at('sc-outline', 'left:200px;top:1px;width:50px;height:20px;outline:2px solid #fff')
      + at('sc-ring', 'left:260px;top:1px;width:50px;height:20px;box-shadow:0 0 0 2px #fff')
      + at('sc-pseudo', 'left:330px;top:40px;width:40px;height:20px')
      + at('sc-move', 'left:10px;top:60px;width:40px;height:20px')
      + '<div id="sc-clipper" style="position:absolute;left:100px;top:60px;width:60px;height:30px;clip-path:inset(0)">'
      + at('sc-clipped', 'left:0;top:5px;width:20px;height:10px;${B}') + '</div>'
      + '<div id="sc-margin" style="position:absolute;left:200px;top:60px;width:60px;height:30px;overflow:clip;overflow-clip-margin:3px">'
      + at('sc-margined', 'left:0;top:5px;width:20px;height:10px;${B}') + '</div>'
      + '<div id="sc-wrap" style="position:absolute;left:10px;top:110px;width:70px">A label that wraps</div>'
      + '<div id="sc-prose" data-wrap style="position:absolute;left:120px;top:110px;width:70px">Prose that may wrap</div>'
    box.id = 'sc-box'
    document.body.appendChild(box)
    const m = document.querySelector('[data-tut=market]')
    m.dataset.was = m.style.flex
    m.style.flex = '0 0 14px'
  })()`)
  await settle(tab, 200)
  let r = await tab.eval(MEASURE)
  // The element itself, or one of its pseudo-elements: `#id:nth-of-type(n)::before`.
  const on = (id) => {
    const [el, which = ''] = id.split(/(?=::)/)
    const end = new RegExp(`#${el}(?::nth-of-type\\(\\d+\\))?${which}$`)
    return r.failures.filter((f) => end.test(f.path))
  }
  const expect = (id, test, what) => { if (!on(id).some(test)) problems.push(`${what} was not seen`) }
  expect('sc-edge', (f) => f.rule === 'edge' && /left cut 1\.0px/.test(f.detail), 'a border cut by 1 px')
  expect('sc-flush', (f) => f.rule === 'edge' && /top 0\.0px inside/.test(f.detail), 'a border flush with its clip')
  if (on('sc-clear').length) problems.push(`a border a whole pixel inside its clip was failed: ${on('sc-clear')[0].detail}`)
  if (on('sc-margined').length) problems.push(`a border inside a clip's overflow-clip-margin was failed: ${on('sc-margined')[0].detail}`)
  expect('sc-outline', (f) => /outline/.test(f.what) && /top cut 1\.0px/.test(f.detail), 'an outline cut by 1 px')
  expect('sc-ring', (f) => /ring/.test(f.what) && /top cut 1\.0px/.test(f.detail), 'a ring cut by 1 px')
  expect('sc-pseudo::before', (f) => /left cut 1\.0px/.test(f.detail), 'a ::before cut by 1 px')
  expect('sc-pseudo::after', (f) => /right cut 1\.0px/.test(f.detail), 'an ::after placed by its right, cut by 1 px,')
  expect('sc-move::before', (f) => /left cut 1\.0px/.test(f.detail), 'a ::before moved by a transform, cut by 1 px,')
  expect('sc-clipped', (f) => /clip-path 0\.0px inside/.test(f.detail), "a border flush with an ancestor's clip-path")
  expect('sc-wrap', (f) => f.rule === 'line' && /wraps/.test(f.detail), 'a label that wraps')
  if (on('sc-prose').length) problems.push('prose marked data-wrap was failed')
  if (r.unplaced.length) problems.push(`a pseudo-element could not be placed: ${r.unplaced[0].path}`)
  if (!r.hidden.some((h) => h.text === 'Market')) problems.push('a squeezed button did not hide its label')
  if (!r.failures.some((f) => f.rule === 'blank' && f.text === 'Market')) problems.push('a button whose only label was hidden was not failed as blank')
  const wrong = r.failures.find((f) => f.text === 'Market' && f.rule !== 'blank')
  if (wrong) problems.push(`a squeezed button's label failed as ${wrong.rule}: ${wrong.detail}`)
  await tab.eval(`(() => {
    const m = document.querySelector('[data-tut=market]'); m.style.flex = m.dataset.was
    document.getElementById('sc-box').remove()
  })()`)
  await settle(tab, 200)
  r = await tab.eval(MEASURE)
  if (r.hidden.some((h) => h.text === 'Market')) problems.push('a button given its room back did not show its label')
  if (r.failures.some((f) => f.text === 'Market')) problems.push('a button given its room back still failed')
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
  // EVERY SCREEN AT EVERY SIZE AND PAIR OF SLIDERS IS ONE JOB, and a pool of
  // windows takes them longest first (a walkthrough is dozens of cards), each
  // from a fresh page. `--jobs=N` sets the pool; by default it is the
  // machine's cores, between 6 and 16: a screen spends most of its time
  // waiting for the page to settle, not computing, so a four-core runner
  // still gets six windows.
  const jobs = []
  const pairs = []
  for (const size of sizes) for (const [ui, text] of pick(settingsFor(size, full))) pairs.push({ size, ui, text })
  for (const s of chosen) for (const p of pairs) jobs.push({ s, ...p })
  jobs.sort((a, b) => (b.s.steps.some((x) => x.walk) ? 1 : 0) - (a.s.steps.some((x) => x.walk) ? 1 : 0))
  if (jobs.length === 0) throw new Error('no window size and slider pair matches --size, --ui and --text')
  const workers = Math.max(1, Math.min(jobs.length,
    Number(args.jobs) || Math.max(6, Math.min(16, availableParallelism()))))
  const all = []
  let next = 0
  await Promise.all(Array.from({ length: workers }, async () => {
    const tab = await browser.tab(1920, 1080)
    while (next < jobs.length) {
      const { s, size, ui, text } = jobs[next++]
      let timer
      try {
        const limit = new Promise((_, fail) => { timer = setTimeout(() => fail(new Error('took over 90 s')), 90000) })
        all.push(...await Promise.race([runScreen(tab, server.origin, s, size, ui, text), limit]))
      } catch (e) {
        // The first line: a page's error carries its stack after it.
        all.push({ screen: s.name, at: at(`${size[0]}x${size[1]}`, ui, text), error: e.message.split(/\r?\n/)[0], failures: [], hidden: [] })
      } finally {
        clearTimeout(timer)
      }
    }
  }))
  const order = pairs.map((p) => at(`${p.size[0]}x${p.size[1]}`, p.ui, p.text))
  all.sort((a, b) => order.indexOf(a.at) - order.indexOf(b.at))

  // Group: one line per element and complaint, with every size it fails at.
  const groups = new Map()
  const errors = []
  const hidden = new Map()
  const unplaced = new Map()
  for (const r of all) {
    if (r.error) { errors.push(`${r.screen} at ${r.at}: ${r.error}`); continue }
    for (const f of r.failures) {
      const key = `${r.screen}\u0000${f.rule}\u0000${f.path}\u0000${f.detail.replace(/[\d.]+px/g, 'Npx')}`
      if (!groups.has(key)) groups.set(key, { ...r, ...f, at: [] })
      const g = groups.get(key)
      g.at.push(r.at)
      if (f.px > g.px) { g.px = f.px; g.detail = f.detail }
    }
    for (const hd of r.hidden) {
      const key = `${r.screen}\u0000${hd.path}`
      if (!hidden.has(key)) hidden.set(key, { screen: r.screen, ...hd, at: [] })
      hidden.get(key).at.push(r.at)
    }
    for (const u of r.unplaced || []) {
      const key = `${r.screen}\u0000${u.path}`
      if (!unplaced.has(key)) unplaced.set(key, { screen: r.screen, ...u, at: [] })
      unplaced.get(key).at.push(r.at)
    }
  }

  const probes = all.filter((r) => !r.error).length
  for (const h of hidden.values()) {
    console.log(`  hidden (no room)  ${h.screen}  "${h.text}"  ${h.path}  [${h.at.join(' ')}]`)
  }
  // One cause (a browser gone) can fail every job after it: said once.
  const byCause = new Map()
  for (const e of errors) {
    const cause = e.replace(/^.*?: /, '')
    if (!byCause.has(cause)) byCause.set(cause, [])
    byCause.get(cause).push(e)
  }
  for (const [cause, list] of byCause) {
    for (const e of list.slice(0, 3)) console.error(`FAIL could not draw ${e}`)
    if (list.length > 3) console.error(`FAIL ...and ${list.length - 3} more, all: ${cause}`)
  }
  const title = { edge: (g) => `${g.what} cut`, line: () => 'label', blank: () => 'blank control' }
  for (const g of groups.values()) {
    console.error(`FAIL ${title[g.rule](g)}  ${g.screen}  [${g.at.join(' ')}]`)
    console.error(`     ${g.path}${g.text ? `  "${g.text}"` : ''}`)
    console.error(`     ${g.detail}`)
  }
  for (const u of unplaced.values()) {
    console.error(`FAIL unplaced  ${u.screen}  [${u.at.join(' ')}]`)
    console.error(`     ${u.path}${u.text ? `  "${u.text}"` : ''}`)
    console.error('     a pseudo-element with an edge, in the flow: no box this check can place, so its edge is unmeasured')
  }
  const secs = ((Date.now() - t0) / 1000).toFixed(1)
  const failed = groups.size + unplaced.size
  if (failed === 0 && errors.length === 0) {
    console.log(`check-layout: ${chosen.length} screens x ${pairs.length} window and slider sizes `
      + `(${sizes.length} windows), ${probes} measurements, every border a pixel inside its clips and every label on one line (${secs}s)`)
    status = 0
  } else {
    console.error(`check-layout: ${failed} failures, ${errors.length} screens not drawn, over ${probes} measurements (${secs}s)`)
  }
} finally {
  await browser.close()
  server.close()
  built.remove()
}
process.exit(status)
