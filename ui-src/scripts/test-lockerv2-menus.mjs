#!/usr/bin/env node
/**
 * LOCKER V2'S MENUS AND NEW'S CARDS, MEASURED IN A BROWSER ON BOTH ZOOM MODELS
 * (#28 review).
 *
 * The Cloudscape island is zoomed (root px / 14), and Cloudscape sizes an open
 * dropdown in script from the boxes it measures. CEF 103 measures a zoomed box
 * in its own px; Chromium 128 and later -- so CEF 144 -- in screen px, and the
 * island's zoom then applied a second time. The pickers were fixed for it and
 * a card's "..." menu was not: 57 px wide at 720p ("Ren / ame") and 217 px at
 * 1440p, on the newer model only. src/cef/zoomRect.ts (#413) and
 * lockerv2.css's sizes in em each answer it now. Nothing that reads the
 * source sees what a browser draws, so
 * this opens the screen the browser mock draws (scripts/lib/headless.mjs), on
 * CEF 103's zoom rule and on Chromium 128's, at three window sizes, presses
 * every Cloudscape dropdown the locker has with a real mouse, and measures:
 *
 *   SAME     each menu and its trigger the same size and place, in screen px,
 *            on both rules;
 *   PICKER   a Select's list exactly its picker's width (owner, 2026-10-14:
 *            "why is the "add" dropdown wider than it's parent button?");
 *   ICON     a card's "..." menu as wide as its words, never narrower;
 *   TALL     every list 15em at most;
 *   LINE     every option on one line, or not drawn -- never wrapped, never
 *            "..." ("text wrapping should not be allowed. if you can't fit the
 *            text, don't draw it"), the game's long tattoo names included,
 *            in the list and on the picker once chosen -- a new row's and a
 *            row's own; every name with room drawn, and one with none chosen
 *            not drawn on its picker;
 *   NEW      both cards' titles at the top left, 1em in ("what happened to the
 *            alignment of text in these boxes"), and the Male / Female
 *            dropdown 8.5em wide ("the gender dropdown is suuuuper wide").
 *
 *   node scripts/test-lockerv2-menus.mjs            build the mock, then measure
 *   ... --dist=<dir>                                a mock build already made
 *
 * Run: npm run test:lockerv2menus   (and as part of npm run build)
 */
