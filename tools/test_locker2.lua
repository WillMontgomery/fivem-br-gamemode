-- Locker v2 (#28, Season 2): the appearance, the server's records, the client,
-- and Season 1 left exactly as it was.
--
-- ═══ WHAT THIS DRIVES ═══
--
-- The REAL files, each in its own Lua environment so a client and a server
-- never share a BR table:
--
--   br_lib/shared/appearance.lua     the schema, its validator and its JSON
--   br_lib/config/tattoos.lua        every tattoo the shops sell (2026-10-11)
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
                     'br_lib/config/locker2.lua', 'br_lib/shared/appearance.lua',
                     'br_lib/config/tattoos.lua' }) do
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
    bad(function(a) a.zz = 1 end, 'a key the schema does not have')
    -- My Looks' two fields (2026-10-13/14): the starting face and the extras.
    bad(function(a) a.f = A.FACE_MAX + 1 end, 'a starting face past FACE_MAX')
    bad(function(a) a.f = -1 end, 'a starting face below 0')
    bad(function(a) a.f = 1.0 end, 'a float face')
    bad(function(a) a.x = 1 end, 'extras that are not a list')
    bad(function(a) a.x = { 'Cape' } end, 'an extra id that is not one\'s shape (capitals)')
    bad(function(a) a.x = { 'hat"' } end, 'an extra id that would break the JSON')
    bad(function(a) a.x = { string.rep('a', 25) } end, 'an extra id past 24')
    bad(function(a) a.x = { 'hat', 'hat' } end, 'an extra twice')
    bad(function(a) a.x = { [1] = 'hat', [3] = 'bag' } end, 'extras with a gap')
    bad(function(a) a.x = { hat = true } end, 'extras by name')
    bad(function(a)
        a.x = {}
        for i = 1, A.EXTRAS_MAX + 1 do a.x[i] = 'x' .. i end
    end, 'more extras than EXTRAS_MAX')
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
    ok(not A.isName('') and not A.isName(string.rep('a', 25))
        and not A.isName('B\195\179b') and not A.isName('a_b') and not A.isName(5),
        'never empty, long, accented, punctuated or a number')
    -- "we need to allow spaces in the ped names" (owner, 2026-10-12): words one
    -- space apart, as the page's nameOk and br_ddb's isName say.
    ok(A.isName('Bob 1') and A.isName('My Night Look') and A.isName(string.rep('a b', 8)),
        'words one space apart, 24 in all')
    ok(not A.isName(' Bob') and not A.isName('Bob ') and not A.isName('Bob  1') and not A.isName(' ')
        and not A.isName(string.rep('ab ', 8) .. 'a') and not A.isName('Bob\t1'),
        'never a space first, last or doubled, past 24, or a tab')
    local model = readFile('ui-src/src/screens/lockerv2/model.ts') or ''
    ok(model:find('/^[A-Za-z0-9]+( [A-Za-z0-9]+)*$/', 1, true) ~= nil and model:find('NAME_MAX = 24', 1, true) ~= nil,
        'the page\'s nameOk is the same rule')
    local ddbSrc = readFile('js-src/br_ddb/src/locker2.js') or ''
    ok(ddbSrc:find('/^(?=.{1,24}$)[A-Za-z0-9]+( [A-Za-z0-9]+)*$/', 1, true) ~= nil,
        'and br_ddb stores what both allow')
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

