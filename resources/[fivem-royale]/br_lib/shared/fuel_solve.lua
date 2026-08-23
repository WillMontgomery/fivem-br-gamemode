-- Fuel arithmetic, with no engine in it.
--
-- Everything here is a function of numbers. The server owns the fuel ledger
-- (br_core/server/fuel.lua) and the client owns the gauge and the pump
-- (br_core/client/fuel.lua); both call into this file, and neither of them can
-- be unit-tested without a running FXServer. This can, which is the same
-- bargain storm_solve.lua and combat_solve.lua strike and the reason they exist
-- as separate files rather than as locals inside their consumers.
--
-- ═══ THE UNIT IS METRES OF GROUND COVERED, AND THAT IS THE OWNER'S CALL ═══
--
--   "Meters would be best as well."   -- owner, 2026-08-21, #195
--
-- Not seconds of engine time. #195's argument for the distance budget, kept
-- here because every function below is written in that unit and a reader
-- arriving from the fuel gauge will expect litres:
--
--   * idling at a POI costs nothing, sitting in a car as cover costs nothing,
--     and a cross-map run costs a tank;
--   * "how far will this take me" is a question a player can answer, and "how
--     many seconds of engine time do I have left" is not;
--   * the server already samples every player's position at 4 Hz
--     (BR.Config.Match.posSampleHz), so distance travelled is a SUBTRACTION on
--     data the server takes anyway. It costs no new loop and no new client
--     message, which is what makes a server-authoritative fuel model affordable
--     at all.
--
-- ═══ METRES ARE THE LEDGER, LITRES ARE THE DIAL ═══
--
-- The owner also asked that the in-vehicle gauge work, which means the number
-- has to reach SET_VEHICLE_FUEL_LEVEL, which is in the vehicle's own tank
-- units. So there are two numbers and exactly one conversion between them,
-- `BR.FuelSolve.tankLevel`. Metres are the truth; litres are a rendering of it.
-- Nothing outside that one function should ever hold a litre.

BR = BR or {}

BR.FuelSolve = {}

--- Clamp a fuel reading into [0, tank].
---
--- SEPARATE FROM BR.Clamp DELIBERATELY, because the failure it guards is not a
--- range error, it is a NaN. `0/0` is a number in Lua, it compares false to
--- everything including itself, and BR.Clamp's `if v < lo` / `if v > hi` pair
--- both answer false for it -- so a NaN passes straight through a clamp and
--- lands in the ledger, where every later subtraction keeps it. One divide by a
--- zero tank is all it takes, and the symptom is a car with a gauge that reads
--- nothing and an engine that never stalls.
--- @param v number|nil
--- @param tank number
--- @return number
function BR.FuelSolve.clamp(v, tank)
    v = tonumber(v)
    tank = tonumber(tank) or 0.0
    if tank < 0.0 then tank = 0.0 end
    -- v ~= v is the NaN test. It is the only one Lua has.
    if v == nil or v ~= v then return 0.0 end
    if v < 0.0 then return 0.0 end
    if v > tank then return tank end
    return v
end

