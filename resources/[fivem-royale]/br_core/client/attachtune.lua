-- /brattach -- stand next to an ambulance and MEASURE the stretcher offset.
--
-- ═══ THE REQUEST ═══
--
-- Owner, 2026-08-23:
--
--   "recall how we talked about getting the proper coords for the ped to sit
--    inside the ambulance? I don't have any tools for that. If you can help me
--    with a client command to AttachEntityToEntity while next to an ambulance,
--    put my ped in the laying position (sunbathe emote if needed), prevent the
--    ped from performing any tasks, then WASD to move around and Q/Z to move up
--    and down, and E/R to rotate, and then a command to get the coords relative
--    to the entity (or whatever would be helpful to you) then I can give you
--    those coords"
--
-- ═══ WHY IT EXISTS ═══
--
-- #191's CPR kit puts a downed player on the ambulance's stretcher with
-- AttachEntityToEntity, and br_lib/config/rescue.lua's `stretcher` table says in
-- as many words that its six numbers are A PLACEHOLDER NOBODY HAS MEASURED.
-- They cannot be derived: an offset into a car's bodywork is a fact about the
-- model, not about anything a solver can compute, and the only way to get it is
-- to put a body there and look at it.
--
-- The owner is the one who can look at it, and he is not a programmer. So the
-- tool has to be usable without reading a line of this file: one command to
-- start, keys that do the obvious thing, the numbers on screen the whole time,
-- and one command that prints something he can paste back.
--
-- ═══ WHAT IT IS NOT ═══
--
-- It is not a feature and nothing in the gamemode calls it. It is /brprobe's
-- argument applied to geometry: MEASURE, then write the code -- not the other
-- way round. It is also deliberately GENERAL. The ambulance is the default
-- because that is the job in hand, but `/brattach <model>` will tune an offset
-- against any vehicle, because the next AttachEntityToEntity somebody has to
-- author will have exactly this problem.
--
-- ═══ THE GATE, AND WHY IT IS NOT A CONVAR ═══
--
-- Every other client dev command here -- /brcoords, /brprobe, /brchute,
-- /brdriveby -- is a plain RegisterCommand with no convar in front of it, and
-- this follows them. A convar gate is not available on this side anyway:
-- sv_devMode and br_devMode are read in br_core/server/main.lua and are NOT
-- replicated, so a client GetConvar sees neither, and BR.Server does not exist
-- in the client Lua state at all (client/spawn.lua and client/state.lua each
-- carry a `BR.Server and BR.Server.devMode` read; both are always false here).
-- Copying that spelling would have produced a command that silently never ran.
--
-- What DOES gate it is the thing the convar was standing in for: this refuses
-- to run in every player state where another subsystem already owns this ped or
-- this camera -- the lobby mannequin, the bus attach, the descent, the downed
-- crawl, the spectator shot -- and it hands the ped back the moment the state
-- leaves the two it allows. See `allowedState` below.

-- NOTHING IS EXPORTED. No BR.AttachTune table, because nothing in the gamemode
-- calls a measuring tool and a namespace with no callers is scaffolding that
-- later reads as an interface somebody is allowed to use.
BR = BR or {}

--- A FiveM native declared BOOL may answer 1 or 0, and in Lua the number 0 is
--- TRUTHY -- so a bare `if DoesEntityExist(v)` is true for a native that said
--- no. Every BOOL read in this file goes through here; see
--- tools/bool_native_rules.lua for the six shipped instances that bought it.
--- @param v any
--- @return boolean
local function isTrue(v) return v == true or v == 1 end

-- --------------------------------------------------------------- the pose ---

-- ═══ AN ANIMATION DICTIONARY, NOT A SCENARIO ═══
--
-- The owner suggested "sunbathe emote if needed", and the sunbathe clip is the
-- right pose: the ped lies flat on its back with its arms at its sides, which
-- is what a body on a stretcher looks like. There are two ways to reach it and
-- only one of them survives being attached to a vehicle:
--
--   TaskStartScenarioInPlace('WORLD_HUMAN_SUNBATHE')  IS A TASK, and a task is
--   the exact thing this command exists to suppress. Scenarios also site
--   themselves against the ground and the ped's own matrix -- they move the ped
--   -- which is a direct fight with AttachEntityToEntity for ownership of where
--   the body is. Measuring an offset while something else is quietly adjusting
--   it is how you get numbers that do not reproduce.
--
--   TaskPlayAnim on the dictionary directly is what client/dbno.lua already
--   uses for the downed pose, on this build, with the loader below copied from
--   it. It poses the ped and asks for nothing else.
--
-- CANDIDATES RATHER THAN A CONSTANT, and the reason is the same one probe.lua
-- was written for: a dictionary name is a guess until the game says otherwise.
-- Each is checked with DoesAnimDictExist before it is requested, the first that
-- loads is used, and WHICH ONE IT WAS is printed with the offsets -- because
-- the numbers only mean anything alongside the pose they were measured with.
--
-- #215's emotes are scoped and NOT BUILT, so nothing here reaches for them.
local POSES = {
    -- Flat on the back, arms down. The owner's suggestion, and the pose the
    -- stretcher wants.
    { dict = 'amb@world_human_sunbathe@male@back@base',   anim = 'base' },
    { dict = 'amb@world_human_sunbathe@female@back@base', anim = 'base' },
    -- A body on a table, face up. Different dictionary family, so it is worth
    -- having if the ambient one is missing on a future build.
    { dict = 'anim@gangops@morgue@table@',                anim = 'body_search' },
}

