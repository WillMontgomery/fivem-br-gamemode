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
--- TWO OFFSETS, SPENT IN THE COUNTER'S OWN FRAME. The store table says where the
--- anchor is and which way the counter faces, and that heading is the only basis
--- there is. Forward is (-sin h, cos h) -- the same convention client/dui.lua's
--- `levelBasis` records for the entity form of the same arithmetic -- and RIGHT
--- is that turned a quarter turn, (cos h, sin h). Facing north, forward is north
--- and right is east; that is the whole derivation.
---
--- ═══ WHY THERE ARE TWO NOW, AND IT IS THE OWNER'S PLAYTEST ═══
---
--- Owner, 2026-09-09, having visited five of the eleven counters:
---
---   "The ped position is consistently on top of the register (as I have
---    validated at many shops) - let us move their position back behind the
---    counter and to the left (the ped-s right) about 1m"
---
--- "Back" is `clerkOffsetM` going negative, which this function could already
--- express. "TO THE PED'S RIGHT" IS THE HALF IT COULD NOT: there was no lateral
--- term in this arithmetic at all, so the second half of his sentence had no
--- number it could be written into. `clerkRightM` is that number.
---
--- BOTH ARE SPENT ALONG THE STORE'S HEADING RATHER THAN THE CLERK'S, and that is
--- deliberate: `clerkFaceDeg` turns the clerk on the spot and must not also
--- slide him sideways, or one playtest fix would quietly undo another. With
--- `clerkFaceDeg` at zero -- which is where it ships -- the counter's right IS
--- the ped's right, which is the frame his sentence is written in.
---
--- ZERO IS NOT A NO-OP WORTH SKIPPING: the multiplication is what makes the
--- owner's numbers in config mean something without anybody editing Lua.
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
    local out   = tonumber(c.clerkOffsetM) or 0.0
    local right = tonumber(c.clerkRightM) or 0.0
    local face  = tonumber(c.clerkFaceDeg) or 0.0

    local rad = math.rad(h)
    local fx, fy = -math.sin(rad), math.cos(rad)
    local rx, ry =  math.cos(rad), math.sin(rad)
    return sx + fx * out + rx * right,
           sy + fy * out + ry * right,
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
-- What is on the shelf, this match, at this counter
-- ---------------------------------------------------------------------------

