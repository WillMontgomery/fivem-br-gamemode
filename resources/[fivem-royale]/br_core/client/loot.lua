-- World loot: props, glow, prompts and pickup.
--
-- EVERY OBJECT HERE IS LOCAL AND NON-NETWORKED. CreateObjectNoOffset with
-- isNetwork = false is the entire basis of the design -- a match lays out
-- ~1900 items, and 1900 networked entities would end the server before the
-- first circle closed. The consequence is that this file is presentation over
-- a server-owned registry: deleting a prop locally does not pick anything up,
-- and only LOOT_GONE removes an entry.
--
-- SUBSCRIPTION IS 3x3 CELLS (768m), PROPS ARE 90m. Those are deliberately
-- different numbers. The registry is cheap and wants to be ahead of the
-- player; objects are not, and want to exist only where they can be seen.
--
-- NOTHING IS HARDCODED TO A KEY. Pickup runs off BR.Keys ('interact'), which
-- is a RegisterKeyMapping binding the player can rebind in the pause menu, and
-- the prompt renders whatever they bound it to.

BR = BR or {}
BR.Loot = BR.Loot or {}

--- How many containers this player has opened THIS MATCH.
---
--- Drives the crate glow, which switches off once it reaches
--- BR.Config.Loot.shineOpenLimit: the shine is teaching "these boxes open",
--- and past that it is a permanent orange marker on scenery (user call,
--- 2026-08-06). Reset with the match, so every round starts by teaching it
--- again -- the next round may be somebody else's first.
BR.Loot.openedCount = 0

--- How many times the crate drag has actually scaled a velocity. Printed by
--- /brloot: it is the difference between "the drag is not running" and "the
--- drag is not strong enough", which cost a round of guessing to tell apart.
BR.Loot.dragTicks = 0

local L = BR.Config.Loot

local entries   = {}      -- [id] = entry, with prop bookkeeping attached
local byObject  = {}      -- [objectHandle] = id, so a ray hit resolves instantly
local queue     = {}      -- ids waiting for a model
local queued    = {}      -- [id] = true, so the queue cannot double up
local draining  = false
local myCell    = nil     -- last cell reported to the server
local claimedAt = {}      -- [id] = gametimer, to stop a held key spamming claims
local reported  = {}      -- [id] = true, entries already sent back as misplaced

--- Where a container's prop ACTUALLY ended up, by entry id.
---
--- Kept outside `entries` on purpose: opening a crate mutates the entry in
--- place on the server (kind 'chest' -> 'husk') and the client replaces its
--- whole entry table with the new payload, so anything stored on the entry is
--- gone by the time the husk needs it. This survives that, and it is what lets
--- the open crate appear exactly where the sealed one was rather than back at
--- the position it was generated at, upright, having visibly teleported (user,
--- 2026-08-06).
---
--- { x, y, z, rx, ry, rz } -- a full pose, because a crate that has been shunted
--- or has settled on a slope has pitch and roll worth keeping too.
local poses = {}

local hold = { id = nil, from = 0 }
local lastPrompt = { id = nil, hold = nil }

-- Which crate is currently the one that shines, and when that was last
-- decided. Held across frames so the search does not have to run in every one.
local shineId = nil
local shineAt = 0

--- Props that are no longer loot, only scenery on its way out.
---
--- THE ENTRY DIES THE INSTANT THE SERVER CONFIRMS THE CLAIM. That is the whole
--- design, and it is the user's (2026-08-08): the moment an item is taken it
--- stops being targetable, stops prompting and leaves the registry -- so
--- nothing that follows can be interacted with, mistargeted, or double-claimed.
--- What is left is a prop with no function, and a prop with no function is
--- free to be animated however it likes.
---
--- Which sidesteps the trap in doing this the other way round: keeping the
--- entry alive for the length of the animation would mean a window in which
--- the player can still see a prompt for something that is already in their
--- inventory.
---
--- Swept by forgetAll() and onResourceStop like everything else that holds an
--- object handle -- an undeleted local object outlives the resource.
--- @type table<integer, table>
local retiring = {}
local retireSeq = 0

--- Until when the spawn worker may build props faster than its steady rate.
--- Set on the first cell subscription of a life -- i.e. on landing. See
--- drain() for why the trickle is wrong at exactly that moment.
local burstUntil = 0

