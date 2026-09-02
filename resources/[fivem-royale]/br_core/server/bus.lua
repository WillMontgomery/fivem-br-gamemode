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

-- Routes and anchors live ON THE MATCH INSTANCE (m.route, m.anchor): two
-- concurrent matches fly two different tours, and each is published only to
-- its own audience.

--- The active route of a match, or nil.
--- @param m table
function BR.Bus.active(m)
    return m and m.route
end

--- Author this match's flight GEOMETRY and broadcast the preview.
---
--- Called when WARMUP begins, so players spend the warmup looking at the
--- route on the map and arguing about where to drop. One waypoint option is
--- drawn from each authored leg list (4 x 4 x 4 x 3 = 192 flights); corners
--- are filleted into arcs; every point carries the speed the plane holds
--- into it. No timestamps yet -- the wheels do not move until BUS, and
--- depart() stamps the clock then.
--- @param m table
function BR.Bus.plan(m)
    local cfg = BR.Config.Bus

    -- Seeded with the match id folded in: two matches planned in the same
    -- server millisecond (tests, mostly) must not fly identical tours.
    local rng = BR.Rng(GetGameTimer() + m.id * 104729)

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

    -- The storm anchor is picked FROM the tour: a random waypoint of this
    -- flight, then a random POI 500-1500 units off it (band widens where the
    -- route is POI-sparse). The circle tends to land where people actually
    -- dropped, it is always centred on a nameable place, and 192 tours x ~49
    -- POIs never settles into a pattern.
    local poi = BR.PickStormAnchor(rng, waypoints,
        BR.Config.Map.POIs, BR.Config.Storm.anchorBand)
    m.anchor = poi and { x = poi.x, y = poi.y, name = poi.name, poi = poi.id }
        or { x = waypoints[1].x, y = waypoints[1].y, name = 'route' }

    -- ---- build the geometry ------------------------------------------------

    local points = {}   -- { x, y, z, v }: v = speed carried into this point

    local function push(x, y, z, v)
        points[#points + 1] = { x = x, y = y, z = z, v = v }
    end

    -- Parked, then the ground roll: UNIFORM ACCELERATION, sampled at equal
    -- time steps -- position goes with k^2, speed linearly, so the speed
    -- carried into every sample rises by the same small step.
    --
    -- DENSITY IS THE SMOOTHNESS. The path is piecewise LINEAR in position
    -- and speed between samples, and at rolling speeds the old 12 samples
    -- meant each boundary jumped the speed by ~7 m/s -- a +100% lurch on
    -- the first few, which is exactly the "sudden movements between speed
    -- and position" the takeoff was reported for (2026-08-04). 32 samples
    -- cut every step by ~2.7x for the cost of 20 route points.
    local sp, rp = cfg.spawn, cfg.rotatePoint
    push(sp.x, sp.y, sp.z, 1.0)
    local rollSamples = 32
    for i = 1, rollSamples do
        local k = i / rollSamples
        push(BR.Lerp(sp.x, rp.x, k * k), BR.Lerp(sp.y, rp.y, k * k), sp.z,
             math.max(3.0, cfg.rollSpeed * k))
    end
    local rotateIdx = #points   -- wheels-up: the island handoff clocks from here

    -- Wheels up: hold the runway heading, climb to altitude over climbDist.
    local dirX, dirY = rp.x - sp.x, rp.y - sp.y
    local dLen = math.max(1.0, BR.Dist(sp.x, sp.y, rp.x, rp.y))
    dirX, dirY = dirX / dLen, dirY / dLen

    -- Doubled alongside the roll: wheels-up is where speed, elevation AND
    -- pitch all change at once, so the sample boundaries show most there.
    --
    -- SMOOTHERSTEP, not smoothstep: k^2(3-2k) has zero slope at the ends
    -- but its CURVATURE is maximal exactly at k=0 -- the climb rate ramped
    -- hardest in the first seconds off the runway, which read as the nose
    -- yanking up ("too aggressive for the first 2 seconds", live report).
    -- 6k^5-15k^4+10k^3 zeroes the second derivative at both ends too: the
    -- lift builds from nothing, gently, and settles the same way at
    -- altitude.
    local climbSamples = 20
    for i = 1, climbSamples do
        local k = i / climbSamples
        local ease = k * k * k * (k * (k * 6.0 - 15.0) + 10.0)
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

            -- The ocean leg is never slower than the ascent that fed it:
            -- climbing at 270 into a 200 cruise would read as air-braking
            -- for no reason (config documents the same invariant).
            local approachV = (i == 1)
                and math.max(cfg.cruiseSpeed, cfg.climbSpeed) or cfg.speed
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

    local route = {
        points    = points,
        waypoints = waypoints,   -- the authored tour, for the map drawing
        legs      = legs,
        jumpIdx   = jumpIdx or #points,
        closeIdx  = closeIdx or #points,   -- last authored point: doors-closing warning
        rotateIdx = rotateIdx,             -- wheels-up sample index
        alt       = cfg.altitude,
        -- The heading the plane SPAWNS at is the direction it will actually
        -- roll: computed from spawn -> rotate point, not the surveyed value,
        -- which was ~3 degrees off and made the airframe visibly snap
        -- straight as the roll began.
        heading   = BR.GtaHeading(BR.Bearing(sp.x, sp.y, rp.x, rp.y)),
        timed     = false,
    }
    m.route = route

    print(('[br_core] bus: match %d tour %d-%d-%d-%d, %d waypoints, %d path points -- storm homes on %s')
        :format(m.id, legs[1], legs[2], legs[3], legs[4], #waypoints, #points,
                m.anchor.name))

    BR.Broadcast.toMatch(m, BR.Net.BUS_ROUTE, route)
end

--- Stamp the clock onto the planned geometry and broadcast the flight.
--- Called when BUS begins: timestamps accumulate as segment length over the
--- speed carried into each point, so the profile IS the timing.
--- @param m table
--- @return number  seconds until BUS should hand over to PLAYING
function BR.Bus.depart(m)
    local cfg = BR.Config.Bus
    local now = GetGameTimer()
    local route = m.route
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
    route.rotateAt   = pts[route.rotateIdx or 1].t   -- wheels leave the runway
    route.jumpFrom   = pts[route.jumpIdx].t
    route.doorsClose = pts[route.closeIdx].t

    -- ...and WIDEN the window for anything the tour actually flies over. The
    -- authored indices assume every route has the same shape; the zones make
    -- the ports and the airport jumpable whenever the flight crosses them.
    -- Never before wheels-up: LSIA is a zone and the bus takes off from an
    -- airstrip.
    route.jumpFrom, route.doorsClose = BR.BusDoorWindow(
        pts, BR.Config.Map.DoorZones or {},
        route.jumpFrom, route.doorsClose, route.rotateAt)
    route.tEnd       = pts[#pts].t
    route.serverNow  = now

    -- THE AIRBORNE HOP (user call, 2026-08-04): riders stay in the communal
    -- warmup bucket through boarding, the roll and the climb -- that is what
    -- lets everyone still at the airstrip watch the flight leave -- and move
    -- to the match's own bucket a few seconds after wheels-up, out over the
    -- water where nobody can tell. Jumpers hop the moment they jump (their
    -- state change re-derives the bucket); this clock covers everyone else.
    m.airborne = false
    m.hopAt    = route.rotateAt + 3500

    print(('[br_core] bus: match %d departing -- doors at %.0fs, %.0fs total')
        :format(m.id, (route.jumpFrom - now) / 1000, (route.tEnd - now) / 1000))

    BR.Broadcast.toMatch(m, BR.Net.BUS_ROUTE, route)

    -- THE AUDIENCE ON THE TARMAC (user call, 2026-08-04): everyone still at
    -- the communal warmup pad -- other matches' forming players -- gets a
    -- SPECTATOR copy of the timed route, and their clients render a ghost
    -- plane flying it: the departure is a thing you watch, not a group of
    -- peds levitating away. Scoped to WARMUP-state players outside this
    -- match; this match's own riders fly the real (equally local) one.
    BR.Roster.each(
        function(e) return e.matchId ~= m.id
            and e.state == BR.PlayerState.WARMUP end,
        function(src)
            TriggerClientEvent(BR.Net.BUS_SPECTATE, src,
                { matchId = m.id, route = route })
        end)

    return (route.tEnd - now) / 1000 + cfg.jumpGrace
end

--- Late joiners during warmup need the preview the room already has.
--- @param m table
--- @param src integer
function BR.Bus.sendPreview(m, src)
    if m and m.route then
        TriggerClientEvent(BR.Net.BUS_ROUTE, src, m.route)
    end
end

--- @param m table
function BR.Bus.clear(m)
    if m then m.route = nil end
end

--- Put one player out of the bus. The exit point is the bus's position on the
--- route RIGHT NOW by the server's clock -- the client is told where it
--- jumped from, never asked.
--- @param m table
--- @param src integer
--- @param forced boolean|nil
local function eject(m, src, forced)
    local entry = BR.Roster.get(src)
    local route = m and m.route
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
    local m = BR.Server.matchOf(src)
    if not m or m.state ~= BR.MatchState.BUS
       or not m.route or not m.route.timed then
        print(('[br_core] bus: jump from %d refused -- state is %s')
            :format(src, m and m.state or 'no match'))
        return
    end
    if GetGameTimer() < m.route.jumpFrom then
        -- KEYED, WITH THE ACTUAL DEADLINE. Someone who wants out early hits
        -- the key repeatedly, and without identity that is one refusal line
        -- per press stacking up the screen -- while still not answering the
        -- only question they have, which is "how long". One row, counting
        -- itself down, replaced rather than repeated.
        BR.Server.notify(src, 'Doors open in', 'warn',
            { key = 'bus.doors', endsAt = m.route.jumpFrom })
        print(('[br_core] bus: jump from %d refused -- doors open in %.1fs')
            :format(src, (m.route.jumpFrom - GetGameTimer()) / 1000))
        return
    end

    eject(m, src, false)
end)

--- Force out everyone still aboard. The end-of-route job below is the usual
--- caller; the PLAYING transition also calls it, so no path into PLAYING --
--- including brforce mid-flight -- can strand a player in the BUS state,
--- invisible and frozen with the match running around them.
--- @param m table
function BR.Bus.ejectAll(m)
    if not m or not m.route then return end
    BR.Roster.each(
        function(e) return e.matchId == m.id
            and e.state == BR.PlayerState.BUS end,
        function(src) eject(m, src, true) end)
end

-- Nobody rides the bus home. Anyone still aboard when the chord runs out is
-- put out over its end -- the same rule Fortnite applies, and the only thing
-- stopping "hide in the bus" from being a strategy. The same clock runs the
-- airborne hop: once the flight has climbed out, its riders leave the
-- communal warmup bucket for the match's own.
BR.Sched.every(500, 'bus.eject', function()
    BR.Server.eachMatch(function(m)
        if m.state ~= BR.MatchState.BUS
           or not m.route or not m.route.timed then return end

        local now = GetGameTimer()
        if not m.airborne and m.hopAt and now >= m.hopAt then
            m.airborne = true
            local moved = 0
            BR.Roster.each(
                function(e) return e.matchId == m.id
                    and e.state == BR.PlayerState.BUS end,
                function(src)
                    BR.Roster.rebucket(src)
                    moved = moved + 1
                end)
            print(('[br_core] bus: match %d airborne -- %d rider(s) moved to bucket %d')
                :format(m.id, moved, m.bucket))
        end

        if now < m.route.tEnd then return end
        BR.Bus.ejectAll(m)
    end)
end)

--- Tell whoever is already down that the match is waiting on the others.
---
--- DRIVEN OFF THE MATCH TICK, not off the landing report. The first version
--- hung this on DROP_LANDED, which meant it only fired if that event arrived
--- and if the state flip happened in the same instant -- and the landing
--- report is the single most historically unreliable message in this project
--- (the stuck-lander promotion exists because it goes missing). Polling the
--- roster instead means every path into ALIVE gets the notice, including the
--- promotion itself.
---
--- Once per player per flight; the latch is cleared at BUS entry.
--- @param m table
--- Withdraw the `bus.landing` notice -- the one that says the match will start
--- once all players have landed.
---
--- NAMED BY ITS KEY RATHER THAN BY ITS SENTENCE, deliberately. The wording has
--- changed twice at the owner's request and both times left comments elsewhere
--- quoting a string that no longer existed; `bus.landing` is what the code
--- actually matches on, here and in tools/test_roster.lua.
---
--- A STICKY NOTICE NEEDS A SECOND CALLER, and forgetting it is the whole risk
--- of the sticky flag. landingNotices only runs during BUS, so it cannot be
--- the thing that clears a notice at the moment the flight ENDS -- which is
--- precisely the moment the wait is over. PLAYING calls this too. The store's
--- STICKY_MAX_MS is the last resort behind both, not the plan.
--- @param m table
function BR.Bus.clearLandingNotices(m)
    BR.Roster.each(
        function(e) return e.matchId == m.id and e.landNotice end,
        function(src, e)
            e.landNotice = nil
            BR.Server.notifyClear(src, 'bus.landing')
        end)
end

function BR.Bus.landingNotices(m)
    if m.state ~= BR.MatchState.BUS then return end

    local airborne = BR.Server.countIn(m, function(e)
        return e.state == BR.PlayerState.FREEFALL
            or e.state == BR.PlayerState.GLIDE
            or e.state == BR.PlayerState.BUS
    end)

    -- THE ALL-CLEAR IS AS IMPORTANT AS THE WARNING, and it is the half this
    -- never had. This notice used to be a four-second toast: by the time it
    -- mattered it was gone, and there was no moment at which the player was
    -- told the wait was over. It is a STICKY notice now -- state, not an event
    -- -- and it is withdrawn the instant the sky is empty. THE STICKINESS IS
    -- THE PART THAT MATTERS AND IT SURVIVED THE REWORDING BELOW; only the
    -- sentence went back.
    if airborne <= 0 then
        BR.Bus.clearLandingNotices(m)
        return
    end

    BR.Roster.each(
        function(e) return e.matchId == m.id
            and e.state == BR.PlayerState.ALIVE and not e.landNotice end,
        function(src, e)
            e.landNotice = true
            -- THE OWNER'S SENTENCE, VERBATIM, TRAILING FULL STOP AND ALL:
            --
            --   'Let''s change the "Waiting for other players to land"
            --    notification to say "The match will start once all players
            --    have landed."'                        -- owner, 2026-08-22
            --
            -- WHAT WAS ACTUALLY ON SCREEN WAS 'Waiting for the last players to
            -- land' -- close to the quoted phrase but not it, and worth writing
            -- down because the wording has now been round trip: this exact
            -- sentence shipped first, was replaced when the notice became
            -- sticky, and is the one being asked for back. Only the WORDS
            -- returned; the sticky flag, the dedup key and the withdrawal above
            -- are the reason the old four-second version was replaced and they
            -- all stay.
            BR.Server.notify(src,
                'The match will start once all players have landed.', 'info',
                { key = 'bus.landing', sticky = true })
            print(('[br_core] landing notice -> %s (%d): %d still airborne')
                :format(e.name, src, airborne))
        end)
end

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

        -- Empty by design, but the config field is real and this is the one
        -- moment it means anything.
        if BR.Inv and BR.Inv.grantStarting then BR.Inv.grantStarting(src) end

        -- A few crates out at the edge of where they can see. Landing in
        -- empty countryside and finding nothing is how a player concludes
        -- the mode has no loot in it.
        if BR.Loot and BR.Loot.landingCrates then BR.Loot.landingCrates(src) end

        -- The "waiting on the others" notice is NOT sent from here -- see
        -- BR.Bus.landingNotices, driven off the match tick. Hooking it to this
        -- event meant it depended on the landing report arriving at all, and
        -- the report has a documented history of going missing (the
        -- stuck-lander promotion exists precisely because of it).
    else
        -- Refusals are AUDIBLE (the jump handler's rule, applied here after
        -- a landing report vanished into this branch untraced). ALIVE is the
        -- benign duplicate; BUS means the server never registered the jump
        -- at all, which is the lead worth having in the log.
        print(('[br_core] bus: landing report from %s (%d) ignored -- state is %s')
            :format(entry.name, src, tostring(entry.state)))
    end
end)
