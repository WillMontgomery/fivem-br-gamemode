-- Unit tests for incident artifacts: the capture schedule, the caps, and every
-- way a frame can fail to arrive.
--
-- THESE LOAD THE REAL FILES. br_lib/shared/artifact_plan.lua AND
-- br_core/server/artifacts.lua both run here against stubbed natives, because a
-- test that re-implements the rule it is checking passes for the same reason the
-- code does and fails for neither. The rules under test -- three timed frames,
-- one per corroboration but only after ten seconds, nine and then stop -- are
-- exactly the kind that are wrong for weeks without anybody noticing, since the
-- only way to see them in the game is to be reported nine times.
--
-- WHAT THIS CANNOT TELL YOU. Nothing here proves an image exists. There is no
-- FiveM, no `screenshot-basic`, no CEF, no S3 and no disk: the capture export is
-- a stub that records what it was asked for, and whether a real client actually
-- renders a webp is a question only a playtest answers.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_artifacts.lua

-- --------------------------------------------------------------- harness ---

local realExit = os.exit
local realPrint = print

--- The two clocks artifacts.lua uses, both controllable. `gameMs` drives the
--- schedule and the ten-second rule; `wallSec` is what an artifact is stamped
--- with. They move independently on purpose -- a test that advanced them
--- together could not tell which one a rule was reading.
local gameMs = 100000
local wallSec = 1770000000

function GetGameTimer() return gameMs end
os.time = function() return wallSec end

local resourceState = {
    br_ddb = 'started',
    ['screenshot-basic'] = 'started',
}
function GetResourceState(name) return resourceState[name] or 'missing' end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerName(src) return 'Player' .. tostring(src) end

