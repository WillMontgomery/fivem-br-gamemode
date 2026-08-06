-- The inventory: five slots, an ammo pool, and one authority.
--
-- THE SERVER OWNS EVERY SLOT. The client is a mirror with buttons on it: it
-- asks to swap, drop, use or select, and it learns what happened when INV_SET
-- comes back. Nothing here trusts a number the client sent.
--
-- The one exception is AMMO, and it is a deliberate, bounded one. Until M6
-- validates shots server-side, the only observer of a fired round is the
-- client's own engine -- so BR.Net.INV_AMMO carries a report, and this file
-- accepts it ONLY when it LOWERS the stored value. The worst a liar can do is
-- disarm themselves. Every other direction is refused in silence.
--
-- THE SERVER CANNOT WRITE A PED. Same split the storm has lived with since M4:
-- it decides the med kit landed and sends INV_EFFECT; the client applies it to
-- its own ped. The roster's 2Hz health sampling reads the result back, so the
-- server's view self-corrects within half a second either way.
--
-- Empty slots travel as `false`, never nil -- and are stored that way too, so
-- there is one representation rather than a conversion at the boundary. A Lua
-- array with a nil hole in it does not survive serialisation intact, which is
-- the same constraint that made roster deltas carry a named `clear` list.

BR = BR or {}
BR.Inv = BR.Inv or {}

local L     = BR.Config.Loot
local SLOTS = L.slots or 5

-- Slot ZERO is fists: selectable, never fillable. See BR.Config.Loot.meleeSlot.
local MELEE_SLOT = L.meleeSlot or 0

-- Which player states may touch an inventory at all. A rider on the bus has
-- one and can look at it; only a landed player can change it.
local LIVE = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO]  = true,
}

-- --------------------------------------------------------------------------
-- Model
-- --------------------------------------------------------------------------

local function newInv()
    local slots = {}
    for i = 1, SLOTS do slots[i] = false end
    local ammo = {}
    for _, pool in ipairs(BR.Config.AmmoOrder) do ammo[pool] = 0 end
    return { slots = slots, ammo = ammo, active = 1 }
end

--- The inventory for a player, created on first touch.
--- @param src integer
--- @return table|nil
function BR.Inv.of(src)
    local e = BR.Roster.get(src)
    if not e then return nil end
    if not e.inv then e.inv = newInv() end
    return e.inv
end

--- How many of one item a single slot may hold.
--- @param stack table
--- @return integer
local function maxStackOf(stack)
    if stack.kind == BR.ItemKind.CONSUMABLE then
        local c = BR.Config.ConsumableById[stack.item]
        return c and c.maxStack or 1
    end
    if stack.kind == BR.ItemKind.THROWABLE then
        local t = BR.Config.WeaponById[stack.item]
        return t and t.maxStack or 1
    end
    return 1   -- weapons never stack: two rifles are two slots
end

--- The wire view of a player's inventory.
--- @param src integer
--- @return table|nil
function BR.Inv.publicFor(src)
    local inv = BR.Inv.of(src)
    if not inv then return nil end

    local slots = {}
    for i = 1, SLOTS do
        local s = inv.slots[i]
        local w = (s and s.kind == BR.ItemKind.WEAPON)
            and BR.Config.WeaponById[s.item] or nil
        slots[i] = s and {
            id     = s.item,
            label  = BR.LootLabel(s),
            kind   = s.kind,
            rarity = s.rarity,
            count  = s.count,
            clip   = s.clip,
            -- Which pool this weapon's reserve comes out of. Sent rather than
            -- looked up UI-side: br_lib's 39-entry weapon table is Lua only,
            -- and mirroring it into TypeScript by hand is a table that goes
            -- stale the first time someone adds a gun.
            pool   = w and w.ammo or nil,
        } or false
    end

    -- `using` carries only what the progress ring needs; the cancellation
    -- bookkeeping (the health it started at) stays server-side.
    local using = nil
    if inv.using then
        using = { slot = inv.using.slot, endsAt = inv.using.endsAt,
                  ms = inv.using.ms }
    end

    return { slots = slots, ammo = inv.ammo, active = inv.active, using = using }
