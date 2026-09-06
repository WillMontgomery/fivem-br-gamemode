-- The four permanent crates on the warmup island: the half that can see them.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THREE JOBS, AND NONE OF THEM CREATES A CRATE
-- ═══════════════════════════════════════════════════════════════════════════
--
-- br_core/server/warmupcrates.lua puts four ordinary loot entries on the island
-- and br_core/client/loot.lua builds their props, exactly as it does for the
-- other 220. Nothing here spawns, streams, targets, prompts or claims anything:
-- all of that already works and a second copy of it would only be a second thing
-- to keep in step. What is left is the two things the loot pipeline gets
-- deliberately wrong for these four, and one thing it was never asked to do:
--
--   THE PIN     Owner, 2026-09-04: "The position of these entities must be
--               frozen... The husks' position should be frozen as well btw."
--
--               client/loot.lua builds every container DYNAMIC, unfrozen,
--               gravity-bound and then ActivatePhysics'd, because "drive into
--               one and it moves" (user, 2026-08-05), and it places it at a
--               PROBED ground height rather than at the authored one. Both are
--               right for a crate that was dropped somewhere approximate and
--               wrong for four that were surveyed. The pin puts each prop back
--               on its surveyed coordinates and freezes it there.
--
--   THE RETURN  Owner: "any loot from the crate will animate back into the
--               crate". The server retires whatever is left of the spill; this
--               flies a copy of each prop into the crate's mouth on the way out.
--
--   THE MARKER  Owner: "we'll draw their attention to these items by drawing a
--               bobbing 3dmarker type 0 over these crates... The color of each
--               marker above the crate will correspond to the rarity of it's
--               loot."
--
--               An ADDITION rather than a correction -- the two above undo
--               something the loot pipeline does on purpose, and this is a
--               thing nothing in the game did at all. Off by default; see the
--               marker section below for what turns it on and why that is a
--               switch rather than a config flag.
--
-- ═══ WHY THE PIN HUNTS FOR THE PROP INSTEAD OF BEING HANDED IT ═══
--
-- client/loot.lua holds every prop it builds in a file-local table and exposes
-- none of them -- the one accessor it ever had (BR.Loot.airdropBox) was deleted
-- when its single caller went, and the note where it stood says why a
-- write-only export is worse than none. Rather than reopen that, this file finds
-- the objects the same way anything else outside that file would have to:
-- GetClosestObjectOfType at a coordinate it already knows exactly.
--
-- THAT IS EXACT RATHER THAN APPROXIMATE, WHICH IS THE ONLY REASON IT IS SAFE.
-- The loot spawner probes for a prop's HEIGHT and never for its x/y -- it builds
-- at `e.x, e.y` verbatim, and the hover animation writes those same two numbers
-- back every frame. So a crate's prop is at its entry's x/y to the centimetre,
-- and `pinTolerance` in config/warmupcrates.lua is what turns that from a
-- coincidence into a test.
--
-- ═══ WHY THE MARKER IS HERE AND NOT IN THE TUTORIAL ═══
--
-- The note that stood in this spot said the marker belonged to client/
-- tutorial.lua and that BR.WarmupCrates.all() was what it would read. That was
-- the wrong seam, and the split it described is now drawn one step over: the
-- TUTORIAL owns WHEN -- it calls BR.WarmupCrates.markers(true) when the
-- walkthrough sends a player to the crates and markers(false) when it is done
-- -- and THIS FILE owns WHAT.
--
-- Because everything the draw needs is already here, and half of it is
-- file-local: the anchors, the pinned handles that say whether a crate is open
-- right now, and the two loop bands the draw has to be split across. A marker
-- drawn from outside would have to re-derive the sealed state through a public
-- accessor ten times a second, allocating four tables each time, and would
-- still be reading a copy rather than the pin's own view.
--
-- BR.WarmupCrates.all() is unchanged and is still what the tutorial reads to
-- ASK QUESTIONS about the crates. The switch below is the only thing it calls
-- to change one.

BR = BR or {}
BR.WarmupCrates = BR.WarmupCrates or {}

local W = BR.Config.WarmupCrates
local L = BR.Config.Loot

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. Seven shipped bugs on this project; client/loot.lua's solidGround
--- carries the write-up of the sixth and tools/bool_natives.baseline carries the
--- rest. Every BOOL native in this file goes through here.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

--- Smoothstep. The same curve client/loot.lua eases its take animation with, so
--- an item flying home reads as the same movement as one flying to a hand.
--- @param t number 0..1
--- @return number
local function ease(t)
    if t <= 0.0 then return 0.0 end
    if t >= 1.0 then return 1.0 end
    return t * t * (3.0 - 2.0 * t)
end

--- The two models one of these anchors can be wearing: sealed, and its husk.
--- Resolved once -- GetHashKey on a constant string sixty times a second is the
--- kind of thing that never shows up in a profile and never needed to happen.
local MODELS = {
    GetHashKey(L.chestProp),
    GetHashKey(L.chestOpenProp),
}

--- Both spellings of GET_CLOSEST_OBJECT_OF_TYPE's `isMission` flag -- see
--- findProp, which explains why both are asked. A file-local constant rather
--- than a literal at the loop, because that loop runs inside a 10Hz callback and
--- a fresh two-element table per anchor per pass is garbage this project has no
--- reason to make.
local MISSION_FLAGS = { false, true }

