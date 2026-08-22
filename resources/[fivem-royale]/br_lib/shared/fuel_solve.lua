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
