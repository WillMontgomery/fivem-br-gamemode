-- Unit tests for the fuel model: the solver, the derived tank size, and the
-- server-side ledger.
--
-- ═══ WHY THIS IS ITS OWN SUITE ═══
--
-- The arithmetic half could live in test_shared and the server half in
-- test_roster, and splitting them across two files is exactly what would make
-- the interesting property untestable. The interesting property is not "does
-- drain() subtract" -- it is THE TANK SURVIVES ITS DRIVER, which needs the
-- solver, the config's derived numbers and the registry in one place, driven
-- through the real scheduler.
--
-- ═══ THE ROSTER IS A STUB HERE, DELIBERATELY, AND THIS IS THE ONE PLACE THIS
--     SUITE COMPROMISES ═══
--
-- tools/test_roster.lua loads the real roster and eleven server files with it.
-- server/fuel.lua touches four things on a roster entry -- state, matchId, ped
-- and pos -- and nothing else, so this stands a four-field fake in front of it
-- rather than pulling in the match state machine to reach a subtraction. The
-- cost is real and is worth naming: if a roster entry ever stops carrying
-- `ped`, this suite passes and the game stops consuming fuel. The mitigation is
-- that `ped` is sampled in the same function this file's sampler was written
-- against, and test_roster pins that.

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetConvar(_, d) return d end
function GetCurrentResourceName() return 'br_core' end
function RegisterNetEvent() end

local commands = {}
function RegisterCommand(name, fn) commands[name] = fn end

-- ---------------------------------------------------------------------------
-- The world
-- ---------------------------------------------------------------------------
--
-- ENTITY HANDLES AND NETWORK IDS ARE DELIBERATELY DIFFERENT NUMBERS. The
-- temptation is to make NetworkGetNetworkIdFromEntity the identity function,
-- which is what tools/test_roster.lua does for peds -- and here it would hide
-- the single most likely bug in the file under test: keying the registry on an
-- entity handle instead of a network id. Handles are per-machine and network
-- ids are not, so the two must never be confused, and a harness that cannot
-- tell them apart cannot notice.

local peds     = {}   -- [src] = ped handle
local pedVeh   = {}   -- [ped] = vehicle handle (0 = on foot)
local vehSeat  = {}   -- [veh] = { [-1] = ped, ... }
local coords   = {}   -- [entity] = { x, y, z }
local netOfEnt = {}   -- [entity] = netId
local entOfNet = {}   -- [netId]  = entity
local exists   = {}   -- [entity] = true

function GetPlayerPed(src) return peds[tonumber(src)] or 0 end
function GetEntityCoords(e) return coords[e] or { x = 0.0, y = 0.0, z = 0.0 } end
function GetVehiclePedIsIn(ped) return pedVeh[ped] or 0 end
function GetPedInVehicleSeat(veh, seat) return (vehSeat[veh] or {})[seat] or 0 end
function NetworkGetNetworkIdFromEntity(e) return netOfEnt[e] or 0 end
function NetworkGetEntityFromNetworkId(n) return entOfNet[n] or 0 end
-- ANSWERS A NUMBER, NOT A BOOLEAN, ON PURPOSE. This is the build shape that
-- makes `0` truthy bite -- the bug this project has shipped four times -- so the
-- harness produces it and the file under test has to normalise.
function DoesEntityExist(e) return exists[e] and 1 or 0 end

--- Put a vehicle in the world with a network id and a driver's seat.
local function makeVehicle(entity, netId, x, y)
    netOfEnt[entity] = netId
    entOfNet[netId]  = entity
    exists[entity]   = true
    coords[entity]   = { x = x, y = y, z = 30.0 }
    vehSeat[entity]  = {}
    return entity
end

--- Put a player in the world, on foot.
local function makePlayer(src, ped)
    peds[src]   = ped
    exists[ped] = true
    coords[ped] = { x = 0.0, y = 0.0, z = 30.0 }
    pedVeh[ped] = 0
end

--- Seat a player in a vehicle. `seat` is -1 for the driver.
local function seat(src, entity, seatIdx)
    local ped = peds[src]
    pedVeh[ped] = entity
    vehSeat[entity] = vehSeat[entity] or {}
    vehSeat[entity][seatIdx] = ped
end

local function unseat(src, entity)
    local ped = peds[src]
    pedVeh[ped] = 0
    for k, v in pairs(vehSeat[entity] or {}) do
        if v == ped then vehSeat[entity][k] = nil end
    end
end

--- Move a vehicle, which is what actually spends fuel.
local function moveVehicle(entity, x, y)
    coords[entity] = { x = x, y = y, z = 30.0 }
end

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

