-- Wrappers for natives whose behaviour we do not fully trust yet.
--
-- Every native in here is one of three kinds:
--   (a) verified but easy to misuse, so the correct usage is encoded once;
--   (b) known-broken in some configuration, with the working path chosen here;
--   (c) uncertain on this build, with a documented fallback behind a config flag.
--
-- The point is that when a native turns out to behave differently than expected,
-- exactly one file changes. /brnativecheck exercises these in the lobby and
-- reports what actually works, so the assumptions get tested rather than trusted.

BR = BR or {}
BR.Native = {}

-- The local relationship group holding me + my squadmates. A relationship
-- group hash IS the joaat of its name, so this is constant and safe to read
-- before applyWorldSetup registers the group.
BR.Native.ALLY_GROUP = GetHashKey('BR_ALLY')

-- Implementation switches. Flipped by /brnativecheck findings or by config.
BR.Native.use = {
    spectatorNative = false,  -- false = free-cam + SetFocusEntity (the safer default)
    stormPostFx     = false,  -- off until an effect name is confirmed in-game
}

-- ---------------------------------------------------------------- parachute ---

-- GET_PED_PARACHUTE_STATE return values (verified against citizenfx/natives).
BR.Native.ChuteState = {
    NONE     = -1,  -- no parachute
    ON_BACK  =  0,  -- equipped, not deployed
    OPENING  =  1,
    OPEN     =  2,
    FREEFALL =  3,  -- "falling to doom"
}

--- Put the local player into the drop.
---
--- TASK_PARACHUTE's second parameter is VERIFIED UNUSED -- it is a vestigial
--- jetpack flag from early development and does NOT give the player a chute.
--- Skipping the explicit grant is the single easiest way to break the drop.
function BR.Native.beginSkydive()
    local ped = PlayerPedId()
    GiveWeaponToPed(ped, BR.Config.Gadgets.PARACHUTE, 1, false, false)

    local model = BR.Config.Drop.parachuteModel
    if model then
        SetPlayerParachuteModelOverride(PlayerId(), GetHashKey(model))
    end
    SetPlayerHasReserveParachute(PlayerId())   -- ensure a known state, then disable below
    TaskParachute(ped, true, false)
end

--- @return integer one of BR.Native.ChuteState
function BR.Native.chuteState()
    return GetPedParachuteState(PlayerPedId())
end

--- Metres above ground, used to decide when to force the glider open.
--- @return number
function BR.Native.heightAboveGround()
    return GetEntityHeightAboveGround(PlayerPedId())
end

function BR.Native.forceOpenChute()
    ForcePedToOpenParachute(PlayerPedId())
end

function BR.Native.endSkydive()
    RemoveWeaponFromPed(PlayerPedId(), BR.Config.Gadgets.PARACHUTE)
end

-- ------------------------------------------------------------------ ragdoll ---

--- Knock the player down for the DBNO transition.
---
--- Ragdoll type 1 (CTaskNMScriptControl) is DOCUMENTED AS NON-FUNCTIONAL in
--- networked environments, so it is never used here. Type 0 (CTaskNMRelax) is the
--- only viable option, and only for the knockdown instant -- sustained ragdoll is
--- too unstable to hold a player in, so the crawl is animation-driven.
--- @param minMs integer
--- @param maxMs integer
function BR.Native.knockdown(minMs, maxMs)
    local ped = PlayerPedId()
    SetPedCanRagdoll(ped, true)
    SetPedToRagdoll(ped, minMs or 1500, maxMs or 2000, 0, false, false, false)
end

-- ------------------------------------------------------------------- health ---

--- Read the local player's health in DISPLAY units (0..100).
--- Engine health runs 100..200 for a living player ped -- the floor IS the
--- conventional 100 (settled by a live death at exactly half bar under the
--- old 0..200 mapping); see BR.ToDisplayHp and the config note.
--- @return number
function BR.Native.displayHealth()
    return BR.ToDisplayHp(GetEntityHealth(PlayerPedId()))
end

--- Apply a server-authoritative health correction, in display units.
--- @param display number
function BR.Native.setDisplayHealth(display)
    SetEntityHealth(PlayerPedId(), BR.ToEngineHp(display))
end

