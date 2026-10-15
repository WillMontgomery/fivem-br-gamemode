/**
 * A HEADLESS BROWSER FOR THE UI'S CHECKS: the page as the browser mock draws
 * it, built, served and driven over the DevTools protocol, with nothing but
 * Node and a Chromium that is already on the machine.
 *
 *   buildMock(uiRoot)   a production build of src/ with the browser mock in it
 *                       (`import.meta.env.DEV` read as true in src/ alone), in
 *                       a temp folder -- never the resource. What `npm run dev`
 *                       shows, minified, served as static files.
 *   serve(dir)          a static server on 127.0.0.1, on a port the OS picks.
 *   launch()            headless Edge or Chrome, on a port the OS picks, and a
 *                       client for its first tab.
 *
 * WHICH BROWSER. BR_UI_BROWSER names one outright; otherwise Edge (on every
 * Windows box), then Chrome and Chromium where Linux and macOS keep them --
 * GitHub's Ubuntu runners carry both Chrome and Edge. None found is a failure
 * that says so, never a silent pass: a check that skipped on a machine with
 * no browser would be a check that never ran in CI.
 */
import { spawn, spawnSync } from 'node:child_process'
import { existsSync, mkdtempSync, readFileSync, realpathSync, rmSync } from 'node:fs'
import http from 'node:http'
import { tmpdir } from 'node:os'
import { extname, join, resolve, sep } from 'node:path'
import { pathToFileURL } from 'node:url'

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms))

function onPath(name) {
  const which = spawnSync(process.platform === 'win32' ? 'where' : 'which', [name], { encoding: 'utf8' })
  if (which.status !== 0) return null
  const first = which.stdout.split(/\r?\n/).find(Boolean)
  return first && existsSync(first) ? first : null
}

export function findBrowser() {
  const named = process.env.BR_UI_BROWSER
  if (named) {
    if (!existsSync(named)) throw new Error(`BR_UI_BROWSER names ${named}, which does not exist`)
    return named
  }
  const candidates = []
  if (process.platform === 'win32') {
    for (const root of [process.env['ProgramFiles(x86)'], process.env.ProgramFiles, process.env.LOCALAPPDATA]) {
      if (!root) continue
      candidates.push(join(root, 'Microsoft', 'Edge', 'Application', 'msedge.exe'))
      candidates.push(join(root, 'Google', 'Chrome', 'Application', 'chrome.exe'))
    }
  } else if (process.platform === 'darwin') {
    candidates.push('/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge')
    candidates.push('/Applications/Google Chrome.app/Contents/MacOS/Google Chrome')
    candidates.push('/Applications/Chromium.app/Contents/MacOS/Chromium')
  }
  for (const c of candidates) if (existsSync(c)) return c
  for (const name of ['google-chrome', 'google-chrome-stable', 'chromium', 'chromium-browser',
    'microsoft-edge', 'microsoft-edge-stable']) {
    const found = onPath(name)
    if (found) return found
  }
  throw new Error('no Chromium browser found (Edge, Chrome or Chromium); set BR_UI_BROWSER to one')
}

/** A production build of the page WITH the browser mock, into a temp folder. */
export async function buildMock(root) {
  // The long, real path: vite names modules by it, and a short (8.3) or
  // junctioned spelling of the same folder would match none of them.
  const uiRoot = realpathSync.native(root)
  const norm = (p) => resolve(p).toLowerCase()
  const src = norm(join(uiRoot, 'src')) + sep
  const outDir = mkdtempSync(join(tmpdir(), 'br-ui-mock-'))
  const vite = await import(pathToFileURL(join(uiRoot, 'node_modules', 'vite', 'dist', 'node', 'index.js')).href)
  const mockOn = {
    name: 'br-mock-in-build',
    enforce: 'pre',
    transform(code, id) {
      if (!norm(id.split('?')[0]).startsWith(src)) return null
      if (!code.includes('import.meta.env.DEV')) return null
      return { code: code.replaceAll('import.meta.env.DEV', 'true'), map: null }
    },
  }
  const cwd = process.cwd()
  // Tailwind resolves `content` from the working directory.
  process.chdir(uiRoot)
  try {
    await vite.build({
      root: uiRoot,
      configFile: join(uiRoot, 'vite.config.ts'),
      logLevel: 'error',
      plugins: [mockOn],
      // A fixed stamp: this build is thrown away, and must not ask git.
      define: { __BUILD_STAMP__: JSON.stringify('layout check') },
      build: { outDir, emptyOutDir: true, reportCompressedSize: false },
    })
  } finally {
    process.chdir(cwd)
  }
  return { dir: outDir, remove: () => rmSync(outDir, { recursive: true, force: true }) }
}

