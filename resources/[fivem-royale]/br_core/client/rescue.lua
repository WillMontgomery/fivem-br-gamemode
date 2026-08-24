-- The CPR kit's rescue, client side (#191).
--
-- The one prompt, the fade, the ambulance, the medic, the stretcher, the camera
-- and the drive. The server decides whether any of this may happen and where it
-- goes (server/rescue.lua); this file is everything that can only be done on the
-- machine the player is sitting at.
--
-- ═══ ONE NOTIFICATION. THE WHOLE CYCLE. ═══
--
-- "press [interact key] to call a medic" is THE ONLY THING SHOWN TO THE PLAYER
-- AT ANY POINT IN THIS FEATURE. Not on dispatch, not on arrival, not when the
-- ambulance is destroyed, not when a recovery fires. The owner has been
-- explicit and repeatedly annoyed about invented UI copy, and the discipline is
-- easier to keep than to restore: there is exactly one BR.Dui.send in this file
-- and no BR.Native.help, no notify, and no toast anywhere in the feature.
--
-- #191 STEP 6 ASKED FOR A TIMER AND THERE IS NONE. The hard deadline is real and
-- does its whole job on the server; it simply is not drawn. A countdown is a
-- second notification, and there is only one.

BR = BR or {}
BR.Rescue = {}

local R = BR.Config.Rescue

--- A FiveM native declared BOOL may hand Lua a `1` rather than `true`, and `0`
--- is TRUTHY in Lua -- so both obvious spellings of the test are wrong, in
--- opposite directions. Every BOOL read in this file goes through here; see
--- tools/bool_native_rules.lua for the seven shipped instances that bought this.
local function isTrue(v) return v == true or v == 1 end

--- The ride, or nil. Everything the teardown needs is on it, because a teardown
--- that has to go looking for its own handles is a teardown that leaks one.
---   veh, driver   entity handles
---   cam           the scripted camera
---   dest          where we are going
---   reported      latched, so this ride reports its outcome exactly once
---   ending        RESCUE_END is running; the sanity sweep must keep its hands off
local ride = nil

--- The last thing the prompt was told, so it is sent on CHANGE rather than per
--- frame -- a re-send restarts the page's animation.
local promptShown = nil

-- ---------------------------------------------------------------------------
-- The prompt
-- ---------------------------------------------------------------------------

