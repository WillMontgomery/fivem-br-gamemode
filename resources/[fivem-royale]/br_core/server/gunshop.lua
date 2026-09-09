-- The in-match Ammu-Nation counter, server side (#274): who may buy, what it
-- costs, and what lands in the bag.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE CLIENT ASKS AND NEVER DECIDES
-- ═══════════════════════════════════════════════════════════════════════════
--
-- One event arrives here and it carries a catalogue id and nothing else. No
-- price, no balance, no claim about where the player is standing or what state
-- they are in. Every one of those is resolved below, against config the server
-- holds and a position the server sampled -- which is BR.GunshopSolve.canBuy's
-- stated rule, server/shop.lua's rule for the warmup showroom, and
-- server/market.lua's rule for the storefront before either of them.
--
-- The one that matters most here is the POSITION. A client that could assert "I
-- am at a counter" could shop from the top of Mount Chiliad, so `atCounter`
-- below is resolved from BR.Roster's own sampled coordinates and the client's
-- word is never asked for.
--
-- ═══ THE ORDER IS THE WHOLE FILE, AND IT IS server/shop.lua's ═══
--
-- Resolve the row, evaluate ONE pure predicate, charge, and do every piece of
-- bookkeeping inside the callback. Everything above the charge is a refusal that
-- costs nothing; everything inside it has been paid for, and "paid for" means
-- DynamoDB accepted a conditional debit against the real row rather than that a
-- number in this process moved.
--
-- ═══ AND THE THINGS THE SHOWROOM HAS THAT THIS DOES NOT ═══
--
-- No purchase limit, and BR.GunshopSolve.canBuy's header says why in as many
-- words: "no more than 1 vehicle during warmup" was an answer about cars, and a
-- shop that sells one magazine of ammo per match is not a convenience. So there
-- is no `inflight` table here either -- the showroom keeps one so that two
-- presses inside a round trip cannot both read `bought` as zero, and with no cap
-- to defend there is nothing for it to defend. BR.Market.charge reserves the
-- Volts against the session cache the moment it is called, so a second press
-- during the first one's round trip is refused by the money if the money has run
-- out and is a second legitimate purchase if it has not.
--
-- No deferred delivery, no forfeit-on-leaving, and no unpacking. A counter
-- purchase lands in the bag on the SAME callback that debited it, so there is no
-- gap for a match to end inside and nothing to hand over at wheels-up.
--
-- No new item ids. `row.stack` is byte for byte what BR.RollLootStack hands back
-- for the same weapon or the same ammo pool, so the thing given over the counter
-- is the thing the ground would have given -- which is the owner's rule for this
-- feature made literal rather than promised.

BR = BR or {}
BR.Gunshop = BR.Gunshop or {}

local G = BR.Config.Gunshop

--- The usable catalogue, and the usable counters. Both empty until `resolve`
--- runs at resource start, and both legitimately empty forever on a build whose
--- config has been emptied -- which is a feature that does not exist rather than
--- one that is broken (BR.GunshopSolve.enabled).
local rows   = {}
local stores = {}

--- BUILD THE CATALOGUE AND THE COUNTER LIST, AND SAY WHAT WAS THROWN OUT.
---
--- ═══ THIS IS ONE OF THE TWO CALL SITES OF BR.Config.Gunshop.build(), AND
---     UNTIL THIS FILE EXISTED THERE WERE NONE ═══
---
--- The data layer shipped alone and deliberately: config/gunshop.lua's own
--- header explains that a catalogue derived at the config's LOAD would come out
--- empty, because br_lib's fxmanifest expands `config/*.lua` as a glob and
--- `gunshop` sorts before `weapons`. So it is a function, called at a resource
--- start by which time every br_lib script has run whatever order it ran in --
--- the same shape, for the same reason, as config/shop.lua's `register`.
---
--- IT IS IDEMPOTENT, so this file and client/gunshop.lua each call it
--- unconditionally and neither has to know whether the other went first. Two
--- callers, one build, one set of console lines.
---
--- THE REJECTS ARE PRINTED BY build() ITSELF, so nothing here repeats them. What
--- is left for this function is the two things build() cannot know: whether any
--- COUNTER survived validation, and what the shop is actually selling.
local function resolve()
    rows = select(1, BR.Config.Gunshop.build())

    local rejects
    stores, rejects = BR.GunshopSolve.stores(G)
    for _, r in ipairs(rejects) do
        -- SAID OUT LOUD, ALWAYS. server/shop.lua's rule: a row that was silently
        -- dropped is a store the owner surveyed, cannot find in game, and has no
        -- way to ask about.
        print(('^3[br_core] gunshop: counter "%s" is unusable -- %s^7')
            :format(tostring(r.id), tostring(r.why)))
    end

    if not BR.GunshopSolve.enabled(G) then
        print('[br_core] gunshop: no counters -- the gun shops are inert')
        return
    end
    if #rows == 0 then
        -- REACHABLE ONLY THROUGH THE WEAPON TABLE, which is why it says so.
        -- The catalogue is derived, so an empty one is not a gun shop problem:
        -- it means BR.Config.Weapons holds nothing at RARE or above, which is a
        -- gamemode with no good guns in it.
        print('[br_core] gunshop: eleven counters and nothing to sell -- '
              .. 'no weapon is at RARE or above')
        return
    end

    local guns = #BR.GunshopSolve.ofKind(rows, BR.ItemKind.WEAPON)
    local ammo = #BR.GunshopSolve.ofKind(rows, BR.ItemKind.AMMO)
    print(('[br_core] gunshop: %d counters, %d for sale (%d weapons, %d ammo), '
           .. 'reach %.1fm client / %.1fm here')
        :format(#stores, #rows, guns, ammo,
                tonumber(G.reachM) or 0.0, tonumber(G.serverReachM) or 0.0))
end

AddEventHandler('onResourceStart', function(name)
    if name == GetCurrentResourceName() then resolve() end
end)

--- The catalogue, for anything that needs to look a row up.
--- @return table
function BR.Gunshop.rows() return rows end

--- WHICH COUNTER IS THIS PLAYER AT, AS THE SERVER SEES IT?
---
--- ═══ THE ROSTER'S SAMPLED POSITION, NOT A FRESH GetPlayerPed ═══
---
--- server/shop.lua's BR.Shop.refusesUse carries the write-up and it is worth
--- repeating because the failure is invisible: GET_PLAYER_PED is declared as
--- `Entity GET_PLAYER_PED(char* playerSrc)` and playerSrc is documented as a
--- STRING. Passing the numeric roster key returns 0 for every player -- which
--- here would mean no player is ever at a counter, every purchase is refused,
--- and every test that stubs the native passes.
---
--- `entry.pos` IS THAT SAMPLE TAKEN THROUGH THE KNOWN-GOOD SPELLING, once per
--- roster pass, and it is what the storm, the health audit and the roadkill
--- detector all rule on. One answer to "where is this player" on this server.
---
--- IT IS UP TO 250ms OLD AND THE RADIUS IS SIZED FOR THAT. See the note beside
--- `serverReachM` in config/gunshop.lua: the sampler runs at 4 Hz, a sprint
--- covers about 1.8m in that time, and refusing somebody standing at the counter
--- because their last sample was taken on the way in is the worst refusal there
--- is -- it has no symptom the player can see.
---
--- NO `present` FILTER IS PASSED, and that is deliberate rather than an
--- omission. The fifth parameter of BR.GunshopSolve.nearest exists so a CLIENT
--- can skip a counter whose clerk failed to stream on that machine. The server
--- has no clerk and never had one; refusing a purchase over a ped that did not
--- load somewhere would be the server ruling on something it cannot see.
--- @param src integer
--- @return table|nil store
local function atCounter(src)
    local e = BR.Roster.get(src)
    local p = e and e.pos
    if type(p) ~= 'table' then return nil end
    return BR.GunshopSolve.nearest(stores, p.x, p.y,
                                   tonumber(G.serverReachM) or 0.0)
end

--- Hand one paid-for row over, and put anywhere it will not fit on the floor.
---
--- ═══ IT IS AN ORDINARY PICKUP IN EVERY WAY EXCEPT THE NOISE ═══
---
--- `row.stack` is the loot system's own shape, so this is BR.Inv.give with no
--- second code path, no "shop item" concept in the inventory, and nothing for
--- the two to disagree about. A weapon finds a slot; ammo goes into the pool,
--- clamped to what is left, exactly as a piece of ammo off the floor does.
---
--- QUIETLY, BECAUSE THE PURCHASE ALREADY MADE THE NOISE. Everything that lands
--- in an inventory plays GTA's PICK_UP through client/inventory.lua, and
--- `br:gunshop:bought` is about to play the shop cue for the same event. Two
--- sounds a frame apart for one purchase is the fault config/audio.lua's rule is
--- about; server/shop.lua's delivery makes the same call for the same reason.
---
--- A FULL BAG DROPS RATHER THAN EVAPORATES, which is the owner's answer 4 on the
--- showroom applied here: a displaced item lands at their feet, and a stack that
--- will not fit at all lands there instead of being taken along with the money.
---
--- ═══ AND A FULL AMMO POOL IS THE ONE CASE THAT IS UNSATISFYING ═══
---
--- Buying Heavy Ammo with a full heavy pool takes the Volts and leaves a pile on
--- the floor the player cannot pick up until they have fired some. That is not
--- refused here, and the alternative -- a refusal -- is worse in this project's
--- terms: BR.GunshopSolve.canBuy has no fullness term, adding one is a rule the
--- owner has not made, and a refusal with no sentence behind it is a press that
--- does nothing for a reason nobody can see. Flagged rather than decided.
--- @param src integer
--- @param row table
local function deliver(src, row)
    if type(row.stack) ~= 'table' then
        print(('^3[br_core] gunshop: "%s" has no stack to hand over^7')
            :format(tostring(row.id)))
        return
    end

    -- ═══ A COPY, BECAUSE row.stack IS THE CATALOGUE'S OWN TABLE ═══
    --
    -- The catalogue is built ONCE and memoised on BR.Config.Gunshop, so
    -- `row.stack` is one table shared by every purchase of that row for the life
    -- of the process. BR.Inv.give happens to build fresh tables on every branch
    -- it takes today, and BR.Loot.dropForPlayer's path is not audited here --
    -- so handing the shared one out is a bet on two other files never keeping a
    -- reference. If either ever did, a magazine count written into one player's
    -- slot would be written into the shelf, and every subsequent buyer of that
    -- gun would get it.
    --
    -- SHALLOW IS ENOUGH: every field of a loot stack is a string or a number.
    -- server/shop.lua never needed this because it composes its stack from
    -- scratch at each delivery; deriving the stack in the catalogue is what
    -- makes it worth a line here.
    local stack = {}
    for k, v in pairs(row.stack) do stack[k] = v end

    local ok, displaced, reason = BR.Inv.give(src, stack, { quiet = true })
    if ok then
        if displaced then BR.Loot.dropForPlayer(src, displaced) end
        print(('[br_core] gunshop: %d received "%s"'):format(src, row.id))
        return
    end

    BR.Loot.dropForPlayer(src, stack)
    print(('[br_core] gunshop: %d had no room for "%s" (%s) -- dropped at '
           .. 'their feet'):format(src, row.id, tostring(reason)))
end

--- C->S. "I am at a counter and I want this."
RegisterNetEvent(BR.Net.GUNSHOP_BUY)
AddEventHandler(BR.Net.GUNSHOP_BUY, function(d)
    local src = source
    -- COERCED DEFENSIVELY BEFORE ANYTHING READS IT. A payload that is not a
    -- table, or an id that is a number or a table, must resolve to "no such
    -- row" rather than reaching BR.GunshopSolve.rowById as a type it refuses.
    local id = tostring(type(d) == 'table' and d.id or '')

    local m = BR.Server.matchOf(src)
    local e = BR.Roster.get(src)
    if not m or not e then return end

    local row = BR.GunshopSolve.rowById(rows, id)
    local at  = atCounter(src)

    -- ONE PREDICATE, AND EVERY TERM RESOLVED HERE. The balance is asked for
    -- rather than cached: one ledger, one reader, and a second copy of a balance
    -- is a second thing that can be wrong about how much money somebody has.
    local ok, why = BR.GunshopSolve.canBuy({
        on          = BR.GunshopSolve.enabled(G),
        matchState  = m.state,
        playerState = e.state,
        atCounter   = at ~= nil,
        row         = row,
        balance     = BR.Market and BR.Market.balanceOf(src) or 0,
        price       = row and row.price or 0,
    })

    if not ok then
        -- ═══ SILENT TO THE PLAYER EXCEPT WHERE THE MARKET ALREADY HAS A
        --     SENTENCE ═══
        --
        -- The owner has written NO player-facing copy for this feature at all --
        -- config/gunshop.lua says so where it explains why the store rows carry
        -- no display name -- and inventing a refusal would be exactly the
        -- unrequested copy his standing rule refuses. `afford` is the one case
        -- with an existing sentence, and it is the market's own, spoken at the
        -- one funnel every shortfall in the game reaches. The `shop.denied` cue
        -- rides on that toast rather than beside it, so this path plays one
        -- sound rather than two.
        if why == BR.GunshopSolve.Refusal.AFFORD and BR.Market then
            BR.Market.tellShortfall(src, row and row.price or 0)
        end
        print(('[br_core] gunshop: %d refused "%s" -- %s')
            :format(src, id, tostring(why)))
        return
    end

    -- ═══ THE CHARGE IS THE POINT OF NO RETURN ═══
    --
    -- Everything above this line is a refusal that costs nothing. Everything
    -- below it has been paid for, and there is no refund path to fall back on.
    -- server/rescue.lua and server/shop.lua order themselves the same way and
    -- state the same rule: the goods must not exist before the debit does.
    BR.Market.charge(src, row.price, 'gunshop:' .. row.id,
        function(paid, why2, left)
            if not paid then
                -- SILENT, except where BR.Market.charge has already spoken the
                -- market's own shortfall sentence on its way out. Same rule as
                -- the refusals above.
                print(('[br_core] gunshop: %d could not be charged for "%s" '
                       .. '-- %s'):format(src, row.id, tostring(why2)))
                return
            end

            -- ═══ RE-READ AFTER THE ROUND TRIP, AND THIS IS A GATE RATHER THAN
            --     A STAMP ═══
            --
            -- A DynamoDB write is up to six seconds and a player can die, be
            -- knocked down, leave the match or disconnect inside it. The
            -- showroom's version of this check exists to stop a purchase leaking
            -- across rounds; here there is nothing to leak, because delivery is
            -- immediate -- what it stops is a gun landing in the bag of somebody
            -- who is no longer alive to hold it, which BR.Inv would then wipe at
            -- the next state change while the Volts stayed spent.
            --
            -- THE SAME TWO CLOCKS canBuy CHECKED, re-asked. Not the counter:
            -- walking away from the till in the six seconds after pressing is
            -- not a reason to lose a purchase, and the position is the one term
            -- here that is sampled rather than authoritative.
            --
            -- IT COSTS THE PLAYER THE VOLTS AND IT SAYS SO, loudly, with the
            -- price -- because this is the harshest thing the feature does and
            -- it is invisible from inside the game.
            local now = BR.Server.matchOf(src)
            local e2  = BR.Roster.get(src)
            if not now or now.state ~= BR.MatchState.PLAYING
               or not e2 or e2.state ~= BR.PlayerState.ALIVE then
                print(('^3[br_core] gunshop: %d was charged %d Volts for "%s" '
                       .. 'and was no longer alive in a live match when the '
                       .. 'write landed -- FORFEITED, no item and no refund^7')
                    :format(src, row.price, row.id))
                return
            end

            deliver(src, row)

            -- NO TOAST. The showroom speaks two sentences here and both are the
            -- owner's own, authored in config/shop.lua for #239. He has written
            -- none for this counter, so this path says nothing: the cue below
            -- and the balance dropping on the HUD are the feedback, and both are
            -- mechanisms that already existed.
            TriggerClientEvent(BR.Net.GUNSHOP_BOUGHT, src, { row = row.id })

            print(('[br_core] gunshop: %d bought "%s" for %d Volts -- %s left')
                :format(src, row.id, row.price, tostring(left)))
        end)
end)