const TYPES = {
  '.html': 'text/html', '.js': 'text/javascript', '.css': 'text/css', '.woff2': 'font/woff2',
  '.woff': 'font/woff', '.png': 'image/png', '.svg': 'image/svg+xml', '.ogg': 'audio/ogg',
  '.mp3': 'audio/mpeg', '.json': 'application/json', '.webp': 'image/webp', '.jpg': 'image/jpeg',
}

/** A static server for `dir` on 127.0.0.1; resolves to { origin, close }. */
export function serve(dir, extra = {}) {
  const root = resolve(dir)
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://x')
    let p = decodeURIComponent(url.pathname)
    if (extra[p] !== undefined) {
      res.writeHead(200, { 'content-type': 'text/html' })
      res.end(extra[p])
      return
    }
    if (p.endsWith('/')) p += 'index.html'
    const file = resolve(join(root, p))
    if (!file.startsWith(root)) { res.writeHead(403); res.end(); return }
    try {
      const body = readFileSync(file)
      res.writeHead(200, { 'content-type': TYPES[extname(file)] ?? 'application/octet-stream', 'cache-control': 'max-age=3600' })
      res.end(body)
    } catch {
      res.writeHead(404); res.end()
    }
  })
  return new Promise((ok) => {
    server.listen(0, '127.0.0.1', () => {
      ok({ origin: `http://127.0.0.1:${server.address().port}`, close: () => server.close() })
    })
  })
}

/** How long one DevTools call may take before the browser is taken for dead. */
const CALL_MS = 60000

/**
 * A DevTools client on one tab. A browser that goes away fails every call
 * waiting on it, and a call that never answers fails after CALL_MS: a check
 * that hung on a crashed browser would hold the build forever, saying nothing.
 */
class Tab {
  constructor(ws) {
    this.ws = ws
    this.nextId = 0
    this.pending = new Map()
    this.listeners = []
    this.gone = null
    const lost = (why) => {
      if (this.gone) return
      this.gone = new Error(`the browser went away (${why})`)
      for (const { fail } of this.pending.values()) fail(this.gone)
      this.pending.clear()
      for (const fn of [...this.listeners]) fn({ method: 'br.gone' })
    }
    ws.onclose = () => lost('its connection closed')
    ws.onerror = () => lost('its connection failed')
    ws.onmessage = (e) => {
      const m = JSON.parse(typeof e.data === 'string' ? e.data : e.data.toString())
      if (m.id && this.pending.has(m.id)) {
        const { ok, fail } = this.pending.get(m.id)
        this.pending.delete(m.id)
        if (m.error) fail(new Error(`${m.error.message} ${m.error.data ?? ''}`)); else ok(m.result)
      } else for (const fn of this.listeners) fn(m)
    }
  }

  send(method, params = {}) {
    if (this.gone) return Promise.reject(this.gone)
    return new Promise((ok, fail) => {
      const id = ++this.nextId
      const timer = setTimeout(() => {
        this.pending.delete(id)
        fail(new Error(`${method} had no answer in ${CALL_MS / 1000} s`))
      }, CALL_MS)
      this.pending.set(id, {
        ok: (v) => { clearTimeout(timer); ok(v) },
        fail: (e) => { clearTimeout(timer); fail(e) },
      })
      this.ws.send(JSON.stringify({ id, method, params }))
    })
  }

  /** Evaluate an expression in the page; promises are awaited, values returned. */
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, awaitPromise: true, returnByValue: true })
    if (r.exceptionDetails) {
      const d = r.exceptionDetails
      throw new Error(`in page: ${d.exception?.description ?? d.text}`.slice(0, 1500))
    }
    return r.result.value
  }

  /** Load `url` and wait for its load event. */
  async go(url) {
    const loaded = new Promise((ok, fail) => {
      const fn = (m) => {
        if (m.method === 'Page.loadEventFired' || m.method === 'br.gone') {
          this.listeners.splice(this.listeners.indexOf(fn), 1)
          if (m.method === 'br.gone') fail(this.gone); else ok()
        }
      }
      this.listeners.push(fn)
    })
    await this.send('Page.navigate', { url })
    let timer
    await Promise.race([loaded, new Promise((_, fail) => {
      timer = setTimeout(() => fail(new Error(`${url} did not load in ${CALL_MS / 1000} s`)), CALL_MS)
    })]).finally(() => clearTimeout(timer))
  }

  async size(width, height) {
    await this.send('Emulation.setDeviceMetricsOverride', { width, height, deviceScaleFactor: 1, mobile: false })
  }

  close() { try { this.ws.close() } catch { /* gone */ } }
}

