-- Unit tests for the emote system's server half (#215, "Scope v2").
--
-- ═══ WHAT THIS DRIVES ═══
--
-- The REAL br_core/server/market.lua and br_core/server/emotes.lua, against the
-- REAL br_lib/config/emotes.lua, with br_ddb, the roster and the engine stubbed
-- -- the shape tools/test_volts.lua set for market.lua. Every assertion is on
-- the wire: what br_ddb was asked, what a client was sent, what the console
-- printed. A file-local cache is never reached into.
--
-- ═══ THE SEASON, AND WHY NO ASSERTION HERE DEPENDS ON IT ═══
--
-- Emotes are a Season 2 feature (#388; owner, 2026-10-04), gated by the
-- `emotes` row in br_lib/config/seasons.lua and asked as
-- BR.Season.has('emotes'). The server holds the season it booted with, so this
-- file boots BR.Season the way server/main.lua does, off a br_season convar.
--
-- tools/verify.sh runs it three times: as a box with no br_season (the latest
-- season), and from the emote gate section with BR_SEASON set to the season
-- before the row's `from` (emotes off) and to `from` (on). So a closed-gate case
-- boots the server at the season before `from` (gateClosed), an open one at
-- `from` (gateOpen), and each group boots back to the run's season (restore).
-- Group 0 asserts whatever the run's own season means, with dev mode OFF
-- throughout: the season alone decides, which is the public box.
--
-- ═══ THE RAW COMMAND, NOT THE WRAPPED ONE ═══
--
-- RegisterCommand is captured AFTER devgate.lua has wrapped it, so the
-- bremotegrant body this file calls is the body itself. Captured before, every
-- command would be devgate's closure, which refuses on dev mode first -- and the
-- grant's own gate branch would never run, so a test of it would pass vacuously.

local RES = 'resources/[fivem-royale]/'
--- The season this run's server boots with: verify.sh's BR_SEASON, or nil for a
--- box whose config never set one.
local RUN_SEASON = os.getenv('BR_SEASON')

local realPrint = print
local printed = {}
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, '\t')
end

-- ---------------------------------------------------------------------------
-- Natives and engine stubs
-- ---------------------------------------------------------------------------

local fakeTime = 1000
function GetGameTimer() return fakeTime end

--- Dev mode, as both convars report it. BR.Dev.on() reads them at call time.
local dev = false
--- Every other convar: br_season is what BR.Season.boot reads.
local convars = {}
function GetConvar(name, d)
    if name == 'sv_devMode' or name == 'br_devMode' then return dev and 'true' or 'false' end
    if convars[name] ~= nil then return convars[name] end
    return d
end
--- What boot replicates to the clients.
local replicated = {}
function SetConvarReplicated(name, v) replicated[name] = v end
function GetCurrentResourceName() return 'br_core' end
function GetPlayerName(src) return 'Player' .. tostring(src) end

--- The license behind each src, movable so a test can recycle an id.
local licKey = {}
local function licenseOfSrc(src) return 'license:' .. (licKey[src] or ('test' .. tostring(src))) end
function GetNumPlayerIdentifiers() return 1 end
function GetPlayerIdentifier(src, _) return licenseOfSrc(src) end

local buckets = {}
function GetPlayerRoutingBucket(s)
    local b = buckets[math.tointeger(tonumber(s))]
    if b == nil then error('no such player') end
    return b
end

--- A deep copy, so a record mutated after it was sent reads as it was sent --
--- the runtime serializes at the call.
local function copy(v)
    if type(v) ~= 'table' then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = copy(x) end
    return o
end

