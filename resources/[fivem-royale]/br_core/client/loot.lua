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
local queue     = {}      -- ids waiting for a model
local queued    = {}      -- [id] = true, so the queue cannot double up
local draining  = false
local myCell    = nil     -- last cell reported to the server
local claimedAt = {}      -- [id] = gametimer, to stop a held key spamming claims

local hold = { id = nil, from = 0 }

local PROP_MAX = 80       -- hard ceiling on live objects, whatever the density

--- States in which loot is visible at all. LOBBY and WARMUP are absent: the
--- warmup pad is shared between matches and the vista is not in one.
local function canSee()
    local st = BR.State.me.state
    return st == BR.PlayerState.BUS or st == BR.PlayerState.FREEFALL
        or st == BR.PlayerState.GLIDE or st == BR.PlayerState.ALIVE
        or st == BR.PlayerState.DBNO or st == BR.PlayerState.DEAD
        or st == BR.PlayerState.SPECTATING
end

--- Only a player on their feet can take something.
local function canTake()
    return BR.State.me.state == BR.PlayerState.ALIVE
end

local function isContainer(e)
    return e.kind == 'chest' or e.kind == 'deathbox'
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

--- Ground height under an entry, cached. The server has no ground probe (the
--- native is client-side), so the authored z is only ever a hint -- and for
--- roadside filler it is not even that.
--- @param e table
--- @return number
local function groundZ(e)
    local now = GetGameTimer()
    if e.gz and now - (e.gzAt or 0) < 10000 then return e.gz end
    local from = math.max((e.z or 0.0) + 50.0, 300.0)
    local ok, gz = GetGroundZFor_3dCoord(e.x, e.y, from, false)
    e.gz = ok and gz or (e.z or 0.0)
    e.gzAt = now
    return e.gz
end

local function despawn(e)
    if e.obj and DoesEntityExist(e.obj) then DeleteEntity(e.obj) end
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
    entries, queue, queued = {}, {}, {}
    myCell, hold.id = nil, nil
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
                    local model = modelOf(e)
                    if model and IsModelValid(model) then
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
                                -- Collision off: a hundred boxes underfoot at a
                                -- hot drop is a player getting stuck on loot
                                -- during a fight.
                                SetEntityCollision(obj, false, false)
                                FreezeEntityPosition(obj, true)
                                SetEntityAsMissionEntity(obj, false, true)
                                PlaceObjectOnGroundProperly(obj)
                                e.obj = obj
                            end
                        end
                        SetModelAsNoLongerNeeded(model)
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
        if d.id and not entries[d.id] then
            entries[d.id] = {
                id = d.id, kind = d.kind, item = d.item,
                rarity = d.rarity or BR.Rarity.COMMON, count = d.count or 1,
                x = d.x, y = d.y, z = d.z, prop = d.prop,
            }
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
        local d2 = BR.Dist2(px, py, e.x, e.y)
        if d2 < bestD2 then best, bestD2 = e, d2 end
    end
    return best
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

    for _, e in pairs(entries) do
        local d2 = BR.Dist2(p.x, p.y, e.x, e.y)
        if d2 <= glow2 then
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

            if d2 <= label2 then
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

    if not canTake() then return end

    -- The prompt names the player's OWN binding. inputForCommand renders the
    -- key they actually have bound; the config token is the escape hatch if
    -- this build draws custom bindings as a hole (see PLAN.md and
    -- /brpromptcheck) -- it changes the GLYPH, never which key works.
    local target = nearestEntry(p.x, p.y, L.promptDistance)
    if target then
        local token = L.promptToken or BR.Native.inputForCommand('brinteract')
        if isContainer(target) then
            BR.Native.helpThisFrame(('Hold %s to open the %s')
                :format(token, target.kind == 'chest' and 'chest' or 'loot box'))
        else
            BR.Native.helpThisFrame(('Press %s to pick up %s')
                :format(token, labelOf(target)))
        end
    end

    -- The container hold. A chest is a commitment in the open -- one second
    -- standing still, visible to anyone watching the building.
    if hold.id then
        local e = entries[hold.id]
        if not e or BR.Dist2(p.x, p.y, e.x, e.y)
            > L.pickupDistance * L.pickupDistance then
            hold.id = nil
        else
            local pct = BR.Clamp((GetGameTimer() - hold.from)
                / (L.chestHoldMs or 1000), 0.0, 1.0)
            -- Drawn in Lua rather than through the NUI bridge: a progress bar
            -- that has to cross a resource boundary at 60fps to move is a
            -- progress bar that stutters.
            DrawRect(0.5, 0.62, 0.14, 0.012, 0, 0, 0, 160)
            DrawRect(0.5 - (0.14 * (1.0 - pct)) / 2.0, 0.62,
                0.14 * pct, 0.012, 255, 255, 255, 220)

            if pct >= 1.0 then
                local id = hold.id
                hold.id = nil
                TriggerServerEvent(BR.Net.LOOT_CLAIM, { id = id })
            end
        end
    end
end)

-- --------------------------------------------------------------------------
-- Input
-- --------------------------------------------------------------------------

BR.Keys.on('interact', function(pressed)
    if not pressed then
        hold.id = nil
        return
    end
    if not canTake() then return end

    local p = GetEntityCoords(PlayerPedId())
    local e = nearestEntry(p.x, p.y, L.pickupDistance)
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
end)

-- --------------------------------------------------------------------------
-- Debug
-- --------------------------------------------------------------------------

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
