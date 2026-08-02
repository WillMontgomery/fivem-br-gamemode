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
