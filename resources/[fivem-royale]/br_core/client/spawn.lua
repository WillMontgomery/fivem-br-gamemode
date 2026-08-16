-- Spawning.
--
-- server.cfg deliberately does not start spawnmanager or basic-gamemode: they
-- would spawn players into the world on join and respawn them on death, both of
-- which the match state machine owns. This is their replacement.
--
-- THE GOVERNING RULE HERE IS: NEVER LEAVE THE PLAYER LOOKING AT BLACK.
--
-- A black screen with the HUD drawn on top of it means the loading screen never
-- came down, or the screen faded out and never faded back in. Neither produces
-- an error, neither appears in any log, and the player cannot do anything about
-- it except reconnect. An earlier version of this file put ShutdownLoadingScreen
-- inside a callback that only ran if a collision-wait loop finished -- so if
-- that loop was interrupted, or a second placement started while the first was
-- still running, the screen stayed black forever.
--
-- Now: the loading screen comes down as soon as the session exists, regardless
-- of where the player ends up; placement is serialised so two requests cannot
-- fight; and a watchdog fades the screen back in if it is ever left dark.

BR = BR or {}
BR.Spawn = {}

local spawned = false
local placing = false

-- --------------------------------------------------------------------------
-- The cover handshake
-- --------------------------------------------------------------------------
--
-- COVER THE SCREEN, CHANGE THE WORLD, UNCOVER. In that order, and the order is
-- the entire feature.
--
-- It was not happening. Every transition in this file used to raise a cover and
-- then WAIT A FIXED NUMBER OF MILLISECONDS for it, which is not the same thing
-- as waiting for it: the curtain is a CSS opacity transition inside CEF, on its
-- own frame budget, in another process. On the owner's machine the world change
-- consistently won the race -- "the lobby UI goes away and cuts immediately to
-- the in-game HUD/minimap/teleports my player, and THEN the fade to black
-- happens" (owner, 2026-08-16, #124) -- and three rounds of adjusting the
-- number did not fix it, because no number can.
--
-- The page now says when it is genuinely black (BR.NuiCb.COVERED, via
-- br_ui/client/nui.lua) and these two functions are how the rest of this file
-- waits for it. The waits are BOUNDED: a CEF that has crashed, a POST that was
-- dropped, a transition the browser optimised away -- any of them must cost a
-- visible cut, never a player parked on black with nothing left to release
-- them. That trade is the whole governing rule at the top of this file.

-- What the PAGE says, mirrored off br_ui's report. Never written by a timer.
local coveredNow = {}

-- Whether WE have asked for the curtain. Distinct from coveredNow: "I asked"
-- and "it is up" are different facts, and the whole bug was treating them as
-- one. Also what the watchdog at the bottom of this file reads.
BR.Spawn.curtainWanted = false

AddEventHandler('br:ui:covered', function(kind, on)
    coveredNow[kind] = on == true
end)

-- A NEW PAGE HAS PAINTED NOTHING YET, so nothing is covered.
--
-- br_ui restarting hands CEF a brand new document, and this table does not
-- restart with it -- br_core keeps running. A stale `true` left here is the
-- worst thing in this whole mechanism: the next teardown would find the screen
-- "already black", skip its wait entirely and dismantle the world in front of a
-- perfectly transparent page. That is the original bug, reintroduced, and
-- wearing the fix's own clothes.
--
-- br:ui:ready is fired from the bundle's own module load (see the ENV callback
-- in br_ui/client/nui.lua), so it genuinely means the page exists again.
AddEventHandler('br:ui:ready', function()
    for kind in pairs(coveredNow) do coveredNow[kind] = false end
end)

--- Ask the page for the curtain, or to take it away.
---
--- The STATE we want, every time -- never a toggle. A dropped message then
--- costs one stale frame instead of leaving the two sides inverted with no way
--- back (the rule br_ui/client/players.lua documents).
--- @param show boolean
--- @param kind string|nil  'leaving' | 'dropping' -- the WORDS on the curtain
function BR.Spawn.curtain(show, kind)
    show = show == true
    BR.Spawn.curtainWanted = show
    if show then
        BR.Spawn.curtainAt = GetGameTimer()
        TriggerEvent('br:ui:sendLocal', BR.Nui.LEAVING, { show = true, kind = kind })
    else
        TriggerEvent('br:ui:sendLocal', BR.Nui.LEAVING, { show = false })
    end
end

