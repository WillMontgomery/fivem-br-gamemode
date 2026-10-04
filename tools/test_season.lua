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

    eq(client.S.current(), LATEST, 'a client before the convar arrives reads the latest')

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
    -- the client falls back the way the server would have.
    wire.br_seasonServed = 'x'
    eq(client.S.current(), LATEST, 'a garbled br_seasonServed reads as the latest')

    -- READ AT CALL TIME on the client, never held: a value that lands late
    -- is used as soon as it lands.
    wire.br_seasonServed = nil
    local before = client.S.current()
    wire.br_seasonServed = '1'
    ok(before == LATEST and client.S.current() == 1, 'the client never keeps a value from before it arrived')
    eq(client.S.recheck(), nil, 'a client never booted, so it never reports a change')
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
