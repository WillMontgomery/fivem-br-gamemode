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
--
-- ═══ ...AND ONCE THE AMBULANCE HAS THEM, THERE IS NOT EVEN THAT ═══
--
-- Owner, 2026-08-28: "while in the ambulance, our HUD should be hidden just like
-- in the bus", and "I need you to make the bleed out timer completely go away
-- while in the ambulance. That time should not be relevant anymore once the
-- ambulance takes over".
--
-- So the prompt's own surface leaves with everything else the moment the ride
-- starts, and this file's contribution to the screen goes from ONE ROW to
-- NOTHING AT ALL. It is published as a second bit on the same payload
-- (BR.Dbno.setRiding) and consumed by the rule that already hides the HUD for
-- the Battle Bus -- see the note on setRiding in client/dbno.lua.

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

    -- ═══ ...AND THE OTHER BIT THE CARD NEEDS: AM I ON THE AMBULANCE ═══
    --
    -- Owner, 2026-08-28: "I need you to make the bleed out timer completely go
    -- away while in the ambulance" and "while in the ambulance, our HUD should
    -- be hidden just like in the bus". One flag serves both, because the card
    -- is part of the HUD -- see BR.Dbno.setRiding for the whole argument.
    --
    -- POLLED FROM THE SAME PLACE AND FOR THE SAME REASON THE PROMPT IS. Nothing
    -- events `ride` going away: it is nilled by cleanup(), which is reached from
    -- a delivery, a destroyed ambulance, the match ending under a ride and the
    -- sanity sweep. A flag pushed from RESCUE_BEGIN/RESCUE_END alone would
    -- survive the two of those that are not events, and a HUD that never came
    -- back is a worse bug than one that never went away. Asking a local every
    -- frame cannot miss a path.
    --
    -- setRiding refuses an unchanged answer, so sixty frames of a ride still
    -- cost exactly one envelope.
    BR.Dbno.setRiding(ride ~= nil)
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
--- Take the destination waypoint down.
---
--- CALLED FROM cleanup SO EVERY ENDING GETS IT -- delivered, destroyed, lost,
--- match over. A waypoint left behind is a route line to a car park the player
--- has already been driven to, and it would outlive the match.
--- BOTH SLOTS COME DOWN, and the second one is the reason this is not one line.
--- The multi-route is drawn into a different eGpsSlotType from the waypoint --
--- DeleteWaypoint does not touch it -- so a ride that ended would leave a line
--- on the minimap pointing at a car park nobody is being driven to, for the rest
--- of the match. Cleared unconditionally rather than behind a flag:
--- ClearGpsMultiRoute on a slot with nothing in it is a no-op, and the flag
--- would be the thing that goes stale.
local function clearWaypoint()
    if isTrue(IsWaypointActive()) then DeleteWaypoint() end
    if ClearGpsMultiRoute then
        SetGpsMultiRouteRender(false)
        ClearGpsMultiRoute()
    end
end

--- @param keepVehicle boolean|nil  leave the parked ambulance and its medic in
---                                 the world instead of deleting them
-- Forward-declared: cleanup parks a kept ambulance and is defined above park,
-- because cleanup is the single exit every ending routes through and park is
-- the scene it leaves behind.
local park

local function cleanup(keepVehicle)
    local r = ride

    -- ═══ AN AMBULANCE LEFT BEHIND IS PARKED, WHATEVER ENDED THE RIDE ═══
    --
    -- Owner, 2026-08-28: "once the timer ran out the ambulance did not park. He
    -- just kept driving".
    --
    -- park() was reached from ONE place -- the arrival watch -- so it described
    -- arriving rather than ending. Every other way a ride finishes with the van
    -- still standing (the deadline expiring on a drive that was going fine, the
    -- match tearing down, a sanity sweep) left a driver mid-task and a medic
    -- who never got out: doors shut, lights off, still driving, with the player
    -- already gone. The one thing the parked scene exists to say -- somebody got
    -- out of this -- was true only on the happy path.
    --
    -- HERE BECAUSE THIS IS THE SINGLE EXIT. Putting it beside the deadline case
    -- would have fixed the reported symptom and left the other two, which is how
    -- this feature has been going. `keepVehicle` is already exactly the question
    -- "is the ambulance staying?", so parking is what that answer means.
    --
    -- park() is idempotent by inspection -- halting a stopped van, unlocking an
    -- unlocked door and opening an open one are all no-ops -- so arriving and
    -- then ending does not double up.
    if keepVehicle and r and r.veh and isTrue(DoesEntityExist(r.veh)) then
        park(r, 'the ride ended with the ambulance still here')
    end

    ride = nil

    -- BEFORE the early return: a ride torn down with no record still set a
    -- waypoint, and a route line to a car park nobody is being driven to would
    -- outlive the match.
    clearWaypoint()

    if not r then return end

    -- ═══ THE STREAMING FOCUS IS NOT LEFT 800 METRES AWAY ═══
    --
    -- `board` moves it to the spawn point so the server's ambulance clones to
    -- this machine, and clears it again once the player is attached to the
    -- vehicle. That is the ordinary path. THIS is the one that cannot be
    -- forgotten: a boarding that is superseded mid-assembly, a match that ends
    -- under a ride, a resource stop, the sanity sweep -- none of them run the
    -- line in `board`, and a client whose world streams in around a car park it
    -- is not standing in is a worse bug than a rescue that failed.
    --
    -- GUARDED ON THE FLAG rather than called unconditionally, because focus is
    -- shared: client/natives.lua's spectate holds it too, and a rescue teardown
    -- must not take a spectator's world away.
    if r.focused and ClearFocus then
        ClearFocus()
        r.focused = nil
    end

    local ped = PlayerPedId()
    DetachEntity(ped, true, true)
    -- ...AND THE STRETCHER POSE GOES WITH THE STRETCHER.
    --
    -- THE RACE THIS CLOSES IS REAL AND ITS SYMPTOM IS ABSURD. A delivery
    -- revives the player on the server, so DBNO_SET (`downed = false`) and
    -- RESCUE_END are two messages with no ordering between them -- and the
    -- first of them runs client/dbno.lua's `leaveDowned`, which clears the
    -- ped's tasks. If that lands FIRST, `rescue.pose` below is still running
    -- against a ride that has not been torn down yet and puts the sunbathe
    -- straight back on. The player is then detached, teleported behind the
    -- ambulance and left lying in the road sunbathing, on their feet
    -- everywhere except the animation.
    --
    -- Cleared HERE because this is the one place every ending passes through,
    -- and every ending that matters is behind a fade -- so the clear is never
    -- seen, whichever of the two messages won. `rescue.pose` stands down on
    -- `ride.ending` as well, which closes the same window from the other side;
    -- this is the one that does not depend on RESCUE_END having arrived.
    ClearPedTasks(ped)
    SetEntityVisible(ped, true, false)
    FreezeEntityPosition(ped, false)
    SetEntityCollision(ped, true, true)

    if r.cam and isTrue(DoesCamExist(r.cam)) then
        RenderScriptCams(false, false, 0, true, true)
        DestroyCam(r.cam, false)
    end

    -- ═══ A DELIVERED RIDE LEAVES ITS AMBULANCE STANDING ═══
    --
    -- Owner, 2026-08-28: "doors open, lights on, but nobody inside... so players
    -- can take the ambulance".
    --
    -- DELETING IT HERE WOULD MAKE THAT WHOLE SCENE POINTLESS. `park` unlocks the
    -- doors, opens the rear two, turns the dome light on and sends the medic
    -- walking -- and every one of those lasts about a second and a half before
    -- this function runs and the vehicle stops existing. The player would fade
    -- in behind an ambulance that is not there.
    --
    -- RELEASED RATHER THAN DELETED, AND THE TWO ENTITIES ARE RELEASED TO
    -- DIFFERENT OWNERS. SetEntityAsNoLongerNeeded is the documented giving-up of
    -- a claim -- "entities marked as no longer needed will be deleted as the
    -- engine sees fit" -- and what happens next depends on who made the thing:
    --
    --   THE MEDIC is local to this machine, so the population manager reclaims
    --   him once nobody is near, exactly as it does every ambient ped.
    --
    --   THE AMBULANCE is the SERVER's, and this call only drops this client's
    --   mission claim on it. It goes on existing for everybody, which is the
    --   whole of "so players can take the ambulance". server/rescue.lua sweeps
    --   the abandoned ones when the match ends, because a server-created entity
    --   is not culled by anybody's population manager and would otherwise
    --   outlive the match it belongs to.
    --
    -- ONLY ON A DELIVERY. Destroyed, out of time, match over, resource stopping
    -- -- every other ending still deletes, because on none of them is there a
    -- parked ambulance worth leaving and on most of them the player is dead.
    if keepVehicle then
        if r.driver and isTrue(DoesEntityExist(r.driver)) then
            SetEntityAsNoLongerNeeded(r.driver)
        end
        if r.veh and isTrue(DoesEntityExist(r.veh)) then
            SetEntityAsNoLongerNeeded(r.veh)
        end
        return
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

