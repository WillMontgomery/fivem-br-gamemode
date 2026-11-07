-- UI v2 (#436) on this machine: the ONE place that holds the answer every
-- door here asks (br_lib/shared/uiv2.lua).
--
-- Owner, 2026-11-07: UI v2 switches live from the server console, on prod
-- too, as a kill switch, and "players get a change in the lobby or at their
-- next match, never mid-match". The server's answer moves the moment a switch
-- moves; this client takes a new one only:
--
--   * THE FIRST ONE, AT ONCE, in any state: at a join the player is in the
--     lobby under the loading screen, and after a br_core restart every match
--     has ended. Holding it until the entrance would show Season 1's ped and
--     then swap (#406's double swap).
--   * ANY WHILE THE LOADING SCREEN IS STILL UP (BR.State.worldReady false):
--     nothing is on screen yet, so a move while the join is still covered is
--     still the join.
--   * STANDING IN THE LOBBY WITH THE ENTRANCE OVER (BR.LobbyPed.settled). Not
--     merely in the lobby: a match's teardown sweeps its players to the lobby
--     behind the verdict, and the trip home then walks the ped in. Taken once
--     the walk is over, a change lands on a parked ped, like a pick in the
--     locker.
--   * ON THE FIRST PASS OUT OF THE LOBBY, as the next match starts. Ready is
--     live through the ~18 s walk-in, and the owner asked for a ready-up there
--     to drop everything, so a player who readies up during every walk-in is
--     never parked between two matches. That pass is the one moment of "their
--     next match" before anything of it is on screen: client/state.lua raised
--     the curtain on that edge, and the warmup trip has not started.
--
-- Otherwise the answer it has is KEPT, through warmup, the bus, the drop, the
-- match, downed, out and spectating, and the in-game walkthrough.
--
-- Every other resource on this machine (br_ui) mirrors this answer through
-- the local events `br:uiv2:held` and `br:uiv2:ask` (the module wires them).
-- Locker v2 keeps an answer of its own on top of this one, because a
-- character changes only standing in the lobby (client/locker2.lua).
--
-- LOADED RIGHT AFTER client/main.lua: it needs the loop registry, reads
-- BR.State and BR.LobbyPed at call time only, and its pass must run ahead of
-- client/spawn.lua's 'spawn.gather', which starts the warmup trip -- a band
-- runs its callbacks in the order they were registered.

BR = BR or {}

BR.UIv2.hold(function()
    -- The loading screen still up is still the join: nothing is on screen yet.
    if BR.State.worldReady == false then return true end
    if BR.LobbyPed and BR.LobbyPed.settled then return BR.LobbyPed.settled() end
    return BR.State.me.state == BR.PlayerState.LOBBY
end)

-- THE FIRST PASS OUT OF THE LOBBY is "at their next match": behind the curtain
-- client/state.lua raises on that edge, and ahead of spawn.gather, which starts
-- the warmup trip (spawn.lua loads after this file; a band runs in load order).
local was = nil
BR.Loop.register(BR.Loop.TICK, 'uiv2.adopt', function()
    local st = BR.State.me.state
    local left = was == BR.PlayerState.LOBBY and st ~= BR.PlayerState.LOBBY
    was = st
    BR.UIv2.adopt(left)
end)
