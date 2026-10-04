-- Offline frame profiler for br_core's client (#393).
--
--   lua tools/perf_client.lua                 the table, every phase
--   lua tools/perf_client.lua --top 10        more contributors per phase
--   lua tools/perf_client.lua --by 12         more natives named per contributor
--   lua tools/perf_client.lua --phase match   one phase (and the ones before it)
--   lua tools/perf_client.lua --check         the budget gate tools/verify.sh runs
--   lua tools/perf_client.lua --rebaseline    print a fresh budget table
--
-- WHAT IT IS. Every br_core client file, in fxmanifest order, plus the vendored
-- ScaleformUI that loads inside br_core, run in one Lua state against a modelled
-- engine: a clock that moves 1/60 s a frame, threads as coroutines woken by that
-- clock, the three BR.Loop bands on their real threads, events and net events,
-- entities, blips and a camera. The session is then walked through the phases a
-- player sees -- lobby, warmup, the plane before and after the island release,
-- the jump, and a match -- and each phase is measured for a few hundred frames.
--
-- WHAT IT COUNTS. Every native the code calls goes through a stub that counts it
-- against whatever is running: a loop callback by its registered name, a raw
-- thread by the file and line that created it, an event handler by its event.
-- Native calls per frame is the headline, because it is deterministic and
-- because a native is where the cost is in the game. Lua time per frame
-- (os.clock over the measured frames) and kilobytes allocated per frame (GC
-- stopped while measuring) are printed beside it.
--
-- WHAT IT CANNOT SEE. The engine side of a native: a DrawSpritePoly counts one
-- here and costs the render thread a triangle there, and a GetEntityCoords is a
-- few hundred nanoseconds of marshalling in the game against a table read here.
-- The Lua time is this machine's PUC Lua 5.4, not the game's CfxLua, and it
-- includes the stubs. Use it to rank and to compare a before with an after; the
-- in-game numbers are brbench / brab (client/debug.lua) and resmon.
--
-- THE BUDGET. tools/perf_budget.lua holds a ceiling per phase on native calls
-- per frame. --check fails when a phase goes over it, which is how an ungated
-- per-frame loop gets caught before a playtest does. docs/testing.md says how to
-- rebaseline.

local ARGS = {}
do
    local i = 1
    while i <= #arg do
        local a = arg[i]
        if a == '--check' or a == '--rebaseline' or a == '--quiet' or a == '--digest' then
            ARGS[a:sub(3)] = true
        elseif a == '--top' or a == '--phase' or a == '--frames' or a == '--root'
            or a == '--by' then
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
local MEASURE_FRAMES = tonumber(ARGS.frames) or 600

local realPrint = print
local clock = os.clock

-- ------------------------------------------------------------ attribution ---

local buckets = {}
local function bucket(key)
    local b = buckets[key]
    if not b then
        b = { key = key, n = 0, t = 0.0, kb = 0.0, calls = 0, by = {} }
        buckets[key] = b
    end
    return b
end

local curB = bucket('(load)')
local stack = {}
local measuring = false

