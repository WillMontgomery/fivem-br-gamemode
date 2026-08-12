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
--
-- ARTWORK is `market/<id>.png` under br_ui, following the same convention as
-- ui-src/public/items. A missing file degrades to the rarity treatment on the
-- card rather than to an empty square, so the set can be filled in a few at a
-- time.

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
    WEAPON    = 'weapon',
    BANNER    = 'banner',
    VERDICT   = 'verdict',
}

--[[
    ============================ CANOPIES ============================

    PARACHUTE CANOPIES ARE AN ENUMERATED SET OF PRESET DESIGNS.

    SET_PLAYER_PARACHUTE_TINT_INDEX has a name that says "tint" and a behaviour
    that says "pick design N". It is not a colour multiplier and there is no way
    to ask for an arbitrary RGB: the canopy textures ship with the model, and the
    index chooses one. Several of them are plain single colours, which is what
    makes the name plausible enough to mislead -- but 2, 3, 4 and 7 are multi
    colour striped liveries that no tint value could produce.

    0-7 are the standard set. 8-13 are documented as requiring a parachute model
    override to appear at all -- and this gamemode already overrides the model
    (client/skydive.lua sets p_parachute1_mp_s before tasking the chute), so they
    are expected to resolve here. EXPECTED IS NOT OBSERVED: see the note below.

    THE INDEX-TO-APPEARANCE MAPPING BELOW COMES FROM DOCUMENTATION, NOT FROM
    THIS BUILD. `brchute` in the F8 console exists to confirm it: `brchute test`
    lifts you to canopy height and deploys, `brchute cycle` steps through them.
    An earlier version of this table was wrong about three of its four entries,
    so this is a demonstrated risk rather than a theoretical one.

    ORDER MATTERS WHEN APPLYING. The tint has to be set before the canopy opens
    -- after SetPlayerParachuteModelOverride and before TaskParachute, which is
    the window skydive.lua already has open for the smoke trail.

    ============================= TRAILS =============================

    SMOKE TRAILS ARE ARBITRARY RGB HERE, AND THAT IS THE BETTER MECHANISM.

    The documented smoke-trail list -- red, orange, yellow, blue, black, crew,
    patriot -- is selected through SET_PLAYER_RESERVE_PARACHUTE_TINT_INDEX,
    where those same numbers mean smoke rather than canopies. IT NEEDS A RESERVE
    PARACHUTE, and this gamemode deliberately never issues one: chute ammo above
    exactly 1 is what the engine reads as a reserve, and that has already been
    the cause of a "handed another parachute after pulling the first" bug
    (2026-08-04). Trading that rule for six fixed colours is a bad trade.

    SET_PLAYER_PARACHUTE_SMOKE_TRAIL_COLOR takes an RGB triple on the PRIMARY
    chute, which the squad system already uses. That gives us every colour
    instead of six, with no reserve involved.

    Two consequences worth stating plainly:
      * "Crew" has no meaning here. It is a GTA Online crew colour, and this
        game has squads instead -- which already colour the trail, for free,
        automatically. We do not need to sell it.
      * "Patriot" is multi-colour, which one RGB value cannot be. So it is
        rebuilt rather than imitated: a CYCLING trail that steps colours while
        you fall. That is more expensive than a solid because it is strictly
        more work to look at, and it is the only thing in the catalogue that
        animates.

    THE SQUAD COLOUR WINS IN A SQUAD. Trail colour is how you find your team in
    the air, and that is a gameplay read, not decoration. A bought trail applies
    when you are dropping alone; in a squad the squad colour overrides it. If
    that ever feels wrong, this is the paragraph to argue with.

    ========================== WEAPON TINTS ==========================

    SET_PED_WEAPON_TINT_INDEX recolours the weapon and nothing else.

    THIS REVERSES A STATED RULE, ON PURPOSE. Market.tsx used to say weapon skins
    were deliberately excluded, alongside tracer colours and anything that alters
    a hitbox. The rest of that rule stands. Tints do not: they are a texture
    swap on a model whose geometry, hitbox and silhouette are untouched, so two
    players with different tints present exactly the same target. The one real
    directional concern -- gold and platinum are BRIGHTER, and brighter is easier
    to see -- points at a self-disadvantage, which is the correct direction for
    anything sold.
]]

--- Solid smoke trail colours, as RGB. Kept together so the palette can be seen
--- at a glance rather than being scattered through the items.
local TRAIL = {
    EMBER   = { 255,  92,  16 },
    VOID    = {  22,  22,  30 },
    TOXIC   = { 140, 255,  40 },
    ICE     = { 120, 220, 255 },
    ROSE    = { 255,  90, 170 },
}

