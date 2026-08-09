-- The pause menu.
--
-- IT REPLACES GTA'S, IT DOES NOT LAYER OVER IT. The engine's frontend is a
-- scaleform, not a NUI layer: nothing we draw can cover it and it cannot cover
-- us, so the two can never be on screen together. The key is therefore
-- captured before the engine sees it, and OUR menu comes up.
--
-- ESC IS NOT THE KEY, AND CANNOT BE. FiveM cannot rebind the engine's pause
-- control away from Escape, and DisableControlAction on it for the whole match
-- would mean a player whose NUI has broken cannot reach the game's own menu at
-- all -- a soft lock with no escape hatch, which is exactly the class of bug
-- br_ui's focus watchdog exists to prevent. So the pause menu is bound to a
-- key of the player's choosing (F1 by default, rebindable in Settings ->
-- Controls) and Escape still opens GTA's, which stays as the way out of
-- anything we get wrong.
--
-- The MAP is deliberately handed back to the engine. GTA's map is a scaleform
-- we cannot reproduce, and re-rendering Los Santos in CEF would cost real
-- frames -- the same reason the minimap is the engine's and not ours.

local RES = GetCurrentResourceName()

BR = BR or {}
BR.Pause = {}

--- Whether our menu is up. Tracked so the keybind toggles rather than
--- re-pushing focus onto a screen that is already showing.
local open = false

--- Whether GTA's own frontend is up because WE put it there, showing the map.
--- Its watcher thread reads this every frame, so clearing it is how anything
--- else asks the map to close.
local frontendMap = false

function BR.Pause.open()
    if open then return end
    open = true
    TriggerEvent('br:ui:pushFocus', 'pause')
end

function BR.Pause.close()
    if not open then return end
    open = false
    TriggerEvent('br:ui:popFocus', 'pause')
end

--- GTA's own pause menu, driven straight to its map page.
---
--- THIS IS THE COMMUNITY RECIPE (cfx forum, "one button main map"), and the
--- difference from what was here is the part I had wrong: it WAITS ON THE
--- MENU'S OWN STATE rather than guessing at a delay. Every timing-based
--- version of this is reported to bring the map up "at irregular intervals",
--- which is exactly what a fixed 200ms racing a scaleform load looks like.
---
--- Two more pieces that were missing. PAUSE_MENUCEPTION_THE_KICK after
--- GoDeeper: going deeper sets the page, the kick is what commits it -- which
--- is why GoDeeper alone appeared to do nothing. And SetFrontendActive(false)
--- to leave, because the menu is being entered sideways and its own back
--- button has nowhere sensible to go back to.
---
--- It still does not SUPPRESS the other tabs. Nothing does; they are the same
--- scaleform. This lands on the map with the tabs above it, which is what
--- GTA Online itself looks like.
function BR.Pause.openFrontendMap()
    if frontendMap then return end
    frontendMap = true

    Citizen.CreateThread(function()
        -- FE_MENU_VERSION_MP_PAUSE, not SP: the multiplayer pause menu is the
        -- one the map is the point of.
        ActivateFrontendMenu(GetHashKey('FE_MENU_VERSION_MP_PAUSE'), false, -1)

        -- The wait is the fix, but it cannot be unbounded: if the menu never
        -- comes up -- another resource holding the frontend, a state that
        -- refuses it -- this thread would spin at Wait(0) for the rest of the
        -- session, and a busy loop nobody can see is the worst kind.
        local deadline = GetGameTimer() + 5000
        while (not IsPauseMenuActive() or IsPauseMenuRestarting())
              and GetGameTimer() < deadline do
            Citizen.Wait(0)
        end
        if not IsPauseMenuActive() then
            print('[br_ui] map: pause menu never became active; giving up')
            frontendMap = false
            return
        end

        local ok, err = pcall(function()
            PauseMenuceptionGoDeeper(BR.Pause.mapPage or 0)
            PauseMenuceptionTheKick()
        end)
        print(('[br_ui] map: frontend, page %d -- %s')
            :format(BR.Pause.mapPage or 0,
                    ok and 'ok' or ('FAILED ' .. tostring(err))))

        -- 199 and 200 are PAUSE, 202 is FRONTEND CANCEL: the keys a player
        -- actually reaches for to leave a menu. Our own map key gets out too,
        -- by clearing the flag this loop is watching.
        while frontendMap
              and not IsControlJustPressed(2, 202)
              and not IsControlJustPressed(2, 200)
              and not IsControlJustPressed(2, 199) do
            Citizen.Wait(0)
        end

        pcall(PauseMenuceptionTheKick)
        SetFrontendActive(false)
        frontendMap = false
    end)
