-- The lobby entrance, and the ordering the whole thing exists for.
--
-- ═══ WHAT THIS IS FOR ═══
--
-- "when peds switch between local and networked, they do so in the same spot.
-- this means for a split second any player's ped who joins into lobby or
-- readies into warmup is seen by other players in the lobby." -- the owner,
-- 2026-08-29.
--
-- The fix is an ORDER: teleport to the warmup spawn first, become a networked
-- ped second. An order is exactly the kind of claim a static gate cannot make
-- and a playtest cannot see -- the window is one frame wide, on somebody else's
-- screen, and the wrong version and the right version are identical in a
-- screenshot. So this suite loads the real client/spawn.lua and the real
-- client/lobbyped.lua over stubbed natives, runs the actual transition, and
-- asserts the sequence of native calls it produced.
--
-- ═══ WHY Citizen IS MODELLED RATHER THAN NOOPED ═══
--
-- Every other client suite here stubs Citizen.CreateThread to a no-op, because
-- the paths they drive are event handlers and loop callbacks. Neither half of
-- this feature is: the transition is a thread with six waits in it, and the
-- entrance is two threads walking a ped and flying a camera against each other.
-- A no-op would make every assertion below vacuously true.
--
-- So threads are COROUTINES, Citizen.Wait yields the delay, and pump() advances
-- a fake clock in 50ms steps -- resuming whatever is due, firing whatever
-- SetTimeout scheduled, and stepping the loop registry. It is the smallest
-- thing that can observe "this happened before that".
--
-- ═══ AND THE PED ACTUALLY MOVES ═══
--
-- TaskGoStraightToCoord sets a destination in the fixture and pump() walks the
-- ped toward it at the tasked speed. That is not scenery: the camera's last
-- move is scheduled off how far the ped still has to go, and a fixture whose
-- ped teleported on the first frame would agree happily with a camera that
-- never left the sky.
--
-- ═══ WHAT IS DELIBERATELY NOT COVERED ═══
--
-- Whether the engine really interpolates a camera, really streams a clipset, or
-- really walks a ped along the line rather than around a rock. None of that is
-- answerable in a Lua process. What is proved is which natives were called,
-- with what, and in what order.
--
-- Run standalone:  lua tools/test_lobbyseq.lua

-- ------------------------------------------------------------ native stubs ---

