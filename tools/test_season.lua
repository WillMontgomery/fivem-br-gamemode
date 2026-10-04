-- Unit tests for seasons (#388): br_lib/shared/season.lua, the one list in
-- br_lib/config/seasons.lua, and the dev-mode label that shows the season.
--
-- Owner, 2026-10-04: "we should gate our functions (or versions of them) by a
-- server convar (set at startup) for which season the server should be
-- running ... This is how we can run season 3 on dev and season 2 on prod with
-- the same codebase." His decisions: a season may remove a feature; an unset
-- convar runs the latest season with a warning in the console; and the season
-- shows next to the version label in the lobby, on dev.
--
-- ═══ WHAT IS WORTH TESTING ═══
--
-- EVERY WRONG ANSWER HERE IS A LEGAL ONE. A season read as 1 instead of 2 is a
-- server with emotes switched off and nothing in any log; an edge off by one is
-- a feature that arrives a season early on prod; a client that reads the
-- operator's convar instead of the server's answer shows a Market tab the
-- server refuses. None of it errors, so all of it is pinned here: the parse and
-- its fallback and the banner that says so, has() and pick() at every edge,
-- the unknown id, the change that is seen and ignored, and the season crossing
-- from a server state to a client state as the game carries it.
--
-- SEPARATE LUA ENVIRONMENTS FOR SERVER AND CLIENT. The module keeps the season
-- it booted with in a file local, exactly as each resource's Lua state would.
-- So the replication block loads it twice, into a "server" and a "client",
-- with one table between them standing in for the replicated convars.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_season.lua

local RES = 'resources/[fivem-royale]/'
local MODULE = RES .. 'br_lib/shared/season.lua'
local REGISTRY = RES .. 'br_lib/config/seasons.lua'

local realPrint = print

-- ---------------------------------------------------------------- harness ---

local pass, fail = 0, 0
local group = ''

local function describe(name) group = name end

local function ok(cond, name, detail)
    if cond then
        pass = pass + 1
    else
        fail = fail + 1
        realPrint(('\27[31mFAIL\27[0m %s > %s%s'):format(group, name,
            detail ~= nil and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

--- A Lua state of its own: the module (and the real registry, unless a fake is
--- handed in) loaded into a fresh environment whose convars, replication and
--- console are tables this suite can read.
--- @param o table|nil  { cfg = { [name] = value }, wire = table, registry = table }
local function state(o)
    o = o or {}
    local st = {
        cfg = o.cfg or {},          -- this state's own convars (server.cfg on a server)
        wire = o.wire or {},        -- what replication carries (shared server <-> client)
        printed = {},
    }
    local env = setmetatable({}, { __index = _G })
    env.BR = {}
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        st.printed[#st.printed + 1] = table.concat(parts, '\t')
    end
    -- A convar this state set itself wins; otherwise what replication brought.
    env.GetConvar = function(name, default)
        if st.cfg[name] ~= nil then return st.cfg[name] end
        if st.wire[name] ~= nil then return st.wire[name] end
        return default
    end
    env.SetConvarReplicated = function(name, value) st.wire[name] = value end
    assert(loadfile(MODULE, 't', env))()
    if o.registry then
        env.BR.Config = { Seasons = o.registry }
    else
        assert(loadfile(REGISTRY, 't', env))()
    end
    st.env = env
    st.S = env.BR.Season
    return st
end

local LATEST = state().env.BR.Config.Seasons.latest

-- =========================================================================
-- the parse
-- =========================================================================

describe('season.parse')
do
    local P = state().S.parse
    for raw, want in pairs({
        ['1'] = 1, ['2'] = 2, ['3'] = 3, ['12'] = 12, ['9999'] = 9999,
        ['02'] = 2, [' 2 '] = 2, ['2\n'] = 2, ['\t3'] = 3,
    }) do
        eq(P(raw), want, ('%q is Season %d'):format(raw, want))
    end
    for _, raw in ipairs({
        '0', '00', '-1', '+2', '1.5', '2.0', '1e1', '0x2', 'two', 'S2', '2a', '2 3',
        '10000', '99999999999999999999999', 'true',
    }) do
        local n, why = P(raw)
        ok(n == nil and why == 'not a season', ('%q is not a season'):format(raw),
            ('got %s, %s'):format(tostring(n), tostring(why)))
    end
    for _, raw in ipairs({ '', '   ' }) do
        local n, why = P(raw)
        ok(n == nil and why == 'unset', ('%q is unset'):format(raw), tostring(why))
    end
    local n, why = P(nil)
    ok(n == nil and why == 'unset', 'nil is unset', tostring(why))
    n, why = P(2)
    ok(n == nil and why == 'unset', 'a number that is not a convar string is not read as one', tostring(why))
end

describe('season.resolve')
do
    local S = state().S
    local n, why = S.resolve('1')
    ok(n == 1 and why == nil, 'a season resolves to itself, with no reason')
    n, why = S.resolve('')
    ok(n == LATEST and why == 'unset', 'unset resolves to the latest, and says unset', n)
    n, why = S.resolve('abc')
    ok(n == LATEST and why == 'not a season', 'garbage resolves to the latest, and says so', n)
    n, why = S.resolve(tostring(LATEST + 5))
    ok(n == LATEST + 5 and why == nil, 'a season past the latest is still the season named', n)
end

-- =========================================================================
-- boot: read once, replicate, and the banner
-- =========================================================================

describe('season.boot')
do
    -- SET: one line, no banner.
    local st = state({ cfg = { br_season = '1' } })
    local lines = st.S.boot()
    eq(st.S.current(), 1, 'br_season 1 boots Season 1')
    eq(st.wire.br_seasonServed, '1', 'and replicates it as br_seasonServed')
    eq(st.wire.br_season, nil, 'and never writes br_season itself')
    eq(#lines, 1, 'a set season is one banner line')
    eq(lines[1], '[br_core]   season       1 (br_season)', 'naming the season and where it came from')
    eq(#st.printed, 0, 'boot prints nothing itself -- server/main.lua prints its lines')

    -- UNSET: the latest, and the warning (owner: "assume the latest and
    -- warning in the console").
    st = state()
    lines = st.S.boot()
    eq(st.S.current(), LATEST, 'unset boots the latest season')
    eq(st.wire.br_seasonServed, tostring(LATEST), 'and replicates the latest')
    eq(lines[1], ('[br_core]   season       %d (br_season is not set: the latest)'):format(LATEST),
        'the first line says it was not set')
    local all = table.concat(lines, '\n')
    ok(all:find('br_season IS NOT SET', 1, true) ~= nil, 'the banner says so in capitals', all)
    ok(all:find('set br_season <n>', 1, true) ~= nil, 'and gives the line to add', all)
    ok(all:find('above `ensure br_core`', 1, true) ~= nil, 'and where it goes', all)
    local bars = 0
    for _, l in ipairs(lines) do
        ok(l:sub(1, 10) == '[br_core] ', 'every line carries the resource tag', l)
        if l:find('######', 1, true) then bars = bars + 1 end
    end
    eq(bars, 2, 'the warning is boxed, top and bottom')

    -- EMPTY STRING is unset too, which is what `set br_season ""` leaves.
    st = state({ cfg = { br_season = '' } })
    lines = st.S.boot()
    ok(st.S.current() == LATEST and table.concat(lines, '\n'):find('NOT SET', 1, true) ~= nil,
        'an empty br_season is unset')

    -- NOT A SEASON: the latest, and the value quoted.
    st = state({ cfg = { br_season = 'two' } })
    lines = st.S.boot()
    eq(st.S.current(), LATEST, 'garbage boots the latest season')
    eq(lines[1], ('[br_core]   season       %d (br_season "two" is not a season: the latest)'):format(LATEST),
        'the first line quotes what was set')
    all = table.concat(lines, '\n')
    ok(all:find('WHICH IS NOT A SEASON', 1, true) ~= nil and all:find('Fix the line', 1, true) ~= nil,
        'and the banner says what is wrong and what to do', all)

    st = state({ cfg = { br_season = '0' } })
    st.S.boot()
    eq(st.S.current(), LATEST, 'Season 0 is not a season either')

    -- A HOSTILE OR HUGE VALUE is quoted safely and short.
    st = state({ cfg = { br_season = '1\27[2J' .. string.rep('x', 100) } })
    lines = st.S.boot()
    ok(not table.concat(lines):find('\27', 1, true), 'a control character never reaches the console', lines[1])
    ok(#lines[1] < 120 and lines[1]:find('...', 1, true) ~= nil, 'and a long value is cut short', lines[1])

    -- PAST THE LATEST: honored, and flagged.
    st = state({ cfg = { br_season = tostring(LATEST + 1) } })
    lines = st.S.boot()
    eq(st.S.current(), LATEST + 1, 'a season past the latest runs as itself')
    ok(lines[1]:find(('this code knows Seasons 1 to %d'):format(LATEST), 1, true) ~= nil,
        'and the line says how far this code goes', lines[1])
    ok(table.concat(lines, '\n'):find('PAST SEASON', 1, true) ~= nil, 'with a banner')

    -- NO RUNTIME: the unit suites boot without GetConvar or SetConvarReplicated.
    st = state()
    st.env.GetConvar, st.env.SetConvarReplicated = nil, nil
    local okBoot, res = pcall(st.S.boot)
    ok(okBoot and st.S.current() == LATEST, 'boot with no Cfx runtime runs the latest and does not raise', res)

    -- THE READERS CAN BE HANDED IN, which is how a suite boots a server.
    st = state()
    local wrote = {}
    st.S.boot(function(name) return name == 'br_season' and '1' or nil end,
              function(name, value) wrote[name] = value end)
    ok(st.S.current() == 1 and wrote.br_seasonServed == '1', 'boot(get, set) reads and writes through them')
end

-- =========================================================================
-- the change that is seen and ignored
-- =========================================================================

describe('season.recheck')
do
    local st = state({ cfg = { br_season = '2' } })
    eq(st.S.recheck(), nil, 'a state that never booted has nothing to report')
    st.S.boot()
    eq(st.S.recheck(), nil, 'unchanged: nothing')
    st.cfg.br_season = '1'
    local line = st.S.recheck()
    eq(line, '[br_core] br_season is now "1"; this server keeps running Season 2 until br_core restarts.',
        'changed: one line saying what was seen and what still runs')
    eq(st.S.current(), 2, 'and the season did not move')
    ok(st.S.has('emotes') == true, 'nor did a door')
    eq(st.wire.br_seasonServed, '2', 'nor what the clients were told')
    eq(st.S.recheck(), nil, 'ONCE: the next check says nothing')
    st.cfg.br_season = '3'
    eq(st.S.recheck(), nil, 'not even for a second change')

    -- A NEW BOOT is a new start: it reads the new value and watches again.
    st.S.boot()
    eq(st.S.current(), 3, 'the next br_core start reads the new value')
    eq(st.S.recheck(), nil, 'and has nothing to report')
    st.cfg.br_season = nil
    ok(st.S.recheck() ~= nil, 'a value removed after boot is a change too')

    -- An unset box that gets a value typed in is seen as well.
    st = state()
    st.S.boot()
    st.cfg.br_season = '1'
    ok(st.S.recheck() ~= nil and st.S.current() == LATEST, 'unset then set: seen, and ignored')
end

-- =========================================================================
-- has(): every edge, removal, and the malformed
-- =========================================================================

describe('season.has')
do
    local reg = {
        latest = 4,
        features = {
            fromTwo   = { from = 2 },
            removed   = { from = 1, untilSeason = 3 },       -- "a season would remove a feature"
            window    = { from = 3, untilSeason = 4 },       -- one season only
            floatFrom = { from = 2.0 },
            floatTill = { from = 1, untilSeason = 3.0 },
            noFrom    = { untilSeason = 3 },
            textTill  = { from = 1, untilSeason = 'x' },
        },
    }
    local want = {
        fromTwo   = { false, true,  true,  true,  true },
        removed   = { true,  true,  false, false, false },
        window    = { false, false, true,  false, false },
        floatFrom = { false, false, false, false, false },
        floatTill = { false, false, false, false, false },
        noFrom    = { false, false, false, false, false },
        textTill  = { false, false, false, false, false },
    }
    for season = 1, 5 do
        local st = state({ registry = reg, cfg = { br_season = tostring(season) } })
        st.S.boot()
        for id, row in pairs(want) do
            eq(st.S.has(id), row[season], ('Season %d: %s'):format(season, id))
        end
    end

    -- THE REAL LIST: emotes are Season 2 and later (owner, 2026-10-04).
    for season, on in ipairs({ false, true, true }) do
        local st = state({ cfg = { br_season = tostring(season) } })
        st.S.boot()
        eq(st.S.has('emotes'), on, ('the real list: emotes at Season %d'):format(season))
    end
    local st = state()
    st.S.boot()
    eq(st.S.has('emotes'), true, 'the real list: emotes on an unset box (the latest)')
end

describe('season.unknown')
do
    local st = state({ cfg = { br_season = '2' } })
    st.S.boot()
    eq(st.S.has('emote'), false, 'an id with no row is off')
    eq(#st.printed, 1, 'and the console is told')
    ok(st.printed[1] and st.printed[1]:find('"emote"', 1, true) ~= nil
        and st.printed[1]:find('br_lib/config/seasons.lua', 1, true) ~= nil,
        'naming the id and the list', st.printed[1])
    eq(st.S.has('emote'), false, 'asked again, still off')
    eq(#st.printed, 1, 'ONCE: a door asked every frame does not flood the console')
    eq(st.S.has(nil), false, 'nil is off')
    eq(st.S.has(2), false, 'a number is off')
    eq(st.S.has({}), false, 'a table is off')

    -- STRICT, which every suite that asks has() switches on: a typo FAILS.
    st.S.strict = true
    local okHas, err = pcall(st.S.has, 'emote')
    ok(not okHas and tostring(err):find('no feature "emote"', 1, true) ~= nil,
        'under strict an unknown id raises, naming it', err)
    ok(pcall(st.S.has, 'emotes'), 'and a known one does not')

    -- NO LIST AT ALL: every id is off, nothing raises.
    st = state({ registry = 'not a table', cfg = { br_season = '2' } })
    st.S.boot()
    eq(st.S.has('emotes'), false, 'with no list loaded, even emotes are off')
    eq(st.S.current(), 2, 'and the season still parses')
    st = state({ registry = {}, cfg = {} })
    st.S.boot()
    eq(st.S.current(), 1, 'a list with no latest falls back to Season 1, the launch season')
end

-- =========================================================================
-- pick(): versions of a function or a value
-- =========================================================================

describe('season.pick')
do
    local function at(season)
        local st = state({ cfg = { br_season = tostring(season) } })
        st.S.boot()
        return st
    end
    local V = { [1] = 'one', [3] = 'three' }
    eq(at(1).S.pick(V), 'one', 'Season 1 takes [1]')
    eq(at(2).S.pick(V), 'one', 'Season 2 takes [1]: the newest at or below')
    eq(at(3).S.pick(V), 'three', 'Season 3 takes [3]')
    eq(at(9).S.pick(V), 'three', 'Season 9 takes [3]')
    eq(at(1).S.pick({ [2] = 'two' }), nil, 'nothing at or below the season is nil')
    eq(at(2).S.pick({}), nil, 'an empty table is nil')
    eq(at(2).S.pick({ [1] = false, [3] = true }), false, 'false is a value like any other')

    local fn = at(3).S.pick({ [1] = function(x) return x + 1 end, [3] = function(x) return x * 10 end })
    eq(fn(4), 40, 'a version of a function is called like one')

    -- NOT SEASONS: ignored in game, raised under strict.
    local st = at(3)
    eq(st.S.pick({ [1] = 'one', [2.5] = 'x', ['3'] = 'string', [0] = 'zero', [-1] = 'neg' }), 'one',
        'a float, a string, 0 and a negative key are not seasons and are skipped')
    eq(st.S.pick({ [2.0] = 'float two' }), 'float two',
        'a float key that IS a whole number is stored as one by Lua, so it counts')
    eq(st.S.pick(nil), nil, 'a nil table is nil')
    st.S.strict = true
    ok(not pcall(st.S.pick, { [1] = 'one', ['2'] = 'two' }), 'under strict a string key raises')
    ok(not pcall(st.S.pick, { [0] = 'zero' }), 'under strict Season 0 raises')
    ok(not pcall(st.S.pick, 'x'), 'under strict a non-table raises')
    ok(pcall(st.S.pick, { [1] = 'a', [2] = 'b' }), 'and a good table does not')
end

-- =========================================================================
-- replication: the server's season reaches the client, and nothing else does
-- =========================================================================

describe('season.replication')
do
    local wire = {}
    local server = state({ cfg = { br_season = '1' }, wire = wire })
    local client = state({ wire = wire })

    -- BEFORE IT ARRIVES THE CLIENT DOES NOT KNOW, AND SAYS SO (#388): not the
    -- latest, which is the server's answer to an unset br_season and would
    -- open Season 2's doors on a Season 1 client until the 1 landed.
    eq(client.S.current(), nil, 'a client before the convar arrives has no season')
    eq(client.S.has('emotes'), false, 'and every gate is shut: no emotes')
    eq(client.S.pick({ [1] = 'one', [2] = 'two' }), nil, 'and pick() has no version to give')

    server.S.boot()
    eq(wire.br_seasonServed, '1', 'the server boots Season 1 and replicates it')
    eq(client.S.current(), 1, 'the client reads Season 1')
    ok(server.S.has('emotes') == false and client.S.has('emotes') == false,
        'both sides agree: no emotes in Season 1')

    -- THE CLIENT IS NEVER TOLD br_season, AND WOULD NOT LISTEN. An operator's
    -- `setr br_season 2` reaches every client; the server keeps its boot value,
    -- and so must they.
    wire.br_season = '2'
    eq(client.S.current(), 1, "a replicated br_season (the operator's setr) moves no client")
    server.cfg.br_season = '2'
    eq(server.S.current(), 1, 'and no server until br_core restarts')

    -- THE NEXT br_core START moves both.
    server.S.boot()
    eq(wire.br_seasonServed, '2', 'a restart replicates the new season')
    ok(server.S.has('emotes') == true and client.S.has('emotes') == true,
        'and both sides open emotes together')

    -- UNSET ON THE SERVER: the client is told the number, not the absence.
    server.cfg.br_season, wire.br_season = nil, nil
    server.S.boot()
    eq(wire.br_seasonServed, tostring(LATEST), 'an unset server replicates the latest as a number')
    eq(client.S.current(), LATEST, 'and the client runs it')

    -- GARBAGE ON THE WIRE (nobody writes it but boot, which writes a number):
    -- not a season the server sent, so the client still does not know one.
    wire.br_seasonServed = 'x'
    eq(client.S.current(), nil, 'a garbled br_seasonServed is no season')
    eq(client.S.has('emotes'), false, 'and shuts every gate')

    -- READ AT CALL TIME on the client, never held: a value that lands late
    -- is used as soon as it lands.
    wire.br_seasonServed = nil
    local before = client.S.current()
    wire.br_seasonServed = '1'
    ok(before == nil and client.S.current() == 1, 'the client never keeps a value from before it arrived')
    eq(client.S.recheck(), nil, 'a client never booted, so it never reports a change')

    -- THE SERVER IS UNTOUCHED BY ANY OF IT: it latched at boot.
    eq(server.S.current(), LATEST, 'the server still runs what it booted with')
end

describe('season.before-arrival')
do
    -- EVERY ROW IS SHUT while the season is unknown -- a launch feature, one a
    -- later season brings, and one a later season takes away -- and each
    -- opens exactly as its season says once the season lands.
    local reg = {
        latest = 3,
        features = {
            base    = { from = 1 },
            later   = { from = 2 },
            removed = { from = 1, untilSeason = 2 },
        },
    }
    local wire = {}
    local client = state({ registry = reg, wire = wire })
    for _, id in ipairs({ 'base', 'later', 'removed' }) do
        eq(client.S.has(id), false, ('no season yet: %s is shut'):format(id))
    end
    eq(client.S.pick({ [1] = 'one' }), nil, 'no season yet: not even a Season 1 version is picked')
    for _, raw in ipairs({ '', '  ', '0', 'two', '1.5' }) do
        wire.br_seasonServed = raw
        ok(client.S.current() == nil and client.S.has('base') == false,
            ('%q on the wire is no season, and shuts even a launch feature'):format(raw))
    end

    wire.br_seasonServed = '1'
    ok(client.S.has('base') and not client.S.has('later') and client.S.has('removed'),
        'Season 1 lands: the launch features open, the later one stays shut')
    eq(client.S.pick({ [1] = 'one', [2] = 'two' }), 'one', 'and pick() takes Season 1\'s version')
    wire.br_seasonServed = '2'
    ok(client.S.has('base') and client.S.has('later') and not client.S.has('removed'),
        'Season 2 lands: the later feature opens, the removed one shuts')

    -- STRICT STILL RAISES on a typo'd id, known season or not.
    wire.br_seasonServed = nil
    client.S.strict = true
    ok(not pcall(client.S.has, 'bse'), 'under strict an unknown id raises before the season arrives')
    ok(not pcall(client.S.pick, { ['1'] = 'x' }), 'and so does a key that is not a season')
end

-- =========================================================================
-- the registry as shipped
-- =========================================================================

describe('season.registry')
do
    local cfg = state().env.BR.Config.Seasons
    ok(math.type(cfg.latest) == 'integer' and cfg.latest >= 1, 'latest is a whole number from 1', cfg.latest)
    eq(cfg.latest, 2, 'latest is Season 2 (emotes are its first feature)')
    for id, row in pairs(cfg.features) do
        ok(math.type(row.from) == 'integer' and row.from >= 1 and row.from <= cfg.latest,
            id .. ': from is a season this code knows', row.from)
        ok(row.untilSeason == nil or (math.type(row.untilSeason) == 'integer' and row.untilSeason > row.from),
            id .. ': untilSeason, if any, is after from', row.untilSeason)
    end
    ok(cfg.features.emotes and cfg.features.emotes.from == 2 and cfg.features.emotes.untilSeason == nil,
        'emotes = { from = 2 } (owner, 2026-10-04: "Season 2+")')
end

-- =========================================================================
-- brseason (#388): the dev-mode switch, without a restart
-- =========================================================================
--
-- Owner, 2026-10-04: "Please add the devmode command. That was my only real
-- intended use case for faster-than-restart switching." `brseason <n>` puts a
-- season in force at once when no match is running; while one is, it is
-- STAGED and applied when the last match is torn down to the lobby -- never
-- mid-match. `reset` goes back to the season br_core started on. It is a dev
-- command, so a box without dev mode refuses it.
--
-- WHAT IS WORTH TESTING is the same as everywhere in this file: every wrong
-- answer is a legal one. A switch that lands mid-match changes the doors a
-- match is being played through and logs nothing; a staged switch that never
-- applies leaves the box on a season nobody asked for; a client that took the
-- season off the message rather than the replicated value runs a season the
-- server is not serving. So the module's one write, the command over
-- devgate's real wrap, the teardown that applies a staged switch, and the
-- client that follows it are all walked here. The real match machine's
-- teardown is driven in tools/test_roster.lua ('season.brseason').

describe('season.switch')
do
    -- A STATE THAT NEVER BOOTED CANNOT SWITCH: a client, or a server before
    -- br_core's start.
    local st = state()
    local n, why = st.S.switch(1)
    ok(n == nil and why == 'not booted', 'a state that never booted switches nothing, and says why', why)
    eq(st.wire.br_seasonServed, nil, 'and replicates nothing')
    eq(st.S.startup(), nil, 'a state that never booted has no startup season')
    eq(st.S.origin(), nil, 'and no origin')

    -- AN UNSET BOX: the latest, switched down and back.
    st.S.boot()
    eq(st.S.startup(), LATEST, 'an unset box started on the latest season')
    local src, words = st.S.origin()
    ok(src == 'latest' and words == 'br_season is not set: the latest',
        'and says where it came from: br_season unset, so the latest', words)
    eq(st.S.switch(1), 1, 'switch(1) puts Season 1 in force and says so')
    eq(st.S.current(), 1, 'current() answers the season in force')
    eq(st.wire.br_seasonServed, '1', 'and it is replicated as br_seasonServed, as boot does')
    eq(st.wire.br_season, nil, 'br_season is never written')
    eq(st.cfg.br_season, nil, "and the operator's own is untouched")
    eq(st.S.has('emotes'), false, 'the door answers the new season from the next question on')
    src, words = st.S.origin()
    eq(src, 'override', 'the origin is an override')
    eq(words, ('brseason override; br_core started on Season %d (br_season is not set: the latest)'):format(LATEST),
        'naming the season br_core started on and why')
    eq(st.S.startup(), LATEST, 'the startup season does not move')
    eq(st.S.switch(nil), LATEST, 'switch(nil) is the startup season again')
    eq(st.wire.br_seasonServed, tostring(LATEST), 'replicated as well')
    eq((st.S.origin()), 'latest', 'and the origin is the startup one again, not an override')

    -- BOUNDS: a whole number from 1 to latest, and nothing else.
    for _, bad in ipairs({ 0, -1, LATEST + 1, 1.0, 1.5, '1', true }) do
        local before = st.wire.br_seasonServed
        local got, w = st.S.switch(bad)
        ok(got == nil and w == 'not a season' and st.S.current() == LATEST and st.wire.br_seasonServed == before,
            ('switch(%s %s) is refused, and nothing moves'):format(type(bad), tostring(bad)),
            ('%s %s, in force %s'):format(tostring(got), tostring(w), tostring(st.S.current())))
    end
    eq(st.S.switch(LATEST), LATEST, 'the latest itself is in bounds')
    local wrote = {}
    eq(st.S.switch(1, function(name, value) wrote[name] = value end), 1, 'switch(n, set) takes a setter')
    eq(wrote.br_seasonServed, '1', 'and writes through it, as boot(get, set) does')

    -- A SET BOX.
    st = state({ cfg = { br_season = '1' } })
    st.S.boot()
    src, words = st.S.origin()
    ok(src == 'convar' and words == 'br_season 1', 'br_season 1: the origin is the convar', words)
    st.S.switch(2)
    eq((st.S.origin()), 'override', 'switched off it: an override')
    st.S.switch(nil)
    ok(st.S.current() == 1 and (st.S.origin()) == 'convar', 'and back: the convar again')

    -- GARBAGE, quoted the way the boot banner quotes it.
    st = state({ cfg = { br_season = 'two' } })
    st.S.boot()
    src, words = st.S.origin()
    ok(src == 'latest' and words == 'br_season "two" is not a season: the latest',
        'a br_season that is not a season: the latest, quoting it', words)

    -- PAST THE LATEST: br_core runs what br_season named. brseason may not name
    -- it, but a reset takes it back -- br_core already chose to run it.
    st = state({ cfg = { br_season = tostring(LATEST + 3) } })
    st.S.boot()
    eq(st.S.switch(LATEST + 3), nil, 'brseason may not name a season past the latest')
    eq(st.S.switch(1), 1, 'it may switch off one')
    eq(st.S.switch(nil), LATEST + 3, 'and a reset takes back the startup season br_season named past the latest')

    -- recheck() STILL WATCHES br_season, AND NAMES THE SEASON IN FORCE.
    st = state({ cfg = { br_season = '2' } })
    st.S.boot()
    st.S.switch(1)
    eq(st.S.recheck(), nil, 'a switch is not a change to br_season')
    st.cfg.br_season = '1'
    eq(st.S.recheck(), '[br_core] br_season is now "1"; this server keeps running Season 1 until br_core restarts.',
        'a later br_season change is still seen once, naming the season in force')

    -- THE NEXT br_core START drops the override: br_season is read as always.
    st.cfg.br_season = '2'
    st.S.boot()
    ok(st.S.current() == 2 and (st.S.origin()) == 'convar' and st.wire.br_seasonServed == '2',
        'the next br_core start reads br_season again and the override is gone')
end

describe('season.switch: both sides of the wire')
do
    local wire = {}
    local server = state({ wire = wire })
    local client = state({ wire = wire })
    server.S.boot()
    ok(server.S.has('emotes') and client.S.has('emotes'), 'an unset box: emotes on both sides at the latest')
    server.S.switch(1)
    eq(client.S.current(), 1, 'a switch reaches the client on the replicated value')
    ok(server.S.has('emotes') == false and client.S.has('emotes') == false,
        'and the emote gate answers Season 1 on both sides')
    server.S.switch(nil)
    ok(server.S.has('emotes') == true and client.S.has('emotes') == true,
        'a reset opens it on both again')
    local n, why = client.S.switch(1)
    ok(n == nil and why == 'not booted' and client.S.current() == LATEST and wire.br_seasonServed == tostring(LATEST),
        'a client cannot switch anything: it never booted')
end

--- A br_core server with `brseason` loaded the way the game loads it: the
--- protocol, devgate.lua's wrap in front of RegisterCommand, the season module
--- and its list, then server/season.lua -- over a match registry, a roster and
--- a market this suite can read. The REAL wrap, so dev mode is a real gate.
--- @param o table|nil  { cfg, wire, registry, dev = false }
local function commandServer(o)
    o = o or {}
    local st = state({ cfg = o.cfg, wire = o.wire, registry = o.registry })
    local env = st.env
    st.dev = o.dev ~= false
    st.matches, st.roster, st.pushed, st.out, st.handlers, st.raw = {}, {}, {}, {}, {}, {}
    local get = env.GetConvar
    env.GetConvar = function(name, default)
        if name == 'sv_devMode' or name == 'br_devMode' then return st.dev and 'true' or 'false' end
        return get(name, default)
    end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetPlayerName = function(s) return 'P' .. tostring(s) end
    env.RegisterCommand = function(name, fn, restricted) st.raw[name] = { fn = fn, restricted = restricted } end
    env.TriggerClientEvent = function(event, target, payload)
        st.out[#st.out + 1] = { event = event, target = target, payload = payload }
    end
    env.AddEventHandler = function(name, fn)
        st.handlers[name] = st.handlers[name] or {}
        table.insert(st.handlers[name], fn)
    end
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua', 'br_lib/shared/devgate.lua' }) do
        assert(loadfile(RES .. f, 't', env))()
    end
    env.BR.Server = { matches = st.matches }
    env.BR.Roster = {
        get = function(s) return st.roster[s] end,
        each = function(pred, fn)
            local keys = {}
            for s in pairs(st.roster) do keys[#keys + 1] = s end
            table.sort(keys)
            for _, s in ipairs(keys) do
                if not pred or pred(st.roster[s]) then fn(s, st.roster[s]) end
            end
        end,
    }
    env.BR.Market = { push = function(s) st.pushed[#st.pushed + 1] = s end }
    -- br_core's onResourceStart boots it; the file below reads it at call time.
    st.S.boot()
    assert(loadfile(RES .. 'br_core/server/season.lua', 't', env))()
    st.SW = env.BR.SeasonSwitch
    st.Net = env.BR.Net
    st.MS = env.BR.MatchState

    --- Type it, as FiveM calls a command: from the console (0) or a player.
    function st.run(src, ...) st.raw.brseason.fn(src, { ... }, 'brseason') end
    function st.fire(name, ...)
        for _, fn in ipairs(st.handlers[name] or {}) do fn(...) end
    end
    --- A match instance, in a state.
    function st.match(id, s)
        st.matches[id] = { id = id, seq = id, state = s }
        return st.matches[id]
    end
    --- Its teardown, as BR.Match.destroy does it: the registry entry goes,
    --- then `br:match:destroyed` is raised.
    function st.destroy(id)
        st.matches[id] = nil
        st.fire('br:match:destroyed', { matchId = id })
    end
    function st.switched()
        local out = {}
        for _, e in ipairs(st.out) do
            if e.event == st.Net.SEASON_SWITCHED then out[#out + 1] = e end
        end
        return out
    end
    --- The `brseason` answers sent to one player's F8.
    function st.f8(src)
        local out = {}
        for _, e in ipairs(st.out) do
            if e.event == st.Net.SEASON_RESULT and e.target == src then out[#out + 1] = e.payload end
        end
        return out
    end
    function st.said(needle)
        for i = #st.printed, 1, -1 do
            if st.printed[i]:find(needle, 1, true) then return st.printed[i] end
        end
        return nil
    end
    function st.clear()
        st.out, st.pushed = {}, {}
        for k in pairs(st.printed) do st.printed[k] = nil end
    end
    return st
end

describe('brseason: dev mode off refuses')
do
    local st = commandServer({ dev = false })
    ok(st.raw.brseason ~= nil, "brseason reaches the native through devgate.lua's wrap")
    eq(st.raw.brseason and st.raw.brseason.restricted, true, 'registered restricted, like brforce')
    st.roster[3] = { name = 'Will' }
    st.run(0, '1')
    st.run(3, '1')
    st.run(0, 'reset')
    st.run(0)
    eq(st.S.current(), LATEST, 'with dev mode off nothing switches')
    eq(st.wire.br_seasonServed, tostring(LATEST), 'nothing new is replicated')
    eq(#st.out, 0, 'no client is told anything, and no F8 answered')
    eq(#st.pushed, 0, 'no market state is pushed')
    eq(st.SW.staged(), nil, 'and nothing is staged')
    ok(st.said('[br_core] brseason is dev-mode only') ~= nil and st.said('in force') == nil,
        'the console says which gate closed, and the command body never ran', st.printed[1])

    st.dev = true
    st.run(0, '1')
    eq(st.S.current(), 1, 'the same box with dev mode on switches')
end

describe('brseason: no match running switches at once')
do
    local st = commandServer()
    st.roster[3] = { name = 'Will' }
    st.roster[5] = { name = 'Ana' }

    st.run(0)
    ok(st.said(('[br_core] brseason: Season %d in force -- br_season is not set: the latest'):format(LATEST)) ~= nil,
        'bare: the season in force and where it came from', st.printed[1])
    ok(st.said('brseason: no switch staged') ~= nil, 'and that nothing is staged')
    ok(st.said(('brseason: usage: brseason | brseason <1-%d> | brseason reset'):format(LATEST)) ~= nil,
        'and how to use it')
    eq(#st.out, 0, 'the console asked, so no F8 is sent anything')
    eq(st.S.current(), LATEST, 'and nothing moved')

    st.clear()
    st.run(3, '1')
    eq(st.S.current(), 1, 'brseason 1 with no match running puts Season 1 in force at once')
    eq(st.wire.br_seasonServed, '1', 'and replicates it')
    eq(st.S.has('emotes'), false, 'every server door answers it from the next question on')
    local sw = st.switched()
    ok(#sw == 1 and sw[1].target == -1, 'every client is told, once', #sw)
    local p = sw[1] and sw[1].payload or {}
    ok(p.season == 1 and p.from == LATEST and p.by == 'Will (#3)',
        'with the season, the one before it, and who switched',
        ('%s %s %s'):format(tostring(p.season), tostring(p.from), tostring(p.by)))
    eq(math.type(p.season), 'integer', 'the season crosses as a whole number')
    ok(st.said(('[br_core] brseason: Will (#3) switched this server to Season 1 (was Season %d)'):format(LATEST)) ~= nil,
        'the console says who switched', st.printed[1])
    eq(table.concat(st.pushed, ','), '3,5', "every connected player's market state is pushed again, against the new season")
    eq(st.SW.staged(), nil, 'nothing is left staged')

    st.clear()
    st.run(3)
    local f8 = st.f8(3)
    ok(#f8 == 3 and f8[1] == ('brseason: Season 1 in force -- brseason override; br_core started on Season %d (br_season is not set: the latest)'):format(LATEST),
        'a bare brseason typed in F8 is answered in that F8: Season 1, an override, and the startup season', f8[1])

    st.clear()
    st.run(0, '1')
    ok(#st.switched() == 0 and #st.pushed == 0 and st.said('brseason: Season 1 is already in force') ~= nil,
        'naming the season in force switches nothing')

    st.clear()
    st.run(5, 'reset')
    eq(st.S.current(), LATEST, 'brseason reset with no match running goes back to the startup season at once')
    eq((st.S.origin()), 'latest', 'and where it came from is the startup again')
    sw = st.switched()
    ok(#sw == 1 and sw[1].payload.season == LATEST and sw[1].payload.from == 1 and sw[1].payload.by == 'Ana (#5)',
        'every client is told, naming who reset it')
    eq(#st.pushed, 2, 'and every market state is pushed again')

    st.clear()
    st.run(0, 'reset')
    ok(#st.switched() == 0 and st.said(('brseason: Season %d is already in force'):format(LATEST)) ~= nil,
        'reset on the startup season switches nothing')
end

describe('brseason: bounds')
do
    local st = commandServer()
    for _, bad in ipairs({ '0', '00', '-1', tostring(LATEST + 1), '1.5', '2.0', 'two', 'S1', '0x1',
                           '99999999999999999999', '' }) do
        st.clear()
        st.run(0, bad)
        ok(st.S.current() == LATEST and #st.out == 0 and #st.pushed == 0 and st.SW.staged() == nil
                and st.said(('is not a season this code knows -- 1 to %d, or reset'):format(LATEST)) ~= nil,
            ('%q is refused, and nothing moves'):format(bad), st.printed[1])
    end
    st.clear()
    st.run(4, 'nope')
    local f8 = st.f8(4)
    ok(#f8 == 1 and f8[1]:find('"nope" is not a season', 1, true) ~= nil, 'a refusal typed in F8 is answered in that F8', f8[1])
    for season = 1, LATEST do
        st.run(0, tostring(season))
        eq(st.S.current(), season, ('Season %d is in bounds'):format(season))
    end
    -- A refused one does not touch a staged one.
    st.match(1, st.MS.PLAYING)
    st.run(0, '1')
    st.run(0, tostring(LATEST + 1))
    ok(st.SW.staged() ~= nil and st.SW.staged().season == 1, 'a refused season leaves a staged switch where it was')
end

describe('brseason: staged in every match state, applied at the teardown and not before')
do
    for i, s in ipairs({ 'WARMUP', 'BUS', 'PLAYING', 'ENDED', 'CLEANUP' }) do
        local st = commandServer()
        local states = { st.MS.WARMUP, st.MS.BUS, st.MS.PLAYING, st.MS.ENDED, st.MS.CLEANUP }
        st.roster[3] = { name = 'Will' }
        local m = st.match(101, states[i])

        st.run(3, '1')
        eq(st.S.current(), LATEST, ('typed during %s: the season in force does not move'):format(s))
        eq(st.wire.br_seasonServed, tostring(LATEST), ('typed during %s: nothing is replicated'):format(s))
        ok(#st.switched() == 0 and #st.pushed == 0, ('typed during %s: no client is told, no market pushed'):format(s))
        local stg = st.SW.staged()
        ok(stg ~= nil and stg.season == 1 and stg.by == 'Will (#3)', ('typed during %s: it is staged, naming who'):format(s))
        local f8 = st.f8(3)
        ok(f8[1] == 'brseason: 1 match running -- Season 1 is staged, and applies when the last one is torn down to the lobby',
            ('typed during %s: the F8 says it is staged and when it applies'):format(s), f8[1])

        for j = i + 1, #states do
            m.state = states[j]
            st.run(0)
            eq(st.S.current(), LATEST, ('still staged as the match moves on to %s'):format(states[j]))
        end
        st.run(0)
        ok(st.said('brseason: Season 1 staged by Will (#3), for when the last of 1 running match is torn down to the lobby') ~= nil,
            'a bare brseason shows the staged switch')

        -- The event with the match still in the registry is not a teardown.
        st.fire('br:match:destroyed', { matchId = 101 })
        eq(st.S.current(), LATEST, 'br:match:destroyed with the match still registered applies nothing')

        st.clear()
        st.destroy(101)
        eq(st.S.current(), 1, ('torn down from %s: Season 1 is in force'):format(s))
        eq(st.wire.br_seasonServed, '1', 'and replicated')
        local sw = st.switched()
        ok(#sw == 1 and sw[1].target == -1 and sw[1].payload.season == 1 and sw[1].payload.by == 'Will (#3)',
            'every client is told once, naming who staged it')
        eq(table.concat(st.pushed, ','), '3', 'and the market state is pushed again')
        eq(st.SW.staged(), nil, 'nothing is left staged')
        ok(st.said('[br_core] brseason: Will (#3) switched this server to Season 1') ~= nil, 'the console says who')
    end

    -- TWO MATCHES: the LAST teardown applies it.
    local st = commandServer()
    st.match(1, st.MS.PLAYING)
    st.match(2, st.MS.WARMUP)
    st.run(0, '1')
    ok(st.said('brseason: 2 matches running -- Season 1 is staged') ~= nil,
        'two matches running: staged, and the console counts them')
    st.destroy(1)
    eq(st.S.current(), LATEST, 'one of two torn down: still staged')
    ok(st.SW.staged() ~= nil and #st.switched() == 0, 'and nobody is told')
    st.destroy(2)
    eq(st.S.current(), 1, 'the last one torn down applies it')
    eq(#st.switched(), 1, 'once')

    -- A teardown with nothing staged moves nothing.
    st.clear()
    st.match(3, st.MS.WARMUP)
    st.destroy(3)
    ok(st.S.current() == 1 and #st.switched() == 0 and #st.pushed == 0, 'a teardown with nothing staged moves nothing')
end

describe('brseason: a second one replaces a staged one, and reset stages too')
do
    -- Three seasons, so a replacement can name a third.
    local reg = { latest = 3, features = { emotes = { from = 2 } } }
    local st = commandServer({ registry = reg })
    eq(st.S.current(), 3, 'an unset box on a three-season list runs Season 3')
    st.roster[3] = { name = 'Will' }
    st.roster[5] = { name = 'Ana' }

    st.match(7, st.MS.PLAYING)
    st.run(3, '1')
    st.run(5, '2')
    local stg = st.SW.staged()
    ok(stg ~= nil and stg.season == 2 and stg.by == 'Ana (#5)', 'the second replaces the first, naming who typed it')
    ok((st.f8(5)[1] or ''):find('Season 2 is staged, replacing the one staged before', 1, true) ~= nil,
        'and says it replaced one', st.f8(5)[1])
    st.destroy(7)
    eq(st.S.current(), 2, 'the teardown applies the replacement, not the first')
    eq(#st.switched(), 1, 'once')

    st.clear()
    st.match(8, st.MS.BUS)
    st.run(0, '1')
    st.run(0, '2')
    eq(st.SW.staged(), nil, 'brseason naming the season in force drops a staged switch')
    ok(st.said('brseason: Season 2 is already in force -- the staged switch is dropped') ~= nil, 'and says so')
    st.destroy(8)
    ok(st.S.current() == 2 and #st.switched() == 0, 'and the teardown applies nothing')

    st.clear()
    st.match(9, st.MS.ENDED)
    st.run(3, 'reset')
    stg = st.SW.staged()
    ok(stg ~= nil and stg.reset == true and stg.season == 3, 'brseason reset during a match is staged, like any other')
    eq(st.S.current(), 2, 'and moves nothing yet')
    ok((st.f8(3)[1] or ''):find('Season 3 (reset) is staged', 1, true) ~= nil, 'the F8 says the reset is staged', st.f8(3)[1])
    st.destroy(9)
    ok(st.S.current() == 3 and (st.S.origin()) == 'latest', 'the teardown applies it: the startup season, from where it started')

    st.clear()
    st.match(10, st.MS.WARMUP)
    st.run(0, '1')
    st.run(0, 'reset')
    eq(st.SW.staged(), nil, 'reset on the startup season drops a staged switch')
    st.destroy(10)
    ok(st.S.current() == 3 and #st.switched() == 0, 'and the teardown applies nothing')

    -- A STAGED RESET TAKES BACK A STARTUP SEASON PAST THE LATEST.
    local past = commandServer({ cfg = { br_season = tostring(LATEST + 2) } })
    past.run(0, '1')
    eq(past.S.current(), 1, 'a box started past the latest switches down')
    past.match(1, past.MS.WARMUP)
    past.run(0, 'reset')
    past.destroy(1)
    eq(past.S.current(), LATEST + 2, 'and a staged reset takes back the season br_season named, past the latest')
end

-- =========================================================================
-- brseason and licensed assets (#391)
-- =========================================================================
--
-- Streamed assets cannot switch while the server runs. tools/assets.py pull
-- installs the licensed set for the season server.cfg names and records it,
-- with every other season's set, in br_licensed/installed.txt; a switch to a
-- season whose set differs warns, names the resources, and still switches.

--- An install record as tools/assets.py writes it.
local function record(lines)
    return table.concat(lines, '\n') .. '\n'
end
local function sha(c) return c:rep(64) end

--- Season 2 installed: legion at aaaa and emotes at bbbb. Season 1 would run
--- legion at cccc and no emotes.
local RECORD = record({
    '# GENERATED by tools/assets.py pull (#391). Do not edit: the next pull rewrites it.',
    'format 1',
    'season 2',
    'seasons 1 2',
    'installed legion ' .. sha('a'),
    'installed emotes ' .. sha('b'),
    'plan 1 legion ' .. sha('c'),
    'plan 2 legion ' .. sha('a'),
    'plan 2 emotes ' .. sha('b'),
})

--- A brseason server whose LoadResourceFile serves `text` as the record.
local function licensedServer(text, o)
    local st = commandServer(o)
    st.reads = {}
    st.env.LoadResourceFile = function(res, file)
        st.reads[#st.reads + 1] = res .. '/' .. file
        if res == 'br_licensed' and file == 'installed.txt' then return text end
        return nil
    end
    st.roster[3] = { name = 'Will' }
    return st
end

local WARN1 = 'brseason: WARNING -- Season 1 runs different licensed assets from the ones installed: '
    .. 'emotes (installed, not in Season 1), legion (installed aaaaaaaa, Season 1 has cccccccc)'
local RESTART1 = "brseason: streamed assets cannot switch while the server runs; to install Season 1's, "
    .. 'set that season in server.cfg, redeploy and restart'

describe('brseason: licensed assets')
do
    -- No record: no pull has ever run here, and nothing is said.
    local none = licensedServer(nil)
    none.run(3, '1')
    eq(none.S.current(), 1, 'with no record the switch is as before')
    ok(none.said('licensed') == nil, 'and nothing is said about licensed assets')
    eq(none.reads[1], 'br_licensed/installed.txt', 'the record is asked for by the names assets.py writes')

    -- A switch whose set differs: it warns, names each resource, and switches.
    local st = licensedServer(RECORD)
    st.run(3, '1')
    eq(st.S.current(), 1, 'the switch still happens')
    ok(st.said('[br_core] ' .. WARN1) ~= nil, 'the console names every resource that differs, and how', st.printed[#st.printed - 1])
    ok(st.said('[br_core] ' .. RESTART1) ~= nil, 'and says a redeploy and restart are what installs them')
    local f8 = st.f8(3)
    ok(f8[#f8 - 1] == WARN1 and f8[#f8] == RESTART1, 'the F8 of whoever typed it gets both lines, last', f8[#f8 - 1])

    -- A bare brseason while the season in force differs from the installed set.
    st.clear()
    st.run(3)
    f8 = st.f8(3)
    ok(#f8 == 5 and f8[4] == WARN1, 'a bare brseason repeats the warning while the sets differ', #f8)

    -- Back to the installed season: the sets agree, nothing is said.
    st.clear()
    st.run(3, 'reset')
    eq(st.S.current(), LATEST, 'reset goes back')
    ok(st.said('licensed') == nil, 'and the installed season warns about nothing')
    st.clear()
    st.run(3)
    eq(#st.f8(3), 3, 'nor does a bare brseason on it')

    -- Staged: warned when typed, since that is when somebody is reading.
    local stg = licensedServer(RECORD)
    stg.match(1, stg.MS.PLAYING)
    stg.run(3, '1')
    eq(stg.S.current(), LATEST, 'staged, nothing moves')
    ok(stg.said('[br_core] ' .. WARN1) ~= nil, 'and the warning comes with the staged line')

    -- A version difference alone is a difference.
    local v = licensedServer(record({ 'format 1', 'season 1', 'seasons 1 2',
        'installed legion ' .. sha('a'), 'plan 1 legion ' .. sha('a'), 'plan 2 legion ' .. sha('d') }),
        { cfg = { br_season = '1' } })
    v.run(0, '2')
    ok(v.said('Season 2 runs different licensed assets from the ones installed: legion (installed aaaaaaaa, Season 2 has dddddddd)') ~= nil,
        'one resource at another version is named with both versions')

    -- A season the record has no plan for: say so rather than guess.
    local gap = licensedServer(record({ 'format 1', 'season 2', 'seasons 2', 'installed legion ' .. sha('a'),
        'plan 2 legion ' .. sha('a') }))
    gap.run(0, '1')
    ok(gap.said('brseason: WARNING -- the licensed asset record on this box has no plan for Season 1; redeploy to refresh it') ~= nil,
        'a season the record never planned is said to be unknown')

    -- After a swap whose undo failed too, a resource the pull found with no
    -- earlier record of it is `installed <name> unknown`: said in words, not
    -- printed as if `unknown` were a version.
    local unk = licensedServer(record({ 'format 1', 'season 1', 'seasons 1 2', 'installed legion unknown',
        'installed emotes unknown', 'plan 1 legion ' .. sha('a'), 'plan 2 legion ' .. sha('a') }),
        { cfg = { br_season = '1' } })
    unk.run(0, '2')
    ok(unk.said('Season 2 runs different licensed assets from the ones installed: '
        .. 'emotes (installed, not in Season 2), '
        .. 'legion (installed at a version a failed swap could not record, Season 2 has aaaaaaaa)') ~= nil,
        'an unknown version is named as one, with what the season has', unk.printed[#unk.printed - 1])
    ok(unk.said('installed unknown') == nil, 'and `unknown` is never printed as a version')

    -- The parser: CRLF from a hand-copied file, a format it does not know.
    local P = st.SW.parseLicensed
    local crlf = P((RECORD:gsub('\n', '\r\n')))
    ok(crlf ~= nil and crlf.installed.legion == sha('a') and crlf.plans[1].legion == sha('c') and crlf.season == 2,
        'a CRLF record reads the same')
    eq(P((RECORD:gsub('format 1', 'format 2'))), nil, 'a format it does not know is no record')
    eq(P(''), nil, 'nor is an empty file')
    local empty = P(record({ 'format 1', 'season 1', 'seasons 1 2', 'plan 2 emotes ' .. sha('b') }))
    ok(empty ~= nil and next(empty.plans[1]) == nil and empty.plans[2].emotes == sha('b'),
        'a season with nothing planned is an empty plan, not a missing one')
    local d = st.SW.licensedDiff(P(RECORD), 1)
    ok(#d == 2 and d[1].name == 'emotes' and d[1].want == nil and d[2].name == 'legion' and d[2].want == sha('c'),
        'the difference is by name, sorted')
end

--- A client with br_core's client/season.lua loaded over the real season
--- module, its own copy of the replicated convars, and a SLOW pass this suite
--- steps by hand.
local function followClient(wire)
    local cl = state({ wire = wire })
    local env = cl.env
    cl.handlers, cl.raised, cl.slow = {}, {}, nil
    env.BR.Loop = {
        SLOW = 'slow',
        register = function(band, name, fn)
            if band == 'slow' and name == 'season.follow' then cl.slow = fn end
        end,
    }
    env.RegisterNetEvent = function() end
    env.AddEventHandler = function(name, fn)
        cl.handlers[name] = cl.handlers[name] or {}
        table.insert(cl.handlers[name], fn)
    end
    env.TriggerEvent = function(name, ...) cl.raised[#cl.raised + 1] = { name = name, args = { ... } } end
    assert(loadfile(RES .. 'br_lib/shared/protocol.lua', 't', env))()
    assert(loadfile(RES .. 'br_core/client/season.lua', 't', env))()
    cl.Net = env.BR.Net
    function cl.deliver(name, ...)
        for _, fn in ipairs(cl.handlers[name] or {}) do fn(...) end
    end
    function cl.changes()
        local out = {}
        for _, e in ipairs(cl.raised) do
            if e.name == 'br:season:changed' then out[#out + 1] = e end
        end
        return out
    end
    function cl.said(line)
        for i = #cl.printed, 1, -1 do
            if cl.printed[i] == line then return true end
        end
        return false
    end
    return cl
end

describe('brseason: every client is told, and follows the replicated value')
do
    local srvWire, cliWire = {}, {}
    local srv = commandServer({ wire = srvWire })
    local cl = followClient(cliWire)
    ok(cl.slow ~= nil, "client/season.lua registers a SLOW pass, 'season.follow'")
    local function land() for k, v in pairs(srvWire) do cliWire[k] = v end end

    cl.slow()
    eq(#cl.changes(), 0, 'no season yet: nothing to re-read')
    land()
    cl.slow()
    eq(#cl.changes(), 0, 'the season arriving is not a switch: the emote gate pass handles an arrival')

    -- THE MESSAGE BEFORE THE VALUE.
    srv.run(3, '1')
    local p = srv.switched()[1].payload
    cl.deliver(cl.Net.SEASON_SWITCHED, p)
    ok(cl.said('[br_core] brseason: P3 (#3) switched this server to Season 1'),
        'every F8 is told who switched', cl.printed[#cl.printed])
    eq(#cl.changes(), 0, 'the message alone re-reads nothing: the client runs what it reads, and has not read Season 1')
    eq(cl.S.has('emotes'), true, 'so its gate still answers the season it has')
    cl.slow()
    eq(#cl.changes(), 0, 'nor does a pass before the value lands')
    land()
    cl.slow()
    local ch = cl.changes()
    eq(#ch, 1, 'the pass after the value lands raises br:season:changed, once')
    ok(ch[1] and ch[1].args[1] == 1 and ch[1].args[2] == LATEST, 'carrying the new season and the one before')
    ok(cl.S.has('emotes') == false and srv.S.has('emotes') == false,
        'and the emote gate answers Season 1 on both sides')
    cl.slow()
    eq(#cl.changes(), 1, 'a later pass does not raise it again')

    -- THE VALUE BEFORE THE MESSAGE.
    srv.clear()
    srv.run(0, 'reset')
    land()
    cl.deliver(cl.Net.SEASON_SWITCHED, srv.switched()[1].payload)
    eq(#cl.changes(), 2, 'with the value already there, the message raises it at once')
    cl.slow()
    eq(#cl.changes(), 2, 'and the pass after does not raise it twice')
    ok(cl.S.has('emotes') == true and srv.S.has('emotes') == true, 'both sides open again')

    -- A STAGED ONE: nothing reaches the client until the teardown.
    srv.clear()
    srv.match(1, srv.MS.PLAYING)
    srv.run(0, '1')
    land()
    cl.slow()
    ok(#srv.switched() == 0 and #cl.changes() == 2 and cl.S.current() == LATEST,
        'staged during a match: nothing is sent and nothing moves on the client')
    srv.destroy(1)
    cl.deliver(cl.Net.SEASON_SWITCHED, srv.switched()[1].payload)
    land()
    cl.slow()
    ok(#cl.changes() == 3 and cl.S.current() == 1, 'the teardown sends it, and the client follows')

    -- GARBAGE moves nothing and raises nothing.
    local before = #cl.printed
    cl.deliver(cl.Net.SEASON_SWITCHED, 'x')
    cl.deliver(cl.Net.SEASON_SWITCHED, { season = 'two' })
    cl.deliver(cl.Net.SEASON_SWITCHED, nil)
    ok(#cl.printed == before and #cl.changes() == 3, 'a malformed message prints nothing and moves nothing')
    cliWire.br_seasonServed = 'x'
    cl.slow()
    eq(#cl.changes(), 3, 'a garbled read is no switch')
    cliWire.br_seasonServed = '1'
    cl.slow()
    eq(#cl.changes(), 3, 'and the season it was is still the one compared against')

    -- THE F8 ANSWER.
    cl.deliver(cl.Net.SEASON_RESULT, 'brseason: Season 1 is already in force')
    ok(cl.said('[br_core] brseason: Season 1 is already in force'), 'a brseason answer lands in the F8 of whoever typed it')
    before = #cl.printed
    cl.deliver(cl.Net.SEASON_RESULT, { 'x' })
    eq(#cl.printed, before, 'and anything but text is ignored')
end

-- =========================================================================
-- the wiring: who boots, who loads, what crosses to the page
-- =========================================================================

--- Code only: line comments and block comments removed.
local function code(src)
    src = src:gsub('%-%-%[(=*)%[.-%]%1%]', '')
    return (src:gsub('%-%-[^\n]*', ''))
end

describe('season.wiring')
do
    local main = code(assert(readFile(RES .. 'br_core/server/main.lua')))
    local start = main:find("AddEventHandler('onResourceStart'", 1, true)
    local boot = main:find('BR.Season.boot()', 1, true)
    local sched = main:find('BR.Sched.start()', 1, true)
    ok(start and boot and sched and start < boot and boot < sched,
        'server/main.lua boots the season in onResourceStart, before the scheduler starts')
    local _, nBoot = main:gsub('BR%.Season%.boot%(', '')
    eq(nBoot, 1, 'and nowhere else')
    ok(main:find('for _, l in ipairs(seasonLines) do print(l) end', 1, true) ~= nil,
        'and prints the lines boot handed back')
    ok(main:find("BR.Sched.every(5000, 'season.watch'", 1, true) ~= nil
        and main:find('BR.Season.recheck()', 1, true) ~= nil,
        'and watches for a change it will ignore')

    -- EVERY RESOURCE THAT ASKS LOADS BOTH FILES, uncommented.
    for _, res in ipairs({ 'br_core', 'br_ui' }) do
        local man = code(assert(readFile(RES .. res .. '/fxmanifest.lua')))
        ok(man:find("'@br_lib/shared/season.lua'", 1, true) ~= nil
            and man:find("'@br_lib/config/seasons.lua'", 1, true) ~= nil,
            res .. ' loads the season module and the list')
    end
end

describe('brseason.wiring')
do
    -- BOTH HALVES ARE LOADED, each on its own side.
    local man = code(assert(readFile(RES .. 'br_core/fxmanifest.lua')))
    local cliAt = man:find('client_scripts%s*{')
    local srvAt = man:find('server_scripts%s*{')
    local cmain = man:find("'client/main.lua'", 1, true)
    local cl = man:find("'client/season.lua'", 1, true)
    local market = man:find("'server/market.lua'", 1, true)
    local sv = man:find("'server/season.lua'", 1, true)
    ok(cliAt and srvAt and cmain and cl and cliAt < cmain and cmain < cl and cl < srvAt,
        "br_core's client_scripts load client/season.lua, after client/main.lua (the loop registry)")
    ok(srvAt and market and sv and srvAt < market and market < sv,
        "br_core's server_scripts load server/season.lua, after server/market.lua")

    -- THE COMMAND IS AN ORDINARY DEV COMMAND: through the wrapped door,
    -- restricted, and reading no dev mode of its own -- the wrap is the gate.
    local cmd = code(assert(readFile(RES .. 'br_core/server/season.lua')))
    ok(cmd:find("RegisterCommand('brseason', function(src, args)", 1, true) ~= nil,
        'server/season.lua registers brseason through RegisterCommand, which devgate.lua wraps')
    ok(cmd:find('end, true%)%s*$') ~= nil, 'restricted: its last line is `end, true)`')
    ok(cmd:find('rawCommand', 1, true) == nil and cmd:find('BR.Dev', 1, true) == nil
        and cmd:find('devMode', 1, true) == nil,
        'and it never goes round the wrap or reads dev mode itself')
    ok(cmd:find("AddEventHandler('br:match:destroyed'", 1, true) ~= nil,
        'it applies a staged switch on br:match:destroyed')

    -- THE TEARDOWN IT HANGS OFF: BR.Match.destroy sends every player home,
    -- drops the registry entry, and only then raises the event -- so a staged
    -- switch lands with the lobby already the lobby and the count already
    -- leaving the destroyed match out.
    local match = code(assert(readFile(RES .. 'br_core/server/match.lua')))
    local d0 = match:find('function BR.Match.destroy(m)', 1, true)
    local d1 = d0 and match:find('\nfunction ', d0 + 1, true)
    local home = d0 and match:find('BR.Roster.setState(src, BR.PlayerState.LOBBY)', d0, true)
    local gone = d0 and match:find('BR.Server.matches[m.id] = nil', d0, true)
    local raised = d0 and match:find("TriggerEvent('br:match:destroyed'", d0, true)
    ok(d0 and d1 and home and gone and raised and home < gone and gone < raised and raised < d1,
        'BR.Match.destroy sends players to the lobby, drops the match, then raises br:match:destroyed')

    -- WHO LISTENS FOR THE CLIENT'S RE-READ, and who raises it.
    local keybinds = code(assert(readFile(RES .. 'br_core/client/keybinds.lua')))
    ok(keybinds:find("AddEventHandler('br:season:changed', function()\n    BR.Keys.mapGated()\n    BR.Keys.push()\nend)", 1, true) ~= nil,
        'client/keybinds.lua maps and re-pushes on br:season:changed')
    local uiMarket = code(assert(readFile(RES .. 'br_ui/client/market.lua')))
    ok(uiMarket:find("AddEventHandler('br:season:changed', function()\n    BR.Market.push()\nend)", 1, true) ~= nil,
        "br_ui's market re-sends the grid and the EMOTES flag on br:season:changed")
    local follow = code(assert(readFile(RES .. 'br_core/client/season.lua')))
    ok(follow:find("TriggerEvent('br:season:changed', now, before)", 1, true) ~= nil,
        'client/season.lua raises it, with the new season and the one before')
end

describe('brseason.licensed.wiring')
do
    -- THE RECORD CROSSES A LANGUAGE BOUNDARY (#391): tools/assets.py writes
    -- it and server/season.lua reads it, so the names and the line shapes are
    -- compared as text.
    local py = assert(readFile('tools/assets.py'))
    ok(py:find("RECORD_RESOURCE = 'br_licensed'", 1, true) ~= nil and py:find("RECORD_FILE = 'installed.txt'", 1, true) ~= nil,
        'tools/assets.py writes the record at br_licensed/installed.txt')
    for _, l in ipairs({ "'format 1'", "'season %d' % season", "'seasons %s'", "'installed %s %s'", "'plan %d %s %s'" }) do
        ok(py:find(l, 1, true) ~= nil, 'and writes the line ' .. l)
    end
    ok(py:find("UNKNOWN_VERSION = 'unknown'", 1, true) ~= nil,
        'and writes `unknown` for a version it cannot name, which the warning above says in words')
    local cmd = code(assert(readFile(RES .. 'br_core/server/season.lua')))
    ok(cmd:find("local LICENSED_RESOURCE = 'br_licensed'", 1, true) ~= nil
        and cmd:find("local LICENSED_FILE = 'installed.txt'", 1, true) ~= nil,
        'server/season.lua reads br_licensed/installed.txt')
end

describe('season.label')
do
    -- THE SERVER SENDS IT UNDER THE COMMIT'S OWN GATE (test_roster's lobby
    -- block drives the real broadcast; this pins the shape).
    local lobby = code(assert(readFile(RES .. 'br_core/server/lobby.lua')))
    ok(lobby:find('local devOn = BR.Dev and BR.Dev.on and BR.Dev.on()', 1, true) ~= nil,
        'server/lobby.lua resolves dev mode once per broadcast')
    ok(lobby:find('commit    = devOn and BR.Lobby.commit or nil', 1, true) ~= nil,
        'the commit is sent only in dev mode')
    ok(lobby:find('season    = devOn and BR.Season.current() or nil', 1, true) ~= nil,
        'and the season beside it, under the same gate, from the server\'s own season')

    -- THE CLIENT PASSES IT THROUGH, as it does the commit.
    local stateLua = code(assert(readFile(RES .. 'br_core/client/state.lua')))
    ok(stateLua:find('season    = d.season,', 1, true) ~= nil, 'client/state.lua forwards it to the page')

    -- THE PAGE: typed, built as "S2 · 1a2b3c4", drawn only when there is text.
    local types = assert(readFile('ui-src/src/bridge/types.ts'))
    ok(types:find('season?: number', 1, true) ~= nil, 'the lobby payload type carries season?: number')
    local tsx = assert(readFile('ui-src/src/screens/Lobby.tsx'))
    ok(tsx:find("const versionLabel = [lobby?.season ? `S${lobby.season}` : '', lobby?.commit ?? '']", 1, true) ~= nil,
        'Lobby.tsx puts the season in front of the commit, as S<n>')
    ok(tsx:find(".filter((part) => part !== '').join(' · ')", 1, true) ~= nil,
        'joined by a middle dot, with either one alone when the other is absent')
    ok(tsx:find("{versionLabel !== '' && (", 1, true) ~= nil and tsx:find('{versionLabel}', 1, true) ~= nil,
        'and drawn only when there is something to draw: off dev mode, nothing')
    local _, nCommit = tsx:gsub('{lobby%.commit}', '')
    eq(nCommit, 0, 'the bare commit is no longer drawn on its own')
end

describe('season.config')
do
    local cfg = assert(readFile('server.cfg.example'))
    local lineAt, ensureAt, live
    local n = 0
    for line in (cfg .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        if line:match('^#%s*set br_season 1%s*$') then lineAt = lineAt or n end
        if line:match('^ensure br_core') then ensureAt = ensureAt or n end
        if line:match('^%s*setr?%s+br_season') then live = live or line end
    end
    ok(live == nil, 'server.cfg.example sets no season uncommented: each box decides', live)
    ok(lineAt ~= nil and ensureAt ~= nil and lineAt < ensureAt,
        'server.cfg.example carries a commented `set br_season 1` above `ensure br_core`')
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
