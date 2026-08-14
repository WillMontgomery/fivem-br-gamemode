-- Unit tests for br_ringmaster.
--
-- This resource is the one that talks to a machine in another AWS region, so
-- almost everything interesting about it is untestable in game and trivially
-- testable here: is it OFF when nothing is configured, does the boot epoch
-- actually differ between two starts, does the identity capture keep the right
-- things and drop the rest.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_ringmaster.lua

-- --------------------------------------------------------------- harness ---

local fakeTime = 0
function GetGameTimer() return fakeTime end

local convars = {}
function GetConvar(name, default)
    local v = convars[name]
    if v == nil then return default end
    return v
end

local identifiers = {}      -- [src] = { 'license:aaa', ... }
function GetNumPlayerIdentifiers(src) return #(identifiers[src] or {}) end
function GetPlayerIdentifier(src, i)  return (identifiers[src] or {})[i + 1] end
function GetPlayers()               return {} end
function GetPlayerName(src)           return 'Player' .. tostring(src) end
function GetCurrentResourceName()     return 'br_ringmaster' end

-- A LIST PER EVENT, not one handler per name. FiveM runs every registered
-- handler for an event, and both main.lua and gate.lua register
-- `playerConnecting` -- so a last-one-wins stub would silently test only half
-- the connect path and hide any interaction between them.
local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
-- Same-state dispatch, which is exactly what FiveM does for server-side
-- TriggerEvent between loaded handlers.
function TriggerEvent(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

-- Timers, controllable. Nothing fires on its own: a test calls fireTimers() at
-- the moment it wants the timeout to land, which is the only way to test "the
-- answer never came" without actually waiting.
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
local function fireTimers()
    local due = timers
    timers = {}
    for _, t in ipairs(due) do t.fn() end
end

-- gate.lua yields once between defer() and update(), as FiveM requires.
function Wait(_) end

-- Which resources are running. The gate skips itself entirely when br_ddb is
-- absent, so this drives that branch.
local resourceState = { br_ddb = 'started' }
function GetResourceState(name) return resourceState[name] or 'missing' end

-- json.encode stub: stash the table, return a marker. The tests assert on the
-- TABLE, because asserting on a hand-rolled JSON string would test the stub.
local encoded = {}
json = { encode = function(tbl) encoded[#encoded + 1] = tbl; return 'JSON#' .. #encoded end }

-- PerformHttpRequest capture. Each call is recorded; the test decides when and
-- how the callback answers, which is what lets ack/nack paths be driven.
local http = {}
function PerformHttpRequest(url, cb, method, body, headers)
    http[#http + 1] = { url = url, cb = cb, method = method, body = body, headers = headers }
end
local function lastRequest() return http[#http] end
local function requestCount() return #http end
local function bodyOf(req)
    local n = tonumber(tostring(req.body):match('JSON#(%d+)'))
    return n and encoded[n] or nil
end

local commands = {}
function RegisterCommand(name, fn, restricted)
    commands[name] = { fn = fn, restricted = restricted }
end

Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = function() end }

local realPrint = print
local printed = {}
function print(s) printed[#printed + 1] = tostring(s) end

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end
end

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/sched.lua',
    'br_lib/shared/identity.lua',
    'br_lib/shared/outbox.lua',
    'br_ringmaster/server/config.lua',
    'br_ringmaster/server/main.lua',
    'br_ringmaster/server/gate.lua',
    'br_ringmaster/server/debug.lua',
})

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

-- ------------------------------------------------------------ config off ---

describe('config.unconfigured')
do
    -- The default state of a server that has never heard of Ringmaster. This
    -- is the one that has to be boring: br_stats' contract with a missing
    -- database, applied to a missing admin console.
    ok(BR.Ring.Config.configured() == false,
        'a server with no convars set is OFF')

    local lines, healthy = BR.Ring.Config.report()
    ok(healthy == false, 'and reports itself unhealthy')

    local text = table.concat(lines, '\n')
    ok(text:find('NOT CONFIGURED', 1, true) ~= nil,
        'the banner says so in words')
    ok(text:find('br_ringmaster_ingest_url', 1, true) ~= nil,
        'and names the convar to set, rather than leaving a scavenger hunt')
end

describe('config.empty-string')
do
    -- GetConvar returns the DEFAULT only when a convar is unset. A convar set
    -- to "" is set, so the default never applies -- which would leave an empty
    -- URL looking configured and produce a push to nowhere, forever, on a
    -- timer. This is the bug that reads as "Ringmaster is up but shows
    -- nothing".
    convars['br_ringmaster_ingest_url'] = ''
    convars['br_ringmaster_ingest_secret'] = ''
    package.loaded = {}
    loadAll({ 'br_ringmaster/server/config.lua' })

    ok(BR.Ring.Config.configured() == false,
        'a convar set to empty string is treated as unset, not as configured')
end

describe('config.half-configured')
do
    -- A URL with no secret is not a configuration, it is a retry loop: the
    -- endpoint rejects every push. Better to be plainly off.
    convars['br_ringmaster_ingest_url'] = 'http://10.0.133.69:3000/api/ingest'
    convars['br_ringmaster_ingest_secret'] = nil
    loadAll({ 'br_ringmaster/server/config.lua' })

    ok(BR.Ring.Config.configured() == false,
        'a URL with no secret is OFF, not half-on')
end

describe('config.on')
do
    convars['br_ringmaster_ingest_url'] = 'http://10.0.133.69:3000/api/ingest'
    convars['br_ringmaster_ingest_secret'] = 'abcdefghijklmnopqrstuvwx'
    loadAll({ 'br_ringmaster/server/config.lua' })

    ok(BR.Ring.Config.configured() == true, 'both halves present means ON')
    ok(BR.Ring.Config.pushMs == 2000, 'push interval defaults to 2s')

    -- The secret must never reach a console, a log file, or a screenshot of
    -- one. Length is enough to diagnose a truncated paste.
    local lines = BR.Ring.Config.report()
    local text = table.concat(lines, '\n')
    ok(text:find('abcdefghij', 1, true) == nil,
        'the banner never prints the secret itself')
    ok(text:find('24 chars', 1, true) ~= nil,
        'only its length, which is what a bad paste shows up in')
end

describe('config.clamp')
do
    -- A typo'd interval should be visible rather than merely survivable. Zero
    -- would spin the scheduler; an hour looks identical to "broken".
    convars['br_ringmaster_push_ms'] = '0'
    loadAll({ 'br_ringmaster/server/config.lua' })
    ok(BR.Ring.Config.pushMs == 250, 'a zero interval clamps to the floor')

    convars['br_ringmaster_push_ms'] = '99999999'
    loadAll({ 'br_ringmaster/server/config.lua' })
    ok(BR.Ring.Config.pushMs == 60000, 'and an absurd one to the ceiling')

    convars['br_ringmaster_push_ms'] = 'banana'
    loadAll({ 'br_ringmaster/server/config.lua' })
    ok(BR.Ring.Config.pushMs == 2000, 'unparseable falls back to the default')

    convars['br_ringmaster_push_ms'] = nil
end

-- ------------------------------------------------------------ boot epoch ---

describe('bootEpoch')
do
    -- The whole point: Ringmaster dedupes on (bootEpoch, seq), because
    -- BR.Outbox restarts seq at 0 on every resource start and deploy.sh
    -- restarts resources after every deploy. Two starts inside the same second
    -- are entirely normal when a script is doing them, so a second-resolution
    -- timestamp alone is not enough -- which is what the other two sources are
    -- for: `os.time()`, `GetGameTimer()`, and a fresh table's address.
    --
    -- WHAT THIS ASSERTS, AND WHAT IT DELIBERATELY DOES NOT (issue #96, closed as
    -- accepted risk by the owner). It asserts distinctness across restarts where
    -- the GAME CLOCK has advanced, which is every restart on a real box: a
    -- resource restart takes far longer than a millisecond, so GetGameTimer()
    -- always differs even when os.time() does not.
    --
    -- It does NOT assert distinctness when all three sources coincide, because
    -- the harness can force that and a real server cannot realistically reach it:
    -- `loadAll` runs in one process with GetGameTimer() stubbed to a constant, so
    -- 200 iterations share a second AND a game-clock reading, leaving only a heap
    -- address that Lua reuses. Asserting on that measured the stub, not the code,
    -- and failed ~9% of the time forever.
    --
    -- The residual risk, priced rather than waved away: two restarts in the same
    -- wall-clock second, at the same game-clock millisecond, with a reused table
    -- address, would make the console discard the events after the restart as
    -- duplicates -- silently. If that ever needs closing, the fix is a monotonic
    -- per-process counter in the string rather than more entropy.
    local seen = {}
    local collisions = 0
    local base = fakeTime
    for i = 1, 200 do
        fakeTime = base + i          -- a restart takes longer than a millisecond
        loadAll({ 'br_ringmaster/server/main.lua' })
        local e = BR.Ring.bootEpoch
        if seen[e] then collisions = collisions + 1 end
        seen[e] = true
    end
    fakeTime = base
    ok(collisions == 0,
        '200 restarts produce 200 distinct epochs once the game clock has moved',
        collisions .. ' collisions')

    -- THREE PARTS, not two. A wall-clock second alone repeats across a scripted
    -- restart; the game-clock reading is what actually separates them.
    local parts = 0
    for _ in BR.Ring.bootEpoch:gmatch('[^-]+') do parts = parts + 1 end
    ok(parts == 3,
        'the epoch carries a wall second, a game-clock reading and a nonce',
        tostring(parts) .. ' parts')
end

describe('clockPair')
do
    -- GetGameTimer is milliseconds since server start. Alone it is meaningless
    -- to anything off the box; paired with a wall clock sampled at the same
    -- instant it becomes convertible. Sampling them TOGETHER is the contract.
    fakeTime = 4281003
    local wallMs, gameMs = BR.Ring.clockPair()

    ok(gameMs == 4281003, 'the game clock reading comes back as-is')
    ok(wallMs > 1700000000000, 'alongside a real unix millisecond timestamp')

    -- The conversion Ringmaster performs on every event.
    local eventAt = 4280003          -- one second earlier, in game-clock terms
    ok(wallMs + (eventAt - gameMs) == wallMs - 1000,
        'wallMs + (at - gameMs) recovers a real time for any event')
end

-- -------------------------------------------------------------- identity ---

describe('capture')
do
    BR.Ring.seen = {}

    identifiers[7] = {
        'license:abc123',
        'ip:203.0.113.7',        -- must never be kept
        'discord:998877',
        'steam:110000100000000',
        'quantumid:whatever',    -- an identifier type that does not exist yet
    }

    local license = BR.Ring.capture(7)
    ok(license == 'license:abc123',
        'capture returns the QUALIFIED license, matching br_stats\' key shape')

    local rec = BR.Ring.seen['license:abc123']
    ok(rec ~= nil, 'and files a record under it')
    ok(rec.byKind.ip == nil, 'IP is never collected -- product decision, not an oversight')
    ok(rec.byKind.quantumid == nil, 'nor is an unanticipated identifier type')
    ok(rec.byKind.discord == '998877', 'discord survives, because login depends on it')
    ok(rec.byKind.steam == '110000100000000', 'and so does steam')
end

describe('capture.no-license')
do
    BR.Ring.seen = {}
    identifiers[8] = { 'discord:12345' }   -- no license at all

    local license = BR.Ring.capture(8)
    ok(license == nil, 'a connection with no license is not captured')
    ok(next(BR.Ring.seen) == nil,
        'and no record is invented -- a guessed key is a ban against the wrong person')
end

describe('capture.reconnect')
do
    BR.Ring.seen = {}
    identifiers[9] = { 'license:aaa' }

    BR.Ring.capture(9)
    local first = BR.Ring.seen['license:aaa'].firstSeen

    BR.Ring.capture(9)
    local rec = BR.Ring.seen['license:aaa']

    ok(BR.Ring.seenCount() == 1, 'reconnecting does not create a second record')
    ok(rec.firstSeen == first, 'firstSeen is preserved across reconnects')
end

-- ------------------------------------------------------- the Slice 1 gate ---

describe('slice1.read-only')
do
    -- These are assertions about the SHAPE of the resource, not its behaviour,
    -- and they exist because Slice 1's exit gate is "there is no code path by
    -- which the panel can affect a match". verify.sh greps for the same thing;
    -- this catches it a layer earlier, with a message that explains why.
    ok(handlers['playerConnecting'] ~= nil,
        'identity capture is registered on playerConnecting')

    local names = {}
    for n in pairs(commands) do names[#names + 1] = n end
    table.sort(names)

    -- The whole read-only command surface, by name. Growing this list is fine;
    -- growing it without updating this test is how a write verb sneaks into a
    -- read-only slice.
    ok(#names == 2 and names[1] == 'bridents' and names[2] == 'brring',
        'bridents and brring are the ONLY commands this resource registers in Slice 1',
        table.concat(names, ', '))
    for _, n in ipairs(names) do
        ok(commands[n].restricted == true,
            n .. ' is restricted, like every other br* console command')
    end
end

-- ------------------------------------------------------------- the wire ---

describe('push')
do
    -- A configured resource, loaded fresh so push.lua registers its jobs.
    convars['br_ringmaster_ingest_url'] = 'http://10.0.133.69:3000/api/ingest'
    convars['br_ringmaster_ingest_secret'] = 'sssssssssssssssssssssss1'
    loadAll({
        'br_ringmaster/server/config.lua',
        'br_ringmaster/server/main.lua',
        'br_ringmaster/server/push.lua',
    })

    -- push.lua says hello on load; br_core is absent here, so nothing answers,
    -- which must be fine -- the resources are deliberately decoupled.

    -- A snapshot arrives from "br_core"...
    TriggerEvent('br:ringmaster:snapshot', {
        takenGameMs = 1000,
        counts = { connected = 1, inMatch = 0 },
        truncated = false,
        matches = {},
        players = { { src = 1, name = 'Xeon', state = 'LOBBY' } },
    })

    -- ...and the timer fires. BR.Sched drives both jobs; step twice past the
    -- interval so ring.snapshot runs.
    fakeTime = 10000
    BR.Sched.step(fakeTime)

    local req = lastRequest()
    ok(req ~= nil, 'a snapshot push goes out')
    ok(req and req.method == 'POST', 'as a POST')
    ok(req and req.headers['X-Ringmaster-Secret'] == 'sssssssssssssssssssssss1',
        'carrying the shared secret header')

    local body = req and bodyOf(req)
    ok(body and body.v == 1 and body.kind == 'snapshot', 'v1 snapshot envelope')
    ok(body and body.server.bootEpoch == BR.Ring.bootEpoch,
        'stamped with THIS boot epoch')
    ok(body and body.snapshot.players[1].name == 'Xeon',
        'wrapping the snapshot br_core provided')
    ok(body and type(body.server.wallMs) == 'number' and body.server.gameMs == fakeTime,
        'and the clock pair, sampled at send time')

    -- Latest wins: two snapshots between ticks, only the second survives.
    TriggerEvent('br:ringmaster:snapshot', { takenGameMs = 2000, counts = { connected = 1, inMatch = 0 }, truncated = false, matches = {}, players = {} })
    TriggerEvent('br:ringmaster:snapshot', { takenGameMs = 3000, counts = { connected = 2, inMatch = 1 }, truncated = false, matches = {}, players = {} })
    req.cb(202)   -- answer the first push so nothing is artificially in flight
    fakeTime = 12500
    BR.Sched.step(fakeTime)
    local second = bodyOf(lastRequest())
    ok(second and second.snapshot.takenGameMs == 3000,
        'LATEST WINS: the older of two queued snapshots is never sent')

    -- A failed snapshot is dropped, not retried: the next tick with no new
    -- snapshot sends nothing.
    lastRequest().cb(500)
    local before = requestCount()
    fakeTime = 15000
    BR.Sched.step(fakeTime)
    ok(requestCount() == before,
        'a failed snapshot is DROPPED -- no retry, the next real one is better')
end

describe('push.events')
do
    -- Evidence goes through the outbox: refusals and player_seen, ordered,
    -- acked on 2xx, returned to the queue on failure.
    TriggerEvent('br:ringmaster:refusal', { src = 3, name = 'Cheater', reason = 'TOO_FAR', count = 8 })

    identifiers[9] = { 'license:evtest', 'discord:42' }
    BR.Ring.seen = {}
    BR.Ring.capture(9)

    fakeTime = 20000
    BR.Sched.step(fakeTime)

    local req = lastRequest()
    local body = bodyOf(req)
    ok(body and body.kind == 'events', 'an events envelope goes out')
    ok(body and #body.events == 2, 'carrying both queued events', body and #body.events)
    ok(body and body.events[1].kind == 'refusal' and body.events[1].seq == 1,
        'ordered, refusal first, seq from 1')
    ok(body and body.events[2].kind == 'player_seen', 'player_seen second')
    ok(body and body.events[2].data.identifiers.discord == '42',
        'player_seen carries the non-license identifiers')
    ok(body and body.events[2].data.identifiers.license == nil,
        'and not the license twice -- it is the envelope key already')

    -- nack: the batch goes back, and the SAME events retry later in order.
    req.cb(500)
    fakeTime = 25000
    BR.Sched.step(fakeTime)
    local retry = bodyOf(lastRequest())
    ok(retry and retry.kind == 'events' and retry.events[1].seq == 1,
        'a failed batch is retried, order preserved')
    lastRequest().cb(202)

    -- ack drains: nothing further to send.
    local before = requestCount()
    fakeTime = 30000
    BR.Sched.step(fakeTime)
    -- (a snapshot may also fire on this step; count only event envelopes)
    local extraEvents = 0
    for i = before + 1, requestCount() do
        local b = bodyOf(http[i]) or {}
        if b.kind == 'events' then extraEvents = extraEvents + 1 end
    end
    ok(extraEvents == 0, 'an acked batch is gone -- the queue drains to silence')
end

-- ------------------------------------------------------------- ban gate ---
--
-- THE PROPERTY UNDER TEST IS "ALWAYS RESOLVES". A deferral that never calls
-- done() strands a human on a connecting screen with no error anywhere, and it
-- is the only bug in this codebase that can waste somebody's evening in
-- complete silence. Every case below asserts a resolution, and several assert
-- that it happened exactly once.

describe('ban gate')

-- Stand in for br_ddb's JS half: record the question instead of answering it,
-- so each test decides what comes back and when.
local banChecks = {}
AddEventHandler('br:ddb:banCheck', function(req, license)
    banChecks[#banChecks + 1] = { req = req, license = license }
end)
local function lastBanCheckReq()
    return banChecks[#banChecks] and banChecks[#banChecks].req
end
local function lastBanCheckLicense()
    return banChecks[#banChecks] and banChecks[#banChecks].license
end

do
    --- Wrap a function the way FIVEM ACTUALLY DOES.
    ---
    --- THIS IS THE WHOLE POINT OF THIS BLOCK. FiveM passes functions across the
    --- runtime boundary as function REFERENCES -- tables with a `__call`
    --- metamethod -- so every member of the real deferrals object reports
    --- `type() == 'table'`, not 'function'.
    ---
    --- The original stub used plain Lua functions, which meant the tests
    --- validated the gate against the SAME wrong assumption the gate was built
    --- on: that `type(deferrals.defer) == 'function'`. Every case passed while
    --- the gate refused to act on every real connect. A stub that is more
    --- convenient than the thing it stands in for tests nothing.
    local function fnRef(fn)
        -- __call receives the table as its first argument; drop it so the
        -- wrapped function sees the same arguments the caller passed.
        return setmetatable({}, { __call = function(_, ...) return fn(...) end })
    end

    -- A stand-in for FiveM's deferrals object that records what was done to it.
    local function newDeferrals()
        local d = { deferred = false, updates = {}, doneCount = 0, doneArg = nil }
        d.defer = fnRef(function() d.deferred = true end)
        d.update = fnRef(function(msg) d.updates[#d.updates + 1] = msg end)
        d.done = fnRef(function(reason)
            d.doneCount = d.doneCount + 1
            d.doneArg = reason
        end)
        return d
    end

    local BANNED = 'license:1111111111111111111111111111111111111111'
    identifiers[70] = { BANNED, 'discord:900' }

    local function connect(src)
        local d = newDeferrals()
        source = src
        TriggerEvent('playerConnecting', 'Someone', function() end, d)
        return d
    end

    -- The most important case: br_ddb answers nothing at all, ever.
    resourceState.br_ddb = 'started'
    local d = connect(70)
    ok(d.deferred, 'defers while it asks')
    ok(d.doneCount == 0, 'does not resolve before an answer arrives')
    fireTimers()
    ok(d.doneCount == 1, 'a silent br_ddb still resolves -- the timeout fires')
    ok(d.doneArg == nil, 'and it FAILS OPEN: no reason means admitted')

    -- A clean "not banned".
    d = connect(70)
    local req = lastBanCheckReq()
    TriggerEvent('br:ddb:banResult', req, false, {})
    ok(d.doneCount == 1 and d.doneArg == nil, 'an unbanned player is admitted')

    -- An error from br_ddb: credentials, route, throttle -- all fail open.
    d = connect(70)
    TriggerEvent('br:ddb:banResult', lastBanCheckReq(), false, { error = 'no credentials' })
    ok(d.doneCount == 1 and d.doneArg == nil, 'a br_ddb error fails open')

    -- An actual ban.
    d = connect(70)
    TriggerEvent('br:ddb:banResult', lastBanCheckReq(), true, {
        reason = 'Aimbot in match 3', expiresAt = nil,
    })
    ok(d.doneCount == 1, 'a banned player is resolved')
    ok(type(d.doneArg) == 'string' and d.doneArg:find('banned'),
        'refused with a message', d.doneArg)
    ok(d.doneArg:find('Aimbot in match 3', 1, true),
        'the message carries the admin-written reason')
    ok(d.doneArg:find('does not expire', 1, true),
        'a permanent ban says so')

    -- A temporary ban reports remaining time rather than a raw timestamp.
    d = connect(70)
    TriggerEvent('br:ddb:banResult', lastBanCheckReq(), true, {
        reason = 'Cooling off', expiresAt = (os.time() + 2 * 86400) * 1000,
    })
    ok(d.doneArg and d.doneArg:find('Expires in 2 days', 1, true),
        'a temporary ban says when it ends', d.doneArg)

    -- A ban with no reason recorded still produces a sentence.
    d = connect(70)
    TriggerEvent('br:ddb:banResult', lastBanCheckReq(), true, {})
    ok(d.doneArg and d.doneArg:find('No reason recorded', 1, true),
        'a reasonless ban still explains itself')

    -- Double-resolution: the answer arrives AND the timer fires.
    d = connect(70)
    local dupReq = lastBanCheckReq()
    TriggerEvent('br:ddb:banResult', dupReq, false, {})
    fireTimers()
    ok(d.doneCount == 1, 'answer then timeout resolves exactly once')

    -- ...and a late duplicate answer for a request already settled.
    d = connect(70)
    local lateReq = lastBanCheckReq()
    TriggerEvent('br:ddb:banResult', lateReq, false, {})
    TriggerEvent('br:ddb:banResult', lateReq, true, { reason = 'too late' })
    ok(d.doneCount == 1 and d.doneArg == nil,
        'a late second answer cannot un-admit somebody')

    -- No br_ddb at all: the gate must not charge every player its timeout.
    resourceState.br_ddb = 'missing'
    d = connect(70)
    ok(not d.deferred and d.doneCount == 0,
        'without br_ddb the gate is a no-op, not a five-second tax')
    resourceState.br_ddb = 'started'

    -- A player with no license cannot be matched against a ban list keyed on
    -- license. Admitted rather than refused on a guess.
    identifiers[71] = { 'discord:901' }
    d = connect(71)
    ok(d.doneCount == 1 and d.doneArg == nil, 'no license means admitted, not refused')
end

-- ----------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
