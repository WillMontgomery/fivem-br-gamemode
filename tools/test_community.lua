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

Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = function() end }
function SetTimeout() end
local realPrint = print
function print() end

local ROOT = 'resources/[fivem-royale]/'

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
    handlers = {}

    local env = setmetatable({}, { __index = _G })
    for _, f in ipairs({
        'br_lib/shared/protocol.lua',
        'br_lib/config/community.lua',
        'br_lib/config/overrides.lua',
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

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