--- The pose the caller asked for with /brattachpose, if any. Tried first.
local override = nil

--- Request a dictionary and wait a beat for it. Returns whether it landed.
---
--- DoesAnimDictExist FIRST, because requesting a name the game has never heard
--- of is a streaming request that can never complete -- without it the wait
--- below is paid in full for every bad guess in POSES. Lifted from
--- client/dbno.lua's loadDict, which learned this the same way.
--- @param dict string
--- @return boolean
local function loadDict(dict)
    if isTrue(HasAnimDictLoaded(dict)) then return true end
    if DoesAnimDictExist and not isTrue(DoesAnimDictExist(dict)) then return false end

    RequestAnimDict(dict)
    local deadline = GetGameTimer() + 400
    while not isTrue(HasAnimDictLoaded(dict)) and GetGameTimer() < deadline do
        Citizen.Wait(0)
    end
    return isTrue(HasAnimDictLoaded(dict))
end

--- The first pose this build can actually play, or nil.
--- @return table|nil
local function resolvePose()
    if override and loadDict(override.dict) then return override end
    for i = 1, #POSES do
        if loadDict(POSES[i].dict) then return POSES[i] end
    end
    return nil
end

-- ----------------------------------------------------------------- controls ---

-- ═══ EVERY ID BELOW WAS LOOKED UP, NOT REMEMBERED ═══
--
-- docs.fivem.net/docs/game-references/controls, 2026-08-23, cross-checked
-- against meta-hub/fivem-controls. client/spectate.lua's BLOCKED table carries
-- the same warning and the same reason: client/inventory.lua's panel block
-- labels 68 "VEH_ATTACK" and 69 "VEH_PASSENGER_ATTACK" in its comments and both
-- are wrong, so copying a neighbour's comment is how a wrong id gets a second
-- home.
--
-- ═══ THE KEYS THIS TOOL CLAIMS ARE ALL SHARED WITH SOMETHING ═══
--
-- Every one of them. This is not a list of nice-to-haves:
--
--   W A S D   movement, and the axis controls 30/31 and 266-269 alongside the
--             _ONLY controls 32-35. A ped that walks while you are measuring
--             where it is standing produces numbers that mean nothing.
--   Q         COVER (44), CONTEXT_SECONDARY (52), VEH_RADIO_WHEEL (85),
--             MELEE_ATTACK_HEAVY (141) and MELEE_ATTACK2 (264). Five.
--   E         PICKUP (38), TALK (46), CONTEXT (51), WEAPON_SPECIAL_TWO (54),
--             VEH_HORN (86), CELLPHONE_CAMERA_SELFIE (184).
--   R         RELOAD (45), VEH_CIN_CAM (80), MELEE_ATTACK_LIGHT (140),
--             MELEE_ATTACK1 (263).
--   Z         MULTIPLAYER_INFO (20), HUD_SPECIAL (48).
--   SHIFT     SPRINT (21), CREATOR_MENU_TOGGLE (254).
--   CTRL      DUCK (36), REPLAY_CTRL (326).
--   ALT       CHARACTER_WHEEL (19).
--
-- ═══ WHAT IS DELIBERATELY NOT BLOCKED ═══
--
--   1 and 2 (LOOK_LR / LOOK_UD). Looking at the body from three angles IS the
--   measurement. Taking the mouse away would make this tool useless in exactly
--   the way that reads as a broken camera rather than a control list --
--   spectate.lua's note about GetControlNormal answering 0.0 for a disabled
--   control is the same trap.
--
--   0 (NEXT_CAMERA, V). Switching view is another angle on the same body.
--
--   199 and 200 (FRONTEND_PAUSE). The pause menu must always open. It is the
--   last exit that does not depend on this file behaving.
local BLOCKED = {
    -- Movement, every spelling of it.
    30, 31, 32, 33, 34, 35,
    266, 267, 268, 269,
    -- The keys this tool reads, and everything else those keys do.
    19,                        -- CHARACTER_WHEEL      (LEFT ALT)
    20, 48,                    -- MULTIPLAYER_INFO, HUD_SPECIAL          (Z)
    21, 254,                   -- SPRINT, CREATOR_MENU_TOGGLE   (LEFT SHIFT)
    36, 326,                   -- DUCK, REPLAY_CTRL              (LEFT CTRL)
    38, 46, 51, 54, 86, 184,   -- PICKUP, TALK, CONTEXT, ...              (E)
    44, 52, 85,                -- COVER, CONTEXT_SECONDARY, RADIO_WHEEL   (Q)
    45, 80, 310,               -- RELOAD, VEH_CIN_CAM, REPLAY_RESTART     (R)
    -- Everything else a ped acts through. An attached ped that punches,
    -- vaults, aims or reaches for a door has left the offset being measured.
    22, 23, 24, 25,            -- JUMP, ENTER, ATTACK, AIM
    37,                        -- SELECT_WEAPON (the wheel)
    47, 58,                    -- DETONATE, THROW_GRENADE
    75,                        -- VEH_EXIT
    140, 141, 142, 143,        -- MELEE_ATTACK_LIGHT/HEAVY/ALTERNATE/BLOCK
    257, 263, 264,             -- ATTACK2, MELEE_ATTACK1, MELEE_ATTACK2
}

