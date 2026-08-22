-- Aerial supply drops (#88, first half).
--
-- MUST LOAD AFTER config/loot.lua AND config/weapons.lua. It reads their
-- rarity buckets to build its own pools, and it appends to
-- BR.Config.Consumables AFTER config/loot.lua has finished bucketing that
-- array -- which is exactly what keeps the airdrop-only items out of every
-- world roll. See "EXCLUSIVE MEANS EXCLUSIVE" below; tools/test_airdrop.lua
-- pins the property rather than trusting the load order to stay right.
--
-- ------------------------------------------------------------------------
-- THERE IS NO AIRDROP NATIVE. Researched before a line was written, because
-- the alternative was writing code that fights the engine (owner, 2026-08-21:
-- "the game should have natives for airdrops already, which spawn falling
-- from a parachute").
--
-- It does not. The `OBJECT` native namespace has nothing matching parachute,
-- cargo, crate, drop, supply or paradrop; the only parachute natives are ped
-- TASK natives. GTA Online's own crate drop (`am_crate_drop`) and ammo drop
-- (`am_ammo_drop`) are hand-rolled script: create the crate object, create a
-- SEPARATE chute prop, ATTACH_ENTITY_TO_ENTITY at (0, 0, 0.1), play the chute
-- deploy anim, ACTIVATE_PHYSICS, SET_ENTITY_VELOCITY (0, 0, -0.2) and
-- SET_DAMPING for the terminal-velocity feel.
--
-- WHAT WE TAKE FROM ROCKSTAR: the chute PROP and its anim. `p_cargo_chute_s`
-- is the purpose-built cargo canopy with its own dict/anim pair. It is NOT
-- BR.Config.Drop.parachuteModel (`p_parachute1_mp_s`) -- that is the player's
-- back-worn canopy, a different asset in a different category.
--
-- WHAT WE DELIBERATELY DO NOT TAKE: the physics. Every public FiveM airdrop
-- either networks the crate (which `sv_entityLockdown relaxed` refuses, and
-- which the Cfx.re issue tracker records as sporadically failing to sync at
-- all) or lets each client run its own physics simulation and then disagree
-- about where the crate landed. Our descent is a PURE FUNCTION of a record
-- the server published once plus the synced clock -- the same bet the storm
-- and the bus route already make. Nothing per-frame crosses the wire, every
-- client's crate is at the same place at the same millisecond because there
-- is no property for two machines to disagree about, and the object stays
-- `isNetwork = false` like everything else this gamemode creates.
-- ------------------------------------------------------------------------

BR = BR or {}
BR.Config = BR.Config or {}

local R = BR.Rarity

-- ---------------------------------------------------------------------------
-- EXCLUSIVE MEANS EXCLUSIVE
-- ---------------------------------------------------------------------------
--
-- Owner, 2026-08-21: "The air drops should have exclusive loot which is not
-- found anywhere else, and a LOT of it (up to 12 items), including our
-- upcoming CPR kit."
--
-- THE MECHANISM IS THE FISTS PATTERN (config/weapons.lua). An item is
-- resolvable everywhere -- the inventory, the label, the refusal sentence, the
-- pickup prompt all go through BR.Config.ConsumableById -- while being absent
-- from every rarity BUCKET, which is the only thing BR.RollLootStack ever
-- rolls against. Registered but never rolled. That is what "found nowhere
-- else" means mechanically, and it costs the world layout nothing: the buckets
-- were built by config/loot.lua before this file loaded, so a fixed seed still
-- produces a byte-identical map.
--
-- WHY ONLY ONE ITEM TODAY, AND WHY NOT NEW GUNS. The obvious way to make a
-- drop exclusive is exclusive WEAPONS, and config/weapons.lua forbids it in as
-- many words: "EXCLUSIONS ARE AN ANTI-CHEAT DECISION as much as a balance one.
-- RPG, minigun, railgun, grenade launcher and homing launcher are absent from
-- this table, which means they are absent from the entity allowlist." Adding
-- any of them to reach twelve exclusive items would hand a weapon-spawning
-- cheat back its highest-value targets, to decorate a crate. The other route
-- -- moving existing guns OUT of world loot to make them airdrop-only -- is a
-- balance change nobody asked for and would quietly gut the legendary tier of
-- every crate on the map.
--
-- So the airdrop's exclusivity is carried by CONSUMABLES, which are pure data
-- and touch no allowlist, and the guns in it are the hottest tiers the world
-- already has -- which is what a supply drop is in every game that has one.
BR.Config.AirdropItems = {
    {
        -- THE FULL SHIELD, and the only one in the game. `shield` takes you to
        -- 100 from 50 and stops; this is the only item that takes an unshielded
        -- player straight to the cap, which is exactly the swing worth
        -- contesting a drop for.
        id = 'heavyshield', label = 'Heavy Shield', plural = 'Heavy Shields',
        rarity = R.LEGENDARY,
        kind = BR.ItemKind.CONSUMABLE,

        -- THE SAME MODEL AS `shield`, SCALED UP, and that is the precedent
        -- rather than a shortcut: `minishield` is prop_bodyarmour_02 at
        -- propScale 0.5 for exactly this reason. Reusing a model already
        -- proven to load on this build beats naming a fifth
        -- prop_bodyarmour_0X nobody has seen render.
        prop = 'prop_bodyarmour_06', propScale = 1.30,

        useMs = 6000, maxStack = 2, carryMax = 2,
        armour = 100, armourCap = 100,

        -- Belt and braces. It is in no bucket at all, so neither flag can fire
        -- -- but if a later change ever DOES bucket it, chestOnly is what stops
        -- it landing on the floor as roadside filler.
        chestOnly   = true,
        airdropOnly = true,
    },
}

-- Registered by hand, into the id lookup ONLY.
--
-- Appended to BR.Config.Consumables so that everything which ENUMERATES
-- consumables -- /brpropscale's listing, /brgrant's grantable ids, the crate
-- simulator's per-item breakdown -- can see them. The rarity buckets are NOT
-- rebuilt, and must not be: config/loot.lua built them from this same array
-- before this file loaded, so appending here adds the item to every listing
-- and to no roll.
for _, c in ipairs(BR.Config.AirdropItems) do
    BR.Config.Consumables[#BR.Config.Consumables + 1] = c
    BR.Config.ConsumableById[c.id] = c
end

BR.Config.Airdrop = {
    enabled = true,

    -- EXACTLY ONE PER MATCH, NO MORE AND NO LESS (owner, 2026-08-21), and both
    -- halves of that sentence are a number here rather than a hardcoded truth.
    --
    -- `perMatch` is how many are SCHEDULED. `chance` is rolled once per
    -- scheduled drop, so a value below 1.0 is a probability that the match gets
    -- one at all -- which the owner asked for explicitly. At 1.0 the roll
    -- always passes and the match always gets exactly `perMatch`, subject to
    -- the siting rule below.
    perMatch = 1,
    chance   = 1.0,

    -- WHEN. Measured from the moment the match goes PLAYING, drawn uniformly.
    -- Early enough that the fight over it is a mid-game event rather than an
    -- endgame coin flip, late enough that everyone has landed and armed up.
    minDelayMs = 210000,   -- 3m30
    maxDelayMs = 420000,   -- 7m00

    -- HOW OFTEN THE SITING RULE IS RE-ASKED once the drop is due. See
    -- BR.AirdropSite: a circle mid-shrink is a different question five seconds
    -- later, so a re-check is progress rather than a spin.
    retryEveryMs = 5000,

    -- THE DESCENT. Linear, because a canopy descends at terminal velocity --
    -- 260m over 30s is ~8.7 m/s, which is about right for a cargo chute and
    -- gives the map roughly half a minute of everyone converging on the blip.
    --
    -- `altitude` is metres ABOVE THE GROUND, never an absolute z, and that
    -- distinction is the same one BR.Loot's `flift` makes: only a client can
    -- ground-probe, so an absolute z from the server is a guess. Each client
    -- resolves the ground under (x, y) itself and falls to it.
    descentMs = 30000,
    altitude  = 260.0,

    -- ------------------------------------------------------------------
    -- WHERE IT LANDS, AND THE TWO RULES THAT CAN CONTRADICT EACH OTHER
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-21: "Airdrops should use standard POIs as coords" and "it
    -- should only happen at a point which is going to be within the circle by a
    -- minimum of 250m".
    --
    -- Those two can have no answer at the same time, and often will: POIs are
    -- fixed and there are 107 of them, while a late circle is small and moves.
    -- Phase 4's target radius is 520m, so a 250m margin leaves a disc of radius
    -- 270m for a POI to sit in -- at this map's POI density that is empty more
    -- often than not.
    --
    -- THE DECISION: NEITHER RULE BENDS, AND A MATCH MAY GET NO AIRDROP.
    --
    -- The margin is a SAFETY property -- the drop has to be a fight, not a
    -- sprint into the wall -- and the POI rule is a PLACEMENT property. Picking
    -- "the nearest POI" would put the most valuable loot on the map outside the
    -- circle, or on its rim, which is worse than no drop at all: it converts
    -- the highest-value objective in the match into a death sentence for
    -- whoever contests it. Silently relaxing 250m to whatever happens to fit
    -- would be the same failure wearing a smaller number.
    --
    -- So when nothing qualifies the drop WAITS (retryEveryMs) and re-asks,
    -- because the circle is usually mid-shrink and the answer changes. If the
    -- phase cap below passes with nothing ever qualifying, this match gets no
    -- airdrop and the server log says exactly why. That is a deliberate
    -- zero, not a silent failure.
    --
    -- In practice the default delay lands during phase 1 or 2, where the radius
    -- is 2600m or more and dozens of POIs qualify, so the zero should be rare.
    insideBy = 250.0,

    -- NO AIRDROPS PAST STORM STAGE 4 (owner). Read against the published
    -- record's phase at the moment the drop is committed.
    maxPhase = 4,

    -- ------------------------------------------------------------------
    -- WHAT IS IN IT
    -- ------------------------------------------------------------------
    --
    -- One entry per item, so the length of this array IS the item count and
    -- "up to 12 items" is editable without arithmetic anywhere else. Each entry
    -- names a pool; each pool is shuffled once per drop and dealt from in
    -- order, so a twelve-item drop is twelve DIFFERENT things rather than the
    -- same rifle four times.
    payout = {
        'exclusive', 'exclusive',
        'legendary', 'legendary', 'legendary',
        'epic', 'epic',
        'throwable',
        'healing',
        'ammo', 'ammo', 'ammo',
    },

    -- The pools the payout draws from.
    --
    -- `bucket` reads a rarity bucket straight out of config/weapons.lua, so the
    -- drop tracks the weapon table automatically -- add a legendary rifle there
    -- and it is in the airdrop, with nothing to remember here.
    --
    -- `ids` names items explicitly, for the pools that are not a whole tier.
    pools = {
        -- The airdrop-only shelf. `cprkit` IS THE SEAM FOR #191 and nothing
        -- more: the id is named here, the resolver below skips ids that do not
        -- resolve, and the day #191 registers a `cprkit` consumable it appears
        -- in this pool with no change to this file. It is deliberately NOT
        -- defined here -- building it would be building #191.
        exclusive = { kind = 'consumable', ids = { 'heavyshield', 'cprkit' } },

        legendary = { kind = 'weapon', bucket = R.LEGENDARY },
        epic      = { kind = 'weapon', bucket = R.EPIC },

        -- A full stack, not one: an airdrop grenade is a plan, a single
        -- grenade is a coin flip (the same argument RollLootStack makes for
        -- pairs on the world tables).
        throwable = { kind = 'throwable', ids = { 'sticky', 'grenade' } },
        healing   = { kind = 'consumable', ids = { 'medkit' } },
        ammo      = { kind = 'ammo', ids = {
            BR.AmmoType.HEAVY, BR.AmmoType.MEDIUM, BR.AmmoType.SHELLS,
            BR.AmmoType.SMG, BR.AmmoType.LIGHT,
        } },
    },

    -- How far out the contents land, per item, when it bursts open. Same
    -- construction as a crate's scatter ring, one radius wider because twelve
    -- items in a crate's ring would stack inside each other.
    scatterSpread = 0.8,

    -- ------------------------------------------------------------------
    -- PROPS
    -- ------------------------------------------------------------------
    --
    -- THE EXISTING PAIR, and they work (owner: "see if we can continue using
    -- our existing ones"). Nothing about prop_box_wood05a stops it being
    -- airdropped, because the descent is a coordinate write on a local object
    -- rather than a physics fall -- there is no model that cannot be moved that
    -- way. So the "if we can't airdrop ours, we shouldn't use the same husk
    -- either" branch never opens: the open/closed pair stays a matched pair.
    --
    -- If a playtest says an airdrop crate has to LOOK different from the 1300
    -- ordinary ones, both lines move together and nothing else changes.
    crateProp = 'prop_box_wood05a',
    huskProp  = 'prop_box_wood05b',

    -- THE CARGO CANOPY, which is a different asset from the player's.
    -- `p_parachute1_mp_s` (BR.Config.Drop.parachuteModel) is the back-worn
    -- one; `p_cargo_chute_s` is the one Rockstar's own crate drop attaches to
    -- a crate, and it ships its own deploy anim. Base-game and streamed, so it
    -- needs nothing but RequestModel.
    chuteModel   = 'p_cargo_chute_s',
    chuteAnimDict = 'P_cargo_chute_S',
    chuteAnim     = 'P_cargo_chute_S_deploy',
    -- The offset Rockstar attaches at, verbatim.
    chuteOffset  = { x = 0.0, y = 0.0, z = 0.1 },

    -- ------------------------------------------------------------------
    -- THE BLIP
    -- ------------------------------------------------------------------
    --
    -- 161, BECAUSE THE OWNER NAMED IT (2026-08-21: "marked on everyone's map in
    -- the match with bliptype 161"). Worth knowing what it is: 161 is
    -- `radar_mp_noise`, an ANIMATED radiating-ripple icon -- not a crate. GTA's
    -- own crate-drop glyph is 306 (`radar_cratedrop`), which is what every
    -- public airdrop resource uses. Both are one number; the owner's choice is
    -- the default and the alternative is this line.
    blipSprite = 161,
    blipColour = 5,      -- the same yellow the loot blips use
    blipScale  = 1.2,
    -- Named, or GTA names the sprite after whatever mission it was drawn for
    -- and the pause-menu legend reads as something from a heist -- the lesson
    -- client/loot.lua's courtesy blips already paid for.
    blipName   = 'Airdrop',

    -- THE BLIP OUTLIVES THE LANDING BY A MINUTE (owner: "The blip should only
    -- appear until 1 minute after the drop hits the ground"). Long enough to
    -- run to, short enough that the contested window has an end.
    blipLingerMs = 60000,

    -- Verbatim, and it must stay verbatim (owner, 2026-08-21). Written here
    -- rather than inline so there is one copy to be wrong.
    notifyText = 'An airdrop is arriving! It brings ultra-rare loot - first come, first served.',
}

-- ---------------------------------------------------------------------------
-- POOL RESOLUTION
-- ---------------------------------------------------------------------------

--- Turn one pool definition into an array of stack TEMPLATES.
---
--- Resolved once, at load, for two reasons. It keeps BR.AirdropPayout pure --
--- it shuffles and copies, and looks nothing up -- and it means an id that does
--- not resolve (the `cprkit` seam, until #191 lands) is dropped ONCE here
--- rather than changing the number of RNG draws a payout burns.
--- @param p table
--- @return table[]
local function resolvePool(p)
    local out = {}

    if p.kind == 'weapon' then
        local bucket = p.bucket and BR.Config.WeaponsByRarity[p.bucket] or nil
        local src = bucket or {}
        if p.ids then
            src = {}
            for _, id in ipairs(p.ids) do
                local w = BR.Config.WeaponById[id]
                if w then src[#src + 1] = w end
            end
        end
        for _, w in ipairs(src) do
            out[#out + 1] = {
                item = w.id, kind = BR.ItemKind.WEAPON,
                rarity = w.rarity, count = 1, clip = w.clip,
            }
        end

    elseif p.kind == 'throwable' then
        for _, id in ipairs(p.ids or {}) do
            local t = BR.Config.WeaponById[id]
            if t then
                out[#out + 1] = {
                    item = t.id, kind = BR.ItemKind.THROWABLE,
                    rarity = t.rarity, count = t.maxStack or 1,
                }
            end
        end

    elseif p.kind == 'consumable' then
        for _, id in ipairs(p.ids or {}) do
            local c = BR.Config.ConsumableById[id]
            if c then
                out[#out + 1] = {
                    item = c.id, kind = BR.ItemKind.CONSUMABLE,
                    rarity = c.rarity, count = 1,
                }
            end
        end

    elseif p.kind == 'ammo' then
        for _, id in ipairs(p.ids or {}) do
            local a = BR.Config.AmmoPickups[id]
            if a then
                out[#out + 1] = {
                    item = id, kind = BR.ItemKind.AMMO,
                    rarity = BR.Rarity.COMMON, count = a.amount,
                }
            end
        end
    end

    return out
end

--- [poolName] = array of stack templates, in a FIXED order.
---
--- Built from arrays throughout -- BR.Config.WeaponsByRarity, the authored id
--- lists -- and never from a pairs() walk, for the reason loot_gen.lua states
--- at the top of its file: a payout must replay identically from a seed.
BR.Config.Airdrop.resolvedPools = {}
for _, name in ipairs({ 'exclusive', 'legendary', 'epic', 'throwable',
                        'healing', 'ammo' }) do
    local p = BR.Config.Airdrop.pools[name]
    if p then
        BR.Config.Airdrop.resolvedPools[name] = resolvePool(p)
    end
end
