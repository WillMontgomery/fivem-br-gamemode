-- The Season 2 jerry can (#217): the shared rules. One spelling of how much a
-- can holds, how much a press pours and for how long, how much should be in the
-- tank by now, what the can holds after it, the crate's roll, whether a
-- pourer stands at a vehicle, and which of a vehicle's bones is its gas cap --
-- for the server, the client and the suites.
--
-- PURE, AND EVERY THRESHOLD CAN BE AN ARGUMENT. Nothing here reads a config at
-- load or touches a native or a global: `J` is BR.Config.Fuel.jerryCan and the
-- tank is BR.Config.Fuel.tankMetres, each read AT CALL TIME when the caller
-- passes nil, so tools/test_jerrycan.lua can drive numbers no shipped config
-- holds. Every number argument goes through tonumber, and a number that is not
-- finite -- a NaN, an infinity -- reads as no number at all.
--
-- ═══ THE CAN HOLDS A FILL, AND THE FILL IS THE WHOLE ANTI-FARM RULE ═══
--
--   "partial use of a can should be possible."  -- owner, 2026-11-02
--
-- A can stack carries `fill`, the fraction of ONE CAN still in it, 0..1, on
-- the slot like a gun's clip. Absent is full. A pour moves fuel out of the can
-- and into the tank, and fillAfter is the only formula that writes what is
-- left -- from the fill the pour started with and the meters the ledger says
-- it really took -- so the meters a can delivers, counted in cans, and the
-- fill left in it always sum to one. No run of presses and interruptions, no
-- drop, death box or hand-off, gets more out of a can than it holds, and an
-- interrupted pour needs no refund: it keeps what it poured, and the can keeps
-- the rest.

BR = BR or {}
BR.JerryCanSolve = BR.JerryCanSolve or {}

local JS = BR.JerryCanSolve

--- The can's own stream for its crate roll: #217's number in the salt
--- BR.TerminalSolve.extraRoll folds in, where the Yubikey's is #396's. A
--- different salt is an independent roll, so a can and a key turn up in a
--- crate apart and together at the rates their own chances say.
JS.CRATE_SALT = 217

--- A finite number, or nil.
--- @param v any
--- @return number|nil
local function num(v)
    v = tonumber(v)
    if v == nil or v ~= v or v == math.huge or v == -math.huge then return nil end
    return v
end

--- BR.Config.Fuel.jerryCan, or the table the caller passed.
--- @param J table|nil
--- @return table
local function cfg(J)
    if type(J) == 'table' then return J end
    local F = BR.Config and BR.Config.Fuel
    return (F and type(F.jerryCan) == 'table') and F.jerryCan or {}
end

--- An argument, or the config's number when the caller passed nil.
---
--- NIL IS "USE THE CONFIG"; ANYTHING ELSE IS TAKEN AT ITS WORD, so a number
--- that is not finite stays invalid rather than quietly becoming the shipped
--- value -- each caller fails closed on it.
--- @param v any
--- @param fallback any  the config's value
--- @return number|nil
local function argOr(v, fallback)
    if v == nil then return num(fallback) end
    return num(v)
end

--- @param v number
--- @return number  v brought into 0..1
local function unit(v)
    if v < 0.0 then return 0.0 end
    if v > 1.0 then return 1.0 end
    return v
end

-- ------------------------------------------------------------ the can ---

--- A can stack's fill, 0..1.
---
--- NIL OR NOT A NUMBER READS 1: A CAN IS FULL UNTIL POURED. A can out of a
--- crate carries `fill = 1`, and one given by a dev verb (`brgive`) carries
--- none -- both are a whole can, so neither path has to remember to write it.
--- @param stack table|nil
--- @return number
function JS.fillOf(stack)
    local f = (type(stack) == 'table') and num(stack.fill) or nil
    if f == nil then return 1.0 end
    return unit(f)
end

--- Is a can with this fill empty -- at or below J.emptyBelow (1e-6 of a can)?
--- An empty can leaves its slot. A fill that is not a number is not empty: it
--- reads as a whole can (fillOf).
--- @param fill number
--- @param J table|nil
--- @return boolean
function JS.empty(fill, J)
    local f = num(fill)
    if f == nil then return false end
    return f <= (num(cfg(J).emptyBelow) or 1e-6)
end

--- Meters one FULL can is worth in this vehicle.
---
--- `tankMeters` WHOLE FOR A `jerryFills` ROW -- the owner's 26, the game's
--- quads, dirt bikes and dune buggies (config/vehicle_models.lua) -- and
--- `canFraction` of it for everything else, an add-on with no row included.
--- Callers pass F.tankMetres, the ledger's one tank; nil reads it.
--- @param row table|nil         the vehicle's config/vehicle_models.lua row
--- @param tankMeters number|nil
--- @param canFraction number|nil  nil reads J.canFraction
--- @return number  0 when either number is missing
function JS.perCan(row, tankMeters, canFraction)
    local F = BR.Config and BR.Config.Fuel
    local tank = argOr(tankMeters, F and F.tankMetres)
    if tank == nil or tank <= 0.0 then return 0.0 end
    if type(row) == 'table' and row.jerryFills == true then return tank end
    local frac = argOr(canFraction, cfg().canFraction)
    if frac == nil or frac <= 0.0 then return 0.0 end
    return frac * tank
end

--- The plan for one press: how many meters this can pours, and for how long.
---
---   meters = min(fill * perCan, space)
---   ms     = max(minPourMs, floor(meters / perCan * useMs + 0.5))
---
--- So a press pours what the can holds or what the tank has room for, whichever
--- is less, and a partial pour takes its share of a full can's `useMs`: a car
--- at 90% takes 750 m in two seconds and the can keeps 0.6 of itself.
---
--- A FILL ABOVE ONE IS ONE: nothing writes one, and a can never holds more
--- than a can.
--- @param fill number      the can's (fillOf)
--- @param space number     meters of room in the tank (BR.Fuel.space)
--- @param perCan number    meters a full can is worth here (perCan)
--- @param useMs number|nil  a full can's pour; nil reads BR.Config.JerryCan's
--- @param minPourMs number|nil  nil reads J.minPourMs
--- @return number|nil meters  nil when fill, space or perCan is not a positive
---                            number, or nothing would pour
--- @return integer|nil ms
function JS.plan(fill, space, perCan, useMs, minPourMs)
    local f, room, per = num(fill), num(space), num(perCan)
    if f == nil or f <= 0.0 or room == nil or room <= 0.0
       or per == nil or per <= 0.0 then
        return nil, nil
    end
    if f > 1.0 then f = 1.0 end
    local meters = math.min(f * per, room)
    if not (meters > 0.0) then return nil, nil end
    local row = BR.Config and BR.Config.JerryCan
    local full = argOr(useMs, row and row.useMs) or 0.0
    local floorMs = argOr(minPourMs, cfg().minPourMs) or 0.0
    local ms = math.max(floorMs, math.floor(meters / per * full + 0.5))
    return meters, math.tointeger(ms) or math.floor(ms)
end

--- Meters that should be in the tank by now, `elapsedMs` after the press.
---
--- 0 WHILE `elapsedMs` < `settleMs` -- the settle window, in which nothing
--- pours and nothing freezes -- and from then the elapsed share of the plan,
--- min(1, elapsedMs / ms) * meters, so the first slice after the window pays
--- for the window too. NEVER DECREASES as `elapsedMs` grows, which is what lets
--- each slice be the difference between this and what has already poured:
--- the slices telescope to `meters` and nothing is paid twice. `ms` <= 0
--- reads as done.
--- @param elapsedMs number
--- @param ms number
--- @param meters number
--- @param settleMs number|nil  nil reads J.settleMs
--- @return number
function JS.target(elapsedMs, ms, meters, settleMs)
    local e, m = num(elapsedMs), num(meters)
    if e == nil or m == nil or m <= 0.0 then return 0.0 end
    local settle = argOr(settleMs, cfg().settleMs) or 0.0
    if e < settle then return 0.0 end
    local total = num(ms)
    if total == nil or total <= 0.0 then return m end
    return unit(e / total) * m
end

--- What is left in a can after a pour: clamp(fill0 - poured / perCan, 0, 1).
---
--- THE ONLY FORMULA THAT WRITES A CAN'S FILL. `poured` is the sum of what
--- BR.Fuel.pour said it really added, so the can loses exactly what the tank
--- gained, counted in cans. It never rises: a negative or missing `poured`
--- takes nothing out and puts nothing back, and with no `perCan` nothing can
--- have poured at all (plan refused it).
--- @param fill0 number   the can's fill when the pour began
--- @param poured number  meters the pour has put in the tank
--- @param perCan number
--- @return number
function JS.fillAfter(fill0, poured, perCan)
    local f0 = num(fill0)
    if f0 == nil then f0 = 1.0 end
    f0 = unit(f0)
    local p, per = num(poured), num(perCan)
    if p == nil or p <= 0.0 or per == nil or per <= 0.0 then return f0 end
    return unit(f0 - p / per)
end

--- Does this match crate hold a can as it opens?
---
--- BR.TerminalSolve.extraRoll with the can's own salt -- the Yubikey's roll,
--- on a stream of its own, so nothing else in the crate moves and the same
--- pinned seed replays the same cans. Reads BR.TerminalSolve at call time.
--- @param layoutSeed integer|nil  the match's loot seed
--- @param containerId integer|nil
--- @param chance number|nil  nil reads J.crateChance
--- @return boolean
function JS.crateRoll(layoutSeed, containerId, chance)
    if chance == nil then chance = cfg().crateChance end
    return BR.TerminalSolve.extraRoll(layoutSeed, containerId, chance, JS.CRATE_SALT)
end

-- -------------------------------------------------------- the vehicle ---

--- A point in the vehicle's own frame.
---
--- THE FORWARD VECTOR IS (-sin h, cos h) AND THE RIGHT IS (cos h, sin h), the
--- convention shared/ambheal_solve.lua writes down for the back of an
--- ambulance: GTA's heading is degrees counter-clockwise from north. So with
--- d = (px - vx, py - vy):
---
---   lx = right . d     how far to the vehicle's right
---   ly = forward . d   how far ahead of its origin; behind is negative
--- @return number|nil lx  nil when any number is missing
--- @return number|nil ly
function JS.toLocal(px, py, vx, vy, headingDeg)
    px, py, vx, vy = num(px), num(py), num(vx), num(vy)
    local h = num(headingDeg)
    if px == nil or py == nil or vx == nil or vy == nil or h == nil then
        return nil, nil
    end
    local dx, dy = px - vx, py - vy
    local rad = math.rad(h)
    local s, c = math.sin(rad), math.cos(rad)
    return c * dx + s * dy, -s * dx + c * dy
end

--- The row's three sizes, when it has all three as numbers.
--- @param row table|nil
--- @return number|nil reach, number|nil front, number|nil rear
local function sizesOf(row)
    if type(row) ~= 'table' then return nil end
    local reach, front, rear = num(row.reach), num(row.front), num(row.rear)
    if reach == nil or front == nil or rear == nil then return nil end
    return reach, front, rear
end

--- Is the pourer at this vehicle? THE SERVER'S BOUND.
---
--- The server cannot read a bone, so "at the gas cap" is bounded by what it
--- can read: the vehicle's footprint, in its own frame, grown on every side by
--- J.boxMargin (the client's 1.5 m reach plus half a meter of sync slack).
---
---   |pz - vz| > J.riseMeters                    false, 'rise'
---   a row with reach, front and rear:           |lx| <= reach + m and
---                                                -(rear + m) <= ly <= front + m
---                                                 -> true, else false, 'box'
---   no row, or a row without all three sizes:   2D distance <= fallbackRadius
---                                                 -> true, else false, 'radius'
---
--- A POSITION OR A HEADING THAT IS NOT A NUMBER IS NOT AT THE CAP ('nopos'):
--- the bound fails closed.
---
--- WHAT IT COSTS, STATED: a modified client can pour from anywhere inside that
--- box rather than at the cap -- still standing still, still one can's worth,
--- still a car in its own match.
--- @param row table|nil  config/vehicle_models.lua's row (BR.Vehicles.modelRowOf)
--- @param J table|nil
--- @param fallbackRadius number|nil  nil reads BR.Config.Fuel.askRadius
--- @return boolean
--- @return string|nil why
function JS.atCap(px, py, pz, vx, vy, vz, headingDeg, row, J, fallbackRadius)
    J = cfg(J)
    px, py, pz = num(px), num(py), num(pz)
    vx, vy, vz = num(vx), num(vy), num(vz)
    if px == nil or py == nil or pz == nil or vx == nil or vy == nil or vz == nil then
        return false, 'nopos'
    end
    if math.abs(pz - vz) > (num(J.riseMeters) or 0.0) then return false, 'rise' end

    local reach, front, rear = sizesOf(row)
    if reach ~= nil then
        local lx, ly = JS.toLocal(px, py, vx, vy, headingDeg)
        if lx == nil then return false, 'nopos' end
        local m = num(J.boxMargin) or 0.0
        if math.abs(lx) <= reach + m and ly >= -(rear + m) and ly <= front + m then
            return true, nil
        end
        return false, 'box'
    end

    local F = BR.Config and BR.Config.Fuel
    local r = argOr(fallbackRadius, F and F.askRadius) or 0.0
    local dx, dy = px - vx, py - vy
    if math.sqrt(dx * dx + dy * dy) <= r then return true, nil end
    return false, 'radius'
end

--- Has (x, y) moved more than `limit` from (x0, y0), in 2D? A position or a
--- limit that is not a number has: the test fails closed.
--- @return boolean
function JS.drifted(x0, y0, x, y, limit)
    x0, y0, x, y, limit = num(x0), num(y0), num(x), num(y), num(limit)
    if x0 == nil or y0 == nil or x == nil or y == nil or limit == nil then return true end
    local dx, dy = x - x0, y - y0
    return math.sqrt(dx * dx + dy * dy) > limit
end

-- --------------------------------------------- the cap, on the client ---

--- Which bones to measure on one vehicle.
---
--- Every name in J.capBones, in config order, that the model has; with none of
--- those, every name in J.wheelBones it has; otherwise none, and a vehicle with
--- none is not a target. `has(name)` answers whether the model has that bone --
--- on the client, GetEntityBoneIndexByName(veh, name) ~= -1, because bone 0 is a
--- real bone -- and anything but `true` reads as no.
---
--- A CAP BONE ALWAYS BEATS A NEARER REAR WHEEL: wheels are never offered for a
--- model that has a cap bone, so nearestAnchor never sees them.
--- @param has fun(name: string): boolean
--- @param J table|nil
--- @return string[]
function JS.anchorBones(has, J)
    J = cfg(J)
    local out = {}
    if type(has) ~= 'function' then return out end
    for _, name in ipairs(J.capBones or {}) do
        if has(name) == true then out[#out + 1] = name end
    end
    if #out > 0 then return out end
    for _, name in ipairs(J.wheelBones or {}) do
        if has(name) == true then out[#out + 1] = name end
    end
    return out
end

--- The nearest anchor in reach.
---
--- Of `anchors` -- each { x, y, z, ... } -- keep those within `reach` in 2D
--- and `rise` in height of (px, py, pz), and return the one with the least 2D
--- distance, and that distance. TIES GO TO THE EARLIER ANCHOR in the list.
--- Extra fields on an anchor are carried through untouched, so the caller
--- gets back its own vehicle and bone.
--- @param anchors table[]
--- @param reach number|nil  nil reads J.capReach
--- @param rise number|nil   nil reads J.capRise
--- @return table|nil anchor
--- @return number|nil dist
function JS.nearestAnchor(anchors, px, py, pz, reach, rise)
    if type(anchors) ~= 'table' then return nil, nil end
    px, py, pz = num(px), num(py), num(pz)
    if px == nil or py == nil or pz == nil then return nil, nil end
    local J = cfg()
    local r = argOr(reach, J.capReach) or 0.0
    local up = argOr(rise, J.capRise) or 0.0

    local best, bestD = nil, nil
    for _, a in ipairs(anchors) do
        local t = type(a)
        if t == 'table' or t == 'vector3' then
            local ax, ay, az = num(a.x), num(a.y), num(a.z)
            if ax ~= nil and ay ~= nil and az ~= nil then
                local dx, dy = ax - px, ay - py
                local d = math.sqrt(dx * dx + dy * dy)
                if d <= r and math.abs(az - pz) <= up and (bestD == nil or d < bestD) then
                    best, bestD = a, d
                end
            end
        end
    end
    return best, bestD
end
