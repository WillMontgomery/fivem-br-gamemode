-- Aerial supply drops, client half: the plane, the crate, its canopy, its two
-- flares, and its two blips (one per map surface -- see addBlip).
--
-- PRESENTATION ONLY. Nothing here decides anything: the server publishes the
-- record (AIRDROP_SYNC) and this file solves the crate's position from it
-- against the synced clock, exactly as client/storm.lua solves the wall and
-- client/bus.lua flies the ghost plane. Deleting the prop locally does not stop
-- the drop; the loot that appears when it lands comes from the server's registry
-- through the ordinary LOOT_ADD path.
--
-- ═══ THE RECORD ARRIVES TWICE NOW, AND THE FIRST ONE IS A BLIP AND NOTHING
--     ELSE ═══
--
-- Owner, 2026-08-22: "the drop should never happen until a player is within 200m
-- of the drop location. That way they get to see the drop happen."
--
-- So the server SITES and ANNOUNCES a drop at schedule time -- which it has to,
-- because a gate on "is somebody near the drop" is circular unless they have
-- been told where it is -- and holds the descent until somebody comes. The first
-- record therefore has a tStart and NO tRelease, tLand or tArm: this file draws
-- its blip and builds absolutely nothing else. BR.AirdropArmed is the question,
-- and every descent predicate in the solver answers "no" to a record that fails
-- it.
--
-- WHICH ALSO MEANS A DROP MAY NEVER HAPPEN. If nobody comes before the blip's
-- ceiling, the server abandons it and the match gets no airdrop -- and this file
-- needs no message to find that out, because its own teardown fires on the same
-- BR.AirdropExpired boundary off the same record and the same clock.
--
-- AND THERE IS NO CLIENT-SIDE VIEW RADIUS ANY MORE. There was one for a day: a
-- 1000m check each client applied to itself before building the aircraft, back
-- when the drop happened whether or not anybody was near. The server holds the
-- drop instead now, so by the time a record carries a tRelease at all, somebody
-- is already standing at the landing point.
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
-- ═══ TWO OBJECTS, ONE SOLVER, NO ATTACHMENTS ═══
--
-- A drop is a crate and a cargo canopy over it. Both are separate local objects
-- and both are positioned the same way: ask BR.AirdropOffsetAt where this part
-- of the crate is right now, and write the coordinates.
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
-- ═══ AND THE FLARES ARE NOT OBJECTS OF OURS AT ALL ANY MORE ═══
--
-- There were four objects here until 2026-08-22: a crate, a canopy and a flare
-- prop on each side. Two attempts shipped that way and the owner saw nothing
-- both times, because no MODEL glows -- every visual a flare has lives in
-- `AMMO_FLARE`'s CAmmoThrownInfo and is applied by the projectile controller.
--
-- So this file no longer builds flares. It works out where the crate's left and
-- right faces are, from the same solver and the same `spin` as everything else,
-- and hands those two positions to client/flares.lua, which lights real
-- projectile flares there on a cadence as the crate falls. See that file, and
-- the long note in br_lib/config/airdrop.lua, for why a projectile is allowed
-- here at all when nothing else in a drop is simulated: it does not travel (the
-- two shot coordinates are 1e-4 apart), it is not ours to delete (the engine
-- expires it), and its replication is REFUSED server-side rather than tolerated.
--
-- NOTHING OF OURS IS SIMULATED. No ACTIVATE_PHYSICS, no SET_ENTITY_VELOCITY, no
-- SET_DAMPING -- which is what every physics-driven airdrop reaches for and
-- exactly why they all end up networking the crate to paper over the divergence.
-- Collision is off and every object we make is frozen.

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

