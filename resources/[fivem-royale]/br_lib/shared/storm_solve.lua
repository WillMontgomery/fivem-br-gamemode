-- Storm solver.
--
-- The single most important property here: this is a PURE FUNCTION of a record
-- the server published once, plus the current time. Server and client both call
-- it and both get the same answer, so a shrinking storm costs zero per-frame
-- network traffic. The server uses it to apply damage; the client uses it to draw
-- the wall. Neither one streams the radius to the other.
--
-- Load order: requires enums.lua and geo.lua.

BR = BR or {}

--- The record shape published by the server (whole-table assignment only --
--- nested mutation of a state bag does not replicate):
---
---   {
---     phase   = 0,        -- 0 = pre-storm hold, 1..n = phase index
---     cx0, cy0, r0,       -- current circle
---     cx1, cy1, r1,       -- circle being shrunk toward
---     tStart,             -- server time this phase began
---     tWait,              -- ms held static before shrinking
---     tShrink,            -- ms spent interpolating
---     dps,                -- damage per second outside the circle
---   }

--- Solve the storm at a given time.
---
--- @param rec table|nil   the published storm record
--- @param now number      server time in ms (BR.Clock.now())
--- @return number cx      current centre x
--- @return number cy      current centre y
--- @return number r       current radius
--- @return string state   one of BR.StormPhase
--- @return number msLeft  ms remaining in the current sub-phase
--- @return number dps     damage per second currently applied outside
function BR.StormAt(rec, now)
    if not rec then
        return 0.0, 0.0, 0.0, BR.StormPhase.PRE, 0.0, 0.0
    end

    local elapsed = now - rec.tStart

    -- Still holding: the next circle is already known and drawn on the map, so
    -- players can see where to rotate before the wall starts moving.
    --
    -- PHASE 1'S HOLD IS THE FREE-LOOT PERIOD AND DEALS NO DAMAGE ANYWHERE --
    -- the Fortnite rule: the whole map is safe until the first circle locks in
    -- and starts closing. The tour spans the entire map and the anchor rides
    -- one leg of it, so a far-end jumper can legitimately land kilometres
    -- outside circle 1; bleeding them for it before the wall has ever moved
    -- punishes the drop they were invited to make. From the first shrink
    -- onward -- including every LATER phase's hold -- outside always hurts.
    -- Decided HERE, in the solver, so the server's damage tick and the
    -- client's vignette cannot disagree about it.
    if elapsed < rec.tWait then
        local state = (rec.phase == 0) and BR.StormPhase.PRE or BR.StormPhase.HOLDING
        local dps = (rec.phase <= 1) and 0.0 or rec.dps
        return rec.cx0, rec.cy0, rec.r0, state, rec.tWait - elapsed, dps
    end

    local shrinkElapsed = elapsed - rec.tWait

    -- Collapsed.
    if shrinkElapsed >= rec.tShrink then
        return rec.cx1, rec.cy1, rec.r1, BR.StormPhase.FINISHED, 0.0, rec.dps
    end

    local t = shrinkElapsed / rec.tShrink

    return BR.Lerp(rec.cx0, rec.cx1, t),
           BR.Lerp(rec.cy0, rec.cy1, t),
           BR.Lerp(rec.r0,  rec.r1,  t),
           BR.StormPhase.SHRINKING,
           rec.tShrink - shrinkElapsed,
           rec.dps
end

