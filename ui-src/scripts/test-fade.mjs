#!/usr/bin/env node
/**
 * THE LOBBY COMES DOWN WITHOUT THE ANIMATION CLOCK (#252).
 *
 * Owner, 2026-10-03: "the lobby UI doesn't go away when getting into warmup -
 * it only happens if you sit AFK in lobby for a long time, like 30+ minutes or
 * so". The page had the warmup state and kept the menu drawn, because the only
 * thing that took it off the screen was a CSS transition -- run by the
 * browser's animation clock, not by the JS timers and messages that were still
 * working. Stopping that clock in a real Chromium reproduces it exactly.
 *
 * src/ui/fade.ts is the decision: when a layer's fade has had its time on the
 * JS clock, and what the layer looks like before and after. These drive it the
 * way the owner's session did -- shown for 87 minutes, then hidden -- with a
 * fake clock and NO animation event of any kind, which is the point: nothing
 * here can be waiting on one. And src/bridge/screenReport.ts is the one F8 line
 * that says which screen the page is showing; its verdicts are pinned below.
 *
 * WHY node RUNS .ts FILES DIRECTLY. Both have no runtime imports, so node's type
 * stripping loads them as-is -- the same shape as test-chat-clear.mjs.
 *
 * WHAT THIS CANNOT REACH: that the lobby, the curtain and the HUD actually draw
 * from this, and that the report is sent. That half is check-ui rule R26. The
 * two are a pair; do not delete one and keep the other.
 *
 * Run: npm run test:fade   (and as part of npm run build)
 */

import { createFadeClock, fadeStyle, FADE_SETTLE_MARGIN_MS } from '../src/ui/fade.ts'
import { formatScreenLine, showing } from '../src/bridge/screenReport.ts'

let failed = 0
let ran = 0

function check(label, got, expected) {
  ran++
  const ok = JSON.stringify(got) === JSON.stringify(expected)
  if (!ok) failed++
  console.log(
    ok
      ? `  ok    ${label}`
      : `  FAIL  ${label}\n          got      ${JSON.stringify(got)}\n          expected ${JSON.stringify(expected)}`,
  )
}

function has(label, line, part) {
  ran++
  const ok = typeof line === 'string' && line.includes(part)
  if (!ok) failed++
  console.log(ok ? `  ok    ${label}` : `  FAIL  ${label}\n          line     ${line}\n          missing  ${part}`)
}

/** A clock the suite moves by hand. */
function fakeClock(start = 0) {
  let t = start
  return { now: () => t, wait: (ms) => { t += ms } }
}

const LOBBY_MS = 200                                 // Lobby.tsx's LOBBY_FADE_MS
const WINDOW = LOBBY_MS + FADE_SETTLE_MARGIN_MS

// ── the owner's session ─────────────────────────────────────────────────────
console.log('the lobby after an 87-minute idle, with no animation event ever delivered')
{
  const t = fakeClock()
  const lobby = createFadeClock(true, WINDOW, t.now)
  check('a layer is settled on the frame it mounts', lobby.settled, true)
  check('...and draws its final style with no transition',
    fadeStyle(true, lobby.settled, LOBBY_MS),
    { opacity: 1, visibility: 'visible', transition: 'none' })

  t.wait(87 * 60 * 1000)
  check('the ready-up is a change of value', lobby.want(false), true)
  check('the fade out is the one the lobby always drew',
    fadeStyle(false, lobby.settled, LOBBY_MS),
    { opacity: 0, visibility: 'hidden', transition: 'opacity 200ms linear, visibility 0s linear 200ms' })

  t.wait(LOBBY_MS)
  check('at the end of the fade itself it is not yet forced -- a healthy fade finishes first',
    lobby.poll(), false)
  t.wait(FADE_SETTLE_MARGIN_MS)
  check('one margin later it is settled, by the JS clock alone', lobby.poll(), true)
  check('...and the lobby is hidden with NOTHING left for an animation clock to hold',
    fadeStyle(false, lobby.settled, LOBBY_MS),
    { opacity: 0, visibility: 'hidden', transition: 'none' })
}