local sent = {}
function TriggerClientEvent(event, target, ...)
    sent[#sent + 1] = { event = event, target = target, args = { ... } }
end
function TriggerEvent() end

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
local function fire(name, src, ...)
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

--- The last FUEL_SET a player was sent, or nil.
local function lastSet(src)
    local out
    for _, s in ipairs(sent) do
        if s.event == BR.Net.FUEL_SET and s.target == src then out = s.args[1] end
    end
    return out
end

local realPrint = print
function print() end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

-- ---------------------------------------------------------------------------
-- A four-field roster
-- ---------------------------------------------------------------------------

BR = BR or {}

local ROOT = 'resources/[fivem-royale]/'
local function load(f)
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

for _, f in ipairs({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/geo.lua',
    'br_lib/shared/sched.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    -- config/fuel.lua reads BR.Config.Storm.mapAABB at LOAD time to derive the
    -- map diagonal the tank size is justified against, so storm must precede
    -- it -- exactly as br_core's fxmanifest orders the pair.
    'br_lib/config/fuel.lua',
    'br_lib/shared/fuel_solve.lua',
}) do load(f) end

-- The roster fake. Four fields, and the header says why.
local roster = {}
BR.Roster = {
    get = function(src) return roster[src] end,
    each = function(pred, fn)
        for src, e in pairs(roster) do
            if not pred or pred(e) then fn(src, e) end
        end
    end,
    sampleIntervalMs = function() return 250 end,
}

--- Enrol a player as ALIVE in a match, with a ped the sampler can read.
local function enrol(src, ped, matchId)
    makePlayer(src, ped)
    roster[src] = {
        state = BR.PlayerState.ALIVE,
        matchId = matchId or 1,
        ped = ped,
        pos = { x = 0.0, y = 0.0, z = 30.0 },
    }
end

load('br_core/server/fuel.lua')

-- ---------------------------------------------------------------------------

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end
local function near(a, b, eps)
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= (eps or 0.001)
end

local function reset()
    -- ═══ THE CLOCK NEVER GOES BACKWARDS, AND THE FIRST DRAFT REWOUND IT ═══
    --
    -- This said `fakeTime = 1000`, and it produced a failure that looked exactly
    -- like a bug in the ledger. BR.Sched keeps each job's own `lastRun` in its
    -- own state and nothing in this file resets it -- so rewinding the clock
    -- left every job scheduled in the future, and the sampler SILENTLY DID NOT
    -- RUN until wall time caught back up. A block that drove 5,900m lost its
    -- first six samples to it and came out 150m rich, with nothing anywhere
    -- saying a pass had been skipped.
    --
    -- Jumping FORWARD is both safe and closer to reality: it is shorter than
    -- BR.Config.Fuel.idleTtlMs, and BR.Fuel.reset() has already emptied the
    -- registry the TTL would have swept.
    fakeTime = fakeTime + 60000
    peds, pedVeh, vehSeat, coords = {}, {}, {}, {}
    netOfEnt, entOfNet, exists = {}, {}, {}
    roster = {}
    sent = {}
    BR.Fuel.reset()
end

--- Advance the clock and run the scheduler, one sample interval at a time.
local function tick(times)
    for _ = 1, (times or 1) do
        fakeTime = fakeTime + 250
        BR.Sched.step(fakeTime)
    end
end

--- Drive a vehicle `metres` along +x, in steps the sampler will believe.
---
--- THE STEP SIZE IS NOT ARBITRARY AND GETTING IT WRONG COST THE FIRST DRAFT OF
--- THIS SUITE. BR.FuelSolve.travelled disbelieves any step faster than
--- maxSpeedMps, which at 120 m/s over a 250ms sample is a 30m budget -- so
--- `moveVehicle(veh, 5900, 0)` followed by one tick is a TELEPORT, charges
--- nothing, and every assertion downstream reads a full tank and blames the
--- ledger. 25m per tick is 100 m/s, comfortably inside the cap and faster than
--- any car in the game, so a test drive is quick without being a jump.
local function drive(entity, metres)
    local step = 25.0
    local y = coords[entity].y
    local done = 0.0
    while done < metres - 0.0001 do
        local d = math.min(step, metres - done)
        moveVehicle(entity, coords[entity].x + d, y)
        tick()
        done = done + d
    end
end

local TANK = BR.Config.Fuel.tankMetres

-- ═══════════════════════════════════════════════════════════════════════════
describe('solve.clamp')
-- ═══════════════════════════════════════════════════════════════════════════
do
    ok(BR.FuelSolve.clamp(50, 100) == 50, 'a value in range is itself')
    ok(BR.FuelSolve.clamp(-5, 100) == 0, 'below zero clamps to empty')
    ok(BR.FuelSolve.clamp(500, 100) == 100, 'above the tank clamps to full')
    ok(BR.FuelSolve.clamp(nil, 100) == 0, 'nil is empty rather than an error')
    -- THE ONE THIS FUNCTION EXISTS FOR. BR.Clamp lets a NaN straight through
    -- because every comparison against it is false; a NaN in the ledger is
    -- permanent, and its symptom is a car that never runs out.
    ok(BR.FuelSolve.clamp(0 / 0, 100) == 0, 'a NaN is empty, not a NaN')
    ok(BR.FuelSolve.clamp(50, -1) == 0, 'a negative tank holds nothing')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('solve.travelled')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local m, jumped = BR.FuelSolve.travelled(0, 0, 30, 40, 250, 1000)
    ok(near(m, 50) and not jumped, 'a 3-4-5 step measures 50m', m)

    -- HORIZONTAL ONLY: there is no z parameter at all, which is the point.
    -- A car dropped off a cliff moves a long way and gets nowhere.

    -- 250ms at 120 m/s is a 30m budget.
    m, jumped = BR.FuelSolve.travelled(0, 0, 29, 0, 250, 120)
    ok(near(m, 29) and not jumped, 'a step inside the budget is charged', m)
    m, jumped = BR.FuelSolve.travelled(0, 0, 31, 0, 250, 120)
    ok(m == 0 and jumped, 'a step outside it is disbelieved, not charged', m)

    -- A TELEPORT IS THE CASE THIS EXISTS FOR.
    m, jumped = BR.FuelSolve.travelled(0, 0, 5000, 5000, 250, 120)
    ok(m == 0 and jumped, 'a cross-map jump charges nothing')

    -- A zero interval carries no information and must not be read as a jump:
    -- re-baselining on it would lose the ground covered since the last sample.
    m, jumped = BR.FuelSolve.travelled(0, 0, 10, 0, 0, 120)
    ok(m == 0 and not jumped, 'a zero interval charges nothing and is not a jump')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('solve.drain and refill')
-- ═══════════════════════════════════════════════════════════════════════════
do
    ok(BR.FuelSolve.drain(100, 30, 100) == 70, 'draining subtracts')
    ok(BR.FuelSolve.drain(100, 300, 100) == 0, 'you cannot go past empty')
    ok(BR.FuelSolve.drain(100, -50, 100) == 100,
       'a NEGATIVE drain is not a fill')
    ok(BR.FuelSolve.refill(50, 30, 100) == 80, 'refilling adds')
    ok(BR.FuelSolve.refill(50, 300, 100) == 100, 'you cannot go past full')
    ok(BR.FuelSolve.refill(50, -30, 100) == 50,
       'a NEGATIVE refill is not a drain')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('solve.grantMs')
-- ═══════════════════════════════════════════════════════════════════════════
do
    ok(BR.FuelSolve.grantMs(nil, 5000, 400) == 400,
       'the first message of a hold earns one step')
    ok(BR.FuelSolve.grantMs(5000, 5250, 400) == 250,
       'a normal cadence earns the elapsed time')
    -- THE WHOLE POINT: MESSAGES DO NOT BUY FUEL, TIME DOES.
    ok(BR.FuelSolve.grantMs(5000, 5000, 400) == 0,
       'a second message in the same millisecond earns nothing')
    ok(BR.FuelSolve.grantMs(5000, 5001, 400) == 1,
       'and the one after it earns one millisecond, not a step')
    -- AND WALKING AWAY DOES NOT BANK IT.
    ok(BR.FuelSolve.grantMs(5000, 300000, 400) == 400,
       'a five-minute gap is still worth one step')
    ok(BR.FuelSolve.grantMs(5000, 4000, 400) == 0,
       'a clock that went backwards earns nothing')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('solve.tankLevel')
-- ═══════════════════════════════════════════════════════════════════════════
do
    ok(near(BR.FuelSolve.tankLevel(3000, 6000, 65), 32.5),
       'half a budget is half a tank of litres')
    ok(BR.FuelSolve.tankLevel(0, 6000, 65) == 0, 'empty is empty')
    ok(near(BR.FuelSolve.tankLevel(6000, 6000, 65), 65), 'full is full')
    -- A BICYCLE. GTA gives a zero-volume vehicle infinite fuel and ignores what
    -- it is told; answering 0 keeps this total instead of dividing by nothing.
    ok(BR.FuelSolve.tankLevel(3000, 6000, 0) == 0, 'a zero-volume tank is zero')
    -- AND A BROKEN CONFIG READS FULL, NOT DRY. The two ways to be wrong are
    -- "fuel does nothing" and "every car on the map is permanently dead", and
    -- only one of them is a match nobody can play.
    ok(BR.FuelSolve.fraction(3000, 0) == 1.0, 'a zero-metre tank reads FULL')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('solve.stationNear')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local list = { { id = 'a', x = 0.0, y = 0.0 }, { id = 'b', x = 100.0, y = 0.0 } }
    local s, d = BR.FuelSolve.stationNear(5.0, 0.0, list, 30.0)
    ok(s and s.id == 'a' and near(d, 5), 'the nearer one wins', s and s.id)
    s, d = BR.FuelSolve.stationNear(95.0, 0.0, list, 30.0)
    ok(s and s.id == 'b', 'and so does the other one', s and s.id)
    s, d = BR.FuelSolve.stationNear(50.0, 0.0, list, 30.0)
    ok(s == nil and near(d, 50), 'out of range is nil AND reports the distance', d)
    ok(BR.FuelSolve.stationNear(0, 0, nil, 30) == nil, 'no list is no station')
    ok(BR.FuelSolve.stationNear(0, 0, list, 0) == nil, 'a zero radius reaches nothing')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('config.twoStops')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE OWNER'S RULE, AS A BUILD FAILURE: "1 trip across the map should require 2
-- fuel stops." Everything here re-derives it from the shipped numbers rather
-- than restating them, so moving the map AABB or the tank size fails HERE
-- rather than in a playtest.
do
    local D = BR.Config.Fuel.mapDiagonal()
    ok(near(D, 14148.1, 1.0), 'the map diagonal is 14,148m', D)

    ok(BR.Config.Fuel.stopsPerCrossing() == 2,
       'a straight-line crossing costs exactly two stops',
       BR.Config.Fuel.stopsPerCrossing())

    -- THE BAND, NOT THE POINT. The tank has to sit inside D/3 .. D/2 for the
    -- rule to hold at all, and the header's whole argument is about where in
    -- that band it sits.
    ok(TANK >= D / 3 and TANK < D / 2,
       'the tank is inside the band two stops defines',
       ('%.0f not in [%.0f, %.0f)'):format(TANK, D / 3, D / 2))

    -- ROAD DETOURS. Nobody drives the diagonal; the chosen value is the one
    -- whose two-stop answer survives a route up to 27% longer than a straight
    -- line, and still holds for one 15% SHORTER.
    ok(BR.Config.Fuel.stopsPerCrossing(0.85) == 2, 'still two at k=0.85')
    ok(BR.Config.Fuel.stopsPerCrossing(1.00) == 2, 'still two at k=1.00')
    ok(BR.Config.Fuel.stopsPerCrossing(1.27) == 2, 'still two at k=1.27')
    ok(BR.Config.Fuel.stopsPerCrossing(1.30) == 3, 'three once the detour is 30%')

    -- A SHORT HOP COSTS NOTHING, and the formula must not answer -1 for it.
    ok(BR.FuelSolve.stopsFor(100, TANK) == 0, 'a hundred metres needs no stop')
    ok(BR.FuelSolve.stopsFor(TANK, TANK) == 0, 'exactly one tank needs no stop')
    ok(BR.FuelSolve.stopsFor(TANK + 1, TANK) == 1, 'one metre more needs one')

    -- The refuel rate is DERIVED from refuelSeconds, so the two can never
    -- disagree. Holding for refuelSeconds fills an empty tank exactly.
    ok(near(BR.Config.Fuel.refuelMetresPerSec * BR.Config.Fuel.refuelSeconds, TANK, 1.0),
       'holding for refuelSeconds fills exactly one tank')

    -- The stations are data this file cannot check the truth of, but it CAN
    -- check that there are some and that they are numbers.
    ok(#BR.Config.Fuel.stations >= 15,
       'there are at least fifteen stations on the map',
       #BR.Config.Fuel.stations)
    local bad = 0
    for _, s in ipairs(BR.Config.Fuel.stations) do
        if type(s.x) ~= 'number' or type(s.y) ~= 'number' or type(s.id) ~= 'string' then
            bad = bad + 1
        end
    end
    ok(bad == 0, 'every station has an id and a pair of coordinates', bad)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('ledger.consumption')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    enrol(1, 1001, 7)
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)

    -- The first pass ADMITS and sets the baseline; it must not charge for the
    -- distance between the origin and wherever the car happens to be.
    tick()
    ok(near(BR.Fuel.left(900), TANK), 'a car is admitted full', BR.Fuel.left(900))

    moveVehicle(500, 20.0, 0.0)
    tick()
    ok(near(BR.Fuel.left(900), TANK - 20), 'twenty metres costs twenty metres',
       BR.Fuel.left(900))

    -- STANDING STILL COSTS NOTHING. This is the whole argument for metres over
    -- seconds: idling at a POI is free.
    local before = BR.Fuel.left(900)
    tick(4)
    ok(BR.Fuel.left(900) == before, 'a parked car with the engine on spends nothing')

    -- THE VEHICLE IS KEYED ON ITS NETWORK ID, NOT ITS ENTITY HANDLE. The
    -- harness makes them different numbers precisely so this can be asserted.
    ok(BR.Fuel.left(500) == TANK, 'the entity handle is not a ledger key')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('ledger.oneCarOneCharge')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A FULL SQUAD MUST NOT DRAIN FOUR TIMES FASTER THAN A LONE DRIVER. The naive
-- shape -- charge each player for the distance they moved -- gets this wrong,
-- and it is invisible in any test with one player in it.
do
    reset()
    for i = 1, 4 do enrol(i, 1000 + i, 7) end
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    seat(2, 500, 0)
    seat(3, 500, 1)
    seat(4, 500, 2)

    tick()
    drive(500, 100.0)
    ok(near(BR.Fuel.left(900), TANK - 100),
       'four aboard costs the same hundred metres as one',
       BR.Fuel.left(900))
    -- AND THE COUNTER AGREES, which is a different claim from the arithmetic.
    -- `drive` ran four passes; a car charged once per pass is four drains, and
    -- a car charged once per OCCUPANT per pass would be sixteen. The metres
    -- alone cannot tell those apart if three of the four charges happen to
    -- measure zero.
    ok(BR.Fuel.stats().drained == 4,
       'and the ledger records one charge per pass, not one per occupant',
       BR.Fuel.stats().drained)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('ledger.carriesOver')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THE DESIGN CRUX, AND THE OWNER NAMED IT ═══
--
--   "that needs to carry over if someone else comes up to the vehicle and tries
--    to drive it."   -- owner, 2026-08-21, #195
--
-- Everything else in this feature is arithmetic. This is the reason the ledger
-- is server-side and keyed on the vehicle rather than on the player.
do
    reset()
    enrol(1, 1001, 7)
    enrol(2, 1002, 7)
    makeVehicle(500, 900, 0.0, 0.0)

    -- Player 1 drives it nearly dry and gets out.
    seat(1, 500, -1)
    tick()
    drive(500, TANK - 100)
    local leftAfterOne = BR.Fuel.left(900)
    ok(near(leftAfterOne, 100), 'the first driver leaves 100m in it', leftAfterOne)

    unseat(1, 500)
    tick(2)
    ok(near(BR.Fuel.left(900), leftAfterOne),
       'an abandoned car does not refill itself', BR.Fuel.left(900))

    -- Player 2 walks up and takes it.
    sent = {}
    seat(2, 500, -1)
    tick()
    ok(near(BR.Fuel.left(900), leftAfterOne),
       'and the new driver inherits the same 100m', BR.Fuel.left(900))

    local push = lastSet(2)
    ok(push ~= nil and push.n == 900, 'the new driver is told about it')
    ok(push ~= nil and near(push.f, 100 / TANK, 0.001),
       'and told the right fraction of a tank', push and push.f)

    -- AND IT RUNS OUT UNDER THEM. The engine does the stalling; what this file
    -- owns is the zero that makes it.
    drive(500, 500.0)
    ok(BR.Fuel.left(900) == 0, 'driving past the end empties it exactly to zero',
       BR.Fuel.left(900))
    push = lastSet(2)
    ok(push ~= nil and push.f == 0.0, 'and the client is told zero', push and push.f)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('ledger.teleport')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    enrol(1, 1001, 7)
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()

    -- /brtp across the map between two samples. Charging it would empty the
    -- tank for a journey nobody drove.
    moveVehicle(500, 5000.0, 5000.0)
    tick()
    ok(BR.Fuel.left(900) == TANK, 'a teleport charges nothing', BR.Fuel.left(900))

    -- ...AND THE BASELINE MOVED WITH IT, so the next real metre is charged from
    -- the new position rather than producing a second phantom jump.
    drive(500, 10.0)
    ok(near(BR.Fuel.left(900), TANK - 10),
       'and driving on from there is charged normally', BR.Fuel.left(900))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('ledger.whoIsTracked')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    -- AMBIENT TRAFFIC IS NEVER ADMITTED. Nothing here looks at a car nobody is
    -- sitting in, which is the whole reason a registry keyed on vehicles is
    -- affordable at GTA's population densities.
    makeVehicle(500, 900, 0.0, 0.0)
    tick(4)
    ok(BR.Fuel.stats().tracked == 0, 'an empty car is not tracked',
       BR.Fuel.stats().tracked)

    -- A NON-NETWORKED VEHICLE HAS NO LEDGER AT ALL. The Battle Bus and #191's
    -- ambulance are both created with isNetwork = false, so the server sees a
    -- network id of 0 for them -- and 0 is truthy in Lua, so this is the assert
    -- that the guard is an explicit comparison rather than `if nid then`.
    reset()
    enrol(1, 1001, 7)
    makeVehicle(600, 0, 0.0, 0.0)   -- netId 0: local, non-networked
    netOfEnt[600] = 0
    seat(1, 600, -1)
    tick()
    moveVehicle(600, 500.0, 0.0)
    tick()
    ok(BR.Fuel.stats().tracked == 0, 'a client-side vehicle is never tracked',
       BR.Fuel.stats().tracked)

    -- A DEAD PLAYER'S CAR IS NOT DRAINED. A spectator's camera follows somebody
    -- else's vehicle and must not spend their fuel.
    reset()
    enrol(1, 1001, 7)
    roster[1].state = BR.PlayerState.DEAD
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()
    moveVehicle(500, 500.0, 0.0)
    tick()
    ok(BR.Fuel.stats().tracked == 0, 'a player who is not live tracks nothing')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('pump.rules')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local S = BR.Config.Fuel.stations[1]

    --- A driver parked on the forecourt with some fuel already spent.
    ---
    --- The drive out and back is what puts the ledger below full; the return
    --- leg is what puts the car back on the pump. Both are believable steps --
    --- see `drive` -- so the tank really is drained rather than being written. Two
    --- kilometres, comfortably more than one pump step is worth, so the fill test
    --- below measures the RATE rather than measuring the clamp at full.
    local function parkedAtPump()
        reset()
        enrol(1, 1001, 7)
        enrol(2, 1002, 7)
        makeVehicle(500, 900, S.x, S.y)
        seat(1, 500, -1)
        tick()
        drive(500, 2000.0)
        moveVehicle(500, S.x, S.y)
        -- Coming back in one step is a jump the sampler disbelieves, which is
        -- correct and costs nothing: the 200m out has already been charged.
        tick()
    end

    -- OFF THE FORECOURT, NOTHING HAPPENS.
    reset()
    enrol(1, 1001, 7)
    makeVehicle(500, 900, S.x + 5000.0, S.y)
    seat(1, 500, -1)
    tick()
    drive(500, 100.0)
    local before = BR.Fuel.left(900)
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    ok(BR.Fuel.left(900) == before, 'no pump five kilometres from a station',
       BR.Fuel.left(900))

    -- ON THE FORECOURT, IT FILLS.
    parkedAtPump()
    before = BR.Fuel.left(900)
    ok(near(before, TANK - 2000), 'the car is 2000m down to begin with', before)

    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    local afterOne = BR.Fuel.left(900)
    ok(afterOne > before, 'a hold at the pump adds fuel', afterOne)
    -- The first message of a hold is worth one step, and a step is worth
    -- pumpStepMs of the rate.
    ok(near(afterOne - before,
            (BR.Config.Fuel.pumpStepMs / 1000.0) * BR.Config.Fuel.refuelMetresPerSec,
            0.01),
       'and it is worth exactly one step of pumping', afterOne - before)

    -- ═══ SPAMMING BUYS NOTHING ═══
    --
    -- The only message in the gamemode that makes a resource go UP. Ten of them
    -- in the same millisecond must be worth what one is.
    local mark = BR.Fuel.left(900)
    for _ = 1, 10 do fire(BR.Net.FUEL_PUMP, 1, { n = 900 }) end
    ok(BR.Fuel.left(900) == mark,
       'ten messages in the same millisecond add nothing at all',
       BR.Fuel.left(900) - mark)

    -- ...and time does.
    fakeTime = fakeTime + 250
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    ok(near(BR.Fuel.left(900) - mark,
            0.250 * BR.Config.Fuel.refuelMetresPerSec, 0.01),
       'a quarter second later, a quarter second of fuel',
       BR.Fuel.left(900) - mark)

    -- ═══ THE REPAIR RIDES ON THE SAME GRANT ═══
    --
    --   "When stopping for fuel ... the vehicle health should be restored."
    --
    -- The server cannot READ a vehicle's health -- every health native is
    -- client-only -- so what it owns is whether any repair was earned and how
    -- much. That is the field asserted here; applying it is client/fuel.lua's.
    sent = {}
    fakeTime = fakeTime + 250
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    local push = lastSet(1)
    ok(push ~= nil and push.r ~= nil, 'a pump grant carries a repair')
    ok(push ~= nil and near(push.r,
            0.250 * BR.Config.Fuel.repairPerSecond, 0.01),
       'worth the same quarter second the fuel was', push and push.r)

    -- AND ONLY A PUMP GRANT CARRIES ONE. An ordinary driving push must not
    -- repair anything, or a car would heal itself by being driven.
    sent = {}
    drive(500, 100.0)
    push = lastSet(1)
    ok(push ~= nil and push.r == nil, 'a driving push carries no repair',
       push and tostring(push.r))

    -- Back onto the forecourt for the seat tests below.
    moveVehicle(500, S.x, S.y)
    tick()

    -- ═══ THE PASSENGER SEAT ═══
    --
    --   "Refueling should only be possible while in the driver's seat"
    seat(2, 500, 0)
    mark = BR.Fuel.left(900)
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 2, { n = 900 })
    ok(BR.Fuel.left(900) == mark, 'a passenger cannot refuel',
       BR.Fuel.left(900) - mark)

    -- ═══ A VEHICLE YOU ARE NOT IN ═══
    makeVehicle(501, 901, S.x, S.y)
    seat(2, 501, -1)
    tick()
    mark = BR.Fuel.left(900)
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 2, { n = 900 })
    ok(BR.Fuel.left(900) == mark,
       'you cannot pump into a car you are not sitting in')

    -- ═══ ON FOOT ═══
    unseat(1, 500)
    mark = BR.Fuel.left(900)
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    ok(BR.Fuel.left(900) == mark, 'you cannot pump while standing beside it')

    -- ═══ A NUMBER OFF THE WIRE THAT NAMES NOTHING ═══
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 424242 })
    ok(BR.Fuel.stats().tracked <= 2, 'a made-up network id admits no row',
       BR.Fuel.stats().tracked)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('pump.fillsToFull')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- END TO END: a tank drained to nothing takes refuelSeconds of held key to
