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

BR.Config.Consumables = {
    {
        id = 'minishield', label = 'Small Shield Potion', rarity = R.COMMON,
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_bodyarmour_02',
        useMs = 3000, maxStack = 6,
        armour = 25, armourCap = 50,   -- small potions only take you to half shield
    },
    {
        id = 'shield', label = 'Shield Potion', rarity = R.RARE,
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_bodyarmour_06',
        useMs = 5000, maxStack = 3,
        armour = 50, armourCap = 100,
    },
    {
        id = 'bandage', label = 'Bandage', rarity = R.COMMON,
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_ld_health_pack',
        useMs = 4000, maxStack = 8,
        health = 15, healthCap = 75,   -- bandages cannot finish the job
    },
    {
        id = 'medkit', label = 'Med Kit', rarity = R.EPIC,
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_ld_health_pack',
        useMs = 8000, maxStack = 2,
        health = 100, healthCap = 100,
    },
}

BR.Config.ConsumableById = {}
for _, c in ipairs(BR.Config.Consumables) do
    BR.Config.ConsumableById[c.id] = c
end

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

--- What kind of thing a ground-loot roll produces.
BR.Config.KindWeights = {
    { kind = BR.ItemKind.WEAPON,     weight = 34 },
    { kind = BR.ItemKind.AMMO,       weight = 30 },
    { kind = BR.ItemKind.CONSUMABLE, weight = 28 },
    { kind = BR.ItemKind.THROWABLE,  weight =  8 },
}

BR.Config.Loot = {
    -- Items per POI, scaled by tier. A 48-player match across ~49 POIs lands
    -- around 1650 items -- which is exactly why they are local, non-networked
    -- props rather than networked entities. (Scaled down from 35/55/80 when
    -- the POI table grew from 22 to 49 for the storm-anchor scheme: the
    -- map-wide total is the budget, the per-POI number is just its share.)
    budgetPerTier = { [1] = 20, [2] = 35, [3] = 60 },

    -- Chests hold a guaranteed burst and are worth crossing open ground for.
    chestsPerTier = { [1] = 2, [2] = 4, [3] = 7 },
    chestItems    = { min = 3, max = 5 },
    chestProps    = {
        'prop_box_ammo04a',
        'prop_mil_crate_01',
        'prop_box_wood02a',
        'prop_gold_cont_01',
    },

    -- Sparse filler between the POIs. Without it a bad drop is a two-minute walk
    -- with empty hands; with it there is always something on the roadside worth
    -- stopping for. Rolled on the tier-1 table -- filler is a lifeline, not a
    -- reason to skip the named locations.
    filler = {
        count         = 240,
        tier          = 1,
        lateralOffset = 22.0,   -- metres either side of the road centreline
        minPoiDist    = 260.0,  -- do not double up on ground a POI already covers
    },

    -- Streaming. Clients subscribe to a 3x3 neighbourhood of cells, so roughly
    -- 50-150 entries are ever in flight rather than the full 1200.
    cellSize        = 256.0,
    subscribeRadius = 1,     -- in cells, so 1 = a 3x3 block

    -- Physical props are a much smaller radius than the subscription: a 3x3
    -- block is 768m across, and 150 objects at that range would be paid for in
    -- frames for no visible benefit. Entries beyond this are registry rows that
    -- materialise as the player walks in.
    propDistance    = 90.0,
    propHysteresis  = 15.0,  -- despawn beyond propDistance + this, so a player
                             -- standing on the boundary does not thrash models

    -- Interaction
    pickupDistance  = 3.5,   -- server re-validates this; the client prompt is cosmetic
    pickupRateLimit = 4,     -- claims per second before it counts as suspicious
    promptDistance  = 2.5,
    glowDistance    = 25.0,  -- rarity marker draw range
    labelDistance   = 8.0,   -- 3D text draw range

    -- Containers are a commitment in the open: you stand still for a second and
    -- anyone watching the building knows exactly where you are.
    chestHoldMs     = 1000,

    -- The GLYPH in the pickup prompt, and nothing else -- which key works is
    -- always the player's own RegisterKeyMapping binding, never this.
    --
    -- false = render the real binding via BR.Native.inputForCommand. PLAN.md
    -- records that a custom binding's ~INPUT_<hash>~ drew as a HOLE on this
    -- build once (the bus doors prompt hit it), so if the prompt comes back
    -- blank in-game, set this to a vanilla token such as '~INPUT_CONTEXT~'.
    -- /brpromptcheck prints both side by side.
    promptToken     = false,

    -- Consumables are interruptible by design -- committing to an 8s med kit
    -- while being shot should lose you the med kit, not heal you through it.
    useCancelOnDamage = true,

    -- Death boxes
    deathBoxProp    = 'prop_box_ammo04a',
    deathBoxSpread  = 0.8,

    -- Inventory. Five is the number the keybinds (slot1..slot5), the UI's
    -- emptyInv and the HUD bar all already assume; changing it means changing
    -- all three together.
    slots           = 5,

    -- A found gun has to be usable, or the first weapon on the ground is a
    -- decoration. One clip loaded plus one in reserve is enough for a fight,
    -- not enough to stop looting ammo.
    weaponReserveClips = 1,

    -- Starting kit. Deliberately nothing but the drop itself -- landing unarmed
    -- is what makes the first thirty seconds tense.
    startingItems   = {},
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
function BR.Config.RollKind(rng)
    local pick = rng:weighted(BR.Config.KindWeights)
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
