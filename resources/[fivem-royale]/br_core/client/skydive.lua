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

-- THE LANDING LATCH. The landing test is "chute away, feet on something" --
-- which is also true in the instant AFTER THE JUMP, before the exit
-- velocity and parachute task have taken hold: the ped still reads as
-- on-foot, so the landing branch fired seconds into the fall. That sent a
-- false DROP_LANDED (the server marked the player ALIVE mid-air -- the
-- premature storm clock), and re-fired every re-arm: the stack of four
-- "Loot up!" toasts. Landing only counts after the drop has actually been
-- AIRBORNE at least once.
local airborneSeen = false

-- THE CANOPY IS OUT, SO THE WEAPON IS SPENT.
--
-- GTA does NOT consume GADGET_PARACHUTE when the canopy opens: the ped keeps
-- the weapon with its ammo intact, which is the engine's definition of "has a
-- parachute available". That is why a player who had already pulled was still
-- armed with a second one and why the vanilla deploy prompt came back the
-- moment they were near the ground (live report, 2026-08-05 -- the third
-- distinct reserve-chute symptom, and the first one whose cause was the
-- ENGINE'S ammo model rather than one of our own give paths).
--
-- Zeroing the ammo the instant the canopy appears leaves the open canopy
-- alone (the parachute TASK owns it, not the inventory entry) while making a
-- redeploy impossible. Removing the weapon outright here would be the obvious
-- move and is exactly what we do NOT do: pulling the weapon out from under a
-- live parachute task is how you drop someone out of their own canopy.
local chuteSpent = false

--- Take the parachute away for good, and kill the vanilla prompt with it.
---
--- `hard` is the second attempt: RemoveWeaponFromPed has now failed to shift
--- GADGET_PARACHUTE often enough (it is a gadget, not an ordinary weapon, and
--- the parachute task can hand it straight back as it unwinds) that the
--- fallback is RemoveAllPedWeapons -- which does work, and is safe here
--- because client/inventory.lua re-grants the active slot on its next tick.
--- @param ped integer
--- @param hard boolean|nil
local function disarmChute(ped, hard)
    if hard then
        RemoveAllPedWeapons(ped, true)
        if BR.Inv and BR.Inv.reapply then BR.Inv.reapply() end
    else
        RemoveWeaponFromPed(ped, CHUTE)
    end
    -- The COUNT is ammo and outlives the weapon removal; this is the line the
    -- "reserve chute after landing" reports kept coming back to.
    SetPedAmmo(ped, CHUTE, 0)
    ClearHelp(true)
end

--- Does this ped still have a parachute in any sense the engine cares about?
--- @param ped integer
--- @return boolean
local function hasChute(ped)
    return HasPedGotWeapon(ped, CHUTE, false)
        or GetAmmoInPedWeapon(ped, CHUTE) > 0
end

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
    airborneSeen = false
    chuteSpent = false

    Citizen.CreateThread(function()
        local ped = PlayerPedId()

        SetEntityVisible(ped, true, false)
        FreezeEntityPosition(ped, false)
        ClearPedTasksImmediately(ped)

        -- Carry the bus's momentum out of the door; a dead-stop exit reads
        -- as teleportation even when the coordinates are right.
        local rad = math.rad(d.heading or 0.0)
        SetEntityVelocity(ped, -math.sin(rad) * 25.0, math.cos(rad) * 25.0, -2.0)

        -- THE CHUTE, VERIFIED -- and NEVER DOUBLED. GiveWeaponToPed is
        -- normally instant, but the one scenario where it quietly fails is
        -- a player mid-teleport -- which is exactly when this runs. Confirm
        -- it stuck, retry across real frames, and say so out loud if the
        -- game refuses. The has-check comes FIRST: giving a second
        -- GADGET_PARACHUTE to a ped that already holds one (the TICK
        -- floor's give can race this thread) stacks as chute ammo, which
        -- the engine treats as a RESERVE parachute -- the "handed another
        -- parachute after pulling the first" report (2026-08-04).
        for attempt = 1, 10 do
            if HasPedGotWeapon(ped, CHUTE, false) then break end
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
            if HasPedGotWeapon(ped, CHUTE, false) then break end
            if attempt == 10 then
                print('[br_core] drop: GADGET_PARACHUTE refused 10 times -- deploy will not work')
            end
            Citizen.Wait(0)
        end
        -- EXACTLY ONE, ALWAYS. Chute count is ammo, and a count above one
        -- is what the engine treats as a RESERVE parachute -- there is no
        -- reserve in this gamemode, whatever race between give paths may
        -- have happened (user rule, 2026-08-04).
        SetPedAmmo(ped, CHUTE, 1)

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

        -- (The glider prompt is drawn per-frame below, so it persists until
        -- the canopy is actually out.)
    end)
end)

-- The glider prompt PERSISTS until the chute is genuinely pulled -- redrawn
-- per frame while falling with the canopy stowed, gone the frame it opens.
-- ~INPUT_PARACHUTE_DEPLOY~ renders the player's real base-game bind (the
-- engine's own deploy input works during the fall, since the ped is in a
-- genuine parachute task; our keybind works alongside).
BR.Loop.register(BR.Loop.FRAME, 'skydive.prompt', function()
    if not dropping then return end
    local ped = PlayerPedId()

    -- F IS NOT A RIPCORD-CUTTER. INPUT_PARACHUTE_DETACH (153, default F)
    -- cuts the canopy mid-glide in base GTA -- and F is also the default
    -- enter-vehicle key, so players who reached for a door mid-descent
    -- dropped out of the sky (live report, 2026-08-04). Dead for the
    -- whole drop.
    DisableControlAction(0, 153, true)

    local cs = GetPedParachuteState(ped)
    -- The airborne test must NOT be `not IsPedOnFoot`: a ped in the
    -- parachute task's freefall COUNTS AS ON FOOT, so that gate killed the
    -- prompt for the entire healthy drop (live report, 2026-08-04). What
    -- it was guarding against -- the canopy detaching a beat before the
    -- TICK landing branch disarms, flashing "open the glider" at a player
    -- standing on the ground -- is covered by the freefall/falling pair
    -- below, both false for a ped with feet on anything.
    if (IsPedInParachuteFreeFall(ped) or IsPedFalling(ped))
       and (cs == BR.Native.ChuteState.ON_BACK
            or cs == BR.Native.ChuteState.FREEFALL) then
        BR.Native.helpThisFrame('Press ~INPUT_PARACHUTE_DEPLOY~ to open the glider.')
    end
end)