-- ---------------------------------------------------------------------------
-- The pose
-- ---------------------------------------------------------------------------

--- The clip the stretcher offset was measured against.
---
--- Read from config so the six numbers and the seventh fact live together --
--- see the note beside `stretcher` in config/rescue.lua. The defaults are the
--- measured pose rather than a plausible fallback, for the same reason the
--- offsets' defaults are: a config that loses its `stretcher` table must still
--- put the body where the owner put it.
local POSE_DICT = ((R and R.stretcher and R.stretcher.pose) or {}).dict
    or 'amb@world_human_sunbathe@male@back@base'
local POSE_ANIM = ((R and R.stretcher and R.stretcher.pose) or {}).anim
    or 'base'

--- Request the dictionary and wait a beat for it.
---
--- DoesAnimDictExist FIRST, because requesting a name the game has never heard
--- of is a streaming request that can never complete -- the whole wait would be
--- paid for nothing. Lifted from client/attachtune.lua's loadDict, which lifted
--- it from client/dbno.lua.
---
--- YIELDS, so it may only be called from `board`'s thread. The re-assert below
--- deliberately does not use it.
--- @return boolean
local function loadPoseDict()
    if isTrue(HasAnimDictLoaded(POSE_DICT)) then return true end
    if DoesAnimDictExist and not isTrue(DoesAnimDictExist(POSE_DICT)) then
        return false
    end
    RequestAnimDict(POSE_DICT)
    local deadline = GetGameTimer() + 1000
    while not isTrue(HasAnimDictLoaded(POSE_DICT)) and GetGameTimer() < deadline do
        Citizen.Wait(50)
    end
    return isTrue(HasAnimDictLoaded(POSE_DICT))
end

--- Put the body in the pose, if the dictionary is here.
---
--- ═══ THE ARGUMENT TAIL IS PART OF THE MEASUREMENT, LIKE THE ATTACH'S ═══
---
--- `8.0, -8.0, -1, 1, 0.0, false, false, false` is exactly the call
--- client/attachtune.lua makes -- the tool the owner authored the offsets with.
--- Flag 1 is LOOPING and the -1 duration is "until something stops it", which
--- together are what make this a pose rather than an animation that plays once
--- and leaves the ped in whatever the engine falls back to. The three `false`s
--- are the position locks: an attached ped's position is the ATTACH's business,
--- and locking it here would be a second writer for the same matrix.
---
--- NON-BLOCKING, unlike loadPoseDict: this is called from a loop band, where a
--- Citizen.Wait would stall every other callback in it. A dictionary that is
--- somehow not resident is re-requested and picked up on a later pass.
--- @param ped integer
--- @return boolean posed
local function poseOnStretcher(ped)
    if not isTrue(HasAnimDictLoaded(POSE_DICT)) then
        RequestAnimDict(POSE_DICT)
        return false
    end
    TaskPlayAnim(ped, POSE_DICT, POSE_ANIM, 8.0, -8.0, -1, 1, 0.0,
                 false, false, false)
    return true
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

