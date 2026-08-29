-- Point-in-polygon, for the surveyed playable boundary.
--
-- ═══ WHY THIS IS NOT IN geo.lua ═══
--
-- geo.lua is the per-frame math: allocation-free, called by the storm renderer
-- sixty times a second. Nothing here runs per frame. It runs eight times per
-- match (once per storm phase) and once per config row at build time, and it is
-- allowed to be a plain readable loop.
--
-- It is a SEPARATE FILE so it can be unit-tested against hand-checked answers
-- with no FiveM in the room, which is the whole reason br_lib/shared exists.
--
-- ═══ RAY CASTING, NOT WINDING ═══
--
-- Both answer the same question for a SIMPLE ring -- one that does not cross
-- itself -- and the surveyed boundary is simple (tools/check_boundary.lua
-- proves it edge-pair by edge-pair, so this file may assume it). The winding
-- number is the better answer for self-intersecting shapes, where it can tell
-- "wrapped twice" from "wrapped once"; ray casting would call the doubly-wrapped
-- interior outside. We have no such shape and want none, so the tie-break is
-- readability: the crossing count is four lines a reviewer can check by eye
-- against a drawing, and the winding number is an accumulation of signed angles
-- that is not.
--
-- The rule below is the HALF-OPEN one, `(a.y > y) ~= (b.y > y)`. It exists to
-- stop a vertex being counted twice: a horizontal ray through a vertex meets
-- both edges that share it, and the naive `>=` test counts both, which flips the
-- answer back to "outside" for a point that is genuinely inside. Half-open
-- assigns each edge the vertex at one end only, so exactly one of the pair
-- counts. It also makes horizontal edges (a.y == b.y) contribute nothing, which
-- is correct: a ray at that y is running along the edge, not across it.
--
-- ═══ AND WHY THE BOUNDARY IS TESTED SEPARATELY, FIRST ═══
--
-- Ray casting has NO defined answer for a point exactly ON the outline. The ray
-- starts on the line it is counting crossings of, and whether it reports inside
-- or outside falls out of floating-point rounding in the interpolation --
-- meaning the answer for a vertex can differ from the answer for the same vertex
-- with 0.0 added to it.
--
-- That is normally a curiosity. Here it is not: POIs are DELETED on this
-- function's answer (owner, 2026-08-28: "everything OUTSIDE this area should be
-- immediately removed from gameplay"), so a coin flip on the line is a coin flip
-- on whether a location he clicked survives. So the outline is tested exactly,
-- before the ray is cast, and a point on it is INSIDE. Deleting a place for
-- sitting on the line the owner drew through it is the wrong default in a way
-- that keeping it is not.
--
-- `eps` is a tolerance in METRES on the perpendicular distance to the edge, and
-- it defaults to a nanometre. Exact zero would be the honest number in exact
-- arithmetic and is not reachable in doubles -- (x - ax) * (by - ay) and
-- (y - ay) * (bx - ax) are each ~1e7 for coordinates this size, so their
-- difference lands near 1e-9 rather than on it even for a point constructed to
-- be on the line. A nanometre is nine orders of magnitude below anything on this
-- map and is not "near enough" in any sense that could move a POI's verdict.

BR = BR or {}

local sqrt, abs, huge = math.sqrt, math.abs, math.huge

--- Is (x, y) exactly on the polygon's outline -- an edge or a vertex?
---
--- @param x number
--- @param y number
--- @param poly table       array of { x, y }; the ring closes implicitly
--- @param eps number|nil   metres of perpendicular slack (default 1e-9)
--- @return boolean
function BR.PointOnPolygonEdge(x, y, poly, eps)
    local n = poly and #poly or 0
    if n < 2 then return false end
    eps = eps or 1e-9

    for i = 1, n do
        local a = poly[i]
        local b = poly[(i % n) + 1]
        local dx, dy = b.x - a.x, b.y - a.y
        local px, py = x - a.x, y - a.y
        local len2 = dx * dx + dy * dy

        if len2 <= 0.0 then
            -- A degenerate edge is a repeated vertex. check_boundary.lua
            -- refuses one, but a hand-edited table can still arrive here and
            -- the point may legitimately BE that vertex.
            if sqrt(px * px + py * py) <= eps then return true end
        else
            -- |cross| / len is the perpendicular distance to the infinite
            -- line, so comparing |cross| against eps * len tests METRES
            -- without taking the square root.
            local cross = px * dy - py * dx
            if abs(cross) <= eps * sqrt(len2) then
                -- On the line. Now: on the SEGMENT? The projection parameter
                -- t = dot / len2 must land in [0, 1], with the same eps
                -- widened to the parameter's units at either end.
                local dot = px * dx + py * dy
                local slack = eps * sqrt(len2)
                if dot >= -slack and dot <= len2 + slack then
                    return true
                end
            end
        end
    end

    return false
end

--- Is (x, y) inside the polygon? Points ON the outline count as inside.
---
--- @param x number
--- @param y number
--- @param poly table       array of { x, y }; the ring closes implicitly
--- @param eps number|nil   outline tolerance in metres (default 1e-9)
--- @return boolean
function BR.PointInPolygon(x, y, poly, eps)
    local n = poly and #poly or 0
    if n < 3 then return false end

    -- The outline first, and unconditionally: it is the case the crossing
    -- count cannot answer. See the header.
    if BR.PointOnPolygonEdge(x, y, poly, eps) then return true end

    local inside = false
    local j = n
    for i = 1, n do
        local a, b = poly[i], poly[j]
        if (a.y > y) ~= (b.y > y) then
            -- Where the edge crosses the horizontal line through y. The
            -- denominator cannot be zero: the half-open test above is false
            -- for a horizontal edge.
            local xint = (b.x - a.x) * (y - a.y) / (b.y - a.y) + a.x
            if x < xint then inside = not inside end
        end
        j = i
    end

    return inside
