-- /brprobe -- what the natives ACTUALLY do on this build.
--
-- WHY THIS EXISTS. brnativecheck answers "does this name resolve", which has
-- caught real bugs (a misspelled native is nil, not an error). It does not
-- answer "does it BEHAVE the way the documentation says", and that second
-- question is where this project keeps losing days:
--
--   * GetAmmoInPedWeapon was assumed to be a total including the magazine.
--     It does not move when firing here, so the derived reserve GREW as the
--     clip shrank -- and the growth fed back into the ped as free ammo.
--   * GetWaterHeight was assumed to answer everywhere. Over open ocean it
--     often returns nothing, so loot "rejected from water" still floated.
--   * CreateObjectNoOffset's last parameter is `dynamic`, and passing false
--     welded every crate to the ground through three rounds of fixes.
--   * ~INPUT_<hash>~ was assumed to render a key glyph for a custom binding.
--     It renders a hole.
--
-- Each of those was a guess dressed as a fact, and each cost a playtest round
-- to find. This command MEASURES instead: it prints raw returns, watches
-- values change while the player acts, and spawns labelled test objects whose
-- behaviour can be reported back in one line.
--
-- Read the output, then write the code. Not the other way round.

BR = BR or {}

local function line() print('--------------------------------------------------------------') end
local function head(s)
    print('==============================================================')
    print('  ' .. s)
    print('==============================================================')
end

--- Print a value with its Lua type, because "0" and "false" and nil are three
--- very different answers and print() renders two of them identically.
local function val(label, v, extra)
    print(('  %-34s %-14s %s'):format(label, tostring(v),
        extra and ('(' .. tostring(extra) .. ')') or ('[' .. type(v) .. ']')))
end

-- --------------------------------------------------------------------------
-- Ammo
-- --------------------------------------------------------------------------

--- Everything the engine will tell us about the weapon in hand.
---
--- The point is the RELATIONSHIPS between these numbers, not any one of them:
--- whether the "ped weapon" figure includes the magazine, and which of them
--- move when a round is fired versus when the player reloads.
local function ammoDump()
    local ped = PlayerPedId()
    local ok, hash = GetCurrentPedWeapon(ped, true)
    if not ok or not hash then
        print('  no weapon in hand -- equip one and run this again')
        return nil
    end

    local w = BR.Config.WeaponByHash[hash]
    print(('  weapon                             %s (0x%08X)')
        :format(w and w.id or 'unknown', hash & 0xFFFFFFFF))
    if w then
        val('config clip size', w.clip)
        val('config ammo pool', w.ammo)
    end

    val('GetAmmoInPedWeapon', GetAmmoInPedWeapon(ped, hash))
    local clipOk, clip = GetAmmoInClip(ped, hash)
    val('GetAmmoInClip -> ret1', clipOk)
    val('GetAmmoInClip -> ret2', clip, 'the magazine, if this is a number')

    local maxOk, maxClip = GetMaxAmmoInClip(ped, hash, true)
    val('GetMaxAmmoInClip -> ret1', maxOk)
    val('GetMaxAmmoInClip -> ret2', maxClip)

    local totOk, maxAmmo = GetMaxAmmo(ped, hash)
    val('GetMaxAmmo -> ret1', totOk)
    val('GetMaxAmmo -> ret2', maxAmmo)

    local atype = GetPedAmmoTypeFromWeapon(ped, hash)
    val('GetPedAmmoTypeFromWeapon', atype)
    val('GetPedAmmoByType', GetPedAmmoByType(ped, atype))

    return hash
end