local KEY = {
    FWD    = 32,   -- W            INPUT_MOVE_UP_ONLY
    BACK   = 33,   -- S            INPUT_MOVE_DOWN_ONLY
    LEFT   = 34,   -- A            INPUT_MOVE_LEFT_ONLY
    RIGHT  = 35,   -- D            INPUT_MOVE_RIGHT_ONLY
    UP     = 44,   -- Q            INPUT_COVER
    DOWN   = 20,   -- Z            INPUT_MULTIPLAYER_INFO
    ROTPOS = 38,   -- E            INPUT_PICKUP
    ROTNEG = 45,   -- R            INPUT_RELOAD
    COARSE = 21,   -- LEFT SHIFT   INPUT_SPRINT
    PITCH  = 19,   -- LEFT ALT     INPUT_CHARACTER_WHEEL
    ROLL   = 36,   -- LEFT CTRL    INPUT_DUCK
}

-- ═══ TWO STEP SIZES, AND THESE TWO ═══
--
-- 1cm steps take forever across two metres of cabin; 10cm steps cannot land a
-- shoulder inside a doorframe. So both, on a modifier rather than a mode: SHIFT
-- is held for the coarse one, which means the size in force is a property of
-- what your hand is doing right now and cannot be left wrong.
--
-- 15 degrees coarse rather than 10 or 45 because the rotations that matter here
-- are quarter and half turns -- six taps is 90, twelve is 180.
local STEP = {
    fine   = { m = 0.01, deg = 1.0 },
    coarse = { m = 0.10, deg = 15.0 },
}

-- ═══ ONE STEP PER 50ms WHILE HELD, NOT ONE PER FRAME ═══
--
-- A per-frame step means the distance a key travels depends on the frame rate,
-- so the same hold moves further on a better machine and a measurement taken
-- one day does not reproduce the next. A per-press step means two hundred
-- presses to cross two metres at the fine size.
--
-- A timer is neither: a tap is exactly one step (the deadline is cleared the
-- moment nothing is held, so the next press applies immediately), and a hold is
-- 20 steps a second whatever the machine is doing -- 2.0 m/s coarse, 20cm/s
-- fine. GetGameTimer is frame-latched (see client/main.lua's timing note), which
-- is harmless at 50ms and is why the deadline is not measured any finer.
local REPEAT_MS = 50

--- How far from the ped to look for the vehicle.
local SEARCH_RANGE = 30.0

--- How far the offset may be pushed, in metres, on each axis. A tool that can
--- lose the ped inside the map while the owner is holding a key is a tool that
--- ends in a /brattachoff nobody can aim.
local LIMIT = 5.0

-- ------------------------------------------------------------------ session ---

--- nil when idle. While tuning: the vehicle, the six numbers, and the pose.
local S = nil

--- Player states this may run in.
---
--- NOT AN ALLOWLIST OF CONVENIENCE. Every state left out is one where another
--- subsystem already owns this ped or this camera, and where attaching would be
--- two files writing the same matrix:
---
---   LOBBY       client/spawn.lua freezes the ped and client/lobbycam.lua owns
---               the shot. The lobby ped is a mannequin in a photograph.
---   BUS         client/bus.lua has the ped ATTACHED TO A PLANE already.
---   FREEFALL    } client/skydive.lua owns the whole descent, and the ped is
---   GLIDE       } holding a canopy.
---   DBNO        client/dbno.lua is playing the crawl and holding the position.
---   OUT         client/spectate.lua's camera is somebody else's fight.
---   LEFT        not in the match at all.
---
--- WARMUP and ALIVE are the two where the ped is an ordinary ped standing on
--- the ground, which is the only state this tool has any business in.
---
--- The literals are a FALLBACK, not a second spelling: shared/enums.lua is the
--- first line of this resource's shared_scripts so BR.PlayerState is always
--- there in the game, and the strings only keep this file loadable in a bare
--- Lua state -- which is what tools/verify.sh's syntax pass runs it in.
local PS = BR.PlayerState or {}
local ALLOWED = {
    [PS.WARMUP or 'warmup'] = true,
    [PS.ALIVE  or 'alive']  = true,
}

