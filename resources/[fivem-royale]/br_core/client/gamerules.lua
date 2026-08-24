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
--- Is this native BOOL true?
---
--- In Lua `0` IS TRUTHY, and a FiveM native declared BOOL may answer `1`/`0`
--- rather than `true`/`false`. A bare `not` over one of those refuses every
--- case -- `not 0` is false -- which this repo has now shipped four times.
--- client/spectate.lua and client/dbno.lua each carry the same normaliser over
--- their own BOOL native; see the note at the IsPedAPlayer call below for why
--- this one is normalised rather than left to the diagnostic.
local function yes(v) return v == true or v == 1 end

local maddened = {}
local maddenedCount = 0

BR.Gamerules = BR.Gamerules or {}

--- WHAT THE LAST PASS ACTUALLY DID, so "the drivers are all too calm" has an
--- answer that is a reading rather than another round of guessing. Drained by
--- /brdrivers in client/debug.lua; nothing reads it to make a decision.
local lastPass = {
    at = 0, ran = false, why = 'not run yet',
    anchorFrom = nil, anchorOffPed = 0.0,
    pool = 0, inRange = 0, empty = 0, playerDriven = 0, treated = 0,
    playerRaw = nil,
}

--- WHERE "NEAR THE PLAYER" IS MEASURED FROM.
---
--- THE PED IS THE WRONG POINT WHILE SPECTATING, and that is a live regression
--- rather than a theoretical one. A spectator's ped is a corpse where they fell
--- -- client/spectate.lua deliberately never moves it, and must not, because an
--- ADMIN spectator may be alive and mid-match (see BR.Native.lockMinimap) --
--- while SET_FOCUS_ENTITY pulls the streaming volume onto whoever is being
--- watched. So the world on screen loads and populates around the TARGET, and
--- every vehicle in the shot is hundreds of metres from the point this pass
--- used to measure from. Nothing visible was ever in range, nothing visible was
--- ever treated, and every driver the spectator could see was a calm commuter.
--- "The NPC drivers are all too calm now" -- the owner, 2026-08-22, one day
--- after spectating went live.
---
--- WITH NO SESSION RUNNING THIS IS EXACTLY WHAT IT ALWAYS WAS: the local ped's
--- coordinates, same native, same value, same drivers treated. A living
--- player's pass is byte-for-byte unchanged, which is the point -- the anchor
--- moves only in the one case that was broken.
---
--- ASKED OF client/spectate.lua RATHER THAN OF THE CAMERA. A rendered-camera
--- coordinate would cover the same case, but it also answers during every
--- cutscene, lobby shot and death cam, and a wrong answer there would move the
--- anchor for a player who is alive and standing still -- which is precisely
--- the regression this is fixing, pointed the other way.
--- @return vector3 point, string source
local function anchor()
    local S = BR.Spectate
    if S and S.active and S.watchPoint and S.active() then
        local p = S.watchPoint()
        if p then return p, 'spectate' end
    end
    return GetEntityCoords(PlayerPedId()), 'ped'
end

BR.Loop.register(BR.Loop.SLOW, 'gamerules.madDrivers', function()
    lastPass.at  = GetGameTimer()
    lastPass.ran = false
    lastPass.pool, lastPass.inRange = 0, 0
    lastPass.empty, lastPass.playerDriven, lastPass.treated = 0, 0, 0

    if not BR.Config.Ambient.erratic then
        lastPass.why = 'BR.Config.Ambient.erratic is off'
        return
    end
    local st = BR.State.me.state
    if st == BR.PlayerState.LOBBY or st == BR.PlayerState.WARMUP then
        lastPass.why = ('player state is %s -- the island is a stage'):format(tostring(st))
        return
    end

    if maddenedCount > 300 then maddened = {} maddenedCount = 0 end

    local A   = BR.Config.Ambient
    local now = GetGameTimer()
    local mp, from = anchor()

    lastPass.ran          = true
    lastPass.why          = 'ran'
    lastPass.anchorFrom   = from
    lastPass.anchorOffPed = #(mp - GetEntityCoords(PlayerPedId()))

    local pool = GetGamePool('CVehicle')
    lastPass.pool = #pool

    for _, veh in ipairs(pool) do
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
            lastPass.inRange = lastPass.inRange + 1
            local drv = GetPedInVehicleSeat(veh, -1)
            if drv == 0 then
                lastPass.empty = lastPass.empty + 1
            else
                -- RECORDED RAW AND JUDGED EXACTLY AS IT SHIPPED ON 2026-08-07.
                --
                -- A FiveM native declared BOOL can hand Lua a number or a
                -- boolean depending on the build, and IN LUA `0` IS TRUTHY --
                -- this repo has shipped that bug four times, which is why
                -- client/spectate.lua and client/dbno.lua each carry a
                -- normaliser over their own BOOL native.
                --
                -- AND THIS ONE IS NORMALISED TOO, WHICH IS A CHANGE OF MIND.
                --
                -- The investigation that found the anchor bug left `not raw`
                -- alone on the reasoning that the feature had been confirmed
                -- working, so the native must already answer a real boolean on
                -- this build -- and that picking a direction on a hunch was
                -- what the report asked nobody to do. The diagnosis was right;
                -- the conclusion about the code was not.
                --
                -- NORMALISING IS A NO-OP IF THAT REASONING HOLDS AND A FIX IF
                -- IT DOES NOT. Answer a real boolean and `yes()` changes
                -- nothing whatsoever. Answer `1`/`0` and the bare `not` refuses
                -- EVERY driver -- `not 0` is false -- so the pass finds cars,
                -- treats none, and every commuter stays calm forever, looking
                -- exactly like the feature being switched off. There is no
                -- third case and no build on which the bare `not` is the better
                -- test.
                --
                -- The raw value is still recorded, because /brdrivers printing
                -- the type is how anybody ever learns which world we are in.
                local raw = IsPedAPlayer(drv)
                lastPass.playerRaw = ('%s (%s)'):format(tostring(raw), type(raw))

                if not yes(raw) then
                    lastPass.treated = lastPass.treated + 1
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
                else
                    lastPass.playerDriven = lastPass.playerDriven + 1
                end
            end
        end
    end
end)

--- What the last mad-driver pass saw and did. Read by /brdrivers.
---
--- A COPY, so a reader cannot edit the pass's own bookkeeping by holding it.
--- @return table
function BR.Gamerules.driverStats()
    return {
        at           = lastPass.at,
        ran          = lastPass.ran,
        why          = lastPass.why,
        anchorFrom   = lastPass.anchorFrom,
        anchorOffPed = lastPass.anchorOffPed,
        pool         = lastPass.pool,
        inRange      = lastPass.inRange,
        empty        = lastPass.empty,
        playerDriven = lastPass.playerDriven,
        treated      = lastPass.treated,
        playerRaw    = lastPass.playerRaw,
        tracked      = maddenedCount,
        range        = BR.Config.Ambient.erraticRange or 250.0,
        erratic      = BR.Config.Ambient.erratic and true or false,
    }
end

-- --------------------------------------------------------------------------
-- Death
-- --------------------------------------------------------------------------

local reportedDeath = false

--- Watch our own ped for death.
---
--- Reading the LOCAL player's ped is always legitimate -- it is the one entity a
--- client can observe directly and authoritatively. This is a report, not a
--- decision: the server decides whether it means elimination, or whether it
--- means downed instead -- in squads, and since #191 in solos too, for a player
--- carrying a CPR kit.
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
