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
--- it under the verdict slam.
local function activeRecord()
    if BR.State.match.state ~= BR.MatchState.PLAYING then return nil end
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

    local cx, cy, r = solveNow(rec)
    if r <= 1.0 then return end   -- a collapsed circle has no wall to draw

    local ped = PlayerPedId()
    local p = GetEntityCoords(ped)

    -- Only draw when the EDGE is near. The wall is a 300m purple curtain;
    -- from four kilometres inside the circle it would be invisible anyway,
    -- and 40 markers a frame are only affordable because of this gate.
    local dist = BR.Dist(p.x, p.y, cx, cy)
    if math.abs(dist - r) > cfg.render.wallRenderDist then return end

    -- The arc nearest the player: segments spread over spanDeg centred on
    -- the bearing from the circle's centre through the player.
    local base = math.atan(p.y - cy, p.x - cx)
    local span = math.rad(cfg.render.spanDeg)
    local segs = cfg.render.segments
    local step = span / (segs - 1)

    -- Segment width: the chord each marker must cover, padded slightly so
    -- neighbours meet. (They must MEET, not overlap -- overlapping additive
    -- alpha renders as banding, which is why alpha rides config.)
    local w = (r * step) * 1.15

    local now = GetGameTimer()
    if now - groundAt > cfg.render.groundCacheSec * 1000 then
        groundAt = now
        local nearX = cx + math.cos(base) * r
        local nearY = cy + math.sin(base) * r
        local okZ, gz = GetGroundZFor_3dCoord(nearX, nearY, p.z + 50.0, false)
        groundZ = okZ and gz or nil
    end
    -- Anchor the curtain well below the ground line so slopes never show a
    -- gap under it; without a ground answer, hang it off the player's own z.
    local zBase = (groundZ or (p.z - cfg.render.fallbackZDrop)) - 50.0

    local col = cfg.render.colour
    for i = 0, segs - 1 do
        local theta = base - span * 0.5 + step * i
        DrawMarker(1,
            cx + math.cos(theta) * r, cy + math.sin(theta) * r, zBase,
            0.0, 0.0, 0.0, 0.0, 0.0, 0.0,
            w, w, cfg.render.height + 50.0,
            col.r, col.g, col.b, cfg.render.alpha,
            false, false, 2, false, nil, nil, false)
    end
end)

-- ----------------------------------------------------- blips, FX, envelope ---

local curBlip, nextBlip = nil, nil
local lastBlipAt = 0
local lastBlipR = -1.0
local fxOn = false
local warnedPhase = nil
local lastPush = 0

local function clearBlips()
    if curBlip then RemoveBlip(curBlip) curBlip = nil end
    if nextBlip then RemoveBlip(nextBlip) nextBlip = nil end
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

-- NO "clear" envelope is ever sent from here. A nil payload arrives in the
-- UI as {} (the bridge's `data or {}`), which rendered as a ghost "PHASE
-- UNDEFINED / NaN" storm card during warmup. The UI clears its own storm
-- slice whenever the match state is not PLAYING -- it already receives every
-- state transition, so it needs no extra message to know.
local function teardown()
    clearBlips()
    fxSet(false)
end

BR.Loop.register(BR.Loop.TICK, 'storm.state', function()
    local rec = activeRecord()
    if not rec then
        teardown()
        warnedPhase = nil
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
    fxSet(edge > 0 and dps > 0 and canHurt)

    -- "Storm closing in 30s" -- once per phase, at the authored warn time.
    if st == BR.StormPhase.HOLDING or st == BR.StormPhase.PRE then
        local phase = cfg.phases[rec.phase]
        if phase and warnedPhase ~= rec.phase
           and msLeft <= (phase.warn or 30) * 1000 then
            warnedPhase = rec.phase
            TriggerEvent('br:ui:sendLocal', BR.Nui.TOAST, {
                text = ('Storm closing in %ds.'):format(math.ceil(msLeft / 1000)),
                tone = 'warn',
            })
        end
    end

    -- Blips: radius blips cannot resize in place, so refresh on a cadence --
    -- brisk while shrinking, lazy while holding, and only when the radius
    -- moved enough to see.
    local gt = GetGameTimer()
    local hz = (st == BR.StormPhase.SHRINKING)
        and cfg.blip.refreshHzShrinking or cfg.blip.refreshHzHolding
    if gt - lastBlipAt >= 1000 / hz then
        lastBlipAt = gt
        if math.abs(r - lastBlipR) > 1.0 or not curBlip then
            lastBlipR = r
            curBlip = BR.Native.radiusBlip(curBlip, cx, cy, r,
                cfg.blip.currentColour, cfg.blip.currentAlpha)
        end
        -- The next circle is static for the whole record; draw it once.
        if not nextBlip and rec.r1 > 1.0 then
            nextBlip = BR.Native.radiusBlip(nil, rec.cx1, rec.cy1, rec.r1,
                cfg.blip.nextColour, cfg.blip.nextAlpha)
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