--- Damage or heal. APPLY_DAMAGE_TO_PED heals on negative values, so this single
--- native covers storm damage, medkits and shield potions.
--- @param amount number   positive damages, negative heals
--- @param armourFirst boolean
function BR.Native.applyDamage(amount, armourFirst)
    ApplyDamageToPed(PlayerPedId(), math.floor(amount + 0.5), armourFirst and true or false)
end

--- Normalise the player's health model at match start.
function BR.Native.initHealthModel()
    local ped = PlayerPedId()
    SetEntityMaxHealth(ped, BR.Config.Match.maxHealth)
    SetEntityHealth(ped, BR.Config.Match.maxHealth)
    SetPedArmour(ped, 0)
    SetPlayerMaxArmour(PlayerId(), BR.Config.Match.maxArmour)
    -- Passive regeneration would quietly undo the whole damage model.
    SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0)
end

-- -------------------------------------------------------------------- blips ---

--- Radius blips CANNOT be resized in place -- the blip must be removed and
--- re-added. Callers pass the previous handle back in and get a new one.
--- @param existing integer|nil
--- @param x number
--- @param y number
--- @param radius number
--- @param colour integer
--- @param alpha integer
--- @return integer blip
function BR.Native.radiusBlip(existing, x, y, radius, colour, alpha)
    if existing and DoesBlipExist(existing) then
        RemoveBlip(existing)
    end
    local blip = AddBlipForRadius(x, y, 0.0, radius)
    SetBlipColour(blip, colour)
    SetBlipAlpha(blip, alpha)
    SetBlipHighDetail(blip, true)
    return blip
end

-- ----------------------------------------------------------------- spectate ---

--- Attach the spectator camera to a target.
---
--- NETWORK_SET_IN_SPECTATOR_MODE requires the target ped to EXIST LOCALLY. Under
--- OneSync a target across the map is out of scope, so the ped handle is 0 and
--- the native silently does nothing. The natives that would widen entity culling
--- are deprecated with known unfixable issues, so there is no way to force the
--- target to stream in from range.
---
--- The default path is therefore a free camera plus SET_FOCUS_ENTITY / focus
--- position, which forces the world to stream around a remote point and does not
--- fight the sync layer. The engine spectator mode is kept behind a flag for
--- comparison once it has been tested in-game.
---
--- @param targetSrc integer  server id of the target
--- @param pos table          server-supplied { x, y, z } -- the client cannot
---                           discover this itself for an out-of-scope player
--- @return boolean attached
function BR.Native.spectate(targetSrc, pos)
    if BR.Native.use.spectatorNative then
        -- scope-ok: resolving a ped handle for the spectator camera only. The
        -- server supplied the position and the client has already been moved
        -- into range, so this is a scope LOOKUP, not a source of game state.
        -- A -1 here means "not streamed yet", never "not in the match".
        local plyIdx = GetPlayerFromServerId(targetSrc)          -- scope-ok: spectator camera
        if plyIdx ~= -1 then
            local ped = GetPlayerPed(plyIdx)                     -- scope-ok: spectator camera
            if ped and ped ~= 0 then
                NetworkSetInSpectatorMode(true, ped)
                return true
            end
        end
        -- fall through to the free-cam path rather than leaving a black screen
    end

    if pos then
        SetFocusPosAndVel(pos.x, pos.y, pos.z, 0.0, 0.0, 0.0)
        return true
    end
    return false
end

function BR.Native.stopSpectate()
    if BR.Native.use.spectatorNative and NetworkIsInSpectatorMode() then
        NetworkSetInSpectatorMode(false, PlayerPedId())
    end
    ClearFocus()
end

-- -------------------------------------------------------------- key prompts ---

--- A native GTA help box (top-left). Used for every prompt that references a
--- key: ~INPUT_*~ placeholders render the player's ACTUAL binding, which no
--- NUI toast can do -- hardcoding "SPACE" into toast text lied to anyone who
--- had rebound it.
--- @param text string  may contain ~INPUT_*~ placeholders
function BR.Native.help(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, true, -1)
end

--- The per-frame variant: call every frame and the box PERSISTS, vanishing
--- the frame the caller stops. This is how a prompt stays up "until they
--- actually do it" -- the one-shot above fades on the engine's own clock,
--- which is why the doors prompt kept disappearing mid-flight. No beep:
--- sounding it every frame would be a siren.
--- @param text string
function BR.Native.helpThisFrame(text)
    BeginTextCommandDisplayHelp('STRING')
    AddTextComponentSubstringPlayerName(text)
    EndTextCommandDisplayHelp(0, false, false, -1)
