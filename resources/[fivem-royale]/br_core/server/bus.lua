-- The Battle Bus, server half: route authorship and jump authority.
--
-- The bus is a SHARED ILLUSION, not a shared entity. The server never spawns
-- anything; it publishes one route record and every client flies its own
-- local, non-networked plane along it against the synced clock. A Titan seats
-- four -- attaching 48 networked peds to one networked vehicle is a guaranteed
-- ownership-thrash failure, which is why that design was rejected in planning
-- rather than discovered in testing.
--
-- What IS authoritative here:
--   * the route (published once, never streamed),
--   * who may jump and when (state BUS, inside the jump window),
--   * where a jumper exits (computed HERE from the route -- the client asks,
--     it does not tell),
--   * the force-eject at the end of the line.

BR = BR or {}
BR.Bus = {}

local route = nil       -- the published record, nil between matches
local anchor = nil      -- the LS-side anchor this route crosses

--- The active route, or nil.
function BR.Bus.active()
    return route
end

--- Author this match's flight GEOMETRY and broadcast the preview.
---
--- Called when WARMUP begins, so players spend the warmup looking at the
--- route on the map and arguing about where to drop. One waypoint option is
--- drawn from each authored leg list (4 x 4 x 4 x 3 = 192 flights); corners
--- are filleted into arcs; every point carries the speed the plane holds
--- into it. No timestamps yet -- the wheels do not move until BUS, and
--- depart() stamps the clock then.
function BR.Bus.plan()
    local cfg = BR.Config.Bus

    -- The anchor is still picked per match for M4's storm, but it is now
    -- DECOUPLED from the flight: the tour crosses the whole map, so the
    -- storm no longer needs to hug the bus path. M4 revisits this.
    local rng = BR.Rng(GetGameTimer())
    anchor = rng:pick(BR.Config.Storm.anchors)
    BR.Server.matchAnchor = anchor

    -- Draw the tour: one option per leg, flattened into waypoints.
    local legs, waypoints = {}, {}
    for i, options in ipairs(cfg.legs) do
        local pick = rng:int(1, #options)
        legs[i] = pick
        for _, wp in ipairs(options[pick]) do
            waypoints[#waypoints + 1] = {
                x = wp.x, y = wp.y, z = wp.z or cfg.altitude,
            }
        end
    end

    -- ---- build the geometry ------------------------------------------------

    local points = {}   -- { x, y, z, v }: v = speed carried into this point

    local function push(x, y, z, v)
        points[#points + 1] = { x = x, y = y, z = z, v = v }
    end

    -- Parked, then the ground roll: speed builds across the surveyed stretch.
    local sp, rp = cfg.spawn, cfg.rotatePoint
    push(sp.x, sp.y, sp.z, 1.0)
    local rollSamples = 6
    for i = 1, rollSamples do
        local k = i / rollSamples
        push(BR.Lerp(sp.x, rp.x, k), BR.Lerp(sp.y, rp.y, k), sp.z,
             BR.Lerp(15.0, cfg.rollSpeed, (k + (i - 1) / rollSamples) * 0.5))
    end

    -- Wheels up: hold the runway heading, climb to altitude over climbDist.
    local dirX, dirY = rp.x - sp.x, rp.y - sp.y
    local dLen = math.max(1.0, BR.Dist(sp.x, sp.y, rp.x, rp.y))
    dirX, dirY = dirX / dLen, dirY / dLen

    local climbSamples = 8
    for i = 1, climbSamples do
        local k = i / climbSamples
        local ease = k * k * (3.0 - 2.0 * k)
        push(rp.x + dirX * cfg.climbDist * k,
             rp.y + dirY * cfg.climbDist * k,
             BR.Lerp(sp.z, cfg.altitude, ease),
             BR.Lerp(cfg.rollSpeed, cfg.climbSpeed, k))
    end

    -- The banked turn toward the first waypoint: a pursuit arc in fixed
    -- angular steps until the nose points at it.
    local w1 = waypoints[1]
    local hx, hy = dirX, dirY
    local px = rp.x + dirX * cfg.climbDist
    local py = rp.y + dirY * cfg.climbDist
    local stepRad = math.rad(6.0)
    local stepLen = cfg.turnRadius * stepRad
    for _ = 1, 60 do
        local tx, ty = w1.x - px, w1.y - py
        local tLen = math.max(1.0, math.sqrt(tx * tx + ty * ty))
        tx, ty = tx / tLen, ty / tLen
        if hx * tx + hy * ty > math.cos(math.rad(5.0)) then break end
        local turn = (hx * ty - hy * tx) >= 0 and stepRad or -stepRad
        local c, s = math.cos(turn), math.sin(turn)
        hx, hy = hx * c - hy * s, hx * s + hy * c
        px, py = px + hx * stepLen, py + hy * stepLen
        push(px, py, cfg.altitude, cfg.climbSpeed)
    end

    -- The ocean approach: accelerate to cruise toward the first waypoint's
    -- fillet entry. Everything after that entry is the drop zone, flown at
    -- drop speed -- the whole tour is jumpable, so nothing over land moves
    -- at cruise.
    local jumpIdx = nil
    local cx, cy, cz = px, py, cfg.altitude   -- current pen position

    --- Straight run to (nx, ny, nz), sampled, speed ramping vFrom -> vTo.
    local function straight(nx, ny, nz, vFrom, vTo, samples)
        for i = 1, samples do
            local k = i / samples
            push(BR.Lerp(cx, nx, k), BR.Lerp(cy, ny, k), BR.Lerp(cz, nz, k),
                 BR.Lerp(vFrom, vTo, k))
        end
        cx, cy, cz = nx, ny, nz
    end

    local closeIdx = nil
    for i, wp in ipairs(waypoints) do
        local nxt = waypoints[i + 1]
        if not nxt then
            -- Final waypoint: run straight in... and then KEEP FLYING. The
            -- overrun past the last authored point is the "doors closing"
            -- window: five more seconds aboard before the force-eject,
            -- instead of the plane evaporating on arrival.
            straight(wp.x, wp.y, wp.z, cfg.speed, cfg.speed, 6)
            closeIdx = #points

            local pv = points[#points - 1]
            local odx, ody = wp.x - pv.x, wp.y - pv.y
            local oLen = math.max(1.0, math.sqrt(odx * odx + ody * ody))
            local oDist = cfg.speed * (cfg.overrunSecs or 5)
            straight(wp.x + odx / oLen * oDist, wp.y + ody / oLen * oDist,
                     wp.z, cfg.speed, cfg.speed, 3)
        else
            -- Fillet: trim the corner by up to turnRadius (never more than
            -- 35% of either adjoining stretch), then round it with a
            -- quadratic Bezier through the authored point.
            local inLen  = BR.Dist(cx, cy, wp.x, wp.y)
            local outLen = BR.Dist(wp.x, wp.y, nxt.x, nxt.y)
            local trim   = math.min(cfg.turnRadius, inLen * 0.35, outLen * 0.35)

            local ik = math.max(0.0, 1.0 - trim / math.max(1.0, inLen))
            local ex1 = BR.Lerp(cx, wp.x, ik)
            local ey1 = BR.Lerp(cy, wp.y, ik)
            local ez1 = BR.Lerp(cz, wp.z, ik)

            local ok2 = math.min(1.0, trim / math.max(1.0, outLen))
            local ex2 = BR.Lerp(wp.x, nxt.x, ok2)
            local ey2 = BR.Lerp(wp.y, nxt.y, ok2)
            local ez2 = BR.Lerp(wp.z, nxt.z, ok2)

            local approachV = (i == 1) and cfg.cruiseSpeed or cfg.speed
            straight(ex1, ey1, ez1,
                     (i == 1) and cfg.climbSpeed or cfg.speed, approachV,
                     (i == 1) and 10 or 6)

            if i == 1 and not jumpIdx then
                -- Doors: arrival at the leg-1 waypoint -- the coastline.
                jumpIdx = #points
            end

            for b = 1, 6 do
                local k = b / 6
                local omk = 1.0 - k
                push(omk * omk * ex1 + 2 * omk * k * wp.x + k * k * ex2,
                     omk * omk * ey1 + 2 * omk * k * wp.y + k * k * ey2,
                     BR.Lerp(ez1, ez2, k),
                     cfg.cornerSpeed)
            end
            cx, cy, cz = ex2, ey2, ez2
        end
    end

    route = {
        points    = points,
        waypoints = waypoints,   -- the authored tour, for the map drawing
        legs      = legs,
        jumpIdx   = jumpIdx or #points,
        closeIdx  = closeIdx or #points,   -- last authored point: doors-closing warning
        alt       = cfg.altitude,
        heading   = sp.heading,
        timed     = false,
    }

    print(('[br_core] bus: tour %d-%d-%d-%d, %d waypoints, %d path points')
        :format(legs[1], legs[2], legs[3], legs[4], #waypoints, #points))

    TriggerClientEvent(BR.Net.BUS_ROUTE, -1, route)
end

--- Stamp the clock onto the planned geometry and broadcast the flight.
--- Called when BUS begins: timestamps accumulate as segment length over the
--- speed carried into each point, so the profile IS the timing.
--- @return number  seconds until BUS should hand over to PLAYING
function BR.Bus.depart()
    local cfg = BR.Config.Bus
    local now = GetGameTimer()
    local pts = route.points

    -- PHYSICS-SMOOTH THE SPEED PROFILE before stamping the clock. The
    -- authored profile changes speed in blocks (cruise into a corner was a
    -- 400 -> 150 step across one sample), which rode like a handbrake. Two
    -- kinematic passes -- accelerate forward, brake backward, both capped at
    -- maxAccel -- turn every step into a ramp: v^2 = v0^2 + 2ad, the same
    -- arithmetic a driving NPC obeys.
    local amax = cfg.maxAccel or 9.0
    for i = 2, #pts do
        local d = BR.Dist(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y)
        local cap = math.sqrt(pts[i - 1].v ^ 2 + 2 * amax * d)
        if pts[i].v > cap then pts[i].v = cap end
    end
    for i = #pts - 1, 1, -1 do
        local d = BR.Dist(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
        local cap = math.sqrt(pts[i + 1].v ^ 2 + 2 * amax * d)
        if pts[i].v > cap then pts[i].v = cap end
    end

    local clockMs = now + cfg.boardSeconds * 1000
    local prev = nil
    for _, p in ipairs(pts) do
        if prev then
            local d = BR.Dist(prev.x, prev.y, p.x, p.y)
            -- Average of entry and exit speed across the segment, since the
            -- smoothing made speed continuous.
            local v = math.max(1.0, (prev.v + p.v) * 0.5)
            clockMs = clockMs + (d / v) * 1000.0
        end
        p.t = math.floor(clockMs)
        prev = p
    end

    route.timed      = true
    route.tStart     = pts[1].t
    route.jumpFrom   = pts[route.jumpIdx].t
    route.doorsClose = pts[route.closeIdx].t
    route.tEnd       = pts[#pts].t
    route.serverNow  = now

    print(('[br_core] bus: departing -- doors at %.0fs, %.0fs total')
        :format((route.jumpFrom - now) / 1000, (route.tEnd - now) / 1000))

    TriggerClientEvent(BR.Net.BUS_ROUTE, -1, route)
    return (route.tEnd - now) / 1000 + cfg.jumpGrace
end

--- Late joiners during warmup need the preview the room already has.
--- @param src integer
function BR.Bus.sendPreview(src)
    if route then
        TriggerClientEvent(BR.Net.BUS_ROUTE, src, route)
    end
end

function BR.Bus.clear()
    route = nil
end

--- Put one player out of the bus. The exit point is the bus's position on the
--- route RIGHT NOW by the server's clock -- the client is told where it
--- jumped from, never asked.
--- @param src integer
--- @param forced boolean|nil
local function eject(src, forced)
    local entry = BR.Roster.get(src)
    if not entry or entry.state ~= BR.PlayerState.BUS
       or not route or not route.timed then return end

    local t = math.min(GetGameTimer(), route.tEnd)
    local x, y, z, dx, dy = BR.PathPosAt(route.points, t)

    BR.Roster.setState(src, BR.PlayerState.FREEFALL)
    TriggerClientEvent(BR.Net.BUS_JUMP_OK, src, {
        x = x, y = y, z = z,
        -- GTA heading of the travel direction HERE -- the client feeds this
        -- straight to SetEntityHeading and its exit-velocity vector.
        heading = BR.GtaHeading(BR.Bearing(0.0, 0.0, dx, dy)),
        forced = forced or false,
    })

    print(('[br_core] %s (%d) %s at %.0f, %.0f')
        :format(entry.name, src, forced and 'force-ejected' or 'jumped', x, y))
end

RegisterNetEvent(BR.Net.BUS_JUMP)
AddEventHandler(BR.Net.BUS_JUMP, function()
    local src = source

    -- Refusals are AUDIBLE, in both consoles. The first flight had a jump
    -- key that "did nothing": the request was being refused silently, and
    -- from in the game that is indistinguishable from the key being dead.
    if BR.Server.match.state ~= BR.MatchState.BUS
       or not route or not route.timed then
        print(('[br_core] bus: jump from %d refused -- state is %s')
            :format(src, BR.Server.match.state))
        return
    end
    if GetGameTimer() < route.jumpFrom then
        BR.Server.notify(src, 'Doors are still closed.', 'warn')
        print(('[br_core] bus: jump from %d refused -- doors open in %.1fs')
            :format(src, (route.jumpFrom - GetGameTimer()) / 1000))
        return
    end

    eject(src, false)
end)

--- Force out everyone still aboard. The end-of-route job below is the usual
--- caller; the PLAYING transition also calls it, so no path into PLAYING --
--- including brforce mid-flight -- can strand a player in the BUS state,
--- invisible and frozen with the match running around them.
function BR.Bus.ejectAll()
    if not route then return end
    BR.Roster.each(
        function(e) return e.state == BR.PlayerState.BUS end,
        function(src) eject(src, true) end)
end

-- Nobody rides the bus home. Anyone still aboard when the chord runs out is
-- put out over its end -- the same rule Fortnite applies, and the only thing
-- stopping "hide in the bus" from being a strategy.
BR.Sched.every(500, 'bus.eject', function()
    if BR.Server.match.state ~= BR.MatchState.BUS
       or not route or not route.timed then return end
    if GetGameTimer() < route.tEnd then return end
    BR.Bus.ejectAll()
end)

-- Landing. FREEFALL -> ALIVE happens when the CLIENT reports touchdown, not
-- when the match flips to PLAYING -- a player still gliding when the bus
-- route expires keeps falling, and only becomes fair game on the ground.
-- The report is a claim about their own ped, the one thing a client can
-- legitimately observe; the position sampler would catch a wildly false one.
RegisterNetEvent(BR.Net.DROP_LANDED)
AddEventHandler(BR.Net.DROP_LANDED, function()
    local src = source
    local entry = BR.Roster.get(src)
    if not entry then return end

    if entry.state == BR.PlayerState.FREEFALL
       or entry.state == BR.PlayerState.GLIDE then
        BR.Roster.setState(src, BR.PlayerState.ALIVE)
        print(('[br_core] %s (%d) landed'):format(entry.name, src))
    end
end)
