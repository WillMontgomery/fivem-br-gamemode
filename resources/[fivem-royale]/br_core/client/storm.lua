-- The storm, client half: rendering and readouts. NOTHING in this file is
-- authoritative -- the wall, the blips, the vignette and the countdown are all
-- solved locally from the record the server published (BR.State.storm, via
-- STORM_SYNC or the snapshot) against the synced clock. Damage arrives in
-- state.lua, deliberately not here: every callback in this file can be
-- disabled (/brloop disable storm.wall etc.) and the player must keep taking
-- exactly the same damage -- that is the M4 authority drill.

BR = BR or {}

local cfg = BR.Config.Storm

-- ---------------------------------------------------------------- helpers ---

--- The record, gated on the one state where a storm can exist. BUS and
--- earlier have no record; ENDED keeps whatever is left but must not render
--- it under the verdict slam. And gated on MY OWN state too: a LOBBY
--- bystander shares the match.state but not the match -- they were getting
--- "storm closing" toasts at the vista menu, storm blips on their pause
--- map, and (with the distance gate gone) a purple wall on the horizon.
local function activeRecord()
    local ms = BR.State.match.state
    -- ENDED COUNTS, and that is the whole fix for the storm snapping off early.
    --
    -- The match flips to ENDED at the START of the verdict sequence, and the
    -- fade to black takes a couple of seconds after that. Tearing the storm
    -- down on the transition therefore killed the colour grade, the rain and
    -- the vignette a beat BEFORE the screen faded -- so the last thing a
    -- player saw was the weather being switched off, which reads as a bug
    -- rather than as the match ending (user, 2026-08-06).
    --
    -- CLEANUP is where it really goes away, and by then the screen is black.
    -- Damage is the server's and stopped at ENDED regardless; this is only
    -- what the client draws.
    if ms ~= BR.MatchState.PLAYING and ms ~= BR.MatchState.ENDED then
        return nil
    end
    if BR.State.me.state == BR.PlayerState.LOBBY then return nil end
    return BR.State.storm
end

--- Solve the record right now, in one place, so every consumer in this file
--- agrees on the circle down to the millisecond.
local function solveNow(rec)
    return BR.StormAt(rec, BR.Clock.now())
end

-- ------------------------------------------------------------------- wall ---

-- Ground height under the nearest wall point, cached: GetGroundZFor_3dCoord
-- (the underscore is real -- FiveM keeps it when a native name segment starts
-- with a digit) is slow and returns garbage for unloaded cells, so it is
-- sampled once per second and the previous answer is reused between samples.
local groundZ, groundAt = nil, 0

