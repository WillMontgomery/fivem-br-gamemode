-- Which stage of a landing is slow -- the ruler, under test.
--
-- "the loop that runs to learn that a player has landed on their feet - that
--  either doesn't run often enough or takes too long" -- the owner, 2026-08-30,
-- and then, with the size of it: "I land on the ground, and my inventory
-- doesn't show up for sometimes >5 seconds. This is the same loop that starts
-- the storm timer once everyone has landed."
--
-- ═══ WHY THIS IS A SUITE OF ITS OWN ═══
--
-- tools/test_client.lua already loads client/skydive.lua and steps it, and its
-- descent block is thorough -- about the PROMPT. Every assertion in it is a
-- question about what the box said and none is a question about WHEN anything
-- happened, because until now there was no time in this file to ask about.
--
-- What is under test here is a measuring instrument, and an instrument has one
-- failure mode that ordinary code does not: it can agree with the thing it
-- measures by accident. A stall timer that took its own "the ped is down" from
-- one of the clauses of the landing test would read zero for exactly the
-- landing the owner is complaining about -- the clause lies, the contact time
-- lies with it, and the readout says the loop was instant. So the properties
-- worth pinning are:
--
--   * a five-second stall MEASURES five seconds, and NAMES the clause that held
--     it, from a ground truth that no ped task owns;
--   * a landing the branch never detects at all says so, rather than printing a
--     plausible number for a branch that did not fire;
--   * a healthy landing reads zero and is not dressed up as a stall;
--   * and one landing prints one line.
--
-- ═══ THE NATIVES ANSWER NUMBERS ═══
--
-- IsPedFalling, IsPedOnFoot, IsEntityInWater and IsEntityInAir are all BOOL
-- natives, this project has shipped ten instances of reading one raw, and in
-- Lua `not 0` is false. Every stub below answers 1/0 rather than true/false, so
-- a sampler that drops the isTrue() wrapper does not quietly stop stamping --
-- it fails here.
--
-- Run:  lua tools/test_landtime.lua        (or via tools/verify.sh)

-- ------------------------------------------------------------ native stubs ---

