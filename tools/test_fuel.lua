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

--- Every FUEL_SFX cue a player was sent, in order.
---
--- A LIST RATHER THAN A LAST-ONE, because the interesting properties of the pump
--- cues are about COUNT and ORDER: the start fires once per hold no matter how
--- many messages the hold is made of, and the completion fires once no matter
--- how long somebody keeps holding afterwards. A `lastSfx` could not see either.
--- @param src integer
--- @return table cues   array of cue-name strings
local function sfxTo(src)
    local out = {}
    for _, s in ipairs(sent) do
        if s.event == BR.Net.FUEL_SFX and s.target == src then
            out[#out + 1] = s.args[1] and s.args[1].c
        end
    end
    return out
end

--- Drop the record of what has been sent, without touching the world.
---
--- `reset()` rebuilds the whole map and is far too big for "I want to count the
--- cues from THIS hold". Parking a car takes a dozen messages and every one of
--- them would be in the way.
local function clearSent() sent = {} end

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
    -- AND NEITHER DOES A MISSING ONE. Found by mutation: `tonumber(radius) or
    -- 0.0` is what turns an absent radius into a refusal, and every assertion
    -- above passes with that fallback changed to math.huge -- which would make
    -- a config typo mean "every station on the map is in range".
    ok(BR.FuelSolve.stationNear(0, 0, list, nil) == nil,
       'and a missing radius is not an unbounded one')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('solve.atPump')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE FIRST PLAYTEST'S SECOND ITEM, AS ARITHMETIC:
--
--   "The DUI draws way too far away from the pumps. We need to be like 10ft
--    from the pumps or less."   -- owner, 2026-08-22
--
-- The behaviour that fixes it is a distance test the client runs every frame
-- against a prop it found at runtime. The prop cannot be reached from here --
-- GET_CLOSEST_OBJECT_OF_TYPE reads a streamed world -- but the test it feeds
-- can, and the test is the half that decides.
do
    local R = 3.0

    -- THE THREE POINTS ON THE BOUNDARY, and the middle one is the reason a
    -- `<` would be wrong: the owner said "10ft or less", so the radius itself
    -- is inside.
    ok(select(1, BR.FuelSolve.atPump(0.0, 0.0, 2.0, 0.0, R)),
       'inside the radius draws')
    ok(select(1, BR.FuelSolve.atPump(0.0, 0.0, 3.0, 0.0, R)),
       'exactly on the radius draws -- "or less" includes it')
    ok(not select(1, BR.FuelSolve.atPump(0.0, 0.0, 3.01, 0.0, R)),
       'a centimetre past it does not')

    -- THE WHOLE POINT OF THE CHANGE, stated as the case that used to pass. A
    -- car on the far side of the forecourt is well inside stationRadius and
    -- must no longer get a plate.
    ok(not select(1, BR.FuelSolve.atPump(0.0, 0.0, 25.0, 0.0, R)),
       'a car 25m away -- inside the station, nowhere near a pump -- does not')

    -- DIAGONALS ARE EUCLIDEAN, not per-axis. 3 east and 3 north is 4.24m and
    -- is out, which a lazy `|dx| <= r and |dy| <= r` would have let through.
    ok(not select(1, BR.FuelSolve.atPump(0.0, 0.0, 3.0, 3.0, R)),
       'three metres on each axis is 4.24m and is out')
    ok(select(1, BR.FuelSolve.atPump(0.0, 0.0, 2.0, 2.0, R)),
       'two on each is 2.83m and is in')

    -- IT REPORTS THE DISTANCE, which is what `/brfuel` prints so the next
    -- adjustment to the radius is measured rather than guessed.
    local _, d = BR.FuelSolve.atPump(10.0, 10.0, 13.0, 14.0, R)
    ok(near(d, 5.0), 'the distance comes back alongside the verdict', d)

    -- SIGN DOES NOT MATTER. The pump can be behind you.
    ok(select(1, BR.FuelSolve.atPump(0.0, 0.0, -2.0, 0.0, R)),
       'a pump on the other side is the same distance away')

    -- ═══ THE REFUSALS, AND THE DIRECTION THEY ALL FAIL IN ═══
    --
    -- Every unreadable input answers NO PLATE. The alternative -- treating an
    -- unknown as close -- puts the prompt back in the sky at a position
    -- nothing can render, which is the fault being fixed wearing a different
    -- hat.
    ok(not select(1, BR.FuelSolve.atPump(nil, 0.0, 0.0, 0.0, R)),
       'a vehicle with no x draws nothing')
    ok(not select(1, BR.FuelSolve.atPump(0.0, 0.0, nil, nil, R)),
       'and neither does a pump with no coordinates')
    ok(not select(1, BR.FuelSolve.atPump(0.0, 0.0, 1.0, 0.0, 0.0)),
       'a zero radius draws nothing rather than everything')
    -- AND NOT EVEN SITTING ON THE PROP. Found by mutation: at any non-zero
    -- distance a zero radius is refused by the `d <= radius` test anyway, so
    -- the explicit guard is only load-bearing at d == 0 -- which is exactly the
    -- case a car parked dead on a pump produces. Without this assertion the
    -- guard can be deleted and every other test here still passes.
    ok(not select(1, BR.FuelSolve.atPump(0.0, 0.0, 0.0, 0.0, 0.0)),
       'not even with the pump exactly underneath')
    ok(not select(1, BR.FuelSolve.atPump(0.0, 0.0, 1.0, 0.0, -1.0)),
       'and so does a negative one')
    ok(not select(1, BR.FuelSolve.atPump(0.0, 0.0, 1.0, 0.0, nil)),
       'a missing radius is not an unbounded one')

    -- NaN. `d > radius` answers FALSE for a NaN, so a refusal written that way
    -- lets it through as a pass -- the same trap BR.FuelSolve.clamp's header
    -- describes, in the one place where the consequence is a sprite drawn at a
    -- position the engine cannot use.
    local nan = 0.0 / 0.0
    local inNan, dNan = BR.FuelSolve.atPump(0.0, 0.0, nan, 0.0, R)
    ok(not inNan, 'a NaN coordinate is not "close"')
    ok(dNan == math.huge, 'and reports an infinite distance, not a NaN', dNan)

    -- A ZERO RADIUS STILL REPORTS THE DISTANCE, because a misconfigured radius
    -- is exactly when somebody runs /brfuel to find out what it should be.
    local _, d0 = BR.FuelSolve.atPump(0.0, 0.0, 4.0, 0.0, 0.0)
    ok(near(d0, 4.0), 'a refused radius still measures', d0)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('config.promptRadius')
-- ═══════════════════════════════════════════════════════════════════════════
do
    local P = BR.Config.Fuel.promptRadius
    local S = BR.Config.Fuel.stationRadius

    -- ═══ THE OWNER MOVED THIS NUMBER TWICE, AND THE SECOND TIME REVERSED THE
    --     FIRST ═══
    --
    -- 2026-08-22, first: "We need to be like 10ft from the pumps or less" --
    -- which is 3.048m, and this assertion pinned it at or under that.
    --
    -- Later the same day, having played it: "Let's double the fuel + DUI radius
    -- again. I was wrong." So the ten-foot rule is retired by the person who set
    -- it, and pinning it now would be pinning a sentence they took back.
    --
    -- WHAT IS STILL WORTH ASSERTING is the RELATIONSHIP, not the figure. The
    -- plate must sit inside the radius the server will actually honour, because
    -- the client draws it only when BOTH tests pass -- that is what closed the
    -- gap where a hold silently filled the tank with nothing on screen. A prompt
    -- radius wider than the server's would reopen it.
    ok(P > 0 and P <= (BR.Config.Fuel.refuelRadius or S),
       'the prompt sits inside the radius the server will honour', P)

    -- THE TWO RADII ARE ORDERED, AND THE ORDER IS WHAT MAKES THE SMALLER ONE
    -- MEAN ANYTHING. The prompt gate sits INSIDE the station gate in
    -- client/fuel.lua, so a prompt radius at or above the station radius stops
    -- being a second test at all -- it silently reverts to the behaviour the
    -- playtest rejected, with a config value that looks deliberate.
    ok(P < S, 'and it is strictly inside the station radius',
       ('prompt %.1f, station %.1f'):format(P, S))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('config.refuelRadius')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THE THREE RADII AND THE ORDER THAT MAKES EACH OF THEM MEAN SOMETHING ═══
--
--   "The distance for the DUI to draw is great, but for some reason I can still
--    get gas further away from the pumps before the DUI is drawn. That's not
--    okay."                                  -- owner, 2026-08-22
--
-- promptRadius (3m, from a PUMP PROP)     is there a plate on screen
-- refuelRadius (20m, from a STATION)      may this vehicle buy fuel
-- stationRadius (30m, from a STATION)     is the horn suppressed, are pumps
--                                         searched for
--
-- The bug the owner is describing is what happens when the REFUEL test is wider
-- than the DRAW test: a hold fills the tank with nothing on screen. The fix has
-- a client half (draw and send are now the same condition) and a server half
-- (this radius), and this block pins the invariant the server half rests on.
do
    local P = BR.Config.Fuel.promptRadius
    local R = BR.Config.Fuel.refuelRadius
    local S = BR.Config.Fuel.stationRadius

    ok(type(R) == 'number' and R > 0, 'the refuel radius exists and is positive', R)

    -- ═══ THE ORDERING, WHICH IS THE WHOLE INVARIANT ═══
    --
    -- refuelRadius MUST NOT EXCEED stationRadius. The client only looks for a
    -- station at all within stationRadius, so a refuelRadius above it would be
    -- a permission the client can never see itself holding -- the plate would
    -- stop drawing before the server stopped granting, which is the ORIGINAL
    -- BUG restored from the other end.
    ok(R <= S, 'the refuel radius is inside the station radius',
       ('refuel %.1f, station %.1f'):format(R, S))

    -- AND IT IS STRICTLY TIGHTER THAN IT USED TO BE. The refuel test was
    -- stationRadius; if a later edit puts it back, the gap the owner rejected
    -- comes back with it and nothing else in this suite would notice.
    ok(R < S, 'and strictly tighter than the forecourt bubble it was cut from',
       ('refuel %.1f, station %.1f'):format(R, S))

    -- THE PUMP RADIUS STAYS INSIDE THE REFUEL RADIUS. The client draws on the
    -- conjunction of the two, so a promptRadius above this would make the
    -- refuel test the binding one and quietly widen what the plate advertises.
    ok(P < R, 'and the prompt radius sits inside it',
       ('prompt %.1f, refuel %.1f'):format(P, R))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('audio.pumpCues')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ WHAT THIS CAN AND CANNOT PROVE, SAID FIRST ═══
--
--   "This should be a native GTA V sound. Pick something most appropriate for
--    'interact'"
--   "When fuel reaches 100%, a 'complete' sound should be played. Again, GTA V
--    sounds only please."                    -- owner, 2026-08-22
--
-- IT CANNOT PROVE A SOUND PLAYS. A wrong sound-set name does not error --
-- PlaySoundFrontend and PlaySoundFromEntity both play nothing, silently, which
-- is why /brsfx exists and why config/audio.lua's header says every name must be
-- auditioned. Only a running client settles that.
--
-- WHAT IT DOES PROVE is the half that a unit test can reach: the two cues exist
-- under the names the fuel code asks for, they carry both fields, and they do
-- not collide with a cue already in use. The collision check is the valuable
-- one -- two actions that sound identical is a bug nobody files.
do
    -- config/audio.lua is not in this suite's load list (it has no arithmetic in
    -- it and nothing else here needs it), so it is loaded on its own.
    load('br_lib/config/audio.lua')

    local cues = BR.Config.Audio and BR.Config.Audio.cues or {}

    -- storm.move RIDES THIS BLOCK RATHER THAN GETTING ITS OWN, and it is here
    -- rather than in a storm suite on purpose: what is being checked is not the
    -- storm, it is the CUE TABLE -- that every cue any subsystem asks for by key
    -- exists, carries both fields, and sounds like nothing else. That is one
    -- property over one table, and splitting it per subsystem is how the
    -- collision check below ends up comparing half the cues with the other half.
    for _, name in ipairs({ 'fuel.start', 'fuel.done', 'storm.move' }) do
        local def = cues[name]
        ok(type(def) == 'table', ('the %s cue exists'):format(name))
        if type(def) == 'table' then
            ok(type(def.set) == 'string' and #def.set > 0,
               ('%s names a sound set'):format(name), tostring(def.set))
            ok(type(def.name) == 'string' and #def.name > 0,
               ('%s names a sound'):format(name), tostring(def.name))
        end
    end

    -- ═══ NO TWO ACTIONS MAY SOUND THE SAME ═══
    --
    -- The hitmarker, the crate and the pump all fire in the same match and a
    -- player learns them by ear. Sharing a set/name pair between two of them is
    -- not a crash and not a visible fault -- it just makes the game harder to
    -- read, permanently, and nobody ever traces it back to a config line.
    local seen, clash = {}, nil
    for cue, def in pairs(cues) do
        if type(def) == 'table' and def.set and def.name then
            local key = def.set .. '/' .. def.name
            if seen[key] then clash = ('%s and %s are both %s'):format(seen[key], cue, key) end
            seen[key] = cue
        end
    end
    ok(clash == nil, 'no two cues share a sound', clash)

    -- ═══ EVERY CUE'S SET IS ONE GTA'S OWN SCRIPTS PLAY ═══
    --
    -- The single failure mode this whole file's header is about: a wrong sound
    -- SET is SILENT, and silent is indistinguishable from a sound somebody
    -- disliked. The catalogue is the 84 base-game sets taken from the calls
    -- Rockstar's scripts actually make, with every DLC bank filtered out -- so a
    -- cue whose set is not in it is a cue nobody has any reason to believe will
    -- play. This is the check that would have caught Pit_Stop_Complete.
    --
    -- ASSERTED OVER THE WHOLE TABLE rather than per cue, because the next cue
    -- added is the one nobody will write a test for.
    local catSets = {}
    for _, entry in ipairs(BR.Config.Audio.catalogue or {}) do catSets[entry.set] = true end
    local stray = nil
    for cue, def in pairs(cues) do
        if type(def) == 'table' and def.set and not catSets[def.set] then
            stray = ('%s uses %s, which is in no catalogue set'):format(cue, def.set)
        end
    end
    ok(stray == nil,
       'every cue plays out of a set GTA\'s own scripts call -- no DLC audio '
           .. 'bank, which would be silent rather than wrong', stray)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('prompt.copy')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THE OWNER'S WORDS, PINNED AS TEXT, BECAUSE THERE IS NO OTHER WAY TO
