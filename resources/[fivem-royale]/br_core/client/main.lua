-- Client bootstrap and the loop registry.
--
-- THIS FILE IS THE PERFORMANCE CONTRACT OF THE PROJECT.
--
-- Every client subsystem registers a callback into one of exactly three loops.
-- No subsystem may call Citizen.CreateThread itself. Twenty subsystems each
-- spawning their own Wait(0) thread is the standard way a FiveM resource ends up
-- costing 3ms a frame, and once it happens it is very hard to unpick.
--
-- There is a second reason this exists. We deliberately consolidated all gameplay
-- into a single resource, because crossing resource boundaries means crossing Lua
-- states and paying serialisation on hot paths. The cost of that decision is that
-- `resmon` can no longer tell us WHICH subsystem is expensive -- it only sees
-- br_core as a whole. So the registry measures each callback itself. That gives
-- back the per-subsystem attribution resmon would have provided, without giving
-- back the per-call overhead.

BR = BR or {}

BR.Loop = {
    FRAME = 'frame',  -- every frame: markers, prompts, control disables
    TICK  = 'tick',   -- 10 Hz: HUD envelopes, proximity scans, storm in/out
    SLOW  = 'slow',   -- 1 Hz: loot cells, blip refresh, cache expiry
}

local INTERVALS = {
    [BR.Loop.FRAME] = 0,
    [BR.Loop.TICK]  = 100,
    [BR.Loop.SLOW]  = 1000,
}

-- A subsystem that throws every frame would flood the console and make the log
-- useless for finding the original fault. After this many consecutive errors the
-- callback is suspended and says so once.
local MAX_CONSECUTIVE_ERRORS = 5

local registry = {
    [BR.Loop.FRAME] = {},
    [BR.Loop.TICK]  = {},
    [BR.Loop.SLOW]  = {},
}

local started = false

-- TIMING -- read this before trusting the numbers in /brperf.
--
-- Two clocks, because neither one alone is honest here:
--
--   GetGameTimer()  wall time, but only millisecond resolution. A healthy
--                   per-frame callback costs well under 1ms, so timing one call
--                   with it rounds to zero. It IS reliable for the total cost of
--                   a whole band pass accumulated over a window.
--
--   os.clock()      sub-millisecond, but it reports PROCESS CPU time. In a
--                   multithreaded game client that can advance faster than wall
--                   time, so its absolute values may be inflated.
--
-- So: band totals come from GetGameTimer and are trustworthy in absolute terms.
-- Per-callback figures come from os.clock and are trustworthy as a RELATIVE
-- share -- good enough to answer "which subsystem is heavy", which is the actual
-- question. /brperf prints both so they can be cross-checked in-game; if the
-- per-callback sum diverges wildly from the band total, believe the band total.
local now_s
do
    local okClock, v = pcall(os.clock)
    if okClock and type(v) == 'number' then
        now_s = os.clock
    else
        now_s = function() return GetGameTimer() / 1000.0 end
    end
end

-- Band-level wall-clock accumulators, keyed by band.
local bandStats = {}

