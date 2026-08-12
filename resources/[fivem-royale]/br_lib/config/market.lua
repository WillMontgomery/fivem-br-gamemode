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
    PARACHUTES USE CANOPY TEXTURE VARIANTS, NOT A COLOUR TINT.

    GTA V's parachute canopy is not tinted arbitrarily -- it selects one of a
    fixed set of preset designs, each its own texture: the plain colours, the
    Rockstar/LS liveries, the flag ones. The native is
    SET_PLAYER_PARACHUTE_TINT_INDEX, whose NAME says tint and whose behaviour is
    "pick variant N", which is exactly the sort of misleading native this
    codebase writes down rather than rediscovers.

    THE INDICES BELOW ARE NOT YET VERIFIED IN GAME. They come from the
    documented ranges, and the mapping from index to appearance wants confirming
    with a client in the air before anybody pays for one -- `brchute <n>` exists
    for exactly that. If an index turns out to be wrong the fix is this table,
    not code.

    The reserve chute takes its own index (SET_PLAYER_RESERVE_PARACHUTE_TINT_
    INDEX). We do not issue reserves -- see client/natives.lua on why -- so
    only the primary matters here.
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
                    id = 'chute_default', name = 'Standard', sub = 'Canopy',
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
                    apply = { chuteTint = 1 },
                },
                {
                    id = 'chute_ls', name = 'Los Santos', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 2500, rarity = BR.Config.Rarity.RARE,
                    apply = { chuteTint = 4 },
                },
                {
                    id = 'chute_storm', name = 'Stormchaser', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 6000, rarity = BR.Config.Rarity.LEGENDARY,
                    apply = { chuteTint = 6 },
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