--- [anchorIndex] = the object handle currently pinned there, or nil.
local pinned = {}

--- Props flying home, detached from any entry. Same idea as client/loot.lua's
--- `retiring` list and for the same reason: the thing being animated is no
--- longer loot, cannot be targeted or claimed, and is scenery being cleared
--- away. Sequential keys through `flySeq` so removal during the pass cannot
--- shuffle the array out from under the iterator.
local flying = {}
local flySeq = 0

--- Diagnostics. /brwarmupcrates reads them, and each one separates two failures
--- that look identical from a chair.
BR.WarmupCrates.stats = {
    pins     = 0,   -- props adopted (a husk swap makes a new object, so this rises)
    corrects = 0,   -- times a pinned prop had drifted and was put back
    returns  = 0,   -- return messages handled
    flown    = 0,   -- props that actually flew
    missed   = 0,   -- items whose prop could not be found or copied
}

-- ---------------------------------------------------------------------------
-- The pin
-- ---------------------------------------------------------------------------

--- Is the local player somewhere these four could be seen from?
---
--- WARMUP AND NOTHING ELSE. The island's loot registry is the shared warmup zone
--- and BR.Config.LootVisibleStates admits exactly one state to it, so no other
--- state has these entries streamed and there is nothing to pin. Cheap enough to
--- ask every pass, which is what keeps the whole file free the other 99% of the
--- time a client is running.
--- @return boolean
local function onIsland()
    return BR.State.me.state == BR.PlayerState.WARMUP
end

--- The prop for this anchor, or nil.
---
--- ═══ BOTH SPELLINGS OF `isMission`, AND THAT IS NOT SUPERSTITION ═══
---
--- GET_CLOSEST_OBJECT_OF_TYPE takes an `isMission` flag whose documented meaning
--- ("only consider mission entities") does not match what several builds
--- actually do with it, and the loot spawner calls
--- SetEntityAsMissionEntity(obj, false, true) on everything it builds -- so
--- which side of that flag a crate falls on is a question about this specific
--- runtime rather than about the API. client/probe.lua exists because this
--- project has been wrong about natives before.
---
--- Asking twice costs one extra native call, and only while nothing is pinned:
--- the caller caches the handle and comes back here only when it dies. Asking
--- once and guessing costs a feature that silently never engages, which is the
--- failure this project keeps paying for.
--- @param a table an anchor row
--- @return integer|nil obj
local function findProp(a)
    local tol = W.pinTolerance or 0.35
    local r   = W.pinRadius or 6.0
    for _, hash in ipairs(MODELS) do
        for _, mission in ipairs(MISSION_FLAGS) do
            local obj = GetClosestObjectOfType(a.x, a.y, a.z, r, hash,
                                               mission, false, false)
            -- A HANDLE OF 0 IS "NOTHING FOUND", not an object. Checked before
            -- DoesEntityExist rather than instead of it: the native answers 0
            -- for a miss, and a stale non-zero handle is a separate question.
            if obj and obj ~= 0 and isTrue(DoesEntityExist(obj)) then
                local c = GetEntityCoords(obj)
                if math.abs(c.x - a.x) <= tol and math.abs(c.y - a.y) <= tol then
                    return obj
                end
            end
        end
    end
    return nil
end

--- Hold one prop on its surveyed coordinates.
---
--- ═══ WHAT EACH LINE IS FOR, BECAUSE THREE OF THEM UNDO A DELIBERATE DECISION
---     IN client/loot.lua ═══
---
---   FreezeEntityPosition   The whole of it. A frozen object takes no simulation
---                          step, so gravity, the crate's own mass and a car
---                          driving into it all stop applying. This is the same
---                          native that file uses to hold LOOSE items still, and
---                          the same one it hands a crate during its collision
---                          wait -- so a frozen container is a state the pipeline
---                          already produces, briefly, on its own.
---   SetEntityHasGravity    Belt to that brace. If anything ever unfreezes one of
---                          these for a frame -- the spawn path does exactly that
---                          when it finishes building a husk -- it must not
---                          spend that frame falling.
---   the coordinate write   The prop was built at a PROBED height (`gz +
---                          restLift`), which is not the surveyed one. This is
---                          where the owner's z is honoured, and it is the only
---                          place it can be: the server has no ground probe.
---
--- RE-ASSERTED EVERY PASS, NOT ONCE. The spawn worker unfreezes a container
--- after its collision wait and the physics is re-activated at the same moment,
--- so a one-shot pin would be undone by the very next husk swap and there would
--- be nothing to see it happen. Written only when it has actually drifted, so
--- the steady state is two comparisons and no matrix writes.
--- @param a table
--- @param obj integer
local function pin(a, obj)
    FreezeEntityPosition(obj, true)
    SetEntityHasGravity(obj, false)

    -- HEADING BEFORE POSITION. SetEntityHeading rebuilds the entity's axis
    -- vectors; it does not move it. The order does not matter here and is
    -- written this way to match the spawn worker's pose-then-place convention,
    -- so the two read the same way.
    --
    -- COMPARED THE WAY ANGLES HAVE TO BE. A heading is modulo 360, so a crate
    -- authored at 0.0 and sitting at 359.98 is 0.02 degrees out and reads as
    -- 359.98 to a straight subtraction -- which would fail this test forever and
    -- buy a matrix write ten times a second, silently, for as long as the server
    -- ran. None of the owner's four is near the wrap; the next one might be.
    local dh = math.abs((GetEntityHeading(obj) - a.heading + 180.0) % 360.0 - 180.0)
    if dh > 0.1 then
        SetEntityHeading(obj, a.heading)
    end

    local c = GetEntityCoords(obj)
    if math.abs(c.x - a.x) > 0.01 or math.abs(c.y - a.y) > 0.01
       or math.abs(c.z - a.z) > 0.01 then
        SetEntityCoordsNoOffset(obj, a.x, a.y, a.z, false, false, false)
        BR.WarmupCrates.stats.corrects = BR.WarmupCrates.stats.corrects + 1
    end
