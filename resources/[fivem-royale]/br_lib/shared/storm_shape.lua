-- The storm's boundary as a WALKABLE SHAPE rather than as a radius.
--
-- Nothing in the game asks this file for anything but a circle, and that is
-- deliberate: the storm draws exactly what it drew before this file existed.
-- What changes is that the renderer no longer KNOWS it is drawing a circle. It
-- asks for a perimeter, walks it in metres, and asks where the boundary is
-- nearest a point -- three questions a circle answers and so does everything
-- below.
--
-- ═══ WHY A LIST OF PIECES AND NOT A ROUNDED RECTANGLE ═══
--
-- The obvious shape language for "a wall of any size with rounded edges" is a
-- rectangle grown by a disc, and it is the wrong one. The proof the owner asked
-- for next is not a rectangle (2026-09-21):
--
--   "take for example 2 storm circles (current and next) which are barely
--    overlapping - like a venn diagram. We should extend the safezone to cover
--    both circles, so if a player gets to the new destination early they are
--    safe."
--
-- That is the UNION OF TWO DISCS, and a rounded rectangle cannot describe it.
-- The union of two overlapping discs is not convex: its outline has two REFLEX
-- corners where the circles cross, and every rounded-rectangle model is convex
-- by construction. Build the rectangle today and it is thrown away the week the
-- Venn zone arrives.
--
-- So a shape here is an ORDERED LIST OF BOUNDARY PIECES plus a containment test,
-- and there are two piece kinds and no more:
--
--   arc: a centre, a radius, a start angle and a SIGNED sweep
--   seg: two endpoints
--
-- which is enough for all of these, without a third spelling of any of them:
--
--   a circle            one arc of 2*pi
--   a union of 2 discs  two arcs (or one, or two whole circles -- see union2)
--   a rounded rect      four segments and four arcs
--   a capsule           two segments and two arcs
--
-- ═══ THE SWEEP IS SIGNED, WHICH IS WHAT MAKES A PIECE SELF-DESCRIBING ═══
--
-- Interior on the LEFT is the convention, as it is for the surveyed boundary in
-- polygon.lua. An arc swept counter-clockwise about its own centre therefore has
-- its interior toward that centre and its outward normal pointing radially OUT;
-- an arc swept clockwise bounds a hole, and its outward normal points radially
-- IN. One sign carries that, so pointAtArc can hand back a normal without being
-- told which kind of piece it is standing on.
--
-- A HOLE IS NOT A REFLEX CORNER, AND THIS FILE ONLY MEETS THE SECOND. A Venn
-- union's two reflex vertices are where two COUNTER-CLOCKWISE arcs meet, and
-- both normals there point outward -- which is why union2 builds both of its
-- arcs counter-clockwise and why the sign never goes negative in it. No
-- constructor here sweeps clockwise, so that half of the sign is carried
-- against the day something does and is not exercised today. Said plainly
-- because the first draft of this paragraph claimed the reflex corners were the
-- clockwise case, which would have sent the next reader looking for a bug in
-- union2 that is not there.
--
-- ═══ THE CUMULATIVE TABLE IS BUILT ONCE, AT CONSTRUCTION ═══
--
-- Every query below is answered off one number per piece -- the arc length at
-- that piece's start -- computed once when the shape is built. For a circle the
-- list is one piece long, so a per-frame query is one comparison and one sin/cos
-- pair: cheaper than the atan2 it replaces, and it stays cheap as pieces are
-- added because a storm boundary is single digits of them, never hundreds.
--
-- ═══ THE TRAP THIS FILE EXISTS TO CLOSE ═══
--
-- The column renderer used to index its slots as `first + i` and let that run
-- negative or past the slot count, because math.cos and math.sin accept any
-- angle and wrap for free. AN ARC WALK GETS NO SUCH GIFT, AND ITS FAILURE IS
-- SILENT RATHER THAN LOUD: with the wrap removed, an s past the end does not
-- error, it falls through the piece scan to the LAST piece's far end, so every
-- off-end slot stacks another marker on the same seam and the wall quietly
-- thins. A nil would at least have said something. So pointAtArc wraps s into
-- [0, P) ITSELF, for every caller, rather than trusting each one to do it.