--     REACH THEM ═══
--
--   "The DUI is not helpful - it just says '6000m' etc. Instead it should say
--    'Hold to refuel'"   -- owner, 2026-08-22
--
-- br_core/client/fuel.lua cannot be loaded here: it registers frame-band loop
-- callbacks and calls a dozen client natives that this suite does not stub, and
-- stubbing them to reach one string literal would be a harness larger than the
-- file. tools/test_client.lua reads client sources as TEXT in four places for
-- the same reason, and this is that shape.
--
-- WHAT A PASS HERE IS AND IS NOT. It proves the string in the file is the
-- owner's, character for character, and that nothing is concatenated onto it on
-- its way to the plate. It cannot prove the plate renders -- that needs a game.
-- The value is against the specific regression this replaces: a label built by
-- `('%d m'):format(...)`, which is what the owner was reading.
do
    local fh = io.open(ROOT .. 'br_core/client/fuel.lua', 'r')
    ok(fh ~= nil, 'client/fuel.lua is readable')
    if fh then
        local src = fh:read('a'); fh:close()

        -- Plain find (the `true` argument): the string is compared as text, so
        -- a `%` in a future edit cannot be read as a Lua pattern.
        ok(src:find("local PROMPT_LABEL = 'Hold to refuel'", 1, true) ~= nil,
           "the plate says exactly 'Hold to refuel'")

        -- ═══ AND THE SECOND STRING, ADDED 2026-08-22 ═══
        --
        --   "While holding the key, the DUI should change to say 'Currently
        --    fueling'"                        -- owner, 2026-08-22
        ok(src:find("local PROMPT_LABEL_FUELING = 'Currently fueling'", 1, true) ~= nil,
           "and says exactly 'Currently fueling' while the key is down")

        -- ═══ THE SPELLING IS THE OWNER'S AND IS PINNED AGAINST A HELPFUL
        --     CORRECTION ═══
        --
        -- "fueling" with one L is what they wrote. A future tidy-up to the
        -- British "fuelling" would be a change to UI copy nobody asked for, and
        -- it is exactly the kind of edit that looks like an improvement. This is
        -- the only thing that would catch it.
        ok(src:find('Currently fuelling', 1, true) == nil,
           "and nobody has 'corrected' it to the double-L spelling")

        -- AND NOTHING IS APPENDED. The label field must be one of the two
        -- constants and only that -- no `..`, no :format(), no metres.
        ok(src:find('label = fueling and PROMPT_LABEL_FUELING or PROMPT_LABEL,',
                    1, true) ~= nil,
           'and the prompt sends one of the two constants unmodified')

        -- ═══ THE GAP THE OWNER REJECTED, PINNED SHUT ═══
        --
        --   "The distance for the DUI to draw is great, but for some reason I
        --    can still get gas further away from the pumps before the DUI is
        --    drawn. That's not okay."         -- owner, 2026-08-22
        --
        -- The fix is that the pump message is not sent while the plate is down.
        -- This is a TEXT check for the same reason the rest of this block is:
        -- the frame loop it lives in cannot be run here. It proves the early
        -- return exists; it cannot prove it is reached.
        ok(src:find('if not inReach then return end', 1, true) ~= nil,
           'and no pump message goes out while the plate is down')

        -- ═══ AND THE PLATE ITSELF IS GATED ON THE SERVER'S OWN RADIUS ═══
        --
        -- The send gate above is only half of it. If the plate kept drawing on
        -- the pump test alone, the two conditions would come apart again in the
        -- other direction -- plate up, server refusing -- which is the WORSE
        -- failure, because it would read "Currently fueling" while nothing
        -- filled. Mutation testing found this line unprotected.
        ok(src:find('and stationDist <= (tonumber(F.refuelRadius) or 0.0)',
                    1, true) ~= nil,
           'and the plate itself is gated on the radius the server enforces')

        -- ═══ THE LABEL SWITCH ACTUALLY REACHES THE PAGE ═══
        --
        -- setPrompt dedupes, and a dedupe that compares only shown-ness would
        -- send the first label and never the second -- so "Currently fueling"
        -- would be in the file, correct, and never once displayed. There is no
        -- symptom to notice in code review. Mutation testing found this too.
        ok(src:find('(not show or promptFueling == fueling)', 1, true) ~= nil,
           'and the dedupe compares the label, not just whether it is shown')

        -- ═══ THE COSMETIC REPAIR IS STILL GATED ON COMPLETION ═══
        --
        -- The partial rule is that a three-second hold buys 30% of a repair.
        -- Cosmetic damage cannot be partially undone -- every native involved is
        -- an all-or-nothing reset -- so it fires when the body reaches full and
        -- NOT before. Ungating it would hand a full respray to a key tap, which
        -- is a balance change nobody asked for and one that no other assertion
        -- here would see.
        ok(src:find('if body >= cap then fixCosmetic(veh) end', 1, true) ~= nil,
           'and the cosmetic repair only fires once the body is fully repaired')

        -- THE REGRESSION, NAMED. This is the exact expression that produced
        -- "6000m" on the plate.
        ok(src:find("('%d m'):format", 1, true) == nil,
           'no metres formatter survives anywhere in the file')

        -- ═══ THE COSMETIC REPAIR REACHES THE THREE NATIVES IT NAMES ═══
        --
        --   "The gas stations should be repairing cosmetic damage as well,
        --    which means a fill up will fix everything in one go."
        --                                     -- owner, 2026-08-22
        --
        -- WashDecalsFromVehicle is the one worth pinning: it lives in the
        -- GRAPHICS namespace rather than VEHICLE, which is how it would get
        -- dropped by somebody tidying the "vehicle natives" together.
        ok(src:find('pcall(SetVehicleFixed, veh)', 1, true) ~= nil,
           'the cosmetic pass calls SetVehicleFixed')
        ok(src:find('pcall(SetVehicleDeformationFixed, veh)', 1, true) ~= nil,
           'and SetVehicleDeformationFixed')
        ok(src:find('pcall(WashDecalsFromVehicle, veh', 1, true) ~= nil,
           'and WashDecalsFromVehicle, for the scratches')
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('config.twoStops')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THIS BLOCK USED TO ASSERT TWO STOPS. IT NOW ASSERTS ONE, AND THAT IS THE
--     POINT OF IT ═══
--
-- The owner's rule of 2026-08-21 was "1 trip across the map should require 2
-- fuel stops." Their instruction of 2026-08-22 was "increase the distance they
-- can go by 25%", which takes the tank from 6,000 to 7,500 -- OUT of the
-- 4,716..7,074 band the two-stop rule defines.
--
-- ═══ AND THE OWNER HAS SINCE RETIRED THE RULE, WHICH SETTLES IT ═══
--
-- Asked whether the band mattered, they said: "Why does the 4716-7074 band
-- matter? We can set fuel burn to whatever we need. The first round was just a
-- guess, now we're fine tuning." (2026-08-22.)
--
-- So two stops was never a requirement -- it was the first estimate of one, and
-- the tank size is now simply a number to turn. THAT DOES NOT MAKE THIS BLOCK
-- POINTLESS. What it pins is not a rule but a MEASUREMENT: how many stops the
-- current tank actually costs, and at what detour the answer changes. Turning
-- the tank moves those numbers and this block says so, which is exactly what
-- fine-tuning needs and what a comment nobody re-derives cannot give.
--
-- Nothing below asserts that two stops MUST hold. Read it as the answer to
-- "what does 7,500 buy", not as a rule being enforced.
do
    local D = BR.Config.Fuel.mapDiagonal()
    ok(near(D, 14148.1, 1.0), 'the map diagonal is 14,148m', D)

    -- THE +25%, PINNED AGAINST THE VALUE IT WAS DERIVED FROM. 6,000 * 1.25.
    ok(near(TANK, 7500.0, 0.001), 'the tank is the owner +25% of 6,000m', TANK)

    -- ═══ THE CONSEQUENCE, STATED AS AN ASSERTION SO NOBODY HAS TO TAKE IT ON
    --     TRUST ═══
    --
    --   ceil(14,148 / 7,500) - 1  =  2 - 1  =  1
    ok(BR.Config.Fuel.stopsPerCrossing() == 1,
       'a straight-line crossing now costs ONE stop, not two (owner +25%)',
       BR.Config.Fuel.stopsPerCrossing())

    -- AND THE BAND IT LEFT. Asserted in the NEGATIVE, deliberately: this is the
    -- line that says out loud that the older rule is broken, so a future reader
    -- finds a deliberate statement rather than a missing test.
    ok(not (TANK >= D / 3 and TANK < D / 2),
       'the tank is deliberately OUTSIDE the band two stops would need',
       ('%.0f vs [%.0f, %.0f)'):format(TANK, D / 3, D / 2))

    -- ═══ WHAT MAY SAVE THE RULE IN PRACTICE, AND IT IS WORTH A TEST ═══
    --
    -- Nobody drives the diagonal. At 7,500 the two-stop answer returns as soon
    -- as the real route is about 6% longer than the straight line, and a road
    -- route between opposite corners of this map is certainly more than 6%
    -- longer than a straight line. So the rule as WRITTEN is broken and the rule
    -- as MEANT is probably fine -- which is exactly the distinction the owner
    -- needs in order to decide, and these four lines are where it is recorded.
    -- THE THRESHOLD IS 2T/D = 15,000/14,148 = 1.0602, and it is asserted from
    -- BOTH SIDES rather than approximated. 1.06 is BELOW it -- 1.06 * 14,148 is
    -- 14,997m, three metres short of two tankfuls -- and that near-miss is worth
    -- pinning: it is the difference between "about 6%" as prose and the actual
    -- number, and a test that only checked the loose side would drift.
    ok(BR.Config.Fuel.stopsPerCrossing(1.00) == 1, 'one stop on a perfect straight line')
    ok(BR.Config.Fuel.stopsPerCrossing(1.06) == 1, 'still one at a 6.0% detour, just')
    ok(BR.Config.Fuel.stopsPerCrossing(1.07) == 2, 'two again once the route is 7% longer')
    ok(BR.Config.Fuel.stopsPerCrossing(1.50) == 2, 'still two at a 50% detour')
    ok(BR.Config.Fuel.stopsPerCrossing(1.60) == 3, 'three once the detour is 60%')

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

    -- A NON-NETWORKED VEHICLE HAS NO LEDGER AT ALL. The Battle Bus is created
    -- with isNetwork = false, so the server sees a network id of 0 for it -- and
    -- 0 is truthy in Lua, so this is the assert that the guard is an explicit
    -- comparison rather than `if nid then`.
    --
    -- #191'S AMBULANCE USED TO BE IN THIS SENTENCE AND IS NOT ANY MORE. It is a
    -- networked entity as of 2026-08-23 -- it had to be, so other players can
    -- shoot it -- so it is NOT covered by this rule and never was after that
    -- change. What covers it is the exemption in the block below.
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
    roster[1].state = BR.PlayerState.OUT
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()
    moveVehicle(500, 500.0, 0.0)
    tick()
    ok(BR.Fuel.stats().tracked == 0, 'a player who is not live tracks nothing')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('ledger.rescueAmbulance')