end

-- ═══ 10 Hz, ON THE SAME BAND AS THE CRATE PHYSICS IT IS CORRECTING ═══
--
-- client/loot.lua's own `loot.crates` pass runs here, and it is the pass that
-- records each container's pose into the table a husk inherits when the crate is
-- opened. Running at the same rate means the pose it records is the pinned one
-- rather than a half-settled one, so the husk is BORN at the surveyed point --
-- which is what makes the freeze survive the swap without a visible jump.
--
-- THE WINDOW THIS LEAVES IS ONE PASS. A newly built prop is unpinned for at most
-- 100ms, and it is not falling during them: the spawn worker freezes a container
-- for the whole of its collision wait (up to 1.5s) before it ever hands it to
-- physics.
BR.Loop.register(BR.Loop.TICK, 'warmupcrates.pin', function()
    if W.enabled == false then return end

    if not onIsland() then
        -- NOT DELETED, JUST FORGOTTEN. These objects belong to client/loot.lua,
        -- which despawns them on its own terms; holding a dead handle across a
        -- state change is how a pin lands on whatever the engine reissues that
        -- number to next.
        if next(pinned) then pinned = {} end
        return
    end

    -- ONLY WHERE THERE COULD BE A PROP AT ALL. client/loot.lua builds a body for
    -- an entry within `propDistance` and tears it down past that plus the
    -- hysteresis; beyond it there is nothing on the island to find, and hunting
    -- for it would be four searches an anchor, ten times a second, for the whole
    -- of a warmup spent at the other end of a kilometre-wide island. The pad's
    -- layout is 460m across and the prop radius is 180, so this is the ordinary
    -- case rather than an edge one.
    local p = GetEntityCoords(PlayerPedId())
    local reach = (L.propDistance or 180.0) + (L.propHysteresis or 15.0)
    local reach2 = reach * reach

    for i = 1, #W.anchors do
        local a = W.anchors[i]

        if BR.Dist2(p.x, p.y, a.x, a.y) > reach2 then
            -- Out of range means client/loot.lua has despawned the prop, so the
            -- handle we are holding names nothing. Dropped rather than kept:
            -- a stale handle is one the engine is free to reissue.
            pinned[i] = nil
        else
            local obj = pinned[i]

            if not obj or not isTrue(DoesEntityExist(obj)) then
                -- Gone, or never found. A husk swap deletes one object and
                -- builds another, so this is the ordinary path once per cycle
                -- rather than an error path.
                obj = findProp(a)
                pinned[i] = obj
                if obj then
                    BR.WarmupCrates.stats.pins = BR.WarmupCrates.stats.pins + 1
                end
            end

            if obj then pin(a, obj) end
        end
    end
end)

-- ---------------------------------------------------------------------------
-- The return
-- ---------------------------------------------------------------------------

--- Find the world object standing at each of these points.
---
--- ═══ BY POSITION, AND THE MODEL IS THE ANSWER RATHER THAN THE QUESTION ═══
---
--- The obvious shape is GetClosestObjectOfType, the way the pin above works --
--- and it cannot be used here, because it needs a model and the server has no
--- model to send. A spilled item is an id and a kind; the MODEL is resolved on
--- this side by client/loot.lua's modelOf(), which asks GET_WEAPONTYPE_MODEL for
--- a weapon and three separate config tables for everything else, and which is a
--- file-local in a file this one deliberately does not reach into. Re-deriving
--- it here would be a second copy of that resolution, in a different file,
--- drifting from the first the day a fourth kind is added.
---
--- So the search is positional and the model is read off whatever is found. That
--- is not a workaround -- it is a better answer: the object in the world is the
--- ground truth for BOTH the model and the height, and neither has to be
--- believed second-hand.
---
--- ONE POOL PASS FOR THE WHOLE MESSAGE. GetGamePool is not cheap enough to run
--- per item and is trivially cheap once per reset -- which happens at most once
--- every few seconds, per crate, and only after somebody has opened one.
---
--- CLOSEST WINS, NOT FIRST. A loose prop sits at its entry's x/y to the
--- centimetre (the spawner builds it there and the hover writes those two
--- numbers back every frame) and the closest pair a spill can produce is 1.07m
--- apart, so within `pinTolerance` there is at most one loot prop to find. Taking
--- the nearest rather than the first is what keeps a piece of map scenery whose
--- origin happens to fall in the same 35cm from beating it.
--- @param items table[]  each { x, y }
--- @param z number       roughly the height they are lying at
--- @return table         [index] = { obj, x, y, z }
local function propsAt(items, z)
    local tol = W.pinTolerance or 0.35
    local best = {}
    local bestD = {}

    for _, obj in ipairs(GetGamePool('CObject') or {}) do
        if isTrue(DoesEntityExist(obj)) then
            local c = GetEntityCoords(obj)
            -- The height test is loose and only there to reject something on a
            -- roof or under the pier that happens to share the column; the
            -- horizontal test is the one doing the identifying.
            if math.abs(c.z - z) <= 4.0 then
                for i, it in ipairs(items) do
                    local dx, dy = math.abs(c.x - it.x), math.abs(c.y - it.y)
                    if dx <= tol and dy <= tol then
                        local d = dx * dx + dy * dy
                        if not bestD[i] or d < bestD[i] then
                            bestD[i] = d
                            best[i] = { obj = obj, x = c.x, y = c.y, z = c.z }
                        end
                    end
                end
            end
        end
    end

    return best