-- fill, and stops at full.
do
    reset()
    enrol(1, 1001, 7)
    local S = BR.Config.Fuel.stations[1]
    makeVehicle(500, 900, S.x, S.y)
    seat(1, 500, -1)
    tick()
    drive(500, TANK + 100.0)
    ok(BR.Fuel.left(900) == 0, 'the tank is empty', BR.Fuel.left(900))

    -- Park back on the forecourt and hold the key at the client's cadence.
    moveVehicle(500, S.x, S.y)
    tick()
    local ticks, repaired = 0, 0.0
    while BR.Fuel.left(900) < TANK and ticks < 200 do
        fakeTime = fakeTime + BR.Config.Fuel.pumpSendMs
        sent = {}
        fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
        local p = lastSet(1)
        repaired = repaired + ((p and p.r) or 0.0)
        ticks = ticks + 1
    end
    ok(BR.Fuel.left(900) == TANK, 'holding the key fills it', BR.Fuel.left(900))

    -- ═══ AND A FULL FILL IS A FULL REPAIR ═══
    --
    -- MEASURED AGAINST THE OWNER'S RULE, NOT AGAINST THE DERIVED RATE. The
    -- earlier per-message assertion compares `r` to
    -- BR.Config.Fuel.repairPerSecond -- which is the same constant the server
    -- multiplied by, so it is true whatever that constant is. Mutation testing
    -- caught exactly that: breaking the derivation (dividing by 1.0 instead of
    -- refuelSeconds, so a stop repairs ten times over) left the suite green.
    --
    -- This one is not self-referential. It asserts the SENTENCE -- "when
    -- stopping for fuel the vehicle health should be restored", read as a full
    -- fill being a full repair -- against healthMax and repairFraction, which
    -- are the two authored numbers rather than the derived one.
    --
    -- The tolerance is one message's worth: the loop stops the instant the tank
    -- reads full, and the grant that filled it was clamped on fuel while the
    -- repair beside it was not.
    local wantRepair = BR.Config.Fuel.healthMax * BR.Config.Fuel.repairFraction
    local slack = (BR.Config.Fuel.pumpStepMs / 1000.0)
        * (wantRepair / BR.Config.Fuel.refuelSeconds)
    ok(math.abs(repaired - wantRepair) <= slack + 0.01,
       'and the same hold restores exactly one full repair',
       ('%.1f vs %.1f (slack %.1f)'):format(repaired, wantRepair, slack))
    -- refuelSeconds of holding, at pumpSendMs per message, plus the one step the
    -- first message of the hold is worth.
    local expect = math.ceil(
        (BR.Config.Fuel.refuelSeconds * 1000 - BR.Config.Fuel.pumpStepMs)
        / BR.Config.Fuel.pumpSendMs) + 1
    ok(math.abs(ticks - expect) <= 1,
       ('it takes about %d messages, not %d'):format(expect, ticks), ticks)

    -- AND IT STOPS AT FULL.
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    ok(BR.Fuel.left(900) == TANK, 'and holding it longer does not overfill')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('ask.rules')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    enrol(1, 1001, 7)
    enrol(2, 1002, 7)
    makeVehicle(500, 900, 0.0, 0.0)

    -- Player 1 drains it and walks away.
    seat(1, 500, -1)
    tick()
    drive(500, 1000.0)

    unseat(1, 500)

    -- Player 2 is standing beside it, about to open the door.
    roster[2].pos = { x = 1002.0, y = 0.0, z = 30.0 }
    sent = {}
    fire(BR.Net.FUEL_ASK, 2, { n = 900 })
    local a = lastSet(2)
    ok(a ~= nil and a.m == TANK - 1000,
       'a player beside the car is told what it holds', a and a.m)

    -- ...AND A PLAYER ACROSS THE MAP IS NOT. Without this the ask is a free
    -- oracle for which cars on the map are dry.
    roster[2].pos = { x = 4000.0, y = 4000.0, z = 30.0 }
    sent = {}
    fire(BR.Net.FUEL_ASK, 2, { n = 900 })
    ok(lastSet(2) == nil, 'a player across the map is told nothing')

    -- AN UNKNOWN CAR ANSWERS FULL AND IS NOT ADMITTED.
    makeVehicle(501, 901, 0.0, 0.0)
    roster[2].pos = { x = 2.0, y = 0.0, z = 30.0 }
    sent = {}
    local tracked = BR.Fuel.stats().tracked
    fire(BR.Net.FUEL_ASK, 2, { n = 901 })
    a = lastSet(2)
    ok(a ~= nil and a.m == TANK, 'an untouched car answers full', a and a.m)
    ok(BR.Fuel.stats().tracked == tracked,
       'and asking about it does not create a row', BR.Fuel.stats().tracked)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('registry.bounds')
