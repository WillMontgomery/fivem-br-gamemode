-- Sprint is unlimited (#389).
--
--   "eliminates the concept of the stamina/sprint bar, and instead allows
--    infinite stamina."                              -- owner, 2026-10-04
--
-- There is no sprint meter of ours any more: no drain, no block on an empty
-- meter, no bar on the HUD. What is left is the job that sat underneath it.
-- GTA has its own stamina stat, and running it dry drains HEALTH -- so with
-- nothing of ours ending a sprint, the engine's meter is what a long one would
-- run down, and it must never be allowed to empty.
--
-- EVERY STATE, NOT A LIST OF THE ONES WHERE SPRINT SEEMS POSSIBLE. The old
-- meter only topped the engine up in warmup and in a match, which was safe
-- while our own meter stopped a sprint long before the engine's could run out.
-- With no meter of ours, a missed state is a player losing health for running,
-- and a list of states is a thing that goes stale. Topping up a full meter
-- costs nothing.
--
-- tools/test_stamina.lua pins it: every player state, every tick.

BR = BR or {}

BR.Loop.register(BR.Loop.TICK, 'stamina.pin', function()
    -- RESTORE_PLAYER_STAMINA ADDS a share of the maximum, documented as 0.0 to
    -- 1.0 (1.0 is all of it). 25.0 is far past that, so every call fills the
    -- meter outright, and at 10 Hz no sprint drains it between two calls.
    RestorePlayerStamina(PlayerId(), 25.0)
end)
