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
--- Geometry: takeoff roll from the Cayo runway threshold, climb out over the
--- ocean to one end of a chord across the match anchor's circle, then fly
--- the chord slowly -- the jump window is exactly the chord leg. The entry
--- point is whichever chord end is nearer the airstrip, so the bus never
--- overflies Los Santos at cruise speed with the doors shut.
---
--- The chord is the best of several candidates by land coverage: an unscored
--- random chord across a coastal anchor is water-to-water often enough to
--- have actually happened on the first flights.
---
--- @return number  seconds until BUS should hand over to PLAYING
function BR.Bus.plan()
    local cfg = BR.Config.Bus
    local rw  = cfg.runwayStart

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
    end

    -- Enter at the end nearer the airstrip.
    if BR.Dist2(rw.x, rw.y, x2, y2) < BR.Dist2(rw.x, rw.y, x1, y1) then
        x1, y1, x2, y2 = x2, y2, x1, y1
    end

    local now    = GetGameTimer()
    local ocean  = BR.Dist(rw.x, rw.y, x1, y1)
    local chord  = BR.Dist(x1, y1, x2, y2)
    local tStart = now + cfg.boardSeconds * 1000

    route = {
        sx = rw.x,  sy = rw.y,  sz = rw.z,
        mx = x1,    my = y1,
        ex = x2,    ey = y2,
        alt    = cfg.altitude,
        tStart = tStart,
        tMid   = math.floor(tStart + (ocean / cfg.cruiseSpeed) * 1000),
        tEnd   = math.floor(tStart + (ocean / cfg.cruiseSpeed
                                    + chord / cfg.speed) * 1000),
        serverNow = now,
        landScore = best,
    }

    print(('[br_core] bus: %s chord (land %.0f%%), %.0fm ocean + %.0fm drop leg, %.0fs total')
        :format(anchor.name, best * 100, ocean, chord, (route.tEnd - now) / 1000))

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
    local x, y = BR.RoutePosAt(route, t)

    BR.Roster.setState(src, BR.PlayerState.FREEFALL)
    TriggerClientEvent(BR.Net.BUS_JUMP_OK, src, {
        x = x, y = y, z = route.alt,
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
    if GetGameTimer() < route.tMid then
        BR.Server.notify(src, 'Doors are still closed.', 'warn')
        print(('[br_core] bus: jump from %d refused -- doors open in %.1fs')
            :format(src, (route.tMid - GetGameTimer()) / 1000))
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