-- ═══════════════════════════════════════════════════════════════════════════
do
    -- Owner, 2026-08-23: "we don't need to factor in fuel for the ambulance
    -- when an NPC is driving".
    --
    -- ═══ WHY THIS IS PINNED, WHEN IT ALREADY BEHAVED ═══
    --
    -- It behaved BY ACCIDENT, twice over, and both accidents belong to other
    -- features. The rescued player is ATTACHED to the stretcher rather than
    -- seated, so GetVehiclePedIsIn answers 0; and they are DBNO for the whole
    -- ride, which the LIVE gate does not admit. Either alone kept the ambulance
    -- out of the registry, so the correct behaviour rested on two facts that a
    -- change to the attach -- or to what state a ride is spent in -- would
    -- silently remove. The symptom would be an ambulance running dry halfway to
    -- the drop-off, in a vehicle the player is not driving.
    --
    -- ═══ THE FIXTURE IS THE WORST CASE, NOT THE REAL ONE, AND THAT IS THE
    --     WHOLE VALUE OF IT ═══
    --
    -- This player is SEATED, in the DRIVER'S seat, ALIVE, in a NETWORKED
    -- vehicle. That is precisely the shape the two accidents ruled out and
    -- precisely what the obvious future refactor produces. Under the old
    -- behaviour this fixture would charge a full drive; it passes now only
    -- because the exemption is written down as a rule.
    reset()
    enrol(1, 1001, 7)
    roster[1].rescue = true
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()
    drive(500, 1000.0)

    ok(BR.Fuel.stats().tracked == 0,
        'a vehicle carrying a rescue is never admitted to the ledger',
        BR.Fuel.stats().tracked)
    ok(near(BR.Fuel.left(900), TANK),
        'so an NPC-driven rescue ambulance burns nothing over a kilometre',
        ('%.1f of %.1f'):format(BR.Fuel.left(900), TANK))

    -- ═══ THE CONTROL ═══
    --
    -- The same fixture and the same drive with the flag off MUST charge.
    -- Without this, a harness that had quietly stopped driving anything at all
    -- would pass the assertions above and prove nothing whatsoever.
    reset()
    enrol(1, 1001, 7)
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()
    drive(500, 1000.0)
    ok(BR.Fuel.left(900) < TANK - 900.0,
        'and the identical drive without the flag does charge -- the exemption '
            .. 'is what is being measured, not a dead harness',
        ('%.1f of %.1f'):format(BR.Fuel.left(900), TANK))

    -- ═══ AND IT IS A WINDOW, NOT A PARDON ═══
    --
    -- server/rescue.lua's `finish` clears the flag on every ending. A player
    -- delivered back into the match drives their own car on their own fuel, so
    -- the exemption has to stop when the rescue does -- otherwise one kit buys
    -- free fuel for the rest of the match, which is a considerably better item
    -- than the one that was designed.
    reset()
    enrol(1, 1001, 7)
    roster[1].rescue = true
    makeVehicle(500, 900, 0.0, 0.0)
    seat(1, 500, -1)
    tick()
    drive(500, 500.0)
    roster[1].rescue = nil
    drive(500, 1000.0)
    ok(BR.Fuel.left(900) < TANK - 900.0,
        'once the rescue ends the same player pays for the same car again',
        ('%.1f of %.1f'):format(BR.Fuel.left(900), TANK))
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
describe('pump.gapClosed')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THE OWNER'S SECOND-PASS COMPLAINT, AS A SERVER-SIDE ASSERTION ═══
--
--   "The distance for the DUI to draw is great, but for some reason I can still
--    get gas further away from the pumps before the DUI is drawn. That's not
--    okay."                                  -- owner, 2026-08-22
--
-- The client half of the fix is a frame loop this suite cannot run, and is
-- pinned as text in `prompt.copy`. THIS is the half that can be executed: the
-- server's own permission test, which used to be stationRadius and is now
-- refuelRadius. A car parked between the two is what the owner was describing,
-- and it must now be refused.
do
    reset()
    enrol(1, 1001, 7)
    local S = BR.Config.Fuel.stations[1]
    local R = BR.Config.Fuel.refuelRadius
    local ST = BR.Config.Fuel.stationRadius

    -- Park INSIDE the old radius and OUTSIDE the new one -- the exact band the
    -- owner is complaining about. Offset on x alone so the distance is the
    -- offset, with no arithmetic to get wrong.
    local between = (R + ST) / 2.0
    makeVehicle(500, 900, S.x + between, S.y)
    seat(1, 500, -1)
    tick()
    drive(500, 500.0)
    moveVehicle(500, S.x + between, S.y)
    tick()

    local before = BR.Fuel.left(900)
    ok(before < TANK, 'the car has spent some fuel to begin with', before)

    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    ok(BR.Fuel.left(900) == before,
       ('a hold at %.1fm -- inside the old 30m, outside the new 20m -- fills nothing')
           :format(between),
       BR.Fuel.left(900) - before)

    -- AND NO CUE IS PLAYED FOR A REFUSED HOLD. The start cue sits after every
    -- refusal in the handler; if it ever drifts above one of them, a player
    -- gets a confirmation noise for a press that did nothing.
    ok(#sfxTo(1) == 0, 'and no sound is played for a refused hold', #sfxTo(1))

    -- ═══ AND THE SAME CAR, MOVED INSIDE, STILL WORKS ═══
    --
    -- The paired assertion matters as much as the refusal: a refuelRadius set
    -- so tight that nothing can ever refuel would pass the test above and break
    -- the game.
    moveVehicle(500, S.x + (R / 2.0), S.y)
    tick()
    before = BR.Fuel.left(900)
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    ok(BR.Fuel.left(900) > before,
       ('but a hold at %.1fm still fills'):format(R / 2.0),
       BR.Fuel.left(900) - before)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('pump.cues')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THREE OF THE OWNER'S SIX ASKS MEET HERE ═══
--
--   "When pressing [key] to fuel, a sound should be played."
--   "When fuel reaches 100%, a 'complete' sound should be played."
--   "All occupants of a vehicle should hear these sounds."
--                                            -- owner, 2026-08-22
--
-- The sound itself is unreachable from here -- PlaySoundFromEntity needs a game
-- -- but WHO IS TOLD and HOW OFTEN are pure server logic, and they are where the
-- bugs would be: a start cue that repeats every 250ms for the length of a hold,
-- or a completion cue only the driver hears.
do
    local S = BR.Config.Fuel.stations[1]

    reset()
    enrol(1, 1001, 7)     -- driver
    enrol(2, 1002, 7)     -- passenger
    enrol(3, 1003, 7)     -- somebody else, in the same match, in another car
    makeVehicle(500, 900, S.x, S.y)
    makeVehicle(501, 901, S.x + 200.0, S.y)
    seat(1, 500, -1)
    seat(2, 500, 0)
    seat(3, 501, -1)
    tick()
    drive(500, 3000.0)
    moveVehicle(500, S.x, S.y)
    tick()

    -- ═══ THE PRESS ═══
    clearSent()
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })

    ok(#sfxTo(1) == 1 and sfxTo(1)[1] == 'fuel.start',
       'pressing the key plays the interact cue for the driver',
       table.concat(sfxTo(1), ','))

    -- ═══ THE PASSENGER HEARS IT, WHICH IS THE WHOLE OF THE FOURTH ASK ═══
    --
    -- They are not holding anything and never sent a message. The server knows
    -- they are aboard because it re-derives that for the ledger anyway.
    ok(#sfxTo(2) == 1 and sfxTo(2)[1] == 'fuel.start',
       'and the passenger hears it too, without asking for it',
       table.concat(sfxTo(2), ','))

    -- ═══ AND NOBODY ELSE DOES ═══
    --
    --   "All occupants of a VEHICLE" -- the man in the other car is not one.
    ok(#sfxTo(3) == 0, 'and a player in a different car hears nothing',
       table.concat(sfxTo(3), ','))

    -- ═══ HOLDING IS NOT PRESSING AGAIN ═══
    --
    -- The client repeats the message every pumpSendMs for as long as the key is
    -- down. The server sees a stream, not a press, so the cue is inferred from
    -- the gap in front of it -- and a continuous hold has no gap. Getting this
    -- wrong is a machine-gun of clicks, which is the failure this asserts away.
    clearSent()
    for _ = 1, 8 do
        fakeTime = fakeTime + BR.Config.Fuel.pumpSendMs
        fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    end
    ok(#sfxTo(1) == 0, 'a continuous hold does not re-play the interact cue',
       table.concat(sfxTo(1), ','))

    -- ═══ LETTING GO AND PRESSING AGAIN IS ═══
    clearSent()
    fakeTime = fakeTime + BR.Config.Fuel.holdGapMs + 1
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    ok(#sfxTo(1) == 1 and sfxTo(1)[1] == 'fuel.start',
       'but letting go and pressing again does',
       table.concat(sfxTo(1), ','))

    -- ═══ REACHING FULL ═══
    clearSent()
    local guard = 0
    while BR.Fuel.left(900) < TANK and guard < 200 do
        fakeTime = fakeTime + BR.Config.Fuel.pumpSendMs
        fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
        guard = guard + 1
    end
    ok(BR.Fuel.left(900) == TANK, 'the tank reaches full', BR.Fuel.left(900))

    local function count(list, want)
        local n = 0
        for _, c in ipairs(list) do if c == want then n = n + 1 end end
        return n
    end

    ok(count(sfxTo(1), 'fuel.done') == 1,
       'and reaching 100% plays the complete cue exactly once',
       table.concat(sfxTo(1), ','))
    ok(count(sfxTo(2), 'fuel.done') == 1,
       'and the passenger hears that one too',
       table.concat(sfxTo(2), ','))

    -- ═══ AND HOLDING ON PAST FULL DOES NOT PLAY IT AGAIN ═══
    --
    -- It is an EDGE. A player who keeps holding for the bodywork sends four
    -- messages a second, and every one of them starts from a full tank.
    clearSent()
    for _ = 1, 6 do
        fakeTime = fakeTime + BR.Config.Fuel.pumpSendMs
        fire(BR.Net.FUEL_PUMP, 1, { n = 900 })
    end
    ok(count(sfxTo(1), 'fuel.done') == 0,
       'and holding on past full does not chime again',
       table.concat(sfxTo(1), ','))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('pump.cues.audience')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ WHO IS AN "OCCUPANT", AT THE TWO EDGES THAT ARE NOT OBVIOUS ═══
