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

--- WHAT IS LEFT ON EVERY SHELF, PER MATCH. `stock[matchId][storeId][rowId] = n`.
---
--- ═══ THE SERVER OWNS IT, WHICH IS NOT A STYLE CHOICE ═══
---
--- The shelf is SHARED. The player who takes the last Carbine takes it from
--- everybody in that match, so a client that derived its own copy from a seed
--- would be right at the start of the match and wrong from the first purchase
--- anyone made. There is one count and it is here.
---
--- WEAPONS ONLY, AND THE ABSENCE IS THE VOCABULARY. Owner, 2026-09-09: "They
--- will have no limited stock on ammo", so an ammo row is never a key in these
--- tables and BR.GunshopSolve.stockOf answers nil for it -- which every reader
--- takes to mean uncounted rather than sold out. `0` is truthy in Lua and those
--- two have to be told apart by an explicit nil test, which is why that
--- distinction is one function rather than one branch per caller.
local stock = {}

--- WHO HAS BEEN SENT THE WHOLE PICTURE, AND FOR WHICH MATCH. `told[src] = id`.
---
--- Keyed by the match rather than by a bare boolean so that a player who moves
--- between matches gets a fresh snapshot without anybody having to notice they
--- moved. A reconnecting player is a new server id and is unknown here, which is
--- the same answer.
local told = {}