end

--- Distance from a point to the nearest point on a line SEGMENT.
---
--- Not the infinite line: an outline is made of segments, and the nearest point
--- on a boundary near a corner is the corner itself.
---
--- @return number
function BR.DistanceToSegment(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    if len2 <= 0.0 then
        return sqrt((px - ax) * (px - ax) + (py - ay) * (py - ay))
    end
    local t = ((px - ax) * dx + (py - ay) * dy) / len2
    if t < 0.0 then t = 0.0 elseif t > 1.0 then t = 1.0 end
    local qx, qy = ax + t * dx, ay + t * dy
    return sqrt((px - qx) * (px - qx) + (py - qy) * (py - qy))
end

--- How far is (x, y) from the outline? Unsigned -- always positive, whichever
--- side the point is on.
---
--- This is the number the POI audit reports as "metres outside": pair it with
--- BR.PointInPolygon for the sign. Kept unsigned because the two questions have
--- different costs -- "is it in?" is answered by a crossing count, "how far?"
--- needs every edge measured -- and a caller that only wants the verdict should
--- not pay for the distance.
---
--- @param x number
--- @param y number
--- @param poly table
--- @return number  metres to the nearest edge (math.huge for a degenerate poly)
function BR.DistanceToPolygonEdge(x, y, poly)
    local n = poly and #poly or 0
    if n < 2 then return huge end

    local best = huge
    for i = 1, n do
        local a = poly[i]
        local b = poly[(i % n) + 1]
        local d = BR.DistanceToSegment(x, y, a.x, a.y, b.x, b.y)
        if d < best then best = d end
    end
    return best
end

--- Axis-aligned bounding box of the polygon.
--- @return number minX, number minY, number maxX, number maxY
function BR.PolygonBounds(poly)
    local minX, minY, maxX, maxY = huge, huge, -huge, -huge
    for _, p in ipairs(poly or {}) do
        if p.x < minX then minX = p.x end
        if p.x > maxX then maxX = p.x end
        if p.y < minY then minY = p.y end
        if p.y > maxY then maxY = p.y end
    end
    return minX, minY, maxX, maxY
end

--- SIGNED area by the shoelace formula. Positive = counter-clockwise winding,
--- negative = clockwise. The sign is not used by the containment test -- ray
--- casting does not care which way the ring was walked -- but it is worth
--- reporting, because a sign flip between two edits of the same table means
--- somebody reversed the point order.
--- @param poly table
--- @return number  square metres, signed
function BR.PolygonArea(poly)
    local n = poly and #poly or 0
    if n < 3 then return 0.0 end
    local sum = 0.0
    for i = 1, n do
        local a = poly[i]
        local b = poly[(i % n) + 1]
        sum = sum + (a.x * b.y - b.x * a.y)
    end
    return sum * 0.5
end

--- Perimeter of the closed ring, including the closing edge.
--- @param poly table
--- @return number  metres
function BR.PolygonPerimeter(poly)
    local n = poly and #poly or 0
    if n < 2 then return 0.0 end
    local total = 0.0
    for i = 1, n do
        local a = poly[i]
        local b = poly[(i % n) + 1]
        total = total + sqrt((b.x - a.x) ^ 2 + (b.y - a.y) ^ 2)
    end
    return total
end

--- Do two line segments properly cross?
---
--- Orientation test, three points at a time. `true` only for a PROPER crossing
--- -- the segments pass through each other's interiors. Touching at an endpoint
--- returns false, which is what the ring check below needs: every pair of
--- adjacent edges touches at the vertex they share, and that is the shape being
--- correct rather than broken.
---
--- @return boolean
function BR.SegmentsCross(ax, ay, bx, by, cx, cy, dx, dy)
    local function orient(px, py, qx, qy, rx, ry)
        local v = (qy - py) * (rx - qx) - (qx - px) * (ry - qy)
        if abs(v) < 1e-9 then return 0 end
        return v > 0 and 1 or 2
    end
    local o1 = orient(ax, ay, bx, by, cx, cy)
    local o2 = orient(ax, ay, bx, by, dx, dy)
    local o3 = orient(cx, cy, dx, dy, ax, ay)
    local o4 = orient(cx, cy, dx, dy, bx, by)
    return o1 ~= o2 and o3 ~= o4
end

--- Is the ring SIMPLE -- does it avoid crossing itself?
---
--- This is the precondition ray casting needs, and it is a build-time check
--- rather than a runtime one: O(n^2) over 66 edges is 2145 pairs, which is
--- nothing once per build and pointless once per storm phase.
---
--- A survey taken by clicking vertices on a pause map is exactly the input that
--- can produce a figure-eight -- two points entered out of order and the ring
--- pinches -- and the containment answer inside the pinch would be silently
--- inverted rather than wrong-looking.
---
--- @param poly table
--- @return boolean simple
--- @return integer|nil i, integer|nil j  the first crossing pair, if any
function BR.PolygonIsSimple(poly)
    local n = poly and #poly or 0
    if n < 4 then return true end

    for i = 1, n do
        local a, b = poly[i], poly[(i % n) + 1]
        for j = i + 1, n do
            -- Skip the pairs that SHARE a vertex: consecutive edges, and the
            -- last-to-first wrap.
            local adjacent = (j == i) or ((i % n) + 1 == j) or ((j % n) + 1 == i)
            if not adjacent then
                local c, d = poly[j], poly[(j % n) + 1]
                if BR.SegmentsCross(a.x, a.y, b.x, b.y, c.x, c.y, d.x, d.y) then
                    return false, i, j
                end
            end
        end
    end
    return true
end
