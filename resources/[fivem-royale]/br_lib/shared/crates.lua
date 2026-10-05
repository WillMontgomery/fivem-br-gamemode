-- Season 2 crates (#395): every question about a crate's LOOK, answered in one
-- place for the server, the client and the suites. The tables are
-- br_lib/config/crates.lua; this file is the only reader of them.
--
-- ═══ A LOOK IS THREE FIELDS, AND THEY RIDE THE CRATE ═══
--
--   bt  the tier, 1..5 (BR.Rarity): the best rarity inside, so the tape color.
--       Set when the crate enters the registry and KEPT when it becomes a husk,
--       which is how the open prop knows its tape -- the husk's own `rarity` is
--       common, as it always has been.
--   bf  true for the festive set. Decided once per match from the server's
--       date (festiveNow below) and stamped on every crate, so every client
--       agrees without a clock of its own.
--   bg  a gift color, for the gift box. Only `brbox` makes one.
--
-- A crate with no `bt` is today's wooden crate, which is what every crate on a
-- Season 1 server is. Nothing here reads the season: the server stamps only
-- when BR.Season.has('crates2') says so (br_core/server/loot.lua).
--
-- ═══ NOTHING HERE CAN BREAK A CRATE ═══
--
-- A row whose names still start with PLACEHOLDER answers nil to every question,
-- and nil means "the wooden crate, opened the way it is today". The client also
-- falls back to the wooden crate for any model its build does not have
-- (br_core/client/loot.lua), and the server plays a clip only while the props'
-- resource runs on its box (openMs).

BR = BR or {}
BR.Crates = BR.Crates or {}

-- THE DEV SWITCH, server side: BR.Crates.festiveOverride. nil (the default)
-- follows the date; true or false forces the festive set. Written only by
-- `brfestive` (br_core/server/loot.lua), and never assigned here, so a second
-- load of this file cannot quietly drop it.

--- @return table|nil
local function cfg()
    local C = BR.Config and BR.Config.Crates
    if type(C) ~= 'table' then return nil end
    return C
end

--- Is this config name missing, or still a placeholder?
---
--- ANYTHING THAT IS NOT A NON-EMPTY STRING COUNTS, as does any string beginning
--- PLACEHOLDER in any case. The config marks every name the owner has not given
--- yet that way, so "is this a real model" never depends on somebody
--- remembering to empty a field.
--- @param s any
--- @return boolean
function BR.Crates.placeholder(s)
    if type(s) ~= 'string' or s == '' then return true end
    return s:upper():sub(1, 11) == 'PLACEHOLDER'
end

--- The tier a rarity paints, clamped to the five tapes.
--- @param rarity any
--- @return integer
function BR.Crates.tierOf(rarity)
    local n = math.tointeger(tonumber(rarity)) or 1
    if n < 1 then return 1 end
    if n > 5 then return 5 end
    return n
end

--- A crate's look out of its three fields (an entry, a wire entry or a record).
--- nil for a crate that carries none: today's wooden crate.
--- @param t table|nil  anything with bt, bf, bg
--- @return table|nil   { t, f, g }
function BR.Crates.lookOf(t)
    if type(t) ~= 'table' or t.bt == nil then return nil end
    return {
        t = BR.Crates.tierOf(t.bt),
        f = t.bf == true,
        g = type(t.bg) == 'string' and t.bg or nil,
    }
end

--- Which prompt row a look uses: 'gift' for the gift box, 'shipping' for every
--- other box, festive included.
--- @param look table|nil
--- @return string|nil
function BR.Crates.kindOf(look)
    if not look then return nil end
    return look.g and 'gift' or 'shipping'
end

--- The config row for a look, or nil.
--- @param look table|nil
--- @return table|nil
function BR.Crates.row(look)
    local C = cfg()
    if not C or not look then return nil end
    if look.g then
        return type(C.gift) == 'table' and C.gift[look.g] or nil
    end
    local set = look.f and C.festive or C.shipping
    return type(set) == 'table' and set[look.t] or nil
end

--- Is every name in this row real, and the clip's length a positive number?
--- @param row table|nil
--- @return boolean
function BR.Crates.rowReady(row)
    if type(row) ~= 'table' then return false end
    for _, k in ipairs({ 'sealed', 'open', 'dict', 'clip' }) do
        if BR.Crates.placeholder(row[k]) then return false end
    end
    local ms = tonumber(row.clipMs)
    return ms ~= nil and ms > 0
end

--- The model this look wears, sealed or open, or nil for the wooden crate.
---
--- A NAME, NOT A HASH, so this file needs no native. The client hashes it and
--- asks its own build whether the model exists.
--- @param look table|nil
--- @param open boolean
--- @return string|nil
function BR.Crates.modelName(look, open)
    local row = BR.Crates.row(look)
    if not row then return nil end
    local name = open and row.open or row.sealed
    if BR.Crates.placeholder(name) then return nil end
    return name
end

--- The clip that opens this look: dict, clip, length in ms -- or nil when any
--- of the three is missing or a placeholder.
--- @param look table|nil
--- @return string|nil dict
--- @return string|nil clip
--- @return number|nil ms
function BR.Crates.clipOf(look)
    local row = BR.Crates.row(look)
    if not row then return nil end
    if BR.Crates.placeholder(row.dict) or BR.Crates.placeholder(row.clip) then return nil end
    local ms = tonumber(row.clipMs)
    if not ms or ms <= 0 then return nil end
    return row.dict, row.clip, ms
end

--- Does the props' resource run on this box?
---
--- THE SERVER'S ANSWER TO "WOULD A CLIENT HAVE THESE MODELS". Clients download
--- what the server streams, so a server without the resource started has
--- clients without the props -- and a clip timed for a box nobody can see is a
--- crate that opens a second and a half late for no visible reason. So while
--- this is false every crate opens the way it does today.
--- @param stateFn function|nil  GetResourceState by default
--- @return boolean
function BR.Crates.assetsPresent(stateFn)
    local C = cfg()
    if not C or BR.Crates.placeholder(C.resource) then return false end
    stateFn = stateFn or GetResourceState
    if not stateFn then return false end
    return stateFn(C.resource) == 'started'
end

--- How long the open takes for this look, in ms, or nil for today's instant
--- open. The server times the burst off this.
---
--- nil unless the whole row is real AND the props run on this box. A missing
--- clip or model is exactly today's crate.
--- @param look table|nil
--- @param stateFn function|nil
--- @return number|nil
function BR.Crates.openMs(look, stateFn)
    local row = BR.Crates.row(look)
    if not BR.Crates.rowReady(row) then return nil end
    if not BR.Crates.assetsPresent(stateFn) then return nil end
    return tonumber(row.clipMs)
end

--- Is this date in the festive months?
--- @param date table|nil  os.date('*t') shape; only `month` is read
--- @return boolean
function BR.Crates.festiveDate(date)
    local C = cfg()
    local months = C and C.festiveMonths or nil
    if type(date) ~= 'table' or type(months) ~= 'table' then return false end
    local m = math.tointeger(tonumber(date.month))
    return m ~= nil and months[m] == true
end

--- The festive answer right now: the dev switch if it is set, the date if not.
---
--- SERVER ONLY. The client has no `os` library and never asks: it reads `bf`
--- off the crate.
--- @param dateFn function|nil  os.date by default
--- @return boolean
function BR.Crates.festiveNow(dateFn)
    if BR.Crates.festiveOverride ~= nil then return BR.Crates.festiveOverride == true end
    dateFn = dateFn or (os and os.date)
    if not dateFn then return false end
    local ok, d = pcall(dateFn, '*t')
    if not ok then return false end
    return BR.Crates.festiveDate(d)
end

--- The prompt row for a kind ('shipping' or 'gift'). The gift box has its own;
--- every other box shares one.
--- @param kind string|nil
--- @return table|nil
function BR.Crates.prompt(kind)
    local C = cfg()
    local P = C and C.prompt or nil
    if type(P) ~= 'table' then return nil end
    if kind == 'gift' and type(P.gift) == 'table' then return P.gift end
    return type(P.shipping) == 'table' and P.shipping or nil
end

--- Is this a gift color the config knows?
--- @param g any
--- @return boolean
function BR.Crates.isGift(g)
    local C = cfg()
    return type(g) == 'string' and C ~= nil and type(C.gift) == 'table'
        and C.gift[g] ~= nil
end

--- Every look the config defines, in a fixed order: shipping 1-5, festive 1-5,
--- then the gift colors. For the dev check and the suites.
--- @return table[]  each { look, label }
function BR.Crates.allLooks()
    local out = {}
    for t = 1, 5 do out[#out + 1] = { look = { t = t, f = false }, label = ('ship %d'):format(t) } end
    for t = 1, 5 do out[#out + 1] = { look = { t = t, f = true }, label = ('festive %d'):format(t) } end
    local C = cfg()
    for _, g in ipairs(C and C.giftColors or {}) do
        out[#out + 1] = { look = { t = 1, f = false, g = g }, label = ('gift %s'):format(g) }
    end
    return out
end
