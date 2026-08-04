-- The loading-screen handoff.
--
-- br_loadscreen is held open by loadscreen_manual_shutdown, and THIS file is
-- what lets go of it -- as early as the real lobby can stand in: the snapshot
-- has seeded the menu with real data and the network session exists. That is
-- long before the world has streamed in, on purpose: the loadscreen NUI is
-- one-way (it cannot fetch callbacks), so every interactive second a player
-- spends on it is a second they cannot spend queueing. The lobby renders an
-- OPAQUE backdrop in the same visual language until the world is ready, so
-- the player sees one continuous purple-on-black screen that quietly becomes
-- clickable, then fades into the vista.
--
-- BR.State.worldReady is the one fact this file owns. screen.lua carries it
-- to the UI inside the metrics envelope it already publishes -- riding an
-- existing periodic channel means a br_ui restart mid-session re-learns it
-- for free, where a one-shot event would be lost.

BR = BR or {}
BR.State = BR.State or {}

-- Initial value by cheap observation: a fresh join still has the loadscreen
-- up (world genuinely not ready); a br_core restart mid-session does not,
-- and must not flash the lobby backdrop over a world that is already there.
BR.State.worldReady = not GetIsLoadingScreenActive()

Citizen.CreateThread(function()
    -- HALF ONE: drop the loading screen when the lobby can take over.
    -- The hard deadline is not decoration: if the snapshot never comes
    -- (server down mid-join, resource fault), a player parked on the
    -- loadscreen forever has no F8, no quit button, nothing. Thirty
    -- seconds, then the screen drops regardless and whatever is wrong
    -- becomes visible and reportable.
    local deadline = GetGameTimer() + 30000
    while GetGameTimer() < deadline do
        if BR.State.me and BR.State.me.src
           and NetworkIsSessionStarted() then break end
        Citizen.Wait(100)
    end

    -- One beat for br_ui's page to have painted behind the loadscreen, so
    -- the reveal lands on the lobby and not on a frame of black.
    Citizen.Wait(400)

    ShutdownLoadingScreenNui()
    ShutdownLoadingScreen()
    print('[br_core] loading: screen released to the lobby')

    -- HALF TWO: declare the world ready. The vista spawn placement holds
    -- its own freezes while collision loads; this only decides when the
    -- lobby's opaque backdrop may fade into the view behind it. The
    -- timeout matters more than the test: a player who alt-tabbed through
    -- the whole load must still get their vista eventually.
    if not BR.State.worldReady then
        local wDeadline = GetGameTimer() + 60000
        while GetGameTimer() < wDeadline do
            if HasCollisionLoadedAroundEntity(PlayerPedId())
               and not GetIsLoadingScreenActive() then break end
            Citizen.Wait(250)
        end
        BR.State.worldReady = true
        print('[br_core] loading: world ready -- backdrop may fade')
    end
end)
