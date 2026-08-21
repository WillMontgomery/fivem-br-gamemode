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
    ok(#notices(at, 101) == 1 and notices(at, 101)[1] == 'Too far away.',
        'inReach refuses AUDIBLY', table.concat(notices(at, 101), ' / '))

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

    function W.startMatch(matchId, startedAt)
        S.matches[matchId] = { id = matchId, startedAt = startedAt }
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

    --- The acknowledgement br_ringmaster sends once a row is durable.
    function W.ack(matchId, license, incidentId)
        env.TriggerEvent('br:incident:filed', {
            incidentId = incidentId, matchId = matchId, subjectLicense = license,
        })
    end

    --- The teardown br_core runs: `br:match:destroyed` is the only path out of
    --- the registry, and server/evidence.lua answers it.
    function W.endMatch(matchId)
        env.TriggerEvent('br:match:destroyed', { matchId = matchId })
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
    ok(p and #(p.matchTimeline or {}) == 0, 'and an empty timeline')
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

describe('strip.opens-a-case')
do
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000)
    W.strip(1, CONJURED)

    local p = W.lastIncident()
    ok(p ~= nil, 'the FIRST strip opens a case')
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

    -- THE EVENT ITSELF IS ON THE TIMELINE, at the moment the server stamped it.
    local strips = ofKind(p and p.matchTimeline, 'weapon_strip')
    ok(#strips == 1, 'the strip that opened the case is on its timeline', #strips)
    ok(strips[1] and strips[1].at == 4000,
        'stamped by the SERVER clock, never by the client',
        strips[1] and tostring(strips[1].at))
    ok(strips[1] and strips[1].weapon == CONJURED,
        'and carries the hash, which is the only name a conjured weapon has',
        strips[1] and tostring(strips[1].weapon))
end

describe('strip.repeats-append')
do
    -- THE OWNER'S SENTENCE, ASSERTED. Several strips in one match are ONE case
    -- with several timeline entries -- not one case each, which would let a
    -- persistent cheater bury the queue the case is meant to be read from.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)
    W.ack(7, 'license:cheat', 'inc-1')

    -- Recursively, exactly as described. Spaced past the server's own throttle
    -- so every one of them counts.
    for i = 1, 5 do
        W.at(4000 + i * 1000)
        W.strip(1, CONJURED)
    end

    ok(#W.S.incidents == 1, 'five more strips file no second case', #W.S.incidents)
    ok(#W.S.corroborations > 0, 'they corroborate the one that exists',
        #W.S.corroborations)
    ok(W.S.corroborations[1] and W.S.corroborations[1].incidentId == 'inc-1',
        'against the case the write came back with')

    -- ...AND EVERY ONE OF THEM REACHES THE TIMELINE, which is the half the
    -- corroboration channel cannot do: corroborations land in the console's own
    -- `events` list, and the owner asked for the incident's timeline.
    W.at(20000)
    W.endMatch(7)

    local c = W.lastClose()
    ok(c ~= nil, 'the match ending closes that one case')
    ok(c and c.incidentId == 'inc-1', 'the same one, not a new row')

    local strips = ofKind(c and c.matchTimeline, 'weapon_strip')
    ok(#strips == 5, 'every strip after the filing is on the close', #strips)
    ok(strips[1] and strips[1].at == 5000, 'oldest first',
        strips[1] and tostring(strips[1].at))

    -- AND THE FIRST ONE IS NOT SENT TWICE. It rode the PutItem; a timeline that
    -- lists the same event twice is a claim about a person that is false.
    local dup = false
    for _, s in ipairs(strips) do if s.at == 4000 then dup = true end end
    ok(not dup, 'the strip already on the row is not repeated')

    ok(c and c.matchTimelineComplete == true,
        'and nothing was dropped, so the record says so')
end

describe('strip.announcements-are-throttled-but-the-record-is-not')
do
    -- REPORT AT THE FIRST, THEN ON EVERY DOUBLING -- the rule server/damage.lua
    -- already lands on, because the corroboration channel is a 512-deep
    -- drop-oldest outbox and an offender chooses how often this fires. What is
    -- throttled is how often the CONSOLE is told; the timeline still gets all of
    -- them, and that distinction is the whole reason this case exists.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)
    W.ack(7, 'license:cheat', 'inc-1')

    for i = 1, 15 do
        W.at(4000 + i * 1000)
        W.strip(1, CONJURED)
    end

    -- 16 strips announce at 1, 2, 4, 8, 16 -- five, of which the first opened
    -- the case and four corroborated it.
    ok(#W.S.corroborations == 4,
        'sixteen strips produce four corroborations, not fifteen',
        #W.S.corroborations)

    W.at(30000)
    W.endMatch(7)

    local strips = ofKind(W.lastClose() and W.lastClose().matchTimeline, 'weapon_strip')
    ok(#strips == 15, 'while all fifteen later strips are on the timeline', #strips)
end

describe('strip.admin-exempt')
do
    -- ═══ A DECISION TAKEN WITHOUT THE OWNER, AND PINNED SO IT CANNOT DRIFT ═══
    --
    -- The owner grants themselves weapons through vMenu constantly while
    -- testing. Every one of those is a strip, so without this the first thing
    -- this feature ships is a queue full of cases about the person who reads the
    -- queue -- and an anticheat known to be noise is one nobody opens again.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:owner', 'Owner')
    W.admin('license:owner')

    for i = 1, 5 do
        W.at(4000 + i * 1000)
        W.strip(1, CONJURED)
    end

    ok(#W.S.incidents == 0, 'an admin testing with vMenu opens no case',
        #W.S.incidents)
    ok(#W.S.corroborations == 0, 'and corroborates nothing')

    -- NOT EVEN IN THE BUFFER. An exempt player's strips are not recorded
    -- anywhere at all, so there is no quiet log of admin activity sitting in
    -- memory waiting for some later feature to read it.
    local recs = W.BR.Evidence.forLicense('license:owner')
    local held = 0
    for _, r in ipairs(recs) do held = held + #(r.strips or {}) end
    ok(held == 0, 'and nothing about them is buffered either', held)

    -- THE STRIP ITSELF IS NOT WHAT IS EXEMPT. This suite cannot see the client,
    -- but the exemption is on the REPORT and the weapon still comes out of the
    -- hand -- see the strip block in client/inventory.lua, which has no notion
    -- of a grant.
end

describe('strip.unknown-grant')
do
    -- SILENCE ON DOUBT. BR.Grants.holds answers nil for "we have never
    -- successfully read this license's row", which is not the same as "they are
    -- not an admin" -- and an accusation against a named person must not be
    -- built on a question nobody answered.
    --
    -- THE COST OF THAT IS NEARLY NOTHING, WHICH IS WHY IT IS THE RIGHT WAY
    -- ROUND, and this case proves it rather than asserting it in a comment: the
    -- behaviour repeats by definition, so the next strip files.
    local W = newTimelineWorld()
    W.startMatch(7, 1000)
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.unread('license:cheat')

    W.at(4000); W.strip(1, CONJURED)
    ok(#W.S.incidents == 0, 'a strip by a player whose grant is unread files nothing',
        #W.S.incidents)

    -- The row is read a moment later, as it always is: the cache is primed at
    -- playerJoining and `holds` re-asks on every miss.
    W.join(1, 7, 'license:cheat', 'Cheater')
    W.at(6000); W.strip(1, CONJURED)
    ok(#W.S.incidents == 1, 'and the next one opens the case', #W.S.incidents)

    local strips = ofKind(W.lastIncident() and W.lastIncident().matchTimeline,
        'weapon_strip')
    ok(#strips == 1, 'carrying only the strip that was actually countable', #strips)
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
    ok(#W.S.incidents == 0, 'a weapon the server DID issue them opens no case',
        #W.S.incidents)

    -- And the guard is not simply "never file": the same player, holding the
    -- same inventory, conjuring something else still files.
    W.at(6000); W.strip(1, CONJURED)
    ok(#W.S.incidents == 1, 'while a weapon it did not issue still does',
        #W.S.incidents)
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

    ok(#W.S.incidents == 1, 'a flood still opens exactly one case', #W.S.incidents)

    local strips = ofKind(W.lastIncident() and W.lastIncident().matchTimeline,
        'weapon_strip')
    ok(#strips == 1, 'and puts one entry on the timeline, not fifty', #strips)

    local st = W.BR.Strip.stats()
    ok(st.throttled == 49, 'the rest are refused and counted as refused',
        st.throttled)
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

    W.at(2000)
    W.strip(1, CONJURED)
    W.ack(7, 'license:cheat', 'inc-1')

    local CAP = W.BR.IncidentBuild.TIMELINE_LIMITS.MAX_TIMELINE_STRIPS
    for i = 1, CAP + 20 do
        W.at(2000 + i * 1000)
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

    W.at(2000); W.strip(1, CONJURED)     -- opens the case
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
    local W = newTimelineWorld()
    W.join(1, nil, 'license:cheat', 'Cheater')

    W.at(4000); W.strip(1, CONJURED)
    ok(#W.S.incidents == 0, 'a strip reported outside a match files nothing',
        #W.S.incidents)
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

    local p = W.lastIncident()
    ok(p ~= nil, 'a strip with a nonsense weapon is still a strip')

    local strips = ofKind(p and p.matchTimeline, 'weapon_strip')
    ok(#strips == 1, 'and reaches the timeline', #strips)
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

-- ----------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
