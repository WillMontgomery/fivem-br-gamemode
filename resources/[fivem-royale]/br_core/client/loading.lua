-- The loading-screen handoff, as choreography.
--
-- br_loadscreen is held open by loadscreen_manual_shutdown, and this file is
-- what lets go of it. The sequence, per direction (user call, 2026-08-04):
--
--   1. The loadscreen (gag reel) stays up until the game is genuinely
--      ready: snapshot seeded, session started, world collision streamed
--      in at the vista.
--   2. Its TEXT fades out on our cue; the purple glow stays.
--   3. The shutdown then lands on the lobby's IDENTICAL opaque purple
--      backdrop -- pixel-invisible.
--   4. worldReady flips, and two 700ms fades run together: the lobby menu
--      fades IN while the backdrop fades OUT to the world behind it.
--
-- BR.State.worldReady is the one fact this file owns. screen.lua carries it
-- inside the metrics envelope it already publishes -- riding an existing
-- periodic channel means a br_ui restart mid-session re-learns it for free
-- -- and 'br:screen:refresh' makes the flip immediate instead of waiting
-- out the poll.

BR = BR or {}
BR.State = BR.State or {}

-- Initial value by cheap observation: a fresh join still has the loadscreen
-- up (world genuinely not ready); a br_core restart mid-session does not,
-- and must not replay the boot choreography over a world already there.
BR.State.worldReady = not GetIsLoadingScreenActive()

-- The interface's ready handshake. THE REVEAL MUST WAIT FOR IT: the page
-- learns worldReady=false via the screen publish that fires on this very
-- event -- reveal before it and the menu is caught in its default-visible
-- state, producing the "lobby appears, fades out, fades back in" stutter
-- (live report, 2026-08-04). Collision can genuinely stream in faster than
-- CEF loads the page, so this is a real order, not paranoia.
local uiReady = false
AddEventHandler('br:ui:ready', function() uiReady = true end)

Citizen.CreateThread(function()
    if BR.State.worldReady then return end   -- mid-session restart: nothing to do

    -- Menu data AND the menu itself. The hard deadline is not decoration:
    -- if the snapshot never comes (server fault mid-join), a player parked
    -- on the loadscreen forever has no F8, no quit button, nothing. The
    -- screen drops regardless and whatever is wrong becomes visible and
    -- reportable.
    local deadline = GetGameTimer() + 30000
    while GetGameTimer() < deadline do
        if uiReady and BR.State.me and BR.State.me.src
           and NetworkIsSessionStarted() then break end
        Citizen.Wait(100)
    end

    -- The world. The gag reel keeps the player company through the whole
    -- stream-in; the timeout matters more than the test -- a player who
    -- alt-tabbed through the load must still get their lobby eventually.
    local wDeadline = GetGameTimer() + 60000
    while GetGameTimer() < wDeadline do
        if HasCollisionLoadedAroundEntity(PlayerPedId()) then break end
        Citizen.Wait(250)
    end

    -- Text out (the glow stays). pcall: if the cue native is unavailable
    -- the exit is a cut instead of a fade, never a hang.
    pcall(function()
        SendLoadingScreenMessage('{"eventName":"br:fadeText"}')
    end)
    Citizen.Wait(500)

    -- The reveal. Behind this is the lobby on its opaque twin backdrop,
    -- menu still transparent (worldReady false). If some earlier fade left
    -- the GAME's screen dark, lift it now -- the world must be standing by
    -- behind the backdrop for step 4 to reveal.
    ShutdownLoadingScreenNui()
    ShutdownLoadingScreen()
    if IsScreenFadedOut() then DoScreenFadeIn(400) end
    print('[br_core] loading: screen released to the lobby')

    -- One beat on pure purple, then the double fade: menu in, world in.
    Citizen.Wait(150)
    BR.State.worldReady = true
    TriggerEvent('br:screen:refresh')
    print('[br_core] loading: world ready -- menu and world fade in')
end)