--- The entry whose prop currently has SetEntityDrawOutline switched on.
---
--- TRACKED SEPARATELY FROM shineId, and that is the whole fix for crates that
--- glowed orange forever (user, 2026-08-08: "unopened chests still glow after
--- they've opened a couple"). Turning the outline OFF used to live inside the
--- render loop's per-entry branch, which is guarded by `d2 <= glow2 and not
--- isHusk(e) and e.gzOk`. Every one of those guards is a way to leave a lit
--- crate lit:
---
---   * WALK AWAY fast enough and the entry falls outside glow2 on the very
---     next pass, so the branch that would clear it never runs again;
---   * OPEN IT and it becomes a husk, which the branch skips by design --
---     so the crate you just emptied keeps shining;
---   * open two and shineId goes nil for the rest of the match, which stops
---     anything NEW lighting up but never revisits what already is.
---
--- The leak accumulates: every crate ever approached and left stays orange,
--- which is exactly "they all glow and opening them does not stop it". One
--- id, cleared unconditionally, cannot accumulate.
local outlinedId = nil

--- Switch the outline off wherever it currently is.
--- @param entriesTbl table
local function clearOutline(entriesTbl)
    if not outlinedId then return end
    local e = entriesTbl[outlinedId]
    outlinedId = nil
    if e and e.obj and DoesEntityExist(e.obj) then
        SetEntityDrawOutline(e.obj, false)
    end
end

-- Crates THIS player opened. The reveal sound is for the person who did the
-- opening, not for everyone standing near it (user, 2026-08-05) -- and the
-- authoritative "it opened" signal arrives for every subscriber alike, so the
-- distinction has to be remembered locally.
local claimedByMe = {}

local PROP_MAX = 160      -- hard ceiling on live objects, whatever the density

-- The crate pair, kept streamed for the whole session: they are the
-- most-spawned models in the game and the sealed->open swap must be instant.
local CRATE_MODEL      = GetHashKey(L.chestProp)
local CRATE_OPEN_MODEL = GetHashKey(L.chestOpenProp)

Citizen.CreateThread(function()
    for _, model in ipairs({ CRATE_MODEL, CRATE_OPEN_MODEL }) do
        RequestModel(model)
        local waited = 0
        while not HasModelLoaded(model) and waited < 10000 do
            Citizen.Wait(100)
            waited = waited + 100
        end
    end
end)

--- Both gates come from br_lib, because the server reads the SAME tables.
--- When these were written out twice they drifted, and the symptom was no
--- loot anywhere with no error to grep for -- see the note on
--- BR.Config.LootVisibleStates.
local function canSee()
    return BR.Config.LootVisibleStates[BR.State.me.state] == true
end

local function canTake()
    if BR.Config.LootTakeStates[BR.State.me.state] ~= true then return false end
    -- NOT FROM A CAR (user call, 2026-08-05). Driving through a POI hoovering
    -- up crates at 40mph is not looting, and the ray comes off the ped's
    -- forward vector, which in a vehicle is the vehicle's.
    return not IsPedInAnyVehicle(PlayerPedId(), false)
end

local function isContainer(e)
    return e.kind == 'chest' or e.kind == 'deathbox'
end

--- An already-opened crate. Scenery: no glow, no label, no prompt, and the
--- server refuses to claim it. It exists so a room you have already swept
--- reads as swept from the doorway.
local function isHusk(e)
    return e.kind == 'husk'
end

--- The pitch an item RESTS at, in degrees.
---
--- Only long things lie down. A rifle standing on end sinks into the terrain
--- however carefully its centre is placed; lying flat it sits on it. An ammo
--- box or a medkit is a box -- it spawns the right way up, and tipping it onto
--- its side is worse rather than better (user, 2026-08-08).
--- @param e table
--- @return number
local function restPitchOf(e)
    if e.kind == BR.ItemKind.WEAPON then return L.restPitch or 90.0 end
    return L.hoverPitch or 0.0
end

-- --------------------------------------------------------------------------
-- Models
-- --------------------------------------------------------------------------

--- The model an entry should be drawn as.
---
--- Weapons resolve through GET_WEAPONTYPE_MODEL rather than an authored prop
--- name per weapon: 35 hand-typed model names is 35 chances to ship an
--- invisible rifle, and the engine already knows the answer.
--- @param e table
--- @return integer|nil
local function modelOf(e)
    if e.kind == BR.ItemKind.WEAPON or e.kind == BR.ItemKind.THROWABLE then
        local w = BR.Config.WeaponById[e.item]
        return w and GetWeapontypeModel(w.hash) or nil
    end
    if e.prop then return GetHashKey(e.prop) end
    if e.kind == BR.ItemKind.AMMO then
        local a = BR.Config.AmmoPickups[e.item]
        return a and GetHashKey(a.prop) or nil
    end
    if e.kind == BR.ItemKind.CONSUMABLE then
        local c = BR.Config.ConsumableById[e.item]
        return c and GetHashKey(c.prop) or nil
    end
    return nil
end

--- What this entry is called, for the label and the prompt.
--- @param e table
--- @return string
local function labelOf(e)
    if e.kind == 'chest' then return 'Chest' end
    if e.kind == 'deathbox' then return 'Loot Box' end
    local name = BR.LootLabel({ kind = e.kind, item = e.item })
    if (e.count or 1) > 1 then return ('%s x%d'):format(name, e.count) end
    return name
end

--- Is a point dry land with something solid under it?
---
--- DECLARED BEFORE groundZ ON PURPOSE. A `local function` referenced above its
--- own declaration resolves as a GLOBAL, which is nil -- and a nil call inside
--- a loop callback gets that callback suspended after five errors, which is
--- exactly how every crate on the map disappeared once already.
--- @param x number
--- @param y number
--- @param fromZ number
--- @return boolean okay
--- @return number groundZ
local function solidGround(x, y, fromZ)
    local ok, gz = GetGroundZFor_3dCoord(x, y, fromZ, false)
    if not ok then return false, 0.0 end

    -- SEA LEVEL IS ZERO, and that is the check that actually works.
    --
    -- GetWaterHeight answers for water VOLUMES the engine has streamed, so
    -- over open ocean -- far from anything, which is exactly where stray loot
    -- ends up -- it frequently returns nothing at all, and the probe below it
    -- happily returns the seabed. Loot kept appearing to float (user,
    -- 2026-08-06). A ground probe that lands at or below zero in this map is
    -- a seabed, full stop; the volume check stays for inland lakes, which sit
    -- well above zero and which the height rule cannot see.
    if gz <= 0.0 then return false, gz end

    local okW, wz = GetWaterHeight(x, y, gz)
    if okW and wz and wz > gz + 0.3 then return false, gz end
    return true, gz
end

--- Somewhere dry and solid near an entry that is not.
---
--- ONLY A CLIENT CAN COMPUTE THIS. The server has no map at all:
--- GetGroundZFor_3dCoord and GetWaterHeight are client natives, so generation
--- can put an item in the Pacific or inside a hillside and never find out.
--- The correction goes back over LOOT_FIX and the server bounds it to 30m --
--- it is a suggestion, not an instruction (see server/loot.lua).
---
--- Candidates walk outward on the golden angle: an even spread that never
--- retraces its own ring, and identical on every client, so two players
--- reporting the same crate suggest the same place for it.
--- @param e table
--- @return number|nil x
--- @return number|nil y
--- @return number|nil z
local function dryPointNear(e)
    local from = math.max((e.z or 0.0) + 50.0, 300.0)
    for i = 1, 12 do
        local ang = i * 2.39996323   -- golden angle in radians
        local r   = 4.0 + i * 2.0    -- 6m out to 28m, inside the server's bound
        local x   = e.x + math.cos(ang) * r
        local y   = e.y + math.sin(ang) * r
        local ok, gz = solidGround(x, y, from)
        if ok then return x, y, gz end
    end
    return nil
end

--- Ground height under an entry, cached. The server has no ground probe (the
--- native is client-side), so the authored z is only ever a hint -- and for
--- roadside filler it is not even that.
--- @param e table
--- @return number
local function groundZ(e)
    local now = GetGameTimer()
    if e.gz and now - (e.gzAt or 0) < 10000 then return e.gz end
    local from = math.max((e.z or 0.0) + 50.0, 300.0)
    local ok, gz = solidGround(e.x, e.y, from)
    e.gzOk = ok
    e.gz   = ok and gz or (e.z or 0.0)
    e.gzAt = now
    return e.gz
end

local function despawn(e)
    -- The settled height belongs to THAT object handle and that pose. A prop
    -- rebuilt after streaming out has to be measured again.
    e.restZ, e.settled = nil, false
    if e.obj then
        byObject[e.obj] = nil
        if DoesEntityExist(e.obj) then DeleteEntity(e.obj) end
    end
    e.obj = nil
end

--- Hand a prop over to the retiring list instead of deleting it.
---
--- Only for loose items with a body already in the world. A crate becomes a
--- husk rather than vanishing, and a husk is scenery that stays.
--- @param e table
--- @param toX number|nil  where it should fly to; nil means straight up
--- @param toY number|nil
--- @param toZ number|nil
local function retireProp(e, toX, toY, toZ)
    if not e.obj or not DoesEntityExist(e.obj) then return false end
    local c = GetEntityCoords(e.obj)
    retireSeq = retireSeq + 1
    retiring[retireSeq] = {
        obj = e.obj,
        fromX = c.x, fromY = c.y, fromZ = c.z,
        toX = toX or c.x, toY = toY or c.y, toZ = toZ or (c.z + 1.0),
        at = GetGameTimer(),
    }
    byObject[e.obj] = nil
    e.obj = nil        -- despawn() must not delete it now
    return true
end

--- Delete every retiring prop immediately. Teardown, not animation.
local function clearRetiring()
    for k, r in pairs(retiring) do
        if r.obj and DoesEntityExist(r.obj) then DeleteEntity(r.obj) end
        retiring[k] = nil
    end
end

local function forget(id)
    local e = entries[id]
    if not e then return end
    despawn(e)
    entries[id] = nil
    queued[id] = nil
    poses[id] = nil
    if hold.id == id then hold.id = nil end
    if outlinedId == id then outlinedId = nil end
end

local function forgetAll()
    clearOutline(entries)
    clearRetiring()
    for id in pairs(entries) do forget(id) end
    entries, queue, queued, byObject, reported = {}, {}, {}, {}, {}
    myCell, hold.id = nil, nil
    shineId, outlinedId = nil, nil
    burstUntil = 0
    -- Inline rather than through setPrompt(): that lives below this, and a
    -- local referenced before its declaration silently resolves as a global.
    lastPrompt.id, lastPrompt.hold = nil, nil
    claimedByMe = {}
    -- The glow teaches the interaction again next match: whoever is here then
    -- may never have opened one.
    BR.Loot.openedCount = 0
    local page = BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
    BR.Dui.send(page, { t = 'prompt', show = false })
end

-- The spawn worker. Model loading is asynchronous, so this cannot live in a
-- loop callback -- and a burst of RequestModel in one frame is exactly how a
-- landing at a dense POI turns into a stutter. Two per pass, then yield.
--
-- ...EXCEPT FOR THE FIRST FEW SECONDS AFTER LANDING, where the trickle is the
-- problem rather than the fix. Two per pass across 50-150 streamed entries is
-- several seconds of a POI that looks empty, and a player who has just landed
-- has nothing else to do but look at it (user, 2026-08-08). The stutter this
-- rate exists to avoid is also least costly right then: the drop is already a
-- loading moment, and nobody is in a firefight three seconds after touchdown.
local function perPass()
    if burstUntil > 0 and GetGameTimer() < burstUntil then
        return L.landingBurst or 8
    end
    return L.drainPerPass or 2
end

local function drain()
    if draining then return end
    draining = true

    Citizen.CreateThread(function()
        while #queue > 0 do
            for _ = 1, perPass() do
                local id = table.remove(queue, 1)
                if not id then break end
                queued[id] = nil

                local e = entries[id]
                if e and not e.obj then
                    -- REPORT BEFORE BUILDING. An entry in the sea or inside a
                    -- hillside gets a corrected position sent back rather than
                    -- a prop built where nobody can reach it; the server
                    -- re-announces it and the next pass builds it properly.
                    groundZ(e)
                    if not e.gzOk and not reported[id] then
                        reported[id] = true
                        local fx, fy, fz = dryPointNear(e)
                        if fx then
                            TriggerServerEvent(BR.Net.LOOT_FIX,
                                { id = id, x = fx, y = fy, z = fz })
                        end
                    end

                    local model = modelOf(e)
                    if e.gzOk and model and IsModelValid(model) then
                        RequestModel(model)
                        local waited = 0
                        while not HasModelLoaded(model) and waited < 3000 do
                            Citizen.Wait(50)
                            waited = waited + 50
                        end
                        -- The entry can be claimed by someone else while its
                        -- model streams in; re-check before building it.
                        if HasModelLoaded(model) and entries[id] and not entries[id].obj then
                            local gz = groundZ(e)
                            -- Containers are dropped a hair above the ground
                            -- and left to settle, because the native that
                            -- would settle them for us is the very thing that
                            -- welds them in place (see below).
                            -- THE LAST PARAMETER IS `dynamic`, and it was
                            -- false -- which is why crates stayed welded to
                            -- the ground however much of the rest of the
                            -- physics setup said otherwise (user, 2026-08-05).
                            -- Containers spawn dynamic; loose floor items stay
                            -- static, because a rifle skittering down a hill
                            -- is not a feature.
                            local dynamic = isContainer(e) or isHusk(e)
                            -- THE HUSK INHERITS THE CRATE'S POSE. If this entry
                            -- already had a prop in the world -- which it did
                            -- whenever a sealed crate has just become an open
                            -- one -- put the replacement exactly where the old
                            -- one was, at the same attitude. Otherwise the box
                            -- you just opened jumps back to where it was
                            -- generated and stands up straight (user,
                            -- 2026-08-06).
                            local pose = poses[id]
                            -- SHARED WITH THE ANIMATION. Static props are
                            -- built here and never moved again unless they
                            -- animate, so this height IS their resting
                            -- height -- and animate() writing a different one
                            -- is what buried them.
                            local sx, sy, sz = e.x, e.y, gz + (L.restLift or 0.35)
                            if pose then sx, sy, sz = pose.x, pose.y, pose.z end

                            local obj = CreateObjectNoOffset(model,
                                sx, sy, sz, false, false, dynamic)
                            if obj and obj ~= 0 then
                                -- CRATES KEEP THEIR COLLISION. You walk up to
                                -- one and it is a box in the world; the ray
                                -- that decides what you are looking at needs
                                -- something to hit. Loose floor items do NOT
                                -- -- a hundred rifles underfoot at a hot drop
                                -- is a player snagging on loot mid-fight, and
                                -- they are close enough to target by proximity.
                                local solid = isContainer(e) or isHusk(e)
                                SetEntityCollision(obj, solid, solid)
                                if pose then
                                    -- Order 2 is the same convention
                                    -- GetEntityRotation was read with, so the
                                    -- pose round-trips exactly.
                                    SetEntityRotation(obj, pose.rx, pose.ry,
                                        pose.rz, 2, true)
                                elseif e.heading then
                                    SetEntityHeading(obj, e.heading)
                                end
                                -- PLACEOBJECTONGROUNDPROPERLY IS WHAT WELDED
                                -- THEM DOWN. Measured, not guessed: /brprobe
                                -- crate spawned five variants differing by one
                                -- decision each, and the ONLY one that moved
                                -- was the one that skipped this call
                                -- (2026-08-06, after three failed fixes).
                                --
                                -- So containers are placed by ARITHMETIC --
                                -- we already have the ground height from the
                                -- probe -- and never by the native that
                                -- settles them into the terrain.
                                --
                                -- Loose floor items still use it: they are
                                -- frozen anyway, and it makes a rifle lie flat
                                -- on a slope instead of hovering.
                                if not solid then
                                    -- POSE FIRST, THEN SETTLE, THEN REMEMBER.
                                    --
                                    -- The native works off the model's
                                    -- bounding box, and a rifle lying flat has
                                    -- a very different box from one standing
                                    -- on end -- settle before posing and it
                                    -- lands at the wrong height for the pose
                                    -- it is about to take.
                                    SetEntityRotation(obj, restPitchOf(e), 0.0,
                                        e.heading or 0.0, 2, true)
                                    PlaceObjectOnGroundProperly(obj)

                                    -- WHERE IT ACTUALLY ENDED UP is the number
                                    -- the hover rises from and returns to, and
                                    -- it is not knowable any other way: it
                                    -- depends on the model and the slope.
                                    --
                                    -- Captured HERE rather than at the first
                                    -- settle because the object is frozen a
                                    -- few lines below, and this native does
                                    -- not move a frozen entity. Two earlier
                                    -- guesses -- the bare ground z, then
                                    -- ground + 0.35 -- buried it and then
                                    -- floated it (user, 2026-08-08).
                                    local c = GetEntityCoords(obj)
                                    e.restZ = c.z
                                end

                                -- CRATES ARE PHYSICAL. Drive into one and it
                                -- moves (user call, 2026-08-05). Only the
                                -- LOCAL prop moves -- the entry's authoritative
                                -- position never changes, so a crate shunted
                                -- across a car park is still looted from where
                                -- the server thinks it is, and every client
                                -- sees its own version of the shunt.
                                FreezeEntityPosition(obj, not solid)
                                if solid then
                                    SetEntityDynamic(obj, true)
                                    SetEntityHasGravity(obj, true)
                                    -- A CRATE IS NOT A SAFE. The default mass
                                    -- for this prop made it shift like a
                                    -- concrete block when a car hit it
                                    -- ("extremely heavy", 2026-08-06); a
                                    -- wooden crate should skitter.
                                    SetObjectPhysicsParams(obj,
                                        L.crateMass or 12.0,
                                        0.1,               -- damping
                                        -1.0, -1.0, -1.0,  -- inertia: engine default
                                        -1.0,              -- gravity: default
                                        0.1, 0.1, 0.1,     -- angular damping
                                        -1.0, -1.0)
                                    -- Physics can be dynamic, unfrozen and
                                    -- gravity-bound and still ASLEEP.
                                    ActivatePhysics(obj)
                                end
                                SetEntityAsMissionEntity(obj, false, true)
                                e.obj = obj
                                byObject[obj] = id
                            end
                        end
                        -- The two crate models stay resident. They are the
                        -- most-spawned models in the game by a wide margin,
                        -- and the sealed->open swap has to be instant --
                        -- re-streaming the open crate at the moment it is
                        -- looted is exactly the delay that was visible.
                        if model ~= CRATE_MODEL and model ~= CRATE_OPEN_MODEL then
                            SetModelAsNoLongerNeeded(model)
                        end
                    end
                end
            end
            Citizen.Wait(0)
        end
        draining = false
    end)
end

-- --------------------------------------------------------------------------
-- The wire
-- --------------------------------------------------------------------------

local function addEntries(list)
    for _, d in ipairs(list or {}) do
        if d.id then
            local have = entries[d.id]
            if have then
                -- A RE-SEND IS A CHANGE, not a duplicate. Two things arrive
                -- this way: the repair round-trip re-announcing a corrected
                -- position, and a sealed crate becoming its opened husk. Both
                -- keep the id; both need the prop rebuilt.
                local moved = math.abs((have.x or 0) - (d.x or 0)) > 0.01
                    or math.abs((have.y or 0) - (d.y or 0)) > 0.01
                local reskinned = have.kind ~= d.kind or have.prop ~= d.prop

                if moved or reskinned then
                    -- THE REVEAL, on the authoritative moment -- and only for
                    -- the player who opened it. This fires when the crate
                    -- ACTUALLY opened, so it cannot play for a claim the
                    -- server refused; the claimedByMe check is what stops it
                    -- firing for everyone standing nearby (user, 2026-08-05).
                    if reskinned and d.kind == 'husk' and L.openSound
                       and claimedByMe[d.id] then
                        claimedByMe[d.id] = nil
                        PlaySoundFrontend(-1, L.openSound.name,
                            L.openSound.set, true)
                    end
                    despawn(have)
                    have.x, have.y, have.z = d.x, d.y, d.z
                    have.kind, have.item, have.prop = d.kind, d.item, d.prop
                    have.rarity = d.rarity or have.rarity
                    if moved then
                        have.gz, have.gzAt, have.gzOk = nil, 0, nil
                    end
                    queued[d.id] = nil
                    -- Rebuilt on the NEXT prop pass at the latest, but a
                    -- crate the player is standing over has to change NOW --
                    -- so it jumps the queue.
                    if reskinned then
                        queued[d.id] = true
                        table.insert(queue, 1, d.id)
                        drain()
                    end
                end
            else
                entries[d.id] = {
                    id = d.id, kind = d.kind, item = d.item,
                    rarity = d.rarity or BR.Rarity.COMMON, count = d.count or 1,
                    x = d.x, y = d.y, z = d.z, prop = d.prop,
                    heading = d.heading,
                    -- Where it came from, if it came from anywhere: a crate
                    -- bursting open or a player's hand. Absent on the
                    -- generated layout, which was always just there.
                    fx = d.fx, fy = d.fy, fl = d.fl,
                    bornAt = d.fx and GetGameTimer() or nil,
                    lift = 0.0,
                }
            end
        end
    end
end

RegisterNetEvent(BR.Net.LOOT_ADD)
AddEventHandler(BR.Net.LOOT_ADD, function(list)
    addEntries(list)
end)

RegisterNetEvent(BR.Net.LOOT_GONE)
AddEventHandler(BR.Net.LOOT_GONE, function(ids)
    for _, id in ipairs(ids or {}) do
        local e = entries[id]
        -- SOMETHING I TOOK FLIES TO ME. Somebody else's pickup just goes --
        -- LOOT_GONE does not say who claimed it, and inventing a direction
        -- would be a lie about where a player is standing.
        if e and claimedByMe[id] and not isContainer(e) and not isHusk(e) then
            local ped = PlayerPedId()
            local p = GetEntityCoords(ped)
            retireProp(e, p.x, p.y, p.z + (L.waistHeight or 0.75))
        end
        forget(id)
    end
end)

-- A br_ui restart does not touch this, but a RECONNECT does: the snapshot
-- carries whatever cells this player was already subscribed to.
RegisterNetEvent(BR.Net.SNAPSHOT)
AddEventHandler(BR.Net.SNAPSHOT, function(payload)
    if payload and payload.loot then addEntries(payload.loot) end
end)

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    if not d then return end
    if d.state == BR.MatchState.WAITING
       or d.state == BR.MatchState.ENDED
       or d.state == BR.MatchState.CLEANUP then
        forgetAll()
    end
end)

-- An un-deleted local object outlives the resource that made it, so this is
-- not optional -- a restart mid-match would leave the props behind forever
-- with nothing left that knows they exist.
AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    forgetAll()
end)

-- --------------------------------------------------------------------------
-- Loops
-- --------------------------------------------------------------------------

-- Cell subscription.
--
-- MOVED FROM 1Hz TO 10Hz, AND THE REASON IS THE LANDING, not the walking.
--
-- A 256m cell takes 25 seconds to cross on foot, so 1Hz was ample for the
-- steady state and the band's comment has said "loot cells" since M0. But the
-- moment that matters is not crossing a boundary, it is the FIRST
-- subscription: a player is only allowed to see loot once they are ALIVE, and
-- that arrives up to 250ms after touchdown (the delta flush). Add up to a
-- second waiting for the next SLOW tick, then the round trip, then models
-- streaming in two at a time, and a player stands in an empty POI for several
-- seconds wondering what to do (user, 2026-08-08).
--
-- This is the cheapest of the three loot loops -- a state check, a coordinate
-- read and a string compare, with an early-out on every tick after the first.
-- loot.props, which is a full walk of every streamed entry, stays on SLOW.
BR.Loop.register(BR.Loop.TICK, 'loot.cells', function()
    if not canSee() then
        if myCell then forgetAll() end
        return
    end

    local p = GetEntityCoords(PlayerPedId())
    local cx, cy = BR.LootCellOf(p.x, p.y)
    local key = BR.LootCellKey(cx, cy)
    if key == myCell then return end

    -- THE FIRST SUBSCRIPTION OF A LIFE GETS A BURST BUDGET. Walking into a
    -- new cell can afford to trickle; landing cannot, because the player is
    -- standing in a POI that looks empty. See drain().
    local first = (myCell == nil)
    myCell = key
    if first then burstUntil = GetGameTimer() + (L.landingBurstMs or 4000) end
    TriggerServerEvent(BR.Net.LOOT_CELL, { cx = cx, cy = cy })
end)

-- Prop lifecycle. Entries are cheap; objects are not, so they exist in a much
-- smaller radius than the subscription and are torn down with hysteresis --
-- without it a player standing exactly on the boundary rebuilds the same model
-- every second.
BR.Loop.register(BR.Loop.SLOW, 'loot.props', function()
    if not canSee() then return end

    local p = GetEntityCoords(PlayerPedId())
    local near = L.propDistance
    local far  = L.propDistance + (L.propHysteresis or 15.0)
    local live = 0

    local now = GetGameTimer()

    for id, e in pairs(entries) do
        local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
        if e.obj then
            live = live + 1
            if d2 > far * far or not DoesEntityExist(e.obj) then
                despawn(e)
            elseif isContainer(e) then
                -- A PUSHED CRATE TAKES ITS ENTRY WITH IT.
                --
                -- The prop is physical now, but the REGISTRY position is what
                -- the prompt, the reach test and the server's claim check all
                -- use -- so a crate shunted by a car became unopenable, sitting
                -- in plain sight (user, 2026-08-06). It could hardly be more
                -- confusing: the thing you can see is not the thing the game
                -- thinks is there.
                --
                -- The client follows the object locally and tells the server,
                -- which bounds how far it will accept. Rate-limited, because
                -- a crate rolling down a hill would otherwise send one of
                -- these per second for as long as it rolls.
                local c = GetEntityCoords(e.obj)
                if BR.Dist2(c.x, c.y, e.x, e.y) > 1.0
                   and now - (e.movedAt or 0) > 2000 then
                    e.movedAt = now
                    e.x, e.y, e.z = c.x, c.y, c.z
                    e.gz, e.gzAt = c.z, now
                    TriggerServerEvent(BR.Net.LOOT_FIX,
                        { id = id, x = c.x, y = c.y, z = c.z })
                end
            end
        elseif d2 <= near * near and not queued[id] and live + #queue < PROP_MAX then
            queued[id] = true
            queue[#queue + 1] = id
        end
    end

    if #queue > 0 then drain() end
end)

--- The entry a player is closest to, within a distance.
--- @param px number
--- @param py number
--- @param maxDist number
--- @return table|nil
local function nearestEntry(px, py, maxDist)
    local best, bestD2 = nil, maxDist * maxDist
    for _, e in pairs(entries) do
        if not isHusk(e) then
            local d2 = BR.Dist2(px, py, e.x, e.y)
            if d2 < bestD2 then best, bestD2 = e, d2 end
        end
    end
    return best
end

--- What the player is interacting with right now.
---
--- LOOK-AT FIRST, PROXIMITY SECOND. A ray from the gameplay camera answers
--- "which crate am I standing in front of" the way players expect -- you face
--- the thing you want. Proximity is the fallback for loose floor items, which
--- have no collision to hit and are picked up by walking over them.
--- @param px number
--- @param py number
--- @return table|nil
--- Is the player actually LOOKING at this thing?
---
--- Walking down a corridor of loot used to flicker a prompt for whichever item
--- happened to be nearest, including ones behind you (user, 2026-08-08). The
--- ray-cast branch below already implies facing; this is the proximity
--- fallback, which did not.
---
--- Ped forward rather than camera forward: the prompt is about what the
--- CHARACTER can reach, and in third person the camera can be looking
--- somewhere the ped is not.
--- @param ped integer
--- @param px number
--- @param py number
--- @param e table
--- @return boolean
local function facing(ped, px, py, e)
    local dx, dy = e.x - px, e.y - py
    local len = math.sqrt(dx * dx + dy * dy)
    -- Standing on top of it: there is no direction to disagree with.
    if len < 0.35 then return true end

    local f = GetEntityForwardVector(ped)
    return ((dx / len) * f.x + (dy / len) * f.y) >= (L.promptFacingDot or 0.55)
end

local function targetEntry(px, py)
    local hit, _, entity = BR.Native.aim(L.pickupDistance + 1.5, 16)
    if hit and entity and entity ~= 0 then
        local id = byObject[entity]
        local e = id and entries[id]
        if e and not isHusk(e)
           and BR.Dist2(px, py, e.x, e.y)
               <= (L.pickupDistance + 1.5) * (L.pickupDistance + 1.5) then
            return e
        end
    end

    local near = nearestEntry(px, py, L.pickupDistance)
    -- A container is exempt: a crate is a metre-wide box you are standing at,
    -- and making players line up with one to open it is friction for nothing.
    if near and not isContainer(near)
       and not facing(PlayerPedId(), px, py, near) then
        return nil
    end
    return near
end

--- The prompt page. One browser for the whole system, created on first use.
local function promptPage()
    return BR.Dui.page('lootprompt', 'nui://br_ui/dui/prompt.html', 512, 256)
end

--- Tell the prompt page WHAT to show. Position is not its business -- that is
--- drawn natively, per frame, in the render loop.
---
--- Sent on CHANGE ONLY. The old NUI version had to push screen coordinates
--- across the resource bridge as the camera moved, which had to be throttled,
--- which is exactly why the text visibly trailed the crate. Nothing here moves
--- with the player at all.
--- @param e table|nil
--- @param holdMs number|nil  non-nil starts the ring animation
local function setPrompt(e, holdMs)
    local page = promptPage()
    local id   = e and e.id or nil

    if not e then
        if lastPrompt.id == nil then return end
        lastPrompt.id, lastPrompt.hold = nil, nil
        BR.Dui.send(page, { t = 'prompt', show = false })
        return
    end

    -- A re-send would restart the ring animation from zero, so a hold that is
    -- already running is left strictly alone.
    if id == lastPrompt.id and holdMs == lastPrompt.hold then return end
    lastPrompt.id, lastPrompt.hold = id, holdMs

    local container = isContainer(e)
    -- A CRATE'S TEXT IS THE SHINE'S ORANGE, not a rarity colour -- the two are
    -- the same signal and must not disagree. Loose items keep their rarity.
    local info = BR.RarityInfo[e.rarity] or BR.RarityInfo[BR.Rarity.COMMON]
    local colour = container and (L.shineHex or '#FF961E') or info.hex

    BR.Dui.send(page, {
        t      = 'prompt',
        show   = true,
        label  = labelOf(e),
        hint   = container and 'Hold to open' or 'Press to pick up',
        -- THE PLAYER'S OWN BINDING, asked for by COMMAND rather than by
        -- control. This used to read control 51 -- GTA's context key -- which
        -- is not the thing `brinteract` is bound to, so rebinding interact in
        -- the pause menu left every prompt still saying E. The vanilla control
        -- remains the fallback, because it also still works (see the two-inputs
        -- note further down) and a prompt with no key at all is worse than one
        -- naming the second of two working keys.
        key    = BR.Native.keyLabelForCommand('brinteract',
                                              L.promptControl or 51),
        colour = colour,
        ring   = container,
        holdMs = holdMs,
    })
end

--- Smoothstep, so eases start and end at rest rather than jerking into motion.
--- @param t number 0..1
--- @return number
local function ease(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return t * t * (3.0 - 2.0 * t)
end

--- Move a value toward a target by at most `step`.
local function approach(v, target, step)
    if v < target then return math.min(target, v + step) end
    return math.max(target, v - step)
end

--- Animate one loose item's prop for this frame.
---
--- LOOSE ITEMS ONLY. Crates and husks are physics objects with collision that
--- the drag loop owns; hovering one would fight that loop and also lie -- a
--- crate is furniture, and furniture does not float.
---
--- Three things stack, in order:
---
---   ARRIVAL  an item born from a crate or a drop flies an arc from where it
---            came from to where it lands. Runs once, from the entry's own
---            birth stamp, so it looks the same for a player who was already
---            standing there and one who walked up mid-flight.
---   HOVER    inside prompt range it rises to about waist height. Eased both
---            ways: a snap reads as a bug, a rise reads as "take me".
---   BOB+SPIN a slow turn and a shallow breath, scaled by how lifted it is --
---            so an item resting on the ground is perfectly still.
--- @param e table
--- @param d2 number  squared distance to the player
--- @param dt number  ms since the last frame
--- @param now number
local function animate(e, d2, dt, now)
    if not e.obj or not DoesEntityExist(e.obj) then return end
    if isContainer(e) or isHusk(e) then return end

    local gz = groundZ(e)

    -- WHERE "ON THE GROUND" ACTUALLY IS -- ASKED, NOT CALCULATED.
    --
    -- Two wrong answers first. `gz` buried everything, because the spawn drops
    -- props at `gz + 0.35`. Then `gz + 0.35` left them floating, because the
    -- spawn ALSO calls PlaceObjectOnGroundProperly straight afterwards, which
    -- settles them onto the surface -- so the number the animation was
    -- restoring had never been where they actually sat (user, 2026-08-08).
    --
    -- Neither number was ever knowable from here: it depends on the model's
    -- bounding box and the slope under it. So the native that already knows
    -- is asked, once per settle, and its answer is remembered as `restZ`.
    local rest = e.restZ or (gz + (L.restLift or 0.35))

    -- PITCH IS THE OTHER HALF OF THE CLIPPING, BUT ONLY FOR LONG THINGS.
    --
    -- A rifle standing on end sinks into the terrain however carefully its
    -- centre is placed; lying flat it sits on it. An ammo box or a medkit is
    -- a box -- it spawns the right way up and tipping it onto its side is
    -- worse, not better (user, 2026-08-08). So only weapons lie down.
    local rp = restPitchOf(e)
    local pitch = rp + ((L.hoverPitch or 0.0) - rp) * ease(e.lift or 0.0)

    -- ARRIVAL. A parabola, not a straight line: the extra height is what
    -- makes it read as thrown rather than slid.
    local arriveMs = L.arriveMs or 520
    if e.fx and e.bornAt and (now - e.bornAt) < arriveMs then
        local t = (now - e.bornAt) / arriveMs
        local k = ease(t)
        -- THE ORIGIN'S HEIGHT IS A LIFT ABOVE OUR OWN GROUND, never a z off
        -- the wire. The server's z is a first-pass hint with no ground probe
        -- behind it, and when it sat below the real terrain the contents of a
        -- crate rose UP OUT OF THE FLOOR (user, 2026-08-08).
        local sz = gz + (e.fl or (L.crateMouthHeight or 0.6))
        local x = e.fx + (e.x - e.fx) * k
        local y = e.fy + (e.y - e.fy) * k
        local z = sz + (rest - sz) * k
            + math.sin(t * math.pi) * (L.arriveArc or 0.55)
        SetEntityCoordsNoOffset(e.obj, x, y, z, false, false, false)
        -- Tumbling through the air, and it keeps the phase for the hover.
        e.spin = ((e.spin or 0.0) + (L.spinDegPerSec or 55.0) * 3.0
                  * (dt / 1000.0)) % 360.0
        SetEntityRotation(e.obj, L.hoverPitch or 0.0, 0.0, e.spin, 2, true)
        e.lift = 0.0
        e.settled = false
        return
    end

    -- HOVER, toward 1 when the player is close enough to be offered it.
    local pr = L.promptDistance or 2.5
    local want = (d2 <= pr * pr) and 1.0 or 0.0
    local ms = (want > (e.lift or 0.0)) and (L.hoverRiseMs or 320)
                                        or (L.hoverFallMs or 420)
    e.lift = approach(e.lift or 0.0, want, dt / math.max(ms, 1))

    local k = ease(e.lift)
    if k <= 0.001 then
        -- Fully at rest. Done once on the way down rather than every frame
        -- forever: a hundred items on the floor should cost nothing.
        if e.settled then return end
        e.settled = true

        -- Back to exactly where the spawn settled it -- see the note there
        -- for why that height is captured once and never recomputed. The prop
        -- is frozen by now, so PlaceObjectOnGroundProperly would do nothing.
        SetEntityRotation(e.obj, rp, 0.0, e.spin or (e.heading or 0.0), 2, true)
        SetEntityCoordsNoOffset(e.obj, e.x, e.y, rest, false, false, false)
        return
    end
    e.settled = false

    local bob = math.sin(now / math.max(L.bobPeriodMs or 1900, 1) * math.pi * 2.0)
                * (L.bobAmplitude or 0.06) * k
    SetEntityCoordsNoOffset(e.obj, e.x, e.y,
        rest + k * (L.hoverHeight or 0.55) + bob, false, false, false)

    e.spin = ((e.spin or 0.0) + (L.spinDegPerSec or 55.0) * k * (dt / 1000.0))
             % 360.0
    SetEntityRotation(e.obj, pitch, 0.0, e.spin, 2, true)
end

--- Fly every retiring prop to its destination, then delete it.
---
--- These are not loot any more -- see the note on `retiring`. Nothing here can
--- be targeted, prompted or claimed; it is scenery being cleared away.
--- @param now number
local function stepRetiring(now)
    local ms = L.takeMs or 400
    for k, r in pairs(retiring) do
        local t = (now - r.at) / ms
        if t >= 1.0 or not r.obj or not DoesEntityExist(r.obj) then
            if r.obj and DoesEntityExist(r.obj) then DeleteEntity(r.obj) end
            retiring[k] = nil
        else
            local p = ease(t)
            SetEntityCoordsNoOffset(r.obj,
                r.fromX + (r.toX - r.fromX) * p,
                r.fromY + (r.toY - r.fromY) * p,
                -- Lifts clear of the ground first, then travels -- otherwise
                -- it ploughs through the floor on the way to a waist.
                r.fromZ + (r.toZ - r.fromZ) * p + math.sin(t * math.pi) * 0.25,
                false, false, false)
            SetEntityHeading(r.obj, (t * 540.0) % 360.0)
            -- Shrinking would be nicer than spinning, but there is no scale
            -- native for a plain object -- SetEntityScale does not exist for
            -- these. The spin plus the arc is what sells it.
        end
    end
end

-- Glow, labels, the prompt and the container hold, all off one pass over the
-- entries in range. Disable with /brloop disable loot.render -- the loot still
-- works, which is the same drill the storm renderer answers to.
--- Crate physics: drag, and remembering where each crate actually is.
---
--- SEPARATE FROM loot.props, AND TEN TIMES FASTER, and that separation is the
--- whole fix. The drag used to live inside loot.props -- which is registered
--- on the SLOW band, once per SECOND. A crate hit by a car therefore skated at
--- full speed for a whole second before anything touched it, then again, and
--- again: the damping was real, ran exactly as written, and was completely
--- invisible ("I'm thinking the weight or drag or whatever just isn't working
--- at all", user 2026-08-06). It was working; it was being asked once a
--- second. At 10Hz the same coefficient is applied ten times as often, which
--- is the order of magnitude that was missing.
---
--- This does no scanning: it walks only the entries that already HAVE a prop,
--- which is at most PROP_MAX and usually a handful.
BR.Loop.register(BR.Loop.TICK, 'loot.crates', function()
    for id, e in pairs(entries) do
        -- HUSKS TOO. An opened crate is the same physical box with a different
        -- lid: it already got the mass (both go through the `solid` branch at
        -- spawn) but it was excluded HERE, so an empty crate kept sliding like
        -- ice long after the sealed ones stopped (user, 2026-08-06). Mass and
        -- drag have to travel together or the pair is half a system.
        if e.obj and (isContainer(e) or isHusk(e)) and DoesEntityExist(e.obj) then
            -- DRAG, because prop physics has no friction worth the name and
            -- SetObjectPhysicsParams' damping only bites in the air. The
            -- horizontal velocity is scaled down and zeroed once it is slower
            -- than walking pace. Z IS LEFT ALONE: a crate knocked off a roof
            -- should still fall like one.
            local v = GetEntityVelocity(e.obj)
            local vx, vy, vz = v.x, v.y, v.z
            local speed2 = vx * vx + vy * vy
            if speed2 > 0.0001 then
                local minV = L.crateDragMin or 0.35
                if speed2 < minV * minV then
                    SetEntityVelocity(e.obj, 0.0, 0.0, vz)
                else
                    local k = L.crateDrag or 0.23
                    SetEntityVelocity(e.obj, vx * k, vy * k, vz)
                end
                -- Provable rather than inferred: /brloot prints this, so
                -- "the drag is not running" and "the drag is not enough" can
                -- be told apart without another round of guessing.
                -- SPLIT BY KIND, because "the weight only works on empty
                -- crates" (user, 2026-08-07) is a claim these two counters
                -- settle in one line: if sealed is 0 and husk is not, the
                -- loop is skipping sealed crates; if both move, the drag is
                -- running on both and the difference is somewhere else.
                BR.Loot.dragTicks = (BR.Loot.dragTicks or 0) + 1
                if isHusk(e) then
                    BR.Loot.dragHusk = (BR.Loot.dragHusk or 0) + 1
                else
                    BR.Loot.dragSealed = (BR.Loot.dragSealed or 0) + 1
                end
            end

            -- Remember where it ACTUALLY is. This is the only record of the
            -- pose that survives the entry being replaced when the crate
            -- becomes a husk.
            local c = GetEntityCoords(e.obj)
            local r = GetEntityRotation(e.obj, 2)
            local pose = poses[id]
            if pose then
                pose.x, pose.y, pose.z = c.x, c.y, c.z
                pose.rx, pose.ry, pose.rz = r.x, r.y, r.z
            else
                poses[id] = { x = c.x, y = c.y, z = c.z,
                              rx = r.x, ry = r.y, rz = r.z }
            end
        end
    end
end)

BR.Loop.register(BR.Loop.FRAME, 'loot.render', function(dt)
    local frameNow = GetGameTimer()

    -- BEFORE THE EARLY-OUT, and deliberately. A retiring prop is no longer an
    -- entry, so claiming the last item in scope would otherwise leave it
    -- frozen in mid-air forever -- `next(entries)` is false and nothing runs.
    if next(retiring) then stepRetiring(frameNow) end

    if not canSee() or not next(entries) then return end

    dt = (dt and dt > 0) and math.min(dt, 100) or 16

    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local glow2  = L.glowDistance * L.glowDistance

    -- ONE CRATE GLOWS: the nearest, and only inside the shine radius.
    --
    -- Every crate in the room lighting up at once was a wall of orange rather
    -- than a signal (user, 2026-08-06). One at a time reads as "this is the
    -- one you are walking towards", which is the only thing the glow is for.
    -- AND ONLY UNTIL THE FIRST ONE IS OPENED. The glow is teaching "these
    -- boxes open"; after that it is a permanent orange marker on furniture.
    -- WHICH crate shines is recomputed at 10Hz, not 60Hz.
    --
    -- This is a full walk of every streamed entry, and it was running once per
    -- FRAME purely to answer a question whose answer changes at walking pace.
    -- At a dense POI that is several hundred distance checks per frame for a
    -- glow that fades over metres -- and it is a prime suspect for the frame
    -- hitching that appeared as the POI count grew (user, 2026-08-06). The
    -- FADE below still runs every frame, so nothing looks any less smooth.
    local shineMax = L.shineDistance or 18.0
    local now = GetGameTimer()
    if now - shineAt >= (L.shineScanMs or 100) then
        shineAt = now
        shineId = nil
        local best = shineMax * shineMax
        if BR.Loot.openedCount < (L.shineOpenLimit or 2) then
            for id, e in pairs(entries) do
                if isContainer(e) and e.gzOk then
                    local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
                    if d2 < best then shineId, best = id, d2 end
                end
            end
        end
    end

    -- ...but the DISTANCE to it is measured fresh every frame, so the fade is
    -- smooth even though the choice of crate is not re-decided.
    local shineD2 = shineMax * shineMax
    if shineId then
        local se = entries[shineId]
        if se then
            shineD2 = BR.Dist2(p.x, p.y, se.x, se.y)
        else
            shineId = nil
        end
    end

    -- FADED BY DISTANCE, not switched at a boundary: full strength stood over
    -- the crate, nothing at all at the rim. The old version was the same
    -- brightness everywhere inside the radius and then simply vanished.
    -- SQUARED, because linear was imperceptible (user, 2026-08-06: "doesn't
    -- really fade, I can't tell the difference"). Halfway to the rim a linear
    -- curve is still at 50% -- which just reads as "on". Squared puts the same
    -- point at 25% and spends most of the radius visibly dying.
    local shineFade = 1.0
    if shineId then
        local t = math.sqrt(shineD2) / shineMax
        if t > 1.0 then t = 1.0 end
        shineFade = (1.0 - t) * (1.0 - t)
    end

    -- A slow, shallow breath. The old pulse swung 0.72..1.0 in under a second,
    -- which read as flashing; this is a fade you notice without being nagged
    -- by it.
    local pulse = 0.55 + 0.20 * math.sin(GetGameTimer() / 900.0)
    local SHINE = L.shineColour or { 255, 150, 30 }

    -- PUT OUT WHATEVER IS LIT AND SHOULD NOT BE, unconditionally and before
    -- anything else. This runs whether or not the crate is still in range,
    -- still a crate, or still anything at all -- which is precisely what the
    -- old in-loop version could not do, and why crates stayed orange for the
    -- rest of the match once you walked away from them or opened them.
    if outlinedId and outlinedId ~= shineId then clearOutline(entries) end

    for id, e in pairs(entries) do
        local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
        -- A husk is scenery. Glowing it would send players across open ground
        -- for a crate somebody already emptied, which is the exact opposite of
        -- what the open-crate model is for.
        --
        -- gzOk gates the DRAWING too, not just the prop: an entry rejected for
        -- standing in the sea still had its rarity disc painted on the waves
        -- (user, 2026-08-06).
        if d2 <= glow2 and not isHusk(e) and e.gzOk then
            animate(e, d2, dt, frameNow)
            local gz = groundZ(e)
            local info = BR.RarityInfo[e.rarity] or BR.RarityInfo[BR.Rarity.COMMON]
            local c = info.rgb

            -- NO DISC UNDER A CRATE (user, 2026-08-07: "are you drawing a blue
            -- marker under every unopened crate? We don't need that").
            --
            -- The disc exists to say "something is here" for a loose item,
            -- which is a small prop easily lost in scenery. A crate is a
            -- metre-wide box with an orange outline and a label on the lid --
            -- it announces itself. The disc under it was a third signal for a
            -- thing that already had two, in the RARITY colour, which also
            -- quietly leaked what was inside before it was opened.
            -- THE DISC YIELDS TO THE ITEM ITSELF.
            --
            -- Its whole job is "something is here", answered from across a
            -- room for a small prop lost in scenery. Once the item has risen
            -- to meet you and is turning in the air, that question is already
            -- answered far better than a disc can -- and a marker left burning
            -- under a floating object reads as two things, not one (user call,
            -- 2026-08-08).
            --
            -- Tied to the SAME eased lift the hover uses, so it dies exactly
            -- as the item rises and fades back in over exactly as long as the
            -- item takes to settle. Two curves would drift; one cannot.
            if not isContainer(e) then
                local a = math.floor(120 * (1.0 - ease(e.lift or 0.0)))
                if a > 0 then
                    -- A flat disc rather than a sphere: it reads as "something
                    -- is here" without swallowing the item itself.
                    DrawMarker(1, e.x, e.y, gz - 0.05,
                        0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                        0.45, 0.45, 0.12,
                        c[1], c[2], c[3], a,
                        false, false, 2, false, nil, nil, false)
                end
            end

            -- CRATES SHINE ORANGE. Always orange, never the rarity colour: the
            -- glow says "a crate is here", and what is inside is not knowable
            -- until it is opened, so colouring it by contents was both a lie
            -- and a second meaning for a channel that already has one (user
            -- call, 2026-08-06).
            --
            -- An OUTLINE carries it, not the light: the world is pinned to
            -- noon, where a light is very nearly invisible -- which is why the
            -- previous version read as no glow at all. The light stays at low
            -- intensity for interiors and storm gloom.
            if isContainer(e) then
                local mine = (id == shineId)
                -- Only the SWITCHING ON lives here now. Switching off is done
                -- once per pass, above, against the id that is actually lit --
                -- see clearOutline and the note on outlinedId for the three
                -- ways this branch used to be skipped while a crate was still
                -- glowing.
                if mine and e.obj and DoesEntityExist(e.obj) then
                    -- The COLOUR is re-sent every frame even when the outline
                    -- is already on: alpha is what carries the distance fade,
                    -- so it has to keep moving as the player walks in. Only
                    -- the on/off flag is latched.
                    if outlinedId ~= id then
                        clearOutline(entries)
                        outlinedId = id
                        SetEntityDrawOutline(e.obj, true)
                    end
                    SetEntityDrawOutlineColor(SHINE[1], SHINE[2], SHINE[3],
                        math.floor((L.shineAlpha or 60) * pulse * shineFade))
                end
                if mine then
                    -- A hint at the crate in front of you, not a floodlight
                    -- down the street -- and it dims to nothing as you back
                    -- away rather than switching off.
                    DrawLightWithRange(e.x, e.y, gz + 0.5,
                        SHINE[1], SHINE[2], SHINE[3],
                        L.shineLightRange or 1.2,
                        (L.shineLightPower or 0.30) * pulse * shineFade)
                end
            end

            -- NO DrawText ANYWHERE IN LOOT any more (user call, 2026-08-06).
            -- The DUI prompt names whatever the player is actually facing,
            -- with real typography and the right key on it; a second, worse
            -- label floating over every item in the room was the engine text
            -- renderer competing with it. The rarity disc is what carries
            -- "something is here" at distance.
        end
    end

    if not canTake() then
        setPrompt(nil)
        return
    end

    -- THE HOLD. A crate is a commitment in the open -- a second standing
    -- still, visible to anyone watching the building. The ring is a CSS
    -- animation inside the DUI page, started once from its duration, so it
    -- runs at the browser's own frame rate rather than being stepped from
    -- here.
    local shown = nil
    if hold.id then
        local e = entries[hold.id]
        if not e or BR.Dist2(p.x, p.y, e.x, e.y)
            > L.pickupDistance * L.pickupDistance then
            hold.id = nil
        else
            shown = e
            setPrompt(e, L.chestHoldMs or 1000)

            if GetGameTimer() - hold.from >= (L.chestHoldMs or 1000) then
                local id = hold.id
                hold.id = nil
                -- THE GLOW HAS DONE ITS JOB. Counted on the hold completing
                -- rather than on the server's reply: the player has
                -- demonstrably learned the interaction by this point, and a
                -- refused claim (someone beat them to it) taught them just as
                -- well.
                BR.Loot.openedCount = BR.Loot.openedCount + 1
                TriggerServerEvent(BR.Net.LOOT_CLAIM, { id = id })
                claimedByMe[id] = GetGameTimer()
                setPrompt(nil)
                shown = nil
            end
        end
    end

    if not shown and not hold.id then
        shown = targetEntry(p.x, p.y)
        setPrompt(shown, nil)
    end

    -- DRAWN NATIVELY, EVERY FRAME. This is the half that used to lag: the
    -- prompt is a sprite at a world position, so it is welded to the crate
    -- however fast the camera moves, and nothing crosses the bridge to keep
    -- it there.
    if shown then
        local gz = groundZ(shown)
        -- A CRATE WEARS ITS LABEL; everything else floats one.
        --
        -- On a container the prompt is drawn flat on the lid at a fixed
        -- heading, so it reads as printed on the box and does not swing round
        -- as the player circles it (user, 2026-08-06). Loose items keep the
        -- screen-facing sprite: there is no surface to print on, and a label
        -- lying flat on the ground over a pistol would be unreadable.
        -- ANCHORED TO THE PROP, not to the entry. The registry position is
        -- where the crate was GENERATED; the prop is where it actually is
        -- after settling, or after a car hit it. Passing the entity also hands
        -- the label the crate's full orientation for free.
        if isContainer(shown) and shown.obj and L.crateLabelFlat ~= false
           and DoesEntityExist(shown.obj) then
            BR.Dui.drawOnEntity(promptPage(), shown.obj,
                L.crateLabelSize or 0.55, L.crateLabelLift or 0.02)
        else
            -- No `dist`: a fixed size, not one that inflates on approach.
            --
            -- MEASURED FROM THE ITEM, not from the ground. The prop rises
            -- half a metre when the player is close enough to be offered it,
            -- and the first version added that lift to a FIXED world height --
            -- so the label climbed twice as far as the thing it labels. A
            -- constant gap above the item is what reads as attached.
            -- `shown.lift` is the same eased 0..1 the animation uses, so the
            -- two cannot drift apart.
            local lift = ease(shown.lift or 0.0) * (L.hoverHeight or 0.55)
            BR.Dui.drawWorld(promptPage(), shown.x, shown.y,
                gz + lift + (L.promptLift or 0.75), L.promptScale or 2.0)
        end
    end
end)

-- --------------------------------------------------------------------------
-- Input
-- --------------------------------------------------------------------------

--- Begin an interaction with whatever is in front of the player.
local function interactPressed()
    if not canTake() then return end

    local p = GetEntityCoords(PlayerPedId())
    local e = targetEntry(p.x, p.y)
    if not e then return end

    if isContainer(e) then
        hold.id, hold.from = e.id, GetGameTimer()
        return
    end

    -- A tap picks up. The rate limit lives on the server; this only stops a
    -- key repeat from spending the player's whole allowance on one item.
    local now = GetGameTimer()
    if now - (claimedAt[e.id] or 0) < 500 then return end
    claimedAt[e.id] = now
    TriggerServerEvent(BR.Net.LOOT_CLAIM, { id = e.id })
end

BR.Keys.on('interact', function(pressed)
    if not pressed then
        hold.id = nil
        return
    end
    interactPressed()
end)

-- ONE INPUT, AND THE PLAYER'S OWN.
--
-- This used to ALSO poll GTA's context control (51) directly, as a workaround
-- for a label problem: a custom binding's `~INPUT_<hash>~` token renders as a
-- blank hole on this build, and a prompt showing a key that does nothing is
-- worse than no prompt -- so vanilla E was wired up alongside the binding to
-- make the sign honest.
--
-- That workaround is now the bug. With the label read correctly from the
-- keymapping, rebinding interact to R left BOTH R and E working, and E was a
-- ghost key mentioned nowhere (user, 2026-08-08). It also quietly broke this
-- project's oldest standing rule -- no code polls a raw control id -- since
-- nothing a player does in the pause menu could ever turn control 51 off.
--
-- The keymapping is the only input now. BR.Keys owns it, the pause menu
-- configures it, and the prompt names it.
--
-- The release side lives here rather than in the BR.Keys handler for one
-- reason: a hold that is interrupted by anything OTHER than letting go --
-- walking out of range, the item being claimed by somebody else -- clears
-- hold.id elsewhere, and this is the frame check that notices the key is no
-- longer down at all.
BR.Loop.register(BR.Loop.FRAME, 'loot.interact', function()
    if not canTake() then return end
    if hold.id and not BR.Keys.isHeld('interact') then
        hold.id = nil
    end
end)

-- --------------------------------------------------------------------------
-- Debug
-- --------------------------------------------------------------------------

-- --------------------------------------------------------------------------
-- Dev: loot blips
-- --------------------------------------------------------------------------

-- OFF BY DEFAULT AND NEVER ON IN A REAL MATCH. A blip per item is a wallhack
-- with a nice interface; this exists so a developer can find the crate they
-- are trying to debug. /brlootblips toggles it.
local blipsOn = false
local blips   = {}   -- [id] = handle

-- THE MERCY BLIPS.
--
-- A player who lands somewhere empty and spends a minute and a half finding
-- nothing has no way to tell "there is no loot here" from "this mode is
-- broken" -- and the second conclusion is the one they act on. After 90
-- seconds empty-handed the crates near them go on the map, with a notice
-- saying so (user, 2026-08-05).
--
-- They stay until BOTH conditions are met: something has been picked up AND
-- three minutes have passed. Whichever is later -- so the help does not
-- vanish the instant it starts working.
local mercy = { landedAt = 0, armedAt = 0, on = false }

local function clearBlips()
    for id, b in pairs(blips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
        blips[id] = nil
    end
end

-- The mercy timer. Separate from the drawing below so the dev toggle and the
-- automatic help share one blip implementation.
BR.Loop.register(BR.Loop.SLOW, 'loot.mercy', function()
    local cfg = L.mercyBlips
    if not cfg or not cfg.enabled then return end

    if BR.State.me.state ~= BR.PlayerState.ALIVE then
        mercy.landedAt, mercy.armedAt, mercy.on = 0, 0, false
        mercy.done = false
        return
    end

    -- ONCE PER LIFE. Without this the blips never go away, and the reason is
    -- not the expiry -- that works -- it is what happens on the very next
    -- pass. `mercy.on` goes false, control falls into the arming branch, and
    -- the arming test is `now - landedAt >= afterMs`, which is still true and
    -- will be true forever. So it re-armed a second later, every second,
    -- indefinitely (user, 2026-08-07: "courtesy loot blips don't remove after
    -- 1 minute" -- they were removed, and then immediately put back).
    if mercy.done then return end

    local now = GetGameTimer()
    if mercy.landedAt == 0 then mercy.landedAt = now end

    -- "HAS THIS PLAYER FOUND ANYTHING" INCLUDES OPENING A CRATE.
    --
    -- This used to read BR.Inv.lastGainAt alone -- i.e. "is anything in your
    -- inventory". But opening a chest does not put anything in your inventory:
    -- it SCATTERS the contents on the ground for you to pick up. So a player
    -- who walked up to a crate, held the key, watched it burst open and then
    -- got into a fight still counted as empty-handed, and the courtesy blips
    -- lit up the map for them anyway (user, 2026-08-08: "courtesy blips show
    -- even after a client has opened a chest").
    --
    -- openedCount is the right signal and it is already maintained for the
    -- glow: somebody who has opened a crate has demonstrably found the loot.
    local gained = (BR.Inv and BR.Inv.lastGainAt or 0) > 0
                or (BR.Loot.openedCount or 0) > 0

    if not mercy.on then
        -- Only for someone who has actually found nothing. Picking something
        -- up at any point before the timer means they know how this works.
        if not gained and now - mercy.landedAt >= (cfg.afterMs or 60000) then
            mercy.on, mercy.armedAt = true, now
            -- THE NOTICE SAYS HOW LONG IT LASTS (user call, 2026-08-06).
            -- Help that vanishes without warning reads as a bug; help with a
            -- stated duration reads as a grace period, and the player knows to
            -- use it now. Derived from the config rather than written out, so
            -- retuning minShownMs cannot leave the text lying.
            local mins = (cfg.minShownMs or 60000) / 60000.0
            local howLong
            if mins >= 2.0 then
                howLong = ('%d minutes'):format(math.floor(mins + 0.5))
            elseif mins >= 1.0 then
                howLong = '1 minute'
            else
                howLong = ('%d seconds'):format(
                    math.floor((cfg.minShownMs or 60000) / 1000 + 0.5))
            end
            TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
                text = ('No loot nearby? Crates are marked on your map for %s.')
                    :format(howLong),
                tone = 'info', ms = 8000,
            })
        end
        return
    end

    -- EITHER, not both (user correction, 2026-08-05): they go away as soon as
    -- something has been found, or after the timeout, whichever comes first.
    -- Help that outstays the problem is just a wallhack left switched on.
    if gained or now - mercy.armedAt >= (cfg.minShownMs or 60000) then
        mercy.on   = false
        mercy.done = true   -- and never again this life
    end
end)

BR.Loop.register(BR.Loop.SLOW, 'loot.devblips', function()
    if not blipsOn and not mercy.on then
        if next(blips) then clearBlips() end
        return
    end

    for id, e in pairs(entries) do
        -- An opened crate loses its blip outright rather than turning white:
        -- a map full of "already looted" markers is noise you have to read
        -- past to find the ones that matter (user, 2026-08-05).
        if isHusk(e) then
            if blips[id] then
                if DoesBlipExist(blips[id]) then RemoveBlip(blips[id]) end
                blips[id] = nil
            end
        elseif not blips[id] or not DoesBlipExist(blips[id]) then
            local b = AddBlipForCoord(e.x, e.y, e.gz or e.z or 0.0)
            -- 457 is the briefcase (user call, 2026-08-07): a courtesy blip is
            -- saying "there is loot over there", and a briefcase reads as loot
            -- at a glance where the generic 68 did not.
            SetBlipSprite(b, isContainer(e) and 457 or 1)
            SetBlipScale(b, isContainer(e) and 0.7 or 0.45)
            SetBlipColour(b, 5)
            SetBlipAsShortRange(b, true)
            blips[id] = b
        end
    end
    for id, b in pairs(blips) do
        if not entries[id] then
            if DoesBlipExist(b) then RemoveBlip(b) end
            blips[id] = nil
        end
    end
end)

-- POI blips, so "where are the points of interest" is answerable without
-- reading the config. Dev only, and off by default -- it is the whole map.
local poiBlips = {}

RegisterCommand('brpois', function()
    if next(poiBlips) then
        for _, b in ipairs(poiBlips) do
            if DoesBlipExist(b) then RemoveBlip(b) end
        end
        poiBlips = {}
        print('[br_core] POI blips off')
        return
    end

    -- Colour by tier, so the density question ("why is there so much loot
    -- here") is answerable at a glance: 3 = hot drop, 1 = rural filler.
    local byTier = { [1] = 2, [2] = 5, [3] = 1 }   -- green, yellow, red
    for _, poi in ipairs(BR.Config.Map.POIs) do
        local b = AddBlipForCoord(poi.x, poi.y, poi.z)
        SetBlipSprite(b, 1)
        SetBlipColour(b, byTier[poi.tier] or 0)
        SetBlipScale(b, 0.9)
        SetBlipAsShortRange(b, false)
        BeginTextCommandSetBlipName('STRING')
        AddTextComponentSubstringPlayerName(
            ('[T%d] %s'):format(poi.tier, poi.name))
        EndTextCommandSetBlipName(b)
        poiBlips[#poiBlips + 1] = b

        -- The radius too: the crate budget is spread across THIS disc, so the
        -- circle is the answer to "why is it all in one corner".
        local r = AddBlipForRadius(poi.x, poi.y, poi.z, poi.radius)
        SetBlipColour(r, byTier[poi.tier] or 0)
        SetBlipAlpha(r, 60)
        poiBlips[#poiBlips + 1] = r
    end

    print(('[br_core] POI blips ON -- %d points of interest')
        :format(#BR.Config.Map.POIs))
    print('  red = tier 3 (hot drop), yellow = tier 2, green = tier 1 (rural)')
    print('  the shaded circle is the radius the crate budget spreads across')
end, false)

RegisterCommand('brlootblips', function()
    blipsOn = not blipsOn
    if not blipsOn then clearBlips() end
    print(('[br_core] loot blips %s (%d entries in scope)')
        :format(blipsOn and 'ON' or 'off', (function()
            local n = 0
            for _ in pairs(entries) do n = n + 1 end
            return n
        end)()))
end, false)

--- Spawn a crate two metres in front of the ped. Dev mode only (the server
--- refuses otherwise) -- this is the one you want when debugging, because you
--- can see the thing land.
RegisterCommand('brcrate', function(_, args)
    local ped = PlayerPedId()
    local p   = GetEntityCoords(ped)
    local f   = GetEntityForwardVector(ped)
    TriggerServerEvent(BR.Net.LOOT_DEV, {
        item = args[1],
        x = p.x + f.x * 2.0,
        y = p.y + f.y * 2.0,
        z = p.z,
    })
    print(('[br_core] asked the server for %s'):format(args[1] or 'a crate'))
end, false)

--- Everything this client knows about the loot around it.
RegisterCommand('brloot', function()
    local p = GetEntityCoords(PlayerPedId())
    local cx, cy = BR.LootCellOf(p.x, p.y)
    local n, objs = 0, 0
    for _, e in pairs(entries) do
        n = n + 1
        if e.obj then objs = objs + 1 end
    end
    print('=== loot (client) ===')
    print(('  cell %d,%d   entries %d   props %d   queued %d')
        :format(cx, cy, n, objs, #queue))
    local near = nearestEntry(p.x, p.y, 50.0)
    if near then
        print(('  nearest: #%d %s (%s) at %.1fm')
            :format(near.id, labelOf(near), near.kind,
                    BR.Dist(p.x, p.y, near.x, near.y)))
    else
        print('  nothing within 50m')
    end

    -- PROOF THE DRAG IS RUNNING. This counter increments on every tick that
    -- actually scaled a crate's velocity, so "the drag is not running" and
    -- "the drag is not strong enough" are two different readings rather than
    -- one guess. It was 0 for as long as the drag sat on the 1Hz band and
    -- nobody could tell (user, 2026-08-06).
    print(('  crate drag: %d applications (sealed %d, husk %d), k=%.2f, floor %.2f m/s')
        :format(BR.Loot.dragTicks or 0, BR.Loot.dragSealed or 0,
                BR.Loot.dragHusk or 0, L.crateDrag or 0.0, L.crateDragMin or 0.0))
    -- And how many of each are physical right now, so "no sealed crate was
    -- ever dragged" can be told from "no sealed crate was ever pushed".
    local nSealed, nHusk = 0, 0
    for _, e in pairs(entries) do
        if e.obj then
            if isHusk(e) then nHusk = nHusk + 1
            elseif isContainer(e) then nSealed = nSealed + 1 end
        end
    end
    print(('  crate props live: %d sealed, %d husk'):format(nSealed, nHusk))
    print(('  crate mass: %.0f kg  (glow off after %d opened; %d opened)')
        :format(L.crateMass or 0.0, L.shineOpenLimit or 0, BR.Loot.openedCount or 0))
end, false)

--- Tune the crate label WITHOUT a deploy.
---
---   /brlabel                  show the current numbers
---   /brlabel <lift>           metres relative to the lid (negative = down)
---   /brlabel <lift> <size>    ...and the label width in metres
---
--- This exists because the lift has now been guessed twice from outside the
--- game -- 0.02 floated it, -0.10 sank it into the box -- and each guess cost
--- a deploy and a playtest round to evaluate (user, 2026-08-06). Stand at a
--- crate, nudge it until it sits on the plywood, and paste the printed line
--- into br_lib/config/loot.lua. Client-local and not persisted: it is a ruler,
--- not a setting.
RegisterCommand('brlabel', function(_, args)
    local lift = tonumber(args[1])
    local size = tonumber(args[2])
    if lift then L.crateLabelLift = lift end
    if size then L.crateLabelSize = size end

    print(('[br_core] crate label: lift %.3f  size %.2f  fit %.2f')
        :format(L.crateLabelLift or 0.0, L.crateLabelSize or 0.0,
                L.crateLabelFit or 0.45))
    if lift or size then
        print(('  paste into br_lib/config/loot.lua:'))
        print(('    crateLabelLift  = %.3f,'):format(L.crateLabelLift or 0.0))
        print(('    crateLabelSize  = %.2f,'):format(L.crateLabelSize or 0.0))
    else
        print('  usage: brlabel <lift> [size]   (lift is metres, negative = down)')
    end
end, false)

--- Which prompt glyph actually renders.
---
--- PLAN.md records that ~INPUT_<hash>~ for a RegisterKeyMapping binding drew
--- as a HOLE on this build, which is why the bus prompt fell back to a vanilla
--- token. This prints both so one in-game look settles which to ship -- and
--- either way the KEY is the player's own binding; only the picture changes.
RegisterCommand('brpromptcheck', function()
    local custom = BR.Native.inputForCommand('brinteract')

    -- WHAT THE DUI WILL ACTUALLY PRINT. The token test below is about the
    -- native HELP TEXT glyph; this is the separate question of whether we can
    -- read back the letter a player has rebound `brinteract` to. If the
    -- "bound" line disagrees with what you set in Settings > Key Bindings,
    -- the prompt is lying and keyLabelForCommand needs another approach.
    -- WHICH FORM ANSWERED IS THE WHOLE DIAGNOSTIC. The first version printed
    -- the label and the vanilla fallback side by side, and for `brinteract`
    -- both said E -- one because the lookup missed, the other because E is
    -- the vanilla context key. Two columns agreeing by coincidence hid the
    -- bug for a round, so the SOURCE is printed now.
    print('=== prompt key label (what the DUI shows) ===')
    for _, cmd in ipairs({ 'brinteract', 'brdrop', 'brinventory', 'bruse' }) do
        local label, via = BR.Native.keyLabelForCommand(cmd, L.promptControl or 51)
        print(('  %-12s %-6s  via %s'):format(
            cmd, tostring(label or '(none)'), tostring(via or 'nothing')))
    end
    print('  "via +brXXX" or "via brXXX" = the player\'s own binding.')
    print('  "via vanilla" = we could not read it and fell back to control 51.')

    print('=== prompt tokens ===')
    print(('  custom  %s'):format(custom))
    print('  vanilla ~INPUT_CONTEXT~')
    print('  showing the custom token for 6s, then the vanilla one')
    Citizen.CreateThread(function()
        BR.Native.help(('CUSTOM: press %s to pick up'):format(custom))
        Citizen.Wait(6000)
        BR.Native.help('VANILLA: press ~INPUT_CONTEXT~ to pick up')
    end)
end, false)