--- The crate's page. One browser for every world prompt in the game.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- Do I hold a CPR kit?
---
--- ASKED OF THE LOCAL MIRROR, which is the right authority for a PROMPT and the
--- wrong one for anything else. The server re-asks its own copy before it grants
--- a rescue (server/rescue.lua's `kitSlot`), so a client that lies to itself here
--- gets a prompt that does nothing when pressed -- which is a cosmetic bug for a
--- cheater and not a way into a rescue.
--- @return boolean
local function holdingKit()
    local inv = BR.Inv and BR.Inv.local_()
    if not inv or not inv.slots then return false end
    for i = 1, (BR.Config.Loot.slots or 5) do
        local s = inv.slots[i]
        if s and s.item == 'cprkit' then return true end
    end
    return false
end

--- May this player call a medic right now?
---
--- THE SAME THREE CONDITIONS THE SERVER USES, asked locally so the prompt does
--- not need a round trip to appear. Deliberately NOT a shared solver: the server
--- has to re-derive all of it from its own state anyway (a client's answer is
--- exactly the thing an exploit would forge), so a shared function would create
--- the impression that one call is the ruling when there are necessarily two.
--- @return boolean
local function canCall()
    if not R or not R.enabled then return false end
    if ride then return false end
    if BR.State.match.state ~= BR.MatchState.PLAYING then return false end
    if BR.State.me.state ~= BR.PlayerState.DBNO then return false end
    if BR.State.match.mode ~= BR.Mode.SOLO.key then return false end
    return holdingKit()
end

--- @param show boolean
local function setPrompt(show)
    if show == promptShown then return end
    promptShown = show

    local page = promptPage()
    if not show then
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    -- THE WORDING IS THE OWNER'S, VERBATIM (#191 step 2: "press [interact key]
    -- to call a medic"), split across the page's label/hint/key fields because
    -- that is the shape the page draws -- the KEY is rendered as its own glyph,
    -- which is the whole reason this is a DUI and not an engine help box.
    -- Nothing here invents a word.
    BR.Dui.send(page, {
        t     = 'prompt',
        show  = true,
        label = 'Call a medic',
        hint  = 'Press',
        key   = BR.Native.keyLabelForCommand('brinteract',
                                             BR.Config.Loot.promptControl or 51),
        ring  = false,
    })
end

BR.Loop.register(BR.Loop.FRAME, 'rescue.prompt', function()
    local want = canCall()
    setPrompt(want)
    if not want then return end

    local page = promptPage()
    if not BR.Dui.ready(page) then return end

    -- THE DESCENT PROMPT'S POSITION, deliberately shared with the bus and the
    -- glider. From the player's side these are one box that keeps appearing in
    -- the same place with different words in it, and reading BR.Config.Drop
    -- rather than copying its numbers is what stops them drifting apart.
    --
    -- NO ENGINE FALLBACK. The bus prompt falls back to BR.Native.help after
    -- three seconds because a player who cannot see the jump prompt does not
    -- jump and loses the match. This one is a downed player with a bleed timer
    -- and a rare item: the cost of a missing browser is one wasted kit, and the
    -- cost of a fallback is a second surface in a feature whose defining rule is
    -- that it has exactly one.
    local D = BR.Config.Drop
    BR.Dui.drawScreen(page, (D and D.promptX) or 0.5,
                            (D and D.promptY) or 0.78,
                            (D and D.promptScale) or 0.17)
end)

BR.Keys.on('interact', function(pressed)
    if not pressed or not canCall() then return end
    TriggerServerEvent(BR.Net.RESCUE_CALL)
end)

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

--- Put everything back.
---
--- CALLED FROM EVERY ENDING, including the ones that are not endings of this
--- file's making -- the match tearing down mid-ride, the player being eliminated
--- by the server, a resource restart. It is written to be safe to call twice and
--- safe to call on a ride that never finished being built, because the failure
--- it prevents is a scripted camera and a detached ped surviving into the next
--- match.
local function cleanup()
    local r = ride
    ride = nil
    if not r then return end

    local ped = PlayerPedId()
    DetachEntity(ped, true, true)
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)

    if r.cam and isTrue(DoesCamExist(r.cam)) then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(r.cam, false)
    end

    if r.driver and isTrue(DoesEntityExist(r.driver)) then
        DeleteEntity(r.driver)
    end
    if r.veh and isTrue(DoesEntityExist(r.veh)) then
        DeleteEntity(r.veh)
    end
end

BR.Rescue.cleanup = cleanup

-- ---------------------------------------------------------------------------
-- The ride
-- ---------------------------------------------------------------------------

--- Load a model, or give up.
--- @param name string|integer
--- @param ms integer
--- @return integer|nil hash
local function loadModel(name, ms)
    local hash = type(name) == 'number' and name or GetHashKey(name)
    RequestModel(hash)
    local deadline = GetGameTimer() + ms
    while not isTrue(HasModelLoaded(hash)) and GetGameTimer() < deadline do
        Citizen.Wait(50)
    end
    if not isTrue(HasModelLoaded(hash)) then return nil end
    return hash
end