BR.Loop.register(BR.Loop.FRAME, 'storm.wall', function()
    local rec = activeRecord()
    if not rec then return end

    local cx, cy, r, stt, msLeft = solveNow(rec)
    if r <= 1.0 then return end   -- a collapsed circle has no wall to draw

    -- NO WALL BEFORE ANYTHING HAS HAPPENED. During the free-loot hold the
    -- "circle" is the whole map, and a purple ring around the horizon
    -- announced nothing but its own existence. The curtain FADES IN across
    -- the hold's last seconds, at full strength as the shrink begins.
    local alphaScale = 1.0
    if rec.phase == 1 and stt == BR.StormPhase.HOLDING then
        local fadeMs = (cfg.render.fadeInSec or 10.0) * 1000.0
        if msLeft > fadeMs then return end
        alphaScale = 1.0 - (msLeft / fadeMs)
    end

    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)

    -- FIXED SLOTS AROUND THE CIRCLE, ALWAYS DRAWN.
    --
    -- Two lessons from the first live walls, both about the same illusion:
    -- the wall must behave like a THING IN THE WORLD, not an effect around
    -- the player.
    --
    --   * Columns stand on quantized angles derived from the circle alone
    --     (slot arc length / radius). The old arc was centred on the
    --     player's own bearing, so every step the player took slid the
    --     whole colonnade around the circumference with them -- "really
    --     jarring" was the polite version.
    --   * No proximity gate. The old |dist - r| cut-off made a 300m-tall
    --     curtain pop out of existence past 300m, which read as a render
    --     bug (and got blamed on OneSync -- it never was; markers are pure
    --     local draw calls). The wall is always drawn; what scales is how
    --     much of the ring gets columns: enough arc to span the view from
    --     wherever the player is, the full ring once the circle is small.
    local rr = cfg.render
    local dist = BR.Dist(p.x, p.y, cx, cy)
    local base = math.atan(p.y - cy, p.x - cx)
    local col = rr.colour

    if BR.Storm.wallStyle == 'solid' then
        -- ONE marker: the entire zone as a single giant vertical cylinder.
        -- Its side surface IS the wall -- continuous, identical from every
        -- angle and distance, no columns to count or watch slide.
        --
        -- GLUED TO THE WORLD, NOT THE PED: a fixed base below sea level and
        -- triple height (user call, 2026-08-03), spanning ocean floor to
        -- above Chiliad. The old ground-probe fallback hung the curtain off
        -- the viewer's own z whenever the probe missed -- which at wall
        -- distances is most of the time -- so the wall rode the camera.
        --
        -- Drawn edgeInset INSIDE the logical radius: the marker's soft
        -- surface reads fatter than its scale, and the logical edge (which
        -- is what damages) must never sit inside the visible curtain.
        local vr = math.max(1.0, r - (rr.edgeInset or 0.0))
        DrawMarker(1,
            cx, cy, -100.0,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            vr * 2.0, vr * 2.0, rr.height * 3.0 + 50.0,
            col.r, col.g, col.b, math.floor(rr.alpha * alphaScale),
            false, false, 2, false, nil, nil, false)
        return
    end

    -- Column fallback keeps the per-arc ground probe: short columns must
    -- meet the terrain they stand on.
    local now = GetGameTimer()
    if now - groundAt > rr.groundCacheSec * 1000 then
        groundAt = now
        local nearX = cx + math.cos(base) * r
        local nearY = cy + math.sin(base) * r
        local okZ, gz = GetGroundZFor_3dCoord(nearX, nearY, p.z + 50.0, false)
        groundZ = okZ and gz or nil
    end
    local zBase = (groundZ or (p.z - rr.fallbackZDrop)) - 50.0

    -- Column fallback: fixed angular slots derived from the circle alone,
    -- so the colonnade stands still as the player moves.
    local slots = math.max(rr.segments,
        math.floor((2.0 * math.pi * r) / rr.slotArc + 0.5))
    local step = (2.0 * math.pi) / slots
    local w = (r * step) * (rr.overlap or 1.05)

    local visArc = math.max(rr.wallVisDist, math.abs(dist - r) * 2.0)
    local want = math.floor((visArc * 2.0) / rr.slotArc + 0.5)
    local drawn = math.min(slots, math.min(rr.maxDraw, math.max(rr.segments, want)))
    local k0 = math.floor(base / step)

    local first = k0 - math.floor(drawn / 2)
    for i = 0, drawn - 1 do
        local theta = (first + i + 0.5) * step
        DrawMarker(1,
            cx + math.cos(theta) * r, cy + math.sin(theta) * r, zBase,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            w, w, rr.height + 50.0,
            col.r, col.g, col.b, rr.alpha,
            false, false, 2, false, nil, nil, false)
    end
end)

-- Which renderer draws the wall. 'solid' is the shipping default (user call,
-- 2026-08-03); /brwallstyle flips to the column renderer live for A/B if the
-- giant-marker geometry ever misbehaves on some hardware.
BR.Storm = BR.Storm or {}
BR.Storm.wallStyle = 'solid'
RegisterCommand('brwallstyle', function()
    BR.Storm.wallStyle = BR.Storm.wallStyle == 'solid' and 'columns' or 'solid'
    print(('[br_core] storm wall style: %s'):format(BR.Storm.wallStyle))
end, false)

-- ----------------------------------------------------- blips, FX, envelope ---

local curBlip, nextBlip = nil, nil
local dirBlip = nil       -- centre marker: clamps to the minimap edge = direction home
local lastBlipAt = 0
local lastBlipR = -1.0
local lastPush = 0

local function clearBlips()
    if curBlip then RemoveBlip(curBlip) curBlip = nil end
    if nextBlip then RemoveBlip(nextBlip) nextBlip = nil end
    if dirBlip then RemoveBlip(dirBlip) dirBlip = nil end
    lastBlipR = -1.0
end

-- The screen grade RAMPS on the same clock as the weather and the NUI
-- vignette (weather.blendSec): fxLevel walks toward its target each tick
-- and drives the timecycle STRENGTH, so entering the storm darkens the
-- world over five seconds instead of snapping (user call, 2026-08-04).
local fxLevel, fxTarget = 0.0, 0.0
local fxApplied, postOn  = false, false
local lastFxAt = 0

local function fxSet(outside)
    fxTarget = outside and 1.0 or 0.0
end

