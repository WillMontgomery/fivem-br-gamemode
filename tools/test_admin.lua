-- Unit tests for the pause-menu admin console (#23).
--
-- WHAT IS WORTH TESTING HERE IS WHO IS OFFERED THE TAB AND WHAT THE GAME DOES
-- WHEN RINGMASTER MISBEHAVES, and neither can be produced in game without a
-- second machine, a Discord role and a deliberate outage. Both are trivial here.
--
-- br_core AND br_ringmaster ARE LOADED INTO ONE LUA STATE, which is not how they
-- run and is exactly right for the seam under test: FiveM dispatches server-side
-- TriggerEvent to every loaded handler regardless of resource, so the
-- request/response pair between the two behaves here the way it behaves there.
-- tools/test_ringmaster.lua makes the same call for the same reason.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_admin.lua

-- --------------------------------------------------------------- harness ---

local fakeTime = 0
function GetGameTimer() return fakeTime end

local convars = {}
function GetConvar(name, default)
    local v = convars[name]
    if v == nil then return default end
    return v
end

local identifiers = {}      -- [src] = { 'license:aaa', 'discord:123', ... }
function GetNumPlayerIdentifiers(src) return #(identifiers[src] or {}) end
function GetPlayerIdentifier(src, i)  return (identifiers[src] or {})[i + 1] end

local connected = {}        -- [src] = name
function GetPlayerName(src) return connected[src] end
function GetPlayers()
    local out = {}
    for src in pairs(connected) do out[#out + 1] = src end
    table.sort(out)
    return out
end
function GetCurrentResourceName() return 'br_core' end

local resourceState = { br_ddb = 'started', br_ringmaster = 'started' }
function GetResourceState(name) return resourceState[name] or 'missing' end

-- A LIST PER EVENT. Several files register the same event name -- grants.lua and
-- admin.lua both take playerDropped -- and a last-one-wins stub would silently
-- test half the path.
local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function RegisterNetEvent() end

function TriggerEvent(name, ...)
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

--- Dispatch an event as if it came FROM a player, which is the only way the
--- global `source` is set. Everything client-facing in admin.lua reads it.
local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

-- What the server sent to a client. This is the whole observable surface of the
-- feature: the tab appears because an envelope arrived carrying an origin.
local sent = {}
function TriggerClientEvent(event, target, data)
    sent[#sent + 1] = { event = event, target = target, data = data }
end
local function lastSent() return sent[#sent] end
local function sentCount() return #sent end

-- Timers, controllable. Nothing fires on its own: a test calls fireTimers() at
-- the moment it wants a deadline to land, which is the only way to test "the
-- answer never came" without actually waiting three seconds.
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { ms = ms, fn = fn } end
local function fireTimers()
    local due = timers
    timers = {}
    for _, t in ipairs(due) do t.fn() end
end
local function timerCount() return #timers end

--- How many timers of exactly this duration are armed.
---
--- BY DURATION RATHER THAN BY COUNT, because two files arm timers here and only
--- one of them is under test: server/grants.lua arms its own 5s deadline every
--- time `holds` starts a DynamoDB read, which a mint necessarily does first. A
--- bare `#timers == 1` would pass or fail depending on whether the grants cache
--- happened to be warm, which is a test that reports on its own setup.
local function timersOf(ms)
    local n = 0
    for _, t in ipairs(timers) do
        if t.ms == ms then n = n + 1 end
    end
    return n
end

--- The mint's own deadline. br_ringmaster/server/handoff.lua's TIMEOUT_MS.
local MINT_TIMEOUT_MS = 3000

-- json. encode stashes the table and returns a marker, so assertions are made
-- against the TABLE rather than against a hand-rolled JSON string -- which would
-- be testing the stub. decode answers from a registry, so a body the test did
-- not register raises, which is what a proxy answering with HTML does.
local encoded = {}
local bodies = {}
json = {
    encode = function(tbl) encoded[#encoded + 1] = tbl; return 'JSON#' .. #encoded end,
    decode = function(s)
        local t = bodies[s]
        if t == nil then error('not json: ' .. tostring(s), 2) end
        return t
    end,
}

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

--- The mint result in the last envelope, or an empty table.
---
--- NIL-SAFE ON PURPOSE. Every interesting mutation of this feature -- a timeout
--- that stops answering, a refusal that stops sending -- makes one of these
--- links nil, and `lastSent().data.mint.error` would then abort the whole suite
--- with a traceback at the first one. A suite that dies tells you where it died;
--- a suite that fails tells you what broke, and lists the rest.
---
--- DECLARED HERE, BELOW `local http`, AND NOT BESIDE THE OTHER HELPERS. Lua
--- resolves an upvalue at COMPILE time: written above that declaration, `http`
--- inside these bodies is a global read that is nil forever, and the failure is
--- an error inside the test harness rather than in anything under test.
local function mint()
    local last = sent[#sent]
    if last == nil or type(last.data) ~= 'table' then return {} end
    return last.data.mint or {}
end

--- The last HTTP request, or an empty table. Same reasoning.
local function request()
    return http[#http] or {}
end

--- Answer the last HTTP request, if one was made.
---
--- GUARDED, because "no request was made" is the shape of several real
--- regressions -- a gate that starts refusing everybody, a config read that
--- starts coming back empty -- and a bare `lastRequest().cb(...)` turns every
--- one of them into a traceback in the harness instead of a named failure in
--- the thing that broke.
local function respond(status, body)
    local req = http[#http]
    if req == nil or type(req.cb) ~= 'function' then return false end
    req.cb(status, body)
    return true
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

-- br_ringmaster's config must be loaded with its convars already in place: it
-- reads them once, at load, exactly as it does on a real boot.
convars['br_ringmaster_ingest_url']    = 'http://10.0.7.4:3000/api/ingest'
convars['br_ringmaster_ingest_secret'] = 'CHANGEME-not-a-real-secret'

loadAll({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/identity.lua',
    'br_lib/config/admin.lua',
    'br_ringmaster/server/config.lua',
    'br_ringmaster/server/handoff.lua',
    'br_core/server/grants.lua',
    'br_core/server/admin.lua',
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

-- ------------------------------------------------------------- the world ---

local CONSOLE = 'https://ringmaster.example'

--- Put one player on the server.
--- @param src number
--- @param opts table { license, discord, scopes }
local function join(src, opts)
    connected[src] = 'Player' .. tostring(src)
    local ids = { 'license:' .. (opts.license or ('lic' .. tostring(src))) }
    if opts.discord then ids[#ids + 1] = 'discord:' .. opts.discord end
    identifiers[src] = ids
end

--- Answer the grants read that BR.Grants.holds starts as a side effect.
---
--- SPEAKING FOR br_ddb, which is not loaded: it answers `br:ddb:grantsFetch`
--- with `br:ddb:grantsResult`, and the shape of that answer -- including the
--- `error` field on every failure path -- is what grants.lua is written against.
local ddbScopes = {}      -- [license] = { 'view', ... }
local ddbError = nil
AddEventHandler('br:ddb:grantsFetch', function(req, license)
    if ddbError then
        TriggerEvent('br:ddb:grantsResult', req, {}, { error = ddbError })
        return
    end
    TriggerEvent('br:ddb:grantsResult', req, ddbScopes[license] or {}, {})
end)

--- Bring a player to the point where the server has decided about their tab.
--- Returns the envelope payload the client was sent, or nil if none was.
local function readyUp(src)
    local before = sentCount()
    fire('playerJoining', src)      -- grants.lua primes the cache here
    fire(BR.Net.READY, src)
    if sentCount() == before then return nil end
    return lastSent().data
end

local function reset()
    sent, http, timers, encoded, printed = {}, {}, {}, {}, {}
    bodies = {}
    ddbError = nil
    BR.Config.Admin.consoleUrl = CONSOLE
end

-- ------------------------------------------------------------ the origin ---

describe('origin of the ingest url')
do
    ok(BR.Ring.originOf('http://10.0.7.4:3000/api/ingest') == 'http://10.0.7.4:3000',
        'strips the path and keeps the port')
    ok(BR.Ring.originOf('https://ringmaster.example/api/ingest') == 'https://ringmaster.example',
        'https with no port')
    ok(BR.Ring.originOf('https://ringmaster.example') == 'https://ringmaster.example',
        'a bare origin is already one')
    ok(BR.Ring.originOf('https://host/a?b#c') == 'https://host',
        'a query and a fragment are not part of the origin')
    ok(BR.Ring.originOf('not a url') == nil, 'nonsense has no origin')
    ok(BR.Ring.originOf(nil) == nil, 'nil has no origin')
    ok(BR.Ring.originOf('https://') == nil, 'a scheme with no host has no origin')
end

-- --------------------------------------------------------- who gets a tab ---

describe('who is offered the tab')
do
    reset()
    ddbScopes['license:adm'] = { 'view', 'ban' }
    join(1, { license = 'adm', discord = '123456789012345678' })
    local payload = readyUp(1)

    ok(payload ~= nil, 'an admin is told something at all')
    ok(payload and payload.origin == CONSOLE,
        'an admin is sent the console origin',
        payload and tostring(payload.origin))
    ok(lastSent().event == BR.Net.ADMIN_STATE, 'on the admin state event')
    ok(lastSent().target == 1, 'to that player and not broadcast')
end

do
    reset()
    ddbScopes['license:pleb'] = {}
    join(2, { license = 'pleb', discord = '223456789012345678' })
    local payload = readyUp(2)

    ok(payload ~= nil, 'an ordinary player is answered rather than ignored')
    ok(payload and payload.origin == nil,
        'an ordinary player is NOT sent the console origin',
        payload and tostring(payload.origin))
end

do
    -- THE SCOPES ARE FLAT ON THE CONSOLE SIDE -- `ban` does not imply `view` --
    -- so a row carrying only the write scope holds no console scope. Asserted
    -- because it is the surprising half of BR.Grants.CONSOLE's argument, and
    -- because a future reader "fixing" it would silently widen the gate.
    reset()
    ddbScopes['license:banonly'] = { 'ban' }
    join(3, { license = 'banonly', discord = '323456789012345678' })
    local payload = readyUp(3)

    ok(payload and payload.origin == nil,
        'a grant of ban alone does not carry the console scope')
end

describe('the Discord id that may not exist')
do
    -- FiveM only reports a discord: identifier when that player has Discord's
    -- activity integration switched on. An admin can hold the grant and still
    -- have no id visible here, and the first open ALWAYS needs a mint -- so the
    -- tab would never once work.
    reset()
    ddbScopes['license:nodiscord'] = { 'view' }
    join(4, { license = 'nodiscord' })      -- no discord identifier at all
    local payload = readyUp(4)

    ok(payload and payload.origin == nil,
        'an admin with no discord id is not offered the tab')

    local verdict = BR.Admin.evaluate(4)
    ok(verdict.why == 'no-discord', 'and the reason says exactly why',
        tostring(verdict.why))
    ok(verdict.grant == true, 'while still recording that they ARE an admin')
end

describe('no console configured')
do
    reset()
    BR.Config.Admin.consoleUrl = ''
    ddbScopes['license:adm2'] = { 'view' }
    join(5, { license = 'adm2', discord = '523456789012345678' })
    local payload = readyUp(5)

    ok(payload and payload.origin == nil, 'nobody is offered a tab')
    ok(BR.Admin.evaluate(5).why == 'no-console', 'and the reason names the convar')
    ok(requestCount() == 0, 'and nothing is asked of Ringmaster')
end

describe('an unread grant is not a refusal')
do
    -- BR.Grants.holds answers nil for "never successfully read", which is NOT
    -- "not an admin". Sending {} on that would be a definite no derived from a
    -- read that had not finished.
    reset()
    ddbError = 'DynamoDB timeout'
    join(6, { license = 'unknown', discord = '623456789012345678' })

    local before = sentCount()
    fire('playerJoining', 6)
    fire(BR.Net.READY, 6)

    ok(sentCount() == before, 'nothing is sent while the answer is unknown')
    ok(timerCount() > 0, 'a retry is armed instead')
    ok(BR.Admin.evaluate(6).why == 'grant-unknown', 'and the reason says so')

    -- DynamoDB comes back, and the retry still needs two goes.
    --
    -- THAT IS BR.Grants.holds' CONTRACT, NOT A FLAW IN THE RETRY, and it is
    -- worth pinning because it decides RETRY_MAX. `holds` answers from the cache
    -- and starts a read as a SIDE EFFECT of a miss -- so the attempt that
    -- repairs the cache is still an attempt that answered nil. The next one
    -- reads the row. Three attempts is therefore the smallest number that can
    -- survive one failed read, not a round number.
    ddbError = nil
    ddbScopes['license:unknown'] = { 'view' }

    fireTimers()
    ok(sentCount() == before,
        'the attempt that re-opens the question still has no answer to give')

    fireTimers()
    ok(sentCount() > before, 'the one after it does')
    ok(lastSent() and lastSent().data.origin == CONSOLE,
        'and the tab appears late rather than never')
end

do
    -- ...and it gives up rather than putting a DynamoDB read on a timer for the
    -- length of a session.
    reset()
    ddbError = 'still down'
    join(7, { license = 'stilldown', discord = '723456789012345678' })
    fire('playerJoining', 7)
    fire(BR.Net.READY, 7)

    for _ = 1, 6 do fireTimers() end

    ok(timerCount() == 0, 'the retries stop')
    ok(sentCount() > 0, 'and the client is finally told there is no tab')
    ok(lastSent().data.origin == nil, 'with no origin in it')
end

-- ------------------------------------------------------- opening the tab ---

describe('the common case costs nothing')
do
    -- THE WHOLE POINT OF THE DESIGN. Opening the tab points the frame at the
    -- plain console URL; the session already in CEF's cookie jar renders it. No
    -- token is asked for unless the console says it is signed out.
    reset()
    ddbScopes['license:adm3'] = { 'view' }
    join(8, { license = 'adm3', discord = '823456789012345678' })
    readyUp(8)

    ok(requestCount() == 0,
        'deciding the tab never calls Ringmaster',
        ('%d request(s)'):format(requestCount()))
    ok(timersOf(MINT_TIMEOUT_MS) == 0,
        'and arms no mint timeout -- there is nothing to wait for')
end

-- ------------------------------------------------------------- the mint ---

--- An admin, ready, with a mint request in flight. Returns their src.
local function mintingAdmin(src, license)
    reset()
    ddbScopes['license:' .. license] = { 'view' }
    join(src, { license = license, discord = '911111111111111111' })
    readyUp(src)
    fire(BR.Net.ADMIN_MINT, src)
    return src
end

describe('mint: the request')
do
    mintingAdmin(10, 'm1')

    ok(requestCount() == 1, 'one HTTP request is made')
    local req = request()
    ok(req.url == 'http://10.0.7.4:3000/api/handoff/mint',
        'to the ingest host, on the handoff path', tostring(req.url))
    ok(req.method == 'POST', 'as a POST')
    ok((req.headers or {})['X-Ringmaster-Secret'] == 'CHANGEME-not-a-real-secret',
        'carrying the ingest secret')
    ok((bodyOf(req) or {}).discordId == '911111111111111111',
        'and the discord id the SERVER read, never one a client supplied')
    ok(timersOf(MINT_TIMEOUT_MS) == 1,
        'with exactly one three-second mint timeout armed, before the request')
end

describe('mint: success')
do
    local src = mintingAdmin(11, 'm2')
    local before = sentCount()

    bodies['{"ok":true}'] = { ok = true, url = CONSOLE .. '/api/handoff/redeem?t=abc.def' }
    respond(200, '{"ok":true}')

    ok(sentCount() > before, 'the client is answered')
    local d = (lastSent() or {}).data or {}
    ok(d.mint ~= nil, 'with a mint result')
    ok(d.mint.url == CONSOLE .. '/api/handoff/redeem?t=abc.def',
        'carrying the url the console built', d.mint and tostring(d.mint.url))
    ok(d.mint.error == nil, 'and no error')
    ok(d.origin == CONSOLE, 'and the origin still, so the tab does not vanish')
    ok(lastSent().target == src, 'sent only to the admin who asked')

    -- The token must not reach a log: a server log outlives a 90s credential.
    local leaked = false
    for _, line in ipairs(printed) do
        if line:find('abc.def', 1, true) then leaked = true end
    end
    ok(not leaked, 'and the token is never printed')
end

describe('mint: every failure the console can return')
do
    -- The codes are fivem-ringmaster's, from its mint route's own table. Each
    -- has to arrive DISTINCTLY: they have different causes and different fixes,
    -- and collapsing them into "failed" is how an afternoon gets spent on the
    -- wrong one.
    local cases = {
        { status = 401, body = '{"e":"auth"}',        err = 'auth',            why = 'wrong or absent secret' },
        { status = 403, body = '{"e":"revoked"}',     err = 'role-revoked',    why = 'discord says no' },
        { status = 403, body = '{"e":"noacct"}',      err = 'no-account',      why = 'never signed in' },
        { status = 503, body = '{"e":"unresolved"}',  err = 'role-unresolved', why = 'discord unreachable' },
        { status = 503, body = '{"e":"store"}',       err = 'store',           why = 'dynamodb' },
        { status = 429, body = '{"e":"rate"}',        err = 'rate-limited',    why = 'six a minute' },
        { status = 400, body = '{"e":"schema"}',      err = 'schema',          why = 'not a snowflake' },
        { status = 413, body = '{"e":"toolarge"}',    err = 'too-large',       why = 'over 4kb' },
    }

    for i, c in ipairs(cases) do
        mintingAdmin(20 + i, 'f' .. i)
        bodies[c.body] = { ok = false, error = c.err }
        respond(c.status, c.body)

        local d = (lastSent() or {}).data or {}
        ok(d.mint ~= nil and d.mint.error == c.err,
            ('%d %s reaches the page as "%s"'):format(c.status, c.why, c.err),
            d.mint and tostring(d.mint.error))
        ok(d.mint ~= nil and d.mint.url == nil, ('%d carries no url'):format(c.status))
    end
end

describe('mint: failures with no usable body')
do
    mintingAdmin(30, 'g1')
    respond(401, '<html>nope</html>')
    ok(mint().error == 'auth',
        'a 401 is auth even when a proxy answers in HTML',
        tostring(mint().error))

    mintingAdmin(31, 'g2')
    respond(500, '')
    ok(mint().error == 'http-500',
        'an unrecognised status names itself rather than inventing a cause',
        tostring(mint().error))

    mintingAdmin(32, 'g3')
    respond(0, '')
    ok(mint().error == 'unreachable',
        'status 0 is a connection that never happened, not a server error',
        tostring(mint().error))

    mintingAdmin(33, 'g4')
    bodies['{"ok":true}'] = { ok = true }        -- 200, but no url in it
    respond(200, '{"ok":true}')
    ok(mint().error == 'malformed-reply',
        'a 200 with no url is a failure, not a frame pointed at nil',
        tostring(mint().error))
end

describe('mint: the timeout')
do
    local src = mintingAdmin(40, 't1')
    local before = sentCount()

    fireTimers()

    ok(sentCount() > before, 'the client is answered when nothing comes back')
    ok(mint().error == 'timeout', 'with timeout',
        tostring(mint().error))
    ok(lastSent().target == src, 'to the admin who asked')

    -- AND THE LATE ANSWER IS DROPPED. A response arriving after the deadline
    -- must not overwrite a failure the page has already acted on, or the frame
    -- would jump to a console the admin has stopped looking at.
    local after = sentCount()
    bodies['{"late":true}'] = { ok = true, url = CONSOLE .. '/late' }
    respond(200, '{"late":true}')

    ok(sentCount() == after, 'and a response arriving after it is ignored')
end

describe('mint: the client is never trusted')
do
    -- The tab is only shown to people who passed the check, which is a statement
    -- about the interface. A modified client sends what it likes; this is where
    -- that stops.
    reset()
    ddbScopes['license:nobody'] = {}
    join(50, { license = 'nobody', discord = '501111111111111111' })
    readyUp(50)

    local before = requestCount()
    fire(BR.Net.ADMIN_MINT, 50)

    ok(requestCount() == before,
        'a non-admin asking for a token reaches no HTTP request at all')
    ok(mint().error == 'not-admin', 'and is refused by name',
        lastSent().data.mint and tostring(mint().error))
end

do
    reset()
    ddbScopes['license:nod'] = { 'view' }
    join(51, { license = 'nod' })       -- admin, but no discord id
    readyUp(51)

    local before = requestCount()
    fire(BR.Net.ADMIN_MINT, 51)

    ok(requestCount() == before, 'an admin with no discord id mints nothing')
    ok(mint().error == 'no-discord', 'and is told which fact is missing')
end

do
    reset()
    resourceState.br_ringmaster = 'missing'
    ddbScopes['license:norm'] = { 'view' }
    join(52, { license = 'norm', discord = '521111111111111111' })
    readyUp(52)
    fire(BR.Net.ADMIN_MINT, 52)

    ok(mint().error == 'not-configured',
        'with br_ringmaster stopped, the ask is declined rather than left hanging',
        lastSent().data.mint and tostring(mint().error))
    ok(timersOf(MINT_TIMEOUT_MS) == 0,
        'and no timer is left armed for an answer that cannot come')
    resourceState.br_ringmaster = 'started'
end

describe('a failed mint must not take the tab with it')
do
    -- THE BUG THIS PINS, and it is a one-line omission with a disproportionate
    -- symptom: the page holds ONE object for this feature, so a mint answer
    -- that carried only the result would blank `origin` -- and the Admin tab
    -- would vanish because a mint failed. The admin presses Admin, sees an
    -- error, and finds the door gone.
    local src = mintingAdmin(65, 'tr1')

    -- The console falls over mid-mint.
    bodies['{"down":true}'] = { ok = false, error = 'store' }
    respond(503, '{"down":true}')
    ok(mint().error == 'store', 'the mint fails', tostring(mint().error))
    ok(lastSent().data.origin == CONSOLE,
        'and the tab survives it',
        tostring(lastSent().data.origin))

    -- Same for a refusal decided on this side rather than by the console, and
    -- for the timeout -- every path out of `answer`, not just the console's.
    fire(BR.Net.ADMIN_MINT, src)
    fireTimers()
    ok(mint().error == 'timeout', 'a timeout is a failure too', tostring(mint().error))
    ok(lastSent().data.origin == CONSOLE,
        'and the tab survives that as well',
        tostring(lastSent().data.origin))
end

describe('a grant read as genuinely gone does take the tab')
do
    -- The other side of the same coin, and the reason the origin is re-derived
    -- on each answer rather than remembered from the offer. `holds` serves a
    -- STALE answer while refreshing and never expires one into nil
    -- (server/grants.lua), so this cannot fire on a blip -- only on a row that
    -- was read and genuinely does not carry the scope.
    local src = mintingAdmin(66, 'tr2')
    respond(0, '')
    ok(lastSent().data.origin == CONSOLE, 'still an admin here')

    ddbScopes['license:tr2'] = {}          -- the grant is revoked for real
    fakeTime = fakeTime + (6 * 60 * 1000)  -- and the cached answer goes stale
    fire(BR.Net.ADMIN_MINT, src)           -- refreshes, still serves stale: ok
    fire(BR.Net.ADMIN_MINT, src)           -- now reads the new, empty row

    ok(mint().error == 'not-admin', 'the mint is refused', tostring(mint().error))
    ok(lastSent().data.origin == nil,
        'and the tab goes with it rather than waiting for a reconnect',
        tostring(lastSent().data.origin))
end

describe('mint: answers are sequenced')
do
    -- The page holds one object for this feature and has to tell a fresh answer
    -- from a re-render. Two mints in a row must not look identical.
    local src = mintingAdmin(60, 's1')
    bodies['{"a":1}'] = { ok = true, url = CONSOLE .. '/a' }
    respond(200, '{"a":1}')
    local first = lastSent().data.mint.seq

    fire(BR.Net.ADMIN_MINT, src)
    bodies['{"b":2}'] = { ok = true, url = CONSOLE .. '/b' }
    respond(200, '{"b":2}')
    local second = lastSent().data.mint.seq

    ok(type(first) == 'number' and type(second) == 'number', 'the seq is a number')
    ok(second > first, 'and it advances', ('%s then %s'):format(tostring(first), tostring(second)))
end

describe('leaving cleans up')
do
    local src = mintingAdmin(70, 'd1')
    -- playerDropped delivers `source` as a STRING while the net event delivered
    -- a NUMBER, and in Lua those are different table keys. This is the exact bug
    -- br_ringmaster/server/main.lua shipped twice.
    fire('playerDropped', tostring(src))

    local before = sentCount()
    bodies['{"z":1}'] = { ok = true, url = CONSOLE .. '/z' }
    respond(200, '{"z":1}')

    ok(sentCount() == before,
        'an answer for a player who has gone is not sent to their old id')
end

describe('bradmin')
do
    ok(commands['bradmin'] ~= nil, 'the diagnostic command is registered')
    ok(commands['bradmin'] and commands['bradmin'].restricted == true,
        'and is restricted -- it names who holds admin scope')

    reset()
    ddbScopes['license:seen'] = { 'view' }
    join(80, { license = 'seen' })      -- admin, no discord id
    readyUp(80)
    printed = {}
    commands['bradmin'].fn()

    local said = table.concat(printed, '\n')
    ok(said:find('activity integration', 1, true) ~= nil,
        'and it names the reason a legitimate admin has no tab',
        said)
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
