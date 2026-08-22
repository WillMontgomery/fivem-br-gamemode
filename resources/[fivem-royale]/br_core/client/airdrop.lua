-- Aerial supply drops, client half: the crate, its canopy, and the blip.
--
-- PRESENTATION ONLY. Nothing here decides anything: the server publishes one
-- record when the drop is committed (AIRDROP_SYNC) and this file solves the
-- crate's position from it against the synced clock, exactly as client/storm.lua
-- solves the wall and client/bus.lua flies the ghost plane. Deleting the prop
-- locally does not stop the drop; the loot that appears when it lands comes from
-- the server's registry through the ordinary LOOT_ADD path.
--
-- THE CRATE IS LOCAL AND NON-NETWORKED, like every other object this gamemode
-- creates -- CreateObjectNoOffset with isNetwork = false. That is not merely
-- consistent, it is required: `sv_entityLockdown relaxed` refuses
-- client-created networked entities outright, so a networked crate would
-- silently never appear for anyone.
--
-- AND IT STILL CANNOT DESYNC, which is the part every public FiveM airdrop gets
-- wrong. They either network the crate (and inherit the "crate stuck in the
-- air" bug the Cfx.re tracker has open) or let each client run its own physics
-- and then disagree about where it landed. Ours is not simulated at all: height
-- is `alt * (1 - elapsed/span)`, a pure function of the record and the clock, so
-- every machine draws the same crate in the same place because there is nothing
-- for them to disagree about.
--
-- ═══ FOUR OBJECTS, ONE SOLVER, NO ATTACHMENTS ═══
--
-- A drop is a crate, a cargo canopy over it and a flare on each side. All four
-- are separate local objects and all four are positioned the same way: ask
-- BR.AirdropOffsetAt where this part of the crate is right now, and write the
-- coordinates.
--
-- They are NOT attached to each other, and that is deliberate. Rockstar's own
-- crate drop uses ATTACH_ENTITY_TO_ENTITY; an earlier version of this file did
-- too, for the canopy. Writing coordinates instead means there is exactly ONE
-- thing deciding where any part of a drop is -- a pure function of the record
-- and the clock -- rather than two, the second of which lives in the engine,
-- cannot be reached by a test, and has no documented behaviour on a pair of
-- local non-networked objects. The result on screen is identical and there is
-- one fewer thing that has to be true.
--
-- NOTHING IS SIMULATED. No ACTIVATE_PHYSICS, no SET_ENTITY_VELOCITY, no
-- SET_DAMPING -- which is what every physics-driven airdrop reaches for and
-- exactly why they all end up networking the crate to paper over the divergence.
-- Collision is off and every object is frozen. The one thing here that is not a
-- pure function of the clock is the flares' particle effect, and it is
-- presentation with no position of its own: the emitter rides the flare, and
-- where its smoke has already been drawn does not change where anything IS.

BR = BR or {}
BR.Airdrop = BR.Airdrop or {}

local A = BR.Config.Airdrop

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true -- so `v == true` is false for a native that said yes, and
--- `if v then` is TRUE for a native that said no with a zero. This project has
--- shipped that bug four times (config/overrides.lua's state guard is the one
--- with a test named after it). Every native BOOL read in this file goes
--- through here.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

--- [n] = { rec, obj, chute, flares, plane, pilot, blip, gz, gzAt, spawning,
---         flying, warned }
---
--- `flares` is an array of { obj, fx, ox }, one per side.
local drops = {}

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

--- The plane and its crew. Separate from dropProps because it goes FIRST: the
--- aircraft's work is done at the release, and the crate's has only just begun.
local function dropPlane(d)
    if d.pilot and isTrue(DoesEntityExist(d.pilot)) then DeleteEntity(d.pilot) end
    if d.plane and isTrue(DoesEntityExist(d.plane)) then DeleteEntity(d.plane) end
    d.plane, d.pilot = nil, nil
end

local function dropProps(d)
    -- THE PARTICLE HANDLES GO FIRST, and before the entity they are anchored
    -- to. A looped ptfx outlives the object it was started on -- that is what
    -- "looped" means -- so deleting the flare first leaves an emitter running at
    -- the last place it was, for the rest of the session, and nothing left holds
    -- its handle.
    for _, f in ipairs(d.flares or {}) do
        if f.fx then StopParticleFxLooped(f.fx, false) end
        f.fx = nil
        if f.obj and isTrue(DoesEntityExist(f.obj)) then DeleteEntity(f.obj) end
        f.obj = nil
    end
    d.flares = nil

    if d.chute and isTrue(DoesEntityExist(d.chute)) then DeleteEntity(d.chute) end
    if d.obj and isTrue(DoesEntityExist(d.obj)) then DeleteEntity(d.obj) end
    d.chute, d.obj = nil, nil
end

local function removeDrop(n)
    local d = drops[n]
    if not d then return end
    dropPlane(d)
    dropProps(d)
    if d.blip and isTrue(DoesBlipExist(d.blip)) then RemoveBlip(d.blip) end
    -- THE RECORD IS THE SPAWN THREAD'S PERMISSION SLIP. A model stream takes
    -- frames, and a match can end inside them -- so the thread re-checks
    -- `d.rec` before it builds anything, and clearing it here is what turns
    -- that check into a real one. Without this, tearing down mid-stream leaves
    -- a crate hanging in the sky with nothing left that knows it exists.
    -- dropProps() deliberately does NOT do this: a LANDED drop keeps its record
    -- for the minute its blip has left to live.
    d.rec = nil
    drops[n] = nil
end

local function clearAll()
    for n in pairs(drops) do removeDrop(n) end
end

-- ---------------------------------------------------------------------------
-- The blip
-- ---------------------------------------------------------------------------

--- Put this drop's marker on the map, if it is not already there.
---
--- IDEMPOTENT, AND CALLED FROM TWO PLACES ON PURPOSE. The record's arrival puts
--- it up immediately, and the render loop re-asserts it every frame the window
--- is open -- so a blip lost to anything at all (another resource sweeping
--- blips, a handle that went bad, a teardown that raced an arrival) comes back
--- on the next frame instead of leaving the match's one airdrop unfindable.
---
--- 161 IS A REGULAR SPRITE AND A COORD BLIP IS THE RIGHT CARRIER FOR IT.
--- Checked against the Cfx blip reference after a playtest reported no marker:
--- 161 is `radar_mp_noise`, an animated sonic-wave icon, and it is an ordinary
--- entry in the sprite table. The RADIUS blips are 9 and 10
--- (`radar_radius_blip` / `radar_radius_outline_blip`) and are made with
--- AddBlipForRadius, which takes no sprite at all. So the owner's "it will give
--- them a radius, not an exact point" is satisfied by what the icon LOOKS like,
--- and does not want AddBlipForRadius.
--- @param d table
local function addBlip(d)
    if not d.rec then return end
    if d.blip and isTrue(DoesBlipExist(d.blip)) then return end

    -- At the POI's nominal height -- the pause map only cares about x/y, and the
    -- ground probe has almost certainly not run yet for a point kilometres away.
    local b = AddBlipForCoord(d.rec.x, d.rec.y, d.rec.gz or 0.0)
    SetBlipSprite(b, A.blipSprite or 161)
    SetBlipColour(b, A.blipColour or 5)
    SetBlipScale(b, A.blipScale or 1.2)
    -- NOT short range: the whole point is that everyone in the match can see
    -- where it is coming down, from wherever they are standing.
    SetBlipAsShortRange(b, false)
    BR.Native.blipName(b, A.blipName or 'Airdrop')
    d.blip = b
end

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

RegisterNetEvent(BR.Net.AIRDROP_SYNC)
AddEventHandler(BR.Net.AIRDROP_SYNC, function(rec)
    if type(rec) ~= 'table' then return end
    if type(rec.x) ~= 'number' or type(rec.y) ~= 'number' then return end
    if type(rec.tStart) ~= 'number' or type(rec.tLand) ~= 'number' then return end

    local n = math.tointeger(rec.n) or 1
    removeDrop(n)   -- a re-send replaces

    local d = { rec = rec }
    drops[n] = d

    -- THE BLIP GOES UP THE MOMENT THE DROP IS ANNOUNCED, rather than on the
    -- first frame that agrees it is due: the notification the player just read
    -- and the marker they are about to look for must not be separated by a
    -- clock estimate.
    addBlip(d)
end)

-- Between matches the world is a different place, and a crate still falling
-- through the verdict slam is scenery from a game that has ended.
RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if not d then return end
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        clearAll()
    end
end)

