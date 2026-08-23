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
    -- BR.Config.Community.discordUrl, which appeal.lua reads at call time. The
    -- REST of the config chain the manifest loads (match, admin, overrides) is
    -- deliberately absent: what turns a convar into that value is tested in
    -- tools/test_config.lua against the real parser, and loading overrides.lua
    -- into a harness that stubs GetConvar would test the stub.
    'br_lib/config/community.lua',
    'br_ringmaster/server/config.lua',
    'br_ringmaster/server/main.lua',
    -- Before gate.lua, as the manifest has it: the gate's rejection message
    -- goes through this on its way to the player.
    'br_ringmaster/server/appeal.lua',
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

    -- ----------------------------------------------------- the appeal line ---
    --
    -- THE OWNER'S SENTENCE, WORD FOR WORD, ON THE END OF A BAN NOTICE. Every
    -- case above ran with br_discordUrl unset, which is the default and is the
    -- state the whole block was written in -- so those assertions are also the
    -- proof that an unconfigured server's ban message is byte-for-byte what it
    -- was before this existed.
    local APPEAL = 'Please join our Discord to discuss or appeal: '

    d = connect(70)
    TriggerEvent('br:ddb:banResult', lastBanCheckReq(), true, { reason = 'Aimbot' })
    ok(d.doneArg and d.doneArg:find('Discord', 1, true) == nil,
        'with no br_discordUrl set, a ban notice says nothing about Discord',
        d.doneArg)

    BR.Config.Community.discordUrl = 'https://discord.gg/PggjJ7hDSg'

    d = connect(70)
    TriggerEvent('br:ddb:banResult', lastBanCheckReq(), true, { reason = 'Aimbot' })
    ok(d.doneArg and d.doneArg:find(
        APPEAL .. 'https://discord.gg/PggjJ7hDSg', 1, true) ~= nil,
        'and with it set the sentence is on the end, verbatim, with the address',
        d.doneArg)
    ok(d.doneArg and d.doneArg:find('Aimbot', 1, true) ~= nil
       and d.doneArg:find('does not expire', 1, true) ~= nil,
        'without displacing the reason or the expiry it already carried',
        d.doneArg)
    ok(d.doneArg and d.doneArg:sub(-#'https://discord.gg/PggjJ7hDSg')
       == 'https://discord.gg/PggjJ7hDSg',
        'and it is the LAST thing on the message, which is what "append" means',
        d.doneArg)

    -- ONCE. rejection() is used by the deferral AND by the late-answer removal,
    -- and dropByLicense deliberately does not append -- so a message that
    -- carried it twice would mean the append had migrated into the drop.
    local n, at = 0, 1
    while true do
        local i = d.doneArg:find(APPEAL, at, true)
        if not i then break end
        n, at = n + 1, i + 1
    end
    ok(n == 1, 'exactly once, however many composers the path went through',
        ('found %d times'):format(n))

    -- A BAN WITH NOTHING ELSE TO SAY STILL SAYS IT.
    d = connect(70)
    TriggerEvent('br:ddb:banResult', lastBanCheckReq(), true, {})
    ok(d.doneArg and d.doneArg:find('No reason recorded', 1, true) ~= nil
       and d.doneArg:find(APPEAL, 1, true) ~= nil,
        'a reasonless ban gets the line too -- "always" was the instruction',
        d.doneArg)

    -- AN EMPTY CONVAR IS UNSET, NOT SET-TO-NOTHING. `set br_discordUrl ""` is a
    -- convar that IS set, so it never reaches its default, and a naive test
    -- would put a dangling colon on the end of a ban notice.
    BR.Config.Community.discordUrl = '   '
    d = connect(70)
    TriggerEvent('br:ddb:banResult', lastBanCheckReq(), true, { reason = 'Aimbot' })
    ok(d.doneArg and d.doneArg:find('appeal', 1, true) == nil,
        'a blank br_discordUrl prints no line at all, rather than a dangling one',
        d.doneArg)

    BR.Config.Community.discordUrl = ''
end

-- --------------------------------------------------------------- brkick ---

describe('kick carries the appeal line')
do
    -- kick.lua IS LOADED HERE RATHER THAN AT THE TOP, and the reason is one file
    -- above: slice1.read-only asserts this resource registers exactly two
    -- commands, and `brkick` is a third. Loading it late keeps that gate meaning
    -- what it says while still exercising the real command.
    local dropped = {}
    function DropPlayer(src, reason) dropped[#dropped + 1] = { src = src, reason = reason } end

    -- GetPlayers answers STRINGS, which is what FiveM does and what
    -- findByLicense passes straight into the identifier natives -- so the
    -- identifier table is keyed the same way rather than by number. A stub that
    -- were tidier than the engine would test the tidiness.
    local KICKED = 'license:2222222222222222222222222222222222222222'
    identifiers['80'] = { KICKED, 'discord:800' }
    GetPlayers = function() return { '80' } end

    loadAll({ 'br_ringmaster/server/kick.lua' })
    ok(commands['brkick'] ~= nil and commands['brkick'].restricted == true,
        'brkick is registered, and restricted like every other br* command')

    --- Run brkick the way dispatch.sh types it: license, reason words, command id.
    local function kick(reason)
        dropped = {}
        local args = { KICKED }
        for w in reason:gmatch('%S+') do args[#args + 1] = w end
        args[#args + 1] = 'cmd-1'
        commands['brkick'].fn(0, args, '')
        return dropped[#dropped]
    end

    BR.Config.Community.discordUrl = ''
    local d = kick('Aimbot in match 3')
    ok(d and d.reason == 'Aimbot in match 3',
        'with no br_discordUrl the player is told the reason and nothing else',
        d and d.reason)

    BR.Config.Community.discordUrl = 'https://discord.gg/PggjJ7hDSg'
    d = kick('Aimbot in match 3')
    ok(d and d.reason == 'Aimbot in match 3\n\n'
       .. 'Please join our Discord to discuss or appeal: https://discord.gg/PggjJ7hDSg',
        'and with it set the whole message is the reason, then the sentence',
        d and d.reason)

    -- THE REASON IS STILL THE REASON. The console writes an audit row against
    -- what the admin typed, and a kick that quietly filed "Aimbot ... appeal:
    -- https://..." as the reason would put our own URL in the moderation log.
    d = kick('No reason given')
    ok(d and d.reason:sub(1, #'No reason given') == 'No reason given',
        'the admin-written reason still leads the message', d and d.reason)

    -- PUT THE BENCH BACK. Both of these are globals and the br_core block far
    -- below runs in the same Lua state; a roster left believing there is a
    -- player 80 in it is the kind of cross-test coupling that gets blamed on
    -- whichever suite happens to fail first.
    BR.Config.Community.discordUrl = ''
    GetPlayers = function() return {} end
end

-- ------------------------------------------------------- the config chain ---

describe('br_ringmaster loads the config chain the appeal line needs')
do
    -- THE ONE PART OF THIS FEATURE NOTHING ELSE CAN SEE. Every assertion above
    -- sets BR.Config.Community.discordUrl by hand, because what turns a convar
    -- into that value is tested against the real parser in tools/test_config.lua
    -- -- which leaves exactly one link untested: whether THIS resource's Lua
    -- state ever loads the file that defines it, and the override file that
    -- fills it in.
    --
    -- BOTH FAILURES ARE SILENT AND ONE IS WORSE THAN THE OTHER.
    --
    -- Drop config/community.lua and the key is nil in this state, appeal.lua
    -- reads nil, and no kick ever carries the line however carefully the convar
    -- was set. Drop config/overrides.lua and the key is the committed default,
    -- '', forever -- the same symptom with a different cause. Neither errors.
    --
    -- Drop config/match.lua and keep overrides.lua and it is the reverse: this
    -- resource REFUSES TO START, on any box where br_maxSquadSize is set, which
    -- is every dev box. overrides.lua raises on a set convar naming a BR.Config
    -- group its state has not loaded -- correctly; that check is what stops a
    -- renamed key becoming a value nothing reads. A state that reads the spec
    -- has to carry every group in it.
    local function slurp(path)
        local f = io.open(path, 'r')
        if not f then return nil end
        local s = f:read('*a')
        f:close()
        return s
    end

    local manifest = slurp(ROOT .. 'br_ringmaster/fxmanifest.lua')
    ok(manifest ~= nil, 'br_ringmaster/fxmanifest.lua is readable')
    manifest = manifest or ''

    --- Where an UNCOMMENTED declaration of `rel` appears, or nil.
    ---
    --- Commented lines do not count, and that is not hypothetical: these
    --- manifests are half prose, and verify.sh's own ordering gate was written
    --- after `-- '@br_lib/config/overrides.lua',` satisfied a plain grep while
    --- loading nothing.
    local function declaredAt(rel)
        local n = 0
        for line in (manifest .. '\n'):gmatch('([^\n]*)\n') do
            n = n + 1
            local trimmed = line:gsub('^%s+', '')
            if not trimmed:match('^%-%-') and trimmed:find(rel, 1, true) then
                return n
            end
        end
        return nil
    end

    local community = declaredAt("'@br_lib/config/community.lua'")
    local overrides = declaredAt("'@br_lib/config/overrides.lua'")

    ok(community ~= nil,
        'it loads config/community.lua, which is where discordUrl is defined')
    ok(overrides ~= nil,
        'and config/overrides.lua, which is what puts the convar into it')
    ok(community ~= nil and overrides ~= nil and overrides > community,
        'in that order -- overrides.lua edits the tables above it, so loading '
        .. 'it first edits nothing',
        ('community at %s, overrides at %s'):format(tostring(community),
                                                    tostring(overrides)))

    -- EVERY GROUP THE SPEC NAMES, read out of the spec rather than listed here,
    -- so adding a tunable extends this check for free.
    local spec = slurp(ROOT .. 'br_lib/config/overrides.lua') or ''
    local groups = {}
    for g in spec:gmatch("group%s*=%s*'([%w_]+)'") do groups[g] = true end

    local found = false
    for _ in pairs(groups) do found = true break end
    ok(found, 'the override spec names at least one config group')

    -- The one hand-written mapping, and it is deliberately a mapping rather
    -- than a lowercase() of the group name: a new group with no line here is a
    -- red build, which is the moment to decide whether this resource needs it.
    local GROUP_FILE = { Match = 'match', Admin = 'admin', Community = 'community' }

    for group in pairs(groups) do
        local file = GROUP_FILE[group]
        ok(file ~= nil,
            ("the override spec's '%s' group has a file named in this test")
                :format(group),
            'add it to GROUP_FILE, then decide whether br_ringmaster loads it')
        if file then
            local where = declaredAt(("'@br_lib/config/%s.lua'"):format(file))
            ok(where ~= nil and overrides ~= nil and where < overrides,
                ("and br_ringmaster loads config/%s.lua before overrides.lua, "
                 .. "or a set convar in the '%s' group stops this resource dead")
                    :format(file, group),
                ('%s at %s'):format(file, tostring(where)))
        end
    end
end

-- ======================================================================== --
-- THE SERVER HALF OF A CRATE CLAIM  (br_core/server/loot.lua)
-- ======================================================================== --
--
-- WHY THIS LIVES AT THE BOTTOM OF THE RINGMASTER SUITE, which is otherwise a
-- strange place for it. br_core is loaded HERE and not at the top because the
-- Slice-1 gate above counts the commands registered up to that point and
-- asserts there are exactly two; br_core/server/loot.lua registers two more of
-- its own (brlootseed, brcrate). Everything above this line is br_ringmaster
-- and is finished asserting by the time the first br_core file is read.
--
-- WHAT THIS BLOCK IS FOR. #129 was a client bug: a FiveM native answered `1`
-- rather than `true`, so `isHeld` was false every frame and LOOT_CLAIM was
-- never sent for a crate -- not once, in any session, ever. The client now
-- sends one, which means the container branch of the claim handler is about to
-- run in play for the first time.
--
-- Every case below drives the REAL AddEventHandler(BR.Net.LOOT_CLAIM) handler
-- in br_core/server/loot.lua through the harness's own dispatch, against a
-- REAL generated layout (BR.BuildLootLayout) and the REAL registry, and
-- asserts on the resulting ENTRY LIST -- what is on the ground afterwards and
-- what the client was told -- rather than on any function having been called.
-- Nothing in br_core is stubbed: BR.Roster, BR.Server, BR.Inv, BR.Loot and the
-- generator are the shipping files. The only stubs are FiveM natives.

-- Natives br_core needs and br_ringmaster does not. Defined now rather than at
-- the top so the blocks above run against exactly the surface they were
-- written for.
function GetPlayerPed(src) return 1000 + (tonumber(src) or 0) end
function GetEntityCoords() return { x = 0.0, y = 0.0, z = 0.0 } end
function GetEntityHealth() return 200 end
function GetPedArmour() return 0 end
function SetPlayerRoutingBucket() end
function SetRoutingBucketPopulationEnabled() end
function DropPlayer() end
function RegisterNetEvent() end
function GetCurrentResourceName() return 'br_core' end

--- Everything the server sent to a client, in order.
local sent = {}
function TriggerClientEvent(event, target, ...)
    sent[#sent + 1] = { event = event, target = target, args = { ... } }
end

loadAll({
    'br_lib/shared/protocol.lua',
    'br_lib/shared/names.lua',
    'br_lib/shared/rng.lua',
    'br_lib/shared/geo.lua',
    'br_lib/shared/clock.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/weapons.lua',
    'br_lib/config/loot.lua',
    'br_lib/shared/loot_gen.lua',
    'br_core/server/main.lua',
    'br_core/server/broadcast.lua',
    'br_core/server/roster.lua',
    'br_core/server/inventory.lua',   -- BR.Inv, for the non-container path
    'br_core/server/loot.lua',
})

local LOOT = BR.Config.Loot

--- Dispatch a net event AS THE SERVER RECEIVES IT: `source` set, every
--- registered handler run. Same shape the ban gate above uses.
local function fire(name, src, payload)
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(payload) end
end

--- Where the outbound log currently ends, so a test can read only what its own
--- claim produced.
local function mark() return #sent end

--- Every message sent to `target` since `from`, optionally of one event name.
local function heard(from, target, event)
    local out = {}
    for i = from + 1, #sent do
        local s = sent[i]
        if s.target == target and (not event or s.event == event) then
            out[#out + 1] = s
        end
    end
    return out
end

--- The notice texts a player was shown since `from`. The distinction between
--- "refused with a reason" and "refused in silence" is the whole point of the
--- refusal block below, so it gets its own reader.
local function notices(from, target)
    local out = {}
    for _, s in ipairs(heard(from, target, BR.Net.NOTIFY)) do
        out[#out + 1] = s.args[1] and s.args[1].text or ''
    end
    return out
end

--- The registry, flattened to comparable strings. A refusal must leave this
--- IDENTICAL -- not merely leave the claimed entry alone, which would miss a
--- refusal that scattered contents on its way out.
local function worldOf(m)
    local out, n = {}, 0
    for id, e in pairs(m.loot.items) do
        out[id] = ('%s|%s|%.3f|%.3f|%s|%s|%d'):format(
            tostring(e.kind), tostring(e.item), e.x, e.y,
            tostring(e.prop), tostring(e.cell), e.contents and #e.contents or -1)
        n = n + 1
    end
    out.n = n
    return out
end

local function sameWorld(a, b)
    for id, v in pairs(a) do if b[id] ~= v then return false, id end end
    for id in pairs(b) do if a[id] == nil then return false, id end end
    return true
end

--- What an id currently is, or nil if the entry is gone. Nil-tolerant on
--- purpose: these tests have to survive a claim handler that does nothing at
--- all and still report a COUNT, because the count is the sanity check.
local function kindOf(m, id)
    local e = m.loot.items[id]
    return e and e.kind or nil
end

--- Entries born since `fromId`, which is what "the contents actually spawned"
--- means in observable terms.
local function newborn(m, fromId)
    local out = {}
    for id = fromId + 1, m.loot.nextId do
        if m.loot.items[id] then out[#out + 1] = m.loot.items[id] end
    end
    return out
end

--- item id -> count, for comparing what was in the crate against what is now
--- on the floor without depending on scatter order.
local function tally(stacks, key)
    local out = {}
    for _, s in ipairs(stacks) do
        local k = s[key or 'item']
        out[k] = (out[k] or 0) + 1
    end
    return out
end

local function tallyEq(a, b)
    for k, v in pairs(a) do if b[k] ~= v then return false, k end end
    for k in pairs(b) do if a[k] == nil then return false, k end end
    return true
end

--- Walk a player up to an entry the way a client does: position first, then
--- the cell subscription. LOOT_CLAIM refuses anything outside the subscription,
--- so a test that skipped this would be testing the refusal, not the claim.
local function walkTo(src, e)
    BR.Roster.get(src).pos = { x = e.x, y = e.y, z = e.z }
    local cx, cy = BR.LootCellOf(e.x, e.y)
    fire(BR.Net.LOOT_CELL, src, { cx = cx, cy = cy })
end

--- The next sealed crate with at least `least` things in it. Tests take a
--- fresh one each time rather than resetting the world, so an earlier block
--- cannot leave a later one claiming a husk by accident.
local function firstSealed(m, least)
    for id = 1, m.loot.nextId do
        local e = m.loot.items[id]
        if e and e.kind == 'chest' and #(e.contents or {}) >= (least or 1) then
            return e
        end
    end
    return nil
end

--- Move past the claim rate limiter's one-second window. Claims are 4/s, and
-- several blocks below spend the whole budget deliberately.
local function nextSecond() fakeTime = fakeTime + 2000 end

-- One world, generated from a pinned seed, shared by the blocks below. Two
-- players in it, both ALIVE, plus a third attached to a match whose loot has
-- already been torn down.
local theMatch = { id = 1, state = BR.MatchState.PLAYING, bucket = 1 }
do
    BR.Server.matches[1] = theMatch
    BR.Server.matches[2] = { id = 2, state = BR.MatchState.CLEANUP, bucket = 2 }
    for _, src in ipairs({ 101, 102, 103, 104 }) do BR.Roster.add(src) end
    BR.Roster.setMatch(101, 1); BR.Roster.setState(101, BR.PlayerState.ALIVE)
    BR.Roster.setMatch(102, 1); BR.Roster.setState(102, BR.PlayerState.ALIVE)
    BR.Roster.setState(103, BR.PlayerState.WARMUP)      -- the shared pad
    BR.Roster.setMatch(104, 2); BR.Roster.setState(104, BR.PlayerState.ALIVE)
    BR.Loot.begin(theMatch, 90210)
end

describe('loot.chest.open')
do
    -- THE CASE THAT HAS NEVER RUN IN PLAY. A player standing on a sealed crate
    -- they have been streamed, claiming it once.
    local crate = firstSealed(theMatch, 2)
    ok(crate ~= nil, 'the generated layout contains a sealed crate to open')

    local wanted   = tally(crate.contents)
    local nInside  = #crate.contents
    local cx, cy = crate.x, crate.y
    walkTo(101, crate)

    local before = theMatch.loot.nextId
    local at     = mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = crate.id })

    -- 1. THE CONTENTS ARE ON THE GROUND, as entries, by item id. Counting new
    -- ids would pass if the crate scattered three copies of the wrong thing.
    local born = newborn(theMatch, before)
    ok(#born == nInside, 'opening a crate lays exactly its contents on the ground',
        ('%d entries for %d items'):format(#born, nInside))
    local eq, missing = tallyEq(wanted, tally(born))
    ok(eq, 'and they are the items that were inside it, item for item',
        tostring(missing))

    -- Nothing born from a crate is itself a container, or the world grows.
    local nested = 0
    for _, e in ipairs(born) do
        if e.kind == 'chest' or e.kind == 'deathbox' or e.kind == 'husk' then
            nested = nested + 1
        end
    end
    ok(nested == 0, 'and none of them is another container')

    -- REACHABLE FROM WHERE THE CRATE WAS. Contents that land outside the
    -- server's own pickup reach are contents the opener has to go hunting for.
    local furthest, coincident = 0.0, false
    for i, e in ipairs(born) do
        local d = BR.Dist(e.x, e.y, cx, cy)
        if d > furthest then furthest = d end
        for j = i + 1, #born do
            if BR.Dist(e.x, e.y, born[j].x, born[j].y) < 0.01 then coincident = true end
        end
    end
    ok(furthest <= LOOT.pickupDistance + 4.0,
        'all of it inside the reach the server itself enforces',
        ('%.2fm'):format(furthest))
    ok(not coincident, 'laid out in a ring -- nothing lands inside anything else')

    -- 2. THE CRATE STAYS, OPENED, under its own id.
    local husk = theMatch.loot.items[crate.id]
    ok(husk ~= nil, 'the crate entry survives the claim')
    ok(husk and husk.kind == 'husk' and husk.item == 'husk', 'as a husk')
    ok(husk and husk.prop == LOOT.chestOpenProp, 'wearing the opened model')
    ok(husk and husk.contents == nil, 'holding nothing')
    ok(husk and math.abs(husk.x - cx) < 0.001 and math.abs(husk.y - cy) < 0.001,
        'exactly where the sealed one stood')
    ok(husk and theMatch.loot.cells[husk.cell]
        and theMatch.loot.cells[husk.cell][husk.id],
        'and still indexed in its cell, so it streams to whoever walks up next')

    -- 3. THE CLIENT WAS TOLD, and told the right things. The husk arrives under
    -- the ORIGINAL id so the client swaps a model instead of deleting a prop
    -- and streaming a new one.
    local sawHusk, sawContents, leaked = false, 0, false
    for _, s in ipairs(heard(at, 101, BR.Net.LOOT_ADD)) do
        for _, w in ipairs(s.args[1]) do
            if w.id == crate.id and w.kind == 'husk' then sawHusk = true end
            if w.id > before then sawContents = sawContents + 1 end
            if w.contents ~= nil then leaked = true end
        end
    end
    ok(sawHusk, 'the opener is sent the husk under the crate\'s original id')
    ok(sawContents == nInside, 'and every scattered item',
        ('%d of %d'):format(sawContents, nInside))
    ok(not leaked, 'with no container contents on the wire, ever')

    -- THE ARC ORIGIN travels with the item, which is the whole reason fx/fy/fl
    -- exist: the client throws the prop out of the crate's mouth rather than
    -- popping it into being on the grass. `fl` is a LIFT above the ground the
    -- client probed, never an absolute z -- an absolute one burst items out of
    -- the floor wherever the authored z sat below the real ground.
    local arced = 0
    for _, s in ipairs(heard(at, 101, BR.Net.LOOT_ADD)) do
        for _, w in ipairs(s.args[1]) do
            if w.id > before
                and w.fx and math.abs(w.fx - cx) < 0.001
                and w.fy and math.abs(w.fy - cy) < 0.001
                and w.fl == (LOOT.crateMouthHeight or 0.6) then
                arced = arced + 1
            end
        end
    end
    ok(arced == nInside, 'each one carrying the crate it came out of as its arc origin',
        ('%d of %d'):format(arced, nInside))

    -- A MATCH crate is not a pad crate: nothing is queued to come back.
    ok(#theMatch.loot.respawn == 0,
        'a crate opened in a match schedules no respawn')
end

describe('loot.chest.husk')
do
    -- AN OPENED CRATE CANNOT BE OPENED AGAIN. If it could, one crate would be
    -- an infinite loot fountain -- which is the failure mode that makes this
    -- the single most load-bearing assertion in the file.
    nextSecond()
    local crate = firstSealed(theMatch, 2)
    walkTo(101, crate)
    fire(BR.Net.LOOT_CLAIM, 101, { id = crate.id })
    local husk = theMatch.loot.items[crate.id]
    ok(husk and husk.kind == 'husk', 'a crate is opened')

    nextSecond()
    local was  = worldOf(theMatch)
    local wasN = theMatch.loot.nextId
    local at   = mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = crate.id })

    ok(theMatch.loot.nextId == wasN,
        'claiming the husk spawns no second set of contents',
        ('%d new entries'):format(theMatch.loot.nextId - wasN))
    local same, which = sameWorld(was, worldOf(theMatch))
    ok(same, 'and mutates nothing at all in the registry', 'entry ' .. tostring(which))
    ok(theMatch.loot.items[crate.id] ~= nil, 'the husk itself stays -- it is scenery')

    -- SILENT, and deliberately so: the client already refuses to target a husk
    -- (client/loot.lua:522), so an honest player never produces this claim.
    ok(#heard(at, 101) == 0,
        'a husk claim is refused in COMPLETE SILENCE -- nothing is sent at all')
end

describe('loot.chest.refusals')
do
    -- EVERY GATE ABOVE THE CONTAINER BRANCH, each one asserted twice: the claim
    -- is refused, and the world is byte-identical afterwards. A refusal that
    -- scatters on its way out would pass a "the crate is still sealed" check.
    --
    -- The second column is the deliverable: WHICH OF THESE SAY ANYTHING. A
    -- silent refusal is indistinguishable from #129 -- the player presses the
    -- key, nothing happens, and nothing anywhere says why.

    -- (a) CAN_TAKE[e.state] -- a corpse reaching for a crate.
    nextSecond()
    local crate = firstSealed(theMatch, 2)
    walkTo(101, crate)
    BR.Roster.setState(101, BR.PlayerState.DEAD)
    local was, at = worldOf(theMatch), mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = crate.id })
    ok(sameWorld(was, worldOf(theMatch)), 'a DEAD player cannot open a crate')
    ok(kindOf(theMatch, crate.id) == 'chest', 'it is still sealed')
    -- THE SENTENCE IS ASKED FOR, NOT SPELLED OUT. This pinned the literal, and
    -- when the owner reworded the refusals (2026-08-18) that made a copy of the
    -- text in a fourth place -- the one place nobody greps. refusalText with no
    -- reason IS the default sentence, so what this asserts is the property that
    -- matters: the state refusal says the same thing the reason table falls
    -- back to, whatever that happens to be.
    ok(#notices(at, 101) == 1
        and notices(at, 101)[1] == BR.Loot.refusalText(nil),
        'CAN_TAKE refuses AUDIBLY', table.concat(notices(at, 101), ' / '))
    BR.Roster.setState(101, BR.PlayerState.ALIVE)

    -- (b) rateOk -- the token bucket. Burned on ids that do not exist, so the
    -- budget is spent without opening anything; then a real crate is claimed
    -- inside the same window.
    nextSecond()
    for _ = 1, (LOOT.pickupRateLimit or 4) do
        fire(BR.Net.LOOT_CLAIM, 101, { id = theMatch.loot.nextId + 9999 })
    end
    was, at = worldOf(theMatch), mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = crate.id })
    ok(sameWorld(was, worldOf(theMatch)), 'a rate-limited claim opens nothing')
    ok(kindOf(theMatch, crate.id) == 'chest', 'the crate is still sealed')
    ok(#heard(at, 101) == 0,
        'and the rate limiter refuses in SILENCE -- the server logs it, the player is not told')

    -- ...and the limiter is a window, not a ban: the same crate opens a second
    -- later. Without this the case above would pass on a permanently broken
    -- limiter.
    nextSecond()
    fire(BR.Net.LOOT_CLAIM, 101, { id = crate.id })
    ok(kindOf(theMatch, crate.id) == 'husk',
        'once the window rolls over the same claim succeeds')

    -- (c) not in the client's subscribed cells. Answers IDENTICALLY to an
    -- entry that never existed -- otherwise the refusal text is an existence
    -- oracle over a dense id space.
    nextSecond()
    local outside
    for id = 1, theMatch.loot.nextId do
        local e = theMatch.loot.items[id]
        if e and e.kind == 'chest' and not (theMatch.loot.subs[101] or {})[e.cell] then
            outside = e break
        end
    end
    ok(outside ~= nil, 'the layout has a crate this player was never streamed')
    was, at = worldOf(theMatch), mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = outside.id })
    ok(sameWorld(was, worldOf(theMatch)), 'an unstreamed crate cannot be opened')
    local unseen = notices(at, 101)
    at = mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = theMatch.loot.nextId + 9999 })
    local absent = notices(at, 101)
    ok(#unseen == 1 and unseen[1] == 'Someone beat you to it.',
        'the subscription check refuses AUDIBLY', table.concat(unseen, ' / '))
    ok(#absent == 1 and absent[1] == unseen[1],
        'in the same words as an id that never existed -- no existence oracle')

    -- (d) inReach -- subscribed, in the same 256m cell, 100m from the crate.
    nextSecond()
    local far = firstSealed(theMatch, 2)
    walkTo(101, far)
    BR.Roster.get(101).pos = { x = far.x + 100.0, y = far.y, z = far.z }
    was, at = worldOf(theMatch), mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = far.id })
    ok(sameWorld(was, worldOf(theMatch)), 'a crate 100m away cannot be opened')
    ok(#notices(at, 101) == 1 and notices(at, 101)[1] == 'This crate has a lock on it and cannot be opened.',
        'inReach refuses AUDIBLY, and a CRATE blames a lock, not the distance',
        table.concat(notices(at, 101), ' / '))

    -- (d2) THE SAME REFUSAL, ON SOMETHING THAT IS NOT A CRATE -- AND IT SAYS
    -- THE SAME THING. An earlier version of this case asserted the opposite,
    -- on the reasoning that for a death box the distance answer is at least
    -- true. The owner overruled it: the replacement is one-for-one, with no
    -- exceptions, because a player cannot see a registry position and "too far
    -- away" reads as nonsense whatever the entry happens to be. THIS CASE NOW
    -- EXISTS TO STOP THE KIND BRANCH COMING BACK.
    nextSecond()
    local box2 = BR.Loot.spawnStack(theMatch, {
        item = 'deathbox', kind = 'deathbox', rarity = BR.Rarity.RARE, count = 1,
        contents = { { item = 'bandage', kind = BR.ItemKind.CONSUMABLE, rarity = 1, count = 1 } },
    }, far.x, far.y, far.z)
    was, at = worldOf(theMatch), mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = box2.id })
    ok(sameWorld(was, worldOf(theMatch)), 'a death box 100m away cannot be opened either')
    ok(#notices(at, 101) == 1 and notices(at, 101)[1] == 'This crate has a lock on it and cannot be opened.',
        'and it gets the SAME sentence -- the replacement is not kind-aware',
        table.concat(notices(at, 101), ' / '))

    -- (e) no zone: ALIVE, in a match whose loot has been torn down. This is
    -- reachable in play -- a claim in flight when the match cleans up.
    nextSecond()
    was, at = worldOf(theMatch), mark()
    fire(BR.Net.LOOT_CLAIM, 104, { id = far.id })
    ok(sameWorld(was, worldOf(theMatch)),
        'a player whose match has no loot cannot reach another match\'s crates')
    ok(#heard(at, 104) == 0,
        'and is refused in SILENCE -- zoneFor returns before CAN_TAKE is consulted')

    -- (f) the malformed shapes, which must not reach anything.
    at = mark()
    fire(BR.Net.LOOT_CLAIM, 101, 'not a table')
    fire(BR.Net.LOOT_CLAIM, 101, { id = 'seven' })
    fire(BR.Net.LOOT_CLAIM, 101, {})
    fire(BR.Net.LOOT_CLAIM, 999, { id = far.id })   -- no roster entry
    ok(sameWorld(was, worldOf(theMatch)), 'a malformed claim changes nothing')
    ok(#heard(at, 101) == 0 and #heard(at, 999) == 0,
        'and is refused in SILENCE')
