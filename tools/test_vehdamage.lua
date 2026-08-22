-- Unit tests for #213: how breakable a car is, and the one number that decides.
--
-- ═══ WHY THIS IS A SUITE AND NOT THREE ASSERTIONS SOMEWHERE ELSE ═══
--
-- The arithmetic is four lines and could live in test_shared. The property
-- worth a suite is not the multiplication -- it is THE APPLIER NEVER COMPOUNDS,
-- and that needs the config, the pure scale and the real client file driven
-- through the real loop registry, against a world that models the one thing
-- that makes compounding possible.
--
-- ═══ THE FIXTURE MODELS FiveM's CLONE-ON-SPAWN, AND THAT IS THE WHOLE POINT
--     ═══
--
-- FiveM gives every vehicle a private copy of its model's CHandlingData when the
-- entity is constructed (`vehicle->SetHandlingData(new CHandlingData(handling))`
-- in handling-loader-five), and GET_VEHICLE_HANDLING_FLOAT reads that copy. So
-- reading a field back after writing it returns OUR value, not the model's.
--
-- A stub where GET always answered the model's stock number would agree happily
-- with an applier that read-modify-writes -- and that applier multiplies by five
-- every hundred milliseconds until a car dissolves on a kerb. So `template` and
-- `handling` are two tables here, `spawn` copies one into the other, and GET
-- reads the copy. That is rule 4 in docs/testing.md: a fixture that cannot tell
-- the right implementation from the wrong one proves nothing.
--
-- ═══ WHAT THIS DELIBERATELY DOES NOT COVER ═══
--
-- Everything that needs the engine to be honest. Whether a 5x collision
-- multiplier makes a car die at a speed that FEELS right; whether the engine
-- really computes collision damage out of the owner's handling copy; whether
-- SET_VEHICLE_HANDLING_FLOAT is accepted at all on the pinned build
-- (citizenfx/fivem#1754 has it raising on an ordinary call, closed with no fix).
-- None of those is a question a Lua process can be asked. `/brvehdamage` prints
-- the three numbers that answer the last one on a live server, and the first is
-- named in the report as a playtest question rather than pretended at here.
--
-- Run:  lua tools/test_vehdamage.lua        (or via tools/verify.sh)

local realPrint = print
function print() end

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function RegisterNetEvent() end
function TriggerEvent() end
function TriggerServerEvent() end

Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

local commands = {}
function RegisterCommand(n, fn) commands[n] = fn end

-- ---------------------------------------------------------------------------
-- The world
-- ---------------------------------------------------------------------------

--- Stock handling per MODEL -- the template the engine clones from.
local template = {}
--- Effective handling per VEHICLE -- the clone. What GET actually reads.
local handling = {}
local vehModel = {}

--- Every SetVehicleHandlingFloat of the session, in order.
local writes = {}

--- Knobs for the failure paths. Both reproduce real platform behaviour:
--- `getThrows` is a build where the native binding is missing or unhappy, and
--- `setThrows` is citizenfx/fivem#1754 exactly.
local getThrows, setThrows = false, false

local MODEL_A = 0x1B38E955      -- stands in for an ordinary car
local MODEL_B = 0x4C80EB0E      -- ...and a second, different one
local MODEL_TOUGH = 0x7BADCAFE  -- one whose stock values are already high

template[MODEL_A] = {
    fCollisionDamageMult   = 1.0,
    fDeformationDamageMult = 0.8,
    fEngineDamageMult      = 1.5,
    fWeaponDamageMult      = 1.0,
}
template[MODEL_B] = {
    fCollisionDamageMult   = 0.7,
    fDeformationDamageMult = 0.7,
    fEngineDamageMult      = 1.5,
    fWeaponDamageMult      = 1.0,
}
template[MODEL_TOUGH] = {
    fCollisionDamageMult   = 3.0,
    fDeformationDamageMult = 0.8,
    fEngineDamageMult      = 2.5,
    fWeaponDamageMult      = 1.0,
}

--- Construct a vehicle, which is what takes the clone. Called again for the
--- same handle to model a stream-out and stream-in: the entity is rebuilt, so
--- the clone is taken from the template again and any override is gone.
local function spawn(veh, model)
    vehModel[veh] = model
    handling[veh] = {}
    for k, v in pairs(template[model] or {}) do handling[veh][k] = v end
end

function GetEntityModel(veh) return vehModel[veh] or 0 end

function GetVehicleHandlingFloat(veh, class, field)
    if getThrows then error('no such native') end
    if class ~= 'CHandlingData' then error('unsupported handling class') end
    local h = handling[veh]
    if not h then error('Tried to access invalid entity') end
    return h[field]
end

function SetVehicleHandlingFloat(veh, class, field, value)
    if setThrows then error('Error executing native at handling-loader-five') end
    if class ~= 'CHandlingData' then error('unsupported handling class') end
    local h = handling[veh]
    if not h then error('Tried to access invalid entity') end
    h[field] = value
    writes[#writes + 1] = { veh = veh, field = field, value = value }
end

--- Where the local player is. `IsPedInAnyVehicle` ANSWERS A NUMBER, NOT A
--- BOOLEAN, on purpose: that is the build shape that makes `0` truthy bite,
--- which this project has shipped four times, so the file under test has to
--- normalise it.
---
--- `asks` COUNTS GetVehiclePedIsIn, AND MUTATION TESTING IS WHY IT EXISTS. A
--- version that wrote `if not IsPedInAnyVehicle(ped) then` survived the
--- assertion below on writes alone -- `not 0` is false in Lua, so it fell
--- through, asked for the vehicle, got 0, and was saved by the `veh == 0` guard
--- underneath. The two guards are deliberately redundant (server/fuel.lua makes
--- the same belt-and-braces argument about its own pair), and redundancy is
--- exactly what makes a mutant invisible if the only thing measured is the
--- outcome. So the question asked here is the stricter one: a player on foot is
--- never asked which vehicle they are in.
local myVeh, entering = 0, 0
local asks = 0
function PlayerPedId() return 77 end
function IsPedInAnyVehicle() return myVeh ~= 0 and 1 or 0 end
function GetVehiclePedIsIn() asks = asks + 1 return myVeh end
function GetVehiclePedIsEntering() return entering end

-- ---------------------------------------------------------------------------
-- Modules
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
    -- BEFORE config/vehicles.lua AND NOT MERELY NEAR IT, which is the manifest's
    -- own ordering and its own reason: that file calls BR.NormHash at LOAD time
    -- to build its hash-keyed lookup.
    'br_lib/shared/geo.lua',
    'br_lib/config/vehicles.lua',
    'br_core/client/main.lua',      -- the loop registry; must precede the file
    'br_core/client/vehdamage.lua',
}) do load(f) end

