-- Unit tests for the Discord guild-membership lookup (owner, 2026-08-31).
--
-- WHY THIS IS A SUITE AND NOT A PLAYTEST. Every interesting case here is either
-- unobservable in the game or ruinously expensive to stage:
--
--   * "a 404 that means the BOT cannot see the guild is not a player who is not
--     a member" needs a deliberately wrong guild id and a second Discord server
--     to prove the difference -- and getting it wrong takes the card away from
--     EVERY player at once, which looks exactly like the feature working.
--   * "one lookup per connection, even when the lookup failed" needs somebody to
--     watch Discord's traffic while a player restarts br_ui three times.
--   * "sixty players connecting do not all call Discord in the same second"
--     needs sixty players.
--   * "a 429 stands the queue down for the interval Discord named" needs Discord
--     to rate-limit us on purpose, which is the one thing this file exists to
--     avoid ever finding out about.
--
-- THE POLARITY IS THE WHOLE SUBJECT. `member` has three values and only one of
-- them hides anything; every mistake available here collapses two of them, and
-- the collapse is invisible until a player who is not in the Discord stops being
-- invited to it. So `nil` is asserted apart from `false` in every branch, and
-- `ok(x == nil)` is written rather than `ok(not x)` throughout -- the second
-- passes for both and would make half this file vacuous.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_guild.lua

-- --------------------------------------------------------------- harness ---

local convars = {}
function GetConvar(name, default)
    local v = convars[name]
    if v == nil then return default end
    return v
end

function IsDuplicityVersion() return true end
function GetCurrentResourceName() return 'br_core' end

local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function RegisterNetEvent() end
function TriggerClientEvent() end

local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

-- --- the clock -------------------------------------------------------------
--
-- STEPPED BY HAND, because the pacing IS the behaviour. A no-op SetTimeout would
-- make "the second lookup waits for the gap" and "a 429 stands the queue down"
-- both vacuously true -- the timers would simply never fire and the queue would
-- look stalled in exactly the same way as one that is working. tools/
-- test_lobbyseq.lua models Citizen for the same reason.

local clock = 0
local timers = {}

function GetGameTimer() return clock end
function SetTimeout(ms, fn)
    timers[#timers + 1] = { at = clock + (tonumber(ms) or 0), fn = fn }
end
Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = SetTimeout }

--- Run every timer due within `ms`, in time order, including ones armed by the
--- callbacks that run. Re-scanned each pass on purpose: `lookup` arms its next
--- drain from inside a timer, and a single sorted sweep would miss it.
local function advance(ms)
    local target = clock + (ms or 0)
    while true do
        local bestI, bestAt
        for i = 1, #timers do
            local t = timers[i]
            if t.at <= target and (bestAt == nil or t.at < bestAt) then
                bestI, bestAt = i, t.at
            end
        end
        if bestI == nil then break end
        local t = table.remove(timers, bestI)
        clock = t.at
        t.fn()
    end
    clock = target
end

-- --- identifiers -----------------------------------------------------------

local idents = {}
function GetNumPlayerIdentifiers(src)
    return #(idents[tonumber(src) or src] or {})
end
function GetPlayerIdentifier(src, i)
    local list = idents[tonumber(src) or src] or {}
    return list[i + 1]
end

-- --- the network -----------------------------------------------------------

