-- Offline frame profiler for br_core's client (#393).
--
--   lua tools/perf_client.lua                 the table, every phase, Season 1
--   lua tools/perf_client.lua --world s2      the same in another world (or `all`)
--   lua tools/perf_client.lua --top 10        more contributors per phase
--   lua tools/perf_client.lua --by 12         more natives named per contributor
--   lua tools/perf_client.lua --files         per client file, and its heavy calls
--   lua tools/perf_client.lua --phase match   one phase (and the ones before it)
--   lua tools/perf_client.lua --check         the budget gate tools/verify.sh runs
--   lua tools/perf_client.lua --rebaseline    measure and rewrite the budget
--
-- WHAT IT IS. Every br_core client file, in fxmanifest order, plus the vendored
-- ScaleformUI that loads inside br_core, run in one Lua state against a modelled
-- engine: a clock that moves 1/60 s a frame, threads as coroutines woken by that
-- clock, the three BR.Loop bands on their real threads, events and net events,
-- entities, blips, keys and a camera, and a stub server that answers what the
-- client asks it (loot cells, and br_environment's island sky). The session is
-- then walked through the phases a player sees -- lobby, warmup, boarding, the
-- plane's doors-open cruise over the mainland, the jump, a match -- and the
-- match through the things a player does in it: aiming down a scope, pinging,
-- driving with boost, reviving, talking, standing outside the storm, the emote
-- wheel, going down, spectating and standing at a terminal with a Yubikey. Each
-- phase is measured for a few hundred frames.
--
-- IN EVERY WORLD A CLIENT CAN STAND IN (see THE WORLDS below): Season 1, Season
-- 2, Season 2 under the festive sky, and Season 1 reached by a live `brseason 1`
-- from Season 2 with `brfestive` on -- the owner's state on 2026-10-06 -- and
-- three that go wrong on purpose: the pad's crates off their anchors, in both
-- seasons, and no streamed asset ever loading. --check and --rebaseline play the
-- session in each of them; each world is one fresh run of this file, loaded by
-- the first. And at the end of each whole session, every change a server makes
-- -- a season switch, the festive sky, its cycle, the match ending -- is made and
-- measured on its own (THE CHANGES).
--
-- WHAT IT COUNTS, four ways, each exact and the same on every run:
--   natives  every native the code calls, through a stub that charges it to
--            whatever is running: a loop callback by its registered name, a raw
--            thread by the file and line that created it, an event handler by
--            its event.
--   draws    the natives among those named Draw* (DrawSpritePoly, DrawPoly,
--            DrawMarker, DrawSprite, DrawRect...), counted again on their own:
--            a draw is a native here and a piece of render-thread work in the
--            game, so a draw that comes back must show as a draw.
--   KB       kilobytes allocated per frame, with the collector stopped while
--            measuring. Deterministic, and the cost a geometry rebuild shows as.
--   heavy    the natives in HEAVY (below) -- a world scan or probe, a stream
--            request, an entity, blip, sound or effect made or taken down, a
--            sky, timecycle, model hide or ground write, a browser message, a
--            prop moved -- counted again, PER SECOND: each is engine work far
--            past a read, so one of them repeated every SLOW pass is a
--            regression the per-frame native count cannot see.
-- Lua time is printed per phase only, over the whole measured window, beside
-- the step of the clock it was read from (os.clock ticks a whole millisecond on
-- Windows' PUC Lua): per callback, a call is shorter than one tick.
--
-- WHAT IT CANNOT SEE. The engine side of a native: a DrawSpritePoly counts one
-- here and costs the render thread a triangle there, and a GetEntityCoords is a
-- few hundred nanoseconds of marshalling in the game against a table read here.
-- The Lua time is this machine's PUC Lua 5.4, not the game's CfxLua, and it
-- includes the stubs. Use it to rank and to compare a before with an after; the
-- in-game numbers are brbench / brab (client/debug.lua) and resmon.
--
-- THE BUDGET. tools/perf_budget.lua holds what each phase measured on each of the
-- four counts, in each world. --check fails a phase that goes over any of them by
-- more than a small slack (see the budget section at the bottom), which is how
-- an ungated per-frame loop, a draw that came back, a rebuild every frame or a
-- heavy call every pass gets caught before a playtest does. docs/testing.md says
-- how to rebaseline.

--- When the first run of this file loads it again to measure one more world
--- (see THE WORLDS), it is handed { world = id, args = its ARGS, self = path }
--- and returns that world's numbers instead of printing them.
local SUB = ...
if type(SUB) ~= 'table' then SUB = nil end

local ARGS = {}
if SUB then
    for k, v in pairs(SUB.args) do ARGS[k] = v end
else
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == '--check' or a == '--rebaseline' or a == '--quiet' or a == '--digest'
            or a == '--files' then
            ARGS[a:sub(3)] = true
        elseif a == '--top' or a == '--phase' or a == '--frames' or a == '--root'
            or a == '--by' or a == '--world' then
            ARGS[a:sub(3)] = arg[i + 1]
            i = i + 1
        end
        i = i + 1
    end
end

local ROOT = ARGS.root or ''
local RES  = ROOT .. 'resources/'
local FR   = RES .. '[fivem-royale]/'
local TOP  = tonumber(ARGS.top) or 5
local BUDGET_FILE = ROOT .. 'tools/perf_budget.lua'
--- This file, which the first run loads again for each other world.
local SELF = SUB and SUB.self or arg[0]

local realPrint = print
local clock = os.clock

-- ------------------------------------------------------------- the worlds ---
--
-- ═══ ONE SESSION, PLAYED IN EVERY WORLD A CLIENT CAN STAND IN ═══
--
--   "seems like I caught br_core above 70ms frame time at 1080p again - that's
--    not okay. this was with season 1 on and festive, with the failed attempt
--    to change the weather"                              -- owner, 2026-10-06
--
-- The session used to be played on a Season 1 server and no other, so a cost
-- that only a Season 2 client pays, or only one switched into Season 1 live,
-- was never measured. Each world is the same session from a different start:
--
--   s1          Season 1 from boot: the shipping world. Its phases keep their
--               bare names.
--   s2          Season 2 from boot: terminals, Yubikeys, the Season 2 crates and
--               the emote wheel on.
--   s2-festive  Season 2 under the festive sky (server/world.lua's one fact):
--               each role's sky is XMAS, with the white ground on under it.
--   s1-live     the owner's, 2026-10-06: Season 2 at boot; in the lobby
--               `brfestive on` while Season 2 is still in force (the festive
--               sky and its white ground arrive), then `brseason 1` applies (the
--               season moves, the festive sky goes with it, the laptops are
--               hidden), and the rest of the session in Season 1.
--
-- AND THREE THAT GO WRONG ON PURPOSE (#393 review, 2026-10-06), because a model
-- in which everything is found and everything loads cannot see a search that
-- never finds or a request that never loads being made again on every pass:
--
--   s1-padoff   the warmup pad's four crates built a meter off their surveyed
--   s2-padoff   anchors, as a crate knocked over or thrown clear stands: client/
--               warmupcrates.lua finds a body there but not on its anchor.
--               Lobby and warmup only, in both seasons (Season 2 searches every
--               box model it has built as well).
--   s1-noload   no streamed asset ever loads: models, animations, particle
--               effects, texture dictionaries, movies and sound banks are each
--               requested and never arrive, the whole session long.
--
-- AND ONE FOR THE TOOLS THAT COME DOWN FROM THE SKY (#396 round 5, 2026-10-06):
--
--   s2-sky      Season 2 from boot, the whole session, then at the terminal a
--               Vehicle drop and an Airstrike, each a scene of its own. Only
--               those scenes are budgeted here (`measure`), and it ends there
--               (`upTo`), with no changes: every other world plays its session
--               exactly as it did, so not one of their numbers moves for them.
--               A scene with `world` set is played in that world alone.
--
-- A world's phases are budgeted as `<world>/<phase>`.
local WORLDS = {
    { id = 's1',         season = '1' },
    { id = 's2',         season = '2' },
    { id = 's2-festive', season = '2', festive = true },
    { id = 's1-live',    season = '2', live = '1' },
    { id = 's1-padoff',  season = '1', padOff = true, upTo = 'warmup' },
    { id = 's2-padoff',  season = '2', padOff = true, upTo = 'warmup' },
    { id = 's1-noload',  season = '1', noLoad = true },
    { id = 's2-sky',     season = '2', upTo = 'match airstrike',
      measure = { ['match vehicle drop'] = true, ['match airstrike'] = true } },
}
local worldById = {}
for _, w in ipairs(WORLDS) do worldById[w.id] = w end

--- A world's name for a phase, in the budget and the table.
--- @param world table @param phase string @return string
local function phaseId(world, phase)
    if world.id == 's1' then return phase end
    return world.id .. '/' .. phase
end

-- ------------------------------------------------------------ heavy calls ---
--
-- ═══ A CALL THAT COSTS THE ENGINE MORE THAN A READ ═══
--
-- Every native counts one in `natives`, which is right for the reads and the
-- per-frame draws that make up nearly all of them. These are not like them: a
-- world scan walks a pool, a stream request queues a load, an entity made or
-- deleted moves the world, and a sky, timecycle, model hide, ground or lights
-- write applies a whole effect. Each belongs ON A CHANGE -- the loot under the
-- player, a season, a festive sky, a storm crossing -- and one of them repeated
-- every SLOW pass is 0.02 natives a frame, invisible beside a budget of
-- hundreds, and still one heavy call a second for the engine. So they are
-- counted again, per second, and budgeted on their own. (The few that are per
-- frame by design -- a custom camera's collision ray, a falling crate's pose --
-- are budgeted as what they are, and a second one would still fail.)
--
-- InvokeNative is here because the one hashed native br_core calls is the white
-- ground's pass (client/world.lua).
--
-- AND EVERY CALL THAT DOES WORK ELSEWHERE OR MOVES THE WORLD (#393 review,
-- 2026-10-06): a message to a browser (a DUI page's script runs on it, a NUI
-- message crosses to the UI), a synchronous ground or water probe, a shape
-- test, a sound or a particle effect started, a blip made or taken down, and a
-- PROP's pose written (`'prop'` below: on an object only, since a ped or a car
-- is moved by the game every frame anyway). A plate's message sent on every
-- TICK pass instead of on a change is under 0.2 natives a frame, inside the
-- native slack; here it is eight or more heavy calls a second.
local HEAVY = {}
for _, n in ipairs({
    -- world scans and probes
    'GetGamePool', 'GetClosestObjectOfType', 'GetClosestVehicle', 'GetClosestPed',
    'GetPedNearbyVehicles', 'GetPedNearbyPeds', 'StartExpensiveSynchronousShapeTestLosProbe',
    'StartShapeTestRay', 'StartShapeTestLosProbe', 'StartShapeTestCapsule',
    'StartShapeTestSweptSphere', 'StartShapeTestBox', 'StartShapeTestBound',
    'StartShapeTestBoundingBox', 'StartShapeTestMouseCursorLosProbe',
    'StartShapeTestSurroundingCoords', 'GetGroundZFor_3dCoord', 'GetGroundZFor3dCoord',
    'GetGroundZExcludingObjectsFor_3dCoord', 'GetGroundZExcludingObjectsFor3dCoord',
    'GetGroundZAndNormalFor_3dCoord', 'GetWaterHeight', 'GetWaterHeightNoWaves',
    'TestProbeAgainstWater', 'TestProbeAgainstAllWater', 'TestVerticalProbeAgainstAllWater',
    -- streaming
    'RequestModel', 'SetModelAsNoLongerNeeded', 'RequestAnimDict', 'RemoveAnimDict',
    'RequestAnimSet', 'RequestClipSet', 'RequestNamedPtfxAsset', 'RemoveNamedPtfxAsset',
    'RequestPtfxAsset', 'RequestStreamedTextureDict', 'RequestCollisionAtCoord',
    'RequestScaleformMovie', 'RequestScaleformMovieInstance', 'RequestScriptAudioBank',
    'RequestWeaponAsset', 'RequestIpl', 'RemoveIpl',
    -- entities and cameras
    'CreateObject', 'CreateObjectNoOffset', 'CreatePed', 'CreatePedInsideVehicle',
    'ClonePed', 'CreateVehicle', 'DeleteEntity', 'DeleteObject', 'DeletePed',
    'DeleteVehicle', 'CreateCam', 'CreateCamWithParams', 'DestroyCam', 'RenderScriptCams',
    -- the world's look: model hides, sky, timecycle, ground, lights, screen effects
    'CreateModelHide', 'CreateModelHideExcludingScriptObjects', 'RemoveModelHide',
    'CreateModelSwap', 'RemoveModelSwap', 'SetWeatherTypeNow', 'SetWeatherTypeNowPersist',
    'SetWeatherTypePersist', 'SetWeatherTypeOvertimePersist', 'SetOverrideWeather',
    'ClearOverrideWeather', 'ClearWeatherTypePersist', 'SetRainLevel', 'SetSnowLevel',
    'SetWind', 'SetWindSpeed', 'SetTimecycleModifier', 'ClearTimecycleModifier',
    'SetTransitionTimecycleModifier', 'SetExtraTimecycleModifier',
    'ClearExtraTimecycleModifier', 'SetForceVehicleTrails', 'SetForcePedFootstepsTracks',
    'SetArtificialLightsState', 'SetArtificialLightsStateAffectsVehicles',
    'AnimpostfxPlay', 'AnimpostfxStop', 'AnimpostfxStopAll', 'InvokeNative',
    -- sounds, particle effects and blips, started or taken down
    'PlaySound', 'PlaySoundFrontend', 'PlaySoundFromCoord', 'PlaySoundFromEntity',
    'StartParticleFxLoopedAtCoord', 'StartParticleFxLoopedOnEntity',
    'StartParticleFxLoopedOnEntityBone', 'StartParticleFxNonLoopedAtCoord',
    'StartParticleFxNonLoopedOnEntity', 'StartNetworkedParticleFxLoopedOnEntity',
    'StartNetworkedParticleFxNonLoopedAtCoord', 'StartNetworkedParticleFxNonLoopedOnEntity',
    'AddBlipForCoord', 'AddBlipForRadius', 'AddBlipForArea', 'AddBlipForEntity', 'RemoveBlip',
    -- browsers, and the messages sent to them
    'CreateDui', 'DestroyDui', 'SetDuiUrl', 'CreateRuntimeTxd',
    'CreateRuntimeTextureFromDuiHandle', 'SendDuiMessage', 'SendNUIMessage', 'SendNuiMessage',
}) do HEAVY[n] = true end

-- A pose written to a prop: heavy on an object, a plain native on a ped or a car.
for _, n in ipairs({
    'SetEntityCoords', 'SetEntityCoordsNoOffset', 'SetEntityRotation', 'SetEntityHeading',
    'SetEntityQuaternion',
}) do HEAVY[n] = 'prop' end

-- ------------------------------------------------- what this run measures ---
--
-- --check and --rebaseline cover every world; a plain run covers Season 1, or
-- the world --world names (`all` for every one). The first is measured by this
-- run and each other one by a fresh run of this file (SUB).
local runList = {}
if SUB then
    runList[1] = assert(worldById[SUB.world], 'no world ' .. tostring(SUB.world))
elseif ARGS.world == 'all' or ((ARGS.check or ARGS.rebaseline) and not ARGS.world) then
    for _, w in ipairs(WORLDS) do runList[#runList + 1] = w end
else
    local w = worldById[ARGS.world or 's1']
    if not w then
        local ids = {}
        for _, x in ipairs(WORLDS) do ids[#ids + 1] = x.id end
        realPrint(('no world %q: one of %s, or all'):format(tostring(ARGS.world),
            table.concat(ids, ', ')))
        os.exit(2)
    end
    if ARGS.rebaseline then
        realPrint('--rebaseline writes every world; leave --world off')
        os.exit(2)
    end
    runList[1] = w
end
local WORLD = runList[1]

--- The recorded budget, or nil. Under --check its frame count is the one used,
--- so the per-frame averages are taken over the same window it was written from.
local budget = nil
if ARGS.check and not SUB then
    local chunk = loadfile(BUDGET_FILE)
    budget = chunk and chunk() or nil
    if type(budget) ~= 'table' or type(budget.phases) ~= 'table' then
        realPrint('\27[31mFAIL\27[0m no readable budget at ' .. BUDGET_FILE)
        realPrint('     Write one: lua tools/perf_client.lua --rebaseline')
        os.exit(1)
    end
    ARGS.frames = tonumber(budget.frames) or ARGS.frames
end
local MEASURE_FRAMES = tonumber(ARGS.frames) or 600
ARGS.frames = MEASURE_FRAMES

--- The step of `clock` on this machine, in ms: the smallest nonzero difference
--- between two readings, over a 50 ms busy loop. Lua time is printed beside it,
--- because a number read off a clock is only as fine as its tick -- and on
--- Windows' PUC Lua that tick is a whole millisecond, longer than most frames'
--- worth of br_core here.
local function clockStep()
    local best = math.huge
    local t0 = clock()
    local last = t0
    while true do
        local now = clock()
        if now ~= last then
            if now - last < best then best = now - last end
            last = now
        end
        if now - t0 >= 0.05 then break end
    end
    return best * 1000.0
end

-- The code under test draws a few things with math.random (a warmup spawn, a
-- lobby idle clip). Seeded, so every run is the same session and the counts
-- the budget compares are exact.
math.randomseed(393)

-- ------------------------------------------------------------ attribution ---
--
-- KILOBYTES ARE THE CODE'S OWN. Each bucket is charged what the collector counts
-- between entering and leaving it, minus two things that are not the code under
-- test: the harness's bookkeeping (the stack record below is made between two
-- readings and charged to nobody) and what a native stub hands back. A stub's
-- vector3 is a table here and a value in CfxLua, which allocates nothing for it,
-- so counting it would charge GetEntityCoords to whoever asked.

local gcCount = collectgarbage
local buckets = {}

--- Is a bucket br_core's own? Not the harness, the stub server or a file's load.
--- @param k string @return boolean
local function counted(k)
    return k ~= '(harness)' and k ~= '(server)' and not k:match('^load ')
end

--- Every counted native and heavy call so far, whoever made it: read before and
--- after each frame of a change (THE CHANGES) for its busiest frame.
local TALLY = { n = 0, h = 0 }

local function bucket(key)
    local b = buckets[key]
    if not b then
        b = { key = key, n = 0, d = 0, h = 0, kb = 0.0, calls = 0, by = {}, hb = {},
              c = counted(key) }
        buckets[key] = b
    end
    return b
end

-- BY FILE, TOO, under --files: every count charged to a bucket is charged again
-- to the client file whose code is running -- a loop callback's, a handler's, a
-- thread's -- so a world's cost reads per file. Off otherwise, and then nothing
-- below touches it.
local FILES = ARGS.files == true
local fileStats = {}
local fileOfFn = setmetatable({}, { __mode = 'k' })

--- The file a function was written in, or a name for the harness's own.
--- @param fn function|string|nil
--- @return string
local function fileOf(fn)
    if type(fn) == 'string' then return fn end
    if type(fn) ~= 'function' then return '(harness)' end
    local f = fileOfFn[fn]
    if not f then
        local info = debug.getinfo(fn, 'S')
        f = (info.short_src or '?'):match('([^/\\]+)$') or '?'
        if f == 'perf_client.lua' then f = '(harness)' end
        fileOfFn[fn] = f
    end
    return f
end

local function fileStat(name)
    local f = fileStats[name]
    if not f then
        f = { file = name, n = 0, h = 0, by = {} }
        fileStats[name] = f
    end
    return f
end

local curB = bucket('(load)')
local curF = nil
local stack = {}

--- Enter `key`, pausing whoever was running. Exclusive attribution: an event a
--- callback triggers is charged to the event, not to the callback. `src` is
--- the function (or the file) whose code runs under it, read only under --files.
local function enter(key, src)
    local kb = gcCount('count')
    local top = stack[#stack]
    if top then top.b.kb = top.b.kb + (kb - top.kb0) end
    local b = bucket(key)
    b.calls = b.calls + 1
    local f = nil
    if FILES then
        f = (src ~= nil and fileStat(fileOf(src))) or (top and top.f) or fileStat('(harness)')
    end
    local rec = { b = b, kb0 = 0.0, f = f }
    stack[#stack + 1] = rec
    curB, curF = b, f
    rec.kb0 = gcCount('count')
end

local function leave()
    local kb = gcCount('count')
    local top = stack[#stack]
    stack[#stack] = nil
    top.b.kb = top.b.kb + (kb - top.kb0)
    local under = stack[#stack]
    if under then
        under.kb0 = gcCount('count')
        curB, curF = under.b, under.f
    else
        curB, curF = bucket('(harness)'), nil
    end
end

--- Run `fn` under `key`. Its results are not wanted by any caller here, so none
--- are packed: a packed result table would be the harness's allocation charged
--- to the code.
local function call(key, fn, ...)
    enter(key, fn)
    local ok, err = pcall(fn, ...)
    leave()
    if not ok then
        local b = bucket(key)
        b.errs = (b.errs or 0) + 1
        if not b.errSaid then
            b.errSaid = true
            realPrint(('\27[33m[perf] %s errored: %s\27[0m'):format(key, tostring(err)))
        end
    end
end

-- ------------------------------------------------------------------- world ---

local NOW = 1000000.0          -- ms; the engine clock, moved 1/60 s per frame
local FRAME_MS = 1000.0 / 60.0
local function gameMs() return math.floor(NOW) end

--- A FiveM vector3. A table here, a userdata in the game; the code only ever
--- indexes it and does arithmetic on it.
local V3 = {}
V3.__index = function(v, k)
    if k == 'xy' then return setmetatable({ x = v.x, y = v.y, z = 0.0 }, V3) end
    return nil
end
local function vec3(x, y, z)
    return setmetatable({ x = (x or 0.0) + 0.0, y = (y or 0.0) + 0.0, z = (z or 0.0) + 0.0 }, V3)
end
V3.__add = function(a, b)
    if type(b) == 'number' then return vec3(a.x + b, a.y + b, a.z + b) end
    return vec3(a.x + b.x, a.y + b.y, (a.z or 0) + (b.z or 0))
end
V3.__sub = function(a, b)
    if type(b) == 'number' then return vec3(a.x - b, a.y - b, a.z - b) end
    return vec3(a.x - b.x, a.y - b.y, (a.z or 0) - (b.z or 0))
end
V3.__mul = function(a, b)
    if type(a) == 'number' then a, b = b, a end
    if type(b) == 'number' then return vec3(a.x * b, a.y * b, a.z * b) end
    return vec3(a.x * b.x, a.y * b.y, a.z * b.z)
end
V3.__div = function(a, b) return vec3(a.x / b, a.y / b, a.z / b) end
V3.__unm = function(a) return vec3(-a.x, -a.y, -a.z) end
V3.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + (a.z or 0) * (a.z or 0)) end
V3.__eq  = function(a, b) return a.x == b.x and a.y == b.y and a.z == b.z end
V3.__tostring = function(a) return ('vector3(%.2f, %.2f, %.2f)'):format(a.x, a.y, a.z) end

local W = {
    ents = {},          -- [handle] = { x, y, z, kind, model, heading }
    nextEnt = 2000,
    blips = {},
    nextBlip = 9000,
    me = 1,             -- PlayerPedId
    players = {},       -- [serverId] = { ped = handle } -- streamed in
    -- The rendered camera: a third-person camera behind the player, looking along
    -- `rz` (GTA heading) and slightly down. Moved with the player every frame.
    cam = { x = 0.0, y = 0.0, z = 0.0, rx = -8.0, rz = 0.0 },
    convars = {},
    kvp = {},
    muted = {},         -- pma-voice's mute list, [serverId] = true
    -- What the player is doing, as the match scenes set it: keys held by their
    -- virtual-key code, controls pressed by id, aiming, the weapon in hand and
    -- the weapons carried, and the car they are driving.
    keys = {},
    controls = {},
    aiming = false,
    weapon = nil,
    carried = {},
    veh = nil,
    handles = 100,
    -- The scripted camera the engine is rendering, and the frame number.
    activeCam = nil,
    scriptRender = false,
    frameNo = 0,
}
W.ents[W.me] = { x = 0.0, y = 0.0, z = 30.0, kind = 'ped', heading = 0.0 }

local function newEnt(kind, model, x, y, z)
    W.nextEnt = W.nextEnt + 1
    W.ents[W.nextEnt] = { kind = kind, model = model, x = (x or 0.0) + 0.0,
                          y = (y or 0.0) + 0.0, z = (z or 0.0) + 0.0, heading = 0.0 }
    return W.nextEnt
end

local function entPos(h)
    local e = W.ents[h]
    if not e then return vec3(0.0, 0.0, 0.0) end
    -- An attached entity (the player riding the plane) is where its parent is.
    local parent = e.attachedTo and W.ents[e.attachedTo]
    if parent then return vec3(parent.x, parent.y, parent.z) end
    return vec3(e.x, e.y, e.z)
end

local function jenkins(s)
    s = tostring(s):lower()
    local h = 0
    for i = 1, #s do
        h = (h + s:byte(i)) & 0xffffffff
        h = (h + (h << 10)) & 0xffffffff
        h = h ~ (h >> 6)
    end
    h = (h + (h << 3)) & 0xffffffff
    h = h ~ (h >> 11)
    h = (h + (h << 15)) & 0xffffffff
    if h >= 0x80000000 then h = h - 0x100000000 end
    return h
end

-- -------------------------------------------------------------- natives ---
--
-- IMPL holds the behaviour of the natives whose answer steers the code. Every
-- other native name falls through to a default chosen by its verb. Either way
-- the call is COUNTED, by name, against whoever is running.

-- BOOL natives answer Lua booleans here, as the runtime's generated wrappers
-- answer them. Code that reads one through BR.NativeTruthy is indifferent; code
-- that tests one bare would, under 0/1, take paths it never takes in the game.
local function T() return true end
local function F() return false end

local IMPL = {}
--- s1-padoff / s2-padoff (THE WORLDS): where a body built at (x, y) really
--- stands, set once the config has loaded. nil in every other world.
local padShift = nil
IMPL.GetGameTimer        = function() return gameMs() end
IMPL.GetNetworkTime      = function() return gameMs() end
IMPL.GetFrameTime        = function() return FRAME_MS / 1000.0 end
IMPL.GetFrameCount       = function() return math.floor(NOW / FRAME_MS) end
IMPL.GetCloudTimeAsInt   = function() return 1790000000 + math.floor(NOW / 1000) end
IMPL.GetCurrentResourceName = function() return 'br_core' end
IMPL.GetResourceState    = function() return 'started' end
IMPL.GetConvar           = function(n, d) local v = W.convars[n]; if v == nil then return d end return tostring(v) end
IMPL.GetConvarInt        = function(n, d) local v = tonumber(W.convars[n]); if v == nil then return d end return math.floor(v) end
-- THE RUNTIME'S CONVAR LISTENER (Cfx, apiset shared): a replicated value lands
-- by `setr`, which calls every AddConvarChangeListener whose filter names it.
-- The season module holds br_seasonServed and re-reads it only then, so a write
-- to W.convars is a `setr`, and each listener runs under its own name.
local convarListeners = {}
IMPL.AddConvarChangeListener = function(filter, fn)
    convarListeners[#convarListeners + 1] = { filter = filter, fn = fn }
    return #convarListeners
end
do
    local store = W.convars
    W.convars = setmetatable({}, {
        __index = store,
        __newindex = function(_, k, v)
            store[k] = v
            for _, l in ipairs(convarListeners) do
                if l.filter == nil or l.filter == k then call('convar ' .. k, l.fn, k, '') end
            end
        end,
    })
end
IMPL.GetHashKey          = jenkins
IMPL.PlayerId            = function() return 0 end
IMPL.PlayerPedId         = function() return W.me end
IMPL.GetPlayerPed        = function(p)
    if p == 0 or p == -1 then return W.me end
    local pl = W.players[p]
    return pl and pl.ped or 0
end
IMPL.GetPlayerServerId   = function(p)
    if p == 0 then return 1 end
    return W.players[p] and p or 0
end
IMPL.GetPlayerFromServerId = function(src)
    if src == 1 then return 0 end
    return W.players[src] and src or -1
end
IMPL.NetworkIsPlayerActive = function(p) return (p == 0 or W.players[p]) and true or false end
IMPL.GetActivePlayers    = function()
    local out = { 0 }
    for src in pairs(W.players) do out[#out + 1] = src end
    return out
end
IMPL.GetPlayerName       = function(p) return 'Player' .. tostring(p) end
IMPL.DoesEntityExist     = function(h) return W.ents[h] ~= nil end
IMPL.GetEntityCoords     = function(h) return entPos(h) end
IMPL.GetEntityHeading    = function(h) local e = W.ents[h] return e and e.heading or 0.0 end
IMPL.GetEntityRotation   = function() return vec3(0.0, 0.0, 0.0) end
IMPL.GetEntityForwardVector = function() return vec3(0.0, 1.0, 0.0) end
IMPL.GetEntityVelocity   = function() return vec3(0.0, 0.0, 0.0) end
IMPL.GetEntitySpeed      = function(h)
    return (W.veh and (h == W.veh or h == W.me)) and 28.0 or 0.0
end
IMPL.GetEntityModel      = function(h) local e = W.ents[h] return e and e.model or 0 end
IMPL.GetEntityHealth     = function(h) return W.ents[h] and 200 or 0 end
IMPL.GetEntityMaxHealth  = function() return 200 end
IMPL.GetPedMaxHealth     = function() return 200 end
IMPL.GetPedArmour        = function() return 50 end
IMPL.GetEntityHeightAboveGround = function(h) return math.max(0.0, entPos(h).z - 30.0) end
IMPL.GetOffsetFromEntityInWorldCoords = function(h, ox, oy, oz)
    local e = W.ents[h] or { x = 0, y = 0, z = 0 }
    return vec3(e.x + (ox or 0), e.y + (oy or 0), e.z + (oz or 0))
end
IMPL.GetPedBoneCoords    = function(h) return entPos(h) end
IMPL.GetWorldPositionOfEntityBone = function(h) return entPos(h) end
IMPL.GetGameplayCamCoord = function() return vec3(W.cam.x, W.cam.y, W.cam.z) end
IMPL.GetGameplayCamRot   = function() return vec3(W.cam.rx, 0.0, W.cam.rz) end
IMPL.GetFinalRenderedCamCoord = function() return vec3(W.cam.x, W.cam.y, W.cam.z) end
IMPL.GetFinalRenderedCamRot   = function() return vec3(W.cam.rx, 0.0, W.cam.rz) end
IMPL.GetFinalRenderedCamFov   = function() return W.cam.fov or 50.0 end
IMPL.GetAspectRatio      = function() return 16.0 / 9.0 end
IMPL.AttachEntityToEntity = function(h, to) local e = W.ents[h] if e then e.attachedTo = to end end
IMPL.DetachEntity        = function(h) local e = W.ents[h] if e then e.attachedTo = nil end end
IMPL.IsEntityAttached    = function(h) local e = W.ents[h] return (e and e.attachedTo) and true or false end
IMPL.GetGameplayCamFov   = function() return W.cam.fov or 50.0 end
IMPL.GetCamCoord         = function() return vec3(W.cam.x, W.cam.y, W.cam.z) end
IMPL.GetCamRot           = function() return vec3(W.cam.rx, 0.0, W.cam.rz) end
IMPL.GetGroundZFor_3dCoord = function() return true, 30.0 end
IMPL.GetWaterHeight      = function() return false, 0.0 end
IMPL.GetWaterHeightNoWaves = function() return false, 0.0 end
IMPL.TestProbeAgainstWater = F
IMPL.GetVehiclePedIsIn   = function(p) return (p == W.me and W.veh) or 0 end
IMPL.GetVehiclePedIsTryingToEnter = function() return 0 end
IMPL.GetVehiclePedIsUsing = IMPL.GetVehiclePedIsIn
IMPL.GetPedInVehicleSeat = function(v, seat)
    return (W.veh and v == W.veh and seat == -1) and W.me or 0
end
IMPL.IsPedInAnyVehicle   = function(p) return p == W.me and W.veh ~= nil end
IMPL.IsPedInVehicle      = function(p, v) return p == W.me and W.veh ~= nil and v == W.veh end
IMPL.GetVehicleFuelLevel = function() return 65.0 end
IMPL.GetSelectedPedWeapon = function() return W.weapon or jenkins('weapon_unarmed') end
IMPL.GetCurrentPedWeapon = function() return true, W.weapon or jenkins('weapon_unarmed') end
IMPL.SetCurrentPedWeapon = function(p, h) if p == W.me then W.weapon = h end end
IMPL.GiveWeaponToPed     = function(p, h, _, _, equip)
    if p ~= W.me then return end
    W.carried[h] = true
    if equip == true or equip == 1 then W.weapon = h end
end
IMPL.HasPedGotWeapon     = function(p, h) return p == W.me and W.carried[h] == true end
IMPL.RemoveWeaponFromPed = function(p, h)
    if p ~= W.me then return end
    W.carried[h] = nil
    if W.weapon == h then W.weapon = nil end
end
IMPL.RemoveAllPedWeapons = function(p) if p == W.me then W.carried, W.weapon = {}, nil end end
IMPL.IsRawKeyDown        = function(code) return W.keys[code] == true end
IMPL.IsControlPressed    = function(_, c) return W.controls[c] == true end
IMPL.IsDisabledControlPressed = IMPL.IsControlPressed
IMPL.IsPlayerFreeAiming  = function() return W.aiming == true end
IMPL.IsUsingKeyboard     = T     -- the owner plays on keyboard and mouse
IMPL.IsAimCamActive      = IMPL.IsPlayerFreeAiming
IMPL.IsFirstPersonAimCamActive = IMPL.IsPlayerFreeAiming
IMPL.GetPedAmmoTypeFromWeapon = function() return 0 end
IMPL.GetAmmoInPedWeapon  = function() return 0 end
IMPL.GetMaxAmmoInClip    = function() return 30 end
IMPL.GetAmmoInClip       = function() return true, 0 end
-- The drop, as far as the code can ask about it: the player is in the air above
-- 32 m (the ground is at 30), on foot below it, and the chute is whatever the
-- phase says (W.chute: 3 freefall, 2 open, -1 none).
local function airborne(h)
    local p = entPos(h)
    local e = W.ents[h]
    return p.z > 32.0 and not (e and e.attachedTo)
end
IMPL.GetPedParachuteState = function() return W.chute or -1 end
IMPL.IsPedOnFoot         = function(h) return not airborne(h) and not (h == W.me and W.veh) end
IMPL.IsEntityInAir       = function(h) return airborne(h) end
IMPL.IsPedFalling        = function(h) return airborne(h) and W.chute == 3 end
IMPL.IsPedInParachuteFreeFall = function(h) return airborne(h) and W.chute == 3 end
IMPL.GetPedParachuteLandingType = function() return -1 end
IMPL.GetPlayerWantedLevel = function() return 0 end
IMPL.GetGamePool         = function(kind)
    local out = {}
    for h, e in pairs(W.ents) do
        if (kind == 'CPed' and e.kind == 'ped') or (kind == 'CVehicle' and e.kind == 'veh')
            or (kind == 'CObject' and e.kind == 'obj') then
            out[#out + 1] = h
        end
    end
    return out
end
IMPL.GetActiveScreenResolution = function() return 1920, 1080 end
IMPL.GetScreenResolution = function() return 1920, 1080 end
IMPL.GetAspectRatio      = function() return 16 / 9 end
IMPL.GetSafeZoneSize     = function() return 1.0 end
IMPL.GetScreenCoordFromWorldCoord = function() return 1, 0.5, 0.5 end
IMPL.World3dToScreen2d   = function() return 1, 0.5, 0.5 end
IMPL.GetResourceKvpString = function(k) return W.kvp[k] end
IMPL.GetResourceKvpInt   = function(k) return tonumber(W.kvp[k]) or 0 end
IMPL.GetResourceKvpFloat = function(k) return tonumber(W.kvp[k]) or 0.0 end
IMPL.SetResourceKvp      = function(k, v) W.kvp[k] = v end
IMPL.SetResourceKvpInt   = function(k, v) W.kvp[k] = v end
IMPL.SetResourceKvpFloat = function(k, v) W.kvp[k] = v end
IMPL.LoadResourceFile    = function() return nil end
IMPL.GetNumResources     = function() return 0 end
IMPL.GetLabelText        = function(s) return tostring(s) end
IMPL.GetStreetNameFromHashKey = function() return 'Street' end
IMPL.GetNameOfZone       = function() return 'ZONE' end
IMPL.GetDisplayNameFromVehicleModel = function() return 'CAR' end
IMPL.GetCurrentFrontendMenuVersion = function() return 0 end
IMPL.GetPlayerUnderwaterTimeRemaining = function() return 10.0 end
IMPL.GetPlayerSprintStaminaRemaining = function() return 100.0 end
-- THE WIDTH A RUNTIME TEXTURE WAS MADE AT (#393): the storm wall reads its ramp's
-- width back before trusting it, and a stub answering one number would send any
-- other width to the banded fallback -- another wall from the one that ships.
IMPL.GetRuntimeTextureWidth = function(t) return W.rtWidth and W.rtWidth[t] or 8 end
IMPL.GetInteriorFromEntity = function() return 0 end
IMPL.GetInteriorAtCoords = function() return 0 end
IMPL.GetRoomKeyFromEntity = function() return 0 end
-- THE GAME CLOCK KEEPS WHAT IT IS TOLD (#394). The clock writer reads the rate
-- and the time back once a second and falls back to writing the time every
-- frame when the engine has not kept them. An engine that answered 12:00:00 and
-- no rate forever would trip that fallback in every phase and charge two
-- natives a frame that a real client never pays, so this one remembers the
-- override and the rate and runs the time on between reads unless paused.
local gameClock = { sec = 12 * 3600, at = 0, msPerMin = 2000, paused = false }
local function clockSec()
    if gameClock.paused or gameClock.msPerMin <= 0 then return gameClock.sec end
    return gameClock.sec + (gameMs() - gameClock.at) * 60 / gameClock.msPerMin
end
IMPL.NetworkOverrideClockTime = function(h, m, s)
    gameClock.sec, gameClock.at = h * 3600 + m * 60 + s, gameMs()
end
IMPL.SetMillisecondsPerGameMinute = function(ms)
    gameClock.sec, gameClock.at = clockSec(), gameMs()
    gameClock.msPerMin = (ms and ms > 0) and ms or 2000
end
IMPL.GetMillisecondsPerGameMinute = function() return gameClock.msPerMin end
IMPL.PauseClock = function(p)
    gameClock.sec, gameClock.at = clockSec(), gameMs()
    gameClock.paused = p == true
end
IMPL.GetClockHours       = function() return math.floor(clockSec() / 3600) % 24 end
IMPL.GetClockMinutes     = function() return math.floor(clockSec() / 60) % 60 end
IMPL.GetClockSeconds     = function() return math.floor(clockSec()) % 60 end
IMPL.GetPedRelationshipGroupHash = function() return jenkins('PLAYER') end
IMPL.GetBlipInfoIdCoord  = function() return vec3(0.0, 0.0, 0.0) end
IMPL.GetBlipCoords       = function(b) local e = W.blips[b] return vec3(e and e.x or 0, e and e.y or 0, 0) end
IMPL.GetFirstBlipInfoId  = function() return 0 end
IMPL.GetNumberOfPlayers  = function() return 1 end
IMPL.GetInvokingResource = function() return nil end
IMPL.GetGameBuildNumber  = function() return 3258 end
IMPL.GetPedLastWeaponImpactCoord = function() return false, vec3(0, 0, 0) end
IMPL.GetPedDrawableVariation = function() return 0 end
IMPL.GetPedTextureVariation = function() return 0 end
IMPL.GetPedPropIndex     = function() return -1 end
IMPL.GetPedPropTextureIndex = function() return -1 end
IMPL.GetEntityAttachedTo = function() return 0 end
IMPL.GetPedSourceOfDeath = function() return 0 end
IMPL.GetShapeTestResult  = function() return 2, 0, vec3(0, 0, 0), vec3(0, 0, 1), 0 end
IMPL.GetShapeTestResultIncludingMaterial = function() return 2, 0, vec3(0, 0, 0), vec3(0, 0, 1), 0, 0 end
-- THE NEAREST OBJECT OF A MODEL IN REACH, as the engine answers it: a crate
-- client/loot.lua built is found where it stands. It used to answer 0 always,
-- and the warmup pad's markers then searched again on every tick of every
-- warmup -- 136 searches a second, which a real client DID pay while a crate
-- was off its anchor or never built. client/warmupcrates.lua now searches again
-- only once a body has been built; s1-padoff and s2-padoff measure that miss.
-- MEASURED ON THE MAP, NOT IN THE SPHERE: this model's ground is one flat 30 m
-- plane (GetGroundZFor_3dCoord), so a prop stands at 30 m wherever the code
-- asks at the surveyed height (the pad's anchors are at 4.5 m). The nearest
-- wins, the lower handle on a tie, so the answer is the same on every run.
IMPL.GetClosestObjectOfType = function(x, y, _, r, hash)
    local best, bestD = 0, (r or 0.0) * (r or 0.0)
    for h, e in pairs(W.ents) do
        if e.kind == 'obj' and e.model == hash then
            local dx, dy = e.x - x, e.y - y
            local d = dx * dx + dy * dy
            if d < bestD or (d == bestD and (best == 0 or h < best)) then best, bestD = h, d end
        end
    end
    return best
end
IMPL.GetPedNearbyVehicles = function() return 0 end
IMPL.GetPedNearbyPeds    = function() return 0 end
IMPL.GetUserLanguage     = function() return 0 end
IMPL.GetCurrentLanguage  = function() return 0 end
IMPL.GetPlayerRadioStationName = function() return nil end
IMPL.NetworkGetNetworkIdFromEntity = function(h) return h end
IMPL.NetworkGetEntityFromNetworkId = function(id) return id end
IMPL.NetworkDoesNetworkIdExist = F
IMPL.NetworkGetPlayerIndexFromPed = function(ped)
    if ped == W.me then return 0 end
    for src, pl in pairs(W.players) do if pl.ped == ped then return src end end
    return -1
end
IMPL.NetworkIsGameInProgress = T
IMPL.NetworkIsSessionStarted = T
IMPL.NetworkIsSessionActive  = T
IMPL.IsMinimapRendering  = T
IMPL.HasModelLoaded      = T
IMPL.IsModelValid        = T
IMPL.IsModelInCdimage    = T
IMPL.IsModelAVehicle     = T
IMPL.HasAnimDictLoaded   = T
IMPL.HasClipSetLoaded    = T
IMPL.HasAnimSetLoaded    = T
IMPL.HasStreamedTextureDictLoaded = T
IMPL.HasNamedPtfxAssetLoaded = T
IMPL.HasPtfxAssetLoaded  = T
IMPL.HasCollisionLoadedAroundEntity = T
IMPL.HasScaleformMovieLoaded = T
IMPL.HasScaleformMovieFilenameLoaded = T
IMPL.HasThisAdditionalTextLoaded = T
IMPL.HasAdditionalTextLoaded = T
IMPL.RequestScriptAudioBank = T
IMPL.HasSoundFinished    = T
IMPL.IsScreenFadedIn     = T
IMPL.IsPlayerControlOn   = T
IMPL.IsPedHuman          = T
IMPL.IsEntityVisible     = T
IMPL.IsPlayerPlaying     = T
IMPL.IsGameplayCamRendering = T
IMPL.IsDuiAvailable      = T
IMPL.IsHudComponentActive = F
IMPL.IsPauseMenuActive   = F
IMPL.IsEntityDead        = function(h) local e = W.ents[h] return (e and e.dead) and true or false end
IMPL.IsPedFatallyInjured = IMPL.IsEntityDead
IMPL.IsPedDeadOrDying    = IMPL.IsEntityDead
IMPL.GetDuiHandle        = function(d) return 'dui' .. tostring(d) end
IMPL.CreateDui           = function() W.handles = W.handles + 1 return W.handles end
IMPL.CreateRuntimeTxd    = function() W.handles = W.handles + 1 return W.handles end
IMPL.CreateRuntimeTexture = function(_, _, w)
    W.handles = W.handles + 1
    W.rtWidth = W.rtWidth or {}
    W.rtWidth[W.handles] = w
    return W.handles
end
IMPL.CreateRuntimeTextureFromDuiHandle = function() W.handles = W.handles + 1 return W.handles end
IMPL.RequestScaleformMovie = function() W.handles = W.handles + 1 return W.handles end
IMPL.RequestScaleformMovieInstance = IMPL.RequestScaleformMovie
IMPL.RequestScaleformMovieInteractive = IMPL.RequestScaleformMovie
IMPL.CreateCam           = function() W.handles = W.handles + 1 return W.handles end
IMPL.CreateCamWithParams = IMPL.CreateCam
IMPL.CreateCameraWithParams = IMPL.CreateCam
IMPL.DoesCamExist        = function(c) return (c and c ~= 0) and true or false end
-- WHICH SCRIPTED CAMERA IS RENDERING, modeled rather than left to the verb default
-- (#393): client/storm.lua leaves out of the bus preview what is behind the bus's
-- own camera, and asks IsCamRendering first -- a stub answering `false` for every
-- camera would measure the ride as if that never happened. The last camera made
-- active renders while RenderScriptCams is on, as in the engine.
IMPL.SetCamActive        = function(c, on)
    if on and on ~= 0 then W.activeCam = c elseif W.activeCam == c then W.activeCam = nil end
end
IMPL.RenderScriptCams    = function(on) W.scriptRender = (on and on ~= 0) and true or false end
IMPL.SetCamActiveWithInterp = function(to) W.activeCam = to end
IMPL.DestroyCam          = function(c) if W.activeCam == c then W.activeCam = nil end end
IMPL.DestroyAllCams      = function() W.activeCam = nil end
IMPL.IsCamRendering      = function(c)
    return (W.scriptRender and c ~= nil and W.activeCam == c) and true or false
end
IMPL.GetRenderingCam     = function() return (W.scriptRender and W.activeCam) or -1 end
IMPL.GetFrameCount       = function() return W.frameNo end
IMPL.StartShapeTestRay   = function() return 1 end
IMPL.StartShapeTestLosProbe = function() return 1 end
IMPL.StartExpensiveSynchronousShapeTestLosProbe = function() return 1 end
IMPL.StartShapeTestCapsule = function() return 1 end
IMPL.StartShapeTestSweptSphere = function() return 1 end
IMPL.CreateObject        = function(m, x, y, z)
    if padShift then x, y = padShift(x, y) end
    return newEnt('obj', m, x, y, z)
end
IMPL.CreateObjectNoOffset = IMPL.CreateObject
IMPL.CreatePed           = function(_, m, x, y, z) return newEnt('ped', m, x, y, z) end
IMPL.CreatePedInsideVehicle = function(v, _, m) local e = W.ents[v] or {} return newEnt('ped', m, e.x, e.y, e.z) end
IMPL.ClonePed            = function(p) local e = W.ents[p] or {} return newEnt('ped', 0, e.x, e.y, e.z) end
IMPL.CreateVehicle       = function(m, x, y, z) return newEnt('veh', m, x, y, z) end
local function deleteEnt(h) W.ents[h] = nil end
IMPL.DeleteEntity        = deleteEnt
IMPL.DeleteObject        = deleteEnt
IMPL.DeletePed           = deleteEnt
IMPL.DeleteVehicle       = deleteEnt
local function setPos(h, x, y, z)
    local e = W.ents[h]
    if e and type(x) == 'number' then e.x, e.y, e.z = x, y, z or e.z end
end
IMPL.SetEntityCoords     = setPos
IMPL.SetEntityCoordsNoOffset = setPos
IMPL.SetPedCoordsKeepVehicle = setPos
IMPL.SetEntityHeading    = function(h, hd) local e = W.ents[h] if e then e.heading = hd end end
IMPL.AddBlipForCoord     = function(x, y, z)
    W.nextBlip = W.nextBlip + 1
    W.blips[W.nextBlip] = { x = x, y = y, z = z }
    return W.nextBlip
end
IMPL.AddBlipForRadius    = IMPL.AddBlipForCoord
IMPL.AddBlipForArea      = IMPL.AddBlipForCoord
IMPL.AddBlipForEntity    = function(h) local e = W.ents[h] or {} return IMPL.AddBlipForCoord(e.x, e.y, e.z) end
IMPL.DoesBlipExist       = function(b) return W.blips[b] ~= nil end
IMPL.RemoveBlip          = function(b) W.blips[b] = nil end
IMPL.SetBlipCoords       = function(b, x, y, z) local e = W.blips[b] if e then e.x, e.y, e.z = x, y, z end end
IMPL.AddMinimapOverlay   = function() W.handles = W.handles + 1 return W.handles end
IMPL.HasMinimapOverlayLoaded = T
IMPL.BeginScaleformMovieMethod = T
IMPL.BeginScaleformMovieMethodOnFrontend = T
IMPL.BeginScaleformMovieMethodOnFrontendHeader = T
IMPL.EndScaleformMovieMethodReturnValue = function() W.handles = W.handles + 1 return W.handles end
IMPL.IsScaleformMovieMethodReturnValueReady = T
IMPL.GetScaleformMovieMethodReturnValueInt = function() return 0 end
IMPL.GetScaleformMovieMethodReturnValueBool = F
IMPL.GetScaleformMovieMethodReturnValueString = function() return '' end
-- The primary timecycle slot (#399): -1 while it is empty, as on the engine, so
-- the storm grade finds it empty and takes it the way it does on a prod client.
IMPL.GetTimecycleModifierIndex = function() return W.tc or -1 end
IMPL.SetTimecycleModifier = function() W.tc = 1 end
IMPL.ClearTimecycleModifier = function() W.tc = nil end

-- s1-noload (THE WORLDS): every streamed asset is asked for and never arrives.
-- Answered before any file loads, because a stub is bound the first time its
-- native is called.
if WORLD.noLoad then
    for _, n in ipairs({
        'HasModelLoaded', 'HasAnimDictLoaded', 'HasClipSetLoaded', 'HasAnimSetLoaded',
        'HasStreamedTextureDictLoaded', 'HasNamedPtfxAssetLoaded', 'HasPtfxAssetLoaded',
        'HasScaleformMovieLoaded', 'HasScaleformMovieFilenameLoaded',
        'HasThisAdditionalTextLoaded', 'HasAdditionalTextLoaded', 'HasMinimapOverlayLoaded',
        'HasWeaponAssetLoaded', 'RequestScriptAudioBank',
    }) do IMPL[n] = F end
end

--- Defaults by verb, for the names IMPL does not know.
local function defaultImpl(name)
    if name:match('^Is') or name:match('^Has') or name:match('^Does') or name:match('^Was')
        or name:match('^Are') or name:match('^Can') or name:match('^Network[IHD][sao]') then
        return F
    end
    if name:match('Name') or name:match('Label') or name:match('String') then
        return function() return '' end
    end
    if name:match('^Get') or name:match('^Request') or name:match('^Create')
        or name:match('^Add') or name:match('^Start') or name:match('^Find') then
        return function() return 0 end
    end
    return function() end
end

--- --digest: a fingerprint of every Draw* call's arguments, in call order, so a
--- refactor that must not change the picture can be compared with the tree it
--- replaced (--root at the other checkout). Exact: each number by its bits.
local digest = { h = 0, n = 0 }
local spack, sunpack = string.pack, string.unpack
local function fold(h, v)
    local t = type(v)
    local x
    if t == 'number' then
        x = sunpack('j', spack('d', v + 0.0))
    elseif t == 'string' then
        x = #v
        for i = 1, #v do x = x * 31 + v:byte(i) end
    elseif t == 'boolean' then
        x = v and 1 or 2
    else
        x = 3
    end
    return (h * 1099511628211 + x) & 0x7fffffffffffffff
end

local natives = {}
local seenNative = {}
local function nativeFn(name)
    local f = natives[name]
    if f then return f end
    local body = IMPL[name] or defaultImpl(name)
    local isDraw = name:match('^Draw') ~= nil
    local heavyAlways = HEAVY[name] == true
    local onProp = HEAVY[name] == 'prop'
    local fingerprint = ARGS.digest and isDraw
    f = function(...)
        local b = curB
        local heavy = heavyAlways
        if onProp then
            local e = W.ents[(...)]
            heavy = e ~= nil and e.kind == 'obj'
        end
        b.n = b.n + 1
        if isDraw then b.d = b.d + 1 end
        if heavy then
            b.h = b.h + 1
            b.hb[name] = (b.hb[name] or 0) + 1
        end
        if b.c then
            TALLY.n = TALLY.n + 1
            if heavy then TALLY.h = TALLY.h + 1 end
        end
        local by = b.by
        by[name] = (by[name] or 0) + 1
        local cf = curF
        if cf then
            cf.n = cf.n + 1
            if heavy then
                cf.h = cf.h + 1
                cf.by[name] = (cf.by[name] or 0) + 1
            end
        end
        if fingerprint then
            local h = fold(digest.h, name)
            for i = 1, select('#', ...) do h = fold(h, (select(i, ...))) end
            digest.h, digest.n = h, digest.n + 1
        end
        -- WHAT THE STUB ALLOCATES IS THE ENGINE'S, not the caller's: moved off
        -- the running bucket by advancing its starting reading. No stub answers
        -- more than six values.
        local k0 = gcCount('count')
        local r1, r2, r3, r4, r5, r6 = body(...)
        local top = stack[#stack]
        if top then top.kb0 = top.kb0 + (gcCount('count') - k0) end
        return r1, r2, r3, r4, r5, r6
    end
    natives[name] = f
    seenNative[name] = true
    return f
end

--- Count a runtime crossing that is not a native in name but is one in cost:
--- TriggerEvent packs its arguments, an export call crosses Lua states.
local function countAs(name)
    local b = curB
    b.n = b.n + 1
    b.by[name] = (b.by[name] or 0) + 1
    local heavy = HEAVY[name] == true
    if heavy then
        b.h = b.h + 1
        b.hb[name] = (b.hb[name] or 0) + 1
    end
    if b.c then
        TALLY.n = TALLY.n + 1
        if heavy then TALLY.h = TALLY.h + 1 end
    end
    local cf = curF
    if cf then
        cf.n = cf.n + 1
        if heavy then
            cf.h = cf.h + 1
            cf.by[name] = (cf.by[name] or 0) + 1
        end
    end
end

-- ------------------------------------------------------------ the runtime ---

local threads = {}      -- { co, wake, key }
local handlers = {}     -- [event] = { fn, ... }
local commands = {}
local env

local function srcKey(fn, prefix)
    local info = debug.getinfo(fn, 'S')
    local file = (info.short_src or '?'):match('([^/\\]+)$') or '?'
    return ('%s %s:%d'):format(prefix, file, info.linedefined or 0)
end

--- @param src function|nil  whose code it runs, for --files (`fn` by default)
local function spawn(fn, delay, src)
    threads[#threads + 1] = {
        co = coroutine.create(fn), wake = NOW + (delay or 0), key = srcKey(fn, 'thread'),
        src = src or fn,
    }
end

local function Wait(ms)
    local co, main = coroutine.running()
    if main then return end
    coroutine.yield(ms or 0)
end

local function runThreads()
    local i = 1
    local n = #threads
    -- Threads created during this pass start next frame, as in the game.
    while i <= n do
        local th = threads[i]
        if th and not th.dead and th.wake <= NOW then
            enter(th.key, th.src)
            local ok, ms = coroutine.resume(th.co)
            leave()
            if not ok then
                th.dead = true
                local b = bucket(th.key)
                b.errs = (b.errs or 0) + 1
                if not b.errSaid then
                    b.errSaid = true
                    realPrint(('\27[33m[perf] %s errored: %s\27[0m'):format(th.key, tostring(ms)))
                end
            elseif coroutine.status(th.co) == 'dead' then
                th.dead = true
            else
                -- Wait(0) is next frame; Wait(n) is the first frame at or after n ms.
                th.wake = NOW + math.max(ms or 0, 1)
            end
        end
        i = i + 1
    end
    local live = {}
    for _, th in ipairs(threads) do if not th.dead then live[#live + 1] = th end end
    threads = live
end

--- Run every handler of `name`. Handlers are only ever flagged removed, never
--- taken out of the list, so walking it to its length at the start skips the
--- ones a handler adds without copying it: a copy would be the harness's
--- allocation charged to whoever fired the event.
local function fire(name, key, ...)
    local list = handlers[name]
    if not list then return end
    for i = 1, #list do
        local h = list[i]
        if not h.removed then call(key or ('event ' .. name), h.fn, ...) end
    end
end

--- What the server sends this client.
local function net(name, ...)
    fire(name, 'net ' .. name, ...)
end

-- ------------------------------------------------------------- the server ---
--
-- What the server, and the other resources br_core talks to, answer. A request
-- is answered on the NEXT frame, as a round trip would be. The work of answering
-- runs under '(server)', which no phase counts -- it is not br_core's -- and its
-- answer is delivered as the net event (or the local event) the client really
-- receives, which is br_core's and is counted.
local SERVER = {}      -- [server event] = fn(payload): what the server does with a request
local SIBLING = {}     -- [local event]  = fn(...): another resource's handler of it
local inbox = {}       -- answers due at the top of the next frame

--- Queue an answer: a net event, or with `isLocal` a local one.
local function reply(name, payload, isLocal)
    inbox[#inbox + 1] = { name = name, payload = payload, isLocal = isLocal }
end

--- Queue something another resource does next frame, as a function.
local function later(fn)
    inbox[#inbox + 1] = { fn = fn }
end

local function deliver()
    if #inbox == 0 then return end
    local due = inbox
    inbox = {}
    for i = 1, #due do
        local m = due[i]
        if m.fn then m.fn()
        elseif m.isLocal then fire(m.name, 'event ' .. m.name, m.payload)
        else net(m.name, m.payload) end
    end
end

local json = {}
do
    local function enc(v, out)
        local t = type(v)
        if t == 'table' then
            if #v > 0 or next(v) == nil then
                out[#out + 1] = '['
                for i = 1, #v do if i > 1 then out[#out + 1] = ',' end enc(v[i], out) end
                out[#out + 1] = ']'
            else
                out[#out + 1] = '{'
                local first = true
                for k, x in pairs(v) do
                    if not first then out[#out + 1] = ',' end
                    first = false
                    out[#out + 1] = ('%q:'):format(tostring(k))
                    enc(x, out)
                end
                out[#out + 1] = '}'
            end
        elseif t == 'string' then out[#out + 1] = ('%q'):format(v)
        elseif t == 'number' or t == 'boolean' then out[#out + 1] = tostring(v)
        else out[#out + 1] = 'null' end
    end
    function json.encode(v) local out = {} enc(v, out) return table.concat(out) end
    function json.decode() return nil end
end

local stateBag = setmetatable({}, { __index = {
    set = function(self, k, v) rawset(self, k, v) end,
} })

local RUNTIME = {
    Citizen = {
        CreateThread = function(fn) spawn(fn, 0) end,
        CreateThreadNow = function(fn) spawn(fn, 0) end,
        Wait = Wait,
        SetTimeout = function(ms, fn) spawn(function() Wait(ms) fn() end, 0, fn) end,
        Await = function(p) return p and p.value end,
        Trace = function() end,
        InvokeNative = function() countAs('InvokeNative') end,
    },
    Wait = Wait,
    vector3 = vec3, vec3 = vec3,
    vector2 = function(x, y) return vec3(x, y, 0.0) end,
    vec2 = function(x, y) return vec3(x, y, 0.0) end,
    vector4 = function(x, y, z, w) local v = vec3(x, y, z) rawset(v, 'w', w) return v end,
    quat = function() return { 0, 0, 0, 1 } end,
    json = json,
    promise = { new = function() return { resolve = function(self, v) self.value = v end } end },
    LocalPlayer = { state = stateBag },
    GlobalState = {},
    AddEventHandler = function(name, fn)
        local list = handlers[name]
        if not list then list = {} handlers[name] = list end
        local h = { fn = fn, name = name }
        list[#list + 1] = h
        return h
    end,
    RemoveEventHandler = function(h) if type(h) == 'table' then h.removed = true end end,
    RegisterNetEvent = function(name, fn)
        if fn then return env.AddEventHandler(name, fn) end
    end,
    TriggerEvent = function(name, ...)
        countAs('TriggerEvent')
        local sib = SIBLING[name]
        if sib then call('(server)', sib, ...) end
        fire(name, nil, ...)
    end,
    TriggerServerEvent = function(name, ...)
        countAs('TriggerServerEvent')
        local h = SERVER[name]
        if h then call('(server)', h, ...) end
    end,
    TriggerLatentServerEvent = function(name, _, ...)
        countAs('TriggerServerEvent')
        local h = SERVER[name]
        if h then call('(server)', h, ...) end
    end,
    RegisterCommand = function(name, fn) commands[name] = fn end,
    RegisterKeyMapping = function() end,
    RegisterNUICallback = function() end,
    SendNUIMessage = function() countAs('SendNUIMessage') end,
    AddStateBagChangeHandler = function() end,
    -- Another resource's exports: each call is counted, and pma-voice's mute
    -- list is kept, since br_core reads it back before toggling (a toggle, not a
    -- setter, so an export that forgot would be asked to toggle every tick).
    exports = setmetatable({}, {
        __call = function() end,
        __index = function(_, res)
            return setmetatable({}, { __index = function(_, fnName)
                return function(_, a)
                    countAs('export ' .. tostring(res) .. '.' .. tostring(fnName))
                    if fnName == 'getMutedPlayers' then
                        local out = {}
                        for src in pairs(W.muted) do out[src] = true end
                        return out
                    elseif fnName == 'toggleMutePlayer' then
                        if W.muted[a] then W.muted[a] = nil else W.muted[a] = true end
                    end
                    return nil
                end
            end })
        end,
    }),
    source = 0,
}

-- Lua's own library, shared with the code under test.
local STD = {
    assert = assert, error = error, ipairs = ipairs, next = next, pairs = pairs,
    pcall = pcall, rawequal = rawequal, rawget = rawget, rawset = rawset, rawlen = rawlen,
    select = select, setmetatable = setmetatable, getmetatable = getmetatable,
    tonumber = tonumber, tostring = tostring, type = type, xpcall = xpcall,
    math = math, string = string, table = table, coroutine = coroutine, utf8 = utf8,
    os = os, io = io, debug = debug, unpack = table.unpack, load = load,
    collectgarbage = collectgarbage,
}

-- Names the loaded code itself defines as globals: classes in ScaleformUI, BR,
-- helpers. Never auto-stubbed, so `Foo = Foo or {}` still reads nil first.
local defined = {}

local printed = {}
env = setmetatable({}, { __index = function(t, k)
    local v = STD[k]
    if v ~= nil then return v end
    v = RUNTIME[k]
    if v ~= nil then return v end
    if type(k) == 'string' and k:match('^[A-Z][A-Za-z0-9_]*$') and not defined[k]
        and not k:match('^[A-Z][A-Z0-9_]*$') then
        local f = nativeFn(k)
        rawset(t, k, f)
        return f
    end
    return nil
end })
env._G = env
env.print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, ' ')
end

-- ------------------------------------------------------------- the files ---

local function manifestList(block)
    local fh = assert(io.open(FR .. 'br_core/fxmanifest.lua', 'r'))
    local src = fh:read('a')
    fh:close()
    local body = src:match(block .. '%s*(%b{})')
    local out = {}
    for line in body:gmatch('[^\n]+') do
        local entry = line:match("^%s*'([^']+)'")
        if entry then out[#out + 1] = entry end
    end
    return out
end

local function resolve(entry)
    local res, path = entry:match('^@([^/]+)/(.+)$')
    if not res then return FR .. 'br_core/' .. entry end
    for _, group in ipairs({ '[fivem-royale]', '[scaleformui]', '[voice]' }) do
        local p = RES .. group .. '/' .. res .. '/' .. path
        local fh = io.open(p, 'r')
        if fh then fh:close() return p end
    end
    error('cannot resolve ' .. entry)
end

local files = {}
for _, e in ipairs(manifestList('shared_scripts')) do files[#files + 1] = resolve(e) end
for _, e in ipairs(manifestList('client_scripts')) do files[#files + 1] = resolve(e) end

local sources = {}
for _, f in ipairs(files) do
    local fh = assert(io.open(f, 'rb'))
    local src = fh:read('a')
    fh:close()
    sources[f] = src
    for name in src:gmatch('\n%s*([A-Z][%w_]*)%s*=[^=]') do defined[name] = true end
    for name in src:gmatch('\n%s*function%s+([A-Z][%w_]*)[%.:%(]') do defined[name] = true end
    for name in src:gmatch('^%s*([A-Z][%w_]*)%s*=[^=]') do defined[name] = true end
end
-- A native whose name the scan above mistakes for a definition, because some
-- table has a field spelled the same: ScaleformUI's controls state carries
-- `IsUsingKeyboard = false,`, and its radial menu calls the native of that name.
defined.IsUsingKeyboard = nil

local BR

--- Every loop callback runs under its own name, so a native it calls is charged
--- to it. Hooked the moment main.lua has defined the registry and before any
--- other file registers, which leaves BR.Loop.register itself untouched.
local function hookLoop()
    local real = BR.Loop.register
    BR.Loop.register = function(band, name, fn)
        local key = band .. ' ' .. tostring(name)
        local function wrapped(dt)
            enter(key, fn)
            local ok, err = pcall(fn, dt)
            leave()
            if not ok then
                local b = bucket(key)
                b.errs = (b.errs or 0) + 1
                if not b.errSaid then
                    b.errSaid = true
                    realPrint(('\27[33m[perf] %s errored: %s\27[0m'):format(key, tostring(err)))
                end
                error(err, 0)
            end
        end
        return real(band, name, wrapped)
    end
end

local loadErrors = 0
for _, f in ipairs(files) do
    local src = sources[f]
    local name = '@' .. f
    local chunk, err = load(src, name, 't', env)
    if not chunk then
        -- CfxLua's `hash` literal, which stock Lua cannot parse. Same retry as
        -- tools/verify.sh's syntax gate, answering the hash rather than a string.
        local fixed = src:gsub('`([%w_]*)`', function(s) return tostring(jenkins(s)) end)
        chunk, err = load(fixed, name, 't', env)
    end
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        loadErrors = loadErrors + 1
    else
        local key = 'load ' .. (f:match('([^/]+)$'))
        enter(key)
        local ok, e2 = pcall(chunk)
        leave()
        if not ok then
            realPrint('\27[31mrun error\27[0m ' .. f .. ': ' .. tostring(e2))
            loadErrors = loadErrors + 1
        end
        if f:match('br_core/client/main%.lua$') then
            BR = env.BR
            hookLoop()
        end
    end
end
if loadErrors > 0 then os.exit(2) end

-- ------------------------------------------------------------- the scene ---
--
-- One player (server id 1) in a squad of four, in a 24-player match, walked
-- through a session the way the server would walk them: the payloads are built
-- by the same shared builders the server uses (BR.BuildStormRecord,
-- BR.BuildLootLayout, BR.BuildWarmupLayout, BR.BuildAirdropRecord) and
-- delivered as the net events the client really receives. Loot is never pushed:
-- the client asks for its cells as it moves, and the stub server answers.

local S = BR.State
local ME, MATES = 1, { 2, 3, 4 }
local DOWNED = 3                     -- the squadmate who is DBNO in the match
local PLAYERS = 24
local SEED = 393
local function poi(id)
    for _, p in ipairs(BR.Config.Map.POIs) do if p.id == id then return p end end
    return BR.Config.Map.POIs[1]
end
local LAND = poi('lsia')             -- a tier-3 hot drop: the densest loot
local ANCHOR = poi('vinewood') or LAND

-- THE SEASON THE SERVER SERVES. Every server publishes one at boot
-- (BR.Season.boot); Season 1 is the one that ships, and each world (THE WORLDS,
-- at the top) boots its own.
W.convars[BR.Season.SERVED] = WORLD.season

-- s1-padoff / s2-padoff: a body built on one of the pad's surveyed anchors
-- stands a meter east of it, as one knocked or thrown clear does.
if WORLD.padOff then
    local anchors = BR.Config.WarmupCrates.anchors or {}
    padShift = function(x, y)
        for _, a in ipairs(anchors) do
            if math.abs(x - a.x) < 0.01 and math.abs(y - a.y) < 0.01 then return x + 1.0, y end
        end
        return x, y
    end
end

--- The season in force once the world's lobby has run: its boot season, or the
--- one a live `brseason` moved it to.
local inForce = WORLD.live or WORLD.season

-- THE MUTANT, for --check's proof that the heavy count sees what it is for (see
-- the end of this file): a model hide made and taken down on every SLOW pass.
-- Only a run the first one loads for that proof is handed it.
if ARGS.mutant == 'heavy' then
    local hide, unhide = env.CreateModelHideExcludingScriptObjects, env.RemoveModelHide
    BR.Loop.register(BR.Loop.SLOW, 'perf.mutant', function()
        hide(0.0, 0.0, 0.0, 2.0, 0, true)
        unhide(0.0, 0.0, 0.0, 2.0, 0, false)
    end)
end
-- A plate's browser message sent on every TICK pass instead of on a change
-- (the #393 review's M14: client/yubikey.lua's setPrompt without its guard).
if ARGS.mutant == 'dui' then
    local send = env.SendDuiMessage
    BR.Loop.register(BR.Loop.TICK, 'perf.mutant', function() send(1, '{}') end)
end
-- Every laptop hidden fifty times over when the season moves (the review's
-- M12): 750 model hides at a switch, and nothing in any steady phase.
if ARGS.mutant == 'burst' then
    local hide = env.CreateModelHideExcludingScriptObjects
    BR.Season.onChange(function()
        for _ = 1, 750 do hide(0.0, 0.0, 0.0, 2.0, 0, true) end
    end)
end

local function setPed(h, x, y, z)
    local e = W.ents[h]
    e.x, e.y, e.z = x + 0.0, y + 0.0, z + 0.0
end

local rosterSeq = 0
local function entry(src, state)
    local squad = (src <= 4) and 1 or (1 + (src - 1) // 4)
    return { name = 'Player' .. src, squadId = squad, state = state, hp = 100.0,
             armour = 50.0, kills = 0, level = 10, placement = 0 }
end

local function rosterAll(stateOf)
    local r = {}
    for src = 1, PLAYERS do r[src] = entry(src, stateOf(src)) end
    return r
end

local function delta(list)
    rosterSeq = rosterSeq + 1
    net(BR.Net.ROSTER_DELTA, { seq = rosterSeq, deltas = list })
end

local function setStates(stateOf)
    local d = {}
    for src = 1, PLAYERS do
        d[#d + 1] = { op = 'update', src = src, e = { state = stateOf(src) } }
    end
    delta(d)
end

local function matchState(st, endsIn)
    net(BR.Net.STATE, { state = st, endsAt = gameMs() + (endsIn or 60000),
                        serverNow = gameMs(), mode = 'squad' })
end

-- ---------------------------------------------------------------- players ---

--- Server ids from..to.
local function others(from, to)
    local t = {}
    for src = from, to do t[#t + 1] = src end
    return t
end

--- Riders: peds carried with the local player every frame (the plane's
--- passengers, whose owners fly the same route their own clients do).
local riders = {}

--- Other players streamed in: real peds the client can see, one per server id
--- in `list`, the i-th placed at `at(i)`. With `ride`, `at` is an offset from
--- the local player that every frame keeps.
local function streamPlayers(list, at, ride)
    for src in pairs(W.players) do W.ents[W.players[src].ped] = nil end
    W.players, riders = {}, {}
    for i, src in ipairs(list) do
        local x, y, z = at(i)
        local ped = newEnt('ped', jenkins('mp_m_freemode_01'), x, y, z)
        W.players[src] = { ped = ped }
        if ride then riders[#riders + 1] = { ped = ped, dx = x, dy = y, dz = z } end
    end
end

local function carry()
    if #riders == 0 then return end
    local p = entPos(W.me)
    for i = 1, #riders do
        local r = riders[i]
        local e = W.ents[r.ped]
        if e then e.x, e.y, e.z = p.x + r.dx, p.y + r.dy, p.z + r.dz end
    end
end

--- A ring of players around (cx, cy, cz): the i-th 8 + 6i metres out.
local function ring(cx, cy, cz)
    return function(i)
        local a = i * 0.9
        return cx + math.cos(a) * (8 + i * 6), cy + math.sin(a) * (8 + i * 6), cz
    end
end

--- A seat in the plane's hold, as an offset from the local player.
local function seat(i)
    return (i % 4) * 1.5 - 2.25, (i // 4) * 2.0 - 6.0, 0.0
end

--- A sky of players around (cx, cy): spread over a few hundred metres and
--- between `lo` and `hi` metres up, as a drop spreads out.
local function sky(cx, cy, lo, hi)
    return function(i)
        local a = i * 2.39996
        local d = 40.0 + i * 22.0
        return cx + math.cos(a) * d, cy + math.sin(a) * d, lo + (hi - lo) * ((i * 7) % 23) / 22
    end
end

--- The mainland's own population once it streams in: ambient pedestrians and
--- parked cars around `x, y`, which the gamerules pools walk.
local ambient = {}
local function populate(x, y)
    for _, h in ipairs(ambient) do W.ents[h] = nil end
    ambient = {}
    for i = 1, 25 do
        local a = i * 2.4
        ambient[#ambient + 1] = newEnt('ped', jenkins('a_m_y_hipster_01'),
            x + math.cos(a) * (40 + i * 9), y + math.sin(a) * (40 + i * 9), 30.0)
    end
    for i = 1, 40 do
        local a = i * 1.7
        ambient[#ambient + 1] = newEnt('veh', jenkins('blista'),
            x + math.cos(a) * (30 + i * 7), y + math.sin(a) * (30 + i * 7), 30.0)
    end
end

-- ------------------------------------------------------------- the server ---

--- The stub server's loot: the match layout and the warmup pad's, each indexed
--- by cell, built the first time a client asks -- as server/loot.lua does.
local lootOf = {}
local function lootLayout(zone)
    local byCell = lootOf[zone]
    if byCell then return byCell end
    byCell = {}
    local entries = (zone == 'pad') and BR.BuildWarmupLayout(SEED) or BR.BuildLootLayout(SEED)
    -- THE PAD'S FOUR PERMANENT CRATES, one on each surveyed anchor, as
    -- server/warmupcrates.lua's place() stocks them. They used to be missing, so
    -- client/warmupcrates.lua's markers never found a crate to pin -- the miss
    -- s1-padoff and s2-padoff now measure on purpose (THE WORLDS).
    if zone == 'pad' then
        for i, a in ipairs(BR.Config.WarmupCrates.anchors or {}) do
            local st = BR.WarmupCrateStack(BR.Rng(SEED + i), a)
            st.id = 1000000 + i
            entries[#entries + 1] = st
        end
    end
    for _, e in ipairs(entries) do
        local k = BR.LootCellKeyAt(e.x, e.y)
        local list = byCell[k]
        if not list then list = {} byCell[k] = list end
        list[#list + 1] = e
    end
    lootOf[zone] = byCell
    return byCell
end

--- The stub server's own season and festive answer: the world's boot season,
--- moved by its live `brseason` (worldStart), and its festive sky. Not the
--- client's copy: the match emote scene's switch is the client's alone, as a
--- real server would hold a `brseason` typed mid-match for the lobby.
local serverSeason = tonumber(WORLD.season)
local serverFestive = false
--- `brfestive on` (server/loot.lua): the festive calendar forced. The sky
--- follows it only on a season with `snow` (server/world.lua's one fact).
local festiveForced = WORLD.festive == true or WORLD.live ~= nil

--- Does the season the stub server runs have this feature?
--- @param id string @return boolean
local function serverHas(id)
    local row = BR.Config.Seasons.features[id]
    return row ~= nil and serverSeason >= row.from
end

--- A fresh copy of a layout entry: the server sends a wire shape, never its own
--- table, and the client writes its own fields onto what it receives.
---
--- SEASON 2 CRATES (#395): while the season in force has crates2, every chest is
--- stamped with its look as the server indexes it (server/loot.lua's stampLook:
--- the tier of its rarity, the festive answer), so a Season 2 world builds its
--- boxes, as a Season 2 client does.
local function wire(e)
    local c = {}
    for k, v in pairs(e) do c[k] = v end
    if c.kind == 'chest' and c.bt == nil and BR.Crates and serverHas('crates2') then
        c.bt, c.bf = BR.Crates.tierOf(c.rarity), serverFestive or nil
    end
    return c
end

--- What this client is subscribed to: the zone and its cells.
local lootSub = { zone = nil, had = {} }
local lootStats = { asks = 0, adds = 0, gone = 0 }

-- server/loot.lua's LOOT_CELL, for one client: a player in a state that sees
-- loot is subscribed to the 3x3 block round the cell it names, and is sent the
-- entries of the cells it gained and told the ids of the cells it lost. Crossing
-- between the warmup pad and the match is a new world: the old block is dropped
-- whole. Every list is walked in a fixed order, so the answers are the same on
-- every run.
SERVER[BR.Net.LOOT_CELL] = function(d)
    if type(d) ~= 'table' then return end
    local st = S.me.state
    if not BR.Config.LootVisibleStates[st] then return end
    local cx, cy = math.tointeger(d.cx), math.tointeger(d.cy)
    if not cx or not cy then return end
    lootStats.asks = lootStats.asks + 1
    local zone = (st == BR.PlayerState.WARMUP) and 'pad' or 'match'
    -- A RESYNC (a client holding nothing in a cell it already named, as after
    -- STATE ENDED's forgetAll) re-seeds the block, as server/loot.lua does.
    if d.resync == true and lootSub.zone == zone then lootSub.had = {} end
    local gone = {}
    if lootSub.zone ~= zone then
        local keys = {}
        for k in pairs(lootSub.had) do keys[#keys + 1] = k end
        table.sort(keys)
        local old = lootSub.zone and lootLayout(lootSub.zone) or {}
        for _, k in ipairs(keys) do
            for _, e in ipairs(old[k] or {}) do gone[#gone + 1] = e.id end
        end
        lootSub.zone, lootSub.had = zone, {}
    end
    local byCell = lootLayout(zone)
    local want, order = {}, BR.LootCellsAround(cx, cy)
    for _, k in ipairs(order) do want[k] = true end
    local adds = {}
    for _, k in ipairs(order) do
        if not lootSub.had[k] then
            for _, e in ipairs(byCell[k] or {}) do adds[#adds + 1] = wire(e) end
        end
    end
    local lost = {}
    for k in pairs(lootSub.had) do if not want[k] then lost[#lost + 1] = k end end
    table.sort(lost)
    for _, k in ipairs(lost) do
        for _, e in ipairs(byCell[k] or {}) do gone[#gone + 1] = e.id end
    end
    lootSub.had = want
    lootStats.adds, lootStats.gone = lootStats.adds + #adds, lootStats.gone + #gone
    if #gone > 0 then reply(BR.Net.LOOT_GONE, gone) end
    if #adds > 0 then reply(BR.Net.LOOT_ADD, adds) end
end

--- br_environment's claim on the sky (br_environment/client/ipl.lua's wantSky):
--- a client event into br_core, where client/world.lua resolves it with the
--- storm's and the console's and writes the winner. A ROLE since #399 --
--- `lobby` while the island rests, `cover` while the bus boards and climbs,
--- `base` once it is released -- which world.lua reads for the festive sky. The
--- session used to make no claim at all, so world.lua never wrote a sky here,
--- festive or not.
local function island(name, blend)
    fire('br:world:island', 'event br:world:island', name, blend)
end

-- br_environment: asked to release the lobby island once the plane is out over
-- the water, it swaps the world and says so, and claims the base sky for the
-- ten seconds to the doors (ipl.lua's applyIsland).
SIBLING['br:env:releaseIsland'] = function()
    reply('br:env:world', false, true)
    later(function() island('base', 10.0) end)
end

--- The densest spot of the match's loot near (x, y): the entry with the most
--- others within glow range, so the render walk has real work in front of it.
local function denseSpot(x, y)
    local byCell = lootLayout('match')
    local list = {}
    for _, k in ipairs(BR.LootCellsAround(BR.LootCellOf(x, y))) do
        for _, e in ipairs(byCell[k] or {}) do list[#list + 1] = e end
    end
    local best, bestN = nil, -1
    local g2 = BR.Config.Loot.glowDistance * BR.Config.Loot.glowDistance
    for _, a in ipairs(list) do
        local n = 0
        for _, b in ipairs(list) do
            if BR.Dist2(a.x, a.y, b.x, b.y) <= g2 then n = n + 1 end
        end
        if n > bestN then best, bestN = a, n end
    end
    return best
end

-- ---------------------------------------------------------------- the bus ---

--- The flight, as server/bus.lua plans and stamps it: parked, the roll from
--- the spawn to wheels-up, the climb to cruise height, the ocean at cruise speed
--- to the coast -- where the doors open -- and then the tour over the mainland at
--- drop speed, the city belt and on to mid-map. Speeds are smoothed both ways at
--- maxAccel and the clock is stamped off them, as BR.Bus.depart does.
local function busRoute(t0)
    local C = BR.Config.Bus
    local pts = {}
    local function push(x, y, z, v)
        pts[#pts + 1] = { x = x + 0.0, y = y + 0.0, z = z + 0.0, v = v + 0.0 }
    end
    local function run(x0, y0, z0, x1, y1, z1, v0, v1, n)
        for i = 1, n do
            local k = i / n
            push(x0 + (x1 - x0) * k, y0 + (y1 - y0) * k, z0 + (z1 - z0) * k,
                 v0 + (v1 - v0) * k)
        end
    end
    local sp, rp = C.spawn, C.rotatePoint
    push(sp.x, sp.y, sp.z, 1.0)
    run(sp.x, sp.y, sp.z, rp.x, rp.y, sp.z, 1.0, C.rollSpeed, 4)
    local rotateIdx = #pts
    local dx, dy = rp.x - sp.x, rp.y - sp.y
    local len = math.sqrt(dx * dx + dy * dy)
    dx, dy = dx / len, dy / len
    local cx, cy = rp.x + dx * C.climbDist, rp.y + dy * C.climbDist
    run(rp.x, rp.y, sp.z, cx, cy, C.altitude, C.rollSpeed, C.climbSpeed, 10)
    local coast = C.legs[1][2][1]
    run(cx, cy, C.altitude, coast.x, coast.y, C.altitude, C.climbSpeed,
        math.max(C.cruiseSpeed, C.climbSpeed), 20)
    local jumpIdx = #pts
    local px, py = coast.x, coast.y
    for _, wp in ipairs({ C.legs[2][3][1], C.legs[3][1][1] }) do
        local n = math.max(1, math.floor(BR.Dist(px, py, wp.x, wp.y) / C.speed))
        run(px, py, C.altitude, wp.x, wp.y, C.altitude, C.speed, C.speed, n)
        px, py = wp.x, wp.y
    end
    local closeIdx = #pts

    local amax = C.maxAccel or 9.0
    for i = 2, #pts do
        local d = BR.Dist(pts[i - 1].x, pts[i - 1].y, pts[i].x, pts[i].y)
        local cap = math.sqrt(pts[i - 1].v ^ 2 + 2 * amax * d)
        if pts[i].v > cap then pts[i].v = cap end
    end
    for i = #pts - 1, 1, -1 do
        local d = BR.Dist(pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
        local cap = math.sqrt(pts[i + 1].v ^ 2 + 2 * amax * d)
        if pts[i].v > cap then pts[i].v = cap end
    end
    local clockMs = t0 + (C.boardSeconds or 5) * 1000
    for i, p in ipairs(pts) do
        if i > 1 then
            local q = pts[i - 1]
            clockMs = clockMs + BR.Dist(q.x, q.y, p.x, p.y)
                / math.max(1.0, (q.v + p.v) * 0.5) * 1000.0
        end
        p.t = math.floor(clockMs)
    end
    return {
        points = pts, waypoints = {}, legs = { 2, 3, 1, 1 },
        jumpIdx = jumpIdx, closeIdx = closeIdx, rotateIdx = rotateIdx,
        alt = C.altitude, heading = BR.GtaHeading(BR.Bearing(sp.x, sp.y, rp.x, rp.y)),
        timed = true, tStart = pts[1].t, rotateAt = pts[rotateIdx].t,
        jumpFrom = pts[jumpIdx].t, doorsClose = pts[closeIdx].t, tEnd = pts[#pts].t,
        sx = sp.x, sy = sp.y,
    }
end

local stormRec
local function stormPhase(phase, cx0, cy0, r0, cx1, cy1, r1, waitS, shrinkS, into)
    stormRec = BR.BuildStormRecord(phase, cx0, cy0, r0, cx1, cy1, r1,
        gameMs() - (into or 0), waitS * 1000, shrinkS * 1000,
        BR.Config.Storm.phases[phase].dps, SEED)
    net(BR.Net.STORM_SYNC, stormRec)
end

local function circleOne()
    local first = BR.Config.Storm.phases[1].radius
    return { cx = LAND.x + 900.0, cy = LAND.y + 1400.0, r = first, seed = SEED }
end

local function openingR(ax, ay)
    local cfg = BR.Config.Storm
    local A = cfg.mapAABB
    local r = cfg.radius0
    r = math.max(r, BR.Dist(ax, ay, A.min.x, A.min.y))
    r = math.max(r, BR.Dist(ax, ay, A.min.x, A.max.y))
    r = math.max(r, BR.Dist(ax, ay, A.max.x, A.min.y))
    r = math.max(r, BR.Dist(ax, ay, A.max.x, A.max.y))
    return r + (cfg.openMargin or 200.0)
end

local route

local function squadPos()
    local e = W.ents[W.me]
    local list = { { src = ME, name = 'Player1', x = e.x, y = e.y, state = S.me.state,
                     hp = 100, armour = 50, level = 10, i = 1 } }
    local off = { [2] = { 20, 0 }, [3] = { 0, 25 }, [4] = { -30, 0 } }
    for i, src in ipairs(MATES) do
        local r = S.roster[src] or {}
        list[#list + 1] = { src = src, name = 'Player' .. src, x = e.x + off[src][1],
            y = e.y + off[src][2], state = r.state, hp = (r.state == BR.PlayerState.DBNO) and 0 or 100,
            armour = 0, level = 10, i = i + 1,
            bleedEndsAt = (r.state == BR.PlayerState.DBNO) and (gameMs() + 60000) or nil }
    end
    net(BR.Net.SQUAD_POS, list)
end

local function lobbyStatus()
    local players = {}
    for src = 1, PLAYERS do
        players[#players + 1] = { src = src, name = 'Player' .. src, inParty = src <= 4,
            leader = src == 1, inMatch = S.match.state ~= BR.MatchState.WAITING,
            queued = false }
    end
    net(BR.Net.LOBBY_STATUS, { queued = 0, needed = 2, connected = PLAYERS, mode = 'squad',
        ids = {}, players = players })
end

local function digestFeed()
    net(BR.Net.DIGEST, { alive = 16, squadsAlive = 4, state = S.match.state, mode = 'squad',
        endsAt = S.match.endsAt, serverNow = gameMs() })
end

--- The squadmate this player is spectating, or nil.
local watching = nil

--- server/spectate.lua's feed: where the watched player is.
local function spectateFeed()
    local pl = W.players[watching]
    local p = entPos(pl and pl.ped or W.me)
    net(BR.Net.SPECTATE_SET, { targetSrc = watching, name = 'Player' .. watching,
                               x = p.x, y = p.y, z = p.z })
end

--- What the server keeps sending on its own clock, whatever the phase.
local FEEDS = {
    { every = 500,  fn = lobbyStatus },
    { every = 500,  fn = digestFeed },
    { every = 1000, fn = function()
        local st = S.match.state
        if st == BR.MatchState.PLAYING then squadPos() end
    end },
    { every = 250, fn = function() if watching then spectateFeed() end end },
}

--- The server's mirror of this player's inventory: a carbine in slot 1 and a
--- sniper rifle in slot 2, with `active` in hand.
local function loadout(active)
    local slots = {}
    for i = 1, BR.Config.Loot.slots or 5 do slots[i] = false end
    local function weapon(id)
        local w = BR.Config.WeaponById[id]
        return { id = id, label = w.label, kind = BR.ItemKind.WEAPON, rarity = w.rarity,
                 count = 1, clip = w.clip, pool = w.ammo }
    end
    slots[1], slots[2] = weapon('carbinerifle'), weapon('sniperrifle')
    local ammo = {}
    for _, pool in ipairs(BR.Config.AmmoOrder) do ammo[pool] = 120 end
    return { slots = slots, ammo = ammo, active = active }
end

--- Hold or release a bound action's key, by its command.
local function holdKey(command, down)
    local code = BR.Keys.boundTo(command)
    if code then W.keys[code] = down or nil end
end

--- Where the player stood before a scene moved them, so the next scene starts
--- from the same place.
local home = nil
local function stepTo(x, y, z)
    local p = entPos(W.me)
    home = { x = p.x, y = p.y, z = p.z }
    setPed(W.me, x, y, z)
end
local function stepBack()
    if home then setPed(W.me, home.x, home.y, home.z) end
    home = nil
end

-- ----------------------------------------------------------------- driver ---

local function followCam()
    local p = entPos(W.me)
    local h = math.rad(W.cam.rz)
    W.cam.x, W.cam.y, W.cam.z = p.x + math.sin(h) * 4.0, p.y - math.cos(h) * 4.0, p.z + 1.5
end

--- One frame: last frame's answers arrive, the riders move with the plane, the
--- camera with the player, the server's feeds go out on their clocks, and every
--- thread due wakes.
local function frame()
    NOW = NOW + FRAME_MS
    W.frameNo = W.frameNo + 1
    deliver()
    carry()
    followCam()
    for _, f in ipairs(FEEDS) do
        if not f.at or NOW >= f.at then
            f.at = (f.at or NOW) + f.every
            f.fn()
        end
    end
    runThreads()
end

--- THE WORLD'S OWN START, at the end of the lobby's setup (THE WORLDS, at the
--- top). s2-festive: the festive sky is on (server/world.lua sends the one
--- fact). s1-live, the owner's 2026-10-06: `brfestive on` while Season 2 is
--- still in force -- the festive sky and its white ground arrive -- two seconds
--- of it, then `brseason 1` applies at the boundary (server/season.lua):
--- br_seasonServed and SEASON_SWITCHED arrive, each on its own, and the festive
--- sky is read again and sent off with the season that had it.
local function worldStart()
    if WORLD.festive then
        serverFestive = true
        net(BR.Net.WORLD_SET, { festive = true })
    end
    if WORLD.live then
        net(BR.Net.WORLD_SET, { festive = true })
        for _ = 1, 120 do frame() end
        serverSeason = tonumber(WORLD.live)
        W.convars[BR.Season.SERVED] = WORLD.live
        net(BR.Net.SEASON_SWITCHED, { season = serverSeason, by = 'perf' })
        net(BR.Net.WORLD_SET, {})
    end
end

-- ----------------------------------------------------------------- phases ---
--
-- In session order. `setup` runs once at the phase boundary and is not
-- measured; `settle` frames run unmeasured after it so one-shot work (model
-- loads, the storm's shape builds) does not land in the steady state.

local PHASES = {
    { id = 'lobby', settle = 120, setup = function()
        local L = BR.Config.Match.lobbyPos
        setPed(W.me, L.x, L.y, L.z)
        W.cam.x, W.cam.y, W.cam.z = L.x, L.y - 4.0, L.z + 1.0
        net(BR.Net.SNAPSHOT, {
            roster = rosterAll(function() return BR.PlayerState.LOBBY end),
            match = { state = BR.MatchState.WAITING, mode = 'squad', endsAt = 0 },
            alive = 0, squadsAlive = 0, seq = 0, serverNow = gameMs(),
        })
        matchState(BR.MatchState.WAITING)
        island('lobby', 0.0)
        worldStart()
    end },
    { id = 'warmup', settle = 240, setup = function()
        local P = BR.Config.Match.warmupPos
        setPed(W.me, P.x, P.y, P.z)
        W.cam.x, W.cam.y, W.cam.z = P.x, P.y - 4.0, P.z + 1.5
        streamPlayers(others(2, 9), ring(P.x, P.y, 30.0))
        env.TriggerEvent('br:env:world', true)
        matchState(BR.MatchState.WARMUP, 90000)
        setStates(function() return BR.PlayerState.WARMUP end)
        net(BR.Net.STORM_PREVIEW, circleOne())
    end },
    { id = 'plane boarding', settle = 120, setup = function()
        matchState(BR.MatchState.BUS, 240000)
        -- The island's haze for the swap (ipl.lua's followState).
        island('cover', 5.0)
        setStates(function() return BR.PlayerState.BUS end)
        route = busRoute(gameMs())
        net(BR.Net.BUS_ROUTE, route)
        W.cam.rz = -90.0      -- looking along the flight, due east
        -- Everyone in the match is aboard, in the hold around this player.
        streamPlayers(others(2, PLAYERS), seat, true)
    end },
    { id = 'plane cruise', settle = 60, setup = function()
        -- THE DOORS-OPEN WINDOW: wheels-up, the island released over the water
        -- (bus.board asks br_environment, which answers), the ocean crossed, and
        -- three seconds past the coast where the doors open -- at cruise height
        -- and drop speed over the mainland, every rider still aboard and the
        -- loot below being asked for as the plane crosses its cells.
        while gameMs() < route.jumpFrom + 3000 do frame() end
        local x, y = BR.PathPosAt(route.points, gameMs())
        populate(x, y)
    end },
    { id = 'freefall', settle = 120, setup = function()
        local x, y, z = BR.PathPosAt(route.points, gameMs())
        setPed(W.me, x, y, z - 5.0)
        W.chute = 3
        -- The rest jumped around the same stretch: falling or gliding nearby.
        streamPlayers(others(2, PLAYERS), sky(x, y, z - 300.0, z - 20.0))
        setStates(function(src)
            if src == ME then return BR.PlayerState.FREEFALL end
            return (src % 2 == 0) and BR.PlayerState.FREEFALL or BR.PlayerState.GLIDE
        end)
    end },
    { id = 'chute', settle = 60, setup = function()
        local e = W.ents[W.me]
        e.x, e.y, e.z = LAND.x, LAND.y, 300.0
        W.chute = 2
        streamPlayers(others(2, PLAYERS), sky(LAND.x, LAND.y, 60.0, 380.0))
        setStates(function(src)
            if src == ME then return BR.PlayerState.GLIDE end
            return (src % 3 == 0) and BR.PlayerState.ALIVE or BR.PlayerState.GLIDE
        end)
    end },
    { id = 'match', settle = 240, setup = function()
        setPed(W.me, LAND.x, LAND.y, LAND.z)
        W.chute = nil
        W.cam.rz = 0.0        -- facing north, up the map
        matchState(BR.MatchState.PLAYING, 1800000)
        -- THE FESTIVE MATCH SKY (#399): under the festive sky a match's weather
        -- cycles, drawn by the server (server/world.lua), its first turn as the
        -- match starts PLAYING.
        if serverFestive and serverHas('snow') then
            net(BR.Net.WORLD_CYCLE, { weather = 'SNOW' })
        end
        local stateOf = function(src)
            if src == DOWNED then return BR.PlayerState.DBNO end
            if src > 16 then return BR.PlayerState.OUT end
            return BR.PlayerState.ALIVE
        end
        setStates(stateOf)
        streamPlayers(others(2, 9), ring(LAND.x, LAND.y, 30.0))
        populate(LAND.x, LAND.y)
        local c1 = circleOne()
        stormPhase(1, ANCHOR.x, ANCHOR.y, openingR(ANCHOR.x, ANCHOR.y),
                   c1.cx, c1.cy, c1.r, 120, 240, 30000)
        -- Stand where the loot is thickest; the client asks for its cells.
        local spot = denseSpot(LAND.x, LAND.y)
        if spot then setPed(W.me, spot.x + 1.5, spot.y + 1.0, spot.z or LAND.z) end
        -- A carbine in hand and a sniper rifle on the bar.
        net(BR.Net.INV_SET, loadout(1))
        squadPos()
        local t0 = gameMs()
        net(BR.Net.AIRDROP_SYNC, BR.BuildAirdropRecord(1,
            { id = LAND.id, x = LAND.x + 150.0, y = LAND.y - 80.0, z = LAND.z },
            260.0, t0, t0 + 60000, 90.0, t0 + 15000))
    end },

    -- ═══ THE MATCH, PLAYED: each of these is the passive match above with one
    --     thing the player does, so the callbacks that only run while they do
    --     it are measured and held to a budget too ═══
    { id = 'match aim', settle = 60, setup = function()
        -- Down the sniper's scope: the rifle in hand, the aim button held, the
        -- camera zoomed in.
        net(BR.Net.INV_SET, loadout(2))
        W.aiming, W.controls[25], W.cam.fov = true, true, 8.0
    end, after = function()
        W.aiming, W.controls[25], W.cam.fov = false, nil, nil
        net(BR.Net.INV_SET, loadout(1))
    end },
    { id = 'match pings', settle = 60, setup = function()
        -- The whole squad has a marker down, near and across the map.
        for i, src in ipairs({ ME, 2, 3, 4 }) do
            net(BR.Net.MARKER_SYNC, { owner = src, i = i,
                x = LAND.x + 300.0 * i, y = LAND.y + 900.0 * i })
        end
    end, after = function()
        for _, src in ipairs({ ME, 2, 3, 4 }) do
            net(BR.Net.MARKER_SYNC, { owner = src, op = 'clear' })
        end
    end },
    { id = 'match drive', settle = 60, setup = function()
        -- At the wheel of a car, boost held.
        local p = entPos(W.me)
        W.veh = newEnt('veh', jenkins('sultan'), p.x, p.y, p.z)
        holdKey('brboost', true)
    end, after = function()
        holdKey('brboost', false)
        if W.veh then W.ents[W.veh] = nil end
        W.veh = nil
    end },
    { id = 'match revive', settle = 60, setup = function()
        -- Kneeling at the downed squadmate, the interact key held.
        local m = entPos(W.players[DOWNED].ped)
        stepTo(m.x + 1.0, m.y, m.z)
        holdKey('brinteract', true)
    end, after = function()
        holdKey('brinteract', false)
        stepBack()
    end },
    { id = 'match ptt', settle = 60, setup = function()
        -- Talking to the squad: push-to-talk held.
        holdKey('brptt', true)
    end, after = function()
        holdKey('brptt', false)
    end },
    { id = 'match loot', settle = 0, setup = function()
        -- Opening a chest: stood at the nearest one, facing it, interact held.
        -- No settle: the hold is a second long, and it is what is measured.
        local p, best, bestD = entPos(W.me), nil, math.huge
        local byCell = lootLayout('match')
        for _, k in ipairs(BR.LootCellsAround(BR.LootCellOf(p.x, p.y))) do
            for _, e in ipairs(byCell[k] or {}) do
                local d = BR.Dist2(p.x, p.y, e.x, e.y)
                if e.kind == 'chest' and d < bestD then best, bestD = e, d end
            end
        end
        if best then
            stepTo(best.x, best.y - 1.2, best.z or LAND.z)
            W.cam.rz = 0.0
        end
        holdKey('brinteract', true)
    end, after = function()
        holdKey('brinteract', false)
        stepBack()
    end },

    { id = 'match sweep', settle = 60, setup = function()
        local c1 = circleOne()
        stormPhase(1, ANCHOR.x, ANCHOR.y, openingR(ANCHOR.x, ANCHOR.y),
                   c1.cx, c1.cy, c1.r, 120, 240, 120000 + 100000)
    end },
    { id = 'match late', settle = 120, setup = function()
        -- Later on: the downed squadmate has been picked up. A long hold, so
        -- the scenes after this one are all inside it.
        delta({ { op = 'update', src = DOWNED, e = { state = BR.PlayerState.ALIVE } } })
        local p2, p3 = BR.Config.Storm.phases[2], BR.Config.Storm.phases[3]
        stormPhase(3, LAND.x + 200.0, LAND.y + 300.0, p2.radius,
                   LAND.x + 300.0, LAND.y + 100.0, p3.radius, 300, 90, 30000)
        -- And the festive match sky's next turn, minutes on.
        if serverFestive and serverHas('snow') then
            net(BR.Net.WORLD_CYCLE, { weather = 'BLIZZARD' })
        end
    end },
    { id = 'match outside', settle = 60, setup = function()
        -- Caught outside the storm: well past the zone's edge.
        stepTo(stormRec.cx0 + stormRec.r0 + 250.0, stormRec.cy0, LAND.z)
    end, after = function()
        stepBack()
    end },
    { id = 'match emote', settle = 60, setup = function()
        -- Season 2's emote wheel, open: the dev-mode brseason switch, then the
        -- wheel key held.
        --
        -- A FRAME BETWEEN THE TWO, as a player has: the season lands, and then
        -- they press. Since #393 the wheel key goes unread while emotes are
        -- off, and a key first read on the frame it is already down is adopted
        -- as held rather than pressed -- so a press in the same frame as the
        -- switch would measure a wheel that never opened.
        W.convars[BR.Season.SERVED] = '2'
        net(BR.Net.SEASON_SWITCHED, { season = 2, by = 'perf' })
        frame()
        holdKey('bremotewheel', true)
    end, after = function()
        holdKey('bremotewheel', false)
        -- Back to the world's season (Season 1 in s1 and s1-live).
        W.convars[BR.Season.SERVED] = inForce
        net(BR.Net.SEASON_SWITCHED, { season = tonumber(inForce), by = 'perf' })
    end },
    { id = 'match downed', settle = 60, setup = function()
        -- Knocked: down, crawling and bleeding out.
        delta({ { op = 'update', src = ME, e = { state = BR.PlayerState.DBNO } } })
        net(BR.Net.DBNO_SET, { downed = true, bleedEndsAt = gameMs() + 90000 })
    end },
    { id = 'match spectate', settle = 120, setup = function()
        -- Bled out, and watching a squadmate on the server's feed.
        net(BR.Net.DBNO_SET, { downed = false })
        delta({ { op = 'update', src = ME, e = { state = BR.PlayerState.OUT } } })
        watching = 2
        spectateFeed()
    end },
    { id = 'match terminal', settle = 60, setup = function()
        -- Back on their feet (a Reboot, terminals wave C) with a Yubikey, at a
        -- terminal `brterminal place` stood where they are, forced online: the
        -- plate in reach every frame, the blips on both maps every pass. Season
        -- 1 has no terminals, so there this is the late match standing still.
        watching = nil
        net(BR.Net.SPECTATE_SET, { stop = true })
        delta({ { op = 'update', src = ME, e = { state = BR.PlayerState.ALIVE } } })
        local p = entPos(W.me)
        net(BR.Net.TERMINAL_SITES, {
            placed = { { id = 'perf', x = p.x + 1.0, y = p.y, z = p.z, h = 0.0 } },
            removed = {}, forced = { 'perf' } })
        net(BR.Net.YUBIKEY_STATE, { held = true, squadUsed = false, squadMatch = true })
        -- AND TWO OF WAVE B'S FUNCTIONS OVER THEM, as a Season 2 server sends
        -- them (server/terminalfx/): a Power outage around this terminal, and
        -- Time & weather's RAIN inside the circle. Each writes the world once,
        -- on arrival; every pass after that must find nothing to do.
        if serverHas('terminals') then
            net(BR.Net.TERMINAL_POWER, { matchId = 1,
                list = { { kind = 'radius', x = p.x, y = p.y, r = 400.0 } } })
            net(BR.Net.TERMINAL_SKY, { matchId = 1, weather = 'RAIN' })
        end
    end },
    -- ROUND 5'S TOOLS FROM THE SKY (#396, 2026-10-06), at the same terminal,
    -- in their own world (s2-sky, THE WORLDS above) and no other: each is over
    -- inside its own window and takes itself down.
    { id = 'match vehicle drop', world = 's2-sky', settle = 30, setup = function()
        -- A Vehicle drop for this player: their client asked to look for
        -- somewhere to land the car (the search, once a second, for 8 s), and
        -- the car coming down 20 m off under the cargo chute, its blip on both
        -- maps -- the descent's FRAME callback carrying the copy for nine of
        -- the ten measured seconds, then gone.
        if not serverHas('terminals') then return end
        local p = entPos(W.me)
        net(BR.Net.TERMINAL_DROP_FIND, { nonce = 1, r = 40.0, minM = 6.0, everyMs = 1000, forMs = 8000 })
        local t0 = gameMs()
        net(BR.Net.TERMINAL_DROP, { matchId = 1, id = 1, netId = 777, x = p.x + 20.0, y = p.y,
            z = p.z, h = 0.0, tRelease = t0, tLand = t0 + 9000, alt = 120.0, blip = true })
    end, after = function()
        if serverHas('terminals') then net(BR.Net.TERMINAL_DROP, { matchId = 1, id = 1, off = true }) end
    end },
    { id = 'match airstrike', world = 's2-sky', settle = 30, setup = function()
        -- An Airstrike 30 m off, its warning nearly over as the scene starts:
        -- the circle and the flare, then its ten rockets falling and bursting
        -- over the next four seconds -- the FRAME callback carrying them, gone
        -- with the last -- and the circle off the map two seconds after.
        if not serverHas('terminals') then return end
        local p = entPos(W.me)
        local t0 = gameMs() + 2000
        local rockets = {}
        for i = 1, 10 do
            rockets[i] = { x = p.x + 30.0 + (i - 5) * 4.0, y = p.y + ((i % 3) - 1) * 6.0,
                           at = t0 + (i - 1) * 400 + 200 }
        end
        net(BR.Net.TERMINAL_STRIKE, { matchId = 1, id = 1, x = p.x + 30.0, y = p.y, r = 40.0,
            startsAt = t0, endsAt = rockets[10].at, rockets = rockets })
    end },
}

local function snapshot()
    local s = {}
    for k, b in pairs(buckets) do
        local by, hb = {}, {}
        for n, c in pairs(b.by) do by[n] = c end
        for n, c in pairs(b.hb) do hb[n] = c end
        s[k] = { n = b.n, d = b.d, h = b.h, kb = b.kb, calls = b.calls, by = by, hb = hb }
    end
    return s
end

--- --files: each client file's counts, as snapshot() takes the buckets'.
local function fileSnapshot()
    local s = {}
    for name, f in pairs(fileStats) do
        local by = {}
        for n, c in pairs(f.by) do by[n] = c end
        s[name] = { n = f.n, h = f.h, by = by }
    end
    return s
end

--- --files: per file over a window, natives per frame and heavy calls per
--- second, busiest first, with each heavy native per second.
local function fileDiff(a, b, frames)
    local rows = {}
    for name, nb in pairs(b) do
        local oa = a[name] or { n = 0, h = 0, by = {} }
        local dn = nb.n - oa.n
        if dn > 0 and name ~= '(harness)' then
            local by = {}
            for n, c in pairs(nb.by) do
                local d = c - (oa.by[n] or 0)
                if d > 0 then by[#by + 1] = { name = n, perSec = d * 60.0 / frames } end
            end
            table.sort(by, function(x, y)
                if x.perSec ~= y.perSec then return x.perSec > y.perSec end
                return x.name < y.name
            end)
            rows[#rows + 1] = { file = name, n = dn / frames, h = (nb.h - oa.h) * 60.0 / frames,
                                by = by }
        end
    end
    table.sort(rows, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        return x.file < y.file
    end)
    return rows
end

local function diff(a, b, frames)
    local rows = {}
    for k, nb in pairs(b) do
        local oa = a[k] or { n = 0, d = 0, h = 0, kb = 0, calls = 0, by = {}, hb = {} }
        local dn, dd, dkb = nb.n - oa.n, nb.d - oa.d, nb.kb - oa.kb
        local dh = nb.h - oa.h
        if (dn > 0 or dkb > 0) and counted(k) then
            local by = {}
            for n, c in pairs(nb.by) do
                local d = c - (oa.by[n] or 0)
                if d > 0 then by[#by + 1] = { name = n, n = d / frames } end
            end
            table.sort(by, function(x, y)
                if x.n ~= y.n then return x.n > y.n end
                return x.name < y.name
            end)
            -- Each heavy native by name, per second (a pose write counts only on
            -- a prop, so these are not read off `by`).
            local hby = {}
            for n, c in pairs(nb.hb) do
                local d = c - (oa.hb[n] or 0)
                if d > 0 then hby[#hby + 1] = { name = n, perSec = d * 60.0 / frames } end
            end
            table.sort(hby, function(x, y) return x.name < y.name end)
            -- Heavy calls PER SECOND: one a second is the regression they are for.
            rows[#rows + 1] = { key = k, n = dn / frames, d = dd / frames,
                                kb = dkb / frames, h = dh * 60.0 / frames, by = by, hby = hby }
        end
    end
    -- A TOTAL ORDER, so the sums below are taken in the same order on every run:
    -- pairs() walks string keys in an order Lua 5.4 seeds afresh each run.
    table.sort(rows, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        if x.kb ~= y.kb then return x.kb > y.kb end
        return x.key < y.key
    end)
    local tot = { n = 0, d = 0, kb = 0, h = 0 }
    for _, r in ipairs(rows) do
        tot.n, tot.d, tot.kb, tot.h = tot.n + r.n, tot.d + r.d, tot.kb + r.kb, tot.h + r.h
    end
    return rows, tot
end

collectgarbage('collect')
collectgarbage('stop')
local gcBase = collectgarbage('count')
local function gcMaybe()
    if collectgarbage('count') > gcBase + 262144 then
        collectgarbage('collect')
        collectgarbage('stop')
    end
end

curB = bucket('(harness)')
fire('onClientResourceStart', 'net onClientResourceStart', 'br_core')

local results = {}
for _, ph in ipairs(PHASES) do
  -- A SCENE OF ONE WORLD'S (`world`) is not played in any other.
  if ph.world == nil or ph.world == WORLD.id then
    enter('net setup ' .. ph.id)
    local ok, err = pcall(ph.setup)
    leave()
    if not ok then
        realPrint(('\27[31m[perf] setup of %s failed: %s\27[0m'):format(ph.id, tostring(err)))
        os.exit(2)
    end
    for _ = 1, ph.settle do frame() gcMaybe() end
    digest.h, digest.n = 0, 0
    local fileBefore = FILES and fileSnapshot() or nil
    local before = snapshot()
    local c0 = clock()
    for _ = 1, MEASURE_FRAMES do frame() gcMaybe() end
    local wall = (clock() - c0) * 1000.0 / MEASURE_FRAMES
    local rows, tot = diff(before, snapshot(), MEASURE_FRAMES)
    -- A WORLD THAT BUDGETS ONLY SOME SCENES (`measure`) plays the rest, so its
    -- match is the one they are written against, and records only those.
    if WORLD.measure == nil or WORLD.measure[ph.id] then
        results[#results + 1] = { id = phaseId(WORLD, ph.id), rows = rows, tot = tot, wall = wall,
                                  digest = ('%016x/%d'):format(digest.h, digest.n),
                                  files = FILES and fileDiff(fileBefore, fileSnapshot(),
                                      MEASURE_FRAMES) or nil }
    end
    if (ARGS.phase and ph.id == ARGS.phase) or ph.id == WORLD.upTo then break end
    -- A scene's `after` puts back what it changed, unmeasured, so the next one
    -- starts from the match it was written against.
    if ph.after then
        enter('net setup ' .. ph.id)
        local okA, errA = pcall(ph.after)
        leave()
        if not okA then
            realPrint(('\27[31m[perf] teardown of %s failed: %s\27[0m'):format(ph.id,
                tostring(errA)))
            os.exit(2)
        end
    end
  end
end

-- ----------------------------------------------------------------- changes ---
--
-- ═══ ONE-TIME WORK ON A CHANGE, BUDGETED ON ITS OWN (#393 review, 2026-10-06) ═══
--
-- A phase is measured after its setup and its settle frames, so the work a
-- change does once -- a season switch, the festive sky going on or off, its
-- match cycle turning, crates restyled, the match ending -- was never measured:
-- the owner's `brfestive on` and `brseason 1` ran inside the lobby's unmeasured
-- setup. And resmon's number for br_core is the mean of its last 64 frames, so
-- one frame that makes a few thousand calls reads, for a second, like a loop
-- that never stops.
--
-- So once the session has been played, each change below is made the way the
-- server makes it -- its messages landing at the top of one frame, in the
-- server's order -- and measured over that frame and the CHANGE_FRAMES after
-- it: three seconds, so three SLOW passes, the loot drain's rebuilds and each
-- sky blend's first write fall inside it. Four counts, as a phase has, but IN
-- TOTAL over the window, and the busiest frame on its own:
--
--   natives  every native the window made
--   heavy    the HEAVY calls among them
--   KB       allocated in the window
--   peak     natives in its busiest frame
--
-- IN BOTH DIRECTIONS, in every world that can make them: Season 2 to 1 and
-- back; the festive sky on and off and its match cycle turning; a switch with
-- crates in reach (server/loot.lua's reseason re-announcing every chest -- the
-- warmup pad's case in the game, since a switch never applies mid-match,
-- measured here on the match's denser loot); the match ending; the owner's own,
-- back in the lobby with a staged `brseason 1` applying in the same frame
-- (server/season.lua applies one on br:match:destroyed); and the other arrival
-- order -- br_seasonServed and SEASON_SWITCHED travel separately, so `the
-- value late` lands the message half a second before the value.
local changes = {}
--- A change's window and its budget's slack and counts (THE CHANGES; the slack
--- is explained with the phases', in the budget section).
local CHANGE = { window = 180 }
do
local CHANGE_FRAMES = CHANGE.window

--- Make one change and measure it: `send` runs at the top of the first frame
--- (as a message lands), `lateFn` at the top of frame `lateAt`.
--- @param label string @param send function @param lateAt integer|nil @param lateFn function|nil
local function measureChange(label, send, lateAt, lateFn)
    local before = snapshot()
    local peak, peakH = 0, 0
    later(send)
    for i = 1, CHANGE_FRAMES do
        if lateAt == i then later(lateFn) end
        local n0, h0 = TALLY.n, TALLY.h
        frame()
        gcMaybe()
        if TALLY.n - n0 > peak then peak = TALLY.n - n0 end
        if TALLY.h - h0 > peakH then peakH = TALLY.h - h0 end
    end
    -- diff() over one "frame" is the window's totals; its heavy is per second.
    local rows, tot = diff(before, snapshot(), 1)
    changes[#changes + 1] = { id = phaseId(WORLD, label), rows = rows, peakH = peakH,
        tot = { n = tot.n, h = tot.h / 60.0, kb = tot.kb, peak = peak } }
end

--- server/world.lua's BR.WorldSky.refresh: the festive sky read again and sent
--- to everybody when it moved -- each PLAYING match's cycle started before the
--- fact (on) or stopped after it (off), which is the order of its blend.
local function skyRefresh()
    local on = festiveForced and serverHas('snow')
    if on == serverFestive then return end
    serverFestive = on
    local playing = S.match.state == BR.MatchState.PLAYING
    if on then
        if playing then net(BR.Net.WORLD_CYCLE, { weather = 'SNOW' }) end
        net(BR.Net.WORLD_SET, { festive = true })
    else
        net(BR.Net.WORLD_SET, {})
        if playing then net(BR.Net.WORLD_CYCLE, {}) end
    end
end

--- `brfestive on|off`.
--- @param on boolean
local function brfestive(on)
    festiveForced = on
    skyRefresh()
end

--- server/loot.lua's BR.Loot.reseason, for this client: every chest in the
--- cells it holds, re-announced in one LOOT_ADD with the look the season now
--- gives it.
local function reseason()
    if not lootSub.zone then return end
    local byCell, keys, out = lootLayout(lootSub.zone), {}, {}
    for k in pairs(lootSub.had) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
        for _, e in ipairs(byCell[k] or {}) do
            if e.kind == 'chest' then out[#out + 1] = wire(e) end
        end
    end
    if #out > 0 then net(BR.Net.LOOT_ADD, out) end
end

--- server/season.lua's apply(): the season and br_seasonServed moved together,
--- every crate restyled, the festive sky read again, then SEASON_SWITCHED to
--- everybody. The value is replicated on its own; `late` sends it after.
--- @param n integer @param late boolean|nil
local function switchTo(n, late)
    local from = serverSeason
    serverSeason = n
    if not late then W.convars[BR.Season.SERVED] = tostring(n) end
    reseason()
    skyRefresh()
    net(BR.Net.SEASON_SWITCHED, { season = n, from = from, by = 'perf' })
end

--- The value a `late` switch held back.
local function valueLands()
    W.convars[BR.Season.SERVED] = tostring(serverSeason)
end

--- The match is over: the verdict. The server keeps the match's loot, and this
--- client's subscription to it, until the match is torn down.
local function matchEnds()
    watching = nil
    matchState(BR.MatchState.ENDED, 15000)
end

--- BR.Match.destroy: everybody back in the lobby, the match WAITING, the player
--- on the lobby mark under the island's sky.
local function backToLobby()
    lootSub.zone, lootSub.had = nil, {}
    W.chute, W.veh, W.aiming, W.cam.fov = nil, nil, false, nil
    local L = BR.Config.Match.lobbyPos
    setPed(W.me, L.x, L.y, L.z)
    streamPlayers({}, ring(L.x, L.y, L.z))
    setStates(function() return BR.PlayerState.LOBBY end)
    matchState(BR.MatchState.WAITING)
    island('lobby', 0.0)
end

--- The changes, from the end of the session (the match terminal scene).
local function playChanges()
    local inS2 = serverHas('crates2')
    local one, two = 1, 2
    if not inS2 then one, two = 2, 1 end
    local m = 'match: Season %d to %d, crates in reach'
    if inS2 then
        -- TIME & WEATHER LETS GO FIRST, unmeasured: its RAIN outranks the
        -- festive sky, and a flip under it writes no sky at all.
        net(BR.Net.TERMINAL_SKY, { matchId = 1 })
        for _ = 1, 120 do frame() gcMaybe() end
        if not festiveForced then
            measureChange('match: festive on', function() brfestive(true) end)
        end
        measureChange('match: the festive sky turns', function()
            net(BR.Net.WORLD_CYCLE, { weather = 'SNOWLIGHT' })
        end)
        measureChange('match: festive off', function() brfestive(false) end)
        measureChange('match: festive back on', function() brfestive(true) end)
    end
    measureChange(m:format(two, one), function() switchTo(one) end)
    measureChange(m:format(one, two), function() switchTo(two) end)
    measureChange('match: ended', matchEnds)
    if inS2 then
        -- THE OWNER'S, 2026-10-06: `brseason 1` staged in a Season 2 match,
        -- applied as it is torn down to the lobby.
        measureChange('lobby: back from the match, Season 2 to 1 applies', function()
            backToLobby()
            switchTo(1)
        end)
        measureChange('lobby: Season 1 to 2', function() switchTo(2) end)
        measureChange('lobby: festive off', function() brfestive(false) end)
        measureChange('lobby: festive on', function() brfestive(true) end)
        measureChange('lobby: Season 2 to 1, the value late',
            function() switchTo(1, true) end, 30, valueLands)
        measureChange('lobby: Season 1 to 2, the value late',
            function() switchTo(2, true) end, 30, valueLands)
    else
        measureChange('lobby: back from the match', backToLobby)
        measureChange('lobby: Season 1 to 2', function() switchTo(2) end)
        measureChange('lobby: Season 2 to 1', function() switchTo(1) end)
        measureChange('lobby: Season 1 to 2, the value late',
            function() switchTo(2, true) end, 30, valueLands)
        measureChange('lobby: Season 2 to 1, the value late',
            function() switchTo(1, true) end, 30, valueLands)
    end
end

-- Only after the whole session: a run stopped at a phase, or a world that
-- plays only part of it, has no match to change.
if not ARGS.phase and not WORLD.upTo then playChanges() end
end
collectgarbage('restart')

--- Every callback that threw under the model, as `key xN`, sorted.
--- @return string[]
local function harnessErrors()
    local errs = {}
    for k, b in pairs(buckets) do
        if (b.errs or 0) > 0 then errs[#errs + 1] = ('%s x%d'):format(k, b.errs) end
    end
    table.sort(errs)
    return errs
end

-- --------------------------------------------------------- every world ---
--
-- This run's world is measured. A run loaded for one more world hands its
-- numbers back here; the first run loads one fresh copy of this file for each
-- world after its own, in WORLDS order, and reports, writes or checks them all.

local run = { world = WORLD, results = results, changes = changes, errs = harnessErrors(),
              loot = { asks = lootStats.asks, adds = lootStats.adds, gone = lootStats.gone } }
if SUB then return run end

local runs = { run }
for i = 2, #runList do
    local chunk = assert(loadfile(SELF))
    runs[#runs + 1] = chunk({ world = runList[i].id, args = ARGS, self = SELF })
    chunk = nil
    collectgarbage('collect')
end

-- ----------------------------------------------------------------- report ---

local function fmt(n) return ('%.1f'):format(n) end

if not ARGS.check and not ARGS.rebaseline then
    local step = clockStep()
    realPrint(('br_core client, offline: %d measured frames per phase at 60 fps')
        :format(MEASURE_FRAMES))
    realPrint('natives, draws (Draw* natives) and KB allocated per frame, and heavy calls per second, '
        .. 'are exact and the same on every run.')
    realPrint(("Lua ms is the whole phase on this machine's PUC Lua, stubs included, read off a clock "
        .. 'that ticks %.3f ms: +/- %.4f ms/frame from the tick alone.'):format(step,
        step / MEASURE_FRAMES))
    realPrint("engine-side cost of a native (a DrawSpritePoly's triangles) is invisible here.")
    for _, rn in ipairs(runs) do
        realPrint('')
        realPrint(('######## world %s'):format(rn.world.id))
        for _, r in ipairs(rn.results) do
            realPrint('')
            realPrint(('== %-16s natives/frame %7s   draws/frame %6s   KB/frame %6.2f   heavy/s %6.2f   Lua ms/frame %6.3f')
                :format(r.id, fmt(r.tot.n), fmt(r.tot.d), r.tot.kb, r.tot.h, r.wall))
            if ARGS.digest then realPrint('   draw digest ' .. r.digest) end
            for i = 1, math.min(TOP, #r.rows) do
                local row = r.rows[i]
                local top = {}
                for j = 1, math.min(tonumber(ARGS.by) or 3, #row.by) do
                    top[#top + 1] = ('%s %s'):format(row.by[j].name, fmt(row.by[j].n))
                end
                realPrint(('   %-34s %7s  %6s draws  %6.2f KB   %s'):format(row.key, fmt(row.n),
                    fmt(row.d), row.kb, table.concat(top, ', ')))
            end
            -- EVERY HEAVY CALL, whoever made it, since one a second matters.
            local heavyRows = {}
            for _, row in ipairs(r.rows) do
                for _, b in ipairs(row.hby) do
                    heavyRows[#heavyRows + 1] = ('%s %s %.2f/s'):format(row.key, b.name, b.perSec)
                end
            end
            if #heavyRows > 0 then
                table.sort(heavyRows)
                realPrint('   heavy: ' .. table.concat(heavyRows, '; '))
            end
            if r.files then
                realPrint(('   %-26s %9s %10s %9s   %s'):format('by file', 'nat/frame',
                    'nat/s', 'heavy/s', 'heavy calls'))
                for _, f in ipairs(r.files) do
                    local hv = {}
                    for _, b in ipairs(f.by) do
                        hv[#hv + 1] = ('%s %.2f/s'):format(b.name, b.perSec)
                    end
                    realPrint(('   %-26s %9.2f %10.1f %9.2f   %s'):format(f.file, f.n,
                        f.n * 60.0, f.h, table.concat(hv, ', ')))
                end
            end
        end
        -- THE CHANGES (see that section): each one's window in total, and its
        -- busiest frame.
        for _, c in ipairs(rn.changes or {}) do
            realPrint('')
            realPrint(('-- change %-48s natives %7s  heavy %5s  KB %7.2f  busiest frame %5d natives, %d heavy')
                :format(c.id, fmt(c.tot.n), fmt(c.tot.h), c.tot.kb, c.tot.peak, c.peakH))
            for i = 1, math.min(TOP, #c.rows) do
                local row = c.rows[i]
                local top = {}
                for j = 1, math.min(tonumber(ARGS.by) or 3, #row.by) do
                    top[#top + 1] = ('%s %s'):format(row.by[j].name, fmt(row.by[j].n))
                end
                realPrint(('   %-34s %7s  %6.2f KB   %s'):format(row.key, fmt(row.n), row.kb,
                    table.concat(top, ', ')))
            end
            local heavyRows = {}
            for _, row in ipairs(c.rows) do
                for _, h in ipairs(row.hby) do
                    heavyRows[#heavyRows + 1] = ('%s %s %d'):format(row.key, h.name,
                        math.floor(h.perSec / 60.0 + 0.5))
                end
            end
            if #heavyRows > 0 then
                table.sort(heavyRows)
                realPrint('   heavy: ' .. table.concat(heavyRows, '; '))
            end
        end
        -- What the stub server did, so a scene that should have loot can be seen to.
        realPrint('')
        realPrint(('stub server, whole session: %d loot cell asks answered, %d entries added, %d gone')
            :format(rn.loot.asks, rn.loot.adds, rn.loot.gone))
        if #rn.errs > 0 then
            realPrint('')
            realPrint('errors (the harness, not the game -- fix the model): '
                .. table.concat(rn.errs, '; '))
        end
    end
end

-- ------------------------------------------------------------------ budget ---
--
-- THE GUARD. tools/perf_budget.lua records, per phase and per world, what the
-- tree measured when it was written, four ways: native calls, draws and
-- kilobytes allocated, each per frame, and heavy calls per second. --check
-- fails a phase that goes over any of them by more than SLACK, which is set so
-- that the smallest regression worth catching fails:
--
--   natives  2.5 a frame -- one more per-frame loop of three calls fails
--   draws    0.9 a frame -- one more draw call every frame fails
--   KB       0.9 a frame -- one more kilobyte allocated every frame fails
--   heavy    0.5 a second -- one more heavy call on every SLOW pass fails
--
-- FOUR COUNTS AND NOT ONE, because each regression this exists to stop shows in
-- a different one. A loop nothing gates is native calls. A wall quad, a marker or
-- a sprite that comes back is a draw, which the game pays for on the render
-- thread as well -- and a draw that replaced another native would leave the
-- native count where it was. A geometry rebuild every frame allocates and calls
-- no native at all: it is invisible to the other two and is what KB is for. And
-- a model hide, a sky write or a world scan repeated once a second is 0.02
-- natives a frame -- under any per-frame slack -- and a real cost to the
-- engine every second: that is what heavy is for (see HEAVY at the top).
--
-- STABLE BECAUSE IT IS EXACT. All four are counts, not timings: the clock is
-- the model's, math.random is seeded and the stub server answers in a fixed
-- order. The one wobble is main.lua starting its band threads in pairs() order,
-- which Lua seeds afresh each run, so a SLOW pass and the loot prop thread can
-- swap places within a frame: up to 0.1 natives a frame in the plane phases,
-- nothing in draws or KB. The slack is twenty-five times that. Lua time is not
-- budgeted at all: on this box it moves by tens of percent with whatever else is
-- running.
--
-- THE SLACK LIVES HERE AND NOT IN THE BUDGET FILE, which holds only what was
-- measured, so a rebaseline cannot loosen it and nobody edits it by hand.

local SLACK = { n = 2.5, d = 0.9, kb = 0.9, h = 0.5 }
local METRICS = {
    { key = 'n',  field = 'natives', unit = 'natives',     per = 'frame' },
    { key = 'd',  field = 'draws',   unit = 'draws',       per = 'frame' },
    { key = 'kb', field = 'kb',      unit = 'KB',          per = 'frame' },
    { key = 'h',  field = 'heavy',   unit = 'heavy calls', per = 'second' },
}

-- A CHANGE (THE CHANGES, above) IS HELD TO ITS WINDOW'S TOTALS, with a slack
-- of its own, set the same way: the smallest one-time regression worth
-- catching fails.
--
--   natives  25 in the window -- the fifteen laptop hides made twice fails
--   heavy     2 in the window -- one more sky, ground or hide write fails
--   KB       10 in the window -- a rebuild the change did not do before fails
--   peak     25 in the busiest frame -- the same burst landing in one frame
--
-- The wobble is up to 5 natives in a window and in its busiest frame (the
-- same band-thread order as above), 1 KB and no heavy call at all.
CHANGE.slack = { n = 25, h = 2, kb = 10, peak = 25 }
CHANGE.metrics = {
    { key = 'n',    field = 'natives', unit = 'natives',     per = 'window' },
    { key = 'h',    field = 'heavy',   unit = 'heavy calls', per = 'window' },
    { key = 'kb',   field = 'kb',      unit = 'KB',          per = 'window' },
    { key = 'peak', field = 'peak',    unit = 'natives',     per = 'busiest frame' },
}

--- The world a budgeted phase id belongs to: `<world>/<phase>`, or Season 1's
--- bare name.
--- @param id string @return string
local function worldOf(id)
    return id:match('^([%w%-]+)/') or 's1'
end

if ARGS.rebaseline then
    local lines = {
        '-- br_core\'s per-frame budget: what each phase measured, in each world (see',
        '-- THE WORLDS in tools/perf_client.lua), as native calls, draw calls (natives',
        '-- named Draw*) and kilobytes allocated per frame, and heavy calls (HEAVY)',
        '-- per second. `lua tools/perf_client.lua --check` (tools/verify.sh runs it)',
        ('-- fails a phase that goes over any of them by more than %.1f natives, %.1f'):format(
            SLACK.n, SLACK.d),
        ('-- draws or %.1f KB a frame, or %.1f heavy calls a second. Each change (THE'):format(
            SLACK.kb, SLACK.h),
        '-- CHANGES) is held to the totals of its window -- natives, heavy calls and KB --',
        ('-- and its busiest frame, by %d natives, %d heavy calls, %d KB and %d natives.'):format(
            CHANGE.slack.n, CHANGE.slack.h, CHANGE.slack.kb, CHANGE.slack.peak),
        '--',
        '-- WRITTEN, NOT EDITED: `lua tools/perf_client.lua --rebaseline` measures the',
        '-- tree and writes this file. The slack is in tools/perf_client.lua, not here.',
        '-- Rebaseline only for a change that is MEANT to cost more (or that costs',
        '-- less, to keep the guard tight), and say so in its commit. See docs/testing.md.',
        'return {',
        ('    frames = %d,'):format(MEASURE_FRAMES),
        '    phases = {',
    }
    local errs = {}
    for _, rn in ipairs(runs) do
        for _, r in ipairs(rn.results) do
            lines[#lines + 1] = ('        { id = %q, natives = %.3f, draws = %.3f, kb = %.3f, heavy = %.3f },')
                :format(r.id, r.tot.n, r.tot.d, r.tot.kb, r.tot.h)
        end
        for _, e in ipairs(rn.errs) do errs[#errs + 1] = rn.world.id .. ': ' .. e end
    end
    lines[#lines + 1] = '    },'
    lines[#lines + 1] = ('    changeFrames = %d,'):format(CHANGE.window)
    lines[#lines + 1] = '    changes = {'
    for _, rn in ipairs(runs) do
        for _, c in ipairs(rn.changes or {}) do
            lines[#lines + 1] = ('        { id = %q, natives = %.0f, heavy = %.0f, kb = %.2f, peak = %d },')
                :format(c.id, c.tot.n, c.tot.h, c.tot.kb, c.tot.peak)
        end
    end
    lines[#lines + 1] = '    },'
    lines[#lines + 1] = '}'
    if #errs > 0 then
        realPrint('\27[31mrefusing to write a budget over harness errors:\27[0m '
            .. table.concat(errs, '; '))
        os.exit(1)
    end
    local fh = assert(io.open(BUDGET_FILE, 'wb'))   -- LF on every platform
    fh:write(table.concat(lines, '\n'), '\n')
    fh:close()
    realPrint('wrote ' .. BUDGET_FILE)
    for _, rn in ipairs(runs) do
        for _, r in ipairs(rn.results) do
            realPrint(('   %-26s %7s natives  %6s draws  %6.2f KB  per frame  %6.2f heavy/s')
                :format(r.id, fmt(r.tot.n), fmt(r.tot.d), r.tot.kb, r.tot.h))
        end
        for _, c in ipairs(rn.changes or {}) do
            realPrint(('   %-58s %6.0f natives  %4.0f heavy  %7.2f KB  busiest %4d')
                :format(c.id, c.tot.n, c.tot.h, c.tot.kb, c.tot.peak))
        end
    end
end

--- Does phase result `r` go over budget row `b` on any count? The counts that
--- do, as { metric, value, ceiling }, and the ones the row has no number for.
--- @return table[] over, string[] missing
local function overBudget(r, b, metrics, slack)
    metrics, slack = metrics or METRICS, slack or SLACK
    local over, missing = {}, {}
    for _, m in ipairs(metrics) do
        local was = tonumber(b[m.field])
        if was == nil then
            missing[#missing + 1] = m.unit
        elseif r.tot[m.key] > was + slack[m.key] then
            over[#over + 1] = { m = m, value = r.tot[m.key], was = was, slack = slack[m.key] }
        end
    end
    return over, missing
end

-- In a function of its own: the main chunk is near Lua's 200 locals.
local function check()
    local want = {}
    for _, b in ipairs(budget.phases) do want[b.id] = b end
    local wantC = {}
    for _, b in ipairs(budget.changes or {}) do wantC[b.id] = b end
    local covered = {}
    for _, w in ipairs(runList) do covered[w.id] = true end
    local bad = 0
    if (budget.changes or budget.changeFrames) and budget.changeFrames ~= CHANGE.window then
        realPrint(('\27[31mFAIL\27[0m the budget measured changes over %s frames, this file over %d -- rebaseline')
            :format(tostring(budget.changeFrames), CHANGE.window))
        bad = bad + 1
    end
    for _, rn in ipairs(runs) do
        local good = 0
        for _, r in ipairs(rn.results) do
            local b = want[r.id]
            if not b then
                realPrint(('\27[31mFAIL\27[0m phase %q has no budget -- rebaseline'):format(r.id))
                bad = bad + 1
            else
                local over, missing = overBudget(r, b)
                for _, unit in ipairs(missing) do
                    realPrint(('\27[31mFAIL\27[0m %-26s has no %s budget -- rebaseline')
                        :format(r.id, unit))
                    bad = bad + 1
                end
                for _, o in ipairs(over) do
                    local m = o.m
                    bad = bad + 1
                    realPrint(('\27[31mFAIL\27[0m %-26s %8.2f %s/%s, budget %.2f (measured %.2f + %.1f)')
                        :format(r.id, o.value, m.unit, m.per, o.was + SLACK[m.key], o.was,
                            SLACK[m.key]))
                    -- The biggest contributors to the count that went over.
                    local top = {}
                    for _, row in ipairs(r.rows) do top[#top + 1] = row end
                    table.sort(top, function(x, y)
                        if x[m.key] ~= y[m.key] then return x[m.key] > y[m.key] end
                        return x.key < y.key
                    end)
                    for i = 1, math.min(5, #top) do
                        realPrint(('       %-34s %8.2f'):format(top[i].key, top[i][m.key]))
                    end
                end
                if #over == 0 and #missing == 0 then
                    good = good + 1
                    if not ARGS.quiet then
                        realPrint(('\27[32mok\27[0m   %-26s %7s natives  %6s draws  %6.2f KB  per frame  %6.2f heavy/s')
                            :format(r.id, fmt(r.tot.n), fmt(r.tot.d), r.tot.kb, r.tot.h))
                    end
                end
            end
            want[r.id] = nil
        end
        -- THE CHANGES, against their own rows and their own slack.
        local goodC = 0
        for _, c in ipairs(rn.changes or {}) do
            local b = wantC[c.id]
            if not b then
                realPrint(('\27[31mFAIL\27[0m change %q has no budget -- rebaseline'):format(c.id))
                bad = bad + 1
            else
                local over, missing = overBudget(c, b, CHANGE.metrics, CHANGE.slack)
                for _, unit in ipairs(missing) do
                    realPrint(('\27[31mFAIL\27[0m change %s has no %s budget -- rebaseline')
                        :format(c.id, unit))
                    bad = bad + 1
                end
                for _, o in ipairs(over) do
                    local m = o.m
                    bad = bad + 1
                    realPrint(('\27[31mFAIL\27[0m change %s: %.2f %s in its %s, budget %.2f (measured %.2f + %d)')
                        :format(c.id, o.value, m.unit, m.per, o.was + o.slack, o.was, o.slack))
                    -- Its biggest contributors, by natives (heavy calls named).
                    for i = 1, math.min(5, #c.rows) do
                        local row = c.rows[i]
                        local hv = {}
                        for _, h in ipairs(row.hby) do
                            hv[#hv + 1] = ('%s %d'):format(h.name, math.floor(h.perSec / 60.0 + 0.5))
                        end
                        realPrint(('       %-34s %8.0f   %s'):format(row.key, row.n, table.concat(hv, ', ')))
                    end
                end
                if #over == 0 and #missing == 0 then
                    goodC = goodC + 1
                    if not ARGS.quiet then
                        realPrint(('\27[32mok\27[0m   change %-58s %6.0f natives  %4.0f heavy  %7.2f KB  busiest %4d')
                            :format(c.id, c.tot.n, c.tot.h, c.tot.kb, c.tot.peak))
                    end
                end
            end
            wantC[c.id] = nil
        end
        if #rn.errs > 0 then
            -- A callback that throws under the model stops being counted, which would
            -- pass the budget for the wrong reason.
            realPrint(('\27[31mFAIL\27[0m %s: callbacks errored under the profiler: %s')
                :format(rn.world.id, table.concat(rn.errs, '; ')))
            bad = bad + 1
        elseif ARGS.quiet and good == #rn.results and goodC == #(rn.changes or {}) then
            -- One line per world for tools/verify.sh: how many phases, and where the
            -- match sits.
            local tail = ''
            for _, r in ipairs(rn.results) do
                if r.id == phaseId(rn.world, 'match') then
                    tail = (', the match at %s natives, %s draws, %.2f KB a frame, %.2f heavy/s')
                        :format(fmt(r.tot.n), fmt(r.tot.d), r.tot.kb, r.tot.h)
                end
            end
            local nC = #(rn.changes or {})
            realPrint(('%sok%s   %-10s %d phases%s within budget on natives, draws, KB and heavy calls%s')
                :format(string.char(27) .. '[32m', string.char(27) .. '[0m', rn.world.id,
                    #rn.results, nC > 0 and (' and %d changes'):format(nC) or '', tail))
        end
    end
    -- A budgeted phase of a world this run covered that it did not measure. Not
    -- asked under --phase, which stops the session early on purpose.
    if not ARGS.phase then
        local ids = {}
        for id in pairs(want) do
            if covered[worldOf(id)] then ids[#ids + 1] = id end
        end
        table.sort(ids)
        for _, id in ipairs(ids) do
            realPrint(('\27[31mFAIL\27[0m budgeted phase %q was not measured -- rebaseline'):format(id))
            bad = bad + 1
        end
        local idsC = {}
        for id in pairs(wantC) do
            if covered[worldOf(id)] then idsC[#idsC + 1] = id end
        end
        table.sort(idsC)
        for _, id in ipairs(idsC) do
            realPrint(('\27[31mFAIL\27[0m budgeted change %q was not measured -- rebaseline'):format(id))
            bad = bad + 1
        end
    end

    -- ═══ THE GATE PROVES IT CAN SEE WHAT IT IS FOR ═══
    --
    -- One more run per regression the heavy count and the change budget exist
    -- for, with it added (the `mutant` the loaded file registers), each of which
    -- must fail what it is aimed at. If one does not, the gate is blind and says
    -- so:
    --
    --   heavy  a model hide made and taken down on every SLOW pass: two natives
    --          a second, 0.03 a frame, inside the native slack. Season 1's lobby.
    --   dui    a browser message on every TICK pass, as client/yubikey.lua's
    --          plate would send without its guard: 0.15 natives a frame. The
    --          same lobby.
    --   burst  every laptop hidden fifty times over at a season switch: 750
    --          model hides once, and nothing in any steady phase. The whole of
    --          s1-live, against its change budget.
    if not ARGS.phase then
        local byId = {}
        for _, b in ipairs(budget.phases) do byId[b.id] = b end
        for _, b in ipairs(budget.changes or {}) do byId['change ' .. b.id] = b end
        local PROOFS = {
            { mutant = 'heavy', world = 's1', phase = 'lobby',
              what = 'a model hide on every SLOW pass' },
            { mutant = 'dui', world = 's1', phase = 'lobby',
              what = 'a browser message on every TICK pass' },
            { mutant = 'burst', world = 's1-live',
              what = 'the laptops hidden fifty times over at a season switch' },
        }
        for _, pf in ipairs(PROOFS) do
            if covered[pf.world] then
                local chunk = assert(loadfile(SELF))
                local proof = chunk({ world = pf.world, self = SELF,
                    args = { frames = MEASURE_FRAMES, phase = pf.phase, mutant = pf.mutant,
                             root = ARGS.root } })
                chunk = nil
                local caught, where = false, nil
                if pf.phase then
                    local r = proof.results[1]
                    local b = r and byId[r.id]
                    for _, o in ipairs(b and overBudget(r, b) or {}) do
                        if o.m.key == 'h' then
                            caught = true
                            where = ('%s at %.2f heavy/s, budget %.2f'):format(r.id, o.value,
                                o.was + o.slack)
                        end
                    end
                else
                    for _, c in ipairs(proof.changes or {}) do
                        local b = byId['change ' .. c.id]
                        for _, o in ipairs(b and overBudget(c, b, CHANGE.metrics, CHANGE.slack) or {}) do
                            if o.m.key == 'h' and not caught then
                                caught = true
                                where = ('%s at %.0f heavy calls, budget %.0f'):format(c.id,
                                    o.value, o.was + o.slack)
                            end
                        end
                    end
                end
                if not caught then
                    realPrint(('\27[31mFAIL\27[0m the gate did not catch %s (%s)'):format(pf.what,
                        pf.world))
                    bad = bad + 1
                elseif not ARGS.quiet then
                    realPrint(('\27[32mok\27[0m   %s fails: %s'):format(pf.what, where))
                end
            end
        end
    end

    if bad > 0 then
        realPrint('     A phase over budget means something new runs, draws, allocates or')
        realPrint('     makes a heavy call there. Find it:')
        realPrint('       lua tools/perf_client.lua --world <world> --top 15 --files --phase <phase>')
        realPrint('     A change over budget does more at once than it did: the same table')
        realPrint('     without --phase prints every change with its biggest contributors.')
        realPrint('     Meant to cost more? lua tools/perf_client.lua --rebaseline, and')
        realPrint('     say why in the commit. See docs/testing.md.')
        os.exit(1)
    end
end
if ARGS.check then check() end

return runs
