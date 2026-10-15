#!/usr/bin/env node
/**
 * HIDE, DON'T WRAP (owner, 2026-10-14: "text wrapping should not be allowed.
 * if you can't fit the text, don't draw it"): ui/labelFit.ts's rule, and the
 * stylesheet and button that carry it.
 *
 *   RULE     a label fits its room only if it is no wider (half a pixel of
 *            sub-pixel slack); judge() marks the room `data-unfit` exactly
 *            while it does not, and takes the mark off when it fits again.
 *   WATCH    watchFit() judges at once, judges again whenever the room or the
 *            label changes size, and lets both go on release.
 *   CSS      index.css hides an unfit room's label by visibility (never
 *            display, never a smaller font), keeps every label on one line
 *            and clips it across only.
 *   BUTTON   Btn puts its label through Fit, so no button label can wrap.
 *
 * In the browser, scripts/check-layout.mjs's self-check proves the same
 * mechanism hides a real label in the real bundle.
 *
 * Run: npm run test:fit   (and as part of npm run build)
 */
import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const here = dirname(fileURLToPath(import.meta.url))
const src = join(here, '..', 'src')

let failures = 0
let passes = 0
function check(name, ok, detail = '') {
  if (ok) { passes++; return }
  failures++
  console.error(`FAIL ${name}${detail ? `: ${detail}` : ''}`)
}

// ── A stand-in DOM: a room and its label, with widths the test sets ─────────
function element(width) {
  const attrs = new Set()
  return {
    width,
    firstElementChild: null,
    getBoundingClientRect() { return { width: this.width } },
    hasAttribute(a) { return attrs.has(a) },
    toggleAttribute(a, on) { if (on) attrs.add(a); else attrs.delete(a); return on },
  }
}
function pair(room, label) {
  const r = element(room)
  r.firstElementChild = element(label)
  return r
}

// A ResizeObserver the test drives by hand.
const observers = []
globalThis.ResizeObserver = class {
  constructor(cb) { this.cb = cb; this.watched = new Set(); observers.push(this) }
  observe(t) { this.watched.add(t) }
  unobserve(t) { this.watched.delete(t) }
  fire(...targets) { this.cb(targets.map((target) => ({ target })), this) }
}

const { fits, judge, watchFit, FIT_SLACK, UNFIT } = await import('../src/ui/labelFit.ts')

// ── RULE ─────────────────────────────────────────────────────────────────
check('a label narrower than its room fits', fits(80, 100))
check('a label exactly its room fits', fits(100, 100))
check('half a pixel over is sub-pixel layout, and fits', fits(100 + FIT_SLACK, 100))
check('a pixel over does not fit', !fits(101, 100))
check('a label in no room at all does not fit', !fits(10, 0))
check('the slack is half a pixel', FIT_SLACK === 0.5)

const wide = pair(100, 140)
check('judge says a too-wide label does not fit', judge(wide) === false)
check('and marks its room', wide.hasAttribute(UNFIT))
wide.firstElementChild.width = 60
check('judge says it fits once it is narrower', judge(wide) === true)
check('and takes the mark off', !wide.hasAttribute(UNFIT))
check('the mark is data-unfit', UNFIT === 'data-unfit')
check('a room with no label is never marked', judge(element(10)) === true)

// ── WATCH ────────────────────────────────────────────────────────────────
const room = pair(50, 120)
const release = watchFit(room)
check('a watched label that cannot fit is hidden at once', room.hasAttribute(UNFIT))
const ro = observers[0]
check('one observer watches the room and the label', observers.length === 1
  && ro.watched.has(room) && ro.watched.has(room.firstElementChild))
room.width = 200
ro.fire(room)
check('a room that grows brings its label back', !room.hasAttribute(UNFIT))
room.firstElementChild.width = 260
ro.fire(room.firstElementChild)
check('a label whose text grows past its room goes', room.hasAttribute(UNFIT))
const other = pair(300, 10)
watchFit(other)
check('every label shares the one observer', observers.length === 1)
release()
check('release lets the room and label go', !ro.watched.has(room) && !ro.watched.has(room.firstElementChild))
check('and leaves the others watched', ro.watched.has(other))

// ── CSS ──────────────────────────────────────────────────────────────────
const css = readFileSync(join(src, 'index.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '')
const rule = (sel) => {
  const m = new RegExp(`(^|\\n)${sel.replace(/[.[\]>*]/g, '\\$&')}\\s*\\{([^}]*)\\}`).exec(css)
  return m ? m[2] : null
}
const fitRule = rule('.fit') ?? ''
check('.fit keeps a label on one line', /white-space:\s*nowrap/.test(fitRule), fitRule)
check('.fit clips across only', /overflow-x:\s*clip/.test(fitRule) && /overflow-y:\s*visible/.test(fitRule), fitRule)
check('.fit asks for its label when there is room and nothing when there is not',
  /display:\s*grid/.test(fitRule) && /grid-template-columns:\s*minmax\(0,\s*max-content\)/.test(fitRule), fitRule)
check('.fit-in is one line as wide as its text', /justify-self:\s*start/.test(rule('.fit-in') ?? '')
  && /white-space:\s*nowrap/.test(rule('.fit-in') ?? ''))
check('.fit sets no width, so the max-w-* a call site gives caps the room', !/(^|[^-])(min-|max-)?width:/.test(fitRule), fitRule)
const hide = rule('.fit[data-unfit] > .fit-in') ?? ''
check('an unfit label is hidden by visibility', /visibility:\s*hidden/.test(hide), hide)
check('and not by display or a smaller size', !/display|font-size|transform/.test(hide), hide)
check('.fit--drop gives up its room first', /flex-shrink:\s*1000/.test(rule('.fit--drop') ?? ''))

// ── BUTTON ───────────────────────────────────────────────────────────────
const btn = readFileSync(join(src, 'ui', 'Btn.tsx'), 'utf8')
check('Btn imports Fit', /import Fit from '\.\/Fit'/.test(btn))
check('Btn draws its label through Fit, centered', /<Fit center>\{children\}<\/Fit>/.test(btn))
check('.fit--center centers; nothing else does', /justify-content:\s*center/.test(rule('.fit--center') ?? '')
  && !/button \.fit/.test(css))

if (failures > 0) {
  console.error(`test-fit: ${failures} failed, ${passes} passed`)
  process.exit(1)
}
console.log(`test-fit: ${passes} passed`)
