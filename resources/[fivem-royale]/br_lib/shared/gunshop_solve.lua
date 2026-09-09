-- The in-match Ammu-Nation weapon shop, as pure functions (#274).
--
-- NO NATIVES, NO STATE, NO SIDE EFFECTS. Everything here is arithmetic and
-- table walks, which is what lets tools/test_gunshop.lua run it -- and it is
-- also what makes the ONE rule this feature rests on checkable by a test rather
-- than by a playtest:
--
--   ═══ "we're not planning to sell items which could not otherwise be found in
--       the wild - just a convenience with a fee" (owner, 2026-09-08) ═══
--
-- There were two ways to build a catalogue and only one of them keeps that
-- sentence true without anybody having to remember it:
--
--   WRITE THE WEAPONS DOWN. A list of ids and prices in config/gunshop.lua,
--   chosen by hand. This is the tempting one and it is REJECTED. It is a SECOND
--   REPRESENTATION of a fact that already exists -- which guns the map can give
--   you -- and this repository's signature defect is exactly that: two
--   representations of one fact drifting apart. The drift here is not
--   hypothetical or cosmetic. The day a rarity moves in config/weapons.lua, the
--   hand list is selling a gun the map no longer produces at that tier, or has
--   stopped selling one it does, and NOTHING ANYWHERE SAYS SO.
--
--   DERIVE IT FROM THE TABLE THE MAP ITSELF ROLLS AGAINST. BR.Config.Weapons is
--   what BR.Config.WeaponsByRarity is built from, and those buckets are what
--   BR.RollLootStack draws every gun on the map out of. Filtering that same
--   array is not a claim that the shop matches the world -- it is the shop and
--   the world reading one table. `BR.GunshopSolve.catalogue` below is that
--   filter, and it is the whole of the fairness argument in code.
--
-- ═══ WHAT THE FILTER CANNOT DO, STATED SO NOBODY MISTAKES IT FOR ENFORCEMENT
--     ═══
--
-- Deriving proves the shop sells things the WORLD LOOT TABLE contains. It does
-- not prove the price is fair, that the rarity floor is in the right place, or
-- that a player who can afford everything is not advantaged over one who
-- cannot. Those are the owner's judgements and they live in his bands in
-- config/gunshop.lua. See that file's header: the derivation bounds what is
-- FINDABLE, his numbers bound what is FAIR, and only the first is a thing code
-- can check.
--
-- ═══ AND THERE IS NO SECOND PURSE, WHICH IS WHY THERE IS NO WALLET HERE ═══
--
-- "in-match wallet should not exist, agreed. the player has one Volts bank."
--
-- So `canBuy` below takes a `balance` and a `price` and nothing else. There is
-- no match-local balance to reconcile, no pickup that means money, and no
-- second number that could disagree with the first. The market already owns the
-- one pot; this file only ever compares against it.

BR = BR or {}
BR.GunshopSolve = {}

--- THE RARITY FLOOR: what is good enough to be worth Volts.
---
--- Common and uncommon guns are what a player trips over in the first ninety
--- seconds of a match. Paying for one is not a convenience anybody would use,
--- and stocking them would bury the four legendaries under twenty rows of
--- Micro SMG.
---
--- A FUNCTION RATHER THAN A CONSTANT, AND CALL-TIME RATHER THAN LOAD-TIME.
--- br_lib's shared scripts load as a glob, so a value assigned here at load
--- would need an `or 3` behind it for the run in which enums.lua has not gone
--- first -- and that 3 is BR.Rarity.RARE written down a second time, which is
--- the one thing this whole feature is built to avoid. Resolved on call there is
--- no fallback to drift.
---
--- ONE PLACE, so moving the floor is one line here and tools/test_gunshop.lua
--- asserts against the same symbol the shipped code reads rather than against a
--- literal typed twice.
--- @return integer
function BR.GunshopSolve.minRarity()
    return BR.Rarity.RARE
end

--- Is this weapon good enough for the counter?
---
--- THE ONE PLACE THE RARITY TEST IS SPELLED. Every caller goes through it, so
--- "what the shop stocks" is one comparison in one function and not a `>=`
--- repeated across a config, a client and a server.
--- @param w table|nil   a row of BR.Config.Weapons
--- @return boolean
function BR.GunshopSolve.sells(w)
    if type(w) ~= 'table' then return false end
    local r = tonumber(w.rarity)
    if not r then return false end
    return r >= BR.GunshopSolve.minRarity()
end

--- The catalogue id an ammo pool is sold under.
---
--- PREFIXED, DERIVED, NEVER AUTHORED. The pool names ('light', 'smg', ...) share
--- an id space here with weapon ids ('mg', 'revolver', ...), and while no
--- collision exists today the two lists are owned by different config files and
--- neither knows about the other. One prefix removes the whole class of problem.
---
--- NO COLON, AND THAT IS NOT COSMETIC. BR.ShopSolve.itemIdFor makes the same
--- point for the same reason: item ids reach br_ui as artwork paths
--- (`ui/items/<id>.png`) and a colon is not a legal filename character on every
--- platform this project is developed on. The failure would be a silently
--- missing icon rather than an error.
---
--- THE ITEM INSIDE THE STACK IS THE BARE POOL NAME, not this. See `catalogue`:
--- the inventory has always keyed ammo by the pool itself and nothing about this
--- feature is allowed to change that.
--- @param pool string|nil
--- @return string|nil
function BR.GunshopSolve.ammoIdFor(pool)
    if type(pool) ~= 'string' or pool == '' then return nil end
    return 'ammo_' .. pool
end

-- ---------------------------------------------------------------------------
-- The counters
-- ---------------------------------------------------------------------------

--- Is one authored store row usable?
---
--- THE z IS CHECKED FOR BEING A NUMBER AND FOR NOTHING ELSE, deliberately.
--- config/gunshop.lua's header explains at length that the tabulated z is of
--- uncertain meaning -- the sources disagree by up to about 1.1m on whether it
--- is the floor or a standing figure's center -- so there is no range this
--- function could check it against that would mean anything. It is a probe
--- starting point, and the client is what decides where the floor is.
--- @param store table|nil
--- @return boolean ok
--- @return string|nil why
function BR.GunshopSolve.validateStore(store)
    if type(store) ~= 'table' then return false, 'not a table' end
    if type(store.id) ~= 'string' or store.id == '' then
        return false, 'no id'
    end
    if type(store.x) ~= 'number' or type(store.y) ~= 'number'
       or type(store.z) ~= 'number' then
        return false, 'no coordinates'
    end
    if type(store.heading) ~= 'number' then return false, 'no heading' end
    -- AN UNKNOWN CLERK KEY IS A REJECT RATHER THAN A FALLBACK. A typo would
    -- otherwise put the city model in a country store and look exactly like the
    -- decision having been made that way.
    if store.clerk ~= nil and store.clerk ~= 'city' and store.clerk ~= 'country'
    then
        return false, ('unknown clerk "%s"'):format(tostring(store.clerk))
    end
    return true, nil
end

--- The usable counters, and everything thrown out.
---
--- TWO RETURNS RATHER THAN ONE FILTERED LIST, for BR.ShopSolve.catalogue's
--- reason: a row that was silently dropped is a store the owner surveyed,
--- cannot find in game, and has no way to ask about. The caller prints.
--- @param cfg table|nil   BR.Config.Gunshop
--- @return table stores
--- @return table rejects  { { id, why } }
function BR.GunshopSolve.stores(cfg)
    local out, rejects = {}, {}
    if type(cfg) ~= 'table' or type(cfg.stores) ~= 'table' then
        return out, rejects
    end

    local seen = {}
    for i = 1, #cfg.stores do
        local store  = cfg.stores[i]
        local ok, why = BR.GunshopSolve.validateStore(store)
        if ok and seen[store.id] then ok, why = false, 'duplicate id' end
        if ok then
            seen[store.id] = true
            out[#out + 1] = store
        else
            rejects[#rejects + 1] = {
                id  = (type(store) == 'table' and tostring(store.id)) or ('#' .. i),
                why = why or 'unusable',
            }
        end
    end
    return out, rejects
end

--- How many counters there are, whatever shape the config is in.
--- @param cfg table|nil
--- @return integer
function BR.GunshopSolve.storeCount(cfg)
    local stores = cfg and cfg.stores
    if type(stores) ~= 'table' then return 0 end
    return #stores
end

--- Is the gun shop a thing at all right now?
---
--- WITH NO STORES THE FEATURE IS INERT RATHER THAN BROKEN, which is
--- BR.Config.Rescue.points' rule applied a third time and for the third
--- identical reason: no clerks, no prompt, no purchase handler doing anything,
--- and above all no error. Every reader should ask this first.
---
--- IT DOES NOT ASK WHETHER THE CATALOGUE IS EMPTY, and that is deliberate. The
--- catalogue is DERIVED, so the only way for it to come out empty is for
--- BR.Config.Weapons to have no rows at RARE or above -- which would be a
--- gamemode with no good guns in it, a far larger problem than a shop, and not
--- one this function should be the reporter of. An empty catalogue with live
--- stores is eleven counters selling nothing, and BR.Config.Gunshop.build says
--- so on the console.
--- @param cfg table|nil
--- @return boolean
function BR.GunshopSolve.enabled(cfg)
    if type(cfg) ~= 'table' then return false end
    if cfg.enabled == false then return false end
    return BR.GunshopSolve.storeCount(cfg) > 0
end

--- WHICH COUNTER IS THE PLAYER AT? THE NEAREST ONE IN REACH.
---
--- THE SAME SHAPE AS BR.ShopSolve.nearest AND FOR ONE OF ITS TWO REASONS. In the
--- warmup showroom, distance ORDER is doing the real work because thirteen cars
--- stand 3.25m apart and no radius can separate them. Here the eleven counters
--- are whole districts apart, so a radius alone would in fact be enough --
--- and this still resolves to the nearest, because "the answer does not depend
--- on iteration order" is worth having for free and because #128 was the same
--- defect one system over: two things in reach, a press that took the other.
---
--- 2-D, AND HERE IT IS LOAD-BEARING RATHER THAN CONVENTIONAL. config/gunshop.lua
--- refuses to trust the tabulated z within about a metre; measuring a reach in
--- 3-D would be measuring against exactly that number. Two Ammu-Nations are
--- never stacked, so the flat distance loses nothing.
---
--- TIES GO TO THE EARLIER ROW. `<` rather than `<=`, so the answer is stable
--- while a player stands still.
---
--- ═══ AND A COUNTER WITH NOBODY BEHIND IT IS NOT A COUNTER (`present`) ═══
---
--- BR.ShopSolve.nearest grew the identical parameter for the identical reason
--- and its header carries the full argument: a row whose model never streamed
--- has no entity, and offering a price for something the player cannot see is
--- worse than offering nothing.
---
--- IT IS HANDED TO THE SELECTION RATHER THAN CHECKED AFTER THE FACT. Picking the
--- nearest store and then discovering its clerk never built would stand a player
--- in front of a working counter and refuse them -- which cannot happen here
--- today, because no two counters are within four reaches of each other, and is
--- still the wrong shape to write. The filter belongs where the choice is made.
---
--- THE FILTER IS THE CLIENT'S BUSINESS AND ONLY THE CLIENT'S. The server passes
--- nothing: it has no clerk, it has never had one, and refusing a purchase
--- because a PED failed to stream on somebody's machine would be the server
--- deciding a question it cannot see. Absent, every store is present -- which is
--- what makes the parameter free for the server to ignore.
---
--- @param stores table         the resolved counters
--- @param px number            the player, x
--- @param py number            the player, y
--- @param reachM number|nil    how far "at the counter" reaches; nil is no reach
--- @param present function|nil store -> boolean; nil accepts every store
--- @return table|nil store
--- @return number|nil dist
function BR.GunshopSolve.nearest(stores, px, py, reachM, present)
    if type(stores) ~= 'table' then return nil, nil end
    px, py = tonumber(px), tonumber(py)
    if not px or not py then return nil, nil end
    local reach = tonumber(reachM)
    if not reach or reach <= 0.0 then return nil, nil end
    if present ~= nil and type(present) ~= 'function' then return nil, nil end

    local best, bestD = nil, nil
    for i = 1, #stores do
        local s = stores[i]
        if type(s) == 'table'
           and type(s.x) == 'number' and type(s.y) == 'number' then
            local d = BR.Dist(px, py, s.x, s.y)
            -- THE DISTANCE IS TESTED BEFORE THE FILTER IS CALLED, so a predicate
            -- that asks the engine about an entity is asked about the two or
            -- three stores in reach rather than about all eleven, on every pass
            -- of a 10 Hz loop.
            if d <= reach and (bestD == nil or d < bestD)
               and (present == nil or present(s) == true) then
                best, bestD = s, d
            end
        end
    end
    return best, bestD
end

-- ---------------------------------------------------------------------------
-- Where the clerk goes, and when
-- ---------------------------------------------------------------------------

--- IS THIS STORE'S CLERK WANTED RIGHT NOW? TWO RADII, AND WHICH ONE APPLIES
--- DEPENDS ON WHETHER HE IS ALREADY THERE.
---
--- ═══ HYSTERESIS, BECAUSE ONE RADIUS IS A FLICKER ═══
---
--- With a single distance, a player standing on it builds a ped and deletes it
--- once a second for as long as they stand there: a model request, a ground
--- probe and a DeleteEntity, forever, out of a reconciler that believes it is
--- idle. Two radii make that unreachable -- he appears at `buildM` and does not
--- go until `keepM`, so the band between them is a place where nothing changes.
---
--- `has` IS "IS HE STANDING", NOT "WAS HE WANTED". The caller passes what it
--- actually has, so a build that failed (a model that never streamed) is asked
--- the BUILD question again on the next pass rather than being remembered as
--- present and never retried.
---
--- DEGENERATE CONFIGURATION IS THE CALLER'S PROBLEM, NOT A SILENT CORRECTION. If
--- `keepM` is below `buildM` the flicker is back and this function will not
--- pretend otherwise -- clamping here would hide a config the owner should see
--- in the dev command instead.
--- @param store table|nil
--- @param px number
--- @param py number
--- @param buildM number|nil
--- @param keepM number|nil
--- @param has boolean   is this store's clerk standing right now
--- @return boolean
function BR.GunshopSolve.wantsClerk(store, px, py, buildM, keepM, has)
    if type(store) ~= 'table' then return false end
    if type(store.x) ~= 'number' or type(store.y) ~= 'number' then return false end
    px, py = tonumber(px), tonumber(py)
    if not px or not py then return false end

    local build = tonumber(buildM) or 0.0
    local keep  = tonumber(keepM) or build
    local limit = (has == true) and keep or build
    if limit <= 0.0 then return false end

    return BR.Dist(px, py, store.x, store.y) <= limit
end

--- WHERE A DOWNWARD GROUND PROBE FOR THIS STORE STARTS.
---
--- THE ANCHOR PLUS A LIFT, and the lift is per-store first and global second --
--- `probeFromM` is the escape hatch config/gunshop.lua ships nil everywhere, for
--- the store that turns out to need a different one. See the long note beside
--- `probeLiftM` for why the number is squeezed between a floor and a ceiling.
---
--- A FUNCTION RATHER THAN AN ADDITION AT THE CALL SITE, so the override is
--- honored in one place and tools/test_gunshop.lua can drive it without a
--- client.
--- @param cfg table|nil
--- @param store table|nil
--- @return number|nil
function BR.GunshopSolve.probeStart(cfg, store)
    if type(store) ~= 'table' then return nil end
    local z = tonumber(store.z)
    if not z then return nil end
    local lift = tonumber(store.probeFromM)
    if not lift then
        lift = tonumber(type(cfg) == 'table' and cfg.probeLiftM or nil) or 0.0
    end
    return z + lift
end

--- ═══ THE CLERK'S HEIGHT, AND THE ORDER THE THREE ANSWERS ARE ASKED IN ═══
---
--- config/gunshop.lua's header is unambiguous that no clerk z is authored and
--- that the client ground-probes. This is where that rule is spent, and it is
--- here rather than in the client so that a test can hold it: "the probe wins
--- over the table" is the whole feature and a client file is the one place no
--- suite can execute.
---
---   1. `zOverride` -- the escape hatch, and it is FIRST because that is what an
---      escape hatch is for. Authoring one is a decision to trust a typed number
---      over the engine, for the one interior where the probe is eventually
---      found to be wrong. Nil everywhere as shipped.
---   2. THE PROBE -- the engine's own answer, and the answer this feature is
---      built around. Only when the native said yes: `hit` is a BOOL and every
---      caller must have put it through its own isTrue() before it gets here,
---      because 0 is truthy in Lua and reading a refusal as an answer would put
---      a clerk at whatever `gz` happened to hold.
---   3. THE RAW ANCHOR -- what the table says, used as it is. This is the
---      "today's behavior" fallback the showroom's collision wait also takes:
---      a clerk who may be a metre out beats a counter with nobody behind it,
---      and the second return says which happened so /brgunshop can print it.
---
--- THE SECOND RETURN IS FOR THE LEDGER AND NOTHING ELSE. It is a source key, not
--- a sentence: no string here is written to be read by a player.
--- @param cfg table|nil
--- @param store table|nil
--- @param hit boolean|nil  did the ground probe answer -- already through isTrue
--- @param gz number|nil    what it answered
--- @return number|nil z
--- @return string source   'override' | 'probe' | 'anchor'
function BR.GunshopSolve.clerkZ(cfg, store, hit, gz)
    if type(store) ~= 'table' then return nil, 'anchor' end

    local over = tonumber(store.zOverride)
    if over then return over, 'override' end

    if hit == true then
        local z = tonumber(gz)
        if z then return z, 'probe' end
    end

    return tonumber(store.z), 'anchor'
end

--- WHERE THE CLERK IS CREATED, ONCE HIS FLOOR IS KNOWN.
---
--- THE OFFSET IS SPENT ALONG THE COUNTER'S OWN HEADING, which is the one thing
--- the store table does say about which way this building faces. GTA headings
--- are degrees clockwise from north, so forward is (-sin h, cos h) -- the same
--- convention client/dui.lua's `levelBasis` records for the entity form of the
--- same arithmetic.
---
--- ZERO OFFSET IS THE SHIPPED CASE AND IT IS NOT A NO-OP WORTH SKIPPING: the
--- multiplication is what makes the owner's one number in config mean something
--- without anybody editing Lua.
--- @param cfg table|nil
--- @param store table|nil
--- @param z number|nil    the resolved floor height
--- @return number|nil x
--- @return number|nil y
--- @return number|nil z
--- @return number|nil heading
function BR.GunshopSolve.clerkAt(cfg, store, z)
    if type(store) ~= 'table' then return nil, nil, nil, nil end
    local sx, sy = tonumber(store.x), tonumber(store.y)
    local h = tonumber(store.heading)
    if not sx or not sy or not h then return nil, nil, nil, nil end

    local c = type(cfg) == 'table' and cfg or {}
    local out  = tonumber(c.clerkOffsetM) or 0.0
    local face = tonumber(c.clerkFaceDeg) or 0.0

    local rad = math.rad(h)
    return sx - math.sin(rad) * out,
           sy + math.cos(rad) * out,
           tonumber(z),
           (h + face) % 360.0
end

--- Which ped model stands behind this counter.
---
--- THE STORE NAMES A KEY AND THIS RESOLVES IT, so no client carries a model
--- string of its own. `city` is the default because nine of the eleven are city
--- stores and an absent field is the common case rather than an omission.
---
--- NIL WHEN THERE IS NO MODEL TABLE, rather than a hardcoded fallback. A caller
--- that gets nil should draw no clerk and say so; a caller handed an invented
--- model name would ask the engine to stream something nobody authored.
--- @param cfg table|nil    BR.Config.Gunshop
--- @param store table|nil
--- @return string|nil
function BR.GunshopSolve.clerkModel(cfg, store)
    local models = type(cfg) == 'table' and cfg.clerkModels or nil
    if type(models) ~= 'table' then return nil end
    local key = (type(store) == 'table' and store.clerk) or 'city'
    local m = models[key]
    if type(m) ~= 'string' or m == '' then return nil end
    return m
end

-- ---------------------------------------------------------------------------
-- The catalogue
-- ---------------------------------------------------------------------------

--- How many rounds one ammo purchase hands over.
---
--- ═══ THE DEFAULT IS ONE GROUND PICKUP, AND IT IS DERIVED RATHER THAN COPIED
---     ═══
---
--- config/gunshop.lua authors no bundle sizes. It authors the RULE -- a purchase
--- is worth exactly what a piece of ammo on the floor is worth -- and this
--- function reads BR.Config.AmmoPickups' own amount to honour it. Five integers
--- retyped into the gunshop config would be a second copy of a table that
--- already exists, and would go stale the first time the loot amounts were
--- retuned, in the direction nobody would notice: the shop quietly becoming a
--- better or worse deal than the ground.
---
--- THE RULE IS ALSO THE ARGUMENT. "A convenience with a fee" is a claim that
--- what you buy is what you would have found, and this is the one place in the
--- feature where that is literally true rather than approximately.
---
--- THE OWNER HAS NOT CONFIRMED IT. See the marked block in config/gunshop.lua:
--- the per-pool `bundle` override below is where his answer goes, and until he
--- gives one the derivation holds.
---
--- @param cfg table|nil      BR.Config.Gunshop
--- @param pool string|nil    a BR.AmmoType value
--- @param pickups table|nil  BR.Config.AmmoPickups
--- @return integer|nil       nil when neither an override nor a pickup exists
function BR.GunshopSolve.ammoBundle(cfg, pool, pickups)
    if type(pool) ~= 'string' or pool == '' then return nil end

    local row = type(cfg) == 'table' and type(cfg.ammo) == 'table'
        and cfg.ammo[pool] or nil

    -- HIS OVERRIDE WINS, and it is read before the derivation so that pinning
    -- one pool never depends on what config/loot.lua happens to say.
    if type(row) == 'table' then
        local n = tonumber(row.bundle)
        if n and n > 0 then return math.floor(n) end
    end

    local def = type(pickups) == 'table' and pickups[pool] or nil
    local amount = tonumber(type(def) == 'table' and def.amount or nil)
    if not amount or amount <= 0 then return nil end
    return math.floor(amount)
end

--- IS THIS A USABLE PRICE? One rule, so the weapon table and the ammo table
--- cannot disagree about what counts as priced.
---
--- NIL RATHER THAN ZERO FOR AN UNPRICED ROW, and the distinction is the whole of
--- what `catalogue` drops below. A zero would be a thing given away free; a nil
--- is a thing the owner has not priced, which is a different thing and gets a
--- console line. A fraction is refused too -- Volts are whole numbers
--- everywhere else in this project and half a Volt would be rounded by whichever
--- surface rendered it first.
--- @param v any
--- @return integer|nil
local function price(v)
    local n = tonumber(v)
    if not n or n <= 0 or n ~= math.floor(n) then return nil end
    return math.floor(n)
end

--- The price of one WEAPON, or nil.
--- @param cfg table|nil
--- @param id string|nil
--- @return integer|nil
function BR.GunshopSolve.priceOf(cfg, id)
    if type(cfg) ~= 'table' or type(id) ~= 'string' then return nil end
    if type(cfg.prices) ~= 'table' then return nil end
    return price(cfg.prices[id])
end

--- The price of one AMMO POOL, or nil.
---
--- ═══ A SECOND ACCESSOR RATHER THAN A SECOND ENTRY IN `prices`, AND THE REASON
---     IS THE BUNDLE ═══
---
--- An ammo row has TWO numbers -- what it costs and how much you get -- and they
--- are only meaningful beside each other: 50 Volts is cheap for 60 rounds and
--- dear for 12. Splitting them across two tables would put the owner's price in
--- one place and the quantity it prices in another, and the marked block in
--- config/gunshop.lua that asks him to confirm the bundle would be asking about
--- a number he cannot see the cost of.
---
--- SO `cfg.ammo[pool]` HOLDS BOTH and this reads the price half. The cost is
--- that "where are the prices" has two answers, which is why both accessors are
--- here, next to each other, rather than being inlined at two call sites.
--- @param cfg table|nil
--- @param pool string|nil
--- @return integer|nil
function BR.GunshopSolve.ammoPrice(cfg, pool)
    if type(cfg) ~= 'table' or type(pool) ~= 'string' then return nil end
    if type(cfg.ammo) ~= 'table' then return nil end
    local row = cfg.ammo[pool]
    if type(row) ~= 'table' then return nil end
    return price(row.price)
end

--- Ids that are on the AIRDROP SHELF and must never reach the counter.
---
--- A SET BUILT FROM THE REAL TABLE, NOT A LIST OF FOUR NAMES. Deriving the
--- catalogue from BR.Config.Weapons already excludes the shelf, because that is
--- the array those four rows are deliberately absent from -- so this is a second
--- lock on a door that is already shut, and it is free because it reads the same
--- table the airdrop does. What it buys is that the exclusion survives a caller
--- passing in the MERGED BR.Config.WeaponById by mistake, which is the one edit
--- that would quietly put an RPG behind a counter.
--- @param airdropOnly table|nil  BR.Config.AirdropWeapons
--- @return table  id -> true
local function airdropIds(airdropOnly)
    local set = {}
    if type(airdropOnly) ~= 'table' then return set end
    for i = 1, #airdropOnly do
        local w = airdropOnly[i]
        if type(w) == 'table' and type(w.id) == 'string' then set[w.id] = true end
    end
    return set
end

--- THE CATALOGUE, DERIVED. Weapons first in BR.Config.Weapons' own order, then
--- ammo in BR.Config.AmmoOrder's.
---
--- ═══ EVERY ROW CARRIES THE STACK IT PAYS OUT, AND THE STACK IS THE LOOT
---     SYSTEM'S OWN SHAPE ═══
---
--- `row.stack` is `{ item, kind, rarity, count }` -- byte for byte what
--- BR.RollLootStack hands back for the same weapon or the same ammo pool. So a
--- purchase can be given to BR.Inv exactly as a pickup is, with no second code
--- path, no "shop item" concept in the inventory and nothing for the two to
--- disagree about.
---
--- THAT IS THE RULE AT THE TOP OF THIS FILE MADE LITERAL. "A convenience with a
--- fee" is not a claim about intent here; it is that the thing handed over the
--- counter is the same table the ground would have handed over.
---
--- NO NEW ITEM IDS ARE MINTED, and that is worth contrasting with the warmup
--- showroom, which mints `car_<id>` because a purchased vehicle is a thing the
--- inventory has never heard of. A carbine is not: BR.Config.WeaponById already
--- knows it, the ground already drops it, the bag already holds it. Inventing
--- `gun_carbinerifle` would create a second name for a thing that has one.
---
--- ORDER IS THE SOURCE TABLES', NEVER pairs(). BR.Config.Weapons is authored in
--- class groups the owner reads it in, and BR.Config.AmmoOrder exists precisely
--- because iterating the pool table with pairs() is order-undefined. Anything
--- that renders this list gets a stable order for free.
---
--- @param cfg table|nil  BR.Config.Gunshop
--- @param src table|nil  { weapons, airdropOnly, ammoOrder, ammoPickups }
--- @return table rows
--- @return table rejects  { { id, why } }
function BR.GunshopSolve.catalogue(cfg, src)
    local rows, rejects = {}, {}
    if type(cfg) ~= 'table' then return rows, rejects end
    src = type(src) == 'table' and src or {}

    local banned = airdropIds(src.airdropOnly)
    local seen   = {}

    local weapons = type(src.weapons) == 'table' and src.weapons or {}
    for i = 1, #weapons do
        local w = weapons[i]
        if BR.GunshopSolve.sells(w) and type(w.id) == 'string' then
            local id = w.id
            if banned[id] then
                -- NOT A REJECT LINE THE OWNER NEEDS TO SEE ON A HEALTHY BOOT,
                -- but it is reported rather than skipped: reaching this branch
                -- means somebody passed the merged weapon table in, and that is
                -- a bug worth a console line even though the outcome is right.
                rejects[#rejects + 1] = { id = id, why = 'airdrop-only' }
            elseif seen[id] then
                rejects[#rejects + 1] = { id = id, why = 'duplicate id' }
            else
                -- `cost` RATHER THAN `price`, WHICH IS NOT A STYLE CHOICE: the
                -- local helper above is called `price`, and a local of that name
                -- here would shadow it inside this loop. It happens to be
                -- harmless today because nothing in the loop body calls the
                -- helper directly, and "harmless today" is how the next edit
                -- becomes a bug that reads as correct.
                local cost = BR.GunshopSolve.priceOf(cfg, id)
                if not cost then
                    -- HALF-PRICED IS HALF-STOCKED, NOT BROKEN. The owner added a
                    -- gun at RARE or moved one up into the band and has not put
                    -- a number beside it in config/gunshop.lua.
                    rejects[#rejects + 1] = { id = id, why = 'no price' }
                else
                    seen[id] = true
                    rows[#rows + 1] = {
                        id     = id,
                        kind   = BR.ItemKind.WEAPON,
                        price  = cost,
                        rarity = w.rarity,
                        label  = w.label,
                        stack  = {
                            item   = id,
                            kind   = BR.ItemKind.WEAPON,
                            rarity = w.rarity,
                            count  = 1,
                        },
                    }
                end
            end
        end
    end

    local order = type(src.ammoOrder) == 'table' and src.ammoOrder or {}
    for i = 1, #order do
        local pool = order[i]
        local id   = BR.GunshopSolve.ammoIdFor(pool)
        if id then
            if seen[id] then
                rejects[#rejects + 1] = { id = id, why = 'duplicate id' }
            else
                local cost   = BR.GunshopSolve.ammoPrice(cfg, pool)
                local bundle = BR.GunshopSolve.ammoBundle(cfg, pool,
                                                          src.ammoPickups)
                local def    = type(src.ammoPickups) == 'table'
                    and src.ammoPickups[pool] or nil
                if not cost then
                    rejects[#rejects + 1] = { id = id, why = 'no price' }
                elseif not bundle then
                    -- A POOL WITH NO BUNDLE IS A POOL WITH NO SIZE. It means
                    -- neither the owner nor config/loot.lua has said how much
                    -- one purchase is, and selling an unknown quantity for a
                    -- known price is the one outcome worse than not selling it.
                    rejects[#rejects + 1] = { id = id, why = 'no bundle size' }
                else
                    seen[id] = true
                    rows[#rows + 1] = {
                        id     = id,
                        kind   = BR.ItemKind.AMMO,
                        price  = cost,
                        pool   = pool,
                        -- AMMO HAS NO RARITY OF ITS OWN ANYWHERE IN THIS
                        -- PROJECT, and BR.RollLootStack spends its rarity roll
                        -- on picking a pool instead. COMMON here is that same
                        -- convention rather than a claim that ammo is common.
                        rarity = BR.Rarity.COMMON,
                        label  = type(def) == 'table' and def.label or nil,
                        stack  = {
                            item   = pool,
                            kind   = BR.ItemKind.AMMO,
                            rarity = BR.Rarity.COMMON,
                            count  = bundle,
                        },
                    }
                end
            end
        end
    end

    return rows, rejects
end

--- One row by its catalogue id, which is what a client names in a purchase.
--- @param rows table
--- @param id any
--- @return table|nil
function BR.GunshopSolve.rowById(rows, id)
    if type(rows) ~= 'table' or type(id) ~= 'string' then return nil end
    for i = 1, #rows do
        if type(rows[i]) == 'table' and rows[i].id == id then return rows[i] end
    end
    return nil
end

--- Every row of one kind, in catalogue order. For a caller that wants the guns
--- and the ammo as separate lists without deciding what "ammo" is spelled.
--- @param rows table
--- @param kind string
--- @return table
function BR.GunshopSolve.ofKind(rows, kind)
    local out = {}
    if type(rows) ~= 'table' then return out end
    for i = 1, #rows do
        if type(rows[i]) == 'table' and rows[i].kind == kind then
            out[#out + 1] = rows[i]
        end
    end
    return out
end

--- HOW ONE ROW IS NAMED ON A SHELF.
---
--- ═══ NOTHING HERE IS COPY, AND THE ONE MARK THAT IS NOT A LABEL IS DECLARED
---     ═══
---
--- The words are the catalogue's: `label` is config/weapons.lua's own display
--- name for a gun and config/loot.lua's own for an ammo pool. This function
--- writes none of them and invents none of them -- the owner has written no
--- player-facing text for this feature and the standing rule is that unrequested
--- copy reads as slop.
---
--- THE QUANTITY IS THE ONE THING THE LABEL CANNOT SAY BY ITSELF. "Heavy Ammo,
--- 50 Volts" is not a price anybody can judge: 50 is dear for twelve rounds and
--- cheap for sixty, and config/gunshop.lua's own marked block asks the owner to
--- judge exactly that. So an ammo row carries how much it hands over, in the
--- shortest form there is -- `x` and the number, which is a quantity mark rather
--- than a word, and which is the only character in this feature that is neither
--- his nor derived from a table he owns. It is flagged here so that replacing it
--- is a one-line edit somebody can find.
---
--- WEAPONS GET NO COUNT because every weapon row is a count of one
--- (`stack.count = 1` in `catalogue` above), and "Carbine Rifle x1" says nothing
--- the row did not already say.
--- @param row table|nil
--- @return string
function BR.GunshopSolve.menuLabel(row)
    if type(row) ~= 'table' then return '' end
    local label = type(row.label) == 'string' and row.label ~= '' and row.label
        or tostring(row.id or '')
    if row.kind ~= BR.ItemKind.AMMO then return label end

    local n = tonumber(type(row.stack) == 'table' and row.stack.count or nil)
    if not n or n <= 0 then return label end
    return ('%s x%d'):format(label, math.floor(n))
end

-- ---------------------------------------------------------------------------
-- May this player buy this, right now?
-- ---------------------------------------------------------------------------

--- Refusal reasons. Values are what the SERVER logs. Nothing here is copy: no
--- string below is written to be read by a player, and inventing player-facing
--- wording for a feature the owner has not written copy for is a standing rule
--- against.
BR.GunshopSolve.Refusal = {
    OFF    = 'gunshopoff',  -- no stores: the feature does not exist
    STATE  = 'notplaying',  -- the counter is open during a live match only
    NOROW  = 'nosuchitem',  -- the client named something that is not for sale
    NOTAT  = 'notatcounter',-- the player is not standing at a counter
    AFFORD = 'afford',      -- not enough Volts
}

--- THE WHOLE PURCHASE CONDITION, IN ONE PLACE, EVALUATED BY THE SERVER.
---
--- THE CLIENT ASKS AND NEVER DECIDES. It sends a catalogue id and nothing else
--- -- no price, no balance, no claim about where it is standing or what state it
--- is in. Every term below is resolved server-side against config and the
--- roster. That is server/market.lua's rule for the storefront and
--- BR.ShopSolve.canBuy's rule for the showroom, and it is the rule here.
---
--- ═══ THE STATE PAIR IS AN ASSUMPTION AND THE OWNER SHOULD CONFIRM IT ═══
---
--- ─────────────────────────────────────────────────────────────────────
---  NEEDS HIS CONFIRMATION: WHEN THE COUNTER IS OPEN.
--- ─────────────────────────────────────────────────────────────────────
---
--- This is an IN-MATCH shop, which is the one thing the owner said that
--- distinguishes it from the warmup showroom -- so PLAYING and ALIVE is the
--- reading, and both clocks are checked for BR.ShopSolve.canBuy's reason: a
--- spectator or a downed player is not somebody standing at a counter, and
--- checking one and not the other is the shape of bug that let a downed player
--- use the inventory.
---
--- WHAT IS GENUINELY OPEN is whether a DBNO player may buy (they cannot walk to
--- a counter, so it is probably moot), and whether the shops are also open
--- during warmup -- eleven of them are on the map the whole time, and the
--- showroom already occupies warmup. Both are one line here.
---
--- NO PURCHASE LIMIT, and that is the difference from the showroom rather than
--- an omission. "no more than 1 vehicle during warmup" was an answer about cars;
--- a shop that sells one magazine of ammo per match is not a convenience. If a
--- cap is wanted it belongs in config/gunshop.lua as a number, the way
--- BR.Config.Shop.limit is.
---
--- @param st table  { on, matchState, playerState, atCounter, row, balance, price }
--- @return boolean ok
--- @return string|nil why  a BR.GunshopSolve.Refusal value
function BR.GunshopSolve.canBuy(st)
    if type(st) ~= 'table' then return false, BR.GunshopSolve.Refusal.OFF end
    if st.on ~= true then return false, BR.GunshopSolve.Refusal.OFF end

    if st.matchState ~= BR.MatchState.PLAYING then
        return false, BR.GunshopSolve.Refusal.STATE
    end
    if st.playerState ~= BR.PlayerState.ALIVE then
        return false, BR.GunshopSolve.Refusal.STATE
    end

    -- RESOLVED ON THE SERVER FROM THE PLAYER'S OWN POSITION, never taken from
    -- the client's word for where it is. A client that could assert "I am at a
    -- counter" could shop from the top of Mount Chiliad.
    if st.atCounter ~= true then
        return false, BR.GunshopSolve.Refusal.NOTAT
    end

    if st.row == nil then return false, BR.GunshopSolve.Refusal.NOROW end

    -- THE PRICE COMES FROM THE ROW AND THE BALANCE FROM THE LEDGER; neither ever
    -- comes from the client. A `>=` rather than a `>`: spending your last Volt
    -- at the counter is a purchase, not an overdraft.
    local price   = tonumber(st.price) or 0
    local balance = tonumber(st.balance) or 0
    if balance < price then return false, BR.GunshopSolve.Refusal.AFFORD end

    return true, nil
end

--- How many more Volts a player needs, for the market's existing sentence.
--- @param balance number|nil
--- @param price number|nil
--- @return integer
function BR.GunshopSolve.shortfall(balance, price)
    local d = (tonumber(price) or 0) - (tonumber(balance) or 0)
    if d < 0 then d = 0 end
    return math.floor(d)
end
