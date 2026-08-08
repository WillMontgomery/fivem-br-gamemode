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

-- THE DROP SEQUENCE LIVES IN client/skydive.lua, AND NOWHERE ELSE.
--
-- There used to be a BR.Native.beginSkydive()/endSkydive() pair here, an M3
-- draft that nothing ever called once skydive.lua grew the real (verified,
-- retried) sequence. It was deleted rather than left as a convenience, because
-- of the line it carried: SetPlayerHasReserveParachute(PlayerId()), whose
-- comment promised a disable that was never written. A second give path for
-- the chute is the exact shape of every reserve-parachute bug this project has
-- had, and one that hands out a reserve deliberately would have been the last
-- one anybody looked for. If a helper is wanted again, it calls into
-- skydive.lua -- it does not re-implement it.
--
-- TASK_PARACHUTE's second parameter is VERIFIED UNUSED -- a vestigial jetpack
-- flag that does NOT give the player a chute. Skipping the explicit
-- GiveWeaponToPed is still the single easiest way to break the drop.

-- ------------------------------------------------------------------- aiming ---

--- What is the player standing in front of?
---
--- Built for loot ("which crate am I facing"), but deliberately generic:
--- doors, revives, vehicles and interactables all want the same question
--- answered, and answering it twice in two places is how two systems end up
--- disagreeing about what the player is pointing at.
---
--- FROM THE PED, NOT THE CAMERA (user call, 2026-08-05). The camera version
--- lets you loot something by glancing at it while walking past; the ped's
--- own facing means you have to turn towards the thing, which is what "stand
--- in front of it" means and what the interaction distance is measured from.
--- The ray starts at chest height so it clears the crate's own footprint and
--- angles down slightly, since everything interactable is on the floor.
---
--- The probe is the SYNCHRONOUS variant: it costs more than the asynchronous
--- one, but the asynchronous one answers on a later frame, and a prompt that
--- appears a frame after you turn to something is a prompt that flickers.
---
--- @param maxDist number   metres ahead of the ped
--- @param flags integer|nil shapetest flags; default 16 = objects only
--- @return boolean hit
--- @return table|nil coords  { x, y, z } where it hit
--- @return integer entity    the entity hit, or 0
function BR.Native.aim(maxDist, flags)
    local ped = PlayerPedId()
    local p   = GetEntityCoords(ped)
    local fwd = GetEntityForwardVector(ped)
    local d   = maxDist or 4.0

    -- Chest height forward, ankle height at the far end: a flat ray at chest
    -- height sails over a crate on the floor, and a flat one at ankle height
    -- catches every kerb between here and there.
    local sx, sy, sz = p.x, p.y, p.z + 0.55
    local ex, ey, ez = p.x + fwd.x * d, p.y + fwd.y * d, p.z - 0.35

    local handle = StartExpensiveSynchronousShapeTestLosProbe(
        sx, sy, sz, ex, ey, ez,
        flags or 16,   -- 16 = objects
        ped,           -- ignore ourselves
        4)
    local _, hit, endCoords, _, entity = GetShapeTestResult(handle)

    if hit == 1 or hit == true then
        return true, endCoords, entity or 0
    end
    return false, nil, 0
end

--- The key currently bound to a GTA control, as a letter we can print.
---
--- GET_CONTROL_INSTRUCTIONAL_BUTTON returns a glyph token ("t_E", "b_32")
--- rather than a name, so the readable half is what comes after the prefix.
--- This is how the interaction prompt shows a real key without hardcoding one:
--- rebind INPUT_CONTEXT in GTA's settings and the prompt follows.
---
--- Returns nil when the token is not a plain key (a controller button, say),
--- and the caller falls back to words.
--- @param control integer
--- @return string|nil
function BR.Native.keyLabel(control)
    local ok, raw = pcall(GetControlInstructionalButton, 2, control, true)
    if not ok or type(raw) ~= 'string' then return nil end
    local letter = raw:match('^t_(.+)$')
    if letter and #letter <= 5 then return letter end
    return nil
end

