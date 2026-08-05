-- Loot layout generation and the streaming grid.
--
-- Pure: no FiveM natives, no globals beyond BR. That is deliberate and it is the
-- same bet storm_solve.lua makes -- it means tools/test_shared.lua can prove
-- determinism, budgets and placement outside the game, which is the cheapest
-- feedback loop on this project by a wide margin.
--
-- DETERMINISM IS THE WHOLE CONTRACT. Given a seed this must produce a
-- byte-identical layout every time, on any machine, in any Lua build. That rules
-- out one thing absolutely: iterating a hash-keyed table. `pairs()` order is
-- undefined, so every walk here goes over an ARRAY -- BR.Config.AmmoOrder,
-- BR.Config.WeaponsByRarity[r], BR.Config.Map.POIs -- never over the string-keyed
-- lookup that happens to hold the same data. BR.Config.RollRarity sorts for the
-- same reason and says so.
--
-- Only the SERVER runs this. The client is streamed the entries near it, cell by
-- cell: a client that could derive the layout from a seed would know where every
-- item on the map is, which is a wallhack we would be shipping ourselves.

BR = BR or {}

local floor = math.floor
local sqrt  = math.sqrt

-- --------------------------------------------------------------------------
-- The streaming grid
-- --------------------------------------------------------------------------

--- Which cell a world position falls in.
--- @param x number
--- @param y number
--- @return integer cx
--- @return integer cy
function BR.LootCellOf(x, y)
    local size = BR.Config.Loot.cellSize
    return floor(x / size), floor(y / size)
end

--- The table key for a cell. Cells are held in a string-keyed map rather than a
--- 2D array because the map's AABB is not the only place loot can be -- a death
--- box lands wherever the player did.
--- @param cx integer
--- @param cy integer
--- @return string
function BR.LootCellKey(cx, cy)
    return cx .. ':' .. cy
end

--- Convenience: the cell key for a world position.
--- @param x number
--- @param y number
--- @return string
function BR.LootCellKeyAt(x, y)
    local cx, cy = BR.LootCellOf(x, y)
    return BR.LootCellKey(cx, cy)
end

