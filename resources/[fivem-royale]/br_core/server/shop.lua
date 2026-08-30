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

--- src -> true while a debit for that player is waiting on DynamoDB.
---
--- THE ONLY STATE THIS FILE KEEPS BETWEEN TWO EVENTS, and it is bounded by the
--- request timeout inside BR.Market.charge: the callback always runs, so an
--- entry cannot outlive one round trip. Keyed by src rather than by license
--- because the press it refuses is a press from that connection.
local inflight = {}

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

--- ═══ WHAT A PLAYER HAS PAID FOR IN THE MATCH THEY ARE STANDING IN ═══
---
--- A LIST RATHER THAN ONE RECORD, since the owner's report of 2026-08-29. It was
--- `e.shopBuy`, one slot, and a second purchase overwrote the first -- a paid
--- car vanishing with nothing in any log. Two entries cost a table; the
--- alternative cost somebody a purchase, and the list is what lets a surplus be
--- SEEN and reported rather than silently replaced.
---
--- ═══ AND EVERY ENTRY BELONGS TO ONE MATCH, WITHOUT A STAMP TO SAY SO ═══
---
--- Entries used to carry `matchId`, with nil meaning OWED -- paid for, not yet
--- received, no longer tied to the match that sold it -- and BR.Shop.deliver
--- handed those over at the next wheels-up their owner attended. The owner
--- ended that on 2026-08-30: "It should not be persistent or carry over to
--- another round ever."
---
--- So there are exactly two ways out of this list and both are terminal:
--- BR.Shop.deliver empties it at wheels-up, and BR.Shop.release destroys it when
--- its owner leaves the match. Nothing survives either, which is what makes the
--- stamp unnecessary -- and it was removed rather than left to go stale, because
--- a field nothing reads is this project's signature defect.
--- @param e table  a roster entry
--- @return table
local function buysOf(e)
    e.shopBuys = e.shopBuys or {}
    return e.shopBuys
end

