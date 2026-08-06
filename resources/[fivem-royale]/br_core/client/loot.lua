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

local L = BR.Config.Loot

local entries   = {}      -- [id] = entry, with prop bookkeeping attached
local byObject  = {}      -- [objectHandle] = id, so a ray hit resolves instantly
local queue     = {}      -- ids waiting for a model
local queued    = {}      -- [id] = true, so the queue cannot double up
local draining  = false
local myCell    = nil     -- last cell reported to the server
local claimedAt = {}      -- [id] = gametimer, to stop a held key spamming claims
local reported  = {}      -- [id] = true, entries already sent back as misplaced

local hold = { id = nil, from = 0 }
local lastPrompt = { id = nil, at = 0, pct = -1 }

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
    -- Water ABOVE the ground here means the ground is a seabed.
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
    if e.obj then
        byObject[e.obj] = nil
        if DoesEntityExist(e.obj) then DeleteEntity(e.obj) end
    end
    e.obj = nil
end

local function forget(id)
    local e = entries[id]
    if not e then return end
    despawn(e)
    entries[id] = nil
    queued[id] = nil
    if hold.id == id then hold.id = nil end
end

local function forgetAll()
    for id in pairs(entries) do forget(id) end
    entries, queue, queued, byObject, reported = {}, {}, {}, {}, {}
    myCell, hold.id = nil, nil
    -- Inline rather than through pushPrompt(): that lives below this, and a
    -- local referenced before its declaration silently resolves as a global.
    lastPrompt.id, lastPrompt.pct = nil, -1
    TriggerEvent('br:ui:sendLocal', BR.Nui.PROMPT, { show = false })
end

