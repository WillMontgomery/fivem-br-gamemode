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
-- br_core as a whole. So the registry has to recover that attribution itself.
--
-- It cannot do so by putting a stopwatch around each call. See the TIMING block
-- below: this runtime has no clock that moves within a frame, so that stopwatch
-- reads exactly zero no matter what the callback costs, which is what it did in
-- shipped builds for months. Attribution here is on demand instead, through
-- BR.Loop.bench and BR.Loop.ab, both of which measure across frame boundaries
-- because that is the only interval this client can see.

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

-- TIMING -- WHY THIS FILE MEASURED NOTHING FOR MONTHS. READ BEFORE CHANGING.
--
-- GetGameTimer() is the only general-purpose clock a FiveM CLIENT script has.
-- The `os` library is sandboxed out of the client runtime, so os.clock() is not
-- available; the profiler natives (ProfilerEnterScope/ExitScope) do record at
-- high resolution but their results only leave the game as a Chrome DevTools
-- trace and cannot be read back into Lua. There is no sub-frame clock.
--
-- THE FAILURE. GetGameTimer is not merely coarse, it is FRAME-STAMPED: it is
-- latched once per rendered frame and returns that same integer for every call
-- made during that frame. (client/dbno.lua has relied on this for years -- "a
-- reading of GetGameTimer on a machine that has just started".) So:
--
--     local s = GetGameTimer()
--     fn()                        -- runs entirely inside this frame
--     local elapsed = GetGameTimer() - s
--
-- is not "0 because fn was faster than a millisecond". It is EXACTLY 0, on
-- every call, for every callback, for ever -- and it would still be exactly 0
-- if fn took nine milliseconds, because the latch does not move until the frame
-- ends. Summing it accumulates zero. peak stays 0 across any number of passes.
-- The whole band pass is inside one frame too, so the band totals were the same
-- zero from the same source. That is the /brperf the user pasted: 66 callbacks
-- reading "<1ms, never measurable" and three bands reading "avg 0.000 peak 0".
--
-- The tell was in the same file: noteFrame() brackets ACROSS frames and has
-- always produced sensible numbers (a 66ms worst frame, populated buckets).
-- One clock, real between frames, identically zero within one.
--
-- WHAT REPLACED IT. The only quantity this runtime can resolve is a
-- frame-boundary delta, so every real measurement here is expressed as one:
--
--   * BR.Loop.bench  AMPLIFIES. Run a callback N times inside a single frame
--                    and that frame gets longer by N x its cost. Measure the
--                    frame, subtract an idle frame measured the same way, and
--                    divide by N. Resolution is 1ms/N -- at N=256 that is four
--                    MICROseconds per call, from a clock that cannot see a
--                    millisecond.
--   * BR.Loop.ab     DIFFERENCES. Hold a callback off for a block of frames,
--                    on for the next, and compare median frame time. Slower and
--                    noisier, but it is the only one that catches cost the
--                    engine pays on our behalf AFTER the Lua call returns --
--                    draws, blips, DUI. bench cannot see any of that.
--
-- Both reduce through pure functions (reduceBench / reduceAB) that return
-- resolved=false rather than 0.0 when the samples cannot support a number.
-- THAT distinction is the whole bug: a stopwatch that reads zero must say "I
-- did not measure", never "it cost nothing". tools/test_loop.lua pins it.

-- ═══ AND THE SAME STOPWATCH, READ CORRECTLY, IS A STALL DETECTOR ═══
--
-- Kept, and kept ON, for a reason discovered after the above was written. A
-- frame-stamped clock cannot report a COST -- but it can report that a call
-- SPANNED A FRAME, because that is the only way its reading ever leaves zero.
-- A per-frame callback that spans a frame is precisely a hitch.
--
-- Owner's capture, 2026-08-23: one pass of airdrop.render in 113,237 came back
-- at 55ms, every other sample in the registry was 0, and total == peak, so it
-- happened exactly once. That is a named suspect for a real stall, out of the
-- very mechanism this block was about to switch off for being useless.
--
-- So `stalls` is counted and `peakMs` kept, and NOTHING may divide those ms by
-- the call count and call it an average -- 55/113237 is the 0.000 that sat
-- beside the 55 and made an operator distrust the tool. Cost still comes from
-- bench and ab; this answers a different question.
--
-- `timingOn` no longer gates collection. It records only whether probeClock()
-- found a clock that moves WITHIN a frame, which decides whether a per-call
-- COST could ever be read straight off the accumulators. On stock FiveM: no.
local timingOn = false

-- nil = not probed yet. Set by BR.Loop.probeClock().
local clockProbe = nil

local function median(t)
    local n = #t
    if n == 0 then return nil end
    local c = table.move(t, 1, n, 1, {})
    table.sort(c)
    if n % 2 == 1 then return c[(n + 1) // 2] end
    return (c[n // 2] + c[n // 2 + 1]) / 2.0
end

--- Prove, on this machine, whether an in-frame elapsed time can ever be
--- non-zero -- rather than assuming it either way.
---
--- Busy-works in doubling blocks and watches for the game timer to move. If it
--- never moves across a spin far longer than a millisecond, the clock is
--- frame-stamped and per-call timing is structurally impossible here. Lazy and
--- memoised: nothing pays for this until a debug command asks.
---
--- @param cap integer|nil  iteration ceiling (default 2^20)
--- @return table { moved, iterations, resolvable }
function BR.Loop.probeClock(cap)
    if clockProbe then return clockProbe end

    local limit = cap or (1 << 20)
    local t0, n, spin = GetGameTimer(), 0, 0.0
    local block = 1024
    while n < limit do
        for i = 1, block do spin = spin + i * 0.5 end
        n = n + block
        if GetGameTimer() ~= t0 then break end
        block = block * 2
    end

    local moved = (GetGameTimer() - t0) > 0
    clockProbe = { moved = moved, iterations = n, resolvable = moved, _spin = spin }
    timingOn = moved
    return clockProbe
end

--- What the instrument can and cannot measure right now. Printers must consult
--- this before reporting a per-callback number OR concluding from its absence.
--- @return table { perCallResolvable, probed, probeIterations }
function BR.Loop.timing()
    return {
        perCallResolvable = timingOn,
        probed            = clockProbe ~= nil,
        probeIterations   = clockProbe and clockProbe.iterations or 0,
    }
end

-- Band-level accumulators, keyed by band.
local bandStats = {}

-- FRAME-TIME HISTOGRAM -- the hitch detector.
--
-- Per-callback averages cannot find a hitch, and that is not a flaw in them:
-- a stall of 40ms once every few seconds moves an average by a rounding error
-- while being the only thing the player actually notices. What matters is the
-- DISTRIBUTION and the tail.
--
-- This measures the gap between successive FRAME passes, which is the real
-- frame time -- our callbacks, every other resource, and the engine itself.
-- That is deliberate: it answers "is the client hitching" first, and only then
-- "is it us", which is the order those questions have to be asked in. If the
-- frame histogram shows stalls and the band totals do not, the stall is not
-- ours.
local BUCKETS = { 17, 25, 34, 50, 100 }   -- ms; last bucket is everything above
local frameStats = {
    samples = 0,
    lastAt  = 0,
    worstMs = 0,
    counts  = { 0, 0, 0, 0, 0, 0 },
    -- What the worst frame cost, per callback, so a spike has a suspect
    -- attached rather than just a number.
    worstBy = nil,
}

local function noteFrame(now)
    local last = frameStats.lastAt
    frameStats.lastAt = now
    if last <= 0 then return end

    local dt = now - last
    frameStats.samples = frameStats.samples + 1

    local slot = #BUCKETS + 1
    for i = 1, #BUCKETS do
        if dt < BUCKETS[i] then slot = i break end
    end
    frameStats.counts[slot] = frameStats.counts[slot] + 1

    if dt > frameStats.worstMs then
        frameStats.worstMs = dt
        -- Snapshot who was expensive on the pass that produced it.
        --
        -- WHAT A NAME IN THIS LIST MEANS, AND WHAT AN EMPTY LIST DOES NOT.
        --
        -- A callback appears here only if its own call spanned a frame, so a
        -- name here is strong evidence and worth acting on -- this is what put
        -- airdrop.render's 55ms next to the frame it happened on.
        --
        -- An EMPTY list is much weaker than it reads. It rules out a callback
        -- that stalled ACROSS a frame; it says nothing at all about one that
        -- burned 9ms inside a single frame, because the clock cannot see that.
        -- /brhitch used to turn the empty list straight into "the stall was
        -- very likely NOT br_core", and that conclusion did not follow.
        local by = {}
        for band, list in pairs(registry) do
            for _, e in ipairs(list) do
                if (e.lastMs or 0) > 0 then
                    by[#by + 1] = { name = e.name, band = band, ms = e.lastMs }
                end
            end
        end
        table.sort(by, function(a, b) return a.ms > b.ms end)
        frameStats.worstBy = by
    end
end

--- Reduce paired frame durations into a per-call cost. PURE -- no natives, no
--- clock -- which is the point: this is where "measured zero" and "could not
--- measure" are told apart, and it is unit-tested.
---
--- `base` are the durations of idle frames, `burst` the durations of frames
--- that additionally ran the callback `iterations` times. Medians, not means:
--- one streamed asset landing mid-run must not become the answer.
---
--- @param base table       array of frame durations, ms
--- @param burst table      array of frame durations, ms, same run
--- @param iterations integer
--- @return table { resolved, reason, perCallMs, deltaMs, baseMs, burstMs, spreadMs }
function BR.Loop.reduceBench(base, burst, iterations)
    local out = { resolved = false, iterations = iterations }

    if not iterations or iterations < 1 then
        out.reason = 'no iterations'
        return out
    end
    if #base < 3 or #burst < 3 then
        out.reason = ('too few samples (base %d, burst %d; need 3)'):format(#base, #burst)
        return out
    end

    -- THE BUG THIS FUNCTION EXISTS FOR. Every sample identically zero does not
    -- mean the work was free, it means the clock never moved -- which is
    -- precisely what a frame-stamped GetGameTimer does to any in-frame
    -- measurement. Reporting 0.0000ms/call here is how the old instrument lied.
    local allZero = true
    for _, v in ipairs(base)  do if v ~= 0 then allZero = false break end end
    if allZero then
        for _, v in ipairs(burst) do if v ~= 0 then allZero = false break end end
    end
    if allZero then
        out.reason = 'clock never advanced across any sample -- not a measurement'
        return out
    end

    local b, s = median(base), median(burst)
    out.baseMs, out.burstMs = b, s
    out.deltaMs = s - b

    -- Spread of the burst frames, as an honest error bar.
    local lo, hi = math.huge, -math.huge
    for _, v in ipairs(burst) do
        if v < lo then lo = v end
        if v > hi then hi = v end
    end
    out.spreadMs = hi - lo

    -- The burst has to clear the clock's own quantum, or the difference is
    -- indistinguishable from rounding. Report the CEILING it proves instead of
    -- a fabricated point value.
    if out.deltaMs < 1 then
        out.reason      = 'below the resolution floor'
        out.perCallMaxMs = 1.0 / iterations
        return out
    end

    out.resolved  = true
    out.perCallMs = out.deltaMs / iterations
    return out
end

--- Reduce two blocks of frame durations -- callback on vs callback off -- into
--- an in-situ cost. Also pure, also unit-tested.
--- @param on table   frame durations with the callback enabled
--- @param off table  frame durations with it disabled
--- @return table { resolved, reason, onMs, offMs, deltaMs, samples }
function BR.Loop.reduceAB(on, off)
    local out = { resolved = false, samples = math.min(#on, #off) }

    if #on < 10 or #off < 10 then
        out.reason = ('too few frames (on %d, off %d; need 10)'):format(#on, #off)
        return out
    end

    local allZero = true
    for _, v in ipairs(on)  do if v ~= 0 then allZero = false break end end
    if allZero then
        for _, v in ipairs(off) do if v ~= 0 then allZero = false break end end
    end
    if allZero then
        out.reason = 'clock never advanced across any frame -- not a measurement'
        return out
    end

    out.onMs    = median(on)
    out.offMs   = median(off)
    out.deltaMs = out.onMs - out.offMs
    out.resolved = true
    return out
end

--- Per-call cost of one callback, by AMPLIFICATION.
---
--- Runs the callback N extra times inside a single frame, which makes that
--- frame longer by N x its cost, then measures the frame the only way this
--- runtime can -- the gap between two frame stamps. An idle frame measured the
--- same way is subtracted. Effective resolution is 1ms/N.
---
--- YIELDS. It must: the frame stamp does not move until the frame ends, so the
--- measurement is not available until we have waited for the next one. Call it
--- from a thread, not from a loop callback.
---
--- CAUTION: this really runs the callback, thousands of times, out of band.
--- Most are idempotent per-frame draws; a few have side effects. Opt-in per
--- name for that reason.
---
--- @param name string
--- @param iterations integer|nil  calls per burst frame (default 256)
--- @param rounds integer|nil      paired frames to sample (default 9)
--- @param waitFn function|nil     frame yield; injected by the tests
--- @return table|nil  reduceBench result plus { name, band }
function BR.Loop.bench(name, iterations, rounds, waitFn)
    local target, targetBand
    for band, list in pairs(registry) do
        for _, e in ipairs(list) do
            if e.name == name then target, targetBand = e, band end
        end
    end
    if not target then return nil end

    local wait = waitFn or function() Citizen.Wait(0) end
    local n    = iterations or 256
    local r    = rounds or 9

    -- One warm-up pass, so first-call model loads and cache fills are not
    -- charged to the measurement.
    pcall(target.fn, 0)
    wait()

    local base, burst = {}, {}
    for _ = 1, r do
        -- Idle frame.
        local t0 = GetGameTimer()
        wait()
        base[#base + 1] = GetGameTimer() - t0

        -- Burst frame, immediately after, so drift between the two is minimal.
        t0 = GetGameTimer()
        for _ = 1, n do pcall(target.fn, 0) end
        wait()
        burst[#burst + 1] = GetGameTimer() - t0
    end

    local out = BR.Loop.reduceBench(base, burst, n)
    out.name, out.band = name, targetBand
    return out
end

--- In-situ cost of one callback, by DIFFERENCE.
---
--- Alternates blocks of frames with the callback disabled and enabled, and
--- compares median frame time. Slower and noisier than bench, and the only
--- thing here that can see cost the ENGINE pays for us after the Lua call
--- returns -- a draw submitted, a blip maintained, a DUI surface composited.
--- For anything that draws, this is the number that matters.
---
--- YIELDS, for the same reason bench does.
---
--- @param name string
--- @param blocks integer|nil       on/off pairs (default 6)
--- @param blockFrames integer|nil  frames per block (default 30)
--- @param waitFn function|nil      frame yield; injected by the tests
--- @return table|nil  reduceAB result plus { name, band, blocks, blockFrames }
function BR.Loop.ab(name, blocks, blockFrames, waitFn)
    local target, targetBand
    for band, list in pairs(registry) do
        for _, e in ipairs(list) do
            if e.name == name then target, targetBand = e, band end
        end
    end
    if not target then return nil end

    local wait = waitFn or function() Citizen.Wait(0) end
    local nb   = blocks or 6
    local bf   = blockFrames or 30
    local was  = target.enabled

    local on, off = {}, {}
    local function sample(into)
        local t0 = GetGameTimer()
        wait()
        into[#into + 1] = GetGameTimer() - t0
    end

    for _ = 1, nb do
        target.enabled = false
        wait()                                  -- let the change take effect
        for _ = 1, bf do sample(off) end
        target.enabled = true
        wait()
        for _ = 1, bf do sample(on) end
    end
    target.enabled = was

    local out = BR.Loop.reduceAB(on, off)
    out.name, out.band = name, targetBand
    out.blocks, out.blockFrames = nb, bf
    return out
end

--- Every registered callback name, for tooling that wants to walk them.
--- @return table
function BR.Loop.names()
    local out = {}
    for band, list in pairs(registry) do
        for _, e in ipairs(list) do
            out[#out + 1] = { name = e.name, band = band }
        end
    end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
end

--- Frame-time distribution since the last reset.
--- @return table { samples, worstMs, worstBy, buckets = { {upTo, count}, ... } }
function BR.Loop.frameStats()
    local buckets = {}
    for i = 1, #BUCKETS do
        buckets[i] = { upTo = BUCKETS[i], count = frameStats.counts[i] }
    end
    buckets[#BUCKETS + 1] = { upTo = nil, count = frameStats.counts[#BUCKETS + 1] }
    return {
        samples = frameStats.samples,
        worstMs = frameStats.worstMs,
        worstBy = frameStats.worstBy,
        buckets = buckets,
        -- Frame GAPS are real on this runtime -- they bracket across frames,
        -- which is the one thing the stamp can see.
        --
        -- `attributable` says whether a per-call COST could be read off the
        -- accumulators (it cannot, here). It is NOT what gates worstBy: a
        -- callback that spanned a frame lands in that list either way, and
        -- that is the useful half. What it gates is the CONCLUSION drawn from
        -- an empty list, which is where the old tool went wrong.
        attributable = timingOn,
    }
end

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
        stalls     = 0,      -- passes that SPANNED A FRAME; see BR.Loop.step
        totalMs    = 0.0,
        peakMs     = 0.0,
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
---
--- `calls` and `stalls` are real. `stalls` counts the passes whose in-frame
--- reading left zero, which on this runtime can only happen by SPANNING A
--- FRAME -- so it is a stall count, not a cost. peakMs sizes the worst one and
--- avgStallMs averages over the stalls rather than over the calls. There is
--- deliberately no per-call average here; see BR.Loop.bench for cost.
--- @return table  array of { name, band, calls, stalls, totalMs, peakMs, avgStallMs, errors, enabled, suspended }
function BR.Loop.stats()
    local out = {}
    for band, list in pairs(registry) do
        for _, e in ipairs(list) do
            out[#out + 1] = {
                name      = e.name,
                band      = band,
                calls     = e.calls,
                stalls    = e.stalls,
                -- Averaged over the STALLS, never over the calls. The old
                -- totalMs/calls is what printed 0.000 beside a 55ms peak.
                avgStallMs = e.stalls > 0 and (e.totalMs / e.stalls) or 0.0,
                totalMs   = e.totalMs,
                peakMs    = e.peakMs,
                errors    = e.errors,
                enabled   = e.enabled,
                suspended = e.suspended,
            }
        end
    end
    table.sort(out, function(a, b) return a.totalMs > b.totalMs end)
    return out
end

--- Band-level pass accounting. `passes` is real; the ms figures are
--- a stall count, on the same terms as BR.Loop.stats above.
--- @return table  [band] = { passes, stalls, totalMs, peakMs, avgStallMs }
function BR.Loop.bandStats()
    local out = {}
    for band, bs in pairs(bandStats) do
        out[band] = {
            passes  = bs.passes,
            stalls  = bs.stalls,
            totalMs = bs.totalMs,
            peakMs  = bs.peakMs,
            -- Deliberately NOT offered as an average cost. See BR.Loop.step:
            -- these ms only accrue on passes that spanned a frame, so dividing
            -- them by every pass produces the 0.000 that sat next to a 55ms
            -- peak and made the whole tool look like it was lying.
            avgStallMs = bs.stalls > 0 and (bs.totalMs / bs.stalls) or 0.0,
        }
    end
    return out
end

--- Clear the perf accumulators so the next sample covers a fresh window.
function BR.Loop.resetStats()
    for _, list in pairs(registry) do
        for _, e in ipairs(list) do
            e.calls, e.stalls, e.totalMs, e.peakMs, e.lastMs = 0, 0, 0.0, 0.0, 0.0
        end
    end
    for _, bs in pairs(bandStats) do
        bs.passes, bs.stalls, bs.totalMs, bs.peakMs = 0, 0, 0, 0
    end
    frameStats.samples, frameStats.worstMs = 0, 0
    frameStats.worstBy, frameStats.lastAt = nil, 0
    for i = 1, #frameStats.counts do frameStats.counts[i] = 0 end
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

    -- Only the frame band is a frame. TICK and SLOW passes say nothing about
    -- how smooth the picture is.
    if band == BR.Loop.FRAME then noteFrame(t) end

    for i = 1, #list do
        local e = list[i]
        if e.dead then
            swept = true
        elseif e.enabled and not e.suspended then
            local dt = e.lastRun > 0 and (t - e.lastRun) or 0
            e.lastRun = t

            -- ═══ WHAT THIS STOPWATCH ACTUALLY MEASURES ═══
            --
            -- Not cost. The clock is latched per frame, so `elapsed` is 0 for a
            -- free callback and 0 for a nine-millisecond one alike. It can only
            -- come back non-zero when the call SPANNED A FRAME BOUNDARY -- the
            -- callback yielded, or blocked the main thread long enough for the
            -- engine to re-latch.
            --
            -- That makes it useless as a cost meter and rather good as a STALL
            -- DETECTOR, which is what the frame band actually needs: a per-frame
            -- callback that spans a frame is, by definition, a hitch, and this
            -- is the only thing in the project that can name which one.
            --
            -- It earned its keep on 2026-08-23: one pass of airdrop.render in
            -- 113,237 came back at 55ms and every other sample in the whole
            -- registry was 0. That is a real event with a real suspect attached.
            --
            -- So `stalls` is the number to read and `peakMs` is the size of the
            -- worst one. totalMs/avgMs are kept only because the fields are
            -- public; nothing may present them as a per-call cost, because a
            -- total built from a sea of zeros plus one spike divided by 113,237
            -- calls is 0.000 and means nothing at all. Cost comes from
            -- BR.Loop.bench and BR.Loop.ab.
            e.calls = e.calls + 1
            local s = GetGameTimer()
            local ok, err = pcall(e.fn, dt)
            local elapsed = GetGameTimer() - s
            e.lastMs = elapsed              -- for the hitch snapshot
            if elapsed > 0 then
                e.stalls  = e.stalls + 1
                e.totalMs = e.totalMs + elapsed
                if elapsed > e.peakMs then e.peakMs = elapsed end
            end

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

    -- Pass accounting. `passes` is real. The wall-clock cost is NOT the
    -- "trustworthy absolute number" this comment used to claim it was: a whole
    -- band pass runs inside a single frame, so on a frame-stamped clock
    -- `GetGameTimer() - bandStart` is exactly 0 every time, which is why all
    -- three bands reported avg 0.000ms peak 0ms over 6391 passes. Same zero,
    -- same source as the per-callback columns. Only accumulated when the probe
    -- says an in-frame delta can move at all.
    local bs = bandStats[band]
    if not bs then
        bs = { passes = 0, stalls = 0, totalMs = 0, peakMs = 0 }
        bandStats[band] = bs
    end
    bs.passes = bs.passes + 1
    local elapsedMs = GetGameTimer() - bandStart
    if elapsedMs > 0 then
        bs.stalls  = bs.stalls + 1
        bs.totalMs = bs.totalMs + elapsedMs
        if elapsedMs > bs.peakMs then bs.peakMs = elapsedMs end
    end
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
    party    = nil,  -- persistent party, pushed by the server; survives a match
    storm    = nil,  -- the published storm record; solved locally via BR.StormAt
    alive    = 0,
    squadsAlive = 0,
    -- MY OWN FEET, ON MY OWN SCREEN. Set by client/skydive.lua the frame the
    -- drop machine sees touchdown; cleared out of the plane door and at the
    -- start of every round.
    --
    -- The ONE piece of match state this client is allowed to answer for
    -- itself, and it is not an exception to the mirror rule -- it is the rule:
    -- a client may observe its own ped, and may not observe anything else. It
    -- decides only what this machine DRAWS and what it will let this player
    -- reach for (client/inventory.lua, client/loot.lua, the HUD envelope). No
    -- authoritative question reads it: whether a pickup succeeded, whether a
    -- bullet counted and where the player placed all remain the server's,
    -- keyed on the state the server holds.
    --
    -- It exists because the server's ALIVE arrives by way of the landing
    -- report, which goes missing often enough to have a retry loop AND a
    -- server-side rescue net -- and until it lands, everything the player has
    -- is switched off (#126).
    landed   = false,
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
