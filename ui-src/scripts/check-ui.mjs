#!/usr/bin/env node
/**
 * THE DESIGN-SYSTEM GATE.
 *
 * check-css.mjs stops the build shipping something CEF cannot parse. This
 * stops it shipping something that parses perfectly and is the wrong design.
 *
 * Every rule here exists because a real miss got through and was found by a
 * human playing the game -- which is the most expensive possible way to find
 * "this panel is still on the old component library". Each one names the miss
 * it would have caught, so nobody has to guess whether a rule still earns its
 * place.
 *
 * These are STATIC checks over source and build output. They cannot tell you
 * whether something looks good; they can tell you it is inconsistent with the
 * system, which is a different and very findable class of bug.
 *
 * Run: npm run check:ui   (and as part of npm run build)
 */

import { readFileSync, readdirSync, statSync, existsSync } from 'fs'
import { join, relative, extname } from 'path'

// decodeURIComponent, and it is not optional: this repo lives under a path
// with a space in it, so the raw pathname is ".../William%20Montgomery/..."
// and every fs call silently finds nothing. A checker that reports "ok, 0
// warnings" because it read zero files is worse than no checker -- it was
// green on the first run while EndScreen was still importing HeroUI.
const ROOT = decodeURIComponent(new URL('..', import.meta.url).pathname)
  .replace(/^\/([A-Za-z]:)/, '$1')
const SRC = join(ROOT, 'src')
const OUT = join(ROOT, '..', 'resources', '[fivem-royale]', 'br_ui', 'ui')
const CORE = join(ROOT, '..', 'resources', '[fivem-royale]', 'br_core')

let failures = 0
let warnings = 0

function fail(rule, file, msg) {
  failures++
  console.error(`check-ui FAIL  [${rule}] ${file}\n               ${msg}`)
}
function warn(rule, file, msg) {
  warnings++
  console.warn(`check-ui warn  [${rule}] ${file}\n               ${msg}`)
}

function walk(dir, out = []) {
  if (!existsSync(dir)) return out
  for (const name of readdirSync(dir)) {
    const p = join(dir, name)
    if (statSync(p).isDirectory()) walk(p, out)
    else out.push(p)
  }
  return out
}

const files = walk(SRC).filter((f) => ['.ts', '.tsx', '.css'].includes(extname(f)))
const read = (f) => readFileSync(f, 'utf8')
const rel = (f) => relative(ROOT, f).replace(/\\/g, '/')

/**
 * Drop comments before searching for retired values.
 *
 * A rule that retires a colour has to be able to NAME it in the comment
 * explaining why it was retired -- the first cut of R2 failed on its own
 * documentation, which is a good way to teach people to ignore the checker.
 */