local function fxStep()
    local now = GetGameTimer()
    local dt = (lastFxAt > 0) and math.min(now - lastFxAt, 500) or 0
    lastFxAt = now
    if fxLevel == fxTarget then return end

    local blend = (cfg.weather and cfg.weather.blendSec or 5.0) * 1000.0
    local step = dt / blend
    if fxLevel < fxTarget then fxLevel = math.min(fxTarget, fxLevel + step)
    else fxLevel = math.max(fxTarget, fxLevel - step) end

    if cfg.fx.useTimecycle then
        if fxLevel > 0.0 and not fxApplied then
            fxApplied = true
            SetTimecycleModifier(cfg.fx.timecycle)
        end
        if fxApplied then
            SetTimecycleModifierStrength(cfg.fx.timecycleTarget * fxLevel)
        end
        if fxLevel <= 0.0 and fxApplied then
            fxApplied = false
            ClearTimecycleModifier()
        end
    end
    -- The post FX loop has no strength knob; it joins once the grade is
    -- genuinely present and leaves as it goes.
    if cfg.fx.usePostFx then
        if fxLevel > 0.15 and not postOn then
            postOn = true
            AnimpostfxPlay(cfg.fx.postFx, 0, true)
        elseif fxLevel < 0.05 and postOn then
            postOn = false
            AnimpostfxStop(cfg.fx.postFx)
        end
    end
end

-- REAL WEATHER. Weather natives are LOCAL to this client -- "global
-- weather" is only a thing when a resource syncs it, and nothing on this
-- server does -- so the sky itself becomes a storm effect: full THUNDER
-- when caught outside (no gentle-rain tier -- user call, 2026-08-04),
-- clear again inside. The engine's overtime blend does the build and the
-- fade over blendSec; the NUI vignette fades on the same clock.
--
-- The ladder never touches the weather until the player is first caught
-- outside -- a match spent inside the circle keeps GTA's own sky.
local wxTier  = 'clear'   -- what the sky is currently doing
local wxWant  = 'clear'   -- what the ladder wants it to do
local wxSince = 0         -- when it first wanted that
local wxOwned = false     -- whether we have overridden the weather at all
local wxDryAt = nil       -- when to force the ground dry after clearing
local wxUndryAt = nil     -- when to hand rain control back to the engine
local WX_NAME = { clear = 'EXTRASUNNY', thunder = 'THUNDER' }

local function weatherWant(tier)
    local wcfg = cfg.weather
    if not (wcfg and wcfg.enabled) then return end

    local now = GetGameTimer()

    -- THE DRYING SCHEDULE. Forcing sunny stops the rain, but the ground
    -- keeps its sheen and puddles for minutes -- SetRainLevel(0.0) kills
    -- rain, rain audio AND puddle creation outright (its documented job),
    -- so once the blend back to clear finishes, the world dries. Control
    -- is handed back (-1.0) a while later so the engine's own weather can
    -- rain again some day.
    if wxDryAt and now >= wxDryAt then
        wxDryAt = nil
        -- The blend has finished, so the snap is visually a no-op -- but it
        -- HARD-RESETS the weather system's internal rain memory, which the
        -- overtime path preserves and which is what kept the ground shiny
        -- long after the sky cleared (live report, 2026-08-04).
        SetWeatherTypeNowPersist(WX_NAME.clear)
        SetRainLevel(0.0)
        wxUndryAt = now + 45000
    end
    if wxUndryAt and now >= wxUndryAt then
        wxUndryAt = nil
        SetRainLevel(-1.0)
    end

    if tier ~= wxWant then
        wxWant, wxSince = tier, now
        return
    end
    -- Hysteresis: a player strafing the wall must not strobe the sky.
    if tier ~= wxTier and now - wxSince >= (wcfg.holdMs or 2000) then
        wxTier = tier
        if not wxOwned and tier == 'clear' then return end
        wxOwned = true
        SetWeatherTypeOvertimePersist(WX_NAME[tier], wcfg.blendSec + 0.0)
        if tier == 'thunder' then
            -- Let the thunderstorm actually rain, whatever the dry
            -- schedule was up to.
            wxDryAt, wxUndryAt = nil, nil
            SetRainLevel(-1.0)
        else
            wxDryAt = now + wcfg.blendSec * 1000.0
        end
    end
end

