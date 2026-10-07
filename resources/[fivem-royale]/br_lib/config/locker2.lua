-- Locker v2 (#28, Season 2): the ped picker's numbers, its categories and the
-- rows each one holds. The Season 1 locker (client/locker.lua, config/peds.lua)
-- reads nothing here.
--
-- ═══ THE OWNER'S SPEC (2026-10-07) ═══
--
-- Stock peds as today; Custom (male) and Custom (female) on the MP freemode
-- peds, "an anchor navigation on the left for all categories of items which can
-- be customized, and when selected, the camera should move to focus on which
-- part of the ped is being customized"; every item a row of `v/n` with
-- previous, next (both wrapping) and reset to 1; "Next color" on an item with
-- more than one color. Heritage is OUT, skin tone is IN; vests, bags, badges
-- and decals are IN; parachute packs and helmets are IN too ("They're just
-- cosmetic after all", owner, 2026-10-07), so every bag drawable is listed.
-- Everything is free.
--
-- ═══ WHAT LIVES HERE AND WHAT DOES NOT ═══
--
-- The row KEYS and their categories, which the client enumerates and the page
-- lays out. The labels are the page's (ui-src/src/screens/lockerv2). The
-- appearance's ranges are br_lib/shared/appearance.lua's, because the server
-- checks them too.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Locker2 = {
    --- The two freemode peds, by the appearance's `s`.
    models = { m = 'mp_m_freemode_01', f = 'mp_f_freemode_01' },
    --- SetPedHeadBlendData's shape for each: one face, never a mix. Heritage is
    --- out (owner, 2026-10-07), so mother and father are this one id and the
    --- resemblance is 0; the skin tone is the only blend the player picks.
    shape = { m = 0, f = 21 },
    --- The undershirt that is no undershirt. "None" comes first in its row.
    undershirtNone = { m = 15, f = 14 },

    --- Camera presets, by name: the bone the shot is built on, a z offset from
    --- it, the distance in front of the ped and the field of view. `behind`
    --- puts the camera on the ped's back. Read by client/lobbycam.lua's focus.
    cams = {
        head  = { bone = 31086, z =  0.05, dist = 0.8, fov = 40.0 },
        upper = { bone = 24818, z =  0.0,  dist = 1.4, fov = 45.0 },
        waist = { bone = 11816, z =  0.15, dist = 1.7, fov = 48.0 },
        legs  = { bone = 11816, z = -0.45, dist = 1.7, fov = 48.0 },
        feet  = { bone = 14201, z =  0.1,  dist = 1.1, fov = 45.0 },
        back  = { bone = 24818, z =  0.0,  dist = 1.5, fov = 45.0, behind = true },
    },
    --- How long the camera takes to reach a preset, eased.
    camMs = 600,

    --- The anchor navigation, in order. Each row key names what it edits:
    ---   sk, e       skin tone, eye color
    ---   ffN         face feature N (0-based), a slider
    ---   h1          the hair highlight, h[2] (0-based, as ffN and oN are)
    ---   oN          head overlay N (0-based); oNop is its opacity slider
    ---   cN          component N (1..11)
    ---   pN          prop N (0, 1, 2, 6, 7)
    --- The hair color is the Hair row's Next color.
    categories = {
        { id = 'face', cam = 'head', rows = {
            'sk', 'e',
            'ff0', 'ff1', 'ff2', 'ff3', 'ff4', 'ff5', 'ff6', 'ff7', 'ff8', 'ff9',
            'ff10', 'ff11', 'ff12', 'ff13', 'ff14', 'ff15', 'ff16', 'ff17', 'ff18', 'ff19',
        } },
        { id = 'hair', cam = 'head', rows = { 'c2', 'h1', 'o2', 'o2op', 'o1', 'o1op' } },
        { id = 'makeup', cam = 'head', rows = { 'o4', 'o4op', 'o5', 'o5op', 'o8', 'o8op' } },
        { id = 'skin', cam = 'head', rows = {
            'o0', 'o0op', 'o3', 'o3op', 'o6', 'o6op', 'o7', 'o7op', 'o9', 'o9op',
        } },
        { id = 'body', cam = 'upper', rows = { 'o11', 'o11op', 'o12', 'o12op', 'o10', 'o10op' } },
        { id = 'headwear', cam = 'head', rows = { 'p0', 'p1', 'p2', 'c1' } },
        { id = 'tops', cam = 'upper', rows = { 'c11', 'c8', 'c3' } },
        { id = 'vests', cam = 'upper', rows = { 'c9', 'c10' } },
        { id = 'accessories', cam = 'waist', rows = { 'c7', 'p6', 'p7' } },
        { id = 'bags', cam = 'back', rows = { 'c5' } },
        { id = 'legs', cam = 'legs', rows = { 'c4' } },
        { id = 'shoes', cam = 'feet', rows = { 'c6' } },
    },

    --- Which palette an overlay's color comes from: 1 is the hair palette, 2
    --- the makeup palette (SetPedHeadOverlayColor's colorType). An overlay not
    --- listed has no color.
    overlayPalette = {
        [1] = 1,   -- facial hair
        [2] = 1,   -- eyebrows
        [10] = 1,  -- chest hair
        [4] = 2,   -- makeup
        [5] = 2,   -- blush
        [8] = 2,   -- lipstick
    },

    -- ── the server ──────────────────────────────────────────────────────────
    --- Writes (save, rename, delete, a headshot) share one bucket per player:
    --- this many, refilling one every refillMs.
    writeBucket = 6,
    writeRefillMs = 2000,
    --- One fetch from the database per player this often; asking sooner gets
    --- the cache.
    fetchMs = 5000,
    --- The worn ped is written at most this often, and on drop.
    wearMs = 5000,

    -- ── the client ──────────────────────────────────────────────────────────
    --- The first apply waits this long, under the loading screen, for the
    --- server's record of the worn ped before it falls back to this machine's.
    joinWaitMs = 4000,
    --- Season 1's locker holds its first apply this long while the season is
    --- still unknown, so a Season 2 client never shows a Season 1 ped first.
    unknownWaitMs = 3000,
    --- How often the worn custom ped is compared with what the game has on it.
    watchMs = 500,
    --- The head blend is asserted again once it has finished, waiting at most
    --- this long.
    headBlendWaitMs = 1000,
    --- A headshot that is not ready by then is given up on.
    shotWaitMs = 3000,
}
