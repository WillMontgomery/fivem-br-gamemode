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

--- IN LUA 0 IS TRUTHY, AND A FIVEM NATIVE DECLARED BOOL MAY ANSWER 1 RATHER
--- THAN true. Every native this file waits on is declared BOOL, and every one
--- of them was read raw -- so on a build that answers with numbers this whole
--- file was a sequence of waits that did not wait. lobbyPedPending below
--- already carried the `== true or == 1` form inline for DoesEntityExist; this
--- is that same test, once, for the four questions that gate the reveal.
--- @param v any
--- @return boolean
local function isTrue(v)
    return v ~= nil and v ~= false and v ~= 0
end

-- Initial value by cheap observation: a fresh join still has the loadscreen
-- up (world genuinely not ready); a br_core restart mid-session does not,
-- and must not replay the boot choreography over a world already there.
--
-- AND THE OBSERVATION IS THE WRONG WAY ROUND WITHOUT isTrue. `not
-- GetIsLoadingScreenActive()` is FALSE for a 0 -- the answer that MEANS the
-- loadscreen is already gone -- so a mid-session br_core restart would read
-- worldReady = false and replay the entire boot choreography over a live world,
-- which is the one case the line exists to avoid.
BR.State.worldReady = not isTrue(GetIsLoadingScreenActive())

-- The interface's ready handshake. THE REVEAL MUST WAIT FOR IT: the page
-- learns worldReady=false via the screen publish that fires on this very
-- event -- reveal before it and the menu is caught in its default-visible
-- state, producing the "lobby appears, fades out, fades back in" stutter
-- (live report, 2026-08-04). Collision can genuinely stream in faster than
-- CEF loads the page, so this is a real order, not paranoia.
local uiReady = false
AddEventHandler('br:ui:ready', function() uiReady = true end)

--- How long the reveal will wait for the character before giving up on it.
---
--- SIZED OFF THE THING IT IS WAITING FOR, not picked. client/locker.lua gives
--- its own RequestModel five seconds and then keeps whatever ped you had; this
--- has to outlast that plus the tick that starts it and the swap itself, or a
--- model that streams slowly-but-successfully would be revealed half-applied
--- anyway and the wait would have bought nothing.
local PED_WAIT_MS = 8000

