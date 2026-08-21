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

--- The tab's retry interval. br_core/server/admin.lua's RETRY_MS.
---
--- SPELLED OUT HERE RATHER THAN IMPORTED, like MINT_TIMEOUT_MS above, because
--- these are file-locals on the other side and a test that could read them could
--- not tell a deliberate change from an accidental one. This number is the whole
--- subject of the timing block at the bottom: it is what a DynamoDB read costs
--- an admin when it lands one millisecond after br:ready.
local RETRY_MS = 5000

--- The connect-time warm's interval. br_core/server/admin.lua's WARM_MS.
local WARM_MS = 500

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

--- How long DynamoDB takes to answer, in milliseconds. ZERO EVERYWHERE BUT THE
--- TIMING BLOCK, where it is the independent variable.
---
--- Zero still is not instant, and that is the contract rather than the stub
--- being lazy: `BR.Grants.holds` returns nil and STARTS the read, so the ask
--- that repairs the cache is never the ask that gets an answer. Every caller in
--- this project has to come back and look again, which is what both ladders in
--- admin.lua exist to do.
local ddbDelayMs = 0

AddEventHandler('br:ddb:grantsFetch', function(req, license)
    local reply = function()
        if ddbError then
            TriggerEvent('br:ddb:grantsResult', req, {}, { error = ddbError })
            return
        end
        TriggerEvent('br:ddb:grantsResult', req, ddbScopes[license] or {}, {})
    end
    if ddbDelayMs > 0 then SetTimeout(ddbDelayMs, reply) else reply() end
end)

--- Bring a player to the point where the server has decided about their tab.
--- Returns the envelope payload the client was sent, or nil if none was.
---
--- IT WALKS THE REAL CONNECT ORDER -- connecting, joining, ready -- because
--- br_core/server/admin.lua now decides the tab on the FIRST of those and the
--- other two only find out. A helper that skipped straight to `playerJoining`
--- would be testing a connection that cannot happen, and every assertion below
--- about the common case would be measuring the fallback path instead.
---
--- ONE fireTimers() BETWEEN CONNECT AND JOIN, and it stands in for the whole
--- resource download: it is where the warm ladder's first rung lands and where
--- the answer that `holds` started is finally collected. On the real server that
--- gap is seconds; here it is one rung, because one rung is all the stub needs.
---
--- LICENSES MUST BE UNIQUE PER BLOCK. `reset()` cannot reach admin.lua's
--- connect-time table -- it is a file-local -- so a license reused after a reset
--- would carry the previous block's decision into the next one. Every block here
--- names its own.
local function readyUp(src)
    local before = sentCount()
    fire('playerConnecting', src)   -- admin.lua warms the grant here
    fireTimers()
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

-- ------------------------------------------------ the connect-time warm ---

