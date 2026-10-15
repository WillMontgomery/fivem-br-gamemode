// THE RULES OF check-cef.mjs, PURE, SO test-cef.mjs CAN PROVE EACH ONE FAILS (#413).
//
// FiveM's CEF goes from Chromium 103 to 144. Cfx's list of what breaks, and
// the rule here that keeps each one out of the tree:
//
//   C1 dialog          alert() / confirm() / prompt() are gone in NUI
//   C2 mutation-event  DOMNodeInserted, DOMSubtreeModified... removed
//                      (Chromium 127) -> MutationObserver
//   C3 exec-command    document.execCommand('copy') copies only from a
//                      FOCUSED element
//   C4 zoom            CSS `zoom` standardized: a zoomed element's
//                      getBoundingClientRect is in screen px on 144, in the
//                      element's own px on 103
//   C5 url-data        URLs throw on forbidden characters (< > |)
//   C6 blocked-api     Picture-in-Picture and other APIs reaching outside the
//                      game throw; WebUSB/Bluetooth/HID/Serial and printing are
//                      blocked; the microphone and camera are the parent
//                      resource's only
//   C7 unload          (Chromium, 103 -> 144) the unload event is deprecated
//                      and may not fire
//   C8 manifest        secure-context checks may block resources on adamant,
//                      bodacious or a legacy __resource.lua -> cerulean
//   C9 zoom-shim       the Season 2 screens' zoom stays measured as on 103
//                      (src/cef/zoomRect.ts, scripts/zoom-rect.mjs)
//
// Every rule reads code with its comments blanked out (offsets kept, so line
// numbers stay true), because the reason a rule exists has to be writable
// next to the code it protects.

const blankRun = (m) => m.replace(/[^\n]/g, ' ')

/** After one of these (or at the start), a `/` opens a regex, not a division. */
const REGEX_AFTER = new Set(['', '(', ',', '=', ':', '[', '!', '&', '|', '?', '{', '}', ';', '+', '-', '*', '%', '~', '^', '>'])

/**
 * Comments to spaces, newlines kept, read the way a lexer would: a `//` or
 * `/*` inside a string, a template or a regex is not a comment (the #413
 * review hid an alert() after `"see //"`, and one after `"image/*"`).
 *
 * Every mistake it can make shows MORE code, never less: a quote it reads
 * wrongly (JSX text's "Don't") opens a string that ends at the line's end, and
 * inside a string nothing is blanked. `//` still needs a line start or
 * whitespace before it, so JSX text's `https://` is never a comment.
 */
export function blankComments(text, { html = false } = {}) {
  const src = html ? text.replace(/<!--[\s\S]*?-->/g, blankRun) : text
  let out = ''
  let i = 0
  let prev = ''          // the last significant code character, for regexes
  const stack = []       // 'tpl' inside a template's text; a number inside ${ }
  const top = () => stack[stack.length - 1]
  while (i < src.length) {
    const c = src[i]
    const n = src[i + 1]
    if (top() === 'tpl') {
      if (c === '\\') { out += src.slice(i, i + 2); i += 2; continue }
      if (c === '`') { stack.pop(); out += c; i++; prev = '`'; continue }
      if (c === '$' && n === '{') { stack.push(0); out += '${'; i += 2; prev = '{'; continue }
      out += c; i++; continue
    }
    if (c === '/' && n === '*') {
      const end = src.indexOf('*/', i + 2)
      const stop = end === -1 ? src.length : end + 2
      out += blankRun(src.slice(i, stop)); i = stop; continue
    }
    if (c === '/' && n === '/' && (i === 0 || /\s/.test(src[i - 1]))) {
      const end = src.indexOf('\n', i)
      const stop = end === -1 ? src.length : end
      out += blankRun(src.slice(i, stop)); i = stop; continue
    }
    if (c === '\'' || c === '"') {
      let j = i + 1
      while (j < src.length && src[j] !== c && src[j] !== '\n') j += src[j] === '\\' ? 2 : 1
      const stop = Math.min(src[j] === c ? j + 1 : j, src.length)
      out += src.slice(i, stop); i = stop; prev = c; continue
    }
    if (c === '`') { stack.push('tpl'); out += c; i++; continue }
    if (c === '/' && (REGEX_AFTER.has(prev) || /(?:^|[^\w$])(?:return|typeof|case|in|of|void|delete|throw|yield|await)$/.test(out.slice(-16).trimEnd()))) {
      let j = i + 1
      let cls = false
      while (j < src.length && src[j] !== '\n' && (cls || src[j] !== '/')) {
        if (src[j] === '\\') j++
        else if (src[j] === '[') cls = true
        else if (src[j] === ']') cls = false
        j++
      }
      if (src[j] === '/') { out += src.slice(i, j + 1); i = j + 1; prev = '/'; continue }
    }
    if (typeof top() === 'number') {
      if (c === '{') stack[stack.length - 1]++
      else if (c === '}') {
        if (top() === 0) { stack.pop(); out += c; i++; prev = ''; continue }
        stack[stack.length - 1]--
      }
    }
    if (!/\s/.test(c)) prev = /[\w$)\]]/.test(c) ? 'w' : c
    out += c
    i++
  }
  return out
}

