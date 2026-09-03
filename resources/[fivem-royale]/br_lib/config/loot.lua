-- Loot tables, consumables and spawn budgets.
--
-- Every prop referenced here is vanilla GTA V. That is a hard constraint on this
-- project: custom assets would need conversion work, and the whole loot system is
-- designed to need none.
--
-- The five vanilla prop_bodyarmour_0X models happen to map one-to-one onto the
-- five rarity tiers, which gives shields a readable visual language for free.

BR = BR or {}
BR.Config = BR.Config or {}

local R = BR.Rarity

--- `plural` IS THE NAME A REFUSAL USES, and it lives here rather than in the
--- message so the sentence is written once (#171). The old refusal built its
--- own by sticking an "s" on `label`, against the consumable table alone --
--- which is why a player holding three grenades was told "You can only carry 0
--- of thoses." Anything without this row falls back to `label .. 's'`, which is
--- right for every name in the game today and wrong the moment one of them
--- isn't. See BR.Loot.refusalText in br_core/server/loot.lua.
BR.Config.Consumables = {
    {
        -- THE SMALL ONE IS THIS ROW, AND THE CONFIG SAYS SO RATHER THAN THE
        -- NAME (#166). `minishield` reads as the smaller tier, but the fields
        -- are what decide it: 25 armour to a cap of 50, against the 50-to-100
        -- of the row below. Anything keyed off "which shield is small" reads
        -- armourCap, not the id.
        id = 'minishield', label = 'Small Shield', plural = 'Small Shields',
        rarity = R.COMMON,
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_bodyarmour_02',
        useMs = 3000, maxStack = 6,
        armour = 25, armourCap = 50,   -- small potions only take you to half shield

        -- HALF SIZE ON THE GROUND (owner, 2026-08-17: "can we make small
        -- shields literally spawn as a smaller prop? like same prop but
        -- physically scaled to 50% the size?").
        --
        -- WHY IT MATTERS NOW: the Shield below moved RARE -> UNCOMMON on the
        -- same day, taking it from a crate in 9 to a crate in 3.3, so both
        -- tiers are on the floor far more often and telling them apart before
        -- you walk over one is suddenly worth something.
        --
        -- HOW IT IS DONE, AND WHY IT IS A NUMBER RATHER THAN A MODEL: GTA V
        -- has no entity-scale native (client/loot.lua has said so since the
        -- take animation wanted one). The only lever is the transform matrix,
        -- so the client normalises the prop's three axis vectors and rescales
        -- them -- see applyPropScale in br_core/client/loot.lua. That scales
        -- the RENDER only, never a collision box, which is free here because
        -- loose floor items are spawned with collision switched off already.
        --
        -- THE TWO TIERS STILL USE DIFFERENT MODELS, DELIBERATELY. The owner
        -- asked for one model at two sizes; leaving the models distinct means
        -- that if the matrix scale turns out not to render on this build, the
        -- tiers stay as distinguishable as they are today rather than becoming
        -- identical. Merging them to prop_bodyarmour_06 is a one-line
        -- follow-up once a playtest confirms the scale bites.
        --
        -- /brpropscale minishield <k> retunes this live, in game, and prints
        -- the line to paste back here -- the same ruler /brlabel is.
        propScale = 0.5,
    },
    {
        -- UNCOMMON, NOT RARE (owner, 2026-08-17: "seems shield is a very rare
        -- item - took me 10 crates to get one. That should be increased").
        --
        -- HIS TEN CRATES WERE NOT BAD LUCK -- THEY WERE THE TABLE. At RARE a
        -- crate held a Shield 11.1% of the time across a whole match layout,
        -- which is one in nine. The report and the model agree to within a
        -- crate, so there was nothing to explain away.
        --
        -- AND THE RARITY FIELD IS THE ONLY LEVER THAT COULD MOVE IT. There is
        -- no per-item weight in this table: BR.LootPickOfRarity picks UNIFORMLY
        -- from a rarity bucket (rng:pick, not rng:weighted), so an item's share
        -- of consumable rolls is decided entirely by which rarity BANDS it owns.
        -- The Shield owned exactly one, RARE, worth 27% of consumable rolls at
        -- crate tier -- already the largest single share of the four
        -- consumables, which is why the kind weight below could not fix this on
        -- its own: reaching one crate in three that way needs CONSUMABLE at ~46
        -- out of 100, which would take crate ammo to almost nothing.
        --
        -- Moving it to UNCOMMON widens the band to UNCOMMON *and* RARE, because
        -- the bucket walk goes DOWN: with RARE now empty, a RARE consumable
        -- roll falls through to this. 27% -> 55% of consumable rolls, which is
        -- a crate in 3.3 rather than a crate in 9.
        --
        -- WHAT IT COSTS: the Shield now renders GREEN/Uncommon rather than
        -- blue/Rare. That is the whole cost -- rarity on a CONSUMABLE is
        -- presentation only. RarityInfo.damageMult is read in exactly one place
        -- (config/weapons.lua's damage calc) and a consumable never reaches it;
        -- the 50 armour and the 100 cap are fields on this row, not functions of
        -- the tier. The other half of the cost is inside the consumable bucket:
        -- Small Shield and Bandage lose the UNCOMMON fall-through they used to
        -- collect, which the kind weight below is raised to offset.
        --
        -- IT IS ALSO THE GENRE'S OWN MAPPING, which is worth saying because it
        -- means this is not a number bent to hit a target: Fortnite ships Small
        -- Shield Potion as Common and Shield Potion as Uncommon, and a 50-point
        -- shield is a staple you expect to find, not a prize.
        id = 'shield', label = 'Shield', plural = 'Shields', rarity = R.UNCOMMON,
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_bodyarmour_06',
        useMs = 5000, maxStack = 3,
        armour = 50, armourCap = 100,
    },
    {
        id = 'bandage', label = 'Bandage', plural = 'Bandages', rarity = R.COMMON,
        -- The small medical crate: reads as "a bit of health" on the floor
        -- without being mistaken for the full kit (user-sourced, 2026-08-05).
        kind = BR.ItemKind.CONSUMABLE, prop = 'xm_prop_smug_crate_s_medical',
        useMs = 4000, maxStack = 3, carryMax = 3,
        health = 15, healthCap = 75,   -- bandages cannot finish the job
        -- HEALING COMES OUT OF CRATES, never off the floor (user call,
        -- 2026-08-06). Health is the resource a fight is fought with, so
        -- finding it should cost the exposure of standing at a container --
        -- and later, of driving to a reboot van. Tripping over a bandage in
        -- the street undoes both.
        chestOnly = true,
    },
    {
        id = 'medkit', label = 'Med Kit', plural = 'Med Kits', rarity = R.EPIC,
        -- The med bag: visibly the bigger of the two.
        kind = BR.ItemKind.CONSUMABLE, prop = 'xm_prop_x17_bag_med_01a',
        useMs = 8000, maxStack = 3, carryMax = 3,
        health = 100, healthCap = 100,
        chestOnly = true,
    },
    {
        -- ═══ THE REPAIR KIT (#228) ═══
        --
        --   "Repair kit should spawn in loot crates, inventory item, maxCarry
        --    1, can be used on the fly to repair any vehicle once."
        --                                          -- owner, 2026-08-23
        --
        -- ═══ `useMs = 0` -- "ON THE FLY" READ AS INSTANT, AND ZERO IS A LENGTH
        --     RATHER THAN AN ABSENCE ═══
        --
        -- server/inventory.lua's rule is that "a consumable is usable through
        -- the inventory exactly when it declares how long using it takes", and
        -- that sentence is left true word for word: this one declares that using
        -- it takes NO time. It is not the CPR kit's `nil`, which means "this item
        -- is not reachable from a keypress at all" and is still refused there.
        --
        -- WHY INSTANT RATHER THAN A CHANNEL. The petrol station is a HOLD while
        -- parked; "on the fly" is the owner drawing the contrast with it. A
        -- channel would also have been defensible -- it is a press-and-wait, not
        -- a hold -- but instant is what makes the item usable in the one moment
        -- it exists for, which is a smoking engine in a chase. It also deletes
        -- the shop car's whole class of bug: press-time and effect-time are the
        -- same line, so there is no window in which the kit is spent and the
        -- rules then change under it.
        --
        -- ═══ `repairVeh` IS WHAT IT DOES, AND IT IS THE `shopCar` SHAPE ═══
        --
        -- A consumable whose effect is not a number on the ped names that effect
        -- with a field, and server/inventory.lua branches on the field and knows
        -- nothing else about it. `shopCar` established that for #224; this is the
        -- second one. The value is `true` rather than a number because the kit
        -- always does THE WHOLE JOB -- see below.
        --
        -- ═══ THE FULL JOB, NOT A FRACTION ═══
        --
        -- At a pump, letting go early buys part of the health back and keeps the
        -- dents (client/fuel.lua: the cosmetic pass fires on the frame the body
        -- reaches full). A kit is one press and cannot be let go of, so it grants
        -- BR.Config.Fuel.healthMax -- enough to cap all three pools, which is
        -- what makes the dents pop and the bullet decals wash. THAT NUMBER IS
        -- NOT COPIED HERE: server/inventory.lua reads it off the fuel config, so
        -- the kit and the pump cannot drift apart, and a partial kit is one field
        -- on this row if the owner ever wants one.
        --
        -- ═══ RARITY IS LEGENDARY, AND IT IS A CHOICE THE OWNER HAS NOT MADE ═══
        --
        -- #228 has never named one. LEGENDARY is picked because it is the only
        -- band that does not quietly undo a tuning decision already in this file:
        --
        --   RARE     the bucket walk goes DOWN, so RARE is empty ONLY so that a
        --            RARE roll falls through to the Shield. Filling it takes the
        --            Shield from 55% of consumable rolls back to ~27% -- exactly
        --            the number the owner complained about on 2026-08-17.
        --   UNCOMMON the same loss, from the other side.
        --   EPIC     halves the Med Kit, whose share the KindWeights note above
        --            was raised specifically to protect.
        --   COMMON   a one-shot full vehicle repair as the most findable item in
        --            the game, and a third off the Bandage.
        --
        -- WHAT LEGENDARY COSTS, STATED: the Med Kit loses the LEGENDARY
        -- fall-through it collects today -- 1% of consumable rolls at tier 1 and
        -- 5% at tier 3, so about a quarter of its share at a hot drop. That is
        -- the smallest bill any band presents, and it is paid by the item best
        -- able to afford it.
        --
        -- HOW OFTEN ONE IS FOUND, so the number is arguable rather than asserted:
        -- consumables are 21% of crate items (KindWeights), LEGENDARY is 1/2/5%
        -- of a roll by POI tier, and this is the only item in that bucket. So a
        -- crate holds one about 0.6% of the time in the countryside and 3% of the
        -- time in a named town -- roughly one player in four finds one in a match
        -- they loot hard. A prize, not a staple, which is what a free full repair
        -- should be.
        id = 'repairkit', label = 'Repair Kit', plural = 'Repair Kits',
        rarity = R.LEGENDARY,
        -- The mechanic's chest. Vanilla, like every prop in this file; a model
        -- this build did not have would draw the marker fallback and say so on
        -- the console rather than spawning nothing (client/loot.lua).
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_toolchest_01',
        -- Scaled down for the same reason the Small Shield is: the chest is a
        -- garage prop and full size it reads as scenery rather than as loot.
        -- `/brpropscale repairkit <k>` retunes it live and prints the line to
        -- paste back here.
        propScale = 0.6,
        useMs = 0, maxStack = 1, carryMax = 1,
        repairVeh = true,
        -- CRATE-ONLY, the flag the bandage and the med kit already carry. The
        -- owner said "spawn in loot crates" and this is the field that means it.
        chestOnly = true,
    },
}

--- THE CPR KIT (#191). AN ORDINARY CONSUMABLE IN EVERY RESPECT BUT ONE: it is
--- in no rarity bucket, so no world roll can ever produce it.
---
--- IT IS THE AIRDROP-SHELF PATTERN, which config/weapons.lua established for the
--- exclusive weapons and which config/airdrop.lua's header explains in full.
--- Registered into BR.Config.ConsumableById by hand below, exactly as the
--- exclusive weapons are registered into WeaponById, and into
--- BR.Config.ConsumablesByRarity never.
---
--- WHY NOT JUST APPEND IT TO BR.Config.Consumables. That array is what the
--- rarity buckets are built from, and the buckets are what BR.RollLootStack
--- rolls against -- so a legendary CPR kit in that table is a CPR kit in every
--- crate on the map that rolls legendary, roughly the rarest-common item in the
--- game. #191 says ULTRA-RARE and says the weight is NOT YET DECIDED:
---
---     "Ultra-rare is stated; the actual weight and which crates can roll it are
---      not."
---
--- So no weight is invented here. The one place it is obtainable is the airdrop,
--- whose `healing` pool has named `cprkit` by id since 2026-08-21 specifically so
--- that this day would need no edit to that file -- the resolver there drops ids
--- that do not resolve, and this one now resolves. When the owner decides the
--- world weight, the change is to move this row into BR.Config.Consumables and
--- delete the hand registration; nothing else has to know.
---
--- CARRY ONE, STACK ONE. It is the item that decides whether death is final, and
--- a pocket of three would mean three lives -- which is a different item. The
--- rescue spends the whole slot (server/rescue.lua takes it with BR.Inv.take),
--- so the stack size and the carry cap have to agree at 1.
---
--- NO `useMs`, `health` OR `armour`, AND THAT IS NOT AN OMISSION. The kit is
--- never used through the inventory: BR.Net.INV_USE refuses a downed player
--- outright -- deliberately, so nobody can bandage themselves off the floor --
--- and this item is only ever reachable while downed. It is spent by pressing
--- the interact key on the "call a medic" prompt, which is its own path
--- (BR.Net.RESCUE_CALL) and validates its own conditions. A `useMs` here would
--- be a channel nothing can start.
BR.Config.CprKit = {
    id = 'cprkit', label = 'CPR Kit', plural = 'CPR Kits', rarity = BR.Rarity.LEGENDARY,
    kind = BR.ItemKind.CONSUMABLE, prop = 'xm_prop_x17_bag_med_01a',
    maxStack = 1, carryMax = 1,
    chestOnly = true,
}

BR.Config.ConsumableById = {}
for _, c in ipairs(BR.Config.Consumables) do
    BR.Config.ConsumableById[c.id] = c
end

-- The hand registration. Resolvable everywhere -- the inventory, the ground
-- prop, the label, the airdrop pool -- and rollable nowhere.
BR.Config.ConsumableById[BR.Config.CprKit.id] = BR.Config.CprKit

--- Consumables bucketed by rarity, in authored order. Built once, and built from
--- an ipairs walk rather than a pairs walk for the same reason the weapon
--- buckets are: the loot layout must replay identically from a seed.
BR.Config.ConsumablesByRarity = {}
for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
    BR.Config.ConsumablesByRarity[r] = {}
end
for _, c in ipairs(BR.Config.Consumables) do
    local b = BR.Config.ConsumablesByRarity[c.rarity]
    if b then b[#b + 1] = c end
end

--- The same buckets with the crate-only items taken out, for LOOSE ground
--- rolls. Precomputed rather than filtered at roll time: a filter would either
--- burn a different number of RNG draws depending on what it rejected, or
--- allocate a table per roll -- and the first of those quietly desynchronises
--- two servers running the same seed.
BR.Config.ConsumablesByRarityFloor = {}
for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
    BR.Config.ConsumablesByRarityFloor[r] = {}
end
for _, c in ipairs(BR.Config.Consumables) do
    if not c.chestOnly then
        local b = BR.Config.ConsumablesByRarityFloor[c.rarity]
        if b then b[#b + 1] = c end
    end
end

--- Ammo pickups. Dropped alongside weapons so a found gun is usable.
BR.Config.AmmoPickups = {
    [BR.AmmoType.LIGHT]  = { label = 'Light Ammo',  amount = 36, prop = 'prop_box_ammo01a' },
    [BR.AmmoType.SMG]    = { label = 'SMG Ammo',    amount = 60, prop = 'prop_box_ammo01a' },
    [BR.AmmoType.MEDIUM] = { label = 'Medium Ammo', amount = 45, prop = 'prop_box_ammo02a' },
    [BR.AmmoType.SHELLS] = { label = 'Shells',      amount = 16, prop = 'prop_box_ammo02a' },
    [BR.AmmoType.HEAVY]  = { label = 'Heavy Ammo',  amount = 12, prop = 'prop_box_ammo03a' },
}

--- The ammo pools in a FIXED order. AmmoPickups is keyed by pool name, and
--- iterating a string-keyed table with pairs() is order-undefined -- rolling
--- against it directly would make two servers with the same seed lay out
--- different maps. Every ordered walk over ammo goes through this.
BR.Config.AmmoOrder = {
    BR.AmmoType.LIGHT,
    BR.AmmoType.SMG,
    BR.AmmoType.MEDIUM,
    BR.AmmoType.SHELLS,
    BR.AmmoType.HEAVY,
}

--- Rarity weighting per POI tier. Higher tiers are contested by design, so they
--- pay out better -- that is the whole reason players fight over them.
---
--- Weights are relative within a row and do not need to sum to anything.
BR.Config.RarityWeights = {
    [1] = { [R.COMMON] = 55, [R.UNCOMMON] = 28, [R.RARE] = 13, [R.EPIC] =  3, [R.LEGENDARY] = 1 },
    [2] = { [R.COMMON] = 40, [R.UNCOMMON] = 30, [R.RARE] = 20, [R.EPIC] =  8, [R.LEGENDARY] = 2 },
    [3] = { [R.COMMON] = 25, [R.UNCOMMON] = 28, [R.RARE] = 27, [R.EPIC] = 15, [R.LEGENDARY] = 5 },
}

--- What kind of thing a roll INSIDE A CRATE produces.
---
--- THE WEIGHTS ARE WRITTEN TO SUM TO 100 so a row reads as a percentage of
--- crate items. Nothing requires that -- rng:weighted normalises -- but it is
--- the difference between retuning this table and doing arithmetic first.
---
--- INVERTED 2026-08-16 (#127). The owner opened crates for a full match and
--- reported "disproportionately more ammo/medkits than weapons", and the table
--- agreed with him: at 34/30/28/8, and with meleeChance taking 18% of the
--- weapon rolls for a machete, a crate item was a FIREARM 27.9% of the time and
--- ammo-or-consumable 58% of the time. That is 2.08 supporting items for every
--- gun. Worse, because a crate holds 3 items on average (chestItems below),
--- only 61% of crates contained a firearm at all -- so two crates in five paid
--- out no weapon, which is the one thing a player crosses open ground for.
---
--- A battle royale's crate has to make a weapon the EXPECTED outcome: you find
--- the gun, and the ammo and the shields are what you find alongside it. At
--- 55/22/17/6 a crate item is a firearm 48.4% of the time, 85% of crates hold
--- at least one, and the supporting-to-gun ratio is 0.81:1 -- the wrong way up
--- from where it was, which is the point.
---
--- HOW TO RETUNE IT WITHOUT OPENING A HUNDRED CRATES: `brlootsim` on the server
--- console rolls this table as many times as you like and prints the resulting
--- distribution, including the number that actually matters here -- the share
--- of crates holding a gun. Change a number, restart, run it again.
---
--- The FLOOR table below is deliberately NOT touched by this. Loose ground loot
--- being almost all ammo is a separate, earlier decision (2026-08-06) and is
--- where most of the ammo a player trips over comes from.
--- CONSUMABLE 17 -> 21, PAID FOR BY AMMO (owner, 2026-08-17, the shield report).
---
--- Moving the Shield to the UNCOMMON band above roughly doubles its share of
--- consumable rolls, and it takes that share from Small Shield and Bandage --
--- which is a healing nerf nobody asked for. Widening the consumable slice by
--- the same factor puts the healing back: Bandage lands at 2.6% of crate items
--- against 4.5% before, Med Kit at 4.2% against 3.4%, so the two HEALING items
--- together move 7.9% -> 6.8% rather than 7.9% -> 5.5%.
---
--- WEAPON STAYS AT 55, EXACTLY. That number is #127's whole result -- a crate
--- item is a firearm 48.4% of the time and 85% of crates hold at least one --
--- and this change must not be the thing that quietly undoes it. THROWABLE
--- stays at 6 because it is already the thinnest row on the table.
---
--- SO AMMO PAYS, and it is the right row to take from: the FLOOR table below is
--- 74% ammo and untouched, so loose ground loot remains the ammo firehose it
--- was deliberately made into (2026-08-06). Crate ammo drops 22 -> 18, which is
--- about 11% off the map's total ammo once floor loot is counted.
BR.Config.KindWeights = {
    { kind = BR.ItemKind.WEAPON,     weight = 55 },
    { kind = BR.ItemKind.AMMO,       weight = 18 },
    { kind = BR.ItemKind.CONSUMABLE, weight = 21 },
    { kind = BR.ItemKind.THROWABLE,  weight =  6 },
}

--- What kind of thing a LOOSE GROUND roll produces.
---
--- Deliberately almost all ammo (user call, 2026-08-06: loose loot "should be
--- rare except for ammo"). The crate is meant to be the thing worth crossing
--- open ground for, and when a rifle on the floor is as likely as one in a box
--- there is no reason to take the box's exposure. Loose ammo is the exception
--- because ammo is what a found gun needs to be a gun at all.
---
--- Healing is not on this table at any weight -- see `chestOnly` on the
--- consumables. Bandages and med kits come out of crates, and eventually out
--- of the reboot vans.
BR.Config.FloorKindWeights = {
    { kind = BR.ItemKind.AMMO,       weight = 74 },
    { kind = BR.ItemKind.WEAPON,     weight = 16 },
    { kind = BR.ItemKind.CONSUMABLE, weight =  6 },
    { kind = BR.ItemKind.THROWABLE,  weight =  4 },
}

BR.Config.Loot = {
    -- Items per POI, scaled by tier. A 48-player match across ~49 POIs lands
    -- around 1650 items -- which is exactly why they are local, non-networked
    -- props rather than networked entities. (Scaled down from 35/55/80 when
    -- the POI table grew from 22 to 49 for the storm-anchor scheme: the
    -- map-wide total is the budget, the per-POI number is just its share.)
    -- CRATES CARRY THE LOOT NOW, floor items garnish it (user call,
    -- 2026-08-05). Floor loot halved and crates roughly tripled: a crate is a
    -- decision (walk to it, stand still, open it) and a floor item is a
    -- freebie, so the interesting one should be the common one.
    -- CUT AGAIN, 2026-08-06: loose loot should be "rare except for ammo", so
    -- there is less of it and what remains is mostly ammo (see
    -- BR.Config.FloorKindWeights). Roughly halved a second time.
    budgetPerTier = { [1] = 5, [2] = 8, [3] = 14 },

    -- HOW FAR OUT THE ROLLS REACH, as a fraction of the POI radius.
    --
    -- pointInDisc already samples uniformly by AREA, so density inside the
    -- sampled disc is even -- but crates only ever used the inner 75% of the
    -- radius, which is 56% of the area, and that is what read as "clustered in
    -- the middle" (user, 2026-08-06). Pushed out to nearly the whole radius.
    -- Not to exactly 1.0: the rim is where a first-pass radius is most likely
    -- to have overshot into water or a cliff face, and every point that lands
    -- there costs a retry.
    poiSpread   = 0.97,   -- loose floor items
    chestSpread = 0.95,   -- crates (was 0.75)

    -- Chests hold a guaranteed burst and are worth crossing open ground for.
    --
    -- ONE MODEL, TWO STATES (user call, 2026-08-05). A sealed wooden crate,
    -- swapped for the open-and-empty version of the same crate the moment it
    -- is looted -- so a room you have already been through reads as looted
    -- from the doorway, which is exactly what the empty version is for. The
    -- husk stays for the rest of the match.
    -- FLATTER THAN IT LOOKS. Tier 3 used to pay 2.4x tier 1, which made the
    -- named hot drops the only rational choice and left the countryside a
    -- transit corridor. It is now closer to 1.5x: a hot drop is still better,
    -- but a rural POI can gear you up (user, 2026-08-05 -- "even it out a bit
    -- between POIs and rural areas").
    chestsPerTier = { [1] = 20, [2] = 20, [3] = 24 },
    -- HOW MANY THINGS ARE IN A CRATE. Never zero -- opening one is a
    -- commitment in the open and it has to pay. 3-5 was too generous (user,
    -- 2026-08-06); this peaks at three with two and four equally likely either
    -- side, so a crate has a typical haul rather than a range. min/max are
    -- kept in agreement with the weights for anything that reads the bounds.
    chestItems    = {
        min = 2, max = 4,
        weights = {
            { n = 2, weight = 1 },
            { n = 3, weight = 2 },
            { n = 4, weight = 1 },
        },
    },
    chestProp     = 'prop_box_wood05a',   -- sealed
    chestOpenProp = 'prop_box_wood05b',   -- open and empty: the husk

    -- Sparse filler between the POIs. Without it a bad drop is a two-minute walk
    -- with empty hands; with it there is always something on the roadside worth
    -- stopping for. Rolled on the tier-1 table -- filler is a lifeline, not a
    -- reason to skip the named locations.
    filler = {
        -- Raised again: with the POI tiers flattened, the space BETWEEN them
        -- needs enough to make crossing it a route rather than a gap.
        count         = 420,
        tier          = 1,
        -- ROADSIDE, NOT ON THE ROAD. The offset used to be a symmetric +-22m
        -- band, which includes ZERO -- so a share of every road's filler
        -- landed on the centreline (user, 2026-08-05: "are you sure the loot
        -- will not spawn in the road?"). It is now a signed band with a floor:
        -- 8-22m out, one side or the other, never on the tarmac.
        minOffset     = 8.0,
        lateralOffset = 22.0,
        minPoiDist    = 260.0,  -- do not double up on ground a POI already covers
    },

    -- WARMUP LOOT. The pad is a COMMUNAL bucket shared by every concurrent
    -- match, so this is ONE layout everyone waiting shares -- not a per-match
    -- one, which would put two players side by side seeing different crates.
    -- Everything found here is wiped when the bus departs: warmup PVP is
    -- practice, and arriving early must not be a head start (Fortnite's
    -- pre-game island rule).
    -- A HANDFUL OF CRATES WHERE EACH PLAYER LANDS.
    --
    -- Dropping into empty countryside and finding nothing is how a player
    -- concludes the mode has no loot in it. These are spawned per player when
    -- they touch down -- generation cannot know where anyone will land.
    --
    -- The inner radius is the whole design: too close and it is obviously
    -- staged (crates rain down around you), far enough out and it just reads
    -- as a lucky drop zone. Outside the 45m the eye takes in on landing.
    landing = {
        crates    = 3,
        minRadius = 55.0,
        maxRadius = 130.0,
        tier      = 2,
    },

    -- DELIBERATELY OVERKILL (user call, 2026-08-05). The pad is where a player
    -- meets this system for the first time, and a crate they have to go
    -- looking for is a crate they never find. It should be impossible to walk
    -- twenty metres without tripping over one.
    -- Spread across the ISLAND, not just the apron: the spawn point is moving
    -- off the airport, and players have to meet loot wherever they end up
    -- (user, 2026-08-05). Cayo is roughly a kilometre across, so this covers
    -- most of it.
    warmup = {
        crates      = 220,
        minRadius   = 12.0,    -- close enough to see one from the spawn point
        radius      = 460.0,   -- around BR.Config.Match.warmupPos
        tier        = 2,
        respawnMs   = 30000,   -- a looted crate comes back, so the pad never empties
    },

    -- THE MERCY BLIPS. A player who lands somewhere empty and finds nothing
    -- for a minute and a half cannot tell "no loot here" from "this mode is
    -- broken", and it is the second conclusion they act on.
    --
    -- They end as soon as EITHER is true: something has been found, or the
    -- timeout expires. Help that outstays the problem is a wallhack left
    -- switched on.
    mercyBlips = {
        enabled    = true,
        -- ONE MINUTE, both halves (user call, 2026-08-06). The toast quotes
        -- minShownMs back to the player, so these two numbers and the wording
        -- cannot drift apart.
        afterMs    = 60000,    -- empty-handed this long after landing
        minShownMs = 60000,    -- and the blips last this long once shown
    },

    -- Streaming. Clients subscribe to a 3x3 neighbourhood of cells, so roughly
    -- 50-150 entries are ever in flight rather than the full 1200.
    cellSize        = 256.0,
    subscribeRadius = 1,     -- in cells, so 1 = a 3x3 block

    -- Physical props are a much smaller radius than the subscription: a 3x3
    -- block is 768m across, and 150 objects at that range would be paid for in
    -- frames for no visible benefit. Entries beyond this are registry rows that
    -- materialise as the player walks in.
    -- Doubled (user call, 2026-08-05): you should be able to see a crate
    -- across a POI, not have it fade in as you approach. Objects are the
    -- expensive part of this system, so PROP_MAX in client/loot.lua is what
    -- actually protects the frame budget -- this only decides how far the
    -- candidates come from.
    propDistance    = 180.0,
    propHysteresis  = 15.0,  -- despawn beyond propDistance + this, so a player
                             -- standing on the boundary does not thrash models

    -- Interaction
    pickupDistance  = 3.5,   -- server re-validates this; the client prompt is cosmetic
    pickupRateLimit = 4,     -- claims per second before it counts as suspicious
    promptDistance  = 2.5,
    glowDistance    = 25.0,  -- rarity marker draw range

    -- THE CRATE SHINE. Always orange, never the rarity colour: what is inside
    -- is not knowable until it is opened, so tinting by contents was a lie --
    -- and the glow already means one thing ("a crate is here"), which is one
    -- meaning per channel (user call, 2026-08-06).
    --
    -- ONE crate shines at a time, the nearest within this radius. Every crate
    -- in a room lighting up was a wall of orange rather than a signal.
    shineColour     = { 255, 150, 30 },
    shineHex        = '#FF961E',   -- the same orange, for the DUI prompt text
    shineDistance   = 18.0,

    -- HOW BRIGHT, AND HOW IT ENDS.
    --
    -- The first version was a flat outline at alpha 120 plus a 2.4m light at
    -- 0.9 intensity, on or off with a hard edge at shineDistance -- "too
    -- bright", and it popped (user, 2026-08-06). Both numbers are roughly
    -- halved, and the whole thing now FADES with distance instead of
    -- switching: full strength at the crate, nothing at the rim. There is no
    -- edge left to pop at.
    shineAlpha      = 60,     -- outline alpha at the crate, before the pulse
    shineLightRange = 1.2,    -- metres of cast light (was 2.4 -- a streetlight)
    shineLightPower = 0.30,   -- intensity at the crate (was 0.9)

    -- OFF. The glow was a tutorial that ended after two crates (2026-08-06);
    -- it is now off from the first one (user call, 2026-08-09: "let's just
    -- turn off the crate glow altogether"). The crates are a distinct prop
    -- with a label over them and a prompt when you are near, which is enough
    -- to say "these open" without painting the world orange.
    --
    -- 0 disables it outright; 2 is what it was; a huge number keeps it up all
    -- match. Everything below still works and /brshine still tunes it live --
    -- this is one number, so turning it back on costs nothing.
    shineOpenLimit  = 0,

    -- THE LANDING BURST. Props stream in two per pass so a dense POI does not
    -- stutter, which is right everywhere except the one moment a player has
    -- nothing to do but watch: the first seconds after touchdown, when a POI
    -- that is actually full of loot looks empty (user, 2026-08-08). For this
    -- long after the first cell subscription of a life, the spawn worker
    -- builds faster -- and it is also the cheapest time to spend frames, since
    -- the drop is already a loading moment and nobody is in a fight yet.
    drainPerPass    = 2,
    landingBurst    = 8,
    landingBurstMs  = 4000,

    -- ----------------------------------------------------------------------
    -- CHOREOGRAPHY. Items are objects, not sprites that blink in and out.
    -- ----------------------------------------------------------------------
    --
    -- Entirely presentational: none of this changes what the server decides,
    -- who gets an item, or when. Every number here is a client-side ease.
    --
    -- Where the world thinks a player's hands are, measured from the ped's
    -- ROOT (which is at their feet). Used at both ends: a dropped item leaves
    -- from here, and a taken one travels back to here.
    waistHeight     = 0.75,
    -- Where a crate's contents come OUT of it, above the crate's base.
    crateMouthHeight = 0.6,

    -- THE ARRIVAL ARC: born somewhere else, landing here. Only entries that
    -- carry an origin (crate contents, dropped items) animate; the generated
    -- layout was always just there and appears without ceremony.
    arriveMs        = 520,
    arriveArc       = 0.55,   -- extra metres at the top of the parabola

    -- HOW STALE AN ORIGIN MAY BE AND STILL FLY (and this number is the whole of
    -- why the arc never played, from the other end).
    --
    -- The arrival is animated by moving a PROP, and the prop does not exist when
    -- the message arrives: it is built by the spawn worker, which streams a
    -- model in. Measuring the 520ms window from the moment the message landed
    -- meant the window was always shut by the time there was anything to move
    -- (owner, 2026-08-23: the arc never played, for any crate).
    --
    -- So the clock now starts when the PROP is built, and this is the guard on
    -- that: an entry whose birth was longer ago than this appears at rest, no
    -- ceremony. It has to be longer than a model stream (RequestModel waits up
    -- to 3s) and short enough that walking 180m to a crate somebody opened a
    -- minute ago does not replay the burst.
    arriveGraceMs   = 3000,

    -- HOW HIGH A PROP IS DROPPED FROM BEFORE IT IS SETTLED. Not its resting
    -- height: PlaceObjectOnGroundProperly decides that, from the model's
    -- bounding box and the slope, and the answer is read back and remembered.
    -- Two attempts to compute it instead -- the bare ground z, then ground
    -- plus this -- buried every item and then floated it (user, 2026-08-08).
    restLift        = 0.35,

    -- LYING DOWN vs STANDING UP, in degrees of pitch.
    --
    -- WEAPONS ONLY (see restPitchOf). A rifle standing on end sinks into the
    -- terrain however carefully its centre is placed -- which was the visible
    -- clipping. Lying flat it sits ON the ground. So a weapon lies down when
    -- it settles and stands up as it rises to be taken, which is also the read
    -- the hover wants: an object presenting itself rather than one dropped.
    --
    -- Ammo boxes, medkits and shield potions are exempt and stay upright at
    -- rest. They are boxes, they spawn the right way up, and tipping one onto
    -- its side is worse rather than better (user, 2026-08-08).
    --
    -- If weapons come out inverted in game -- flat while hovering and upright
    -- in the dirt -- swap the two numbers. Which way a given weapon prop's
    -- local axes point is not something the config can know.
    restPitch       = 90.0,
    hoverPitch      = 0.0,

    -- THE HOVER. Inside prompt range an item rises off the ground, bobs and
    -- turns; outside it, it settles back. Both directions eased, because a
    -- snap reads as a bug and this is meant to read as "you can take this".
    hoverHeight     = 0.55,
    hoverRiseMs     = 320,
    hoverFallMs     = 420,
    bobAmplitude    = 0.06,
    bobPeriodMs     = 1900,
    spinDegPerSec   = 55.0,

    -- THE PICKUP. The prompt and the marker go first, then the prop flies to
    -- the taker and vanishes. By the time any of this is on screen the item is
    -- already gone from the registry -- it is scenery being cleared away, not
    -- something you could still interact with (user call, 2026-08-08).
    takeMs          = 400,

    -- FACING. The prompt only appears for an item the player is actually
    -- looking at -- otherwise walking down a corridor of loot flickers a
    -- prompt for whatever happens to be nearest. Cosine of the half-angle, so
    -- 0.55 is roughly a 113-degree cone.
    promptFacingDot = 0.55,

    -- How big the floating "press to pick up" panel draws, and how far above
    -- the ITEM it floats.
    --
    -- 1.35 was too timid to notice: what the eye actually caught was the label
    -- climbing, because the item beneath it had started hovering half a metre
    -- and the label was pinned to a fixed world height ON TOP of that -- two
    -- rises stacked ("I think you doubled the elevation, not the size", user
    -- 2026-08-08). Now the offset is measured from the item, so the label
    -- keeps a constant gap however high the thing floats, and the size is a
    -- number nobody has to squint at.
    promptScale     = 2.0,
    promptLift      = 0.75,   -- metres above the item, hovering or resting

    -- How often the "which crate shines" search runs. That search is a full
    -- walk of every streamed entry; the FADE is still per-frame, so this only
    -- controls how quickly the glow can jump to a different crate.
    shineScanMs     = 100,

    -- THE CRATE LABEL. Drawn flat on the lid rather than as a sprite turning
    -- to face the camera, so it reads as printed on the box (user call,
    -- 2026-08-06). Set crateLabelFlat = false to go back to the floating
    -- screen-facing prompt.
    -- THE LID HEIGHT IS READ OFF THE MODEL now rather than configured. The
    -- previous version placed the label at ground + 0.95, which on a crate
    -- roughly 0.8m tall left it hanging "about 6 inches over the plywood"
    -- (user, 2026-08-06) -- a guessed constant against a measured object.
    -- GetModelDimensions gives the real top face, whatever the prop.
    crateLabelFlat  = true,
    -- Doubled 0.55 -> 1.1 (user, 2026-08-06). `crateLabelFit` is what stops it
    -- overhanging; at 0.48 the label may cover almost the whole lid, which is
    -- what doubling the size actually needs -- at the old 0.45 clamp the
    -- bigger number would simply have been clipped back to the same size.
    crateLabelSize  = 1.1,    -- label WIDTH in metres, clamped to fit the lid
    crateLabelFit   = 0.48,   -- max half-extent of the lid the label may use

    -- Metres proud of that top face. NEGATIVE, and deliberately: the bounding
    -- box top is the raised battens around the lid, not the plywood between
    -- them, so sitting exactly on it still reads as floating.
    --
    -- Guessed twice now -- 0.02 floated, -0.10 sank inside the box -- so stop
    -- guessing: /brlabel <lift> changes this live, in game, and prints what to
    -- paste back here. The plywood is only a few centimetres under the batten
    -- tops, so the useful range is small.
    crateLabelLift  = -0.050,

    -- CRATE DRAG, applied to a crate that is actually moving.
    --
    -- The mass is right now, but a nudge from a car sent them skating for
    -- twenty metres -- prop physics has no friction worth the name and
    -- SetObjectPhysicsParams exposes damping that only bites in the air
    -- (user, 2026-08-06: "they slide like ice"). This is a straight velocity
    -- scale per tick on the horizontal component only, so gravity and falls
    -- are untouched: 0.82 at 10Hz kills a slide in about a second and a half
    -- without making the crate feel glued.
    -- Tuned down twice on 2026-08-06: 0.82 was a long skate, 0.46 was working
    -- but still slid, and the user asked to double the drag again. 0.23 keeps
    -- under a quarter of the speed each tick -- a crate stops within about its
    -- own length of being hit.
    crateDrag       = 0.23,
    crateDragMin    = 0.35,   -- m/s below which it is simply stopped dead

    -- How often the client tells the SERVER what the magazine is doing. The
    -- HUD does not wait for this -- it follows the gun every tick -- so this
    -- is purely how quickly the server's reserve arithmetic catches up.
    -- Was 500ms, which also gated the display and left the counter several
    -- rounds behind the shots (user, 2026-08-06).
    ammoReportMs    = 150,

    -- How often a CRATE weapon roll produces melee instead of a firearm.
    -- Crate-only: a machete on the roadside is a consolation prize, a machete
    -- in a box you crossed open ground for is a decision (user, 2026-08-07).
    --
    -- THIS IS A FRACTION OF THE WEAPON ROLLS, SO IT IS COUPLED TO
    -- BR.Config.KindWeights AND HAS TO MOVE WITH IT. Raising the weapon weight
    -- from 34 to 55 for #127 would have taken melee from 6.1% of crate items to
    -- 9.9% as a side effect -- a 62% increase in machetes that nobody asked
    -- for, arriving inside a change whose entire purpose was "more guns".
    -- 0.12 of the new weight lands melee back at 6.6% of crate items, so the
    -- whole of the increase goes where the owner pointed it: firearms.
    --
    -- The knob still means what it always meant. Raise it for more machetes.
    meleeChance     = 0.12,

    -- Crate mass, in kg, via SetObjectPhysicsParams. Tuned in game, in four
    -- passes: the prop default read as "extremely heavy", 12 overcorrected
    -- into a paperweight, 120 was still a paperweight, and 1200 landed at
    -- "about half what an EMPTY crate should weigh" -- so a FULL one is 4x
    -- that again (user, 2026-08-06). Heavy enough that a car shunts it and a
    -- shoulder does not.
    crateMass       = 4800.0,

    -- HOW LONG A CRATE IS HELD FROZEN WAITING FOR THE GROUND TO EXIST.
    --
    -- Owner, 2026-08-23: an airdrop that lands on a building "falls through the
    -- top of the building as if it doesn't have collisions", and the crate then
    -- "spawn[s] at ground level inside a building".
    --
    -- A container is the one prop this gamemode hands to the physics
    -- simulation, and map collision streams asynchronously: hand it over before
    -- the roof underneath it has arrived and gravity takes it to the terrain,
    -- where it stays. So client/loot.lua freezes it, calls
    -- RequestCollisionAtCoord, and waits here for
    -- HasCollisionLoadedAroundEntity before letting go.
    --
    -- 1500ms IS A CEILING AND NOT A COST. The wait ends the moment the collision
    -- reports in, which for the ordinary ~1300 crates -- built well inside a
    -- world the player is standing in -- is the first check. Only a prop built
    -- at the edge of what has streamed pays anything at all.
    --
    -- WHEN IT EXPIRES, THE CRATE IS RELEASED ANYWAY. A box that behaves exactly
    -- as it did before this existed beats a box frozen in mid-air for the rest
    -- of the match because a streaming request never completed.
    collisionWaitMs = 1500,
    labelDistance   = 8.0,   -- 3D text draw range

    -- Containers are a commitment in the open: you stand still for a second and
    -- anyone watching the building knows exactly where you are.
    chestHoldMs     = 1000,

    -- Frontend sounds. Here rather than inline precisely so they can be
    -- auditioned -- /brsound <set> <name> plays any pair in-game.
    --
    -- openSound is the crate reveal; pickupSound fires whenever something
    -- actually lands in the inventory, which is the feedback that tells you
    -- the claim was accepted rather than refused.
    openSound       = { name = 'CHECKPOINT_PERFECT',
                        set  = 'HUD_MINI_GAME_SOUNDSET' },
    pickupSound     = { name = 'PICK_UP',
                        set  = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },
    -- Switching slots. Deliberately the quietest of the three -- it fires
    -- every time the wheel moves, so anything with character becomes
    -- irritating within a minute.
    switchSound     = { name = 'NAV_UP_DOWN',
                        set  = 'HUD_FRONTEND_DEFAULT_SOUNDSET' },

    -- The GLYPH in the pickup prompt.
    --
    -- SETTLED IN-GAME 2026-08-05: a custom RegisterKeyMapping binding's
    -- ~INPUT_8D762F65~ renders as a HOLE ("press  to pick up"), while
    -- ~INPUT_CONTEXT~ draws a proper E key. So the prompt shows the VANILLA
    -- token -- and, so that the picture never lies, GTA's own INPUT_CONTEXT
    -- control is accepted as a second interact input alongside our binding.
    -- Both are player-configurable: INPUT_CONTEXT in GTA's settings, ours in
    -- Settings > Key Bindings > FiveM. Neither is a hardcoded key.
    promptToken     = '~INPUT_CONTEXT~',

    -- The GTA control that backs that glyph. 51 = INPUT_CONTEXT.
    promptControl   = 51,

    -- Consumables are interruptible by design -- committing to an 8s med kit
    -- while being shot should lose you the med kit, not heal you through it.
    useCancelOnDamage = true,

    -- Death drops. A player's kit lands scattered AROUND them rather than in a
    -- box: right after a fight, standing still to hold a key on a container is
    -- the last thing anyone wants to do (user call, 2026-08-05). ~15 feet.
    deathScatterRadius = 4.6,
    deathBoxSpread     = 0.8,   -- still used by chest contents

    -- HOW CLOSE TO THE BOX AN ITEM MAY LAND. The contents no longer sit on an
    -- even ring (see scatter() in server/loot.lua) and the inner band of that
    -- spill is well inside a crate's own footprint for a two-item chest -- an
    -- item inside the prop is an item that can be neither seen nor targeted,
    -- which is indistinguishable from loot that failed to spawn.
    scatterClearance   = 0.7,

    -- Inventory. Five is the number the keybinds (slot1..slot5), the UI's
    -- emptyInv and the HUD bar all already assume; changing it means changing
    -- all three together.
    slots           = 5,

    -- Slot ZERO: fists. Always present, never fillable, left of slot 1 on the
    -- bar and part of the scroll ring. A deliberate empty hand is a real
    -- choice -- you cannot open a crate convincingly with a rifle up, and
    -- putting the gun away should not mean dropping it.
    meleeSlot       = 0,

    -- A found gun has to be usable, or the first weapon on the ground is a
    -- decoration. One clip loaded plus one in reserve is enough for a fight,
    -- not enough to stop looting ammo.
    weaponReserveClips = 1,

    -- KILLING AN NPC DROPS THEIR GUN, as one of OUR entries (user call,
    -- 2026-08-06). The vanilla pickup was removed because it had no DUI, no
    -- rarity and no route into the inventory -- the answer was never "no
    -- drop", it was "our drop".
    --
    -- The server cannot see ambient peds die, so this is a client report, and
    -- the limits below are what make lying pointless rather than impossible:
    -- one drop every few seconds with a hard per-match ceiling is strictly
    -- slower than opening crates, so the honest path stays the fast one.
    -- The gun arrives EMPTY -- it is a lifeline after a bad landing, not a
    -- substitute for finding a crate.
    npcDrop = {
        enabled       = true,
        range         = 60.0,   -- corpse must be this close to the reporter
        minIntervalMs = 4000,   -- one drop per reporter per this long
        maxPerMatch   = 12,     -- and no more than this many all match
    },

    -- Starting kit. Deliberately nothing but the drop itself -- landing unarmed
    -- is what makes the first thirty seconds tense.
    startingItems   = {},
}

--- WHO CAN SEE LOOT, AND WHO CAN TAKE IT -- ONE DEFINITION, BOTH SIDES.
---
--- The client decides whether to ASK for a cell; the server decides whether to
--- ANSWER. When those two disagreed there was no loot anywhere: WARMUP was
--- added to the server's set and not the client's, so nobody on the pad ever
--- subscribed, the shared warmup zone was therefore never built, and 140
--- crates existed nowhere at all -- with no error, because nothing failed
--- (user, 2026-08-05). A shared table is the only version of this that cannot
--- drift.
---
--- The server's copy remains the security boundary. This is not a permission
--- system; it is the single place the permission is written down.
BR.Config.LootVisibleStates = {
    [BR.PlayerState.WARMUP]     = true,   -- the shared pad layout
    [BR.PlayerState.BUS]        = true,
    [BR.PlayerState.FREEFALL]   = true,
    [BR.PlayerState.GLIDE]      = true,
    [BR.PlayerState.ALIVE]      = true,
    [BR.PlayerState.DBNO]       = true,
    [BR.PlayerState.OUT]        = true,   -- and so a spectator, who is OUT
    -- LOBBY is absent: the vista is a menu with a view, not a place.
}

BR.Config.LootTakeStates = {
    [BR.PlayerState.ALIVE]  = true,
    [BR.PlayerState.WARMUP] = true,   -- the pad exists for practice PVP
}

--- Roll a rarity for a given POI tier.
--- @param rng table   a BR.Rng instance
--- @param tier integer
--- @return integer rarity
function BR.Config.RollRarity(rng, tier)
    local row = BR.Config.RarityWeights[tier] or BR.Config.RarityWeights[2]
    local entries = {}
    for rarity, weight in pairs(row) do
        entries[#entries + 1] = { rarity = rarity, weight = weight }
    end
    -- pairs() order is undefined, so sort for determinism: the same seed must
    -- produce the same layout on the server and on every client.
    table.sort(entries, function(a, b) return a.rarity < b.rarity end)
    local pick = rng:weighted(entries)
    return pick and pick.rarity or R.COMMON
end

--- Roll what kind of item a ground slot holds.
--- @param rng table
--- @return string kind
--- @param rng table
--- @param weights table|nil  defaults to the crate table; pass
---                           BR.Config.FloorKindWeights for loose ground loot
--- @return string kind
function BR.Config.RollKind(rng, weights)
    local pick = rng:weighted(weights or BR.Config.KindWeights)
    return pick and pick.kind or BR.ItemKind.WEAPON
end

--- Total planned item count across every POI, for sanity-checking budgets.
--- @return integer
function BR.Config.TotalLootBudget()
    local total = 0
    for _, poi in ipairs(BR.Config.Map.POIs) do
        total = total + (BR.Config.Loot.budgetPerTier[poi.tier] or 0)
    end
    return total
end