--- Watch the ammo numbers while the player shoots and reloads.
---
--- This is the measurement that actually settles the model: fire a few rounds,
--- reload, and read which columns moved. A static dump cannot tell you whether
--- a number is a total or a reserve; watching it change can.
---
--- `raw` suspends BR.Inv's own ammo writes for the duration. THE FIRST RUN OF
--- THIS WAS CONTAMINATED WITHOUT IT: two of the three columns went UP by one
--- per shot, which is not something a gun does -- it was our own code writing
--- ammo back while the watch read it. A measurement of a system that includes
--- the thing being questioned answers nothing.
local function ammoWatch(seconds, raw)
    local hash = ammoDump()
    if not hash then return end

    print('')
    if raw then
        BR.Inv.suspendAmmo = true
        print('  RAW MODE: br_core is not touching the ped\'s ammo. Every number')
        print('  below is the engine on its own -- no writes of ours mixed in.')
    else
        print('  NOTE: br_core is still managing ammo, so some movement below is')
        print('  ours. Use /brprobe raw for the engine alone.')
    end
    print(('  WATCHING for %ds -- fire a few rounds, then reload.'):format(seconds))
    print('  Any line below is a CHANGE. Columns: pedWeapon | clip | byType')
    line()

    Citizen.CreateThread(function()
        local ped = PlayerPedId()
        local last = { a = -1, c = -1, t = -1 }
        local started = GetGameTimer()
        local until_ = started + seconds * 1000

        -- Turn infinite ammo OFF for the measurement, and say so. A magazine
        -- that never empties makes every other column unreadable, and it is a
        -- ped flag with a default we do not set.
        if raw then
            local _, hnow = GetCurrentPedWeapon(ped, true)
            if hnow then SetPedInfiniteAmmo(ped, false, hnow) end
            SetPedInfiniteAmmoClip(ped, false)
            print('  (infinite ammo + infinite clip asserted OFF for this run)')
        end

        while GetGameTimer() < until_ do
            local a = GetAmmoInPedWeapon(ped, hash)
            local _, c = GetAmmoInClip(ped, hash)
            local t = GetPedAmmoByType(ped, GetPedAmmoTypeFromWeapon(ped, hash))

            if a ~= last.a or c ~= last.c or t ~= last.t then
                local function delta(now, before)
                    if before < 0 then return '   ' end
                    local d = now - before
                    return d == 0 and '  =' or ('%+3d'):format(d)
                end
                -- TIME AND SHOOTING STATE, because "+1 per shot" and "+1 per
                -- second" produce the identical column and mean completely
                -- different things. The first run could not tell them apart.
                print(('  t%5dms  shooting=%-5s  %6s %s   %6s %s   %6s %s')
                    :format(GetGameTimer() - started,
                            tostring(IsPedShooting(ped)),
                            tostring(a), delta(a, last.a),
                            tostring(c), delta(c, last.c),
                            tostring(t), delta(t, last.t)))
                last.a, last.c, last.t = a, c, t
            end
            Citizen.Wait(100)
        end

        line()
        BR.Inv.suspendAmmo = false
        print('  done. Reading it:')
        print('    pedWeapon is the TOTAL -- magazine included. That is the')
        print('      number br_core reports, and it is the only one that has')
        print('      to be honest: firing lowers it, a reload does not move it.')
        print('    clip is only the SPLIT of that total, for the HUD.')
        print('    A RISING total is refused outright, both here and on the')
        print('      server -- see the note in client/inventory.lua. If it')
        print('      rises in this raw run, that is the engine doing it with')
        print('      our hands off the wheel, and the clamp is what stops it')
        print('      reaching the player.')
        if raw then print('  (br_core ammo writes re-enabled)') end
    end)
end

-- --------------------------------------------------------------------------
-- Screen
-- --------------------------------------------------------------------------

local function screenDump()
    local sw, sh = GetActiveScreenResolution()
    val('GetActiveScreenResolution', ('%dx%d'):format(sw or 0, sh or 0))
    val('  -> derived aspect', ('%.4f'):format((sh and sh > 0) and sw / sh or 0))
    val('GetAspectRatio(false)', GetAspectRatio(false),
        'what DrawSprite actually renders into')
    val('GetAspectRatio(true)', GetAspectRatio(true))
    val('GetScreenAspectRatio', pcall(GetScreenAspectRatio) and GetScreenAspectRatio() or 'n/a')
    local szx, szy = GetSafeZoneSize(), nil
    val('GetSafeZoneSize', szx)

    -- The two disagree on letterboxed and multi-monitor setups, and the one
    -- that matters for a world-anchored sprite is whatever DrawSprite uses.
    print('  NOTE: if the derived aspect and GetAspectRatio disagree, the DUI')
    print('        prompt should use GetAspectRatio -- it is the renderer\'s.')