describe('appearance.mylooks')
do
    -- MY LOOKS' FIELDS (2026-10-13/14): `f` the starting face, `x` the extras
    -- in the order put on. Both optional: a look of neither is the string it
    -- always was.
    local plain = A.encode(A.default('m'))
    local a = A.default('m')
    a.f, a.x = 0, {}
    eq(A.encode(a), plain, 'face 0 and no extras write nothing: an older save is the same string')
    a.f = 5
    a.x = { 'tattoos', 'hat', 'earrings' }
    local enc = A.encode(a)
    local tail = ',"f":5,"x":["tattoos","hat","earrings"]}'
    ok(enc ~= nil and enc:sub(-#tail) == tail, 'written last, the extras in order', enc)
    local back = A.decode(enc)
    ok(back and back.f == 5 and table.concat(back.x, ',') == 'tattoos,hat,earrings', 'and read back in that order')
    ok(not A.equal(back, A.default('m')), 'a face and extras are part of the look')
    local other = A.copy(back)
    other.x = { 'hat', 'tattoos', 'earrings' }
    ok(not A.equal(other, back), 'and so is their order')
    eq(#shared.BR.Config.Locker2.faces.m, 6, 'six starting faces a sex')
    eq(shared.BR.Config.Locker2.faces.m[1], 0, 'the first his one face before My Looks')
    eq(shared.BR.Config.Locker2.faces.f[1], 21, 'and hers')
    local w = A.decodeWorn(A.encodeWorn({ k = 'p', id = '0abcdefgh12', a = back }))
    ok(w and w.a.f == 5 and #w.a.x == 3, 'the worn record carries both')
    -- A LOOK FROM ANOTHER DAY'S LISTS STILL READS (#28 review): the starting
    -- faces are a proposal to trim by eye and an extra can be retired, and a
    -- look naming one cut since stopped decoding -- left out of every fetch,
    -- its worn record refused.
    local L2c = shared.BR.Config.Locker2
    local keepFaces = L2c.faces.m
    L2c.faces.m = { 0, 4, 8, 12 }
    local older = A.default('m')
    older.f = 5
    older.x = { 'cape', 'hat' }
    local olderEnc = A.encode(older)
    local olderBack = olderEnc and A.decode(olderEnc)
    ok(olderBack and olderBack.f == 5 and table.concat(olderBack.x, ',') == 'cape,hat',
        'a face past today\'s four, and an extra today\'s list does not have, encode and decode as they were', olderEnc)
    ok(A.decodeWorn(A.encodeWorn({ k = 'p', id = '0abcdefgh12', a = older })) ~= nil, 'and the worn record reads')
    L2c.faces.m = keepFaces
    -- The extras are the page's, in its order (ui-src/src/screens/lockerv2/
    -- model.ts EXTRA_CATS), and every one but Tattoos a category here.
    local model = readFile('ui-src/src/screens/lockerv2/model.ts') or ''
    local function tsList(name)
        local body = model:match('export const ' .. name .. ' = %[(.-)%]') or ''
        local out = {}
        for id in body:gmatch("'([%w_]+)'") do out[#out + 1] = id end
        return table.concat(out, ',')
    end
    local L2 = shared.BR.Config.Locker2
    eq(table.concat(L2.extras, ','), tsList('EXTRA_CATS'), 'Lua\'s extras are the page\'s, in its order')
    local core, extras = {}, {}
    for _, cat in ipairs(L2.categories) do
        if cat.extra then extras[#extras + 1] = cat.id else core[#core + 1] = cat.id end
    end
    extras[#extras + 1] = 'tattoos'
    eq(table.concat(core, ','), tsList('CORE_CATS'), 'and its core categories, first and in order')
    eq(table.concat(extras, ','), table.concat(L2.extras, ','), 'each extra a category, Tattoos the section')
    eq(L2.historyMax, tonumber(model:match('HISTORY_MAX = (%d+)')), 'the history keeps what the page says')
    eq(L2.coalesceMs, tonumber(model:match('COALESCE_MS = (%d+)')), 'and merges a drag as the page does')
end

local TAT = shared.BR.Config.Tattoos

--- The row of the tattoo list with this label key, and its index.
local function tatRow(key)
    for i, r in ipairs(TAT.list) do
        if r[1] == key then return r, i end
    end
    return nil, nil
end

--- The first row with an overlay for one sex only, in a zone if one is named.
local function onlyFor(sex, zone)
    for i, r in ipairs(TAT.list) do
        local m, f = r[4], r[5]
        if ((sex == 'm' and m and not f) or (sex == 'f' and f and not m)) and (zone == nil or r[2] == zone) then
            return r, i
        end
    end
    return nil, nil
end

--- Every value at the far end of its range: the longest look there is.
local function longest(sex)
    local a = A.default(sex)
    a.sk, a.e, a.h = 45, 30, { 63, 63 }
    for i = 1, A.FEATURES do a.ff[i] = (i == 19 or i == 20) and 100 or -100 end
    for i = 1, A.OVERLAYS do a.o[i] = { 254, 100, 63 } end
    for i = 1, A.COMPS do a.c[i] = { 1023, 31 } end
    for i = 1, #A.PROPS do a.p[i] = { 1023, 31 } end
    return a
end

describe('tattoos.data')
do
    -- "whatever the game has include DLC sets" (owner, 2026-10-11): the shops'
    -- tattoos for the two freemode peds, and nothing that is not one.
    ok(type(TAT) == 'table' and type(TAT.list) == 'table', 'br_lib/config/tattoos.lua loads')
    eq(#TAT.list, 775, 'every shop tattoo: 775 items')
    eq(table.concat(TAT.zones, ','), 'head,torso,larm,rarm,lleg,rleg', 'six body zones, in the order drawn')
    local zoneOk = {}
    for _, z in ipairs(TAT.zones) do zoneOk[z] = true end
    local keys, names = {}, { m = {}, f = {} }
    local count, perZone = { m = 0, f = 0 }, { m = {}, f = {} }
    local bad = {}
    for _, row in ipairs(TAT.list) do
        local key, zone, coll = row[1], row[2], row[3]
        if not A.tattooPart(key) then bad[#bad + 1] = 'key ' .. tostring(key) end
        if keys[key] then bad[#bad + 1] = 'twice ' .. tostring(key) end
        keys[key] = true
        if not zoneOk[zone] then bad[#bad + 1] = 'zone ' .. tostring(zone) end
        if type(coll) ~= 'string' or not coll:match('^mp.*_overlays$') and coll ~= 'multiplayer_overlays' then
            bad[#bad + 1] = 'collection ' .. tostring(coll)
        end
        if not row[4] and not row[5] then bad[#bad + 1] = 'no overlay ' .. key end
        for sex, name in pairs({ m = row[4], f = row[5] }) do
            if name then
                local low = type(name) == 'string' and name:lower() or ''
                if low:find('hair', 1, true) or low:find('crew', 1, true) then bad[#bad + 1] = 'not a tattoo ' .. low end
                if names[sex][low] then bad[#bad + 1] = 'overlay twice ' .. low end
                names[sex][low] = true
                count[sex] = count[sex] + 1
                perZone[sex][zone] = (perZone[sex][zone] or 0) + 1
            end
        end
    end
    ok(#bad == 0, 'every row: a TAT_<set>_<nnn> key once, a zone, an MP collection, an overlay for a sex, '
        .. 'never a hair overlay or a crew emblem', table.concat(bad, '; '))
    eq(count.m, 744, 'the male ped has 744 tattoos')
    eq(count.f, 746, 'the female ped 746')
    local every = true
    for _, z in ipairs(TAT.zones) do every = every and (perZone.m[z] or 0) > 0 and (perZone.f[z] or 0) > 0 end
    ok(every, 'every zone has tattoos for both')
    for _, coll in ipairs({ 'mpHeist4_overlays', 'mpSecurity_overlays', 'mpSum2_overlays',
                            'mpChristmas3_overlays', 'mp2023_02_overlays' }) do
        local n = 0
        for _, row in ipairs(TAT.list) do if row[3] == coll then n = n + 1 end end
        ok(n > 0, 'DLC sets are in: ' .. coll, n)
    end
    local fm204 = tatRow('TAT_FM_204')
    ok(fm204 and fm204[4] == 'FM_Tat_M_000' and fm204[5] == false,
        'a shop item whose overlay the game lacks for one sex is that sex\'s none (TAT_FM_204)')
    ok(onlyFor('m') ~= nil and onlyFor('f') ~= nil, 'and some tattoos are one sex\'s alone')
    -- A collection newer than 1604 names the build that has it, never one the
    -- server does not run.
    local enforced = tonumber((readFile('server.cfg.example') or ''):match('\nsv_enforceGameBuild%s+(%d+)'))
    local used = {}
    for _, row in ipairs(TAT.list) do used[row[3]] = true end
    local badBuild = {}
    for coll, b in pairs(TAT.builds) do
        if not used[coll] or math.type(b) ~= 'integer' or not enforced or b > enforced then
            badBuild[#badBuild + 1] = coll
        end
    end
    ok(enforced ~= nil and #badBuild == 0, 'every gated set is in the list and on the enforced build',
        table.concat(badBuild, ' '))
    local src = readFile(RES .. 'br_lib/config/tattoos.lua') or ''
    ok(src:find('DurtyFree/gta-v-data-dumps', 1, true) and src:find('root-cause/v-tattoos', 1, true),
        'its header cites where the list came from')
end

describe('appearance.tattoos')
do
    local base = A.encode(A.default('m'))
    ok(not base:find('"t"', 1, true), 'no tattoos, no `t`: a save from before tattoos encodes as it did')
    local old = A.decode(base)
    ok(old and old.t == nil and #A.tattoos(old) == 0, 'and an old save reads as none')
    local a = A.default('m')
    ok(A.setTattoo(a, 'TAT_FM_012', true) and A.setTattoo(a, 'TAT_AR_002', true) and A.setTattoo(a, 'TAT_AR_000', true),
        'tattoos go on by the game\'s label key')
    eq(A.encode(a):match(',"t":(%b{})}$'), '{"AR":"5","FM":"0001"}', 'one hex string per set, sets sorted, last')
    ok(A.hasTattoo(a, 'TAT_AR_002') and not A.hasTattoo(a, 'TAT_AR_001'), 'read back one by one')
    eq(table.concat(A.tattoos(a), ','), 'TAT_AR_000,TAT_AR_002,TAT_FM_012', 'or all at once, sorted')
    ok(A.equal(A.decode(A.encode(a)), a), 'and round-trip')
    ok(not A.equal(a, A.default('m')), 'a look with a tattoo is not the look without')
    A.setTattoo(a, 'TAT_FM_012', false)
    eq(A.encode(a):match(',"t":(%b{})}$'), '{"AR":"5"}', 'off drops a set left empty')
    A.setTattoo(a, 'TAT_AR_000', false)
    A.setTattoo(a, 'TAT_AR_002', false)
    eq(A.encode(a), base, 'and with none on, `t` itself')
    ok(not A.setTattoo(a, 'FM_Tat_M_000', true) and not A.setTattoo(a, 'TAT_AR_1', true)
        and not A.setTattoo(a, 42, true), 'a key that is not TAT_<set>_<nnn> is no tattoo')
    ok(not A.setTattoo(a, 'TAT_ar_001', true) and not A.setTattoo(a, 'TAT__AR_001', true)
        and not A.setTattoo(a, 'TAT_AR__X_001', true) and a.t == nil,
        'nor one whose set is not capitals and digits joined by one _, which `t` could not store')
    eq(table.concat(A.tattoos({ t = { ar = '1', AR = '1' } }), ','), 'TAT_AR_000',
        'and a set that is not one reads as no tattoo')
    local nc = A.decode(base:sub(1, -2) .. ',"t":{"FM":"0100","AR":"50","X7":"","ZZ":"000"}}')
    ok(nc ~= nil, 'a `t` out of canonical form is read')
    eq(nc and A.encode(nc):match(',"t":(%b{})}$'), '{"AR":"5","FM":"01"}',
        'and written canonical: sorted, no trailing zero, no empty set')
    local empty = A.decode(base:sub(1, -2) .. ',"t":{}}')
    eq(empty and A.encode(empty), base, '{} is written as no `t`')
    -- A set or a number no list knows is the SHAPE of a tattoo: kept, skipped
    -- where tattoos are put on (season2.tattoo_paths), never refused.
    local unk = A.decode(base:sub(1, -2) .. ',"t":{"ZZ9":"f","AR":"0008"}}')
    ok(unk ~= nil, 'a set or a number no list knows is not refused')
    eq(unk and A.encode(unk):match(',"t":(%b{})}$'), '{"AR":"0008","ZZ9":"f"}', 'and is kept as it was')
    local function badT(t, label)
        local x = A.default('m')
        x.t = t
        ok(not A.validate(x) and A.encode(x) == nil, label)
    end
    badT('AR', '`t` that is not an object')
    badT({ ar = '1' }, 'a set in lower case')
    badT({ AR = 'g' }, 'a digit that is not hex')
    badT({ AR = 'F' }, 'upper-case hex')
    badT({ AR = 5 }, 'a number for a set')
    badT({ AR = string.rep('f', 251) }, 'past 250 digits')
    badT({ _AR = '1' }, 'a set starting with _')
    badT({ AR__X = '1' }, 'a set with __')
    badT({ [string.rep('A', 17)] = '1' }, 'a set name past 16')
    badT({ '1' }, 'an array')
    -- THE FORMAT HAS NO CAP: every tattoo of the list on the longest look
    -- there is still fits, and so does the worn record carrying it. The cap of
    -- 10 a zone (owner, 2026-10-12) is the saver's, below.
    for _, sex in ipairs({ 'm', 'f' }) do
        local all = longest(sex)
        for _, row in ipairs(TAT.list) do A.setTattoo(all, row[1], true) end
        local str = A.encode(all)
        ok(str ~= nil and #str <= A.MAX_BYTES, sex .. ': every tattoo on the longest look fits in MAX_BYTES',
            str and #str)
        local back = str and A.decode(str)
        eq(back and #A.tattoos(back), #TAT.list, sex .. ': and every one survives the round trip')
        local w = A.encodeWorn({ k = 'p', id = '0abcdefgh12', a = all })
        ok(w ~= nil and #w <= A.MAX_BYTES + 64 and A.decodeWorn(w) ~= nil, sex .. ': the worn record too', w and #w)
    end
    local js = readFile('js-src/br_ddb/src/locker2.js') or ''
    eq(tonumber(js:match('APPEARANCE_MAX = (%d+)')), A.MAX_BYTES,
        'br_ddb stores the same 2048 bytes, so the database takes every tattoo too')

    -- "You can just make it max 10 per category" (owner, 2026-10-12).
    eq(A.TATTOOS_PER_ZONE, 10, 'max 10 tattoos a body zone')
    local function zoneOf(key, sex)
        local r = tatRow(key)
        return r and r[sex == 'f' and 5 or 4] and r[2] or nil
    end
    local function nOf(zone, sex, n)
        local out = {}
        for _, r in ipairs(TAT.list) do
            if #out < n and r[2] == zone and r[sex == 'f' and 5 or 4] then out[#out + 1] = r[1] end
        end
        return out
    end
    local capped = A.default('f')
    for _, key in ipairs(nOf('torso', 'f', 10)) do A.setTattoo(capped, key, true) end
    for _, key in ipairs(nOf('head', 'f', 10)) do A.setTattoo(capped, key, true) end
    ok(not A.tattoosOverCap(capped, zoneOf), '10 in each of two zones: not over')
    local _, mOnly = onlyFor('m', 'torso')
    local withHis = A.copy(capped)
    A.setTattoo(withHis, TAT.list[mOnly][1], true)
    A.setTattoo(withHis, 'TAT_ZZ_001', true)
    ok(not A.tattoosOverCap(withHis, zoneOf),
        'an 11th on her torso that only he wears, or one no list knows, is not counted')
    local eleven = A.copy(capped)
    A.setTattoo(eleven, nOf('torso', 'f', 11)[11], true)
    ok(A.tattoosOverCap(eleven, zoneOf), 'an 11th in a zone is over')
    ok(A.validate(eleven) and A.decode(A.encode(eleven)) ~= nil, 'and still reads: the cap is the saver\'s, not the format\'s')
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
                         'br_lib/shared/appearance.lua', 'br_lib/config/tattoos.lua' }) do
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
    -- THE RECORD IS READ ONCE AND KEPT (#28 lag: every open read every look
    -- and headshot again). Every write goes through here, so the cache is the
    -- record until cacheMs.
    eq(#W.ddbCalls, 1, 'from the cache: every look is read from the database once')
    -- The cache answers another player of the same license (a second session).
    W.BR.Identity.ofPlayer = function() return { license = 'p1' } end
    W.net(NET.LOCKER2_FETCH, 3, {})
    eq(W.last(NET.LOCKER2_STATE).target, 3, 'another session of that license is answered at once')
    eq(#W.ddbCalls, 1, 'from the cache')
    eq(W.BR.Config.Locker2.cacheMs, 600000, 'kept ten minutes')
    W.advance(W.BR.Config.Locker2.cacheMs - 6000)
    W.net(NET.LOCKER2_FETCH, 3, {})
    eq(#W.ddbCalls, 1, 'just inside ten minutes: still the cache')
    W.advance(6000)
    W.net(NET.LOCKER2_FETCH, 3, {})
    eq(#W.ddbCalls, 2, 'then the database is read again')

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
    eq(#W.ddbCalls, 1, 'one read: the second answer is the cache')
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

    -- MY LOOKS' SAVE (2026-10-13): the dialog shows the look's name, and an
    -- update saves the name typed there too. Words one space apart.
    W.advance(2000)
    W.net(NET.LOCKER2_SAVE, 1, { req = 41, op = 'update', id = id, name = 'Night Bob', a = enc })
    r = W.lastResult()
    ok(r.ok == true and r.ped.name == 'Night Bob', 'an update with a name renames as it saves')
    eq(W.ddb['license:p1'].peds[id].n, 'Night Bob', 'in the row')
    W.advance(2000)
    W.net(NET.LOCKER2_SAVE, 1, { req = 42, op = 'update', id = id, name = 'Night  Bob', a = enc })
    eq(W.lastResult().reason, 'name', 'an update with a bad name is refused name')
    eq(W.ddb['license:p1'].peds[id].n, 'Night Bob', 'and nothing is written')
    W.advance(2000)
    W.net(NET.LOCKER2_SAVE, 1, { req = 43, op = 'new', name = 'My Look', a = enc })
    ok(W.lastResult().ok and W.lastResult().ped.name == 'My Look', 'a new look named with a space')

    -- Refusals, in order.
    local function refused(payload, want, label)
        W.advance(2000)
        W.net(NET.LOCKER2_SAVE, 1, payload)
        eq(W.lastResult().reason, want, label)
    end
    refused({ req = 5, op = 'new', name = 'Bo  b', a = enc }, 'name', 'a name with two spaces together')
    refused({ req = 51, op = 'new', name = ' Bob', a = enc }, 'name', 'a name starting with a space')
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
    W.net(NET.LOCKER2_RENAME, 1, { req = 2, id = id, name = 'Bad  Name' })
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
    -- A later read that fails, after one that worked, stops the writes again
    -- (one past the cache: inside it nothing is read).
    W.advance(W.BR.Config.Locker2.cacheMs)
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

describe('server.unconfirmed')
do
    -- A WRITE THE DATABASE DID NOT CONFIRM (#28 review): ask gives up after
    -- 6 s and answers store, but the write can still land -- and the cache
    -- then answered every fetch without it for cacheMs.
    local L2s = nil
    local W = serverWorld(2)
    L2s = W.BR.Config.Locker2
    W.net(NET.LOCKER2_FETCH, 1, {})
    W.held = true
    W.net(NET.LOCKER2_SAVE, 1, { req = 1, op = 'new', name = 'Slow', a = A.encode(A.default('m')) })
    W.advance(6000)
    eq(W.lastResult().reason, 'store', 'no answer in 6 s: store')
    W.held = false
    W.flush()
    local id = next(W.ddb['license:p1'].peds)
    ok(id ~= nil, 'and the database took the row all the same, late')
    W.advance(L2s.fetchMs)
    local reads = #W.ddbCalls
    W.net(NET.LOCKER2_FETCH, 1, {})
    eq(#W.ddbCalls, reads + 1, 'so the next fetch reads the database again, well inside cacheMs')
    local st = W.last(NET.LOCKER2_STATE)
    ok(st and #st.p.peds == 1 and st.p.peds[1].id == id, 'and lists that look')
    -- A confirmed write keeps the cache: it IS the record.
    W.advance(L2s.fetchMs)
    W.net(NET.LOCKER2_SAVE, 1, { req = 2, op = 'new', name = 'Quick', a = A.encode(A.default('f')) })
    ok(W.lastResult().ok, 'a write the database confirms')
    W.advance(L2s.fetchMs)
    reads = #W.ddbCalls
    W.net(NET.LOCKER2_FETCH, 1, {})
    eq(#W.ddbCalls, reads, 'is answered from the cache')
    eq(#W.last(NET.LOCKER2_STATE).p.peds, 2, 'with it in')
    -- Every write the same: an error answer from each of them.
    local nameOf = { pedPut = 'a save', pedRename = 'a rename', pedShot = 'a headshot', pedDelete = 'a delete' }
    for _, verb in ipairs({ 'pedPut', 'pedRename', 'pedShot', 'pedDelete' }) do
        W.advance(L2s.fetchMs)
        W.failNext = verb
        local req = 10 + #W.ddbCalls
        if verb == 'pedPut' then
            W.net(NET.LOCKER2_SAVE, 1, { req = req, op = 'update', id = id, a = A.encode(A.default('m')) })
        elseif verb == 'pedRename' then
            W.net(NET.LOCKER2_RENAME, 1, { req = req, id = id, name = 'Renamed' })
        elseif verb == 'pedShot' then
            W.net(NET.LOCKER2_SHOT, 1, { req = req, id = id, img = 'data:image/webp;base64,AAAA' })
        else
            W.net(NET.LOCKER2_DELETE, 1, { req = req, id = id })
        end
        eq(W.lastResult().reason, 'store', nameOf[verb] .. ' the database refused: store')
        W.advance(L2s.fetchMs)
        reads = #W.ddbCalls
        W.net(NET.LOCKER2_FETCH, 1, {})
        eq(#W.ddbCalls, reads + 1, '...and the next fetch reads again')
    end
    -- A READ THAT FAILED is never answered from the cache, however fresh.
    local F = serverWorld(2)
    F.net(NET.LOCKER2_FETCH, 1, {})
    F.advance(L2s.cacheMs)
    F.failNext = 'lockerFetch'
    F.net(NET.LOCKER2_FETCH, 1, {})
    eq(F.last(NET.LOCKER2_STATE).p.store, false, 'a read that fails after one that worked: store false')
    F.advance(L2s.fetchMs)
    reads = #F.ddbCalls
    F.net(NET.LOCKER2_FETCH, 1, {})
    eq(#F.ddbCalls, reads + 1, 'the next fetch reads again, inside cacheMs of the failed one')
    eq(F.last(NET.LOCKER2_STATE).p.store, true, 'and works again')
    -- A LOOK FROM ANOTHER DAY'S LISTS is fetched (#28 review): a face past
    -- today's list and an extra today's does not have.
    local C2 = serverWorld(2)
    C2.BR.Config.Locker2.faces.m = { 0, 4, 8, 12 }
    local older = A.default('m')
    older.f, older.x = 5, { 'cape', 'hat' }
    C2.ddb['license:p1'] = { profile = { locker2 = A.encodeWorn({ k = 'p', id = '0abcdefgh12', a = older }) },
        peds = { ['0abcdefgh12'] = { n = 'Old', a = A.encode(older), cr = 1, up = 2 } } }
    C2.net(NET.LOCKER2_FETCH, 1, {})
    st = C2.last(NET.LOCKER2_STATE)
    ok(st and #st.p.peds == 1 and st.p.worn and st.p.worn.id == '0abcdefgh12',
        'a look with face 5 of four and a retired extra is listed, and worn')
end

describe('server.tattoos')
do
    local W = serverWorld(2)
    local a = A.default('f')
    A.setTattoo(a, 'TAT_X7_031', true)
    A.setTattoo(a, 'TAT_BB_000', true)
    local enc = A.encode(a)
    local oldA = A.encode(A.default('m'))
    W.ddb['license:p1'] = { profile = {}, peds = {
        ['0abcdefgh11'] = { n = 'Old', a = oldA, cr = 1, up = 1 },
        ['0abcdefgh12'] = { n = 'Odd', a = oldA:sub(1, -2) .. ',"t":{"ZZ":"1"}}', cr = 1, up = 1 },
    } }
    W.net(NET.LOCKER2_FETCH, 1, {})
    eq(#W.last(NET.LOCKER2_STATE).p.peds, 2, 'a save from before tattoos and one naming a set nobody knows both load')
    W.net(NET.LOCKER2_SAVE, 1, { req = 1, op = 'new', name = 'Inked', a = enc })
    local r = W.lastResult()
    ok(r.ok == true and W.ddb['license:p1'].peds[r.id].a == enc, 'a save with tattoos is stored, canonical')
    ok(enc:find(',"t":{"BB":"1","X7":"00000008"}}', 1, true) ~= nil, 'with its `t`', enc:sub(-40))
    W.advance(100)
    local worn = A.decodeWorn(W.ddb['license:p1'].profile.locker2)
    ok(worn and A.hasTattoo(worn.a, 'TAT_X7_031') and A.hasTattoo(worn.a, 'TAT_BB_000'), 'and worn with them')
    local spaced = enc:sub(1, -3) .. ',"AR":"0"}}'
    W.advance(2000)
    W.net(NET.LOCKER2_SAVE, 1, { req = 2, op = 'update', id = r.id, a = spaced })
    eq(W.ddb['license:p1'].peds[r.id].a, enc, 'an empty set sent is not stored')
    -- Through the database and back: a new session reads the tattoos.
    local W2 = serverWorld(2)
    W2.ddb = W.ddb
    W2.net(NET.LOCKER2_FETCH, 1, {})
    local back = nil
    for _, p in ipairs(W2.last(NET.LOCKER2_STATE).p.peds) do
        if p.id == r.id then back = A.decode(p.a) end
    end
    ok(back and table.concat(A.tattoos(back), ',') == 'TAT_BB_000,TAT_X7_031', 'a new session reads them back')

    -- MAX 10 PER ZONE (owner, 2026-10-12): a save past it is refused, and a
    -- ped stored the day there was no cap still reads.
    local function hers(zone, n)
        local out = {}
        for _, row in ipairs(TAT.list) do
            if #out < n and row[2] == zone and row[5] then out[#out + 1] = row[1] end
        end
        return out
    end
    local ten = A.default('f')
    for _, key in ipairs(hers('torso', 10)) do A.setTattoo(ten, key, true) end
    for _, key in ipairs(hers('head', 10)) do A.setTattoo(ten, key, true) end
    local _, mOnly = onlyFor('m', 'torso')
    A.setTattoo(ten, TAT.list[mOnly][1], true)
    local eleven = A.copy(ten)
    A.setTattoo(eleven, hers('torso', 11)[11], true)
    local W3 = serverWorld(2)
    W3.ddb['license:p1'] = { profile = {}, peds = {
        ['0abcdefgh13'] = { n = 'Old', a = A.encode(eleven), cr = 1, up = 1 },
    } }
    W3.net(NET.LOCKER2_FETCH, 1, {})
    local listed = W3.last(NET.LOCKER2_STATE).p.peds
    ok(#listed == 1 and listed[1].a == A.encode(eleven), 'a ped stored with 11 in a zone still reads, as it was')
    local calls = #W3.ddbCalls
    W3.net(NET.LOCKER2_SAVE, 1, { req = 1, op = 'new', name = 'Over', a = A.encode(eleven) })
    eq(W3.lastResult().reason, 'appearance', 'a save with 11 tattoos in one zone is refused')
    eq(#W3.ddbCalls, calls, 'before the database is asked anything')
    W3.advance(2000)
    W3.net(NET.LOCKER2_SAVE, 1, { req = 2, op = 'update', id = '0abcdefgh13', a = A.encode(eleven) })
    eq(W3.lastResult().reason, 'appearance', 'and so is an update of the old ped with all 11')
    W3.advance(2000)
    W3.net(NET.LOCKER2_SAVE, 1, { req = 3, op = 'new', name = 'Ten', a = A.encode(ten) })
    local rt = W3.lastResult()
    ok(rt.ok == true and W3.ddb['license:p1'].peds[rt.id].a == A.encode(ten),
        '10 in each of two zones is stored, one only he wears not counted against her')
    -- The server has the list: br_core loads it in shared_scripts.
    local manifest = readFile(RES .. 'br_core/fxmanifest.lua') or ''
    local sharedBlock = manifest:match('\nshared_scripts%s*(%b{})') or ''
    local clientBlock = manifest:match('\nclient_scripts%s*(%b{})') or ''
    ok(sharedBlock:find("'@br_lib/config/tattoos.lua'", 1, true) ~= nil
        and not clientBlock:find("'@br_lib/config/tattoos.lua'", 1, true),
        'br_core loads the tattoo list on both sides, once')
end

-- ═══════════════════════════════════════════════════════════════════════════
-- 3. THE CLIENT, over a modeled ped
-- ═══════════════════════════════════════════════════════════════════════════

local MALE = hashOf('mp_m_freemode_01')
local FEMALE = hashOf('mp_f_freemode_01')
local DEFAULT_PED = hashOf('player_default')

local function newPed(model)
    return { model = model, comps = {}, props = {}, ff = {}, ov = {}, ovc = {}, hair = nil, eye = nil,
             blend = nil, blendAt = 0, x = 10.0, y = 20.0, z = 30.0, h = 90.0, exists = true, decos = {} }
end

--- A client. opts: season (nil unknown), v2 (load Locker v2), kvp, quiet.
local function clientWorld(opts)
    opts = opts or {}
    local env = newEnv()
    local W = { time = 1000, log = {}, events = {}, server = {}, kvp = deepCopy(opts.kvp or {}),
                invalid = {}, texCount = {}, propTex = {}, shop = {}, forced = {}, invokes = {}, drawCount = {},
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
        -- An engine whose head blend takes the decorations with it, if asked.
        if W.blendTakesTattoos then p.decos = {} end
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
    N.GetNumberOfPedDrawableVariations = function(_, s) return W.drawCount[s] or (s == 5 and 10 or (s == 2 and 30 or 40)) end
    N.GetNumberOfPedTextureVariations = function(_, s, d) return W.texCount[s .. ':' .. d] or ((d % 3) + 1) end
    N.GetNumberOfPedPropDrawableVariations = function() return 20 end
    N.GetNumberOfPedPropTextureVariations = function(_, s, d) return W.propTex[s .. ':' .. d] or ((d % 2) + 1) end
    -- What the game says it draws: everything but W.invalid's `slot:d` and
    -- `slot:d:t` (#28: "if the answer is it doesn't draw anything - then
    -- remove that item from the list entirely").
    N.IsPedComponentVariationValid = function(_, s, d, t)
        return (W.invalid[s .. ':' .. d] or W.invalid[s .. ':' .. d .. ':' .. t]) and 0 or 1
    end
    -- The shop data: W.shop's `slot:d:t` -> an item's hash, W.forced's hash ->
    -- { { nameHash, enumValue, componentType }... } (GET_FORCED_COMPONENT).
    N.GetHashNameForComponent = function(_, s, d, t) return W.shop[s .. ':' .. d .. ':' .. t] or 0 end
    N.GetShopPedApparelForcedComponentCount = function(h) return #(W.forced[h] or {}) end
    N.GetForcedComponent = function(h, i)
        local f = W.forced[h][i + 1]
        return f[1], f[2], f[3]
    end
    N.GetPedHairRgbColor = function(i) return i, (i * 2) % 256, 255 - i end
    N.GetPedMakeupRgbColor = function(i) return 255 - i, i, (i * 3) % 256 end
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
    N.ClearPedDecorations = function(h) P(h).decos = {} end
    -- Decorations as the engine keeps them: a list per ped, at most decoCap.
    N.AddPedDecorationFromHashes = function(h, c, o)
        local d = P(h).decos
        if #d < (W.decoCap or math.huge) then d[#d + 1] = { c, o } end
    end
    N.GetPedDecorations = function(h)
        local out = {}
        for i, d in ipairs(P(h).decos) do out[i] = { d[1], d[2] } end
        return out
    end
    -- The game's text: every label but the ones it has none for.
    N.GetLabelText = function(k) return (W.noLabel or { TAT_AW_000 = true })[k] and 'NULL' or ('Label ' .. k) end
    N.GetGameBuildNumber = function() return W.build or 3889 end
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
        -- Only the item names (off unless BR.Config.Locker2.names says) call
        -- natives by hash: recorded, and answering none.
        InvokeNative = function(h, ...)
            W.invokes[#W.invokes + 1] = h
            return 0
        end,
        ResultAsInteger = function() return 'int' end,
    }

    env.BR = { Config = {} }
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua', 'br_lib/config/peds.lua',
                         'br_lib/shared/season.lua', 'br_lib/config/seasons.lua',
                         'br_lib/config/locker2.lua', 'br_lib/shared/appearance.lua',
                         'br_lib/config/tattoos.lua' }) do
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
        zoom = function(d) W.cams[#W.cams + 1] = 'zoom:' .. d return true end,
        resetView = function(p) W.cams[#W.cams + 1] = 'reset:' .. tostring(p) W.focusedCam = p return true end,
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
    -- The entrance splits the same expression (#406): wantHash() is asked on
    -- every poll, and Season 1's half is worked out once and kept, because it
    -- cannot move while the walk waits.
    local lobbyped = readFile(RES .. 'br_core/client/lobbyped.lua')
    ok(lobbyped:find('local v2 = BR.LockerV2 and BR.LockerV2.wantHash()\n'
        .. '        if v2 then return v2 end\n', 1, true) ~= nil
        and lobbyped:find('s1Want = GetHashKey(BR.PedById(BR.Locker.chosen()).model)', 1, true) ~= nil,
        'and so does client/lobbyped.lua\'s entrance, wantHash first and Season 1\'s model when it says nil')
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

--- The pushes the page has had, oldest first.
local function pushes(W)
    local out = {}
    for _, e in ipairs(W.events) do
        if e.name == 'br:ui:sendLocal' and e.args[1] == NUI.LOCKER2 then out[#out + 1] = e.args[2] end
    end
    return out
end

--- A Lua list as it reaches the page: an empty one is a table all the same.
local function listOf(v) return type(v) == 'table' and v or {} end

--- A world editing a saved look (`a`, the default male look if none), the
--- page open on it: My Looks' Edit. `peds` are saved beside it.
local function editing(a, peds)
    local list = { { id = PID, name = 'Base', a = A.encode(a or A.default('m')), up = 5 } }
    for _, p in ipairs(peds or {}) do list[#list + 1] = p end
    local W = joined(list)
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    W.pump(300)
    return W
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
    eq(W2.nui(NUI.LOCKER2_SHOT), nil, 'not in the frame the page asked in: it is still revealing (#28 lag)')
    W2.pump(50)
    local pic = W2.nui(NUI.LOCKER2_SHOT)
    ok(pic and pic.id == PID and pic.up == 5 and pic.img == 'data:image/webp;base64,AA' and pic.txd == nil,
        'the stored picture, a frame later')
    -- EVERY PUSH IS PICTURE-FREE, whatever is pressed: a push goes out on every
    -- press, up to one a slider's 60 ms, and saved peds have no limit.
    W2.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    W2.pump(300)
    for i = 1, 5 do W2.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = i * 10 }) end
    local carried = 0
    for _, e in ipairs(pushes(W2)) do
        for _, c in ipairs(e.peds or {}) do if c.img ~= nil then carried = carried + 1 end end
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
    F.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK1 }, store = true, peds = {} })
    local f2 = F.nui(NUI.LOCKER2)
    ok(f2.fetching == false and f2.tab == 'stock', 'an answer of none: loaded, and Stock is the tab')
end

describe('season2.openpath')
do
    -- THE OPEN, MEASURED (#28 lag): three full pushes, a database read of every
    -- look and headshot, and clone headshots one after another, on every open.
    local img = 'data:image/webp;base64,AA'
    local W = joined({ { id = PID, name = 'Ann', a = A.encode(femaleLook()), up = 5, img = img } })
    local fetches = #W.sentTo(NET.LOCKER2_FETCH)
    eq(fetches, 1, 'the join asked for the saved looks once')
    local before = #pushes(W)
    W.ui(NUICB.LOCKER2_OPEN)
    eq(#pushes(W) - before, 1, 'an open is one push')
    eq(#W.sentTo(NET.LOCKER2_FETCH), fetches, 'and asks the server nothing: the join\'s answer is current')
    W.ui(NUICB.LOCKER2_CLOSE)
    W.pump(1000)
    W.ui(NUICB.LOCKER2_OPEN)
    eq(#W.sentTo(NET.LOCKER2_FETCH), fetches, 'nor does the next open')
    W.ui(NUICB.LOCKER2_CLOSE)
    W.pump(W.BR.Config.Locker2.refreshMs)
    W.ui(NUICB.LOCKER2_OPEN)
    eq(#W.sentTo(NET.LOCKER2_FETCH), fetches + 1, 'an answer refreshMs old is asked for again')
    -- An answer that never came, or a server that could not read them.
    local N0 = clientWorld({ season = 2, v2 = true })
    N0.pump(6000)
    N0.ui(NUICB.LOCKER2_OPEN)
    eq(#N0.sentTo(NET.LOCKER2_FETCH), 2, 'no answer since the join: the open asks again')
    N0.ui(NUICB.LOCKER2_CLOSE)
    N0.ui(NUICB.LOCKER2_OPEN)
    eq(#N0.sentTo(NET.LOCKER2_FETCH), 2, 'but not twice inside fetchMs')
    local S0 = clientWorld({ season = 2, v2 = true })
    S0.pump(200)
    S0.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK1 }, store = false })
    S0.pump(500)
    S0.ui(NUICB.LOCKER2_OPEN)
    eq(#S0.sentTo(NET.LOCKER2_FETCH), 2, 'a server that could not read them: the open asks again')

    -- HEADSHOTS NEVER HITCH THE OPEN: the stored pictures a frame apart, the
    -- first clone shotDelayMs after the page asks, the next shotGapMs after.
    local H = joined({ { id = PID, name = 'Ann', a = A.encode(femaleLook()), up = 5 },
                       { id = '0abcdefgh13', name = 'Eve', a = A.encode(femaleLook()), up = 6, img = img },
                       { id = '0abcdefgh14', name = 'Zoe', a = A.encode(femaleLook()), up = 7, img = img },
                       { id = '0abcdefgh15', name = 'Ivy', a = A.encode(femaleLook()), up = 8 } })
    H.ui(NUICB.LOCKER2_OPEN)
    local asked = H.time
    H.ui(NUICB.LOCKER2_SHOTS, { ids = { PID, '0abcdefgh13', '0abcdefgh14', '0abcdefgh15' } })
    local function sent()
        local n = 0
        for _, e in ipairs(H.events) do
            if e.name == 'br:ui:sendLocal' and e.args[1] == NUI.LOCKER2_SHOT and e.args[2].img then n = n + 1 end
        end
        return n
    end
    eq(sent(), 0, 'nothing in the frame the page asked in')
    H.pump(50)
    eq(sent(), 1, 'one stored picture a frame')
    H.pump(50)
    eq(sent(), 2, 'and the next one the frame after')
    H.pump(H.BR.Config.Locker2.shotDelayMs - 200)
    eq(#H.created, 0, 'no clone before shotDelayMs')
    H.pump(300)
    eq(#H.created, 1, 'then the first')
    local function taken(id)
        for _, e in ipairs(H.events) do
            if e.name == 'br:ui:sendLocal' and e.args[1] == NUI.LOCKER2_SHOT and e.args[2].id == id and e.args[2].txd then
                return true
            end
        end
        return false
    end
    while not taken(PID) and H.time < asked + 5000 do H.pump(50) end
    H.ui(NUICB.LOCKER2_SHOTDONE, { id = PID, ok = true })
    local doneAt = H.time
    while #H.created < 2 and H.time < asked + 10000 do H.pump(50) end
    ok(#H.created == 2 and H.time - doneAt >= H.BR.Config.Locker2.shotGapMs,
        'the next clone shotGapMs after the last, however soon the page had its picture', H.time - doneAt)
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
    local W = editing(A.default('m'))
    local BR = W.BR
    eq(W.ped().model, MALE, 'Edit wears the male freemode ped')
    local msg = W.nui(NUI.LOCKER2)
    eq(msg.tab, 'male', 'on its tab')
    ok(msg.edit and msg.edit.sex == 'm' and msg.edit.dirty == false, 'a clean draft, nothing to save')
    eq(#listOf(msg.edit.extras), 0, 'no extras on the look')
    eq(rowOf(msg, 'c5'), nil, 'so no Bag row is drawn, nor its list built')
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'bag', on = true })
    msg = W.nui(NUI.LOCKER2)
    local bag = rowOf(msg, 'c5')
    ok(bag and bag.n == 10, 'the Bag extra lists every bag drawable, parachute packs included', bag and bag.n)
    eq(table.concat(listOf(msg.edit.extras), ','), 'bag', 'and is on the look')
    local top = rowOf(msg, 'c11')
    ok(top and top.kind == 'count' and top.v == 1 and top.n == 39, 'tops count 1/39: a gen9-only drawable skipped',
        top and (top.v .. '/' .. top.n))
    eq(top.cat, 'top', 'under Top')
    local under = rowOf(msg, 'c8')
    ok(under and under.v == 1 and under.n == 40, 'the undershirt starts on none, first in its row')
    local brow = rowOf(msg, 'o2')
    ok(brow and brow.n == 10 and brow.colors == 64 and brow.pal == 'hair', 'eyebrows: no none, the hair palette')
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
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = -1 })
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = -1 })
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 39, 'previous from 1 wraps to the last')
    eq(W.ped().comps[11][1], 38, 'which is drawable 38, 39 being gen9-only')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 1, 'and next from the last wraps to 1')
    local before = #pushes(W)
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 2 })
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 1, 'a step of 2 is refused')
    eq(#pushes(W), before, 'and pushes nothing')

    -- A swatch, never "Next color" (owner, 2026-10-14).
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 3 })
    eq(W.ped().comps[11][1], 2, 'set jumps to a position')
    top = rowOf(W.nui(NUI.LOCKER2), 'c11')
    ok(top.colors == 3 and top.c == 0 and top.pal == nil, 'drawable 2 has three colors, the first worn, no palette')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11', c = 2 })
    eq(W.ped().comps[11][2], 2, 'a swatch puts that texture on')
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').c, 2, 'and the row says which is worn')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11', c = 3 })
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11', c = -1 })
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11' })
    eq(W.ped().comps[11][2], 2, 'past its colors, below 0, or no color at all: refused')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    eq(W.ped().comps[11][2], 0, 'a new item starts on its first color')
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 1 })
    eq(W.ped().comps[11][1], 0, 'reset puts the row back to 1')
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 40 })
    eq(W.ped().comps[11][1], 0, 'a position past the end is refused')
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'mask', on = true })
    eq(W.ped().comps[1][1], 1, 'Add more\'s Mask puts its first mask on')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c1', c = 1 })
    eq(W.ped().comps[1][2], 1, 'a mask of two colors has its swatches')
    W.ui(NUICB.LOCKER2_SET, { k = 'c1', v = 1 })
    eq(W.ped().comps[1][2], 0, 'and reset puts its color back too')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o2', c = 1 })
    eq(W.ped().ovc[2][2], 1, 'eyebrow color, on the hair palette')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c2', c = 1 })
    eq(W.ped().hair[1], 1, 'the Hair row\'s swatch is the hair color')
    local hairRow = rowOf(W.nui(NUI.LOCKER2), 'c2')
    ok(hairRow.pal == 'hair' and hairRow.c == 1 and hairRow.colors == 64, 'drawn from the hair palette, the one worn')
    W.ui(NUICB.LOCKER2_STEP, { k = 'h1', d = 1 })
    eq(W.ped().hair[2], 1, 'the Highlight row is `h1`, the name the page labels')
    local hl = rowOf(W.nui(NUI.LOCKER2), 'h1')
    ok(hl.pal == 'hair' and hl.c == nil, 'its swatches are its own value')

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
    eq(W.ped().comps[5][1], 1, 'the Bag row takes a bag')
    W.ui(NUICB.LOCKER2_SET, { k = 'zz', v = 1 })

    -- The camera.
    W.ui(NUICB.LOCKER2_CAT, { cat = 'shoes' })
    eq(W.cams[#W.cams], 'focus:feet', 'Shoes moves the camera to the feet')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'bag' })
    eq(W.nui(NUI.LOCKER2).edit.cat, 'bag', 'any category is remembered')
    eq(W.cams[#W.cams], 'focus:back', 'Bag looks at the back')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'nope' })
    eq(W.cams[#W.cams], 'focus:back', 'an unknown category moves nothing')

    -- Back, out of the editor.
    W.ui(NUICB.LOCKER2_LEAVE, { seq = 2 })
    W.pump(300)
    local m3 = W.nui(NUI.LOCKER2)
    ok(m3.edit == nil and m3.tabSeq == 2, 'Leave drops the draft, and says it saw the request')
    eq(W.ped().model, hashOf(BR.PedById(STOCK1).model), 'and the worn look is put back on')
    eq(W.cams[#W.cams], 'unfocus', 'with the camera home')
end

describe('season2.save')
do
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 1 })
    W.pump(300)
    W.ui(NUICB.LOCKER2_SET, { k = 'c4', v = 2 })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'An  n' })
    eq(#W.sentTo(NET.LOCKER2_SAVE), 0, 'a bad name is refused here as well')
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update' })
    eq(#W.sentTo(NET.LOCKER2_SAVE), 0, 'update with nothing being edited')
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Night Ann' })
    local s = W.sentTo(NET.LOCKER2_SAVE)[1]
    ok(s and s.op == 'new' and s.name == 'Night Ann' and s.id == nil, 'a new look is named: words with a space')
    local sent = s and A.decode(s.a)
    ok(sent and sent.s == 'f' and sent.c[4][1] == 1, 'and carries the draft, canonical')
    eq(W.nui(NUI.LOCKER2).busy, true, 'the page is busy')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c4', d = 1 })
    eq(W.ped().comps[4][1], 1, 'and nothing changes while it is')
    local ped = { id = PID, name = 'Night Ann', a = s.a, up = 9 }
    W.net(NET.LOCKER2_RESULT, { req = s.req, ok = true, id = PID, ped = ped,
        worn = { k = 'p', id = PID, a = s.a } })
    local msg = W.nui(NUI.LOCKER2)
    ok(msg.busy == false and msg.edit.editing == PID and msg.edit.dirty == false,
        'saved: the draft is now that look, clean')
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
    W.net(NET.LOCKER2_RESULT, { req = up.req, ok = true, id = PID, ped = { id = PID, name = 'Night Ann', a = s.a, up = 9, img = img } })
    eq(W.BR.LockerV2.state().peds[1].img, img, 'and kept for the next time the page asks for that card')

    -- Update (the save dialog's Save), with the name typed there.
    W.ui(NUICB.LOCKER2_STEP, { k = 'c6', d = 1 })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update', id = PID })
    local u = W.sentTo(NET.LOCKER2_SAVE)[2]
    ok(u and u.op == 'update' and u.id == PID and u.name == nil, 'Save updates the look being edited')
    W.net(NET.LOCKER2_RESULT, { req = u.req, ok = false, reason = 'rate' })
    eq(W.notify[#W.notify], 'Something went wrong. Try again.', 'a refusal says so')
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'and the changes are still there')
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update', id = '0abcdefgh99', name = 'Ann' })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update', id = PID, name = 'Ann  Two' })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'replace', id = PID })
    eq(#W.sentTo(NET.LOCKER2_SAVE), 2, 'another look\'s id, a bad name, or an op that is not one: nothing sent')
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update', id = PID, name = 'Ann Two' })
    local u2 = W.sentTo(NET.LOCKER2_SAVE)[3]
    ok(u2 and u2.op == 'update' and u2.id == PID and u2.name == 'Ann Two', 'an update carries the name typed')
    W.net(NET.LOCKER2_RESULT, { req = u2.req, ok = true, id = PID,
        ped = { id = PID, name = 'Ann Two', a = u2.a, up = 10 }, worn = { k = 'p', id = PID, a = u2.a } })
    eq(W.nui(NUI.LOCKER2).peds[1].name, 'Ann Two', 'and the card follows')
    local saved = A.decode(u2.a)

    -- A write the server never answers gives the page back.
    W.ui(NUICB.LOCKER2_STEP, { k = 'c6', d = 1 })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Eve' })
    W.pump(10500)
    eq(W.nui(NUI.LOCKER2).busy, false, 'after 10 s with no answer the page is not busy')

    -- Close discards and puts the worn look back.
    W.ui(NUICB.LOCKER2_CLOSE)
    W.pump(300)
    local m4 = W.nui(NUI.LOCKER2)
    eq(m4.edit, nil, 'close discards the draft')
    eq(W.ped().comps[6][1], saved.c[6][1], 'and the saved look is back on')
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
    W.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    local msg = W.nui(NUI.LOCKER2)
    ok(msg.tab == 'female' and msg.edit.editing == PID and msg.tabSeq == 1, 'Edit opens it, the request echoed')
    W.ui(NUICB.LOCKER2_LEAVE, { seq = 2 })
    W.ui(NUICB.LOCKER2_RENAME, { id = PID, name = 'Eve Two' })
    local rn = W.sentTo(NET.LOCKER2_RENAME)[1]
    ok(rn and rn.name == 'Eve Two', 'Rename asks the server, a space and all')
    W.net(NET.LOCKER2_RESULT, { req = rn.req, ok = true, id = PID, ped = { id = PID, name = 'Eve Two', a = A.encode(a), up = 6 } })
    eq(W.nui(NUI.LOCKER2).peds[1].name, 'Eve Two', 'and the card follows')
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
    W2.pump(1100)
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
    W3.pump(1100)
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
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    eq(W.count('SetPlayerModel'), 1, 'nothing before the page is open')
    W.ui(NUICB.LOCKER2_OPEN)
    W.locked = true
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 2 })
    W.ui(NUICB.LOCKER2_WEAR, { k = 's', id = STOCK2 })
    W.pump(300)
    eq(W.count('SetPlayerModel'), 1, 'nothing while the entrance holds the ped')
    W.locked = false
    W.season(1)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 3 })
    W.pump(300)
    ok(W.ped().model ~= MALE, 'nothing off Season 2')
end

describe('season2.lifecycle')
do
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
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
    W.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 2 })
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
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    W.pump(300)
    eq(W.nui(NUI.LOCKER2).edit.cat, nil, 'a new draft lights no category')
    eq(W.cams[#W.cams], 'unfocus', 'with the camera home on the whole ped')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'face' })
    eq(W.cams[#W.cams], 'focus:head', 'Face moves the camera to the head')
    eq(W.nui(NUI.LOCKER2).edit.cat, 'face', 'and lights Face')
    local moves, events = #W.cams, #W.events
    W.ui(NUICB.LOCKER2_CAT, { cat = 'face' })
    eq(#W.cams, moves, 'Face again: the camera is there already')
    eq(#W.events, events + 1, 'and nothing is pushed (the one event is the press itself)')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'hair' })
    eq(#W.cams, moves, 'Hair is the same shot of the head: no move')
    eq(W.nui(NUI.LOCKER2).edit.cat, 'hair', 'but Hair is lit')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'shoes' })
    eq(W.cams[#W.cams], 'focus:feet', 'Shoes: the feet')
    W.ui(NUICB.LOCKER2_LEAVE, { seq = 2 })
    eq(W.cams[#W.cams], 'unfocus', 'Back out of the editor brings the camera home from the feet')
    W.pump(300)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 3 })
    W.pump(300)
    eq(W.nui(NUI.LOCKER2).edit.cat, nil, 'and the next new look lights no category')
    -- Edit is a new draft too.
    local P = joined({ { id = PID, name = 'Ann', a = A.encode(femaleLook()), up = 5 } })
    P.ui(NUICB.LOCKER2_OPEN)
    P.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    P.pump(300)
    P.ui(NUICB.LOCKER2_CAT, { cat = 'legs' })
    eq(P.focusedCam, 'legs', 'the camera on the legs')
    P.ui(NUICB.LOCKER2_LEAVE, { seq = 2 })
    P.pump(300)
    P.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 3 })
    P.pump(300)
    local m = P.nui(NUI.LOCKER2)
    ok(m.tab == 'female' and m.edit.cat == nil, 'Edit: no category lit')
    eq(P.focusedCam, nil, 'and the camera home')
end

describe('season2.absent')
do
    -- #28 review: a color and the opacity sliders on an overlay of none
    -- changed what nobody can see, and made the draft dirty -- the page locked
    -- with nothing on screen to say why.
    local look = A.default('m')
    look.x = { 'makeup' }
    local W = editing(look)
    local m = W.nui(NUI.LOCKER2)
    eq(table.concat(listOf(m.edit.extras), ','), 'makeup', 'a look saved with Makeup on its list, nothing chosen')
    for _, k in ipairs({ 'o1', 'o4', 'o5', 'o8', 'o10' }) do
        eq(rowOf(m, k).colors, 1, k .. ' of none: no swatches')
        eq(rowOf(m, k .. 'op').off, true, k .. ' of none: its opacity is off')
    end
    eq(rowOf(m, 'o2').colors, 64, 'the eyebrows are never none: they keep their swatches')
    eq(rowOf(m, 'o2op').off, nil, 'and their opacity')
    eq(rowOf(m, 'o4').pal, 'makeup', 'makeup on the makeup palette')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o1', c = 1 })
    W.ui(NUICB.LOCKER2_SET, { k = 'o1op', v = 40 })
    m = W.nui(NUI.LOCKER2)
    eq(m.edit.dirty, false, 'a color and an opacity on none are refused: nothing to save')
    eq(W.ped().ov[1][2], 1.0, 'and nothing reaches the ped')

    -- On, then back to none: what the player cannot see is not a change.
    W.ui(NUICB.LOCKER2_STEP, { k = 'o1', d = 1 })
    m = W.nui(NUI.LOCKER2)
    ok(rowOf(m, 'o1').colors == 64 and rowOf(m, 'o1op').off == nil, 'facial hair on: swatches and opacity')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o1', c = 1 })
    W.ui(NUICB.LOCKER2_SET, { k = 'o1op', v = 40 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'a color and an opacity on it are changes')
    W.ui(NUICB.LOCKER2_STEP, { k = 'o1', d = -1 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, false, 'stepped back to none: no change left to save')

    -- A row's reset puts its color back too, as a component's always did.
    W.ui(NUICB.LOCKER2_STEP, { k = 'o1', d = 1 })
    eq(W.ped().ovc[1][2], 1, 'on again, with the color it had')
    W.ui(NUICB.LOCKER2_SET, { k = 'o1', v = 1 })
    W.ui(NUICB.LOCKER2_STEP, { k = 'o1', d = 1 })
    eq(W.ped().ovc[1][2], 0, 'an overlay reset puts its color back')
    W.ui(NUICB.LOCKER2_SET, { k = 'o1', v = 1 })
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o2', c = 1 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'eyebrow color is a change')
    W.ui(NUICB.LOCKER2_SET, { k = 'o2', v = 1 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, false, 'and the Eyebrows reset takes it back')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c2', c = 1 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, true, 'hair color is a change')
    W.ui(NUICB.LOCKER2_SET, { k = 'c2', v = 1 })
    eq(W.nui(NUI.LOCKER2).edit.dirty, false, 'and the Hair reset takes it back')
    eq(W.ped().hair[1], 0, 'on the ped too')
end

describe('season2.tabseq')
do
    -- #28 review: the page moves its view on the press. A press Lua refused
    -- (the freemode model still streaming in) left the page in an editor Lua
    -- never opened. Every request that starts or ends a draft is numbered, and
    -- every answer says which it saw.
    local W = joined({ { id = PID, name = 'Ann', a = A.encode(femaleLook()), up = 5 } })
    W.ui(NUICB.LOCKER2_OPEN)
    eq(W.nui(NUI.LOCKER2).tabSeq, nil, 'an opening has seen no request yet')
    W.modelDelay = 300
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    W.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 2 })
    local m = W.nui(NUI.LOCKER2)
    ok(m.tab == 'male' and m.edit and m.edit.sex == 'm', 'a female look while the male ped streams in is refused')
    eq(m.tabSeq, 2, 'and the answer says which request it saw, so the page shows the male one')
    W.pump(500)
    m = W.nui(NUI.LOCKER2)
    ok(m.tab == 'male' and m.edit.sex == 'm' and m.tabSeq == 2, 'the male draft, on its tab')
    W.locked = true
    W.ui(NUICB.LOCKER2_LEAVE, { seq = 3 })
    m = W.nui(NUI.LOCKER2)
    ok(m.edit ~= nil and m.tabSeq == 3, 'every refusal says so -- Back with the ped held keeps the editor')
    W.locked = false
    W.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 4 })
    m = W.nui(NUI.LOCKER2)
    ok(m.edit.sex == 'm' and m.tabSeq == 4, 'Edit over an unsaved new look is refused, and says so')
    W.ui(NUICB.LOCKER2_LEAVE, { seq = 5 })
    W.pump(500)
    W.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 6 })
    W.pump(500)
    m = W.nui(NUI.LOCKER2)
    ok(m.edit.sex == 'f' and m.edit.editing == PID and m.tabSeq == 6, 'then it opens')
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
    -- A new look's draft likewise.
    local Y = joined()
    Y.ui(NUICB.LOCKER2_OPEN)
    Y.modelDelay = 500
    Y.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 1 })
    Y.BR.State.me.state = Y.BR.PlayerState.WARMUP
    Y.pump(1500)
    ok(Y.ped().model ~= FEMALE, 'nor is a new look\'s ped')
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
    eq(#W.sentTo(NET.LOCKER2_FETCH), 2, 'back on Season 2 it asks the server again (after the join; the open asked nothing)')

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

-- ═══ SEASON 2: TATTOOS (owner, 2026-10-11) ═══

--- The decorations a ped carries, as the overlay names of the list, sorted.
local function decoNames(p, sex)
    local by = {}
    for _, r in ipairs(TAT.list) do
        local n = r[sex == 'f' and 5 or 4]
        if n then by[hashOf(r[3]) .. ':' .. hashOf(n)] = n end
    end
    local out = {}
    for _, d in ipairs(p.decos) do out[#out + 1] = by[d[1] .. ':' .. d[2]] or '?' end
    table.sort(out)
    return table.concat(out, ',')
end

--- The Tattoos section's rows on the last push: { r, z, i }, zone by zone.
local function tatRowsIn(W)
    local m = W.nui(NUI.LOCKER2)
    return m and m.edit and m.edit.tats or {}
end

--- One zone's rows, in order.
local function zoneRowsIn(W, z)
    local out = {}
    for _, row in ipairs(tatRowsIn(W)) do
        if row.z == z then out[#out + 1] = row end
    end
    return out
end

--- A zone's tattoos as the page lists them for a sex, the list asked for
--- unless the last one sent is that sex's.
local function zoneItems(W, sex, z)
    local l = W.nui(NUI.LOCKER2_TATS)
    if not l or l.sex ~= sex then
        W.ui(NUICB.LOCKER2_TATS, { sex = sex })
        l = W.nui(NUI.LOCKER2_TATS)
    end
    for _, zone in ipairs(l.zones) do
        if zone.z == z then
            local out = {}
            for k, it in ipairs(zone.items) do out[k] = it.i end
            return out
        end
    end
    return {}
end

--- Tattoo `i` put on as the player would: "Add more", its zone, then it
--- (owner, 2026-10-14). The new row's id.
local function tatOn(W, i)
    local z = TAT.list[i][2]
    local before = #zoneRowsIn(W, z)
    W.ui(NUICB.LOCKER2_TAT_ADD, { z = z, i = i })
    local rows = zoneRowsIn(W, z)
    if #rows == before then return nil end
    return rows[#rows].i == i and rows[#rows].r or nil
end

--- The overlay names of these rows of the list for a sex, sorted, as decoNames
--- gives a ped's.
local function overlaysOf(is, sex)
    local out = {}
    for _, i in ipairs(is) do out[#out + 1] = TAT.list[i][sex == 'f' and 5 or 4] end
    table.sort(out)
    return table.concat(out, ',')
end

describe('season2.tattoos')
do
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    W.pump(300)
    -- "a list, starting empty" (owner, 2026-10-12).
    local m0 = W.nui(NUI.LOCKER2)
    ok(m0.edit and #listOf(m0.edit.tats) == 0 and #W.ped().decos == 0,
        'a new look starts with no tattoo rows, and wears none')
    local labels = W.count('GetLabelText')
    eq(labels, 0, 'no name is looked up before the page asks for the list')
    W.ui(NUICB.LOCKER2_TATS, { sex = 'm' })
    local list = W.nui(NUI.LOCKER2_TATS)
    ok(list and list.sex == 'm', 'the page asks for the male list and gets it')
    local zs, total, badItem, sorted = {}, 0, 0, true
    for _, z in ipairs(list.zones) do
        zs[#zs + 1] = z.z
        local prev = nil
        for _, it in ipairs(z.items) do
            total = total + 1
            local row = TAT.list[it.i]
            if not row or not row[4] or row[2] ~= z.z then badItem = badItem + 1 end
            if row and it.name and it.name ~= 'Label ' .. row[1] then badItem = badItem + 1 end
            local key = it.name and it.name:lower() or nil
            if prev ~= nil and key ~= nil and key < prev then sorted = false end
            if prev == false and key ~= nil then sorted = false end
            prev = key == nil and false or key
        end
    end
    eq(table.concat(zs, ','), 'head,torso,larm,rarm,lleg,rleg', 'by body zone, in order')
    eq(total, 744, 'every male tattoo, DLC sets included')
    eq(badItem, 0, 'each the male overlay\'s row, in its own zone, named with the game\'s text')
    ok(sorted, 'each zone by name, the ones with no text last')
    local aw = nil
    for _, z in ipairs(list.zones) do
        for _, it in ipairs(z.items) do if TAT.list[it.i][1] == 'TAT_AW_000' then aw = it end end
    end
    ok(aw and aw.name == nil, 'a tattoo the game has no text for is sent with no name, never its key')
    W.ui(NUICB.LOCKER2_TATS, { sex = 'f' })
    local fl, ft = W.nui(NUI.LOCKER2_TATS), 0
    for _, z in ipairs(fl.zones) do ft = ft + #z.items end
    ok(fl.sex == 'f' and ft == 746, 'the female list is her own 746', ft)
    labels = W.count('GetLabelText')
    W.ui(NUICB.LOCKER2_TATS, { sex = 'm' })
    eq(W.count('GetLabelText'), labels, 'a list is built once: asking again looks nothing up')
    local function listsSent()
        local n = 0
        for _, e in ipairs(W.events) do
            if e.name == 'br:ui:sendLocal' and e.args[1] == NUI.LOCKER2_TATS then n = n + 1 end
        end
        return n
    end
    local sent = listsSent()
    W.ui(NUICB.LOCKER2_TATS, { sex = 'x' })
    eq(listsSent(), sent, 'a sex that is not one gets nothing')

    -- "ADD MORE" (owner, 2026-10-14: "starting with a bunch of add buttons is
    -- not intuitive ... fix that"): the zone and the tattoo, picked.
    local torso = zoneItems(W, 'm', 'torso')
    local headFirst = zoneItems(W, 'm', 'head')[1]
    W.ui(NUICB.LOCKER2_TAT_ADD, { z = 'torso', i = torso[1] })
    local rows = zoneRowsIn(W, 'torso')
    ok(#rows == 1 and rows[1].i == torso[1], 'Add makes a row of the tattoo picked', rows[1] and rows[1].i)
    eq(decoNames(W.ped(), 'm'), overlaysOf({ torso[1] }, 'm'), 'on the preview at once, the male overlay')
    eq(W.ped().decos[1][1], hashOf(TAT.list[torso[1]][3]), 'from its collection')
    eq(table.concat(listOf(W.nui(NUI.LOCKER2).edit.extras), ','), 'tattoos', 'and Tattoos is on the look\'s list')
    W.ui(NUICB.LOCKER2_TAT_ADD, { z = 'torso', i = torso[2] })
    rows = zoneRowsIn(W, 'torso')
    ok(#rows == 2 and rows[2].i == torso[2], 'a second Add: at the foot of its zone')
    local a, b = rows[1].r, rows[2].r
    ok(a ~= b, 'each row its own id')
    -- What "Add more" never offers is refused here whatever the page sends.
    local clearsAdd, addsAdd = W.count('ClearPedDecorations'), W.count('AddPedDecorationFromHashes')
    local _, herOnly = onlyFor('f', 'torso')
    for _, bad in ipairs({ { z = 'torso', i = torso[1] }, { z = 'head', i = torso[3] }, { z = 'torso', i = herOnly },
                           { z = 'torso' }, { z = 'torso', i = 0 }, { z = 'torso', i = #TAT.list + 1 },
                           { z = 'torso', i = 'x' } }) do
        W.ui(NUICB.LOCKER2_TAT_ADD, bad)
    end
    ok(#zoneRowsIn(W, 'torso') == 2 and #zoneRowsIn(W, 'head') == 0,
        'a tattoo the zone has, another zone\'s, one only she has, or none: refused')
    ok(W.count('ClearPedDecorations') == clearsAdd and W.count('AddPedDecorationFromHashes') == addsAdd,
        'and the preview untouched')

    -- THE LIST (owner, 2026-10-12: "attribute editor"): a row's tattoo chosen
    -- among its zone's, on the preview at once, the row the same row.
    W.ui(NUICB.LOCKER2_TAT_SET, { r = a, i = torso[3] })
    rows = zoneRowsIn(W, 'torso')
    ok(rows[1].r == a and rows[1].i == torso[3], 'a row\'s choice: that tattoo, in that row', rows[1].i)
    ok(rows[2].r == b and rows[2].i == torso[2], 'the other row as it was')
    eq(decoNames(W.ped(), 'm'), overlaysOf({ torso[3], torso[2] }, 'm'), 'the preview follows at once')
    W.ui(NUICB.LOCKER2_TAT_SET, { r = a, i = torso[#torso] })
    eq(decoNames(W.ped(), 'm'), overlaysOf({ torso[#torso], torso[2] }, 'm'), 'the last of the list too, the old one off')
    W.ui(NUICB.LOCKER2_TAT_SET, { r = a, i = torso[1] })
    eq(zoneRowsIn(W, 'torso')[1].i, torso[1], 'and back to the first')
    -- What the list never offers is refused here whatever the page sends.
    local clearsSet = W.count('ClearPedDecorations')
    W.ui(NUICB.LOCKER2_TAT_SET, { r = a, i = torso[2] })
    eq(zoneRowsIn(W, 'torso')[1].i, torso[1], 'the tattoo another row of the zone holds: refused, never one in two rows')
    W.ui(NUICB.LOCKER2_TAT_SET, { r = a, i = torso[1] })
    local _, herTorso = onlyFor('f', 'torso')
    ok(herTorso ~= nil, 'the list has a torso tattoo only she has')
    for _, bad in ipairs({ { r = a, i = headFirst }, { r = a, i = herTorso }, { r = a, i = #TAT.list + 1 },
                           { r = a, i = 0 }, { r = a, i = 'x' }, { r = a }, { r = 99999, i = torso[4] },
                           { r = 'x', i = torso[4] }, { i = torso[4] } }) do
        W.ui(NUICB.LOCKER2_TAT_SET, bad)
    end
    rows = zoneRowsIn(W, 'torso')
    ok(rows[1].i == torso[1] and rows[2].i == torso[2] and #zoneRowsIn(W, 'head') == 0,
        'the same one again, another zone\'s, one only she has, one that is none, or a row that is none: refused')
    eq(W.count('ClearPedDecorations'), clearsSet, 'and the preview untouched by every one of them')
    -- Every tattoo of the zone the list offers can be chosen: each the male's,
    -- all but the one the other row holds.
    local each, eachOk = 0, true
    for k = 3, #torso do
        W.ui(NUICB.LOCKER2_TAT_SET, { r = a, i = torso[k] })
        local i = zoneRowsIn(W, 'torso')[1].i
        if i ~= torso[k] or not TAT.list[i][4] then eachOk = false end
        each = each + 1
    end
    ok(eachOk and each == #torso - 2, 'every male tattoo of the zone but the other row\'s can be chosen', each)
    W.ui(NUICB.LOCKER2_TAT_SET, { r = a, i = torso[1] })

    -- REMOVE: "Allow me to select each row and remove if I want to."
    local clears = W.count('ClearPedDecorations')
    W.ui(NUICB.LOCKER2_TAT_DEL, { r = a })
    rows = zoneRowsIn(W, 'torso')
    ok(#rows == 1 and rows[1].r == b and rows[1].i == torso[2], 'Remove takes that row out, the other kept')
    eq(W.count('ClearPedDecorations'), clears + 1, 'the decorations cleared')
    eq(decoNames(W.ped(), 'm'), overlaysOf({ torso[2] }, 'm'), 'and the rest put back, without its tattoo')
    W.ui(NUICB.LOCKER2_TAT_DEL, { r = a })
    W.ui(NUICB.LOCKER2_TAT_DEL, { r = 'x' })
    eq(#zoneRowsIn(W, 'torso'), 1, 'a row already gone, or not one: nothing')
    W.ui(NUICB.LOCKER2_TAT_ADD, { z = 'torso', i = torso[1] })
    rows = zoneRowsIn(W, 'torso')
    ok(#rows == 2 and rows[2].i == torso[1] and rows[2].r ~= a, 'an Add after it: the tattoo free again, a new row')

    -- "You can just make it max 10 per category."
    for k = 3, 14 do W.ui(NUICB.LOCKER2_TAT_ADD, { z = 'torso', i = torso[k] }) end
    rows = zoneRowsIn(W, 'torso')
    eq(#rows, 10, 'max 10 per zone: an 11th Add is refused')
    local seen, dup = {}, false
    for _, r in ipairs(rows) do
        if seen[r.i] then dup = true end
        seen[r.i] = true
    end
    ok(not dup, 'and no tattoo in two rows')
    eq(#W.ped().decos, 10, 'ten on the preview')
    W.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = headFirst })
    eq(#zoneRowsIn(W, 'head'), 1, 'another zone has ten of its own')
    eq(#W.ped().decos, 11, 'on the preview too')
    for _, bad in ipairs({ { z = 'nope', i = headFirst }, { z = 5, i = headFirst }, {} }) do
        W.ui(NUICB.LOCKER2_TAT_ADD, bad)
    end
    eq(#tatRowsIn(W), 11, 'Add in a zone that is not one: refused')
    local own = true
    for _, r in ipairs(tatRowsIn(W)) do
        if not TAT.list[r.i][4] or TAT.list[r.i][2] ~= r.z then own = false end
    end
    ok(own, 'every row a male tattoo of its own zone')

    -- THE SAVE'S OWN CHECK: past 10 in a zone, nothing goes to the server.
    local S = W.BR.LockerV2.state()
    local extra = nil
    for _, i in ipairs(torso) do
        if not seen[i] then
            extra = i
            break
        end
    end
    W.BR.Appearance.setTattoo(S.draft.a, TAT.list[extra][1], true)
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Over' })
    eq(#W.sentTo(NET.LOCKER2_SAVE), 0, 'a look with 11 in a zone is never sent to be saved')
    W.BR.Appearance.setTattoo(S.draft.a, TAT.list[extra][1], false)
    -- Save carries the rows' tattoos.
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Inked' })
    local s = W.sentTo(NET.LOCKER2_SAVE)[1]
    local sa = s and A.decode(s.a)
    eq(sa and #A.tattoos(sa), 11, 'Save sends every row\'s tattoo')
    W.net(NET.LOCKER2_RESULT, { req = s.req, ok = true, id = PID, ped = { id = PID, name = 'Inked', a = s.a, up = 9 },
        worn = { k = 'p', id = PID, a = s.a } })
    ok(W.nui(NUI.LOCKER2).edit.dirty == false, 'saved: clean')
    eq(#tatRowsIn(W), 11, 'the rows kept as they were')
    eq(#A.tattoos(A.decodeWorn(W.kvp['br:locker2:worn']).a), 11, 'and worn with them here')
    -- The camera follows a zone, as it follows a row.
    W.ui(NUICB.LOCKER2_CAT, { cat = 'tat_lleg' })
    eq(W.cams[#W.cams], 'focus:legs', 'a leg zone looks at the legs')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'tat_head' })
    eq(W.cams[#W.cams], 'focus:head', 'the head zone at the head')
    W.ui(NUICB.LOCKER2_CAT, { cat = 'tattoos' })
    eq(W.cams[#W.cams], 'focus:upper', 'the section itself at the upper body')
    eq(W.nui(NUI.LOCKER2).edit.cat, 'tattoos', 'and its anchor is lit')

    -- Her list and her overlays on a female look; Undo takes them off.
    local F = joined()
    F.ui(NUICB.LOCKER2_OPEN)
    F.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 1 })
    F.pump(300)
    local fhead = zoneItems(F, 'f', 'head')
    F.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = fhead[1] })
    eq(decoNames(F.ped(), 'f'), overlaysOf({ fhead[1] }, 'f'), 'a female look: her list, her overlay')
    local fr = zoneRowsIn(F, 'head')[1].r
    local _, hisHead = onlyFor('m', 'head')
    ok(hisHead ~= nil, 'the list has a head tattoo only he has')
    F.ui(NUICB.LOCKER2_TAT_SET, { r = fr, i = hisHead })
    eq(zoneRowsIn(F, 'head')[1].i, fhead[1], 'on her look, one only he has: refused')
    F.ui(NUICB.LOCKER2_TAT_SET, { r = fr, i = fhead[#fhead] })
    eq(decoNames(F.ped(), 'f'), overlaysOf({ fhead[#fhead] }, 'f'), 'one of her list chosen: her overlay')
    local before = F.nui(NUI.LOCKER2).edit.tats[1].r
    F.ui(NUICB.LOCKER2_UNDO)
    eq(decoNames(F.ped(), 'f'), overlaysOf({ fhead[1] }, 'f'), 'Undo: the choice taken back, on the preview')
    F.ui(NUICB.LOCKER2_UNDO)
    local fm = F.nui(NUI.LOCKER2)
    ok(#listOf(fm.edit.tats) == 0 and #F.ped().decos == 0, 'Undo again: the row and the tattoo off')
    F.ui(NUICB.LOCKER2_TAT_SET, { r = before, i = fhead[2] })
    F.ui(NUICB.LOCKER2_TAT_DEL, { r = before })
    ok(#listOf(F.nui(NUI.LOCKER2).edit.tats) == 0 and #F.ped().decos == 0, 'and a row undone is no row at all')
    -- Refused while the ped is held, as every change is.
    F.locked = true
    F.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = fhead[1] })
    ok(#listOf(F.nui(NUI.LOCKER2).edit.tats) == 0 and #F.ped().decos == 0, 'nothing while the entrance holds the ped')
end

describe('season2.tattoo_paths')
do
    -- EVERY PLACE A SAVED CUSTOM PED IS PUT ON, its tattoos go on with it.
    local inked = femaleLook()
    A.setTattoo(inked, 'TAT_X7_031', true)
    A.setTattoo(inked, 'TAT_H4_000', true)
    -- A set the list does not know and a male-only tattoo: skipped, no error.
    A.setTattoo(inked, 'TAT_ZZ_001', true)
    A.setTattoo(inked, onlyFor('m')[1], true)
    local enc = A.encode(inked)
    local want = table.concat((function()
        local t = { tatRow('TAT_X7_031')[5], tatRow('TAT_H4_000')[5] }
        table.sort(t)
        return t
    end)(), ',')

    -- 1. The join: the server's worn ped, first applied.
    local W = clientWorld({ season = 2, v2 = true })
    W.pump(200)
    W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = enc }, store = true, peds = {} })
    W.pump(600)
    eq(decoNames(W.ped(), 'f'), want, 'the join puts the saved tattoos on, an unknown set and a male-only one skipped')
    -- 2. A new ped in every state there is one (warmup, the plane, the drop,
    -- the match, downed): the respawns and the warmup trip.
    for _, st in ipairs({ 'WARMUP', 'BUS', 'FREEFALL', 'GLIDE', 'ALIVE', 'DBNO' }) do
        W.BR.State.me.state = W.BR.PlayerState[st]
        W.handle = W.handle + 1
        W.peds[W.handle] = newPed(FEMALE)
        W.pump(600)
        eq(decoNames(W.ped(), 'f'), want, 'in ' .. st .. ' a new ped gets the tattoos back')
    end
    -- 3. The same ped losing them (a resurrection that kept its handle).
    W.ped().decos = {}
    W.pump(600)
    eq(decoNames(W.ped(), 'f'), want, 'the same ped with its tattoos gone gets them back')
    local clears = W.count('ClearPedDecorations')
    W.pump(10000)
    eq(W.count('ClearPedDecorations'), clears, 'and nothing is put on again while they are all there')
    -- 4. An engine that draws fewer than asked is not asked again every pass.
    local C2 = clientWorld({ season = 2, v2 = true })
    C2.decoCap = 1
    C2.pump(200)
    C2.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = enc }, store = true, peds = {} })
    C2.pump(600)
    C2.BR.State.me.state = C2.BR.PlayerState.ALIVE
    local c0 = C2.count('ClearPedDecorations')
    C2.pump(5000)
    eq(C2.count('ClearPedDecorations'), c0, 'a ped that carries fewer than it was given is not cleared every pass')

    -- 5. Wearing a saved ped from the page, over one of the same model.
    local plain = femaleLook()
    local P = joined({ { id = PID, name = 'Ann', a = enc, up = 5 },
                       { id = '0abcdefgh13', name = 'Old', a = A.encode(plain), up = 6 } })
    P.ui(NUICB.LOCKER2_OPEN)
    P.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    P.pump(300)
    eq(decoNames(P.ped(), 'f'), want, 'a saved ped worn from the page wears its tattoos')
    -- 6. An old save, with no `t`, over it: none, the last look's taken off.
    P.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = '0abcdefgh13' })
    P.pump(300)
    ok(P.ped().model == FEMALE and #P.ped().decos == 0, 'an old save wears none, and takes the last one\'s off')
    -- 7. Edit opens it with its tattoos as rows, each in its own zone, the
    -- skipped ones not.
    P.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    P.pump(300)
    local tats = P.nui(NUI.LOCKER2).edit.tats
    local _, iX7 = tatRow('TAT_X7_031')
    local _, iH4 = tatRow('TAT_H4_000')
    local got, zoned = {}, true
    for _, row in ipairs(tats) do
        got[#got + 1] = row.i
        if TAT.list[row.i][2] ~= row.z or not row.r then zoned = false end
    end
    table.sort(got)
    eq(table.concat(got, ','), table.concat({ math.min(iX7, iH4), math.max(iX7, iH4) }, ','),
        'Edit shows its two tattoos as rows, the skipped ones not')
    ok(zoned, 'each in its own zone, with its id')
    ok(P.nui(NUI.LOCKER2).edit.dirty == false, 'nothing to save')
    eq(decoNames(P.ped(), 'f'), want, 'and the preview wears them')
    -- 8. A stock ped, picked straight after the tattooed one: none.
    P.ui(NUICB.LOCKER2_LEAVE, { seq = 2 })
    P.pump(300)
    P.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    P.pump(300)
    eq(decoNames(P.ped(), 'f'), want, 'the tattooed ped worn again')
    P.ui(NUICB.LOCKER2_WEAR, { k = 's', id = STOCK2 })
    P.pump(600)
    local adds = P.count('AddPedDecorationFromHashes')
    ok(P.ped().model == hashOf(P.BR.PedById(STOCK2).model) and #P.ped().decos == 0, 'a stock ped wears no tattoo')
    P.BR.State.me.state = P.BR.PlayerState.ALIVE
    P.pump(5000)
    eq(P.count('AddPedDecorationFromHashes'), adds, 'and none is put on it later')
    -- 9. The headshot clone wears them.
    local H = joined({ { id = PID, name = 'Ann', a = enc, up = 5 } })
    H.ui(NUICB.LOCKER2_OPEN)
    H.ui(NUICB.LOCKER2_SHOTS, { ids = { PID } })
    H.pump(1100)
    eq(decoNames(H.peds[H.created[1].handle], 'f'), want, 'a card\'s headshot clone wears the tattoos')
    -- 10. A build without a set skips it, in the list and on the ped.
    local B = clientWorld({ season = 2, v2 = true })
    B.build = 3000
    B.pump(200)
    B.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = enc }, store = true, peds = {} })
    B.pump(600)
    eq(decoNames(B.ped(), 'f'), tatRow('TAT_H4_000')[5], 'a build without The Chop Shop skips its tattoo')
    B.ui(NUICB.LOCKER2_OPEN)
    B.ui(NUICB.LOCKER2_TATS, { sex = 'f' })
    local x7 = 0
    for _, z in ipairs(B.nui(NUI.LOCKER2_TATS).zones) do
        for _, it in ipairs(z.items) do if TAT.list[it.i][3] == 'mp2023_02_overlays' then x7 = x7 + 1 end end
    end
    eq(x7, 0, 'and does not list it')
end

describe('season2.tattoo_bookkeeping')
do
    -- EVERY WRITE THE TATTOOS ADD TO A PATH THAT PUTS A LOOK ON (#28 review):
    -- what the ped carries, noted after a swap, a dress, a tick on or off and
    -- a restore; a tick noted as the look applied; and no tick on a ped that
    -- is not the draft's model. Each test below fails with its write taken out.
    local inked = femaleLook()
    A.setTattoo(inked, 'TAT_X7_031', true)
    A.setTattoo(inked, 'TAT_H4_000', true)
    local enc, plainEnc = A.encode(inked), A.encode(femaleLook())
    local want = table.concat((function()
        local t = { tatRow('TAT_X7_031')[5], tatRow('TAT_H4_000')[5] }
        table.sort(t)
        return t
    end)(), ',')
    local rX7, iX7 = tatRow('TAT_X7_031')
    local _, iH4 = tatRow('TAT_H4_000')
    local function stepUntil(W, cond, ms)
        local stop = W.time + ms
        while not cond() and W.time < stop do W.pump(50) end
        return cond()
    end
    local function wornInked(setup)
        local W = clientWorld({ season = 2, v2 = true })
        if setup then setup(W) end
        W.pump(200)
        W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = enc }, store = true, peds = {} })
        return W
    end

    -- 1. A SWAP notes what the ped carries: the same ped losing its tattoos
    -- straight after one gets them back.
    local W = wornInked()
    W.pump(600)
    local h = W.handle
    W.ped().decos = {}
    W.pump(600)
    ok(W.handle == h and decoNames(W.ped(), 'f') == want, 'after a swap, the same ped losing its tattoos gets them back',
        decoNames(W.ped(), 'f'))

    -- 2. A RESTORE notes what it put back: one given fewer back (the engine's
    -- room taken) is not tried again every pass.
    local R = wornInked()
    R.pump(600)
    R.decoCap = 1
    R.ped().decos = {}
    R.pump(600)
    eq(#R.ped().decos, 1, 'a restore with room for one puts one back')
    local clears = R.count('ClearPedDecorations')
    R.pump(5000)
    eq(R.count('ClearPedDecorations'), clears, 'and is not tried again every pass')

    -- 3. THE HEAD BLEND ASSERTED AGAIN once it settles puts back what it took,
    -- then and there, not at the watcher's next pass.
    local B = wornInked(function(w) w.blendTakesTattoos = true end)
    ok(stepUntil(B, function() return B.count('SetPedHeadBlendData') == 2 end, 2000), 'the blend is asserted again')
    eq(decoNames(B.ped(), 'f'), want, 'a blend asserted again that takes the tattoos puts them straight back')

    -- 4. A DRESS IN PLACE notes what the ped carries.
    local D = joined({ { id = PID, name = 'Ann', a = enc, up = 5 },
                       { id = '0abcdefgh13', name = 'Old', a = plainEnc, up = 6 } })
    D.ui(NUICB.LOCKER2_OPEN)
    D.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = '0abcdefgh13' })
    D.pump(300)
    local dh = D.handle
    D.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    D.pump(300)
    D.ped().decos = {}
    D.pump(600)
    ok(D.handle == dh and decoNames(D.ped(), 'f') == want,
        'after a dress in place, the same ped losing its tattoos gets them back', decoNames(D.ped(), 'f'))

    -- 5. AN ADD notes what the ped carries, and the draft as the look on.
    local T = joined()
    T.ui(NUICB.LOCKER2_OPEN)
    T.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 1 })
    T.pump(300)
    local head1 = zoneItems(T, 'f', 'head')[1]
    local torso = zoneItems(T, 'f', 'torso')
    T.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = head1 })
    T.ped().decos = {}
    T.pump(600)
    eq(decoNames(T.ped(), 'f'), overlaysOf({ head1 }, 'f'), 'after an Add, the same ped losing the tattoo gets it back')
    -- 6. A CHOICE notes it too, and a REMOVE: one taken off is not mistaken for
    -- one lost.
    T.ui(NUICB.LOCKER2_TAT_ADD, { z = 'torso', i = torso[1] })
    T.ui(NUICB.LOCKER2_TAT_SET, { r = zoneRowsIn(T, 'torso')[1].r, i = torso[2] })
    T.ped().decos = {}
    T.pump(600)
    eq(decoNames(T.ped(), 'f'), overlaysOf({ head1, torso[2] }, 'f'),
        'after a choice, the same ped losing its tattoos gets the chosen one back')
    T.ui(NUICB.LOCKER2_TAT_ADD, { z = 'larm', i = zoneItems(T, 'f', 'larm')[1] })
    T.ui(NUICB.LOCKER2_TAT_DEL, { r = zoneRowsIn(T, 'larm')[1].r })
    local tc = T.count('ClearPedDecorations')
    T.pump(3000)
    eq(T.count('ClearPedDecorations'), tc, 'a tattoo removed is not put back on, nor the rest again')
    eq(decoNames(T.ped(), 'f'), overlaysOf({ head1, torso[2] }, 'f'), 'and the others stay on')

    -- 7. DONE, OR BACK'S DISCARD, after an Add: the worn ped goes back on
    -- without the draft's tattoo.
    local E = joined({ { id = PID, name = 'Ann', a = plainEnc, up = 5 } })
    E.ui(NUICB.LOCKER2_OPEN)
    E.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    E.pump(300)
    E.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    E.pump(300)
    E.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = head1 })
    eq(#E.ped().decos, 1, 'the Add is on the preview')
    E.ui(NUICB.LOCKER2_CLOSE)
    E.pump(600)
    eq(#E.ped().decos, 0, 'closing the page takes the draft\'s tattoo off the worn ped')
    E.ui(NUICB.LOCKER2_OPEN)
    E.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 2 })
    E.pump(300)
    eq(#listOf(E.nui(NUI.LOCKER2).edit.tats), 0, 'and editing it again opens it with none')

    -- 8. A MATCH STARTED MID-EDIT plays in the draft, its tattoo included,
    -- through a respawn.
    local M = joined({ { id = PID, name = 'Ann', a = plainEnc, up = 5 } })
    M.ui(NUICB.LOCKER2_OPEN)
    M.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    M.pump(300)
    M.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    M.pump(300)
    M.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = head1 })
    M.BR.State.me.state = M.BR.PlayerState.ALIVE
    M.pump(300)
    M.handle = M.handle + 1
    M.peds[M.handle] = newPed(FEMALE)
    M.pump(600)
    eq(decoNames(M.ped(), 'f'), overlaysOf({ head1 }, 'f'),
        'a match started mid-edit keeps the draft\'s tattoo through a respawn')

    -- 9. A NEW LOOK WHOSE MODEL NEVER STREAMED leaves no draft over the stock
    -- ped (#28 review: it stood empty), so an Add after it puts nothing on it.
    local G = joined()
    G.neverLoad = true
    G.ui(NUICB.LOCKER2_OPEN)
    G.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    G.pump(5600)
    ok(G.ped().model == hashOf(G.BR.PedById(STOCK1).model) and G.nui(NUI.LOCKER2).edit == nil,
        'a new look whose model never streamed: the stock ped still on, and no draft')
    local adds, blends = G.count('AddPedDecorationFromHashes'), G.count('SetPedHeadBlendData')
    G.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = zoneItems(G, 'm', 'head')[1] })
    G.pump(2000)
    ok(G.count('AddPedDecorationFromHashes') == adds and #G.ped().decos == 0,
        'an Add after it puts no tattoo on the stock ped')
    eq(G.count('SetPedHeadBlendData'), blends, 'nor, later, the custom look')

    -- 10. ONE SEX'S OVERLAY LOOKED UP IS NOT THE OTHER'S: the same tattoo on
    -- a male look, then a female one.
    local X = joined()
    X.ui(NUICB.LOCKER2_OPEN)
    X.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    X.pump(300)
    ok(tatOn(X, iX7) ~= nil, 'the list reaches a tattoo deep in its zone')
    eq(decoNames(X.ped(), 'm'), rX7[4], 'a male look: his overlay')
    X.ui(NUICB.LOCKER2_LEAVE, { seq = 2 })
    X.pump(300)
    X.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 3 })
    X.pump(300)
    tatOn(X, iX7)
    eq(decoNames(X.ped(), 'f'), rX7[5], 'then a female one: hers, not the one looked up for him')

    -- 11. brlocker2 SAYS HOW MANY THE LOOK HAS AND HOW MANY THE ENGINE HOLDS:
    -- the playtest's count for an engine that draws fewer than were added.
    local K = joined()
    K.decoCap = 1
    K.ui(NUICB.LOCKER2_OPEN)
    K.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 1 })
    K.pump(300)
    K.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = zoneItems(K, 'f', 'head')[1] })
    K.ui(NUICB.LOCKER2_TAT_ADD, { z = 'torso', i = zoneItems(K, 'f', 'torso')[1] })
    local printed = {}
    K.env.print = function(s) printed[#printed + 1] = s end
    K.commands.brlocker2(0, {})
    K.env.print = function() end
    local line = nil
    for _, s in ipairs(printed) do if s:find('tattoos', 1, true) then line = s end end
    eq(line, '  tattoos  2  decorations 1', 'brlocker2: two in the look, one on the ped as the engine says')
end

describe('season2.tattoo_cap')
do
    -- MAX 10 PER ZONE ON LOAD (owner, 2026-10-12): a ped saved the day there
    -- was no cap -- 12 on her torso and one on her head -- wears and opens
    -- with the first 10 of the torso in the list's order, and saves no more.
    local torsoF = {}
    for i, r in ipairs(TAT.list) do
        if r[2] == 'torso' and r[5] then torsoF[#torsoF + 1] = i end
    end
    local headF, headF2 = nil, nil
    for i, r in ipairs(TAT.list) do
        if r[2] == 'head' and r[5] then
            if not headF then headF = i elseif not headF2 then headF2 = i end
        end
    end
    local over = femaleLook()
    for k = 1, 12 do A.setTattoo(over, TAT.list[torsoF[k]][1], true) end
    A.setTattoo(over, TAT.list[headF][1], true)
    local enc = A.encode(over)
    local first10 = {}
    for k = 1, 10 do first10[k] = torsoF[k] end
    local worn = { table.unpack(first10) }
    worn[#worn + 1] = headF

    -- 1. Worn at the join.
    local W = clientWorld({ season = 2, v2 = true })
    W.pump(200)
    W.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = enc }, store = true, peds = {} })
    W.pump(600)
    eq(decoNames(W.ped(), 'f'), overlaysOf(worn, 'f'), 'the join wears the torso\'s first 10 in the list\'s order, and the head\'s one')
    W.BR.State.me.state = W.BR.PlayerState.ALIVE
    W.handle = W.handle + 1
    W.peds[W.handle] = newPed(FEMALE)
    W.pump(600)
    eq(#W.ped().decos, 11, 'and so does a new ped in the match')

    -- 2. Edit: the 10 as rows, in the list's order, and nothing to save.
    local P = joined({ { id = PID, name = 'Ann', a = enc, up = 5 } })
    P.ui(NUICB.LOCKER2_OPEN)
    P.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    P.pump(300)
    local rows = zoneRowsIn(P, 'torso')
    local got = {}
    for k, r in ipairs(rows) do got[k] = r.i end
    eq(table.concat(got, ','), table.concat(first10, ','), 'Edit opens the torso\'s first 10 as rows, in the list\'s order')
    eq(#zoneRowsIn(P, 'head'), 1, 'and the head\'s one')
    ok(P.nui(NUI.LOCKER2).edit.dirty == false, 'with nothing to save')
    eq(#P.ped().decos, 11, 'the preview wears the 11')
    -- The order a saved ped's rows open in is the list's (br_lib/config/
    -- tattoos.lua), not their label keys': two on her torso whose keys sort
    -- the other way round.
    local early, late = nil, nil
    for x = 1, #torsoF do
        for y = x + 1, #torsoF do
            if TAT.list[torsoF[x]][1] > TAT.list[torsoF[y]][1] then
                early, late = torsoF[x], torsoF[y]
                break
            end
        end
        if early then break end
    end
    ok(early ~= nil, 'her torso has two tattoos whose keys sort against the list')
    local two = femaleLook()
    A.setTattoo(two, TAT.list[early][1], true)
    A.setTattoo(two, TAT.list[late][1], true)
    local O = joined({ { id = PID, name = 'Ann', a = A.encode(two), up = 5 } })
    O.ui(NUICB.LOCKER2_OPEN)
    O.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    O.pump(300)
    local opened = {}
    for k, r in ipairs(zoneRowsIn(O, 'torso')) do opened[k] = r.i end
    eq(table.concat(opened, ','), early .. ',' .. late, 'Edit opens a zone\'s rows in the list\'s order, whatever their keys')

    -- 3. ON CHANGE: an 11th refused there too.
    P.ui(NUICB.LOCKER2_TAT_ADD, { z = 'torso', i = torsoF[11] })
    eq(#zoneRowsIn(P, 'torso'), 10, 'an 11th torso row refused')
    ok(P.nui(NUI.LOCKER2).edit.dirty == false, 'and nothing changed')

    -- 4. A change, then Save: the 10, and the change.
    P.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = headF2 })
    P.ui(NUICB.LOCKER2_SAVE, { op = 'update' })
    local s = P.sentTo(NET.LOCKER2_SAVE)[1]
    local sa = s and A.decode(s.a)
    local n = 0
    for _, key in ipairs(sa and A.tattoos(sa) or {}) do
        local _, i = tatRow(key)
        if TAT.list[i][2] == 'torso' then n = n + 1 end
    end
    eq(n, 10, 'Save sends the torso\'s 10, never the two it never wore')
    eq(sa and #A.tattoos(sa), 12, 'and the head\'s two')

    -- 5. UNDO, after the change: the rows it opened with, as they were.
    local P2 = joined({ { id = PID, name = 'Ann', a = enc, up = 5 } })
    P2.ui(NUICB.LOCKER2_OPEN)
    P2.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    P2.pump(300)
    local ids = {}
    for _, r in ipairs(tatRowsIn(P2)) do ids[r.r] = true end
    P2.ui(NUICB.LOCKER2_TAT_DEL, { r = zoneRowsIn(P2, 'torso')[1].r })
    local larm = nil
    for i, r in ipairs(TAT.list) do
        if r[2] == 'larm' and r[5] and not larm then larm = i end
    end
    P2.ui(NUICB.LOCKER2_TAT_ADD, { z = 'larm', i = larm })
    ok(P2.nui(NUI.LOCKER2).edit.dirty == true, 'a row removed and one added: dirty')
    P2.ui(NUICB.LOCKER2_UNDO)
    P2.ui(NUICB.LOCKER2_UNDO)
    local back, same = {}, true
    for k, r in ipairs(zoneRowsIn(P2, 'torso')) do
        back[k] = r.i
        if not ids[r.r] then same = false end
    end
    eq(table.concat(back, ','), table.concat(first10, ','), 'two Undos put back the rows it opened with')
    ok(same and #zoneRowsIn(P2, 'larm') == 0, 'the same rows, the added one gone')
    ok(P2.nui(NUI.LOCKER2).edit.dirty == false and #P2.ped().decos == 11, 'clean, and the preview with it')

    -- 6. One only he wears, kept in her look beside her torso's 10, is not
    -- counted: her Save still goes.
    local _, mOnly = onlyFor('m', 'torso')
    local his = femaleLook()
    for _, i in ipairs(first10) do A.setTattoo(his, TAT.list[i][1], true) end
    A.setTattoo(his, TAT.list[mOnly][1], true)
    local H = joined({ { id = PID, name = 'Ann', a = A.encode(his), up = 5 } })
    H.ui(NUICB.LOCKER2_OPEN)
    H.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    H.pump(300)
    eq(#zoneRowsIn(H, 'torso'), 10, 'her 10 as rows, his not')
    H.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = headF })
    H.ui(NUICB.LOCKER2_SAVE, { op = 'update' })
    local hs = H.sentTo(NET.LOCKER2_SAVE)[1]
    ok(hs ~= nil and A.hasTattoo(A.decode(hs.a), TAT.list[mOnly][1]),
        'her Save goes, his kept in the look and not counted against her 10')
end

describe('season2.tattoo_season1')
do
    -- Season 1 is untouched: no tattoo native in a whole session.
    local W = clientWorld({ season = 1, v2 = true })
    W.pump(600)
    W.fire('br:ui:ready')
    W.ui(NUICB.LOCKER_PICK, { id = STOCK2 })
    W.pump(600)
    W.BR.State.me.state = W.BR.PlayerState.ALIVE
    W.pump(5000)
    eq(W.count('AddPedDecorationFromHashes') + W.count('ClearPedDecorations') + W.count('GetPedDecorations')
        + W.count('GetLabelText') + W.count('GetGameBuildNumber'), 0, 'Season 1 calls no tattoo native at all')
    -- A live switch back to Season 1 leaves Season 1's ped bare.
    local inked = femaleLook()
    A.setTattoo(inked, 'TAT_X7_031', true)
    local F = clientWorld({ season = 2, v2 = true })
    F.pump(200)
    F.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = A.encode(inked) }, store = true, peds = {} })
    F.pump(600)
    eq(#F.ped().decos, 1, 'on Season 2 the saved ped wears its tattoo')
    F.season(1)
    F.pump(600)
    ok(F.ped().model ~= FEMALE and #F.ped().decos == 0, 'back on Season 1 its ped wears none')
    local adds = F.count('AddPedDecorationFromHashes')
    F.BR.State.me.state = F.BR.PlayerState.ALIVE
    F.pump(5000)
    eq(F.count('AddPedDecorationFromHashes'), adds, 'and none is put on it later')
end

-- ═══ SEASON 2: MY LOOKS (owner, 2026-10-12/13/14) ═══

--- The draft Lua holds, for the suites.
local function draftOf(W) return W.BR.LockerV2.state().draft end

describe('mylooks.new')
do
    -- "New" -> Custom -> Create (owner, 2026-10-14): a new custom look, the
    -- core randomized ("a randomize button for the whole ped"), no extras.
    math.randomseed(11)
    local W = joined()
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    W.pump(300)
    local m = W.nui(NUI.LOCKER2)
    ok(m.tabSeq == 1 and m.tab == 'male' and m.edit and m.edit.sex == 'm', 'a male look, the page\'s request echoed')
    eq(W.ped().model, MALE, 'on the male freemode ped')
    ok(m.edit.editing == nil and m.edit.dirty == true, 'never saved, so never clean: Back asks first, Save names it')
    eq(#listOf(m.edit.extras), 0, 'no extras')
    ok(m.edit.undo == false and m.edit.redo == false, 'and nothing to undo')
    local a = draftOf(W).a
    ok(not A.equal(a, A.default('m')), 'the core randomized, not the defaults')
    ok(a.c[2][1] ~= 0, 'with hair: never the list\'s first')
    local spread = true
    for i = 1, A.FEATURES do
        if math.abs(a.ff[i]) > 35 or ((i == 19 or i == 20) and a.ff[i] < 0) then spread = false end
    end
    ok(spread, 'the face\'s features near the middle')
    ok(a.e <= 7 and a.h[1] <= 28 and a.h[2] <= 28, 'natural eyes and hair colors')
    eq(a.o[3][3], a.h[1], 'the eyebrows in the hair\'s color')
    ok(W.ped().comps[11][1] == a.c[11][1] and W.ped().hair[1] == a.h[1], 'and on the preview')
    -- Each New is its own look.
    local looks = { [A.encode(a)] = true }
    for n = 2, 4 do
        W.ui(NUICB.LOCKER2_LEAVE, { seq = n * 2 })
        W.pump(300)
        W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = n * 2 + 1 })
        W.pump(300)
        looks[A.encode(draftOf(W).a)] = true
    end
    local distinct = 0
    for _ in pairs(looks) do distinct = distinct + 1 end
    eq(distinct, 4, 'four News, four looks')
    -- A female one: no beard on her.
    W.ui(NUICB.LOCKER2_LEAVE, { seq = 20 })
    W.pump(300)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 21 })
    W.pump(300)
    ok(W.ped().model == FEMALE and draftOf(W).a.o[2][1] == A.NONE, 'a female look, with no facial hair')
    -- A second New while one is unsaved: refused (the page asked first).
    W.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 22 })
    m = W.nui(NUI.LOCKER2)
    ok(m.edit.sex == 'f' and m.tabSeq == 22, 'another New over an unsaved look is refused, and says so')
    W.ui(NUICB.LOCKER2_LEAVE, { seq = 23 })
    W.pump(300)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'x', seq = 24 })
    m = W.nui(NUI.LOCKER2)
    ok(m.edit == nil and m.tabSeq == 24, 'a sex that is not one: nothing, and it says so')
end

describe('mylooks.faces')
do
    -- THE STARTING FACES (2026-10-13: "a few starting faces"): the Face
    -- panel's tiles, the look's `f`.
    local W = editing(A.default('m'))
    local row = rowOf(W.nui(NUI.LOCKER2), 'shape')
    ok(row and row.cat == 'face' and row.v == 1 and row.n == 6, 'six starting faces, the first worn')
    eq(W.ped().blend[1], 0, 'the first is the one face every look had before')
    W.ui(NUICB.LOCKER2_SET, { k = 'shape', v = 3 })
    eq(draftOf(W).a.f, 2, 'a tile sets the look\'s face')
    eq(W.ped().blend[1], W.BR.Config.Locker2.faces.m[3], 'and the head blend wears it at once')
    W.ui(NUICB.LOCKER2_SET, { k = 'shape', v = 7 })
    eq(draftOf(W).a.f, 2, 'a seventh face is refused')
    local f = A.default('f')
    f.f = 4
    local F = editing(f)
    eq(F.ped().blend[1], F.BR.Config.Locker2.faces.f[5], 'a saved look is worn with its face')
    eq(rowOf(F.nui(NUI.LOCKER2), 'shape').v, 5, 'and its tile lit')
end

describe('mylooks.history')
do
    -- UNDO AND REDO (owner, 2026-10-13: "yes"), held here, by the page's rules.
    local W = editing(A.default('m'))
    local function edit() return W.nui(NUI.LOCKER2).edit end
    local quiet = #pushes(W)
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 1 })
    W.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 0 })
    ok(edit().undo == false and #pushes(W) == quiet, 'a press that changes nothing is no step, and no push')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    ok(edit().undo == true and edit().redo == false, 'a change can be undone')
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 3, 'two steps of one row inside 800 ms')
    W.ui(NUICB.LOCKER2_UNDO)
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 1, 'are one Undo (a held arrow)')
    eq(W.ped().comps[11][1], 0, 'on the preview too')
    ok(edit().undo == false and edit().redo == true and edit().dirty == false, 'back where it began: clean, Redo lit')
    W.ui(NUICB.LOCKER2_REDO)
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 3, 'Redo puts it back')
    ok(edit().redo == false and edit().dirty == true, 'and nothing left to redo')
    W.pump(900)
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    W.pump(900)
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    W.ui(NUICB.LOCKER2_UNDO)
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').v, 4, 'touches further apart are steps of their own')
    W.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 20 })
    eq(edit().redo, false, 'a new change clears Redo')
    W.ui(NUICB.LOCKER2_SET, { k = 'ff1', v = 30 })
    W.ui(NUICB.LOCKER2_UNDO)
    ok(W.ped().ff[1] == 0.0 and W.ped().ff[0] == 0.2, 'another row inside 800 ms is another step')
    W.pump(900)
    for v = 10, 90, 10 do W.ui(NUICB.LOCKER2_SET, { k = 'ff2', v = v }) end
    W.ui(NUICB.LOCKER2_UNDO)
    eq(W.ped().ff[2], 0.0, 'a slider\'s drag is one step')
    local before = #pushes(W)
    W.ui(NUICB.LOCKER2_REDO)
    W.ui(NUICB.LOCKER2_REDO)
    eq(#pushes(W), before + 1, 'a Redo with nothing to redo pushes nothing')
    -- At most 50 steps.
    local H = editing(A.default('m'))
    for n = 1, 55 do H.ui(NUICB.LOCKER2_SET, { k = 'ff' .. (n % 2), v = n }) end
    local undone = 0
    while H.nui(NUI.LOCKER2).edit.undo and undone < 60 do
        H.ui(NUICB.LOCKER2_UNDO)
        undone = undone + 1
    end
    eq(undone, 50, 'fifty steps are kept')
    eq(H.ped().ff[0], 4 / 100, 'the oldest ones gone: back to the fifth change, not the first')
end

describe('mylooks.extras')
do
    -- "Add more" (owner, 2026-10-14), in the order put on: "adding earrings
    -- after adding tattoos should not show tattoos on the bottom of the list".
    local W = editing(A.default('m'))
    local function extras() return table.concat(listOf(W.nui(NUI.LOCKER2).edit.extras), ',') end
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'tattoos', on = true })
    eq(extras(), 'tattoos', 'Tattoos on, with no tattoo yet')
    eq(#W.ped().decos, 0, 'and none on the preview')
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'earrings', on = true })
    eq(extras(), 'tattoos,earrings', 'Earrings after it: at the end, not before Tattoos')
    local ear = rowOf(W.nui(NUI.LOCKER2), 'p2')
    ok(ear and ear.v == 2 and ear.cat == 'earrings', 'wearing its first item', ear and ear.v)
    ok(W.ped().props[2] and W.ped().props[2][1] == 0, 'on the preview')
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'hat', on = true })
    eq(extras(), 'tattoos,earrings,hat', 'and a Hat after that')
    local before = #pushes(W)
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'hat', on = true })
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'cape', on = true })
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'vest', on = false })
    eq(#pushes(W), before, 'one already on, one that is not an extra, or one off already: nothing')
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'earrings', on = false })
    eq(extras(), 'tattoos,hat', 'its trash icon takes Earrings off')
    eq(rowOf(W.nui(NUI.LOCKER2), 'p2'), nil, 'its row gone')
    eq(W.ped().props[2], nil, 'and the earrings off the preview')
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'makeup', on = true })
    eq(extras(), 'tattoos,hat,makeup', 'Makeup on')
    eq(rowOf(W.nui(NUI.LOCKER2), 'o4').v, 1, 'with nothing chosen yet')
    W.ui(NUICB.LOCKER2_UNDO)
    eq(extras(), 'tattoos,hat', 'an extra put on is one Undo')
    W.ui(NUICB.LOCKER2_REDO)
    -- Saved in that order, and opened in it.
    W.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Order' })
    local s = W.sentTo(NET.LOCKER2_SAVE)[1]
    local sa = s and A.decode(s.a)
    eq(sa and table.concat(sa.x, ','), 'tattoos,hat,makeup', 'Save keeps the order')
    local R = editing(sa)
    eq(table.concat(listOf(R.nui(NUI.LOCKER2).edit.extras), ','), 'tattoos,hat,makeup', 'and Edit opens it so')
    eq(R.nui(NUI.LOCKER2).edit.dirty, false, 'with nothing to save')
    -- A look saved before My Looks lists what is on it, in the extras' order.
    local old = A.default('m')
    old.p[1] = { 3, 0 }
    old.c[1] = { 2, 0 }
    local O = editing(old)
    eq(table.concat(listOf(O.nui(NUI.LOCKER2).edit.extras), ','), 'hat,mask', 'an older save lists its hat and mask')
    eq(O.nui(NUI.LOCKER2).edit.dirty, false, 'and is not changed by it')
    -- A tattoo added lists Tattoos at the end, if it was not on.
    O.ui(NUICB.LOCKER2_TAT_ADD, { z = 'head', i = zoneItems(O, 'm', 'head')[1] })
    eq(table.concat(listOf(O.nui(NUI.LOCKER2).edit.extras), ','), 'hat,mask,tattoos', 'a tattoo puts Tattoos on the list')
    O.ui(NUICB.LOCKER2_EXTRA, { id = 'tattoos', on = false })
    ok(#listOf(O.nui(NUI.LOCKER2).edit.tats) == 0 and #O.ped().decos == 0, 'and its trash icon takes them all off')
end

describe('mylooks.random')
do
    -- RANDOMIZE (owner, 2026-10-14: "the randomize button should randomize
    -- those additional categories too, and add them to the list when it sets
    -- them"), one step of Undo.
    math.randomseed(5)
    local start = A.default('m')
    start.x = { 'earrings', 'hat' }
    start.p[3] = { 1, 0 }
    start.p[1] = { 2, 0 }
    local W = editing(start)
    local rows = W.BR.Config.Locker2.extras
    local sawAdd, sawKeep, sawDrop = false, false, false
    local orderOk, listedOk, undoOk, tatsOk, wornOk = true, true, true, true, true
    for n = 1, 25 do
        local d = draftOf(W)
        local before, bx = A.encode(d.a), table.concat(d.a.x or {}, ',')
        local prev = d.a.x or {}
        W.ui(NUICB.LOCKER2_RANDOM)
        d = draftOf(W)
        local x = d.a.x or {}
        local m = W.nui(NUI.LOCKER2)
        if table.concat(listOf(m.edit.extras), ',') ~= table.concat(x, ',') then listedOk = false end
        -- The ones it kept first, in their order; the ones it put on after.
        local kept = {}
        for _, id in ipairs(prev) do
            for _, y in ipairs(x) do if y == id then kept[#kept + 1] = id end end
        end
        for i, id in ipairs(kept) do
            if x[i] ~= id then orderOk = false end
            sawKeep = true
        end
        if #x > #kept then sawAdd = true end
        if #kept < #prev then sawDrop = true end
        -- Every extra on the list wears something (Makeup may be none); none
        -- off the list does.
        for _, id in ipairs(rows) do
            local on = false
            for _, y in ipairs(x) do if y == id then on = true end end
            if id == 'tattoos' then
                local t = #listOf(m.edit.tats)
                if on and (t < 1 or t > 4) then tatsOk = false end
                if not on and t > 0 then tatsOk = false end
            elseif id ~= 'makeup' then
                local cat
                for _, c in ipairs(W.BR.Config.Locker2.categories) do if c.id == id then cat = c end end
                local r = rowOf(m, cat.rows[1])
                if on and (not r or r.v == 1) then wornOk = false end
                if not on and r then wornOk = false end
            end
        end
        W.ui(NUICB.LOCKER2_UNDO)
        if A.encode(draftOf(W).a) ~= before or table.concat(draftOf(W).a.x or {}, ',') ~= bx then undoOk = false end
        W.ui(NUICB.LOCKER2_REDO)
        W.pump(100)
    end
    ok(sawAdd and sawKeep and sawDrop, 'over 25 presses it put extras on, kept some and took some off')
    ok(orderOk, 'the extras it kept keep their places, the ones it put on join the end')
    ok(listedOk, 'and the page is told every one, in that order')
    ok(wornOk, 'each extra on wears an item, never none; each off has no row')
    ok(tatsOk, 'Tattoos on wears one to four tattoos')
    ok(undoOk, 'one Undo puts the whole look back, extras and all')
    local d = draftOf(W)
    local zoned = true
    for _, z in ipairs(TAT.zones) do
        for _, r in ipairs(d.tats[z]) do
            if TAT.list[r.i][2] ~= z or not TAT.list[r.i][4] then zoned = false end
        end
    end
    ok(zoned, 'every tattoo it chose is his, in its own zone')
    eq(W.count('GetLabelText'), 0, 'and it asked the game for no tattoo\'s name')
    -- Never bald: two hairstyles, the first none, twenty-five presses.
    local B = joined()
    B.drawCount[2] = 2
    B.ui(NUICB.LOCKER2_OPEN)
    B.ui(NUICB.LOCKER2_NEW, { sex = 'm', seq = 1 })
    B.pump(300)
    local bald = draftOf(B).a.c[2][1] == 0
    for _ = 1, 25 do
        B.ui(NUICB.LOCKER2_RANDOM)
        if draftOf(B).a.c[2][1] == 0 then bald = true end
    end
    ok(not bald, 'New and Randomize always give a hairstyle, never the list\'s first')
end

describe('mylooks.items')
do
    -- "if the answer is it doesn't draw anything - then remove that item from
    -- the list entirely" (owner, 2026-10-14): only what the game draws is
    -- listed, so the counts count real items.
    local W = joined({ { id = PID, name = 'Base', a = A.encode(A.default('m')), up = 5 } })
    W.invalid['11:3'] = true
    W.texCount['11:4'] = 0
    W.invalid['11:5:1'] = true
    W.propTex['0:2'] = 0
    W.log = {}
    W.ui(NUICB.LOCKER2_OPEN)
    eq(W.count('GetNumberOfPedDrawableVariations') + W.count('IsPedComponentVariationValid'), 0,
        'nothing is listed when the page opens')
    W.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    W.pump(300)
    local slots = {}
    for _, l in ipairs(W.log) do
        local s = l:match('^GetNumberOfPedDrawableVariations%(%d+,(%d+)%)$')
        if s then slots[#slots + 1] = tonumber(s) end
    end
    table.sort(slots)
    eq(table.concat(slots, ','), '2,3,4,6,8,11', 'the editor lists the core\'s rows alone: hair, arms, legs, shoes, undershirt, top')
    eq(W.count('GetNumberOfPedPropDrawableVariations'), 0, 'no extra\'s list before it is on the look')
    local top = rowOf(W.nui(NUI.LOCKER2), 'c11')
    eq(top.n, 37, '40 tops less gen9-only 39, invalid 3 and textureless 4')
    local seen = {}
    for _ = 1, 40 do
        W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
        seen[W.ped().comps[11][1]] = true
    end
    ok(not seen[3] and not seen[4] and not seen[39] and seen[5], 'stepping never lands on one the game would not draw')
    eq(W.BR.LockerV2.removed('m').c11, 3, 'three tops left out')
    -- An item's textures: only the ones the game says it draws.
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 4 })
    eq(W.ped().comps[11][1], 5, 'top 5')
    local r5 = rowOf(W.nui(NUI.LOCKER2), 'c11')
    eq(r5.colors, 2, 'its three textures less the invalid one')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11', c = 1 })
    eq(W.ped().comps[11][2], 2, 'its second color is texture 2')
    eq(rowOf(W.nui(NUI.LOCKER2), 'c11').c, 1, 'and is the second swatch lit')
    -- Props by their counts, once the Hat is on.
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'hat', on = true })
    eq(rowOf(W.nui(NUI.LOCKER2), 'p0').n, 20, 'a hat with no texture is left out (none and 19 hats)')
    local printed = {}
    W.env.print = function(s) printed[#printed + 1] = s end
    W.commands.brlocker2(0, {})
    W.env.print = function() end
    local line = nil
    for _, s in ipairs(printed) do if s:find('dropped', 1, true) then line = s end end
    ok(line and line:find('c11 3', 1, true) and line:find('p0 1', 1, true), 'brlocker2 says what each row left out', line)
end

describe('mylooks.forced')
do
    -- THE GAME'S FORCED COMPONENTS (#28's game data): a top puts on the arms
    -- and the undershirt it names, per texture, a jumpsuit its legs and shoes,
    -- and an undershirt its arms where the top names none. The Arms row stays
    -- the player's override.
    local W = editing(A.default('m'))
    local ZERO = hashOf('0')
    -- The flat index over a slot's base textures: here a drawable d has
    -- d % 3 + 1, so index 7 is drawable 4's first.
    W.shop['11:5:0'], W.shop['11:5:1'] = 5001, 5002
    W.forced[5001] = { { ZERO, 7, 3 }, { ZERO, 3, 8 } }
    W.forced[5002] = { { ZERO, 10, 3 }, { ZERO, 3, 8 } }
    -- A DLC arm, found by its own shop hash: arms 20, texture 1.
    W.shop['3:20:1'] = 7020
    -- One native hands a hash back signed and another unsigned: the same item.
    W.shop['3:22:0'] = 0xF0000001
    W.shop['11:12:0'] = 5012
    W.forced[5012] = { { 0xF0000001 - 0x100000000, 0, 3 } }
    W.shop['11:6:0'] = 5006
    W.forced[5006] = { { 7020, 0, 3 } }
    -- An undershirt that names its arms (and one the top forces).
    W.shop['8:12:0'] = 8012
    W.forced[8012] = { { ZERO, 1, 3 } }
    W.shop['11:7:0'] = 5007
    W.forced[5007] = { { 8012, 0, 8 } }
    W.shop['8:12:0'] = 8012
    -- A jumpsuit: its legs and shoes.
    W.shop['4:8:2'] = 4092
    W.shop['11:8:0'] = 5008
    W.forced[5008] = { { 4092, 0, 4 }, { ZERO, 7, 6 } }
    -- A top whose forced arms the game would not draw.
    W.shop['11:10:0'] = 5010
    W.forced[5010] = { { ZERO, 7, 3 } }
    W.invalid['3:4'] = nil

    local a = function() return draftOf(W).a end
    W.ui(NUICB.LOCKER2_SET, { k = 'c3', v = 2 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 6 })
    eq(W.ped().comps[11][1], 5, 'top 5 on')
    ok(a().c[3][1] == 4 and a().c[3][2] == 0, 'its arms: flat index 7 is arms 4', a().c[3][1])
    ok(a().c[8][1] == 2 and a().c[8][2] == 0, 'its undershirt: flat index 3 is undershirt 2', a().c[8][1])
    ok(W.ped().comps[3][1] == 4 and W.ped().comps[8][1] == 2, 'on the preview with it')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'c11', c = 1 })
    ok(a().c[3][1] == 5 and a().c[3][2] == 1, 'its second color names other arms: per texture', a().c[3][1])
    W.ui(NUICB.LOCKER2_UNDO)
    ok(a().c[11][2] == 0 and a().c[3][1] == 4, 'one Undo takes the color and its arms back')
    W.ui(NUICB.LOCKER2_SET, { k = 'c3', v = 10 })
    eq(a().c[3][1], 9, 'the Arms row overrides')
    eq(a().c[11][1], 5, 'and changes no top')
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 7 })
    ok(a().c[3][1] == 20 and a().c[3][2] == 1, 'a DLC top names DLC arms, found by their own hash')
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 13 })
    eq(a().c[3][1], 22, 'a hash named signed by one native and unsigned by the other is the same arms')
    -- An undershirt the top names, and its own arms.
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 8 })
    ok(a().c[8][1] == 12 and a().c[3][1] == 1, 'a top that names an undershirt: it, and the arms it names')
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 6 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c8', v = 14 })
    eq(a().c[8][1], 12, 'undershirt 12 picked')
    eq(a().c[3][1], 4, 'under a top that names arms, its own arms are not put on')
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 1 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c3', v = 3 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c8', v = 1 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c8', v = 14 })
    eq(a().c[3][1], 1, 'under a top that names none, an undershirt puts its arms on')
    -- A base top, over no undershirt: the arms as they are.
    W.ui(NUICB.LOCKER2_SET, { k = 'c8', v = 1 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c3', v = 3 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 2 })
    eq(a().c[3][1], 2, 'a top with no shop data leaves the arms as they are')
    -- A jumpsuit.
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 9 })
    ok(a().c[4][1] == 8 and a().c[4][2] == 2 and a().c[6][1] == 4, 'a jumpsuit puts its legs and shoes on')
    ok(W.ped().comps[4][1] == 8 and W.ped().comps[6][1] == 4, 'on the preview too')
    -- One the game would not draw is not put on.
    W.invalid['3:4'] = true
    W.ui(NUICB.LOCKER2_SET, { k = 'c8', v = 1 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c3', v = 3 })
    W.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 11 })
    eq(a().c[3][1], 2, 'forced arms the game would not draw are left off')
    W.invalid['3:4'] = nil
    -- Randomize puts on what its top names.
    local R = editing(A.default('m'))
    for d = 0, 38 do R.shop['11:' .. d .. ':0'] = 9000 + d end
    for d = 0, 38 do R.shop['11:' .. d .. ':1'] = 9000 + d end
    for d = 0, 38 do R.shop['11:' .. d .. ':2'] = 9000 + d end
    for d = 0, 38 do R.forced[9000 + d] = { { ZERO, 7, 3 } } end
    math.randomseed(9)
    R.ui(NUICB.LOCKER2_RANDOM)
    eq(draftOf(R).a.c[3][1], 4, 'Randomize\'s top puts its arms on')
