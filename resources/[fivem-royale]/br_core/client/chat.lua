-- Client chat wiring.
--
-- Thin by design. br_core owns the keybinds, br_ui owns focus and rendering, and
-- the server owns routing. This file only connects them.

-- Keybinds registered in keybinds.lua open chat by asking br_ui, because focus
-- belongs to whichever resource owns the ui_page. br_core must never call
-- SetNuiFocus itself -- that would create a second focus owner and the two would
-- eventually disagree, which is how a player ends up unable to move.
BR.Keys.on('chatGlobal', function(pressed)
    if not pressed then return end
    TriggerEvent('br:ui:openChat', BR.ChatChannel.GLOBAL)
end)

BR.Keys.on('chatSquad', function(pressed)
    if not pressed then return end
    TriggerEvent('br:ui:openChat', BR.ChatChannel.SQUAD)
end)

-- Messages from the server go straight to the UI.
RegisterNetEvent(BR.Net.CHAT_MSG)
AddEventHandler(BR.Net.CHAT_MSG, function(msg)
    TriggerEvent('br:ui:sendLocal', BR.Nui.CHAT, msg)
end)
