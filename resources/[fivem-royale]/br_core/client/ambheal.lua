-- Healing in the back of an ambulance, client side.
--
-- The prompt at the rear doors, the stretcher, the siren, the scripted camera,
-- the one key that gets you out, and the ground behind the van you are put back
-- on. The server decides whether any of it may happen (server/ambheal.lua) and
-- issues every point of health; this file is everything that can only be done on
-- the machine the player is sitting at.
--
-- ═══ THE PLAYER IS MORTAL FOR EVERY FRAME OF THIS, AND THAT IS THE HARD ONE ═══
--
--   "if someone shoots me to death while in the ambulance healing, I should
--    still take damage and die completely."     -- owner, 2026-08-28
--
-- THREE THINGS MAKE THAT TRUE AND ONLY ONE OF THEM IS IN THIS FILE:
--
--   1. THE STATE NEVER CHANGES. A healing player is ALIVE in a PLAYING match,
--      start to finish. client/natives.lua's `wantInvincible` is derived from
--      exactly that pair -- WARMUP, BUS, LOBBY, FREEFALL, GLIDE, DBNO, a decided
--      match, or the drop grace -- so it answers FALSE and the latch writes
--      SetPlayerInvincible(pid, false). Nothing here touches the state, and
--      nothing here may: the CPR kit's rider is invincible because they are
--      DBNO, and this feature must never borrow that.
--
--   2. NOTHING HERE MAKES THE PED TOUGHER. There is no SetEntityInvincible, no
--      SetEntityProofs and no SetPlayerInvincible anywhere in this file, and
--      tools/test_ambheal.lua greps for all three -- because the edit that
--      breaks this requirement is not a bug, it is somebody reasonably deciding
--      that a heal should not be interruptible.
--
--   3. THE DEATH REPORT DOES NOT CARE THAT THE PED IS ATTACHED.
--      client/gamerules.lua's `gamerules.death` reads IsEntityDead /
--      IsPedFatallyInjured on the local ped every tick, unconditionally, with no
--      test for a vehicle, an attach, a camera or a subsystem. So a player shot
--      on the stretcher reports their own death down the same path as a player
--      shot in a field, and the server eliminates them through the same one.
--
-- AND THE FOURTH THING, WHICH IS THIS FILE'S JOB: the moment the ped is dead,
-- the session ends -- the attach comes off, the camera comes down and the
-- control block stops being issued. That is what stops "still killable" from
-- meaning "killable, and then stuck in a dead man's scripted camera".
--
-- ═══ THE CONTROL BLOCK CANNOT OUTLIVE ANYTHING, BY CONSTRUCTION ═══
--
--   "the only way to leave the ambulance while healing should be pressing the
--    interact button."
--
-- DisableControlAction lasts EXACTLY ONE FRAME. client/attachtune.lua's note is
-- the whole argument -- "the controls need no restoring and that is the
-- strongest part" -- and it matters more here than it does there: a lock that
-- had to be released would be a lock that leaks when the player dies mid-heal,
-- which is precisely the failure the owner's requirement is about. There is
-- nothing to release. The block is re-issued every frame while a session is
-- live, and the frame after it is not, every key is free.

BR = BR or {}
BR.AmbHeal = {}

local A = BR.Config.AmbHeal
local R = BR.Config.Rescue

--- A FiveM native declared BOOL may hand Lua a `1` rather than `true`, and `0`
--- is TRUTHY in Lua -- so both obvious spellings of the test are wrong, in
--- opposite directions. Every BOOL read in this file goes through here.
local function isTrue(v) return v == true or v == 1 end

--- The heal in progress, or nil.
---
---   netId    the vehicle, as the server knows it
---   veh      the entity on this machine
---   cam      the scripted camera
---   camYaw   free look, exactly as the ambulance ride does it
---   camPitch
---   from     { x, y, z } where the player was standing when they pressed
---   ending   teardown is running; the pose loop must keep its hands off
local session = nil

--- What the prompt was last told, so it is sent on CHANGE rather than per frame.
local promptShown = false

--- The ambulance the TICK pass decided to offer, held for the FRAME pass to draw
--- against.
---
--- ONE SCAN PER TICK RATHER THAN ONE PER FRAME. `ambheal.draw` needs a position
--- sixty times a second because a DrawSprite lasts one frame, and re-running the
--- closest-vehicle search to get it would put a world query on every frame of
--- every player's game. client/fuel.lua's `at` table is the same idea for the
--- same reason: the decision is slow, the drawing is fast, and only the second
--- one belongs in the frame band.
---
--- CLEARED WHENEVER THE PLATE COMES DOWN, so a stale handle can never be drawn
--- against -- `setPrompt(false)` is the one place both happen.
local candidate = nil

--- Forward-declared: `board` poses the ped and is defined above the pose helper,
--- because boarding is the sequence a reader follows and the pose is a detail of
--- it. A `local function` called from above its own declaration resolves as a
--- GLOBAL, which is nil -- see tools/check_forward_locals.lua for the two
--- playtest rounds that bought this line.
local poseOnStretcher

-- ---------------------------------------------------------------------------
-- Finding the ambulance
-- ---------------------------------------------------------------------------

--- Model hashes that count, resolved once on first use.
---
--- LAZILY, for the reason server/rescue.lua resolves its copy lazily:
--- config/ambheal.lua is a shared file and GetHashKey is not available in every
--- state that loads it. The LIST is BR.Config.Rescue.models through
--- BR.Config.AmbHeal.models(), so the rescue and the heal cannot come to mean
--- different things by "ambulance".
local modelSet = nil
local function isAmbulance(model)
    if modelSet == nil then
        modelSet = {}
        for _, name in ipairs(BR.Config.AmbHeal.models()) do
            local h = BR.NormHash(GetHashKey(name))
            if h then modelSet[h] = true end
        end
    end
    return modelSet[BR.NormHash(model)] == true
end