end

--- Send a player their inventory. Every mutation ends in one of these.
--- @param src integer
function BR.Inv.push(src)
    local payload = BR.Inv.publicFor(src)
    if payload then TriggerClientEvent(BR.Net.INV_SET, src, payload) end
end

--- Wipe an inventory back to empty and tell the owner.
--- @param src integer
function BR.Inv.reset(src)
    local e = BR.Roster.get(src)
    if not e then return end
    e.inv = newInv()
    BR.Inv.push(src)
end

--- Reset every inventory in a match. Called at CLEANUP.
--- @param m table
function BR.Inv.clearFor(m)
    BR.Roster.each(
        function(e) return e.matchId == m.id end,
        function(src) BR.Inv.reset(src) end)
end

-- --------------------------------------------------------------------------
-- Ammo
-- --------------------------------------------------------------------------

--- Add to an ammo pool, clamped to its cap.
--- @param inv table
--- @param pool string
--- @param amount integer
--- @return integer taken
local function addAmmo(inv, pool, amount)
    if not inv.ammo[pool] then return 0 end
    local cap  = BR.Config.AmmoCaps[pool] or 0
    local have = inv.ammo[pool]
    local next_ = math.min(cap, have + amount)
    inv.ammo[pool] = next_
    return next_ - have
end

-- --------------------------------------------------------------------------
-- Giving
-- --------------------------------------------------------------------------

--- Put a stack into a player's inventory.
---
--- Returns what happened, because the caller (a claim, a chest, a death box)
--- has to know whether the item left the world:
---   ok        -- any of it was taken
---   displaced -- a stack pushed out to make room, for the world to catch
---   reason    -- why nothing was taken
---
--- WEAPONS DISPLACE, EVERYTHING ELSE REFUSES. Picking up a rifle with five
--- full slots swaps it for whatever is in hand, which is what the muscle
--- memory of the genre expects. Picking up a bandage does NOT get to throw
--- away your rifle -- that is a misclick costing a gunfight.
---
--- @param src integer
--- @param stack table
--- @return boolean ok
--- @return table|nil displaced
--- @return string|nil reason
function BR.Inv.give(src, stack)
    local inv = BR.Inv.of(src)
    if not inv or not stack then return false, nil, 'noinv' end

    -- Ammo never occupies a slot.
    if stack.kind == BR.ItemKind.AMMO then
        local taken = addAmmo(inv, stack.item, stack.count or 0)
        if taken <= 0 then return false, nil, 'ammofull' end
        BR.Inv.push(src)
        return true, nil, nil
    end

    if stack.kind == BR.ItemKind.CONSUMABLE
       or stack.kind == BR.ItemKind.THROWABLE then
        local left = stack.count or 1
        local max  = maxStackOf(stack)
        local before = left

        -- Top up existing stacks first, lowest slot first, so a player who
        -- picks up their eighth bandage does not open a second stack while
        -- the first has room.
        for i = 1, SLOTS do
            local s = inv.slots[i]
            if left > 0 and s and s.item == stack.item and s.count < max then
                local room = max - s.count
                local move = math.min(room, left)
                s.count = s.count + move
                left = left - move
            end
        end

        while left > 0 do
            local free = nil
            for i = 1, SLOTS do
                if not inv.slots[i] then free = i break end
            end
            if not free then break end
            local move = math.min(max, left)
            inv.slots[free] = {
                item = stack.item, kind = stack.kind,
                rarity = stack.rarity, count = move,
            }
            left = left - move
        end

        -- NOTHING FITS? SWAP, DO NOT REFUSE (user call, 2026-08-05).
        --
        -- This used to answer "No room for that" and leave the item on the
        -- floor. But the player deliberately reached for it -- they want it
        -- more than whatever is in their hand -- so the active slot goes on
        -- the ground and the new thing takes its place. Refusing made the
        -- player drop something manually and pick up again, which is the same
        -- outcome with three extra steps.
        if left >= before then
            -- Fists cannot be swapped out -- slot 0 holds nothing to displace
            -- and must stay empty -- so a full-inventory swap made with an
            -- empty hand lands in slot 1.
            local at = math.max(inv.active, 1)
            local displaced = inv.slots[at] or nil
            inv.slots[at] = {
                item = stack.item, kind = stack.kind,
                rarity = stack.rarity, count = math.min(max, left),
            }
            BR.Inv.push(src)
            return true, displaced, nil
        end

        BR.Inv.push(src)
        -- Partially taken: hand the remainder back so it stays in the world.
        if left > 0 then
            local rest = {}
            for k, v in pairs(stack) do rest[k] = v end
            rest.count = left
            return true, rest, nil
        end
        return true, nil, nil
    end

    -- Weapons.
    local free = nil
    for i = 1, SLOTS do
        if not inv.slots[i] then free = i break end
    end

    local w = BR.Config.WeaponById[stack.item]
    local placed = {
        item = stack.item, kind = stack.kind, rarity = stack.rarity,
        count = 1, clip = stack.clip or (w and w.clip) or 0,
    }

    local displaced = nil
    local at
    if free then
        at = free
    else
        at = math.max(inv.active, 1)   -- never slot 0: fists hold nothing
        displaced = inv.slots[at] or nil
    end
    inv.slots[at] = placed

    -- A weapon picked up into an EMPTY hand comes up in it. Picking your
    -- first gun off the floor and then having to press a number key to hold
    -- it is the kind of friction that gets you killed in the first minute.
    --
    -- FISTS ARE A DELIBERATE CHOICE, though: someone who selected slot 0 put
    -- their gun away on purpose, and yanking a rifle back into their hands
    -- because they walked over one undoes that.
    if inv.active ~= MELEE_SLOT
       and (displaced or not inv.slots[inv.active] or inv.active == at) then
        inv.active = at
    end

    -- A found gun has to be usable. One clip's worth of reserve, capped by
    -- the pool -- enough to fight with, not enough to stop looting ammo.
    if w and w.ammo then
        addAmmo(inv, w.ammo, (w.clip or 0) * (L.weaponReserveClips or 1))
    end

    BR.Inv.push(src)
    return true, displaced, nil
