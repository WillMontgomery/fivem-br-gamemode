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

    local A   = BR.Config.Ambient
    local now = GetGameTimer()
    local mp  = GetEntityCoords(PlayerPedId())

    for _, veh in ipairs(GetGamePool('CVehicle')) do
        -- RE-TASKED ON A CADENCE, NOT ONCE AND FOREVER.
        --
        -- The old version marked a vehicle done the first time it was
        -- treated and never looked at it again -- but the engine hands the
        -- ped new tasks all the time (a collision, a blocked road, arriving
        -- somewhere), and the moment it does, the driver reverts to a calm
        -- commuter for the rest of its life. That is the most likely reason
        -- some drivers stayed sane while others did not.
        local due = (maddened[veh] or 0) <= now
        if due and DoesEntityExist(veh)
           and #(GetEntityCoords(veh) - mp) < (A.erraticRange or 250.0) then
            -- Marked only once a driver is actually TREATED: marking on
            -- sight branded empty or not-yet-crewed vehicles as done, and
            -- their drivers stayed calm forever ("some peds drive like
            -- assholes, but not all", live report).
            local drv = GetPedInVehicleSeat(veh, -1)
            if drv ~= 0 and not IsPedAPlayer(drv) then
                if not maddened[veh] then maddenedCount = maddenedCount + 1 end
                maddened[veh] = now + (A.erraticRetaskMs or 8000)

                -- Ability/aggressiveness alone changed nothing visible (live
                -- report: "drivers are still very much calm") -- the ambient
                -- cruise TASK is what actually drives, so it gets replaced.
                --
                -- THE STYLE IS THE WHOLE THING. 786468 still carried the
                -- avoid-vehicles and avoid-objects flags, so a "rushed"
                -- driver still politely went round everything. See
                -- BR.Config.Ambient.erraticStyle for the flags that are left
                -- and, more importantly, the ones that are not.
                SetDriverAbility(drv, A.erraticAbility or 0.0)
                SetDriverAggressiveness(drv, A.erraticAggression or 1.0)
                SetPedKeepTask(drv, true)
                TaskVehicleDriveWander(drv, veh,
                    A.erraticSpeed or 45.0, A.erraticStyle or 262656)
                SetDriveTaskMaxCruiseSpeed(drv, A.erraticSpeed or 45.0)
                -- Two more that make the difference between "fast" and
                -- "unhinged": they will not brake for a red light and they
                -- will not wait for a gap.
                SetDriveTaskDrivingStyle(drv, A.erraticStyle or 262656)
                SetDriverRacingModifier(drv, 1.0)
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
        -- Ped handles are recycled between matches, so a stale entry here
        -- would silently refuse a legitimate drop later.
        looted = {}
    end
end)

-- --------------------------------------------------------------------------
-- Vanilla weapon pickups
-- --------------------------------------------------------------------------

-- GTA'S OWN LOOT MUST NOT EXIST IN A GAME THAT HAS ITS OWN.
--
-- Kill an ambient NPC and the engine drops their weapon as a `CPickup` -- a
-- vanilla pickup with a vanilla glow that you collect by walking over it
-- (user, 2026-08-06). It is not one of our entries, so it has no DUI, no
-- rarity, no marker, and picking it up puts a gun in the ped's hands that the
-- inventory has never heard of -- which the active-slot model then strips off
-- again on the next weapon switch. Every part of that is confusing.
--
-- Two lines of defence, because the first one alone is not enough:
--
--   1. Stop peds dropping in the first place, for every ped near us. This is
--      the clean fix, but only reaches peds currently streamed in.
--   2. Sweep whatever appears anyway. Covers peds that died before they were
--      near us, and anything else in the game that spawns a pickup.
--
-- CPickup is its own game pool, so the sweep is a short walk over pickups
-- only -- not over every object in the world.
local PICKUP_SWEEP_RANGE = 120.0

-- Peds we have already turned into a drop, so one corpse pays once. Cleared
-- with the match; a handful of entries at a time in practice.
local looted = {}

BR.Loop.register(BR.Loop.TICK, 'gamerules.pickups', function()
    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local canLoot = BR.State.me.state == BR.PlayerState.ALIVE
                 or BR.State.me.state == BR.PlayerState.WARMUP

    -- 1. Nearby peds keep their guns when they die -- and if WE killed one,
    --    it becomes a proper loot entry instead.
    --
    --    KILLING AN NPC SHOULD PAY, IT JUST SHOULD NOT PAY IN GTA'S CURRENCY
    --    (user, 2026-08-06). The vanilla pickup was removed last round because
    --    it had no DUI, no rarity and no route into the inventory; the answer
    --    is not "no drop", it is "our drop". So the corpse is read once, its
    --    weapon looked up in our own table, and the SERVER asked to place a
    --    real entry -- which then behaves exactly like every other item on the
    --    ground.
    for _, other in ipairs(GetGamePool('CPed')) do
        if other ~= ped and DoesEntityExist(other) then
            SetPedDropsWeaponsWhenDead(other, false)

            if canLoot and not looted[other] and IsPedDeadOrDying(other, true) then
                looted[other] = true
                -- Ours only: the kill has to be attributable to this player,
                -- or standing near a road where NPCs crash would print money.
                if HasEntityBeenDamagedByEntity(other, ped, true) then
                    -- THEIR INVENTORY, WHICH FOR AN NPC IS THE GUN IN THEIR
                    -- HAND AND WHAT WAS IN IT (user, 2026-08-06: "I only want
                    -- them to drop their inventory the same as a player
                    -- would"). Nothing is invented: no rolled rarity, no bonus
                    -- ammo, no consumables. An unarmed pedestrian drops
                    -- nothing at all, which is the same rule a player follows.
                    local okW, wh = GetCurrentPedWeapon(other, true)
                    local w = okW and BR.Config.WeaponByHash[BR.NormHash(wh)] or nil
                    if w and w.ammo then
                        local c = GetEntityCoords(other)
                        if BR.Dist2(c.x, c.y, p.x, p.y) < 40.0 * 40.0 then
                            -- What the ped actually had, capped at one
                            -- magazine so a scripted NPC with a huge reserve
                            -- cannot become an ammo piñata.
                            local carried = GetAmmoInPedWeapon(other, wh) or 0
                            TriggerServerEvent(BR.Net.NPC_DROP, {
                                item = w.id,
                                clip = math.min(carried, w.clip or 0),
                                x = c.x, y = c.y, z = c.z,
                            })
                        end
                    end
                end
            end
        end
    end

    -- 2. Anything that got through goes away. RemovePickup is the engine's own
    --    call for this -- DeleteEntity does not apply to a pickup handle.
    for _, pickup in ipairs(GetGamePool('CPickup')) do
        if DoesPickupExist(pickup) then
            local c = GetPickupCoords(pickup)
            if c and BR.Dist2(c.x, c.y, p.x, p.y)
                < PICKUP_SWEEP_RANGE * PICKUP_SWEEP_RANGE then
                RemovePickup(pickup)
            end
        end
    end
end)

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end
    BR.Native.applyWorldSetup()
    print('[br_core] game rules applied')
end)