end

--- Copy one prop where it stands, so it can be flown somewhere the original
--- cannot go.
---
--- ═══ WHY A COPY AND NOT THE PROP ITSELF ═══
---
--- The original belongs to client/loot.lua and is about to be deleted by it:
--- LOOT_GONE arrives in this same frame (see beginReset in
--- br_core/server/warmupcrates.lua, which sends this message first and retires
--- the entries second). Animating the original would be a tug of war with
--- despawn() that despawn() wins, and holding it back from despawn() would mean
--- reaching into that file's registry.
---
--- So the original is measured, copied, and left to be deleted on schedule. The
--- copy takes the ORIGINAL'S measured transform rather than anything the server
--- named, and that is the whole reason to copy rather than to build from the
--- message: the server's z is a hint with no ground probe behind it, and this
--- client resolved the real one when it built the prop.
---
--- NO MODEL REQUEST. The archetype is resident by construction -- an instance of
--- it is standing right there, and it is the thing being copied. Asking for it
--- again would either be a no-op or a yield inside an event handler, and the
--- honest fallback for a model that somehow is not loaded is no animation for
--- that one item.
--- @param found table  { obj, x, y, z }
--- @return integer|nil ghost
local function copyProp(found)
    local model = GetEntityModel(found.obj)
    if not model or model == 0 then return nil end
    if not isTrue(HasModelLoaded(model)) then return nil end

    local r = GetEntityRotation(found.obj, 2)
    local ghost = CreateObjectNoOffset(model, found.x, found.y, found.z,
                                       false, false, false)
    if not ghost or ghost == 0 then return nil end

    -- SCENERY, NOT AN OBSTACLE. Collision off so a player standing in the spill
    -- is not shoved by their own loot going home, and frozen so nothing about
    -- this is handed to physics for the half second it exists.
    SetEntityCollision(ghost, false, false)
    FreezeEntityPosition(ghost, true)
    SetEntityRotation(ghost, r.x, r.y, r.z, 2, true)
    SetEntityAsMissionEntity(ghost, false, true)
    return ghost
end

RegisterNetEvent(BR.Net.WARMUP_CRATE_RETURN)
AddEventHandler(BR.Net.WARMUP_CRATE_RETURN, function(d)
    if W.enabled == false then return end
    if type(d) ~= 'table' or type(d.items) ~= 'table' then return end
    if #d.items == 0 then return end

    local S = BR.WarmupCrates.stats
    S.returns = S.returns + 1

    local ms   = tonumber(d.ms) or W.returnMs or 520
    local lift = tonumber(d.lift) or W.mouthLift or 0.6
    local now  = GetGameTimer()

    local found = propsAt(d.items, d.z or 0.0)

    for i = 1, #d.items do
        local hit = found[i]
        local ghost = hit and copyProp(hit) or nil

        if ghost then
            flySeq = flySeq + 1
            flying[flySeq] = {
                obj = ghost,
                fromX = hit.x, fromY = hit.y, fromZ = hit.z,
                toX = d.x, toY = d.y, toZ = (d.z or hit.z) + lift,
                at = now, ms = math.max(1, ms),
            }
            S.flown = S.flown + 1
        else
            -- NOT AN ERROR, AND COUNTED RATHER THAN LOGGED. A player who is on
            -- the island but out of prop range has no object to copy and should
            -- see nothing; a message per item per reset would be a console full
            -- of the system working.
            S.missed = S.missed + 1
        end
    end
end)

--- Fly every returning prop into the crate, then delete it.
---
--- REGISTERED ALWAYS, RUNS ALMOST NEVER. One `next()` on an empty table is the
--- cost of this callback for the whole of a match; there is no state in which it
--- has work to do outside the half second after a reset.
BR.Loop.register(BR.Loop.FRAME, 'warmupcrates.return', function()
    if not next(flying) then return end

    local now = GetGameTimer()
    for k, r in pairs(flying) do
        local t = (now - r.at) / r.ms
        if t >= 1.0 or not isTrue(DoesEntityExist(r.obj)) then
            if isTrue(DoesEntityExist(r.obj)) then DeleteEntity(r.obj) end
            flying[k] = nil
        else
            local p = ease(t)
            -- LIFTS CLEAR OF THE GROUND FIRST, THEN TRAVELS. The same arc, and
            -- the same 0.25 of it, that client/loot.lua flies a claimed item to
            -- a player's hands along -- otherwise an item on the far side of the
            -- crate ploughs through the box on its way in.
            SetEntityCoordsNoOffset(r.obj,
                r.fromX + (r.toX - r.fromX) * p,
                r.fromY + (r.toY - r.fromY) * p,
                r.fromZ + (r.toZ - r.fromZ) * p + math.sin(t * math.pi) * 0.25,
                false, false, false)
            SetEntityHeading(r.obj, (t * 540.0) % 360.0)
        end
    end
end)

