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
    -- ═══ THE OWNER'S PROPS (Season 2 assets folder, resources/[licensed]/br_stream_s2) ═══
    --
    -- Names read from the props themselves (owner, 2026-10-04; issue #395):
    -- every box is `blitz_loot_<kind>` sealed (the animated body) and
    -- `blitz_loot_<kind>_opened` open, posed as its clip's last frame. One
    -- clipset, `blitz_lootbox_anims`: `open` (0.933 s) for the shipping boxes and
    -- `gift_open` (1.2 s) for the gift boxes. Model origin is bottom center.
    --
    --   resource   the props' folder: br_stream_s2, the one resource that
    --              streams everything Season 2 needs. The server checks it is
    --              started before it plays a clip; while it is not, every crate
    --              opens the way it does today.
    --   clipMs     the clip's length in milliseconds. The SERVER times the burst
    --              off this number, so it has to match the clip: `brboxcheck` in
    --              F8 prints GetAnimDuration for every row beside it.
    --   prompt     where the hold prompt sits, one row for every shipping box and
    --              one for the gift box. These are first guesses: tune them live
    --              with `brboxprompt` standing at a box; it prints the line to
    --              paste.
    --
    -- Any model this build does not have, on any client, draws the wooden crate
    -- and opens the way a crate does today. Nothing here can break a crate.
    resource = 'br_stream_s2',

    -- Tier = BR.Rarity: 1 common, 2 uncommon, 3 rare, 4 epic, 5 legendary.
    shipping = {
        [1] = { sealed = 'blitz_loot_common', open = 'blitz_loot_common_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        [2] = { sealed = 'blitz_loot_uncommon', open = 'blitz_loot_uncommon_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        [3] = { sealed = 'blitz_loot_rare', open = 'blitz_loot_rare_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        [4] = { sealed = 'blitz_loot_epic', open = 'blitz_loot_epic_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        [5] = { sealed = 'blitz_loot_legendary', open = 'blitz_loot_legendary_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
    },

    -- The festive set: separate props with festive icons, the common tape candy
    -- cane. Same tiers, same clip.
    festive = {
        [1] = { sealed = 'blitz_loot_common_xmas', open = 'blitz_loot_common_xmas_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        [2] = { sealed = 'blitz_loot_uncommon_xmas', open = 'blitz_loot_uncommon_xmas_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        [3] = { sealed = 'blitz_loot_rare_xmas', open = 'blitz_loot_rare_xmas_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        [4] = { sealed = 'blitz_loot_epic_xmas', open = 'blitz_loot_epic_xmas_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        [5] = { sealed = 'blitz_loot_legendary_xmas', open = 'blitz_loot_legendary_xmas_opened',
                dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
    },

    -- The extra-large gift box. Registered, wired to nothing but `brbox`.
    gift = {
        white = { sealed = 'blitz_loot_largegift_white', open = 'blitz_loot_largegift_white_opened',
                  dict = 'blitz_lootbox_anims', clip = 'gift_open', clipMs = 1200 },
        blue  = { sealed = 'blitz_loot_largegift_blue', open = 'blitz_loot_largegift_blue_opened',
                  dict = 'blitz_lootbox_anims', clip = 'gift_open', clipMs = 1200 },
        green = { sealed = 'blitz_loot_largegift_green', open = 'blitz_loot_largegift_green_opened',
                  dict = 'blitz_lootbox_anims', clip = 'gift_open', clipMs = 1200 },
        red   = { sealed = 'blitz_loot_largegift_red', open = 'blitz_loot_largegift_red_opened',
                  dict = 'blitz_lootbox_anims', clip = 'gift_open', clipMs = 1200 },
    },

    -- REGISTERED, PICKED BY NOTHING (owner, 2026-10-04: "Plain will be unused for
    -- now"). The props ship a sixth, tier-less box and its festive twin. They are
    -- listed so the names are on record beside the rest; no crate, test command
    -- or check reads this table.
    spare = {
        plain      = { sealed = 'blitz_loot_plain', open = 'blitz_loot_plain_opened',
                       dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
        plain_xmas = { sealed = 'blitz_loot_plain_xmas', open = 'blitz_loot_plain_xmas_opened',
                       dict = 'blitz_lootbox_anims', clip = 'open', clipMs = 934 },
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