--- How much ground was covered between two samples, and may it be believed?
---
--- ═══ HORIZONTAL DISTANCE ONLY, AND THAT IS A CHOICE RATHER THAN AN OVERSIGHT
---     ═══
---
--- A vehicle that falls 100m off the Chiliad trail has moved 100m in three
--- dimensions and got nowhere, and charging it a hundred metres of fuel for
--- being dropped is the kind of rule players notice and cannot explain. The
--- storm's geometry is 2-D (BR.Dist, BR.InCircle, the whole of geo.lua), the
--- map is described by a 2-D AABB, and the budget is derived from a 2-D
--- diagonal -- so the consumption is 2-D too, and the four numbers agree.
---
--- The cost, stated: a climb up Mount Chiliad is charged as its footprint
--- rather than its road. That undercharges hill roads slightly and nothing
--- else, which is the cheaper of the two errors.
---
--- ═══ THE SPEED CAP IS NOT AN ANTICHEAT, IT IS A TELEPORT FILTER ═══
---
--- The samples come from the server's own GetEntityCoords, so nobody is lying
--- to it. What DOES happen is discontinuity: `/brtp` moves an admin across the
--- map between two samples, a vehicle handle is recycled onto a different car,
--- an entity streams back in somewhere else. Every one of those presents as a
--- single enormous step, and charging it would empty a full tank in one tick.
---
--- So a step that could not have been driven is not drained -- it re-baselines.
--- The cap is deliberately far above any land vehicle in the game (the fastest
--- is around 67 m/s) rather than tuned close to it: a cap that trims real
--- driving is a cap that silently makes fuel free at speed.
---
--- @param x1 number
--- @param y1 number
--- @param x2 number
--- @param y2 number
--- @param dtMs number      milliseconds between the two samples
--- @param maxSpeed number  metres per second above which the step is disbelieved
--- @return number metres   0 when the step is disbelieved
--- @return boolean jumped  true when it was disbelieved
function BR.FuelSolve.travelled(x1, y1, x2, y2, dtMs, maxSpeed)
    local dx = (tonumber(x2) or 0.0) - (tonumber(x1) or 0.0)
    local dy = (tonumber(y2) or 0.0) - (tonumber(y1) or 0.0)
    local d  = math.sqrt(dx * dx + dy * dy)

    -- NaN in, nothing out. Same reasoning as clamp(): a NaN here would be
    -- subtracted from the ledger and stay there forever.
    if d ~= d then return 0.0, true end

    dtMs = tonumber(dtMs) or 0
    maxSpeed = tonumber(maxSpeed) or 0.0
    -- A NON-POSITIVE INTERVAL CANNOT BOUND ANYTHING. Two samples in the same
    -- millisecond give a budget of zero metres, which would disbelieve every
    -- real step; the scheduler can produce that on a stalled tick. Treat it as
    -- "no information" and charge nothing rather than re-baselining on it.
    if dtMs <= 0 or maxSpeed <= 0.0 then return 0.0, false end

    local budget = maxSpeed * (dtMs / 1000.0)
    if d > budget then return 0.0, true end
    return d, false
end

--- Take metres out of a tank.
--- @param left number
--- @param metres number
--- @param tank number
--- @return number
function BR.FuelSolve.drain(left, metres, tank)
    local m = tonumber(metres) or 0.0
    if m ~= m or m < 0.0 then m = 0.0 end
    return BR.FuelSolve.clamp(BR.FuelSolve.clamp(left, tank) - m, tank)
end

--- Put metres back into a tank.
--- @param left number
--- @param metres number
--- @param tank number
--- @return number
function BR.FuelSolve.refill(left, metres, tank)
    local m = tonumber(metres) or 0.0
    if m ~= m or m < 0.0 then m = 0.0 end
    return BR.FuelSolve.clamp(BR.FuelSolve.clamp(left, tank) + m, tank)
end

