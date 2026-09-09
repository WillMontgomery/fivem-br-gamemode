local overlayID = -1
RegisterNetEvent("ScUI:AddMinimapOverlay")
AddEventHandler("ScUI:AddMinimapOverlay", function(cb)
    if overlayID == -1 then
        overlayID = AddMinimapOverlay("files/MINIMAP_LOADER.gfx")
        -- BR-PATCH 1: removed a bare, unconditional print(overlayID). It put a raw
        -- number with no label into every player's F8 console at start, with no way
        -- to turn it off. Same fault, same fix, as pma-voice's BR-PATCH 1 -- except
        -- there was no logger here to route it through, and the handle is already
        -- returned to the caller through cb, so the line is simply gone.
    end
    cb(overlayID)
end)

-- BR-PATCH 2: added the missing `cb` parameter. This body is a copy of the event
-- handler above, which takes a callback, but the export was declared with no
-- parameters at all -- so cb(overlayID) reached for a global named cb that has
-- never existed and calling this export died with "attempt to call a nil value".
-- One word restores the contract the body was already written for. Nothing we
-- ship calls it; ScaleformUI_Lua uses the event, not the export.
exports('AddMinimapOverlay', function(cb)
    if overlayID == -1 then
        overlayID = AddMinimapOverlay("files/MINIMAP_LOADER.gfx")
    end
    cb(overlayID)
end)