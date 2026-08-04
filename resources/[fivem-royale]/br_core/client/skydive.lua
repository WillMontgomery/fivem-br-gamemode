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
    -- One-shot thread: the give-verify-task sequence needs real frames
    -- between steps, and the first flight ended with a player falling
    -- chuteless -- never again on an assumption. dropping is set FIRST so
    -- the SPACE listener in bus.lua stands down immediately.
    dropping = true

    Citizen.CreateThread(function()
        local ped = PlayerPedId()

        SetEntityVisible(ped, true, false)
        FreezeEntityPosition(ped, false)
        ClearPedTasksImmediately(ped)

        -- Carry the bus's momentum out of the door; a dead-stop exit reads
        -- as teleportation even when the coordinates are right.
        local rad = math.rad(d.heading or 0.0)
        SetEntityVelocity(ped, -math.sin(rad) * 25.0, math.cos(rad) * 25.0, -2.0)

        -- THE CHUTE, VERIFIED. GiveWeaponToPed is normally instant, but the
        -- one scenario where it quietly fails is a player mid-teleport --
        -- which is exactly when this runs. Confirm it stuck, retry across
        -- real frames, and say so out loud if the game refuses.
        for attempt = 1, 10 do
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
            if HasPedGotWeapon(ped, CHUTE, false) then break end
            if attempt == 10 then
                print('[br_core] drop: GADGET_PARACHUTE refused 10 times -- deploy will not work')
            end
            Citizen.Wait(0)
        end

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

        -- TASKED, VERIFIED, RETRIED. TaskParachute issued in the same frame
        -- as a long teleport can silently not take -- the ped is mid-warp --
        -- and a ped without the task reports chute state -1 forever, which
        -- made SPACE dead on flight 3. The state saying FREEFALL/OPENING is
        -- the only proof the task exists.
        for attempt = 1, 8 do
            TaskParachute(ped, true, false)   -- second param verified unused
            Citizen.Wait(150)
            local cs = GetPedParachuteState(ped)
            if cs ~= BR.Native.ChuteState.NONE then break end
            if attempt == 8 then
                print('[br_core] drop: TaskParachute never took after 8 attempts')
            end
        end

        -- A native help box, NOT a toast: ~INPUT_PARACHUTE_DEPLOY~ renders
        -- the player's real base-game parachute bind (the engine's own
        -- deploy input works during the fall too, since the ped is in a
        -- genuine parachute task). The old toast said "SPACE" to everyone,
        -- which was our binding's DEFAULT, not their key. No "ride it low"
        -- promise: the auto-deploy floor opens the canopy regardless.
        BR.Native.help('Press ~INPUT_PARACHUTE_DEPLOY~ to open the glider early.')
    end)
end)

-- Manual deploy on OUR keymapped binding too (the base game's own deploy
-- input already works natively during the task). If the engine lost the
-- parachute task (state -1 while clearly airborne), this re-tasks instead of
-- doing nothing -- a dead key during a fatal fall is the worst possible
-- failure mode, twice observed.
BR.Keys.on('deploy', function(pressed)
    if not pressed or not dropping then return end
    local ped = PlayerPedId()
    local cs = GetPedParachuteState(ped)
    -- ON_BACK is the state a HEALTHY drop spends its whole freefall in (the
    -- chute was given, so the engine never reports 3/falling-to-doom). The
    -- old check only forced the canopy from FREEFALL, which is why the key
    -- read as dead for every player whose drop was going fine.
    if cs == BR.Native.ChuteState.FREEFALL
       or cs == BR.Native.ChuteState.ON_BACK then
        ForcePedToOpenParachute(ped)
    elseif cs == BR.Native.ChuteState.NONE
       and not IsPedOnFoot(ped) and not IsEntityInWater(ped) then
        GiveWeaponToPed(ped, CHUTE, 1, false, false)
        TaskParachute(ped, true, false)
    end
end)

-- The drop state machine, at TICK rate -- 10Hz is far finer than any of
-- these transitions and keeps GetEntityHeightAboveGround (slow) off the
-- frame path.
BR.Loop.register(BR.Loop.TICK, 'skydive.state', function()
    -- Armed by the drop handoff OR by the server calling me a faller --
    -- whichever arrives first. Gating on the handoff alone meant that if it
    -- was ever missed, the chute floor below was disarmed for exactly the
    -- player who needed it.
    if not dropping then
        local st = BR.State.me.state
        if st == BR.PlayerState.FREEFALL or st == BR.PlayerState.GLIDE then
            dropping = true
        else
            return
        end
    end

    local ped = PlayerPedId()
    local cs = GetPedParachuteState(ped)

    -- THE FLOOR, UNCONDITIONALLY. Below the auto-deploy height with the
    -- canopy not out, this hammers EVERY tick until it is: re-give, re-task,
    -- force -- regardless of which state the chute machinery claims to be in
    -- (-1 task lost, 0 stowed, 3 freefall; ragdolls lie about all three).
    -- Earlier versions gated each recovery step on the state that step
    -- expected, and players fell past a floor made of preconditions. The
    -- descent is invincible as the last net, but the chute is the fix.
    local airborne = not IsPedOnFoot(ped) and not IsEntityInWater(ped)
    if airborne
       and cs ~= BR.Native.ChuteState.OPENING
       and cs ~= BR.Native.ChuteState.OPEN
       and GetEntityHeightAboveGround(ped) < BR.Config.Drop.autoDeployAGL then
        if not HasPedGotWeapon(ped, CHUTE, false) then
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
        end
        if cs ~= BR.Native.ChuteState.FREEFALL then
            TaskParachute(ped, true, false)
        end
        ForcePedToOpenParachute(ped)
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

--- Everything about the drop, in one paste.
RegisterCommand('brdrop', function()
    local ped = PlayerPedId()
    print('=== drop (client) ===')
    print(('  dropping  %s   chuteState %d   hasChute %s'):format(
        tostring(dropping), GetPedParachuteState(ped),
        tostring(HasPedGotWeapon(ped, CHUTE, false))))
    print(('  AGL %.0fm   onFoot %s   inWater %s   falling %s'):format(
        GetEntityHeightAboveGround(ped), tostring(IsPedOnFoot(ped)),
        tostring(IsEntityInWater(ped)), tostring(IsPedFalling(ped))))
end, false)

-- A match ending mid-air (brforce, mass leave) must not leave the latch set.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        dropping = false
    end
end)