--- WHY THE CHARACTER IN THE LOBBY SHOT IS NOT READY TO BE LOOKED AT YET.
---
--- Returns the REASON as a string, or nil when the ped is genuinely finished.
--- A string rather than a boolean because the only thing worse than this wait
--- timing out is it timing out without saying which half never arrived -- the
--- same argument the fade cue below already makes for logging its own result.
---
--- WHAT "FULLY SPAWNED IN" HAD TO MEAN (owner, 2026-08-18: "on the lobby
--- screen - can we wait to fade the screen in until after our target ped has
--- fully spawned in?"). Four different moments were available and they are not
--- the same moment:
---
---   * the ped EXISTS. True before we finished connecting -- GTA hands every
---     player a ped -- so it proves nothing at all.
---   * the MODEL HAS STREAMED (HasModelLoaded). Proves the character is in
---     memory, not that it is on the player. locker.apply streams the model and
---     THEN swaps it, and a reveal in that gap shows the default freemode ped
---     standing in the shot.
---   * THE MODEL IS ON THE PLAYER. This is the one, and it is stronger than it
---     looks because of how locker.apply is written: SetPlayerModel, the
---     coordinate and heading restore, initHealthModel and
---     SetPedDefaultComponentVariation all run in ONE unbroken block with no
---     Citizen.Wait between them, so no other thread can ever observe the ped
---     between the swap and the components. Reading the model back therefore
---     reads a ped that is already dressed -- which is the frame that matters,
---     because a model with no component variation is the one that spawns "in
---     their underwear" (locker.lua's own words), and two frames of that is
---     exactly the ped-assembling-itself the report describes.
---   * IT IS STANDING ON THE MARK. client/lobbycam.lua aims at authored
---     COORDINATES rather than at the entity, so a ped that is correct but
---     somewhere else is a menu over an empty hillside -- the other half of the
---     report.
---
--- The last two are both asserted. The first two are implied by them and are
--- not worth a line of their own.
---
--- NOT ASKED: whether the ped is VISIBLE. client/natives.lua sets that every
--- frame from the player's state, and it is just as true for the default ped as
--- for the finished one -- it would answer yes to the exact frame we are trying
--- not to show.
---
--- EVERY HALF FAILS OPEN. A missing module or an absent config makes its own
--- test disappear rather than hold the loading screen up over a game that is
--- working, which is this file's governing rule and spawn.lua's.
local function lobbyPedPending()
    local ped = PlayerPedId()

    -- `not DoesEntityExist(ped)` cannot be written here -- see isTrue at the top
    -- of this file. This test was the first place in this file to carry the
    -- scar, spelled out inline; it goes through the helper now that the helper
    -- exists, because one file with two spellings of one rule is how the next
    -- person picks the wrong one.
    if not isTrue(DoesEntityExist(ped)) then return 'no ped yet' end

    -- The locker is the only thing that decides WHICH character this is, so it
    -- is the only honest source for what we are waiting to see.
    if BR.Locker and BR.PedById then
        local want = GetHashKey(BR.PedById(BR.Locker.chosen()).model)
        if GetEntityModel(ped) ~= want then
            return 'the chosen character is not on the player yet'
        end
    end

    -- A TRIP OWNS ITS OWN DARKNESS, AND THIS IS WHERE THE TWO SCREENS COULD
    -- HAVE LEFT A GAP OF BLACK BETWEEN THEM.
    --
    -- spawn.lua's lobby watchdog fires during a fresh boot, not only after a
    -- match: BR.State.me.state DEFAULTS to LOBBY (client/main.lua) and the ped
    -- starts wherever GTA put it, thousands of metres from the Cayo vista -- so
    -- a join routinely has a BR.Spawn.toLobby running underneath the loadscreen.
    -- That trip is faded OUT from its DoScreenFadeOut until its own collision
    -- wait finishes, and its teleport lands the ped on the mark BEFORE that --
    -- so a gate that only asked about the ped would release the loading screen
    -- into the middle of somebody else's black. Waiting for the trip instead of
    -- racing it costs nothing: every wait inside it is already bounded.
    if BR.Spawn and BR.Spawn.traveling then
        return 'a spawn trip is still in flight'
    end

    -- AND THE ENTRANCE HAS TO HAVE ITS PED ON ITS OWN MARK (owner, 2026-08-29).
    --
    -- The lobby ped walks in now, and the owner's choreography has that walk
    -- STARTING under this screen -- the reveal happens partway through it, with
    -- the camera already flying. So the two things this gate has to know are
    -- both questions for client/lobbyped.lua rather than for this file: whether
    -- the walk has begun, and where the ped is supposed to be standing when it
    -- has (the START of the path, not the lobby spot).
    --
    -- IT FAILS OPEN LIKE EVERY OTHER HALF HERE. revealBlock() is bounded by its
    -- own arm wait and answers nil once that expires, and the entrance tick
    -- gives up in the same breath rather than starting a walk after the screen
    -- has already come down.
    if BR.LobbyPed and BR.LobbyPed.revealBlock then
        local why = BR.LobbyPed.revealBlock()
        if why then return why end
    end

    local p = BR.Config and BR.Config.Match and BR.Config.Match.lobbyPos
    if BR.LobbyPed and BR.LobbyPed.revealMark then
        p = BR.LobbyPed.revealMark() or p
    end
    if p then
        local c = GetEntityCoords(ped)
        -- Ten metres, against a placement that is EXACT: the lobby is a camera
        -- mark, so spawn.lua's exact path puts the ped on the authored
        -- coordinates without a ground snap. The slack is for a frozen entity
        -- reading back slightly off, not a second opinion about where the lobby
        -- is -- the failure this catches is a ped in Los Santos, not one that
        -- drifted.
        if BR.Dist(c.x, c.y, p.x, p.y) > 10.0 then
            return 'the ped is not standing on the lobby mark yet'
        end
    end

    return nil
end

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
           and isTrue(NetworkIsSessionStarted()) then break end
        Citizen.Wait(100)
    end

    -- The world. The gag reel keeps the player company through the whole
    -- stream-in; the timeout matters more than the test -- a player who
    -- alt-tabbed through the load must still get their lobby eventually.
    local wDeadline = GetGameTimer() + 60000
    while GetGameTimer() < wDeadline do
        -- isTrue, NOT the bare call. `if HasCollisionLoadedAroundEntity(p) then`
        -- breaks on the 0 that means "no collision here", so the gag reel that
        -- exists to cover the stream-in would be dropped on the first poll --
        -- 250ms into a cold load, over an island that is not there yet.
        if isTrue(HasCollisionLoadedAroundEntity(PlayerPedId())) then break end
        Citizen.Wait(250)
    end

    -- AND THE CHARACTER STANDING IN THE SHOT. THIS IS THE LOBBY'S FADE.
    --
    -- The lobby is a portrait: the ped is the subject and the menu is composed
    -- around the gap left for it (ui-src/src/screens/Lobby.tsx). Everything
    -- above waits for the WORLD -- the session, the interface, the collision
    -- under the vista -- and nothing waited for the person standing in it, so
    -- the reveal raced client/locker.lua's one-and-only model swap. Whichever
    -- won was luck: the owner either got the default freemode ped for a beat
    -- and then a cut to their character, or an empty mark (owner, 2026-08-18).
    --
    -- AND IT IS THE ONLY FADE IN THIS CLIENT THAT A PED CAN RACE. spawn.lua has
    -- five DoScreenFadeIns and not one of them is this moment: the shared one in
    -- reveal() that every placement ends with (which at boot fires UNDER this
    -- loading screen -- the world standing by behind the backdrop, not the lobby
    -- being shown), the trip home's own tail, the WAITING handover out of the
    -- result screen, the anti-black watchdog, and /brunstuck. All five uncover a
    -- ped that is already whatever it is going to be, because locker.lua applies
    -- the stored character EXACTLY ONCE per session -- on the first tick my
    -- state reads LOBBY -- and never again between rounds ("it does NOT
    -- re-apply on every return to the lobby", its own words). So the only
    -- arrival where the character is still being built is this one, and hanging
    -- any of the others off a lobby-ped condition would hold a warmup spawn or a
    -- black-screen recovery on a fact about the lobby.
    --
    -- AND IT IS BOUNDED, LIKE EVERY OTHER WAIT IN THIS FILE. A character whose
    -- model is not on this build never arrives at all -- two roster entries
    -- already were not (locker.lua) -- and a player parked on a loading screen
    -- because of a typo in a model name is far worse than a pop. It gives up,
    -- says which half never came, and reveals anyway.
    local pending = nil
    local pStarted = GetGameTimer()
    local pDeadline = pStarted + PED_WAIT_MS
    while GetGameTimer() < pDeadline do
        -- pcall'd for the same reason the fade cue below is: this runs in a bare
        -- Citizen thread with no handler above it, immediately before the only
        -- code that takes the loading screen down. A predicate that throws would
        -- stop the thread dead and leave the player on the gag reel forever --
        -- the exact unrecoverable failure this file and spawn.lua exist to
        -- prevent -- so an error here releases the screen rather than holding it.
        local probed, why = pcall(lobbyPedPending)
        if not probed then
            print(('[br_core] loading: ped check errored (%s) -- revealing anyway')
                :format(tostring(why)))
            pending = nil
            break
        end
        pending = why
        if not pending then break end
        Citizen.Wait(100)
    end
    if pending then
        print(('[br_core] loading: the lobby ped never settled in %dms (%s) -- revealing anyway')
            :format(PED_WAIT_MS, pending))
    else
        print(('[br_core] loading: lobby ped ready after %dms')
            :format(GetGameTimer() - pStarted))
    end

    -- STREAMING LEADS THE REVEAL, AND THE LEAD IS EXPLICIT (owner, 2026-08-29:
    -- "please set the focus area to the first camera coords 1 second before
    -- fading in").
    --
    -- The entrance's opening shot is three hundred metres from where the player
    -- has been standing and a hundred metres above it, so nothing under it has
    -- streamed. SET_FOCUS_POS_AND_VEL moves where the engine loads terrain and
    -- assets -- that and nothing else; it has no bearing on which entities are
    -- relevant to this client -- and pointing it there before anybody can see
    -- the shot is exactly its job.
    --
    -- THE ORDER IS ENFORCED RATHER THAN HOPED FOR. `revealAt` is a floor the
    -- flip below waits out, so the lead survives somebody retiming the fade cue
    -- or the shutdown; without it the two calls would be a second apart only by
    -- coincidence, which is the failure mode #124 was made of. pcall'd for the
    -- same reason the fade cue is: this is the last stretch before the screen
    -- comes down, and nothing here may be able to strand a player on it.
    local lead = 0
    if BR.LobbyPed and BR.LobbyPed.focusAhead then
        local okf, ms = pcall(BR.LobbyPed.focusAhead)
        if okf and type(ms) == 'number' then lead = ms end
    end
    local revealAt = GetGameTimer() + lead

    -- Text out (the glow stays). The result is LOGGED: if this channel ever
    -- fails the exit degrades to a cut, and the console should say which
    -- half was at fault rather than leaving it to timing forensics.
    local ok, sent = pcall(SendLoadingScreenMessage, '{"eventName":"br:fadeText"}')
    print(('[br_core] loading: fade cue %s')
        :format(ok and ('delivered=' .. tostring(sent)) or 'native unavailable'))
    Citizen.Wait(500)

    -- The reveal. Behind this is the lobby on its opaque twin backdrop,
    -- menu still transparent (worldReady false). If some earlier fade left
    -- the GAME's screen dark, lift it now -- the world must be standing by
    -- behind the backdrop for step 4 to reveal.
    ShutdownLoadingScreenNui()
    ShutdownLoadingScreen()
    if isTrue(IsScreenFadedOut()) then DoScreenFadeIn(400) end
    print('[br_core] loading: screen released to the lobby')

    -- One beat on pure purple, then the double fade: menu in, world in.
    Citizen.Wait(150)

    -- ...AND NOT BEFORE THE STREAMING FOCUS HAS HAD ITS LEAD. Everything above
    -- has already spent most of it; this is the remainder, and it is zero
    -- whenever there is no entrance to lead.
    local left = revealAt - GetGameTimer()
    if left > 0 then Citizen.Wait(left) end

    BR.State.worldReady = true
    TriggerEvent('br:screen:refresh')
    print('[br_core] loading: world ready -- menu and world fade in')
end)
