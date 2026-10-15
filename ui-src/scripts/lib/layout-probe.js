/**
 * THE LAYOUT PROBE: what check-layout.mjs asks of a page, run IN the page.
 * Evaluated as one expression; defines `window.__brProbe()`, which returns
 * every failure of the two rules on what is drawn right now.
 *
 *   EDGE   an element with a visible border, outline or ring (a box-shadow
 *          with a spread and no blur, which is how a ring or an inset border
 *          is drawn) whose drawn box is cut by an ancestor: by overflow other
 *          than visible, by paint containment, or by clip-path -- or by the
 *          screen. Even by one pixel.
 *
 *            A scroll container is measured as what it is. Along an axis it
 *            scrolls, the edge only has to be inside what scrolling can reach
 *            (its scroll height, padding included), so a card below the fold
 *            is not cut; along any other axis, and always across (nothing in
 *            this interface scrolls sideways), it has to be inside the padding
 *            box, scrollbar excluded. An outline or a ring is ink, which a
 *            scroll height never counts: one past the content is cut.
 *
 *            An element's OWN clip-path is not counted against it: that is the
 *            plate's chamfer, drawn on purpose and redrawn by its ::before and
 *            ::after. Its ancestors' are.
 *
 *   LINE   any text that is not marked as prose is a single-line label: it may
 *          not wrap to a second line, end in an ellipsis, be cut by any clip,
 *          or run out of its own box -- measured across, at its ends, since a
 *          text box is the font's whole height and not its ink. Prose is opted
 *          in, never guessed: `data-wrap` on the element or an ancestor, or
 *          `.body-text` (the prose class, index.css). A label hidden by `.fit`
 *          is listed, not failed.
 *
 * WHAT IS DRAWN. checkVisibility with opacity and visibility, a non-empty box,
 * no legacy `clip` (screen-reader-only text), and not wholly clipped away --
 * a box with nothing of it on screen is not drawn, so it cannot be cut.
 * Pseudo-elements have no box the DOM can see; the plate's chamfers are inside
 * its own box, so a cut plate is caught by its border.
 */
