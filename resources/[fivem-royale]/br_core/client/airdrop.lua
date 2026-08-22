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

--- [n] = { rec, obj, chute, blip, gz, gzAt, spawning, warned }
local drops = {}

-- ---------------------------------------------------------------------------
-- Teardown
-- ---------------------------------------------------------------------------

local function dropProps(d)
    -- The chute goes first: it is attached to the crate, and deleting the
    -- parent out from under an attachment is how you end up with a canopy
    -- hanging in the sky with nothing under it.
    if d.chute and isTrue(DoesEntityExist(d.chute)) then DeleteEntity(d.chute) end
    if d.obj and isTrue(DoesEntityExist(d.obj)) then DeleteEntity(d.obj) end
    d.chute, d.obj = nil, nil
end

local function removeDrop(n)
    local d = drops[n]
    if not d then return end
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

    -- THE BLIP GOES UP THE MOMENT THE DROP IS ANNOUNCED, at the POI's nominal
    -- height -- the pause map only cares about x/y, and the ground probe has
    -- almost certainly not run yet for a point kilometres away.
    local b = AddBlipForCoord(rec.x, rec.y, rec.gz or 0.0)
    SetBlipSprite(b, A.blipSprite or 161)
    SetBlipColour(b, A.blipColour or 5)
    SetBlipScale(b, A.blipScale or 1.2)
    -- NOT short range: the whole point is that everyone in the match can see
    -- where it is coming down, from wherever they are standing.
    SetBlipAsShortRange(b, false)
    BR.Native.blipName(b, A.blipName or 'Airdrop')
    d.blip = b
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
-- The prop
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

--- Build the crate and hang the canopy off it.
---
--- THE CANOPY IS ROCKSTAR'S OWN, and its offset and attach flags are theirs
--- verbatim. GTA Online's crate drop (am_crate_drop) and ammo drop
--- (am_ammo_drop) both do exactly this: a separate `p_cargo_chute_s` object
--- attached at (0, 0, 0.1) with the deploy anim played once. There is no native
--- that does any of it -- researched before this was written, because the
--- alternative was writing code that fights the engine.
---
--- NOT BR.Config.Drop.parachuteModel. That is `p_parachute1_mp_s`, the
--- player's back-worn canopy -- a different asset for a different job.
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

        local gz = d.gz or d.rec.gz or 0.0
        local obj = CreateObjectNoOffset(model, d.rec.x, d.rec.y,
            gz + (d.rec.alt or 0.0), false, false, false)
        SetModelAsNoLongerNeeded(model)
        if not obj or obj == 0 then d.spawning = false return end

        -- A falling crate must not shove anyone, and nothing may shove it: its
        -- position is decided by arithmetic, and a collision that moved it
        -- would put this client's crate somewhere no other client's is.
        SetEntityCollision(obj, false, false)
        FreezeEntityPosition(obj, true)
        SetEntityHeading(obj, d.rec.heading or 0.0)
        d.obj = obj

        local chuteModel = GetHashKey(A.chuteModel or 'p_cargo_chute_s')
        if loadModel(chuteModel) and isTrue(DoesEntityExist(obj)) then
            local off = A.chuteOffset or { x = 0.0, y = 0.0, z = 0.1 }
            local chute = CreateObjectNoOffset(chuteModel, d.rec.x, d.rec.y,
                gz + (d.rec.alt or 0.0), false, false, false)
            SetModelAsNoLongerNeeded(chuteModel)
            if chute and chute ~= 0 then
                SetEntityCollision(chute, false, false)
                -- Attached to the CRATE, so moving the crate moves both and
                -- there is one thing to drive rather than two to keep in step.
                AttachEntityToEntity(chute, obj, 0,
                    off.x or 0.0, off.y or 0.0, off.z or 0.1,
                    0.0, 0.0, 0.0, false, false, false, false, 2, true)
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
        if not BR.AirdropBlipVisible(d.rec, now, A.blipLingerMs) then
            -- One minute past touchdown: the blip goes, and with it the whole
            -- entry. What is left on the ground is ordinary loot with ordinary
            -- rules.
            removeDrop(n)
        elseif BR.AirdropLanded(d.rec, now) then
            -- Down. The husk and the twelve items arrive as registry entries
            -- from the server; this prop has nothing left to represent.
            dropProps(d)
        else
            if not d.obj and not d.spawning then
                groundOf(d)
                spawn(d)
            end
            if d.obj and isTrue(DoesEntityExist(d.obj)) then
                local gz = groundOf(d)
                local t  = BR.AirdropProgress(d.rec, now)
                SetEntityCoords(d.obj, d.rec.x, d.rec.y,
                    gz + BR.AirdropHeightAt(d.rec, now), false, false, false, false)
                -- A slow yaw. A crate under a canopy that never turns reads as
                -- a prop sliding down an invisible rail.
                SetEntityHeading(d.obj, (d.rec.heading or 0.0) + t * 30.0)
            end
        end
    end
end)