BR = BR or {}
BR.StormShape = {}

local sin, cos, sqrt, atan, abs = math.sin, math.cos, math.sqrt, math.atan, math.abs
local max, huge, pi = math.max, math.huge, math.pi
local TAU = pi * 2.0

-- Metres of slack on the four-way case split in union2. A nanometre, for the
-- same reason polygon.lua picks one: exact equality is not reachable in doubles
-- at map coordinates, and a nanometre is nine orders of magnitude below anything
-- that could change which case a pair of circles is in.
local EPS = 1e-9

-- THE FLOOR ON ANY RADIUS THIS FILE BUILDS, AND IT IS THE SHIPPING ONE.
--
-- A zero-radius arc is a boundary with no length, and a shape with no length has
-- no point at s, no nearest point and no normal -- so every consumer would need
-- a special case for it, and the one that forgot would divide by zero in a
-- per-frame draw call. client/storm.lua's shipping 'solid' path already floors
-- its drawn radius at one metre for the same reason (`math.max(1.0, ...)`), so
-- flooring here keeps the two paths identical in the case rather than giving the
-- generalised one its own behaviour. Sub-metre is far below the storm's own
-- resolution: the wall is drawn in 30m slots.
local MIN_RADIUS = 1.0

--- Arc length remaining strictly positive, for a radius a caller may have
--- shrunk to nothing.
local function radius(r)
    return max(MIN_RADIUS, r or 0.0)
end

--- A counter-clockwise sweep from angle a to angle b, in (0, 2*pi].
---
--- A zero difference means "all the way round" rather than "no arc at all": the
--- only way to ask for a zero-length arc is to build one directly, which seal()
--- drops.
local function ccwSweep(a, b)
    local s = (b - a) % TAU
    if s <= 0.0 then s = TAU end
    return s
end

-- --------------------------------------------------------------- the pieces ---

--- One boundary arc. `sweep` is signed: positive is counter-clockwise.
local function arc(cx, cy, r, a0, sweep)
    r = radius(r)
    return {
        kind = 'arc',
        cx = cx + 0.0, cy = cy + 0.0, r = r,
        a0 = a0 + 0.0, sweep = sweep + 0.0,
        len = abs(sweep) * r,
        -- Which way "out" is, from this piece's own centre. See the header.
        out = (sweep >= 0.0) and 1.0 or -1.0,
    }
end

--- One straight boundary run, from (x0, y0) to (x1, y1).
local function seg(x0, y0, x1, y1)
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len <= 0.0 then return nil end     -- no direction, so no normal
    local ux, uy = dx / len, dy / len
    return {
        kind = 'seg',
        x0 = x0 + 0.0, y0 = y0 + 0.0, x1 = x1 + 0.0, y1 = y1 + 0.0,
        ux = ux, uy = uy,
        -- Interior on the left, so outward is the RIGHT of travel.
        nx = uy, ny = -ux,
        len = len,
    }
end

--- Where a single piece is at `t` metres along ITSELF, and the outward normal.
local function pieceAt(pc, t)
    if pc.kind == 'arc' then
        local th = pc.a0 + pc.sweep * (t / pc.len)
        local c, s = cos(th), sin(th)
        return pc.cx + c * pc.r, pc.cy + s * pc.r, c * pc.out, s * pc.out
    end
    return pc.x0 + pc.ux * t, pc.y0 + pc.uy * t, pc.nx, pc.ny
end