--- Enter `key`, pausing whoever was running. Exclusive attribution: an event a
--- callback triggers is charged to the event, not to the callback.
local function enter(key)
    local now, kb = clock(), collectgarbage('count')
    local top = stack[#stack]
    if top then
        top.b.t  = top.b.t + (now - top.t0)
        top.b.kb = top.b.kb + (kb - top.kb0)
    end
    local b = bucket(key)
    b.calls = b.calls + 1
    stack[#stack + 1] = { b = b, t0 = now, kb0 = kb }
    curB = b
end

local function leave()
    local now, kb = clock(), collectgarbage('count')
    local top = stack[#stack]
    stack[#stack] = nil
    top.b.t  = top.b.t + (now - top.t0)
    top.b.kb = top.b.kb + (kb - top.kb0)
    local under = stack[#stack]
    if under then
        under.t0, under.kb0 = now, kb
        curB = under.b
    else
        curB = bucket('(harness)')
    end
end

local function call(key, fn, ...)
    enter(key)
    local res = table.pack(pcall(fn, ...))
    leave()
    if not res[1] then
        local b = bucket(key)
        b.errs = (b.errs or 0) + 1
        if not b.errSaid then
            b.errSaid = true
            realPrint(('\27[33m[perf] %s errored: %s\27[0m'):format(key, tostring(res[2])))
        end
    end
    return table.unpack(res, 1, res.n)
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
    handles = 100,
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
IMPL.GetGameTimer        = function() return gameMs() end
IMPL.GetNetworkTime      = function() return gameMs() end
IMPL.GetFrameTime        = function() return FRAME_MS / 1000.0 end
IMPL.GetFrameCount       = function() return math.floor(NOW / FRAME_MS) end
IMPL.GetCloudTimeAsInt   = function() return 1790000000 + math.floor(NOW / 1000) end
IMPL.GetCurrentResourceName = function() return 'br_core' end
IMPL.GetResourceState    = function() return 'started' end
IMPL.GetConvar           = function(n, d) local v = W.convars[n]; if v == nil then return d end return tostring(v) end
IMPL.GetConvarInt        = function(n, d) local v = tonumber(W.convars[n]); if v == nil then return d end return math.floor(v) end
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
IMPL.GetEntitySpeed      = function() return 0.0 end
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
IMPL.GetFinalRenderedCamFov   = function() return 50.0 end
IMPL.GetAspectRatio      = function() return 16.0 / 9.0 end
IMPL.AttachEntityToEntity = function(h, to) local e = W.ents[h] if e then e.attachedTo = to end end
IMPL.DetachEntity        = function(h) local e = W.ents[h] if e then e.attachedTo = nil end end
IMPL.IsEntityAttached    = function(h) local e = W.ents[h] return (e and e.attachedTo) and true or false end
IMPL.GetGameplayCamFov   = function() return 50.0 end
IMPL.GetCamCoord         = function() return vec3(W.cam.x, W.cam.y, W.cam.z) end
IMPL.GetCamRot           = function() return vec3(W.cam.rx, 0.0, W.cam.rz) end
IMPL.GetGroundZFor_3dCoord = function() return true, 30.0 end
IMPL.GetWaterHeight      = function() return false, 0.0 end
IMPL.GetWaterHeightNoWaves = function() return false, 0.0 end
IMPL.TestProbeAgainstWater = F
IMPL.GetVehiclePedIsIn   = function() return 0 end
IMPL.GetVehiclePedIsTryingToEnter = function() return 0 end
IMPL.GetVehiclePedIsUsing = function() return 0 end
IMPL.GetPedInVehicleSeat = function() return 0 end
IMPL.GetSelectedPedWeapon = function() return jenkins('weapon_unarmed') end
IMPL.GetCurrentPedWeapon = function() return true, jenkins('weapon_unarmed') end
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
IMPL.IsPedOnFoot         = function(h) return not airborne(h) end
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
IMPL.GetRuntimeTextureWidth = function() return 8 end
IMPL.GetInteriorFromEntity = function() return 0 end
IMPL.GetInteriorAtCoords = function() return 0 end
IMPL.GetRoomKeyFromEntity = function() return 0 end
IMPL.GetClockHours       = function() return 12 end
IMPL.GetClockMinutes     = function() return 0 end
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
IMPL.GetClosestObjectOfType = function() return 0 end
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
IMPL.CreateRuntimeTexture = function() W.handles = W.handles + 1 return W.handles end
IMPL.CreateRuntimeTextureFromDuiHandle = function() W.handles = W.handles + 1 return W.handles end
IMPL.RequestScaleformMovie = function() W.handles = W.handles + 1 return W.handles end
IMPL.RequestScaleformMovieInstance = IMPL.RequestScaleformMovie
IMPL.RequestScaleformMovieInteractive = IMPL.RequestScaleformMovie
IMPL.CreateCam           = function() W.handles = W.handles + 1 return W.handles end
IMPL.CreateCamWithParams = IMPL.CreateCam
IMPL.CreateCameraWithParams = IMPL.CreateCam
IMPL.DoesCamExist        = function(c) return (c and c ~= 0) and true or false end
IMPL.StartShapeTestRay   = function() return 1 end
IMPL.StartShapeTestLosProbe = function() return 1 end
IMPL.StartExpensiveSynchronousShapeTestLosProbe = function() return 1 end
IMPL.StartShapeTestCapsule = function() return 1 end
IMPL.StartShapeTestSweptSphere = function() return 1 end
IMPL.CreateObject        = function(m, x, y, z) return newEnt('obj', m, x, y, z) end
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
    local draws = ARGS.digest and name:match('^Draw')
    f = function(...)
        local b = curB
        b.n = b.n + 1
        local by = b.by
        by[name] = (by[name] or 0) + 1
        if draws then
            local h = fold(digest.h, name)
            for i = 1, select('#', ...) do h = fold(h, (select(i, ...))) end
            digest.h, digest.n = h, digest.n + 1
        end
        return body(...)
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

local function spawn(fn, delay)
    threads[#threads + 1] = {
        co = coroutine.create(fn), wake = NOW + (delay or 0), key = srcKey(fn, 'thread'),
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
            enter(th.key)
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

local function fire(name, key, ...)
    local list = handlers[name]
    if not list then return end
    for _, h in ipairs({ table.unpack(list) }) do
        if not h.removed then call(key or ('event ' .. name), h.fn, ...) end
    end
end

--- What the server sends this client.
local function net(name, ...)
    fire(name, 'net ' .. name, ...)
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
        SetTimeout = function(ms, fn) spawn(function() Wait(ms) fn() end, 0) end,
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
        fire(name, nil, ...)
    end,
    TriggerServerEvent = function() countAs('TriggerServerEvent') end,
    TriggerLatentServerEvent = function() countAs('TriggerServerEvent') end,
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

local BR

--- Every loop callback runs under its own name, so a native it calls is charged
--- to it. Hooked the moment main.lua has defined the registry and before any
--- other file registers, which leaves BR.Loop.register itself untouched.
local function hookLoop()
    local real = BR.Loop.register
    BR.Loop.register = function(band, name, fn)
        local key = band .. ' ' .. tostring(name)
        local function wrapped(dt)
            enter(key)
            local ok, err = pcall(fn, dt)
            leave()
            if not ok then
                local b = bucket(key)
                b.errs = (b.errs or 0) + 1
                if not b.errSaid then
                    b.errSaid = true
                    realPrint(('[33m[perf] %s errored: %s[0m'):format(key, tostring(err)))
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
        realPrint('[31mload error[0m ' .. f .. ': ' .. tostring(err))
        loadErrors = loadErrors + 1
    else
        local key = 'load ' .. (f:match('([^/]+)$'))
        enter(key)
        local ok, e2 = pcall(chunk)
        leave()
        if not ok then
            realPrint('[31mrun error[0m ' .. f .. ': ' .. tostring(e2))
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
-- BR.BuildLootLayout, BR.BuildAirdropRecord) and delivered as the net events
-- the client really receives.

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

--- Other players streamed in around `x, y`: real peds the client can see.
local function streamPlayers(x, y, list)
    for src in pairs(W.players) do W.ents[W.players[src].ped] = nil end
    W.players = {}
    for i, src in ipairs(list) do
        local a = i * 0.9
        local ped = newEnt('ped', jenkins('mp_m_freemode_01'),
            x + math.cos(a) * (8 + i * 6), y + math.sin(a) * (8 + i * 6), 30.0)
        W.players[src] = { ped = ped }
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

local function busRoute(t0)
    local pts = {}
    local x, y = LAND.x - 6000.0, LAND.y - 900.0
    local z = 40.0
    local t = t0
    for i = 1, 160 do
        local speed = (i <= 33) and (i * 4.0) or 185.0
        if i > 33 and i <= 53 then z = z + (1800.0 - 40.0) / 20.0 end
        x = x + speed
        y = y + speed * 0.15
        t = t + 1000
        pts[i] = { x = x, y = y, z = z, t = t }
    end
    return {
        points = pts, waypoints = {}, legs = { 1, 2, 3, 4 },
        jumpIdx = 60, closeIdx = 150, rotateIdx = 33,
        alt = 1800.0, heading = 80.0, timed = true,
        tStart = t0, rotateAt = t0 + 8000, doorsClose = pts[150].t,
        tEnd = pts[160].t, sx = pts[1].x, sy = pts[1].y, jumpFrom = pts[60].t,
    }
end

local lootSent = false
local function sendLoot(x, y)
    if lootSent then return end
    lootSent = true
    local entries = BR.BuildLootLayout(SEED)
    local want = {}
    for _, key in ipairs(BR.LootCellsAround(BR.LootCellOf(x, y))) do want[key] = true end
    local list = {}
    for _, e in ipairs(entries) do
        if want[BR.LootCellKeyAt(e.x, e.y)] then list[#list + 1] = e end
    end
    net(BR.Net.LOOT_ADD, list)
    -- Stand where the loot is thickest: the entry with the most others within
    -- glow range, so the render walk has real work in front of it.
    local best, bestN = nil, -1
    local g2 = BR.Config.Loot.glowDistance * BR.Config.Loot.glowDistance
    for _, a in ipairs(list) do
        local n = 0
        for _, b in ipairs(list) do
            if BR.Dist2(a.x, a.y, b.x, b.y) <= g2 then n = n + 1 end
        end
        if n > bestN then best, bestN = a, n end
    end
    return #list, best, bestN
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

--- What the server keeps sending on its own clock, whatever the phase.
local FEEDS = {
    { every = 500,  fn = lobbyStatus },
    { every = 500,  fn = digestFeed },
    { every = 1000, fn = function()
        local st = S.match.state
        if st == BR.MatchState.PLAYING then squadPos() end
    end },
}

--- The phases, in session order. `setup` runs once at the phase boundary and is
--- not measured; `settle` frames run unmeasured after it so one-shot work (model
--- loads, the storm's shape builds) does not land in the steady state.
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
    end },
    { id = 'warmup', settle = 240, setup = function()
        local P = BR.Config.Match.warmupPos
        setPed(W.me, P.x, P.y, P.z)
        W.cam.x, W.cam.y, W.cam.z = P.x, P.y - 4.0, P.z + 1.5
        streamPlayers(P.x, P.y, { 2, 3, 4, 5, 6, 7, 8, 9 })
        env.TriggerEvent('br:env:world', true)
        matchState(BR.MatchState.WARMUP, 90000)
        setStates(function() return BR.PlayerState.WARMUP end)
        net(BR.Net.STORM_PREVIEW, circleOne())
    end },
    { id = 'plane boarding', settle = 120, setup = function()
        matchState(BR.MatchState.BUS, 180000)
        setStates(function() return BR.PlayerState.BUS end)
        route = busRoute(gameMs() + 500)
        net(BR.Net.BUS_ROUTE, route)
        W.cam.rz = -90.0      -- looking along the flight, due east
        W.players = {}
    end },
    { id = 'plane cruise', settle = 60, setup = function()
        -- Past wheels-up and the island release: bus.board has asked
        -- br_environment to swap the world, and this is its answer.
        while gameMs() < route.rotateAt + 6000 do
            NOW = NOW + FRAME_MS
            runThreads()
        end
        env.TriggerEvent('br:env:world', false)
        local x, y = BR.PathPosAt(route.points, gameMs())
        populate(x, y - 500.0)
    end },
    { id = 'freefall', settle = 120, setup = function()
        local x, y, z = BR.PathPosAt(route.points, gameMs())
        setPed(W.me, x, y, z - 5.0)
        W.chute = 3
        delta({ { op = 'update', src = ME, e = { state = BR.PlayerState.FREEFALL } } })
    end },
    { id = 'chute', settle = 60, setup = function()
        local e = W.ents[W.me]
        e.x, e.y, e.z = LAND.x, LAND.y, 300.0
        W.chute = 2
        delta({ { op = 'update', src = ME, e = { state = BR.PlayerState.GLIDE } } })
    end },
    { id = 'match', settle = 240, setup = function()
        setPed(W.me, LAND.x, LAND.y, LAND.z)
        W.chute = nil
        W.cam.rz = 0.0        -- facing north, up the map
        matchState(BR.MatchState.PLAYING, 1800000)
        local stateOf = function(src)
            if src == DOWNED then return BR.PlayerState.DBNO end
            if src > 16 then return BR.PlayerState.OUT end
            return BR.PlayerState.ALIVE
        end
        setStates(stateOf)
        streamPlayers(LAND.x, LAND.y, { 2, 3, 4, 5, 6, 7, 8, 9 })
        populate(LAND.x, LAND.y)
        local c1 = circleOne()
        stormPhase(1, ANCHOR.x, ANCHOR.y, openingR(ANCHOR.x, ANCHOR.y),
                   c1.cx, c1.cy, c1.r, 120, 240, 30000)
        local _, spot = sendLoot(LAND.x, LAND.y)
        if spot then setPed(W.me, spot.x + 1.5, spot.y + 1.0, spot.z or LAND.z) end
        squadPos()
        local t0 = gameMs()
        net(BR.Net.AIRDROP_SYNC, BR.BuildAirdropRecord(1,
            { id = LAND.id, x = LAND.x + 150.0, y = LAND.y - 80.0, z = LAND.z },
            260.0, t0, t0 + 60000, 90.0, t0 + 15000))
    end },
    { id = 'match sweep', settle = 60, setup = function()
        local c1 = circleOne()
        stormPhase(1, ANCHOR.x, ANCHOR.y, openingR(ANCHOR.x, ANCHOR.y),
                   c1.cx, c1.cy, c1.r, 120, 240, 120000 + 100000)
    end },
    { id = 'match late', settle = 120, setup = function()
        -- Later on: the downed squadmate has been picked up.
        delta({ { op = 'update', src = DOWNED, e = { state = BR.PlayerState.ALIVE } } })
        local p2, p3 = BR.Config.Storm.phases[2], BR.Config.Storm.phases[3]
        stormPhase(3, LAND.x + 200.0, LAND.y + 300.0, p2.radius,
                   LAND.x + 300.0, LAND.y + 100.0, p3.radius, 90, 90, 30000)
    end },
}

-- ----------------------------------------------------------------- driver ---

local function followCam()
    local p = entPos(W.me)
    local h = math.rad(W.cam.rz)
    W.cam.x, W.cam.y, W.cam.z = p.x + math.sin(h) * 4.0, p.y - math.cos(h) * 4.0, p.z + 1.5
end

local function frame()
    NOW = NOW + FRAME_MS
    followCam()
    for _, f in ipairs(FEEDS) do
        if not f.at or NOW >= f.at then
            f.at = (f.at or NOW) + f.every
            f.fn()
        end
    end
    runThreads()
end

local function snapshot()
    local s = {}
    for k, b in pairs(buckets) do
        local by = {}
        for n, c in pairs(b.by) do by[n] = c end
        s[k] = { n = b.n, t = b.t, kb = b.kb, calls = b.calls, by = by }
    end
    return s
end

local function diff(a, b, frames)
    local rows = {}
    for k, nb in pairs(b) do
        local oa = a[k] or { n = 0, t = 0, kb = 0, calls = 0, by = {} }
        local dn, dt, dkb = nb.n - oa.n, nb.t - oa.t, nb.kb - oa.kb
        if (dn > 0 or dt > 0 or dkb > 0) and k ~= '(harness)'
            and not k:match('^load ') then
            local by = {}
            for n, c in pairs(nb.by) do
                local d = c - (oa.by[n] or 0)
                if d > 0 then by[#by + 1] = { name = n, n = d / frames } end
            end
            table.sort(by, function(x, y) return x.n > y.n end)
            rows[#rows + 1] = { key = k, n = dn / frames, ms = dt * 1000.0 / frames,
                                kb = dkb / frames, by = by }
        end
    end
    table.sort(rows, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        return x.ms > y.ms
    end)
    local tot = { n = 0, ms = 0, kb = 0 }
    for _, r in ipairs(rows) do
        tot.n, tot.ms, tot.kb = tot.n + r.n, tot.ms + r.ms, tot.kb + r.kb
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
    enter('net setup ' .. ph.id)
    local ok, err = pcall(ph.setup)
    leave()
    if not ok then
        realPrint(('\27[31m[perf] setup of %s failed: %s\27[0m'):format(ph.id, tostring(err)))
        os.exit(2)
    end
    for _ = 1, ph.settle do frame() gcMaybe() end
    digest.h, digest.n = 0, 0
    local before = snapshot()
    local c0 = clock()
    for _ = 1, MEASURE_FRAMES do frame() gcMaybe() end
    local wall = (clock() - c0) * 1000.0 / MEASURE_FRAMES
    local rows, tot = diff(before, snapshot(), MEASURE_FRAMES)
    results[#results + 1] = { id = ph.id, rows = rows, tot = tot, wall = wall,
                              digest = ('%016x/%d'):format(digest.h, digest.n) }
    if ARGS.phase and ph.id == ARGS.phase then break end
end
collectgarbage('restart')

-- ----------------------------------------------------------------- report ---

local function fmt(n) return ('%.1f'):format(n) end

if not ARGS.check and not ARGS.rebaseline then
    realPrint(('br_core client, offline: %d measured frames per phase at 60 fps')
        :format(MEASURE_FRAMES))
    realPrint('natives/frame is exact for this scene; Lua ms is this machine\'s PUC Lua, stubs included;')
    realPrint('engine-side cost of a native (a DrawSpritePoly\'s triangles) is invisible here.')
    for _, r in ipairs(results) do
        realPrint('')
        realPrint(('== %-14s natives/frame %7s   Lua ms/frame %6.3f (wall %6.3f)   KB/frame %7.1f')
            :format(r.id, fmt(r.tot.n), r.tot.ms, r.wall, r.tot.kb))
        if ARGS.digest then realPrint('   draw digest ' .. r.digest) end
        for i = 1, math.min(TOP, #r.rows) do
            local row = r.rows[i]
            local top = {}
            for j = 1, math.min(tonumber(ARGS.by) or 3, #row.by) do
                top[#top + 1] = ('%s %s'):format(row.by[j].name, fmt(row.by[j].n))
            end
            realPrint(('   %-34s %7s  %6.3f ms  %7.1f KB   %s'):format(row.key, fmt(row.n),
                row.ms, row.kb, table.concat(top, ', ')))
        end
    end
    local errs = {}
    for k, b in pairs(buckets) do
        if (b.errs or 0) > 0 then errs[#errs + 1] = ('%s x%d'):format(k, b.errs) end
    end
    if #errs > 0 then
        table.sort(errs)
        realPrint('')
        realPrint('errors (the harness, not the game -- fix the model): ' .. table.concat(errs, '; '))
    end
end

return results
