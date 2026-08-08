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

local last = { w = 0, h = 0, safe = -1.0, radar = nil, ready = nil }

--- The native radar's footprint, as a fraction of screen height.
---
--- MEASURED, NOT DERIVED. GTA does not expose the radar rectangle, so these come
--- from measuring a 1080p screenshot: the minimap occupies roughly 400x210 px
--- with the default safe zone. They scale with height, which is how the engine
--- scales it. Re-measure with /brdebug if the radar ever looks wrong -- the dev
--- overlay draws this rectangle so a mismatch is visible immediately.
-- THE CANONICAL VALUES, finally researched instead of measured off
-- screenshots (glitchdetector/fivem-minimap-anchor, the community-standard
-- derivation): the radar's map area is EXACTLY screenHeight/4 wide and
-- screenHeight/5.674 tall, anchored to the safe zone's bottom-left. Two
-- rounds of screenshot-measuring produced 0.370 then 0.291; the real number
-- is 0.25, which is why the bars kept overshooting the map's right edge.
local RADAR_H_FRAC = 1.0 / 5.674   -- ~0.1763
local RADAR_W_FRAC = 0.25          -- width == height/4, aspect-independent

--- Whether the radar is currently on screen. IsRadarHidden reflects both our
--- own DisplayRadar calls and the pause map; guarded because a wrong native
--- name is nil and this must never take the metrics loop down.
local function radarVisible()
    local ok, hidden = pcall(function() return IsRadarHidden() end)
    if not ok then return true end
    return not hidden
end

local function publish()
    local w, h = GetActiveScreenResolution()
    local safe = GetSafeZoneSize()

    -- GetSafeZoneSize returns roughly 0.8..1.0, where 1.0 is no inset. Convert
    -- to a percentage inset the CSS can use directly.
    local inset = (1.0 - safe) * 0.5

    -- The minimap rectangle in VIEWPORT PERCENTAGES, so the UI can anchor our
    -- health/shield bars, the chat and the notices to the real radar wherever
    -- the player's safe-zone slider put it. Width is measured against screen
    -- HEIGHT (that is how the engine scales the radar) and converted to a
    -- width-percentage here.
    local mapW = (h > 0 and w > 0) and (RADAR_W_FRAC * h / w * 100.0) or 20.8
    local mapH = RADAR_H_FRAC * 100.0

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
        -- The radar rect: left/bottom insets match the safe zone (the engine
        -- anchors the radar to the safe zone's bottom-left corner).
        mapLeft   = inset * 100.0,
        mapBottom = inset * 100.0,
        mapW      = mapW,
        mapH      = mapH,
        radarOn   = radarVisible(),
        aspect  = (h > 0) and (w / h) or (16.0 / 9.0),
        -- Rides here rather than in its own envelope so a br_ui restart
        -- mid-session re-learns it on the next periodic publish. Owned by
        -- loading.lua; the lobby's opaque streaming backdrop keys on it.
        worldReady = BR.State.worldReady ~= false,
    })
end