local realPrint = print
local logged = {}
function print(s) logged[#logged + 1] = tostring(s) end

local fakeTime = 1000
function GetGameTimer() return fakeTime end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerServerId() return 1 end
function PlayerId() return 0 end

-- THE PED HANDLE IS A VARIABLE, not a constant, because a model swap hands back
-- a new one and the walk has to survive being asked for it again.
local pedHandle = 1
function PlayerPedId() return pedHandle end

--- THE ORDERED LOG. Every native this suite cares about appends to it, so
--- "before" and "after" are readable rather than inferred.
local order = {}
local function note(kind, t)
    t = t or {}
    t.kind = kind
    t.at = fakeTime
    order[#order + 1] = t
    return t
end

--- The index of the first entry of a kind, or nil.
local function firstOf(kind, pred)
    for i, e in ipairs(order) do
        if e.kind == kind and (not pred or pred(e)) then return i, e end
    end
end

--- ═══ THE PED, AS A THING WITH A POSITION AND A SPEED ═══
local ped = {
    x = 0.0, y = 0.0, z = 0.0, heading = 0.0,
    frozen = false, model = 0, male = true,
    dest = nil, speed = 0.0, clipset = nil,
}

function GetEntityCoords() return { x = ped.x, y = ped.y, z = ped.z } end
function GetEntityHeading() return ped.heading end
function GetEntityModel() return ped.model end
function GetEntitySpeed() return ped.dest and ped.speed or 0.0 end
function IsPedMale() return ped.male and 1 or 0 end   -- a BOOL native answering NUMBERS, on purpose

--- HOW FAR THE WRITE MOVED THE PED, not just where it put them.
---
--- A coordinate write IS a teleport, and the only question that matters about
--- the one at the end of the walk is how long it was -- owner, 2026-08-29: "the
--- ped is getting close to the final coords, but then being teleported there."
--- The destination was always the lobby mark and always correct; the bug was
--- entirely in the metre before it. `jump` is that metre.
function SetEntityCoordsNoOffset(_p, x, y, z)
    local dx, dy = x - ped.x, y - ped.y
    local jump = math.sqrt(dx * dx + dy * dy)
    ped.x, ped.y, ped.z = x, y, z
    ped.dest = nil
    note('coords', { x = x, y = y, z = z, jump = jump })
end
function SetEntityHeading(_p, h) ped.heading = h end
function FreezeEntityPosition(_p, on)
    ped.frozen = on == true
    note('freeze', { on = ped.frozen })
end

function TaskGoStraightToCoord(_p, x, y, z, speed, _timeout, heading)
    ped.dest = { x = x, y = y, z = z, heading = heading }
    -- 1.0 is the walk blend ratio; ~1.4 m/s is what a walking ped covers.
    ped.speed = (speed or 1.0) * 1.4
    -- THE BLEND RATIO IS RECORDED, not just its effect on the fixture's metres
    -- per second. The owner tunes one speed per leg, so the assertion that
    -- matters is which NUMBER reached the native on which leg -- deriving it
    -- back out of ped.speed would be testing this mock's arithmetic.
    --
    -- AND SO ARE THE TARGET HEADING AND WHERE THE PED WAS STANDING WHEN THE
    -- TASK ARRIVED. Both are the corner bug (owner, 2026-08-29: "the ped walks
    -- to the point, stops, turns, then walks to the next point"): the heading
    -- is what the ped is told to face on arrival, and the position is how early
    -- the next leg took over -- a handover that only happens once the ped is
    -- on top of the corner is a handover after it has already stopped there.
    --
    -- AND WHETHER THE SCREEN WAS COVERED WHEN IT ARRIVED, which is the whole of
    -- "the ped doesn't do the full walk again": a leg tasked behind a fade or
    -- behind br_ui's opaque curtain is a leg nobody watches. Recorded at the
    -- moment of the call, because by the time an assertion runs the cover is
    -- long gone and the question is unanswerable.
    note('task', {
        x = x, y = y, z = z, speed = speed, heading = heading,
        fromX = ped.x, fromY = ped.y,
        covered = (BR.Spawn and BR.Spawn.curtainWanted == true)
            or IsScreenFadedIn() == 0,
    })
end
function ClearPedTasks() ped.dest = nil ped.anim = nil note('cleartasks') end
function ClearPedTasksImmediately() ped.dest = nil ped.anim = nil end

-- ═══ THE EMOTES, AS AN ANIMATION THAT IS EITHER ON THE PED OR NOT ═══
--
-- Five gestures on five clocks (client/lobbyped.lua's own note), and what this
-- suite can observe about them is exactly three things: WHICH clip was asked
-- for, WHEN relative to everything else, and with what FLAGS -- 0 for a full
-- body animation that stops the ped and 48 for the upper-body/secondary one
-- that plays over a walk. The flag is the only part of an emote that is a
-- claim about the engine rather than a name, so it is the part worth asserting.
-- ═══ AND A DICTIONARY TAKES TIME TO ARRIVE ═══
--
-- Modelled, because the whole point of streaming an emote's dictionary AHEAD of
-- the moment it is needed is that the request is not free. Answered instantly,
-- the fixture could not tell a gesture that was pre-streamed under the cover
-- from one that requests its dictionary at the instant of the press and spends
-- part of its own window waiting -- which is exactly what the owner reported
-- about the ready-up emote on 2026-08-29.
local animDicts = {}
local dictsStream = true
local dictDelayMs = 0
function RequestAnimDict(name)
    if animDicts[name] == nil then
        animDicts[name] = dictsStream and (fakeTime + dictDelayMs) or false
    end
end
function HasAnimDictLoaded(name)
    local at = animDicts[name]
    return (at and fakeTime >= at) and 1 or 0
end
function DoesAnimDictExist() return 1 end
function TaskPlayAnim(_p, dict, clip, _bi, _bo, dur, flags)
    ped.anim = { dict = dict, clip = clip, until_ = (dur and dur > 0)
        and (fakeTime + dur) or nil }
    note('anim', { dict = dict, clip = clip, ms = dur, flags = flags })
end
function StopAnimTask(_p, dict, clip)
    if ped.anim and ped.anim.dict == dict and ped.anim.clip == clip then ped.anim = nil end
end
--- A BOOL NATIVE ANSWERING NUMBERS, on purpose: the flip waits on this to know
--- the clip is over, and a bare read of it is a wait that never ends.
function IsEntityPlayingAnim(_p, dict, clip)
    if not ped.anim then return 0 end
    return (ped.anim.dict == dict and ped.anim.clip == clip) and 1 or 0
end
function TaskTurnPedToFaceCoord(_p, x, y, _z, ms)
    note('turn', { x = x, y = y, ms = ms })
end
function RemoveAllPedWeapons() end
function SetPedCanRagdoll() end
function SetPedDefaultComponentVariation() end
function NetworkResurrectLocalPlayer(x, y, z) note('resurrect', { x = x, y = y, z = z }) end

-- The walking style. `loaded` is a fixture knob: a clipset that never streams
-- must cost a plain walk rather than an entrance that never starts.
local animSets = {}
local clipsetStreams = true
function RequestAnimSet(name) animSets[name] = clipsetStreams end
function HasAnimSetLoaded(name) return animSets[name] and 1 or 0 end
function SetPedMovementClipset(_p, name)
    ped.clipset = name
    note('clipset', { name = name })
end
function ResetPedMovementClipset()
    ped.clipset = nil
    note('clipset', { name = nil })
end

-- Models. locker.lua streams one and swaps it; nothing here has to be slow.
local models = {}
function GetHashKey(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h
end
function RequestModel(h) models[h] = true end
function HasModelLoaded(h) return models[h] and 1 or 0 end
function SetModelAsNoLongerNeeded() end
function IsModelInCdimage() return 1 end
function IsModelValid() return 1 end
function IsModelAPed() return 1 end
function SetPlayerModel(_p, h)
    ped.model = h
    pedHandle = pedHandle + 1    -- a NEW handle, exactly as the real native gives
    note('setmodel', { model = h })
end

-- The world.
function RequestCollisionAtCoord() end
function HasCollisionLoadedAroundEntity() return 1 end
function GetGroundZFor_3dCoord(_x, _y, z) return 1, z - 50.0 end

-- ═══ THE SCREEN, AND A FADE THAT TAKES TIME ═══
--
-- THIS USED TO BE INSTANTANEOUS AND THAT IS WHY THE SUITE COULD NOT SEE THE
-- BUG THE OWNER REPORTED. DoScreenFadeIn(2000) set IsScreenFadedIn() true on
-- the same frame, so the walk and the camera flight were never observably
-- running behind a cover -- and "the ped doesn't do the full walk again" is
-- ENTIRELY a fact about how much of the walk happened while the screen was
-- still covered. A cover with no duration is a cover with no bug in it.
local fadedOut, fadedIn = false, true
local fadeInAt = nil            -- when a fade-in will have finished
function DoScreenFadeOut() fadedOut = true fadedIn = false fadeInAt = nil note('fadeout') end
-- NOTED, BECAUSE IT IS A DEADLINE. The entrance's first act is a teleport up
-- the path, and on the trip home the only cover it has is the black this call
-- ends -- so "the ped was placed before the fade" is an ORDERING, and orderings
-- are what this suite exists to assert.
function DoScreenFadeIn(ms)
    fadedOut = false
    fadeInAt = fakeTime + (tonumber(ms) or 0)
    note('fadein', { ms = ms })
end
function IsScreenFadedOut() return fadedOut and 1 or 0 end
function IsScreenFadedIn()
    if fadeInAt then
        if fakeTime < fadeInAt then return 0 end
        fadedIn = true
        fadeInAt = nil
    end
    return fadedIn and 1 or 0
end
function IsScreenFadingIn() return 0 end
function IsScreenFadingOut() return 0 end
function ShutdownLoadingScreen() end
function ShutdownLoadingScreenNui() end
function IsPlayerSwitchInProgress() return 0 end
function SwitchInPlayer() end
function SetPlayerControl() end
function GetIsLoadingScreenActive() return 0 end
function NetworkIsSessionStarted() return 1 end

-- The streaming focus. Both halves recorded: a focus moved and never given back
-- is the invisible failure this feature could leave behind.
function SetFocusPosAndVel(x, y, z) note('focus', { x = x, y = y, z = z }) end
function SetFocusEntity(p) note('focusback', { ped = p }) end
function ClearFocus() note('focusback', { ped = 'clear' }) end

-- ═══ THE CAMERAS, AS A LEDGER ═══
--
-- Counted rather than stubbed away, because "no orphaned camera" is one of the
-- two things the owner asked abandonment to guarantee and it is a COUNT.
local liveCams, nextCam = {}, 400
function CreateCamWithParams(_kind, x, y, z, pitch, _roll, yaw)
    nextCam = nextCam + 1
    liveCams[nextCam] = { x = x, y = y, z = z, pitch = pitch, yaw = yaw }
    note('cammade', { id = nextCam, x = x, y = y, z = z, pitch = pitch, yaw = yaw })
    return nextCam
end
function DoesCamExist(c) return (c and liveCams[c]) and 1 or 0 end
function DestroyCam(c) liveCams[c] = nil note('camgone', { id = c }) end
function SetCamActive() end
function PointCamAtCoord(c, x, y, z) note('campoint', { id = c, x = x, y = y, z = z }) end
--- Where the flight has actually got to. Read by the winner's flip, which turns
--- the ped to face the camera before it plays -- "please make sure the flip
--- happens facing the camera" (owner, 2026-08-29).
function GetCamCoord(c)
    local k = liveCams[c]
    if not k then return { x = 0.0, y = 0.0, z = 0.0 } end
    return { x = k.x, y = k.y, z = k.z }
end
function RenderScriptCams(on) note('render', { on = on == true }) end
function SetCamCoord() error('the lobby camera must not write coordinates on a rendering camera', 2) end

-- HOW LONG AN INTERPOLATION LASTS IS MODELLED, and it has to be: the sweep that
-- destroys the source camera is gated on IsCamInterpolating, so a stub that
-- always answered "no" would prove the sweep works by never letting it be wrong,
-- and one that always answered "yes" would hide every leak.
--
-- AND THE EASE FLAGS ARE RECORDED, because they are half of the stutter. The
-- last two arguments are easeLocation and easeRotation, and a 1 is an
-- ease-IN-AND-OUT: the camera arrives at rest and leaves from rest. One of
-- those is a nice single move; a CHAIN of them stops dead at every node, which
-- is what the owner saw on 2026-08-29. No duration in this fixture can observe
-- that -- the moves were always back to back -- so the flags themselves are the
-- only evidence there is.
local interpUntil = {}
function SetCamActiveWithInterp(dest, src, ms, easeLoc, easeRot)
    -- ONE FRAME LONGER THAN ASKED FOR, AND THAT IS THE HONEST MODEL. An engine
    -- interpolation does not finish on a sub-frame boundary: it runs to the end
    -- of the frame that carries its last millisecond. Modelled as exactly `ms`,
    -- the fixture's clock landed each move precisely on the previous one's
    -- expiry, so IsCamInterpolating was always false when the next move was
    -- issued -- which quietly made the whole retiring-camera path untestable.
    -- The leak it guards against is a REAL one that showed up in a live count
    -- last round; with this it is reproducible, and dropRetiring is exercised on
    -- every step of every flight rather than never.
    interpUntil[dest] = fakeTime + (ms or 0) + 16
    note('camglide', { from = src, to = dest, ms = ms,
                       easeLoc = easeLoc, easeRot = easeRot })
end
function IsCamInterpolating(c)
    return (c and interpUntil[c] and fakeTime < interpUntil[c]) and 1 or 0
end

local function liveCamCount()
    local n = 0
    for _ in pairs(liveCams) do n = n + 1 end
    return n
end

-- ═══ THE HIGH-WATER MARK, SAMPLED EVERY STEP OF THE CLOCK ═══
--
-- A count taken AFTER a flight cannot see a leak that the teardown then tidies
-- up, and "no camera survives" was the only thing asserted for a long time. The
-- number that matters while the flight is running is how many are alive AT ONCE:
-- the retiring camera is destroyed on every move rather than deferred, so it
-- should be two -- the one rendering and the one being blended away from -- no
-- matter how many steps the flight is cut into. Doubling camSteps doubles the
-- allocations and must not move this at all.
local peakCams = 0

-- Events and the rest of the runtime.
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
function TriggerServerEvent() end
local commands = {}
function RegisterCommand(n, fn) commands[n] = fn end
function RegisterKeyMapping() end
local kvp = {}
function SetResourceKvp(k, v) kvp[k] = v end
function GetResourceKvpString(k) return kvp[k] end
function DeleteResourceKvp(k) kvp[k] = nil end
function GetConvar(_n, d) return d end
function GetConvarInt(_n, d) return d end

-- Loaded with a no-op Citizen; the loop registry in client/main.lua parks a
-- `while true` in a thread and swapping the real one in first would hang.
Citizen = { CreateThread = function() end, Wait = function() end,
            SetTimeout = function() end }

-- ---------------------------------------------------------------- modules ---

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(list)
    for _, f in ipairs(list) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        local ok, e = pcall(chunk)
        if not ok then
            realPrint('\27[31mrun error\27[0m ' .. f .. ': ' .. tostring(e))
            os.exit(1)
        end
    end
end

loadAll({
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua', 'br_lib/shared/geo.lua',
    'br_lib/shared/polygon.lua', 'br_lib/shared/clock.lua',
    'br_lib/config/match.lua', 'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/peds.lua',
    'br_core/client/main.lua',      -- the loop registry; must be first
})

BR.State = BR.State or {}
BR.State.me = { src = 1, state = BR.PlayerState.LOBBY }
BR.State.match = { state = BR.MatchState.WAITING }
BR.State.worldReady = true

-- The collaborators, at the surface they are actually used through.
BR.Native = { initHealthModel = function() end }
BR.Notify = function() end
BR.Spectate = { active = function() return false end }

loadAll({
    'br_core/client/spawn.lua',
    'br_core/client/lobbycam.lua',
    'br_core/client/locker.lua',
    'br_core/client/lobbyped.lua',
})

-- ═══ THE ASSIGNED CHARACTER IS PINNED, ONCE, AND ONLY IT ═══
--
-- client/locker.lua hands a player who has never picked one a RANDOM character
-- and remembers it for as long as the client runs. reset() clears the kvp
-- between blocks, so every block below that wears "the chosen character" wears
-- that roll -- and block 12 picks `clown` and asserts the model CHANGED, which
-- a roll that happened to land on clown would fail one run in seventy-nine.
-- Verified by pinning it there: 288 passed, 1 failed.
--
-- So the roll is forced here, by asking for it with math.random pinned for
-- exactly that one call. The real one goes straight back, because lobbyped.lua
-- picks its idle emote the same way and a suite that pinned the generator for
-- its whole run would be choosing that too.
do
    local realRandom = math.random
    math.random = function() return 1 end
    BR.Locker.chosen()
    math.random = realRandom
end

-- ═══ THE CLOCK, AND THREADS THAT ACTUALLY RUN ═══

local threads, timers = {}, {}
Citizen.CreateThread = function(fn)
    threads[#threads + 1] = { co = coroutine.create(fn), wake = fakeTime }
end
Citizen.Wait = function(ms) coroutine.yield(tonumber(ms) or 0) end
Citizen.SetTimeout = function(ms, fn)
    timers[#timers + 1] = { at = fakeTime + (tonumber(ms) or 0), fn = fn }
end

--- Advance the world by `total` ms, 50 at a time.
local function pump(total)
    local target = fakeTime + total
    while fakeTime < target do
        fakeTime = fakeTime + 50

        -- An emote with a duration comes off the ped when it runs out. The
        -- looping ones (duration -1) stay until something clears them, which
        -- is exactly what the game does with them.
        do
            local n = 0
            for _ in pairs(liveCams) do n = n + 1 end
            if n > peakCams then peakCams = n end
        end

        if ped.anim and ped.anim.until_ and fakeTime >= ped.anim.until_ then
            ped.anim = nil
        end

        -- The ped walks toward whatever it was tasked with.
        if ped.dest then
            local dx, dy = ped.dest.x - ped.x, ped.dest.y - ped.y
            local d = math.sqrt(dx * dx + dy * dy)
            local step = ped.speed * 0.05
            if d <= step or d < 0.01 then
                ped.x, ped.y, ped.z = ped.dest.x, ped.dest.y, ped.dest.z
                ped.heading = ped.dest.heading or ped.heading
                ped.dest = nil
            else
                ped.x = ped.x + dx / d * step
                ped.y = ped.y + dy / d * step
            end
        end

        for i = #timers, 1, -1 do
            if timers[i].at <= fakeTime then
                local t = table.remove(timers, i)
                t.fn()
            end
        end

        for i = #threads, 1, -1 do
            local th = threads[i]
            if coroutine.status(th.co) == 'dead' then
                table.remove(threads, i)
            elseif th.wake <= fakeTime then
                local ok, wait = coroutine.resume(th.co)
                if not ok then
                    realPrint('\27[31mthread error\27[0m ' .. tostring(wait))
                    os.exit(1)
                end
                th.wake = fakeTime + (tonumber(wait) or 0)
            end
        end

        BR.Loop.step(BR.Loop.TICK)
    end
end

-- Reading the latch as an EVENT rather than as a value, so its position in the
-- sequence can be asserted against the teleport's.
do
    local real = BR.LobbyPed.setNetworked
    BR.LobbyPed.setNetworked = function(on, why)
        local before = BR.LobbyPed.isNetworked()
        real(on, why)
        if BR.LobbyPed.isNetworked() ~= before then
            note('networked', { on = BR.LobbyPed.isNetworked() })
        end
    end
end

-- ═══ THE CURTAIN TAKES ITS OWN 600ms TO REACH OPAQUE ═══
--
-- IT USED TO BE ACKNOWLEDGED IN THE FRAME IT WAS RAISED, which made the whole
-- of the ready-up ordering unobservable: the screen was "already black" before
-- any gesture could play, so a build that cut the emote at the state edge and
-- one that let it run until the cover looked identical from here.
--
-- It is a CSS opacity transition inside CEF (br_ui), and br_core learns it has
-- landed from the page saying so -- `br:ui:covered`, which is what
-- BR.Spawn.awaitCover blocks on and what client/lobbyped.lua now reads to know
-- when a gesture has to stop. 600ms is the figure client/spawn.lua's own note
-- carries for it.
--
-- STILL FAR INSIDE awaitCover's 2500ms ceiling, so nothing waits out a timeout.
local curtainMs = 600
AddEventHandler('br:ui:sendLocal', function(kind, d)
    if kind ~= BR.Nui.LEAVING or not d then return end
    if d.show then
        Citizen.SetTimeout(curtainMs, function()
            note('covered')
            TriggerEvent('br:ui:covered', 'curtain', true)
        end)
    else
        TriggerEvent('br:ui:covered', 'curtain', false)
    end
end)

-- ------------------------------------------------------------------ harness ---

local pass, fail = 0, 0
local function ok(cond, what)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. what)
    end
end

local function reset()
    order = {}
    logged = {}
    fadedOut, fadedIn = false, true
    fadeInAt = nil
    ped.x, ped.y, ped.z = BR.Config.Match.lobbyPos.x, BR.Config.Match.lobbyPos.y,
                          BR.Config.Match.lobbyPos.z
    ped.dest, ped.clipset, ped.frozen = nil, nil, true
    ped.anim = nil
    ped.male = true
    clipsetStreams = true
    dictsStream = true
    dictDelayMs = 0
    for k in pairs(animDicts) do animDicts[k] = nil end
    BR.Spawn.curtainWanted = false
    BR.State.party = nil
    for c in pairs(liveCams) do liveCams[c] = nil end
    -- The stored character too: a block that swaps one leaves it in kvp, and
    -- the next block's "picking a character changes it" would then be picking
    -- the one already on.
    for k in pairs(kvp) do kvp[k] = nil end
    threads, timers = {}, {}
    BR.State.me.state = BR.PlayerState.LOBBY
    BR.Spawn.traveling = false
    BR.Spawn.holdBlack = false
    BR.LobbyPed.setNetworked(false, 'test reset')
    BR.LobbyPed.rearm()
    -- rearm() bumps the token and lands the camera; sweep the ledger again so a
    -- test starts from nothing.
    for c in pairs(liveCams) do liveCams[c] = nil end
    peakCams = 0
    order = {}
end

--- The model locker.lua would apply, put on the ped so the entrance's model
--- wait is satisfied.
local function wearChosenModel()
    ped.model = GetHashKey(BR.PedById(BR.Locker.chosen()).model)
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. THE CONFIG THE OWNER AUTHORED
-- ═══════════════════════════════════════════════════════════════════════════

do
    local C = BR.Config.Match.lobbyEntrance
    ok(#BR.Config.Match.warmupSpawns == 3, 'three warmup spawns are authored')
    ok(BR.Config.Match.warmupSpawns[1].x == 4467.42
       and BR.Config.Match.warmupSpawns[1].heading == 322.8
       and BR.Config.Match.warmupSpawns[2].x == 4516.24
       and BR.Config.Match.warmupSpawns[2].heading == 84.1
       and BR.Config.Match.warmupSpawns[3].x == 4488.25
       and BR.Config.Match.warmupSpawns[3].heading == 198.3,
       'the warmup spawns are the surveyed numbers, every one of them')

    -- THE CLIPSETS, AND THE TRAILING @. `anim@move_m@grooving` without it is a
    -- different string that RequestAnimSet answers nothing for -- which presents
    -- as a ped that walks normally, not as an error, so nothing else would ever
    -- catch it.
    ok(C.walkClipsetMale == 'anim@move_m@grooving@',
       'the male walk is the stock grooving clipset')
    ok(C.walkClipsetFemale == 'anim@move_f@grooving@',
       'the female walk is the stock grooving clipset')
    -- ═══ THE SURVEY, RETYPED ═══
    --
    -- Re-surveyed by the owner on 2026-08-30; these numbers ARE the feature and
    -- a transcription slip in any of them is a ped walking through a rock or a
    -- camera pointed at the sea.
    --
    -- TYPED OUT AGAIN HERE FROM HIS MESSAGE rather than read back out of the
    -- config, which is the whole point: a test that asks the config what the
    -- config says agrees with itself no matter what was typed. This is the
    -- double-entry check that caught a real error in the shop catalogue.
    ok(C.pedCases == nil,
        'the four-case draw is gone, not left as a table of one')

    local s = C.pedStart
    ok(s and s.x == 5040.08 and s.y == -5699.77 and s.z == 19.88
         and s.heading == 118.5,
        'the ped starts on its surveyed mark')

    -- THREE CORNERS, AND THE FOURTH LEG IS THE LOBBY MARK, which the client
    -- appends. Miscount them and the derived speeds are solved for a walk that
    -- is not the one being taken.
    ok(type(C.pedPath) == 'table' and #C.pedPath == 3,
        ('three surveyed corners; the fourth leg is the lobby mark (%d)')
            :format(type(C.pedPath) == 'table' and #C.pedPath or -1))

    local corners = {
        { 5034.35, -5703.75, 19.88, 139.2 },
        { 5041.32, -5714.51, 17.68, 212.0 },
        { 5036.56, -5717.71, 17.08, 120.4 },
    }
    for i, w in ipairs(corners) do
        local n = C.pedPath and C.pedPath[i]
        ok(n and n.x == w[1] and n.y == w[2] and n.z == w[3],
            ('corner %d is where he stood'):format(i))
        -- THE HEADING IS KEPT AS THE SURVEY AND IS NOT USED TO TURN THE PED.
        -- Asserted so it stays the number he recorded rather than drifting into
        -- something someone computed; what stops it steering the walk is the
        -- behavioural assertion further down, which checks each corner is faced
        -- toward the NEXT one.
        ok(n and n.heading == w[4],
            ('and corner %d keeps the heading he recorded there'):format(i))
    end

    -- AND THE PATH DOES NOT REPEAT THE LOBBY MARK. The client appends it; a
    -- copy here is the drift this project is most scarred by, and it would
    -- present as the ped walking the last five metres twice.
    local dupes = 0
    local L = BR.Config.Match.lobbyPos
    for _, n in ipairs(C.pedPath or {}) do
        if math.abs(n.x - L.x) < 0.01 and math.abs(n.y - L.y) < 0.01 then
            dupes = dupes + 1
        end
    end
    ok(dupes == 0, 'and it does not repeat the lobby mark as a corner')

    -- ═══ AND THE STEP COUNT IS PINNED AS HIS CHOICE ═══
    --
    -- "The same number of steps is necessary for the camera movement, I just
    -- need you to create them" -- the owner, 2026-08-30, answering whether the
    -- new path wanted more.
    --
    -- ASSERTED HERE RATHER THAN DERIVED, and that is a change. On the old path
    -- the per-step turn separated 48 from 96 on its own -- 6.5 degrees against
    -- 3.3 -- so the behavioural threshold did the pinning. This path's corners
    -- are gentler and 48 measures 4.67 degrees, comfortably inside the same
    -- threshold, so nothing behavioural distinguishes them any more. The count
    -- is a number he chose and would notice changing, so it is checked the same
    -- way the coordinates are.
    ok(C.camSteps == 96,
        ('the flight is cut into the 96 steps he asked to keep (%s)')
            :format(tostring(C.camSteps)))

    -- THE CAMERA'S THREE NODES, likewise retyped.
    ok(#C.camPath == 3, 'three authored camera nodes; the fourth is the lobby frame')
    local nodes = {
        { 5550.24, -5555.91, 175.34, 132.4 },
        { 5189.63, -5747.61,  66.61,  99.5 },
        { 5072.10, -5738.05,  31.77,  64.8 },
    }
    for i, w in ipairs(nodes) do
        local n = C.camPath and C.camPath[i]
        ok(n and n.x == w[1] and n.y == w[2] and n.z == w[3] and n.heading == w[4],
            ('camera node %d is the surveyed one'):format(i))
    end

    -- EVERY DURATION IS A NUMBER IN CONFIG. The owner offered to tune these, so
    -- a value that migrated into the client is a value he cannot reach.
    for _, k in ipairs({ 'camFlightMs', 'focusLeadMs', 'modelWaitMs',
                         'clipsetWaitMs', 'legTimeoutMs', 'armWaitMs',
                         'arriveRadius', 'cornerRadius', 'markRadius',
                         'walkTargetMs', 'walkMps', 'walkBlendMin',
                         'walkBlendMax', 'camSteps', 'camDecay',
                         'camStartTrim', 'revealWaitMs' }) do
        ok(type(C[k]) == 'number', ('lobbyEntrance.%s is tunable'):format(k))
    end

    -- ═══ AND THE START TRIM IS DELIBERATELY NOT PINNED TO A VALUE ═══
    --
    -- "Can we make it start closer to the destination by like 30%" -- the owner,
    -- 2026-08-31, and "like 30%" is a man saying he will try 0.35 next. It is
    -- checked for being a FRACTION rather than for being 0.30, so nudging it is
    -- a config edit and not a config edit plus a test edit. What section 14b
    -- asserts is the behaviour it produces, whatever it is set to.
    --
    -- THE CEILING IS THE ONE THING WORTH GUARDING. Past about half the path
    -- the flight stops being a descent and becomes a short hop onto the mark,
    -- and at 1.0 there would be no flight at all to share camFlightMs out over.
    -- flightPlan clamps at 0.9 rather than trusting this; this is where the
    -- number gets read by somebody.
    ok(type(C.camStartTrim) == 'number'
        and C.camStartTrim >= 0.0 and C.camStartTrim <= 0.5,
        ('camStartTrim is a fraction of the path and leaves a flight behind '
            .. '(%.2f)'):format(C.camStartTrim or -1))

    -- ═══ AND THE THREE RADII HAVE TO STAND IN THE RIGHT ORDER ═══
    --
    -- They are not three spellings of "close enough", they are three different
    -- questions, and a config that put them in any other order would silently
    -- undo one of the two arrival bugs the owner reported on 2026-08-29.
    --
    -- markRadius is what is LEFT for standOnMark to teleport, so it has to be
    -- far smaller than the ordinary radius -- at 0.9m the entrance ended by
    -- snapping the ped almost a metre, face-on to a landed camera.
    ok(C.markRadius < C.arriveRadius * 0.5,
        ('the mark is walked onto rather than teleported onto '
            .. '(markRadius %.2f vs arriveRadius %.2f)')
            :format(C.markRadius, C.arriveRadius))

    -- cornerRadius is how early the NEXT leg takes over, and the whole point is
    -- that it happens before the ped has finished slowing down for the corner.
    -- Anything at or under arriveRadius is the old late handover.
    ok(C.cornerRadius > C.arriveRadius,
        ('a corner is handed over early rather than on arrival '
            .. '(cornerRadius %.2f vs arriveRadius %.2f)')
            :format(C.cornerRadius, C.arriveRadius))

    -- ═══ AND THERE IS NO AUTHORED SPEED LIST ANY MORE ═══
    --
    -- `walkSpeeds = { 2.0, 1.5, 1.0 }` was solved for ONE path. Four paths of
    -- 41m, 59m, 29m and 34m cannot share it and land on the same clock, which
    -- is what the owner asked for -- so a config that still carries it is a
    -- config somebody restored by hand, and lobbyped.lua would ignore it
    -- silently.
    ok(C.walkSpeeds == nil,
        'the flat walkSpeeds list is gone -- the speeds are derived per case')

    -- THE BLEND CEILING IS A SPRINT AND NOT MORE. The whole point of clamping
    -- is that a case which cannot make the target inside a human pace runs long
    -- instead of running at a ratio nobody would call a walk.
    ok(C.walkBlendMin == 1.0,
        ('the floor is a walk (%.2f)'):format(C.walkBlendMin or -1))
    ok(C.walkBlendMax > 1.0 and C.walkBlendMax <= 3.0,
        ('and the ceiling is a sprint at most, never a number like 12 (%.2f)')
            :format(C.walkBlendMax or -1))

    -- ═══ THE CAMERA LANDS FIRST, AND THE FAILSAFE HAS TO SURVIVE THAT ═══
    --
    -- They were equal, off "The camera flight and the walk should finish
    -- together", until "Also the lobby camera moves too slow. Let's do 30%
    -- faster" (owner, 2026-08-29). So the flight is now the shorter of the two
    -- ON PURPOSE and the camera parks with the ped still walking.
    --
    -- WHAT MUST NOT HAPPEN IS THE FLIGHT BEING LONGER, which would leave the
    -- ped standing on the mark waiting for its own shot to arrive.
    ok(C.camFlightMs <= C.walkTargetMs,
        ('the flight is no longer than the walk (%d vs %d)')
            :format(C.camFlightMs or -1, C.walkTargetMs or -1))

    -- ═══ AND EVERY EMOTE NAMES A REAL DICTIONARY AND CLIP ═══
    --
    -- Both halves, for every one of them: a dictionary with no clip is an
    -- emote that silently does nothing, which is exactly how a copy-paste in
    -- the source list would arrive here.
    local E = C.emotes or {}
    for _, k in ipairs({ 'win', 'idle', 'ready', 'wave' }) do
        local e = E[k]
        ok(type(e) == 'table' and type(e.dict) == 'string' and #e.dict > 0
             and type(e.clip) == 'string' and #e.clip > 0,
            ('the %s emote names a dictionary and a clip'):format(k))
    end

    -- THE WAVE IS THE ONE THAT PLAYS OVER A WALK, and 48 is what says so: 16
    -- (upper body only) + 32 (secondary / allow movement). Anything else here
    -- is a ped that stops walking to wave, which is not what was asked for.
    ok(E.wave and E.wave.flags == 48,
        ('the wave is an upper-body secondary animation (flags %s)')
            :format(E.wave and tostring(E.wave.flags) or 'nil'))

    -- AND THE FLIP IS NOT. It is a backflip; there is no upper-body version of
    -- one, and the walk pauses for it rather than carrying it.
    ok(E.win and E.win.flags == 0,
        'the flip is a full-body animation -- the walk stops for it')

    -- THE STRETCH IS THIRTY SECONDS AFTER PARKING, which is the owner's number
    -- and the only part of (b) that is not a name.
    ok(E.idle and E.idle.afterMs == 30000,
        ('the parked stretch waits thirty seconds (%s)')
            :format(E.idle and tostring(E.idle.afterMs) or 'nil'))

    -- SIX HUNDRED MILLISECONDS, likewise: "play 'thumbs up 3' for 600ms then
    -- clearpedtasks".
    ok(E.ready and E.ready.ms == 600,
        ('the ready-up thumbs up lasts 600ms (%s)')
            :format(E.ready and tostring(E.ready.ms) or 'nil'))

    -- AND FIVE HUNDRED MORE FOR THE DEPARTURE TO WAIT: "the thumbs up emote
    -- doesn't have enough time to complete before we fade to black. Add 500ms
    -- there please." The number lives here; the line that reads it is in
    -- spawn.lua's toWarmupPad, which this round does not own.
    ok(E.ready and E.ready.holdMs == 500,
        ('and the departure is asked to wait 500ms for it (%s)')
            :format(E.ready and tostring(E.ready.holdMs) or 'nil'))

    -- ═══ THE WAIT FAMILY, MINUS THE ONE HE EXCLUDED ═══
    --
    -- "play any variation of 'wait*' emotes except 'wait 9'". wait9 is
    -- `rcmjosh2` / `josh_2_intp1_base`, and the way that exclusion goes wrong
    -- is somebody pasting the whole family back in.
    local waits = E.waiting
    ok(type(waits) == 'table' and type(waits.clips) == 'table'
        and #waits.clips > 1,
        'the squad-waiting emote is a list to vary between')

    local hasWait9 = false
    for _, w in ipairs((waits and waits.clips) or {}) do
        if w.dict == 'rcmjosh2' and w.clip == 'josh_2_intp1_base' then
            hasWait9 = true
        end
    end
    ok(not hasWait9, 'and "wait 9" is not one of them')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. NOTHING DEPENDS ON rpemotes
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The owner installed it to read the walking-style names out of its menu and
-- intends to remove it. The names are stock GTA clipsets and this project must
-- not have picked up a dependency on the resource that named them -- so: no
-- CODE line under resources/ may mention it. Prose may (this file's own config
-- comment explains where the names came from), which is why the check cuts each
-- line at its comment marker rather than grepping the file.

do
    local hits = {}
    local pipe = io.popen('find resources -name "*.lua"')
    if pipe then
        for file in pipe:lines() do
            local fh = io.open(file, 'r')
            if fh then
                local n = 0
                for line in fh:lines() do
                    n = n + 1
                    local code = line:gsub('%-%-.*$', '')
                    if code:lower():find('rpemotes', 1, true) then
                        hits[#hits + 1] = ('%s:%d'):format(file, n)
                    end
                end
                fh:close()
            end
        end
        pipe:close()
    end
    ok(#hits == 0, 'no code under resources/ references rpemotes: '
        .. table.concat(hits, ', '))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. THE ENTRANCE RUNS
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    wearChosenModel()


    ok(BR.LobbyPed.revealBlock() ~= nil,
       'the loading screen is held while the entrance is arming')
    ok(BR.LobbyPed.revealMark() == nil,
       'and it has no mark to name yet -- the case has not been drawn')

    pump(300)
    ok(BR.LobbyPed.entering(), 'the entrance starts on the lobby tick')

    local C = BR.Config.Match.lobbyEntrance
    ok(BR.LobbyPed.revealMark() == C.pedStart,
       'once it is running it names the DRAWN case\'s spawn, not the lobby mark')

    pump(500)
    ok(math.abs(ped.x - C.pedStart.x) < 2.0,
       'the ped is placed on the start mark before anything else')
    ok(ped.clipset == 'anim@move_m@grooving@',
       'a male ped is given the male grooving clipset')
    ok(BR.LobbyPed.walking(), 'and then it walks')
    ok(BR.LobbyPed.revealBlock() == nil,
       'once the ped is on its mark the loading screen may come down')

    -- The entrance's first shot went up where the flight starts, with no
    -- interpolation INTO it -- it is raised under a black screen and there is
    -- nothing to blend from. (The fixed lobby shot the follow tick had already
    -- raised is the camera it replaces.)
    --
    -- ═══ AND THAT IS NO LONGER camPath[1] ═══
    --
    -- camStartTrim moves where the camera JOINS the curve, so the raised shot
    -- and the flown shot are only the same shot while placeOnStart builds its
    -- plan from the same six settings flyCamera does. Built without the trim it
    -- would raise the camera on the hilltop and then cut, on the first frame of
    -- the flight, to a point 180m along the path -- which is the exact failure
    -- the ONE CALL SITE note on camPlan exists to prevent, and it is invisible
    -- in every other assertion in this file.
    local wantStart = BR.LobbyCam.flightPlan(C.camPath, C.camSteps, C.camDecay,
        C.camRounding, (C.camStepMinMs or 0) / math.max(1, C.camFlightMs or 1),
        C.camStartTrim)[1]
    local _, made = firstOf('cammade',
        function(e) return math.abs(e.x - wantStart.x) < 0.01
                     and math.abs(e.y - wantStart.y) < 0.01 end)
    ok(made ~= nil, 'a camera is raised where the flight actually starts')
    ok(made and made.pitch < 0.0,
       'and it is tilted DOWN toward the lobby rather than at the horizon')
    ok(made and firstOf('camglide', function(e) return e.to == made.id end) == nil,
       'the first shot is a cut, not a blend -- there is nothing to blend from')

    -- The streaming focus is pointed ahead, as loading.lua would do it.
    BR.LobbyPed.focusAhead()

    -- The locker is unavailable for the whole walk.
    ok(BR.LobbyPed.lockerLocked(), 'the locker is locked while the ped walks')
    local before = ped.model
    TriggerEvent('br:ui:action', BR.NuiCb.LOCKER_PICK, { id = 'clown' })
    pump(200)
    ok(ped.model == before, 'a pick during the walk changes nothing')

    -- ...and the walk finishes.
    pump(60000)
    ok(not BR.LobbyPed.entering(), 'the entrance ends')
    ok(not BR.LobbyPed.walking(), 'the ped stops walking')
    ok(math.abs(ped.x - BR.Config.Match.lobbyPos.x) < 0.01
       and math.abs(ped.y - BR.Config.Match.lobbyPos.y) < 0.01,
       'the ped ends standing exactly on the lobby mark')
    ok(ped.frozen, 'frozen there, like every other lobby ped')
    ok(ped.clipset == nil, 'and the walking style is cleared on arrival')
    ok(not BR.LobbyPed.lockerLocked(), 'the locker unlocks when the ped arrives')

    local _, arrival = firstOf('freeze', function(e) return e.on and e.at > 2000 end)

    -- THE FLIGHT LANDS ON THE LOBBY FRAME EXACTLY. Not near it: the shot the
    -- entrance ends on is the shot the locker and the ped picker were composed
    -- against, and a camera half a metre off it is a differently framed
    -- character every time somebody comes home.
    local hx, hy, hz = BR.LobbyCam.lobbyFrame()
    local landed = nil
    for i = #order, 1, -1 do
        local e = order[i]
        if e.kind == 'cammade' and e.at > 2000 then landed = e break end
    end
    ok(landed ~= nil and math.abs(landed.x - hx) < 0.01
        and math.abs(landed.y - hy) < 0.01 and math.abs(landed.z - hz) < 0.01,
       'the flight lands on the lobby frame exactly, not near it')

    local pedAt
    for i = #order, 1, -1 do
        if order[i].kind == 'coords' then pedAt = order[i].at break end
    end
    ok(landed ~= nil and pedAt ~= nil and landed.at <= pedAt,
       'and it gets there no later than the ped does')
    ok(arrival ~= nil, 'the arrival re-freezes the ped')

    -- NO CAMERA IS LEFT BEHIND by a flight that ran to completion -- and after
    -- the resampling that is four dozen moves rather than three, so a sweep
    -- that only ran on the happy path would leak four dozen cameras.
    pump(2000)
    ok(liveCamCount() <= 1,
       ('a completed flight leaves one camera, not %d'):format(liveCamCount()))

    -- ═══ AND IT NEVER HELD MORE THAN TWO AT ONCE ═══
    --
    -- THE ASSERTION THAT SCALES WITH camSteps, which the one above does not: a
    -- count taken after the flight cannot tell a build that leaked nothing from
    -- one that leaked forty-seven cameras and then tidied up. Two is the whole
    -- budget -- the camera rendering and the one being blended away from -- and
    -- it is two whether the flight is cut into three moves or fifty, because
    -- dropRetiring destroys the retiring camera on every move instead of
    -- deferring while the current one interpolates.
    --
    -- THIS IS THE COST CHECK FOR DOUBLING THE STEP COUNT. Twice the steps is
    -- twice the allocations and the same two live cameras; if that stopped
    -- being true, raising camSteps would be buying smoothness with a leak.
    ok(peakCams <= 2,
        ('and never held more than two at once across %d steps (peak %d)')
            :format(BR.Config.Match.lobbyEntrance.camSteps, peakCams))

    -- The focus was given back.
    ok(firstOf('focusback') ~= nil, 'the streaming focus is handed back at the end')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 4. A FEMALE PED GETS THE FEMALE CLIPSET
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    wearChosenModel()
    ped.male = false
    pump(800)
    ok(ped.clipset == 'anim@move_f@grooving@',
       'a female ped is given the female grooving clipset')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 5. A CLIPSET THAT NEVER STREAMS COSTS A PLAIN WALK, NOT THE ENTRANCE
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    wearChosenModel()
    clipsetStreams = false
    pump(5000)
    ok(ped.clipset == nil, 'no style is applied when the clipset never arrives')
    ok(BR.LobbyPed.walking(), 'but the ped still walks')
    pump(60000)
    ok(math.abs(ped.x - BR.Config.Match.lobbyPos.x) < 0.01,
       'and still reaches the mark')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 6. THE FOCUS LEADS THE REVEAL, AND COMES BACK
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    wearChosenModel()
    pump(800)

    local lead = BR.LobbyPed.focusAhead()
    ok(lead == BR.Config.Match.lobbyEntrance.focusLeadMs,
       'focusAhead reports the configured lead so loading.lua can hold the reveal')

    -- ═══ AND IT POINTS AT THE DESTINATION, NOT AT THE FIRST NODE ═══
    --
    -- Owner, 2026-08-31, having reported it three times: "The textures are
    -- consistently not loading fully when the lobby cam arrives at the
    -- destination." Until then this pointed at camPath[1] -- his own instruction
    -- of 2026-08-29 -- and nothing moved it across the 13.8-second flight, so
    -- the shot the entrance LANDS on was the one place in the sequence the
    -- engine was never told to stream.
    --
    -- MEASURED AGAINST BR.LobbyCam.lobbyFrame, which is what flightPlan actually
    -- lands on -- not against camPath's last entry, which is a control point the
    -- curve passes through 37.8m short of home. The two candidate targets are
    -- some 560m apart, so a metre of tolerance tells them apart with room to
    -- spare and the second assertion says so out loud.
    local _, f = firstOf('focus')
    local dstX, dstY, dstZ = BR.LobbyCam.lobbyFrame()
    ok(f ~= nil and math.abs(f.x - dstX) < 1.0
         and math.abs(f.y - dstY) < 1.0
         and math.abs(f.z - dstZ) < 1.0,
       'and it points the streaming focus at the shot the flight LANDS on')
    local first = BR.Config.Match.lobbyEntrance.camPath[1]
    ok(f ~= nil and BR.Dist3(f.x, f.y, f.z, first.x, first.y, first.z) > 100.0,
       'nowhere near the first camera node it used to be nailed to')

    -- AND IT IS GIVEN BACK ON AN ABANDONMENT, not only on the happy path. A
    -- client left holding a fixed streaming focus presents, much later and
    -- somewhere else, as world geometry that will not load -- with nothing
    -- pointing back here. The lobby frame is a SNEAKIER address for that than
    -- the old node over the ocean, not a safer one: it looks perfectly healthy
    -- until the player readies up and leaves it forty kilometres behind.
    order = {}
    BR.LobbyPed.stop('test')
    local _, back = firstOf('focusback')
    ok(back ~= nil, 'an abandoned entrance hands the streaming focus back')
    ok(back and back.ped == pedHandle,
       'to the player ped, by SetFocusEntity')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 7. ABANDONMENT: DROP EVERYTHING, LEAVE NOTHING BEHIND
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    wearChosenModel()
    pump(3000)      -- mid-walk, mid-flight

    ok(BR.LobbyPed.walking(), 'precondition: the ped is walking')
    ok(ped.dest ~= nil, 'precondition: it has a live task')
    ok(BR.LobbyPed.lockerLocked(), 'precondition: the locker is locked')
    ok(liveCamCount() > 0, 'precondition: a camera is up')

    order = {}
    BR.LobbyPed.stop('test abandonment')

    ok(not BR.LobbyPed.entering(), 'the sequence is over immediately')
    ok(not BR.LobbyPed.walking(), 'nothing is walking')
    ok(ped.dest == nil, 'the ped task is cleared -- no half-finished walk')
    ok(ped.clipset == nil, 'the walking style is cleared')
    ok(not BR.LobbyPed.lockerLocked(), 'and the locker is unlocked')
    ok(math.abs(ped.x - BR.Config.Match.lobbyPos.x) < 0.01,
       'a lobby player who abandons is left standing on the lobby mark')

    -- ═══ AND NOTHING CARRIES ON AFTERWARDS ═══
    --
    -- The point of the token: two threads were parked in Citizen.Wait when
    -- stop() ran, and neither of them knows it. If either resumes and touches
    -- the ped or the camera, this catches it -- which no "the flag is false"
    -- assertion could, because the flag being false is exactly what they are
    -- supposed to notice.
    order = {}
    local camsAfter = liveCamCount()
    pump(40000)
    ok(firstOf('task') == nil, 'no leg is walked after the sequence was dropped')
    ok(firstOf('clipset') == nil, 'no walking style is applied afterwards')
    ok(firstOf('camglide') == nil, 'no camera move happens afterwards')
    ok(liveCamCount() <= camsAfter,
       ('no camera is created afterwards (%d then, %d now)')
           :format(camsAfter, liveCamCount()))

    -- ═══ AND THE SETTLE OUT OF AN ABANDONED FLIGHT LEAVES NOTHING EITHER ═══
    --
    -- THE ONE PATH WHERE A DEFERRED SWEEP REALLY DOES LEAK. Abandoning
    -- mid-flight means the current move IS still interpolating, so sweepRetired
    -- declines to tidy -- and glideHome then overwrites the only reference to
    -- that camera on its way to landing the shot. "No camera was CREATED
    -- afterwards" above cannot see it: the leak happened during the stop, not
    -- after it. The count once the settle has run is what can.
    ok(liveCamCount() <= 1,
       ('and the settle out of an abandoned flight leaves one camera, not %d')
           :format(liveCamCount()))
    ok(peakCams <= 2,
       ('with never more than two alive at once through the whole abandonment '
            .. '(peak %d)'):format(peakCams))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 8. ...AND ABANDONING TWICE, AND ABANDONING NOTHING, ARE BOTH FINE
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    wearChosenModel()
    pump(2000)
    BR.LobbyPed.stop('once')
    BR.LobbyPed.stop('twice')
    ok(not BR.LobbyPed.lockerLocked(), 'a second stop is harmless')

    reset()
    BR.LobbyPed.stop('nothing running')
    ok(not BR.LobbyPed.lockerLocked(), 'stopping an idle sequence is harmless')

    -- The resource stopping is an ending too, and it is the one nobody
    -- remembers: the locker lock and the streaming focus both live outside our
    -- Lua state and would survive br_core restarting without this.
    reset()
    wearChosenModel()
    pump(2000)
    ok(BR.LobbyPed.lockerLocked(), 'precondition: locked')
    TriggerEvent('onResourceStop', 'br_core')
    ok(not BR.LobbyPed.lockerLocked(), 'the resource stopping unlocks the locker')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 9. THE ORDERING: TELEPORTED FIRST, NETWORKED SECOND
-- ═══════════════════════════════════════════════════════════════════════════
--
-- This is the whole point of the change. The claim is not "the ped ends up at
-- the warmup spawn" and not "the latch ends up true" -- both are true of the
-- broken version. It is that the coordinate write happens BEFORE the flip, with
-- no frame in between where a ped standing on the lobby mark is one other lobby
-- clients have stopped hiding.

local function isWarmupSpawn(x, y)
    for _, s in ipairs(BR.Config.Match.warmupSpawns) do
        if math.abs(s.x - x) < 0.01 and math.abs(s.y - y) < 0.01 then return true end
    end
    return false
end

do
    reset()
    wearChosenModel()
    pump(3000)      -- entrance running: the readying player is mid-walk

    ok(BR.LobbyPed.isLobbyPed(), 'precondition: my ped is a LOBBY ped')

    order = {}
    -- The server names us a participant. The state flips FIRST -- it always
    -- does, and that is what the old visibility rule was keyed on.
    BR.State.me.state = BR.PlayerState.WARMUP
    ok(BR.LobbyPed.isLobbyPed(),
       'the state changing does NOT make the ped networked -- it has not moved yet')

    ok(BR.Spawn.toWarmupPad(), 'the trip starts')
    pump(20000)

    local iCoords = firstOf('coords', function(e) return isWarmupSpawn(e.x, e.y) end)
    local iNet = firstOf('networked', function(e) return e.on end)

    ok(iCoords ~= nil, 'the player is teleported to an authored warmup spawn')
    ok(iNet ~= nil, 'and the ped becomes networked')
    if iCoords and iNet then
        ok(iCoords < iNet,
           ('the teleport comes FIRST (teleport #%d, networked #%d)')
               :format(iCoords, iNet))
    end

    -- Said the other way round, because the index comparison above would also
    -- be satisfied by a flip that happened during the fade: at the moment the
    -- latch flips, the ped must already BE at a warmup spawn.
    local flippedAt = nil
    for _, e in ipairs(order) do
        if e.kind == 'networked' and e.on then flippedAt = e.at end
    end
    ok(flippedAt ~= nil and isWarmupSpawn(ped.x, ped.y),
       'at the moment of the flip the ped is standing on a warmup spawn')

    ok(BR.LobbyPed.isNetworked(), 'and it stays networked in the match')
    ok(not BR.LobbyPed.entering(), 'the entrance was dropped by the trip')
    ok(not BR.LobbyPed.lockerLocked(), 'and readying up unlocks the locker too')

    -- THE CAMERA WENT WITH IT. A lobby camera left rendering after a teleport
    -- shows the inside of the world forever.
    ok(liveCamCount() == 0,
       ('no camera survives the trip to warmup (%d left)'):format(liveCamCount()))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 10. THE SPAWN IS ONE OF THE AUTHORED ONES, AND NOT ALWAYS THE SAME ONE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- COUNTED AGAINST THE TABLE RATHER THAN AGAINST A LITERAL. The owner re-surveys
-- these -- five became three on 2026-08-31 -- and a hardcoded count makes every
-- re-survey fail a test that has nothing to say about the change. What the
-- assertion is actually for is that the draw reaches EVERY authored stand and
-- does not get stuck on one, and that is the same claim at any length.

do
    local seen = {}
    for _ = 1, 200 do
        local s = BR.Spawn.warmupSpawn()
        ok(isWarmupSpawn(s.x, s.y) or true, '')   -- counted below instead
        seen[('%.2f,%.2f'):format(s.x, s.y)] = true
    end
    pass = pass - 200                              -- undo the placeholder counts
    local n = 0
    for _ in pairs(seen) do n = n + 1 end
    local authored = #BR.Config.Match.warmupSpawns
    ok(n == authored,
       ('all %d authored warmup spawns are reachable (saw %d)')
           :format(authored, n))

    -- An emptied list falls back to the old scatter rather than stacking every
    -- player on one coordinate.
    local real = BR.Config.Match.warmupSpawns
    BR.Config.Match.warmupSpawns = {}
    local s = BR.Spawn.warmupSpawn()
    ok(type(s.x) == 'number' and type(s.heading) == 'number',
       'an empty spawn list falls back to the scatter rather than failing')
    BR.Config.Match.warmupSpawns = real
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 11. THE LATCH RECOVERS FROM A ROAD THAT DOES NOT GO THROUGH THE TRIP
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A latch stuck at "local" outside the lobby is a player who cannot see anybody
-- they are fighting, and there are several ways to leave the lobby that never
-- touch toWarmupPad -- a /brforce, an admin resetting a stuck round, br_core
-- restarting under somebody mid-match.

do
    reset()
    ok(BR.LobbyPed.isLobbyPed(), 'precondition: local, in the lobby')

    -- ═══ ALIVE, AND IT SAID PlayerState.PLAYING UNTIL 2026-08-30 ═══
    --
    -- PLAYING IS A MatchState, NOT A PlayerState. The player list is LOBBY,
    -- WARMUP, BUS, FREEFALL, GLIDE, ALIVE, DBNO, OUT, LEFT -- so the old line
    -- read nil and set the state to nothing at all, here and at four other
    -- sites in this file.
    --
    -- WHY IT PASSED FOR WEEKS, AND WHY CORRECTING IT CHANGED NOTHING: every
    -- consumer on these paths compares against LOBBY, and one against WARMUP.
    -- Not one reads ALIVE. `nil ~= 'lobby'` is true exactly as `'alive' ~=
    -- 'lobby'` is, so the blocks really were exercising "the player is not in
    -- the lobby" -- the property they claim -- but reaching it through an
    -- absent value rather than a state.
    --
    -- WHAT IT WAS COSTING WAS THE FUTURE. The day one of these paths grows a
    -- rule keyed on a SPECIFIC match state -- an emote that differs for DBNO, a
    -- latch that only fires for ALIVE -- all five would have taken the wrong
    -- branch and stayed green. tools/check_player_states.lua is what noticed,
    -- and verify.sh now runs it over tools/ as well as resources/ so the next
    -- one cannot hide here either.
    BR.State.me.state = BR.PlayerState.ALIVE
    pump(300)
    ok(BR.LobbyPed.isLobbyPed(),
       'a state change alone does not flip it -- the ped is still on the mark')

    ped.x, ped.y = 1500.0, 2500.0     -- somebody teleported us, uncoreographed
    pump(300)
    ok(BR.LobbyPed.isNetworked(),
       'but a ped far from the lobby mark is networked, whoever moved it')

    -- ...and coming home puts it back.
    BR.State.me.state = BR.PlayerState.LOBBY
    pump(300)
    ok(BR.LobbyPed.isLobbyPed(), 'returning to the lobby makes it local again')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 11b. A SWAP THAT GETS THROUGH ANYWAY DROPS THE WALK RATHER THAN STRANDING IT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The lock refuses the interface and nothing server-side can change a model --
-- SetPlayerModel has one call site in the project. /brlocker is the remaining
-- road, and it is a deliberate manual override: it should leave a coherent
-- lobby behind rather than a ped on a hillside holding a task nobody owns.

do
    reset()
    wearChosenModel()
    pump(3000)
    ok(BR.LobbyPed.entering(), 'precondition: the walk is running')

    BR.Locker.apply('clown')
    pump(2000)

    ok(not BR.LobbyPed.entering(), 'a forced swap drops the entrance')
    ok(ped.clipset == nil, 'and takes the walking style with it')
    ok(not BR.LobbyPed.lockerLocked(), 'and unlocks, like every other ending')
    ok(ped.model == GetHashKey(BR.PedById('clown').model),
       'and the character really did change')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 12. THE LOCKER IS AVAILABLE AGAIN AFTERWARDS
-- ═══════════════════════════════════════════════════════════════════════════

do
    reset()
    wearChosenModel()
    pump(70000)     -- the whole entrance
    ok(not BR.LobbyPed.lockerLocked(), 'precondition: unlocked')

    local before = ped.model
    TriggerEvent('br:ui:action', BR.NuiCb.LOCKER_PICK, { id = 'clown' })
    pump(1000)
    ok(ped.model ~= before, 'a pick after the walk changes the character')

    -- The payload the page reads carries the lock, so the button can wear it.
    local seen = nil
    for i = #events, 1, -1 do
        if events[i].name == 'br:ui:sendLocal' and events[i].args[1] == BR.Nui.LOCKER then
            seen = events[i].args[2]
            break
        end
    end
    ok(seen ~= nil and seen.locked == false,
       'the locker payload carries `locked` so the button can be disabled')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 13. EVERY CASE TAKES THE SAME TIME, AND READYING UP CANCELS THE SPEED
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29: "Each walk should take the exact same amount of time, and
-- be faster at the first steps when necessary, before slowing down to a normal
-- pace for the last walk." Eighteen seconds, confirmed, for all four.
--
-- THE ASSERTION IS ABOUT THE FOUR CASES AGAINST EACH OTHER, which is the whole
-- reason the speeds stopped being authored: the paths are 41m, 59m, 29m and 34m
-- and one list of blend ratios cannot land all of them on one clock. Every case
-- is walked in full, and what is measured is the wall time between the first
-- task and the placement on the mark.

--- Did the client say it placed a ped that had not arrived?
---
--- DECLARED UP HERE because the case sweep below is the first thing that needs
--- it: "no case trips the failsafe on an ordinary return" is the assertion that
--- would have caught the camera going thirty percent faster turning a failsafe
--- into a teleport, and it belongs in the block that walks all four.
local function forcedHome()
    for _, l in ipairs(logged) do
        if l:find('after the camera parked', 1, true) then return true end
    end
    return false
end

do
    local C = BR.Config.Match.lobbyEntrance
    local target = C.walkTargetMs / 1000.0

    reset()
    wearChosenModel()
    pump(70000)

    -- ═══ AND IT GOT THERE ON ITS OWN FEET ═══
    --
    -- THE FAILSAFE IS A FAILSAFE ONLY WHILE IT DOES NOT FIRE ON AN ORDINARY
    -- RETURN, and for a long time nothing checked that -- so shortening the
    -- camera flight by thirty percent quietly put one of the old cases over the
    -- line on EVERY return, which would have reached the owner as "the ped is
    -- being teleported again" rather than as a timing number.
    ok(not forcedHome(),
        'the ped arrives on its own feet -- the failsafe does not fire on an '
            .. 'ordinary return')

    local tasks = {}
    for _, e in ipairs(order) do
        if e.kind == 'task' then tasks[#tasks + 1] = e end
    end

    local nLegs = #C.pedPath + 1
    ok(#tasks == nLegs,
        ('the ped is tasked once per leg, the lobby mark included (%d tasks, '
            .. '%d legs)'):format(#tasks, nLegs))

    -- THE LAST LEG IS A WALK, WHATEVER PRECEDED IT. It is the leg the player
    -- actually watches -- the camera has landed by then -- so arriving at a run
    -- would be the whole point missed.
    ok(#tasks > 0 and math.abs(tasks[#tasks].speed - 1.0) < 0.001,
        ('and it arrives at a walk (%.2f)')
            :format(#tasks > 0 and tasks[#tasks].speed or -1))

    -- AND IT ONLY EVER SLOWS DOWN. A ramp, not a step: speeding up mid-path
    -- would read as the ped noticing the camera.
    local descends = true
    for i = 2, #tasks do
        if tasks[i].speed > tasks[i - 1].speed + 0.001 then descends = false end
    end
    ok(descends, 'and never speeds up from one leg to the next')

    -- INSIDE THE CLAMPS. "a ratio of 12 is not a walk."
    local inRange = true
    for _, t in ipairs(tasks) do
        if t.speed < C.walkBlendMin - 0.001 or t.speed > C.walkBlendMax + 0.001 then
            inRange = false
        end
    end
    ok(inRange, 'and stays between the blend floor and ceiling')

    -- ═══ AND IT IS STILL SOLVED RATHER THAN AUTHORED ═══
    --
    -- THE FOUR-CASE SWEEP IS GONE WITH THE FOUR CASES, and it was carrying more
    -- than it looked: comparing the cases against each other is what proved the
    -- speeds were DERIVED, because no single authored list could put a 29m walk
    -- and a 59m walk on the same clock. With one path a flat list would fit it
    -- perfectly well, so that proof is not available any more.
    --
    -- WHAT REPLACES IT IS THE RAMP ITSELF. The blends are solved to land on the
    -- target, so they come out at whatever the geometry needs -- 30.8m over
    -- four legs at 18s is nothing like a round number, and a list somebody typed
    -- would be. Asserting the opening blend is not a value a person would pick,
    -- and that the ramp between the legs is even, is what still distinguishes a
    -- solved plan from an authored one.
    local opening = #tasks > 0 and tasks[1].speed or 0.0
    ok(opening > 1.0,
        ('the opening leg is quicker than a walk (%.3f)'):format(opening))

    local evenRamp = true
    if #tasks >= 3 then
        local firstGap = tasks[1].speed - tasks[2].speed
        for i = 3, #tasks do
            local gap = tasks[i - 1].speed - tasks[i].speed
            if math.abs(gap - firstGap) > 0.005 then evenRamp = false end
        end
    end
    ok(evenRamp,
        'and the ramp down to it is in equal steps, which is what a solved plan '
            .. 'looks like and an authored list does not')

    -- ═══ AND HERE IS THE NUMBER THE OWNER ASKED FOR ═══
    --
    -- "Each walk should take the exact same amount of time." Eighteen seconds.
    -- Nothing is clamped now: the old case 2 needed a blend of 3.76 to make it
    -- and was pinned at the 3.0 ceiling, and this path needs 1.71 m/s average.
    local landed = nil
    local L = BR.Config.Match.lobbyPos
    for _, e in ipairs(order) do
        if e.kind == 'coords' and e.at > 2000
           and math.abs(e.x - L.x) < 0.01 and math.abs(e.y - L.y) < 0.01 then
            landed = e break
        end
    end
    local took = (landed and #tasks > 0) and (landed.at - tasks[1].at) / 1000.0 or -1
    ok(took > 0 and math.abs(took - target) <= 1.0,
        ('the walk takes %.1fs against a target of %.1fs'):format(took, target))

    -- ═══ READYING UP MID-RUN CANCELS THE SPEED WITH THE TASK ═══
    --
    -- The blend ratio is an argument to TaskGoStraightToCoord rather than a
    -- property written onto the ped -- unlike the movement clipset, which needs
    -- its own reset. So the thing to prove is that stop() clears the TASK, and
    -- that nothing re-tasks afterwards at the running speed.
    reset()
    wearChosenModel()
    pump(1200)      -- inside the first leg, which is the fastest one

    local live = nil
    for _, e in ipairs(order) do if e.kind == 'task' then live = e.speed end end
    ok(live ~= nil and live > 1.0,
        ('precondition: the ped is mid-walk on the opening leg, above a walk '
            .. '(%s)'):format(tostring(live)))
    ok(ped.dest ~= nil, 'precondition: the task is live')

    order = {}
    BR.LobbyPed.stop('readied up')

    ok(firstOf('cleartasks') ~= nil,
        'readying up clears the ped task, and the blend ratio goes with it -- '
            .. 'a player who readies during the 2.0 leg does not carry a run '
            .. 'into warmup')
    ok(ped.dest == nil, 'so no destination survives the abandonment')

    order = {}
    pump(40000)
    ok(firstOf('task') == nil,
        'and nothing re-tasks afterwards at any speed')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 14. THE CAMERA IS A CURVE THAT SLOWS DOWN, AND IT NEVER STOPS ON THE WAY
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29, four complaints about one flight: "The speed is too slow
-- at the beginning and too fast at the end. Over the course of the final move
-- the camera should slow down exponentially. Also the camera facing direction
-- changes too suddenly - it should be much smoother. When the camera gets to a
-- position and changes direction that's also too sudden. I feel like we need
-- more steps in this process which will smooth out the corners into curves."
--
-- FOUR COMPLAINTS, FOUR ASSERTIONS, and one of them -- no stop between steps --
-- is the property from the round before that must survive all of this.

--- Every camera move of one entrance, in order.
local function glides()
    local out = {}
    for _, e in ipairs(order) do
        if e.kind == 'camglide' then out[#out + 1] = e end
    end
    return out
end

--- The cameras THE FLIGHT built, in flight order, with their rotations.
---
--- FOLLOWED THROUGH THE GLIDES RATHER THAN FILTERED BY TIME, because the lobby
--- camera the follow tick raises before and after the entrance is a `cammade`
--- too -- and it is built with a zero rotation and PointCamAtCoord, so letting
--- one into this list turns every rotation assertion into nonsense.
local function flightCams()
    local byId = {}
    for _, e in ipairs(order) do
        if e.kind == 'cammade' then byId[e.id] = e end
    end
    local out = {}
    for _, e in ipairs(order) do
        if e.kind == 'camglide' then
            if #out == 0 and byId[e.from] then out[1] = byId[e.from] end
            if byId[e.to] then out[#out + 1] = byId[e.to] end
        end
    end
    return out
end

do
    reset()
    wearChosenModel()
    pump(70000)

    local C = BR.Config.Match.lobbyEntrance
    local moves = glides()
    local made = flightCams()

    -- ═══ MORE STEPS, WHICH IS THE CORNERS BECOMING CURVES ═══
    --
    -- Three moves between four authored positions is three straight lines and
    -- two corners. The owner asked for this in as many words.
    ok(#moves == C.camSteps,
        ('the flight is cut into camSteps moves rather than one per authored '
            .. 'node (%d moves, camSteps %d)'):format(#moves, C.camSteps))

    -- ═══ NO EASE ON A STEP OF A FLIGHT ═══
    --
    -- This is the pause from the round before, and it must not come back to
    -- deliver the deceleration. An eased interpolation decelerates to a
    -- STANDSTILL at its destination; two dozen of those in a row is a camera
    -- that stops two dozen times. The slowing down asked for here is in how
    -- SHORT the last steps are, not in how they are interpolated.
    local eased = 0
    for _, m in ipairs(moves) do
        if m.easeLoc ~= 0 or m.easeRot ~= 0 then eased = eased + 1 end
    end
    ok(eased == 0,
        ('no step of the flight eases in or out (%d of %d eased)')
            :format(eased, #moves))

    -- ═══ FAST AT THE START, EXPONENTIALLY SLOWER AT THE END ═══
    --
    -- READ OFF THE PLAN RATHER THAN OFF THE LOGGED MOVES, and that is a change
    -- forced by the step count. The pace is a property of flightPlan, which is
    -- pure arithmetic; the LOG is a property of the fixture's clock, which
    -- advances in 50ms hops and therefore cannot resolve a step that is 34ms
    -- long. At 96 steps half of them are shorter than one hop, so the logged
    -- durations clamp to 1ms and every speed read from them is fiction. The
    -- loop's own behaviour -- ease flags, no gap between moves, one move per
    -- step -- is still asserted off the log below, because none of that depends
    -- on sub-hop timing.
    -- THE SAME SIX SETTINGS THE CLIENT FLIES WITH, the step floor and the start
    -- trim included: a plan built without either is not the plan the loop
    -- issues, and the trim is the one that changes every distance below.
    local minFrac = (C.camStepMinMs or 0) / math.max(1, C.camFlightMs or 1)
    local pacePlan = BR.LobbyCam.flightPlan(C.camPath, C.camSteps, C.camDecay,
        C.camRounding, minFrac, C.camStartTrim)
    local speeds, mids = {}, {}
    for i = 2, #pacePlan do
        local a, b = pacePlan[i - 1], pacePlan[i]
        local len = BR.Dist3(a.x, a.y, a.z, b.x, b.y, b.z)
        local secs = (b.t - a.t) * (C.camFlightMs / 1000.0)
        if secs > 0.0 then
            speeds[#speeds + 1] = len / secs
            mids[#mids + 1] = (a.t + b.t) * 0.5
        end
    end

    local rising = 0
    for i = 2, #speeds do
        -- A little slack: the curve's own geometry wobbles the arc-length
        -- resampling by a fraction of a percent, and that is not a pace change.
        if speeds[i] > speeds[i - 1] * 1.02 then rising = rising + 1 end
    end
    ok(#speeds > 4 and rising == 0,
        ('the camera never speeds up on the way down (%d of %d steps rose)')
            :format(rising, #speeds))

    ok(#speeds > 4 and speeds[1] > speeds[#speeds] * 2.0,
        ('and it opens far faster than it lands -- %.1f m/s to %.1f m/s')
            :format(speeds[1] or -1, speeds[#speeds] or -1))

    -- EXPONENTIAL RATHER THAN MERELY DECREASING. A linear ramp-down would pass
    -- the two assertions above and is not what was asked for.
    --
    -- THE OLD TEST COMPARED CONSECUTIVE STEP RATIOS, which only works while
    -- every step lasts the same length of time -- and they deliberately do not
    -- any more. The property itself is unchanged and does not depend on the
    -- spacing: speed is proportional to e^(-k*t), so ln(speed) + k*t is the
    -- same number at every point of the flight, wherever it is sampled.
    if #speeds >= 8 then
        local lo, hi = math.huge, -math.huge
        for i = 1, #speeds do
            local v = math.log(speeds[i]) + C.camDecay * mids[i]
            if v < lo then lo = v end
            if v > hi then hi = v end
        end
        ok(hi - lo < 0.15,
            ('the slowdown is exponential in time, not linear -- ln(speed) + '
                .. 'k*t spans %.3f across the flight'):format(hi - lo))
    end

    -- ═══ THE RESOLUTION AND THE ROUNDING ARE DIFFERENT SETTINGS ═══
    --
    -- Owner, 2026-08-29: "the camera movements in the lobby should be 2x
    -- smoother please. And round the corners once more. I mean like 2x the
    -- resolution of points."
    --
    -- TWO CLAIMS, AND CONFLATING THEM IS THE EASY MISTAKE: more sample points
    -- is smoother MOTION over identical GEOMETRY. Doubling camSteps halves how
    -- far the shot turns in any one move and changes the PATH not at all, so a
    -- build that answered the whole sentence with camSteps would look smoother
    -- and still corner exactly as tightly. These assertions are pure
    -- flightPlan arithmetic -- no fixture clock -- and they pin each knob to
    -- the half of the report it actually answers.
    --
    -- The measure is the path's own bend: degrees of TRAVEL direction per
    -- metre, densely sampled so it cannot be an artefact of the step count.
    --
    -- MEASURED OFF EVENLY-SPACED POINTS, WHICH flightPlan NO LONGER GIVES. Its
    -- steps are spaced by how far the shot moves, so its points bunch up
    -- exactly where the curve bends hardest -- fine for flying, useless for
    -- asking how hard it bends, because the answer would then depend on its own
    -- sampling. BR.LobbyCam.curveSamples is evenly spaced by arc length, so
    -- degrees per metre out of it is a fact about the PATH.
    local function sharpestBend(n, rounding)
        local pl = BR.LobbyCam.curveSamples(C.camPath, n, rounding)
        local worst, prevB = 0.0, nil
        for i = 2, #pl do
            local a, b = pl[i - 1], pl[i]
            local d = BR.Dist(a.x, a.y, b.x, b.y)
            if d > 0.02 then
                local bg = BR.Bearing(a.x, a.y, b.x, b.y)
                if prevB then
                    local turn = math.abs((bg - prevB + 540.0) % 360.0 - 180.0)
                    if turn / d > worst then worst = turn / d end
                end
                prevB = bg
            end
        end
        return worst
    end

    -- ═══ THE ROUNDING'S EFFECT REVERSED WHEN THE PATH CHANGED ═══
    --
    -- IT USED TO ASSERT THAT ROUNDING HELPS, and that is exactly why it is
    -- re-measured rather than re-run. On the path surveyed on 2026-08-29 a
    -- rounding of 0.75 was meaningfully gentler through the corner than a plain
    -- 0.50, because that path turned 69 degrees at its last node. The path
    -- surveyed on 2026-08-30 turns 32.6 and 19.7, and on it MORE rounding is
    -- worse by every measure -- 7.2 deg/m at 0.50 against 13.1 at 0.75.
    --
    -- SO THE OLD ASSERTION IS GONE RATHER THAN INVERTED. "Rounding must help"
    -- and "rounding must not help" are both claims about one survey, and the
    -- survey is the thing that keeps changing. What is asserted instead is the
    -- part that does not: that the CLIFF is real and close, so the next person
    -- to reach for a bigger number finds out here rather than in a playtest.
    local plain = sharpestBend(2000, 0.5)
    ok(sharpestBend(2000, 1.0) > plain * 2.0,
        ('rounding past 1.00 is far worse than not rounding at all on this path '
            .. '(%.1f against %.1f deg/m)')
            :format(sharpestBend(2000, 1.0), plain))

    -- ...AND SAMPLING DOES NOT CHANGE THE GEOMETRY. Same rounding, four times
    -- the points, same path. This is the assertion that fails if somebody
    -- "answers" a corner complaint by raising camSteps, which measures the
    -- sampling and not the curve.
    local few  = sharpestBend(2000, C.camRounding)
    local many = sharpestBend(8000, C.camRounding)
    ok(math.abs(few - many) < math.max(1.0, many * 0.15),
        ('and sampling does not -- the geometry is the same path however often '
            .. 'it is measured (%.1f vs %.1f deg/m)'):format(few, many))

    -- WHAT ACTUALLY GUARDS THE PICTURE IS THE PER-STEP TURN, further down: it
    -- is what the eye sees, it is independent of which survey is loaded, and it
    -- catches a rounding wound past the cliff whatever the geometry says.

    -- ═══ AND THE FACING TURNS SMOOTHLY ═══
    --
    -- "the camera facing direction changes too suddenly". Three authored
    -- headings meant three rotations; one moving aim point means one. The
    -- assertion is the WORST single-step turn, because a smooth rotation with
    -- one snap in it is still a snap.
    local worstTurn, at = 0.0, 0
    for i = 2, #made do
        local d = math.abs((made[i].yaw - made[i - 1].yaw + 540.0) % 360.0 - 180.0)
        if d > worstTurn then worstTurn, at = d, i end
    end

    -- ═══ AND THIS IS WHERE THE RESOLUTION IS ACTUALLY ASSERTED ═══
    --
    -- "the camera movements in the lobby should be 2x smoother please ... 2x
    -- the resolution of points." Doubling camSteps halves the time and the
    -- distance in each move, so what it buys is a shot that turns LESS far in
    -- any one of them -- which is the thing he will judge by eye and the only
    -- honest place to pin the number.
    --
    -- Measured: 20.4 degrees at the old 24 steps, 12.8 at 48. Fifteen is the
    -- line between them, and it is not an arbitrary one -- above about that a
    -- single move starts reading as a jump rather than as motion. The worst is
    -- always the LAST step, where the camera is under two metres from its
    -- subject and a small move is a large angle.
    ok(#made > 4 and worstTurn < 5.0,
        ('no single step of the flight turns the camera far enough to read as a '
            .. 'jump (worst %.1f degrees at step %d of %d)')
            :format(worstTurn, at, #made - 1))

    -- ═══ AND NO STEP CARRIES MUCH MORE OF THE TURN THAN ANY OTHER ═══
    --
    -- Owner, 2026-08-29, having watched 48 steps: "It's smoother, but still
    -- appears stepped."
    --
    -- THE STEPPING WAS IN TWO STEPS OUT OF FORTY-EIGHT. Spaced evenly in TIME,
    -- the per-step turn ran 0.6 degrees at the top of the descent and 12.8 at
    -- the bottom -- the camera ends 1.83m from its subject, and the angle to a
    -- thing you are two metres from changes enormously for a small move. Forty
    -- six invisible steps and two visible ones.
    --
    -- SO WHAT IS ASSERTED IS FLATNESS, not the count. Doubling the count halves
    -- every step and leaves the LAST one still four times the average, which is
    -- paying everywhere for a problem that lives in two places. Spacing the
    -- steps by how far the shot actually moves is what flattens it, and this is
    -- the number that says whether that is switched on: uniform-in-time spacing
    -- puts the worst step at four-odd times the mean however many steps there
    -- are, and cost spacing holds it near two.
    local sum = 0.0
    for i = 2, #made do
        sum = sum + math.abs((made[i].yaw - made[i - 1].yaw + 540.0) % 360.0 - 180.0)
    end
    local mean = (#made > 1) and (sum / (#made - 1)) or 0.0
    ok(mean > 0.0 and worstTurn / mean < 3.0,
        ('and the turn is shared evenly across them rather than piled into the '
            .. 'landing (worst %.1f deg against a mean of %.1f)')
            :format(worstTurn, mean))

    -- ...WHICH MEANS THE STEPS DO NOT ALL LAST THE SAME LENGTH OF TIME. A step
    -- through the landing is short and one down the long descent is long. If
    -- these were equal the spacing above would be back to uniform-in-time.
    local shortest, longest = math.huge, 0.0
    for i = 2, #pacePlan do
        local d = (pacePlan[i].t - pacePlan[i - 1].t) * C.camFlightMs
        if d < shortest then shortest = d end
        if d > longest then longest = d end
    end
    ok(longest > shortest * 3.0,
        ('and the steps genuinely differ in duration -- %dms at the tightest, '
            .. '%dms at the loosest'):format(math.floor(shortest), math.floor(longest)))

    -- ...AND NONE OF THEM IS SHORTER THAN A FRAME.
    --
    -- THE COST SPACING WILL ASK FOR ONE IF NOTHING STOPS IT: it draws its
    -- boundaries where the shot moves fastest, and this path's sharpest bend is
    -- its final approach, so the landing collects a cluster of very short steps
    -- -- 11ms before the floor was added, against a frame of about 17. A move
    -- shorter than a frame has no frame to interpolate across and resolves as a
    -- cut; several in a row is a stutter arriving exactly where the smoothing
    -- was aimed, which would read as the complaint that started all this.
    --
    -- A LONGER PATH DOES NOT FIX IT, which is why this is a floor rather than a
    -- step count. The spacing is by cost, so a sharper corner pulls the
    -- boundaries together however much room there is elsewhere.
    -- SIXTEEN, NOT camStepMinMs. Asserting against the config value would be the
    -- test agreeing with whatever was typed -- set the floor to zero and it
    -- would still pass. A frame is a fact about the engine, so it is the
    -- constant, and the setting is checked separately for being at least one.
    ok(shortest >= 16.0,
        ('and none is shorter than a frame (%dms)'):format(math.floor(shortest)))
    ok((C.camStepMinMs or 0) >= 16,
        ('and the floor that keeps it there is at least a frame (%dms)')
            :format(C.camStepMinMs or 0))

    -- ...AND NO SINGLE INTERPOLATION SPANS A LONG STRETCH OF THE CURVE.
    --
    -- THE OTHER HALF OF THE COST FUNCTION. Spacing by turn alone puts almost no
    -- boundaries through the long descent -- the longest chord goes from 6.9m
    -- to 34.2m -- and a chord is a straight line where the path is a curve.
    -- Measured on today's coordinates that costs nothing, because the stretch
    -- it lengthens happens to be straight; the point is that the sampling must
    -- not DEPEND on it being straight, which is a fact about one survey and not
    -- about the design. Re-survey camPath with a bend there and turn-only
    -- spacing would fly straight through it.
    local pathLen, longestChord = 0.0, 0.0
    for i = 2, #pacePlan do
        local a, b = pacePlan[i - 1], pacePlan[i]
        local d = BR.Dist3(a.x, a.y, a.z, b.x, b.y, b.z)
        pathLen = pathLen + d
        if d > longestChord then longestChord = d end
    end
    ok(pathLen > 0.0 and longestChord < pathLen * 0.04,
        ('and no one step flies a long chord across the curve (%.1fm, of a '
            .. '%.0fm path)'):format(longestChord, pathLen))

    -- ═══ AND NOTHING SITS BETWEEN TWO STEPS ═══
    --
    -- Each move is issued when the one before it finishes. Anything else is a
    -- camera parked waiting for something -- which is what the last move used
    -- to do, holding until the ped's measured arrival came within camLeadMs.
    local worst = 0
    for i = 2, #moves do
        local gap = moves[i].at - (moves[i - 1].at + (moves[i - 1].ms or 0))
        if gap > worst then worst = gap end
    end
    ok(worst <= 100,
        ('no step waits for the one before it to be over (worst gap %dms)')
            :format(worst))
end

-- ...AND EVERY STEP IS FLOWN FOR ITS OWN SHARE OF THE CLOCK.
--
-- THE PLAN AND THE LOOP HAVE TO AGREE, and after the redistribution they can
-- disagree silently. The plan's steps are spaced by how far the shot moves, so
-- they no longer last equal lengths of time -- a loop still slicing the flight
-- into equal durations would fly the same POSITIONS at the wrong SPEEDS, which
-- is the pace complaint from two rounds ago arriving by a new road. Nothing
-- caught that: the pacing assertions above read the plan, and the plan is right
-- either way.
--
-- RUN AT TWELVE STEPS, deliberately. The fixture's clock advances in 50ms hops
-- and at 96 steps half the durations are shorter than one hop, so the logged
-- values are dominated by rounding. At twelve every step is hundreds of
-- milliseconds and the log can be read honestly.
do
    local C = BR.Config.Match.lobbyEntrance
    local realSteps = C.camSteps
    C.camSteps = 12

    reset()
    wearChosenModel()
    pump(70000)

    local plan = BR.LobbyCam.flightPlan(C.camPath, 12, C.camDecay, C.camRounding,
        (C.camStepMinMs or 0) / math.max(1, C.camFlightMs or 1), C.camStartTrim)
    local moves = glides()

    ok(#moves == 12, ('precondition: twelve moves were flown (%d)'):format(#moves))

    -- Each logged duration against the one the plan asked for. Generous, because
    -- the loop measures its boundaries off a real clock and spends a hop of
    -- lateness out of the move it belongs to -- but nowhere near generous enough
    -- to hide equal slices, which would be 1154ms every time.
    local worst, worstAt = 0.0, 0
    for i = 2, #plan do
        local want = (plan[i].t - plan[i - 1].t) * C.camFlightMs
        local got = moves[i - 1] and moves[i - 1].ms or 0
        local off = math.abs(got - want)
        if off > worst then worst, worstAt = off, i - 1 end
    end
    ok(#moves == 12 and worst < 120.0,
        ('and each is flown for the duration its own step asked for (worst step '
            .. '%d is %.0fms out)'):format(worstAt, worst))

    C.camSteps = realSteps
end

-- ...AND THE FLIGHT DOES NOT READ THE PED AT ALL.
--
-- The old code held at the last node until the ped's estimated arrival came
-- within camLeadMs. At the speeds authored at the time it happened not to
-- dwell, so the property worth having is not "it does not dwell today" -- it is
-- that slowing the WALK right down changes nothing about the flight.
do
    local C = BR.Config.Match.lobbyEntrance
    local realMps = C.walkMps
    C.walkMps = 0.35              -- a quarter pace: the walk runs minutes long

    reset()
    wearChosenModel()
    pump(80000)

    local moves = glides()
    local worst = 0
    for i = 2, #moves do
        local gap = moves[i].at - (moves[i - 1].at + (moves[i - 1].ms or 0))
        if gap > worst then worst = gap end
    end
    ok(#moves > 1 and worst <= 100,
        ('the flight is the same flight when the ped is slow -- it does not '
            .. 'wait on the walk (worst gap %dms over %d moves)')
            :format(worst, #moves))

    C.walkMps = realMps
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 14b. THE FLIGHT STARTS PART OF THE WAY ALONG ITS OWN PATH, AND STILL TAKES
--      EXACTLY AS LONG
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-31: "the lobby cam movement goes for a WAY too long distance -
-- you were right. Can we make it start closer to the destination by like 30%?
-- Keep the timing the same though."
--
-- TWO CLAIMS THAT PULL AGAINST EACH OTHER, which is the only reason this is a
-- suite entry rather than a config diff. Less ground in the same time is a
-- SLOWER camera, and the obvious "helpful" mistake -- trimming camFlightMs to
-- match so the speed is preserved -- would satisfy the first sentence and
-- silently undo the second. So both halves are asserted, and the timing half is
-- read off the fixture's clock rather than off the arithmetic that produced it.
--
-- THE THIRD CLAIM IS THE SHAPE. "Closer to the destination" has a cheap reading
-- -- slide the opening shot down the straight line toward home -- and that is a
-- different flight through different air. The trim moves the start ALONG the
-- surveyed curve, so what is asserted is that the new opening shot is still a
-- point ON the path, and that the cheap reading would not be.
do
    local C = BR.Config.Match.lobbyEntrance
    local minFrac = (C.camStepMinMs or 0) / math.max(1, C.camFlightMs or 1)

    local function planWith(trim)
        return BR.LobbyCam.flightPlan(C.camPath, C.camSteps, C.camDecay,
            C.camRounding, minFrac, trim)
    end
    local function arcLen(plan)
        local n = 0.0
        for i = 2, #plan do
            n = n + BR.Dist3(plan[i - 1].x, plan[i - 1].y, plan[i - 1].z,
                             plan[i].x, plan[i].y, plan[i].z)
        end
        return n
    end

    local full = planWith(0.0)
    local flown = planWith(C.camStartTrim)
    local hx, hy, hz = BR.LobbyCam.lobbyFrame()

    -- ═══ IT STARTS CLOSER TO WHERE IT LANDS ═══
    --
    -- Against the untrimmed flight rather than against a metre count, so this
    -- keeps meaning the same thing after the next survey. Set camStartTrim to 0
    -- and this is the assertion that goes red.
    local wasGap = BR.Dist3(full[1].x, full[1].y, full[1].z, hx, hy, hz)
    local nowGap = BR.Dist3(flown[1].x, flown[1].y, flown[1].z, hx, hy, hz)
    ok(nowGap < wasGap * 0.85,
        ('the flight starts closer to the shot it lands on -- %.0fm out against '
            .. '%.0fm untrimmed'):format(nowGap, wasGap))

    -- ...AND BY THE FRACTION THE NUMBER SAYS. The trim is a share of the path's
    -- LENGTH, so this is what makes the setting readable: 0.30 means the camera
    -- flies 70% of the ground it used to, not "somewhat less".
    local wasLen, nowLen = arcLen(full), arcLen(flown)
    local ratio = wasLen > 0.0 and (nowLen / wasLen) or -1
    ok(math.abs(ratio - (1.0 - C.camStartTrim)) < 0.02,
        ('and it flies %.0f%% of the path, which is the %.0f%% trim it was '
            .. 'given (%.0fm of %.0fm)')
            :format(ratio * 100.0, C.camStartTrim * 100.0, nowLen, wasLen))

    -- ═══ ALONG THE CURVE, NOT ACROSS IT ═══
    --
    -- The opening shot has to be a point the untrimmed flight ALSO passed
    -- through -- same arc, entered late -- so it is measured against densely
    -- sampled points of the path itself. The straight-line reading is measured
    -- too, and it is the number that says this assertion has teeth: it is not
    -- close to the path at all, so a build that trimmed toward the destination
    -- would fail here rather than pass by accident.
    local curve = BR.LobbyCam.curveSamples(C.camPath, 4000, C.camRounding)
    local function offPath(x, y, z)
        local best = math.huge
        for _, q in ipairs(curve) do
            local d = BR.Dist3(x, y, z, q.x, q.y, q.z)
            if d < best then best = d end
        end
        return best
    end

    local onCurve = offPath(flown[1].x, flown[1].y, flown[1].z)
    local t = C.camStartTrim
    local shortcut = offPath(full[1].x + (hx - full[1].x) * t,
                             full[1].y + (hy - full[1].y) * t,
                             full[1].z + (hz - full[1].z) * t)
    ok(onCurve < 0.5,
        ('the opening shot is still a point ON the surveyed path (%.2fm off it)')
            :format(onCurve))
    ok(shortcut > 20.0,
        ('and it is not the straight line toward home, which leaves the path by '
            .. '%.0fm'):format(shortcut))

    -- ...AND THE LANDING IS UNTOUCHED. The whole reason the trim is taken off
    -- the FRONT: the shot the locker was composed against is the shot the
    -- entrance still ends on, exactly.
    local last = flown[#flown]
    ok(math.abs(last.x - hx) < 0.01 and math.abs(last.y - hy) < 0.01
        and math.abs(last.z - hz) < 0.01,
       'and a trimmed flight still lands on the lobby frame exactly')

    -- ═══ AND THE TIMING IS THE SAME TIMING ═══
    --
    -- "Keep the timing the same though." MEASURED OFF THE FIXTURE'S CLOCK, from
    -- the first move issued to the last one finishing, on two real entrances --
    -- one trimmed, one not. The plan's own `t` column spans 0..1 either way and
    -- would agree with itself no matter what the loop did with it, which is
    -- exactly the reassurance that is worth nothing here.
    local function flightMs()
        reset()
        wearChosenModel()
        pump(70000)
        local moves = glides()
        if #moves < 2 then return -1, #moves end
        local last = moves[#moves]
        return (last.at + (last.ms or 0)) - moves[1].at, #moves
    end

    local trimmedMs, trimmedMoves = flightMs()

    local shipped = C.camStartTrim
    C.camStartTrim = 0.0
    local untrimmedMs, untrimmedMoves = flightMs()
    C.camStartTrim = shipped

    -- One 50ms hop of slack, which is the fixture's own resolution and nowhere
    -- near enough to hide the 30% the speed-preserving mistake would take off.
    ok(trimmedMs > 0 and math.abs(trimmedMs - untrimmedMs) <= 50,
        ('the trimmed flight takes exactly as long as the untrimmed one -- '
            .. '%dms against %dms'):format(trimmedMs, untrimmedMs))
    ok(trimmedMs > 0 and math.abs(trimmedMs - (C.camFlightMs or 0)) <= 100,
        ('and it is still the whole of camFlightMs -- %dms against %dms')
            :format(trimmedMs, C.camFlightMs or 0))
    ok(trimmedMoves == untrimmedMoves and trimmedMoves == C.camSteps,
        ('and it is still cut into the same camSteps moves (%d and %d)')
            :format(trimmedMoves, untrimmedMoves))

    -- ═══ WHICH MEANS IT IS SLOWER, AND THAT IS THE POINT ═══
    --
    -- The consequence he asked for, stated as an assertion so that nobody
    -- "restores" the speed by cutting camFlightMs and leaves this suite green.
    -- Same clock over 70% of the ground is 70% of the speed, everywhere.
    ok(nowLen < wasLen * 0.95,
        ('so the camera moves slower over the whole flight -- %.1f m/s average '
            .. 'against %.1f'):format(nowLen / (C.camFlightMs / 1000.0),
                                      wasLen / (C.camFlightMs / 1000.0)))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 15. THE PED ROUNDS ITS CORNERS RATHER THAN STOPPING ON THEM
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29: "it seems the ped walks to the point, stops, turns, then
-- walks to the next point. Can we maybe smooth the corners to keep them
-- walking?"
--
-- TWO CAUSES, AND THE FIRST ONE IS IN CONFIG RATHER THAN IN THE CLIENT. The
-- seventh argument to TaskGoStraightToCoord is the heading to face ON ARRIVAL,
-- and every leg was handing it the heading authored on the corner -- which is
-- where the surveyor was looking, and for two of the three corners that is back
-- the way he came. The ped was being told to arrive, turn eighty-odd degrees
-- the wrong way, and only then given the next leg.
--
-- The second is that the next leg only arrived once the ped was within 0.9m of
-- the corner, by which time a go-to-coord task has already slowed the ped down
-- to stop on it.

do
    -- CASE 1, BECAUSE IT HAS THE MOST CORNERS. Five of them, which is five
    -- chances to face the wrong way and five handovers to be late.
    reset()
    wearChosenModel()
    pump(70000)

    -- The legs, as the client builds them: the case's corners then the mark.
    local C = BR.Config.Match.lobbyEntrance
    local legs = {}
    for _, n in ipairs(C.pedPath) do legs[#legs + 1] = n end
    legs[#legs + 1] = BR.Config.Match.lobbyPos

    local tasks = {}
    for _, e in ipairs(order) do
        if e.kind == 'task' then tasks[#tasks + 1] = e end
    end
    ok(#tasks == #legs, ('precondition: one task per leg (%d)'):format(#tasks))

    if #tasks == #legs then
        -- ═══ EVERY CORNER IS FACED THE WAY THE PATH GOES NEXT ═══
        local worstOff, worstLeg = 0.0, 0
        for i = 1, #legs - 1 do
            local want = BR.GtaHeading(BR.Bearing(legs[i].x, legs[i].y,
                                                  legs[i + 1].x, legs[i + 1].y))
            local off = math.abs((tasks[i].heading or 0.0) - want) % 360.0
            if off > 180.0 then off = 360.0 - off end
            if off > worstOff then worstOff, worstLeg = off, i end
        end
        ok(worstOff < 5.0,
            ('a corner is faced toward the NEXT corner, not toward whatever the '
                .. 'survey recorded (leg %d is %.1f degrees out)')
                :format(worstLeg, worstOff))

        -- ...AND THE LOBBY MARK KEEPS ITS AUTHORED HEADING, because it is not a
        -- corner -- it is what the whole lobby shot is composed against.
        ok(math.abs((tasks[#tasks].heading or 0.0)
                    - BR.Config.Match.lobbyPos.heading) < 0.01,
            'the final leg still faces the authored lobby heading')

        -- ═══ AND THE HANDOVER HAPPENS BEFORE THE PED GETS THERE ═══
        --
        -- Measured where the ped was STANDING when each task arrived, against
        -- the corner the previous leg was aimed at. The whole fix is that this
        -- number is metres rather than centimetres.
        -- AGAINST THE LEG'S OWN CLAMPED RADIUS, not the flat cornerRadius:
        -- lobbyped.lua clamps the handover to 40% of the leg being walked so a
        -- short leg cannot be swallowed whole by its own corner, and case 1's
        -- opening leg is under four metres. Asserting the flat 2m against a leg
        -- that legitimately hands over at 1.5m would be testing the clamp away.
        local late, lateLeg, wanted = 1.0, 0, 0.0
        for i = 2, #tasks do
            local prev = legs[i - 1]
            local raw = BR.Dist(tasks[i - 1].fromX, tasks[i - 1].fromY, prev.x, prev.y)
            local want = math.min(C.cornerRadius, raw * 0.4)
            if want < C.arriveRadius then want = C.arriveRadius end
            local d = BR.Dist(tasks[i].fromX, tasks[i].fromY, prev.x, prev.y)
            local ratio = want > 0.0 and (d / want) or 1.0
            if ratio < late then late, lateLeg, wanted = ratio, i, want end
        end
        ok(late >= 0.75,
            ('each leg is handed over while the ped is still short of the '
                .. 'corner and still moving (leg %d took over at %.0f%% of its '
                .. '%.2fm handover)'):format(lateLeg, late * 100.0, wanted))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 16. THE WALK ENDS ON THE MARK RATHER THAN A METRE SHORT OF IT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29: "the ped is getting close to the final coords, but then
-- being teleported there. Not sure why that is."
--
-- IT WAS arriveRadius, AND THERE WAS NO SECOND TELEPORT TO FIND. The leg loop
-- stopped walking the moment the ped was within 0.9m of its target, and the
-- target of the last leg is the lobby mark -- so standOnMark's exact placement
-- had 0.9m left to cover, in plain sight, six feet from a landed camera.
--
-- The destination was never wrong, so asserting where the ped ends up proves
-- nothing (the broken version passes that too, and did). What is asserted is
-- HOW FAR THE WRITE MOVED THEM.

do
    reset()
    wearChosenModel()
    pump(70000)

    local p = BR.Config.Match.lobbyPos
    local landing = nil
    for _, e in ipairs(order) do
        if e.kind == 'coords' and e.at > 2000
           and math.abs(e.x - p.x) < 0.01 and math.abs(e.y - p.y) < 0.01 then
            landing = e
            break
        end
    end

    ok(landing ~= nil, 'precondition: the walk ends with a placement on the mark')
    ok(landing ~= nil and landing.jump <= 0.30,
        ('the ped WALKS onto the mark -- the placement at the end of it moves '
            .. 'them a distance nobody can see (%.2fm)')
            :format(landing and landing.jump or -1.0))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 17. THE ENTRANCE HAPPENS ON EVERY TRIP BACK TO THE LOBBY
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29: "Also let's make that grand entry happen for every trip
-- back to the lobby. That was my expectation."
--
-- It used to run once per br_core load. RE-ARMED ON LEAVING rather than on
-- arriving, which is what makes it cover the roads nobody enumerated: an admin
-- force, a stuck round being reset, the ordinary end of a match.

do
    reset()
    wearChosenModel()
    pump(70000)
    ok(not BR.LobbyPed.entering(), 'precondition: the first entrance is over')
    ok(not BR.LobbyPed.lockerLocked(), 'precondition: and it released the locker')

    -- Away to a match, by a road that is not the choreographed one.
    BR.State.me.state = BR.PlayerState.ALIVE
    ped.x, ped.y = 1500.0, 2500.0
    pump(500)

    -- ...AND STILL NOT WHILE WE ARE ELSEWHERE. The re-arm must not be a start.
    ok(not BR.LobbyPed.entering(),
        'being out of the lobby re-arms the entrance but does not run it')

    -- Home again.
    local p = BR.Config.Match.lobbyPos
    BR.State.me.state = BR.PlayerState.LOBBY
    ped.x, ped.y, ped.z = p.x, p.y, p.z
    order = {}
    pump(500)

    ok(BR.LobbyPed.entering(), 'a second arrival in the lobby gets its own entrance')
    ok(BR.LobbyPed.lockerLocked(), 'and the locker is locked again for it')
    ok(firstOf('task') ~= nil, 'and the ped really is walking a leg, not just flagged')

    pump(70000)
    ok(not BR.LobbyPed.entering(), 'the second entrance ends like the first')
    ok(not BR.LobbyPed.lockerLocked(),
        'and unlocks -- a lock that arms twice and clears once is worse than none')
    ok(math.abs(ped.x - p.x) < 0.01 and math.abs(ped.y - p.y) < 0.01,
        'and leaves the ped on the mark')
end

-- ...AND THE TRIP HOME HANDS IT THE BLACK RATHER THAN RACING IT.
--
-- The entrance opens with a teleport thirty metres up the path. On the boot
-- road the loading screen covers that; on the trip home the cover ends inside
-- BR.Spawn.respawn's exact path, which finishes with BR.Spawn.reveal() and
-- therefore with DoScreenFadeIn. A fade renders nothing on the frame it is
-- STARTED, so a placement in that same frame is still completely hidden -- and
-- one Citizen.Wait later is not: the collision wait after it can be seconds
-- long, and the entrance's own 10Hz tick is gated on `traveling`, which does
-- not clear until the trip thread ends. Both of those put the teleport in front
-- of the player, which is the arriving-ped pop this whole feature removes.
--
-- SO THE ASSERTION IS ABOUT ELAPSED TIME, NOT ABOUT ORDER. "The placement came
-- after the fade started" is true of the broken version too -- seconds after.
-- What has to hold is that NO CLOCK TIME passes between them at all.

do
    reset()
    wearChosenModel()
    pump(70000)

    BR.State.me.state = BR.PlayerState.ALIVE
    ped.x, ped.y = 1500.0, 2500.0
    pump(500)

    BR.State.me.state = BR.PlayerState.LOBBY
    order = {}
    BR.Spawn.toLobby(false)
    pump(4000)

    local C = BR.Config.Match.lobbyEntrance
    local spawn = C.pedStart
    local _, start = firstOf('coords',
        function(e) return math.abs(e.x - spawn.x) < 0.01 end)
    local _, fade = firstOf('fadein')

    ok(start ~= nil, 'the trip home starts the entrance')
    ok(fade ~= nil, 'precondition: the trip home lifts its cover')
    ok(start ~= nil and fade ~= nil and start.at == fade.at,
        ('the ped is placed on the start mark in the same frame the cover '
            .. 'lifts, not after it (%sms apart)')
            :format(start and fade and tostring(start.at - fade.at) or '?'))

    -- AND THE ENTRANCE REALLY RAN, rather than the assertion above passing
    -- because nothing happened at all on this road.
    ok(BR.LobbyPed.entering(),
        'and the entrance itself is under way on the trip home')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 17b. ...AND THE WALK DOES NOT START UNTIL THERE IS SOMEBODY WATCHING IT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29, having played the round that added the re-arm: "when
-- coming back from the warmup or another match, the ped doesn't do the full
-- walk again. It should."
--
-- ═══ THE ENTRANCE DID RUN. THE OPENING OF IT WAS COVERED ═══
--
-- The re-arm above is not the bug, which is why every assertion in 17 was green
-- and stayed green. What the owner watched is the TAIL of a walk: on the road
-- home the ped is placed under the trip's cover -- correctly, that is the pop
-- this whole feature removes -- and then the walk STARTED under it too, while
-- the camera flight (which already waited for IsScreenFadedIn) did not.
--
-- THE LEAVING CURTAIN IS THE WORST OF IT and it is the road he named. The
-- TO_LOBBY handler lowers it on a schedule about the ISLAND streaming in: a
-- 3.5s floor, then collision, then two more seconds. BR.Spawn.toLobby starts the
-- entrance about 450ms into that, so around five seconds of walk happened behind
-- an opaque NUI layer -- and case 1's whole opening leg is shorter than that.
--
-- THIS SUITE COULD NOT SEE IT UNTIL NOW, and that is the other half of the bug:
-- DoScreenFadeIn was instantaneous here, so no cover ever had a DURATION for a
-- walk to hide inside. It does now, and this block drives the TO_LOBBY handler
-- rather than BR.Spawn.toLobby directly so the curtain's own lifetime is real.

do
    reset()
    wearChosenModel()
    pump(70000)      -- the boot entrance, out of the way

    BR.State.me.state = BR.PlayerState.ALIVE
    ped.x, ped.y = 1500.0, 2500.0
    pump(500)

    -- /brleave from a match: the server sets me LOBBY and sends TO_LOBBY, which
    -- raises the curtain and takes the trip home.
    BR.State.me.state = BR.PlayerState.LOBBY
    order = {}
    TriggerEvent(BR.Net.TO_LOBBY)
    pump(30000)

    local C = BR.Config.Match.lobbyEntrance
    local spawn = C.pedStart

    local _, placed = firstOf('coords',
        function(e) return math.abs(e.x - spawn.x) < 0.01 end)
    local _, firstTask = firstOf('task')

    ok(placed ~= nil, 'precondition: the trip home placed the ped on its mark')
    ok(firstTask ~= nil, 'precondition: and the walk ran')

    -- ═══ THE CURTAIN CAME DOWN BEFORE THE FIRST STEP ═══
    --
    -- `curtainWanted` is br_ui's opaque layer, and the game's own fade natives
    -- cannot see it -- which is precisely why the walk used to ignore it. The
    -- assertion is about the FIRST leg specifically: it is the fast one, it is
    -- the one the owner lost, and by the time the second leg starts the curtain
    -- is always down anyway.
    local curtainDown = nil
    for _, e in ipairs(events) do
        if e.name == 'br:ui:sendLocal' and e.args[1] == BR.Nui.LEAVING
           and e.args[2] and e.args[2].show == false then
            curtainDown = true
        end
    end
    ok(curtainDown == true, 'precondition: and the leaving curtain was lowered')

    ok(placed ~= nil and firstTask ~= nil and firstTask.at > placed.at,
        'the ped is placed under the cover and only walks afterwards')

    -- THE REAL ASSERTION: how much of the walk happened before the cover
    -- lifted. None of it. The placement is under the cover; the WALK is not.
    local coveredLegs = 0
    for _, e in ipairs(order) do
        if e.kind == 'task' and e.covered then coveredLegs = coveredLegs + 1 end
    end
    ok(coveredLegs == 0,
        ('no leg of the walk is tasked while the screen is still covered '
            .. '(%d of them were)'):format(coveredLegs))

    -- ...AND THE WHOLE WALK IS VISIBLE, measured the way the owner would: the
    -- distance from the start mark to where the ped was standing when it was
    -- first tasked. It should be nothing -- the ped has not moved yet.
    local moved = firstTask
        and BR.Dist(firstTask.fromX, firstTask.fromY, spawn.x, spawn.y) or 999.0
    ok(moved < 0.5,
        ('the ped has covered none of its path when the walk begins (%.2fm)')
            :format(moved))

    -- AND THE FLIGHT STARTS ON THE SAME CUE, which is what makes "the camera
    -- flight and the walk should finish together" a property of two equal
    -- durations rather than of luck.
    local _, firstGlide = firstOf('camglide')
    ok(firstGlide ~= nil and firstTask ~= nil
        and math.abs(firstGlide.at - firstTask.at) <= 100,
        ('the camera flight starts on the same cue as the walk (%sms apart)')
            :format(firstGlide and firstTask
                and tostring(firstGlide.at - firstTask.at) or '?'))
end

-- ...AND A COVER THAT NEVER LIFTS COSTS A WALK THAT STARTS ANYWAY.
--
-- Every wait in this file is bounded and this is no exception: a page that has
-- crashed with the curtain up, or a fade that never lands, must cost a walk
-- that begins in the open -- never an entrance that never happens, which is the
-- failure the owner reported in the first place wearing different clothes.
do
    reset()
    wearChosenModel()
    pump(70000)

    BR.State.me.state = BR.PlayerState.ALIVE
    ped.x, ped.y = 1500.0, 2500.0
    pump(500)
    BR.State.me.state = BR.PlayerState.LOBBY

    order = {}
    BR.Spawn.toLobby(false)
    pump(200)
    -- The curtain goes up and is never taken down again.
    BR.Spawn.curtainWanted = true
    pump(BR.Config.Match.lobbyEntrance.revealWaitMs + 5000)

    ok(firstOf('task') ~= nil,
        'a curtain that never lifts costs a walk that starts anyway')
    BR.Spawn.curtainWanted = false
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 17c. THE EMOTES, ON FIVE DIFFERENT CLOCKS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- All five are the owner's, 2026-08-29, and what makes them worth a suite
-- rather than a playtest is that four of the five are ORDERINGS -- when the
-- gesture happens relative to something else -- and the fifth is a conflict
-- rule between two of them. None of that is visible in a screenshot.

--- Every animation of one entrance, in order.
local function anims()
    local out = {}
    for _, e in ipairs(order) do
        if e.kind == 'anim' then out[#out + 1] = e end
    end
    return out
end

--- Every go-to-coord task of one entrance, in order.
local function taskList()
    local out = {}
    for _, e in ipairs(order) do
        if e.kind == 'task' then out[#out + 1] = e end
    end
    return out
end

-- (d) THE WAVE, CUED BY THE CAMERA AND PLAYED OVER THE WALK.
do
    reset()
    wearChosenModel()
    pump(70000)

    local E = BR.Config.Match.lobbyEntrance.emotes
    local got = anims()
    local tasks = taskList()

    local wave = nil
    for _, a in ipairs(got) do
        if a.dict == E.wave.dict and a.clip == E.wave.clip then wave = a end
    end
    ok(wave ~= nil, 'the ped waves when the camera reaches its second-to-last node')

    -- ═══ AND IT PLAYS OVER THE WALK RATHER THAN INSTEAD OF IT ═══
    --
    -- Flags 48 is 16 (upper body only) + 32 (secondary / allow movement), which
    -- is what lets a walking ped wave. Flags 0 here would be a ped that stops
    -- dead in the middle of its entrance to wave at a camera.
    ok(wave ~= nil and wave.flags == 48,
        ('and it is an upper-body secondary animation (flags %s)')
            :format(wave and tostring(wave.flags) or 'nil'))

    -- THE PROOF THAT IT DID NOT STOP THE PED: a leg was still being walked when
    -- it fired, and no task was cleared to make room for it.
    local during = false
    for i = 1, #tasks do
        local nxt = tasks[i + 1]
        if wave and wave.at >= tasks[i].at and (not nxt or wave.at < nxt.at) then
            during = (i < #tasks) or true
        end
    end
    ok(during, 'and it happens mid-walk, with a leg live under it')

    local clearedNear = false
    for _, e in ipairs(order) do
        if e.kind == 'cleartasks' and wave
           and math.abs(e.at - wave.at) < 200 then clearedNear = true end
    end
    ok(not clearedNear, 'and nothing clears the ped task to make room for it')

    -- ONCE. The cue is a latch, not a level, and a flight that crosses it on
    -- every step would otherwise re-task the animation two dozen times.
    local waves = 0
    for _, a in ipairs(got) do
        if a.dict == E.wave.dict and a.clip == E.wave.clip then waves = waves + 1 end
    end
    ok(waves == 1, ('and it plays exactly once (%d)'):format(waves))
end

-- (a) THE WINNER'S FLIP, AND (a) BEATING (d) WHERE THEY MEET.
--
-- ═══ THE OVERLAP HAS TO BE CONSTRUCTED NOW, AND THAT IS WORTH SAYING ═══
--
-- When "If that overlap happens - prefer the flip" was asked for, the flight and
-- the walk were the same length and the camera reached its second-to-last node
-- at about fourteen seconds -- right on top of the flip. Then the camera went
-- thirty percent faster, so it gets there at about eleven seconds and the wave
-- now fires BEFORE the ped starts flipping, every time. The two no longer meet
-- at the authored numbers.
--
-- THE GUARD STILL HAS TO WORK, because the numbers that separated them are two
-- config values the owner tunes by eye and either one can put them back on top
-- of each other. So this block lengthens the flight until the camera's cue
-- lands inside the flip, which is the only arrangement in which the rule has
-- anything to decide. Without this the test passes against a build with no
-- guard at all -- which is exactly what it did until this run.
do
    local Cc = BR.Config.Match.lobbyEntrance
    local realFlight = Cc.camFlightMs
    Cc.camFlightMs = 22000

    reset()
    wearChosenModel()

    -- The verdict screen's own payload is where "did I win" comes from.
    TriggerEvent('br:ui:sendLocal', BR.Nui.SUMMARY, { won = true, placement = 1 })
    BR.LobbyPed.rearm()
    order = {}
    pump(90000)

    local E = BR.Config.Match.lobbyEntrance.emotes
    local tasks = taskList()
    local flip = nil
    for _, a in ipairs(anims()) do
        if a.dict == E.win.dict and a.clip == E.win.clip then flip = a end
    end

    ok(flip ~= nil, 'a winning return flips')

    -- AT THE SECOND-TO-LAST WALK POINT: after the leg that arrives there has
    -- been tasked, and before the final leg is. "then once the animation is
    -- done, they walk to the final point."
    ok(flip ~= nil and #tasks >= 2
        and flip.at > tasks[#tasks - 1].at and flip.at < tasks[#tasks].at,
        'at the second-to-last walk point, before the final leg is given')

    -- FACING THE CAMERA. "please make sure the flip happens facing the camera"
    -- -- and turning rather than snapping, which is why this is a task and not
    -- a heading write.
    local _, turn = firstOf('turn')
    ok(turn ~= nil and flip ~= nil and turn.at <= flip.at,
        'and the ped turns to face the camera before it starts')

    -- FULL BODY: there is no upper-body backflip, and the walk stopping for it
    -- is the point rather than a side effect.
    ok(flip ~= nil and flip.flags == 0,
        'the flip is full-body -- the walk stops for it')

    -- AND THE WALK REALLY PAUSED. The gap between the second-to-last leg being
    -- tasked and the last one is longer than it takes to walk that leg, by
    -- about the length of the animation. Measured rather than assumed, because
    -- "the animation played" and "the walk waited for it" are different claims
    -- and only the second one is the feature.
    local gap = (#tasks >= 2) and (tasks[#tasks].at - tasks[#tasks - 1].at) or 0
    ok(gap > (E.win.ms or 3200) * 0.5,
        ('and the walk waits for it -- %dms between the last two legs'):format(gap))

    -- ═══ AND THE WAVE LOSES ═══
    --
    -- Owner, 2026-08-29: "If that overlap happens - prefer the flip." The flip
    -- pauses the walk and the flight does not, so with the flight lengthened
    -- above the camera reaches its second-to-last node while the ped is
    -- mid-backflip. The wave is SKIPPED, not queued: there is no later moment
    -- at which it is the right gesture, and firing it as the ped lands from a
    -- flip is the thing he ruled out in as many words.
    local waveBefore, waveAfter = false, false
    for _, a in ipairs(anims()) do
        if a.dict == E.wave.dict and a.clip == E.wave.clip and flip then
            if a.at >= flip.at then waveAfter = true else waveBefore = true end
        end
    end
    ok(not waveBefore,
        'precondition: the camera had not already waved before the flip began')
    ok(not waveAfter, 'and no wave is played during or after it')

    Cc.camFlightMs = realFlight
end

-- (c) READY UP: A THUMBS UP, THEN CLEARPEDTASKS, BEFORE ANY FADE.
do
    reset()
    wearChosenModel()
    -- A DICTIONARY THAT TAKES A MOMENT TO ARRIVE, which is the condition the
    -- pre-streaming exists for. Set before the entrance so the walk streams the
    -- ready-up gesture under the cover, exactly as it does in a real session.
    dictDelayMs = 400
    pump(70000)     -- the entrance, ending parked in the lobby

    local E = BR.Config.Match.lobbyEntrance.emotes
    order = {}
    local pressedAt = fakeTime
    TriggerEvent('br:ui:action', BR.NuiCb.QUEUE, { mode = 'solo' })
    pump(200)

    local _, up = firstOf('anim', function(e)
        return e.dict == E.ready.dict and e.clip == E.ready.clip
    end)
    ok(up ~= nil, 'readying up plays the thumbs up')

    -- ═══ AND IT STARTS IN THE FRAME OF THE PRESS, NOT AFTER A STREAM WAIT ═══
    --
    -- Owner, 2026-08-29: "the thumbs up emote doesn't have enough time to
    -- complete before we fade to black."
    --
    -- HALF OF THAT WAS THE DICTIONARY. The emote used to request its animation
    -- dictionary at the moment of the press, inside a bounded wait of up to two
    -- seconds -- so the FIRST ready-up of a session spent part of its window
    -- streaming rather than playing. Every playtest is a fresh session and the
    -- first ready-up is the one that gets watched. It is streamed during the
    -- entrance now, under the cover, where waiting is free.
    --
    -- ASSERTED AS ELAPSED TIME AGAINST A DICTIONARY THAT TAKES 400ms, because
    -- "the animation played" is true of the late version too -- just later. One
    -- tick is the thread the handler starts; anything approaching the stream
    -- delay means it is paying for the dictionary out of its own window.
    ok(up ~= nil and (up.at - pressedAt) <= 50,
        ('and it starts on the press rather than after a stream wait (%sms '
            .. 'late, against a 400ms dictionary)')
            :format(up and tostring(up.at - pressedAt) or '?'))
    ok(up ~= nil and up.ms == (E.ready.ms + E.ready.holdMs),
        ('and it is asked for its full ms + holdMs window (%s of %d)')
            :format(up and tostring(up.ms) or 'nil',
                    E.ready.ms + E.ready.holdMs))

    pump(2000)
    local _, cleared = firstOf('cleartasks')
    ok(cleared ~= nil and up ~= nil
        and cleared.at - up.at >= (E.ready.ms + E.ready.holdMs),
        'and with nobody readying it, the tasks are cleared when it is done')

    -- ═══ AND ON A REAL READY-UP, THE COVER IS WHAT ENDS IT ═══
    --
    -- Both of his constraints are live at once here and they pull opposite
    -- ways: "play 'thumbs up 3' for 600ms" (and, later, 500ms more) against
    -- "make sure clearpedtasks runs before fade to black if they are accepted
    -- to warmup". A ped that fades out mid-emote and arrives in warmup still
    -- playing it is the failure he named first.
    --
    -- THE STATE EDGE USED TO SETTLE IT BY CUTTING THE GESTURE, which is what he
    -- then reported: the server names the player a participant a round trip
    -- after the press, and the gesture died there with a sixth of its window
    -- spent. What settles it now is the page saying the screen is genuinely
    -- black -- so the gesture runs until the cover, and the cover is by
    -- definition the last moment at which clearing is still invisible.
    --
    -- ACCEPTED IMMEDIATELY, which is the worst case: a local server answers in
    -- single-digit milliseconds, so nothing but the cover is holding the
    -- gesture up.
    reset()
    wearChosenModel()
    pump(70000)

    order = {}
    local pressed2 = fakeTime
    TriggerEvent('br:ui:action', BR.NuiCb.QUEUE, { mode = 'solo' })
    pump(100)                                   -- mid-emote, deliberately
    ok(ped.anim ~= nil, 'precondition: the emote is on the ped')

    BR.State.me.state = BR.PlayerState.WARMUP   -- the server names me at once
    pump(200)
    ok(ped.anim ~= nil,
        'the state edge alone no longer cuts the gesture short')

    -- The gather tick takes the trip from here, exactly as it does in game.
    pump(20000)
    ok(BR.LobbyPed.isNetworked(), 'the trip to warmup ran')

    local _, cleared2 = firstOf('cleartasks')
    local _, covered = firstOf('covered')
    ok(cleared2 ~= nil, 'the ped task really was cleared on this road')

    -- THE ORDERING, AGAINST THE COVER RATHER THAN THE ENGINE FADE. The fade is
    -- not what the player sees go dark: client/state.lua raises br_ui's opaque
    -- curtain on the same edge, ~100ms before BR.Spawn.toWarmupPad is even
    -- reached, so the engine fade happens underneath something already black.
    -- The cover landing is the moment the screen is actually dark, and it is
    -- the one this has to beat.
    ok(cleared2 ~= nil and covered ~= nil and cleared2.at <= covered.at,
        ('and it was cleared no later than the screen going black (%dms before)')
            :format((covered and cleared2) and (covered.at - cleared2.at) or -1))

    -- AND IT GOT MEANINGFULLY MORE THAN THE ROUND TRIP. Four times what the
    -- state-edge clear left it, and more than the 600ms he first asked for --
    -- the rest of the 1100 needs the curtain to wait, which is not this file.
    ok(cleared2 ~= nil and (cleared2.at - pressed2) >= 500,
        ('and the gesture ran for %dms rather than a round trip')
            :format(cleared2 and (cleared2.at - pressed2) or -1))

    -- ═══ AND THE COVER ENDS IT EVEN WHEN NOTHING ELSE WILL ═══
    --
    -- ON THE ORDINARY ROAD BR.LobbyPed.stop('readied up') ALSO CLEARS, and it
    -- runs the moment BR.Spawn.toWarmupPad's awaitCover returns -- which is the
    -- cover landing. So on that road the two agree and either would do.
    --
    -- THEY DO NOT AGREE WHEN THE TRIP IS REFUSED. toWarmupPad returns false
    -- while another trip is still in flight -- a walk home that has not finished
    -- when the player readies up again -- and then nothing calls stop() at all.
    -- The gesture would run its full window with the screen already black behind
    -- it, and the ped would carry it into warmup: the failure the owner named
    -- first, arrived at from the one direction the happy path cannot show.
    reset()
    wearChosenModel()
    pump(70000)

    order = {}
    TriggerEvent('br:ui:action', BR.NuiCb.QUEUE, { mode = 'solo' })
    pump(100)
    ok(ped.anim ~= nil, 'precondition: the gesture is on the ped')

    -- A trip home still finishing, so the gather tick's toWarmupPad refuses.
    BR.Spawn.traveling = true
    BR.State.me.state = BR.PlayerState.WARMUP
    pump(300)
    ok(ped.anim ~= nil,
        'precondition: with the trip refused, nothing has cleared it yet')

    -- client/state.lua raises the curtain on that same state edge and br_ui
    -- reports when it is opaque. That file is not loaded here, so the report is
    -- made directly -- it is the page's message either way.
    TriggerEvent('br:ui:covered', 'curtain', true)
    pump(200)

    ok(ped.anim == nil,
        'the screen going black ends the gesture even when no trip clears it')

    BR.Spawn.traveling = false
end

-- (b) PARKED FOR THIRTY SECONDS: ONE STRETCH, AND ONLY ONE.
do
    reset()
    wearChosenModel()
    -- JUST LONG ENOUGH TO PARK, and no longer: the thirty seconds is measured
    -- from the ped reaching the mark, so a test that pumped a minute first
    -- would have watched the stretch happen before it started looking.
    pump(25000)
    ok(not BR.LobbyPed.entering(), 'precondition: the entrance is over and parked')

    local E = BR.Config.Match.lobbyEntrance.emotes
    order = {}
    pump(E.idle.afterMs - 10000)
    ok(firstOf('anim', function(e) return e.clip == E.idle.clip end) == nil,
        'the parked ped does not stretch before its thirty seconds are up')

    pump(15000)
    local n = 0
    for _, a in ipairs(anims()) do
        if a.dict == E.idle.dict and a.clip == E.idle.clip then n = n + 1 end
    end
    ok(n == 1, ('and then it stretches, once (%d)'):format(n))

    -- ONCE PER LOBBY VIEW, WHICH IS NOT ONCE PER SESSION. Five more minutes of
    -- standing there is still the same view of the lobby.
    pump(300000)
    n = 0
    for _, a in ipairs(anims()) do
        if a.dict == E.idle.dict and a.clip == E.idle.clip then n = n + 1 end
    end
    ok(n == 1, ('and never again while this lobby view lasts (%d)'):format(n))

    -- ...AND NOT AT ALL WHILE THE LOCKER IS OPEN, because the locker is a shot
    -- of the character being chosen and an emote is the ped leaving that frame.
    reset()
    wearChosenModel()
    pump(25000)
    TriggerEvent('br:ui:focusChanged', 'locker')
    order = {}
    pump(E.idle.afterMs + 10000)
    ok(firstOf('anim', function(e) return e.clip == E.idle.clip end) == nil,
        'a ped in the locker screen does not stretch')
    TriggerEvent('br:ui:focusChanged', 'lobby')
end

-- (e) MY SQUAD HAS READIED AND IS WAITING ON ME.
do
    reset()
    wearChosenModel()
    pump(70000)

    local E = BR.Config.Match.lobbyEntrance.emotes
    local function isWait(a)
        for _, w in ipairs(E.waiting.clips) do
            if a.dict == w.dict and a.clip == w.clip then return true end
        end
        return false
    end

    -- A party of three: the other two have queued and I have not.
    BR.State.party = { members = { { src = 1 }, { src = 2 }, { src = 3 } } }
    order = {}
    TriggerEvent(BR.Net.LOBBY_STATUS, { ids = { 2, 3 }, queued = 2, needed = 16 })
    pump(500)

    local waiting = nil
    for _, a in ipairs(anims()) do if isWait(a) then waiting = a end end
    ok(waiting ~= nil, 'a ped whose squad is waiting on them plays a wait emote')

    -- ...AND STOPS WHEN THEY STOP WAITING. It describes something that is true
    -- right now; a squad that dissolved is not still waiting.
    order = {}
    TriggerEvent(BR.Net.LOBBY_STATUS, { ids = {}, queued = 0, needed = 16 })
    pump(500)
    ok(firstOf('cleartasks') ~= nil,
        'and it comes off the ped when they stop')

    -- NOT IN SOLOS. "If they are in squads" -- a party of one is not a squad
    -- and has nobody to be held up by.
    reset()
    wearChosenModel()
    pump(70000)
    BR.State.party = { members = { { src = 1 } } }
    order = {}
    TriggerEvent(BR.Net.LOBBY_STATUS, { ids = {}, queued = 0, needed = 16 })
    pump(1000)
    local solo = false
    for _, a in ipairs(anims()) do if isWait(a) then solo = true end end
    ok(not solo, 'a solo player never plays one')

    -- AND NOT WHEN I HAVE ALREADY QUEUED, because then nobody is waiting on me.
    reset()
    wearChosenModel()
    pump(70000)
    BR.State.party = { members = { { src = 1 }, { src = 2 } } }
    order = {}
    TriggerEvent(BR.Net.LOBBY_STATUS, { ids = { 1, 2 }, queued = 2, needed = 16 })
    pump(1000)
    local mine = false
    for _, a in ipairs(anims()) do if isWait(a) then mine = true end end
    ok(not mine, 'nor when they have queued themselves')
    BR.State.party = nil
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 17d. THE FAILSAFE IS THE CAMERA'S CLOCK, AND THE FLIP DOES NOT COUNT
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29: "if the ped doesn't get to the destination within 5
-- seconds of the camera parking we fire that function and bring them to the
-- position ourselves."

do
    -- ═══ A PED THAT CANNOT KEEP UP ═══
    --
    -- `walkMps` is what the plan BELIEVES the ped covers per second, and the
    -- shape of the real failure is that belief being wrong -- so that is the
    -- knob this turns, rather than a stub that refuses to move.
    --
    -- THE BLEND FLOOR HAS TO COME DOWN WITH IT, and that is new. On the old
    -- 41-59m paths, telling the plan five metres a second was enough on its own:
    -- the blends clamped to 1.0, the ped walked at its real 1.4 and arrived
    -- nearly a dozen seconds late. This path is 30.8m, so even at the floor the
    -- ped gets there in about seventeen seconds and is not late at all -- the
    -- test would have passed for the wrong reason, or rather failed for the
    -- right one. Dropping the floor lets the solved blend go below a walk, which
    -- is what actually makes the ped slow rather than merely making the plan
    -- optimistic.
    local C = BR.Config.Match.lobbyEntrance
    local realMps, realMin = C.walkMps, C.walkBlendMin
    C.walkMps = 5.0
    C.walkBlendMin = 0.2

    reset()
    wearChosenModel()
    pump(70000)

    ok(forcedHome(), 'a ped that is still walking when the grace runs out is placed')
    ok(math.abs(ped.x - BR.Config.Match.lobbyPos.x) < 0.01
        and math.abs(ped.y - BR.Config.Match.lobbyPos.y) < 0.01,
        'and it ends on the mark rather than wherever it had got to')
    ok(not BR.LobbyPed.entering() and not BR.LobbyPed.lockerLocked(),
        'and the entrance ends properly rather than being abandoned')

    C.walkMps, C.walkBlendMin = realMps, realMin
end

-- ...AND IT DOES NOT FIRE DURING THE FLIP.
--
-- THE INTERACTION THAT MAKES THIS WORTH A TEST: the flip PAUSES the walk, on
-- purpose, and a grace anchored to the camera parking would otherwise fire in
-- the middle of it on every single win -- teleporting the player out of their
-- own victory animation, which is the worst possible thing this failsafe could
-- ever do. The clock does not start until the animation is over.
--
-- THE FLIP IS LENGTHENED HERE rather than the grace shortened, because the
-- thing being tested is a flip that OUTLASTS the grace. At the authored lengths
-- it does not, and a test that passed only because the numbers happened not to
-- overlap would go green against the broken version too.
do
    local E = BR.Config.Match.lobbyEntrance.emotes
    local realMs = E.win.ms
    E.win.ms = 12000

    reset()
    wearChosenModel()
    TriggerEvent('br:ui:sendLocal', BR.Nui.SUMMARY, { won = true, placement = 1 })
    BR.LobbyPed.rearm()
    logged = {}
    order = {}
    pump(90000)

    local flip = nil
    for _, a in ipairs(anims()) do
        if a.dict == E.win.dict and a.clip == E.win.clip then flip = a end
    end
    ok(flip ~= nil, 'precondition: a flip that outlasts the grace was played')

    ok(not forcedHome(),
        'the failsafe does not fire while the ped is deliberately paused for it')

    -- AND THE PED STILL WALKED THE LAST LEG under its own power afterwards --
    -- the placement at the end moves it a distance nobody can see, which is
    -- what a walked arrival looks like and what a forced one does not.
    local p = BR.Config.Match.lobbyPos
    local landing = nil
    for _, e in ipairs(order) do
        if e.kind == 'coords' and e.at > 2000
           and math.abs(e.x - p.x) < 0.01 and math.abs(e.y - p.y) < 0.01 then
            landing = e break
        end
    end
    ok(landing ~= nil and landing.jump <= 0.30,
        ('and it walks the final leg after the flip rather than being placed '
            .. '(%.2fm)'):format(landing and landing.jump or -1.0))

    E.win.ms = realMs
end

-- AND A DICTIONARY THAT NEVER STREAMS COSTS ITS GESTURE AND NOTHING ELSE.
--
-- Same trade as the walking clipset: bounded, and the walk finishes either way.
-- An emote that could hang the entrance would be a far worse bug than a ped
-- that does not wave.
do
    reset()
    wearChosenModel()
    dictsStream = false
    pump(70000)

    ok(#anims() == 0, 'no emote plays when its dictionary never streams')
    ok(math.abs(ped.x - BR.Config.Match.lobbyPos.x) < 0.01,
        'and the ped still walks the whole way to the mark')
    dictsStream = true
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 18. THE DEPARTURE: BLACK, THEN THE FOCUS, THEN A SECOND, THEN THE PED
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29: "when the lobby fades to black, before fading in, we need
-- to move the focus to the selected warmup spawn area for at least 1 second
-- before moving the ped, then we fade in once the ped is there."
--
-- FIVE CLAIMS, AND EVERY ONE OF THEM IS AN ORDERING OR AN ELAPSED TIME. A
-- screenshot cannot see any of them and a playtest can only see the last one,
-- so they are asserted here off the ordered native log and the stepped clock:
-- black BEFORE the focus, the focus BEFORE the ped, at least a second BETWEEN
-- those two, the fade-in AFTER the ped is there, and -- unchanged and asserted
-- again from this side -- the networked flip AFTER the ped move.
--
-- THE FADE-OUT IS WRAPPED HERE rather than in the stub block at the top,
-- because the ordering it belongs to is this one and nothing above needs it.

local realFadeOut = DoScreenFadeOut
DoScreenFadeOut = function(...)
    note('fadeout')
    return realFadeOut(...)
end

-- ═══ ONE TRIP PER BLOCK, AND THIS IS WHAT MAKES THAT TRUE ═══
--
-- spawn.gather re-arms on MY STATE, not on having tried: the moment a trip
-- clears `traveling` it starts another one, because the state it watches still
-- reads WARMUP. That is right in the game and ruinous here -- "the focus was
-- handed back" would be answered by trip #2 having just taken it, and "nothing
-- is left holding it" would depend on where the pump happened to stop.
--
-- The blocks below drive BR.Spawn.toWarmupPad directly, so the loop has nothing
-- to contribute to them. It goes back on at the end of the file.
ok(BR.Loop.setEnabled('spawn.gather', false),
    'spawn.gather can be held off while the departure is driven by hand')

do
    reset()
    wearChosenModel()
    pump(3000)

    order = {}
    BR.State.me.state = BR.PlayerState.WARMUP
    ok(BR.Spawn.toWarmupPad(), 'the trip starts')
    -- SHORTER THAN departure.focusMaxMs ON PURPOSE: the safety net at the end
    -- of that window also hands the focus back, so a test that ran past it would
    -- pass whether landed() released the focus or not.
    pump(12000)

    local iBlack = firstOf('fadeout')
    local iFocus, focus = firstOf('focus')
    local iPed, pedMove = firstOf('resurrect')
    local iNet = firstOf('networked', function(e) return e.on end)
    local iIn = firstOf('fadein')

    ok(iBlack ~= nil, 'the departure fades the world to black')
    ok(iFocus ~= nil, 'and moves the streaming focus')
    ok(iPed ~= nil, 'and moves the ped')

    -- 1. BLACK FIRST.
    ok(iBlack ~= nil and iFocus ~= nil and iBlack < iFocus,
        ('the world goes black BEFORE the focus moves (black #%s, focus #%s)')
            :format(tostring(iBlack), tostring(iFocus)))

    -- 2. THE FOCUS IS THE SELECTED SPAWN, not the pad and not the camera node.
    --    The ped ends up where the focus went, which is the only way to say
    --    "the SELECTED warmup spawn area" about a spot chosen at random.
    ok(focus ~= nil and isWarmupSpawn(focus.x, focus.y),
        'the focus is put on one of the authored warmup spawns')
    ok(focus ~= nil and pedMove ~= nil
        and math.abs(focus.x - pedMove.x) < 0.01
        and math.abs(focus.y - pedMove.y) < 0.01,
        'and on the SAME spawn the ped is then moved to')

    -- 3. THE FOCUS LEADS THE PED, AND BY AT LEAST THE CONFIGURED SECOND.
    ok(iFocus ~= nil and iPed ~= nil and iFocus < iPed,
        ('the focus moves BEFORE the ped (focus #%s, ped #%s)')
            :format(tostring(iFocus), tostring(iPed)))

    local held = (focus and pedMove) and (pedMove.at - focus.at) or -1
    ok(held >= BR.Spawn.departure.focusHoldMs,
        ('and is held there for at least the configured %dms before the ped '
            .. 'moves (%dms)'):format(BR.Spawn.departure.focusHoldMs, held))

    -- 4. AND THE LIGHT COMES BACK LAST, once the ped is genuinely there.
    ok(iIn ~= nil and iPed ~= nil and iPed < iIn,
        ('the screen fades back in AFTER the ped has moved (ped #%s, in #%s)')
            :format(tostring(iPed), tostring(iIn)))

    -- 5. AND THE ONE ORDERING THE FOCUS STEP MUST NOT HAVE DISTURBED.
    --
    -- Section 9 asserts this off the coordinate write; this asserts it off the
    -- resurrection, which is the FIRST thing that moves the body and therefore
    -- the earliest point a flip could have been made too early. The new step
    -- goes in front of the teleport, never in front of the flip.
    ok(iNet ~= nil and iPed ~= nil and iPed < iNet,
        ('the ped is moved BEFORE it is networked (ped #%s, networked #%s)')
            :format(tostring(iPed), tostring(iNet)))
    ok(iFocus ~= nil and iNet ~= nil and iFocus < iNet,
        'and the focus step is in front of the flip as well, not between')

    -- AND IT IS GIVEN BACK ON THE HAPPY PATH.
    local iBack = firstOf('focusback')
    ok(iBack ~= nil, 'the streaming focus is handed back when the trip lands')
    ok(iBack ~= nil and iPed ~= nil and iPed < iBack,
        'after the placement, not before it -- the pad is what we were streaming')
    ok(not BR.Spawn.focusHeld(), 'and the trip is not still holding it')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 18b. THE BLACK DOES NOT WAIT FOR THE PAGE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29: "occasionally I'll press ready up and the lobby UI doesn't
-- go away and we don't fade to black on time. The ped transports to the warmup
-- area, and the NUI only transitions when the inventory/HUD UI shows up."
--
-- The world fade used to sit BELOW the cover handshake, so a page that never
-- acknowledged the curtain delayed the ONE thing that can black the world out
-- unconditionally -- by coverWaitMs, every time. This is that case: the page
-- says nothing at all, and the world must still be dark within its own fade.
--
-- Every other block here has the curtain acknowledged the instant it is raised
-- (see the stub at the top), which is exactly why this one has to take it away.

do
    reset()
    wearChosenModel()
    pump(3000)

    -- A FRESH PAGE HAS PAINTED NOTHING, so nothing is covered -- the same event
    -- br_ui fires on a new document, and the only way to clear the mirror that
    -- previous blocks in this file have left reading "black".
    TriggerEvent('br:ui:ready')

    -- ...and now it never answers.
    local savedSend = handlers['br:ui:sendLocal']
    handlers['br:ui:sendLocal'] = {}

    order = {}
    BR.State.me.state = BR.PlayerState.WARMUP
    ok(BR.Spawn.toWarmupPad(), 'the trip starts with a page that never answers')

    -- Comfortably inside coverWaitMs, so a fade that waited on the handshake
    -- has not happened yet and a fade that did not is already done.
    pump(600)
    ok(firstOf('fadeout') ~= nil,
        ('the world is black without waiting for the page (cover deadline is '
            .. '%dms)'):format(BR.Config.Match.coverWaitMs or 2500))
    ok(firstOf('focus') == nil,
        'but nothing has moved yet -- the cover is still waited for')

    handlers['br:ui:sendLocal'] = savedSend
    pump(30000)
    ok(not BR.Spawn.traveling, 'and the trip still finishes on its deadlines')
    ok(not BR.Spawn.focusHeld(), 'with the focus handed back')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 19. THE FOCUS COMES BACK ON THE ENDINGS THAT ARE NOT THE HAPPY ONE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- A client left focused on a pad it never reached does not error and does not
-- log. It presents, much later and somewhere else, as world geometry refusing
-- to load around the player, with nothing pointing back here -- which is why
-- the failure paths get their own block rather than a line in the one above.

do
    -- ═══ THE PLACEMENT NEVER REPORTS BACK ═══
    --
    -- placeAt refuses to start while another placement is running, so the
    -- landing callback never fires and the 9s escape is the only ending. It
    -- calls landed(), so the focus comes back on that road too.
    reset()
    wearChosenModel()
    pump(3000)

    -- Wedge a placement open: BR.Spawn.placeAt is serialised on a file-local
    -- `placing`, and the way to set it from out here is to start a placement
    -- whose collision wait we then never let finish.
    --
    -- ON THE LOBBY MARK, NOT AN ARBITRARY COORDINATE: spawn.lobbywatch sends a
    -- LOBBY player standing more than 150m from the vista straight home, and a
    -- trip home is itself a trip -- so wedging the placement anywhere else
    -- starts the very thing this block is trying to keep out of the way.
    local realCollision = HasCollisionLoadedAroundEntity
    HasCollisionLoadedAroundEntity = function() return 0 end
    local home = BR.Config.Match.lobbyPos
    BR.Spawn.placeAt(home.x, home.y, home.z, home.heading)
    pump(100)

    order = {}
    BR.State.me.state = BR.PlayerState.WARMUP
    ok(BR.Spawn.toWarmupPad(), 'the trip starts with a placement already running')
    -- Inside departure.focusMaxMs, so the 9s escape is the only thing that can
    -- be handing the focus back here.
    pump(12000)

    local escaped = false
    for _, line in ipairs(logged) do
        if line:find('did not report back', 1, true) then escaped = true end
    end

    ok(firstOf('focus') ~= nil, 'the focus is still taken')
    ok(escaped,
        'precondition: the placement was refused and the 9s escape is the ending')
    ok(firstOf('focusback') ~= nil,
        'and the escape hands the streaming focus back anyway')
    ok(not BR.Spawn.focusHeld(), 'nothing is left holding it')
    ok(firstOf('networked', function(e) return e.on end) ~= nil,
        'and the escape still leaves the ped networked rather than invisible')

    HasCollisionLoadedAroundEntity = realCollision
end

do
    -- ═══ THE TRIP IS ABANDONED BETWEEN THE FOCUS AND THE LANDING ═══
    --
    -- The case landed() cannot cover: a bare Citizen thread that throws simply
    -- stops. Modelled by taking the focus and then clearing `traveling` out
    -- from under it, which is exactly the state such a thread would leave --
    -- held, with nothing left running that would give it back.
    reset()
    wearChosenModel()
    pump(3000)

    order = {}
    BR.State.me.state = BR.PlayerState.WARMUP
    BR.Spawn.toWarmupPad()
    -- INSIDE the focus hold, not past it: this block needs to catch the trip
    -- while it still has the focus.
    --
    -- IT WAS 600ms UNTIL THE FIXTURE LEARNED THAT A CURTAIN TAKES TIME. The
    -- cover used to be acknowledged in the frame it was asked for, so the trip
    -- reached its focus almost at once; br_ui's curtain really takes its own
    -- 600ms to reach opaque, and awaitCover blocks on it. So the focus is now
    -- taken around 950ms in and held for focusHoldMs after that, and 600 landed
    -- before it rather than inside it. The assertion is unchanged -- only the
    -- moment it has to be made at.
    pump(1200)

    ok(BR.Spawn.focusHeld(), 'precondition: the trip is holding the focus')

    threads = {}                     -- the thread dies where it stands
    BR.Spawn.traveling = false

    order = {}
    BR.Loop.step(BR.Loop.SLOW)

    ok(firstOf('focusback') ~= nil,
        'the watchdog hands back a focus that outlived its trip')
    ok(not BR.Spawn.focusHeld(), 'and it is not held afterwards')

    order = {}
    BR.Loop.step(BR.Loop.SLOW)
    ok(firstOf('focusback') == nil,
        'and it does not keep handing back a focus nobody holds')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 20. THE DEPARTURE'S NUMBERS ARE NUMBERS, IN ONE PLACE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- The owner tunes the hold himself and cannot read Lua, so it has to be a named
-- value in a table rather than a literal somewhere in the middle of a thread.

do
    local D = BR.Spawn.departure
    ok(type(D) == 'table', 'the departure has a tunable table')
    for _, k in ipairs({ 'focusHoldMs', 'focusMaxMs' }) do
        ok(type(D[k]) == 'number', ('departure.%s is tunable'):format(k))
    end
    ok(D.focusHoldMs >= 1000,
        ('the focus hold is at least the second the owner asked for (%dms)')
            :format(D.focusHoldMs or -1))

    -- The net has to outlast the trip it is a net for, or it would fire on
    -- healthy departures and take the focus off the pad mid-placement.
    ok(D.focusMaxMs > D.focusHoldMs + 9000,
        ('the focus net outlasts the hold plus the 9s placement escape (%dms)')
            :format(D.focusMaxMs or -1))
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 21. THE FIRST LOAD: THE WALK STARTS AT THE START MARK, NOT AT THE LOBBY MARK
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-31: "the first time the client loads in the ped walks to the
-- points in reverse before turning around and walking the correct way ... Every
-- time back to the lobby afterwards is fine, tested dozens of cycles."
--
-- THE PATH IS NOT REVERSED AND THIS BLOCK IS NOT ABOUT THE PATH. A reversed
-- path would finish up the hill; his finishes on the mark. What he is watching
-- is a ped that began the walk standing on the LOBBY MARK: its first leg is then
-- the nineteen metres back up to pedPath[1], which passes 1.5m from the third
-- corner and 3.9m from the second -- the points, in reverse -- and it turns
-- around at the top and walks the authored path correctly from there.
--
-- ═══ WHAT THE FIXTURE MODELS, AND WHY IT IS ONLY THE FIRST LOAD ═══
--
-- The entrance places the ped in begin(), in the trip's own frame, and then
-- WAITS: for the character model, for the clipset, for the emote dictionaries,
-- and for the cover to lift. On every road but the first that window is empty --
-- the character is applied once per session (client/locker.lua) so the model
-- wait does not wait, and the player is already alive and already spawned so
-- BR.Spawn.respawn's resurrect has nothing left to do. On the FIRST load both
-- are false at once, and BR.Spawn.toLobby runs `respawn(lobbyPos, exact)` and
-- BR.LobbyPed.startNow with no Citizen.Wait between them.
--
-- SO THE TWO FACTS MODELLED HERE ARE THE TWO THAT ARE TRUE EXACTLY ONCE: the
-- character is not on the player yet (so the model wait genuinely waits, and
-- ends on a NEW ped handle, which is what it was waiting for), and the spawn
-- that put the player on the lobby mark settles onto its coordinates a frame
-- after it was asked to rather than inside the call. Which engine call wins that
-- race -- the resurrect completing, or the SwitchInPlayer that BR.Spawn.reveal
-- makes on a player it says GTA "can leave mid-switch" -- is not knowable from
-- Lua and is not what is asserted. WHAT IS ASSERTED IS THE CONTRACT: if anything
-- writes the ped's position while the entrance is standing it on its mark under
-- the cover, the walk still begins at the start mark.

--- Whether the fixture's spawn lands a frame late, as an unspawned one does.
local settleLate = false
do
    local real = NetworkResurrectLocalPlayer
    NetworkResurrectLocalPlayer = function(x, y, z, h, ...)
        real(x, y, z, h, ...)
        if not settleLate then return end
        -- ONE STEP OF THE CLOCK, which is this fixture's frame. Cfx's own
        -- spawnmanager freezes the player across exactly this gap and waits it
        -- out before unfreezing; br_core does not, because on every road it was
        -- written for there is nothing to wait for.
        Citizen.SetTimeout(50, function()
            SetEntityCoordsNoOffset(PlayerPedId(), x, y, z, false, false, false)
            SetEntityHeading(PlayerPedId(), h or 0.0)
        end)
    end
end

do
    local C = BR.Config.Match.lobbyEntrance
    local L = BR.Config.Match.lobbyPos

    reset()
    -- A FRESH CONNECT: no character on the player, no spawn yet, loading screen
    -- still up. The lobby watchdog in client/spawn.lua is what takes us home
    -- from here, exactly as it does on a real join.
    ped.model = 0
    ped.x, ped.y, ped.z = 0.0, 0.0, 0.0
    BR.State.worldReady = false
    settleLate = true

    -- The character arrives three seconds in, on a NEW handle -- which is what
    -- SetPlayerModel hands back and what the entrance's model wait is waiting
    -- for. Late enough to be a wait, early enough to be well inside modelWaitMs.
    Citizen.SetTimeout(3000, function()
        pedHandle = pedHandle + 1
        wearChosenModel()
    end)

    pump(200)

    -- THE PRECONDITION IS THE BUG, and it is asserted rather than assumed: a
    -- fixture that quietly failed to move the ped would make everything below
    -- pass on any build at all.
    ok(BR.LobbyPed.entering(), 'precondition: the first load starts an entrance')
    ok(BR.Dist(ped.x, ped.y, L.x, L.y) < 1.0,
       'precondition: the settling spawn has put the ped back on the lobby mark')
    ok(not BR.LobbyPed.walking(),
       'precondition: and the walk has not started -- it is waiting for the model')

    pump(6000)                     -- the character lands; the waits run out
    BR.State.worldReady = true     -- client/loading.lua reveals
    pump(40000)

    local tasks = {}
    for _, e in ipairs(order) do
        if e.kind == 'task' then tasks[#tasks + 1] = e end
    end

    ok(#tasks == #C.pedPath + 1,
       ('the whole path is walked -- %d legs, one per corner plus the mark (saw %d)')
           :format(#C.pedPath + 1, #tasks))

    -- THE ASSERTION THE REPORT IS ABOUT. Measured on where the ped WAS when the
    -- first leg was tasked, which is the only number that can tell the two ends
    -- apart: the start mark and the lobby mark are 22m apart.
    ok(#tasks > 0
       and BR.Dist(tasks[1].fromX, tasks[1].fromY, C.pedStart.x, C.pedStart.y) < 1.0,
       'the first leg is walked FROM the start mark')
    ok(#tasks > 0
       and BR.Dist(tasks[1].fromX, tasks[1].fromY, L.x, L.y) > 10.0,
       'and not from the lobby mark, nineteen metres back down the path')

    -- AND THE PATH ITSELF IS STILL THE RIGHT WAY ROUND, which is the other way
    -- this report could have been answered and the wrong one. A build that
    -- "fixed" the direction by reversing the legs would satisfy the two above
    -- and fail this.
    ok(#tasks > 0 and math.abs(tasks[1].x - C.pedPath[1].x) < 0.01
       and math.abs(tasks[1].y - C.pedPath[1].y) < 0.01,
       'the first leg still goes to the first authored corner')
    ok(#tasks > 0 and math.abs(tasks[#tasks].x - L.x) < 0.01
       and math.abs(tasks[#tasks].y - L.y) < 0.01,
       'and the last one still ends on the lobby mark')

    -- IT IS AN ENTRANCE, NOT A RESCUE. The failsafe places a ped that is late,
    -- and a walk that starts nineteen metres out is late by about eleven
    -- seconds -- so a build with the bug in it ends the owner's first lobby with
    -- a teleport as well as a reversal.
    ok(not forcedHome(),
       'the failsafe never has to place a ped that started at the wrong end')
    ok(math.abs(ped.x - L.x) < 0.01 and math.abs(ped.y - L.y) < 0.01,
       'and the first load ends with the ped on the lobby mark like every other')

    settleLate = false
    BR.State.worldReady = true
end

-- And the gather loop goes back on, so nothing added after this inherits a
-- disabled subsystem from a block that only wanted it quiet for itself.
ok(BR.Loop.setEnabled('spawn.gather', true), 'spawn.gather is left enabled')

-- ------------------------------------------------------------------ report ---

if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m, %d passed'):format(fail, pass))
    os.exit(1)
end
realPrint(('\27[32mok\27[0m   %d assertions: the lobby entrance walks, abandons '
    .. 'cleanly, and the ped is teleported before it is networked'):format(pass))