--- Every cell key in the (2r+1)^2 block centred on a cell, in a FIXED order.
--- The order matters: subscription diffs are compared between calls.
--- @param cx integer
--- @param cy integer
--- @param radius integer|nil  defaults to BR.Config.Loot.subscribeRadius
--- @return string[]
function BR.LootCellsAround(cx, cy, radius)
    local r = radius or BR.Config.Loot.subscribeRadius
    local out = {}
    for dy = -r, r do
        for dx = -r, r do
            out[#out + 1] = BR.LootCellKey(cx + dx, cy + dy)
        end
    end
    return out
end

-- --------------------------------------------------------------------------
-- Rolling a stack
-- --------------------------------------------------------------------------

--- A stack is what an inventory slot holds and what a ground entry carries:
---   { item = <id string>, kind, rarity, count, clip? }
--- `item` is the id, never the numeric ground-entry id -- those are different
--- namespaces and conflating them was easy to do and hard to see.

--- Roll one ground-loot stack for a POI tier.
--- @param rng table   a BR.Rng instance
--- @param tier integer
--- @return table stack
function BR.RollLootStack(rng, tier)
    local kind   = BR.Config.RollKind(rng)
    local rarity = BR.Config.RollRarity(rng, tier)

    if kind == BR.ItemKind.AMMO then
        -- Ammo has no rarity of its own; the roll is spent picking a pool. Fixed
        -- order, never pairs() over AmmoPickups.
        local pool = rng:pick(BR.Config.AmmoOrder)
        local def  = BR.Config.AmmoPickups[pool]
        return {
            item   = pool,
            kind   = BR.ItemKind.AMMO,
            rarity = BR.Rarity.COMMON,
            count  = def.amount,
        }
    end

    if kind == BR.ItemKind.CONSUMABLE then
        local c = BR.LootPickOfRarity(rng, BR.Config.ConsumablesByRarity, rarity)
        return {
            item   = c.id,
            kind   = BR.ItemKind.CONSUMABLE,
            rarity = c.rarity,
            count  = 1,
        }
    end

    if kind == BR.ItemKind.THROWABLE then
        local t = BR.LootPickOfRarity(rng, BR.Config.ThrowablesByRarity, rarity)
        return {
            item   = t.id,
            kind   = BR.ItemKind.THROWABLE,
            rarity = t.rarity,
            -- Throwables spawn as a pair when the stack allows it: one grenade is
            -- a coin flip, two is a decision.
            count  = math.min(t.maxStack or 1, rng:int(1, 2)),
        }
    end

    local w = BR.LootPickOfRarity(rng, BR.Config.WeaponsByRarity, rarity)
    return {
        item   = w.id,
        kind   = BR.ItemKind.WEAPON,
        rarity = w.rarity,
        count  = 1,
        clip   = w.clip,
    }
end

--- Pick from a rarity-bucketed table, walking DOWN to a populated tier.
---
--- Not every rarity has an entry of every kind -- there is no legendary
--- consumable and no common sniper -- and an empty bucket must not produce a nil
--- item. Walking down rather than up keeps the miss cheap: a legendary roll that
--- finds no legendary consumable pays out an epic one, it does not silently
--- upgrade a common roll.
--- @param rng table
--- @param buckets table   [rarity] = array
--- @param rarity integer
--- @return table
function BR.LootPickOfRarity(rng, buckets, rarity)
    for r = rarity, BR.Rarity.COMMON, -1 do
        local b = buckets[r]
        if b and #b > 0 then return rng:pick(b) end
    end
    -- Nothing at or below: walk up instead. Only reachable if a whole kind is
    -- authored above the rolled rarity.
    for r = rarity + 1, BR.Rarity.LEGENDARY do
        local b = buckets[r]
        if b and #b > 0 then return rng:pick(b) end
    end
    return nil
end

--- The contents of a chest. Chests roll one tier hotter than the ground around
--- them -- that is what makes crossing open ground for one worth the exposure.
--- @param rng table
--- @param tier integer
--- @return table[] stacks
function BR.LootChestContents(rng, tier)
    local cfg = BR.Config.Loot.chestItems
    local n   = rng:int(cfg.min, cfg.max)
    local hot = math.min(tier + 1, 3)

    local out = {}
    for _ = 1, n do
        out[#out + 1] = BR.RollLootStack(rng, hot)
    end
    return out
end

--- The rarity a container displays: the best thing inside it. A chest full of
--- common ammo and one legendary rifle should glow gold.
--- @param contents table[]
--- @return integer
function BR.LootContentsRarity(contents)
    local best = BR.Rarity.COMMON
    for _, s in ipairs(contents or {}) do
        if (s.rarity or 1) > best then best = s.rarity end
    end
    return best
end

--- Human-readable label for a stack, for the pickup prompt and the inventory.
--- @param stack table
--- @return string
function BR.LootLabel(stack)
    if not stack then return '' end
    if stack.kind == BR.ItemKind.AMMO then
        local def = BR.Config.AmmoPickups[stack.item]
        return def and def.label or 'Ammo'
    end
    if stack.kind == BR.ItemKind.CONSUMABLE then
        local c = BR.Config.ConsumableById[stack.item]
        return c and c.label or 'Item'
    end
    local w = BR.Config.WeaponById[stack.item]
    return w and w.label or 'Weapon'
end

-- --------------------------------------------------------------------------
-- Road corridors, for the sparse filler
-- --------------------------------------------------------------------------

--- Cumulative segment lengths for a road, cached on the road table itself.
--- Sampling by length rather than by segment index matters: a road authored with
--- one 3km leg and five 200m legs would otherwise put a sixth of its loot on the
--- long one.
--- @param road table
--- @return table  { total, cum = { ... } }
local function roadMetrics(road)
    if road._metrics then return road._metrics end

    local cum, total = { 0.0 }, 0.0
    for i = 2, #road.points do
        local a, b = road.points[i - 1], road.points[i]
        total = total + BR.Dist(a.x, a.y, b.x, b.y)
        cum[i] = total
    end

    road._metrics = { total = total, cum = cum }
    return road._metrics
end

--- A point at distance `d` along a road, with its direction.
--- @param road table
--- @param d number
--- @return number x
--- @return number y
--- @return number dx  unit direction
--- @return number dy
local function roadPointAt(road, d)
    local m = roadMetrics(road)
    local pts = road.points

    for i = 2, #pts do
        if d <= m.cum[i] or i == #pts then
            local a, b = pts[i - 1], pts[i]
            local segLen = m.cum[i] - m.cum[i - 1]
            local t = segLen > 0 and ((d - m.cum[i - 1]) / segLen) or 0.0
            t = BR.Clamp(t, 0.0, 1.0)
            local dx, dy = b.x - a.x, b.y - a.y
            local len = sqrt(dx * dx + dy * dy)
            if len <= 0 then len = 1.0 end
            return BR.Lerp(a.x, b.x, t), BR.Lerp(a.y, b.y, t), dx / len, dy / len
        end
    end

    local p = pts[1]
    return p.x, p.y, 1.0, 0.0
end

--- Distance from a point to the nearest POI centre.
--- @param x number
--- @param y number
--- @return number
local function distToNearestPoi(x, y)
    local best = math.huge
    for _, poi in ipairs(BR.Config.Map.POIs) do
        local d2 = BR.Dist2(x, y, poi.x, poi.y)
        if d2 < best then best = d2 end
    end
    return sqrt(best)
end

-- --------------------------------------------------------------------------
-- The layout
-- --------------------------------------------------------------------------

--- Build a whole match's loot layout.
---
--- Entries are stacks with a position:
---   { id, item, kind, rarity, count, clip?, x, y, z, prop?, contents? }
---
--- `z` is the POI's nominal height, NOT the ground. The server has no ground
--- probe -- GetGroundZFor_3dCoord is client-side -- so every client resolves the
--- real height itself when it materialises the prop, exactly as markers.lua
--- already does for its beams. That also means a POI z that is 20m out costs
--- nothing but a first frame at the wrong height.
---
--- @param seed integer
--- @return table[] entries
--- @return table stats  { poi, chest, filler, total }
function BR.BuildLootLayout(seed)
    local L   = BR.Config.Loot
    local rng = BR.Rng(seed)

    local out    = {}
    local nextId = 0
    local stats  = { poi = 0, chest = 0, filler = 0, total = 0 }

    local function add(e)
        nextId = nextId + 1
        e.id = nextId
        out[#out + 1] = e
        stats.total = stats.total + 1
        return e
    end

    -- POIs, in authored order. Ground loot first, then chests, so that adding a
    -- POI at the end of the table does not shift every existing item's id.
    for _, poi in ipairs(BR.Config.Map.POIs) do
        local budget = L.budgetPerTier[poi.tier] or 0
        for _ = 1, budget do
            -- 0.92 keeps items off the exact rim, where a first-pass radius is
            -- most likely to have overshot into water or a cliff face.
            local x, y = rng:pointInDisc(poi.x, poi.y, poi.radius * 0.92)
            local s = BR.RollLootStack(rng, poi.tier)
            s.x, s.y, s.z = x, y, poi.z
            s.poi = poi.id
            add(s)
            stats.poi = stats.poi + 1
        end

        local chests = L.chestsPerTier[poi.tier] or 0
        for _ = 1, chests do
            local x, y = rng:pointInDisc(poi.x, poi.y, poi.radius * 0.75)
            local contents = BR.LootChestContents(rng, poi.tier)
            add({
                item     = 'chest',
                kind     = 'chest',
                rarity   = BR.LootContentsRarity(contents),
                count    = 1,
                x = x, y = y, z = poi.z,
                poi      = poi.id,
                prop     = rng:pick(L.chestProps),
                contents = contents,
            })
            stats.chest = stats.chest + 1
        end
    end

    -- Sparse filler along the road corridors. Rejection-sampled away from the
    -- POIs: filler exists to make the walk between them survivable, not to
    -- thicken the ground that is already worth fighting over.
    local roads = BR.Config.Map.Roads or {}
    local f = L.filler
    if f and f.count and f.count > 0 and #roads > 0 then
        for _ = 1, f.count do
            local placed = false
            -- Bounded retries keep this deterministic: the same seed always burns
            -- the same number of rng draws whether or not a point is rejected.
            for _ = 1, 6 do
                local road = rng:pick(roads)
                local m    = roadMetrics(road)
                local d    = rng:float() * m.total
                local px, py, dx, dy = roadPointAt(road, d)
                -- Perpendicular offset, either side.
                local off = (rng:float() * 2.0 - 1.0) * f.lateralOffset
                local x, y = px - dy * off, py + dx * off

                if distToNearestPoi(x, y) >= (f.minPoiDist or 0) then
                    local s = BR.RollLootStack(rng, f.tier or 1)
                    s.x, s.y, s.z = x, y, 0.0
                    s.road = road.id
                    add(s)
                    stats.filler = stats.filler + 1
                    placed = true
                    break
                end
            end
            -- Six rejections in a row means this road runs through a POI; drop
            -- the item rather than forcing it somewhere it does not belong.
            local _ = placed
        end
    end

    return out, stats
end