end

-- --------------------------------------------------------------------------
-- Health and armour
-- --------------------------------------------------------------------------

local function healthDump()
    local ped = PlayerPedId()
    val('GetEntityHealth', GetEntityHealth(ped))
    val('GetEntityMaxHealth', GetEntityMaxHealth(ped))
    val('config maxHealth', BR.Config.Match.maxHealth)
    val('config healthFloor', BR.Config.Match.healthFloor)
    val('GetPedArmour', GetPedArmour(ped))
    val('GetPlayerMaxArmour', GetPlayerMaxArmour(PlayerId()),
        'GTA defaults to 50 and RESETS WITH THE PED')
    val('config maxArmour', BR.Config.Match.maxArmour)
    print('  Try: SetPedArmour(ped, 100) then read GetPedArmour back --')
    print('       if it clamps to 50, SetPlayerMaxArmour was lost with a respawn.')
end

--- Prove the armour ceiling one way or the other.
local function armourTest()
    local ped = PlayerPedId()
    val('before: GetPlayerMaxArmour', GetPlayerMaxArmour(PlayerId()))
    SetPedArmour(ped, 100)
    Citizen.Wait(50)
    val('SetPedArmour(100) -> reads', GetPedArmour(ped))
    SetPlayerMaxArmour(PlayerId(), BR.Config.Match.maxArmour)
    SetPedArmour(ped, 100)
    Citizen.Wait(50)
    val('after SetPlayerMaxArmour -> reads', GetPedArmour(ped))
    print('  If the first read is 50 and the second is 100, the max armour')
    print('  needs re-asserting after every respawn.')
end

-- --------------------------------------------------------------------------
-- Objects and physics
-- --------------------------------------------------------------------------

local testObjects = {}