--- The nearest ambulance, or nil.
---
--- ═══ GetClosestVehicle RATHER THAN A RAY OR A POOL WALK ═══
---
--- client/loot.lua ray-casts because a crate is a thing you LOOK at and two
--- crates a metre apart have to be told apart by aim. A van is not that: it is
--- four metres long, you walk up to the back of it, and the rear-arc test below
--- is what decides you are at the right end. A ray would add a "you were not
--- quite looking at it" failure to a gesture that has none.
---
--- ONE NATIVE PER PASS, ON THE TICK BAND. The pool walk (GetGamePool
--- 'CVehicle') is the other way to do this and it is a walk over every vehicle
--- streamed in, ten times a second, to answer a question about the one within
--- eight metres.
---
--- MODEL 0 AND OUR OWN FILTER, deliberately: passing an ambulance hash would
--- make the native answer only for the FIRST model in the list, and the list is
--- allowed to grow. Reading the model back costs one call on a vehicle that is
--- already in hand.
--- @param x number
--- @param y number
--- @param z number
--- @return integer|nil veh
local function nearestAmbulance(x, y, z)
    if GetClosestVehicle == nil then return nil end
    local ok, veh = pcall(GetClosestVehicle, x, y, z,
                          tonumber(A.scanM) or 8.0, 0, 70)
    if not ok or not veh or veh == 0 then return nil end
    if not isTrue(DoesEntityExist(veh)) then return nil end
    if not isAmbulance(GetEntityModel(veh)) then return nil end
    return veh
end

