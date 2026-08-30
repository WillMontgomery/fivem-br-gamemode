-- The warmup vehicle shop, server side (#224).
--
-- Four things happen here and nothing else does:
--
--   1. THE CATALOGUE IS RESOLVED ONCE, at resource start, against
--      config/vehicles.lua's refused list. A row naming a banned model is
--      thrown out with a line on the console rather than sold and then
--      undeliverable.
--   2. A PURCHASE IS ARBITRATED. The client names a catalogue id; every other
--      term -- the price, the balance, the state, the one-per-match count -- is
--      resolved on this side. server/market.lua's rule, applied to a second
--      storefront: "a storefront that trusts the client for a price is a
--      storefront that sells everything for zero the first time somebody looks
--      at it."
--   3. THE ITEM IS DELIVERED WHEN THE MATCH STARTS, from match.onEnter(BUS),
--      immediately after the warmup inventory wipe.
--   4. THE CAR IS BUILT when the item is used, through BR.Vehicles.spawnOwned
--      and nowhere else.
--
-- ═══ WHAT THIS FILE DELIBERATELY DOES NOT DO ═══
--
-- IT NEVER TOUCHES A VEHICLE'S APPEARANCE. Every colour, mod, extra and plate
-- lives in config/shop.lua and is applied on a CLIENT, by one function, to both
-- the showroom car and the delivered car (BR.Shop.dress, client/shop.lua). The
-- server's whole contribution to "exactly as shown" is that it sends an ITEM ID
-- and never a description -- there is no appearance on this side to get wrong,
-- to truncate over the wire, or to let drift.
--
-- IT NEVER REFUNDS AND NEVER RETRIES. Owner, 2026-08-29, answer 3: "Purchases
-- cannot be refunded" is literal, and it covers citizenfx/fivem#2623 -- the OPEN
-- bug where a vehicle from CreateVehicleServerSetter is randomly deleted. What
-- this file does instead is SAY WHAT HAPPENED at every step, so a car that was
-- never created can be told apart from one that was created and vanished. That
-- distinction cost the ambulance two playtest rounds when it was missing.

BR = BR or {}
BR.Shop = BR.Shop or {}

local S = BR.Config.Shop

--- The usable catalogue, resolved at start. Empty until `resolve` runs, and
--- empty forever if the owner has not authored any rows -- which is the shipped
--- state and is a shop that simply does not exist.
local rows = {}

--- Build the catalogue and register every row as an inventory item.
---
--- SAID OUT LOUD, ALWAYS. A shop with no rows is the shipped state and prints
--- one line saying so; a shop that threw rows away prints each one and why.
--- Both matter: the first tells the owner the feature is waiting on his data,
--- the second tells him a car he authored is not on the pad and is not a bug in
--- the coordinates.
local function resolve()
    local rejects
    rows, rejects = BR.Config.Shop.register(BR.Config.Shop.refusedReason)

    if #rejects > 0 then
        for _, r in ipairs(rejects) do
            print(('^3[br_core] shop: row "%s" is not for sale -- %s^7')
                :format(r.id, r.why))
        end
    end

    if #rows == 0 then
        print('[br_core] shop: no catalogue -- the warmup shop is inert')
        return
    end

    -- ═══ THIS WARNING NO LONGER MEANS "A PRESS BETWEEN THEM IS A COIN FLIP" ═══
    --
    -- It used to compare spacing against `reachM`, and against the owner's
    -- surveyed pad it fired on TEN PAIRS at every boot -- the showroom's whole
    -- point is that the cars stand close together. A warning that is true of
    -- almost every row is a warning nobody reads, and it would have buried the
    -- one row that ever genuinely needed reporting.
    --
    -- Two cars inside one reach radius is now the DESIGNED case, not a fault:
    -- BR.ShopSolve.nearest resolves the plate and the purchase to the nearer of
    -- them, deterministically, so the press is not a coin flip and reach is not
    -- the quantity to measure against. See that function's header for why no
    -- radius could have done this job at 3.25m spacing.
    --
    -- WHAT IS LEFT TO WARN ABOUT IS PHYSICAL. Below `minSpacingM` two cars are
    -- not close, they are INTERSECTING -- there is no room for both sets of
    -- bodywork, let alone for a player to stand between them and read a plate --
    -- and that is a fact about the coordinates that no amount of nearest-wins
    -- can fix. Reported rather than corrected: the coordinates are his.
    local spacing = tonumber(S.minSpacingM) or 0.0
    if spacing > 0.0 then
        for i = 1, #rows do
            for j = i + 1, #rows do
                local a, b = rows[i], rows[j]
                local d = BR.Dist(a.x, a.y, b.x, b.y)
                if d < spacing then
                    print(('^3[br_core] shop: "%s" and "%s" are %.2fm apart '
                           .. '-- closer than %.2fm is two cars standing in one '
                           .. 'another, with nowhere to stand between them^7')
                        :format(tostring(a.id), tostring(b.id), d, spacing))
                end
            end
        end
    end

    print(('[br_core] shop: %d for sale -- %s')
        :format(#rows, (function()
            local parts = {}
            for _, r in ipairs(rows) do
                parts[#parts + 1] = ('%s %d'):format(
                    BR.ShopSolve.nameOf(r), tonumber(r.price) or 0)
            end
            return table.concat(parts, ', ')
        end)()))