-- An un-deleted local object outlives the resource that made it.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearAll()
end)

-- ---------------------------------------------------------------------------
-- The aircraft and the props
-- ---------------------------------------------------------------------------

--- Load a model, bounded. Returns false rather than blocking forever on a
--- name that is not a model at all.
--- @param model integer
--- @return boolean
local function loadModel(model)
    if not isTrue(IsModelValid(model)) then return false end
    RequestModel(model)
    local waited = 0
    while not isTrue(HasModelLoaded(model)) and waited < 5000 do
        Citizen.Wait(50)
        waited = waited + 50
    end
    return isTrue(HasModelLoaded(model))
end

--- Stream a named particle asset, bounded. Same shape and same bound as
--- loadModel, and returns false rather than blocking on an asset name that is
--- not one -- a missing trail costs the flares their smoke and must not cost the
--- match its airdrop.
--- @param asset string|nil
--- @return boolean
local function loadPtfx(asset)
    if type(asset) ~= 'string' or asset == '' then return false end
    if isTrue(HasNamedPtfxAssetLoaded(asset)) then return true end
    RequestNamedPtfxAsset(asset)
    local waited = 0
    while not isTrue(HasNamedPtfxAssetLoaded(asset)) and waited < 5000 do
        Citizen.Wait(50)
        waited = waited + 50
    end
    return isTrue(HasNamedPtfxAssetLoaded(asset))