--- Are this vehicle's rear doors open?
---
--- READ HERE AND NOWHERE ELSE, because GET_VEHICLE_DOOR_ANGLE_RATIO has no
--- server handler -- see BR.AmbHealSolve.doorsOpen for the full statement of
--- what that means and why it is the right half of the feature to leave on this
--- side. The ratio is a FLOAT, which is the one mercy in this path: there is no
--- BOOL here to misread, so the 0-is-truthy fault cannot reach it.
--- @param veh integer
--- @return boolean
local function rearDoorsOpen(veh)
    if GetVehicleDoorAngleRatio == nil then return false end
    local doors = A.rearDoors or { 2, 3 }
    local ratios = {}
    for i, door in ipairs(doors) do
        local ok, r = pcall(GetVehicleDoorAngleRatio, veh, door)
        -- `false` RATHER THAN nil FOR A DOOR THAT WOULD NOT READ, and this is
        -- not a style choice. In Lua a nil is not an element -- it is the END of
        -- the array -- so writing nil here would make `#ratios` shrink and the
        -- solver would check one door instead of two and approve the van. The
        -- solver refuses a short array as well; this is the half that stops it
        -- ever being short. See BR.AmbHealSolve.doorsOpen.
        ratios[i] = ok and r or false
    end
    return BR.AmbHealSolve.doorsOpen(ratios, A.doorOpenRatio or 0.35, #doors)
end

--- Is this player able to start a heal at that vehicle right now?
---
--- THE SAME CONDITIONS THE SERVER USES, MINUS THE ARBITRATION, asked locally so
--- the prompt does not need a round trip to appear. Deliberately NOT routed
--- through one shared "may I" function: the server has to re-derive all of it
--- from its own state anyway (a client's answer is exactly what an exploit would
--- forge), and a single call would create the impression that there is one
--- ruling when there are necessarily two. What IS shared is the arithmetic --
--- BR.AmbHealSolve -- so the two rulings cannot disagree about geometry.
---
--- WHAT THIS CANNOT KNOW: whether somebody else already has the van. That is the
--- one condition with no local answer, and it is why a press can be refused with
--- nothing on screen to say so. The cost is one wasted keypress at an occupied
--- ambulance; the alternative is publishing every claim to every client, which
--- is a per-vehicle broadcast for a fifteen-second interaction.
--- ...and the half of it that does not need a vehicle.
---
--- SPLIT OUT SO THE SCAN IS NEVER PAID FOR BY SOMEBODY WHO COULD NOT HEAL
--- ANYWAY. `nearestAmbulance` is a world query, the prompt pass runs ten times a
--- second for the whole match, and the overwhelmingly common answer is "this
--- player is on full health and nowhere near an ambulance". Every condition here
--- is a table read or one native, so asking them first turns the ordinary case
--- into a handful of comparisons.
--- @return boolean
local function eligible()
    if not A or A.enabled ~= true then return false end
    if session then return false end
    if BR.State.match.state ~= BR.MatchState.PLAYING then return false end
    if BR.State.me.state ~= BR.PlayerState.ALIVE then return false end

    -- HURT, on the client's own reading. The server re-asks its ledger, so this
    -- only decides whether a plate appears in front of somebody who has nothing
    -- to gain from it.
    if (tonumber(BR.State.me.hp) or 100.0) >= (tonumber(A.healTo) or 100.0) then
        return false
    end

    -- NOT FROM A CAR. You walk up to the back of an ambulance; you do not drive
    -- up to it and heal through the window. client/loot.lua's canTake makes the
    -- same call for the same reason.
    return not isTrue(IsPedInAnyVehicle(PlayerPedId(), false))
end

--- @param veh integer
--- @return boolean
local function canHeal(veh)
    if not eligible() then return false end
    return rearDoorsOpen(veh)
end

--- Is this player on the stretcher right now?
---
--- READ BY client/loot.lua, WHICH IS OTHERWISE TRYING TO HAND THEM A CRATE.
--- Same shape and same reason as BR.Rescue.riding(), which four files already
--- consult: `session` is this file's local and the one thing anybody else needs
--- to know is whether it exists. Nil-safe at the call site, so load order cannot
--- matter.
--- @return boolean
function BR.AmbHeal.healing()
    return session ~= nil
end

--- Is the stretcher plate on screen right now?
---
--- READ BY client/revivekey.lua, WHICH IS OTHERWISE OFFERING TO SELL REVIVE KEYS
--- AT THE SAME VAN. The two prompts are drawn on one shared browser and both
--- handlers act on one 'interact' press, so a hurt player behind an ambulance
--- with a squadmate down would start a heal AND spend 25 Volts on a single tap.
--- That file stands down while this returns true.
---
--- ONE MORE ACCESSOR RATHER THAN AN ARBITER, deliberately. The header above
--- records why a shared interaction registry is the right end state and is not
--- being built here; this is the same nil-guarded, call-time question
--- BR.AmbHeal.healing() and BR.Rescue.riding() already answer for five other
--- files, so it costs nothing and cannot create a load order.
--- @return boolean
function BR.AmbHeal.prompting()
    return promptShown == true
end

-- ---------------------------------------------------------------------------
-- The prompt
-- ---------------------------------------------------------------------------

--- The prompt page.
---
--- SHARED WITH THE CRATE, THE PUMP AND THE REVIVE, and client/fuel.lua's note is
--- the rule this follows: "One browser for every world prompt in the game". A
--- DUI is a whole CEF instance and a fifth one for a plate that is only up while
--- standing behind a van would be a browser per interaction.
---
--- THE OVERLAP, NAMED RATHER THAN DISCOVERED. client/loot.lua stands down while
--- BR.AmbHeal.healing(), so the crate and the stretcher can never both be
--- writing -- but BEFORE a heal starts they can: a crate on the tarmac behind an
--- ambulance puts two writers on one page and two handlers on one keypress. The
--- honest cost is that such a press does both. loot.lua's own header already
--- asks for the fix ("a shared interaction registry ... is the right move the
--- day a THIRD consumer shows up") and this file is that third consumer; it is
--- NOT built here, because it means restructuring the hottest frame pass in the
--- client and that pass has cost two playtests already. Recorded so the next
--- person to want it finds the argument rather than re-deriving it.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- Show or hide the plate.
---
--- ═══ THE COPY IS THE EXISTING VOCABULARY AND NOTHING ELSE ═══
---
--- `label` is the SUBJECT and `hint` is the VERB PHRASE -- client/loot.lua's
--- split, which client/dbno.lua and client/fuel.lua both follow. The subject is
--- BR.Config.AmbHeal.label(), which reads BR.Config.Rescue.blip.label, which is
--- already the word this exact vehicle is given on the map. The verb is
--- 'Press to heal', which is loot.lua's 'Press to pick up' with the verb changed
--- -- a PRESS rather than a HOLD, because that is what the input actually is.
---
--- ONE STRING AND NO SECOND ONE. The fuel pump has a "Currently fueling" state
--- because the owner asked for it in as many words; nobody asked for one here,
--- and there is deliberately NO on-screen hint saying how to get out again --
--- see the open questions in the report. When the heal starts, this comes down
--- and the screen says nothing at all until it ends.
---
--- SENT ON CHANGE. The label is a constant, so a plate that is up costs exactly
--- one message however long somebody stands there.
--- @param show boolean
--- @param veh integer|nil  what it is FOR; held for the frame pass to draw at
local function setPrompt(show, veh)
    show = (show == true)
    candidate = show and veh or nil
    if show == promptShown then return end
    promptShown = show

    local page = promptPage()
    if not show then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    BR.Dui.send(page, {
        t     = 'prompt',
        show  = true,
        label = BR.Config.AmbHeal.label(),
        hint  = A.promptHint or 'Press to heal',
        -- THE PLAYER'S OWN BINDING, asked for by COMMAND rather than by control,
        -- which is loot.lua's fix: reading control 51 left every prompt saying E
        -- after a rebind.
        key   = BR.Native.keyLabelForCommand('brinteract', 51),
        ring  = false,
    })
end

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

--- Put everything back.
---
--- CALLED FROM EVERY ENDING, including the ones that are not this file's making
--- -- the server ending it, the ped dying, the match tearing down, the resource
--- stopping. Written to be safe to call twice and safe to call on a session that
--- never finished being built, because what it prevents is a scripted camera and
--- an attached ped surviving into the next match.
---
--- @param place boolean|nil  put the ped down behind the ambulance
local function cleanup(place)
    local s = session
    session = nil
    setPrompt(false)
    if not s then return end

    local ped = PlayerPedId()

    -- ═══ THE ORDER HERE IS THE INSTRUCTION ═══
    --
    -- Detach, then place, then take the camera down. The camera is looking at
    -- the back of the van from eleven metres, so the placement happens ON SCREEN
    -- and reads as the player getting out -- which is what the owner described
    -- ("we force them out the back"). Destroying the camera first would cut to
    -- gameplay and then teleport, which is the same two events in the order that
    -- looks like a glitch.
    DetachEntity(ped, true, true)
    -- ...AND THE STRETCHER POSE GOES WITH THE STRETCHER. Left on, the player
    -- stands up behind the ambulance still sunbathing -- client/rescue.lua hit
    -- exactly this and its note describes the result as "lying in the road
    -- sunbathing, on their feet everywhere except the animation".
    ClearPedTasks(ped)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)

    if place and s.veh and isTrue(DoesEntityExist(s.veh)) then
        local c = GetEntityCoords(s.veh)
        local h = GetEntityHeading(s.veh)

        -- BEHIND THE AMBULANCE AS IT STANDS NOW, and the sign is the thing that
        -- gets got wrong: a GTA heading's forward vector is (-sin h, cos h), so
        -- behind is its negation. client/rescue.lua carries the same warning
        -- beside its delivery. Both go through BR.AmbHealSolve.dropPoint so
        -- there is one place for the sign to be right.
        local bx, by = BR.AmbHealSolve.dropPoint(c.x, c.y, h, A.reachM or 3.5)

        -- THE HEIGHT, WITH TWO FALLBACKS. The ground is what we want; the
        -- position the player walked in from is the next best thing and is
        -- literally "where they were before"; the vehicle's own origin is the
        -- last resort and is about a body's width too high, which gravity
        -- resolves in a few frames.
        local z = (s.from and s.from.z) or c.z
        if GetGroundZFor_3dCoord then
            local okG, hitG, gz = pcall(GetGroundZFor_3dCoord, bx, by, c.z + 1.0, false)
            if okG and isTrue(hitG) and gz then z = gz end
        end

        SetEntityCoords(ped, bx, by, z, false, false, false, true)
        -- FACING THE WAY THE VAN FACES, so they are looking away from it rather
        -- than at a door. The same heading the delivery uses.
        SetEntityHeading(ped, h)
    end

    if s.cam and isTrue(DoesCamExist(s.cam)) then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(s.cam, false)
    end

    -- THE SIREN AND THE DOME LIGHT GO BACK. Not because they hurt -- an
    -- ambulance left wailing in a field is a thing the owner would ask about --
    -- and only on the vehicle we turned them on for. Guarded on control the same
    -- way every other write to a vehicle this client did not create is: the
    -- request may simply be refused, and a refused siren is cosmetic.
    if s.veh and isTrue(DoesEntityExist(s.veh)) then
        if s.sirenWasOff then
            pcall(SetVehicleSiren, s.veh, false)
        end
        if s.litLight and SetVehicleInteriorlight then
            pcall(SetVehicleInteriorlight, s.veh, false)
        end
    end
end

BR.AmbHeal.cleanup = cleanup

-- ---------------------------------------------------------------------------
-- Getting in
-- ---------------------------------------------------------------------------

--- Ask for control of a vehicle this client did not create.
---
--- Every write below -- the siren, the dome light -- is a write to somebody
--- else's entity. NetworkRequestControlOfEntity returns whether the REQUEST was
--- accepted rather than whether control arrived, so client/rescue.lua asks in a
--- loop; this does not, because nothing here NEEDS control to succeed. The heal
--- is the feature and the siren is the flourish, so a refused request costs a
--- noise rather than a heal.
--- @param veh integer
local function nudgeControl(veh)
    if NetworkRequestControlOfEntity then pcall(NetworkRequestControlOfEntity, veh) end
end

--- The server said yes. Get on the stretcher.
--- @param netId integer
local function board(netId)
    local okVeh, veh = pcall(NetworkGetEntityFromNetworkId, netId)
    if not okVeh then veh = nil end
    if not veh or veh == 0 or not isTrue(DoesEntityExist(veh)) then
        -- The server granted a claim on a vehicle this machine cannot resolve.
        -- Say so and give it back rather than starting a session with no
        -- vehicle in it; the server's own tick would end it a second later.
        print('[br_core] ambheal: the server granted an ambulance this client cannot see')
        TriggerServerEvent(BR.Net.AMBHEAL_STOP)
        return
    end

    local ped = PlayerPedId()
    local from = GetEntityCoords(ped)

    session = {
        netId = netId, veh = veh,
        from  = { x = from.x, y = from.y, z = from.z },
        camPitch = -12.0, camYaw = 0.0,
    }
    setPrompt(false)

    nudgeControl(veh)

    -- ═══ THE STRETCHER. THE OWNER'S NUMBERS, AND THE CALL SHAPE IS PART OF THEM ═══
    --
    -- BR.Config.Rescue.stretcher, authored in game with /brattach at 0.01m and 1
    -- degree steps and confirmed by looking at it. config/rescue.lua's warning
    -- applies here word for word: the offsets are ONLY VALID FOR AN IDENTICAL
    -- ATTACH -- bone index 0 and the argument tail
    -- `false, false, false, false, 2, true`, which is client/bus.lua:244's shape
    -- and the one /brattach itself used. Change the bone or any of those flags
    -- and the body moves somewhere he never approved, silently.
    --
    -- The defaults below are the MEASURED values rather than a plausible guess,
    -- so a config that lost its stretcher table still puts the ped where he put
    -- it.
    local S = BR.Config.AmbHeal.stretcher()
    AttachEntityToEntity(ped, veh,
        0,
        S.x or -0.010, S.y or -3.100, S.z or 1.690,
        S.pitch or 0.0, S.roll or 0.0, S.yaw or 1.0,
        false, false, false, false, 2, true)

    -- ═══ AND IT IS CHECKED, BECAUSE EVERYTHING BELOW ASSUMES IT TOOK ═══
    --
    -- The camera, the control block and the pose are all things that would run
    -- for fifteen seconds around a ped standing in the road -- a player frozen
    -- out of their own controls, watching a van, next to it rather than in it.
    -- AttachEntityToEntity is synchronous and has no return value, so the only
    -- way to know is to ask, and the cheapest moment to ask is now: giving the
    -- claim straight back costs one message and nothing has been built yet.
    if not isTrue(IsEntityAttachedToEntity(ped, veh)) then
        print('[br_core] ambheal: the attach to the stretcher did not take')
        session = nil
        TriggerServerEvent(BR.Net.AMBHEAL_STOP)
        return
    end

    -- ═══ AND THE POSE, WHICH THE OFFSET IS ONLY CORRECT FOR ═══
    --
    -- The seventh number. config/rescue.lua: "a ped attached at
    -- (-0.010, -3.100, 1.690) in any other posture is not at the offset the
    -- owner approved; it is at the same coordinates with a different body around
    -- them." AFTER the attach and not before -- TaskPlayAnim on a free ped and
    -- then attaching it is two writes to one matrix in the order that lets the
    -- first one lose.
    poseOnStretcher(ped)

    -- ═══ THE SIREN. "run the siren" ═══
    --
    -- REMEMBERED BEFORE IT IS CHANGED, so the teardown can put back what was
    -- there rather than assuming it was off. An ambulance somebody was already
    -- driving with its siren on must not go quiet because a stranger healed in
    -- the back of it.
    if A.siren ~= false then
        local okS, was = pcall(IsVehicleSirenOn, veh)
        session.sirenWasOff = not (okS and isTrue(was))
        pcall(SetVehicleSiren, veh, true)
        pcall(SetVehicleHasMutedSirens, veh, false)
    end

    if A.interiorLight ~= false and SetVehicleInteriorlight then
        session.litLight = true
        pcall(SetVehicleInteriorlight, veh, true)
    end

    -- ═══ THE CAMERA. "Use the scripted cam while healing in the ambulance." ═══
    --
    -- THE RESCUE'S, AND ITS NUMBERS. Unattached and repositioned every frame by
    -- `ambheal.cam` below -- client/bus.lua:252 records the measurement both
    -- inherit: an attached camera is welded in place and kills free look. The
    -- position written here lasts one frame and exists only so the camera is not
    -- created at the world origin for that frame; the loop rewrites it from
    -- BR.Config.Rescue.camBackM and camHeight, which are the two the owner tuned
    -- by eye for a body on this stretcher.
    local vc = GetEntityCoords(veh)
    session.cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
        vc.x, vc.y, vc.z + ((R and R.camHeight) or 5.5), 0.0, 0.0, 0.0, 60.0, false, 2)
    SetCamActive(session.cam, true)
    RenderScriptCams(true, false, 0, true, true)

    print(('[br_core] ambheal: on the stretcher of ambulance %d'):format(netId))
