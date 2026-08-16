--[[
    The in-game player list and report panel, this side of the wire.

    THIS FILE DECIDES NOTHING. It asks the server who is here, renders what
    comes back, and forwards what the player pressed. The bucket is resolved
    server-side, the categories and the remaining allowance arrive with the
    list, and a report is validated against all of it again on the far end.

    LATCHING, NOT HELD (#95). The key is br_core's -- registered there as
    `brplayers`, rebindable in Settings like everything else -- and it is a
    `tap` because only `tap` accepts the raw-layer VK override that tilde needs.
    So this toggles rather than tracking a held key, and there is no release
    event to miss.

    IT ASKS EVERY TIME IT OPENS. A cached list would show somebody who left
    thirty seconds ago as present and, worse, hide somebody who just joined the
    match -- and the whole point of the panel is naming who is actually here.
]]

BR = BR or {}
BR.PlayerList = {}

--- Whether the panel is currently up. Owned here because the keybind has to
--- toggle something, and RECONCILED against the focus stack at the bottom of
--- this file, because the stack is what actually knows (#121).
local open = false

--- ONE SCREEN FOR ONE PANEL, again.
---
--- It was two for a day. `players` kept game input so the roster could be read
--- on the move, and `playersReport` existed for no other reason than to NOT be
--- in BR.FocusKeepsInput -- a report has a text field, and with input kept
--- every keystroke in it is also a movement key, so typing a note walked you
--- off a roof.
---
--- View mode gave up keep-input too in #135 ("The player list doesn't capture
--- mouse input today. It should" -- owner, 2026-08-16), and the moment it did,
--- both modes wanted the same focus and the second screen was machinery that
--- did nothing. It is DELETED rather than left inert, here, in the resolver's
--- table and in the page's focus union: an unused branch in the one part of
--- this interface that has already been got wrong twice is not a spare part,
--- it is a thing the next reader has to disprove.
---
--- The mode is now entirely the page's business. Lua is not told about it and
--- has no reason to want to be.
local SCREEN = 'players'

--- Reconcile the focus stack to the state the page asked for.
---
--- STATE, NOT TOGGLES. The page sends what it wants to be true, never "flip
--- it" -- a dropped message then costs one stale frame instead of leaving the
--- panel and the cursor permanently disagreeing, which is the failure this
--- interface has already had twice.
---
--- `open` IS WRITTEN BEFORE THE PUSH OR THE POP, and that ordering is load
--- bearing now that the handler at the bottom of this file listens to focus:
--- pushFocus/popFocus emit `br:ui:focusChanged` synchronously, so that handler
--- runs INSIDE this function. It reads `open`, and it must read the value we
--- are on our way to, not the one we are leaving.
local function apply(wantOpen)
    if wantOpen == open then return end
    open = wantOpen

    if wantOpen then
        TriggerServerEvent(BR.Net.PLAYERS_ASK)
        TriggerEvent('br:ui:pushFocus', SCREEN)
    else
        TriggerEvent('br:ui:popFocus', SCREEN)
    end
end

--- Ask the server and show the panel.
local function show()
    apply(true)
end

--- Close it, in whichever mode the page had it in. There is nothing to unwind:
--- the mode is React state on a component that unmounts with the panel, so it
--- cannot survive to be wrong the next time this opens.
local function hide()
    apply(false)
end

--- The key. One press toggles.
---
--- NOTHING IN THE LOBBY (owner, 2026-08-12). The server answers with
--- `inMatch = false` for a lobby player, and this refuses to open at all rather
--- than showing an empty panel -- an empty list reads as a broken feature,
--- where nothing happening reads as a key that does not apply here.
AddEventHandler('br:ui:playersToggle', function()
    if open then hide() return end
    show()
end)

RegisterNetEvent(BR.Net.PLAYERS_LIST)
AddEventHandler(BR.Net.PLAYERS_LIST, function(payload)
    if type(payload) ~= 'table' then return end

    if not payload.inMatch then
        -- Asked from the lobby. Release the focus we optimistically took and
        -- say nothing: there is no panel to show and no error to report.
        if open then hide() end
        return
    end

    TriggerEvent('br:ui:sendLocal', BR.Nui.PLAYERS, {
        players         = payload.players or {},
        categories      = payload.categories or {},
        defaultCategory = payload.defaultCategory,
        maxTargets      = payload.maxTargets,
        remaining       = payload.remaining,
    })
end)

RegisterNetEvent(BR.Net.REPORT_RESULT)
AddEventHandler(BR.Net.REPORT_RESULT, function(res)
    if type(res) ~= 'table' then return end

    -- THE PANEL IS TOLD, AND SO IS THE PLAYER. The panel closes itself on a
    -- success; the toast is what survives the panel closing, and it is the
    -- thing that carries the actual promise -- that somebody will look.
    TriggerEvent('br:ui:sendLocal', BR.Nui.REPORT, {
        ok      = res.ok == true,
        filed   = tonumber(res.filed) or 0,
        refused = res.refused,
    })

    if res.ok then
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = (tonumber(res.filed) or 0) == 1
                and 'Report sent. An admin will review it.'
                or ('%d reports sent. An admin will review them.')
                    :format(tonumber(res.filed) or 0),
            tone = 'success', key = 'report.sent', ms = 6000,
        })
        if open then hide() end
    else
        TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
            text = tostring(res.refused or 'That report could not be sent.'),
            tone = 'warn', key = 'report.refused', ms = 6000,
        })
    end