--- Pick the match anchor: the POI the whole storm sequence homes on.
---
--- The scheme (user-designed, 2026-08-02): one random waypoint of THIS match's
--- flight tour, then one random POI between band.min and band.max units of it.
--- Route-coupled -- the opening circle almost always contains a stretch of the
--- path players actually dropped along -- and POI-anchored, so the centre is
--- always a nameable place on land, never a point in the sea.
---
--- FAILURE IS NOT AN OPTION HERE: this runs inside the WARMUP transition, and
--- an error would kill the match before it starts. So the band widens in steps
--- when a waypoint is POI-sparse (coastal leg-1 points, the Chiliad exits),
--- and the nearest POI of all is the final fallback. Some POI is always
--- returned as long as one exists.
---
--- @param rng table         a BR.Rng instance (server only)
--- @param waypoints table   the tour's authored waypoints, { {x, y}, ... }
--- @param pois table        candidate POIs, { {x, y, ...}, ... }
--- @param band table        { min, max, widenStep, widenMax }
--- @return table|nil poi    the chosen POI (a reference into `pois`)
--- @return table|nil wp     the waypoint it was picked around
function BR.PickStormAnchor(rng, waypoints, pois, band)
    if #pois == 0 or #waypoints == 0 then return nil, nil end

    local wp = rng:pick(waypoints)
    local minD = band and band.min or 500.0
    local maxD = band and band.max or 1500.0
    local step = band and band.widenStep or 500.0
    local cap  = band and band.widenMax or 4000.0

    while true do
        local candidates = {}
        for _, p in ipairs(pois) do
            local d = BR.Dist(wp.x, wp.y, p.x, p.y)
            if d >= minD and d <= maxD then
                candidates[#candidates + 1] = p
            end
        end
        if #candidates > 0 then
            return rng:pick(candidates), wp
        end
        if maxD >= cap then break end
        maxD = math.min(cap, maxD + step)
    end

    -- Nothing within widenMax of this waypoint. Take the nearest POI outright:
    -- a slightly off-band anchor is a shrug, no anchor is a dead match.
    local best, bestD = nil, math.huge
    for _, p in ipairs(pois) do
        local d = BR.Dist(wp.x, wp.y, p.x, p.y)
        if d < bestD then best, bestD = p, d end
    end
    return best, wp
end

--- Choose the centre of the next circle.
---
--- Sampled uniformly inside the slack between the current and next radius, so the
--- new circle always nests inside the old one and nobody is ever caught outside a
--- circle they were legitimately standing in.
---
--- @param rng table       a BR.Rng instance (server only -- this must not be
---                        recomputed client-side, or clients could predict it)
--- @param cx number       current centre
--- @param cy number
--- @param curRadius number
--- @param nextRadius number
--- @param edgeBias number  0..1, how far off-centre the next circle may sit
--- @param aabb table       playable bounds
--- @param minDist number|nil  minimum offset from the current centre -- the
---                        edge-hug rule for the final phases pushes the next
---                        centre out to at least (slack - edgeHugM). Clamped
---                        to the slack, so containment always wins.
--- @return number, number  next centre
function BR.NextStormCentre(rng, cx, cy, curRadius, nextRadius, edgeBias, aabb, minDist)
    local slack = curRadius - nextRadius
    if slack <= 0 then
        return cx, cy
    end

    -- A config value above 1.0 would push the new centre further than the slack
    -- allows and silently break containment, so clamp rather than trusting it.
    edgeBias = BR.Clamp(edgeBias or 0.55, 0.0, 1.0)

    -- pointInDisc applies the sqrt that keeps the distribution uniform rather
    -- than centre-clustered. Without it every match's zone path feels the same.
    local nx, ny = rng:pointInDisc(cx, cy, slack * edgeBias)

    -- The edge hug: push a too-central draw outward along its own bearing
    -- until it clears the minimum. A zero-length draw gets a random bearing
    -- -- there is no "outward" from the exact centre.
    minDist = BR.Clamp(minDist or 0.0, 0.0, slack)
    local off = BR.Dist(cx, cy, nx, ny)
    if off < minDist then
        local ang
        if off > 1e-9 then
            ang = math.atan(ny - cy, nx - cx)
        else
            ang = rng:float() * 2.0 * math.pi
        end
        nx = cx + math.cos(ang) * minDist
        ny = cy + math.sin(ang) * minDist
    end

    if aabb then
        nx, ny = BR.ClampCircleToAABB(nx, ny, nextRadius, aabb)

        -- Clamping to the map bounds can push the centre further from the old
        -- one than the slack permits -- most easily when the current circle
        -- already overhangs the bounds, which the opening circle routinely does.
        --
        -- CONTAINMENT WINS OVER BOUNDS. A circle poking into the ocean is a
        -- cosmetic problem; a circle that is not contained by its predecessor
        -- puts a player who was standing legitimately inside the safe zone into
        -- the storm through no fault of their own, and presents as an
        -- unreproducible "I was taking damage inside the circle" bug report.
        --
        -- So pull the centre back along the line toward the previous centre
        -- until the new circle is contained again.
        local d = BR.Dist(cx, cy, nx, ny)
        if d > slack and d > 1e-9 then
            local t = slack / d
            nx = cx + (nx - cx) * t
            ny = cy + (ny - cy) * t
        end
    end

    return nx, ny
end

--- Build the record for a phase transition.
---
--- @param phase integer      phase index being entered (1-based)
--- @param cx0 number         circle we are starting from
--- @param cy0 number
--- @param r0 number
--- @param cx1 number         circle we are shrinking toward
--- @param cy1 number
--- @param r1 number
--- @param now number         server time
--- @param waitMs number
--- @param shrinkMs number
--- @param dps number
--- @return table
function BR.BuildStormRecord(phase, cx0, cy0, r0, cx1, cy1, r1, now, waitMs, shrinkMs, dps)
    return {
        phase   = phase,
        cx0     = cx0 + 0.0,
        cy0     = cy0 + 0.0,
        r0      = r0 + 0.0,
        cx1     = cx1 + 0.0,
        cy1     = cy1 + 0.0,
        r1      = r1 + 0.0,
        tStart  = now + 0.0,
        tWait   = waitMs + 0.0,
        tShrink = shrinkMs + 0.0,
        dps     = dps + 0.0,
    }
end

--- Total ms from the start of a phase until its circle has fully collapsed.
function BR.StormPhaseDuration(rec)
    if not rec then return 0.0 end
    return rec.tWait + rec.tShrink
end