end

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then resolve() end
end)

--- The catalogue, for anything that needs to look a row up.
--- @return table
function BR.Shop.rows() return rows end

-- ---------------------------------------------------------------------------
-- Buying
-- ---------------------------------------------------------------------------

--- What this player bought in THIS match, or nil.
---
--- KEYED ON THE MATCH ID RATHER THAN CLEARED BY A HOOK. A purchase is a fact
--- about one match; stamping the match on it means a new match is a clean slate
--- with no teardown to remember and no state to leak between rounds. The same
--- shape roster entries already use for `matchId`.
--- @param src integer
--- @param m table|nil
--- @return table|nil
local function purchaseOf(src, m)
    local e = BR.Roster.get(src)
    if not e or not e.shopBuy or not m then return nil end
    if e.shopBuy.matchId ~= m.id then return nil end
    return e.shopBuy
end

RegisterNetEvent('br:shop:buy')
AddEventHandler('br:shop:buy', function(d)
    local src = source
    local id  = tostring(type(d) == 'table' and d.id or '')

    local m = BR.Server.matchOf(src)
    local e = BR.Roster.get(src)
    if not m or not e then return end

    local row = BR.ShopSolve.rowById(rows, id)
    local prior = purchaseOf(src, m)

    -- THE WHOLE CONDITION IN ONE CALL, and the same call tools/test_shop.lua
    -- exercises. Nothing is re-decided below it.
    local ok, why = BR.ShopSolve.canBuy({
        on          = BR.ShopSolve.enabled(S),
        matchState  = m.state,
        playerState = e.state,
        row         = row,
        bought      = prior and 1 or 0,
        limit       = tonumber(S.limit) or 1,
        -- THE BALANCE IS THE MARKET'S, ASKED FOR RATHER THAN CACHED HERE. One
        -- ledger, one reader; a second copy of a balance is a second thing that
        -- can be wrong about how much money somebody has.
        balance     = BR.Market and BR.Market.balanceOf(src) or 0,
        price       = row and row.price or 0,
    })

    if not ok then
        -- SILENT TO THE PLAYER EXCEPT WHERE THE MARKET ALREADY HAS A SENTENCE.
        -- The owner gave three strings for this feature and none of them is a
        -- refusal; inventing one would be exactly the unrequested copy his
        -- standing rule refuses. `afford` is the one case with an existing
        -- sentence, and BR.Market.charge speaks it below, in the market's own
        -- words, because the market owns that wording already.
        if why == BR.ShopSolve.Refusal.AFFORD and BR.Market then
            BR.Market.tellShortfall(src, row and row.price or 0)
        end
        print(('[br_core] shop: %d refused "%s" -- %s'):format(src, id, tostring(why)))
        return
    end

    -- ═══ THE CHARGE IS THE POINT OF NO RETURN, AND IT IS TAKEN FIRST ═══
    --
    -- Everything above this line is a refusal that costs nothing. Everything
    -- below it has been paid for. server/rescue.lua orders itself the same way
    -- and for the same reason -- "every refusal in this function returns before
    -- the kit is spent" -- and here it matters more, because there is no refund
    -- path to fall back on by instruction.
    local paid, why2 = BR.Market.charge(src, row.price, 'shop:' .. row.id)
    if not paid then
        print(('[br_core] shop: %d could not be charged for "%s" -- %s')
            :format(src, row.id, tostring(why2)))
        return
    end

    e.shopBuy = { matchId = m.id, row = row.id, paid = row.price, delivered = false }

    -- THE OWNER'S SENTENCE, VERBATIM, AND THE ONLY ONE THIS PATH SPEAKS.
    BR.Server.notify(src, S.boughtToast, 'success')
    -- ...and the pickup cue, which the CLIENT plays because a frontend sound is
    -- a client thing. The existing one: see config/shop.lua on why there is no
    -- new cue.
    TriggerClientEvent('br:shop:bought', src, { row = row.id })

    print(('[br_core] shop: %d bought "%s" for %d Volts')
        :format(src, row.id, row.price))
end)