end

describe('mylooks.colors')
do
    -- Swatches (owner, 2026-10-14: "any button showing "next color" should
    -- have a button for a color swatch instead"), and the palettes they draw.
    local W = editing(A.default('m'))
    W.ui(NUICB.LOCKER2_EXTRA, { id = 'hat', on = true })
    W.ui(NUICB.LOCKER2_SET, { k = 'p0', v = 1 })
    eq(rowOf(W.nui(NUI.LOCKER2), 'p0').colors, 1, 'no hat: one color, no swatches')
    local before = #pushes(W)
    W.ui(NUICB.LOCKER2_COLOR, { k = 'p0', c = 0 })
    eq(#pushes(W), before, 'and a swatch press is refused, pushing nothing')
    W.ui(NUICB.LOCKER2_SET, { k = 'p0', v = 3 })
    W.ui(NUICB.LOCKER2_COLOR, { k = 'p0', c = 1 })
    eq(W.ped().props[0][2], 1, 'a hat of two colors takes its second')
    eq(rowOf(W.nui(NUI.LOCKER2), 'p0').c, 1, 'the row says so')
    W.ui(NUICB.LOCKER2_COLOR, { k = 'h1', c = 3 })
    W.ui(NUICB.LOCKER2_COLOR, { k = 'o2op', c = 3 })
    eq(W.ped().hair[2], 0, 'the highlight is set by its own value, never a color index; an opacity has none')
    -- The palettes, once.
    W.log = {}
    W.ui(NUICB.LOCKER2_PAL)
    local pal = W.nui(NUI.LOCKER2_PAL)
    ok(pal and #pal.hair == 64 and #pal.makeup == 64, 'the page asks for the palettes and gets 64 of each')
    eq(pal.hair[3], '#0204fd', 'the game\'s colors, as #rrggbb')
    eq(pal.makeup[1], '#ff0000', 'the makeup palette too')
    local reads = W.count('GetPedHairRgbColor')
    W.ui(NUICB.LOCKER2_PAL)
    eq(W.count('GetPedHairRgbColor'), reads, 'built once: asking again reads nothing')
    W.locked = true
    local sent = 0
    W.ui(NUICB.LOCKER2_PAL)
    for _, e in ipairs(W.events) do
        if e.name == 'br:ui:sendLocal' and e.args[1] == NUI.LOCKER2_PAL then sent = sent + 1 end
    end
    eq(sent, 3, 'and it changes nothing, so nothing refuses it')
end

describe('mylooks.defaults')
do
    -- A face group's reset (2026-10-13: one reset a group): its sliders back to
    -- their defaults, one step.
    local W = editing(A.default('m'))
    W.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 50 })
    W.ui(NUICB.LOCKER2_SET, { k = 'ff1', v = -20 })
    W.ui(NUICB.LOCKER2_SET, { k = 'ff6', v = 30 })
    W.pump(900)
    W.ui(NUICB.LOCKER2_DEFAULTS, { ks = { 'ff0', 'ff1', 'zz', 5, 'c11' } })
    ok(W.ped().ff[0] == 0.0 and W.ped().ff[1] == 0.0 and W.ped().ff[6] == 0.3, 'its sliders back to 0, the rest kept')
    eq(draftOf(W).a.c[11][1], 0, 'a key that is no slider is left alone')
    W.ui(NUICB.LOCKER2_UNDO)
    ok(W.ped().ff[0] == 0.5 and W.ped().ff[1] == -0.2, 'one Undo puts the group back')
    local before = #pushes(W)
    W.ui(NUICB.LOCKER2_DEFAULTS, { ks = { 'ff19' } })
    W.ui(NUICB.LOCKER2_DEFAULTS, { ks = 'ff0' })
    eq(#pushes(W), before, 'a group already at its defaults, or no list: nothing pushed')
end

describe('mylooks.camera')
do
    -- The camera buttons (2026-10-14: across the bottom, a hover hint each):
    -- rotate is Season 1's spin; turn around, zoom and Reset view are
    -- LOCKER2_CAM.
    local W = editing(A.default('m'))
    local h0 = W.ped().h
    local before = #pushes(W)
    W.ui(NUICB.LOCKER2_CAM, { op = 'turn' })
    eq((W.ped().h - h0) % 360, 180.0, 'Turn around turns the look 180 degrees')
    W.ui(NUICB.LOCKER2_CAM, { op = 'zoom', d = 1 })
    eq(W.cams[#W.cams], 'zoom:1', 'Zoom in')
    W.ui(NUICB.LOCKER2_CAM, { op = 'zoom', d = -1 })
    eq(W.cams[#W.cams], 'zoom:-1', 'Zoom out (and the wheel)')
    local n = #W.cams
    W.ui(NUICB.LOCKER2_CAM, { op = 'zoom', d = 3 })
    W.ui(NUICB.LOCKER2_CAM, { op = 'zoom' })
    eq(#W.cams, n, 'a zoom of 3 or none: nothing')
    W.ui(NUICB.LOCKER_SPIN, { delta = 33 })
    W.ui(NUICB.LOCKER2_CAT, { cat = 'face' })
    W.ui(NUICB.LOCKER2_CAM, { op = 'reset' })
    eq(W.ped().h % 360, W.BR.Config.Match.lobbyPos.heading % 360, 'Reset view faces the look to the camera again')
    eq(W.cams[#W.cams], 'reset:head', 'and frames the category again')
    eq(#pushes(W) - before, 1, 'the camera pushes nothing (the one push is the category\'s)')
    W.locked = true
    local h = W.ped().h
    W.ui(NUICB.LOCKER2_CAM, { op = 'turn' })
    W.ui(NUICB.LOCKER2_CAM, { op = 'zoom', d = 1 })
    ok(W.ped().h == h and W.cams[#W.cams] == 'reset:head', 'nothing while the entrance holds the ped')
    W.locked = false
    W.ui(NUICB.LOCKER2_LEAVE, { seq = 2 })
    W.pump(300)
    W.ui(NUICB.LOCKER2_CAM, { op = 'reset' })
    eq(W.cams[#W.cams], 'reset:nil', 'on My Looks Reset view frames the whole look')
    W.ui(NUICB.LOCKER2_CLOSE)
    n = #W.cams
    W.ui(NUICB.LOCKER2_CAM, { op = 'zoom', d = 1 })
    eq(#W.cams, n, 'and with the page shut, nothing')
end

describe('mylooks.names')
do
    -- ITEM NAMES, OFF (owner, 2026-10-14: "All or nothing on that"): no row
    -- carries one and none is looked up -- unless a category is switched on.
    local W = editing(A.default('m'))
    local named = 0
    for _, r in ipairs(W.nui(NUI.LOCKER2).edit.rows) do if r.name ~= nil then named = named + 1 end end
    eq(named, 0, 'no row carries a name')
    eq(#W.invokes, 0, 'and no shop data is read')
    eq(#(W.BR.Config.Locker2.names or {}), 0, 'no category is switched on')
    W.BR.Config.Locker2.names = { 'top' }
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    local looked = {}
    for _, h in ipairs(W.invokes) do looked[h] = (looked[h] or 0) + 1 end
    ok((looked[0x0368B3A838070348] or 0) == 3, 'switched on, Top\'s three rows are looked up', looked[0x0368B3A838070348])
    eq(looked[0x5D6160275CAEC8DD], nil, 'and nothing else')
end

describe('mylooks.swaps')
do
    -- A DRAFT WHOSE MODEL LANDS AFTER THE PAGE HAS GONE (#28 review: Create,
    -- then Escape, left the player in the unsaved look, which the watcher
    -- kept on through the next match).
    local stockModel = nil
    local W = joined()
    stockModel = W.ped().model
    W.modelDelay = 500
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 1 })
    W.ui(NUICB.LOCKER2_CLOSE)
    W.pump(2500)
    eq(W.ped().model, stockModel, 'Create, then Escape while her model streams in: the worn look is back once it lands')
    ok(draftOf(W) == nil and W.BR.LockerV2.state().applied.a == nil, 'with no draft, and nothing custom left on')
    eq(W.BR.LockerV2.state().worn.id, STOCK1, 'and the worn look unchanged')
    local E = joined({ { id = PID, name = 'Ann', a = A.encode(femaleLook()), up = 5 } })
    E.modelDelay = 500
    E.ui(NUICB.LOCKER2_OPEN)
    E.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    E.ui(NUICB.LOCKER2_CLOSE)
    E.pump(2500)
    eq(E.ped().model, stockModel, 'Edit, then Escape while the look streams in: the same')
    -- A look PICKED, then the page closed while it streams in: that is a wear,
    -- and it stays on.
    local K = joined({ { id = PID, name = 'Ann', a = A.encode(femaleLook()), up = 5 } })
    K.modelDelay = 500
    K.ui(NUICB.LOCKER2_OPEN)
    K.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    K.ui(NUICB.LOCKER2_CLOSE)
    K.pump(2500)
    ok(K.ped().model == FEMALE and K.BR.LockerV2.state().worn.id == PID,
        'a look pressed, then the page closed as it streams in: it goes on and is the worn one')
    -- A model that never streams: the editor does not stand empty.
    local N = joined()
    N.neverLoad = true
    N.ui(NUICB.LOCKER2_OPEN)
    N.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 1 })
    N.pump(6000)
    local m = N.nui(NUI.LOCKER2)
    ok(m.edit == nil and m.tabSeq == 1, 'her model never streams: no draft, so the page goes back to My Looks')
    eq(N.notify[#N.notify], 'That character could not be loaded.', 'in Season 1\'s words')
    N.neverLoad = false
    N.ui(NUICB.LOCKER2_NEW, { sex = 'f', seq = 2 })
    N.pump(300)
    ok(N.nui(NUI.LOCKER2).edit ~= nil, 'and the next Create is not refused as unsaved')
end

describe('mylooks.unconfirmed')
do
    -- A WRITE THAT FAILED OR WENT UNANSWERED (#28 review): the database can
    -- still take it, so the next open asks for the looks again.
    local function reopen(W)
        W.ui(NUICB.LOCKER2_CLOSE)
        local f0 = #W.sentTo(NET.LOCKER2_FETCH)
        W.ui(NUICB.LOCKER2_OPEN)
        return #W.sentTo(NET.LOCKER2_FETCH) - f0
    end
    local W = editing(A.default('m'))
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update', id = PID, name = 'Base' })
    local s = W.sentTo(NET.LOCKER2_SAVE)[1]
    W.net(NET.LOCKER2_RESULT, { req = s.req, ok = true, ped = { id = PID, name = 'Base', a = s.a, up = 9 },
                                worn = { k = 'p', id = PID, a = s.a } })
    eq(reopen(W), 0, 'a save the server confirmed: the next open asks nothing')
    W.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 2 })
    W.pump(300)
    W.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    W.ui(NUICB.LOCKER2_SAVE, { op = 'update', id = PID, name = 'Base' })
    s = W.sentTo(NET.LOCKER2_SAVE)[2]
    W.net(NET.LOCKER2_RESULT, { req = s.req, ok = false, reason = 'store' })
    eq(reopen(W), 1, 'a save answered store: the next open asks again')
    -- Never answered: the page is given back after 10 s, and the list is unsure.
    local B = editing(A.default('m'))
    B.ui(NUICB.LOCKER2_STEP, { k = 'c11', d = 1 })
    B.ui(NUICB.LOCKER2_SAVE, { op = 'update', id = PID, name = 'Base' })
    local sb = B.sentTo(NET.LOCKER2_SAVE)[1]
    B.pump(10200)
    eq(B.BR.LockerV2.state().busy, nil, 'unanswered for 10 s: the page is given back')
    eq(reopen(B), 1, 'and the next open asks again')
    B.net(NET.LOCKER2_STATE, { worn = { k = 's', id = STOCK1 }, store = true,
                               peds = { { id = PID, name = 'Base', a = A.encode(A.default('m')), up = 5 } } })
    B.net(NET.LOCKER2_RESULT, { req = sb.req, ok = true, ped = { id = PID, name = 'Base', a = sb.a, up = 9 } })
    eq(reopen(B), 1, 'an answer that comes after that, even after a fetch: asked again')
    B.net(NET.LOCKER2_STATE, { worn = { k = 'p', id = PID, a = sb.a }, store = true,
                               peds = { { id = PID, name = 'Base', a = sb.a, up = 9 } } })
    eq(reopen(B), 0, 'and once answered, not again')
    -- The boundary of a current answer: refreshMs exactly.
    local Z = joined()
    local at = Z.BR.LockerV2.state().stateAt
    Z.time = at + Z.BR.Config.Locker2.refreshMs - 1
    eq(reopen(Z), 0, 'an answer a moment short of refreshMs old is current')
    Z.time = at + Z.BR.Config.Locker2.refreshMs
    eq(reopen(Z), 1, 'and one exactly refreshMs old is asked for again')
end

describe('mylooks.oldlists')
do
    -- A LOOK FROM ANOTHER DAY'S LISTS (#28 review): a face past today's list
    -- and an extra the list no longer has. It reads, it is worn, and it opens.
    local older = A.default('m')
    older.f, older.x = 5, { 'cape', 'hat' }
    older.p[1] = { 2, 0 }
    local W = joined({ { id = PID, name = 'Old', a = A.encode(older), up = 5 } })
    W.BR.Config.Locker2.faces.m = { 0, 4, 8, 12 }
    eq(#W.BR.LockerV2.state().peds, 1, 'the card is listed')
    W.ui(NUICB.LOCKER2_OPEN)
    W.ui(NUICB.LOCKER2_WEAR, { k = 'p', id = PID })
    W.pump(300)
    eq(W.ped().blend[1], 0, 'worn with the first face, its own trimmed away')
    W.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    W.pump(300)
    local m = W.nui(NUI.LOCKER2)
    eq(draftOf(W).a.f, nil, 'the draft starts on the first face')
    ok(rowOf(m, 'shape').v == 1 and rowOf(m, 'shape').n == 4, 'the first of four tiles lit')
    eq(table.concat(listOf(m.edit.extras), ','), 'hat', 'the retired extra is skipped, the hat listed')
    eq(m.edit.dirty, false, 'and nothing to save until something changes')
end

describe('mylooks.mutants')
do
    -- What the review's mutation pass found unpinned (#28 review), each a rule
    -- a player would see broken.
    local ZERO = hashOf('0')
    -- An item of more textures than the sync tree carries: 32 colors at most.
    local X = editing(A.default('m'))
    X.texCount['11:5'] = 40
    X.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 6 })
    eq(rowOf(X.nui(NUI.LOCKER2), 'c11').colors, 32, 'a top of 40 textures shows 32 colors, all the sync carries')
    X.ui(NUICB.LOCKER2_COLOR, { k = 'c11', c = 31 })
    eq(X.ped().comps[11][2], 31, 'the 32nd is texture 31')
    X.ui(NUICB.LOCKER2_COLOR, { k = 'c11', c = 32 })
    eq(X.ped().comps[11][2], 31, 'a 33rd is refused')
    ok(A.encode(draftOf(X).a) ~= nil, 'and the look still saves')
    -- The top's arms win over its undershirt's; the undershirt's reach the
    -- preview; a base top over an undershirt that names arms leaves them be.
    local F = editing(A.default('m'))
    local a = function() return draftOf(F).a end
    F.shop['8:12:0'] = 8012
    F.forced[8012] = { { ZERO, 1, 3 } }
    F.shop['11:5:0'] = 5001
    F.forced[5001] = { { ZERO, 7, 3 }, { 8012, 0, 8 } }
    F.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 6 })
    ok(a().c[8][1] == 12 and a().c[3][1] == 4, 'a top naming arms and an undershirt that names its own: the top\'s arms', a().c[3][1])
    F.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 1 })
    F.ui(NUICB.LOCKER2_SET, { k = 'c8', v = 1 })
    F.ui(NUICB.LOCKER2_SET, { k = 'c3', v = 3 })
    F.ui(NUICB.LOCKER2_SET, { k = 'c8', v = 14 })
    ok(a().c[3][1] == 1 and F.ped().comps[3][1] == 1, 'an undershirt\'s arms go on the preview with it', F.ped().comps[3][1])
    F.ui(NUICB.LOCKER2_SET, { k = 'c3', v = 3 })
    F.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 3 })
    eq(a().c[3][1], 2, 'a base top over an undershirt that names arms: the arms as they are')
    -- Two arms under one shop hash: the first is the one.
    local H = editing(A.default('m'))
    H.shop['3:20:1'], H.shop['3:25:0'] = 7020, 7020
    H.shop['11:6:0'] = 5006
    H.forced[5006] = { { 7020, 0, 3 } }
    H.ui(NUICB.LOCKER2_SET, { k = 'c11', v = 7 })
    eq(draftOf(H).a.c[3][1], 20, 'two arms under one hash: the first drawable')
    -- Undo ends the merge window: the next change of that row is its own step.
    local U = editing(A.default('m'))
    U.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 40 })
    U.ui(NUICB.LOCKER2_UNDO)
    U.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 60 })
    eq(U.nui(NUI.LOCKER2).edit.undo, true, 'a change of a row just undone is a step of its own')
    U.ui(NUICB.LOCKER2_UNDO)
    eq(U.ped().ff[0], 0.0, 'and Undo takes it back')
    -- The merge window's edge: coalesceMs apart is two steps.
    local G = editing(A.default('m'))
    local ms = G.BR.Config.Locker2.coalesceMs
    G.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 40 })
    G.time = G.time + ms - 1
    G.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 50 })
    G.time = G.time + ms
    G.ui(NUICB.LOCKER2_SET, { k = 'ff0', v = 60 })
    G.ui(NUICB.LOCKER2_UNDO)
    eq(G.ped().ff[0], 0.5, 'touches coalesceMs apart are two steps; a moment closer, one')
    G.ui(NUICB.LOCKER2_UNDO)
    eq(G.ped().ff[0], 0.0, 'the first two were one')
    -- Randomize's tattoos: never one twice in a zone, never past ten. Every
    -- draw the lowest it can be, so a repeat or an eleventh would show.
    local R = editing(A.default('m'))
    R.BR.Config.Locker2.random.tattoosMin, R.BR.Config.Locker2.random.tattoosMax = 25, 25
    R.env.math = setmetatable({ random = function(lo, hi)
        if lo == nil then return 0 end
        if hi == nil then return 1 end
        return lo
    end }, { __index = math })
    R.ui(NUICB.LOCKER2_RANDOM)
    local d = draftOf(R)
    local capped, once, total = true, true, 0
    for _, z in ipairs(TAT.zones) do
        if #d.tats[z] > A.TATTOOS_PER_ZONE then capped = false end
        local seen = {}
        for _, r in ipairs(d.tats[z]) do
            if seen[r.i] then once = false end
            seen[r.i] = true
            total = total + 1
        end
    end
    eq(total, 25, 'Randomize asked for 25 tattoos')
    ok(capped, 'never more than ten a zone')
    ok(once, 'and never one twice in a zone')
    -- The extras it puts on join in a random order, not the list's.
    local x = table.concat(d.a.x or {}, ',')
    local all = table.concat(R.BR.Config.Locker2.extras, ',')
    local sorted = {}
    for _, id in ipairs(d.a.x or {}) do sorted[#sorted + 1] = id end
    table.sort(sorted)
    local want = {}
    for _, id in ipairs(R.BR.Config.Locker2.extras) do want[#want + 1] = id end
    table.sort(want)
    ok(x ~= all and table.concat(sorted, ',') == table.concat(want, ','),
        'every extra put on (each draw 0), shuffled out of the list\'s order', x)
    -- A look with no change is never saved, as an update or as new.
    local S0 = editing(A.default('m'))
    S0.ui(NUICB.LOCKER2_SAVE, { op = 'update', id = PID, name = 'Base' })
    S0.ui(NUICB.LOCKER2_SAVE, { op = 'new', name = 'Copy' })
    eq(#S0.sentTo(NET.LOCKER2_SAVE), 0, 'a look with no change is not saved, as an update or as new')
    -- An item of one color takes no swatch press.
    local one = A.default('m')
    one.c[11] = { 7, 2 }
    local O = joined({ { id = PID, name = 'One', a = A.encode(one), up = 5 } })
    O.texCount['11:7'] = 1
    O.ui(NUICB.LOCKER2_OPEN)
    O.ui(NUICB.LOCKER2_EDIT, { id = PID, seq = 1 })
    O.pump(300)
    eq(rowOf(O.nui(NUI.LOCKER2), 'c11').colors, 1, 'a top of one texture, worn in a texture the game has no more')
    O.ui(NUICB.LOCKER2_COLOR, { k = 'c11', c = 0 })
    eq(draftOf(O).a.c[11][2], 2, 'an item of one color: a swatch press changes nothing')
    -- A reset reads 64 keys at most.
    local D = editing(A.default('m'))
    D.ui(NUICB.LOCKER2_SET, { k = 'ff3', v = 50 })
    local ks = {}
    for i = 1, 64 do ks[i] = 'zz' end
    ks[65] = 'ff3'
    D.ui(NUICB.LOCKER2_DEFAULTS, { ks = ks })
    eq(D.ped().ff[3], 0.5, 'a reset of more than 64 keys stops at the 64th')
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

    -- THE CAMERA BUTTONS' ZOOM (My Looks): along the line to the bone, the aim
    -- with it, so the look keeps its place on screen and only grows.
    LC.start()
    LC.focus('head')
    local function dist(c) return math.sqrt(c.x * c.x + (c.y) ^ 2 + (c.z - 1.65) ^ 2) end
    ok(LC.zoom(1), 'a step in')
    local zc = cams[interp[#interp].to]
    ok(math.abs(dist(zc) - 0.8 * 0.85) < 1e-9, 'brings the camera zoomFactor of its distance closer', dist(zc))
    ok(math.abs((zc.aim.x / dist(zc)) - (ax / 0.8)) < 1e-9, 'the aim slid with it: the head keeps its place')
    eq(interp[#interp].ms, 200, 'in zoomMs')
    for _ = 1, 10 do LC.zoom(1) end
    eq(LC.zoomed(), 4, 'no closer than zoomMax')
    ok(not LC.zoom(1), 'a step past it is nothing')
    for _ = 1, 10 do LC.zoom(-1) end
    eq(LC.zoomed(), -2, 'no further than zoomMin')
    LC.focus('feet')
    eq(LC.zoomed(), 0, 'a new category frames afresh')
    LC.zoom(1)
    ok(LC.resetView('head') and LC.zoomed() == 0 and LC.focused() == 'head', 'Reset view: the category\'s framing, no zoom')
    LC.zoom(1)
    ok(LC.unfocus() and LC.zoomed() == 0, 'leaving frames the whole look again')
    ok(LC.zoom(1), 'at home too')
    local home = cams[interp[#interp].to]
    local hx, hy, hz = LC.lobbyFrame()
    local P = env.BR.Config.Match
    local px, py, pz = P.lobbyPos.x, P.lobbyPos.y, P.lobbyPos.z + P.lobbyCam.aim
    ok(math.abs(home.x - (px + (hx - px) * 0.85)) < 1e-9 and math.abs(home.y - (py + (hy - py) * 0.85)) < 1e-9
       and math.abs(home.z - (pz + (hz - pz) * 0.85)) < 1e-9, 'the lobby frame, closer to the ped')
    ok(LC.unfocus() and LC.zoomed() == 0, 'and a zoomed home is brought back too')
    LC.zoom(1)
    LC.stop()
    eq(LC.zoomed(), 0, 'stop() forgets the zoom')
    ok(not LC.zoom(1), 'and there is nothing to zoom with the camera down')
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
    for _, k in ipairs({ 'LOCKER2', 'LOCKER2_SHOT', 'LOCKER2_TATS', 'LOCKER2_PAL' }) do
        if not types:find("'" .. NUI[k] .. "'", 1, true) then missing[#missing + 1] = NUI[k] end
    end
    eq(#keys, 27, 'twenty-seven callbacks: My Looks\' nine (2026-10-13/14) and the old tabs\' two retired')
    eq(NUICB.LOCKER2_TAT, nil, 'and no checkbox\'s on and off any more')
    eq(NUICB.LOCKER2_TAT_STEP, nil, 'nor a row\'s arrows')
    ok(NUICB.LOCKER2_TAB == nil and NUICB.LOCKER2_RESET == nil and not types:find("'br/locker2/tab'", 1, true)
        and not types:find("'br/locker2/reset'", 1, true), 'nor the old tabs and Reset, on either side')
    -- And every one the page names, this side answers.
    local pageCbs = {}
    for name in types:gmatch("'(br/locker2/[%w]+)'") do pageCbs[#pageCbs + 1] = name end
    local known = {}
    for _, v in pairs(NUICB) do known[v] = true end
    local unknown = {}
    for _, name in ipairs(pageCbs) do if not known[name] then unknown[#unknown + 1] = name end end
    ok(#pageCbs >= 27 and #unknown == 0, 'every callback the page names is Lua\'s', table.concat(unknown, ' '))
    -- The page's cap is this side's (ui-src/src/screens/lockerv2/model.ts).
    local model = readFile('ui-src/src/screens/lockerv2/model.ts') or ''
    eq(tonumber(model:match('export const TATTOOS_PER_ZONE = (%d+)')), A.TATTOOS_PER_ZONE,
        'the page\'s Add stops at the cap Lua holds')
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
            -- The starting face is the Face panel's tiles: numbered, no label.
            local base = k:match('^(o%d+)op$') or k
            if k ~= 'shape' and not labeled(rowLabels, base) then unlabeled[#unlabeled + 1] = k end
        end
    end
    ok(#rowLabels > 2 and #catLabels > 2, 'copy.ts has its ROW_LABEL and CAT_LABEL')
    ok(#unlabeled == 0, 'the page has a label for every row and category Lua sends',
       table.concat(unlabeled, ' '))
    -- And for the Tattoos section: its own heading and every zone Lua sends,
    -- each zone's category the one the page's anchor asks for.
    local zoneLabels = block('ZONE_LABEL')
    local unzoned = {}
    for _, z in ipairs(TAT.zones) do
        if not labeled(zoneLabels, z) then unzoned[#unzoned + 1] = z end
    end
    ok(labeled(catLabels, 'tattoos') and #unzoned == 0,
        'the page has a label for the Tattoos extra and every zone', table.concat(unzoned, ' '))
    local cats = {}
    for _, c in ipairs(shared.BR.Config.Locker2.tattooCats) do
        cats[#cats + 1] = c.id
        if c.zone then ok(c.id == 'tat_' .. c.zone, 'zone ' .. c.zone .. '\'s category is tat_' .. c.zone) end
    end
    eq(table.concat(cats, ','), 'tattoos,tat_head,tat_torso,tat_larm,tat_rarm,tat_lleg,tat_rleg',
        'the section and its six zones, in order')
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