--- The local player's state, or nil if the mirror has not been built yet.
--- @return string|nil
local function myState()
    return BR.State and BR.State.me and BR.State.me.state or nil
end

--- May the tool run right now? Returns false and the state that says no.
--- @return boolean ok, string|nil state
local function allowedState()
    local st = myState()
    -- No mirror at all means no match, which means nothing owns the ped.
    if st == nil then return true, nil end
    return ALLOWED[st] == true, st
end

-- ------------------------------------------------------------------ finding ---

--- The vehicle models this command hunts for, and the names to say out loud.
---
--- READ FROM BR.Config.Rescue AT CALL TIME, never captured at load: that config
--- is #191's and it is landing in parallel with this file. A nil-guarded read
--- here means the tool works with or without it and agrees with it when it is
--- there -- which matters, because "the models #191 calls an ambulance" and
--- "the models this tool will attach to" being two different lists is how the
--- offset gets measured against a vehicle the feature will never use.
--- @param want string|nil  a model name from the command line, or nil
--- @return table set of normalised model hashes (empty means "any vehicle")
--- @return string what it looked for, for the console
local function wantedModels(want)
    if want == 'any' then return {}, 'any vehicle' end

    local names
    if want then
        names = { want }
    else
        names = (BR.Config and BR.Config.Rescue and BR.Config.Rescue.models)
                or { 'ambulance' }
    end

    local set = {}
    for i = 1, #names do
        local h = BR.NormHash(GetHashKey(names[i]))
        if h then set[h] = true end
    end
    return set, table.concat(names, ', ')
end

--- The nearest vehicle matching `set`, within SEARCH_RANGE of the ped.
---
--- GetGamePool('CVehicle') like client/gamerules.lua's ambient pass -- it is a
--- LOCAL pool of entities this machine has streamed, which is the right kind of
--- question to ask on a client and is nothing like the scope-poisoned player
--- lookups the verify gate bans.
--- @param set table  normalised model hashes; empty means any
--- @return number|nil veh, number|nil distance
local function nearest(set)
    local me = GetEntityCoords(PlayerPedId())
    local any = next(set) == nil

    local best, bestD
    local pool = GetGamePool('CVehicle')
    for i = 1, #pool do
        local v = pool[i]
        if isTrue(DoesEntityExist(v))
           and (any or set[BR.NormHash(GetEntityModel(v))]) then
            local d = #(GetEntityCoords(v) - me)
            if d <= SEARCH_RANGE and (not bestD or d < bestD) then
                best, bestD = v, d
            end
        end
    end
    return best, bestD
end

-- ------------------------------------------------------------------- output ---

--- One line of the on-screen readout. Same call shape as client/debug.lua's
--- overlay text; this file cannot reach that one, it is a local there.
local function text(x, y, s, scale)
    SetTextFont(4)
    SetTextScale(0.0, scale or 0.34)
    SetTextColour(255, 255, 255, 235)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextDropShadow()
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(x, y)
end

--- THE OFFSET, IN THE TWO FORMS IT IS WANTED IN.
---
--- ═══ THIS IS THE POINT OF THE COMMAND ═══
---
--- /brcoords prints a position AND a `BR.Config.Map.POIs` row in that table's
--- exact field order, because reading three floats off a screen and retyping
--- them is where a tuning session goes wrong. Same principle, same reason:
---
---   the AttachEntityToEntity call   argument for argument, INCLUDING the tail
---                                   `false, false, false, false, 2, true`,
---                                   which is client/bus.lua:244's and #191's.
---                                   The numbers only transfer if the call they
---                                   transfer into is the same call.
---   the `stretcher = { ... }` block  x/y/z then pitch/roll/yaw, the exact field
---                                   order of BR.Config.Rescue.stretcher, so the
---                                   swap is one paste. Printed ONLY when that
---                                   table actually exists, so it can never
---                                   advertise a home the config does not have.
---
--- AND THE POSE IS PRINTED WITH THEM, every time. An offset measured with the
--- body lying flat is not the offset for a body standing up; six numbers with
--- no note of which pose produced them is a number nobody can check.
local function dump()
    if not S then
        print('[br_core] brattach: not attached to anything (run /brattach first)')
        return
    end

    print(('[br_core] brattach: %s (handle %d)'):format(S.modelName, S.veh))
    print(('  pose  %s / %s'):format(S.pose.dict, S.pose.anim))
    print('  AttachEntityToEntity(ped, veh,')
    print('      0,')
    print(('      %.3f, %.3f, %.3f,'):format(S.x, S.y, S.z))
    print(('      %.1f, %.1f, %.1f,'):format(S.pitch, S.roll, S.yaw))
    print('      false, false, false, false, 2, true)')

    if BR.Config and BR.Config.Rescue and BR.Config.Rescue.stretcher then
        print('')
        print('  stretcher = {')
        print(('      x = %.3f, y = %.3f, z = %.3f,'):format(S.x, S.y, S.z))
        print(('      pitch = %.1f, roll = %.1f, yaw = %.1f,')
            :format(S.pitch, S.roll, S.yaw))
        print('  },')
    end