--- What the drive path actually looks like, in one line.
---
--- ═══ THREE FAULTS HAVE BEEN WEARING THE SAME SYMPTOM ═══
---
--- A stationary ambulance is one of: never tasked; tasked and the task dropped;
--- or tasked, running, and going nowhere because every write this file makes is
--- landing on an entity this machine does not own. From the outside all three
--- are a van that does not move, and the server can only ever report the van.
--- These are the values that separate them, and they are PRINTED RATHER THAN
--- ACTED ON -- the same discipline that ended the netId round.
---
--- `owner` IS THE ONE THAT MATTERS, and it is the field this feature has never
--- had. A vehicle from CreateVehicleServerSetter is created ORPHANED -- Cfx's
--- own migration guide says exactly that, and says NETWORK_GET_ENTITY_OWNER
--- answers -1 for as long as it stays that way -- and an orphaned entity has no
--- owning client for a takeover to take it FROM. So:
---
---   owner = -1                     still orphaned; the control request had
---                                  nobody to ask, which is not a refusal
---   owner = some other player      it migrated, just not to us
---   owner = us, control = false    a third thing, and a new one
---
--- @param r table
--- @param when string   which moment this is, for the log
local function reportDrive(r, when)
    if not r or not r.veh or not isTrue(DoesEntityExist(r.veh)) then return end
    local veh = r.veh

    local owner = -1
    if NetworkGetEntityOwner then
        owner = math.tointeger(tonumber(NetworkGetEntityOwner(veh)) or -1) or -1
    end

    -- GET_ACTIVE_VEHICLE_MISSION_TYPE is the AI drive task from the VEHICLE's
    -- side rather than the ped's, which is what makes it the right question
    -- here: it answers even when the driver is a ped nobody else can see.
    -- 0 is MISSION_NONE, so "tasked and dropped" reads as 0 while "never
    -- tasked" reads as 0 too -- the pairing with driverInSeat is what splits
    -- those, and the pairing with control is what splits both from the third.
    local mission = -1
    if GetActiveVehicleMissionType then
        mission = math.tointeger(tonumber(GetActiveVehicleMissionType(veh)) or -1) or -1
    end

    local netd = 'n/a'
    if NetworkGetEntityIsNetworked then
        netd = tostring(isTrue(NetworkGetEntityIsNetworked(veh)))
    end

    local seated = false
    if r.driver and isTrue(DoesEntityExist(r.driver)) then
        seated = (GetPedInVehicleSeat(veh, -1) == r.driver)
    end

    print(('[br_core] rescue: drive state (%s) -- control=%s owner=%d me=%d '
           .. 'networked=%s driverInSeat=%s mission=%d speed=%.2f')
        :format(tostring(when),
                tostring(isTrue(NetworkHasControlOfEntity(veh))),
                owner, PlayerId(), netd, tostring(seated),
                mission, GetEntitySpeed(veh)))
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
    -- ...BUT NEVER ONCE IT HAS PARKED. The only caller left that could reach a
    -- finished ride is RESCUE_PLACE, and the server can still send one: a client
    -- whose RESCUE_ARRIVED is refused (`everMoved` false) stays in `live`, and
    -- its stalled clock is now genuinely stalled because the ambulance really
    -- has stopped. Re-tasking there would undo the whole parked scene -- doors
    -- open, dome light on, no driver -- and send an empty ambulance off again.
    if r.parked then return end

    SetDriverAbility(r.driver, R.driverAbility or 0.6)
    SetDriverAggressiveness(r.driver, R.driverAggression or 0.8)

    TaskVehicleDriveToCoord(r.driver, r.veh,
        r.dest.x, r.dest.y, r.dest.z,
        R.driveSpeed or 30.0,
        0,                                  -- no special driving mode
        GetEntityModel(r.veh),
        R.driveStyle or 786485,
        -- STOP RANGE, AND IT WAS 4.0 -- WHICH IS THE CIRCLING FROM THE ENGINE'S
        -- SIDE. The native's own documentation names small values as the failure
        -- mode ("20.0 works fine"), and a driver told to stop within four metres
        -- of a car park it can only reach within twenty simply never stops. It
        -- is BR.Config.Rescue.arriveM now, so the AI's idea of having arrived
        -- and this file's cannot drift apart.
        R.arriveM or 50.0,
        true)
    SetDriveTaskDrivingStyle(r.driver, R.driveStyle or 786485)
    SetDriveTaskMaxCruiseSpeed(r.driver, R.driveSpeed or 30.0)

    -- ═══ AFTER THE TASK, WHICH IS WHERE IT WAS NOT ═══
    --
    -- Owner, 2026-08-28: "are we using SetPedKeepTask(driver, true) anywhere for
    -- the ambulance driver by chance?" We were, and it ran BEFORE the task.
    --
    -- WHAT I COULD ESTABLISH, AND WHAT I COULD NOT. SET_PED_KEEP_TASK sets a
    -- persistent flag on the PED rather than a property of a task, and a flag
    -- read at cleanup time should not care which side of the task it was set
    -- on -- so the honest answer is that I could NOT show the order matters on
    -- this build, and this is not being claimed as the fix. It moves because
    -- every working reference in the survey (es_taxi and the rest) orders it
    -- this way, because the flag is about making an EXISTING task persist, and
    -- because it costs one line to remove a variable from a path that has cost
    -- seven rounds. If it turns out to matter, it now matches the references.
    SetPedKeepTask(r.driver, true)

    -- AND THEN SAY WHAT HAPPENED, ONE SECOND LATER. Long enough for the task to
    -- have been picked up and for a migration to have taken it away again;
    -- short enough to land in the log before the server's 5s stall clock fires,
    -- so the two can be read against each other.
    Citizen.CreateThread(function()
        Citizen.Wait(1000)
        if ride ~= r then return end
        reportDrive(r, 'one second after tasking')
    end)
end