end

-- ---------------------------------------------------------------------------
-- The pose
-- ---------------------------------------------------------------------------

local POSE_DICT, POSE_ANIM
do
    local S = (R and R.stretcher) or {}
    local p = S.pose or {}
    POSE_DICT = p.dict or 'amb@world_human_sunbathe@male@back@base'
    POSE_ANIM = p.anim or 'base'
end

--- Put the body in the pose, if the dictionary is here.
---
--- THE ARGUMENT TAIL IS PART OF THE MEASUREMENT, exactly as the attach's is.
--- `8.0, -8.0, -1, 1, 0.0, false, false, false` is client/rescue.lua's call and
--- client/attachtune.lua's before it -- the tool the offsets were authored with.
--- Flag 1 is LOOPING and the -1 duration is "until something stops it", which
--- together make this a pose rather than a clip that plays once and drops the
--- ped into whatever the engine falls back to. The three `false`s are the
--- position locks: an attached ped's position is the ATTACH's business, and
--- locking it here would be a second writer for the same matrix.
---
--- NON-BLOCKING. Called from a loop band, where a Citizen.Wait would stall every
--- other callback in it. A dictionary that is not resident is re-requested and
--- picked up on a later pass -- and a heal is fifteen seconds long, so a pose
--- that arrives on the second pass has arrived in time.
---
--- FORWARD-DECLARED because `board` above calls it. tools/check_forward_locals
--- is the gate that makes this mandatory rather than tidy: a `local function`
--- called from above its declaration resolves as a global, which is nil, and the
--- loop registry suspends the whole band after five throws.
--- @param ped integer
--- @return boolean posed
function poseOnStretcher(ped)   -- forward-declared as a local, above.
    if not isTrue(HasAnimDictLoaded(POSE_DICT)) then
        RequestAnimDict(POSE_DICT)
        return false
    end
    TaskPlayAnim(ped, POSE_DICT, POSE_ANIM, 8.0, -8.0, -1, 1, 0.0,
                 false, false, false)
    return true
