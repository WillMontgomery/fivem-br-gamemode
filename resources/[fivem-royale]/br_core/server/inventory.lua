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

-- ═══ THE ONE SENTENCE THE REPAIR KIT IS ALLOWED TO SAY (#228) ═══
--
--   "the copy should be revised to 'You can only use this item while driving.'
--    - if they switch seats before it is finished it should still apply, and
--    same if they leave the vehicle mid-use."   -- owner, 2026-09-04
--
-- A CONSTANT BECAUSE THERE ARE NOW TWO SPEAKERS. It started as one literal in
-- the press-time refusal; the owner has since asked for the same sentence on
-- the mid-channel cancels, and two copies of a string a player reads is how
-- one of them drifts. (config/shop.lua keeps its equivalent, `onFootToast`, in
-- config -- but that one is spoken by the CATALOGUE module, which has to hand
-- the string back across a module boundary. This one has one file and two call
-- sites twelve hundred lines apart, so one local is the whole of what it
-- needs.)
--
-- IT REPLACED "You cannot use this item while on foot", which was the same
-- refusal described from the wrong end: it was only ever true of the on-foot
-- case, and the owner's new wording is true of every case that is allowed to
-- say it. tools/test_roster.lua asserts it verbatim, full stop included.
local USE_WHILE_DRIVING = 'You can only use this item while driving.'

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
--
-- DBNO DOES NOT COUNT, and it used to. A downed player keeps their inventory
-- -- it is what the death box is built from, and a revive has to hand it back
-- intact -- but they cannot reach into it: no swapping, no dropping, and above
-- all no bandaging themselves back up off the floor, which would make the
-- bleed timer a suggestion. The client's canArm() lists the same states for
-- the same reason; the two have to agree or a keypress does nothing in silence
-- (that exact disagreement is what the WARMUP note above is about).
local LIVE = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,
}

-- --------------------------------------------------------------------------
-- Model
-- --------------------------------------------------------------------------

