-- A custom ped's appearance (#28, Locker v2), as one canonical JSON string.
--
-- ═══ ONE SCHEMA, BOTH SIDES ═══
--
-- The client builds an appearance as the player clicks and applies it to the
-- ped; the server stores it in DynamoDB (`br:ddb:pedPut`) and hands it back on
-- the next join. Both load this file, so "is this an appearance" has one
-- answer. The server never trusts the client's string: it checks the size
-- before decoding, decodes, validates and re-encodes, and the canonical form
-- is what is stored.
--
-- ═══ THE FORM (v1) ═══
--
--   {"v":1,"s":"m","sk":0,"e":0,"h":[0,0],"ff":[20 ints],
--    "o":[13 x [i,op,col]],"c":[11 x [d,t]],"p":[5 x [d,t]]}
--
--   s    'm' or 'f'                    the freemode ped
--   sk   0..45                         skin tone (the head blend's skin)
--   e    0..30                         eye color
--   h    [color, highlight], 0..63     hair colors
--   ff   20 face features x 100, -100..100; features 18 and 19 (chin dimple,
--        neck thickness; Lua ff[19], ff[20]) 0..100
--   o    head overlays 0..12: [index 0..254 or 255 for none (never on the
--        eyebrows, overlay 2), opacity 0..100, color 0..63]
--   c    components 1..11: [drawable 0..1023, texture 0..31]; any bag (5),
--        parachute packs included (owner, 2026-10-07)
--   p    props 0, 1, 2, 6, 7: [drawable -1..1023 (-1 is none, with texture 0),
--        texture 0..31]
--   t    tattoos, OPTIONAL: { "<set>": "<hex>" }; absent is none, which is
--        every save from before tattoos. See THE TATTOOS below.
--   f    the starting face, OPTIONAL: an index into BR.Config.Locker2.faces
--        for the look's sex; absent is 0, the one face every look had before
--        My Looks, so an older save is the same face.
--   x    the extras on the look, OPTIONAL and last: ["hat","tattoos"], in the
--        order the player put them on (owner, 2026-10-14), each one of
--        BR.Config.Locker2.extras at most once. Absent on a save from before
--        My Looks; the client then lists the extras that are on, in the
--        extras' own order.
--
-- Textures stop at 31 because that is all the sync tree carries (5 bits): a
-- texture above it would show on this machine and nowhere else.
--
-- FIXED KEY ORDER, INTEGERS ONLY (but `t`'s hex), AT MOST 2048 BYTES. Nothing
-- is clamped: a
-- value out of range is refused, so the server stores exactly what the player
-- saw or nothing.
--
-- WHAT IS NOT ON THE PED IS NOT IN THE STRING. An overlay of none has no
-- opacity or color anyone can see, so encode() writes it as [255,100,0]
-- whatever the table holds. Two looks that show the same are then the same
-- string: equal() agrees, a draft that only changed what nobody can see is not
-- dirty, and what the server stores is what the player saw.
--
-- ═══ THE TATTOOS (2026-10-11) ═══
--
-- "No cap on tattoos per ped, and yes whatever the game has include DLC sets"
-- (owner). A tattoo is named by the game's own shop label key, TAT_<set>_<nnn>
-- (br_lib/config/tattoos.lua), and `t` holds one hex string per set with any on:
--
--   "t":{"AR":"5","FM":"0001"}   is TAT_AR_000, TAT_AR_002 and TAT_FM_012
--
-- Hex digit k (0-based) covers numbers 4k..4k+3, bit (nnn % 4) within it. So
-- any number of tattoos fits the format: every one the game has is under 500
-- bytes, and the whole appearance stays inside MAX_BYTES. A key means the same
-- tattoo on every build and for both sexes; the client puts on the overlay of
-- the appearance's own sex.
--
-- CANONICAL: sets sorted, trailing zero digits dropped, an empty set dropped,
-- and no `t` at all when nothing is on -- so a look with no tattoos encodes
-- exactly as it did before they existed. Likewise no `f` for face 0 and no `x`
-- for no extras: a look of none of My Looks' fields is the string it was. Only the SHAPE is checked here: a set
-- or a number this build's list does not know (a set the game build lacks, a
-- list from a later round) is kept as it is and skipped where tattoos are put
-- on, never refused.
--
-- THE CAP (owner, 2026-10-12): "You can just make it max 10 per category" --
-- TATTOOS_PER_ZONE in each body zone of the list. It is not the format's: a
-- look past it still reads (a save from the day there was no cap), and is
-- held to it where it is put on and edited (client/locker2.lua). A SAVE past
-- it is refused (tattoosOverCap, server/locker2.lua and the client's own
-- save), since telling a key's zone needs the list.

BR = BR or {}
BR.Appearance = {}

local A = BR.Appearance

--- The longest string decode() will look at.
A.MAX_BYTES = 2048
--- Head overlays, components, props, face features.
A.OVERLAYS = 13
A.COMPS = 11
A.PROPS = { 0, 1, 2, 6, 7 }
A.FEATURES = 20
--- The overlay that may not be none: the eyebrows.
A.EYEBROWS = 2
A.NONE = 255
--- The longest tattoo set name (the <set> of TAT_<set>_<nnn>) and hex string:
--- a label number has three digits, so 250 hex digits reach every one.
A.TATTOO_SET_MAX = 16
A.TATTOO_HEX_MAX = 250
--- The most tattoos one body zone takes (THE CAP, above).
A.TATTOOS_PER_ZONE = 10

local SEXES = { m = true, f = true }

local function isInt(v, lo, hi)
    return math.type(v) == 'integer' and v >= lo and v <= hi
end

--- The undershirt that is no undershirt, for one sex.
local function undershirtNone(s)
    local cfg = BR.Config and BR.Config.Locker2
    local u = cfg and cfg.undershirtNone
    if type(u) == 'table' and math.type(u[s]) == 'integer' then return u[s] end
    return s == 'f' and 14 or 15
end

--- The prop slot at position i of `p`.
--- @param i integer 1..5
--- @return integer
function A.propSlot(i) return A.PROPS[i] end

--- A fresh appearance: every value 0, opacities 100, overlays none (eyebrows
--- the first), no undershirt, no props.
--- @param s string 'm' | 'f'
--- @return table
function A.default(s)
    if not SEXES[s] then s = 'm' end
    local a = { v = 1, s = s, sk = 0, e = 0, h = { 0, 0 }, ff = {}, o = {}, c = {}, p = {} }
    for i = 1, A.FEATURES do a.ff[i] = 0 end
    for i = 1, A.OVERLAYS do
        a.o[i] = { (i - 1) == A.EYEBROWS and 0 or A.NONE, 100, 0 }
    end
    for i = 1, A.COMPS do a.c[i] = { 0, 0 } end
    a.c[8] = { undershirtNone(s), 0 }
    for i = 1, #A.PROPS do a.p[i] = { -1, 0 } end
    return a
end

--- A deep copy.
--- @param a table
--- @return table
function A.copy(a)
    if type(a) ~= 'table' then return a end
    local o = {}
    for k, v in pairs(a) do o[k] = A.copy(v) end
    return o
end

--- An array of exactly `n` entries, and nothing else in the table.
local function isList(t, n)
    if type(t) ~= 'table' then return false end
    local count = 0
    for k in pairs(t) do
        if math.type(k) ~= 'integer' or k < 1 or k > n then return false end
        count = count + 1
    end
    return count == n
end

--- Only these keys.
local function onlyKeys(t, allowed)
    for k in pairs(t) do
        if not allowed[k] then return false end
    end
    return true
end

local TOP = { v = true, s = true, sk = true, e = true, h = true, ff = true, o = true, c = true, p = true,
              t = true, f = true, x = true }

--- How many starting faces a sex has (BR.Config.Locker2.faces).
local function faceCount(s)
    local cfg = BR.Config and BR.Config.Locker2
    local f = cfg and cfg.faces and cfg.faces[s]
    return type(f) == 'table' and #f or 1
end

--- The extras a look's `x` may name, as a set.
local extraSet = nil
local function extras()
    if extraSet then return extraSet end
    local cfg = BR.Config and BR.Config.Locker2
    local set = {}
    for _, id in ipairs(cfg and cfg.extras or {}) do set[id] = true end
    if next(set) ~= nil then extraSet = set end
    return set
end

--- `x`'s shape: a list of known extras, none twice.
local function validExtras(x)
    if x == nil then return true end
    if type(x) ~= 'table' then return false end
    local n = 0
    for _ in pairs(x) do n = n + 1 end
    if n ~= #x then return false end
    local known, seen = extras(), {}
    for _, id in ipairs(x) do
        if type(id) ~= 'string' or not known[id] or seen[id] then return false end
        seen[id] = true
    end
    return true
end

--- A tattoo set's name: capitals and digits, words joined by one `_` (BUS_F).
local function isSet(k)
    return type(k) == 'string' and #k >= 1 and #k <= A.TATTOO_SET_MAX and k:match('^[%u%d_]+$') ~= nil
        and k:find('__', 1, true) == nil and k:sub(1, 1) ~= '_' and k:sub(-1) ~= '_'
end

--- `t`'s shape -- set -> hex string -- and never what the sets mean.
local function validTattoos(t)
    if t == nil then return true end
    if type(t) ~= 'table' then return false end
    for k, v in pairs(t) do
        if not isSet(k) then return false end
        if type(v) ~= 'string' or #v > A.TATTOO_HEX_MAX or v:match('^[0-9a-f]*$') == nil then
            return false
        end
    end
    return true
end

--- Is this an appearance? Never clamps.
--- @param a any
--- @return boolean ok
--- @return string|nil reason  which part failed, for the console
function A.validate(a)
    if type(a) ~= 'table' then return false, 'not a table' end
    if not onlyKeys(a, TOP) then return false, 'unknown key' end
    if a.v ~= 1 or math.type(a.v) ~= 'integer' then return false, 'v' end
    if type(a.s) ~= 'string' or not SEXES[a.s] then return false, 's' end
    if not isInt(a.sk, 0, 45) then return false, 'sk' end
    if not isInt(a.e, 0, 30) then return false, 'e' end
    if not isList(a.h, 2) or not isInt(a.h[1], 0, 63) or not isInt(a.h[2], 0, 63) then
        return false, 'h'
    end
    if not isList(a.ff, A.FEATURES) then return false, 'ff' end
    for i = 1, A.FEATURES do
        local lo = (i == 19 or i == 20) and 0 or -100
        if not isInt(a.ff[i], lo, 100) then return false, 'ff' .. (i - 1) end
    end
    if not isList(a.o, A.OVERLAYS) then return false, 'o' end
    for i = 1, A.OVERLAYS do
        local o = a.o[i]
        if not isList(o, 3) then return false, 'o' .. (i - 1) end
        local idx = o[1]
        local okIdx = isInt(idx, 0, 254) or (idx == A.NONE and math.type(idx) == 'integer'
            and (i - 1) ~= A.EYEBROWS)
        if not okIdx or not isInt(o[2], 0, 100) or not isInt(o[3], 0, 63) then
            return false, 'o' .. (i - 1)
        end
    end
    if not isList(a.c, A.COMPS) then return false, 'c' end
    for i = 1, A.COMPS do
        local c = a.c[i]
        if not isList(c, 2) or not isInt(c[1], 0, 1023) or not isInt(c[2], 0, 31) then
            return false, 'c' .. i
        end
    end
    if not isList(a.p, #A.PROPS) then return false, 'p' end
    for i = 1, #A.PROPS do
        local p = a.p[i]
        if not isList(p, 2) or not isInt(p[1], -1, 1023) or not isInt(p[2], 0, 31) then
            return false, 'p' .. A.PROPS[i]
        end
        if p[1] == -1 and p[2] ~= 0 then return false, 'p' .. A.PROPS[i] end
    end
    if not validTattoos(a.t) then return false, 't' end
    if a.f ~= nil and not isInt(a.f, 0, faceCount(a.s) - 1) then return false, 'f' end
    if not validExtras(a.x) then return false, 'x' end
    return true, nil
end

local function ints(t)
    local out = {}
    for i = 1, #t do out[i] = tostring(t[i]) end
    return '[' .. table.concat(out, ',') .. ']'
end

local function pairsOf(t)
    local out = {}
    for i = 1, #t do out[i] = ints(t[i]) end
    return '[' .. table.concat(out, ',') .. ']'
end

--- An overlay of none, as it is written: the opacity and color it has by
--- default, since neither shows.
local NONE_OVERLAY = '[255,100,0]'

local function overlaysOf(o)
    local out = {}
    for i = 1, #o do out[i] = o[i][1] == A.NONE and NONE_OVERLAY or ints(o[i]) end
    return '[' .. table.concat(out, ',') .. ']'
end

--- `t` as it is written: ',"t":{...}' with its sets sorted, each without its
--- trailing zero digits, an empty one left out -- or '' when nothing is on.
local function tattoosOf(t)
    if t == nil then return '' end
    local sets = {}
    for k, v in pairs(t) do
        local hex = v:gsub('0+$', '')
        if hex ~= '' then sets[#sets + 1] = { k, hex } end
    end
    if #sets == 0 then return '' end
    table.sort(sets, function(x, y) return x[1] < y[1] end)
    local out = {}
    for i, s in ipairs(sets) do out[i] = ('"%s":"%s"'):format(s[1], s[2]) end
    return ',"t":{' .. table.concat(out, ',') .. '}'
end

--- `f` as it is written: ',"f":N', or '' for the first face.
local function faceOf(f)
    if f == nil or f == 0 then return '' end
    return (',"f":%d'):format(f)
end

--- `x` as it is written: ',"x":["hat",...]' in its order, or '' for none.
local function extrasOf(x)
    if x == nil or #x == 0 then return '' end
    local out = {}
    for i, id in ipairs(x) do out[i] = '"' .. id .. '"' end
    return ',"x":[' .. table.concat(out, ',') .. ']'
end

--- The canonical string, or nil and why when `a` is not an appearance.
--- @param a table
--- @return string|nil
--- @return string|nil reason
function A.encode(a)
    local ok, why = A.validate(a)
    if not ok then return nil, why end
    return ('{"v":1,"s":"%s","sk":%d,"e":%d,"h":%s,"ff":%s,"o":%s,"c":%s,"p":%s%s%s%s}'):format(
        a.s, a.sk, a.e, ints(a.h), ints(a.ff), overlaysOf(a.o), pairsOf(a.c), pairsOf(a.p),
        tattoosOf(a.t), faceOf(a.f), extrasOf(a.x)), nil
end

-- ═══ TATTOOS BY LABEL KEY ═══

--- A label key's set and number: 'TAT_BUS_F_013' is 'BUS_F', 13. nil for a
--- key that is not TAT_<set>_<three digits>.
--- @param key any
--- @return string|nil set
--- @return integer|nil n
function A.tattooPart(key)
    if type(key) ~= 'string' then return nil, nil end
    local set, n = key:match('^TAT_(.+)_(%d%d%d)$')
    if not set or not isSet(set) then return nil, nil end
    return set, math.tointeger(tonumber(n))
end

--- Is this tattoo on?
--- @param a table
--- @param key string
--- @return boolean
function A.hasTattoo(a, key)
    local set, n = A.tattooPart(key)
    if not set or type(a.t) ~= 'table' then return false end
    local hex = a.t[set]
    local k = n // 4 + 1
    if type(hex) ~= 'string' or #hex < k then return false end
    local d = tonumber(hex:sub(k, k), 16) or 0
    return d & (1 << (n % 4)) ~= 0
end

--- Put a tattoo on or take it off. The format takes any number; the cap per
--- zone is held by whoever edits a look (client/locker2.lua).
--- @param a table
--- @param key string
--- @param on boolean
--- @return boolean  false for a key that is not a tattoo's
function A.setTattoo(a, key, on)
    local set, n = A.tattooPart(key)
    if not set then return false end
    local t = type(a.t) == 'table' and a.t or {}
    local hex = t[set] or ''
    local k = n // 4 + 1
    if #hex < k then hex = hex .. string.rep('0', k - #hex) end
    local d = tonumber(hex:sub(k, k), 16) or 0
    local bit = 1 << (n % 4)
    d = on and (d | bit) or (d & ~bit)
    hex = (hex:sub(1, k - 1) .. ('%x'):format(d) .. hex:sub(k + 1)):gsub('0+$', '')
    t[set] = hex ~= '' and hex or nil
    a.t = next(t) ~= nil and t or nil
    return true
end

--- Every tattoo on, as label keys, sorted.
--- @param a table
--- @return string[]
function A.tattoos(a)
    local out = {}
    if type(a.t) ~= 'table' then return out end
    for set, hex in pairs(a.t) do
        if isSet(set) and type(hex) == 'string' then
            for k = 1, #hex do
                local d = tonumber(hex:sub(k, k), 16) or 0
                for b = 0, 3 do
                    if d & (1 << b) ~= 0 then out[#out + 1] = ('TAT_%s_%03d'):format(set, (k - 1) * 4 + b) end
                end
            end
        end
    end
    table.sort(out)
    return out
end

--- Does any body zone of `a` hold more than TATTOOS_PER_ZONE tattoos?
--- `zoneOf(key, sex)` is a label key's zone, or nil for a key that is never
--- put on that sex here (a set no list knows, the other sex's alone): kept in
--- the look, and not counted.
--- @param a table
--- @param zoneOf fun(key: string, sex: string): string|nil
--- @return boolean
function A.tattoosOverCap(a, zoneOf)
    local n = {}
    for _, key in ipairs(A.tattoos(a)) do
        local z = zoneOf(key, a.s)
        if z ~= nil then
            n[z] = (n[z] or 0) + 1
            if n[z] > A.TATTOOS_PER_ZONE then return true end
        end
    end
    return false
end

-- ═══ A STRICT JSON READER ═══
--
-- The schema needs objects, arrays, integers and short strings, and nothing
-- else; a reader that knew floats, escapes or literals would only be more ways
-- in. It works the same on a client, on the server and in the suites (the
-- runtime's json.decode is not in the plain interpreter, and would accept a
-- float this schema refuses).

local function skip(s, i)
    local _, e = s:find('^[ \t\r\n]*', i)
    return e + 1
end

local parseValue

local function parseString(s, i)
    -- Letters, digits and the punctuation an id may hold; no escapes.
    local str, e = s:match('^"([%w_%-#]*)"()', i)
    if not str then return nil, nil end
    return str, e
end

local function parseNumber(s, i)
    -- Digits only. A float or an exponent leaves a '.' or an 'e' where the
    -- object or array expects a separator, so it fails there.
    local num, e = s:match('^(%-?%d+)()', i)
    if not num then return nil, nil end
    if #num > 6 then return nil, nil end
    return math.tointeger(tonumber(num)), e
end

local function parseArray(s, i, depth)
    local out = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == ']' then return out, i + 1 end
    while true do
        local v
        v, i = parseValue(s, i, depth + 1)
        if v == nil then return nil, nil end
        out[#out + 1] = v
        i = skip(s, i)
        local ch = s:sub(i, i)
        if ch == ']' then return out, i + 1 end
        if ch ~= ',' then return nil, nil end
        i = skip(s, i + 1)
    end
end

local function parseObject(s, i, depth)
    local out = {}
    i = skip(s, i + 1)
    if s:sub(i, i) == '}' then return out, i + 1 end
    while true do
        local key
        key, i = parseString(s, i)
        if key == nil or out[key] ~= nil then return nil, nil end
        i = skip(s, i)
        if s:sub(i, i) ~= ':' then return nil, nil end
        local v
        v, i = parseValue(s, skip(s, i + 1), depth + 1)
        if v == nil then return nil, nil end
        out[key] = v
        i = skip(s, i)
        local ch = s:sub(i, i)
        if ch == '}' then return out, i + 1 end
        if ch ~= ',' then return nil, nil end
        i = skip(s, i + 1)
    end
end

parseValue = function(s, i, depth)
    if depth > 6 then return nil, nil end
    local ch = s:sub(i, i)
    if ch == '{' then return parseObject(s, i, depth) end
    if ch == '[' then return parseArray(s, i, depth) end
    if ch == '"' then return parseString(s, i) end
    return parseNumber(s, i)
end

--- Parse a JSON text of objects, arrays, integers and plain strings.
--- @param s string
--- @return any|nil
function A.parse(s)
    if type(s) ~= 'string' or #s > A.MAX_BYTES * 2 then return nil end
    local v, i = parseValue(s, skip(s, 1), 0)
    if v == nil then return nil end
    if skip(s, i) ~= #s + 1 then return nil end
    return v
end

--- An appearance out of a string, or nil and why. The size is checked before
--- anything is read.
--- @param s any
--- @return table|nil
--- @return string|nil reason
function A.decode(s)
    if type(s) ~= 'string' then return nil, 'not a string' end
    if #s > A.MAX_BYTES then return nil, 'too long' end
    local a = A.parse(s)
    if a == nil then return nil, 'not JSON' end
    local ok, why = A.validate(a)
    if not ok then return nil, why end
    return a, nil
end

--- Are two appearances the same?
--- @param a table|nil
--- @param b table|nil
--- @return boolean
function A.equal(a, b)
    if a == nil or b == nil then return a == b end
    local ea, eb = A.encode(a), A.encode(b)
    return ea ~= nil and ea == eb
end

-- ═══ SAVED PEDS AND THE WORN RECORD ═══

--- A saved ped's id: nine base36 digits of milliseconds and two random ones.
--- Ids sort by creation.
A.ID_LEN = 11

--- @param id any
--- @return boolean
function A.isPedId(id)
    return type(id) == 'string' and #id == A.ID_LEN and id:match('^[0-9a-z]+$') ~= nil
end

--- A look's name: Roman letters and digits (owner, 2026-10-07), words of
--- them one space apart ("we need to allow spaces in the ped names", owner,
--- 2026-10-12), 1 to 24 in all -- never a space first, last or doubled.
--- ui-src/src/screens/lockerv2/model.ts nameOk and js-src/br_ddb's isName say
--- the same.
--- @param n any
--- @return boolean
function A.isName(n)
    if type(n) ~= 'string' or #n < 1 or #n > 24 then return false end
    if n:match('^[A-Za-z0-9 ]+$') == nil then return false end
    return n:sub(1, 1) ~= ' ' and n:sub(-1) ~= ' ' and n:find('  ', 1, true) == nil
end

local B36 = '0123456789abcdefghijklmnopqrstuvwxyz'

--- A new id for `ms` milliseconds since the epoch.
--- @param ms integer
--- @param rand function|nil  (lo, hi) -> integer; math.random by default
--- @return string
function A.newId(ms, rand)
    rand = rand or math.random
    local n = math.max(0, math.floor(ms))
    local out = {}
    for i = 9, 1, -1 do
        local d = n % 36
        out[i] = B36:sub(d + 1, d + 1)
        n = n // 36
    end
    for i = 10, 11 do
        local d = rand(0, 35)
        out[i] = B36:sub(d + 1, d + 1)
    end
    return table.concat(out)
end

--- Is this a stock ped's id (BR.Config.Peds)?
--- @param id any
--- @return boolean
function A.isStockId(id)
    if type(id) ~= 'string' or #id > 32 then return false end
    local peds = BR.Config and BR.Config.Peds
    if type(peds) ~= 'table' then return false end
    for _, p in ipairs(peds) do
        if p.id == id then return true end
    end
    return false
end

--- The worn record, canonical: {"k":"s","id":"<stock id>"} or
--- {"k":"p","id":"<ped id>","a":{...}}. A saved ped's appearance is COPIED in,
--- so deleting that ped leaves the player wearing it.
--- @param w table  { k, id, a? }
--- @return string|nil
function A.encodeWorn(w)
    if type(w) ~= 'table' then return nil end
    if w.k == 's' and A.isStockId(w.id) then
        return ('{"k":"s","id":"%s"}'):format(w.id)
    end
    if w.k == 'p' and A.isPedId(w.id) then
        local a = A.encode(w.a)
        if not a then return nil end
        return ('{"k":"p","id":"%s","a":%s}'):format(w.id, a)
    end
    return nil
end

--- The worn record out of a string, or nil.
--- @param s any
--- @return table|nil  { k, id, a? }
function A.decodeWorn(s)
    if type(s) ~= 'string' or s == '' or #s > A.MAX_BYTES + 64 then return nil end
    local w = A.parse(s)
    if type(w) ~= 'table' then return nil end
    if w.k == 's' and A.isStockId(w.id) and onlyKeys(w, { k = true, id = true }) then
        return { k = 's', id = w.id }
    end
    if w.k == 'p' and A.isPedId(w.id) and onlyKeys(w, { k = true, id = true, a = true }) then
        local ok = A.validate(w.a)
        if ok then return { k = 'p', id = w.id, a = w.a } end
    end
    return nil
end