end

-- ---------------------------------------------------------------------------
-- Input
-- ---------------------------------------------------------------------------

--- What a healing player may not do.
---
--- ═══ EVERY ID BELOW WAS LOOKED UP, NOT REMEMBERED ═══
---
--- docs.fivem.net/docs/game-references/controls. client/attachtune.lua and
--- client/spectate.lua both carry the same warning and the same reason:
--- client/inventory.lua's panel block labels 68 "VEH_ATTACK" and 69
--- "VEH_PASSENGER_ATTACK" in its comments and both are wrong, so copying a
--- neighbour's comment is how a wrong id gets a second home.
---
--- THIS IS client/dbno.lua's DOWNED_BLOCKED PLUS TWO, and being nearly the same
--- list is not laziness -- it is the same situation. A downed player and a
--- healing player are both a body the game is holding in place that must keep
--- its camera and must be able to press one key.
---
--- ═══ WHAT IS DELIBERATELY NOT BLOCKED, AND EACH IS LOAD-BEARING ═══
---
---   1 and 2 (LOOK_LR / LOOK_UD). The scripted camera's free look reads them
---   through GetDisabledControlNormal, so they would still function -- but
---   spectate.lua's note records that a disabled control's *enabled* reader
---   answers 0.0, and leaving them alone means nothing else that reads them
---   normally is surprised.
---
---   38 / 51 (PICKUP / CONTEXT, the E family). THE KEY THAT GETS YOU OUT. It is
---   the whole of the owner's "the only way to leave the ambulance while healing
---   should be pressing the interact button", so it is the one input that must
---   survive. (BR.Keys would read it either way -- it goes through the raw layer
---   and the IsDisabledControl* variants, which is exactly what client/fuel.lua
---   relies on to read interact through its own horn suppression -- but a key
---   the player is being told to press should not also be disabled.)
---
---   199 and 200 (FRONTEND_PAUSE). The pause menu must always open. It is the
---   last exit that does not depend on this file behaving.
---
--- ═══ AND WHY 75 IS ON THE LIST DESPITE BEING UNREACHABLE ═══
---
--- VEH_EXIT. client/rescue.lua's note is right that an attached ped cannot leave
--- a seat it was never in -- "there is no exit control to fight and no 'get out'
--- state machine to lose a race against". It is blocked anyway because the cost
--- is one array entry and the thing it guards against is somebody later putting
--- this player in a seat, at which point the absence would be a silent hole in
--- the owner's rule rather than a line to delete.
local BLOCKED = {
    21, 22, 23, 24, 25,          -- sprint, jump, enter vehicle, attack, aim
    30, 31, 32, 33, 34, 35,      -- movement axes and WASD
    266, 267, 268, 269,          -- ...and the _ONLY spellings of the same
    36,                          -- duck
    44,                          -- cover
    37,                          -- the weapon wheel
    47, 58,                      -- detonate, throw grenade
    75,                          -- exit vehicle. See above.
    140, 141, 142, 143,          -- melee light/heavy/alternate/block
    257, 263, 264,               -- attack2, melee1, melee2
}

