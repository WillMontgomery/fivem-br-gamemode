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

    0-7 ARE THE ONLY ONES THAT EXIST FOR US, and that is now observed rather
    than assumed. 8-13 are the flight-school designs, documented as needing a
    parachute model override -- which this gamemode already applies, so they
    were expected to work. Checked in game on 2026-08-15 (#78): every index
    above 7 renders as Hornet. The engine clamps to the standard canopy's range
    on p_parachute1_mp_s, so those six designs are simply not reachable from
    this model.

    THE 0-7 MAPPING BELOW IS VERIFIED IN THIS BUILD, by eye, on the same date.
    That is worth stating because it was not always true: an earlier version of
    this table was wrong about three of its four entries. `brchute` in the F8
    console is how it was checked and how it should be re-checked if the
    parachute model ever changes -- `brchute cycle` steps 0-7 with a re-deploy
    between each, since the tint is only read when the canopy opens.

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

                -- THE 8-13 SET IS GONE, AND THIS IS THE RECORD OF WHY.
                --
                -- Air Force, Desert, Shadow, High Altitude, Airborne and
                -- Sunrise were priced and sold on the strength of documentation
                -- saying they need a parachute model override -- which this
                -- gamemode already applies, so they were expected to resolve.
                --
                -- THEY DO NOT. Verified in game 2026-08-15 (#78): every index
                -- above 7 renders as Hornet. The engine clamps to the standard
                -- canopy's range on p_parachute1_mp_s, so the flight-school
                -- designs are not reachable from this model at all.
                --
                -- Six items that all looked identical, three of them priced
                -- above 4000. Pulled before there was an economy to spend in,
                -- which is the only reason this costs nothing: nobody owns one.
                --
                -- Reinstating them means a second parachute model, not a config
                -- edit -- and that is a gameplay change, since the model is what
                -- the drop sequence tasks and retries against.

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

    ================== RETUNED 2026-08-16, AND WHY (#89) ==================

    The first calibration paid a single match 470 Volts. Owner: "volts going
    from 665 to 1135 in one match is insane lol. It should be like MAYBE 1/3 of
    that max." So the whole table came down by roughly a third.

    THE INVERSION WAS THE INFORMATIVE HALF. In the same match the player who
    placed SECOND with one kill took 470, and the player who WON took 60 -- the
    loser earning nearly eight times the winner. A payout where placement is the
    headline term cannot do that, so placement was not the headline term. Two
    things were:

      * THE LEVEL-UP BONUS, which was the single largest line on the bill. At
        100 + 25/level it could exceed the win bonus outright, and the player
        who took 470 had just crossed a level while the winner had not. A bonus
        that beats the thing it is a bonus ON is not a bonus. It is now a
        quarter of a win rather than most of one.
      * THE RESULTS ROW REACHING THIS FUNCTION BLANK. 60 is `completion` and
        nothing else, which takes more than a missing placement: it needs
        placement ≠ 1, zero kills AND zero revives on the same row. The ENDED
        transition awards placements before it publishes results and nothing
        writes LOBBY in between, so this is not an ordering bug -- it is the
        shape of a row published by a SECOND ENDED transition, after
        BR.Match.resetPlayers has zeroed the per-match counters and cleared
        placement while leaving matchId intact. That is a defect upstream of
        this file and no amount of retuning here touches it: retuning a formula
        whose inputs are blank only changes which wrong number comes out.
        Called out so the next reader does not conclude these weights produced
        60.

    CALIBRATED SO PLACEMENT DOMINATES. Worked examples on a 16-player field:

      won it, no kills                 15 + 120                    = 135
      2nd, 1 kill, levelled to 3       15 +  65 + 10 + 35          = 125
      2nd, 4 kills                     15 +  65 + 40               = 120
      8th, 2 kills                     15 +  37 + 20               =  72
      last, nothing                    15                          =  15

    The win is the biggest single line in a winning match; placement is the
    biggest in every other one; kills are worth chasing without being the
    strategy; and the level-up is a punctuation mark you notice rather than the
    reason the number moved.

    WHAT THIS DOES TO THE PRICES ABOVE, stated rather than quietly absorbed: at
    ~70 for a middling match an uncommon canopy at 1200 is around 17 matches
    where it used to be 8, and a legendary at 6000 is 60-80 where it used to be
    40. The owner asked for a third of the payout and said nothing about
    prices, so prices are untouched -- but "a handful of matches" for an
    uncommon is no longer strictly true, and if that is the half that should
    have moved, it is the table at the top of this file.

    EVERY NUMBER BELOW IS MEANT TO BE ARGUED WITH. They are in one table, next
    to the prices, on purpose: retuning is editing five integers and re-reading
    the worked examples above, not tracing a formula through three files.
]]
BR.Config.Market.payout = {
    completion   = 15,    -- for turning up and finishing
    win          = 120,
    placementTop = 70,    -- scaled linearly by how far up you finished
    perKill      = 10,
    perRevive    = 8,     -- paid because it is the least selfish thing you can do
}

--- What the currency is called, in ONE place.
---
--- "Credits" is what every game calls this and it says nothing. Volts belongs
--- to Blitz Royale specifically, which is the whole job of a currency name.
--- Changing it is this line plus the matching constant in Ringmaster, which
--- cannot read Lua -- the only duplication, and it is deliberate rather than
--- an oversight.
BR.Config.Market.currency = 'Volts'

--- What crossing into a level is worth.
---
--- LEVELS PAY, AND LATER LEVELS PAY MORE, because the XP between them grows.
--- A flat bonus would mean the twentieth level-up felt worse than the second
--- despite taking four times as long, which is the exact shape of a
--- progression system people quit.
---
--- Deliberately modest against the match payout: this is a punctuation mark on
--- top of earning, not the earning itself. A player who levels every few
--- matches should notice it; a player grinding for a legendary should still be
--- getting there mostly by playing.
---
--- IT WAS NOT MODEST, AND THAT IS #89. At 100 + 25/level this line competed
--- with winning the match: level 3 paid 150 against a 240 win bonus, and at
--- level 7 it passed it outright and never came back. So the largest single
--- term in a session's earnings went to whoever happened to cross a boundary,
--- regardless of how they placed. 25 + 5/level puts it at roughly a quarter of
--- a win and keeps it there -- still growing with the curve, no longer racing
--- it.
---
--- THE INPUT THIS DEPENDS ON is `levelBefore`, which br_stats derives from a
--- lifetime total br_core publishes to it. When that total is missing the
--- damage is NOT an unbounded payout -- br_stats computes `after` as
--- `before + xpEarned`, so a zero `before` gives a small `after` and the loop
--- crosses at most a level or two. The real cost is the level itself: the
--- profile row and the verdict screen both take a veteran's level from one
--- match's XP. Small per-level numbers here are what keep the money half of
--- that failure boring while the level half gets fixed properly.
--- @param level integer  the level just reached
--- @return integer
function BR.Config.levelBonus(level)
    local n = math.max(1, math.floor(tonumber(level) or 1))
    return 25 + (n - 1) * 5
end

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