-- ---------------------------------------------------------------------------
-- Delivery
-- ---------------------------------------------------------------------------

--- Hand out every car bought during this match's warmup.
---
--- ═══ CALLED FROM match.onEnter(BUS), IMMEDIATELY AFTER BR.Inv.clearFor(m),
---     AND THE ORDER IS THE WHOLE OF IT ═══
---
--- "THE PAD'S LOOT DOES NOT FLY" -- everything found during warmup is wiped at
--- wheels-up, so a car handed out one line earlier would be wiped by the very
--- next statement and the purchase would vanish with it. One line later and the
--- bag is empty, which is also what makes the owner's answer 4 unreachable in
--- practice: there is no way for the inventory to be full at the moment this
--- runs. The full-bag path below is still written, because "unreachable today"
--- and "cannot happen" are different claims and only the first one is true.
---
--- "It will be available in your inventory once the match starts" is the promise
--- the toast made, and BUS is when the match starts -- the bus is in the air,
--- warmup is over, and the item is in the bag before anybody jumps.
--- @param m table
function BR.Shop.deliver(m)
    if not m then return end

    BR.Roster.each(
        function(e) return e.matchId == m.id and e.shopBuy ~= nil end,
        function(src, e)
            local buy = e.shopBuy
            if buy.matchId ~= m.id or buy.delivered then return end

            local row = BR.ShopSolve.rowById(rows, buy.row)
            if not row then
                -- A ROW THAT WAS SOLD AND HAS SINCE STOPPED EXISTING. Only
                -- reachable across a br_lib reload mid-match. Answer 3 applies:
                -- nothing is refunded, and the console says so rather than the
                -- player silently getting nothing.
                print(('^3[br_core] shop: %d paid for "%s" and it is no longer '
                       .. 'in the catalogue -- nothing delivered^7')
                    :format(src, tostring(buy.row)))
                buy.delivered = true
                return
            end

            local itemId = BR.ShopSolve.itemIdFor(row)
            local stack = {
                item   = itemId,
                kind   = BR.ItemKind.CONSUMABLE,
                rarity = BR.Rarity.LEGENDARY,
                count  = 1,
            }

            -- ═══ SILENTLY, BECAUSE THIS IS A DELIVERY AND NOT A PICKUP ═══
            --
            -- Owner, 2026-08-29: "when transitioning to state BUS, the pickup
            -- sound is heard again by anyone who has purchased an item."
            --
            -- Everything that lands in an inventory plays GTA's PICK_UP
            -- (client/inventory.lua), which is right for something you just
            -- walked over and wrong for a car you paid for during warmup and
            -- that the match hands you at wheels-up. The player is standing in
            -- a plane; nothing is visibly arriving; the sound has no referent.
            --
            -- THE PURCHASE ALREADY MADE THE NOISE. `br:shop:bought` plays the
            -- same cue at the moment the Volts leave the balance, which is when
            -- something actually happened, and the toast already promised this
            -- delivery in the owner's own words -- "it will be available in your
            -- inventory once the match starts". A second cue here is the same
            -- event announced twice, minutes apart, the second time with no
            -- cause the player can see.
            local ok, displaced, reason = BR.Inv.give(src, stack, { quiet = true })
            buy.delivered = true

            if ok then
                -- ANSWER 4: an ordinary item in every way, including the part
                -- where something it pushed out lands on the floor.
                if displaced then BR.Loot.dropForPlayer(src, displaced) end
                print(('[br_core] shop: %d received "%s"'):format(src, itemId))
            else
                -- ...AND IF IT WOULD NOT FIT AT ALL, IT GOES ON THE GROUND AT
                -- THEIR FEET rather than evaporating. Owner, answer 4.
                BR.Loot.dropForPlayer(src, stack)
                print(('[br_core] shop: %d had no room for "%s" (%s) -- dropped '
                       .. 'at their feet'):format(src, itemId, tostring(reason)))
            end
        end)
end

