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

function SetEntityCoordsNoOffset(_p, x, y, z)
    ped.x, ped.y, ped.z = x, y, z
    ped.dest = nil
    note('coords', { x = x, y = y, z = z })
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
    note('task', { x = x, y = y, z = z, speed = speed })
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
function DoScreenFadeIn() fadedOut = false fadedIn = true end
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
local interpUntil = {}
function SetCamActiveWithInterp(dest, src, ms)
    interpUntil[dest] = fakeTime + (ms or 0)
    note('camglide', { from = src, to = dest, ms = ms })
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
    for _, k in ipairs({ 'camMoveMs', 'camLeadMs', 'focusLeadMs', 'modelWaitMs',
                         'clipsetWaitMs', 'legTimeoutMs', 'armWaitMs',
                         'arriveRadius' }) do
        ok(type(C[k]) == 'number', ('lobbyEntrance.%s is tunable'):format(k))
    end

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

    -- THE CAMERA GOT THERE FIRST. The owner's number is two seconds; what is
    -- asserted is the property rather than the number, so tuning camLeadMs does
    -- not break the test -- but the lead has to be real and it has to be most of
    -- what was asked for.
    local _, arrival = firstOf('freeze', function(e) return e.on and e.at > 2000 end)
    local homeAt, pedAt
    for _, e in ipairs(order) do
        if e.kind == 'campoint' and e.at > 2000 then homeAt = homeAt or e.at end
    end
    for i = #order, 1, -1 do
        if order[i].kind == 'coords' then pedAt = order[i].at break end
    end
    local C2 = BR.Config.Match.lobbyEntrance
    ok(homeAt ~= nil, 'the camera is aimed at the lobby frame at the end of the flight')
    if homeAt and pedAt then
        local landedAt = homeAt + C2.camMoveMs
        ok(landedAt <= pedAt,
           ('the camera lands before the ped (%dms vs %dms)'):format(landedAt, pedAt))
        ok(pedAt - landedAt >= C2.camLeadMs * 0.5,
           ('and by most of the authored lead (%dms of %dms)')
               :format(pedAt - landedAt, C2.camLeadMs))
    end
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

-- ------------------------------------------------------------------ report ---

if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m, %d passed'):format(fail, pass))
    os.exit(1)
end
realPrint(('\27[32mok\27[0m   %d assertions: the lobby entrance walks, abandons '
    .. 'cleanly, and the ped is teleported before it is networked'):format(pass))