--- Republish when anything changes. Resolution can change mid-session when the
--- player alt-tabs, switches monitor, or edits display settings, the safe
--- zone changes the moment they touch the calibration slider, and the radar
--- toggles with match state -- so this is polled rather than sent once.
-- SCOPES ONLY, NOT AIMING GENERALLY.
--
-- "Hide the HUD while aiming" is too broad: aiming a pistol leaves the screen
-- alone, and blanking the interface for it costs the player their health bar
-- in a fight. What actually clashes is a SCALEFORM -- the sniper scope draws a
-- full-screen overlay, and our panels sit on top of it (user, 2026-08-07:
-- "anything that doesn't display scaleforms while aiming should still have HUD
-- on, but HUD+scaleforms = bad").
--
-- Which weapons do that is a property of the weapon, so it is answered from
-- OUR table (`scoped = true`) rather than by asking the engine about camera
-- modes -- the last time this file guessed at a camera native it suspended a
-- callback and brought GTA's weapon wheel back.
--- True while a scope scaleform is up. Read by natives.lua, which owns the
--- per-frame DisplayRadar call -- see below for why that matters.
BR.Screen = BR.Screen or {}
BR.Screen.scoped = false

local scopedNow = false

BR.Loop.register(BR.Loop.TICK, 'screen.scope', function()
    local want = false

    if IsPlayerFreeAiming(PlayerId()) then
        -- ASK THE ENGINE WHAT IS IN THE HAND, not our inventory.
        --
        -- The first version read the active INVENTORY slot, which is wrong for
        -- a reason the screenshot made obvious: it only knows about weapons WE
        -- issued. A sniper equipped any other way -- vMenu, a future starting
        -- kit, anything -- left the slot empty, so the check found no weapon,
        -- decided nothing was scoped, and the HUD drew straight over the scope
        -- (user, 2026-08-08).
        --
        -- The ped is the thing actually holding a rifle, so the ped is what to
        -- ask. Our table still decides whether that weapon HAS a scope; the
        -- engine only says which weapon it is.
        local ok, hash = GetCurrentPedWeapon(PlayerPedId(), true)
        if ok then
            local w = BR.Config.WeaponByHash[BR.NormHash(hash)]
            want = (w and w.scoped) and true or false
        end
    end

    if want == scopedNow then return end
    scopedNow = want
    BR.Screen.scoped = want

    -- The radar goes with it: a minimap over a scope is the same problem.
    -- Setting it here is not enough on its own -- natives.lua re-asserts
    -- DisplayRadar every FRAME from the player's state, so a 10Hz call here
    -- would be overwritten within milliseconds. That loop reads
    -- BR.Screen.scoped for exactly this reason.
    DisplayRadar(not want)
    TriggerEvent('br:ui:sendLocal', BR.Nui.SCREEN, { scoped = want })
end)

BR.Loop.register(BR.Loop.SLOW, 'screen.metrics', function()
    local w, h = GetActiveScreenResolution()
    local safe = GetSafeZoneSize()
    local radar = radarVisible()
    local ready = BR.State.worldReady ~= false

    if w ~= last.w or h ~= last.h or math.abs(safe - last.safe) > 0.001
       or radar ~= last.radar or ready ~= last.ready then
        last.w, last.h, last.safe, last.radar, last.ready = w, h, safe, radar, ready
        publish()
    end
end)

-- THE STOCK MINIMAP HEALTH/ARMOUR BARS ARE OURS NOW. SETUP_HEALTH_ARMOUR(3)
-- on the minimap scaleform hides the built-in strip (the community-standard
-- trick every custom HUD uses); our bars render in its place, driven by the
-- same display units as the rest of the interface -- the stock bar also
-- disagreed with our numbers, because it draws the raw engine range.
-- Re-applied every pass: the game quietly restores the strip after certain
-- frontend transitions, and a once-only call came back after the pause menu.
local minimapSf = nil
BR.Loop.register(BR.Loop.SLOW, 'screen.hidebars', function()
    if not minimapSf then
        minimapSf = RequestScaleformMovie('minimap')
    end
    if minimapSf and HasScaleformMovieLoaded(minimapSf) then
        BeginScaleformMovieMethod(minimapSf, 'SETUP_HEALTH_ARMOUR')
        ScaleformMovieMethodAddParamInt(3)
        EndScaleformMovieMethod()
    end
end)

--- Re-send when the UI restarts, since it loses everything on reload.
AddEventHandler('br:ui:ready', function()
    last.w = 0   -- force the next poll to republish
    publish()
end)

--- Immediate republish on demand -- the boot choreography flips worldReady
--- and must not wait out the SLOW poll for the double fade to start.
AddEventHandler('br:screen:refresh', function()
    last.w = 0
    publish()
end)

exports('publishScreenMetrics', publish)
