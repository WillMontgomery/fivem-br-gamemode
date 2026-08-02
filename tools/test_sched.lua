-- Unit tests for the br_core server scheduler.
--
-- The client loop registry had tests from the start and the server scheduler did
-- not, which is how a shadowed local -- BR.Sched.step's `nowMs` parameter hiding
-- a `nowMs()` helper -- reached a running server. luac -p accepts it happily;
-- it fails at runtime as "attempt to call a number value", inside the scheduler
-- thread, which would have stopped every server job.
--
-- The lesson encoded here: healthy jobs must report zero errors, and step()
-- itself must not throw.

local fakeTime = 0
function GetGameTimer() return fakeTime end
function GetConvar(_, d) return d end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerName() return 'Tester' end

local realPrint = print
local printed = {}
function print(s) printed[#printed + 1] = tostring(s) end

Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = function() end }
local handlers = {}
function AddEventHandler(n, fn) handlers[n] = fn end
function RegisterCommand() end
function TriggerClientEvent() end

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
    'br_core/server/main.lua',
}) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function statOf(name)
    for _, s in ipairs(BR.Sched.stats()) do
        if s.name == name then return s end
    end
    return nil
end

-- ------------------------------------------------------------- scheduling ---

describe('scheduling')
do
    local ran = 0
    local h = BR.Sched.every(1000, 't.basic', function() ran = ran + 1 end)
    ok(h ~= nil, 'every() returns a handle')

    fakeTime = 0
    BR.Sched.step(fakeTime)
    ok(ran == 1, 'runs on the first step')

    fakeTime = 500
    BR.Sched.step(fakeTime)
    ok(ran == 1, 'does not run again before its interval elapses')

    fakeTime = 1000
    BR.Sched.step(fakeTime)
    ok(ran == 2, 'runs again once the interval has elapsed')

    fakeTime = 5000
    BR.Sched.step(fakeTime)
    ok(ran == 3, 'a long gap still only runs it once -- no catch-up burst',
        ('ran=%d'):format(ran))

    -- Checked while the job is still live: names are only reserved by jobs that
    -- actually exist.
    local dup = pcall(BR.Sched.every, 100, 't.basic', function() end)
    ok(not dup, 'duplicate job names are rejected while the job is live')

    local badFn = pcall(BR.Sched.every, 100, 't.badfn', 'not a function')
    ok(not badFn, 'a non-function job is rejected')

    BR.Sched.cancel(h)
    fakeTime = 9000
    BR.Sched.step(fakeTime)
    ok(ran == 3, 'a cancelled job stops running')

    -- Cancelling frees the name again, which matters for match restarts: the
    -- same jobs are torn down and re-registered every round.
    local reuse, reuseHandle = pcall(BR.Sched.every, 100, 't.basic', function() end)
    ok(reuse, 'a cancelled name can be registered again')
    if reuse then BR.Sched.cancel(reuseHandle) end
    BR.Sched.step(fakeTime)
end