--- Hold this thread until the page says a cover is fully opaque.
---
--- MUST be called from inside a Citizen thread -- it yields.
--- @param kind string      'curtain' | 'verdict'
--- @param timeoutMs number
--- @return boolean covered  false means the page never answered and we are
---         proceeding anyway, which is deliberate and is logged
function BR.Spawn.awaitCover(kind, timeoutMs)
    if coveredNow[kind] then return true end

    local deadline = GetGameTimer() + (timeoutMs or 2500)
    while GetGameTimer() < deadline do
        Citizen.Wait(16)   -- one frame: this is the thing being waited ON
        if coveredNow[kind] then return true end
    end

    -- SAID OUT LOUD, because "it still cuts" and "the acknowledgement never
    -- arrived so everything fell back to a timeout" look identical in game and
    -- have completely different causes. /brcover reads the same state.
    print(('[br_core] cover "%s" never acknowledged in %dms -- proceeding')
        :format(tostring(kind), timeoutMs or 2500))
    return false
end

--- Place the local player, waiting for the world to stream in.
---
--- The wait matters: teleporting to coordinates whose collision has not loaded
--- drops the player through the map. Freezing during the wait prevents that.
---
--- Serialised on `placing`. Two overlapping placements would each freeze and
--- unfreeze the ped, and whichever finished first would unfreeze a player the
--- other still intended to hold still.
---
--- @param x number
--- @param y number
--- @param z number
--- @param heading number|nil
--- @param cb function|nil
function BR.Spawn.placeAt(x, y, z, heading, cb)
    if placing then
        if BR.Server and BR.Server.devMode then
            print('[br_core] placement already in progress, ignoring')
        end
        return
    end
    placing = true

    local ped = PlayerPedId()
    RequestCollisionAtCoord(x, y, z)
    SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
    SetEntityHeading(ped, heading or 0.0)
    FreezeEntityPosition(ped, true)

    Citizen.CreateThread(function()
        local groundZ = z

        -- ~4 seconds: long enough for a cold streaming load, short enough that
        -- failing does not look like a hang.
        for _ = 1, 40 do
            Citizen.Wait(100)
            RequestCollisionAtCoord(x, y, z)
            if HasCollisionLoadedAroundEntity(ped) then
                local found, gz = GetGroundZFor_3dCoord(x, y, z + 50.0, false)
                if found then groundZ = gz + 1.0 end
                break
            end
        end

        -- Re-read the ped: it can change while we waited (a respawn, a model
        -- swap), and unfreezing a stale handle would leave the real one stuck.
        ped = PlayerPedId()
        SetEntityCoordsNoOffset(ped, x, y, groundZ, false, false, false)
        FreezeEntityPosition(ped, false)

        -- Unconditional. Whatever happened above, the player can see and move.
        BR.Spawn.reveal()

        placing = false
        if cb then cb() end
    end)
end

--- Make sure the player can actually see the world.
---
--- Safe to call at any time and as often as you like. This is the single place
--- that undoes every way the screen can be dark, and there are more of them
--- than the obvious one:
---
---   * the loading screen never came down
---   * the screen was faded out and never faded back in
---   * the screen was NEVER FADED IN AT ALL -- distinct from the above, and the
---     one that bit us. After connecting, the screen is dark without any fade
---     having been performed, so IsScreenFadedOut() returns FALSE and a
---     watchdog checking only that sees nothing wrong.
---   * the player is mid "switch" (the cinematic GTA uses to move between
---     characters), which renders black until switched in
---   * player control was never handed back
function BR.Spawn.reveal()
    -- THE BOOT CHOREOGRAPHY OWNS THE LOADSCREEN. While worldReady is still
    -- false, loading.lua is mid-sequence -- gag reel, text fade, purple
    -- hold, double fade -- and these two calls firing from the vista
    -- placement WAS the "loadscreen instantly pops instead of fading" report:
    -- the spawn completes before the collision wait, reveal() ran, and the
    -- screen died mid-reel with the fade cue still queued. loading.lua has
    -- its own hard deadlines for every wait, and brunstuck stays the
    -- unconditional manual escape.
    if BR.State.worldReady ~= false then
        ShutdownLoadingScreen()
        ShutdownLoadingScreenNui()
    end

    -- Not `IsScreenFadedOut`: see above. Fading in an already-faded-in screen
    -- is a no-op, so this is safe to call repeatedly. holdBlack is the one
    -- legitimate dark screen: the end-of-match sequence owns the fade until
    -- WAITING, and this reveal racing it was the rough lobby transition.
    if not BR.Spawn.holdBlack
       and not IsScreenFadedIn() and not IsScreenFadingIn() then
        DoScreenFadeIn(500)
    end

    -- GTA can leave a joining player mid-switch, which renders black no matter
    -- what the fade state says.
    if IsPlayerSwitchInProgress() then
        SwitchInPlayer(PlayerPedId())
    end

    SetPlayerControl(PlayerId(), true, 0)
end

