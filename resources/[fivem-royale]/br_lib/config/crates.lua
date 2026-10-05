-- Season 2 crates (#395): the shipping boxes, their festive set, the gift boxes,
-- and where the hold prompt sits on each.
--
-- Owner, 2026-10-04: "We're going to re-do the crate props ... a fundamental
-- rework - pay close attention". Unbranded delivery boxes with a shipping label
-- and packing tape, one prop per tier (the tape color, which glows in the dark,
-- is the best rarity inside), an already-open prop for each, and a clipset that
-- opens the box. December and January use a festive set with festive icons and
-- a candy-cane common tape. An extra-large gift box in four colors is
-- registered too; what it is FOR is not decided, so nothing places one except
-- the dev command `brbox gift <color>`.
--
-- ═══ WHO READS THIS ═══
--
--   br_lib/shared/crates.lua    every question about a look: which model, which
--                               clip and how long, whether the festive set is in
--                               season. Nothing else reads these tables.
--   br_core/server/loot.lua     stamps each crate's look when it enters the
--                               registry and times the burst off `clipMs`.
--   br_core/client/loot.lua     picks the model, plays the clip, swaps to the
--                               open prop and draws the prompt at `prompt`.
--   br_core/client/airdrop.lua  the falling airdrop crate, so the box under the
--                               canopy is the box that lands.
--
-- ═══ SEASON 1 NEVER SEES ANY OF THIS ═══
--
-- The `crates2` row in br_lib/config/seasons.lua gates it. A Season 1 server
-- stamps nothing, so its clients draw today's wooden crate and it opens the way
-- it always has: the hold completes, the loot bursts, the crate is a husk.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Crates = {
    -- ╔═══════════════════════════════════════════════════════════════════════╗
    -- ║  PLACEHOLDERS. THE OWNER'S NAMES REPLACE EVERYTHING DOWN TO THE END   ║
    -- ║  OF THIS BLOCK WHEN THE PROPS LAND.                                   ║
    -- ╚═══════════════════════════════════════════════════════════════════════╝
    --
    -- WHAT TO FILL IN, from the Season 2 assets folder (#391):
    --
    --   resource   the folder the props arrive in, resources/[licensed]/<name>.
    --              The server checks it is started before it plays a clip; while
    --              it is not, every crate opens the way it does today.
    --   sealed     the closed box's model name
    --   open       the already-open box's model name, posed as the clip's last
    --              frame (the swap happens there)
    --   dict       the clipset (animation dictionary) that opens the box
    --   clip       the clip inside it
    --   clipMs     the clip's length in milliseconds. The SERVER times the burst
    --              off this number, so it has to match the clip: `brboxcheck` in
    --              F8 prints GetAnimDuration for every row beside it.
    --   prompt     where the hold prompt sits, one row for every shipping box and
    --              one for the gift box. Tune it live with `brboxprompt` standing
    --              at a box; it prints the line to paste.
    --
    -- A NAME STILL STARTING `PLACEHOLDER` IS NOT USED. Such a row opens the way a
    -- crate does today and draws the wooden crate; so does any model this build
    -- does not have, on any client. Nothing here can break a crate.
    resource = 'PLACEHOLDER_crates_resource',

    -- Tier = BR.Rarity: 1 common, 2 uncommon, 3 rare, 4 epic, 5 legendary.
    shipping = {
        [1] = { sealed = 'PLACEHOLDER_ship_common',    open = 'PLACEHOLDER_ship_common_open',
                dict = 'PLACEHOLDER_ship_common_anim',    clip = 'PLACEHOLDER_open', clipMs = 1500 },
        [2] = { sealed = 'PLACEHOLDER_ship_uncommon',  open = 'PLACEHOLDER_ship_uncommon_open',
                dict = 'PLACEHOLDER_ship_uncommon_anim',  clip = 'PLACEHOLDER_open', clipMs = 1500 },
        [3] = { sealed = 'PLACEHOLDER_ship_rare',      open = 'PLACEHOLDER_ship_rare_open',
                dict = 'PLACEHOLDER_ship_rare_anim',      clip = 'PLACEHOLDER_open', clipMs = 1500 },
        [4] = { sealed = 'PLACEHOLDER_ship_epic',      open = 'PLACEHOLDER_ship_epic_open',
                dict = 'PLACEHOLDER_ship_epic_anim',      clip = 'PLACEHOLDER_open', clipMs = 1500 },
        [5] = { sealed = 'PLACEHOLDER_ship_legendary', open = 'PLACEHOLDER_ship_legendary_open',
                dict = 'PLACEHOLDER_ship_legendary_anim', clip = 'PLACEHOLDER_open', clipMs = 1500 },
    },

    -- The festive set: separate props with festive icons, the common tape candy
    -- cane. Same tiers, same shape.
    festive = {
        [1] = { sealed = 'PLACEHOLDER_xmas_common',    open = 'PLACEHOLDER_xmas_common_open',
                dict = 'PLACEHOLDER_xmas_common_anim',    clip = 'PLACEHOLDER_open', clipMs = 1500 },
        [2] = { sealed = 'PLACEHOLDER_xmas_uncommon',  open = 'PLACEHOLDER_xmas_uncommon_open',
                dict = 'PLACEHOLDER_xmas_uncommon_anim',  clip = 'PLACEHOLDER_open', clipMs = 1500 },
        [3] = { sealed = 'PLACEHOLDER_xmas_rare',      open = 'PLACEHOLDER_xmas_rare_open',
                dict = 'PLACEHOLDER_xmas_rare_anim',      clip = 'PLACEHOLDER_open', clipMs = 1500 },
        [4] = { sealed = 'PLACEHOLDER_xmas_epic',      open = 'PLACEHOLDER_xmas_epic_open',
                dict = 'PLACEHOLDER_xmas_epic_anim',      clip = 'PLACEHOLDER_open', clipMs = 1500 },
        [5] = { sealed = 'PLACEHOLDER_xmas_legendary', open = 'PLACEHOLDER_xmas_legendary_open',
                dict = 'PLACEHOLDER_xmas_legendary_anim', clip = 'PLACEHOLDER_open', clipMs = 1500 },
    },

    -- The extra-large gift box. Registered, wired to nothing but `brbox`.
    gift = {
        white = { sealed = 'PLACEHOLDER_gift_white', open = 'PLACEHOLDER_gift_white_open',
                  dict = 'PLACEHOLDER_gift_white_anim', clip = 'PLACEHOLDER_open', clipMs = 1500 },
        blue  = { sealed = 'PLACEHOLDER_gift_blue',  open = 'PLACEHOLDER_gift_blue_open',
                  dict = 'PLACEHOLDER_gift_blue_anim',  clip = 'PLACEHOLDER_open', clipMs = 1500 },
        green = { sealed = 'PLACEHOLDER_gift_green', open = 'PLACEHOLDER_gift_green_open',
                  dict = 'PLACEHOLDER_gift_green_anim', clip = 'PLACEHOLDER_open', clipMs = 1500 },
        red   = { sealed = 'PLACEHOLDER_gift_red',   open = 'PLACEHOLDER_gift_red_open',
                  dict = 'PLACEHOLDER_gift_red_anim',   clip = 'PLACEHOLDER_open', clipMs = 1500 },
    },

    -- The hold prompt, in the BOX'S OWN FRAME: x right, y forward, z up, in
    -- meters from the model's origin; rx/ry/rz turn the label in degrees (0, 0, 0
    -- is lying flat, reading from the box's back edge, like the wooden crate's lid
    -- label); `size` is the label's width in meters. One row for every shipping
    -- box, festive included, and one for the gift box.
    prompt = {
        shipping = { x = 0.0, y = 0.0, z = 0.45, rx = 0.0, ry = 0.0, rz = 0.0, size = 0.40 },
        gift     = { x = 0.0, y = 0.0, z = 0.95, rx = 0.0, ry = 0.0, rz = 0.0, size = 0.55 },
    },
    -- ═══ END OF THE PLACEHOLDER BLOCK ═══

    -- The festive months, by the SERVER's date: December and January (owner,
    -- 2026-10-04). Decided once per match when its loot is laid out and carried on
    -- every crate, so every client agrees. `brfestive` forces it for testing.
    festiveMonths = { [12] = true, [1] = true },

    -- The order the gift colors are listed and checked in.
    giftColors = { 'white', 'blue', 'green', 'red' },

    -- How long a client waits for a clipset to stream before it gives up on the
    -- clip and lets the box sit sealed until the open prop arrives.
    clipDictWaitMs = 1000,

    -- How long a client keeps the sealed body on screen while the open one is
    -- built, at most. The swap normally takes a frame; this is the net.
    lingerMs = 3000,
}