--- WHICH WEAPONS THIS COUNTER HOLDS FOR THE LIFE OF ONE MATCH, AND HOW MANY.
---
--- Owner, 2026-09-09:
---
---   "Each shop should start the match with a random number of weapons in
---    stock, distributed across all categories they sell. Let us say this
---    number is between 3 and 8 total. They will have no limited stock on
---    ammo."
---   "The amount of each item they have in stock should differ between shops"
---
--- ═══ THREE READINGS OF THAT SENTENCE, AND THE ONE TAKEN ═══
---
--- "Between 3 and 8 TOTAL" is read as UNITS, not as distinct models: a counter
--- rolls a total somewhere in that band and then spends it, one unit at a time,
--- across the shelf. So a shop with a 5 might hold two Carbine Rifles and three
--- other guns, or five different guns, and the two shops next door will not
--- match -- which is the second sentence, satisfied by the roll being taken
--- independently per store rather than by any extra rule.
---
--- "DISTRIBUTED ACROSS ALL CATEGORIES THEY SELL" IS A GUARANTEE, NOT A HOPE, so
--- it is spent first: one unit into each rarity band present on the shelf,
--- before a single unit is spent at random. His floor of 3 and the catalogue's
--- three bands (rare, epic, legendary) are the same number, which is what makes
--- that affordable -- the smallest legal shop is exactly one of each.
---
--- THE CATEGORY AXIS IS RARITY BECAUSE RARITY IS THE ONLY ONE THAT EXISTS.
--- `rarity` is a field on every catalogue row. Weapon CLASS -- pistols, SMGs,
--- rifles -- is a comment header in config/weapons.lua and nothing else, so a
--- class axis would have to be authored from scratch before it could be rolled
--- against. Flagged rather than assumed: if he meant class, this function is
--- where that changes and the band grouping below is the four lines that move.
---
--- AMMO IS NOT IN THE ANSWER AT ALL. "They will have no limited stock on ammo",
--- so an ammo row never appears in the returned table, and the ABSENCE is the
--- vocabulary the rest of the feature reads: nil means unlimited, a number means
--- counted. That is why every weapon row appears here even at zero -- a shelf
--- that omitted its sold-out rows would be indistinguishable from a shelf that
--- sells unlimited ones.
---
--- @param cfg table|nil   BR.Config.Gunshop
--- @param rows table|nil  the catalogue
--- @param rnd function|nil  (lo, hi) -> integer, inclusive. math.random by
---                          default; a test passes its own so the roll is a
---                          thing that can be replayed.
--- @return table  { [rowId] = count } -- weapons only, zeros included
function BR.GunshopSolve.rollStock(cfg, rows, rnd)
    local out = {}
    if type(rows) ~= 'table' then return out end
    if type(rnd) ~= 'function' then rnd = math.random end

    local guns = BR.GunshopSolve.ofKind(rows, BR.ItemKind.WEAPON)
    for i = 1, #guns do out[guns[i].id] = 0 end
    if #guns == 0 then return out end

    local c  = type(cfg) == 'table' and cfg or {}
    local lo = math.floor(tonumber(c.stockMin) or 0)
    local hi = math.floor(tonumber(c.stockMax) or 0)
    -- A CONFIG WITH THE TWO THE WRONG WAY ROUND IS A SHOP, NOT A CRASH. The
    -- owner authors both numbers by hand; swapping them is a typo with a
    -- sensible reading and the alternative is an empty shelf nobody can explain.
    if hi < lo then lo, hi = hi, lo end
    if lo < 0 then lo = 0 end
    if hi <= 0 then return out end

    local left = math.floor(tonumber(rnd(lo, hi)) or lo)
    if left <= 0 then return out end

    -- THE BANDS, IN RARITY ORDER RATHER THAN pairs() ORDER. Everything in this
    -- file that iterates a table iterates it in an authored order for the same
    -- reason: a roll that replays differently on two machines is not a roll a
    -- test can pin.
    local bands, order = {}, {}
    for i = 1, #guns do
        local r = guns[i].rarity
        if r ~= nil then
            local b = bands[r]
            if not b then
                b = {}
                bands[r] = b
                order[#order + 1] = r
            end
            b[#b + 1] = guns[i]
        end
    end
    table.sort(order, function(a, b)
        if type(a) == 'number' and type(b) == 'number' then return a < b end
        return tostring(a) < tostring(b)
    end)

    for i = 1, #order do
        if left <= 0 then break end
        local b = bands[order[i]]
        local pick = b[rnd(1, #b)]
        if pick then
            out[pick.id] = (out[pick.id] or 0) + 1
            left = left - 1
        end
    end

    while left > 0 do
        local pick = guns[rnd(1, #guns)]
        if not pick then break end
        out[pick.id] = (out[pick.id] or 0) + 1
        left = left - 1
    end

    return out
end

--- HOW MANY OF THIS ROW ARE LEFT, OR nil FOR "THIS ROW IS NOT COUNTED".
---
--- THE nil IS THE POINT. Ammo has no stock, and a counted zero and an uncounted
--- row are the two things every caller of this has to keep apart -- `0` is
--- TRUTHY in Lua, so a caller that tested the number rather than asking this
--- would read "sold out" as "in stock" without an error anywhere.
--- @param stock table|nil  { [rowId] = count } for ONE store
--- @param row table|nil
--- @return integer|nil
function BR.GunshopSolve.stockOf(stock, row)
    if type(stock) ~= 'table' or type(row) ~= 'table' then return nil end
    if row.kind ~= BR.ItemKind.WEAPON then return nil end
    local n = tonumber(stock[row.id])
    if not n then return nil end
    n = math.floor(n)
    if n < 0 then return 0 end
    return n
end

-- ---------------------------------------------------------------------------
-- Which guns take this ammo
-- ---------------------------------------------------------------------------

--- EVERY WEAPON IN THE GAME THAT FEEDS ON ONE POOL, IN AUTHORED ORDER.
---
--- Owner, 2026-09-09:
---
---   "When an ammo item is in focus in the menu, a description should be shown
---    that includes a list of all weapons that ammo is used in. This will help
---    the customer understand what ammo they need to purchase for their given
---    loadout."
---
--- ═══ "ALL WEAPONS", NOT "ALL WEAPONS ON THIS SHELF" ═══
---
--- The counter sells RARE and above. A player's loadout is mostly floor loot,
--- so the Pump Shotgun they are actually carrying is COMMON, is not for sale
--- here, and is exactly the gun they are trying to work out which box of shells
--- feeds. Listing only the shelf would answer a question nobody asked. So this
--- takes SOURCE TABLES rather than the catalogue, and the caller passes the ones
--- a player can end up holding -- BR.Config.Weapons and BR.Config.AirdropWeapons
--- are two arrays for reasons that have nothing to do with ammo.
---
--- NOTHING HERE IS COPY. Every word out of this function is a `label` the owner
--- authored in config/weapons.lua, in the order he authored it, and the only
--- character this file adds is the comma between them.
--- ONE SCAN, AND EVERY PUBLIC ANSWER BELOW IS A VIEW OF IT.
---
--- ⚠ DECLARED ABOVE ITS READERS, because a Lua local is invisible above its own
--- declaration.
---
--- THE REASON IT IS ONE FUNCTION AND NOT TWO IS A BUG THIS FEATURE ALREADY HAD.
--- client/gunshop.lua rolled a private scan over BR.Config.Weapons alone while
--- this file scanned both source tables: two answers to one question, and the
--- shorter one shipped, so every airdrop weapon was missing from every ammo
--- description. Splitting the list by what a player is carrying is a THIRD caller
--- for the same walk, and a third walk is the same bug waiting.
---
--- IT CARRIES THE id AS WELL AS THE label, which is the only thing the label-only
--- answer could not do: "is the player holding this one" is a question about ids.
--- @param pool string|nil    a BR.AmmoType value
--- @param sources table|nil  an array of weapon arrays
--- @return table  array of { id, label }, de-duplicated by id, authored order
local function ammoUserRows(pool, sources)
    local out = {}
    if type(pool) ~= 'string' or pool == '' then return out end
    if type(sources) ~= 'table' then return out end

    local seen = {}
    for i = 1, #sources do
        local list = sources[i]
        if type(list) == 'table' then
            for j = 1, #list do
                local w = list[j]
                if type(w) == 'table' and w.ammo == pool
                   and type(w.id) == 'string' and not seen[w.id] then
                    seen[w.id] = true
                    local label = type(w.label) == 'string' and w.label ~= ''
                        and w.label or w.id
                    out[#out + 1] = { id = w.id, label = label }
                end
            end
        end
    end
    return out
end

--- @param pool string|nil       a BR.AmmoType value
--- @param sources table|nil     an array of weapon arrays
--- @return table  array of label strings, de-duplicated by weapon id
function BR.GunshopSolve.ammoUsers(pool, sources)
    local rows = ammoUserRows(pool, sources)
    local out = {}
    for i = 1, #rows do out[i] = rows[i].label end
    return out
end

--- THE SAME WEAPONS, SPLIT BY WHETHER THE PLAYER IS HOLDING ONE.
---
--- Owner, 2026-09-11: "we should prefix them with 'This ammo works with your:
--- {guntypes} (new line) As well as: {otherguntypes}'", and the reason: "The
--- {guntypes} text should be blue, comma-separated, and everything else should
--- remain white. This is because the list is exhaustive to read through and we
--- should make it so they can skim, which is enabled by the colors."
---
--- ═══ THE SPLIT IS THE WHOLE FEATURE AND MUST NOT BE FLATTENED ═══
---
--- `{guntypes}` is what is IN THEIR HANDS RIGHT NOW and `{otherguntypes}` is
--- every other gun that takes the pool. Joining them back into one list would
--- leave the row saying exactly what it said before he asked, with two sentences
--- wrapped around it -- and the skim he is describing only works when the first
--- line is short and is about them.
---
--- ORDER IS THE SOURCE TABLES', IN BOTH HALVES. This is a stable partition of
--- ammoUserRows rather than a re-sort of it, so his authored class grouping in
--- config/weapons.lua survives into both lists.
---
--- `held` IS A SET OF ITEM IDS AND NOT A WEAPON TABLE, which keeps the caller's
--- job to "what is in the bag" and this function's to "which of these is that".
--- An id in it that is not a gun at all -- a throwable, a gadget -- simply matches
--- nothing, because the scan above only ever yields weapons that take the pool.
--- @param pool string|nil
--- @param sources table|nil
--- @param held table|nil  { [itemId] = true }. nil and {} both mean "nothing"
--- @return table yours   labels the player is carrying, in authored order
--- @return table others  every other label, in authored order
function BR.GunshopSolve.ammoUsersSplit(pool, sources, held)
    local rows = ammoUserRows(pool, sources)
    local yours, others = {}, {}
    local have = type(held) == 'table' and held or {}
    for i = 1, #rows do
        local r = rows[i]
        if have[r.id] then
            yours[#yours + 1] = r.label
        else
            others[#others + 1] = r.label
        end
    end
    return yours, others
end

--- The same list as one line, for a surface that has one line to put it on.
---
--- IN br_lib SO THE JOINING IS A THING A TEST CAN RUN, which is
--- BR.ShopSolve.boughtToast's stated reason for living here rather than in the
--- server file that sends it. A comma and a space is a separator, not a word.
--- @param pool string|nil
--- @param sources table|nil
--- @return string  '' when nothing takes this pool
function BR.GunshopSolve.ammoUsersLine(pool, sources)
    return table.concat(BR.GunshopSolve.ammoUsers(pool, sources), ', ')
end

--- The split, joined, for a surface that has one line per half to put it on.
---
--- THE COMMA LIVES HERE FOR THE REASON ammoUsersLine GIVES ABOVE: the joining is a
--- thing a test can run, and a `, ` assembled in client/gunshop.lua would be the
--- one character of this feature that only a playtest could check. A comma and a
--- space is a separator, not a word, which is why it is not in config either.
--- @param pool string|nil
--- @param sources table|nil
--- @param held table|nil
--- @return string yours   '' when they are carrying nothing that takes the pool
--- @return string others  '' when nothing else takes it
function BR.GunshopSolve.ammoUsersSplitLine(pool, sources, held)
    local yours, others = BR.GunshopSolve.ammoUsersSplit(pool, sources, held)
    return table.concat(yours, ', '), table.concat(others, ', ')
end

--- HIS TWO LINES, JOINED, WITH A HALF THAT CANNOT BE FILLED LEFT OFF.
---
--- ═══ NOT ONE WORD OUT OF THIS FUNCTION IS OURS ═══
---
--- `ammoDescYours` and `ammoDescOthers` are authored in config/gunshop.lua, in his
--- wording and with his colon. This chooses which of them can be said and puts a
--- line break between them, which is the same division of labour as
--- BR.GunshopSolve.poorToast and for the same reason: the alternative is a
--- concatenation in client/gunshop.lua, where the only way to see what a player
--- reads is to stand at a till in a running game.
---
--- ═══ THE THREE CASES, AND THE ONE THAT IS A JUDGEMENT ═══
---
---   BOTH HALVES FILLED -> both sentences, his line break between them.
---
---   NOTHING ELSE TAKES THE POOL -> the second sentence is dropped. "As well as:"
---   with nothing after it is a dangling sentence.
---
---   ⚠ NOTHING CARRIED -> the LEAD-IN is dropped and the bare list is returned,
---   which is the description this row has carried since L5. This is the case his
---   structure has no form for and the one place a decision was taken rather than
---   read. The alternatives were both worse: "This ammo works with your:" followed
---   by nothing, or "As well as:" with no antecedent, or a third lead-in nobody
---   wrote. Falling back to something he has already seen and approved is the only
---   one of the four that invents nothing. FLAGGED FOR HIM.
---
--- `others` IS THE WHOLE LIST IN THAT CASE, WHICH IS WHY THERE IS NO FOURTH
--- PARAMETER. Carried plus other is every gun that takes the pool, so when nothing
--- is carried `others` already IS the exhaustive list.
---
--- ═══ THE LINE BREAK IS `~n~` AND IT IS NOT COPY ═══
---
--- It is the engine's newline -- the thing "(new line)" in his message names -- and
--- the movie's own `notColours` list carries `~n`, so it survives the library and
--- is resolved by the game's formatter. client/menu.lua has that evidence.
---
--- A TEMPLATE THAT WILL NOT TAKE A STRING LEAVES THE SENTENCE OUT, exactly as
--- poorToast does: these are authored, so a `%d` in one is an authoring slip
--- rather than a runtime condition, and string.format would THROW on it while a
--- player was reading a menu.
---
--- @param cfg table|nil     BR.Config.Gunshop
--- @param yours string|nil  the carried list, ALREADY MARKED by the surface
--- @param others string|nil every other, plain
--- @return string
function BR.GunshopSolve.ammoDesc(cfg, yours, others)
    local c     = type(cfg) == 'table' and cfg or {}
    local mine  = type(yours) == 'string' and yours or ''
    local rest  = type(others) == 'string' and others or ''
    local head  = type(c.ammoDescYours) == 'string' and c.ammoDescYours or ''
    local tail  = type(c.ammoDescOthers) == 'string' and c.ammoDescOthers or ''

    if mine == '' or head == '' then return rest end

    local okHead, first = pcall(string.format, head, mine)
    if not okHead then return rest end
    if rest == '' or tail == '' then return first end

    local okTail, second = pcall(string.format, tail, rest)
    if not okTail then return first end
    return first .. '~n~' .. second
end

--- WHAT ONE WEAPON ROW SAYS ABOUT ITS AMMUNITION.
---
--- Owner, 2026-09-11: "The weapons should each have a description which reads:
--- 'This weapon uses {ammotype}. You have {number} rounds for it.'" And: "The
--- {ammotype} should be the same blue as we use above, and the number should be
--- blue as well."
---
--- BOTH HOLES ARRIVE ALREADY MARKED, for the same reason ammoDesc's do: blue is a
--- GTA text token and only the surface knows that. This function does not know what
--- color anything is and must not.
---
--- ═══ ALL OR NOTHING, WHICH IS THE ONLY HONEST SHAPE FOR ONE SENTENCE ═══
---
--- His sentence has two holes in one clause pair and there is no version of it
--- with one filled. So a row with no pool, or one where the holding could not be
--- read, says NOTHING rather than "This weapon uses . You have rounds for it."
--- Every gun on this shelf takes a pool, so the empty answer is a guard rather
--- than a state.
---
--- ⚠ `rounds` IS A STRING BY THE TIME IT ARRIVES AND THAT IS DELIBERATE. It has
--- been through BR.Menu.blue, so it is `~HC_9~42~s~` rather than 42 -- which means
--- this function cannot check it is a number and does not try. The caller owns
--- reading the holding at the moment the description is built; see the block on
--- that in client/gunshop.lua.
--- @param cfg table|nil     BR.Config.Gunshop
--- @param ammo string|nil   the pool's own label, ALREADY MARKED
--- @param rounds string|nil the player's holding, ALREADY MARKED
--- @return string  '' when the template or either hole is missing
function BR.GunshopSolve.weaponDesc(cfg, ammo, rounds)
    local c    = type(cfg) == 'table' and cfg or {}
    local tmpl = type(c.weaponDesc) == 'string' and c.weaponDesc or ''
    if tmpl == '' then return '' end
    if type(ammo) ~= 'string' or ammo == '' then return '' end
    if type(rounds) ~= 'string' or rounds == '' then return '' end

    local okFmt, line = pcall(string.format, tmpl, ammo, rounds)
    return okFmt and line or ''
end

-- ---------------------------------------------------------------------------
-- The two sentences the counter now speaks, joined where a test can read them
-- ---------------------------------------------------------------------------

--- WHAT A PLAYER WHO CANNOT AFFORD A ROW IS TOLD.
---
--- Owner, 2026-09-09:
---
---   "if they select an item they cannot afford, give them a toast that says
---    You do not have enough Volts for that item. Your balance is: {balance}
---    Volts. remember the Volts text and quantity must be our signature color."
---
--- BOTH SENTENCES ARE AUTHORED IN config/gunshop.lua and neither is written
--- here. This does the joining and the marking and nothing else -- the same
--- division of labour as BR.ShopSolve.boughtToast, for the same reason: the
--- alternative is a concatenation in server/gunshop.lua, where the only way to
--- see what a player reads is to stand at a till in a running game and be poor.
---
--- ═══ THE MARK IS TILDES AND IT IS THE ONE THIS PROJECT ALREADY HAS ═══
---
--- ui-src's KeyText paints anything between tildes with `--color-volts`. Lua
--- composes this sentence, so the mark travels with it. His instruction covers
--- both halves -- "the Volts text AND quantity" -- so the bare word in the first
--- sentence is marked in the config string, and the figure in the second is
--- marked here, where it is built.
---
--- A TEMPLATE THAT WILL NOT TAKE A STRING LEAVES THE FIRST SENTENCE ALONE.
--- `balanceToast` is authored, so a `%d` in it is an authoring slip rather than
--- a runtime condition -- but string.format would THROW on it, on the refusal
--- path, which would turn "you are broke" into a server error.
--- @param cfg table|nil       BR.Config.Gunshop
--- @param balance number|nil  what the player actually holds
--- @param currency string|nil BR.Config.Market.currency
--- @return string
function BR.GunshopSolve.poorToast(cfg, balance, currency)
    local c = type(cfg) == 'table' and cfg or {}
    local head = type(c.poorToast) == 'string' and c.poorToast or ''
    local tmpl = type(c.balanceToast) == 'string' and c.balanceToast or ''
    if tmpl == '' then return head end

    local okFmt, line = pcall(string.format, tmpl,
        '~' .. BR.ShopSolve.priceLine(balance, currency) .. '~')
    if not okFmt or type(line) ~= 'string' then return head end
    if head == '' then return line end
    return head .. ' ' .. line
end

--- WHAT A PLAYER WHO JUST BOUGHT AMMO IS TOLD.
---
--- Owner, 2026-09-09:
---
---   "when ammo is purchased show a success toast: You purchased {item} for
---    {cost}. otherwise they have no way to know anything went through."
---
--- ONE SENTENCE, AUTHORED IN config/gunshop.lua, WITH TWO HOLES. `{item}` is
--- BR.GunshopSolve.menuLabel -- the owner's own label out of config/weapons.lua
--- or config/loot.lua, plus the quantity mark an ammo row already carries -- and
--- `{cost}` is BR.ShopSolve.priceLine, marked for the currency's color the way
--- every other figure in a toast in this game is.
---
--- WEAPONS GET NOTHING HERE, and that is his scoping rather than an omission:
--- he asked for this "when ammo is purchased" and gave the weapon purchase a
--- clerk animation instead. The caller decides; this function will compose a
--- line for any row it is handed.
--- @param cfg table|nil       BR.Config.Gunshop
--- @param row table|nil       the catalogue row that was bought
--- @param currency string|nil
--- @return string  '' when no sentence is authored
function BR.GunshopSolve.boughtToast(cfg, row, currency)
    local c = type(cfg) == 'table' and cfg or {}
    local tmpl = type(c.boughtToast) == 'string' and c.boughtToast or ''
    if tmpl == '' then return '' end

    local item = BR.GunshopSolve.menuLabel(row)
    local cost = '~' .. BR.ShopSolve.priceLine(
        type(row) == 'table' and row.price or 0, currency) .. '~'

    local okFmt, line = pcall(string.format, tmpl, item, cost)
    if not okFmt or type(line) ~= 'string' then return '' end
    return line
end

-- ---------------------------------------------------------------------------
-- May this player buy this, right now?
-- ---------------------------------------------------------------------------

--- Refusal reasons. Values are what the SERVER logs.
---
--- THESE ARE LOG KEYS AND NOT COPY. Two of them now have a player-facing
--- sentence attached at the call site -- `afford` speaks the owner's own toast
--- out of config/gunshop.lua, `ammofull` borrows the sentence the loot pickup
--- already refuses with -- but the sentence lives where it is sent, never here.
BR.GunshopSolve.Refusal = {
    OFF    = 'gunshopoff',  -- no stores: the feature does not exist
    STATE  = 'notplaying',  -- the counter is open during a live match only
    NOROW  = 'nosuchitem',  -- the client named something that is not for sale
    NOTAT  = 'notatcounter',-- the player is not standing at a counter
    STOCK  = 'outofstock',  -- this counter has none of these left this match
    FULL   = 'ammofull',    -- the pool this fills is already at its cap
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
--- ═══ TWO NEW TERMS, AND BOTH RANK ABOVE THE MONEY ═══
---
--- `stock` and `ammoFull` are asked BEFORE `afford`, and the order is the
--- sentence the player gets. Somebody broke standing in front of an empty shelf
--- is told the shelf is empty, not that they are broke -- being told the price
--- of a thing that is not for sale is the worse of the two answers, and it is
--- the one a naive ordering gives.
---
--- `stock` IS nil FOR "NOT COUNTED", NEVER ZERO. Ammo has no stock (owner: "They
--- will have no limited stock on ammo"), so its term is absent rather than
--- large. `0` is TRUTHY in Lua, so the nil and the zero have to be told apart by
--- an explicit `~= nil`, which is what BR.GunshopSolve.stockOf exists to make
--- one decision rather than one per caller.
---
--- @param st table  { on, matchState, playerState, atCounter, row, stock,
---                    ammoFull, balance, price }
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

    -- AN EXPLICIT nil TEST, BECAUSE `0` IS TRUTHY IN LUA. `if st.stock then` is
    -- true for a sold-out shelf and would sell the gun that is not there.
    if st.stock ~= nil and (tonumber(st.stock) or 0) <= 0 then
        return false, BR.GunshopSolve.Refusal.STOCK
    end

    -- Owner, 2026-09-09: "If someone is already carrying the max of an ammo ...
    -- reject the purchase and give them a toast explaining they already have the
    -- max (same as we do for loot pickups)". Which retires the flag in
    -- server/gunshop.lua's `deliver`: buying Heavy Ammo on a full heavy pool
    -- used to take the Volts and leave a pile on the floor, and the note there
    -- said the fix was a rule the owner had not made. He has made it.
    if st.ammoFull == true then return false, BR.GunshopSolve.Refusal.FULL end

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