end

--- Take a whole slot out. Used by drops and by death.
--- @param src integer
--- @param slot integer
--- @return table|nil stack
function BR.Inv.take(src, slot)
    local inv = BR.Inv.of(src)
    if not inv or not slot or slot < 1 or slot > SLOTS then return nil end
    local s = inv.slots[slot]
    if not s then return nil end
    inv.slots[slot] = false
    return s
end

--- Everything a player was carrying, emptied out. The death box's contents.
--- @param src integer
--- @return table[] stacks
function BR.Inv.dropAll(src)
    local inv = BR.Inv.of(src)
    if not inv then return {} end

    local out = {}
    for i = 1, SLOTS do
        local s = inv.slots[i]
        if s then
            out[#out + 1] = s
            inv.slots[i] = false
        end
    end

    -- Ammo drops too, one stack per non-empty pool, in the fixed order (never
    -- pairs() -- two servers must build the same box from the same corpse).
    for _, pool in ipairs(BR.Config.AmmoOrder) do
        local n = inv.ammo[pool] or 0
        if n > 0 then
            out[#out + 1] = {
                item = pool, kind = BR.ItemKind.AMMO,
                rarity = BR.Rarity.COMMON, count = n,
            }
            inv.ammo[pool] = 0
        end
    end

    inv.using = nil
    return out
end

--- Grant the configured starting kit. Empty by design -- landing unarmed is
--- what makes the first thirty seconds tense -- but the config is real, so
--- the path that honours it has to be too.
--- @param src integer
function BR.Inv.grantStarting(src)
    for _, item in ipairs(L.startingItems or {}) do
        BR.Inv.give(src, {
            item   = item.id,
            kind   = item.kind,
            rarity = item.rarity or BR.Rarity.COMMON,
            count  = item.count or 1,
        })
    end
end

-- --------------------------------------------------------------------------
-- Client requests
-- --------------------------------------------------------------------------

--- Everything below shares one gate: you must be a live player in a running
--- match to change your own inventory.
--- @param src integer
--- @return table|nil inv
local function liveInv(src)
    local e = BR.Roster.get(src)
    if not e or not LIVE[e.state] then return nil end
    local m = BR.Server.matchOf(src)
    if not m then return nil end
    return BR.Inv.of(src)
end

RegisterNetEvent(BR.Net.INV_SELECT)
AddEventHandler(BR.Net.INV_SELECT, function(d)
    local src = source
    local inv = liveInv(src)
    if not inv or type(d) ~= 'table' then return end

    local slot = math.tointeger(d.slot)
    -- MELEE_SLOT (0) is selectable and holds nothing -- fists. Everything
    -- downstream already handles an empty slot, so this needs no special case
    -- beyond letting the index through.
    if not slot or slot < MELEE_SLOT or slot > SLOTS then return end
    if inv.active == slot then return end

    inv.active = slot
    -- Switching weapons interrupts a consumable: both are "what my hands are
    -- doing", and letting a med kit finish while a rifle comes up would be a
    -- free heal mid-fight.
    inv.using = nil
    BR.Inv.push(src)
end)

RegisterNetEvent(BR.Net.INV_SWAP)
AddEventHandler(BR.Net.INV_SWAP, function(d)
    local src = source
    local inv = liveInv(src)
    if not inv or type(d) ~= 'table' then return end

    local from = math.tointeger(d.from)
    local to   = math.tointeger(d.to)
    if not from or not to or from == to then return end
    if from < 1 or from > SLOTS or to < 1 or to > SLOTS then return end

    inv.slots[from], inv.slots[to] = inv.slots[to], inv.slots[from]
    -- The ACTIVE SLOT INDEX does not move. The player selected a position on
    -- the bar, not a particular gun; dragging something into slot 3 while
    -- slot 1 is up must not change what is in their hands.
    BR.Inv.push(src)
end)

RegisterNetEvent(BR.Net.INV_DROP)
AddEventHandler(BR.Net.INV_DROP, function(d)
    local src = source
    local inv = liveInv(src)
    if not inv or type(d) ~= 'table' then return end

    local slot = math.tointeger(d.slot)
    if not slot then return end

    local stack = BR.Inv.take(src, slot)
    if not stack then return end

    if inv.using and inv.using.slot == slot then inv.using = nil end
    BR.Loot.dropForPlayer(src, stack)
    BR.Inv.push(src)
end)

RegisterNetEvent(BR.Net.INV_USE)
AddEventHandler(BR.Net.INV_USE, function(d)
    local src = source
    local inv = liveInv(src)
    if not inv or type(d) ~= 'table' then return end

    local slot = math.tointeger(d.slot)
    if not slot or slot < 1 or slot > SLOTS then return end

    local s = inv.slots[slot]
    if not s or s.kind ~= BR.ItemKind.CONSUMABLE then return end
    if inv.using then return end   -- one at a time

    local c = BR.Config.ConsumableById[s.item]
    if not c then return end

    local e = BR.Roster.get(src)

    -- REFUSE A USE THAT WOULD DO NOTHING, out loud. Drinking a shield potion
    -- at full shield and watching five seconds pass for no effect is worse
    -- than being told no.
    if c.armour and (e.armour or 0) >= (c.armourCap or 0) then
        BR.Server.notify(src,
            (c.armourCap >= BR.Config.Match.maxArmour)
                and 'Your shield is already full.'
                or ('%s only takes your shield to %d.')
                    :format(c.label, math.floor(c.armourCap)),
            'warn')
        return
    end
    if c.health and (e.hp or 0) >= (c.healthCap or 0) then
        BR.Server.notify(src,
            (c.healthCap >= 100)
                and 'Your health is already full.'
                or ('%s only takes your health to %d.')
                    :format(c.label, math.floor(c.healthCap)),
            'warn')
        return
    end

    inv.using = {
        slot   = slot,
        item   = s.item,
        ms     = c.useMs,
        endsAt = GetGameTimer() + c.useMs,
        hp0    = e.hp or 0,      -- the damage-cancel baseline
    }
    BR.Inv.push(src)
end)

-- The ammo report. Decrease-only, see the header.
RegisterNetEvent(BR.Net.INV_AMMO)
AddEventHandler(BR.Net.INV_AMMO, function(d)
    local src = source
    local inv = BR.Inv.of(src)
    if not inv or type(d) ~= 'table' then return end

    local changed = false

    if type(d.pool) == 'table' then
        for _, name in ipairs(BR.Config.AmmoOrder) do
            local reported = tonumber(d.pool[name])
            local have = inv.ammo[name] or 0
            -- Strictly lower, and never negative. An "increase" is either a
            -- cheat or a stale report that crossed a pickup in flight;
            -- neither is worth acting on.
            if reported and reported >= 0 and reported < have then
                inv.ammo[name] = math.floor(reported)
                changed = true
            end
        end
    end

    local slot = math.tointeger(d.slot)
    local clip = tonumber(d.clip)
    if slot and clip and slot >= 1 and slot <= SLOTS then
        local s = inv.slots[slot]
        if s and s.clip and clip >= 0 and clip < s.clip then
            s.clip = math.floor(clip)
            changed = true
        end
    end

    -- Deliberately NOT pushed back. The client already knows -- it is where
    -- the number came from -- and echoing it would put a 2Hz packet per
    -- player on the wire to tell them what they just said.
    local _ = changed
end)

-- --------------------------------------------------------------------------
-- Consumable timing
-- --------------------------------------------------------------------------

--- Cancel an in-progress use, audibly.
--- @param src integer
--- @param why string
function BR.Inv.cancelUse(src, why)
    local inv = BR.Inv.of(src)
    if not inv or not inv.using then return end
    inv.using = nil
    BR.Inv.push(src)
    if why then BR.Server.notify(src, why, 'warn') end
end

-- 250ms: fine enough that a cancelled use stops looking like it worked, and
-- coarse enough to be free. The COMPLETION is what consumes the item -- an
-- interrupted use costs nothing, which is why cancelling needs no refund
-- path at all.
BR.Sched.every(250, 'inv.use', function()
    local now = GetGameTimer()

    BR.Roster.each(
        function(e) return e.inv ~= nil and e.inv.using ~= nil end,
        function(src, e)
            local inv = e.inv
            local u   = inv.using

            local m = BR.Server.matchOf(src)
            if not m or not LIVE[e.state] then
                inv.using = nil
                BR.Inv.push(src)
                return
            end

            -- The slot must still hold the thing that was started.
            local s = inv.slots[u.slot]
            if not s or s.item ~= u.item then
                inv.using = nil
                BR.Inv.push(src)
                return
            end

            if L.useCancelOnDamage and (e.hp or 0) < (u.hp0 or 0) then
                BR.Inv.cancelUse(src, 'Interrupted.')
                return
            end

            if now < u.endsAt then return end

            -- Landed. Consume one, then tell the client to apply it.
            s.count = s.count - 1
            if s.count <= 0 then inv.slots[u.slot] = false end
            inv.using = nil

            local c = BR.Config.ConsumableById[u.item]
            if c then
                local payload = { item = u.item }
                if c.armour then
                    payload.armour    = math.min(c.armourCap,
                        (e.armour or 0) + c.armour)
                    payload.armourCap = c.armourCap
                end
                if c.health then
                    payload.health    = math.min(c.healthCap,
                        (e.hp or 0) + c.health)
                    payload.healthCap = c.healthCap
                end
                TriggerClientEvent(BR.Net.INV_EFFECT, src, payload)
            end

            BR.Inv.push(src)
        end)
end)
