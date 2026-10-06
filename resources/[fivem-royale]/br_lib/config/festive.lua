-- The festive months (#395, #399): one calendar for every festive thing.
--
-- Owner, 2026-10-04: the Season 2 crates wear a festive set in December and
-- January. Owner, 2026-10-05: "yes snow is meant to reach the players" -- in
-- the same months, on the same switch as the crates (`brfestive` drives both).
--
-- ═══ WHO READS THIS ═══
--
--   br_lib/shared/festive.lua   the one answer, BR.Festive.now(), and the dev
--                               switch `brfestive` writes. Nothing else reads
--                               `months`.
--   br_lib/shared/world.lua     `cycle`, the festive match sky (below): the
--                               server draws a match's weathers from it and a
--                               client blends each one in over its blendSec.
--
-- And who asks BR.Festive.now():
--
--   br_core/server/loot.lua     the crates' festive set, decided once per match
--                               when its loot is laid out (#395).
--   br_core/server/airdrop.lua  the same, for a drop with no match answer.
--   br_core/server/world.lua    the festive sky (#399): the clear sky is XMAS,
--                               sent to every client as one fact when it moves;
--                               in a match it cycles (below).
--
-- Neither feature owns the calendar: each asks it, and each keeps its own
-- Season gate (`crates2`, `snow` in br_lib/config/seasons.lua).

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Festive = {
    -- By the SERVER's date, so every client agrees: December and January.
    months = { [12] = true, [1] = true },

    -- ═══ THE FESTIVE MATCH SKY CYCLES (#399) ═══
    --
    --   "The match weather can cycle between snow, snowlight, xmas and
    --    blizzard during the months of December and January."
    --                                                   -- owner, 2026-10-06
    --
    -- While the festive sky is on, a match's clear sky (the `base` role) is not
    -- a fixed XMAS. From the moment the match goes PLAYING -- the moment its
    -- first circle goes on the map -- the server draws one of `weathers`, never
    -- the one just shown, and holds it a whole number of seconds from
    -- holdMinSec to holdMaxSec, uniformly; then the next, until the match
    -- leaves PLAYING. Every client in the match is told each change once and
    -- blends into it over blendSec. The lobby, warmup and the bus keep #399's
    -- sky: XMAS, and the bus's OVERCAST cover.
    cycle = {
        weathers   = { 'SNOW', 'SNOWLIGHT', 'XMAS', 'BLIZZARD' },
        holdMinSec = 180,
        holdMaxSec = 300,
        blendSec   = 30.0,
    },
}
