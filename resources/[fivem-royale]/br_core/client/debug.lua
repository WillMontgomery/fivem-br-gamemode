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
    -- HONEST UNITS. GetGameTimer resolves to 1ms and a healthy callback costs
    -- far less, so every sample rounds to zero and the total stays zero -- a
    -- column of "0.0000ms" that looks like data and is not (user's paste,
    -- 2026-08-06). Anything that never reached a millisecond is reported as
    -- "<1ms", which is the truth, and /brbench is how to get a real number.
    print('--- callbacks (peak cost; "<1ms" means never measurable) ---')
    for _, s in ipairs(BR.Loop.stats()) do
        local cost = (s.peakMs > 0)
            and ('total %5dms peak %dms'):format(s.totalMs, s.peakMs)
            or  ('   <1ms per call, never measurable')
        print(('  %-24s %-5s calls %-7d %s%s%s')
            :format(s.name, s.band, s.calls, cost,
                    s.errors > 0 and ('  errors ' .. s.errors) or '',
                    s.suspended and '  SUSPENDED' or (s.enabled and '' or '  disabled')))
    end
    print('  For a real per-call cost: /brbench <name> [iterations]')
end, false)

--- Time one callback properly, by running it many times back to back.
---
---   /brbench loot.render          500 iterations
---   /brbench loot.render 2000
---   /brbench all                  every callback, 200 each
---
--- This exists because /brperf structurally cannot measure a sub-millisecond
--- callback: 1ms timer resolution means each sample rounds to zero and the
--- total never leaves zero. N calls in a row DO exceed a millisecond, so
--- total/N is a real number.
---
--- It runs the callbacks for real, out of band. Most are idempotent per-frame
--- draws; read the list before benching "all" on a live match.
RegisterCommand('brbench', function(_, args)
    local which = args[1]
    if not which then
        print('  usage: brbench <callbackName|all> [iterations]')
        print('  names:')
        for _, e in ipairs(BR.Loop.names()) do
            print(('    %-24s %s'):format(e.name, e.band))
        end
        return
    end

    local iters = tonumber(args[2])

    if which == 'all' then
        local rows = {}
        for _, e in ipairs(BR.Loop.names()) do
            local r = BR.Loop.bench(e.name, iters or 200)
            if r then rows[#rows + 1] = r end
        end
        table.sort(rows, function(a, b) return a.perCallMs > b.perCallMs end)
        print('--- per-call cost, most expensive first ---')
        for _, r in ipairs(rows) do
            print(('  %-24s %-5s %8.4fms/call  (%dms over %d calls)')
                :format(r.name, r.band, r.perCallMs, r.totalMs, r.iterations))
        end
        return
    end

    local r = BR.Loop.bench(which, iters)
    if not r then
        print(('[br_core] no such callback: %s   (see /brbench for the list)'):format(which))
        return
    end
    print(('  %s (%s): %.4fms per call -- %dms over %d calls')
        :format(r.name, r.band, r.perCallMs, r.totalMs, r.iterations))
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

-- `brkeys` LIVES IN keybinds.lua, NOT HERE (#137). There were two of them in
-- the same Lua state, and this file loads last, so this one silently won --
-- which meant the raw-layer, holds and focus-resync readings added to the real
-- one for #90 and #129 could never print, and the command answered a debugging
-- question with a fraction of what it knew. Its held column moved there; this
-- registration is deliberately gone rather than renamed, because two commands
-- that answer the same question is how the collision happened.

-- ---------------------------------------------------------------- drive-by ---
--
-- /brdriveby -- WHY CAN A PASSENGER NOT FIRE? (#197)
--
-- The symptom has four causes that are indistinguishable from the seat: our
-- flag never asserted, the engine's own per-seat weapon rule, a control
-- something disables every frame, or the seat itself. Each of them wants a
-- different fix in a different file, and three of the four are invisible to
-- every readout this project already has. So the question is measured instead.
--
-- IT SAMPLES ACROSS FRAMES RATHER THAN READING ONCE, and that is the whole
-- reason this is not four print statements.
--
--   A DISABLED CONTROL LASTS ONE FRAME. Whoever disables it does so from their
--   own callback, at their own point in the frame, and a command handler reads
--   the flag at ITS point in the frame -- so a single read is a coin flip on
--   whether the disable has happened yet. Sampling every frame for a couple of
--   seconds cannot miss it.
--
--   A STOWED WEAPON LOOKS EXACTLY LIKE AN ENTRY ANIMATION for the half second
--   it takes to climb in. "The engine held it on 0 of 120 frames" is the
--   difference between "you asked too early" and "it is never coming back",
--   and that difference is the entire diagnosis.
--
-- The verdict itself lives in client/inventory.lua as BR.Inv.driveByVerdict --
-- pure, and settled by tools/test_client.lua, for the same reason
-- BR.Native.teamFor is.

--- Everything that can stop a trigger, with the name the owner will see.
---
--- 68/69/70 are the vehicle set and 24/25/257 are the on-foot set, and BOTH are
--- listed because which pair the engine actually reads from a seat is a fact
--- about the build, not something to assume. A row that is always enabled costs
--- one line and rules out a whole file.
local ATTACK_CONTROLS = {
    {  24, 'ATTACK'               },
    {  25, 'AIM'                  },
    {  68, 'VEH_ATTACK'           },
    {  69, 'VEH_PASSENGER_ATTACK' },
    {  70, 'VEH_ATTACK2'          },
    { 257, 'ATTACK2'              },
}

--- A FiveM BOOL. `0` is truthy in Lua and this project has shipped that bug
--- four times; IsControlEnabled and IsPedInAnyVehicle are both declared BOOL.
local function yes(v) return v == true or v == 1 end

--- The same rule the server readouts draw between a table and its trailer.
local function rule()
    print('--------------------------------------------------------------')
end

--- Read the engine without letting an unbound native kill the readout.
---
--- Every native below is probed in client/natives.lua, which is the standing
--- rule. This is the belt to that pair of braces: a diagnostic that throws
--- before it prints a word is worse than no diagnostic, and /brprobe has
--- already been that once (owner, 2026-08-16).
local function safe(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

--- Which seat, in words. -1 is the driver in every vehicle in the game.
local function seatName(i)
    if i == nil then return 'not in a seat' end
    if i == -1 then return 'driver'          end
    if i ==  0 then return 'front passenger' end
    return 'rear seat ' .. tostring(i)
end

--- Which seat this ped is in, by asking the vehicle rather than the ped.
---
--- There is no native that answers "which seat am I in"; the engine only
--- answers "who is in seat N". Eight is past the largest seat count in the base
--- game, and a miss simply reports nil rather than guessing.
local function seatOf(veh, ped)
    for i = -1, 8 do
        if safe(GetPedInVehicleSeat, veh, i) == ped then return i end
    end
    return nil
end

--- The armed sample, or nil when nothing is being measured. One nil check per
--- frame when it is off, which is what the overlay above costs too.
local watch = nil

local function driveByReport()
    local f = BR.Inv.driveByFacts()
    local ped = PlayerPedId()
    local veh = watch.veh

    f.inVehicle    = watch.inVehicle > 0
    f.blocked      = watch.blocked
    f.engineHash   = watch.engineHash
    f.doingDriveby = watch.driveby > 0

    local seat  = veh and veh ~= 0 and seatOf(veh, ped) or nil
    local model = veh and veh ~= 0 and safe(GetEntityModel, veh) or nil
    local name  = model and safe(GetDisplayNameFromVehicleModel, model) or nil
    local w     = f.wantHash and BR.Config.WeaponByHash[BR.NormHash(f.wantHash)]

    --- What to call whatever the engine says is in the hand.
    ---
    --- FISTS ARE NAMED, NOT LEFT AS "unknown". WEAPON_UNARMED is the single most
    --- important value this row can hold -- it IS the stow -- and printing it as
    --- an unrecognised hash would bury the answer in the one line that carries
    --- it.
    local eng = 'nothing'
    if f.engineHash then
        local hit = BR.Config.WeaponByHash[BR.NormHash(f.engineHash)]
        if BR.NormHash(f.engineHash) == BR.NormHash(BR.Config.Gadgets.UNARMED) then
            eng = 'FISTS -- the weapon is not in your hands'
        else
            eng = hit and hit.label or 'unrecognised'
        end
    end

    local function hx(h)
        return h and ('0x%08X'):format(BR.NormHash(h)) or '-'
    end

    print('==============================================================')
    print('  #197 -- why can a passenger not fire?')
    print('==============================================================')
    print(('  sampled              %d frames over %.1fs')
        :format(watch.frames, (GetGameTimer() - watch.from) / 1000.0))
    print(('  state                %s   (this file may arm you: %s)')
        :format(tostring(f.state), f.canArm and 'yes' or 'NO'))
    print(('  in a vehicle         %s   (on %d of %d frames)')
        :format(f.inVehicle and 'yes' or 'no', watch.inVehicle, watch.frames))
    print(('  vehicle              %s'):format(name or '-'))
    print(('  seat                 %s   (%s)')
        :format(seat == nil and '-' or tostring(seat), seatName(seat)))
    print(('  inventory panel      %s'):format(f.panelOpen and 'OPEN' or 'closed'))
    print(('  active slot          %d   %s'):format(f.slotIndex, tostring(f.item or '-')))
    print(('  slot wants           %s   %s'):format(hx(f.wantHash), w and w.label or '-'))
    print(('  we granted           %s'):format(hx(f.appliedHash)))
    print(('  ENGINE holds         %s   %s'):format(hx(f.engineHash), eng))
    print(('  engine held the slot weapon on %d of %d frames')
        :format(watch.held, watch.frames))
    print(('  ammo in that weapon  %s'):format(tostring(watch.ammo or '-')))
    -- "never" rather than an age, because subtracting from a timestamp that
    -- was never written prints a number the size of the session uptime and
    -- reads like an answer.
    print(('  drive-by permission  %s')
        :format((f.driveByCount or 0) == 0 and 'NEVER ASSERTED'
            or ('asserted %.1fs ago, %d times so far')
                :format((GetGameTimer() - (f.driveByAt or 0)) / 1000.0, f.driveByCount)))
    print(('  IS_PED_DOING_DRIVEBY %s   (on %d of %d frames)')
        :format(tostring(f.doingDriveby), watch.driveby, watch.frames))
    for _, c in ipairs(ATTACK_CONTROLS) do
        local off = watch.off[c[1]] or 0
        print(('  control %-21s (%3d)  %s')
            :format(c[2], c[1],
                off == 0 and 'enabled on every frame'
                        or ('DISABLED on ' .. off .. ' of ' .. watch.frames .. ' frames')))
    end

    local code, sentence = BR.Inv.driveByVerdict(f)
    rule()
    print(('  VERDICT [%s]'):format(code))
    print('  ' .. sentence)
    rule()
    print('  HOW TO READ THIS')
    print('  in a vehicle / seat  which seat you were in for the sample. GTA')
    print('                       permits drive-by per SEAT, so a rear seat and')
    print('                       a front passenger seat can differ.')
    print('  slot wants / we granted / ENGINE holds')
    print('                       three answers to "what is in your hands".')
    print('                       Ours, ours, and the engine\'s. When the last')
    print('                       one is nothing while the first two agree, the')
    print('                       engine has taken the weapon off you.')
    print('  engine held it on N of M frames')
    print('                       0 of M means it is never coming back -- a')
    print('                       seat rule. A few frames means you asked')
    print('                       during the climb-in animation; run it again.')
    print('  drive-by permission  our SetPlayerCanDoDriveBy call. Seconds ago')
    print('                       and a large count is healthy; "never" means')
    print('                       the inv.apply tick is dead (see /brperf).')
    print('  control rows         a control disabled on ANY frame is a script')
    print('                       holding your trigger down, and is fixable.')
    print('                       All six enabled means no script is at fault.')
    print('  THE ONE THING NO SCRIPT CAN CHANGE: which weapons a seat accepts is')
    print('  game DATA -- the WeaponGroup list on that seat\'s CVehicleDriveByInfo')
    print('  in vehiclelayouts.meta. A standard car seat lists unarmed, one-handed')
    print('  and thrown. Rifles, shotguns, snipers and MGs are not on it, and')
    print('  there is no native that adds them. Lifting it means shipping our own')
    print('  copy of that data file, for every seat in the game -- which is a')
    print('  design decision about how a car fight feels, not a bug fix.')
end

BR.Loop.register(BR.Loop.FRAME, 'debug.driveby', function()
    if not watch then return end

    watch.frames = watch.frames + 1

    local ped = PlayerPedId()
    if yes(safe(IsPedInAnyVehicle, ped, false)) then
        watch.inVehicle = watch.inVehicle + 1
        watch.veh = safe(GetVehiclePedIsIn, ped, false) or watch.veh
    end
    if yes(safe(IsPedDoingDriveby, ped)) then watch.driveby = watch.driveby + 1 end

    -- THE HAND, EVERY FRAME. `ok == false` is the engine declining to answer,
    -- which is the same shape a stow produces and is recorded as "not holding
    -- it" rather than as no sample -- the question is whether the weapon is
    -- available to fire, and a weapon the engine will not name is not.
    local okW, held = GetCurrentPedWeapon(ped, true)
    watch.engineHash = okW and held or nil
    local want = BR.Inv.driveByFacts().wantHash
    if okW and want and BR.NormHash(held) == BR.NormHash(want) then
        watch.held = watch.held + 1
    end
    if want then watch.ammo = safe(GetAmmoInPedWeapon, ped, want) end

    for _, c in ipairs(ATTACK_CONTROLS) do
        -- NOT `if not IsControlEnabled(...)`. On a build that answers 0 for
        -- false, `not 0` is false and every row would read "enabled on every
        -- frame" -- the exact failure this command exists to rule out, wearing
        -- the exact bug this codebase has shipped four times.
        if not yes(safe(IsControlEnabled, 0, c[1])) then
            watch.off[c[1]] = (watch.off[c[1]] or 0) + 1
            watch.blocked = c[2]
        end
    end

    if GetGameTimer() >= watch.until_ then
        local ok, err = pcall(driveByReport)
        if not ok then print('[br_core] brdriveby: ' .. tostring(err)) end
        watch = nil
    end
end)

RegisterCommand('brdriveby', function(_, args)
    local secs = tonumber(args[1] or '') or 2
    if secs < 0.2 then secs = 0.2 end
    if secs > 30  then secs = 30  end

    local now = GetGameTimer()
    watch = {
        from = now, until_ = now + math.floor(secs * 1000),
        frames = 0, inVehicle = 0, held = 0, driveby = 0,
        off = {}, blocked = nil, veh = nil, engineHash = nil, ammo = nil,
    }
    print(('[br_core] brdriveby: watching for %.1fs -- SIT IN THE SEAT and try to fire.'):format(secs))
end, false)

-- ------------------------------------------------------------ canopy audit ---
--
-- WHAT A CANOPY INDEX ACTUALLY LOOKS LIKE, ANSWERED BY LOOKING AT IT.
--
-- br_lib/config/market.lua sells canopies by index, and every one of those
-- index-to-appearance claims came out of documentation rather than out of this
-- build. That is a bad thing to be wrong about quietly: the failure mode is a
-- player spending 6000 on a canopy that renders as something else, and nobody
-- finding out until they are already in the air and already charged.
--
-- So the mapping gets audited the same way this project audits every other
-- native assumption -- in game, out loud, before anything depends on it. The
-- table below is the CLAIM. `brchute test` is the check.
local CHUTE_TINTS = {
    [0] = 'Rainbow          (default -- what everyone has today)',
    [1] = 'Red              solid',
    [2] = 'Seaside Stripes  white/blue/yellow',
    [3] = 'Widowmaker       brown/red/white',
    [4] = 'Patriot          red/white/blue',
    [5] = 'Blue             solid',
    [6] = 'Black            solid',
    [7] = 'Hornet           black/yellow',
    -- 8-13 DO NOT RENDER, verified 2026-08-15 (#78): every one comes out as
    -- Hornet. The engine clamps above 7 on p_parachute1_mp_s. Kept in this list
    -- so the command still reports honestly if somebody tries them, and so the
    -- finding is not rediscovered from scratch.
    [8]  = 'Air Force       (DOES NOT RENDER -- clamps to Hornet)',
    [9]  = 'Desert          (DOES NOT RENDER -- clamps to Hornet)',
    [10] = 'Shadow          (DOES NOT RENDER -- clamps to Hornet)',
    [11] = 'High Altitude   (DOES NOT RENDER -- clamps to Hornet)',
    [12] = 'Airborne        (DOES NOT RENDER -- clamps to Hornet)',
    [13] = 'Sunrise         (DOES NOT RENDER -- clamps to Hornet)',
}

--- Set the canopy tint, both halves of it.
---
--- THE PACK IS TINTED SEPARATELY from the canopy, and they are two natives. A
--- player wearing a black pack under a red canopy is the sort of mismatch that
--- reads as a bug rather than as a cosmetic, so both move together and this is
--- the one place that knows they are a pair.
local function setCanopy(index)
    local pid = PlayerId()
    SetPlayerParachuteTintIndex(pid, index)
    SetPlayerParachutePackTintIndex(pid, index)
end

RegisterCommand('brchute', function(_, args)
    local sub = args[1]

    if not sub or sub == 'list' then
        print('  usage: brchute <0-13>   set the canopy tint now')
        print('         brchute test     lift to canopy height and deploy, to look at it')
        print('         brchute cycle    test, then step through 0-7 every 4s')
        print('  --- documented canopy indices (UNVERIFIED IN THIS BUILD) ---')
        for i = 0, 13 do
            print(('   %2d  %s'):format(i, CHUTE_TINTS[i]))
        end
        return
    end

    if sub == 'test' or sub == 'cycle' then
        local ped = PlayerPedId()
        local x, y, z = table.unpack(GetEntityCoords(ped))
        local start = tonumber(args[2]) or 0

        -- HIGH ENOUGH TO ACTUALLY WATCH ONE. A canopy seen for two seconds
        -- before the ground arrives is not a canopy anybody can judge.
        SetEntityCoordsNoOffset(ped, x, y, z + 600.0, false, false, false)

        local CHUTE = GetHashKey('GADGET_PARACHUTE')
        if not HasPedGotWeapon(ped, CHUTE, false) then
            GiveWeaponToPed(ped, CHUTE, 1, false, false)
        end
        -- EXACTLY ONE, ALWAYS -- chute ammo above one is what the engine reads
        -- as a reserve parachute, and this gamemode issues no reserves. The
        -- same rule skydive.lua enforces, for the same reason.
        SetPedAmmo(ped, CHUTE, 1)

        -- The model override FIRST, then the tint, then the task. This is the
        -- order the real drop path uses, and the order matters: a tint set
        -- after the canopy is already open does not repaint it.
        SetPlayerParachuteModelOverride(PlayerId(),
            GetHashKey(BR.Config.Drop.parachuteModel))
        setCanopy(start)

        Citizen.CreateThread(function()
            Citizen.Wait(300)
            for attempt = 1, 8 do
                TaskParachute(ped, true, false)
                Citizen.Wait(150)
                if GetPedParachuteState(ped) ~= BR.Native.ChuteState.NONE then break end
                if attempt == 8 then
                    print('[br_core] brchute: TaskParachute never took -- nothing to look at')
                    return
                end
            end
            print(('[br_core] brchute: canopy %d -- %s'):format(start, CHUTE_TINTS[start] or '?'))

            if sub ~= 'cycle' then return end

            -- CYCLING RE-DEPLOYS, because it has to. The tint is read when the
            -- canopy opens, so stepping the index under an already-open canopy
            -- changes nothing on screen -- which would look exactly like the
            -- indices all being identical, and would be the wrong conclusion.
            for i = start + 1, 7 do
                Citizen.Wait(4000)
                if GetPedParachuteState(PlayerPedId()) == BR.Native.ChuteState.NONE then
                    print('[br_core] brchute: landed -- cycle stopped')
                    return
                end
                local p = PlayerPedId()
                local cx, cy, cz = table.unpack(GetEntityCoords(p))
                SetEntityCoordsNoOffset(p, cx, cy, cz + 400.0, false, false, false)
                setCanopy(i)
                Citizen.Wait(200)
                TaskParachute(p, true, false)
                print(('[br_core] brchute: canopy %d -- %s'):format(i, CHUTE_TINTS[i] or '?'))
            end
        end)
        return
    end

    local index = tonumber(sub)
    if not index or index < 0 or index > 13 then
        print('[br_core] brchute: index must be 0-13, or "test" / "cycle" / "list"')
        return
    end

    setCanopy(index)
    print(('[br_core] brchute: canopy set to %d -- %s'):format(index, CHUTE_TINTS[index] or '?'))
    print('[br_core] brchute: takes effect on the NEXT deploy, not the current canopy.')
end, false)
