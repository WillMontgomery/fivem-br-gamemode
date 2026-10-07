-- Locker v2 (#28, Season 2): the appearance, the server's records, the client,
-- and Season 1 left exactly as it was.
--
-- ═══ WHAT THIS DRIVES ═══
--
-- The REAL files, each in its own Lua environment so a client and a server
-- never share a BR table:
--
--   br_lib/shared/appearance.lua     the schema, its validator and its JSON
--   br_core/server/locker2.lua       over a modeled br_ddb that keeps rows
--   br_core/client/locker2.lua       over a modeled ped, models, kvp and
--   br_core/client/locker2shot.lua   threads (coroutines on a fake clock)
--   br_core/client/locker.lua        Season 1's locker, beside and without v2
--   br_core/client/lobbycam.lua      the camera's focus presets
--
-- ═══ SEASON 1 IS PROVED BY A TRACE ═══
--
-- Season 1's locker is the finished product and may not change. So the same
-- session -- the first lobby, a pick, a spin, the chosen id -- is played twice:
-- once with client/locker.lua alone (BR.LockerV2 absent, which is every line
-- of it as it was at 4af6bb48), once with Locker v2 loaded beside it on a
-- Season 1 client. Every native call, event, kvp write and server event is
-- recorded, and the two records must be identical.
--
-- Run standalone:  lua tools/test_locker2.lua

local realPrint = print
local RES = 'resources/[fivem-royale]/'

local pass, fail = 0, 0
local function ok(cond, label, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s%s'):format(label, detail ~= nil and ('  (' .. tostring(detail) .. ')') or ''))
    end
end
local function eq(got, want, label)
    ok(got == want, label, ('got %s, want %s'):format(tostring(got), tostring(want)))
end
local function describe(name) realPrint('\n' .. name) end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

local function deepCopy(v)
    if type(v) ~= 'table' then return v end
    local o = {}
    for k, x in pairs(v) do o[k] = deepCopy(x) end
    return o
end

--- A fresh environment: the standard library, and nothing of anybody's BR.
local function newEnv()
    local env = {}
    setmetatable(env, { __index = _G })
    env._G = env
    return env
end

local function loadInto(env, file)
    local chunk, err = loadfile(RES .. file, 't', env)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. file .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

local function hashOf(s)
    local h = 0
    for i = 1, #s do h = (h * 31 + s:byte(i)) % 2147483647 end
    return h
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 1. THE APPEARANCE (br_lib/shared/appearance.lua)
-- ═══════════════════════════════════════════════════════════════════════════

local shared = newEnv()
shared.print = function() end
for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/config/peds.lua',
                     'br_lib/config/locker2.lua', 'br_lib/shared/appearance.lua' }) do
    if f == 'br_lib/config/peds.lua' then
        shared.BR = shared.BR or {}
        shared.BR.Config = shared.BR.Config or {}
    end
    loadInto(shared, f)
end
local A = shared.BR.Appearance

