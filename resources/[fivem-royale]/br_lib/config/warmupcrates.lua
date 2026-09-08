-- The four permanent crates on the warmup island: where they are, what rarity
-- each one pays, and how long the island has to be empty before one resets.
--
-- ═══════════════════════════════════════════════════════════════════════════
-- WHAT THESE ARE, AND WHY THEY ARE THE ONLY ONES
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, 2026-09-04: "We need 4 crates in warmup that are persistent entities
-- and can be cycled through open/closed states infinitely... These crates will
-- be special and the only ones to do this anywhere in the game. First crate in
-- that list should be common loot, and last should be legendary loot.
-- Everything in between will increase in rarity until #4."
--
-- Every other container in this game is a one-shot: it is opened, it becomes a
-- husk, and the husk is scenery for the rest of the match (see toHusk in
-- br_core/server/loot.lua). The warmup pad's crates respawn, but SOMEWHERE
-- ELSE -- server/loot.lua's `loot.warmupRespawn` job puts a replacement at a
-- fresh random point on the island, which is the right answer for 220 crates
-- and the wrong one for four that are meant to be found in the same four
-- places forever.
--
-- ═══ THE COORDINATES ARE SURVEYED AND ARE USED LITERALLY ═══
--
-- The owner stood on each of these four spots and read the numbers off. This
-- project does not round them, does not lower them, and does not run a ground
-- probe over them -- config/match.lua's `warmupSpawns` carries the same rule in
-- the same words ("Sited by the owner, and used exactly as surveyed: this
-- project does not round, adjust or 'correct' his coordinates").
--
-- And a probe would be actively wrong here rather than merely unnecessary.
-- GetGroundZFor_3dCoord answers with the highest ground BELOW the point it is
-- given -- the write-up above PROBE_FROM_Z in br_core/client/loot.lua is the
-- record of what that cost the last time it was trusted, and the 2026-09-03
-- bridge report is the record of it succeeding with the wrong surface. These
-- four heights are measurements. There is nothing for a probe to add.
--
-- br_core/client/warmupcrates.lua is what makes that stick: the loot pipeline
-- probes for every prop it builds, so the crate arrives at a probed height and
-- is then pinned back onto the surveyed one and frozen there.
--
-- ═══ WHY THE LADDER IS FOUR VALUES OUT OF FIVE ═══
--
-- The owner named both ends -- #1 common, #4 legendary -- and asked for the
-- middle two to "increase in rarity until #4". Four crates over five rarities
-- means exactly one tier is not represented, and UNCOMMON is the one dropped:
-- it is the least distinct step (grey to green reads as "the same crate again"
-- at the distance the tutorial's marker will be seen from), while
-- common -> rare -> epic -> legendary reads as four separate promises.
--
-- THAT IS THE ONE DECISION HERE THE OWNER DID NOT MAKE, and it is a single
-- edit: change `rarity` on anchor 2 or 3 below and nothing else has to move.
-- The rarity is authored per anchor rather than derived from the index, so the
-- ladder is legible as a ladder.

BR = BR or {}
BR.Config = BR.Config or {}

local R = BR.Rarity

BR.Config.WarmupCrates = {
    -- OFF IS REPRESENTABLE. These four are the only permanently-cycling
    -- containers in the game, so "turn them off and see whether the symptom
    -- goes away" is a diagnostic worth being able to run without deleting a
    -- file from a manifest.
    enabled = true,

    -- ═══ THE OWNER'S FOUR PLACEMENTS, IN HIS ORDER ═══
    --
    -- The order is the ladder: index 1 is the first line of his message and the
    -- common one, index 4 is the last line and the legendary one. Do not sort
    -- this table.
    anchors = {
        { x = 4523.67, y = -4453.56, z = 4.77, heading = 334.5, rarity = R.COMMON },
        { x = 4526.88, y = -4459.69, z = 4.36, heading = 292.1, rarity = R.RARE },
        { x = 4528.40, y = -4464.43, z = 4.45, heading = 291.4, rarity = R.EPIC },
        { x = 4532.05, y = -4471.95, z = 4.27, heading = 290.7, rarity = R.LEGENDARY },
    },

    -- HOW MANY THINGS ARE IN ONE. Fixed rather than weighted like
    -- BR.Config.Loot.chestItems, and the difference is deliberate: a world
    -- crate's haul varies so that opening one is a small gamble, and these four
    -- are a rehearsal. A player who opens the legendary crate twice and gets
    -- two items once and four the next time learns nothing about either.
    items = 3,

    -- ═══ WHEN A CRATE RESETS ═══
    --
    -- Owner: "After they walk away any loot from the crate will animate back
    -- into the crate and the husk entity will revert to a full crate entity."
    --
    -- Two numbers rather than one, because "walked away" and "walked away and
    -- stayed away" are different claims and only the second is safe to act on.
    -- A player who steps back four metres to look at what fell out has not left,
    -- and resetting under them would eat loot they were about to pick up.
    --
    -- ═══ ABOUT TEN FEET, WHICH IS THE OWNER'S NUMBER ═══
    --
    -- 2026-09-05: "walking away from a special crate for it to refill should only
    -- be like a 10ft radius from it." This was 22m, chosen so that a player who
    -- could still SEE the crate glowing was holding it open -- and the argument
    -- was wrong about what a player wants. These four exist to be opened over
    -- and over; taking two steps back and having one reset is the behaviour, not
    -- a hazard.
    --
    -- 4.0m RATHER THAN 3.05m, AND THE HALF-METRE IS LOAD-BEARING. Ten feet is
    -- 3.05m, which is INSIDE BR.Config.Loot.pickupDistance (3.5) -- so a crate
    -- set to exactly ten feet would start its reseal timer on a player who is
    -- still close enough to pick the loot up, and five seconds later animate it
    -- home out of their hands. Whatever this number becomes it must stay above
    -- pickupDistance, or the reset eats loot the player can still reach.
    --
    -- AND IT NO LONGER HOLDS THE NEIGHBOURS OPEN. The crates are 6-8m apart, so
    -- at 22m standing at one kept all four awake and at 4.0m each is on its own
    -- -- which is what makes "walk away and it refills" mean anything.
    leaveRadius = 4.0,
    -- ...AND HAS BEEN GONE THIS LONG. Long enough that a lap around the crate
    -- does not trip it, short enough that the next player up the beach finds it
    -- sealed. It is the whole of the "infinitely" in the request: nothing else
    -- decides when the cycle comes round again.
    settleMs    = 5000,

    -- HOW LONG THE LOOT TAKES TO FLY HOME, milliseconds. Matched to
    -- BR.Config.Loot.arriveMs (520) on purpose -- this is that flight run
    -- backwards, and two different durations for one movement in two directions
    -- would read as a different mechanism rather than the same one undone.
    returnMs = 520,

    -- ═══ ONE BLIP ON THE MAP, SO THEY CAN BE FOUND AT ALL ═══
    --
    -- Owner, 2026-09-06: "we need to inform them that said crates even exist.
    -- They may not have noticed, and they're not going to spawn facing the
    -- crates necessarily. Perhaps we should put a blip on their map near the
    -- crates?"
    --
    -- ONE FOR THE ROW, NOT FOUR. The anchors are 6-8m apart, which is less than
    -- a blip is wide on the minimap at any zoom -- four would draw as one smear
    -- and would say "four separate places to go" when the truth is one place
    -- with four boxes in it. Placed at the centroid of the four, computed rather
    -- than authored, so moving an anchor moves the blip.
    --
    -- SHORT RANGE, so it appears when they are near enough for it to be an
    -- answer rather than sitting on the world map as a destination. Everyone in
    -- warmup gets it, on the same argument the rarity markers now carry: these
    -- crates are not a tutorial feature.
    --
    -- NO BLOCK, NO BLIP -- config/revivekey.lua's rule. Numbers inside it fall
    -- back; the table's absence is an operator saying no.
    blip = {
        -- ═══ THE COURTESY BLIP'S OWN ICON, DELIBERATELY ═══
        --
        -- Owner, 2026-09-08: "change the blip type to match the one used in
        -- courtesy blips so they'll recognize courtesy blips when they see
        -- them." 457 is the briefcase, and client/loot.lua's own note explains
        -- the choice: "a courtesy blip is saying 'there is loot over there', and
        -- a briefcase reads as loot at a glance where the generic 68 did not."
        --
        -- SO THIS IS TEACHING, NOT DECORATION. The four practice crates are the
        -- first loot marker a new player ever sees; making it a different icon
        -- from the real one would teach them to recognise something the game
        -- never shows again. Colour 5 is that blip's too.
        sprite = 457,
        colour = 5,
        scale  = 0.85,
        name   = 'Practice Crates',
        -- FLASHING, because it is up for one card and has to be found (owner,
        -- 2026-09-08). The courtesy blip does not flash and must not start: it
        -- is up for a whole match, and a flashing marker that never stops is a
        -- thing players learn to ignore.
        flash  = true,
    },

    -- WHERE IT FLIES TO: metres above the crate's base, i.e. its mouth. Same
    -- number and same meaning as BR.Config.Loot.crateMouthHeight, which is where
    -- the contents came OUT of when the crate was opened.
    mouthLift = 0.6,

    -- HOW FAR FROM THE CRATE AN ITEM MAY BE AND STILL BE ITS ITEM.
    --
    -- The server identifies a crate's spilled contents by their recorded origin
    -- (`fx`/`fy`, written by BR.Loot.spawnStack from the container's own
    -- position), which is an exact match and cannot collide with anything else
    -- on the island. This is the SECOND condition, and it exists only to bound
    -- what a wrong answer could ever reach: LOOT_FIX can walk an entry up to
    -- 30m from where it was born, and an item that has been moved that far is
    -- not sitting in a pile at the crate's feet any more. 12m is comfortably
    -- outside the widest spill a 4-item crate produces (about 2.2m) and
    -- comfortably inside the repair bound.
    returnRadius = 12.0,

    -- ═══ THE PIN, WHICH IS HOW "FROZEN" IS ACTUALLY DONE ═══
    --
    -- br_core/client/loot.lua builds every container DYNAMIC, unfrozen and
    -- gravity-bound, on purpose -- "drive into one and it moves" (user,
    -- 2026-08-05) -- and that is exactly what these four must not do. The
    -- client-side pin finds each crate's prop and freezes it onto the surveyed
    -- coordinates; these two numbers are how it decides which object is which
    -- crate's.
    --
    -- `radius` is the SEARCH and `tolerance` is the TEST, and they are wildly
    -- different sizes on purpose.
    --
    -- The search is mostly VERTICAL slack: a prop is built at its entry's exact
    -- x/y but at a PROBED height, so the object can be most of a metre off the
    -- surveyed z before the pin ever reaches it, and a sphere has to be wide
    -- enough to contain that however the terrain reads on the day.
    --
    -- Widening it costs nothing, which is the part worth writing down.
    -- GetClosestObjectOfType answers with the NEAREST match, and the crate this
    -- anchor owns is within about 40cm of the anchor in 3D -- so a wider sphere
    -- can only ever pick up a different crate if that crate is nearer than 40cm,
    -- and one of the 220 randomly-sited island crates landing inside 40cm of a
    -- surveyed point is not a case anybody needs to have designed for. Anything
    -- further away loses to ours before the tolerance is even consulted.
    --
    -- The tolerance is then the confirmation, in the plane where the answer is
    -- exact: the loot spawner never probes x or y, and the hover animation
    -- writes both back verbatim every frame, so a correctly-identified prop is
    -- within centimetres. 0.35m is slack for the fraction of a second between
    -- the object being created and the pin reaching it.
    pinRadius    = 6.0,
    pinTolerance = 0.35,

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE BOBBING MARKER OVER EACH CRATE
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- Owner, 2026-09-04: "we'll draw their attention to these items by drawing
    -- a bobbing 3dmarker type 0 over these crates... The color of each marker
    -- above the crate will correspond to the rarity of it's loot."
    --
    -- ═══ IT IS OFF UNTIL SOMEBODY ASKS FOR IT ═══
    --
    -- There is no `enabled` here on purpose, and its absence is the design.
    -- These markers exist to serve the guided first run (#261) -- they are the
    -- tutorial pointing at four boxes -- and a player on their fiftieth warmup
    -- does not need four cones burning over the pad. So the switch is a
    -- RUNTIME one (BR.WarmupCrates.markers(on) in client/warmupcrates.lua), not
    -- a config one: the tutorial turns them on when it starts and off when it
    -- ends, and a config flag would be a second, slower answer to a question
    -- that has to change several times per player per session.
    --
    -- What IS here is the shape of the thing once it is on. Turning the whole
    -- feature off is `BR.Config.WarmupCrates.enabled = false`, which takes the
    -- crates with it -- which is correct, because a marker over nothing is not
    -- a state worth being able to reach.
    --
    -- ⚠ ONE OF THESE IS THE OWNER'S NUMBER AND THE REST ARE NOT. He named the
    -- marker TYPE and the colour RULE and nothing else; every distance, size
    -- and duration below is a starting point chosen to be readable, in the same
    -- spirit as config/revivekey.lua's `marker` block. They are expected to
    -- come back from the first playtest changed.
    marker = {
        -- HIS NUMBER, AND THE ONLY ONE HERE THAT IS. Named explicitly rather
        -- than left as a literal at the draw call so that "3dmarker type 0" is
        -- greppable from his own words.
        --
        -- WHAT TYPE 0 ACTUALLY DRAWS IS NOT VERIFIED HERE. It is the number he
        -- asked for, passed through -- client/loot.lua's `fallbackMarkerOf`
        -- carries the same disclaimer for the same reason: two published
        -- versions of this enum have disagreed with the game's own parser on
        -- this project before, so nothing in this file claims to know what
        -- appears on screen.
        kind = 0,

        -- `size` IS BOTH HORIZONTAL AXES AND `height` IS THE VERTICAL ONE --
        -- see DrawMarker's (scaleX, scaleY, scaleZ) at the call in
        -- client/warmupcrates.lua. Same split, same names and same meaning as
        -- config/revivekey.lua's marker, so the two read as one idea.
        --
        -- Smaller than the revive key's 0.8: that one stands alone on open
        -- ground and this one stands over a metre-wide box in a row of four
        -- crates 6-8m apart. Four large cones over four boxes at that spacing
        -- read as one wall of colour rather than as four separate promises,
        -- which is the whole point of the rarity ladder.
        size   = 0.55,
        height = 0.55,

        -- ═══ HOW HIGH IT FLOATS, MEASURED FROM THE CRATE'S SURVEYED z ═══
        --
        -- The anchor z is the crate's BASE -- the number the owner read off
        -- standing on the spot, and the height the pin holds the prop at -- so
        -- this has to clear the box itself before it clears anything else.
        -- The sealed container model is roughly a metre tall, and the marker
        -- wants to be read from across the pad rather than to sit on the lid.
        --
        -- ⚠ THE FIRST NUMBER TO CHECK IN A PLAYTEST. It is derived from the
        -- model's rough height and nothing more; whether type 0's origin is its
        -- point, its base or its centre is exactly the thing the note on `kind`
        -- above refuses to guess at, and this number absorbs whichever it is.
        lift = 1.60,

        -- ═══ THE BOB ═══
        --
        -- `bobM` is how far it travels either side of `lift`, in metres, and
        -- `bobMs` is one complete up-and-down.
        --
        -- DELIBERATELY NOT DrawMarker's OWN `bobUpAndDown` FLAG, which the
        -- engine offers for free and which client/loot.lua uses on the
        -- no-prop fallback marker. Two reasons, and the second is the one that
        -- settles it:
        --
        --   The engine's bob is a fixed amplitude and a fixed rate. The owner
        --   asked for a bob and the request behind it is "draw their
        --   attention" -- which is a thing to TUNE against a real pad with real
        --   crates on it, and a flag has no numbers to turn.
        --
        --   And these four are a ROW. A sine driven off the shared game clock
        --   puts all four markers on the same phase, so the pad rises and falls
        --   as one object and reads as a set that was placed; four independent
        --   engine bobs would be four things that happen to be near each other.
        --
        -- THE DRAW PASSES `false` FOR THAT FLAG, and it has to: the two bobs
        -- would otherwise stack into a beat nobody authored. That is written
        -- down at the call as well, because it is the kind of thing a later
        -- reader turns on "to make it bob".
        --
        -- 2.2 seconds and 14cm is a float rather than a bounce, matching
        -- client/loot.lua's shine pulse, whose note is the precedent: the fast
        -- version "read as flashing", and this is "a fade you notice without
        -- being nagged by it".
        bobM  = 0.14,
        bobMs = 2200,

        -- ═══ TWO ALPHAS, BECAUSE A CRATE HAS TWO STATES ═══
        --
        -- The RGB is never authored here -- it is BR.RarityInfo[rarity].rgb,
        -- the same table client/loot.lua paints its rarity discs from and the
        -- same one the NUI borders come out of. That is the owner's "the color
        -- ... will correspond to the rarity", and a palette in this file would
        -- be a second spelling of it free to drift.
        --
        -- Alpha is the one channel left, and it carries the OTHER fact: whether
        -- there is anything in the box right now. `open` is the husk -- looted,
        -- and about to reseal itself once everybody walks away. It is dimmed
        -- rather than hidden; the argument for that is at `markerAlpha` in
        -- client/warmupcrates.lua, where the nil case lives too.
        alpha     = 200,
        openAlpha = 70,

        -- How far away it is drawn, in metres.
        --
        -- WIDER THAN THE PROP RANGE, WHICH IS THE POINT. BR.Config.Loot's
        -- `propDistance` is 180m and the pad's own layout is 460m across, so a
        -- marker gated on the prop would only appear once the player was
        -- already close enough to see the crate -- which is a signpost that
        -- lights up after you have arrived. The marker is drawn from the
        -- surveyed coordinates and needs no prop, so it can outrun one.
        drawM = 250.0,
    },

    -- The reset's own message, S->C: which items are flying home and where they
    -- are flying to. Named here rather than in br_lib/shared/protocol.lua beside
    -- BR.Net -- which is where it belongs and where it should move -- because
    -- both halves of this feature read this file and neither should carry a
    -- string the other also spells out.
    -- THE NAME LIVES IN BR.Net NOW (protocol.lua). Kept here as a pointer
    -- rather than a value: a config file is for numbers an operator may
    -- retune, and an event name is a contract between two Lua states. Read
    -- BR.Net.WARMUP_CRATE_RETURN.
}

--- One item at a KNOWN rarity, rather than at a rolled one.
---
--- ═══ WHY THIS IS NOT BR.RollLootStack ═══
---
--- That function takes a TIER and rolls a rarity out of it
--- (BR.Config.RollRarity), which is right for 1300 world crates and is the one
--- thing these four must not do: the owner authored their rarities, so there is
--- nothing to roll. Everything else about a crate item -- which kinds appear
--- and how often, which tables they come from, how ammo and throwables count --
--- is read out of the same shipped config tables that function reads, so a
--- retune of BR.Config.KindWeights or of any rarity bucket lands here too.
---
--- MELEE IS THE ONE DELIBERATE OMISSION. BR.RollLootStack gives a crate weapon
--- roll an 18% chance of a machete instead, and BR.Config.MeleeByRarity has
--- nothing at LEGENDARY at all -- so the legendary crate's headline item would
--- have been a one-in-six chance of a knife that BR.LootPickOfRarity had walked
--- down to EPIC to find. These four crates exist to show a player what a rarity
--- looks like; a silent downgrade is the opposite of that.
---
--- @param rng table      a BR.Rng instance
--- @param rarity integer BR.Rarity.*
--- @return table stack
function BR.WarmupCrateItem(rng, rarity)
    local kind = BR.Config.RollKind(rng)

    if kind == BR.ItemKind.AMMO then
        -- Ammo has no rarity of its own anywhere in this project, so the
        -- authored rarity is spent on the pool and nothing else -- exactly as
        -- BR.RollLootStack does it.
        local pool = rng:pick(BR.Config.AmmoOrder)
        local def  = BR.Config.AmmoPickups[pool]
        return {
            item   = pool,
            kind   = BR.ItemKind.AMMO,
            rarity = BR.Rarity.COMMON,
            count  = def.amount,
        }
    end

    if kind == BR.ItemKind.CONSUMABLE then
        local c = BR.LootPickOfRarity(rng, BR.Config.ConsumablesByRarity, rarity)
        return {
            item   = c.id,
            kind   = BR.ItemKind.CONSUMABLE,
            rarity = c.rarity,
            count  = 1,
        }
    end

    if kind == BR.ItemKind.THROWABLE then
        local t = BR.LootPickOfRarity(rng, BR.Config.ThrowablesByRarity, rarity)
        return {
            item   = t.id,
            kind   = BR.ItemKind.THROWABLE,
            rarity = t.rarity,
            count  = math.min(t.maxStack or 1, rng:int(1, 2)),
        }
    end

    local w = BR.LootPickOfRarity(rng, BR.Config.WeaponsByRarity, rarity)
    return {
        item   = w.id,
        kind   = BR.ItemKind.WEAPON,
        rarity = w.rarity,
        count  = 1,
        clip   = w.clip,
    }
end

--- The contents of one anchored crate, guaranteed to DISPLAY the rarity it was
--- authored with.
---
--- ═══ "GUARANTEED" IS THE WHOLE JOB, AND IT IS NOT FREE ═══
---
--- A container's displayed rarity is the best thing inside it
--- (BR.LootContentsRarity), so an authored rarity is a statement about the
--- maximum -- which has to be hit from BOTH sides:
---
---   NOTHING ABOVE IT. The common crate is the one this bites on. Every item is
---     rolled at COMMON, but BR.LootPickOfRarity walks UP when a bucket at or
---     below the asked rarity is empty, so one emptied table in
---     config/weapons.lua would silently turn the common crate uncommon.
---   AND SOMETHING AT IT. Rolling three items at LEGENDARY does not produce a
---     legendary crate: two of the four kinds have no legendary bucket, and the
---     walk DOWN that saves them is exactly what would leave a crate the owner
---     called legendary paying out epic.
---
--- Both are fixed the same way, with a weapon: BR.Config.WeaponsByRarity is the
--- only table populated at all five rarities (5/6/11/10/4 as shipped), so it is
--- the only one that can be asked for an exact tier and be believed. The fix-up
--- below is therefore a real guarantee rather than a hope about the tables, and
--- it costs nothing on a healthy config -- on the shipped tables the "nothing
--- above it" pass never fires at all.
---
--- @param rng table
--- @param rarity integer  BR.Rarity.*
--- @param n integer|nil   defaults to BR.Config.WarmupCrates.items
--- @return table[] stacks
function BR.WarmupCrateContents(rng, rarity, n)
    local W = BR.Config.WarmupCrates
    n = n or W.items or 3

    local out = {}
    for i = 1, n do out[i] = BR.WarmupCrateItem(rng, rarity) end

    --- A weapon at EXACTLY this rarity, or nil if even that table is empty.
    --- Indexed directly rather than through BR.LootPickOfRarity, whose whole
    --- purpose is the walk this function exists to defeat.
    local function exactWeapon()
        local b = BR.Config.WeaponsByRarity[rarity]
        if not b or #b == 0 then return nil end
        local w = rng:pick(b)
        return {
            item   = w.id,
            kind   = BR.ItemKind.WEAPON,
            rarity = w.rarity,
            count  = 1,
            clip   = w.clip,
        }
    end

    -- Nothing above the ceiling.
    for i = 1, n do
        if (out[i].rarity or 1) > rarity then
            out[i] = exactWeapon() or out[i]
        end
    end

    -- And something on it. Slot 1, so the guaranteed item is the one a player
    -- sees first when the crate bursts -- spill() deals its ring in index
    -- order.
    if BR.LootContentsRarity(out) ~= rarity then
        out[1] = exactWeapon() or out[1]
    end

    return out
end

--- One sealed crate for one anchor, ready for BR.Loot.spawnStack.
---
--- THE SHAPE IS BR.MakeCrate'S, FIELD FOR FIELD, and that is what lets the
--- claim path in br_core/server/loot.lua treat these as ordinary containers --
--- the open, the scatter, the husk swap and the arbitration are all the code
--- that already exists. The two differences are the point of the whole file:
--- the rarity is authored rather than derived, and the heading is the owner's
--- rather than `rng:float() * 360`.
--- @param rng table
--- @param anchor table  a row of BR.Config.WarmupCrates.anchors
--- @return table stack
function BR.WarmupCrateStack(rng, anchor)
    local contents = BR.WarmupCrateContents(rng, anchor.rarity)
    return {
        item     = 'chest',
        kind     = 'chest',
        rarity   = BR.LootContentsRarity(contents),
        count    = 1,
        x = anchor.x, y = anchor.y, z = anchor.z,
        prop     = BR.Config.Loot.chestProp,
        heading  = anchor.heading,
        contents = contents,
    }
end
