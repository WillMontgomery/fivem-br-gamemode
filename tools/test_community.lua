-- Unit tests for the Discord card's sender (owner, 2026-08-30).
--
-- WHAT IS WORTH TESTING HERE IS THE ANSWER A PAGE GETS, and the interesting
-- cases are the ones a playtest cannot produce cheaply. "The card is absent on a
-- server with no invite configured" needs a second deployment; "a whitespace-only
-- convar counts as absent" needs somebody to type a space into a live console and
-- then get kicked to find out. Both are three lines here.
--
-- AND ONE OF THEM IS THE FEATURE'S ONLY REAL TRAP. br_core/server/community.lua
-- answers br:ready with `{}` rather than staying silent when there is no invite,
-- ON PURPOSE -- an empty table is a definite "this server publishes none", and it
-- is what takes a card back down on a page that is already up. Silence would
-- leave the last answer standing forever. A refactor that "optimises away" the
-- empty send looks harmless and breaks exactly that, so it is asserted directly:
-- an envelope IS sent, and it carries no invite.
--
-- SINCE 2026-08-31 THE ENVELOPE CARRIES A SECOND FACT and the same argument
-- applies to it twice over. `member` is present only for a player Discord
-- confirmed is already in the guild, and ABSENT for both "Discord said no" and
-- every shade of "we never found out" -- so two of BR.Guild's three answers must
-- produce byte-identical payloads. Staging that in a match needs a bot token, a
-- second Discord account, and a way to make Discord time out on demand; here it
-- is a status code. The blocks at the bottom of this file walk them.
--
-- THE CONVAR PATH IS EXERCISED THROUGH THE REAL br_lib/config/overrides.lua
-- rather than by assigning BR.Config.Community.discordUrl by hand. Assigning it
-- would test the reader against a value nothing in production produces; running
-- the real parser means this suite also fails the day the override stops
-- reaching the table it is read out of, which is this project's most expensive
-- recurring bug (two homes for one setting, nothing comparing them).
--
-- Run via tools/verify.sh, or directly:  lua tools/test_community.lua

-- --------------------------------------------------------------- harness ---

local convars = {}
function GetConvar(name, default)
    local v = convars[name]
    if v == nil then return default end
    return v
end

-- overrides.lua only applies convars on the server, and asks with this native.
function IsDuplicityVersion() return true end

function GetCurrentResourceName() return 'br_core' end

-- A LIST PER EVENT, like tools/test_admin.lua's. Several files register br:ready
-- and a last-one-wins stub would silently test half the path -- and here the
-- file under test is deliberately the SECOND listener on that event.
local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function RegisterNetEvent() end

--- Dispatch an event as if it came FROM a player, which is the only way the
--- global `source` is set.
local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