import { readFileSync } from 'node:fs'
import { dirname, join, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'
import { buildMock, launch, serve, sleep } from './lib/headless.mjs'

const here = dirname(fileURLToPath(import.meta.url))
const uiRoot = resolve(here, '..')
const DRIVER = readFileSync(join(here, 'lib', 'layout-driver.js'), 'utf8')
const SIZES = [[1280, 720], [1920, 1080], [2560, 1440]]
const L = '[data-page=locker]'
/** bridge/mockLocker2.ts's stand-in for a name with no room in any picker. */
const TOO_LONG = 'Flaming Skull and Crossed Wrenches Over the Vinewood Sign'
/** Screen px either way: a box under CEF 103's rule is put back by its zoom. */
const TOL = 1.5

const PAGE = `(() => {
  const L = '${L}'
  const LEGACY = (() => {
    const o = document.createElement('div')
    o.style.cssText = 'position:absolute;visibility:hidden;zoom:2'
    const i = document.createElement('div')
    i.style.cssText = 'width:10px;height:10px'
    o.appendChild(i)
    document.body.appendChild(o)
    const w = i.getBoundingClientRect().width
    o.remove()
    return Math.abs(w - 10) < 0.5
  })()
  const zoomOf = (el) => {
    if (!LEGACY) return 1
    let z = 1
    for (let e = el; e; e = e.parentElement) z *= parseFloat(getComputedStyle(e).zoom) || 1
    return z
  }
  const scaled = (r, z) => ({ l: r.left * z, t: r.top * z, r: r.right * z, b: r.bottom * z, w: r.width * z, h: r.height * z })
  const box = (el) => scaled(el.getBoundingClientRect(), zoomOf(el))
  /** A label's text: its lines, its box, and whether any of it shows inside its fit box. */
  const label = (el, fitBox) => {
    // The text itself: every text node's own boxes, never an element's.
    const rg = document.createRange()
    const rs = []
    const walk = document.createTreeWalker(el, NodeFilter.SHOW_TEXT)
    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
      if (n.data.trim() === '') continue
      rg.selectNodeContents(n)
      const z = zoomOf(n.parentElement)
      for (const r of rg.getClientRects()) if (r.width > 0.5) rs.push(scaled(r, z))
    }
    const tops = new Set(rs.map((r) => Math.round(r.t)))
    const fb = fitBox ? box(fitBox) : null
    const inside = rs.filter((r) => !fb || (r.b > fb.t + 0.5 && r.t < fb.b - 0.5))
    return {
      text: el.textContent.trim(),
      lines: tops.size,
      drawn: inside.length > 0,
      l: Math.min(...rs.map((r) => r.l)), r: Math.max(...rs.map((r) => r.r)), t: Math.min(...rs.map((r) => r.t)),
      w: rs.reduce((a, r) => Math.max(a, r.w), 0),
      fit: fb,
    }
  }
  window.__lk = {
    legacy: LEGACY,
    rootPx: () => parseFloat(getComputedStyle(document.documentElement).fontSize),
    center(expr) {
      const el = expr()
      if (!el) return null
      el.scrollIntoView({ block: 'nearest' })
      const b = box(el)
      return [b.l + b.w / 2, b.t + b.h / 2]
    },
    openList: () => document.querySelector(L + ' [class*=awsui_dropdown_][class*=awsui_open_]'),
    /** The open dropdown: its box, its trigger's, and every option's label. */
    measure(trigger) {
      const d = this.openList()
      if (!d) return null
      const t = trigger()
      const items = [...d.querySelectorAll('[role=option], [role=menuitem]')].map((o) => {
        const fit = o.querySelector('[class*=awsui_label-content_]')
        const text = fit ? fit.firstElementChild : o
        return label(text, fit)
      })
      return { list: box(d), trig: box(t), items }
    },
    /** Scroll the open list to its foot: a long list draws only what it shows. */
    toFoot() {
      const d = this.openList()
      const sc = d && [d, ...d.querySelectorAll('*')].find((e) => e.scrollHeight > e.clientHeight + 1
        && /auto|scroll/.test(getComputedStyle(e).overflowY))
      if (!sc) return false
      sc.scrollTop = sc.scrollHeight
      sc.dispatchEvent(new Event('scroll'))
      return true
    },
    /** A picker's own label, once chosen. */
    chosen(trigger) {
      const s = trigger().querySelector('[class*=awsui_trigger_]')
      return s ? label(s, s) : null
    },
    newCards() {
      return [...document.querySelectorAll(L + ' .lk2-choice')].map((c) => {
        const b = box(c)
        const t = box(c.querySelector('.lk2-choice-title > span'))
        return { dx: t.l - b.l, dy: t.t - b.t }
      })
    },
    sexWidth: () => box(document.querySelector(L + ' .lk2-choice-sub button')).w,
  }
})()`

const args = Object.fromEntries(process.argv.slice(2).map((a) => {
  const m = /^--([^=]+)(?:=(.*))?$/.exec(a)
  return m ? [m[1], m[2] ?? true] : [a, true]
}))

let failed = 0
let ran = 0
function check(label, ok, detail = '') {
  ran++
  if (!ok) failed++
  console.log(ok ? `  ok    ${label}` : `  FAIL  ${label}${detail ? `\n          ${detail}` : ''}`)
}
const near = (a, b, tol = TOL) => Math.abs(a - b) <= tol
const px = (n) => `${n.toFixed(1)}px`

/** One window size on one zoom rule: every menu, opened and measured. */
async function measureAll(browser, origin, [w, h]) {
  const tab = await browser.tab(w, h)
  await tab.go(`${origin}/?still`)
  await tab.eval(`new Promise((ok, fail) => {
    const end = Date.now() + 10000
    const f = () => window.brEmit ? ok(1) : Date.now() > end ? fail(new Error('the mock never started')) : setTimeout(f, 20)
    f()
  })`)
  await tab.eval(DRIVER)
  await tab.eval(PAGE)
  const run = (js) => tab.eval(`(async () => { ${js} })()`)
  const settle = () => sleep(350)
  /** A real press: the mouse, where the element is drawn. */
  const mouse = async (expr) => {
    const at = await tab.eval(`window.__lk.center(() => ${expr})`)
    if (!at) throw new Error(`nothing to press: ${expr}`)
    for (const type of ['mouseMoved', 'mousePressed', 'mouseReleased']) {
      await tab.send('Input.dispatchMouseEvent', { type, x: at[0], y: at[1], button: 'left', clickCount: 1 })
    }
    await settle()
  }
  const escape = async () => {
    for (const type of ['keyDown', 'keyUp']) {
      await tab.send('Input.dispatchKeyEvent', { type, key: 'Escape', code: 'Escape', windowsVirtualKeyCode: 27 })
    }
    await settle()
  }
  const out = { legacy: await tab.eval('window.__lk.legacy'), rootPx: await tab.eval('window.__lk.rootPx()') }
  const open = async (name, trigger) => {
    await mouse(trigger)
    out[name] = await tab.eval(`window.__lk.measure(() => ${trigger})`)
  }

  await run(`await __br.lockerV2(); await __br.until(() => __br.has('Nightshift', '${L}'), 8000, 'My Looks')`)
  const CARD = `document.querySelector('${L} .lk2-card-menu button')`
  await open('card', CARD)
  await escape()

  await run(`__br.click('button', 'New')`)
  await settle()
  out.newCards = await tab.eval('window.__lk.newCards()')
  out.sexWidth = await tab.eval('window.__lk.sexWidth()')
  const SEX = `document.querySelector('${L} .lk2-choice-sub button')`
  await open('sex', SEX)
  await escape()

  await run(`__br.click('button', 'Create'); await __br.until(() => __br.has('Randomize', '${L}'), 8000, 'the editor')`)
  await mouse(`[...document.querySelectorAll('${L} .lk2-add button')].find((b) => b.textContent.trim() === 'Add more')`)
  await mouse(`[...document.querySelectorAll('${L} .lk2-menu button')].find((b) => b.textContent.trim() === 'Tattoos')`)
  const ZONE = `document.querySelector('${L} .lk2-tatnew .lk2-tatzonepick button')`
  await open('zone', ZONE)
  await mouse(`[...document.querySelectorAll('${L} [role=option]')].find((o) => o.textContent.trim() === 'Torso')`)
  const TAT = `[...document.querySelectorAll('${L} .lk2-tatnew button[aria-haspopup]')].pop()`
  await open('tattoo', TAT)
  // The rest of the list, scrolled to: it draws only what it shows.
  out.scrolled = await tab.eval('window.__lk.toFoot()')
  await settle()
  out.tattooFoot = await tab.eval(`window.__lk.measure(() => ${TAT})`)
  await tab.eval(`(() => { const d = window.__lk.openList(); const sc = d && [d, ...d.querySelectorAll('*')]
    .find((e) => e.scrollHeight > e.clientHeight + 1); if (sc) { sc.scrollTop = 0; sc.dispatchEvent(new Event('scroll')) } })()`)
  await settle()
  // The longest name the mock has that fits, chosen: it stands on its row's picker.
  const LONG = 'Flaming Cross Over Two Pistols'
  out.longListed = out.tattoo?.items.some((i) => i.text === LONG) ?? false
  await mouse(`[...document.querySelectorAll('${L} [role=option]')].find((o) => o.textContent.trim() === '${LONG}')`)
  out.chosen = await tab.eval(`(() => {
    const b = [...document.querySelectorAll('${L} .lk2-tatzone button[aria-haspopup]')]
      .find((x) => x.textContent.trim() === '${LONG}')
    return b ? window.__lk.chosen(() => b) : null
  })()`)
  // That row's own picker: its list, and the name too long for any picker
  // chosen -- not drawn on the picker, never "...".
  const ROW = `[...document.querySelectorAll('${L} .lk2-tatzone button[aria-haspopup]')].find((x) => x.textContent.trim() === '${LONG}')`
  await open('row', ROW)
  const PICK = `[...document.querySelectorAll('${L} [role=option]')].find((o) => o.textContent.trim() === '${TOO_LONG}')`
  if (!(await tab.eval(`!!(${PICK})`))) {
    await tab.eval('window.__lk.toFoot()')
    await settle()
  }
  await mouse(PICK)
  out.chosenLong = await tab.eval(`(() => {
    const b = [...document.querySelectorAll('${L} .lk2-tatzone button[aria-haspopup]')]
      .find((x) => x.textContent.trim() === '${TOO_LONG}')
    return b ? window.__lk.chosen(() => b) : null
  })()`)
  return out
}

const t0 = Date.now()
const built = typeof args.dist === 'string' ? { dir: resolve(args.dist), remove: () => {} } : await buildMock(uiRoot)
const server = await serve(built.dir)
const results = { legacy: {}, standard: {} }
try {
  for (const [model, standardZoom] of [['legacy', false], ['standard', true]]) {
    const browser = await launch({ standardZoom })
    try {
      for (const size of SIZES) {
        const key = `${size[0]}x${size[1]}`
        try {
          results[model][key] = await measureAll(browser, server.origin, size)
        } catch (e) {
          results[model][key] = { error: e.message.split(/\r?\n/)[0] }
        }
      }
    } finally {
      await browser.close()
    }
  }
} finally {
  server.close()
  built.remove()
}

// The browser asked for each rule must be on it, or nothing here means much.
check('CEF 103\'s zoom rule and Chromium 128\'s, each where it was asked for',
  Object.values(results.legacy).every((r) => r.legacy === true)
  && Object.values(results.standard).every((r) => r.legacy === false))

const MENUS = ['card', 'sex', 'zone', 'tattoo', 'tattooFoot', 'row']
for (const [w, h] of SIZES) {
  const key = `${w}x${h}`
  for (const model of ['legacy', 'standard']) {
    const r = results[model][key]
    const at = `${key}, ${model === 'legacy' ? 'CEF 103' : 'CEF 144'}`
    if (r.error) { check(`${at}: the screen draws`, false, r.error); continue }
    const em = r.rootPx
    for (const name of MENUS) {
      const m = r[name]
      if (!m) { check(`${at}: the ${name} menu opens`, false); continue }
      const items = m.items
      const wrapped = items.filter((i) => i.drawn && i.lines > 1).map((i) => i.text)
      const out = items.filter((i) => i.drawn && i.fit && i.r > i.fit.r + 0.5).map((i) => i.text)
      // A label drawn is on its box's one line, never below an empty one.
      const low = items.filter((i) => i.drawn && i.fit && i.t - i.fit.t > 0.5 * em).map((i) => i.text)
      check(`${at}: the ${name} menu's every option on one line, or not drawn`, items.length > 0 && wrapped.length === 0
        && out.length === 0 && low.length === 0,
        `wrapped: ${wrapped.join(' | ')}; run out: ${out.join(' | ')}; a line down: ${low.join(' | ')}`)
      check(`${at}: the ${name} menu 15em tall at most`, m.list.h <= 15 * em + 2.5, `${px(m.list.h)} for 15em of ${px(15 * em)}`)
      if (name === 'card') {
        const widest = Math.max(...items.map((i) => i.w))
        check(`${at}: a card's "..." menu as wide as its words and its padding, no wider`,
          m.list.w >= widest && m.list.w <= widest + 4 * em && items.every((i) => i.drawn),
          `${px(m.list.w)} for words ${px(widest)}`)
      } else {
        check(`${at}: the ${name} picker's list is the picker's width, under it`,
          near(m.list.w, m.trig.w) && near(m.list.l, m.trig.l), `list ${px(m.list.w)} at ${px(m.list.l)}, picker ${px(m.trig.w)} at ${px(m.trig.l)}`)
      }
    }
    check(`${at}: New's two titles at the top left of their cards, 1em in`,
      r.newCards.length === 2 && r.newCards.every((c) => near(c.dx, em) && near(c.dy, em)),
      JSON.stringify(r.newCards.map((c) => [c.dx.toFixed(1), c.dy.toFixed(1)])) + ` for 1em of ${px(em)}`)
    check(`${at}: the Male / Female dropdown 8.5em wide`, near(r.sexWidth, 8.5 * em), `${px(r.sexWidth)} for ${px(8.5 * em)}`)
    check(`${at}: the longest tattoo name is in the list, and once chosen sits on its picker, whole, on one line`,
      r.longListed && r.chosen !== null && r.chosen.drawn && r.chosen.lines === 1 && r.chosen.r <= r.chosen.fit.r + 0.5,
      JSON.stringify(r.chosen))
    check(`${at}: a name too long for its picker, chosen, is not drawn on it -- never "..."`,
      r.chosenLong !== null && r.chosenLong !== undefined && !r.chosenLong.drawn, JSON.stringify(r.chosenLong))
    const tatItems = [...(r.tattoo?.items ?? []), ...(r.tattooFoot?.items ?? [])]
    const tooLong = tatItems.find((i) => i.text === TOO_LONG)
    check(`${at}: a name wider than its picker is in the list and not drawn`, tooLong !== undefined && !tooLong.drawn,
      JSON.stringify(tooLong))
    // The new row's picker has the row's whole width: every name the game
    // has, up to "Japanese Warrior and Skull" and longer, is drawn in it.
    const hidden = tatItems.filter((i) => i.text !== TOO_LONG && !i.drawn).map((i) => i.text)
    check(`${at}: every other tattoo name in the list is drawn`, tatItems.length > 0 && hidden.length === 0,
      `not drawn: ${[...new Set(hidden)].join(' | ')}`)
  }
  // SAME: CEF 103 and CEF 144 draw each menu alike.
  const a = results.legacy[key]
  const b = results.standard[key]
  if (a.error || b.error) continue
  for (const name of MENUS) {
    const x = a[name]
    const y = b[name]
    if (!x || !y) continue
    check(`${key}: the ${name} menu the same on CEF 103 and CEF 144`,
      near(x.list.w, y.list.w) && near(x.list.h, y.list.h) && near(x.list.l - x.trig.l, y.list.l - y.trig.l)
      && near(x.list.t - x.trig.t, y.list.t - y.trig.t),
      `103: ${px(x.list.w)} x ${px(x.list.h)}; 144: ${px(y.list.w)} x ${px(y.list.h)}`)
  }
}

console.log(`\ntest-lockerv2-menus: ${ran - failed}/${ran} passed (${((Date.now() - t0) / 1000).toFixed(1)}s)`)
process.exit(failed > 0 ? 1 : 0)