(() => {
  const TOL = 0.5
  const px = (v) => parseFloat(v) || 0

  // CSS ZOOM, AS CEF 103 MEASURES IT. scripts/lib/headless.mjs runs the
  // browser on the pre-128 rule (FiveM's), where a box inside `zoom: z` is
  // reported in that element's own px -- Locker v2's Cloudscape island is
  // zoomed. Every box read here is put back into screen px by the zoom it was
  // measured under; on the newer rule that factor is 1.
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
  let zooms = new Map()
  /** The zoom a box of `el` is reported under: every `zoom` from it to the root. */
  function zoomOf(el) {
    if (!LEGACY || !el) return 1
    if (zooms.has(el)) return zooms.get(el)
    const own = parseFloat(getComputedStyle(el).zoom) || 1
    const z = own * (el.parentElement ? zoomOf(el.parentElement) : 1)
    zooms.set(el, z)
    return z
  }
  /** A box in screen px. */
  function scaled(r, z) {
    return { left: r.left * z, top: r.top * z, right: r.right * z, bottom: r.bottom * z, width: r.width * z, height: r.height * z }
  }
  const rectOf = (el) => scaled(el.getBoundingClientRect(), zoomOf(el))

  function alpha(color) {
    if (!color || color === 'transparent') return 0
    const m = /rgba?\(([^)]*)\)/.exec(color)
    if (!m) return 1
    const parts = m[1].split(/[\s,/]+/).filter(Boolean)
    if (parts.length < 4) return 1
    const a = parts[3]
    return a.endsWith('%') ? parseFloat(a) / 100 : parseFloat(a)
  }

  /** Box-shadows as { x, y, blur, spread, inset, a }, from the computed list. */
  function shadows(value) {
    if (!value || value === 'none') return []
    const out = []
    // Split on commas outside parentheses.
    let depth = 0, cur = ''
    for (const ch of value) {
      if (ch === '(') depth++
      if (ch === ')') depth--
      if (ch === ',' && depth === 0) { out.push(cur); cur = '' } else cur += ch
    }
    if (cur.trim()) out.push(cur)
    return out.map((s) => {
      const color = (/rgba?\([^)]*\)|transparent/.exec(s) || ['rgb(0,0,0)'])[0]
      const rest = s.replace(color, ' ')
      const nums = rest.match(/-?[\d.]+px/g) || []
      return {
        x: px(nums[0]), y: px(nums[1]), blur: px(nums[2]), spread: px(nums[3]),
        inset: /\binset\b/.test(rest), a: alpha(color),
      }
    })
  }

  /** How far beyond the border box this element draws an edge, or null if none. */
  function edgeOf(cs) {
    let kinds = []
    let out = { t: 0, r: 0, b: 0, l: 0 }
    const grow = (t, r, b, l) => {
      out = { t: Math.max(out.t, t), r: Math.max(out.r, r), b: Math.max(out.b, b), l: Math.max(out.l, l) }
    }
    for (const s of ['Top', 'Right', 'Bottom', 'Left']) {
      const style = cs[`border${s}Style`]
      if (style !== 'none' && style !== 'hidden' && px(cs[`border${s}Width`]) > 0 && alpha(cs[`border${s}Color`]) > 0) {
        kinds.push('border')
        break
      }
    }
    if (cs.outlineStyle !== 'none' && px(cs.outlineWidth) > 0 && alpha(cs.outlineColor) > 0) {
      kinds.push('outline')
      const o = px(cs.outlineWidth) + px(cs.outlineOffset)
      grow(o, o, o, o)
    }
    for (const sh of shadows(cs.boxShadow)) {
      if (sh.a <= 0 || sh.blur > 0) continue
      if (sh.inset) {
        if (sh.spread > 0 || sh.x !== 0 || sh.y !== 0) kinds.push('inset ring')
      } else if (sh.spread > 0) {
        kinds.push('ring')
        grow(sh.spread - sh.y, sh.spread + sh.x, sh.spread + sh.y, sh.spread - sh.x)
      }
    }
    if (kinds.length === 0) return null
    return { kinds: [...new Set(kinds)], out }
  }

  function establishesFixedBlock(cs) {
    return cs.transform !== 'none' || cs.perspective !== 'none' || cs.filter !== 'none'
      || (cs.backdropFilter && cs.backdropFilter !== 'none')
      || /paint|layout|strict|content/.test(cs.contain)
      || /transform|perspective|filter/.test(cs.willChange)
  }

  const clips = (o) => o !== 'visible'

  /** Evaluate one clip-path coordinate (`10px`, `100%`, `calc(100% - 9.6px)`). */
  function coord(expr, size) {
    const e = expr.trim().replace(/^calc\((.*)\)$/, '$1')
    let total = 0
    let sign = 1
    for (const tok of e.split(/\s+/)) {
      if (tok === '+') { sign = 1; continue }
      if (tok === '-') { sign = -1; continue }
      const v = tok.endsWith('%') ? (parseFloat(tok) / 100) * size : parseFloat(tok)
      total += sign * (Number.isFinite(v) ? v : 0)
      sign = 1
    }
    return total
  }

  /** The clip-path of `el` as a convex polygon in viewport space, or null. */
  function clipPolygon(el, cs, rect) {
    const v = cs.clipPath
    if (!v || v === 'none') return null
    const w = el.offsetWidth || rect.width
    const h = el.offsetHeight || rect.height
    const sx = w ? rect.width / w : 1
    const sy = h ? rect.height / h : 1
    const at = (x, y) => [rect.left + x * sx, rect.top + y * sy]
    let m = /^polygon\((.*)\)/.exec(v)
    if (m) {
      // Points split on commas outside parentheses.
      let depth = 0, cur = ''
      const pts = []
      for (const ch of m[1].replace(/^\s*(nonzero|evenodd)\s*,/, '')) {
        if (ch === '(') depth++
        if (ch === ')') depth--
        if (ch === ',' && depth === 0) { pts.push(cur); cur = '' } else cur += ch
      }
      pts.push(cur)
      return pts.map((p) => {
        const parts = []
        let d = 0, c = ''
        for (const ch of p.trim()) {
          if (ch === '(') d++
          if (ch === ')') d--
          if (ch === ' ' && d === 0) { if (c) parts.push(c); c = '' } else c += ch
        }
        if (c) parts.push(c)
        return at(coord(parts[0], w), coord(parts[1], h))
      })
    }
    m = /^inset\((.*)\)/.exec(v)
    if (m) {
      const parts = m[1].split(/\s+round\s+/)[0].trim().split(/\s+(?![^(]*\))/)
      const [t, r = t, b = t, l = r] = parts.map((p, i) => coord(p, i % 2 ? w : h))
      return [at(l, t), at(w - r, t), at(w - r, h - b), at(l, h - b)]
    }
    return [at(0, 0), at(w, 0), at(w, h), at(0, h)]
  }

  /** How far the box sticks out of a convex polygon (0 when inside). */
  function outsidePolygon(box, poly) {
    // Orientation of the polygon, so "inside" is the same side of every edge.
    let area = 0
    for (let i = 0; i < poly.length; i++) {
      const [x1, y1] = poly[i], [x2, y2] = poly[(i + 1) % poly.length]
      area += x1 * y2 - x2 * y1
    }
    const dir = area >= 0 ? 1 : -1
    let worst = 0
    for (const [px_, py] of [[box.l, box.t], [box.r, box.t], [box.r, box.b], [box.l, box.b]]) {
      for (let i = 0; i < poly.length; i++) {
        const [x1, y1] = poly[i], [x2, y2] = poly[(i + 1) % poly.length]
        const len = Math.hypot(x2 - x1, y2 - y1)
        if (len < 1e-6) continue
        // Signed distance; negative is outside.
        const d = (dir * ((x2 - x1) * (py - y1) - (y2 - y1) * (px_ - x1))) / len
        if (-d > worst) worst = -d
      }
    }
    return worst
  }

  /** Every clip between `el` and the screen, nearest first. */
  function clipChain(el) {
    const chain = []
    let pos = getComputedStyle(el).position
    for (let a = el.parentElement; a; a = a.parentElement) {
      const cs = getComputedStyle(a)
      // clip-path cuts everything painted inside it, positioned or not.
      if (cs.clipPath && cs.clipPath !== 'none') chain.push({ el: a, cs, kind: 'clip-path' })
      const applies = pos === 'fixed' ? establishesFixedBlock(cs)
        : pos === 'absolute' ? (cs.position !== 'static' || establishesFixedBlock(cs))
          : true
      if (!applies) continue
      if (a !== document.documentElement && a !== document.body && (clips(cs.overflowX) || clips(cs.overflowY))) {
        chain.push({ el: a, cs, kind: 'overflow' })
      } else if (/paint|strict|content/.test(cs.contain)) {
        chain.push({ el: a, cs, kind: 'contain: paint' })
      }
      pos = cs.position === 'absolute' || cs.position === 'fixed' ? cs.position : 'static'
    }
    return chain
  }

  /** The padding box of a clipping ancestor, in viewport space. */
  function paddingBox(a) {
    const r = rectOf(a)
    const sx = a.offsetWidth ? r.width / a.offsetWidth : 1
    const sy = a.offsetHeight ? r.height / a.offsetHeight : 1
    const l = r.left + a.clientLeft * sx
    const t = r.top + a.clientTop * sy
    return { l, t, r: l + a.clientWidth * sx, b: t + a.clientHeight * sy, sx, sy }
  }

  /**
   * How far `box` is cut by each clip in `chain` and by the screen, as
   * [{ by, side, px }], plus whether the box is drawn at all.
   */
  function cuts(start, chain) {
    const found = []
    // `box` is what the next clip out sees: past a region that scrolls, only
    // the part of the box scrolled into its view, wherever the scroll is.
    // `visible` is what no scrolling can bring back -- if none of it is left,
    // the box is not drawn at any scroll, and nothing of it can be cut.
    let box = { ...start }
    let visible = { ...start }
    const keep = (l, t, r, b) => {
      visible = { l: Math.max(visible.l, l), t: Math.max(visible.t, t), r: Math.min(visible.r, r), b: Math.min(visible.b, b) }
    }
    const clamp = (v, lo, hi) => Math.min(Math.max(v, lo), hi)
    for (const c of chain) {
      if (c.kind === 'clip-path') {
        const poly = clipPolygon(c.el, c.cs, rectOf(c.el))
        const out = poly ? outsidePolygon(box, poly) : 0
        if (out > TOL) found.push({ by: c.el, kind: c.kind, side: 'clip-path', px: out })
        if (poly) {
          const xs = poly.map((p) => p[0]), ys = poly.map((p) => p[1])
          keep(Math.min(...xs), Math.min(...ys), Math.max(...xs), Math.max(...ys))
        }
        continue
      }
      const p = paddingBox(c.el)
      const a = c.el
      // Down the page: what scrolling reaches, if this box scrolls that way.
      const scrollsY = c.kind === 'overflow' && /auto|scroll/.test(c.cs.overflowY) && a.scrollHeight > a.clientHeight + 1
      let top = p.t, bottom = p.b
      if (scrollsY) {
        top = p.t - a.scrollTop * p.sy
        bottom = top + a.scrollHeight * p.sy
      }
      const sides = { left: p.l - box.l, right: box.r - p.r, top: top - box.t, bottom: box.b - bottom }
      for (const [side, d] of Object.entries(sides)) {
        if (d > TOL) found.push({ by: a, kind: c.kind, side, px: d })
      }
      if (scrollsY) {
        keep(p.l, -Infinity, p.r, Infinity)
        box = { l: box.l, r: box.r, t: clamp(box.t, p.t, p.b), b: clamp(box.b, p.t, p.b) }
      } else {
        keep(p.l, p.t, p.r, p.b)
      }
    }
    const vw = window.innerWidth, vh = window.innerHeight
    const screen = { left: -box.l, top: -box.t, right: box.r - vw, bottom: box.b - vh }
    for (const [side, d] of Object.entries(screen)) {
      if (d > TOL) found.push({ by: null, kind: 'screen', side, px: d })
    }
    keep(0, -Infinity, vw, Infinity)
    if (box.b <= 0 || box.t >= vh) visible = { l: 0, r: 0, t: 0, b: 0 }
    // A label's box is a line across its middle, with no height to lose.
    const drawn = visible.r - visible.l > TOL && visible.b - visible.t >= (start.b > start.t ? TOL : 0)
    return { found, drawn }
  }

  function drawn(el, cs) {
    if (el.checkVisibility && !el.checkVisibility({ opacityProperty: true, visibilityProperty: true })) return false
    if (cs.visibility !== 'visible' || cs.display === 'none') return false
    for (let a = el; a; a = a.parentElement) {
      const s = a === el ? cs : getComputedStyle(a)
      if (s.clip && s.clip !== 'auto') return false
      if (parseFloat(s.opacity) === 0) return false
    }
    return true
  }

  /** A short CSS-ish path: tag, the attributes this codebase names things by, a class or two. */
  function pathOf(el) {
    const parts = []
    for (let e = el; e && e !== document.body && parts.length < 7; e = e.parentElement) {
      let s = e.tagName.toLowerCase()
      if (e.id && !/^:/.test(e.id)) s += `#${e.id}`
      for (const at of ['data-page', 'data-tut', 'data-layer', 'data-screen', 'role']) {
        const v = e.getAttribute(at)
        if (v) { s += `[${at}=${v}]`; break }
      }
      const cls = [...e.classList].filter((c) => !/^(awsui_|_|\[|hover:|focus:)/.test(c) && !c.includes(':')).slice(0, 3)
      const aws = [...e.classList].find((c) => /^awsui_[a-z-]+_/.test(c))
      if (cls.length) s += `.${cls.join('.')}`
      else if (aws) s += `.${aws.replace(/_[a-z0-9]+_[0-9a-z]+$/, '')}`
      const sib = e.parentElement ? [...e.parentElement.children].filter((c) => c.tagName === e.tagName) : []
      if (sib.length > 1) s += `:nth-of-type(${sib.indexOf(e) + 1})`
      parts.unshift(s)
      if (e.hasAttribute('data-page')) break
    }
    return parts.join(' > ')
  }

  function nameOf(el) {
    return el ? pathOf(el).split(' > ').pop() : 'the screen'
  }

  const textOf = (el) => (el.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 48)

  function checkEdges(out) {
    for (const el of document.body.querySelectorAll('*')) {
      if (el.closest('svg') && el.tagName.toLowerCase() !== 'svg') continue
      const cs = getComputedStyle(el)
      const edge = edgeOf(cs)
      if (!edge) continue
      if (!drawn(el, cs)) continue
      const r = rectOf(el)
      if (r.width < 1 || r.height < 1) continue
      const z = zoomOf(el)
      const box = { l: r.left - edge.out.l * z, t: r.top - edge.out.t * z, r: r.right + edge.out.r * z, b: r.bottom + edge.out.b * z }
      const { found, drawn: shown } = cuts(box, clipChain(el))
      if (!shown || found.length === 0) continue
      const worst = found.reduce((a, b) => (b.px > a.px ? b : a))
      out.push({
        rule: 'edge',
        path: pathOf(el),
        text: textOf(el),
        what: edge.kinds.join('+'),
        detail: found.map((f) => `${f.side} ${f.px.toFixed(1)}px by ${f.kind === 'screen' ? 'the screen' : `${nameOf(f.by)} (${f.kind})`}`).join('; '),
        px: worst.px,
      })
    }
  }

  const PROSE = '[data-wrap], .body-text'

  /** The element whose line a text node is laid out in: its nearest non-inline ancestor. */
  function hostOf(node) {
    let h = node.parentElement
    while (h && h.parentElement) {
      const d = getComputedStyle(h).display
      if (d !== 'inline' && d !== 'contents') break
      h = h.parentElement
    }
    return h
  }

  function lines(rects) {
    const rows = []
    for (const r of [...rects].sort((a, b) => a.top - b.top)) {
      const row = rows.find((w) => Math.min(w.b, r.bottom) - Math.max(w.t, r.top) > 0.5 * Math.min(w.b - w.t, r.height))
      if (row) { row.t = Math.min(row.t, r.top); row.b = Math.max(row.b, r.bottom) } else rows.push({ t: r.top, b: r.bottom })
    }
    return rows.length
  }

  function checkLabels(out, hidden) {
    const hosts = new Map()
    const walk = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
    for (let n = walk.nextNode(); n; n = walk.nextNode()) {
      if (!/\S/.test(n.data)) continue
      const p = n.parentElement
      if (!p || p.closest('svg, script, style, textarea, noscript')) continue
      const h = hostOf(n)
      if (!h) continue
      if (!hosts.has(h)) hosts.set(h, [])
      hosts.get(h).push(n)
    }
    const range = document.createRange()
    for (const [h, nodes] of hosts) {
      const cs = getComputedStyle(h)
      if (!drawn(h, cs)) {
        // A label the fit rule hid is reported, never failed: that is the rule working.
        const fit = h.closest('.fit[data-unfit]')
        if (fit && fit.parentElement && drawn(fit.parentElement, getComputedStyle(fit.parentElement))) {
          hidden.push({ path: pathOf(fit), text: textOf(fit) })
        }
        continue
      }
      if (h.closest(PROSE)) continue
      const rects = []
      for (const n of nodes) {
        range.selectNodeContents(n)
        const z = zoomOf(n.parentElement)
        for (const r of range.getClientRects()) if (r.width > 0.5 && r.height > 0.5) rects.push(scaled(r, z))
      }
      if (rects.length === 0) continue
      // ACROSS ONLY. A text rect is the font's whole ascent and descent, not
      // its ink, so a tight line height reads as "cut" top and bottom on text
      // that draws whole; a label is cut, or not, at its ends.
      const mid = (Math.min(...rects.map((r) => r.top)) + Math.max(...rects.map((r) => r.bottom))) / 2
      const box = {
        l: Math.min(...rects.map((r) => r.left)), t: mid,
        r: Math.max(...rects.map((r) => r.right)), b: mid,
      }
      const problems = []
      // A <br> is a line its author wrote.
      const authored = 1 + h.querySelectorAll('br').length
      const n = lines(rects)
      if (n > authored) problems.push(`wraps to ${n} lines`)
      if (cs.textOverflow === 'ellipsis' && clips(cs.overflowX) && h.scrollWidth > h.clientWidth) {
        problems.push(`ends in an ellipsis (${h.scrollWidth - h.clientWidth}px short)`)
      }
      if (/^\d+$/.test(cs.webkitLineClamp) && h.scrollHeight > h.clientHeight) problems.push('is line-clamped')
      // Cut by its own box or any clip around it.
      const chain = clipChain(h)
      if (clips(cs.overflowX) || clips(cs.overflowY)) chain.unshift({ el: h, cs, kind: 'overflow' })
      const { found, drawn: shown } = cuts(box, chain)
      if (!shown) continue
      for (const f of found) {
        problems.push(`cut ${f.side} ${f.px.toFixed(1)}px by ${f.kind === 'screen' ? 'the screen' : `${f.by === h ? 'its own box' : nameOf(f.by)} (${f.kind})`}`)
      }
      // Run out of its own box, where nothing clips it.
      if (!clips(cs.overflowX)) {
        const hr = rectOf(h)
        const hz = zoomOf(h)
        const bl = hr.left + px(cs.borderLeftWidth) * hz, br = hr.right - px(cs.borderRightWidth) * hz
        if (box.r > br + TOL) problems.push(`runs ${(box.r - br).toFixed(1)}px out of its box (right)`)
        if (box.l < bl - TOL) problems.push(`runs ${(bl - box.l).toFixed(1)}px out of its box (left)`)
      }
      if (problems.length === 0) continue
      out.push({ rule: 'line', path: pathOf(h), text: textOf(h), detail: problems.join('; '), px: 0 })
    }
  }

  window.__brProbe = () => {
    zooms = new Map()
    const failures = []
    const hidden = []
    checkEdges(failures)
    checkLabels(failures, hidden)
    return { failures, hidden }
  }
})()