-- Manual deploy on OUR keymapped binding too (the base game's own deploy
-- input already works natively during the task). If the engine lost the
-- parachute task (state -1 while clearly airborne), this re-tasks instead of
-- doing nothing -- a dead key during a fatal fall is the worst possible
-- failure mode, twice observed.
BR.Keys.on('deploy', function(pressed)
    if not pressed or not dropping then return end
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, true) then return end
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
        -- State NONE means the TASK is lost, not necessarily the weapon --
        -- re-giving one the ped still holds stacks a reserve chute.
        if not HasPedGotWeapon(ped, CHUTE, false) then
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
        end
        SetPedAmmo(ped, CHUTE, 1)   -- exactly one; never a reserve
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

    -- A DRIVER'S SEAT IS NOT A DROP. In a vehicle IsPedOnFoot is false, so
    -- the airborne test below reads "falling" -- and the chute floor then
    -- gave the ped a parachute, re-tasked it, and forced the canopy, which
    -- EJECTS from the vehicle (live report: "given a parachute, prompted to
    -- pull, immediately ejected"). If the machine was somehow still armed
    -- when the player got in, entering a vehicle IS proof of being landed:
    -- finish the drop and stand down.
    if IsPedInAnyVehicle(ped, true) then
        if dropping then
            dropping = false
            disarmChute(ped)
            SetPlayerCanLeaveParachuteSmokeTrail(PlayerId(), false)
            TriggerServerEvent(BR.Net.DROP_LANDED)
            print('[br_core] drop: finished from a vehicle seat -- the machine was still armed')
        end
        return
    end

    local cs = GetPedParachuteState(ped)

    -- Spend the chute the moment the canopy appears -- see the note on
    -- chuteSpent at the top. One write, latched, so this is not fighting the
    -- engine every tick of a two-minute glide.
    if not chuteSpent
       and (cs == BR.Native.ChuteState.OPENING
            or cs == BR.Native.ChuteState.OPEN) then
        chuteSpent = true
        SetPedAmmo(ped, CHUTE, 0)
    end

    -- THE FLOOR, UNCONDITIONALLY. Below the auto-deploy height with the
    -- canopy not out, this hammers EVERY tick until it is: re-give, re-task,
    -- force -- regardless of which state the chute machinery claims to be in
    -- (-1 task lost, 0 stowed, 3 freefall; ragdolls lie about all three).
    -- Earlier versions gated each recovery step on the state that step
    -- expected, and players fell past a floor made of preconditions. The
    -- descent is invincible as the last net, but the chute is the fix.
    local agl = GetEntityHeightAboveGround(ped)
    local airborne = not IsPedOnFoot(ped) and not IsEntityInWater(ped)
    if airborne and agl > 3.0 then airborneSeen = true end
    -- The floor's band has a BOTTOM as well as a top: below ~3m a chute
    -- can do nothing, and firing there is pure harm -- the vehicle-entry
    -- animation reads as "airborne at ground level" for a beat (not on
    -- foot, chute state NONE once the task drops), and the floor answered
    -- it by handing the player a parachute and forcing it open ("given a
    -- chute the moment I try to enter a vehicle", live report 2026-08-04).
    if airborne
       and cs ~= BR.Native.ChuteState.OPENING
       and cs ~= BR.Native.ChuteState.OPEN
       and agl > 3.0
       and agl < BR.Config.Drop.autoDeployAGL then
        if not HasPedGotWeapon(ped, CHUTE, false) then
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
        end
        -- Ammo is re-asserted here even when the weapon was already held: the
        -- canopy-spent latch above zeroes it, and a chute that reverted to
        -- ON_BACK afterwards would have nothing to deploy. The floor is the
        -- unconditional net -- it must not be able to fire blanks.
        SetPedAmmo(ped, CHUTE, 1)   -- exactly one; never a reserve
        chuteSpent = false
        if cs ~= BR.Native.ChuteState.FREEFALL then
            TaskParachute(ped, true, false)
        end
        ForcePedToOpenParachute(ped)
        return
    end

    -- Landed: on the ground, not falling, canopy not mid-opening -- and
    -- only after the drop has actually BEEN airborne (see the latch note
    -- at the top). Water counts: a sea landing is a bad drop, not a
    -- continuing one.
    --
    -- ANY chute state except OPENING counts as landed. The old test
    -- required NONE/ON_BACK, but the engine sometimes keeps the canopy
    -- ATTACHED after touchdown (state still OPEN, with GTA's own "press F
    -- to release parachute" prompt) -- so the machine stayed armed, the
    -- glider prompt lingered, and the next F press (bound to enter-vehicle)
    -- hit the chute floor from a driver's seat: the parachute-in-a-car
    -- ejection, root-caused at last (user insight, 2026-08-04).
    --
    -- AND on-foot alone is not the whole grounded test: with the canopy
    -- still ATTACHED the parachute task holds the ped off "on foot"
    -- indefinitely -- the machine stayed armed on the ground, which kept
    -- F dead (control 153 stays disabled while dropping) and left the
    -- floor loaded for the vehicle-entry gap (live report, 2026-08-04:
    -- "press F, nothing; enter a vehicle, given a chute"). A ped standing
    -- still at ground level with the canopy out has landed, whatever the
    -- task claims.
    local grounded = IsPedOnFoot(ped) or IsEntityInWater(ped)
    if not grounded and cs == BR.Native.ChuteState.OPEN
       and agl < 2.0 and GetEntitySpeed(ped) < 2.0 then
        grounded = true
    end
    if airborneSeen
       and cs ~= BR.Native.ChuteState.OPENING
       and not IsPedFalling(ped)
       and grounded then
        dropping = false

        if cs == BR.Native.ChuteState.OPEN then
            -- Shed the still-attached canopy along with its vanilla prompt.
            ClearPedTasks(ped)
        end

        -- REMOVAL IS VERIFIED, NOT ASSUMED. The give path has retried across
        -- real frames since flight one, on the grounds that GiveWeaponToPed
        -- can quietly fail around a teleport -- and the removal path, doing
        -- the mirror-image thing at the mirror-image moment, never did. It
        -- also has to outlive ClearPedTasks: the task teardown can hand the
        -- weapon back into the ped's hands a frame later, which no
        -- single-shot RemoveWeaponFromPed can see coming.
        disarmChute(ped)
        Citizen.CreateThread(function()
            for attempt = 1, 15 do
                Citizen.Wait(100)
                local p = PlayerPedId()
                if not hasChute(p) then break end
                -- Escalate after three polite attempts.
                disarmChute(p, attempt >= 3)
            end
        end)

        SetPlayerCanLeaveParachuteSmokeTrail(PlayerId(), false)

        -- A short grace absorbs the landing-stumble edge cases (gamerules
        -- reads this alongside its warmup/bus invincibility rule).
        BR.State.dropGraceUntil = GetGameTimer() + BR.Config.Drop.landedGraceMs

        TriggerServerEvent(BR.Net.DROP_LANDED)
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = 'Loot up before the storm comes!', tone = 'info', ms = 6000,
        })
        print('[br_core] landed')
    end
end)