end

describe('loot.chest.race')
do
    -- TWO PLAYERS, ONE CRATE, SAME TICK. The normal case at a hot drop, and the
    -- one the whole handler is arranged around. Exactly one set of contents may
    -- reach the ground; a second would be a duplication exploit anybody could
    -- run by accident.
    nextSecond()
    local crate  = firstSealed(theMatch, 2)
    local nInside = #crate.contents
    walkTo(101, crate)
    walkTo(102, crate)

    local before = theMatch.loot.nextId
    local at     = mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = crate.id })
    fire(BR.Net.LOOT_CLAIM, 102, { id = crate.id })

    local born = newborn(theMatch, before)
    ok(#born == nInside,
        'two claims in one tick produce EXACTLY ONE set of contents',
        ('%d entries for %d items'):format(#born, nInside))
    ok(kindOf(theMatch, crate.id) == 'husk', 'and one husk')

    -- Both are subscribed, so both must see the crate open and both must see
    -- the contents -- or the loser is left staring at a sealed prop.
    local sawHusk = { [101] = false, [102] = false }
    for _, who in ipairs({ 101, 102 }) do
        for _, s in ipairs(heard(at, who, BR.Net.LOOT_ADD)) do
            for _, w in ipairs(s.args[1]) do
                if w.id == crate.id and w.kind == 'husk' then sawHusk[who] = true end
            end
        end
    end
    ok(sawHusk[101] and sawHusk[102],
        'both claimants are shown the crate opening, not just the winner')

    -- THE LOSER IS TOLD NOTHING. The loser of a race for a loose item hears
    -- "Someone beat you to it"; the loser of a race for a CRATE hears nothing,
    -- because the second claim lands on a husk and the husk branch is silent.
    ok(#notices(at, 102) == 0,
        'the loser of a CRATE race is given no refusal -- the husk branch is silent')
end

describe('loot.deathbox')
do
    -- A DEATH BOX RETIRES RATHER THAN HUSKING, and the comment in the handler
    -- says why: an empty box left lying there reads as a body nobody has
    -- looted yet, and sends people across open ground for nothing.
    --
    -- Built with the real BR.Loot.spawnStack, because NOTHING IN THE CODEBASE
    -- MINTS A 'deathbox' ENTRY ANY MORE -- BR.Loot.deathBox scatters a kit
    -- directly. The branch is still live in the handler, so it is still tested.
    nextSecond()
    local anchor = firstSealed(theMatch, 1)
    walkTo(101, anchor)

    local box = BR.Loot.spawnStack(theMatch, {
        item = 'deathbox', kind = 'deathbox', rarity = BR.Rarity.RARE, count = 1,
        contents = {
            { item = 'pistol',  kind = BR.ItemKind.WEAPON,     rarity = 1, count = 1, clip = 12 },
            { item = 'bandage', kind = BR.ItemKind.CONSUMABLE, rarity = 1, count = 3 },
        },
    }, anchor.x, anchor.y, anchor.z)
    ok(box ~= nil and theMatch.loot.items[box.id] ~= nil, 'a death box is on the ground')

    local cell   = box.cell
    local before = theMatch.loot.nextId
    local at     = mark()
    fire(BR.Net.LOOT_CLAIM, 101, { id = box.id })

    ok(theMatch.loot.items[box.id] == nil,
        'claiming a death box RETIRES it -- no husk is left behind')
    ok(not (theMatch.loot.cells[cell] or {})[box.id],
        'and it is out of its cell, so it streams to nobody')

    local born = newborn(theMatch, before)
    ok(#born == 2, 'its contents are on the ground', ('%d entries'):format(#born))
    ok(tallyEq({ pistol = 1, bandage = 1 }, tally(born)),
        'item for item, exactly what was in it')

    -- ORDER MATTERS ON THE WIRE: the box is retired before its contents are
    -- announced, so no client ever holds the box and its spilled kit at once.
    local goneAt, addAt
    for i = at + 1, #sent do
        local s = sent[i]
        if s.target == 101 and s.event == BR.Net.LOOT_GONE and not goneAt then
            for _, id in ipairs(s.args[1]) do if id == box.id then goneAt = i end end
        end
        if s.target == 101 and s.event == BR.Net.LOOT_ADD and not addAt then
            for _, w in ipairs(s.args[1]) do if w.id > before then addAt = i end end
        end
    end
    ok(goneAt ~= nil, 'every subscriber is told the box is gone')
    ok(goneAt and addAt and goneAt < addAt,
        'and told that BEFORE the contents arrive')
end

describe('loot.warmup.respawn')
do
    -- THE PAD MUST NOT BE STRIPPABLE. Everybody waiting shares one island, so
    -- whoever queued first opening every crate on it would leave the next
    -- twenty arrivals with nothing to practise on.
    --
    -- THE SHARED ZONE IS PRIVATE TO loot.lua and there is no accessor for it,
    -- so this block never touches the table. It censuses the island the only
    -- way anything outside that file can: a WARMUP player walked across it,
    -- subscribing cell by cell, with BR.Loot.viewFor read at each stop. That is
    -- the same route a real client takes, and it means every number below is
    -- one the game itself could produce.
    nextSecond()
    local pad = BR.Config.Match.warmupPos
    local pcx, pcy = BR.LootCellOf(pad.x, pad.y)
    local size = LOOT.cellSize

    --- Every entry on the pad, id -> wire entry. The island is a 460m annulus
    --- around the pad, so a 5x5 block of 256m cells covers all of it.
    local function census()
        local out = {}
        for dx = -2, 2 do
            for dy = -2, 2 do
                local cx, cy = pcx + dx, pcy + dy
                BR.Roster.get(103).pos =
                    { x = (cx + 0.5) * size, y = (cy + 0.5) * size, z = pad.z or 30.0 }
                fire(BR.Net.LOOT_CELL, 103, { cx = cx, cy = cy })
                for _, w in ipairs(BR.Loot.viewFor(103) or {}) do out[w.id] = w end
            end
        end
        return out
    end

    local function countKind(c, kind)
        local n = 0
        for _, w in pairs(c) do if w.kind == kind then n = n + 1 end end
        return n
    end

    local before = census()
    local sealed0 = countKind(before, 'chest')
    ok(sealed0 > 0, 'the shared pad is stocked with sealed crates',
        ('%d crates'):format(sealed0))

    local padCrate
    for _, w in pairs(before) do if w.kind == 'chest' then padCrate = w break end end

    -- Open it, standing on it, exactly as in a match.
    BR.Roster.get(103).pos = { x = padCrate.x, y = padCrate.y, z = padCrate.z }
    local ccx, ccy = BR.LootCellOf(padCrate.x, padCrate.y)
    fire(BR.Net.LOOT_CELL, 103, { cx = ccx, cy = ccy })
    local highest = 0
    for id in pairs(before) do if id > highest then highest = id end end
    fire(BR.Net.LOOT_CLAIM, 103, { id = padCrate.id })

    local opened = census()
    ok(opened[padCrate.id] and opened[padCrate.id].kind == 'husk',
        'a pad crate opens the same way a match crate does')
    ok(countKind(opened, 'chest') == sealed0 - 1,
        'leaving the island one sealed crate short',
        ('%d -> %d'):format(sealed0, countKind(opened, 'chest')))

    -- Only the respawn job runs. Everything else in br_core and br_ringmaster
    -- is parked, so what follows is attributable to THAT job rather than to a
    -- whole server tick.
    local parked = {}
    for _, j in ipairs(BR.Sched.stats()) do
        if j.name ~= 'loot.warmupRespawn' and j.enabled then
            parked[#parked + 1] = j.name
            BR.Sched.setEnabled(j.name, false)
        end
    end

    -- ONE MILLISECOND EARLY: still short. This is what makes the next
    -- assertion mean "the timer landed" rather than "a crate exists".
    fakeTime = fakeTime + (LOOT.warmup.respawnMs or 45000) - 1
    BR.Sched.step(fakeTime)
    ok(countKind(census(), 'chest') == sealed0 - 1,
        'nothing comes back before the respawn is due')

    fakeTime = fakeTime + 2000
    BR.Sched.step(fakeTime)
    local back = census()
    ok(countKind(back, 'chest') == sealed0,
        'and exactly one crate comes back once it is',
        ('%d of %d'):format(countKind(back, 'chest'), sealed0))

    -- SOMEWHERE ELSE ON THE ISLAND, under a new id: the husk stays put, so a
    -- replacement on the same spot would stack two props in one place.
    local fresh
    for id, w in pairs(back) do
        if id > highest and w.kind == 'chest' then fresh = w break end
    end
    ok(fresh ~= nil, 'as a new entry rather than the old one un-opened')
    ok(fresh and BR.Dist(fresh.x, fresh.y, padCrate.x, padCrate.y) > 1.0,
        'in a different place')
    ok(back[padCrate.id] and back[padCrate.id].kind == 'husk',
        'and the husk it replaces is still standing where it was opened')

    -- A SECOND CLAIM ON THE HUSK MUST NOT QUEUE ANOTHER, or the pad is a crate
    -- printer for anybody willing to press the key twice.
    nextSecond()
    local farmFrom = countKind(census(), 'chest')
    BR.Roster.get(103).pos = { x = padCrate.x, y = padCrate.y, z = padCrate.z }
    fire(BR.Net.LOOT_CELL, 103, { cx = ccx, cy = ccy })
    for _ = 1, 3 do fire(BR.Net.LOOT_CLAIM, 103, { id = padCrate.id }) end
    fakeTime = fakeTime + (LOOT.warmup.respawnMs or 45000) + 2000
    BR.Sched.step(fakeTime)
    ok(countKind(census(), 'chest') == farmFrom,
        'reclaiming a husk queues NO further crates -- the pad cannot be farmed',
        ('%d -> %d'):format(farmFrom, countKind(census(), 'chest')))

    for _, n in ipairs(parked) do BR.Sched.setEnabled(n, true) end
end

-- ===========================================================================
-- THE OTHER HALF OF THE INCIDENT PIPELINE, IN A SANDBOX
-- ===========================================================================
--
-- br_core/server/incident.lua and br_core/server/players.lua are the two files
-- that decide WHO IS TOLD WHAT about a case, and both of those decisions landed
-- with #168 and #169. They belong in this suite because the thing they are
-- about -- an incident becoming real -- is what this whole resource exists for,
-- and because the rule they enforce is a rule about silence: the offender is
-- shown nothing, and no client can ask who is under suspicion. A rule that says
-- "nothing happens" is exactly the kind that passes a playtest by accident.
--
-- IN A SANDBOX, and not loaded alongside br_ringmaster above. Both halves
-- register handlers for `br:ringmaster:refusal` and `br:incident:filed`, so
-- sharing one environment would have every existing case in this file start
-- driving the br_core builder as a side effect -- which is a suite testing
-- something other than what it says. The pattern is test_shared.lua's.

local SANDBOX_STD = {
    ipairs = ipairs, pairs = pairs, next = next, type = type, select = select,
    tostring = tostring, tonumber = tonumber, error = error, pcall = pcall,
    setmetatable = setmetatable, rawget = rawget, rawset = rawset,
    table = table, string = string, math = math, os = os,
}

--- A fresh world, with the smallest amount of br_core that will hold up the two
--- files under test.
---
--- @return table  { fire, filed, clientEvents, roster, incidents, setPrior }
local function newIncidentWorld()
    local env = setmetatable({}, { __index = function(_, k) return SANDBOX_STD[k] end })
    env._G = env

    local S = {
        roster = {},        -- [src] = entry
        licenses = {},      -- [src] = 'license:...'
        out = {},           -- every TriggerClientEvent
        killer = {},        -- [src] = attributed killer src
    }

    local h = {}
    env.AddEventHandler = function(name, fn)
        h[name] = h[name] or {}
        table.insert(h[name], fn)
    end
    env.TriggerEvent = function(name, ...)
        for _, fn in ipairs(h[name] or {}) do fn(...) end
    end
    env.TriggerClientEvent = function(name, src, payload)
        S.out[#S.out + 1] = { name = name, src = src, payload = payload }
    end
    env.RegisterNetEvent = function() end
    env.RegisterCommand  = function() end
    env.GetGameTimer     = function() return 1000 end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.print = function() end
    env.GetNumPlayerIdentifiers = function(src) return S.licenses[src] and 1 or 0 end
    env.GetPlayerIdentifier = function(src) return S.licenses[src] end

    -- Loaded one at a time into THIS env rather than through loadAll above,
    -- which deliberately loads into the global one.
    for _, f in ipairs({
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/shared/identity.lua',
    }) do
        local chunk, err = loadfile(ROOT .. f, 't', env)
        if not chunk then
            realPrint('\27[31msandbox load error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end

    local BRs = env.BR

    -- The smallest roster that answers the two questions these files ask of it.
    BRs.Roster = {
        get = function(src) return S.roster[src] end,
        each = function(pred, fn)
            local ids = {}
            for src in pairs(S.roster) do ids[#ids + 1] = src end
            table.sort(ids)
            for _, src in ipairs(ids) do
                local e = S.roster[src]
                if pred(e) then fn(src, e) end
            end
        end,
    }
    -- players.lua reads the report rules off BR.Config; none of them is under
    -- test here, so they are the smallest values that let the file load.
    BRs.Config = {
        Report = { maxPerMatch = 3, maxTargets = 5, categories = { 'cheating' } },
        isReportCategory = function(c) return c == 'cheating' end,
        defaultReportCategory = function() return 'cheating' end,
    }
    -- The REAL attribution question, answered by a stub, because combat.lua's
    -- own version is a rule about assist windows and is tested where it lives.
    BRs.Combat = { attributedKiller = function(entry) return S.killer[entry.src] end }

    for _, f in ipairs({
        'br_core/server/incident.lua',
        'br_core/server/players.lua',
    }) do
        local chunk, err = loadfile(ROOT .. f, 't', env)
        if not chunk then
            realPrint('\27[31msandbox load error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end

    local W = { env = env, BR = BRs, out = S.out }

    function W.join(src, matchId, license, state)
        S.roster[src] = {
            src = src, name = 'P' .. src, matchId = matchId,
            state = state or BRs.PlayerState.ALIVE,
        }
        S.licenses[src] = license
    end

    function W.killedBy(victim, killer) S.killer[victim] = killer end

    --- The acknowledgement br_ringmaster sends once a row is durable.
    function W.filed(incidentId, matchId, subjectLicense)
        env.TriggerEvent('br:incident:filed', {
            incidentId = incidentId, matchId = matchId,
            subjectLicense = subjectLicense,
        })
    end

    --- A net event from one client.
    function W.fromClient(name, src)
        env.source = src
        env.TriggerEvent(name, nil)
        env.source = nil
    end

    --- Everything sent to clients on one event name.
    function W.sentOn(name)
        local list = {}
        for _, o in ipairs(S.out) do
            if o.name == name then list[#list + 1] = o end
        end
        return list
    end

    function W.clear() for i = #S.out, 1, -1 do S.out[i] = nil end end

    return W
end

describe('incident.announce')
do
    -- #168: everybody in the match is told that reporting exists, once, the
    -- first time anybody in it draws a case -- and the subject is told nothing.
    local W = newIncidentWorld()
    W.join(1, 7, 'license:one')
    W.join(2, 7, 'license:two')
    W.join(3, 7, 'license:cheat')
    W.join(9, 8, 'license:other')          -- a different match entirely

    W.filed('inc-1', 7, 'license:cheat')

    local hints = W.sentOn(W.BR.Net.REPORT_HINT)
    ok(#hints == 2, 'everybody else in the match is told', tostring(#hints))

    local told = {}
    for _, hh in ipairs(hints) do told[hh.src] = hh.payload.kind end
    ok(told[1] == 'exists' and told[2] == 'exists',
        'and what they are told is that reporting exists')

    -- THE RULE THIS TEST EXISTS FOR (#93). An offender who learns they are
    -- under suspicion changes behaviour, which costs the case the evidence it
    -- was going to be made of.
    ok(told[3] == nil, 'the player the incident is ABOUT is told nothing at all')
    ok(told[9] == nil, 'and neither is anybody in another match')

    -- ONCE PER MATCH, however many cases are filed in it. A hint per incident
    -- would nag the whole server every time a persistent cheater tripped the
    -- threshold again.
    W.clear()
    W.filed('inc-2', 7, 'license:cheat')
    W.filed('inc-3', 7, 'license:two')
    ok(#W.sentOn(W.BR.Net.REPORT_HINT) == 0,
        'the second and third cases in the same match announce nothing')

    -- A NEW MATCH IS A CLEAN SHEET, because the people in it are different.
    W.clear()
    W.filed('inc-4', 8, 'license:someone')
    ok(#W.sentOn(W.BR.Net.REPORT_HINT) == 1,
        'the first case in the NEXT match announces again')
end

describe('incident.announce.edges')
do
    local W = newIncidentWorld()
    W.join(1, 7, 'license:one')
    W.join(2, 7, 'license:gone', nil)
    W.BR.Roster.get(2).state = W.BR.PlayerState.LEFT

    W.filed('inc-1', 7, 'license:cheat')
    local hints = W.sentOn(W.BR.Net.REPORT_HINT)
    ok(#hints == 1 and hints[1].src == 1,
        'a player who has already left is not addressed -- their id may be recycled')

    -- NO MATCH, NO AUDIENCE. `brrefuse` from a console and an anticheat firing
    -- in the lobby both file under the no-match sentinel; there is no round for
    -- the nudge to be about.
    local X = newIncidentWorld()
    X.join(1, 7, 'license:one')
    X.filed('inc-lobby', nil, 'license:cheat')
    ok(#X.sentOn(X.BR.Net.REPORT_HINT) == 0,
        'an incident filed outside a match announces to nobody')
end

describe('report.killedBy')
do
    -- #169: killed by somebody who ALREADY has a case open, and only then.
    local W = newIncidentWorld()
    W.join(1, 7, 'license:victim', W.BR.PlayerState.DEAD)
    W.join(2, 7, 'license:suspect')
    W.join(3, 7, 'license:clean')
    W.killedBy(1, 2)

    -- No case yet: the prompt would be an invitation to report whoever just
    -- killed you, which is a machine for generating noise.
    W.fromClient(W.BR.Net.REPORT_KILLED, 1)
    ok(#W.sentOn(W.BR.Net.REPORT_HINT) == 0,
        'a killer with no incident against them produces nothing at all')

    -- Now there is one. The announcement fires too, so filter to the nudge.
    W.filed('inc-1', 7, 'license:suspect')
    W.clear()

    W.fromClient(W.BR.Net.REPORT_KILLED, 1)
    local hints = W.sentOn(W.BR.Net.REPORT_HINT)
    ok(#hints == 1 and hints[1].src == 1, 'the victim is prompted', tostring(#hints))
    ok(hints[1] and hints[1].payload.kind == 'killer',
        'with the killer-flavoured prompt')
    ok(hints[1] and hints[1].payload.name == 'P2',
        'naming the killer by their display name')

    -- NOTHING ON THE WIRE THAT NAMES A PLAYER THE CLIENT COULD NOT ALREADY SEE.
    -- No license, no incident id, no list -- see the handler's own note.
    local p = hints[1] and hints[1].payload or {}
    local keys = {}
    for k in pairs(p) do keys[#keys + 1] = k end
    table.sort(keys)
    ok(table.concat(keys, ',') == 'kind,name',
        'and the payload carries only the occasion and a display name',
        table.concat(keys, ','))

    -- ONCE. A client that fires this every frame gets one answer, because the
    -- latch is the server's.
    W.clear()
    W.fromClient(W.BR.Net.REPORT_KILLED, 1)
    W.fromClient(W.BR.Net.REPORT_KILLED, 1)
    ok(#W.sentOn(W.BR.Net.REPORT_HINT) == 0,
        'asking again about the same killer answers nothing')
end

describe('report.killedBy.refusals')
do
    local W = newIncidentWorld()
    W.join(1, 7, 'license:victim')          -- ALIVE
    W.join(2, 7, 'license:suspect')
    W.killedBy(1, 2)
    W.filed('inc-1', 7, 'license:suspect')
    W.clear()

    -- A LIVING PLAYER HAS NOT BEEN KILLED BY ANYBODY, so there is nothing to
    -- answer -- and answering would turn this into a probe usable at any time.
    W.fromClient(W.BR.Net.REPORT_KILLED, 1)
    ok(#W.sentOn(W.BR.Net.REPORT_HINT) == 0, 'a living player is told nothing')

    W.BR.Roster.get(1).state = W.BR.PlayerState.DBNO
    W.fromClient(W.BR.Net.REPORT_KILLED, 1)
    ok(#W.sentOn(W.BR.Net.REPORT_HINT) == 0,
        'and neither is one who is only downed -- being knocked is not being killed')

    W.BR.Roster.get(1).state = W.BR.PlayerState.DEAD
    W.fromClient(W.BR.Net.REPORT_KILLED, 1)
    ok(#W.sentOn(W.BR.Net.REPORT_HINT) == 1, 'a dead player is')

    -- NOBODY THE SERVER DOES NOT KNOW ABOUT. A client that is not in the roster
    -- at all cannot use this to find out anything.
    W.clear()
    W.fromClient(W.BR.Net.REPORT_KILLED, 99)
    ok(#W.sentOn(W.BR.Net.REPORT_HINT) == 0, 'a stranger asking is answered with silence')

    -- THE STORM, A FALL, A FIRE. No attributed killer means no prompt, and the
    -- server decides that from its own damage records rather than from a claim.
    local X = newIncidentWorld()
    X.join(1, 7, 'license:victim', X.BR.PlayerState.DEAD)
    X.join(2, 7, 'license:suspect')
    X.filed('inc-1', 7, 'license:suspect')
    X.clear()
    X.fromClient(X.BR.Net.REPORT_KILLED, 1)   -- killedBy was never set
    ok(#X.sentOn(X.BR.Net.REPORT_HINT) == 0,
        'dying to the storm prompts nothing -- there is no killer to report')
end


-- ======================================================================== --
-- THE MATCH TIMELINE ON AN INCIDENT  (#30)
-- ======================================================================== --
--
-- An incident should show the match around it: when the match started, every
-- kill by the offender before AND after the report, the corroborations, and
-- when the match ended.
--
-- WHAT MAKES THESE CASES WORTH WRITING RATHER THAN ASSUMING. Two of them are
-- about ORDER, and order bugs in this project have shipped as features that look
-- correct and record nothing:
--
--   * server/evidence.lua discards the buffer on `br:match:destroyed`, and
--     br_core's manifest loads it at line 114 -- twenty-four lines BEFORE
--     server/incident.lua, which is where the close is built. FiveM runs handlers
--     in registration order. So a close that listened to `br:match:destroyed`
--     would read an empty buffer, write a timeline with no kills on it, and pass
--     any test that only checked "a close was emitted".
--
--   * the filing instant is stamped when the payload is BUILT, not when the
--     acknowledgement returns -- that round trip retries for up to thirty
--     seconds, and kills inside that window would otherwise be classified as
--     "before the report" by one function and "after" by the other.
--
-- These load the REAL br_lib/shared/evidence_buf.lua, br_lib/shared/
-- incident_build.lua, br_core/server/evidence.lua and br_core/server/
-- incident.lua, IN MANIFEST ORDER, and drive them through the real events. The
-- only stubs are FiveM natives and the roster.

--- A world with the evidence buffer and the incident writer, wired as br_core
--- wires them.
---
--- SEPARATE FROM newIncidentWorld ABOVE, which deliberately loads the smallest
--- surface that holds up the announcement tests. This one needs the evidence
--- half as well, and loading it into that world would change what those cases
--- run against.
local function newTimelineWorld()
    local env = setmetatable({}, { __index = function(_, k) return SANDBOX_STD[k] end })
    env._G = env

    local S = {
        roster = {},
        licenses = {},
        now = 0,
        matches = {},
        incidents = {},   -- br:ringmaster:incident payloads
        closes = {},      -- br:ringmaster:incidentClose payloads
        corroborations = {},
        -- The SERVER's inventories, which server/strip.lua cross-checks a
        -- reported hash against. [src] = { slots = { { item = 'id' }, ... } }
        invs = {},
        -- BR.Grants.holds answers, by license. THREE-VALUED ON PURPOSE: true is
        -- an admin, false is an ordinary player whose row has been read, and nil
        -- is a row nobody has read yet -- which is the state every player is in
        -- for the first moments of a session and is a different answer from
        -- "they are not an admin".
        grants = {},
    }

    local h = {}
    env.AddEventHandler = function(name, fn)
        h[name] = h[name] or {}
        table.insert(h[name], fn)
    end
    env.TriggerEvent = function(name, ...)
        for _, fn in ipairs(h[name] or {}) do fn(...) end
    end
    env.TriggerClientEvent = function() end
    env.RegisterNetEvent = function() end
    env.RegisterCommand  = function() end
    -- CONTROLLABLE, because every assertion below is about WHEN something was
    -- recorded relative to something else.
    env.GetGameTimer = function() return S.now end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.print = function() end
    env.GetNumPlayerIdentifiers = function(src) return S.licenses[src] and 1 or 0 end
    env.GetPlayerIdentifier = function(src) return S.licenses[src] end

    for _, f in ipairs({
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/shared/identity.lua',
        'br_lib/shared/combat_solve.lua',
        -- THE REAL WEAPON TABLE, not a stub. weaponFacts() decides whether a kill
        -- gets painted red as an unissued weapon, and a stub would let that
        -- logic pass against a table shaped the way the test author imagined.
        -- geo.lua comes first only because weapons.lua calls BR.NormHash.
        'br_lib/shared/geo.lua',
        'br_lib/config/weapons.lua',
        -- THE REAL REFUSAL WORDS, for the same reason the weapon table is real.
        -- A vehicle corroboration now carries BR.Config.VehicleRefusal's own
        -- prose (see the `br:core:vehicle` handler), and a literal spelled in a
        -- test would still pass the day somebody re-words the config -- which is
        -- precisely the drift the cases below exist to catch. It loads AFTER
        -- geo.lua because it calls BR.NormHash at load time.
        'br_lib/config/vehicles.lua',
        'br_lib/shared/evidence_buf.lua',
        'br_lib/shared/incident_build.lua',
    }) do
        local chunk, err = loadfile(ROOT .. f, 't', env)
        if not chunk then
            realPrint('\27[31msandbox load error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end

    local BRs = env.BR

    BRs.Roster = {
        get = function(src) return S.roster[src] end,
        licenseOf = function(src) return S.licenses[src] end,
        each = function(pred, fn)
            local ids = {}
            for src in pairs(S.roster) do ids[#ids + 1] = src end
            table.sort(ids)
            for _, src in ipairs(ids) do
                local e = S.roster[src]
                if pred(e) then fn(src, e) end
            end
        end,
    }
    -- The match registry, which is where `startedAt` lives.
    BRs.Server = { matches = S.matches }
    -- EXTENDED, NOT REPLACED, AND THAT IS LOAD-BEARING. A bare assignment here
    -- threw away everything config/weapons.lua had just put on BR.Config --
    -- the real weapon tables weaponFacts() classifies kills against. Every kill
    -- in this world then produced no weapon claim at all, and the tests that
    -- assert "an environmental death makes NO claim" passed for entirely the
    -- wrong reason: nothing could make a claim, so nothing did. The tests that
    -- assert a claim IS made are what caught it.
    BRs.Config = BRs.Config or {}
    BRs.Config.Report = { maxPerMatch = 3, maxTargets = 5, categories = { 'cheating' } }
    BRs.Config.isReportCategory = function(c) return c == 'cheating' end
    BRs.Config.defaultReportCategory = function() return 'cheating' end
    BRs.Combat = { attributedKiller = function() return nil end }

    -- THE AUTHORITATIVE INVENTORY, which is what makes server/strip.lua's
    -- false-positive guard a SERVER decision rather than a client one. The real
    -- BR.Inv.of returns the roster entry's inventory; nothing else about
    -- server/inventory.lua is needed to answer "is this weapon theirs".
    BRs.Inv = { of = function(src) return S.invs[src] end }

    -- THE ADMIN GRANT. `holds` is genuinely three-valued in server/grants.lua
    -- and server/strip.lua's exemption turns on that, so a stub that collapsed
    -- it to a boolean would test a rule this project does not have.
    BRs.Grants = {
        CONSOLE = 'view',
        holds = function(license, scope)
            if scope ~= 'view' then return false end
            return S.grants[license]
        end,
    }

    -- IN MANIFEST ORDER. evidence.lua at br_core/fxmanifest.lua:114, incident.lua
    -- at :138, strip.lua below it -- the same order the server loads them, which
    -- is the order that decides whether the close reads a full buffer or an
    -- empty one.
    for _, f in ipairs({
        'br_core/server/evidence.lua',
        'br_core/server/incident.lua',
        'br_core/server/strip.lua',
    }) do
        local chunk, err = loadfile(ROOT .. f, 't', env)
        if not chunk then
            realPrint('\27[31msandbox load error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        chunk()
    end

    env.AddEventHandler('br:ringmaster:incident', function(p)
        S.incidents[#S.incidents + 1] = p
    end)
    env.AddEventHandler('br:ringmaster:incidentClose', function(p)
        S.closes[#S.closes + 1] = p
    end)
    env.AddEventHandler('br:ringmaster:corroborate', function(p)
        S.corroborations[#S.corroborations + 1] = p
    end)

    local W = { env = env, BR = BRs, S = S }

    function W.at(t) S.now = t end

    --- A match that has GONE LIVE. `createdAt` defaults to the start because
    --- almost every case here is about a match already running and the exact
    --- formation time is not what those are testing -- the warmup cases below
    --- use `W.formMatch` and set the two apart deliberately.
    function W.startMatch(matchId, startedAt, createdAt)
        S.matches[matchId] = {
            id = matchId,
            startedAt = startedAt,
            createdAt = createdAt or startedAt,
        }
    end

    --- A match that has been FORMED and is still on the warmup pad.
    ---
    --- `startedAt` IS ABSENT, WHICH IS THE WHOLE POINT. br_core/server/match.lua
    --- stamps it on entering PLAYING and nothing else does, so this is what the
    --- registry really holds for every second of warmup.
    function W.formMatch(matchId, createdAt)
        S.matches[matchId] = { id = matchId, createdAt = createdAt }
    end

    --- The warmup ends and the match goes live.
    function W.beginPlaying(matchId, startedAt)
        local m = S.matches[matchId]
        if m then m.startedAt = startedAt end
    end

    function W.join(src, matchId, license, name)
        S.roster[src] = {
            src = src, name = name or ('P' .. src), matchId = matchId, squadId = nil,
            -- ALIVE, because server/strip.lua will not count a report from a
            -- lobby ped or a corpse -- the hand it is about is not one this
            -- gamemode fills in either state.
            state = BRs.PlayerState.ALIVE,
        }
        S.licenses[src] = license
        -- READ, AND NOT AN ADMIN. The default for a joined player, because the
        -- grants cache is primed at playerJoining and a match starts minutes
        -- later. `W.unread` below is the other case.
        if license ~= nil then S.grants[license] = false end
    end

    --- Nobody has successfully read this license's grant row.
    function W.unread(license) S.grants[license] = nil end

    --- This license holds the console grant.
    function W.admin(license) S.grants[license] = true end

    --- What the SERVER believes is in this player's five slots.
    function W.carrying(src, items)
        local slots = {}
        for i, id in ipairs(items or {}) do slots[i] = { item = id } end
        S.invs[src] = { slots = slots }
    end

    --- One strip report, as client/inventory.lua sends it.
    ---
    --- `source` IS SET RATHER THAN PASSED, because that is how FiveM delivers it
    --- and because the whole point of reading it there is that a client cannot
    --- name somebody else. A helper that passed the src as an argument would be
    --- testing a function this project does not have.
    --- @param weapon any  a hash, or deliberate rubbish
    function W.strip(src, weapon)
        env.source = src
        env.TriggerEvent(BRs.Net.INV_STRIPPED, weapon)
        env.source = nil
    end

    --- One elimination, through the REAL BR.Evidence.noteKill, in the shape
    --- server/combat.lua hands it over.
    --- @param weapon any|nil  hash, id or WEAPON_* name; see weaponFacts()
    ---
    --- THE DEFAULT IS A HASH BECAUSE THE GUNSHOT PATH STORES A HASH. This
    --- fixture used to pass the string 'WEAPON_CARBINERIFLE', which is a form
    --- the gunshot path never produces -- damage.lua sets `lastHitWeapon` from
    --- `data.weaponType`, looked up as `WeaponByHash[NormHash(...)]`. Nothing
    --- consumed the field then, so the mismatch cost nothing; it does now, and
    --- a fixture that disagrees with the runtime is how a resolver ships
    --- passing its tests and calling every real kill a conjured weapon.
    function W.kill(killerSrc, victimSrc, weapon)
        -- AN EXPLICIT nil TEST, NOT `weapon ~= nil and weapon or DEFAULT`. That
        -- idiom returns the DEFAULT when weapon is `false`, because the `and`
        -- yields false and the `or` then takes its right branch -- so the one
        -- case the caller most wants to pass through is the one it swallows.
        if weapon == nil then weapon = 0x83BF0278 end  -- WEAPON_CARBINERIFLE
        BRs.Evidence.noteKill({
            killer    = killerSrc and S.roster[killerSrc] and S.roster[killerSrc].name or nil,
            killerSrc = killerSrc,
            victim    = S.roster[victimSrc] and S.roster[victimSrc].name or 'V',
            victimSrc = victimSrc,
            cause     = 'gunshot',
            weapon    = weapon,  -- nil is substituted by the caller guard above
            headshot  = nil,
        })
    end

    --- File a case the way the anticheat does, then acknowledge it.
    function W.file(matchId, license, name, incidentId)
        env.TriggerEvent('br:ringmaster:refusal', {
            matchId = matchId, license = license, name = name,
            count = 8, windowMs = 4000,
            reason  = BRs.ShotRefusal.NO_WEAPON,
            reasons = { [BRs.ShotRefusal.NO_WEAPON] = 8 },
            severity = 'high', seq = 1, at = S.now,
        })
        if incidentId then
            env.TriggerEvent('br:incident:filed', {
                incidentId = incidentId, matchId = matchId,
                subjectLicense = license,
            })
        end
    end

    --- One refused-vehicle announcement, in the shape server/vehicles.lua sends.
    ---
    --- FIRED AT THIS FILE'S HANDLER DIRECTLY rather than through the detector,
    --- which is deliberate and is the same split `W.file` makes for refusals:
    --- server/vehicles.lua decides WHEN to announce (the population guard, the
    --- 900ms throttle, the bar of two) and tools/test_shared.lua drives the real
    --- handler for all of that. What is under test here is what
    --- server/incident.lua does with the announcement once it arrives.
    ---
    --- `count` STARTS AT 2 BECAUSE THE DETECTOR'S FIRST ANNOUNCEMENT DOES. The
    --- first refused vehicle is counted and announced to nobody; `seq` is which
    --- announcement this is, so seq 1 opens the case and 2+ corroborate it.
    --- @param why string|nil  a BR.Config.VehicleRefusal value, or nil for none
    function W.vehicle(src, matchId, license, name, count, seq, why)
        env.TriggerEvent('br:core:vehicle', {
            src = src, name = name, license = license, matchId = matchId,
            count = count, seq = seq,
            why = why,
            at = S.now,
        })
    end

    --- The acknowledgement br_ringmaster sends once a row is durable.
    function W.ack(matchId, license, incidentId)
        env.TriggerEvent('br:incident:filed', {
            incidentId = incidentId, matchId = matchId, subjectLicense = license,
        })
    end

    --- The teardown br_core runs: `br:match:destroyed` is the only path out of
    --- the registry, and server/evidence.lua answers it.
    ---
    --- THE REGISTRY ENTRY IS CLEARED BEFORE THE EVENT IS FIRED, exactly as
    --- BR.Match.destroy does it, and that ordering is load-bearing rather than
    --- decorative. The close needs the match's `startedAt` and there is nothing
    --- left to read it off by then -- so it rides the event, and a close that
    --- went back to the registry for it would read nil for EVERY match and null
    --- out a start that was correct on the row. Mirroring the order here is what
    --- makes that a test failure instead of a production one.
    function W.endMatch(matchId)
        local m = S.matches[matchId]
        S.matches[matchId] = nil
        env.TriggerEvent('br:match:destroyed', {
            matchId = matchId,
            startedAt = m and m.startedAt or nil,
        })
    end

    function W.lastClose() return S.closes[#S.closes] end
    function W.lastIncident() return S.incidents[#S.incidents] end

    return W
end

--- Entries of one kind on a timeline.
local function ofKind(timeline, kind)
    local out = {}
    for _, e in ipairs(timeline or {}) do
        if e.kind == kind then out[#out + 1] = e end
    end
    return out
end

describe('timeline.filing')
do
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.join(2, 7, 'license:v1', 'Victim1')
    W.join(3, 7, 'license:v2', 'Victim2')

    W.at(2000); W.kill(1, 2)
    W.at(3000); W.kill(1, 3)

    W.at(4000)
    W.file(7, 'license:cheat', 'Cheater')

    local p = W.lastIncident()
    ok(p ~= nil, 'a refusal files a case')
    ok(p and p.matchStartedAt == 1000, 'the case records when the match started',
        p and tostring(p.matchStartedAt))

    -- THE ZERO POINT IS THE CASE'S OWN openedAt, and the console subtracts. The
    -- game stores absolute times so a corrected timestamp re-renders the whole
    -- timeline rather than leaving baked-in offsets behind.
    ok(p and p.atGameMs == 4000, 'and stamps the filing instant from the payload',
        p and tostring(p.atGameMs))

    local starts = ofKind(p and p.matchTimeline, 'match_start')
    ok(#starts == 1 and starts[1].at == 1000, 'match start is on the timeline')

    -- THE KILLS BEFORE THE REPORT, which is the half the buffer already had.
    local kills = ofKind(p and p.matchTimeline, 'kill')
    ok(#kills == 2, 'both kills before the report are on the timeline', #kills)
    ok(kills[1] and kills[1].at == 2000 and kills[2] and kills[2].at == 3000,
        'oldest first')

    -- THE PROFILE LINK. A display name is not what the console can look up.
    ok(kills[1] and kills[1].victimLicense == 'license:v1',
        'a kill names the victim by licence', kills[1] and tostring(kills[1].victimLicense))
    ok(kills[1] and kills[1].killerLicense == 'license:cheat',
        'and the killer by licence')

    -- NOT ENDED YET, and the row says so by carrying a deadline instead.
    ok(p and p.matchEndsByMs ~= nil, 'the case carries when the match should be over by')
    ok(p and p.matchEndedAt == nil, 'and does not claim the match has ended')
end

describe('timeline.close')
do
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.join(2, 7, 'license:v1', 'Victim1')
    W.join(3, 7, 'license:v2', 'Victim2')
    W.join(4, 7, 'license:v3', 'Victim3')

    W.at(2000); W.kill(1, 2)          -- before the report
    W.at(4000); W.file(7, 'license:cheat', 'Cheater', 'inc-1')
    W.at(6000); W.kill(1, 3)          -- AFTER the report
    W.at(7000); W.kill(1, 4)          -- and again

    W.at(9000)
    W.endMatch(7)

    local c = W.lastClose()
    ok(c ~= nil, 'the match ending closes the case it produced')
    ok(c and c.incidentId == 'inc-1', 'against the id the write came back with')
    ok(c and c.matchEndedAt == 9000, 'and records when the match ended',
        c and tostring(c.matchEndedAt))

    local ends = ofKind(c and c.matchTimeline, 'match_end')
    ok(#ends == 1 and ends[1].at == 9000, 'match end is an entry on the timeline')

    -- THE HALF THAT ONLY EXISTS BECAUSE THE BUFFER OUTLIVED THE MATCH BY ONE
    -- EVENT. If server/evidence.lua discarded before announcing, this is 0 --
    -- and the whole feature would be silently dead.
    local kills = ofKind(c and c.matchTimeline, 'kill')
    ok(#kills == 2, 'the kills AFTER the report are on the close', #kills)
    ok(kills[1] and kills[1].at == 6000 and kills[2] and kills[2].at == 7000,
        'and they are the ones that happened after it',
        kills[1] and tostring(kills[1].at))

    -- AND NOT THE ONES ALREADY ON THE ROW. A timeline that lists an elimination
    -- twice is a claim about a person that is false.
    local dup = false
    for _, k in ipairs(kills) do if k.at == 2000 then dup = true end end
    ok(not dup, 'the kill from before the report is not sent twice')

    ok(c and c.matchTimelineComplete == true,
        'and nothing was dropped, so it says so')
end

describe('timeline.ordering')
do
    -- THE HAZARD, ASSERTED DIRECTLY. server/evidence.lua must announce the
    -- closing BEFORE it discards the buffer. This drives the real
    -- `br:match:destroyed` and reads what the buffer held at the moment the
    -- close was built -- so moving `clearMatch` above the emit fails here.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.join(2, 7, 'license:v1', 'Victim1')

    W.at(4000); W.file(7, 'license:cheat', 'Cheater', 'inc-1')
    W.at(6000); W.kill(1, 2)

    -- The buffer has the kill right up until the match is torn down.
    ok(#W.BR.Evidence.forLicense('license:cheat') > 0,
        'the buffer holds the subject while the match runs')

    W.at(9000)
    W.endMatch(7)

    local c = W.lastClose()
    ok(c ~= nil, 'a close is emitted')
    ok(c and #ofKind(c.matchTimeline, 'kill') == 1,
        'and it was built while the evidence still existed',
        c and #ofKind(c.matchTimeline, 'kill'))

    -- AND THE DISCARD STILL HAPPENS. The announcement must not have replaced
    -- the teardown -- a buffer that is never freed is the leak the caps exist
    -- to prevent.
    ok(#W.BR.Evidence.forLicense('license:cheat') == 0,
        'and the buffer is discarded afterwards anyway')
end

describe('timeline.never-ends')
do
    -- A CRASH, A RESTART, A LOST WRITE. The match end is the one part of this
    -- that happens later, so it is the one part that can fail to happen at all.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000)
    W.file(7, 'license:cheat', 'Cheater', 'inc-1')

    local p = W.lastIncident()

    -- NO CLOSE, EVER. Nothing tears the match down.
    ok(W.lastClose() == nil, 'a match that never ends closes nothing')

    -- SO THE ROW MUST CARRY THE ANSWER ITSELF, written at filing time, when the
    -- game was still alive to write it. Absent `matchEndedAt` plus a deadline in
    -- the past is "the end was never reported"; absent plus a deadline in the
    -- future is "still in progress". Without the deadline both are just absent,
    -- and an admin cannot tell a live match from a dead server.
    ok(p and p.matchEndedAt == nil, 'the case has no end timestamp')
    ok(p and p.matchEndsByMs == W.BR.IncidentBuild.TIMELINE_LIMITS.MATCH_ENDS_BY_MS,
        'but it does carry a deadline, so absent never means "running forever"')
    ok(p and p.matchEndsByMs > 0, 'and the deadline is a real duration')
end

describe('timeline.weapon')
do
    -- WHAT THIS IS PROTECTING. The console renders `weaponIssued == false` in
    -- red and says it is high confidence of cheating. That is an accusation
    -- against a named player, made automatically, so every branch that can
    -- reach it is pinned here -- including the ones that must NOT reach it.

    local function killWith(weapon)
        local W = newTimelineWorld()
        W.startMatch(7, 1000)
        W.join(1, 7, 'license:cheat', 'Cheater')
        W.join(2, 7, 'license:v1', 'Victim1')
        W.at(2000); W.kill(1, 2, weapon)
        W.at(3000); W.file(7, 'license:cheat', 'Cheater')
        local p = W.lastIncident()
        return ofKind(p and p.matchTimeline, 'kill')[1]
    end

    -- THE THREE IDENTIFIER FORMS, all of which reach lastHitWeapon in real
    -- play and all of which name the same rifle.
    local byHash = killWith(0x83BF0278)
    ok(byHash and byHash.weaponIssued == true,
        'a weapon known by hash is issued', byHash and tostring(byHash.weaponIssued))
    ok(byHash and byHash.weaponLabel == 'Carbine Rifle',
        'and carries its display label, not its id', byHash and tostring(byHash.weaponLabel))

    local byId = killWith('carbinerifle')
    ok(byId and byId.weaponIssued == true and byId.weaponLabel == 'Carbine Rifle',
        'the same weapon by id resolves identically', byId and tostring(byId.weaponLabel))

    local byName = killWith('WEAPON_CARBINERIFLE')
    ok(byName and byName.weaponIssued == true and byName.weaponLabel == 'Carbine Rifle',
        'and by WEAPON_* name', byName and tostring(byName.weaponLabel))

    -- THE FINDING ITSELF.
    local conjured = killWith('not_a_weapon_we_have')
    ok(conjured and conjured.weaponIssued == false,
        'a weapon the gamemode does not issue is flagged',
        conjured and tostring(conjured.weaponIssued))
    ok(conjured and conjured.weaponLabel == nil,
        'and gets no label, because we have no name for what we do not hand out')

    -- STRICTLY FALSE, NOT FALSY. The console keys red off `=== false`, and a
    -- nil arriving where false was meant would silently stop flagging.
    ok(conjured and type(conjured.weaponIssued) == 'boolean',
        'the flag is a real boolean', conjured and type(conjured.weaponIssued))

    -- THE FALSE-ACCUSATION GUARDS. Each of these must make NO claim at all.
    local fell = killWith('fall')
    ok(fell and fell.weaponIssued == nil,
        'an environmental death makes no weapon claim', fell and tostring(fell.weaponIssued))

    local fellByName = killWith('WEAPON_FALL')
    ok(fellByName and fellByName.weaponIssued == nil,
        'and the same by WEAPON_* name', fellByName and tostring(fellByName.weaponIssued))

    local none = killWith({})  -- a type weaponFacts has no branch for
    ok(none and none.weaponIssued == nil,
        'an unexpected type makes no claim rather than a false one',
        none and tostring(none.weaponIssued))

    -- BACKWARDS COMPATIBILITY, stated as a test because it is a promise to
    -- every case already in DynamoDB: they carry no weaponIssued, and the
    -- console must not paint them red. Absence is the same shape as the
    -- environmental answer above -- the key simply is not there.
    ok(fell and rawget(fell, 'weaponIssued') == nil,
        'absence is absence, not a stored nil')
end

describe('timeline.no-match')
do
    -- `brrefuse` from a console, or an anticheat trip in the lobby. Inventing a
    -- timeline for these would put a match on the record that never happened.
    local W = newTimelineWorld()
    W.join(1, nil, 'license:cheat', 'Cheater')

    W.at(4000)
    W.file(nil, 'license:cheat', 'Cheater', 'inc-1')

    local p = W.lastIncident()
    ok(p ~= nil, 'a case filed outside a match is still filed')
    ok(p and p.matchStartedAt == nil, 'with no match start')
    ok(p and p.matchEndsByMs == nil, 'and no deadline to expire')
    ok(p and p.matchCreatedAt == nil, 'and no formation time either')
    ok(p and #(p.matchTimeline or {}) == 0, 'and an empty timeline')
end

-- ======================================================================== --
-- A CASE FILED DURING WARMUP
-- ======================================================================== --
--
-- WHY THIS IS THE CASE THAT MATTERED MOST AND WAS RECORDED LEAST. vMenu is a
-- development tool that is not going to production, so there is no benign route
-- to a weapon this gamemode never issued -- every strip is a cheat signal, and
-- one on the warmup pad is the EARLIEST signal available: it happens before the
-- offender has touched a real player.
--
-- WHAT IT USED TO PRODUCE. `startedAt` is stamped on entering PLAYING, so
-- `timelineOpen` answered with the empty shape and `attachTimeline` -- which
-- keyed its close registration on that same start -- never queued the case at
-- all. The row was written with no start, no deadline, an empty timeline, and
-- then never received a match-end write, ever. The console reads that shape as
-- "filed outside a match", which is false about a row carrying a matchId.
--
-- These drive the REAL server/strip.lua, server/evidence.lua and
-- server/incident.lua through the real events, because the two halves of the
-- bug were in different files and either fix alone still loses the case.

describe('timeline.warmup-filing')
do
    local W = newTimelineWorld()
    -- FORMED, NOT STARTED. The registry entry a warmup match really has.
    W.formMatch(7, 500)
    W.join(1, 7, 'license:cheat', 'Cheater')

    -- A weapon this gamemode has never heard of -- nothing in
    -- br_lib/config/weapons carries this hash. The same value the strip cases
    -- further down the file use, for the same reason.
    local CONJURED = 0x11111111

    -- TWO STRIPS: the first is recorded and announced to nobody, the second
    -- opens the case. Both on the pad.
    W.at(1000); W.strip(1, CONJURED)
    W.at(2000); W.strip(1, CONJURED)

    local p = W.lastIncident()
    ok(p ~= nil, 'a strip during warmup files a case')
    ok(p and p.matchId == 7, 'about the match it happened in', p and tostring(p.matchId))

    -- THE TRUTHFUL FIELD STAYS TRUTHFUL.
    ok(p and p.matchStartedAt == nil,
        'the case does not claim the match had started',
        p and tostring(p.matchStartedAt))
    ok(p and p.matchCreatedAt == 500,
        'it records when the match was FORMED instead',
        p and tostring(p.matchCreatedAt))

    -- AND NO DEADLINE, because a deadline means "this long after the match
    -- STARTED" and measuring it from the formation would fire early on any long
    -- warmup -- `brwarmup hold` holds one for a day -- telling an admin the end
    -- was never reported about a match still sitting on the pad.
    ok(p and p.matchEndsByMs == nil,
        'and no deadline derived from a start it does not have',
        p and tostring(p.matchEndsByMs))

    -- AND THE TIMELINE HAS A BEGINNING, under a kind that says which beginning.
    local formed = ofKind(p and p.matchTimeline, W.BR.IncidentBuild.MATCH_CREATED_KIND)
    ok(#formed == 1 and formed[1].at == 500,
        'the timeline is anchored on the formation', #formed)
    ok(#ofKind(p and p.matchTimeline, 'match_start') == 0,
        'and carries no match_start, because the match had not started')

    -- THE EVIDENCE ITSELF, which the empty shape used to throw away entirely --
    -- an evidence record carries chat and kills, and a strip is neither, so
    -- `matchTimeline` was the only place either strip could have been recorded.
    local strips = ofKind(p and p.matchTimeline, W.BR.IncidentBuild.STRIP_KIND)
    ok(#strips == 2, 'both strips are on it, including the quiet first one', #strips)
end

describe('timeline.warmup-close')
do
    -- THE SECOND HALF: the case must receive the match-end write like any other,
    -- and the start and deadline that did not exist at filing must arrive on it.
    local W = newTimelineWorld()
    W.formMatch(7, 500)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.join(2, 7, 'license:v1', 'Victim1')

    local CONJURED = 0x11111111
    W.at(1000); W.strip(1, CONJURED)
    W.at(2000); W.strip(1, CONJURED)
    W.ack(7, 'license:cheat', 'inc-1')

    -- THE MATCH THEN ACTUALLY STARTS, which is what makes the start knowable.
    W.at(3000); W.beginPlaying(7, 3000)
    W.at(5000); W.kill(1, 2)

    W.at(9000); W.endMatch(7)

    local c = W.lastClose()
    ok(c ~= nil, 'a case filed during warmup is closed at match end')
    ok(c and c.incidentId == 'inc-1', 'against the id it was filed under')
    ok(c and c.matchEndedAt == 9000, 'and records when the match ended',
        c and tostring(c.matchEndedAt))

    -- THE REPAIR. Neither of these was on the row at filing time.
    ok(c and c.matchStartedAt == 3000,
        'the close carries the start the filing could not know',
        c and tostring(c.matchStartedAt))
    ok(c and c.matchEndsByMs == W.BR.IncidentBuild.TIMELINE_LIMITS.MATCH_ENDS_BY_MS,
        'and the deadline that goes with it',
        c and tostring(c.matchEndsByMs))

    -- AND THE REST OF THE MATCH IS ON IT TOO.
    ok(#ofKind(c and c.matchTimeline, 'kill') == 1,
        'with the kill that happened after the case was filed',
        c and #ofKind(c.matchTimeline, 'kill'))
end

describe('timeline.warmup-dissolved')
do
    -- A MATCH NOBODY STAYED FOR. It is destroyed off the pad without ever
    -- entering PLAYING, so there is no start and there never will be -- and the
    -- close must say nothing about one rather than write the end time into it or
    -- null out the row's own answer.
    local W = newTimelineWorld()
    W.formMatch(7, 500)
    W.join(1, 7, 'license:cheat', 'Cheater')

    local CONJURED = 0x11111111
    W.at(1000); W.strip(1, CONJURED)
    W.at(2000); W.strip(1, CONJURED)
    W.ack(7, 'license:cheat', 'inc-1')

    W.at(4000); W.endMatch(7)

    local c = W.lastClose()
    ok(c ~= nil, 'a match that dissolves on the pad still closes its case')
    ok(c and c.matchEndedAt == 4000, 'and says when it was torn down')
    ok(c and c.matchStartedAt == nil,
        'without claiming a start it never had', c and tostring(c.matchStartedAt))
    ok(c and c.matchEndsByMs == nil,
        'and without a deadline measured from one', c and tostring(c.matchEndsByMs))
end

describe('timeline.close-reads-the-event-not-the-registry')
do
    -- ═══ THE ORDERING HAZARD, ASSERTED DIRECTLY ═══
    --
    -- BR.Match.destroy clears `BR.Server.matches[id]` and THEN announces the
    -- destruction, so by the time any handler runs there is no instance left to
    -- read `startedAt` off. A close that looked it up there would find nil for
    -- EVERY match -- including one that ran for twenty minutes -- and would then
    -- write a null over a start that was correct on the row.
    --
    -- This is an ordinary mid-match case, so the registry lookup and the event
    -- field disagree in the one direction that matters: nil versus 1000.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.file(7, 'license:cheat', 'Cheater', 'inc-1')
    W.at(9000); W.endMatch(7)

    ok(W.S.matches[7] == nil,
        'the registry entry is gone by the time the close is built')

    local c = W.lastClose()
    ok(c and c.matchStartedAt == 1000,
        'and the close still knows when the match started, from the event',
        c and tostring(c.matchStartedAt))
end

describe('timeline.corroboration')
do
    -- CORROBORATIONS ARE NOT ON THIS TIMELINE AND MUST NOT BE. They land in the
    -- console's own `events` list, appended by Ringmaster's `corroborate()`,
    -- because appending to a case that exists is an UpdateItem the game
    -- deliberately does not hold on that attribute. The game emits the fact; the
    -- console records it. This asserts the split rather than assuming it.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.file(7, 'license:cheat', 'Cheater', 'inc-1')

    -- The second refusal doubling corroborates rather than filing again.
    W.at(6000)
    W.env.TriggerEvent('br:ringmaster:refusal', {
        matchId = 7, license = 'license:cheat', name = 'Cheater',
        count = 16, windowMs = 4000,
        reason  = W.BR.ShotRefusal.NO_WEAPON,
        reasons = { [W.BR.ShotRefusal.NO_WEAPON] = 16 },
        severity = 'high', seq = 2, at = 6000,
    })

    ok(#W.S.incidents == 1, 'a second refusal does not file a second case',
        #W.S.incidents)
    ok(#W.S.corroborations == 1, 'it corroborates the first', #W.S.corroborations)
    ok(W.S.corroborations[1].incidentId == 'inc-1',
        'against the case that already exists')

    W.at(9000)
    W.endMatch(7)

    local c = W.lastClose()
    ok(c ~= nil, 'and the match still closes that one case')
    ok(#ofKind(c and c.matchTimeline, 'match_end') == 1, 'with a match end on it')
    -- The corroboration is the console's to place on the timeline; the game
    -- never writes one into `matchTimeline`.
    ok(#ofKind(c and c.matchTimeline, 'note') == 0,
        'and the game writes no corroboration entry of its own')
end

describe('timeline.volume')
do
    -- A PROLIFIC OFFENDER IN A LONG MATCH. The buffer's default cap is 30 kills
    -- per player session, which is right for an evidence snippet and wrong for
    -- "every kill by the offender" -- so filing PROMOTES the subject's records.
    -- The cost is paid per incident, not per player: a match with no incident
    -- promotes nobody.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.join(2, 7, 'license:v1', 'Victim1')

    local DEFAULT_KILL_MAX = W.BR.EvidenceBuf.DEFAULTS.killMax
    ok(DEFAULT_KILL_MAX == 30, 'the default cap is what this case assumes',
        DEFAULT_KILL_MAX)

    -- File EARLY, which is the real shape: the anticheat fires on a doubling and
    -- a report comes in mid-match.
    W.at(2000)
    W.file(7, 'license:cheat', 'Cheater', 'inc-1')

    -- Now far more kills than the DEFAULT cap would have held.
    for i = 1, 100 do
        W.at(3000 + i)
        W.kill(1, 2)
    end

    W.at(200000)
    W.endMatch(7)

    local c = W.lastClose()
    local kills = ofKind(c and c.matchTimeline, 'kill')

    -- THE POINT: without the promotion this is 30, and the timeline would
    -- silently be "the last thirty kills" while claiming to be every kill.
    ok(#kills == 100, 'every kill after the report survives the default cap', #kills)
    ok(c and c.matchTimelineComplete == true,
        'and the timeline reports itself complete')

    -- AND IT IS STILL BOUNDED. A DynamoDB item is 400KB.
    ok(#kills <= W.BR.IncidentBuild.TIMELINE_LIMITS.MAX_TIMELINE_KILLS,
        'while staying under the hard cap')
end

describe('timeline.volume.truncated')
do
    -- BEYOND EVEN THE PROMOTED CAP, the timeline truncates -- and says so. A
    -- kill list that stops early and reports itself complete tells an admin
    -- "this is everything they did" when it is not.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.join(2, 7, 'license:v1', 'Victim1')

    W.at(2000)
    W.file(7, 'license:cheat', 'Cheater', 'inc-1')

    local PROMOTED = W.BR.EvidenceBuf.PROMOTED.killMax
    for i = 1, PROMOTED + 50 do
        W.at(3000 + i)
        W.kill(1, 2)
    end

    W.at(500000)
    W.endMatch(7)

    local c = W.lastClose()
    local kills = ofKind(c and c.matchTimeline, 'kill')

    ok(#kills <= PROMOTED, 'a runaway kill count is bounded', #kills)
    ok(c and c.matchTimelineComplete == false,
        'and a truncated timeline never claims to be complete')
    ok(c and c.matchKillsSeen >= PROMOTED + 50,
        'and it reports how many kills there really were',
        c and tostring(c.matchKillsSeen))
end

describe('timeline.no-incident')
do
    -- THE COST RULE. A match nobody was reported in must produce NOTHING: no
    -- close, no write, no DynamoDB traffic at all. This is the case that makes
    -- the whole design affordable, and it is the one that would silently regress
    -- if the close were ever hung off the match rather than off the incident.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:clean', 'Clean')
    W.join(2, 7, 'license:v1', 'Victim1')

    W.at(2000); W.kill(1, 2)
    W.at(3000); W.kill(1, 2)

    W.at(9000)
    W.endMatch(7)

    ok(#W.S.incidents == 0, 'a quiet match files nothing', #W.S.incidents)
    ok(#W.S.closes == 0, 'and closes nothing -- zero writes', #W.S.closes)
end

describe('timeline.filing-window')
do
    -- THE ACKNOWLEDGEMENT ARRIVES LATE. br_ringmaster retries a failed write for
    -- up to thirty seconds, so `br:incident:filed` can come back long after the
    -- payload was built. A kill inside that window belongs AFTER the report --
    -- and would be lost entirely if the filing instant were read from the
    -- acknowledgement instead of from the payload.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.join(2, 7, 'license:v1', 'Victim1')

    W.at(4000)
    W.file(7, 'license:cheat', 'Cheater')   -- filed, NOT yet acknowledged

    W.at(6000); W.kill(1, 2)                -- during the write's retry window

    W.at(30000)
    W.env.TriggerEvent('br:incident:filed', {
        incidentId = 'inc-1', matchId = 7, subjectLicense = 'license:cheat',
    })

    W.at(40000)
    W.endMatch(7)

    local c = W.lastClose()
    local kills = ofKind(c and c.matchTimeline, 'kill')
    ok(#kills == 1, 'a kill during the write window is still on the timeline', #kills)
    ok(kills[1] and kills[1].at == 6000, 'at the moment it actually happened',
        kills[1] and tostring(kills[1].at))
end

-- ======================================================================== --
-- AN UNISSUED WEAPON IN THE HAND
-- ======================================================================== --
--
-- client/inventory.lua has always taken a weapon the inventory did not issue
-- out of the ped's hand, and it did it in silence: a player granting themselves
-- a rifle in a menu left no trace anywhere at all. These cases are about what
-- that silence was replaced with.
--
-- THE OWNER'S INSTRUCTION IS ONE SENTENCE AND TWO OF THESE CASES ARE IT:
-- "that triggers an incident. Remember a cheater is likely to do this several
-- times recursively, so we need to log that in the incident timeline rather
-- than creating a new incident each time."
--
-- The rest are about the ways it could be WRONG, which is where the cost is:
-- an anticheat that files a case about an innocent player is worse than one
-- that files nothing, and two of the four paths below exist only to stop that.

-- A weapon this gamemode has never heard of. Nothing in br_lib/config/weapons
-- carries this hash, which is the whole point of it.
local CONJURED = 0x11111111
-- ...and one it issues, by the hash the engine reports for it.
local CARBINE = 0x83BF0278

describe('strip.the-second-opens-a-case')
do
    -- THE OWNER'S BAR, 2026-08-20: "'4 or 5 more times' is too many. This should
    -- fire an incident on the 2nd offense, and each subsequent should show as
    -- corroboration from system."
    --
    -- ONE IS RECORDED AND ANNOUNCED TO NOBODY. A single weapon in a hand for a
    -- single tick is the shape our own two inventory mirrors disagreeing has,
    -- and `ourWeapon` cannot catch every ordering of that. A second one a
    -- second later is not that shape.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000)
    W.strip(1, CONJURED)
    ok(#W.S.incidents == 0, 'the FIRST strip opens no case', #W.S.incidents)
    ok(#W.S.corroborations == 0, 'and corroborates nothing either',
        #W.S.corroborations)

    W.at(5000)
    W.strip(1, CONJURED)

    local p = W.lastIncident()
    ok(p ~= nil, 'the SECOND strip opens the case')
    ok(#W.S.incidents == 1, 'exactly one of them', #W.S.incidents)
    ok(p and p.kind == 'anticheat', 'as an anticheat case, not a new record type',
        p and tostring(p.kind))
    ok(p and p.subjectLicense == 'license:cheat', 'about the player it happened to')
    ok(p and p.reporterLicense == nil,
        'with no reporter, so the console reads it as system-filed')

    -- SEVERITY IS READ FROM THE TAXONOMY, not restated. NO_WEAPON is graded
    -- `high` in combat_solve.lua and this must agree with it by construction.
    ok(p and p.severity == W.BR.ShotTier[W.BR.ShotRefusal.NO_WEAPON],
        'graded by the same table that grades a conjured-weapon refusal',
        p and tostring(p.severity))

    -- AND IT DOES NOT CLAIM SHOTS WERE REFUSED. Nothing was fired.
    ok(p and p.refusal == nil, 'and carries no refusal block, because none happened')
    ok(p and type(p.summary) == 'string' and p.summary:find('unissued') ~= nil,
        'the queue line says what actually happened', p and tostring(p.summary))

    -- BOTH EVENTS ARE ON THE TIMELINE, at the moments the server stamped them.
    -- The strip that stayed quiet was written into the evidence buffer anyway --
    -- that write happens before the announcement gate -- so the case is created
    -- knowing about the offence that did not open it. Losing it would be the
    -- worst of both rules: a bar of two that shows an admin one.
    local strips = ofKind(p and p.matchTimeline, 'weapon_strip')
    ok(#strips == 2, 'BOTH strips are on the timeline the case is created with',
        #strips)
    ok(strips[1] and strips[1].at == 4000,
        'including the silent first one, stamped by the SERVER clock',
        strips[1] and tostring(strips[1].at))
    ok(strips[2] and strips[2].at == 5000, 'and the one that filed it, second',
        strips[2] and tostring(strips[2].at))
    ok(strips[1] and strips[1].weapon == CONJURED,
        'and carries the hash, which is the only name a conjured weapon has',
        strips[1] and tostring(strips[1].weapon))

    -- THE QUEUE LINE COUNTS BOTH, because the summary is built from `count` and
    -- `count` is offences rather than announcements.
    ok(p and type(p.summary) == 'string' and p.summary:find('2 unissued') ~= nil,
        'and the queue line says two, not one', p and tostring(p.summary))
end

describe('strip.repeats-append')
do
    -- THE OWNER'S SENTENCE, ASSERTED. Several strips in one match are ONE case
    -- with several timeline entries -- not one case each, which would let a
    -- persistent cheater bury the queue the case is meant to be read from.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)   -- recorded, announced to nobody
    W.at(5000); W.strip(1, CONJURED)   -- opens the case
    W.ack(7, 'license:cheat', 'inc-1')

    -- Recursively, exactly as described. Spaced past the server's own throttle
    -- so every one of them counts.
    for i = 1, 5 do
        W.at(5000 + i * 1000)
        W.strip(1, CONJURED)
    end

    ok(#W.S.incidents == 1, 'five more strips file no second case', #W.S.incidents)

    -- ═══ ONE ROW, NOT FIVE (the owner, 2026-08-22) ═══
    --
    -- This case used to assert five, one per offence, and the owner read the
    -- result: "it seems to be filing a corroboration every few seconds", with a
    -- screenshot of nine notes in nine seconds differing only in a counter. Five
    -- identical rows are the same bug in miniature.
    --
    -- WHAT DID NOT CHANGE IS THAT ALL FIVE OFFENCES STILL REACH THE CASE. The
    -- assertions below are what makes that a claim rather than a hope: the note
    -- that goes out carries a CUMULATIVE count, and the four that folded into it
    -- are on the timeline the close appends, individually and with their own
    -- timestamps. The rows went; the evidence did not.
    ok(#W.S.corroborations == 1,
        'and they say so ONCE rather than once each -- one row, not five',
        #W.S.corroborations)

    -- THE FIRST ONE IS NEVER HELD. It is what tells an admin reading the queue
    -- that the case is live rather than historical.
    local first = W.S.corroborations[1]
    ok(first and first.seq == 2 and first.count == 3,
        'the first repeat goes out at once, at announcement 2 and offence 3',
        first and (tostring(first.seq) .. '/' .. tostring(first.count)))

    -- ═══ AND THE COUNT IS NOT LOST WITH THE ROWS ═══
    --
    -- The four that folded were superseded, not discarded: `count` is a running
    -- total, so the note released at teardown says everything they would have.
    -- A throttle without this line would close this case reading `3` when seven
    -- offences had happened, which is a false statement about a person.
    W.at(20000)
    W.endMatch(7)

    ok(#W.S.corroborations == 2,
        'the match ending releases the one that was still waiting',
        #W.S.corroborations)
    local last = W.S.corroborations[2]
    ok(last and last.count == 7,
        'and it carries the TRUE final count, not the one the first row had',
        last and tostring(last.count))
    ok(last and last.seq == 6,
        'with the announcement number that produced it', last and tostring(last.seq))

    local allSame = true
    for _, c in ipairs(W.S.corroborations) do
        if c.incidentId ~= 'inc-1' then allSame = false end
    end
    ok(allSame, 'every one against the case the write came back with')

    -- ATTRIBUTION IS THE EXISTING ONE AND NOT A SECOND SPELLING. The game sends
    -- a fact with no actor on it; br_ringmaster forwards a fixed field set; and
    -- the console's `incidents.corroborate()` writes the note as
    -- `byLicense: null, byName: 'System'` -- the same pair it uses for an
    -- automatic resolution. So "corroboration from system" is what this channel
    -- already produces, and a reporter field invented here would be a second
    -- answer to a question already answered.
    local noActor = true
    for _, c in ipairs(W.S.corroborations) do
        if c.reporterLicense ~= nil or c.reporterName ~= nil then noActor = false end
    end
    ok(noActor, 'and none of them names a player as the source')

    -- ...AND EVERY ONE OF THEM REACHES THE TIMELINE, which is the half the
    -- corroboration channel cannot do: corroborations land in the console's own
    -- `events` list, and the owner asked for the incident's timeline.
    --
    -- IT IS ALSO WHAT MAKES THE THROTTLE ABOVE SAFE, and this is the assertion
    -- that says so rather than the comment. The thing a folded note genuinely
    -- drops is WHEN each offence happened -- and here are all five of those,
    -- individually, with their own timestamps, on the record the admin opens.
    -- Were this list ever to stop being complete, the throttle would start
    -- costing something and this case would fail first.
    local c = W.lastClose()
    ok(c ~= nil, 'the match ending closes that one case')
    ok(c and c.incidentId == 'inc-1', 'the same one, not a new row')

    local strips = ofKind(c and c.matchTimeline, 'weapon_strip')
    ok(#strips == 5, 'every strip after the filing is on the close', #strips)
    ok(strips[1] and strips[1].at == 6000, 'oldest first',
        strips[1] and tostring(strips[1].at))

    -- AND THE FIRST TWO ARE NOT SENT TWICE. They rode the PutItem; a timeline
    -- that lists the same event twice is a claim about a person that is false.
    local dup = false
    for _, s in ipairs(strips) do
        if s.at == 4000 or s.at == 5000 then dup = true end
    end
    ok(not dup, 'the strips already on the row are not repeated')

    ok(c and c.matchTimelineComplete == true,
        'and nothing was dropped, so the record says so')
end

describe('strip.the-doubling-rule-is-gone')
do
    -- ═══ THE CADENCE THE OWNER REPLACED, PINNED SO IT DOES NOT COME BACK ═══
    --
    -- This case used to assert the opposite number and was described as
    -- "sixteen strips produce four corroborations, not fifteen". The rule it
    -- pinned was server/damage.lua's -- announce at the bar, then at every
    -- doubling (1, 2, 4, 8, 16) -- copied to bound a 512-deep drop-oldest outbox
    -- an offender chooses the fill rate of.
    --
    -- THE OWNER OVERRULED IT ON 2026-08-20: "'4 or 5 more times' is too many."
    -- Four announcements for sixteen offences is not a moderation record. The
    -- bound that remains is MIN_INTERVAL_MS -- one countable strip per 900ms per
    -- player -- and the artifact planner's per-case frame cap, and the fact that
    -- no volume of strips adds a DynamoDB write to the two a case always cost.
    --
    -- THE HALF THAT DID NOT CHANGE is that the timeline still gets every one of
    -- them, which was always the distinction this case existed to draw.
    --
    -- ═══ AND THE LAYER THIS CASE IS ABOUT IS THE DETECTOR, NOT THE RECORD ═══
    --
    -- 2026-08-22 put a throttle on the CORROBORATION, in server/incident.lua, so
    -- fourteen announcements no longer make fourteen rows. That is a different
    -- layer and it did not restore the doubling rule -- so this case now asserts
    -- both halves apart, because a reader who saw only the row count would
    -- reasonably conclude the thing this case exists to prevent had happened.
    --
    -- WHAT SEPARATES THE THROTTLE FROM THE RULE IT MUST NOT BECOME. Under the
    -- doubling rule a cheater who stopped at fifteen left a record saying EIGHT:
    -- the next announcement was the one that would have corrected it and it
    -- never came. The throttle cannot do that -- the tail is released at
    -- teardown -- so the final number is always the true one, however few rows
    -- carried it. That property is asserted at the bottom.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    -- EVERY ANNOUNCEMENT THE DETECTOR MAKES, counted at the door it makes them
    -- through. This is the owner's 2026-08-20 rule and it is untouched;
    -- registering the listener before the strips is what makes it observable.
    local announced = 0
    W.env.AddEventHandler('br:core:stripped', function() announced = announced + 1 end)

    W.at(4000); W.strip(1, CONJURED)   -- 1: recorded, silent
    W.at(5000); W.strip(1, CONJURED)   -- 2: opens the case
    W.ack(7, 'license:cheat', 'inc-1')

    for i = 1, 14 do
        W.at(5000 + i * 1000)
        W.strip(1, CONJURED)
    end

    ok(#W.S.incidents == 1, 'sixteen strips are still ONE case', #W.S.incidents)

    -- THE ASSERTION THIS CASE HAS ALWAYS BEEN FOR, now read off the detector.
    -- Fifteen: one per offence from the second, which is "each subsequent should
    -- show as corroboration from system" exactly as the owner wrote it. Four
    -- would mean the doubling rule was back.
    ok(announced == 15,
        'the detector still announces every offence from the second -- fifteen, not four',
        announced)

    -- AND THE RECORD DOES NOT PRINT ONE ROW PER ANNOUNCEMENT. Fourteen rows a
    -- second apart is what the owner photographed on 2026-08-22.
    ok(#W.S.corroborations == 1,
        'while the record carries one row rather than fourteen',
        #W.S.corroborations)

    W.at(30000)
    W.endMatch(7)

    -- ═══ THE PROPERTY THE DOUBLING RULE DID NOT HAVE ═══
    local last = W.S.corroborations[#W.S.corroborations]
    ok(last and last.count == 16,
        'and the last thing it says is 16 -- the true total, not a stale doubling',
        last and tostring(last.count))

    local strips = ofKind(W.lastClose() and W.lastClose().matchTimeline, 'weapon_strip')
    ok(#strips == 14, 'while all fourteen later strips are on the timeline', #strips)
end

-- ======================================================================== --
-- How often one case is allowed to repeat itself  (the owner, 2026-08-22)
-- ======================================================================== --
--
-- WHAT THESE COVER THAT NOTHING ELSE DOES. server/incident.lua's corroboration
-- path had no rate limit of any kind, and no case anywhere asserted that it
-- should -- the two strip cases above actively asserted the opposite, one row
-- per offence, which is what the owner photographed. The throttle that replaced
-- it is the sort of code that reads correct while being wrong in one direction
-- only: too eager and the record is unreadable again, too keen and the final
-- count never arrives. Both directions are asserted below.
--
-- MUTATION TESTED. Fifteen mutants applied to the real file, thirteen caught,
-- two survived. The counts are what was observed rather than what was hoped for:
--
--   the throttle removed entirely                     16 cases
--   the record is never looked up (same effect)       16 cases
--   the strip handler goes round the throttle         13 cases
--   the window becomes zero                           16 cases
--   the teardown stops flushing the held note          5 cases
--   the oldest waiting note is kept, not the newest    4 cases
--   `reason` is no longer compared                     8 cases
--   `severity` is no longer compared                   2 cases
--   the refusal handler goes round the throttle        3 cases
--   the vehicle handler goes round the throttle        1 case
--   the record is never refreshed after a send         1 case
--   the window boundary becomes exclusive (`>`)        1 case
--   the window is ten times longer                     3 cases
--
-- THE TWO SURVIVORS WERE THE SAME SURVIVOR TWICE and one of them was closed by
-- changing the code rather than by adding a case: `flushHeld` cleared each note
-- after sending it while the caller dropped the whole record on the next line,
-- so deleting either was unobservable. They are now one function.
--
-- WHAT STILL SURVIVES, STATED RATHER THAN QUIETLY LEFT: deleting the
-- `lastSaid[k] = nil` inside `flushAndForget`. It leaks -- one small record per
-- case, for the life of the process -- and a leak has no behavioural signal to
-- assert on. `filed`'s equivalent drop IS caught, but only because deleting it
-- changes which cases get OPENED in the next match; this map is read by nothing
-- after its match ends. Pinning it would mean exposing the map for a test to
-- count, and BR.Incident.stats() already has no reader.

describe('corroboration.nine-seconds-of-cheating-is-not-nine-rows')
do
    -- ═══ THE REPORT, REPRODUCED (the owner, 2026-08-22) ═══
    --
    -- "For the record it seems to be filing a corroboration every few seconds
    -- (see attached)". The screenshot was one `Weapon strip` and then a Note
    -- every single second for nine seconds:
    --
    --   Note -- 3 refusals this match - last: weapon is not one this gamemode issues
    --   Note -- 4 refusals this match - ...                            ... up to 11.
    --
    -- THE CADENCE IS NOT A GUESS. Nine consecutive counts, one a second, is what
    -- server/strip.lua's MIN_INTERVAL_MS (900ms) and client/inventory.lua's
    -- STRIP_REPORT_MS (1000ms) allow through, and it is the shape no other
    -- producer has: server/damage.lua announces at doublings, so its counts jump
    -- 2, 4, 8. This drives the same eleven strips the owner drew.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)   -- 1: silent
    W.at(5000); W.strip(1, CONJURED)   -- 2: opens the case
    W.ack(7, 'license:cheat', 'inc-1')

    -- Nine more, one a second: offences 3 through 11.
    for i = 1, 9 do
        W.at(5000 + i * 1000)
        W.strip(1, CONJURED)
    end

    ok(#W.S.corroborations == 1,
        'nine seconds of it is ONE row, not nine', #W.S.corroborations)

    -- ═══ AND ROW 11 IS STILL AVAILABLE TO BE READ ═══
    --
    -- "11 refusals this match" is real information; the nine rows carrying it
    -- were not. This is the half a plain drop-throttle would have lost.
    W.at(60000)
    W.endMatch(7)

    local last = W.S.corroborations[#W.S.corroborations]
    ok(last and last.count == 11,
        'and the record still says eleven', last and tostring(last.count))
end

describe('corroboration.a-changed-finding-never-waits')
do
    -- THE THROTTLE IS NOT A MUTE BUTTON, and this is the line between the two.
    -- Rows 3 through 11 of the owner's screenshot were suppressible because they
    -- said what row 2 said. A row that says something NEW -- a different reason,
    -- a worse tier -- is the row an admin is scrolling for, and it goes out on
    -- arrival however recently the last one did.
    local W = newTimelineWorld()
    local V = W.BR.Config.VehicleRefusal
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)
    W.at(5000); W.strip(1, CONJURED)   -- opens a STRIP case
    W.ack(7, 'license:cheat', 'inc-1')

    -- Two strips one second apart: the second says nothing new and waits.
    W.at(6000); W.strip(1, CONJURED)
    W.at(7000); W.strip(1, CONJURED)
    ok(#W.S.corroborations == 1, 'a repeat waits', #W.S.corroborations)

    -- A REFUSED VEHICLE IN THE SAME SECOND. Same case -- `priorFor` crosses
    -- kinds -- but `reason` is now config/vehicles.lua's own prose rather than
    -- the shot taxonomy's sentence, so it is a different finding.
    W.at(7500); W.vehicle(1, 7, 'license:cheat', 'Cheater', 2, 1, V.FLIES)
    ok(#W.S.corroborations == 2,
        'a different reason does not, even half a second later',
        #W.S.corroborations)
    -- GUARDED, LIKE EVERY OTHER INDEX IN THIS FILE. A bare
    -- `W.S.corroborations[2].reason` aborts the whole suite the moment the row
    -- it is asserting the existence of is missing -- which is exactly the state
    -- a broken throttle produces, so the run that most needs the rest of these
    -- cases is the one that would never reach them.
    local got = W.S.corroborations[2]
    ok(got and got.reason == V.FLIES,
        'and it is the vehicle that got through', got and got.reason)

    -- AND THE SECOND KIND FOLDS ON ITS OWN TERMS. The same vehicle rule again is
    -- a repeat like any other.
    W.at(8000); W.vehicle(1, 7, 'license:cheat', 'Cheater', 3, 2, V.FLIES)
    ok(#W.S.corroborations == 2, 'while a repeat of THAT waits too',
        #W.S.corroborations)
end

describe('corroboration.a-worse-tier-never-waits')
do
    -- SEVERITY IS THE OTHER HALF OF "SOMETHING NEW", and it is asserted apart
    -- from `reason` because they are two fields and a throttle that checked only
    -- one would read, in every other case in this file, exactly like a throttle
    -- that checked both. A case producing `high` where it had been producing
    -- `normal` has changed in the one field an admin triages on.
    --
    -- DRIVEN THROUGH THE REFUSAL PATH, which is the only producer whose severity
    -- varies: server/damage.lua carries the tier of the refusal that tripped and
    -- BR.ShotTier grades them differently. The strip and vehicle handlers both
    -- read one constant, so neither could ever exercise this.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.file(7, 'license:cheat', 'Cheater', 'inc-1')

    local function refusal(at, count, seq, severity)
        W.at(at)
        W.env.TriggerEvent('br:ringmaster:refusal', {
            matchId = 7, license = 'license:cheat', name = 'Cheater',
            count = count, windowMs = 4000,
            reason  = W.BR.ShotRefusal.NO_WEAPON,
            reasons = { [W.BR.ShotRefusal.NO_WEAPON] = count },
            severity = severity, seq = seq, at = at,
        })
    end

    refusal(5000, 16, 2, 'normal')
    refusal(6000, 32, 3, 'normal')
    ok(#W.S.corroborations == 1, 'the same tier twice is one row',
        #W.S.corroborations)

    refusal(7000, 64, 4, 'high')
    ok(#W.S.corroborations == 2,
        'and a worse tier a second later is a row of its own',
        #W.S.corroborations)
    ok(W.S.corroborations[2] and W.S.corroborations[2].severity == 'high',
        'the one that got through is the worse one',
        W.S.corroborations[2] and W.S.corroborations[2].severity)
end

describe('corroboration.the-window-is-inclusive')
do
    -- EXACTLY ONE WINDOW LATER COUNTS AS PAST IT, asserted rather than left to
    -- whichever comparison somebody types next. `>` where this file has `>=` is
    -- a one-character change that every other case here would sail through,
    -- because none of them lands on the boundary to the millisecond.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)
    W.at(5000); W.strip(1, CONJURED)   -- opens the case
    W.ack(7, 'license:cheat', 'inc-1')
    W.at(6000); W.strip(1, CONJURED)   -- the first repeat, sent at once

    -- 6000 + CORROBORATE_MIN_INTERVAL_MS, to the millisecond.
    W.at(36000); W.strip(1, CONJURED)
    ok(#W.S.corroborations == 2,
        'a repeat exactly one window later goes out', #W.S.corroborations)
end

describe('corroboration.the-window-reopens')
do
    -- A CASE STILL SAYS "IT IS STILL HAPPENING", just not every second. Once the
    -- window has passed the next repeat goes out on its own -- no teardown, no
    -- change of finding -- which is what keeps a long match's record breathing
    -- rather than silent from the first row to the last.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)
    W.at(5000); W.strip(1, CONJURED)   -- opens the case
    W.ack(7, 'license:cheat', 'inc-1')

    W.at(6000);  W.strip(1, CONJURED)  -- the first repeat, sent at once
    W.at(35000); W.strip(1, CONJURED)  -- inside the window still: held
    ok(#W.S.corroborations == 1, 'inside the window it holds', #W.S.corroborations)

    W.at(37000); W.strip(1, CONJURED)  -- past 6000 + 30s: the window reopened
    ok(#W.S.corroborations == 2,
        'and past it the next one goes out with no teardown needed',
        #W.S.corroborations)
    -- FIVE, NOT THREE AND NOT FOUR. Three is what the first row said; four is
    -- the offence that was waiting when this one arrived and superseded it. The
    -- number that goes out is always the newest, which is what makes a held note
    -- costless.
    local reopened = W.S.corroborations[2]
    ok(reopened and reopened.count == 5,
        'carrying the count as it stands at that moment, not as it stood at the first row',
        reopened and tostring(reopened.count))
end

describe('corroboration.a-quiet-case-releases-nothing')
do
    -- NOTHING HELD MEANS NOTHING SENT. The teardown flush must not invent a row
    -- for a case whose repeats all went out already -- a duplicate note is a
    -- second claim about a person, and this is the cheapest place to catch one.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)
    W.at(5000); W.strip(1, CONJURED)   -- opens the case
    W.ack(7, 'license:cheat', 'inc-1')
    W.at(6000); W.strip(1, CONJURED)   -- one repeat, sent at once, nothing behind it

    ok(#W.S.corroborations == 1, 'one repeat, one row', #W.S.corroborations)

    W.at(40000)
    W.endMatch(7)
    ok(#W.S.corroborations == 1,
        'and the teardown adds nothing, because nothing was waiting',
        #W.S.corroborations)

    -- AND THE MATCH AFTER IT STARTS CLEAN. The teardown drops the per-match
    -- record, so the next round's first repeat is a FIRST repeat -- it must not
    -- inherit a window from a match that is over.
    W.startMatch(8, 100000)
    W.join(1, 8, 'license:cheat', 'Cheater')
    W.at(101000); W.strip(1, CONJURED)
    W.at(102000); W.strip(1, CONJURED)   -- opens a case in the NEW match
    W.ack(8, 'license:cheat', 'inc-2')
    W.at(103000); W.strip(1, CONJURED)

    local c = W.S.corroborations[#W.S.corroborations]
    ok(#W.S.corroborations == 2 and c and c.incidentId == 'inc-2',
        'and a new match corroborates at once rather than inheriting a window',
        #W.S.corroborations)
end

describe('strip.nobody-is-exempt')
do
    -- ═══ THE EXEMPTION IS GONE, AND ITS ABSENCE IS PINNED ═══
    --
    -- An admin exemption lived here, skipping the report for anyone holding
    -- BR.Grants.CONSOLE. The owner removed it on 2026-08-21: "I don't want
    -- admins to be exempt from any incidents please."
    --
    -- THIS CASE EXISTS SO NOBODY RESTORES IT AS A KINDNESS. The argument for
    -- the exemption is genuinely appealing -- the owner grants themselves
    -- weapons constantly while testing, and every one is a strip -- and that is
    -- exactly why it needs a test rather than a comment. The hole it opened was
    -- shaped like the accounts with the most power.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:owner', 'Owner')
    W.admin('license:owner')

    W.at(4000); W.strip(1, CONJURED)
    W.at(5000); W.strip(1, CONJURED)

    ok(#W.S.incidents == 1, 'an admin who conjures a weapon gets a case like anyone else',
        #W.S.incidents)
    ok(W.lastIncident() and W.lastIncident().subjectLicense == 'license:owner',
        'and it is about them', W.lastIncident() and W.lastIncident().subjectLicense)

    -- AND THEY ARE BUFFERED. The old exemption sat BELOW the evidence note so an
    -- exempt player's strips were recorded nowhere at all. Nothing is skipped
    -- now, so both strips are on the timeline the case is created with.
    local strips = ofKind(W.lastIncident() and W.lastIncident().matchTimeline, 'weapon_strip')
    ok(#strips == 2, 'with both strips on its timeline', #strips)

    -- REPEATS STILL APPEND RATHER THAN RE-FILE, for staff as for anyone. The
    -- rule that matters is one case per offender per match, not who they are.
    --
    -- THE ACK IS NOT CEREMONY. `priorFor` recognises an existing case by the id
    -- br_ringmaster hands back after the write lands; without it the server has
    -- filed something it cannot yet name, and the next strip files again. That
    -- is the real sequence, so the test reproduces it rather than reaching past
    -- it -- and it is why this assertion read 3 before the ack was added.
    W.ack(7, 'license:owner', 'inc-admin-1')
    for i = 2, 6 do
        W.at(5000 + i * 1000)
        W.strip(1, CONJURED)
    end
    ok(#W.S.incidents == 1, 'and five more strips open no second case', #W.S.incidents)
end

describe('strip.grant-state-is-irrelevant')
do
    -- THE GRANT IS NOT CONSULTED AT ALL ANY MORE, which is a stronger statement
    -- than "admins are not exempt" and is the one worth pinning. A previous
    -- version read BR.Grants.holds and treated its three answers -- true, false
    -- and nil for "never read this row" -- as reasons to stay silent. All three
    -- now file identically, so a slow or failed DynamoDB read cannot decide
    -- whether an accusation is made.
    for _, case in ipairs({
        { label = 'an admin',                    setup = 'admin'  },
        { label = 'a player known not to be one', setup = 'plain' },
        { label = 'a player whose grant was never read', setup = 'unread' },
    }) do
        local W = newTimelineWorld()
        W.startMatch(7, 1000)
        W.join(1, 7, 'license:subject', 'Subject')
        if case.setup == 'admin' then W.admin('license:subject')
        elseif case.setup == 'unread' then W.unread('license:subject') end

        W.at(4000); W.strip(1, CONJURED)
        W.at(5000); W.strip(1, CONJURED)
        ok(#W.S.incidents == 1, case.label .. ' files a case', #W.S.incidents)
    end
end


describe('strip.our-own-weapon-is-not-evidence')
do
    -- THE ONLY FALSE POSITIVE THIS FEATURE CAN PRODUCE. The client strips
    -- anything that is not the ACTIVE slot, so a weapon from another slot of the
    -- player's own inventory -- held for the tick between a slot change and the
    -- grant landing -- is stripped too. Stripping it is harmless. Opening a case
    -- about it would put an innocent player in a moderation queue over a tenth
    -- of a second of tick ordering.
    --
    -- CHECKED AGAINST THE INVENTORY THE SERVER HOLDS, not the one the client
    -- reported, because the client's copy is exactly what a compromised client
    -- controls.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:honest', 'Honest')
    W.carrying(1, { 'carbinerifle' })

    W.at(4000); W.strip(1, CARBINE)
    W.at(5000); W.strip(1, CARBINE)
    ok(#W.S.incidents == 0, 'a weapon the server DID issue them opens no case',
        #W.S.incidents)

    -- And the guard is not simply "never file": the same player, holding the
    -- same inventory, conjuring something else still files -- on the second one.
    W.at(6000); W.strip(1, CONJURED)
    ok(#W.S.incidents == 0, 'one conjured weapon is still only one', #W.S.incidents)
    W.at(7000); W.strip(1, CONJURED)
    ok(#W.S.incidents == 1, 'while two weapons it did not issue still do',
        #W.S.incidents)

    -- AND THE RACED REPORTS DID NOT COUNT TOWARDS THE BAR. Two carbine strips
    -- plus two conjured ones is a case about TWO offences, not four -- the
    -- refusal returns before `rec.count` is touched. A version that counted
    -- them would file on the first genuine strip and put our own tick ordering
    -- in the summary.
    local p = W.lastIncident()
    ok(p and type(p.summary) == 'string' and p.summary:find('2 unissued') ~= nil,
        'and the queue line counts two offences, not four',
        p and tostring(p.summary))
end

describe('strip.flood-is-bounded')
do
    -- A CLIENT CHOOSES HOW OFTEN IT SENDS THIS, so the number that bounds it has
    -- to be on the server. The client throttles too, but it is code the offender
    -- has already decided to modify.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000)
    for _ = 1, 50 do W.strip(1, CONJURED) end   -- all in the same millisecond

    -- FIFTY MESSAGES ARE ONE OFFENCE, so under the owner's bar of two they open
    -- nothing at all. That is the throttle doing the only job it was ever the
    -- control for: a client cannot buy itself a case by flooding, and it cannot
    -- buy somebody else one either.
    ok(#W.S.incidents == 0, 'a flood inside one window opens NO case',
        #W.S.incidents)

    local st = W.BR.Strip.stats()
    ok(st.throttled == 49, 'the rest are refused and counted as refused',
        st.throttled)

    -- A SECOND WINDOW IS A SECOND OFFENCE, and that is what files.
    W.at(5000); W.strip(1, CONJURED)
    ok(#W.S.incidents == 1, 'a strip in the next window opens exactly one case',
        #W.S.incidents)

    local strips = ofKind(W.lastIncident() and W.lastIncident().matchTimeline,
        'weapon_strip')
    ok(#strips == 2, 'and puts two entries on the timeline, not fifty-one',
        #strips)
end

describe('strip.truncation-is-never-silent')
do
    -- THE HONESTY GUARANTEE, AND FOR STRIPS IT IS CARRIED BY ONE FLAG ALONE.
    --
    -- A truncated kill list says so twice: `matchTimelineComplete` goes false
    -- AND `matchKillsSeen` states the real number. Strips have no equivalent
    -- counter and deliberately never will -- the close write may touch exactly
    -- five attributes, and that list IS the game's IAM grant on
    -- `ringmaster-incidents`, so a sixth would mean widening a policy to carry a
    -- number. So the flag is the whole of it, and it has to be right.
    --
    -- WHAT IT PREVENTS is the one failure a moderation record must not produce:
    -- a list that stops early and looks complete, telling an admin "this is
    -- everything they did" when it is not.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(2000); W.strip(1, CONJURED)
    W.at(3000); W.strip(1, CONJURED)
    W.ack(7, 'license:cheat', 'inc-1')

    local CAP = W.BR.IncidentBuild.TIMELINE_LIMITS.MAX_TIMELINE_STRIPS
    for i = 1, CAP + 20 do
        W.at(3000 + i * 1000)
        W.strip(1, CONJURED)
    end

    W.at(500000)
    W.endMatch(7)

    local c = W.lastClose()
    local strips = ofKind(c and c.matchTimeline, 'weapon_strip')
    ok(#strips <= CAP, 'a runaway strip count is bounded', #strips)
    ok(c and c.matchTimelineComplete == false,
        'and a truncated timeline never claims to be complete',
        c and tostring(c.matchTimelineComplete))
end

describe('strip.timeline-stays-chronological')
do
    -- THE ORDER OF THIS LIST IS NOT COSMETIC. js-src/br_ddb/src/close.js takes
    -- the LAST n entries when a close overflows, so a timeline that appended
    -- every strip after every kill would truncate by KIND rather than by age --
    -- and an offender who kept stripping would push their own kills off the
    -- record, which is the opposite of what the evidence is for.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.join(2, 7, 'license:v1', 'Victim1')
    W.join(3, 7, 'license:v2', 'Victim2')

    W.at(2000); W.strip(1, CONJURED)     -- recorded, silent
    W.at(2900); W.strip(1, CONJURED)     -- opens the case
    W.ack(7, 'license:cheat', 'inc-1')

    W.at(3000); W.kill(1, 2)
    W.at(4000); W.strip(1, CONJURED)
    W.at(5000); W.kill(1, 3)
    W.at(6000); W.strip(1, CONJURED)

    W.at(9000); W.endMatch(7)

    local c = W.lastClose()
    ok(c ~= nil, 'the case closes')

    local last, sorted, kinds = -1, true, {}
    for _, e in ipairs(c and c.matchTimeline or {}) do
        if e.at < last then sorted = false end
        last = e.at
        kinds[#kinds + 1] = e.kind
    end
    ok(sorted, 'kills and strips interleave in the order they happened',
        table.concat(kinds, ','))
    ok(table.concat(kinds, ',') == 'kill,weapon_strip,kill,weapon_strip,match_end',
        'and that order is the one the match actually had',
        table.concat(kinds, ','))
end

describe('strip.needs-a-live-match')
do
    -- NO MATCH, NOTHING TO PUT IT ON. A report from the lobby has no round to be
    -- about, and the evidence buffer would refuse the note anyway.
    --
    -- TWO OF THEM, DELIBERATELY. The bar is two strips (owner, 2026-08-20), so
    -- a single one files nothing anywhere and this case would pass without
    -- exercising the match guard at all.
    local W = newTimelineWorld()
    W.join(1, nil, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)
    W.at(5000); W.strip(1, CONJURED)
    ok(#W.S.incidents == 0, 'strips reported outside a match file nothing',
        #W.S.incidents)
    ok(W.BR.Strip.stats().counted == 0, 'and are not even counted',
        W.BR.Strip.stats().counted)
end

describe('strip.rubbish-is-not-a-weapon')
do
    -- A CLIENT SENDS WHATEVER IT LIKES. The only record it can write to is its
    -- own -- `source` decides who the entry is about -- so the failure to guard
    -- against is a malformed value being STORED as though it named something.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, 'not a hash')
    W.at(5000); W.strip(1, 'not a hash')

    local p = W.lastIncident()
    ok(p ~= nil, 'a strip with a nonsense weapon is still a strip')

    local strips = ofKind(p and p.matchTimeline, 'weapon_strip')
    ok(#strips == 2, 'and reaches the timeline', #strips)
    -- IN LUA `0` IS TRUTHY, so a hash of zero would sail through a bare check
    -- and land on a moderation record as though it named a weapon.
    ok(strips[1] and strips[1].weapon == nil,
        'with no weapon on it rather than a stored zero',
        strips[1] and tostring(strips[1].weapon))
end

describe('strip.quiet-match-still-costs-nothing')
do
    -- THE COST RULE, RESTATED FOR THE NEW SOURCE. Adding a second way to open a
    -- case must not add a write to a match that produces none -- and this is the
    -- source whose volume an offender chooses, so it is the one worth pinning.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:clean', 'Clean')
    W.join(2, 7, 'license:v1', 'Victim1')

    W.at(2000); W.kill(1, 2)
    W.at(9000); W.endMatch(7)

    ok(#W.S.incidents == 0, 'a match with no strips files nothing')
    ok(#W.S.closes == 0, 'and closes nothing -- zero writes', #W.S.closes)
end

-- ======================================================================== --
-- A REFUSED VEHICLE READS AS A VEHICLE, START TO FINISH  (#193, playtest)
-- ======================================================================== --
--
-- THE OWNER, 2026-08-22: "when getting in an unauthorized vehicle, the incident
-- is described in ringmaster as an unauthorized weapon."
--
-- WHERE THAT CAME FROM, AND WHY NO PURE-FUNCTION TEST COULD HAVE CAUGHT IT.
-- BR.IncidentBuild.fromVehicle was correct and is covered in test_shared.lua:
-- the CASE has always named the vehicle rule -- "N refused vehicles this match
-- -- vehicle flies". What was wrong was the CORROBORATION, which is built in
-- server/incident.lua and not in br_lib at all -- the whole block was copied
-- from the strip handler above it, `reason` included, and that field is the
-- literal sentence "weapon is not one this gamemode issues". Ringmaster prints
-- it verbatim onto the case's timeline. So the queue row said vehicle and every
-- row underneath it said weapon.
--
-- WHICH IS WHY THESE CASES ARE HERE RATHER THAN IN test_shared.lua. The whole
-- of this file's `br:core:vehicle` handler had no coverage of any kind; the
-- functions under it were fully covered and entirely correct. That is the same
-- gap the header of the strip section describes and the same one this suite
-- exists to close: a caller wiring correct functions together wrongly.
--
-- MUTATION TESTED, which is the only reason to trust any of it. Each was broken
-- on purpose and this suite watched to fail by name; the counts are what was
-- observed rather than what was expected:
--
--   `reason` goes back to ShotRefusal.NO_WEAPON   5 cases  (the reported bug)
--   `reason` defaults: `ev.why or NO_WEAPON`      1 case
--   the corroboration severity becomes 'normal'   2 cases
--   the vehicle path never corroborates          15 cases

describe('vehicle.the-case-reads-as-a-vehicle')
do
    local W = newTimelineWorld()
    local V = W.BR.Config.VehicleRefusal
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:pilot', 'Pilot')

    -- THE DETECTOR'S FIRST ANNOUNCEMENT IS THE SECOND OFFENCE. See the bar in
    -- server/vehicles.lua; `count` is offences and `seq` is announcements.
    W.at(4000); W.vehicle(1, 7, 'license:pilot', 'Pilot', 2, 1, V.FLIES)

    local p = W.lastIncident()
    ok(p ~= nil, 'a refused vehicle files a case')
    ok(p and p.kind == 'anticheat' and p.category == 'system',
        'in the anticheat shape, filed by nobody')
    ok(p and p.summary == '2 refused vehicles this match -- vehicle flies',
        'and the one line an admin reads is about a VEHICLE', p and p.summary)
    -- THE WORD THAT MUST NOT BE IN IT. Asserted as an absence rather than only
    -- as the sentence above, because the sentence could be re-worded correctly
    -- while somebody re-borrowed the shot taxonomy for one of its halves.
    ok(p and not p.summary:find('weapon is not one this gamemode issues'),
        'and never as the shot validator\'s sentence about weapons', p and p.summary)
end

describe('vehicle.corroborations-read-as-vehicles-too')
do
    -- ═══ THE REGRESSION THE OWNER REPORTED, PINNED ═══
    local W = newTimelineWorld()
    local V = W.BR.Config.VehicleRefusal
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:pilot', 'Pilot')

    W.at(4000); W.vehicle(1, 7, 'license:pilot', 'Pilot', 2, 1, V.FLIES)
    W.ack(7, 'license:pilot', 'inc-veh')

    -- A JET, THEN A TANK. The detector sends the LATEST reason, so the two
    -- corroborations carry different halves of the owner's rule -- which is the
    -- property a single borrowed constant destroyed.
    W.at(5000); W.vehicle(1, 7, 'license:pilot', 'Pilot', 3, 2, V.FLIES)
    W.at(6000); W.vehicle(1, 7, 'license:pilot', 'Pilot', 4, 3, V.ARMED)

    ok(#W.S.incidents == 1, 'three refused vehicles are ONE case', #W.S.incidents)
    ok(#W.S.corroborations == 2, 'and two corroborations', #W.S.corroborations)

    local c1, c2 = W.S.corroborations[1], W.S.corroborations[2]
    ok(c1 and c1.incidentId == 'inc-veh' and c2 and c2.incidentId == 'inc-veh',
        'both against the case the write came back with')

    -- THE ASSERTION THIS WHOLE SECTION EXISTS FOR.
    ok(c1 and c1.reason == V.FLIES,
        'the first corroboration says why the VEHICLE was refused',
        c1 and tostring(c1.reason))
    ok(c2 and c2.reason == V.ARMED,
        'and the second carries the reason that tripped THIS time, not the first',
        c2 and tostring(c2.reason))

    local weaponish = false
    for _, c in ipairs(W.S.corroborations) do
        if c.reason == W.BR.ShotRefusal.NO_WEAPON then weaponish = true end
    end
    ok(not weaponish,
        'and neither of them describes a vehicle case as an unissued weapon')

    -- THE TIER IS STILL THE TAXONOMY'S, which is the half that was right to
    -- borrow: 'high' is a triage hint with no prose in it, and it must agree
    -- with the severity fromVehicle put on the case they attach to.
    ok(c1 and c1.severity == W.BR.ShotTier[W.BR.ShotRefusal.NO_WEAPON],
        'severity still comes from the taxonomy rather than from a literal',
        c1 and tostring(c1.severity))
    ok(c1 and c1.severity == W.lastIncident().severity,
        'and grades the corroboration exactly as the case itself is graded')

    -- THE WIRE COUNTERS, the same pair the strip path pins. A gap in either
    -- means a LOST message rather than quiet offences in between.
    ok(c1 and c1.seq == 2 and c2 and c2.seq == 3,
        'seq counts the announcements', c1 and tostring(c1.seq))
    ok(c1 and c1.count == 3 and c2 and c2.count == 4,
        'and count counts the offences', c1 and tostring(c1.count))
end

describe('vehicle.no-reason-is-said-rather-than-invented')
do
    -- A `why` THAT NEVER ARRIVED LEAVES THE FIELD ABSENT. The console drops the
    -- `last:` clause of its note entirely when `reason` is missing, which is
    -- honest; a fallback here would put the shot taxonomy's sentence back on a
    -- vehicle case through the one door this fix closed.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:pilot', 'Pilot')

    W.at(4000); W.vehicle(1, 7, 'license:pilot', 'Pilot', 2, 1, nil)
    W.ack(7, 'license:pilot', 'inc-veh')
    W.at(5000); W.vehicle(1, 7, 'license:pilot', 'Pilot', 3, 2, nil)

    local c = W.S.corroborations[1]
    ok(c ~= nil, 'it still corroborates')
    ok(c and c.reason == nil, 'and says nothing rather than guessing a reason',
        c and tostring(c.reason))
    ok(c and c.severity ~= nil, 'while the triage hint still travels')
end

describe('vehicle.a-licenseless-connection-files-nothing')
do
    -- THE RULE EVERY PRODUCER HERE SHARES. A case keyed to a server id is a case
    -- about whoever holds that slot next, and server ids are recycled within the
    -- minute. server/vehicles.lua sends nil rather than a sentinel when
    -- BR.Roster.licenseOf has no answer.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)

    W.at(4000); W.vehicle(1, 7, nil, 'Ghost', 2, 1, W.BR.Config.VehicleRefusal.FLIES)

    ok(#W.S.incidents == 0, 'no license, no case', #W.S.incidents)
    ok(#W.S.corroborations == 0, 'and nothing to corroborate either')
end

describe('vehicle.crosses-kinds-with-the-strip-path')
do
    -- ONE PLAYER, ONE ROUND, ONE RECORD -- whichever thing they did first opened
    -- it. This is `priorFor` being shared rather than per-kind, and it is the
    -- reason the corroboration's `reason` has to be the DETECTOR's word: a
    -- vehicle corroborating a strip case is exactly where a borrowed constant
    -- looks correct and is not.
    local W = newTimelineWorld()
    local V = W.BR.Config.VehicleRefusal
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)   -- recorded, announced to nobody
    W.at(5000); W.strip(1, CONJURED)   -- opens a STRIP case
    W.ack(7, 'license:cheat', 'inc-strip')

    W.at(6000); W.vehicle(1, 7, 'license:cheat', 'Cheater', 2, 1, V.ARMED)

    ok(#W.S.incidents == 1, 'the vehicle opens no second case', #W.S.incidents)
    local c = W.S.corroborations[#W.S.corroborations]
    ok(c and c.incidentId == 'inc-strip', 'it appends to the case already open')
    ok(c and c.reason == V.ARMED,
        'and still says what the VEHICLE did, on a case a weapon opened',
        c and tostring(c.reason))
end

-- ======================================================================== --
-- br_ringmaster's OWN half of the close  (#30, #B, #C)
-- ======================================================================== --
--
-- WHAT IS UNDER TEST HERE THAT IS NOWHERE ELSE. br_ringmaster/server/incident.lua
-- was loaded by no suite at all, which meant `realiseClose` -- the function that
-- turns the game clock into wall clock and a DURATION into a DEADLINE on its way
-- to DynamoDB -- had no coverage of any kind. A mistake in it does not throw:
-- it writes a plausible number into a real attribute, and the console renders a
-- moderation record dated 1970 or a deadline an hour in the wrong direction.
--
-- IT IS LOADED HERE, AT THE BOTTOM, ON PURPOSE. This file's harness is one
-- global Lua state shared by every case above it, and this file registers
-- handlers for events those cases do not use. Loading it last keeps that
-- one-directional.

loadAll({ 'br_ringmaster/server/incident.lua' })

--- The last payload br_ddb was asked to write, and a way to answer for it.
local ddbClose = { req = nil, payload = nil }
AddEventHandler('br:ddb:incidentClose', function(req, payload)
    ddbClose.req, ddbClose.payload = req, payload
end)
local function answerClose(ok, extra)
    TriggerEvent('br:ddb:incidentCloseResult', ddbClose.req, ok, extra or {})
end

--- Everything brring printed this call.
local function brringOutput()
    local from = #printed + 1
    commands['brring'].fn(0, {}, '')
    return table.concat(printed, '\n', from, #printed)
end

--- The last payload br_ddb was asked to file.
local ddbPut = { req = nil, payload = nil }
AddEventHandler('br:ddb:putIncident', function(req, _, payload)
    ddbPut.req, ddbPut.payload = req, payload
end)

describe('filing.realise')
do
    -- THE CONVERSION IS EXHAUSTIVE OR IT IS WORSE THAN NOTHING. Every timestamp
    -- on an incident is a GetGameTimer() reading on the way in, and one field
    -- missed here renders as January 1970 beside fields that render correctly --
    -- which reads as corrupt data rather than as a bug in one line of Lua.
    --
    -- `matchCreatedAt` IS THE NEWEST OF THEM and, for a case filed during
    -- warmup, the ONLY match timestamp on the row -- so a missed conversion here
    -- is the whole of what that case says about its match, wrong.
    fakeTime = 5000000

    TriggerEvent('br:ringmaster:incident', {
        kind           = 'anticheat',
        severity       = 'high',
        subjectLicense = 'license:cheat',
        matchId        = 7,
        atGameMs       = 2000000,
        matchCreatedAt = 1000000,
        matchTimeline  = { { at = 1000000, kind = 'match_created' } },
    })

    local p = ddbPut.payload
    ok(p ~= nil, 'the filing reaches br_ddb')
    ok(p and p.matchCreatedAt and p.matchCreatedAt > 1700000000000,
        'the formation time is converted to a real unix millisecond',
        p and tostring(p.matchCreatedAt))
    ok(p and p.openedAt and p.openedAt - p.matchCreatedAt == 1000000,
        'and the gap between it and the filing survives the conversion',
        p and tostring(p.openedAt and p.matchCreatedAt
            and (p.openedAt - p.matchCreatedAt)))
    ok(p and p.matchTimeline[1].at == p.matchCreatedAt,
        'and the timeline entry at that moment realises to exactly it')
end

describe('close.realise')
do
    fakeTime = 5000000

    -- The shape br_core emits: game-clock readings and a DURATION, because
    -- br_lib has no wall clock and br_ringmaster owns the pair.
    TriggerEvent('br:ringmaster:incidentClose', {
        incidentId            = 'inc-real',
        matchId               = 7,
        subjectLicense        = 'license:cheat',
        matchEndedAt          = 4000000,
        matchStartedAt        = 1000000,
        matchEndsByMs         = 60 * 60 * 1000,
        matchTimeline         = { { at = 1000000, kind = 'match_created' } },
        matchTimelineComplete = true,
        matchKillsSeen        = 0,
    })

    local p = ddbClose.payload
    ok(p ~= nil, 'the close reaches br_ddb')

    -- REAL TIME, NOT GAME TIME. `os.time()` is seconds, so the absolute value
    -- cannot be pinned without making the suite depend on when it runs -- but
    -- the DIFFERENCES are exact arithmetic and are what a missed conversion
    -- destroys. A `matchStartedAt` left as 1000000 fails the first of these.
    ok(p and p.matchStartedAt and p.matchStartedAt > 1700000000000,
        'the start is converted to a real unix millisecond',
        p and tostring(p.matchStartedAt))
    ok(p and p.matchEndedAt and p.matchEndedAt - p.matchStartedAt == 3000000,
        'and the gap between start and end survives the conversion',
        p and tostring(p.matchEndedAt and p.matchStartedAt
            and (p.matchEndedAt - p.matchStartedAt)))

    -- THE DURATION BECOMES AN ABSOLUTE DEADLINE, HERE AND ONLY HERE. The console
    -- compares it against Date.now() and knows nothing about the game's uptime.
    ok(p and p.matchEndsBy and p.matchEndsBy - p.matchStartedAt == 60 * 60 * 1000,
        'the duration becomes a deadline measured from the realised start',
        p and tostring(p.matchEndsBy))
    ok(p and p.matchEndsByMs == nil,
        'and the duration itself does not travel on to DynamoDB',
        p and tostring(p.matchEndsByMs))

    -- COMPUTED FROM THE SAME SAMPLE AS THE START. Two clock reads would drift,
    -- and a deadline sampled apart from the start it is measured from is the one
    -- thing this pair must never be.
    ok(p and p.matchTimeline[1].at == p.matchStartedAt,
        'a timeline entry at the start realises to exactly the start')
end

describe('close.no-start')
do
    -- A MATCH THAT DISSOLVED ON THE PAD. `real()` answers nil for nil, so
    -- nothing is invented -- and close.js omits the attribute entirely rather
    -- than writing a null over whatever the row already says.
    TriggerEvent('br:ringmaster:incidentClose', {
        incidentId    = 'inc-nostart',
        matchEndedAt  = 4000000,
        matchTimeline = {},
    })

    local p = ddbClose.payload
    ok(p and p.incidentId == 'inc-nostart', 'a startless close still goes out')
    ok(p and p.matchStartedAt == nil,
        'with no start invented for it', p and tostring(p.matchStartedAt))
    ok(p and p.matchEndsBy == nil,
        'and no deadline derived from one', p and tostring(p.matchEndsBy))
end

describe('brring.closes')
do
    -- ═══ #C: THE COUNTER THAT NOTHING PRINTED ═══
    --
    -- `closeFailed` has been counted since #30 and surfaced nowhere. The failure
    -- it counts is the quietest in the pipeline: the case is filed, the row is
    -- durable, the console lists it, and the write that would say how the match
    -- finished never lands. Every symptom is on the CONSOLE -- cases reading
    -- "end never reported" -- so the obvious diagnosis is a console bug and the
    -- actual cause is an IAM allowlist missing an attribute this write touches.
    -- That has now happened three times.

    -- The two closes above were never answered, so nothing has resolved yet.
    ok(BR.Ring.incidentStats().closeFailed == 0,
        'nothing has failed yet', BR.Ring.incidentStats().closeFailed)

    local idle = brringOutput()
    ok(idle:find('closes 0, failed 0', 1, true) ~= nil,
        'brring reports the close counters even when they are zero', idle)

    -- ONE THAT SUCCEEDS.
    answerClose(true, {})
    ok(BR.Ring.incidentStats().closed == 1,
        'a successful close is counted', BR.Ring.incidentStats().closed)

    -- AND ONE THAT DOES NOT, with the answer an un-widened attribute allowlist
    -- actually produces.
    TriggerEvent('br:ringmaster:incidentClose', {
        incidentId    = 'inc-denied',
        matchEndedAt  = 4000000,
        matchTimeline = {},
    })
    answerClose(false, { error = 'AccessDeniedException', retryable = false })

    ok(BR.Ring.incidentStats().closeFailed == 1,
        'a refused close is counted', BR.Ring.incidentStats().closeFailed)

    local after = brringOutput()
    ok(after:find('closes 1, failed 1', 1, true) ~= nil,
        'and brring prints both numbers', after)

    -- THE DIAGNOSIS, NOT JUST THE COUNT. The allowlist is the one cause a reader
    -- cannot guess from the console's symptom, and it has been the cause every
    -- time.
    ok(after:find('dynamodb:Attributes', 1, true) ~= nil,
        'along with where to look when it is not zero', after)
end

-- ----------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
