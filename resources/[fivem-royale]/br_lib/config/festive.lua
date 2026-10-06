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
--                               this table.
--
-- And who asks BR.Festive.now():
--
--   br_core/server/loot.lua     the crates' festive set, decided once per match
--                               when its loot is laid out (#395).
--   br_core/server/airdrop.lua  the same, for a drop with no match answer.
--   br_core/server/world.lua    the festive sky (#399): the clear sky is XMAS,
--                               sent to every client as one fact when it moves.
--
-- Neither feature owns the calendar: each asks it, and each keeps its own
-- Season gate (`crates2`, `snow` in br_lib/config/seasons.lua).

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Festive = {
    -- By the SERVER's date, so every client agrees: December and January.
    months = { [12] = true, [1] = true },
}