--- How much fuel a refuel hold has EARNED, in milliseconds of wall clock.
---
--- ═══ THE ONLY THING IN THIS FEATURE THAT ADDS RATHER THAN SUBTRACTS, WHICH IS
---     WHY IT IS BOUNDED BY THE CLOCK AND NOT BY THE MESSAGE ═══
---
--- docs/security.md's ammo rule -- "reports are decrease-only, the worst a liar
--- can do is disarm themselves" -- does not cover refuelling, because
--- refuelling goes the other way. A client holding the interact key sends a
--- repeating request while it holds, and a client that sends that request sixty
--- times a second instead of four must not fill sixty times faster.
---
--- So the grant is a function of ELAPSED TIME since the last accepted grant,
--- capped, and never of how many messages arrived. Spamming buys nothing: the
--- second message in the same millisecond earns zero milliseconds of fuel.
---
--- THE CAP IS WHAT STOPS A PAUSE BECOMING A TANKFUL. Without it, a client that
--- sends one request, waits four minutes at the pump doing nothing, and sends a
--- second, would be granted four minutes of pumping for two messages -- which is
--- exactly the "send start and walk away" hole. Capping the step means a hold
--- has to actually be held: the grant can never exceed one step, so filling a
--- tank takes as many steps as the rate says it does.
---
--- @param lastAtMs number|nil  when this player was last granted fuel
--- @param nowMs number
--- @param maxStepMs number     ceiling on a single grant
--- @return number ms           milliseconds of pumping earned, >= 0
function BR.FuelSolve.grantMs(lastAtMs, nowMs, maxStepMs)
    local now = tonumber(nowMs) or 0
    local cap = tonumber(maxStepMs) or 0
    if cap <= 0 then return 0 end

    local last = tonumber(lastAtMs)
    -- NO PRIOR GRANT IS ONE STEP, NOT ZERO AND NOT EVERYTHING. Zero would make
    -- the first message of every hold worthless, so a player tapping the key
    -- would never start; `now` would make it the whole clock since boot.
    if last == nil then return cap end

    local dt = now - last
    -- A CLOCK THAT WENT BACKWARDS EARNS NOTHING. GetGameTimer does not, but a
    -- record that survived a resource restart alongside a clock that did not is
    -- the same shape, and a negative dt subtracted from a tank would be a fill.
    if dt <= 0 then return 0 end
    if dt > cap then return cap end
    return dt
end

--- The tank reading a fuel gauge wants, from the ledger the server keeps.
---
--- ═══ THE ONE PLACE METRES BECOME LITRES ═══
---
--- SET_VEHICLE_FUEL_LEVEL is in the vehicle's own tank units -- the handling
--- float `fPetrolTankVolume`, which differs per model -- so the fraction is
--- what travels and the volume is applied at the far end. That also means the
--- gauge reads the same on a Sultan and a Bison for the same number of metres
--- left, which is the behaviour the budget wants: the ledger is a range, and a
--- range does not change because the tank is bigger.
---
--- ZERO VOLUME IS ZERO LEVEL AND IS NOT A DIVISION. Bicycles have a zero tank
--- and infinite fuel by construction in GTA; asking for their level is
--- meaningless, and the engine ignores whatever it is told. Answering 0.0 keeps
--- this function total rather than making every caller check first.
---
--- @param left number    metres remaining
--- @param tank number    metres in a full tank
--- @param volume number  the vehicle's fPetrolTankVolume
--- @return number level  0..volume
function BR.FuelSolve.tankLevel(left, tank, volume)
    volume = tonumber(volume) or 0.0
    if volume <= 0.0 then return 0.0 end
    return BR.FuelSolve.fraction(left, tank) * volume
end

--- How full the tank is, 0..1.
--- @param left number
--- @param tank number
--- @return number
function BR.FuelSolve.fraction(left, tank)
    tank = tonumber(tank) or 0.0
    -- AN UNSET OR ZERO TANK READS FULL, NOT EMPTY, and the direction matters.
    -- This is reached when a config is broken or absent, and the two ways to be
    -- wrong are "every vehicle on the map is permanently dry" and "fuel does
    -- nothing". The second is a feature that failed to arrive; the first is a
    -- match nobody can play.
    if tank <= 0.0 then return 1.0 end
    return BR.FuelSolve.clamp(left, tank) / tank
end

