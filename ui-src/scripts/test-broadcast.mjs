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
 * 2. EVERY PRESET HAS BOTH HALVES: a TS spec and a CSS rule.
 * 3. THE PRESENCE MACHINE (motion/machine.ts) does what the README's table
 *    says for every change of moment: a leave mid-enter, an enter mid-leave,
 *    a hold, a quick hide, a late joiner, the settle and the landing, and a
 *    scope's way out as one (a leave the scope drove parks until its last).
 * 4. THE CSS KEEPS ITS RULES: every endless animation has its .layer-off line
 *    (check-ui R27), every class is bc- (no Tailwind collision, R8), keyframes
 *    move transform and opacity only (R7).
 * 5. THE OWNER'S PICKS HOLD (2026-11-03).
 * 6. A NUMBER IN A LABEL LEAVES WITH ITS WORDS; a number standing alone goes
 *    the moment its content starts to leave, under EVERY preset there is.
 *    The cascade a number meets is resolved by specificity, then order, over
 *    every sheet it can meet (the kit's and every other one under src), and
 *    only the kit may set a number's own opacity; motion/label.ts is run on
 *    stand-ins for the cases the screens draw, its way out and back through
 *    every moment; and Numeral and Clock are checked to be wired to both.
 * 7. THE KIT IN THE GAME. main.tsx imports every stylesheet above App, so the
 *    built CSS has every kit rule after index.css's last; the index.css
 *    keyframes the kit animates with are still there, and every name the kit
 *    defines is its own (a keyframe that took one of index.css's would
 *    replace it); the tokens sit on the kit's root class and never on :root,
 *    and every kit rule lands on what the kit draws (through every :is() and
 *    :where()), so with every UI v2 piece off nothing on screen carries
 *    either; deps.ts is the kit's one door into the rest of src, nothing the
 *    kit draws leaves the tree it is mounted in, and every file that takes a
 *    value from the kit is drawn under a .bc-kit root; and no kit source hands
 *    Tailwind a utility of its own.
 *
 * node runs the .ts files as-is (type stripping): they have no runtime imports.
 */

import { readdirSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { BUILT_IN, COUNT, EASE, HALF, LEAVE_STEP, STEP, T } from '../src/ui/broadcast/motion/tokens.ts'
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
const R7 = /^(?:width|height|min-width|min-height|max-width|max-height|top|left|right|bottom|inset|margin.*|padding.*|box-shadow)$/
const layoutFrames = []
for (const m of kit.matchAll(/@keyframes\s+([\w-]+)\s*\{((?:[^{}]*\{[^{}]*\})*[^{}]*)\}/g)) {
  for (const p of m[2].matchAll(/([a-z-]+)\s*:/g)) if (R7.test(p[1])) layoutFrames.push(`${m[1]}: ${p[1]}`)
}
check('keyframes move transform and opacity only (R7)', layoutFrames, [])
check('a plate line is scoped to its plate (no bare .bc-line rule)',
  [kit.includes('.bc-plate .bc-line {'), /(?:^|\})\s*\.bc-line\s*\{/.test(kit)], [true, false])
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
const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((e) => {
  if (e.name === 'node_modules' || e.name.startsWith('.')) return []
  const p = join(dir, e.name)
  return e.isDirectory() ? walk(p) : [p]
})
const inKit = (p) => !relative(here, p).startsWith('..')
const slash = (p) => p.replace(/\\/g, '/')
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
check('the other sheets under src are read too (index.css, and Locker v2\'s and the Market\'s at least)',
  [pageSheets.some((s) => s.name === 'index.css'), pageSheets.length >= 3], [true, true])

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
/** Specificity [ids, classes + attributes + pseudo-classes, types]; :not()
 *  counts its argument. */
function specificity(sel) {
  const n = [0, 0, 0]
  let s = sel.replace(/:not\(([^()]*)\)/g, (_, x) => { const k = specificity(x); n[0] += k[0]; n[1] += k[1]; n[2] += k[2]; return ' ' })
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
check('the presets checked below include the built-ins and the plug-ins (broadcast, quickHide, none, drop, fade, slide)',
  ['broadcast', 'quickHide', 'none', 'drop', 'fade', 'slide'].filter((n) => !presets.includes(n)), [])
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
const builtCss = readFileSync(join(scripts, '..', '..', 'resources', '[fivem-royale]', 'br_ui', 'ui', 'assets', 'index.css'), 'utf8')
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

// THE ONE DOOR. Every kit file imports its siblings and React; deps.ts alone
// reaches the rest of src, and nothing else does.
const kitCode = walk(here).filter((p) => /\.tsx?$/.test(p))
const doors = []
for (const f of kitCode) {
  const name = slash(relative(here, f))
  const src = blankComments(readFileSync(f, 'utf8'))
  for (const m of src.matchAll(/(?:\bfrom\s*|\bimport\s*\(?\s*)(['"])([^'"]+)\1/g)) {
    const spec = m[2]
    if (!spec.startsWith('.')) { if (spec !== 'react') doors.push(`${name}: ${spec}`); continue }
    const inside = !relative(here, resolve(dirname(f), spec)).startsWith('..')
    if (inside === (name === 'deps.ts')) doors.push(`${name}: ${spec}`)
  }
}
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
const TYPE_ONLY = [
  /^\s*(?:import|export)\s+type\s+(?:\{[^}]*\}|\*\s+as\s+[\w$]+|[\w$]+)\s+from\s*(['"])[^'"]*\1/gm,
  /^\s*import\s*\{(?:\s*type\s+[\w$]+(?:\s+as\s+[\w$]+)?\s*,?)+\s*\}\s*from\s*(['"])[^'"]*\1/gm,
]
const codeOf = new Map(srcCode.map((f) => [f, blankComments(readFileSync(f, 'utf8'))]))
const takes = new Map(srcCode.map((f) => {
  const code = TYPE_ONLY.reduce((s, re) => s.replace(re, ' '), codeOf.get(f))
  return [f, [...code.matchAll(/(?:\bfrom\s*|\bimport\s*\(?\s*)(['"])([^'"]+)\1/g)].map((m) => target(f, m[2])).filter(Boolean)]
}))
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
// negation of `hidden` was the one rule the kit added to the bundle.
const BARE = ['hidden', 'block', 'inline', 'flex', 'grid', 'table', 'contents', 'flow-root', 'visible', 'invisible',
  'collapse', 'static', 'fixed', 'absolute', 'relative', 'sticky', 'isolate', 'truncate', 'italic', 'underline',
  'overline', 'uppercase', 'lowercase', 'capitalize', 'container', 'shadow', 'border', 'rounded', 'outline', 'ring',
  'blur', 'grow', 'shrink', 'transform', 'transition', 'filter', 'invert', 'grayscale', 'sepia']
const bang = new RegExp(`(?<![\\w-])!(?:${BARE.join('|')})(?![\\w-])`, 'g')
check('no kit source hands Tailwind an important utility (a bang before a utility\'s name)',
  kitCode.flatMap((f) => [...readFileSync(f, 'utf8').matchAll(bang)].map((m) => `${slash(relative(here, f))}: ${m[0]}`)), [])

console.log(`\n${ran - failed}/${ran} passed${failed ? `, ${failed} FAILED` : ''}`)
process.exit(failed ? 1 : 0)