-- What the server sent to a client. This is the whole observable surface of the
-- feature: the card appears because an envelope arrived carrying an address.
local sent = {}
function TriggerClientEvent(event, target, data)
    sent[#sent + 1] = { event = event, target = target, data = data }
end

local function reset() sent = {} end
local function sentCount() return #sent end

--- The last envelope, or an empty table.
---
--- NIL-SAFE ON PURPOSE. Every interesting mutation of this feature -- a sender
--- that stops answering, a guard that starts refusing everybody -- makes this
--- nil, and `sent[#sent].data.invite` would then abort the whole suite with a
--- traceback at the first one. A suite that dies tells you where it died; a
--- suite that fails tells you what broke, and lists the rest.
local function last()
    local e = sent[#sent]
    if e == nil then return {} end
    return e
end

--- The invite in the last envelope, or nil. Same reasoning.
local function lastInvite()
    local d = last().data
    if type(d) ~= 'table' then return nil end
    return d.invite
end

--- The membership flag in the last envelope, or nil. Same nil-safety.
local function lastMember()
    local d = last().data
    if type(d) ~= 'table' then return nil end
    return d.member
end

-- --- what server/guild.lua needs to exist ----------------------------------
--
-- THE REAL guild.lua IS IN THE CHAIN BELOW, NOT A STUB OF IT, for the same
-- reason the real config/overrides.lua is: this suite's job is the SEAM. A
-- hand-written BR.Guild would assert that community.lua does what it is told,
-- and would go on passing the day the function it calls is renamed or the day
-- `member` stops meaning what this file thinks it means. tools/test_guild.lua
-- walks that file's own branches; what is here is the one thing neither file can
-- prove alone -- that a confirmed member reaches the payload and nothing else
-- does.
--
-- The stubs are therefore the minimum guild.lua needs to run: a clock it can
-- schedule on, a network it cannot reach, and identifiers.

local clock = 0
local timers = {}
function GetGameTimer() return clock end
function SetTimeout(ms, fn)
    timers[#timers + 1] = { at = clock + (tonumber(ms) or 0), fn = fn }
end
Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = SetTimeout }

--- Run every timer due within `ms`, in time order, re-scanning as callbacks
--- arm more. See tools/test_guild.lua, which drives the pacing in detail.
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

local http = {}
function PerformHttpRequest(url, cb, method, data, headers)
    http[#http + 1] = { url = url, cb = cb, method = method, headers = headers }
end

local idents = {}
function GetNumPlayerIdentifiers(src) return #(idents[tonumber(src) or src] or {}) end
function GetPlayerIdentifier(src, i)
    local list = idents[tonumber(src) or src] or {}
    return list[i + 1]
end

-- Only the 404 body is ever decoded here; test_guild.lua covers the rest.
json = {
    decode = function(s)
        if s == '{"code":10007}' then return { code = 10007 } end
        error('unparseable body')
    end,
}

local realPrint = print
function print() end

local ROOT = 'resources/[fivem-royale]/'

-- A PLACEHOLDER-SHAPED FIXTURE, NOT A TOKEN-SHAPED ONE, and the difference is
-- not cosmetic. tools/check_secrets.sh scans this file like any other, and the
-- first draft of these blocks used a realistic three-segment token that missed
-- its shape rule by a single character -- it was caught by the convar-name rule
-- instead, which is the second pair of eyes doing exactly what it is for.
-- Nothing here depends on the shape: the file under test never parses the token,
-- it only puts it in a header.
local TOKEN = 'EXAMPLE.not-a-real.bot-token'
local GUILD_ID = '905311830203392042'
local SNOW = '280000000000000000'

--- Load the chain into a FRESH sandbox, with these convars in place.
---
--- A NEW `BR` PER CASE. The whole feature is "read a value config/overrides.lua
--- mutated into a table", so a leak from one case into the next would make the
--- suite report on its own setup. Convars are set BEFORE the load because that
--- is when overrides.lua reads them, exactly as it does on a real boot.
--- @param cvs table  convar name -> raw string
--- @return table env
local function boot(cvs)
    convars = {}
    for k, v in pairs(cvs or {}) do convars[k] = v end
    reset()
    handlers, http, timers, idents = {}, {}, {}, {}
    clock = 0

    local env = setmetatable({}, { __index = _G })
    for _, f in ipairs({
        'br_lib/shared/protocol.lua',
        'br_lib/shared/identity.lua',
        'br_lib/config/community.lua',
        'br_lib/config/overrides.lua',
        'br_core/server/guild.lua',
        'br_core/server/community.lua',
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

-- ------------------------------------------------------------ the answer ---

local INVITE = 'https://discord.gg/PggjJ7hDSg'

describe('community.ready')
do
    local env = boot({ br_discordUrl = INVITE })
    fire(env.BR.Net.READY, 7)

    ok(sentCount() == 1, 'br:ready is answered exactly once', tostring(sentCount()))
    ok(last().event == env.BR.Net.COMMUNITY,
        'on the community event', tostring(last().event))
    ok(last().target == 7, 'to the player who asked', tostring(last().target))
    ok(lastInvite() == INVITE, 'carrying the configured invite', tostring(lastInvite()))
end

describe('community.unset')
do
    -- No convar at all: config/community.lua's committed default is '' and
    -- GetConvar returns a default only when the convar is UNSET, so this is the
    -- out-of-the-box server.
    local env = boot({})
    fire(env.BR.Net.READY, 3)

    -- THE ASSERTION THIS SUITE EXISTS FOR. Not "no invite was sent" -- an
    -- envelope must be sent, and it must be empty. A sender that returns early
    -- when there is nothing to say passes a test written the other way round and
    -- leaves a stale card on screen forever after an operator clears the invite.
    ok(sentCount() == 1, 'an unconfigured server still answers -- `{}`, never silence',
        tostring(sentCount()))
    ok(last().event == env.BR.Net.COMMUNITY, 'on the community event')
    ok(type(last().data) == 'table', 'with a table', type(last().data))
    ok(lastInvite() == nil, 'and no invite in it', tostring(lastInvite()))
end

describe('community.blank')
do
    -- `set br_discordUrl ""` is SET-to-empty rather than unset, and it arrives
    -- here as ''. br_ringmaster/server/appeal.lua collapses the two spellings and
    -- so does this; the point of asserting it is that they must not drift.
    local env = boot({ br_discordUrl = '' })
    fire(env.BR.Net.READY, 4)

    ok(sentCount() == 1, 'an empty convar still answers', tostring(sentCount()))
    ok(lastInvite() == nil, 'and means absent, exactly as unset does',
        tostring(lastInvite()))
end

describe('community.whitespace')
do
    -- WHITESPACE CANNOT ARRIVE BY CONVAR, WHICH IS WHY THIS CASE IS DRIVEN BY
    -- HAND. `set br_discordUrl "   "` does not reach the reader at all:
    -- config/overrides.lua's link parser trims it, sees an empty string and
    -- REFUSES TO BOOT the whole gamemode -- verified by loading the real parser
    -- with that value, which exits before any of this runs.
    --
    -- The trim below therefore guards the other door: a hand-edited
    -- config/community.lua, or any future writer of BR.Config.Community that
    -- does not go through the override spec. It is kept because
    -- br_ringmaster/server/appeal.lua has exactly the same guard against exactly
    -- the same door, and the two readers of this one value must not drift.
    local env = boot({})
    env.BR.Config.Community.discordUrl = '   '
    fire(env.BR.Net.READY, 5)

    ok(sentCount() == 1, 'a whitespace-only value still answers', tostring(sentCount()))
    ok(lastInvite() == nil, 'and means absent too', tostring(lastInvite()))

    -- A LEADING SPACE ON A REAL ADDRESS IS TRIMMED, NOT REFUSED. The card would
    -- otherwise copy a string the player cannot paste into a browser.
    env.BR.Config.Community.discordUrl = '  ' .. INVITE .. '  '
    fire(env.BR.Net.READY, 5)
    ok(lastInvite() == INVITE, 'and a padded one is trimmed to the address',
        tostring(lastInvite()))
end

describe('community.payload')
do
    -- The reader, straight. `BR.Community.payload()` is what the handler sends,
    -- so a change that breaks the handler and not the reader (or the other way
    -- round) is named rather than merely counted.
    local env = boot({ br_discordUrl = INVITE })
    local p = env.BR.Community.payload()
    ok(type(p) == 'table' and p.invite == INVITE, 'payload() carries the invite',
        tostring(type(p) == 'table' and p.invite))

    local none = boot({}).BR.Community.payload()
    ok(type(none) == 'table', 'and is a table when there is none', type(none))
    ok(next(none) == nil, 'an EMPTY one -- not nil, not false', tostring(next(none)))
end

describe('community.repeat')
do
    -- br_core/client/state.lua's br:ui:ready ALWAYS re-requests -- on a fresh
    -- connect, on a reconnect and on every `restart br_ui` -- which is the whole
    -- reason there is no cache anywhere in this feature. Every ask must be
    -- answered, not just the first.
    local env = boot({ br_discordUrl = INVITE })
    fire(env.BR.Net.READY, 9)
    fire(env.BR.Net.READY, 9)
    ok(sentCount() == 2, 'a second ask gets a second answer', tostring(sentCount()))
    ok(lastInvite() == INVITE, 'with the same address', tostring(lastInvite()))
end

describe('community.name')
do
    -- THE WIRE FIELD IS `invite`, AND THAT IS LOAD-BEARING RATHER THAN
    -- COSMETIC. tools/verify.sh's tunable-overrides gate forbids the convar's
    -- key name in any br_*/client/*.lua, comment lines included, so a rename
    -- back to `discordUrl` would fail the build the moment br_ui's relay
    -- mentioned it. Pinned here so the rename is a deliberate act.
    local env = boot({ br_discordUrl = INVITE })
    fire(env.BR.Net.READY, 2)
    local d = last().data
    ok(type(d) == 'table' and d.discordUrl == nil,
        'the convar key never crosses the wire', tostring(type(d) == 'table' and d.discordUrl))
    ok(env.BR.Net.COMMUNITY == 'br:community', 'the net event name is pinned',
        tostring(env.BR.Net.COMMUNITY))
    ok(env.BR.Nui.COMMUNITY == 'community', 'and so is the envelope kind',
        tostring(env.BR.Nui.COMMUNITY))
end

-- ------------------------------------------- who is already in the Discord ---
--
-- THE SECOND RULE ON THIS CARD (owner, 2026-08-31): "let's make it always show
-- in the help page (unless we know they're in the guild)". The half that lives
-- in this file is which answers reach the wire, and the trap is the same shape
-- as the `{}` above: two of BR.Guild's three answers must produce IDENTICAL
-- payloads, so a suite that only checked the happy path would pass with them
-- collapsed and stop inviting everybody whose lookup merely failed.

local CONFIGURED = {
    br_discordUrl = INVITE,
    br_discord_bot_token = TOKEN,
    br_discord_guild_id = GUILD_ID,
}

--- A configured sandbox with one player who has a Discord identifier, primed at
--- playerJoining exactly as a real connection is.
local function bootJoined(src, cvs)
    local env = boot(cvs or CONFIGURED)
    idents[src] = { 'license:abc123', 'discord:' .. SNOW }
    fire('playerJoining', src)
    return env
end

describe('community.member')
do
    local env = bootJoined(5)
    ok(#http == 1, 'joining asks Discord once', tostring(#http))
    http[1].cb(200, '', {})

    fire(env.BR.Net.READY, 5)
    ok(sentCount() == 1, 'and br:ready answers exactly once', tostring(sentCount()))
    ok(lastInvite() == INVITE, 'still carrying the address', tostring(lastInvite()))
    -- THE WHOLE FEATURE, IN ONE FIELD. The page hides the card on this and on
    -- nothing else.
    ok(lastMember() == true, 'and saying this player is already in the guild',
        tostring(lastMember()))
end

describe('community.notmember')
do
    local env = bootJoined(5)
    http[1].cb(404, '{"code":10007}', {})

    fire(env.BR.Net.READY, 5)
    ok(sentCount() == 1, 'a definite non-member is answered once', tostring(sentCount()))
    ok(lastInvite() == INVITE, 'with the address', tostring(lastInvite()))
    -- ABSENT, NOT `false`. bridge/types.ts pins the client side of this: the
    -- payload says "hide it" or says nothing, and there is no third spelling for
    -- a page to get the polarity wrong on.
    ok(lastMember() == nil, 'and no membership flag at all', tostring(lastMember()))
end

describe('community.unknown')
do
    -- EVERY WAY OF NOT KNOWING PRODUCES THE SAME PAYLOAD AS "not a member", and
    -- that is the point rather than a coincidence: a card that hid itself when
    -- Discord was merely unreachable would stop inviting people in exactly the
    -- state nobody is watching.
    for _, answer in ipairs({ { 500, '' }, { 429, '' }, { 401, '' }, { 403, '' },
                              { 404, '{"code":10004}' }, { 0, '' } }) do
        local env = bootJoined(5)
        http[1].cb(answer[1], answer[2], {})
        fire(env.BR.Net.READY, 5)
        ok(lastMember() == nil, ('a %d leaves the card up'):format(answer[1]),
            tostring(lastMember()))
        ok(lastInvite() == INVITE, ('and a %d still carries the address'):format(answer[1]),
            tostring(lastInvite()))
    end
end

describe('community.nodiscord')
do
    -- FiveM reports `discord:` only when the player's desktop client is running.
    -- That is most of a public server on a bad day, and all of it if Discord ever
    -- withdraws the integration -- so it must be the ordinary case, not an edge.
    local env = boot(CONFIGURED)
    idents[5] = { 'license:abc123' }
    fire('playerJoining', 5)
    advance(60000)
    ok(#http == 0, 'no discord identifier, no request', tostring(#http))

    fire(env.BR.Net.READY, 5)
    ok(sentCount() == 1, 'and the player is still answered', tostring(sentCount()))
    ok(lastInvite() == INVITE, 'with the address', tostring(lastInvite()))
    ok(lastMember() == nil, 'and the card up', tostring(lastMember()))
end

describe('community.notoken')
do
    -- THE DEFAULT THIS SHIPS ON. The owner may not paste a token for weeks; until
    -- he does, this feature is inert and every player sees the card.
    local env = boot({ br_discordUrl = INVITE })
    idents[5] = { 'discord:' .. SNOW }
    fire('playerJoining', 5)
    fire(env.BR.Net.READY, 5)
    advance(60000)

    ok(#http == 0, 'an unconfigured server asks Discord nothing', tostring(#http))
    ok(sentCount() == 1, 'and answers br:ready as it always did', tostring(sentCount()))
    ok(lastInvite() == INVITE, 'with the address', tostring(lastInvite()))
    ok(lastMember() == nil, 'and no membership flag', tostring(lastMember()))
end

describe('community.noinvite')
do
    -- A SERVER THAT PUBLISHES NO DISCORD DRAWS NO CARD, so there is nothing to
    -- hide and no reason to spend a Discord call per connection finding out who
    -- to hide it from. The guard lives in this file because this is the file that
    -- knows there is a card.
    local env = boot({
        br_discord_bot_token = TOKEN,
        br_discord_guild_id = GUILD_ID,
    })
    idents[5] = { 'discord:' .. SNOW }
    fire('playerJoining', 5)
    advance(60000)
    ok(#http == 0, 'no invite means no lookup', tostring(#http))

    fire(env.BR.Net.READY, 5)
    ok(sentCount() == 1, 'and `{}` is still sent, never silence', tostring(sentCount()))
    ok(next(last().data) == nil, 'an EMPTY one', tostring(next(last().data)))
end

describe('community.late')
do
    -- THE ANSWER ARRIVING AFTER THE PAGE IS UP. A `restart br_ui` replays
    -- br:ready without a playerJoining in front of it, and a reconnect can beat
    -- its own lookup. The page is told what we know NOW and corrected if we learn
    -- better; it is never held behind a round trip to a third party.
    local env = boot(CONFIGURED)
    idents[5] = { 'discord:' .. SNOW }

    fire(env.BR.Net.READY, 5)
    ok(sentCount() == 1, 'the first answer does not wait for Discord', tostring(sentCount()))
    ok(lastMember() == nil, 'and claims nothing about membership', tostring(lastMember()))
    ok(#http == 1, 'while the lookup goes out', tostring(#http))

    http[1].cb(200, '', {})
    ok(sentCount() == 2, 'a confirmed member gets a second envelope', tostring(sentCount()))
    ok(lastMember() == true, 'carrying the flag', tostring(lastMember()))
    ok(lastInvite() == INVITE, 'and the address, because the payload is whole',
        tostring(lastInvite()))
end

describe('community.nolatenoise')
do
    -- ONLY A `true` RE-SENDS. false and nil leave the card exactly where the
    -- first envelope left it, so a second one would be a wire message per player
    -- per connection that changes nothing on screen.
    for _, answer in ipairs({ { 404, '{"code":10007}' }, { 500, '' } }) do
        local env = boot(CONFIGURED)
        idents[5] = { 'discord:' .. SNOW }
        fire(env.BR.Net.READY, 5)
        http[1].cb(answer[1], answer[2], {})
        ok(sentCount() == 1, ('a %d sends no second envelope'):format(answer[1]),
            tostring(sentCount()))
    end
end

describe('community.onelookup')
do
    -- "Do not call Discord on every menu open." br:ready is re-fired on every
    -- `restart br_ui` and on every reconnect -- br_core/client/state.lua ALWAYS
    -- re-requests -- so an uncached lookup would be one Discord call per menu, per
    -- player, for the length of a session.
    local env = bootJoined(5)
    fire(env.BR.Net.READY, 5)
    fire(env.BR.Net.READY, 5)
    fire(env.BR.Net.READY, 5)
    advance(60000)
    ok(#http == 1, 'four asks, one lookup', tostring(#http))
    ok(sentCount() == 3, 'and every ask still gets an answer', tostring(sentCount()))
end

describe('community.drop')
do
    -- A SERVER ID IS RECYCLED WITHIN THE MINUTE, and the verdict must not be. An
    -- inherited `true` takes the card away from somebody Discord was never asked
    -- about -- the one failure of this feature that is invisible from both ends.
    local env = bootJoined(5)
    http[1].cb(200, '', {})
    fire(env.BR.Net.READY, 5)
    ok(lastMember() == true, 'the member is hidden from', tostring(lastMember()))

    fire('playerDropped', '5')
    fire(env.BR.Net.READY, 5)
    ok(lastMember() == nil, 'and the next holder of that id is not',
        tostring(lastMember()))
end

describe('community.strictmember')
do
    -- THE `== true` IN payload(), TESTED AS A RULE RATHER THAN AS AN OUTCOME.
    --
    -- THE ONLY BLOCK IN THIS FILE THAT REACHES INTO BR.Guild, and it earns the
    -- exception: a mutation that changed `member(src) == true` to `member(src)`
    -- left every other case here green, because the real function returns only
    -- true, false and nil -- so the strict comparison is right by accident today
    -- and is the thing the comment above it claims to be doing. An answer that is
    -- TRUTHY WITHOUT BEING TRUE is the case that tells them apart, and this
    -- project has a standing rule about it: `0` is truthy in Lua, a FiveM BOOL
    -- native may answer 1/0, and server/admin.lua writes `grant ~= true` rather
    -- than `not grant` for the same reason on the same kind of three-valued
    -- answer.
    local env = bootJoined(5)
    env.BR.Guild.member = function() return { inTheGuild = 'probably' } end

    fire(env.BR.Net.READY, 5)
    ok(lastMember() == nil, 'a truthy non-true answer takes no card away',
        tostring(lastMember()))
    ok(lastInvite() == INVITE, 'and the address still travels', tostring(lastInvite()))

    -- 0 IS TRUTHY IN LUA. This is the one that reads as paranoia and is not.
    env.BR.Guild.member = function() return 0 end
    fire(env.BR.Net.READY, 5)
    ok(lastMember() == nil, 'and neither does a zero', tostring(lastMember()))
end

describe('community.membername')
do
    -- THE WIRE FIELD IS `member` AND IT IS ONLY EVER `true`, pinned here beside
    -- the `invite` pin above for the same reason: ui-src reads these two names and
    -- no Lua test can see ui-src.
    local env = bootJoined(5)
    http[1].cb(200, '', {})
    fire(env.BR.Net.READY, 5)
    local d = last().data
    ok(type(d) == 'table' and d.member == true, 'the field is `member`',
        tostring(type(d) == 'table' and d.member))
    ok(env.BR.Nui.COMMUNITY == 'community', 'on the envelope kind it always was',
        tostring(env.BR.Nui.COMMUNITY))

    -- AND payload() WITH NO SOURCE STILL ANSWERS ABOUT NOBODY, which is what
    -- `brconfig`-style inspection asks for and what keeps the reader above honest.
    local p = env.BR.Community.payload()
    ok(p.member == nil, 'payload() with no source claims nothing about anybody',
        tostring(p.member))
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
