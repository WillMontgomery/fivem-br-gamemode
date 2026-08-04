-- Client chat wiring.
--
-- Thin by design. br_core owns the keybinds, br_ui owns focus and rendering, and
-- the server owns routing. This file only connects them.

-- Keybinds registered in keybinds.lua open chat by asking br_ui, because focus
-- belongs to whichever resource owns the ui_page. br_core must never call
-- SetNuiFocus itself -- that would create a second focus owner and the two would
-- eventually disagree, which is how a player ends up unable to move.
--- Do I have a squad (or persistent party) to talk to? Squad chat with
--- nobody on the other end is a channel to nowhere; solos never see it.
local function hasSquad()
    return BR.State.me.squadId ~= nil or BR.State.me.partyId ~= nil
end

-- The MAIN chat key defaults to the people you are playing WITH: squad when
-- you have one, everyone when you do not.
BR.Keys.on('chatGlobal', function(pressed)
    if not pressed then return end
    TriggerEvent('br:ui:openChat',
        hasSquad() and BR.ChatChannel.SQUAD or BR.ChatChannel.GLOBAL)
end)

-- The dedicated squad key is a no-op without a squad rather than silently
-- opening global -- pressing "talk to my squad" and reaching the whole
-- server would be worse than nothing happening.
BR.Keys.on('chatSquad', function(pressed)
    if not pressed then return end
    if not hasSquad() then return end
    TriggerEvent('br:ui:openChat', BR.ChatChannel.SQUAD)
end)

-- Messages from the server go straight to the UI.
RegisterNetEvent(BR.Net.CHAT_MSG)
AddEventHandler(BR.Net.CHAT_MSG, function(msg)
    TriggerEvent('br:ui:sendLocal', BR.Nui.CHAT, msg)
end)