--
--   "All occupants of a vehicle should hear these sounds."
--                                            -- owner, 2026-08-22
--
-- Sitting in the seat is not the whole test, and both extra conditions are ones
-- the rest of this file already applies to everything else:
--
--   THE MATCH. Network ids are GLOBAL across routing buckets -- the teardown
--   handler in server/fuel.lua exists precisely because of that -- so a cue
--   addressed by network id alone can reach a player in a different match who
--   happens to share the number. They would hear a pump they cannot see.
--
--   THE STATE. A corpse in a seat is not an occupant. LIVE is the same pair
--   every other privileged path in this file gates on.
--
-- Both survived the first mutation round, which is why they are here.
do
    local S = BR.Config.Fuel.stations[1]

    reset()
    enrol(1, 1001, 7)     -- driver, alive, match 7
    enrol(2, 1002, 7)     -- passenger, about to be dead
    enrol(4, 1004, 7)     -- passenger, about to be in another match
    makeVehicle(500, 900, S.x, S.y)
    seat(1, 500, -1)
    seat(2, 500, 0)
    seat(4, 500, 1)
    tick()
    drive(500, 1000.0)
    moveVehicle(500, S.x, S.y)
    tick()

    -- Applied AFTER the drive, so the ledger arithmetic above is ordinary.
    roster[2].state   = BR.PlayerState.OUT
    roster[4].matchId = 8

    clearSent()
    fakeTime = fakeTime + 1000
    fire(BR.Net.FUEL_PUMP, 1, { n = 900 })

    ok(#sfxTo(1) == 1 and sfxTo(1)[1] == 'fuel.start',
       'the living driver hears the cue', table.concat(sfxTo(1), ','))
    ok(#sfxTo(2) == 0, 'a dead passenger does not', table.concat(sfxTo(2), ','))
    ok(#sfxTo(4) == 0,
       'and neither does one the roster puts in a different match',
       table.concat(sfxTo(4), ','))
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

-- ═══════════════════════════════════════════════════════════════════════════
describe('blips.seat')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THE RULE, AS THE OWNER GAVE IT TWICE ═══
--
--   "Also, while in a vehicle (any seat), all gas stations should be shown as
--    blips on the map."                            -- owner, 2026-08-21, #195
--   "passengers should only see gas station blips if the driver is in the same
--    squad. Is that a lot of compute to do each time?"
--                                                  -- owner, 2026-08-22
--
-- THE SECOND NARROWS THE FIRST WITHOUT LOSING ITS REASON. "Any seat" was never
-- about seats -- the case that made it worth having was a PASSENGER NAVIGATING
-- FOR THE DRIVER, and a passenger navigating for a stranger is not that case.
--
-- ═══ WHY THIS BLOCK EXISTS AT ALL RATHER THAN A TEXT CHECK ═══
--
-- br_core/client/fuel.lua cannot be loaded here -- see the `prompt.copy` block
-- above, which reads it as TEXT for exactly that reason. So the predicate lives
-- in br_lib/shared/fuel_solve.lua, which this suite already loads, and it is
-- PURE and TAKES ITS INPUTS. That is what makes the truth table below possible:
-- every combination of seat, squad and roster, with no game and no stub that
-- could agree with the code by construction.
do
    -- Peds are opaque handles. Distinct non-zero numbers is the whole model.
    local ME, MATE, STRANGER = 101, 202, 303

    --- The one sanctioned resolver, faked: server id -> local ped, 0 when the
    --- player is not streamed. Matches BR.Squadmates.pedOf's contract exactly,
    --- including the zero.
    local function pedMap(t)
        return function(src) return t[src] or 0 end
    end

    local squadRoster = {
        [1] = { squadId = 'sq-a' },   -- me
        [2] = { squadId = 'sq-a' },   -- my squadmate
        [3] = { squadId = 'sq-b' },   -- somebody else's squad
    }
    local peds = pedMap({ [2] = MATE, [3] = STRANGER })
    local meSquad = { src = 1, squadId = 'sq-a' }
    local meSolo  = { src = 1 }

    local V = BR.FuelSolve.blipsVisibleTo

    ok(type(V) == 'function', 'BR.FuelSolve.blipsVisibleTo exists')

    -- ═══ THE DRIVER, ALWAYS ═══
    ok(V(ME, ME, meSquad, squadRoster, peds) == true,
       'the driver sees the stations')
    ok(V(ME, ME, meSolo, {}, peds) == true,
       'and sees them in a solo match, with no squad and an empty roster -- the '
           .. 'driver test is ahead of everything about squads on purpose')
    ok(V(ME, ME, nil, nil, nil) == true,
       'and on a client whose state has not arrived yet, which is a cold start '
           .. 'rather than a fault')

    -- ═══ THE PASSENGER, BEHIND A SQUADMATE ═══
    ok(V(MATE, ME, meSquad, squadRoster, peds) == true,
       'a passenger whose DRIVER is a squadmate sees them -- the navigator '
           .. 'case, which is the whole reason "any seat" was asked for')

    -- ═══ THE PASSENGER, BEHIND ANYBODY ELSE ═══
    ok(V(STRANGER, ME, meSquad, squadRoster, peds) == false,
       "a passenger in another squad's car sees nothing")
    ok(V(999, ME, meSquad, squadRoster, peds) == false,
       'and so does a passenger behind a driver who is on no roster row at all '
           .. '-- an NPC, or a player this client has not been told about')

    -- ═══ SOLOS, WHICH THE OWNER ASKED TO HAVE SETTLED ═══
    --
    -- A solo passenger in a stranger's car sees nothing. There is no squad in a
    -- solo match, so there is no squadmate the driver could be, and the rule
    -- resolves without the predicate ever asking what kind of match this is --
    -- which is why there is no match-mode argument.
    ok(V(STRANGER, ME, meSolo, squadRoster, peds) == false,
       'a SOLO passenger in a stranger\'s car sees nothing')
    ok(V(MATE, ME, meSolo, squadRoster, peds) == false,
       'and sees nothing even behind the player who WOULD be their squadmate in '
           .. 'a squad match -- no squadId is nobody, not everybody')

    -- ═══ AND THE SAME LINE COVERS A SQUAD MATCH BEFORE SQUADS ARE FORMED ═══
    --
    -- Squads are cut at WARMUP (server/match.lua, BR.Party.formSquads). A
    -- player in the lobby or between rounds has no squadId, and neither does
    -- anybody else -- so a truth-test rather than a type-test here would make
    -- every squadless player a squadmate of every other, and a whole lobby
    -- would share one map. THE TYPE TEST IS WHAT STOPS THAT and these two pin
    -- it from both sides.
    local noSquadRoster = { [1] = {}, [2] = {}, [3] = {} }
    ok(V(MATE, ME, {}, noSquadRoster, peds) == false,
       'nobody has a squad yet, so no passenger sees anything')
    ok(V(MATE, ME, { src = 1, squadId = false }, noSquadRoster, peds) == false,
       'and a squadId that is present but not a string is still not a squad')

    -- THE ONE THAT ONLY THE TYPE TEST CATCHES, FOUND BY MUTATION. Every case
    -- above still passes if `type(squad) ~= 'string'` is relaxed to
    -- `squad == nil`, because no OTHER row shares the junk value. This is the
    -- shape that would actually ship: a build that writes the same non-string
    -- placeholder into every squadless row, at which point `e.squadId == squad`
    -- is TRUE for every stranger and the whole match shares one map.
    local junk = { [1] = { squadId = false }, [2] = { squadId = false },
                   [3] = { squadId = false } }
    ok(V(MATE, ME, { src = 1, squadId = false }, junk, peds) == false,
       'and when EVERY squadless row carries the same non-string placeholder, '
           .. 'they still do not become one squad -- the test is the TYPE, not '
           .. 'the equality')

    -- ═══ AN EMPTY DRIVER'S SEAT IS NOT A SQUADMATE, AND `0` IS TRUTHY ═══
    --
    -- THIS IS THE ONE THAT WOULD HAVE SHIPPED. GetPedInVehicleSeat answers 0
    -- for an empty seat, and BR.Squadmates.pedOf answers 0 for a player who is
    -- not streamed. In Lua `if 0 then` is TRUE -- so without the explicit zero
    -- tests those two zeroes compare EQUAL to each other, and a passenger
    -- sitting in a driverless car alongside any out-of-scope squadmate would be
    -- handed the whole map. This repository has shipped the `0`-is-truthy bug
    -- five times.
    ok(V(0, ME, meSquad, squadRoster, peds) == false,
       'a passenger in a car with an EMPTY driver seat sees nothing')
    ok(V(0, 0, meSquad, squadRoster, pedMap({})) == false,
       'and two zeroes -- an empty seat and an unstreamable ped -- do not '
           .. 'satisfy the driver test by comparing equal to each other')
    ok(V(0, ME, meSquad, squadRoster, pedMap({ [2] = 0 })) == false,
       'nor does an empty seat match a squadmate the engine cannot place')
    ok(V(MATE, 0, meSquad, squadRoster, peds) == false,
       'and a client that cannot read its OWN ped shows nothing rather than '
           .. 'guessing')
    ok(V(nil, ME, meSquad, squadRoster, peds) == false,
       'a nil seat read is refused the same way a zero is')

    -- ═══ OUR OWN ROW IS SKIPPED ═══
    --
    -- The roster contains this player, and their squadId equals their own by
    -- definition. Without the `src ~= me.src` guard the loop would ask pedOf
    -- about ourselves -- harmless only by coincidence today, and this pins the
    -- guard so the coincidence is not what is relied on.
    ok(V(ME, 999, meSquad, squadRoster, pedMap({ [1] = ME })) == false,
       'a driver who is ME-by-ped but not this player\'s own ped does not pass '
           .. 'through our own roster row')

    -- ═══ MISSING COLLABORATORS FAIL TOWARDS NO BLIPS ═══
    --
    -- client/squadmates.lua may not have loaded, the roster may not have
    -- arrived, and a passenger is the case where a wrong answer LEAKS
    -- information. Every one of these is a real cold-start state, and the safe
    -- direction is the same in all of them.
    ok(V(MATE, ME, meSquad, squadRoster, nil) == false,
       'no ped resolver, no blips')
    ok(V(MATE, ME, meSquad, nil, peds) == false,
       'no roster, no blips')
    ok(V(MATE, ME, 'not a table', squadRoster, peds) == false,
       'and a junk `me` is refused rather than indexed')

    -- ═══ THE DRIVER CHANGING MID-DRIVE IS NOT A CASE, AND THAT IS THE POINT ═══
    --
    -- The predicate is a pure function of the seat as it is RIGHT NOW, so the
    -- caller re-deriving it on the 10 Hz tick is the whole of "the driver
    -- changed seat or left". There is no transition to enumerate and therefore
    -- none to forget. Here it is as a sequence anyway, because that is the
    -- owner's actual question.
    ok(V(MATE, ME, meSquad, squadRoster, peds) == true
       and V(0, ME, meSquad, squadRoster, peds) == false
       and V(STRANGER, ME, meSquad, squadRoster, peds) == false
       and V(MATE, ME, meSquad, squadRoster, peds) == true,
       'squadmate drives, bails out, a stranger takes the wheel, the squadmate '
           .. 'comes back -- on, off, off, on, with nothing cached in between')

    -- ═══ AND THE CALLER REALLY TAKES BOTH BRANCHES ═══
    --
    -- A visibility rule that only knows how to turn a thing ON leaves it on.
    -- client/fuel.lua cannot be executed here, so this is TEXT -- but the
    -- specific defect it guards is `if visible then showBlips() end` with no
    -- else, which would leave every station on a passenger's map for the rest
    -- of a drive after their squadmate got out, with no event to take them down.
    local fh = io.open(ROOT .. 'br_core/client/fuel.lua', 'r')
    ok(fh ~= nil, 'client/fuel.lua is readable')
    if fh then
        local src = fh:read('a'); fh:close()
        local code = src:gsub('%-%-%[%[.-%]%]', ' '):gsub('%-%-[^\n]*', '')
        ok(code:find('BR.FuelSolve.blipsVisibleTo', 1, true) ~= nil,
           'the tick asks the predicate rather than carrying its own copy of '
               .. 'the rule')
        local at = code:find('BR.FuelSolve.blipsVisibleTo', 1, true)
        local after = at and code:sub(at, at + 400) or ''
        ok(after:find('showBlips()', 1, true) ~= nil
           and after:find('hideBlips()', 1, true) ~= nil,
           'and BOTH branches are written -- a rule with no else-branch leaves '
               .. 'the blips up forever once they are up')
        -- AND THE SEAT IS READ FRESH RATHER THAN REMEMBERED. A cached driver is
        -- what would make "the driver changed seat" a case that needs handling.
        ok(code:find('pcall(GetPedInVehicleSeat, veh, -1)', 1, true) ~= nil,
           'the driver seat is read from the engine on the tick, guarded, and '
               .. 'not held between ticks')
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('pump.cues.completion')
-- ═══════════════════════════════════════════════════════════════════════════
--
--   "the noise we're playing when fueling finishes is more like a warning
--    sound than a complete/confirmation sound. That should be changed."
--                                                  -- owner, 2026-08-22
--
-- ═══ WHAT THIS CAN PROVE AND WHAT ONLY A CLIENT CAN ═══
--
-- IT CANNOT PROVE THE NEW SOUND READS AS A CONFIRMATION. That is a judgement
-- about audio and it belongs to whoever is wearing the headphones -- `/brsfx
-- fuel.done` is how they make it.
--
-- WHAT IT PINS is the two facts a later edit could quietly get wrong: the
-- rejected sound does not come back, and the START sound -- which the owner
-- listened to and KEPT -- is not "improved" while somebody is in here changing
-- its neighbour. The block above already asserts both cues exist, carry both
-- fields, and collide with nothing.
do
    local cues = BR.Config.Audio and BR.Config.Audio.cues or {}
    local done  = cues['fuel.done'] or {}
    local start = cues['fuel.start'] or {}

    ok(done.name ~= 'CHALLENGE_UNLOCKED',
       'the sound the owner heard as a warning is gone', tostring(done.name))

    -- ═══ THIS ASSERTION USED TO READ `done.set == 'HUD_AWARDS'` AND WAS
    --     DELIBERATELY LOOSENED, 2026-08-22 ═══
    --
    -- It was right while the fix was "change the NAME inside the one set the
    -- owner had demonstrably heard". It became wrong the moment the owner was
    -- handed /brsfx and told to go and choose: the third pick is theirs, it may
    -- legitimately land in HUD_MINI_GAME_SOUNDSET or anywhere else, and a test
    -- that reddened the build for the owner exercising the tool built for them
    -- would simply be deleted by whoever landed their choice. A gate people
    -- route around protects nothing.
    --
    -- WHAT REPLACES IT IS THE PROPERTY THAT ACTUALLY MATTERED ALL ALONG, and it
    -- is stronger in the direction that has cost real rounds: the set must be
    -- one of the 84 in BR.Config.Audio.catalogue. Those are the sets GTA's own
    -- scripts call, with every DLC_*/dlc_* bank filtered out -- which is exactly
    -- the check that would have rejected Pit_Stop_Complete (a real name, in a
    -- real set, in a script audio bank this gamemode never requests, and
    -- therefore silent). A wrong SET is the failure mode here; a name inside a
    -- loaded set is at worst a sound somebody dislikes.
    local inCatalogue = false
    for _, entry in ipairs(BR.Config.Audio.catalogue or {}) do
        if entry.set == done.set then inCatalogue = true end
    end
    ok(inCatalogue,
       'and whatever it is, its SET is one GTA\'s own scripts play -- so the '
           .. 'third pick can be any sound the owner likes, but not a DLC bank '
           .. 'that would be silent',
       tostring(done.set))

    -- THE START SOUND IS OWNER-CONFIRMED AND IS NOT TO BE TOUCHED.
    ok(start.set == 'HUD_FRONTEND_DEFAULT_SOUNDSET' and start.name == 'SELECT',
       'and the START cue is untouched -- the owner heard it and kept it, so it '
           .. 'is not collateral in a change to the other one',
       tostring(start.set) .. '/' .. tostring(start.name))

    -- AUDITIONABLE THE SAME WAY, AND NOTHING HAD TO BE ADDED FOR IT. /brsfx
    -- takes any key in this table, so `/brsfx fuel.done` plays whatever is
    -- configured. That is only true while the cue is reached BY KEY -- a
    -- name/set pair inlined at the call site would be unauditionable, which is
    -- the state config/audio.lua's header exists to prevent.
    local fh = io.open(ROOT .. 'br_core/client/sfx.lua', 'r')
    if fh then
        local sfx = fh:read('a'); fh:close()
        -- THE SPELLING MOVED WHEN /brsfx GREW SUBCOMMANDS -- `args[1]` is read
        -- into `verb` first, because the first word now decides between a cue
        -- key, a sound set and a subcommand. Both halves are pinned so the
        -- lookup cannot quietly stop being driven by what was typed.
        ok(sfx:find('local verb = args[1]', 1, true) ~= nil,
           '/brsfx still reads its first word from the command line')
        ok(sfx:find('BR.Config.Audio.cues[verb]', 1, true) ~= nil,
           "/brsfx still resolves any cue by key, so `/brsfx fuel.done` "
               .. 'auditions whatever this table says')

        -- ═══ AND THE OWNER CAN NOW CHANGE IT WITHOUT A CODE EDIT ═══
        --
        -- The third fuel sound is theirs to pick by ear, and picking by ear
        -- means hearing it AT A PUMP rather than in a menu. `bind` re-points a
        -- cue for the session so the next tank plays the candidate. It writes
        -- nothing, which is the honest half and is why the command says so.
        ok(sfx:find("BR.Config.Audio.cues[cue] = { set = set, name = name }", 1, true) ~= nil,
           'and `brsfx bind <cue> <SET> <NAME>` re-points a cue live, so the '
               .. 'candidate can be judged where it actually fires')
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('repairkit.reuse')
-- ═══════════════════════════════════════════════════════════════════════════
--
--   "Repair kit should spawn in loot crates, inventory item, maxCarry 1, can
--    be used on the fly to repair any vehicle once."   -- owner, 2026-08-23
--
-- ═══ THE PROPERTY IS "ONE IMPLEMENTATION, TWO CALLERS" ═══
--
-- The station already restores the three health pools in the order they have to
-- go in -- ENGINE FIRST, because SetVehicleFixed is documented not to fix a
-- broken one -- then pops the deformation and washes the decals. A repair kit
-- that carried its own copy of that sequence would be a second place for the
-- ordering to be got wrong, and the wrong one would be the one nobody had
-- played. So the kit's handler must CALL applyRepair rather than reimplement it.
--
-- TEXT, for the reason the prompt.copy block above gives at length:
-- client/fuel.lua registers frame-band loops and calls a dozen client natives
-- this suite does not stub, and stubbing them to reach one call would be a
-- harness bigger than the file. What a pass proves is that the second caller
-- exists and goes through the shared function; it cannot prove a car looks
-- repaired, which needs a game.
do
    local fh = io.open(ROOT .. 'br_core/client/fuel.lua', 'r')
    ok(fh ~= nil, 'client/fuel.lua is readable')
    if fh then
        local src = fh:read('a'); fh:close()
        local code = src:gsub('%-%-%[%[.-%]%]', ' '):gsub('%-%-[^\n]*', '')

        ok(code:find('AddEventHandler(BR.Net.VEH_FIX', 1, true) ~= nil,
           'the client listens for the repair grant')

        -- ═══ THERE IS EXACTLY ONE applyRepair, AND TWO CALLS OF IT ═══
        --
        -- Counted rather than merely found, and this is the assertion that
        -- actually carries the property: a second DEFINITION is how the
        -- ordering rule gets forked, and a handler that repaired without
        -- calling it would show up as one call rather than two.
        local defs = 0
        for _ in code:gmatch('local function applyRepair%(') do defs = defs + 1 end
        ok(defs == 1, ('there is one repair implementation in the file (saw %d)')
            :format(defs))

        -- MINUS THE DEFINITION, WHICH IS ALSO A `applyRepair(veh,`. The first
        -- spelling of this counted the name and reported three callers for two,
        -- which is the same trap test_shop.lua's `BR.Shop.unpack` assertion fell
        -- into: a mention is not a call.
        local mentions = 0
        for _ in code:gmatch('applyRepair%(veh,') do mentions = mentions + 1 end
        ok(mentions - defs == 2,
           ('and both callers go through it -- the pump grant and the repair '
            .. 'kit (saw %d)'):format(mentions - defs))

        -- ═══ AND THE KIT'S CALLER IS INSIDE THE VEH_FIX HANDLER ═══
        --
        -- Two calls somewhere in a 1300-line file is not the same statement as
        -- "the handler repairs". Anchored on the handler's own opening so this
        -- cannot pass on a build where the second call drifted into the tick.
        local at = code:find('AddEventHandler(BR.Net.VEH_FIX', 1, true)
        local body = at and code:sub(at, at + 700) or ''
        ok(body:find('applyRepair(veh, points)', 1, true) ~= nil,
           'the VEH_FIX handler hands its grant to the shared function')

        -- ═══ ...AND IT DOES NOTHING ELSE TO THE CAR ═══
        --
        -- fixCosmetic's NAME IS A LIE ABOUT ITS FIRST LINE. It calls
        -- SetVehicleFixed, which is a FULL repair native; only the deformation
        -- and decal calls after it are cosmetic-only. That is harmless in the
        -- one place it is called from -- inside applyRepair, on the frame
        -- `body >= cap` has just been proven, where a full repair is a no-op --
        -- and it is a free repair anywhere else. A build of the kit called it
        -- unconditionally at completion, off a flag on the wire, which put a
        -- damaged car back to full outside every rule that grants health.
        --
        -- COUNTED, MINUS THE DEFINITION, for the same reason the applyRepair
        -- count above is: a mention is not a call, and `local function
        -- fixCosmetic(veh)` matches the same pattern its callers do.
        local cdefs = 0
        for _ in code:gmatch('local function fixCosmetic%(') do
            cdefs = cdefs + 1
        end
        local ccalls = 0
        for _ in code:gmatch('fixCosmetic%(veh%)') do ccalls = ccalls + 1 end
        ok(cdefs == 1 and ccalls - cdefs == 1,
           ('and fixCosmetic has exactly ONE caller -- applyRepair, gated on '
            .. 'the body reaching the cap (saw %d)'):format(ccalls - cdefs))

        -- ═══ IT CHECKS THE CAR IT WAS SENT ═══
        --
        -- Between the server ruling and this arriving, a player can leave the
        -- seat. Repairing whatever they are in NOW would spend a kit on a car
        -- nobody aimed it at, so the network id on the wire is compared and a
        -- mismatch does nothing.
        ok(body:find('netOf(veh) ~= nid', 1, true) ~= nil,
           'and refuses a vehicle that is not the one the server named')

        -- 0 IS TRUTHY IN LUA. IsPedInAnyVehicle is declared BOOL; a bare read
        -- here would repair for a player standing in a field.
        ok(body:find('didHit(IsPedInAnyVehicle(ped, false))', 1, true) ~= nil,
           'and reads the BOOL native through didHit rather than bare')

        -- ═══ NO SECOND FUEL LEDGER ═══
        --
        -- The grant deliberately does NOT ride FUEL_SET: that message carries
        -- the ledger's fraction and metres, and a client that receives one
        -- writes them into `known`. A repair kit must not tell a client
        -- anything about its tank.
        ok(body:find('known[', 1, true) == nil,
           'and it touches the fuel ledger not at all')
    end
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