end

--- The ~INPUT_~ placeholder for one of OUR keymapped commands (keybinds.lua),
--- resolving to whatever the player bound under Settings > Key Bindings >
--- FiveM. The hash convention (joaat of the command name with the high bit
--- set) is the documented RegisterKeyMapping instructional-button contract.
--- @param command string  the command name as registered, e.g. 'brdeploy'
--- @return string
function BR.Native.inputForCommand(command)
    return ('~INPUT_%08X~'):format((GetHashKey(command) | 0x80000000) & 0xFFFFFFFF)
end

-- ------------------------------------------------------------- storm screen ---

local stormFxActive = false

--- @param inside boolean  true when the player is outside the safe circle
function BR.Native.setStormScreen(inside)
    local fx = BR.Config.Storm.fx
    if inside == stormFxActive then return end
    stormFxActive = inside

    if inside then
        if fx.useTimecycle then
            SetTimecycleModifier(fx.timecycle)
            SetTimecycleModifierStrength(fx.timecycleTarget)
        end
        -- postFX names are the most likely thing to differ between builds, so
        -- this stays off until /brfx confirms one. The timecycle plus the NUI
        -- vignette keep the storm fully readable without it.
        if fx.usePostFx and BR.Native.use.stormPostFx then
            AnimpostfxPlay(fx.postFx, 0, true)
        end
    else
        ClearTimecycleModifier()
        if fx.usePostFx and BR.Native.use.stormPostFx then
            AnimpostfxStop(fx.postFx)
        end
    end
end

-- --------------------------------------------------------------- game rules ---