BR.Keys.on('interact', function(pressed)
    if not pressed then return end

    -- ═══ WHILE HEALING, THIS KEY MEANS ONE THING AND IT IS "OUT" ═══
    --
    -- Checked FIRST, so a session cannot be started and stopped by one press and
    -- so no other reading of the key can get in front of it.
    --
    -- THE SERVER IS ASKED RATHER THAN TOLD-AND-ASSUMED. The teardown runs on
    -- AMBHEAL_SET coming back, not here, because the same message is what ends a
    -- heal the SERVER stopped -- one path out means the camera and the attach
    -- cannot be released twice or, worse, once for a stop the server refused.
    if session then
        if session.ending then return end
        session.ending = true
        TriggerServerEvent(BR.Net.AMBHEAL_STOP)
        return
    end

    -- ═══ ONE PROMPT, ONE VAN. THE PRESS ACTS ON WHAT WAS DRAWN ═══
    --
    -- `candidate` rather than a fresh search, which is client/loot.lua's #128
    -- lesson applied before it costs anything: the prompt and the claim used to
    -- resolve independently there, and with two crates in reach a player pressed
    -- while looking at one and took the other. Two ambulances parked at a
    -- station is the same picture. The press cannot name a vehicle the plate was
    -- not for, because there is only one answer and the plate is what wrote it.
    if not promptShown then return end
    local veh = candidate
    if not veh or not isTrue(DoesEntityExist(veh)) then return end
    if not canHeal(veh) then return end

    -- ...and it has to be networked, or there is nothing to name to the server.
    -- An ambulance that exists only on this machine is not a shared world object
    -- and cannot be arbitrated over; refused rather than healed locally, because
    -- a local-only heal is a heal with no claim behind it.
    if NetworkGetEntityIsNetworked ~= nil
       and not isTrue(NetworkGetEntityIsNetworked(veh)) then
        return
    end

    local ok, netId = pcall(NetworkGetNetworkIdFromEntity, veh)
    if not ok or not netId then return end

    TriggerServerEvent(BR.Net.AMBHEAL_START, { n = netId })
end)

-- ---------------------------------------------------------------------------
-- Loops
-- ---------------------------------------------------------------------------

--- The prompt, and finding something to point it at.
---
--- TICK RATHER THAN FRAME. Walking speed is about two metres a second, the
--- prompt's reach is three and a half, and ten passes a second is already an
--- order of magnitude finer than the question can change -- while the frame band
--- would put a vehicle scan and up to two door reads on every frame of every
--- player's game for a plate almost nobody is looking at.
BR.Loop.register(BR.Loop.TICK, 'ambheal.prompt', function()
    -- THE CHEAP HALF FIRST, so a full-health player standing in a field pays a
    -- few comparisons rather than a world query -- see `eligible`.
    if not eligible() then setPrompt(false) return end

    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local veh = nearestAmbulance(c.x, c.y, c.z)
    if not veh then setPrompt(false) return end

    -- THE REAR ARC, THROUGH THE SOLVER THE SERVER WILL RE-RUN. There is no
    -- position at which the plate is up and the server refuses on geometry --
    -- client/fuel.lua's header records what that divergence costs, and the
    -- server's own copy is deliberately the more forgiving of the two.
    local vc = GetEntityCoords(veh)
    local inReach = BR.AmbHealSolve.atRearDoors(
        vc.x, vc.y, GetEntityHeading(veh), c.x, c.y,
        A.reachM or 3.5, A.behindDot or -0.35)

    if not inReach or not canHeal(veh) then setPrompt(false) return end

    setPrompt(true, veh)
end)

--- ...and drawing it, which has to be per frame.
---
--- BR.Dui.drawWorld is a DrawSprite, and a sprite lasts exactly one frame. The
--- TICK band above decides WHETHER; this decides WHERE, sixty times a second, so
--- the plate is welded to the doors however fast the camera moves.
---
--- AT THE DROP POINT, WHICH IS THE SAME ARITHMETIC AS THE EXIT. The plate hangs
--- where the rear doors are and where the player will be put back down --
--- BR.AmbHealSolve.dropPoint, one function, so the plate cannot end up at the
--- bonnet on the day somebody flips a sign.
BR.Loop.register(BR.Loop.FRAME, 'ambheal.draw', function()
    if session or not promptShown then return end

    -- WHATEVER THE TICK PASS DECIDED, not a fresh search. Existence is re-checked
    -- because a vehicle can be destroyed between two ticks and reading the
    -- coordinates of a dead handle throws -- which in a frame callback costs the
    -- whole band after five of them.
    local veh = candidate
    if not veh or not isTrue(DoesEntityExist(veh)) then return end

    local vc = GetEntityCoords(veh)
    local bx, by = BR.AmbHealSolve.dropPoint(vc.x, vc.y, GetEntityHeading(veh),
                                             A.reachM or 3.5)
    BR.Dui.drawWorld(promptPage(), bx, by, vc.z + (A.promptLift or 1.1),
                     A.promptScale or 1.6)
end)

--- The control block, per frame.
---
--- FRAME RATHER THAN TICK, and DisableControlAction is the whole reason: a
--- disable lasts exactly one frame, so anything that suppresses a control has to
--- run in this band. client/fuel.lua's horn suppression and
--- client/inventory.lua's panel block are the same shape and the same argument.
---
--- AND THIS IS THE WHOLE OF THE LOCK. There is no matching "restore" anywhere in
--- this file, because there is nothing to restore -- the frame after this stops
--- running, every key in BLOCKED is live again. That is what makes the owner's
--- "still killable" requirement safe: a player who dies mid-heal has their
--- session ended by the watch below, this callback returns on its next pass, and
--- their controls come back with no code having had to remember to give them.
BR.Loop.register(BR.Loop.FRAME, 'ambheal.controls', function()
    if not session then return end
    for i = 1, #BLOCKED do
        DisableControlAction(0, BLOCKED[i], true)
    end
end)

