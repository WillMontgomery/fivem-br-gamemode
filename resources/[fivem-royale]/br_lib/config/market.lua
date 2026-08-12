-- The market catalogue.
--
-- ORGANISED BY SEASON, because that is how it will actually change: a season
-- ends, its items stop being purchasable, and a new set appears. Keeping them
-- in one flat list would mean editing the middle of a table and hoping nothing
-- else moved. Adding a season is appending a block; ending one is flipping
-- `active`.
--
-- ITEMS ARE NEVER DELETED, only deactivated. Somebody owns them. A player who
-- bought the season-one chute in season two still has it, still equips it, and
-- still sees its name -- so the definition has to survive even when the item
-- is no longer for sale. Deleting the row would leave them holding an id
-- nothing can render.
--
-- WHAT AN ITEM IS, MECHANICALLY, is described by `apply` -- the small table the
-- client reads to actually put the thing on the player. Cosmetics differ in how
-- they are applied far more than in how they are sold, and keeping that
-- difference in the definition rather than in a switch statement somewhere is
-- what lets a season add a kind of item nobody thought of.

BR = BR or {}
BR.Config = BR.Config or {}

--- Rarity drives the card treatment in the NUI. Ordered, not arbitrary.
BR.Config.Rarity = {
    COMMON = 1, UNCOMMON = 2, RARE = 3, EPIC = 4, LEGENDARY = 5,
}

--- Item kinds. A kind decides which slot an item occupies -- one equipped
--- chute, one equipped character -- and which tab it appears under.
BR.Config.ItemKind = {
    CHARACTER = 'character',
    CHUTE     = 'chute',
    TRAIL     = 'trail',
    BANNER    = 'banner',
    VERDICT   = 'verdict',
}

--[[
    PARACHUTE CANOPIES ARE AN ENUMERATED SET OF PRESET DESIGNS.

    SET_PLAYER_PARACHUTE_TINT_INDEX has a name that says "tint" and a behaviour
    that says "pick design N". It is not a colour multiplier and there is no way
    to ask for an arbitrary RGB: the canopy textures ship with the model, and the
    index chooses one. Several of them are plain single colours, which is what
    makes the name plausible enough to mislead -- but 2, 3, 4 and 7 are multi
    colour striped liveries that no tint value could produce.

    0-7 WORK ON THE STANDARD MP CANOPY. 8-13 are the San Andreas Flight School
    designs and are documented as requiring a parachute model override to appear
    at all. THIS GAMEMODE ALREADY OVERRIDES THE MODEL -- client/skydive.lua sets
    p_parachute1_mp_s before tasking the chute -- so whether 8-13 resolve here is
    an open question rather than a known no. They are deliberately not sold until
    somebody has seen one. 0-7 are the season.

    THE INDEX-TO-APPEARANCE MAPPING BELOW COMES FROM DOCUMENTATION, NOT FROM
    THIS BUILD. `brchute` in the F8 console exists to confirm it: `brchute test`
    lifts you to canopy height and cycles, `brchute <n>` sets one. Anything sold
    should be looked at once before a player can spend on it, because the failure
    mode is somebody paying 6000 for a canopy that renders as something else.

    ORDER MATTERS WHEN APPLYING. The tint has to be set before the canopy opens
    -- after SetPlayerParachuteModelOverride and before TaskParachute, which is
    the window skydive.lua already has open for the smoke trail.

    The reserve chute takes its own index (SET_PLAYER_RESERVE_PARACHUTE_TINT_
    INDEX), and on the reserve those same numbers select SMOKE TRAIL colours
    rather than canopies. We do not issue reserves -- see client/skydive.lua on
    why chute ammo above one is a bug -- so only the primary matters here.
]]

BR.Config.Market = {
    seasons = {
        {
            id = 'founders',
            name = 'Founders',
            -- Inactive seasons still render for the people who own their items;
            -- they simply cannot be bought.
            active = true,
            items = {
                {
                    -- INDEX 0 IS THE RAINBOW CANOPY, and it is what every player
                    -- already gets today because nothing sets a tint at all. So
                    -- the free default is not a neutral "standard" -- it is the
                    -- loud one, and calling it Standard in the storefront would
                    -- be describing something the player can plainly see is not
                    -- standard. Naming it honestly also gives the paid canopies
                    -- something to be an upgrade FROM.
                    id = 'chute_rainbow', name = 'Rainbow', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 0, rarity = BR.Config.Rarity.COMMON,
                    -- Owned by everyone, always, and not purchasable. Every
                    -- slot needs a default or "unequip" has nowhere to go.
                    default = true,
                    apply = { chuteTint = 0 },
                },
                {
                    id = 'chute_crimson', name = 'Crimson', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 1200, rarity = BR.Config.Rarity.UNCOMMON,
                    apply = { chuteTint = 1 },        -- solid red
                },
                {
                    id = 'chute_seaside', name = 'Seaside', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 1500, rarity = BR.Config.Rarity.UNCOMMON,
                    apply = { chuteTint = 2 },        -- white/blue/yellow stripes
                },
                {
                    id = 'chute_azure', name = 'Azure', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 2200, rarity = BR.Config.Rarity.RARE,
                    apply = { chuteTint = 5 },        -- solid blue
                },
                {
                    id = 'chute_widowmaker', name = 'Widowmaker', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 2500, rarity = BR.Config.Rarity.RARE,
                    apply = { chuteTint = 3 },        -- brown/red/white stripes
                },
                {
                    id = 'chute_patriot', name = 'Patriot', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 2500, rarity = BR.Config.Rarity.RARE,
                    apply = { chuteTint = 4 },        -- red/white/blue stripes
                },
                {
                    id = 'chute_midnight', name = 'Midnight', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 4000, rarity = BR.Config.Rarity.EPIC,
                    apply = { chuteTint = 6 },        -- solid black
                },
                {
                    id = 'chute_hornet', name = 'Hornet', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 6000, rarity = BR.Config.Rarity.LEGENDARY,
                    apply = { chuteTint = 7 },        -- black/yellow stripes
                },
            },
        },
    },
}

--- Every item across every season, flattened, keyed by id.
---
--- BUILT ONCE AT LOAD rather than searched per lookup: equipping and rendering
--- both ask "what is this id" constantly, and a linear scan through seasons
--- would be the kind of cost that only shows up at a full server.
BR.Config.MarketIndex = {}
for _, season in ipairs(BR.Config.Market.seasons) do
    for _, item in ipairs(season.items) do
        item.season = season.id
        item.seasonName = season.name
        item.purchasable = season.active and not item.default and item.price > 0
        BR.Config.MarketIndex[item.id] = item
    end
end

--- The default item for a slot, which every player owns implicitly.
--- @param kind string
--- @return table|nil
function BR.Config.defaultItem(kind)
    for _, item in pairs(BR.Config.MarketIndex) do
        if item.kind == kind and item.default then return item end
    end
    return nil
end
