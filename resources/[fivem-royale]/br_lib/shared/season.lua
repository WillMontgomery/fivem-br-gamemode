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
-- br_seasonServed is written only here -- by boot, and by switch() below -- and
-- only with the number the server is actually running. Nobody types it, so
-- nothing but a br_core start or the dev-mode `brseason` can move it.
--
-- ═══ ON A DEV BOX, `brseason` MOVES IT WITHOUT A RESTART ═══
--
-- Owner, 2026-10-04: "Please add the devmode command. That was my only real
-- intended use case for faster-than-restart switching." br_core/server/season.lua
-- owns the command and its timing rule (never mid-match); switch() is the one
-- write it makes, here, because this file holds the latch. It moves the season
-- in force and br_seasonServed together and nothing else: br_season is not
-- touched, so the next br_core start reads it as it always did. Prod is
-- restart-only because the command is a dev command (br_lib/shared/devgate.lua);
-- this file still reads no dev mode.
--
-- ═══ AND ONE FEATURE AT A TIME, UNDER br_seasonFeatures (#425) ═══
--
-- Owner, 2026-11-01: "can you also dispatch a way for me to turn on locker v2
-- in season 1 with a dev command?" `brseason locker2 on` sets one row on
-- whatever the season, `off` off whatever it, and `auto` hands it back to the
-- season, as `brfestive auto` hands the festive months back to the date.
-- setFeature() is the one write, here beside switch(), and only
-- br_core/server/season.lua calls it (verify.sh's `season gates`, S7).
-- br_core's server holds the settings in its latch, in memory, and replicates
-- them as br_seasonFeatures under br_seasonServed's rule: written only here --
-- by boot, EMPTY, so a setting from an earlier br_core run on the same
-- FXServer never outlives a restart, and by setFeature() -- and typed by
-- nobody. A switch() keeps them.
--
-- has() asks a setting only AFTER its own checks: an id with no row is still
-- off, a row whose numbers are not whole numbers is still off, and an unknown
-- season still shuts every gate, setting or not. On a box where nobody typed
-- the command -- prod included -- there is no setting, and every answer is the
-- season's, as it always was.
--
-- ═══ EVERYWHERE ELSE IT IS LATCHED TOO, AND FOLLOWS THE CONVAR ═══
--
-- A client, and any server state that is not br_core's, never boots. It used
-- to read br_seasonServed on every question, which made every has() a native
-- call -- the emote wheel asked sixty times a second. Owner, 2026-10-04:
-- "let's also be efficient in how we're checking. That could turn out to be a
-- lot of repeated checks." So it holds the value too, read once as this file
-- loads and AGAIN ONLY WHEN IT CHANGES -- and the settings beside it, under
-- the same rules, so every client and resource answers what the server does:
--
--   * AddConvarChangeListener (Cfx, apiset shared; added to FiveM 2024-10-13,
--     citizen-scripting-core's ConsoleScriptFunctions.cpp), one on each name.
--     It hangs off the variable manager's OnConvarModified, which every
--     change of value raises. A client's replicated convars arrive as `setr`
--     (msgConVars), and one the server creates on this client is made empty
--     and then set, so the value is re-read the moment it lands -- the first
--     arrival and every `brseason` after it.
--   * `br:season:changed`, which br_core's client raises once its own copy
--     has moved. Every resource that loads this file re-reads on it BEFORE its
--     own handlers run (this file loads first), so br_ui's Market never asks a
--     copy that br_core's listener beat it to.
--   * BR.Season.expect(n, settings), on br_core's SEASON_SWITCHED and
--     SEASON_FEATURE.
--   * A runtime without the listener re-reads every POLL_MS until a season
--     arrives, and after expect() until the announced season and settings
--     do -- POLL_TRIES times at most either way -- and nowhere else.
--
-- Every re-read takes both names, and onChange's followers hear either move.
--
-- So has() is a few table reads wherever it is asked, and the rule above
-- still holds: NOTHING may call has() or pick() while a file loads and keep
-- the answer. A copy taken at load would be wrong for the life of the process
-- once the season moves; this one is not, because it moves with it. A file
-- that keeps a derived answer of its own follows BR.Season.onChange.
--
-- ═══ UNTIL IT ARRIVES, THE SEASON IS UNKNOWN, AND EVERY GATE IS SHUT ═══
--
-- `latest` is the SERVER's answer to an unset br_season, decided once at boot.
-- It is not a client's answer to a convar that has not landed yet: a Season 1
-- client that guessed `latest` would open Season 2's doors until the server's
-- 1 arrived, and one of those doors -- the emote wheel's RegisterKeyMapping --
-- can never be shut again. So where nothing is booted, an unset or garbled
-- br_seasonServed is UNKNOWN: current() returns nil, has() answers false for
-- every row and pick() answers nil. The value landing moves the copy above,
-- and the gate passes that ask on a timer pick it up on their next pass.
-- br_core's server latches in onResourceStart, before any handler or job can
-- ask, so it never sees the unknown answer.
--
-- ═══ THE CLIENT DECIDES NOTHING A PLAYER COULD CHEAT ═══
--
-- A client's answer drives what it SHOWS and what it bothers to ask for. Every
-- door a modified client could walk through asks again on the server, which
-- holds the season in force and never reads a client's word for it.
--
-- ═══ DEV MODE IS SEPARATE ═══
--
-- Dev mode is tooling: who may type which console command. Seasons are content.
-- Nothing here reads dev mode, and nothing in devgate.lua reads the season.

BR = BR or {}
BR.Season = BR.Season or {}

--- What the operator sets in server.cfg. Read by boot() and recheck() only.
BR.Season.CONVAR = 'br_season'
--- What boot() and switch() replicate: the season the server is running.
BR.Season.SERVED = 'br_seasonServed'
--- What boot() and setFeature() replicate: every feature `brseason` has set on
--- or off whatever the season, as `<id>=on` or `<id>=off`, sorted by id and
--- joined by commas. Empty while none is.
BR.Season.FEATURES = 'br_seasonFeatures'

--- THE TESTS' SWITCH. With it on, has() of an id with no row and pick() of a
--- key that is not a season RAISE instead of answering. Off in game, where an
--- unknown id is off (fails closed) and says so once in the console.
if BR.Season.strict == nil then BR.Season.strict = false end

--- The highest season a convar may name. Far past any real one; it is here so
--- a number too long to be an integer is refused rather than rounded.
local MAX = 9999

--- br_core's server only, from boot() on: { season, raw, why, boot, set }.
--- `season` is the season in force; `boot` the one br_core started on, which
--- `season` leaves only through switch(); `set` the feature settings, moved
--- only by setFeature().
local latched = nil
--- recheck() has already reported a change.
local reported = false
--- has() ids already reported as unknown, so a door asked every frame prints once.
local unknownSeen = {}

--- Every state that never boots: br_seasonServed as last read, parsed -- nil
--- while it holds no season. Moved only by refresh().
local served = nil
--- The feature settings has() answers on this state, [id] = true (on whatever
--- the season) or false (off whatever it); a row not in it follows its season.
--- br_core's latch's from boot() on, and on every state that never boots
--- br_seasonFeatures as last read. Moved only by boot(), setFeature() and
--- refresh().
local settings = {}
--- Every state that never boots: br_seasonFeatures as last read, spelled the
--- one way (encodeSet), so a move is a change of text.
local servedSet = ''
--- How this state hears br_seasonServed move: 'listener' or 'poll'.
local follows = nil
--- 'poll' only: the season a SEASON_SWITCHED said is on its way, or nil.
local awaiting = nil
--- 'poll' only: the settings a SEASON_FEATURE said are on their way, spelled
--- the one way, or nil.
local awaitingSet = nil
--- 'poll' only: a re-read thread is running.
local polling = false
--- onChange()'s functions, called in order with (now, before).
local watchers = {}

--- A runtime without AddConvarChangeListener re-reads this often while it is
--- waiting for a season ...
local POLL_MS = 500
--- ... this many times at most (two minutes) per wait: a first arrival, or the
--- one a SEASON_SWITCHED announced. Bounded, so a value that never comes costs
--- two minutes of one read a half-second and then nothing.
local POLL_TRIES = 240

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

--- Feature settings as br_seasonFeatures holds them: `<id>=on` or `<id>=off`,
--- sorted by id and joined by commas, '' for none. THE ONE SPELLING, so a
--- move is a change of text and a SEASON_FEATURE's settings compare as text.
--- Anything but a plain id set to a boolean is left out.
--- @param t table  [id] = boolean
--- @return string
local function encodeSet(t)
    local ids = {}
    for id, v in pairs(t) do
        if type(id) == 'string' and id:match('^[%a_][%w_]*$') and type(v) == 'boolean' then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for i, id in ipairs(ids) do ids[i] = id .. (t[id] and '=on' or '=off') end
    return table.concat(ids, ',')
end

--- br_seasonFeatures' text, read: [id] = boolean. AN ENTRY THAT IS NOT
--- `<id>=on` OR `<id>=off` IS SKIPPED, so that feature follows its season --
--- what every box runs when nobody typed the command.
--- @param raw any
--- @return table
local function parseSet(raw)
    local t = {}
    if type(raw) ~= 'string' then return t end
    for part in raw:gmatch('[^,]+') do
        local id, v = part:match('^%s*([%a_][%w_]*)=(%a+)%s*$')
        if v == 'on' then t[id] = true elseif v == 'off' then t[id] = false end
    end
    return t
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
--- No feature setting survives it: the latch starts with none, and
--- br_seasonFeatures is written empty.
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
    latched = { season = n, raw = raw, why = why, boot = n, set = {} }
    settings = latched.set
    reported = false
    -- Guarded for the unit suites, which run without the Cfx runtime, as
    -- server/main.lua guards the dev-mode write.
    if set then
        set(BR.Season.SERVED, tostring(n))
        -- EMPTY ON EVERY START: a replicated value outlives the resource that
        -- wrote it, and a setting from the last br_core run must not.
        set(BR.Season.FEATURES, '')
    end
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

--- The newest season this code knows: `latest` in br_lib/config/seasons.lua,
--- or 1 when the registry is missing or malformed. `brseason` names its bounds
--- with it.
--- @return integer
function BR.Season.latest()
    return latest()
end

--- br_core's server only: the season br_core started on, which `brseason
--- reset` goes back to. nil on every state that never booted.
--- @return integer|nil
function BR.Season.startup()
    return latched and latched.boot or nil
end

--- br_core's server only: where the season in force came from, for brseason's
--- status line. nil on every state that never booted.
---
---   'convar'    br_season named it as br_core started
---   'latest'    br_season was unset or not a season, so the latest
---   'override'  `brseason` moved it off the season br_core started on
---
--- The second return says so in words, quoting br_season the way the boot
--- banner does -- here, because no other file may name the convar.
--- @return string|nil source
--- @return string|nil words
function BR.Season.origin()
    if latched == nil then return nil, nil end
    local started
    if latched.why == nil then
        started = ('br_season %d'):format(latched.boot)
    elseif latched.why == 'unset' then
        started = 'br_season is not set: the latest'
    else
        started = ('br_season %s is not a season: the latest'):format(quoted(latched.raw))
    end
    if latched.season ~= latched.boot then
        return 'override', ('brseason override; br_core started on Season %d (%s)'):format(latched.boot, started)
    end
    return latched.why == nil and 'convar' or 'latest', started
end

--- br_core's server only, for `brseason` (br_core/server/season.lua): put the
--- season in force to `n`, or back to the one br_core started on when `n` is
--- nil, and replicate it as br_seasonServed, exactly as boot() did.
---
--- THE TIMING IS THE CALLER'S. This moves the latch the moment it is called;
--- br_core/server/season.lua is what holds a switch until no match is running.
--- A season is a whole number from 1 to `latest` -- the startup season is
--- taken back whatever it was, since br_core already chose to run it.
--- @param n integer|nil
--- @param set function|nil  (name, value); SetConvarReplicated by default
--- @return integer|nil season  the season now in force, or nil
--- @return string|nil why      'not booted' or 'not a season'
function BR.Season.switch(n, set)
    if latched == nil then return nil, 'not booted' end
    if n == nil then
        n = latched.boot
    elseif math.type(n) ~= 'integer' or n < 1 or n > latest() then
        return nil, 'not a season'
    end
    set = set or SetConvarReplicated
    latched.season = n
    if set then set(BR.Season.SERVED, tostring(n)) end
    return n, nil
end

--- br_core's server only, for `brseason <id> on|off|auto`
--- (br_core/server/season.lua): feature `id` on (true) or off (false) whatever
--- the season, or following it again (nil), and every setting replicated as
--- br_seasonFeatures, as switch() replicates the season.
---
--- THE TIMING IS THE CALLER'S, as switch()'s is, and so is the choice of
--- feature: any row may be set here, and `brseason` keeps its own short list
--- of the ones it offers. A switch() leaves every setting where it is.
--- @param id string  a row of br_lib/config/seasons.lua
--- @param on boolean|nil
--- @param set function|nil  (name, value); SetConvarReplicated by default
--- @return boolean|nil ok
--- @return string|nil why  'not booted', 'no such feature' or 'not a setting'
function BR.Season.setFeature(id, on, set)
    if latched == nil then return nil, 'not booted' end
    local cfg = BR.Config and BR.Config.Seasons
    local feats = type(cfg) == 'table' and cfg.features or nil
    if type(id) ~= 'string' or not id:match('^[%a_][%w_]*$') or type(feats) ~= 'table'
       or type(feats[id]) ~= 'table' then
        return nil, 'no such feature'
    end
    if on ~= nil and type(on) ~= 'boolean' then return nil, 'not a setting' end
    set = set or SetConvarReplicated
    latched.set[id] = on
    if set then set(BR.Season.FEATURES, encodeSet(latched.set)) end
    return true, nil
end

--- The feature settings this state answers has() with, copied: [id] = true
--- (on whatever the season) or false (off whatever it); a row not in it
--- follows its season. br_core's server reads its latch, every other state
--- br_seasonFeatures as it last read it. For `brseason`'s status lines and
--- the suites -- a door asks has().
--- @return table
function BR.Season.settings()
    local out = {}
    for id, v in pairs(settings) do out[id] = v end
    return out
end

--- The season this machine is running, or nil while it is not known.
---
--- On br_core's server after boot, the season in force: the one it booted
--- with, or the one `brseason` switched it to since. Everywhere else,
--- br_seasonServed as this state last read it -- which follows every change
--- (see the header) -- and NIL until it holds a season: a client before the
--- server's answer arrives. Every caller copes with nil.
---
--- TABLE READS, NEVER A NATIVE: this is asked from per-frame passes.
--- @return integer|nil
function BR.Season.current()
    if latched then return latched.season end
    return served
end

--- Read br_seasonServed and br_seasonFeatures again, now, and move this
--- state's copies if either moved.
---
--- What the listeners, `br:season:changed`, expect() and the fallback re-read
--- call; nothing else needs to. A no-op on br_core's server, which answers
--- its own latch. Every onChange() function is told of a move, the first
--- arrival included, in the order they asked -- and one that raises does not
--- keep the rest from hearing it. A move of the settings alone is told with
--- the season unchanged: (now, before) the same.
--- @return integer|nil  the season this state now runs
function BR.Season.refresh()
    if latched then return latched.season end
    local raw = GetConvar and GetConvar(BR.Season.SERVED, '') or ''
    local now = (BR.Season.parse(raw))
    local set = parseSet(GetConvar and GetConvar(BR.Season.FEATURES, '') or '')
    local text = encodeSet(set)
    if awaiting ~= nil and now == awaiting then awaiting = nil end
    if awaitingSet ~= nil and text == awaitingSet then awaitingSet = nil end
    if now == served and text == servedSet then return served end
    local before = served
    served = now
    if text ~= servedSet then servedSet, settings = text, set end
    local failed = nil
    for i = 1, #watchers do
        local okW, err = pcall(watchers[i], now, before)
        if not okW then
            print(('[br_lib] BR.Season.onChange: a follower raised -- %s'):format(tostring(err)))
            failed = failed or err
        end
    end
    -- The suites hear it as a failure rather than a console line.
    if failed ~= nil and BR.Season.strict then error(failed, 0) end
    return served
end

--- Be told when this state's season moves: fn(now, before), either of which
--- may be nil (not known). For a file that keeps an answer DERIVED from the
--- season -- client/loot.lua's crate bodies, client/season.lua's
--- `br:season:changed` -- so it re-derives once per move instead of asking per
--- frame. A move of the feature settings alone (#425) is told too, with `now`
--- and `before` the same season: a follower asks has() again, it never keys
--- an answer on the number. Never called on br_core's server, whose season
--- moves only by boot() or switch(), and whose followers are named in
--- br_core/server/season.lua.
--- @param fn function
function BR.Season.onChange(fn)
    if type(fn) == 'function' then watchers[#watchers + 1] = fn end
end

--- The re-read a runtime without the listener falls back to: every POLL_MS
--- while no season is known, or while an announced season or settings have
--- not landed, for POLL_TRIES at most. One thread at a time.
local function poll()
    if polling or follows ~= 'poll' then return end
    if type(Citizen) ~= 'table' or type(Citizen.CreateThread) ~= 'function' then return end
    polling = true
    Citizen.CreateThread(function()
        local tries = 0
        while latched == nil and tries < POLL_TRIES
              and (served == nil or awaiting ~= nil or awaitingSet ~= nil) do
            Citizen.Wait(POLL_MS)
            BR.Season.refresh()
            tries = tries + 1
        end
        awaiting, awaitingSet = nil, nil
        polling = false
    end)
end

--- br_core's client, on SEASON_SWITCHED (`n`, the season on its way) and on
--- SEASON_FEATURE (`set`, every feature setting now in force, [id] = boolean).
--- Re-reads now; the values and the messages travel separately, so when a
--- value has not landed yet the listener will see it land -- and without one,
--- the fallback re-reads until it does. A message is never TAKEN as the
--- answer: what this machine runs is what br_seasonServed and
--- br_seasonFeatures say.
--- @param n integer|nil
--- @param set table|nil
function BR.Season.expect(n, set)
    if latched then return end
    BR.Season.refresh()
    if follows ~= 'poll' then return end
    local wait = false
    if math.type(n) == 'integer' and served ~= n then
        awaiting = n
        wait = true
    end
    if type(set) == 'table' then
        local want = encodeSet(set)
        if want ~= servedSet then
            awaitingSet = want
            wait = true
        end
    end
    if wait then poll() end
end

--- How this state follows br_seasonServed: 'listener', 'poll', or nil on a
--- state that has booted. For /brloot-style readouts and the suites.
--- @return string|nil
function BR.Season.follows()
    if latched then return nil end
    return follows
end

--- Is this feature on, in the season this machine is running?
---
--- On when `from` <= season, and season < `untilSeason` if the row has one.
--- AN ID WITH NO ROW IS OFF, and the console is told once: a door that asks
--- about a feature nobody listed is a typo, and a typo must close a door rather
--- than open it. Under BR.Season.strict (the suites) it raises instead.
--- A row whose numbers are not whole numbers is off too, and EVERY row is off
--- while the season is unknown (current() is nil). Past those checks, and only
--- past them, a `brseason <id> on|off` setting answers ahead of the season
--- (#425).
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
    if s == nil then return false end
    local from, till = row.from, row.untilSeason
    -- A SETTING IN FORCE IS THE ANSWER, on or off whatever the season -- for a
    -- row whose numbers are whole numbers. With none, the two lines below it
    -- are the whole answer, as they always were.
    local forced = settings[id]
    if forced ~= nil then
        if math.type(from) ~= 'integer' or (till ~= nil and math.type(till) ~= 'integer') then return false end
        return forced
    end
    if math.type(from) ~= 'integer' or s < from then return false end
    if till ~= nil and (math.type(till) ~= 'integer' or s >= till) then return false end
    return true
end

--- The version for this season: the entry with the highest key at or below the
--- season this machine is running, or nil when every key is above it -- and
--- nil while the season is unknown, which a client-side caller must cope with.
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
            if s ~= nil and k <= s and (bestK == nil or k > bestK) then bestK, best = k, v end
        elseif BR.Season.strict then
            error(('BR.Season.pick: key %s is not a season (a whole number from 1)'):format(tostring(k)), 2)
        end
    end
    return best
end

-- ═══ FOLLOWING BOTH NAMES, FROM THE MOMENT THIS FILE LOADS ═══
--
-- Read once now, then again only when one moves (the header). Every state
-- wires the same way, br_core's server included, harmlessly: it boots in
-- onResourceStart and answers its own latch from then on, and refresh() hands
-- that back without reading anything.
BR.Season.refresh()
-- GUARDED: a listener that will not register must leave the re-read behind it,
-- not take this file -- and every season gate -- down at load. Either name
-- refused is the re-read for both.
local function listen(name)
    return pcall(AddConvarChangeListener, name, function() BR.Season.refresh() end)
end
if type(AddConvarChangeListener) == 'function' and listen(BR.Season.SERVED) and listen(BR.Season.FEATURES) then
    follows = 'listener'
else
    follows = 'poll'
    poll()
end
-- br_core's client raises it once its own copy has moved, and this handler is
-- registered before any of this resource's own (this file loads first), so
-- they all ask a copy that has already moved.
if type(AddEventHandler) == 'function' then
    AddEventHandler('br:season:changed', function() BR.Season.refresh() end)
end