local C = BR.Config.VehicleDamage
local V = BR.VehDamage

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
    return math.abs((tonumber(a) or 0) - (tonumber(b) or 0)) <= (eps or 1e-6)
end

--- One pass of the applier, in the band it is registered on.
local function tick(times)
    for _ = 1, (times or 1) do
        fakeTime = fakeTime + 100
        BR.Loop.step(BR.Loop.TICK)
    end
end

local function reset()
    handling, vehModel, writes = {}, {}, {}
    myVeh, entering, asks = 0, 0, 0
    getThrows, setThrows = false, false
    C.enabled = true
    C.multiplier = 5.0
    C.weaponMultiplier = 1.0
    C.ceiling = 10.0
    C.maxModels = 64
    V.reset()
end

--- What the engine currently holds for one field of one vehicle.
local function held(veh, field)
    return (handling[veh] or {})[field]
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the numbers')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE CONFIG IS UNDER TEST HERE, NOT JUST THE ARITHMETIC. A suite that only
-- exercised `scale` would pass just as happily on a multiplier of 1.0, which is
-- the feature doing nothing at all -- and doing nothing is indistinguishable in
-- game from the bug #213 is about.

ok(C.enabled == true, 'the feature ships switched on', tostring(C.enabled))
ok(C.multiplier == 5.0, 'a car takes five times the damage GTA gives it',
   C.multiplier)
