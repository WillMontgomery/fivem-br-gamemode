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
--
-- Textures stop at 31 because that is all the sync tree carries (5 bits): a
-- texture above it would show on this machine and nowhere else.
--
-- FIXED KEY ORDER, INTEGERS ONLY, AT MOST 2048 BYTES. Nothing is clamped: a
-- value out of range is refused, so the server stores exactly what the player
-- saw or nothing.

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

local TOP = { v = true, s = true, sk = true, e = true, h = true, ff = true, o = true, c = true, p = true }

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

--- The canonical string, or nil and why when `a` is not an appearance.
--- @param a table
--- @return string|nil
--- @return string|nil reason
function A.encode(a)
    local ok, why = A.validate(a)
    if not ok then return nil, why end
    return ('{"v":1,"s":"%s","sk":%d,"e":%d,"h":%s,"ff":%s,"o":%s,"c":%s,"p":%s}'):format(
        a.s, a.sk, a.e, ints(a.h), ints(a.ff), pairsOf(a.o), pairsOf(a.c), pairsOf(a.p)), nil
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

--- A ped's name: Roman letters and digits only, 1 to 24 (owner, 2026-10-07).
--- @param n any
--- @return boolean
function A.isName(n)
    return type(n) == 'string' and #n >= 1 and #n <= 24 and n:match('^[A-Za-z0-9]+$') ~= nil
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
