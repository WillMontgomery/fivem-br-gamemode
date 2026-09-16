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
local reads = { model = 0, class = 0, type = 0, asks = 0, gun = 0 }

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
    if throws.held then error('stale handle') end
    return heldBool, heldHash
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

local function reset()
    entering, myVeh, boolShape = 0, 0, 1
    vehModel, vehClass, vehType, vehLock = {}, {}, {}, {}
    acts, notices = {}, {}
    reads = { model = 0, class = 0, type = 0, asks = 0, gun = 0 }
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
local function spawn(veh, model, class, vtype)
    vehModel[veh] = model
    vehClass[veh] = class or 4          -- Muscle: an ordinary car
    vehType[veh] = vtype or 'automobile'
    vehLock[veh] = 1                    -- VEHICLELOCK_UNLOCKED
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
-- held off rather than refused. `caracara2` is the model the issue was opened
-- about -- armed, ordinary Off-road class, permitted by omission until it was
-- written down. `technical` is the same ruling on a row that was always there.
local CARACARA2 = 0xAF966F3C
local TECHNICAL = 0x83051506
--- A vehicle weapon hash. Any non-zero number: what the file does with it is
--- pass it back to the engine untouched, which is the property asserted.
local SEAT_GUN = 0x1D6FDE47
--- VEHICLE_WEAPON_PLAYER_BUZZARD: a REAL mounted-gun hash, and in no row of
--- BR.Config.WeaponByHash. That is the whole property the `unnamed-gun` counter
--- tests for, so it is a published hash rather than an invented one.
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
    spawn(10, CARACARA2, 2, 'automobile')   -- Off-road: no net sees this model
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
    -- THE SEAT THE NATIVE HAS NO OPINION ABOUT, WHICH IS THE FIRETRUCK CASE
    -- WEARING A DIFFERENT MODEL. Nothing is disabled because there is nothing to
    -- name; the pass must not throw and must not eject.
    reset()
    spawn(10, CARACARA2, 2, 'automobile')
    myVeh = 10
    throws.gun = true
    heldBool, heldHash = true, ENGINE_GUN   -- and the engine put it in the hand
    tick(2)
    ok(did('disable') == 0, 'a native that throws disables nothing', did('disable'))
    ok(did('leave') == 0, 'and does not turn into an ejection', did('leave'))
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
    local pok = pcall(tick, 2)
    DisableVehicleWeapon = saved
    ok(pok, 'a build without DisableVehicleWeapon does not take the pass down')

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

-- ═══ THE `unnamed-gun` COUNTER, WHICH HAS TO MEAN THE FIRETRUCK AND NOT A
--     DRIVER ═══
--
-- `disarm` runs for ANY seat by design, so "the seat named no gun" is the
-- ORDINARY case: the driver of a Technical, an Insurgent or a Caracara has no
-- vehicle weapon at all and would climb this counter ten times a second for the
-- whole time they drive one normally. The first version of this file counted
-- exactly that and printed it under a line telling the operator that a climbing
-- number meant a missing StripExemptVehicles row.
--
-- What the firetruck actually was is BOTH HALVES AT ONCE: the seat names no gun
-- AND the engine has put something in the hand that this gamemode issues nobody.

do
    -- THE ORDINARY DRIVER. Holding a rifle out of this gamemode's own arsenal,
    -- in a disarmed vehicle whose driving seat names no gun. Nothing to disable,
    -- nothing to report, and nothing to count.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    gunBool, gunHash = false, 0
    heldBool, heldHash = true, CARBINE
    tick(5)
    ok(V.stats().unnamedGun == 0,
       'a driver holding an issued weapon is not the firetruck case',
       V.stats().unnamedGun)
end

do
    -- AND AN EMPTY HAND IS NOT IT EITHER. `0` is TRUTHY in Lua, so a counter
    -- written as `if held then` counts every pass of every drive.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, 0
    tick(5)
    ok(V.stats().unnamedGun == 0, 'nor is an empty hand', V.stats().unnamedGun)
end

do
    -- THE FIRETRUCK. The seat names nothing and the hand holds a hash in no row
    -- of BR.Config.WeaponByHash, which is the only pair that says this model
    -- needs an answer of its own.
    reset()
    spawn(10, CARACARA2, 2, 'automobile')
    myVeh = 10
    gunBool, gunHash = false, 0
    heldBool, heldHash = true, ENGINE_GUN
    tick(3)
    ok(V.stats().unnamedGun == 3,
       'a gun the seat will not name, in the hand, in no row of ours, is',
       V.stats().unnamedGun)
    ok(did('disable') == 0, 'and there is still nothing to disable',
       did('disable'))
end

do
    -- THE PARACHUTE IS IN NO WEAPON ROW AND IS NOT A GUN. client/skydive.lua
    -- grants it on purpose and client/inventory.lua's strip excuses it by hash;
    -- counting it here would be counting our own grant as an engine fault.
    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, BR.Config.Gadgets.PARACHUTE
    tick(3)
    ok(V.stats().unnamedGun == 0, 'nor is the parachute', V.stats().unnamedGun)
end

do
    -- A HAND NATIVE THAT THROWS OR DECLINES TO ANSWER COUNTS NOTHING. This is a
    -- diagnostic, and a silence that INFLATES it is worse than one that loses a
    -- reading: the number is what an operator would act on.
    for _, shape in ipairs({ 0, false }) do
        reset()
        spawn(10, TECHNICAL, 4, 'automobile')
        myVeh = 10
        heldBool, heldHash = shape, ENGINE_GUN
        tick(2)
        ok(V.stats().unnamedGun == 0,
           ('a hand BOOL of %s is no opinion'):format(tostring(shape)),
           V.stats().unnamedGun)
    end

    reset()
    spawn(10, TECHNICAL, 4, 'automobile')
    myVeh = 10
    throws.held = true
    local pok = pcall(tick, 2)
    ok(pok and V.stats().unnamedGun == 0,
       'and a hand native that throws does not take the pass down or count')
end

do
    -- AN ORDINARY CAR IS NEVER ASKED WHAT IS IN THE HAND EITHER. The model test
    -- in `disarm` is what keeps both natives off the path of every player in
    -- every car in the match.
    reset()
    spawn(10, ADDER, 7, 'automobile')
    myVeh = 10
    heldBool, heldHash = true, ENGINE_GUN
    tick(5)
    ok(V.stats().unnamedGun == 0,
       'an ordinary car counts nothing whatever is in the hand',
       V.stats().unnamedGun)
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
    -- mounted weapon to name and nothing to hold off.
    reset()
    spawn(10, CARACARA2, 2, 'automobile')
    entering, myVeh = 10, 0
    gunBool, gunHash = true, SEAT_GUN
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
    -- AND WARMUP IS, because the showroom sells the Caracara and the warmup is
    -- where it is bought and driven.
    reset()
    spawn(10, CARACARA2, 2, 'automobile')
    myVeh = 10
    gunBool, gunHash = true, SEAT_GUN
    BR.State.me.state = BR.PlayerState.WARMUP
    tick()
    ok(did('disable') == 1, 'but WARMUP disarms, where the Caracara is bought',
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

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
