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

-- Forward declaration. zoneFor() needs the warmup zone, which is built further
-- down, but the spawn helpers above it need zoneFor -- and a local referenced
-- before its `local` statement resolves as a GLOBAL, which is nil at runtime
-- and silent at load.
local zoneFor

-- Which player states may see loot. LOBBY is the only one that cannot: a
-- bystander at the vista is not in the world. WARMUP sees the SHARED island
-- layout rather than any match's -- see zoneFor().
local CAN_SEE = {
    [BR.PlayerState.WARMUP]   = true,
    [BR.PlayerState.BUS]      = true,
    [BR.PlayerState.FREEFALL] = true,
    [BR.PlayerState.GLIDE]    = true,
    [BR.PlayerState.ALIVE]    = true,
    [BR.PlayerState.DBNO]     = true,
    [BR.PlayerState.DEAD]     = true,
    [BR.PlayerState.SPECTATING] = true,
}

-- Only a player standing on their own two feet can pick something up -- and on
-- the warmup pad, where the whole point is early practice PVP.
local CAN_TAKE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,
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
        id      = e.id,
        kind    = e.kind,
        item    = e.item,
        rarity  = e.rarity,
        count   = e.count,
        x       = e.x,
        y       = e.y,
        z       = e.z,
        prop    = e.prop,
        heading = e.heading,
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
--- @param m table    a match, or the shared warmup zone
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
        heading = stack.heading,
        contents = stack.contents,
        warmup = stack.warmup,
        dropped = true,
    }
    index(m.loot, e)
    announce(m, e)
    return e
end

--- Leave an opened crate standing where the sealed one was.
---
--- A husk is not loot: it cannot be claimed and it carries no rarity. It is
--- there so a room you have already swept reads as swept from the doorway,
--- which is the entire reason the open-crate model exists.
--- @param m table
--- @param crate table
local function leaveHusk(m, crate)
    if crate.kind ~= 'chest' then return end
    BR.Loot.spawnStack(m, {
        item    = 'husk',
        kind    = 'husk',
        rarity  = BR.Rarity.COMMON,
        count   = 1,
        prop    = L.chestOpenProp,
        heading = crate.heading,
    }, crate.x, crate.y, crate.z)
end

--- Drop a stack at a player's feet. The inventory calls this.
--- @param src integer
--- @param stack table
--- @return table|nil entry
function BR.Loot.dropForPlayer(src, stack)
    local e = BR.Roster.get(src)
    if not e or not e.pos then return nil end
    local m = zoneFor(src)
    if not m then return nil end
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
        seed    = seed,
        nextId  = 0,
        items   = {},
        cells   = {},
        subs    = {},
        at      = {},
        respawn = {},
        fixed   = 0,
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
-- The shared warmup zone
-- --------------------------------------------------------------------------

-- ONE LAYOUT FOR EVERYBODY WAITING. The warmup pad is a COMMUNAL routing
-- bucket -- every concurrent match's warmup players stand on it together --
-- so a per-match layout would put two players side by side looking at
-- different crates in the same spot.
--
-- It is a pseudo-match: same `loot` shape, so every function above operates on
-- it unchanged. Id 0, which no real match can have (BR.Server.matchId starts
-- at 1), so a stray lookup cannot collide.
local warmupZone = nil

--- [src] = the loot registry this player is currently subscribed to (a match
--- id, or 0 for the shared warmup pad). Crossing between them invalidates
--- every id the client is holding.
local zoneOf = {}

--- The shared warmup zone, built on first use.
--- @return table
local function warmup()
    if warmupZone then return warmupZone end

    local W = BR.Config.Loot.warmup
    warmupZone = {
        id     = 0,
        warmup = true,
        state  = BR.MatchState.WARMUP,
        loot   = {
            seed = GetGameTimer(), nextId = 0, items = {}, cells = {},
            subs = {}, at = {}, respawn = {}, fixed = 0,
        },
    }
    warmupZone.rng = BR.Rng(warmupZone.loot.seed + 5779)

    for _, e in ipairs(BR.BuildWarmupLayout(warmupZone.loot.seed)) do
        warmupZone.loot.nextId = math.max(warmupZone.loot.nextId, e.id)
        index(warmupZone.loot, e)
    end

    print(('[br_core] loot: warmup pad stocked with %d crates (shared)')
        :format(W.crates or 0))
    return warmupZone
end

--- Which loot registry this player is looking at.
---
--- A WARMUP player sees the shared island; everyone else sees their own
--- match. This is the single place that decision is made -- every handler
--- below goes through it, so there is no path where a warmup player can reach
--- a match's items or the reverse.
--- @param src integer
--- @return table|nil zone
zoneFor = function(src)
    local e = BR.Roster.get(src)
    if not e then return nil end
    if e.state == BR.PlayerState.WARMUP then return warmup() end
    local m = BR.Server.matchOf(src)
    if m and m.loot then return m end
    return nil
end

-- --------------------------------------------------------------------------
-- Streaming
-- --------------------------------------------------------------------------