--- Delete every ghost immediately. Teardown, not animation.
---
--- AN UN-DELETED LOCAL OBJECT OUTLIVES THE RESOURCE THAT MADE IT, so this is not
--- optional: a restart mid-flight would leave a rifle hanging over the beach
--- forever with nothing left that knows it is there. client/loot.lua carries the
--- same handler for the same reason.
local function clearFlying()
    for k, r in pairs(flying) do
        if r.obj and isTrue(DoesEntityExist(r.obj)) then DeleteEntity(r.obj) end
        flying[k] = nil
    end
end

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    clearFlying()
end)

-- ---------------------------------------------------------------------------
-- The marker
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-09-04: "we'll draw their attention to these items by drawing a
-- bobbing 3dmarker type 0 over these crates... The color of each marker above
-- the crate will correspond to the rarity of it's loot."
--
-- ═══ WHY THIS IS TWO LOOPS AND NOT ONE ═══
--
-- DrawMarker draws for exactly one frame, so the CALL has to be on the frame
-- band -- there is no version of this that decides and draws at 10Hz and is
-- still visible. But almost nothing about the decision changes between frames:
-- which crates are in range, whether each is a husk, and what colour each one
-- is are answers good for a tenth of a second, and three of them cost natives.
--
-- So the TICK pass answers them into a small list and the FRAME pass does
-- nothing but walk it. The steady state on a frame is one integer comparison
-- and four DrawMarker calls, and every native that could have been called sixty
-- times a second is called ten times instead. This is the split client/loot.lua
-- arrived at the hard way for its glow, and BR.Loop's own band comments name it:
-- FRAME is "markers, prompts, control disables" and TICK is "proximity scans".
--
-- THE LAG THAT BUYS IS ONE TICK. A player sprinting past `drawM` keeps a marker
-- for up to 100ms after they should have lost it, at 250m, at the edge of
-- visibility. Turning the markers OFF is not subject to it -- the setter zeroes
-- the list itself, because "the tutorial ended" must be instant.

--- The marker's shape, or nil if nobody has configured one.
---
--- NO BLOCK, NO MARKER, which is config/revivekey.lua's rule and its reasoning:
--- an absent table is a feature nobody has set up rather than one to invent a
--- size and a colour for. Individual NUMBERS inside it do fall back, because a
--- number nobody has tuned is a starting point rather than an invention.
local M = W.marker

--- Is the tutorial (or /brwarmupmarkers) asking for these right now?
---
--- OFF BY DEFAULT AND THAT IS THE SPECIFICATION. These four cones exist to serve
--- the guided first run; a player on their fiftieth warmup has not asked to be
--- pointed at anything. See BR.WarmupCrates.markers below for the switch.
local markersOn = false

--- [anchorIndex] = { r, g, b } for that crate's authored rarity.
---
--- ═══ RESOLVED ONCE, AT LOAD, AND THAT IS SAFE FOR EXACTLY ONE REASON ═══
---
--- A crate's rarity is CONSTANT for the life of the server -- the contents are
--- rerolled every cycle and the rarity never is (BR.WarmupCrateStack takes it
--- from the anchor, not from a roll) -- so there is nothing here that can go
--- stale. The note on `rarity` in all() below states that invariant and this is
--- the table that spends it.
---
--- BR.RarityInfo AND NOT A PALETTE OF OUR OWN. Owner: "The color of each marker
--- ... will correspond to the rarity of it's loot", and the game already has one
--- answer to what a rarity looks like -- the same `rgb` client/loot.lua paints
--- its rarity discs with and the same row the NUI's `hex` borders come from.
--- Inventing a second set of four colours here would be a second thing to keep
--- in step with a table whose entire stated purpose is stopping that.
local MARKER_RGB = {}
do
    for i = 1, #W.anchors do
        -- Falling back to COMMON on an unknown rarity, exactly as
        -- client/loot.lua's glow does: a crate with a colour nobody recognises
        -- should be grey, not invisible and not a crash.
        local info = BR.RarityInfo[W.anchors[i].rarity]
                  or BR.RarityInfo[BR.Rarity.COMMON]
        MARKER_RGB[i] = info.rgb
    end
end

--- What the FRAME pass draws: reused rows, never rebuilt.
---
--- `drawN` IS THE LENGTH, not `#draw`. The rows are allocated once and then
--- written over forever, so the array stays four long while the count varies --
--- which is the whole point. A fresh table per crate per tick is 40 tables a
--- second of garbage for a feature whose answer changes about twice a match.
local draw  = {}
local drawN = 0

local TAU = math.pi * 2.0