--- The camera, per frame.
---
--- THE RESCUE'S, LINE FOR LINE, off BR.Config.Rescue.camBackM and camHeight.
--- Written every frame from the vehicle's own position, which is what keeps it
--- smooth over a vehicle physics is moving, and what lets the player look
--- around, because the camera is not attached to anything.
---
--- NOT HOISTED INTO A SHARED HELPER, and that is a judgement rather than an
--- oversight: it is nine lines of arithmetic, hoisting it would put the
--- ambulance ride and the heal station on one function in a file that owns
--- neither, and the coupling that actually matters -- the two NUMBERS -- is
--- already shared through the config. The comment is the coupling, and it names
--- the file to change with.
BR.Loop.register(BR.Loop.FRAME, 'ambheal.cam', function()
    local s = session
    if not s or not s.cam or not isTrue(DoesCamExist(s.cam)) then return end
    if not s.veh or not isTrue(DoesEntityExist(s.veh)) then return end

    local dx = GetDisabledControlNormal(0, 1)
    local dy = GetDisabledControlNormal(0, 2)
    s.camYaw   = (s.camYaw or 0.0) - dx * 8.0
    s.camPitch = BR.Clamp((s.camPitch or -12.0) - dy * 5.0, -60.0, 20.0)

    local c = GetEntityCoords(s.veh)
    local hdg = GetEntityHeading(s.veh) + s.camYaw
    local rad = math.rad(hdg)
    local pitchRad = math.rad(s.camPitch)

    local boom = (R and R.camBackM) or 11.0
    local back = boom * math.cos(pitchRad)
    local up   = ((R and R.camHeight) or 5.5) - boom * math.sin(pitchRad)

    SetCamCoord(s.cam, c.x + math.sin(rad) * back,
                       c.y - math.cos(rad) * back,
                       c.z + up)
    PointCamAtCoord(s.cam, c.x, c.y, c.z + 0.5)
end)

--- The pose, kept.
---
--- "ENFORCE" IS THE OPERATIVE WORD and client/rescue.lua's note applies: a pose
--- set once is a call something else overwrites. Nothing is re-tasking this ped
--- -- an ALIVE player has no dbno.controls holding them -- so anything the
--- engine hands it over fifteen seconds wins by default. The offset is only
--- correct for this clip, so a lost pose is a body in the wrong place.
---
--- 10Hz, and guarded by IsEntityPlayingAnim, which is dbno.lua's own rule
--- learned there: re-tasking unconditionally is a clip that restarts on its
--- first frame for ever and never plays. `3` is the standard task-filter mask.
BR.Loop.register(BR.Loop.TICK, 'ambheal.pose', function()
    local s = session
    if not s or s.ending or not s.veh then return end
    if not isTrue(DoesEntityExist(s.veh)) then return end

    local ped = PlayerPedId()
    -- Only while the body is actually ON the ambulance. Re-posing a ped the
    -- attach has lost would pin a player to the floor in a sunbathe.
    if not isTrue(IsEntityAttachedToEntity(ped, s.veh)) then return end
    if isTrue(IsEntityPlayingAnim(ped, POSE_DICT, POSE_ANIM, 3)) then return end

    poseOnStretcher(ped)
end)

--- The three things that end a heal from this side.
---
--- ═══ ALL THREE ARE THINGS THE SERVER CANNOT SEE ═══
---
--- server/ambheal.lua ends a heal for the reasons a server can judge: the player
--- left, died in the roster's eyes, their match ended, the vehicle stopped
--- existing on ITS machine, or they walked away. These are the ones only this
--- client can observe.
---
---   1. THE PED IS DEAD. THE OWNER'S REQUIREMENT, AND THIS IS THE LINE THAT
---      MAKES IT SAFE RATHER THAN THE ONE THAT MAKES IT TRUE. The player was
---      always killable -- nothing here or in client/natives.lua protected them
---      -- and client/gamerules.death has already reported the death down its
---      own unconditional path. What this does is make the death ORDINARY: the
---      attach comes off, the camera comes down and the control block stops, so
---      the corpse is a corpse rather than a body welded to a van under a
---      scripted camera nobody can dismiss.
---
---      CHECKED ON THE TICK BAND, which is the same band gamerules.death runs
---      in, so the two see the same frame's answer.
---
---   2. THE REAR DOORS SHUT. The owner's rule, enforced continuously rather than
---      only at the start -- another player can walk up and close them, and an
---      ambulance whose doors are shut around a healing player is exactly the
---      picture the rule exists to prevent.
---
---   3. THE AMBULANCE IS GONE. Blown up, streamed out, deleted. The server
---      notices too, one tick later, from its own copy; this is the half that
---      notices when the entity has gone on THIS machine only, which is what
---      would otherwise leave a camera pointed at nothing.
---
--- EVERY ONE OF THEM TELLS THE SERVER AND WAITS. The teardown runs when
--- AMBHEAL_SET comes back, so there is exactly one path out of a session
--- whatever ended it -- and the health already granted is kept, because the
--- server's targets were issued as they were earned.
BR.Loop.register(BR.Loop.TICK, 'ambheal.watch', function()
    local s = session
    if not s or s.ending then return end

    local ped = PlayerPedId()
    local why = nil

    if isTrue(IsEntityDead(ped)) or isTrue(IsPedFatallyInjured(ped)) then
        why = 'the player died on the stretcher'
    elseif not s.veh or not isTrue(DoesEntityExist(s.veh)) then
        why = 'the ambulance is gone'
    elseif not isTrue(IsEntityAttachedToEntity(ped, s.veh)) then
        -- ═══ THE BODY CAME OFF THE STRETCHER SOMEHOW ═══
        --
        -- `board` proves the attach took, so this is something that happened
        -- SINCE -- an engine event, a ragdoll, another script. Whatever it was,
        -- everything else this session is doing is now describing a player who
        -- is not in the ambulance: a camera pointed at a van they are standing
        -- beside, and a control block on a ped that could otherwise walk away.
        -- Ending is the honest answer and the heal so far is kept.
        why = 'the ped came off the stretcher'
    elseif A.stopOnDoorsShut ~= false and not rearDoorsOpen(s.veh) then
        why = 'the rear doors were shut'
    end

    if why == nil then return end

    s.ending = true
    TriggerServerEvent(BR.Net.AMBHEAL_STOP)
    print(('[br_core] ambheal: ending -- %s'):format(why))

    -- ═══ THE ONE CASE THAT DOES NOT WAIT ═══
    --
    -- A DEAD PLAYER IS TORN DOWN IMMEDIATELY rather than on the round trip. The
    -- server will answer and the answer will find nothing to do, which is fine;
    -- what is NOT fine is a corpse attached to a van, in a sunbathe, under a
    -- scripted camera, for however long the round trip takes -- on the one path
    -- where the player is also being handed to the spectator camera and the
    -- death word. This is the owner's "die completely" in the only place it
    -- could be got wrong.
    if isTrue(IsEntityDead(ped)) or isTrue(IsPedFatallyInjured(ped)) then
        cleanup(false)
    end
end)

