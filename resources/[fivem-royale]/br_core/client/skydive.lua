-- The drop: freefall -> glider -> ground.
--
-- Driven entirely by GET_PED_PARACHUTE_STATE, because the engine's own state
-- is the only honest answer to "is the chute out yet" -- inferring it from
-- velocity or height re-derives what the ped already knows.
--
-- THE CHUTE IS A WEAPON AND IT MUST BE GIVEN. TASK_PARACHUTE's second
-- parameter looks like "give parachute" and is verified UNUSED (a removed
-- legacy jetpack flag) -- task a ped without GADGET_PARACHUTE in their
-- inventory and they fall to their death with the animation of someone
-- reaching for a ripcord that is not there.

BR = BR or {}

local CHUTE = GetHashKey('GADGET_PARACHUTE')   -- 0xFBAB5776, verified

local dropping = false

--- Parse '#RRGGBB' (the squad colour the server assigned) into rgb.
local function hexToRgb(hex)
    if type(hex) ~= 'string' then return 255, 255, 255 end
    local r, g, b = hex:match('^#(%x%x)(%x%x)(%x%x)$')
    if not r then return 255, 255, 255 end
    return tonumber(r, 16), tonumber(g, 16), tonumber(b, 16)
end

AddEventHandler('br:drop:begin', function(d)
    local ped = PlayerPedId()

    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    ClearPedTasksImmediately(ped)

    -- Carry the bus's momentum out of the door; a dead-stop exit reads as
    -- teleportation even when the coordinates are right.
    local rad = math.rad(d.heading or 0.0)
    SetEntityVelocity(ped, -math.sin(rad) * 25.0, math.cos(rad) * 25.0, -2.0)

    GiveWeaponToPed(ped, CHUTE, 1, false, false)
    SetPlayerParachuteModelOverride(PlayerId(),
        GetHashKey(BR.Config.Drop.parachuteModel))

    -- Squad identity in the air, exactly as cheap as it looks.
    if BR.Config.Drop.smokeTrail then
        local me = BR.State.roster[BR.State.me.src]
        if me and me.colour then
            SetPlayerCanLeaveParachuteSmokeTrail(PlayerId(), true)
            SetPlayerParachuteSmokeTrailColor(PlayerId(), hexToRgb(me.colour))
        end
    end

    TaskParachute(ped, true, false)   -- second param verified unused
    dropping = true

    TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
        text = 'SPACE deploys the glider — or ride it low.', tone = 'info', ms = 5000,
    })
end)

-- Manual deploy.
BR.Keys.on('deploy', function(pressed)
    if not pressed or not dropping then return end
    local ped = PlayerPedId()
    if GetPedParachuteState(ped) == BR.Native.ChuteState.FREEFALL then
        ForcePedToOpenParachute(ped)
    end
end)

-- The drop state machine, at TICK rate -- 10Hz is far finer than any of
-- these transitions and keeps GetEntityHeightAboveGround (slow) off the
-- frame path.
BR.Loop.register(BR.Loop.TICK, 'skydive.state', function()
    if not dropping then return end

    local ped = PlayerPedId()
    local cs = GetPedParachuteState(ped)

    if cs == BR.Native.ChuteState.FREEFALL then
        -- The floor is not a suggestion: below this height the chute opens
        -- whether or not the player was still holding for style.
        if GetEntityHeightAboveGround(ped) < BR.Config.Drop.autoDeployAGL then
            ForcePedToOpenParachute(ped)
        end
        return
    end

    -- Landed: no chute in play and feet on something. Water counts -- a sea
    -- landing is a bad drop, not a continuing one.
    if (cs == BR.Native.ChuteState.NONE or cs == BR.Native.ChuteState.ON_BACK)
       and not IsPedFalling(ped)
       and (IsPedOnFoot(ped) or IsEntityInWater(ped)) then
        dropping = false

        RemoveWeaponFromPed(ped, CHUTE)
        SetPlayerCanLeaveParachuteSmokeTrail(PlayerId(), false)

        -- A short grace absorbs the landing-stumble edge cases (gamerules
        -- reads this alongside its warmup/bus invincibility rule).
        BR.State.dropGraceUntil = GetGameTimer() + BR.Config.Drop.landedGraceMs

        TriggerServerEvent(BR.Net.DROP_LANDED)
        print('[br_core] landed')
    end
end)

-- A match ending mid-air (brforce, mass leave) must not leave the latch set.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.CLEANUP then
        dropping = false
    end
end)
