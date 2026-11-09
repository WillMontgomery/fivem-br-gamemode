#!/usr/bin/env node
/**
 * THE BROADCAST KIT'S CHECKS (#431), on src/ui/broadcast. Run from ui-src (and
 * as part of npm run build):
 *
 *     npm run test:broadcast
 *
 * 1. THE NUMBERS AGREE. motion/tokens.ts holds the curves and durations as
 *    literals (WAAPI cannot read var(), the settle clock needs ms); tokens.css
 *    holds them for CSS. Every pair is pinned here, and --bc-ease-out and
 *    --bc-ease-snap are pinned through to src/index.css's --ease-out and
 *    --ease-snap, so neither copy can drift.
 * 2. EVERY PRESET HAS BOTH HALVES: a TS spec and a CSS rule. The page preset
 *    (the TAB page's and the player list's) is broadcast at twice the speed:
 *    every duration, start and stagger halved, broadcast's hidden values; the
 *    kit exports its name beside its step.
 * 3. THE PRESENCE MACHINE (motion/machine.ts) does what the README's table
 *    says for every change of moment: a leave mid-enter, an enter mid-leave,
 *    a hold, a quick hide, a late joiner, the settle and the landing, and a
 *    scope's way out as one (a leave the scope drove parks until its last).
 * 4. THE CSS KEEPS ITS RULES: every endless animation has its .layer-off line
 *    (check-ui R27), every class is bc- (no Tailwind collision, R8), keyframes
 *    move transform and opacity only (R7, check-ui's list to the letter). A
 *    square plate stands upright: its slant and tan are 0 on it, so its lines
 *    step in by 0; no other rule declares either and nothing registers either
 *    (@property), in a sheet under src or in the built CSS (whatever Tailwind
 *    adds), and no string or template in src's code names either or declares
 *    it. A name built at run time is not read.
 * 5. THE OWNER'S PICKS HOLD (2026-11-03).
 * 6. A NUMBER IN A LABEL LEAVES WITH ITS WORDS; a number standing alone goes
 *    the moment its content starts to leave, under EVERY preset there is.
 *    The cascade a number meets is resolved by specificity, then order, over
 *    every sheet it can meet (the kit's and every other one under src), and
 *    only the kit may set a number's own opacity; motion/label.ts is run on
 *    stand-ins for the cases the screens draw, its way out and back through
 *    every moment; and Numeral and Clock are checked to be wired to both. A
 *    quick hide a page registers (UI v2's TAB page's binvQuick) has
 *    quickHide's hidden values in a rule of its own.
 * 7. THE KIT IN THE GAME. main.tsx imports every stylesheet above App, so the
 *    built CSS has every kit rule after index.css's last; the index.css
 *    keyframes the kit animates with are still there, and every name the kit
 *    defines is its own (a keyframe that took one of index.css's would
 *    replace it); the tokens sit on the kit's root class and never on :root,
 *    and every kit rule lands on what the kit draws (through every :is() and
 *    :where()), so with every UI v2 piece off nothing on screen carries
 *    either; deps.ts is the kit's one door into the rest of src (imports read
 *    off the syntax tree), nothing the kit draws leaves the tree it is mounted
 *    in, and every file that takes a value from the kit is drawn under a
 *    .bc-kit root; and no kit source hands Tailwind a utility of its own, nor
 *    UI v2's other code an important one today's code does not hand it
 *    already.
 * 8. UI V2'S HUD (src/hud/v2). Its sheet matches nothing outside its root and
 *    names its own keyframes; each of App's three places draws a root with
 *    bc-kit and hud-v2 on it, and quick-hides under our pause menu alone
 *    (never hud.paused); each layer says every walkthrough target it
 *    draws is away while it is held or quick-hidden; the notice stack keeps
 *    its place over the TAB page; the three shapes of today's markup it reads
 *    (the wipe's light's two, the Volts balance) are still there;
 *    .hud-safe and the fixed boxes sit under no transform (check-ui R9 and
 *    R12 read today's HUD alone); and the slanted vitals' anchor takes no
 *    channel of its own (their plates carry the kit's).
 * 9. CEF 103 IN UI V2'S CODE: the preview gate's code bans, over the .ts and
 *    .tsx of the kit, of src/hud/v2 and of every other file that takes a value
 *    from the kit (inline styles, WAAPI keyframes, selectors).
 * 10. UI V2'S SQUAD PANEL (src/hud/SquadPanelV2.tsx, #429). Its sheet lands on
 *    the panel alone and names its own keyframes, and it cascades after the
 *    kit; its root carries bc-kit; it takes today's panel's props and draws
 *    today's two walkthrough targets; the three steps that ended on the
 *    animation clock alone (the leave's drop, the death's settle, the FLIP)
 *    each have a JS clock net (#252); the owner's order for a death
 *    (decision 3) is drawn: the key mark and its red line only once their
 *    beat's wait is over, each change read at its time on the row's presence
 *    clock; a squad drawn over another is a new one on air (the panel's scope
 *    keyed by its id); and UI v2's HUD draws it in its squad slot, today's
 *    panel nowhere there, with today's props, under the squad anchor keyed on
 *    the panel's own rule (hasSquad), so the anchor stands down for its rows,
 *    and no ScopeFloor in the slot.
 *
 * node runs the .ts files as-is (type stripping): they have no runtime imports.
 */

import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import ts from 'typescript'
import { BUILT_IN, COUNT, EASE, HALF, LEAVE_STEP, PAGE_PRESET, PAGE_STEP, STEP, T } from '../src/ui/broadcast/motion/tokens.ts'
import {
  begin, drained, enterBase, initialState, landAt, leaveBase, release, rootVars, settle, update, windowOf,
} from '../src/ui/broadcast/motion/machine.ts'
import { CONTROL, LABEL, cameBack, inLabel, runs, wayOf, wayStart } from '../src/ui/broadcast/motion/label.ts'
import { blankComments } from './cef-rules.mjs'

const scripts = dirname(fileURLToPath(import.meta.url))
const SRC = join(scripts, '..', 'src')
const here = join(SRC, 'ui', 'broadcast')
const read = (...p) => readFileSync(join(here, ...p), 'utf8')
const indexCss = readFileSync(join(SRC, 'index.css'), 'utf8')
const tokensCss = read('tokens.css')
const kitCss = read('kit.css')
const motionCss = read('motion.css')
const presetCss = ['drop', 'fade', 'slide'].map((n) => read('motion', `${n}.css`)).join('\n')
// The built CSS: section 4 reads it for the slant, section 7 for the cascade.
const builtCss = readFileSync(join(scripts, '..', '..', 'resources', '[fivem-royale]', 'br_ui', 'ui', 'assets', 'index.css'), 'utf8')

let failed = 0
let ran = 0
function check(label, got, expected) {
  ran++
  const ok = JSON.stringify(got) === JSON.stringify(expected)
  if (!ok) failed++
  console.log(ok
    ? `  ok    ${label}`
    : `  FAIL  ${label}\n          got      ${JSON.stringify(got)}\n          expected ${JSON.stringify(expected)}`)
}

const blank = (css) => css.replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, ' '))
const decl = (css, name) => {
  const m = new RegExp(`(?:^|[\\s;{])${name.replace(/[-]/g, '\\-')}\\s*:\\s*([^;]+);`).exec(blank(css))
  return m ? m[1].trim() : null
}
const bez = (s) => {
  if (s === null) return null
  const m = /cubic-bezier\(([^)]*)\)/.exec(s)
  return m ? m[1].split(',').map((x) => Number(x)) : s.trim()
}
/** Every file under `dir` (no node_modules, nothing hidden). Up here, as
 *  section 4 reads every sheet and source under src as well. */
const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  if (e.name === 'node_modules' || e.name.startsWith('.')) return []
  const p = join(dir, e.name)
  return e.isDirectory() ? walk(p) : [p]
})
const slash = (p) => p.replace(/\\/g, '/')

console.log('1. the numbers agree')
check('EASE.out is index.css --ease-out', bez(EASE.out), bez(decl(indexCss, '--ease-out')))
check('EASE.snap is index.css --ease-snap', bez(EASE.snap), bez(decl(indexCss, '--ease-snap')))
check('--bc-ease-out points at --ease-out', decl(tokensCss, '--bc-ease-out'), 'var(--ease-out)')
check('--bc-ease-snap points at --ease-snap', decl(tokensCss, '--bc-ease-snap'), 'var(--ease-snap)')
for (const name of ['wipe', 'sweep', 'exit', 'fly', 'fall']) {
  check(`EASE.${name} is --bc-ease-${name}`, bez(EASE[name]), bez(decl(tokensCss, `--bc-ease-${name}`)))
}
const kebab = (k) => k.replace(/[A-Z]/g, (c) => `-${c.toLowerCase()}`)
let pinned = 0
for (const [k, ms] of Object.entries(T)) {
  const v = decl(tokensCss, `--bc-t-${kebab(k)}`)
  if (v === null) continue
  pinned++
  check(`T.${k} is --bc-t-${kebab(k)}`, Number.parseFloat(v), ms)
}
check('every T duration CSS also uses is pinned (at least quick, fade, tick, burn, hotDrop)', pinned >= 5, true)
check('STEP is --bc-step', Number.parseFloat(decl(tokensCss, '--bc-step')), STEP)
check('a leave steps at half the step', LEAVE_STEP, STEP / 2)
check('the quick hide is --bc-t-quick, each way', [HALF.quick.root.ms, BUILT_IN.find((p) => p.name === 'quickHide').leave.root.ms], [T.quick, T.quick])
check('drop is index.css hotDrop (620ms)', /animation:\s*hotDrop 620ms/.test(indexCss) && HALF.dropIn.root.ms === 620, true)
check('--bc-t-ramp is .bar-fill (300ms linear)', /transition:\s*transform 300ms linear/.test(indexCss) && Number.parseFloat(decl(tokensCss, '--bc-t-ramp')) === 300, true)
check('a count-up is at most ten writes', COUNT.writes <= 10 && COUNT.writes >= 2, true)

