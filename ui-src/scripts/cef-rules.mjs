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
//   C9 zoom-shim       Locker v2's zoom stays measured as on 103
//                      (src/cef/zoomRect.ts, scripts/zoom-rect.mjs)
//
// Every rule reads code with its comments blanked out (offsets kept, so line
// numbers stay true), because the reason a rule exists has to be writable
// next to the code it protects.

/** Comments to spaces, newlines kept. `//` counts only at a line start or after
 *  whitespace, so `https://` in a string is never one. */
export function blankComments(text, { html = false } = {}) {
  const blank = (m) => m.replace(/[^\n]/g, ' ')
  let out = text.replace(/\/\*[\s\S]*?\*\//g, blank)
  if (html) out = out.replace(/<!--[\s\S]*?-->/g, blank)
  return out.replace(/(^|[ \t])\/\/[^\n]*/gm, (m, lead) => lead + blank(m.slice(lead.length)))
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
  [/\bnavigator\s*\.\s*(?:usb|bluetooth|hid|serial)\b/g,
    'WebUSB, WebBluetooth, WebHID and Serial are blocked in CEF 144'],
  [/\b(?:getUserMedia|webkitGetUserMedia|getDisplayMedia|mediaDevices)\b/g,
    'the microphone and camera are the parent resource\'s only in CEF 144, never a frame\'s -- and voice is pma-voice\'s, in Lua'],
  [/\bwindow\s*\.\s*print\s*\(/g,
    'printing is blocked in CEF 144'],
]

const UNLOAD = /addEventListener\(\s*['"]unload['"]|\bonunload\b/g

const DIALOG_MSG = 'a browser dialog: gone from NUI in CEF 144 (it returns without asking anything).'
  + ' Draw the question in the page -- lockerv2/Modals.tsx is one.'

/** Does `file` declare `name` itself (a local function, binding or parameter)? */
function declaresLocally(code, name) {
  const n = name
  return new RegExp(
    `\\bfunction\\s+${n}\\b|\\b(?:const|let|var)\\s+${n}\\b|[({,]\\s*${n}\\s*[,)}=:]`
    + `|^\\s*(?:async\\s+)?${n}\\s*\\([^)]*\\)\\s*[:{]`, 'm',
  ).test(code)
}

function dialogFindings(code, file, out, { bundle }) {
  const re = /(?<![\w$.])(alert|confirm|prompt)\(|\b(?:window|self|globalThis|top|parent)\s*\.\s*(alert|confirm|prompt)\s*\(/g
  for (const m of code.matchAll(re)) {
    const name = m[1] ?? m[2]
    const qualified = m[2] !== undefined
    const open = m.index + m[0].length - 1
    if (!qualified) {
      // A definition, not a call: `function confirm(`, or `confirm(...) {`.
      if (/\bfunction\s*$/.test(code.slice(Math.max(0, m.index - 12), m.index))) continue
      const close = closeParen(code, open)
      if (close > 0 && /^\s*(?::[^;{=]*)?\{/.test(code.slice(close + 1, close + 40))) continue
      if (!bundle && declaresLocally(code, name)) continue
    }
    out.push({ rule: 'C1 dialog', file, line: lineOf(code, m.index), msg: `${name}(): ${DIALOG_MSG}` })
  }
}

function execCommandFindings(code, file, out) {
  const lines = code.split('\n')
  const starts = [0]
  for (let i = 0; i < code.length; i++) if (code.charCodeAt(i) === 10) starts.push(i + 1)
  for (const m of code.matchAll(/\bexecCommand\s*\(/g)) {
    const at = lineOf(code, m.index) - 1
    // Back to the function this call sits in: the nearest line above it that
    // opens one (a control-flow line ending in `{` does not), 40 lines at most.
    let from = Math.max(0, at - 40)
    for (let i = at - 1; i >= Math.max(0, at - 40); i--) {
      const l = lines[i]
      if (/^\s*(?:\}\s*)?(?:if|for|while|switch|catch|else|try|do)\b/.test(l)) continue
      if (/(?:=>|\bfunction\b[^{]*|\)\s*(?::\s*[^{=]+)?)\s*\{\s*$/.test(l)) { from = i; break }
    }
    if (!/\.focus\s*\(/.test(code.slice(starts[from], m.index))) {
      out.push({
        rule: 'C3 exec-command', file, line: at + 1,
        msg: 'document.execCommand with no .focus() before it in the same function: CEF 144 copies only'
          + ' from a focused element, and returns false otherwise. Use ui/clipboard.ts copyText().',
      })
    }
  }
}

function zoomFindings(code, file, out) {
  if (ZOOM_ALLOWED.has(file)) return
  const re = /(?<![\w-])zoom\s*:|\.style\s*\.\s*zoom\b|setProperty\(\s*['"]zoom['"]/g
  for (const m of code.matchAll(re)) {
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
    // Anchored at a line's start, so a `-- fx_version ...` comment never counts.
    const m = /^\s*fx_version\s*\(?\s*['"]([\w-]+)['"]/m.exec(text)
    if (!m || m[1] !== 'cerulean') {
      out.push({ rule: 'C8 manifest', file, line: m ? lineOf(text, m.index) : 1,
        msg: `fx_version ${m ? `'${m[1]}'` : 'missing'}: CEF 144's secure-context checks may block a resource on`
          + ' adamant or bodacious. Use \'cerulean\' -- and read the resource\'s other version-dependent behavior first.' })
    }
  }
  return out
}

/** C9: the zoom shim is wired: vite.config.ts runs both plugins, the helper
 *  measures through currentCSSZoom, and the built locker carries it. */
export function checkZoomShim({ viteConfig, helper, lockerBundle }) {
  const out = []
  const cfg = blankComments(viteConfig)
  if (!/\bzoomRectPlugin\(\)/.test(cfg) || !/\bzoomRectEsbuild\(\)/.test(cfg)) {
    out.push({ rule: 'C9 zoom-shim', file: 'ui-src/vite.config.ts', line: 1,
      msg: 'zoomRectPlugin() and zoomRectEsbuild() must both run: without them Cloudscape sizes Locker v2\'s'
        + ' dropdowns in screen px on CEF 144 and they draw past the panel (scripts/zoom-rect.mjs).' })
  }
  if (!/currentCSSZoom/.test(helper) || !/__brZoomRect/.test(helper)) {
    out.push({ rule: 'C9 zoom-shim', file: 'ui-src/src/cef/zoomRect.ts', line: 1,
      msg: 'the helper must define __brZoomRect and divide by currentCSSZoom where it exists.' })
  }
  if (lockerBundle !== null && !/__brZoomRect/.test(lockerBundle)) {
    out.push({ rule: 'C9 zoom-shim', file: 'resources/[fivem-royale]/br_ui/ui/assets/LockerV2.js', line: 1,
      msg: 'the built locker does not measure through __brZoomRect: rebuild (npm run build).' })
  }
  return out
}
