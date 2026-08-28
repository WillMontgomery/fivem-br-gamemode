-- The CPR kit's rescue, client side (#191).
--
-- The one prompt, the fade, the ambulance, the medic, the stretcher, the camera
-- and the drive. The server decides whether any of this may happen and where it
-- goes (server/rescue.lua); this file is everything that can only be done on the
-- machine the player is sitting at.
--
-- ═══ ONE NOTIFICATION. THE WHOLE CYCLE. ═══
--
-- "Use the CPR kit", on the interact key, is THE ONLY THING SHOWN TO THE PLAYER
-- AT ANY POINT IN THIS FEATURE -- and it is drawn as a row of the bleed-out card
-- rather than as a surface of its own (the owner's fix, 2026-08-23; his wording
-- supersedes #191 step 2's "call a medic" -- see setPrompt for both).
-- Not on dispatch, not on arrival, not when the
-- ambulance is destroyed, not when a recovery fires. The owner has been
-- explicit and repeatedly annoyed about invented UI copy, and the discipline is
-- easier to keep than to restore: there is exactly one thing this file tells the
-- interface, and no BR.Native.help, no notify, and no toast anywhere in it.
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

--- The last thing the interface was told, so it is sent on CHANGE rather than
--- per frame -- the card's row is not worth an envelope sixty times a second.
local promptShown = nil

-- ---------------------------------------------------------------------------
-- The prompt
-- ---------------------------------------------------------------------------

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
    -- ═══ THE FIELD IS `id`, NOT `item`, AND THAT WAS THE WHOLE BUG ═══
    --
    -- Owner, 2026-08-23, after three failed attempts at the prompt: /brcpr
    -- printed `1  nil` for a slot holding a CPR kit while slots 2-5 printed
    -- `-`. Two different answers: `-` is an empty slot (they are `false`, see
    -- inventory.lua:43), `nil` is a slot that EXISTS and whose `item` field
    -- does not.
    --
    -- The client mirror keys a slot's identity as `slot.id`. inventory.lua
    -- reads it that way everywhere -- `BR.Config.WeaponById[slot.id]`,
    -- `rec.id ~= slot.id`, `if s.id then` -- and its own report builders
    -- RENAME it on the way out (`item = slot and slot.id or nil`, twice). The
    -- server's entry uses `item`. This file read the server's spelling against
    -- the client's table, so it was nil for every slot, for every item, always.
    --
    -- IT NEVER RETURNED TRUE ONCE. Not for the wrong slot, not for the wrong
    -- selection, not intermittently -- which is why moving the prompt to three
    -- different places changed nothing: the display was correct every time and
    -- was being told there was no kit.
    for i = 1, (BR.Config.Loot.slots or 5) do
        local s = inv.slots[i]
        if type(s) == 'table' and s.id == 'cprkit' then return true end
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

--- Is this player currently on the ambulance?
---
--- READ BY client/dbno.lua, WHICH IS OTHERWISE TRYING TO UNDO THE RIDE. A downed
--- ped is not left alone: dbno.controls re-issues the crawl every frame and
--- stayPut writes the body back to where it fell. Both are correct for a player
--- bleeding out on the floor and both are exactly wrong for one attached to the
--- back of a vehicle -- between them they pinned the owner's ped at the down
--- point while the ambulance drove away with a camera on it (2026-08-28: "My ped
--- stayed in place while the timer continued").
---
--- A FUNCTION RATHER THAN A FLAG ON BR.State, because `ride` is this file's
--- local and the one thing dbno.lua needs to know is whether it exists. Nil-safe
--- at the call site, so load order cannot matter.
--- @return boolean
function BR.Rescue.riding()
    return ride ~= nil
end

--- @param show boolean
local function setPrompt(show)
    if show == promptShown then return end
    promptShown = show

    -- ═══ IT IS A ROW OF THE BLEED-OUT CARD NOW, AND THAT IS THE FIX ═══
    --
    -- Owner, 2026-08-23, after two rounds of an invisible prompt: "Why don't we
    -- just make it part of the bleed out timer card?"
    --
    -- TWO WAYS OF DRAWING IT HAVE FAILED, for opposite reasons, and his idea
    -- removes the thing both of them were fighting rather than dodging it:
    --
    --   1. A NATIVE SPRITE AT THE SHARED PROMPT POSITION (0.5, 0.78). NUI
    --      composites above every DrawSprite the game makes, and
    --      ui-src/src/hud/DbnoOverlay.tsx is an effectively opaque `.panel-hot`
    --      at `bottom-40` sitting right on top of it. No ordering on this side
    --      can put a sprite in front of a browser overlay.
    --
    --   2. THE SAME SPRITE MOVED ONTO THE BODY (ad3ead8). Also invisible:
    --      client/dbno.lua parks the downed camera at GROUND level, so a label
    --      lifted above the ped is behind the ped, or off the top of a shot
    --      that is mostly tarmac. Owner: "Putting a DUI above my ped while the
    --      camera is on the ground is why I can't see it."
    --
    -- INSIDE THE CARD there is no compositing race, because the prompt now IS
    -- the browser overlay that was winning; no camera dependency, because the
    -- card is screen furniture; and no scale-dependent position to tune, which
    -- was the third problem -- it lays out in the same flow as the countdown at
    -- every interface size.
    --
    -- WHAT CROSSES THE BRIDGE IS ONE BIT. The wording lives in the component,
    -- and the key glyph is resolved there from the bindings the interface
    -- already holds (ui/KeyCap.tsx, by command name) -- so no letter is sent
    -- from here and nothing goes stale on a rebind. That is why
    -- BR.Native.keyLabelForCommand and the DUI page are both gone from this
    -- file.
    --
    -- THE WORDING IS THE OWNER'S LATER ONE. "Use the CPR kit" (2026-08-23),
    -- superseding #191 step 2's "call a medic": the medic is an implementation
    -- detail of what the item does, and the ITEM is what the player is holding
    -- and is being asked about. Recorded rather than quietly swapped, because
    -- the issue body still carries the old sentence.
    --
    -- STILL EXACTLY ONE NOTIFICATION, and now it cannot become two: there is no
    -- second surface left to fall back to. The prompt is one row of a card that
    -- is already on screen, or it is nothing.
    BR.Dbno.setCpr(show)
end

-- POLLED, AND NOTHING IS DRAWN FROM HERE ANY MORE. Nothing events this answer:
-- it moves when the player is knocked down, when they pick a kit up, when a
-- ride starts and when the match ends, and none of those call in here. Both
-- `setPrompt` and BR.Dbno.setCpr refuse an unchanged answer, so sixty frames of
-- "yes" still cost exactly one envelope -- which is the same send-on-change
-- discipline this loop has always had, moved one layer down.
BR.Loop.register(BR.Loop.FRAME, 'rescue.prompt', function()
    setPrompt(canCall())
end)

--- WHY IS THE CPR PROMPT NOT THERE?
---
--- Owner, 2026-08-23, on the third failed attempt: "still nothing in the card,
--- still nothing happens when holding E."
---
--- canCall() is six guards and every one of them fails IDENTICALLY from the
--- outside -- no row, no keypress, no error, no print. Reading the file cannot
--- say which fired on a live client, and three rounds were spent guessing at it
--- from the source. So it reports itself, the same way /brprobe ammo and
--- /brboostwhy already do for the same class of problem.
---
--- BOTH SYMPTOMS SHARE THIS FUNCTION. The row and the interact handler are the
--- same answer rendered two ways, which is why "nothing shows AND nothing
--- happens" is one bug rather than two.
RegisterCommand('brcpr', function()
    local ok = true
    local function line(label, pass, detail)
        if not pass then ok = false end
        print(('  %-22s %s%s'):format(
            label, pass and 'ok' or 'NO  <-- this one',
            detail and ('   ' .. detail) or ''))
    end

    print('--- brcpr: why canCall() answers what it does ---')
    line('config loaded',   R ~= nil, 'BR.Config.Rescue')
    line('feature enabled', R ~= nil and R.enabled == true,
         'config/rescue.lua enabled')
    line('not already riding', ride == nil,
         ride and 'a rescue is already running' or nil)
    line('match PLAYING',   BR.State.match.state == BR.MatchState.PLAYING,
         ('state is %s'):format(tostring(BR.State.match.state)))
    line('you are DBNO',    BR.State.me.state == BR.PlayerState.DBNO,
         ('state is %s'):format(tostring(BR.State.me.state)))
    line('mode is solo',    BR.State.match.mode == BR.Mode.SOLO.key,
         ('mode is %s, wanted %s')
             :format(tostring(BR.State.match.mode),
                     tostring(BR.Mode.SOLO.key)))

    local inv = BR.Inv and BR.Inv.local_()
    line('inventory mirror', inv ~= nil and inv.slots ~= nil,
         inv and 'slots present' or 'BR.Inv.local_() gave nothing')
    line('holding a cprkit', holdingKit())

    if inv and inv.slots then
        print('  slots:')
        for i = 1, (BR.Config.Loot.slots or 5) do
            local sl = inv.slots[i]
            print(('    %d  %s'):format(i,
                type(sl) == 'table' and tostring(sl.id) or '-'))
        end
    end

    print(('  => canCall() = %s%s'):format(tostring(canCall()),
        ok and '' or '   (the NO line above is why)'))
end, false)

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

--- Turn on the extras the owner asked for.
---
--- Owner, 2026-08-23: "make sure vehicle extra 1 and 2 are enabled please".
---
--- ═══ THE THIRD ARGUMENT IS `disable`. FALSE TURNS THE EXTRA ON. ═══
---
--- SET_VEHICLE_EXTRA(Vehicle, int extraId, BOOL disable) -- the parameter is
--- named for what it SUPPRESSES, so `false` enables and `true` removes. Reading
--- it as "enabled" and passing `true` is the obvious mistake, it compiles, it
--- runs, and its only symptom is the extras being missing -- which looks exactly
--- like the model not having them.
---
--- THIS COMMENT IS THE POINT OF THIS FUNCTION EXISTING. The call is one line;
--- what it costs to get wrong is a future reader "fixing" `false` into `true`
--- while tidying, and nothing failing loudly when they do.
---
--- `DoesExtraExist` FIRST, because not every ambulance variant carries both, and
--- setting one that does not exist is a silent no-op that would leave this
--- function looking like it worked.
---
--- CALLED AT EVERY CREATION, never once globally: a freshly created vehicle
--- comes up with the MODEL's defaults, so anything set on a previous ambulance
--- is gone. There is one creation site today and this is called from it; a
--- second one must call it too.
--- @param veh integer
local function applyExtras(veh)
    if not veh or not isTrue(DoesEntityExist(veh)) then return end
    for _, id in ipairs((R and R.extras) or {}) do
        if isTrue(DoesExtraExist(veh, id)) then
            SetVehicleExtra(veh, id, false)   -- false = ON. See above.
        end
    end
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

        -- ═══ A REFUSED CREATE RETURNS 0, AND 0 IS TRUTHY ═══
        --
        -- Owner, 2026-08-28: "I spawned a location where the ambulance should
        -- have been and my camera locked to the correct position I think, but
        -- there was no ambulance. I could walk around as normal."
        --
        -- That is this line failing and nothing noticing. CreateVehicle answers
        -- 0 when it is refused; a bare 'not' test on 0 is FALSE in Lua, so every
        -- call below took the handle anyway -- SetEntityAsMissionEntity, the
        -- siren, the door lock, the attach. All of them no-op against entity 0
        -- without erroring, so the camera built at the right coordinates
        -- pointing at nothing and the ride 'started' with no vehicle in it.
        --
        -- EIGHTH TIME THIS FAMILY HAS SHIPPED HERE -- see the bool natives gate
        -- and its baseline. The gate cannot catch this one: CreateVehicle is not
        -- named like a question, which is the blind spot that file documents
        -- about itself.
        --
        -- IT FAILS LOUDLY AND ENDS THE RIDE. Silence was the whole problem: the
        -- deadline eventually delivered him with a 'you have been revived'
        -- toast, which reads like the feature worked. Losing the kit and saying
        -- so in the console beats faking a rescue.
        if not r.veh or r.veh == 0 or not isTrue(DoesEntityExist(r.veh)) then
            print(('[br_core] rescue: CreateVehicle refused (%s) at %.1f %.1f %.1f'
                .. ' -- no ambulance was made, so there is no ride')
                :format(tostring(r.veh), px, py, pz))
            r.veh = nil
            TriggerServerEvent(BR.Net.RESCUE_LOST)
            return
        end

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

        applyExtras(r.veh)

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
        -- ═══ THIS CALL'S SHAPE IS PART OF THE MEASUREMENT ═══
        --
        -- The owner authored the six numbers in config with /brattach, which
        -- attached with bone index 0 and this exact argument tail
        -- (`false, false, false, false, 2, true`) -- itself client/bus.lua:244's
        -- shape. THE OFFSET IS ONLY VALID FOR AN IDENTICAL ATTACH: change the
        -- bone or any of those flags and the body moves somewhere he never
        -- looked at, with nothing to indicate it drifted.
        --
        -- The defaults below are the measured values, not a fallback guess, so a
        -- config that loses its `stretcher` table still puts the ped where he
        -- put it rather than somewhere plausible-looking.
        AttachEntityToEntity(ped, r.veh,
            0,
            S.x or -0.010, S.y or -3.100, S.z or 1.690,
            S.pitch or 0.0, S.roll or 0.0, S.yaw or 1.0,
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

        -- ═══ DO NOT COME BACK UNTIL THE AMBULANCE IS REALLY THERE ═══
        --
        -- Owner, 2026-08-28: "After using the cprkit, let's not fade in the
        -- screen until HasVehicleAssetLoaded = true also."
        --
        -- The fade exists to hide a vehicle appearing out of nothing. It was
        -- lifting on a timer instead, so the one run where the vehicle never
        -- appeared faded up on an empty road and looked like the feature had
        -- worked. Waiting on the thing itself is the difference between hiding
        -- a seam and hiding a failure.
        --
        -- ON THE NATIVE HE NAMED: HasVehicleAssetLoaded pairs with
        -- RequestVehicleAsset and answers for an asset id, not for a spawned
        -- vehicle -- we request none, so on its own it would answer about
        -- nothing. It is asked anyway, guarded, because it costs nothing and is
        -- the right question the day this feature does request one. What
        -- actually gates the fade is the vehicle existing, its model resident,
        -- and the world around it streamed in -- which is what he was asking
        -- for, in the words the natives happen to use.
        --
        -- BOUNDED, AND IT FADES IN REGARDLESS. A fade that never lifts is a
        -- black screen forever, which is worse than an early one. The wait is
        -- an improvement on the timing, never a new way to be stuck.
        local waited = GetGameTimer()
        while GetGameTimer() - waited < 5000 do
            local there = isTrue(DoesEntityExist(r.veh))
                and isTrue(HasCollisionLoadedAroundEntity(r.veh))
            local asset = (not HasVehicleAssetLoaded)
                or isTrue(HasVehicleAssetLoaded(model))
            if there and asset then break end
            if not ride or ride ~= r then return end
            Citizen.Wait(50)
        end

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

--- What the condition bar would say about this vehicle: 0..100.
---
--- THE SAME READING client/fuel.lua's `healthPct` TAKES, deliberately, because
--- it is the one already on screen: the WORST of the three pools over
--- BR.Config.Fuel.healthMax. "The vehicle health should go to 0" (owner,
--- 2026-08-23) has to mean the same thing here as it does on the bar he is
--- looking at when he says it, and two definitions of vehicle health that agree
--- today would not agree for long.
---
--- NOT SHARED WITH fuel.lua's COPY, and that is a judgement rather than an
--- oversight: hoisting it would put a reader of the fuel gauge and a reader of
--- the rescue watchdog on one function, in a file that owns neither, for eight
--- lines of arithmetic. The comment above is the coupling, and it names the
--- file to change with.
---
--- pcall'd per pool for the reason server/fuel.lua pcalls its entity natives:
--- these throw rather than answer on a handle that went stale between the
--- existence test above and this line, and an uncaught throw in a loop callback
--- costs five of them before the band suspends itself.
--- @param veh integer
--- @return number|nil pct   nil if nothing could be read at all
local function vehicleHealthPct(veh)
    local cap = tonumber(BR.Config.Fuel and BR.Config.Fuel.healthMax) or 1000.0
    if cap <= 0.0 then return nil end

    local worst, read = cap, false
    local function pool(getter)
        if type(getter) ~= 'function' then return end
        local ok, v = pcall(getter, veh)
        if not ok then return end
        v = tonumber(v)
        -- v ~= v is the NaN test; a NaN would sail through every comparison
        -- below and poison the answer.
        if v == nil or v ~= v then return end
        read = true
        if v < 0.0 then v = 0.0 end
        if v > cap then v = cap end
        if v < worst then worst = v end
    end

    pool(GetVehicleBodyHealth)
    pool(GetVehicleEngineHealth)
    pool(GetVehiclePetrolTankHealth)

    -- NO READING IS NOT A READING OF ZERO. A build without these natives, or a
    -- handle that answered nothing, must not be reported as a wreck -- that
    -- would eliminate every rescued player on the platform it happened on.
    if not read then return nil end
    return (worst / cap) * 100.0
end

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

    -- ═══ ...AND A FOURTH: A WRECK THAT IS STILL TECHNICALLY DRIVEABLE ═══
    --
    -- Owner, 2026-08-23: "if the ambulance gets in a wreck, even if it doesn't
    -- blow up, the vehicle health should go to 0 if it's bad enough. In this
    -- case the rescue also failed."
    --
    -- The three tests above all wait for the engine to be FINISHED. A head-on
    -- that mangles the ambulance and leaves the engine on its last few points is
    -- none of them: DoesEntityExist is true, IsEntityDead is false, and
    -- IsVehicleDriveable is still true right up until the engine pool hits zero.
    -- What happened next was the worst available answer -- the vehicle crawls or
    -- stops, the SERVER reads that as "not moving", and layer 2 of the recovery
    -- ladder teleports the wreck onto a road and tells it to drive on.
    --
    -- WHY THIS IS THE RIGHT SIDE OF THE WIRE. It is the same report as an
    -- explosion (BR.Net.RESCUE_LOST) and it is trusted for the same reason: the
    -- only thing this message can do is eliminate the player who sent it. A
    -- client that lies here resigns. And it is a CLIENT question by necessity --
    -- the three health pools are client natives, the same wall server/fuel.lua
    -- and client/vehdamage.lua both document.
    --
    -- WHAT IT DOES TO THE LADDER: it SHORT-CIRCUITS layers 2 and 3 for a
    -- crippled-but-existing vehicle, which is the point -- there is nothing
    -- worth re-placing. The ladder's invariant is untouched and slightly
    -- strengthened: this is a new road to ELIMINATION and there is no arrangement
    -- of it that delivers anybody, so "every ambiguous case resolves to
    -- elimination" still holds. A silent or lying client changes nothing either:
    -- the wreck stops moving and layers 2, 3 and 4 run exactly as they did.
    --
    -- THE HEALTH IS THEN ACTUALLY WRITTEN, because he asked for it in as many
    -- words and because it is what everyone ELSE sees. Vehicle health rides the
    -- entity's own sync tree (client/vehdamage.lua's header), so zeroing it here
    -- is what turns the thing sitting in the road into a wreck on every machine
    -- rather than a pristine ambulance that mysteriously stopped.
    --
    -- BODY AND ENGINE, NOT THE PETROL TANK. Taking the tank to zero detonates
    -- the vehicle, and he was explicit that this is the case where it does NOT
    -- blow up. Zeroing these two is enough to put the condition bar on the floor
    -- -- it reads the WORST of the three -- and to make the vehicle undriveable.
    local pct = vehicleHealthPct(r.veh)
    if pct and pct <= (R.wreckedAtPct or 0.0) then
        r.reported = true
        if SetVehicleBodyHealth   then SetVehicleBodyHealth(r.veh, 0.0)   end
        if SetVehicleEngineHealth then SetVehicleEngineHealth(r.veh, 0.0) end
        print(('[br_core] rescue: the ambulance is a wreck (%.0f%%) -- reporting it')
            :format(pct))
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
