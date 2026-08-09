-- The tick scheduler, one per resource.
--
-- Every subsystem registers a job here rather than spawning its own thread, so
-- the cost of the whole gamemode is measurable in one place and a fault in one
-- job cannot take the match loop down with it.
--
-- The scheduler is interval-based rather than banded, because server work is
-- naturally heterogeneous -- the storm ticks at 1 Hz, roster sampling at 2 Hz,
-- delta flushes at 4 Hz -- and forcing those into three fixed bands would mean
-- either running work too often or adding manual counters everywhere.
--
-- WHY THIS MOVED OUT OF br_core (2026-08-09, M9). It lived in
-- br_core/server/main.lua, which meant a second server-side resource had no
-- scheduler at all: br_ringmaster would have had to either copy this file or
-- spawn raw Citizen.CreateThread loops, and this project does not do the
-- second. Moving it here costs nothing -- it was already pure enough to unit
-- test, since step() takes the clock as a parameter -- and every consuming
-- resource now gets its own independent registry, its own /brperf accounting,
-- and its own suspension state. That separation is the point rather than a side
-- effect: a wedged moderation job must not appear in the gamemode's numbers,
-- and vice versa.
--
-- ONE REGISTRY PER LUA STATE, and FiveM gives each resource its own, so
-- `jobs` below is genuinely per-resource despite looking like a global.
--
-- Note this file defines start() but never calls it. br_lib registers nothing
-- and schedules nothing at load time -- the consuming resource decides when its
-- clock begins.

BR = BR or {}

BR.Sched = {}

local jobs = {}
local started = false
local MAX_CONSECUTIVE_ERRORS = 5

-- Whoever is loading us, for log lines. Resolved lazily and defensively: this
-- is only ever reached on an error path, and a scheduler that throws while
-- reporting a throw is a bad way to find out about the first one.
local function who()
    local ok, name = pcall(GetCurrentResourceName)
    return (ok and name) or 'br_lib'
end

-- GetGameTimer only, matching the client. The `os` library IS available in the
-- server runtime, unlike the client -- but using one clock on both sides means
-- /brperf reads the same way wherever you run it, and removes a difference
-- nobody would remember later.
--
-- Resolution is 1ms, so a single sub-millisecond job measures as 0. Totals
-- accumulated over many calls are what carry the signal; see the longer note in
-- client/main.lua.
-- Named clockMs, not nowMs, on purpose: BR.Sched.step takes a `nowMs` parameter,
-- and a local function of the same name would be shadowed inside it -- turning
-- every `nowMs()` call into "attempt to call a number value" at runtime. Syntax
-- checks do not catch that; the scheduler tests do.
local function clockMs()
    return GetGameTimer()
end

--- Register a repeating job.
---
--- @param intervalMs integer  how often to run
--- @param name string         unique, shown in /brperf
--- @param fn function         receives (dtMs) since the job last ran
--- @return table handle
function BR.Sched.every(intervalMs, name, fn)
    if type(fn) ~= 'function' then
        error(('BR.Sched.every: "%s" needs a function'):format(tostring(name)), 2)
    end
    for _, j in ipairs(jobs) do
        if j.name == name then
            error(('BR.Sched.every: duplicate job name "%s"'):format(name), 2)
        end
    end

    local job = {
        name        = name,
        fn          = fn,
        interval    = intervalMs,
        nextRun     = 0,
        lastRun     = 0,
        enabled     = true,
        suspended   = false,
        dead        = false,
        calls       = 0,
        totalMs     = 0.0,
        peakMs      = 0.0,
        errors      = 0,
        consecutive = 0,
    }
    jobs[#jobs + 1] = job
    return job
end

--- Stop a job. Takes effect immediately; the entry is swept after the pass.
function BR.Sched.cancel(handle)
    if handle then handle.dead = true end
end

--- @param name string
--- @param enabled boolean
--- @return boolean found
function BR.Sched.setEnabled(name, enabled)
    for _, j in ipairs(jobs) do
        if j.name == name then
            j.enabled = enabled and true or false
            if enabled then
                j.suspended, j.consecutive = false, 0
            end
            return true
        end
    end
    return false
end

--- @return table array of per-job stats, most expensive first
function BR.Sched.stats()
    local out = {}
    for _, j in ipairs(jobs) do
        out[#out + 1] = {
            name       = j.name,
            intervalMs = j.interval,
            calls      = j.calls,
            avgMs      = j.calls > 0 and (j.totalMs / j.calls) or 0.0,
            totalMs    = j.totalMs,
            peakMs     = j.peakMs,
            errors     = j.errors,
            enabled    = j.enabled,
            suspended  = j.suspended,
        }
    end
    table.sort(out, function(a, b) return a.totalMs > b.totalMs end)
    return out
end

function BR.Sched.resetStats()
    for _, j in ipairs(jobs) do
        j.calls, j.totalMs, j.peakMs = 0, 0.0, 0.0
    end
end

--- Run one scheduler pass. Public so it can be driven manually in tests.
--- @param nowMs integer
function BR.Sched.step(nowMs)
    local swept = false

    for i = 1, #jobs do
        local j = jobs[i]
        if j.dead then
            swept = true
        elseif j.enabled and not j.suspended and nowMs >= j.nextRun then
            local dt = j.lastRun > 0 and (nowMs - j.lastRun) or 0
            j.lastRun = nowMs
            j.nextRun = nowMs + j.interval

            local s = clockMs()
            local ok, err = pcall(j.fn, dt)
            local elapsed = clockMs() - s

            j.calls  = j.calls + 1
            j.totalMs = j.totalMs + elapsed
            if elapsed > j.peakMs then j.peakMs = elapsed end

            if ok then
                j.consecutive = 0
            else
                j.errors      = j.errors + 1
                j.consecutive = j.consecutive + 1
                print(('[%s] job "%s" errored: %s'):format(who(), j.name, tostring(err)))
                if j.consecutive >= MAX_CONSECUTIVE_ERRORS then
                    j.suspended = true
                    print(('[%s] suspending job "%s" after %d consecutive errors; /brjob enable %s')
                        :format(who(), j.name, j.consecutive, j.name))
                end
            end
        end
    end

    if swept then
        for i = #jobs, 1, -1 do
            if jobs[i].dead then table.remove(jobs, i) end
        end
    end
end

--- Start the scheduler thread. Ticks at 50ms, which is finer than the fastest
--- job (4 Hz) so intervals are honoured without jitter mattering.
---
--- Idempotent, and each resource calls it for itself.
function BR.Sched.start()
    if started then return end
    started = true
    Citizen.CreateThread(function()
        while true do
            BR.Sched.step(GetGameTimer())
            Citizen.Wait(50)
        end
    end)
end