console.log('2. every preset has both halves')
const allCss = blank(tokensCss + kitCss + motionCss + presetCss)
for (const p of BUILT_IN) {
  check(`preset "${p.name}" has its CSS rule`, allCss.includes(`[data-bc-preset="${p.name}"]`), true)
  check(`preset "${p.name}" names all four channels each way`,
    ['root', 'edge', 'surface', 'content'].every((c) => p.enter[c] && p.leave[c]), true)
}
// THE PAGE: broadcast at twice the speed, the one preset for the pages over a
// match (the TAB page and the player list; the owner, 2026-11-04: "make the
// inventory page appear and disappear 2x the speed"). The same choreography,
// only faster: every duration and every start halved, the curves kept, the
// stagger halved too, and broadcast's own hidden values.
const page = BUILT_IN.find((p) => p.name === PAGE_PRESET) ?? null
// ITS NAME IS EXPORTED, beside its step, for the page's scope to name: a name
// nobody registered falls back to broadcast without a word (presets.ts
// getPreset) and lands on the root as data-bc-preset="broadcast", so a page
// that misspelled a literal would play at full speed with every check green.
const kitTokenExports = ts.createSourceFile('index.ts', read('index.ts'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TS)
  .statements.filter((s) => ts.isExportDeclaration(s) && s.moduleSpecifier && ts.isStringLiteral(s.moduleSpecifier)
    && s.moduleSpecifier.text === './motion/tokens' && s.exportClause && ts.isNamedExports(s.exportClause))
  .flatMap((s) => s.exportClause.elements.map((e) => e.name.text))
check('the page preset is named by PAGE_PRESET ("page"), which the kit exports beside PAGE_STEP (index.ts)',
  [PAGE_PRESET, page?.name, ['PAGE_PRESET', 'PAGE_STEP'].filter((n) => !kitTokenExports.includes(n))], ['page', 'page', []])
const halved = (t) => Object.fromEntries(Object.entries(t).map(([c, x]) => [c, { ...x, ms: x.ms / 2, at: x.at / 2 }]))
check('the page preset is onAir and offAir with every duration and every start halved, the curves kept',
  page && [page.enter, page.leave], [halved(HALF.onAir), halved(HALF.offAir)])
check('...in 320 ms and out in 160, half of broadcast\'s each way',
  page && [windowOf(page.enter, 0), windowOf(page.leave, 0), windowOf(HALF.onAir, 0) / 2, windowOf(HALF.offAir, 0) / 2], [320, 160, 320, 160])
check('...a 20 ms stagger each way (PAGE_STEP, the leave step halved), backwards on the way out, and no layer',
  page && [page.step, page.leaveStep, PAGE_STEP, page.reverse, page.layer], [20, 20, LEAVE_STEP / 2, true, false])
/** The declarations of the first rule in a sheet whose selector list holds
 *  `sel`. */
const declsOf = (css, sel) => {
  for (const m of blank(css).matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    if (!members(m[1]).includes(sel)) continue
    return Object.fromEntries([...m[2].matchAll(/([\w-]+)\s*:\s*([^;]+);?/g)].map((d) => [d[1], d[2].trim()]))
  }
  return null
}
check("...and its hidden values are broadcast's, in motion.css",
  [declsOf(motionCss, `[data-bc-preset="${PAGE_PRESET}"]`) !== null, declsOf(motionCss, `[data-bc-preset="${PAGE_PRESET}"]`)],
  [true, declsOf(motionCss, '[data-bc-preset="broadcast"]')])

console.log('3. the presence machine')
const spec = BUILT_IN.find((p) => p.name === 'broadcast')
const WANT = { wanted: true, held: false, quick: false, keep: false }
const ctx = (now, order = 0, scopeStart = Number.NaN, maxOrder = 0) => ({
  now, order, step: spec.step, spec, scopeStart, maxOrder,
})
const mounted = initialState(WANT, true, 0)
check('mounts wanted: a hidden first frame, pending', [mounted.phase, mounted.mounted, mounted.pending], ['hidden', true, true])
check('appear off: mounts shown, no motion', initialState(WANT, false, 0).phase, 'shown')
check('mounts unwanted: absent', initialState({ ...WANT, wanted: false }, true, 0).mounted, false)
check('mounts held: present and hidden', (() => { const s = initialState({ ...WANT, wanted: false, held: true }, true, 0); return [s.phase, s.mounted] })(), ['hidden', true])

const entering = begin(mounted, ctx(0, 3, 0))
check('begins on its turn: order x step', [entering.phase, entering.base, entering.epoch], ['entering', 3 * STEP, 1])
check('outside a scope it still staggers by its order', begin(mounted, ctx(500, 2)).base, 2 * STEP)
check('a late joiner takes the rest of its slot', enterBase(1000, 5, 80, 1300), 100)
check('a late joiner past its slot goes at once (never waits)', enterBase(1000, 2, 80, 1300), 0)
check('a leave runs the stagger backwards at half the step', leaveBase(1, 7, LEAVE_STEP, true), 6 * LEAVE_STEP)

const leaving = update(entering, { ...WANT, wanted: false }, ctx(100, 3, 0, 7))
check('want false while entering: leaves from where it is, at once', [leaving.phase, leaving.base, leaving.land], ['leaving', 0, false])
const back = update(leaving, WANT, ctx(150, 3, 150, 7))
check('want true while leaving: enters from where it is, at once', [back.phase, back.epoch, back.base, back.land], ['entering', 2, 0, false])

const held = update(entering, { ...WANT, wanted: false, held: true }, ctx(50))
check('held while entering: hidden at once, landed, still mounted', [held.phase, held.land, held.mounted], ['hidden', true, true])
const released = update(held, WANT, ctx(500, 3, 500))
check('released: enters in that commit, on its turn', [released.phase, released.pending, released.base], ['entering', false, 3 * STEP])

const shown = settle(entering, false)
check('an entrance settles shown, transitions left on', [shown.phase, shown.land], ['shown', false])
const offAir = update(shown, { ...WANT, wanted: false }, ctx(2000, 3, 0, 7))
check('want false when shown: leaves on its turn, the stagger backwards', [offAir.phase, offAir.base], ['leaving', (7 - 3) * LEAVE_STEP])
check('a stalled entrance lands outright', settle(entering, true).land, true)
const quick = update(shown, { ...WANT, wanted: false, quick: true }, ctx(900))
check('want false in a quick hide: hidden at once, unseen, gone', [quick.phase, quick.land, quick.mounted], ['hidden', true, false])
check('a quick hide alone changes nothing underneath', update(shown, { ...WANT, quick: true }, ctx(900)).phase, 'shown')
const gone = settle(offAir, false)
check('a leave settles hidden and unmounts', [gone.phase, gone.mounted], ['hidden', false])
check('a kept leave stays mounted', settle(update(shown, { ...WANT, wanted: false, keep: true }, ctx(10)), false).mounted, true)
check('want false on a pending first frame: never shown', update(mounted, { ...WANT, wanted: false }, ctx(1)).mounted, false)

check('onAir runs 640 ms from its turn', windowOf(spec.enter, 0), 640)
check('offAir runs 320 ms', windowOf(spec.leave, 0), 320)
check('eight anchors reveal in 1.2 s', windowOf(spec.enter, 7 * STEP), 1200)
check('the content lands at its turn + 640', landAt(entering, spec), 3 * STEP + 640)

const v = rootVars(spec, entering)
check('root vars: a channel starts at its turn + its offset', [v['--bc-edge-delay'], v['--bc-surface-delay'], v['--bc-content-delay']], ['240ms', '320ms', '400ms'])
check('root vars: durations in ms', [v['--bc-edge-ms'], v['--bc-surface-ms'], v['--bc-content-ms']], ['360ms', '420ms', '480ms'])
check('root vars: curves are literals (WAAPI-safe)', v['--bc-surface-ease'], EASE.out)
check('root vars: transitions on while it moves', v['--bc-tp'], undefined)
check('root vars: a landing turns them off', rootVars(spec, held)['--bc-tp'], 'none')
check('root vars: leaving uses the out-half', rootVars(spec, offAir)['--bc-content-ms'], '140ms')
check('root vars: the out-half starts on its turn', rootVars(spec, offAir)['--bc-edge-delay'], `${(7 - 3) * LEAVE_STEP + 120}ms`)

// A SCOPE'S WAY OUT IS ONE: a leave the scope drove that ends while others
// still leave is parked (hidden, its box held), and released by the last.
const parked = settle(offAir, false, true)
check('a leave the scope drove, others still leaving: hidden, parked, still mounted (its box held)',
  [parked.phase, parked.parked, parked.mounted], ['hidden', true, true])
check('released: it goes, as its own leave would have taken it', [release(parked).mounted, release(parked).parked], [false, false])
check('a kept presence is never parked (it stays anyway)',
  settle(update(shown, { ...WANT, wanted: false, keep: true }, ctx(10)), false, true).parked, false)
check('release leaves anything not parked as it is', [release(shown) === shown, release(gone) === gone], [true, true])
const back2 = update(parked, WANT, ctx(3000, 3, 3000))
check('parked, then wanted again: it enters from where it is, no longer parked',
  [back2.phase, back2.mounted, back2.parked], ['entering', true, false])
check('parked, and the inputs change (a quick hide): still mounted, still parked',
  (() => { const q = update(parked, { ...WANT, wanted: false, quick: true }, ctx(3100)); return [q.mounted, q.parked] })(), [true, true])
check('a leave nobody parks unmounts as it ends (as before)', settle(offAir, false).mounted, false)
const calls = []
const d = { leaving: new Set([1, 2]), parked: new Map([[3, () => calls.push(3)], [4, () => calls.push(4)]]) }
drained(d)
d.leaving.delete(1)
drained(d)
check('the drain releases nobody while anything in it still leaves', calls, [])
d.leaving.delete(2)
drained(d)
check('...and every parked presence once the last leave ends, once', [calls, d.parked.size], [[3, 4], 0])
drained(d)
check('...and never twice', calls, [3, 4])

console.log('4. the CSS keeps its rules')
const kit = blank(kitCss)
const loops = []
for (const m of kit.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
  if (!/\binfinite\b/.test(m[2])) continue
  for (const sel of m[1].split(',').map((x) => x.trim()).filter(Boolean)) loops.push(sel)
}
check('the kit has endless animations to check', loops.length > 0, true)
for (const sel of loops) {
  if (sel.startsWith('@')) continue
  check(`"${sel}" is paused under .layer-off`, kit.includes(`.layer-off ${sel}`), true)
}
// The project classes the kit extends. Not .br-cs: the Cloudscape islands
// declare no kit unit while the Market and the Locker are not on the kit.
const ours = new Set(['layer-off', 'btn'])
const classes = new Set()
for (const css of [kit, blank(motionCss), blank(presetCss), blank(tokensCss)]) {
  const noStrings = css.replace(/'[^']*'|"[^"]*"/g, '')
  for (const m of noStrings.matchAll(/(?<![\w-])\.([a-zA-Z][\w-]*)/g)) classes.add(m[1])
}
const stray = [...classes].filter((c) => !c.startsWith('bc-') && !ours.has(c))
check('every class the kit styles is bc- (or a project class it extends)', stray, [])
// R7's list, check-ui's to the letter, and box-shadow, which check-ui reads on
// its own: every side and every size, each in its logical form too
// (inset-inline, inset-block-start, inline-size, max-block-size and the rest).
const R7 = /^(?:(?:min-|max-)?(?:width|height|inline-size|block-size)|top|left|right|bottom|inset(?:-[a-z-]+)?|margin.*|padding.*|box-shadow)$/
const layoutFrames = []
for (const m of kit.matchAll(/@keyframes\s+([\w-]+)\s*\{((?:[^{}]*\{[^{}]*\})*[^{}]*)\}/g)) {
  for (const p of m[2].matchAll(/([a-z-]+)\s*:/g)) if (R7.test(p[1])) layoutFrames.push(`${m[1]}: ${p[1]}`)
}
check('keyframes move transform and opacity only (R7)', layoutFrames, [])
check("...on check-ui R7's own list, to the letter, so the two cannot drift apart (check-ui's let right, bottom, inset and the min- and max- sizes through until #431)",
  R7.source.replace('|box-shadow)', ')'),
  (/^const LAYOUT_PROP = \/(.+)\/$/m.exec(readFileSync(join(scripts, 'check-ui.mjs'), 'utf8')) ?? [])[1] ?? null)
check('a plate line is scoped to its plate (no bare .bc-line rule)',
  [kit.includes('.bc-plate .bc-line {'), /(?:^|\})\s*\.bc-line\s*\{/.test(kit)], [true, false])

// A SQUARE PLATE (Plate shape="square": the hotbar's slots). The slant and
// its tan are 0 on the plate itself, and the kit's own arithmetic does the
// rest. Resolved here as the page resolves it: --bc-lean is declared on every
// plate, so it resolves on the square one; the deck and the cover skew by
// --bc-slant; a line steps in by --bc-tan times its height from each slanted
// edge, then by its pads. The squad row's three lines are measured, the pads
// left out, so what is left is the step along the slant.
/** A calc() in kit units as a number, each var() it reads from `vars`; null
 *  for anything else (a var() it was not given, a unit, no rule at all). */
const calcU = (expr, vars) => {
  const s = String(expr ?? '').replace(/var\((--[\w-]+)\)/g, (_, k) => (typeof vars[k] === 'number' ? `(${vars[k]})` : '?'))
    .replace(/calc\(/g, '(')
  return /^[\d\s.+\-*/()]+$/.test(s) ? Number(Function(`return ${s}`)().toFixed(6)) : null
}
const squareDecls = declsOf(kitCss, '.bc-plate--square')
const lineDecls = declsOf(kitCss, '.bc-plate .bc-line') ?? {}
const plateDecls = declsOf(kitCss, '.bc-plate') ?? {}
const deckDecls = declsOf(kitCss, '.bc-plate__deck') ?? {}
const tanSquare = Number.parseFloat(squareDecls?.['--bc-tan'])
const tanSlant = Number.parseFloat(decl(tokensCss, '--bc-tan'))
const stepIn = (tan) => [[0.68, 0.44], [1.84, 0.44], [2.86, 0.44]].flatMap(([cy, ch]) => {
  const v = { '--bc-h': 3.4, '--bc-cy': cy, '--bc-ch': ch, '--bc-tan': tan, '--bc-pad-l': 0, '--bc-pad-r': 0 }
  return [calcU(lineDecls['padding-left'], v), calcU(lineDecls['padding-right'], v)]
})
check('a square plate (bc-plate--square) sets the slant and its tan to 0 on itself, and nothing else',
  squareDecls, { '--bc-slant': '0deg', '--bc-tan': '0' })
check("a square plate's lines step in by 0 (their pads alone), where a slanted plate's step in along the slant",
  [stepIn(tanSquare), stepIn(tanSlant).every((x) => x !== null && x > 0)], [[0, 0, 0, 0, 0, 0], true])
check('its lean is 0: --bc-lean is declared on every plate from --bc-tan, and is where the deck stops short (either pivot)',
  [plateDecls['--bc-lean'], calcU(plateDecls['--bc-lean'], { '--bc-h': 3.4, '--bc-tan': tanSquare }),
    plateDecls['--bc-deck-r'], declsOf(kitCss, '.bc-plate--head')?.['--bc-deck-l']],
  ['calc(var(--bc-h) * var(--bc-tan))', 0, 'var(--bc-lean)', 'var(--bc-lean)'])
check('its deck and its cover stand upright: both skew by --bc-slant, 0deg on a square plate',
  [deckDecls.transform, declsOf(kitCss, '.bc-plate__cover')?.transform,
    (deckDecls.transform ?? '').replace('var(--bc-slant)', squareDecls?.['--bc-slant'] ?? '?')],
  ['skewX(var(--bc-slant))', 'skewX(var(--bc-slant))', 'skewX(0deg)'])
const plateCode = blankComments(read('Plate.tsx'))
check("Plate puts the class on for shape=\"square\" alone, so a plate that names no shape is drawn as it was (unless it is set inside a square plate: that one's slant and tan reach it too, see below)",
  [(plateCode.match(/bc-plate--square/g) ?? []).length, plateCode.includes("p.shape === 'square' ? 'bc-plate--square' : ''")],
  [1, true])
// NOTHING ELSE SETS THE SLANT. The checks above read the square rule's own
// declarations: a later or a more specific rule that declared either value on
// a plate, a row's override (the preview's way to a square row), an inline
// value (a style, a setProperty, a cssText), a <style> string, a Tailwind
// arbitrary property on a class ([--bc-tan:0], which Tailwind turns into a
// rule), or an @property that turned either's inheritance off (a square
// plate's lines would then read its initial value) would put a square plate
// back on the slant (or stand a slanted one up) and pass them all. So the two
// are declared in two places alone, the kit's root (tokens.css's .bc-kit) and
// a square plate, and registered in none: in every sheet under src (a
// keyframe step included), and in the built CSS, which holds whatever
// Tailwind made of a class in any file it reads (a comment's too: it reads
// raw text). And no string or template in src's code names either or
// declares it. A name built at run time is not read. Neither is declared on
// .bc-plate, which is why a plate set inside a square one is square too
// (kit.css, its rules at the top).
/** Where a sheet declares the slant or its tan, `<rule> { <name> }` (the
 *  innermost rule round it, a keyframe step included), and where it
 *  registers either, `@property <name>`. */
const slantIn = (text) => {
  const css = blank(text)
  const found = [...css.matchAll(/([^{}]*)\{([^{}]*)\}/g)]
    .flatMap((m) => [...m[2].matchAll(/(?<![\w-])(--bc-(?:slant|tan))\s*:/g)].map((d) => `${m[1].trim().replace(/\s+/g, ' ')} { ${d[1]} }`))
  const all = [...css.matchAll(/(?<![\w-])--bc-(?:slant|tan)\s*:/g)].length
  return [...found, ...(all === found.length ? [] : [`${all - found.length} more, outside any rule read here`]),
    ...[...css.matchAll(/@property\s+(--bc-(?:slant|tan))(?![\w-])/g)].map((r) => `@property ${r[1]}`)]
}
const slantDecls = walk(SRC).filter((f) => f.endsWith('.css'))
  .flatMap((f) => slantIn(readFileSync(f, 'utf8')).map((s) => `${slash(relative(SRC, f))}: ${s}`)).sort()
check('the slant and its tan are declared in two places alone, in every sheet under src: the kit root and a square plate (never on .bc-plate, so a plate set inside a square one is square too); and registered (@property) in none',
  slantDecls, [
    'ui/broadcast/kit.css: .bc-plate--square { --bc-slant }', 'ui/broadcast/kit.css: .bc-plate--square { --bc-tan }',
    'ui/broadcast/tokens.css: .bc-kit { --bc-slant }', 'ui/broadcast/tokens.css: .bc-kit { --bc-tan }',
  ])
check('...and the same in the built CSS, whatever Tailwind adds to it (a class carrying [--bc-tan:0] in any file it reads, a comment included)',
  slantIn(builtCss).sort(),
  ['.bc-kit { --bc-slant }', '.bc-kit { --bc-tan }', '.bc-plate--square { --bc-slant }', '.bc-plate--square { --bc-tan }'])
// A string or a piece of a template that names either or declares it, read
// off the syntax tree (a comment that does is not one): an inline value
// through vars() or style, a setProperty, a cssText, a <style> body, a style
// attribute in markup, a class carrying [--bc-tan:0]. Every code file
// Tailwind reads under src (.js, .jsx, .ts, .tsx).
const KIND = { js: ts.ScriptKind.JS, jsx: ts.ScriptKind.JSX, ts: ts.ScriptKind.TS, tsx: ts.ScriptKind.TSX }
const slantWrites = walk(SRC).filter((f) => /\.[jt]sx?$/.test(f)).flatMap((f) => {
  const text = readFileSync(f, 'utf8')
  if (!/--bc-(?:slant|tan)\b/.test(text)) return []
  const sf = ts.createSourceFile(f, text, ts.ScriptTarget.Latest, true, KIND[f.split('.').pop()])
  const out = []
  const visit = (n) => {
    const piece = ts.isStringLiteralLike(n) || ts.isTemplateHead(n) || ts.isTemplateMiddle(n) || ts.isTemplateTail(n)
    if (piece && (/^--bc-(?:slant|tan)$/.test(n.text.trim()) || /(?<![\w-])--bc-(?:slant|tan)\s*:/.test(n.text))) {
      out.push(`${slash(relative(SRC, f))}:${sf.getLineAndCharacterOfPosition(n.getStart(sf)).line + 1}: ${JSON.stringify(n.text)}`)
    }
    ts.forEachChild(n, visit)
  }
  visit(sf)
  return out
}).sort()
check("...and no string or template in src's code names either or declares it (an inline value, a setProperty, a cssText, a <style> body, a class carrying [--bc-tan:0])",
  slantWrites, [])
check('the ramp feed names its own timing (--bc-t-ramp, linear)',
  /\.bc-barline--ramp \.bc-fill\s*\{\s*transition:\s*transform var\(--bc-t-ramp\) linear;/.test(kit), true)

console.log("5. the owner's picks (2026-11-03) hold")
const numeralTsx = read('Numeral.tsx')
const barTsx = read('Bar.tsx')
const vitalsTsx = read('Vitals.tsx')
check('numbers tick in: Numeral reveal defaults to tick', /\breveal = 'tick'/.test(numeralTsx), true)
check("numbers tick in: a bar's numeral defaults to tick", /\bnumReveal = 'tick'/.test(barTsx), true)
check('the vitals are slanted straps on the ramp feed, never pills',
  [/variant="strap"/.test(vitalsTsx), /feed="ramp"/.test(vitalsTsx), /shape=["']pill/.test(vitalsTsx)], [true, true, false])

console.log('6. a number in a label leaves with its words')
// ---------------------------------------------------------------------------
// EVERY SHEET A NUMBER CAN MEET, in the order they cascade: the kit's own
// (index.ts's order), then every other one under src.
// ---------------------------------------------------------------------------
const PAGES = SRC
const inKit = (p) => !relative(here, p).startsWith('..')
const KIT_SHEETS = ['tokens.css', 'kit.css', 'motion.css', 'motion/drop.css', 'motion/fade.css', 'motion/slide.css']
check('every sheet of the kit is in the cascade read here',
  walk(here).filter((p) => p.endsWith('.css')).map((p) => slash(relative(here, p))).filter((f) => !KIT_SHEETS.includes(f)), [])
check('index.ts imports the kit\'s sheets, in that order',
  [...blankComments(read('index.ts')).matchAll(/^import\s+'\.\/([^']+\.css)'$/gm)].map((m) => m[1]), KIT_SHEETS)
const pageFiles = walk(PAGES).filter((p) => !inKit(p))
const pageSheets = pageFiles.filter((p) => p.endsWith('.css')).map((p) => ({ name: slash(relative(PAGES, p)), css: readFileSync(p, 'utf8') }))
const sheets = [
  ...KIT_SHEETS.map((f) => ({ name: `kit/${f}`, css: read(...f.split('/')) })),
  ...pageSheets,
]
check('the other sheets under src are read too (index.css, UI v2\'s HUD\'s, and Locker v2\'s and the Market\'s at least)',
  [pageSheets.some((s) => s.name === 'index.css'), pageSheets.some((s) => s.name === 'hud/v2/hud2.css'), pageSheets.length >= 4],
  [true, true, true])

const STEPS = /^(?:from|to|\d+(?:\.\d+)?%)$/
const rules = []
const frames = new Map()
for (const { name, css } of sheets) {
  const b = blank(css)
  for (const m of b.matchAll(/@keyframes\s+([\w-]+)\s*\{((?:[^{}]*\{[^{}]*\})*[^{}]*)\}/g)) {
    frames.set(m[1], [...m[2].matchAll(/([a-z-]+)\s*:/g)].map((x) => x[1]))
  }
  for (const m of b.matchAll(/([^{}]+)\{([^{}]*)\}/g)) {
    const sels = m[1].trim().split(/,(?![^()]*\))/).map((x) => x.trim().replace(/\s+/g, ' ')).filter(Boolean)
    if (sels.length === 0 || sels.every((s) => STEPS.test(s))) continue
    const decls = {}
    const imp = new Set()
    for (const d of m[2].matchAll(/([\w-]+)\s*:\s*([^;]+);?/g)) {
      const v = d[2].trim()
      if (/!important$/.test(v)) imp.add(d[1])
      decls[d[1]] = v.replace(/\s*!important$/, '')
    }
    rules.push({ sheet: name, sels, decls, imp, at: rules.length })
  }
}

/** A selector's compounds, split on its combinators (never inside [] or ()). */
function compounds(sel) {
  const out = []
  let cur = ''
  let depth = 0
  for (const ch of sel) {
    if (ch === '[' || ch === '(') depth++
    if (ch === ']' || ch === ')') depth--
    if (depth === 0 && /[\s>+~]/.test(ch)) { if (cur) out.push(cur); cur = ''; continue }
    cur += ch
  }
  if (cur) out.push(cur)
  return out
}
/** Specificity [ids, classes + attributes + pseudo-classes, types]: :not(),
 *  :is() and :matches() count their heaviest argument, and :where() counts
 *  nothing (UI v2's HUD scopes its sheet under one, hud/v2/hud2.css). */
function specificity(sel) {
  const n = [0, 0, 0]
  let s = sel.replace(/:where\([^()]*\)/g, ' ')
  s = s.replace(/:(?:not|is|matches)\(([^()]*)\)/g, (_, x) => {
    const k = members(x).map(specificity).sort(bySpec).pop() ?? [0, 0, 0]
    n[0] += k[0]; n[1] += k[1]; n[2] += k[2]
    return ' '
  })
  s = s.replace(/::[\w-]+/g, () => { n[2]++; return ' ' })
  s = s.replace(/\[[^\]]*\]/g, () => { n[1]++; return ' ' })
  s = s.replace(/#[\w-]+/g, () => { n[0]++; return ' ' })
  s = s.replace(/[.:][\w-]+(?:\([^()]*\))?/g, () => { n[1]++; return ' ' })
  n[2] += (s.match(/[a-zA-Z][\w-]*/g) ?? []).length
  return n
}
const bySpec = (a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2]
const outranks = (a, b) => (a.important === b.important ? 0 : a.important ? 1 : -1) || bySpec(a.spec, b.spec) || a.at - b.at
const NUMERAL = /\.(?:bc-num|bc-whole|bc-clock)(?![\w-])/
/** The rules whose rightmost compound can land on a numeral itself. */
const onNumeral = rules.flatMap((r) => r.sels
  .filter((s) => { const c = compounds(s); const last = c[c.length - 1] ?? ''; return NUMERAL.test(last) && !last.includes('::') })
  .map((sel) => ({ ...r, sel })))
check('the numeral rules are found (the kit\'s own and any page\'s live landings)', onNumeral.length > 8, true)

// ONLY THE KIT SETS A NUMBER'S OWN OPACITY AND TIMING. A page may show one
// whole at once (its live landing: opacity 1, transitions off); anything else
// on the number itself -- a dim, a fade, a timing -- outranks or outlasts the
// kit's rules for that number (the Ladder's locked price was a 0.5 that held
// through every way in and out).
const MOTION = /^(?:opacity|visibility|transition(?:-[a-z]+)?)$/
const landing = (d) => Object.keys(d).length === 2 && d.opacity === '1' && d.transition === 'none'
check('no sheet but motion.css sets a number\'s own opacity or timing (a page may only land one whole: opacity 1, transitions off)',
  onNumeral.filter((r) => r.sheet !== 'kit/motion.css' && Object.keys(r.decls).some((p) => MOTION.test(p)) && !landing(r.decls))
    .map((r) => `${r.sheet}: ${r.sel}`), [])
check('an animation on a number moves its transform only (never its opacity: that is the kit\'s)',
  onNumeral.filter((r) => r.decls.animation || r.decls['animation-name']).flatMap((r) => {
    const names = (r.decls['animation-name'] ?? r.decls.animation).split(',').map((a) => a.trim().split(/\s+/).find((w) => frames.has(w)) ?? null)
    return names.filter((k) => k === null || frames.get(k).some((p) => p !== 'transform' && p !== 'animation-timing-function'))
      .map((k) => `${r.sheet}: ${r.sel} -> ${k ?? '(no keyframes found)'}`)
  }), [])
const sources = pageFiles.filter((p) => /\.tsx$/.test(p)).concat(walk(here).filter((p) => /\.tsx$/.test(p)))
/** Each <Numeral .../> or <Clock .../> element's props (braces balanced, so an
 *  arrow function's => does not end it). */
function propsOf(src) {
  const out = []
  for (const m of src.matchAll(/<(?:Numeral|Clock)\s/g)) {
    let depth = 0
    let i = m.index + m[0].length
    for (; i < src.length; i++) {
      const ch = src[i]
      if (ch === '{') depth++
      else if (ch === '}') depth--
      else if (depth === 0 && ch === '>') break
    }
    out.push(src.slice(m.index, i))
  }
  return out
}
check('the props of every Numeral and Clock drawn under src are read (the kit\'s Bar draws one)',
  sources.reduce((n, p) => n + propsOf(readFileSync(p, 'utf8')).length, 0) >= 1, true)
check('no page hands a Numeral or a Clock a class or a style of its own (so the rules above are every rule that can reach it)',
  sources.flatMap((p) => propsOf(readFileSync(p, 'utf8')).filter((t) => /\b(?:className|style)=/.test(t)).map(() => slash(relative(PAGES, p)))), [])

// THE CASCADE A NUMBER MEETS, RESOLVED: its root's variables (every pure root
// rule of every sheet, by specificity then order), then the winning number
// rule's opacity among the kit's (motion.css), by specificity then order.
const ROOT_ATTR = /^\[data-bc-(phase|preset)(?:="([^"]*)")?\]$/
function rootMatch(sel, phase, preset) {
  if (compounds(sel).length !== 1) return false
  const parts = sel.match(/\[[^\]]*\]/g)
  if (!parts || parts.join('') !== sel) return false
  return parts.every((p) => {
    const m = ROOT_ATTR.exec(p)
    if (!m) return false
    return m[2] === undefined || m[2] === (m[1] === 'phase' ? phase : preset)
  })
}
function rootVarsOf(phase, preset) {
  const hits = []
  for (const r of rules) for (const sel of r.sels) if (rootMatch(sel, phase, preset)) hits.push({ ...r, spec: specificity(sel), important: false })
  hits.sort(outranks)
  const out = {}
  for (const r of hits) for (const [k, v] of Object.entries(r.decls)) if (k.startsWith('--')) out[k] = v
  return out
}
function resolveVar(value, vars, depth = 0) {
  if (depth > 12) throw new Error(`var() loop in ${value}`)
  const m = /var\((--[\w-]+)\s*(?:,\s*([^()]*(?:\([^()]*\))?[^()]*))?\)/.exec(value)
  if (!m) return value.trim()
  const got = vars[m[1]] !== undefined ? resolveVar(vars[m[1]], vars, depth + 1) : m[2] !== undefined ? m[2].trim() : 'unset'
  return resolveVar(value.slice(0, m.index) + got + value.slice(m.index + m[0].length), vars, depth + 1)
}
/** Does a compound land on the number `el` ({ cls, attrs, exit })? */
function lands(compound, el) {
  let s = compound
  const nots = []
  s = s.replace(/:not\(([^()]*)\)/g, (_, x) => { nots.push(x); return '' })
  if (/:/.test(s)) return false
  const tag = /^[a-z][\w-]*/.exec(s)?.[0]
  if (tag && tag !== 'span') return false
  for (const m of s.matchAll(/\.([\w-]+)/g)) if (!el.cls.includes(m[1])) return false
  for (const m of s.matchAll(/\[([\w-]+)(?:="([^"]*)")?\]/g)) if (!(m[1] in el.attrs) || (m[2] !== undefined && el.attrs[m[1]] !== m[2])) return false
  return !nots.some((x) => lands(x, el))
}
const numberRules = onNumeral.filter((r) => r.sheet === 'kit/motion.css')
function winner(el, prop) {
  const hits = []
  for (const r of numberRules) {
    if (r.decls[prop] === undefined) continue
    const c = compounds(r.sel)
    if (!lands(c[c.length - 1], el)) continue
    const above = c.slice(0, -1)
    if (!above.every((a) => {
      const attrs = a.match(/\[[^\]]*\]/g) ?? []
      if (attrs.join('') !== a) throw new Error(`motion.css: a number rule over "${a}" cannot be resolved here`)
      return attrs.every((x) => x === '[data-bc-exit]' ? el.exit : /^\[data-bc-(?:phase|preset)\]$/.test(x))
    })) continue
    hits.push({ ...r, spec: specificity(r.sel), important: r.imp.has(prop) })
  }
  hits.sort(outranks)
  return hits[hits.length - 1] ?? null
}
/** A number's opacity and its stepped curve under (phase, preset); `side`:
 *  { run, live, exit, clock }. */
function numberIn(phase, preset, side = {}) {
  const el = {
    cls: side.clock ? ['bc-clock', 'bc-whole'] : ['bc-num', 'bc-whole'],
    attrs: { ...(side.run ? { 'data-bc-run': '' } : null), ...(side.live ? { 'data-bc-live': '' } : null) },
    exit: side.exit === true,
  }
  const vars = rootVarsOf(phase, preset)
  const o = winner(el, 'opacity')
  const ease = winner({ ...el, attrs: {} }, 'transition-timing-function')
  return { o: Number(resolveVar(o.decls.opacity, vars)), ease: resolveVar(ease.decls['transition-timing-function'], vars) }
}

const ruleOf = (sel) => rules.find((r) => r.sheet === 'kit/motion.css' && r.sels.length === 1 && r.sels[0] === sel) ?? null
const wholeRule = ruleOf('.bc-whole')
const runRule = ruleOf('.bc-whole[data-bc-run]')
const liveRule = ruleOf('.bc-whole[data-bc-live]')
check('a number in a label has its own rule, after .bc-whole and before the live rule',
  [runRule !== null, rules.indexOf(wholeRule) < rules.indexOf(runRule), rules.indexOf(runRule) < rules.indexOf(liveRule)],
  [true, true, true])
check('...and it moves nothing but opacity (the content channel carries its slide)',
  runRule ? Object.keys(runRule.decls) : null, ['opacity'])
check('the leave never names --bc-run-o (it holds the shown value through the way out)',
  rules.filter((r) => r.sels.includes('[data-bc-phase="leaving"]') && r.decls['--bc-run-o'] !== undefined).length, 0)
check('every root declares it shown, and only the settled hidden takes the preset\'s content value (a nested presence never inherits its parent\'s)',
  [ruleOf('[data-bc-phase]')?.decls['--bc-run-o'], ruleOf('[data-bc-phase="hidden"]')?.decls['--bc-run-o']],
  ['1', 'var(--bc-pre-content-o)'])
check('a number alone has a hidden value of its own: 0 unless a preset says otherwise',
  [ruleOf('[data-bc-preset]')?.decls['--bc-pre-whole-o'], ruleOf('[data-bc-phase]')?.decls['--bc-whole-o'],
    rules.find((r) => r.sheet === 'kit/motion.css' && r.sels.includes('[data-bc-phase="leaving"]'))?.decls['--bc-whole-o']],
  ['0', '1', 'var(--bc-pre-whole-o)'])
check('broadcast, entering: alone and in a label, each lands with its content (stepped at the end)',
  [numberIn('entering', 'broadcast'), numberIn('entering', 'broadcast', { run: true })],
  [{ o: 1, ease: 'steps(1, end)' }, { o: 1, ease: 'steps(1, end)' }])
check('broadcast, leaving: alone it goes the moment its content starts to leave',
  numberIn('leaving', 'broadcast'), { o: 0, ease: 'steps(1, start)' })
check('broadcast, leaving: in a label it keeps its opacity, so its words take it out',
  numberIn('leaving', 'broadcast', { run: true }).o, 1)
check('broadcast, hidden: both are hidden, ready to land again',
  [numberIn('hidden', 'broadcast').o, numberIn('hidden', 'broadcast', { run: true }).o], [0, 0])
check('a Clock is a number like any other', [numberIn('leaving', 'broadcast', { clock: true }).o, numberIn('leaving', 'broadcast', { clock: true, run: true }).o], [0, 1])
check('a number that changed mid-entrance shows at once (the live rule outranks both)',
  [numberIn('entering', 'broadcast', { live: true }).o, numberIn('hidden', 'broadcast', { live: true, run: true }).o], [1, 1])
check('a page\'s own exit (data-bc-exit): a number alone in it goes at once, in every phase; one in a label rides it with its words',
  [['entering', 'shown', 'leaving'].map((ph) => numberIn(ph, 'broadcast', { exit: true }).o),
    ['shown', 'leaving'].map((ph) => numberIn(ph, 'broadcast', { exit: true, run: true }).o),
    numberIn('entering', 'broadcast', { exit: true, live: true }).o],
  [[0, 0, 0], [1, 1], 0])
const exitRule = numberRules.find((r) => r.sel.startsWith('[data-bc-exit]'))
check('...and it outranks every page\'s live landing (a row that is leaving is not landing), whatever order the sheets come in',
  onNumeral.filter((r) => r.sheet !== 'kit/motion.css' && landing(r.decls))
    .filter((r) => !(exitRule && exitRule.imp.has('opacity') && (!r.imp.has('opacity') || bySpec(specificity(exitRule.sel), specificity(r.sel)) > 0)))
    .map((r) => `${r.sheet}: ${r.sel}`), [])

// EVERY PRESET THERE IS: the kit's, its plug-ins, and every one a page names
// in its CSS or registers in its code.
const cssPresets = new Set()
for (const r of rules) for (const sel of r.sels) for (const m of sel.matchAll(/\[data-bc-preset="([\w-]+)"\]/g)) if (rootMatch(sel, 'shown', m[1])) cssPresets.add(m[1])
const code = pageFiles.filter((p) => /\.tsx?$/.test(p)).concat(walk(here).filter((p) => /\.tsx?$/.test(p))).map((p) => readFileSync(p, 'utf8'))
// A name is a literal, a constant of the file that registers it, or a spec
// (`const X: PresetSpec = { name: ... }`) another file exports.
const constsOf = (src) => new Map([...src.matchAll(/\bconst ([A-Z][A-Z0-9_]*)\s*=\s*'([\w-]+)'/g)].map((m) => [m[1], m[2]]))
const specNames = new Map()
for (const src of code) {
  const own = constsOf(src)
  for (const m of src.matchAll(/\bconst ([A-Z][A-Z0-9_]*)\s*:\s*PresetSpec\s*=\s*\{\s*name:\s*(?:'([\w-]+)'|([A-Z][A-Z0-9_]*))/g)) specNames.set(m[1], m[2] ?? own.get(m[3]))
}
const registered = new Set()
/** A page's registration, as written (its timings), by name. */
const registration = new Map()
for (const src of code) {
  const own = constsOf(src)
  for (const m of src.matchAll(/registerPreset\(\s*(?:\{\s*name:\s*(?:'([\w-]+)'|([A-Z][A-Z0-9_]*))|([A-Z][A-Z0-9_]*)\s*\))/g)) {
    const name = m[1] ?? (m[2] ? own.get(m[2]) : specNames.get(m[3]))
    registered.add(name ?? `?${m[2] ?? m[3]}`)
    if (name) registration.set(name, src.slice(m.index, src.indexOf('})', m.index) + 2))
  }
}
check('every preset a page registers is named (its name read off its code)', [...registered].filter((n) => n.startsWith('?')), [])
const presets = [...new Set([...BUILT_IN.map((p) => p.name), ...cssPresets, ...registered])].sort()
check('the presets checked below include the built-ins and the plug-ins (broadcast, page, quickHide, none, drop, fade, slide)',
  ['broadcast', 'page', 'quickHide', 'none', 'drop', 'fade', 'slide'].filter((n) => !presets.includes(n)), [])
check("the page preset's hidden values are declared once, in the kit's motion.css, for every page that names it (no page sheet of its own)",
  rules.filter((r) => r.sels.some((s) => s.includes('[data-bc-preset="page"]')) && Object.keys(r.decls).some((k) => k.startsWith('--bc-pre-')))
    .map((r) => r.sheet), ['kit/motion.css'])
// A preset that keeps its numbers through its way out says so (--bc-pre-whole-o:
// 1), and may only be a quick hide: its root's opacity alone, on the quick
// hide's own timing (one layer fading as one, 150 ms), never a way off air.
const ownRules = (p) => rules.filter((r) => r.sels.some((s) => s === `[data-bc-preset="${p}"]`))
const keeps = presets.filter((p) => ownRules(p).some((r) => r.decls['--bc-pre-whole-o'] === '1'))
const quickTimed = (p) => {
  const spec = BUILT_IN.find((x) => x.name === p)
  if (spec) return JSON.stringify(spec.leave) === JSON.stringify(HALF.quick)
  return /\bleave:\s*HALF\.quick\b/.test(registration.get(p) ?? '')
}
check(`a preset that keeps its numbers on the way out (${keeps.join(', ')}) is a quick hide: its root's opacity alone, on the quick hide's timing`,
  keeps.filter((p) => !quickTimed(p) || ownRules(p).some((r) => Object.keys(r.decls).some((k) => k !== '--bc-pre-root-o' && k !== '--bc-pre-whole-o'))), [])
// ...AND THE OTHER WAY ROUND, for a quick hide a page registers (its timings
// in its code, HALF.quick): its own rule says what quickHide's says, the root
// hidden and its numbers kept with it. The checks above find a preset that
// keeps its numbers by that rule, so without it they would read the preset as
// an ordinary way off air and pass: the page whole for its 150 ms, then gone.
const pageQuick = [...registered].filter((p) => !BUILT_IN.some((b) => b.name === p) && quickTimed(p)).sort()
check(`every quick hide a page registers (${pageQuick.join(', ')}) hides its root and keeps its numbers in a rule of its own, as quickHide does`,
  pageQuick.filter((p) => !ownRules(p).some((r) => r.decls['--bc-pre-root-o'] === '0' && r.decls['--bc-pre-whole-o'] === '1')), [])
check("...and UI v2's TAB page's way out under the pause menu (binvQuick) is one of them", pageQuick.includes('binvQuick'), true)
for (const p of presets) {
  const kept = keeps.includes(p)
  check(`preset "${p}": ${kept ? 'its quick fade takes a number alone with it' : 'a number alone goes the moment its content leaves, and stays hidden'}`,
    [numberIn('leaving', p).o, numberIn('hidden', p).o], kept ? [1, 1] : [0, 0])
  check(`preset "${p}": a number in a label leaves with its words, never on its own`, numberIn('leaving', p, { run: true }).o, 1)
  check(`preset "${p}": the two land alike (entering and shown)`,
    ['entering', 'shown'].map((ph) => numberIn(ph, p, { run: true }).o === numberIn(ph, p).o), [true, true])
}

// WHICH SIDE A NUMBER FALLS ON (motion/label.ts), on stand-ins for the DOM
// the previews drew: just what the rule reads.
function matches(e, sel) {
  return sel.split(',').some((s) => {
    const m = /^([a-z]*)(?:\.([\w-]+))?(?:\[([\w-]+)(?:="([^"]*)")?\])?$/.exec(s.trim())
    if (!m) throw new Error(`the stand-in cannot match "${s}"`)
    const [, tag, cls, attr, val] = m
    if (tag && e.localName !== tag) return false
    if (cls && !(e.attrs.class ?? '').split(' ').includes(cls)) return false
    if (attr && !(attr in e.attrs)) return false
    return val === undefined || e.attrs[attr] === val
  })
}
const textOf = (n) => (n.nodeType === 3 ? n.nodeValue : n.childNodes.map(textOf).join(''))
const below = (e) => e.childNodes.filter((k) => k.nodeType === 1).flatMap((k) => [k, ...below(k)])
const txt = (s) => ({ nodeType: 3, nodeValue: s, parentElement: null })
function h(tag, attrs = {}, ...kids) {
  const [localName, cls] = tag.split('.')
  const e = {
    nodeType: 1, localName, attrs: cls ? { ...attrs, class: cls.replace(/\+/g, ' ') } : attrs,
    childNodes: kids.map((k) => (typeof k === 'string' ? txt(k) : k)), parentElement: null,
    get textContent() { return textOf(e) },
    querySelector: (sel) => below(e).find((x) => matches(x, sel)) ?? null,
    closest: (sel) => { for (let x = e; x; x = x.parentElement) if (matches(x, sel)) return x; return null },
    contains: (o) => { for (let x = o; x; x = x.parentElement) if (x === e) return true; return false },
  }
  for (const k of e.childNodes) k.parentElement = e
  return e
}
const ROOT = { 'data-bc-phase': 'shown' }
const SAYS = { 'data-bc-label': '' }
const NUM = () => h('span.bc-num+bc-whole')
const sideOf = (build) => { const n = NUM(); build(n); return inLabel(n) ? 'label' : 'alone' }
const CASES = [
  ['players: Send 2 reports (words either side, in a button)', 'label',
    (n) => h('div', ROOT, h('button.bc-btn', {}, h('span.fit', {}, h('span.fit-in', {}, 'Send ', n, ' reports'))))],
  ['Collections: the balance beside its currency', 'label', (n) => h('div', ROOT, h('span.mkc-balance', {}, n, h('span.mkc-currency', {}, 'Volts')))],
  ['Collections: the wheel count "8/8"', 'label', (n) => h('div', ROOT, h('b.mkc-wheel__count', {}, n, h('span', {}, '/8')))],
  ['Collections: a set price beside its struck total', 'label', (n) => h('div', ROOT, h('span.mkc-price', {}, n, h('s', {}, '2,600')))],
  ['Showcase: a clock glyph and its time', 'label', (n) => h('div', ROOT, h('span.shw-clock', {}, h('svg'), n))],
  ['Showcase: a struck price whose strike its box draws in CSS (data-bc-label)', 'label',
    (n) => h('div', ROOT, h('div.shw-hero__act', {}, h('span.shw-was', SAYS, n), h('button', {}, h('span', {}, '4,000'))))],
  ['Showcase: the gated kit\'s price beside its struck total (data-bc-label)', 'label',
    (n) => h('div', ROOT, h('div.shw-hero__act', {}, h('span.shw-was', SAYS, h('span.bc-num')), h('span.shw-hero__dimprice', SAYS, n)))],
  ['Ladder: the level, the whole label of a chip whose plate is its ::before (data-bc-label)', 'label',
    (n) => h('div', ROOT, h('div.mkl-marker', {}, h('i.mkl-marker__needle'), h('span.mkl-marker__chip', SAYS, n)))],
  ['a box that says it is a label OUTSIDE the number\'s presence (it is not what is leaving)', 'alone',
    (n) => h('span', SAYS, h('div', ROOT, h('span', {}, n)))],
  ['a price that is its button\'s whole label', 'label',
    (n) => h('div', ROOT, h('span.mkc-act', {}, h('button', {}, h('span.mkc-btn', {}, h('span.mkc-price', {}, n)))))],
  ['a number beside a glyph on its button (still the whole label)', 'label',
    (n) => h('div', ROOT, h('button', {}, h('svg'), h('span', {}, n)))],
  ['a number that is a kit Tag\'s word', 'label', (n) => h('div', ROOT, h('span.bc-tag', {}, h('span.bc-tag__word', {}, n)))],
  ['a price on a clickable tile that has a name of its own', 'alone',
    (n) => h('div', ROOT, h('div.shw-tile', { role: 'button' }, h('span.shw-tile__name', {}, 'Midnight'), h('span.shw-tile__price', {}, n)))],
  ['a score alone on its plate line', 'alone',
    (n) => h('div', ROOT, h('div.bc-plate', {}, h('span.bc-line', {}, n), h('span.bc-line', {}, h('span', {}, 'Elims'))))],
  ['a slanted bar\'s numeral beside its track', 'alone',
    (n) => h('div', ROOT, h('div.bc-barline', {}, h('div.bc-bar', {}, h('div.bc-track', {}, h('div.bc-fill'))), n))],
  ['a number beside a light sweep only', 'alone', (n) => h('div', ROOT, h('span', {}, n, h('span.shw-fx', {}, h('i.bc-sweep'))))],
  ['a number with only white space beside it', 'alone', (n) => h('div', ROOT, h('span', {}, '  ', n, '\n'))],
  ['a level alone in its span beside the name', 'alone',
    (n) => h('div', ROOT, h('div.bsq-line', {}, h('span.fit', {}, 'Halcyon'), h('span.bsq-level', {}, n)))],
  ['a number whose button holds its whole presence (the button is not leaving)', 'alone',
    (n) => h('button', {}, h('div', ROOT, h('span', {}, n)))],
  ['outside any presence, in a button', 'label', (n) => h('button', {}, h('span', {}, n))],
]
for (const [what, want, build] of CASES) check(`${what}: ${want}`, sideOf(build), want)
check('a control is a button, a link, a checkbox, a tab or the kit\'s Tag',
  CONTROL.split(',').map((s) => s.trim()), ['button', 'a[href]', '[role="button"]', '[role="checkbox"]', '[role="tab"]', '.bc-tag'])
check('a box says it is a label with data-bc-label', LABEL, '[data-bc-label]')

// THE WAY OUT AND BACK (motion/label.ts wayOf), through every moment. A
// presence's moments as a number reads them: { phase, epoch, landAt }.
const M = (phase, epoch, landAt = 640) => ({ phase, epoch, landAt })
const drive = (steps, run = true) => {
  let w = wayStart(steps[0][0])
  const seen = []
  for (const [m, now, live = false] of steps) {
    w = wayOf(w, m, now, run, live)
    seen.push({ draw: runs(run, w), back: cameBack(w) })
  }
  return seen
}
check('mounts in a label while entering: drawn in a label, lands and ticks in (not "back")',
  drive([[M('entering', 1), 0]])[0], { draw: true, back: false })
check('a leave from shown: with its words', drive([[M('entering', 1), 0], [M('shown', 1), 700], [M('leaving', 1), 2000]])[2].draw, true)
check('a leave begun BEFORE its content landed: nothing on screen to take out, so it is hidden as a number alone is (its pending entrance canceled)',
  drive([[M('entering', 1), 0], [M('leaving', 1), 300]])[1].draw, false)
check('a leave begun after its content landed, the entrance not yet settled: with its words',
  drive([[M('entering', 1), 0], [M('leaving', 1), 650]])[1].draw, true)
check('a leave begun before landing, but it had changed and shown at once (live): with its words',
  drive([[M('entering', 1), 0], [M('leaving', 1), 300, true]])[1].draw, true)
check('turned round while still showing: that entrance neither hides it nor ticks it in again',
  drive([[M('shown', 1), 0], [M('leaving', 1), 2000], [M('entering', 2, 2640), 2100]])[2], { draw: true, back: true })
check('turned round after a leave that found it hidden: it lands and ticks in as ever',
  drive([[M('entering', 1), 0], [M('leaving', 1), 300], [M('entering', 2, 990), 350]])[2], { draw: true, back: false })
check('back, then out again before the new landing: still with its words (it never stopped showing)',
  drive([[M('shown', 1), 0], [M('leaving', 1), 2000], [M('entering', 2, 2640), 2100], [M('leaving', 2, 2640), 2200]])[3].draw, true)
check('held while entering (hidden at once), then released: it lands and ticks in',
  drive([[M('entering', 1), 0], [M('hidden', 1), 200], [M('entering', 2, 1300), 660]])[2].back, false)
check('a quick hide from shown (hidden at once, no leave), then back: it lands and ticks in',
  drive([[M('shown', 1), 0], [M('hidden', 1), 900], [M('entering', 2, 1640), 1000]])[2].back, false)
check('a value change mid-leave changes nothing on the way out (same moment, same reading)',
  (() => { const w = wayOf(wayStart(M('shown', 1)), M('leaving', 1), 2000, true, false); return wayOf(w, M('leaving', 1), 2050, true, false) === w })(), true)
check('a leave that ends (hidden): the next entrance is a fresh one',
  drive([[M('shown', 1), 0], [M('leaving', 1), 2000], [M('hidden', 1), 2400], [M('entering', 2, 3640), 3000]])[3], { draw: true, back: false })
check('a number that mounts mid-leave is drawn with its words', runs(true, wayStart(M('leaving', 1))), true)
check('a number alone is never drawn in a label and never "back" (it was hidden as the leave began)',
  drive([[M('shown', 1), 0], [M('leaving', 1), 2000], [M('entering', 2, 2640), 2100]], false), [{ draw: false, back: false }, { draw: false, back: false }, { draw: false, back: false }])

// THE WIRING: Numeral and Clock read their side off their own span after
// every render, carry it through the way out and back, and draw it.
const numeralSrc = blank(numeralTsx.replace(/\/\/[^\n]*/g, ''))
const fn = (name) => new RegExp(`function ${name}\\b[\\s\\S]*?\\n}\\n`).exec(numeralSrc)?.[0] ?? ''
const numeralFn = fn('Numeral')
const clockFn = fn('Clock')
for (const [what, body] of [['Numeral', numeralFn], ['Clock', clockFn]]) {
  check(`${what}: reads its side off its own span (ref on the span it draws, const run = useInLabel(ref))`,
    [/<span\s+ref=\{ref\}/.test(body), /\bconst run = useInLabel\(ref\)\n/.test(body)], [true, true])
  check(`${what}: carries it through the way out and back, and draws that (data-bc-run)`,
    [/\bconst way = useWay\(info, run, /.test(body), (body.match(/data-bc-run=\{runs\(run, way\) \? '' : undefined\}/g) ?? []).length], [true, 1])
}
check('Numeral: hands the way its live entrance, and "back" holds its reveal and its count-up',
  [/useWay\(info, run, s\.liveEpoch\)/.test(numeralFn), /\bconst back = cameBack\(way\)/.test(numeralFn),
    /revealNow = [^\n]*&& !back/.test(numeralFn), /useCountUp\(v, reveal === 'count' && !back/.test(numeralFn)],
  [true, true, true, true])
check('useInLabel reads the DOM after EVERY render (a layout effect with no dependency list)',
  [/useLayoutEffect\(\(\) => \{[\s\S]*?\n {2}\}\)\n/.test(fn('useInLabel')), /\}, \[/.test(fn('useInLabel'))], [true, false])
check('useWay reads the presence\'s clock and the side on every render',
  /wayOf\(w, info, info\.now\(\), run, liveEpoch === w\.epoch\)/.test(fn('useWay')), true)

console.log('7. the kit in the game')
// ---------------------------------------------------------------------------
// THE CASCADE. Vite writes the CSS in the order its modules are first
// reached, so the kit's sheets, imported from App's tree, land after
// index.css only because main.tsx imports every stylesheet above App. The
// other way round the kit comes first, and two of its caption colors lose to
// .micro-label and draw dim.
// ---------------------------------------------------------------------------
const mainTsx = blankComments(readFileSync(join(SRC, 'main.tsx'), 'utf8'))
const appAt = mainTsx.search(/^import App from '\.\/App'$/m)
const sheetImports = [...mainTsx.matchAll(/^import\s+'([^']+\.css)'$/gm)]
check('main.tsx imports index.css above App, and every other stylesheet too',
  [appAt >= 0, sheetImports.some((m) => m[1] === './index.css'), sheetImports.filter((m) => m.index > appAt).map((m) => m[1])],
  [true, true, []])

/** Top-level blocks of a stylesheet, in order: { prelude, body }. */
function topBlocks(css) {
  const out = []
  let depth = 0
  let start = 0
  let open = -1
  for (let i = 0; i < css.length; i++) {
    const c = css[i]
    if (c === '{') { if (depth === 0) open = i; depth++ } else if (c === '}') {
      depth--
      if (depth === 0) { out.push({ prelude: css.slice(start, open).trim(), body: css.slice(open + 1, i) }); start = i + 1 }
    } else if (c === ';' && depth === 0) start = i + 1   // an @tailwind or @import line
  }
  return out
}
// Source and minified CSS read alike: esbuild drops the quotes round an
// attribute's value and the spaces round a combinator, and writes ::after as
// :after.
const norm = (s) => s.replace(/["']/g, '').replace(/::(before|after|first-line|first-letter)\b/g, ':$1')
  .replace(/\s*([>+~,{}:;])\s*/g, '$1').replace(/\s+/g, ' ').trim()
const builtNorm = norm(builtCss)
// Its first appearance: index.css's own, whatever sheet after it repeats the
// selector.
const lastOwn = topBlocks(blank(indexCss)).filter((b) => !b.prelude.startsWith('@')).pop()
const lastAt = lastOwn ? builtNorm.indexOf(`${norm(lastOwn.prelude)}{`) : -1
check("index.css's last rule is found in the built CSS", lastAt >= 0, true)
const kitRules = [
  ...[...builtNorm.matchAll(/(?:^|[{}])([^{}@]*(?:\.bc-|\[data-bc-)[^{}]*)\{/g)].map((m) => ({ at: m.index, what: m[1] })),
  ...[...builtNorm.matchAll(/@(?:keyframes bc[A-Z]\w*|property --bc-[\w-]+)/g)].map((m) => ({ at: m.index, what: m[0] })),
]
check("the built CSS: every kit rule comes after index.css's last rule (none are in it until a screen imports the kit)",
  kitRules.filter((r) => r.at < lastAt).map((r) => r.what).slice(0, 5), [])

// THE KEYFRAMES THE KIT BORROWS. kit.css animates the Stamp's slam, the
// delta badge and the count badge with index.css's own, and nothing else
// pinned the names: renamed there, they would stop without an error.
const KEYWORDS = new Set(['none', 'infinite', 'normal', 'reverse', 'alternate', 'alternate-reverse', 'forwards', 'backwards',
  'both', 'running', 'paused', 'linear', 'ease', 'ease-in', 'ease-out', 'ease-in-out', 'step-start', 'step-end',
  'initial', 'inherit', 'unset'])
const kitFrames = new Set()
const used = new Set()
for (const f of KIT_SHEETS) {
  const b = blank(read(...f.split('/')))
  for (const m of b.matchAll(/@keyframes\s+([\w-]+)/g)) kitFrames.add(m[1])
  for (const m of b.matchAll(/(?:^|[\s;{])animation(?:-name)?\s*:\s*([^;}]+)/g)) {
    for (const entry of m[1].split(/,(?![^()]*\))/)) {
      const words = entry.replace(/[\w-]+\((?:[^()]|\([^()]*\))*\)/g, ' ').trim().split(/\s+/)
        .filter((w) => /^[A-Za-z_][\w-]*$/.test(w) && !KEYWORDS.has(w))
      for (const w of words) used.add(w)
    }
  }
}
const indexFrames = new Set([...blank(indexCss).matchAll(/@keyframes\s+([\w-]+)/g)].map((m) => m[1]))
check("every animation a kit sheet names is defined, in the kit or in index.css",
  [...used].filter((n) => !kitFrames.has(n) && !indexFrames.has(n)), [])
check("the ones it takes from index.css are endSlam, punch and deltaFloat, and index.css still has all three",
  [[...used].filter((n) => !kitFrames.has(n)).sort(), ['deltaFloat', 'endSlam', 'punch'].filter((n) => !indexFrames.has(n))],
  [['deltaFloat', 'endSlam', 'punch'], []])

// AND EVERY NAME THE KIT DEFINES IS ITS OWN. A keyframe's name is global and
// the last sheet to define it wins: the kit's land after index.css's, so a
// kit keyframe that took one of index.css's names, or Tailwind's, HeroUI's or
// Cloudscape's, would replace today's animation with every piece off.
const globals = KIT_SHEETS.flatMap((f) => [...blank(read(...f.split('/'))).matchAll(/@([\w-]+)\s*([^\s{;]*)/g)]
  .map((m) => ({ f, at: m[1], name: m[2] })))
check("every name a kit sheet defines is the kit's own: a @keyframes is bc and a capital, a @property --bc-, and no other at-rule names anything",
  globals.filter(({ at, name }) => !(at === 'keyframes' && /^bc[A-Z]\w*$/.test(name)) && !(at === 'property' && /^--bc-[\w-]+$/.test(name))
    && at !== 'media' && at !== 'supports').map(({ f, at, name }) => `${f}: @${at} ${name}`), [])
check('no other sheet under src defines a keyframe the kit defines',
  pageSheets.flatMap((s) => [...blank(s.css).matchAll(/@keyframes\s+([\w-]+)/g)].filter((m) => kitFrames.has(m[1])).map((m) => `${s.name}: ${m[1]}`)), [])

// THE TOKENS SIT ON THE KIT'S ROOT, NEVER ON :root (#431).
// Some 215 custom properties on the document root would ride every element
// of every screen with every UI v2 piece off; Cloudscape's on <body> made
// every lobby restyle 17% dearer (screens/lockerv2/sheet.ts). On .bc-kit they
// sit on what the kit draws, and only while a screen built on it is mounted.
/** A selector list's members: split at its top-level commas, never inside
 *  (), [] or a string. */
function members(list) {
  const out = []
  let depth = 0
  let quote = ''
  let cur = ''
  for (const c of list) {
    if (quote) { if (c === quote) quote = '' } else if (c === '"' || c === "'") quote = c
    else if (c === '(' || c === '[') depth++
    else if (c === ')' || c === ']') depth--
    else if (c === ',' && depth === 0) { out.push(cur); cur = ''; continue }
    cur += c
  }
  out.push(cur)
  return out.map((s) => s.trim().replace(/\s+/g, ' ')).filter(Boolean)
}
const ruleSels = (css) => [...blank(css).matchAll(/([^{}]+)\{([^{}]*)\}/g)]
  .flatMap((m) => members(m[1]))
  .filter((s) => !STEPS.test(s) && !s.startsWith('@'))
check('the tokens are declared on .bc-kit alone, and the lengths that re-resolve on [data-bc-u] too: never :root, never an island',
  [...new Set(ruleSels(tokensCss))], ['.bc-kit', '[data-bc-u]'])
check('the derived lengths re-resolve on both (the unit trap: a var() resolves where it is declared)',
  [decl(tokensCss, '--bc-u'), /\.bc-kit,\s*\[data-bc-u\]\s*\{[^}]*--bc-slab-w:/.test(blank(tokensCss))], ['1rem', true])

// EVERY KIT RULE LANDS ON WHAT THE KIT DRAWS: on an element of the kit's (a
// bc- class or a data-bc- attribute) or inside one. A :not() or a :has()
// holding one is no kit element, and an :is() or a :where() is one only when
// every alternative is: `:is(.bc-plate, div)` lands on every div there is.
/** One complex selector as [compound, combinator, compound, ...]. */
function chain(sel) {
  const parts = []
  let depth = 0
  let quote = ''
  let cur = ''
  let comb = ''
  for (const c of sel.trim()) {
    if (!quote && depth === 0 && /[\s>+~]/.test(c)) {
      if (cur) { parts.push(cur); cur = ''; comb = ' ' }
      if (/[>+~]/.test(c) && parts.length) comb = c
      continue
    }
    if (comb) { parts.push(comb); comb = '' }
    if (quote) { if (c === quote) quote = '' } else if (c === '"' || c === "'") quote = c
    else if (c === '(' || c === '[') depth++
    else if (c === ')' || c === ']') depth--
    cur += c
  }
  if (cur) parts.push(cur)
  return parts
}
/** Does every element a compound can match belong to the kit (it is one of
 *  the kit's, or sits inside one)? */
function compoundKit(compound) {
  let rest = ''
  const lists = []
  for (let i = 0; i < compound.length;) {
    const close = compound[i] === '[' ? ']' : null
    const fn = close ? null : /^::?([\w-]+)\(/.exec(compound.slice(i))
    if (!close && !fn) { rest += compound[i++]; continue }
    let j = close ? i + 1 : i + fn[0].length
    let depth = 1
    let quote = ''
    for (; j < compound.length && depth > 0; j++) {
      const d = compound[j]
      if (quote) { if (d === quote) quote = '' } else if (d === '"' || d === "'") quote = d
      else if (!close && d === '(') depth++
      else if (d === (close ?? ')')) depth--
    }
    if (close) rest += compound.slice(i, j)
    else if (!fn[0].startsWith('::') && /^(?:is|where|matches|-webkit-any|-moz-any)$/.test(fn[1])) lists.push(compound.slice(i + fn[0].length, j - 1))
    i = j
  }
  return /\.bc-|\[data-bc-/.test(rest) || lists.some((l) => members(l).every(inKitTree))
}
/** ...and does every element a selector can match? Its subject belongs to
 *  the kit, or a compound left of it that does is its ancestor: the
 *  combinator just right of that compound is a descendant's or a child's. */
function inKitTree(sel) {
  const parts = chain(sel)
  const last = parts.length - 1
  if (last < 0) return false
  if (compoundKit(parts[last])) return true
  for (let k = last - 2; k >= 0; k -= 2) if ((parts[k + 1] === ' ' || parts[k + 1] === '>') && compoundKit(parts[k])) return true
  return false
}
check('every rule of every kit sheet lands on what the kit draws: an element with a bc- class or a data-bc- attribute (never one a :not() or a :has() holds, in every alternative of an :is() or a :where()), or one inside it',
  KIT_SHEETS.flatMap((f) => ruleSels(read(...f.split('/'))).filter((s) => !inKitTree(s)).map((s) => `${f}: ${s}`)), [])

// WHAT A FILE IMPORTS, READ OFF ITS SYNTAX TREE: every import and every
// export from a module (each { spec, type }, `type` for one that draws
// nothing: `import type`, `export type`, or every name in it a type), a bare
// side-effect import, an import() or a require(), and an import() in a type's
// place (a type). A string, a comment or JSX text that reads like one is not
// one: read as text, Plate.tsx's `'--from'` key ended in `from'` and paired
// with the next quote in the file, an import nobody wrote.
function importsIn(file, text = readFileSync(file, 'utf8')) {
  const sf = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true,
    file.endsWith('.tsx') ? ts.ScriptKind.TSX : ts.ScriptKind.TS)
  const out = []
  const allTypes = (els) => els.length > 0 && els.every((e) => e.isTypeOnly)
  const visit = (n) => {
    if (ts.isImportDeclaration(n) && ts.isStringLiteral(n.moduleSpecifier)) {
      const c = n.importClause
      out.push({ spec: n.moduleSpecifier.text, type: !!c && (c.isTypeOnly
        || (!c.name && !!c.namedBindings && ts.isNamedImports(c.namedBindings) && allTypes(c.namedBindings.elements))) })
    } else if (ts.isExportDeclaration(n) && n.moduleSpecifier && ts.isStringLiteral(n.moduleSpecifier)) {
      out.push({ spec: n.moduleSpecifier.text, type: n.isTypeOnly
        || (!!n.exportClause && ts.isNamedExports(n.exportClause) && allTypes(n.exportClause.elements)) })
    } else if (ts.isImportEqualsDeclaration(n) && ts.isExternalModuleReference(n.moduleReference)
      && ts.isStringLiteral(n.moduleReference.expression)) {
      out.push({ spec: n.moduleReference.expression.text, type: n.isTypeOnly })
    } else if (ts.isCallExpression(n) && (n.expression.kind === ts.SyntaxKind.ImportKeyword
      || (ts.isIdentifier(n.expression) && n.expression.text === 'require'))
      && n.arguments.length > 0 && ts.isStringLiteralLike(n.arguments[0])) {
      out.push({ spec: n.arguments[0].text, type: false })
    } else if (ts.isImportTypeNode(n) && ts.isLiteralTypeNode(n.argument) && ts.isStringLiteral(n.argument.literal)) {
      out.push({ spec: n.argument.literal.text, type: true })
    }
    ts.forEachChild(n, visit)
  }
  visit(sf)
  return out
}
check('imports are read off the syntax tree in every form (import, export from, a bare one, import(), require(), a type\'s), and never out of a string or JSX text',
  importsIn('probe.tsx', [
    "import a from 'x1'", "import type { B } from 'x2'", "import { type C } from 'x3'", "import 'x4'",
    "export { d } from 'x5'", "export type { E } from 'x6'", "export * from 'x7'", "const f = import('x8')",
    "const g = require('x9')", "type H = typeof import('x10')",
    "const s = { '--from': n }; const t = 'from'; const v = <i>from 'nowhere' import 'nothing'</i>",
  ].join('\n')).map((i) => `${i.spec}${i.type ? ' (type)' : ''}`),
  ['x1', 'x2 (type)', 'x3 (type)', 'x4', 'x5', 'x6 (type)', 'x7', 'x8', 'x9', 'x10 (type)'])

// THE ONE DOOR. Every kit file imports its siblings and React; deps.ts alone
// reaches the rest of src, and nothing else does. A type import counts: it is
// the rest of src all the same.
const kitCode = walk(here).filter((p) => /\.tsx?$/.test(p))
const doors = []
for (const f of kitCode) {
  const name = slash(relative(here, f))
  for (const { spec } of importsIn(f)) {
    if (!spec.startsWith('.')) { if (spec !== 'react') doors.push(`${name}: ${spec}`); continue }
    const inside = !relative(here, resolve(dirname(f), spec)).startsWith('..')
    if (inside === (name === 'deps.ts')) doors.push(`${name}: ${spec}`)
  }
}
check("the kit's imports are read (deps.ts's doors, index.ts's sheets)",
  [importsIn(join(here, 'deps.ts')).filter((i) => i.spec.startsWith('../')).length >= 5,
    importsIn(join(here, 'index.ts')).filter((i) => i.spec.endsWith('.css')).map((i) => i.spec.slice(2))], [true, KIT_SHEETS])
check('deps.ts is the one door to the rest of src: every other kit file imports its siblings and React', doors, [])
check("nothing the kit draws leaves the tree it is mounted in (no createPortal, no document.body), so a screen root's .bc-kit reaches all of it",
  kitCode.filter((f) => /\bcreatePortal\b|\bdocument\.body\b/.test(blankComments(readFileSync(f, 'utf8')))).map((f) => slash(relative(here, f))), [])

// AND A SCREEN ON THE KIT CARRIES THAT ROOT. The tokens are declared on
// .bc-kit alone, so a kit element drawn outside every .bc-kit draws with each
// var(--bc-*) unset (no color, no size, no timing), and only while its piece
// is on. A file outside the kit that takes a value from it sets the class on
// what it draws, or every file that imports it does, all the way up. Read per
// file: one that sets the class on one root and draws a second root bare
// still passes here. A type import draws nothing and is not read.
const srcCode = walk(SRC).filter((p) => /\.tsx?$/.test(p))
const known = new Set(srcCode)
const target = (from, spec) => {
  const base = spec.startsWith('@/') ? join(SRC, spec.slice(2)) : spec.startsWith('.') ? resolve(dirname(from), spec) : null
  return base === null ? null
    : [base, `${base}.ts`, `${base}.tsx`, join(base, 'index.ts'), join(base, 'index.tsx')].find((p) => known.has(p)) ?? null
}
const codeOf = new Map(srcCode.map((f) => [f, blankComments(readFileSync(f, 'utf8'))]))
// Off the syntax tree (importsIn, above), as the door is.
const takes = new Map(srcCode.map((f) => [f, importsIn(f).filter((i) => !i.type).map((i) => target(f, i.spec)).filter(Boolean)]))
const importers = new Map(srcCode.map((f) => [f, srcCode.filter((g) => takes.get(g).includes(f))]))
/** Is `f` drawn under .bc-kit: it sets the class, or every file that imports
 *  it is? Round an import cycle, the files outside the cycle decide. */
function rooted(f, path = new Set()) {
  if (/(?<![\w-])bc-kit(?![\w-])/.test(codeOf.get(f)) || path.has(f)) return true
  const up = importers.get(f)
  path.add(f)
  const ok = up.length > 0 && up.every((g) => rooted(g, path))
  path.delete(f)
  return ok
}
const onKit = srcCode.filter((f) => !inKit(f) && takes.get(f).some(inKit))
check(`every file outside the kit that takes a value from it is drawn under .bc-kit: it sets the class, or every file that imports it is (${onKit.length} such files)`,
  onKit.filter((f) => !rooted(f)).map((f) => slash(relative(SRC, f))), [])

// TAILWIND READS EVERY .ts AND .tsx UNDER src AS TEXT, comments and all, and
// a bang before a utility's name is its important modifier: QuickHide's
// negation of `hidden` was the one rule the kit added to the bundle. UI v2's
// other code is read the same way: src/hud/v2, and every file outside the kit
// that takes a value from it, so a later port is read as it lands. It may
// carry Tailwind classes (the v2 HUD is today's markup), but no important
// utility today's code does not hand Tailwind already: Hud.tsx's and
// Chat.tsx's `!visible` put one in the bundle with every piece off, and a
// file of today's that comes to take from the kit brings its own along.
const BARE = ['hidden', 'block', 'inline', 'flex', 'grid', 'table', 'contents', 'flow-root', 'visible', 'invisible',
  'collapse', 'static', 'fixed', 'absolute', 'relative', 'sticky', 'isolate', 'truncate', 'italic', 'underline',
  'overline', 'uppercase', 'lowercase', 'capitalize', 'container', 'shadow', 'border', 'rounded', 'outline', 'ring',
  'blur', 'grow', 'shrink', 'transform', 'transition', 'filter', 'invert', 'grayscale', 'sepia']
const bang = new RegExp(`(?<![\\w-])!(?:${BARE.join('|')})(?![\\w-])`, 'g')
const bangs = (f) => [...readFileSync(f, 'utf8').matchAll(bang)].map((m) => m[0])
check('no kit source hands Tailwind an important utility (a bang before a utility\'s name)',
  kitCode.flatMap((f) => bangs(f).map((b) => `${slash(relative(here, f))}: ${b}`)), [])
const V2 = join(SRC, 'hud', 'v2')
const v2Own = [...new Set([...walk(V2).filter((p) => /\.tsx?$/.test(p)), ...onKit])]
const todaysBangs = new Set(srcCode.filter((f) => !inKit(f) && !v2Own.includes(f)).flatMap(bangs))
check(`nor does UI v2's other code, src/hud/v2 and every file outside the kit that takes a value from it (${v2Own.length} files), but for one today's code hands it already`,
  v2Own.flatMap((f) => bangs(f).filter((b) => !todaysBangs.has(b)).map((b) => `${slash(relative(SRC, f))}: ${b}`)), [])

console.log("8. UI v2's HUD (src/hud/v2)")
// ---------------------------------------------------------------------------
// ITS SHEET IS UNDER ITS ROOT. hud2.css lands after index.css's rules and the
// kit's, and with the hud piece off it must match nothing: every rule sits
// under :where(.hud-v2), the class each of HudLayer.tsx's roots carries, and
// every keyframe it defines is its own (one that took another sheet's name
// would replace that animation with every piece off). Under it means the root
// itself, or inside it: a sibling's combinator (~, +) after the root would
// land on App's next places, today's among them, while the hud piece is on.
// ---------------------------------------------------------------------------
const v2Code = (f) => codeOf.get(join(V2, f)) ?? ''
const hud2Css = readFileSync(join(V2, 'hud2.css'), 'utf8')
const V2_ROOT = ':where(.hud-v2)'
const v2Sels = ruleSels(hud2Css)
const underRoot = (s) => { const c = chain(s); return c[0] === V2_ROOT && (c.length === 1 || c[1] === ' ' || c[1] === '>') }
check('hud2.css: every rule is scoped under the v2 root (:where(.hud-v2): the root itself, or inside it, never a sibling of it)',
  [v2Sels.length > 20, v2Sels.filter((s) => !underRoot(s))], [true, []])
const v2Frames = [...blank(hud2Css).matchAll(/@keyframes\s+([\w-]+)/g)].map((m) => m[1])
const otherFrames = new Set(pageSheets.filter((s) => s.name !== 'hud/v2/hud2.css')
  .flatMap((s) => [...blank(s.css).matchAll(/@keyframes\s+([\w-]+)/g)].map((m) => m[1])))
check("hud2.css: every keyframe it defines is its own (hud and a capital), never another sheet's or the kit's",
  v2Frames.filter((n) => !/^hud[A-Z]\w*$/.test(n) || otherFrames.has(n) || kitFrames.has(n)), [])
const v2Used = new Set()
for (const m of blank(hud2Css).matchAll(/(?:^|[\s;{])animation(?:-name)?\s*:\s*([^;}]+)/g)) {
  for (const w of m[1].replace(/[\w-]+\((?:[^()]|\([^()]*\))*\)/g, ' ').trim().split(/\s+/)) {
    if (/^[A-Za-z_][\w-]*$/.test(w) && !KEYWORDS.has(w)) v2Used.add(w)
  }
}
check("hud2.css: every animation it names is defined, in it or in the kit (the slanted vitals' light runs the kit's bcCross)",
  [[...v2Used].sort(), [...v2Used].filter((n) => !v2Frames.includes(n) && !kitFrames.has(n))], [['bcCross', 'hudWipeSweep'], []])

// ITS ROOTS CARRY THE KIT. The per-file rule in section 7 passes a file that
// sets bc-kit on one root and draws a second bare, so App's three places are
// each read here: a root of their own, with bc-kit (the kit's tokens) and
// hud-v2 (hud2.css's scope), and HudV2's own root carries bc-kit too.
const layerTsx = v2Code('HudLayer.tsx')
const hudV2Tsx = v2Code('HudV2.tsx')
const layers = [...layerTsx.matchAll(/^export function (\w+)\(/gm)].map((m) => m[1])
/** One top-level function of `src`, to the next one. */
const fnBody = (src, name) => {
  const at = src.search(new RegExp(`^(?:export )?function ${name}\\(`, 'm'))
  if (at < 0) return ''
  const next = src.slice(at + 1).search(/^(?:export )?function /m)
  return src.slice(at, next < 0 ? undefined : at + 1 + next)
}
const rootClass = (name) => (/\breturn \(\s*<div\s+className="([^"]*)"/.exec(fnBody(layerTsx, name))?.[1] ?? '').split(/\s+/)
check("HudLayer.tsx: App's three places, each a layer of its own", layers, ['HudLayer', 'ChatLayer', 'NoticesLayer'])
check('each of them draws its own root, with bc-kit and hud-v2 on it',
  layers.filter((n) => !rootClass(n).includes('bc-kit') || !rootClass(n).includes('hud-v2')), [])
check('HudV2.tsx\'s root (data-layer="hud") carries bc-kit as well',
  /\bdata-layer="hud"\s+className=\{`bc-kit\s/.test(hudV2Tsx), true)

// OUR PAUSE MENU QUICK-HIDES ALL THREE, AND ONLY OURS (the port's call for UI
// v2's HUD). GTA's map and menus are App's ui gate, round everything, and
// App hands no layer `!hudPaused` (check-ui R26d). Here: each layer takes
// `paused` from usePauseOpen, which is our pause menu alone (s.focus, never
// hud.paused, which trails GTA's edge by up to a push), and draws its want
// inside <QuickHide hidden={paused}>, inside the curtain's hold. A layer
// without it would stay up over our pause menu; one on hud.paused would hide
// again, late, under GTA's.
check("usePauseOpen is our pause menu alone: useUi((s) => s.focus === 'pause')",
  /^function usePauseOpen\(\): boolean \{\s*return useUi\(\(s\) => s\.focus === 'pause'\)\s*\}/m.test(layerTsx), true)
check('each layer quick-hides on it round its want: `const paused = usePauseOpen()`, and one'
  + ' <QuickHide hidden={paused}> between <PresenceScope hold={held} preset={PRESET}> and <PresenceScope want={..}>',
  layers.filter((n) => {
    const b = fnBody(layerTsx, n)
    return !/\bconst paused = usePauseOpen\(\)/.test(b) || (b.match(/<QuickHide\b/g) ?? []).length !== 1
      || !/<PresenceScope hold=\{held\} preset=\{PRESET\}>\s*<QuickHide hidden=\{paused\}>\s*<PresenceScope want=\{\w+\}>/.test(b)
  }), [])
check("...and no code in src/hud/v2 reads hud.paused: the v2 HUD hides on GTA's edge by the ui gate alone",
  walk(V2).filter((p) => /\.tsx?$/.test(p) && /\bhud\.paused\b|\bhudPaused\b/.test(codeOf.get(p) ?? '')).map((p) => slash(relative(SRC, p))), [])

// THE WALKTHROUGH'S TARGETS ARE AWAY WHILE A LAYER IS HELD OR QUICK-HIDDEN
// (HudV2.tsx, V2 4). A held or quick-hidden presence is visibility: hidden,
// and the walkthrough ends a run whose target it cannot see unless a screen
// says the target is away. Each layer names every target it draws -- its own
// and those of the elements it mounts, today's components read through their
// imports -- or a card about one it left out ends the run with hud on.
const TUT = /(?:\bdata-tut|\btut)=["']([\w-]+)["']/g
function targetsOf(entry) {
  const seen = new Set()
  const out = new Set()
  const visit = (f) => {
    if (seen.has(f)) return
    seen.add(f)
    for (const m of (codeOf.get(f) ?? '').matchAll(TUT)) out.add(m[1])
    for (const g of takes.get(f) ?? []) {
      const r = slash(relative(SRC, g))
      // Today's HUD is not drawn by its v2 twin, which takes its slot id alone.
      if (r === 'hud/Hud.tsx' || !(r.startsWith('hud/') || r.startsWith('chat/'))) continue
      visit(g)
    }
  }
  visit(entry)
  return [...out].sort()
}
const hudTargets = ((/\bconst HUD_TARGETS = \[([\s\S]*?)\]/.exec(hudV2Tsx)?.[1] ?? '').match(/'[\w-]+'/g) ?? [])
  .map((s) => s.slice(1, -1)).sort()
const awayOf = (name) => (/\[AWAY_ATTR\]:\s*'([^']*)'/.exec(fnBody(layerTsx, name))?.[1] ?? '').split(/\s+/).filter(Boolean).sort()
check('HudV2 says every walkthrough target it draws is away while it is held or quick-hidden (HUD_TARGETS)',
  hudTargets, targetsOf(join(V2, 'HudV2.tsx')))
check('...and that is the vitals, the counters and the Alive plate, the feed, the squad and its two, the inventory and its Volts, the minimap and the timer',
  hudTargets.length, 11)
check('HudV2 puts them up while held, or quick-hidden by our pause menu or a scope',
  /\bconst away = sentinel\.held \|\| paused \|\| scoped\b/.test(hudV2Tsx) && /\{\.\.\.\(away \? \{ \[AWAY_ATTR\]: HUD_TARGETS \} : \{\}\)\}/.test(hudV2Tsx), true)
check("ChatLayer says chat's target is away while held or quick-hidden", awayOf('ChatLayer'), targetsOf(join(SRC, 'chat', 'Chat.tsx')))
check("NoticesLayer says the notice stack's is", awayOf('NoticesLayer'), targetsOf(join(SRC, 'hud', 'Notices.tsx')))

// THE NOTICE STACK STAYS OVER THE TAB PAGE. Notices.tsx draws it at z-index
// 40, which ties InventoryPanel's and wins on App's order; inside its
// full-stage anchor (fixed, so a stacking context) the 40 would count only
// there, and the TAB page would paint over every notice.
const noticesZ = /\bzIndex:\s*(\d+)/.exec(codeOf.get(join(SRC, 'hud', 'Notices.tsx')) ?? '')?.[1] ?? null
const anchorZ = /:where\(\.hud-v2\) \.hud-anchor\[data-hud-id="notices"\]\s*\{[^}]*\bz-index:\s*(\d+)/.exec(blank(hud2Css))?.[1] ?? null
check("the notice stack's anchor carries Notices.tsx's own z-index", [noticesZ !== null, anchorZ], [true, noticesZ])

// THE SHAPES hud2.css READS IN TODAY'S MARKUP. The wipe's light rides the
// inventory bar's slot row (its root's last child) and each counter's label
// line (the div right after its numeral span), and neither carries a class of
// its own: today's files are not edited for UI v2. Read here off the JSX, so
// a change to either fails the build rather than putting the light out. The
// Volts gold reads a third, below.
const jsxOf = (f) => ts.createSourceFile(f, readFileSync(f, 'utf8'), ts.ScriptTarget.Latest, true, ts.ScriptKind.TSX)
const eachNode = (n, fn) => { fn(n); ts.forEachChild(n, (k) => eachNode(k, fn)) }
const isEl = (n) => ts.isJsxElement(n) || ts.isJsxSelfClosingElement(n)
const tagOf = (n) => (ts.isJsxElement(n) ? n.openingElement : n).tagName.getText()
const unparen = (e) => { let x = e; while (x && ts.isParenthesizedExpression(x)) x = x.expression; return x }
const attrsOf = (n) => (ts.isJsxElement(n) ? n.openingElement : n).attributes.properties
const attrOf = (n, name) => attrsOf(n).find((a) => ts.isJsxAttribute(a) && a.name.getText() === name) ?? null
/** An attribute's value when it is a plain string (`id="dbno"`), else null. */
const attrText = (n, name) => { const i = attrOf(n, name)?.initializer; return i && ts.isStringLiteral(i) ? i.text : null }
function classOf(n) {
  for (const a of (ts.isJsxElement(n) ? n.openingElement : n).attributes.properties) {
    if (!ts.isJsxAttribute(a) || a.name.getText() !== 'className' || !a.initializer) continue
    const i = a.initializer
    const e = ts.isJsxExpression(i) ? i.expression : i
    if (e && (ts.isStringLiteral(e) || ts.isNoSubstitutionTemplateLiteral(e))) return e.text
    if (e && ts.isTemplateExpression(e)) return e.head.text
  }
  return ''
}
/** An element's children as elements: `{ el, cond }`, a `{x && (<a/>)}` or a
 *  ternary being one that may be absent, and any other expression an unknown
 *  (`el` null). Text and comments are not elements. */
function elementKids(n) {
  const out = []
  for (const k of ts.isJsxElement(n) ? n.children : []) {
    if (isEl(k)) { out.push({ el: k, cond: false }); continue }
    if (!ts.isJsxExpression(k) || !k.expression) continue
    const e = unparen(k.expression)
    const right = ts.isBinaryExpression(e) && e.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken ? unparen(e.right) : null
    out.push({ el: right && isEl(right) ? right : null, cond: true })
  }
  return out
}
function returnedRoot(file, fnName) {
  let fn = null
  eachNode(jsxOf(file), (n) => { if (ts.isFunctionDeclaration(n) && n.name?.text === fnName) fn = n })
  const rets = fn?.body?.statements.filter((s) => ts.isReturnStatement(s)) ?? []
  const e = unparen(rets[rets.length - 1]?.expression)
  return e && isEl(e) ? e : null
}
const invRoot = returnedRoot(join(SRC, 'hud', 'InventoryBar.tsx'), 'InventoryBar')
const invLast = invRoot ? elementKids(invRoot).pop() ?? null : null
let slotsDrawn = false
if (invLast?.el) eachNode(invLast.el, (n) => { if (isEl(n) && tagOf(n) === 'Slot') slotsDrawn = true })
check('InventoryBar\'s root is a div that ends, always, in the row that draws its slots ([data-tut="hud-inventory"] > div > div:last-child)',
  [invRoot && tagOf(invRoot), invLast?.cond ?? null, invLast?.el ? tagOf(invLast.el) : null, slotsDrawn], ['div', false, 'div', true])
const plates = []
eachNode(jsxOf(join(SRC, 'hud', 'Counters.tsx')), (n) => { if (isEl(n) && classOf(n).split(/\s+/).includes('plate')) plates.push(n) })
const labeled = plates.filter((p) => elementKids(p).some((k, i, all) => i > 0 && !k.cond && !all[i - 1].cond
  && k.el !== null && all[i - 1].el !== null && tagOf(all[i - 1].el) === 'span' && tagOf(k.el) === 'div'))
check("each counter's plate draws its numeral span and, right after it, its label line ([data-tut=\"hud-counters\"] .plate > span + div)",
  [plates.length > 0, labeled.length], [true, plates.length])
// ...and HudV2's half of both: the inventory span's one child is the bar
// itself (the selector steps from the span to the bar's root by a child's
// combinator, so a wrapper between them would light the whole column), and
// the counters span holds the counters.
let invSpan = null
let countersSpan = null
eachNode(jsxOf(join(V2, 'HudV2.tsx')), (n) => {
  if (!isEl(n)) return
  if (attrText(n, 'data-tut') === 'hud-inventory') invSpan = n
  if (attrText(n, 'data-tut') === 'hud-counters') countersSpan = n
})
const invKids = invSpan ? elementKids(invSpan) : []
let countersIn = false
if (countersSpan) eachNode(countersSpan, (n) => { if (isEl(n) && tagOf(n) === 'Counters') countersIn = true })
check("HudV2 draws InventoryBar as its inventory span's one child, unwrapped, and Counters inside its counters span",
  [invKids.length, invKids[0]?.cond ?? null, invKids[0]?.el ? tagOf(invKids[0].el) : null, countersIn], [1, false, 'InventoryBar', true])
// ...and the third shape, the Volts gold's: InventoryBar's Volts plate draws
// the balance as its .font-display child, which hud2.css paints --bc-volts
// inside the v2 HUD's inventory anchor alone. A balance moved out of that
// child would stay white with the hud piece on.
let voltsPlate = null
eachNode(jsxOf(join(SRC, 'hud', 'InventoryBar.tsx')), (n) => { if (isEl(n) && attrText(n, 'data-tut') === 'hud-volts') voltsPlate = n })
const balance = (voltsPlate ? elementKids(voltsPlate) : []).find((k) => k.el && classOf(k.el).split(/\s+/).includes('font-display')) ?? null
let drawsBalance = false
if (balance?.el) eachNode(balance.el, (n) => { if (ts.isIdentifier(n) && n.text === 'volts') drawsBalance = true })
check('InventoryBar\'s Volts plate draws the balance as its own .font-display child ([data-tut="hud-volts"] > .font-display)',
  [voltsPlate !== null, balance?.cond ?? null, balance?.el ? tagOf(balance.el) : null, drawsBalance], [true, false, 'span', true])
check("...and hud2.css paints that child the kit's Volts gold, inside the inventory anchor",
  /:where\(\.hud-v2\) \.hud-anchor\[data-hud-id="inventory"\] \[data-tut="hud-volts"\] > \.font-display\s*\{[^}]*\bcolor:\s*var\(--bc-volts\)/.test(blank(hud2Css)), true)

// .hud-safe AND THE FIXED BOXES STAY OFF EVERY TRANSFORM. A transformed
// ancestor is the containing block of every fixed box under it (#231), and
// check-ui R9 and R12 read index.css and Hud.tsx alone. In the v2 HUD the
// boxes that address the screen are .hud-safe, every `fixed` box, the
// full-stage anchors (choreo.ts) and HudV2's own root, and each sits under
// nothing that can carry a transform: a plain element with none of its own
// (no transform or filter class, no such key in its style), a scope (it draws
// no element) or a quick hide, whose preset names none. An anchor always
// moves its channels, a Presence takes its preset's root transform (drop's,
// slide's), and any other component is not read here, so none of them may.
// In hud2.css a transform, or anything else that makes a box the containing
// block of a fixed one, lands only inside an anchor.
const BOXING = /^(?:transform|translate|rotate|scale|perspective|filter|backdrop-filter|will-change|contain|transform-style|--bc-root-t|--bc-pre-root-t)$/
const BOXING_KEYS = new Set(['transform', 'translate', 'rotate', 'scale', 'perspective', 'filter', 'backdropFilter',
  'WebkitBackdropFilter', 'willChange', 'contain', 'transformStyle'])
const BOXING_CLASS = /^-?(?:transform(?:-gpu|-cpu)?|translate-[xy]-\S+|rotate-\S+|scale-\S+|skew-[xy]-\S+|will-change-transform|filter|blur(?:-\S+)?|brightness-\S+|contrast-\S+|drop-shadow(?:-\S+)?|grayscale(?:-\S+)?|hue-rotate-\S+|invert(?:-\S+)?|saturate-\S+|sepia(?:-\S+)?|backdrop-\S+|\[(?:transform|translate|rotate|scale|perspective|filter|backdrop-filter|will-change|contain|transform-style):\S+\])$/
/** Every class a className can put on its element: each string in it. */
function classTokens(n) {
  const out = []
  const i = attrOf(n, 'className')?.initializer
  if (i) {
    eachNode(i, (k) => {
      if (ts.isStringLiteral(k) || ts.isNoSubstitutionTemplateLiteral(k) || ts.isTemplateHead(k) || ts.isTemplateMiddle(k)
        || ts.isTemplateTail(k)) out.push(...k.text.split(/\s+/).filter(Boolean))
    })
  }
  return out
}
const keyOf = (p) => p.name.getText().replace(/^['"]|['"]$/g, '')
/** An inline style's object literal: [] with no style, null when it is not
 *  one, or a spread in it hides its keys. */
function styleOf(n) {
  const a = attrOf(n, 'style')
  if (!a) return []
  const e = a.initializer && ts.isJsxExpression(a.initializer) ? unparen(a.initializer.expression) : null
  if (!e || !ts.isObjectLiteralExpression(e) || e.properties.some((p) => !ts.isPropertyAssignment(p) && !ts.isShorthandPropertyAssignment(p))) return null
  return e.properties
}
/** A spread of attributes made of object literals alone (a ternary of them),
 *  none of them with a class or a style. */
function plainSpread(e) {
  const x = unparen(e)
  if (ts.isConditionalExpression(x)) return plainSpread(x.whenTrue) && plainSpread(x.whenFalse)
  return ts.isObjectLiteralExpression(x) && x.properties.every((p) => ts.isPropertyAssignment(p) && !/^(?:className|class|style)$/.test(keyOf(p)))
}
const fillIds = new Set()
eachNode(jsxOf(join(V2, 'choreo.ts')), (n) => {
  if (!ts.isVariableDeclaration(n) || n.name.getText() !== 'ANCHORS' || !n.initializer || !ts.isObjectLiteralExpression(n.initializer)) return
  for (const p of n.initializer.properties) {
    if (ts.isPropertyAssignment(p) && ts.isObjectLiteralExpression(p.initializer) && p.initializer.properties
      .some((q) => ts.isPropertyAssignment(q) && keyOf(q) === 'fill' && q.initializer.kind === ts.SyntaxKind.TrueKeyword)) fillIds.add(keyOf(p))
  }
})
check("choreo.ts's full-stage anchors are found (fill: true): chat, the notices and the bleed-out card", [...fillIds].sort(), ['chat', 'dbno', 'notices'])
const fixedStyle = (n) => (styleOf(n) ?? []).some((p) => ts.isPropertyAssignment(p) && keyOf(p) === 'position'
  && ts.isStringLiteral(p.initializer) && p.initializer.text === 'fixed')
/** A box that addresses the screen: .hud-safe, a fixed one, a full-stage
 *  anchor, or a v2 component whose root is one of those. */
function screenBox(n) {
  if (tagOf(n) === 'Anchor') return fillIds.has(attrText(n, 'id'))
  if (v2Roots.has(tagOf(n))) return true
  const cls = classTokens(n)
  return cls.includes('hud-safe') || cls.includes('fixed') || fixedStyle(n)
}
const v2Roots = new Set()
const hudV2Root = returnedRoot(join(V2, 'HudV2.tsx'), 'HudV2')
if (hudV2Root && screenBox(hudV2Root)) v2Roots.add('HudV2')
const SCOPES = new Set(['PresenceScope', 'Fragment', 'React.Fragment'])
/** What on `a` can carry a transform, or null when nothing can. */
function carrier(a) {
  const tag = tagOf(a)
  if (SCOPES.has(tag)) return null
  if (tag !== 'QuickHide' && !/^[a-z]/.test(tag)) return `<${tag}>`
  const cls = classTokens(a).map((c) => c.replace(/^(?:[\w-]+:)+/, '')).filter((c) => BOXING_CLASS.test(c))
  if (cls.length) return `<${tag} className="${cls.join(' ')}">`
  const style = styleOf(a)
  if (style === null) return `<${tag} style> (not read)`
  const keys = style.map(keyOf).filter((k) => BOXING_KEYS.has(k))
  if (keys.length) return `<${tag} style={{ ${keys.join(', ')} }}>`
  if (attrsOf(a).some((x) => ts.isJsxSpreadAttribute(x) && !plainSpread(x.expression))) return `<${tag} {...}> (not read)`
  return null
}
const boxes = []
const wrapped = []
for (const f of ['HudV2.tsx', 'HudLayer.tsx']) {
  eachNode(jsxOf(join(V2, f)), (n) => {
    if (!isEl(n) || !screenBox(n)) return
    const tag = tagOf(n)
    const what = tag === 'Anchor' ? `<Anchor id="${attrText(n, 'id')}">` : v2Roots.has(tag) ? `<${tag}>`
      : `<${tag} className="${classTokens(n).join(' ')}">`
    boxes.push(`${f}: ${what}`)
    for (let a = n.parent; a; a = a.parent) {
      if (!ts.isJsxElement(a) && !ts.isJsxSelfClosingElement(a)) continue
      const why = carrier(a)
      if (why) wrapped.push(`${f}: ${what} under ${why}`)
    }
  })
}
check('the boxes that address the screen are found: .hud-safe, four fixed ones (the HUD root, the vitals strip, the minimap box, the dev radar), the three full-stage anchors and HudV2 in its layer',
  [boxes.filter((b) => /className="hud-safe"/.test(b)).length, boxes.filter((b) => /className="[^"]*\bfixed\b/.test(b)).length,
    boxes.filter((b) => /<Anchor id=/.test(b)).length, boxes.filter((b) => /<HudV2>/.test(b)).length], [1, 4, 3, 1])
check('each sits under nothing that can carry a transform: plain elements with none of their own, scopes and quick hides (R9 and R12, for the v2 HUD)',
  wrapped, [])
const quickBoxing = rules.filter((r) => r.sels.some((s) => /\[data-bc-preset=["']?quickHide["']?\]/.test(chain(s).pop() ?? ''))
  && Object.keys(r.decls).some((p) => BOXING.test(p))).map((r) => `${r.sheet}: ${r.sels.join(', ')}`)
check("...and the quick hide's preset names no root transform, nor anything else that makes its root a containing block", quickBoxing, [])
const ANCHOR_CLASS = /\.hud-(?:anchor|ch|fill|mask(?:__in|__frame)?)(?![\w-])/
const anchorCompound = (c) => ANCHOR_CLASS.test(c.replace(/:(?:not|has)\((?:[^()]|\([^()]*\))*\)/g, ''))
/** Does a selector land inside an anchor: on an anchor or one of its
 *  channels, or under one (the combinator just right of it a descendant's or
 *  a child's)? */
function inAnchor(sel) {
  const parts = chain(sel)
  const last = parts.length - 1
  if (last < 0) return false
  if (anchorCompound(parts[last])) return true
  for (let k = last - 2; k >= 0; k -= 2) if ((parts[k + 1] === ' ' || parts[k + 1] === '>') && anchorCompound(parts[k])) return true
  return false
}
const v2Boxing = rules.filter((r) => r.sheet === 'hud/v2/hud2.css' && Object.keys(r.decls).some((p) => BOXING.test(p)))
check('hud2.css transforms (or filters, or contains) only inside an anchor: never .hud-safe, a fixed box or a root above them',
  [v2Boxing.length >= 5, v2Boxing.flatMap((r) => r.sels.filter((s) => !inAnchor(s)))], [true, []])

// THE SLANTED VITALS MOVE THEMSELVES (choreo.ts). The kit's Vitals carry the
// kit's channels in their own plates (the slab, the strap, the face), so
// their anchor takes no channel of its own: `channel: []` in the wipe's
// table. Left out, it takes the default content channel, and a slide and a
// fade round the straps compound with theirs; nothing else in the build sees
// that.
let vitalsChannel = 'no vitals entry in WIPE'
eachNode(jsxOf(join(V2, 'choreo.ts')), (n) => {
  if (!ts.isVariableDeclaration(n) || n.name.getText() !== 'WIPE' || !n.initializer || !ts.isObjectLiteralExpression(n.initializer)) return
  const fx = n.initializer.properties.find((p) => ts.isPropertyAssignment(p) && keyOf(p) === 'vitals')
  if (!fx || !ts.isObjectLiteralExpression(fx.initializer)) return
  const ch = fx.initializer.properties.find((q) => ts.isPropertyAssignment(q) && keyOf(q) === 'channel')
  vitalsChannel = !ch ? 'none named (the default, content)'
    : ts.isArrayLiteralExpression(ch.initializer) ? ch.initializer.elements.map((e) => e.getText()) : ch.initializer.getText()
})
check("choreo.ts: the slanted vitals' anchor takes no channel of its own (WIPE's vitals: channel: [])", vitalsChannel, [])

console.log("9. CEF 103 in UI v2's code (#431, #413)")
// ---------------------------------------------------------------------------
// THE PREVIEW GATE'S CODE BANS (previews/squad/shared/cef103.mjs, which held
// the kit and the HUD stage while they were previews): what Chromium 103
// cannot parse or apply, written where check-css never looks -- an inline
// style, a WAAPI keyframe or its options, a selector string. FiveM draws
// br_ui with CEF 103 today and 144 after the move (#413), and 103 drops what
// it does not know with nothing to say so: a keyframe on `scale: 1.2`
// animates nothing in game while it looks right on a desktop browser.
//
// HERE AND NOT IN check-cef OR check-css. check-cef.mjs is the CEF 144 gate,
// what 144 took away, over every file we ship; check-css.mjs is the 103 gate
// for CSS, read in the built sheets and the hand-written pages. These are 103
// bans on the TS and TSX of UI v2's code: the kit and src/hud/v2, which came
// from the previews, and every other file that takes a value from the kit,
// so a later port is read as it lands. Today's screens were never written to
// them, and they are not read for them.
//
// At the gate's levels: a ban fails here, a note is printed. Comments are
// blanked first, so a comment may name a ban; a deliberate exception carries
// `cef-ok` in a comment on its line, and says why. A React style object spells
// a property in camelCase, so each ban reads that spelling too. Two of the
// gate's CSS-only bans are read here as well, because a style can carry them
// (lch()/lab() in a color, scrollbar-width and -color); its other CSS-only
// ones (@starting-style, @scope, nesting) have no shape in code.
//
// A CSS PROPERTY CODE WRITES BY NAME (`ast`) is read off the syntax tree, in
// every shape code writes one: an object literal's key, whatever its value
// and wherever it sits (a style, a keyframe in either WAAPI form,
// Object.assign's), quoted, computed or short; `.style.name` and
// `.style['name']`; setProperty() and attributeStyleMap.set(); and a
// declaration in a string's CSS text (cssText, a style attribute). A
// variable, a prop, a type's member or a template's ${} of that name is not
// one: the transform code 103 needs names its scale `scale` too.
// ---------------------------------------------------------------------------
const tsxOf = (raw, kind) => ts.createSourceFile(`x.${kind}`, raw, ts.ScriptTarget.Latest, true, kind === 'ts' ? ts.ScriptKind.TS : ts.ScriptKind.TSX)
/** A key's or an argument's name: an identifier, or a string or computed one. */
const nameText = (n) => (!n ? null : ts.isIdentifier(n) || ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n) ? n.text
  : ts.isComputedPropertyName(n) ? nameText(n.expression) : null)
const styleOwner = (e) => { const x = unparen(e); return (ts.isIdentifier(x) && x.text === 'style') || (ts.isPropertyAccessExpression(x) && x.name.text === 'style') }
const lineAt = (sf, pos) => sf.getLineAndCharacterOfPosition(pos).line
/** The lines (from 0) where code writes one of `names` (camelCase and
 *  kebab-case) as a CSS property. */
const propWrites = (...names) => (sf) => {
  const set = new Set(names)
  const kebab = names.filter((n) => n === n.toLowerCase())
  const inText = kebab.length ? new RegExp(`(?<![\\w-])(?:${kebab.join('|')})\\s*:`) : /(?!)/
  const out = new Set()
  eachNode(sf, (n) => {
    let at = null
    if ((ts.isPropertyAssignment(n) || ts.isShorthandPropertyAssignment(n)) && ts.isObjectLiteralExpression(n.parent) && set.has(nameText(n.name))) at = n.name
    else if (ts.isPropertyAccessExpression(n) && set.has(n.name.text) && styleOwner(n.expression)) at = n.name
    else if (ts.isElementAccessExpression(n) && styleOwner(n.expression) && set.has(nameText(n.argumentExpression))) at = n.argumentExpression
    else if (ts.isCallExpression(n) && ts.isPropertyAccessExpression(n.expression) && set.has(nameText(n.arguments[0]))
      && (n.expression.name.text === 'setProperty' || (n.expression.name.text === 'set' && /\battributeStyleMap$/.test(n.expression.expression.getText(sf))))) at = n.arguments[0]
    else if (ts.isStringLiteral(n) || ts.isNoSubstitutionTemplateLiteral(n) || ts.isTemplateHead(n) || ts.isTemplateMiddle(n) || ts.isTemplateTail(n)) {
      const m = inText.exec(n.getText(sf))
      if (m) out.add(lineAt(sf, n.getStart(sf) + m.index))
    }
    if (at) out.add(lineAt(sf, at.getStart(sf)))
  })
  return [...out]
}
/** WAAPI's composite, as an option, a keyframe's key or a write to an
 *  effect's: any value but replace and auto, from a literal or not. */
const compositeWrites = (sf) => {
  const fine = (v) => { const x = unparen(v); return !!x && (ts.isStringLiteral(x) || ts.isNoSubstitutionTemplateLiteral(x)) && /^(?:replace|auto)$/.test(x.text) }
  const out = new Set()
  eachNode(sf, (n) => {
    let at = null
    if (ts.isPropertyAssignment(n) && ts.isObjectLiteralExpression(n.parent) && nameText(n.name) === 'composite' && !fine(n.initializer)) at = n.name
    else if (ts.isShorthandPropertyAssignment(n) && ts.isObjectLiteralExpression(n.parent) && n.name.text === 'composite') at = n.name
    else if (ts.isBinaryExpression(n) && n.operatorToken.kind === ts.SyntaxKind.EqualsToken && ts.isPropertyAccessExpression(n.left)
      && n.left.name.text === 'composite' && !fine(n.right)) at = n.left.name
    if (at) out.add(lineAt(sf, at.getStart(sf)))
  })
  return [...out]
}
const CEF_BANS = [
  { re: /\b(?:oklch|oklab)\(/, what: 'oklch()/oklab() (Chrome 111)', eg: "color: 'oklch(0.7 0.1 200)'" },
  { re: /(?<![\w-])(?:lch|lab)\(/, what: 'lch()/lab() (Chrome 111)', eg: "color: 'lab(50% 40 59)'" },
  { re: /color-mix\(/, what: 'color-mix() (Chrome 111): write the rgba', eg: "background: 'color-mix(in srgb, red, blue)'" },
  { re: /\bcolor\(\s*(?:srgb|srgb-linear|display-p3|a98-rgb|prophoto-rgb|rec2020|xyz)/, what: 'color() (Chrome 111)', eg: "color: 'color(display-p3 1 0 0)'" },
  { re: /\b(?:rgba?|hsla?|hwb)\(\s*from\s/, what: 'relative color syntax (Chrome 119)', eg: "color: 'rgb(from red r g b)'" },
  { re: /light-dark\(/, what: 'light-dark() (Chrome 123)', eg: "color: 'light-dark(#fff, #000)'" },
  { re: /:has\(/, what: ':has() (Chrome 105): toggle a class or a data- attribute instead', eg: "el.querySelector('.a:has(.b)')" },
  { re: /@container\b/, ast: propWrites('containerType', 'container-type', 'containerName', 'container-name'), what: 'container queries (Chrome 105)',
    eg: "const s = { containerType: 'inline-size' }", names: [['containerType', 'container-type'], ['containerName', 'container-name']] },
  { re: /\d(?:cqw|cqh|cqi|cqb|cqmin|cqmax)\b/, what: 'container units (Chrome 105)', eg: "width: '50cqw'" },
  { re: /\d(?:[dsl]vh|[dsl]vw|[dsl]vi|[dsl]vb|[dsl]vmin|[dsl]vmax)\b/, what: 'dvh/svh/lvh units (Chrome 108)', eg: "height: '100dvh'" },
  // Any value: 103 has no text-wrap at all, so nowrap is dropped as balance is.
  { ast: propWrites('textWrap', 'text-wrap'), what: 'text-wrap (Chrome 114)', eg: "const s = { textWrap: 'balance' }", names: [['textWrap', 'text-wrap']] },
  { re: /transition-behavior|transitionBehavior/, what: 'transition-behavior (Chrome 117)', eg: "transitionBehavior: 'allow-discrete'" },
  { re: /(?<![\w-])linear\(/, what: 'linear() easing (Chrome 113): use cubic-bezier() or keyframe steps', eg: "el.animate(frames, { easing: 'linear(0, 0.5, 1)' })" },
  { re: /animation-composition|animationComposition/, ast: compositeWrites, what: 'animation composition (Chrome 112)', eg: "el.animate(frames, { composite: 'add' })" },
  { re: /(?:animation|scroll|view)-timeline|(?:animation|scroll|view)Timeline/, what: 'scroll-driven animations (Chrome 115)', eg: "animationTimeline: 'scroll()'" },
  { re: /view-transition|viewTransitionName|startViewTransition/, what: 'view transitions (Chrome 111)', eg: 'document.startViewTransition(() => {})' },
  { re: /\banchor(?:-size)?\(|anchor-name|position-anchor|anchorName|positionAnchor/, what: 'anchor positioning (Chrome 125)', eg: "top: 'anchor(--tip bottom)'" },
  { re: /calc-size\(|interpolate-size|interpolateSize/, what: 'calc-size()/interpolate-size (Chrome 129)', eg: "interpolateSize: 'allow-keywords'" },
  { ast: propWrites('scrollbarWidth', 'scrollbar-width', 'scrollbarColor', 'scrollbar-color'), what: 'scrollbar-width/-color (Chrome 121)',
    eg: "const s = { scrollbarWidth: 'none' }", names: [['scrollbarWidth', 'scrollbar-width'], ['scrollbarColor', 'scrollbar-color']] },
  // The individual transform properties: a keyframe on `scale` animates
  // nothing on 103.
  { ast: propWrites('translate', 'rotate', 'scale'), what: 'the individual transform properties translate/rotate/scale (Chrome 104): use transform',
    eg: 'el.animate([{ scale: 1.2 }], 200)', names: [['translate', 'translate'], ['rotate', 'rotate'], ['scale', 'scale']] },
  // CSS zoom is check-cef's C4 everywhere outside the Season 2 islands too.
  { ast: propWrites('zoom'), what: 'CSS zoom (check-cef bans it outside Locker v2 and the Market)', eg: 'const s = { zoom: 2 }', names: [['zoom', 'zoom']] },
  // Not a parser problem, a cost one: framer-motion drives its animations
  // from requestAnimationFrame on the main thread, every frame.
  { re: /from\s+['"](?:framer-motion|motion)(?:\/[^'"]*)?['"]/, what: 'framer-motion: it animates from JavaScript every frame; use CSS keyframes and transitions', eg: "import { motion } from 'framer-motion'" },
]
const CEF_NOTES = [
  { re: /\brequestAnimationFrame\b/, what: 'requestAnimationFrame: fine for a one-shot (restarting a class), never a loop -- the HUD is on screen all match', eg: 'requestAnimationFrame(tick)' },
  { re: /\bsetInterval\b/, what: 'setInterval: anything but a clock is a timer running all match', eg: 'setInterval(tick, 250)' },
  { re: /backdrop-filter|backdropFilter/, what: 'backdrop-filter: index.css avoids it (a known CEF flicker, and expensive)', eg: "backdropFilter: 'blur(4px)'" },
]
const LAYOUT_TRANSITION = 'an inline transition on layout (or `all`): transform and opacity only'
/** One file's findings: { bans, notes }, each [{ what, line }]. `kind` is how
 *  its syntax tree is read: 'ts' or 'tsx'. */
function cefScan(raw, kind = 'tsx') {
  const code = blankComments(raw)
  const lines = code.split('\n')
  const rawLines = raw.split('\n')
  // `cef-ok` excuses its line only from a comment: blanked away with it.
  const excused = (i) => /cef-ok/.test(rawLines[i] ?? '') && !/cef-ok/.test(lines[i] ?? '')
  let sf = null
  const hits = (list) => list.flatMap((b) => {
    const at = new Set()
    if (b.re) lines.forEach((l, i) => { if (b.re.test(l)) at.add(i) })
    if (b.ast) for (const i of b.ast(sf ??= tsxOf(raw, kind))) at.add(i)
    return [...at].sort((x, y) => x - y).filter((i) => !excused(i)).map((i) => ({ what: b.what, line: i + 1 }))
  })
  const layout = [...code.matchAll(/transition(?:Property)?\s*:\s*['"`][^'"`]*/g)]
    .filter((m) => /\b(?:width|height|top|left|right|bottom|margin|padding|all)\b/.test(m[0]))
    .map((m) => ({ what: LAYOUT_TRANSITION, line: code.slice(0, m.index).split('\n').length }))
    .filter((n) => !excused(n.line - 1))
  return { bans: hits(CEF_BANS), notes: [...hits(CEF_NOTES), ...layout] }
}
check('every ban fires on a use of what it bans', CEF_BANS.filter((b) => !cefScan(b.eg).bans.some((x) => x.what === b.what)).map((b) => b.what), [])
check('...and on nothing but its own (no two bans are one)', CEF_BANS.filter((b) => cefScan(b.eg).bans.some((x) => x.what !== b.what)).map((b) => b.what), [])
check('every note fires on its own, a layout transition in a style included, and fails nothing',
  [CEF_NOTES.filter((b) => !cefScan(b.eg).notes.some((x) => x.what === b.what)).map((b) => b.what),
    cefScan("const s = { transition: 'width 200ms ease' }").notes.map((x) => x.what), cefScan(CEF_NOTES.map((b) => b.eg).join('\n')).bans],
  [[], [LAYOUT_TRANSITION], []])
check('a comment may name every ban (a block or a line comment): none fires',
  [cefScan(`/* ${CEF_BANS.map((b) => b.eg).join('\n')} */`).bans, cefScan(CEF_BANS.map((b) => `// ${b.eg}`).join('\n')).bans], [[], []])
check('`cef-ok` in a comment on the line excuses it, and `cef-ok` in a string does not',
  [cefScan("const s = { textWrap: 'balance' } // cef-ok: a test").bans.length, cefScan("const s = { textWrap: 'balance', why: 'cef-ok' }").bans.length], [0, 1])
// EVERY SHAPE CODE WRITES A PROPERTY IN, for each ban on one (camelCase,
// kebab-case): the review's mutants among them, a property-indexed keyframe,
// a keyframe's value from a variable, a value on the next line, cssText, a
// write to .style and setProperty().
const WRITES = [
  (c) => `const s = { ${c}: '1' }`,
  (c) => `el.animate({ ${c}: [a, b] }, 200)`,
  (c) => `el.animate([{ ${c}: v }], 200)`,
  (c) => `const s = {\n  ${c}:\n    v }`,
  (c, k) => `const s = { '${k}': v }`,
  (c) => `const s = { ['${c}']: v }`,
  (c) => `const s = { opacity, ${c} }`,
  (c) => `Object.assign(el.style, { ${c}: v })`,
  (c) => `const d = <div style={{ ${c}: v }} />`,
  (c) => `el.style.${c} = v`,
  (c, k) => `el.style['${k}'] = v`,
  (c, k) => `el.style.setProperty('${k}', v)`,
  (c, k) => `el.attributeStyleMap.set("${k}", v)`,
  (c, k) => 'el.style.cssText = `opacity: 1; ' + k + ': ${v}`',
  (c, k) => `el.setAttribute('style', '${k}: 1')`,
]
// ...and code that only names one: the shapes a regex for `scale:` or
// `{ scale }` fires on (check-cef's C4 reading of zoom does), with no CSS in
// them.
const NAMES = [
  (c) => `const ${c} = 2`,
  (c) => `const s = { transform: ${c} }`,
  (c) => 'const t = `scale(${' + c + '})`',
  (c) => `const b = <b ${c}={${c}}>{${c}}</b>`,
  (c) => `const n = big ? ${c} : 1`,
  (c) => `f(a, ${c}, b)`,
  (c) => `function F({ ${c} }: { ${c}: number }) { return ${c} }`,
  (c) => `interface P { ${c}: number }`,
  (c) => `const { ${c}: v } = props`,
  (c, k) => `const s = { '--hud-${k}': '1' }`,
]
const named = CEF_BANS.filter((b) => b.names)
check('each ban on a property code writes by name reads it in every shape: a key of a style, a keyframe (either WAAPI form) or Object.assign\'s, any value, on the next line, quoted, computed or short; .style; setProperty() and attributeStyleMap; CSS text',
  [named.length, named.flatMap((b) => b.names.flatMap(([c, k]) => WRITES.map((w) => w(c, k)).filter((s) => !cefScan(s).bans.some((x) => x.what === b.what))))],
  [5, []])
check('...and none fires on code that only names one: a variable, its value, a template\'s ${}, a prop, a JSX child, a ternary, an argument, a destructured prop, a type\'s member, a custom property',
  named.flatMap((b) => b.names.flatMap(([c, k]) => NAMES.map((w) => w(c, k)).filter((s) => cefScan(s).bans.length > 0))), [])
check("WAAPI's composite fails from a variable and as an effect's, and passes as replace or auto, in a comparison and in a type",
  [cefScan('el.animate(frames, { composite: mode })').bans.length, cefScan("effect.composite = 'accumulate'").bans.length,
    cefScan("el.animate(frames, { composite: 'replace' })").bans.length, cefScan("const k = [{ opacity: 0, composite: 'auto' }]").bans.length,
    cefScan("if (effect.composite === 'add') stop()").bans.length, cefScan('type O = { composite: CompositeOperation }').bans.length],
  [1, 1, 0, 0, 0, 0])
const cefFiles = [...kitCode, ...v2Own]
const cefNames = cefFiles.map((f) => slash(relative(SRC, f)))
check("UI v2's code is read: every .ts and .tsx of the kit, of src/hud/v2 and of every other file that takes a value from the kit",
  [cefFiles.length > 20, ['hud/v2/HudV2.tsx', 'hud/v2/HudLayer.tsx', 'hud/v2/Anchor.tsx', 'hud/v2/choreo.ts', 'ui/broadcast/motion/usePresence.ts']
    .filter((n) => !cefNames.includes(n))], [true, []])
const cefFound = cefFiles.map((f) => ({ name: slash(relative(SRC, f)), ...cefScan(readFileSync(f, 'utf8'), f.endsWith('.tsx') ? 'tsx' : 'ts') }))
for (const b of CEF_BANS) {
  check(`no ${b.what}`, cefFound.flatMap(({ name, bans }) => bans.filter((x) => x.what === b.what).map((x) => `${name}:${x.line}`)), [])
}
for (const { name, notes } of cefFound) for (const n of notes) console.log(`  warn  ${name}:${n.line}  ${n.what}`)

console.log("10. UI v2's squad panel (src/hud/SquadPanelV2.tsx, #429)")
// ---------------------------------------------------------------------------
// THE BROADCAST SQUAD PANEL, the owner's preview ported beside today's panel.
// ITS SHEET LANDS ON THE PANEL ALONE. squadV2.css comes after index.css's
// rules and the kit's once the panel is imported, and then ships with every
// UI v2 piece off too (a piece decides what mounts, not what is imported),
// so it must match nothing but the panel: every rule starts on one of the
// panel's own elements (a bsq- class, read outside every :not(), :has(),
// :is() and :where()) and goes no further than inside it, never to a
// sibling. Every keyframe it defines is its own (one that took another
// sheet's name, the kit's or index.css's, would replace that animation for
// every screen that plays it).
// ---------------------------------------------------------------------------
const SQ = join(SRC, 'hud', 'SquadPanelV2.tsx')
const sqTsx = codeOf.get(SQ) ?? ''
const sqSf = jsxOf(SQ)
const sqCss = readFileSync(join(SRC, 'hud', 'squadV2.css'), 'utf8')
const sqSels = ruleSels(sqCss)
const PSEUDO_LIST = /:(?:not|has|is|where|matches)\((?:[^()]|\([^()]*\))*\)/g
const onPanel = (s) => {
  const c = chain(s)
  return /\.bsq-[\w-]/.test((c[0] ?? '').replace(PSEUDO_LIST, '')) && c.every((x, i) => i % 2 === 0 || x === ' ' || x === '>')
}
check("squadV2.css: every rule starts on one of the panel's own elements (bsq-) and lands on it or inside it, never on a sibling",
  [sqSels.length > 20, sqSels.filter((s) => !onPanel(s))], [true, []])
const sqFrames = [...blank(sqCss).matchAll(/@keyframes\s+([\w-]+)/g)].map((m) => m[1])
const notSqFrames = new Set(pageSheets.filter((s) => s.name !== 'hud/squadV2.css')
  .flatMap((s) => [...blank(s.css).matchAll(/@keyframes\s+([\w-]+)/g)].map((m) => m[1])))
check("squadV2.css: every keyframe it defines is its own (bsq and a capital), never another sheet's or the kit's",
  [sqFrames.length, sqFrames.filter((n) => !/^bsq[A-Z]\w*$/.test(n) || notSqFrames.has(n) || kitFrames.has(n))], [8, []])
const sqUsed = new Set()
for (const m of blank(sqCss).matchAll(/(?:^|[\s;{])animation(?:-name)?\s*:\s*([^;}]+)/g)) {
  for (const w of m[1].replace(/[\w-]+\((?:[^()]|\([^()]*\))*\)/g, ' ').trim().split(/\s+/)) {
    if (/^[A-Za-z_][\w-]*$/.test(w) && !KEYWORDS.has(w)) sqUsed.add(w)
  }
}
check('squadV2.css: every animation it names is one of its own, and each of its own is played',
  [...sqUsed].sort(), [...sqFrames].sort())
// ...AND IT CASCADES AFTER THE KIT, as in the preview: the panel imports the
// kit first and its sheet last. (Appended to index.css, as the preview's
// notes had it, it would come before the kit's sheets.)
const sqImports = sqSf.statements.filter((s) => ts.isImportDeclaration(s)).map((s) => s.moduleSpecifier.text)
check('SquadPanelV2.tsx imports the kit, and its own sheet last, after it',
  [sqImports.includes('../ui/broadcast'), sqImports[sqImports.length - 1], sqImports.indexOf('../ui/broadcast') < sqImports.indexOf('./squadV2.css')],
  [true, './squadV2.css', true])

// ITS ROOT CARRIES THE KIT. Section 7 reads per file; here the root itself:
// the panel draws its scope (no element) round Board, and Board's div is the
// one root, with bc-kit (where the kit's tokens are declared) and bsq-panel
// (its sheet's) on it.
const sqTop = returnedRoot(SQ, 'SquadPanelV2')
const sqTopKids = sqTop ? elementKids(sqTop) : []
const sqRoot = returnedRoot(SQ, 'Board')
check("SquadPanelV2 draws its PresenceScope round Board, and Board's root is a div with bc-kit and bsq-panel on it",
  [sqTop && tagOf(sqTop), sqTopKids.map((k) => (k.el ? tagOf(k.el) : null)), sqRoot && tagOf(sqRoot),
    sqRoot ? ['bc-kit', 'bsq-panel'].filter((c) => !classOf(sqRoot).split(/\s+/).includes(c)) : null],
  ['PresenceScope', ['Board'], 'div', []])

// IT TAKES TODAY'S PROPS AND DRAWS TODAY'S TWO WALKTHROUGH TARGETS. The HUD
// hands it what it hands today's panel, and the walkthrough's squad cards
// (squad-name, squad-bars) find their targets in either panel; a card whose
// target is missing ends the run.
let todayProps = null
let v2Props = null
let v2Takes = null
eachNode(jsxOf(join(SRC, 'hud', 'SquadPanel.tsx')), (n) => {
  const p = ts.isFunctionDeclaration(n) && n.name?.text === 'SquadPanel' ? n.parameters[0]?.type : null
  if (p && ts.isTypeLiteralNode(p)) todayProps = p.members.map((m) => m.name.getText())
})
eachNode(sqSf, (n) => {
  if (ts.isInterfaceDeclaration(n) && n.name.text === 'SquadPanelProps') v2Props = n.members.map((m) => m.name.getText())
  if (ts.isFunctionDeclaration(n) && n.name?.text === 'SquadPanelV2') v2Takes = n.parameters[0]?.type?.getText() ?? null
})
check("its props, SquadPanelProps, are today's panel's (hud/SquadPanel.tsx), and it takes them",
  [Array.isArray(todayProps) && todayProps.length > 0, v2Props, v2Takes], [true, todayProps, 'SquadPanelProps'])
const sqTargets = targetsOf(SQ)
check("it draws the walkthrough's squad targets that today's panel draws (the slot round it draws hud-squad)",
  [sqTargets.length >= 2, sqTargets], [true, targetsOf(join(SRC, 'hud', 'SquadPanel.tsx'))])

// THE NETS UNDER THE ANIMATION CLOCK (#252). Three steps end on an event of
// the browser's animation clock: a mate who left is dropped on the leave's
// animationend, a death settles (its fade starts) on the OUT plate's, and the
// rows under a gap slide up on a Web Animation. A clock that stalls fires
// none of them, so each has a net on the JS clock, the kit's way: after() is
// a fade clock (ui/fade.ts) over the step's own window plus
// FADE_SETTLE_MARGIN_MS, on the presence clock, looked at by a timer and by
// every envelope, so a timer that never fired is not the end of it.
const afterFn = fnBody(sqTsx, 'after')
check("the nets' clock is ui/fade.ts's own: createFadeClock and FADE_SETTLE_MARGIN_MS, imported from it",
  /^import \{ createFadeClock, FADE_SETTLE_MARGIN_MS \} from '\.\.\/ui\/fade'$/m.test(sqTsx), true)
check('after(): a fade clock over its window on the clock it is given, looked at by a timer and by every envelope',
  [/\bconst fc = createFadeClock\(false, ms, now\)\s+fc\.want\(true\)/.test(afterFn),
    /\bif \(fc\.poll\(\)\) \{ finish\(\); return \}/.test(afterFn),
    /\btimer = window\.setTimeout\(look, Math\.max\(1, fc\.remaining\(\)\)\)/.test(afterFn),
    /\boff = onEnvelope\(\(\) => \{ if \(!done && fc\.poll\(\)\) finish\(\) \}\)/.test(afterFn)],
  [true, true, true, true])
const slotFn = fnBody(sqTsx, 'Slot')
const boardFn = fnBody(sqTsx, 'Board')
const rowAt = sqTsx.indexOf('const Row = memo(function Row(')
const rowFn = rowAt < 0 ? '' : sqTsx.slice(rowAt, sqTsx.indexOf('\n}, (a, b) =>', rowAt))
check("the leave: dropped on its animationend, or by the JS clock once T.rowLeave (the panel's --bsq-t-leave) and the margin have passed",
  [/\bconst now = p\.info\.now\b/.test(slotFn),
    /if \(!out \|\| !mounted\) return undefined\s+return after\(T\.rowLeave \+ FADE_SETTLE_MARGIN_MS, now, \(\) => onDrop\(src\)\)/.test(slotFn),
    /e\.animationName === 'bsqLeave'\) onDrop\(src\)/.test(slotFn), /'--bsq-t-leave': `\$\{T\.rowLeave\}ms`/.test(boardFn)],
  [true, true, true, true])
check('the death: settled on the OUT plate landing, or by the JS clock once OUT_PLATE_AT, its slide (OUT_PLATE_MS) and the margin have passed',
  [/if \(!dying\) return undefined\s+return after\(OUT_PLATE_AT \+ OUT_PLATE_MS \+ FADE_SETTLE_MARGIN_MS, now, \(\) => setSettled\(deathN\)\)/.test(rowFn),
    /onLanded=\{\(\) => setSettled\(deathN\)\}/.test(rowFn)],
  [true, true])
check('the FLIP: every Web Animation still unfinished is canceled once the newest has had T.flip and the margin on the JS clock',
  [/flips\.current\.push\(child\.animate\(/.test(boardFn),
    /return after\(T\.flip \+ FADE_SETTLE_MARGIN_MS, now, \(\) => \{\s+for \(const a of flips\.current\) if \(a\.playState !== 'finished'\) a\.cancel\(\)/.test(boardFn)],
  [true, true])

// THE OWNER'S ORDER FOR A DEATH (decision 3). The game mints a revive key on
// the death's own edge, so the key and its red line usually come in the same
// push as the death; mateEvents.ts's step() gives their beats a `delay`,
// OUT's beat (OUT_WORD_AT) when they come with it and what is left of it when
// they come in a later push before it, and test-mate-events pins that half.
// The panel's half, read here: the key mark is keyed by the key's beat and
// drawn only once that beat's wait is over, the red line the same by its own
// beat, the line's zip with the key, the wait is the beat's delay on the
// row's presence clock, every change goes to step() with its time on that
// clock, and OUT itself drops at OUT_WORD_AT. Keyed by the beat object rather
// than its `n`, every line would share one key and a new one would never
// slide in.
const flatAnd = (e) => {
  const x = unparen(e)
  return ts.isBinaryExpression(x) && x.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken
    ? [...flatAnd(x.left), ...flatAnd(x.right)] : [x.getText(sqSf)]
}
/** Each `tag` element the panel draws: its key, and the conditions of the
 *  `a && b && (<El />)` it is drawn under. */
function drawnUnder(tag) {
  const out = []
  eachNode(sqSf, (n) => {
    if (!isEl(n) || tagOf(n) !== tag) return
    const k = attrOf(n, 'key')?.initializer
    let up = n.parent
    while (up && ts.isParenthesizedExpression(up)) up = up.parent
    const and = up && ts.isBinaryExpression(up) && up.operatorToken.kind === ts.SyntaxKind.AmpersandAmpersandToken
    out.push({
      key: k && ts.isJsxExpression(k) && k.expression ? k.expression.getText(sqSf) : null,
      conds: and ? flatAnd(up.left) : [],
    })
  })
  return out
}
check("the key mark: one, keyed by the key's beat (km and b.keyAnim.n), drawn only once that beat's wait is over (keyDue)",
  drawnUnder('KeyMark').map((d) => [d.key, d.conds.includes('keyDue')]), [['`km${b.keyAnim.n}`', true]])
check("the red line: one, keyed by its own beat (pl and b.lineIn.n), drawn only once that beat's wait is over (lineDue)",
  drawnUnder('PickupLine').map((d) => [d.key, d.conds.includes('lineDue')]), [['`pl${b.lineIn.n}`', true]])
check('the zip that takes the line away plays with the key, so it waits with it (keyDue)',
  drawnUnder('Plate.Zip').map((d) => d.conds.includes('keyDue')), [true])
const waits = new Map()
eachNode(sqSf, (n) => {
  if (ts.isVariableDeclaration(n) && n.initializer && ts.isCallExpression(n.initializer)
    && n.initializer.expression.getText(sqSf) === 'useWaited') waits.set(n.name.getText(sqSf), n.initializer.arguments.map((a) => a.getText(sqSf)))
})
check("keyDue waits on the key's beat and lineDue on the line's, both on the row's presence clock",
  [waits.get('keyDue') ?? null, waits.get('lineDue') ?? null, /\bconst Row = memo\(function Row\(\{[^}]*\bnow\b[^}]*\}: RowProps\)/.test(sqTsx),
    /<Row\b[^>]*\bnow=\{now\}/.test(slotFn)],
  [['b.keyAnim', 'now'], ['b.lineIn', 'now'], true, true])
const waitedFn = fnBody(sqTsx, 'useWaited')
check('useWaited: a beat with no delay, or whose n has waited, is drawn; any other is drawn once its delay has passed on the clock',
  [/\bconst \[played, setPlayed\] = useState\(n\)/.test(waitedFn), /\bconst due = delay <= 0 \|\| played === n\b/.test(waitedFn),
    /if \(due\) return undefined\s+return after\(delay, now, \(\) => setPlayed\(n\)\)/.test(waitedFn), /\}, \[due, n, delay, now\]\)/.test(waitedFn)],
  [true, true, true, true])
check("OUT drops at OUT_WORD_AT, the wait step() gives the key, and the panel keeps no copy of the dying sequence's times",
  [/<Stamp word="OUT"[^>]*\bdelay=\{OUT_WORD_AT\}/.test(rowFn), /\bdelay=\{OUT_PLATE_AT\}/.test(rowFn),
    /\bconst OUT_(?:PLATE_AT|PLATE_MS|WORD_AT)\b/.test(sqTsx)],
  [true, true, false])
// A change read at no time, or on another clock, would measure a later key
// from nothing: every key would wait, or none.
const beatsFn = fnBody(sqTsx, 'useBeats')
check("useBeats hands step() each change's time on the row's presence clock, the one the waits run on, and Row gives it that clock",
  [/^function useBeats\(m: SquadMember, silent: Silence, now: \(\) => number\): Beats \{/.test(beatsFn),
    /\bstep\(s\.b, s\.m, m, s\.silent, silent, now\(\)\)/.test(beatsFn), /\bconst b = useBeats\(m, silent, now\)/.test(rowFn)],
  [true, true, true])

// UI V2'S HUD DRAWS IT, AND ITS ROWS LEAVE THEIR OWN WAY (#429, #431).
// hud/v2/HudV2.tsx's squad slot draws this panel where Hud.tsx's draws
// today's, with the props Hud.tsx hands today's, and today's panel nowhere.
// The slot's anchor is ownable and keyed on the panel's own rule (hasSquad,
// the rule the panel draws its rows by, today's panel's own): the anchor
// looks for the rows when that rule moves and as each of its phases begins,
// and once it sees them it stands down. Keyed on something that can stay put
// while the rows come (the squad's size, when an id arrives on a squad of the
// same size), it would miss them, and its content channel would fade the
// whole panel in one 140 ms go on every way out, each row cut short. No
// ScopeFloor sits in the slot, the preview's call: the slot's scope counts
// its way out from the squad anchor alone, so the gun-shop menu never waits
// out the HUD's reversed stagger (the rows count back in the panel's own
// scope either way). check-layout's hud/v2-squad-out watches the way out
// itself, in a browser.
const hudV2Sf = jsxOf(join(V2, 'HudV2.tsx'))
const importsOf = (sf) => sf.statements.filter((s) => ts.isImportDeclaration(s)).map((s) => {
  const c = s.importClause
  const named = c?.namedBindings && ts.isNamedImports(c.namedBindings) ? c.namedBindings.elements.map((e) => e.name.text) : []
  return { from: s.moduleSpecifier.text, name: c?.name?.text ?? null, named }
})
const v2Imports = importsOf(hudV2Sf)
check("HudV2.tsx takes the panel and its rule from ../SquadPanelV2 (SquadPanelV2, { hasSquad }), and nothing from today's ../SquadPanel",
  [v2Imports.filter((i) => i.from === '../SquadPanelV2').map((i) => [i.name, i.named]), v2Imports.filter((i) => i.from === '../SquadPanel').length],
  [[['SquadPanelV2', ['hasSquad']]], 0])
/** An element's attributes as `name=value` (a string's text, an
 *  expression's code, or the bare name), in source order. */
const attrList = (n, sf) => attrsOf(n).filter((a) => ts.isJsxAttribute(a)).map((a) => {
  const i = a.initializer
  if (!i) return a.name.getText(sf)
  if (ts.isStringLiteral(i)) return `${a.name.getText(sf)}="${i.text}"`
  return `${a.name.getText(sf)}={${i.expression ? i.expression.getText(sf) : ''}}`
})
const elementsOf = (sf, tag) => {
  const out = []
  eachNode(sf, (n) => { if (isEl(n) && tagOf(n) === tag) out.push(n) })
  return out
}
const hudSf = jsxOf(join(SRC, 'hud', 'Hud.tsx'))
const todayPanel = elementsOf(hudSf, 'SquadPanel')
const v2Panel = elementsOf(hudV2Sf, 'SquadPanelV2')
check("HudV2 draws SquadPanelV2 once, today's panel never, with the props Hud.tsx hands today's panel, off the same names",
  [v2Panel.length, elementsOf(hudV2Sf, 'SquadPanel').length, v2Panel.map((n) => attrList(n, hudV2Sf))],
  [1, 0, todayPanel.map((n) => attrList(n, hudSf))])
// From the panel up to the slot: each element round it, and nothing else.
const slotChain = []
let slotEl = null
for (let a = v2Panel[0]?.parent; a; a = a.parent) {
  if (!ts.isJsxElement(a)) continue
  slotChain.push(`<${tagOf(a)} ${attrList(a, hudV2Sf).join(' ')}>`)
  if (attrList(a, hudV2Sf).includes('id={SQUAD_SLOT_ID}')) { slotEl = a; break }
}
check('in the slot: the walkthrough\'s span, in the squad anchor (ownable, keyed on hasSquad(squad)), in the gun-shop scope, in the slot itself',
  slotChain, [
    '<span data-tut="hud-squad" className="block">',
    '<Anchor id="squad" ownable ownKey={hasSquad(squad)}>',
    '<PresenceScope want={!gunshopMenu}>',
    `<div id={SQUAD_SLOT_ID} className="absolute w-[13rem]" style={{ top: 'var(--hud-top)', left: 'var(--hud-left)' }}>`,
  ])
let slotFloors = slotEl === null ? -1 : 0
if (slotEl !== null) eachNode(slotEl, (n) => { if (isEl(n) && tagOf(n) === 'ScopeFloor') slotFloors++ })
check("and no ScopeFloor in the slot (the preview's call): the gun-shop menu never waits out the HUD's reversed stagger", slotFloors, 0)
const panelAt = sqTsx.indexOf('export default function SquadPanelV2(')
const panelFn = panelAt < 0 ? '' : sqTsx.slice(panelAt, sqTsx.indexOf('\n}\n', panelAt) + 2)
check("hasSquad is today's panel's rule (SquadPanel.tsx draws nothing when !squad.id || squad.members.length <= 1), and the panel's rows come by it",
  [/^export function hasSquad\(squad: SquadPayload\): boolean \{\s*return !!squad\.id && squad\.members\.length > 1\s*\}/m.test(sqTsx),
    /\bif \(!squad\.id \|\| squad\.members\.length <= 1\) return null\b/.test(codeOf.get(join(SRC, 'hud', 'SquadPanel.tsx')) ?? ''),
    /\bconst has = hasSquad\(squad\)/.test(panelFn), /<PresenceScope [^>]*\bwant=\{has\}/.test(panelFn)],
  [true, true, true, true])
// A DIFFERENT SQUAD IS A NEW ONE ON AIR (#429). The rows are read by server
// id, so a squad drawn over another (the walkthrough's staged one over the
// player's, selHudSquad) was read as a change to each row it shared a server
// id with, a hit, a shield break, a knock or a kill nobody took, and as a
// leave for each it did not, under the new rows. The panel's one scope is
// keyed by the squad's id, so the squad drawn goes and the new one goes on air
// as a squad that forms does. check-layout's hud/v2-squad-staged watches it.
check("a squad drawn over another is a new one on air: the panel's one scope is keyed by the squad's id",
  elementsOf(sqSf, 'PresenceScope').map((n) => attrList(n, sqSf)),
  [['key={frame.squad.id}', 'want={has}', 'preset="broadcast"', 'step={STEP}']])

console.log(`\n${ran - failed}/${ran} passed${failed ? `, ${failed} FAILED` : ''}`)
process.exit(failed ? 1 : 0)