--- [n] = { rec, obj, chute, flares, plane, pilot, blip, blipMini, gz, gzAt,
---         spawning, flying, warned, audio }
---
--- `blip` AND `blipMini` ARE TWO REAL BLIPS FOR ONE DROP, restricted to the big
--- map and to the minimap respectively so each can carry its own scale (owner,
--- 2026-08-23). See addBlip.
---
--- `flares` IS A BR.Flare SITE NOW, NOT AN ARRAY OF PROPS, and that is the
--- shape change the third attempt needed. A site is "something that wants
--- flares at moving positions"; what it does with that is the route's business
--- and lives in client/flares.lua. On the default projectile route it holds
--- nothing at all -- the engine owns every flare it lights and expires them on
--- AMMO_FLARE's own clock -- so there is no array here to tear down.
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
    -- THE FLARE SITE GOES FIRST, and it goes through client/flares.lua rather
    -- than being unwound here. On the object route that stops each emitter
    -- BEFORE deleting the prop it is anchored to -- a looped ptfx outlives its
    -- entity, which is what "looped" means, so the other order leaves an
    -- emitter running in mid-air for the rest of the session with nothing
    -- holding its handle. On the projectile route it does nothing at all,
    -- because we hold nothing: the flares are the engine's and it expires them.
    BR.Flare.clearSite(d.flares)
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
    -- BOTH SURFACES, IN ONE PLACE. The minimap half is a second real blip with
    -- its own handle (see addBlip); missing it here would leave the radar
    -- marking a crate that no longer exists, for the rest of the match, with
    -- nothing left holding the handle.
    if d.blip and isTrue(DoesBlipExist(d.blip)) then RemoveBlip(d.blip) end
    if d.blipMini and isTrue(DoesBlipExist(d.blipMini)) then
        RemoveBlip(d.blipMini)
    end
    d.blip, d.blipMini = nil, nil
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

--- ═══ A DROP PUTS UP TWO BLIPS, ONE PER SURFACE (owner, 2026-08-23) ═══
---
--- "specifically the blip on the MINIMAP should show much smaller... The big map
--- blip is perfect size"
---
--- THERE IS NO PER-SURFACE SCALE, which is the whole reason this is two objects
--- and not one call. SET_BLIP_SCALE sets a single size that both the pause map
--- and the minimap draw at, so "2.4 there, small here" is not reachable from one
--- blip. What IS per-surface is DISPLAY, so each blip is restricted to one
--- surface and carries its own scale. See br_lib/config/airdrop.lua for the
--- SET_BLIP_DISPLAY enum and where it was read from.
---
--- BOTH ARE THE SAME DROP AND HAVE THE SAME LIFETIME. They go up together, are
--- re-asserted together, and are removed together in removeDrop -- a second blip
--- that outlived the first would be a marker for a crate that is not there.
---
--- @param d table
--- @param key string     'blip' (big map) or 'blipMini' (minimap)
--- @param display number
--- @param scale number
local function ensureBlip(d, key, display, scale)
    -- INDEPENDENTLY, PER SURFACE. Sharing one existence check would mean
    -- whichever blip a stray sweep took stayed gone for as long as the other one
    -- survived, which is the failure this re-assertion exists to prevent.
    if d[key] and isTrue(DoesBlipExist(d[key])) then return end

    -- At the POI's nominal height -- the pause map only cares about x/y, and the
    -- ground probe has almost certainly not run yet for a point kilometres away.
    local b = AddBlipForCoord(d.rec.x, d.rec.y, d.rec.gz or 0.0)
    SetBlipSprite(b, A.blipSprite or 161)
    SetBlipColour(b, A.blipColour or 5)
    SetBlipScale(b, scale)
    SetBlipDisplay(b, display)
    -- NOT short range: the whole point is that everyone in the match can see
    -- where it is coming down, from wherever they are standing. On the minimap
    -- half this is what keeps it pinned to the edge of the radar when the drop
    -- is off-screen, rather than simply not being drawn.
    SetBlipAsShortRange(b, false)
    BR.Native.blipName(b, A.blipName or 'Airdrop')
    d[key] = b
end

--- Put this drop's markers on the map, if they are not already there.
---
--- IDEMPOTENT, AND CALLED FROM TWO PLACES ON PURPOSE. The record's arrival puts
--- them up immediately, and the render loop re-asserts them every frame the
--- window is open -- so a blip lost to anything at all (another resource
--- sweeping blips, a handle that went bad, a teardown that raced an arrival)
--- comes back on the next frame instead of leaving the match's one airdrop
--- unfindable.
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
    ensureBlip(d, 'blip',     A.blipDisplay or 3, A.blipScale or 1.2)
    ensureBlip(d, 'blipMini', A.blipMinimapDisplay or 5,
               A.blipMinimapScale or 0.8)
end

-- ---------------------------------------------------------------------------
-- The wire
-- ---------------------------------------------------------------------------