--- Strip the vanilla systems that make no sense in a battle royale. Called from
--- the frame loop because several of these reset themselves every tick.
function BR.Native.applyGameRules()
    local pid = PlayerId()

    SetMaxWantedLevel(0)
    SetPlayerWantedLevel(pid, 0, false)
    SetPlayerWantedLevelNow(pid, false)
    SetCreateRandomCops(false)
    SetCreateRandomCopsNotOnScenarios(false)
    SetCreateRandomCopsOnScenarios(false)

    -- PvP, with two carve-outs, both enforced on the SHOOTER's client where
    -- GTA computes bullet damage:
    --
    --   Squadmates: my ped and my squadmates' local peds share the BR_ALLY
    --   relationship group (squadmates.lua assigns theirs as they stream in),
    --   and canAttackFriendly = false means same-group damage is refused.
    --   Everyone else stays in the engine's default PLAYER group, which
    --   BR_ALLY hates -- so enemies take damage exactly as before. This is
    --   the same lever that made PvP work in the first place (default no-PvP
    --   IS "everyone in PLAYER + canAttackFriendly false"), pointed at a
    --   group that now only contains my own squad.
    --
    --   Warmup: my own ped is simply invincible. Everyone's client does the
    --   same, so nobody can be hurt by anything until the bus.
    --
    -- Per-frame like the rest: the ped handle changes on respawn, and the
    -- group assignment dies with the old handle.
    local ped = PlayerPedId()
    NetworkSetFriendlyFireOption(true)
    SetPedRelationshipGroupHash(ped, BR.Native.ALLY_GROUP)
    SetCanAttackFriendly(ped, false, false)

    -- Peace while nobody can meaningfully fight back: the warmup pad, the
    -- bus ride, THE WHOLE DESCENT, and half a second after touchdown. The
    -- descent matters most -- a chute that fails to open must cost the drop,
    -- never the life; the invincibility holds until the landing grace runs
    -- out no matter how hard the ground arrives.
    local st = BR.State.me.state
    SetPlayerInvincible(pid,
        st == BR.PlayerState.WARMUP
        or st == BR.PlayerState.BUS
        or st == BR.PlayerState.LOBBY
        or st == BR.PlayerState.FREEFALL
        or st == BR.PlayerState.GLIDE
        or GetGameTimer() < (BR.State.dropGraceUntil or 0))

    -- The lobby is a menu with a view -- no ped in the shot, and no ped
    -- FALLING OUT of the shot: the vista point floats above the hillside,
    -- so an unfrozen ped drops on camera. The bus rider is hidden too, but
    -- NOT frozen: it rides attached inside the plane, and the old per-frame
    -- BUS freeze was still re-freezing for the ~250ms after a jump while
    -- the roster still said BUS -- fighting TaskParachute in exactly the
    -- frames it needed the ped falling. That race was the dead SPACE key.
    -- The freeze deliberately never RELEASES here: spawn placement holds
    -- its own temporary freezes while collision loads, and stomping those
    -- drops players through the world.
    SetEntityVisible(ped,
        st ~= BR.PlayerState.LOBBY and st ~= BR.PlayerState.BUS, false)
    if st == BR.PlayerState.LOBBY then
        FreezeEntityPosition(ped, true)
    end

    -- The radar follows MY state, owned here like every other per-frame
    -- rule: hidden in the LOBBY (it used to poke out under the menu after a
    -- match), shown for every in-match state. This replaces the point calls
    -- spawn.lua made at ENDED/WAITING, which said the right thing for match
    -- participants and the wrong thing for everyone idling in the lobby.
    DisplayRadar(st ~= BR.PlayerState.LOBBY)

    -- GTA's own feed ("X joined", "Y died", weapon unlocks, whatever any other
    -- resource posts). The gamemode owns its presentation -- eliminations go
    -- through the kill feed, everything personal through the notice stack --
    -- so the engine ticker only ever duplicates or contradicts them.
    -- NOTE: this also silences vMenu's notifications, deliberately.
    ThefeedHideThisFrame()

    -- The cash/bank readout pops top-right at load-in and every time the
    -- pause menu closes. There is no money in a battle royale.
    HideHudComponentThisFrame(3)   -- HUD_CASH
    HideHudComponentThisFrame(4)   -- HUD_MP_CASH (the bank line)

    -- The corner busy spinner ("Loading...") -- the engine raises it during
    -- session setup and other resources may leave one on. The convar
    -- sv_showBusySpinnerOnLoadingScreen only covers the phase BEFORE scripts
    -- run; from the first frame we own, nothing of the engine's spins.
    if BusyspinnerIsOn() then BusyspinnerOff() end

    -- AMBIENT LIFE, throttled rather than zeroed (user call, 2026-08-04):
    -- the routing bucket's population flag is the on/off switch (matches
    -- on, lobby off -- roster.applyBucket), and these set HOW MUCH streams
    -- in where it is on. Zeroed during the lobby/warmup states anyway --
    -- the island stays a stage.
    local amb = BR.Config.Ambient
    local inWorld = st ~= BR.PlayerState.LOBBY and st ~= BR.PlayerState.WARMUP
    SetVehicleDensityMultiplierThisFrame(inWorld and amb.vehicles or 0.0)
    SetPedDensityMultiplierThisFrame(inWorld and amb.peds or 0.0)
    SetScenarioPedDensityMultiplierThisFrame(
        inWorld and amb.scenarioPeds or 0.0, inWorld and amb.scenarioPeds or 0.0)
    SetRandomVehicleDensityMultiplierThisFrame(inWorld and amb.vehicles or 0.0)
    SetParkedVehicleDensityMultiplierThisFrame(inWorld and amb.parked or 0.0)

    -- HIGH NOON, FOREVER (for now -- user call, 2026-08-04). Weather is
    -- already gamemode-owned; the clock joins it. Overridden per frame so
    -- nothing else can advance it.
    NetworkOverrideClockTime(12, 0, 0)

    -- Never let the engine's own death/respawn flow run; the gamemode owns it.
    PauseDeathArrestRestart(true)
    SetFadeOutAfterDeath(false)
    IgnoreNextRestart(true)
end

--- One-time world setup at resource start.
function BR.Native.applyWorldSetup()
    SetGarbageTrucks(false)
    SetRandomBoats(false)
    SetRandomTrains(false)
    DistantCopCarSirens(false)
    SetAudioFlag('PoliceScannerDisabled', true)

    -- The squad relationship group. Local to this client, like all
    -- relationship state: MY view groups me and my squadmates together, an
    -- enemy's view groups me with the default PLAYER crowd -- and since each
    -- client's own shots are computed against its own view, both are right.
    AddRelationshipGroup('BR_ALLY')
    local player = GetHashKey('PLAYER')
    -- 5 = hate: BR_ALLY (me + squad) will damage the PLAYER group (everyone
    -- else) and vice versa. Within BR_ALLY, canAttackFriendly = false rules.
    SetRelationshipBetweenGroups(5, BR.Native.ALLY_GROUP, player)
    SetRelationshipBetweenGroups(5, player, BR.Native.ALLY_GROUP)