end

-- -------------------------------------------------------------------- attach ---

--- Write the current six numbers onto the ped.
---
--- THE ARGUMENT TAIL IS client/bus.lua:244's, COPIED RATHER THAN CHOSEN. That
--- call attaches own-local-ped to own-local-vehicle and its comment records why:
--- the seat API brings network attach problems this avoids entirely. #191's
--- attach in client/rescue.lua is the same call with the same tail. If this tool
--- used a different one -- a different vertexIndex, fixedRot the other way --
--- the numbers it produced would be right for a call nobody makes.
local function applyAttach()
    AttachEntityToEntity(PlayerPedId(), S.veh,
        0,
        S.x, S.y, S.z,
        S.pitch, S.roll, S.yaw,
        false, false, false, false, 2, true)
end

--- Pose the ped and take everything else away from it.
---
--- ═══ AN ATTACHED PED THAT IS STILL ALLOWED TO REACT WILL DRIFT ═══
---
--- and it drifts INVISIBLY -- the body is still roughly where you put it, the
--- numbers on screen are still the numbers you typed, and they no longer
--- describe each other. A ragdoll from the ambulance moving, a flinch at a
--- gunshot, an ambient idle: any of them moves the ped off the offset.
---
---   ClearPedTasksImmediately    whatever it was doing, it stops now.
---   SetBlockingOfNonTemporaryEvents  the reactions. Re-asserted on every tick
---                                    below, because the engine hands a ped new
---                                    tasks constantly (client/gamerules.lua's
---                                    ambient pass learned this the hard way --
---                                    "marked done once and never looked at
---                                    again" is why some drivers stayed calm).
---   SetPedCanRagdoll(false)     the one that actually moves the body. The same
---                               false/true pair client/dbno.lua holds a downed
---                               ped with, and nothing else in this client
---                               writes it on a cadence.
---
--- ═══ AND NOT INVINCIBILITY, WHICH ALREADY HAS AN OWNER ═══
---
--- The obvious extra -- make the ped invincible so a burning ambulance cannot
--- end the session -- was written and then taken out. client/natives.lua's
--- applyWorldSetup latch derives SetPlayerInvincible from the player and match
--- state and rewrites it every LATCH_REFRESH_MS, so in ALIVE it would revoke
--- this within a second, and on the way out a `false` from here would fight it
--- in WARMUP where it wants true. A second writer that loses is worse than no
--- writer: it looks like protection and is not there.
---
--- What actually protects the measurement is the upkeep pass below. If the
--- vehicle burns, or the player dies, the offsets are PRINTED and then the ped
--- is handed back -- so the numbers survive the thing that ended the session,
--- which is the half that mattered.
---
--- NOT FROZEN. FreezeEntityPosition on an attached ped is two systems writing
--- the same matrix -- client/bus.lua retired exactly that freeze for exactly
--- that reason. The attach IS the hold.
local function poseAndHold()
    local ped = PlayerPedId()
    ClearPedTasksImmediately(ped)
    SetBlockingOfNonTemporaryEvents(ped, true)
    SetPedCanRagdoll(ped, false)
    applyAttach()
    TaskPlayAnim(ped, S.pose.dict, S.pose.anim, 8.0, -8.0, -1, 1, 0.0,
                 false, false, false)
end

--- Detach, hand the ped back, and say where it went.
---
--- ═══ THIS PATH CANNOT BE ALLOWED TO FAIL ═══
---
--- The owner is measuring against a vehicle that #191 lets other players
--- destroy, and the failure this must never have is "welded to a wreck, no
--- controls, in a live match". So it is reached from FIVE places and none of
--- them depends on him remembering a command: /brattachoff, the vehicle ceasing
--- to exist, the vehicle dying, the player state leaving WARMUP/ALIVE, and the
--- resource stopping.
---
--- THE CONTROLS NEED NO RESTORING AND THAT IS THE STRONGEST PART. DisableControlAction
--- lasts exactly one frame, so the callback below simply stops running and the
--- keyboard is live on the next frame -- the same argument client/spectate.lua
--- makes for the same reason. There is no restore call here that could be
--- skipped, because there is nothing to restore.
---
--- WHERE THE BODY LANDS. Detaching leaves the ped exactly where the offset put
--- it, which is usually INSIDE the bodywork. So it is placed 2.5m out to the
--- vehicle's right; if the vehicle is the thing that went away, its last known
--- position a metre up is used instead.
--- @param why string  printed, so an exit nobody asked for still explains itself
local function stop(why)
    if not S then return end
    local sess, ped = S, PlayerPedId()
    S = nil

    DetachEntity(ped, true, false)
    ClearPedTasksImmediately(ped)
    SetBlockingOfNonTemporaryEvents(ped, false)
    SetPedCanRagdoll(ped, true)
    -- FreezeEntityPosition is not something this file ever set. It is unset here
    -- anyway, because "cannot be left stuck to a vehicle" and "cannot be left
    -- unable to move" are the same promise, and a restore that only undoes what
    -- this file did is a restore that trusts every other file to be perfect.
    FreezeEntityPosition(ped, false)

    local x, y, z
    if isTrue(DoesEntityExist(sess.veh)) then
        local o = GetOffsetFromEntityInWorldCoords(sess.veh, 2.5, 0.0, 0.5)
        x, y, z = o.x, o.y, o.z
    else
        x, y, z = sess.lastX, sess.lastY, sess.lastZ + 1.0
    end
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)

    print(('[br_core] brattach: detached -- %s'):format(why))
