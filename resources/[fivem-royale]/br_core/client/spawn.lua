-- Spawning.
--
-- server.cfg deliberately does not start spawnmanager or basic-gamemode: they
-- would spawn players into the world on join and respawn them on death, both of
-- which the match state machine owns. Removing them without replacing them left
-- players with no ped at all, which is why the server's position sampling had
-- nothing to read.
--
-- This is that replacement. It is deliberately minimal -- put the player in the
-- world at a known place, take the loading screen down, and let the match state
-- machine decide where they belong from there.

BR = BR or {}
BR.Spawn = {}

local spawned = false

--- Place the local player at a position, waiting for the world to stream in.
---
--- The wait matters: teleporting to coordinates whose collision has not loaded
--- drops the player through the map. Freezing during the wait is what stops that
--- becoming a swim in the ocean.
---
--- @param x number
--- @param y number
--- @param z number
--- @param heading number|nil
--- @param cb function|nil  called once the player is on solid ground
function BR.Spawn.placeAt(x, y, z, heading, cb)
    local ped = PlayerPedId()

    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, heading or 0.0)
    FreezeEntityPosition(ped, true)

    Citizen.CreateThread(function()
        local tries = 0
        local groundZ = z

        -- ~4 seconds. Long enough for a cold streaming load, short enough that a
        -- failure does not look like a hang.
        while tries < 40 do
            Citizen.Wait(100)
            tries = tries + 1
            RequestCollisionAtCoord(x, y, z)
            if HasCollisionLoadedAroundEntity(ped) then
                local found, gz = GetGroundZFor_3dCoord(x, y, z + 50.0, false)
                if found then groundZ = gz + 1.0 end
                break
            end
        end

        SetEntityCoordsNoOffset(ped, x, y, groundZ, false, false, false)
        FreezeEntityPosition(ped, false)

        if cb then cb() end
    end)
end

--- Bring the player into the world for the first time.
local function initialSpawn()
    if spawned then return end
    spawned = true

    local pad = BR.Config.Match.warmupPos
    local ped = PlayerPedId()

    -- Without spawnmanager nothing has resurrected the player, so do it here.
    -- Skipping this leaves them in a not-quite-alive state where controls work
    -- but the ped is not properly registered.
    NetworkResurrectLocalPlayer(pad.x, pad.y, pad.z, pad.heading, true, false)
    ClearPedTasksImmediately(ped)
    RemoveAllPedWeapons(ped, true)

    BR.Native.initHealthModel()

    BR.Spawn.placeAt(pad.x, pad.y, pad.z, pad.heading, function()
        ShutdownLoadingScreen()
        ShutdownLoadingScreenNui()
        DoScreenFadeIn(800)
        print('[br_core] spawned at the warmup pad')
    end)
end

--- Move the player to the warmup pad, scattered a little so a full lobby does
--- not stack everyone on one point.
function BR.Spawn.toWarmupPad()
    local pad = BR.Config.Match.warmupPos
    local r = BR.Config.Match.warmupRadius * 0.5
    local theta = math.random() * 2.0 * math.pi
    local dist = r * math.sqrt(math.random())

    BR.Spawn.placeAt(
        pad.x + math.cos(theta) * dist,
        pad.y + math.sin(theta) * dist,
        pad.z,
        pad.heading)
end

-- Match state drives where the player belongs.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WARMUP or d.state == BR.MatchState.CLEANUP then
        BR.Spawn.toWarmupPad()
    end
end)

Citizen.CreateThread(function()
    -- The one place a thread is spawned outside the loop registry, because this
    -- runs exactly once at startup and then never again. Registering a callback
    -- that no-ops forever afterwards would cost more than it saves.
    while not NetworkIsSessionStarted() do
        Citizen.Wait(100)
    end
    Citizen.Wait(500)
    initialSpawn()
end)

RegisterCommand('brrespawn', function()
    spawned = false
    initialSpawn()
    print('[br_core] forced respawn')
end, false)