--- Is this anchor's crate currently sealed? true / false / nil.
---
--- NIL IS "NOTHING IS PINNED THERE YET" and is a third answer rather than a
--- missing one: the prop has not been built (out of range, or streaming in), so
--- this client has not seen the crate and cannot say. all() hands the same
--- tri-state out and its note carries the warning.
--- @param i integer
--- @return boolean|nil
local function isSealed(i)
    local obj = pinned[i]
    if obj and isTrue(DoesEntityExist(obj)) then
        return GetEntityModel(obj) == MODELS[1]
    end
    return nil
end

--- How solid the marker over a crate in this state should be.
---
--- ═══ AN OPEN CRATE KEEPS ITS MARKER, DIMMED. IT DOES NOT LOSE IT ═══
---
--- Hiding it was the other candidate and it is wrong for two separate reasons,
--- either of which would be enough:
---
---   THE CRATE COMES BACK, AND SOON. These four reseal after `settleMs` (5s) of
---   nobody standing within `leaveRadius` -- so hiding the marker means it winks
---   out under the player who just opened it and winks back on BEHIND them as
---   they walk to the next one. Four crates 6-8m apart, all inside each other's
---   leave radius, makes that a row of markers flickering on and off at a
---   player's back. Nothing they did causes the return and nothing on screen
---   explains it.
---
---   AND THE MARKER'S JOB IS THE PLACE, NOT THE CONTENTS. It exists to say
---   "there is a crate here, and it pays this tier" to somebody being walked
---   through the game for the first time. A husk is still a place where a crate
---   is, and is about to be one again. The tutorial pointing at three of four
---   boxes because the fourth is mid-cycle is the pointer failing, not the
---   crate.
---
--- So the state goes in the ALPHA, which is the one channel the rarity is not
--- already using: full for a sealed crate, faint for a husk. "Already got this
--- one, it will fill up again" in a channel that costs nothing and cannot be
--- confused with the colour.
---
--- ═══ AND NIL IS TREATED AS SEALED, DELIBERATELY ═══
---
--- Tested as `sealed == false` and NOT as `not sealed`, which is the entire
--- difference between this working and this flickering. `not sealed` and
--- `sealed ~= true` both answer the same for nil and for false, and nil is the
--- ordinary case at range: the marker is drawn from the SURVEYED coordinates and
--- needs no prop (see `drawM`, which outruns the prop distance on purpose), so
--- for most of the way across the pad there is no pinned object to ask.
---
--- Treating that as "open" would draw every marker faint until its crate
--- streamed in and then snap it to full -- the exact failure all()'s own note
--- warns about, one line up from the accessor this replaces.
---
--- Sealed is also the right GUESS, not merely the safe one. A crate spends
--- almost all of its life closed; it is a husk only between somebody opening it
--- and the reset five seconds after they leave. So nil -> sealed means the
--- common case never changes appearance when the prop arrives, and the only
--- visible transition is the one a player caused by opening the box they are
--- standing at.
--- @param sealed boolean|nil
--- @return integer alpha
local function markerAlpha(sealed)
    if sealed == false then return math.tointeger(tonumber(M.openAlpha)) or 70 end
    return math.tointeger(tonumber(M.alpha)) or 200
end

-- ═══ 10 Hz: WHICH MARKERS, WHAT COLOUR, HOW SOLID ═══
--
-- Everything that is not the draw call itself.
BR.Loop.register(BR.Loop.TICK, 'warmupcrates.markers', function()
    -- CLEARED FIRST, UNCONDITIONALLY. Every refusal below leaves the list empty
    -- rather than leaving yesterday's list standing -- the failure otherwise is
    -- four markers frozen over the island for the rest of the match because the
    -- pass that would have removed them returned before it got to the removal.
    -- client/loot.lua's clearOutline carries the same note and the same scar.
    drawN = 0

    if not markersOn then return end
    if not M then return end
    if W.enabled == false then return end

    -- WARMUP AND NOTHING ELSE, for the reason onIsland() states: these anchors
    -- are a fixed point on the warmup island, and in any other state the player
    -- is kilometres away in a world where there is nothing standing there.
    if not onIsland() then return end

    -- FROM THE PED, NOT THE RENDERED CAMERA. client/markers.lua measures its
    -- beams from GetFinalRenderedCamCoord because they have to read from the bus
    -- 5km up, where the ped is nowhere near the view. Nothing like that happens
    -- here: onIsland() has already restricted this to WARMUP, where the player
    -- is on their own two feet behind their own camera, and the marker is
    -- something to walk to. revivekey.lua's chevron makes the same call in the
    -- same words.
    --
    -- A SECOND GetEntityCoords IN THE SAME TICK as the pin pass above, and left
    -- that way on purpose: sharing it would couple two passes that are otherwise
    -- independent (one can be disabled by /brloop without the other changing
    -- behaviour) to save one native call ten times a second.
    local p = GetEntityCoords(PlayerPedId())
    local reach = tonumber(M.drawM) or 250.0
    local reach2 = reach * reach

    for i = 1, #W.anchors do
        local a = W.anchors[i]
        if BR.Dist2(p.x, p.y, a.x, a.y) <= reach2 then
            drawN = drawN + 1
            local row = draw[drawN]
            if not row then
                row = {}
                draw[drawN] = row
            end
            local c = MARKER_RGB[i]
            row.x = a.x
            row.y = a.y
            -- THE SURVEYED z PLUS THE LIFT, and never a live read of the prop.
            -- The prop is pinned to this exact height by the pass above, so the
            -- two agree -- and this one is answerable when there is no prop at
            -- all, which is what lets the marker be up before the crate streams
            -- in. The bob is added per frame; this is the middle of its travel.
            row.z = a.z + (tonumber(M.lift) or 1.60)
            row.r, row.g, row.b = c[1], c[2], c[3]
            row.a = markerAlpha(isSealed(i))
        end
    end
end)