async function until(fn, ms, what) {
  const end = Date.now() + ms
  for (;;) {
    try { const v = await fn(); if (v) return v } catch { /* not yet */ }
    if (Date.now() > end) throw new Error(`timed out waiting for ${what}`)
    await sleep(100)
  }
}

/** Headless Chromium; resolves to { exe, tab(), close }. */
export async function launch() {
  const exe = findBrowser()
  const profile = mkdtempSync(join(tmpdir(), 'br-ui-browser-'))
  const args = [
    '--headless=new', '--remote-debugging-port=0', `--user-data-dir=${profile}`,
    '--no-first-run', '--no-default-browser-check', '--disable-extensions',
    '--disable-background-timer-throttling', '--disable-renderer-backgrounding',
    '--disable-backgrounding-occluded-windows', '--force-device-scale-factor=1',
    '--window-size=3840,2160', '--mute-audio', '--autoplay-policy=no-user-gesture-required',
    // CSS `zoom` AS CEF 103 DOES IT. Chromium 128 standardized zoom, and a box
    // measured inside a zoomed element now comes back in screen px; FiveM's
    // CEF reports it in the element's own (screens/lockerv2/scope.ts,
    // legacyZoom). Locker v2's Cloudscape island is zoomed and measures and
    // places its menus inside it, so on the newer rule they come out the wrong
    // size, in a browser the game never runs.
    '--disable-blink-features=StandardizedBrowserZoom',
  ]
  // Linux CI runners refuse Chromium's user-namespace sandbox; the only page
  // this ever loads is our own, from 127.0.0.1.
  if (process.platform === 'linux') args.push('--no-sandbox')
  args.push('about:blank')
  // NOT A HANDLE ON THE BROWSER. On Windows msedge.exe hands itself to another
  // process and exits at once, so the browser is found, and closed, through
  // the port it writes into its profile -- never through this child.
  const child = spawn(exe, args, { stdio: 'ignore' })
  child.on('error', () => {})
  const portFile = join(profile, 'DevToolsActivePort')
  const port = await until(() => existsSync(portFile) && readFileSync(portFile, 'utf8').split(/\r?\n/)[0],
    30000, `${exe} to start`)
  const version = await until(async () => (await fetch(`http://127.0.0.1:${port}/json/version`)).json(),
    10000, 'the browser to answer')

  const opened = []
  let closed = false
  const close = async () => {
    if (closed) return
    closed = true
    for (const t of opened) t.close()
    try {
      const ws = new WebSocket(version.webSocketDebuggerUrl)
      await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail })
      ws.send(JSON.stringify({ id: 1, method: 'Browser.close' }))
      await new Promise((ok) => { ws.onclose = ok; setTimeout(ok, 5000) })
    } catch { /* already gone */ }
    try { child.kill() } catch { /* long gone */ }
    // Chromium holds its profile for a moment after it closes.
    for (let i = 0; i < 40; i++) {
      try { rmSync(profile, { recursive: true, force: true }); break } catch { await sleep(250) }
    }
  }
  // A check that throws or is interrupted still takes its browser down.
  process.once('exit', () => { if (!closed) try { child.kill() } catch { /* gone */ } })
  for (const sig of ['SIGINT', 'SIGTERM']) process.once(sig, () => { void close().then(() => process.exit(1)) })

  // The browser's own session, for opening windows.
  const bws = new WebSocket(version.webSocketDebuggerUrl)
  await new Promise((ok, fail) => { bws.onopen = ok; bws.onerror = fail })
  const browserSession = new Tab(bws)
  opened.push(browserSession)

  /**
   * A fresh page IN ITS OWN WINDOW, sized, with Page and Runtime enabled. A
   * background tab is a hidden page, and a hidden page gets no animation
   * frames -- a check waiting on one would wait forever.
   */
  const tab = async (width = 1920, height = 1080) => {
    const { targetId } = await browserSession.send('Target.createTarget', {
      url: 'about:blank', newWindow: true, width, height,
    })
    const ws = new WebSocket(`ws://127.0.0.1:${port}/devtools/page/${targetId}`)
    await new Promise((ok, fail) => { ws.onopen = ok; ws.onerror = fail })
    const t = new Tab(ws)
    opened.push(t)
    await t.send('Page.enable')
    await t.send('Runtime.enable')
    await t.send('Emulation.setFocusEmulationEnabled', { enabled: true })
    await t.size(width, height)
    return t
  }

  return { exe, tab, close }
}