--- Everything that determines whether the player can see anything.
---
--- "Black screen" carries no error and no log line, and the cause is one of
--- half a dozen unrelated states. Printing all of them at once turns a guessing
--- game into a reading.
--- @return table
function BR.Spawn.diagnose()
    local ped = PlayerPedId()

    -- Every probe is wrapped. This runs precisely when something is already
    -- wrong, and a diagnostic that throws halfway through tells you less than
    -- no diagnostic at all -- GetRenderingCam with no active camera is exactly
    -- the sort of call that misbehaves in that state.
    local function safe(fn, fallback)
        local ok, v = pcall(fn)
        if ok then return v end
        return fallback == nil and 'error' or fallback
    end

    return {
        fadedIn      = safe(function() return IsScreenFadedIn() end),
        fadedOut     = safe(function() return IsScreenFadedOut() end),
        fadingIn     = safe(function() return IsScreenFadingIn() end),
        fadingOut    = safe(function() return IsScreenFadingOut() end),
        switchActive = safe(function() return IsPlayerSwitchInProgress() end),
        switchState  = safe(function() return GetPlayerSwitchState() end),
        pedExists    = safe(function() return DoesEntityExist(ped) end),
        pedVisible   = safe(function() return IsEntityVisible(ped) end),
        pedDead      = safe(function() return IsEntityDead(ped) end),
        frozen       = safe(function() return IsEntityPositionFrozen(ped) end),
        collision    = safe(function() return HasCollisionLoadedAroundEntity(ped) end),
        scriptCam    = safe(function()
            local c = GetRenderingCam()
            return c and c ~= -1 and IsCamRendering(c) or false
        end, false),
        placing      = placing,
        spawned      = spawned,
        pos          = safe(function()
            local p = GetEntityCoords(ped)
            return ('%.0f, %.0f, %.0f'):format(p.x, p.y, p.z)
        end, '?'),
        matchState   = BR.State and BR.State.match and BR.State.match.state or '?',
        playerState  = BR.State and BR.State.me and BR.State.me.state or '?',
    }
end

--- Put the player into the world ALIVE at a position.
---
--- Distinct from placeAt, which only moves them. Teleporting a dead ped gives
--- you a corpse at the new coordinates: after a match ended, players were
--- returned to the warmup pad still dead, reading 0 hp with a valid ped handle
--- at the right position. Resurrection has to be explicit, and without
--- spawnmanager nothing else does it.
---
--- @param x number
--- @param y number
--- @param z number
--- @param heading number|nil
--- @param exact boolean|nil
--- @param cb function|nil  called once the player is genuinely placed. Only
---        the non-exact path is asynchronous; the exact path calls it before
---        returning, so a caller never has to know which one it took.
function BR.Spawn.respawn(x, y, z, heading, exact, cb)
    local ped = PlayerPedId()

    NetworkResurrectLocalPlayer(x, y, z, heading or 0.0, true, false)
    ClearPedTasksImmediately(ped)
    RemoveAllPedWeapons(ped, true)

    -- Re-apply the health model: resurrection restores GTA's defaults, not ours.
    BR.Native.initHealthModel()

    if exact then
        -- EXACTLY these coordinates, no ground snap. The lobby spot is a
        -- CAMERA MARK: the shot is framed from the authored position, six
        -- feet in front of wherever the ped's feet land, so a ground probe
        -- that moved them half a metre downhill would move the subject out of
        -- its own frame. placeAt's ground-finding is right for the warmup
        -- scatter and wrong here. The per-frame LOBBY freeze holds them.
        SetEntityCoordsNoOffset(ped, x, y, z, false, false, false)
        SetEntityHeading(ped, heading or 0.0)
        FreezeEntityPosition(ped, true)
        BR.Spawn.reveal()
        if cb then cb() end
        return
    end

    BR.Spawn.placeAt(x, y, z, heading, cb)
end

--- Bring the player into the world for the first time: straight onto the
--- lobby mark, where BR.LobbyCam frames them. Visibility is owned by the game
--- rules (client/natives.lua) and OTHER players' lobby peds are hidden by
--- each client for itself (client/squadmates.lua), so nothing here has to
--- hide anyone.
local function initialSpawn()
    if spawned then return end
    spawned = true

    local p = BR.Config.Match.lobbyPos
    BR.Spawn.respawn(p.x, p.y, p.z, p.heading, true)

    print('[br_core] spawned at the lobby vista')
end