ok(C.multiplier > 1.0,
   'and that is strictly more than stock -- the whole request',
   'a multiplier at or below 1.0 makes vehicles no more breakable than base GTA')
ok(C.weaponMultiplier == 1.0,
   'bullet damage is deliberately unchanged -- it was not what was asked for',
   C.weaponMultiplier)
ok(C.ceiling == 10.0, 'and nothing is written above GTA\'s documented range top',
   C.ceiling)
ok(BR.Config.VehicleDamageRangeMax == 10.0,
   'which is also the fallback the scale uses when the ceiling is nonsense')
ok(C.class == 'CHandlingData',
   'the only handling class the native supports', C.class)

-- ═══ THE ONE NUMBER IS ONE NUMBER ═══
--
-- The owner will ask for "more" or "less" as a single value, so exactly one key
-- may decide the three fields the request is about. This is the assertion that
-- fails the day somebody splits collision and deformation into two knobs
-- without saying so.
do
    local scaled, absolute = {}, {}
    for i = 1, #C.fields do
        local f = C.fields[i]
        if f.from == 'multiplier' then scaled[#scaled + 1] = f.field
        else absolute[#absolute + 1] = f.field end
    end
    ok(#C.fields == 4, 'four handling fields are written', #C.fields)
    ok(#scaled == 3, 'and three of them read the one number', #scaled)
    ok(#absolute == 1 and absolute[1] == 'fWeaponDamageMult',
       'the fourth is the weapon multiplier and reads its own',
       table.concat(absolute, ','))
    for _, want in ipairs({ 'fCollisionDamageMult', 'fDeformationDamageMult',
                            'fEngineDamageMult' }) do
        local found = false
        for _, got in ipairs(scaled) do if got == want then found = true end end
        ok(found, want .. ' is scaled by the one number')
    end
    -- EVERY ROW NAMES A REAL CONFIG KEY. `from` is an indirection, and an
    -- indirection into a key that does not exist reads as nil, which `scale`
    -- turns into 1.0 -- a field silently left at stock with nothing saying so.
    for i = 1, #C.fields do
        local f = C.fields[i]
        ok(type(C[f.from]) == 'number',
           f.field .. ' names a multiplier that exists', tostring(f.from))
        ok(type(f.governs) == 'string' and #f.governs > 0,
           f.field .. ' says what it governs, for /brvehdamage')
    end
end

-- ═══ THE HEADROOM CLAIM IN THE CONFIG IS ARITHMETIC, SO IT IS CHECKED ═══
--
-- config/vehicles.lua says the shipped multiplier clamps nothing on an ordinary
-- model and that the engine field meets the ceiling at about 6.6. Both are
-- statements about numbers in that file, so neither gets to rot.
ok(select(2, C.scale(1.5, C.multiplier, C.ceiling)) == false,
   'the shipped multiplier clamps nothing on a typical engine value',
   C.scale(1.5, C.multiplier, C.ceiling))
ok(select(2, C.scale(1.5, 6.0, C.ceiling)) == false,
   'nor at six')
ok(select(2, C.scale(1.5, 7.0, C.ceiling)) == true,
   'and it does clamp at seven -- which is what the headroom note claims')

-- ═══════════════════════════════════════════════════════════════════════════
describe('scale')
-- ═══════════════════════════════════════════════════════════════════════════

ok(near(C.scale(1.0, 5.0, 10.0), 5.0), 'multiplies the model\'s own value')
ok(near(C.scale(0.7, 5.0, 10.0), 3.5), 'whatever that value is')
ok(near(C.scale(1.5, 5.0, 10.0), 7.5), 'including the engine field')

-- THE CEILING, AND IT REPORTS ITSELF. A clamp nobody can see is a knob that has
-- silently stopped working; /brvehdamage counts these.
do
    local v, clamped = C.scale(2.5, 5.0, 10.0)
    ok(near(v, 10.0), 'a value over the ceiling comes back as the ceiling', v)
    ok(clamped == true, 'and says so', tostring(clamped))
end
ok(select(2, C.scale(1.0, 5.0, 10.0)) == false,
   'a value under it does not claim to have been clamped')

-- ═══ A BAD STOCK LEAVES THE FIELD ALONE ═══
--
-- nil rather than a number, because there is no value to invent for a field the
-- engine would not report. GTA's own is the only answer that cannot be wrong.
ok(C.scale(nil, 5.0, 10.0) == nil, 'a missing stock value scales to nothing')
ok(C.scale(0 / 0, 5.0, 10.0) == nil, 'and so does a NaN one')
ok(C.scale(-1.0, 5.0, 10.0) == nil, 'and so does a negative one')
ok(C.scale('bananas', 5.0, 10.0) == nil, 'and so does one that is not a number')
ok(near(C.scale(0.0, 5.0, 10.0), 0.0),
   'but a model that is immune by design stays immune -- zero is a real value')

-- ═══ A BAD MULTIPLIER COSTS THE FEATURE AND NEVER REVERSES IT ═══
--
-- BR.BoostSolve.target learned this from mutation testing and states the rule:
-- a config typo must cost the feature, never invert it. A negative multiplier
-- here would write a negative damage multiplier into handling, and nobody knows
-- what the engine does with one.
ok(near(C.scale(1.0, nil, 10.0), 1.0), 'a missing multiplier leaves it at stock')
ok(near(C.scale(1.0, 0 / 0, 10.0), 1.0), 'and so does a NaN one')
ok(near(C.scale(2.0, -5.0, 10.0), 2.0),
   'and a NEGATIVE one is 1.0, not a sign flip')
ok(near(C.scale(1.0, 0.5, 10.0), 0.5),
   'but below 1.0 is a legitimate direction -- tougher cars, on request')
ok(near(C.scale(1.0, 0.0, 10.0), 0.0),
   'and zero is honoured here; the applier is what refuses to run on it')

-- ═══ A BAD CEILING FALLS BACK TO THE DOCUMENTED RANGE, NEVER TO NO CEILING ═══
do
    local M = BR.Config.VehicleDamageRangeMax
    ok(near(C.scale(5.0, 5.0, nil), M), 'a missing ceiling is the range top')
    ok(near(C.scale(5.0, 5.0, 0.0), M), 'and so is a zero one')
    ok(near(C.scale(5.0, 5.0, -3.0), M), 'and so is a negative one')
    ok(near(C.scale(5.0, 5.0, 0 / 0), M), 'and so is a NaN one')
    ok(select(2, C.scale(5.0, 5.0, nil)) == true,
       'and the fallback still reports the clamp')
end

-- NEVER NaN OUT, whatever went in, because a NaN in handling is a car whose
-- damage calculation nobody can predict.
for _, s in ipairs({ 0.0, 0.7, 1.0, 1.5, 3.0, 9.9 }) do
    for _, m in ipairs({ 0.0, 0.5, 1.0, 5.0, 999.0 }) do
        local v = C.scale(s, m, 10.0)
        ok(v ~= nil and v == v and v >= 0.0 and v <= 10.0,
           'every plausible pair lands inside the range',
           ('stock %s x %s -> %s'):format(s, m, tostring(v)))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the applier')
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    spawn(10, MODEL_A)

    -- ON FOOT IS THE IDLE PATH AND IT WRITES NOTHING.
    tick(5)
    ok(#writes == 0, 'a player on foot has nothing done to any vehicle', #writes)
    ok(near(held(10, 'fCollisionDamageMult'), 1.0),
       'and the car beside them is stock', held(10, 'fCollisionDamageMult'))

    myVeh = 10
    tick()
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'sitting in it scales collision by the one number',
       held(10, 'fCollisionDamageMult'))
    ok(near(held(10, 'fDeformationDamageMult'), 4.0),
       'and deformation', held(10, 'fDeformationDamageMult'))
    ok(near(held(10, 'fEngineDamageMult'), 7.5),
       'and the engine -- which is what total failure means',
       held(10, 'fEngineDamageMult'))
    ok(near(held(10, 'fWeaponDamageMult'), 1.0),
       'and leaves bullets exactly where GTA had them',
       held(10, 'fWeaponDamageMult'))
    ok(V.stats().models == 1, 'one model baseline is held', V.stats().models)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the applier does not compound')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE ONE THAT MATTERS. GET_VEHICLE_HANDLING_FLOAT answers the vehicle's own
-- clone, which is our write once we have made one -- so an applier that read the
-- field and multiplied it would multiply by five every hundred milliseconds. At
-- 10 Hz that is 5^10 within a second, and the symptom in game is a car that
-- disintegrates against a kerb for reasons nothing logs.

do
    reset()
    spawn(10, MODEL_A)
    myVeh = 10

    tick(200)   -- twenty seconds of driving
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'two hundred passes leave collision exactly where one pass did',
       held(10, 'fCollisionDamageMult'))
    ok(near(held(10, 'fEngineDamageMult'), 7.5),
       'and the engine too', held(10, 'fEngineDamageMult'))
    ok(V.stats().models == 1,
       'and the baseline was read once, not two hundred times',
       V.stats().models)

    -- ═══ AND A SECOND CAR OF THE SAME MODEL IS NOT BASELINED OFF THE FIRST ═══
    --
    -- The subtler half. Even an applier that scaled from a per-vehicle baseline
    -- would be correct above; this is the case that separates "cache the
    -- baseline" from "cache the baseline PER MODEL, before writing". Vehicle 10
    -- is now sitting at 5.0, and if getting into a fresh Granger re-read the
    -- stock value off any modified Granger, the second car would come out at 25.
    spawn(11, MODEL_A)
    myVeh = 11
    tick(3)
    ok(near(held(11, 'fCollisionDamageMult'), 5.0),
       'a second car of the same model gets five, not twenty-five',
       held(11, 'fCollisionDamageMult'))

    -- ═══ AND A STREAM-OUT / STREAM-IN IS REPAIRED RATHER THAN COMPOUNDED ═══
    --
    -- The clone is taken from the template when the entity is constructed, so a
    -- car that leaves scope and comes back is holding stock values again and our
    -- override is gone. Re-applying every tick is what fixes it -- and it must
    -- fix it back to 5.0.
    spawn(10, MODEL_A)
    ok(near(held(10, 'fCollisionDamageMult'), 1.0),
       'a re-streamed car really has lost the override', held(10, 'fCollisionDamageMult'))
    myVeh = 10
    tick(3)
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'and the next pass puts it back -- once, not on top of itself',
       held(10, 'fCollisionDamageMult'))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('per model')
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    spawn(10, MODEL_A)
    spawn(20, MODEL_B)
    spawn(30, MODEL_TOUGH)

    myVeh = 10; tick(2)
    myVeh = 20; tick(2)
    myVeh = 30; tick(2)

    ok(V.stats().models == 3, 'three models, three baselines', V.stats().models)
    ok(near(held(10, 'fCollisionDamageMult'), 5.0), 'model A scales from 1.0')
    ok(near(held(20, 'fCollisionDamageMult'), 3.5),
       'model B scales from its own 0.7, not from A\'s',
       held(20, 'fCollisionDamageMult'))

    -- ═══ THE PER-MODEL DIFFERENCES SURVIVE, WHICH IS WHY IT IS RELATIVE ═══
    --
    -- config/vehicles.lua's own note about the plain Insurgent -- "the rule the
    -- owner wrote is about built-in weapons, not about durability" -- stays true
    -- only if a tough model stays relatively tough. An absolute write would
    -- flatten every model onto one number and quietly settle a balance question
    -- nobody asked.
    ok(held(30, 'fCollisionDamageMult') > held(10, 'fCollisionDamageMult'),
       'a model with a higher stock value is still relatively tougher',
       ('%s vs %s'):format(held(30, 'fCollisionDamageMult'),
                           held(10, 'fCollisionDamageMult')))

    -- ...AND THE CEILING BITES ON THE ONE THAT NEEDS IT. 2.5 x 5 is 12.5, which
    -- is outside the range the engine was tuned for.
    ok(near(held(30, 'fEngineDamageMult'), 10.0),
       'and a model that would exceed the range is capped at it',
       held(30, 'fEngineDamageMult'))
    ok(V.stats().clamped > 0, 'and the cap is counted for /brvehdamage',
       V.stats().clamped)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('when it must not run')
-- ═══════════════════════════════════════════════════════════════════════════

-- SWITCHED OFF MEANS STOCK GTA, not half applied.
do
    reset()
    C.enabled = false
    spawn(10, MODEL_A)
    myVeh = 10
    tick(5)
    ok(#writes == 0, 'disabled writes nothing at all', #writes)
    ok(near(held(10, 'fCollisionDamageMult'), 1.0), 'and the car is stock')
end

-- ═══ A MULTIPLIER OF ZERO SWITCHES THE FEATURE OFF, IT DOES NOT MAKE CARS
--     INVULNERABLE ═══
--
-- 0.0 is a legal handling value meaning "immune", so the naive reading of a
-- config typo here is the exact opposite of the feature -- and it would present
-- as "the change didn't work", which is the failure nobody debugs.
do
    reset()
    C.multiplier = 0.0
    spawn(10, MODEL_A)
    myVeh = 10
    tick(5)
    ok(#writes == 0, 'a zero multiplier writes nothing rather than zero', #writes)
    ok(near(held(10, 'fCollisionDamageMult'), 1.0),
       'so the car is GTA\'s, not immortal', held(10, 'fCollisionDamageMult'))
end
do
    reset()
    C.multiplier = -5.0
    spawn(10, MODEL_A)
    myVeh = 10
    tick(5)
    ok(#writes == 0, 'and so does a negative one', #writes)
end

-- ═══ `0` IS TRUTHY IN LUA, AND IsPedInAnyVehicle IS DECLARED BOOL ═══
--
-- The stub answers 0 and 1 rather than false and true, which is the build shape
-- this project has shipped the bug against four times. An applier that wrote
-- `if IsPedInAnyVehicle(ped) then` would reach GetVehiclePedIsIn for a player
-- standing in a field.
do
    reset()
    spawn(10, MODEL_A)
    myVeh = 0
    ok(IsPedInAnyVehicle() == 0, 'the fixture answers a number, as builds do')
    tick(5)
    ok(#writes == 0, 'and a numeric zero is read as "not in a vehicle"', #writes)
    -- THE STRICTER QUESTION, AND THE ONE A MUTANT CANNOT SLIP PAST. See `asks`.
    ok(asks == 0,
       'and the player on foot is never even asked which vehicle they are in',
       asks)

    -- ...AND A NUMERIC ONE IS READ AS "IN A VEHICLE". Half of the idiom is that
    -- `1 == true` is false, so a file that compared against `true` would refuse
    -- to work at all on a build that answers numbers.
    myVeh = 10
    tick()
    ok(asks > 0, 'while a numeric one does reach the vehicle read', asks)
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'and the car is written', held(10, 'fCollisionDamageMult'))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('entering')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The entry animation runs for about a second and ownership arrives with the
-- seat. Applying on the animation means the multipliers are already on the car
-- at the instant this machine becomes the one whose physics decide a crash.

do
    reset()
    spawn(10, MODEL_A)
    entering = 10
    tick()
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'a car being climbed into is written before the seat is taken',
       held(10, 'fCollisionDamageMult'))

    -- ...AND TAKING THE SEAT DOES NOT DOUBLE IT.
    entering, myVeh = 0, 10
    tick(3)
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'and sitting down afterwards changes nothing',
       held(10, 'fCollisionDamageMult'))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('when the natives will not play')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- citizenfx/fivem#1754 is SetVehicleHandlingFloat raising "Error executing
-- native" on an ordinary (veh, 'CHandlingData', 'fEngineDamageMult', 1.0),
-- closed with no documented fix. An uncaught throw inside a loop callback costs
-- five before BR.Loop suspends the callback entirely and silently, which is this
-- project's most expensive failure mode.

do
    reset()
    spawn(10, MODEL_A)
    myVeh = 10
    setThrows = true
    tick(10)
    ok(#writes == 0, 'a throwing setter writes nothing', #writes)
    -- THE CALLBACK IS STILL ALIVE, which is the assertion that matters: five
    -- unhandled throws would have suspended it and everything after this point
    -- in a real session would be silence.
    setThrows = false
    tick(2)
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'and the pass recovers the moment the native does -- the callback survived',
       held(10, 'fCollisionDamageMult'))
end

do
    reset()
    spawn(10, MODEL_A)
    myVeh = 10
    getThrows = true
    tick(5)
    ok(#writes == 0, 'a throwing getter takes no baseline and writes nothing',
       #writes)
    ok(V.stats().models == 0, 'and stores no baseline it could not read',
       V.stats().models)
    ok(V.stats().refused >= 1, 'and counts the refusal', V.stats().refused)

    getThrows = false
    tick(2)
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'and takes the baseline properly once it can',
       held(10, 'fCollisionDamageMult'))
end

-- ═══ A HANDLE THE ENGINE CANNOT NAME ═══
--
-- GetEntityModel answers 0, and `0` IS TRUTHY IN LUA. A baseline filed under 0
-- would be ONE ROW SHARED BY EVERY VEHICLE NOBODY COULD IDENTIFY -- so the
-- first bad read would go on to decide the handling of the next unrelated car,
-- which is a wrong number arriving somewhere with no connection to its cause.
--
-- BOTH VEHICLES BELOW HAVE READABLE HANDLING, AND MUTATION TESTING IS WHY. The
-- first draft gave the unnameable entity an EMPTY handling table, so a version
-- that accepted model 0 was stopped by `readStock` failing rather than by the
-- guard, and deleting the guard changed nothing. Giving them real -- and
-- DIFFERENT -- handling is what makes the shared row visible: without the
-- guard, the second car is scaled from the first one's numbers.
do
    reset()
    handling[10] = {}
    handling[11] = {}
    for k, v in pairs(template[MODEL_A]) do handling[10][k] = v end
    for k, v in pairs(template[MODEL_B]) do handling[11][k] = v end
    vehModel[10], vehModel[11] = nil, nil   -- GetEntityModel answers 0 for both

    myVeh = 10
    tick(3)
    ok(#writes == 0, 'a vehicle with no model is written nothing', #writes)
    ok(near(held(10, 'fCollisionDamageMult'), 1.0),
       'and keeps GTA\'s own handling', held(10, 'fCollisionDamageMult'))
    ok(V.baselineFor(0) == nil, 'and no baseline is filed under model zero')

    myVeh = 11
    tick(3)
    ok(#writes == 0, 'nor is a second one', #writes)
    ok(near(held(11, 'fCollisionDamageMult'), 0.7),
       'and it certainly does not inherit the first one\'s numbers',
       held(11, 'fCollisionDamageMult'))
    ok(V.stats().refused >= 2, 'both refusals are counted', V.stats().refused)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the model cap')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The keys arrive from the world, so the table gets a bound whether or not
-- anybody can imagine it filling -- server/vehicles.lua's MAX_SEEN_MODELS makes
-- the same argument. Past the cap a model keeps STOCK handling, which is the
-- fail-safe direction: a tougher car, never a wilder one.

do
    reset()
    C.maxModels = 2
    spawn(10, MODEL_A); myVeh = 10; tick(2)
    spawn(20, MODEL_B); myVeh = 20; tick(2)
    spawn(30, MODEL_TOUGH); myVeh = 30; tick(2)

    ok(V.stats().models == 2, 'the cap holds', V.stats().models)
    ok(near(held(30, 'fCollisionDamageMult'), 3.0),
       'and the model past it keeps GTA\'s own handling',
       held(30, 'fCollisionDamageMult'))
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'while the ones inside it are unaffected')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the way out')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The write is on the entity and outlives this resource; the baseline cache does
-- not. So a /refresh with a modified car under the player would leave the next
-- start reading our own value as though it were stock -- the one way this
-- feature can drift. Putting the car back on the way out is what closes it, and
-- it is client/boost.lua's own reasoning about a looped particle effect that
-- "outlives the resource that started it".

do
    reset()
    spawn(10, MODEL_A)
    myVeh = 10
    tick(2)
    ok(near(held(10, 'fCollisionDamageMult'), 5.0), 'modified while driving')

    fire('onClientResourceStop', 'br_core')
    ok(near(held(10, 'fCollisionDamageMult'), 1.0),
       'and put back to stock when the resource stops',
       held(10, 'fCollisionDamageMult'))
    ok(near(held(10, 'fEngineDamageMult'), 1.5),
       'every field of it, not just the first',
       held(10, 'fEngineDamageMult'))
end

-- SOMEBODY ELSE'S RESOURCE STOPPING IS NOT OURS.
do
    reset()
    spawn(10, MODEL_A)
    myVeh = 10
    tick(2)
    fire('onClientResourceStop', 'some_other_resource')
    ok(near(held(10, 'fCollisionDamageMult'), 5.0),
       'another resource stopping leaves our car alone',
       held(10, 'fCollisionDamageMult'))
end

-- ...AND NOTHING IS RESTORED FOR A PLAYER WHO IS NOT IN A CAR.
do
    reset()
    spawn(10, MODEL_A)
    myVeh = 10
    tick(2)
    myVeh = 0
    tick()
    local before = V.stats().restored
    fire('onClientResourceStop', 'br_core')
    ok(V.stats().restored == before,
       'a player on foot has no car to hand back', V.stats().restored)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the readout')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- /brvehdamage is the only instrument that can turn `multiplier` from a guess
-- into a measurement, because the question it answers -- what did the engine
-- actually accept -- cannot be asked here. It has to survive being run in every
-- state, including the ones where there is nothing to say.

do
    reset()
    ok(type(commands.brvehdamage) == 'function', 'the verb is registered')
    local okRun = pcall(commands.brvehdamage, 0, {})
    ok(okRun, 'and runs with the player on foot')

    spawn(10, MODEL_A)
    myVeh = 10
    tick(2)
    ok(pcall(commands.brvehdamage, 0, {}), 'and in a vehicle with a baseline')

    spawn(11, MODEL_B)
    myVeh = 11
    ok(pcall(commands.brvehdamage, 0, {}),
       'and in one whose baseline has not been taken yet')

    C.enabled = false
    ok(pcall(commands.brvehdamage, 0, {}), 'and with the feature switched off')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('what this feature does not touch')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ASSERTED AS AN ABSENCE, which is the only way to assert it. #213 is about the
-- RATE at which the three health pools fall, and the condition bar reads their
-- VALUES; a file that wrote a health number would be silently fighting both the
-- HUD and the pump repair, and the visible symptom would be a bar that
-- disagreed with the car.

do
    reset()
    spawn(10, MODEL_A)
    myVeh = 10
    tick(20)

    for _, w in ipairs(writes) do
        ok(w.field:find('DamageMult', 1, true) ~= nil,
           'only damage multipliers are ever written', w.field)
    end
    -- The three health natives and the petrol-tank volume are not stubbed
    -- ANYWHERE in this file, so a call to one is a nil-index and the pcall in
    -- the applier would swallow it -- which is why the assertion is on the write
    -- log rather than on a spy. `fPetrolTankVolume` is the trap: it lives in the
    -- same handling struct as the four fields above and client/fuel.lua reads it
    -- to convert the metre ledger into a gauge reading, so writing it here would
    -- move the fuel gauge as a side effect of a damage change.
    local touchedTank = false
    for _, w in ipairs(writes) do
        if w.field == 'fPetrolTankVolume' then touchedTank = true end
    end
    ok(not touchedTank,
       'and fPetrolTankVolume is left alone -- the fuel gauge reads it')

    ok(near(held(10, 'fWeaponDamageMult'), 1.0),
       'and bullet damage comes out exactly as GTA had it',
       held(10, 'fWeaponDamageMult'))
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