-- NO "clear" envelope is ever sent from here. A nil payload arrives in the
-- UI as {} (the bridge's `data or {}`), which rendered as a ghost "PHASE
-- UNDEFINED / NaN" storm card during warmup. The UI clears its own storm
-- slice whenever the match state is not PLAYING -- it already receives every
-- state transition, so it needs no extra message to know.
local function teardown()
    clearBlips()
    -- Between matches the grade SNAPS off -- there is nothing to fade
    -- against once the world resets around a teleport home.
    fxTarget, fxLevel = 0.0, 0.0
    if fxApplied then fxApplied = false ClearTimecycleModifier() end
    if postOn then postOn = false AnimpostfxStop(cfg.fx.postFx) end
    -- Hand the sky back to the engine between matches.
    if wxOwned then
        wxOwned = false
        wxTier, wxWant = 'clear', 'clear'
        wxDryAt, wxUndryAt = nil, nil
        SetRainLevel(-1.0)
        ClearWeatherTypePersist()
    end
end

BR.Loop.register(BR.Loop.TICK, 'storm.state', function()
    local rec = activeRecord()
    if not rec then
        teardown()
        return
    end

    local now = BR.Clock.now()
    local cx, cy, r, st, msLeft, dps = solveNow(rec)

    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)
    local dist = BR.Dist(p.x, p.y, cx, cy)
    local edge = dist - r   -- positive = outside

    -- Screen FX track being outside AND the storm actually hurting right now
    -- (dps is 0 for everyone during the phase-1 free-loot hold -- the solver
    -- decides that, so this cannot disagree with the server's damage tick),
    -- and only while we can be hurt at all -- a spectator ghosting through
    -- the wall does not need a red screen.
    local me = BR.State.me.state
    -- DEAD is included: a corpse in the storm is still IN the storm, and
    -- the rain and grade stopping at the moment of death read as a bug
    -- (live report, 2026-08-04 -- this becomes the DBNO view later).
    -- Spectate will re-gate this when it exists.
    local affected = me == BR.PlayerState.ALIVE
        or me == BR.PlayerState.DBNO
        or me == BR.PlayerState.DEAD
    local caught = edge > 0 and dps > 0 and affected
    fxSet(caught)
    fxStep()

    -- The sky agrees with the vignette: thunder when caught outside,
    -- clearing on the way back in. Same condition as the screen FX so the
    -- free-loot hold stays dry everywhere.
    weatherWant(caught and 'thunder' or 'clear')

    -- NO STORM TOASTS AT ALL (user call, 2026-08-05). This used to announce
    -- the approach every thirty seconds through the phase-1 hold, because the
    -- bar was hidden for that stretch and the wait needed a voice. The bar is
    -- permanent now, from the first storm record onward, so the toasts were
    -- a second clock -- coarser than the first, occasionally disagreeing with
    -- it, and interrupting the one activity the hold exists for. The
    -- countdown IS the announcement.

    -- Blips: radius blips cannot resize in place, so refresh on a cadence --
    -- brisk while shrinking, lazy while holding, and only when the radius
    -- moved enough to see.
    local gt = GetGameTimer()
    -- The blip fade window shares the wall's fade clock: the map ring and
    -- the 3D curtain arrive together (user call, 2026-08-04).
    local fadeMs  = (cfg.render.fadeInSec or 10.0) * 1000.0
    local wholeMap = rec.phase == 1 and st == BR.StormPhase.HOLDING
    local fading   = wholeMap and msLeft <= fadeMs
    local hz = (st == BR.StormPhase.SHRINKING or fading)
        and cfg.blip.refreshHzShrinking or cfg.blip.refreshHzHolding
    if gt - lastBlipAt >= 1000 / hz then
        lastBlipAt = gt
        -- The CURRENT circle is not drawn while it is still the whole map
        -- (phase-1 hold): a ring around all of Los Santos on every map told
        -- players nothing... until the wall starts fading in, when its map
        -- ring fades in WITH it -- alpha ramped on the same countdown the
        -- curtain uses, so neither pops.
        if wholeMap then
            if fading then
                local a = math.floor(cfg.blip.currentAlpha
                    * (1.0 - msLeft / fadeMs) + 0.5)
                curBlip = BR.Native.radiusBlip(curBlip, cx, cy, r,
                    cfg.blip.currentColour, a)
                lastBlipR = r
                if nextBlip then RemoveBlip(nextBlip) nextBlip = nil end
            elseif curBlip then
                RemoveBlip(curBlip) curBlip = nil lastBlipR = -1.0
            end
        elseif math.abs(r - lastBlipR) > 1.0 or not curBlip then
            lastBlipR = r
            curBlip = BR.Native.radiusBlip(curBlip, cx, cy, r,
                cfg.blip.currentColour, cfg.blip.currentAlpha)
            -- REBUILT TOGETHER, ALWAYS IN THIS ORDER. The target ring used to
            -- be created once and left alone -- so every current-circle
            -- rebuild landed ON TOP of it, then the next phase put it back on
            -- top, and the purple ring read as flashing on the map. Blips
            -- draw in creation order; recreating both keeps purple above.
            if nextBlip then RemoveBlip(nextBlip) nextBlip = nil end
        end
        if not nextBlip and rec.r1 > 1.0 then
            nextBlip = BR.Native.radiusBlip(nil, rec.cx1, rec.cy1, rec.r1,
                cfg.blip.nextColour, cfg.blip.nextAlpha)
        end

    end

    -- "RUN THIS WAY", on the minimap -- whenever outside the PURPLE
    -- TARGET circle, not just the current wall (user call, 2026-08-04:
    -- during the whole phase-1 hold "outside the current circle" is
    -- impossible -- it is the entire map -- but outside the target is
    -- exactly when guidance matters). The blip sits at the NEAREST
    -- SAFE POINT just inside the target's edge, long-range so it
    -- clamps to the minimap's border as a heading that rotates with
    -- the map. Deliberately NOT the centre: the anchor is tuning
    -- data, and parking a marker on it would hand every player the
    -- storm's destination for free.
    --
    -- EVERY TICK, not on the blip refresh cadence (user call,
    -- 2026-08-04): the arrow's rotation must track the player's own
    -- movement smoothly, and re-asserting existence at 10Hz means
    -- anything that eats the handle (a live "no blip at all in squads"
    -- report -- engine blip handles are recycled, so another system
    -- removing a stale handle can delete ours) heals within 100ms
    -- instead of a refresh period.
    local tx, ty, tr = rec.cx1, rec.cy1, rec.r1
    local distT = BR.Dist(p.x, p.y, tx, ty)
    if distT > tr then
        local inv = 1.0 / math.max(distT, 1.0)
        local sx = tx + (p.x - tx) * inv * math.max(tr - 25.0, 0.0)
        local sy = ty + (p.y - ty) * inv * math.max(tr - 25.0, 0.0)
        -- AN ARROW THAT POINTS AT THE CIRCLE (user call, 2026-08-04,
        -- overturning the earlier "no rotatable arrow" finding): sprite
        -- 11 is a directional arrow per the FiveM blip reference, and
        -- SetBlipRotation aims it. The bearing is player -> target
        -- centre. 2x scale, and NO SetBlipFlashes -- the sprite blinks
        -- on its own, and stacking our flash on top of that left it
        -- invisible half the time (both user calls, 2026-08-04).
        local rot = math.floor(
            BR.GtaHeading(BR.Bearing(p.x, p.y, tx, ty)) + 0.5) % 360
        if not dirBlip or not DoesBlipExist(dirBlip) then
            dirBlip = AddBlipForCoord(sx, sy, 0.0)
            SetBlipSprite(dirBlip, 11)
            SetBlipColour(dirBlip, cfg.blip.nextColour)
            SetBlipScale(dirBlip, 2.0)
            SetBlipAsShortRange(dirBlip, false)
        else
            SetBlipCoords(dirBlip, sx, sy, 0.0)
        end
        SetBlipRotation(dirBlip, rot)
    elseif dirBlip then
        RemoveBlip(dirBlip)
        dirBlip = nil
    end

    -- The HUD envelope, at ~4Hz. The countdown is NOT ticked here -- endsAt
    -- is a server timestamp and the UI derives the digits locally, same as
    -- the warmup timer.
    if gt - lastPush >= 250 then
        lastPush = gt
        local endsAt = 0
        if st == BR.StormPhase.PRE or st == BR.StormPhase.HOLDING then
            endsAt = rec.tStart + rec.tWait
        elseif st == BR.StormPhase.SHRINKING then
            endsAt = rec.tStart + rec.tWait + rec.tShrink
        end
        TriggerEvent('br:ui:sendLocal', BR.Nui.STORM, {
            phase        = rec.phase,
            phaseState   = st,
            endsAt       = endsAt,
            radius       = r,
            edgeDistance = edge,
            -- Toward the CENTRE when outside -- the way to run.
            bearing      = BR.Bearing(p.x, p.y, cx, cy),
            dps          = dps,
        })
    end
end)

-- A new record means the "next circle" moved: force the blips to rebuild so
-- the old target ring never lingers on the map.
AddEventHandler(BR.Net.STORM_SYNC, function()
    clearBlips()
    lastBlipAt = 0
end)

AddEventHandler('onResourceStop', function(res)
    if res ~= GetCurrentResourceName() then return end
    teardown()
end)
