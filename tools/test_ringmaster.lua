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
function GetPlayerName(src)           return 'Player' .. tostring(src) end
function GetCurrentResourceName()     return 'br_ringmaster' end

local handlers = {}
function AddEventHandler(name, fn) handlers[name] = fn end

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
    'br_lib/shared/identity.lua',
    'br_lib/shared/outbox.lua',
    'br_ringmaster/server/config.lua',
    'br_ringmaster/server/main.lua',
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
    -- timestamp alone is not enough -- which is what the nonce is for.
    local seen = {}
    local collisions = 0
    for _ = 1, 200 do
        loadAll({ 'br_ringmaster/server/main.lua' })
        local e = BR.Ring.bootEpoch
        if seen[e] then collisions = collisions + 1 end
        seen[e] = true
    end
    ok(collisions == 0,
        '200 restarts inside the same second produce 200 distinct epochs',
        collisions .. ' collisions')

    ok(BR.Ring.bootEpoch:find('-', 1, true) ~= nil,
        'the epoch carries a nonce, not just a wall-clock second')
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

    ok(#names == 1 and names[1] == 'brring',
        'brring is the ONLY command this resource registers in Slice 1',
        table.concat(names, ', '))
    ok(commands['brring'].restricted == true,
        'and it is restricted, like every other br* console command')
end

-- ----------------------------------------------------------------- result ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