--- How many refuelling stops a journey of `distance` needs, starting full.
---
--- ═══ THIS IS THE FUNCTION THE OWNER'S RULE IS WRITTEN IN ═══
---
---   "Our fuel consumption rate should be such that 1 trip across the map
---    should require 2 fuel stops."   -- owner, 2026-08-21, #195
---
--- A journey of D metres on a tank of T, starting full and filling to full at
--- every stop, covers T metres per tankful, so it needs ceil(D/T) tankfuls and
--- therefore ceil(D/T) - 1 stops. Two stops means ceil(D/T) = 3, which means
---
---     D/3 <= T < D/2
---
--- and that BAND, not a single value, is what "two stops" actually pins down.
--- BR.Config.Fuel.tankMetres is chosen inside it and shows its working.
---
--- A JOURNEY SHORTER THAN A TANK NEEDS NO STOPS, and this answers 0 for it
--- rather than -1: ceil(D/T) - 1 is 0 at D = T exactly, and the guard below
--- covers D = 0.
---
--- @param distance number  metres
--- @param tank number      metres in a full tank
--- @return integer stops
function BR.FuelSolve.stopsFor(distance, tank)
    distance = tonumber(distance) or 0.0
    tank = tonumber(tank) or 0.0
    if tank <= 0.0 then return 0 end
    if distance <= 0.0 then return 0 end
    local n = math.ceil(distance / tank) - 1
    if n < 0 then return 0 end
    return n
end

--- The nearest station to a point, if one is close enough to use.
---
--- LINEAR OVER THE WHOLE LIST, ON PURPOSE. There are a few dozen stations and
--- this runs at most once per occupied vehicle per server tick, so a spatial
--- index would be more code than the walk it replaces. The moment the list
--- reaches the hundreds this is the line to revisit.
---
--- @param x number
--- @param y number
--- @param stations table   array of { x, y, ... }
--- @param radius number    metres
--- @return table|nil station
--- @return number dist     distance to it; math.huge when none is in range
function BR.FuelSolve.stationNear(x, y, stations, radius)
    x = tonumber(x); y = tonumber(y)
    radius = tonumber(radius) or 0.0
    if x == nil or y == nil or radius <= 0.0 or type(stations) ~= 'table' then
        return nil, math.huge
    end

    local best, bestD = nil, math.huge
    for i = 1, #stations do
        local s = stations[i]
        local sx, sy = tonumber(s and s.x), tonumber(s and s.y)
        if sx and sy then
            local dx, dy = sx - x, sy - y
            local d2 = dx * dx + dy * dy
            if d2 < bestD then best, bestD = s, d2 end
        end
    end

    if best == nil then return nil, math.huge end
    local d = math.sqrt(bestD)
    if d > radius then return nil, d end
    return best, d
end

--- Is the vehicle close enough to the PUMP for the prompt to be drawn?
---
--- ═══ A SECOND RADIUS, AN ORDER OF MAGNITUDE SMALLER, AND THE OWNER ASKED FOR
---     THE GAP BETWEEN THEM ═══
---
---   "The DUI draws way too far away from the pumps. We need to be like 10ft
---    from the pumps or less."   -- owner, 2026-08-22
---
--- `stationNear` above answers a different question -- MAY THIS VEHICLE REFUEL
--- -- and it is answered against the authored forecourt centre at 30m because
--- the server re-derives it and the server cannot see props. This one answers
--- IS THERE A PLATE ON SCREEN, against the pump prop the client found at
--- runtime, and the two numbers are deliberately not the same.
---
--- WHAT HAPPENS IN THE GAP, STATED PLAINLY: between the prompt radius and the
--- station radius a driver can still refuel and sees nothing telling them so.
--- That is the direction to fail in. Narrowing the REFUEL radius to match would
--- be a behaviour change nobody asked for, and it is not even available: the
--- server owns that test and has no pump coordinates to test against.
---
--- ═══ 2-D, LIKE EVERY OTHER DISTANCE IN THIS FEATURE ═══
---
--- BR.FuelSolve.travelled is 2-D, the storm is 2-D, `stationNear` is 2-D. A
--- forecourt is flat, so the third dimension here would only ever contribute
--- the difference between a pump's origin and a car's -- about a metre of a
--- three-metre budget, spent on nothing.
---
--- @param vx number|nil  the vehicle's x
--- @param vy number|nil  the vehicle's y
--- @param px number|nil  the pump's x -- or the station centre, when no prop
---                       was found; client/fuel.lua passes whichever it has
--- @param py number|nil
--- @param radius number  metres
--- @return boolean inReach
--- @return number dist   metres; math.huge when either point is unreadable
function BR.FuelSolve.atPump(vx, vy, px, py, radius)
    vx, vy = tonumber(vx), tonumber(vy)
    px, py = tonumber(px), tonumber(py)
    if vx == nil or vy == nil or px == nil or py == nil then
        return false, math.huge
    end

    local dx, dy = px - vx, py - vy
    local d = math.sqrt(dx * dx + dy * dy)
    -- NaN IS NOT "CLOSE", AND IT WOULD READ AS CLOSE IF THIS WERE LEFT OUT.
    -- Same argument as clamp(): a NaN compares false to everything, so a
    -- `d > radius` refusal answers false for it and the prompt draws at a
    -- position nothing can render. The distance is reported as infinite rather
    -- than as the NaN, so `/brfuel` prints a number a human can read.
    if d ~= d then return false, math.huge end

    -- A NON-POSITIVE RADIUS DRAWS NOTHING, and the direction is the point. This
    -- is reached when the key is missing or mistyped, and the two ways to be
    -- wrong are "no prompt anywhere" and "the prompt is back at 30m" -- which
    -- is the exact fault being fixed. Fail towards the absence.
    --
    -- THE DISTANCE IS STILL RETURNED. It is what `/brfuel` prints, and a
    -- misconfigured radius is precisely when somebody wants to see it.
    radius = tonumber(radius) or 0.0
    if radius <= 0.0 then return false, d end

    return d <= radius, d
