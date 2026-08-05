-- World loot: the layout, the streaming grid, and claim arbitration.
--
-- ONE MATCH, ONE LAYOUT, LIVING ON THE INSTANCE. Exactly the shape storm.lua
-- settled on: state hangs off `m`, one globally-named scheduler job walks
-- BR.Server.eachMatch. Per-match jobs are not merely unnecessary, they are
-- impossible -- BR.Sched.every hard-errors on a duplicate name -- and teardown
-- is data (m.loot = nil), not cancellation.
--
-- THE CLIENT IS TOLD, NEVER SHOWN THE SEED. The layout is generated here from
-- a seed and streamed cell by cell as players walk into range. Handing the
-- client the seed instead would be one line shorter and would ship a wallhack:
-- every item on the map, derivable at leisure, forever.
--
-- CLAIMS ARE ARBITRATED, NOT ANNOUNCED. Two players reaching the same rifle in
-- the same tick is the normal case at a hot drop, not an edge case; exactly one
-- of them gets it here, and the loser is TOLD (refusals are audible, the rule
-- the bus jump handler earned the hard way).

BR = BR or {}
BR.Loot = BR.Loot or {}

local L = BR.Config.Loot

-- Which player states may see and take loot. LOBBY and WARMUP are deliberately
-- absent: a bystander at the vista has no business streaming a match's items,
-- and the warmup pad is shared between matches.
local CAN_SEE = {
    [BR.PlayerState.BUS]      = true,
    [BR.PlayerState.FREEFALL] = true,
    [BR.PlayerState.GLIDE]    = true,
    [BR.PlayerState.ALIVE]    = true,
    [BR.PlayerState.DBNO]     = true,
    [BR.PlayerState.DEAD]     = true,
    [BR.PlayerState.SPECTATING] = true,
}

-- Only a player standing on their own two feet can pick something up.
local CAN_TAKE = {
    [BR.PlayerState.ALIVE] = true,
}

-- --------------------------------------------------------------------------
-- Wire shapes
-- --------------------------------------------------------------------------

--- The client's view of a ground entry. Container CONTENTS never travel: what
--- is in a chest is the reason to open it, and a client that knew would only
--- open the good ones.
--- @param e table
--- @return table
local function wireEntry(e)
    return {
        id     = e.id,
        kind   = e.kind,
        item   = e.item,
        rarity = e.rarity,
        count  = e.count,
        x      = e.x,
        y      = e.y,
        z      = e.z,
        prop   = e.prop,
    }
end

-- --------------------------------------------------------------------------
-- The registry
-- --------------------------------------------------------------------------

--- Index one entry into its cell.
--- @param loot table
--- @param e table
local function index(loot, e)
    local key = BR.LootCellKeyAt(e.x, e.y)
    e.cell = key
    local cell = loot.cells[key]
    if not cell then
        cell = {}
        loot.cells[key] = cell
    end
    cell[e.id] = true
    loot.items[e.id] = e
end