--- A FRESH INVENTORY STARTS ON FISTS, NOT ON SLOT 1 (#155).
---
--- Owner, 2026-08-16: "The default inventory slot should be fists, not slot 1."
--- A player who lands holding something they never drew has had their first
--- action taken for them, and on a battle-royale drop the first action is
--- looking around rather than aiming.
---
--- THIS IS THE ONLY PLACE THAT DECIDES IT, and that is the point. `newInv` is
--- reached by every path that starts or restarts an inventory -- first touch in
--- BR.Inv.of (spawn and join), BR.Inv.reset (a party leave, a respawn), and
--- BR.Inv.clearFor (match reset at CLEANUP and at match end) -- so there is one
--- default rather than five that have to agree. Fixing one and leaving the
--- others is how the last few of these have gone.
---
--- `choseActive` IS NOT BOOKKEEPING, IT IS THE HALF THAT KEEPS THE PICKUP
--- WORKING. See the note in BR.Inv.give: "a weapon into an empty hand comes up
--- in it" and "fists are a deliberate choice" used to be the same test, because
--- the only way to be on slot 0 was to put yourself there. Now that fists are
--- where everybody STARTS, those two facts have come apart and the flag is what
--- tells them apart -- false means nobody has chosen anything yet, so the first
--- gun off the floor still comes up in the hand.
local function newInv()
    local slots = {}
    for i = 1, SLOTS do slots[i] = false end
    local ammo = {}
    for _, pool in ipairs(BR.Config.AmmoOrder) do ammo[pool] = 0 end
    return { slots = slots, ammo = ammo, active = MELEE_SLOT, choseActive = false }
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

--- How many of one item the WHOLE inventory may hold, across every slot.
---
--- Distinct from maxStackOf, which is per slot. Without this a player could
--- fill three slots with three grenades each and carry nine -- the per-slot
--- cap says nothing about how many slots you may open (user call,
--- 2026-08-08: throwables are three per item, full stop).
---
--- Throwables reuse their own maxStack as the carry cap, so the two numbers
--- cannot drift apart: one slot of three, and the fourth grenade stays on the
--- floor.
---
--- PUBLIC, BECAUSE THE REFUSAL HAS TO NAME THIS NUMBER (#171) AND IT IS NOT
--- ONE FIELD. A consumable's cap is `carryMax`; a throwable's is its own
--- `maxStack`, in a different config table. server/loot.lua wrote the message
--- by reading `BR.Config.ConsumableById[...].carryMax` directly, so a player
--- holding three grenades -- which are THROWABLE, and therefore not in that
--- table at all -- was told they could carry ZERO of them. There is one answer
--- to "how many of these may I hold", and it is this function.
--- @param stack table
--- @return integer|nil  nil means uncapped
function BR.Inv.carryMax(stack)
    if not stack then return nil end
    if stack.kind == BR.ItemKind.CONSUMABLE then
        local c = BR.Config.ConsumableById[stack.item]
        return c and c.carryMax or nil
    end
    if stack.kind == BR.ItemKind.THROWABLE then
        local t = BR.Config.WeaponById[stack.item]
        return t and t.maxStack or nil
    end
    return nil
end

local carryMaxOf = BR.Inv.carryMax

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

    -- `using` carries only what the progress bar needs -- three scalars, and
    -- deliberately no item id: the cancellation bookkeeping (the health it
    -- started at, the car it was aimed at, what has already been granted for
    -- it) stays server-side. THE BAR IS A SIBLING OF THE PLATE, not a child of
    -- it (ui-src InventoryBar.tsx: `{slot && ...}` and `{using && ...}` are two
    -- blocks), so the fill draws OVER a slot that still holds its icon, its
    -- label, its rarity band and its count for the whole of the channel -- which
    -- is what every consumable looks like while it is being used, the repair kit
    -- included. A build that emptied the slot at the keypress drew the bar over
    -- a blank plate, and the owner's word for that was "not that".
    local using = nil
    if inv.using then
        using = { slot = inv.using.slot, endsAt = inv.using.endsAt,
                  ms = inv.using.ms }
    end

    return { slots = slots, ammo = inv.ammo, active = inv.active, using = using }
end

--- Send a player their inventory. Every mutation ends in one of these.
---
--- ═══ `opts.quiet` SUPPRESSES THE PICKUP CUE, AND ONLY THE CUE ═══
---
--- client/inventory.lua plays GTA's PICK_UP whenever an INV_SET shows the
--- inventory GAINED something. That is right for every ordinary arrival -- the
--- sound is the feedback that separates a pickup from a pickup that was refused
--- -- and it is wrong for a grant the player did not just perform.
---
--- The warmup shop is the case that found it (owner, 2026-08-29: "when
--- transitioning to state BUS, the pickup sound is heard again by anyone who has
--- purchased an item"). The car token is handed out at wheels-up, minutes after
--- the purchase, and everyone who bought one heard a pickup sound for something
--- they could not see arriving.
---
--- A FLAG ON THE PUSH RATHER THAN A GUESS ON THE CLIENT. The client cannot tell
--- a delivery from a pickup by looking at the payload -- both are simply "a slot
--- gained an item" -- and any rule it invented (was I entering BUS? is the item
--- a car?) would be a second, drifting answer to a question the server already
--- knows. The server is the only thing that knows WHY the inventory changed, so
--- it is what says whether it made a noise.
---
--- IT DOES NOT SUPPRESS ANYTHING ELSE. The slots still arrive, the panel still
--- updates, the toast the shop already sends still speaks. Silence here means
--- silence, not invisibility.
--- @param src integer
--- @param opts table|nil  { quiet = true } to deliver without the pickup cue
function BR.Inv.push(src, opts)
    local payload = BR.Inv.publicFor(src)
    if not payload then return end
    if type(opts) == 'table' and opts.quiet == true then payload.quiet = true end
    TriggerClientEvent(BR.Net.INV_SET, src, payload)
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

--- THE RELOAD RULE. THERE IS EXACTLY ONE OF IT AND THIS IS IT.
---
--- Rounds out of the pool and into the magazine, up to what the magazine holds.
--- It MOVES and it cannot MINT: `clip + pool` is the same number on both sides
--- of this function, whatever it is given, which is the property the whole ammo
--- model rests on and the one a reload KEY makes somebody able to press on
--- demand. Every guard below is a `return 0` rather than a clamp, so there is no
--- path through it that writes without the arithmetic above having balanced.
---
--- THREE CALLERS, AND THEY WERE TWO COPIES BEFORE THIS EXISTED (2026-08-23):
---
---   spendRound          an empty magazine refills when the last round is fired
---   the INV_AMMO floor  ...and when the client reports it emptied unseen
---   INV_RELOAD          the manual key, which is the reason this is shared
---
--- The first two keep their own `clip <= 0` test and this is a strict
--- generalisation of what they used to do inline: at clip 0, `w.clip - 0` is
--- `w.clip` and the arithmetic is identical to the line each of them held. The
--- manual reload is the only caller that tops up a PARTIAL magazine, which is
--- the whole difference between a reload key and waiting to run dry -- and it is
--- the reason this is one function rather than a third copy that would have to
--- be kept honest against the other two by hand.
---
--- @param inv table
--- @param s table|false   a slot
--- @return integer moved
function BR.Inv.reload(inv, s)
    if not inv or not s or s.kind ~= BR.ItemKind.WEAPON then return 0 end

    local w = BR.Config.WeaponById[s.item]
    -- Melee has no magazine and a throwable's "magazine" is its stack -- neither
    -- is a thing rounds can be moved into.
    if not w or w.melee or not w.clip or not w.ammo then return 0 end

    local pool = inv.ammo[w.ammo] or 0
    local clip = s.clip or 0
    -- ROOM, NOT EMPTINESS, and `<= 0` on both rather than a truthiness test:
    -- these are the two numbers a bare `if pool then` gets exactly backwards,
    -- because 0 IS TRUTHY IN LUA and an empty pool is the case this function
    -- exists to refuse.
    local room = w.clip - clip
    if room <= 0 or pool <= 0 then return 0 end

    local moved = math.min(room, pool)
    s.clip, inv.ammo[w.ammo] = clip + moved, pool - moved
    return moved
end

--- STAMP A STACK THAT IS LEAVING SOMEBODY'S HANDS.
---
--- ═══ THE FOURTH DOOR (owner, 2026-08-23) ═══
---
--- "when I drop it and pick it back up it has 1 round in it now." His /brammo,
--- on a railgun fired dry: the magazine went 0 -> 1 while the heavy pool stayed
--- 0. A round was CREATED, not moved, and docs/terminology.md says an empty pool
--- cannot conjure.
---
--- IT IS THE PICKUP, AND IT WAS NEVER ONE ROUND. BR.Inv.give ends by granting a
--- clip's worth of reserve to any weapon that arrives -- "a found gun has to be
--- usable" -- and it asked nothing about where the gun came from. So a railgun
--- dropped with 0/0 came back with THREE in the heavy pool, out of nothing, and
--- it COMPOUNDED: the same trip run three times measured 3, 6, 9. What the owner
--- saw was smaller only because it had already been laundered -- the client
--- pushes the conjured three onto the ped, the engine's own reading comes back
--- lower, and the INV_AMMO floor below spends the difference and then reloads,
--- which turns "+3 in the pool" into "1 in the magazine, pool 0". The row he
--- photographed is the tail of it, not the size of it.
---
--- AND IT IS NOT RAILGUN-ONLY. A dry pistol makes the same trip and comes back
--- with twelve light rounds. The railgun is simply the only weapon whose pool is
--- normally 0, so it is the only one where a conjured round has nothing to hide
--- behind -- exactly as the 2026-08-23 switch bug was found on the same gun for
--- the same reason.
---
--- THE GRANT IS RIGHT AND ITS AUDIENCE WAS WRONG. A gun off the floor of the
--- world, out of a crate, off the airdrop shelf, should arrive with something in
--- it; that is a piece of loot being minted. A gun that has already been in an
--- inventory has already been paid for -- its magazine travels with it and its
--- reserve stayed with the player who had it -- so re-minting one is printing
--- ammunition on demand.
---
--- So every stack that leaves an inventory is marked on the way out, and the
--- grant asks. The mark is applied at the EXIT rather than stored on the slot:
--- there are exactly four ways out (a drop, a death, a displaced swap, and this
--- is all of them), each of them returns the slot table itself, and deriving the
--- fact where it becomes true means there is no stale copy of it to go wrong.
--- @generic T
--- @param s T
--- @return T
local function released(s)
    if s then s.carried = true end
    return s
end

-- --------------------------------------------------------------------------
-- Giving
-- --------------------------------------------------------------------------

--- How many of one item this inventory holds, ACROSS EVERY SLOT.
---
--- A question about the PLAYER, not about a slot, and that is the whole of
--- #171's second fault (owner, 2026-08-18: "with 3 shield in one slot, I can
--- pickup more shields in a different slot. Anything with a max carry limit
--- should be applied across all slots, not a per-slot basis"). A rule that
--- reads one slot enforces a PER-SLOT limit no matter how globally it is
--- worded, and the player discovers that by putting the same item somewhere
--- else.
---
--- `or 1` rather than `or 0` for a countless stack: a weapon slot is one
--- weapon. Nothing in the game writes a stack without a count today, but a
--- missing one meaning ZERO would silently under-count a cap, and a cap that
--- under-counts is the permissive failure -- it lets a player past a ceiling
--- rather than stopping them short of it.
--- @param inv table
--- @param item string
--- @return integer
local function heldOf(inv, item)
    local n = 0
    for i = 1, SLOTS do
        local s = inv.slots[i]
        if s and s.item == item then n = n + (s.count or 1) end
    end
    return n
end

--- How much more of this item the player may carry. THREE ANSWERS (#171).
---
---   nil -- THERE IS NO CEILING. Weapons never have one; neither do shields.
---   > 0 -- there is a ceiling and it has not been reached.
---   0   -- there is a ceiling and it has been reached.
---
--- NIL IS NOT ZERO, and keeping the two apart is the point of returning nil at
--- all. Reading "no cap" as "a cap of zero" is what shipped "You can only carry
--- 0 of thoses." out of this pair of files once already, and the reopened half
--- of #171 is the same confusion wearing a different sentence: a refusal that
--- announced a maximum for an SNS Pistol, which has never had one.
---
--- math.max, because an inventory can already sit OVER a ceiling -- see the
--- split-stack note in BR.Inv.give. Without it a player holding four bandages
--- against a cap of three gets a NEGATIVE room, which is not <= 0 by accident
--- but by arithmetic, and clamping `left` to it would hand them a negative
--- count.
--- @param inv table
--- @param stack table
--- @return integer|nil
local function carryRoom(inv, stack)
    local cap = carryMaxOf(stack)
    if not cap then return nil end
    return math.max(0, cap - heldOf(inv, stack.item))
end

--- Would this swap trade the active slot for something exactly like it?
---
--- THE ONE SWAP THAT IS NEVER A CHOICE (owner, 2026-08-18: "I don't want the
--- swap, if both the item being picked up and the item in my active slot are
--- the same type").
---
--- The swap below exists so a full inventory can still take an UPGRADE in one
--- motion -- a rifle over a pistol, a med kit over a bandage. Trading a Shield
--- for a Shield is not an upgrade; it is a lateral move that costs the player
--- real goods, because what leaves is a whole SLOT and what arrives is one
--- pickup. Hold a full stack of three shields, walk over a loose one, and the
--- swap hands you a stack of ONE and puts three on the floor. The player
--- pressed a key and came away with less than they started with.
---
--- SAME ITEM ID, NOT SAME KIND. The wider reading -- refuse when the two are
--- both WEAPON, or both CONSUMABLE -- would delete the swap outright, since
--- WEAPON-for-WEAPON is precisely the case it was built for and the one the
--- comment above still describes. Narrow is also what the report is about: two
--- shields, one name.
---
--- Compared against what is IN THE ACTIVE SLOT rather than against the whole
--- inventory, because the active slot is the only thing a swap can throw away.
--- Holding the same gun in slot 4 while slot 2 is a pistol still swaps, and
--- should: that trade loses nothing.
---
--- THIS IS NOT A CARRY LIMIT AND MUST NEVER SPEAK AS ONE. That conflation is
--- the reopened half of #171. The two rules answer different questions --
--- "would this trade cost me goods" reads ONE slot, "have I reached my
--- maximum" reads ALL of them and only exists for items that have a maximum --
--- and carryRoom above is consulted FIRST in BR.Inv.give so that a player who
--- really is at a ceiling hears the ceiling's own sentence. What is left for
--- this to refuse is a swap, so BR.Loot.refusalText answers `sameitem` with the
--- way out of it: pick another slot.
--- @param displaced table|nil  what the swap would push out (false when empty)
--- @param stack table          what is being picked up
--- @return boolean
local function isLikeForLike(displaced, stack)
    if not displaced or not stack then return false end
    return displaced.item == stack.item
end

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
function BR.Inv.give(src, stack, opts)
    local inv = BR.Inv.of(src)
    if not inv or not stack then return false, nil, 'noinv' end

    -- Ammo never occupies a slot.
    if stack.kind == BR.ItemKind.AMMO then
        local taken = addAmmo(inv, stack.item, stack.count or 0)
        if taken <= 0 then return false, nil, 'ammofull' end
        BR.Inv.push(src, opts)
        return true, nil, nil
    end

    -- THE CARRY CEILING, ASKED ONCE AND FOR EVERY KIND (#171).
    --
    -- It used to be asked inside the consumable branch alone, which was true to
    -- the config -- only consumables and throwables have ceilings -- and false
    -- to the READER, who could no longer tell whether a weapon was uncapped or
    -- merely unchecked. It is asked here now so that the three cases are one
    -- decision made in one place, above every branch that could disagree:
    --
    --   nil ceiling  -- pick it up; find it a slot. A second SNS Pistol is
    --                   legitimate and always was.
    --   room left    -- pick it up, clamped to what is left.
    --   no room      -- refuse, and this is the ONLY refusal entitled to talk
    --                   about a maximum.
    --
    -- `room and room <= 0` and not `not room`: nil is uncapped, zero is full,
    -- and the day those two collapse into each other is the day every weapon in
    -- the game becomes unpickable. Lua treats both as falsey; only the code has
    -- to keep them apart.
    local room = carryRoom(inv, stack)
    if room and room <= 0 then return false, nil, 'carrymax' end

    if stack.kind == BR.ItemKind.CONSUMABLE
       or stack.kind == BR.ItemKind.THROWABLE then
        local left = stack.count or 1
        local max  = maxStackOf(stack)

        -- The ceiling is across EVERY SLOT, not per stack. Without it, capping
        -- the stack at three simply produced two stacks of three (user call,
        -- 2026-08-06: "no higher quantities of either item should be allowed").
        if room then left = math.min(left, room) end

        local before = left

        -- Top up existing stacks first, lowest slot first, so a player who
        -- picks up their eighth bandage does not open a second stack while
        -- the first has room.
        for i = 1, SLOTS do
            local s = inv.slots[i]
            if left > 0 and s and s.item == stack.item and s.count < max then
                -- `space`, not `room`: `room` is the WHOLE INVENTORY's headroom
                -- and it is still live here. Two different numbers under one
                -- name inside one function is how a global cap quietly becomes
                -- a per-slot one.
                local space = max - s.count
                local move = math.min(space, left)
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

            -- ...BUT NOT FOR AN IDENTICAL ITEM. See isLikeForLike: reaching a
            -- full inventory with a shield in hand and a shield on the floor
            -- would otherwise trade a full stack for a single pickup.
            --
            -- REACHED ONLY WHEN THERE IS NO CEILING TO BLAME, because carryRoom
            -- ran above and a player who is genuinely at their maximum already
            -- left with `carrymax`. Everything that gets this far is an item
            -- the player MAY have more of and has nowhere to put -- so the
            -- refusal is about the slot, and says so.
            if isLikeForLike(displaced, stack) then
                return false, nil, 'sameitem'
            end

            inv.slots[at] = {
                item = stack.item, kind = stack.kind,
                rarity = stack.rarity, count = math.min(max, left),
            }
            BR.Inv.push(src, opts)
            return true, released(displaced), nil
        end

        BR.Inv.push(src, opts)
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

    -- NO MAGAZINE MEANS NO NUMBER, not a zero. The `or 0` fallback gave melee
    -- a clip of 0, and the HUD reads `clip ~= nil` to decide whether to draw a
    -- counter at all -- so a machete arrived wearing "0 / 0" and a slot badge
    -- reading 0 (user, 2026-08-08). Absent and empty are different facts and
    -- the wire has to keep them apart.
    local clip = stack.clip or (w and w.clip)
    if clip == nil and w and not w.melee then
        clip = 0   -- a firearm with no authored magazine is a config error,
                   -- but it should still render as empty rather than as melee
    end

    local placed = {
        item = stack.item, kind = stack.kind, rarity = stack.rarity,
        count = 1, clip = clip,
    }

    local displaced = nil
    local at
    if free then
        at = free
    else
        at = math.max(inv.active, 1)   -- never slot 0: fists hold nothing
        displaced = inv.slots[at] or nil

        -- THE SAME GUN FOR THE SAME GUN IS NOT A TRADE. Nothing has been
        -- written to the inventory yet, so this returns clean -- and it must
        -- return here rather than proceed, because the swap would hand the
        -- player the floor copy's magazine and drop their own loaded one.
        --
        -- AND IT IS NOT A MAXIMUM. A weapon has no carryMax and never will, so
        -- carryRoom returned nil above and no ceiling was ever in play here.
        -- This is the branch that told the owner he could not pick up any more
        -- SNS Pistols (2026-08-18) -- reachable at all only because every one
        -- of his five slots was full, since `free` is taken first and a second
        -- pistol into an empty slot never reaches this line.
        if isLikeForLike(displaced, stack) then
            return false, nil, 'sameitem'
        end
    end
    inv.slots[at] = placed

    -- A weapon picked up into an EMPTY hand comes up in it. Picking your
    -- first gun off the floor and then having to press a number key to hold
    -- it is the kind of friction that gets you killed in the first minute.
    --
    -- FISTS ARE A DELIBERATE CHOICE, though: someone who selected slot 0 put
    -- their gun away on purpose, and yanking a rifle back into their hands
    -- because they walked over one undoes that.
    --
    -- ...AND SINCE #155, BEING ON SLOT 0 IS NO LONGER EVIDENCE OF A CHOICE.
    -- Fists are now where every inventory starts, so `inv.active == MELEE_SLOT`
    -- on its own would refuse to arm a player who has never touched a slot key
    -- -- which is every player, on their first gun, in the first minute. That is
    -- a straight trade of the bug being fixed for a worse one: landing
    -- empty-handed is the ask, staying empty-handed while standing on a rifle is
    -- not. `choseActive` is only set by an INV_SELECT the player actually sent,
    -- so the deliberate holster is still honoured and the default is not.
    if (inv.active ~= MELEE_SLOT or not inv.choseActive)
       and (displaced or not inv.slots[inv.active] or inv.active == at) then
        inv.active = at
    end

    -- A FOUND gun has to be usable. One clip's worth of reserve, capped by
    -- the pool -- enough to fight with, not enough to stop looting ammo.
    --
    -- `not stack.carried` IS THE WHOLE OF THE 2026-08-23 DROP/PICKUP FIX, and
    -- the note on `released` above is why. This line used to run for every
    -- weapon that arrived by any route, so a gun the player had just thrown on
    -- the floor was minted a fresh magazine's worth of reserve when they picked
    -- it up again -- out of an empty pool, repeatable, compounding. A weapon
    -- that has been in an inventory is not found loot; it is the same weapon
    -- coming back, and it comes back with what it left with.
    if w and w.ammo and not stack.carried then
        addAmmo(inv, w.ammo, (w.clip or 0) * (L.weaponReserveClips or 1))
    end

    BR.Inv.push(src, opts)
    return true, released(displaced), nil
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
    return released(s)
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
            out[#out + 1] = released(s)
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
    -- THE PLAYER HAS NOW CHOSEN, and this is the only line in the file that may
    -- say so (#155). It is what makes a hand-picked slot 0 different from the
    -- one every inventory starts on -- see newInv and the pickup rule in
    -- BR.Inv.give. Set for every slot, not just fists: coming back to a weapon
    -- and then holstering it deliberately has to read the same as holstering
    -- straight away.
    inv.choseActive = true
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

-- THE MANUAL RELOAD KEY (owner, 2026-08-23: "we need a manual reload button,
-- which should default to R").
--
-- ═══ IT MUST NOT BECOME DOOR NUMBER FIVE ═══
--
-- Four ways to conjure ammunition have been closed in two days -- the slot
-- switch, an unrelated pickup, the post-landing sweep and the drop/pickup round
-- trip -- and every one of them was something a player could REPEAT. A reload
-- key is that shape by construction: it is a button, in the player's hand,
-- pressable as fast as they like, and any version of it that can add a round can
-- add all of them.
--
-- SO IT ADDS NOTHING AND CHOOSES NOTHING. It carries no payload, it names no
-- slot, it reloads the slot THIS SIDE believes is active, out of the pool THIS
-- SIDE holds, by BR.Inv.reload -- the same function spendRound and the INV_AMMO
-- floor run. That function MOVES rounds, so `clip + pool` is identical on both
-- sides of it, so pressing this key a thousand times at a pool of zero produces
-- exactly what pressing it once does: nothing. There is no rate limit here and
-- none is needed -- a spammed reload is a magazine that is already full, which
-- the rule returns 0 for.
--
-- AND IT DOES NOT ASK THE ENGINE. The obvious implementation is to tell the
-- client to call the reload native, but the ped's magazine is not the authority
-- on anything here and never has been (see the header, and the whole of
-- client/inventory.lua's `shortfall`). The server moves its own numbers and
-- pushes; the ped learns about it through the INV_SET that follows, on the same
-- path a reload the server paid for has always travelled.
--
-- THE SILENCE IS DELIBERATE. A full magazine, an empty pool, fists, a melee
-- weapon in hand: all of them return without a word, because a key that talks
-- back every time it has nothing to do becomes noise in a firefight -- and the
-- one case worth explaining, an empty pool, is already on the HUD as a zero.
RegisterNetEvent(BR.Net.INV_RELOAD)
AddEventHandler(BR.Net.INV_RELOAD, function()
    local src = source
    local inv = liveInv(src)
    if not inv then return end

    -- SLOT ZERO IS FISTS and holds nothing; every other index is checked by
    -- BR.Inv.reload, which refuses anything that is not a magazined weapon.
    if BR.Inv.reload(inv, inv.slots[inv.active]) <= 0 then return end

    -- Reloading interrupts a consumable, exactly as a slot switch does: both are
    -- "what my hands are doing", and letting a med kit finish while a magazine
    -- goes in would be a free heal mid-fight.
    inv.using = nil
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

    -- ═══ `useMs` IS WHAT MAKES A CONSUMABLE USABLE FROM THE INVENTORY ═══
    --
    -- Owner, 2026-08-23, on the CPR kit: "this item should do absolutely
    -- nothing while the player is alive." It did rather more than nothing --
    -- it took the server down:
    --
    --     @br_core/server/inventory.lua:883: attempt to perform arithmetic on
    --     a nil value (field 'useMs')
    --
    -- The kit is a CONSUMABLE and it is in BR.Config.ConsumableById, because it
    -- has to be carried, dropped, labelled, propped and rolled into an airdrop
    -- like any other. What it is NOT is a channelled item: it is spent by the
    -- prompt while downed (BR.Net.RESCUE_CALL), which validates its own
    -- conditions, so config/loot.lua gives it no `useMs` on purpose -- "a
    -- `useMs` here would be a channel nothing can start". Nothing refused it
    -- before the arithmetic below, so pressing use on it while standing threw.
    --
    -- ═══ WHY A GUARD HERE AND NOT A REQUIRED FIELD AT CONFIG LOAD ═══
    --
    -- Because the kit is not malformed. A load-time "every consumable must
    -- declare useMs" check would be a rule the shipped config deliberately
    -- breaks, so it would have to carry an exemption for `cprkit` -- which puts
    -- the same decision in two files and makes the next non-channelled item a
    -- config edit in both. A verify.sh gate has the same problem one step
    -- further out: it cannot see which consumables are meant to be reachable
    -- from a keypress, so it would be scanning for a fake field.
    --
    -- The honest statement is the POSITIVE one, and this line is it: a
    -- consumable is usable through the inventory exactly when it declares how
    -- long using it takes. Anything else is not an item with a missing field,
    -- it is an item this path was never for -- and the whole class is refused
    -- here rather than crashing on the next one somebody adds.
    --
    -- SILENTLY. No notify, no print, no INV_SET. "Absolutely nothing while the
    -- player is alive" is the requirement, and a console line every time a
    -- player mashes their kit slot is not nothing.
    --
    -- ═══ AND ZERO IS AN ABSENCE AGAIN (#228, 2026-09-03) ═══
    --
    -- This test was widened from `<= 0` to `< 0` when the repair kit shipped
    -- instant, so that `useMs = 0` could mean "using this takes no time". The
    -- owner has since asked for a progress bar on the kit -- it is a 5000ms
    -- channel now -- and NOTHING IN THE SHIPPED CONFIG DECLARES ZERO ANY MORE.
    --
    -- So the widening is reverted rather than left as a capability with no
    -- user. A `useMs = 0` that reached this line today would open a channel
    -- that completed on its first tick, which is a third behaviour nobody asked
    -- for and nobody would find until they wrote it by accident; and this
    -- repo's standing lesson is that scaffolding without callers gets read as
    -- live. tools/test_shared.lua asserts the same thing from the config side:
    -- a consumable whose channel was zeroed is malformed, not instant.
    --
    -- THE SENTENCE ABOVE IS TRUE WORD FOR WORD AGAIN: a consumable is usable
    -- through the inventory exactly when it declares how long using it takes,
    -- and zero is not a length any more than nil is. The CPR kit's nil is still
    -- caught by the type test on the left, before any comparison happens.
    if type(c.useMs) ~= 'number' or c.useMs <= 0 then return end

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

    -- ═══ A CAR IS UNPACKED ON FOOT, AND THE PRESS IS THE FIRST OF TWO ASKS ═══
    --
    -- Owner, 2026-08-31: "let's make sure the player cannot use their purchased
    -- vehicle spawn while already inside another vehicle. They can only use it
    -- while on foot."
    --
    -- THE SAME `shopCar` COUPLING AND NO OTHER, which is the rule the effect
    -- branch below states at length: this file does not know what a catalogue
    -- is, so it asks BR.Shop about a consumable that carries that field and
    -- knows nothing else about cars. A server with no shop rules nothing and
    -- consumes nothing differently, exactly as it does at the effect.
    --
    -- REFUSED HERE RATHER THAN AT THE EFFECT, AND THAT IS THE WHOLE PLACEMENT.
    -- The item is CONSUMED four lines above BR.Shop.unpack is called -- see the
    -- note there, a purchase is never refunded -- so a rule enforced at the
    -- effect would cost a player their car for standing in one. Enforced at the
    -- channel it costs them nothing at all: they step out and press again.
    --
    -- THE BOOLEAN REFUSES; THE STRING ONLY SPEAKS. BR.Shop.refusesUse returns
    -- them apart on purpose (its header says why), so a build with no wording
    -- still refuses in silence rather than allowing the use.
    if c.shopCar and BR.Shop and BR.Shop.refusesUse then
        local refused, why = BR.Shop.refusesUse(src)
        if refused then
            if why then BR.Server.notify(src, why, 'warn') end
            return
        end
    end

    -- ═══ A VEHICLE REPAIR IS RULED ON THIS PRESS, AND RULED ON AGAIN EVERY
    --     PASS AFTER IT (#228) ═══
    --
    --   "instead of instantly burning the item it should have a progress bar
    --    ... As that bar progresses, the vehicle health should incrementally
    --    increase to finally reach full once the item has been spent."
    --                                          -- owner, 2026-09-03
    --
    -- The first build of this was INSTANT: one press, one grant, no channel.
    -- The owner reversed that, so everything below this block is now the kit's
    -- code path too and the only thing that happens here is the RULING. NOTHING
    -- IS SPENT ON THIS PRESS -- see the note where the channel is opened.
    --
    -- ═══ THE SERVER NAMES THE CAR. THE CLIENT IS NOT ASKED WHICH ONE ═══
    --
    -- INV_USE carries a SLOT and nothing else -- there is no vehicle in the
    -- message and there must not be, because "repair the car I say I am in" is
    -- a client repairing any car on the map. BR.Vehicles.drivenNetId answers
    -- from the server's own reads of its own ped, and it answers nil for a
    -- player on foot, a passenger, and a vehicle the platform does not network.
    --
    -- THE ANSWER IS KEPT ON THE CHANNEL, not just used and dropped. The tick
    -- loop compares against it every pass, so the kit is spent on the car it was
    -- aimed at or on nothing -- five seconds is long enough to change cars.
    --
    -- NIL-GUARDED ON THE MODULE, not on the answer, in the same shape as the
    -- BR.Shop guards above: a build without server/vehicles.lua cannot rule this
    -- and therefore refuses it, rather than spending a kit into silence.
    --
    -- ═══ NOT DRIVING, IT SAYS SO. ANY OTHER NO IS STILL SILENT ═══
    --
    --   "the copy should be revised to 'You can only use this item while
    --    driving.'"                            -- owner, 2026-09-04
    --
    -- (It replaced "You cannot use this item while on foot", which was the
    -- previous day's wording for this same refusal.)
    --
    -- THE BOOLEAN REFUSES AND THE STRING ONLY SPEAKS -- server/shop.lua's
    -- standing convention, and the reason these are two tests rather than one.
    -- `drivenNetId` answers nil for FOUR different situations and the owner has
    -- named the sentence for the one a player will meet: they pressed it
    -- standing in the road. BR.Vehicles.ridingIn is the server's own answer to
    -- "is this ped in a vehicle at all" (it exists because the bare native is
    -- citizenfx/fivem#4006 and lies about it), so a ped in no vehicle is told,
    -- and A PASSENGER, and a driver of a vehicle the platform does not network,
    -- are refused in silence exactly as before.
    --
    -- THE PASSENGER'S SILENCE IS NOW AN ASYMMETRY RATHER THAN A GAP, AND IT IS
    -- FLAGGED RATHER THAN CLOSED. The old sentence could not be said to somebody
    -- sitting in a car -- it would have been a lie -- and that was the whole
    -- reason for the silence. The new one is TRUE of a passenger, and the
    -- mid-channel arm below does say it to one. What is missing is not a reason
    -- but a ruling: the owner named two moments ("switch seats", "leave the
    -- vehicle") and pressing the key from a passenger seat is a third he has not
    -- been asked about. Inventing the extension is how copy stops being his.
    --
    -- ...AND A BUILD WITH NO `ridingIn` STILL REFUSES, it just says nothing.
    -- Absent copy must never delete a rule.
    --
    -- ═══ NOTHING IS SPENT BY A REFUSAL, AND NOTHING IS SPENT BY THE PRESS ═══
    --
    -- This block rules and returns; the item is debited by the COMPLETION, like
    -- every other consumable in the file. So a mis-press costs a keypress.
    local netId = nil
    if c.repairVeh then
        if not (BR.Vehicles and BR.Vehicles.drivenNetId) then return end

        netId = BR.Vehicles.drivenNetId(src)
        if netId == nil then
            if BR.Vehicles.ridingIn and BR.Vehicles.ridingIn(e.ped) == nil then
                BR.Server.notify(src, USE_WHILE_DRIVING, 'warn')
            end
            return
        end
    end

    -- ═══ THE COMPLETION SPENDS IT, LIKE EVERYTHING ELSE IN THIS FILE (#228) ═══
    --
    --   "when using it the inventory item visually goes away immediately and
    --    the item function is applied immediately. BUT THEN the progress bar
    --    shows up. What we'd discussed earlier is not that. Any other
    --    consumable doesn't get removed until the progress bar is full, and
    --    that's why we have a progress bar - because it's in progress."
    --                                          -- owner, 2026-09-03
    --
    -- A BUILD OF THIS DEBITED AT THE KEYPRESS AND IT WAS A MISREADING. What he
    -- had said before was "the actuation is a momentary press like anything
    -- else - then once it's spent, it's spent", which is a sentence about the
    -- INPUT -- a tap rather than a held key, which is how this channel already
    -- works -- and about the kit not coming back afterwards. It was read as
    -- "debited at the press", and the sentence above is him correcting that.
    -- SPENT HAPPENS AT COMPLETION. There is no `spendOnPress` any more; a field
    -- with no true case is scaffolding, and this repo's standing lesson is that
    -- scaffolding gets read as live.
    --
    -- WHAT THAT COSTS, STATED PLAINLY SO NOBODY "FIXES" IT: an interrupted
    -- channel now costs NOTHING. A slot switch, a reload, dying, or leaving the
    -- driving seat at 4.9 seconds leaves the player holding the kit AND holding
    -- whatever repair the slices already put on the car -- because a granted
    -- repair is health on a car on somebody else's machine and there is nothing
    -- to take back. That is the med kit's contract exactly (its partial heal is
    -- kept too), it is what "in progress" means, and it is the owner's ruling
    -- twice over. IT IS ALSO REPEATABLE: the vehicle ledger below lives on the
    -- channel, so pressing, cancelling and pressing again starts a fresh one and
    -- grants again from zero. A player who is willing to tap two keys in turn
    -- can therefore mend a car for more than one kit's worth without spending
    -- the kit. That is a known consequence of the shape he asked for, written
    -- down rather than designed around; closing it means either taking the
    -- climb away or building a per-vehicle ledger, and both are his call.
    inv.using = {
        slot   = slot,
        item   = s.item,
        ms     = c.useMs,
        endsAt = GetGameTimer() + c.useMs,
        -- Baselines: hp0 doubles as the damage-cancel reference, and both are
        -- what the per-tick partial effects interpolate FROM.
        hp0     = e.hp or 0,
        armour0 = e.armour or 0,
        -- The car this use was aimed at, and the running total of health points
        -- already granted for it -- see the tick loop for why a ledger is needed
        -- rather than a per-tick delta.
        veh        = netId,
        vehGranted = 0.0,
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
    if not s then return end

    -- ═══ THE FIFTH DOOR, AND IT OPENED THE MOMENT THIS HANDLER STOPPED
    --     RETURNING (owner, 2026-08-23, third report) ═══
    --
    -- "I also picked up the railgun again this time, which came with ammo, and
    -- was immediately drained of all railgun ammo..... didn't even do anything."
    --
    -- HE DIDN'T. THE ROUND TRIP DID. An INV_AMMO is a MEASUREMENT OF A MOMENT --
    -- "you said 6, the gun holds 5" -- and until this line the arithmetic below
    -- was applied to whatever this inventory happened to hold when the message
    -- ARRIVED. Between those two instants sits one round trip, and a pickup
    -- lands inside it comfortably: the loop speaks every 150ms and a LOOT_CLAIM
    -- is answered in rather less.
    --
    -- So a report about the weapon he was holding a moment earlier arrived after
    -- the airdrop railgun had been credited, and `lost` was computed against the
    -- LARGER number. Three rounds in the magazine and three in the heavy pool
    -- paid for the previous weapon's shots, in one write, before he fired it.
    --
    --     probe, 2026-08-23: a dry rpg in slot 1 over an empty heavy pool; a
    --     found railgun lands in slot 2 (clip 3, pool 3); the in-flight
    --     `{slot=1,total=0}` then arrives and the pool reads 0. Same probe with
    --     the railgun landing in slot 1 itself: clip 3 pool 3 -> clip 0 pool 0.
    --
    -- AND IT WAS NEVER RAILGUN-ONLY -- a pistol arriving under an in-flight
    -- report is zeroed identically. The railgun is where it SHOWS, for the two
    -- reasons it always is: an explosive is charged for nothing the server can
    -- see, so its report is the whole holding rather than a round, and HEAVY is
    -- the one pool normally at 0, so there is nothing else in it to absorb the
    -- loss. 951c6ea's floor is what made a stale report able to spend anything
    -- at all; before it this handler returned outright under serverAmmo.
    --
    -- ═══ SO THE REPORT NAMES WHAT IT WAS MEASURED AGAINST, AND A MISMATCH IS
    --     REFUSED RATHER THAN GUESSED AT ═══
    --
    -- `was` is what THIS SERVER last told that slot it holds, echoed back. It is
    -- a compare-and-swap: the swap happens only if the value the client read is
    -- still the value here. Nothing about it is trusted -- it is compared, never
    -- used as a quantity -- so a client that lies about it achieves a refusal,
    -- which is the one outcome that cannot cost anybody a round.
    --
    -- REFUSING CANNOT LOSE AMMUNITION, WHICH IS WHY THIS IS THE SAFE DIRECTION
    -- AND NOT A HOLE IN 951c6ea. The client re-arms its baseline on every
    -- INV_SET -- rebaseline(), client/inventory.lua -- and the push that
    -- invalidated a report is itself an INV_SET, so a refused report is measured
    -- again against the fresh numbers and re-sent within one cycle. Rounds an
    -- explosive really burnt are still charged; they are charged against the
    -- holding they were actually taken out of.
    --
    -- WHAT `was` MEANS PER KIND, and it is the same sentence in both: the number
    -- this server states for that slot. A magazined weapon states `clip` plus
    -- its pool; a throwable's whole statement is its stack.
    local was = math.tointeger(d.was)
    if not was or was < 0 then return end
    do
        local here
        if s.kind == BR.ItemKind.THROWABLE then
            here = s.count or 0
        else
            local w = BR.Config.WeaponById[s.item]
            local pool = (w and w.ammo) and (inv.ammo[w.ammo] or 0) or 0
            here = (s.clip or 0) + pool
        end
        if was ~= here then return end
    end

    -- THROWABLES ARE COUNTED, NOT MAGAZINED.
    --
    -- A grenade's "ammo" IS its stack: the engine holds three of them and
    -- throwing one leaves two. This handler used to accept WEAPON only and
    -- drop everything else on the floor, so a thrown grenade was never
    -- deducted from anything -- infinite grenades, for as long as the slot
    -- existed. Same decrease-only rule: the engine's count may fall, never
    -- rise, and the slot empties when it hits zero.
    -- AND THIS BRANCH SURVIVES serverAmmo, which the round-counting one below
    -- does not. That is not an oversight either way:
    --
    -- The server counts RIFLE rounds off validated weaponDamageEvents, because
    -- every shot raises one. A THROW raises nothing. The only event a grenade
    -- produces is its detonation -- which lands a second or more later, may
    -- never arrive at all (into water, off a cliff, at nobody), and is
    -- cancelled by this very validator when it does. Counting throws off
    -- detonations would give infinite grenades to anyone who missed.
    --
    -- So the M5 client report stays the authority here, and it stays safe for
    -- the same reason it always was: decrease-only, so the worst a liar can do
    -- is throw their own grenades away. Between 2026-08-07 and 2026-08-08 the
    -- serverAmmo early-return sat ABOVE this branch and nothing decremented
    -- throwables at all -- literally unlimited grenades.
    if s.kind == BR.ItemKind.THROWABLE then
        local have = s.count or 0
        if total >= have then return end
        if total <= 0 then
            inv.slots[slot] = false
        else
            s.count = total
        end
        -- ...and the throw is remembered, because the explosion arrives after
        -- the slot is empty and the validator has to know it was ours.
        if BR.Damage and BR.Damage.noteThrow then
            BR.Damage.noteThrow(src, s.item)
        end
        BR.Inv.push(src)
        return
    end

    if s.kind ~= BR.ItemKind.WEAPON then return end

    local w = BR.Config.WeaponById[s.item]
    if not w then return end

    -- ═══ UNDER serverAmmo THIS IS A FLOOR, NOT AN AUTHORITY (2026-08-23) ═══
    --
    -- It used to be a flat `return`. M6 counts rounds off validated shot events,
    -- so for the shots it SEES it has the better answer and a second opinion
    -- would only overwrite the reload it just paid for. The part that was not
    -- true is the part that mattered: BR.Damage.spendRound is reachable from
    -- ONE place, the weaponDamageEvent handler, so a round burnt by anything
    -- that raises no such event was charged to nobody and stayed on the books
    -- forever. An explosive raises none at all -- server/damage.lua measured
    -- that on 2026-08-08 -- which is the whole airdrop shelf, and the owner
    -- found it on the railgun: fire it dry, switch slots, and client/inventory's
    -- re-grant wrote the untouched server number back onto the ped.
    --
    -- So the client keeps ONE job here and it is the job only it can do: saying
    -- that rounds are GONE. The TOTAL may fall and may do nothing else -- it
    -- cannot rise (the arithmetic below is a subtraction), it cannot choose the
    -- split, and it cannot trigger a reload the pool has not paid for. Under an
    -- honest client this fires only when the server has fallen behind, which is
    -- exactly the drift it exists to close; under a lying one the worst
    -- available move is still to throw your own ammunition away.
    if (BR.Config.Combat or {}).serverAmmo then
        local pool     = w.ammo and (inv.ammo[w.ammo] or 0) or 0
        local wasClip  = s.clip or 0
        local lost     = (wasClip + pool) - total
        if lost <= 0 then return end

        -- OUT OF THE MAGAZINE FIRST, then the reserve, because that is the
        -- order rounds leave a gun. Anything deeper than the magazine is a
        -- burst that spanned a reload, and the reserve is what paid for it.
        local newClip = wasClip - lost
        local newPool = pool
        if newClip < 0 then
            newPool = math.max(0, newPool + newClip)
            newClip = 0
        end

        s.clip = newClip
        if w.ammo then inv.ammo[w.ammo] = newPool end

        -- AND THE RELOAD IS STILL THE SERVER'S, by running the same rule
        -- spendRound runs rather than a second copy of it: an empty magazine
        -- over a non-empty pool refills, once, capped by the magazine. Doing it
        -- here rather than waiting for the next shot keeps the two paths from
        -- disagreeing about what an empty gun looks like -- and it moves rounds
        -- without creating any, so the total is untouched.
        --
        -- `newClip <= 0` STAYS HERE AND IS NOT INSIDE BR.Inv.reload. That
        -- function tops a magazine up to capacity, which is what a player
        -- pressing the reload key asks for; this path is a REPORT of rounds
        -- already gone, and topping up a partial magazine off the back of one
        -- would reload the gun every time it was fired.
        if newClip <= 0 then BR.Inv.reload(inv, s) end

        BR.Inv.push(src)
        return
    end

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
-- coarse enough to be free.
--
-- ═══ WHO PAYS, AND WHEN -- THE ONE CONTRACT THIS LOOP RESTS ON ═══
--
-- THE RULE, AND IT HAS NO EXCEPTIONS AGAIN: the COMPLETION is what consumes the
-- item, so an interrupted use costs nothing and cancelling needs no refund path
-- at all. That is true of the med kit, the bandage, both shields, the shop car
-- AND THE REPAIR KIT, and it is what lets every guard below simply drop the
-- channel and walk away.
--
-- ONE ITEM BRIEFLY DIVERGED AND THE OWNER REVERSED IT (#228, 2026-09-03): the
-- repair kit was debited at the keypress, which meant the slot emptied the
-- instant the bar appeared. "Any other consumable doesn't get removed until the
-- progress bar is full, and that's why we have a progress bar - because it's in
-- progress." The `spendOnPress` field and the `u.spent` waiver it needed are
-- both gone rather than set false, and the two guards they waived -- the
-- slot-identity test below and the completion debit -- are back to running
-- unconditionally for every consumable there is.
--
-- WHAT AN INTERRUPTION LEAVES BEHIND IS NOT NOTHING, and that is deliberate: a
-- cancelled med kit keeps the health its partials already applied, and a
-- cancelled repair keeps the vehicle health its slices already granted. The item
-- comes back; the effect that was already delivered does not. See the note at
-- INV_USE for what that makes repeatable, and why it is written down rather than
-- closed.
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

            -- HOISTED ABOVE THE GUARDS THAT NOW READ IT. This used to be
            -- fetched below the damage branch, where the only thing that
            -- wanted it was the interpolation; the damage exemption and the
            -- vehicle guard both need it earlier.
            local c = BR.Config.ConsumableById[u.item]

            -- The slot must still hold the thing that was started. It was waived
            -- for a `spendOnPress` item for one day, because a press-time debit
            -- empties the slot and trips this on the very first pass; with the
            -- debit back at the completion there is nothing to waive and this
            -- guards every channel again.
            local s = inv.slots[u.slot]
            if not s or s.item ~= u.item then
                inv.using = nil
                BR.Inv.push(src)
                return
            end

            -- ═══ ...AND ONE CLASS OF CONSUMABLE IS NOT INTERRUPTED BY BEING
            --     SHOT (#228) ═══
            --
            --   "I couldn't find useCancelOnDamage as an available native.
            --    Let's not use that to stop any type of bullet damage."
            --                                          -- owner, 2026-09-03
            --
            -- POSITIVE OPT-IN ON THE ROW, so this reads as a property of the
            -- item rather than as an id test in a loop that must never learn
            -- one. The exemption is the repair kit's alone today and the
            -- argument is on its row: cancelling on damage is a rule about a
            -- player topping THEMSELVES up under fire, and the kit moves nothing
            -- on the ped -- the driver being shot is not the thing being
            -- repaired. server/ambheal.lua's heal is exempt for the same shape
            -- of reason and says so at length.
            --
            -- NOTE WHAT THIS REMOVES, AND IT IS NOT NOTHING. Damage-cancel is
            -- the backstop that keeps a partial effect from being worth
            -- repeating: it costs a player who re-presses under fire the rest of
            -- their channel. An `ignoresDamage` item has no such brake, and the
            -- ped partials do not need one -- they are TARGETS anchored on
            -- `u.hp0`, so re-pressing recomputes from the new baseline and gains
            -- exactly nothing. THE VEHICLE GRANT IS NOT A TARGET; it is a ledger
            -- of increments on a value this server cannot read, so a cancelled
            -- channel's slices are delivered and a fresh channel starts its
            -- ledger at zero. Press, cancel, press again and the car gains twice.
            -- That was previously argued away by the press-debit ("there is
            -- nothing to re-press"), and the press-debit is gone -- so the
            -- argument goes with it rather than being left standing as a claim
            -- that has quietly stopped being true. The exposure is bounded by
            -- what the owner asked for: he wants the health to climb WITH the
            -- bar, which requires granting before the item is spent. See INV_USE.
            if L.useCancelOnDamage and not (c and c.ignoresDamage)
                and (e.hp or 0) < (u.hp0 or 0) then
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
            -- losing that increment for good. THAT DISCIPLINE DOES NOT REACH
            -- THE VEHICLE GRANT BELOW -- client/fuel.lua's applyRepair is
            -- additive -- which is why that one keeps a ledger instead.

            -- ...AND THE SECOND ASK, WHICH IS THE ONE THAT ACTUALLY GUARDS IT.
            --
            -- "They can only use it while on foot" is a fact about the WHOLE
            -- use, not about the frame it started on. This is a three-second
            -- channel, so a player can press it standing in the road and be in
            -- the passenger seat of a mate's car well before it lands -- and the
            -- press-time refusal above sees none of that.
            --
            -- PLACED ABOVE THE PARTIALS AND ABOVE THE COMPLETION, so it runs on
            -- every pass INCLUDING the one where `now >= u.endsAt`. That is what
            -- makes it a guard rather than a courtesy: the item is consumed a
            -- few lines below this point, and there is no pass on which it can
            -- be spent without this test having just answered no.
            --
            -- CANCELLED, NOT COMPLETED-AND-DROPPED. cancelUse clears the channel
            -- and pushes the inventory back without touching the slot, and every
            -- consumable is debited by its COMPLETION -- the rule in the note
            -- above the loop -- so the car survives to be spawned on foot.
            --
            -- THE SAME SENTENCE AS THE PRESS. config/shop.lua's note: the two
            -- arms refuse for one reason and telling the player so in two
            -- different wordings would read as two rules.
            if c and c.shopCar and BR.Shop and BR.Shop.refusesUse then
                local refused, why = BR.Shop.refusesUse(src)
                if refused then
                    BR.Inv.cancelUse(src, why)
                    return
                end
            end

            -- ═══ THE DRIVING SEAT IS A FACT ABOUT THE WHOLE CHANNEL, AND THE
            --     REPAIR IS PAID IN SLICES (#228) ═══
            --
            --   "As that bar progresses, the vehicle health should
            --    incrementally increase to finally reach full once the item has
            --    been spent."                   -- owner, 2026-09-03
            --
            -- THE SHOP CAR'S SHAPE EXACTLY, one guard above: the press ruled on
            -- the seat, and five seconds is long enough to be blown out of it,
            -- to slide over into a passenger seat, or for the car to despawn. So
            -- the same question is asked every pass INCLUDING the completion,
            -- which is what makes it a guard rather than a courtesy.
            --
            -- COMPARED AGAINST `u.veh` RATHER THAN MERELY ANSWERED. One extra
            -- comparison, and it makes "the car you aimed it at" exact -- the
            -- same reasoning shared/protocol.lua gives for putting the netId on
            -- the wire at all.
            --
            -- ═══ AND THIS ARM NOW SPEAKS, FOR THE TWO CASES HE NAMED ═══
            --
            --   "if they switch seats before it is finished it should still
            --    apply, and same if they leave the vehicle mid-use."
            --                                          -- owner, 2026-09-04
            --
            -- "It" is the press-time sentence, USE_WHILE_DRIVING. It was silent
            -- here until he wrote that, and the cancel costs nothing either way
            -- -- the kit is still in the bag, because the completion is what
            -- spends it.
            --
            -- FOUR SITUATIONS REACH THIS BRANCH AND THE SENTENCE IS TRUE OF TWO.
            -- Left the vehicle, and slid into a passenger seat: both are "not
            -- driving", both are his. Still driving a car the platform will not
            -- network (the Battle Bus: `drivenNetId` answers nil for it), and
            -- driving a DIFFERENT car (`nid ~= u.veh`): in both of those the
            -- player is at a wheel, so "you can only use this while driving"
            -- would be a lie, and there is no agreed wording for either.
            --
            -- SO IT ASKS THE QUESTION THE SENTENCE IS ABOUT rather than reusing
            -- the answer that cancelled the channel. BR.Vehicles.drivingHandle
            -- is `drivenVehicle` exported -- seat -1 or nothing, the same read
            -- `drivenNetId` is built on -- so "is this player driving" still has
            -- ONE answer on this server, and it is the only one of the two that
            -- can separate a passenger from an un-networked driver. Gated on the
            -- module in the same shape as everything else here: a build without
            -- it still cancels, it just says nothing.
            --
            -- ═══ WHY A LEDGER AND NOT A DELTA ═══
            --
            -- The health/armour partials above are TARGETS -- the client applies
            -- them upward only, so a dropped one self-corrects. VEH_FIX is not
            -- like that: client/fuel.lua's applyRepair ADDS the points it is
            -- given (it is the pump's grant shape, and the pump's `r` means
            -- "points earned since the last message"). So the wire has to carry
            -- an INCREMENT, and the only way to make those increments add up to
            -- exactly one kit's worth across a jittering 250ms cadence is to
            -- keep the running total on the server and subtract it.
            --
            -- WHAT THE INCREMENT IS A FRACTION OF: BR.Config.Fuel.healthMax, so
            -- the kit and the petrol station cannot drift apart, and so that
            -- this file holds no opinion about vehicle health -- it has none to
            -- hold: every vehicle-health native is client-only, which is why
            -- this is a GRANT the client applies rather than a value the server
            -- sets. A lightly damaged car will therefore reach full, and pop its
            -- dents, before the bar finishes; that is the pump's behaviour too.
            if c and c.repairVeh then
                local nid = (BR.Vehicles and BR.Vehicles.drivenNetId)
                    and BR.Vehicles.drivenNetId(src) or nil
                if nid == nil or nid ~= u.veh then
                    -- THE MODULE'S ABSENCE IS NOT AN ANSWER OF "NOT DRIVING",
                    -- and writing this as one expression got that wrong: a build
                    -- with no `drivingHandle` would have told everybody the
                    -- sentence, including the drivers it is a lie to. Both
                    -- conditions have to be true for a word to be said.
                    local why = nil
                    if BR.Vehicles and BR.Vehicles.drivingHandle
                        and BR.Vehicles.drivingHandle(src) == nil then
                        why = USE_WHILE_DRIVING
                    end
                    BR.Inv.cancelUse(src, why)
                    return
                end

                if now < u.endsAt then
                    local cap = (BR.Config.Fuel
                        and tonumber(BR.Config.Fuel.healthMax)) or 1000.0
                    local total = math.max(1, u.ms or 1)
                    local pct  = BR.Clamp((total - (u.endsAt - now)) / total,
                                          0.0, 1.0)
                    local want = cap * pct
                    local give = want - (u.vehGranted or 0.0)
                    if give > 0.0 then
                        u.vehGranted = want
                        TriggerClientEvent(BR.Net.VEH_FIX, src,
                            { n = nid, r = give })
                    end
                end
            end

            -- ...AND ONLY FOR AN ITEM THAT MOVES SOMETHING ON THE PED.
            --
            -- PRE-EXISTING, FIXED IN PASSING (#228, 2026-09-03). The test was
            -- `if c and now < u.endsAt`, so a consumable with neither `health`
            -- nor `armour` -- the shop car, and now the repair kit -- sent an
            -- EMPTY `{ item, partial = true }` four times a second and stamped
            -- `healUntil` on every one of them. The client no-ops on the empty
            -- payload so nothing visible happened, but the stamp is a rolling
            -- amnesty window in server/roster.lua's health audit for a player
            -- who is not healing at all. Three seconds of that already shipped
            -- for the warmup shop; a 5s kit under fire would have extended it to
            -- where the audit matters.
            if c and (c.health or c.armour) and now < u.endsAt then
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
                -- THE SERVER JUST TOLD THIS PLAYER TO GET HEALTHIER, so the
                -- health audit in server/roster.lua must not read the rise as a
                -- client lying about its own ped. Stamped where the effect is
                -- ISSUED rather than where the use starts: these targets are
                -- what the client actually climbs toward, and a window anchored
                -- anywhere else would either open before there was anything to
                -- excuse or close while the ped was still on its way up.
                e.healUntil = now + ((BR.Config.Combat.healthAudit or {}).healSettleMs or 2000)
                TriggerClientEvent(BR.Net.INV_EFFECT, src, partial)
                return
            end

            if now < u.endsAt then return end

            -- ═══ LANDED. CONSUME ONE ═══
            --
            -- Unconditionally, for every consumable, which is the whole of the
            -- contract stated above the loop. `s` is safe to dereference here
            -- because the slot-identity guard at the top of the pass proved it
            -- still holds what was started -- there is no arm that skips that
            -- guard any more.
            --
            -- AND IT IS BELOW EVERY GUARD, WHICH IS THE PROPERTY WORTH KEEPING.
            -- The seat re-rule and the shop-car re-rule both run on this same
            -- pass and both return, so there is no pass on which an item can be
            -- spent for a use the rules had just refused.
            s.count = s.count - 1
            if s.count <= 0 then inv.slots[u.slot] = false end
            inv.using = nil

            -- ═══ A CAR IS A CONSUMABLE THAT DOES NOT HEAL ANYTHING (#224) ═══
            --
            -- The warmup shop's item is an ordinary consumable in every respect
            -- the inventory cares about -- it occupies a slot, it stacks to one,
            -- it drops, it is channelled by `useMs` and cancelled by damage --
            -- and its EFFECT is a vehicle rather than a number on the ped. So it
            -- branches here, at the one line where an effect is issued, and
            -- nowhere else in this file.
            --
            -- ONE `shopCar` FIELD IS THE WHOLE COUPLING. server/inventory.lua
            -- does not know what a catalogue is; it knows that a consumable
            -- carrying that field is spent by asking BR.Shop to build what it
            -- names. A server with no shop (BR.Shop absent) consumes the item
            -- and issues nothing, which is the same shape as every other guard
            -- in this file.
            --
            -- THE ITEM IS ALREADY GONE BY THIS LINE, and that is deliberate.
            -- Owner, 2026-08-29, answer 3: a purchase is never refunded, and
            -- that includes the known fault where a server-created vehicle
            -- vanishes. A use that put the item back on a failed spawn would be
            -- a use a player could repeat until the engine cooperated, which is
            -- a second car for one payment. BR.Shop.unpack logs every failure
            -- instead.
            if c and c.shopCar then
                if BR.Shop and BR.Shop.unpack then
                    BR.Shop.unpack(src, c.shopCar)
                else
                    print(('^1[br_core] inventory: %d used "%s" and there is no '
                           .. 'shop to build it^7'):format(src, tostring(u.item)))
                end
                BR.Inv.push(src)
                return
            end

            -- ═══ AND THE REPAIR FINISHES THE JOB -- WITH THE REMAINDER, NOT
            --     WITH ANOTHER WHOLE ONE (#228) ═══
            --
            --   "...to finally reach full once the item has been spent."
            --                                          -- owner, 2026-09-03
            --
            -- THE FIRST BUILD SENT THE FULL CAP HERE and called it a harmless
            -- backstop, on the grounds that applyRepair clamps. IT WAS NOT
            -- HARMLESS, AND THAT COMMENT WAS WRONG. The slices above already
            -- telescope to about 95% of the cap by the last in-channel pass, so
            -- one kit put ~1950 points on the wire instead of 1000 -- invisible
            -- on a car that took no damage, and worth nearly two full repairs on
            -- one that did, which is precisely the situation `ignoresDamage`
            -- exists for. The kit was priced at "the pump's repair in half the
            -- time" and was quietly worth twice the pump.
            --
            -- SO IT SENDS WHAT THE LEDGER SAYS IS OUTSTANDING. Slices plus this
            -- equal exactly one BR.Config.Fuel.healthMax, whatever the cadence
            -- did and whatever happened to the car in between -- one kit is one
            -- kit.
            --
            -- `f = true` IS THE COSMETIC PASS, AND IT IS WHY THIS MESSAGE IS
            -- SENT EVEN WHEN THE REMAINDER IS ZERO. client/fuel.lua pops the
            -- dents when the BODY reaches full, which a remainder cannot promise
            -- for a car that was being shot while it mended. The flag says "this
            -- is the last message of a kit" and the far end runs the cosmetic
            -- pass on it -- GTA has no partial deformation to animate, so the
            -- bodywork was always going to snap straight on one frame, and this
            -- is the frame the owner named: the one where the item is spent.
            --
            -- `u.veh` RATHER THAN A FRESH READ: the guard above ran on this same
            -- pass and proved the player is still driving exactly that car.
            if c and c.repairVeh then
                local cap = (BR.Config.Fuel
                    and tonumber(BR.Config.Fuel.healthMax)) or 1000.0
                TriggerClientEvent(BR.Net.VEH_FIX, src, {
                    n = u.veh,
                    r = math.max(0.0, cap - (u.vehGranted or 0.0)),
                    f = true,
                })
                BR.Inv.push(src)
                return
            end

            if c then
                -- ANCHORED ON WHERE THIS USE STARTED, exactly like the partials
                -- above -- and NOT on the roster's current reading.
                --
                -- This is the shield bug, and it double-counted its own ramp.
                -- The partials walk the player from armour0 to armour0 + 50 and
                -- the roster samples that rise at 2Hz, so by the time the use
                -- completed `e.armour` already read ~45. The final payload then
                -- computed 45 + 50 = 95, which is precisely the "one shield took
                -- me to ~95% from 0%" report (user, 2026-08-08).
                --
                -- Every message in a use is a TARGET measured from the same
                -- origin. That is what makes a dropped partial harmless, and it
                -- is only true if the last one uses the same origin as the rest.
                local payload = { item = u.item }
                if c.armour then
                    payload.armour    = math.min(c.armourCap,
                        (u.armour0 or 0) + c.armour)
                    payload.armourCap = c.armourCap
                end
                if c.health then
                    payload.health    = math.min(c.healthCap,
                        (u.hp0 or 0) + c.health)
                    payload.healthCap = c.healthCap
                end
                -- The same stamp as the partials above, and the landing one
                -- matters most: this is the payload that carries the FULL
                -- target, so it is the largest single rise the ped will make.
                e.healUntil = now + ((BR.Config.Combat.healthAudit or {}).healSettleMs or 2000)
                TriggerClientEvent(BR.Net.INV_EFFECT, src, payload)
            end

            BR.Inv.push(src)
        end)
end)