--- The seed one match's shelves are rolled from.
---
--- THE ARITHMETIC IS BR.Loot.begin's, deliberately: the clock plus the match's
--- sequence number folded with a prime of this feature's own, so two matches
--- minted in the same server millisecond do not stock the same eleven shops.
--- The storm uses 7919, the bus 104729, the loot layout 15485863; this is the
--- fourth. `seq` rather than `id` for the reason BR.Loot.begin gives (#291).
--- @param m table
--- @return integer
local function seedFor(m)
    local t = 0
    if type(GetGameTimer) == 'function' then t = tonumber(GetGameTimer()) or 0 end
    if t <= 0 then t = math.floor(os.time() * 1000) end
    return math.floor(t + (tonumber(m.seq) or 0) * 32452843)
end

--- ONE MATCH'S SHELVES, ROLLED ON FIRST ASK.
---
--- ═══ LAZY, BECAUSE THE ALTERNATIVE IS A WINDOW IN WHICH EVERYTHING IS FREE
---     ═══
---
--- A missing shelf means "not counted", and not counted means unlimited -- that
--- is how ammo works and it is the right answer for ammo. If the only thing that
--- rolled a shelf were the one-second heartbeat, then for up to a second after a
--- match came into existence every counter on the map would sell every gun with
--- no limit, silently. So the roll happens on the first ASK, from whichever side
--- asks first, and the heartbeat is only what carries it to the clients.
---
--- IDEMPOTENT AND SEEDED ONCE. The second caller gets the first caller's table,
--- not a second roll, which is the property the shelf being SHARED rests on.
--- @param id any        a match id
--- @param m table|nil   the match, when the caller has it. Without it an
---                      unrolled match stays unrolled rather than being rolled
---                      off a seed nobody can reproduce.
--- @return table|nil    { [storeId] = { [rowId] = count } }
function BR.Gunshop.stock(id, m)
    if id == nil then return nil end
    if stock[id] ~= nil then return stock[id] end
    if type(m) ~= 'table' or #stores == 0 or #rows == 0 then return nil end

    local rng  = BR.Rng(seedFor(m))
    local roll = function(lo, hi) return rng:int(lo, hi) end
    local by   = {}
    for i = 1, #stores do
        by[stores[i].id] = BR.GunshopSolve.rollStock(G, rows, roll)
    end
    stock[id] = by
    print(('[br_core] gunshop: match %s stocked %d counters')
        :format(tostring(id), #stores))
    return by
end

--- ONE ENVELOPE, TWO USES. See BR.Net.GUNSHOP_STOCK in shared/protocol.lua.
--- @param targets integer[]
--- @param payload table
local function pushStock(targets, payload)
    for i = 1, #targets do
        TriggerClientEvent(BR.Net.GUNSHOP_STOCK, targets[i], payload)
    end
end

--- ROLL A MATCH'S SHELVES ONCE, AND TELL EVERYONE IN IT WHO HAS NOT BEEN TOLD.
---
--- ═══ WHY THIS IS A POLL RATHER THAN A HOOK ON THE STATE MACHINE ═══
---
--- The natural place to stock eleven shops is the WARMUP branch of
--- server/match.lua, beside BR.Loot.begin, and that is where the loot layout is
--- seeded for the same reason. It is NOT done there, because the same round that
--- added stock is being built by three people at once and match.lua belongs to
--- none of them -- so the trigger lives in this file, where the feature is, and
--- reads the state machine rather than editing it.
---
--- IT ALSO SOLVES A PROBLEM A HOOK WOULD NOT. There is no "this player is now in
--- this match" event on this server, so even with a hook at WARMUP something
--- would still have to notice a player who joined afterwards. `told` is that
--- notice, and it costs one table lookup per player per second.
---
--- ROLLED FOR ANY LIVE MATCH, NOT ONLY A PLAYING ONE. "Start the match with" is
--- the owner's phrasing, so the shelves exist before the bus does. Nobody can
--- buy from them until PLAYING -- that is BR.GunshopSolve.canBuy's term and it
--- has not moved.
function BR.Gunshop.sync()
    if #stores == 0 or #rows == 0 then return end

    BR.Server.eachMatch(function(m)
        local id = m.id
        BR.Gunshop.stock(id, m)

        local fresh = {}
        local seats = BR.Server.audience(m)
        for i = 1, #seats do
            if told[seats[i]] ~= id then
                told[seats[i]] = id
                fresh[#fresh + 1] = seats[i]
            end
        end
        if #fresh > 0 then
            pushStock(fresh, { stores = stock[id], full = true })
        end
    end)
end

--- The counts one store holds right now, or nil for a match with no shelves yet.
--- @param m table|nil
--- @param storeId any
--- @return table|nil
local function stockAt(m, storeId)
    local by = m and BR.Gunshop.stock(m.id, m) or nil
    if type(by) ~= 'table' then return nil end
    local one = by[storeId]
    if type(one) ~= 'table' then return nil end
    return one
end

--- Move one count and tell the whole match, which is everyone the shelf is
--- shared with.
--- @param m table
--- @param storeId any
--- @param rowId string
--- @param delta integer
local function moveStock(m, storeId, rowId, delta)
    local one = stockAt(m, storeId)
    if not one or one[rowId] == nil then return end
    local n = (tonumber(one[rowId]) or 0) + delta
    if n < 0 then n = 0 end
    one[rowId] = n
    pushStock(BR.Server.audience(m), { stores = { [storeId] = { [rowId] = n } } })
end

-- A MATCH THAT IS GONE HAS NO SHELVES. The same hook server/players.lua uses to
-- forget a finished match, for the same reason: this table is keyed by match id
-- and nothing else would ever clear it.
AddEventHandler('br:match:destroyed', function(ev)
    local id = type(ev) == 'table' and ev.matchId or nil
    if id == nil then return end
    stock[id] = nil
    for src, at in pairs(told) do
        if at == id then told[src] = nil end
    end
end)

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

-- THE ONE HEARTBEAT THIS FILE HAS. A second is far below anything a player can
-- perceive here -- the shelves cannot change without a purchase, and a purchase
-- pushes its own delta immediately -- so this loop exists only to stock a new
-- match and to catch a player who was not in the audience a second ago.
--
-- GUARDED, BECAUSE THIS FILE IS STOOD UP HEADLESS BY tools/test_gunshop.lua and
-- CreateThread does not exist there. BR.Gunshop.sync is public for the same
-- reason: the suite drives it directly rather than waiting a second.
if type(CreateThread) == 'function' then
    CreateThread(function()
        while true do
            Wait(1000)
            BR.Gunshop.sync()
        end
    end)
end

--- WHAT IS ON EVERY SHELF, PRINTED. Dev-gated by construction, like every other
--- command in this project -- shared/devgate.lua wraps RegisterCommand once so a
--- new verb is gated without anybody remembering to gate it.
---
--- IT EXISTS BECAUSE "WHY DOES THIS SHOP HAVE NOTHING" IS OTHERWISE
--- UNANSWERABLE. A shelf is rolled once, per match, per store, and the only
--- other evidence of it is what a player sees at a counter -- which is the same
--- argument /brlootseed makes for the loot layout and /brgunshop makes for the
--- clerk ledger.
RegisterCommand('brgunshopstock', function()
    for id, by in pairs(stock) do
        for i = 1, #stores do
            local one = by[stores[i].id]
            if one then
                local parts = {}
                for rowId, n in pairs(one) do
                    if n > 0 then parts[#parts + 1] = ('%s x%d'):format(rowId, n) end
                end
                table.sort(parts)
                print(('[br_core] gunshop stock: match %s / %s -- %s')
                    :format(tostring(id), tostring(stores[i].id),
                            #parts > 0 and table.concat(parts, ', ') or 'empty'))
            end
        end
    end
end, false)

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
--- ═══ AND A FULL AMMO POOL USED TO BE THE ONE CASE THAT WAS UNSATISFYING ═══
---
--- Buying Heavy Ammo with a full heavy pool took the Volts and left a pile on
--- the floor the player could not pick up until they had fired some. The note
--- here said that was flagged rather than decided, because refusing it was a
--- rule the owner had not made and a refusal with no sentence behind it is a
--- press that does nothing for a reason nobody can see.
---
--- HE MADE THE RULE AND WROTE THE SENTENCE ON 2026-09-09: "If someone is already
--- carrying the max of an ammo ... reject the purchase and give them a toast
--- explaining they already have the max (same as we do for loot pickups)". So a
--- full pool is now refused above the charge, in BR.GunshopSolve.canBuy, in the
--- loot pickup's own words. What is left here is the PARTIAL case -- a pool with
--- room for some of the bundle but not all of it -- which still clamps and drops
--- the remainder, exactly as a piece of ammo off the floor does.
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

    -- ═══ `focus`: THE GUN THEY BOUGHT IS THE GUN IN THEIR HANDS (I3) ═══
    --
    -- Owner, 2026-09-09: "when they buy a weapon and it's granted to them, the
    -- weapon must immediately be the inventory slot in focus."
    --
    -- BR.Inv.give deliberately does NOT arm a player who is already holding
    -- something, and it is right about floor loot: walking over a rifle must
    -- not tear the shotgun out of your hands. A purchase is the opposite event
    -- -- the player named this weapon, paid for it and watched the clerk hand
    -- it over -- so the flag is set here and nowhere else. It is the only
    -- caller in the tree that passes it, and it defaults off.
    --
    -- HARMLESS ON AN AMMO ROW. That branch of give() returns before a slot is
    -- ever chosen, because a pool does not have one; passing the flag on every
    -- delivery is one fewer condition here than asking the row what kind it is,
    -- and asking would be a second copy of a question give() already answers.
    local ok, displaced, reason =
        BR.Inv.give(src, stack, { quiet = true, focus = true })
    if ok then
        if displaced then BR.Loot.dropForPlayer(src, displaced) end
        print(('[br_core] gunshop: %d received "%s"'):format(src, row.id))
        return
    end

    BR.Loot.dropForPlayer(src, stack)
    print(('[br_core] gunshop: %d had no room for "%s" (%s) -- dropped at '
           .. 'their feet'):format(src, row.id, tostring(reason)))
end

--- IS THE POOL THIS ROW FILLS ALREADY AT ITS CEILING?
---
--- Owner, 2026-09-09: "If someone is already carrying the max of an ammo ...
--- reject the purchase and give them a toast explaining they already have the
--- max (same as we do for loot pickups)".
---
--- READ, NEVER WRITTEN, AND OUT OF THE INVENTORY'S OWN TABLES. `inv.ammo` is the
--- pool and BR.Config.AmmoCaps is the ceiling, which are the same two values
--- BR.Inv.give's own `addAmmo` clamps against -- so the number that refuses the
--- purchase here cannot disagree with the number that would have clamped it.
---
--- FALSE FOR EVERYTHING THAT IS NOT AMMO, and false when the pool has no cap at
--- all. A refusal invented out of a lookup that came back empty is the defect
--- BR.Loot.refusalText's own header is about.
--- @param src integer
--- @param row table|nil
--- @return boolean
local function ammoFull(src, row)
    if type(row) ~= 'table' or row.kind ~= BR.ItemKind.AMMO then return false end
    local pool = row.pool
    if type(pool) ~= 'string' or pool == '' then return false end

    local inv = BR.Inv and BR.Inv.of and BR.Inv.of(src) or nil
    if type(inv) ~= 'table' or type(inv.ammo) ~= 'table' then return false end

    local caps = BR.Config and BR.Config.AmmoCaps or nil
    local cap  = tonumber(type(caps) == 'table' and caps[pool] or nil)
    if not cap or cap <= 0 then return false end

    return (tonumber(inv.ammo[pool]) or 0) >= cap
end

--- ONE REFUSAL, SPOKEN THE WAY server/market.lua SPEAKS ITS OWN.
---
--- ═══ WHY A RAW NOTIFY RATHER THAN BR.Server.notify ═══
---
--- The cue has to ride ON the payload rather than beside it. BR.Server.notify
--- has no cue field, so a separate SFX_CUE would race the sentence and, worse,
--- would play ON TOP of the general warn sound br_ui/client/nui.lua gives every
--- warn toast -- two sounds for one refusal. market.lua's own `refuse` helper
--- carries the same three lines for the same reason, and BR.Market.tellShortfall
--- has the write-up.
---
--- THE KEY COMES OUT OF CONFIG, so client/sfx.lua stays the only file that knows
--- what set and name it resolves to and /brsfx can still audition it.
--- @param src integer
--- @param text string
local function refuse(src, text)
    if type(text) ~= 'string' or text == '' then return end
    TriggerClientEvent(BR.Net.NOTIFY, src,
        { text = text, tone = 'warn', ms = 4000, cue = G.denyCue })
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

    -- THE SHELF THIS PRESS IS AGAINST, RESOLVED FROM THE SERVER'S OWN POSITION
    -- SAMPLE like every other term here. A client cannot name a store any more
    -- than it can name a price.
    local shelf = at and stockAt(m, at.id) or nil

    -- ONE PREDICATE, AND EVERY TERM RESOLVED HERE. The balance is asked for
    -- rather than cached: one ledger, one reader, and a second copy of a balance
    -- is a second thing that can be wrong about how much money somebody has.
    local ok, why = BR.GunshopSolve.canBuy({
        on          = BR.GunshopSolve.enabled(G),
        matchState  = m.state,
        playerState = e.state,
        atCounter   = at ~= nil,
        row         = row,
        -- nil FOR AMMO AND FOR A MATCH THAT HAS NOT BEEN STOCKED, WHICH ARE THE
        -- SAME ANSWER: not counted. stockOf makes that one decision so no caller
        -- has to remember that `0` is truthy.
        stock       = BR.GunshopSolve.stockOf(shelf, row),
        ammoFull    = ammoFull(src, row),
        balance     = BR.Market and BR.Market.balanceOf(src) or 0,
        price       = row and row.price or 0,
    })

    if not ok then
        -- ═══ TWO REFUSALS SPEAK NOW, AND STILL NOTHING INVENTS A WORD ═══
        --
        -- This path used to be silent everywhere except `afford`, where it
        -- borrowed BR.Market.tellShortfall's sentence, because the owner had
        -- written no copy for this counter. He played it on 2026-09-09 and wrote
        -- two sentences, and the third is one this game already had:
        --
        --   afford    his own, out of config/gunshop.lua, joined and marked for
        --             the signature color by BR.GunshopSolve.poorToast. It
        --             REPLACES tellShortfall's "You need %d more to buy that."
        --             here -- which he called "not good copy" -- and takes the
        --             `shop.denied` cue with it so the refusal still has its
        --             one sound.
        --   ammofull  "same as we do for loot pickups", so it IS the loot
        --             pickup's: BR.Loot.refusalText is public and this calls it
        --             rather than copying the sentence out of it. The day he
        --             rewords one, both move.
        --
        -- AND `outofstock` STAYS SILENT, deliberately. He asked for that row to
        -- be LOCKED with no price rather than for a sentence, so a press that
        -- reaches here is a press the menu should not have allowed -- a race
        -- with somebody else's purchase, or a client that named a row it could
        -- not see. There is no wording for it because he wrote none.
        if why == BR.GunshopSolve.Refusal.AFFORD then
            refuse(src, BR.GunshopSolve.poorToast(
                G,
                BR.Market and BR.Market.balanceOf(src) or 0,
                BR.Config.Market and BR.Config.Market.currency or nil))
        elseif why == BR.GunshopSolve.Refusal.FULL then
            BR.Server.notify(src,
                BR.Loot.refusalText('ammofull', row and row.stack or nil), 'warn')
        end
        print(('[br_core] gunshop: %d refused "%s" -- %s')
            :format(src, id, tostring(why)))
        return
    end

    -- ═══ THE UNIT COMES OFF THE SHELF BEFORE THE MONEY MOVES ═══
    --
    -- A charge is a DynamoDB round trip of up to six seconds, and the shelf is
    -- shared. Decrementing after the callback would mean two players pressing on
    -- the last Carbine inside one round trip both read a stock of 1, both pass
    -- canBuy, and both get a gun that only existed once. So the unit is RESERVED
    -- here, on the same line of reasoning that has BR.Market.charge reserve the
    -- Volts against the session cache the moment it is called.
    --
    -- AND IT GOES BACK ON THE SHELF IF NOTHING IS HANDED OVER. Both failure arms
    -- below release it: a refused charge, and the post-charge gate that forfeits
    -- a purchase whose buyer died inside the write. The forfeit still costs that
    -- player the Volts -- there is no refund path and that is stated below --
    -- but the gun was never handed to anybody, so the shelf is wrong if it
    -- stays short.
    local shelfId = at and at.id or nil
    local reserved = shelfId ~= nil
        and BR.GunshopSolve.stockOf(shelf, row) ~= nil
    if reserved then moveStock(m, shelfId, row.id, -1) end
    local function release()
        if reserved then
            reserved = false
            moveStock(m, shelfId, row.id, 1)
        end
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
                release()
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
                release()
                print(('^3[br_core] gunshop: %d was charged %d Volts for "%s" '
                       .. 'and was no longer alive in a live match when the '
                       .. 'write landed -- FORFEITED, no item and no refund^7')
                    :format(src, row.price, row.id))
                return
            end

            print(('[br_core] gunshop: %d bought "%s" for %d Volts -- %s left')
                :format(src, row.id, row.price, tostring(left)))

            -- ═══ AMMO IS HANDED OVER AT ONCE, BECAUSE THERE IS NO HANDOVER ═══
            --
            -- P2 step 5: "This animation/entity/speech process should be skipped
            -- for all ammo purchases." No presentation means nothing to wait
            -- for, so this arm is the old order unchanged.
            --
            -- ═══ AND THE TOAST IS AMMO-ONLY, WHICH IS HIS SCOPING ═══
            --
            -- Owner, 2026-09-09: "when ammo is purchased show a success toast:
            -- You purchased {item} for {cost}. otherwise they have no way to
            -- know anything went through."
            --
            -- A weapon purchase is answered by the clerk handing the gun over,
            -- so a sentence there would be the second thing saying the same
            -- thing. Ammo goes into a pool with no slot and no animation, which
            -- is exactly the "no way to know" he is describing.
            --
            -- SUCCESS, NOT WARN, and no cue: `shop.buy` already rides on
            -- GUNSHOP_BOUGHT and two sounds for one purchase is the fault
            -- config/audio.lua's rule is about.
            if row.kind == BR.ItemKind.AMMO then
                deliver(src, row)
                BR.Server.notify(src, BR.GunshopSolve.boughtToast(
                    G, row,
                    BR.Config.Market and BR.Config.Market.currency or nil),
                    'success')
                TriggerClientEvent(BR.Net.GUNSHOP_BOUGHT, src, { row = row.id })
                return
            end

            -- ═══ P2 STEP 4: THE ARMING IS THE END OF THE PRESENTATION ═══
            --
            -- Owner, 2026-09-09:
            --
            --   3. the weapon I just purchased is spawned as a network entity in
            --      the clerk's hands as the clerk presents it to me
            --   4. the entity is deleted, the ped tasks cleared, and I am now
            --      armed with that weapon ALL AT ONCE
            --
            -- This used to call deliver() and THEN fire GUNSHOP_BOUGHT, which is
            -- his sequence backwards: the gun was in the bag -- and, since I3,
            -- in the player's hands -- before the clerk had begun to offer it.
            -- The clerk was then animated presenting something the player was
            -- already holding.
            --
            -- SO THE EVENT GOES FIRST AND THE GOODS FOLLOW. GUNSHOP_BOUGHT
            -- starts the remark and the presentation; `handoverMs` later the
            -- client deletes the prop and clears the clerk's tasks, and this
            -- delivers. Three things, one moment, two machines reading ONE
            -- config value -- see the note on `handoverMs` for why the number is
            -- not typed in either file.
            --
            -- THE GATE IS ASKED AGAIN, and it is the same gate for the same
            -- reason. The one above proves the buyer was alive when the charge
            -- landed; this proves it when the goods do, because the wait is a
            -- window a player can die in like any other. It costs them the Volts
            -- and says so, exactly as the first one does -- there is still no
            -- refund path, and inventing one for a window we introduced would be
            -- a rule the rest of the file does not have.
            TriggerClientEvent(BR.Net.GUNSHOP_BOUGHT, src, { row = row.id })

            SetTimeout(tonumber(G.handoverMs) or 0, function()
                local m2 = BR.Server.matchOf(src)
                local e3 = BR.Roster.get(src)
                if not m2 or m2.state ~= BR.MatchState.PLAYING
                   or not e3 or e3.state ~= BR.PlayerState.ALIVE then
                    -- BACK ON THE SHELF, because nothing was handed over. The
                    -- rule is stated at `reserved` above and both of the other
                    -- failure arms already keep it; a forfeit that left the
                    -- count short would take a rifle out of the match that
                    -- nobody ever received.
                    release()
                    print(('^3[br_core] gunshop: %d was charged %d Volts for '
                           .. '"%s" and was no longer alive in a live match '
                           .. 'when the clerk finished handing it over -- '
                           .. 'FORFEITED, no item and no refund^7')
                        :format(src, row.price, row.id))
                    return
                end
                deliver(src, row)
            end)
        end)
end)
