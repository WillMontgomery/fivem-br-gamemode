-- Aerial supply drops (#88).
--
-- MUST LOAD AFTER config/loot.lua AND config/weapons.lua. It reads their rarity
-- buckets and their id lookups to build its own pools.
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
-- found anywhere else, and a LOT of it (up to 12 items)", and then, on what
-- that loot should be: "Things like explosives, RPGs, miniguns, etc are
-- exciting."
--
-- THE MECHANISM IS THE FISTS PATTERN (config/weapons.lua). A weapon is
-- resolvable everywhere -- the allowlist, the validator, the inventory, the
-- ground prop, the label -- through BR.Config.WeaponById, while being absent
-- from every rarity BUCKET, which is the only thing BR.RollLootStack ever rolls
-- against. Registered but never rolled. That is what "found nowhere else" means
-- mechanically, and it costs the world layout nothing: the buckets are built
-- from BR.Config.Weapons alone, so a fixed seed still produces a byte-identical
-- map. tools/test_airdrop.lua pins that by generating a whole layout and
-- looking, rather than by trusting this paragraph.
--
-- THE HEAVY SHIELD USED TO BE HERE AND IS GONE (owner, 2026-08-21: "We don't
-- need heavy shield to exist. That's not exciting."). Removed outright -- the
-- item, its registration and the test that pinned it -- rather than left
-- disabled, because a consumable that exists and is in no pool is indisting-
-- uishable from a bug for whoever reads this next.
--
-- `cprkit` IS STILL NAMED, IN THE HEALING POOL, AND IS STILL #191's SEAM. The
-- resolver below drops ids that do not resolve, so naming it costs nothing
-- today and costs no edit to this file on the day it exists.

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
    -- THE PLANE
    -- ------------------------------------------------------------------
    --
    -- The owner said no plane, then changed their mind (2026-08-21). It is
    -- hand-rolled, because there is no native for any of this -- and the thing
    -- it is modelled on is already in this repo: client/bus.lua's ghost flights
    -- (795-853) fly a LOCAL, non-networked Titan along a server-published timed
    -- route by direct coordinate writes against the synced clock, for warmup
    -- bystanders. That is an airdrop flyover with a different model and route.
    --
    -- NOTHING WAS TAKEN FROM kq_airdrop, the paid resource in the owner's
    -- project folder. Its plane and drop logic is Cfx.re escrow-ENCRYPTED (FXAP
    -- header), so there is no source to read; it is a commercial product with no
    -- licence permitting reuse; and its one readable spawn call is
    -- `CreateObject(model, coords, 1, 0, 0)` -- isNetwork = true, which
    -- `sv_entityLockdown relaxed` refuses outright. There was nothing to take
    -- and it would not have worked.
    --
    -- ═══ THE RELEASE IS NOT THE ANNOUNCEMENT, AND THAT IS WHAT THE PLANE
    --     BOUGHT ═══
    --
    -- Before the plane, the crate began falling at `tStart` -- the moment the
    -- server committed the drop and sent the record. Clients receive that record
    -- AFTER tStart, so there is no window in which a plane could be seen flying
    -- IN: by the time anyone knew, it would already be leaving.
    --
    -- So the record now carries a third timestamp. `tStart` is when the drop is
    -- announced and the blip goes up; `tRelease` is `planeLeadMs` later, when
    -- the plane is overhead and the crate leaves it; `tLand` is `descentMs`
    -- after that. Everyone gets the notification, looks up, and watches it
    -- arrive -- which is the entire point of having a plane rather than a crate
    -- that appears in the sky.
    --
    -- IT COSTS THE MATCH `planeLeadMs` OF EXTRA WARNING and nothing else. The
    -- siting rule is solved against the circle at tLand, so the margin is still
    -- honoured at the moment the crate actually arrives.
    planeLeadMs = 12000,

    -- The flyover is on the same bet as everything else here: a pure function of
    -- the record and the clock, so every client's plane is in the same place at
    -- the same millisecond with nothing on the wire. It flies a STRAIGHT LINE
    -- along `rec.heading` -- the same heading the crate rests at, which makes
    -- the box land pointing the way the plane was going -- and is over the drop
    -- point exactly at tRelease.
    --
    -- THE SAME MODEL AS THE BATTLE BUS, deliberately. It is already proven to
    -- load and fly on this build, its engine simulation is already understood
    -- (a seated ped is what keeps the props turning -- see bus.lua), and a
    -- supply drop arriving on the same airframe the match arrived on is a
    -- coherent world rather than a second aircraft to source.
    planeModel = 'titan',
    planePilot = 's_m_m_pilot_01',
    -- Metres a second. 90 is about 175 knots -- a cargo run rather than a strike
    -- package, and slow enough to be readable from the ground at 300m.
    planeSpeed = 90.0,
    -- Metres ABOVE THE CRATE's release altitude, never an absolute z. Same rule
    -- as `altitude` above and for the same reason: only a client can ground-probe.
    planeAltAbove = 40.0,
    -- How long it stays in the world after the release. Long enough to watch it
    -- go, short enough that it is gone before the fight over the crate starts.
    planeTrailMs = 15000,

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
        'volts',
        'legendary', 'legendary', 'legendary',
        'epic', 'epic',
        'throwable',
        'healing',
        'ammo', 'ammo',
    },

    -- The pools the payout draws from.
    --
    -- `bucket` reads a rarity bucket straight out of config/weapons.lua, so the
    -- drop tracks the weapon table automatically -- add a legendary rifle there
    -- and it is in the airdrop, with nothing to remember here.
    --
    -- `ids` names items explicitly, for the pools that are not a whole tier.
    pools = {
        -- THE AIRDROP SHELF: the four weapons that exist only here
        -- (BR.Config.AirdropWeapons). Named by id rather than by bucket, on
        -- purpose -- they are in no bucket, which is the whole of "not found
        -- anywhere else", and a bucket reference would silently pay out
        -- nothing the day someone re-tiered them.
        exclusive = { kind = 'weapon', ids = {
            'rpg', 'minigun', 'railgun', 'grenadelauncher',
        } },

        -- Volts. Not an inventory item at all -- see voltsAmount below.
        volts     = { kind = 'volts' },

        legendary = { kind = 'weapon', bucket = R.LEGENDARY },
        epic      = { kind = 'weapon', bucket = R.EPIC },

        -- A full stack, not one: an airdrop grenade is a plan, a single
        -- grenade is a coin flip (the same argument RollLootStack makes for
        -- pairs on the world tables).
        throwable = { kind = 'throwable', ids = { 'sticky', 'grenade' } },
        -- `cprkit` IS THE SEAM FOR #191 and nothing more: the id is named here,
        -- the resolver below skips ids that do not resolve, and the day #191
        -- registers a `cprkit` consumable it appears in this pool with no change
        -- to this file. It is deliberately NOT defined here -- building it would
        -- be building #191.
        healing   = { kind = 'consumable', ids = { 'medkit', 'cprkit' } },
        ammo      = { kind = 'ammo', ids = {
            BR.AmmoType.HEAVY, BR.AmmoType.MEDIUM, BR.AmmoType.SHELLS,
            BR.AmmoType.SMG, BR.AmmoType.LIGHT,
        } },
    },

    -- ------------------------------------------------------------------
    -- VOLTS, AND WHY THE PICKUP IS NOT A WRITE
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-21: "Yes Volts should be a loot item in the air drops, and
    -- they should be 100 Volts. This should be an item that does not go into
    -- inventory - they simply pick it up and it's gone. Simple notification that
    -- they collected 100 Volts, and that's it."
    --
    -- WHAT IT IS ON THE GROUND: an ordinary loot registry entry of kind
    -- 'volts'. It inherits the whole hardened claim path -- range-checked
    -- against the roster's own sampled position, rate-limited, first-come
    -- arbitrated, refused identically for an entry that was never streamed to
    -- you and for one that no longer exists (docs/security.md). It is the
    -- highest-value single entry on the map, so re-earning that for a bespoke
    -- pickup would have been the wrong trade.
    --
    -- WHAT IT IS NOT: a second writer of a balance. The claim handler credits
    -- the roster entry and nothing else; the number rides the match results
    -- envelope into BR.Config.marketPayout and lands in the SAME atomic ADD as
    -- the match payout and the level-up bonus. config/market.lua's "exactly one
    -- writer that can increase a balance" stays literally true, and #88 asked
    -- for that explicitly ("it keeps the one-writer property intact").
    --
    -- The player is told at the moment they pick it up either way, which is the
    -- half the owner described. A player who leaves the match before it ends
    -- forfeits it along with their XP, their kills and their placement -- the
    -- rule roster.lua already applies to everything else a match earned.
    voltsAmount = 100,
    -- The prop the pile is drawn as. A vanilla money bundle: this is currency
    -- on the floor and it should read as currency on the floor.
    voltsProp   = 'prop_anim_cash_pile_01',

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
    -- one; `p_cargo_chute_s` is the one Rockstar's own crate drop hangs over
    -- a crate, and it ships its own deploy anim. Base-game and streamed, so it
    -- needs nothing but RequestModel.
    chuteModel   = 'p_cargo_chute_s',
    chuteAnimDict = 'P_cargo_chute_S',
    chuteAnim     = 'P_cargo_chute_S_deploy',
    -- Rockstar's own offset, in the crate's LOCAL frame: right/forward/up in
    -- metres from the crate's centre. Their script reaches it with
    -- ATTACH_ENTITY_TO_ENTITY; we reach it by writing the canopy's coordinates
    -- from the same solver the crate's come from. See the note on rigid parts
    -- in br_core/client/airdrop.lua for why.
    chuteOffset  = { x = 0.0, y = 0.0, z = 0.1 },

    -- ------------------------------------------------------------------
    -- THE FLARES
    -- ------------------------------------------------------------------
    --
    -- Owner, 2026-08-21: "we need to attach flares to the left and right side of
    -- the crate when it's spawned so the flares leave smoke trails as it falls."
    --
    -- ONE PROP AND ONE LOOPED PARTICLE PER SIDE. The prop is what you see when
    -- the particle asset does not stream; the particle is the trail. Both are
    -- local, non-networked and positioned by the same solver as the crate --
    -- nothing here is simulated, so every screen draws the flares in the same
    -- place at the same millisecond for the same reason the crate is.
    --
    -- WHY A LOOPED PTFX ANCHORED TO THE FLARE IS THE RIGHT SHAPE, and why the
    -- lesson client/bus.lua learned does not apply here. That file records two
    -- rounds of failed tuning on engine smoke for the battle bus: "particles
    -- detach into world space with no slipstream". That is precisely what a
    -- flare wants -- the emitter rides the falling prop, the smoke it has
    -- already made stays where it was made, and the shape that leaves behind IS
    -- the trail. Exhaust needed particles to keep up with a plane; a trail needs
    -- them not to.
    --
    -- `core` / `proj_flare_trail` IS GTA'S OWN FLARE TRAIL, from the base-game
    -- particle asset, so it needs nothing streamed from a DLC pack. UNVERIFIED
    -- IN GAME -- nothing outside a running client can say how big or how bright
    -- it reads, which is why the asset, the effect, the scale and the offsets
    -- are all numbers here rather than literals in the client. Rockstar's own
    -- air-dropped packages use a `*_package_flare` effect out of the DLC script
    -- assets (`scr_gr_def`, `scr_ba_bb`); if a playtest wants that instead it is
    -- these two lines.
    flareProp      = 'prop_flare_01a',
    flarePtfxAsset = 'core',
    flarePtfxName  = 'proj_flare_trail',
    flarePtfxScale = 1.0,
    -- In the crate's LOCAL frame, so they stay on the crate's left and right
    -- faces while it yaws. One per side, and the sign is the only difference.
    flareOffset    = { x = 0.55, y = 0.0, z = 0.0 },

    -- HOW FAR THE CRATE TURNS OVER THE WHOLE DESCENT, in degrees. A crate under
    -- a canopy that never turns reads as a prop sliding down an invisible rail.
    -- A number rather than a literal in the client because the flares' world
    -- positions are derived from it, so the two cannot disagree.
    spinDegrees = 30.0,

    -- ------------------------------------------------------------------
    -- THE BLIP
    -- ------------------------------------------------------------------
    --
    -- 161 IS THE POINT, NOT A COMPROMISE. It was first written down here as the
    -- owner's choice over GTA's crate-drop glyph (306, `radar_cratedrop`), as
    -- though a crate glyph were the thing we could not have. It is the other way
    -- round -- owner, 2026-08-21: "bliptype 161 is what I want - it will give
    -- them a radius, not an exact point. That's why we want 161."
    --
    -- 161 is `radar_mp_noise`, the animated radiating-ripple icon, and a ripple
    -- is an AREA. That is the design: everyone in the match learns roughly where
    -- the drop is coming down and has to find it, rather than being handed a
    -- pixel to run at. A crate glyph would answer the question the search is
    -- supposed to be. Do not "fix" this to 306.
    --
    -- IT IS AN ORDINARY SPRITE ON AN ORDINARY COORD BLIP, checked against the
    -- Cfx blip reference after the 2026-08-22 playtest reported no marker. The
    -- RADIUS blips are 9 and 10 (`radar_radius_blip`,
    -- `radar_radius_outline_blip`) and are made with AddBlipForRadius, which
    -- takes no sprite at all -- so "gives them a radius" is what 161 LOOKS like
    -- and does not mean this wants a radius blip.
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

    elseif p.kind == 'volts' then
        -- ONE TEMPLATE, NO ids LIST. There is exactly one thing this pool can
        -- pay and the amount is the config's, so the deck is a single card and
        -- every slot pointing at this pool deals the same 100 Volts. `count`
        -- carries the amount because that is the field wireEntry already sends;
        -- nothing new travels for this.
        --
        -- 'volts' IS A BARE STRING BECAUSE THE OTHER NON-INVENTORY KINDS ARE.
        -- BR.ItemKind names what a SLOT can hold, and this is the one loot kind
        -- that never reaches a slot -- so it sits beside 'chest', 'husk' and
        -- 'deathbox', which are literals in server/loot.lua and client/loot.lua
        -- for the same reason.
        out[#out + 1] = {
            item = 'volts', kind = 'volts',
            rarity = BR.Rarity.LEGENDARY,
            count = BR.Config.Airdrop.voltsAmount or 100,
            prop = BR.Config.Airdrop.voltsProp,
        }
    end

    return out
end

--- [poolName] = array of stack templates, in a FIXED order.
---
--- Built from arrays throughout -- BR.Config.WeaponsByRarity, the authored id
--- lists -- and never from a pairs() walk, for the reason loot_gen.lua states
--- at the top of its file: a payout must replay identically from a seed.
BR.Config.Airdrop.resolvedPools = {}
for _, name in ipairs({ 'exclusive', 'volts', 'legendary', 'epic', 'throwable',
                        'healing', 'ammo' }) do
    local p = BR.Config.Airdrop.pools[name]
    if p then
        BR.Config.Airdrop.resolvedPools[name] = resolvePool(p)
    end
end
