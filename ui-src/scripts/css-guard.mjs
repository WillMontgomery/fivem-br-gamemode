// @SUPPORTS BLOCKS THAT TEST FOR A FEATURE, BLANKED BEFORE check-css COUNTS IT (#413).
//
// `@supports (color: oklch(0 0 0)) { ... }` is the one way to use a CEF 144
// feature while CEF 103 clients remain: 103 evaluates the condition false and
// skips the whole block. So a banned function inside such a block is not a
// bug, and check-css must not count it.
//
// The old exemption was a regex, `@supports\s*\([^)]*\)\s*\{`, which stops at
// the first `)` -- inside `oklch(0 0 0)` -- and blanked only the header
// anyway, so a guarded use was always counted (the #413 audit tried one).
// This walks parentheses and braces instead:
//
//   - the condition runs to the `{` at parenthesis depth 0;
//   - the block is blanked only if the condition itself names the feature
//     (`feature` is tested against it) -- a block guarded by something else
//     is no guard for this feature;
//   - never under `not` or `or`: `@supports not (...)` applies on exactly the
//     engines that lack the feature, and `(a) or (b)` may apply through `b`.
//
// Offsets are kept (blanked to spaces, newlines kept) so a later count or
// position is unchanged.

export function blankGuarded(css, feature) {
  let out = css
  const re = /@supports\b/g
  let m
  while ((m = re.exec(out)) !== null) {
    let i = m.index + m[0].length
    let depth = 0
    for (; i < out.length; i++) {
      const c = out[i]
      if (c === '(') depth++
      else if (c === ')') depth--
      else if ((c === '{' || c === ';') && depth === 0) break
    }
    if (out[i] !== '{') continue
    const cond = out.slice(m.index + m[0].length, i)
    const flags = feature.flags.replace('g', '')
    const named = new RegExp(feature.source, flags).test(cond)
    if (!named || /\b(?:not|or)\b/i.test(cond)) continue
    let braces = 0
    let end = i
    for (; end < out.length; end++) {
      if (out[end] === '{') braces++
      else if (out[end] === '}' && --braces === 0) break
    }
    const blank = out.slice(m.index, end + 1).replace(/[^\n]/g, ' ')
    out = out.slice(0, m.index) + blank + out.slice(end + 1)
    re.lastIndex = end + 1
  }
  return out
}
