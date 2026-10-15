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
--
-- ═══ MY LOOKS (owner, 2026-10-12/13/14) ═══
--
-- The anchor navigation became a summary list: six CORE categories always on
-- the look, and EXTRAS that start absent, come from "Add more" and go with
-- their trash icon -- in the order the player put them on, which the look
-- keeps (its `x`). The ids are the page's (ui-src/src/screens/lockerv2/
-- model.ts CORE_CATS and EXTRA_CATS), in the same order.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Locker2 = {
    --- The two freemode peds, by the appearance's `s`.
    models = { m = 'mp_m_freemode_01', f = 'mp_f_freemode_01' },
    --- SetPedHeadBlendData's shape for each: one face, never a mix. Heritage is
    --- out (owner, 2026-10-07), so mother and father are this one id and the
    --- resemblance is 0; the skin tone is the only blend the player picks.
    ---
    --- THE STARTING FACES (My Looks, 2026-10-13: "a few starting faces"): the
    --- Face panel's tiles, the look's `f` an index into its sex's list. The
    --- first is the one face every look had before, so a look saved then is the
    --- same face now. The others are spread over the game's faces for that sex
    --- (0-20 male, 21-41 female) and are a proposal to pick by eye.
    faces = {
        m = { 0, 4, 8, 12, 16, 20 },
        f = { 21, 25, 29, 33, 37, 41 },
    },
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
    --- THE CAMERA BUTTONS' ZOOM (LOCKER2_CAM): each step in brings the camera
    --- this share of its distance closer (and out, back), between zoomMin and
    --- zoomMax steps, in zoomMs. Reset view and a new category frame afresh.
    zoomFactor = 0.85,
    zoomMin = -2,
    zoomMax = 4,
    zoomMs = 200,

    --- The summary list, in order: the core, then the extras (`extra`). Each
    --- row key names what it edits:
    ---   shape       the starting face, the look's `f` (an index into `faces`)
    ---   sk, e       skin tone, eye color
    ---   ffN         face feature N (0-based), a slider
    ---   h1          the hair highlight, h[2] (0-based, as ffN and oN are)
    ---   oN          head overlay N (0-based); oNop is its opacity slider
    ---   cN          component N (1..11)
    ---   pN          prop N (0, 1, 2, 6, 7)
    --- The hair color is the Hair row's swatches. An extra's first row is the
    --- one "Add more" puts its first item on.
    categories = {
        { id = 'face', cam = 'head', rows = {
            'shape', 'e',
            'ff0', 'ff1', 'ff2', 'ff3', 'ff4', 'ff5', 'ff6', 'ff7', 'ff8', 'ff9',
            'ff10', 'ff11', 'ff12', 'ff13', 'ff14', 'ff15', 'ff16', 'ff17', 'ff18', 'ff19',
        } },
        { id = 'skin', cam = 'head', rows = {
            'sk', 'o0', 'o0op', 'o3', 'o3op', 'o6', 'o6op', 'o7', 'o7op', 'o9', 'o9op',
            'o11', 'o11op', 'o12', 'o12op',
        } },
        { id = 'hair', cam = 'head', rows = { 'c2', 'h1', 'o2', 'o2op', 'o1', 'o1op', 'o10', 'o10op' } },
        { id = 'top', cam = 'upper', rows = { 'c11', 'c8', 'c3' } },
        { id = 'legs', cam = 'legs', rows = { 'c4' } },
        { id = 'shoes', cam = 'feet', rows = { 'c6' } },
        { id = 'hat', cam = 'head', extra = true, rows = { 'p0' } },
        { id = 'glasses', cam = 'head', extra = true, rows = { 'p1' } },
        { id = 'earrings', cam = 'head', extra = true, rows = { 'p2' } },
        { id = 'mask', cam = 'head', extra = true, rows = { 'c1' } },
        { id = 'vest', cam = 'upper', extra = true, rows = { 'c9' } },
        { id = 'bag', cam = 'back', extra = true, rows = { 'c5' } },
        { id = 'watch', cam = 'waist', extra = true, rows = { 'p6' } },
        { id = 'bracelet', cam = 'waist', extra = true, rows = { 'p7' } },
        { id = 'decals', cam = 'upper', extra = true, rows = { 'c10' } },
        { id = 'accessory', cam = 'upper', extra = true, rows = { 'c7' } },
        { id = 'makeup', cam = 'head', extra = true, rows = { 'o4', 'o4op', 'o5', 'o5op', 'o8', 'o8op' } },
    },

    --- THE EXTRAS, in "Add more"'s order: every `extra` category above, then
    --- Tattoos (the section below). A look's `x` holds some of these, in the
    --- order the player put them on (owner, 2026-10-14).
    extras = {
        'hat', 'glasses', 'earrings', 'mask', 'vest', 'bag', 'watch', 'bracelet', 'decals', 'accessory',
        'makeup', 'tattoos',
    },
    --- A component extra's "none": the drawable that draws nothing, first in its
    --- row. A prop's none is -1 and an overlay's 255.
    componentNone = { [1] = 0, [5] = 0, [7] = 0, [9] = 0, [10] = 0 },

    --- THE GAME'S FORCED COMPONENTS (#28, the game-data check): a shop top
    --- names the arms and undershirt it is worn with (per texture), a jumpsuit
    --- its legs and shoes, and an undershirt its arms. These are the slots
    --- taken from that data; the Arms row stays the player's override after.
    forcedSlots = { 3, 8, 4, 6 },

    --- RANDOMIZE (owner, 2026-10-14: "the randomize button should randomize
    --- those additional categories too"): each extra goes on with this chance,
    --- Tattoos with tattoosMin..tattoosMax of them; hair and its highlight come
    --- from the first naturalHair colors; face features stay within
    --- featureSpread of the middle; eyes from the first naturalEyes.
    random = { extra = 0.3, tattoosMin = 1, tattoosMax = 4, naturalHair = 29, naturalEyes = 8,
               featureSpread = 35 },

    --- UNDO AND REDO (owner, 2026-10-13: "yes"): the most steps kept, and how
    --- close two touches of one row are to be one step (a slider's drag, a held
    --- arrow). ui-src/src/screens/lockerv2/model.ts HISTORY_MAX and COALESCE_MS
    --- say the same, which tools/test_locker2.lua holds them to.
    historyMax = 50,
    coalesceMs = 800,

    --- The palettes the swatch grids draw: the first this many of each.
    paletteMax = 64,

    --- ITEM NAMES (owner, 2026-10-14: "All or nothing on that"): the
    --- categories whose rows carry the game's name for the item worn. None:
    --- the game names too few. The page shows a name only for a category in
    --- its own NAMED_CATS (ui-src/src/screens/lockerv2/model.ts) as well.
    names = {},

    --- THE TATTOOS SECTION (owner, 2026-10-11), after the categories above: its
    --- own anchor, then one per body zone of br_lib/config/tattoos.lua that has
    --- any tattoo, each with the preset the camera moves to. The arms have no
    --- preset of their own; the upper body frames both.
    tattooCats = {
        { id = 'tattoos', cam = 'upper' },
        { id = 'tat_head', zone = 'head', cam = 'head' },
        { id = 'tat_torso', zone = 'torso', cam = 'upper' },
        { id = 'tat_larm', zone = 'larm', cam = 'upper' },
        { id = 'tat_rarm', zone = 'rarm', cam = 'upper' },
        { id = 'tat_lleg', zone = 'lleg', cam = 'legs' },
        { id = 'tat_rleg', zone = 'rleg', cam = 'legs' },
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
    --- A player is answered at most once this often; asking sooner is answered
    --- once when it is up.
    fetchMs = 5000,
    --- THE SAVED LOOKS ARE READ ONCE AND KEPT (#28 lag): every write goes
    --- through this server and updates the cache, so a read is answered from
    --- it for this long before the database is asked again.
    cacheMs = 600000,
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
    --- THE OPEN IS NOT HITCHED BY HEADSHOTS (#28 lag): a card's stored picture
    --- goes to the page one a frame, and the first clone is taken this long
    --- after the page asks, each next one shotGapMs after the last.
    shotDelayMs = 750,
    shotGapMs = 250,
    --- The saved looks are asked for again on an open only once the last
    --- answer is this old (or never came, or the server could not read them).
    refreshMs = 600000,
}
