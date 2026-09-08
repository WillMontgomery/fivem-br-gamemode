-- The in-match Ammu-Nation weapon shop (#274): where the counters are, what is
-- sold over them, and what it costs.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- THE GOVERNING RULE. IF YOU READ ONE PARAGRAPH, READ THIS
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-09-08:
--
--   "config/shop.lua's header is for the pregame shop, where this is still
--    true. an in-game shop is different. also we're not planning to (as of now)
--    sell items which could not otherwise be found in the wild - just a
--    convenience with a fee."
--
--   "in-match wallet should not exist, agreed. the player has one Volts bank."
--
-- So the rule this feature lives or dies by is one sentence:
--
--     NOTHING IS SOLD HERE THAT CANNOT BE FOUND IN THE WILD.
--
-- The shop is a CONVENIENCE WITH A FEE. A player standing at this counter is
-- paying to skip the search, not to buy something the map would never have
-- given them. That is the whole of what stops a saved Volts balance turning
-- into an advantage, and it is the same argument config/shop.lua's header makes
-- about the warmup showroom -- except that showroom is a PREGAME shop, where the
-- worst case is transport, and this one opens in the middle of a fight.
--
-- ═══ AND NOTHING IN CODE ENFORCES IT, WHICH IS WHY IT IS WRITTEN HERE ═══
--
-- There is no line of Lua anywhere in this repository that can look at a
-- catalogue row and tell you whether the thing it names is findable on the map.
-- The rarity buckets, the airdrop shelf, the melee list and the crate tables are
-- four separate structures and "findable" is a property of the relationship
-- between them, not of any one row.
--
-- SO THE CATALOGUE IS DERIVED RATHER THAN AUTHORED, and that is the closest
-- thing to enforcement available. This file writes down NO list of weapons.
-- `BR.GunshopSolve.catalogue` walks BR.Config.Weapons -- the array the world
-- loot roll itself is built from -- and keeps the rows at BR.Rarity.RARE and
-- above. A weapon is on sale here BECAUSE it is in the table the map rolls
-- against, and the day the owner moves a rarity, adds a gun or removes one, the
-- shop moves with him and nobody has to remember that it exists.
--
-- A HAND-COPIED SECOND LIST IS THIS PROJECT'S SIGNATURE DEFECT. Two
-- representations of one fact, drifting apart quietly -- see the same paragraph
-- in shared/shop_solve.lua's header, which was written after it had already
-- happened. A copied weapon list here would go stale the first time a rarity
-- changed, and the symptom would be a shop selling a gun the map no longer
-- has, which is exactly the thing the owner's sentence forbids.
--
-- ═══ WHAT IS DELIBERATELY *NOT* SOLD ═══
--
--   BR.Config.AirdropWeapons -- RPG, grenade launcher, railgun, minigun. The
--   owner ruled on 2026-08-21 that these are AIRDROP-ONLY: "We just spawn normal
--   (ultra rare) loot and they can pick it up if they want to." They are in no
--   rarity bucket, so no world roll can ever produce them, so THE ONLY WAY TO
--   HOLD ONE IS TO REACH A SUPPLY DROP. Selling one over a counter would be
--   selling exactly the thing that cannot otherwise be found -- a breach of the
--   rule at the top of this file, not a balance question -- and it would also
--   undo the reason the airdrop is worth crossing the map for.
--
--   Deriving from BR.Config.Weapons excludes them for free, because that is the
--   array they are deliberately absent from (see the long note above
--   BR.Config.AirdropWeapons). `BR.GunshopSolve.catalogue` ALSO takes the
--   airdrop table and rejects by id anyway, so the exclusion survives somebody
--   later passing the merged BR.Config.WeaponById in by mistake.
--
--   BR.Config.Melee -- brass knuckles through battle axe. A SEPARATE TABLE from
--   BR.Config.Weapons, so deriving from Weapons excludes the whole list without
--   a single line of filtering. THAT IS DELIBERATE AND NOT AN ACCIDENT OF THE
--   FILTER: melee is a crate prize (user call, 2026-08-07), it has no magazine
--   and no ammo pool, and an Ammu-Nation counter selling a machete is not a
--   thing anybody asked for. If the owner ever wants them, it is a second
--   source table passed to the solver, not an edit to this note.
--
--   BR.Config.Throwables -- grenades, molotovs, sticky bombs, smoke. Also a
--   separate table and also excluded for free. Not ruled on either way; they are
--   findable in the wild, so the rule at the top does not forbid them. If they
--   are wanted, they are a third source table. Flagged rather than assumed.
--
--   Everything below BR.Rarity.RARE. Common and uncommon guns are what a player
--   trips over in the first ninety seconds of a match; paying Volts for a Micro
--   SMG is not a convenience anybody would use. The floor is named once, by
--   `BR.GunshopSolve.minRarity`, rather than spelled as a literal inside a
--   filter, so moving it is one line.
--
-- ═══ ONE VOLTS BANK, AND NO SECOND PURSE ═══
--
-- "in-match wallet should not exist, agreed. the player has one Volts bank."
--
-- So this feature adds NO currency, NO match-local balance and NO pickup that
-- means money. A purchase is debited from the saved balance the market already
-- owns (BR.Config.Market.currency is the one place the word "Volts" is spelled),
-- exactly as the warmup showroom's purchases are. There is nothing here to keep
-- in step with anything, because there is only one pot.
--
-- ═══════════════════════════════════════════════════════════════════════════

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Gunshop = {
    -- WITH NO STORES OR NO CATALOGUE THE FEATURE IS INERT RATHER THAN BROKEN.
    -- BR.Config.Rescue.points' rule, applied a third time (config/shop.lua was
    -- the second). See BR.GunshopSolve.enabled.
    enabled = true,

    -- ------------------------------------------------------------------
    -- THE ELEVEN COUNTERS
    -- ------------------------------------------------------------------
    --
    -- Anchors read out of GTA's own `shop_controller` script data and
    -- cross-checked against two independent third-party transcriptions of the
    -- same set (ox_inventory's shop locations and qb-shops' `ammunation`
    -- config). The owner has confirmed these look right.
    --
    -- `heading` IS THE COUNTER'S FACING, not a clerk's and not a player's. What
    -- stands where relative to it is the client's decision and is deliberately
    -- not made here.
    --
    -- ═══════════════════════════════════════════════════════════════════════
    -- THE `z` IS THE TABULATED ANCHOR AND IT IS NOT A CLERK HEIGHT. DO NOT
    -- AUTHOR ONE.
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- THE SOURCES DISAGREE WITH EACH OTHER BY UP TO ABOUT 1.1 METRES on these z
    -- values, and the disagreement is not noise -- it is that they do not all
    -- mean the same thing by "the shop's z". Some tables carry the FLOOR of the
    -- interior at the counter. Others carry the coordinate a standing ped was
    -- recorded at, which is that floor plus roughly the distance from a ped's
    -- feet to its center. A metre is the difference between a clerk standing on
    -- the floor, a clerk buried to the waist in it, and a clerk floating.
    --
    -- THERE IS NO WAY TO TELL WHICH ONE ANY GIVEN ROW IS FROM THE NUMBER ALONE,
    -- and picking wrong is a fault that only a playtest can see -- eleven
    -- interiors, one of which will look fine while the other ten do not. The
    -- warmup showroom already paid for this lesson from the other end: `veto`
    -- shipped at an authored z that probed a metre out, and it cost three
    -- playtest rounds and a whole investigation before anybody looked at the
    -- ground instead of at the table (see the note on that row in
    -- config/shop.lua).
    --
    -- SO NOTHING HERE AUTHORS A CLERK z. THE CLIENT GROUND-PROBES. The engine
    -- knows where the floor of an interior is and no surveyed figure can be more
    -- accurate than asking it. This table carries the ANCHOR -- which is
    -- correct as an x/y position and as a rough height for starting a probe --
    -- and the override slots below, and nothing else.
    --
    -- `zOverride` IS THE ESCAPE HATCH AND IT SHOULD STAY EMPTY. An absolute
    -- world z that skips the probe entirely, for the one interior where the
    -- probe is eventually found to be wrong (a mezzanine, a prop the ray
    -- catches, an interior that has not streamed). Authoring one is a decision
    -- to trust a typed number over the engine, so it wants a reason beside it.
    --
    -- `probeFromM` IS THE OTHER SLOT: how far ABOVE the anchor the client starts
    -- its downward probe, when this store's anchor turns out to be the standing
    -- figure rather than the floor and the default start is already below the
    -- ceiling of something. Also nil everywhere, also per-store.
    --
    -- `range = true` marks the two SHOOTING-RANGE interiors. Those two buildings
    -- have a second room behind the shop floor, so anything that reasons about
    -- what is inside the store (a probe ceiling, a spawn area, an interior id)
    -- has a case here it does not have at the other nine.
    --
    -- `clerk = 'country'` marks the two that want the country clerk model rather
    -- than the city one. See `clerkModels` below.
    --
    -- NO `label`. The store ids are the districts they stand in and are enough
    -- to name a row in a console line; a display name is COPY, the owner has not
    -- written any for this feature, and inventing player-facing text is a
    -- standing rule against, not a gap to fill. Whoever builds the UI should ask
    -- him for the words rather than reading a guess out of this file.
    stores = {
        { id = 'pillbox',  x =    23.6862, y = -1106.4610, z =  29.9159, heading = 160.0000, range = true },
        { id = 'sandy',    x =  1693.5720, y =  3761.6010, z =  34.8242, heading = 227.3919, clerk = 'country' },
        { id = 'hawick',   x =   252.8583, y =   -51.6284, z =  70.0600, heading =  69.9999 },
        { id = 'lamesa',   x =   841.0564, y = -1034.7620, z =  28.3137, heading =   0.0000 },
        { id = 'paleto',   x =  -330.2908, y =  6085.5480, z =  31.5737, heading = 224.9999, clerk = 'country' },
        { id = 'seoul',    x =  -660.9294, y =  -934.1031, z =  21.9481, heading = 180.0000 },
        { id = 'morning',  x = -1304.9760, y =  -395.8181, z =  36.8147, heading =  75.7783 },
        { id = 'route68',  x = -1117.6120, y =  2700.2640, z =  18.6730, heading = 221.8271 },
        { id = 'chumash',  x = -3172.5110, y =  1089.4120, z =  20.9576, heading = 246.5813 },
        { id = 'palomino', x =  2566.5920, y =   293.1332, z = 108.8538, heading =   0.0000 },
        { id = 'cypress',  x =   808.8609, y = -2158.5080, z =  29.7379, heading =   0.0000, range = true },
    },

    --- THE TWO CLERK MODELS, NAMED HERE BECAUSE THEY ARE DATA.
    ---
    --- Rockstar ships two Ammu-Nation shopkeepers and uses the country one at
    --- the rural stores. Which store gets which is the `clerk` field above; the
    --- model strings are here so the client resolves a key rather than carrying
    --- a model name of its own.
    ---
    --- UNVERIFIED IN GAME AND WORTH ONE GLANCE. These are the model names the
    --- community resources use for these two peds; nothing in this repository
    --- has loaded either of them yet. A model that will not stream is a counter
    --- with nobody behind it, so whoever writes the client should say so on the
    --- console rather than failing silently, and should treat a failed request
    --- as "no clerk" rather than as an error.
    clerkModels = {
        city    = 's_m_y_ammucity_01',
        country = 's_m_m_ammucountry',
    },

    --- HOW CLOSE "AT THE COUNTER" IS, IN METRES, MEASURED IN 2-D.
    ---
    --- Every reach in this project is flat (see BR.ShopSolve.nearest), and here
    --- it matters more than usual: a player is on the shop floor and the anchor's
    --- z is of uncertain meaning by up to a metre, so a 3-D distance would be
    --- measuring against a number this file explicitly refuses to trust.
    ---
    --- 2.5m IS A FIRST CUT AND IS THE OWNER'S TO MOVE. The eleven counters are
    --- not near each other -- the closest pair is districts apart -- so unlike
    --- the warmup showroom there is no ambiguity for the radius to resolve and
    --- nothing here has to be tight. It only has to mean "standing at the
    --- counter and not walking past the door".
    reachM = 2.5,

    -- ------------------------------------------------------------------
    -- WHAT IT COSTS
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-09-08:
    --
    --   "ammo should be cheap (20-50 Volts), and prices should be a range per
    --    weapon class - rare is 100-150 Volts, epic is 200-275 Volts, and
    --    legendary is 400-500 Volts."
    --
    -- HIS BANDS ARE RANGES, SO THE WEAPONS INSIDE A BAND ARE SPREAD ACROSS IT
    -- rather than all sharing one number. Every price below is a LITERAL and not
    -- a formula, deliberately: a formula would mean he could not move one gun
    -- without moving its neighbours, and moving one gun by hand is the entire
    -- reason a price table exists.
    --
    -- ═══ THE AXIS IS PER-SHOT `damage`, ASCENDING ═══
    --
    -- Within each band the guns are sorted by the `damage` field in
    -- config/weapons.lua and priced from the bottom of the band to the top. The
    -- damage figure is quoted on every line, so the ordering is checkable
    -- against the source table without opening it.
    --
    -- WHY THAT AXIS AND NOT SUSTAINED DPS. `damage / minInterval` is the more
    -- sophisticated number and both fields are right there, and it was rejected
    -- for two reasons. It reorders the band in ways that read as wrong to the
    -- person paying -- the Heavy Revolver, a 97-damage hand cannon, prices
    -- BELOW the SMG Mk II on a DPS axis -- and, more importantly, `damage` is
    -- the number the server's own damage model and anti-cheat already run on
    -- (BR.Config.ExpectedDamage), so pricing on it means the shop's order and
    -- the game's order cannot disagree.
    --
    -- WHERE THE AXIS READS ODDLY, SAID OUT LOUD. Per-shot damage is not
    -- comparable ACROSS weapon classes in a fight: a shotgun's 72 is one slow
    -- shell and a rifle's 33 is ten rounds a second. So the Assault Shotgun and
    -- the Heavy Revolver land at the expensive end of RARE, and the Sniper Rifle
    -- and Revolver Mk II at the expensive end of EPIC, on a number that
    -- overstates them. That is the axis being consistent rather than being
    -- right, and those four are the first rows the owner is likely to want to
    -- move. Moving one is one integer.
    --
    -- TIES BREAK ON THE AUTHORED ORDER of BR.Config.Weapons, which is the class
    -- grouping he already reads that file in.
    --
    -- ═══ A WEAPON WITH NO PRICE IS DROPPED, NOT SOLD FOR NOTHING ═══
    --
    -- The catalogue is derived and this table is authored, so the two can come
    -- apart in one direction: he adds a gun at RARE and does not price it.
    -- BR.GunshopSolve.catalogue REJECTS that row and BR.Config.Gunshop.build
    -- prints it, the way server/shop.lua's resolve() reports its rejects. A
    -- half-priced catalogue is a HALF-STOCKED SHOP rather than a crash, and the
    -- console says which gun and why.
    prices = {
        -- RARE -- his band is 100-150. Eleven weapons, five Volts apart.
        smgmk2         = 100,  -- damage 26
        assaultsmg     = 105,  -- damage 27
        combatpdw      = 110,  -- damage 28
        carbinerifle   = 115,  -- damage 32
        gusenberg      = 120,  -- damage 32
        assaultrifle   = 125,  -- damage 33
        advancedrifle  = 130,  -- damage 34
        mg             = 135,  -- damage 34
        heavypistol    = 140,  -- damage 40
        assaultshotgun = 145,  -- damage 72, one slow shell -- see the note above
        revolver       = 150,  -- damage 97, one slow shot -- see the note above

        -- EPIC -- his band is 200-275. Ten weapons, spread across it.
        carbinemk2     = 200,  -- damage 36
        assaultmk2     = 210,  -- damage 37
        specialcarbine = 215,  -- damage 38
        combatmg       = 225,  -- damage 38
        marksmanrifle  = 235,  -- damage 65
        combatshotgun  = 240,  -- damage 80
        heavyshotgun   = 250,  -- damage 88
        pumpshotgunmk2 = 260,  -- damage 92
        revolvermk2    = 265,  -- damage 99, one slow shot -- see the note above
        sniperrifle    = 275,  -- damage 101, one slow shot -- see the note above

        -- LEGENDARY -- his band is 400-500. Four weapons.
        combatmgmk2    = 400,  -- damage 40
        militaryrifle  = 435,  -- damage 42
        marksmanmk2    = 465,  -- damage 70
        heavysniper    = 500,  -- damage 216
    },

    -- ------------------------------------------------------------------
    -- AMMO: ALL FIVE POOLS
    -- ------------------------------------------------------------------
    --
    -- "ammo should be cheap (20-50 Volts)". All five of BR.Config.AmmoOrder are
    -- sold, because all five are found in the wild -- the floor loot table is
    -- 74% ammo by weight (config/loot.lua) and every pool is in it.
    --
    -- ═══ THE PRICE ORDER IS SCARCITY, AND THE TWO SCARCITY NUMBERS AGREE ═══
    --
    -- There are two independent measures of how freely a pool is meant to flow,
    -- and they were both authored years apart by different decisions:
    --
    --   the GROUND PICKUP    BR.Config.AmmoPickups[pool].amount -- how many
    --                        rounds one piece of ammo on the floor is worth.
    --   the INVENTORY CAP    BR.Config.AmmoCaps[pool] -- how much of it a player
    --                        may hold at once.
    --
    -- They put the five pools in EXACTLY THE SAME ORDER: smg, medium, light,
    -- shells, heavy, from most freely available to least. Two numbers that were
    -- not written to agree, agreeing, is a better axis than either one alone,
    -- so that is the order the prices run in.
    --
    -- THE GAPS ARE UNEVEN BECAUSE THE SCARCITY IS. Light, SMG and medium sit at
    -- caps of 300-400 and pickups of 36-60; shells and heavy sit at caps of 120
    -- and 60 and pickups of 16 and 12. That is a cliff, not a slope, and the
    -- price steps at the same place rather than pretending the five pools are
    -- evenly spaced.
    --
    -- ═══ THE BUNDLE SIZE IS THE OWNER'S CALL AND HE HAS NOT MADE IT ═══
    --
    -- ─────────────────────────────────────────────────────────────────────
    --  NEEDS HIS CONFIRMATION: HOW MUCH AMMO ONE PURCHASE BUYS.
    -- ─────────────────────────────────────────────────────────────────────
    --
    -- THE DEFAULT IS ONE GROUND PICKUP'S WORTH, and it is authored as a RULE
    -- rather than as five copied integers: `bundle` is nil on every row below,
    -- and BR.GunshopSolve reads BR.Config.AmmoPickups[pool].amount when it is.
    -- Writing the five numbers out here would be a second copy of a table that
    -- already exists, which is the defect the header of this file is about.
    --
    -- WHY THAT DEFAULT. It is the rule at the top of this file made literal: a
    -- purchase hands over EXACTLY the stack the player would have picked up off
    -- the floor, so the counter is a convenience and demonstrably nothing more.
    -- Any other number is a judgement about pacing that only the owner can make.
    --
    -- WHAT HE SHOULD JUDGE IT AGAINST -- both numbers are quoted per row below:
    -- the pickup amount is how much a single find is worth, and the cap is how
    -- many of these bundles it takes to fill the pool from empty. Heavy is the
    -- one to look at first: at 12 a bundle and a cap of 60, filling a Heavy
    -- Sniper from empty is five purchases and 250 Volts, which may well be more
    -- transactions than he wants at a counter in the middle of a match.
    --
    -- `bundle` IS THE PER-POOL OVERRIDE. An integer on any row below pins that
    -- pool and leaves the other four deriving. That is where his answer goes.
    --
    -- KEYED BY BR.AmmoType, NOT BY THE STRING, exactly as BR.Config.AmmoPickups
    -- and BR.Config.AmmoCaps are keyed. Five bare 'light'/'smg' literals here
    -- would be the pool vocabulary written down a second time, in a file that
    -- has no reason to know how it is spelled.
    ammo = {
        --  pool                       price      pickup   cap   bundles to fill
        [BR.AmmoType.SMG]    = { price = 20 },  --   60     400   6.7
        [BR.AmmoType.MEDIUM] = { price = 25 },  --   45     350   7.8
        [BR.AmmoType.LIGHT]  = { price = 30 },  --   36     300   8.3
        [BR.AmmoType.SHELLS] = { price = 40 },  --   16     120   7.5
        [BR.AmmoType.HEAVY]  = { price = 50 },  --   12      60   5.0
    },
}