end

--- One local, non-networked, non-colliding, frozen object at (x, y, z).
---
--- EVERY OBJECT A DROP MAKES GOES THROUGH HERE, so "local, invisible to the
--- physics, and moved only by arithmetic" is one decision rather than four
--- copies of it. `isNetwork = false` is not consistency for its own sake:
--- `sv_entityLockdown relaxed` refuses a client-created networked entity
--- outright, so any other value is an object that silently never appears.
--- @param model integer
--- @param x number
--- @param y number
--- @param z number
--- @return integer|nil
local function makePart(model, x, y, z)
    local obj = CreateObjectNoOffset(model, x, y, z, false, false, false)
    if not obj or obj == 0 then return nil end
    -- A falling crate must not shove anyone, and nothing may shove it: its
    -- position is decided by arithmetic, and a collision that moved it would put
    -- this client's crate somewhere no other client's is.
    SetEntityCollision(obj, false, false)
    FreezeEntityPosition(obj, true)
    return obj
end

--- Build the delivery plane and the pilot who keeps its engine turning.
---
--- LOCAL, NON-NETWORKED, AND FLOWN BY COORDINATE WRITE, exactly as
--- client/bus.lua's ghost flights are -- that file is the working precedent for
--- this whole idea, and two things it learned the hard way are copied here
--- rather than rediscovered:
---
---   * A PROP AIRCRAFT SHUTS ITS ENGINE OFF WHEN UNOCCUPIED. That is engine
---     behaviour, not a missing call, so the pilot is load-bearing: a seated ped
---     is what keeps the propellers turning and the audio playing. Without one
---     the Titan glides past as a silent model with static props.
---   * NOT FROZEN. The fly loop writes coordinates every frame anyway, and a
---     frozen plane does not run its engine simulation at all -- which is half
---     of what made the first battle-bus flight unconvincing.
---
--- Collision off and invincible, because it is scenery: nothing in the match may
--- hit it, and it may not hit anybody.
--- @param d table
local function spawnPlane(d)
    d.flying = true
    Citizen.CreateThread(function()
        local model = GetHashKey(A.planeModel or 'titan')
        if not loadModel(model) then
            d.flying = false
            return
        end
        if not d.rec then d.flying = false return end

        local px, py, pz = BR.AirdropPlaneAt(d.rec, BR.Clock.now(), A)
        local gz = d.gz or d.rec.gz or 0.0
        local plane = CreateVehicle(model, px, py, gz + pz,
            d.rec.heading or 0.0, false, false)
        SetModelAsNoLongerNeeded(model)
        if not plane or plane == 0 then d.flying = false return end
        SetEntityCollision(plane, false, false)
        SetEntityInvincible(plane, true)
        d.plane = plane

        -- The crew, best-effort. A plane with no pilot still flies the route;
        -- it just does it with the props stopped, which is worse and is not
        -- worth losing the flyover over.
        local pilotModel = GetHashKey(A.planePilot or 's_m_m_pilot_01')
        if loadModel(pilotModel) and isTrue(DoesEntityExist(plane)) then
            local pilot = CreatePed(4, pilotModel, px, py, gz + pz,
                d.rec.heading or 0.0, false, false)
            SetModelAsNoLongerNeeded(pilotModel)
            if pilot and pilot ~= 0 then
                SetEntityInvincible(pilot, true)
                SetBlockingOfNonTemporaryEvents(pilot, true)
                SetPedIntoVehicle(pilot, plane, -1)
                d.pilot = pilot
            end
        end
        SetVehicleEngineOn(plane, true, true, false)

        d.flying = false
    end)
