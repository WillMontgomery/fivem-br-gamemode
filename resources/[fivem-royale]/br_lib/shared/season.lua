-- The season this server runs, and the one door every season-gated feature
-- asks (#388). The list of gated features is br_lib/config/seasons.lua.
--
-- ═══ ONE READ, ON ONE SIDE, AT ONE MOMENT ═══
--
-- br_season is read in this file and nowhere else; verify.sh's `season gates`
-- fails any other file that names it. br_core's server/main.lua calls
-- BR.Season.boot() as br_core starts, and boot reads br_season ONCE, holds the
-- answer for the life of the resource, and replicates it to every client. A
-- change to br_season after that is ignored until br_core next starts, and the
-- console is told so once (BR.Season.recheck).
--
-- ═══ THE ANSWER CROSSES UNDER ITS OWN NAME, br_seasonServed ═══
--
-- Dev mode writes its resolved answer back under one of the names it reads
-- (server/main.lua, br_devMode) and documents the one case where that bites.
-- Here it would bite twice, so the design in #388 is departed from on this one
-- point:
--
--   * An unset box would write `br_season 2` on its first start, so the next
--     `restart br_core` would find it set: no warning, and the box would keep
--     that season after a deploy raised `latest` instead of running the latest.
--   * A live `setr br_season 3` typed into the console would reach every client
--     at once while the server kept the season it started with, so what the
--     page shows and what the server allows would disagree until a restart.
--
-- br_seasonServed is written only here, only by boot, and only with the number
-- the server is actually running. Nobody types it, so nothing but a br_core
-- start can move it.
--
-- ═══ EVERYWHERE ELSE IT IS READ AT CALL TIME ═══
--
-- A client, and any server state that is not br_core's, never boots: current()
-- reads br_seasonServed each time it is asked, the way BR.Dev.on() reads
-- br_devMode (br_lib/shared/devgate.lua says why: a replicated convar can land
-- after the scripts load, and a value kept from load time would be wrong for
-- the life of the process). So NOTHING may call has() or pick() while a file
-- loads and keep the answer. Unset or garbled is read as `latest` there too,
-- the same rule the server applies; a client sees it only before the convar
-- arrives, because the server always sends a valid number.
--
-- ═══ THE CLIENT DECIDES NOTHING A PLAYER COULD CHEAT ═══
--
-- A client's answer drives what it SHOWS and what it bothers to ask for. Every
-- door a modified client could walk through asks again on the server, which
-- holds the season it booted with and never reads a client's word for it.
--
-- ═══ DEV MODE IS SEPARATE ═══
--
-- Dev mode is tooling: who may type which console command. Seasons are content.
-- Nothing here reads dev mode, and nothing in devgate.lua reads the season.

BR = BR or {}
BR.Season = BR.Season or {}

--- What the operator sets in server.cfg. Read by boot() and recheck() only.
BR.Season.CONVAR = 'br_season'
--- What boot() replicates: the season the server is running.
BR.Season.SERVED = 'br_seasonServed'

--- THE TESTS' SWITCH. With it on, has() of an id with no row and pick() of a
--- key that is not a season RAISE instead of answering. Off in game, where an
--- unknown id is off (fails closed) and says so once in the console.
if BR.Season.strict == nil then BR.Season.strict = false end

--- The highest season a convar may name. Far past any real one; it is here so
--- a number too long to be an integer is refused rather than rounded.
local MAX = 9999

--- br_core's server only, from boot() on: { season, raw }.
local latched = nil
--- recheck() has already reported a change.
local reported = false
--- has() ids already reported as unknown, so a door asked every frame prints once.
local unknownSeen = {}

--- The newest season this code knows, off the registry. 1 if the registry is
--- missing or malformed -- the launch season -- and every has() is then off
--- anyway, because there are no rows to be on.
--- @return integer
local function latest()
    local cfg = BR.Config and BR.Config.Seasons
    local n = type(cfg) == 'table' and cfg.latest or nil
    if math.type(n) == 'integer' and n >= 1 then return n end
    return 1
end

--- A convar's text, made safe and short enough to quote in one console line.
--- @param raw string @return string
local function quoted(raw)
    local s = raw:gsub('%c', '?')
    if #s > 32 then s = s:sub(1, 32) .. '...' end
    return '"' .. s .. '"'
end

--- A season out of a convar's text, or nil and why not.
---
--- A WHOLE NUMBER FROM 1, AS DIGITS AND NOTHING ELSE. Surrounding spaces are
--- forgiven; a sign, a decimal point, an exponent or hex are not, because each
--- is a typo for some other number and a season is not something to guess at.
--- @param raw any
--- @return integer|nil season
--- @return string|nil why  'unset' or 'not a season'
function BR.Season.parse(raw)
    if type(raw) ~= 'string' then return nil, 'unset' end
    local s = raw:match('^%s*(.-)%s*$')
    if s == '' then return nil, 'unset' end
    if not s:match('^%d+$') then return nil, 'not a season' end
    local n = math.tointeger(tonumber(s))
    if not n or n < 1 or n > MAX then return nil, 'not a season' end
    return n
end

--- The season a convar's text means: itself when it is one, `latest` when not.
--- @param raw any
--- @return integer season
--- @return string|nil why  nil when `raw` named the season itself
function BR.Season.resolve(raw)
    local n, why = BR.Season.parse(raw)
    if n then return n, nil end
    return latest(), why
end

--- The boot banner's lines for a resolved season.
--- @param n integer @param raw string @param why string|nil
--- @return string[]
local function banner(n, raw, why)
    local top = latest()
    local L = {}
    local function add(s) L[#L + 1] = '[br_core] ' .. s end
    local bar = '############################################################'

    if why == nil and n <= top then
        add(('  season       %d (br_season)'):format(n))
        return L
    end

    if why == nil then
        add(('  season       %d (br_season; this code knows Seasons 1 to %d)'):format(n, top))
        add(bar)
        add(('  br_season IS %d, PAST SEASON %d, the newest this code knows.'):format(n, top))
        add(('  It runs as Season %d anyway. Check this box is running the'):format(n))
        add('  code you meant it to.')
        add(bar)
        return L
    end

    if why == 'unset' then
        add(('  season       %d (br_season is not set: the latest)'):format(n))
        add(bar)
        add(('  br_season IS NOT SET, so this server runs Season %d, the'):format(n))
        add('  newest this code knows. A public server must say which')
        add('  season it runs. In server.cfg, above `ensure br_core`:')
        add('      set br_season <n>')
        add(bar)
        return L
    end

    add(('  season       %d (br_season %s is not a season: the latest)'):format(n, quoted(raw)))
    add(bar)
    add(('  br_season IS %s, WHICH IS NOT A SEASON (a whole'):format(quoted(raw)))
    add(('  number from 1), so this server runs Season %d, the newest'):format(n))
    add('  this code knows. Fix the line in server.cfg and restart.')
    add(bar)
    return L
end

--- br_core's server, once, as it starts: read br_season, hold the answer,
--- replicate it as br_seasonServed, and hand back the boot banner's lines.
---
--- RETURNS THE LINES RATHER THAN PRINTING THEM so server/main.lua prints them
--- in its banner, beside devMode, where an operator already looks.
---
--- Calling it again re-reads and re-latches. The game calls it once per
--- br_core start; the suites call it to put a server on a season.
--- @param get function|nil  (name, default) -> string; GetConvar by default
--- @param set function|nil  (name, value); SetConvarReplicated by default
--- @return string[] lines
function BR.Season.boot(get, set)
    get = get or GetConvar
    set = set or SetConvarReplicated
    local raw = get and get(BR.Season.CONVAR, '') or ''
    if type(raw) ~= 'string' then raw = '' end
    local n, why = BR.Season.resolve(raw)
    latched = { season = n, raw = raw }
    reported = false
    -- Guarded for the unit suites, which run without the Cfx runtime, as
    -- server/main.lua guards the dev-mode write.
    if set then set(BR.Season.SERVED, tostring(n)) end
    return banner(n, raw, why)
end

--- Has br_season changed since boot? The console line saying so, the first
--- time only; nil otherwise and on every state that never booted.
---
--- THE SEASON DOES NOT MOVE. The line says what was seen and what is still
--- running, so `set br_season 3` typed into a live console is not taken for a
--- change that happened.
--- @param get function|nil  GetConvar by default
--- @return string|nil
function BR.Season.recheck(get)
    if latched == nil or reported then return nil end
    get = get or GetConvar
    if not get then return nil end
    local raw = get(BR.Season.CONVAR, '')
    if type(raw) ~= 'string' then raw = '' end
    if raw == latched.raw then return nil end
    reported = true
    return ('[br_core] br_season is now %s; this server keeps running Season %d until br_core restarts.')
        :format(quoted(raw), latched.season)
end

--- The season this machine is running.
---
--- On br_core's server after boot, the season it booted with. Everywhere else,
--- br_seasonServed read now (see the header).
--- @return integer
function BR.Season.current()
    if latched then return latched.season end
    local raw = GetConvar and GetConvar(BR.Season.SERVED, '') or ''
    return (BR.Season.resolve(raw))
end

--- Is this feature on, in the season this machine is running?
---
--- On when `from` <= season, and season < `untilSeason` if the row has one.
--- AN ID WITH NO ROW IS OFF, and the console is told once: a door that asks
--- about a feature nobody listed is a typo, and a typo must close a door rather
--- than open it. Under BR.Season.strict (the suites) it raises instead.
--- A row whose numbers are not whole numbers is off too.
--- @param id string  a key of BR.Config.Seasons.features, written as a literal
--- @return boolean
function BR.Season.has(id)
    local cfg = BR.Config and BR.Config.Seasons
    local feats = type(cfg) == 'table' and cfg.features or nil
    local row = (type(feats) == 'table' and id ~= nil) and feats[id] or nil
    if type(row) ~= 'table' then
        if BR.Season.strict then
            error(('BR.Season.has: no feature %q in br_lib/config/seasons.lua'):format(tostring(id)), 2)
        end
        local key = tostring(id)
        if not unknownSeen[key] then
            unknownSeen[key] = true
            print(('[br_lib] BR.Season.has(%q): no such feature in br_lib/config/seasons.lua -- treated as off')
                :format(key))
        end
        return false
    end
    local s = BR.Season.current()
    local from, till = row.from, row.untilSeason
    if math.type(from) ~= 'integer' or s < from then return false end
    if till ~= nil and (math.type(till) ~= 'integer' or s >= till) then return false end
    return true
end

--- The version for this season: the entry with the highest key at or below the
--- season this machine is running, or nil when every key is above it.
---
---   local spawnDelayMs = BR.Season.pick({ [1] = 3000, [3] = 1500 })
---   BR.Season.pick({ [1] = oldScore, [3] = newScore })(kills, place)
---
--- Keys are seasons: whole numbers from 1. Any other key is ignored in game and
--- raises under BR.Season.strict. Asked where the value is used, never at file
--- load and kept (see the header).
--- @param versions table  { [season] = value }
--- @return any
function BR.Season.pick(versions)
    if type(versions) ~= 'table' then
        if BR.Season.strict then error('BR.Season.pick: wants { [season] = value }', 2) end
        return nil
    end
    local s = BR.Season.current()
    local bestK, best = nil, nil
    for k, v in pairs(versions) do
        if math.type(k) == 'integer' and k >= 1 then
            if k <= s and (bestK == nil or k > bestK) then bestK, best = k, v end
        elseif BR.Season.strict then
            error(('BR.Season.pick: key %s is not a season (a whole number from 1)'):format(tostring(k)), 2)
        end
    end
    return best
end