-- A list per event, as FiveM does it: every registered handler runs.
local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function RegisterNetEvent() end
function TriggerEvent(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end
function TriggerClientEvent() end

-- Timers, controllable. Nothing fires on its own: a test advances the clock to
-- the moment it wants and fires what is due, which is the only way to test "the
-- +5 second frame" and "the answer never came" without waiting.
local timers = {}
function SetTimeout(ms, fn)
    timers[#timers + 1] = { at = gameMs + ms, fn = fn }
end

--- Advance the game clock and run everything that became due.
local function advance(ms)
    gameMs = gameMs + ms
    local due, keep = {}, {}
    for _, t in ipairs(timers) do
        if t.at <= gameMs then due[#due + 1] = t else keep[#keep + 1] = t end
    end
    timers = keep
    table.sort(due, function(a, b) return a.at < b.at end)
    for _, t in ipairs(due) do t.fn() end
end

-- Identifiers, so the REAL br_lib/shared/identity.lua can resolve a license.
-- Stubbing BR.Identity itself would have hidden the thing this file most needs
-- to be right about: which player the picture is taken of.
local identifiers = {}
function GetNumPlayerIdentifiers(src) return #(identifiers[src] or {}) end
function GetPlayerIdentifier(src, i) return (identifiers[src] or {})[i + 1] end

local printed = {}
function print(s) printed[#printed + 1] = tostring(s) end

-- ---- the capture resource --------------------------------------------------

--- Every `requestClientScreenshot` this run has seen. The stub answers NOTHING
--- on its own: a test calls `shots[n].cb(...)` at the moment it chooses, which
--- is what makes "the client never answered" testable at all.
local shots = {}
exports = {
    ['screenshot-basic'] = {
        requestClientScreenshot = function(_, src, opts, cb)
            shots[#shots + 1] = { src = src, opts = opts, cb = cb, answered = false }
        end,
    },
}

-- ---- br_ddb ----------------------------------------------------------------

--- What the fake br_ddb does next. Tests flip these.
local ddb = {
    beginOk = true,
    beginError = 'spool full',
    putOk = true,
    putError = 'connection reset',
    begins = {},   -- { incidentId, index, encoding }
    puts = {},     -- { incidentId, index, encoding, capturedAt }
}

AddEventHandler('br:ddb:artifactBegin', function(req, incidentId, index, encoding)
    ddb.begins[#ddb.begins + 1] =
        { incidentId = incidentId, index = index, encoding = encoding }
    if not ddb.beginOk then
        TriggerEvent('br:ddb:artifactResult', req, false, { error = ddb.beginError })
        return
    end
    TriggerEvent('br:ddb:artifactResult', req, true, {
        key  = ('incidents/%s/%02d.%s'):format(incidentId, index, encoding),
        path = ('/tmp/br_artifacts/%s-%02d.%s'):format(incidentId, index, encoding),
    })
end)

AddEventHandler('br:ddb:artifactPut', function(req, incidentId, index, encoding, capturedAt)
    ddb.puts[#ddb.puts + 1] = {
        incidentId = incidentId, index = index,
        encoding = encoding, capturedAt = capturedAt,
    }
    if not ddb.putOk then
        TriggerEvent('br:ddb:artifactResult', req, false, { error = ddb.putError })
        return
    end
    TriggerEvent('br:ddb:artifactResult', req, true, { bytes = 24680 })
end)

-- ---- the roster ------------------------------------------------------------

--- [src] = entry. `each` is the real function's two lines, copied rather than
--- imported because loading server/roster.lua would drag in the broadcast layer,
--- the scheduler and the whole match config for a predicate and a loop.
local roster = {}

local function connect(src, license)
    identifiers[src] = { 'license:' .. license, 'steam:110000100000000' }
    roster[src] = { src = src, name = 'Player' .. src, state = 'ALIVE', matchId = 41 }
end

local function disconnect(src)
    roster[src] = nil
    identifiers[src] = nil
end

-- ---- load ------------------------------------------------------------------

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            realExit(1)
        end
        chunk()
    end
end

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/identity.lua',
    'br_lib/shared/artifact_plan.lua',
})

BR.Roster = {
    each = function(pred, fn)
        for src, entry in pairs(roster) do
            if not pred or pred(entry) then fn(src, entry) end
        end
    end,
}

loadAll({ 'br_core/server/artifacts.lua' })

-- ------------------------------------------------------------------ asserts ---

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s: %s%s')
            :format(group, name, detail and ('\n        ' .. detail) or ''))
    end
end
local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

--- `t[k]`, answering nil for a missing `t`.
---
--- NOT A CONVENIENCE. Nearly every assertion below reaches into the Nth request
--- this run produced, and the regressions worth catching are exactly the ones
--- that produce FEWER requests -- so a raw `list[4].index` turns "the fourth
--- frame was not taken" into a nil-index traceback that stops the file and names
--- nothing. One accessor, and every such regression reports as a named failure
--- with the rest of the suite still running.
local function of(t, k)
    if t == nil then return nil end
    return t[k]
end

--- A fresh world. Called at the top of every case so one test cannot leave the
--- plan, the roster or the timer queue holding the next one's answer.
local LIC = 'license:1100001aaaaaaaa'
local function reset()
    timers, shots, printed = {}, {}, {}
    ddb.begins, ddb.puts = {}, {}
    ddb.beginOk, ddb.putOk = true, true
    resourceState['screenshot-basic'] = 'started'
    resourceState.br_ddb = 'started'
    for src in pairs(roster) do disconnect(src) end
    gameMs = gameMs + 1000000       -- forward, so old timers can never be due
    TriggerEvent('onResourceStart', 'br_core')
    printed = {}
    connect(7, '1100001aaaaaaaa')
end

--- File a case against the connected subject.
local function file(id)
    TriggerEvent('br:incident:filed', {
        incidentId = id, matchId = 41, subjectLicense = LIC,
    })
end

--- Answer the nth outstanding screenshot request the way a healthy client would.
--- `err` defaults to `false`, which is literally what screenshot-basic sends.
local function deliver(n, err)
    local s = shots[n]
    if not s then return false end
    s.answered = true
    s.cb(err == nil and false or err, s.opts.fileName)
    return true
end

--- Every line printed so far, joined. For the "nothing shouts" assertions.
local function log() return table.concat(printed, '\n') end

-- ═══════════════════════════════════════════════════════════════════════════
describe('three timed frames')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    file('11111111-2222-4333-8444-555555555555')

    eq(#shots, 1, 'the first frame is taken immediately')
    advance(4999)
    eq(#shots, 1, 'nothing more before +5s')
    advance(1)
    eq(#shots, 2, 'the second frame lands at +5s')
    advance(5000)
    eq(#shots, 3, 'the third frame lands at +10s')
    advance(60000)
    eq(#shots, 3, 'and there is no fourth')

    eq(shots[1].src, 7, 'the frame is taken of the subject')
    eq(shots[1].opts.encoding, 'webp', 'the encoding is webp')
    eq(shots[1].opts.quality, 0.92, 'the quality is 0.92')
    ok(type(shots[1].opts.fileName) == 'string' and shots[1].opts.fileName ~= '',
        'a fileName is supplied, so the bytes never cross as a data URI')

    eq(of(ddb.begins[1], 'index'), 1, 'the first frame claims number 1')
    eq(of(ddb.begins[2], 'index'), 2, 'the second claims 2')
    eq(of(ddb.begins[3], 'index'), 3, 'the third claims 3')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the frames are uploaded, stamped with the SERVER clock')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    wallSec = 1770000000
    file('11111111-2222-4333-8444-000000000001')
    deliver(1)

    eq(#ddb.puts, 1, 'a delivered frame is uploaded')
    eq(of(ddb.puts[1], 'capturedAt'), 1770000000 * 1000,
        'stamped with os.time() on this box, in milliseconds')
    eq(of(ddb.puts[1], 'encoding'), 'webp', 'the encoding travels with it')
    eq(of(ddb.puts[1], 'index'), 1, 'under the number that was claimed')

    -- The subject's own clock is never consulted. Nothing the client sends is
    -- read at all except "did this work" -- proven by the fact that a delivery
    -- carrying a wild fileName still stamps from the server.
    wallSec = 1770000042
    advance(5000)
    deliver(2, false)
    eq(of(ddb.puts[2], 'capturedAt'), 1770000042 * 1000,
        'the stamp follows the server clock between frames')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('a corroboration inside the first ten seconds is already covered')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    local ID = '11111111-2222-4333-8444-000000000002'
    file(ID)
    eq(#shots, 1, 'one timed frame so far')

    advance(3000)
    TriggerEvent('br:ringmaster:corroborate', { incidentId = ID, license = LIC })
    eq(#shots, 1, 'a corroboration at +3s takes no frame')

    advance(2000)   -- +5s: the second timed frame
    eq(#shots, 2, 'the timed schedule is unaffected')

    advance(4999)   -- +9.999s
    TriggerEvent('br:ringmaster:corroborate', { incidentId = ID, license = LIC })
    eq(#shots, 2, 'a corroboration one millisecond short of +10s is still covered')

    advance(1)      -- +10s: the third timed frame
    eq(#shots, 3, 'the third timed frame lands')
    TriggerEvent('br:ringmaster:corroborate', { incidentId = ID, license = LIC })
    eq(#shots, 4, 'a corroboration AT +10s takes a frame')
    eq(of(ddb.begins[4], 'index'), 4,
        'and it is numbered after the timed three')

    ok(not log():find('%^1') and not log():find('%^3'),
        'no refusal here is dressed as a warning or an error')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('nine, and then stop')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    local ID = '11111111-2222-4333-8444-000000000003'
    file(ID)
    advance(10000)
    eq(#shots, 3, 'the three timed frames')

    for i = 1, 6 do
        TriggerEvent('br:ringmaster:corroborate', { incidentId = ID, license = LIC })
        eq(#shots, 3 + i, ('corroboration %d takes a frame'):format(i))
    end
    eq(#shots, 9, 'three timed plus six corroboration is nine')
    -- INDEXED DEFENSIVELY ON PURPOSE. A regression that takes FEWER frames
    -- should report as a failed assertion, not as a nil index that stops the
    -- whole file -- a crashed suite tells you far less than a named one.
    eq(of(ddb.begins[9], 'index'), 9, 'the last frame is number 9')

    local before = #printed
    TriggerEvent('br:ringmaster:corroborate', { incidentId = ID, license = LIC })
    eq(#shots, 9, 'the seventh corroborator adds no frame')
    eq(#ddb.begins, 9, 'and asks br_ddb for nothing')
    eq(#printed, before, 'and says nothing at all -- it is a rule, not a fault')

    for _ = 1, 20 do
        TriggerEvent('br:ringmaster:corroborate', { incidentId = ID, license = LIC })
    end
    eq(#shots, 9, 'nor do the next twenty')

    local s = BR.Artifacts.stats()
    ok(s.refusedCap >= 21, 'the refusals are counted rather than lost')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the subject disconnects between frames')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    local ID = '11111111-2222-4333-8444-000000000004'
    file(ID)
    deliver(1)
    eq(#shots, 1, 'the first frame was taken while they were here')

    disconnect(7)
    advance(5000)
    eq(#shots, 1, 'the +5s frame is not requested of a player who has gone')
    advance(5000)
    eq(#shots, 1, 'nor the +10s one')
    eq(#ddb.begins, 1, 'and neither reserves anything on disk')

    -- THE SLOT WAS NOT SPENT. A frame nobody asked for must not consume one of
    -- the nine, or a subject who leaves for thirty seconds would come back with
    -- their case already at the cap.
    connect(7, '1100001aaaaaaaa')
    TriggerEvent('br:ringmaster:corroborate', { incidentId = ID, license = LIC })
    eq(#shots, 2, 'a corroboration after they return still takes a frame')
    eq(of(ddb.begins[2], 'index'), 2, 'and gets number 2, not number 4')

    ok(not log():find('%^1') and not log():find('%^3'),
        'a departed subject is not an error')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('screenshot-basic is not installed')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    resourceState['screenshot-basic'] = 'missing'
    TriggerEvent('onResourceStart', 'br_core')
    printed = {}

    local ID = '11111111-2222-4333-8444-000000000005'
    file(ID)
    advance(20000)
    eq(#shots, 0, 'no frame is requested')
    eq(#ddb.begins, 0, 'nothing is reserved on disk')
    eq(#printed, 0, 'and the incident produces not one line of noise')

    TriggerEvent('br:ringmaster:corroborate', { incidentId = ID, license = LIC })
    eq(#shots, 0, 'a corroboration is a no-op too')

    -- AND THE CASE IS NOT HALF-OPEN. An incident opened with no way to capture
    -- would start refusing corroborations as 'covered' or 'cap', which would
    -- read as a rule firing rather than as a server that cannot take pictures.
    ok(not BR.Artifacts.plan:isOpen(ID),
        'the case is never opened, so nothing is later refused on its behalf')
    eq(BR.Artifacts.stats().enabled, false, 'and the state is visible to brdebug')

    -- It comes back without a restart.
    resourceState['screenshot-basic'] = 'started'
    file('11111111-2222-4333-8444-000000000006')
    eq(#shots, 1, 'a resource started mid-session is picked up on the next case')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the upload fails')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    local ID = '11111111-2222-4333-8444-000000000007'
    ddb.putOk = false
    file(ID)
    deliver(1)

    eq(#ddb.puts, 1, 'the upload was attempted')
    ok(log():find('not stored'), 'and the loss is recorded')
    ok(not log():find('%^1') and not log():find('%^3'),
        'but not as a warning or an error -- a partial set is normal')

    -- THE CASE SURVIVES IT. The incident row was durable before any of this ran
    -- and nothing here can unfile it; the rest of the schedule must go on.
    ok(BR.Artifacts.plan:isOpen(ID), 'the case is still being captured for')

    -- COUNTERS ARE PROCESS-WIDE, so these are read as deltas. `stat` is not
    -- cleared by `onResourceStart` because in the game that event means the Lua
    -- state is brand new anyway -- clearing it would be code that exists only
    -- for this file.
    local lostBefore = BR.Artifacts.stats().lost
    local storedBefore = BR.Artifacts.stats().stored

    ddb.putOk = true
    advance(5000)
    eq(#shots, 2, 'the +5s frame is still taken')
    deliver(2)
    eq(#ddb.puts, 2, 'and this one stores')
    eq(BR.Artifacts.stats().stored - storedBefore, 1, 'one more stored')
    ok(lostBefore >= 1, 'the failed upload was counted as lost, not as stored')
    eq(BR.Artifacts.stats().lost - lostBefore, 0, 'and the good one adds no loss')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the spool refuses a path')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    ddb.beginOk = false
    file('11111111-2222-4333-8444-000000000008')
    eq(#ddb.begins, 1, 'br_ddb was asked')
    eq(#shots, 0, 'and no picture was taken, so nothing lands with nowhere to go')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('br_ddb is not running')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    resourceState.br_ddb = 'missing'
    file('11111111-2222-4333-8444-000000000009')
    eq(#shots, 0, 'no picture is taken when there is nowhere to put it')
    eq(#ddb.begins, 0, 'and the bridge is not called')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the client never answers')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    local ID = '11111111-2222-4333-8444-00000000000a'
    file(ID)
    eq(#shots, 1, 'a frame was requested')

    advance(30000)  -- well past the 15s wait; also fires +5s and +10s
    eq(#ddb.puts, 0, 'nothing was uploaded for a frame that never arrived')
    ok(log():find('no answer from the client'), 'and the wait is recorded')
    ok(not log():find('%^1') and not log():find('%^3'), 'quietly')

    -- THE LATE ANSWER. screenshot-basic keeps its upload token open forever, so
    -- a client that comes back minutes later still fires this callback -- into a
    -- request nobody is waiting for. It must not upload a file br_ddb has
    -- already swept.
    deliver(1)
    eq(#ddb.puts, 0, 'and a callback arriving after the wait uploads nothing')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the truthiness scar')
-- ═══════════════════════════════════════════════════════════════════════════
do
    -- screenshot-basic's error argument is declared `string | boolean` and
    -- crosses a JS-to-Lua resource boundary. IN LUA `0` IS TRUTHY: a runtime
    -- that hands back 0 for that `false` would make every successful capture
    -- read as a failure, and this feature would store nothing while logging
    -- nothing worth noticing.
    reset()
    file('11111111-2222-4333-8444-00000000000b')
    deliver(1, 0)
    eq(#ddb.puts, 1, '0 means success, not failure')

    reset()
    file('11111111-2222-4333-8444-00000000000c')
    deliver(1, false)
    eq(#ddb.puts, 1, 'false means success')

    reset()
    file('11111111-2222-4333-8444-00000000000d')
    deliver(1, 'ENOENT: no such file')
    eq(#ddb.puts, 0, 'a message means failure')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('cases this process did not file')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    -- A day-old case corroborated tonight. server/players.lua reads
    -- BR.Incident.openFor, which deliberately outlives a match -- but this
    -- process has no capture state for it, so it cannot know which frame numbers
    -- are already in the bucket. Guessing would OVERWRITE existing evidence,
    -- which is strictly worse than a missing frame.
    TriggerEvent('br:ringmaster:corroborate', {
        incidentId = '11111111-2222-4333-8444-0000000000ff', license = LIC,
    })
    eq(#shots, 0, 'no frame is taken for a case with no plan')
    eq(#printed, 0, 'and nothing is said about it')
    ok(BR.Artifacts.stats().refusedUnknown >= 1, 'it is counted')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('a duplicate acknowledgement')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    local ID = '11111111-2222-4333-8444-0000000000ee'
    file(ID)
    advance(10000)
    eq(#shots, 3, 'three frames')

    -- br_ddb reports a duplicate write as a success, which is what makes
    -- br_ringmaster's retry safe -- so this event CAN arrive twice for one case.
    -- Re-opening would restart the numbering at 01 and overwrite frames already
    -- in the bucket.
    file(ID)
    advance(10000)
    eq(#shots, 3, 'the second acknowledgement schedules nothing')
    eq(#ddb.begins, 3, 'and claims no numbers')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('malformed events')
-- ═══════════════════════════════════════════════════════════════════════════
do
    reset()
    TriggerEvent('br:incident:filed', nil)
    TriggerEvent('br:incident:filed', 'not a table')
    TriggerEvent('br:incident:filed', { incidentId = '', subjectLicense = LIC })
    TriggerEvent('br:incident:filed', { incidentId = 'x', subjectLicense = nil })
    TriggerEvent('br:ringmaster:corroborate', nil)
    TriggerEvent('br:ringmaster:corroborate', { incidentId = 42, license = LIC })
    TriggerEvent('br:ringmaster:corroborate', { incidentId = 'x' })
    advance(20000)
    eq(#shots, 0, 'nothing malformed reaches the camera')
    eq(#printed, 0, 'and nothing malformed is worth a line')
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('the plan on its own')
-- ═══════════════════════════════════════════════════════════════════════════
do
    -- The pure module, driven directly, so the arithmetic is pinned
    -- independently of the wiring above.
    local p = BR.ArtifactPlan.new()
    eq(#BR.ArtifactPlan.timedOffsets(), 3, 'three timed offsets')
    eq(BR.ArtifactPlan.timedOffsets()[1], 0, 'the first is immediate')
    eq(BR.ArtifactPlan.timedOffsets()[3], BR.ArtifactPlan.coveredMs(),
        'the covered window IS the last offset, not a second copy of it')

    ok(p:open('a', 0), 'a case opens')
    ok(not p:open('a', 0), 'and does not open twice')
    ok(not p:open('', 0), 'an empty id is refused')

    local _, why = p:claim('nope', 'timed', 0)
    eq(why, 'unknown', 'an unfiled case is unknown')

    local _, why2 = p:claim('a', 'corroboration', 9999)
    eq(why2, 'covered', 'a corroboration inside the window is covered')

    eq(p:claim('a', 'timed', 0), 1, 'timed frames number from 1')
    eq(p:claim('a', 'timed', 5000), 2, '')
    eq(p:claim('a', 'timed', 10000), 3, '')
    local _, why3 = p:claim('a', 'timed', 10000)
    eq(why3, 'cap', 'a fourth timed frame is refused')

    for i = 4, 9 do
        eq(p:claim('a', 'corroboration', 10000), i,
            ('corroboration frame %d'):format(i))
    end
    local _, why4 = p:claim('a', 'corroboration', 99999)
    eq(why4, 'cap', 'the seventh corroboration is refused')
    eq(of(p:usage('a'), 'used'), 9, 'nine frames used')
    eq(of(p:usage('a'), 'timed'), 3, 'three of them timed')
    eq(of(p:usage('a'), 'corroboration'), 6, 'six of them corroboration')

    -- THE TOTAL IS THE OWNER'S NUMBER AND IT WINS. Raising the corroboration
    -- cap without raising the total must not raise the total.
    local q = BR.ArtifactPlan.new({ corroborationMax = 99 })
    q:open('b', 0)
    for _ = 1, 3 do q:claim('b', 'timed', 0) end
    for _ = 1, 6 do q:claim('b', 'corroboration', 10000) end
    local _, why5 = q:claim('b', 'corroboration', 10000)
    eq(why5, 'cap', 'the total of nine holds even with the halves out of step')

    -- AND THE HALVES ARE PINNED SEPARATELY, WITH THE TOTAL OUT OF THE WAY.
    --
    -- WHY THIS IS NOT REDUNDANT WITH EVERYTHING ABOVE, and it is the whole
    -- reason the block exists: 3 + 6 = 9 exactly, so every assertion made
    -- against a default plan is satisfied by `totalMax` alone. Raising
    -- `corroborationMax` from 6 to 7 passed the entire rest of this file. Both
    -- halves are the owner's numbers too, so both get a case that can only be
    -- answered by the half it names.
    local h = BR.ArtifactPlan.new({ totalMax = 99 })
    h:open('c', 0)
    for i = 1, 3 do
        eq(h:claim('c', 'timed', 0), i, ('timed frame %d, total lifted'):format(i))
    end
    local _, why6 = h:claim('c', 'timed', 0)
    eq(why6, 'cap', 'there are THREE timed frames, not four, whatever the total is')

    for i = 1, 6 do
        eq(h:claim('c', 'corroboration', 10000), 3 + i,
            ('corroboration frame %d, total lifted'):format(i))
    end
    local _, why7 = h:claim('c', 'corroboration', 10000)
    eq(why7, 'cap', 'there are SIX corroboration frames, not seven')

    -- The bound on how many cases are held.
    local r = BR.ArtifactPlan.new({ incidentMax = 2 })
    r:open('one', 0); r:open('two', 0); r:open('three', 0)
    ok(not r:isOpen('one'), 'the oldest case is evicted')
    ok(r:isOpen('three'), 'the newest is kept')
    eq(r:stats().evicted, 1, 'and the eviction is counted')
end

-- ------------------------------------------------------------------ report ---

realPrint(('artifacts: %d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