describe('the warm never delays a connection')
do
    -- THE ONE WAY THIS CHANGE COULD BE WORSE THAN THE BUG IT FIXES.
    -- `playerConnecting` is the event that can DEFER a join: a handler that
    -- called deferrals.defer() and then waited on DynamoDB would hold every
    -- player on "connecting" for as long as the read took, and hold them
    -- forever if it never answered. An admin convenience would have become an
    -- outage for everybody.
    reset()
    ddbScopes['license:warmDefer'] = { 'view' }
    join(90, { license = 'warmDefer', discord = '901111111111111111' })

    local touched = {}
    local deferrals = {
        defer       = function() touched[#touched + 1] = 'defer' end,
        update      = function() touched[#touched + 1] = 'update' end,
        done        = function() touched[#touched + 1] = 'done' end,
        presentCard = function() touched[#touched + 1] = 'presentCard' end,
    }
    local kicked = false
    local askedBefore = BR.Grants.stats().asked

    fire('playerConnecting', 90, 'Player90',
        function() kicked = true end, deferrals)

    ok(#touched == 0, 'no method on the deferrals object is called',
        table.concat(touched, ','))
    ok(kicked == false, 'and nobody is refused a connection')
    ok(requestCount() == 0, 'and Ringmaster is not consulted either')
    ok(BR.Grants.stats().asked > askedBefore,
        'while the grants read has nonetheless started',
        ('%d -> %d'):format(askedBefore, BR.Grants.stats().asked))
end

describe('the tab is decided before the client asks for it')
do
    reset()
    ddbScopes['license:warmAdmin'] = { 'view' }
    join(91, { license = 'warmAdmin', discord = '911111111111111112' })

    fire('playerConnecting', 91)
    fireTimers()                       -- the read answers during the download
    fire('playerJoining', 91)

    local before = sentCount()
    fire(BR.Net.READY, 91)

    ok(sentCount() == before + 1,
        'the envelope goes out on the same tick as br:ready')
    ok(lastSent().data.origin == CONSOLE,
        'carrying the origin', tostring(lastSent().data.origin))
    ok(timersOf(RETRY_MS) == 0,
        'and no retry is armed, because nothing was unknown',
        ('%d armed'):format(timersOf(RETRY_MS)))
end

do
    -- THE ORDINARY PLAYER IS THE MUTATION TARGET, not the admin. A cache written
    -- or read with `if grant then` instead of `grant ~= nil` looks perfect for
    -- everyone who holds the scope and sends nearly everybody else back down the
    -- slow path -- and nothing about the tab would look wrong, because they were
    -- never getting one.
    reset()
    ddbScopes['license:warmPleb'] = {}
    join(92, { license = 'warmPleb', discord = '921111111111111111' })

    fire('playerConnecting', 92)
    fireTimers()
    fire('playerJoining', 92)

    local before = sentCount()
    fire(BR.Net.READY, 92)

    ok(sentCount() == before + 1, 'an ordinary player is answered immediately too')
    ok(lastSent().data.origin == nil, 'with no origin')
    ok(timersOf(RETRY_MS) == 0, 'and no retry armed for them either')
    ok(BR.Admin.tabVerdict(92).why == 'not-admin-at-connect',
        'and the reason names the connect-time answer rather than a live one',
        tostring(BR.Admin.tabVerdict(92).why))
    ok(BR.Admin.tabVerdict(92).cached == true, 'and says it was cached')
end

describe('a read that never answered is not a refusal')
do
    -- THE SAFETY PROPERTY, AND THE ONLY ONE THAT COULD SILENTLY DENY A REAL
    -- ADMIN. BR.Grants.holds answers nil for "never successfully read", which is
    -- NOT "not an admin" -- and a warm that wrote nil down as false would file a
    -- DynamoDB outage as a fact about a person, for the length of their session,
    -- with a `bradmin` line that agreed with it.
    reset()
    ddbError = 'DynamoDB timeout'
    join(93, { license = 'warmDown', discord = '931111111111111111' })

    -- DELTAS, NOT ABSOLUTES, on both counters. Ladders from earlier blocks are
    -- still recorded -- `reset()` cannot reach admin.lua's file-locals, and
    -- their timers were thrown away with the rest -- so an absolute count here
    -- would be reporting on this suite's history rather than on this block.
    local climbing = BR.Admin.stats().warming
    local gaveUp   = BR.Admin.stats().gaveUp

    fire('playerConnecting', 93)
    ok(BR.Admin.stats().warming == climbing + 1, 'a ladder starts')

    for _ = 1, 20 do fireTimers() end      -- and climbs to its last rung

    ok(BR.Admin.stats().warming == climbing,
        'then gives up rather than climbing forever')
    ok(BR.Admin.stats().gaveUp == gaveUp + 1, 'and says so')
    ok(BR.Admin.tabVerdict(93).why == 'grant-unknown',
        'and the answer is still UNKNOWN, not "not an admin"',
        tostring(BR.Admin.tabVerdict(93).why))
    ok(BR.Admin.tabVerdict(93).cached == false,
        'because nothing was written down at all')

    fire('playerJoining', 93)
    -- COUNTED EITHER SIDE OF br:ready RATHER THAN AFTER IT. server/grants.lua
    -- arms its own 5s deadline every time a read starts, and RETRY_MS is 5s too
    -- -- so `timersOf(RETRY_MS)` cannot tell one file's timer from the other's,
    -- and only the change across this one event belongs to `offer`.
    local armed  = timersOf(RETRY_MS)
    local before = sentCount()
    fire(BR.Net.READY, 93)

    ok(sentCount() == before, 'nothing is sent, exactly as before the warm existed')
    ok(timersOf(RETRY_MS) > armed, 'and the existing retry ladder is armed instead',
        ('%d -> %d'):format(armed, timersOf(RETRY_MS)))

    -- DynamoDB comes back while they are in the world. The retry still needs two
    -- goes -- see the note on RETRY_MAX -- but it gets there.
    ddbError = nil
    ddbScopes['license:warmDown'] = { 'view' }
    fireTimers()
    fireTimers()

    ok(lastSent() and lastSent().data.origin == CONSOLE,
        'and an admin the warm could not decide still gets their tab',
        lastSent() and tostring(lastSent().data.origin))
end

describe('relaunching is what re-decides it')
do
    -- THE OWNER'S OWN REMEDY, PINNED. "For the case of not having the role when
    -- joining the game and then receiving admin perms, we'll simply make them
    -- relaunch the game." That sentence is only true if the drop forgets the
    -- decision, and nothing else in this suite would notice if it stopped.
    reset()
    ddbScopes['license:warmLate'] = {}
    join(94, { license = 'warmLate', discord = '941111111111111111' })
    readyUp(94)

    ok(lastSent().data.origin == nil, 'not an admin at connect, so no tab')

    -- The grant is added while they are in the world, and the live cache goes
    -- stale so a live read would pick it up.
    ddbScopes['license:warmLate'] = { 'view' }
    fakeTime = fakeTime + (6 * 60 * 1000)
    fire(BR.Net.READY, 94)

    ok(lastSent().data.origin == nil,
        'a grant added mid-session does not conjure the tab',
        tostring(lastSent().data.origin))
    ok(BR.Admin.tabVerdict(94).why == 'not-admin-at-connect',
        'and the reason tells the admin what to do about it',
        tostring(BR.Admin.tabVerdict(94).why))

    -- AND AGAIN, NOW THAT THE LIVE ROW HAS ACTUALLY BEEN RE-READ. This second
    -- ask is the only one that can tell the two verdicts apart, and without it
    -- the whole point of the change goes untested: `holds` SERVES A STALE ANSWER
    -- while it refreshes, so the ask above returns `false` whichever function
    -- `offer` calls. The one after it returns `true` live -- so an `offer` that
    -- had been left asking `evaluate` would hand out the origin here, and every
    -- other assertion in this suite would still pass.
    fire(BR.Net.READY, 94)
    ok(lastSent().data.origin == nil,
        'not even once DynamoDB has confirmed the new grant',
        tostring(lastSent().data.origin))
    -- TWICE, AND NOT AS ONE EXPRESSION. `holds` serves the stale row and starts
    -- the re-read on the same ask, so the first call is the one that repairs the
    -- cache and the second is the one with an answer in it. Written as
    -- `evaluate(94).grant == true` with the detail argument alongside it, the
    -- two calls straddle that repair and the assertion reports on itself.
    BR.Admin.evaluate(94)
    local live = BR.Admin.evaluate(94)
    ok(live.grant == true,
        'while a live read plainly says they hold the scope now',
        tostring(live.grant))

    -- They relaunch. `playerDropped` delivers `source` as a STRING while the
    -- connect delivered a NUMBER, and in Lua those are different table keys --
    -- the bug br_ringmaster/server/main.lua shipped twice.
    local keptBefore = BR.Admin.stats().decided
    fire('playerDropped', tostring(94))
    ok(BR.Admin.stats().decided == keptBefore - 1,
        'the drop forgets the decision, string source and all',
        ('%d -> %d'):format(keptBefore, BR.Admin.stats().decided))

    -- THE SAME EVENT AGAIN, AS A NUMBER, AND IT IS A PROP RATHER THAN A SECOND
    -- ASSERTION. On a real server one `playerDropped` frees both tables:
    -- server/grants.lua's row and admin.lua's decision. Here grants.lua reads
    -- identifiers back out of the harness, whose fixture is keyed by number, so
    -- it needs the number spelling to let go -- and the relaunch below is only
    -- honest if its cache is genuinely cold. admin.lua's own handler is already
    -- past its guard and does nothing the second time.
    fire('playerDropped', 94)

    readyUp(94)
    ok(lastSent().data.origin == CONSOLE,
        'and the relaunch the owner promised actually works',
        tostring(lastSent().data.origin))
end

describe('the temporary connect id is re-keyed onto the real one')
do
    -- `playerConnecting` hands out a TEMPORARY source id; `playerDropped`
    -- arrives with the real one. Without the handoff at `playerJoining` the
    -- decision is filed under a number that never appears again, every eviction
    -- quietly does nothing, and the owner's "relaunch the game" stops working
    -- for everybody -- with no symptom until somebody says so out loud.
    --
    -- THIS IS THE BUG br_ringmaster/server/main.lua SHIPPED, in a second file:
    -- "the emitter, the event kind, the console handler and the key type were
    -- all correct. The key VALUE was wrong."
    --
    -- Every other block here connects and joins under one id, because that is
    -- all they need; this one is the only place the two numbers differ, so it is
    -- the only place the handoff can be seen at all.
    reset()
    ddbScopes['license:warmTemp'] = {}
    local TEMP, REAL = 65535, 98
    join(TEMP, { license = 'warmTemp', discord = '981111111111111111' })
    join(REAL, { license = 'warmTemp', discord = '981111111111111111' })

    fire('playerConnecting', TEMP)
    fireTimers()

    ok(BR.Admin.tabVerdict(REAL).why == 'not-admin-at-connect',
        'the connect-time answer follows the license, not the id it arrived on',
        tostring(BR.Admin.tabVerdict(REAL).why))

    fire('playerJoining', REAL, TEMP)

    local kept = BR.Admin.stats().decided
    fire('playerDropped', tostring(REAL))
    ok(BR.Admin.stats().decided == kept - 1,
        'and a drop on the REAL id still finds it',
        ('%d -> %d'):format(kept, BR.Admin.stats().decided))
end

describe('a ladder stops when the player gives up on the connection')
do
    -- A ladder climbing for somebody who has gone is not merely wasted: `holds`
    -- STARTS a DynamoDB read as a side effect of being asked, so it would refill
    -- server/grants.lua's cache one row after that file freed it -- on a timer,
    -- per abandoned connection.
    reset()
    ddbError = 'still down'
    join(95, { license = 'warmGone', discord = '951111111111111111' })

    local climbing = BR.Admin.stats().warming

    fire('playerConnecting', 95)
    ok(BR.Admin.stats().warming == climbing + 1, 'a ladder is climbing')

    fire('playerDropped', tostring(95))
    ok(BR.Admin.stats().warming == climbing, 'and the drop stops it')

    local askedBefore = BR.Grants.stats().asked
    for _ = 1, 20 do fireTimers() end
    ok(BR.Grants.stats().asked == askedBefore,
        'no further DynamoDB read is started for a license nobody is holding',
        ('%d -> %d'):format(askedBefore, BR.Grants.stats().asked))
end

describe('the mint still asks DynamoDB, not the cache')
do
    -- THE HALF OF THIS FILE THAT MUST NOT BE MADE FASTER. The tab is a door and
    -- may be drawn from a frozen answer; the mint hands out a CREDENTIAL and may
    -- not. A `tabVerdict` here would keep minting for an admin whose grant row
    -- had been emptied, until they happened to reconnect.
    reset()
    ddbScopes['license:warmRevoked'] = { 'view' }
    join(96, { license = 'warmRevoked', discord = '961111111111111111' })
    readyUp(96)
    ok(lastSent().data.origin == CONSOLE, 'the tab is drawn from the connect answer')

    ddbScopes['license:warmRevoked'] = {}       -- revoked for real
    fakeTime = fakeTime + (6 * 60 * 1000)
    fire(BR.Net.ADMIN_MINT, 96)                 -- refreshes, still serves stale
    fire(BR.Net.ADMIN_MINT, 96)                 -- now reads the new, empty row

    ok(mint().error == 'not-admin',
        'a revoked grant is refused a token even though connect said otherwise',
        tostring(mint().error))
    ok(lastSent().data.origin == nil,
        'and the door goes with it', tostring(lastSent().data.origin))
end

describe('bradmin names the connect-time answer')
do
    reset()
    ddbScopes['license:warmSaid'] = {}
    join(97, { license = 'warmSaid', discord = '971111111111111111' })
    readyUp(97)

    printed = {}
    commands['bradmin'].fn()
    local said = table.concat(printed, '\n')

    ok(said:find('they must relaunch', 1, true) ~= nil,
        'the diagnostic tells them the fix is a relaunch, not a grants edit',
        said)
    ok(said:find('connect%-time answers %d') ~= nil,
        'and the warm reports how many answers it collected')
end

-- ---------------------------------------------------------------- timing ---

describe('timing: what the first pause menu waits for')
do
    -- THIS BLOCK MEASURES RATHER THAN DESCRIBES, and the number it produces is
    -- the only reason the warm exists.
    --
    -- THE BUG WAS NEVER THE ROUND TRIP. server/grants.lua asked DynamoDB at
    -- `playerJoining` and admin.lua decided the tab at `br:ready`, so the read's
    -- entire budget was the gap between those two -- the tail of a connection,
    -- a few hundred milliseconds. Land outside it and `holds` answers nil,
    -- nothing is sent, and the next look is RETRY_MS later. A 900ms read
    -- therefore cost five seconds, not 900ms.
    --
    -- A CLOCK THAT ACTUALLY ADVANCES, for this block only. `fireTimers()`
    -- everywhere above fires every armed timer at once, which is exactly right
    -- for asking WHETHER something happens and useless for asking WHEN.
    local realSetTimeout = SetTimeout
    local due = {}
    SetTimeout = function(ms, fn) due[#due + 1] = { at = fakeTime + ms, fn = fn } end

    --- Walk the clock forward, firing what falls due, in due order.
    local function advance(ms)
        local target = fakeTime + ms
        while true do
            local soonest, idx = nil, nil
            for i, t in ipairs(due) do
                if t.at <= target and (soonest == nil or t.at < soonest.at) then
                    soonest, idx = t, i
                end
            end
            if soonest == nil then break end
            table.remove(due, idx)
            fakeTime = soonest.at
            soonest.fn()
        end
        fakeTime = target
    end

    --- The next armed deadline, or nil.
    local function nextDue()
        local soonest = nil
        for _, t in ipairs(due) do
            if soonest == nil or t.at < soonest then soonest = t.at end
        end
        return soonest
    end

    -- The connection this models. The two gaps are what the read has to land in.
    local DOWNLOAD_MS = 9000    -- playerConnecting -> playerJoining
    local BOOT_MS     = 400     -- playerJoining -> br:ready

    --- Run one whole connection and return the milliseconds between `br:ready`
    --- and the envelope that carries the console origin. nil if it never came.
    --- @param src number
    --- @param license string
    --- @param warm boolean   whether admin.lua gets its playerConnecting
    --- @param ddbMs number   how long DynamoDB takes to answer
    local function waitAfterReady(src, license, warm, ddbMs)
        reset()
        due = {}
        ddbDelayMs = ddbMs
        ddbScopes['license:' .. license] = { 'view' }
        join(src, { license = license, discord = '999999999999999999' })

        if warm then fire('playerConnecting', src) end
        advance(DOWNLOAD_MS)
        fire('playerJoining', src)
        advance(BOOT_MS)

        local readyAt = fakeTime
        local before = sentCount()
        fire(BR.Net.READY, src)

        while sentCount() == before and (fakeTime - readyAt) < 60000 do
            local soonest = nextDue()
            if soonest == nil then break end
            advance(math.max(soonest - fakeTime, 1))
        end

        if sentCount() == before then return nil end
        if lastSent().data.origin == nil then return nil end
        return fakeTime - readyAt
    end

    local slowBefore = waitAfterReady(100, 'tFastNoWarm', false, 900)
    local slowAfter  = waitAfterReady(101, 'tFastWarm',   true,  900)
    local fastBefore = waitAfterReady(102, 'tSlowNoWarm', false, 150)
    local fastAfter  = waitAfterReady(103, 'tSlowWarm',   true,  150)

    ok(slowBefore ~= nil and slowBefore >= RETRY_MS,
        'a 900ms read used to cost the retry interval, not 900ms',
        tostring(slowBefore))
    ok(slowAfter == 0,
        'and now costs nothing, because it landed during the download',
        tostring(slowAfter))
    ok(fastBefore == 0, 'a 150ms read always did fit in the boot gap',
        tostring(fastBefore))
    ok(fastAfter == 0, 'and still does', tostring(fastAfter))

    -- THE BUDGET IS THE STORY, more than any one latency: the read used to have
    -- the boot gap and now has the whole download as well.
    realPrint(('       first tab after br:ready -- 900ms read: %sms -> %sms;' ..
               ' 150ms read: %sms -> %sms  (budget %dms -> %dms)')
        :format(tostring(slowBefore), tostring(slowAfter),
                tostring(fastBefore), tostring(fastAfter),
                BOOT_MS, DOWNLOAD_MS + BOOT_MS))

    ddbDelayMs = 0
    SetTimeout = realSetTimeout
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