BR.Config.Market = {
    seasons = {
        {
            id = 'founders',
            name = 'Founders',
            -- Inactive seasons still render for the people who own their items;
            -- they simply cannot be bought.
            active = true,
            items = {
                -- ------------------------------------------------- canopies ---
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

                -- THE 8-13 SET. Documented as needing a model override, which
                -- this gamemode already applies -- so they are expected to
                -- work and are not yet observed to. Nothing can be bought at
                -- all until the purchase path lands, so there is no window in
                -- which a player could pay for one of these before the
                -- canopy audit confirms it renders.
                {
                    id = 'chute_airforce', name = 'Air Force', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 3000, rarity = BR.Config.Rarity.RARE,
                    apply = { chuteTint = 8 },        -- red/blue/green stripes
                },
                {
                    id = 'chute_desert', name = 'Desert', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 3000, rarity = BR.Config.Rarity.RARE,
                    apply = { chuteTint = 9 },        -- cream and tan stripes
                },
                {
                    id = 'chute_shadow', name = 'Shadow', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 4500, rarity = BR.Config.Rarity.EPIC,
                    apply = { chuteTint = 10 },       -- black and teal stripes
                },
                {
                    id = 'chute_highaltitude', name = 'High Altitude', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 4500, rarity = BR.Config.Rarity.EPIC,
                    apply = { chuteTint = 11 },       -- red and tan stripes
                },
                {
                    id = 'chute_airborne', name = 'Airborne', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 5000, rarity = BR.Config.Rarity.EPIC,
                    apply = { chuteTint = 12 },       -- white/orange/blue stripes
                },
                {
                    id = 'chute_sunrise', name = 'Sunrise', sub = 'Canopy',
                    kind = BR.Config.ItemKind.CHUTE,
                    price = 7500, rarity = BR.Config.Rarity.LEGENDARY,
                    apply = { chuteTint = 13 },       -- red/orange/yellow/blue
                },

                -- --------------------------------------------------- trails ---
                {
                    -- The default trail is the squad colour, which is what
                    -- happens today and costs nothing. `trailRgb = nil` means
                    -- "leave the squad system alone".
                    id = 'trail_squad', name = 'Squad Colour', sub = 'Smoke trail',
                    kind = BR.Config.ItemKind.TRAIL,
                    price = 0, rarity = BR.Config.Rarity.COMMON,
                    default = true,
                    apply = { trailRgb = nil },
                },
                {
                    id = 'trail_ember', name = 'Ember', sub = 'Smoke trail',
                    kind = BR.Config.ItemKind.TRAIL,
                    price = 800, rarity = BR.Config.Rarity.UNCOMMON,
                    apply = { trailRgb = TRAIL.EMBER },
                },
                {
                    id = 'trail_ice', name = 'Ice', sub = 'Smoke trail',
                    kind = BR.Config.ItemKind.TRAIL,
                    price = 800, rarity = BR.Config.Rarity.UNCOMMON,
                    apply = { trailRgb = TRAIL.ICE },
                },
                {
                    id = 'trail_toxic', name = 'Toxic', sub = 'Smoke trail',
                    kind = BR.Config.ItemKind.TRAIL,
                    price = 1400, rarity = BR.Config.Rarity.RARE,
                    apply = { trailRgb = TRAIL.TOXIC },
                },
                {
                    id = 'trail_rose', name = 'Rose', sub = 'Smoke trail',
                    kind = BR.Config.ItemKind.TRAIL,
                    price = 1400, rarity = BR.Config.Rarity.RARE,
                    apply = { trailRgb = TRAIL.ROSE },
                },
                {
                    id = 'trail_void', name = 'Void', sub = 'Smoke trail',
                    kind = BR.Config.ItemKind.TRAIL,
                    price = 2000, rarity = BR.Config.Rarity.EPIC,
                    apply = { trailRgb = TRAIL.VOID },
                },
                {
                    -- THE ONLY ANIMATED ITEM IN THE CATALOGUE, and the reason
                    -- it costs the most: one RGB value cannot be three colours,
                    -- so this steps between them while you fall. It is the
                    -- rebuild of the multi-colour canister trail we cannot
                    -- reach without issuing a reserve chute.
                    id = 'trail_patriot', name = 'Patriot', sub = 'Smoke trail',
                    kind = BR.Config.ItemKind.TRAIL,
                    price = 5000, rarity = BR.Config.Rarity.LEGENDARY,
                    apply = {
                        trailCycle = { { 235, 235, 240 }, { 200, 25, 45 }, { 30, 60, 190 } },
                        trailCycleMs = 350,
                    },
                },

                -- ---------------------------------------------- weapon tints ---
                {
                    id = 'wtint_normal', name = 'Standard', sub = 'Weapon finish',
                    kind = BR.Config.ItemKind.WEAPON,
                    price = 0, rarity = BR.Config.Rarity.COMMON,
                    default = true,
                    apply = { weaponTint = 0 },
                },
                {
                    id = 'wtint_green', name = 'Verde', sub = 'Weapon finish',
                    kind = BR.Config.ItemKind.WEAPON,
                    price = 900, rarity = BR.Config.Rarity.UNCOMMON,
                    apply = { weaponTint = 1 },
                },
                {
                    id = 'wtint_army', name = 'Army', sub = 'Weapon finish',
                    kind = BR.Config.ItemKind.WEAPON,
                    price = 900, rarity = BR.Config.Rarity.UNCOMMON,
                    apply = { weaponTint = 4 },
                },
                {
                    id = 'wtint_orange', name = 'Sunset', sub = 'Weapon finish',
                    kind = BR.Config.ItemKind.WEAPON,
                    price = 1400, rarity = BR.Config.Rarity.RARE,
                    apply = { weaponTint = 6 },
                },
                {
                    id = 'wtint_lspd', name = 'Bluesteel', sub = 'Weapon finish',
                    kind = BR.Config.ItemKind.WEAPON,
                    price = 1400, rarity = BR.Config.Rarity.RARE,
                    apply = { weaponTint = 5 },
                },
                {
                    id = 'wtint_pink', name = 'Fuchsia', sub = 'Weapon finish',
                    kind = BR.Config.ItemKind.WEAPON,
                    price = 2200, rarity = BR.Config.Rarity.EPIC,
                    apply = { weaponTint = 3 },
                },
                {
                    id = 'wtint_gold', name = 'Gold', sub = 'Weapon finish',
                    kind = BR.Config.ItemKind.WEAPON,
                    price = 5000, rarity = BR.Config.Rarity.LEGENDARY,
                    apply = { weaponTint = 2 },
                },
                {
                    id = 'wtint_platinum', name = 'Platinum', sub = 'Weapon finish',
                    kind = BR.Config.ItemKind.WEAPON,
                    price = 6500, rarity = BR.Config.Rarity.LEGENDARY,
                    apply = { weaponTint = 7 },
                },
            },
        },
    },
}

