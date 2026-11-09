#!/usr/bin/env node
/**
 * THE ELIMS PLATE'S SQUAD LINE, ON BOTH HUDS (#439).
 *
 * Under your own count the Elims plate draws the squad's total, "N squad",
 * while the two differ (hud/Counters.tsx). Each HUD sums that total from the
 * squad payload's rows (hud/Hud.tsx, and UI v2's hud/v2/HudV2.tsx the same
 * way), so it is only as right as the rows. br_core's pushSquadOrParty sent
 * them with no kills: the sum was 0 whatever the squad had done, and under
 * your first kill in a squad match the plate read "0 squad". The rows carry
 * each member's kills now, and tools/test_roster.lua's squad.kills pins that
 * wire. This pins what the page draws from it:
 *
 *   THE TOTAL        every row's kills, yours among them, under your own
 *                    count: "6 squad" under 1, and it moves with a mate's
 *                    kill and with yours.
 *   EVERY STATE      a mate who is down or out still counts: their kills
 *                    were made, and the rows carry them in every state.
 *   EQUAL, NO LINE   nothing under the numeral while the total is yours, your
 *                    first kill with mates on none included: "3 / squad 3" is
 *                    noise (Counters.tsx).
 *   ONE OR NONE      no line for a squad of one (solos deal every player
 *                    their own) or for no squad at all.
 *   NO COUNT         a row that holds none adds none, rather than a NaN.
 *
 * ONE PUSH, BOTH ENVELOPES. Each push below sets the HUD envelope and the
 * squad's rows in one act, because br_core sends them from one handler: a
 * delta that moves the kills of anybody in your squad pushes the squad, then
 * the HUD envelope, at once. Apart, the rows came up to a second behind your
 * count and the plate read "0 squad" under your first kill for that second;
 * the page cannot tell, so tools/test_roster.lua's squad.kills pins the timing.
 *
 * BOTH HUDS, EACH AS App.tsx PICKS IT. Every check runs on today's HUD, drawn
 * with every UI v2 piece off, and on UI v2's (#431, #436), drawn with the
 * store's `uiv2` holding the hud piece, each by the one ternary App.tsx picks
 * them with. A HUD whose sum drifts from the other's fails on its own half.
 *
 * HOW. As scripts/test-hud-conditions.mjs: esbuild bundles the HUDs with the
 * store, scripts/lockerv2-render.mjs's renderer plays React, the store is
 * moved by the setters App.tsx's handlers call, and what is drawn is read
 * back. UI v2's half reads its HUD once every presence has settled. No DOM,
 * no browser.
 *
 * Run: npm run test:squadelims   (and as part of npm run build)
 */

import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { fakePage, hasClass, mount, textOf } from './lockerv2-render.mjs'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')

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

// ── the page ────────────────────────────────────────────────────────────────

const out = await build({
  stdin: {
    contents: [
      "export * as React from 'react'",
      "export { default as Hud } from './src/hud/Hud.tsx'",
      "export { HudLayer } from './src/hud/v2/HudLayer.tsx'",
      "export { useUIv2 } from './src/ui/useUIv2'",
      "export { useUi } from './src/store'",
    ].join('\n'),
    resolveDir: ROOT,
    loader: 'ts',
    sourcefile: 'test-squad-elims-entry.ts',
  },
  bundle: true,
  write: false,
  format: 'esm',
  platform: 'neutral',
  mainFields: ['module', 'main'],
  jsx: 'automatic',
  loader: { '.css': 'empty' },
  define: { 'process.env.NODE_ENV': '"production"', 'import.meta.env.DEV': 'false' },
  logLevel: 'silent',
})

// The clock, held still: one instant for every Date.now, and timers that run
// only when a half says so (test-hud-conditions.mjs's, for the same reasons).
const NOW = 1_800_000_000_000
let page = fakePage()
Date.now = () => NOW
const timers = () => {
  globalThis.setTimeout = globalThis.window.setTimeout
  globalThis.clearTimeout = globalThis.window.clearTimeout
}
timers()
globalThis.setInterval = () => 0
globalThis.clearInterval = () => {}
// UI v2's presences run on performance.now; its half moves it (settle below).
let perf = 0
performance.now = () => perf
// What UI v2's presences ask of an element, for the renderer's stand-ins: no
// transition ever runs, so each phase ends on the clock, inside nothing.
Object.assign(globalThis.Node.prototype, {
  parentElement: null,
  closest() { return null },
  addEventListener() {},
  removeEventListener() {},
  getAnimations() { return [] },
})

const { React, Hud, HudLayer, useUIv2, useUi } = await import(
  `data:text/javascript;base64,${Buffer.from(out.outputFiles[0].text).toString('base64')}`)
const store = () => useUi.getState()
/** The store as the page loads it, for each half to start from. */
const FRESH = useUi.getState()

/** App.tsx's HUD place: one ternary on the hud piece (App.tsx `hud2On`). */
function Place() {
  return useUIv2('hud')
    ? React.createElement(HudLayer, { up: true })
    : React.createElement(Hud, { visible: true })
}

// ── the pushes, as br_core sends them ───────────────────────────────────────

/** A `state` envelope: a squad match, playing. */
const MATCH = { state: 'playing', mode: 'squad', endsAt: NOW + 600_000, serverNow: NOW, participant: true }
/** A `hud` envelope: alive and landed, `kills` my own count. */
const hud = (kills) => ({ hp: 100, armour: 0, alive: 20, squadsAlive: 6, kills, state: 'alive', landed: true }) // wire names: spelling-ok
/** One row of a `squad` envelope, as pushSquadOrParty builds it. `kills`
 *  undefined is a row that holds no count; `state` is the wire's ('dbno' is
 *  down, 'dead' is out). */
