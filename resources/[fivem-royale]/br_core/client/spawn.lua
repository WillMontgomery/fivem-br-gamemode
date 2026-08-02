-- Spawning.
--
-- server.cfg deliberately does not start spawnmanager or basic-gamemode: they
-- would spawn players into the world on join and respawn them on death, both of
-- which the match state machine owns. This is their replacement.
--
-- THE GOVERNING RULE HERE IS: NEVER LEAVE THE PLAYER LOOKING AT BLACK.
--
-- A black screen with the HUD drawn on top of it means the loading screen never
-- came down, or the screen faded out and never faded back in. Neither produces
-- an error, neither appears in any log, and the player cannot do anything about
-- it except reconnect. An earlier version of this file put ShutdownLoadingScreen
-- inside a callback that only ran if a collision-wait loop finished -- so if
-- that loop was interrupted, or a second placement started while the first was
-- still running, the screen stayed black forever.
--
-- Now: the loading screen comes down as soon as the session exists, regardless
-- of where the player ends up; placement is serialised so two requests cannot
-- fight; and a watchdog fades the screen back in if it is ever left dark.

BR = BR or {}
BR.Spawn = {}

local spawned = false
local placing = false

--- Place the local player, waiting for the world to stream in.
---
--- The wait matters: teleporting to coordinates whose collision has not loaded
--- drops the player through the map. Freezing during the wait prevents that.
---
--- Serialised on `placing`. Two overlapping placements would each freeze and
--- unfreeze the ped, and whichever finished first would unfreeze a player the
--- other still intended to hold still.
---
--- @param x number
--- @param y number
--- @param z number
--- @param heading number|nil
--- @param cb function|nil
function BR.Spawn.placeAt(x, y, z, heading, cb)
    if placing then
        if BR.Server and BR.Server.devMode then
            print('[br_core] placement already in progress, ignoring')
        end
        return
    end
    placing = true

    local ped = PlayerPedId()
    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, heading or 0.0)
    FreezeEntityPosition(ped, true)

    Citizen.CreateThread(function()
        local groundZ = z

        -- ~4 seconds: long enough for a cold streaming load, short enough that
        -- failing does not look like a hang.
        for _ = 1, 40 do
            Citizen.Wait(100)
            RequestCollisionAtCoord(x, y, z)
            if HasCollisionLoadedAroundEntity(ped) then
                local found, gz = GetGroundZFor_3dCoord(x, y, z + 50.0, false)
                if found then groundZ = gz + 1.0 end
                break
            end
        end

        -- Re-read the ped: it can change while we waited (a respawn, a model
        -- swap), and unfreezing a stale handle would leave the real one stuck.
        ped = PlayerPedId()
        SetEntityCoordsNoOffset(ped, x, y, groundZ, false, false, false)
        FreezeEntityPosition(ped, false)

        -- Unconditional. Whatever happened above, the player can see and move.
        BR.Spawn.reveal()

        placing = false
        if cb then cb() end
    end)
end

--- Make sure the player can actually see the world.
---
--- Safe to call at any time and as often as you like. This is the single place
--- that undoes every way the screen can be dark.
function BR.Spawn.reveal()
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
    if IsScreenFadedOut() or IsScreenFadingOut() then
        DoScreenFadeIn(500)
    end
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
    BR.Spawn.placeAt(pad.x, pad.y, pad.z, pad.heading)

    print('[br_core] spawned at the warmup pad')
end

--- Move the player to the warmup pad, scattered slightly so a full lobby does
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

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WARMUP or d.state == BR.MatchState.CLEANUP then
        BR.Spawn.toWarmupPad()
    end
end)

Citizen.CreateThread(function()
    -- The one thread outside the loop registry: it runs once at startup and
    -- then never again, so a permanently-registered callback would cost more
    -- than it saves.
    while not NetworkIsSessionStarted() do
        Citizen.Wait(100)
    end

    -- Take the loading screen down as soon as there is a session, BEFORE any
    -- placement. Tying it to the end of a placement meant an interrupted
    -- placement left the player staring at black with the HUD drawn on top.
    BR.Spawn.reveal()

    Citizen.Wait(500)
    initialSpawn()
end)

-- Watchdog. If the screen is dark and nothing is deliberately placing the
-- player, something failed silently -- there is no error for "faded out and
-- never faded back in". Recovering automatically beats a reconnect.
BR.Loop.register(BR.Loop.SLOW, 'spawn.antiblack', function()
    if placing then return end
    if IsScreenFadedOut() and not IsScreenFadingIn() then
        print('[br_core] screen was left faded out -- fading back in (watchdog)')
        BR.Spawn.reveal()
    end
end)

RegisterCommand('brunstuck', function()
    -- Manual escape hatch for anything the watchdog does not catch.
    local ped = PlayerPedId()
    placing = false
    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
    DoScreenFadeIn(300)
    ClearFocus()
    print('[br_core] unstuck: screen restored, ped unfrozen')
end, false)