-- ---------------------------------------------------------------------------
-- Unpacking
-- ---------------------------------------------------------------------------

--- Put the car a player paid for on the ground in front of them.
---
--- CALLED BY server/inventory.lua's use pass, AFTER the item has been consumed.
--- That ordering is deliberate and it is the opposite of the ambulance's:
--- server/rescue.lua creates first and spends the kit after, because a rescue
--- that cannot be started must not cost the rarest item in the game. This item
--- IS the car, the owner has ruled that a failure costs the purchase, and a use
--- that consumed nothing would be a use a player could repeat until the engine
--- cooperated -- which is a second car off one payment.
---
--- SO A FAILURE HERE IS FINAL, AND IS THEREFORE LOUD. Three separate things can
--- go wrong -- the row, the creation, the clone -- and the console names which.
--- @param src integer
--- @param rowId string|nil   the `shopCar` field off the consumable
--- @return boolean
function BR.Shop.unpack(src, rowId)
    local row = BR.ShopSolve.rowById(rows, rowId)
    if not row then
        print(('^1[br_core] shop: %d used a car item for "%s", which is not in '
               .. 'the catalogue -- nothing spawned^7')
            :format(src, tostring(rowId)))
        return false
    end

    local e = BR.Roster.get(src)
    if not e then return false end

    local ped = GetPlayerPed(src)
    if not ped or ped == 0 then
        print(('^1[br_core] shop: %d has no ped -- "%s" not spawned^7')
            :format(src, row.id))
        return false
    end

    local okPos, p = pcall(GetEntityCoords, ped)
    if not okPos or not p then
        print(('^1[br_core] shop: %d position unreadable -- "%s" not spawned^7')
            :format(src, row.id))
        return false
    end

    -- IN FRONT, NOT UNDERNEATH. brcar's SPAWN_AHEAD_M note: a vehicle created
    -- at a ped's own coordinates leaves the engine to resolve the intersection,
    -- and it resolves it by throwing one of the two.
    --
    -- FACING THE SAME WAY THE PLAYER IS, unlike brcar -- which turns the car
    -- 90 degrees so a door faces you. The owner wants to be IN this one, so it
    -- is pointed where he is looking and the client seats him.
    local okHdg, hdg = pcall(GetEntityHeading, ped)
    local heading = (okHdg and tonumber(hdg)) or 0.0
    local rad = math.rad(heading)
    local ahead = tonumber(S.spawnAheadM) or 5.0
    local x = p.x - math.sin(rad) * ahead
    local y = p.y + math.cos(rad) * ahead

    -- ═══ THE ONE CREATION PATH THERE IS ═══
    --
    -- BR.Vehicles.spawnOwned, in server/vehicles.lua, beside the allowlist --
    -- tools/verify.sh refuses server-side vehicle creation anywhere else, and
    -- the reason is written there: CreateVehicleServerSetter raises
    -- `serverEntityCreated` and NOT `entityCreating`, so the refused-model
    -- pre-check inside that function is the entire boundary. It also puts the
    -- entity in this player's routing bucket, which matches run in and which
    -- the setter defaults wrongly to 0.
    local veh, netId, whyVeh = BR.Vehicles.spawnOwned(
        row.model, row.vtype or 'automobile', x, y, p.z, heading, src)

    if not veh then
        print(('^1[br_core] shop: %d unpacked "%s" and the engine refused it '
               .. '(%s) -- the item is spent and there is no refund^7')
            :format(src, row.id, tostring(whyVeh)))
        return false
    end

    -- NO SetEntityDistanceCullingRadius. See config/shop.lua: this car is five
    -- metres from the only client that has to see it, which is well inside the
    -- 424-unit default -- and the native is deprecated with a known fault
    -- (citizenfx/fivem#1828) that a widened radius is what triggers.

    print(('[br_core] shop: %d unpacked "%s" -- netId %s at %.1f %.1f %.1f')
        :format(src, row.id, tostring(netId), x, y, p.z))

    -- THE CLIENT DRESSES IT, AND THAT IS WHERE "EXACTLY AS SHOWN" IS KEPT.
    -- What crosses the wire is a net id and a CATALOGUE ID -- never an
    -- appearance. The buyer's client already holds config/shop.lua, so it
    -- rebuilds the car from the same row the showroom car was built from, by
    -- the same function. There is nothing here that could describe the car
    -- differently from the way it was described in warmup.
    TriggerClientEvent('br:shop:dress', src, { n = netId, row = row.id })
    return true
end