end

--- Build the crate, the canopy over it and a flare on each side.
---
--- THE CANOPY IS ROCKSTAR'S OWN, and the offset is theirs verbatim. GTA
--- Online's crate drop (am_crate_drop) and ammo drop (am_ammo_drop) both use a
--- separate `p_cargo_chute_s` object at (0, 0, 0.1) with the deploy anim played
--- once. There is no native that does any of it -- researched before this was
--- written, because the alternative was writing code that fights the engine.
--- What we do NOT take from them is the attachment; see the note at the top.
---
--- NOT BR.Config.Drop.parachuteModel. That is `p_parachute1_mp_s`, the
--- player's back-worn canopy -- a different asset for a different job.
---
--- THE FLARES ARE A PROP AND A LOOPED PARTICLE EACH, and both halves are
--- best-effort in the same way the deploy anim is: a flare with no smoke still
--- reads as a flare, smoke with no flare prop still reads as a trail, and
--- neither missing may cost us the drop. The particle is anchored to the flare
--- rather than started at a coordinate, so the emitter rides the fall while the
--- smoke it has already made stays where it was made -- which is what a trail is.
--- @param d table
local function spawn(d)
    d.spawning = true
    Citizen.CreateThread(function()
        local model = GetHashKey(A.crateProp or 'prop_box_wood05a')
        if not loadModel(model) then
            d.spawning = false
            if not d.warned then
                d.warned = true
                print(('[br_core] airdrop: crate model %s would not load')
                    :format(tostring(A.crateProp)))
            end
            return
        end

        -- The record may have been torn down while the model streamed.
        if not d.rec then d.spawning = false return end

        local gz  = d.gz or d.rec.gz or 0.0
        local top = gz + (d.rec.alt or 0.0)

        local obj = makePart(model, d.rec.x, d.rec.y, top)
        SetModelAsNoLongerNeeded(model)
        if not obj then d.spawning = false return end
        SetEntityHeading(obj, d.rec.heading or 0.0)
        d.obj = obj

        -- The canopy. Positioned every frame from the same solver as the crate.
        local chuteModel = GetHashKey(A.chuteModel or 'p_cargo_chute_s')
        if loadModel(chuteModel) and d.rec then
            local chute = makePart(chuteModel, d.rec.x, d.rec.y, top)
            SetModelAsNoLongerNeeded(chuteModel)
            if chute then
                d.chute = chute

                -- The deploy anim, once. Best-effort: a canopy that never
                -- unfurls still reads as a canopy, and a missing anim dict must
                -- not cost us the drop.
                local dict = A.chuteAnimDict
                local anim = A.chuteAnim
                if dict and anim then
                    RequestAnimDict(dict)
                    local waited = 0
                    while not isTrue(HasAnimDictLoaded(dict)) and waited < 2000 do
                        Citizen.Wait(50)
                        waited = waited + 50
                    end
                    if isTrue(HasAnimDictLoaded(dict))
                       and isTrue(DoesEntityExist(chute)) then
                        PlayEntityAnim(chute, anim, dict, 1000.0,
                            false, false, false, 0.0, 0)
                    end
                end
            end
        end

        -- The flares, left and right. One offset, two signs.
        local off = A.flareOffset or { x = 0.55, y = 0.0, z = 0.0 }
        local flareModel = GetHashKey(A.flareProp or 'prop_flare_01a')
        if loadModel(flareModel) and d.rec then
            local ptfxReady = loadPtfx(A.flarePtfxAsset)
            d.flares = {}
            for _, side in ipairs({ 1.0, -1.0 }) do
                local f = makePart(flareModel, d.rec.x, d.rec.y, top)
                if f then
                    local rec = { obj = f, ox = (off.x or 0.55) * side }
                    if ptfxReady and A.flarePtfxName then
                        -- USE_PARTICLE_FX_ASSET IS PER CALL, NOT PER SESSION,
                        -- and it is the line every ptfx bug on the forums turns
                        -- out to be missing. It has to be re-asserted
                        -- immediately before each start or the effect resolves
                        -- against whatever asset was last named.
                        UseParticleFxAsset(A.flarePtfxAsset)
                        local fx = StartParticleFxLoopedOnEntity(
                            A.flarePtfxName, f,
                            0.0, 0.0, 0.0,
                            0.0, 0.0, 0.0,
                            A.flarePtfxScale or 1.0,
                            false, false, false)
                        -- A FAILED START ANSWERS 0, AND 0 IS TRUTHY IN LUA --
                        -- the four-times bug in its other direction. Stored only
                        -- when it is a real handle, so teardown never calls
                        -- StopParticleFxLooped(0).
                        if fx and fx ~= 0 then rec.fx = fx end
                    end
                    d.flares[#d.flares + 1] = rec
                end
            end
            SetModelAsNoLongerNeeded(flareModel)
        end

        d.spawning = false
    end)
end

--- The ground under the drop, re-probed while it falls.
---
--- ONLY A CLIENT CAN ANSWER THIS -- GetGroundZFor_3dCoord is a client native --
--- which is exactly why the record carries a HEIGHT ABOVE THE GROUND rather
--- than an absolute z. The probe is also documented to fail beyond render
--- distance, and the drop is announced while everyone is kilometres away, so
--- the POI's authored height stands in until the probe starts answering.
--- @param d table
--- @return number
local function groundOf(d)
    local now = GetGameTimer()
    if d.gz and (now - (d.gzAt or 0)) < 3000 then return d.gz end
    d.gzAt = now

    local ok, gz = GetGroundZFor_3dCoord(d.rec.x, d.rec.y,
        (d.rec.gz or 0.0) + (d.rec.alt or 0.0), false)
    if isTrue(ok) then
        d.gz = gz
    else
        d.gz = d.gz or d.rec.gz or 0.0
    end
    return d.gz
end

-- ---------------------------------------------------------------------------
-- The descent
-- ---------------------------------------------------------------------------

--- Put every part of one drop where the clock says it is, this frame.
---
--- ONE FUNCTION FOR ALL FOUR OBJECTS, because they are four renderings of a
--- single solved state: a height above the ground, a heading, and two offsets
--- rotated by that heading. Positioning the crate here and the canopy somewhere
--- else is how a canopy comes to lag a frame behind the box it is over.
---
--- The z is `groundOf` + BR.AirdropHeightAt, and the ground is re-probed rather
--- than resolved once: the drop is announced while everyone is kilometres away,
--- where the probe is documented not to answer, and it starts answering as
--- players close in.
--- @param d table
--- @param now number  synced clock
local function place(d, now)
    local gz   = groundOf(d)
    local z    = gz + BR.AirdropHeightAt(d.rec, now)
    local spin = A.spinDegrees or 0.0
    local hdg  = BR.AirdropHeadingAt(d.rec, now, spin)

    SetEntityCoords(d.obj, d.rec.x, d.rec.y, z, false, false, false, false)
    SetEntityHeading(d.obj, hdg)

    if d.chute and isTrue(DoesEntityExist(d.chute)) then
        local off = A.chuteOffset or { x = 0.0, y = 0.0, z = 0.1 }
        local cx, cy = BR.AirdropOffsetAt(d.rec, now, off.x, off.y, spin)
        SetEntityCoords(d.chute, cx, cy, z + (off.z or 0.1),
            false, false, false, false)
        SetEntityHeading(d.chute, hdg)
    end

    for _, f in ipairs(d.flares or {}) do
        if f.obj and isTrue(DoesEntityExist(f.obj)) then
            local off = A.flareOffset or { x = 0.55, y = 0.0, z = 0.0 }
            local fx, fy = BR.AirdropOffsetAt(d.rec, now, f.ox, off.y, spin)
            SetEntityCoords(f.obj, fx, fy, z + (off.z or 0.0),
                false, false, false, false)
            SetEntityHeading(f.obj, hdg)
        end
    end
end

BR.Loop.register(BR.Loop.FRAME, 'airdrop.render', function()
    if not next(drops) then return end

    -- A player back at the lobby vista keeps their matchId and therefore keeps
    -- receiving this match's traffic. The drop is not their problem any more --
    -- the same rule client/storm.lua applies to the wall.
    local st = BR.State.me.state
    if st == BR.PlayerState.LOBBY or st == BR.PlayerState.LEFT then
        clearAll()
        return
    end

    local now = BR.Clock.now()

    for n, d in pairs(drops) do
        -- THE ONLY TEARDOWN PATH, AND IT ONLY FIRES AT THE FAR END. This asked
        -- BR.AirdropBlipVisible until 2026-08-22, which is ALSO false for a
        -- record whose tStart the client's clock estimate has not reached --
        -- so a client running a few tens of milliseconds behind the server
        -- destroyed its own airdrop on the frame it arrived, having just shown
        -- the player a notification about it. See BR.AirdropExpired.
        if BR.AirdropExpired(d.rec, now, A.blipLingerMs) then
            -- One minute past touchdown: the blip goes, and with it the whole
            -- entry. What is left on the ground is ordinary loot with ordinary
            -- rules.
            removeDrop(n)
        else
            -- Re-asserted, not assumed. addBlip is idempotent and cheap, and
            -- this is what makes the marker survive anything that removes it
            -- while the drop is still live.
            if BR.AirdropBlipVisible(d.rec, now, A.blipLingerMs) then
                addBlip(d)
            end

            -- THE PLANE, WHICH LIVES ON ITS OWN CLOCK. It arrives with the
            -- announcement, is overhead at the release, and leaves -- so it is
            -- gone long before the crate is, and it is torn down where it is
            -- decided rather than where the crate is.
            if BR.AirdropPlaneVisible(d.rec, now, A) then
                if not d.plane and not d.flying then
                    groundOf(d)
                    spawnPlane(d)
                end
                if d.plane and isTrue(DoesEntityExist(d.plane)) then
                    local px, py, pz, phdg = BR.AirdropPlaneAt(d.rec, now, A)
                    SetEntityCoordsNoOffset(d.plane, px, py, groundOf(d) + pz,
                        false, false, false)
                    -- A STRAIGHT LINE NEEDS NO EASED HEADING. bus.lua smooths
                    -- its bearing because a polyline steps between legs; this
                    -- route has one leg and one bearing, so the honest write is
                    -- the constant.
                    SetEntityRotation(d.plane, 0.0, 0.0, phdg, 2, true)
                end
            elseif d.plane or d.pilot then
                dropPlane(d)
            end

            if BR.AirdropLanded(d.rec, now) then
                -- Down. The husk and the twelve items arrive as registry
                -- entries from the server; these props have nothing left to
                -- represent.
                dropProps(d)
            elseif BR.AirdropReleased(d.rec, now) then
                -- THE CRATE ONLY EXISTS ONCE IT HAS LEFT THE PLANE. Building it
                -- during the run-in would put a box in the sky under an aircraft
                -- that has not reached it, which is the picture the run-in was
                -- added to replace.
                if not d.obj and not d.spawning then
                    groundOf(d)
                    spawn(d)
                end
                if d.obj and isTrue(DoesEntityExist(d.obj)) then
                    place(d, now)
                end
            end
        end
    end
end)

-- ---------------------------------------------------------------- observing ---

--- What this client currently believes about the match's airdrop.
---
--- WRITTEN BECAUSE A SILENT FAILURE HERE COSTS A WHOLE ROUND. An airdrop
--- happens once per match, the blip lives about ninety seconds, and when the
--- owner reported "I randomly got a notification for airdrop, but didn't see it
--- on the map" there was nothing on any screen or in any log that could tell
--- "the record never arrived" apart from "the blip was made and removed" apart
--- from "the blip is there and you were looking at the wrong part of the map".
--- Three different bugs, one symptom, and no way to choose between them without
--- playing another match.
---
--- THE CLOCK IS THE FIRST THING IT PRINTS, because the clock is what broke it:
--- every window in this file is a comparison between the server's timestamps and
--- this client's ESTIMATE of the server's clock, and that estimate is the one
--- number a player cannot otherwise see.
RegisterCommand('brairdrop', function()
    local now = BR.Clock.now()
    print('=== airdrop (client) ===')
    print(('  clock: now %.0f, offset %+.0fms, synced %s')
        :format(now, BR.Clock.offset or 0.0, tostring(BR.Clock.synced)))
    print(('  my state: %s'):format(tostring(BR.State.me.state)))

    local any = false
    for n, d in pairs(drops) do
        any = true
        local rec = d.rec
        if not rec then
            print(('  drop %d: torn down, blip only'):format(n))
        else
            print(('  drop %d at %s (%.0f, %.0f), gz %.1f, alt %.0f')
                :format(n, tostring(rec.poi), rec.x, rec.y, rec.gz or 0.0,
                        rec.alt or 0.0))
            print(('    tStart %+.1fs, tRelease %+.1fs, tLand %+.1fs, expires %+.1fs')
                :format((rec.tStart - now) / 1000,
                        ((rec.tRelease or rec.tStart) - now) / 1000,
                        (rec.tLand - now) / 1000,
                        (rec.tLand + (A.blipLingerMs or 60000) - now) / 1000))
            print(('    released %s, landed %s, blip should be up %s, expired %s')
                :format(tostring(BR.AirdropReleased(rec, now)),
                        tostring(BR.AirdropLanded(rec, now)),
                        tostring(BR.AirdropBlipVisible(rec, now, A.blipLingerMs)),
                        tostring(BR.AirdropExpired(rec, now, A.blipLingerMs))))
            local px, py = BR.AirdropPlaneAt(rec, now, A)
            print(('    plane should be up %s, at (%.0f, %.0f)')
                :format(tostring(BR.AirdropPlaneVisible(rec, now, A)), px, py))
        end
        print(('    blip handle %s, exists %s, sprite %d')
            :format(tostring(d.blip),
                    tostring(d.blip and isTrue(DoesBlipExist(d.blip))),
                    A.blipSprite or 161))
        print(('    plane %s, pilot %s, crate %s, canopy %s, flares %d')
            :format(tostring(d.plane), tostring(d.pilot), tostring(d.obj),
                    tostring(d.chute), #(d.flares or {})))
    end
    if not any then
        print('  no drop record on this client -- nothing has been announced, '
              .. 'or it has already expired')
    end
end, false)