local http = {}
function PerformHttpRequest(url, cb, method, data, headers)
    http[#http + 1] = { url = url, cb = cb, method = method, data = data, headers = headers }
end

--- Answer request `i`. Returns nothing; the callback does the work.
local function respond(i, status, body)
    local r = http[i]
    if r == nil then return false end
    r.cb(status, body, {})
    return true
end

-- --- json ------------------------------------------------------------------
--
-- A LOOKUP TABLE RATHER THAN A PARSER, so this suite tests guild.lua and not a
-- JSON decoder written for the occasion. A body string that is not registered
-- below is the "Discord answered with something we cannot read" case -- an HTML
-- error page from Cloudflare is the realistic one -- and it reaches the pcall in
-- guild.lua exactly as a real parse failure would.

local BODIES = {}
json = {
    decode = function(s)
        local t = BODIES[s]
        if t == nil then error('unparseable body') end
        return t
    end,
}

local function body(name, tbl)
    BODIES[name] = tbl
    return name
end

local B_NOT_MEMBER  = body('{"code":10007}', { code = 10007, message = 'Unknown Member' })
local B_UNKNOWN_GLD = body('{"code":10004}', { code = 10004, message = 'Unknown Guild' })
local B_NO_CODE     = body('{"message":"404: Not Found"}', { message = '404: Not Found' })
local B_HTML        = '<html>cloudflare</html>'          -- deliberately unregistered
local B_NOT_A_TABLE = body('12', 12)                     -- decodes to a number
local B_RETRY_1_5   = body('{"retry_after":1.5}', { retry_after = 1.5 })
local B_RETRY_STR   = body('{"retry_after":"0.25"}', { retry_after = '0.25' })
local B_RETRY_ZERO  = body('{"retry_after":0}', { retry_after = 0 })
local B_RETRY_NEG   = body('{"retry_after":-3}', { retry_after = -3 })
local B_RETRY_HUGE  = body('{"retry_after":9999}', { retry_after = 9999 })

local realPrint = print
function print() end

local ROOT = 'resources/[fivem-royale]/'

-- A PLACEHOLDER-SHAPED FIXTURE, NOT A TOKEN-SHAPED ONE. tools/check_secrets.sh
-- scans this file like any other, and a realistic three-segment value here would
-- be one regex away from a red build for no benefit -- nothing under test parses
-- the token, it only goes into a header. See the same note in test_community.lua,
-- where a realistic one WAS caught.
local TOKEN = 'EXAMPLE.not-a-real.bot-token'
local GUILD = '905311830203392042'
local SNOW  = '280000000000000000'

--- Load the module into a FRESH sandbox with these convars in place.
---
--- CONVARS BEFORE THE LOAD, because guild.lua reads them ONCE at load -- the same
--- arrangement br_ringmaster/server/config.lua has, and the reason its boot line
--- cannot disagree with its behaviour. A suite that set them afterwards would be
--- testing a file that does not exist.
local function boot(cvs)
    convars = {}
    for k, v in pairs(cvs or {}) do convars[k] = v end
    handlers, http, timers, idents = {}, {}, {}, {}
    clock = 0

    local env = setmetatable({}, { __index = _G })
    for _, f in ipairs({
        'br_lib/shared/identity.lua',
        'br_core/server/guild.lua',
    }) do
        local chunk, err = loadfile(ROOT .. f, 't', env)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            os.exit(1)
        end
        local good, e = pcall(chunk)
        if not good then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(e))
            os.exit(1)
        end
    end
    return env
end

--- A configured sandbox with one player who has a Discord identifier.
local function bootReady(src)
    local env = boot({ br_discord_bot_token = TOKEN, br_discord_guild_id = GUILD })
    idents[src or 5] = { 'license:abc123', 'discord:' .. SNOW }
    return env
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

-- ------------------------------------------------------- reading an answer ---

describe('guild.answer')
do
    local env = boot({})
    local read = env.BR.Guild.readAnswer

    ok(read(200, '') == true, 'a 200 is a member', tostring(read(200, '')))
    -- The status alone decides a yes. Nothing parses a success body, so nothing
    -- can be confused by one -- including one that is not JSON at all.
    ok(read(200, B_HTML) == true, 'and a 200 with an unreadable body still is',
        tostring(read(200, B_HTML)))

    ok(read(404, B_NOT_MEMBER) == false, '404 + code 10007 is a definite NOT a member',
        tostring(read(404, B_NOT_MEMBER)))

    -- THE ASSERTION THIS WHOLE FILE EXISTS FOR. 10004 is "this bot cannot see
    -- that guild" -- a mistyped br_discord_guild_id, or a bot removed from the
    -- server -- and reading it as 10007 would report every player on the server
    -- as a non-member... which, inverted through community.lua, is the case that
    -- leaves the card up for everybody. The dangerous direction is the OTHER
    -- one, and it is why a 200 is the only thing that ever returns true.
    ok(read(404, B_UNKNOWN_GLD) == nil, '404 + code 10004 is about US, not the player',
        tostring(read(404, B_UNKNOWN_GLD)))
    ok(read(404, B_NO_CODE) == nil, '404 with no code at all is unknown',
        tostring(read(404, B_NO_CODE)))
    ok(read(404, B_HTML) == nil, '404 with an unparseable body is unknown',
        tostring(read(404, B_HTML)))
    ok(read(404, B_NOT_A_TABLE) == nil, '404 whose body decodes to a non-table is unknown',
        tostring(read(404, B_NOT_A_TABLE)))
    ok(read(404, nil) == nil, '404 with no body is unknown', tostring(read(404, nil)))

    for _, status in ipairs({ 401, 403, 429, 500, 502, 0, -1 }) do
        ok(read(status, '') == nil, ('%d is unknown, never a denial'):format(status),
            tostring(read(status, '')))
    end
    ok(read(nil, nil) == nil, 'and so is no status at all', tostring(read(nil, nil)))