--[[
    WHAT A MATCH PAYS, kept next to what things cost.

    These two numbers only mean anything relative to each other -- a 1200 chute
    is cheap or extortionate depending entirely on what a match returns -- so
    they live in one file where changing one forces you to look at the other.
    Splitting them is how a storefront ends up with a legendary priced at four
    months of play and nobody noticing until somebody does the arithmetic.

    THE CURRENCY IS EARNED, NEVER BOUGHT. There is no purchase path, no top-up,
    and exactly one writer that can increase a balance (br_ddb's statsApply, at
    the end of a match). That is what makes "nothing here changes how a fight
    goes" a property of the system rather than a promise in a comment.

    EVERY MATCH PAYS SOMETHING. A player who drops, loses a fight in the first
    minute and finishes last still earns -- badly, but not nothing. Zero-payout
    matches teach people that playing was a waste of time, which is the exact
    opposite of what a progression system is for.

    Roughly calibrated so a middling match pays ~150 and a strong one ~400: an
    uncommon canopy is a handful of matches, a legendary is a season's habit.
]]
BR.Config.Market.payout = {
    completion   = 60,    -- for turning up and finishing
    win          = 240,
    placementTop = 150,   -- scaled linearly by how far up you finished
    perKill      = 20,
    perRevive    = 15,    -- paid because it is the least selfish thing you can do
}

--- What one match earned, in currency.
--- @param r table  the same result shape the XP curve reads
--- @return integer
function BR.Config.marketPayout(r)
    local p = BR.Config.Market.payout
    local earned = p.completion

    local placement = tonumber(r.placement) or 0
    local total     = tonumber(r.total) or 1

    if placement == 1 then
        earned = earned + p.win
    elseif placement > 0 and total > 1 then
        earned = earned + math.floor(p.placementTop * (1.0 - (placement - 1) / (total - 1)))
    end

    earned = earned + (tonumber(r.kills) or 0) * p.perKill
    earned = earned + (tonumber(r.revives) or 0) * p.perRevive

    return math.max(0, math.floor(earned))
end

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

--- Is this a real, currently-buyable item at this price?
---
--- THE SERVER'S QUESTION, not the client's. The client already knows what it
--- rendered; this exists so the purchase path can refuse a request that names
--- a default, an item from a closed season, or an id that does not exist --
--- without trusting anything the client said about it.
--- @param id string
--- @return table|nil item, string|nil why
function BR.Config.buyable(id)
    local item = BR.Config.MarketIndex[tostring(id or '')]
    if not item then return nil, 'no such item' end
    if item.default then return nil, 'already owned by everyone' end
    if not item.purchasable then return nil, 'not for sale' end
    return item, nil
end