end

-- ═══════════════════════════════════════════════════════════════════════════
-- WHO MAY SEE THE STATION BLIPS, WHICH IS NOT ARITHMETIC AND IS HERE ANYWAY
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The header above says everything here is a function of numbers. This one is a
-- function of tables, and it is in this file for the OTHER half of that header's
-- bargain: br_core/client/fuel.lua cannot be unit-tested. It registers
-- frame-band callbacks and calls a dozen natives at load, and tools/test_fuel.lua
-- reads it as TEXT for exactly that reason. A visibility rule left in the client
-- file would be pinned by grep and by nothing else; here it is executed.
--
-- IT IS SHARED CODE ONLY THE CLIENT CALLS, like stationNear before it. The cost
-- is one function the server never asks for; the gain is that a rule the owner
-- asked for has a truth table.

--- MAY THE OCCUPANT OF THIS SEAT SEE THE GAS STATION BLIPS?
---
--- ═══ THE RULE, IN THE OWNER'S TWO INSTRUCTIONS ═══
---
---   "Also, while in a vehicle (any seat), all gas stations should be shown as
---    blips on the map."                          -- owner, 2026-08-21, #195
---   "passengers should only see gas station blips if the driver is in the same
---    squad."                                     -- owner, 2026-08-22
---
--- THE DRIVER ALWAYS. A PASSENGER ONLY BEHIND A SQUADMATE AT THE WHEEL. A SOLO
--- PASSENGER IN A STRANGER'S CAR SEES NOTHING -- there is no squad in a solo
--- match, so there is no squadmate the driver could be, and the rule resolves
--- without ever asking what kind of match this is.
---
--- PURE, AND IT TAKES ITS INPUTS RATHER THAN READING THEM -- the same shape as
--- BR.Voice.audibleFor, and for the same reason: the suite drives every
--- combination without a game, and without a stub that agrees with the code by
--- construction.
---
--- ═══ WHY THE DRIVER IS A PED AND THE SQUAD IS A ROSTER WALK ═══
---
--- The engine answers "who is in the driver's seat" with a PED, and this client
--- has no way to turn a ped back into a server id. GetPlayerFromServerId and
--- GetPlayerPed are both banned in br_core/client by tools/verify.sh without a
--- marked `-- scope-ok:` exception, no reverse native is in use anywhere in this
--- tree, and a marked exception per feature is how an allowlist rots into a
--- permission -- BR.Squadmates.pedOf's own note makes that argument.
---
--- So the comparison runs the other way. Walk the players the ROSTER says share
--- my squad -- `squadId` is in server/roster.lua's PUBLIC_FIELDS, so it is the
--- SERVER's answer and it is already on this machine -- and ask the one
--- sanctioned resolver whether any of their peds is the ped at the wheel. A
--- squadmate driving the car this player is sitting in is a metre away and
--- therefore certainly streamed, which is the one situation in which pedOf's
--- "0 means out of scope" cannot bite.
---
--- ═══ WHAT IT COSTS, BECAUSE THE OWNER ASKED WHETHER IT WAS A LOT ═══
---
--- It is not, and it is cheaper than the question implies. Called on the 10 Hz
--- TICK band, never per frame, and only while the player is in a vehicle:
---
---   THE DRIVER'S CASE IS THREE COMPARISONS and returns. That is the majority
---   of all ticks, because most people are driving their own car.
---   A PASSENGER WITH NO SQUAD IS ONE MORE. The squadId type test ends it.
---   A PASSENGER WITH A SQUAD walks the roster ONCE -- at most 48 entries in a
---   full match, of which at most three reach a table lookup and a comparison.
---
--- The caller adds exactly one native to the tick, GetPedInVehicleSeat. Nothing
--- is cached, so nothing has to be invalidated when a driver changes seat, bails
--- out or disconnects: the answer is re-derived within 100 ms and no transition
--- has to be enumerated. THE CACHING IS WHAT WOULD HAVE COST SOMETHING, and it
--- is the thing deliberately not being done.
---
--- @param driver integer|nil  the ped in seat -1; 0 or nil when the seat is empty
--- @param ped integer|nil     this player's own ped
--- @param me table|nil        BR.State.me -- `src` and `squadId` are read
--- @param roster table|nil    BR.State.roster; [src] = { squadId = ... }
--- @param pedOf function|nil  server id -> local ped handle, 0 when not streamed
--- @return boolean
function BR.FuelSolve.blipsVisibleTo(driver, ped, me, roster, pedOf)
    -- ZERO IS TESTED EXPLICITLY, TWICE, AND `0` IS TRUTHY IN LUA. These are
    -- ENTITY handles rather than BOOLs, so this is not quite the didHit case --
    -- but it is the same trap wearing different clothes: 0 is what every
    -- entity-returning native answers for "there isn't one". Without these two
    -- lines an empty driver's seat (0) and an unreadable own-ped (0) would
    -- compare EQUAL to each other, and every passenger in a driverless car would
    -- be handed the map by the `driver == ped` test below.
    if not driver or driver == 0 then return false end
    if not ped or ped == 0 then return false end

    -- THE DRIVER, ALWAYS, AND TESTED BEFORE ANYTHING ABOUT SQUADS. That
    -- ordering is what makes the rule hold in a solo match, in a squad that
    -- never formed, and on a client whose roster has not arrived yet -- none of
    -- which the driver should be punished for.
    if driver == ped then return true end

    -- From here this player is a PASSENGER, and the only way through is a
    -- squadmate at the wheel.
    if type(me) ~= 'table' then return false end

    local squad = me.squadId
    -- TYPE-TESTED, NOT TRUTH-TESTED, and that is the line that keeps solos safe.
    -- squadId is a string when it exists and absent otherwise. A truth test
    -- would pass for any non-nil -- and if a future build ever put a number or a
    -- `false` there, every squadless player would match every other squadless
    -- player and a solo lobby would share one "squad" of strangers. Fail towards
    -- no blips.
    if type(squad) ~= 'string' then return false end
    if type(roster) ~= 'table' or type(pedOf) ~= 'function' then return false end

    for src, e in pairs(roster) do
        -- `src ~= me.src` because this player's own row is in the roster and
        -- shares their squadId by definition. Without it a passenger would test
        -- themselves -- harmless today, since pedOf(me.src) could not equal a
        -- driver who is not them, but it is a coincidence rather than a reason
        -- and the next change to pedOf would decide it.
        if src ~= me.src and type(e) == 'table' and e.squadId == squad then
            local p = pedOf(src)
            if p and p ~= 0 and p == driver then return true end
        end
    end
    return false
end