-- ---------------------------------------------------------------------------
-- Wire
-- ---------------------------------------------------------------------------

RegisterNetEvent(BR.Net.AMBHEAL_SET)
AddEventHandler(BR.Net.AMBHEAL_SET, function(d)
    if type(d) ~= 'table' then return end

    -- BEGIN. `n` present and no session yet.
    if d.n ~= nil and not session then
        board(tonumber(d.n))
        return
    end

    -- END, whichever side decided it. `done` distinguishes a completed heal from
    -- an interrupted one for the log and for nothing else: the player is put
    -- down behind the ambulance either way, because "walk out" and "finish" both
    -- end with them standing at the back of a van, and having only one of them
    -- place the ped would leave the other attached to it.
    if session then
        print(('[br_core] ambheal: %s'):format(
            d.done == true and 'healed to full' or 'stopped early'))
        cleanup(true)
    end
end)

-- The match ending, the resource stopping, or the player being eliminated by
-- something that never reached the watch above. `cleanup` is safe on no session,
-- so all three can be blunt.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if type(d) ~= 'table' then return end
    if d.state ~= BR.MatchState.PLAYING then cleanup(false) end
end)

AddEventHandler('onResourceStop', function(name)
    if name == GetCurrentResourceName() then cleanup(false) end
end)

-- ---------------------------------------------------------------------------
-- Why is there no prompt?
-- ---------------------------------------------------------------------------

--- canHeal() is six guards and every one of them fails IDENTICALLY from the
--- outside -- no plate, no keypress, no error, no print. server/rescue.lua's
--- /brcpr exists because reading the file could not say which guard fired on a
--- live client, and three playtest rounds were spent guessing. Same problem,
--- same answer, before it costs the same three rounds.
RegisterCommand('brambulance', function()
    -- BEFORE ANYTHING TOUCHES THE CONFIG. Every reader below dereferences `A`,
    -- and the one state this command exists to explain includes "the config did
    -- not load" -- which must not be reported as a stack trace.
    if A == nil then
        print('--- brambulance: BR.Config.AmbHeal is nil; the feature is not loaded ---')
        return
    end

    local ped = PlayerPedId()
    local c = GetEntityCoords(ped)
    local veh = nearestAmbulance(c.x, c.y, c.z)

    local function line(label, pass, detail)
        print(('  %-24s %s%s'):format(
            label, pass and 'ok' or 'NO  <-- this one',
            detail and ('   ' .. tostring(detail)) or ''))
    end

    print('--- brambulance: why the heal prompt is or is not there ---')
    line('config loaded',   A ~= nil, 'BR.Config.AmbHeal')
    line('feature enabled', A ~= nil and A.enabled == true)
    line('not already healing', session == nil)
    line('match PLAYING',   BR.State.match.state == BR.MatchState.PLAYING,
         ('state is %s'):format(tostring(BR.State.match.state)))
    line('you are ALIVE',   BR.State.me.state == BR.PlayerState.ALIVE,
         ('state is %s'):format(tostring(BR.State.me.state)))
    line('you are hurt',    (tonumber(BR.State.me.hp) or 100.0)
                                < (tonumber(A and A.healTo) or 100.0),
         ('hp is %s'):format(tostring(BR.State.me.hp)))
    line('on foot',         not isTrue(IsPedInAnyVehicle(ped, false)))
    line('an ambulance near', veh ~= nil,
         ('scan radius %.1fm'):format(tonumber(A and A.scanM) or 8.0))

    if veh then
        local vc = GetEntityCoords(veh)
        local inReach, dist, dot = BR.AmbHealSolve.atRearDoors(
            vc.x, vc.y, GetEntityHeading(veh), c.x, c.y,
            (A and A.reachM) or 3.5, (A and A.behindDot) or -0.35)
        line('at the rear doors', inReach,
             ('%.1fm away, dot %.2f (want <= %.2f within %.1fm)')
                 :format(dist, dot, (A and A.behindDot) or -0.35,
                         (A and A.reachM) or 3.5))
        line('rear doors open',  rearDoorsOpen(veh),
             ('doors %s, want ratio >= %.2f')
                 :format(table.concat(A.rearDoors or { 2, 3 }, ' and '),
                         (A and A.doorOpenRatio) or 0.35))
        line('networked',        NetworkGetEntityIsNetworked == nil
                                    or isTrue(NetworkGetEntityIsNetworked(veh)),
             'a local-only vehicle cannot be arbitrated over')
    end

    print(('  => the plate is %s'):format(promptShown and 'up' or 'down'))
    print('  (whether somebody ELSE has that ambulance is only knowable on the')
    print('   server -- run brambheal there.)')
end, false)