end)

RegisterNUICallback(BR.NuiCb.PLAYERS_FOCUS, function(data, cb)
    -- `report` USED TO RIDE ALONG HERE and no longer does. The page sent it so
    -- Lua could swap focus screens for the note field; with one screen there is
    -- nothing to swap, so the page stopped sending it and this stopped reading
    -- it. A field still parsed on one side and never written on the other is
    -- how a contract quietly grows a member nobody can delete.
    apply(data ~= nil and data.open == true)
    cb({ ok = true })
end)

--- Submit. FORWARDS AND NOTHING ELSE.
---
--- The client names server ids and a category string; the server resolves the
--- licenses, checks the bucket, applies the limit and refuses anything it does
--- not like. Every rule this panel appears to enforce is enforced again there,
--- because a panel is a suggestion and a server is an authority.
---
--- The callback resolves immediately: CEF promises must always resolve, and
--- the real answer arrives as REPORT_RESULT. A page that awaited the round
--- trip would hang on a dropped message.
RegisterNUICallback(BR.NuiCb.REPORT_SUBMIT, function(data, cb)
    TriggerServerEvent(BR.Net.REPORT_SUBMIT, {
        targets = (data and data.targets) or {},
        note    = data and data.note or nil,
    })
    cb({ ok = true })
end)

-- THE PANEL CAN BE TAKEN AWAY FROM UNDER US, and until now nothing here would
-- ever find out (#121).
--
-- `open` above is this file's own boolean; the focus STACK is what actually
-- decides whether the panel is on screen. Anything that empties or replaces
-- the stack without asking -- a match ending, a br_ui restart, the focus
-- watchdog, `brfocus clear`, the frontend handover in pause.lua -- left `open`
-- still saying true. The next press of the key then tried to CLOSE a panel
-- that was already gone: nothing appeared, and the player had to press twice.
--
-- br_ui/client/pause.lua carries the scar this is copied from, where the same
-- drift also stranded a stack entry nothing would ever pop (user, 2026-08-09:
-- readied up and "was brought back to the pause menu where I could not close
-- the UI"). So this calls hide() rather than just clearing the flag -- popFocus
-- is safe on a screen that does not hold focus, and letting go of both halves
-- is the whole point.
--
-- IT IS FIXABLE IN ONE LINE ONLY BECAUSE THERE IS ONE SCREEN NOW. While report
-- mode had its own, `screen` could be `playersReport` with the panel very much
-- up, so "the top is not mine" was not the same question as "am I closed" and
-- this handler would have had to know about both. Collapsing the screens is
-- what made it trivial; #135 and #121 land together for that reason.
AddEventHandler('br:ui:focusChanged', function(screen)
    if screen ~= SCREEN and open then hide() end
end)

-- A REFRESH WHILE OPEN, because a match moves. Somebody dies, somebody leaves,
-- and a panel held open through a fight would name a roster that no longer
-- exists. Two seconds matches the snapshot cadence the rest of the interface
-- already runs at.
Citizen.CreateThread(function()
    while true do
        Citizen.Wait(2000)
        if open then TriggerServerEvent(BR.Net.PLAYERS_ASK) end
    end
end)
