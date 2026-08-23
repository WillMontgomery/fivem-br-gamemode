-- Aerial supply drops, client half: the plane, the crate, its canopy, its two
-- flares, and the blip.
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

--- Is this a looped-particle handle that is actually running?
---
--- ═══ THE FAILURE VALUE IS -1, NOT 0, AND CHECKING FOR 0 SHIPPED A LIE ═══
---
--- The first flare attempt stored the handle when it was `~= 0`, on the
--- reasoning that 0 is the falsy-looking value Lua would wave through. That is
--- the right instinct aimed at the wrong number: Cfx's own ParticleEffect
--- wrapper documents the handle as "-1 when this ParticleEffect is not active",
--- and its start path is
---
---     Handle = StartParticleFxLoopedOnEntity(...)
---     if IsActive then return true end
---     Handle = -1; return false
---
--- with `IsActive` being `Handle ~= -1 and DoesParticleFxLoopedExist(Handle)`.
--- So there are TWO ways to fail and the old check caught neither: -1 was
--- stored as a live handle, and a handle that came back non-(-1) but dead was
--- never questioned. Either way the diagnostic said "flares 2" and the sky was
--- empty.
---
--- BOTH TESTS, IN THE ORDER CFX DOES THEM. DoesParticleFxLoopedExist is guarded
--- because a build without it must degrade to the handle test rather than
--- error, and because the test rig does not stub every native in the engine.
--- @param fx any
--- @return boolean
--- BOTH SENTINELS ARE REFUSED, and 0 stays refused deliberately. Cfx's looped
--- wrapper compares against -1 while its NON-looped one compares `> 0`, so the
--- two halves of their own code disagree about which number means failure. When
--- the engine's own bindings cannot agree, treating either as a handle is a
--- guess with a known cost -- we have already paid it once -- and refusing both
--- costs at most one improbable legitimate zero.
local function fxLive(fx)
    if fx == nil or fx == false then return false end
    if fx == -1 or fx == 0 then return false end
    if DoesParticleFxLoopedExist then
        return isTrue(DoesParticleFxLoopedExist(fx))
    end
    return true
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
        -- Only handles that were ever live are stored (see fxLive), so this is
        -- a nil check rather than a validity one -- but stopping an effect that
        -- has already ended is harmless and stopping one that has not is the
        -- whole point.
        if f.fx ~= nil then StopParticleFxLooped(f.fx, false) end
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
    -- ...AND THE RESOLVED FLARE MODEL GOES WITH IT. It is cached for the
    -- session because the answer cannot change within one, but a restart is a
    -- new session -- and the config it was resolved from may have been edited
    -- in between, which is the whole point of restarting.
    BR.Airdrop.forgetFlareModel()
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

--- The first flare model in the config list that this build will actually load.
---
--- ═══ THE FIRST ATTEMPT NAMED A MODEL THAT DOES NOT EXIST ═══
---
--- It asked for `prop_flare_01a`. There is a `prop_flare_01` and a
--- `prop_flare_01b` in the game's object list and there is no `_01a` -- so
--- IsModelValid refused it, loadModel returned false, and the whole flare
--- branch (props AND particles, both behind that one `if`) never ran. No flare,
--- no smoke, no error, and a diagnostic that printed "flares 0" only if anyone
--- had thought to look. That is precisely the reported symptom.
---
--- SO A NAME IS A CANDIDATE NOW, NOT A PROMISE. Three verified names in
--- preference order; the first that loads wins; and if NONE load this says so
--- once, loudly, because a silent nothing is what cost the round. Cached after
--- the first resolve -- the answer cannot change within a session.
--- @return integer|nil model
--- @return string|nil name
local flareModelCache, flareModelName, flareModelTried = nil, nil, false
local function flareModel()
    if flareModelTried then return flareModelCache, flareModelName end
    flareModelTried = true

    local names = A.flareProps
    -- A bare string is still accepted, so a config edited back to one name is
    -- a working config rather than a crash.
    if type(names) == 'string' then names = { names } end
    if type(names) ~= 'table' or #names == 0 then
        print('[br_core] airdrop: no flare prop configured (flareProps) -- '
              .. 'the crate will fall without flares')
        return nil, nil
    end

    for _, n in ipairs(names) do
        local m = GetHashKey(n)
        if loadModel(m) then
            flareModelCache, flareModelName = m, n
            print(('[br_core] airdrop: flare prop is %s'):format(n))
            return m, n
        end
    end

    print(('[br_core] airdrop: NONE of the flare props would load (%s) -- '
           .. 'the crate will fall without flares. Check the names against an '
           .. 'object dump; this is exactly how the 2026-08-21 flares shipped '
           .. 'invisible.'):format(table.concat(names, ', ')))
    return nil, nil
