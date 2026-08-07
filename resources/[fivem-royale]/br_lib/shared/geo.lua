-- Geometry and math helpers shared by server and client.
--
-- Everything here is allocation-free where it plausibly runs per frame: the storm
-- renderer calls ArcPoints() every frame, so it writes into a caller-supplied
-- buffer rather than returning a fresh table. Per-frame table churn shows up as
-- GC stutter, not as average frame cost, which makes it hard to spot later.

BR = BR or {}

local sin, cos, sqrt, pi = math.sin, math.cos, math.sqrt, math.pi

--- Clamp v into [lo, hi].
function BR.Clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

--- Linear interpolation. Deliberately linear everywhere in this project:
--- smoothstep looks marginally nicer on the storm and destroys the player's
--- ability to judge "how long until the wall reaches me", which is the core
--- tactical question of the genre.
function BR.Lerp(a, b, t)
    return a + (b - a) * t
end

--- Squared 2D distance. Prefer this in comparisons to avoid the sqrt.
function BR.Dist2(x1, y1, x2, y2)
    local dx, dy = x2 - x1, y2 - y1
    return dx * dx + dy * dy
end

--- True 2D distance.
function BR.Dist(x1, y1, x2, y2)
    return sqrt(BR.Dist2(x1, y1, x2, y2))
end

--- Is (x, y) inside the circle? Uses squared comparison.
function BR.InCircle(x, y, cx, cy, radius)
    return BR.Dist2(x, y, cx, cy) <= radius * radius
end

--- Signed distance from the circle edge. Negative = inside, positive = outside.
--- The storm uses this for both the damage test and the "how far to safety" HUD.
function BR.EdgeDistance(x, y, cx, cy, radius)
    return BR.Dist(x, y, cx, cy) - radius
end

--- Clamp a point into an axis-aligned box. Used to keep each shrinking storm
--- circle from drifting off the playable landmass.
function BR.ClampToAABB(x, y, aabb)
    return BR.Clamp(x, aabb.min.x, aabb.max.x),
           BR.Clamp(y, aabb.min.y, aabb.max.y)
end

--- Clamp a circle so it stays fully inside the box where possible.
function BR.ClampCircleToAABB(cx, cy, radius, aabb)
    local minX, maxX = aabb.min.x + radius, aabb.max.x - radius
    local minY, maxY = aabb.min.y + radius, aabb.max.y - radius

    -- If the circle is wider than the box, centring is the best we can do.
    if minX > maxX then
        cx = (aabb.min.x + aabb.max.x) * 0.5
    else
        cx = BR.Clamp(cx, minX, maxX)
    end
    if minY > maxY then
        cy = (aabb.min.y + aabb.max.y) * 0.5
    else
        cy = BR.Clamp(cy, minY, maxY)
    end
    return cx, cy
end

--- Bearing in degrees from (x1,y1) to (x2,y2), 0 = north, clockwise.
function BR.Bearing(x1, y1, x2, y2)
    local deg = math.deg(math.atan(x2 - x1, y2 - y1))
    if deg < 0 then deg = deg + 360.0 end
    return deg
end

--- A COMPASS bearing converted to a GTA entity heading.
---
--- The two run opposite ways around: bearings increase clockwise from north,
--- GTA headings counter-clockwise. Conflating them is why the first bus flew
--- sideways-mirrored to its route -- every entity-facing consumer of
--- BR.Bearing must pass through this.
--- @param bearing number  degrees, 0 = north, clockwise
--- @return number heading  degrees, 0 = north, counter-clockwise
function BR.GtaHeading(bearing)
    return (360.0 - bearing) % 360.0
end

--- Sample points along the arc of a circle nearest to (px, py).
---
--- This is what makes the storm wall affordable. Drawing the full circle would
--- need hundreds of markers at large radii; we only ever draw the slice the
--- player can actually see, so cost is constant regardless of circle size.
---
--- Writes { x, y } pairs into `buf` and returns the number of points written.
--- `buf` is reused across frames by the caller.
---
--- @param buf table         reusable output buffer of {x=,y=} tables
--- @param cx number         circle centre x
--- @param cy number         circle centre y
--- @param radius number     circle radius
--- @param px number         player x
--- @param py number         player y
--- @param segments integer  number of points to emit
--- @param spanDeg number    total arc width in degrees, centred on the player
--- @return integer count
function BR.ArcPoints(buf, cx, cy, radius, px, py, segments, spanDeg)
    if radius <= 0.0 then return 0 end

    -- Angle from the circle centre toward the player. The nearest point on the
    -- circle lies along this bearing, so we centre the arc there.
    local mid = math.atan(py - cy, px - cx)
    local span = math.rad(spanDeg)
    local step = span / (segments - 1)
    local start = mid - span * 0.5

    for i = 1, segments do
        local a = start + step * (i - 1)
        local p = buf[i]
        if not p then
            p = {}
            buf[i] = p
        end
        p.x = cx + cos(a) * radius
        p.y = cy + sin(a) * radius
    end

    return segments
