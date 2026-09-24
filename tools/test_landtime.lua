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
    -- WHERE THE GROUND IS, for the pull-chute warning (#352). The ped is `agl`
    -- above `groundZ` -- the seabed, when that is below zero -- and `waterZ` is
    -- a surface GetWaterHeight can see, nil where it answers nothing, which over
    -- open ocean is most of the time.
    groundZ  = 30.0,
    waterZ   = nil,
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
--- Measured to `groundZ`, so the position and the height above ground agree the
--- way the engine's do: a ped `agl` up stands at `groundZ + agl`.
function GetEntityCoords() return { x = 0.0, y = 0.0, z = ped.groundZ + ped.agl } end
function GetWaterHeight()
    if ped.waterZ then return 1, ped.waterZ end
    return 0, 0.0
end

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

loadAll({
    'br_core/client/skydive.lua',
    -- THE REAL WALKTHROUGH, AFTER THE DROP AS fxmanifest ORDERS IT (#369). The
    -- "Loot up" toast is gated on a fact only tutorial.lua raises, so a stub here
    -- would be asserting the stub. Its ticks stand down for a player who never
    -- started it, which is every block but the toast's.
    'br_core/client/tutorial.lua',
})

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

--- The parachute task's freefall, AS THE ENGINE ANSWERS FOR IT. IS_PED_ON_FOOT
--- is TRUE here -- measured live, 2026-08-04, and pinned in test_client's descent
--- block -- and that one fact is why #245 was reopened. IsPedFalling has never been
--- measured inside the task, so it is left at the worse of its two answers:
--- false, which leaves nothing in the old landing test that could tell this ped
--- from one standing in a field.
local function inFreefall()
    ped.cs, ped.falling = CS.ON_BACK, false
    ped.onFoot, ped.inWater, ped.inAir = true, false, true
    ped.agl, ped.speed = 400.0, 50.0
    ped.hasChute, ped.ammo = true, 1
end

--- Down on its feet with the task gone: `cs -1`, as the owner's line ended.
local function downFromFreefall()
    ped.cs, ped.falling = CS.NONE, false
    ped.onFoot, ped.inWater, ped.inAir = true, false, false
    ped.agl, ped.speed = 1.0, 0.0
end

--- Was DROP_LANDED ever sent?
local function reported()
    for _, s in ipairs(sent) do
        if s.name == BR.Net.DROP_LANDED then return true end
    end
    return false
end

--- THE SERVER, AS FAR AS ONE LANDING GOES: it agrees on the tick after a
--- DROP_LANDED reaches it, and without one its stuck-lander net promotes a player
--- who has held one altitude for stuckLanderMs (server/match.lua). Both are the
--- real sources of `server` on the line, so a landing the client never reports is
--- rescued here exactly as it was on 2026-09-23, rather than never ending.
---
--- `promotedAt` is when it did, on the harness clock. NOT the line's `server`:
--- that is an offset from contact, and on a line with no contact the base IS the
--- promotion, so it reads 0 exactly when the net was all there was.
--- @param n integer  ticks
--- @param downAt integer|nil  when the ped came to rest; nil while still falling
local promotedAt = nil
local function serve(n, downAt)
    for _ = 1, n do
        tick()
        if BR.State.me.state == BR.PlayerState.FREEFALL
           and (reported() or (downAt and fakeTime - downAt
                                  >= BR.Config.Match.stuckLanderMs)) then
            BR.State.me.state = BR.PlayerState.ALIVE
            promotedAt = fakeTime
        end
    end
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
    ped.groundZ, ped.waterZ = 30.0, nil
    ticks(2)
    logged, sent, events = {}, {}, {}
    promotedAt = nil
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

-- ------------------------------------- the drop the latch could not see ---
--
-- The owner, 2026-09-23, the only player in the match, down on his feet:
--
--   [br_core] landtime contact NEVER (ms after contact): detect n/a report n/a
--   server 0 ui 0 | NEVER TRUE: seen,nopen,nfall,gnd | seen n/a nopen n/a
--   nfall n/a gnd n/a foot n/a airb n/a | cs nil>-1 aglMax 0.0 spdMax 0.0
--   descent n/a
--
-- `seen` is the drop latch, and the ruler starts on it: no contact, no stamp and
-- no maximum is taken until it is armed. So that whole line is ONE fact -- the
-- latch never armed -- and the latch armed only on IS_PED_ON_FOOT answering
-- false, which the parachute task's freefall never does. Nothing about it is
-- solo: no line of the drop path counts players.

describe('a drop ridden to the ground in freefall is a landing (the owner, 2026-09-23)')
do
    reset()
    jump()
    inFreefall()
    serve(40)                       -- four seconds of freefall, never pulled

    ok(BR.State.landed == false and not reported(),
        'NOT A LANDING IN MID-AIR, on-foot and not-falling though the ped reads '
            .. '-- the false DROP_LANDED the latch exists to stop')

    downFromFreefall()
    local contactAt = fakeTime + 100
    serve(90, contactAt)

    local l = lastLine()
    ok(l ~= nil, 'the landing is printed', table.concat(logged, '\n'))
    ok(field(l, 'detect') == '0' and not has(l, 'contact NEVER'),
        'AND IT IS DETECTED ON CONTACT -- the owner read `contact NEVER` and '
            .. '`NEVER TRUE: seen` here', l)
    ok(BR.State.landed == true and field(l, 'report') == '0',
        'so the HUD comes up and the report leaves on the tick the feet do', l)
    ok(promotedAt ~= nil
       and promotedAt - contactAt < BR.Config.Match.stuckLanderMs,
        'and the server is TOLD, not rescued five seconds later by its '
            .. 'stuck-lander net',
        ('promoted %s ms after contact'):format(
            promotedAt and tostring(promotedAt - contactAt) or 'never'))
end

describe('an open canopy the engine still calls on-foot is a landing too')
do
    -- UNMEASURED, AND THAT IS WHY IT IS HERE. Nobody has read IS_PED_ON_FOOT
    -- under an open canopy on this build; the one indirect reading (#131, the
    -- trail prompt that failed twice behind a `not IsPedOnFoot` gate) says it may
    -- well be true there too. If it is, the old latch never armed on ANY drop.
    reset()
    jump()
    inFreefall()
    serve(20)
    ped.cs, ped.falling, ped.onFoot = CS.OPEN, false, true
    ped.agl, ped.speed = 300.0, 14.0
    serve(20)
    ok(BR.State.landed == false and not reported(),
        'not a landing under the canopy, whatever on-foot answers there')

    touchDown()
    local contactAt = fakeTime + 100
    serve(90, contactAt)

    local l = lastLine()
    ok(field(l, 'detect') == '0' and has(l, 'detected on contact'),
        'and the landing is found on contact', l)
end

describe('the in-air veto cannot strand a player who is down')
do
    -- THE VETO IS THE NEW WAY TO GET THIS WRONG, and a player it strands is
    -- worse off than one it misses: the machine stays armed on the ground, with
    -- detach dead and the floor loaded. So each of the readings it takes is
    -- given its worst answer on the ground, one at a time, and the landing must
    -- still be found.
    local cases = {
        { 'on its feet, with IsEntityInAir still saying air',
          function() touchDown(); ped.inAir, ped.agl = true, 1.0 end },
        { 'on a roof the height probe measures past, to the street below',
          function() touchDown(); ped.agl = 40.0 end },
        { 'in the sea, with IsEntityInAir saying air and the height to the seabed',
          function()
              ped.cs, ped.falling, ped.onFoot = CS.NONE, false, false
              ped.inWater, ped.inAir = true, true
              ped.agl, ped.speed = 30.0, 1.0
          end },
    }
    for _, c in ipairs(cases) do
        reset()
        jump()
        underCanopy()
        serve(20)
        c[2]()
        serve(3)
        ok(BR.State.landed == true and reported(),
            'a landing ' .. c[1], lastLine() or table.concat(logged, '\n'))
    end

    -- AND THE FIRST OF THOSE SAYS SO ON THE LINE. The ruler times from the same
    -- IsEntityInAir, so a landing it never agreed to is exactly the reading
    -- `seen but never down` exists for.
    reset()
    jump()
    underCanopy()
    serve(20)
    cases[1][2]()
    serve(40)
    local l = lastLine()
    ok(has(l, 'contact NEVER') and has(l, 'seen but never down'),
        'with IsEntityInAir named as the reading that never let go', l)
end

describe('a drop that never leaves the ground says so, and measures nothing')
do
    -- THE SOLO-ARTIFACT READING, now distinguishable from a blind latch. A record
    -- open over a ped that was never in the air cannot arm the latch -- correctly
    -- -- and the line must say that, not name three clauses it never asked.
    reset()
    jump()
    downFromFreefall()
    local restAt = fakeTime
    serve(90, restAt)

    local l = lastLine()
    ok(has(l, 'NEVER TRUE: seen -- nopen,nfall,gnd were not asked'),
        'THE ONE CLAUSE THAT FAILED IS NAMED, and the three never asked are said '
            .. 'to be unasked', l)
    ok(has(l, 'aglMax n/a spdMax n/a'),
        'AND THE MAXIMA MEASURED NOTHING, SO THEY SAY n/a -- `0.0` was read as '
            .. '"no fall was seen"', l)
end

describe('a latch that armed over a ped the physics never put down says that instead')
do
    reset()
    jump()
    underCanopy()
    serve(20)
    -- Held in the air: stuck on something the collision does not count, so the
    -- server's net (a still altitude) is what ends it.
    ped.speed = 0.0
    serve(90, fakeTime)

    local l = lastLine()
    ok(has(l, 'seen but never down -- nopen,nfall,gnd were not asked'),
        'the armed latch is not reported as a clause that never came true', l)
    ok(not has(l, 'NEVER TRUE'), 'so no clause is blamed at all', l)
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

-- ------------------------------------------------------- the "Loot up" toast ---
--
-- Owner, 2026-09-23: "please only ever show the 'loot up' toast for new players
-- who just completed the tutorial. otherwise nobody needs to see that." (#369)
--
-- Every landing used to say it. Now the first drop after a FINISHED walkthrough
-- claims it at the door and its landing says it; every other landing is silent.

describe('the "Loot up" toast is for the first landing after a finished walkthrough')
do
    local LOOT_UP = 'Loot up before the storm comes!'

    --- How many times the toast has been put up since `events` was last cleared.
    local function lootUps()
        local n = 0
        for _, e in ipairs(events) do
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.TOAST
               and type(e.args[2]) == 'table' and e.args[2].text == LOOT_UP then
                n = n + 1
            end
        end
        return n
    end

    --- The in-game half on the pad, ended the way the page ends it: `done` is
    --- the last card dismissed, and without it the run was abandoned.
    local function walkthrough(done)
        reset()
        BR.State.me.state = BR.PlayerState.WARMUP
        fire('br:tutorial:game', true)
        fire('br:tutorial:game', false, done)
    end

    --- Out of the door, down under a canopy, onto its feet.
    local function dropAndLand()
        jump()
        underCanopy()
        ticks(20)
        touchDown()
        serve(5, fakeTime)
    end

    reset()
    dropAndLand()
    ok(BR.State.landed == true, 'a player who never touched the walkthrough lands')
    ok(lootUps() == 0, 'AND IS NOT TOLD TO LOOT UP -- "nobody needs to see that"',
        ('%d toasts'):format(lootUps()))

    walkthrough(false)
    dropAndLand()
    ok(lootUps() == 0,
        'nor is a player who abandoned it -- an abandoned run is not a completion',
        ('%d toasts'):format(lootUps()))

    walkthrough(true)
    dropAndLand()
    ok(lootUps() == 1,
        'A PLAYER WHO JUST FINISHED IT IS, ON THE LANDING THAT FOLLOWS',
        ('%d toasts'):format(lootUps()))
    ticks(30)
    ok(lootUps() == 1, 'once, however long they stand there',
        ('%d toasts'):format(lootUps()))

    reset()
    dropAndLand()
    ok(lootUps() == 0, 'AND NEVER AGAIN -- their next match lands in silence',
        ('%d toasts'):format(lootUps()))

    -- THE GAP. Finished on the pad, then off it before the bus: the next door
    -- is the next match's, and it is still their first landing since.
    walkthrough(true)
    reset()
    dropAndLand()
    ok(lootUps() == 1,
        'a finish outlives leaving before the bus, to the next match\'s landing',
        ('%d toasts'):format(lootUps()))

    -- CLAIMED AT THE DOOR. A drop killed mid-air spends it unshown, rather than
    -- saving it for a landing matches later.
    walkthrough(true)
    jump()
    underCanopy()
    ticks(20)
    fire(BR.Net.STATE, { state = BR.MatchState.ENDED })
    reset()
    dropAndLand()
    ok(lootUps() == 0,
        'THE FIRST DROP AFTER FINISHING IS THE ONLY ONE THAT CAN SAY IT -- a '
            .. 'match killed mid-air does not hand it to the next',
        ('%d toasts'):format(lootUps()))

    -- AND A DROP THAT NEVER CAME THROUGH A DOOR -- the re-arm net's -- does not
    -- inherit what an earlier, unlanded drop claimed.
    walkthrough(true)
    jump()
    underCanopy()
    ticks(20)
    fire(BR.Net.STATE, { state = BR.MatchState.ENDED })
    reset()
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    fire(BR.Net.STATE, { state = BR.MatchState.BUS })
    BR.State.me.state = BR.PlayerState.FREEFALL   -- the server's word; no door
    underCanopy()
    ticks(20)
    touchDown()
    serve(5, fakeTime)
    ok(BR.State.landed == true, 'the re-armed drop lands')
    ok(lootUps() == 0,
        'and says nothing: no door, no "Loot up"',
        ('%d toasts'):format(lootUps()))

    -- AND A FIRST DROP THE NET ARMED CLAIMS IT, rather than leaving it for the
    -- next door -- which would be a later landing than the first one (#369).
    walkthrough(true)
    reset()
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    fire(BR.Net.STATE, { state = BR.MatchState.BUS })
    BR.State.me.state = BR.PlayerState.FREEFALL   -- the server's word; no door
    underCanopy()
    ticks(20)
    touchDown()
    serve(5, fakeTime)
    ok(BR.State.landed == true and lootUps() == 1,
        'the first drop after finishing says it even when the net armed it',
        ('%d toasts'):format(lootUps()))
    reset()
    dropAndLand()
    ok(lootUps() == 0,
        'AND THE NEXT DOOR DOES NOT -- the drop the net armed spent it',
        ('%d toasts'):format(lootUps()))
end

-- ------------------------------------------- the last call to pull the chute ---
--
-- Owner, 2026-09-23 (#352): "yes it's okay if late landers can die on bad
-- touchdown - but we can give them a quick urgent toast when they're 100m from
-- the ground if they've not pulled the chute yet." The wording, his, in bold:
-- "**Press {key} to pull your chute!**".
--
-- Every freefall here is the engine's as measured -- IS_PED_ON_FOOT true, the
-- physics saying air -- so the auto-open floor stays out of it, as it does in a
-- real drop (#362).

describe('a freefall is told to pull the chute at 100 m, once, and only a freefall')
do
    local PULL = 'Press {key:brdeploy} to pull your chute!'

    --- Every "pull your chute" put up since `events` was last cleared.
    local function pulls()
        local out = {}
        for _, e in ipairs(events) do
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.TOAST
               and type(e.args[2]) == 'table' and e.args[2].text == PULL then
                out[#out + 1] = e.args[2]
            end
        end
        return out
    end

    --- How many times it was taken down, by the key it went up with.
    local function clears(key)
        local n = 0
        for _, e in ipairs(events) do
            local d = e.args[2]
            if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.TOAST
               and type(d) == 'table' and d.clear == true
               and key ~= nil and d.key == key then
                n = n + 1
            end
        end
        return n
    end

    --- One tick at each height, on the way down.
    local function fallTo(...)
        for _, h in ipairs({ ... }) do
            ped.agl = h
            tick()
        end
    end

    --- The bold is the envelope's `b` parts: every word of his sentence in one,
    --- and the key a `{key:}` token in a `t` part of its own, so the page draws
    --- it as the player's own binding.
    local function boldWithKey(p)
        if type(p) ~= 'table' or type(p.parts) ~= 'table' then return false end
        local flat, keys = {}, 0
        for _, part in ipairs(p.parts) do
            if type(part.b) == 'string' then
                flat[#flat + 1] = part.b
            elseif part.t == '{key:brdeploy}' then
                flat[#flat + 1] = part.t
                keys = keys + 1
            else
                return false
            end
        end
        return keys == 1 and table.concat(flat) == p.text
    end

    local n = function() return ('%d said'):format(#pulls()) end

    -- 1. THE DROP HE MEANT: out of the door, canopy stowed, all the way down.
    reset()
    jump()
    inFreefall()
    ticks(5)
    fallTo(300.0, 200.0, 101.0, 100.5)
    ok(#pulls() == 0, 'nothing is said above 100 m', n())
    fallTo(100.0)
    local p = pulls()
    ok(#p == 1, 'AT 100 M ABOVE THE GROUND IT IS SAID', n())
    ok(p[1] ~= nil and p[1].text == PULL,
        'in his words, with the deploy key as a token', p[1] and p[1].text)
    ok(boldWithKey(p[1]), 'IN BOLD, with the key a cap between the bold words')
    ok(p[1] ~= nil and p[1].tone == 'danger',
        'urgent: the most urgent tone the stack has', p[1] and p[1].tone)
    ok(p[1] ~= nil and type(p[1].key) == 'string'
       and type(p[1].ms) == 'number' and p[1].ms <= 3000,
        'quick, and keyed so the canopy or the ground can take it down')
    local key = p[1] and p[1].key

    fallTo(80.0, 50.0, 20.0, 6.0)
    ok(#pulls() == 1, 'ONCE -- never again on the way down', n())

    downFromFreefall()
    serve(3, fakeTime)
    ok(BR.State.landed == true, 'precondition: the freefall lands')
    ok(clears(key) == 1, 'THE LANDING TAKES IT DOWN',
        ('%d clears'):format(clears(key)))
    ticks(20)
    ok(#pulls() == 1 and clears(key) == 1,
        'and nothing more is said, or cleared, on the ground', n())

    -- 2. THE CHUTE ALREADY OUT: pulled at 150, and never told.
    reset()
    jump()
    inFreefall()
    ticks(5)
    ped.agl, ped.cs = 150.0, CS.OPENING
    tick()
    ped.cs, ped.speed = CS.OPEN, 14.0
    fallTo(100.0, 60.0, 20.0)
    ok(#pulls() == 0, 'A CANOPY PULLED ABOVE 100 M IS NEVER TOLD TO PULL', n())

    -- ...nor told once the canopy has gone again: the task unwinding mid-air
    -- leaves the chute state NONE, and that chute was already pulled.
    reset()
    jump()
    inFreefall()
    ticks(5)
    ped.agl, ped.cs = 150.0, CS.OPEN
    tick()
    ped.cs = CS.NONE
    fallTo(90.0, 40.0)
    ok(#pulls() == 0, 'a chute that has been out is never asked for again', n())

    -- 3. PULLED AFTER BEING TOLD: the canopy takes it down, once.
    reset()
    jump()
    inFreefall()
    ticks(5)
    fallTo(200.0, 95.0)
    key = pulls()[1] and pulls()[1].key
    ok(#pulls() == 1, 'precondition: told at 95 m', n())
    ped.cs = CS.OPENING
    tick()
    ok(clears(key) == 1, 'THE CANOPY OPENING TAKES IT DOWN',
        ('%d clears'):format(clears(key)))
    ped.cs = CS.OPEN
    fallTo(70.0, 40.0)
    ok(clears(key) == 1 and #pulls() == 1,
        'once, and it is not said again under the canopy',
        ('%d clears, %s'):format(clears(key), n()))

    -- 4. A REVIVE-KEY ARRIVAL: 150 m over the van with the chute on the back, a
    --    fall like any other -- but the server has the player ALIVE, and it is
    --    not a freefall to warn about.
    reset()
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    fire(BR.Net.STATE, { state = BR.MatchState.BUS })
    fire(BR.Net.STATE, { state = BR.MatchState.PLAYING })
    BR.State.me.state = BR.PlayerState.ALIVE
    fire('br:drop:begin',
        { x = 0.0, y = 0.0, z = 180.0, heading = 0.0, speed = 0.0 })
    events = {}
    inFreefall()
    fallTo(150.0, 100.0, 60.0, 20.0)
    ok(#pulls() == 0, 'A REVIVE-KEY ARRIVAL IS NOT WARNED', n())

    -- 5. WATER IS GROUND. Over the sea the height above ground runs to the
    --    seabed, and GetWaterHeight answers nothing there.
    reset()
    jump()
    inFreefall()
    ped.groundZ = -60.0            -- the seabed, 60 m under the sea
    ticks(5)
    fallTo(170.0)                  -- 110 m over the water
    ok(#pulls() == 0, 'at 110 m over the sea, nothing', n())
    fallTo(155.0)                  -- 95 m over the water, 155 over the seabed
    ok(#pulls() == 1,
        'THE SEA IS THE GROUND -- told at 95 m over the water, with the seabed '
            .. '155 m down', n())

    -- ...and a lake the engine can see, twelve meters deep.
    reset()
    jump()
    inFreefall()
    ped.groundZ, ped.waterZ = 50.0, 62.0
    ticks(5)
    fallTo(115.0)                  -- 103 m over the lake
    ok(#pulls() == 0, 'at 103 m over a lake, nothing', n())
    fallTo(110.0)                  -- 98 m over the lake, 110 over its bed
    ok(#pulls() == 1, 'AND A LAKE IS THE GROUND TOO', n())

    -- ...but water UNDER the ground is not a surface anybody lands on.
    reset()
    jump()
    inFreefall()
    ped.groundZ, ped.waterZ = 30.0, 10.0
    ticks(5)
    fallTo(95.0)
    ok(#pulls() == 1, 'water the engine reports below the ground moves nothing',
        n())

    -- 6. ONCE PER DROP, EVEN THROUGH THE RE-ARM NET. Told, landed, and off a
    --    ledge before the server has agreed: the net arms the machine again for
    --    a player who is still FREEFALL to the server, and that is still the
    --    same drop.
    reset()
    jump()
    inFreefall()
    ticks(5)
    fallTo(90.0)
    downFromFreefall()
    tick()
    ok(BR.State.landed == true and #pulls() == 1,
        'precondition: told, and down', n())
    ped.falling, ped.inAir, ped.agl = true, true, 60.0
    ticks(3)
    fallTo(40.0, 10.0)
    ok(#pulls() == 1, 'NOT TOLD TWICE IN ONE DROP -- the re-arm net is no door',
        n())

    -- ...and a drop that landed untold is not told after it. The server had not
    -- registered the jump, so the fall was never a FREEFALL to this client; its
    -- word arrives after touchdown, and the player steps off a ledge.
    reset()
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    fire(BR.Net.STATE, { state = BR.MatchState.BUS })
    BR.State.me.state = BR.PlayerState.BUS
    fire('br:drop:begin', { heading = 0.0 })
    inFreefall()
    ticks(5)
    fallTo(90.0, 40.0)
    downFromFreefall()
    tick()
    ok(BR.State.landed == true and #pulls() == 0,
        'precondition: down, never told, the server not yet caught up', n())
    BR.State.me.state = BR.PlayerState.FREEFALL
    ped.falling, ped.inAir, ped.agl = true, true, 60.0
    ticks(3)
    ok(#pulls() == 0, 'ONCE LANDED, NEVER -- whatever the server says after', n())

    -- 7. A ROUND'S FIRST DROP IS OWED IT, HOWEVER IT ARMED. The last drop spent
    --    it; the net arms this one, with no door.
    reset()
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    fire(BR.Net.STATE, { state = BR.MatchState.BUS })
    BR.State.me.state = BR.PlayerState.FREEFALL   -- the server's word; no door
    inFreefall()
    ticks(5)
    fallTo(90.0)
    ok(#pulls() == 1, 'a drop the net armed is told as well', n())

    -- 8. AND EVERY DOOR IS A NEW DROP, whatever the round has already said.
    downFromFreefall()
    serve(3, fakeTime)
    events = {}
    BR.State.me.state = BR.PlayerState.BUS
    fire('br:drop:begin', { heading = 0.0 })
    BR.State.me.state = BR.PlayerState.FREEFALL
    inFreefall()
    ticks(5)
    fallTo(90.0)
    ok(#pulls() == 1, 'a door is owed its own warning', n())

    -- 9. NEVER ON THE GROUND. A drop the net arms over a player lying in a field
    --    -- ragdolled, off their feet, nothing but ground under them -- is not
    --    a player to tell to pull anything.
    reset()
    fire(BR.Net.STATE, { state = BR.MatchState.WARMUP })
    fire(BR.Net.STATE, { state = BR.MatchState.BUS })
    BR.State.me.state = BR.PlayerState.FREEFALL
    ped.cs, ped.falling, ped.onFoot, ped.inAir = CS.NONE, false, false, false
    ped.agl = 0.5
    ticks(10)
    ok(#pulls() == 0, 'A PLAYER ON THE GROUND IS NOT TOLD', n())

    -- 10. A SEAT IS THE GROUND, as far as the warning goes.
    reset()
    jump()
    inFreefall()
    ticks(5)
    fallTo(60.0)
    key = pulls()[1] and pulls()[1].key
    ped.inVeh = true
    tick()
    ok(#pulls() == 1 and clears(key) == 1,
        'a drop that ends in a vehicle seat takes it down',
        ('%d clears'):format(clears(key)))

    -- ...and one that ended there untold stays untold, out of the car and off
    -- a ledge with the server still calling it a freefall.
    reset()
    jump()
    inFreefall()
    ticks(5)
    ped.agl = 150.0
    ped.inVeh = true
    tick()
    ped.inVeh = false
    ped.falling, ped.inAir, ped.agl = true, true, 60.0
    ticks(3)
    ok(#pulls() == 0, 'a seat is a landing -- nothing is said after it', n())

    -- 11. THE 100 IS CONFIG. A server that wants the call earlier gets it earlier.
    local was = BR.Config.Drop.pullChuteAGL
    ok(was == 100.0, 'BR.Config.Drop.pullChuteAGL ships at the owner\'s 100 m',
        tostring(was))
    BR.Config.Drop.pullChuteAGL = 250.0
    reset()
    jump()
    inFreefall()
    ticks(5)
    fallTo(260.0)
    ok(#pulls() == 0, 'above a tuned 250 m, nothing', n())
    fallTo(240.0)
    ok(#pulls() == 1, 'AND AT 240 IT IS SAID -- the height is read from config',
        n())
    BR.Config.Drop.pullChuteAGL = was
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