RegisterNetEvent(BR.Net.AIRDROP_SYNC)
AddEventHandler(BR.Net.AIRDROP_SYNC, function(rec)
    if type(rec) ~= 'table' then return end
    if type(rec.x) ~= 'number' or type(rec.y) ~= 'number' then return end
    -- tLand IS OPTIONAL NOW, AND REFUSING A RECORD WITHOUT ONE WOULD THROW AWAY
    -- EVERY ANNOUNCEMENT. Since the 200m gate (owner, 2026-08-22) a drop is
    -- SITED and announced first and only starts falling when somebody comes
    -- near, so the first record a client ever sees has a tStart and no landing
    -- time at all. It is a blip and nothing else until the second send arrives.
    if type(rec.tStart) ~= 'number' then return end
    if rec.tLand ~= nil and type(rec.tLand) ~= 'number' then return end

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

-- An un-deleted local object outlives the resource that made it. The flares'
-- own cached state is dropped by client/flares.lua's handler on the same event
-- -- one owner, one teardown.
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
--- @param scale number|nil  a multiple of the model's authored size
local function makePart(model, x, y, z, scale)
    local obj = CreateObjectNoOffset(model, x, y, z, false, false, false)
    if not obj or obj == 0 then return nil end
    -- A falling crate must not shove anyone, and nothing may shove it: its
    -- position is decided by arithmetic, and a collision that moved it would put
    -- this client's crate somewhere no other client's is.
    SetEntityCollision(obj, false, false)
    FreezeEntityPosition(obj, true)
    -- SIZE LAST, because every call above can write the transform matrix and a
    -- scale applied before one of them is a scale that was silently thrown away
    -- (#166). It is re-applied after every heading write in place() for the same
    -- reason -- there is no SetEntityScale in this engine, only the matrix, so
    -- anything that touches the matrix erases it. See BR.Native.propScale, and
    -- read the warning attached to it: nothing has confirmed this renders.
    BR.Native.propScale(obj, scale)
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
--- Ask the audio system to keep this aircraft at full audio LOD, and record
--- exactly what happened -- which is less than anybody would like.
---
--- SET_AUDIO_VEHICLE_PRIORITY (0xE5564483E407F914) returns void and has no
--- getter. There is no native that reads a vehicle's audio priority back, so a
--- receipt is the most that can honestly be produced: whether the binding
--- exists on this build, what value was passed, and whether the call threw.
--- The forum has no thread mentioning this native under either name -- no
--- working examples and no bug reports -- so nothing documents whether it is
--- sticky either. It is applied on the handle at the moment it is created,
--- which is the only moment we certainly have one.
---
--- @param plane integer
--- @param priority integer|nil  nil means "do not ask"
--- @return table  { asked, applied, why }
function BR.Airdrop.setPlaneAudio(plane, priority)
    if priority == nil then
        return { asked = nil, applied = false, why = 'not configured' }
    end
    if not SetAudioVehiclePriority then
        return { asked = priority, applied = false,
                 why = 'SetAudioVehiclePriority does not exist on this build' }
    end
    -- pcall for the same reason the flare's fire path has one: an audio nicety
    -- must not be able to throw inside the spawn thread and cost the match its
    -- aircraft.
    local ok, err = pcall(SetAudioVehiclePriority, plane, priority)
    if not ok then
        return { asked = priority, applied = false,
                 why = 'threw: ' .. tostring(err) }
    end
    return { asked = priority, applied = true,
             why = 'called; the engine reports nothing back' }
end

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

        -- ═══ AUDIO LOD, AND THE OWNER ASKED FOR A WAY TO VALIDATE IT ═══
        --
        -- Owner, 2026-08-22: "I could barely hear it" and then "Sure let's use
        -- the audio priority native, but we need a way to validate it
        -- especially since nobody uses it."
        --
        -- THE NATIVE RETURNS void AND THERE IS NO GETTER. Nothing can read a
        -- vehicle's audio priority back -- not this native, not any other -- so
        -- "we called it" is genuinely all the evidence that exists on this
        -- machine, and pretending otherwise would be the fourth confident guess
        -- in a row. What CAN be recorded honestly is: whether the binding
        -- exists on this build, what value was passed, and whether the call
        -- threw. That is what `d.audio` is, and /brairdrop prints it.
        --
        -- SO THE REAL VALIDATION IS AN A/B THE OWNER CAN HEAR, and it is
        -- `/brairdrop audio <n>` on the client: it re-applies a priority to the
        -- aircraft in flight, so 0 and 2 can be compared on the SAME pass
        -- rather than across two matches. If they sound identical, the native
        -- does nothing here and the altitude change is what did the work.
        --
        -- MAX IS 2, NOT 3. See the config: the enum is NORMAL 0, MEDIUM 1,
        -- MAX 2, HIGH 3, which is not ascending, and a 3 shipped in the belief
        -- it was the maximum would look exactly like the native doing nothing.
        d.audio = BR.Airdrop.setPlaneAudio(plane, A.planeAudioPriority)

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
--- THE FLARES ARE NOT BUILT HERE ANY MORE, and that is the third attempt's
--- shape change. They are lit by place() as the crate falls, through
--- client/flares.lua, because on the default projectile route there is nothing
--- to build ONCE: a fired flare stands where it was lit while the crate falls
--- away from it, so the only way a falling crate has flares beside it is to
--- light a new one on a cadence as it goes. What that leaves behind is a
--- burning column down the descent path -- the "smoke trails as it falls" the
--- owner asked for on 2026-08-21, drawn by the engine rather than by us.
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

        local obj = makePart(model, d.rec.x, d.rec.y, top, A.crateScale)
        SetModelAsNoLongerNeeded(model)
        if not obj then d.spawning = false return end
        SetEntityHeading(obj, d.rec.heading or 0.0)
        d.obj = obj

        -- The canopy. Positioned every frame from the same solver as the crate.
        local chuteModel = GetHashKey(A.chuteModel or 'p_cargo_chute_s')
        if loadModel(chuteModel) and d.rec then
            local chute = makePart(chuteModel, d.rec.x, d.rec.y, top,
                A.chuteScale)
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
--- ═══ AIRDROPS LAND ON ROOFS, AND FOR ONE DAY THIS FUNCTION ANSWERED THAT BY
---     DROPPING THE CRATE THROUGH THEM ═══
---
--- Owner, 2026-08-22: "Somehow these airdrops can happen on top of buildings
--- where peds otherwise cannot access."
---
--- Nothing is wrong with the SITING. The server picks an authored POI, which is
--- a street-level landmark, and this probe then starts hundreds of metres above
--- it and takes the first surface it finds -- which citizenfx's own
--- documentation describes as "the highest ground Z directly beneath" the start
--- point. Over a building that is the ROOF, every time, exactly as designed.
---
--- THE ANSWER WRITTEN THAT DAY WAS: when the navmesh calls the probed surface
--- unreachable, fall to the POI's authored street-level `z` instead. It is a
--- local presentation-only correction, it cannot desync, and it is WRONG, which
--- the next playtest said in one sentence:
---
---   Owner, 2026-08-23: "when it lands on top of a building the loot crate
---   falls through the top of the building as if it doesn't have collisions.
---   This leads to (when the chute is removed) the actual crate prop spawning
---   at ground level inside a building."
---
--- IT DOES NOT HAVE COLLISION -- makePart switches it off, deliberately, so
--- nothing can shove a crate whose position is arithmetic. So aiming it at a
--- height BELOW the surface it is over does not make it land there; it makes it
--- sink through the roof in full view and finish inside the building. A crate
--- standing on a roof is a crate somebody has to find a way up to. A crate
--- inside a sealed building is loot nobody in the match can ever have, and it is
--- the strictly worse of the two.
---
--- ═══ SO THE PROBED SURFACE IS USED, ROOF OR NOT ═══
---
--- The crate is drawn coming to rest on whatever is actually underneath it. The
--- reachability verdict is still taken -- it is worth having on screen, and
--- /brairdrop prints it -- but it is now a DIAGNOSTIC and never a height. This
--- function's one job is that the box on the way down and the box on the ground
--- are in the same place.
---
--- WHAT MOVES UNREACHABLE LOOT IS SOMEWHERE ELSE, and that has always been the
--- design: the sealed crate that lands is an ordinary registry entry, and
--- client/loot.lua's repair round-trip walks it to reachable ground under the
--- server's own 30m bound. That correction is LATERAL -- it looks for somewhere
--- better nearby and leaves the height to the probe there -- which is the only
--- shape of correction that cannot bury a crate. Nothing in this file may lower
--- a z on a reachability opinion, and that is the rule the 2026-08-22 version
--- broke.
--- @param d table
--- @return number
local function groundOf(d)
    local now = GetGameTimer()
    if d.gz and (now - (d.gzAt or 0)) < 3000 then return d.gz end
    d.gzAt = now

    local ok, gz = GetGroundZFor_3dCoord(d.rec.x, d.rec.y,
        (d.rec.gz or 0.0) + (d.rec.alt or 0.0), false)
    if isTrue(ok) then
        -- THE VERDICT IS RECORDED AND NOT ACTED ON. `d.roof` is what /brairdrop
        -- prints and what makes "it came down on the Maze Bank" legible from a
        -- log; the crate still descends to `gz`, because `gz` is where the
        -- world is.
        local reach, why = BR.Native.pedReachable(d.rec.x, d.rec.y, gz)
        d.gz   = gz
        d.roof = (not isTrue(reach)) and why or nil
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
    -- AND THE SIZE BACK, EVERY FRAME, because SetEntityHeading is a matrix write
    -- and a matrix write resets the axis vectors to unit length -- which is
    -- where the scale lives (#166). Without this the crate is 2x for exactly
    -- one frame and authored size for the other 1800 of the descent.
    BR.Native.propScale(d.obj, A.crateScale)

    if d.chute and isTrue(DoesEntityExist(d.chute)) then
        local off = A.chuteOffset or { x = 0.0, y = 0.0, z = 0.1 }
        local cx, cy = BR.AirdropOffsetAt(d.rec, now, off.x, off.y, spin)
        SetEntityCoords(d.chute, cx, cy, z + (off.z or 0.1),
            false, false, false, false)
        SetEntityHeading(d.chute, hdg)
        BR.Native.propScale(d.chute, A.chuteScale)
    end

    -- ═══ THE FLARES, THROUGH THE SITE RATHER THAN BY HAND ═══
    --
    -- The two world positions still come from BR.AirdropOffsetAt and the same
    -- `spin`, so a flare is where the crate's left or right face is at this
    -- millisecond and both ends agree about which way "left" is (that is why
    -- BR.AirdropHeadingAt lives in the solver rather than here). What HAPPENS
    -- at those positions is the route's business: the projectile route lights a
    -- new flare there when its cadence is due, the object route writes the
    -- coordinates of the two it holds.
    --
    -- GetGameTimer, NOT the synced clock, for the cadence. A refire rhythm is
    -- local presentation and must not lurch when the clock estimate is
    -- corrected; the POSITIONS are still solved from the synced clock, which is
    -- the half that has to agree between machines.
    local off = A.flareOffset or { x = 1.1, y = 0.0, z = 0.0 }
    local pos = {}
    for i, side in ipairs({ 1.0, -1.0 }) do
        local fx, fy = BR.AirdropOffsetAt(d.rec, now,
            (off.x or 1.1) * side, off.y, spin)
        pos[i] = { x = fx, y = fy, z = z + (off.z or 0.0), h = hdg }
    end
    d.flares = d.flares or BR.Flare.newSite()
    BR.Flare.updateSite(d.flares, GetGameTimer(),
        A.flareFallRefireMs or 3000, pos)
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
        if BR.AirdropExpired(d.rec, now, A) then
            -- The blip's window is over -- a minute after somebody opened the
            -- crate, or four minutes after the announcement if nobody did
            -- (owner, 2026-08-22). The blip goes and with it the whole entry.
            -- What is left on the ground is ordinary loot with ordinary rules.
            removeDrop(n)
        else
            -- Re-asserted, not assumed. addBlip is idempotent and cheap, and
            -- this is what makes the marker survive anything that removes it
            -- while the drop is still live.
            if BR.AirdropBlipVisible(d.rec, now, A) then
                addBlip(d)
            end

            -- THE PLANE, WHICH LIVES ON ITS OWN CLOCK. It arrives with the ARM,
            -- is overhead at the release, and leaves -- so it is gone long
            -- before the crate is, and it is torn down where it is decided
            -- rather than where the crate is.
            --
            -- ═══ THE CLIENT-SIDE VIEW RADIUS IS GONE, AND SO IS THE PROBLEM IT
            --     SOLVED ═══
            --
            -- It used to ask "am I close enough for this Titan to be worth
            -- building" and skip it otherwise, because the drop happened whether
            -- or not anybody was near. The drop no longer does: the SERVER holds
            -- it until a player is within `armWithin` of the landing point
            -- (owner, 2026-08-22), so by the time a record carries a tRelease at
            -- all, somebody is already standing there. A second radius here
            -- would be a second gate on a question that has been answered, and
            -- the one thing it could still do is hide the aircraft from a
            -- squadmate watching from a ridge a kilometre away.
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
                -- Down. A SEALED crate arrives as an ordinary registry entry
                -- from the server -- the auto-open is gone (owner, 2026-08-22)
                -- and the contents stay inside it until somebody opens it. Both
                -- the crate and its husk are drawn by client/loot.lua at
                -- BR.Config.Airdrop's own scale, so the box does not change size
                -- when it touches down. These props have nothing left to
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
--- `/brairdrop audio <n>` IS THE OWNER'S A/B, and it is the only validation of
--- the audio-priority native that is worth anything. The native returns void
--- and nothing reads it back, so the honest test is not a printed value: it is
--- setting 0 and then 2 on the SAME aircraft, on the same pass, and listening.
--- Across two matches the altitude, the weather and where you are standing have
--- all changed; within one flyover, nothing has but the number.
RegisterCommand('brairdrop', function(_, args)
    if args and args[1] == 'audio' then
        local n = tonumber(args[2])
        if not n then
            print('[br_core] /brairdrop audio <0|1|2|3> -- NORMAL 0, MEDIUM 1, '
                  .. 'MAX 2, HIGH 3. The enum is not in ascending order; MAX is '
                  .. '2. Set 0, listen, set 2, listen.')
            return
        end
        local touched = 0
        for _, d in pairs(drops) do
            if d.plane and isTrue(DoesEntityExist(d.plane)) then
                d.audio = BR.Airdrop.setPlaneAudio(d.plane, n)
                touched = touched + 1
                print(('[br_core] airdrop: audio priority %d on plane %s -- %s')
                    :format(n, tostring(d.plane), tostring(d.audio.why)))
            end
        end
        if touched == 0 then
            print('[br_core] airdrop: no aircraft in the world right now -- run '
                  .. 'this while the Cargobob is on its run-in')
        end
        return
    end

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
            -- tArm, tRelease AND tLand ARE ALL ABSENT ON A WAITING DROP, so they
            -- print as '--' rather than crashing the one command anybody runs
            -- when this breaks.
            local function at(t)
                if type(t) ~= 'number' then return '--' end
                return ('%+.1fs'):format((t - now) / 1000)
            end
            print(('    tStart %s, tArm %s, tRelease %s, tLand %s, blip goes %s')
                :format(at(rec.tStart), at(rec.tArm), at(rec.tRelease),
                        at(rec.tLand), at(BR.AirdropBlipEndsAt(rec, A))))
            -- ═══ ARMED OR STILL WAITING, WHICH IS THE FIRST THING TO ASK NOW ═══
            --
            -- A blip with no plane and no crate is a legitimate state since the
            -- 200m gate (owner, 2026-08-22) and it is exactly what a broken drop
            -- looks like. This line is the difference between "the server is
            -- holding it until somebody gets near" and "something is wrong".
            print(('    %s')
                :format(BR.AirdropArmed(rec)
                    and ('ARMED -- the aircraft is on its way')
                    or  ('WAITING for a player within %.0fm of the landing '
                         .. 'point; nothing flies until then')
                            :format(A.armWithin or 200.0)))
            -- WHICH OF THE OWNER'S TWO RULES IS DECIDING THE BLIP. "1 minute
            -- after the crate is opened" and "no longer than 4 minutes if
            -- unopened" produce the same kind of number and the wrong one is
            -- indistinguishable from the right one on a map.
            print(('    opened %s -- window is %s')
                :format(rec.tOpen and ('%+.1fs'):format((rec.tOpen - now) / 1000)
                                   or 'no',
                        rec.tOpen
                            and ('open + %.0fs'):format((A.blipAfterOpenMs or 60000) / 1000)
                            or  ('%s + %.0fs (cap)'):format(
                                    rec.tArm and 'arm' or 'announce',
                                    (A.blipMaxMs or 240000) / 1000)))
            print(('    released %s, landed %s, blip should be up %s, expired %s')
                :format(tostring(BR.AirdropReleased(rec, now)),
                        tostring(BR.AirdropLanded(rec, now)),
                        tostring(BR.AirdropBlipVisible(rec, now, A)),
                        tostring(BR.AirdropExpired(rec, now, A))))
            local px, py = BR.AirdropPlaneAt(rec, now, A)
            print(('    plane should be up %s, at (%.0f, %.0f)')
                :format(tostring(BR.AirdropPlaneVisible(rec, now, A)), px, py))
            -- THE ROOFTOP VERDICT for the point the crate is falling to. `roof`
            -- is set by groundOf when the navmesh refuses the probed ground --
            -- and since 2026-08-23 that is ALL it is. The crate comes down onto
            -- the probed surface either way; a verdict that moved the height is
            -- how a crate came to sink through a roof and finish inside the
            -- building. Anything unreachable is walked somewhere better by
            -- client/loot.lua's repair round-trip, laterally, once it lands.
            print(('    ground %.1f (POI authored %.1f)%s')
                :format(d.gz or 0.0, rec.gz or 0.0,
                        d.roof and (' -- navmesh calls this unreachable: '
                                    .. tostring(d.roof)
                                    .. '; the crate still lands on it, and the '
                                    .. 'LOOT_FIX round-trip moves the entry')
                               or ''))
        end
        -- BOTH SURFACES, SEPARATELY. "The blip is missing" is now two different
        -- reports depending on which map they were looking at, and the sizes
        -- are the owner's two tuning knobs -- so the line names the handle, the
        -- display id and the scale of each rather than one blip's.
        print(('    big-map blip %s exists %s (display %d, scale %.2f), '
               .. 'minimap blip %s exists %s (display %d, scale %.2f), sprite %d')
            :format(tostring(d.blip),
                    tostring(d.blip and isTrue(DoesBlipExist(d.blip))),
                    A.blipDisplay or 3, A.blipScale or 1.2,
                    tostring(d.blipMini),
                    tostring(d.blipMini and isTrue(DoesBlipExist(d.blipMini))),
                    A.blipMinimapDisplay or 5, A.blipMinimapScale or 0.8,
                    A.blipSprite or 161))
        print(('    plane %s, pilot %s, crate %s (x%.1f), canopy %s (x%.1f)')
            :format(tostring(d.plane), tostring(d.pilot), tostring(d.obj),
                    A.crateScale or 1.0, tostring(d.chute), A.chuteScale or 1.0))
        -- ═══ THE AUDIO RECEIPT, WHICH IS ALL THERE IS ═══
        --
        -- Owner, 2026-08-22: "we need a way to validate it especially since
        -- nobody uses it." SET_AUDIO_VEHICLE_PRIORITY returns void and there is
        -- no getter for it, so this line says what was asked for and whether
        -- the call went through, and does NOT claim the engine agreed. The A/B
        -- is `/brairdrop audio <n>` while the aircraft is up.
        local au = d.audio
        print(('    audio priority: asked %s, applied %s -- %s')
            :format(au and tostring(au.asked) or 'nothing yet',
                    au and tostring(au.applied) or 'false',
                    au and tostring(au.why) or 'the plane has not been built'))
    end
    if not any then
        print('  no drop record on this client -- nothing has been announced, '
              .. 'or it has already expired')
    end

    -- ═══ THE FLARE LINE IS THE ONE THAT COST TWO ROUNDS ═══
    --
    -- It used to print "flares 2" whether or not either of them had a running
    -- particle, which is the same silence the owner reported into. It now
    -- reports the ROUTE and, on the projectile route, the number of flares this
    -- client has actually lit -- because a projectile has no handle and a
    -- counter is the only evidence that exists. A count that stays at zero
    -- while a drop is falling is a real answer; so is a count that climbs while
    -- the sky stays dark, and they are different bugs.
    local st = BR.Flare.status()
    print(('  flares: route %s, lit this session %d (failed %d)')
        :format(tostring(st.route), st.fired, st.failed))
    -- ═══ AND THEY ONLY EXIST WHILE SOMETHING IS FALLING (owner, 2026-08-23) ═══
    --
    -- This used to print a third line about the pair standing on the landed
    -- box. There is no such pair any more: the owner watched the husk collect
    -- flares forever and asked for that half to go, keeping only the column the
    -- descent leaves behind. So a count that climbs while a crate is in the air
    -- and then STOPS is the correct reading, and a count still climbing after
    -- touchdown is the bug this line would catch.
    local live = {}
    for n, d in pairs(drops) do
        for i, f in ipairs((d.flares or {}).flares or {}) do
            live[#live + 1] = ('drop %d #%d obj %s fx %s%s'):format(n, i,
                tostring(f.obj), tostring(f.fx),
                BR.Flare.live(f.fx) and ' live' or ' DEAD')
        end
    end
    print(('    object-route props on the falling crate: %d%s')
        :format(#live,
                #live > 0 and (' -- ' .. table.concat(live, ', '))
                          or ' (none, which is what the projectile route holds)'))
end, false)