local fired, sent = {}, {}
function TriggerEvent(event, ...) fired[#fired + 1] = { event = event, args = copy({ ... }) } end
function TriggerClientEvent(event, target, ...)
    sent[#sent + 1] = { event = event, target = target, args = copy({ ... }) }
end

local handlers = {}
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    handlers[name][#handlers[name] + 1] = fn
end
function RegisterNetEvent() end

local function fire(name, src, ...)
    _G.source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
end

local ddbState = 'started'
function GetResourceState() return ddbState end

local timers = {}
function SetTimeout(_, fn) timers[#timers + 1] = fn end

--- What devgate.lua sees as the native: records what reached the raw door.
local rawRegistered = {}
function RegisterCommand(name, fn, restricted)
    rawRegistered[name] = { fn = fn, restricted = restricted }
end

-- ---------------------------------------------------------------------------
-- The modules under test, in load order
-- ---------------------------------------------------------------------------

local function loadAt(f)
    local chunk, err = loadfile(RES .. f)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

for _, f in ipairs({
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/identity.lua',
    'br_lib/shared/xp.lua',
    'br_lib/shared/devgate.lua',
    'br_lib/shared/sched.lua',
    'br_lib/config/market.lua',
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
    'br_lib/config/emotes.lua',
}) do loadAt(f) end
local C = BR.Config.Emotes

-- A TYPO'D ID FAILS THIS SUITE rather than quietly closing a door.
BR.Season.strict = true

--- The emotes row, and the two seasons either side of its edge.
local ROW = BR.Config.Seasons.features.emotes
local FROM = ROW.from
local OFF = FROM - 1
if OFF < 1 then
    realPrint('\27[31mFAIL\27[0m emotes are on from Season 1, so there is no season to close them in')
    os.exit(1)
end

--- Boot the server's season off a br_season value (nil = unset), as
--- server/main.lua does at resource start.
local function bootAt(raw)
    convars.br_season = raw
    return BR.Season.boot()
end
bootAt(RUN_SEASON)
-- The wrapped door, kept for the devgate assertions in group 9; then the
-- capturing stub, so the files below register their RAW handlers here.
local wrappedRegister = RegisterCommand
local commands = {}
function RegisterCommand(name, fn, restricted) commands[name] = { fn = fn, restricted = restricted } end

-- ═══ THE STUBS server/emotes.lua AND server/market.lua READ AT CALL TIME ═══
local entries = {}
BR.Roster = {
    get = function(src) return entries[src] end,
    each = function(pred, fn)
        local keys = {}
        for s in pairs(entries) do keys[#keys + 1] = s end
        table.sort(keys)
        for _, s in ipairs(keys) do
            local e = entries[s]
            if e and (not pred or pred(e)) then fn(s, e) end
        end
    end,
    licenseOf = function(src) local e = entries[src]; return e and e.license or nil end,
}
BR.Server = { devMode = false }
local riding, using, watching = {}, {}, {}
BR.Vehicles = { ridingIn = function(ped) return riding[ped] end }
BR.Inv = { of = function(src) return entries[src] and { using = using[src] } or nil end }
BR.Spectate = { targetOf = function(src) return watching[src] end }

loadAt('br_core/server/market.lua')
loadAt('br_core/server/emotes.lua')

-- ---------------------------------------------------------------------------
-- Assertions
-- ---------------------------------------------------------------------------

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        realPrint('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail ~= nil and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function gateClosed() bootAt(tostring(OFF)) end
local function gateOpen() bootAt(tostring(FROM)) end
local function restore() bootAt(RUN_SEASON); dev = false end

local gen = 0
local function reset()
    for s in pairs(entries) do fire('playerDropped', s) end
    fired, sent, timers, printed = {}, {}, {}, {}
    for k in pairs(entries) do entries[k] = nil end
    for k in pairs(buckets) do buckets[k] = nil end
    for k in pairs(riding) do riding[k] = nil end
    for k in pairs(using) do using[k] = nil end
    for k in pairs(watching) do watching[k] = nil end
    for k in pairs(licKey) do licKey[k] = nil end
    gen = gen + 1
    ddbState = 'started'
    fakeTime = fakeTime + 100000
    restore()
end

local function reqOf(verb)
    for i = #fired, 1, -1 do
        if fired[i].event == verb then return fired[i].args[1], fired[i].args end
    end
    return nil
end
local function countOf(verb)
    local n = 0
    for _, f in ipairs(fired) do if f.event == verb then n = n + 1 end end
    return n
end

--- br_ddb answers the newest (or a given) request of a verb.
local function answer(verb, ok_, extra, req)
    req = req or reqOf(verb)
    fire(verb .. 'Result', nil, req, ok_, extra or {})
end

local function sentTo(src, event)
    local out = {}
    for _, s in ipairs(sent) do
        if s.target == src and s.event == event then out[#out + 1] = s.args[1] end
    end
    return out
end
local function lastState(src)
    local all = sentTo(src, BR.Net.MARKET_STATE)
    return all[#all]
end
local function toasts(src)
    local out = {}
    for _, t in ipairs(sentTo(src, BR.Net.NOTIFY)) do out[#out + 1] = t.text end
    return out
end
local function has(list, v)
    for _, x in ipairs(list) do if x == v then return true end end
    return false
end
local function records(src) return sentTo(src, BR.Net.EMOTE_RECORD) end
local function allRecords()
    local n = 0
    for _, s in ipairs(sent) do if s.event == BR.Net.EMOTE_RECORD then n = n + 1 end end
    return n
end

--- A connected player with a loaded profile, through the real load path.
--- @param src integer
--- @param o table|nil  owned, equipped, state, pos, bucket, name, balance
local function player(src, o)
    o = o or {}
    licKey[src] = licKey[src] or ('t' .. gen .. '_' .. src)
    entries[src] = {
        src = src, name = o.name or ('Player' .. src), license = licenseOfSrc(src),
        state = o.state or BR.PlayerState.ALIVE, ped = 5000 + src,
        pos = o.pos or { x = 0.0, y = 0.0, z = 0.0 },
        posAt = o.posAt or fakeTime,
    }
    buckets[src] = o.bucket or 1
    BR.Market.load(src)
    fire('br:ddb:inventoryResult', nil, reqOf('br:ddb:inventoryFetch'),
        { balance = o.balance or 5000, xp = 0, owned = o.owned or {}, equipped = o.equipped or {}, tutorial = '' }, {})
end

local function sweep(ms)
    fakeTime = fakeTime + (ms or C.sweepMs)
    BR.Sched.step(fakeTime)
end

local ORDER = {
    'emote_club_podium', 'emote_club_groove', 'emote_club_drop', 'emote_shuffle',
    'emote_techno_karate', 'emote_techno_monkey', 'emote_beach_boxing', 'emote_jumper',
    'emote_sand_trip', 'emote_casino_sway', 'emote_casino_bounce', 'emote_beach_party',
    'emote_beach_party_2', 'emote_island_club', 'emote_uncle_disco', 'emote_the_woogie',
}
local E = ORDER   -- E[1]..E[16], for brevity below

local function eight() return { E[1], E[2], E[3], E[4], E[5], E[6], E[7], E[8] } end
local function slotted(list)
    local eq = {}
    for k, id in ipairs(list) do if id ~= '' then eq['emote' .. k] = id end end
    return eq
end

-- ---------------------------------------------------------------------------
describe('0. this run\'s season, with dev mode OFF')
-- ---------------------------------------------------------------------------
do
    reset()
    local season = BR.Season.current()
    local want = season >= FROM and (ROW.untilSeason == nil or season < ROW.untilSeason)
    if RUN_SEASON == nil then
        ok(season == BR.Config.Seasons.latest, 'no br_season: the server runs the latest season', season)
    else
        ok(season == math.tointeger(tonumber(RUN_SEASON)), 'the server runs BR_SEASON', season)
    end
    ok(replicated.br_seasonServed == tostring(season), 'and replicated that season to the clients',
        replicated.br_seasonServed)
    ok(dev == false and BR.Season.has('emotes') == want,
        ('Season %d: emotes are %s, with dev mode off'):format(season, want and 'on' or 'off'))
    player(1, { owned = { E[4] }, equipped = { emote1 = E[4] } })
    local st = lastState(1)
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    if want then
        ok(st and type(st.emotes) == 'table' and st.emotes[1] == E[4], 'push carries the wheel', st and st.emotes)
        ok(#records(1) == 1, 'and a PLAY is published')
    else
        ok(st and st.emotes == nil, 'push carries no wheel', st and st.emotes)
        ok(#records(1) == 0, 'and a PLAY is not published')
    end
    restore()
end

-- ---------------------------------------------------------------------------
describe('1. the catalogue')
-- ---------------------------------------------------------------------------
do
    reset()
    ok(#C.order == 16, '16 valid rows', #C.order)
    local same = true
    for i, id in ipairs(ORDER) do if C.order[i] ~= id then same = false end end
    ok(same, 'in the seam order')
    for _, id in ipairs(C.order) do
        local item = BR.Config.MarketIndex[id]
        local row = BR.Emotes.row(id)
        ok(item and item.kind == 'emote' and item.price == 250 and item.sub == 'Dance'
           and item.seasonName == 'Founders' and item.purchasable == true,
           id .. ' is a 250-Volt Founders dance in the index')
        ok(row and row.track == 'emotes/' .. id .. '.ogg', id .. ' names its track')
        ok(BR.Config.buyable(id) ~= nil, id .. ' is buyable')
    end
    ok(BR.Config.defaultItem('emote') == nil, 'there is no free dance ("no free ones")')
    local inSeason = false
    for _, s in ipairs(BR.Config.Market.seasons) do
        for _, it in ipairs(s.items or {}) do
            if type(it) == 'table' and tostring(it.id):match('^emote_') then inSeason = true end
        end
    end
    ok(not inSeason, 'and no emote is in any season.items, where the storefront walks')

    local function row(over)
        local r = { id = 'emote_test_row', name = 'T', dict = 'd', clip = 'c', flag = 1,
                    durationMs = 12000, track = 'emotes/emote_test_row.ogg', price = 250 }
        for k, v in pairs(over) do r[k] = v end
        return r
    end
    ok(BR.Emotes.rowProblem(row({})) == nil, 'a good row passes')
    for name, over in pairs({
        ['a bad prefix'] = { id = 'dance_x' },
        ['an over-long id'] = { id = 'emote_' .. string.rep('a', 49) },
        ['a float flag'] = { flag = 1.0 },
        ['flag 16'] = { flag = 16 }, ['flag 32'] = { flag = 32 }, ['flag 1025'] = { flag = 1025 },
        ['durationMs 999'] = { durationMs = 999 }, ['durationMs 600001'] = { durationMs = 600001 },
        ["track 'x.ogg'"] = { track = 'x.ogg' },
        ['a zero price'] = { price = 0 }, ['a float price'] = { price = 250.5 },
        ['a duplicate id'] = { id = 'emote_shuffle' },
    }) do
        ok(BR.Emotes.rowProblem(row(over)) ~= nil, 'rowProblem refuses ' .. name)
    end
    ok(BR.Emotes.rowProblem(row({ track = nil })) == nil, 'a row with no track is allowed (plays silent)')
end

-- ---------------------------------------------------------------------------
describe('2. the season is the gate, and dev mode is not')
-- ---------------------------------------------------------------------------
do
    reset()
    bootAt(tostring(OFF)); dev = false
    ok(BR.Season.has('emotes') == false, ('Season %d, dev off -> closed'):format(OFF))
    dev = true
    ok(BR.Season.has('emotes') == false, ('Season %d, dev ON -> still closed'):format(OFF))
    bootAt(tostring(FROM)); dev = false
    ok(BR.Season.has('emotes') == true, ('Season %d, dev off -> open'):format(FROM))
    bootAt(nil)
    ok(BR.Season.current() == BR.Config.Seasons.latest and BR.Season.has('emotes') == true,
        'no br_season -> the latest season -> open')
    -- THE SERVER'S SEASON IS THE ONE IT BOOTED WITH: a convar typed afterwards
    -- moves nothing until the next boot.
    bootAt(tostring(FROM))
    convars.br_season = tostring(OFF)
    ok(BR.Season.has('emotes') == true, 'br_season changed after boot -> still open until br_core restarts')
    ok(not pcall(BR.Season.has, 'emote'), 'and a typo\'d id raises in this suite')
    restore()
end

-- ---------------------------------------------------------------------------
describe('3. load')
-- ---------------------------------------------------------------------------
do
    reset(); gateOpen()
    player(1, {
        owned = { E[1], E[2], E[3], 'chute_crimson' },
        equipped = { emote1 = E[1], emote3 = E[2], emote4 = 'chute_crimson', emote5 = E[9],
                     emote6 = E[1], emote7 = 'nonsense', chute = 'chute_crimson' },
    })
    local st = lastState(1)
    local want = { E[1], '', E[2], '', '', '', '', '' }
    local same = st and type(st.emotes) == 'table' and #st.emotes == 8
    for k = 1, 8 do if not st or st.emotes[k] ~= want[k] then same = false end end
    ok(same, 'equip_emoteN -> 8 strings with holes as \'\'; unowned, non-emote and duplicate ids dropped',
       st and table.concat(st.emotes or {}, ','))
    local leak = false
    for k in pairs(st.equipped or {}) do if tostring(k):match('^emote') then leak = true end end
    ok(not leak, 'equipped carries no emote slot keys')
    ok(st.equipped.chute == 'chute_crimson', 'and the ordinary kinds are untouched')
    ok(has(st.owned, E[1]), 'owned carries the emote ids while the gate is open')

    gateClosed()
    BR.Market.push(1)
    st = lastState(1)
    ok(st.emotes == nil, 'gate closed -> no emotes field')
    local anyEmote = false
    for _, id in ipairs(st.owned) do if id:match('^emote_') then anyEmote = true end end
    ok(not anyEmote, 'and no emote ids in owned')
    ok(has(st.owned, 'chute_crimson'), 'but the rest of owned is there')
    restore()
end

-- ---------------------------------------------------------------------------
describe('4. equip')
-- ---------------------------------------------------------------------------
do
    reset(); gateOpen()
    player(1, { owned = ORDER })
    fire(BR.Net.MARKET_EQUIP, 1, { id = E[1] })
    local _, args = reqOf('br:ddb:equip')
    ok(args and args[3] == 'emote1' and args[4] == E[1] and args[5] == false,
       'the first goes into emote1, ownership condition on', args and args[3])
    answer('br:ddb:equip', true)
    fire(BR.Net.MARKET_EQUIP, 1, { id = E[2] })
    _, args = reqOf('br:ddb:equip')
    ok(args and args[3] == 'emote2', 'the next into emote2')
    answer('br:ddb:equip', true)

    local before = countOf('br:ddb:equip')
    fire(BR.Net.MARKET_EQUIP, 1, { id = E[1] })
    ok(countOf('br:ddb:equip') == before, 'an id already on the wheel asks nothing')

    for i = 3, 8 do
        fire(BR.Net.MARKET_EQUIP, 1, { id = E[i] })
        answer('br:ddb:equip', true)
    end
    before = countOf('br:ddb:equip')
    sent = {}
    fire(BR.Net.MARKET_EQUIP, 1, { id = E[9] })
    ok(countOf('br:ddb:equip') == before, 'a full wheel without replace asks nothing')
    ok(has(toasts(1), 'That could not be equipped.'), 'and says so in the existing words')

    fire(BR.Net.MARKET_EQUIP, 1, { id = E[9], replace = E[3] })
    _, args = reqOf('br:ddb:equip')
    ok(args and args[3] == 'emote3' and args[4] == E[9], 'replace -> the replaced dance\'s slot', args and args[3])
    answer('br:ddb:equip', false, { refused = 'not owned' })
    ok(lastState(1).emotes[3] == E[3], 'a refused write rolls back to what was there')

    -- DUPLICATE SCENARIO B: replace B@2 with E9 in flight, equip B into 5,
    -- E9 fails -> B appears once.
    fire(BR.Net.MARKET_UNEQUIP, 1, { id = E[5] })
    answer('br:ddb:unequip', true)
    fire(BR.Net.MARKET_EQUIP, 1, { id = E[9], replace = E[2] })
    local e9req = reqOf('br:ddb:equip')
    fire(BR.Net.MARKET_EQUIP, 1, { id = E[2] })
    _, args = reqOf('br:ddb:equip')
    ok(args and args[3] == 'emote5', 'B goes into the free slot 5 while slot 2 is in flight', args and args[3])
    answer('br:ddb:equip', true)
    answer('br:ddb:equip', false, { error = 'boom' }, e9req)
    local st = lastState(1)
    local n = 0
    for k = 1, 8 do if st.emotes[k] == E[2] then n = n + 1 end end
    ok(n == 1, 'scenario B: B is on the wheel exactly once', table.concat(st.emotes, ','))
    ok(st.emotes[2] == '', 'and the failed slot is left empty rather than duplicated')

    -- A BUSY SLOT REFUSES WITH NO CALL.
    fire(BR.Net.MARKET_EQUIP, 1, { id = E[10], replace = E[1] })
    before = countOf('br:ddb:equip')
    sent = {}
    fire(BR.Net.MARKET_EQUIP, 1, { id = E[11], replace = E[10] })
    ok(countOf('br:ddb:equip') == before, 'a slot with a write in flight is not written again')
    ok(#toasts(1) == 0, 'silently -- the push re-syncs the page')
    answer('br:ddb:equip', true)

    -- THE RATE CAP: twenty slot writes in ten seconds, then no more.
    reset(); gateOpen()
    player(2, { owned = ORDER })
    for _ = 1, 10 do
        fire(BR.Net.MARKET_EQUIP, 2, { id = E[1] }); answer('br:ddb:equip', true)
        fire(BR.Net.MARKET_UNEQUIP, 2, { id = E[1] }); answer('br:ddb:unequip', true)
    end
    ok(countOf('br:ddb:equip') + countOf('br:ddb:unequip') == 20, 'twenty writes go through')
    fire(BR.Net.MARKET_EQUIP, 2, { id = E[1] })
    ok(countOf('br:ddb:equip') == 10, 'the 21st in ten seconds is refused')
    fakeTime = fakeTime + 10001
    fire(BR.Net.MARKET_EQUIP, 2, { id = E[1] })
    ok(countOf('br:ddb:equip') == 11, 'and the window reopens')

    -- GATE CLOSED.
    reset(); gateOpen()
    player(3, { owned = ORDER })
    gateClosed()
    fire(BR.Net.MARKET_EQUIP, 3, { id = E[1] })
    ok(BR.Market.equip(3, E[2], true) == nil, 'BR.Market.equip refuses an emote')
    ok(countOf('br:ddb:equip') == 0, 'gate closed -> nothing asked')
    -- ...while the ordinary kinds are untouched by it.
    player(4, { owned = { 'chute_crimson' } })
    fire(BR.Net.MARKET_EQUIP, 4, { id = 'chute_crimson' })
    ok(countOf('br:ddb:equip') == 1, 'and a chute still equips')
    restore()
end

-- ---------------------------------------------------------------------------
describe('5. unequip')
-- ---------------------------------------------------------------------------
do
    reset(); gateOpen()
    player(1, { owned = ORDER, equipped = slotted({ E[1], E[2], E[3] }) })
    fire(BR.Net.MARKET_UNEQUIP, 1, { id = E[3] })
    local _, args = reqOf('br:ddb:unequip')
    ok(args and args[2] == licenseOfSrc(1) and args[3] == 'emote3', 'REMOVE emote3', args and args[3])
    answer('br:ddb:unequip', true)
    ok(lastState(1).emotes[3] == '', 'and the slot is empty')

    sent = {}
    fire(BR.Net.MARKET_UNEQUIP, 1, { id = E[2] })
    answer('br:ddb:unequip', false, { error = 'boom' })
    ok(lastState(1).emotes[2] == E[2], 'a failure puts it back')
    ok(has(toasts(1), 'That could not be unequipped.'), 'and says so')

    local before = countOf('br:ddb:unequip')
    fire(BR.Net.MARKET_UNEQUIP, 1, { id = E[9] })
    ok(countOf('br:ddb:unequip') == before, 'a dance not on the wheel asks nothing')

    -- DUPLICATE SCENARIO A: unequip A@3 in flight, equip A -> slot 1, the
    -- REMOVE fails -> A only in slot 1, and slot 3 was not picked while busy.
    reset(); gateOpen()
    local A, X = E[5], E[6]
    player(2, { owned = ORDER, equipped = slotted({ '', X, A }) })
    fire(BR.Net.MARKET_UNEQUIP, 2, { id = A })
    local removeReq = reqOf('br:ddb:unequip')
    fire(BR.Net.MARKET_EQUIP, 2, { id = A })
    _, args = reqOf('br:ddb:equip')
    ok(args and args[3] == 'emote1', 'scenario A: the equip takes slot 1', args and args[3])
    answer('br:ddb:equip', true)
    answer('br:ddb:unequip', false, { error = 'boom' }, removeReq)
    local st = lastState(2)
    ok(st.emotes[1] == A and st.emotes[3] == '', 'scenario A: A stays only in slot 1', table.concat(st.emotes, ','))

    -- ...and the busy guard is what keeps a SET off a slot with a REMOVE in
    -- flight: with 1 and 2 full, the lowest empty slot is 3, and it is busy.
    reset(); gateOpen()
    player(3, { owned = ORDER, equipped = slotted({ E[1], E[2], E[3] }) })
    fire(BR.Net.MARKET_UNEQUIP, 3, { id = E[3] })
    fire(BR.Net.MARKET_EQUIP, 3, { id = E[9] })
    _, args = reqOf('br:ddb:equip')
    ok(args and args[3] == 'emote4', 'firstFree skips a slot whose REMOVE is in flight', args and args[3])

    gateClosed()
    before = countOf('br:ddb:unequip')
    fire(BR.Net.MARKET_UNEQUIP, 3, { id = E[1] })
    ok(countOf('br:ddb:unequip') == before, 'MARKET_UNEQUIP with the gate closed does nothing')
    restore()

    -- server/market.lua WITHOUT config/emotes.lua (test_volts, test_tutorial
    -- load it that way): the new door must not throw.
    local env = setmetatable({}, { __index = _G })
    env.BR = {}
    local envHandlers = {}
    env.AddEventHandler = function(name, fn)
        envHandlers[name] = envHandlers[name] or {}
        envHandlers[name][#envHandlers[name] + 1] = fn
    end
    env.RegisterCommand = function() end
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
                         'br_lib/shared/identity.lua', 'br_lib/shared/xp.lua',
                         'br_lib/config/market.lua', 'br_core/server/market.lua' }) do
        assert(loadfile(RES .. f, 't', env))()
    end
    local threw = false
    local function envFire(name, src, ...)
        env.source = src
        for _, fn in ipairs(envHandlers[name] or {}) do
            local okc, err = pcall(fn, ...)
            if not okc then threw = err end
        end
    end
    envFire(env.BR.Net.MARKET_UNEQUIP, 1, { id = E[1] })
    envFire(env.BR.Net.MARKET_STATE, 1)
    envFire(env.BR.Net.MARKET_EQUIP, 1, { id = 'chute_crimson', replace = 'x' })
    ok(threw == false, 'market.lua without the emote config does not throw', threw)
    ok(env.BR.Emotes == nil, 'and nothing invented BR.Emotes for it')
end

-- ---------------------------------------------------------------------------
describe('6. buy')
-- ---------------------------------------------------------------------------
do
    reset(); gateOpen()
    player(1, { owned = {} })
    fire(BR.Net.MARKET_BUY, 1, { id = 'emote_shuffle' })
    local _, args = reqOf('br:ddb:purchase')
    ok(args and args[3] == 'emote_shuffle' and args[4] == 250, 'a dance is bought at 250 Volts')
    answer('br:ddb:purchase', true, { balance = 4750 })
    ok(has(toasts(1), 'Shuffle equipped.'), 'a free slot -> "Shuffle equipped."', toasts(1)[1])
    _, args = reqOf('br:ddb:equip')
    ok(args and args[3] == 'emote1', 'into slot 1')

    reset(); gateOpen()
    player(2, { owned = eight(), equipped = slotted(eight()) })
    fire(BR.Net.MARKET_BUY, 2, { id = 'emote_shuffle' })
    ok(countOf('br:ddb:purchase') == 0, 'an owned dance is not bought twice')
    fire(BR.Net.MARKET_BUY, 2, { id = E[9] })
    answer('br:ddb:purchase', true, { balance = 4750 })
    ok(has(toasts(2), BR.Config.MarketIndex[E[9]].name .. ' bought -- your emote wheel is full.'),
       'a full wheel -> the full-wheel sentence', toasts(2)[1])
    ok(not has(toasts(2), 'That could not be equipped.'), 'and no refusal beside it')
    ok(countOf('br:ddb:equip') == 0, 'and no equip asked')

    reset(); gateOpen()
    player(3, { owned = {} })
    gateClosed()
    fire(BR.Net.MARKET_BUY, 3, { id = 'emote_shuffle' })
    ok(has(toasts(3), 'That item is not for sale.'), 'gate closed -> not for sale')
    ok(countOf('br:ddb:purchase') == 0, 'and br:ddb:purchase is never asked')
    restore()
end

-- ---------------------------------------------------------------------------
describe('7. play')
-- ---------------------------------------------------------------------------
local function stage(over)
    reset(); gateOpen()
    over = over or {}
    player(1, { owned = { E[4], E[5] }, equipped = { emote1 = E[4] }, state = over.state,
                pos = over.pos, posAt = over.posAt, bucket = 1 })
    player(2, { pos = { x = 30.0, y = 0.0, z = 0.0 }, bucket = 1 })                              -- near
    player(3, { pos = { x = 500.0, y = 0.0, z = 0.0 }, bucket = 1 })                             -- far teammate
    player(4, { pos = { x = 10.0, y = 0.0, z = 0.0 }, bucket = 2, state = BR.PlayerState.WARMUP }) -- other bucket
    player(5, { pos = { x = 10.0, y = 0.0, z = 0.0 }, bucket = 0, state = BR.PlayerState.LOBBY }) -- lobby bucket
    player(6, { pos = { x = 900.0, y = 0.0, z = 0.0 }, bucket = 9 })                             -- spectator
    watching[6] = 2
    player(7, { pos = { x = 20.0, y = 0.0, z = 0.0 }, bucket = 1, posAt = fakeTime - 2000 })    -- stale
    sent = {}
end

do
    --- `why` is the console line's reason, or nil for the silent refusals
    --- (the gate, which says nothing on a public box).
    local function refusedCase(name, setup, why, id)
        stage()
        if setup then setup() end
        printed = {}
        id = id or E[4]
        fire(BR.Net.EMOTE_PLAY, 1, { id = id })
        ok(allRecords() == 0, 'no record: ' .. name)
        if why then
            ok(has(printed, ('[br_core] emotes: 1 play "%s" refused -- %s'):format(id, why)),
               'and one console line: ' .. why, printed[1])
        else
            ok(#printed == 0, 'and not a word: ' .. name, printed[1])
        end
        restore()
    end
    refusedCase('the gate is closed', function() gateClosed() end, nil)
    refusedCase('an unknown id', nil, 'no such emote', 'emote_nope')
    refusedCase('owned but not on the wheel', nil, 'not on the wheel', E[5])
    refusedCase('in the lobby', function() entries[1].state = BR.PlayerState.LOBBY end, 'state lobby')
    refusedCase('downed', function() entries[1].state = BR.PlayerState.DBNO end, 'state dbno')
    refusedCase('riding a vehicle', function() riding[entries[1].ped] = 77 end, 'in a vehicle')
    refusedCase('using an item', function() using[1] = { slot = 2 } end, 'using an item')
    refusedCase('no position', function() entries[1].pos = nil end, 'position not fresh')
    refusedCase('a 2000 ms old position', function() entries[1].posAt = fakeTime - 2000 end, 'position not fresh')

    stage()
    for i = 1, 6 do
        fakeTime = fakeTime + 10
        fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
        ok(#records(1) >= i, 'play ' .. i .. ' in ten seconds is published')
    end
    sent = {}
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    ok(allRecords() == 0, 'the 7th in ten seconds is not')

    stage()
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    local r = records(1)[1]
    ok(r ~= nil, 'the dancer is sent their own record')
    ok(r and r.src == 1 and r.id == E[4] and r.tStart == fakeTime and r.tSent == fakeTime
       and r.durationMs == 12000 and r.x == 0.0 and r.y == 0.0 and r.z == 0.0 and r.tEnd == nil,
       'tStart = tSent = now, durationMs 12000, x/y/z from the roster')
    ok(#records(2) == 1, 'a same-bucket player 30 m away is sent it')
    ok(#records(6) == 1, 'and a spectator watching a player in range')
    ok(#records(3) == 0, 'NOT a teammate 500 m away')
    ok(#records(4) == 0, 'NOT a WARMUP player in another bucket')
    ok(#records(5) == 0, 'NOT a lobby-bucket player who still holds the matchId')
    ok(#records(7) == 0, 'NOT a player whose position is stale')
    restore()

    -- A SPECTATOR IS ASKED THE WATCHED PLAYER'S BUCKET (#215, rule 8): two
    -- concurrent matches share the map in their own buckets, and the record
    -- carries the dancer's x/y/z, which the roster withholds across matches.
    -- Player 6 above (bucket 9, watching 2 in bucket 1) is the positive
    -- control: an admin watching from the lobby still hears.
    stage()
    player(9, { pos = { x = 900.0, y = 0.0, z = 0.0 }, bucket = 2 })
    watching[9] = 4   -- 4 is in bucket 2, 10 m from the dancer in bucket 1
    sent = {}
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    ok(#records(6) == 1, 'a spectator whose target shares the dancer\'s bucket is sent it')
    ok(#records(9) == 0, 'NOT a spectator whose target is in range but in another match\'s bucket')
    sweep()
    local act = BR.Emotes.active(1)
    ok(#records(9) == 0 and act ~= nil and not has(act.sentTo, 9), 'nor by the sweep after it')
    watching[9] = nil
    restore()
end

-- ---------------------------------------------------------------------------
describe('8. stop and the sweep')
-- ---------------------------------------------------------------------------
do
    stage()
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    entries[2].state = BR.PlayerState.BUS
    entries[2].pos = { x = 900.0, y = 0.0, z = 0.0 }
    fakeTime = fakeTime + 3000
    sent = {}
    fire(BR.Net.EMOTE_STOP, 1)
    local a, b, c = records(1)[1], records(2)[1], records(6)[1]
    ok(a and a.tEnd == fakeTime and a.tSent == fakeTime, 'the stop re-sends with tEnd = now')
    ok(b and b.tEnd == fakeTime, 'to a listener who has since boarded the bus and left range')
    ok(c and c.tEnd == fakeTime, 'and to the spectator')
    ok(allRecords() == 3, 'and to nobody the start did not reach', allRecords())

    stage()
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    fakeTime = fakeTime + 12001
    sent = {}
    fire(BR.Net.EMOTE_STOP, 1)
    ok(allRecords() == 0, 'a stop after the natural end sends nothing')

    stage()
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    sent = {}
    sweep(12001)
    ok(allRecords() == 0 and BR.Emotes.active(1) == nil, 'the sweep drops an ended dance silently')

    for name, mut in pairs({
        DBNO = function() entries[1].state = BR.PlayerState.DBNO end,
        vehicle = function() riding[entries[1].ped] = 9 end,
        item = function() using[1] = { slot = 1 } end,
        ['the gate closing mid-dance'] = function() gateClosed() end,
    }) do
        stage()
        fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
        sent = {}
        mut()
        sweep()
        local r = records(1)[1]
        ok(r and r.tEnd == fakeTime, 'the sweep stops the dance on ' .. name)
        ok(BR.Emotes.active(1) == nil, 'and forgets it (' .. name .. ')')
        restore()
    end

    stage()
    player(8, { pos = { x = 400.0, y = 0.0, z = 0.0 }, bucket = 1 })
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    ok(#records(8) == 0, 'a player out of range is not sent the start')
    sweep()
    entries[8].pos = { x = 15.0, y = 0.0, z = 0.0 }
    entries[8].posAt = fakeTime
    entries[7].posAt = fakeTime
    sent = {}
    sweep(C.sweepMs)
    local late = records(8)[1]
    ok(late and late.tSent == fakeTime and late.tStart < fakeTime, 'the sweep DELIVERS to a walk-in, tSent = sweep time')
    ok(#records(7) == 1, 'and to a player whose position became fresh')
    ok(#records(1) == 0 and #records(2) == 0, 'and never re-sends to a sentTo member')
    sent = {}
    entries[8].posAt = fakeTime + C.sweepMs
    sweep()
    ok(allRecords() == 0, 'a second sweep sends nothing new')

    stage()
    fire(BR.Net.EMOTE_PLAY, 1, { id = E[4] })
    entries[2] = nil
    fire('playerDropped', 2)
    local act = BR.Emotes.active(1)
    ok(act and not has(act.sentTo, 2), 'a leaver is removed from other dances\' sentTo')
    sent = {}
    entries[1] = nil
    fire('playerDropped', 1)
    ok(#records(6) == 1 and records(6)[1].tEnd ~= nil, 'a dancer who drops ends the dance for its listeners')
    ok(BR.Emotes.active(1) == nil, 'and the record is gone')
    restore()

    local errored = false
    for _, l in ipairs(printed) do if l:find('errored', 1, true) then errored = l end end
    ok(errored == false, 'the sweep never errored', errored)
end

-- ---------------------------------------------------------------------------
describe('9. bremotegrant')
-- ---------------------------------------------------------------------------
do
    local cmd = commands.bremotegrant
    ok(cmd ~= nil and cmd.restricted == true, 'registered, restricted')
    local function run(src, ...) printed = {}; cmd.fn(src, { ... }) end
    local function said(text)
        for _, l in ipairs(printed) do if l:find(text, 1, true) then return true end end
        return false
    end

    reset(); gateOpen()
    player(3, { name = 'Epyc' })
    run(3, 'Epyc', 'emote_shuffle')
    ok(said('server-console only') and countOf('br:ddb:ownedAdd') == 0, 'a player cannot run it')

    gateClosed()
    run(0, 'Epyc', 'emote_shuffle')
    ok(said('bremotegrant: emotes are off on this box'), 'gate closed -> the off line')
    ok(countOf('br:ddb:ownedAdd') == 0, 'and nothing asked')
    restore(); gateOpen()

    run(0)
    local rows = 0
    for _, l in ipairs(printed) do if l:match('^  emote_') then rows = rows + 1 end end
    ok(rows == 16 and said('usage: bremotegrant'), 'no args lists 16 plus the usage', rows)

    run(0, 'Epyc', 'emote_shuffle')
    local _, args = reqOf('br:ddb:ownedAdd')
    ok(args and args[2] == licenseOfSrc(3) and args[3] == 'emote_shuffle', 'an exact name asks ownedAdd with the license and id')
    sent = {}
    answer('br:ddb:ownedAdd', true)
    ok(BR.Market.owns(3, 'emote_shuffle'), 'reply ok -> owned')
    ok(BR.Market.slotOf(3, 'emote_shuffle') == 1, 'slotted, since the wheel was empty')
    ok(lastState(3) ~= nil and has(lastState(3).owned, 'emote_shuffle'), 'and pushed')
    ok(said('Epyc (#3) emote_shuffle -- granted'), 'and the console is told')

    player(4, { name = 'Big Dave' })
    run(0, '#4', E[1])
    _, args = reqOf('br:ddb:ownedAdd')
    ok(args and args[2] == licenseOfSrc(4) and args[3] == E[1], '#<id> grants')
    answer('br:ddb:ownedAdd', true)
    local n0 = countOf('br:ddb:ownedAdd')
    run(0, 'big', 'dave', E[2])
    ok(countOf('br:ddb:ownedAdd') == n0 + 1, 'a name with a space, rejoined, case-insensitive')
    answer('br:ddb:ownedAdd', false, { refused = 'already owned' })
    ok(BR.Market.owns(4, E[2]), 'an already-owned reply sets owned')
    ok(said('-- already owned'), 'and says so')

    player(5, { name = 'Twin' })
    player(6, { name = 'twin' })
    n0 = countOf('br:ddb:ownedAdd')
    run(0, 'Twin', E[3])
    ok(said('2 players are called "Twin"') and said('(#5)') and said('(#6)'), 'two exact matches are listed with #ids')
    ok(countOf('br:ddb:ownedAdd') == n0, 'and nothing is asked')

    run(0, 'Epy', E[3])
    ok(said('nobody is called exactly "Epy"') and said('Epyc (#3)'), 'a partial name lists candidates')
    ok(countOf('br:ddb:ownedAdd') == n0, 'and grants NOTHING')
    run(0, 'Zed', E[3])
    ok(said('nobody connected is called "Zed"'), 'and no candidate at all says so')
    run(0, 'Epyc', 'emote_nope')
    ok(said('no emote "emote_nope"'), 'an unknown emote is named')
    run(0, '#99', E[3])
    ok(said('no player #99 connected'), 'an unknown #id is named')

    -- 'all', sequentially.
    reset(); gateOpen()
    player(7, { name = 'Allie', owned = { E[1], E[2] } })
    run(0, 'Allie', 'all')
    ok(countOf('br:ddb:ownedAdd') == 1, "'all' asks one at a time")
    for _ = 1, 14 do answer('br:ddb:ownedAdd', true) end
    ok(countOf('br:ddb:ownedAdd') == 14, "'all' asks once per unowned id", countOf('br:ddb:ownedAdd'))
    ok(said('Allie (#7) 14 granted, 2 already owned, 0 failed'), 'and ends with a tally')
    local seen = {}
    local dup = false
    for _, f in ipairs(fired) do
        if f.event == 'br:ddb:ownedAdd' then
            if seen[f.args[3]] then dup = true end
            seen[f.args[3]] = true
        end
    end
    ok(not dup and not seen[E[1]] and not seen[E[2]], 'never asking for one already owned')

    -- A recycled id mid-'all' stops it.
    reset(); gateOpen()
    player(8, { name = 'Swap' })
    run(0, 'Swap', 'all')
    answer('br:ddb:ownedAdd', true)
    local pendingReq = reqOf('br:ddb:ownedAdd')
    entries[8] = nil
    fire('playerDropped', 8)
    licKey[8] = 'somebody_else'
    player(8, { name = 'Other' })
    local before = countOf('br:ddb:ownedAdd')
    answer('br:ddb:ownedAdd', true, nil, pendingReq)
    ok(said('#8 is somebody else now -- stopped'), 'a license swap mid-all stops the run')
    ok(countOf('br:ddb:ownedAdd') == before, 'and asks nothing more')
    ok(not BR.Market.owns(8, E[2]), 'and the new holder of #8 was handed nothing')
    ok(not said(E[2] .. ' -- granted'), 'and the answer that landed on the new holder is not reported as a grant')
    ok(#toasts(8) == 0, 'nor turned into a toast at them')
    restore()

    -- THE EXEMPTION. Read off devgate.lua, and proved through its wrap.
    local fh = assert(io.open(RES .. 'br_lib/shared/devgate.lua', 'r'))
    local src = fh:read('a'); fh:close()
    ok(src:match('\nlocal EXEMPT = {[^\n]*bremotegrant = true') ~= nil, 'devgate EXEMPT contains bremotegrant')
    dev = false
    wrappedRegister('bremotegrant', function() return 'ran' end, true)
    wrappedRegister('bremote', function() return 'ran' end, false)
    ok(rawRegistered.bremotegrant and rawRegistered.bremotegrant.fn() == 'ran',
       'through the wrap, bremotegrant reaches the raw door unwrapped')
    printed = {}
    ok(rawRegistered.bremote and rawRegistered.bremote.fn(0, {}, '') == nil
       and said('bremote is dev-mode only'), 'while a devgate-wrapped bremote refuses with dev off')
    restore()
end

-- ---------------------------------------------------------------------------
describe('traps')
-- ---------------------------------------------------------------------------
do
    local fh = assert(io.open(RES .. 'br_core/server/market.lua', 'r'))
    local src = fh:read('a'); fh:close()
    ok(not src:find('done(true, nil)', 1, true), 'market.lua never writes done(true, nil)')
    ok(src:find('done(true, nil, left)', 1, true) ~= nil, 'and still writes done(true, nil, left)')
end

if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m, %d passed'):format(fail, pass))
    os.exit(1)
end
realPrint(('\27[32m%d passed\27[0m (Season %s)'):format(pass, RUN_SEASON or 'unset'))