local realPrint = print
local logged = {}
function print(s) logged[#logged + 1] = tostring(s) end

local fakeTime = 0
function GetGameTimer() return fakeTime end
function PlayerId() return 0 end
function PlayerPedId() return 1 end
function GetPlayerServerId() return 1 end
function GetCurrentResourceName() return 'br_core' end
function GetHashKey(s) return #tostring(s) * 1000 + 7 end

--- Threads are RECORDED, not run. Everything they do -- the chute give, the
--- report retry, the disarm sweep -- is somebody else's subject, and running
--- them under a Wait() that does not wait would spin a give-verify loop ten
--- times inside one tick for no assertion's benefit.
local threads = {}
Citizen = {
    CreateThread = function(fn) threads[#threads + 1] = fn end,
    Wait         = function() end,
    SetTimeout   = function() end,
}

local handlers = {}
function AddEventHandler(n, fn)
    handlers[n] = handlers[n] or {}
    table.insert(handlers[n], fn)
end
function RegisterNetEvent() end

local events = {}
function TriggerEvent(n, ...)
    events[#events + 1] = { name = n, args = { ... } }
    for _, fn in ipairs(handlers[n] or {}) do fn(...) end
end

local sent = {}
function TriggerServerEvent(n, ...) sent[#sent + 1] = { name = n, at = fakeTime } end

local commands = {}
function RegisterCommand(n, fn) commands[n] = fn end

-- THE PED, AS THE DROP MACHINE ASKS ABOUT IT. `inAir` is the one field that is
-- not a copy of something the landing predicate reads: it is the physics
-- underneath the ped, which is what the instrument is supposed to be timing
-- from.
local ped = {
    cs       = -1,      -- GetPedParachuteState
    falling  = false,
    onFoot   = true,
    inWater  = false,
    inAir    = false,
    inVeh    = false,
    agl      = 0.0,
    speed    = 0.0,
    hasChute = false,
    ammo     = 0,
}

--- 1 and 0, not true and false. See the header.
local function B(v) return v and 1 or 0 end

function IsPedFalling()            return B(ped.falling) end
function IsPedOnFoot()             return B(ped.onFoot) end
function IsEntityInWater()         return B(ped.inWater) end
function IsEntityInAir()           return B(ped.inAir) end
function IsPedInAnyVehicle()       return B(ped.inVeh) end
function IsPedInParachuteFreeFall() return B(false) end
function HasPedGotWeapon()         return B(ped.hasChute) end
function GetPlayerHasReserveParachute() return 0 end
function GetPedParachuteState()    return ped.cs end
function GetEntityHeightAboveGround() return ped.agl end
function GetEntitySpeed()          return ped.speed end
function GetAmmoInPedWeapon()      return ped.ammo end
function GetControlInstructionalButton() return '' end

for _, n in ipairs({
    'ClearHelp', 'ClearPedTasks', 'ClearPedTasksImmediately',
    'DisableControlAction', 'ForcePedToOpenParachute', 'FreezeEntityPosition',
    'GiveWeaponToPed', 'RemoveAllPedWeapons', 'RemoveWeaponFromPed',
    'SetControlNormal', 'SetEntityVelocity', 'SetEntityVisible', 'SetPedAmmo',
    'SetPlayerCanLeaveParachuteSmokeTrail', 'SetPlayerParachuteModelOverride',
    'SetPlayerParachuteSmokeTrailColor', 'TaskParachute',
}) do _G[n] = function() end end

-- ---------------------------------------------------------------- modules ---

local ROOT = 'resources/[fivem-royale]/'

local function loadAll(list)
    for _, f in ipairs(list) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end
end

loadAll({
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/loot.lua',
    'br_lib/shared/storm_solve.lua',
    'br_core/client/main.lua',      -- the loop registry and BR.State; first
    'br_core/client/natives.lua',   -- the REAL ChuteState, not a copy of it
})

-- The collaborators skydive.lua reaches for, each at the surface it uses them
-- through. None of them is the subject here.
local hudPushes = 0
function BR.PushHud() hudPushes = hudPushes + 1 end

BR.Cosmetics = {
    applyChute = function() end, applyTrail = function() end,
    clearTrail = function() end, emitTrailThisFrame = function() end,
    showTrail  = function() end, engineTrailColour = function() return '0,0,0' end,
    trailArmed = false, trailOn = false,
}
BR.Dui = {
    page = function(n) return { name = n } end,
    send = function() end, drawScreen = function() end,
    drawWorld = function() end, drawOnEntity = function() end,
    ready = function() return true end,
}
BR.Keys = { on = function() end, labelFor = function() return 'SPACE' end,
            set = function() end }
BR.Inv = { reapply = function() end }

loadAll({ 'br_core/client/skydive.lua' })

local CS = BR.Native.ChuteState

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function fire(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

--- One TICK pass, at the band's real interval.
local function tick(ms)
    fakeTime = fakeTime + (ms or 100)
    BR.Loop.step(BR.Loop.TICK)
end

local function ticks(n, ms)
    for _ = 1, n do tick(ms) end
end

--- Every landtime line said so far.
local function lines()
    local out = {}
    for _, s in ipairs(logged) do
        if s:find('landtime', 1, true) then out[#out + 1] = s end
    end
    return out
end

local function lastLine()
    local l = lines()
    return l[#l]
end

--- One field out of the readout, as text. `nil` when the line does not carry it
--- at all, which is a different failure from carrying 'n/a'.
local function field(line, name)
    if not line then return nil end
    return line:match(name .. ' (%-?%d+)') or line:match(name .. ' (n/a)')
end

--- NIL-SAFE ON PURPOSE. A regression that stops the line being printed at all
--- must be reported as the assertions it fails, not as a traceback three
--- assertions later -- a suite that crashes tells whoever broke it far less
--- than one that names the four things that stopped being true.
--- @param line string|nil
--- @param s string
local function has(line, s)
    return line ~= nil and line:find(s, 1, true) ~= nil
end

--- Put the player in the plane door and out of it, with the mirror saying what
--- the server says during a real descent.
local function jump()
    logged, sent, events = {}, {}, {}
    BR.State.me.state = BR.PlayerState.BUS
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    fire(BR.Net.STATE, { state = BR.MatchState.BUS })
    fire('br:drop:begin', { heading = 0.0 })
    BR.State.me.state = BR.PlayerState.FREEFALL
end

--- Under the canopy, hundreds of metres up: off its feet, not falling, chute
--- open, physics agreeing there is nothing underneath.
local function underCanopy()
    ped.cs, ped.falling = CS.OPEN, false
    ped.onFoot, ped.inWater, ped.inAir = false, false, true
    ped.agl, ped.speed = 300.0, 14.0
    ped.hasChute, ped.ammo = true, 1
end

--- Feet down and everything agreeing about it.
local function touchDown()
    ped.cs, ped.falling = CS.ON_BACK, false
    ped.onFoot, ped.inWater, ped.inAir = true, false, false
    ped.agl, ped.speed = 0.4, 0.0
end

--- Reset between scenarios, the way a new round does.
local function reset()
    fire(BR.Net.STATE, { state = BR.MatchState.WAITING })
    BR.State.me.state = BR.PlayerState.LOBBY
    BR.State.landed = false
    ped.cs, ped.falling = -1, false
    ped.onFoot, ped.inWater, ped.inAir, ped.inVeh = true, false, false, false
    ped.agl, ped.speed = 0.0, 0.0
    ped.hasChute, ped.ammo = false, 0
    ticks(2)
    logged, sent, events = {}, {}, {}
end

-- ------------------------------------------------------- the readout exists ---

describe('the instrument is wired into the band that runs the drop')
do
    local found, band = nil, nil
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 'skydive.landtime' then found, band = s, s.band end
    end
    ok(found ~= nil, 'a callback named skydive.landtime is registered')
    ok(band == BR.Loop.TICK, 'in the 10Hz band, alongside the drop machine',
        tostring(band))

    -- REGISTRATION ORDER IS LOAD-BEARING -- the registry runs a band in
    -- registration order, so the printer must come AFTER skydive.state or every
    -- landing would carry a spurious 100ms of instrument in stage 4. It cannot
    -- be read off BR.Loop.stats(), which sorts by cost; it is asserted
    -- BEHAVIOURALLY instead, by `ui 0` on the healthy landing below, which is
    -- only reachable if the printer sees the branch in the same pass.
end

-- ------------------------------------------------------- the healthy landing ---

describe('a landing that works reads as a landing that works')
do
    reset()
    jump()
    underCanopy()
    ticks(20)                       -- a glide; the machine sees us airborne
    ok(lastLine() == nil, 'nothing is said while the player is still in the air')

    touchDown()
    local contactAt = fakeTime + 100
    tick()                          -- the branch fires on this pass

    ok(BR.State.landed == true, 'the drop machine has seen the landing')

    -- The server agrees four ticks later.
    ticks(3)
    BR.State.me.state = BR.PlayerState.ALIVE
    tick()
    local serverAt = fakeTime

    local l = lastLine()
    ok(l ~= nil, 'one line is printed for the landing',
        table.concat(logged, '\n'))
    ok(field(l, 'detect') == '0',
        'THE CLIENT TEST AGREED ON THE TICK THE FEET CAME DOWN -- detect 0', l)
    ok(field(l, 'ui') == '0',
        'and the interface was un-hidden on the same tick, without the server', l)
    ok(field(l, 'server') == tostring(serverAt - contactAt),
        'while the server took the four ticks it actually took', l)
    ok(has(l, 'detected on contact'),
        'and the verdict does not dress a healthy landing up as a stall', l)

    -- CONTACT IS NOT ALLOWED TO GO MISSING ON THE BEST POSSIBLE DROP. The
    -- debounce wants two samples and the branch fires on the first, so without
    -- the commit in landBranch this line would read `contact NEVER` -- the
    -- readout's alarm for the physics never agreeing we were down.
    ok(not has(l, 'contact NEVER'),
        'and the contact time is real, not "never"', l)

    ok(#lines() == 1, 'exactly one line, not one per tick',
        ('%d lines'):format(#lines()))

    ticks(30)
    ok(#lines() == 1, 'and it stays one line however long the player stands there',
        ('%d lines'):format(#lines()))
end

-- ------------------------------------------------------------- the stall ---

describe('a five-second stall measures five seconds and names the clause')
do
    reset()
    jump()
    underCanopy()
    ticks(20)

    -- THE PARACHUTE LANDING, AS THE ENGINE ACTUALLY LEAVES IT. The feet are
    -- down -- the physics says so -- but the parachute task still owns the ped,
    -- so IsPedOnFoot is false, the canopy is still OPEN, and the player is
    -- running the landing out at 6 m/s. `grounded` needs on-foot, or water, or
    -- the canopy fallback, whose thresholds are agl < 2.0 AND speed < 2.0. The
    -- speed is the one that fails.
    ped.inAir, ped.agl = false, 0.4
    ped.onFoot, ped.cs, ped.falling = false, CS.OPEN, false
    ped.speed = 6.0

    local contactAt = fakeTime + 100    -- the first touching sample
    ticks(52)                           -- 5.2 seconds on the ground, undetected
    ok(BR.State.landed == false,
        'the drop machine has NOT seen the landing, which is the bug')
    ok(lastLine() == nil, 'and nothing has been said yet -- it is not over')

    -- The player stops running; the canopy lets go.
    touchDown()
    tick()
    local branchAt = fakeTime
    local stall = tostring(branchAt - contactAt)
    ticks(2)
    BR.State.me.state = BR.PlayerState.ALIVE
    tick()

    local l = lastLine()
    ok(l ~= nil, 'the landing is eventually detected and printed', l)
    ok(field(l, 'detect') == stall and tonumber(stall) >= 5000,
        'AND THE STALL IS MEASURED, NOT ROUNDED AWAY -- five seconds of it',
        ('%s (expected %s)'):format(tostring(field(l, 'detect')), stall))
    ok(has(l, 'held by gnd'),
        'and the readout names `gnd` -- the grounded clause -- as what held it',
        l)
    ok(field(l, 'gnd') == stall, 'which came true only at the end', l)
    ok(field(l, 'nfall') == '0',
        'while the falling test was never the problem on this drop', l)
    ok(field(l, 'nopen') == '0', 'nor the canopy-opening test', l)
    ok(has(l, 'spdMax 6.0'),
        'AND THE THRESHOLD THAT DID IT IS ON THE LINE: speed peaked at 6 m/s '
        .. 'against a fallback that wants under 2', l)

    -- THE MEASUREMENT DOES NOT COME FROM THE CLAUSES IT IS JUDGING. `foot` was
    -- false for the whole stall, and if ground contact had been taken from it
    -- -- or from `grounded`, or from anything else the predicate reads -- the
    -- stall would have measured zero and the readout would have exonerated the
    -- very code it is pointing at.
    ok(field(l, 'foot') == stall,
        'and on-foot was false for the whole stall, so contact did not come '
            .. 'from it', l)
end

-- ---------------------------------------- the branch that never fires at all ---

describe('a landing the client never detects says exactly that')
do
    reset()
    jump()
    underCanopy()
    ticks(20)

    -- THE COORDINATOR'S PRIME SUSPECT, HELD OPEN. The feet are down and
    -- IsPedFalling never lets go -- so `not IsPedFalling` is false for ever,
    -- the branch cannot fire, and what ends the wait is the SERVER's
    -- stuck-lander net at five seconds (stuckLanderMs, server/match.lua).
    ped.inAir, ped.agl, ped.speed = false, 0.4, 0.0
    ped.onFoot, ped.cs = true, CS.ON_BACK
    ped.falling = true

    local contactAt = fakeTime + 100
    ticks(50)
    ok(BR.State.landed == false, 'the branch has not fired')
    BR.State.me.state = BR.PlayerState.ALIVE   -- the server's own net
    tick()
    local promoted = tostring(fakeTime - contactAt)

    ok(lastLine() == nil,
        'the line is held briefly, in case the branch is merely late')
    ticks(31)

    local l = lastLine()
    ok(l ~= nil, 'but it is said rather than waited on for ever', l)
    ok(field(l, 'detect') == 'n/a',
        'AND IT REFUSES TO INVENT A DETECTION TIME -- detect n/a', l)
    ok(has(l, 'NEVER TRUE: nfall'),
        'naming the one clause that never came true', l)
    ok(field(l, 'server') == promoted and tonumber(promoted) >= 5000,
        'while the server promoted at five seconds -- which is the stuck-lander '
            .. 'net, not this file',
        ('%s (expected %s)'):format(tostring(field(l, 'server')), promoted))
    ok(field(l, 'airb') == 'n/a',
        'and airborneNow never answered false either, because it reads the same '
            .. 'native', l)
    ok(field(l, 'ui') == promoted,
        'so what the player waited for was the server, start to finish', l)
end

-- ------------------------------------------------------------ the debounce ---

describe('a rooftop clipped on the way down is not a landing')
do
    reset()
    jump()
    underCanopy()
    ticks(20)

    -- One tick of collision, mid-glide, three hundred metres from anywhere the
    -- player is going to stand.
    ped.inAir = false
    tick()
    ped.inAir = true
    ticks(30)                        -- three more seconds of glide

    touchDown()
    tick()
    ticks(2)
    BR.State.me.state = BR.PlayerState.ALIVE
    tick()

    local l = lastLine()
    ok(l ~= nil, 'the real landing still prints', l)
    ok(field(l, 'detect') == '0',
        'AND IT IS TIMED FROM THE REAL ONE -- a single touching tick three '
            .. 'seconds earlier does not become the contact time', l)
    ok(field(l, 'nfall') == '0' and field(l, 'gnd') == '0',
        'and the clause stamps taken under the clip were thrown away with it', l)
end

-- ------------------------------------------------------- the vehicle ending ---

describe('the drop that ends in a driver seat is timed too')
do
    reset()
    jump()
    underCanopy()
    ticks(20)

    ped.inAir, ped.agl = false, 0.4
    ped.inVeh = true
    tick()
    ticks(2)
    BR.State.me.state = BR.PlayerState.ALIVE
    tick()

    local l = lastLine()
    ok(l ~= nil, 'a drop finished from a vehicle seat gets a line as well', l)
    ok(field(l, 'detect') == '0',
        'with a real detection time, not the never-fired reading', l)
    -- The seat branch returns before the sampler ever runs, so there is no
    -- debounce to commit -- and the contact time comes from asking the physics
    -- again rather than from the seat, which is what keeps `contact NEVER`
    -- meaning only one thing.
    ok(not has(l, 'contact NEVER'),
        'and a ground-contact time that came from the physics, not the seat', l)

    -- AND ITS FOUR CLAUSES ARE REPORTED AS UNASKED, NOT AS FAILED. This branch
    -- returns above the landing test, so `NEVER TRUE: seen,nopen,nfall,gnd` --
    -- which is what the readout said here before -- would send the next round
    -- of this issue after four clauses that were never evaluated.
    ok(has(l, 'vehicle seat'),
        'and the verdict names the ending rather than blaming the clauses', l)
    ok(not has(l, 'NEVER TRUE'),
        'so an unasked question is not reported as a failed one', l)
end

describe('a seat entered after the feet were already down is timed from the feet')
do
    -- THE HALF THE FRESH PHYSICS READ CANNOT DO. The player touches down and
    -- the landing test does not fire -- the canopy is still attached and they
    -- are still moving -- and a tick later they get into a car. Asking the
    -- physics again at THAT moment would time the landing from the car door;
    -- the debounce the sampler already has open knows the feet came down a
    -- tick earlier, and that is the honest contact time.
    reset()
    jump()
    underCanopy()
    ticks(20)

    ped.inAir, ped.agl = false, 0.4
    ped.onFoot, ped.cs, ped.speed = false, CS.OPEN, 6.0
    local contactAt = fakeTime + 100
    tick()                          -- one touching sample; no landing detected
    ok(BR.State.landed == false, 'the landing test has not fired')

    ped.inVeh = true
    tick()
    local branchAt = fakeTime
    ticks(2)
    BR.State.me.state = BR.PlayerState.ALIVE
    tick()

    local l = lastLine()
    ok(field(l, 'detect') == tostring(branchAt - contactAt),
        'the seat ending is timed from the tick the feet came down, not from '
            .. 'the tick the door closed',
        ('%s (expected %d)'):format(tostring(field(l, 'detect')),
                                    branchAt - contactAt))
end

describe('a drop the server never registered does not fake a promotion')
do
    -- THE MIRROR STILL SAYS ALIVE FROM THE LAST ROUND. If the server has not
    -- yet been told about this jump, the state this client holds is whatever it
    -- was before -- and a stage-3 stamp taken from it would time a promotion
    -- that has not happened, at the instant the player left the plane.
    reset()
    logged, sent, events = {}, {}, {}
    BR.State.me.state = BR.PlayerState.ALIVE      -- never moved to FREEFALL
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    fire(BR.Net.STATE, { state = BR.MatchState.BUS })
    fire('br:drop:begin', { heading = 0.0 })

    underCanopy()
    ticks(20)
    touchDown()
    tick()
    ok(BR.State.landed == true, 'the client detects its own landing regardless')

    ticks(205)                       -- past the twenty-second cap

    local l = lastLine()
    ok(l ~= nil, 'the record is still spoken at the cap', l)
    ok(field(l, 'server') == 'n/a',
        'AND STAGE 3 IS n/a RATHER THAN A NUMBER -- the server never called us '
            .. 'airborne, so it never promoted us either', l)
    ok(field(l, 'detect') == '0',
        'while stage 2, which needs nobody, is measured as usual', l)
end

-- ------------------------------------------------------------- /brdropdbg ---

describe('the last landing can be read back after the console has scrolled')
do
    logged = {}
    pcall(commands['brdropdbg'], nil, {}, '')
    local dbg = table.concat(logged, '\n')
    ok(dbg:find('landtime', 1, true) ~= nil,
        'brdropdbg repeats the last landing line', dbg)
end

-- ----------------------------------------------------- the formatter, pure ---
--
-- The reductions, fed records of landings that never happened. This is the half
-- that can be asserted exactly, the way main.lua's reduceBench is: a readout
-- that cannot be given a broken landing on demand is a readout whose broken
-- cases are only ever seen by the owner.

describe('the readout, as a pure function')
do
    local base = 10000

    local healthy = {
        exitAt = 1000, contactAt = base, branchAt = base, reportAt = base,
        serverAt = base + 300, uiAt = base,
        csContact = 0, csLast = 0, aglMax = 0.4, spdMax = 0.5,
        at = { seen = base, nopen = base, nfall = base, gnd = base,
               foot = base, airb = base },
    }
    local l = BR.Skydive.landLine(healthy)
    ok(has(l, 'detected on contact'),
        'a branch that fired on contact is called that', l)
    ok(field(l, 'descent') == '9000',
        'and the descent length is the door to the ground', l)

    local stalled = {}
    for k, v in pairs(healthy) do stalled[k] = v end
    stalled.branchAt, stalled.uiAt = base + 4200, base + 4200
    stalled.serverAt = base + 4500
    stalled.at = { seen = base, nopen = base, nfall = base + 100,
                   gnd = base + 4200, foot = base + 4200, airb = base + 4200 }
    l = BR.Skydive.landLine(stalled)
    ok(has(l, 'held by gnd'),
        'the LAST clause to come true is the one named', l)
    ok(field(l, 'detect') == '4200' and field(l, 'server') == '4500',
        'and every stage is an offset from contact, so they are comparable', l)

    local never = {}
    for k, v in pairs(stalled) do never[k] = v end
    never.branchAt = nil
    never.at = { seen = base, nopen = base, gnd = base + 4200 }
    l = BR.Skydive.landLine(never)
    ok(has(l, 'NEVER TRUE: nfall'),
        'a clause with no stamp at all is named as never true, not skipped', l)
    ok(field(l, 'detect') == 'n/a',
        'and a branch that never fired has no detection time', l)

    local noContact = {
        exitAt = 1000, contactAt = nil, branchAt = base, reportAt = base,
        serverAt = base + 200, uiAt = base, csContact = nil, csLast = 2,
        aglMax = 0.0, spdMax = 0.0,
        at = { seen = base, nopen = base, nfall = base, gnd = base },
    }
    l = BR.Skydive.landLine(noContact)
    ok(has(l, 'contact NEVER'),
        'A LINE WITH NO GROUND TRUTH SAYS SO rather than rebasing quietly', l)
    ok(field(l, 'descent') == 'n/a',
        'and refuses to report a descent length it cannot know', l)

    -- The one outcome that would mean the ruler had drifted off the predicate.
    local drift = {}
    for k, v in pairs(healthy) do drift[k] = v end
    drift.branchAt = nil
    l = BR.Skydive.landLine(drift)
    ok(has(l, 'SAMPLER DRIFT'),
        'all four clauses true with no branch is reported as an instrument '
            .. 'fault, not as a landing', l)
end

-- ---------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
