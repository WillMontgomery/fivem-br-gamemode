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
-- one and can look at it; only a player with their feet on the ground can
-- change it.
--
-- WARMUP COUNTS, and leaving it out was a real bug: there is loot on the
-- warmup island and the whole point of it is early PVP, so a player could
-- pick a rifle up and then not be able to SELECT it -- every INV_SELECT,
-- INV_SWAP, INV_DROP and INV_USE was refused in silence (user, 2026-08-06:
-- "it's impossible to select a weapon while in warmup"). The CLIENT had
-- always allowed it -- canArm() lists WARMUP -- so the two ends disagreed and
-- the visible symptom was a keypress that did nothing at all.
local LIVE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.DBNO]   = true,
    [BR.PlayerState.WARMUP] = true,
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

        -- A CARRY CEILING ACROSS EVERY SLOT, not just per stack. Without it,
        -- capping the stack at three simply produced two stacks of three
        -- (user call, 2026-08-06: "no higher quantities of either item should
        -- be allowed").
        local c = BR.Config.ConsumableById[stack.item]
        if c and c.carryMax then
            local held = 0
            for i = 1, SLOTS do
                local s = inv.slots[i]
                if s and s.item == stack.item then held = held + (s.count or 0) end
            end
            local room = math.max(0, c.carryMax - held)
            if room <= 0 then
                return false, nil, 'carrymax'
            end
            left = math.min(left, room)
        end

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
        -- Baselines: hp0 doubles as the damage-cancel reference, and both are
        -- what the per-tick partial effects interpolate FROM.
        hp0     = e.hp or 0,
        armour0 = e.armour or 0,
    }
    BR.Inv.push(src)
end)

-- The ammo report. Decrease-only, see the header.
-- THE CLIP IS REPORTED; THE RESERVE IS DEDUCED.
--
-- The client sends one number it can read honestly -- rounds in the magazine
-- -- and the direction it moved says what happened:
--
--     clip DOWN  -> rounds were fired. The reserve is untouched.
--     clip UP    -> a reload. The reserve paid for the difference.
--
-- That is the whole model, and it deliberately assumes nothing about any
-- other ammo native. The previous version had the client compute the reserve
-- as `GetAmmoInPedWeapon - clip`; on this build that number does not move
-- when firing, so a shrinking clip made the reserve GROW, and the growth then
-- fed back into the ped as free ammo (user, 2026-08-06).
--
-- It is still only as honest as the client, and that is fine for now: the
-- worst a liar achieves is never reloading, which M6's shot validation takes
-- away along with everything else in this category.
RegisterNetEvent(BR.Net.INV_AMMO)
AddEventHandler(BR.Net.INV_AMMO, function(d)
    local src = source
    local inv = BR.Inv.of(src)
    if not inv or type(d) ~= 'table' then return end

    local slot  = math.tointeger(d.slot)
    local total = math.tointeger(d.total)
    local clip  = math.tointeger(d.clip)
    if not slot or not total or not clip then return end
    if total < 0 or clip < 0 then return end
    if slot < 1 or slot > SLOTS then return end

    local s = inv.slots[slot]
    if not s or s.kind ~= BR.ItemKind.WEAPON then return end

    local w = BR.Config.WeaponById[s.item]
    if not w then return end

    -- ONE NUMBER IS AUTHORITATIVE AND IT IS THE TOTAL.
    --
    -- The client reports what the engine says the ped holds for this weapon,
    -- magazine included. That number is decrease-only here, which is the only
    -- rule this handler needs:
    --
    --   FIRING  lowers the total. The rounds are gone.
    --   RELOAD  does not change it at all -- it moves rounds from the reserve
    --           into the magazine, and the split is what `clip` describes.
    --   PICKUP  raises it, and the server did that itself, so a client
    --           reporting a rise is either stale or lying. Refused either way.
    --
    -- The old version inferred all of this from the magazine count alone,
    -- treating "clip went up" as a reload to be paid for. That works right up
    -- until the magazine stops moving -- which is exactly what the engine did
    -- (user, 2026-08-06) -- and then nothing is measurable at all. This is the
    -- guard ox_inventory uses for the same reason.
    local pool     = w.ammo and (inv.ammo[w.ammo] or 0) or 0
    local wasClip  = s.clip or 0
    local wasTotal = wasClip + pool

    total = math.min(total, wasTotal)

    -- The magazine holds no more than a magazine, and no more than the player
    -- has left in total.
    clip = math.min(clip, w.clip or total, total)

    if total == wasTotal and clip == wasClip then return end

    -- The reserve is not reported and never has been: it is what is left over
    -- once the magazine is taken out of the total. An empty pool therefore
    -- cannot conjure a magazine -- there is nothing for the arithmetic to take
    -- it from.
    s.clip = clip
    if w.ammo then inv.ammo[w.ammo] = total - clip end

    -- PUSHED BACK, unlike the old version: the reserve here is now something
    -- the server WORKED OUT rather than something the client told it, so the
    -- client has no other way to learn it.
    BR.Inv.push(src)
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

            -- THE BAR FILLS AS YOU DRINK (user call, 2026-08-05). Applying the
            -- whole amount at the end made an 8-second med kit look like
            -- nothing happening followed by a jump; feeding the interpolated
            -- TARGET every tick makes the bar climb with the animation.
            --
            -- Targets, not deltas: the client only ever applies these upward,
            -- so a dropped tick self-corrects on the next one instead of
            -- losing that increment for good.
            local c = BR.Config.ConsumableById[u.item]
            if c and now < u.endsAt then
                local total = math.max(1, u.ms or 1)
                local pct = BR.Clamp((total - (u.endsAt - now)) / total, 0.0, 1.0)
                local partial = { item = u.item, partial = true }
                if c.armour then
                    partial.armour = math.min(c.armourCap,
                        (u.armour0 or 0) + c.armour * pct)
                    partial.armourCap = c.armourCap
                end
                if c.health then
                    partial.health = math.min(c.healthCap,
                        (u.hp0 or 0) + c.health * pct)
                    partial.healthCap = c.healthCap
                end
                TriggerClientEvent(BR.Net.INV_EFFECT, src, partial)
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