-- The spawn worker. Model loading is asynchronous, so this cannot live in a
-- loop callback -- and a burst of RequestModel in one frame is exactly how a
-- landing at a dense POI turns into a stutter. Two per pass, then yield.
local function drain()
    if draining then return end
    draining = true

    Citizen.CreateThread(function()
        while #queue > 0 do
            for _ = 1, 2 do
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
                            local obj = CreateObjectNoOffset(model,
                                e.x, e.y, gz + 0.35, false, false, false)
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
                                if e.heading then
                                    SetEntityHeading(obj, e.heading)
                                end
                                PlaceObjectOnGroundProperly(obj)
                                -- CRATES ARE PHYSICAL. Drive into one and it
                                -- moves (user call, 2026-08-05). Only the
                                -- LOCAL prop moves -- the entry's authoritative
                                -- position never changes, so a crate shunted
                                -- across a car park is still looted from where
                                -- the server thinks it is, and every client
                                -- sees its own version of the shunt. Worth it
                                -- for a world that reacts; revisit if the
                                -- disagreement ever matters.
                                --
                                -- Loose floor items stay frozen: a rifle
                                -- skittering down a hill is not a feature.
                                FreezeEntityPosition(obj, not solid)
                                if solid then SetEntityDynamic(obj, true) end
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
    for _, id in ipairs(ids or {}) do forget(id) end
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

-- Cell subscription. 1Hz is the band whose comment has said "loot cells" since
-- M0; a 256m cell takes 25 seconds to cross on foot and 8 in a car.
BR.Loop.register(BR.Loop.SLOW, 'loot.cells', function()
    if not canSee() then
        if myCell then forgetAll() end
        return
    end

    local p = GetEntityCoords(PlayerPedId())
    local cx, cy = BR.LootCellOf(p.x, p.y)
    local key = BR.LootCellKey(cx, cy)
    if key == myCell then return end

    myCell = key
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

    for id, e in pairs(entries) do
        local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
        if e.obj then
            live = live + 1
            if d2 > far * far or not DoesEntityExist(e.obj) then despawn(e) end
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
    return nearestEntry(px, py, L.pickupDistance)
end

--- Push the world-anchored prompt to the UI, or clear it.
---
--- Throttled and change-gated: the bridge to br_ui crosses a resource
--- boundary, and a per-frame push of an unchanged prompt would put 60 messages
--- a second on it for no visible difference. The RING is driven UI-side from
--- the same numbers, so a dropped frame here does not stall it.
--- @param e table|nil
--- @param pct number|nil
local function pushPrompt(e, pct)
    local now = GetGameTimer()
    local id  = e and e.id or nil

    if not e then
        if lastPrompt.id == nil then return end
        lastPrompt.id, lastPrompt.pct = nil, -1
        TriggerEvent('br:ui:sendLocal', BR.Nui.PROMPT, { show = false })
        return
    end

    local onScreen, sx, sy = BR.Native.worldToScreen(e.x, e.y, groundZ(e) + 0.9)
    if not onScreen then
        if lastPrompt.id ~= nil then
            lastPrompt.id, lastPrompt.pct = nil, -1
            TriggerEvent('br:ui:sendLocal', BR.Nui.PROMPT, { show = false })
        end
        return
    end

    pct = pct or 0.0
    local moved = id ~= lastPrompt.id or math.abs(pct - lastPrompt.pct) > 0.01
    if not moved and now - lastPrompt.at < 60 then return end

    lastPrompt.id, lastPrompt.pct, lastPrompt.at = id, pct, now

    local container = isContainer(e)
    TriggerEvent('br:ui:sendLocal', BR.Nui.PROMPT, {
        show   = true,
        x      = sx,
        y      = sy,
        label  = labelOf(e),
        hint   = container and 'Hold to open' or 'Press to pick up',
        -- The player's ACTUAL binding, read back from the control. Rebinding
        -- INPUT_CONTEXT in GTA's settings changes what this says.
        key    = BR.Native.keyLabel(L.promptControl or 51),
        rarity = e.rarity,
        pct    = pct,
        ring   = container,
    })
end

-- Glow, labels, the prompt and the container hold, all off one pass over the
-- entries in range. Disable with /brloop disable loot.render -- the loot still
-- works, which is the same drill the storm renderer answers to.
BR.Loop.register(BR.Loop.FRAME, 'loot.render', function()
    if not canSee() or not next(entries) then return end

    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local glow2  = L.glowDistance * L.glowDistance
    local label2 = L.labelDistance * L.labelDistance

    -- The shine pulses on a shared clock so every crate breathes together --
    -- individually-phased glows read as flickering rather than as a beacon.
    local pulse = 0.72 + 0.28 * math.sin(GetGameTimer() / 380.0)

    for _, e in pairs(entries) do
        local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
        -- A husk is scenery. Glowing it would send players across open ground
        -- for a crate somebody already emptied, which is the exact opposite of
        -- what the open-crate model is for.
        if d2 <= glow2 and not isHusk(e) then
            local gz = groundZ(e)
            local info = BR.RarityInfo[e.rarity] or BR.RarityInfo[BR.Rarity.COMMON]
            local c = info.rgb
            -- A flat disc rather than a sphere: it reads as "something is
            -- here" from across a room without swallowing the item itself.
            DrawMarker(1, e.x, e.y, gz - 0.05,
                0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
                0.45, 0.45, 0.12,
                c[1], c[2], c[3], 120,
                false, false, 2, false, nil, nil, false)

            -- CRATES SHINE. A real light in the world, not a screen effect:
            -- it spills onto the ground and the wall behind, which is what
            -- makes a crate readable through a doorway or round a corner
            -- (user call, 2026-08-05). Containers only -- a lit-up floor
            -- rifle would drown the crates it is meant to sit beside.
            if isContainer(e) then
                DrawLightWithRange(e.x, e.y, gz + 0.5,
                    c[1], c[2], c[3], 4.0 * pulse, 1.6 * pulse)
            end

            -- The floor label stays for LOOSE items: a rifle in the grass
            -- needs naming from further away than you would ever stand to
            -- pick it up. Containers are named by the prompt instead.
            if d2 <= label2 and not isContainer(e) then
                SetDrawOrigin(e.x, e.y, gz + 0.55, 0)
                SetTextFont(4)
                SetTextScale(0.0, 0.32)
                SetTextColour(c[1], c[2], c[3], 220)
                SetTextCentre(true)
                SetTextOutline()
                BeginTextCommandDisplayText('STRING')
                AddTextComponentSubstringPlayerName(labelOf(e))
                EndTextCommandDisplayText(0.0, 0.0)
                ClearDrawOrigin()
            end
        end
    end

    if not canTake() then
        pushPrompt(nil)
        return
    end

    -- THE HOLD. A crate is a commitment in the open -- a second standing
    -- still, visible to anyone watching the building. The ring is drawn over
    -- the crate itself by the UI, from the percentage sent here.
    if hold.id then
        local e = entries[hold.id]
        if not e or BR.Dist2(p.x, p.y, e.x, e.y)
            > L.pickupDistance * L.pickupDistance then
            hold.id = nil
        else
            local pct = BR.Clamp((GetGameTimer() - hold.from)
                / (L.chestHoldMs or 1000), 0.0, 1.0)
            pushPrompt(e, pct)

            if pct >= 1.0 then
                local id = hold.id
                hold.id = nil
                TriggerServerEvent(BR.Net.LOOT_CLAIM, { id = id })
                pushPrompt(nil)
                -- The reveal. Played locally the instant the hold completes
                -- rather than waiting for the server's answer: the sound is
                -- feedback for the ACTION, and a lock that clicks a round-trip
                -- later feels broken even when it worked.
                local snd = L.openSound
                if snd then PlaySoundFrontend(-1, snd.name, snd.set, true) end
            end
            return
        end
    end

    pushPrompt(targetEntry(p.x, p.y), 0.0)
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

-- TWO INPUTS, ONE ACTION. The prompt draws ~INPUT_CONTEXT~ because a custom
-- binding's token renders as a blank hole on this build (settled in-game
-- 2026-08-05, /brpromptcheck), and a prompt showing a key that does nothing is
-- worse than no prompt -- so GTA's own context control works too. Ours still
-- works alongside it, and both are things the player configures.
BR.Loop.register(BR.Loop.FRAME, 'loot.interact', function()
    if not canTake() then return end
    local control = L.promptControl
    if not control then return end

    if IsControlJustPressed(0, control) then
        interactPressed()
    elseif hold.id and not IsControlPressed(0, control)
           and not BR.Keys.isHeld('interact') then
        -- Released: either input letting go cancels, so long as neither is
        -- still down.
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

local function clearBlips()
    for id, b in pairs(blips) do
        if DoesBlipExist(b) then RemoveBlip(b) end
        blips[id] = nil
    end
end

BR.Loop.register(BR.Loop.SLOW, 'loot.devblips', function()
    if not blipsOn then
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
            SetBlipSprite(b, isContainer(e) and 68 or 1)
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
end, false)

--- Which prompt glyph actually renders.
---
--- PLAN.md records that ~INPUT_<hash>~ for a RegisterKeyMapping binding drew
--- as a HOLE on this build, which is why the bus prompt fell back to a vanilla
--- token. This prints both so one in-game look settles which to ship -- and
--- either way the KEY is the player's own binding; only the picture changes.
RegisterCommand('brpromptcheck', function()
    local custom = BR.Native.inputForCommand('brinteract')
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