--- Point the AI at the destination.
---
--- THE FIRST `TaskVehicleDriveToCoord` IN THIS TREE. Everything else that moves
--- -- the Battle Bus, the airdrop plane -- is flown by writing coordinates every
--- frame, which is exact and reproducible and completely unsuitable here: an
--- ambulance has to obey roads and traffic, and a coordinate write would slide
--- it through both.
---
--- RE-TASKED RATHER THAN TASKED ONCE, because a re-place has to be able to start
--- the journey again from wherever the vehicle has been put.
--- @param r table
local function taskDrive(r)
    if not r.driver or not isTrue(DoesEntityExist(r.driver)) then return end

    SetDriverAbility(r.driver, R.driverAbility or 0.6)
    SetDriverAggressiveness(r.driver, R.driverAggression or 0.8)
    SetPedKeepTask(r.driver, true)

    TaskVehicleDriveToCoord(r.driver, r.veh,
        r.dest.x, r.dest.y, r.dest.z,
        R.driveSpeed or 30.0,
        0,                                  -- no special driving mode
        GetEntityModel(r.veh),
        R.driveStyle or 262144,
        4.0,                                -- stop within 4m of the point
        true)
    SetDriveTaskDrivingStyle(r.driver, R.driveStyle or 262144)
    SetDriveTaskMaxCruiseSpeed(r.driver, R.driveSpeed or 30.0)
end

--- Where to actually park.
---
--- #191 step 7: "The driver checks for vehicles already at the parking spot --
--- another ambulance may have arrived with another player -- and picks a nearby
--- space." Two rescues can genuinely converge on one point, because the
--- destination solver picks the shortest qualifying route and two players downed
--- in the same part of the map get the same answer.
---
--- Walks out in a ring rather than picking a random offset: the offsets are
--- tried in a fixed order so the second ambulance parks in a predictable place
--- rather than somewhere new every time the code runs.
--- @param x number
--- @param y number
--- @param z number
--- @return number, number, number
local function freeSpaceNear(x, y, z)
    if isTrue(IsPositionOccupied(x, y, z, 3.0, false, true, false, false, false, 0, false)) then
        for _, step in ipairs({ 5.0, 10.0, 15.0 }) do
            for deg = 0, 315, 45 do
                local rad = math.rad(deg)
                local nx, ny = x + math.cos(rad) * step, y + math.sin(rad) * step
                if not isTrue(IsPositionOccupied(nx, ny, z, 3.0, false, true, false, false, false, 0, false)) then
                    return nx, ny, z
                end
            end
        end
    end
    return x, y, z
end