end

RegisterNUICallback(BR.NuiCb.PAUSE_FOCUS, function(data, cb)
    if data and data.open then BR.Pause.open() else BR.Pause.close() end
    cb({ ok = true })
end)

--- The verbs on the front page.
---
--- EVERY ONE OF THEM IS br_core's TO PERFORM, not ours: leaving a match is a
--- server round trip, leaving a squad is a roster change, and disconnecting is
--- a native br_core already wraps. br_ui owns the page and forwards the verb,
--- which is the same split the locker and the inventory use.
RegisterNUICallback(BR.NuiCb.PAUSE_ACTION, function(data, cb)
    local action = tostring(data and data.action or '')

    if action == 'map' then
        -- THREE ROUTES, SWITCHABLE, BECAUSE THIS IS A QUESTION THE GAME
        -- ANSWERS AND NOT ONE THE DOCUMENTATION DOES.
        --
        --   bigmap      SetBigmapActive -- the radar, expanded (default)
        --   frontend    the real pause menu, driven to its map page
        --   fullscreen  PauseToggleFullscreenMap alone
        --
        -- `brmapmode` switches between them in game.
        if BR.Pause.mapMode == 'frontend' then
            BR.Pause.close()
            BR.Pause.openFrontendMap()
            cb({ ok = true })
            return
        end

        if BR.Pause.mapMode == 'fullscreen' then
            -- PAUSE_TOGGLE_FULLSCREEN_MAP (0x2DE6C5E2E996F178, "toggles pause
            -- menu map rendering") on its own, on the chance it draws the map
            -- with no frontend at all. pcall because a native this obscure is
            -- exactly the kind that is missing from a build, and a missing one
            -- must not take the pause menu down with it.
            BR.Pause.close()
            local ok, err = pcall(PauseToggleFullscreenMap, true)
            print(('[br_ui] map: PauseToggleFullscreenMap(true) %s')
                :format(ok and 'ok' or ('FAILED ' .. tostring(err))))
            BR.Pause.fullscreenMap = true
            cb({ ok = true })
            return
        end

        -- THE BIG MINIMAP, NOT GTA'S PAUSE MENU.
        --
        -- The question was whether the rest of the pause menu's scaleforms
        -- can be suppressed when we only want the map. They cannot -- the
        -- tabs are part of that scaleform and ActivateFrontendMenu's
        -- component argument only chooses which one is FOCUSED (-1 is
        -- already the map).
        --
        -- SET_BIGMAP_ACTIVE avoids the question entirely: it expands the
        -- minimap to the full-screen map GTA Online uses, drawn over live
        -- gameplay, with no frontend, no tabs and no pause. It is what every
        -- resource that wants "just the map" actually uses, and it is better
        -- than what was asked for -- the world keeps running underneath.
        --
        -- IT EXPANDS THE MINIMAP, which is the catch: br_core turns the radar
        -- off in the lobby, so calling this from here worked exactly as
        -- documented on a minimap that was not being drawn, and the button
        -- looked dead (user, 2026-08-09). br_core owns the radar, so br_core
        -- owns this -- one place decides whether the map is on screen.
        BR.Pause.close()
        TriggerEvent('br:map:big', true)
        BR.Pause.bigmap = true
        print('[br_ui] map: big map on')
        cb({ ok = true })
        return
    end

    if action == 'server' then
        -- The client's own `disconnect` is a restricted console command and
        -- comes back "Access denied" (user, 2026-08-09). The server drops us.
        BR.Pause.close()
        TriggerServerEvent(BR.Net.LEAVE_SERVER)
        cb({ ok = true })
        return
    end

    -- 'lobby' and 'squad' are gameplay: br_core decides what they mean.
    BR.Pause.close()
    TriggerEvent('br:ui:pauseAction', action)
    cb({ ok = true })
end)

-- ---------------------------------------------------------------- keybind ---

-- THE KEY LIVES IN br_core, with every other key in the project.
--
-- It was registered here with an empty default and in no binding table at all,
-- which meant the pause menu had no key AND no row in the settings screen to
-- give it one -- there was literally no way to open it (user, 2026-08-09).
-- br_core/client/keybinds.lua registers it (F1) and fires this; TriggerEvent
-- crosses resources, which is the same hop br_core already uses to reach the
-- interface.
AddEventHandler('br:ui:pauseToggle', function()
    -- THE BIG MAP IS A STATE THE SAME KEY GETS YOU OUT OF. It is drawn over
    -- live gameplay with no cursor and no menu, so without this the only way
    -- back would be a key the player has not been told about.
    if BR.Pause.bigmap then
        TriggerEvent('br:map:big', false)
        BR.Pause.bigmap = false
        return
    end
    -- Same rule for the frontend routes: whatever the map key turned on, the
    -- map key turns off. A player should never have to know WHICH native drew
    -- the thing in front of them to get rid of it.
    if frontendMap then
        -- Cleared, not closed here: the watcher thread owns the teardown, and
        -- two callers racing SetFrontendActive is how a frontend gets left up
        -- with nothing listening.
        frontendMap = false
        return
    end
    if BR.Pause.fullscreenMap then
        pcall(PauseToggleFullscreenMap, false)
        BR.Pause.fullscreenMap = false
        return
    end
    if open then BR.Pause.close() else BR.Pause.open() end
end)

-- And a console door, so it can be opened without a keyboard binding at all --
-- which is exactly what you need when the question is "does the key work".
RegisterCommand('brpause', function()
    if open then BR.Pause.close() else BR.Pause.open() end
    print(('[br_ui] pause menu %s'):format(open and 'open' or 'closed'))
end, false)

-- Which route the Map button takes. 'bigmap' draws GTA's full map over live
-- gameplay with no frontend at all; 'frontend' opens the real pause menu and
-- drives it to its map page; 'fullscreen' is PauseToggleFullscreenMap on its
-- own. Switchable so the three can be compared in game rather than argued
-- about from documentation.
--
-- bigmap is the default because the world keeps running underneath it, which
-- in a battle royale is not a small thing: the frontend routes are a PAUSE
-- MENU, and pressing them mid-match means standing still in front of one.
BR.Pause.mapMode = 'bigmap'
BR.Pause.mapPage = nil

RegisterCommand('brmapmode', function(_, args)
    local mode = tostring(args[1] or '')
    if mode == 'frontend' or mode == 'bigmap' or mode == 'fullscreen' then
        BR.Pause.mapMode = mode
        BR.Pause.mapPage = tonumber(args[2])
        print(('[br_ui] map mode: %s%s'):format(mode,
            BR.Pause.mapPage and (' page ' .. BR.Pause.mapPage) or ''))
        return
    end
    print('=== map mode ===')
    print(('  mode: %s'):format(tostring(BR.Pause.mapMode)))
    print(('  page: %s'):format(tostring(BR.Pause.mapPage)))
    print('  bigmap     -- SetBigmapActive: full map over live gameplay, no frontend')
    print('  frontend   -- ActivateFrontendMenu + GoDeeper + TheKick (cfx recipe)')
    print('  fullscreen -- PauseToggleFullscreenMap alone, no frontend at all')
    print('  usage: brmapmode bigmap | fullscreen | frontend [pageId]')
end, false)

-- The page can be closed from under us: a match ending, a br_core restart,
-- the focus watchdog. Watching the focus envelope keeps `open` honest instead
-- of letting it drift into a state where the keybind toggles the wrong way.
AddEventHandler('br:ui:focusChanged', function(screen)
    if screen ~= 'pause' then open = false end
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= RES then return end
    open = false
    -- A big map left active would survive this resource and there would be
    -- nothing left listening for the key that closes it.
    if BR.Pause.bigmap then
        TriggerEvent('br:map:big', false)
        BR.Pause.bigmap = false
    end
    -- Same for the frontend: a pause menu we opened and then stopped listening
    -- for would be a menu the player cannot leave by any route we told them
    -- about. The thread is going away with the resource, so close it here.
    if frontendMap then
        frontendMap = false
        SetFrontendActive(false)
    end
    if BR.Pause.fullscreenMap then
        pcall(PauseToggleFullscreenMap, false)
        BR.Pause.fullscreenMap = false
    end
end)