--- How many cars this player is holding against the ceiling.
---
--- ═══ THE OWNER'S RULING, 2026-08-30: "ONE CAR AT WHEELS-UP, EVER" ═══
---
--- "Confirmed the vehicle is dropped when leaving the WARMUP, nice. But now when
--- I bought one the next round, and landed after the bus, I have BOTH vehicles
--- in my inventory -- the one from the previous warmup and this warmup."
---
--- ═══ WHY THAT HAPPENED, AND WHY THE PREVIOUS FIX AIMED AT THE WRONG THING ═══
---
--- The bug before this one was "I bought a thing, left the match with it (and
--- still in warmup), then joined a new match and couldn't buy anything else".
--- The diagnosis was right -- readying up while a warmup of your mode is still
--- open re-enters the SAME instance with the SAME id (BR.Lobby.ready ->
--- BR.Party.lateJoin), so a purchase he had walked away from was still binding
--- him. The REMEDY was wrong: it made leaving a fresh allowance, so a player
--- could hold two paid-for cars at once and both arrived at the next wheels-up.
---
--- He was never short of a car. He was refused a SECOND one, which is the rule.
---
--- ═══ AND COUNTING UNDELIVERED PURCHASES *IS* COUNTING THIS MATCH'S ═══
---
--- This deliberately does not compare a match id, and since the owner's second
--- ruling (2026-08-30: "if you buy a car, then leave the match, you forfeit your
--- purchase") it does not need to. BR.Shop.release destroys every record when
--- its owner leaves, and BR.Shop.deliver clears the list at wheels-up, so a
--- purchase cannot outlive the match it was made in -- which makes "undelivered"
--- and "bought in the match I am standing in" the same set, reached without a
--- stamp to keep in step.
---
--- THE STAMP IS GONE ENTIRELY. `buy.matchId` was written at purchase and, once
--- the carry-over accounting it fed was removed, read by nothing -- dead
--- bookkeeping that would have gone stale in silence. The one thing it really
--- guarded, a charge that lands after its match, is now a GATE in the buy
--- handler rather than a field: a purchase that cannot belong to a live warmup
--- is refused a record and forfeited on the spot.
---
--- ═══ A SECOND PURCHASE IN THE SAME MATCH IS STILL REFUSED ═══
---
--- Which is the half of his complaint that has not changed. A player holding an
--- undelivered car cannot buy another, and the refusal is
--- BR.ShopSolve.Refusal.BOUGHT.
---
--- HE IS NOT TOLD, and that is deliberate rather than an omission. That refusal
--- has never produced a toast -- the standing rule on this project is that
--- unrequested copy is slop, and the second press is already answered by the
--- plate not disappearing.
--- @param src integer
--- @return integer
local function heldBy(src)
    local e = BR.Roster.get(src)
    if not e then return 0 end
    local n = 0
    for _, buy in ipairs(buysOf(e)) do
        if not buy.delivered then n = n + 1 end
    end
    return n
end

--- Destroy a player's purchases when they leave the match that sold them.
---
--- ═══ THE OWNER'S RULING, 2026-08-30: LEAVING FORFEITS ═══
---
--- "#238 if you buy a car, then leave the match, you forfeit your purchase. It
--- should not be persistent or carry over to another round ever."
---
--- THIS FUNCTION USED TO DO THE OPPOSITE and the reasoning was defensible: a
--- purchase is never refunded, so making it never delivered either reads like
--- taking the money twice. It unbound the record instead -- OWED -- and the next
--- wheels-up the player attended handed it over. He has decided against that. He
--- is content for the car to be lost, and he does not want purchases surviving a
--- round under any circumstances.
---
--- SO EVERYTHING GOES, delivered and undelivered alike. There is no state a
--- purchase can be in that outlives its owner's participation in the match.
---
--- ═══ FORFEIT ON LEAVING, NEVER FORFEIT WHILE STILL IN THE MATCH ═══
---
--- The failure this must not become is the one he reported first: a paid car
--- disappearing while he still had every right to it. The whole of the guard is
--- the CALL SITE -- BR.Match.leaveMatch and nothing else -- so walking off the
--- pad, driving to the other end of it, going AFK or being culled do not reach
--- this at all. Nothing in this file polls a position or a distance, and nothing
--- should ever be added that does.
---
--- ═══ IT IS LOUD, BECAUSE IT IS THE HARSHEST THING THE FEATURE DOES ═══
---
--- A player can lose 1500 Volts by stepping out of a warmup, and from inside the
--- game it is silent: no toast, no car, a balance that went down. If that turns
--- out to feel wrong in play, this line is the evidence -- one per forfeited
--- car, naming the car and what it cost.
--- @param src integer
function BR.Shop.release(src)
    local e = BR.Roster.get(src)
    if not e or not e.shopBuys then return end
    for _, buy in ipairs(e.shopBuys) do
        if not buy.delivered then
            print(('^3[br_core] shop: %d left the match holding an undelivered '
                   .. '"%s" (%d Volts) -- FORFEITED, no refund^7')
                :format(src, tostring(buy.row), tonumber(buy.paid) or 0))
        end
    end
    e.shopBuys = nil
end

RegisterNetEvent('br:shop:buy')
AddEventHandler('br:shop:buy', function(d)
    local src = source
    local id  = tostring(type(d) == 'table' and d.id or '')

    local m = BR.Server.matchOf(src)
    local e = BR.Roster.get(src)
    if not m or not e then return end

    local row = BR.ShopSolve.rowById(rows, id)

    -- ═══ A CHARGE IN FLIGHT COUNTS AS BOUGHT ═══
    --
    -- The debit is a DynamoDB round trip now, so two presses inside it would
    -- both find `boughtIn` at zero and both be allowed -- one allowance, two
    -- cars. BR.Market.charge reserves the Volts against the session cache, so
    -- the money cannot be spent twice either way; this is the SECOND press's
    -- refusal, and it is the one that says `alreadyone` rather than `afford`.
    --
    -- CLEARED BY THE ANSWER, WHICH ALWAYS ARRIVES: BR.Market.charge's request
    -- carries its own six-second timeout, so a bridge that never replies costs
    -- one refused press and not the rest of the warmup.
    local ok, why = BR.ShopSolve.canBuy({
        on          = BR.ShopSolve.enabled(S),
        matchState  = m.state,
        playerState = e.state,
        row         = row,
        bought      = heldBy(src) + (inflight[src] and 1 or 0),
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

    -- ═══ THE CHARGE IS THE POINT OF NO RETURN, AND NOTHING EXISTS BEFORE IT
    --     LANDS ═══
    --
    -- Everything above this line is a refusal that costs nothing. Everything
    -- inside the callback has been paid for -- and "paid for" now means DynamoDB
    -- accepted a conditional debit against the real row, not that a number in
    -- this process moved. server/rescue.lua orders itself the same way and for
    -- the same reason ("every refusal in this function returns before the kit is
    -- spent"), and here it matters more, because there is no refund path to fall
    -- back on by instruction.
    --
    -- THE RECORD IS WRITTEN IN THE CALLBACK, NOT BEFORE IT. A record written
    -- optimistically and rolled back on a refusal is a car that briefly existed;
    -- the ordering below means it never does.
    inflight[src] = true
    BR.Market.charge(src, row.price, 'shop:' .. row.id, function(paid, why2, left)
        inflight[src] = nil

        if not paid then
            -- SILENT TO THE PLAYER, except where BR.Market.charge has already
            -- spoken the market's own shortfall sentence. Same rule as the
            -- refusals above: the owner gave three strings for this feature and
            -- none of them is a refusal.
            print(('[br_core] shop: %d could not be charged for "%s" -- %s')
                :format(src, row.id, tostring(why2)))
            return
        end

        -- ═══ THE MATCH IS RE-READ, AND IT IS NOW A GATE RATHER THAN A STAMP
        --     ═══
        --
        -- A DynamoDB round trip is up to six seconds and a player can walk out
        -- of the match inside it. That used to be handled by stamping the record
        -- with `matchId = nil` -- the OWED state -- and delivering it at the
        -- next wheels-up they attended. The owner has forbidden that
        -- (2026-08-30): a purchase must never carry over to another round.
        --
        -- SO A PURCHASE THAT LANDS AFTER ITS MATCH IS FORFEITED HERE, and the
        -- alternative is the exact bug he ruled against: BR.Shop.release has
        -- already run for this player, so a record written now would survive
        -- into whatever match they join next and be handed over there. This is
        -- the one path by which "leaving forfeits" could be true everywhere else
        -- and still leak a car across rounds.
        --
        -- WARMUP SPECIFICALLY, not merely "still in a match". Past warmup the
        -- delivery for this match has already run or is running, so a record
        -- written now is one nothing will ever hand over -- the same forfeit,
        -- reached by a different door.
        --
        -- IT COSTS THE PLAYER THE VOLTS AND IT SAYS SO. Loudly, with the price,
        -- because this is the harshest thing the feature does and it is
        -- invisible from the game: the toast never appears, the car never
        -- arrives, and the balance simply went down.
        local now = BR.Server.matchOf(src)
        if not now or now.state ~= BR.MatchState.WARMUP
           or e.state ~= BR.PlayerState.WARMUP then
            print(('^3[br_core] shop: %d was charged %d Volts for "%s" and left '
                   .. 'the warmup before the write landed -- FORFEITED, no car '
                   .. 'and no refund^7'):format(src, row.price, row.id))
            return
        end

        local buys = buysOf(e)
        buys[#buys + 1] = {
            row       = row.id,
            paid      = row.price,
            delivered = false,
        }

        -- ═══ THE OWNER'S TWO SENTENCES, VERBATIM, AND THE ONLY ONES THIS PATH
        --     SPEAKS ═══
        --
        -- #239: "'Thank you for your purchase.' toast should also include a
        -- note about their new balance, stated as 'Your new balance is: [X]
        -- Volts.'" Both strings are authored in config/shop.lua and joined by
        -- BR.ShopSolve.boughtToast, which is where a test can run the joining.
        --
        -- `left` IS THE ROW'S OWN FIGURE AND NOT ARITHMETIC. It comes out of
        -- BR.Market.charge, which took it from `br:ddb:spend`'s UPDATED_NEW
        -- answer -- so the toast quotes what DynamoDB holds after the write, and
        -- it is the same number BR.Market.push has just sent the Store screen.
        -- `row.price` subtracted from a cached balance here would be a second
        -- computation of one fact, free to disagree with the screen the player
        -- can open in the next breath, and the exact staleness the debit was
        -- moved into DynamoDB to end.
        BR.Server.notify(src, BR.ShopSolve.boughtToast(
            S, left, BR.Config.Market and BR.Config.Market.currency), 'success')
        -- ...and the pickup cue, which the CLIENT plays because a frontend sound
        -- is a client thing. The existing one: see config/shop.lua on why there
        -- is no new cue.
        TriggerClientEvent('br:shop:bought', src, { row = row.id })

        print(('[br_core] shop: %d bought "%s" for %d Volts')
            :format(src, row.id, row.price))
    end)
end)

-- ---------------------------------------------------------------------------
-- Delivery
-- ---------------------------------------------------------------------------

--- Hand ONE paid-for car to its buyer, whichever match it was bought in.
--- @param src integer
--- @param buy table
local function deliverOne(src, buy)
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
end

--- Hand out ONE car to each of this match's players who is owed any.
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
        function(e) return e.matchId == m.id and e.shopBuys ~= nil end,
        function(src, e)
            -- ═══ WHAT THEY HAVE PAID FOR AND NOT RECEIVED ═══
            --
            -- Bound to THIS match, or OWED from an earlier one they walked out
            -- of before its wheels-up (BR.Shop.release). Delivering only the
            -- bound ones would mean a car somebody paid for could never arrive
            -- at all, which is a worse reading of "purchases cannot be refunded"
            -- than the owner can possibly have meant.
            --
            -- ═══ ONE CAR AT WHEELS-UP, AND NOTHING SURVIVES IT ═══
            --
            -- He landed after the bus holding a car from the previous warmup
            -- and a car from this one, because this loop handed over everything
            -- owed. Two rulings answer that now and they compose: `heldBy`
            -- refuses a second purchase while one is undelivered, and
            -- BR.Shop.release destroys the lot when its owner leaves -- so at
            -- this point the list holds at most one entry.
            --
            -- THE LIMIT IS KEPT ANYWAY, because "unreachable today" and "cannot
            -- happen" are different claims and only the first one is true. It is
            -- the guard on the exact thing he reported.
            --
            -- AND A SURPLUS IS DESTROYED RATHER THAN CARRIED. It used to WAIT
            -- for the next wheels-up, which was the kinder reading and is the
            -- one the owner overruled: "It should not be persistent or carry
            -- over to another round ever." So the list is emptied whatever
            -- happened to it, and anything that did not fit says so with the
            -- price attached.
            local limit = tonumber(S.limit) or 1
            local given = 0
            for _, buy in ipairs(buysOf(e)) do
                if not buy.delivered and given < limit then
                    deliverOne(src, buy)
                    given = given + 1
                elseif not buy.delivered then
                    print(('^3[br_core] shop: %d had a second undelivered "%s" '
                           .. '(%d Volts) at wheels-up -- FORFEITED, one car per '
                           .. 'match and nothing carries over^7')
                        :format(src, tostring(buy.row), tonumber(buy.paid) or 0))
                end
            end
            -- NOTHING SURVIVES A WHEELS-UP EITHER. A delivered entry's only
            -- remaining job was to say "already bought this match" and warmup is
            -- over; an undelivered one has just been forfeited above.
            e.shopBuys = nil
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