end

--- Chord length between adjacent arc samples, used as marker width so the
--- cylinders butt together without overlapping. Overlapping alpha bands are the
--- single ugliest artifact of the marker-wall technique.
function BR.ArcSegmentWidth(radius, segments, spanDeg)
    local step = math.rad(spanDeg) / (segments - 1)
    return 2.0 * radius * sin(step * 0.5)
end

--- Where a two-leg bus route puts the bus at time t.
---
--- Shared by the server (jump validation, force-eject coordinates) and every
--- client (rendering the bus), all computing from the SAME published record
--- against the synced clock -- which is what makes 48 locally spawned buses
--- appear to be one bus, with zero per-frame network traffic.
---
--- Legs: start (the airstrip) -> mid (chord entry, cruise speed), then
--- mid -> end (the drop chord, slower). Clamped at both ends so a caller a
--- frame early or late gets the endpoints, not an extrapolation.
---
--- Where a WAYPOINT PATH puts the bus at time t.
---
--- The path is an array of { x, y, z, t } with strictly increasing t,
--- authored once by the server -- ground roll, rotation, climb, the banked
--- turn, the acceleration, all of it is just waypoint spacing and timing.
--- Every client and the server interpolate the same array against the same
--- clock, which is what makes 48 locally spawned buses appear to be one.
---
--- Replaces the old two-straight-legs model, whose instant heading change at
--- the leg boundary read in-game as the plane teleporting mid-air.
---
--- Clamped at both ends: before the first timestamp you are parked at the
--- first point, after the last you are parked at the last.
---
--- @param points table  array of { x, y, z, t }
--- @param t number      synced-clock milliseconds
--- @return number x, number y, number z, number dx, number dy  position, travel direction
function BR.PathPosAt(points, t)
    local n = #points
    local first, last = points[1], points[n]

    if t <= first.t or n == 1 then
        local nxt = points[2] or last
        return first.x, first.y, first.z, nxt.x - first.x, nxt.y - first.y
    end
    if t >= last.t then
        local prev = points[n - 1] or first
        return last.x, last.y, last.z, last.x - prev.x, last.y - prev.y
    end

    -- Linear scan: paths are under a hundred points and calls are per-frame,
    -- not per-entity -- measured cost is noise. Revisit only if paths grow.
    for i = 2, n do
        local b = points[i]
        if t <= b.t then
            local a = points[i - 1]
            local k = (t - a.t) / math.max(1, b.t - a.t)
            return BR.Lerp(a.x, b.x, k), BR.Lerp(a.y, b.y, k), BR.Lerp(a.z, b.z, k),
                   b.x - a.x, b.y - a.y
        end
    end
    return last.x, last.y, last.z, 0.0, 0.0
end

--- Pick a chord across a circle: two points on the circumference, offset from
--- centre so the line does not always pass through the middle.
---
--- @param rng table       a BR.Rng instance
--- @param cx number
--- @param cy number
--- @param radius number
--- @param maxOffset number  0..1, how far off-centre the chord may sit
--- @return number, number, number, number  sx, sy, ex, ey
function BR.PickChord(rng, cx, cy, radius, maxOffset)
    local theta = rng:float() * 2.0 * pi
    local dx, dy = cos(theta), sin(theta)

    -- Perpendicular offset, so the flight path varies match to match.
    local offset = (rng:float() * 2.0 - 1.0) * radius * (maxOffset or 0.5)
    local ox, oy = -dy * offset, dx * offset

    -- Half-chord length at that offset.
    local half = sqrt(math.max(0.0, radius * radius - offset * offset))

    return cx + ox - dx * half, cy + oy - dy * half,
           cx + ox + dx * half, cy + oy + dy * half
end

--- Normalise a GTA hash to its UNSIGNED 32-bit value.
---
--- THE ENGINE HANDS BACK SIGNED HASHES. GetCurrentPedWeapon, GetHashKey,
--- GetEntityModel and friends return a signed 32-bit int, so any hash with the
--- top bit set comes back NEGATIVE -- 0xDB1AA450 arrives as -619916720. The
--- config authors them as positive literals, so the two never compare equal and
--- never hit the same table key.
---
--- This cost half the arsenal. TWENTY of forty weapons have the top bit set,
--- and every one of them had unlimited ammo: the ammo reporter refuses to
--- report unless the engine agrees what is in the hand, the comparison could
--- never be true, so nothing was ever deducted. The Advanced Rifle and the
--- Machine Pistol were simply the two the user happened to pick up
--- (2026-08-06). It also explains the "unknown (0x9D07F764)" in an earlier
--- probe -- that WAS our MG; WeaponByHash just could not find it.
---
--- Nothing about it is visible: printing both sides with %08X masks them back
--- to the same digits, which is exactly what the first diagnostic did.
---
--- Use this on BOTH sides of any hash comparison, and on every hash used as a
--- table key.
--- @param h integer|nil
--- @return integer|nil
function BR.NormHash(h)
    if not h then return nil end
    return h & 0xFFFFFFFF
end