--- Register a callback into one of the three loops.
---
--- @param band string    one of BR.Loop.FRAME / TICK / SLOW
--- @param name string    unique, human-readable; shown in the perf overlay
--- @param fn function    receives (dtMs) since this callback last ran
--- @return table handle
function BR.Loop.register(band, name, fn)
    local list = registry[band]
    if not list then
        error(('BR.Loop.register: unknown loop band "%s"'):format(tostring(band)), 2)
    end
    if type(fn) ~= 'function' then
        error(('BR.Loop.register: "%s" needs a function'):format(tostring(name)), 2)
    end

    for _, e in ipairs(list) do
        if e.name == name then
            error(('BR.Loop.register: duplicate callback name "%s"'):format(name), 2)
        end
    end

    local entry = {
        name       = name,
        fn         = fn,
        band       = band,
        enabled    = true,
        -- perf accumulators, drained by BR.Loop.stats()
        calls      = 0,
        totalS     = 0.0,
        peakS      = 0.0,
        errors     = 0,
        consecutive= 0,
        lastRun    = 0,
        suspended  = false,
    }

    list[#list + 1] = entry
    return entry
end

--- Remove a callback. Safe to call at any time, including from inside a callback.
---
--- Semantics, pinned deliberately:
---   * Removal takes effect IMMEDIATELY. If A unregisters B during a pass and B
---     has not run yet, B does not run on that pass. Match cleanup unregistering
---     the storm renderer should not leave it drawing one more frame of a storm
---     that no longer exists.
---   * The array entry is flagged and swept AFTER the pass, never removed
---     mid-iteration -- doing that would shuffle the array and silently skip
---     whichever callback followed, which is close to undetectable from behaviour.
---
--- @param handle table
function BR.Loop.unregister(handle)
    if not handle then return end
    handle.dead = true
end

--- Enable or disable a callback by name, without unregistering it.
--- Used by the debug tooling to isolate a subsystem's cost, and to prove the
--- authority model -- disabling the client storm feedback must not stop the
--- player taking storm damage.
--- @param name string
--- @param enabled boolean
--- @return boolean found
function BR.Loop.setEnabled(name, enabled)
    for _, list in pairs(registry) do
        for _, e in ipairs(list) do
            if e.name == name then
                e.enabled = enabled and true or false
                if enabled then
                    e.suspended   = false
                    e.consecutive = 0
                end
                return true
            end
        end
    end
    return false
end

--- Snapshot of per-callback cost since the last reset.
--- @return table  array of { name, band, calls, avgMs, peakMs, errors, enabled, suspended }
function BR.Loop.stats()
    local out = {}
    for band, list in pairs(registry) do
        for _, e in ipairs(list) do
            out[#out + 1] = {
                name      = e.name,
                band      = band,
                calls     = e.calls,
                avgMs     = e.calls > 0 and (e.totalS / e.calls) * 1000.0 or 0.0,
                totalMs   = e.totalS * 1000.0,
                peakMs    = e.peakS * 1000.0,
                errors    = e.errors,
                enabled   = e.enabled,
                suspended = e.suspended,
            }
        end
    end
    table.sort(out, function(a, b) return a.totalMs > b.totalMs end)
    return out
end

--- Band-level wall-clock cost. These are the trustworthy absolute numbers;
--- compare against the summed per-callback figures to sanity-check them.
--- @return table  [band] = { passes, totalMs, peakMs, avgMs }
function BR.Loop.bandStats()
    local out = {}
    for band, bs in pairs(bandStats) do
        out[band] = {
            passes  = bs.passes,
            totalMs = bs.totalMs,
            peakMs  = bs.peakMs,
            avgMs   = bs.passes > 0 and (bs.totalMs / bs.passes) or 0.0,
        }
    end
    return out
end

--- Clear the perf accumulators so the next sample covers a fresh window.
function BR.Loop.resetStats()
    for _, list in pairs(registry) do
        for _, e in ipairs(list) do
            e.calls, e.totalS, e.peakS = 0, 0.0, 0.0
        end
    end
    for _, bs in pairs(bandStats) do
        bs.passes, bs.totalMs, bs.peakMs = 0, 0, 0
    end
end

--- Run a single pass over one band.
---
--- Public rather than local for two reasons: the debug tooling can single-step a
--- band to isolate a stall, and it makes the registry testable outside the game
--- (see tools/test_loop.lua) without spawning threads.
--- @param band string
function BR.Loop.step(band)
    local list = registry[band]
    if not list then return end

    local t = GetGameTimer()
    local bandStart = t
    local swept = false

    for i = 1, #list do
        local e = list[i]
        if e.dead then
            swept = true
        elseif e.enabled and not e.suspended then
            local dt = e.lastRun > 0 and (t - e.lastRun) or 0
            e.lastRun = t

            local s = now_s()
            local ok, err = pcall(e.fn, dt)
            local elapsed = now_s() - s

            e.calls  = e.calls + 1
            e.totalS = e.totalS + elapsed
            if elapsed > e.peakS then e.peakS = elapsed end

            if ok then
                e.consecutive = 0
            else
                -- One subsystem failing must not take the whole loop with it --
                -- a crash in the loot renderer should not stop storm damage.
                e.errors      = e.errors + 1
                e.consecutive = e.consecutive + 1
                print(('[br_core] loop callback "%s" errored: %s'):format(e.name, tostring(err)))
                if e.consecutive >= MAX_CONSECUTIVE_ERRORS then
                    e.suspended = true
                    print(('[br_core] suspending "%s" after %d consecutive errors; re-enable with /brloop enable %s')
                        :format(e.name, e.consecutive, e.name))
                end
            end
        end
    end

    -- Sweep anything unregistered during the pass, now that iteration is done.
    if swept then
        for i = #list, 1, -1 do
            if list[i].dead then table.remove(list, i) end
        end
    end

    -- Wall-clock cost of the whole pass. Coarse per pass, but accumulated over a
    -- window it is the trustworthy absolute number.
    local bs = bandStats[band]
    if not bs then
        bs = { passes = 0, totalMs = 0, peakMs = 0 }
        bandStats[band] = bs
    end
    local elapsedMs = GetGameTimer() - bandStart
    bs.passes  = bs.passes + 1
    bs.totalMs = bs.totalMs + elapsedMs
    if elapsedMs > bs.peakMs then bs.peakMs = elapsedMs end
end

--- Start the three loops. Called once from the resource start handler.
function BR.Loop.start()
    if started then return end
    started = true

    for band, interval in pairs(INTERVALS) do
        Citizen.CreateThread(function()
            while true do
                BR.Loop.step(band)
                Citizen.Wait(interval)
            end
        end)
    end
end

-- ---------------------------------------------------------------------------
-- Local match context.
--
-- The client mirrors server state and never derives it. Nothing in br_core/client
-- may enumerate players to work out who is alive, what the storm is doing, or who
-- killed whom -- those answers only exist on the server. See tools/verify.sh,
-- which fails the build if the scope-limited natives appear here.
-- ---------------------------------------------------------------------------

BR.State = {
    match    = { state = BR.MatchState.WAITING, endsAt = 0, mode = BR.Mode.SOLO.key },
    me       = { src = 0, squadId = nil, state = BR.PlayerState.LOBBY, hp = 100.0, armour = 0.0 },
    roster   = {},   -- [serverId] = { name, squadId, state, ... } -- mirror only
    squad    = {},   -- array of serverIds
    storm    = nil,  -- the published storm record; solved locally via BR.StormAt
    alive    = 0,
    squadsAlive = 0,
}

--- True when the local player is in a live match (not lobby or warmup).
--- @return boolean
function BR.InMatch()
    local s = BR.State.match.state
    return s == BR.MatchState.BUS or s == BR.MatchState.PLAYING
end

--- True when the local player can act -- landed, alive, not downed.
--- @return boolean
function BR.IsPlaying()
    return BR.State.match.state == BR.MatchState.PLAYING
       and BR.State.me.state == BR.PlayerState.ALIVE
end

AddEventHandler('onClientResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    BR.State.me.src = GetPlayerServerId(PlayerId())
    BR.Loop.start()

    print(('[br_core] client started (serverId %d, %d callbacks registered)')
        :format(BR.State.me.src, #BR.Loop.stats()))
end)
