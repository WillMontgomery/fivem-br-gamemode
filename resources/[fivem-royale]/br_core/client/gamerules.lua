-- Game rules and death reporting.
--
-- Two jobs, both about stopping vanilla GTA from running a game we are trying to
-- run ourselves.
--
-- The rules half was written in natives.lua during M0 and then never called --
-- so wanted levels, ambient traffic and, most importantly, the engine's own
-- death/respawn flow were all still active. A player who died got GTA's
-- behaviour rather than ours.

BR = BR or {}

-- --------------------------------------------------------------------------
-- Rules
-- --------------------------------------------------------------------------

-- Several of these reset themselves every tick, which is why this is a frame
-- callback rather than a one-off. It is cheap: a handful of native calls with no
-- allocation.
BR.Loop.register(BR.Loop.FRAME, 'gamerules.apply', function()
    BR.Native.applyGameRules()
end)

-- --------------------------------------------------------------------------
-- Mad drivers
-- --------------------------------------------------------------------------

-- Ambient drivers drive BADLY (user call, 2026-08-04): zero ability, full
-- aggression -- the apocalypse does not produce calm commuters. Applied
-- once per vehicle as they stream in; the handled set is wiped when it
-- grows stale so handle reuse cannot leak.
local maddened = {}
local maddenedCount = 0

BR.Loop.register(BR.Loop.SLOW, 'gamerules.madDrivers', function()
    if not BR.Config.Ambient.erratic then return end
    local st = BR.State.me.state
    if st == BR.PlayerState.LOBBY or st == BR.PlayerState.WARMUP then return end

    if maddenedCount > 300 then maddened = {} maddenedCount = 0 end

    local mp = GetEntityCoords(PlayerPedId())
    for _, veh in ipairs(GetGamePool('CVehicle')) do
        if not maddened[veh] and DoesEntityExist(veh)
           and #(GetEntityCoords(veh) - mp) < 250.0 then
            maddened[veh] = true
            maddenedCount = maddenedCount + 1
            local drv = GetPedInVehicleSeat(veh, -1)
            if drv ~= 0 and not IsPedAPlayer(drv) then
                -- Ability/aggressiveness alone changed nothing visible
                -- (live report: "drivers are still very much calm") -- the
                -- ambient cruise TASK is what actually drives. Replace it:
                -- wander fast with style 786468 (rushed -- runs lights,
                -- overtakes, swerves for nothing).
                SetDriverAbility(drv, 0.0)
                SetDriverAggressiveness(drv, 1.0)
                TaskVehicleDriveWander(drv, veh, 30.0, 786468)
                SetDriveTaskMaxCruiseSpeed(drv, 30.0)
            end
        end
    end
end)

-- --------------------------------------------------------------------------
-- Death
-- --------------------------------------------------------------------------

local reportedDeath = false

--- Watch our own ped for death.
---
--- Reading the LOCAL player's ped is always legitimate -- it is the one entity a
--- client can observe directly and authoritatively. This is a report, not a
--- decision: the server decides whether it means elimination, and in squads
--- whether it means downed instead.
BR.Loop.register(BR.Loop.TICK, 'gamerules.death', function()
    local ped = PlayerPedId()
    local dead = IsEntityDead(ped) or IsPedFatallyInjured(ped)

    if dead and not reportedDeath then
        reportedDeath = true

        -- GET_PED_SOURCE_OF_DEATH gives the killing ENTITY, which may be another
        -- player's ped, a vehicle, or the world. The server resolves it to a
        -- player where it can; a fall has no killer and that is fine.
        local killerEntity = GetPedSourceOfDeath(ped)
        local causeHash = GetPedCauseOfDeath(ped)

        TriggerServerEvent(BR.Net.PLAYER_DIED, {
            cause  = causeHash,
            killer = (killerEntity and killerEntity ~= 0 and killerEntity ~= ped)
                     and NetworkGetNetworkIdFromEntity(killerEntity) or nil,
        })

        print('[br_core] reported own death to the server')

    elseif not dead and reportedDeath then
        -- Respawned, so arm the detector again. Without this a player can only
        -- ever die once per session.
        reportedDeath = false
    end
end)

--- Clear the death latch when the server moves us somewhere new, so a respawn
--- into the next match is not treated as still-dead.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WARMUP or d.state == BR.MatchState.CLEANUP then
        reportedDeath = false
    end
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    BR.Native.applyWorldSetup()
    print('[br_core] game rules applied')
end)