-- BR.Native.worldToScreen was deleted with the NUI loot prompt.
--
-- It existed to tell the UI where a crate was on screen, which is the thing
-- DUI removes the need for entirely: the prompt is now a texture drawn at a
-- world position by SetDrawOrigin, so nothing has to project anything. Left
-- as a note because "how do I put a UI element over a world object" is a
-- question that will come up again, and the answer is now client/dui.lua
-- rather than a screen-space round trip.

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
    -- match), hidden ABOARD THE BUS (the ride is a cutscene; the map lives
    -- on the pause screen -- user call, 2026-08-04), shown for every other
    -- in-match state. This replaces the point calls spawn.lua made at
    -- ENDED/WAITING, which said the right thing for match participants and
    -- the wrong thing for everyone idling in the lobby.
    -- ...and never over a scope. This runs every FRAME, so it is the call that
    -- actually decides: screen.lua sets DisplayRadar when the scope state
    -- changes, and without this line that setting would be overwritten here
    -- within a millisecond and the minimap would sit on the scaleform.
    DisplayRadar(st ~= BR.PlayerState.LOBBY and st ~= BR.PlayerState.BUS
        and not (BR.Screen and BR.Screen.scoped))

    -- GTA's own feed ("X joined", "Y died", weapon unlocks, whatever any other
    -- resource posts). The gamemode owns its presentation -- eliminations go
    -- through the kill feed, everything personal through the notice stack --
    -- so the engine ticker only ever duplicates or contradicts them.
    -- NOTE: this also silences vMenu's notifications, deliberately.
    ThefeedHideThisFrame()

    -- The cash/bank readout pops top-right at load-in and every time the
    -- pause menu closes. There is no money in a battle royale. The area
    -- and street names ("Grand Senora Desert") go with them -- the map is
    -- the gamemode's to narrate (user call, 2026-08-04).
    HideHudComponentThisFrame(3)   -- HUD_CASH
    HideHudComponentThisFrame(4)   -- HUD_MP_CASH (the bank line)
    HideHudComponentThisFrame(7)   -- HUD_AREA_NAME
    HideHudComponentThisFrame(9)   -- HUD_STREET_NAME

    -- GTA'S OWN WEAPON AND AMMO READOUT (user call, 2026-08-06). The
    -- inventory bar IS the ammo counter -- it shows the magazine, the reserve
    -- and which of five slots is up. The engine's version sits in the same
    -- corner showing a subset of that, from its own idea of what the ped
    -- holds, and the two disagree by design: ours is the server's number.
    HideHudComponentThisFrame(2)   -- HUD_WEAPON_ICON (the ammo counter)

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
    -- already gamemode-owned; the clock joins it. The SECONDS still spin
    -- (invisible at sun-angle scale) so any engine system that steps on
    -- clock deltas -- wetness decay is a suspect -- keeps stepping.
    NetworkOverrideClockTime(12, 0, math.floor(GetGameTimer() / 1000) % 60)

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
    -- The chute's AMMO, not its presence, is what the engine reads as "has a
    -- parachute available" -- the disarm path checks it and the landing retry
    -- loop exits on it, so a nil here would silently re-arm every player.
    probe('GetAmmoInPedWeapon',      function()
        return GetAmmoInPedWeapon(ped, BR.Config.Gadgets.PARACHUTE)
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
    -- Dead squadmates keep a dimmed blip; a nil here would leave every
    -- eliminated mate looking alive on the minimap.
    probe('SetBlipAlpha',            function()
        local b = AddBlipForCoord(0.0, 0.0, 0.0)
        SetBlipAlpha(b, 120)
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

    -- M5 loot and inventory. Every one of these is load-bearing on a path the
    -- unit tests cannot reach (they stub natives), and a misspelled native is
    -- nil rather than an error -- which is how GetGroundZFor_3dCoord cost a
    -- day. Probe first, test in-game second.
    probe('GetWeapontypeModel',      function()
        -- Weapons on the ground are drawn as the engine's own model for the
        -- weapon rather than 35 hand-typed prop names.
        return GetWeapontypeModel(BR.Config.WeaponById['pistol'].hash)
    end)
    probe('PlaceObjectOnGroundProperly', function()
        local m = GetHashKey('prop_box_ammo04a')
        RequestModel(m)
        local obj = CreateObjectNoOffset(m, 0.0, 0.0, -200.0, false, false, false)
        if obj and obj ~= 0 then
            PlaceObjectOnGroundProperly(obj)
            DeleteEntity(obj)
        end
        SetModelAsNoLongerNeeded(m)
    end)
    -- The ammo report reads this every 500ms. A nil here reports clip 0 for
    -- every weapon forever, and the server accepts decreases -- so a wrong
    -- name would quietly empty every magazine in the match.
    probe('GetAmmoInClip',           function()
        local _, clip = GetAmmoInClip(ped, BR.Config.WeaponById['pistol'].hash)
        return clip
    end)
    probe('GetAmmoInPedWeapon',      function()
        return GetAmmoInPedWeapon(ped, BR.Config.WeaponById['pistol'].hash)
    end)
    probe('SetAmmoInClip',           function()
        -- Harmless on a ped that does not hold the weapon; the point is only
        -- that the name resolves.
        SetAmmoInClip(ped, BR.Config.WeaponById['pistol'].hash, 0)
    end)
    probe('SetDrawOrigin',           function()
        SetDrawOrigin(0.0, 0.0, -200.0, 0)
        ClearDrawOrigin()
    end)
    -- The no-teamkill net reads these every frame that health drops. A nil
    -- here means friendly fire silently works again.
    probe('HasEntityBeenDamagedByEntity', function()
        return HasEntityBeenDamagedByEntity(ped, ped, true)
    end)
    probe('ClearEntityLastDamageEntity', function()
        ClearEntityLastDamageEntity(ped)
    end)
    probe('GetPlayerHasReserveParachute', function()
        return GetPlayerHasReserveParachute(PlayerId())
    end)
    -- The interaction ray. Without it there is no pickup system at all -- the
    -- prompt would never resolve a target.
    probe('StartExpensiveSynchronousShapeTestLosProbe', function()
        local h = StartExpensiveSynchronousShapeTestLosProbe(
            0.0, 0.0, -200.0, 0.0, 0.0, -190.0, 16, PlayerPedId(), 4)
        local _, hit = GetShapeTestResult(h)
        return hit
    end)
    -- The interaction ray's DIRECTION. BR.Native.aim() fires along the ped's
    -- forward vector (user call: you turn towards a thing to interact with
    -- it), so a nil here is a ray that always points at world origin.
    probe('GetEntityForwardVector',  function() return GetEntityForwardVector(ped) end)
    -- LOOT CHOREOGRAPHY. Loose items arc out of crates, hover when you are in
    -- range and fly to your hands when taken -- all of which is these two
    -- natives called per frame on a prop. A nil in either is not a subtle
    -- failure: it throws every frame, and five throws suspend loot.render,
    -- which takes the glow, the labels and the prompt with it.
    --
    -- NoOffset specifically: SetEntityCoords applies a model-height offset
    -- that would sink the item into the ground as it lands.
    probe('SetEntityCoordsNoOffset', function()
        return SetEntityCoordsNoOffset ~= nil
    end)
    probe('SetEntityHeading', function() return GetEntityHeading(ped) end)
    -- Reads the player's ACTUAL binding for the prompt's key badge. Without
    -- it the prompt shows no key at all.
    probe('GetControlInstructionalButton', function()
        return GetControlInstructionalButton(2, BR.Config.Loot.promptControl or 51, true)
    end)
    -- DUI: the loot prompt is a browser page rendered into a game texture and
    -- drawn as a world sprite. Four natives, all load-bearing -- a nil in any
    -- of them is a prompt that never appears at all.
    probe('CreateRuntimeTxd',        function()
        local txd = CreateRuntimeTxd('br_probe_txd')
        return txd ~= nil
    end)
    probe('CreateDui + DestroyDui',  function()
        local d = CreateDui('nui://br_ui/dui/prompt.html', 8, 8)
        local h = GetDuiHandle(d)
        DestroyDui(d)
        return h
    end)
    -- The ammo report skips a reloading ped: mid-swap the magazine reads as
    -- whatever the animation has reached, which is not a number to build on.
    probe('IsPedReloading',          function() return IsPedReloading(ped) end)
    probe('IsPedShooting',           function() return IsPedShooting(ped) end)
    -- MEASURED: with our own ammo writes suspended, the magazine did not move
    -- while firing and the totals rose by one per shot -- the signature of an
    -- infinite-ammo clip. Nothing here turns it on, which is exactly why it is
    -- asserted OFF on every weapon grant: it is a ped flag with a default we
    -- do not control.
    probe('SetPedInfiniteAmmo',      function()
        SetPedInfiniteAmmo(ped, false, BR.Config.WeaponById['pistol'].hash)
    end)
    probe('SetPedInfiniteAmmoClip',  function() SetPedInfiniteAmmoClip(ped, false) end)
    -- Closing GTA's pause menu out from under our own screens: a player killed
    -- with the map open arrived in the lobby with the frontend still up.
    probe('IsPauseMenuActive',       function() return IsPauseMenuActive() end)
    probe('SetFrontendActive',       function()
        -- Only ever called when the pause menu IS active, so this probe must
        -- not call it blind -- SetFrontendActive(false) on a closed frontend
        -- is harmless but proves nothing about the open case.
        return IsPauseMenuActive() and 'menu open (not touched by probe)'
            or 'menu closed'
    end)
    -- Crate drag. Prop physics has no useful friction, so a shunted crate is
    -- slowed by scaling its own velocity down each tick.
    probe('GetEntityVelocity',       function()
        local v = GetEntityVelocity(ped)
        return ('%.2f,%.2f,%.2f'):format(v.x, v.y, v.z)
    end)
    probe('SetEntityVelocity',       function()
        -- On the PED, and with its own current velocity: this is a no-op that
        -- still proves the native exists and takes three floats.
        local v = GetEntityVelocity(ped)
        SetEntityVelocity(ped, v.x, v.y, v.z)
    end)
    -- Stops the engine choosing the weapon on pickup and on empty, which
    -- otherwise fights the active-slot model for control of the hand.
    -- ox_inventory sets this for the same reason.
    probe('SetWeaponsNoAutoswap',    function() SetWeaponsNoAutoswap(true) end)
    -- Passengers must be able to fire; without this GTA refuses drive-bys
    -- outright and a car is a coffin for everyone who is not driving.
    probe('SetPlayerCanDoDriveBy',   function()
        SetPlayerCanDoDriveBy(PlayerId(), true)
    end)
    -- Taking a weapon the server never issued back out of the hand, so a
    -- trainer-spawned rifle cannot even produce the local corpse.
    probe('RemoveWeaponFromPed',     function()
        -- A weapon the player will not have: proves the binding without
        -- disarming anybody mid-probe.
        RemoveWeaponFromPed(ped, GetHashKey('WEAPON_RAILGUN'))
    end)
    -- Undoing a refused shot on the SHOOTER's screen. The engine applies
    -- damage locally before the server sees the event, so a cancelled shot
    -- still leaves a corpse there -- and health alone does not revive a ped
    -- that has entered the death state.
    probe('ResurrectPed',            function()
        -- On the player's own ped, which is alive: a no-op that proves the
        -- binding without disturbing anything.
        if not IsEntityDead(ped) then ResurrectPed(ped) end
        return 'not called on a live ped'
    end)
    probe('ClearPedTasksImmediately', function()
        -- NOT called on the player -- it would cancel whatever they are doing.
        return IsEntityDead(ped) and 'ped is dead' or 'ped alive (not called)'
    end)
    probe('NetworkDoesNetworkIdExist', function()
        return NetworkDoesNetworkIdExist(NetworkGetNetworkIdFromEntity(ped))
    end)
    probe('NetworkGetEntityFromNetworkId', function()
        local id = NetworkGetNetworkIdFromEntity(ped)
        return NetworkGetEntityFromNetworkId(id) == ped
            and 'round-trips to the same ped' or 'MISMATCH'
    end)
    -- The mouse wheel belongs to the scope while aiming, not to slot cycling.
    probe('IsPlayerFreeAiming',      function()
        return IsPlayerFreeAiming(PlayerId())
    end)
    -- Ambient drivers who drive like maniacs. Ability and aggression alone did
    -- nothing visible -- the driving TASK and its style flags are what decide
    -- whether a ped stops at a light or drives through the junction.
    probe('SetPedKeepTask',          function() SetPedKeepTask(ped, true) end)
    probe('SetDriveTaskDrivingStyle', function()
        -- On the PLAYER's ped, which has no drive task: a no-op that still
        -- proves the binding exists.
        SetDriveTaskDrivingStyle(ped, 262656)
    end)
    probe('SetDriverRacingModifier', function()
        SetDriverRacingModifier(ped, 1.0)
    end)
    -- Killing an NPC makes the engine drop their weapon as a vanilla pickup,
    -- which has none of our loot's affordances and puts a gun in the ped's
    -- hands the inventory has never heard of.
    probe('SetPedDropsWeaponsWhenDead', function()
        SetPedDropsWeaponsWhenDead(ped, false)
    end)
    -- Reading a corpse for the weapon it was holding, so an NPC kill drops one
    -- of OUR entries instead of a vanilla pickup.
    probe('IsPedDeadOrDying',        function()
        return IsPedDeadOrDying(ped, true)
    end)
    probe('GetGamePool(CPed)',       function()
        return ('%d peds in the world'):format(#GetGamePool('CPed'))
    end)
    probe('GetGamePool(CPickup)',    function()
        return ('%d pickups in the world'):format(#GetGamePool('CPickup'))
    end)
    probe('DoesPickupExist',         function()
        local pool = GetGamePool('CPickup')
        return #pool > 0 and tostring(DoesPickupExist(pool[1])) or 'no pickups'
    end)
    probe('GetPickupCoords',         function()
        local pool = GetGamePool('CPickup')
        if #pool == 0 then return 'no pickups' end
        local c = GetPickupCoords(pool[1])
        return c and ('%.1f,%.1f,%.1f'):format(c.x, c.y, c.z) or 'nil'
    end)
    probe('RemovePickup',            function()
        -- NOT called blind: removing a live pickup would be the probe changing
        -- the world. Existence of the binding is what is being checked.
        return ('%d pickups present'):format(#GetGamePool('CPickup'))
    end)
    -- Clearing the player's own map waypoint from a keybind, because GTA's
    -- only built-in way is to re-click the flag in the pause map.
    probe('IsWaypointActive',        function() return IsWaypointActive() end)
    probe('SetWaypointOff',          function()
        -- Not called blind: turning off a waypoint the player set on purpose
        -- would be the probe changing the game.
        return IsWaypointActive() and 'waypoint set (not cleared by probe)'
            or 'no waypoint'
    end)
    -- Anchoring the crate label to the crate: every corner of the quad is an
    -- offset in the PROP's local space, which is what buys yaw, pitch and roll
    -- without any orientation maths of our own.
    probe('GetOffsetFromEntityInWorldCoords', function()
        local v = GetOffsetFromEntityInWorldCoords(ped, 0.0, 0.0, 1.0)
        return ('%.2f,%.2f,%.2f'):format(v.x, v.y, v.z)
    end)
    probe('GetModelDimensions',      function()
        local mn, mx = GetModelDimensions(GetHashKey(BR.Config.Loot.chestProp))
        return ('%.2f..%.2f z'):format(mn.z, mx.z)
    end)
    probe('GetEntityRotation',       function()
        local r = GetEntityRotation(ped, 2)
        return ('%.1f,%.1f,%.1f'):format(r.x, r.y, r.z)
    end)
    probe('SetEntityRotation',       function()
        local r = GetEntityRotation(ped, 2)
        SetEntityRotation(ped, r.x, r.y, r.z, 2, true)
    end)
    probe('GetGameplayCamCoord',     function()
        local c = GetGameplayCamCoord()
        return ('%.1f,%.1f,%.1f'):format(c.x, c.y, c.z)
    end)
    -- The world-space crate label: a textured quad lying flat on the lid.
    probe('DrawSpritePoly',          function()
        -- Degenerate (all three vertices identical) so the probe draws
        -- nothing visible while still proving the signature binds.
        local c = GetEntityCoords(ped)
        DrawSpritePoly(c.x, c.y, c.z, c.x, c.y, c.z, c.x, c.y, c.z,
            255, 255, 255, 0, 'deadline', 'deadline',
            0.0, 0.0, 1.0, 0.0, 0.0, 1.0, 0.0, 0.0, 1.0)
    end)
    -- Crate mass. Measured: PlaceObjectOnGroundProperly is what welds a crate
    -- down, and the default mass is what made the survivor feel like concrete.
    probe('SetObjectPhysicsParams',  function()
        local m = GetHashKey(BR.Config.Loot.chestProp)
        RequestModel(m)
        local obj = CreateObjectNoOffset(m, 0.0, 0.0, -200.0, false, false, true)
        if obj and obj ~= 0 then
            SetObjectPhysicsParams(obj, 12.0, 0.1, -1.0, -1.0, -1.0, -1.0,
                0.1, 0.1, 0.1, -1.0, -1.0)
            DeleteEntity(obj)
        end
        SetModelAsNoLongerNeeded(m)
    end)
    probe('DrawSprite',              function()
        DrawSprite('commonmenu', 'common_medal', -1.0, -1.0, 0.01, 0.01,
            0.0, 255, 255, 255, 0)
    end)
    probe('GetWaterHeight',          function()
        local _, h = GetWaterHeight(0.0, 0.0, 0.0)
        return h
    end)

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