--- BUILD THE CATALOGUE, AND SAY WHAT WAS THROWN OUT OF IT.
---
--- ═══ A FUNCTION, NOT A LOOP AT THE BOTTOM OF THIS FILE, AND THE REASON IS
---     LOAD ORDER ═══
---
--- br_lib's fxmanifest loads `config/*.lua` as a GLOB, and the order a glob is
--- expanded in is the platform's business rather than anything this file can
--- see. `gunshop` sorts BEFORE `weapons` alphabetically, so at this file's own
--- load BR.Config.Weapons may not exist yet -- and a catalogue derived from a
--- table that is not there is an EMPTY SHOP with no error anywhere.
---
--- config/shop.lua's `register` is a function for the mirror-image version of
--- the same hazard (it writes into a table config/loot.lua later reassigns).
--- Same shape, same reason: br_core's own gunshop files call this once at their
--- own resource start, by which time every br_lib script is up whatever order
--- they ran in.
---
--- IDEMPOTENT, so two callers cost one build and ONE set of console lines. The
--- client and the server both need the catalogue and neither should have to
--- know whether the other went first.
---
--- @return table rows     the usable catalogue, in BR.Config.Weapons order,
---                        ammo last
--- @return table rejects  { { id, why } } -- rows that are not for sale
function BR.Config.Gunshop.build()
    local G = BR.Config.Gunshop
    if G.rows then return G.rows, G.rejects end

    local rows, rejects = BR.GunshopSolve.catalogue(G, {
        weapons     = BR.Config.Weapons,
        -- THE EXCLUSION, PASSED AS THE REAL TABLE. Deriving from
        -- BR.Config.Weapons already excludes the airdrop shelf, because that is
        -- the array it is deliberately absent from -- this is the belt to that
        -- braces, and it costs nothing because it is the SAME table the airdrop
        -- reads rather than a list of four names retyped here.
        airdropOnly = BR.Config.AirdropWeapons,
        ammoOrder   = BR.Config.AmmoOrder,
        ammoPickups = BR.Config.AmmoPickups,
    })

    -- SAID OUT LOUD, ALWAYS. server/shop.lua's resolve() sets the precedent and
    -- the argument is the same: a row that was silently dropped is a gun the
    -- owner priced, cannot see on the shelf, and has no way to ask about.
    for i = 1, #rejects do
        print(('^3[br_lib] gunshop: "%s" is not for sale -- %s^7')
            :format(tostring(rejects[i].id), tostring(rejects[i].why)))
    end

    if #rows == 0 then
        print('[br_lib] gunshop: no catalogue -- the gun shops are inert')
    end

    G.rows, G.rejects = rows, rejects
    return rows, rejects
end