// ── a level, not an edge ────────────────────────────────────────────────────
console.log('the clock follows the latest value')
{
  const t = fakeClock()
  const c = createFadeClock(true, WINDOW, t.now)
  c.want(false)
  // App re-renders the lobby on every store change, ten times a second in a
  // match. A clock that restarted on each of those would never settle.
  for (let i = 0; i < 3; i++) { t.wait(100); c.want(false) }
  check('re-asserting the same value on every render does not hold the fade open', c.poll(), true)

  c.want(true)
  t.wait(100)
  c.want(false)
  t.wait(WINDOW - 1)
  check('a change inside the window restarts it from the change', c.poll(), false)
  t.wait(1)
  check('...and it settles on the LATEST value', [c.poll(), c.shown], [true, false])

  c.want(true)
  check('remaining() is what the timer is armed with', c.remaining(), WINDOW)
  t.wait(120)
  check('...and counts down', c.remaining(), WINDOW - 120)
  t.wait(10 * 60 * 1000)
  check('a fade asked late -- by the next envelope, with the timer never fired -- settles',
    c.poll(), true)
  check('...and a settled clock has nothing remaining', c.remaining(), 0)
  check('the fade in, settled, is fully drawn with no transition',
    fadeStyle(true, c.settled, LOBBY_MS), { opacity: 1, visibility: 'visible', transition: 'none' })
  check('the fade in, running, is the one the lobby always drew',
    fadeStyle(true, false, LOBBY_MS), { opacity: 1, visibility: 'visible', transition: 'opacity 200ms linear' })
}
{
  const c = createFadeClock(false, WINDOW, fakeClock().now)
  check('a layer mounted hidden is hidden and settled at once', [c.settled,
    fadeStyle(false, c.settled, LOBBY_MS).visibility], [true, 'hidden'])
}

// ── the F8 line ─────────────────────────────────────────────────────────────
console.log('the screen report')

const off = (end) => ({ opacity: 0, visibility: 'hidden', end })
const on = (end) => ({ opacity: 1, visibility: 'visible', end })
const reading = (over) => ({
  match: 'warmup', me: 'warmup', focus: 'none', wanted: 'hud',
  lobby: off('transition'), hud: on('transition'), curtain: { opacity: 0, visibility: 'visible', end: 'transition' },
  frames: 58, frameMs: 500, pageVisible: 'visible', focused: true, upMs: (87 * 60 + 12) * 1000,
  ...over,
})

{
  const line = formatScreenLine(reading({}))
  has('a healthy warmup names the state the page holds', line, 'screen after warmup/warmup:')
  has('...the screen it wants and the one it shows, and agrees', line, 'wanted hud, showing hud -- ok')
  has('...the lobby off, hidden, by its own transition', line, 'lobby off (0 hidden, transition)')
  has('...the HUD on', line, 'hud on (1, transition)')
  has('...the frame count', line, '58 frames in 500ms')
  has('...and how long the page has been up, so a reload cannot hide', line, 'up 87m12s')
  check('one line, always', /[\r\n]/.test(line), false)
  check('short enough that br_ui never has to cut it', line.length < 400, true)
}
{
  // What the page looked like on 2026-10-03 under a stopped animation clock,
  // before this fix: the transition still pending, the menu fully drawn.
  const line = formatScreenLine(reading({ lobby: on('fading'), hud: { opacity: 0, visibility: 'visible', end: 'fading' } }))
  has('the #252 state is called WRONG, by name', line, 'wanted hud, showing LOBBY -- WRONG')
  has('...with the lobby still on and its fade never finished', line, 'lobby on (1 visible, fading)')
}
{
  const line = formatScreenLine(reading({ lobby: off('forced'), hud: on('forced') }))
  has('a stopped clock the fix covered reads ok, and says it had to force it', line,
    'showing hud -- ok | lobby off (0 hidden, forced) | hud on (1, forced)')
}
{
  const line = formatScreenLine(reading({ frames: 0 }))
  has('a page drawing no frames says so -- right styles, old screen', line,
    '0 frames in 500ms (nothing is being drawn)')
}
{
  const r = reading({ match: 'waiting', me: 'lobby', wanted: 'lobby', lobby: on('transition'), hud: off('transition'),
    curtain: { opacity: 1, visibility: 'visible' } })
  check('a curtain still up is what the player sees, over everything', showing(r), 'curtain')
  has('...and is reported as the wrong screen when the lobby was wanted', formatScreenLine(r),
    'wanted lobby, showing CURTAIN -- WRONG')
}
{
  const r = reading({ lobby: { opacity: 0, visibility: 'missing' }, hud: { opacity: 0, visibility: 'missing' },
    curtain: { opacity: 0, visibility: 'missing' } })
  check('a page with none of the layers shows nothing', showing(r), 'nothing')
}

// ── result ──────────────────────────────────────────────────────────────────
if (failed) {
  console.error(`\ntest-fade: ${failed} failure(s) of ${ran} checks`)
  process.exit(1)
}
console.log(`test-fade: ok, ${ran} checks`)
