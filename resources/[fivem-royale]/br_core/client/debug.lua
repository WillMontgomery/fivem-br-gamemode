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

-- `brsound` IS GONE. IT LIVES IN client/sfx.lua AS `brsfx play`.
--
-- It was a second raw-pair audition command, registered under a different name
-- to /brsfx's identical two-argument form -- so the duplicate-command gate in
-- verify.sh could not see it (that gate buckets by NAME, and these were two
-- names for one question). #137's lesson was written about exactly this shape:
-- "two commands for one question is how the collision happened".
--
-- IT MATTERED MORE THAN A TIDY-UP, because the two were not equivalent. This
-- one played through the fire-and-forget sound id -1, which cannot be asked
-- whether it ever started; /brsfx now plays through a real GET_SOUND_ID and
-- reports `[silent?]` when the engine says the sound was over before it could
-- be heard. Somebody choosing a sound and reaching for the wrong one of these
-- two would have lost precisely the answer they were looking for -- and a
-- wrong-set silence being indistinguishable from a bad sound is what has
-- already cost this project two rounds of fuel-cue picks.
--
-- Its one extra readout -- the loot pair out of config/loot.lua, which is not
-- in the cue table -- moved to `brsfx`'s own usage rather than being dropped.

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

--- Which seat this ped is in. ONE DEFINITION, IN client/driveby.lua.
---
--- The drive-by hint has to answer exactly this question before it will say
--- anything, and two answers to "which seat am I in" living in one Lua state is
--- how the duplicate `brkeys` above happened -- the two drift, and the one that
--- loads last silently wins. The readout borrows the gameplay file's rather
--- than keeping a second copy: if the hint is looking at the wrong seat, this
--- command has to show the wrong seat too, or it exonerates the bug.
---
--- Resolved at CALL time rather than bound at load time, so this file's position
--- in the manifest is not a thing anyone has to get right twice.
local function seatOf(veh, ped) return BR.DriveBy.seatOf(veh, ped) end

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

    -- OUR CLAIM ABOUT THIS WEAPON, alongside the engine's answer to the same
    -- question, so the two can be read off one screen. There is no native that
    -- asks "does this seat accept this weapon" -- the engine only answers by
    -- stowing or not stowing what is already in the hand -- so this row IS the
    -- audit of br_lib/config/weapons.lua's `driveby` field, and the sample above
    -- is the engine's half of it. Left nil when no weapon is selected: nil is
    -- "nobody asked", and the verdict must not read it as "no".
    --
    -- WRITTEN AS AN `if`, NOT AS `a and b or nil`. That idiom collapses `false`
    -- to `nil` -- which is precisely the tri-state this readout has to keep
    -- apart, and precisely the family of bug this file has a `yes()` helper for.
    if f.wantHash ~= nil then
        f.permitted = BR.DriveBy.permits(f.wantHash)
    end

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
    -- OUR CLAIM, PRINTED NEXT TO THE ENGINE'S ANSWER. `== true` / `== false`
    -- rather than truthiness, because the third state is a real one and reads
    -- differently: "-" is nobody asked, not "no".
    print(('  we say the seat    %s   (driveby field, br_lib/config/weapons.lua)')
        :format(f.permitted == true and 'ACCEPTS it'
            or (f.permitted == false and 'REFUSES it' or '-')))
    -- And the drive-by hint, which reads exactly that field. Printing what it
    -- would say is the only way to see the notification without waiting for the
    -- one time a session it fires.
    do
        local slotN, label = BR.DriveBy.suggestion(BR.Inv.local_())
        print(('  drive-by hint      %s')
            :format(slotN and BR.DriveBy.MESSAGE:format(slotN, label)
                or 'nothing to suggest -- no other slot holds a weapon a seat accepts'))
        print(('  ...already shown   %s'):format(BR.DriveBy.shown() and 'yes -- once per session, and this session has had it'
            or 'no'))
    end
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
    print('  we say the seat      OUR claim, from the driveby field in')
    print('                       br_lib/config/weapons.lua. There is no native')
    print('                       that asks the engine this, so the only check on')
    print('                       it is the row above: ACCEPTS plus a stow means')
    print('                       the table is WRONG and the hint would send a')
    print('                       player to a weapon that does not fire.')
    print('  WIDENING THE SEAT RULE WAS TRIED AND THE GAME REFUSED IT. We shipped a')
    print('  vehiclelayouts.meta redefining DRIVEBY_DEFAULT_ONE_HANDED by name; the')
    print('  engine kept its own and ignored ours (owner, 2026-08-22). The file is')
    print('  gone. docs/vehicle-data.md has the finding and the only route left.')
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