export function lineOf(text, index) {
  let n = 1
  for (let i = 0; i < index && i < text.length; i++) if (text.charCodeAt(i) === 10) n++
  return n
}

/** Index of the `)` closing the `(` at `open`, or -1. */
function closeParen(text, open) {
  let depth = 0
  for (let i = open; i < text.length; i++) {
    const c = text[i]
    if (c === '(') depth++
    else if (c === ')' && --depth === 0) return i
  }
  return -1
}

// ---------------------------------------------------------------------------
// C4's and C5's allowances: each one a file and the reason it is safe on both
// engines. A new entry is a decision someone wrote down, never an accident.
// ---------------------------------------------------------------------------
export const ZOOM_ALLOWED = new Map([
  ['ui-src/src/screens/LockerV2.tsx',
    "the Cloudscape island (zoom = root px / 14); Cloudscape measures it through src/cef/zoomRect.ts, which answers as CEF 103 does"],
  ['ui-src/src/screens/lockerv2/scope.ts',
    "the island's portals (hover card, slider tooltip) wear its zoom, measured the same way"],
  ['ui-src/src/screens/lockerv2/Footer.tsx',
    'a tutorial anchor undoes the zoom (1/z, then z inside it): a true zoom of 1, measured alike on 103 and 144'],
  ['ui-src/src/screens/lockerv2/Tabs.tsx',
    'a tutorial anchor undoes the zoom (1/z): a true zoom of 1, measured alike on 103 and 144'],
  ['ui-src/src/screens/MarketV2.tsx',
    "the Season 2 Market's island, as Locker v2's (#411): Cloudscape measures through src/cef/zoomRect.ts;"
      + " Done's tutorial anchor undoes the zoom (1/z, then z inside it), a true zoom of 1 on both engines"],
])

export const URL_ALLOWED = new Map([
  ['ui-src/src/bridge/nui.ts', new Map([
    ['name', 'a CallbackName: one of the constants in bridge/types.ts'],
  ])],
  ['ui-src/src/screens/lockerv2/shots.ts', new Map([
    ['txd', 'refused unless it matches /^[A-Za-z0-9_-]{1,64}$/ (takeShot)'],
    ['nonce', 'a counter'],
  ])],
  ['resources/[computer]/cuchi_computer/nui/br.js', new Map([
    ['RES', 'GetParentResourceName(), or the literal resource name'],
    ['name', "one of br.js's own callback names, passed as literals"],
  ])],
])

const SAFE_URL_EXPR = /^(?:resourceName\(\)|GetParentResourceName\(\)|encodeURIComponent\([\s\S]*\))$/
const URL_SCHEME = /^(?:https?|wss?|nui|cfx-nui[\w-]*):\/\//

