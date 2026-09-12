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
// COMMENTS ARE STRIPPED BEFORE THIS RULE LOOKS, AND THAT IS NOT A LOOSENING.
//
// The rule is about CALLS. It used to read the raw file, so it fired on
// br_core/client/dbno.lua the moment a comment there quoted the owner asking
// for MATE_CUE to be rewired to that native -- a file that names it only to
// explain why it does not call it. In a codebase whose house style is long
// explanatory comments, a rule that forbids naming a native in prose is a rule
// people delete rather than obey.
//
// A REAL CALL IS CODE, so this cannot hide one: only the text after a `--`
// goes, and a call sitting before a trailing comment on the same line survives.
const stripLuaComments = (src) =>
  src.replace(/--\[\[[\s\S]*?\]\]/g, ' ').replace(/--[^\n]*/g, ' ')

for (const f of walk(CORE).filter((x) => x.endsWith('.lua'))) {
  const r = relative(CORE, f).replace(/\\/g, '/')
  if (SFX_ALLOWED.has(r)) continue
  if (!stripLuaComments(read(f)).includes('PlaySoundFrontend')) continue
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
// R9  A transformed wrapper must be sized, or it eats `position: fixed`.
//
// CAUGHT BY A PLAYER, AND IT BROKE EVERY MENU IN THE GAME: `Page` wraps each
// full-screen screen in a div carrying an animated transform, and a
// transformed element becomes the CONTAINING BLOCK for every `position: fixed`
// descendant. The screens inside are all `fixed inset-0`, so instead of the
// viewport they resolved against a zero-height block at the top of the
// document -- collapsing to 0x0 and drawing off the top of the screen (user,
// 2026-08-09: "way above our vertical draw space", "opens a blank page").
//
// The rule is narrow and mechanical: if a class is animated by a keyframe that
// sets `transform`, and that class is applied alongside a wrapper class, the
// wrapper must establish a real box. Expressed here for the one wrapper that
// exists, because a general version would need a layout engine -- and a
// specific rule that fires is worth more than a general one that cannot.
// ---------------------------------------------------------------------------
{
  const cssPath = join(SRC, 'index.css')
  if (existsSync(cssPath)) {
    const css = read(cssPath)
    const transformsInPage = keyframeBlocks(css)
      .filter((b) => /@keyframes\s+page(In|Out)\b/.test(b))
      .some((b) => /transform\s*:/.test(b))

    if (transformsInPage) {
      // The .page rule itself, if it exists at all.
      //
      // No `(^|\})` anchor: the rule is preceded by a comment block, so the
      // character before it is `/` and an anchored pattern never matches --
      // which made the first cut of this fail on a perfectly good stylesheet.
      // `\s*\{` is enough to keep `.page-in {` and `.page-under {` out, since
      // the next character there is `-`.
      const rule = (css.match(/\.page\s*\{([^}]*)\}/) ?? [])[1] ?? null
      if (rule == null) {
        fail('R9 fixed-trap', 'src/index.css',
          '@keyframes pageIn/pageOut animate transform, but there is no `.page`'
          + ' rule. The wrapper carrying that transform becomes the containing'
          + ' block for every `fixed` child inside it -- they will collapse to'
          + ' 0x0. It must be position:fixed and inset:0.')
      } else if (!/position\s*:\s*fixed/.test(rule) || !/inset\s*:\s*0/.test(rule)) {
        fail('R9 fixed-trap', 'src/index.css',
          '.page carries an animated transform but is not `position: fixed;'
          + ' inset: 0`. Every `fixed inset-0` screen inside it will resolve'
          + ' against this box instead of the viewport and render off-screen.')
      }
    }
  }
}