const row = (src, name, kills, state = 'alive') => ({
  src, name, state, hp: state === 'alive' ? 100 : 0, armour: 0, colour: '#60A5FA', // wire names: spelling-ok
  ...(kills === undefined ? {} : { kills }),
})
/** A `squad` envelope: my squad, me (1) among its rows. */
const squad = (...members) => ({ id: 'mabcsq1', members, you: 1 })

/**
 * ONE HALF: the page fresh, the hud piece as `v2` says, the HUD App.tsx would
 * draw for it mounted, and every check run against what it draws.
 */
function half(v2) {
  const which = v2 ? "UI v2's HUD (the hud piece on)" : "today's HUD (every UI v2 piece off)"
  useUi.setState(FRESH, true)
  page = fakePage()
  timers()
  store().setUIv2(v2 ? { hud: true } : null)
  const view = mount(React, React.createElement(Place))
  /** UI v2's presences, settled: their clock past every way in and out, and
   *  every timer that is due run, a few rounds for what each one arms. */
  const settle = () => {
    for (let i = 0; i < 4; i++) {
      perf += 5_000
      page.frames()
      view.render()
    }
  }
  const act = (fn) => {
    view.act(fn)
    if (v2) settle()
  }
  /** A squad push and a HUD push, as App.tsx's two handlers take them. */
  const push = (kills, ...members) => act(() => {
    store().setHud(hud(kills))
    store().setSquad(squad(...members))
  })

  /**
   * The Elims plate as the player reads it: its numeral, and what is drawn
   * under its label (the squad line, or nothing). Null where there is not
   * exactly one plate labeled Elims.
   */
  const elims = () => {
    const plates = view.all((n) => hasClass(n, 'plate')
      && n.children.some((c) => typeof c !== 'string' && textOf(c) === 'Elims'))
    if (plates.length !== 1) return null
    const kids = plates[0].node.children.filter((c) => typeof c !== 'string')
    const label = kids.findIndex((c) => textOf(c) === 'Elims')
    return { count: textOf(kids[0]), under: kids.slice(label + 1).map(textOf) }
  }

  console.log(which)
  {
    // A half that drew the other HUD would pass on that one's code: each says
    // which root it drew (as test-hud-conditions.mjs reads it).
    const roots = view.all((n) => n.props['data-layer'] === 'hud')
    check(v2 ? "one HUD root, UI v2's, inside its layer (.hud-v2)" : "one HUD root, today's, with no UI v2 layer anywhere",
      [roots.length, roots.length === 1 && roots[0].parents.some((p) => hasClass(p, 'hud-v2')),
        view.all((n) => hasClass(n, 'hud-v2')).length > 0],
      [1, v2, v2])
  }

  act(() => store().setMatch(MATCH))
  if (v2) settle()

  console.log(`${which}: the squad's total`)
  {
    push(1, row(1, 'Me', 1), row(2, 'Bravo', 2), row(3, 'Charlie', 3, 'dead'))
    check('me on 1, Bravo on 2 and Charlie out on 3: "6 squad" under 1, the mate who is out counted',
      elims(), { count: '1', under: ['6 squad'] })

    push(1, row(1, 'Me', 1), row(2, 'Bravo', 3, 'dbno'), row(3, 'Charlie', 3, 'dead'))
    check('a mate\'s kill moves it, and a mate who is down counts: "7 squad"', elims(), { count: '1', under: ['7 squad'] })

    push(2, row(1, 'Me', 2), row(2, 'Bravo', 3, 'dbno'), row(3, 'Charlie', 3, 'dead'))
    check('and so does mine, under my new count: "8 squad" under 2', elims(), { count: '2', under: ['8 squad'] })

    push(1, row(1, 'Me', 1), row(2, 'Bravo', 2), row(4, 'Delta'))
    check('a row that holds no count adds none: "3 squad", not NaN', elims(), { count: '1', under: ['3 squad'] })
  }

  console.log(`${which}: no line while the total is yours`)
  {
    push(1, row(1, 'Me', 1), row(2, 'Bravo', 0), row(3, 'Charlie', 0))
    check('my first kill, mates on none: 1 and nothing under it, not "0 squad" (#439)', elims(), { count: '1', under: [] })

    push(4, row(1, 'Me', 4), row(2, 'Bravo', 0))
    check('4 of a squad\'s 4: nothing under it', elims(), { count: '4', under: [] })

    push(0, row(1, 'Me', 0), row(2, 'Bravo', 0), row(3, 'Charlie', 0), row(4, 'Delta', 0))
    check('a squad that has none yet: 0 and nothing under it', elims(), { count: '0', under: [] })
  }

  console.log(`${which}: one or no squad`)
  {
    push(2, row(1, 'Me', 2))
    check('a squad of one (solos): no line', elims(), { count: '2', under: [] })

    push(2, row(1, 'Me', 0))
    check('a squad of one draws none whatever its row says', elims(), { count: '2', under: [] })

    act(() => {
      store().setHud(hud(3))
      store().setSquad({ id: null, members: [], you: 1 })
    })
    check('no squad at all: no line', elims(), { count: '3', under: [] })

    push(3, row(1, 'Me', 3), row(2, 'Bravo', 2))
    check('and a squad forming again draws it: "5 squad" under 3', elims(), { count: '3', under: ['5 squad'] })
  }
}

half(false)
half(true)

console.log(`\n${ran - failed}/${ran} passed`)
process.exit(failed ? 1 : 0)