-- ═══ EVERY FRAME: THE DRAW, AND THE BOB ═══
--
-- REGISTERED ALWAYS, RUNS ALMOST NEVER -- the same shape as the return pass
-- above and for the same reason. Markers are off for the whole of a normal
-- session, so this callback's cost is one integer comparison per frame.
BR.Loop.register(BR.Loop.FRAME, 'warmupcrates.markers.draw', function()
    if drawN == 0 then return end

    -- `M` IS NOT NIL-CHECKED HERE AND DOES NOT NEED TO BE. drawN is zero unless
    -- the tick pass filled the list, and that pass refuses on `not M` before it
    -- can. The check belongs there rather than in both: this runs sixty times a
    -- second and that one answers the question ten.
    local kind = math.tointeger(tonumber(M.kind)) or 0
    local size = tonumber(M.size)   or 0.55
    local tall = tonumber(M.height) or 0.55
    local amp  = tonumber(M.bobM)   or 0.14
    -- FLOORED AT 1 BECAUSE IT IS A DIVISOR. A `bobMs` of 0 in the config would
    -- otherwise be a division by zero producing nan, and a nan z is a marker
    -- that silently never appears -- which is a config typo presenting as a
    -- broken feature.
    --
    -- `tonumber` AND NOT `math.tointeger`, which is the opposite of the choice
    -- made for `kind` two lines up and is right for the opposite reason. `kind`
    -- is handed to a native that takes an int, so a fractional one is nonsense
    -- and the default is the better answer. This is a divisor in Lua
    -- arithmetic, where 2200.5 is a perfectly good period -- and tointeger
    -- would answer nil for it and silently swap in the shipped 2200, which is a
    -- retune that appears to do nothing.
    local per  = math.max(1, tonumber(M.bobMs) or 2200)

    -- ONE PHASE, DRIVEN OFF THE SHARED CLOCK, SO ALL FOUR RISE TOGETHER.
    -- Computed once outside the loop rather than per marker: it is the same
    -- number for every one of them, which is the effect being asked for -- the
    -- row reads as one placed object rather than four things near each other.
    local bob = math.sin((GetGameTimer() % per) / per * TAU) * amp

    for i = 1, drawN do
        local d = draw[i]
        DrawMarker(kind, d.x, d.y, d.z + bob,
            0.0, 0.0, 0.0,      -- direction: unused for an axis-aligned marker
            0.0, 0.0, 0.0,      -- rotation: likewise
            size, size, tall,
            d.r, d.g, d.b, d.a,
            -- THE ENGINE'S OWN BOB IS OFF, AND THAT IS NOT AN OVERSIGHT. This
            -- argument is DrawMarker's `bobUpAndDown` and turning it on would
            -- stack a second, untunable oscillation on the sine above -- two
            -- bobs at two rates beating against each other. The bob here is the
            -- `bobM`/`bobMs` pair in config/warmupcrates.lua, which carries the
            -- full argument for why it is done in Lua. If you are here to make
            -- it bob, it already does: turn those numbers up.
            false,
            -- faceCamera off: a cone is a solid that reads from any angle, and
            -- billboarding one makes it swim as the player turns. Same reason
            -- rotate (below) is off -- a cone is rotationally symmetric about z,
            -- so spinning it costs a flag and shows nothing.
            false,
            2, false, nil, nil, false)
    end
end)