end

--- Attach to the nearest matching vehicle and start tuning.
--- @param want string|nil  a model name, 'any', or nil for #191's ambulance list
local function start(want)
    if S then
        print('[br_core] brattach: already attached -- /brattachoff first')
        return
    end

    local ok, st = allowedState()
    if not ok then
        print(('[br_core] brattach: not while your state is %s.'):format(tostring(st)))
        print('  Another subsystem owns the ped or the camera in that state.')
        print('  Allowed: warmup, alive.')
        return
    end

    local set, looked = wantedModels(want)
    local veh, dist = nearest(set)
    if not veh then
        print(('[br_core] brattach: nothing within %.0fm -- looked for %s')
            :format(SEARCH_RANGE, looked))
        print('  Spawn one with /brcar ambulance (server, dev mode) and stand next to it.')
        return
    end

    local pose = resolvePose()
    if not pose then
        print('[br_core] brattach: no laying animation this build will load.')
        for i = 1, #POSES do
            print(('  tried %s / %s'):format(POSES[i].dict, POSES[i].anim))
        end
        print('  Try another with /brattachpose <dict> <anim>.')
        return
    end

    local vc = GetEntityCoords(veh)
    S = {
        veh       = veh,
        modelName = looked,
        pose      = pose,
        -- ZEROED, NOT SEEDED FROM #191's PLACEHOLDER. Starting at the vehicle
        -- origin is obviously a starting point; starting at six numbers that
        -- look authored invites them to be believed and handed straight back.
        -- Coarse steps cross the cabin in about two seconds.
        x = 0.0, y = 0.0, z = 0.0,
        pitch = 0.0, roll = 0.0, yaw = 0.0,
        nextAt = 0,
        lastX = vc.x, lastY = vc.y, lastZ = vc.z,
    }
    poseAndHold()

    print(('[br_core] brattach: attached to %s (handle %d, %.1fm away)')
        :format(looked, veh, dist or 0.0))
    print(('  pose        %s / %s'):format(pose.dict, pose.anim))
    print('  W / S       toward the nose / toward the back doors  (vehicle Y)')
    print('  A / D       left / right                             (vehicle X)')
    print('  Q / Z       up / down                                (vehicle Z)')
    print('  E / R       yaw, one way and the other')
    print('  ALT + E/R   pitch      CTRL + E/R   roll')
    print(('  SHIFT       hold for coarse steps (%.2fm, %.0f deg); otherwise %.2fm, %.0f deg')
        :format(STEP.coarse.m, STEP.coarse.deg, STEP.fine.m, STEP.fine.deg))
    print('  /brattachdump   print the offset (it is also printed when you stop)')
    print('  /brattachoff    detach and put everything back')
end

-- ------------------------------------------------------------------- nudging ---

--- Keep an angle in (-180, 180]. Six numbers that read 359.0 and -1.0 on
--- alternate sessions are the same rotation and do not look like it.
--- @param a number
--- @return number
local function wrap180(a)
    a = a % 360.0
    if a > 180.0 then a = a - 360.0 end
    return a
end

--- @param v number
--- @return number
local function clamp(v)
    if v >  LIMIT then return  LIMIT end
    if v < -LIMIT then return -LIMIT end
    return v
end

