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

--- Whether the panel is currently up. Owned here because the focus stack is
--- the thing that actually knows, and asking it is one hop.
local open = false

--- Ask the server and show the panel.
local function show()
    open = true
    TriggerServerEvent(BR.Net.PLAYERS_ASK)
    TriggerEvent('br:ui:pushFocus', 'players')
end

local function hide()
    open = false
    TriggerEvent('br:ui:popFocus', 'players')
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
    if data and data.open then
        show()
    else
        hide()
    end
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