function stripComments(s) {
  return s
    .replace(/\/\*[\s\S]*?\*\//g, '')
    .replace(/^\s*\/\/.*$/gm, '')
}

/**
 * Brace-matched @keyframes bodies.
 *
 * A lazy /@keyframes[\s\S]*?\n\}/ stops at the closing brace of the LAST FRAME,
 * not of the block -- so it swallows the following rule and reports its
 * properties as being inside the animation. That is how `.leave-spinner`'s
 * width/height were blamed on @keyframes leaveSpin.
 */
/**
 * The opening `<button ...>` tag, in full.
 *
 * A regex cannot do this. `/<button[\s\S]*?>/` stops at the first `>` it
 * meets -- and in JSX that is almost always the arrow in `onClick={() => ...}`,
 * so the match ends before the className and every styled button in the
 * project looked unstyled. This tracks brace depth and stops at a `>` that is
 * genuinely closing the tag.
 */
function buttonTags(src) {
  const out = []
  for (const m of src.matchAll(/<button[\s>]/g)) {
    let depth = 0
    for (let i = m.index; i < src.length; i++) {
      const c = src[i]
      if (c === '{') depth++
      else if (c === '}') depth--
      else if (c === '>' && depth === 0 && src[i - 1] !== '=') {
        out.push(src.slice(m.index, i + 1))
        break
      }
    }
  }
  return out
}

function keyframeBlocks(css) {
  const out = []
  for (const m of css.matchAll(/@keyframes\s+[\w-]+\s*\{/g)) {
    let depth = 0
    for (let i = m.index; i < css.length; i++) {
      if (css[i] === '{') depth++
      else if (css[i] === '}' && --depth === 0) { out.push(css.slice(m.index, i + 1)); break }
    }
  }
  return out
}

// ---------------------------------------------------------------------------
// R1  No HeroUI outside the places it has actually earned.
//
// CAUGHT LATE: PartyPanel was still entirely HeroUI Buttons and Chips, and
// EndScreen still used HeroUI's Spinner, long after everything around them had
// moved to Btn and Ring. Both were found by a human noticing the screen looked
// unfinished. HeroUI is not banned -- it is pinned to v2 for good reasons and
// still fine for a modal shell -- but a component sneaking back in should be a
// decision, not an accident.
// ---------------------------------------------------------------------------
const HEROUI_ALLOWED = new Set([
  'src/main.tsx',        // HeroUIProvider: the theme root
])
for (const f of files) {
  if (!read(f).includes('@heroui/react')) continue
  if (HEROUI_ALLOWED.has(rel(f))) continue
  fail('R1 heroui', rel(f),
    'imports @heroui/react. Use ui/Btn, hud/Ring and the .plate/.panel classes,'
    + ' or add this file to HEROUI_ALLOWED with a reason.')
}

// ---------------------------------------------------------------------------
// R2  The retired palette must not come back.
//
// CAUGHT LATE: after the palette moved to cyan, chat's ALL channel was still
// on accent2 -- which had silently become VICTORY GOLD, so a chat label was
// wearing the one colour reserved for winning.
// ---------------------------------------------------------------------------
const RETIRED = [
  ['#a855f7', 'the old brand purple (now Epic loot only -- use --color-royale-accent)'],
  ['#9333ea', 'the old storm purple (storm is now #c026d3)'],
  ['#4cc9f0', 'the old accent2 cyan (accent2 is now victory gold)'],
  ['rgba(52,44,80', 'the old inventory active fill'],
  ['226,226,236', 'the icon squircle fill, removed in favour of --plate-fill'],
]
for (const f of files) {
  // Strip comments first. A rule that retires a colour has to be able to NAME
  // it in the comment explaining why, and the first cut of this failed on its
  // own documentation.
  const body = stripComments(read(f))
    // #a855f7 is retired as a BRAND colour and is still perfectly correct as
    // Epic loot -- that is the whole point of the move. The canonical rarity
    // tokens are where it is allowed to live.
    .replace(/--rarity-\d:\s*#[0-9a-fA-F]{6};/g, '')
  for (const [needle, why] of RETIRED) {
    if (body.includes(needle)) fail('R2 palette', rel(f), `uses ${needle} -- ${why}`)
  }
}

// ---------------------------------------------------------------------------
// R3  Interactive controls must carry the button language.
//
// A bare <button> with no `btn` class has no press travel, no hover cue and no
// sound, which is exactly how a screen ends up feeling half-built. Anything
// deliberately plain can opt out with `data-plain`.
// ---------------------------------------------------------------------------
for (const f of files.filter((x) => x.endsWith('.tsx'))) {
  const body = read(f)
  const buttons = buttonTags(body)
  for (const b of buttons) {
    if (b.includes('data-plain')) continue
    // Anywhere in the tag. Every styled button in the project builds its class
    // list in a template literal, which an attribute-shaped regex misses.
    if (/\bbtn\b/.test(b)) continue
    fail('R3 button', rel(f),
      'a <button> without the `btn` class: no press travel, no hover cue, no'
      + ' sound. Use ui/Btn, add `btn`, or mark it data-plain.')
  }
}

// ---------------------------------------------------------------------------
// R4  Numerals the player reads under pressure are Anton.
//
// `font-bold` on a large number means it is being set in Barlow at a weight
// Anton would do better -- the display face exists precisely for these.
// ---------------------------------------------------------------------------
for (const f of files.filter((x) => x.endsWith('.tsx'))) {
  for (const [i, line] of read(f).split('\n').entries()) {
    if (!/tabular-nums/.test(line)) continue
    if (/font-display/.test(line)) continue
    if (/text-\[0\.[0-7]/.test(line)) continue   // small print, Barlow is right
    warn('R4 numerals', `${rel(f)}:${i + 1}`,
      'tabular-nums without font-display -- a number read under pressure'
      + ' should be Anton.')
  }
}

// ---------------------------------------------------------------------------
// R5  GTA frontend sounds are combat-only.
//
// CAUGHT LATE: the whole interface was wired to HUD_FRONTEND_DEFAULT_SOUNDSET,
// which makes a standalone mode sound exactly like GTA Online's menus. Native
// audio is kept for cues that fire during shooting, where engine ducking is a
// real advantage a browser cannot reproduce.
// ---------------------------------------------------------------------------
const SFX_ALLOWED = new Set([
  'client/sfx.lua',        // the wrapper itself
  'client/inventory.lua',  // pickup + weapon switch: world events, must duck
  'client/probe.lua',      // native probes
  'client/debug.lua',
  'client/loot.lua',       // crate open: a world event, and it must duck
])
for (const f of walk(CORE).filter((x) => x.endsWith('.lua'))) {
  const r = relative(CORE, f).replace(/\\/g, '/')
  if (SFX_ALLOWED.has(r)) continue
  if (!read(f).includes('PlaySoundFrontend')) continue
  fail('R5 audio', `br_core/${r}`,
    'calls PlaySoundFrontend directly. Interface audio is synthesised in the'
    + ' browser (ui-src/src/audio/cues.ts); native is for combat cues only.')
}

// ---------------------------------------------------------------------------
// R6  Fonts reach the client.
//
// THE HIGHEST-VALUE CHECK HERE. A font missing from fxmanifest files{} renders
// perfectly in the browser and falls back to Segoe UI in game, silently, with
// the layout still plausible. That is not hypothetical -- the interface ran in
// the OS UI font for months because tailwind.config.ts asked for a Rajdhani
// that was never loaded.
// ---------------------------------------------------------------------------
const manifestPath = join(ROOT, '..', 'resources', '[fivem-royale]', 'br_ui', 'fxmanifest.lua')
if (existsSync(manifestPath) && existsSync(join(OUT, 'assets'))) {
  const manifest = readFileSync(manifestPath, 'utf8')
  const assets = readdirSync(join(OUT, 'assets'))
  const fonts = assets.filter((a) => /\.(woff2?|ttf|otf)$/.test(a))
  if (fonts.length === 0) {
    fail('R6 fonts', 'br_ui/ui/assets', 'no font files in the build output.')
  }
  for (const ext of new Set(fonts.map((f) => extname(f).slice(1)))) {
    if (!manifest.includes(`ui/assets/*.${ext}`)) {
      fail('R6 fonts', 'br_ui/fxmanifest.lua',
        `build output contains .${ext} fonts but files{} has no`
        + ` 'ui/assets/*.${ext}' glob -- they will silently fall back in game.`)
    }
  }
  // The standalone documents carry their own copy; they start before br_ui or
  // have no bundler at all, so they cannot borrow the bundle's.
  for (const [label, p] of [
    ['loadscreen', join(ROOT, '..', 'resources', '[fivem-royale]', 'br_loadscreen', 'index.html')],
    ['dui prompt', join(ROOT, '..', 'resources', '[fivem-royale]', 'br_ui', 'dui', 'prompt.html')],
  ]) {
    if (!existsSync(p)) continue
    if (!readFileSync(p, 'utf8').includes('@font-face')) {
      fail('R6 fonts', label,
        'no @font-face -- this document has no bundler and cannot borrow the'
        + ' bundle, so it will render in Segoe UI while everything else does not.')
    }
  }
}

// ---------------------------------------------------------------------------
// R7  Motion stays off the layout thread.
//
// A keyframe that animates a layout property costs real frames exactly when
// damage is landing. NoticeRow animates height deliberately and says so.
// ---------------------------------------------------------------------------
const cssFiles = files.filter((f) => f.endsWith('.css'))
for (const f of cssFiles) {
  const body = read(f)
  const blocks = keyframeBlocks(body)
  for (const b of blocks) {
    const bad = ['width:', 'height:', 'top:', 'left:', 'margin', 'padding']
      .filter((p) => new RegExp(`\\n\\s*${p}`).test(b))
    if (bad.length) {
      const name = (b.match(/@keyframes\s+([\w-]+)/) ?? [])[1]
      fail('R7 motion', rel(f),
        `@keyframes ${name} animates ${bad.join(', ')} -- transform/opacity only.`)
    }
    if (/box-shadow/.test(b)) {
      const name = (b.match(/@keyframes\s+([\w-]+)/) ?? [])[1]
      fail('R7 motion', rel(f), `@keyframes ${name} animates box-shadow.`)
    }
  }
}

// ---------------------------------------------------------------------------
// R8  Our class names must not collide with a Tailwind utility.
//
// CAUGHT LATE, AND IT SHIPPED TO A PLAYER: the loading ring's component class
// was `ring`, which is a Tailwind CORE UTILITY. The JIT scans source TEXT, saw
// the word, and emitted its own `.ring { box-shadow: 0 0 0 3px
// var(--tw-ring-color) }` -- default blue-500. Ours set no box-shadow, so both
// rules applied and every loader in the game wore a blue SQUARE outline
// (user, 2026-08-08).
//
// Unfindable in the source, trivial in the OUTPUT: the same class selector
// appears twice, once in a block full of --tw- properties. That is what this
// reads. It needs a build to have happened, so it is a no-op on a clean tree
// rather than a false pass -- `npm run build` runs vite first.
// ---------------------------------------------------------------------------
const builtCss = existsSync(join(OUT, 'assets'))
  ? readdirSync(join(OUT, 'assets')).filter((a) => a.endsWith('.css'))
  : []
for (const name of builtCss) {
  const css = readFileSync(join(OUT, 'assets', name), 'utf8')

  // Blocks whose selector is a single bare class, which is the only shape that
  // can collide. `.a .b`, `.a:hover` and friends cannot be a bare utility.
  //
  // LOOKBEHIND, not a capture group, for the delimiter. Matching `(^|\})`
  // CONSUMES the preceding brace, so the closing brace of rule N is no longer
  // available as the opening delimiter of rule N+1 -- the scan silently reads
  // every OTHER rule, which is why the first cut of this passed a build that
  // had the collision in it.
  const owners = new Map()   // class -> ['tailwind' | 'ours', ...]
  for (const m of css.matchAll(/(?<=^|[{}])\s*\.([a-zA-Z][\w-]*)\s*\{([^}]*)\}/g)) {
    const cls = m[1]
    const who = m[2].includes('--tw-') ? 'tailwind' : 'ours'
    const seen = owners.get(cls) ?? []
    seen.push(who)
    owners.set(cls, seen)
  }

  for (const [cls, who] of owners) {
    if (who.length < 2) continue
    if (!who.includes('tailwind') || !who.includes('ours')) continue
    fail('R8 collision', `br_ui/ui/assets/${name}`,
      `.${cls} is defined by BOTH Tailwind and index.css. Tailwind's rule is`
      + ` still live and applies whatever ours does not override -- rename the`
      + ` component class (this is how .ring got a blue square outline).`)
  }
}

// ---------------------------------------------------------------------------
// Result
// ---------------------------------------------------------------------------
if (failures) {
  console.error(`\ncheck-ui: ${failures} failure(s), ${warnings} warning(s)`)
  process.exit(1)
}
console.log(`check-ui: ok, ${warnings} warning(s)`)