// ---------------------------------------------------------------------------
// R10  Sizes are in rem, because rem is the only unit the player can reach.
//
// CAUGHT LATE, AND BY THE OWNER RATHER THAN BY THIS FILE: the DBNO placard's
// bleed bars shipped as `h-[3px]`. The root font size is
// `clamp(11px, calc(1.481vh * var(--ui-scale)), 28px)` and every size in the
// interface is in rem, so ONE number scales 720p to 4K and carries the
// player's interface-size slider with it. A px size opts out of both: it stays
// a 3px hairline at every setting, on every resolution, while the placard
// around it doubles. Nothing errors and nothing looks broken at the developer's
// own resolution, which is exactly the class of miss this file exists for.
//
// NARROW ON PURPOSE. Only properties that describe a SIZE, and only above one
// pixel -- a 1px border or a 1px gap is a hairline by intent and is supposed to
// stay one whatever the scale. Borders, gaps and 0 are never flagged.
// ---------------------------------------------------------------------------
{
  // Tailwind arbitrary values: h-[3px], text-[14px], min-w-[200px], bottom-[8px].
  const TW = /\b(?:min-|max-)?(?:w|h|text|top|bottom|left|right|inset|basis)-\[(\d+(?:\.\d+)?)px\]/g
  // Inline styles: fontSize: '14px', minWidth: "200px", height: '3px'.
  const INLINE = /\b(?:width|height|minWidth|maxWidth|minHeight|maxHeight|fontSize|top|bottom|left|right)\s*:\s*['"](\d+(?:\.\d+)?)px['"]/g

  for (const f of files.filter((x) => x.endsWith('.tsx'))) {
    const body = stripComments(read(f))
    for (const [i, line] of body.split('\n').entries()) {
      for (const re of [TW, INLINE]) {
        re.lastIndex = 0
        let m
        while ((m = re.exec(line)) !== null) {
          // Hairlines stay hairlines. 0 is not a size.
          if (parseFloat(m[1]) <= 1) continue
          fail('R10 rem', `${rel(f)}:${i + 1}`,
            `${m[0]} sizes in px -- the interface-size slider and every`
            + ` resolution above 1080p move rem and nothing else. Use rem`
            + ` (3px at the 16px default is 0.2rem).`)
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// R11  Escape leaves the player list from every state it has (#176).
//
// CAUGHT BY A HUMAN PLAYING, twice over. Owner, 2026-08-18: "Escape only closes
// the player list if they haven't clicked report." The panel holds the cursor,
// so an Escape that does not close it is a player who believes the interface
// has hung -- the worst failure this screen can produce short of leaking focus.
//
// WHAT THIS ACTUALLY CHECKS, and why it is not a restatement of the code. The
// bug was never a missing `close()`; it was `close()` sitting behind a LADDER of
// mode checks, each of which looked reasonable on its own and which together
// took three presses. So the rule is about the SHAPE: inside the Escape branch,
// the only thing allowed to stand between the key and `close()` is the search
// field having something in it -- the one rung the player can see. A branch on
// `reporting`, or on anything else, fails here.
//
// IT CAN FAIL. Re-add `if (reporting) leaveReport()` to that branch and this
// goes red; delete the `close()` call and it goes red. It cannot prove Escape
// reaches the handler at all -- there is no DOM in this process -- which is
// stated so nobody reads a pass as more than it is.
// ---------------------------------------------------------------------------
{
  const f = join(SRC, 'screens', 'PlayerList.tsx')
  if (!existsSync(f)) {
    fail('R11 escape', 'src/screens/PlayerList.tsx', 'file is missing.')
  } else {
    const body = stripComments(read(f))
    // The branch runs from the `e.key === 'Escape'` test to its `return`.
    const m = /if\s*\(\s*e\.key\s*===\s*'Escape'\s*\)\s*\{([\s\S]*?)\n\s*return\s*\n/.exec(body)
    if (!m) {
      fail('R11 escape', 'src/screens/PlayerList.tsx',
        "no `if (e.key === 'Escape') { ... return }` branch found -- either the"
        + ' handler moved or Escape stopped being answered here. #176 is about'
        + ' this branch; find it before deleting this rule.')
    } else {
      const branch = m[1]
      if (!/\bclose\s*\(\s*\)/.test(branch)) {
        fail('R11 escape', 'src/screens/PlayerList.tsx',
          'the Escape branch never calls close(). Escape must dismiss this'
          + ' panel -- it holds the cursor, and a panel that ignores Escape'
          + ' reads as a hung game (#176).')
      }
      // `query` is the visible rung and is allowed. Anything else gating the
      // close is the ladder growing back.
      for (const g of branch.matchAll(/\bif\s*\(([^)]*)\)/g)) {
        const cond = g[1]
        if (/\bquery\b/.test(cond)) continue
        fail('R11 escape', 'src/screens/PlayerList.tsx',
          `the Escape branch gates on \`${cond.trim()}\`. Only a non-empty`
          + ' search box may stand between Escape and close() -- it is the one'
          + ' step the player can see. Report mode was the other one, and three'
          + ' presses to leave a panel holding the cursor is what #176 is.')
      }
    }
  }
}

// ---------------------------------------------------------------------------
// R12  `.hud-safe` must not be transformed, or it eats the vitals strip.
//
// R9's twin, and the second one this project has shipped. `.hud-safe` carried
// `left: 50%; width: var(--usable-w); transform: translateX(-50%)` -- an
// ultrawide clamp -- and a transformed element becomes the CONTAINING BLOCK for
// every `position: fixed` descendant. The health/shield strip is `fixed`
// precisely BECAUSE the --map-* variables are viewport-true coordinates of the
// real minimap, and it sits inside this box, so it stopped resolving against
// the viewport: 305px away from the minimap at 32:9, while the notice stack --
// `fixed` too, but rendered at App level and OUTSIDE this box -- did not move
// at all. Two surfaces meant to share the minimap's left edge, pulled apart by
// a rule about neither (#231).
//
// R9 checks that a wrapper which MUST be transformed is sized to the viewport.
// This checks the other shape of the same trap: a wrapper that must not be
// transformed at all, because its fixed children are addressing the viewport on
// purpose. Neither rule generalises to the other.
//
// IT CAN FAIL. Put any `transform` back on `.hud-safe` and this goes red.
// ---------------------------------------------------------------------------
{
  const cssPath = join(SRC, 'index.css')
  const hudPath = join(SRC, 'hud', 'Hud.tsx')
  if (existsSync(cssPath) && existsSync(hudPath)) {
    const css = read(cssPath)
    // Same un-anchored match R9 uses, and for the same reason: the rule is
    // preceded by a comment block. `\s*\{` keeps `.hud-safe-x {` out.
    const rule = (css.match(/\.hud-safe\s*\{([^}]*)\}/) ?? [])[1] ?? null
    // Only worth checking while something inside it is actually `fixed`.
    const fixedInside = /className="fixed"|className={`fixed/.test(read(hudPath))

    if (rule == null) {
      fail('R12 fixed-trap', 'src/index.css',
        'there is no `.hud-safe` rule. The HUD lays out inside that box and'
        + ' this gate is what keeps a transform off it; if the box was renamed,'
        + ' rename it here too rather than deleting the rule.')
    } else if (fixedInside && /(^|[;\s])transform\s*:/.test(rule)) {
      fail('R12 fixed-trap', 'src/index.css',
        '.hud-safe carries a `transform`. It becomes the containing block for'
        + ' every `position: fixed` child, and the vitals strip inside it is'
        + ' fixed on purpose -- it addresses the viewport, because --map-* are'
        + ' viewport-true coordinates of the real minimap. This is #231.')
    }
  }
}

// ---------------------------------------------------------------------------
// R13  A HUD surface anchors to the MINIMAP's box, never to the panel's edges.
//
// #231, round two, and the reason there was a round two. The first fix read the
// safe zone from the engine instead of computing it -- correct, and not enough.
// It then said the minimap sits on the safe zone's bottom-left corner, which is
// true on a 16:9 monitor and false on every wider one: citizenfx/fivem#2719
// reports BOTH that the minimap stays "in the center(ish) of the screen as if
// it was following a 16:9 aspect ratio" AND that "the screen safe-zone has been
// verified to be setup correctly". Two rectangles. The gap between them is the
// bug, and at 16:9 the gap is zero -- which is why --safe-x and --safe-r looked
// right for a year and produced a screenshot of a 32:9 with the map near the
// middle, the health bars hard against the left edge and the inventory hard
// against the right.
//
// So: --hud-left and --hud-right, which are the edges of the box the MAP is in.
// --safe-x and --safe-r are the PANEL's edges. They are still published, still
// correct, and still what a full-screen menu should use -- the lobby is
// viewport-anchored on purpose and is confirmed good on the owner's ultrawide.
// This rule is about the HUD, which is the cluster around the map.
//
// --safe-y and --safe-b are NOT banned and must not be: a panel wider than 16:9
// has spare WIDTH, so the top and bottom edges of the engine's box are the safe
// zone's own and there is nothing there to correct.
//
// IT CAN FAIL. Put `var(--safe-x)` back on the squad panel and this goes red.
// ---------------------------------------------------------------------------
{
  const HUD_SURFACES = files.filter((f) => {
    const r = rel(f)
    return r.startsWith('src/hud/')
      || r.startsWith('src/chat/')
      || r === 'src/screens/PlayerList.tsx'
  })

  if (HUD_SURFACES.length === 0) {
    fail('R13 hud-frame', 'src/hud',
      'no HUD surfaces found to check. src/hud and src/chat are where the'
      + ' interface around the minimap lives; if they moved, point this rule at'
      + ' the new place rather than letting it pass over nothing.')
  }

  for (const f of HUD_SURFACES) {
    // `var(--safe-x)` only -- the prose in these files names the variable
    // while explaining why it is the wrong one, and setProperty('--safe-x')
    // in useScreenMetrics is the writer, not a consumer.
    const used = [...read(f).matchAll(/var\(\s*(--safe-[xr])\s*\)/g)]
      .map((m) => m[1])
    if (used.length === 0) continue
    fail('R13 hud-frame', rel(f),
      `anchors to ${[...new Set(used)].join(', ')}, which is the PANEL's edge.`
      + ' On an ultrawide the minimap is a quarter of a screen inboard of it'
      + ' (fivem#2719) and this surface would sit alone out at the edge. Use'
      + ' --hud-left / --hud-right, the edges of the box the map is in. Vertical'
      + ' is unaffected: --safe-y and --safe-b are still right.')
  }
}

// ---------------------------------------------------------------------------
// R14  Every inbound window message goes through the NUI guard.
//
// #281. An external audit found the bridge's `message` listener dispatching
// anything envelope-shaped from anywhere, and this interface embeds two
// script-capable iframes -- the player manual and the Ringmaster console, the
// second of which is deliberately unsandboxed. A page in either could raise a
// toast, rewrite match state, or send a sequence number so far ahead of Lua's
// counter that every genuine envelope afterwards was discarded as stale, which
// froze the whole interface for the session.
//
// The fix is bridge/envelope.ts. This rule is here because the fix is one line
// at a call site: `dispatch(ev.data)` is the shape of the bug and it is also
// the shape of the obvious thing to write. Deleting the guard would leave every
// test in scripts/test-envelope.mjs passing over code nothing calls -- which is
// the failure this project has a name for, and the reason a static gate sits
// beside a unit test rather than instead of one.
//
// THIS RULE AND THAT SUITE ARE A PAIR. The suite MODELS this listener, because
// there is no DOM to run it in; the model is only honest while the ordering
// below holds. Change one and change the other.
//
// IT CAN FAIL. Put `dispatch(ev.data as WireEnvelope)` back in the listener.
// ---------------------------------------------------------------------------
{
  const NUI = join(SRC, 'bridge', 'nui.ts')
  const GUARD = join(SRC, 'bridge', 'envelope.ts')

  if (!existsSync(NUI) || !existsSync(GUARD)) {
    fail('R14 nui-guard', 'src/bridge',
      'nui.ts or envelope.ts is missing. The window message listener and the'
      + ' guard in front of it are what this rule is about; if they moved,'
      + ' point it at the new place rather than letting it pass over nothing.')
  } else {
    const body = read(NUI)

    // The listener body, from the addEventListener to the end of the file. The
    // guard has to be INSIDE it -- importing admit and never calling it there
    // would satisfy a naive search of the whole file.
    const at = body.indexOf("addEventListener('message'")
    if (at === -1) {
      fail('R14 nui-guard', 'src/bridge/nui.ts',
        "no window 'message' listener found. This is the NUI receive path; if"
        + ' it moved, move this rule with it.')
    } else {
      const listener = body.slice(at)

      if (!/\badmit\s*\(\s*window\s*,\s*ev\.source\s*,\s*ev\.data\s*\)/.test(listener)) {
        fail('R14 nui-guard', 'src/bridge/nui.ts',
          'the message listener does not call admit(window, ev.source, ev.data).'
          + ' Every inbound message must be judged by bridge/envelope.ts before'
          + ' a field of it is read -- see #281, and Admin.tsx\'s own listener,'
          + ' which states the same rule about its origin check.')
      }

      if (/\bdispatch\s*\(\s*ev\.data\b/.test(listener)) {
        fail('R14 nui-guard', 'src/bridge/nui.ts',
          'the message listener dispatches ev.data directly. That is the #281'
          + ' bug exactly: an embedded page can post that. Dispatch the envelope'
          + ' admit() returned instead.')
      }
    }

    // The sequence gate is the other half, and the half that fixes the denial of
    // service. A `let lastSeq` back in nui.ts would compile, pass every other
    // check, and quietly restore the freeze.
    if (/\blet\s+lastSeq\b/.test(body)) {
      fail('R14 nui-guard', 'src/bridge/nui.ts',
        'lastSeq is a local again. It belongs to createSeqGate() in'
        + ' bridge/envelope.ts, which re-seeds itself after a run of stale'
        + ' envelopes -- a plain counter cannot, and a forged sequence number'
        + ' freezes the session permanently (#281).')
    }
    for (const call of ['reseed', 'fresh', 'commit']) {
      if (!body.includes(`seq.${call}(`)) {
        fail('R14 nui-guard', 'src/bridge/nui.ts',
          `the dispatcher never calls seq.${call}(). All three are load-bearing:`
          + ' reseed is the snapshot path, fresh is the stale test, commit is'
          + ' what keeps an unheard kind from eating a sequence number.')
      }
    }
  }
}

// ---------------------------------------------------------------------------
// R15  The gun shop menu flag reaches BOTH surfaces it was asked for.
//
// Owner, after the first in-match gun shop playtest, two sentences: "hide the
// squad panel when the menu is open" and "their volts balance is always shown
// in the bottom right while the menu is open". One fact, two surfaces, four
// files -- the envelope kind, the router, the Volts selector and the squad
// slot -- and THREE of the four are silent when they go missing. A kind nobody
// routes is discarded by the dispatcher with no error (that is exactly how the
// `squadcue` sounds were dropped for a fortnight); a selector that forgets the
// flag simply renders null.
//
// THE VOLTS HALF IS THE ONE THAT LOOKS ALREADY DONE. `shopPlate` has driven
// that readout since 2026-08-29, so the balance appears at the warmup shop and
// the code reads correct -- but the counter takes its own plate DOWN to raise
// the menu, so the one moment the owner asked about is the one moment
// `shopPlate` is false. The OR below is the whole fix, and it is one character
// away from looking untouched.
//
// WHAT THIS CANNOT PROVE, said plainly: that Lua ever sends the envelope. The
// sender is br_core/client/gunshop.lua, which is not this project. A pass here
// means the page would act on it if it arrived.
//
// IT CAN FAIL. Drop `!gunshopMenu` from the squad block, or `s.gunshopMenu`
// from the selector, or the handler, or the union member.
// ---------------------------------------------------------------------------
{
  const T = join(SRC, 'bridge', 'types.ts')
  const A = join(SRC, 'App.tsx')
  const H = join(SRC, 'hud', 'Hud.tsx')

  if (!existsSync(T) || !existsSync(A) || !existsSync(H)) {
    fail('R15 gunshopmenu', 'src',
      'types.ts, App.tsx or hud/Hud.tsx is missing. If they moved, move this'
      + ' rule with them rather than letting it pass over nothing.')
  } else {
    if (!/k:\s*'gunshopmenu'/.test(read(T))) {
      fail('R15 gunshopmenu', 'src/bridge/types.ts',
        "the Envelope union has no `gunshopmenu` member. Lua sends the kind as a"
        + ' raw string, so nothing here would fail to compile -- the envelope'
        + ' would simply arrive and be discarded.')
    }
    if (!/useNuiEvent\(\s*'gunshopmenu'/.test(read(A))) {
      fail('R15 gunshopmenu', 'src/App.tsx',
        "nothing subscribes to 'gunshopmenu'. An unrouted kind is dropped by the"
        + ' dispatcher in silence, which presents as "the squad panel does not'
        + ' hide" and is indistinguishable from Lua never sending it.')
    }

    const hud = stripComments(read(H))

    // The Volts readout: the flag must be one of the conditions that puts a
    // balance on screen.
    // BALANCED PARENS, NOT A LINE MATCH AND NOT A FIXED WINDOW. Both cheaper
    // spellings were tried and both were wrong: `\)\n` finds nothing in a CRLF
    // checkout, and a 300-character window from `useUi(` reaches PAST the end
    // of this selector into `const gunshopMenu = useUi((s) => s.gunshopMenu)`
    // on the next line -- so the rule passed over a shopVolts selector that had
    // been reverted, which is the one thing it exists to catch.
    const selAt = hud.search(/const\s+shopVolts\s*=\s*useUi\(/)
    let sel = null
    if (selAt !== -1) {
      const open = hud.indexOf('(', hud.indexOf('useUi', selAt))
      let depth = 0
      for (let i = open; i < hud.length; i++) {
        if (hud[i] === '(') depth++
        else if (hud[i] === ')' && --depth === 0) { sel = [null, hud.slice(open, i + 1)]; break }
      }
    }
    if (!sel) {
      fail('R15 gunshopmenu', 'src/hud/Hud.tsx',
        'no `const shopVolts = useUi(...)` selector found. That selector is'
        + ' where "is a balance relevant" is decided; if it was renamed, rename'
        + ' it here too.')
    } else if (!/\bs\.gunshopMenu\b/.test(sel[1])) {
      fail('R15 gunshopmenu', 'src/hud/Hud.tsx',
        'the shopVolts selector does not read s.gunshopMenu. `shopPlate` alone'
        + ' is false at a gun shop counter -- the counter lowers its plate to'
        + ' raise the menu -- so the balance vanishes at exactly the moment the'
        + ' owner asked for it.')
    }

    // The squad panel: the flag must gate the block that carries the slot id.
    const at = hud.indexOf('id={SQUAD_SLOT_ID}')
    if (at === -1) {
      fail('R15 gunshopmenu', 'src/hud/Hud.tsx',
        'the squad slot (id={SQUAD_SLOT_ID}) is gone. screens/PlayerList.tsx'
        + ' measures that id -- see the note above it -- so this is a bigger'
        + ' change than this rule; do not delete the rule to make it pass.')
    } else if (!/!gunshopMenu\s*&&/.test(hud.slice(Math.max(0, at - 300), at))) {
      fail('R15 gunshopmenu', 'src/hud/Hud.tsx',
        'the squad slot is not gated on !gunshopMenu. It must go away while the'
        + ' gun shop menu is up, the same way it already does during the'
        + ' descent -- one block, two reasons, one panel that comes back.')
    }
  }
}

// ---------------------------------------------------------------------------
// R16  The inventory names a weapon's ammunition, and ammunition can be put
//      down.
//
// Owner, same report: "for some reason there is no way to drop ammo from my
// inventory, only weapons?" and "please add an item in the inventory page that
// shows what type of ammo each weapon takes. like instead of where it says
// weapon say Medium shells etc".
//
// BOTH ARE ONE-EXPRESSION CHANGES THAT REVERT INVISIBLY. `{slot.kind}` renders
// a perfectly reasonable word, and a strip with no control on it looks
// finished -- neither reads as missing in a diff, which is how the first one
// survived to a playtest.
//
// THE DROP HALF IS HALF A FEATURE HERE AND THIS RULE SAYS SO. A pool has no
// slot index (br_core/server/inventory.lua: "Ammo never occupies a slot"), so
// the request below names a POOL, and the server handler that can act on one
// is not in this project. This gate proves the page asks. It cannot prove
// anybody answers.
//
// IT CAN FAIL. Put `{slot.kind}` back, or delete the pool drop.
// ---------------------------------------------------------------------------
{
  const f = join(SRC, 'screens', 'InventoryPanel.tsx')
  if (!existsSync(f)) {
    fail('R16 inventory', 'src/screens/InventoryPanel.tsx', 'file is missing.')
  } else {
    const body = stripComments(read(f))

    if (/\{\s*slot\.kind\s*\}/.test(body)) {
      fail('R16 inventory', 'src/screens/InventoryPanel.tsx',
        'a slot still prints `{slot.kind}` bare. A weapon should name the'
        + " ammunition it takes -- AMMO_LABEL[slot.pool], the same word the"
        + ' strip at the bottom uses -- and fall back to the kind only when'
        + ' there is no pool, which is what melee is.')
    }
    if (!/AMMO_LABEL\[\s*slot\.pool\s*\]/.test(body)) {
      fail('R16 inventory', 'src/screens/InventoryPanel.tsx',
        'no AMMO_LABEL[slot.pool] anywhere. The pool name must come from the'
        + ' map already in this file, never from a second list written beside'
        + ' it -- two spellings of "Shells" is the bug this avoids.')
    }
    if (!/fetchNui\(\s*CB\.INV_DROP\s*,\s*\{\s*pool\s*\}/.test(body)) {
      fail('R16 inventory', 'src/screens/InventoryPanel.tsx',
        'nothing sends CB.INV_DROP with a { pool }. Ammunition has no slot'
        + ' index, so a pool name is the only address a drop can carry; without'
        + ' this the strip is read-only and the owner\'s report stands.')
    }
  }
}

// ---------------------------------------------------------------------------
// R17  The storm card's closing ring is the tutorial's ring, on the card's beat.
//
// Owner, 2026-09-11: "can you also make an affect on the timer card when the
// 'storm moving now' timer starts? whatever affect the tutorial uses around the
// buttons -- that would be great but like 4x the radius."
//
// FOUR SEPARATE WAYS TO LOOK RIGHT AND BE WRONG, which is why this is a rule
// and not a screenshot:
//
//   * a second pulse. `.panel-hot` already breathes its border on a 1.6s beat,
//     so a ring mounted at the phase flip breathes at an offset nobody chose --
//     the card shimmers instead of breathing, and index.css's own words about
//     .tut-ring are "one pulse in the interface, not two". The lock is the
//     matching period AND delay, and it is two numbers that can drift apart in
//     a later edit without anything failing to compile.
//   * a second set of keyframes. Writing stormRingPulse with the same two
//     frames reverts nothing visibly and quietly doubles the vocabulary.
//   * the radius. 4x is the box-shadow SPREAD, measured against the ring it
//     copies. A literal 1.12rem with no relationship to .tut-ring's 0.28rem
//     stops being 4x the moment the tutorial's ring is retuned.
//   * the gate. The ring is mounted always and shown by a class, so the thing
//     that starts and stops it is one ternary on `shrinking` -- and a ring left
//     permanently up reads as a broken HUD rather than as a missing feature.
//
// IT CAN FAIL. Drop the `is-up` ternary, rename the keyframes, change either
// time, move the `key` back off the wrapper, or retune one spread on its own.
// ---------------------------------------------------------------------------
{
  const cssPath = join(SRC, 'index.css')
  const tsxPath = join(SRC, 'hud', 'StormBar.tsx')

  if (!existsSync(cssPath) || !existsSync(tsxPath)) {
    fail('R17 storm-ring', 'src/hud/StormBar.tsx',
      'index.css or hud/StormBar.tsx is missing. If they moved, move this rule'
      + ' with them rather than letting it pass over nothing.')
  } else {
    const css = stripComments(read(cssPath))
    const tsx = stripComments(read(tsxPath))
    const rule = (name) => (css.match(new RegExp(`\\.${name}\\s*\\{([^}]*)\\}`)) ?? [])[1] ?? null

    // Every time in an animation shorthand, in ms. `1.6s` and `1600ms` are the
    // same beat and this rule is about the beat, not about the spelling.
    const times = (decl) =>
      [...decl.matchAll(/(?<![\w.-])(\d+(?:\.\d+)?)(ms|s)(?![\w-])/g)]
        .map((m) => (m[2] === 's' ? parseFloat(m[1]) * 1000 : parseFloat(m[1])))
    const spread = (decl) => {
      const m = /box-shadow\s*:\s*0\s+0\s+0\s+(\d+(?:\.\d+)?)rem/.exec(decl)
      return m ? parseFloat(m[1]) : null
    }

    const ring = rule('storm-ring')
    const tut = rule('tut-ring')
    const hot = rule('panel-hot')

    if (ring == null || tut == null || hot == null) {
      fail('R17 storm-ring', 'src/index.css',
        'one of .storm-ring, .tut-ring or .panel-hot is gone. The first copies'
        + ' the second and shares the third\'s beat; renaming any of them means'
        + ' renaming it here, not deleting the rule.')
    } else {
      // ── the ring is the tutorial's, four times as wide ──
      const rs = spread(ring)
      const ts = spread(tut)
      if (rs == null || ts == null) {
        fail('R17 storm-ring', 'src/index.css',
          'no `box-shadow: 0 0 0 <n>rem` on .storm-ring or .tut-ring. The halo'
          + ' IS the request; a ring with only a border is a different effect.')
      } else if (Math.abs(rs - ts * 4) > 0.005) {
        fail('R17 storm-ring', 'src/index.css',
          `.storm-ring's halo spreads ${rs}rem against .tut-ring's ${ts}rem --`
          + ` 4x is ${(ts * 4).toFixed(2)}rem. The owner asked for the tutorial's`
          + ' ring at four times the radius, which is this spread and not the'
          + ' border, the standoff or the card.')
      }

      // ── one pulse, and it is matePulse ──
      const ringAnim = (/animation\s*:\s*([^;]+)/.exec(ring) ?? [])[1] ?? ''
      if (!/\bmatePulse\b/.test(ringAnim)) {
        fail('R17 storm-ring', 'src/index.css',
          '.storm-ring does not animate matePulse. The breath is shared with'
          + ' .tut-ring and the squad panel on purpose -- a second set of'
          + ' keyframes with the same two frames is a second vocabulary.')
      }

      // ── on the card's own beat: same period, same delay ──
      const hotEdge = (hot.match(/animation\s*:\s*([^;]+)/) ?? [])[1]
        ?.split(',').find((a) => /\bhotEdge\b/.test(a)) ?? null
      if (hotEdge == null) {
        fail('R17 storm-ring', 'src/index.css',
          '.panel-hot no longer runs hotEdge. The ring\'s delay exists only to'
          + ' fall in step with that pulse; if the card stopped pulsing, this'
          + ' ring should be rethought rather than left syncing to nothing.')
      } else {
        const [rp, rd] = times(ringAnim)
        const [hp, hd] = times(hotEdge)
        if (rp !== hp || rd !== hd) {
          fail('R17 storm-ring', 'src/index.css',
            `.storm-ring breathes ${rp}ms after ${rd}ms; .panel-hot's hotEdge`
            + ` breathes ${hp}ms after ${hd}ms. Two pulses on one card at`
            + ' different periods or out of step is the shimmer this was built'
            + ' to avoid -- match both numbers or take the card\'s pulse away.')
        }
      }

      // ── it starts at the flip and stops when the shrinking does ──
      const at = tsx.indexOf('storm-ring')
      if (at === -1) {
        fail('R17 storm-ring', 'src/hud/StormBar.tsx',
          'nothing renders the ring. The CSS on its own draws nothing, so this'
          + ' is the whole feature: a `storm-ring` element beside the card.')
      } else {
        const el = tsx.slice(Math.max(0, at - 160), at + 160)
        if (!/\bshrinking\b/.test(el) || !/is-up/.test(el)) {
          fail('R17 storm-ring', 'src/hud/StormBar.tsx',
            'the ring is not gated on `shrinking` via `is-up`. That flag is the'
            + ' moment the owner pointed at -- the same one that flips the label'
            + ' to "Storm closing now" -- and the ring has to go away again when'
            + ' the wall stops, not stay up for the rest of the match.')
        }
      }

      // ── the key is on the wrapper, so card and ring restart together ──
      if (!/key=\{[^}]*\}\s+className="relative"|className="relative"\s+key=\{[^}]*\}/.test(tsx)) {
        fail('R17 storm-ring', 'src/hud/StormBar.tsx',
          'the state `key` is not on the `relative` wrapper that holds the ring.'
          + ' On a swap the card remounts and its hotEdge restarts from zero; a'
          + ' ring outside that remount keeps its old phase and the two beats'
          + ' come apart, which is exactly what the matching delay is for.')
      }
    }
  }
}

// ---------------------------------------------------------------------------
// R18  `tscale` never sits beside a size the element declared itself (#159).
//
// index.css says it in full beside `.ts`, and five HUD files repeat the warning
// in their own words, and it was still live in two of them: `.tscale` is
// `calc(1em * var(--text-scale))`, and 1em is the PARENT's size -- so on an
// element that declares its own, the declared size is discarded without a
// warning and the element renders at whatever it happened to inherit.
//
// MEASURED, NOT REASONED: a kill feed row in `npm run dev` computed to 11px --
// the root size -- while its own class asked for 0.8125rem, which is 8.94px at
// that root. In game at 1080p that is a feed running at 16px against the 13px
// it declares. Chat's log line had the identical fault one file over.
//
// NOTHING ELSE CATCHES THIS. Both spellings are valid CSS, both classes are
// really applied, the screen looks plausible, and which one wins is decided by
// stylesheet ORDER -- so it cannot be seen in the markup at all. The fix is the
// one the stylesheet prescribes: `.ts` with the size handed in as `--fs`.
//
// `.micro-label` is the other half, and the other way this bit: it declares a
// font-size too, and `micro-label tscale` ignored the preference entirely.
//
// ═══ IT FAILS ON THE HUD AND WARNS ON THE SCREENS, AND THAT IS A DEBT ═══
//
// The same fault is live in twelve places across six lobby screens (Lobby,
// Settings, PlayerList, Keybinds, Market, Locker). Every one of them is a real
// text size being discarded, and every fix is a visible size change on a screen
// nobody reported -- which is a round of its own with the owner looking at it,
// not a quiet side effect of an audit of the kill feed. So they are counted and
// named on every build rather than hidden behind an allow-list, and the surfaces
// drawn over live gameplay, which is where this was measured, hold the line.
//
// IT CAN FAIL. Put `text-[0.8125rem]` back beside `tscale` on the kill feed row.
// ---------------------------------------------------------------------------
{
  // className="..." and className={`...`}. Both may span lines: the kill feed's
  // own class list does, which is why neither pattern excludes newlines.
  const CLASS_ATTR = [/className="([^"]*)"/g, /className=\{`([^`]*)`\}/g]
  const LIVE = (r) => r.startsWith('src/hud/') || r.startsWith('src/chat/')
  const owed = new Map()   // file -> count

  for (const f of files.filter((x) => x.endsWith('.tsx'))) {
    const body = stripComments(read(f))
    for (const re of CLASS_ATTR) {
      re.lastIndex = 0
      let m
      while ((m = re.exec(body)) !== null) {
        const cls = m[1]
        if (!/\btscale\b/.test(cls)) continue
        const declared = (cls.match(/\btext-\[[^\]]+\]/) ?? [])[0]
          ?? (/\bmicro-label\b/.test(cls) ? 'micro-label' : null)
        if (!declared) continue
        if (!LIVE(rel(f))) {
          owed.set(rel(f), (owed.get(rel(f)) ?? 0) + 1)
          continue
        }
        fail('R18 tscale', rel(f),
          `\`tscale\` sits beside \`${declared}\`, which declares a font size of`
          + ' its own. `.tscale` multiplies 1em -- the PARENT\'s size -- so that'
          + ' declaration is silently discarded and the element renders at'
          + ' whatever it inherits. Use `ts` and pass the size in as `--fs`'
          + ' (#159); index.css says so where `.ts` is declared.')
      }
    }
  }

  if (owed.size) {
    const total = [...owed.values()].reduce((a, b) => a + b, 0)
    warn('R18 tscale', 'src/screens',
      `${total} more in ${owed.size} screens, each throwing away a declared text`
      + ` size (#159): ${[...owed].map(([f, n]) => `${f} x${n}`).join(', ')}.`
      + ' Not failed here because every fix changes a size on screen and that is'
      + ' a round the owner should see, not a side effect of another one.')
  }
}

// ---------------------------------------------------------------------------
// R19  The kill feed is square, and its ink is the palette's.
//
// Owner, 2026-09-11: "can you check the kill feed to make sure it complies with
// our current UI colors, fonts, and outlines/corners? I don't think it does."
// It did not, and both faults were the same kind: a value that was right once,
// left behind by a change to the thing it was copied from.
//
//   * the rows rounded their right-hand corners to `var(--r-panel)`, which is
//     the radius `.panel` carried BEFORE the square restyle the owner kept
//     ("I like the style"). `.panel` is `border-radius: 0` now, so the override
//     was the only round corner left on the surface -- and it only applied to
//     rows that concern YOU, so your own eliminations were a different shape
//     from everyone else's. The HS chip did the same in miniature with
//     `rounded-sm`. Both are invisible in a diff of index.css, because neither
//     lives there.
//   * the chip's ink was `#0b0c12`, which is --color-royale-bg's value copied
//     by hand. It stops tracking the moment the token moves.
//
// NARROW TO ONE FILE ON PURPOSE. Rounded corners are correct elsewhere in the
// HUD -- every bar in the interface is `rounded-full` and is meant to be -- so
// a blanket ban would be wrong. This surface has no bars and no exceptions.
//
// IT CAN FAIL. Put back `rounded-sm`, the borderRadius line, or the literal.
// ---------------------------------------------------------------------------
{
  const f = join(SRC, 'hud', 'KillFeed.tsx')
  if (!existsSync(f)) {
    fail('R19 killfeed', 'src/hud/KillFeed.tsx', 'file is missing.')
  } else {
    const body = stripComments(read(f))

    for (const [needle, what] of [
      [/\brounded-[\w[\]./-]+/, 'a `rounded-` utility'],
      [/\bborderRadius\b/, 'an inline `borderRadius`'],
      [/--r-panel/, 'the --r-panel radius'],
    ]) {
      const hit = (body.match(needle) ?? [])[0]
      if (hit) {
        fail('R19 killfeed', 'src/hud/KillFeed.tsx',
          `${what} (\`${hit}\`). The feed is a \`.panel\`, and \`.panel\` has`
          + ' been `border-radius: 0` since the owner kept the square restyle.'
          + ' A row that concerns the player is marked with the blade on its'
          + ' leading edge, not with a second shape.')
      }
    }

    const hex = (body.match(/#[0-9a-fA-F]{6}\b/) ?? [])[0]
    if (hex) {
      fail('R19 killfeed', 'src/hud/KillFeed.tsx',
        `the literal ${hex}. Every color this surface draws is in the palette`
        + ' -- --color-royale-accent, --color-danger, --color-royale-bg -- and a'
        + ' hand-copied value stops following it, colorblind modes included.')
    }
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
