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
        id = 'minishield', label = 'Small Shield', rarity = R.COMMON,
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_bodyarmour_02',
        useMs = 3000, maxStack = 6,
        armour = 25, armourCap = 50,   -- small potions only take you to half shield
    },
    {
        id = 'shield', label = 'Shield', rarity = R.RARE,
        kind = BR.ItemKind.CONSUMABLE, prop = 'prop_bodyarmour_06',
        useMs = 5000, maxStack = 3,
        armour = 50, armourCap = 100,
    },
    {
        id = 'bandage', label = 'Bandage', rarity = R.COMMON,
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
        id = 'medkit', label = 'Med Kit', rarity = R.EPIC,
        -- The med bag: visibly the bigger of the two.
        kind = BR.ItemKind.CONSUMABLE, prop = 'xm_prop_x17_bag_med_01a',
        useMs = 8000, maxStack = 3, carryMax = 3,
        health = 100, healthCap = 100,
        chestOnly = true,
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
BR.Config.KindWeights = {
    { kind = BR.ItemKind.WEAPON,     weight = 34 },
    { kind = BR.ItemKind.AMMO,       weight = 30 },
    { kind = BR.ItemKind.CONSUMABLE, weight = 28 },
    { kind = BR.ItemKind.THROWABLE,  weight =  8 },
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

    -- THE GLOW IS A TUTORIAL, AND IT ENDS (user call, 2026-08-06). It exists
    -- to teach "these boxes open"; a permanent orange marker on every crate in
    -- the game is then just noise on top of the prop itself. Two crates rather
    -- than one, because the first one is often opened by accident while
    -- working out the key. Client-local and per-match; set 0 to disable the
    -- glow outright, or a huge number to keep it all match.
    shineOpenLimit  = 2,

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
    meleeChance     = 0.18,

    -- Crate mass, in kg, via SetObjectPhysicsParams. Tuned in game, in four
    -- passes: the prop default read as "extremely heavy", 12 overcorrected
    -- into a paperweight, 120 was still a paperweight, and 1200 landed at
    -- "about half what an EMPTY crate should weigh" -- so a FULL one is 4x
    -- that again (user, 2026-08-06). Heavy enough that a car shunts it and a
    -- shoulder does not.
    crateMass       = 4800.0,
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
    [BR.PlayerState.DEAD]       = true,
    [BR.PlayerState.SPECTATING] = true,
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