--- Spawn one crate per flag combination, in a row in front of the player.
---
--- Three rounds of "crates are still anchored" have been three guesses at
--- which call wakes the physics. This spawns all of them at once, labelled,
--- so ONE push settles it: walk or drive into each and report which moved.
local function crateTest()
    local ped = PlayerPedId()
    local p   = GetEntityCoords(ped)
    local f   = GetEntityForwardVector(ped)
    local model = GetHashKey(BR.Config.Loot.chestProp)

    RequestModel(model)
    local waited = 0
    while not HasModelLoaded(model) and waited < 5000 do
        Citizen.Wait(50); waited = waited + 50
    end
    if not HasModelLoaded(model) then
        print('  model never loaded: ' .. BR.Config.Loot.chestProp)
        return
    end

    -- Each variant differs in exactly ONE decision, so whichever moves names
    -- the call that matters.
    local variants = {
        { name = 'A dynamic=false',            dyn = false, phys = false, place = true  },
        { name = 'B dynamic=true',             dyn = true,  phys = false, place = true  },
        { name = 'C dynamic=true +Activate',   dyn = true,  phys = true,  place = true  },
        { name = 'D dynamic=true, no Place',   dyn = true,  phys = true,  place = false },
        { name = 'E dynamic=true, no collide', dyn = true,  phys = true,  place = true,
          noCollide = true },
    }

    for i, v in ipairs(variants) do
        -- Spread sideways so each is reachable on its own.
        local side = (i - 3) * 2.5
        local x = p.x + f.x * 5.0 - f.y * side
        local y = p.y + f.y * 5.0 + f.x * side
        local obj = CreateObjectNoOffset(model, x, y, p.z + 0.5, false, false, v.dyn)
        if obj and obj ~= 0 then
            SetEntityCollision(obj, not v.noCollide, not v.noCollide)
            if v.place then PlaceObjectOnGroundProperly(obj) end
            FreezeEntityPosition(obj, false)
            if v.phys then
                SetEntityDynamic(obj, true)
                SetEntityHasGravity(obj, true)
                ActivatePhysics(obj)
            end
            testObjects[#testObjects + 1] = obj

            print(('  %-30s handle %-7d static=%-5s frozen=%-5s')
                :format(v.name, obj,
                    tostring(IsEntityStatic(obj)),
                    tostring(IsEntityPositionFrozen(obj))))
        else
            print(('  %-30s FAILED TO SPAWN'):format(v.name))
        end
    end

    SetModelAsNoLongerNeeded(model)
    line()
    print('  Left to right: A B C D E. Drive or walk into each.')
    print('  Report which ones MOVE. /brprobe clear removes them.')
end

local function crateClear()
    local n = 0
    for _, obj in ipairs(testObjects) do
        if DoesEntityExist(obj) then DeleteEntity(obj); n = n + 1 end
    end
    testObjects = {}
    print(('  removed %d test object(s)'):format(n))
end

-- --------------------------------------------------------------------------
-- Ground and water, where the player stands
-- --------------------------------------------------------------------------

local function groundDump()
    local p = GetEntityCoords(PlayerPedId())
    val('position', ('%.1f, %.1f, %.1f'):format(p.x, p.y, p.z))

    local ok, gz = GetGroundZFor_3dCoord(p.x, p.y, p.z + 50.0, false)
    val('GetGroundZFor_3dCoord -> ret1', ok)
    val('GetGroundZFor_3dCoord -> ret2', gz)

    local wOk, wz = GetWaterHeight(p.x, p.y, p.z)
    val('GetWaterHeight -> ret1', wOk)
    val('GetWaterHeight -> ret2', wz)

    local nOk, nwz = GetWaterHeightNoWaves(p.x, p.y, p.z)
    val('GetWaterHeightNoWaves -> ret1', nOk)
    val('GetWaterHeightNoWaves -> ret2', nwz)

    print('  Run this standing on land AND in the sea. If the water calls')
    print('  return nothing over open ocean, the ground z is the only signal.')
end

-- --------------------------------------------------------------------------
-- Keys and prompts
-- --------------------------------------------------------------------------

local function keyDump()
    local ctl = BR.Config.Loot.promptControl or 51
    val('promptControl', ctl)
    val('GetControlInstructionalButton', GetControlInstructionalButton(2, ctl, true))
    val('  -> BR.Native.keyLabel', BR.Native.keyLabel(ctl))
    val('inputForCommand(brinteract)', BR.Native.inputForCommand('brinteract'))
    print('  The custom token renders as a HOLE in help text on this build.')
    print('  There is no API to read a RegisterKeyMapping binding back.')
end

-- --------------------------------------------------------------------------
-- The command
-- --------------------------------------------------------------------------

RegisterCommand('brprobe', function(_, args)
    local what = (args[1] or 'all'):lower()

    if what == 'ammo' then
        head('probe: ammo (br_core still managing)')
        ammoWatch(tonumber(args[2]) or 15, false)
        return
    elseif what == 'raw' then
        head('probe: ammo, ENGINE ONLY')
        ammoWatch(tonumber(args[2]) or 15, true)
        return
    elseif what == 'vehicle' then
        head('probe: does a vehicle seat change the ammo readings?')
        print('  Reading now, then get in a vehicle and read again.')
        ammoDump()
        val('IsPedInAnyVehicle', IsPedInAnyVehicle(PlayerPedId(), false))
        print('  The clip reading dropping to 0 in a seat is EXPECTED -- the')
        print('  engine stows the weapon. It must not be reported as ammo lost.')
        return
    elseif what == 'crate' then
        head('probe: crate physics')
        crateTest()
        return
    elseif what == 'clear' then
        crateClear()
        return
    elseif what == 'armour' or what == 'armor' then
        head('probe: armour ceiling')
        Citizen.CreateThread(armourTest)
        return
    end

    head('probe: everything static (no interaction needed)')
    print('  screen'); screenDump(); line()
    print('  health'); healthDump(); line()
    print('  ground'); groundDump(); line()
    print('  keys');   keyDump();    line()
    print('  ammo');   ammoDump();   line()
    print('')
    print('  Interactive modes:')
    print('    /brprobe raw [seconds]    ammo with br_core NOT touching it')
    print('    /brprobe ammo [seconds]   ammo as the game normally runs')
    print('    /brprobe vehicle          what a vehicle seat does to the readings')
    print('    /brprobe armour           prove the 50/100 armour ceiling')
    print('    /brprobe crate            spawn labelled crates to push')
    print('    /brprobe clear            remove them')
end, false)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    crateClear()
end)