--- Turn the crate markers on or off. THE TUTORIAL'S ONLY WRITE INTO THIS FILE.
---
--- Owner's requirement is that they are off by default and exist to serve the
--- guided first run (#261), so this is a switch rather than a config flag: it is
--- expected to be thrown several times per player per session, and the caller is
--- br_core/client/tutorial.lua.
---
--- IDEMPOTENT, AND `on == true` RATHER THAN TRUTHINESS. BR.Tutorial.game's
--- convention, field for field: anything that is not exactly `true` is off, so a
--- caller that passes a native's 1/0 or a nil from a lookup cannot turn markers
--- on by accident.
---
--- OFF TAKES EFFECT ON THIS LINE, not on the next tick. The tick pass would
--- clear the list within 100ms anyway, but "the tutorial ended and there are
--- still cones up" is a visible wrong state and this costs one assignment to
--- make impossible.
--- @param on boolean
function BR.WarmupCrates.markers(on)
    on = on == true
    if on == markersOn then return end
    markersOn = on
    if not on then drawN = 0 end
end

--- Are they on? For a caller that has to ask rather than assert.
--- @return boolean
function BR.WarmupCrates.markersOn()
    return markersOn
end

-- NO TEARDOWN HANDLER, AND THE ABSENCE IS DELIBERATE. clearFlying above exists
-- because an un-deleted local OBJECT outlives the resource that made it; a
-- marker is not an object. It is a draw call that stops happening the moment
-- this file stops running, so there is nothing left behind to clean up.

-- The dev toggle. Markers are off in every ordinary session, so the only way to
-- look at them without running the whole tutorial is to ask for them.
--
-- NO THIRD ARGUMENT. br_lib/shared/devgate.lua wraps RegisterCommand for every
-- file that loads after it, so this is dev-gated for free; passing `true` would
-- make it ace-restricted instead, which FiveM's client console refuses outright
-- in production mode. Same rule, same reason, as /brwarmupcrates below.
RegisterCommand('brwarmupmarkers', function()
    BR.WarmupCrates.markers(not markersOn)
    -- WHY IT MIGHT STILL SHOW NOTHING, printed rather than left to be guessed
    -- at: on the lobby menu, or in a match, these anchors are kilometres away
    -- and the tick pass refuses. That is two of the three ways a toggled-on
    -- marker stays invisible and both are visible in this line.
    print(('[br_core] warmup crate markers: %s (warmup=%s, drawing=%d)')
        :format(markersOn and 'on' or 'off', tostring(onIsland()), drawN))
end)

-- ---------------------------------------------------------------------------
-- What the tutorial reads
-- ---------------------------------------------------------------------------

--- The four crates: where they are, and what rarity each one pays.
---
--- ═══ THIS IS THE WHOLE OF WHAT THE TUTORIAL NEEDS, AND IT IS READ-ONLY ═══
---
--- The tutorial draws a bobbing marker over each crate coloured by its rarity.
--- It needs a position, and a rarity to colour with; it does not need -- and
--- must not have -- the entry, the prop handle or anything that would let it
--- move one.
---
---   x, y, z, heading   the SURVEYED numbers, not a live read of a prop. They
---                      are also where the prop actually is, because that is the
---                      whole point of the pin above, and they are answerable
---                      before any prop has been built -- so a marker can be up
---                      the instant a player lands rather than a second later.
---   rarity             a BR.Rarity.*, CONSTANT for the life of the server. The
---                      contents are rerolled on every cycle and the rarity
---                      never is, which is what lets a caller resolve
---                      BR.RarityInfo[...] once and keep the colour.
---   sealed             true if this crate is currently closed, false if it is
---                      an open husk, and NIL IF NOTHING IS PINNED THERE YET --
---                      which is not a failure, it is a prop that has not been
---                      built, and a caller that treats nil as false will flip a
---                      marker every time one streams in. Observed from the
---                      model of the pinned object, so it is this client's own
---                      view of its own world.
---
--- A COPY PER CALL. The anchors are the shipped config table and a caller that
--- was handed it could edit the owner's surveyed coordinates by accident.
--- @return table[]
function BR.WarmupCrates.all()
    local out = {}
    for i = 1, #W.anchors do
        local a = W.anchors[i]
        out[i] = {
            index   = i,
            x = a.x, y = a.y, z = a.z,
            heading = a.heading,
            rarity  = a.rarity,
            -- THROUGH isSealed, WHICH THE MARKER PASS ALSO CALLS. This used to
            -- compare the model against MODELS[1] here, in its own words, and
            -- the marker section needed exactly the same answer -- so the
            -- tri-state that two readers depend on would have been spelled out
            -- twice, in two places, free to disagree about what nil means. It
            -- is spelled out once, up beside markerAlpha, which is where the
            -- argument about nil lives.
            sealed  = isSealed(i),
        }
    end
    return out
end

--- One of them, by index. Same shape and the same copy as all().
--- @param i integer
--- @return table|nil
function BR.WarmupCrates.get(i)
    if type(i) ~= 'number' or not W.anchors[i] then return nil end
    return BR.WarmupCrates.all()[i]
end

-- The client-side twin of the server's dump, and it answers a different
-- question: the server knows what the crate IS, and only a client knows what it
-- has actually got standing on the beach.
--
-- DEV-GATED FOR FREE. br_lib/shared/devgate.lua wraps RegisterCommand for every
-- file that loads after it, so there is no third argument here -- passing `true`
-- would make this ace-restricted instead, and FiveM's client console refuses
-- those outright in production mode.
--
-- `pins` VS `corrects` IS THE READING THAT MATTERS. A pin count that rises once
-- per open is the husk swap being caught; a corrects count that keeps rising
-- while nobody touches anything is a prop being pushed by something this file
-- has not accounted for.
RegisterCommand('brwarmupcrates', function()
    local S = BR.WarmupCrates.stats
    local p = GetEntityCoords(PlayerPedId())
    print(('[br_core] warmup crates: island=%s  pins=%d corrects=%d returns=%d flown=%d missed=%d')
        :format(tostring(onIsland()), S.pins, S.corrects, S.returns,
                S.flown, S.missed))
    for _, s in ipairs(BR.WarmupCrates.all()) do
        local info = BR.RarityInfo[s.rarity]
        local obj = pinned[s.index]
        local drift = 'no prop'
        if obj and isTrue(DoesEntityExist(obj)) then
            local c = GetEntityCoords(obj)
            drift = ('drift %.3fm'):format(
                BR.Dist3(c.x, c.y, c.z, s.x, s.y, s.z))
        end
        print(('  %d  %-9s  sealed=%-5s  %.1fm away  %s')
            :format(s.index, info and info.label or '?',
                    tostring(s.sealed), BR.Dist(p.x, p.y, s.x, s.y), drift))
    end
end)