-- THE STANDING DISARM. Everything above depends on the landing branch firing,
-- and the landing branch has now been wrong in four different ways across four
-- sessions -- attached canopies, vehicle seats, water, the state machine never
-- arming at all. This is the net under all of it: a player the SERVER считает
-- calls landed (ALIVE/DBNO), standing on the ground, must not be holding a
-- parachute, whatever route they took to get there.
--
-- HasPedGotWeapon first, so the ordinary case is one cheap call at 10Hz and the
-- expensive height probe only runs for a ped that actually still has a chute.
local sweeps = 0
BR.Loop.register(BR.Loop.TICK, 'skydive.disarm', function()
    if dropping then return end

    local st = BR.State.me.state
    if st ~= BR.PlayerState.ALIVE and st ~= BR.PlayerState.DBNO then return end

    local ped = PlayerPedId()
    if not hasChute(ped) then
        sweeps = 0
        return
    end

    -- WATER IS GROUND. GetEntityHeightAboveGround measures to the SEABED, so
    -- a player swimming in 30m of water reads as 30m up and the height gate
    -- skipped them entirely -- which is the worst possible place to leave
    -- someone armed with a parachute, because the engine's next expected
    -- action is a deploy they cannot perform (user, 2026-08-05).
    local inWater = IsEntityInWater(ped)
    if not inWater then
        -- Never yank one out of the air: if this player is somehow genuinely
        -- falling, the floor above is the system that owns them.
        if IsPedFalling(ped) or GetEntityHeightAboveGround(ped) > 5.0 then
            sweeps = 0
            return
        end
    end

    sweeps = sweeps + 1
    disarmChute(ped, sweeps >= 3)
end)

--- Everything about the drop, in one paste.
RegisterCommand('brdrop', function()
    local ped = PlayerPedId()
    print('=== drop (client) ===')
    print(('  dropping  %s   chuteState %d   hasChute %s   chuteAmmo %d   reserve %s'):format(
        tostring(dropping), GetPedParachuteState(ped),
        tostring(HasPedGotWeapon(ped, CHUTE, false)),
        GetAmmoInPedWeapon(ped, CHUTE),
        tostring(GetPlayerHasReserveParachute(PlayerId()))))
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