--- Seal a piece list into a shape: the cumulative-length table and the total.
---
--- `discs` is the shape's containment test when it has one -- the list of discs
--- it is the union of. A shape that is not a union of discs carries none, and
--- distance() and inset() say so rather than guessing (see their headers).
---
--- PRIVATE, AND THE PIECE BUILDERS ABOVE ARE TOO. Every shape that exists is
--- named by a constructor below, so there is no door anywhere -- in the game or
--- in a test -- through which a raw piece list can arrive unvalidated.
---
--- @param pieces table       array of arc/seg pieces, in boundary order
--- @param discs table|nil    { { x, y, r }, ... } this shape is the union of
--- @return table shape
local function seal(pieces, discs)
    local keep, P = {}, 0.0
    for _, pc in ipairs(pieces or {}) do
        -- A zero-length piece is not a boundary, and left in the list it would
        -- be selected by the scan below only for s exactly at its start -- the
        -- one index where its own length would then divide.
        if pc and pc.len > 0.0 then
            pc.s0 = P
            P = P + pc.len
            keep[#keep + 1] = pc
        end
    end
    return { pieces = keep, P = P, discs = discs }
end

--- Which piece holds arc length s, and how far along that piece it is.
---
--- `s` must already be wrapped into [0, P). One comparison for a circle.
local function pieceAtArc(shape, s)
    local pcs = shape.pieces
    local n = #pcs
    for i = 1, n do
        local pc = pcs[i]
        if s < pc.s0 + pc.len then return pc, s - pc.s0 end
    end
    -- Only reachable for s at or fractionally under P, where the floating-point
    -- sum of the piece lengths lands under the total. The last piece's end is
    -- the honest answer.
    local pc = pcs[n]
    return pc, pc and pc.len or 0.0
end

-- ------------------------------------------------------------ constructors ---

--- A circle. THE ONLY CONSTRUCTOR ANYTHING IN THE GAME CALLS.
--- @return table shape
function BR.StormShape.circle(cx, cy, r)
    r = radius(r)
    return seal(
        { arc(cx, cy, r, 0.0, TAU) },
        { { x = cx + 0.0, y = cy + 0.0, r = r } })
end

--- A capsule: a segment with a radius. Two straight runs and two end caps.
---
--- NOT CALLED BY ANYTHING, HERE OR IN THE GAME, and it is not the next shape
--- either -- the union of two discs is. It exists because the seg branch of the
--- walk above has to be driven by something real, and a capsule is the smallest
--- shape that has both piece kinds in it. The alternative was shipping that
--- branch untested behind a promise that the rounded rectangle will exercise it
--- one day. Delete this the day a shape with straight runs actually ships and can
--- carry those tests instead.
---
--- Walked counter-clockwise, so the interior stays on the left: out along the
--- RIGHT of the axis, a half turn about the far end, back along the other side,
--- a half turn about the near end.
--- @return table shape
function BR.StormShape.capsule(x0, y0, x1, y1, r)
    r = radius(r)
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len <= 0.0 then return BR.StormShape.circle(x0, y0, r) end
    local ux, uy = dx / len, dy / len
    -- Right of travel, which is where the first run sits and the angle both
    -- caps are measured from.
    local rx, ry = uy, -ux
    local a = atan(ry, rx)
    return seal({
        seg(x0 + rx * r, y0 + ry * r, x1 + rx * r, y1 + ry * r),
        arc(x1, y1, r, a, pi),
        seg(x1 - rx * r, y1 - ry * r, x0 - rx * r, y0 - ry * r),
        arc(x0, y0, r, a + pi, pi),
    })
end

--- The UNION OF TWO DISCS, which is the whole point of this file.
---
--- ═══ NOTHING CALLS THIS YET, ON PURPOSE ═══
---
--- The commit that introduced it changes nothing a player can see. There is no
--- way in the game to ask the storm for this shape, and the renderer builds a
--- circle from the live record every frame exactly as it always did. What this
--- function is for is the next commit -- the safe zone extended to cover the
--- current circle AND the one it is closing toward, so that a player who gets to
--- the new destination early is safe there.
---
--- ═══ FOUR CASES, AND THE THIRD ONE IS NOT A BUG ═══
---
---   ONE CONTAINS THE OTHER  the shape is the containing disc, one arc. Includes
---                           two identical circles and internal tangency.
---   THEY OVERLAP            two arcs, meeting at the two crossings. The
---                           boundary has two reflex corners, which is exactly
---                           what rules out a convex shape language.
---   THEY ARE DISJOINT       two WHOLE circles: a boundary with TWO COMPONENTS.
---                           Legal and correct -- the safe zone is two islands
---                           and the gap between them is not safe. The solver
---                           already produces this pair: a breakout separates
---                           the circles entirely and caps the gap between their
---                           edges at gapMax times the predecessor's radius
---                           (shared/storm_solve.lua). External tangency lands
---                           here too, which is why nothing divides by the
---                           half-chord.
---   TANGENT OR IDENTICAL    whichever of the above it degenerates to, decided
---                           by the same three comparisons with a nanometre of
---                           slack, so no case has to divide by zero to find out
---                           it was degenerate.
---
--- WHICH ARC OF EACH CIRCLE SURVIVES is decided by geometry rather than by
--- sampling. The outer part of circle 1 is the part facing away from circle 2,
--- so walking counter-clockwise it BEGINS at the crossing on the left of the
--- centre line and ENDS at the one on the right. Circle 2's outer arc is the
--- mirror of that, which is what makes the two chain end-to-start into one
--- closed loop: arc 1 finishes at the right-hand crossing and arc 2 starts
--- there. tools/test_shared.lua checks that claim the other way round, by
--- proving the interior arcs are NOT on the boundary.
---
--- @return table shape
function BR.StormShape.union2(x1, y1, r1, x2, y2, r2)
    r1, r2 = radius(r1), radius(r2)
    local discs = {
        { x = x1 + 0.0, y = y1 + 0.0, r = r1 },
        { x = x2 + 0.0, y = y2 + 0.0, r = r2 },
    }

    local dx, dy = x2 - x1, y2 - y1
    local d = sqrt(dx * dx + dy * dy)

    -- Contained, either way round. Tested first so that d == 0 never reaches
    -- the division below.
    if d + r2 <= r1 + EPS then return BR.StormShape.circle(x1, y1, r1) end
    if d + r1 <= r2 + EPS then return BR.StormShape.circle(x2, y2, r2) end

    -- Disjoint, or touching at exactly one point. Two components.
    if d >= r1 + r2 - EPS then
        return seal({
            arc(x1, y1, r1, 0.0, TAU),
            arc(x2, y2, r2, 0.0, TAU),
        }, discs)
    end

    -- A proper overlap. `a` is how far along the centre line from circle 1 the
    -- two crossings sit, and `h` is how far off it -- so the crossings are the
    -- centre-line point plus and minus h along the perpendicular.
    local ux, uy = dx / d, dy / d
    local a = (d * d + r1 * r1 - r2 * r2) / (2.0 * d)
    local h2 = r1 * r1 - a * a
    local h = (h2 > 0.0) and sqrt(h2) or 0.0
    local mx, my = x1 + a * ux, y1 + a * uy

    -- Left of the centre line, then right of it.
    local lx, ly = mx - h * uy, my + h * ux
    local rx, ry = mx + h * uy, my - h * ux

    local l1 = atan(ly - y1, lx - x1)
    local r1a = atan(ry - y1, rx - x1)
    local l2 = atan(ly - y2, lx - x2)
    local r2a = atan(ry - y2, rx - x2)

    return seal({
        arc(x1, y1, r1, l1, ccwSweep(l1, r1a)),
        arc(x2, y2, r2, r2a, ccwSweep(r2a, l2)),
    }, discs)
end

-- ----------------------------------------------------------------- queries ---

--- Total length of the boundary, in metres. Sums every component.
--- @return number
function BR.StormShape.perimeter(shape)
    return shape and shape.P or 0.0
end

--- The boundary point at arc length `s`, and the OUTWARD unit normal there.
---
--- `s` IS WRAPPED HERE, and that is the whole reason this is a function rather
--- than four lines at the call site. The column walk indexes slots either side
--- of the viewer's own and lets the index run negative or past the count,
--- because the angular walk it grew up on wrapped for free in cos/sin. An arc
--- walk indexed off the end of its piece table does not fail, it silently
--- returns the last piece's far end, so the wrap lives here, once, where no
--- caller can forget it.
---
--- @param shape table
--- @param s number    metres along the boundary; any real number
--- @return number x, number y, number nx, number ny
function BR.StormShape.pointAtArc(shape, s)
    local P = shape and shape.P or 0.0
    if P <= 0.0 then return 0.0, 0.0, 1.0, 0.0 end
    local pc, t = pieceAtArc(shape, s % P)
    if not pc then return 0.0, 0.0, 1.0, 0.0 end
    return pieceAt(pc, t)
end

--- The arc length of the boundary point NEAREST (px, py).
---
--- This is what replaces `base = math.atan(p.y - cy, p.x - cx)` in the column
--- renderer, and it answers the same question for a boundary of any shape: where
--- along it is the part the viewer is looking at.
---
--- Exact, from the piece list: for each piece, the radial or perpendicular foot
--- when it lands on that piece, and the nearer endpoint when it does not. A
--- point at the exact centre of a circle has no nearest point -- every boundary
--- point ties -- and gets the start of the arc it is the centre of, which is one
--- of the tied winners rather than an error.
---
--- @return number s
function BR.StormShape.nearestArc(shape, px, py)
    local pcs = shape and shape.pieces
    if not pcs or #pcs == 0 then return 0.0 end

    local bestS, bestD = 0.0, huge

    local function consider(s, x, y)
        local ddx, ddy = px - x, py - y
        local d = ddx * ddx + ddy * ddy
        if d < bestD then bestD, bestS = d, s end
    end

    for i = 1, #pcs do
        local pc = pcs[i]
        if pc.kind == 'arc' then
            -- How far along this arc the radial foot lies, measured in the
            -- sweep's own direction and wrapped into [0, 2*pi). For a whole
            -- circle the span is 2*pi, so this always lands on the piece and
            -- the endpoint branch is never taken.
            local off = ((atan(py - pc.cy, px - pc.cx) - pc.a0) * pc.out) % TAU
            local span = abs(pc.sweep)
            if off <= span then
                local t = off * pc.r
                local x, y = pieceAt(pc, t)
                consider(pc.s0 + t, x, y)
            else
                local x, y = pieceAt(pc, 0.0)
                consider(pc.s0, x, y)
                x, y = pieceAt(pc, pc.len)
                consider(pc.s0 + pc.len, x, y)
            end
        else
            -- The perpendicular foot, clamped to the run's own ends.
            local t = (px - pc.x0) * pc.ux + (py - pc.y0) * pc.uy
            if t < 0.0 then t = 0.0 elseif t > pc.len then t = pc.len end
            local x, y = pieceAt(pc, t)
            consider(pc.s0 + t, x, y)
        end
    end

    -- WRAPPED, BECAUSE THE LAST PIECE'S FAR END IS SPELLED `P` AND `P` IS NOT
    -- IN THE DOMAIN. The endpoint branch above considers `pc.s0 + pc.len`, and
    -- on the final piece that sum IS the perimeter: the same vertex the walk
    -- calls 0. Which spelling wins is decided by the last bits of two different
    -- floating-point reconstructions of one point, so it is not a case anybody
    -- would think to test for. Found in review on a real union --
    -- union2(0, 0, 900, 1300, 0, 700) at (291.9, 97.3) returned exactly its own
    -- perimeter, on 15 of 3721 grid points.
    --
    -- NOT LIVE TODAY AND FIXED ANYWAY. The one caller in client/storm.lua turns
    -- this into an index and hands it back to pointAtArc, which wraps, so the
    -- wall draws the identical markers either way. It is fixed here because
    -- this file's header promises every caller a value in [0, P) and pieceAtArc
    -- documents that its argument must already be wrapped; the next consumer to
    -- use the answer for a piece lookup rather than a point is the one that
    -- pays for the promise being untrue.
    local P = shape.P
    return (P and P > 0.0) and (bestS % P) or bestS
end

--- Signed distance to the boundary. Negative inside, positive outside.
---
--- ═══ THE MINIMUM OF THE DISC DISTANCES, NOT A WALK OF THE PIECES ═══
---
--- A point is inside a union exactly when it is inside one of the discs, so the
--- minimum of the per-disc signed distances gets the SIGN right everywhere and
--- the MAGNITUDE right everywhere outside and on the boundary -- which is every
--- place any consumer reads the magnitude. The damage test wants the sign. The
--- HUD's "how far to safety" and the wall's window width are read from outside.
---
--- WHERE IT IS NOT THE TRUE DISTANCE, said plainly so nobody has to rediscover
--- it: strictly inside the LENS where two discs overlap, the nearest point of a
--- disc's own circle can be a point the other disc has swallowed, so it is not
--- on the union's boundary at all. Two unit discs 1.0 apart read -0.5 at the
--- midpoint where the true distance to the outline is -0.866. The error is
--- always in the direction of reading SHALLOWER than the truth, never deeper, so
--- nothing can be told it is safely inside when it is not. For an exact answer
--- at a point inside a union, walk to nearestArc and measure -- that is what
--- makes these two functions different rather than redundant.
---
--- A shape with no disc list -- one built piece by piece -- has no answer here.
--- Returning a guess would be worse than the error: the first non-disc shape is
--- the rounded rectangle, whose signed distance is a real function somebody has
--- to write, and a silent approximation is how it would never get written.
---
--- @return number  metres, negative inside
function BR.StormShape.distance(shape, px, py)
    local discs = shape and shape.discs
    if not discs then
        error('StormShape.distance: this shape is not a union of discs, and '
            .. 'a boundary made of straight runs needs its own signed distance')
    end
    local best = huge
    for i = 1, #discs do
        local c = discs[i]
        local ddx, ddy = px - c.x, py - c.y
        local d = sqrt(ddx * ddx + ddy * ddy) - c.r
        if d < best then best = d end
    end
    return best
end

--- The same shape, shrunk by `metres`.
---
--- This is what pays the edgeInset debt in the column renderer: a marker's
--- translucent surface reads fatter than its scale, so the visible curtain is
--- drawn slightly INSIDE the logical edge and standing at the wall is always
--- genuinely safe.
---
--- Rebuilt from the disc list rather than by offsetting pieces, which is exact
--- for a single disc and is the same construction the shape came from.
---
--- FOR A UNION IT SHRINKS EACH DISC, which is not quite the true erosion: near
--- the join the eroded union is a little wider than the union of the eroded
--- discs. It errs the same way distance() does, INWARD, which is the safe
--- direction for the only thing this is used for -- the drawn boundary may pull
--- a little further inside the logical edge near a reflex corner, and can never
--- sit outside it.
---
--- Radii floor at one metre, as everything here does, so an inset larger than
--- the shape leaves a boundary that can still be walked instead of a shape with
--- no length. See MIN_RADIUS.
---
--- @return table shape
function BR.StormShape.inset(shape, metres)
    local discs = shape and shape.discs
    if not discs then
        error('StormShape.inset: this shape is not a union of discs, and '
            .. 'offsetting a straight run is a different algorithm')
    end
    metres = metres or 0.0
    if #discs == 1 then
        local c = discs[1]
        return BR.StormShape.circle(c.x, c.y, c.r - metres)
    end
    local a, b = discs[1], discs[2]
    return BR.StormShape.union2(a.x, a.y, a.r - metres, b.x, b.y, b.r - metres)
end
