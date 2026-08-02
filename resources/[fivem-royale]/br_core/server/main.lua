-- Server bootstrap and the tick scheduler.
--
-- The server mirror of the client's loop registry. Same reasoning: every
-- subsystem registers a job here rather than spawning its own thread, so the cost
-- of the whole gamemode is measurable in one place and a fault in one job cannot
-- take the match loop down with it.
--
-- The scheduler is interval-based rather than banded, because server work is
-- naturally heterogeneous -- the storm ticks at 1 Hz, roster sampling at 2 Hz,
-- delta flushes at 4 Hz -- and forcing those into three fixed bands would mean
-- either running work too often or adding manual counters everywhere.

BR = BR or {}

BR.Sched = {}

local jobs = {}
local started = false
local MAX_CONSECUTIVE_ERRORS = 5

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
                print(('[br_core] job "%s" errored: %s'):format(j.name, tostring(err)))
                if j.consecutive >= MAX_CONSECUTIVE_ERRORS then
                    j.suspended = true
                    print(('[br_core] suspending job "%s" after %d consecutive errors; /brjob enable %s')
                        :format(j.name, j.consecutive, j.name))
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

-- ---------------------------------------------------------------------------
-- Server state.
--
-- This is the authority. Nothing here is derived from anything a client said,
-- and nothing here depends on players being in each other's scope -- which is
-- what makes it survive OneSync big mode at 48 players spread across the map.
-- ---------------------------------------------------------------------------

BR.Server = {
    devMode  = false,
    matchId  = 0,

    match = {
        state  = BR.MatchState.WAITING,
        mode   = BR.Mode.SOLO.key,
        endsAt = 0,
        bucket = 0,
    },

    -- roster[src] = { src, name, license, squadId, state, hp, armour, pos, ... }
    -- Populated from the server-side playerJoining / playerDropped events, which
    -- are global and unaffected by entity scoping.
    roster = {},

    -- squads[squadId] = { id, members = { src, ... }, colour, alive, placement }
    squads = {},

    storm = nil,
}

--- Count players in the roster matching an optional predicate.
--- @param pred function|nil
--- @return integer
function BR.Server.count(pred)
    local n = 0
    for _, p in pairs(BR.Server.roster) do
        if not pred or pred(p) then n = n + 1 end
    end
    return n
end

--- How many players are still alive (includes downed -- they are not out yet).
--- @return integer
function BR.Server.aliveCount()
    return BR.Server.count(function(p)
        return p.state == BR.PlayerState.ALIVE
            or p.state == BR.PlayerState.DBNO
            or p.state == BR.PlayerState.BUS
            or p.state == BR.PlayerState.FREEFALL
            or p.state == BR.PlayerState.GLIDE
    end)
end

--- How many squads still have at least one living member. This is the win
--- condition, not the player count -- a four-stack with three dead is one squad.
--- @return integer
function BR.Server.squadsAlive()
    local seen, n = {}, 0
    for _, p in pairs(BR.Server.roster) do
        local living = p.state == BR.PlayerState.ALIVE
                    or p.state == BR.PlayerState.DBNO
                    or p.state == BR.PlayerState.BUS
                    or p.state == BR.PlayerState.FREEFALL
                    or p.state == BR.PlayerState.GLIDE
        if living then
            -- Solo players have no squad; each counts as their own team.
            local key = p.squadId or ('solo:' .. tostring(p.src))
            if not seen[key] then
                seen[key] = true
                n = n + 1
            end
        end
    end
    return n
end

AddEventHandler('onResourceStart', function(res)
    if res ~= GetCurrentResourceName() then return end

    BR.Server.devMode = GetConvar('sv_devMode', 'false') == 'true'
        or GetConvar('br_devMode', 'false') == 'true'

    BR.Sched.start()

    print('[br_core] server started')
    print(('[br_core]   devMode      %s'):format(tostring(BR.Server.devMode)))
    print(('[br_core]   maxPlayers   %d (free OneSync ceiling is 48)')
        :format(BR.Config.Match.maxPlayers))
    print(('[br_core]   minToStart   %d'):format(BR.Config.Match.MinPlayers(BR.Server.devMode)))
    print(('[br_core]   match length ~%.0f min planned')
        :format(BR.Config.Storm.TotalSeconds() / 60.0))
end)
