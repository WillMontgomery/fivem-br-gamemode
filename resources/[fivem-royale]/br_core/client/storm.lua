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
    if BR.State.match.state ~= BR.MatchState.PLAYING then return nil end
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
local fxOn = false
local lastPush = 0
local lastComing = 0   -- the 30s SLOT last announced; 0 = fire on sight

local function clearBlips()
    if curBlip then RemoveBlip(curBlip) curBlip = nil end
    if nextBlip then RemoveBlip(nextBlip) nextBlip = nil end
    if dirBlip then RemoveBlip(dirBlip) dirBlip = nil end
    lastBlipR = -1.0
end

local function fxSet(outside)
    if outside == fxOn then return end
    fxOn = outside
    if outside then
        if cfg.fx.useTimecycle then
            SetTimecycleModifier(cfg.fx.timecycle)
            SetTimecycleModifierStrength(cfg.fx.timecycleTarget)
        end
        if cfg.fx.usePostFx then
            AnimpostfxPlay(cfg.fx.postFx, 0, true)
        end
    else
        if cfg.fx.useTimecycle then ClearTimecycleModifier() end
        if cfg.fx.usePostFx then AnimpostfxStop(cfg.fx.postFx) end
    end
end

-- REAL RAIN, tiered by depth. Weather natives are LOCAL to this client --
-- "global weather" is only a thing when a resource syncs it, and nothing on
-- this server does -- so the sky itself becomes a storm effect: RAIN just
-- past the wall, THUNDER deep outside, clear again inside. The engine's
-- overtime blend does the dramatics for free: rain builds gently over
-- blendSec, and fades the same way on the walk back in.
--
-- The ladder never touches the weather until the player is first caught
-- outside -- a match spent inside the circle keeps GTA's own sky.
local wxTier  = 'clear'   -- what the sky is currently doing
local wxWant  = 'clear'   -- what the ladder wants it to do
local wxSince = 0         -- when it first wanted that
local wxOwned = false     -- whether we have overridden the weather at all
local WX_NAME = { clear = 'EXTRASUNNY', rain = 'RAIN', thunder = 'THUNDER' }

local function weatherWant(tier)
    local wcfg = cfg.weather
    if not (wcfg and wcfg.enabled) then return end

    local now = GetGameTimer()
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
    end
end

-- NO "clear" envelope is ever sent from here. A nil payload arrives in the
-- UI as {} (the bridge's `data or {}`), which rendered as a ghost "PHASE
-- UNDEFINED / NaN" storm card during warmup. The UI clears its own storm
-- slice whenever the match state is not PLAYING -- it already receives every
-- state transition, so it needs no extra message to know.
local function teardown()
    clearBlips()
    fxSet(false)
    -- Hand the sky back to the engine between matches.
    if wxOwned then
        wxOwned = false
        wxTier, wxWant = 'clear', 'clear'
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
    local canHurt = me == BR.PlayerState.ALIVE or me == BR.PlayerState.DBNO
    local caught = edge > 0 and dps > 0 and canHurt
    fxSet(caught)

    -- The sky agrees with the vignette: rain when caught outside, thunder
    -- when deep outside, clearing on the way back in. Same condition as
    -- the screen FX so the free-loot hold stays dry everywhere.
    weatherWant(not caught and 'clear'
        or (edge > cfg.weather.deepM and 'thunder' or 'rain'))

    -- No per-phase warn toast: once the first shrink begins the storm bar
    -- is PERMANENT (user call, 2026-08-04) and a toast repeating what the
    -- timer already says was noise. The countdown notices below cover the
    -- one stretch the bar sits out -- the long phase-1 hold.

    -- The long first hold speaks through NOTICES, not a parked timer -- and
    -- always in clean half-minute amounts: "2 minutes", "1m 30s", never
    -- "2m 29s". Each notice fires when the countdown enters a new 30-second
    -- slot and names THAT slot, so the cadence lands on the dot regardless
    -- of when this client started listening. Landed players only -- the
    -- drop has its own prompts.
    --
    -- THE LAST SLOT ANNOUNCED IS 90s. The 60 slot fires anywhere in its
    -- (45s, 75s] window, while the bar appears at exactly 60s -- so "the
    -- storm is coming in 1 minute" could precede a bar reading 1:00 by
    -- fifteen silent seconds (filmed report, 2026-08-04). The bar's own
    -- arrival at 60s IS the one-minute announcement; a toast that lies
    -- about it is worse than none.
    if rec.phase == 1 and st == BR.StormPhase.HOLDING and msLeft > 60000
       and me == BR.PlayerState.ALIVE then
        local slot = math.floor((msLeft + 15000) / 30000) * 30
        if slot ~= lastComing and slot >= 90 then
            lastComing = slot
            local m, s = math.floor(slot / 60), slot % 60
            local span
            if m > 0 and s > 0 then span = ('%dm %ds'):format(m, s)
            elseif m > 1 then span = ('%d minutes'):format(m)
            elseif m == 1 then span = '1 minute'
            else span = ('%d seconds'):format(s) end
            TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
                text = ('The storm is coming in %s.'):format(span),
                tone = 'info', ms = 6000,
            })
        end
    else
        lastComing = 0
    end

    -- Blips: radius blips cannot resize in place, so refresh on a cadence --
    -- brisk while shrinking, lazy while holding, and only when the radius
    -- moved enough to see.
    local gt = GetGameTimer()
    local hz = (st == BR.StormPhase.SHRINKING)
        and cfg.blip.refreshHzShrinking or cfg.blip.refreshHzHolding
    if gt - lastBlipAt >= 1000 / hz then
        lastBlipAt = gt
        -- The CURRENT circle is not drawn while it is still the whole map
        -- (phase-1 hold): a ring around all of Los Santos on every map told
        -- players nothing. Only the purple target matters until the wall
        -- starts moving.
        local wholeMap = rec.phase == 1 and st == BR.StormPhase.HOLDING
        if wholeMap then
            if curBlip then RemoveBlip(curBlip) curBlip = nil lastBlipR = -1.0 end
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

        -- "RUN THIS WAY", on the minimap -- and only while outside. The blip
        -- sits at the NEAREST SAFE POINT on the circle (just inside the
        -- edge), long-range so it clamps to the minimap's border as a
        -- heading that rotates with the map itself. Deliberately NOT the
        -- circle's centre: the anchor is tuning data, and parking a marker
        -- on it would hand every player the storm's destination for free.
        -- Inside the circle there is nothing to point at, so no blip.
        if edge > 0 then
            local inv = 1.0 / math.max(dist, 1.0)
            local sx = cx + (p.x - cx) * inv * math.max(r - 25.0, 0.0)
            local sy = cy + (p.y - cy) * inv * math.max(r - 25.0, 0.0)
            if not dirBlip or not DoesBlipExist(dirBlip) then
                dirBlip = AddBlipForCoord(sx, sy, 0.0)
                SetBlipSprite(dirBlip, 1)
                SetBlipColour(dirBlip, cfg.blip.nextColour)
                SetBlipScale(dirBlip, 0.65)
                SetBlipAsShortRange(dirBlip, false)
            else
                SetBlipCoords(dirBlip, sx, sy, 0.0)
            end
        elseif dirBlip then
            RemoveBlip(dirBlip)
            dirBlip = nil
        end
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