describe('dt')
do
    local seen = {}
    local h = BR.Sched.every(100, 't.dt', function(dt) seen[#seen + 1] = dt end)

    fakeTime = 10000; BR.Sched.step(fakeTime)
    fakeTime = 10250; BR.Sched.step(fakeTime)
    fakeTime = 10600; BR.Sched.step(fakeTime)

    ok(seen[1] == 0, 'first call reports zero delta, not a bogus one')
    ok(seen[2] == 250, 'delta reflects elapsed time', ('got %s'):format(tostring(seen[2])))
    ok(seen[3] == 350, 'delta keeps tracking', ('got %s'):format(tostring(seen[3])))

    BR.Sched.cancel(h)
    BR.Sched.step(fakeTime)
end

-- ------------------------------------------------------ the shadowing bug ---

describe('step integrity')
do
    -- REGRESSION. BR.Sched.step takes a `nowMs` parameter. A local helper of the
    -- same name would be shadowed inside it, so the timing call became
    -- "attempt to call a number value" -- thrown by step() itself, OUTSIDE the
    -- pcall that guards job bodies. In the running server that killed the
    -- scheduler thread and every job with it.
    --
    -- Two assertions, because they fail differently:
    --   * step() must not throw
    --   * a job that cannot fail must report zero errors
    local ran = 0
    local h = BR.Sched.every(50, 't.integrity', function() ran = ran + 1 end)

    fakeTime = 20000
    local stepOk, stepErr = pcall(BR.Sched.step, fakeTime)
    ok(stepOk, 'step() does not throw', tostring(stepErr))

    local s = statOf('t.integrity')
    ok(s ~= nil, 'the job appears in stats')
    ok(s and s.errors == 0, 'a job that cannot fail reports zero errors',
        s and ('errors=%d'):format(s.errors))
    ok(ran == 1, 'and it actually ran')

    -- Drive many passes; anything that only breaks on a later iteration surfaces.
    local threw = nil
    for i = 1, 200 do
        fakeTime = 20000 + i * 60
        local o, e = pcall(BR.Sched.step, fakeTime)
        if not o then threw = e break end
    end
    ok(threw == nil, 'step() is stable across many passes', tostring(threw))

    local s2 = statOf('t.integrity')
    ok(s2 and s2.errors == 0, 'still zero errors after 200 passes',
        s2 and ('errors=%d'):format(s2.errors))
    ok(s2 and s2.calls > 100, 'and it ran on most of them',
        s2 and ('calls=%d'):format(s2.calls))

    BR.Sched.cancel(h)
    BR.Sched.step(fakeTime)
end

-- ------------------------------------------------------ error containment ---

describe('error containment')
do
    local survivor = 0
    local hBad = BR.Sched.every(10, 't.err.bad', function() error('boom') end)
    local hOk  = BR.Sched.every(10, 't.err.ok', function() survivor = survivor + 1 end)

    fakeTime = 40000
    local stepOk = pcall(BR.Sched.step, fakeTime)
    ok(stepOk, 'a throwing job does not take step() down with it')
    ok(survivor == 1, 'other jobs in the same pass still run')

    for i = 1, 10 do
        fakeTime = 40000 + i * 20
        BR.Sched.step(fakeTime)
    end

    local bad = statOf('t.err.bad')
    ok(bad and bad.suspended, 'a persistently failing job is suspended')
    ok(bad and bad.errors >= 5, 'errors are counted', bad and ('errors=%d'):format(bad.errors))

    local good = statOf('t.err.ok')
    ok(good and good.errors == 0, 'the healthy job records no errors')
    ok(survivor > 5, 'and kept running throughout', ('ran=%d'):format(survivor))

    local before = bad.errors
    fakeTime = fakeTime + 1000
    BR.Sched.step(fakeTime)
    ok(statOf('t.err.bad').errors == before, 'a suspended job stops being called')

    BR.Sched.setEnabled('t.err.bad', true)
    ok(not statOf('t.err.bad').suspended, 're-enabling clears the suspension')

    BR.Sched.cancel(hBad); BR.Sched.cancel(hOk)
    BR.Sched.step(fakeTime)
end

describe('cancel during a pass')
do
    -- Same hazard as the client registry: removing an entry mid-iteration would
    -- shuffle the array and silently skip whichever job followed.
    local a, b, c = 0, 0, 0
    local hA, hB, hC
    hA = BR.Sched.every(10, 't.c.a', function() a = a + 1 end)
    hB = BR.Sched.every(10, 't.c.b', function() b = b + 1; BR.Sched.cancel(hB) end)
    hC = BR.Sched.every(10, 't.c.c', function() c = c + 1 end)

    fakeTime = 60000
    BR.Sched.step(fakeTime)
    ok(a == 1 and b == 1 and c == 1,
        'the job after a self-cancelling one is not skipped',
        ('a=%d b=%d c=%d'):format(a, b, c))

    fakeTime = 60100
    BR.Sched.step(fakeTime)
    ok(b == 1, 'the cancelled job does not run again')
    ok(a == 2 and c == 2, 'its neighbours are unaffected', ('a=%d c=%d'):format(a, c))

    BR.Sched.cancel(hA); BR.Sched.cancel(hC)
    BR.Sched.step(fakeTime)
end

describe('stats')
do
    BR.Sched.resetStats()
    local h = BR.Sched.every(10, 't.stats', function() end)

    for i = 1, 8 do
        fakeTime = 70000 + i * 20
        BR.Sched.step(fakeTime)
    end

    local s = statOf('t.stats')
    ok(s and s.calls == 8, 'call count is accurate', s and ('calls=%d'):format(s.calls))
    ok(s and s.intervalMs == 10, 'stats carry the interval')
    ok(s and s.avgMs >= 0, 'avgMs is a number, not nil or NaN',
        s and tostring(s.avgMs))
    ok(s and s.totalMs >= 0, 'totalMs is a number')

    BR.Sched.resetStats()
    ok(statOf('t.stats').calls == 0, 'resetStats clears the window')

    BR.Sched.cancel(h)
    BR.Sched.step(fakeTime)
end

-- ------------------------------------------------------------ server state ---

describe('server state')
do
    BR.Server.roster = {
        [1] = { src = 1, state = BR.PlayerState.ALIVE, squadId = 'a' },
        [2] = { src = 2, state = BR.PlayerState.DBNO,  squadId = 'a' },
        [3] = { src = 3, state = BR.PlayerState.DEAD,  squadId = 'a' },
        [4] = { src = 4, state = BR.PlayerState.ALIVE, squadId = 'b' },
        [5] = { src = 5, state = BR.PlayerState.ALIVE, squadId = nil },
    }

    ok(BR.Server.count() == 5, 'count() sees the whole roster')
    ok(BR.Server.aliveCount() == 4, 'downed players count as alive, dead ones do not',
        ('got %d'):format(BR.Server.aliveCount()))

    -- The win condition is squads standing, not players standing: a four-stack
    -- with three dead is still one team in the match.
    ok(BR.Server.squadsAlive() == 3, 'squadsAlive counts teams, and solos as their own',
        ('got %d'):format(BR.Server.squadsAlive()))

    BR.Server.roster[2].state = BR.PlayerState.DEAD
    ok(BR.Server.squadsAlive() == 3, 'a squad with one member left is still up')

    BR.Server.roster[1].state = BR.PlayerState.DEAD
    ok(BR.Server.squadsAlive() == 2, 'a fully eliminated squad drops out',
        ('got %d'):format(BR.Server.squadsAlive()))

    BR.Server.roster = {}
    ok(BR.Server.aliveCount() == 0 and BR.Server.squadsAlive() == 0,
        'an empty roster is handled')
end

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
