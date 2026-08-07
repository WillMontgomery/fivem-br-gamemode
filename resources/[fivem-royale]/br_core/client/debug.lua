-- Client debug tooling.
--
-- Commands print to the F8 console; the overlay draws on screen. The overlay is
-- registered into the normal FRAME band like any other subsystem -- it does not
-- get its own thread, and when it is off it costs one boolean check per frame.
--
-- The most important command here is brnativecheck. Every assumption this project
-- makes about a native is written down in client/natives.lua, and this is what
-- turns those assumptions into observations.

local overlay = {
    enabled = false,
    page    = 'perf',   -- perf | state | keys
}

-- ------------------------------------------------------------------ drawing ---

local function text(x, y, s, scale, r, g, b)
    SetTextFont(4)
    SetTextScale(0.0, scale or 0.32)
    SetTextColour(r or 255, g or 255, b or 255, 235)
    SetTextDropshadow(0, 0, 0, 0, 255)
    SetTextEdge(1, 0, 0, 0, 205)
    SetTextDropShadow()
    SetTextOutline()
    BeginTextCommandDisplayText('STRING')
    AddTextComponentSubstringPlayerName(s)
    EndTextCommandDisplayText(x, y)
end

local function drawPerf(y)
    local bands = BR.Loop.bandStats()
    text(0.012, y, '~b~BAND (wall clock, trustworthy)', 0.30) y = y + 0.018
    for _, band in ipairs({ BR.Loop.FRAME, BR.Loop.TICK, BR.Loop.SLOW }) do
        local b = bands[band]
        if b then
            text(0.012, y, ('  %-6s %6d passes  avg %.2fms  peak %dms')
                :format(band, b.passes, b.avgMs, b.peakMs), 0.28)
            y = y + 0.016
        end
    end

    y = y + 0.006
    text(0.012, y, '~b~CALLBACK (relative share -- see natives.lua on timing)', 0.30)
    y = y + 0.018

    local stats = BR.Loop.stats()
    for i = 1, math.min(#stats, 14) do
        local s = stats[i]
        local r, g, b = 255, 255, 255
        if s.suspended then r, g, b = 255, 90, 90
        elseif not s.enabled then r, g, b = 140, 140, 140
        elseif s.peakMs > 1.0 then r, g, b = 255, 200, 90 end

        text(0.012, y, ('  %-22s %-5s %6d  avg %.3f  peak %.3f%s')
            :format(s.name, s.band, s.calls, s.avgMs, s.peakMs,
                    s.errors > 0 and ('  err ' .. s.errors) or ''), 0.28, r, g, b)
        y = y + 0.015
    end
    return y
end

local function drawState(y)
    local S = BR.State
    text(0.012, y, '~b~MATCH', 0.30) y = y + 0.018
    text(0.012, y, ('  state %s   mode %s   alive %d   squads %d')
        :format(S.match.state, tostring(S.match.mode), S.alive, S.squadsAlive), 0.28)
    y = y + 0.016
    text(0.012, y, ('  ends in %.1fs   clock %s (offset %.0fms)')
        :format(BR.Clock.remaining(S.match.endsAt) / 1000.0,
                BR.Clock.synced and 'synced' or '~y~UNSYNCED~w~', BR.Clock.offset), 0.28)
    y = y + 0.02

    text(0.012, y, '~b~ME', 0.30) y = y + 0.018
    text(0.012, y, ('  src %d   state %s   squad %s')
        :format(S.me.src, S.me.state, tostring(S.me.squadId or '-')), 0.28)
    y = y + 0.016
    text(0.012, y, ('  hp %.0f   armour %.0f   engine hp %d')
        :format(S.me.hp, S.me.armour, GetEntityHealth(PlayerPedId())), 0.28)
    y = y + 0.016

    local p = GetEntityCoords(PlayerPedId())
    local poi = BR.Config.Map.NearestPOI(p.x, p.y)
    text(0.012, y, ('  pos %.0f, %.0f, %.0f   near %s')
        :format(p.x, p.y, p.z, poi and poi.name or '-'), 0.28)
    y = y + 0.02

    text(0.012, y, '~b~STORM', 0.30) y = y + 0.018
    if S.storm then
        local cx, cy, r, st, left = BR.StormAt(S.storm, BR.Clock.now())
        local d = BR.EdgeDistance(p.x, p.y, cx, cy, r)
        text(0.012, y, ('  phase %d  %s  %.1fs'):format(S.storm.phase, st, left / 1000.0), 0.28)
        y = y + 0.016
        text(0.012, y, ('  centre %.0f, %.0f   radius %.0f'):format(cx, cy, r), 0.28)
        y = y + 0.016
        text(0.012, y, ('  you are %.0fm %s'):format(math.abs(d), d > 0 and '~r~OUTSIDE~w~' or 'inside'), 0.28)
        y = y + 0.016
    else
        text(0.012, y, '  no storm record', 0.28) y = y + 0.016
    end
    return y
end

local function drawKeys(y)
    text(0.012, y, '~b~KEY ACTIONS (rebind in Pause > Settings > Key Bindings)', 0.30)
    y = y + 0.018
    for _, a in ipairs(BR.Keys.actions or {}) do
        local held = BR.Keys.isHeld(a)
        text(0.012, y, ('  %-14s %s'):format(a, held and '~g~HELD' or '~w~-'), 0.28)
        y = y + 0.015
    end
    return y
end

BR.Loop.register(BR.Loop.FRAME, 'debug.overlay', function()
    if not overlay.enabled then return end

    DrawRect(0.16, 0.5, 0.32, 0.96, 0, 0, 0, 140)
    local y = 0.035
    text(0.012, y, ('~y~FiveM Royale debug  [%s]  /brdebug next'):format(overlay.page), 0.34)
    y = y + 0.024

    if overlay.page == 'perf'  then drawPerf(y)
    elseif overlay.page == 'state' then drawState(y)
    else drawKeys(y) end
end)

-- ---------------------------------------------------------------- commands ---

RegisterCommand('brdebug', function(_, args)
    local pages = { 'perf', 'state', 'keys' }
    if args[1] == 'off' then
        overlay.enabled = false
        print('[br_core] overlay off')
        return
    end
    if args[1] and args[1] ~= 'on' then
        overlay.page, overlay.enabled = args[1], true
    elseif not overlay.enabled then
        overlay.enabled = true
    else
        -- cycle pages, then switch off after the last one
        local i = 1
        for n, p in ipairs(pages) do if p == overlay.page then i = n end end
        if i >= #pages then
            overlay.enabled = false
        else
            overlay.page = pages[i + 1]
        end
    end
    print(('[br_core] overlay %s (page %s)')
        :format(overlay.enabled and 'on' or 'off', overlay.page))
end, false)

RegisterCommand('brperf', function(_, args)
    if args[1] == 'reset' then
        BR.Loop.resetStats()
        print('[br_core] client loop stats reset')
        return
    end

    print('--- band totals (wall clock) ---')
    for band, b in pairs(BR.Loop.bandStats()) do
        print(('  %-6s passes %-7d avg %.3fms  peak %dms')
            :format(band, b.passes, b.avgMs, b.peakMs))
    end
    print('--- callbacks (relative share) ---')
    for _, s in ipairs(BR.Loop.stats()) do
        print(('  %-24s %-5s calls %-7d avg %.4fms peak %.4fms%s%s')
            :format(s.name, s.band, s.calls, s.avgMs, s.peakMs,
                    s.errors > 0 and ('  errors ' .. s.errors) or '',
                    s.suspended and '  SUSPENDED' or (s.enabled and '' or '  disabled')))
    end
end, false)

--- The hitch hunter.
---
---   /brhitch          read the frame-time distribution
---   /brhitch reset    start a fresh window
---
--- An average cannot find a hitch. A 40ms stall once every few seconds moves
--- the average by a rounding error and is the only thing the player notices,
--- so this reports the DISTRIBUTION and the tail instead -- and names the
--- callbacks that were expensive on the worst frame.
---
--- READ IT IN THIS ORDER:
---   1. If almost everything is in the <17ms bucket and the worst frame is
---      under ~34ms, the client is fine and the "hitch" is elsewhere.
---   2. If the tail buckets have counts but the br_core band totals are tiny,
---      the stall is NOT ours -- another resource, streaming, or the engine.
---   3. Only if a br_core callback shows up in "worst frame by callback" with
---      a real number is it ours, and then /brloop off <name> proves it in one
---      step: turn it off, play, and look again.
RegisterCommand('brhitch', function(_, args)
    if args[1] == 'reset' then
        BR.Loop.resetStats()
        print('[br_core] perf window reset -- play for 30s, then /brhitch')
        return
    end

    local f = BR.Loop.frameStats()
    if f.samples < 60 then
        print('[br_core] only ' .. f.samples .. ' frames sampled. Let it run a few seconds.')
        return
    end

    print('--- frame time distribution (' .. f.samples .. ' frames) ---')
    local prev = 0
    for _, b in ipairs(f.buckets) do
        local pct = 100.0 * b.count / math.max(1, f.samples)
        local label = b.upTo and ('%3d-%3dms'):format(prev, b.upTo)
                             or  ('   >%3dms'):format(prev)
        -- A bar, because a column of numbers hides the shape that matters.
        local bar = string.rep('#', math.floor(pct / 2.0 + 0.5))
        print(('  %s  %6d  %5.1f%%  %s'):format(label, b.count, pct, bar))
        prev = b.upTo or prev
    end
    print(('  worst frame: %dms'):format(f.worstMs))

    if f.worstBy and #f.worstBy > 0 then
        print('--- worst frame, by callback ---')
        for i = 1, math.min(5, #f.worstBy) do
            local e = f.worstBy[i]
            print(('  %-24s %-5s %dms'):format(e.name, e.band, e.ms))
        end
    else
        print('  no br_core callback measured above 0ms on the worst frame')
        print('  -> the stall was very likely NOT br_core. Check other')
        print('     resources, asset streaming, or the engine itself.')
    end

    print('--- band totals ---')
    for band, b in pairs(BR.Loop.bandStats()) do
        print(('  %-6s passes %-7d avg %.3fms  peak %dms')
            :format(band, b.passes, b.avgMs, b.peakMs))
    end
    print('  (then: /brperf for per-callback totals, /brloop off <name> to bisect)')
end, false)

RegisterCommand('brloop', function(_, args)
    local action, name = args[1], args[2]
    if not action or not name then
        print('  usage: brloop <on|off> <callbackName>   (see brperf for names)')
        return
    end
    local enable = (action == 'on' or action == 'enable')
    if BR.Loop.setEnabled(name, enable) then
        print(('[br_core] callback "%s" %s'):format(name, enable and 'enabled' or 'disabled'))
    else
        print(('[br_core] no such callback: %s'):format(name))
    end
end, false)

--- Audition a frontend sound pair, so the loot sounds can be chosen by ear
--- rather than by guessing at soundset names.
---   /brsound HUD_MINI_GAME_SOUNDSET CHECKPOINT_PERFECT
RegisterCommand('brsound', function(_, args)
    local set, name = args[1], args[2]
    if not set or not name then
        print('  usage: brsound <soundSet> <soundName>')
        print(('  loot open:   %s / %s'):format(
            BR.Config.Loot.openSound.set, BR.Config.Loot.openSound.name))
        print(('  loot pickup: %s / %s'):format(
            BR.Config.Loot.pickupSound.set, BR.Config.Loot.pickupSound.name))
        return
    end
    PlaySoundFrontend(-1, name, set, true)
    print(('[br_core] played %s / %s'):format(set, name))
end, false)

RegisterCommand('brnativecheck', function()
    print('==============================================================')
    print('  native check -- assumptions vs this build')
    print('==============================================================')
    local results = BR.Native.check()
    local failed = 0
    for _, r in ipairs(results) do
        if r.ok then
            print(('  [ ok ] %-32s %s'):format(r.name, r.detail))
        else
            failed = failed + 1
            print(('  [FAIL] %-32s %s'):format(r.name, r.detail))
        end
    end
    print('--------------------------------------------------------------')
    print(('  %d checked, %d failed'):format(#results, failed))
    if failed > 0 then
        print('  A failure here means client/natives.lua needs its fallback path,')
        print('  not that the calling code should work around it locally.')
    end
end, false)

--- Set our own armour, so the shield HUD can be validated before any shield
--- consumable exists (M5). Dev tool only: the server's ledger will reconcile
--- this away once server-authoritative health lands in M6 -- which is exactly
--- the behaviour that milestone will want to see demonstrated.
RegisterCommand('brshield', function(_, args)
    local amount = math.floor(tonumber(args[1] or 50) or 50)
    amount = math.max(0, math.min(BR.Config.Match.maxArmour, amount))
    SetPedArmour(PlayerPedId(), amount)
    print(('[br_core] armour set to %d (dev only -- M6 reconciliation will own this)')
        :format(amount))
end, false)

RegisterCommand('brfx', function(_, args)
    -- postFX names are the likeliest thing to differ between builds, so they get
    -- auditioned in-game rather than guessed at.
    local name = args[1]
    if not name then
        print('  usage: brfx <effectName> | brfx stop')
        print('  try:   DeathFailOut, ChopVision, DrugsMichaelAliensFightIn, RaceTurbo')
        return
    end
    if name == 'stop' then
        AnimpostfxStopAll()
        ClearTimecycleModifier()
        print('[br_core] all effects stopped')
        return
    end
    AnimpostfxPlay(name, 0, true)
    print(('[br_core] playing postfx "%s" -- "brfx stop" to clear'):format(name))
end, false)

RegisterCommand('brtc', function(_, args)
    local name, strength = args[1], tonumber(args[2] or '1.0')
    if not name then
        print('  usage: brtc <timecycleName> [strength]  |  brtc clear')
        return
    end
    if name == 'clear' then
        ClearTimecycleModifier()
        print('[br_core] timecycle cleared')
        return
    end
    SetTimecycleModifier(name)
    SetTimecycleModifierStrength(strength)
    print(('[br_core] timecycle "%s" at %.2f'):format(name, strength))
end, false)

RegisterNetEvent('br:debug:teleport')
AddEventHandler('br:debug:teleport', function(x, y)
    local ped = PlayerPedId()
    -- Request collision at the destination and wait for ground to stream in;
    -- teleporting without it drops the player through the map into the water.
    RequestCollisionAtCoord(x + 0.0, y + 0.0, 500.0)
    SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, 500.0, false, false, false)
    FreezeEntityPosition(ped, true)

    Citizen.CreateThread(function()
        local tries = 0
        while tries < 40 do
            Citizen.Wait(100)
            tries = tries + 1
            local found, z = GetGroundZFor_3dCoord(x + 0.0, y + 0.0, 500.0, false)
            if found then
                SetEntityCoordsNoOffset(ped, x + 0.0, y + 0.0, z + 1.0, false, false, false)
                break
            end
        end
        FreezeEntityPosition(ped, false)
        print(('[br_core] scatter: moved to %.0f, %.0f'):format(x, y))
    end)
end)

RegisterCommand('brkeys', function()
    print('--- key actions (rebind in Pause > Settings > Key Bindings) ---')
    for _, a in ipairs(BR.Keys.actions or {}) do
        print(('  %-14s held=%s'):format(a, tostring(BR.Keys.isHeld(a))))
    end
end, false)