--- Everyone currently subscribed to a cell.
--- @param m table
--- @param key string
--- @return integer[]
local function subscribersOf(m, key)
    local out = {}
    for src, keys in pairs(m.loot.subs) do
        if keys[key] then out[#out + 1] = src end
    end
    table.sort(out)
    return out
end

--- Announce a new entry to everyone already looking at its cell.
--- @param m table
--- @param e table
local function announce(m, e)
    local payload = { wireEntry(e) }
    for _, src in ipairs(subscribersOf(m, e.cell)) do
        TriggerClientEvent(BR.Net.LOOT_ADD, src, payload)
    end
end

--- Remove an entry and tell everyone looking at it.
--- @param m table
--- @param e table
local function retire(m, e)
    local cell = m.loot.cells[e.cell]
    if cell then cell[e.id] = nil end
    m.loot.items[e.id] = nil

    local payload = { e.id }
    for _, src in ipairs(subscribersOf(m, e.cell)) do
        TriggerClientEvent(BR.Net.LOOT_GONE, src, payload)
    end
end

--- Put a stack into the world.
--- @param m table
--- @param stack table
--- @param x number
--- @param y number
--- @param z number
--- @return table|nil entry
function BR.Loot.spawnStack(m, stack, x, y, z)
    if not m or not m.loot or not stack then return nil end

    m.loot.nextId = m.loot.nextId + 1
    local e = {
        id     = m.loot.nextId,
        item   = stack.item,
        kind   = stack.kind,
        rarity = stack.rarity,
        count  = stack.count or 1,
        clip   = stack.clip,
        x = x, y = y, z = z,
        prop   = stack.prop,
        contents = stack.contents,
        dropped = true,
    }
    index(m.loot, e)
    announce(m, e)
    return e
end

--- Drop a stack at a player's feet. The inventory calls this.
--- @param src integer
--- @param stack table
--- @return table|nil entry
function BR.Loot.dropForPlayer(src, stack)
    local m = BR.Server.matchOf(src)
    local e = BR.Roster.get(src)
    if not m or not m.loot or not e or not e.pos then return nil end
    return BR.Loot.spawnStack(m, stack, e.pos.x, e.pos.y, e.pos.z)
end

-- --------------------------------------------------------------------------
-- Lifecycle
-- --------------------------------------------------------------------------

--- Generate a match's loot.
---
--- Called at WARMUP, not at PLAYING: players land during BUS, and an item that
--- appears the moment the state machine ticks over is an item that was not
--- there when the first player ran past it.
---
--- @param m table
--- @param seed integer|nil
function BR.Loot.begin(m, seed)
    -- Folded with a prime of its own, exactly as the storm (7919) and the bus
    -- (104729) do, so two matches minted in the same server millisecond do not
    -- lay out the same map.
    seed = seed or (GetGameTimer() + m.id * 15485863)

    m.loot = {
        seed   = seed,
        nextId = 0,
        items  = {},
        cells  = {},
        subs   = {},
        at     = {},
    }

    local entries, stats = BR.BuildLootLayout(seed)
    for _, e in ipairs(entries) do
        m.loot.nextId = math.max(m.loot.nextId, e.id)
        index(m.loot, e)
    end

    print(('[br_core] loot: match %d seeded %d -- %d items, %d chests, %d filler across %d cells')
        :format(m.id, seed, stats.poi, stats.chest, stats.filler,
                (function()
                    local n = 0
                    for _ in pairs(m.loot.cells) do n = n + 1 end
                    return n
                end)()))
end

--- Forget a match's loot. The clients tear their own props down off the state
--- transition, so there is nothing to un-send here.
--- @param m table
function BR.Loot.clear(m)
    if m then m.loot = nil end
end

-- --------------------------------------------------------------------------
-- Streaming
-- --------------------------------------------------------------------------

--- The entries a player should be holding right now, for the snapshot.
--- @param src integer
--- @return table|nil
function BR.Loot.viewFor(src)
    local m = BR.Server.matchOf(src)
    local e = BR.Roster.get(src)
    if not m or not m.loot or not e or not CAN_SEE[e.state] then return nil end

    local keys = m.loot.subs[src]
    if not keys then return nil end

    local out = {}
    for key in pairs(keys) do
        for id in pairs(m.loot.cells[key] or {}) do
            local entry = m.loot.items[id]
            if entry then out[#out + 1] = wireEntry(entry) end
        end
    end
    -- Sorted: a snapshot is compared against by tests, and an unordered one
    -- would be a different payload every run.
    table.sort(out, function(a, b) return a.id < b.id end)
    return out
end

RegisterNetEvent(BR.Net.LOOT_CELL)
AddEventHandler(BR.Net.LOOT_CELL, function(d)
    local src = source
    if type(d) ~= 'table' then return end

    local cx = math.tointeger(d.cx)
    local cy = math.tointeger(d.cy)
    if not cx or not cy then return end

    local m = BR.Server.matchOf(src)
    local e = BR.Roster.get(src)
    if not m or not m.loot or not e or not CAN_SEE[e.state] then return end

    local centre = BR.LootCellKey(cx, cy)
    if m.loot.at[src] == centre then return end   -- nothing moved
    m.loot.at[src] = centre

    local want = {}
    for _, key in ipairs(BR.LootCellsAround(cx, cy)) do want[key] = true end

    local had = m.loot.subs[src] or {}

    -- Entering scope.
    local adds = {}
    for key in pairs(want) do
        if not had[key] then
            for id in pairs(m.loot.cells[key] or {}) do
                local entry = m.loot.items[id]
                if entry then adds[#adds + 1] = wireEntry(entry) end
            end
        end
    end

    -- Leaving it.
    local gone = {}
    for key in pairs(had) do
        if not want[key] then
            for id in pairs(m.loot.cells[key] or {}) do
                gone[#gone + 1] = id
            end
        end
    end

    m.loot.subs[src] = want

    if #adds > 0 then TriggerClientEvent(BR.Net.LOOT_ADD, src, adds) end
    if #gone > 0 then TriggerClientEvent(BR.Net.LOOT_GONE, src, gone) end
end)

-- --------------------------------------------------------------------------
-- Claims
-- --------------------------------------------------------------------------

--- Is this player close enough to that entry to have taken it?
---
--- The position being compared is the roster's own 2Hz sample, so it can be
--- half a second stale -- a sprinting player covers ~3.5m in that time, which
--- is the entire pickup radius. Without a slack term the honest claims of
--- anyone moving get refused, which is the same class of skew the storm's edge
--- cushion exists for, and the same fix.
--- @param e table roster entry
--- @param item table
--- @return boolean
local function inReach(e, item)
    if not e.pos then return false end
    local slack = 4.0
    local d = BR.Dist(e.pos.x, e.pos.y, item.x, item.y)
    if d > (L.pickupDistance + slack) then return false end
    -- Vertical too, generously: a player on the floor above is not reaching
    -- the rifle downstairs, but a first-pass POI z can be metres out.
    return math.abs((e.pos.z or 0.0) - (item.z or 0.0)) < 12.0
end

--- Token-bucket rate limit on claims.
--- @param e table roster entry
--- @return boolean allowed
local function rateOk(e)
    local now = GetGameTimer()
    if not e.lootWindow or now - e.lootWindow >= 1000 then
        e.lootWindow, e.lootClaims = now, 0
    end
    e.lootClaims = e.lootClaims + 1
    return e.lootClaims <= (L.pickupRateLimit or 4)
end

--- Scatter a container's contents on the ground around it.
--- @param m table
--- @param container table
local function scatter(m, container)
    local contents = container.contents or {}
    local n = #contents
    if n == 0 then return end

    -- A ring, not a random spray: everything lands visible and reachable, and
    -- two players opening the same chest see the same arrangement.
    local spread = L.deathBoxSpread or 0.8
    local radius = math.max(spread, 0.55 * n * spread)
    for i, stack in ipairs(contents) do
        local a = (i / n) * math.pi * 2.0
        BR.Loot.spawnStack(m, stack,
            container.x + math.cos(a) * radius,
            container.y + math.sin(a) * radius,
            container.z)
    end
end

RegisterNetEvent(BR.Net.LOOT_CLAIM)
AddEventHandler(BR.Net.LOOT_CLAIM, function(d)
    local src = source
    if type(d) ~= 'table' then return end

    local id = math.tointeger(d.id)
    if not id then return end

    local m = BR.Server.matchOf(src)
    local e = BR.Roster.get(src)
    if not m or not m.loot or not e then return end

    if not CAN_TAKE[e.state] then
        BR.Server.notify(src, 'You cannot pick that up right now.', 'warn')
        return
    end

    if not rateOk(e) then
        -- Not announced to the player: at four claims a second this is either
        -- a stuck key or a script, and neither deserves a toast per frame.
        print(('[br_core] loot: %s (%d) is claiming faster than %d/s -- refused')
            :format(e.name, src, L.pickupRateLimit or 4))
        return
    end

    -- FIRST CLAIM WINS, and the loser hears about it. This is the whole
    -- arbitration: the entry is gone from the table before anything else
    -- happens, so a second claim in the same tick finds nothing.
    local item = m.loot.items[id]
    if not item then
        BR.Server.notify(src, 'Someone beat you to it.', 'warn')
        return
    end

    if not inReach(e, item) then
        BR.Server.notify(src, 'Too far away.', 'warn')
        return
    end

    if item.kind == 'chest' or item.kind == 'deathbox' then
        retire(m, item)
        scatter(m, item)
        return
    end

    local ok, displaced, reason = BR.Inv.give(src, item)
    if not ok then
        if reason == 'full' then
            BR.Server.notify(src, 'No room for that.', 'warn')
        elseif reason == 'ammofull' then
            BR.Server.notify(src, 'Already carrying the maximum.', 'warn')
        end
        return
    end

    retire(m, item)

    -- A weapon swapped out of a full inventory lands where the player stands.
    if displaced then
        BR.Loot.spawnStack(m, displaced, item.x, item.y, item.z)
    end
end)

-- --------------------------------------------------------------------------
-- Death boxes
-- --------------------------------------------------------------------------

--- Turn what a player was carrying into a box on the ground.
---
--- Called from combat.eliminate BEFORE the inventory is reset, which is the
--- only moment both the contents and the position are still true.
--- @param m table
--- @param src integer
--- @return table|nil entry
function BR.Loot.deathBox(m, src)
    if not m or not m.loot then return nil end

    local e = BR.Roster.get(src)
    if not e or not e.pos then return nil end

    local contents = BR.Inv.dropAll(src)
    BR.Inv.push(src)
    if #contents == 0 then return nil end

    return BR.Loot.spawnStack(m, {
        item     = 'deathbox',
        kind     = 'deathbox',
        rarity   = BR.LootContentsRarity(contents),
        count    = 1,
        prop     = L.deathBoxProp,
        contents = contents,
    }, e.pos.x, e.pos.y, e.pos.z)
end

-- --------------------------------------------------------------------------
-- Housekeeping
-- --------------------------------------------------------------------------

-- Subscriptions belong to players, and players leave. Left behind they would
-- keep a departed src in every announce() loop for the rest of the match.
BR.Sched.every(5000, 'loot.sweep', function()
    BR.Server.eachMatch(function(m)
        if not m.loot then return end
        for src in pairs(m.loot.subs) do
            local e = BR.Roster.get(src)
            if not e or e.matchId ~= m.id or not CAN_SEE[e.state] then
                m.loot.subs[src] = nil
                m.loot.at[src] = nil
            end
        end
    end)
end)
