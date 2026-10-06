#!/usr/bin/env node
/**
 * THE COMPUTER'S DESKTOP, DRIVEN (#396, review of round 2).
 *
 * cuchi_computer/nui/br.js is the page between client/shell.lua and the
 * terminal app: it boots the desktop, launches the app from its icon, and
 * relays both ways. It is plain browser script with no module system, so it
 * runs here in a node:vm context over a small model of the page it lives in --
 * the elements it looks up, upstream's window manager (Load, OpenApp,
 * CloseApp, MinimizeApp) as far as it changes what br.js reads, the app's
 * iframe as a window that records what it is posted, and fetch as the NUI
 * callbacks it records.
 *
 * WHAT IS HELD HERE: A RUN'S LAST WORD NEVER GOES NOWHERE. The review of
 * round 2 found the answer to a paid run thrown away when the player closed
 * the app's window while it loaded and then closed the computer; and lost the
 * same way when it reached an app still loading after its icon was clicked.
 * Every path an answer can take to a surface that is not there is driven
 * below, and each must end with the answer shown in the app or handed back to
 * the shell (`missed`) for a toast -- exactly once.
 *
 * AND THE TAB'S LOADING SYMBOL (owner, 2026-10-06): the app's page loads put
 * br.css's loading symbol on the window's tab, and NOTHING MAY LEAVE IT
 * SPINNING (#385) -- the page showing, a load dropped, the app's window
 * closed, the computer closed, a fresh app, and the backstop timer each take
 * it down.
 *
 * What a browser has to show (the boot screen, the windows, the colors) was
 * checked in a browser for #396's reports, not here.
 *
 * Run: npm run build:terminal (and so npm run build), or node scripts/test-terminal-desktop.mjs
 */

import { readFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'
import vm from 'node:vm'

const ROOT = join(dirname(fileURLToPath(import.meta.url)), '..')
const BR_JS = join(ROOT, '..', 'resources', '[computer]', 'cuchi_computer', 'nui', 'br.js')
const SOURCE = readFileSync(BR_JS, 'utf8')

let failed = 0
let ran = 0
const ok = (cond, name, detail) => {
  ran++
  if (!cond) {
    failed++
    console.error(`FAIL ${name}${detail !== undefined ? `\n     ${JSON.stringify(detail)}` : ''}`)
  }
}
const eq = (got, want, name) => ok(got === want, name, { got, want })

/** A style declaration: unset properties read '', and a write tells the observers of its element. */
function styleFor(page, el) {
  return new Proxy({}, {
    get: (t, k) => (k in t ? t[k] : ''),
    set: (t, k, v) => {
      t[k] = v
      if (el) for (const o of page.observers) if (o.target === el) o.cb([])
      return true
    },
  })
}

function classList() {
  const s = new Set()
  return { add: (...c) => c.forEach((x) => s.add(x)), remove: (...c) => c.forEach((x) => s.delete(x)), contains: (c) => s.has(c) }
}

/** A fresh page with br.js loaded and its DOMContentLoaded run. */
function desktop() {
  const page = { posts: [], app: [], timers: [], observers: [], listeners: { window: {}, document: {} },
    clock: 0, later: new Map(), nextLater: 1 }
  const listen = (where) => (type, fn) => {
    ;(page.listeners[where][type] ||= []).push(fn)
  }

  const appWindow = { postMessage: (msg) => page.app.push(msg) }
  let src = 'about:blank'
  const frame = {
    contentWindow: appWindow,
    getAttribute: (k) => (k === 'src' ? src : null),
    setAttribute: (k, v) => {
      if (k === 'src') src = v
    },
    focus: () => {},
  }
  frame.style = styleFor(page, null)
  const win = { classList: classList(), offsetWidth: 1254, offsetHeight: 662, offsetLeft: 0, offsetTop: 0 }
  win.style = styleFor(page, win)
  win.style.display = 'none'
  const img = { alt: 'x' }
  const icon = { querySelector: () => img, textContent: '', appendChild: () => {}, onclick: null }
  const buttons = { quit: { onclick: null }, maximize: { onclick: null } }
  const title = { addEventListener: () => {} }
  const container = { style: styleFor(page, null) }
  const els = {
    'terminal-frame': frame,
    'app-terminal': win,
    desktop: { clientWidth: 1280, clientHeight: 684 },
    container,
    terminal: icon,
    'terminal-window-title': { textContent: '', classList: classList() },
    hours: { innerText: '' },
    date: { innerText: '' },
    'terminal-quit': buttons.quit,
    'terminal-maximize': buttons.maximize,
    'app-terminal-title': title,
  }

  const document = {
    getElementById: (id) => els[id] || null,
    addEventListener: listen('document'),
    createTextNode: (t) => ({ t }),
    body: { style: styleFor(page, null), classList: classList() },
  }
  const ctx = {
    document,
    window: null,
    innerWidth: 1280,
    innerHeight: 720,
    Locale: 'EN',
    openedApps: [],
    apps: ['terminal'],
    Applications: { terminal: { width: 1440, height: 880 } },
    GetParentResourceName: () => 'cuchi_computer',
    GetLocale: () => 'en-US',
    fetch: (url, opts) => {
      page.posts.push({ name: url.split('/').pop(), body: JSON.parse(opts.body) })
      return Promise.resolve()
    },
    // Upstream's window manager, as far as it changes what br.js reads.
    Load: (show, _text, _ms, cb) => {
      if (show) {
        container.style.display = 'none'
        page.timers.push(cb)
      }
    },
    OpenApp: (name) => {
      ctx.openedApps.push(name)
      win.style.display = 'flex'
      win.style.visibility = 'visible'
    },
    CloseApp: () => {
      win.style.display = 'none'
    },
    MutationObserver: class {
      constructor(cb) {
        this.cb = cb
      }
      observe(target) {
        page.observers.push({ target, cb: this.cb })
      }
    },
    // A clock that moves only when the test says (D.wait).
    setTimeout: (fn, ms) => {
      const id = page.nextLater++
      page.later.set(id, { at: page.clock + ms, fn })
      return id
    },
    clearTimeout: (id) => {
      page.later.delete(id)
    },
    console,
    Math,
    Number,
    JSON,
    Object,
    Array,
    Date,
    Promise,
  }
  ctx.window = { addEventListener: listen('window'), innerWidth: 1280, innerHeight: 720 }
  vm.createContext(ctx)
  vm.runInContext(SOURCE, ctx, { filename: 'br.js' })
  for (const fn of page.listeners.document.DOMContentLoaded || []) fn()

  const message = (data, source) => {
    for (const fn of page.listeners.window.message || []) fn({ data, source })
  }
  const D = {
    page,
    frameSrc: () => src,
    /** The desktop behind the boot screen: 'block' once the boot has ended. */
    desk: () => container.style.display,
    /** client/shell.lua's SendNUIMessage. */
    lua: (msg) => message(msg, null),
    /** The app, from its own window -- which only posts while it is loaded. */
    fromApp: (msg) => {
      if (src !== 'about:blank') message({ brTerminal: 1, ...msg }, appWindow)
    },
    /** From the frame's window whatever it holds: br.js's own gate decides. */
    fromFrame: (msg) => message({ brTerminal: 1, ...msg }, appWindow),
    /** br:open, and the boot's timer run out. */
    boot: () => {
      D.lua({ type: 'br:open', state: { terminalId: 'dev' }, copy: {}, catalog: {}, desktop: { bootMinMs: 7000, bootMaxMs: 10000 } })
      const t = page.timers.splice(0)
      t.forEach((cb) => cb())
    },
    icon: () => icon.onclick(),
    quit: () => buttons.quit.onclick(),
    minimize: () => {
      win.style.visibility = 'hidden'
    },
    restore: () => {
      win.style.visibility = 'visible'
    },
    escape: () => {
      for (const fn of page.listeners.document.keydown || []) fn({ key: 'Escape', preventDefault: () => {} })
    },
    result: (r) => D.lua({ type: 'br:result', result: r }),
    posted: () => page.posts.map((p) => `${p.name}${p.body.toast ? ':' + p.body.toast : ''}${p.body.why ? ':' + p.body.why : ''}`),
    appResults: () => page.app.filter((m) => m.type === 'result').map((m) => m.result.code + (m.result.toast ? ':' + m.result.toast : '')),
    appTypes: () => page.app.map((m) => m.type),
    /** Is the window's tab showing the loading symbol? */
    tabLoading: () => els['terminal-window-title'].classList.contains('br-loading'),
    /** Timers still waiting. */
    pending: () => page.later.size,
    /** Let `ms` pass: every timer due by then runs, in order. */
    wait: (ms) => {
      const until = page.clock + ms
      for (;;) {
        let next = null
        for (const [id, t] of page.later) if (t.at <= until && (next === null || t.at < next[1].at)) next = [id, t]
        if (next === null) break
        page.later.delete(next[0])
        page.clock = next[1].at
        next[1].fn()
      }
      page.clock = until
    },
  }
  return D
}

const RUNNING = { functionId: 'scan', ok: true, code: 'running', runMs: 4000 }
const done = (toast) => ({ functionId: 'scan', ok: true, code: 'done', balance: 1050, toast })
const refused = (toast) => ({ functionId: 'scan', ok: false, code: 'no_site', toast })

// ── the review's repro: the app's window closed while it loads, then the computer ──
{
  const D = desktop()
  D.boot()
  eq(D.frameSrc(), 'about:blank', 'the boot ends on the desktop with the app not loaded')
  D.icon()
  eq(D.frameSrc(), 'apps/terminal/index.html', 'the icon loads the app')
  D.fromApp({ type: 'ready' })
  eq(D.appTypes().join(), 'state', 'the ready app gets its state')
  D.result(RUNNING)
  eq(D.appResults().join(), 'running', 'and the run loading')
  D.quit()
  eq(D.frameSrc(), 'about:blank', 'the window\'s close unloads the app')
  D.result(done('Done. Your new balance is: 1,050 Volts.'))
  eq(D.appResults().length, 1, 'the done answer is not posted to an app that is gone')
  eq(D.posted().length, 0, 'nor handed back while the computer is up')
  D.escape()
  eq(D.posted().join(' | '), 'missed:Done. Your new balance is: 1,050 Volts. | close:escape',
    'Escape hands the answer back for a toast, then says the close')
}

// ── the app's window closed, then reopened: the held answer is shown, not toasted ──
{
  const D = desktop()
  D.boot()
  D.icon()
  D.fromApp({ type: 'ready' })
  D.quit()
  D.result(done('Held.'))
  D.icon()
  eq(D.appResults().length, 0, 'the reopened app, still loading, is not posted to')
  D.fromApp({ type: 'ready' })
  eq(D.appTypes().join(), 'state,state,result', 'when ready: its state, then the held answer')
  eq(D.appResults().join(), 'done:Held.', 'the answer it missed')
  D.escape()
  eq(D.posted().join(' | '), 'close:escape', 'shown, so nothing is handed back')
}

// ── an answer that reaches an app still loading after its icon was clicked ──
{
  const D = desktop()
  D.boot()
  D.icon()
  D.result(refused('No spot.'))
  D.lua({ type: 'br:update', state: { terminalId: 'dev', volts: 1 } })
  eq(D.page.app.length, 0, 'an app with no listener yet is posted nothing: not the answer, not the state')
  D.fromApp({ type: 'ready' })
  eq(D.appTypes().join(), 'state,result', 'once it is ready: the latest state, then the answer')
  eq(D.appResults().join(), 'no_site:No spot.', 'the answer it would have lost')
  eq(D.page.app[0].state.volts, 1, 'and the state is the one the update brought')

  // And the computer closed by br_core before the app was ready.
  const E = desktop()
  E.boot()
  E.icon()
  E.result(refused('No spot.'))
  E.lua({ type: 'br:close' })
  eq(E.posted().join(' | '), 'missed:No spot.', 'br_core closing it: handed back, and no close is said')
  E.fromApp({ type: 'ready' })
  eq(E.page.app.length, 0, 'and nothing reaches an app after the close')
}

// ── an answer that reaches a desktop that has already closed ──
{
  const D = desktop()
  D.boot()
  D.icon()
  D.fromApp({ type: 'ready' })
  D.escape()
  D.result(done('After.'))
  D.result(RUNNING)
  eq(D.posted().join(' | '), 'close:escape | missed:After.', 'a last word after the close is handed straight back; running is not')
}

// ── `running` is never held or handed back ──
{
  const D = desktop()
  D.boot()
  D.result(RUNNING)
  D.escape()
  eq(D.posted().join(' | '), 'close:escape', 'a run loading is the state\'s to say, not a toast')
}

// ── a minimized window: the app has the answer, the player has not seen it ──
{
  const D = desktop()
  D.boot()
  D.icon()
  D.fromApp({ type: 'ready' })
  D.minimize()
  D.result(done('Unseen.'))
  eq(D.appResults().join(), 'done:Unseen.', 'the minimized app is given the answer')
  D.escape()
  eq(D.posted().join(' | '), 'missed:Unseen. | close:escape', 'closed before it was shown again: handed back')

  const E = desktop()
  E.boot()
  E.icon()
  E.fromApp({ type: 'ready' })
  E.minimize()
  E.result(done('Seen.'))
  E.restore()
  E.escape()
  eq(E.posted().join(' | '), 'close:escape', 'shown again before the close: the player saw it')

  const F = desktop()
  F.boot()
  F.icon()
  F.fromApp({ type: 'ready' })
  F.minimize()
  F.result(done('Seen.'))
  F.icon()
  F.escape()
  eq(F.posted().join(' | '), 'close:escape', 'opened again from the icon: seen')

  const G = desktop()
  G.boot()
  G.icon()
  G.minimize()
  G.result(done('Held, then unseen.'))
  G.fromApp({ type: 'ready' })
  eq(G.appResults().join(), 'done:Held, then unseen.', 'an app that loads minimized is given what was held')
  G.escape()
  eq(G.posted().join(' | '), 'missed:Held, then unseen. | close:escape', 'and it goes back if never shown')
}

// ── shown normally: nothing is handed back ──
{
  const D = desktop()
  D.boot()
  D.icon()
  D.fromApp({ type: 'ready' })
  D.result(RUNNING)
  D.result(done('Shown.'))
  D.escape()
  eq(D.appResults().join(), 'running,done:Shown.', 'the app shows the run and its answer')
  eq(D.posted().join(' | '), 'close:escape', 'and nothing is toasted')
}

// ── a second last word while one is held hands the first back ──
{
  const D = desktop()
  D.boot()
  D.icon()
  D.fromApp({ type: 'ready' })
  D.quit()
  D.result(refused('First.'))
  D.result(done('Second.'))
  eq(D.posted().join(' | '), 'missed:First.', 'never dropped: the first goes back for a toast')
  D.icon()
  D.fromApp({ type: 'ready' })
  eq(D.appResults().join(), 'done:Second.', 'and the app is given the second')
}

// ── the boot: a closed session's timer never fires into a later one ──
{
  const D = desktop()
  D.lua({ type: 'br:open', state: { terminalId: 'dev' }, copy: {}, catalog: {}, desktop: { bootMinMs: 7000, bootMaxMs: 10000 } })
  const first = D.page.timers.splice(0)
  D.escape()
  D.lua({ type: 'br:open', state: { terminalId: 'dev' }, copy: {}, catalog: {}, desktop: { bootMinMs: 7000, bootMaxMs: 10000 } })
  first.forEach((cb) => cb())
  eq(D.page.timers.length, 1, 'the second opening boots anew')
  eq(D.desk(), 'none', 'the first boot\'s timer does not end the second boot')
  D.page.timers.splice(0).forEach((cb) => cb())
  eq(D.desk(), 'block', 'its own does: the desktop')
  D.lua({ type: 'br:open', state: { terminalId: 'dev' }, copy: {}, catalog: {}, desktop: { bootMinMs: 7000, bootMaxMs: 10000 } })
  eq(D.page.timers.length, 0, 'a second open while up is a refresh, not a reboot')
}

// ── the tab's loading symbol (owner, 2026-10-06) ──
{
  // A page load starts and ends: the symbol is on for exactly that long.
  const D = desktop()
  D.boot()
  D.icon()
  D.fromApp({ type: 'ready' })
  eq(D.tabLoading(), false, 'the tab shows the app\'s icon')
  D.fromApp({ type: 'loading', on: true, ms: 2000 })
  eq(D.tabLoading(), true, 'a load starts: the tab shows the loading symbol')
  D.wait(1999)
  eq(D.tabLoading(), true, 'and keeps it while the page loads')
  D.fromApp({ type: 'loading', on: false })
  eq(D.tabLoading(), false, 'the page shows: the symbol is taken off (the class goes, and its animation with it)')
  eq(D.pending(), 0, 'and no timer is left behind')

  // A new load replaces the one under way: the backstop follows the new one.
  D.fromApp({ type: 'loading', on: true, ms: 1000 })
  D.wait(900)
  D.fromApp({ type: 'loading', on: true, ms: 3000 })
  eq(D.pending(), 1, 'a replacing load re-arms one backstop, not two')
  D.wait(2500)
  eq(D.tabLoading(), true, 'the first load\'s backstop does not cut the second one short')
  D.fromApp({ type: 'loading', on: false })
  eq(D.tabLoading(), false, 'the second page shows: off')

  // THE BACKSTOP: an app that never says the page showed cannot leave it spinning.
  D.fromApp({ type: 'loading', on: true, ms: 3000 })
  D.wait(3999)
  eq(D.tabLoading(), true, 'an app that goes quiet: still loading at its length plus the slack')
  D.wait(1)
  eq(D.tabLoading(), false, 'and taken down a second after the load was due to end')
  D.fromApp({ type: 'loading', on: true, ms: 1e9 })
  D.wait(15000)
  eq(D.tabLoading(), false, 'a length past all reason is cut at the 15 s cap')
  D.fromApp({ type: 'loading', on: true, ms: 'soon' })
  D.wait(15000)
  eq(D.tabLoading(), false, 'and one that is not a number gets the cap too')
}
{
  // Every way the app or the computer goes away takes the symbol down.
  const D = desktop()
  D.boot()
  D.icon()
  D.fromApp({ type: 'ready' })
  D.fromApp({ type: 'loading', on: true, ms: 2000 })
  D.quit()
  eq(D.tabLoading(), false, 'the app\'s window closed mid-load: off')
  eq(D.pending(), 0, 'with its timer')

  D.icon()
  D.fromApp({ type: 'ready' })
  D.fromApp({ type: 'loading', on: true, ms: 2000 })
  D.escape()
  eq(D.tabLoading(), false, 'the computer closed mid-load: off')

  const E = desktop()
  E.boot()
  E.icon()
  E.fromApp({ type: 'ready' })
  E.fromApp({ type: 'loading', on: true, ms: 2000 })
  E.lua({ type: 'br:close' })
  eq(E.tabLoading(), false, 'br_core closing it mid-load: off')

  const F = desktop()
  F.boot()
  F.icon()
  F.fromApp({ type: 'ready' })
  F.fromApp({ type: 'loading', on: true, ms: 2000 })
  F.fromApp({ type: 'ready' })
  eq(F.tabLoading(), false, 'a fresh app says it is ready: it is loading nothing')

  // Only the app that is up, while the computer is.
  const G = desktop()
  G.boot()
  G.fromFrame({ type: 'loading', on: true, ms: 2000 })
  eq(G.tabLoading(), false, 'no app loaded in the window: a loading message is nobody\'s')
  G.icon()
  G.fromFrame({ type: 'loading', on: true, ms: 2000 })
  eq(G.tabLoading(), true, 'the app loaded: it is the app\'s')
  G.escape()
  G.fromFrame({ type: 'loading', on: true, ms: 2000 })
  eq(G.tabLoading(), false, 'and after the computer closed, nobody\'s again')
}

// ── the stylesheet: the only animation is the tab's, and only while it loads ──
{
  const css = readFileSync(join(ROOT, '..', 'resources', '[computer]', 'cuchi_computer', 'nui', 'br.css'), 'utf8')
    .replace(/\/\*[\s\S]*?\*\//g, '')
  const rules = [...css.matchAll(/([^{}]+)\{([^{}]*)\}/g)]
  const animated = rules.filter((m) => /(^|;|\s)animation(-name)?\s*:/.test(m[2]))
  eq(animated.length, 1, 'br.css animates one thing')
  ok(animated.every((m) => m[1].includes('#terminal-window-title.br-loading')),
    'the tab\'s icon, and only under .br-loading -- the class br.js takes off', animated.map((m) => m[1].trim()))
  ok(!/animation-play-state/.test(css), 'never paused in place: removed with its class')
}

if (failed > 0) {
  console.error(`test-terminal-desktop: ${failed} of ${ran} assertions failed`)
  process.exit(1)
}
console.log(`test-terminal-desktop: ${ran} assertions ok`)