--- Build the ambulance and get in the back.
--- @param d table  the server's RESCUE_BEGIN payload
local function board(d)
    Citizen.CreateThread(function()
        -- FADE FIRST (#191 step 3). Everything below -- a vehicle appearing out
        -- of nothing, a ped being teleported into the back of it, a camera
        -- taking over -- is exactly the sequence a fade exists to hide.
        DoScreenFadeOut(400)
        local t0 = GetGameTimer()
        while not isTrue(IsScreenFadedOut()) and GetGameTimer() - t0 < 1200 do
            Citizen.Wait(50)
        end

        -- The generation guard the bus learned the hard way: this thread yields
        -- several times, and the rescue can be ended underneath it by the server
        -- (destroyed, match over) while it is still assembling. Without this, a
        -- superseded boarding finishes anyway and leaves an orphan ambulance
        -- with a camera pointed at it.
        -- Nothing has been built yet at this point, so a plain "is there still a
        -- ride" test is the whole question. Past the vehicle creation below it
        -- stops being enough -- see the orphan guard further down.
        if not ride then return end
        local r = ride

        local model = loadModel(R.model or 'ambulance', 10000)
        if not model then
            print('[br_core] rescue: the ambulance model never loaded')
            -- Say nothing to the player and let the deadline resolve it. There
            -- is no message for this and there must not be one.
            return
        end

        local p = d.pickup
        local px, py, pz = freeSpaceNear(p.x, p.y, p.z)

        -- ═══ NETWORKED, AND THAT REVERSES WHAT THREE OTHER FILES EXPECTED ═══
        --
        -- server/fuel.lua, client/fuel.lua and server/vehicles.lua all carry
        -- comments written BEFORE the owner's 2026-08-23 message saying #191's
        -- ambulance would be "local and non-networked", like the Battle Bus.
        -- That is no longer possible and the reason is the whole point of the
        -- reversal: "other players can blow up the ambulance which kills you".
        -- A non-networked vehicle does not exist on anybody else's machine, so
        -- there would be nothing for them to shoot. Destructibility by other
        -- players REQUIRES a networked entity; the two cannot both be had.
        --
        -- WHAT THAT COSTS, CHECKED RATHER THAN ASSUMED:
        --
        --   FUEL: still free, but by a DIFFERENT mechanism than those comments
        --   describe. server/fuel.lua's registry only admits a vehicle a player
        --   is SITTING IN, and this player is ATTACHED to the stretcher rather
        --   than in a seat -- GetVehiclePedIsIn answers 0 for an attached ped.
        --   The exemption survives the networking change intact; only the reason
        --   for it moved, so those comments have been corrected rather than left
        --   to mislead the next reader.
        --
        --   ANTI-CHEAT: server/vehicles.lua's `entityCreating` detector sees
        --   client-created networked entities, so it does see this one. It files
        --   only on a REFUSED model, and that file already anticipated this
        --   exact vehicle: "An ambulance is not on that list." Nothing is
        --   exempted, because nothing needs to be.
        r.veh = CreateVehicle(model, px, py, pz, p.heading or 0.0, true, false)
        SetModelAsNoLongerNeeded(model)
        SetEntityAsMissionEntity(r.veh, true, true)

        -- NOT INVINCIBLE. There is no SetEntityInvincible here and there must
        -- never be one: #191 asked for godmode and the owner reversed it on
        -- 2026-08-23. The ambulance takes damage, burns and explodes like any
        -- other vehicle, and that is the feature.
        SetVehicleEngineOn(r.veh, true, true, false)
        SetVehicleSiren(r.veh, R.siren ~= false)
        SetVehicleHasMutedSirens(r.veh, false)
        SetVehicleWindowTint(r.veh, R.windowTint or 0)

        -- TYRES: see config/rescue.lua. Kept bulletproof for a mechanical
        -- reason rather than a protective one -- a shot-out tyre cannot kill
        -- anybody, it can only wedge the ambulance, which is a way to force the
        -- recovery machinery to run from outside.
        SetVehicleTyresCanBurst(r.veh, not (R.tyresBulletproof ~= false))

        -- DOORS LOCKED so no other player can get in (#191 step 4). 4 is
        -- "locked for everyone including the player". The passenger cannot get
        -- out either -- but that is not what this line achieves, and it is worth
        -- being precise: THE PLAYER CANNOT EXIT BECAUSE THEY ARE NOT IN A SEAT.
        -- An attached ped has no vehicle to leave, so there is no exit control
        -- to fight and no "get out" state machine to lose a race against.
        SetVehicleDoorsLocked(r.veh, 4)

        -- Maximum upgrades except suspension (#191 step 4). Resolved against
        -- what this model actually HAS rather than a hardcoded tier, which is
        -- how a vehicle ends up silently unmodified.
        SetVehicleModKit(r.veh, 0)
        for _, mod in ipairs({ { 11, 'engine' }, { 12, 'brakes' }, { 13, 'transmission' }, { 16, 'armour' } }) do
            if (R.upgrades or {})[mod[2]] == 'max' then
                local n = GetNumVehicleMods(r.veh, mod[1])
                if n and n > 0 then SetVehicleMod(r.veh, mod[1], n - 1, false) end
            end
        end
        if (R.upgrades or {}).turbo then ToggleVehicleMod(r.veh, 18, true) end

        -- The medic. A seated ped is what drives; it is also what keeps the
        -- engine simulation running, the same property the Battle Bus's pilot
        -- has. Invincible, unlike the vehicle: an NPC that can be shot out of
        -- the driver's seat would strand the ambulance without destroying it,
        -- which is precisely the "stuck versus destroyed" ambiguity the server
        -- has to resolve -- and the cheapest place to remove a source of it is
        -- here, before it happens.
        local pedModel = loadModel(R.driverModel or 's_m_m_paramedic_01', 5000)
        if pedModel then
            r.driver = CreatePed(4, pedModel, px, py, pz, p.heading or 0.0, true, false)
            SetModelAsNoLongerNeeded(pedModel)
            SetEntityInvincible(r.driver, true)
            SetBlockingOfNonTemporaryEvents(r.driver, true)
            SetPedCanBeDraggedOut(r.driver, false)
            SetPedIntoVehicle(r.driver, r.veh, -1)
        end

        -- ═══ THE ORPHAN GUARD, AND IT IS `ride ~= r` RATHER THAN `not ride` ═══
        --
        -- THE VEHICLE AND THE MEDIC NOW EXIST, so from here a bare "did the ride
        -- end" test is not enough: returning would leave an ambulance and a
        -- paramedic standing in the world with nothing owning them, and
        -- `cleanup` has already run against the record they are NOT on. That is
        -- client/bus.lua's two-plane bug exactly -- a superseded boarding that
        -- finished anyway and orphaned everything it had built.
        --
        -- Comparing the RECORD rather than testing for nil also catches the
        -- worse case: a second rescue that began while this thread was loading
        -- models. `ride` is non-nil and belongs to somebody else, and tearing it
        -- down would be a live rescue destroyed by a stale thread -- so this
        -- deletes only what THIS thread made.
        if ride ~= r then
            if r.driver and isTrue(DoesEntityExist(r.driver)) then DeleteEntity(r.driver) end
            if r.veh and isTrue(DoesEntityExist(r.veh)) then DeleteEntity(r.veh) end
            print('[br_core] rescue: boarding was superseded; the ambulance it built is gone')
            return
        end

        -- ═══ THE PED RIDES THE STRETCHER, NOT A SEAT ═══
        --
        -- AttachEntityToEntity at a cabin offset, own ped to own vehicle, which
        -- is client/bus.lua:244's pattern and is used here for the reason the
        -- comment there records: the seat API brings network attach problems
        -- this avoids entirely. It is also what makes the arrival read properly
        -- -- the player watches their own body in the back of the ambulance, and
        -- when the doors open they are already there.
        --
        -- AND IT IS WHY THERE IS NO EXIT TO BLOCK. A ped that was never put in a
        -- seat cannot leave one.
        local ped = PlayerPedId()
        local S = R.stretcher or {}
        AttachEntityToEntity(ped, r.veh,
            0,
            S.x or 0.0, S.y or -1.6, S.z or 0.55,
            S.pitch or 0.0, S.roll or 90.0, S.yaw or 180.0,
            false, false, false, false, 2, true)

        -- ═══ THE CAMERA ═══
        --
        -- UNATTACHED, repositioned every frame by the loop below. client/bus.lua
        -- :252 records the measurement this inherits: an attached camera is
        -- welded in place and kills free look, and free look was the first thing
        -- missed. Third person on the vehicle, scenic, never first person, and
        -- the same behaviour at both ends of the journey.
        local vc = GetEntityCoords(r.veh)
        r.cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            vc.x, vc.y, vc.z + 3.0, 0.0, 0.0, 0.0, 60.0, false, 2)
        SetCamActive(r.cam, true)
        RenderScriptCams(true, false, 0, true, true)

        taskDrive(r)

        DoScreenFadeIn(600)
        print(('[br_core] rescue: aboard (vehicle %d) bound for %s')
            :format(r.veh, tostring(r.dest.id)))
    end)
end

RegisterNetEvent(BR.Net.RESCUE_BEGIN)
AddEventHandler(BR.Net.RESCUE_BEGIN, function(d)
    if type(d) ~= 'table' or not d.pickup or not d.dest then return end
    if ride then return end

    ride = {
        dest    = d.dest,
        camYaw  = 0.0,
        camPitch = -12.0,
        reported = false,
    }
    board(d)
end)

--- The server has decided this ambulance is stuck and ordered a re-place.
---
--- THE CLIENT NEVER DECIDES THIS. It is told, because "has the ambulance made
--- progress" is judged on the server's own position samples -- a client-asserted
--- stall would be a client-asserted teleport. All this handler does is carry it
--- out.
RegisterNetEvent(BR.Net.RESCUE_PLACE)
AddEventHandler(BR.Net.RESCUE_PLACE, function(d)
    local r = ride
    if not r or not r.veh or not isTrue(DoesEntityExist(r.veh)) then return end

    local dist = (type(d) == 'table' and d.distM) or 15.0
    local c = GetEntityCoords(r.veh)

    -- ON A ROAD, NOT JUST ELSEWHERE. #191: "teleport it ~50ft away -- still on a
    -- road". Dropping a wedged ambulance into a field would trade a stuck
    -- vehicle for one that cannot find its way back to the network, and the
    -- recovery would then fire forever.
    --
    -- The node is searched for AHEAD along the route rather than at a random
    -- bearing, so a recovery makes progress toward the destination instead of
    -- shuffling the vehicle around the obstruction it is already caught on.
    local bearing = BR.Bearing(c.x, c.y, r.dest.x, r.dest.y)
    local rad = math.rad(bearing)
    local tx, ty = c.x + math.sin(rad) * dist, c.y + math.cos(rad) * dist

    local ok, node, heading = GetClosestVehicleNodeWithHeading(tx, ty, c.z, 1, 3.0, 0)
    if isTrue(ok) and node then
        SetEntityCoords(r.veh, node.x, node.y, node.z + 1.0, false, false, false, true)
        SetEntityHeading(r.veh, heading or 0.0)
    else
        SetEntityCoords(r.veh, tx, ty, c.z, false, false, false, true)
    end

    SetVehicleOnGroundProperly(r.veh)
    taskDrive(r)
    print('[br_core] rescue: re-placed on the server\'s order')
end)

--- Delivered, or dead. Either way the ride is over.
RegisterNetEvent(BR.Net.RESCUE_END)
AddEventHandler(BR.Net.RESCUE_END, function(d)
    Citizen.CreateThread(function()
        local delivered = type(d) == 'table' and d.delivered == true

        -- LATCHED BEFORE THE FIRST YIELD. `rescue.sanity` below tears down any
        -- ride whose player is no longer downed, and a DELIVERY makes them ALIVE
        -- -- so without this the sanity sweep and this handler race, and the
        -- sweep wins often enough to detach the ped and kill the camera while
        -- the screen is still up. That reads as the world snapping a beat before
        -- the fade. The ending is this handler's to run.
        if ride then ride.ending = true end

        -- FADE FIRST ON THE WAY OUT TOO (#191 step 7), and the fade is what the
        -- detach and the teleport hide.
        DoScreenFadeOut(400)
        local t0 = GetGameTimer()
        while not isTrue(IsScreenFadedOut()) and GetGameTimer() - t0 < 1200 do
            Citizen.Wait(50)
        end

        cleanup()

        if delivered then
            -- ON THE GROUND DIRECTLY BEHIND THE AMBULANCE (#191 step 7), which
            -- is where the rear doors are. Health and weapons are the server's
            -- business and are already restored by the time this runs.
            -- BEHIND, and the sign matters. A GTA heading's FORWARD vector is
            -- (-sin h, cos h), so behind is its negation -- getting this
            -- backwards puts the player in front of the bonnet, which is both
            -- wrong and the one place a still-rolling ambulance can hit them.
            local ped = PlayerPedId()
            local h = d.heading or 0.0
            local rad = math.rad(h)
            local bx = d.x + math.sin(rad) * (R.dropBackM or 3.5)
            local by = d.y - math.cos(rad) * (R.dropBackM or 3.5)

            SetEntityCoords(ped, bx, by, d.z, false, false, false, true)
            SetEntityHeading(ped, h)

            -- Wait for the ground under them before showing it. Landing a ped
            -- on unstreamed collision is how a delivery ends up underneath the
            -- map, and the fade is already down so the wait costs nothing
            -- visible.
            local t1 = GetGameTimer()
            while not isTrue(HasCollisionLoadedAroundEntity(ped))
                  and GetGameTimer() - t1 < 3000 do
                Citizen.Wait(50)
            end
        end

        DoScreenFadeIn(600)
    end)
end)

-- ---------------------------------------------------------------------------
-- Watching the ride
-- ---------------------------------------------------------------------------

--- The camera, per frame.
---
--- Written every frame from the vehicle's own position, which is what keeps it
--- smooth over a vehicle the physics engine is moving -- and what lets the
--- player look around, because the camera is not attached to anything.
BR.Loop.register(BR.Loop.FRAME, 'rescue.cam', function()
    local r = ride
    if not r or not r.cam or not isTrue(DoesCamExist(r.cam)) then return end
    if not r.veh or not isTrue(DoesEntityExist(r.veh)) then return end

    -- Free look, on the right stick / mouse, exactly as the bus does it.
    local dx = GetDisabledControlNormal(0, 1)
    local dy = GetDisabledControlNormal(0, 2)
    r.camYaw   = (r.camYaw or 0.0) - dx * 8.0
    r.camPitch = BR.Clamp((r.camPitch or -12.0) - dy * 5.0, -60.0, 20.0)

    local c = GetEntityCoords(r.veh)
    local hdg = GetEntityHeading(r.veh) + r.camYaw
    local rad = math.rad(hdg)
    local pitchRad = math.rad(r.camPitch)

    local back = 7.0 * math.cos(pitchRad)
    local up   = 2.5 - 7.0 * math.sin(pitchRad)

    SetCamCoord(r.cam, c.x + math.sin(rad) * back,
                       c.y - math.cos(rad) * back,
                       c.z + up)
    PointCamAtCoord(r.cam, c.x, c.y, c.z + 0.5)
end)

--- Is the ambulance a wreck, and are we there yet?
---
--- THE ONLY TWO THINGS THIS CLIENT EVER TELLS THE SERVER ABOUT A RIDE IN
--- PROGRESS, and they are believed very differently at the other end -- see the
--- scheme at the top of server/rescue.lua. The destruction report is trusted on
--- sight because it can only kill the sender; the arrival report is checked
--- against the server's own evidence that the ambulance was moving.
BR.Loop.register(BR.Loop.TICK, 'rescue.watch', function()
    local r = ride
    if not r or not r.veh then return end
    if r.reported then return end

    -- ═══ DESTROYED ═══
    --
    -- THREE TESTS, NOT ONE, because a vehicle can stop being an ambulance in
    -- three different ways and only one of them is an explosion. It can be
    -- deleted outright (the entity stops existing), it can be destroyed (dead
    -- but still there, burning), or it can be rendered undriveable -- which is
    -- what a wrecked engine looks like before the fire finishes. All three mean
    -- the same thing to the player inside: this ambulance is not going anywhere,
    -- and by the owner's rule they are out.
    if not isTrue(DoesEntityExist(r.veh))
       or isTrue(IsEntityDead(r.veh))
       or not isTrue(IsVehicleDriveable(r.veh, false)) then
        r.reported = true   -- latch: report once, whatever happens next
        print('[br_core] rescue: the ambulance is gone -- reporting it')
        TriggerServerEvent(BR.Net.RESCUE_LOST)
        return
    end

    -- ═══ ARRIVED ═══
    local c = GetEntityCoords(r.veh)
    if BR.Dist(c.x, c.y, r.dest.x, r.dest.y) <= 8.0 then
        r.reported = true
        -- Rear doors open on arrival (#191 step 7). The siren is NOT turned off
        -- -- the owner asked for it on the whole time, and "the whole time"
        -- includes this moment.
        SetVehicleDoorOpen(r.veh, 2, false, false)
        SetVehicleDoorOpen(r.veh, 3, false, false)
        TriggerServerEvent(BR.Net.RESCUE_ARRIVED)
    end
end)

-- ---------------------------------------------------------------------------
-- The map
-- ---------------------------------------------------------------------------

--- Ambulance blips. [key] = blip handle.
---
--- TWO KINDS ON ONE TABLE, and the client does not know or care which is which.
--- The server sends `r:<src>` for a rescue in flight and `v:<entity>` for an
--- ambient ambulance somebody was seen driving; both are just strings here. That
--- is what lets the server add a category without this file changing.
---
--- NOT `ride`. These are other people's ambulances, tracked separately from the
--- one ride this machine might itself be taking; the two never interact.
local blips = {}

--- @param key string
local function dropBlip(key)
    local b = blips[key]
    blips[key] = nil
    if b and isTrue(DoesBlipExist(b)) then RemoveBlip(b) end
end

--- Owner, 2026-08-23: "if someone takes it, we need to update it's location on
--- the map for other players when their blips are shown."
---
--- DRAWN FROM SERVER COORDINATES, which is client/squadmates.lua's pattern and
--- is chosen for its reason: an entity-anchored blip stops existing at the ~424m
--- scope ceiling, and an ambulance driving across the map is precisely the thing
--- that ceiling breaks. Data the server sends has no such limit, so the blip
--- survives the whole journey.
RegisterNetEvent(BR.Net.RESCUE_BLIP)
AddEventHandler(BR.Net.RESCUE_BLIP, function(d)
    if type(d) ~= 'table' or type(d.key) ~= 'string' then return end

    -- NEVER YOUR OWN RESCUE. The one rule this feature is built around is that
    -- the player being rescued sees exactly one thing -- the prompt that started
    -- it -- for the whole cycle. A blip on their own ambulance would be a second
    -- surface telling them where they already are. Everyone else's map follows
    -- it, which is the whole of what was asked for.
    --
    -- ONLY THE RESCUE KEY IS SUPPRESSED. An ambient ambulance the player happens
    -- to be driving is not part of anybody's rescue cycle, so it is drawn for
    -- them like any other.
    if d.key == ('r:' .. tostring(BR.State.me.src)) then return end

    if d.gone then dropBlip(d.key) return end
    if not d.x or not d.y then return end

    local B = (R and R.blip) or {}
    local b = blips[d.key]
    if not b or not isTrue(DoesBlipExist(b)) then
        b = AddBlipForCoord(d.x + 0.0, d.y + 0.0, 0.0)
        SetBlipSprite(b, B.sprite or 153)
        SetBlipColour(b, B.colour or 1)
        SetBlipScale(b, B.scale or 0.9)
        -- NOT short range: an ambulance matters most when it is far away and
        -- you are deciding whether to go and meet it.
        SetBlipAsShortRange(b, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(B.label or 'Ambulance')
        EndTextCommandSetBlipName(b)
        blips[d.key] = b
    else
        SetBlipCoords(b, d.x + 0.0, d.y + 0.0, 0.0)
    end
end)

--- Nothing survives the match it belongs to.
---
--- The server takes each blip down as its rescue ends, but a client can lose the
--- match under it -- and a red ambulance icon stranded on the lobby map is
--- exactly the kind of leftover nobody can explain later.
BR.Loop.register(BR.Loop.SLOW, 'rescue.blips', function()
    if BR.State.match.state == BR.MatchState.PLAYING then return end
    if next(blips) == nil then return end
    for key in pairs(blips) do dropBlip(key) end
end)

--- A ride must not survive the thing it belongs to.
---
--- The server ends every rescue it starts, but a client can lose the match under
--- it -- a disconnect and rejoin, a resource restart, the match ending while the
--- ambulance is still driving. None of those produce a RESCUE_END, and all of
--- them would otherwise leave a scripted camera over a detached ped.
BR.Loop.register(BR.Loop.SLOW, 'rescue.sanity', function()
    if not ride or ride.ending then return end
    if BR.State.match.state ~= BR.MatchState.PLAYING
       or BR.State.me.state ~= BR.PlayerState.DBNO then
        print(('[br_core] rescue: tearing down -- match %s, me %s')
            :format(tostring(BR.State.match.state), tostring(BR.State.me.state)))
        cleanup()
    end
end)

AddEventHandler('onClientResourceStop', function(res)
    if res == GetCurrentResourceName() then cleanup() end
end)
