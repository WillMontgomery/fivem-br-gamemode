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

--- How much of a chord overflies LAND, 0..1.
---
--- Proximity to authored POIs is the proxy -- they blanket the landmass and
--- exist on both sides already. Sampled, not solved: thirteen distance checks
--- against two dozen POIs, once per candidate, at match start.
--- @return number
function BR.Bus.landScore(x1, y1, x2, y2)
    local hits, samples = 0, 12
    for i = 0, samples do
        local k = i / samples
        local _, d = BR.Config.Map.NearestPOI(BR.Lerp(x1, x2, k), BR.Lerp(y1, y2, k))
        if d and d <= BR.Config.Bus.landRadius then hits = hits + 1 end
    end
    return hits / (samples + 1)
end

--- Author a route for this match and remember it. Does not broadcast.
---
--- The flight is a WAYPOINT PATH: parked at the surveyed runway spawn,
--- ground roll to the surveyed rotation point, wheels-up and a straight
--- climb on the same heading to altitude, one banked turn onto the heading
--- for the chord entry, acceleration across the ocean, then the drop chord
--- -- the jump window -- at drop speed. Timing IS the speed profile:
--- waypoints are spaced by segment length over the speed the plane should
--- carry there, so the roll starts gentle (streaming gets a head start) and
--- the ocean crossing is the fast part.
---
--- The chord is the best of several candidates by land coverage: an unscored
--- random chord across a coastal anchor is water-to-water often enough to
--- have actually happened on the first flights.
---
--- @return number  seconds until BUS should hand over to PLAYING
function BR.Bus.plan()
    local cfg = BR.Config.Bus

    -- The anchor is picked here and REMEMBERED: M4's storm must shrink over
    -- the same ground the bus crossed, or drops and circles disagree about
    -- where the match is.
    local rng = BR.Rng(GetGameTimer())
    anchor = rng:pick(BR.Config.Storm.anchors)
    BR.Server.matchAnchor = anchor

    local x1, y1, x2, y2, best = nil, nil, nil, nil, -1.0
    for _ = 1, cfg.chordTries do
        local cx1, cy1, cx2, cy2 = BR.PickChord(rng, anchor.x, anchor.y,
                                                cfg.chordRadius, cfg.chordOffset)
        local score = BR.Bus.landScore(cx1, cy1, cx2, cy2)
        if score > best then
            x1, y1, x2, y2, best = cx1, cy1, cx2, cy2, score
        end
        -- Good enough is good enough; keep drawing only while it is not.
        -- A coastal anchor can hand out a 30%-land "best of N" -- which a
        -- player experiences as flying over water the whole way.
        if best >= (cfg.minLandScore or 0) then break end
    end

    local sp = cfg.spawn
    -- Enter at the end nearer the airstrip.
    if BR.Dist2(sp.x, sp.y, x2, y2) < BR.Dist2(sp.x, sp.y, x1, y1) then
        x1, y1, x2, y2 = x2, y2, x1, y1
    end

    -- ---- build the path ---------------------------------------------------

    local now    = GetGameTimer()
    local points = {}
    local clockMs = now + cfg.boardSeconds * 1000

    local function push(x, y, z, speed)
        local prev = points[#points]
        if prev then
            local d = BR.Dist(prev.x, prev.y, x, y)
            clockMs = clockMs + (d / math.max(1.0, speed)) * 1000.0
        end
        points[#points + 1] = { x = x, y = y, z = z, t = math.floor(clockMs) }
    end

    -- Parked, then the ground roll: speed builds 15 -> rollSpeed across the
    -- surveyed runway stretch. Segment speed is the AVERAGE carried across
    -- it, hence the ramp values between samples.
    local rp = cfg.rotatePoint
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

    -- The banked turn: fly the arc in fixed angular steps, steering toward
    -- the chord entry each step (a pursuit arc), until the nose points at
    -- it. Right or left falls out of the geometry; with the runway pointing
    -- out to sea and every anchor to the northwest, it is a right turn.
    local hx, hy = dirX, dirY
    local px = rp.x + dirX * cfg.climbDist
    local py = rp.y + dirY * cfg.climbDist
    local stepRad = math.rad(6.0)
    local stepLen = cfg.turnRadius * stepRad
    for _ = 1, 60 do
        local tx, ty = x1 - px, y1 - py
        local tLen = math.max(1.0, math.sqrt(tx * tx + ty * ty))
        tx, ty = tx / tLen, ty / tLen

        local cross = hx * ty - hy * tx
        local dot   = hx * tx + hy * ty
        if dot > math.cos(math.rad(5.0)) then break end   -- nose on target

        local turn = cross >= 0 and stepRad or -stepRad
        local c, s = math.cos(turn), math.sin(turn)
        hx, hy = hx * c - hy * s, hx * s + hy * c
        px, py = px + hx * stepLen, py + hy * stepLen
        push(px, py, cfg.altitude, cfg.climbSpeed)
    end

    local turnEndT = math.floor(clockMs)

    -- The straight run to the chord entry, accelerating to cruise. Sampled
    -- finely enough that the doors-over-land scan below has real waypoints
    -- to find the coastline with.
    local runSamples = 12
    for i = 1, runSamples do
        local k = i / runSamples
        push(BR.Lerp(px, x1, k), BR.Lerp(py, y1, k), cfg.altitude,
             BR.Lerp(cfg.climbSpeed, cfg.cruiseSpeed, math.min(1.0, k * 1.6)))
    end
    local chordAt = math.floor(clockMs)

    -- The drop chord.
    local chordSamples = 6
    for i = 1, chordSamples do
        local k = i / chordSamples
        push(BR.Lerp(x1, x2, k), BR.Lerp(y1, y2, k), cfg.altitude, cfg.speed)
    end

    -- THE DOORS OPEN AT FIRST LAND, not at the anchor circle. The chord
    -- entry is a geometric boundary that can sit far inland -- riders
    -- watched half the mainland pass with the doors shut, twice. The first
    -- waypoint after the turn that overflies land opens them; the chord
    -- entry is only the latest they can possibly open.
    local jumpFrom = chordAt
    for _, p in ipairs(points) do
        if p.t > turnEndT and p.t < jumpFrom then
            local _, d = BR.Config.Map.NearestPOI(p.x, p.y)
            if d and d <= cfg.landRadius then
                jumpFrom = p.t
                break
            end
        end
    end

    route = {
        points    = points,
        tStart    = points[1].t,
        jumpFrom  = jumpFrom,
        chordAt   = chordAt,
        tEnd      = points[#points].t,
        alt       = cfg.altitude,
        mx = x1, my = y1, ex = x2, ey = y2,
        heading   = sp.heading,
        serverNow = now,
        landScore = best,
    }

    print(('[br_core] bus: %s chord (land %.0f%%), %d waypoints, doors at %.0fs, %.0fs total')
        :format(anchor.name, best * 100, #points,
                (jumpFrom - now) / 1000, (route.tEnd - now) / 1000))

    return (route.tEnd - now) / 1000 + cfg.jumpGrace
end

--- Broadcast the planned route. Separate from plan() so the match can set its
--- own deadline from the return value first.
function BR.Bus.launch()
    if route then
        TriggerClientEvent(BR.Net.BUS_ROUTE, -1, route)
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
    if not entry or entry.state ~= BR.PlayerState.BUS or not route then return end

    local t = math.min(GetGameTimer(), route.tEnd)
    local x, y, z = BR.PathPosAt(route.points, t)

    BR.Roster.setState(src, BR.PlayerState.FREEFALL)
    TriggerClientEvent(BR.Net.BUS_JUMP_OK, src, {
        x = x, y = y, z = z,
        -- GTA heading, not compass bearing -- the client feeds this straight
        -- to SetEntityHeading and its exit-velocity vector.
        heading = BR.GtaHeading(BR.Bearing(route.mx, route.my, route.ex, route.ey)),
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
    if BR.Server.match.state ~= BR.MatchState.BUS or not route then
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
    if BR.Server.match.state ~= BR.MatchState.BUS or not route then return end
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
