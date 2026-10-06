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
  const page = { posts: [], app: [], timers: [], observers: [], listeners: { window: {}, document: {} } }
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
    'terminal-window-title': { textContent: '' },
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

if (failed > 0) {
  console.error(`test-terminal-desktop: ${failed} of ${ran} assertions failed`)
  process.exit(1)
}
console.log(`test-terminal-desktop: ${ran} assertions ok`)