const MUTATION_EVENT = /\bDOM(?:NodeInserted(?:IntoDocument)?|NodeRemoved(?:FromDocument)?|SubtreeModified|AttrModified|CharacterDataModified|AttributeNameChanged|ElementNameChanged)\b|createEvent\(\s*['"]MutationEvents?['"]/g

const BLOCKED = [
  [/\b(?:requestPictureInPicture|exitPictureInPicture|pictureInPictureElement|pictureInPictureEnabled|documentPictureInPicture)\b/g,
    'Picture-in-Picture reaches outside the game: disabled in CEF 144, and it throws'],
  [/\bnavigator\s*(?:\??\.\s*|\[\s*['"`])(?:usb|bluetooth|hid|serial)\b/g,
    'WebUSB, WebBluetooth, WebHID and Serial are blocked in CEF 144'],
  [/\b(?:getUserMedia|webkitGetUserMedia|getDisplayMedia|mediaDevices)\b/g,
    'the microphone and camera are the parent resource\'s only in CEF 144, never a frame\'s -- and voice is pma-voice\'s, in Lua'],
  [/\bwindow\s*\.\s*print\s*\(/g,
    'printing is blocked in CEF 144'],
]

const UNLOAD = /addEventListener\(\s*(['"`])unload\1|\bonunload\b/g

const DIALOG_MSG = 'a browser dialog: gone from NUI in CEF 144 (it returns without asking anything).'
  + ' Draw the question in the page -- lockerv2/Modals.tsx is one.'

/** Where the top-level statement holding `index` starts: the last line at or
 *  before it that starts in column 0 with code (not a closing bracket). Our
 *  sources are formatted, so a top-level statement is a column-0 line and
 *  everything indented under it. */
function statementStart(code, index) {
  let at = code.lastIndexOf('\n', index - 1) + 1
  while (at > 0 && /^(?:[\s})\]]|$)/.test(code.slice(at, at + 1))) at = code.lastIndexOf('\n', at - 2) + 1
  return at
}

/**
 * Does the code declare `name` itself, where the call at `index` sees it?
 * At module scope (a column-0 const, let, var or function) it covers the file;
 * anywhere else -- a binding, a parameter, a method -- only the same top-level
 * statement. A `{ confirm }` parameter of one component no longer excuses a
 * real confirm() in another (#413 review).
 */
function declaresLocally(code, name, index) {
  const n = name
  if (new RegExp(`^(?:export\\s+)?(?:(?:async\\s+)?function\\s+${n}\\b|(?:const|let|var)\\s+${n}\\b)`, 'm').test(code)) return true
  const at = statementStart(code, index)
  const decl = new RegExp(
    `\\bfunction\\s+${n}\\b|\\b(?:const|let|var)\\s+${n}\\b|[({,]\\s*${n}\\s*[,)}=:]`
    + `|^\\s*(?:async\\s+)?${n}\\s*\\([^)]*\\)\\s*[:{]`, 'gm',
  )
  for (const d of code.matchAll(decl)) if (statementStart(code, d.index) === at) return true
  return false
}

/**
 * A dialog, however it is reached: `alert (x)`, `confirm?.(x)`, `(0, alert)(x)`,
 * and on the global object `window.confirm`, `self?.alert` or
 * `window['prompt']` -- the global ones whether called or not, since a
 * reference is only ever taken to call it. The #413 review got the first
 * three and the bracket past the old pattern.
 */
const DIALOG = new RegExp([
  /(?<![\w$.])(alert|confirm|prompt)\s*(?:\?\.\s*)?\(/.source,
  /(?<![\w$.])(?:window|self|globalThis|top|parent)\s*\??\.\s*(alert|confirm|prompt)\b/.source,
  /(?<![\w$.])(?:window|self|globalThis|top|parent)\s*(?:\?\.\s*)?\[\s*(['"`])(alert|confirm|prompt)\3\s*\]/.source,
  /,\s*(alert|confirm|prompt)\s*\)\s*(?:\?\.\s*)?\(/.source,
].join('|'), 'g')

function dialogFindings(code, file, out, { bundle }) {
  for (const m of code.matchAll(DIALOG)) {
    const name = m[1] ?? m[2] ?? m[4] ?? m[5]
    const qualified = m[1] === undefined
    const open = m.index + m[0].length - 1
    if (!qualified) {
      // A definition, not a call: `function confirm(`, or `confirm(...) {`.
      if (/\bfunction\s*$/.test(code.slice(Math.max(0, m.index - 12), m.index))) continue
      const close = closeParen(code, open)
      if (close > 0 && /^\s*(?::[^;{=]*)?\{/.test(code.slice(close + 1, close + 40))) continue
      if (!bundle && declaresLocally(code, name, m.index)) continue
    }
    out.push({ rule: 'C1 dialog', file, line: lineOf(code, m.index), msg: `${name}(): ${DIALOG_MSG}` })
  }
}

function execCommandFindings(code, file, out) {
  const lines = code.split('\n')
  const starts = [0]
  for (let i = 0; i < code.length; i++) if (code.charCodeAt(i) === 10) starts.push(i + 1)
  // Any reference, not only a call: `document['execCommand'](...)` and a
  // bound copy are the same command (#413 review).
  for (const m of code.matchAll(/\bexecCommand\b/g)) {
    const at = lineOf(code, m.index) - 1
    // Back to the function this call sits in: the nearest line above it that
    // opens one (a control-flow line ending in `{` does not), 40 lines at most.
    let from = Math.max(0, at - 40)
    for (let i = at - 1; i >= Math.max(0, at - 40); i--) {
      const l = lines[i]
      if (/^\s*(?:\}\s*)?(?:if|for|while|switch|catch|else|try|do)\b/.test(l)) continue
      if (/(?:=>|\bfunction\b[^{]*|\)\s*(?::\s*[^{=]+)?)\s*\{\s*$/.test(l)) { from = i; break }
    }
    const body = code.slice(starts[from], m.index)
    // THE FIELD THAT IS SELECTED IS THE ONE THAT MUST HAVE FOCUS: a focus on
    // anything else (document.body) leaves the copy empty on CEF 144.
    const selected = [...body.matchAll(/([\w$]+)\s*\??\.\s*(?:select|setSelectionRange)\s*\(/g)].pop()?.[1]
    const focus = selected
      ? new RegExp(`(?<![\\w$])${selected.replace(/\$/g, '\\$')}\\s*\\??\\.\\s*focus\\s*\\(`)
      : /\.focus\s*\(/
    if (!focus.test(body)) {
      out.push({
        rule: 'C3 exec-command', file, line: at + 1,
        msg: (selected ? `document.execCommand on \`${selected}\` with no ${selected}.focus() before it`
          : 'document.execCommand with no .focus() before it') + ' in the same function: CEF 144 copies only'
          + ' from a focused element, and returns false otherwise. Use ui/clipboard.ts copyText().',
      })
    }
  }
}

/** `zoom:` (CSS, a style object, a type), `.style.zoom`, the property named
 *  as a string (`style['zoom']`, `setProperty('zoom')`, `{ 'zoom': 2 }`), and
 *  the shorthand `{ zoom }` (a style object, or Object.assign's) -- the last
 *  three got past the old pattern in the #413 review. A variable called zoom
 *  is not one: `const zoom = 2` passes. */
const ZOOM = /(?<![\w-])zoom\s*:|\.style\s*\??\.\s*zoom\b|(['"`])zoom\1|[{,]\s*zoom\s*(?=[,}])/g

function zoomFindings(code, file, out) {
  if (ZOOM_ALLOWED.has(file)) return
  for (const m of code.matchAll(ZOOM)) {
    out.push({
      rule: 'C4 zoom', file, line: lineOf(code, m.index),
      msg: 'CSS zoom: CEF 144 standardized it, and a zoomed element\'s getBoundingClientRect is in screen px'
        + ' there but in its own px on CEF 103, so measuring code differs between them. Size with rem or'
        + ' font-size, or add the file to ZOOM_ALLOWED (cef-rules.mjs) with the reason it measures alike.',
    })
  }
}

/** Every `...` literal in `code`: its first text run and its ${} expressions. */
export function templateLiterals(code) {
  const out = []
  for (let i = 0; i < code.length; i++) {
    if (code[i] !== '`') continue
    const start = i
    let head = null
    const exprs = []
    let text = ''
    i++
    while (i < code.length && code[i] !== '`') {
      if (code[i] === '\\') { text += code[i + 1] ?? ''; i += 2; continue }
      if (code[i] === '$' && code[i + 1] === '{') {
        if (head === null) head = text
        let depth = 1
        let j = i + 2
        while (j < code.length && depth > 0) {
          if (code[j] === '{') depth++
          else if (code[j] === '}') depth--
          j++
        }
        exprs.push(code.slice(i + 2, j - 1).trim())
        i = j
        continue
      }
      text += code[i]
      i++
    }
    out.push({ start, head: head ?? text, exprs })
  }
  return out
}

function urlFindings(code, file, out) {
  const allowed = URL_ALLOWED.get(file) ?? new Map()
  const bad = (expr, index) => out.push({
    rule: 'C5 url-data', file, line: lineOf(code, index),
    msg: `a URL built from \`${expr}\`: CEF 144 throws on < > | in a URL. Wrap it in encodeURIComponent(),`
      + ' or add it to URL_ALLOWED (cef-rules.mjs) with the reason it cannot carry one.',
  })
  for (const t of templateLiterals(code)) {
    if (!URL_SCHEME.test(t.head)) continue
    for (const e of t.exprs) if (!SAFE_URL_EXPR.test(e) && !allowed.has(e)) bad(e, t.start)
  }
  for (const m of code.matchAll(/(['"])(?:https?|wss?|nui):\/\/[^'"\n]*\1\s*\+\s*([\w$.]+(?:\([^)]*\))?)/g)) {
    if (!SAFE_URL_EXPR.test(m[2]) && !allowed.has(m[2])) bad(m[2], m.index)
  }
  for (const m of code.matchAll(/\bnew\s+URL\(\s*(?![`'"])([^,)]*)/g)) {
    if (!allowed.has('new URL')) bad(`new URL(${m[1].trim()})`, m.index)
  }
}

function patternFindings(code, file, out, re, rule, msg) {
  for (const m of code.matchAll(re)) {
    out.push({ rule, file, line: lineOf(code, m.index), msg: typeof msg === 'function' ? msg(m) : msg })
  }
}

const MUTATION_MSG = (m) => `${m[0]}: mutation events are removed in CEF 144 (Chromium 127). Use a MutationObserver.`
const UNLOAD_MSG = 'the unload event: deprecated in Chromium and may never fire. Use pagehide or visibilitychange.'

/** Code we write and ship as written: TS/TSX, hand-written JS, CSS and HTML. */
export function scanSource(text, file) {
  const html = /\.(?:html?|vue)$/.test(file)
  const code = blankComments(text, { html })
  const out = []
  if (!/\.css$/.test(file)) {
    dialogFindings(code, file, out, { bundle: false })
    execCommandFindings(code, file, out)
    urlFindings(code, file, out)
    for (const [re, why] of BLOCKED) patternFindings(code, file, out, re, 'C6 blocked-api', (m) => `${m[0]}: ${why}.`)
    patternFindings(code, file, out, UNLOAD, 'C7 unload', UNLOAD_MSG)
  }
  patternFindings(code, file, out, MUTATION_EVENT, 'C2 mutation-event', MUTATION_MSG)
  zoomFindings(code, file, out)
  return out
}

/** Built or vendored-minified output: what a dependency can bring in. */
export function scanBundle(text, file) {
  const out = []
  if (/\.css$/.test(file)) {
    patternFindings(text, file, out, /(?<![\w-])zoom\s*:/g, 'C4 zoom',
      'CSS zoom in a built stylesheet: its boxes measure differently on CEF 103 and 144 (see cef-rules.mjs C4).')
    return out
  }
  dialogFindings(text, file, out, { bundle: true })
  patternFindings(text, file, out, MUTATION_EVENT, 'C2 mutation-event', MUTATION_MSG)
  for (const [re, why] of BLOCKED) patternFindings(text, file, out, re, 'C6 blocked-api', (m) => `${m[0]}: ${why}.`)
  patternFindings(text, file, out, UNLOAD, 'C7 unload', UNLOAD_MSG)
  return out
}

/** C8: `manifests` is [{ file, text }] for every fxmanifest.lua; `legacy` every __resource.lua. */
export function scanManifests(manifests, legacy) {
  const out = []
  for (const f of legacy) {
    out.push({ rule: 'C8 manifest', file: f, line: 1,
      msg: 'a legacy __resource.lua: CEF 144\'s secure-context checks may block its pages. Use an fxmanifest.lua with fx_version \'cerulean\'.' })
  }
  for (const { file, text } of manifests) {
    // Lua comments blanked first, `--[[ ]]` blocks included; then the LAST
    // fx_version, because a manifest is Lua and a later call wins (the #413
    // review: a second, adamant line after a cerulean one passed).
    const code = text.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, blankRun).replace(/--[^\n]*/g, blankRun)
    const m = [...code.matchAll(/^\s*fx_version\s*\(?\s*['"]([\w-]+)['"]/gm)].pop()
    if (!m || m[1] !== 'cerulean') {
      out.push({ rule: 'C8 manifest', file, line: m ? lineOf(text, m.index) : 1,
        msg: `fx_version ${m ? `'${m[1]}'` : 'missing'}: CEF 144's secure-context checks may block a resource on`
          + ' adamant or bodacious. Use \'cerulean\' -- and read the resource\'s other version-dependent behavior first.' })
    }
  }
  return out
}

/**
 * C9: the zoom shim is wired. vite.config.ts runs both plugins (in `plugins`
 * and in optimizeDeps' esbuild `plugins`, not merely called somewhere), the
 * helper measures through currentCSSZoom, and the built br_ui carries it.
 *
 * `chunks` is every built br_ui chunk ([{ file, text }], or null before a
 * build): Cloudscape went from LockerV2.js into the shared index2.js with the
 * Market (#411), and may move again, so no one file is named. A Cloudscape
 * call the rewrite missed fails the build itself (zoom-rect.mjs
 * unrewrittenRects), where module names still exist.
 */
export function checkZoomShim({ viteConfig, helper, chunks }) {
  const out = []
  const cfg = blankComments(viteConfig)
  const inBuild = /\bplugins\s*:\s*\[[^\]]*\bzoomRectPlugin\(\)/.test(cfg)
  const inDeps = /\besbuildOptions\s*:\s*\{[^}]*\bplugins\s*:\s*\[[^\]]*\bzoomRectEsbuild\(\)/.test(cfg)
  if (!inBuild || !inDeps) {
    out.push({ rule: 'C9 zoom-shim', file: 'ui-src/vite.config.ts', line: 1,
      msg: 'zoomRectPlugin() in `plugins` and zoomRectEsbuild() in optimizeDeps.esbuildOptions.plugins must both'
        + ' run: without them Cloudscape sizes the Season 2 screens\' dropdowns in screen px on CEF 144 and they'
        + ' draw past the panel (scripts/zoom-rect.mjs).' })
  }
  if (!/currentCSSZoom/.test(helper) || !/__brZoomRect/.test(helper)) {
    out.push({ rule: 'C9 zoom-shim', file: 'ui-src/src/cef/zoomRect.ts', line: 1,
      msg: 'the helper must define __brZoomRect and divide by currentCSSZoom where it exists.' })
  }
  if (chunks !== null) {
    const defines = chunks.some((c) => /['"`]__brZoomRect['"`]/.test(c.text))
    const calls = chunks.some((c) => /\.__brZoomRect\(\)/.test(c.text))
    if (!defines || !calls) {
      out.push({ rule: 'C9 zoom-shim', file: 'resources/[fivem-royale]/br_ui/ui/assets', line: 1,
        msg: `no built br_ui chunk ${defines ? 'measures through' : 'defines'} __brZoomRect: rebuild (npm run build).` })
    }
  }
  return out
}