--- Is a blocked control held? IsDisabledControlPressed, not IsControlPressed:
--- these ids are held down every frame by the callback below, and the disabled
--- reader is the one that still sees them -- the same disabled-then-read pattern
--- client/inventory.lua's panel block uses on 199/200/25 and client/dbno.lua
--- uses to drive the crawl off 30-35.
--- @param id number
--- @return boolean
local function held(id)
    return isTrue(IsDisabledControlPressed(0, id))
end

-- ═══ CONTROLS AND THE READOUT, PER FRAME ═══
--
-- FRAME rather than TICK for the same reason client/inventory.lua's suppression
-- is: DisableControlAction lasts exactly one frame, and a control that is only
-- held down at 10Hz is a control that is live five frames in six.
BR.Loop.register(BR.Loop.FRAME, 'attach.tune', function()
    if not S then return end

    for i = 1, #BLOCKED do
        DisableControlAction(0, BLOCKED[i], true)
    end

    -- ═══ THE AXES ARE THE VEHICLE'S, AND THEY ARE FOR FREE ═══
    --
    -- AttachEntityToEntity's offset is already expressed in the PARENT's local
    -- space, so adding to S.y moves the body down the ambulance's own length
    -- whichever way the ambulance happens to be pointing. There is no world-to-
    -- local conversion here because there is no world involved: +Y is the nose,
    -- +X is the right flank, +Z is the roof, and that is true of the vehicle
    -- parked, turning, or on its side. A tool that converted through world
    -- coordinates would produce numbers that only held for one heading.
    local step  = held(KEY.COARSE) and STEP.coarse or STEP.fine
    local dx, dy, dz = 0.0, 0.0, 0.0
    local rot = 0.0

    if held(KEY.FWD)   then dy = dy + step.m end
    if held(KEY.BACK)  then dy = dy - step.m end
    if held(KEY.RIGHT) then dx = dx + step.m end
    if held(KEY.LEFT)  then dx = dx - step.m end
    if held(KEY.UP)    then dz = dz + step.m end
    if held(KEY.DOWN)  then dz = dz - step.m end
    if held(KEY.ROTPOS) then rot = rot + step.deg end
    if held(KEY.ROTNEG) then rot = rot - step.deg end

    if dx == 0.0 and dy == 0.0 and dz == 0.0 and rot == 0.0 then
        -- Nothing held: clear the deadline so the next press lands on the frame
        -- it is made. This is what makes a tap exactly one step.
        S.nextAt = 0
        return
    end

    local now = GetGameTimer()
    if now < S.nextAt then return end
    S.nextAt = now + REPEAT_MS

    S.x = clamp(S.x + dx)
    S.y = clamp(S.y + dy)
    S.z = clamp(S.z + dz)

    if rot ~= 0.0 then
        -- WHICH ANGLE E AND R DRIVE IS THE MODIFIER'S ANSWER, not a mode
        -- somebody has to remember setting. Yaw is the one the stretcher needs
        -- -- which way the head points down the cabin -- so yaw is the one with
        -- no modifier at all.
        if held(KEY.PITCH) then
            S.pitch = wrap180(S.pitch + rot)
        elseif held(KEY.ROLL) then
            S.roll = wrap180(S.roll + rot)
        else
            S.yaw = wrap180(S.yaw + rot)
        end
    end

    applyAttach()
end)

-- ═══ THE READOUT IS CONTINUOUS, AND THAT IS NOT A NICETY ═══
--
-- Nudging blind and running a print command to find out what happened is a
-- round trip per step. With the numbers on screen the loop is closed: move,
-- look, move. It is the difference between converging in a minute and guessing
-- for ten.
--
-- IT IS NUMBERS AND NOTHING ELSE. No hints, no captions, no empty-state prose --
-- the owner's standing rule against unsolicited UI text is about player-facing
-- copy, and this is a dev command's instrument panel, but there is no reason for
-- it to carry a word it does not need. The key map is printed to the console
-- once, at the top, where it can be read without covering the thing being
-- measured.
BR.Loop.register(BR.Loop.FRAME, 'attach.readout', function()
    if not S then return end
    local y = 0.34
    text(0.015, y, ('~b~%s~w~  %d'):format(S.modelName, S.veh))          y = y + 0.026
    text(0.015, y, ('x %7.3f   y %7.3f   z %7.3f'):format(S.x, S.y, S.z))  y = y + 0.026
    text(0.015, y, ('pitch %6.1f   roll %6.1f   yaw %6.1f')
        :format(S.pitch, S.roll, S.yaw))                                 y = y + 0.026
    local step = held(KEY.COARSE) and STEP.coarse or STEP.fine
    text(0.015, y, ('step %.2f m   %.0f deg'):format(step.m, step.deg))
end)