--- The entries a player should be holding right now, for the snapshot.
--- @param src integer
--- @return table|nil
function BR.Loot.viewFor(src)
    local e = BR.Roster.get(src)
    if not e or not CAN_SEE[e.state] then return nil end
    local m = zoneFor(src)
    if not m then return nil end

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

    local e = BR.Roster.get(src)
    if not e or not CAN_SEE[e.state] then return end
    local m = zoneFor(src)
    if not m then return end

    -- CROSSING BETWEEN THE PAD AND A MATCH is not a cell move, it is a new
    -- world. Ids mean different things in the two registries, so the old
    -- subscription is dropped whole (the client is told to forget those ids)
    -- rather than diffed against the new one.
    if zoneOf[src] ~= m.id then
        local prev = zoneOf[src] == 0 and warmupZone or BR.Server.matchById(zoneOf[src])
        if prev and prev.loot then
            local stale = {}
            for key in pairs(prev.loot.subs[src] or {}) do
                for id in pairs(prev.loot.cells[key] or {}) do
                    stale[#stale + 1] = id
                end
            end
            prev.loot.subs[src] = nil
            prev.loot.at[src] = nil
            if #stale > 0 then TriggerClientEvent(BR.Net.LOOT_GONE, src, stale) end
        end
        zoneOf[src] = m.id
    end

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

    local e = BR.Roster.get(src)
    if not e then return end
    local m = zoneFor(src)
    if not m then return end

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

    if item.kind == 'husk' then
        return   -- an already-looted crate; nothing to take
    end

    if item.kind == 'chest' or item.kind == 'deathbox' then
        retire(m, item)
        scatter(m, item)
        leaveHusk(m, item)
        if item.warmup then
            -- The pad must never end up stripped bare by whoever queued
            -- first: a looted crate comes back somewhere else on the island.
            m.loot.respawn[#m.loot.respawn + 1] = {
                at   = GetGameTimer() + (BR.Config.Loot.warmup.respawnMs or 45000),
                tier = BR.Config.Loot.warmup.tier or 2,
            }
        end
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

-- --------------------------------------------------------------------------
-- The repair round-trip
-- --------------------------------------------------------------------------

--- How far a client may move an entry. Generous enough to walk an item off a
--- rooftop or out of the surf, far too small to relocate loot somewhere
--- useful to the reporter.
local FIX_RADIUS = 30.0

-- ONLY A CLIENT CAN GROUND-PROBE. GetGroundZFor_3dCoord and GetWaterHeight are
-- client natives, and the server has no map at all -- so an entry that
-- generation put in the sea or under a bridge can only be NOTICED out there.
-- The client sends back the corrected position it worked out locally and the
-- server decides whether to accept it.
--
-- The bound is what makes this safe to trust. A hostile client can nudge loot
-- it can already see by up to 30m, once per entry -- which is a worse outcome
-- for them than leaving it where it is, and strictly better than the status
-- quo of items floating in the Pacific.
RegisterNetEvent(BR.Net.LOOT_FIX)
AddEventHandler(BR.Net.LOOT_FIX, function(d)
    local src = source
    if type(d) ~= 'table' then return end

    local id = math.tointeger(d.id)
    local x, y, z = tonumber(d.x), tonumber(d.y), tonumber(d.z)
    if not id or not x or not y or not z then return end

    local e = BR.Roster.get(src)
    if not e or not CAN_SEE[e.state] then return end
    local m = zoneFor(src)
    if not m then return end

    local item = m.loot.items[id]
    if not item or item.repaired then return end

    -- Must be a place this player is actually looking at, and a small move.
    if not m.loot.subs[src] or not m.loot.subs[src][item.cell] then return end
    if BR.Dist(x, y, item.x, item.y) > FIX_RADIUS then return end

    item.repaired = true
    m.loot.fixed = (m.loot.fixed or 0) + 1

    -- Re-index: the correction can cross a cell boundary, and an entry filed
    -- under the wrong cell is invisible to everyone who walks up to it.
    local oldCell = m.loot.cells[item.cell]
    if oldCell then oldCell[item.id] = nil end
    item.x, item.y, item.z = x, y, z
    index(m.loot, item)

    -- Everyone looking at either cell hears about it; the id is unchanged, so
    -- clients holding it move the entry rather than duplicating it.
    announce(m, item)
end)

-- --------------------------------------------------------------------------
-- Housekeeping
-- --------------------------------------------------------------------------

--- Every loot registry there is: the live matches plus the shared pad.
--- @param fn function
local function eachZone(fn)
    BR.Server.eachMatch(function(m)
        if m.loot then fn(m) end
    end)
    if warmupZone then fn(warmupZone) end
end

-- Subscriptions belong to players, and players leave. Left behind they would
-- keep a departed src in every announce() loop for the rest of the match.
BR.Sched.every(5000, 'loot.sweep', function()
    eachZone(function(m)
        for src in pairs(m.loot.subs) do
            local ent = BR.Roster.get(src)
            local stillHere = ent and CAN_SEE[ent.state]
                and (m.warmup and ent.state == BR.PlayerState.WARMUP
                     or (not m.warmup and ent.matchId == m.id))
            if not stillHere then
                m.loot.subs[src] = nil
                m.loot.at[src] = nil
                zoneOf[src] = nil
            end
        end
    end)
end)

-- The warmup pad refills itself. Whoever queued first must not be able to
-- strip the island for everyone who arrives after them.
BR.Sched.every(1000, 'loot.warmupRespawn', function()
    if not warmupZone then return end

    local now  = GetGameTimer()
    local W    = BR.Config.Loot.warmup
    local pad  = BR.Config.Match.warmupPos
    local due  = warmupZone.loot.respawn

    for i = #due, 1, -1 do
        if now >= due[i].at then
            local rng = warmupZone.rng
            local a = rng:float() * math.pi * 2.0
            local r = 25.0 + rng:float() * math.max(1.0, (W.radius or 190.0) - 25.0)
            local crate = BR.MakeCrate(rng, due[i].tier,
                pad.x + math.cos(a) * r, pad.y + math.sin(a) * r, pad.z, nil)
            crate.warmup = true
            BR.Loot.spawnStack(warmupZone, crate, crate.x, crate.y, crate.z)
            table.remove(due, i)
        end
    end
end)