describe('appearance.default')
do
    local m = A.default('m')
    ok(A.validate(m), 'the male default is an appearance')
    ok(A.validate(A.default('f')), 'and the female one')
    eq(m.o[3][1], 0, 'eyebrows are the first, never none')
    eq(m.o[1][1], 255, 'every other overlay is none')
    eq(m.o[5][2], 100, 'opacities are 100')
    eq(m.c[8][1], 15, 'the male undershirt is none (15)')
    eq(A.default('f').c[8][1], 14, 'the female undershirt is none (14)')
    eq(m.p[1][1], -1, 'no props')
    eq(#m.ff, 20, 'twenty face features')
end

describe('appearance.encode')
do
    local s = A.encode(A.default('m'))
    ok(s:sub(1, 33) == '{"v":1,"s":"m","sk":0,"e":0,"h":[', 'the canonical key order', s:sub(1, 40))
    ok(#s <= 2048, 'within 2048 bytes')
    local back = A.decode(s)
    ok(back ~= nil and A.encode(back) == s, 'decode then encode is the same string')
    ok(A.equal(back, A.default('m')), 'and equal() agrees')
    ok(not A.equal(A.default('m'), A.default('f')), 'two sexes are not equal')
    local a = A.default('f')
    a.sk, a.e, a.h, a.ff[1], a.ff[20] = 45, 30, { 63, 12 }, -100, 100
    a.o[2] = { 254, 0, 63 }
    a.c[11] = { 1023, 31 }
    a.p[5] = { 3, 2 }
    local enc = A.encode(a)
    ok(enc ~= nil and A.equal(A.decode(enc), a), 'every edge of every range survives the round trip')
    ok(A.decode(' ' .. enc .. ' ') ~= nil, 'whitespace around it is read')
end

describe('appearance.none')
do
    -- #28 review: an overlay of none shows no opacity or color, so neither is
    -- part of the look -- or a press nobody can see makes a draft dirty.
    local a = A.default('m')
    a.o[2] = { 255, 40, 9 }
    eq(A.encode(a), A.encode(A.default('m')), 'an overlay of none is written with opacity 100 and color 0')
    ok(A.equal(a, A.default('m')), 'so two looks that differ only there are equal')
    ok(A.validate(a), 'and the table itself is still an appearance')
    a.o[2] = { 3, 40, 9 }
    ok(not A.equal(a, A.default('m')), 'an overlay that is on keeps its own opacity and color')
    ok(A.encode(a):find('[3,40,9]', 1, true) ~= nil, 'written as they are')
end

describe('appearance.validate')
do
    local function bad(mut, label)
        local a = A.default('m')
        mut(a)
        local okv = A.validate(a)
        ok(not okv, label)
        ok(A.encode(a) == nil, label .. ' (and will not encode)')
    end
    bad(function(a) a.v = 2 end, 'a version that is not 1')
    bad(function(a) a.v = 1.0 end, 'a float version')
    bad(function(a) a.s = 'x' end, 'a sex that is not m or f')
    bad(function(a) a.sk = 46 end, 'skin past 45')
    bad(function(a) a.sk = -1 end, 'skin below 0')
    bad(function(a) a.e = 31 end, 'eyes past 30')
    bad(function(a) a.sk = 1.5 end, 'a float, never rounded')
    bad(function(a) a.h = { 0, 64 } end, 'a highlight past 63')
    bad(function(a) a.h = { 0 } end, 'one hair color')
    bad(function(a) a.ff[1] = 101 end, 'a feature past 100')
    bad(function(a) a.ff[19] = -1 end, 'the chin dimple below 0 (feature 18)')
    bad(function(a) a.ff[20] = -1 end, 'the neck below 0 (feature 19)')
    bad(function(a) a.ff[21] = 0 end, 'a twenty-first feature')
    bad(function(a) a.o[3][1] = 255 end, 'eyebrows of none')
    bad(function(a) a.o[1][2] = 101 end, 'an opacity past 100')
    bad(function(a) a.o[1][3] = 64 end, 'an overlay color past 63')
    bad(function(a) a.o[14] = { 0, 0, 0 } end, 'a fourteenth overlay')
    bad(function(a) a.c[1][1] = 1024 end, 'a drawable past 1023')
    bad(function(a) a.c[1][2] = 32 end, 'a texture past 31 (the sync carries 5 bits)')
    bad(function(a) a.p[1] = { -1, 1 } end, 'no prop with a texture')
    bad(function(a) a.p[1][1] = -2 end, 'a prop below none')
    bad(function(a) a.x = 1 end, 'a key the schema does not have')
    bad(function(a) a.c[3] = { 0, 0, 0 } end, 'a component with three numbers')
    local a = A.default('m')
    a.c[5][1] = 7
    ok(A.validate(a), 'any bag drawable is fine: parachute packs are allowed (owner, 2026-10-07)')
    eq(shared.BR.Config.Locker2.bagSkip, nil, 'and no list of packs is kept to refuse them')
end

describe('appearance.decode')
do
    local s = A.encode(A.default('m'))
    ok(A.decode(s:gsub('"sk":0', '"sk":0.5')) == nil, 'a float is refused, not rounded')
    ok(A.decode(s:gsub('"sk":0', '"sk":1e1')) == nil, 'an exponent is refused')
    ok(A.decode(s .. 'x') == nil, 'trailing text is refused')
    ok(A.decode(s:gsub('"sk":0', '"sk":0,"sk":1')) == nil, 'a repeated key is refused')
    ok(A.decode(s:gsub('"v":1', '"v":true')) == nil, 'a literal is refused')
    ok(A.decode(s:sub(1, -2)) == nil, 'a cut-off string is refused')
    ok(A.decode(s .. string.rep(' ', 2049 - #s)) == nil, 'past 2048 bytes is refused before reading')
    ok(A.decode(42) == nil and A.decode(nil) == nil, 'and so is anything not a string')
end

describe('appearance.ids')
do
    local id = A.newId(1791400000000, function() return 35 end)
    eq(#id, 11, 'an id is eleven characters')
    ok(A.isPedId(id), 'of base36')
    ok(id:sub(10) == 'zz', 'the last two random')
    ok(A.newId(1791400000000) < A.newId(1791400000001 + 36 * 36), 'ids sort by creation')
    ok(not A.isPedId('ABCDEFGHIJK') and not A.isPedId('profile') and not A.isPedId('0123456789'),
        'upper case, a word and ten characters are not ids')
    ok(A.isName('Bob') and A.isName(string.rep('a', 24)) and A.isName('Z9'), 'names of letters and digits, 1 to 24')
    ok(not A.isName('') and not A.isName(string.rep('a', 25)) and not A.isName('Bob 1')
        and not A.isName('B\195\179b') and not A.isName('a_b') and not A.isName(5),
        'never empty, long, spaced, accented, punctuated or a number')
end

describe('appearance.worn')
do
    local stock = shared.BR.Config.Peds[1].id
    local w = A.encodeWorn({ k = 's', id = stock })
    eq(w, ('{"k":"s","id":"%s"}'):format(stock), 'a stock ped is its id')
    local back = A.decodeWorn(w)
    ok(back and back.k == 's' and back.id == stock, 'and reads back')
    ok(A.encodeWorn({ k = 's', id = 'nobody' }) == nil, 'an id not in the roster is not worn')
    local pw = A.encodeWorn({ k = 'p', id = '0abcdefgh12', a = A.default('f') })
    local pb = A.decodeWorn(pw)
    ok(pb and pb.k == 'p' and A.equal(pb.a, A.default('f')), 'a saved ped carries its appearance')
    ok(A.decodeWorn('{"k":"p","id":"0abcdefgh12"}') == nil, 'a saved ped with no appearance is nothing')
    ok(A.decodeWorn('') == nil and A.decodeWorn('{}') == nil, 'nor is an empty record')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 2. THE SERVER (br_core/server/locker2.lua) over a modeled br_ddb
-- ═══════════════════════════════════════════════════════════════════════════

local function serverWorld(season, withDdb)
    local env = newEnv()
    local W = { time = 5000, printed = {}, sent = {}, timers = {}, handlers = {}, ddb = {},
                ddbCalls = {}, replies = {}, entries = {}, failNext = nil, decodes = 0 }
    env.print = function(s) W.printed[#W.printed + 1] = tostring(s) end
    env.GetGameTimer = function() return W.time end
    env.GetConvar = function(n, d) if n == 'br_season' then return tostring(season) end return d end
    env.SetConvarReplicated = function() end
    env.GetResourceState = function() return withDdb == false and 'missing' or 'started' end
    env.RegisterNetEvent = function() end
    env.RegisterCommand = function() end
    env.AddEventHandler = function(n, fn)
        W.handlers[n] = W.handlers[n] or {}
        table.insert(W.handlers[n], fn)
    end
    env.SetTimeout = function(ms, fn) W.timers[#W.timers + 1] = { at = W.time + ms, fn = fn } end
    env.TriggerClientEvent = function(n, target, p)
        W.sent[#W.sent + 1] = { name = n, target = target, p = deepCopy(p) }
    end
    env.TriggerLatentClientEvent = function(n, target, bps, p)
        W.sent[#W.sent + 1] = { name = n, target = target, p = deepCopy(p), latent = bps }
    end

    -- ═══ br_ddb, as rows ═══
    local function rowsOf(lic)
        W.ddb[lic] = W.ddb[lic] or { profile = {}, peds = {} }
        return W.ddb[lic]
    end
    local verbs = {}
    verbs.lockerFetch = function(lic)
        local r = rowsOf(lic)
        local peds = {}
        local ids = {}
        for id in pairs(r.peds) do ids[#ids + 1] = id end
        table.sort(ids)
        for _, id in ipairs(ids) do
            local p = r.peds[id]
            peds[#peds + 1] = { id = id, name = p.n, a = p.a, cr = p.cr, up = p.up, img = p.img }
        end
        return true, { worn = r.profile.locker2 or '', peds = peds }
    end
    verbs.pedPut = function(lic, id, rec, isNew)
        local r = rowsOf(lic)
        if isNew and r.peds[id] then return false, { refused = 'exists' } end
        if not isNew and not r.peds[id] then return false, { refused = 'missing' } end
        r.peds[id] = { n = rec.n, a = rec.a, cr = rec.cr, up = rec.up }
        return true, { id = id }
    end
    verbs.pedRename = function(lic, id, name, up)
        local r = rowsOf(lic)
        if not r.peds[id] then return false, { refused = 'missing' } end
        r.peds[id].n, r.peds[id].up = name, up
        return true, { id = id }
    end
    verbs.pedShot = function(lic, id, img)
        local r = rowsOf(lic)
        if not r.peds[id] then return false, { refused = 'missing' } end
        r.peds[id].img = img
        return true, { id = id }
    end
    verbs.pedDelete = function(lic, id)
        rowsOf(lic).peds[id] = nil
        return true, { id = id }
    end
    verbs.wornSet = function(lic, worn)
        rowsOf(lic).profile.locker2 = worn
        return true, {}
    end
    env.TriggerEvent = function(n, req, ...)
        local verb = n:match('^br:ddb:(%w+)$')
        if verb and verbs[verb] then
            W.ddbCalls[#W.ddbCalls + 1] = { verb = verb, args = deepCopy({ ... }) }
            local okv, extra
            if W.failNext == verb then
                W.failNext = nil
                okv, extra = false, { error = 'boom' }
            else
                okv, extra = verbs[verb](...)
            end
            W.replies[#W.replies + 1] = { name = 'br:ddb:' .. verb .. 'Result', args = { req, okv, extra } }
        end
    end

    env.BR = {}
    env.BR.Config = {}
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
                         'br_lib/config/peds.lua', 'br_lib/shared/season.lua',
                         'br_lib/config/seasons.lua', 'br_lib/config/locker2.lua',
                         'br_lib/shared/appearance.lua' }) do
        loadInto(env, f)
    end
    env.BR.Season.strict = true
    env.BR.Season.boot()
    env.BR.Identity = {
        ofPlayer = function(src) return { license = 'p' .. tostring(src) } end,
        qualified = function(kind, v) return kind .. ':' .. v end,
    }
    env.BR.Roster = { get = function(src) return W.entries[src] end }
    -- Count decodes, to prove an oversize appearance is refused unread.
    local realDecode = env.BR.Appearance.decode
    env.BR.Appearance.decode = function(...)
        W.decodes = W.decodes + 1
        return realDecode(...)
    end
    loadInto(env, 'br_core/server/locker2.lua')

    function W.flush()
        if W.held then return end
        local guard = 0
        while #W.replies > 0 and guard < 100 do
            guard = guard + 1
            local r = table.remove(W.replies, 1)
            for _, fn in ipairs(W.handlers[r.name] or {}) do fn(table.unpack(r.args)) end
        end
    end
    function W.advance(ms)
        local stop = W.time + ms
        while W.time < stop do
            W.time = W.time + 50
            local due = {}
            for i = #W.timers, 1, -1 do
                if W.timers[i].at <= W.time then due[#due + 1] = table.remove(W.timers, i) end
            end
            for i = #due, 1, -1 do due[i].fn() end
            W.flush()
        end
    end
    function W.net(name, src, payload)
        env.source = src
        for _, fn in ipairs(W.handlers[name] or {}) do fn(payload) end
        W.flush()
    end
    function W.last(name)
        for i = #W.sent, 1, -1 do
            if W.sent[i].name == name then return W.sent[i] end
        end
        return nil
    end
    function W.results()
        local out = {}
        for _, s in ipairs(W.sent) do
            if s.name == env.BR.Net.LOCKER2_RESULT then out[#out + 1] = s.p end
        end
        return out
    end
    function W.lastResult() local r = W.results(); return r[#r] end
    W.env = env
    W.BR = env.BR
    W.entries[1] = { state = env.BR.PlayerState.LOBBY }
    W.entries[2] = { state = env.BR.PlayerState.LOBBY }
    return W
end

local NET = shared.BR and nil
do
    local penv = newEnv()
    penv.BR = {}
    loadInto(penv, 'br_lib/shared/protocol.lua')
    NET = penv.BR.Net
end
local STOCK1 = shared.BR.Config.Peds[1].id
local STOCK2 = shared.BR.Config.Peds[2].id

describe('server.fetch')
do
    local W = serverWorld(2)
    W.ddb['license:p1'] = { profile = { locker2 = ('{"k":"s","id":"%s"}'):format(STOCK2) }, peds = {
        ['0abcdefgh12'] = { n = 'Bob', a = A.encode(A.default('m')), cr = 1, up = 2 },
        ['0abcdefgh11'] = { n = 'Ann', a = A.encode(A.default('f')), cr = 1, up = 1 },
        ['0abcdefgh13'] = { n = 'Bad', a = '{"v":1}', cr = 1, up = 1 },
    } }
    W.net(NET.LOCKER2_FETCH, 1, {})
    local st = W.last(NET.LOCKER2_STATE)
    ok(st ~= nil and st.target == 1, 'a fetch answers its player')
    ok(st and st.latent ~= nil, 'with a LATENT event: the list can be large')
    ok(st and st.p.store == true, 'store true')
    eq(st and st.p.worn.id, STOCK2, 'the worn ped off the profile')
    eq(st and #st.p.peds, 2, 'every saved ped that is one, a broken row left out')
    eq(st and st.p.peds[1].id, '0abcdefgh11', 'oldest first')
    eq(#W.ddbCalls, 1, 'one database read')
    W.advance(1000)
    W.net(NET.LOCKER2_FETCH, 1, {})
    eq(#W.ddbCalls, 1, 'a second fetch inside 5 s reads nothing')
    eq(#W.sent, 1, 'and is not answered yet: one answer per player per 5 s')
    W.advance(4000)
    eq(#W.sent, 2, 'it is answered once the 5 s are up')
    eq(#W.ddbCalls, 2, 'with a fresh read')
    -- The cache answers another player of the same license (a second session).
    W.BR.Identity.ofPlayer = function() return { license = 'p1' } end
    W.net(NET.LOCKER2_FETCH, 3, {})
    eq(W.last(NET.LOCKER2_STATE).target, 3, 'another session of that license is answered at once')
    eq(#W.ddbCalls, 2, 'from the cache')

    local W1 = serverWorld(1)
    W1.net(NET.LOCKER2_FETCH, 1, {})
    eq(#W1.sent + #W1.ddbCalls, 0, 'Season 1: a fetch reads nothing and answers nothing')
end

describe('server.fetch_rate')
do
    -- #28 review: every fetch was answered, each a latent copy of the whole
    -- list with every headshot. 200 asks in 5 s queued 67.7 MB.
    local W = serverWorld(2)
    local img = 'data:image/webp;base64,' .. string.rep('A', 10000)
    local rows = {}
    for i = 1, 30 do
        rows[('0abcdefgh%02d'):format(i)] = { n = 'P' .. i, a = A.encode(A.default('m')), cr = 1, up = 1, img = img }
    end
    W.ddb['license:p1'] = { profile = {}, peds = rows }
    local function answers(src)
        local n = 0
        for _, x in ipairs(W.sent) do
            if x.name == NET.LOCKER2_STATE and x.target == src then n = n + 1 end
        end
        return n
    end
    W.net(NET.LOCKER2_FETCH, 1, {})
    for _ = 1, 99 do
        W.advance(50)
        W.net(NET.LOCKER2_FETCH, 1, {})
    end
    eq(answers(1), 1, 'a hundred asks inside 5 s: one answer so far')
    W.advance(100)
    eq(answers(1), 2, 'and one more when the 5 s are up, however many asked')
    eq(#W.ddbCalls, 2, 'two reads')
    W.advance(10000)
    eq(answers(1), 2, 'nothing after that unasked')

    -- Asking while a read is in flight waits on it once.
    local R = serverWorld(2)
    R.held = true
    for _ = 1, 50 do R.net(NET.LOCKER2_FETCH, 1, {}) end
    R.held = false
    R.flush()
    local n = 0
    for _, x in ipairs(R.sent) do if x.name == NET.LOCKER2_STATE then n = n + 1 end end
    eq(n, 1, 'fifty asks during one read: one answer')
    eq(#R.ddbCalls, 1, 'and one read')

    -- A player who drops is not answered later.
    local D = serverWorld(2)
    D.net(NET.LOCKER2_FETCH, 1, {})
    D.advance(1000)
    D.net(NET.LOCKER2_FETCH, 1, {})
    D.net('playerDropped', 1)
    D.advance(6000)
    eq(#D.sent, 1, 'a held answer to a player who left is never sent')
end

describe('server.save')
do
    local W = serverWorld(2)
    local a = A.default('m')
    a.sk = 7
    local enc = A.encode(a)
    W.net(NET.LOCKER2_SAVE, 1, { req = 1, op = 'new', name = 'Bob', a = enc })
    eq(W.lastResult().reason, 'store', 'a write before any fetch is refused store')
    W.net(NET.LOCKER2_FETCH, 1, {})
    W.net(NET.LOCKER2_SAVE, 1, { req = 2, op = 'new', name = 'Bob', a = enc })
    local r = W.lastResult()
    ok(r.ok == true and r.req == 2, 'a new ped is saved')
    ok(A.isPedId(r.id), 'with an id the server minted', r.id)
    ok(r.ped and r.ped.name == 'Bob' and r.ped.a == enc, 'the answer carries that ped')
    ok(r.worn and r.worn.k == 'p' and r.worn.id == r.id, 'and the saved ped is now the worn one')
    local row = W.ddb['license:p1'].peds[r.id]
    ok(row and row.a == enc and row.n == 'Bob', 'the row holds the canonical string')
    local put = W.ddbCalls[#W.ddbCalls]
    ok(put.verb == 'pedPut' and put.args[4] == true, 'written as new')
    local id = r.id

    -- The worn record is written coalesced, not now.
    eq(W.ddb['license:p1'].profile.locker2, nil, 'the worn ped is not written yet')
    W.advance(100)
    local worn = A.decodeWorn(W.ddb['license:p1'].profile.locker2)
    ok(worn and worn.id == id and A.equal(worn.a, a), 'then it is, with a copy of the appearance')

    -- Canonical: whitespace and key spacing are not stored.
    local spaced = enc:gsub(',', ', ')
    W.advance(2000)
    W.net(NET.LOCKER2_SAVE, 1, { req = 3, op = 'update', id = id, a = spaced })
    r = W.lastResult()
    ok(r.ok == true and r.id == id, 'an update of an owned ped')
    eq(W.ddb['license:p1'].peds[id].a, enc, 'stored canonical, whatever was sent')
    eq(W.ddb['license:p1'].peds[id].n, 'Bob', 'an update keeps the name')
    ok(W.ddbCalls[#W.ddbCalls].args[4] == false, 'written only where the ped exists')

    W.net(NET.LOCKER2_SAVE, 1, { req = 4, op = 'replace', id = id, name = 'Zed', a = enc })
    eq(W.ddb['license:p1'].peds[id].n, 'Bob', 'a replace keeps the name too, whatever it was sent')

    -- Refusals, in order.
    local function refused(payload, want, label)
        W.advance(2000)
        W.net(NET.LOCKER2_SAVE, 1, payload)
        eq(W.lastResult().reason, want, label)
    end
    refused({ req = 5, op = 'new', name = 'Bo b', a = enc }, 'name', 'a name with a space')
    refused({ req = 6, op = 'new', name = string.rep('a', 25), a = enc }, 'name', 'a name of 25')
    refused({ req = 7, op = 'new', a = enc }, 'name', 'no name')
    refused({ req = 8, op = 'new', name = 'Bob', id = id, a = enc }, 'missing', 'a new ped with an id')
    refused({ req = 9, op = 'update', id = 'profile', a = enc }, 'missing', 'an id that is not one')
    local calls = #W.ddbCalls
    refused({ req = 10, op = 'update', id = '0abcdefgh99', a = enc }, 'missing', 'an id this player does not own')
    eq(#W.ddbCalls, calls, 'refused before the database is asked anything')
    refused({ req = 11, op = 'new', name = 'Bob', a = '{"v":1}' }, 'appearance', 'an appearance that is not one')
    refused({ req = 12, op = 'new', name = 'Bob', a = 5 }, 'appearance', 'an appearance that is not a string')
    local before = W.decodes
    refused({ req = 13, op = 'new', name = 'Bob', a = enc .. string.rep(' ', 2048) }, 'appearance',
        'an appearance past 2048 bytes')
    eq(W.decodes, before, 'refused before it is decoded')
    refused({ req = 14, op = 'move', id = id, a = enc }, 'missing', 'an op that is not one')

    -- Another player cannot touch this one's ped.
    W.net(NET.LOCKER2_FETCH, 2, {})
    W.net(NET.LOCKER2_SAVE, 2, { req = 15, op = 'update', id = id, a = enc })
    eq(W.lastResult().reason, 'missing', 'another player\'s id is missing to them')
    eq(W.lastResult().req, 15, 'answered to them')
end

describe('server.rate')
do
    local W = serverWorld(2)
    W.net(NET.LOCKER2_FETCH, 1, {})
    local enc = A.encode(A.default('m'))
    for i = 1, 6 do W.net(NET.LOCKER2_SAVE, 1, { req = i, op = 'new', name = 'P' .. i, a = enc }) end
    local res = W.results()
    local okCount = 0
    for _, r in ipairs(res) do if r.ok then okCount = okCount + 1 end end
    eq(okCount, 6, 'six writes at once are taken')
    W.net(NET.LOCKER2_SAVE, 1, { req = 7, op = 'new', name = 'P7', a = enc })
    eq(W.lastResult().reason, 'rate', 'the seventh is refused rate')
    W.advance(1900)
    W.net(NET.LOCKER2_SAVE, 1, { req = 8, op = 'new', name = 'P8', a = enc })
    eq(W.lastResult().reason, 'rate', 'and still inside two seconds')
    W.advance(200)
    W.net(NET.LOCKER2_SAVE, 1, { req = 9, op = 'new', name = 'P9', a = enc })
    eq(W.lastResult().ok, true, 'one more after two seconds')
    local id = W.lastResult().id
    W.net(NET.LOCKER2_RENAME, 1, { req = 10, id = id, name = 'Q' })
    eq(W.lastResult().reason, 'rate', 'renames share the bucket')
    W.advance(2000)
    W.net(NET.LOCKER2_RENAME, 1, { req = 11, id = id, name = 'Q' })
    eq(W.lastResult().ok, true, 'a rename once it refills')
    eq(W.ddb['license:p1'].peds[id].n, 'Q', 'renamed')
end

describe('server.rename_delete_shot')
do
    local W = serverWorld(2)
    W.net(NET.LOCKER2_FETCH, 1, {})
    local a = A.default('f')
    W.net(NET.LOCKER2_SAVE, 1, { req = 1, op = 'new', name = 'Ann', a = A.encode(a) })
    local id = W.lastResult().id
    W.advance(6000)
    W.net(NET.LOCKER2_RENAME, 1, { req = 2, id = id, name = 'Bad Name' })
    eq(W.lastResult().reason, 'name', 'a rename to a bad name')
    W.net(NET.LOCKER2_RENAME, 1, { req = 3, id = id, name = 'Eve' })
    ok(W.lastResult().ok and W.lastResult().ped.name == 'Eve', 'a rename answers the ped renamed')
    local img = 'data:image/webp;base64,' .. string.rep('A', 100)
    W.advance(2000)
    W.net(NET.LOCKER2_SHOT, 1, { req = 4, id = id, img = img })
    ok(W.lastResult().ok and W.ddb['license:p1'].peds[id].img == img, 'a headshot is stored with its ped')
    W.advance(2000)
    W.net(NET.LOCKER2_SHOT, 1, { req = 5, id = id, img = 'data:image/png;base64,AAAA' })
    eq(W.lastResult().reason, 'appearance', 'a png is not a headshot')
    W.advance(2000)
    W.net(NET.LOCKER2_SHOT, 1, { req = 6, id = id, img = 'data:image/webp;base64,' .. string.rep('A', 11000) })
    eq(W.lastResult().reason, 'appearance', 'nor one past 8 KB')
    W.advance(2000)
    W.net(NET.LOCKER2_FETCH, 1, {})
    W.advance(6000)
    W.net(NET.LOCKER2_FETCH, 1, {})
    local st = W.last(NET.LOCKER2_STATE)
    eq(st.p.peds[1].img, img, 'and comes back in the state')

    W.net(NET.LOCKER2_DELETE, 1, { req = 7, id = id })
    ok(W.lastResult().ok and W.lastResult().gone == true, 'a delete answers gone')
    eq(W.ddb['license:p1'].peds[id], nil, 'the row is gone')
    W.advance(6000)
    local worn = A.decodeWorn(W.ddb['license:p1'].profile.locker2)
    ok(worn and worn.id == id and A.equal(worn.a, a), 'the worn ped keeps its copy')
    W.advance(2000)
    W.net(NET.LOCKER2_DELETE, 1, { req = 8, id = id })
    eq(W.lastResult().reason, 'missing', 'a second delete is missing')
end

describe('server.wear')
do
    local W = serverWorld(2)
    W.net(NET.LOCKER2_FETCH, 1, {})
    W.net(NET.LOCKER2_WEAR, 1, { k = 's', id = STOCK2 })
    W.advance(100)
    local w = A.decodeWorn(W.ddb['license:p1'].profile.locker2)
    ok(w and w.id == STOCK2, 'a stock pick is worn')
    local writes = 0
    for _, c in ipairs(W.ddbCalls) do if c.verb == 'wornSet' then writes = writes + 1 end end
    W.net(NET.LOCKER2_WEAR, 1, { k = 's', id = STOCK1 })
    W.net(NET.LOCKER2_WEAR, 1, { k = 's', id = STOCK2 })
    W.net(NET.LOCKER2_WEAR, 1, { k = 's', id = STOCK1 })
    W.advance(1000)
    local writes2 = 0
    for _, c in ipairs(W.ddbCalls) do if c.verb == 'wornSet' then writes2 = writes2 + 1 end end
    eq(writes2, writes, 'three more picks inside 5 s write nothing yet')
    W.advance(4500)
    writes2 = 0
    for _, c in ipairs(W.ddbCalls) do if c.verb == 'wornSet' then writes2 = writes2 + 1 end end
    eq(writes2, writes + 1, 'then one write')
    eq(A.decodeWorn(W.ddb['license:p1'].profile.locker2).id, STOCK1, 'of the last one')
    W.net(NET.LOCKER2_WEAR, 1, { k = 's', id = STOCK2 })
    W.net('playerDropped', 1)
    eq(A.decodeWorn(W.ddb['license:p1'].profile.locker2).id, STOCK2, 'a drop writes the pending pick at once')
    W.net(NET.LOCKER2_WEAR, 2, { k = 's', id = 'nobody' })
    W.net(NET.LOCKER2_WEAR, 2, { k = 'p', id = '0abcdefgh12' })
    W.advance(6000)
    eq(W.ddb['license:p2'], nil, 'an unknown stock id or an unowned ped is never worn')
    W.entries[2].state = W.BR.PlayerState.ALIVE
    W.net(NET.LOCKER2_WEAR, 2, { k = 's', id = STOCK1 })
    W.advance(6000)
    eq(W.ddb['license:p2'], nil, 'and nothing is worn outside the lobby')
end

describe('server.failures')
do
    local W = serverWorld(2)
    W.failNext = 'lockerFetch'
    W.net(NET.LOCKER2_FETCH, 1, {})
    local st = W.last(NET.LOCKER2_STATE)
    ok(st and st.p.store == false and st.p.peds == nil, 'a failed read says store false, with no list')
    W.net(NET.LOCKER2_SAVE, 1, { req = 1, op = 'new', name = 'Bob', a = A.encode(A.default('m')) })
    eq(W.lastResult().reason, 'store', 'and every write is refused store')
    W.advance(6000)
    W.net(NET.LOCKER2_FETCH, 1, {})
    W.net(NET.LOCKER2_SAVE, 1, { req = 2, op = 'new', name = 'Bob', a = A.encode(A.default('m')) })
    eq(W.lastResult().ok, true, 'until a read works')
    W.failNext = 'pedPut'
    W.advance(2000)
    W.net(NET.LOCKER2_SAVE, 1, { req = 3, op = 'new', name = 'Ann', a = A.encode(A.default('m')) })
    eq(W.lastResult().reason, 'store', 'a failed write answers store')
    -- A later read that fails, after one that worked, stops the writes again.
    W.advance(6000)
    W.failNext = 'lockerFetch'
    W.net(NET.LOCKER2_FETCH, 1, {})
    W.advance(2000)
    W.net(NET.LOCKER2_SAVE, 1, { req = 4, op = 'new', name = 'Zed', a = A.encode(A.default('m')) })
    eq(W.lastResult().reason, 'store', 'a read that fails after one that worked refuses writes as store')

    local W1 = serverWorld(1)
    W1.net(NET.LOCKER2_SAVE, 1, { req = 1, op = 'new', name = 'Bob', a = A.encode(A.default('m')) })
    eq(W1.lastResult().reason, 'season', 'Season 1 refuses every write as season')
    eq(#W1.ddbCalls, 0, 'and asks the database nothing')

    local W0 = serverWorld(2, false)
    W0.net(NET.LOCKER2_FETCH, 1, {})
    W0.net(NET.LOCKER2_SAVE, 1, { req = 1, op = 'new', name = 'Bob', a = A.encode(A.default('m')) })
    ok(W0.lastResult().ok, 'with no br_ddb a save is kept in memory')
    W0.advance(6000)
    W0.net(NET.LOCKER2_FETCH, 1, {})
    eq(#W0.last(NET.LOCKER2_STATE).p.peds, 1, 'and listed for the session')
    local warned = 0
    for _, s in ipairs(W0.printed) do if s:find('in memory', 1, true) then warned = warned + 1 end end
    eq(warned, 1, 'said once')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. THE CLIENT, over a modeled ped
-- ═══════════════════════════════════════════════════════════════════════════

local MALE = hashOf('mp_m_freemode_01')
local FEMALE = hashOf('mp_f_freemode_01')
local DEFAULT_PED = hashOf('player_default')

local function newPed(model)
    return { model = model, comps = {}, props = {}, ff = {}, ov = {}, ovc = {}, hair = nil, eye = nil,
             blend = nil, blendAt = 0, x = 10.0, y = 20.0, z = 30.0, h = 90.0, exists = true }
end

--- A client. opts: season (nil unknown), v2 (load Locker v2), kvp, quiet.
local function clientWorld(opts)
    opts = opts or {}
    local env = newEnv()
    local W = { time = 1000, log = {}, events = {}, server = {}, kvp = deepCopy(opts.kvp or {}),
                threads = {}, ticks = {}, notify = {}, handlers = {}, commands = {}, cams = {},
                stops = {}, shots = {}, created = {}, locked = false, entering = false, walking = false,
                convar = opts.season and tostring(opts.season) or '', listener = nil,
                models = {}, modelDelay = opts.modelDelay or 0, neverLoad = false, peds = {}, handle = 1 }
    W.peds[1] = newPed(opts.startModel or DEFAULT_PED)
    env.print = function() end

    local function rec(name, ...)
        local args = { ... }
        local parts = {}
        for i = 1, select('#', ...) do
            local v = args[i]
            parts[#parts + 1] = type(v) == 'table' and 'tbl' or tostring(v)
        end
        W.log[#W.log + 1] = name .. '(' .. table.concat(parts, ',') .. ')'
    end
    local function P(h) return W.peds[h] end

    local N = {}
    N.GetGameTimer = function() return W.time end
    N.PlayerPedId = function() return W.handle end
    N.PlayerId = function() return 0 end
    N.GetHashKey = function(s) return hashOf(s) end
    N.RequestModel = function(h) if W.models[h] == nil then W.models[h] = W.time + W.modelDelay end end
    N.HasModelLoaded = function(h) return not W.neverLoad and W.models[h] ~= nil and W.time >= W.models[h] end
    N.SetModelAsNoLongerNeeded = function() end
    N.IsModelInCdimage = function(h) return not (opts.missing and h == hashOf(opts.missing)) end
    N.IsModelValid = function() return true end
    N.IsModelAPed = function() return true end
    N.GetEntityModel = function(h) return P(h) and P(h).model or 0 end
    N.GetEntityCoords = function(h) local p = P(h); return { x = p.x, y = p.y, z = p.z } end
    N.GetEntityHeading = function(h) return P(h).h end
    N.SetEntityCoordsNoOffset = function(h, x, y, z) local p = P(h); p.x, p.y, p.z = x, y, z end
    N.SetEntityHeading = function(h, v) P(h).h = v end
    N.FreezeEntityPosition = function() end
    N.SetPedCanRagdoll = function() end
    N.SetPlayerModel = function(_, hash)
        local old = P(W.handle)
        W.handle = W.handle + 1
        W.peds[W.handle] = newPed(hash)
        W.peds[W.handle].x, W.peds[W.handle].y, W.peds[W.handle].z = old.x, old.y, old.z
    end
    N.SetPedDefaultComponentVariation = function(h)
        local p = P(h)
        for s = 0, 11 do p.comps[s] = { 0, 0 } end
    end
    N.SetPedHeadBlendData = function(h, s1, _, _, k1)
        local p = P(h)
        p.blend = { s1, k1 }
        p.blendAt = W.time + 100
    end
    N.HasPedHeadBlendFinished = function(h) return W.time >= P(h).blendAt and 1 or 0 end
    N.SetPedFaceFeature = function(h, i, v) P(h).ff[i] = v end
    N.SetPedHeadOverlay = function(h, i, idx, op) P(h).ov[i] = { idx, op } end
    N.SetPedHeadOverlayColor = function(h, i, kind, c) P(h).ovc[i] = { kind, c } end
    N.SetPedComponentVariation = function(h, s, d, t) P(h).comps[s] = { d, t } end
    N.SetPedHairColor = function(h, c, hl) P(h).hair = { c, hl } end
    N.SetPedEyeColor = function(h, e) P(h).eye = e end
    N.SetPedPropIndex = function(h, s, d, t) P(h).props[s] = { d, t } end
    N.ClearPedProp = function(h, s) P(h).props[s] = nil end
    N.GetPedDrawableVariation = function(h, s) return (P(h).comps[s] or { 0, 0 })[1] end
    N.GetPedTextureVariation = function(h, s) return (P(h).comps[s] or { 0, 0 })[2] end
    N.GetPedPropIndex = function(h, s) return P(h).props[s] and P(h).props[s][1] or -1 end
    N.GetPedPropTextureIndex = function(h, s) return P(h).props[s] and P(h).props[s][2] or -1 end
    N.GetNumberOfPedDrawableVariations = function(_, s) return s == 5 and 10 or (s == 2 and 30 or 40) end
    N.GetNumberOfPedTextureVariations = function(_, _, d) return (d % 3) + 1 end
    N.GetNumberOfPedPropDrawableVariations = function() return 20 end
    N.GetNumberOfPedPropTextureVariations = function(_, _, d) return (d % 2) + 1 end
    N.GetPedHeadOverlayNum = function() return 10 end
    N.GetNumHairColors = function() return 64 end
    N.GetNumMakeupColors = function() return 64 end
    N.IsPedComponentVariationGen9Exclusive = function(_, s, d) return (s == 11 and d == 39) and 1 or 0 end
    N.HasPedGotWeapon = function(h) return P(h).chute and 1 or 0 end
    N.GetPedParachuteState = function(h) return P(h).chuteState or -1 end
    N.IsPedWearingHelmet = function(h) return P(h).helmet and 1 or 0 end
    N.ClearPedBloodDamage = function() end
    N.ResetPedVisibleDamage = function() end
    N.ClearPedWetness = function() end
    N.ClearPedEnvDirt = function() end
    N.ClearPedDecorations = function() end
    N.RegisterPedheadshot = function(h)
        W.shots[#W.shots + 1] = { ped = h, at = W.time, gone = false }
        return #W.shots
    end
    N.IsPedheadshotReady = function(n) return W.time >= W.shots[n].at + 100 and 1 or 0 end
    N.IsPedheadshotValid = function() return 1 end
    N.GetPedheadshotTxdString = function(n) return 'pedmugshot_0' .. n end
    N.UnregisterPedheadshot = function(n) W.shots[n].gone = true end
    N.CreatePed = function(_, hash, x, y, z, _, net)
        W.handleMax = (W.handleMax or 1000) + 1
        W.peds[W.handleMax] = newPed(hash)
        W.created[#W.created + 1] = { handle = W.handleMax, net = net, z = z }
        return W.handleMax
    end
    N.DoesEntityExist = function(h) return (P(h) and P(h).exists) and 1 or 0 end
    N.DeletePed = function(h) P(h).exists = false end
    N.SetEntityCollision = function() end
    N.SetEntityInvincible = function() end
    N.SetBlockingOfNonTemporaryEvents = function() end
    N.SetResourceKvp = function(k, v) W.kvp[k] = v end
    N.GetResourceKvpString = function(k) return W.kvp[k] end
    N.DeleteResourceKvp = function(k) W.kvp[k] = nil end
    N.TriggerServerEvent = function(name, p) W.server[#W.server + 1] = { name = name, p = deepCopy(p) } end
    for name, fn in pairs(N) do
        env[name] = function(...)
            if name ~= 'GetGameTimer' then rec(name, ...) end
            return fn(...)
        end
    end

    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetConvar = function(n, d) if n == 'br_seasonServed' then return W.convar end return d end
    env.AddConvarChangeListener = function(_, fn) W.listener = fn return 1 end
    env.RegisterNetEvent = function() end
    env.RegisterCommand = function(n, fn) W.commands[n] = fn end
    env.AddEventHandler = function(n, fn)
        W.handlers[n] = W.handlers[n] or {}
        table.insert(W.handlers[n], fn)
    end
    env.TriggerEvent = function(n, ...)
        W.events[#W.events + 1] = { name = n, args = deepCopy({ ... }) }
        W.log[#W.log + 1] = 'event:' .. n .. (type((...)) == 'string' and (':' .. (...)) or '')
        for _, fn in ipairs(W.handlers[n] or {}) do fn(...) end
    end
    env.Citizen = {
        CreateThread = function(fn)
            W.threads[#W.threads + 1] = { co = coroutine.create(fn), at = W.time }
        end,
        Wait = function(ms) coroutine.yield(ms or 0) end,
    }

    env.BR = { Config = {} }
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua', 'br_lib/config/peds.lua',
                         'br_lib/shared/season.lua', 'br_lib/config/seasons.lua',
                         'br_lib/config/locker2.lua', 'br_lib/shared/appearance.lua' }) do
        loadInto(env, f)
    end
    local BR = env.BR
    BR.Season.strict = true
    BR.Config.Match = { lobbyPos = { x = 10.0, y = 20.0, z = 30.0, heading = 90.0 } }
    BR.Loop = { FRAME = 'frame', TICK = 'tick', SLOW = 'slow',
                register = function(band, name, fn) W.ticks[#W.ticks + 1] = { band = band, name = name, fn = fn } end }
    BR.State = { me = { state = BR.PlayerState.LOBBY } }
    BR.Native = { initHealthModel = function() W.log[#W.log + 1] = 'initHealthModel()' end }
    BR.Spawn = { concealPed = function() W.log[#W.log + 1] = 'concealPed()' end }
    BR.Notify = function(t, tone) W.notify[#W.notify + 1] = t; W.log[#W.log + 1] = 'notify:' .. tostring(t) end
    BR.LobbyPed = {
        lockerLocked = function() return W.locked end,
        entering = function() return W.entering end,
        walking = function() return W.walking end,
        stop = function(why) W.stops[#W.stops + 1] = why; W.entering, W.locked, W.walking = false, false, false end,
    }
    BR.LobbyCam = {
        focus = function(p) W.cams[#W.cams + 1] = 'focus:' .. p W.focusedCam = p return true end,
        unfocus = function() W.cams[#W.cams + 1] = 'unfocus' W.focusedCam = nil return true end,
        focused = function() return W.focusedCam end,
    }
    loadInto(env, 'br_core/client/locker.lua')
    if opts.v2 then
        loadInto(env, 'br_core/client/locker2.lua')
        loadInto(env, 'br_core/client/locker2shot.lua')
    end

    local tickAcc = 0
    function W.pump(ms)
        local stop = W.time + ms
        while W.time < stop do
            W.time = W.time + 50
            for i = #W.threads, 1, -1 do
                local t = W.threads[i]
                if W.time >= t.at then
                    local okc, wait = coroutine.resume(t.co)
                    if not okc then error(wait) end
                    if coroutine.status(t.co) == 'dead' then
                        table.remove(W.threads, i)
                    else
                        t.at = W.time + (wait or 0)
                    end
                end
            end
            tickAcc = tickAcc + 50
            if tickAcc >= 100 then
                tickAcc = 0
                for _, t in ipairs(W.ticks) do
                    if t.band == 'tick' then t.fn() end
                end
            end
        end
    end
    function W.fire(name, ...) env.TriggerEvent(name, ...) end
    function W.ui(name, data) env.TriggerEvent('br:ui:action', name, data or {}) end
    function W.net(name, payload) for _, fn in ipairs(W.handlers[name] or {}) do fn(deepCopy(payload)) end end
    function W.season(n)
        W.convar = n and tostring(n) or ''
        if W.listener then W.listener() end
    end
    function W.ped() return W.peds[W.handle] end
    function W.nui(kind)
        for i = #W.events, 1, -1 do
            local e = W.events[i]
            if e.name == 'br:ui:sendLocal' and e.args[1] == kind then return e.args[2] end
        end
        return nil
    end
    function W.count(prefix)
        local n = 0
        for _, l in ipairs(W.log) do if l:sub(1, #prefix) == prefix then n = n + 1 end end
        return n
    end
    function W.sentTo(name)
        local out = {}
        for _, s in ipairs(W.server) do if s.name == name then out[#out + 1] = s.p end end
        return out
    end
    W.env, W.BR = env, BR
    return W
end

local NUICB, NUI
do
    local penv = newEnv()
    penv.BR = {}
    loadInto(penv, 'br_lib/shared/protocol.lua')
    NUICB, NUI = penv.BR.NuiCb, penv.BR.Nui
end

local function locker2Traffic(W)
    local n = 0
    for _, s in ipairs(W.server) do if s.name:find('locker2', 1, true) then n = n + 1 end end
    for _, e in ipairs(W.events) do
        if e.name == 'br:ui:sendLocal' and (e.args[1] == NUI.LOCKER2 or e.args[1] == NUI.LOCKER2_SHOT) then
            n = n + 1
        end
    end
    return n
end

-- ═══ SEASON 1, GOLDEN ═══

describe('season1.golden')
do
    local function session(v2)
        math.randomseed(7)
        local W = clientWorld({ season = 1, v2 = v2 })
        W.pump(600)
        W.fire('br:ui:ready')
        W.ui(NUICB.LOCKER_PICK, { id = STOCK2 })
        W.pump(600)
        W.ui(NUICB.LOCKER_SPIN, { delta = 30 })
        W.pump(300)
        W.log[#W.log + 1] = 'chosen=' .. W.BR.Locker.chosen()
        for _, s in ipairs(W.server) do W.log[#W.log + 1] = 'server:' .. s.name end
        local keys = {}
        for k, v in pairs(W.kvp) do keys[#keys + 1] = k .. '=' .. v end
        table.sort(keys)
        W.log[#W.log + 1] = 'kvp:' .. table.concat(keys, ';')
        return W
    end
    local base, beside = session(false), session(true)
    eq(#beside.log, #base.log, 'Season 1 with Locker v2 loaded makes as many calls as without it')
    local first = nil
    for i = 1, math.max(#base.log, #beside.log) do
        if base.log[i] ~= beside.log[i] then first = i break end
    end
    ok(first == nil, 'and the same calls, in the same order, with the same arguments',
        first and ('first difference at %d: %s vs %s'):format(first, tostring(base.log[first]),
            tostring(beside.log[first])))
    ok(base.count('SetPlayerModel') == 2, 'the trace is a real session: the first apply and a pick',
        base.count('SetPlayerModel'))
    eq(beside.BR.LockerV2.wantHash(), nil, 'wantHash is nil on Season 1')
    eq(locker2Traffic(beside), 0, 'no locker2 traffic at all')
    eq(beside.kvp['br:locker:ped'], STOCK2, 'Season 1 writes its own kvp as it always did')
    eq(beside.kvp['br:locker2:worn'], nil, 'and nothing of v2\'s')
end

describe('season1.switchlines')
do
    local locker = readFile(RES .. 'br_core/client/locker.lua')
    local _, n = locker:gsub('LockerV2', '')
    eq(n, 2, 'client/locker.lua names BR.LockerV2 on one line only (twice on it)')
    ok(locker:find('    if BR.State.me.state ~= BR.PlayerState.LOBBY then return end\n'
        .. '    if BR.LockerV2 and BR.LockerV2.defer() then return end\n    appliedOnce = true', 1, true) ~= nil,
        'the line is the one before appliedOnce = true')
    local want = 'BR.LockerV2 and BR.LockerV2.wantHash() or GetHashKey(BR.PedById(BR.Locker.chosen()).model)'
    ok(readFile(RES .. 'br_core/client/loading.lua'):find('local want = ' .. want, 1, true) ~= nil,
        'client/loading.lua waits on wantHash or Season 1\'s expression')
    ok(readFile(RES .. 'br_core/client/lobbyped.lua'):find('want = ' .. want, 1, true) ~= nil,
        'and so does client/lobbyped.lua\'s entrance')
    -- Evaluated as written, on Season 1, the expression is Season 1's.
    local W = clientWorld({ season = 1, v2 = true })
    local BR = W.BR
    local got = BR.LockerV2 and BR.LockerV2.wantHash() or W.env.GetHashKey(BR.PedById(BR.Locker.chosen()).model)
    eq(got, hashOf(BR.PedById(BR.Locker.chosen()).model), 'and on Season 1 it is exactly Season 1\'s model')
end

describe('season1.unknown')
do
    local W = clientWorld({ season = nil, v2 = true })
    W.pump(1000)
    eq(W.count('SetPlayerModel'), 0, 'while the season is unknown, Season 1\'s first apply waits')
    eq(W.BR.LockerV2.wantHash(), nil, 'and v2 claims nothing')
    W.season(1)
    W.pump(1000)
    eq(W.count('SetPlayerModel'), 1, 'unknown then Season 1: one Season 1 apply')
    eq(locker2Traffic(W), 0, 'and no v2 at all')

    local W2 = clientWorld({ season = nil, v2 = true })
    W2.pump(2900)
    eq(W2.count('SetPlayerModel'), 0, 'still unknown at 2.9 s: still waiting')
    W2.pump(600)
    eq(W2.count('SetPlayerModel'), 1, 'past 3 s Season 1 goes ahead')

    local W3 = clientWorld({ season = nil, v2 = true })
    W3.pump(500)
    W3.season(2)
    W3.pump(5000)
    eq(W3.kvp['br:locker:ped'], nil, 'unknown then Season 2: Season 1 never applies or writes')
    eq(#W3.sentTo(NET.LOCKER2_FETCH), 1, 'v2 asks the server once')
end

-- ═══ SEASON 2: THE JOIN ═══

local function femaleLook()
    local a = A.default('f')
    a.sk, a.e, a.h = 12, 4, { 5, 6 }
    a.ff[1] = 40
    a.o[5] = { 3, 80, 9 }
    a.c[11] = { 6, 1 }
    a.c[4] = { 2, 0 }
    a.p[1] = { 4, 1 }
    return a
end
local PID = '0abcdefgh12'

describe('season2.join')
do
    local W = clientWorld({ season = 2, v2 = true })
    local BR = W.BR
    W.pump(200)
    eq(#W.sentTo(NET.LOCKER2_FETCH), 1, 'the first lobby tick asks the server')
    eq(BR.LockerV2.wantHash(), 0, 'and the loading screen waits on nothing yet')
    eq(W.count('SetPlayerModel'), 0, 'Season 1 does not apply')
    local a = femaleLook()
    W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(a) }, store = true,
        peds = { { id = PID, name = 'Ann', a = A.encode(a), up = 5 } } })
    W.pump(500)
    local ped = W.ped()
    eq(ped.model, FEMALE, 'the server\'s worn ped is put on: the female freemode ped')
    eq(BR.LockerV2.wantHash(), FEMALE, 'and wantHash names it')
    ok(ped.blend and ped.blend[1] == 21 and ped.blend[2] == 12, 'head blend: shape 21, skin 12')
    eq(ped.ff[0], 0.4, 'face features')
    ok(ped.ov[4] and ped.ov[4][1] == 3 and ped.ov[4][2] == 0.8, 'overlays and opacity')
    ok(ped.ovc[4] and ped.ovc[4][1] == 2 and ped.ovc[4][2] == 9, 'blush on the makeup palette')
    ok(ped.ovc[2] and ped.ovc[2][1] == 1, 'eyebrows on the hair palette')
    ok(ped.hair and ped.hair[1] == 5 and ped.hair[2] == 6, 'hair colors')
    eq(ped.eye, 4, 'eyes')
    ok(ped.comps[11][1] == 6 and ped.comps[11][2] == 1 and ped.comps[4][1] == 2, 'components')
    ok(ped.props[0] and ped.props[0][1] == 4 and ped.props[0][2] == 1, 'props')
    eq(ped.props[1], nil, 'and a prop of none is cleared')
    -- The order, inside one block.
    local idx = {}
    for i, l in ipairs(W.log) do
        local n = l:match('^(%w+)%(')
        if n and not idx[n] then idx[n] = i end
    end
    ok(idx.SetPlayerModel < idx.SetPedHeadBlendData and idx.SetPedHeadBlendData < idx.SetPedFaceFeature
        and idx.SetPedFaceFeature < idx.SetPedHeadOverlay and idx.SetPedHeadOverlay < idx.SetPedHairColor
        and idx.SetPedHairColor < idx.SetPedEyeColor and idx.SetPedEyeColor < idx.SetPedPropIndex,
        'swap, blend, features, overlays, hair, eyes, then props')
    eq(W.count('SetPedHeadBlendData'), 2, 'the blend is asserted again once it has finished')
    ok(W.kvp['br:locker2:worn'] ~= nil and A.decodeWorn(W.kvp['br:locker2:worn']).id == PID,
        'this machine remembers the worn ped')
    eq(W.kvp['br:locker:ped'], nil, 'and Season 1\'s kvp is never written')
end

describe('season2.join_fallbacks')
do
    -- The server's record outranks this machine's: a new PC, or another
    -- machine's pick, joins as the ped the player left with.
    local S0 = clientWorld({ season = 2, v2 = true, kvp = { ['br:locker2:worn'] = ('{"k":"s","id":"%s"}'):format(STOCK2) } })
    S0.pump(200)
    S0.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(femaleLook()) }, store = true, peds = {} })
    S0.pump(500)
    eq(S0.ped().model, FEMALE, 'the server\'s worn ped wins over this machine\'s')
    eq(S0.count('SetPlayerModel'), 1, 'in one swap')

    -- No answer: the kvp after 4 s.
    local W = clientWorld({ season = 2, v2 = true, kvp = { ['br:locker2:worn'] = ('{"k":"s","id":"%s"}'):format(STOCK2) } })
    local BR = W.BR
    W.pump(3800)
    eq(W.count('SetPlayerModel'), 0, 'up to 4 s the first apply waits for the server')
    W.pump(600)
    eq(W.ped().model, hashOf(BR.PedById(STOCK2).model), 'then this machine\'s worn ped')
    -- The server answers late, differently, while the walk holds the ped.
    W.locked = true
    W.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK1 }, store = true, peds = {} })
    W.pump(600)
    eq(W.ped().model, hashOf(BR.PedById(STOCK2).model), 'a later answer waits while the locker is locked')
    W.locked = false
    W.pump(600)
    eq(W.ped().model, hashOf(BR.PedById(STOCK1).model), 'and is worn once it clears')
    eq(A.decodeWorn(W.kvp['br:locker2:worn']).id, STOCK1, 'and remembered')

    -- Nothing anywhere: Season 1's chosen id, never written by v2.
    local W2 = clientWorld({ season = 2, v2 = true })
    W2.pump(4500)
    eq(W2.ped().model, hashOf(W2.BR.PedById(W2.BR.Locker.chosen()).model), 'no record anywhere: chosen() as stock')
    eq(W2.kvp['br:locker:ped'], nil, 'still never writing Season 1\'s kvp')

    -- A server with no record keeps this machine's.
    local W3 = clientWorld({ season = 2, v2 = true, kvp = { ['br:locker2:worn'] = ('{"k":"s","id":"%s"}'):format(STOCK2) } })
    W3.pump(200)
    W3.net(NET.LOCKER2_STATE, { store = true, peds = {} })
    W3.pump(500)
    eq(W3.ped().model, hashOf(W3.BR.PedById(STOCK2).model), 'a server with no record: the kvp stands')

    -- The entrance waiting for its model keeps going; a walking ped is not swapped.
    local W4 = clientWorld({ season = 2, v2 = true })
    W4.pump(200)
    W4.entering, W4.locked = true, true
    W4.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK2 }, store = true, peds = {} })
    W4.pump(500)
    eq(W4.ped().model, hashOf(W4.BR.PedById(STOCK2).model), 'the first apply lands while the entrance waits for it')
    eq(#W4.stops, 0, 'without stopping the entrance')
    local W5 = clientWorld({ season = 2, v2 = true })
    W5.pump(200)
    W5.entering, W5.locked, W5.walking = true, true, true
    W5.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK2 }, store = true, peds = {} })
    W5.pump(500)
    eq(W5.count('SetPlayerModel'), 0, 'but a ped already walking is not swapped')
    W5.entering, W5.locked, W5.walking = false, false, false
    W5.pump(500)
    eq(W5.ped().model, hashOf(W5.BR.PedById(STOCK2).model), 'until it stops')
end

-- ═══ SEASON 2: THE PAGE ═══

local function joined(peds)
    local W = clientWorld({ season = 2, v2 = true })
    W.pump(200)
    W.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK1 }, store = true, peds = peds or {} })
    W.pump(500)
    return W
end

local function rowOf(msg, k)
    for _, r in ipairs(msg.edit and msg.edit.rows or {}) do
        if r.k == k then return r end
    end
    return nil
end

describe('season2.open')
do
    local W = joined()
    W.log = {}
    W.ui(NUICB.LOCKER2_OPEN)
    local msg = W.nui(NUI.LOCKER2)
    ok(msg and msg.on == true, 'opening pushes the state')
    eq(msg.tab, 'stock', 'no saved peds: it opens on Stock')
    eq(#msg.stock, #W.BR.Config.Peds, 'with today\'s stock peds')
    eq(msg.worn.id, STOCK1, 'and the worn one')
    ok(msg.peds and #msg.peds == 0, 'and no saved peds')
    for _, n in ipairs({ 'ClearPedBloodDamage', 'ResetPedVisibleDamage', 'ClearPedWetness', 'ClearPedEnvDirt' }) do
        eq(W.count(n), 1, 'clean and dry: ' .. n)
    end
    eq(W.count('ClearPedDecorations'), 0, 'never ClearPedDecorations')
    local W2 = joined({ { id = PID, name = 'Ann', a = A.encode(femaleLook()), up = 5, img = 'data:image/webp;base64,AA' } })
    W2.ui(NUICB.LOCKER2_OPEN)
    local m2 = W2.nui(NUI.LOCKER2)
    eq(m2.tab, 'peds', 'with saved peds it opens on My peds')
    ok(m2.peds[1].name == 'Ann' and m2.peds[1].a == nil, 'the cards carry no appearance')
    eq(m2.peds[1].img, nil, 'and no picture: that goes once, on its own (#28 review)')
    W2.ui(NUICB.LOCKER2_SHOTS, { ids = { PID } })
    local pic = W2.nui(NUI.LOCKER2_SHOT)
    ok(pic and pic.id == PID and pic.up == 5 and pic.img == 'data:image/webp;base64,AA' and pic.txd == nil,
        'the stored picture, when the page asks for the card')
    -- EVERY PUSH IS PICTURE-FREE, whatever is pressed: a push goes out on every
    -- press, up to one a slider's 60 ms, and saved peds have no limit.
    W2.ui(NUICB.LOCKER2_TAB, { tab = 'male', seq = 1 })
    W2.pump(300)
    for i = 1, 5 do W2.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = i * 10 }) end
    local carried = 0
    for _, e in ipairs(W2.events) do
        if e.name == 'br:ui:sendLocal' and e.args[1] == NUI.LOCKER2 then
            for _, c in ipairs(e.args[2].peds or {}) do if c.img ~= nil then carried = carried + 1 end end
        end
    end
    eq(carried, 0, 'no push carries a picture')
    eq(msg.fetching, false, 'once the server has answered, nothing is being fetched')

    -- THE LOADING ICON (owner, 2026-10-07): until the server answers, the
    -- page is told the saved peds are still coming, and opens on My peds.
    local F = clientWorld({ season = 2, v2 = true })
    F.pump(4500)
    F.ui(NUICB.LOCKER2_OPEN)
    local f1 = F.nui(NUI.LOCKER2)
    eq(f1.fetching, true, 'before the server answers, the page shows the saved peds loading')
    eq(f1.tab, 'peds', 'on My peds')
    F.ui(NUICB.LOCKER2_TAB, { tab = 'stock' })
    F.ui(NUICB.LOCKER2_TAB, { tab = 'peds' })
    eq(F.nui(NUI.LOCKER2).tab, 'peds', 'and My peds can be pressed while it loads')
    F.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK1 }, store = true, peds = {} })
    local f2 = F.nui(NUI.LOCKER2)
    ok(f2.fetching == false and f2.tab == 'stock', 'an answer of none: loaded, and Stock is the tab')
end

describe('season2.stock')
do
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.modelDelay = 300
    W.ui(NUICB.LOCKER2_WEAR, { k = 's', id = STOCK2 })
    eq(W.nui(NUI.LOCKER2).loading, STOCK2, 'a pick shows which ped is loading')
    W.ui(NUICB.LOCKER2_WEAR, { k = 's', id = STOCK1 })
    W.pump(1000)
    eq(W.ped().model, hashOf(W.BR.PedById(STOCK1).model), 'the last press wins')
    local wears = W.sentTo(NET.LOCKER2_WEAR)
    eq(wears[#wears].id, STOCK1, 'and is worn on the server')
    eq(A.decodeWorn(W.kvp['br:locker2:worn']).id, STOCK1, 'and here')
    W.neverLoad = true
    W.ui(NUICB.LOCKER2_WEAR, { k = 's', id = STOCK2 })
    W.pump(5500)
    eq(W.notify[#W.notify], 'That character could not be loaded.', 'a model that never streams says Season 1\'s words')
end

describe('season2.custom')
do
    local W = joined()
    local BR = W.BR
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male' })
    W.pump(300)
    eq(W.ped().model, MALE, 'Custom (male) wears the male freemode ped')
    local msg = W.nui(NUI.LOCKER2)
    eq(msg.tab, 'male', 'on its tab')
    ok(msg.edit and msg.edit.sex == 'm' and msg.edit.dirty == false, 'a clean draft, nothing to save')
    local bag = rowOf(msg, 'c5')
    ok(bag and bag.n == 10, 'the Bags row lists every bag drawable, parachute packs included',
        bag and bag.n)
    local hasBags = false
    for _, c in ipairs(msg.edit.cats) do if c == 'bags' then hasBags = true end end
    ok(hasBags, 'and its category is in the anchor navigation')
    local top = rowOf(msg, 'c11')
    ok(top and top.kind == 'count' and top.v == 1 and top.n == 39, 'tops count 1/39: a gen9-only drawable skipped',
        top and (top.v .. '/' .. top.n))
    local under = rowOf(msg, 'c8')
    ok(under and under.v == 1 and under.n == 40, 'the undershirt starts on none, first in its row')
    local hat = rowOf(msg, 'p0')
    ok(hat and hat.v == 1 and hat.n == 21 and hat.colors == 1, 'a hat: none first, 1/21, no color')
    local brow = rowOf(msg, 'o2')
    ok(brow and brow.n == 10 and brow.colors == 64, 'eyebrows: no none, and a color')
    local beard = rowOf(msg, 'o1')
    ok(beard and beard.n == 11 and beard.v == 1, 'facial hair: none first')
    local nose = rowOf(msg, 'ff0')
    ok(nose and nose.kind == 'slider' and nose.min == -100 and nose.max == 100 and nose.def == 0, 'a face slider')
    local chin = rowOf(msg, 'ff18')
    ok(chin and chin.min == 0, 'the chin dimple starts at 0')
    local op = rowOf(msg, 'o2op')
    ok(op and op.def == 100, 'an opacity defaults to 100')

    -- Steps wrap, apply live and make the draft dirty.
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    eq(W.ped().comps[11][1], 1, 'next puts the next top on the ped')
    msg = W.nui(NUI.LOCKER2)
    ok(msg.edit.dirty == true and rowOf(msg, 'c11').v == 2, 'shows 2/39 and the draft is dirty')
    W.ui(NUICB.LOCKER2_TAB, { tab = 'stock' })
    eq(W.nui(NUI.LOCKER2).tab, 'male', 'with unsaved changes the other tabs are refused')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = -1 })
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = -1 })
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 39, 'previous from 1 wraps to the last')
    eq(W.ped().comps[11][1], 38, 'which is drawable 38, 39 being gen9-only')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 1, 'and next from the last wraps to 1')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 2 })
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 1, 'a step of 2 is refused')

    -- Next color.
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 3 })
    eq(W.ped().comps[11][1], 2, 'set jumps to a position')
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').colors, 3, 'drawable 2 has three colors')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11' })
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11' })
    eq(W.ped().comps[11][2], 2, 'Next color steps the texture')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11' })
    eq(W.ped().comps[11][2], 0, 'and wraps')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11' })
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    eq(W.ped().comps[11][2], 0, 'a new item starts on its first color')
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 1 })
    eq(W.ped().comps[11][1], 0, 'reset puts the row back to 1')
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 40 })
    eq(W.ped().comps[11][1], 0, 'a position past the end is refused')
    W.ui(NUICB.LOCKER2_SET, { k = 'c1', v = 2 })
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c1' })
    eq(W.ped().comps[1][2], 1, 'a mask of two colors has Next color')
    W.ui(NUICB.LOCKER2_SET, { k = 'c1', v = 1 })
    eq(W.ped().comps[1][2], 0, 'and reset puts its color back too')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o2' })
    eq(W.ped().ovc[2][2], 1, 'eyebrow color, on the hair palette')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c2' })
    eq(W.ped().hair[1], 1, 'the Hair row\'s Next color is the hair color')
    W.ui(NUICB.LOCKER2_STEP, { k = 'h1', d = 1 })
    eq(W.ped().hair[2], 1, 'the Highlight row is `h1`, the name the page labels')

    -- Sliders.
    W.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 50 })
    eq(W.ped().ff[0], 0.5, 'a slider applies at once')
    W.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 101 })
    eq(W.ped().ff[0], 0.5, 'past its range it is refused, not clamped')
    W.ui(NUICB.LOCKER2_SET, { k = 'ff18', v = -1 })
    eq(W.ped().ff[18], 0, 'the chin dimple refuses a negative')
    W.ui(NUICB.LOCKER2_SET, { k = 'o2op', v = 40 })
    eq(W.ped().ov[2][2], 0.4, 'an opacity slider')
    W.ui(NUICB.LOCKER2_SET, { k = 'sk', v = 46 })
    eq(W.ped().blend[2], 45, 'skin tone 46/46 is tone 45')
    W.ui(NUICB.LOCKER2_SET, { k = 'c5', v = 2 })
    eq(W.ped().comps[5][1], 1, 'the Bags row takes a bag')
    W.ui(NUICB.LOCKER2_SET, { k = 'zz', v = 1 })

    -- The camera.
    W.ui(NUICB.LOCKER2_CAT, { cat = 'shoes' })
    eq(W.cams[#W.cams], 'focus:feet', 'Shoes moves the camera to the feet')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'bags' })
    eq(W.nui(NUI.LOCKER2).edit.cat, 'bags', 'any category is remembered')
    eq(W.cams[#W.cams], 'focus:back', 'Bags looks at the back')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'nope' })
    eq(W.cams[#W.cams], 'focus:back', 'an unknown category moves nothing')

    -- Reset.
    W.ui(NUICB.LOCKER2_RESET)
    local m3 = W.nui(NUI.LOCKER2)
    ok(m3.edit.dirty == false and rowOf(m3, 'c11').v == 1 and W.ped().ff[0] == 0.0,
        'Reset takes the draft back to where it began')
    W.ui(NUICB.LOCKER2_TAB, { tab = 'stock' })
    W.pump(300)
    eq(W.nui(NUI.LOCKER2).tab, 'stock', 'with nothing unsaved the tabs are free')
    eq(W.ped().model, hashOf(BR.PedById(STOCK1).model), 'and Stock wears the worn ped again')
    eq(W.cams[#W.cams], 'unfocus', 'with the camera home')
end

describe('season2.save')
do
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_TAB, { tab = 'female' })
    W.pump(300)
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Ann' })
    eq(#W.sentTo(NET.LOCKER2_SAVE), 0, 'nothing to save while the draft is clean')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c4', d = 1 })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'An n' })
    eq(#W.sentTo(NET.LOCKER2_SAVE), 0, 'a bad name is refused here as well')
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update' })
    eq(#W.sentTo(NET.LOCKER2_SAVE), 0, 'update with nothing being edited')
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Ann' })
    local s = W.sentTo(NET.LOCKER2_SAVE)[1]
    ok(s and s.op == 'new' and s.name == 'Ann' and s.id == nil, 'a new save names the ped')
    local sent = s and A.decode(s.a)
    ok(sent and sent.s == 'f' and sent.c[4][1] == 1, 'and carries the draft, canonical')
    eq(W.nui(NUI.LOCKER2).busy, true, 'the page is busy')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c4', d = 1 })
    eq(W.ped().comps[4][1], 1, 'and nothing changes while it is')
    local ped = { id = PID, name = 'Ann', a = s.a, up = 9 }
    W.net(NET.LOCKER2_RESULT, { req = s.req, ok = true, id = PID, ped = ped,
        worn = { k = 'p', id = PID, a = s.a } })
    local msg = W.nui(NUI.LOCKER2)
    ok(msg.busy == false and msg.edit.editing == PID and msg.edit.dirty == false,
        'saved: the draft is now that ped, clean')
    eq(#msg.peds, 1, 'and it is listed')
    eq(A.decodeWorn(W.kvp['br:locker2:worn']).id, PID, 'and worn')
    -- The headshot, off the player's own ped.
    W.pump(300)
    local shot = W.nui(NUI.LOCKER2_SHOT)
    ok(shot and shot.id == PID and shot.save == true and shot.txd ~= nil, 'a headshot of the saved ped is sent')
    ok(shot and shot.url:match('^https://nui%-img/(.-)/%1%?v=%d+$') ~= nil, 'as a nui-img url with a cache-buster')
    eq(W.shots[1].ped, W.handle, 'taken off the player\'s own ped')
    W.ui(NUICB.LOCKER2_SHOTDONE, { id = PID, ok = true })
    eq(W.shots[1].gone, true, 'unregistered when the page has it')
    local img = 'data:image/webp;base64,AAAA'
    W.ui(NUICB.LOCKER2_SHOT, { id = PID, img = img })
    local up = W.sentTo(NET.LOCKER2_SHOT)[1]
    ok(up and up.id == PID and up.img == img, 'and uploaded, whichever callback came first')
    W.ui(NUICB.LOCKER2_SHOT, { id = PID, img = img })
    eq(#W.sentTo(NET.LOCKER2_SHOT), 1, 'once')
    W.net(NET.LOCKER2_RESULT, { req = up.req, ok = true, id = PID, ped = { id = PID, name = 'Ann', a = s.a, up = 9, img = img } })
    eq(W.BR.LockerV2.state().peds[1].img, img, 'and kept for the next time the page asks for that card')

    -- Update, and a refusal.
    W.ui(NUICB.LOCKER2_STEP, { k = 'c6', d = 1 })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update' })
    local u = W.sentTo(NET.LOCKER2_SAVE)[2]
    ok(u and u.op == 'update' and u.id == PID and u.name == nil, 'Update saves over the ped being edited')
    W.net(NET.LOCKER2_RESULT, { req = u.req, ok = false, reason = 'rate' })
    eq(W.notify[#W.notify], 'Something went wrong. Try again.', 'a refusal says so')
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'and the changes are still there')
    W.ui(NUICB.LOCKER2_SAVE, { op = 'replace', id = 'nope' })
    eq(#W.sentTo(NET.LOCKER2_SAVE), 2, 'replace needs a saved ped')

    -- A write the server never answers gives the page back.
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Eve' })
    W.pump(10500)
    eq(W.nui(NUI.LOCKER2).busy, false, 'after 10 s with no answer the page is not busy')

    -- Close discards and puts the worn ped back.
    W.ui(NUICB.LOCKER2_CLOSE)
    W.pump(300)
    local m4 = W.nui(NUI.LOCKER2)
    eq(m4.edit, nil, 'close discards the draft')
    eq(W.ped().comps[6][1], 0, 'and the saved look is back on')
    eq(W.cams[#W.cams], 'unfocus', 'with the camera home')
end

describe('season2.saved')
do
    local a = femaleLook()
    local W = joined({ { id = PID, name = 'Ann', a = A.encode(a), up = 5 } })
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    W.pump(300)
    eq(W.ped().model, FEMALE, 'a card wears its ped')
    eq(W.sentTo(NET.LOCKER2_WEAR)[1].id, PID, 'and the server is told')
    W.ui(NUICB.LOCKER2_EDIT, { id = PID })
    local msg = W.nui(NUI.LOCKER2)
    ok(msg.tab == 'female' and msg.edit.editing == PID, 'Edit opens it on its own tab')
    W.ui(NUICB.LOCKER2_TAB, { tab = 'peds' })
    W.ui(NUICB.LOCKER2_RENAME, { id = PID, name = 'Eve' })
    local rn = W.sentTo(NET.LOCKER2_RENAME)[1]
    ok(rn and rn.name == 'Eve', 'Rename asks the server')
    W.net(NET.LOCKER2_RESULT, { req = rn.req, ok = true, id = PID, ped = { id = PID, name = 'Eve', a = A.encode(a), up = 6 } })
    eq(W.nui(NUI.LOCKER2).peds[1].name, 'Eve', 'and the card follows')
    W.ui(NUICB.LOCKER2_DELETE, { id = PID })
    local dl = W.sentTo(NET.LOCKER2_DELETE)[1]
    W.net(NET.LOCKER2_RESULT, { req = dl.req, ok = true, id = PID, gone = true })
    local m2 = W.nui(NUI.LOCKER2)
    ok(#m2.peds == 0 and m2.tab == 'stock', 'Delete removes the card, and with none left Stock is the tab')
    ok(m2.worn.id == PID, 'the deleted ped is still the one worn')
    -- A card with no picture is shot off a local clone.
    local W2 = joined({ { id = PID, name = 'Ann', a = A.encode(a), up = 5 } })
    W2.ui(NUICB.LOCKER2_OPEN)
    W2.ui(NUICB.LOCKER2_SHOTS, { ids = { PID, 'nope' } })
    W2.pump(600)
    eq(#W2.created, 1, 'one clone')
    eq(W2.created[1].net, false, 'never networked')
    local shot = W2.nui(NUI.LOCKER2_SHOT)
    ok(shot and shot.id == PID and shot.save == nil, 'its headshot sent, not as a save')
    W2.pump(3500)
    ok(W2.shots[1].gone and not W2.peds[W2.created[1].handle].exists, 'released and deleted after 3 s with no answer')
    W2.ui(NUICB.LOCKER2_SHOT, { id = PID, img = 'data:image/webp;base64,AAAA' })
    eq(#W2.sentTo(NET.LOCKER2_SHOT), 0, 'a clone\'s picture is never uploaded')
    -- The ped being worn is shot off the player, and a stored picture is sent as it is.
    local W3 = joined({ { id = PID, name = 'Ann', a = A.encode(a), up = 5 },
                        { id = '0abcdefgh13', name = 'Eve', a = A.encode(a), up = 6, img = 'data:image/webp;base64,BB' } })
    W3.ui(NUICB.LOCKER2_OPEN)
    W3.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    W3.pump(300)
    W3.ui(NUICB.LOCKER2_SHOTS, { ids = { PID, '0abcdefgh13' } })
    W3.pump(300)
    eq(#W3.created, 0, 'no clone for the ped being worn')
    eq(W3.shots[1] and W3.shots[1].ped, W3.handle, 'it is shot off the player')
    local stored = nil
    for _, e in ipairs(W3.events) do
        if e.name == 'br:ui:sendLocal' and e.args[1] == NUI.LOCKER2_SHOT and e.args[2].id == '0abcdefgh13' then stored = e.args[2] end
    end
    ok(stored and stored.img == 'data:image/webp;base64,BB' and stored.txd == nil, 'a stored picture is sent, not shot')
end

describe('season2.refusals')
do
    local W = joined()
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male' })
    eq(W.count('SetPlayerModel'), 1, 'nothing before the page is open')
    W.ui(NUICB.LOCKER2_OPEN)
    W.locked = true
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male' })
    W.ui(NUICB.LOCKER2_WEAR, { k = 's', id = STOCK2 })
    W.pump(300)
    eq(W.count('SetPlayerModel'), 1, 'nothing while the entrance holds the ped')
    W.locked = false
    W.season(1)
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male' })
    W.pump(300)
    ok(W.ped().model ~= MALE, 'nothing off Season 2')
end

describe('season2.lifecycle')
do
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male' })
    W.pump(300)
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    W.fire('br:ui:focusChanged', 'chat')
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'chat over the locker keeps the draft')
    W.fire('br:ui:focusChanged', 'lobby')
    eq(W.nui(NUI.LOCKER2).edit, nil, 'leaving it any other way is a close')
    W.pump(300)
    eq(W.ped().model, hashOf(W.BR.PedById(STOCK1).model), 'the worn ped is back')

    -- A match started mid-edit plays in the preview; the next lobby restores.
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_TAB, { tab = 'female' })
    W.pump(300)
    W.ui(NUICB.LOCKER2_STEP, { k = 'c4', d = 1 })
    W.BR.State.me.state = W.BR.PlayerState.ALIVE
    W.pump(300)
    eq(W.ped().model, FEMALE, 'leaving the lobby keeps the look')
    eq(W.BR.LockerV2.state().draft, nil, 'but not the draft')
    W.BR.State.me.state = W.BR.PlayerState.LOBBY
    W.pump(300)
    eq(W.ped().model, hashOf(W.BR.PedById(STOCK1).model), 'the next lobby arrival puts the worn ped back')
end

describe('season2.camera')
do
    -- #28 review: a draft started on Face with the camera wherever the last
    -- one left it, and the page sent no category it thought was current, so
    -- pressing Face never moved the camera.
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male', seq = 1 })
    W.pump(300)
    eq(W.nui(NUI.LOCKER2).edit.cat, nil, 'a new draft lights no anchor')
    eq(W.cams[#W.cams], 'unfocus', 'with the camera home on the whole ped')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'face' })
    eq(W.cams[#W.cams], 'focus:head', 'Face moves the camera to the head')
    eq(W.nui(NUI.LOCKER2).edit.cat, 'face', 'and lights Face')
    local moves, pushes = #W.cams, #W.events
    W.ui(NUICB.LOCKER2_CAT, { cat = 'face' })
    eq(#W.cams, moves, 'Face again: the camera is there already')
    eq(#W.events, pushes + 1, 'and nothing is pushed (the one event is the press itself)')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'hair' })
    eq(#W.cams, moves, 'Hair is the same shot of the head: no move')
    eq(W.nui(NUI.LOCKER2).edit.cat, 'hair', 'but Hair is lit')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'shoes' })
    eq(W.cams[#W.cams], 'focus:feet', 'Shoes: the feet')
    W.ui(NUICB.LOCKER2_TAB, { tab = 'female', seq = 2 })
    W.pump(300)
    eq(W.nui(NUI.LOCKER2).edit.cat, nil, 'Custom (female) after Shoes lights no anchor')
    eq(W.cams[#W.cams], 'unfocus', 'and brings the camera home from the feet')
    -- Edit is a new draft too.
    local P = joined({ { id = PID, name = 'Ann', a = A.encode(femaleLook()), up = 5 } })
    P.ui(NUICB.LOCKER2_OPEN)
    P.ui(NUICB.LOCKER2_TAB, { tab = 'male', seq = 1 })
    P.pump(300)
    P.ui(NUICB.LOCKER2_CAT, { cat = 'legs' })
    eq(P.focusedCam, 'legs', 'the camera on the legs')
    P.ui(NUICB.LOCKER2_TAB, { tab = 'peds', seq = 2 })
    P.pump(300)
    P.ui(NUICB.LOCKER2_EDIT, { id = PID })
    P.pump(300)
    local m = P.nui(NUI.LOCKER2)
    ok(m.tab == 'female' and m.edit.cat == nil, 'Edit: no anchor lit')
    eq(P.focusedCam, nil, 'and the camera home')
end

describe('season2.absent')
do
    -- #28 review: Next color and the opacity sliders on an overlay of none
    -- changed what nobody can see, and made the draft dirty -- the tabs locked
    -- with nothing on screen to say why.
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male', seq = 1 })
    W.pump(300)
    local m = W.nui(NUI.LOCKER2)
    for _, k in ipairs({ 'o1', 'o4', 'o5', 'o8', 'o10' }) do
        eq(rowOf(m, k).colors, 1, k .. ' of none: no Next color')
        eq(rowOf(m, k .. 'op').off, true, k .. ' of none: its opacity is off')
    end
    eq(rowOf(m, 'o2').colors, 64, 'the eyebrows are never none: they keep Next color')
    eq(rowOf(m, 'o2op').off, nil, 'and their opacity')
    eq(rowOf(m, 'p0').colors, 1, 'no hat, no Next color (as before)')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o1' })
    W.ui(NUICB.LOCKER2_SET, { k = 'o1op', v = 40 })
    m = W.nui(NUI.LOCKER2)
    eq(m.edit.dirty, false, 'Next color and opacity on none are refused: nothing to save')
    eq(W.ped().ov[1][2], 1.0, 'and nothing reaches the ped')

    -- On, then back to none: what the player cannot see is not a change.
    W.ui(NUICB.LOCKER2_STEP, { k = 'o1', d = 1 })
    m = W.nui(NUI.LOCKER2)
    ok(rowOf(m, 'o1').colors == 64 and rowOf(m, 'o1op').off == nil, 'facial hair on: Next color and opacity')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o1' })
    W.ui(NUICB.LOCKER2_SET, { k = 'o1op', v = 40 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'a color and an opacity on it are changes')
    W.ui(NUICB.LOCKER2_STEP, { k = 'o1', d = -1 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, false, 'stepped back to none: no change left to save')

    -- A row's reset puts its Next color back too, as a component's always did.
    W.ui(NUICB.LOCKER2_STEP, { k = 'o1', d = 1 })
    eq(W.ped().ovc[1][2], 1, 'on again, with the color it had')
    W.ui(NUICB.LOCKER2_SET, { k = 'o1', v = 1 })
    W.ui(NUICB.LOCKER2_STEP, { k = 'o1', d = 1 })
    eq(W.ped().ovc[1][2], 0, 'an overlay reset puts its color back')
    W.ui(NUICB.LOCKER2_RESET)
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o2' })
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'eyebrow color is a change')
    W.ui(NUICB.LOCKER2_SET, { k = 'o2', v = 1 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, false, 'and the Eyebrows reset takes it back')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c2' })
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'hair color is a change')
    W.ui(NUICB.LOCKER2_SET, { k = 'c2', v = 1 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, false, 'and the Hair reset takes it back')
    eq(W.ped().hair[1], 0, 'on the ped too')
end

describe('season2.tabseq')
do
    -- #28 review: the page moves its tab on the press. A press Lua refused
    -- (the freemode model still streaming in) left the page on Custom (female)
    -- with the male draft's rows -- and Save saved a male ped.
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    eq(W.nui(NUI.LOCKER2).tabSeq, nil, 'an opening has seen no press yet')
    W.modelDelay = 300
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male', seq = 1 })
    W.ui(NUICB.LOCKER2_TAB, { tab = 'female', seq = 2 })
    local m = W.nui(NUI.LOCKER2)
    eq(m.tab, 'male', 'Custom (female) while the male ped streams in is refused')
    eq(m.tabSeq, 2, 'and the answer says which press it saw, so the page goes back')
    W.pump(500)
    m = W.nui(NUI.LOCKER2)
    ok(m.tab == 'male' and m.edit.sex == 'm' and m.tabSeq == 2, 'the male draft, on its tab')
    W.locked = true
    W.ui(NUICB.LOCKER2_TAB, { tab = 'stock', seq = 3 })
    m = W.nui(NUI.LOCKER2)
    ok(m.tab == 'male' and m.tabSeq == 3, 'every refusal says so, the locked ped too')
    W.locked = false
    W.ui(NUICB.LOCKER2_TAB, { tab = 'male', seq = 4 })
    eq(W.nui(NUI.LOCKER2).tabSeq, 4, 'and a press of the tab already shown')
    W.ui(NUICB.LOCKER2_CLOSE)
    W.ui(NUICB.LOCKER2_OPEN)
    eq(W.nui(NUI.LOCKER2).tabSeq, nil, 'a new opening starts again')
end

describe('season2.lobbyonly')
do
    -- #28 review: a server answer that landed outside the lobby swapped the
    -- model mid-match -- a new, unarmed, frozen ped.
    local W = clientWorld({ season = 2, v2 = true, kvp = { ['br:locker2:worn'] = ('{"k":"s","id":"%s"}'):format(STOCK2) } })
    W.pump(4500)
    eq(W.ped().model, hashOf(W.BR.PedById(STOCK2).model), 'no answer: this machine has its worn ped')
    local function counts()
        return { W.count('SetPlayerModel'), W.count('FreezeEntityPosition'), W.count('initHealthModel'),
                 W.count('SetPedHeadBlendData') }
    end
    for _, st in ipairs({ 'WARMUP', 'ALIVE' }) do
        W.BR.State.me.state = W.BR.PlayerState[st]
        local before = counts()
        W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(femaleLook()) }, store = true, peds = {} })
        W.pump(1000)
        local after = counts()
        ok(after[1] == before[1] and after[2] == before[2] and after[3] == before[3] and after[4] == before[4],
            'a late answer in ' .. st .. ' swaps, freezes and dresses nothing')
    end
    W.BR.State.me.state = W.BR.PlayerState.LOBBY
    W.pump(600)
    eq(W.ped().model, FEMALE, 'it is worn at the next lobby')
    eq(W.count('SetPlayerModel'), 2, 'in one swap')

    -- A pick still streaming in when the match starts is not put on in it.
    local X = joined()
    X.ui(NUICB.LOCKER2_OPEN)
    local swaps = X.count('SetPlayerModel')
    X.modelDelay = 500
    X.ui(NUICB.LOCKER2_WEAR, { k = 's', id = STOCK2 })
    X.BR.State.me.state = X.BR.PlayerState.WARMUP
    X.pump(1500)
    eq(X.count('SetPlayerModel'), swaps, 'a pick that streams in after the lobby is left is not swapped in')
    eq(#X.notify, 0, 'and nothing says it failed')
    eq(X.BR.LockerV2.state().applying, false, 'nor is anything left in flight')
    eq(A.decodeWorn(X.kvp['br:locker2:worn']).id, STOCK1, 'the worn ped is still the one on')
    -- A Custom tab's draft likewise.
    local Y = joined()
    Y.ui(NUICB.LOCKER2_OPEN)
    Y.modelDelay = 500
    Y.ui(NUICB.LOCKER2_TAB, { tab = 'female', seq = 1 })
    Y.BR.State.me.state = Y.BR.PlayerState.WARMUP
    Y.pump(1500)
    ok(Y.ped().model ~= FEMALE, 'nor is a Custom tab draft ped')
end

describe('season2.watchstates')
do
    -- #28 review: the warmup trip resurrects the player (a new ped), and the
    -- watcher only ran in the lobby and alive, so a custom ped went bare
    -- through warmup, the plane and the drop.
    for _, st in ipairs({ 'WARMUP', 'BUS', 'FREEFALL', 'GLIDE', 'ALIVE', 'DBNO' }) do
        local W = clientWorld({ season = 2, v2 = true })
        W.pump(200)
        W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(femaleLook()) }, store = true, peds = {} })
        W.pump(600)
        W.BR.State.me.state = W.BR.PlayerState[st]
        W.handle = W.handle + 1
        W.peds[W.handle] = newPed(FEMALE)
        W.pump(1000)
        local p = W.ped()
        ok(p.blend ~= nil and p.blend[2] == 12 and p.comps[11] ~= nil and p.comps[11][1] == 6,
            'in ' .. st .. ' a new ped gets the look back')
    end
    for _, st in ipairs({ 'OUT', 'LEFT' }) do
        local W = clientWorld({ season = 2, v2 = true })
        W.pump(200)
        W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(femaleLook()) }, store = true, peds = {} })
        W.pump(600)
        W.BR.State.me.state = W.BR.PlayerState[st]
        W.handle = W.handle + 1
        W.peds[W.handle] = newPed(FEMALE)
        W.log = {}
        W.pump(2000)
        eq(#W.log, 0, st .. ': nothing is watched')
    end
end

describe('season2.watcher')
do
    local a = femaleLook()
    local W = clientWorld({ season = 2, v2 = true })
    W.pump(200)
    W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(a) }, store = true, peds = {} })
    W.pump(600)
    W.BR.State.me.state = W.BR.PlayerState.ALIVE
    W.ped().comps[11] = { 0, 0 }
    W.pump(600)
    eq(W.ped().comps[11][1], 6, 'a component the game changed is put back')
    W.ped().chute = true
    W.ped().comps[5] = { 9, 0 }
    local before = W.count('SetPedComponentVariation')
    W.pump(1100)
    eq(W.count('SetPedComponentVariation'), before, 'the bag slot is the parachute\'s while one is held')
    W.ped().chute = false
    W.ped().chuteState = 2
    W.pump(600)
    eq(W.ped().comps[5][1], 9, 'and while one is in use')
    W.ped().chuteState = -1
    W.pump(600)
    W.ped().helmet = true
    W.ped().props[0] = { 17, 0 }
    local eyes = W.count('SetPedEyeColor')
    W.pump(1100)
    eq(W.ped().props[0][1], 17, 'the hat slot is a helmet\'s while one is worn')
    eq(W.count('SetPedEyeColor'), eyes, 'and a helmet alone re-applies nothing')
    W.ped().helmet = false
    W.pump(600)
    eq(W.ped().props[0][1], 4, 'and the hat comes back after')
    -- A new handle (a resurrection) is dressed outright, even when its
    -- clothes happen to match.
    local old = W.ped()
    W.handle = W.handle + 1
    W.peds[W.handle] = newPed(FEMALE)
    for s, c in pairs(old.comps) do W.ped().comps[s] = { c[1], c[2] } end
    for s, c in pairs(old.props) do W.ped().props[s] = { c[1], c[2] } end
    W.pump(600)
    ok(W.ped().blend ~= nil and W.ped().blend[2] == 12, 'a new ped handle gets the head blend back')
    -- Nothing at all with a stock ped worn.
    local W2 = joined()
    W2.BR.State.me.state = W2.BR.PlayerState.ALIVE
    W2.log = {}
    W2.pump(10000)
    eq(#W2.log, 0, 'with a stock ped on, ten seconds of a match call no native at all')
end

describe('season2.flip')
do
    local W = clientWorld({ season = 2, v2 = true })
    W.pump(200)
    W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(femaleLook()) }, store = true, peds = {} })
    W.pump(600)
    W.ui(NUICB.LOCKER2_OPEN)
    eq(W.kvp['br:locker:ped'], nil, 'a whole Season 2 session never writes Season 1\'s kvp')
    W.season(1)
    W.pump(600)
    local msg = W.nui(NUI.LOCKER2)
    ok(msg and msg.on == false, 'a live switch to Season 1 tells the page it is off')
    eq(W.ped().model, hashOf(W.BR.PedById(W.BR.Locker.chosen()).model), 'and puts Season 1\'s ped back on')
    eq(W.cams[#W.cams], 'unfocus', 'with the camera home')
    W.season(2)
    W.pump(300)
    eq(#W.sentTo(NET.LOCKER2_FETCH), 3, 'back on Season 2 it asks the server again (after the join and the open)')

    -- A switch that lands mid-match waits for the lobby.
    local M = clientWorld({ season = 2, v2 = true })
    M.pump(200)
    M.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(femaleLook()) }, store = true, peds = {} })
    M.pump(600)
    M.BR.State.me.state = M.BR.PlayerState.ALIVE
    M.log, M.events, M.server = {}, {}, {}
    M.season(1)
    M.pump(2000)
    eq(M.count('SetPlayerModel'), 0, 'a switch to Season 1 mid-match changes no ped in the match')
    eq(locker2Traffic(M), 0, 'and tells the page nothing yet')
    M.BR.State.me.state = M.BR.PlayerState.LOBBY
    M.pump(600)
    eq(M.ped().model, hashOf(M.BR.PedById(M.BR.Locker.chosen()).model), 'then, in the lobby, Season 1\'s ped')
    eq(M.count('SetPlayerModel'), 1, 'put on once (Season 1\'s own first apply, which v2 had held)')
    ok(M.nui(NUI.LOCKER2) and M.nui(NUI.LOCKER2).on == false, 'and the page is told')

    -- A switch while the entrance walks leaves the walk alone, Season 1's own
    -- held first apply included.
    local E = clientWorld({ season = 2, v2 = true })
    E.pump(200)
    E.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(femaleLook()) }, store = true, peds = {} })
    E.pump(600)
    E.entering, E.locked, E.walking = true, true, true
    E.season(1)
    E.pump(1000)
    eq(#E.stops, 0, 'a switch to Season 1 mid-entrance does not stop the walk')
    eq(E.ped().model, FEMALE, 'or swap the ped under it')
    E.entering, E.locked, E.walking = false, false, false
    E.pump(600)
    eq(E.ped().model, hashOf(E.BR.PedById(E.BR.Locker.chosen()).model), 'Season 1\'s ped once it has arrived')
    eq(E.count('SetPlayerModel'), 2, 'in one swap')

    -- When Season 1's first apply already ran (the season was unknown for 3 s
    -- at the join), v2 puts its ped back itself -- once the walk lets go.
    local K = clientWorld({ season = nil, v2 = true })
    K.pump(3500)
    eq(K.count('SetPlayerModel'), 1, 'unknown for 3 s: Season 1 applies')
    K.season(2)
    K.pump(200)
    K.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(femaleLook()) }, store = true, peds = {} })
    K.pump(600)
    eq(K.ped().model, FEMALE, 'then Season 2 arrives and v2 wears the saved ped')
    K.locked = true
    K.season(1)
    K.pump(600)
    eq(K.ped().model, FEMALE, 'back to Season 1 with the entrance holding the ped: nothing yet')
    K.locked = false
    K.pump(600)
    eq(K.ped().model, hashOf(K.BR.PedById(K.BR.Locker.chosen()).model), 'then Season 1\'s ped, put back by v2')
end

describe('season2.stocklist')
do
    -- Season 1 drops a model this build does not have; the Stock tab is that
    -- same list, as Season 1 sends it.
    local W = clientWorld({ season = 2, v2 = true, missing = 'a_f_y_hipster_01' })
    W.fire('br:ui:ready')
    W.pump(200)
    W.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK1 }, store = true, peds = {} })
    W.pump(500)
    W.ui(NUICB.LOCKER2_OPEN)
    local s1 = W.nui(NUI.LOCKER)
    local v2 = W.nui(NUI.LOCKER2)
    eq(#v2.stock, #s1.peds, 'the Stock tab lists exactly what Season 1 sends')
    eq(#v2.stock, #W.BR.Config.Peds - 1, 'which is every stock ped but the one this build lacks')
    local has = false
    for _, p in ipairs(v2.stock) do if p.id == STOCK2 then has = true end end
    ok(not has, 'the missing one is not offered')
    W.ui(NUICB.LOCKER2_WEAR, { k = 's', id = STOCK2 })
    W.pump(600)
    eq(W.ped().model, hashOf(W.BR.PedById(STOCK1).model), 'nor can it be worn')
end

-- ═══ THE CAMERA'S FOCUS (client/lobbycam.lua) ═══

describe('lobbycam.focus')
do
    local env = newEnv()
    local log, cams, nextCam, interp = {}, {}, 100, {}
    env.print = function() end
    env.PlayerPedId = function() return 1 end
    env.GetPedBoneCoords = function(_, bone) return { x = 0.0, y = 0.0, z = bone == 31086 and 1.6 or 1.0 } end
    env.GetEntityHeading = function() return 0.0 end
    env.CreateCamWithParams = function(_, x, y, z, _, _, _, fov)
        nextCam = nextCam + 1
        cams[nextCam] = { x = x, y = y, z = z, fov = fov, live = true }
        return nextCam
    end
    env.PointCamAtCoord = function(c, x, y, z) cams[c].aim = { x = x, y = y, z = z } end
    env.DoesCamExist = function(c) return (cams[c] and cams[c].live) and 1 or 0 end
    env.DestroyCam = function(c) cams[c].live = false end
    env.SetCamActive = function() end
    env.RenderScriptCams = function() end
    env.SetCamActiveWithInterp = function(to, from, ms, e1, e2) interp[#interp + 1] = { to = to, from = from, ms = ms, e1 = e1, e2 = e2 } end
    env.IsCamInterpolating = function() return 0 end
    env.SetCamCoord = function() log[#log + 1] = 'SetCamCoord' end
    env.AddEventHandler = function() end
    env.RegisterCommand = function() end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.BR = { Config = {} }
    loadInto(env, 'br_lib/shared/enums.lua')
    loadInto(env, 'br_lib/config/locker2.lua')
    env.BR.Config.Match = { lobbyCam = { dist = 1.83, height = 0.6, aim = 0.4, offset = 0.55, fov = 50.0 },
                            lobbyPos = { x = 0.0, y = 0.0, z = 0.0, heading = 0.0 } }
    env.BR.Loop = { TICK = 'tick', register = function() end }
    env.BR.Bearing = function() return 0.0 end
    env.BR.GtaHeading = function(h) return h end
    loadInto(env, 'br_core/client/lobbycam.lua')
    local LC = env.BR.LobbyCam
    local cx, cy, cz, ax, ay, az, fov = LC.focusFrame('head')
    -- Heading 0: forward is +y, right is +x.
    ok(math.abs(cx) < 1e-9 and math.abs(cy - 0.8) < 1e-9 and math.abs(cz - 1.65) < 1e-9,
        'head: the camera 0.8 in front of the head bone, 5 cm up', ('%.3f %.3f %.3f'):format(cx, cy, cz))
    eq(fov, 40.0, 'at 40 degrees')
    local C = env.BR.Config.Match.lobbyCam
    local homeFrac = (C.offset / C.dist) / math.tan(math.rad(C.fov) / 2)
    local frac = (ax / 0.8) / math.tan(math.rad(40) / 2)
    ok(ax > 0 and math.abs(frac - homeFrac) < 1e-9, 'aimed off to the ped\'s right by the home shot\'s share of the screen')
    ok(math.abs(ay) < 1e-9 and math.abs(az - 1.65) < 1e-9, 'level with the bone')
    local bx, by, _, bax = LC.focusFrame('back')
    ok(math.abs(by + 1.5) < 1e-9 and math.abs(bx) < 1e-9, 'back: 1.5 behind the ped')
    ok(bax < 0, 'aimed to the ped\'s left, which is screen left from behind')
    ok(not LC.focus('head'), 'no focus without the lobby camera up')
    LC.start()
    ok(LC.focus('head'), 'a focus with it up')
    local last = interp[#interp]
    ok(last and last.ms == 600 and last.e1 == 1 and last.e2 == 1, 'an eased 600 ms engine interpolation')
    eq(LC.focused(), 'head', 'remembered')
    ok(LC.focus('feet') and #interp == 2, 'a second focus glides on from the first')
    ok(LC.unfocus() and LC.focused() == nil and interp[#interp].e1 == 1, 'unfocus glides home, eased')
    ok(not LC.unfocus(), 'and again is nothing')
    LC.focus('upper')
    LC.stop()
    eq(LC.focused(), nil, 'stop() forgets the focus')
    eq(#log, 0, 'never SetCamCoord')
end

-- ═══ THE WIRE ═══

describe('wire.mirror')
do
    -- The page's half (ui-src/src/bridge/types.ts) mirrors every name.
    local types = readFile('ui-src/src/bridge/types.ts') or ''
    local missing = {}
    local keys = {}
    for k in pairs(NUICB) do if k:match('^LOCKER2_') then keys[#keys + 1] = k end end
    table.sort(keys)
    for _, k in ipairs(keys) do
        if not types:find("'" .. NUICB[k] .. "'", 1, true) then missing[#missing + 1] = NUICB[k] end
    end
    for _, k in ipairs({ 'LOCKER2', 'LOCKER2_SHOT' }) do
        if not types:find("'" .. NUI[k] .. "'", 1, true) then missing[#missing + 1] = NUI[k] end
    end
    eq(#keys, 16, 'sixteen callbacks')
    ok(#missing == 0, 'bridge/types.ts carries every locker2 callback and message name', table.concat(missing, ' '))
    -- And br_ui forwards every callback to br_core.
    local nui = readFile(RES .. 'br_ui/client/nui.lua')
    local unforwarded = {}
    for _, k in ipairs(keys) do
        if not nui:find('BR.NuiCb.' .. k .. ',', 1, true) then unforwarded[#unforwarded + 1] = k end
    end
    ok(#unforwarded == 0, 'br_ui forwards every one', table.concat(unforwarded, ' '))
    for _, k in ipairs({ 'LOCKER2_FETCH', 'LOCKER2_SAVE', 'LOCKER2_RENAME', 'LOCKER2_DELETE', 'LOCKER2_WEAR',
                         'LOCKER2_SHOT', 'LOCKER2_STATE', 'LOCKER2_RESULT' }) do
        eq(NET[k], 'br:locker2:' .. k:sub(9):lower(), 'net event ' .. k)
    end
    -- Every row and category this side sends, the page has a label for
    -- (ui-src/src/screens/lockerv2/copy.ts): a key it does not know draws
    -- with no label at all. An opacity slider `oNop` is named from its `oN`.
    local copy = readFile('ui-src/src/screens/lockerv2/copy.ts') or ''
    local function block(name)
        return copy:match('export const ' .. name .. '%s*:[^=]*=%s*(%b{})') or ''
    end
    local rowLabels, catLabels = block('ROW_LABEL'), block('CAT_LABEL')
    local function labeled(src, k)
        return src:find('\n%s*' .. k .. ':%s*\'') ~= nil
    end
    local unlabeled = {}
    for _, cat in ipairs(shared.BR.Config.Locker2.categories) do
        if not labeled(catLabels, cat.id) then unlabeled[#unlabeled + 1] = cat.id end
        for _, k in ipairs(cat.rows) do
            local base = k:match('^(o%d+)op$') or k
            if not labeled(rowLabels, base) then unlabeled[#unlabeled + 1] = k end
        end
    end
    ok(#rowLabels > 2 and #catLabels > 2, 'copy.ts has its ROW_LABEL and CAT_LABEL')
    ok(#unlabeled == 0, 'the page has a label for every row and category Lua sends',
       table.concat(unlabeled, ' '))
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