-- ═══ THE TWO THINGS THAT GO WRONG WHILE ATTACHED ═══
--
-- THE VEHICLE MOVES. Nothing to do -- the offset is relative, so a driven
-- ambulance carries the body with it and the six numbers never change. It is
-- worth measuring on the move: a stretcher offset that looks right parked and
-- clips through the roof over a kerb is a number that has to be found now
-- rather than in a playtest.
--
-- THE VEHICLE IS DESTROYED. #191 made the ambulance destructible on purpose, so
-- this is a case the owner may well create deliberately -- and a burnt-out shell
-- STILL EXISTS as an entity for a good while afterwards, so DoesEntityExist
-- alone would happily keep him welded to a wreck. IsEntityDead is the question
-- that catches it.
--
-- EXISTENCE IS ASKED FIRST, and the order is not cosmetic: a native handed a
-- handle that no longer resolves has no defined answer, so asking whether a
-- deleted entity is dead is asking a question with no meaning and believing the
-- reply. Exists, then dead, then the state -- widest to narrowest.
--
-- EITHER WAY THE OFFSETS ARE PRINTED BEFORE THE SESSION ENDS. An exit nobody
-- asked for must not also throw away the work that led up to it.
--
-- AND THE STATE LEAVING WARMUP/ALIVE, which is the same argument as the gate on
-- the way in, applied continuously: the moment another subsystem is entitled to
-- this ped, this one is not.
BR.Loop.register(BR.Loop.TICK, 'attach.upkeep', function()
    if not S then return end

    if not isTrue(DoesEntityExist(S.veh)) then
        dump()
        stop('the vehicle no longer exists')
        return
    end
    if isTrue(IsEntityDead(S.veh)) then
        dump()
        stop('the vehicle was destroyed')
        return
    end

    local ok, st = allowedState()
    if not ok then
        dump()
        stop(('your state became %s'):format(tostring(st)))
        return
    end

    local vc = GetEntityCoords(S.veh)
    S.lastX, S.lastY, S.lastZ = vc.x, vc.y, vc.z

    local ped = PlayerPedId()

    -- RE-ASSERTED, NOT SET ONCE. The engine hands a ped new tasks constantly and
    -- a single call at the start is a call something else overwrites -- which is
    -- exactly the bug client/gamerules.lua's ambient pass shipped when it marked
    -- a driver done and never looked again.
    SetBlockingOfNonTemporaryEvents(ped, true)

    -- The attach itself can be taken away -- a ragdoll the block missed, another
    -- resource, a ped swap. Put it back rather than letting the readout describe
    -- an offset the body is no longer at.
    if not isTrue(IsEntityAttachedToEntity(ped, S.veh)) then
        applyAttach()
    end

    -- AND THE POSE, but only when it has actually stopped. client/dbno.lua's
    -- note is the whole reason for the test: re-tasking unconditionally is sixty
    -- TaskPlayAnims a second, forever, and a clip that never gets past its first
    -- frame.
    if not isTrue(IsEntityPlayingAnim(ped, S.pose.dict, S.pose.anim, 3)) then
        TaskPlayAnim(ped, S.pose.dict, S.pose.anim, 8.0, -8.0, -1, 1, 0.0,
                     false, false, false)
    end
end)

-- ------------------------------------------------------------------ commands ---

--- /brattach [model|any]
RegisterCommand('brattach', function(_, args)
    start(args and args[1] or nil)
end, false)

--- /brattachdump
RegisterCommand('brattachdump', function()
    dump()
end, false)

--- /brattachoff
RegisterCommand('brattachoff', function()
    if not S then
        print('[br_core] brattach: not attached to anything')
        return
    end
    dump()
    stop('asked to')
end, false)

--- /brattachpose <dict> <anim> -- try a pose the built-in list does not have.
---
--- HERE BECAUSE A DICTIONARY NAME IS A GUESS UNTIL THE GAME AGREES. POSES above
--- is three guesses; if all three turn out to be missing on some future build,
--- this is the difference between the owner trying a fourth in ten seconds and
--- waiting for a code change to reach him.
RegisterCommand('brattachpose', function(_, args)
    local dict, anim = args and args[1], args and args[2]
    if not dict or not anim then
        print('[br_core] brattachpose <dict> <anim>')
        if override then
            print(('  currently %s / %s'):format(override.dict, override.anim))
        end
        return
    end
    if not loadDict(dict) then
        print(('[br_core] brattachpose: %s will not load on this build'):format(dict))
        return
    end
    override = { dict = dict, anim = anim }
    print(('[br_core] brattachpose: %s / %s -- takes effect on the next /brattach')
        :format(dict, anim))
end, false)

-- A resource restart with the ped still attached would leave a player welded to
-- a vehicle with no command left to unweld them, because the file holding the
-- command is the file going away.
AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() then stop('the resource stopped') end
end)
