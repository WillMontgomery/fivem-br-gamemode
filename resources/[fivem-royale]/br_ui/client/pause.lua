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
        BR.Pause.close()
        SetBigmapActive(true, true)
        BR.Pause.bigmap = true
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
        SetBigmapActive(false, false)
        BR.Pause.bigmap = false
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
        SetBigmapActive(false, false)
        BR.Pause.bigmap = false
    end
end)