end

--- Drop the cached flare-model answer, so the next drop resolves it again.
---
--- Called on resource stop and nowhere else. A restart is a new session and the
--- config may have been edited across it -- which is the reason anybody
--- restarts a resource while tuning this.
function BR.Airdrop.forgetFlareModel()
    flareModelCache, flareModelName, flareModelTried = nil, nil, false
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

--- How far this client is from the drop point, right now, in metres.
---
--- Its own ped, never a roster position: this is a question about where THIS
--- screen is, and it is asked once a frame while a plane might be worth
--- building.
--- @param d table
--- @return number
local function distanceToDrop(d)
    if not d.rec then return math.huge end
    local ped = PlayerPedId()
    if not ped or ped == 0 then return math.huge end
    local p = GetEntityCoords(ped)
    if not p then return math.huge end
    return BR.Dist(p.x, p.y, d.rec.x, d.rec.y)
end

--- Is this client close enough for a delivery plane to be worth existing?
---
--- ═══ A PRESENTATION DECISION, MADE PER CLIENT, THAT CHANGES NO SCHEDULE ═══
---
--- Owner, 2026-08-22: "We should make it so the plane doesn't spawn until a
--- player is within a reasonable radius to be able to see the event happen",
--- because "if nobody is nearby, they don't get to see the cool drop, they just
--- arrive and the thing is there."
---
--- The plane is LOCAL and solved from the published record against the synced
--- clock, so this is a question each client answers about ITSELF: the drop
--- happens on the server's clock whether anyone watches, and a client that
--- answers no simply does not build a Titan and a pilot it could not see. There
--- is no message, no vote and nothing the server needs to know.
---
--- AND IT NEVER GATES THE CRATE, which is the half that would break joining
--- late. The descent is a pure function of the record and has to stay one: a
--- client that walks into view twenty seconds into the fall must see the box
--- exactly where the clock says the box is, so the crate is built at the
--- release for everyone holding the record, wherever they are standing.
--- @param d table
--- @return boolean
local function planeWorthBuilding(d)
    local r = A.planeViewRadius
    -- No radius configured is the old behaviour -- everybody gets a plane --
    -- rather than nobody, because a missing number must not delete a feature.
    if not r or r <= 0.0 then return true end
    return distanceToDrop(d) <= r
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

        -- The flares, left and right. One offset, two signs.
        local off = A.flareOffset or { x = 1.1, y = 0.0, z = 0.0 }
        local fModel = flareModel()
        if fModel and d.rec then
            local ptfxReady = loadPtfx(A.flarePtfxAsset)
            d.flares = {}
            for _, side in ipairs({ 1.0, -1.0 }) do
                -- SCALED, because the first attempt drew a one-foot road flare
                -- on a crate 260 metres up and the owner reported seeing no
                -- flares AT ALL -- which the prop's size explains on its own,
                -- before any particle is involved.
                local f = makePart(fModel, d.rec.x, d.rec.y, top,
                    A.flareScale)
                if f then
                    local rec = { obj = f, ox = (off.x or 1.1) * side }
                    if ptfxReady and A.flarePtfxName then
                        -- USE_PARTICLE_FX_ASSET IS PER CALL, NOT PER SESSION --
                        -- its own alias is _SET_PTFX_ASSET_NEXT_CALL, and Cfx's
                        -- wrapper re-asserts it before every one of its start
                        -- calls. Immediately before each start or the effect
                        -- resolves against whatever asset was last named.
                        UseParticleFxAsset(A.flarePtfxAsset)
                        local fx = StartParticleFxLoopedOnEntity(
                            A.flarePtfxName, f,
                            0.0, 0.0, 0.0,
                            0.0, 0.0, 0.0,
                            A.flarePtfxScale or 1.0,
                            false, false, false)
                        -- STORED ONLY IF IT IS ACTUALLY RUNNING. See fxLive:
                        -- the failure value is -1, not 0, and a handle that is
                        -- neither can still be dead.
                        if fxLive(fx) then
                            rec.fx = fx
                        else
                            -- SAID OUT LOUD, ONCE PER DROP. A silent particle
                            -- failure is what shipped last time: the flares
                            -- counted 2, the handles looked fine and the sky
                            -- was empty, and there was nothing anywhere that
                            -- could tell "never started" from "started and
                            -- invisible".
                            if not d.fxWarned then
                                d.fxWarned = true
                                print(('[br_core] airdrop: flare ptfx %s/%s would not start (handle %s) -- try /brflare')
                                    :format(tostring(A.flarePtfxAsset),
                                            tostring(A.flarePtfxName),
                                            tostring(fx)))
                            end
                        end
                    end
                    d.flares[#d.flares + 1] = rec
                end
            end
            -- NOT released: flareModel() caches the hash for the session and a
            -- second drop would find it unloaded. One model resident is cheaper
            -- than re-streaming it, and it is the same call the two crate models
            -- already get in client/loot.lua.
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
--- ═══ AND IT IS WHY AIRDROPS LAND ON ROOFS ═══
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
--- SO WHEN THE ANSWER IS A ROOF, THE AUTHORED HEIGHT IS THE BETTER ONE. A POI's
--- `z` is a hand-walked street-level number (config/map.lua), and the crate has
--- collision switched off, so it simply falls past the roof to the ground the
--- POI was authored at. That is a LOCAL, PRESENTATION-ONLY correction with no
--- lateral movement -- the record is untouched, nothing crosses the wire, and
--- every client that can answer the question at all answers it the same way,
--- so the "no two machines can disagree" property this whole file rests on is
--- unchanged.
---
--- WHAT ACTUALLY MOVES THE LOOT IS SOMEWHERE ELSE, and deliberately: the sealed
--- crate that lands is an ordinary registry entry, and client/loot.lua's repair
--- round-trip walks it to reachable ground under the server's own 30m bound.
--- This function only decides where the box is DRAWN on the way down.
--- @param d table
--- @return number
local function groundOf(d)
    local now = GetGameTimer()
    if d.gz and (now - (d.gzAt or 0)) < 3000 then return d.gz end
    d.gzAt = now

    local ok, gz = GetGroundZFor_3dCoord(d.rec.x, d.rec.y,
        (d.rec.gz or 0.0) + (d.rec.alt or 0.0), false)
    if isTrue(ok) then
        local reach, why = BR.Native.pedReachable(d.rec.x, d.rec.y, gz)
        if reach then
            d.gz, d.roof = gz, nil
        else
            -- The authored height, not the last one we had: a stale `d.gz` from
            -- an earlier frame is just as likely to be the roof.
            d.gz, d.roof = d.rec.gz or 0.0, why
        end
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

            -- THE PLANE, WHICH LIVES ON ITS OWN CLOCK. It arrives with the
            -- announcement, is overhead at the release, and leaves -- so it is
            -- gone long before the crate is, and it is torn down where it is
            -- decided rather than where the crate is.
            if BR.AirdropPlaneVisible(d.rec, now, A) then
                -- ...AND ONLY FOR SOMEBODY WHO COULD SEE IT (owner, 2026-08-22:
                -- "the plane doesn't spawn until a player is within a
                -- reasonable radius to be able to see the event happen").
                --
                -- ASKED HERE RATHER THAN AT THE ANNOUNCEMENT, so a player who
                -- was two kilometres out when the notification landed and has
                -- driven into range since gets the plane built wherever the
                -- clock says it is by then. The route is a pure function of the
                -- record, so a plane created mid-approach is in exactly the
                -- right place -- gating this once at tStart would have punished
                -- the players who ran towards it.
                --
                -- IT GATES THE SPAWN AND NOTHING ELSE. A plane already in the
                -- air is never torn down for distance: it is a hundred metres
                -- from where it was last frame, and deleting an aircraft
                -- somebody is watching because they crossed a config line
                -- would be a worse artefact than the one this fixes.
                if not d.plane and not d.flying and planeWorthBuilding(d) then
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
            print(('    tStart %+.1fs, tRelease %+.1fs, tLand %+.1fs, blip goes %+.1fs')
                :format((rec.tStart - now) / 1000,
                        ((rec.tRelease or rec.tStart) - now) / 1000,
                        (rec.tLand - now) / 1000,
                        (BR.AirdropBlipEndsAt(rec, A) - now) / 1000))
            -- WHICH OF THE OWNER'S TWO RULES IS DECIDING THE BLIP. "1 minute
            -- after the crate is opened" and "no longer than 4 minutes if
            -- unopened" produce the same kind of number and the wrong one is
            -- indistinguishable from the right one on a map.
            print(('    opened %s -- window is %s')
                :format(rec.tOpen and ('%+.1fs'):format((rec.tOpen - now) / 1000)
                                   or 'no',
                        rec.tOpen
                            and ('open + %.0fs'):format((A.blipAfterOpenMs or 60000) / 1000)
                            or  ('announce + %.0fs (cap)'):format((A.blipMaxMs or 240000) / 1000)))
            print(('    released %s, landed %s, blip should be up %s, expired %s')
                :format(tostring(BR.AirdropReleased(rec, now)),
                        tostring(BR.AirdropLanded(rec, now)),
                        tostring(BR.AirdropBlipVisible(rec, now, A)),
                        tostring(BR.AirdropExpired(rec, now, A))))
            local px, py = BR.AirdropPlaneAt(rec, now, A)
            -- THE RADIUS GATE, PRINTED AS BOTH HALVES. "no plane" is now a
            -- legitimate outcome as well as a bug, and the only way to tell
            -- those apart from a chair is to see the distance next to the
            -- threshold that rejected it.
            print(('    plane should be up %s, at (%.0f, %.0f); I am %.0fm away, radius %.0fm -> %s')
                :format(tostring(BR.AirdropPlaneVisible(rec, now, A)), px, py,
                        distanceToDrop(d), A.planeViewRadius or 0.0,
                        planeWorthBuilding(d) and 'build it' or 'too far, no plane'))
            -- THE ROOFTOP VERDICT for the point the crate is falling to. `roof`
            -- is set by groundOf when the navmesh refuses the probed ground.
            print(('    ground %.1f (POI authored %.1f)%s')
                :format(d.gz or 0.0, rec.gz or 0.0,
                        d.roof and (' -- probe rejected as unreachable: '
                                    .. tostring(d.roof)
                                    .. ', falling to the authored height')
                               or ''))
        end
        print(('    blip handle %s, exists %s, sprite %d')
            :format(tostring(d.blip),
                    tostring(d.blip and isTrue(DoesBlipExist(d.blip))),
                    A.blipSprite or 161))
        -- ═══ THE FLARE LINE IS THE ONE THAT COST A ROUND ═══
        --
        -- It used to print "flares 2" whether or not either of them had a
        -- running particle, which is the same silence the owner reported into.
        -- Each flare now says whether its effect is ALIVE, which separates
        -- "the start failed" from "the start worked and I cannot see it" --
        -- two different bugs with one symptom.
        local fl = {}
        for i, f in ipairs(d.flares or {}) do
            fl[#fl + 1] = ('%d:%s%s'):format(i, tostring(f.fx),
                fxLive(f.fx) and ' live' or ' DEAD')
        end
        print(('    plane %s, pilot %s, crate %s (x%.1f), canopy %s (x%.1f)')
            :format(tostring(d.plane), tostring(d.pilot), tostring(d.obj),
                    A.crateScale or 1.0, tostring(d.chute), A.chuteScale or 1.0))
        print(('    flares %d (prop x%.1f, ptfx %s/%s x%.1f): %s')
            :format(#(d.flares or {}), A.flareScale or 1.0,
                    tostring(A.flarePtfxAsset), tostring(A.flarePtfxName),
                    A.flarePtfxScale or 1.0,
                    #(d.flares or {}) > 0 and table.concat(fl, ', ') or 'none'))
    end
    if not any then
        print('  no drop record on this client -- nothing has been announced, '
              .. 'or it has already expired')
    end
end, false)

-- ---------------------------------------------------------------------------
-- The flare bench
-- ---------------------------------------------------------------------------

--- The last test flare, so a second /brflare replaces rather than litters.
local bench = nil

--- Start any particle effect on a flare prop in front of the player, and say
--- whether it is actually running.
---
--- ═══ WRITTEN BECAUSE THE FLARES ARE THE SECOND ATTEMPT ═══
---
--- The first shipped `core` / `proj_flare_trail` at scale 1.0, taken from a
--- published dump, and the owner saw nothing. Everything about why is still a
--- hypothesis (see the long note in br_lib/config/airdrop.lua): the prop may
--- have been too small, the effect may need a velocity a frozen prop does not
--- have, the handle check was testing the wrong failure value. NONE of that can
--- be settled from outside a running client, and the cost of guessing again is
--- another whole playtest round.
---
--- So this puts the question on the ground, three metres away, at eye level,
--- where it takes ten seconds to answer:
---
---   /brflare                          the committed asset/effect/scale
---   /brflare <asset> <name> [scale]   any other pair, e.g.
---                                     /brflare core proj_flare_trail 2
---   /brflare off                      clear it
---
--- IT PRINTS WHETHER THE HANDLE IS LIVE, which is the distinction that was
--- missing: a dead handle means the effect never started and the asset or the
--- name is wrong; a LIVE handle with nothing visible means it started and is
--- invisible, which is a scale or a velocity problem and a completely different
--- fix. Verified names to try are listed in the config.
---
--- The prop is frozen, collision-off and non-networked exactly as a real flare
--- is, so what renders here is what would render on the crate.
local function clearBench()
    if not bench then return end
    if bench.fx ~= nil then StopParticleFxLooped(bench.fx, false) end
    if bench.obj and isTrue(DoesEntityExist(bench.obj)) then
        DeleteEntity(bench.obj)
    end
    bench = nil
end

RegisterCommand('brflare', function(_, args)
    local asset = args[1] and tostring(args[1]) or A.flarePtfxAsset
    local name  = args[2] and tostring(args[2]) or A.flarePtfxName
    local scale = tonumber(args[3]) or A.flarePtfxScale or 1.0

    clearBench()
    if asset == 'off' then
        print('[br_core] flare bench cleared')
        return
    end

    local ped = PlayerPedId()
    local p   = GetEntityCoords(ped)
    local h   = math.rad(GetEntityHeading(ped) or 0.0)
    -- Three metres in front, at chest height: close enough to see a wisp, far
    -- enough that a plume does not fill the screen.
    local x, y, z = p.x - math.sin(h) * 3.0, p.y + math.cos(h) * 3.0, p.z + 1.0

    -- WHICH FLARE MODELS THIS BUILD HAS, PRINTED EVERY TIME. This is the check
    -- that was never run: the shipped name was `prop_flare_01a`, which is not a
    -- model, and nothing anywhere said so. A fourth candidate can be added to
    -- the config and tested by running this again.
    print('=== flare bench ===')
    local names = A.flareProps
    if type(names) == 'string' then names = { names } end
    for _, n in ipairs(names or {}) do
        local h = GetHashKey(n)
        print(('  model %-18s valid %s'):format(n,
            tostring(isTrue(IsModelValid(h)))))
    end

    local model, modelName = flareModel()
    if not model then
        print('  NO FLARE MODEL LOADS -- that is the answer, and it is the '
              .. 'whole 2026-08-21 bug. Nothing below matters until a name here '
              .. 'is a real object.')
        return
    end
    local obj = makePart(model, x, y, z, A.flareScale)
    if not obj then
        print('  the prop would not spawn')
        return
    end
    bench = { obj = obj }

    print(('  prop %s at x%.2f, effect %s / %s at x%.2f'):format(
        tostring(modelName), A.flareScale or 1.0,
        tostring(asset), tostring(name), scale))

    if not loadPtfx(asset) then
        print(('  asset %s WOULD NOT LOAD -- that is the answer: the name is '
               .. 'not a particle asset on this build'):format(tostring(asset)))
        return
    end
    print(('  asset %s loaded'):format(tostring(asset)))

    UseParticleFxAsset(asset)
    local fx = StartParticleFxLoopedOnEntity(name, obj,
        0.0, 0.0, 0.0, 0.0, 0.0, 0.0, scale, false, false, false)
    if fxLive(fx) then
        bench.fx = fx
        print(('  handle %s -- LIVE. If you cannot see it, the effect is '
               .. 'rendering and the problem is size or velocity, not the name.')
            :format(tostring(fx)))
    else
        print(('  handle %s -- DEAD. The effect did not start: %s is not an '
               .. 'effect in %s, or it is not loopable.')
            :format(tostring(fx), tostring(name), tostring(asset)))
    end
    print('  paste into br_lib/config/airdrop.lua:')
    print(('    flarePtfxAsset = \'%s\','):format(tostring(asset)))
    print(('    flarePtfxName  = \'%s\','):format(tostring(name)))
    print(('    flarePtfxScale = %.2f,'):format(scale))
    print('  /brflare off to clear it')
end, false)

-- A bench flare is an un-deleted local object like any other.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearBench()
end)