end

-- ------------------------------------------------------------- the backoff ---

describe('guild.backoff')
do
    local env = boot({})
    local back = env.BR.Guild.backoffMs

    ok(back(nil) == 5000, 'no body falls back to 5s', tostring(back(nil)))
    ok(back(B_HTML) == 5000, 'and so does an unparseable one', tostring(back(B_HTML)))

    -- `retry_after` IS SECONDS AND MAY BE FRACTIONAL. Reading it as milliseconds
    -- turns a 1.5s bucket reset into a 1.5ms one, which is a tight loop of 429s
    -- against an API that bans an IP for ten thousand of them in ten minutes.
    ok(back(B_RETRY_1_5) == 1500, '1.5 seconds becomes 1500ms', tostring(back(B_RETRY_1_5)))
    ok(back(B_RETRY_STR) == 250, 'a stringified number is still a number',
        tostring(back(B_RETRY_STR)))

    ok(back(B_RETRY_ZERO) == 5000, 'zero is not an interval', tostring(back(B_RETRY_ZERO)))
    ok(back(B_RETRY_NEG) == 5000, 'and neither is a negative one', tostring(back(B_RETRY_NEG)))

    -- A CEILING ON SOMEBODY ELSE'S NUMBER. Nothing in a response body may park
    -- this queue for the life of the process.
    ok(back(B_RETRY_HUGE) == 60000, 'a huge retry_after is clamped to a minute',
        tostring(back(B_RETRY_HUGE)))
end

-- ------------------------------------------------------------ unconfigured ---