--- Return to the lobby vista behind a screen fade.
---
--- The sequence the transition NEEDS, in order: black first, THEN the world
--- change (the island coming back is also Los Santos going away -- watching
--- that happen was an eight-second texture void), then the teleport, then
--- collision under our feet, then light. The lobby interface renders above
--- the fade throughout, so the menu is usable the whole time.
--- @param holdBlack boolean|nil  end-of-match mode: let the result slam play
---        over the live world first, then go dark and STAY dark -- the fade
---        back in belongs to WAITING, when the result screen hands over to
---        the lobby card. Without it (the /brleave path), fade out now and
---        back in as soon as the vista is under our feet.
function BR.Spawn.toLobby(holdBlack)
    if BR.Spawn.traveling then return end
    BR.Spawn.traveling = true
    Citizen.CreateThread(function()
        local began = GetGameTimer()
        if holdBlack then
            BR.Spawn.holdBlack = true

            -- THE WORLD IS STILL THE WORLD WHILE THE VERDICT SLAMS.
            --
            -- The owner's report, verbatim (2026-08-16, #124): "when the
            -- verdict slam text is shown: the player should still be able to
            -- move during that point (but can't), any vehicle they were
            -- driving despawns for some reason, and if they were in the storm,
            -- the storm effects stop rendering, THEN it fades to black."
            --
            -- All three were the same event -- the SERVER's roster sweep to
            -- LOBBY, which fired the instant the match was decided. LOBBY is
            -- what freezes the ped (client/natives.lua), what moves the player
            -- into the lobby routing bucket (so the car they were sitting in
            -- stops existing for them), and what stops the storm drawing
            -- (client/storm.lua). The match was over but the world had not
            -- gone anywhere yet, and we dismantled it in plain sight.
            --
            -- So the sweep waits for THIS: the page reporting that the verdict
            -- backdrop has reached solid black. Then the world is taken away
            -- under cover, which is what the cover was for.
            local ok = BR.Spawn.awaitCover('verdict',
                BR.Config.Match.verdictWaitMs or 6000)

            -- AND THE SERVER IS TOLD BY US, because it cannot see a screen.
            -- Sent even when the page never answered: the deadline above has
            -- already expired, the server has its own longer one behind this
            -- (coverSweepMs), and a player whose page died must still be swept
            -- home rather than left standing in a finished match.
            TriggerServerEvent(BR.Net.MATCH_COVERED)
            if not ok then
                print('[br_core] verdict cover never confirmed -- swept on the timeout')
            end

            -- The REST of the result sequence plays out under that black:
            -- secondary lines at rest (~4.9s) plus a hold on the finished
            -- card. Only then does the teleport-and-swap begin.
            --
            -- 8.4s from the transition, UP FROM 6.9s (owner's call,
            -- 2026-08-09) -- and measured from the transition rather than
            -- slept for outright, because the cover wait above has already
            -- spent part of it. This is a CONTENT duration (how long the
            -- verdict is on screen), not a fade being timed against: the
            -- ordering is owned by the handshake above, and shortening this
            -- would clip the animation, not un-hide a cut.
            local left = 8400 - (GetGameTimer() - began)
            if left > 0 then Citizen.Wait(left) end

            -- AND THEN IT WAITS FOR THE INTERFACE, if the interface is still
            -- doing something.
            --
            -- The XP award lands on this screen, and when it crosses a level
            -- it runs a burst that is the whole point of the system. Timing
            -- the teardown against an animation in another process is a guess,
            -- and the guess kept cutting off the last beat -- so the page says
            -- when it is busy (BR.Nui XP_BUSY) and this holds while it is.
            --
            -- THE CAP IS NOT OPTIONAL. A page that never says "done" -- a
            -- reload mid-award, an error in a handler -- would otherwise leave
            -- a player on a black screen forever, which is a far worse failure
            -- than a clipped animation.
            local until_ = GetGameTimer() + 6000
            while BR.Spawn.xpBusy and GetGameTimer() < until_ do
                Citizen.Wait(100)
            end
        end

        -- THE CURTAIN GOES FIRST ON THIS ROAD TOO. /brleave and the server's
        -- TO_LOBBY both raise it before calling in here, and this used to fade
        -- the WORLD out immediately afterwards -- a game fade racing a CSS
        -- transition that had not landed, so the teleport could happen with the
        -- curtain still see-through. Only waited on when somebody actually
        -- asked for a curtain: the lobby watchdog comes through here with no
        -- cover at all and must not sit out a timeout for one it never wanted.
        if BR.Spawn.curtainWanted then
            BR.Spawn.awaitCover('curtain', BR.Config.Match.coverWaitMs or 2500)
        end

        DoScreenFadeOut(400)
        local t0 = GetGameTimer()
        while not IsScreenFadedOut() and GetGameTimer() - t0 < 1000 do
            Citizen.Wait(50)
        end

        local p = BR.Config.Match.lobbyPos
        BR.Spawn.respawn(p.x, p.y, p.z, p.heading, true)

        -- Hold black until the island is actually under us; br_environment
        -- flips it on within a second of the state change.
        RequestCollisionAtCoord(p.x, p.y, p.z)
        local deadline = GetGameTimer() + 8000
        while GetGameTimer() < deadline
              and not HasCollisionLoadedAroundEntity(PlayerPedId()) do
            Citizen.Wait(100)
        end
        Citizen.Wait(300)   -- one breath for textures behind the collision

        if not BR.Spawn.holdBlack then
            DoScreenFadeIn(600)
        end
        BR.Spawn.traveling = false
    end)
end

-- THE LOBBY STATE ALWAYS MEANS THE VISTA, no matter which door led to it.
-- The choreographed path only runs off the ENDED transition -- so any other
-- road to the LOBBY state (brforce cleanup mid-match, an admin resetting a
-- stuck round) left the player standing in Los Santos with the menu over a
-- live world and no teleport. This watcher closes every such gap: my state
-- says lobby, my ped is far from the vista, and no trip is already running
-- -- go home behind an ordinary fade.
BR.Loop.register(BR.Loop.TICK, 'spawn.lobbywatch', function()
    if BR.State.me.state ~= BR.PlayerState.LOBBY then return end
    if BR.Spawn.traveling or BR.Spawn.holdBlack then return end
    if BR.State.match.state == BR.MatchState.ENDED then return end

    local p = BR.Config.Match.lobbyPos
    local c = GetEntityCoords(PlayerPedId())
    if BR.Dist(c.x, c.y, p.x, p.y) > 150.0 then
        print('[br_core] lobby state away from the vista -- going home')
        BR.Spawn.toLobby(false)
    end
end)

--- Return the player to the warmup pad, alive, scattered slightly so a full
--- lobby does not stack everyone on one point.
---
--- BEHIND A FADE, IN THIS ORDER, AND THE ORDER IS THE WHOLE POINT: black
--- first, THEN the camera released, then the teleport, then collision under
--- our feet, then light.
---
--- The lobby is a locked character shot now, and handing the view back to the
--- game while it is on screen snaps from a portrait to a third-person
--- gameplay camera in a single frame -- which reads as a bug rather than as
--- the match starting. Doing it under black costs nothing and is invisible,
--- which is the same argument BR.Spawn.toLobby already makes for the trip in
--- the other direction (user, 2026-08-08).
---
--- respawn rather than placeAt: this runs between matches, and whoever died in
--- the last one is still a corpse until something resurrects them. placeAt's
--- own reveal() at the end of its collision wait IS the fade back in -- there
--- is deliberately no second one here to race it.
--- @return boolean  whether the trip actually started
function BR.Spawn.toWarmupPad()
    -- REFUSED, NOT SWALLOWED. The caller latches on "I have gathered this
    -- player", so a silent refusal here (a trip home still finishing when the
    -- next match's warmup arrives -- entirely possible now that readying up
    -- during a summary jumps ENDED straight to WARMUP) would leave them
    -- standing in the lobby for the whole warmup with the flag saying it had
    -- been handled.
    if BR.Spawn.traveling then return false end
    BR.Spawn.traveling = true

    Citizen.CreateThread(function()
        -- 1. THE CURTAIN FIRST, AND IT IS NUI, NOT THE GAME'S FADE.
        --
        -- DoScreenFadeOut blacks the WORLD. It does not touch the HUD, which
        -- we draw over the world, or the radar, which the engine draws -- so
        -- a game fade on its own left both of them floating on a black
        -- rectangle for the whole trip, and the lobby menu vanished in one
        -- frame underneath (user, 2026-08-09). An opaque NUI curtain covers
        -- every layer at once and fades in rather than cutting.
        --
        -- ...AND IT IS WAITED FOR, NOT SLEPT THROUGH. This was
        -- `Citizen.Wait(450)` with the comment "the curtain's own 600ms fade,
        -- mostly landed" -- a guess at another process's frame budget, and
        -- "mostly" is what the owner saw: the teleport and the HUD arriving
        -- through a curtain that was still see-through (#124). The page says
        -- when it is black; this waits for that, bounded, and says so if it
        -- never comes.
        --
        -- Usually already true by the time we get here -- client/state.lua
        -- raises the same curtain the moment the server names us a
        -- participant, before it lets the new state reach the page at all --
        -- in which case this returns immediately.
        BR.Spawn.curtain(true, 'dropping')
        BR.Spawn.awaitCover('curtain', BR.Config.Match.coverWaitMs or 2500)

        -- 2. Then the world goes dark too, so nothing renders a teleport
        --    underneath the curtain if it is ever less than fully opaque.
        DoScreenFadeOut(300)
        local t0 = GetGameTimer()
        while not IsScreenFadedOut() and GetGameTimer() - t0 < 1200 do
            Citizen.Wait(50)
        end

        -- A NEW MATCH IS PLACING US IN THE WORLD: whatever end-of-match dark
        -- hold was running is over -- even though its WAITING handover never
        -- arrived. Under parallel matches a player who dies, returns to the
        -- lobby and readies up during the old match's summary jumps ENDED ->
        -- (new match's) WARMUP directly, and holdBlack -- released only by
        -- WAITING, and respected by the anti-black watchdog -- parked exactly
        -- those players on a permanent black screen at the warmup pad (live
        -- repro, 2026-08-04: consistently the client that had DIED).
        --
        -- Cleared WITHOUT fading in here: the fade belongs to placeAt, at the
        -- far end, once there is ground to stand on.
        BR.Spawn.holdBlack = false

        BR.LobbyCam.stop()

        local pad = BR.Config.Match.warmupPos
        local r = BR.Config.Match.warmupRadius * 0.5
        local theta = math.random() * 2.0 * math.pi
        local dist = r * math.sqrt(math.random())

        -- THE LAST THING TO LIFT IS THE CURTAIN, and it lifts on the world
        -- being ready rather than on a timer. placeAt waits for collision and
        -- calls reveal() (the game's fade back in) before this runs, so by
        -- the time the curtain goes the pad is under the player's feet and
        -- the HUD is already drawn -- the player fades INTO the warmup, which
        -- is the whole point of the ordering.
        local function landed()
            BR.Spawn.traveling = false
            -- One breath after the world fade so the two do not both move at
            -- once; the curtain then takes its own 600ms to clear.
            Citizen.SetTimeout(250, function()
                BR.Spawn.curtain(false)
            end)
        end

        BR.Spawn.respawn(
            pad.x + math.cos(theta) * dist,
            pad.y + math.sin(theta) * dist,
            pad.z,
            pad.heading,
            false,
            landed)

        -- placeAt refuses to start while another placement is running, in
        -- which case the callback above never fires -- and the curtain would
        -- stay down over a perfectly healthy game, which is the same
        -- unrecoverable black screen this file exists to prevent. The
        -- deadline is the escape, not the plan.
        Citizen.SetTimeout(9000, function()
            if BR.Spawn.traveling then
                print('[br_core] warmup placement did not report back -- releasing')
                BR.Spawn.reveal()
                landed()
            end
        end)
    end)

    return true
end

RegisterNetEvent(BR.Net.STATE)
AddEventHandler(BR.Net.STATE, function(d)
    -- The radar is no longer touched here: it rides MY player state in the
    -- per-frame gamerules (hidden whenever I am in the LOBBY), which covers
    -- both the teardown and the "minimap poking out under the lobby menu"
    -- report in one rule.
    if d.state == BR.MatchState.ENDED then
        -- The moment the match is decided: the verdict slams in over the
        -- world, and the trip home happens under black that does not lift
        -- until WAITING.
        BR.Spawn.toLobby(true)
    elseif d.state == BR.MatchState.WAITING then
        -- The result screen has just handed over to the lobby card; NOW the
        -- world may come back behind it.
        if BR.Spawn.holdBlack then
            BR.Spawn.holdBlack = false
            DoScreenFadeIn(2000)
        end
    end
end)

-- WARMUP moves only the players who are IN the match, and the trigger is MY
-- state, not the match transition: the STATE broadcast is deliberately sent
-- BEFORE onEnter's roster deltas (clients must not learn a match started
-- before learning who is in it), so at the moment 'warmup' arrives my own
-- state still reads lobby. Watching my state instead means the gather
-- happens when the server actually names me a participant -- late joiners
-- included, which no transition-time check could ever cover.
local gathered = false
BR.Loop.register(BR.Loop.TICK, 'spawn.gather', function()
    if BR.State.me.state == BR.PlayerState.WARMUP then
        -- The latch is set by the TRIP STARTING, not by having tried. A
        -- refusal (a trip home still finishing) leaves it clear so the next
        -- tick tries again, 100ms later, which is the whole retry policy this
        -- needs.
        if not gathered then
            gathered = BR.Spawn.toWarmupPad()
        end
    else
        gathered = false
    end
end)

-- The server's half of /brleave: it has already recorded the elimination (if
-- any) and set us back to LOBBY; all that is left is the physical trip.
RegisterNetEvent(BR.Net.TO_LOBBY)
AddEventHandler(BR.Net.TO_LOBBY, function()
    -- THE LEAVING INTERSTITIAL (user call, 2026-08-04). A voluntary leave
    -- used to snap straight to a half-streamed Cayo. Now: an opaque black
    -- NUI screen with a quiet "Leaving the match" fly-up covers everything
    -- IMMEDIATELY; the teleport and the island swap happen under it; it
    -- lifts only once the vista genuinely exists (collision loaded, with a
    -- hard timeout -- nobody gets parked on a black screen).
    BR.Spawn.curtain(true, 'leaving')

    BR.Spawn.toLobby()

    -- THE CURSOR RIDES THE TRIP HOME. The focus grant for a voluntary
    -- leaver rode the roster-delta path and at least once never landed --
    -- lobby menu up, no cursor, game still eating input (live report,
    -- 2026-08-04). This event IS the server saying "you are a lobby
    -- player now", so assert the focus here too; pushFocus is idempotent.
    Citizen.SetTimeout(600, function()
        if BR.State.me.state == BR.PlayerState.LOBBY then
            TriggerEvent('br:ui:pushFocus', 'lobby')
        end
    end)

    Citizen.CreateThread(function()
        -- Give the text a beat to be read even on an instant trip, then
        -- hold until the island is real underfoot -- and then TWO MORE
        -- seconds: collision loads well before the island's visuals finish
        -- streaming, and lifting on collision alone still showed a
        -- half-baked Cayo (live report, 2026-08-04).
        local minUntil = GetGameTimer() + 3500
        local deadline = GetGameTimer() + 15000
        while GetGameTimer() < deadline do
            local ped = PlayerPedId()
            local p = BR.Config.Match.lobbyPos
            local c = GetEntityCoords(ped)
            if GetGameTimer() >= minUntil
               and BR.Dist(c.x, c.y, p.x, p.y) < 200.0
               and HasCollisionLoadedAroundEntity(ped) then
                break
            end
            Citizen.Wait(200)
        end
        Citizen.Wait(2000)
        BR.Spawn.curtain(false)
    end)
end)

--- Leave the current match and return to the lobby.
---
--- A COMMAND rather than a button, by design: mid-match the HUD never holds
--- NUI focus (that rule is what keeps players able to move and shoot), so
--- there is nothing on screen to click. A console/chat command plus a
--- bindable key in Pause > Settings > Key Bindings costs no focus at all.
--- Unbound by default -- a mispressed key must not be able to forfeit a match.
RegisterCommand('brleave', function()
    if BR.State.me.state == BR.PlayerState.LOBBY then
        print('[br_core] not in a match')
        return
    end
    -- The interstitial rises HERE, before the server round-trip: the LOBBY
    -- roster delta can beat TO_LOBBY across the wire, and the menu flashed
    -- in the gap (live report, 2026-08-04). TO_LOBBY owns the hide; the
    -- fallback below only covers a refused or lost leave.
    BR.Spawn.curtain(true, 'leaving')
    TriggerServerEvent(BR.Net.MATCH_LEAVE)
    Citizen.SetTimeout(3000, function()
        if BR.State.me.state ~= BR.PlayerState.LOBBY
           and not BR.Spawn.traveling then
            BR.Spawn.curtain(false)
        end
    end)
end, false)
RegisterKeyMapping('brleave', 'Royale: Leave the current match', 'keyboard', '')

Citizen.CreateThread(function()
    -- The one thread outside the loop registry: it runs once at startup and
    -- then never again, so a permanently-registered callback would cost more
    -- than it saves.
    while not NetworkIsSessionStarted() do
        Citizen.Wait(100)
    end

    -- Take the loading screen down as soon as there is a session, BEFORE any
    -- placement. Tying it to the end of a placement meant an interrupted
    -- placement left the player staring at black with the HUD drawn on top.
    BR.Spawn.reveal()

    Citizen.Wait(500)
    initialSpawn()
end)

-- Watchdog.
--
-- The condition is `not IsScreenFadedIn()`, NOT `IsScreenFadedOut()`. Those are
-- different states and the distinction is the whole bug: after connecting, the
-- screen is dark without any fade having been performed, so IsScreenFadedOut()
-- is false and a watchdog checking it sees a perfectly healthy screen while the
-- player stares at black.
--
-- Two consecutive ticks before acting, so a legitimate fade in progress is not
-- interrupted.
local darkTicks = 0
BR.Loop.register(BR.Loop.SLOW, 'spawn.antiblack', function()
    if placing or not spawned then
        darkTicks = 0
        return
    end

    -- A TRIP IS A DELIBERATELY DARK SCREEN TOO. toLobby and toWarmupPad both
    -- fade out, then wait for collision at the far end -- which can be
    -- several seconds, comfortably past this watchdog's two-tick patience.
    -- Recovering there does not rescue anything; it fades the world in
    -- halfway through a teleport and then the trip fades it out again. Both
    -- ends of every trip call reveal() themselves.
    if BR.Spawn.traveling then
        darkTicks = 0
        return
    end

    -- holdBlack is a deliberately dark screen (the end-of-match sequence);
    -- recovering from it would fade the aftermath in behind the result
    -- card. But the hold is only legitimate while that sequence is
    -- actually running: the mirror reading WAITING with the hold still set
    -- means the release signal was swallowed somewhere upstream, and a
    -- watchdog that keeps deferring to it parks the player on black
    -- forever (live repro, 2026-08-04). An expired hold is released here,
    -- not respected.
    if BR.Spawn.holdBlack then
        if BR.State.match.state == BR.MatchState.WAITING then
            print('[br_core] holdBlack outlived the match -- releasing (watchdog)')
            BR.Spawn.holdBlack = false
            DoScreenFadeIn(1000)
        end
        darkTicks = 0
        return
    end

    if IsScreenFadedIn() or IsScreenFadingIn() then
        darkTicks = 0
        return
    end

    darkTicks = darkTicks + 1
    if darkTicks < 2 then return end
    darkTicks = 0

    print('[br_core] screen is not faded in -- recovering (watchdog)')
    for k, v in pairs(BR.Spawn.diagnose()) do
        print(('[br_core]   %-13s %s'):format(k, tostring(v)))
    end
    BR.Spawn.reveal()
end)

-- The curtain's own watchdog.
--
-- Every OTHER black screen in this file has one, and the curtain -- an opaque
-- NUI layer over the whole interface -- is the one the engine's own diagnostics
-- cannot see at all: /brblack reads a perfectly healthy, faded-IN screen while
-- the page paints over it. That is the exact failure the CEF environment report
-- in br_ui warns about, arrived at from the other direction.
--
-- The curtain now goes up in more places than it used to (client/state.lua
-- raises it before a match's state is allowed to reach the page), so the number
-- of ways a trip can be abandoned between "raise" and "lower" went up with it:
-- a refused placement, a state that bounces back to lobby, a server that never
-- sends the next transition. Every one of those leaves a black rectangle over a
-- working game with nothing left to remove it.
--
-- Fifteen seconds is longer than the longest legitimate trip (the leave path
-- waits on collision plus two seconds, with a 15s ceiling of its own), so this
-- can only fire on something that has genuinely been abandoned.
local CURTAIN_MAX_MS = 15000
BR.Loop.register(BR.Loop.SLOW, 'spawn.curtainwatch', function()
    if not BR.Spawn.curtainWanted then return end
    if BR.Spawn.traveling or BR.Spawn.holdBlack then return end
    if GetGameTimer() - (BR.Spawn.curtainAt or 0) < CURTAIN_MAX_MS then return end

    print('[br_core] the curtain outlived its trip -- lifting (watchdog)')
    BR.Spawn.curtain(false)
end)

RegisterCommand('brblack', function()
    -- Read this when the screen is black. Every state that can cause it, at once.
    print('=== screen / spawn diagnosis ===')
    local d = BR.Spawn.diagnose()
    for _, k in ipairs({
        'fadedIn', 'fadedOut', 'fadingIn', 'fadingOut',
        'switchActive', 'switchState',
        'pedExists', 'pedVisible', 'pedDead', 'frozen', 'collision',
        'scriptCam', 'placing', 'spawned', 'pos', 'matchState', 'playerState',
    }) do
        print(('  %-13s %s'):format(k, tostring(d[k])))
    end
    -- The hint reflects the ACTUAL values rather than printing a fixed line
    -- that contradicts them -- a static footer saying "faded in is false" under
    -- a reading of true is worse than no footer.
    if d.fadedIn == true or d.fadedIn == 1 then
        print('  -- screen is faded in; if it still looks black the page is')
        print('     painting over the game. Check the overlay line at startup.')
    elseif d.fadedOut == true or d.fadedOut == 1 then
        print('  -- faded OUT: something faded and never faded back in.')
    else
        print('  -- never faded in at all, which is a different fault from')
        print('     being faded out. The watchdog should recover this.')
    end
    print('  -- run brunstuck to force recovery')
end, false)

RegisterCommand('brunstuck', function()
    -- Manual escape hatch for anything the watchdog does not catch.
    local ped = PlayerPedId()
    placing = false

    FreezeEntityPosition(ped, false)
    SetEntityVisible(ped, true, false)
    SetEntityCollision(ped, true, true)
    SetPlayerControl(PlayerId(), true, 0)

    -- Tear down any script camera: one left rendering shows whatever it points
    -- at, which after a failed placement is often nothing at all.
    RenderScriptCams(false, false, 0, true, true)
    DestroyAllCams(true)
    ClearFocus()

    if IsPlayerSwitchInProgress() then
        SwitchInPlayer(ped)
    end

    ShutdownLoadingScreen()
    ShutdownLoadingScreenNui()
    DoScreenFadeIn(300)

    print('[br_core] unstuck: screen restored, ped unfrozen, cams cleared')
end, false)

-- THE INTERFACE ASKING FOR MORE TIME. Raised by the post-match XP award while
-- it animates and cleared when it finishes; the result hold above waits on it,
-- capped. br_ui owns the page and forwards the flag -- br_core owns the trip
-- home and decides what to do about it.
AddEventHandler('br:xp:busy', function(busy)
    BR.Spawn.xpBusy = busy == true
end)
