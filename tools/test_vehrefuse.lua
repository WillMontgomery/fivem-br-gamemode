-- Unit tests for #215: refusing a vehicle at the door.
--
-- ═══ WHAT IS WORTH A SUITE HERE, AND WHAT IS NOT ═══
--
-- The ruling itself is not: BR.Config.VehicleRefusalFor is pure, shared by three
-- callers, and covered in tools/test_shared.lua under `vehicles.refusalFor`.
-- Duplicating it here would only mean two places to update and one of them
-- forgotten.
--
-- What this file is for is the four properties that live ONLY in the client
-- file, each of which is invisible in a live game until it is wrong:
--
--   1. THE SEAT IS INTERCEPTED BEFORE IT IS TAKEN. `GetVehiclePedIsEntering`
--      answers during the entry animation and `IsPedInAnyVehicle` is false for
--      the whole of it. An implementation that only checked the seat would look
--      identical in every screenshot and would be a full second later every
--      time. The fixture keeps `entering` and `myVeh` as two separate variables
--      that are never both set, so a file that read the wrong one fails rather
--      than passes slowly.
--
--   2. THE SENTENCE IS THE OWNER'S, VERBATIM. It is written out as a literal
--      below rather than compared to BR.VehRefuse.MESSAGE, because comparing the
--      constant to itself would pass for any string at all.
--
--   3. IT SAYS THE SAME THING EVERY TIME (#93). A notification that varied by
--      repeat, by reason, or by vehicle would be an anti-cheat disclosure; the
--      suite drives four rejections across three vehicles and three refusal
--      reasons and asserts one distinct message.
--
--   4. IT DOES NOT RUN WHILE THE GAMEMODE IS CARRYING THE PLAYER. The Battle
--      Bus IS a refused model -- `titan`, on the flight half -- so an ungated
--      version of this loop throws every player out of it at altitude, ten times
--      a second. That is the single worst thing this file could do and it is
--      three characters of edit away, so it is asserted directly.
--
-- ═══ THE FIXTURE MODELS THE BOOL AMBIGUITY, WHICH IS NOT DECORATION ═══
--
-- A FiveM BOOL native answers `true` or `1`, and a diagnostic on this build
-- caught ONE native answering `number 1` on some frames and `boolean false` on
-- others in a single session. This repo has shipped that bug five times. So
-- `IsPedInAnyVehicle` here is driven through all four shapes -- true, 1, false,
-- 0 -- and `0` is the one that matters: it is TRUTHY in Lua, so a file that
-- wrote `if IsPedInAnyVehicle(...) then` passes every other test in this file.
--
-- ═══ WHAT THIS CANNOT COVER ═══
--
-- Everything that needs the engine to be honest, and the header of the file
-- under test names the same three: whether the entry window is really wide
-- enough on this build for the cancel to beat the seat; whether
-- `SetVehicleDoorsLocked` sticks on an entity this client did not create;
-- whether `TaskLeaveVehicle` flag 16 is ever declined. `/brvehrefuse` prints all
-- three from a live lobby. They are named in the report as playtest questions
-- rather than pretended at here.
--
-- Run:  lua tools/test_vehrefuse.lua        (or via tools/verify.sh)

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

local commands = {}
function RegisterCommand(n, fn) commands[n] = fn end

-- ---------------------------------------------------------------------------
-- The world
-- ---------------------------------------------------------------------------

local PED = 77

--- What the player is doing. NEVER BOTH AT ONCE: `entering` is the animation and
--- `myVeh` is the seat, and the engine does not report both, so a fixture that
--- allowed both would let a file that reads only the seat look like a file that
--- intercepts the door.
local entering, myVeh = 0, 0

--- The BOOL shape `IsPedInAnyVehicle` answers with this pass. Set to 1, true,
--- 0 or false by the tests; the seat is `myVeh` regardless.
local boolShape = 1

--- [veh] = model hash
local vehModel = {}
--- [veh] = GetVehicleClass answer
local vehClass = {}
--- [veh] = GetVehicleType answer
local vehType = {}
--- [veh] = door lock status
local vehLock = {}
--- [veh] = what DOES_VEHICLE_HAVE_WEAPONS answers for it (#329)
---
--- HELD PER VEHICLE AND DEFAULTING TO nil, which `isTrue` reads as no. A native
--- that has no opinion, is missing from the build or throws must be
--- indistinguishable from "this car has no gun" as far as the OUTCOME goes, and
--- distinguishable in the counters -- which is what the blocks below assert.
local vehArmed = {}
--- [veh][seat] = what IS_TURRET_SEAT answers for that seat (#329)
local vehTurret = {}
--- [veh][seat] = the ped sitting in it. The engine only answers "who is in seat
--- N", which is why the file under test has to walk them.
local vehSeats = {}
--- [veh] = network id, as NetworkGetNetworkIdFromEntity answers it
local vehNetId = {}

--- Everything the file did to the world this run, in order.
local acts = {}
--- Every BR.Notify call, in order.
local notices = {}
--- How many times each read native was called.
---
--- `asks` COUNTS `GetVehiclePedIsIn`, AND IT IS THERE FOR ONE MUTANT. The two
--- guards in the seat path are deliberately redundant -- `isTrue(IsPedInAnyVehicle)`
--- and then `veh == 0` -- and redundancy is exactly what makes a broken first
--- guard invisible if only the OUTCOME is measured: strip the BOOL
--- normalisation and `not 0` is false in Lua, so the pass falls through, asks
--- for the vehicle, gets 0, and the second guard saves it. Every outcome
--- assertion in this file still passes. tools/test_vehdamage.lua counts the same
--- native for the same reason. So the question asked is the stricter one: A
--- PLAYER ON FOOT IS NEVER ASKED WHICH VEHICLE THEY ARE IN.
---
--- `held` COUNTS `GetCurrentPedWeapon` for the same reason, one native along:
--- an ordinary car must never be asked what is in the hand, and since the hand
--- became a source of hashes to disable that is a count, not an outcome.
---
--- `armed`, `turret` AND `seat` ARE #329's THREE, AND THEY ARE THE WHOLE COST
--- STORY OF THE PROBE. The file asks the engine once per OCCUPANCY and not once
--- per pass, and there is no outcome that changes when it asks ten times as
--- often -- the answers are the same. So the only way a probe that re-walks
--- eleven natives every pass, for every player in every car in the match, is
--- visible at all is by counting.
local reads = { model = 0, class = 0, type = 0, asks = 0, gun = 0, held = 0,
                armed = 0, turret = 0, seat = 0 }

--- Everything the file told the server, in order. [n] = { name, payload }
local sent = {}

--- Natives that should throw, by name, to model a stale handle.
local throws = {}

--- What `GetCurrentPedVehicleWeapon` answers, AS THE PAIR IT REALLY RETURNS.
---
--- BOOL GET_CURRENT_PED_VEHICLE_WEAPON(Ped, Hash*) -- two returns in Lua, the
--- BOOL first and the hash second. Held as two variables rather than one
--- "does this seat have a gun" flag because the two halves fail separately and
--- both failures are silent:
---
---   `gunBool` DRIVEN THROUGH ALL FOUR SHAPES. A FiveM BOOL answers `true` or
---   `1`, and `0` is TRUTHY in Lua. A file that wrote `if answered then` would
---   pass every case where the seat has a gun and would ALSO disable weapon
---   whatever-the-hash-slot-held on every seat that has none.
---
---   `gunHash` OF 0 WITH A TRUE BOOL is the other half: a vehicle with no
---   mounted gun answers zero, and zero is truthy too.
local gunBool, gunHash = false, 0

--- What `GetCurrentPedWeapon` answers: what is in the ped's HAND.
---
--- A DIFFERENT NATIVE AND A DIFFERENT QUESTION from the pair above, and the
--- whole of the `unnamed-gun` counter is the two disagreeing. The seat names no
--- gun AND the engine has put one in the hand that this gamemode issues nobody:
--- that pair is the firetruck. Either half alone is an ordinary driver -- the
--- driver of a Technical has no vehicle weapon and is holding their own rifle --
--- which is what the first version of this counter counted, ten times a second,
--- all match.
---
--- Held as the real pair as well, BOOL first, for the reason `gunBool` is.
local heldBool, heldHash = true, 0

local function act(kind, ...) acts[#acts + 1] = { kind = kind, ... } end

function PlayerPedId() return PED end

function IsPedInAnyVehicle()
    if myVeh == 0 then
        -- Both falsey shapes, alternated, so neither is the only one tested.
        return (boolShape == 1 or boolShape == 0) and 0 or false
    end
    return boolShape
end

function GetVehiclePedIsIn()
    reads.asks = reads.asks + 1
    return myVeh
end
function GetVehiclePedIsEntering() return entering end

function GetEntityModel(v)
    reads.model = reads.model + 1
    if throws.model then error('stale handle') end
    return vehModel[v]
end

function GetVehicleClass(v)
    reads.class = reads.class + 1
    if throws.class then error('stale handle') end
    return vehClass[v]
end

function GetVehicleType(v)
    reads.type = reads.type + 1
    if throws.type then error('stale handle') end
    return vehType[v]
end

function GetVehicleDoorLockStatus(v) return vehLock[v] or 1 end

function GetCurrentPedVehicleWeapon(p)
    reads.gun = reads.gun + 1
    if throws.gun then error('stale handle') end
    return gunBool, gunHash
end

--- DISABLE_VEHICLE_WEAPON(BOOL disabled, Hash weaponHash, Vehicle vehicle,
--- Ped owner) -- 0xF4FC6A6F67FA663B, citizenfx/natives.
---
--- EVERY ARGUMENT IS RECORDED IN ORDER AND ASSERTED POSITIONALLY. The flag comes
--- FIRST here and LAST-ish in every other vehicle native this file calls, so the
--- order is the single most likely thing to be written from memory and be wrong
--- -- and wrong it is completely silent: the engine is handed a vehicle where it
--- wanted a boolean, does nothing, and the gun keeps firing.
function DisableVehicleWeapon(disabled, hash, veh, owner)
    act('disable', disabled, hash, veh, owner)
end

--- BOOL GET_CURRENT_PED_WEAPON(Ped, Hash*, BOOL) -- the hand, not the seat.
function GetCurrentPedWeapon(p)
    reads.held = reads.held + 1
    if throws.held then error('stale handle') end
    return heldBool, heldHash
end

--- BOOL DOES_VEHICLE_HAVE_WEAPONS(Vehicle) -- 0x25ECB9F8017D98E0 (#329).
---
--- "IS THIS VEHICLE ARMED AT ALL", agnostic about how the weapon is worked, and
--- the only one of the two whose answer is sent to the server. Its doc page does
--- not describe its return value, so the fixture drives it through all four BOOL
--- shapes and through absence and a throw.
function DoesVehicleHaveWeapons(v)
    reads.armed = reads.armed + 1
    if throws.armed then error('stale handle') end
    return vehArmed[v]
end

--- BOOL IS_TURRET_SEAT(Vehicle, int seatIndex) -- 0xE33FFA906CE74880 (#329).
---
--- "DOES THIS SEAT HAVE A GUN", which is the question GetCurrentPedVehicleWeapon
--- has no opinion about in the Caracara's gun seat. THE SEAT INDEX IS THE SECOND
--- ARGUMENT and it is recorded rather than ignored: a file that passed the ped,
--- or the vehicle twice, would answer about the wrong seat and look identical.
function IsTurretSeat(v, seat)
    reads.turret = reads.turret + 1
    if throws.turret then error('stale handle') end
    return (vehTurret[v] or {})[seat]
end

--- Ped GET_PED_IN_VEHICLE_SEAT(Vehicle, int seatIndex).
---
--- THE ENGINE ANSWERS "WHO IS IN SEAT N" AND NEVER "WHICH SEAT AM I IN", which is
--- why the file under test walks them. Answers 0 for an empty seat, and 0 is
--- truthy in Lua.
function GetPedInVehicleSeat(v, seat)
    reads.seat = reads.seat + 1
    if throws.seat then error('stale handle') end
    return (vehSeats[v] or {})[seat] or 0
end

--- int NETWORK_GET_NETWORK_ID_FROM_ENTITY(Entity).
---
--- 0 IS A REAL ANSWER -- it is what the engine says for a vehicle it does not
--- network -- so a vehicle with no row here is one no report may name.
function NetworkGetNetworkIdFromEntity(v)
    if throws.netId then error('not networked') end
    return vehNetId[v] or 0
end

--- TriggerServerEvent, CAPTURED RATHER THAN SWALLOWED (#329).
---
--- The no-op at the top of this file stands where the rest of the FiveM shims
--- are, which is above `sent`; this replaces it before any test runs. What the
--- client TELLS THE SERVER is half of #329, and a suite that dropped it would
--- assert the disarm and say nothing about the suppression.
function TriggerServerEvent(name, payload)
    sent[#sent + 1] = { name = name, payload = payload }
end

function ClearPedTasksImmediately(p) act('clear', p) end
function TaskLeaveVehicle(p, v, f) act('leave', p, v, f) end
function SetVehicleDoorsLocked(v, s)
    if throws.lock then error('no control') end
    vehLock[v] = s
    act('lock', v, s)
end
function NetworkRequestControlOfEntity(v) act('control', v) end

-- ---------------------------------------------------------------------------
-- Modules
-- ---------------------------------------------------------------------------

BR = BR or {}

--- The notification spy, installed BEFORE the file under test loads.
---
--- BR.Notify itself lives in client/state.lua and is a four-line wrapper over a
--- TriggerEvent; loading that file would drag in the whole client state mirror
--- to prove nothing this suite is about. What this file owns is WHICH WORDS go
--- in and how often, and that is what is captured.
function BR.Notify(text, tone, opts)
    notices[#notices + 1] = { text = text, tone = tone, opts = opts or {} }
end

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
    -- BEFORE config/vehicles.lua, which calls BR.NormHash at LOAD time to build
    -- both of its hash-keyed lookups. The manifest carries the same ordering.
    'br_lib/shared/geo.lua',
    -- FOR BR.Net.VEH_ARMED (#329), WHICH IS THE NAME ON THE WIRE. Loaded rather
    -- than stubbed for protocol.lua's own stated reason -- "magic strings
    -- scattered across files are how client and server quietly stop agreeing" --
    -- and because a suite that made the name up would pass while the two ends
    -- named two different events.
    'br_lib/shared/protocol.lua',
    'br_lib/config/vehicles.lua',
    -- FOR THE `unnamed-gun` COUNTER, WHICH ASKS BR.Config.WeaponByHash WHETHER
    -- THE THING IN THE HAND IS ONE WE ISSUE. The real arsenal rather than a
    -- fixture: the counter's whole meaning is "in no row of ours", and a
    -- hand-built table of two weapons would prove that against a table nobody
    -- ships. It carries BR.Config.Gadgets with it, which is the parachute the
    -- counter also has to decline to count.
    'br_lib/config/weapons.lua',
    'br_core/client/main.lua',      -- the loop registry and BR.State
    'br_core/client/vehrefuse.lua',
}) do load(f) end

local V = BR.VehRefuse

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

--- One pass of the gate, in the band it is registered on.
local function tick(times)
    for _ = 1, (times or 1) do
        fakeTime = fakeTime + 100
        BR.Loop.step(BR.Loop.TICK)
    end
end

--- How many times the gate has thrown, as the loop registry counts it.
---
--- NOT `pcall(tick)`. BR.Loop.step runs every callback under its own pcall and
--- only counts what it catches, so a pass wrapped in a second pcall is true
--- whether the gate threw or not. This count is where a throw actually shows.
local function gateErrors()
    for _, e in ipairs(BR.Loop.stats()) do
        if e.name == 'vehrefuse.gate' then return e.errors end
    end
end

local function reset()
    entering, myVeh, boolShape = 0, 0, 1
    vehModel, vehClass, vehType, vehLock = {}, {}, {}, {}
    vehArmed, vehTurret, vehSeats, vehNetId = {}, {}, {}, {}
    acts, notices, sent = {}, {}, {}
    reads = { model = 0, class = 0, type = 0, asks = 0, gun = 0, held = 0,
              armed = 0, turret = 0, seat = 0 }
    throws = {}
    gunBool, gunHash = false, 0
    -- AN EMPTY HAND BY DEFAULT: `0` is what the engine answers for no weapon and
    -- it is TRUTHY in Lua, so this is also the shape that punishes a counter
    -- written as `if held then`.
    heldBool, heldHash = true, 0
    BR.State.me.state = BR.PlayerState.ALIVE
    V.reset()
end

--- Put a vehicle in the world.
---
--- THE PLAYER IS IN THE DRIVING SEAT OF IT BY DEFAULT, AND NETWORKED. Both are
--- #329's doing and both are the ordinary case rather than a convenience: seat -1
--- is where a player who presses F ends up, and a vehicle with no network id is
--- one no report can name -- so a fixture that left both empty would make every
--- probe assertion below pass for the wrong reason. `seatPed` moves them.
local function spawn(veh, model, class, vtype)
    vehModel[veh] = model
    vehClass[veh] = class or 4          -- Muscle: an ordinary car
    vehType[veh] = vtype or 'automobile'
    vehLock[veh] = 1                    -- VEHICLELOCK_UNLOCKED
    vehSeats[veh] = { [-1] = PED }
    vehNetId[veh] = 900 + veh
end

--- Move the player into one seat of a vehicle, and out of every other.
--- @param veh integer
--- @param seat integer  -1 is the driving seat
local function seatPed(veh, seat)
    vehSeats[veh] = { [seat] = PED }
end

--- Every act of one kind, in order.
local function acted(kind)
    local out = {}
    for _, a in ipairs(acts) do if a.kind == kind then out[#out + 1] = a end end
    return out
end

local function did(kind) return #acted(kind) end

-- Models used below. Every hash here is one this suite asserts a RULING on, so
-- each is named as well as numbered -- a bare hex literal in an assertion is
-- unreadable and, worse, unfalsifiable by inspection.
local BUZZARD = 0x2F03547B  -- heli, refused by the model table
local RHINO   = 0x2EA68690  -- tank, refused by the model table
local ZR3803  = 0xA7DCC35C  -- Nightmare ZR380: Arena War, ARMED in the table
local DELUXO  = 0x586765FB  -- hovers, so FLIES; Sports Classics, seen by no net
local TITAN   = 0x761E2AD3  -- the Battle Bus, which IS refused
local BARRACKS = 0xCEEA3F4B -- class 19 and exempt from the class net
local ADDER   = 0xB779A091  -- an ordinary supercar, in no list at all
-- #322's two: an ARMED row of the model table, which is DRIVEN with its gun
-- held off rather than refused. `caracara` -- the 6x6 -- is the one the owner
-- sat in on 2026-09-19: armed, ordinary Off-road class, permitted by omission
-- until then, and its gun seat names no weapon. `technical` is the same ruling
-- on a row that was always there.
local CARACARA  = 0x4ABEBF23
local TECHNICAL = 0x83051506
--- `caracara2`, the 4x4, which #322 had listed as ARMED in the 6x6's place. It
--- has no weapon and is in no row now, so it is an ordinary car here.
local CARACARA2 = 0xAF966F3C
--- A vehicle weapon hash. Any non-zero number: what the file does with it is
--- pass it back to the engine untouched, which is the property asserted.
local SEAT_GUN = 0x1D6FDE47
--- VEHICLE_WEAPON_PLAYER_BUZZARD: a REAL mounted-gun hash, and in no row of
--- BR.Config.WeaponByHash. That is the whole property the hand path tests for,
--- so it is a published hash rather than an invented one.
local ENGINE_GUN = 0xE2822A29
--- WEAPON_CARBINERIFLE, which this gamemode DOES issue -- one of its own rows,
--- so a hand holding it is an ordinary player rather than an engine fault.
local CARBINE = 0x83BF0278

-- ═══════════════════════════════════════════════════════════════════════════
describe('before the seat')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE HALF THE OWNER ASKED FOR IN THOSE WORDS -- "detect the vehicle they're
-- trying to get in as they try, then reject the action". Rejecting the action is
-- cancelling the entry task; the player never sits down.
do
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    entering = 10
    tick()

    ok(did('clear') == 1, 'the entry task is cancelled', did('clear'))
    ok(did('leave') == 0,
       'and no exit task is issued -- there is no seat to leave', did('leave'))
    ok(#notices == 1, 'the player is told once', #notices)
    ok(did('lock') == 1, 'and the doors are locked behind them', did('lock'))

    local s = V.stats()
    ok(s.cancelled == 1 and s.ejected == 0,
       'and it is counted as an interception, not an ejection')

    -- The order is the property: nobody is locked into a vehicle they are still
    -- being removed from.
    local first, lockAt = nil, nil
    for i, a in ipairs(acts) do
        if a.kind == 'clear' and first == nil then first = i end
        if a.kind == 'lock' and lockAt == nil then lockAt = i end
    end
    ok(first ~= nil and lockAt ~= nil and first < lockAt,
       'and the removal is ordered before the lock')
end

do
    -- AND AN ORDINARY CAR IS UNTOUCHED IN THE SAME WINDOW. This is the assertion
    -- that fails if somebody ever inverts the ruling, which is the failure mode
    -- config/vehicles.lua's header spends four hundred words on.
    reset()
    spawn(10, ADDER, 7, 'automobile')
    entering = 10
    tick(5)

    ok(#acts == 0, 'climbing into an ordinary car does nothing at all', #acts)
    ok(#notices == 0, 'and says nothing')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('after the seat')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE ROUTE THE WINDOW MISSES: a script warp, a bike, or simply the window
-- opening and closing between two passes of a 100 ms loop.
do
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    myVeh = 10
    tick()

    local leave = acted('leave')
    ok(#leave == 1, 'an exit task is issued', #leave)
    ok(leave[1] and leave[1][1] == PED and leave[1][2] == 10,
       'for this player, out of this vehicle')
    ok(leave[1] and leave[1][3] == 16,
       'with flag 16 -- teleport out, door kept closed', leave[1] and leave[1][3])
    ok(did('clear') == 0,
       'and the hammer is NOT reached for on the first pass', did('clear'))
    ok(#notices == 1 and did('lock') == 1, 'told once, locked once')
end

do
    -- THE ESCALATION. `TaskLeaveVehicle` is a task and a task can be declined --
    -- by a vehicle upside down, a destroyed door, an animation already blending
    -- -- and a declined task is indistinguishable from an unfinished one. So the
    -- file stops asking after 400 ms. Without this the player stays in the
    -- helicopter and the only symptom is that nothing happens.
    reset()
    spawn(10, RHINO, 19, 'automobile')
    myVeh = 10
    tick(3)                 -- 300 ms: still inside the polite window
    ok(did('clear') == 0, 'three passes still only ask politely', did('clear'))
    ok(did('leave') == 3, 'and ask on every one of them', did('leave'))

    tick(2)                 -- past ESCALATE_MS
    ok(did('clear') >= 1, 'and then it stops asking', did('clear'))
end

do
    -- A PLAYER INTERCEPTED AT THE DOOR WHO IS SOMEHOW SEATED A MOMENT LATER gets
    -- the polite task first. Two clocks, not one -- with a single clock the
    -- rejection at the door would have started the escalation timer and the
    -- hammer would land the instant the seat was taken.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    entering = 10
    tick(6)                 -- 600 ms of being refused at the door
    ok(did('clear') == 6, 'six passes at the door, six cancels', did('clear'))

    entering, myVeh = 0, 10
    tick()
    ok(did('leave') == 1,
       'and the first pass in the seat still asks politely', did('leave'))
    ok(did('clear') == 6, 'rather than escalating on a clock it never started')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the sentence')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    entering = 10
    tick()

    -- WRITTEN OUT, NOT COMPARED TO THE CONSTANT. `BR.VehRefuse.MESSAGE ==
    -- BR.VehRefuse.MESSAGE` is true for every string there is.
    ok(notices[1] and notices[1].text ==
       'To keep things fair, this vehicle is not allowed to be used during the match.',
       'is the owner\'s wording, verbatim',
       notices[1] and notices[1].text)

    -- NOTHING APPENDED. The owner's standing rule is that unsolicited UI text is
    -- never added, and the likeliest way it creeps in is a reason, a model name
    -- or a "(you have been reported)" on the end of a string that was right.
    ok(notices[1] and not notices[1].text:find('Buzzard', 1, true)
       and not notices[1].text:find('flies', 1, true)
       and not notices[1].text:find('helicopter', 1, true),
       'and names neither the vehicle nor the reason')
end

do
    -- ═══ #93: AN OFFENDER MUST LEARN NOTHING ═══
    --
    -- Four rejections, three vehicles, three different halves of the rule, and a
    -- repeat of the first. If the sentence varied by ANY of those it would be
    -- telling a cheat which signal caught them -- or, worse, that a case exists.
    --
    -- THE ARMED ONE IS THE CLASS NET'S SINCE #322, and it had to be: the model
    -- table's armed rows are DRIVEN now rather than refused, so a Nightmare
    -- ZR380 no longer produces a sentence at all. The unlisted class-19 model
    -- below is the armed half that still ejects, and putting it here means the
    -- sentence is proved identical across the signal that was added LAST -- the
    -- one most likely to grow a reason of its own.
    reset()
    spawn(10, BUZZARD, 15, 'heli')       -- flies, by the model table
    spawn(11, RHINO, 19, 'automobile')   -- tank, by the model table
    spawn(12, 0x0BADF00D, 19, 'automobile')  -- armed, by the class net

    local seen = {}
    for _, v in ipairs({ 10, 11, 12, 10 }) do
        entering = v
        tick()
        fakeTime = fakeTime + 10000      -- past the notify cooldown every time
    end
    for _, n in ipairs(notices) do seen[n.text .. '|' .. tostring(n.tone)] = true end

    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    ok(#notices == 4, 'all four attempts are answered', #notices)
    ok(distinct == 1,
       'with one single message -- no reason, no repeat count, no case',
       ('%d distinct messages'):format(distinct))
end

do
    -- THE COOLDOWN. A player leaning on the entry key against a locked Buzzard
    -- is refused ten times a second; they are told once.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    entering = 10
    tick(20)                             -- two seconds of trying
    ok(V.stats().rejected == 20, 'every pass rejects', V.stats().rejected)
    ok(#notices == 1, 'and exactly one sentence is shown', #notices)

    fakeTime = fakeTime + 5000
    tick()
    ok(#notices == 2, 'a deliberate attempt later is answered again', #notices)
end

do
    -- A DIFFERENT VEHICLE IS A FRESH EPISODE even inside the cooldown: the
    -- player is being told about THIS car, and silence would read as the rule
    -- not applying to it.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    spawn(11, RHINO, 19, 'automobile')
    entering = 10
    tick()
    entering = 11
    tick()
    ok(#notices == 2, 'a second vehicle is answered immediately', #notices)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the lock')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    entering = 10
    tick()

    local l = acted('lock')
    ok(l[1] and l[1][2] == 2,
       'the doors go to state 2 -- VEHICLELOCK_LOCKED', l[1] and l[1][2])
    ok(did('control') >= 1,
       'and control is asked for first, for the entering case')
end

do
    -- ═══ IT DOES NOT SURVIVE A STREAM-OUT, AND DOES NOT NEED TO ═══
    --
    -- Door lock state lives on the entity. An entity that streams out and back
    -- is a new entity at default lock, and nothing in this feature persists
    -- anything. The recovery is that the next attempt is refused exactly like
    -- the first -- so the assertion is that a vehicle found UNLOCKED again is
    -- re-locked, rather than skipped because we remember locking it.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    entering = 10
    tick()
    ok(vehLock[10] == 2, 'locked on the first attempt')

    vehLock[10] = 1                      -- streamed out and back
    entering = 0
    tick()
    entering = 10
    tick()
    ok(vehLock[10] == 2, 're-locked when the same vehicle comes back unlocked')
    ok(did('lock') == 2, 'by writing it again, not by remembering', did('lock'))
end

do
    -- A LOCKED VEHICLE IS STILL CHECKED. The owner's "this will prevent us from
    -- running that check again" is the ENGINE refusing the entry, not this file
    -- skipping a lock state -- and it must stay that way, because ambient parked
    -- cars in GTA V are frequently already at lock state 2. A file that skipped
    -- locked vehicles would wave through an ambient locked Buzzard.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    vehLock[10] = 2                      -- already locked by the map, not by us
    myVeh = 10
    tick()
    ok(did('leave') == 1,
       'a vehicle that was already locked is refused like any other', did('leave'))
    ok(#notices == 1, 'and its driver is told like any other')
    -- ...but its doors are not written to a value they already hold. Lock state
    -- is NETWORKED, and `reject` runs ten times a second while somebody leans on
    -- the entry key.
    ok(did('lock') == 0,
       'while a lock that already holds is not written again', did('lock'))
end

do
    -- AND THE WRITE IS NOT REPEATED WHILE IT HOLDS. Twenty passes of refusing
    -- the same vehicle is one lock, not twenty.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    entering = 10
    tick(20)
    ok(V.stats().rejected == 20, 'twenty rejections', V.stats().rejected)
    ok(did('lock') == 1, 'and one write to the doors', did('lock'))
end

do
    -- THE LOCK FAILING CHANGES NOTHING ELSE. It is best effort; the ejection is
    -- not.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    throws.lock = true
    myVeh = 10
    tick()
    ok(did('leave') == 1, 'a lock this client cannot write still ejects')
    ok(#notices == 1, 'and still tells the player')
    ok(V.stats().locked == 0, 'and does not claim to have locked anything')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('when it must not run')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THE BATTLE BUS ═══
--
-- BR.Config.Bus.model is `titan` and `titan` IS in the refused table -- it is an
-- aircraft and the owner's rule says so. Every player in every match rides it.
do
    ok(select(1, BR.Config.IsAllowedVehicle(TITAN)) == false,
       'the Battle Bus model really is refused -- this is why the gate exists')

    for _, st in ipairs({ BR.PlayerState.BUS, BR.PlayerState.FREEFALL,
                          BR.PlayerState.GLIDE }) do
        reset()
        BR.State.me.state = st
        spawn(10, TITAN, 16, 'plane')
        myVeh = 10
        tick(10)
        ok(#acts == 0 and #notices == 0,
           ('a player in state %s is left entirely alone'):format(st), #acts)
    end
end

do
    for _, st in ipairs({ BR.PlayerState.LOBBY, BR.PlayerState.OUT,
                          BR.PlayerState.DBNO, BR.PlayerState.LEFT }) do
        reset()
        BR.State.me.state = st
        spawn(10, BUZZARD, 15, 'heli')
        myVeh = 10
        tick(3)
        ok(#acts == 0, ('nothing happens in state %s'):format(st), #acts)
    end
end

do
    -- WARMUP DOES run: it is a player on their own feet who could walk to a
    -- helicopter, and the server's creation detector is the only thing covering
    -- them otherwise.
    reset()
    BR.State.me.state = BR.PlayerState.WARMUP
    spawn(10, BUZZARD, 15, 'heli')
    myVeh = 10
    tick()
    ok(did('leave') == 1, 'but a warmup player is refused like any other')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the bool shapes')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- THE BUG THIS REPO HAS SHIPPED FIVE TIMES. `0` is TRUTHY in Lua and a FiveM
-- BOOL native returns `1` as often as `true` -- one native on this build was
-- caught answering `number 1` and `boolean false` in the same session.
do
    for _, shape in ipairs({ 1, true }) do
        reset()
        boolShape = shape
        spawn(10, BUZZARD, 15, 'heli')
        myVeh = 10
        tick()
        ok(did('leave') == 1,
           ('a seat reported as %s is a seat'):format(tostring(shape)))
    end
end

do
    -- AND THE FALSEY HALF, which is the one a careless `if x then` gets wrong:
    -- `IsPedInAnyVehicle` answering the NUMBER 0 must mean "on foot".
    --
    -- ═══ THE OUTCOME IS NOT THE ASSERTION HERE, AND THAT IS THE POINT ═══
    --
    -- The seat path has two guards and they are deliberately redundant. Strip
    -- the BOOL normalisation and `not 0` is FALSE in Lua, so the pass falls
    -- straight through the first guard -- and then asks for the vehicle, gets
    -- 0, and is caught by the second. Nothing is ejected, nothing is said, and
    -- `#acts == 0` passes exactly as it does now. The only visible difference is
    -- that the native was asked a question about a player standing in a field.
    for _, shape in ipairs({ 0, false }) do
        reset()
        boolShape = (shape == 0) and 1 or 2   -- selects which falsey shape
        spawn(10, BUZZARD, 15, 'heli')
        myVeh = 0                              -- on foot
        tick(3)
        ok(#acts == 0,
           ('a player on foot (%s) is never ejected from anything')
               :format(tostring(shape)), #acts)
        ok(reads.asks == 0,
           ('nor asked which vehicle they are in (%s)'):format(tostring(shape)),
           reads.asks)
    end
end

do
    -- AND `entering` == 0 IS NOT A VEHICLE. Same trap, the other native: `if
    -- entering then` is true for a player standing in a field, and 0 is in no
    -- model table, so the ruling would come back allowed and nothing would look
    -- wrong -- until GetEntityModel(0) answers something one day.
    reset()
    entering, myVeh = 0, 0
    tick(5)
    ok(reads.model == 0,
       'a player entering nothing is never asked what model nothing is',
       reads.model)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the three signals, from the client')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The ruling is BR.Config.VehicleRefusalFor's and is tested in test_shared.lua.
-- What is asserted here is that this file WIRES all three -- a client that
-- passed only the model would lose the two nets silently.
do
    reset()
    -- A model in no table at all, class 19: only the class net can catch it, and
    -- only the client has the class. This is the armed half's first net anywhere
    -- in the tree.
    spawn(10, 0x0BADF00D, 19, 'automobile')
    myVeh = 10
    tick()
    ok(did('leave') == 1, 'unlisted military hardware is caught by its class')
end

do
    reset()
    spawn(10, 0x0BADF00D, 4, 'heli')     -- ordinary class, aircraft type
    myVeh = 10
    tick()
    ok(did('leave') == 1, 'and an unlisted aircraft by its type')
end

do
    -- THE EXEMPTION, END TO END. A Barracks is class 19 and unarmed, and the
    -- owner's rule -- the one that keeps the plain `insurgent` out of the table
    -- -- permits it. Refusing it would have this gamemode inventing a rule and
    -- telling a player it is not allowed.
    reset()
    spawn(10, BARRACKS, 19, 'automobile')
    myVeh = 10
    tick(3)
    ok(#acts == 0, 'a barracks is class 19 and is left alone', #acts)
    ok(#notices == 0, 'and nothing is said to its driver')
end

do
    -- THE MODEL TABLE ALONE, END TO END: ordinary class, ordinary type, refused
    -- only because the table names it. If the table were ever dropped in favour
    -- of "just use the class" this whole shape comes back.
    --
    -- A DELUXO RATHER THAN THE ARENA WAR ROW THIS USED TO USE. The Nightmare
    -- ZR380 is still in the table and still invisible to both nets, but #322
    -- made the ARMED rows drivable, so it no longer ejects anybody -- see the
    -- #322 block below, where it is asserted from the other side. The Deluxo is
    -- the same structural case on the half of the rule that did not move: Sports
    -- Classics, type `automobile`, and filed under FLIES because it hovers.
    reset()
    spawn(10, DELUXO, 5, 'automobile')
    myVeh = 10
    tick()
    ok(did('leave') == 1,
       'a Deluxo is refused although no net would see it')
end

do
    -- AND THE ROW THAT MOVED, FROM THE OTHER SIDE. Same model table, same
    -- invisibility to both nets, opposite outcome -- because its row says ARMED
    -- and the owner ruled that armed rows are driven with the gun off.
    reset()
    spawn(10, ZR3803, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    tick()
    ok(did('leave') == 0, 'a Nightmare ZR380 is not ejected any more', did('leave'))
    ok(did('disable') == 1, 'its gun is switched off instead', did('disable'))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the cache')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- KEYED ON THE MODEL, NOT THE HANDLE, and the difference is worth a test in both
-- directions: keyed on the handle it would be both slower (every Adder in the
-- match is a fresh miss) and WRONG (a recycled handle inherits a stale ruling).
do
    reset()
    spawn(10, ADDER, 7, 'automobile')
    myVeh = 10
    tick(10)
    ok(reads.class <= 1, 'one ordinary car is classed once, not ten times',
       reads.class)
    ok(V.stats().asked == 1 and V.stats().cached == 9,
       'and the other nine passes are lookups')
end

do
    reset()
    spawn(10, ADDER, 7, 'automobile')
    spawn(11, ADDER, 7, 'automobile')    -- a second car, the same model
    myVeh = 10
    tick()
    myVeh = 11
    tick()
    ok(V.stats().asked == 1,
       'two vehicles of one model are one ruling', V.stats().asked)
end

do
    -- AND A RECYCLED HANDLE DOES NOT INHERIT ONE. Handle 10 is an Adder, then
    -- handle 10 is a Buzzard. A handle-keyed cache flies the Buzzard.
    reset()
    spawn(10, ADDER, 7, 'automobile')
    myVeh = 10
    tick(3)
    ok(#acts == 0, 'the adder is allowed')

    spawn(10, BUZZARD, 15, 'heli')       -- same handle, new entity
    tick()
    ok(did('leave') == 1,
       'and the same handle carrying a Buzzard is refused', did('leave'))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('when the natives will not play')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Every read here is pcall'd because `makeEntityFunction` natives THROW on a
-- stale handle rather than answering -- server/vehicles.lua carries the same
-- warning. An uncaught throw takes the loop callback down.
do
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    throws.model = true
    myVeh = 10
    local fine = pcall(tick)
    ok(fine, 'a model read that throws does not take the pass down')
    -- ...and it must not invent a refusal either: nil model, and the nets are
    -- still asked, and this one really is an aircraft by class.
    ok(did('leave') == 1, 'the class net still answers for it')
end

do
    reset()
    spawn(10, ADDER, 7, 'automobile')
    throws.class, throws.type = true, true
    myVeh = 10
    local fine = pcall(tick)
    ok(fine, 'nor do the class and type reads')
    ok(#acts == 0, 'and an ordinary car with no readable signals is allowed')
end

do
    -- THE NATIVE THAT IS NOT THERE AT ALL. `GetVehiclePedIsEntering` is not
    -- stubbed in every harness in this repo, which is why the production line
    -- guards it -- and the guard must read "not entering anything", never crash.
    reset()
    local saved = GetVehiclePedIsEntering
    GetVehiclePedIsEntering = nil
    spawn(10, BUZZARD, 15, 'heli')
    myVeh = 10
    local fine = pcall(tick)
    GetVehiclePedIsEntering = saved
    ok(fine, 'a missing entering native does not crash the pass')
    ok(did('leave') == 1, 'and the seat is still checked')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('what this file does not do')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- IT IS ADVISORY. It sends nothing to the server, so it cannot be an input to a
-- case -- and the server-side detector it must not weaken is a different file
-- entirely. The assertion is on the wire: nothing goes over it.
do
    local sent = 0
    local savedS, savedE = TriggerServerEvent, TriggerEvent
    TriggerServerEvent = function() sent = sent + 1 end
    TriggerEvent = function() sent = sent + 1 end

    reset()
    spawn(10, BUZZARD, 15, 'heli')
    myVeh = 10
    tick(5)
    entering, myVeh = 10, 0
    tick(5)

    TriggerServerEvent, TriggerEvent = savedS, savedE
    ok(sent == 0, 'ten rejections send the server nothing at all', sent)
end

do
    -- AND IT NEVER TOUCHES A PED THAT IS NOT THIS PLAYER'S. Every act carries a
    -- ped and every one of them must be PlayerPedId()'s.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    myVeh = 10
    tick(8)
    local wrong = 0
    for _, a in ipairs(acts) do
        if (a.kind == 'clear' or a.kind == 'leave') and a[1] ~= PED then
            wrong = wrong + 1
        end
    end
    ok(wrong == 0, 'every task is aimed at this player\'s own ped', wrong)
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('driving one with the gun off (#322)')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THE OWNER'S RULING ═══
--
--   "only vehicles refused for being ARMED become drivable."
--
-- The ruling is BR.Config's and is covered in tools/test_shared.lua under
-- `vehicles.disarmed`. What is asserted HERE is the four things that exist only
-- in this file, each of which is silent when it is wrong:
--
--   1. THE ARGUMENT ORDER. DisableVehicleWeapon takes the FLAG FIRST, which is
--      the opposite of every other vehicle native this file calls. Written from
--      memory and got wrong, the engine is handed a vehicle handle where it
--      wanted a boolean, does nothing anybody can see, and the gun keeps firing
--      -- in a car the player is no longer ejected from, so the symptom is a
--      working weapon rather than an error.
--   2. THE HASH COMES FROM THE ENGINE AND GOES BACK UNTOUCHED. It is the only
--      hash in this file not put through BR.NormHash, because it is not going
--      into a table.
--   3. THE BOOL IS NORMALISED. `0` is truthy in Lua and this repo has shipped
--      that six times; here it would mean disabling a weapon on every seat that
--      has none.
--   4. IT AND THE EJECTION ARE MUTUALLY EXCLUSIVE. A Buzzard must never be
--      disarmed instead of emptied, and the negative cases below are the point
--      of the block.
do
    reset()
    spawn(10, CARACARA, 9, 'automobile')    -- Off-road: no net sees this model
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    tick()

    ok(did('leave') == 0 and did('clear') == 0,
       'an armed row of the model table does not eject anybody',
       ('%d leave, %d clear'):format(did('leave'), did('clear')))
    ok(#notices == 0, 'and says nothing to the player', #notices)
    ok(did('lock') == 0, 'and does not lock the doors behind them')

    local d = acted('disable')
    ok(#d == 1, 'the mounted weapon is disabled', #d)
    -- POSITIONALLY, ALL FOUR. See the note on the stub.
    ok(d[1] and d[1][1] == true, 'with the DISABLED FLAG FIRST, and true',
       d[1] and tostring(d[1][1]))
    ok(d[1] and d[1][2] == SEAT_GUN,
       'then the hash the engine itself named, unaltered',
       d[1] and tostring(d[1][2]))
    ok(d[1] and d[1][3] == 10, 'then the vehicle', d[1] and tostring(d[1][3]))
    ok(d[1] and d[1][4] == PED, 'then this player\'s own ped',
       d[1] and tostring(d[1][4]))

    local s = V.stats()
    ok(s.disarmed == 1 and s.unnamedGun == 0, 'and it is counted',
       ('disarmed=%d unnamedGun=%d'):format(s.disarmed, s.unnamedGun))
end

do
    -- IT IS A LOOP AND NOT A ONE-SHOT. The call does not persist, and the seat's
    -- weapon can change under us -- so it is re-asserted on every pass for as
    -- long as somebody is sitting there.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    tick(4)
    ok(did('disable') == 4, 'the disable is re-applied on every pass',
       did('disable'))
end

do
    -- AND THE RE-READ IS WHAT MAKES THAT WORTH DOING. A player switching to the
    -- vehicle's second weapon gets the NEW hash disabled, which a file that
    -- cached the first one would not do.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    tick()
    gunHash = 0x4D3C9A11
    tick()

    local d = acted('disable')
    ok(#d == 2 and d[1][2] == SEAT_GUN and d[2][2] == 0x4D3C9A11,
       'a weapon switch mid-seat disables the weapon they switched TO',
       d[2] and tostring(d[2][2]))
end

-- ═══ THE NEGATIVES, WHICH ARE THE REASON THIS BLOCK EXISTS ═══

do
    -- A BUZZARD IS EMPTIED, NOT DISARMED. Disabling a gun does not stop a
    -- helicopter flying, and an implementation that treated every refusal as
    -- disarmable would leave a player airborne in a refused aircraft with a
    -- quiet minigun -- which looks, from the seat, exactly like the feature
    -- working.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    tick(3)
    ok(did('leave') > 0, 'a FLIES refusal still ejects', did('leave'))
    ok(did('disable') == 0, 'and is never disarmed instead', did('disable'))
end

do
    -- A RHINO IS EMPTIED. The owner ruled on this one by name.
    reset()
    spawn(10, RHINO, 19, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    tick(3)
    ok(did('leave') > 0, 'a TANK refusal still ejects', did('leave'))
    ok(did('disable') == 0, 'and a tank is never merely disarmed', did('disable'))
end

do
    -- ═══ THE ONE THE WHOLE RULING TURNS ON ═══
    --
    -- A model in NO row of the table, class 19. The class net refuses it with
    -- BR.Config.VehicleRefusal.ARMED -- the SAME STRING the model table's armed
    -- rows carry, character for character. An implementation that decided on the
    -- reason word rather than on which signal produced it passes every case
    -- above and quietly makes every unknown piece of military hardware drivable.
    -- There is no in-game symptom: an absent ejection looks like a clean server.
    reset()
    spawn(10, 0x0BADF00D, 19, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    tick(3)
    ok(did('leave') > 0,
       'a class-net ARMED refusal still ejects, although its reason word is '
           .. 'identical to the rows that do not', did('leave'))
    ok(did('disable') == 0, 'and is not disarmed', did('disable'))
end

-- ═══ THE BOOL, AND THE ZERO HASH ═══

do
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = 1, SEAT_GUN          -- the native answered `number 1`
    tick()
    ok(did('disable') == 1, 'a BOOL of 1 is an answer', did('disable'))
end

for _, shape in ipairs({ 0, false }) do
    -- `0` IS THE ONE THAT MATTERS. It is TRUTHY in Lua, so a file that wrote
    -- `if answered then` would take "this seat has no vehicle weapon" for yes
    -- and disable whatever was in the hash slot.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = shape, SEAT_GUN
    tick(2)
    ok(did('disable') == 0,
       ('a BOOL of %s is a refusal to answer, and nothing is disabled')
           :format(tostring(shape)), did('disable'))
    ok(V.stats().disarmed == 0,
       ('and nothing is counted as disarmed (%s)'):format(tostring(shape)),
       V.stats().disarmed)
end

do
    -- A TRUE BOOL AND A ZERO HASH. A vehicle with no mounted gun answers zero,
    -- and zero is truthy -- so without the explicit test this would hand the
    -- engine 0 as a weapon hash, forever, on every pass.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, 0
    tick(2)
    ok(did('disable') == 0, 'a hash of 0 is not a weapon', did('disable'))
end

do
    -- A SEAT NATIVE THAT THROWS IS NO OPINION, AND NO OPINION IS THE HAND PATH.
    -- The pass must not throw and must not eject -- and since the owner's
    -- Caracara, the gun the engine put in the hand is what gets switched off,
    -- exactly as it would be for a seat that answered and named nothing.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    throws.gun = true
    heldBool, heldHash = true, ENGINE_GUN   -- and the engine put it in the hand
    local before = gateErrors()
    tick(2)
    ok(gateErrors() == before,
       'a seat native that throws does not take the pass down',
       gateErrors() - before)
    ok(did('leave') == 0, 'and does not turn into an ejection', did('leave'))
    local d = acted('disable')
    ok(#d == 2 and d[1][2] == ENGINE_GUN and d[2][2] == ENGINE_GUN,
       'and the hand\'s gun is disabled instead, on every pass', #d)
    ok(V.stats().unnamedGun == 2, 'and is counted', V.stats().unnamedGun)
end

do
    -- AND THE NATIVE SIMPLY NOT BEING ON THIS BUILD. `safe` answers nil for an
    -- absent native exactly as it does for a throwing one, and a nil call here
    -- would take the whole TICK pass down -- the ejection with it.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    local saved = DisableVehicleWeapon
    DisableVehicleWeapon = nil
    local before = gateErrors()
    tick(2)
    DisableVehicleWeapon = saved
    ok(gateErrors() == before,
       'a build without DisableVehicleWeapon does not take the pass down',
       gateErrors() - before)

    -- AND THE COUNTER SAYS SO. This is the assertion the first version did not
    -- make, and without it the readout was a lie in the one direction it is read
    -- in: `disarmed` was incremented after a helper that answers nil BOTH for a
    -- native that threw and for one it never called, under a doc comment
    -- promising "calls that reached the native". An operator reading
    -- `disarmed=600` on a build with no DisableVehicleWeapon would have
    -- concluded the feature was working.
    ok(V.stats().disarmed == 0,
       'and nothing is counted as disarmed on a build that has no such native',
       V.stats().disarmed)
end

-- ═══ THE HAND PATH: THE SEAT NAMES NOTHING, AND THE GUN IS IN THE HAND ═══
--
-- THE OWNER'S CARACARA, 2026-09-19. `brcar 1 caracara`, the gun seat, and the
-- gun fired -- with the truck's gun in his hand, where client/inventory.lua
-- stripped it and the server counted it, because the seat did not name it.
-- `disarm` now reads that hash from the hand where the seat names nothing and
-- switches it off, ONLY when it is in no row of BR.Config.WeaponByHash. Every
-- case below is one side of that "only".
--
-- `disarm` runs for ANY seat by design, so "the seat named no gun" is the
-- ORDINARY case: the driver of a Technical, an Insurgent or a Caracara has no
-- vehicle weapon at all. Their rifle, their fists, their parachute and their
-- empty hand must never be handed to DisableVehicleWeapon, and must not climb
-- `unnamed-gun` either -- the first version of this file counted exactly that
-- and printed it under a line telling the operator that a climbing number
-- meant a missing StripExemptVehicles row.

do
    -- THE OWNER'S SEAT. The seat names nothing and the hand holds a hash in no
    -- row of ours, so that hash is disabled -- with the same four arguments, in
    -- the same order, that the named path hands over.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    gunBool, gunHash = false, 0
    heldBool, heldHash = true, ENGINE_GUN
    tick(3)

    ok(did('leave') == 0 and did('clear') == 0 and #notices == 0,
       'nobody is ejected from the Caracara or told anything')

    local d = acted('disable')
    ok(#d == 3, 'the gun in the hand is disabled on every pass', #d)
    -- POSITIONALLY, ALL FOUR, for the reason the named path is.
    ok(d[1] and d[1][1] == true, 'with the DISABLED FLAG FIRST, and true',
       d[1] and tostring(d[1][1]))
    ok(d[1] and d[1][2] == ENGINE_GUN, 'then the hash in the hand',
       d[1] and tostring(d[1][2]))
    ok(d[1] and d[1][3] == 10, 'then the vehicle', d[1] and tostring(d[1][3]))
    ok(d[1] and d[1][4] == PED, 'then this player\'s own ped',
       d[1] and tostring(d[1][4]))

    -- BOTH COUNTERS, TOGETHER. That pairing is how /brvehrefuse says the hand
    -- path is doing the work rather than the seat.
    local s = V.stats()
    ok(s.unnamedGun == 3 and s.disarmed == 3,
       'and it is counted as disarmed, from the hand',
       ('disarmed=%d unnamedGun=%d'):format(s.disarmed, s.unnamedGun))
end

do
    -- THE HASH GOES BACK AS THE ENGINE GAVE IT. VEHICLE_WEAPON_PLAYER_BUZZARD
    -- has the top bit set, so the engine reports it NEGATIVE. It is normalized
    -- to be looked up and handed back raw -- the reason `mountedWeaponOf` gives
    -- for its own hash: a rewrite on the way from the engine to the engine can
    -- only make it wrong.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, ENGINE_GUN - 0x100000000
    tick()
    local d = acted('disable')
    ok(#d == 1 and d[1][2] == ENGINE_GUN - 0x100000000,
       'a signed hash from the hand is disabled exactly as the engine reported it',
       d[1] and tostring(d[1][2]))
end

do
    -- ON TICK, WITH THE NAMED PATH. Same call, same band.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, ENGINE_GUN
    BR.Loop.step(BR.Loop.FRAME)
    BR.Loop.step(BR.Loop.FRAME)
    ok(did('disable') == 0, 'the hand path does nothing on the FRAME band',
       did('disable'))
    tick()
    ok(did('disable') == 1, 'and one pass of TICK is what does it', did('disable'))
end

do
    -- A BUILD WITHOUT DisableVehicleWeapon, ON THE HAND PATH. The seat still
    -- names nothing and the hand still holds the gun, so `unnamed-gun` climbs;
    -- nothing reached the engine, so `disarmed` does not. That split is the
    -- reading /brvehrefuse documents as "the disable never reached it".
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, ENGINE_GUN
    local saved = DisableVehicleWeapon
    DisableVehicleWeapon = nil
    local before = gateErrors()
    tick(2)
    DisableVehicleWeapon = saved
    local s = V.stats()
    ok(gateErrors() == before and s.unnamedGun == 2 and s.disarmed == 0,
       'and a build with no such native counts the gun but not a disable',
       ('disarmed=%d unnamedGun=%d'):format(s.disarmed, s.unnamedGun))
end

do
    -- THE ORDINARY DRIVER. Holding a rifle out of this gamemode's own arsenal,
    -- in a disarmed vehicle whose seat names no gun. It is THEIR weapon and not
    -- the car's: nothing is disabled, nothing is done to the world at all, and
    -- nothing is counted.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    gunBool, gunHash = false, 0
    heldBool, heldHash = true, CARBINE
    tick(5)
    ok(#acts == 0, 'an issued rifle in the hand is never disabled or touched',
       #acts)
    ok(V.stats().unnamedGun == 0,
       'and a driver holding it is not the firetruck case',
       V.stats().unnamedGun)
end

do
    -- FISTS ARE NOT THE CAR'S GUN EITHER. WEAPON_UNARMED is a row -- BR.Config.
    -- Fists, registered into WeaponByHash by hand -- and that row is the only
    -- thing declining it, so this is the assertion that fails the day it goes.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, BR.Config.Gadgets.UNARMED
    tick(3)
    ok(did('disable') == 0, 'bare hands are never disabled', did('disable'))
    ok(V.stats().unnamedGun == 0, 'nor counted', V.stats().unnamedGun)
end

do
    -- AND AN EMPTY HAND IS NOT IT EITHER. `0` is TRUTHY in Lua, so a test
    -- written as `if held then` would hand the engine 0 as a weapon, every pass
    -- of every drive.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, 0
    tick(5)
    ok(did('disable') == 0, 'an empty hand disables nothing', did('disable'))
    ok(V.stats().unnamedGun == 0, 'nor is an empty hand', V.stats().unnamedGun)
end

do
    -- THE PARACHUTE IS IN NO WEAPON ROW AND IS NOT A GUN. client/skydive.lua
    -- grants it on purpose and client/inventory.lua's strip excuses it by hash;
    -- switching it off here would be switching off our own grant.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, BR.Config.Gadgets.PARACHUTE
    tick(3)
    ok(did('disable') == 0, 'the parachute is never disabled', did('disable'))
    ok(V.stats().unnamedGun == 0, 'nor is the parachute', V.stats().unnamedGun)
end

do
    -- A HAND NATIVE THAT THROWS OR DECLINES TO ANSWER IS NO OPINION, and no
    -- opinion hands the engine nothing. A silence that inflated the counter
    -- would be worse than one that loses a reading: the number is what an
    -- operator would act on.
    for _, shape in ipairs({ 0, false }) do
        reset()
        spawn(10, TECHNICAL, 4, 'automobile')
        myVeh = 10
        heldBool, heldHash = shape, ENGINE_GUN
        tick(2)
        ok(did('disable') == 0 and V.stats().unnamedGun == 0,
           ('a hand BOOL of %s is no opinion'):format(tostring(shape)),
           V.stats().unnamedGun)
    end

    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    throws.held = true
    local before = gateErrors()
    tick(2)
    ok(gateErrors() == before and did('disable') == 0
           and V.stats().unnamedGun == 0,
       'and a hand native that throws does not take the pass down, disable '
           .. 'anything, or count')
end

do
    -- AN ORDINARY CAR IS NEVER ASKED WHAT IS IN THE HAND. The model test in
    -- `disarm` is what keeps the hand, and the fallback with it, off the path
    -- of every player in every car in the match -- whatever the hand holds.
    reset()
    spawn(10, ADDER, 7, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, ENGINE_GUN
    tick(5)
    ok(#acts == 0, 'an ordinary car does nothing whatever is in the hand', #acts)
    ok(reads.held == 0, 'and is never asked what is in it', reads.held)
    ok(V.stats().unnamedGun == 0, 'and counts nothing', V.stats().unnamedGun)
end

do
    -- AND NEITHER IS THE CARACARA 4x4. #322 listed it as ARMED in the 6x6's
    -- place; it has no weapon and is in no row now, so it is an ordinary car,
    -- and the hand path never reaches it.
    reset()
    spawn(10, CARACARA2, 9, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, ENGINE_GUN
    tick(5)
    ok(#acts == 0 and #notices == 0,
       'the Caracara 4x4 is driven like any other car', #acts)
    ok(reads.held == 0 and reads.gun == 0,
       'and is never asked about a gun, in the seat or in the hand',
       ('%d / %d'):format(reads.gun, reads.held))
end

-- ═══ WHAT IT COSTS, AND WHEN IT RUNS AT ALL ═══

do
    -- AN ORDINARY CAR IS NEVER ASKED WHAT GUN IT HAS. This is the assertion that
    -- fails if the model test is ever dropped out of `disarm` -- two natives per
    -- pass for every player in every car in the match, on the band this project
    -- keeps its performance contract in.
    reset()
    spawn(10, ADDER, 7, 'automobile')
    myVeh = 10
    tick(5)
    ok(reads.gun == 0, 'an ordinary car is never asked what gun it has', reads.gun)
    ok(#acts == 0, 'and nothing is done to it at all', #acts)
end

do
    -- NOR IS A BARRACKS, WHICH IS CLASS 19 AND ALLOWED. Allowed is not the same
    -- as disarmed, and the class-net exemption must not become a disable.
    reset()
    spawn(10, BARRACKS, 19, 'automobile')
    myVeh = 10
    tick(3)
    ok(reads.gun == 0, 'nor is a Barracks, which is allowed and unarmed', reads.gun)
end

do
    -- NOR IS SOMEBODY STILL CLIMBING IN. There is no seat yet, so there is no
    -- mounted weapon to name, no seat's gun in the hand, and nothing to hold
    -- off -- whichever of the two places the hash would have come from.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    entering, myVeh = 10, 0
    gunBool, gunHash = true, SEAT_GUN
    heldBool, heldHash = true, ENGINE_GUN
    tick(3)
    ok(did('disable') == 0, 'nor is a player still climbing in', did('disable'))
    ok(#acts == 0, 'and the entry is not interfered with either', #acts)
end

do
    -- IT IS ON THE TICK BAND. Stepping FRAME must do nothing at all -- this file
    -- registers one callback and it is not there. A FRAME loop would be two
    -- natives every frame for every player sitting in one of these; TICK's cost
    -- is a tenth of a second of a gun whose shots server/damage.lua refuses
    -- anyway.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    BR.Loop.step(BR.Loop.FRAME)
    BR.Loop.step(BR.Loop.FRAME)
    ok(did('disable') == 0, 'nothing happens on the FRAME band', did('disable'))
    tick()
    ok(did('disable') == 1, 'and one pass of TICK is what does it', did('disable'))
end

for _, st in ipairs({ BR.PlayerState.BUS, BR.PlayerState.FREEFALL,
                      BR.PlayerState.DBNO, BR.PlayerState.OUT }) do
    -- THE SAME GATE THE EJECTION HAS, and it is the same gate on purpose: the
    -- states this file stands down in are the ones where the gamemode is
    -- carrying the player or they are past playing, and neither is a state in
    -- which somebody is working a vehicle turret.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    BR.State.me.state = st
    tick(3)
    ok(did('disable') == 0,
       ('nothing is disarmed in state %s'):format(tostring(st)), did('disable'))
end

do
    -- AND WARMUP IS, on the gate the ejection keeps: a warmup player is on
    -- their own feet with the map's vehicles in reach, and "a warmup player is
    -- refused like any other" above is the same decision from the other side.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    BR.State.me.state = BR.PlayerState.WARMUP
    tick()
    ok(did('disable') == 1, 'but WARMUP disarms, as it ejects',
       did('disable'))
end

do
    -- THE DIAGNOSTIC RUNS. It reads five natives on whatever the player is in,
    -- and a nil-index in a command nobody runs in a test is a crash on a live
    -- server at the moment somebody is trying to diagnose something.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    myVeh = 10
    tick()
    ok(type(commands.brvehrefuse) == 'function', '/brvehrefuse is registered')
    ok(pcall(commands.brvehrefuse), 'and runs with a player in a vehicle')
    myVeh = 0
    ok(pcall(commands.brvehrefuse), 'and on foot')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('asking the engine which vehicles are armed (#329)')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ THE OWNER'S REPORT, AND WHY THERE IS NO MODEL NAME IN THIS BLOCK ═══
--
-- A second stock vehicle turned up on 2026-09-21 whose weapons were not disabled
-- and which filed an incident against its own driver, three days after the
-- Caracara did the same thing. He withheld its name on purpose: "I'm not going to
-- give you that vehicle's name because I don't want you to hardcode anything with
-- this."
--
-- SO THE MODEL USED BELOW IS ONE THAT IS IN NO ROW OF ANYTHING, and every block
-- asserts that as part of the outcome rather than assuming it. That assertion IS
-- the owner's requirement: a suite that named a real model would pass just as
-- well against a fix that added a row, which is the fix he ruled out.
--
-- ═══ WHICH NATIVE ANSWERS WHICH QUESTION, WHICH IS THE THING TO GET RIGHT ═══
--
--   DOES_VEHICLE_HAVE_WEAPONS  the VEHICLE. It is what the report to the server
--                              carries, and the reason is the Ruiner 2000 family:
--                              those fire from the DRIVING seat, so a turret test
--                              alone would go on accusing every one of them.
--   IS_TURRET_SEAT             the SEAT. It is what sees the Caracara's gun seat,
--                              where GetCurrentPedVehicleWeapon has no opinion,
--                              and it is deliberately NOT on the wire.
--
-- A file that swapped them would pass a suite that only asserted "the gun is
-- switched off", so the two are driven independently below -- armed with no
-- turret, a turret with no armament, and each with the other absent.
--
-- ═══ AND WHAT THIS SUITE CANNOT SETTLE ═══
--
-- Whether either native answers as assumed on a real build. Their doc pages
-- describe no return value, the fixture is this file's own, and a stub cannot
-- disagree with the engine. `/brvehrefuse` prints `probed` beside `engine-armed`
-- and `turret-seat` for exactly that reason; the report names it as a playtest
-- question rather than pretending at it here.

--- A model in NO row of anything: not refused, not disarmed, not strip-exempt.
---
--- WHICH IS THE PROPERTY, NOT THE VALUE. Every block below asserts it holds
--- before asserting what happens, so the day somebody "fixes" a case here by
--- writing a row this stops being the test it was.
local MYSTERY = 0x5EC0FFEE
--- The firetruck, the one model the owner exempted BY HAND: its hose IS a vehicle
--- weapon and using it is not an incident (c58745f).
local FIRETRUK = 0x73920F8E
--- What one full walk of the seats costs in GetPedInVehicleSeat reads.
---
--- -1 THROUGH MAX_SEAT, which is ten -- the range client/driveby.lua's `seatOf`
--- walks and the range server/vehicles.lua refuses a report outside. Written out
--- because a walk that found nobody is the expensive case, and the cost of it
--- happening every pass is invisible in every outcome.
local MAX_SEAT_WALK = 10

do
    -- THE SHAPE THE OWNER REPORTED, IN A MODEL NOBODY WROTE DOWN: the engine says
    -- the vehicle is armed, the seat is a turret, and GetCurrentPedVehicleWeapon
    -- names nothing -- so the gun is in the hand, which is where the Caracara's
    -- was.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')      -- Off-road: no type, no class net
    myVeh = 10
    seatPed(10, 0)
    vehArmed[10] = true
    vehTurret[10] = { [-1] = false, [0] = true }
    gunBool, gunHash = false, 0              -- the seat names nothing
    heldBool, heldHash = true, ENGINE_GUN    -- and the engine put it in the hand
    tick()

    ok(BR.Config.IsDisarmedVehicle(MYSTERY) == false
       and BR.Config.VehicleRefusalFor(MYSTERY) == nil
       and BR.Config.StripExemptByHash[BR.NormHash(MYSTERY)] == nil,
       'the model is in no authored row of any kind -- which is the requirement')

    local d = acted('disable')
    ok(#d == 1 and d[1][1] == true and d[1][2] == ENGINE_GUN
           and d[1][3] == 10 and d[1][4] == PED,
       'the gun is switched off anyway, with the same four arguments', #d)
    ok(did('leave') == 0 and did('clear') == 0 and did('lock') == 0
       and #notices == 0,
       'and nothing about it ejects anybody or says anything -- the probe can '
           .. 'only widen the DISARM, never the refusal')

    ok(#sent == 1 and sent[1].name == BR.Net.VEH_ARMED,
       'and the server is told, on BR.Net.VEH_ARMED', #sent)
    local p = sent[1] and sent[1].payload or {}
    ok(p.netId == 910, 'by network id and not by the local handle',
       tostring(p.netId))
    ok(p.seat == 0, 'naming the seat, which is what the far end validates with',
       tostring(p.seat))
    ok(p.turret == nil and p.armed == nil and p.model == nil,
       'and nothing else: the seat\'s turret answer stays on this machine, and '
           .. 'the message\'s existence is the armed claim')

    local s = V.stats()
    ok(s.probed == 1 and s.engineArmed == 1 and s.turretSeat == 1
       and s.reported == 1, 'and all four counters say so',
       ('probed=%d armed=%d turret=%d reported=%d')
           :format(s.probed, s.engineArmed, s.turretSeat, s.reported))
end

do
    -- ═══ THE FAMILY A TURRET TEST ALONE WOULD KEEP ACCUSING ═══
    --
    -- A Ruiner 2000, a Toreador, a Stromberg and a Scramjet all fire from the
    -- DRIVING seat, so IS_TURRET_SEAT answers no for the only seat anybody is in.
    -- DOES_VEHICLE_HAVE_WEAPONS is what covers them, and this is the case that
    -- fails if somebody keys the report on the seat instead of the vehicle.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    vehTurret[10] = { [-1] = false }
    gunBool, gunHash = true, SEAT_GUN        -- a driver gun the seat DOES name
    tick()

    ok(did('disable') == 1 and acted('disable')[1][2] == SEAT_GUN,
       'a driver-operated gun is switched off from the seat\'s own hash',
       did('disable'))
    ok(#sent == 1 and sent[1].payload.seat == -1,
       'and the report names the driving seat', #sent)
    ok(V.stats().turretSeat == 0,
       'with the turret answer a flat no -- which is why it is not what the '
           .. 'report keys on', V.stats().turretSeat)
end

do
    -- ═══ THE NEGATIVE THAT KEEPS THE SUPPRESSION FROM BECOMING UNCONDITIONAL ═══
    --
    -- An unlisted vehicle the engine says is NOT armed must go on accusing its
    -- driver exactly as it does today. Without this, "suppress when the engine
    -- says armed" and "suppress always" look identical in every other block.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    heldBool, heldHash = true, ENGINE_GUN
    tick(3)

    ok(reads.armed == 1, 'the engine IS asked about it', reads.armed)
    ok(did('disable') == 0,
       'and its answer of no leaves the gun alone', did('disable'))
    ok(#sent == 0,
       'and tells the server nothing, so the shot still files as NO_WEAPON',
       #sent)
end

do
    -- A TURRET SEAT IN A VEHICLE THE VEHICLE-LEVEL QUESTION DID NOT ANSWER.
    -- Either native answering is enough for the DISARM -- neither return value is
    -- documented, so a single surprising answer must not switch the feature off --
    -- and this is also what a build with DOES_VEHICLE_HAVE_WEAPONS missing looks
    -- like. The REPORT is a different question and stays silent.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = nil                       -- no opinion
    vehTurret[10] = { [-1] = true }
    gunBool, gunHash = true, SEAT_GUN
    tick()

    ok(did('disable') == 1, 'a turret seat alone switches the gun off',
       did('disable'))
    ok(#sent == 0,
       'and sends nothing: only the armed half of the answer travels', #sent)
end

do
    -- ═══ THE FIRETRUCK, WHICH IS THE CASE THAT PROVES POLICY IS STILL AUTHORED
    --     (c58745f, owner 2026-09-15) ═══
    --
    -- Its hose IS a vehicle weapon, so the engine will say so, and the owner ruled
    -- that using it is the point: "I want them to be able to use the firehose.
    -- That's the point. We shouldn't get an incident for that." A version of this
    -- feature that disarmed it because the engine called it armed would be a
    -- regression wearing a fix's clothes, and there is no in-game symptom beyond a
    -- hose that stops working.
    reset()
    spawn(10, FIRETRUK, 18, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    vehTurret[10] = { [-1] = true }
    gunBool, gunHash = true, SEAT_GUN
    heldBool, heldHash = true, ENGINE_GUN
    tick(3)

    ok(BR.Config.StripExemptByHash[BR.NormHash(FIRETRUK)] ~= nil
       and BR.Config.VehicleRefusalFor(FIRETRUK) == nil,
       'the firetruck is exempt by hand and is not a refused model')
    ok(did('disable') == 0, 'and it is never disarmed', did('disable'))
    ok(#sent == 0, 'and never reported', #sent)
    ok(reads.armed == 0 and reads.turret == 0,
       'and the engine is not even asked -- the authored table answers first',
       ('armed=%d turret=%d'):format(reads.armed, reads.turret))
end

do
    -- ═══ A LISTED MODEL BEHAVES EXACTLY AS IT DID BEFORE ANY OF THIS ═══
    --
    -- The ruling already disarms it and server/vehicles.lua already excuses it, so
    -- there is nothing a probe could add and nothing a report could change. Not
    -- asking is what makes that true by construction rather than by coincidence.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    vehTurret[10] = { [-1] = true }
    gunBool, gunHash = true, SEAT_GUN
    tick(3)

    ok(did('disable') == 3, 'a listed model is disarmed on every pass, as before',
       did('disable'))
    ok(reads.armed == 0 and reads.turret == 0 and reads.seat == 0,
       'and the engine is never asked about it at all',
       ('armed=%d turret=%d seat=%d')
           :format(reads.armed, reads.turret, reads.seat))
    ok(#sent == 0, 'and nothing is reported about it', #sent)
end

do
    -- A REFUSED MODEL IS STILL EMPTIED, AND IS NEVER PROBED. The probe sits BELOW
    -- the refusal's `return`, so a Buzzard cannot become a vehicle we merely
    -- disarm however loudly the engine agrees it is armed.
    reset()
    spawn(10, BUZZARD, 15, 'heli')
    myVeh = 10
    vehArmed[10] = true
    vehTurret[10] = { [-1] = true }
    tick(3)

    ok(did('leave') > 0, 'a FLIES refusal still ejects', did('leave'))
    ok(did('disable') == 0, 'and is never disarmed instead', did('disable'))
    ok(reads.armed == 0 and #sent == 0,
       'and the engine is not asked and the server is not told',
       ('armed=%d sent=%d'):format(reads.armed, #sent))
end

-- ═══ WHAT IT COSTS, WHICH IS THE ONLY WAY A PER-PASS PROBE IS VISIBLE ═══

do
    -- AN ORDINARY CAR IS ASKED ONCE AND THEN NEVER AGAIN. "This vehicle has no
    -- gun in any seat" is a complete answer, so the latch spends nothing for the
    -- rest of the match -- and a version that re-walked the seats every pass
    -- would produce identical outcomes in every block above.
    reset()
    spawn(10, ADDER, 7, 'automobile')
    myVeh = 10
    tick(5)

    ok(reads.armed == 1,
       'five passes in an ordinary car ask the vehicle-level question once',
       reads.armed)
    ok(reads.seat == 1,
       'and walk the seats once, stopping at the driving seat', reads.seat)
    ok(reads.turret == 1, 'and ask about that one seat once', reads.turret)
    ok(V.stats().probed == 1, 'one occupancy, one probe', V.stats().probed)
    ok(#acts == 0, 'and nothing is done to the car', #acts)
end

do
    -- A VEHICLE THAT DID ANSWER COSTS ONE NATIVE A PASS AFTER THAT, and that one
    -- is a CONFIRMATION rather than a search: seat state is the only thing that
    -- can change without the handle changing.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    tick(5)

    ok(reads.armed == 1, 'the vehicle is asked once, not five times', reads.armed)
    ok(reads.seat == 5, 'and the latched seat is confirmed once a pass',
       reads.seat)
    ok(reads.turret == 1, 'and the seat question is not re-asked', reads.turret)
end

do
    -- ...AND A SEAT CHANGE INSIDE THE SAME VEHICLE IS RE-ASKED. A player who
    -- drives a Technical to a fight and then shuffles into the bed is in a
    -- different seat of the same handle, and the turret answer is about the seat.
    -- THE SEAT INDEX IS THE SECOND ARGUMENT, and this is where a file that passed
    -- the wrong one fails: the two seats answer differently on purpose.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    vehTurret[10] = { [-1] = false, [0] = true }
    gunBool, gunHash = true, SEAT_GUN
    tick()
    ok(V.stats().turretSeat == 0, 'the driving seat is no turret',
       V.stats().turretSeat)

    seatPed(10, 0)
    tick()
    ok(V.stats().turretSeat == 1,
       'and moving to the gun seat is asked about again', V.stats().turretSeat)
    ok(reads.turret == 2, 'which is a second read and not a cached one',
       reads.turret)
end

-- ═══ THE BOOL SHAPES, FOR BOTH NATIVES, BECAUSE NEITHER DOC PAGE SAYS ═══

for _, shape in ipairs({ true, 1 }) do
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehArmed[10] = shape
    gunBool, gunHash = true, SEAT_GUN
    tick()
    ok(did('disable') == 1 and #sent == 1,
       ('DOES_VEHICLE_HAVE_WEAPONS answering %s is a yes'):format(tostring(shape)),
       did('disable'))
end

for _, shape in ipairs({ 0, false }) do
    -- `0` IS THE ONE THAT MATTERS: it is TRUTHY in Lua, so a probe written as
    -- `if DoesVehicleHaveWeapons(veh) then` would report every car in the match as
    -- armed and hand the anticheat a blanket excuse. This project has shipped the
    -- truthiness version of this six times.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehArmed[10] = shape
    gunBool, gunHash = true, SEAT_GUN
    tick(2)
    ok(did('disable') == 0 and #sent == 0,
       ('DOES_VEHICLE_HAVE_WEAPONS answering %s is a no'):format(tostring(shape)),
       ('%d disables, %d sent'):format(did('disable'), #sent))
end

for _, shape in ipairs({ 0, false }) do
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehTurret[10] = { [-1] = shape }
    gunBool, gunHash = true, SEAT_GUN
    tick(2)
    ok(did('disable') == 0,
       ('IS_TURRET_SEAT answering %s is a no'):format(tostring(shape)),
       did('disable'))
end

do
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehTurret[10] = { [-1] = 1 }
    gunBool, gunHash = true, SEAT_GUN
    tick()
    ok(did('disable') == 1, 'and IS_TURRET_SEAT answering 1 is a yes',
       did('disable'))
end

-- ═══ A BUILD WITHOUT THEM, AND A HANDLE THAT HAS GONE STALE ═══

do
    -- NEITHER NATIVE ON THIS BUILD. `safe` answers nil for an absent native
    -- exactly as it does for a throwing one, and a nil call would take the whole
    -- TICK pass down -- the ejection with it.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    local a, t = DoesVehicleHaveWeapons, IsTurretSeat
    DoesVehicleHaveWeapons, IsTurretSeat = nil, nil
    local before = gateErrors()
    tick(2)
    DoesVehicleHaveWeapons, IsTurretSeat = a, t

    ok(gateErrors() == before,
       'a build with neither native does not take the pass down',
       gateErrors() - before)
    ok(did('disable') == 0 and #sent == 0,
       'and nothing is disabled and nothing is claimed',
       ('%d disables, %d sent'):format(did('disable'), #sent))
    ok(V.stats().probed == 1,
       'while `probed` still climbs -- one occupancy, asked about',
       V.stats().probed)
    -- AND `probed` IS NOT WHAT SAYS THE NATIVE IS SILENT, which this block used to
    -- claim in as many words. A `probed` of one with `engine-armed` at zero is also
    -- what one ordinary car looks like. `armed-silent` counts the reads that
    -- reached no engine at all, and it is the only number here that separates the
    -- two.
    ok(V.stats().armedSilent == 2 and V.stats().engineArmed == 0,
       'and `armed-silent` is what tells an operator the native is not answering '
           .. 'rather than every car being unarmed',
       ('silent=%d armed=%d')
           :format(V.stats().armedSilent, V.stats().engineArmed))
end

for _, which in ipairs({ 'armed', 'turret', 'seat', 'netId' }) do
    -- A STALE HANDLE THROWS RATHER THAN ANSWERING, which is the shape this file's
    -- `safe` exists for. Each of the four natives is thrown separately: a pcall
    -- around the wrong one looks identical while the pass is fine.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    gunBool, gunHash = true, SEAT_GUN
    throws[which] = true
    local before = gateErrors()
    tick(2)
    ok(gateErrors() == before,
       ('a %s native that throws does not take the pass down'):format(which),
       gateErrors() - before)
    ok(did('leave') == 0,
       ('nor does it turn into an ejection (%s)'):format(which), did('leave'))
end

-- ═══ AND A READ THAT DID NOT ANSWER IS NOT AN ANSWER OF "NO" ═══
--
-- THE WORST SHAPE THIS FEATURE HAD. `probe.asked` was set before either native was
-- read and `isTrue(safe(...))` folded "threw, or is not on this build" into the
-- same `false` as "answered no", so one bad pass latched "no gun" for the WHOLE
-- occupancy: no disarm and no report for as long as the player stayed in that
-- vehicle, which is precisely the symptom #329 exists to remove, now silent and
-- with `probed` climbing so the readout said "asked, the car was unarmed".
--
-- IT IS THE EXPECTED CASE AND NOT AN EXOTIC ONE. `safe` exists in the file under
-- test because these natives "may not exist on this build and may throw on a stale
-- handle"; an ownership migration or a handle that goes stale for a tenth of a
-- second is enough, and the player pays for the whole time they stay seated.

--- How many passes of one occupancy may read DOES_VEHICLE_HAVE_WEAPONS.
---
--- WRITTEN OUT HERE FOR MAX_SEAT_WALK's REASON: the bound is a cost contract with
--- no outcome to show it, so an unbounded retry -- a pcall'd native every pass for
--- every player in every vehicle, forever -- would pass every other assertion in
--- this file.
local PROBE_TRIES = 5

do
    -- ONE THROWING PASS, THEN A HEALTHY ONE. The reviewer's reproduction of the
    -- defect was one throwing pass followed by twenty healthy passes, which
    -- produced armed-reads=1, disables=0, sent=0.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    gunBool, gunHash = true, SEAT_GUN

    throws.armed = true
    tick()
    ok(reads.armed == 1 and did('disable') == 0 and #sent == 0,
       'the pass whose read threw disarms nothing and reports nothing, which is '
           .. 'all a pass that learned nothing can do',
       ('armed=%d disables=%d sent=%d')
           :format(reads.armed, did('disable'), #sent))
    ok(V.stats().armedSilent == 1 and V.stats().engineArmed == 0,
       'and it is counted as silence rather than as an answer of no',
       ('silent=%d armed=%d')
           :format(V.stats().armedSilent, V.stats().engineArmed))

    throws.armed = nil
    tick()
    ok(reads.armed == 2, 'the next pass asks the engine again', reads.armed)
    ok(did('disable') == 1 and #sent == 1,
       'and the gun goes off and the server is told, in the SAME occupancy -- '
           .. 'without this the player keeps a live gun and an incident for as '
           .. 'long as they stay in the car',
       ('disables=%d sent=%d'):format(did('disable'), #sent))
    ok(V.stats().probed == 1 and V.stats().engineArmed == 1,
       'which is one occupancy that answered late, not two',
       ('probed=%d armed=%d')
           :format(V.stats().probed, V.stats().engineArmed))
end

do
    -- ...AND THE RETRY IS BOUNDED, WHICH IS THE OTHER HALF OF THE SAME FIX. A
    -- native that is not on this build never starts answering, so "ask again next
    -- pass" with no ceiling is a native call every 100 ms for every player in every
    -- vehicle for the whole match. Five passes is half a second at TICK: long
    -- enough for a migration to settle, and five reads is the entire cost of a
    -- build without the native.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    gunBool, gunHash = true, SEAT_GUN
    throws.armed = true
    local before = gateErrors()
    tick(20)

    ok(reads.armed == PROBE_TRIES,
       'twenty passes of a native that always throws read it five times and then '
           .. 'stop asking', reads.armed)
    ok(V.stats().armedSilent == PROBE_TRIES and V.stats().probed == 1,
       'all five counted as silence, against the one occupancy',
       ('silent=%d probed=%d')
           :format(V.stats().armedSilent, V.stats().probed))
    ok(gateErrors() == before, 'and none of them took the pass down',
       gateErrors() - before)
    ok(did('disable') == 0 and #sent == 0,
       'a vehicle nothing ever answered about is left to the authored table, '
           .. 'which is the pre-#329 floor',
       ('disables=%d sent=%d'):format(did('disable'), #sent))
end

do
    -- ═══ AND `/brvehrefuse` TELLS THE TWO APART, WHICH IS WHY THE COUNTER IS
    --     THERE AT ALL ═══
    --
    -- "The natives are silent on this build" and "every car in this match really
    -- was unarmed" are the same picture in `probed` and `engine-armed`, and only a
    -- live lobby can settle which one is happening. So the readout has to carry the
    -- silence itself rather than leave an operator to infer it from a zero.
    --
    -- THE GLOBAL `print` IS BORROWED FOR THE CALL. The command resolves it when it
    -- runs, so this reads the real line the operator would see.
    local function readout()
        local lines, saved = {}, print
        print = function(m) lines[#lines + 1] = m end
        local okc = pcall(commands.brvehrefuse)
        print = saved
        return okc, table.concat(lines, '\n')
    end

    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    throws.armed = true
    tick(20)
    local okc, silent = readout()
    ok(okc and silent:find('armed%-silent=5') ~= nil,
       'a build whose native never answers prints the silence', silent)

    reset()
    spawn(10, ADDER, 7, 'automobile')
    myVeh = 10
    tick(20)
    local okd, ordinary = readout()
    ok(okd and ordinary:find('armed%-silent=0') ~= nil
       and ordinary:find('probed=1') ~= nil,
       'and an ordinary car prints the same one probe with no silence in it',
       ordinary)
end

-- ═══ A HANDLE IS NOT A VEHICLE, WHICH IS WHAT THE LATCH IS KEYED ON ═══

do
    -- ═══ A RECYCLED HANDLE CARRYING A STALE ARMED CLAIM INTO ANOTHER VEHICLE ═══
    --
    -- Entity handles are REISSUED. Sit in the armed vehicle holding handle 10, get
    -- out, let that vehicle be deleted, and the engine can hand 10 to a plain
    -- Adder. Keyed on the handle alone, the latch answers "armed" for the Adder
    -- with the engine never asked about it -- and THE SERVER CANNOT CATCH THAT: it
    -- reads the model off the vehicle it resolved itself, so its handle, model,
    -- seat and match checks all pass and the report is believed.
    --
    -- THE RECYCLE HAPPENS BETWEEN TWO PASSES HERE, with no pass in between where
    -- the player is seen on foot, and that is deliberate: a dismount and a remount
    -- inside one 100 ms window is invisible to the gate, so the KEY is the half of
    -- the fix that has to hold. The block below is the other half.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    vehTurret[10] = { [-1] = true }
    gunBool, gunHash = true, SEAT_GUN
    tick()
    ok(#sent == 1 and did('disable') == 1,
       'the armed vehicle holding handle 10 is disarmed and reported',
       ('sent=%d disables=%d'):format(#sent, did('disable')))

    -- THE SAME HANDLE, ANOTHER VEHICLE: an ordinary supercar in no row of
    -- anything, which the engine says has no weapons and no turret seat.
    spawn(10, ADDER, 7, 'automobile')
    vehArmed[10], vehTurret[10] = nil, nil
    acts, sent = {}, {}
    -- PAST THE REPORT CADENCE, so the report half of this is visible too: a stale
    -- armed latch does not only disarm the wrong car, it goes on TELLING THE
    -- SERVER about it every two seconds, and the server believes it.
    tick(25)

    ok(reads.armed == 2,
       'the engine is asked about the vehicle that holds the handle NOW',
       reads.armed)
    ok(did('disable') == 0 and #sent == 0,
       'and the Adder is neither disarmed nor reported armed',
       ('disables=%d sent=%d'):format(did('disable'), #sent))
    ok(V.stats().probed == 2 and V.stats().engineArmed == 1,
       'which is a second occupancy, measured rather than remembered',
       ('probed=%d armed=%d')
           :format(V.stats().probed, V.stats().engineArmed))
end

do
    -- ...AND LEAVING THE VEHICLE ENDS THE MEASUREMENT.
    --
    -- `clearProbe` was reachable from nothing but BR.VehRefuse.reset, and that
    -- function has NO CALLER anywhere in `resources/` -- only this suite -- so the
    -- latch outlived dismounts, deaths and match boundaries. The gate clears it
    -- wherever it clears `pending`, which is every place it has established that
    -- this player is not sitting in anything.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    tick()
    ok(reads.armed == 1 and V.stats().probed == 1 and #sent == 1,
       'one occupancy, one read, one report',
       ('armed=%d probed=%d sent=%d')
           :format(reads.armed, V.stats().probed, #sent))

    myVeh = 0                            -- out of the car and standing beside it
    tick()
    myVeh = 10                           -- and back into the same one
    tick()

    ok(reads.armed == 2 and V.stats().probed == 2,
       'getting out and back in is a new occupancy and is asked about again',
       ('armed=%d probed=%d'):format(reads.armed, V.stats().probed))
    ok(#sent == 2,
       'and reported at once, rather than waiting out a cadence window opened '
           .. 'before they got out', #sent)
end

-- ═══ WHEN THE SERVER IS TOLD, AND HOW OFTEN ═══

do
    -- IT IS A REPEAT, NOT AN EDGE, and the reason is the far end: this server's
    -- copy of who is in which seat is up to a roster sample behind the client's,
    -- so a single report sent on the pass the seat was taken can arrive before the
    -- server agrees anybody is sitting there -- and a lost edge is a suppression
    -- lost for the whole occupancy.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    tick()
    ok(#sent == 1, 'the first pass in the seat reports once', #sent)

    tick(19)                         -- 1900 ms later
    ok(#sent == 1, 'and nineteen more passes do not repeat it', #sent)
    tick()                           -- 2000 ms
    ok(#sent == 2, 'the cadence repeats it after two seconds', #sent)
    ok(sent[2].payload.netId == 910 and sent[2].payload.seat == -1,
       'naming the same vehicle and seat')
end

do
    -- A VEHICLE THE ENGINE DOES NOT NETWORK CANNOT BE REPORTED, because the id is
    -- the only name the two machines share. `0` is what the engine answers for
    -- one, and `0` is truthy in Lua. The GUN is still switched off: that half
    -- needs no server at all.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehNetId[10] = 0
    vehArmed[10] = true
    gunBool, gunHash = true, SEAT_GUN
    tick(2)
    ok(#sent == 0, 'a vehicle with no network id is not reported', #sent)
    ok(did('disable') == 2, 'and its gun is still held off', did('disable'))
end

do
    -- A SEAT THIS FILE CANNOT NAME. Seats past MAX_SEAT -- the back of a coach --
    -- are not walked, so there is no seat index to validate a report with and none
    -- is sent. server/vehicles.lua's CABIN_SEATS states the same limit. The
    -- vehicle-level answer still holds the gun off.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    seatPed(10, 9)
    vehArmed[10] = true
    gunBool, gunHash = true, SEAT_GUN
    tick()
    ok(reads.turret == 0, 'no seat named, no seat question asked', reads.turret)
    ok(#sent == 0, 'and nothing reported', #sent)
    ok(did('disable') == 1, 'and the gun is still switched off', did('disable'))

    -- AND IT IS A SETTLED ANSWER RATHER THAN A FAILED ONE, which is a COST
    -- assertion and has no outcome to show it: there is no seat state to confirm,
    -- so a version that treated "no seat" as "ask again" would walk ten natives
    -- every pass for as long as somebody rode in the back of a coach, and every
    -- other assertion in this block would still pass.
    tick(4)
    ok(reads.armed == 1, 'the vehicle is not re-asked on later passes',
       reads.armed)
    ok(reads.seat == MAX_SEAT_WALK,
       'and the seats are walked exactly once', reads.seat)
end

do
    -- MOVING INTO THE GUN SEAT IS A NEW CLAIM AND IS SENT AT ONCE. The cadence
    -- clock is cleared with the seat, so a player who shuffles into a turret does
    -- not wait out the remainder of a window opened by the seat they left.
    reset()
    spawn(10, MYSTERY, 9, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    vehTurret[10] = { [-1] = false, [0] = true }
    tick()
    ok(#sent == 1 and sent[1].payload.seat == -1,
       'the driving seat is reported first', #sent)

    seatPed(10, 0)
    tick()
    ok(#sent == 2 and sent[2].payload.seat == 0,
       'and the gun seat is reported on the very next pass, not two seconds '
           .. 'later', #sent)
end

do
    -- NOBODY IS REPORTED WHILE STILL CLIMBING IN. There is no seat yet, the
    -- refusal half of this file has not ruled, and a report about a vehicle
    -- somebody has not sat down in is a claim the far end would refuse anyway.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    entering, myVeh = 10, 0
    vehArmed[10] = true
    tick(3)
    ok(#sent == 0 and reads.armed == 0,
       'a player at the door reports nothing and asks nothing',
       ('%d sent, %d asked'):format(#sent, reads.armed))
end

for _, st in ipairs({ BR.PlayerState.BUS, BR.PlayerState.FREEFALL,
                      BR.PlayerState.OUT }) do
    -- AND THE GATE THE WHOLE FILE KEEPS. A spectator is OUT and the bus is
    -- carrying people; neither is a state in which anybody is working a turret,
    -- and a report from one would be a message per player per two seconds for a
    -- lobby full of people who are not playing.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    BR.State.me.state = st
    tick(3)
    ok(#sent == 0 and reads.armed == 0,
       ('nothing is asked or reported in state %s'):format(tostring(st)),
       ('%d sent, %d asked'):format(#sent, reads.armed))
end

do
    -- THE DIAGNOSTIC STILL RUNS, and it reads both new natives on whatever the
    -- player is in. A nil-index in a command nobody runs in a test is a crash on a
    -- live server at the moment somebody is trying to diagnose this very feature.
    reset()
    spawn(10, MYSTERY, 4, 'automobile')
    myVeh = 10
    vehArmed[10] = true
    tick()
    ok(pcall(commands.brvehrefuse), '/brvehrefuse prints the probe readout')
    seatPed(10, 9)
    ok(pcall(commands.brvehrefuse), 'and in a seat it cannot name')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the hand is read before client/inventory.lua empties it (#322)')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ WHY THIS SUITE LOADS client/inventory.lua AT ALL ═══
--
-- Where the seat names no gun -- the Caracara's gun seat, on the owner's own
-- test -- `disarm` takes the hash to switch off from the HAND. inventory.lua's
-- strip reads the same hand on the same TICK, takes that hash out of it and
-- puts the active slot back. Whichever of the two runs first in the pass
-- decides whether `disarm` sees the car's gun or the player's own weapon, and
-- that order is written in neither file: BR.Loop runs a band in the order its
-- callbacks registered, which is the order br_core/fxmanifest.lua loads them.
--
-- Every block above loads this file alone and cannot see that, and
-- tools/test_client.lua loads inventory.lua without this file. So this block
-- takes the order FROM THE MANIFEST, loads the two real files that way into a
-- sandbox with its own BR and its own loop registry, and drives the pass.
--
-- THE ENGINE HERE EMPTIES THE HAND THE MOMENT IT IS TOLD TO. Nothing has ruled
-- that reading out, and it is the one under which the wrong order disables
-- nothing at all. The gun is back in the hand before the next pass, which is
-- what the owner's climbing count says the engine does.
do
    -- The manifest's client scripts, in order. Comments are stripped first so
    -- a path named in a note is not read as a declaration.
    local fh = io.open(ROOT .. 'br_core/fxmanifest.lua', 'r')
    local text = fh and fh:read('a') or ''
    if fh then fh:close() end
    local at, n = {}, 0
    for line in text:gmatch('[^\n]+') do
        local code = line:gsub('%-%-.*$', '')
        for rel in code:gmatch("'(client/[^']+%.lua)'") do
            n = n + 1
            at[rel] = at[rel] or n
        end
    end
    local invAt, vehAt = at['client/inventory.lua'], at['client/vehrefuse.lua']
    ok(invAt ~= nil and vehAt ~= nil, 'the manifest declares both files',
       ('inventory=%s vehrefuse=%s'):format(tostring(invAt), tostring(vehAt)))

    local pair = { 'br_core/client/inventory.lua', 'br_core/client/vehrefuse.lua' }
    if invAt and vehAt and vehAt < invAt then pair = { pair[2], pair[1] } end

    local UNARMED = BR.Config.Gadgets.UNARMED
    local removed, up, events = {}, {}, {}

    -- EVERYTHING NOT NAMED HERE IS THIS SUITE'S OWN STUB, so the seat, the
    -- model, the hand and DisableVehicleWeapon are the variables every block
    -- above drives. A native neither side defines is a call to nil, and the
    -- error counts at the bottom of this block are where that would show.
    local env = setmetatable({
        BR = { Keys = { on = function() end }, Notify = function() end },
        -- ITS OWN EVENTS AND COMMANDS, so nothing it registers reaches the
        -- tables the blocks above read.
        RegisterNetEvent = function() end,
        AddEventHandler  = function(name, fn)
            events[name] = events[name] or {}
            table.insert(events[name], fn)
        end,
        RegisterCommand  = function() end,
        TriggerEvent     = function() end,
        TriggerServerEvent = function(name, ...)
            up[#up + 1] = { name = name, ... }
        end,
        -- THE HAND, AS THE STRIP AND THE RE-GRANT LEAVE IT.
        RemoveWeaponFromPed = function(_, h)
            removed[#removed + 1] = h
            heldHash = UNARMED
        end,
        RemoveAllPedWeapons = function() heldHash = UNARMED end,
        SetCurrentPedWeapon = function(_, h) heldHash = h end,
        GiveWeaponToPed = function() end,
        SetPedAmmo = function() end,
        SetAmmoInClip = function() end,
        SetWeaponsNoAutoswap = function() end,
        SetPlayerCanDoDriveBy = function() end,
        PlayerId = function() return 0 end,
    }, { __index = _G })
    env._G = env

    for _, f in ipairs({
        'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
        'br_lib/shared/geo.lua', 'br_lib/config/weapons.lua',
        'br_lib/config/loot.lua', 'br_lib/config/vehicles.lua',
        'br_core/client/main.lua', pair[1], pair[2],
    }) do
        local chunk, err = loadfile(ROOT .. f, 't', env)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end

    local B = env.BR
    B.State.me.state = B.PlayerState.ALIVE
    B.State.landed = true
    -- THE AMMO REPORT IS NOT WHAT THIS BLOCK IS ABOUT, and it reads a dozen
    -- natives nothing here has a reason to model.
    B.Loop.setEnabled('inv.ammo', false)

    local function errorsOf(name)
        for _, e in ipairs(B.Loop.stats()) do
            if e.name == name then return e.errors end
        end
    end

    local function reported()
        local out = {}
        for _, u in ipairs(up) do
            if u.name == B.Net.INV_STRIPPED then out[#out + 1] = u[1] end
        end
        return out
    end

    --- One pass of the sandbox's own TICK band.
    local function onePass()
        fakeTime = fakeTime + 5000
        B.Loop.step(B.Loop.TICK)
    end

    -- 1. AN EMPTY ACTIVE SLOT. The strip empties the hand and the re-grant
    --    leaves the fists in it.
    reset()
    spawn(10, CARACARA, 9, 'automobile')
    myVeh = 10
    gunBool, gunHash = false, 0               -- the seat names nothing
    heldBool, heldHash = true, ENGINE_GUN     -- and the car's gun is in the hand
    onePass()

    local d = acted('disable')
    ok(#d == 1 and d[1][1] == true and d[1][2] == ENGINE_GUN
           and d[1][3] == 10 and d[1][4] == PED,
       'the gun in the hand is disabled, read before the strip took it',
       ('%d disables, loaded %s then %s'):format(#d, pair[1], pair[2]))
    ok(#removed == 1 and removed[1] == ENGINE_GUN,
       'and the strip still takes it out of the hand', #removed)
    ok(#reported() == 1 and reported()[1] == B.NormHash(ENGINE_GUN),
       'and still reports it, for the server to drop', #reported())
    ok(heldHash == UNARMED,
       'and the hand after the pass is the fists, which is what a later '
           .. 'reader would have been handed', tostring(heldHash))

    -- 2. THE GUN BACK IN THE HAND ON THE NEXT PASS, and switched off again.
    heldHash = ENGINE_GUN
    onePass()
    ok(#acted('disable') == 2 and acted('disable')[2][2] == ENGINE_GUN,
       'and again on the next pass, when the engine hands it back',
       #acted('disable'))

    -- 3. A CARBINE IN THE ACTIVE SLOT. The re-grant puts OUR weapon in the
    --    hand, which is a row, so a later reader would switch off nothing.
    for _, fn in ipairs(events[B.Net.INV_SET] or {}) do
        fn({ slots = { { id = 'carbinerifle', kind = B.ItemKind.WEAPON,
                         clip = 30 } },
             ammo = {}, active = 1, quiet = true })
    end
    onePass()
    acts, removed = {}, {}
    heldHash = ENGINE_GUN
    onePass()
    d = acted('disable')
    ok(#d == 1 and d[1][2] == ENGINE_GUN,
       'with a carbine in the active slot, the car\'s gun is still the one '
           .. 'disabled', #d)
    ok(#removed == 1 and removed[1] == ENGINE_GUN and heldHash == CARBINE,
       'and the strip still takes it out and puts the carbine back',
       ('%d removed, hand %s'):format(#removed, tostring(heldHash)))

    ok(errorsOf('inv.apply') == 0 and errorsOf('vehrefuse.gate') == 0,
       'and neither callback threw on any of these passes',
       ('inv.apply=%s vehrefuse.gate=%s'):format(
           tostring(errorsOf('inv.apply')), tostring(errorsOf('vehrefuse.gate'))))
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the far end keeps the report per player (#329)')
-- ═══════════════════════════════════════════════════════════════════════════
--
-- ═══ WHY THE REAL br_core/server/vehicles.lua IS LOADED HERE ═══
--
-- Because the half that decides what an armament report is WORTH is on the
-- server, and it is not the sort of thing a pure function can be extracted from:
-- the whole of it is a client claim checked against natives, a roster entry and
-- two authored tables. The client half above could be perfect while this side
-- believed anybody about anything.
--
-- THE THREE PROPERTIES THAT HAVE NO IN-GAME SYMPTOM UNTIL THEY ARE WRONG:
--
--   1. IT IS PER PLAYER. The fact lives on the reporter's own roster entry, not
--      in a table keyed on the model, so one liar excuses themselves and nobody
--      else. A shared cache would pass every other assertion in this block and
--      would hand the whole match an anticheat excuse for one forged message.
--   2. IT MAY ONLY ADD. A model BR.Config.IsDisarmedVehicle names is excused
--      whether a report arrived or not, so nothing regresses and no client can
--      take an excuse away from anybody -- including itself.
--   3. IT IS CHECKED, NOT BELIEVED. The vehicle is resolved from the network id
--      on THIS side and asked who is in that seat -- citizenfx/fivem#4006 is why
--      the ped is never asked what it is in -- and a mismatch is dropped.
--
-- AND IT KEEPS THE OWNER'S RULINGS THE OWNER'S: a report about a model the
-- gamemode refuses, or about the one model exempted by hand, is refused here too,
-- so a modified client cannot reach either of them from this direction.
do
    --- A loaded server/vehicles.lua and the levers to drive it.
    local function newServer()
        -- ITS OWN BR, SET BEFORE ANY FILE LOADS. `BR = BR or {}` at the top of
        -- every file in this project would otherwise find the OUTER one through
        -- __index and the two halves of this suite would share a module table.
        local S = { now = 50000, roster = {}, seats = {}, lastVeh = {},
                    models = {}, types = {}, ids = {}, prints = {},
                    handlers = {} }
        local env = setmetatable({ BR = {} }, { __index = _G })
        env._G = env

        env.GetGameTimer = function() return S.now end
        env.print = function(m) S.prints[#S.prints + 1] = m end
        env.GetCurrentResourceName = function() return 'br_core' end
        env.RegisterNetEvent = function() end
        env.RegisterCommand  = function() end
        -- COUNTED RATHER THAN SWALLOWED: the owner's rule for this file is "don't
        -- stop them, simply file an incident", so a cancel appearing in it is a
        -- behavior change and this suite should say so.
        S.cancels = 0
        env.CancelEvent = function() S.cancels = S.cancels + 1 end
        env.Citizen = { CreateThread = function() end, Wait = function() end,
                        SetTimeout = function() end }
        env.AddEventHandler = function(n, fn)
            S.handlers[n] = S.handlers[n] or {}
            table.insert(S.handlers[n], fn)
        end
        env.TriggerEvent = function() end

        -- THE ENTITY, AS A SERVER WOULD ANSWER FOR IT.
        env.GetEntityModel = function(h) return S.models[h] end
        -- ═══ THE TYPE, PER VEHICLE, BECAUSE THIS SIDE CAN READ IT ═══
        --
        -- `GetVehicleType` IS NOT CLIENT-ONLY. `GetVehicleClass` -- the 0-22 enum
        -- -- is the one that is, and the two get confused: it is the type that
        -- catches an aircraft the model table does not name, which is what
        -- `stat.byType` exists to count. A stub answering one constant cannot tell
        -- a guard that asks with the type signal from one that asks with no
        -- signals at all, and the second of those was a hole a modified client
        -- could drive an armed helicopter through.
        env.GetVehicleType = function(h) return S.types[h] or 'automobile' end
        env.DoesEntityExist = function() return false end
        env.GetEntityType = function() return 0 end
        env.GetEntityPopulationType = function() return 5 end
        env.NetworkGetEntityOwner = function() return nil end

        -- ═══ THE TWO SEAT NATIVES, AND THE FIRST ONE LIES ON PURPOSE ═══
        --
        -- citizenfx/fivem#4006, still OPEN: server-side GetVehiclePedIsIn answers
        -- the vehicle a ped was LAST in when it is in none. Modelling that
        -- faithfully is the whole value of the stub -- a version answering 0 for a
        -- ped on foot would pass a `ridingIn` written as a bare read of it, and
        -- the armament check leans on `ridingIn` for every answer it gives.
        env.GetVehiclePedIsIn = function(ped) return S.lastVeh[ped] or 0 end
        env.GetPedInVehicleSeat = function(veh, seat)
            return (S.seats[veh] or {})[seat] or 0
        end
        -- THE ONE NATIVE THE REPORT IS RESOLVED THROUGH. An id naming nothing
        -- answers 0, which is what the engine does and what `entityFrom` reads as
        -- "no such entity".
        env.NetworkGetEntityFromNetworkId = function(id) return S.ids[id] or 0 end

        env.BR.Roster = {
            get = function(s) return S.roster[s] end,
            licenseOf = function(s)
                local r = S.roster[s]
                return r and r.license or nil
            end,
            -- The roadkill ledger registers a scheduler job at LOAD time, so
            -- without these two the file cannot load at all. It is driven in
            -- tools/test_roster.lua against the real roster; what it needs here is
            -- only to not explode.
            each = function(pred, fn)
                for s, e in pairs(S.roster) do
                    if not pred or pred(e) then fn(s, e) end
                end
            end,
            sampleIntervalMs = function() return 250 end,
        }

        for _, f in ipairs({
            'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
            'br_lib/shared/geo.lua', 'br_lib/shared/sched.lua',
            'br_lib/config/match.lua', 'br_lib/config/vehicles.lua',
            'br_core/server/vehicles.lua',
        }) do
            local chunk, err = loadfile(ROOT .. f, 't', env)
            if not chunk then
                realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
                os.exit(1)
            end
            local okc, e2 = pcall(chunk)
            if not okc then
                realPrint('\27[31mrun error\27[0m ' .. f .. ': ' .. tostring(e2))
                os.exit(1)
            end
        end

        S.env = env
        S.stats = function() return env.BR.Vehicles.stats() end

        --- Put a player in the match, in a seat of a vehicle.
        ---
        --- THE ROSTER ENTRY IS KEPT ACROSS A MOVE, AND THAT IS THE WHOLE POINT OF
        --- THIS FIXTURE. The armament report lives ON that entry, so a `sit` that
        --- built a fresh table every call would silently wipe it -- and every
        --- assertion about a report NOT following somebody into the next car would
        --- pass whether the code checked anything or not.
        ---
        --- AND A PED IS IN ONE SEAT. The old seat is cleared, because the check on
        --- the far side is a seat read: a fixture that left them in both would
        --- accept a report about the car they just got out of.
        function S.sit(src, veh, seat, model)
            local ped = 100 + src
            local e = S.roster[src]
            if e == nil then
                e = { src = src, name = 'P' .. src, matchId = 1, ped = ped,
                      license = 'license:p' .. src,
                      state = env.BR.PlayerState.ALIVE }
                S.roster[src] = e
            end
            e.ped = ped

            for _, seats in pairs(S.seats) do
                for s, p in pairs(seats) do
                    if p == ped then seats[s] = nil end
                end
            end

            S.models[veh] = model
            S.ids[900 + veh] = veh
            S.seats[veh] = S.seats[veh] or {}
            S.seats[veh][seat] = ped
            -- citizenfx/fivem#4006's stale answer, which is what the file under
            -- test has to refute with the seat read.
            S.lastVeh[ped] = veh
            return ped
        end

        --- Deliver one BR.Net.VEH_ARMED from this player.
        function S.report(src, payload)
            env.source = src
            for _, fn in ipairs(S.handlers[env.BR.Net.VEH_ARMED] or {}) do
                fn(payload)
            end
        end

        --- Is this player excused, asked the way both accusers ask?
        function S.excused(src)
            local e = S.roster[src]
            return env.BR.Vehicles.inDisarmedVehicle(e and e.ped, e)
        end

        return S
    end

    do
        -- AN UNLISTED MODEL, NO REPORT: exactly the pre-#329 answer, which is the
        -- floor everything else is measured from.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)

        -- THE SAME ASSERTION THE CLIENT BLOCK OPENS WITH, MADE AGAINST THIS
        -- SANDBOX'S OWN CONFIG: the model is in no authored row, which is the
        -- owner's requirement rather than a detail of the fixture. A suite that
        -- skipped it here would pass against a fix that wrote a row.
        ok(S.env.BR.Config.IsDisarmedVehicle(MYSTERY) == false
           and S.env.BR.Config.VehicleRefusalFor(MYSTERY) == nil,
           'the model is in no authored row on this side either')

        ok(S.excused(1) == false,
           'an unlisted model with no report is not excused',
           tostring(S.excused(1)))

        -- ...AND ONE REPORT LATER IT IS.
        S.report(1, { netId = 910, seat = -1 })
        ok(S.excused(1) == true,
           'and the engine\'s own answer, reported and checked, excuses it',
           tostring(S.excused(1)))
        ok(S.stats().probes == 1 and S.stats().probesBad == 0,
           'counted as believed rather than as refused',
           ('probes=%d bad=%d'):format(S.stats().probes, S.stats().probesBad))
        ok(#S.prints == 0, 'and nothing is printed about it', #S.prints)
    end

    do
        -- ═══ THE PROPERTY THE WHOLE DESIGN TURNS ON: PER PLAYER, NOT PER MODEL ═══
        --
        -- Two players in two vehicles of the SAME model. One reports; the other
        -- must be unaffected. A cache keyed on the model hash would be cheaper,
        -- would pass every other assertion in this block, and would mean one
        -- forged message excused that model for everybody in the match.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.sit(2, 11, -1, MYSTERY)
        S.report(1, { netId = 910, seat = -1 })

        ok(S.excused(1) == true, 'the player who reported is excused')
        ok(S.excused(2) == false,
           'and the player beside them in the same model is NOT',
           tostring(S.excused(2)))
    end

    do
        -- A REPORT ABOUT A VEHICLE THIS SERVER DOES NOT AGREE THEY ARE IN. The
        -- claim names a real vehicle -- somebody else's -- and the check is the
        -- seat read on THIS side, never the client's word.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.sit(2, 11, -1, MYSTERY)
        S.report(1, { netId = 911, seat = -1 })

        ok(S.excused(1) == false, 'naming another player\'s car excuses nothing',
           tostring(S.excused(1)))
        ok(S.stats().probes == 0 and S.stats().probesBad == 1,
           'and is counted as refused', ('probes=%d bad=%d')
               :format(S.stats().probes, S.stats().probesBad))
        ok(#S.prints == 1 and S.prints[1]:find('does not match', 1, true) ~= nil,
           'and says so once, in words that accuse nobody',
           S.prints[1] or 'nothing printed')
    end

    do
        -- A REPORT NAMING A SEAT THEY ARE NOT IN. The seat is the validation key,
        -- so this is the same check one argument along -- and a file that dropped
        -- the seat and walked the vehicle itself would accept it.
        local S = newServer()
        S.sit(1, 10, 0, MYSTERY)         -- really in the gun seat
        S.report(1, { netId = 910, seat = -1 })
        ok(S.excused(1) == false, 'claiming the driving seat from the gun seat '
           .. 'excuses nothing', tostring(S.excused(1)))
        ok(S.stats().probesBad == 1, 'and is refused', S.stats().probesBad)
    end

    for _, bad in ipairs({
        { name = 'nothing at all',   payload = nil },
        { name = 'a string',         payload = 'armed' },
        { name = 'no network id',    payload = { seat = -1 } },
        { name = 'a zero id',        payload = { netId = 0, seat = -1 } },
        { name = 'an unknown id',    payload = { netId = 12345, seat = -1 } },
        { name = 'no seat',          payload = { netId = 910 } },
        { name = 'a float seat',     payload = { netId = 910, seat = 0.5 } },
        { name = 'a seat past the cabin',
          payload = { netId = 910, seat = 99 } },
        { name = 'a seat below the driver',
          payload = { netId = 910, seat = -2 } },
    }) do
        -- EVERY SHAPE A CLIENT CAN CHOOSE TO SEND. `math.tointeger` answers nil
        -- for a float, a string and a table, and ZERO IS TESTED FOR EXPLICITLY
        -- because `0` is truthy in Lua -- it is what the engine answers for a
        -- vehicle it does not network, so a client naming it is naming nothing.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.report(1, bad.payload)
        ok(S.excused(1) == false,
           ('a report carrying %s excuses nothing'):format(bad.name),
           tostring(S.excused(1)))
        ok(S.stats().probes == 0,
           ('and is never believed (%s)'):format(bad.name), S.stats().probes)
    end

    do
        -- A PLAYER WITH NO PED SAMPLED YET. `entityFrom` answers 0 for an empty
        -- seat as well, so a 0 ped compared rather than refused would match every
        -- empty seat in the world.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.roster[1].ped = 0
        S.report(1, { netId = 910, seat = -1 })
        ok(S.stats().probes == 0, 'a player with no ped is not believed',
           S.stats().probes)
    end

    do
        -- ═══ THE PROBE MAY ONLY ADD ARMAMENT AND NEVER CLEAR IT ═══
        --
        -- A listed model is excused with no report at all, and goes on being
        -- excused while a report about a DIFFERENT vehicle sits on the entry. The
        -- authored table answers first and its yes is final, so there is no
        -- message a client can send that takes an excuse away from anybody.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.sit(1, 11, -1, CARACARA)       -- the same player, now in a listed one
        S.lastVeh[101] = 11
        ok(S.excused(1) == true,
           'a listed model is excused with no report at all',
           tostring(S.excused(1)))

        S.report(1, { netId = 910, seat = -1 })   -- about the car they left
        ok(S.excused(1) == true,
           'and a stale report about another vehicle does not unexcuse it',
           tostring(S.excused(1)))
    end

    do
        -- AND A BELIEVED REPORT DOES NOT FOLLOW THEM INTO THE NEXT CAR. The
        -- handle, the model and the match all have to match the vehicle they are
        -- in NOW -- otherwise a fact about the Technical somebody was in would
        -- excuse the Adder they are in next.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.report(1, { netId = 910, seat = -1 })
        ok(S.excused(1) == true, 'excused in the car that was reported')

        S.sit(1, 12, -1, ADDER)
        S.lastVeh[101] = 12
        ok(S.excused(1) == false,
           'and not in the ordinary car they got into afterwards',
           tostring(S.excused(1)))

        -- ...NOR IN A SECOND CAR OF THE SAME MODEL, WHICH IS THE ASSERTION THE
        -- HANDLE CHECK IS THE ONLY THING THAT PASSES. Two identical cars parked
        -- side by side agree on the model, so a record compared on the model alone
        -- would carry an excuse from one into the other -- and the honest client
        -- reports the new one within two seconds anyway, so nothing is lost by
        -- being exact about which vehicle was measured.
        S.sit(1, 13, -1, MYSTERY)
        S.lastVeh[101] = 13
        ok(S.excused(1) == false,
           'nor in a second car of the same model they have not reported',
           tostring(S.excused(1)))
        -- PAST THE WINDOW, because the report about the first car opened it. An
        -- honest client's cadence is two seconds and the floor here is 900ms, so
        -- this is the same wait a real one does.
        S.now = S.now + 1000
        S.report(1, { netId = 913, seat = -1 })
        ok(S.excused(1) == true, 'until they report that one too')
    end

    do
        -- A RECYCLED HANDLE IS NOT THE SAME VEHICLE. The model is compared as well
        -- as the handle, and it costs nothing because the line above already read
        -- it for the authored table.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.report(1, { netId = 910, seat = -1 })
        S.models[10] = ADDER             -- same handle, different vehicle
        ok(S.excused(1) == false,
           'a handle that has been recycled under the report is not excused',
           tostring(S.excused(1)))
    end

    do
        -- A MATCH CHANGE VOIDS IT, exactly as every other per-player record in
        -- this file is rebuilt on one: a fact about last round is not a fact.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.report(1, { netId = 910, seat = -1 })
        S.roster[1].matchId = 2
        ok(S.excused(1) == false, 'a report from the previous match is not read',
           tostring(S.excused(1)))
    end

    do
        -- ONE PER WINDOW. An honest client sends one every two seconds; what this
        -- bounds is one sending them as fast as it can, and the clock is stamped
        -- on ARRIVAL so a flood of lies is bounded too.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.report(1, { netId = 910, seat = -1 })
        S.report(1, { netId = 910, seat = -1 })
        ok(S.stats().probeThrottled == 1,
           'a second report inside the window is throttled',
           S.stats().probeThrottled)
        ok(S.excused(1) == true, 'and the first one still stands')

        S.now = S.now + 900
        S.report(1, { netId = 910, seat = -1 })
        ok(S.stats().probes == 2, 'and the window reopens', S.stats().probes)
        ok(S.stats().probeReports == 3, 'with everything that arrived counted',
           S.stats().probeReports)
    end

    do
        -- ═══ THE OWNER'S OWN RULINGS, WHICH NO REPORT MAY REACH PAST ═══
        --
        -- A REFUSED MODEL IS EMPTIED, NOT DRIVEN. The honest client never reports
        -- one -- its probe sits below the refusal -- so this is for the modified
        -- one, and what it stops is an excuse for the mounted gun of a stolen
        -- Buzzard.
        local S = newServer()
        S.sit(1, 10, -1, BUZZARD)
        S.report(1, { netId = 910, seat = -1 })
        ok(S.excused(1) == false, 'a refused model is not excused by a report',
           tostring(S.excused(1)))
        ok(S.stats().probesBad == 1, 'the report is refused', S.stats().probesBad)
    end

    do
        -- ═══ AND AN ARMED AIRCRAFT THE MODEL TABLE DOES NOT NAME ═══
        --
        -- THE GUARD ABOVE WAS ASKED WITH NO SIGNALS AT ALL, under a comment saying
        -- that was "all this side can read anyway". It is not: `GetVehicleType` is
        -- readable on the server -- only `GetVehicleClass` is not -- and it is the
        -- signal that catches the aircraft config/vehicles.lua has not got a row
        -- for. So the guard blocked model-table refusals only, and a modified
        -- client sitting in an unlisted armed helicopter passed every check this
        -- handler makes: the model resolves, the seat holds its ped, the ruling
        -- comes back nil. Its report was BELIEVED, which relabels its mounted-gun
        -- shots from NO_WEAPON to VEHICLE_GUN -- a moderation record quietly not
        -- filed.
        --
        -- AN HONEST CLIENT NEVER REACHES IT, which is what makes this the guard's
        -- whole job rather than a corner: client/vehrefuse.lua's own class net
        -- refuses a helicopter and returns ABOVE its probe, so the only sender that
        -- can get here is the one the guard exists for.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.types[10] = 'heli'

        ok(S.env.BR.Config.VehicleRefusalFor(MYSTERY) == nil,
           'the model table has no row for it, which is the requirement')
        ok(S.env.BR.Config.VehicleRefusalFor(MYSTERY, {
               typeOf = function() return 'heli' end,
           }) == S.env.BR.Config.VehicleRefusal.FLIES,
           'and the TYPE is what rules on it -- the signal this side can read')

        S.report(1, { netId = 910, seat = -1 })
        ok(S.excused(1) == false,
           'a report about an aircraft the table missed excuses nothing',
           tostring(S.excused(1)))
        ok(S.stats().probes == 0 and S.stats().probesBad == 1,
           'and is refused rather than believed',
           ('probes=%d bad=%d'):format(S.stats().probes, S.stats().probesBad))
        ok(S.stats().byType == 1,
           'counted where every other type-caught refusal is counted, which is '
               .. 'the proof the signal was passed at all', S.stats().byType)
    end

    do
        -- AND THE FIRETRUCK. Its hose IS a vehicle weapon and the owner ruled that
        -- using it is not an incident; the exemption is the authored table's, and a
        -- report must not become a second route to a model it names.
        local S = newServer()
        S.sit(1, 10, -1, FIRETRUK)
        S.report(1, { netId = 910, seat = -1 })
        ok(S.excused(1) == false,
           'the model exempted by hand is not reachable by report',
           tostring(S.excused(1)))
        ok(S.stats().probesBad == 1, 'that report is refused too',
           S.stats().probesBad)
    end

    do
        -- A CALLER THAT PASSES NO ENTRY GETS THE PRE-#329 ANSWER, which is the
        -- conservative direction: the authored table and nothing else. Both real
        -- callers hold the entry already -- server/damage.lua's `s` and
        -- server/strip.lua's `e` -- and a build where one of them did not would
        -- lose the widening rather than gain a hole.
        local S = newServer()
        local ped = S.sit(1, 10, -1, MYSTERY)
        S.report(1, { netId = 910, seat = -1 })
        ok(S.env.BR.Vehicles.inDisarmedVehicle(ped) == false,
           'asked with no roster entry, the table is the whole answer',
           tostring(S.env.BR.Vehicles.inDisarmedVehicle(ped)))
        ok(S.env.BR.Vehicles.inDisarmedVehicle(nil, S.roster[1]) == false,
           'and nil is not an error')
    end

    do
        -- THE CONSOLE LINE IS PRINTED ONCE PER PLAYER PER MATCH, and counted every
        -- time. A line per refused message is an amplifier on a path a client
        -- chooses the rate of -- server/strip.lua's own objection about its
        -- ANTICHEAT line -- and the first says everything the ten thousandth would.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        for i = 1, 5 do
            S.now = S.now + 1000
            S.report(1, { netId = 999, seat = -1 })
        end
        ok(S.stats().probesBad == 5, 'five refusals are all counted',
           S.stats().probesBad)
        ok(#S.prints == 1, 'and one line is printed', #S.prints)

        S.roster[1].matchId = 2
        S.now = S.now + 1000
        S.report(1, { netId = 999, seat = -1 })
        ok(#S.prints == 2, 'and one more in the next match', #S.prints)
    end

    do
        -- NOTHING IS BELIEVED FROM SOMEBODY OUTSIDE A MATCH. The gate the rest of
        -- this file keeps: a lobby ped and a corpse are outside any round, so there
        -- is nothing for the fact to be about and nothing for it to expire with.
        for _, st in ipairs({ 'LOBBY', 'OUT', 'DBNO' }) do
            local S = newServer()
            S.sit(1, 10, -1, MYSTERY)
            S.roster[1].state = S.env.BR.PlayerState[st]
            S.report(1, { netId = 910, seat = -1 })
            ok(S.stats().probes == 0,
               ('a report from a %s player is not believed'):format(st),
               S.stats().probes)
        end

        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.roster[1].matchId = nil
        S.report(1, { netId = 910, seat = -1 })
        ok(S.stats().probes == 0, 'nor is one from a player in no match',
           S.stats().probes)
    end

    do
        -- AND NOTHING IN THIS PATH CANCELS ANYTHING OR FILES ANYTHING. The owner's
        -- rule for this file is "don't stop them, simply file an incident", and an
        -- armament report is neither: it decides how a refused shot is LABELLED.
        local S = newServer()
        S.sit(1, 10, -1, MYSTERY)
        S.report(1, { netId = 910, seat = -1 })
        ok(S.cancels == 0, 'no CancelEvent', S.cancels)
        ok(S.stats().counted == 0 and S.stats().occupied == 0,
           'and no refused-vehicle count either',
           ('counted=%d occupied=%d')
               :format(S.stats().counted, S.stats().occupied))
    end
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