end

-- ------------------------------------------------------------ native check ---

--- Probe the natives this file depends on and report what is actually available.
---
--- This exists because "the native is documented" and "the native behaves as
--- documented on this build" are different claims, and the second one is the one
--- that matters. Run it in the lobby after any client update.
---
--- @return table array of { name, ok, detail }
function BR.Native.check()
    local results = {}
    local function probe(name, fn)
        local ok, err = pcall(fn)
        results[#results + 1] = { name = name, ok = ok, detail = ok and '' or tostring(err) }
    end

    local ped = PlayerPedId()

    probe('GetPedParachuteState',    function() return GetPedParachuteState(ped) end)
    probe('GetEntityHeightAboveGround', function() return GetEntityHeightAboveGround(ped) end)
    probe('SetPlayerParachuteModelOverride', function()
        SetPlayerParachuteModelOverride(PlayerId(), GetHashKey(BR.Config.Drop.parachuteModel))
    end)
    probe('SetPedCanRagdoll',        function() SetPedCanRagdoll(ped, true) end)
    probe('GetEntityHealth',         function() return GetEntityHealth(ped) end)
    probe('SetEntityMaxHealth',      function() SetEntityMaxHealth(ped, BR.Config.Match.maxHealth) end)
    probe('GetPedArmour',            function() return GetPedArmour(ped) end)
    probe('SetPlayerMaxArmour',      function() SetPlayerMaxArmour(PlayerId(), BR.Config.Match.maxArmour) end)
    probe('SetPlayerHealthRechargeMultiplier', function()
        SetPlayerHealthRechargeMultiplier(PlayerId(), 0.0)
    end)
    probe('AddBlipForRadius',        function()
        local b = AddBlipForRadius(0.0, 0.0, 0.0, 100.0)
        RemoveBlip(b)
    end)
    probe('DrawMarker',              function()
        DrawMarker(1, 0.0, 0.0, -200.0, 0,0,0, 0,0,0, 1.0,1.0,1.0, 0,0,0, 0, false, false, 2, false, nil, nil, false)
    end)
    probe('SetTimecycleModifier',    function()
        SetTimecycleModifier(BR.Config.Storm.fx.timecycle)
        ClearTimecycleModifier()
    end)
    -- The underscore is real: FiveM keeps it when a native name segment
    -- starts with a digit. The unadorned spelling is nil, and the storm wall
    -- shipped calling it once -- this probe is what makes that a boot-time
    -- finding instead of a per-frame error spam report.
    probe('GetGroundZFor_3dCoord',   function()
        return GetGroundZFor_3dCoord(0.0, 0.0, 500.0, false)
    end)
    probe('SetFocusPosAndVel',       function()
        SetFocusPosAndVel(0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        ClearFocus()
    end)
    probe('NetworkIsInSpectatorMode', function() return NetworkIsInSpectatorMode() end)
    probe('CreateObjectNoOffset',    function()
        -- isNetwork = false is the whole basis of the loot design; if this ever
        -- starts producing networked entities the server will not survive it.
        local m = GetHashKey('prop_box_ammo04a')
        RequestModel(m)
        local obj = CreateObjectNoOffset(m, 0.0, 0.0, -200.0, false, false, false)
        if obj and obj ~= 0 then DeleteEntity(obj) end
        SetModelAsNoLongerNeeded(m)
    end)
    probe('PauseDeathArrestRestart', function() PauseDeathArrestRestart(true) end)

    -- The health model assumption that most affects gameplay: does a player ped
    -- really floor at 100 rather than 0?
    local maxH = GetEntityMaxHealth(ped)
    results[#results + 1] = {
        name   = 'health model',
        ok     = true,
        detail = ('engine max=%d, configured max=%d, floor=%d -- verify a dead player reads <= floor')
            :format(maxH, BR.Config.Match.maxHealth, BR.Config.Match.healthFloor),
    }

    return results
end