-- ═══════════════════════════════════════════════════════════════════════════
do
    -- ═══ THE CAP ═══
    reset()
    local realCap = BR.Config.Fuel.maxTracked
    BR.Config.Fuel.maxTracked = 3
    enrol(1, 1001, 7)
    for i = 1, 6 do
        makeVehicle(500 + i, 900 + i, 0.0, 0.0)
        seat(1, 500 + i, -1)
        tick()
    end
    ok(BR.Fuel.stats().tracked <= 3, 'the registry never exceeds its cap',
       BR.Fuel.stats().tracked)
    ok(BR.Fuel.stats().evicted >= 3, 'and it says how many it threw away',
       BR.Fuel.stats().evicted)
    BR.Config.Fuel.maxTracked = realCap

    -- ═══ A DISCONNECT DOES NOT REFILL A CAR ═══
    --
    -- Per-vehicle state means exactly this: the tank belongs to the car, not to
    -- whoever was last sitting in it.
    reset()
    enrol(1, 1001, 7)
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()
    drive(500, 500.0)

    local left = BR.Fuel.left(900)
    fire('playerDropped', 1)
    ok(BR.Fuel.left(900) == left,
       "a driver disconnecting does not refill the car they left", BR.Fuel.left(900))

    -- ═══ A MATCH ENDING TAKES ITS OWN CARS AND NOBODY ELSE'S ═══
    reset()
    enrol(1, 1001, 7)
    enrol(2, 1002, 9)
    makeVehicle(500, 900, 0.0, 0.0)
    makeVehicle(501, 901, 0.0, 0.0)
    seat(1, 500, -1)
    seat(2, 501, -1)
    tick()
    drive(500, 300.0)
    drive(501, 300.0)
    ok(BR.Fuel.left(900) < TANK and BR.Fuel.left(901) < TANK,
       'both matches have a car with fuel spent')
    fire('br:match:destroyed', nil, { matchId = 7 })
    ok(BR.Fuel.left(900) == TANK, "the ended match's car is forgotten")
    ok(BR.Fuel.left(901) < TANK, "and the other match's car is not",
       BR.Fuel.left(901))

    -- ═══ A VEHICLE THAT NO LONGER EXISTS IS SWEPT ═══
    reset()
    enrol(1, 1001, 7)
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()
    drive(500, 300.0)
    ok(BR.Fuel.stats().tracked == 1, 'one car tracked')
    unseat(1, 500)
    exists[500] = nil
    -- The sweep runs on its own 5s job.
    for _ = 1, 24 do tick() end
    ok(BR.Fuel.stats().tracked == 0, 'a destroyed vehicle is swept',
       BR.Fuel.stats().tracked)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('push.policy')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    enrol(1, 1001, 7)
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()

    -- A CAR THAT IS NOT MOVING DOES NOT GENERATE TRAFFIC, past the heartbeat.
    sent = {}
    tick(4)   -- one second
    local n = 0
    for _, s in ipairs(sent) do if s.event == BR.Net.FUEL_SET then n = n + 1 end end
    ok(n == 0, 'a parked car sends nothing for a second', n)

    -- ...and the heartbeat eventually lands one anyway, so a client that missed
    -- a message converges without having to ask.
    sent = {}
    tick(12)  -- three seconds, past pushHeartbeatMs
    n = 0
    for _, s in ipairs(sent) do if s.event == BR.Net.FUEL_SET then n = n + 1 end end
    ok(n >= 1, 'but the heartbeat still lands one', n)

    -- A METRE DOES NOT MOVE THE NEEDLE AND DOES NOT COST A MESSAGE.
    sent = {}
    moveVehicle(500, 1.0, 0.0)
    tick()
    n = 0
    for _, s in ipairs(sent) do if s.event == BR.Net.FUEL_SET then n = n + 1 end end
    ok(n == 0, 'one metre of travel sends nothing', n)

    -- A HUNDRED DOES.
    sent = {}
    drive(500, 100.0)
    ok(lastSet(1) ~= nil, 'a hundred metres does')
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
