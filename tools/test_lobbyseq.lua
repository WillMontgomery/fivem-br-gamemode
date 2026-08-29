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
    note('task', {
        x = x, y = y, z = z, speed = speed, heading = heading,
        fromX = ped.x, fromY = ped.y,
    })
end
function ClearPedTasks() ped.dest = nil note('cleartasks') end
function ClearPedTasksImmediately() ped.dest = nil end
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

-- The screen.
local fadedOut, fadedIn = false, true
function DoScreenFadeOut() fadedOut = true fadedIn = false end
-- NOTED, BECAUSE IT IS A DEADLINE. The entrance's first act is a teleport
-- thirty metres up the path, and on the trip home the only cover it has is the
-- black this call ends -- so "the ped was placed before the fade" is an
-- ORDERING, and orderings are what this suite exists to assert.
function DoScreenFadeIn() fadedOut = false fadedIn = true note('fadein') end
function IsScreenFadedOut() return fadedOut and 1 or 0 end
function IsScreenFadedIn() return fadedIn and 1 or 0 end
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
    interpUntil[dest] = fakeTime + (ms or 0)
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

-- The curtain is acknowledged immediately: awaitCover's timeout is a real
-- 2500ms and every test here would otherwise spend it.
AddEventHandler('br:ui:sendLocal', function(kind, d)
    if kind == BR.Nui.LEAVING and d and d.show then
        TriggerEvent('br:ui:covered', 'curtain', true)
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
    ped.x, ped.y, ped.z = BR.Config.Match.lobbyPos.x, BR.Config.Match.lobbyPos.y,
                          BR.Config.Match.lobbyPos.z
    ped.dest, ped.clipset, ped.frozen = nil, nil, true
    ped.male = true
    clipsetStreams = true
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
    ok(#BR.Config.Match.warmupSpawns == 5, 'five warmup spawns are authored')
    ok(BR.Config.Match.warmupSpawns[1].x == 4498.92
       and BR.Config.Match.warmupSpawns[5].heading == 261.1,
       'the warmup spawns are the surveyed numbers')

    -- THE CLIPSETS, AND THE TRAILING @. `anim@move_m@grooving` without it is a
    -- different string that RequestAnimSet answers nothing for -- which presents
    -- as a ped that walks normally, not as an error, so nothing else would ever
    -- catch it.
    ok(C.walkClipsetMale == 'anim@move_m@grooving@',
       'the male walk is the stock grooving clipset')
    ok(C.walkClipsetFemale == 'anim@move_f@grooving@',
       'the female walk is the stock grooving clipset')

    ok(C.pedStart.x == 5012.76 and C.pedStart.heading == 315.3,
       'the walk starts on the surveyed mark')
    ok(#C.pedPath == 3, 'three authored corners; the fourth leg is the lobby mark')
    ok(#C.camPath == 3, 'three authored camera nodes; the fourth is the lobby frame')
    ok(C.camPath[1].x == 4919.50 and C.camPath[1].z == 98.80,
       'the first camera node is the one the focus leads to')

    -- EVERY DURATION IS A NUMBER IN CONFIG. The owner offered to tune these, so
    -- a value that migrated into the client is a value he cannot reach.
    for _, k in ipairs({ 'camFlightMs', 'focusLeadMs', 'modelWaitMs',
                         'clipsetWaitMs', 'legTimeoutMs', 'armWaitMs',
                         'arriveRadius', 'cornerRadius', 'markRadius' }) do
        ok(type(C[k]) == 'number', ('lobbyEntrance.%s is tunable'):format(k))
    end

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

    -- ═══ AND THE SPEED IS A LIST NOW, ONE ENTRY PER LEG ═══
    --
    -- Owner, 2026-08-29: "Set walk speed to 2.0 until the first point, 1.5
    -- until the second point, then 1.0 for 3rd -> 4th point." It was a single
    -- number until then, which is why this is not in the loop above.
    ok(type(C.walkSpeeds) == 'table' and #C.walkSpeeds > 0,
        'lobbyEntrance.walkSpeeds is a list rather than one number')

    local allNums = true
    for _, v in ipairs(C.walkSpeeds or {}) do
        if type(v) ~= 'number' then allNums = false end
    end
    ok(allNums, '...and every entry in it is tunable')

    -- THE PED MUST ARRIVE AT A WALK. The last leg is the one the player is
    -- actually looking at -- the camera has landed by then -- so a list that
    -- ended fast would be a run into a dead stop on the mark.
    local last = C.walkSpeeds and C.walkSpeeds[#C.walkSpeeds]
    ok(last == 1.0,
        ('the final leg is walked at 1.0, whatever precedes it (%s)')
            :format(tostring(last)))

    -- AND IT ONLY EVER SLOWS DOWN. The owner's three numbers descend, and a
    -- sequence that sped up mid-path would read as the ped noticing the camera.
    local descends = true
    for i = 2, #(C.walkSpeeds or {}) do
        if C.walkSpeeds[i] > C.walkSpeeds[i - 1] then descends = false end
    end
    ok(descends, 'and the speeds never increase from one leg to the next')

    -- A LIST SHORTER THAN THE PATH IS LEGAL -- lobbyped.lua clamps to the last
    -- entry, which is how the 1.0 covers both the third leg and the walk onto
    -- the mark -- but a list LONGER than the path means somebody tuned a leg
    -- that does not exist, which is a silent no-op and worth catching here.
    --
    -- THE LEG COUNT IS pedPath PLUS ONE: legs() finishes at BR.Config.Match
    -- .lobbyPos, so the last authored corner is not the last thing walked.
    ok(#(C.walkSpeeds or {}) <= #(C.pedPath or {}) + 1,
        ('and there is no speed for a leg the path does not have '
            .. '(%d speeds, %d legs)')
            :format(#(C.walkSpeeds or {}), #(C.pedPath or {}) + 1))
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
    ok(BR.LobbyPed.revealMark() == BR.Config.Match.lobbyEntrance.pedStart,
       'and it is told to expect the ped on the START mark, not the lobby one')

    pump(300)
    ok(BR.LobbyPed.entering(), 'the entrance starts on the lobby tick')

    pump(500)
    local C = BR.Config.Match.lobbyEntrance
    ok(math.abs(ped.x - C.pedStart.x) < 2.0,
       'the ped is placed on the start mark before anything else')
    ok(ped.clipset == 'anim@move_m@grooving@',
       'a male ped is given the male grooving clipset')
    ok(BR.LobbyPed.walking(), 'and then it walks')
    ok(BR.LobbyPed.revealBlock() == nil,
       'once it is walking the loading screen may come down')

    -- The entrance's first shot went up at the authored node, with no
    -- interpolation INTO it -- it is raised under a black screen and there is
    -- nothing to blend from. (The fixed lobby shot the follow tick had already
    -- raised is the camera it replaces.)
    local _, made = firstOf('cammade',
        function(e) return math.abs(e.x - C.camPath[1].x) < 0.01 end)
    ok(made ~= nil, 'a camera is raised at the first authored node')
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
    local homeAt, pedAt
    for _, e in ipairs(order) do
        if e.kind == 'campoint' and e.at > 2000 then homeAt = homeAt or e.at end
    end
    for i = #order, 1, -1 do
        if order[i].kind == 'coords' then pedAt = order[i].at break end
    end
    ok(homeAt ~= nil, 'the camera is aimed at the lobby frame at the end of the flight')
    ok(homeAt ~= nil and pedAt ~= nil and homeAt <= pedAt,
       'the camera starts its landing before the ped arrives')
    ok(arrival ~= nil, 'the arrival re-freezes the ped')

    -- NO CAMERA IS LEFT BEHIND by a flight that ran to completion.
    pump(2000)
    ok(liveCamCount() <= 1,
       ('a completed flight leaves one camera, not %d'):format(liveCamCount()))

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

    local _, f = firstOf('focus')
    ok(f and math.abs(f.x - BR.Config.Match.lobbyEntrance.camPath[1].x) < 0.01
         and math.abs(f.z - BR.Config.Match.lobbyEntrance.camPath[1].z) < 0.01,
       'and it points the streaming focus at the FIRST camera node')

    -- AND IT IS GIVEN BACK ON AN ABANDONMENT, not only on the happy path. A
    -- client left streaming a point three hundred metres up over the ocean
    -- presents, much later and somewhere else, as world geometry that will not
    -- load -- with nothing pointing back here.
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
-- 10. THE SPAWN IS ONE OF THE FIVE, AND NOT ALWAYS THE SAME ONE
-- ═══════════════════════════════════════════════════════════════════════════

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
    ok(n == 5, ('all five warmup spawns are reachable (saw %d)'):format(n))

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

    BR.State.me.state = BR.PlayerState.PLAYING
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
-- 13. ONE SPEED PER LEG, AND READYING UP CANCELS IT
-- ═══════════════════════════════════════════════════════════════════════════

do
    -- Owner, 2026-08-29: "Set walk speed to 2.0 until the first point, 1.5
    -- until the second point, then 1.0 for 3rd -> 4th point. Also remember if
    -- the player readies up fast we need to cancel that walk speed now too."
    reset()
    wearChosenModel()

    local C = BR.Config.Match.lobbyEntrance
    local want = C.walkSpeeds

    -- Run the whole walk out. The legs are timed by the fixture's own clock, so
    -- this has to be long enough for the slowest configuration to finish.
    pump(60000)

    -- EVERY TASK, IN ORDER. `firstOf` answers one; the whole point here is the
    -- SEQUENCE of blend ratios, so they are collected by hand.
    local got = {}
    for _, e in ipairs(order) do
        if e.kind == 'task' then got[#got + 1] = e.speed end
    end

    -- FOUR LEGS, NOT THREE. lobbyped.lua's legs() walks every pedPath corner
    -- and then the lobby mark itself, so the positions the ped arrives at are
    -- the owner's "first / second / 3rd / 4th point" exactly.
    local nLegs = #(C.pedPath or {}) + 1
    ok(#got == nLegs,
        ('the ped is tasked once per leg, the lobby mark included '
            .. '(%d tasks, %d legs)'):format(#got, nLegs))

    local matched = #got > 0
    for i = 1, #got do
        local expect = want[math.min(i, #want)]
        if got[i] ~= expect then matched = false end
    end
    ok(matched,
        ('and each leg is walked at its own speed -- 2.0 in, then 1.5, '
            .. 'arriving at 1.0 -- rather than one number for the whole path '
            .. '(got %s)'):format((function()
                local s = {}
                for i, v in ipairs(got) do s[i] = tostring(v) end
                return table.concat(s, ', ')
            end)()))

    -- THE SPEEDS ARE NOT ALL THE SAME, which is the assertion that fails if
    -- someone collapses the list back to a scalar and the loop above starts
    -- comparing one value against itself.
    local varied = false
    for i = 2, #got do if got[i] ~= got[1] then varied = true end end
    ok(varied, 'and they genuinely differ from one leg to the next')

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
    ok(live == want[1],
        ('precondition: the ped is mid-walk on the opening leg, at its speed '
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
-- 14. THE CAMERA FLIES AT ONE PACE, AND NEVER STOPS ON THE WAY
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-08-29: "The camera movements and the walks should not wait on
-- each other. Right now once the camera reaches each point, there's a pause.
-- That shouldn't happen, it should be smooth movement all the way start to
-- finish with no pace change either."
--
-- THREE SEPARATE THINGS WERE WRONG AND THEY NEED THREE SEPARATE ASSERTIONS.
-- The moves were EASED, so the camera arrived at rest at every node. They were
-- given the SAME DURATION over segments of wildly different lengths, so the
-- pace changed at every node even without the easing. And the last one WAITED
-- on the ped's measured arrival, which is the coupling the owner suspected.

--- The flight's segments, in metres, computed the way the client has to: the
--- last one ends at the lobby FRAME, which is not in camPath.
local function camSegLengths()
    local nodes = BR.Config.Match.lobbyEntrance.camPath
    local out = {}
    for i = 2, #nodes do
        out[#out + 1] = BR.Dist3(nodes[i - 1].x, nodes[i - 1].y, nodes[i - 1].z,
                                 nodes[i].x, nodes[i].y, nodes[i].z)
    end
    local last = nodes[#nodes]
    local hx, hy, hz = BR.LobbyCam.lobbyFrame()
    out[#out + 1] = BR.Dist3(last.x, last.y, last.z, hx, hy, hz)
    return out
end

--- Every camera move of one entrance, in order.
local function glides()
    local out = {}
    for _, e in ipairs(order) do
        if e.kind == 'camglide' then out[#out + 1] = e end
    end
    return out
end

do
    reset()
    wearChosenModel()
    pump(70000)

    local lens = camSegLengths()
    local moves = glides()

    ok(#moves == #lens,
        ('the flight is one move per segment, ending on the lobby frame '
            .. '(%d moves, %d segments)'):format(#moves, #lens))

    -- ═══ NO EASE ON A SEGMENT OF A FLIGHT ═══
    --
    -- This is the pause itself. An eased interpolation decelerates to a
    -- standstill at its destination; three of them in a row is a camera that
    -- stops at every node, and no amount of retiming the moves can fix it
    -- because the stop is inside the engine's own curve.
    local eased = 0
    for _, m in ipairs(moves) do
        if m.easeLoc ~= 0 or m.easeRot ~= 0 then eased = eased + 1 end
    end
    ok(eased == 0,
        ('no segment of the flight eases in or out -- an eased move arrives at '
            .. 'rest, which is the pause at each node (%d of %d eased)')
            :format(eased, #moves))

    -- ═══ ONE PACE, ALL THE WAY DOWN ═══
    --
    -- The segments are about 222m, 102m and 31m. A flat duration each -- which
    -- is what camMoveMs was -- flies them at roughly 44, 20 and 6 metres per
    -- second, so the camera changes speed at every node even once the easing is
    -- gone. The ratio is what is asserted rather than any particular speed, so
    -- retuning camFlightMs cannot break this.
    if #moves == #lens then
        local fast, slow = 0.0, math.huge
        for i, m in ipairs(moves) do
            local mps = lens[i] / ((m.ms or 1) / 1000.0)
            if mps > fast then fast = mps end
            if mps < slow then slow = mps end
        end
        ok(slow > 0.0 and fast / slow < 1.10,
            ('the camera holds one pace across every segment '
                .. '(%.1f m/s fastest, %.1f m/s slowest)'):format(fast, slow))
    end

    -- ═══ AND NOTHING SITS BETWEEN TWO SEGMENTS ═══
    --
    -- Each move is issued when the one before it finishes. Anything else is a
    -- camera parked at a node waiting for something -- which is what the last
    -- move used to do, holding at the third node until the ped's measured
    -- arrival came within camLeadMs of it.
    local worst = 0
    for i = 2, #moves do
        local gap = moves[i].at - (moves[i - 1].at + (moves[i - 1].ms or 0))
        if gap > worst then worst = gap end
    end
    ok(worst <= 100,
        ('no segment waits for the one before it to be over '
            .. '(worst gap %dms)'):format(worst))
end

-- ...AND THE COUPLING IS GONE RATHER THAN MERELY DORMANT.
--
-- At the walk speeds the owner authored the old code happened not to dwell:
-- the ped is quick enough that its estimated arrival was already inside the
-- lead by the time the second move ended. Slow the walk down -- which is one
-- config edit, and is exactly what the entrance did before walkSpeeds landed --
-- and the same code parks the camera in the sky for ten seconds. The property
-- worth having is that the flight does not read the ped AT ALL.
do
    local C = BR.Config.Match.lobbyEntrance
    local realSpeeds = C.walkSpeeds
    C.walkSpeeds = { 1.0 }

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

    C.walkSpeeds = realSpeeds
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
    reset()
    wearChosenModel()
    pump(70000)

    -- The legs, as the client builds them: the authored corners then the mark.
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
        local nearest, nearestLeg = math.huge, 0
        for i = 2, #tasks do
            local prev = legs[i - 1]
            local d = BR.Dist(tasks[i].fromX, tasks[i].fromY, prev.x, prev.y)
            if d < nearest then nearest, nearestLeg = d, i end
        end
        ok(nearest >= C.cornerRadius * 0.75,
            ('each leg is handed over while the ped is still short of the '
                .. 'corner and still moving (leg %d took over %.2fm out, '
                .. 'cornerRadius %.2f)')
                :format(nearestLeg, nearest, C.cornerRadius))
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
    BR.State.me.state = BR.PlayerState.PLAYING
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

    BR.State.me.state = BR.PlayerState.PLAYING
    ped.x, ped.y = 1500.0, 2500.0
    pump(500)

    BR.State.me.state = BR.PlayerState.LOBBY
    order = {}
    BR.Spawn.toLobby(false)
    pump(4000)

    local C = BR.Config.Match.lobbyEntrance
    local _, start = firstOf('coords',
        function(e) return math.abs(e.x - C.pedStart.x) < 0.01 end)
    local _, fade = firstOf('fadein')

    ok(start ~= nil, 'the trip home starts the entrance')
    ok(fade ~= nil, 'precondition: the trip home lifts its cover')
    ok(start ~= nil and fade ~= nil and start.at == fade.at,
        ('the ped is placed on the start mark in the same frame the cover '
            .. 'lifts, not after it (%sms apart)')
            :format(start and fade and tostring(start.at - fade.at) or '?'))

    -- AND THE ENTRANCE REALLY RAN, rather than the assertion above passing
    -- because nothing happened at all on this road.
    ok(BR.LobbyPed.entering() or firstOf('task') ~= nil,
        'and the walk itself is under way on the trip home')
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
    -- INSIDE the focus hold, not past it: the whole trip -- fade, cover, hold,
    -- placement -- is over in a little over a second here, and this block needs
    -- to catch it while it still has the focus.
    pump(600)

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