--- Stop here, open it up, and let the medic walk away from it.
---
--- ═══ THE OWNER DESIGNED THIS RATHER THAN ASKING FOR A BETTER RADIUS ═══
---
--- 2026-08-28: "If it can't arrive, I don't want it to circle. I want it to park
--- as close as it can get, even if that's on the road. And remember we want the
--- back left and right doors open when it parks. See if you can turn the dome
--- light on too so it's obvious someone got out of it - doors open, lights on,
--- but nobody inside. Then you can make the driver get out and run around
--- aimlessly so players can take the ambulance"
---
--- ...and, in the same breath: "That also means the doors need to unlock before
--- the driver gets out."
---
--- THE ORDER OF THESE FIVE STEPS IS THE INSTRUCTION. Unlocking is not a
--- flourish at the end: it comes before the medic is told to leave, because a
--- ped exiting a vehicle locked against entry either fails silently or strands
--- him in the seat -- and because the scene it leaves behind is a lie
--- otherwise. Doors open, dome light on, nobody inside, and nobody can get in.
---
--- CALLED EXACTLY ONCE PER RIDE, latched on `r.parked`, which `taskDrive` also
--- reads: a re-place arriving after this would send an empty ambulance off again
--- with its doors hanging open.
--- @param r table
--- @param why string   how it got here, for the log
function park(r, why)
    if r.parked then return end
    r.parked = true
    if not r.veh or not isTrue(DoesEntityExist(r.veh)) then return end

    -- 1. THE DRIVE ENDS, THEN THE VEHICLE STOPS, AND BOTH ARE NEEDED.
    -- ClearPedTasks stops the driver and leaves a heavy van coasting;
    -- BringVehicleToHalt stops the van and lapses after its hold, by which time
    -- there must be no task left to re-accelerate it. Clearing first is what
    -- makes the halt final rather than a pause.
    if r.driver and isTrue(DoesEntityExist(r.driver)) then
        ClearPedTasks(r.driver)
    end
    BringVehicleToHalt(r.veh, R.haltDistM or 8.0, R.haltHoldS or 6, false)

    -- 2. UNLOCK, BEFORE ANYTHING ELSE TOUCHES A DOOR.
    SetVehicleDoorsLocked(r.veh, R.unlockedState or 1)

    -- 3. Rear doors open (#191 step 7, and the owner again). The siren is NOT
    -- turned off -- he asked for it on the whole time, and "the whole time"
    -- includes this moment.
    SetVehicleDoorOpen(r.veh, 2, false, false)
    SetVehicleDoorOpen(r.veh, 3, false, false)
    -- ...and the dome light, which is the detail that makes the picture read.
    -- Guarded on the native rather than assumed: it is undocumented beyond its
    -- signature, and a build without it must still park the ambulance.
    if R.interiorLight ~= false and SetVehicleInteriorlight then
        SetVehicleInteriorlight(r.veh, true)
    end

    -- 4. THE MEDIC LEAVES AND DOES NOT COME BACK.
    --
    -- Mortal and unblocked first: he was invincible and deaf to events because
    -- an NPC shot out of the driver's seat mid-rescue would strand the ambulance
    -- in the recovery machinery. The rescue is over, so both come off -- an
    -- invincible paramedic wandering Los Santos for the rest of the match is a
    -- thing nobody could explain, and a ped blocked from non-temporary events
    -- is a poor candidate for ambient behaviour.
    if r.driver and isTrue(DoesEntityExist(r.driver)) then
        local medic = r.driver
        SetEntityInvincible(medic, false)
        SetBlockingOfNonTemporaryEvents(medic, false)
        SetPedCanBeDraggedOut(medic, true)
        SetPedKeepTask(medic, true)
        TaskLeaveVehicle(medic, r.veh, R.driverExitFlag or 256)

        -- THE WANDER HAS TO FOLLOW THE EXIT, NOT REPLACE IT. Both are tasks and
        -- the second one issued wins, so wandering him on this line would
        -- cancel the exit and leave him sitting in the ambulance behaving
        -- ambiently. client/vehrefuse.lua learned the same thing about this
        -- native from the other end: it is queued, it takes frames, and it can
        -- be refused outright -- so this waits for him to actually be out, and
        -- gives up on a bound rather than looping forever.
        --
        -- WANDER RATHER THAN A FLEE TASK. "Run around aimlessly" is the effect
        -- and a flee is not it: a fleeing ped runs in one direction and is over
        -- the horizon in fifteen seconds, which empties the scene the doors and
        -- the light were staged for. TaskWanderStandard(ped, 10.0, 10) is the
        -- documented "walk anywhere without a duration".
        Citizen.CreateThread(function()
            local t0 = GetGameTimer()
            while GetGameTimer() - t0 < 3000 do
                if not isTrue(DoesEntityExist(medic)) then return end
                if not isTrue(IsPedInAnyVehicle(medic, false)) then break end
                Citizen.Wait(100)
            end
            if not isTrue(DoesEntityExist(medic)) then return end
            TaskWanderStandard(medic, 10.0, 10)
        end)
    end

    print(('[br_core] rescue: parked at %s -- %s')
        :format(tostring(r.dest and r.dest.id), tostring(why)))
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

        -- ═══ THE SERVER PLACED THE AMBULANCE; THIS IS WHERE TO GO AND LOOK ═══
        --
        -- `freeSpaceNear` USED TO SITE THE VEHICLE and cannot any more: the
        -- vehicle is created on the server, which has no IsPositionOccupied to
        -- ask. So the surveyed point is where it is, exactly, and the ring-walk
        -- now only sites the MEDIC -- a position that lasts until he is put in
        -- the driver's seat two dozen lines below.
        --
        -- WHAT THAT COSTS, NAMED: two rescues converging on one station can now
        -- overlap where they used to step aside (#191 step 7). It is behind the
        -- fade, the engine resolves the intersection by pushing one out, and
        -- only a client can answer the question that would prevent it.
        local p = d.pickup
        local px, py, pz = p.x, p.y, p.z
        local mx, my, mz = freeSpaceNear(p.x, p.y, p.z)

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
        -- ═══ THE CLIENT ADOPTS THE SERVER'S AMBULANCE, AND MOVES ITS STREAMING
        --     FOCUS ACROSS THE MAP TO GO AND MEET IT ═══
        --
        -- Owner, 2026-08-28: "Other players have to be able to see the
        -- ambulance. Local is not acceptable." Only a networked entity exists on
        -- anybody else's machine, so local is off the table and the two failures
        -- that put it there have to be answered rather than avoided.
        --
        -- THEY BOTH HAVE CAUSES, FROM THE PLATFORM'S OWN SOURCE:
        --
        --   1. CLIENT-SIDE networked CreateVehicle was refused by
        --      sv_entityLockdown relaxed -- a client script's entity is
        --      POPTYPE_MISSION with no creation token, and ValidateEntity admits
        --      only POPTYPE_RANDOM_* or a token carrying a scriptGuid. That is a
        --      permanent dead end and nothing here goes near it.
        --
        --   2. SERVER-SIDE CreateVehicleServerSetter worked and the clone never
        --      arrived. OneSync relevancy for an empty vehicle is pure 2D
        --      distance with a 424-unit radius; the ambulance is built at a
        --      surveyed point averaging 825m from where the player fell, and
        --      81.7% of the map is further than 424m from the nearest one. The
        --      net id was correct and NetworkDoesNetworkIdExist answered false
        --      honestly for the full five seconds.
        --
        -- ═══ (2) IS FIXED ON THE SERVER, NOT HERE. THE FOCUS BELOW IS NOT THE
        --     FIX AND MUST NOT BE MISTAKEN FOR IT ═══
        --
        -- THE FIX IS SetEntityDistanceCullingRadius, in server/rescue.lua, which
        -- writes the very field the 424 default lives in. Relevancy is computed
        -- entirely server-side from the player's SYNCED PED POSITION and the
        -- CPlayerCameraDataNode sync node -- see ServerGameState.cpp's
        -- `isRelevantViaPos` and `GetPlayerFocusPos`. SET_FOCUS_POS_AND_VEL
        -- writes NEITHER of those: its own documentation is "override the area
        -- where the camera will render the terrain", and it is a STREAMING
        -- native, client-side, that the server never reads.
        --
        -- IT IS CALLED ANYWAY, FOR THE JOB IT REALLY DOES. The ambulance is up
        -- to 2.4km away and the fade below will not lift until
        -- HasCollisionLoadedAroundEntity answers for it -- so the world at the
        -- pickup point has to stream in either way, and pulling the streaming
        -- volume there is exactly how that is hurried along. It is the same call
        -- client/natives.lua's spectate makes to load the world around a target
        -- across the map, for the same reason, and no other.
        --
        -- BEHIND THE FADE, WHICH IS ALREADY DOWN. Moving the focus streams the
        -- player's own surroundings out while it is elsewhere; the screen is
        -- black across the whole of this window, so the visible cost is paid by
        -- a fade that was already there for the vehicle appearing out of nothing.
        --
        -- AND IT IS GIVEN BACK ON EVERY PATH. `ClearFocus` runs after the attach
        -- (by which point the player IS at the ambulance, so ordinary focus is
        -- correct again) and from `cleanup`, which every ending reaches. A client
        -- left with its streaming focus 800m away is a far worse bug than the one
        -- this helps with, so it is not defended by remembering to call it here.
        local netId = tonumber(d.netId)
        if not netId then
            print('[br_core] rescue: the server sent no ambulance id')
            TriggerServerEvent(BR.Net.RESCUE_LOST)
            return
        end

        local me0 = GetEntityCoords(PlayerPedId())
        local away = BR.Dist(me0.x, me0.y, px, py)
        SetFocusPosAndVel(px + 0.0, py + 0.0, pz + 0.0, 0.0, 0.0, 0.0)
        r.focused = true

        -- THE DOCUMENTED SPELLING FIRST. NetworkDoesEntityExistWithNetworkId is
        -- the one Cfx's reference names and declares BOOL;
        -- NetworkDoesNetworkIdExist is a different native whose declaration
        -- carries no description and no documented return, and it is what the
        -- failed round asked. Both are read through isTrue either way -- a BOOL
        -- native may answer 1, and 0 is truthy in Lua.
        local existsFn = NetworkDoesEntityExistWithNetworkId
                      or NetworkDoesNetworkIdExist

        local tv, sawId = GetGameTimer(), false
        repeat
            -- SUPERSEDED. Give the focus back only if THIS record still holds
            -- it: `ride ~= r` means cleanup has already run against this record
            -- and a second rescue may have started and moved the focus to its
            -- own pickup point, and a stale thread taking that away would strand
            -- the live ride's world unstreamed.
            if not ride or ride ~= r then
                if r.focused then ClearFocus() r.focused = nil end
                return
            end
            if isTrue(existsFn(netId)) then
                sawId = true
                r.veh = NetworkGetEntityFromNetworkId(netId)
            end
            if r.veh and r.veh ~= 0 and isTrue(DoesEntityExist(r.veh)) then break end
            r.veh = nil
            Citizen.Wait(50)
        until GetGameTimer() - tv > (R.adoptMs or 10000)

        -- ═══ AND IF IT STILL DOES NOT ARRIVE, IT SAYS WHICH HALF FAILED ═══
        --
        -- Six rounds have been spent on this feature and the last two were spent
        -- because "no ambulance" and "an ambulance nobody could see" printed the
        -- same nothing. `sawId` splits the two remaining failures: the net id
        -- resolving and then not producing an entity is a DIFFERENT fault from
        -- the id never resolving at all, and only the second one is scope.
        if not r.veh then
            print(('[br_core] rescue: net id %d never became an ambulance here '
                   .. '(id seen: %s, spawn was %.0fm away at %.1f %.1f, '
                   .. 'waited %dms)')
                :format(netId, tostring(sawId), away, px, py,
                        GetGameTimer() - tv))
            ClearFocus()
            r.focused = nil
            TriggerServerEvent(BR.Net.RESCUE_LOST)
            return
        end
        SetModelAsNoLongerNeeded(model)

        -- ═══ CONTROL, BECAUSE EVERYTHING BELOW WRITES TO SOMEBODY ELSE'S
        --     ENTITY ═══
        --
        -- The server made this vehicle, so this machine does not own it by
        -- construction. Every line after this one -- the mods, the siren, the
        -- lock, the driver task, and later the doors and the halt -- is a write,
        -- and a write to an entity you do not control is a local-only change
        -- that the owner's next sync undoes. Requested in a bounded loop because
        -- the native ASKS: it returns whether the request was accepted, not
        -- whether control has arrived, so one call is a coin flip.
        --
        -- NOT FATAL IF IT NEVER COMES. An ambulance nobody can task is a rescue
        -- the deadline resolves, which is a worse ride and not a broken client --
        -- and the same is true of an ambulance whose control migrates mid-drive.
        -- It is logged rather than acted on.
        local tc = GetGameTimer()
        while not isTrue(NetworkHasControlOfEntity(r.veh))
              and GetGameTimer() - tc < (R.controlMs or 3000) do
            NetworkRequestControlOfEntity(r.veh)
            Citizen.Wait(50)
        end
        -- LATCHED, so the watcher below knows whether it is reporting an
        -- arrival or just agreeing with a gate that already passed.
        r.hadControl = isTrue(NetworkHasControlOfEntity(r.veh))
        if not r.hadControl then
            print(('[br_core] rescue: no control of ambulance %d after %dms -- '
                   .. 'the drive may not take')
                :format(r.veh, GetGameTimer() - tc))
        end

        -- AND WHO DOES OWN IT. The line above says control was not obtained; it
        -- has never said what the entity's ownership actually IS, which is the
        -- difference between "refused" and "there was nobody to ask". See
        -- reportDrive.
        reportDrive(r, 'at the control gate')

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

        -- ═══ DOORS LOCKED SO NO OTHER PLAYER CAN GET IN (#191 step 4) -- AND
        --     THE VALUE THAT WAS HERE DID NOT DO THAT ═══
        --
        -- It was `4`, with a comment calling it "locked for everyone including
        -- the player". R*'s eVehicleLockState says otherwise: 4 is
        -- VEHICLELOCK_LOCKED_PLAYER_INSIDE -- "locked once a player enters,
        -- preventing others from entering" -- and the condition it waits for
        -- NEVER HAPPENS HERE. The rescued player is ATTACHED to the stretcher,
        -- not seated; no player ever enters this vehicle; so the lock never
        -- armed and the ambulance drove the whole way unlocked.
        --
        -- 2 is VEHICLELOCK_LOCKED, "preventing entry by players and NPCs",
        -- which is the sentence the issue asked for. client/vehrefuse.lua
        -- reached the same value for the same job and its header carries the
        -- argument for it over 10 (CANNOT_ENTER).
        --
        -- IT IS STILL NOT WHAT KEEPS THE PASSENGER IN, and that is worth being
        -- precise about: THE PLAYER CANNOT EXIT BECAUSE THEY ARE NOT IN A SEAT.
        -- An attached ped has no vehicle to leave, so there is no exit control
        -- to fight and no "get out" state machine to lose a race against.
        --
        -- IT COMES OFF WHEN THE AMBULANCE PARKS -- see `park`, which unlocks
        -- before it opens a door or tells the medic to get out.
        SetVehicleDoorsLocked(r.veh, R.lockedState or 2)

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
            -- ═══ THE MEDIC STAYS LOCAL, AND IT IS NOT A CHOICE ═══
            --
            -- The vehicle went back to the server because only a networked one
            -- can be seen, shot and taken by other players. The medic cannot
            -- follow it, and the reason is that THERE IS NO PED SERVER SETTER:
            -- citizenfx/fivem's ext/native-decls/server/ holds exactly one
            -- creation native, CreateVehicleServerSetter, and citizenfx/fivem
            -- #2787 ("Implement Server Setters; RPC are broken") is still open.
            --
            -- THE TWO ROUTES THAT REMAIN ARE BOTH CLOSED HERE:
            --
            --   * CLIENT-SIDE networked CreatePed is POPTYPE_MISSION, which
            --     sv_entityLockdown relaxed refuses outright -- the same wall
            --     that killed the client-side vehicle, and the failure that was
            --     already queued behind it.
            --   * SERVER-SIDE CreatePed is an RPC native, and citizenfx/fivem
            --     #1407 is closed with the rule server/vehicles.lua already
            --     obeys: RPC creation is inherently incompatible with routing
            --     buckets. THIS GAMEMODE RUNS EVERY MATCH IN ONE. The ped would
            --     land in the bucket of whichever client the engine picked to
            --     build it, which is a coin flip on a feature that has already
            --     cost six rounds.
            --
            -- WHAT IT COSTS IS EXACTLY ONE THING, AND IT IS COSMETIC: other
            -- players see the ambulance and can find it, shoot it, be run over
            -- by it and take it when it parks -- but they see it DRIVING
            -- ITSELF, because the ped at the wheel exists only on this machine.
            -- The vehicle's own visibility is not affected: it is relevant to
            -- every client in the match by its culling radius rather than by
            -- having an occupant the server can see.
            r.driver = CreatePed(4, pedModel, mx, my, mz, p.heading or 0.0,
                                 false, false)
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

        -- ═══ AND THE STREAMING FOCUS COMES BACK, HERE, BECAUSE HERE IS WHERE IT
        --     STOPS BEING A LIE ═══
        --
        -- The focus was moved to the spawn point so an ambulance 800m away would
        -- clone to this machine at all. The player's ped is now ATTACHED to that
        -- ambulance, so the player IS at the spawn point -- ordinary focus and
        -- the moved focus are the same place, and from the next metre the
        -- ambulance drives, only ordinary focus follows it.
        --
        -- ALSO CLEARED BY `cleanup`, which every ending reaches. This call is
        -- the ordinary path; that one is the guarantee.
        ClearFocus()
        r.focused = nil

        -- ═══ AND THE POSE, WHICH THE OFFSET IS ONLY CORRECT FOR ═══
        --
        -- Owner, 2026-08-28: "please enforce the ped emote in the ambulance as
        -- we discussed. It should be sunbathe".
        --
        -- WHAT WAS ON THE STRETCHER BEFORE THIS. Not nothing -- the CRAWL. A
        -- player reaches this line already downed, and client/dbno.lua has been
        -- re-issuing `move_injured_ground` at them every frame since the knock;
        -- it stands down for the ride (c0016d6) but does not undo its last task,
        -- so the clip that was playing kept playing. The owner measured
        -- (-0.010, -3.100, 1.690) against a body lying flat on its back, and a
        -- body curled on its front at the same offset is not at the offset he
        -- approved. THIS IS THE FIX, not a flourish on top of one.
        --
        -- AFTER THE ATTACH AND NOT BEFORE. TaskPlayAnim on a free ped, then
        -- attaching it, is two writes to the same matrix in the order that lets
        -- the first one lose; attachtune.lua's poseAndHold does the attach first
        -- for the same reason, and its numbers are the ones in the config.
        --
        -- LOADED HERE, BEHIND THE FADE. The dictionary is a streaming request
        -- and this thread is already the one place in the feature that can
        -- afford to wait for one -- the screen is black until the last block of
        -- this function lifts it.
        loadPoseDict()
        if not poseOnStretcher(ped) then
            -- Said once, and nothing is shown to the player: the ride still
            -- works, it just does not look right, and #191's one-notification
            -- rule does not bend for a cosmetic failure.
            print(('[br_core] rescue: the stretcher pose (%s) never loaded')
                :format(POSE_DICT))
        end

        -- ═══ THE CAMERA ═══
        --
        -- UNATTACHED, repositioned every frame by the loop below. client/bus.lua
        -- :252 records the measurement this inherits: an attached camera is
        -- welded in place and kills free look, and free look was the first thing
        -- missed. Third person on the vehicle, scenic, never first person, and
        -- the same behaviour at both ends of the journey.
        -- THE POSITION HERE LASTS ONE FRAME. `rescue.cam` below rewrites it from
        -- BR.Config.Rescue.camBackM/camHeight on the next pass and every pass
        -- after, which is where the zoom-out actually lives -- see the block
        -- there for why a number written only at this line could never have been
        -- what the owner was looking at. This one exists so the camera is not
        -- created at the world origin for that one frame.
        local vc = GetEntityCoords(r.veh)
        r.cam = CreateCamWithParams('DEFAULT_SCRIPTED_CAMERA',
            vc.x, vc.y, vc.z + (R.camHeight or 5.5), 0.0, 0.0, 0.0, 60.0, false, 2)
        SetCamActive(r.cam, true)
        RenderScriptCams(true, false, 0, true, true)

        -- ═══ WHERE IT IS TAKING YOU, ON THE MAP YOU ALREADY READ ═══
        --
        -- Owner, 2026-08-28: "It would be neat if there was a clear blip on my
        -- map to show where the ambulance is taking me - perhaps we could
        -- actually use GTA's built-in waypoint system for this one. Then delete
        -- that once the revive is processed."
        --
        -- His suggestion, and it is the better one: a waypoint draws the route
        -- line the player already knows how to read, survives the map being
        -- opened and closed, and needs no blip lifecycle of its own. The cost is
        -- that it CLOBBERS a waypoint they had set before going down -- accepted
        -- as an explicit trade, because a downed player is not navigating to
        -- anything and the destination is the only thing they can act on.
        --
        -- client/markers.lua consumes fresh waypoints and turns them into squad
        -- pings; it now stands down for the ride, or this would be eaten on the
        -- next tick.
        --
        -- ═══ ...AND THE MINIMAP, WHICH THE WAYPOINT ALONE DOES NOT REACH ═══
        --
        -- Owner, 2026-08-28: "we did drive to the waypoint, which was clearly on
        -- my map. Curiously the route was not on the minimap."
        --
        -- HE IS DESCRIBING A REAL GATE AND IT IS NOT OURS. The engine keeps
        -- three independent GPS route slots (eGpsSlotType: waypoint, blip,
        -- discrete), and route rendering on the RADAR is conditioned on the
        -- player being in a vehicle. The proof is in the natives themselves:
        -- START_GPS_MULTI_ROUTE's third parameter is
        --
        --     displayOnFoot -- "Draws the GPS path regardless if the player is
        --                       in a vehicle or not."
        --
        -- A flag that only exists because the default is the other way. And this
        -- player is on the wrong side of it by construction: they are ATTACHED
        -- to the stretcher rather than sitting in a seat, so IsPedInAnyVehicle
        -- is false and GetVehiclePedIsIn answers 0 for the whole ride -- the same
        -- property that exempts them from the fuel registry.
        --
        -- SO BOTH ARE DRAWN, AND THEY ARE DIFFERENT SLOTS RATHER THAN A
        -- DUPLICATE. The waypoint is the owner's own suggestion and is what puts
        -- the marker on the pause map; the multi-route is a second slot with the
        -- on-foot flag set, and it is the one that reaches the radar he is
        -- actually watching while he rides. `routeFromPlayer` is true so the
        -- line starts at the ambulance rather than at wherever the previous
        -- point was.
        --
        -- NOT SetGpsFlags, which was the other candidate: its own documentation
        -- says the flags do not appear to be read, and it LOCKS OUT every other
        -- resource until ClearGpsFlags is called by the same script -- a way to
        -- break somebody else's GPS for no gain.
        if r.dest and r.dest.x then
            SetNewWaypoint(r.dest.x + 0.0, r.dest.y + 0.0)

            ClearGpsMultiRoute()
            StartGpsMultiRoute((R.routeColour or 5), true, true)
            AddPointToGpsMultiRoute(r.dest.x + 0.0, r.dest.y + 0.0,
                                    (r.dest.z or 0.0) + 0.0)
            SetGpsMultiRouteRender(true)
        end

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

        -- ═══ THE DRIVER WAITS FOR THE PLAYER'S SCREEN ═══
        --
        -- Owner, 2026-08-28: "please make it so the ped doesn't start driving
        -- until my screen fades in."
        --
        -- It used to be tasked BEFORE the fade wait, so the ambulance pulled
        -- away while the screen was still black and the ride opened halfway
        -- down the road -- the arrival the fade exists to stage was already
        -- over by the time anyone saw it.
        --
        -- AFTER the fade call, not before: DoScreenFadeIn is the request, and
        -- the wait above it is what guarantees there is an ambulance to look
        -- at. Tasking here means the first frame the player sees is the
        -- vehicle standing still with them in the back.
        taskDrive(r)
        print(('[br_core] rescue: aboard (vehicle %d) bound for %s')
            :format(r.veh, tostring(r.dest.id)))

        -- ═══ KEEP ASKING, AND SAY THE MOMENT IT ARRIVES ═══
        --
        -- The gate above asks for three seconds and then gives up, which was
        -- enough to name the fault and not enough to tell refusal from latency.
        -- A vehicle from CreateVehicleServerSetter is created ORPHANED and only
        -- gets an owning client once one is in scope, so "not yet" and "never"
        -- are genuinely different answers here and three seconds cannot tell
        -- them apart.
        --
        -- THIS IS NOT BEING OFFERED AS THE FIX, and the distinction matters:
        -- if control is truly never granted this changes nothing except that
        -- the log finally says so with a number on it. If it was only late,
        -- the re-task is the ride working. Either way the next run answers the
        -- question instead of restating it.
        --
        -- ONE LOG LINE EITHER WAY. A watcher that printed every attempt would
        -- bury the answer in its own noise.
        Citizen.CreateThread(function()
            local t0 = GetGameTimer()
            local limit = R.controlWatchMs or 15000
            while GetGameTimer() - t0 < limit do
                if ride ~= r then return end
                if not r.veh or not isTrue(DoesEntityExist(r.veh)) then return end
                if isTrue(NetworkHasControlOfEntity(r.veh)) then
                    -- Only interesting if the gate had already given up; a ride
                    -- that got control on time has nothing to report here.
                    if not r.hadControl then
                        print(('[br_core] rescue: control of ambulance %d arrived '
                               .. 'after %dms -- re-tasking the drive')
                            :format(r.veh, GetGameTimer() - t0))
                        taskDrive(r)
                        reportDrive(r, 'after control arrived')
                    end
                    return
                end
                NetworkRequestControlOfEntity(r.veh)
                Citizen.Wait(250)
            end
            if ride ~= r then return end
            print(('[br_core] rescue: control of ambulance %d never arrived in '
                   .. '%dms of asking -- this is a refusal, not latency')
                :format(r.veh, limit))
        end)
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

        -- ═══ WHERE THE AMBULANCE ACTUALLY STOPPED, READ BEFORE IT IS RELEASED
        --     ═══
        --
        -- THE ARRIVAL RADIUS IS 50 METRES (owner, 2026-08-28) and the delivery
        -- used to be placed behind the DESTINATION's coordinates, which is a
        -- different place. At 8m nobody would have noticed; at 50m the player
        -- fades in half a street away from an ambulance whose open doors, dome
        -- light and departed driver are the whole point of the scene. And the
        -- gap is not bounded by 50m either: the "park as close as it can get"
        -- rule can end a ride up to `arriveNearM` out.
        --
        -- SO THE DELIVERY FOLLOWS THE VEHICLE. The server has always delegated
        -- the placing to the client -- "the server says where, the client does
        -- the placing", the same contract as BUS_JUMP_OK -- and the vehicle's
        -- own position is a strictly better answer to the same question than the
        -- point it was aiming at. The server's coordinates stay as the fallback
        -- for a ride with no vehicle left to read.
        --
        -- READ NOW, because `cleanup` below hands the ambulance back to the
        -- engine and the handle stops being ours a line later.
        local dd = (type(d) == 'table') and d or {}
        -- ═══ THE DESTINATION, ALWAYS. NOT WHERE THE AMBULANCE GOT TO. ═══
        --
        -- Owner, 2026-08-28: "when the timer expired it just dumped me on the
        -- side of the road where the ambulance was. No matter what - the revive
        -- must leave the player AT the destination whether the ambulance makes
        -- it there or not."
        --
        -- This read the VEHICLE's parked position for one commit, on the
        -- reasoning that a 50m arrival radius would otherwise set the player
        -- down away from the ambulance they had just ridden in. That reasoning
        -- was about the good case and ignored the bad one: a ride that runs out
        -- of deadline halfway leaves the player wherever the van happened to
        -- be, which is the one outcome a rescue must never produce.
        --
        -- THE DESTINATION IS THE PROMISE. The waypoint named it, the storm rule
        -- chose it for being inside the next circle, and a player who spent an
        -- ultra-rare kit is owed arrival there whether the drive succeeded, ran
        -- long, wedged, or was abandoned. The ambulance is scenery; the
        -- destination is the feature.
        --
        -- The parked ambulance, its open doors and its wandering medic still
        -- stand wherever they stopped -- they are a scene, not a delivery.
        local px, py, pz, ph = dd.x, dd.y, dd.z, dd.heading or 0.0

        -- FADE FIRST ON THE WAY OUT TOO (#191 step 7), and the fade is what the
        -- detach and the teleport hide.
        DoScreenFadeOut(400)
        local t0 = GetGameTimer()
        while not isTrue(IsScreenFadedOut()) and GetGameTimer() - t0 < 1200 do
            Citizen.Wait(50)
        end

        -- A DELIVERY LEAVES ITS AMBULANCE BEHIND; every other ending deletes it.
        cleanup(delivered)

        if delivered then
            -- ON THE GROUND DIRECTLY BEHIND THE AMBULANCE (#191 step 7), which
            -- is where the rear doors are -- and since 2026-08-28 that is the
            -- REAL ambulance rather than the surveyed point it drove at.
            -- Health and weapons are the server's business and are already
            -- restored by the time this runs.
            -- BEHIND, and the sign matters. A GTA heading's FORWARD vector is
            -- (-sin h, cos h), so behind is its negation -- getting this
            -- backwards puts the player in front of the bonnet, which is both
            -- wrong and the one place a still-rolling ambulance can hit them.
            local ped = PlayerPedId()
            local h = ph
            local rad = math.rad(h)
            local bx = px + math.sin(rad) * (R.dropBackM or 3.5)
            local by = py - math.cos(rad) * (R.dropBackM or 3.5)

            SetEntityCoords(ped, bx, by, pz, false, false, false, true)
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

    -- ═══ THE TWO NUMBERS THAT DECIDE HOW ZOOMED OUT THIS IS, AND THEY ARE
    --     CONFIG NOW ═══
    --
    -- Owner, 2026-08-28: "I don't think the camera is zoomed out enough" -- after
    -- a commit that moved `camHeight` 3.0 -> 4.83. HE WAS RIGHT AND THE CAMERA
    -- HAD NOT MOVED AT ALL. Two reasons, and both are the same mistake:
    --
    --   * `R.camHeight` was never added to config/rescue.lua, so `or 4.83` was
    --     the entire value.
    --   * and it was only ever passed to CreateCamWithParams, on the frame the
    --     camera was made -- THIS LOOP overwrote it on the very next frame from
    --     a hardcoded 7.0 and 2.5, and has done since it was written.
    --
    -- So the config values are read HERE, where the camera actually is. The
    -- distance is the half his complaint needed: a camera that is only higher
    -- looks down at the roof, and a van is long enough that it has to come back
    -- as well to fit in the shot.
    local boom = R.camBackM or 11.0
    local back = boom * math.cos(pitchRad)
    local up   = (R.camHeight or 5.5) - boom * math.sin(pitchRad)

    SetCamCoord(r.cam, c.x + math.sin(rad) * back,
                       c.y - math.cos(rad) * back,
                       c.z + up)
    PointCamAtCoord(r.cam, c.x, c.y, c.z + 0.5)
end)

--- The pose, kept.
---
--- ═══ "ENFORCE" IS THE OPERATIVE WORD, AND NOTHING ELSE IS ENFORCING IT ═══
---
--- Owner, 2026-08-28. Posing once at boarding time is a call something else
--- overwrites, and this ride has a specific reason to expect that: the file
--- that was re-asserting a pose on this ped every frame -- client/dbno.lua's
--- `dbno.controls` -- STANDS DOWN for the ride (c0016d6), correctly, because
--- its pose and its stayPut were dragging the body off the moving ambulance.
--- The ped therefore goes from "re-tasked sixty times a second" to "tasked
--- once, by us" at exactly the moment the journey starts. Anything the engine
--- hands it over the next minute or two wins by default.
---
--- WHAT CAN TAKE IT AWAY, none of which is hypothetical: an ambient event the
--- non-temporary block does not cover, a ragdoll from the vehicle's own physics
--- as the AI driver "drives erratically" into things, and the re-place
--- (RESCUE_PLACE) which teleports the vehicle out from under an attached ped.
--- The failure is silent and cosmetic-looking and it is not cosmetic: the
--- offset is only correct for this clip, so a lost pose is a body in the wrong
--- place.
---
--- ═══ ON THE TICK BAND, AND GUARDED BY IsEntityPlayingAnim ═══
---
--- 10Hz rather than per frame: the worst case is a tenth of a second of a body
--- in the wrong posture behind a camera seven metres back, which is not worth a
--- frame callback. The guard is client/dbno.lua's own rule, learned there --
--- re-tasking unconditionally is a clip that restarts on its first frame for
--- ever and never plays. It is read through isTrue because IsEntityPlayingAnim
--- is declared BOOL and `0` is truthy in Lua; dbno.lua shipped exactly that bug.
---
--- `3` is the standard task-filter mask for "is this the clip I asked for".
BR.Loop.register(BR.Loop.TICK, 'rescue.pose', function()
    local r = ride
    if not r or not r.veh then return end
    -- THE RIDE IS ENDING, SO STOP PUTTING THE BODY BACK ON THE STRETCHER.
    -- RESCUE_END sets this before its first yield, and the ~400ms of fade that
    -- follows is 4 passes of this band -- 4 chances to re-task a pose over the
    -- ClearPedTasks a delivery's revive has just performed. Same window,
    -- opposite end, as the clear in `cleanup`.
    if r.ending then return end
    if not isTrue(DoesEntityExist(r.veh)) then return end

    local ped = PlayerPedId()
    -- Only while the body is actually ON the ambulance. Re-posing a ped the
    -- attach has lost would pin a player to the floor in a sunbathe.
    if not isTrue(IsEntityAttachedToEntity(ped, r.veh)) then return end
    if isTrue(IsEntityPlayingAnim(ped, POSE_DICT, POSE_ANIM, 3)) then return end

    poseOnStretcher(ped)
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

    -- ═══ ARRIVED -- OR AS CLOSE AS IT IS GOING TO GET ═══
    --
    -- THE CLOSEST APPROACH IS THE STATE THIS BAND KEEPS, and it is a running
    -- MINIMUM rather than a distance. A circling ambulance is moving, at speed,
    -- on a road, making no progress -- invisible to a speed test and invisible
    -- to the server's own `everMoved` sampling, which reads a lap as a healthy
    -- drive and is right to. What a lap cannot do is beat its own best, so
    -- `bestM` stops falling the moment the driving stops being progress. See
    -- BR.RescueArrived for the rule this feeds.
    local c = GetEntityCoords(r.veh)
    local d = BR.Dist(c.x, c.y, r.dest.x, r.dest.y)
    local now = GetGameTimer()
    if not r.bestM or d < r.bestM then
        r.bestM, r.bestAt = d, now
    end

    local arrived, why = BR.RescueArrived(d, r.bestM, now - (r.bestAt or now), R)
    if arrived then
        r.reported = true
        park(r, why)
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