-- ------------------------------------------------------------ boost audit ---
--
-- /brboostwhy -- WHY DOES THE BOOST DO NOTHING? (#203)
--
-- NOT `brboost`, AND THE NAME IS A GATE RATHER THAN A PREFERENCE. `brboost` is
-- already taken twice: server/boost.lua registers it for the relay stats (a
-- different Lua state, so that alone would be fine and is common here), and
-- keybinds.lua's own hold() registers the +brboost / -brboost pair on THIS
-- state. tools/verify.sh's duplicate-command gate counts the hold registrar as
-- claiming the bare name, deliberately -- #137 was three commands silently
-- shadowing each other, one of which was the very readout we were telling the
-- owner to run to diagnose the bug it was hiding.
--
--   "Boost does nothing, likely because GTA V's drift mode is taking over which
--    is bound on SHIFT. If we can find a way to override that and test again."
--   "The boost bar does display and is at 100, so that's good at least."
--                                                  -- owner, 2026-08-22
--
-- ═══ THE FULL METER IS WHY THIS COMMAND EXISTS ═══
--
-- It reads as reassurance and it is the opposite: the meter only falls on a
-- frame the boost loop decides to SPEND, so "100 and staying there" is the
-- signature of every failure at once. A key that never arrives, a seat gate that
-- refuses, a dry latch, and an impulse the engine ignores all leave the bar
-- exactly where the owner found it. Three of those four want a fix in a
-- different file.
--
-- So the chain is measured instead, one rung at a time, and the rung that fails
-- is named. This is /brdriveby's argument for #197 applied to #203, and it is
-- the same shape because the situation is the same shape: several causes, one
-- symptom, and no way to tell them apart from the driver's seat.
--
-- ═══ WHAT IT SAMPLES THAT NOTHING ELSE CAN ═══
--
--   THE KEYBOARD, THREE WAYS AT ONCE. /brprobe rawkey already answers "is
--   IsRawKeyDown a level or an edge" for ONE virtual-key code. That is not the
--   question here. The question is whether the code the boost is ACTUALLY
--   WATCHING is the code this build reports shift on -- so all three shift codes
--   are counted side by side, and the winner is named. 0x10 (VK_SHIFT) is what
--   keybinds.lua's DEFAULT_VK chose, on three converging arguments and no
--   observation; if 0xA0 counts frames and 0x10 counts none, that reasoning was
--   wrong and the fix is one table entry.
--
--   GTA'S OWN CONTROLS ON THE SAME KEY. If no raw code reports the key and a
--   control does, the key is reaching the game and IsRawKeyDown is the wrong
--   reader -- which is a different fix again, and is not something any existing
--   readout in this project can see.
--
--   AND THE SPEED THE CAR ACTUALLY REACHED, against the speed the spec asked
--   for. That is the only thing that can convict APPLY_FORCE_TO_ENTITY, and it
--   is measured inside the push itself (BR.Boost.trace) rather than modelled out
--   here -- a second copy of the rules would exonerate the bug.

--- Every raw code worth asking about for a binding on shift.
---
--- ALL THREE, ALWAYS, EVEN THOUGH ONLY ONE CAN BE RIGHT. The whole diagnostic
--- value is in the DISAGREEMENT: one of these counting frames while the one the
--- boost watches counts none is the finding, and it cannot be seen by asking
--- about a single code.
local SHIFT_VK = {
    { 0x10, 'VK_SHIFT   -- either shift, what DEFAULT_VK chose' },
    { 0xA0, 'VK_LSHIFT  -- left only'  },
    { 0xA1, 'VK_RSHIFT  -- right only' },
}

--- GTA's own controls on left shift, from br_lib/config/boost.lua's own list.
---
--- BORROWED RATHER THAN RETYPED IN SPIRIT: the numbers and their names are the
--- four that config/boost.lua's header enumerates as "what shift already does in
--- a vehicle", and this is the row that turned that research into an
--- observation. It did: all four read PRESSED on 590 of 686 frames in a car.
---
--- WHAT THAT ROW CANNOT TELL YOU, WRITTEN HERE BECAUSE IT WAS MISREAD ONCE.
--- IS_DISABLED_CONTROL_PRESSED answers the MAPPER -- "is the input bound to this
--- id down" -- and there is no native anywhere that asks whether the engine
--- ACTED on it. All four of these are bound to LSHIFT, so all four read down
--- whenever shift is down, on any build, in any context. Four PRESSED rows are
--- the sentence "shift was down" printed four times; they are not four things
--- happening to the car.
local SHIFT_CONTROLS = {
    {  21, 'INPUT_SPRINT'                    },
    {  61, 'INPUT_VEH_MOVE_UP_ONLY'          },
    { 340, 'INPUT_VEH_HYDRAULICS_CONTROL_UP' },
    { 352, 'INPUT_VEH_FLY_BOOST'             },
}

--- The highest control id in the Cfx table (359 is INPUT_RESPAWN_FASTER).
local CONTROL_MAX = 359

--- ═══ AND EVERY OTHER CONTROL IN THE TABLE, BECAUSE THE FOUR ABOVE ARE A
---     HARDCODED LIST AND THE DOCUMENT THEY CAME FROM IS SIX YEARS OLD ═══
---
--- config/boost.lua states the gap in its own words: the public control table's
--- last substantive update was November 2020 (build ~2189), so an input Rockstar
--- added between then and 3095 would not appear in it. SHIFT_CONTROLS is that
--- document, retyped. A fifth control on this key -- the thing that would
--- actually explain "still getting drift mode" -- is by construction the one
--- thing the four rows above can never show.
---
--- SO THE WHOLE TABLE IS SWEPT AND ANYTHING UNEXPECTED IS NAMED. Ids 0..359,
--- every sample, reported only when they read down while the boost key is held
--- and only when they are not already one of the four. An empty list here is
--- "the four are all there is"; a populated one names the id to look up, which
--- is the difference between the next round having an answer and having another
--- hypothesis.
---
--- THE COST IS 360 PROBES A FRAME AND IT IS PAID BY A COMMAND WITH A DEADLINE.
--- Nothing sweeps unless /brboostwhy is armed, the window is six seconds by
--- default and thirty at most, and every probe goes through safe() -- an id this
--- build does not know throws once and is skipped, rather than killing the
--- readout before it prints a word.
local function sweepOther(w)
    for c = 0, CONTROL_MAX do
        if not w.known[c] and yes(safe(IsDisabledControlPressed, 0, c)) then
            w.other[c] = (w.other[c] or 0) + 1
        end
    end
end

--- The armed boost sample, or nil. One nil check per frame when it is off.
local bwatch = nil

--- @param w table  the sample, PASSED IN rather than read from `bwatch`.
---
--- The caller disarms before it reports -- a report that throws must not leave
--- the trace armed on the FRAME band forever -- so by the time this runs
--- `bwatch` is already nil. Reading it from the upvalue instead cost the first
--- run of this command its entire output.
local function boostReport(w)
    -- THE FILE'S OWN STATE, MERGED IN RATHER THAN RE-ASKED. BR.Boost.facts()
    -- carries the two things that were true before this window opened -- whether
    -- the force native has EVER been accepted, and what it said when it was not.
    for k, v in pairs(BR.Boost.facts()) do w[k] = v end

    -- HOW OFTEN THE CODE WE ACTUALLY WATCH READ DOWN. Counted here from the
    -- per-code table rather than sampled separately, so it cannot disagree with
    -- the row printed below it.
    --
    -- ITS ABSENCE MADE ONE WHOLE VERDICT UNREACHABLE, and mutation testing is
    -- what found it: `key-not-routed` -- the raw code down while
    -- BR.Keys.isHeld stays false, which is what a NUI screen holding the
    -- keyboard looks like -- reads `rawSelf`, and nothing ever wrote it. Every
    -- such case came out as `key-unseen`, which names the wrong file.
    w.rawSelf = (w.rawSelfCode and w.raw[w.rawSelfCode]) or 0

    -- WHICH RAW CODE DID BEST, AND IT IS NOT ALLOWED TO BE OUR OWN. The verdict
    -- asks "did some OTHER code answer for this key", so the one we are already
    -- watching is excluded here or it would answer its own question.
    --
    -- ═══ THE EXCLUSION IS UNREACHABLE TODAY, AND MUTATION TESTING SAYS SO ═══
    --
    -- Deleting `r[1] ~= w.rawSelfCode` changes no outcome and no assertion
    -- notices, which is worth writing down rather than leaving for the next
    -- person to rediscover. The branch that consumes `rawBestFrames` is only
    -- reached when `rawSelf` is ZERO -- rung 1 takes the `rawSelf > 0` road
    -- first -- and a code that read down on zero frames cannot win a `>`
    -- comparison against zero. So our own code can never be the winner here
    -- whether or not it is excluded.
    --
    -- KEPT ANYWAY, for the reason boost_solve.lua keeps its own unreachable
    -- floor: the two protect against different edits. The ladder's ordering is
    -- what makes this dead, and the ladder is a thing somebody will reorder --
    -- at which point a verdict that told the owner "0x10 never answered but
    -- 0x10 did" would be worse than no verdict at all.
    w.rawBestCode, w.rawBestFrames = nil, 0
    for _, r in ipairs(SHIFT_VK) do
        local c = w.raw[r[1]] or 0
        if r[1] ~= w.rawSelfCode and c > w.rawBestFrames then
            w.rawBestCode, w.rawBestFrames = r[1], c
        end
    end

    w.engineFrames = 0
    for _, c in ipairs(SHIFT_CONTROLS) do
        local n = w.ctrl[c[1]] or 0
        if n > w.engineFrames then w.engineFrames = n end
    end

    local function mph(m) return (m or 0.0) / BR.BoostSolve.MPH end

    print('==============================================================')
    print('  #203 -- why does the boost do nothing?')
    print('==============================================================')
    print(('  sampled              %d boost.drive frames over %.1fs')
        :format(w.frames or 0, (GetGameTimer() - w.from) / 1000.0))
    print(('  boost enabled        %s   meter %.0f%%  (%.0f / %.0f ms)')
        :format(w.enabled and 'yes' or 'NO', BR.Boost.meter(),
                w.budgetMs or 0, w.capacityMs or 0))
    rule()
    print('  THE KEY')
    print(('  binding              %s   watching %s')
        :format(tostring(BR.Keys.labelFor('brboost')),
                w.rawSelfCode and ('0x%02X'):format(w.rawSelfCode)
                              or 'NOTHING -- unbound'))
    print(('  raw layer            active %s   holds %s   ui owns keyboard %s')
        :format(tostring(BR.Keys.rawActive), tostring(BR.Keys.rawHolds),
                tostring(BR.Keys.uiOwnsKeyboard)))
    for _, r in ipairs(SHIFT_VK) do
        local n = w.raw[r[1]] or 0
        print(('  IsRawKeyDown 0x%02X    %-24s %s')
            :format(r[1],
                n == 0 and 'never'
                       or (('DOWN on %d of %d'):format(n, w.samples or 0)),
                r[2]))
    end
    -- THE SHAPES, BECAUSE `1` IS NOT `true`. keybinds.lua normalises at the
    -- sample (truth()), and this is the row that says whether it had to.
    for k, n in pairs(w.shapes) do
        print(('  ...returned          %s on %d sample(s)'):format(k, n))
    end
    print(('  BR.Keys.isHeld       %s')
        :format((w.heldFrames or 0) == 0 and 'NEVER true'
            or ('true on %d of %d frames'):format(w.heldFrames, w.frames or 0)))
    rule()
    print('  WHAT GTA ITSELF DOES WITH THAT KEY')
    for _, c in ipairs(SHIFT_CONTROLS) do
        local n   = w.ctrl[c[1]] or 0
        local off = w.ctrlOff[c[1]] or 0
        print(('  control %-33s (%3d)  %s%s')
            :format(c[2], c[1],
                n == 0 and 'never pressed'
                       or ('PRESSED on %d of %d'):format(n, w.samples or 0),
                off > 0 and ('   [disabled on %d]'):format(off) or ''))
    end

    -- ANYTHING ELSE IN THE TABLE THAT ANSWERED TO THE SAME KEY. Sorted, because
    -- pairs() order is a different readout every run and this one gets pasted
    -- into an issue.
    local other = {}
    for c in pairs(w.other) do other[#other + 1] = c end
    table.sort(other)
    if #other == 0 then
        print(('  every OTHER control    silent on all %d frames the key was down')
            :format(w.sweeps or 0))
    else
        for _, c in ipairs(other) do
            print(('  control %-33s (%3d)  ALSO PRESSED on %d of %d')
                :format('-- not in the 2020 table --', c, w.other[c], w.sweeps or 0))
        end
    end
    rule()
    print('  THE SEAT')
    print(('  in a vehicle         %s')
        :format((w.inVehFrames or 0) == 0 and 'no'
            or ('on %d frames'):format(w.inVehFrames)))
    print(('  in the driver seat   %s')
        :format((w.driverFrames or 0) == 0 and 'NO'
            or ('on %d frames'):format(w.driverFrames)))
    print(('  vehicle class        %s%s')
        :format(tostring(w.class),
            (w.excludedFrames or 0) > 0
                and ('   EXCLUDED on %d frames (BR.Config.Boost.excludeClasses)')
                    :format(w.excludedFrames) or ''))
    rule()
    print('  THE LOOP')
    print(('  wanted to boost      %s')
        :format((w.wantFrames or 0) == 0 and 'on NO frame'
            or ('on %d of %d frames'):format(w.wantFrames, w.frames or 0)))
    print(('  refused: dry latch %d   meter empty %d')
        :format(w.dryFrames or 0, w.emptyFrames or 0))
    rule()
    print('  THE PUSH')
    print(('  push() ran           %s')
        :format((w.pushFrames or 0) == 0 and 'never'
            or ('on %d frames'):format(w.pushFrames)))
    print(('  ...no speed reading  %d      ...already ahead of the ramp  %d')
        :format(w.noSpeed or 0, w.alreadyAhead or 0))
    print(('  APPLY_FORCE accepted %d   threw %d   (this session: %d of %d)')
        :format(w.forced or 0, w.forceThrew or 0, w.forceOk or 0, w.forceCalls or 0))
    if w.forceErr then
        print(('  FIRST ERROR          %s'):format(w.forceErr))
    end
    print(('  total asked for      %.1f m/s summed over every pushing frame')
        :format(w.dvAsked or 0.0))
    rule()
    print('  DID THE CAR GO FASTER')
    print(('  speed seen           %.1f .. %.1f m/s  (%.0f .. %.0f mph)')
        :format(w.speedMin or 0.0, w.speedMax or 0.0,
                mph(w.speedMin), mph(w.speedMax)))
    print(('  best gain over the speed at the press   %.1f m/s  (%.1f mph)')
        :format(w.gain or 0.0, mph(w.gain)))
    print(('  the spec asks for                       %.1f m/s  (%.1f mph)')
        :format(w.addMps or 0.0, mph(w.addMps)))
    -- ═══ AND HOW SIDEWAYS IT WENT WHILE WE PUSHED IT ═══
    --
    -- "still getting drift mode at the same time" (owner, 2026-08-22). No drift
    -- INPUT exists on this build -- the Cfx table runs 0..359 and no name in it
    -- contains DRIFT -- so the remaining suspect is our own impulse, which
    -- delivers about 1.4 g to the rigid body without passing through the tyres
    -- and therefore without spending any of their grip. This is that claim made
    -- falsifiable: a car travelling sideways at several m/s while boosting IS a
    -- drift, and one whose lateral speed stays near zero is not.
    print(('  sideways while boosting                 %s')
        :format(w.slipMax == nil
            and 'not measured (no speed vector on this build)'
            or ('%.1f m/s peak  (%.1f mph)'):format(w.slipMax, mph(w.slipMax))))

    local code, sentence = BR.Boost.verdict(w)
    rule()
    print(('  VERDICT [%s]'):format(code))
    print('  ' .. sentence)
    rule()
    print('  HOW TO READ THIS')
    print('  IsRawKeyDown rows    the three codes shift can arrive as. The boost')
    print('                       watches ONE of them (named above). If a code we')
    print('                       are NOT watching counts frames and ours counts')
    print('                       none, DEFAULT_VK in keybinds.lua is wrong -- and')
    print('                       that is a one-line fix in a different file.')
    print('  control rows         GTA\'s own controls on the same key. These read')
    print('                       the engine\'s mapper, not the keyboard, so a')
    print('                       control firing while every raw code stays silent')
    print('                       means the key reaches the GAME and not us.')
    print('                       ALL FOUR ARE BOUND TO LSHIFT, so all four read')
    print('                       PRESSED whenever shift is down, in any context.')
    print('                       That is the mapper answering, NOT four things')
    print('                       happening to the car -- no native reports what')
    print('                       the engine did with a control. What each one')
    print('                       actually does is in config/boost.lua.')
    print('  OTHER control rows   the rest of the table (0..359), swept only on')
    print('                       frames the key was down. Empty is the answer we')
    print('                       expect; a row here is an input added after the')
    print('                       public table\'s last update and is the first')
    print('                       thing to look up.')
    print('  sideways             lateral speed while boosting. A drift is this')
    print('                       number being large. Near zero exonerates the')
    print('                       impulse and sends the next round to the key.')
    print('  BR.Keys.isHeld       the key layer\'s own conclusion. A raw code down')
    print('                       with this never true is keybinds.lua dropping it')
    print('                       -- check `holds` and `ui owns keyboard` above.')
    print('  APPLY_FORCE accepted 0 accepted with a non-zero call count is the')
    print('                       native refusing us, and the message says why.')
    print('  best gain            the spec in its own words: "30mph faster than')
    print('                       what it was doing when they pressed it". Pushing')
    print('                       for hundreds of frames and gaining nothing is')
    print('                       the impulse doing nothing, which is a decision')
    print('                       for the owner -- the fallback is a torque')
    print('                       multiplier and it cannot hit an exact speed.')
end

BR.Loop.register(BR.Loop.FRAME, 'debug.boost', function()
    if not bwatch then return end
    local w = bwatch

    -- `samples` IS THIS CALLBACK'S OWN COUNT AND `frames` IS boost.drive's, AND
    -- THEY ARE DELIBERATELY TWO NUMBERS. Both run on the FRAME band so they
    -- should agree -- and if they do not, that is itself the finding: a
    -- boost.drive that is suspended (see BR.Loop's error ceiling) would leave
    -- every counter below at zero for a reason that has nothing to do with the
    -- key. One number would hide it.
    w.samples = (w.samples or 0) + 1

    -- IS THE BOOST KEY DOWN ON THIS FRAME, ASKED OF BOTH READERS. It gates the
    -- sweep below and nothing else: a sweep that ran on every frame would report
    -- INPUT_VEH_ACCELERATE and the whole of the driving control set, which is
    -- true, useless, and would bury the one row worth having.
    local keyDown = false

    for _, r in ipairs(SHIFT_VK) do
        local ok, v = pcall(IsRawKeyDown, r[1])
        if ok then
            -- THE SHAPE, NOT JUST THE TRUTHINESS. /brprobe rawkey's own note:
            -- counting with `if ok and v` exonerated the key layer for six
            -- rounds while the native was handing back the NUMBER 1 and every
            -- consumer compared it with `== true`. 0 is truthy in Lua, so a
            -- truthiness count cannot tell `true` from `1`, and `1` was the bug.
            local shape = ('%s %s'):format(type(v), tostring(v))
            w.shapes[shape] = (w.shapes[shape] or 0) + 1
            if not (v == nil or v == false or v == 0) then
                w.raw[r[1]] = (w.raw[r[1]] or 0) + 1
                keyDown = true
            end
        end
    end

    for _, c in ipairs(SHIFT_CONTROLS) do
        -- DISABLED-INCLUSIVE, DELIBERATELY. IsControlPressed goes quiet for a
        -- control something disabled this frame, and "the key reached the
        -- engine" is true either way -- which is the only thing this row is
        -- being asked. The disable itself is counted beside it.
        if yes(safe(IsDisabledControlPressed, 0, c[1])) then
            w.ctrl[c[1]] = (w.ctrl[c[1]] or 0) + 1
            keyDown = true
        end
        if not yes(safe(IsControlEnabled, 0, c[1])) then
            w.ctrlOff[c[1]] = (w.ctrlOff[c[1]] or 0) + 1
        end
    end

    -- THE REST OF THE TABLE, ONLY WHILE THE KEY IS DOWN. See sweepOther.
    if keyDown then
        w.sweeps = w.sweeps + 1
        sweepOther(w)
    end

    if GetGameTimer() >= w.until_ then
        -- DISARMED BEFORE THE REPORT, NOT AFTER. A report that throws must not
        -- leave the trace armed on the FRAME band forever -- a diagnostic that
        -- breaks the thing it is measuring has happened on this project once
        -- already (/brprobe, owner 2026-08-16).
        BR.Boost.trace(nil)
        bwatch = nil
        local ok, err = pcall(boostReport, w)
        if not ok then print('[br_core] brboostwhy: ' .. tostring(err)) end
    end
end)

RegisterCommand('brboostwhy', function(_, args)
    local secs = tonumber(args[1] or '') or 6
    if secs < 0.5 then secs = 0.5 end
    if secs > 30  then secs = 30  end

    local now = GetGameTimer()
    -- WHICH IDS THE SWEEP IS NOT TO REPORT, BUILT FROM THE PRINTED LIST RATHER
    -- THAN RETYPED. Two copies of "the four" is how one of them ends up with a
    -- fifth entry nobody notices, and the whole value of the sweep is that its
    -- output is exactly the ids the four rows above did not already cover.
    local known = {}
    for _, c in ipairs(SHIFT_CONTROLS) do known[c[1]] = true end

    bwatch = {
        from = now, until_ = now + math.floor(secs * 1000),
        raw = {}, ctrl = {}, ctrlOff = {}, shapes = {}, samples = 0,
        known = known, other = {}, sweeps = 0,
        -- WHAT THE BOOST IS ACTUALLY WATCHING, ASKED OF THE KEY LAYER RATHER
        -- THAN ASSUMED TO BE SHIFT. The binding is remappable by the spec, so a
        -- readout that hardcoded 0x10 would be lying to any player who moved it,
        -- and "the boost is on a key you are not pressing" is a real answer.
        rawSelfCode = BR.Keys.boundTo('brboost'),
    }
    -- The counters only boost.lua can fill land in the same table.
    BR.Boost.trace(bwatch)

    print(('[br_core] brboostwhy: watching for %.1fs -- BE DRIVING A CAR and HOLD %s '
        .. 'for the whole window.'):format(secs, tostring(BR.Keys.labelFor('brboost'))))
end, false)

-- ------------------------------------------------------------ mad drivers ---
--
-- WHY THE AMBIENT DRIVERS ARE CALM, ANSWERED BY READING RATHER THAN GUESSING.
--
-- "The NPC drivers are all too calm now, did something change?" -- the owner,
-- 2026-08-22. That question has four candidate answers and no way to tell them
-- apart through a windscreen: the feature can be switched off, the pass can be
-- gated out by player state, the pass can be running and finding nothing in
-- range, or it can be finding drivers and having the re-task refused. All four
-- look identical from the driver's seat and every one of them has a different
-- fix, which is exactly how a tuning pass ends up being done on a hunch.
--
-- Every number below is taken off the pass itself (client/gamerules.lua), so
-- this reports what happened rather than what was supposed to happen.
RegisterCommand('brdrivers', function()
    local S = BR.Gamerules and BR.Gamerules.driverStats and BR.Gamerules.driverStats()
    if not S then
        print('[br_core] brdrivers: client/gamerules.lua is not loaded')
        return
    end

    print('--- mad drivers: the last pass ---')
    print(('  erratic          %s   (BR.Config.Ambient.erratic)')
        :format(S.erratic and 'ON' or 'OFF'))
    print(('  player state     %s'):format(tostring(BR.State.me.state)))
    print(('  last pass        %s   %s')
        :format(S.ran and 'RAN' or 'DID NOT RUN', S.why or '?'))

    -- THE ANCHOR IS THE LINE THAT ANSWERED THE 2026-08-22 REPORT. A spectator's
    -- ped is a corpse where they fell and the shot is somewhere else entirely,
    -- so a pass anchored on the ped treats the traffic around a body nobody is
    -- looking at and leaves every driver on screen alone.
    if S.ran then
        print(('  anchored on      %s   (%.0fm from your own ped)')
            :format(tostring(S.anchorFrom), S.anchorOffPed or 0.0))
        print(('  vehicles         %d in the pool, %d within %.0fm')
            :format(S.pool, S.inRange, S.range))
        print(('    of those       %d empty, %d driven by a player, %d treated')
            :format(S.empty, S.playerDriven, S.treated))
        print(('  tracked handles  %d (re-tasked on a cadence, not once)')
            :format(S.tracked))
        -- IN LUA `0` IS TRUTHY and a BOOL native may hand back a number, which
        -- this repo has shipped four times. gamerules.lua tests this value with
        -- a bare `not`, so a build that returns 0 for "not a player" would make
        -- that test refuse EVERY driver. Printed raw, with its type, because
        -- reading it is the only way to know which build this is.
        print(('  IsPedAPlayer     %s   <- if that is a NUMBER, read the note in')
            :format(S.playerRaw or 'no driver seen yet'))
        print('                   client/gamerules.lua before changing anything')
    end

    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 'gamerules.madDrivers' then
            print(('  loop callback    %s, %d errors%s')
                :format(s.suspended and 'SUSPENDED' or (s.enabled and 'live' or 'disabled'),
                        s.errors,
                        s.suspended and ' -- /brloop enable gamerules.madDrivers' or ''))
        end
    end
end, false)
