-- Unit tests for the br_core client loop registry.
--
-- The registry is the performance contract of the whole project and it has real
-- logic in it -- error suspension, deferred sweeping, perf accounting -- so it is
-- worth testing outside the game. FiveM natives are stubbed below; the registry
-- itself is exercised for real via BR.Loop.step().

-- ------------------------------------------------------------ native stubs ---

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetPlayerServerId() return 1 end
function PlayerId() return 0 end

local printed = {}
local realPrint = print
function print(s) printed[#printed + 1] = tostring(s) end

Citizen = {
    CreateThread = function() end,  -- loops are stepped manually in these tests
    Wait         = function() end,
}

local handlers = {}
function AddEventHandler(name, fn) handlers[name] = fn end
function GetCurrentResourceName() return 'br_core' end

-- br_core/client/main.lua expects br_lib's enums to already be loaded.
local ROOT = 'resources/[fivem-royale]/'
for _, f in ipairs({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/rng.lua',
    'br_lib/shared/geo.lua',
    'br_lib/shared/clock.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    'br_lib/shared/storm_solve.lua',
    'br_core/client/main.lua',
}) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

-- Each test gets a clean band by unregistering everything first.
local function clearAll()
    for _, band in ipairs({ BR.Loop.FRAME, BR.Loop.TICK, BR.Loop.SLOW }) do
        for _, s in ipairs(BR.Loop.stats()) do
            if s.band == band then BR.Loop.setEnabled(s.name, false) end
        end
    end
end

-- --------------------------------------------------------------- register ---

describe('register')
do
    local ran = 0
    local h = BR.Loop.register(BR.Loop.FRAME, 't.basic', function() ran = ran + 1 end)
    ok(h ~= nil, 'returns a handle')

    BR.Loop.step(BR.Loop.FRAME)
    ok(ran == 1, 'callback runs once per step')
    BR.Loop.step(BR.Loop.FRAME)
    ok(ran == 2, 'and again on the next step')

    local dupOk = pcall(BR.Loop.register, BR.Loop.FRAME, 't.basic', function() end)
    ok(not dupOk, 'duplicate names are rejected')

    local badBand = pcall(BR.Loop.register, 'nonsense', 't.x', function() end)
    ok(not badBand, 'unknown band is rejected')

    local badFn = pcall(BR.Loop.register, BR.Loop.FRAME, 't.y', 'not a function')
    ok(not badFn, 'non-function callback is rejected')

    BR.Loop.unregister(h)
    BR.Loop.step(BR.Loop.FRAME)
    local after = ran
    BR.Loop.step(BR.Loop.FRAME)
    ok(ran == after, 'unregistered callback stops running')
end

describe('bands')
do
    local f, t, s = 0, 0, 0
    BR.Loop.register(BR.Loop.FRAME, 't.band.f', function() f = f + 1 end)
    BR.Loop.register(BR.Loop.TICK,  't.band.t', function() t = t + 1 end)
    BR.Loop.register(BR.Loop.SLOW,  't.band.s', function() s = s + 1 end)

    BR.Loop.step(BR.Loop.FRAME)
    ok(f == 1 and t == 0 and s == 0, 'stepping one band does not run the others')

    BR.Loop.step(BR.Loop.TICK)
    BR.Loop.step(BR.Loop.SLOW)
    ok(f == 1 and t == 1 and s == 1, 'each band runs independently')

    BR.Loop.setEnabled('t.band.f', false)
    BR.Loop.step(BR.Loop.FRAME)
    ok(f == 1, 'disabled callbacks do not run')

    BR.Loop.setEnabled('t.band.f', true)
    BR.Loop.step(BR.Loop.FRAME)
    ok(f == 2, 're-enabled callbacks resume')

    ok(BR.Loop.setEnabled('t.does.not.exist', true) == false,
        'setEnabled reports an unknown name')
end

-- ------------------------------------------------------- error containment ---

describe('error containment')
do
    -- A crash in one subsystem must not stop the others in the same band. The
    -- storm damage path and the loot renderer share the frame loop; a broken
    -- renderer must not stop the storm.
    local survivorRan = 0
    BR.Loop.register(BR.Loop.FRAME, 't.err.thrower', function() error('boom') end)
    BR.Loop.register(BR.Loop.FRAME, 't.err.survivor', function() survivorRan = survivorRan + 1 end)

    BR.Loop.step(BR.Loop.FRAME)
    ok(survivorRan == 1, 'a throwing callback does not stop the rest of the band')

    -- After repeated failures the callback is suspended so it cannot flood the
    -- console and bury the original fault.
    for _ = 1, 10 do BR.Loop.step(BR.Loop.FRAME) end

    local thrower
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 't.err.thrower' then thrower = s end
    end
    ok(thrower ~= nil and thrower.suspended, 'a persistently failing callback is suspended')
    ok(thrower.errors >= 5, 'errors are counted', ('errors=%s'):format(thrower and thrower.errors))
    ok(survivorRan == 11, 'the healthy callback kept running throughout',
        ('ran=%d'):format(survivorRan))

    local errBefore = thrower.errors
    BR.Loop.step(BR.Loop.FRAME)
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 't.err.thrower' then thrower = s end
    end
    ok(thrower.errors == errBefore, 'a suspended callback stops being called at all')

    BR.Loop.setEnabled('t.err.thrower', true)
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 't.err.thrower' then thrower = s end
    end
    ok(not thrower.suspended, 're-enabling clears the suspension')

    BR.Loop.setEnabled('t.err.thrower', false)
    BR.Loop.setEnabled('t.err.survivor', false)
end

-- ------------------------------------------ unregister during iteration ----

describe('unregister during iteration')
do
    -- REGRESSION: removing an entry mid-pass used to shuffle the array and make
    -- the loop skip whichever callback followed it -- a subsystem silently
    -- missing a frame, which is close to impossible to spot from behaviour.
    local aRan, bRan, cRan = 0, 0, 0
    local hA, hB, hC

    hA = BR.Loop.register(BR.Loop.SLOW, 't.it.a', function() aRan = aRan + 1 end)
    hB = BR.Loop.register(BR.Loop.SLOW, 't.it.b', function()
        bRan = bRan + 1
        BR.Loop.unregister(hB)   -- remove self, mid-pass
    end)
    hC = BR.Loop.register(BR.Loop.SLOW, 't.it.c', function() cRan = cRan + 1 end)

    BR.Loop.step(BR.Loop.SLOW)
    ok(aRan == 1 and bRan == 1 and cRan == 1,
        'every callback still runs on the pass where one removes itself',
        ('a=%d b=%d c=%d'):format(aRan, bRan, cRan))

    BR.Loop.step(BR.Loop.SLOW)
    ok(bRan == 1, 'the self-removed callback does not run again')
    ok(aRan == 2 and cRan == 2, 'its neighbours are unaffected',
        ('a=%d c=%d'):format(aRan, cRan))

    -- Removing a *different* entry mid-pass is the nastier case, and the one
    -- where the semantics have to be deliberate rather than accidental.
    --
    -- Removal takes effect immediately: a callback unregistered earlier in the
    -- same pass does not run on that pass. Match cleanup unregistering the storm
    -- renderer must not leave it drawing one more frame of a dead storm.
    local dRan, eRan, fRan = 0, 0, 0
    local hD, hE, hF
    hD = BR.Loop.register(BR.Loop.SLOW, 't.it.d', function()
        dRan = dRan + 1
        BR.Loop.unregister(hE)   -- remove the one that comes after us
    end)
    hE = BR.Loop.register(BR.Loop.SLOW, 't.it.e', function() eRan = eRan + 1 end)
    hF = BR.Loop.register(BR.Loop.SLOW, 't.it.f', function() fRan = fRan + 1 end)

    BR.Loop.step(BR.Loop.SLOW)
    ok(dRan == 1, 'the remover ran')
    ok(eRan == 0, 'a callback removed earlier in the pass does not run on that pass')
    ok(fRan == 1, 'the callback AFTER the removed one is not skipped',
        ('this is the array-shuffle regression; f=%d'):format(fRan))

    BR.Loop.step(BR.Loop.SLOW)
    ok(eRan == 0, 'and stays gone')
    ok(dRan == 2 and fRan == 2, 'the survivors keep running',
        ('d=%d f=%d'):format(dRan, fRan))

    BR.Loop.unregister(hA); BR.Loop.unregister(hC)
    BR.Loop.unregister(hD); BR.Loop.unregister(hF)
    BR.Loop.step(BR.Loop.SLOW)
end

-- ------------------------------------------------------------------ perf ---

describe('perf accounting')
do
    BR.Loop.resetStats()
    local h = BR.Loop.register(BR.Loop.TICK, 't.perf', function() end)

    for _ = 1, 7 do BR.Loop.step(BR.Loop.TICK) end

    local found
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 't.perf' then found = s end
    end
    ok(found ~= nil, 'the callback appears in stats')
    ok(found.calls == 7, 'call count is accurate', ('calls=%s'):format(found and found.calls))
    ok(found.enabled and not found.suspended, 'healthy callbacks report as such')
    ok(found.band == BR.Loop.TICK, 'stats carry the band')

    local bands = BR.Loop.bandStats()
    ok(bands[BR.Loop.TICK] ~= nil and bands[BR.Loop.TICK].passes == 7,
        'band pass count is tracked',
        bands[BR.Loop.TICK] and ('passes=%d'):format(bands[BR.Loop.TICK].passes))

    BR.Loop.resetStats()
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 't.perf' then found = s end
    end
    ok(found.calls == 0, 'resetStats clears the window')
    ok(BR.Loop.bandStats()[BR.Loop.TICK].passes == 0, 'resetStats clears band stats too')

    BR.Loop.unregister(h)
end

-- ------------------------------------------------------- timing aggregation ---
--
-- THE SUITE THAT SHOULD HAVE EXISTED FIRST.
--
-- br_core shipped for months with every per-callback cost reading 0.000ms and
-- every band reading "avg 0.000ms peak 0ms" over 6391 passes, and no gate
-- noticed, because nothing here ever asserted that the instrument could produce
-- a non-zero number. The stub above is itself a faithful model of the bug: it
-- freezes GetGameTimer unless a test moves it, exactly as FiveM's frame-stamped
-- clock freezes it within a frame.
--
-- So the property under test is not "the arithmetic is right". It is that the
-- reducers can tell A MEASUREMENT OF ZERO from A FAILURE TO MEASURE, and say
-- so, because reporting the second as the first is the entire defect.

describe('reduceBench')
do
    -- The exact shape of the shipped bug: the clock never moved, so every
    -- sample is 0. The honest answer is "no measurement", never "0ms/call".
    local frozen = BR.Loop.reduceBench({ 0, 0, 0, 0, 0 }, { 0, 0, 0, 0, 0 }, 256)
    ok(not frozen.resolved, 'a frozen clock does not resolve')
    ok(frozen.perCallMs == nil, 'and reports NO number rather than zero',
        ('perCallMs=%s'):format(tostring(frozen.perCallMs)))
    ok(tostring(frozen.reason):find('never advanced') ~= nil,
        'and says why', frozen.reason)

    -- A real amplified measurement. 16ms idle frames; burst frames run the
    -- callback 200 times and cost 36ms; so the callback costs 20/200 = 0.1ms.
    local real = BR.Loop.reduceBench({ 16, 16, 17, 16, 16 }, { 36, 36, 37, 36, 36 }, 200)
    ok(real.resolved, 'a real difference resolves', real.reason)
    ok(math.abs(real.perCallMs - 0.1) < 1e-9,
        'per-call cost is the frame delta over the iteration count',
        ('got %s'):format(tostring(real.perCallMs)))
    ok(real.deltaMs == 20, 'the delta is reported for sanity-checking',
        ('got %s'):format(tostring(real.deltaMs)))

    -- MEDIAN, not mean: one streamed asset landing mid-run must not become the
    -- answer. With a mean, the 300ms outlier below would report ~0.35ms/call.
    local spiked = BR.Loop.reduceBench({ 16, 16, 16, 16, 16 }, { 36, 36, 36, 36, 300 }, 200)
    ok(math.abs(spiked.perCallMs - 0.1) < 1e-9,
        'one hitched sample does not move the answer',
        ('got %s'):format(tostring(spiked.perCallMs)))

    -- Below the floor: the burst did not clear one clock tick. That is not
    -- 0ms/call, it is "cheaper than this many iterations can see", and the
    -- ceiling it proves is the useful thing to say.
    local floored = BR.Loop.reduceBench({ 16, 16, 16, 16 }, { 16, 16, 16, 17 }, 500)
    ok(not floored.resolved, 'a sub-tick difference does not resolve')
    ok(floored.perCallMs == nil, 'and still refuses to invent a number')
    ok(floored.perCallMaxMs == 1.0 / 500,
        'but does report the ceiling it proves',
        ('got %s'):format(tostring(floored.perCallMaxMs)))

    -- More iterations means a lower ceiling. This is the whole reason
    -- amplification works, so it is worth pinning.
    local tighter = BR.Loop.reduceBench({ 16, 16, 16, 16 }, { 16, 16, 16, 17 }, 4000)
    ok(tighter.perCallMaxMs < floored.perCallMaxMs,
        'amplifying harder tightens the bound',
        ('%s vs %s'):format(tostring(tighter.perCallMaxMs), tostring(floored.perCallMaxMs)))

    local thin = BR.Loop.reduceBench({ 16 }, { 36 }, 200)
    ok(not thin.resolved, 'too few samples does not resolve')
    ok(thin.perCallMs == nil, 'and invents nothing')

    local noIter = BR.Loop.reduceBench({ 16, 16, 16 }, { 36, 36, 36 }, 0)
    ok(not noIter.resolved, 'zero iterations does not resolve (no division by it)')
end

describe('reduceAB')
do
    local frozen = {}
    for i = 1, 30 do frozen[i] = 0 end
    local dead = BR.Loop.reduceAB(frozen, frozen)
    ok(not dead.resolved, 'a frozen clock does not resolve here either')
    ok(dead.deltaMs == nil, 'and reports no delta rather than a zero one',
        ('deltaMs=%s'):format(tostring(dead.deltaMs)))

    local on, off = {}, {}
    for i = 1, 30 do on[i], off[i] = 22, 16 end
    local r = BR.Loop.reduceAB(on, off)
    ok(r.resolved, 'on/off blocks resolve', r.reason)
    ok(r.deltaMs == 6, 'the cost is the difference in median frame time',
        ('got %s'):format(tostring(r.deltaMs)))

    -- A callback that costs nothing measurable reads as ~0 -- and that IS a
    -- measurement here, because the frames themselves were non-zero. This is
    -- the distinction the whole suite exists for: same number, different
    -- meaning, and the reducer has to get it right in both directions.
    local same = {}
    for i = 1, 30 do same[i] = 16 end
    local innocent = BR.Loop.reduceAB(same, same)
    ok(innocent.resolved, 'equal frame times ARE a measurement, not a failure')
    ok(innocent.deltaMs == 0, 'and the honest answer there is zero',
        ('got %s'):format(tostring(innocent.deltaMs)))

    local short = { 1, 2, 3 }
    ok(not BR.Loop.reduceAB(short, short).resolved, 'too few frames does not resolve')
end

describe('bench driver')
do
    -- Drive the real bench() with an injected frame yield, so the whole path --
    -- burst, pair, reduce -- is exercised without a game. The fake clock only
    -- advances when a frame ends, which is precisely how the real one behaves.
    local ran = 0
    local h = BR.Loop.register(BR.Loop.FRAME, 't.bench.target', function() ran = ran + 1 end)

    -- 16ms idle frames; a frame that ran the burst costs 16 + 0.05ms x calls.
    local burstThisFrame = 0
    local function advance()
        fakeTime = fakeTime + 16 + math.floor(burstThisFrame * 0.05)
        burstThisFrame = 0
    end
    local counted = BR.Loop.register(BR.Loop.FRAME, 't.bench.counted', function()
        burstThisFrame = burstThisFrame + 1
    end)

    local r = BR.Loop.bench('t.bench.counted', 200, 5, advance)
    ok(r ~= nil, 'bench finds a registered callback')
    ok(r.resolved, 'bench resolves against a clock that moves between frames',
        r and r.reason)
    ok(r.perCallMs ~= nil and math.abs(r.perCallMs - 0.05) < 0.005,
        'bench recovers a per-call cost far below the clock resolution',
        ('got %s'):format(tostring(r and r.perCallMs)))
    ok(r.iterations == 200 and r.name == 't.bench.counted', 'bench labels its result')

    -- AND THE REGRESSION ITSELF: with a clock that never moves -- the real
    -- FiveM client -- bench must come back empty-handed rather than confident.
    local frozenR = BR.Loop.bench('t.bench.counted', 200, 5, function() end)
    ok(not frozenR.resolved, 'bench on a frozen clock does not resolve')
    ok(frozenR.perCallMs == nil, 'bench on a frozen clock reports no number',
        ('perCallMs=%s'):format(tostring(frozenR.perCallMs)))

    ok(BR.Loop.bench('t.no.such.callback', 10, 2, advance) == nil,
        'bench reports an unknown name as nil')

    BR.Loop.unregister(h)
    BR.Loop.unregister(counted)
    BR.Loop.step(BR.Loop.FRAME)
end

describe('ab driver')
do
    local h = BR.Loop.register(BR.Loop.FRAME, 't.ab.target', function() end)

    -- The callback is registered but the AB driver toggles `enabled`, so the
    -- fake frame cost keys off that: 22ms while it is on, 16ms while it is off.
    local function advance()
        local on = false
        for _, s in ipairs(BR.Loop.stats()) do
            if s.name == 't.ab.target' then on = s.enabled end
        end
        fakeTime = fakeTime + (on and 22 or 16)
    end

    local r = BR.Loop.ab('t.ab.target', 3, 12, advance)
    ok(r ~= nil and r.resolved, 'ab resolves', r and r.reason)
    ok(r.deltaMs == 6, 'ab recovers the in-situ per-frame cost',
        ('got %s'):format(tostring(r and r.deltaMs)))

    -- It must leave the subsystem exactly as it found it. An instrument that
    -- silently disables a gameplay callback is worse than no instrument.
    local restored
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 't.ab.target' then restored = s.enabled end
    end
    ok(restored == true, 'ab restores the callback it toggled')

    ok(BR.Loop.ab('t.no.such.callback', 2, 4, advance) == nil,
        'ab reports an unknown name as nil')

    BR.Loop.unregister(h)
    BR.Loop.step(BR.Loop.FRAME)
end

describe('timing capability')
do
    -- The hot path must not accumulate ms it cannot measure, and every
    -- reporting surface must be able to see that it did not. This is what
    -- /brhitch now gates its "the stall was NOT br_core" verdict on -- that
    -- sentence was previously reachable from a stopwatch that read zero, and so
    -- exonerated br_core on every hitch it ever saw.
    local t = BR.Loop.timing()
    ok(t.perCallResolvable == false,
        'per-call COST is unresolvable until a probe says otherwise')

    BR.Loop.resetStats()
    local h = BR.Loop.register(BR.Loop.TICK, 't.cap', function() end)
    fakeTime = fakeTime + 100
    for _ = 1, 5 do BR.Loop.step(BR.Loop.TICK) end

    local found
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 't.cap' then found = s end
    end
    ok(found.calls == 5, 'call counts are still collected -- the clock cannot corrupt those')
    ok(found.stalls == 0, 'a callback that never spans a frame records no stalls')
    ok(found.peakMs == 0, 'and no peak')
    ok(found.avgStallMs == 0, 'and the mean stall of zero stalls is zero, not a division by zero')
    ok(BR.Loop.frameStats().attributable == false,
        'frame stats say per-call cost is unattributable, so /brhitch withholds its verdict')

    BR.Loop.unregister(h)
    BR.Loop.step(BR.Loop.TICK)

    -- ═══ THE 55ms CASE, WHICH IS WHY THE STOPWATCH IS KEPT ═══
    --
    -- Owner's capture, 2026-08-23: one pass of airdrop.render in 113,237 read
    -- 55ms and every other sample in the registry read 0. On a frame-stamped
    -- clock that can only happen if the call SPANNED A FRAME -- it yielded, or
    -- it blocked the main thread. Either way it is a stall with a name on it,
    -- and it is the only signal this runtime gives that can name one.
    --
    -- So a callback that moves the clock must be COUNTED as a stall, sized by
    -- its peak, and -- the part the old build got wrong -- must never have its
    -- milliseconds divided by the call count and presented as an average.
    BR.Loop.resetStats()
    local spanner = BR.Loop.register(BR.Loop.SLOW, 't.cap.spanner', function()
        fakeTime = fakeTime + 55      -- as if a frame boundary passed mid-call
    end)
    local quiet = BR.Loop.register(BR.Loop.SLOW, 't.cap.quiet', function() end)

    BR.Loop.step(BR.Loop.SLOW)
    for _ = 1, 999 do BR.Loop.step(BR.Loop.SLOW) end

    local sp, qu
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 't.cap.spanner' then sp = s end
        if s.name == 't.cap.quiet'   then qu = s end
    end
    ok(sp.stalls == 1000, 'every pass that moved the clock is counted as a stall',
        ('stalls=%s'):format(tostring(sp.stalls)))
    ok(sp.peakMs == 55, 'the stall is sized by its worst reading',
        ('peak=%s'):format(tostring(sp.peakMs)))
    ok(sp.avgStallMs == 55, 'the mean is over STALLS, so it agrees with the peak',
        ('avgStall=%s'):format(tostring(sp.avgStallMs)))
    -- The regression in one line: totalMs/calls for a single 55ms spike across
    -- 113,237 passes is 0.000485, which prints as "avg 0.000ms" beside
    -- "peak 55ms" and makes an operator distrust every other row.
    ok(sp.avgStallMs > 0,
        'an average printed beside a non-zero peak can never itself be zero')
    ok(qu.stalls == 0 and qu.calls == 1000,
        'a callback in the same band that never spans a frame stays at zero stalls')
    ok(BR.Loop.bandStats()[BR.Loop.SLOW].stalls == 1000,
        'the band records the stall too, since the pass spanned a frame as well')

    BR.Loop.unregister(spanner)
    BR.Loop.unregister(quiet)
    BR.Loop.step(BR.Loop.SLOW)
    BR.Loop.resetStats()

    -- The probe itself, against the stub -- which is a faithful model of the
    -- real client, because GetGameTimer here does not move unless a test moves
    -- it, exactly as the game's does not move unless a frame ends. The probe
    -- must come back saying "cannot resolve" rather than quietly enabling a
    -- stopwatch that will read zero for ever.
    local probe = BR.Loop.probeClock(4096)
    ok(probe.moved == false, 'the probe sees a frozen clock for what it is')
    ok(probe.resolvable == false, 'and reports per-call timing as unresolvable')
    ok(probe.iterations > 0, 'having actually done the work to find out',
        ('iterations=%s'):format(tostring(probe.iterations)))
    ok(BR.Loop.timing().perCallResolvable == false,
        'so per-call timing stays off after probing')
    ok(BR.Loop.probeClock(4096) == probe, 'the probe is memoised, not re-run')
end

describe('dt')
do
    local seen = {}
    local h = BR.Loop.register(BR.Loop.SLOW, 't.dt', function(dt) seen[#seen + 1] = dt end)

    fakeTime = 1000; BR.Loop.step(BR.Loop.SLOW)
    fakeTime = 1250; BR.Loop.step(BR.Loop.SLOW)
    fakeTime = 1600; BR.Loop.step(BR.Loop.SLOW)

    ok(seen[1] == 0, 'first call reports zero delta rather than a bogus one')
    ok(seen[2] == 250, 'delta reflects elapsed time', ('got %s'):format(tostring(seen[2])))
    ok(seen[3] == 350, 'delta keeps tracking', ('got %s'):format(tostring(seen[3])))

    BR.Loop.unregister(h)
end

describe('state helpers')
do
    BR.State.match.state = BR.MatchState.PLAYING
    BR.State.me.state    = BR.PlayerState.ALIVE
    ok(BR.IsPlaying(), 'IsPlaying true when playing and alive')
    ok(BR.InMatch(), 'InMatch true while playing')

    BR.State.me.state = BR.PlayerState.DBNO
    ok(not BR.IsPlaying(), 'a downed player is not "playing"')
    ok(BR.InMatch(), 'but is still in the match')

    BR.State.match.state = BR.MatchState.BUS
    ok(BR.InMatch(), 'the bus counts as in-match')

    BR.State.match.state = BR.MatchState.WAITING
    ok(not BR.InMatch(), 'the lobby does not')
end

-- ---------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
