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

--- The breakout budget for one phase, with the chance RAMPED by progress.
---
--- The first circle must never break out and the last should nearly always
--- (user call, 2026-08-06). The reason is that the opening circle is enormous
--- and already contains most of the map -- moving it outside itself asks
--- players to cross the whole island before they have a gun -- while the late
--- circles are small, everyone is armed, and a static circle is where a
--- passive player wins by having picked the right building.
---
--- Linear from chanceStart at phase 1 to chanceEnd at the last phase.
---
--- @param cfg table      BR.Config.Storm
--- @param phase integer  1-based phase being entered
--- @return table|nil     { chance, overhang, minRadius } for NextStormCentre
function BR.StormBreakoutFor(cfg, phase)
    local bo = cfg and cfg.breakout
    if not bo then return nil end

    local n = #(cfg.phases or {})
    local t = 1.0
    if n > 1 then
        t = BR.Clamp((phase - 1) / (n - 1), 0.0, 1.0)
    end

    local a = bo.chanceStart or 0.0
    local b = bo.chanceEnd or 0.0
    return {
        chance    = a + (b - a) * t,
        gapMax    = bo.gapMax,
        minRadius = bo.minRadius,
    }
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
---                        to the phase's reach budget.
--- @param breakout table|nil  { chance, overhang, minRadius } -- lets this
---                        phase's circle leave the current one entirely. Omit
---                        for the strict nesting rule.
--- @return number, number  next centre
function BR.NextStormCentre(rng, cx, cy, curRadius, nextRadius, edgeBias, aabb, minDist, breakout)
    local slack = curRadius - nextRadius
    if slack <= 0 then
        return cx, cy
    end

    -- BREAKOUT: this phase may leave the current circle entirely.
    --
    -- Rolled FIRST, before any draw that depends on it, so the decision costs
    -- exactly one RNG value whether or not it fires -- a conditional draw
    -- would make the sequence depend on the outcome and two servers on the
    -- same seed would diverge from here on.
    --
    -- What it changes is the budget: `slack` is the containment limit, and a
    -- breakout raises the ceiling on how far the centre may sit from the old
    -- one. Everything downstream still works in terms of `reach`, so the
    -- edge-hug and the AABB pull-back need no special case.
    -- A BREAKOUT MAY SEPARATE THE CIRCLES ENTIRELY.
    --
    -- Stated as the geometry rather than as a fudge factor, because that is
    -- how it was asked for (user, 2026-08-06): the new circle may sit wholly
    -- outside the old one, and the GAP between their edges is capped at
    -- `gapMax` times the predecessor's radius.
    --
    --     d_max = curRadius + nextRadius + gapMax * curRadius
    --              \___________________/   \_________________/
    --                 edges just touch        the gap allowed
    --
    -- Two earlier formulations were wrong in instructive ways. Scaling the
    -- budget by the NEXT radius made the final phase (next radius 0) unable to
    -- move at all. Scaling it by the current radius fixed that but could never
    -- separate the circles on the early phases, where nextRadius/curRadius is
    -- large. Expressing the thing we actually want removes both accidents.
    local reach, broke = slack, false
    if breakout and breakout.chance and breakout.chance > 0
       and curRadius >= (breakout.minRadius or 0.0) then
        if rng:float() < breakout.chance then
            broke = true
            reach = curRadius + nextRadius
                  + (breakout.gapMax or 0.5) * curRadius
        end
    end

    -- A config value above 1.0 would push the new centre past the reach budget
    -- and silently overshoot it, so clamp rather than trusting it.
    edgeBias = BR.Clamp(edgeBias or 0.55, 0.0, 1.0)

    -- pointInDisc applies the sqrt that keeps the distribution uniform rather
    -- than centre-clustered. Without it every match's zone path feels the same.
    local nx, ny = rng:pointInDisc(cx, cy, reach * edgeBias)

    -- The edge hug: push a too-central draw outward along its own bearing
    -- until it clears the minimum. A zero-length draw gets a random bearing
    -- -- there is no "outward" from the exact centre.
    minDist = BR.Clamp(minDist or 0.0, 0.0, reach)
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
        -- one than the reach budget permits -- most easily when the current
        -- circle already overhangs the bounds, which the opening circle
        -- routinely does.
        --
        -- THE REACH BUDGET WINS OVER BOUNDS. A circle poking into the ocean is
        -- a cosmetic problem; a circle further out than the phase intended is
        -- a run nobody was given time for, because the shrink duration was
        -- priced off the distance the solver chose.
        --
        -- Note this is a bound on the OFFSET, not on containment: when the
        -- breakout roll fires, `reach` exceeds the slack on purpose and the
        -- new circle is legitimately not nested. What must never happen is
        -- exceeding whatever budget this phase actually settled on.
        local d = BR.Dist(cx, cy, nx, ny)
        if d > reach and d > 1e-9 then
            local t = reach / d
            nx = cx + (nx - cx) * t
            ny = cy + (ny - cy) * t
        end
    end

    -- AND NOT OFF THE MAP.
    --
    -- The anchor is a POI and therefore always on land, but nothing stopped
    -- the per-phase drift from walking seaward one circle at a time -- eight
    -- phases of `slack * edgeBias` off a coastal anchor is enough to finish
    -- over open water, and the final circle is where it matters most (user,
    -- 2026-08-06: "rare (but possible) cases where the storm can close in to
    -- an anchor point in the ocean").
    --
    -- Walked back along its own line toward the PREVIOUS centre, which is on
    -- the map by induction: phase 0 is the anchor POI, and every POI is inside
    -- the boundary (tools/check_boundary.lua is what makes that true rather
    -- than hoped). That makes this terminate, and it keeps the draw's bearing
    -- -- the circle still moves the way the roll said, just not as far.
    -- Containment is preserved for free, since every step is strictly closer
    -- to the centre it was already contained by.
    --
    -- ═══ THE MASK IS THE SURVEYED BOUNDARY NOW, NOT JUST THE RECTANGLES ═══
    --
    -- It used to be BR.Config.Map.Water alone: five coarse rectangles authored
    -- to stop LOOT generating in the Pacific. They were never a map outline,
    -- and the gaps between them are where the storm went. Measured over 4000
    -- simulated matches on the old rule, 20.2% of them ENDED with the final
    -- circle's centre outside the playable shape -- which is the owner's report
    -- ("we have too many places where the storm can end outside the map and in
    -- the ocean", 2026-08-28) as a number rather than as an anecdote.
    --
    -- BOTH TESTS RUN, because neither contains the other. The boundary is the
    -- island's outline and knows nothing about the water inside it; the Alamo
    -- Sea rectangle sits wholly within the ring and is the case the boundary
    -- cannot catch. The four ocean rectangles are wholly outside it and are now
    -- redundant here -- kept because they cost one comparison and because
    -- deleting a backstop to save a comparison is how backstops go missing.
    local M = BR.Config and BR.Config.Map
    local function offMap(x, y)
        if not M then return false end
        if M.IsWater and M.IsWater(x, y) then return true end
        if M.InBounds and not M.InBounds(x, y) then return true end
        return false
    end

    if offMap(nx, ny) then
        for attempt = 1, 8 do
            local t = 1.0 - attempt / 8.0
            local tx, ty = cx + (nx - cx) * t, cy + (ny - cy) * t
            if not offMap(tx, ty) then
                return tx, ty, broke
            end
        end
        -- Every step of the way in was off the map, which means the CURRENT
        -- centre is too. Nothing better to offer than staying put.
        return cx, cy, broke
    end

    return nx, ny, broke
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
