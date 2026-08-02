-- Screen metrics.
--
-- Players run at 1080p, 1440p, 4K, on ultrawide and on 16:10. Rather than the
-- UI guessing where the edges are, the game is asked directly.
--
-- GTA maintains its own "safe zone" -- an inset from the screen edges that the
-- player can adjust in Settings > Display, and which the engine varies with
-- aspect ratio. Every vanilla HUD element respects it. Reading it and handing it
-- to the UI means our HUD sits exactly where the player expects their interface
-- to sit, on any display, including the ultrawide cases we cannot otherwise
-- reason about.

local last = { w = 0, h = 0, safe = -1.0 }

--- The native radar's footprint, as a fraction of screen height.
---
--- MEASURED, NOT DERIVED. GTA does not expose the radar rectangle, so these come
--- from measuring a 1080p screenshot: the minimap occupies roughly 400x210 px
--- with the default safe zone. They scale with height, which is how the engine
--- scales it. Re-measure with /brdebug if the radar ever looks wrong -- the dev
--- overlay draws this rectangle so a mismatch is visible immediately.
local RADAR_H_FRAC = 0.195   -- ~210 / 1080
local RADAR_W_FRAC = 0.370   -- ~400 / 1080, expressed against HEIGHT so the
                             -- aspect of the radar itself stays correct

local function publish()
    local w, h = GetActiveScreenResolution()
    local safe = GetSafeZoneSize()

    -- GetSafeZoneSize returns roughly 0.8..1.0, where 1.0 is no inset. Convert
    -- to a percentage inset the CSS can use directly.
    local inset = (1.0 - safe) * 0.5

    TriggerEvent('br:ui:sendLocal', BR.Nui.SCREEN, {
        width   = w,
        height  = h,
        -- Percentages, because the UI positions with them.
        safeX   = inset * 100.0,
        safeY   = inset * 100.0,
        -- rem, where 1rem is 1.481vh -- matching the root scale in index.css, so
        -- the radar box scales with the rest of the interface.
        radarW  = (RADAR_W_FRAC * 100.0) / 1.481,
        radarH  = (RADAR_H_FRAC * 100.0) / 1.481,
        aspect  = (h > 0) and (w / h) or (16.0 / 9.0),
    })
end

--- Republish when anything changes. Resolution can change mid-session when the
--- player alt-tabs, switches monitor, or edits display settings, and the safe
--- zone changes the moment they touch the calibration slider -- so this is
--- polled rather than sent once at start.
BR.Loop.register(BR.Loop.SLOW, 'screen.metrics', function()
    local w, h = GetActiveScreenResolution()
    local safe = GetSafeZoneSize()

    if w ~= last.w or h ~= last.h or math.abs(safe - last.safe) > 0.001 then
        last.w, last.h, last.safe = w, h, safe
        publish()
    end
end)

--- Re-send when the UI restarts, since it loses everything on reload.
AddEventHandler('br:ui:ready', function()
    last.w = 0   -- force the next poll to republish
    publish()
end)

exports('publishScreenMetrics', publish)