describe('guild.unconfigured')
do
    -- THE OUT-OF-THE-BOX SERVER, AND THE DEFAULT THIS FEATURE SHIPS ON. The owner
    -- may not set a token for weeks; until he does the whole thing must be inert
    -- and every player must keep seeing the card.
    local env = boot({})
    idents[5] = { 'discord:' .. SNOW }

    ok(env.BR.Guild.configured() == false, 'no convars means not configured',
        tostring(env.BR.Guild.configured()))

    local called, got = false, 'untouched'
    env.BR.Guild.ask(5, function(m) called = true; got = m end)
    advance(60000)

    ok(#http == 0, 'nothing is asked of Discord', tostring(#http))
    ok(env.BR.Guild.member(5) == nil, 'and nothing is known about anybody',
        tostring(env.BR.Guild.member(5)))
    ok(called == false, 'the caller is not called back either', tostring(called))
    ok(got == 'untouched', 'so it cannot mistake a callback for an answer', tostring(got))
end

describe('guild.halfconfigured')
do
    -- NEITHER HALF IS USEFUL ALONE, so both spell "off" rather than one of them
    -- producing an authenticated request with no guild or a guild with no
    -- credential -- a retry loop rather than a configuration.
    local tokenOnly = boot({ br_discord_bot_token = TOKEN })
    ok(tokenOnly.BR.Guild.configured() == false, 'a token with no guild id is off',
        tostring(tokenOnly.BR.Guild.configured()))

    local guildOnly = boot({ br_discord_guild_id = GUILD })
    ok(guildOnly.BR.Guild.configured() == false, 'a guild id with no token is off',
        tostring(guildOnly.BR.Guild.configured()))
end

describe('guild.badguild')
do
    -- A SNOWFLAKE IS DIGITS. This is the guard that keeps anything that is not a
    -- run of digits out of the request path, which is what makes escaping
    -- unnecessary rather than merely unlikely to matter.
    for _, bad in ipairs({ 'not-a-snowflake', '123abc', '../../x', '9053118 30203392042',
                           '12345678901234567890123456789012345' }) do
        local env = boot({ br_discord_bot_token = TOKEN, br_discord_guild_id = bad })
        ok(env.BR.Guild.configured() == false,
            ('%q is refused as a guild id'):format(bad),
            tostring(env.BR.Guild.configured()))
    end

    -- AND SET-BUT-UNUSABLE IS ITS OWN BOOT LINE, because the operator believes
    -- this is on. Silence there is the expensive outcome.
    local env = boot({ br_discord_bot_token = TOKEN, br_discord_guild_id = 'nope' })
    local lines, healthy = env.BR.Guild.report()
    ok(healthy == false, 'and reports unhealthy', tostring(healthy))
    ok(table.concat(lines, '\n'):find('not a snowflake', 1, true) ~= nil,
        'saying so by name', table.concat(lines, ' | '))
end

-- ------------------------------------------------------------- the request ---

describe('guild.request')
do
    local env = bootReady(5)
    env.BR.Guild.ask(5, nil)

    ok(#http == 1, 'one request goes out', tostring(#http))
    local r = http[1] or {}
    ok(r.method == 'GET', 'as a GET', tostring(r.method))
    ok(r.url == ('https://discord.com/api/v10/guilds/%s/members/%s'):format(GUILD, SNOW),
        'to the member endpoint, v10, with both ids in the path', tostring(r.url))
    ok((r.headers or {})['Authorization'] == 'Bot ' .. TOKEN,
        'authorised as a bot', tostring((r.headers or {})['Authorization']))
    -- Discord's API reference REQUIRES this shape and says requests without it
    -- "may be blocked and return a Cloudflare error" -- which would arrive as a
    -- 403, i.e. as unknown, i.e. as this feature silently never working.
    ok(tostring((r.headers or {})['User-Agent']):find('DiscordBot', 1, true) == 1,
        'and identifies as a DiscordBot', tostring((r.headers or {})['User-Agent']))
end

describe('guild.verdicts')
do
    local yes = bootReady(5)
    local gotYes
    yes.BR.Guild.ask(5, function(m) gotYes = m end)
    respond(1, 200, '')
    ok(yes.BR.Guild.member(5) == true, 'a 200 makes a member', tostring(yes.BR.Guild.member(5)))
    ok(gotYes == true, 'and the caller is told true', tostring(gotYes))

    local no = bootReady(5)
    local gotNo = 'untouched'
    no.BR.Guild.ask(5, function(m) gotNo = m end)
    respond(1, 404, B_NOT_MEMBER)
    ok(no.BR.Guild.member(5) == false, 'a 10007 makes a definite non-member',
        tostring(no.BR.Guild.member(5)))
    ok(gotNo == false, 'and the caller is told false, not nil', tostring(gotNo))

    local dunno = bootReady(5)
    local gotDunno = 'untouched'
    dunno.BR.Guild.ask(5, function(m) gotDunno = m end)
    respond(1, 500, '')
    -- THE DISTINCTION THE FEATURE RESTS ON. `false` and `nil` both leave the card
    -- up today, so a suite that only checked the card would pass with these
    -- collapsed -- and the day anything wants to tell "not a member" from "we
    -- never found out" it would be reading a lie.
    ok(dunno.BR.Guild.member(5) == nil, 'a 500 leaves us knowing nothing',
        tostring(dunno.BR.Guild.member(5)))
    ok(gotDunno == nil, 'and says so as nil rather than as false', tostring(gotDunno))
end

describe('guild.nodiscord')
do
    -- FiveM reports `discord:` only for a player whose desktop client is running
    -- with the activity integration on. It is opt-in, it is not ours to turn on,
    -- and server/admin.lua's header records the same limitation gating the Admin
    -- tab. There is nobody to ask about, so no call is made at all.
    local env = bootReady(5)
    idents[5] = { 'license:abc123', 'steam:110000100000000' }

    local got = 'untouched'
    env.BR.Guild.ask(5, function(m) got = m end)
    advance(60000)

    ok(#http == 0, 'no identifier means no request', tostring(#http))
    ok(got == nil, 'the caller is told nil', tostring(got))
    ok(env.BR.Guild.member(5) == nil, 'and the card stays up',
        tostring(env.BR.Guild.member(5)))

    -- AND IT IS STILL SPENT. Otherwise every br:ready for a player with no
    -- Discord client re-enters the queue for the length of their session.
    env.BR.Guild.ask(5, nil)
    advance(60000)
    ok(#http == 0, 'and a second ask still asks nothing', tostring(#http))
end

describe('guild.badidentifier')
do
    -- THE IDENTIFIER VALUE GOES STRAIGHT INTO THE REQUEST PATH, which is what
    -- makes the digits-only check a URL control rather than tidiness. FiveM's
    -- `discord:` value is a snowflake today and this guard is what keeps that
    -- from being load-bearing -- a malformed or hostile one is refused here
    -- rather than escaped somewhere downstream.
    --
    -- IT WAS UNTESTED UNTIL A MUTATION FOUND IT. Dropping `snowflake()` from
    -- discordIdOf left every case in this file green, because every fixture in it
    -- had a well-formed id. That is exactly the shape of an assertion that is
    -- true by accident.
    for _, bad in ipairs({ 'not-a-snowflake', '280000000000000000/../x', '28 0000',
                           '2800000000000000000000000000000000000' }) do
        local env = bootReady(5)
        idents[5] = { 'discord:' .. bad }
        local got = 'untouched'
        env.BR.Guild.ask(5, function(m) got = m end)
        advance(60000)
        ok(#http == 0, ('%q never reaches a URL'):format(bad), tostring(#http))
        ok(got == nil, ('and %q is answered as unknown'):format(bad), tostring(got))
    end
end

-- ------------------------------------------------ one lookup per connection ---

describe('guild.once')
do
    local env = bootReady(5)
    env.BR.Guild.ask(5, nil)
    respond(1, 200, '')
    advance(60000)

    env.BR.Guild.ask(5, nil)
    advance(60000)
    ok(#http == 1, 'a settled source is never asked again', tostring(#http))
end

describe('guild.onceafterfailure')
do
    -- THE CASE A CACHE OF ANSWERS WOULD MISS. A lookup that resolved to unknown
    -- leaves nothing in the verdict table, so a file that keyed "have we asked"
    -- off "do we have an answer" would call Discord again on the next br:ready,
    -- and again on the one after that -- once per menu open, per player, forever,
    -- and only while Discord is already unhappy with us.
    local env = bootReady(5)
    env.BR.Guild.ask(5, nil)
    respond(1, 500, '')
    advance(60000)

    ok(env.BR.Guild.member(5) == nil, 'the failure left no verdict behind',
        tostring(env.BR.Guild.member(5)))
    env.BR.Guild.ask(5, nil)
    advance(60000)
    ok(#http == 1, 'and it is still not asked again', tostring(#http))
end

describe('guild.inflight')
do
    -- Two br:ready events a frame apart -- a reconnect, a `restart br_ui` -- must
    -- attach to the lookup already out rather than start a second one, and BOTH
    -- callers must be answered.
    local env = bootReady(5)
    local a, b = 'untouched', 'untouched'
    env.BR.Guild.ask(5, function(m) a = m end)
    env.BR.Guild.ask(5, function(m) b = m end)

    ok(#http == 1, 'a second ask mid-flight starts no second request', tostring(#http))
    respond(1, 200, '')
    ok(a == true and b == true, 'and both callers get the answer',
        tostring(a) .. '/' .. tostring(b))
end

describe('guild.throwingcallback')
do
    -- A callback belongs to another file. One that throws must not take the
    -- queue's in-flight flag down with it, because that would wedge every lookup
    -- after this one for the life of the process -- on somebody else's bug.
    local env = bootReady(5)
    idents[6] = { 'discord:' .. SNOW }
    env.BR.Guild.ask(5, function() error('boom') end)
    env.BR.Guild.ask(6, nil)
    respond(1, 200, '')
    advance(1000)
    ok(#http == 2, 'the queue survives a throwing callback', tostring(#http))
end

-- ------------------------------------------------------------ the lifecycle ---

describe('guild.drop')
do
    local env = bootReady(5)
    env.BR.Guild.ask(5, nil)
    respond(1, 200, '')
    ok(env.BR.Guild.member(5) == true, 'a member is remembered while connected',
        tostring(env.BR.Guild.member(5)))

    fire('playerDropped', '5')   -- a STRING, which is how FiveM delivers it
    -- A SERVER ID IS RECYCLED WITHIN THE MINUTE. A verdict left behind is handed
    -- to the next person to hold that number, and an inherited `true` takes the
    -- card away from somebody Discord was never asked about. The string/number
    -- key normalisation is what makes this line pass at all -- t[5] and t["5"]
    -- are different keys in Lua.
    ok(env.BR.Guild.member(5) == nil, 'and forgotten on drop, string source and all',
        tostring(env.BR.Guild.member(5)))

    env.BR.Guild.ask(5, nil)
    advance(1000)
    ok(#http == 2, 'so the next holder of that id is asked afresh', tostring(#http))
end

describe('guild.dropwhilequeued')
do
    -- A player who leaves before their turn in the queue costs nothing. Spending
    -- a Discord call to fill a table we are about to forget is the only waste
    -- this file can produce on its own.
    local env = bootReady(5)
    idents[6] = { 'discord:' .. SNOW }
    env.BR.Guild.ask(5, nil)
    env.BR.Guild.ask(6, nil)
    ok(#http == 1, 'only the first is out', tostring(#http))

    fire('playerDropped', 6)
    respond(1, 200, '')
    advance(60000)
    ok(#http == 1, 'and the queued one who left is never sent', tostring(#http))
end

describe('guild.rejoin')
do
    -- THE ONLY REMEDY THIS FEATURE HAS, and it has to work: a player joins the
    -- Discord and reconnects, and is asked again. Nothing listens for a Discord
    -- join, on the owner's own reasoning ("it's not worth us writing something to
    -- listen for that").
    local env = bootReady(5)
    env.BR.Guild.ask(5, nil)
    respond(1, 404, B_NOT_MEMBER)
    ok(env.BR.Guild.member(5) == false, 'not a member on the first connection',
        tostring(env.BR.Guild.member(5)))

    fire('playerDropped', 5)
    env.BR.Guild.ask(5, nil)
    respond(2, 200, '')
    ok(env.BR.Guild.member(5) == true, 'and a member on the next one',
        tostring(env.BR.Guild.member(5)))
end

-- ------------------------------------------------------------------- pacing ---

describe('guild.pace')
do
    -- SIXTY PLAYERS ARRIVE AT ONCE. Discord publishes no per-route number for
    -- this endpoint -- the bucket is dynamic and announced in headers -- so the
    -- engineering answer is to stay far enough under it that we never find out.
    local env = bootReady(1)
    for src = 1, 4 do idents[src] = { 'discord:' .. SNOW } end
    for src = 1, 4 do env.BR.Guild.ask(src, nil) end

    ok(#http == 1, 'only one request is ever out at a time', tostring(#http))

    respond(1, 200, '')
    ok(#http == 1, 'and the next does not follow the answer immediately', tostring(#http))
    advance(249)
    ok(#http == 1, 'nor 249ms later', tostring(#http))
    advance(1)
    ok(#http == 2, 'but does at 250ms', tostring(#http))

    respond(2, 200, '')
    advance(250)
    ok(#http == 3, 'and the queue keeps draining at that rate', tostring(#http))
end

describe('guild.ratelimited')
do
    local OTHER = '410000000000000001'
    local env = bootReady(1)
    idents[1] = { 'discord:' .. SNOW }
    idents[2] = { 'discord:' .. OTHER }
    env.BR.Guild.ask(1, nil)
    env.BR.Guild.ask(2, nil)

    respond(1, 429, B_RETRY_1_5)
    ok(env.BR.Guild.member(1) == nil, 'a 429 is unknown, so the card stays up',
        tostring(env.BR.Guild.member(1)))

    -- NOT RETRIED, AND THE QUEUE STANDS DOWN FOR THE INTERVAL DISCORD NAMED.
    -- Re-queueing the refused lookup would make the busiest moment on the server
    -- the moment we send Discord the most traffic, which is how a rate limit
    -- becomes an IP ban.
    advance(1000)
    ok(#http == 1, 'and the next lookup waits out the named interval', tostring(#http))
    advance(600)
    ok(#http == 2, 'then goes, once', tostring(#http))
    ok(tostring((http[2] or {}).url):find(OTHER, 1, true) ~= nil,
        'and it is the QUEUED player, not a retry of the refused one',
        tostring((http[2] or {}).url))
    advance(60000)
    ok(#http == 2, 'the refused lookup is never re-sent', tostring(#http))
    ok(env.BR.Guild.member(1) == nil, 'and that connection has spent its one call',
        tostring(env.BR.Guild.member(1)))
end

describe('guild.timeout')
do
    -- PerformHttpRequest's own no-response ceiling is a hardcoded 5s and is not
    -- ours to move, so this timer only ever fires for a request that threw
    -- synchronously or a callback that never came. Without it, `busy` stays true
    -- and the queue is stopped for the life of the process.
    local env = bootReady(1)
    for src = 1, 2 do idents[src] = { 'discord:' .. SNOW } end
    local calls, got = 0, 'untouched'
    env.BR.Guild.ask(1, function(m) calls = calls + 1; got = m end)
    env.BR.Guild.ask(2, nil)

    advance(5999)
    ok(calls == 0, 'nothing gives up early', tostring(calls))
    advance(1)
    ok(calls == 1 and got == nil, 'the caller is told nil at 6s',
        tostring(calls) .. '/' .. tostring(got))
    advance(250)
    ok(#http == 2, 'and the queue moves on', tostring(#http))

    -- A LATE ANSWER MUST NOT SETTLE A SECOND TIME. It would call a callback that
    -- has already been answered and release a `busy` flag belonging to the NEXT
    -- request, which puts two lookups in flight at once from then on.
    respond(1, 200, '')
    ok(calls == 1, 'a late answer calls nobody a second time', tostring(calls))
    ok(env.BR.Guild.member(1) == nil, 'and records nothing',
        tostring(env.BR.Guild.member(1)))
    advance(60000)
    ok(#http == 2, 'and does not send a third request', tostring(#http))
end

-- ------------------------------------------------------------- the secret ---

describe('guild.secret')
do
    local env = bootReady(5)
    local lines = env.BR.Guild.report()
    local text = table.concat(lines, '\n')

    -- THE GUILD ID IS NOT A SECRET AND THE TOKEN IS. This is the boot banner and
    -- an operator's scrollback; a token that reaches it is a token in a log file.
    ok(text:find(GUILD, 1, true) ~= nil, 'the boot line names the guild', text)
    ok(text:find(TOKEN, 1, true) == nil, 'and never the token', text)
    ok(text:find(('set (%d chars)'):format(#TOKEN), 1, true) ~= nil,
        'only its length, so a truncated paste is still diagnosable', text)

    -- AND IT IS NOWHERE ON THE WIRE EXCEPT THE ONE HEADER.
    env.BR.Guild.ask(5, nil)
    local r = http[1] or {}
    ok(tostring(r.url):find(TOKEN, 1, true) == nil, 'the URL does not carry it',
        tostring(r.url))
    ok(tostring(r.data or ''):find(TOKEN, 1, true) == nil, 'and neither does the body',
        tostring(r.data))
end

describe('guild.surface')
do
    -- THE THREE FUNCTIONS server/community.lua CALLS, pinned. tools/
    -- test_community.lua drives the real file, so a rename would fail there too
    -- -- this names them so the failure says WHICH one moved.
    local env = bootReady(5)
    for _, name in ipairs({ 'member', 'ask', 'configured', 'report', 'readAnswer', 'backoffMs' }) do
        ok(type(env.BR.Guild[name]) == 'function', ('BR.Guild.%s is a function'):format(name),
            type(env.BR.Guild[name]))
    end
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
