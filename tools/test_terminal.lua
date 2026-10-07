-- Unit tests for the Season 2 terminals' contract (#396): the shell half.
--
-- The contract is docs/terminals.md. Three Lua files carry it, and each is
-- stood up here for real over stubbed natives:
--
--   PART A  br_core/server/terminal.lua behind the REAL devgate.lua and the
--           REAL season module -- the dev command, the session a run is only
--           ever taken inside, every reason a run is refused or dropped, the
--           key and the squad's use spent once, the season switched under an
--           open session, and the registry agreeing with the copy block.
--   PART B  br_core/client/terminal.lua over a modelled cuchi_computer --
--           what it opens the computer with, what it relays each way, the key
--           layer told on the way in and out, and `brterminal`'s lines.
--   PART C  cuchi_computer/client/shell.lua -- the NUI focus vote taken and
--           released on every way in and out, nothing opened before the page
--           is ready, the page's run request shape-checked and sent on with
--           the terminal br_core opened, and the opener stopping.
--   PART D  the three together: PART B's client and PART C's shell wired to
--           PART A's server, one round trip from the dev command to the answer
--           on the page.
--
-- What a browser has to show -- the desktop, the app, Escape and the mouse in
-- the page -- is the headless check in #396's report, not this file.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_terminal.lua

local realPrint = print
local ROOT = 'resources/[fivem-royale]/'
local CUCHI = 'resources/[computer]/cuchi_computer/'

local function loadFile(path)
    local chunk, err = loadfile(path)
    if not chunk then
        realPrint('\27[31mload error\27[0m ' .. path .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

local function loadAll(files)
    for _, f in ipairs(files) do loadFile(ROOT .. f) end
end

--- The function files br_core's manifest lists under `<side>/terminalfx/`
--- (wave A on, one per function), in its order, as paths under ROOT. Loaded
--- from the manifest so a function file the manifest forgot is a function the
--- suite finds unbuilt.
--- @param side string  'server' | 'client'
--- @return string[]
local function fxFiles(side)
    local fh = io.open(ROOT .. 'br_core/fxmanifest.lua', 'rb')
    local text = fh and fh:read('a') or ''
    if fh then fh:close() end
    local out = {}
    for f in text:gmatch("'(" .. side .. "/terminalfx/[%w_]+%.lua)'") do
        out[#out + 1] = 'br_core/' .. f
    end
    return out
end

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
            detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local function eq(got, want, name)
    ok(got == want, name, ('got %s, want %s'):format(tostring(got), tostring(want)))
end

-- =========================================================================
-- PART A -- the server
-- =========================================================================

local S = {}   -- the server world: handlers, sent, console, commands, convars

local function bootServer(opts)
    opts = opts or {}
    BR = nil
    S.handlers, S.sent, S.console, S.commands = {}, {}, {}, {}
    S.convars = {
        sv_devMode = opts.devMode == false and 'false' or 'true',
        br_season = opts.season or '2',
    }
    S.clock = 100000
    S.players = { [1] = 'Alpha', [2] = 'Bravo' }
    S.timers = {}

    function GetGameTimer() return S.clock end
    -- A RUN LOADS FOR runMinMs..runMaxMs (round 2): the server's SetTimeout,
    -- held here and stepped by `flush`.
    function SetTimeout(ms, fn) S.timers[#S.timers + 1] = { at = S.clock + ms, fn = fn, ms = ms } end
    function GetCurrentResourceName() return 'br_core' end
    function IsDuplicityVersion() return true end
    function GetConvar(n, d)
        local v = S.convars[n]
        if v == nil then return d end
        return v
    end
    function SetConvarReplicated(n, v) S.convars[n] = v end
    function GetPlayerName(src) return S.players[src] end
    function RegisterCommand(name, fn, restricted)
        S.commands[name] = { fn = fn, restricted = restricted }
    end
    function RegisterNetEvent() end
    function AddEventHandler(name, fn)
        S.handlers[name] = S.handlers[name] or {}
        table.insert(S.handlers[name], fn)
    end
    function TriggerClientEvent(name, target, data)
        S.sent[#S.sent + 1] = { name = name, target = target, data = data }
        if S.onClient then S.onClient(name, target, data) end
    end
    print = function(s) S.console[#S.console + 1] = tostring(s) end

    -- THE REAL DEV GATE FIRST, as br_core's manifest loads it.
    loadAll({
        'br_lib/shared/devgate.lua',
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/shared/notice.lua',
        'br_lib/shared/rng.lua',
        'br_lib/shared/season.lua',
        'br_lib/config/seasons.lua',
        'br_lib/config/terminals.lua',
        'br_lib/shared/terminal_solve.lua',
        'br_lib/shared/shop_solve.lua',
    })
    BR.Season.strict = true
    BR.Season.boot()
    -- The toasts a run's last word becomes once its computer has closed, and
    -- the currency's name the Volts are written with (config/market.lua's).
    S.notices = {}
    BR.Config.Market = { currency = 'Volts' }
    BR.Server = { notify = function(target, text, tone)
        S.notices[#S.notices + 1] = { target = target, text = text, tone = tone }
    end }
    loadAll({ 'br_core/server/terminal.lua', 'br_core/server/terminalfx.lua' })
    loadAll(fxFiles('server'))
end

local function fireAs(src, name, ...)
    local prev = source
    source = src
    for _, fn in ipairs(S.handlers[name] or {}) do fn(...) end
    source = prev
end

--- Let every pending timer run, the clock moved to each one's time: a run's
--- loading, over.
local function flush()
    for _ = 1, 20 do
        if #S.timers == 0 then return end
        local due = S.timers
        S.timers = {}
        table.sort(due, function(a, b) return a.at < b.at end)
        for _, t in ipairs(due) do
            if t.at > S.clock then S.clock = t.at end
            t.fn()
        end
    end
end

--- Type one `brterminalsv` line as `src` (0 is the server console).
local function sv(src, line)
    local args = {}
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    local c = S.commands.brterminalsv
    if c then c.fn(src, args, 'brterminalsv ' .. line) end
end

local function sentTo(target, name)
    local out = {}
    for _, e in ipairs(S.sent) do
        if (target == nil or e.target == target) and (name == nil or e.name == name) then
            out[#out + 1] = e
        end
    end
    return out
end

local function last(target, name)
    local r = sentTo(target, name)
    return r[#r] and r[#r].data or nil
end

local function fnState(state, id)
    for _, f in ipairs(state and state.functions or {}) do
        if f.id == id then return f end
    end
    return nil
end

describe('the dev command is a dev command')
do
    bootServer({ devMode = false })
    sv(1, 'open')
    eq(#sentTo(1, nil), 0, 'with dev mode off, brterminalsv opens nothing')
    ok(table.concat(S.console, '\n'):find('dev-mode only', 1, true) ~= nil,
        'and the gate says which gate closed', table.concat(S.console, '\n'))

    bootServer()
    ok(S.commands.brterminalsv ~= nil and S.commands.brterminalsv.restricted == false,
        'registered unrestricted, through the wrap (dev mode is its gate, as brpropsv)')
end

describe('it is Season 2')
do
    bootServer({ season = '1' })
    sv(1, 'open')
    eq(#sentTo(1, BR.Net.TERMINAL_OPEN), 0, 'at Season 1 no computer opens')
    local said = last(1, BR.Net.TERMINAL_DEV) or ''
    ok(said:find('Season 2', 1, true) and said:find('brseason 2', 1, true),
        'and the requester is told which season and how to get there', said)
end

describe('brterminalsv open: the payload the computer opens with')
do
    bootServer()
    sv(1, 'open')
    local d = last(1, BR.Net.TERMINAL_OPEN)
    local st = d and d.state
    ok(st ~= nil and st.terminalId == 'dev', 'a dev terminal opens for the requester', st and st.terminalId)
    ok(st and st.keyHeld == true and st.squadUsed == false, 'with a key and nothing against it')
    local f = fnState(st, 'storm_reveal')
    ok(f ~= nil and f.available == true and f.reason == nil, 'Storm reveal is listed and available', f and tostring(f.reason))
    eq(#sentTo(2, nil), 0, 'and nobody else is sent anything')
    ok((last(1, BR.Net.TERMINAL_DEV) or ''):find('key held', 1, true) ~= nil, 'the requester reads what opened')

    -- Every reason, and the order a player hears them in.
    local cases = {
        { 'nokey', 'no_key' },
        { 'used', 'squad_used' },
        { 'offline', 'offline' },
        { 'nokey used', 'squad_used' },
        { 'nokey used offline', 'offline' },
    }
    for _, c in ipairs(cases) do
        sv(1, 'open ' .. c[1])
        local g = fnState(last(1, BR.Net.TERMINAL_OPEN).state, 'storm_reveal')
        ok(g and g.available == false and g.reason == c[2],
            ('"%s" lists it unavailable, %s'):format(c[1], c[2]), g and tostring(g.reason))
    end

    local before = #sentTo(1, BR.Net.TERMINAL_OPEN)
    sv(1, 'open sideways')
    eq(#sentTo(1, BR.Net.TERMINAL_OPEN), before, 'a word it does not know opens nothing')
    ok((last(1, BR.Net.TERMINAL_DEV) or ''):find('usage', 1, true) ~= nil, 'and says the usage')

    -- The server console names a player.
    sv(0, 'open')
    ok(table.concat(S.console, '\n'):find('needs a player', 1, true) ~= nil,
        'from the console, open without a player is refused')
    sv(0, 'open 2 nokey')
    local two = last(2, BR.Net.TERMINAL_OPEN)
    ok(two and fnState(two.state, 'storm_reveal').reason == 'no_key', 'and with one, opens for that player')
    sv(0, 'open 9')
    eq(#sentTo(9, nil), 0, 'nobody who is not connected is opened for')
end

describe('a run is taken only inside the session the server opened')
do
    bootServer()
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    local answers = function(src) return #sentTo(src, BR.Net.TERMINAL_RESULT) end

    run(1, { terminalId = 'dev', functionId = 'storm_reveal' })
    eq(answers(1), 0, 'no session: dropped, with no answer')

    sv(1, 'open')
    run(1, { terminalId = 'somewhere', functionId = 'storm_reveal' })
    eq(answers(1), 0, 'a terminal it was not opened on: dropped')
    for _, bad in ipairs({ 'Storm_reveal', 'storm reveal', ('x'):rep(33), '1storm', '' }) do
        S.clock = S.clock + 1000
        run(1, { terminalId = 'dev', functionId = bad })
        eq(answers(1), 0, ('a malformed id is dropped: %q'):format(bad))
    end
    S.clock = S.clock + 1000
    run(1, 'storm_reveal')
    run(1, { terminalId = 'dev', functionId = 7 })
    eq(answers(1), 0, 'and so is a request of the wrong shape')
    run(2, { terminalId = 'dev', functionId = 'storm_reveal' })
    eq(answers(2), 0, 'another player cannot run on a session that is not theirs')

    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'no_such_function' })
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'unavailable' and r.functionId == 'no_such_function',
        'a well-formed id that is not in the registry is answered unavailable', r and r.code)
end

describe('every registry row is listed; an unbuilt one is offline and never runs')
do
    bootServer()
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    -- EVERY ROW IS BUILT since wave C (#396, 2026-10-06), so the unbuilt one
    -- is made here, both ways a row can be unbuilt: one marked
    -- `implemented = false`, and one marked built with no server half. The
    -- first two rows a non-squad dev terminal lists; put back at the end.
    local unbuiltRows, putBack = {}, {}
    for _, row in ipairs(BR.Config.Terminals.functions) do
        if not row.squadOnly and #unbuiltRows < 2 then unbuiltRows[#unbuiltRows + 1] = row end
    end
    do
        local flagged, headless = unbuiltRows[1], unbuiltRows[2]
        putBack[#putBack + 1] = function() flagged.implemented = true end
        flagged.implemented = false
        local fn = BR.Terminal.FUNCTIONS[headless.id]
        putBack[#putBack + 1] = function() BR.Terminal.FUNCTIONS[headless.id] = fn end
        BR.Terminal.FUNCTIONS[headless.id] = nil
    end
    sv(1, 'open')
    local st = last(1, BR.Net.TERMINAL_OPEN).state
    -- A dev terminal outside a match is not a squad match: the squad-only
    -- rows are not listed (round 2), every other one is.
    local listed = {}
    for _, row in ipairs(BR.Config.Terminals.functions) do
        if not row.squadOnly then listed[#listed + 1] = row end
    end
    ok(#listed < #BR.Config.Terminals.functions, 'the registry has squad-only rows to leave out')
    eq(st.squadMatch, false, 'and the state says this is not a squad match')
    eq(#st.functions, #listed, 'one row per registry row, built or not, but the squad-only ones')
    for i, row in ipairs(listed) do
        local f = st.functions[i]
        ok(f and f.id == row.id, ('row %d is %s, in the registry\'s order'):format(i, row.id))
        if row.implemented and BR.Terminal.FUNCTIONS[row.id] then
            ok(f and f.available == true, ('%s is built and available'):format(row.id))
        else
            ok(f and f.available == false and f.reason == 'fn_offline',
                ('%s is not built: listed, offline'):format(row.id), f and tostring(f.reason))
        end
    end
    -- An unbuilt function is offline before anything else is asked: with no
    -- key and the squad's use spent, it still says fn_offline.
    for _, row in ipairs(unbuiltRows) do
        local unbuilt = row.id
        sv(1, 'open nokey used')
        ok(fnState(last(1, BR.Net.TERMINAL_OPEN).state, unbuilt).reason == 'fn_offline',
            unbuilt .. ', unbuilt, says fn_offline whatever else is true')
        sv(1, 'open')
        S.clock = S.clock + 1000
        run(1, { terminalId = 'dev', functionId = unbuilt })
        local r = last(1, BR.Net.TERMINAL_RESULT)
        ok(r and r.ok == false and r.code == 'fn_offline', unbuilt .. "'s run is refused fn_offline", r and r.code)
        ok(r and r.state.keyHeld == true and r.state.squadUsed == false, 'and nothing is spent')
    end
    for _, f in ipairs(putBack) do f() end
    eq(last(1, BR.Net.TERMINAL_OPEN).state.player, 'Alpha', 'the open payload names the player (their gamertag)')
end

describe('options: only what the registry allows, defaults filled, the rest refused whole')
do
    bootServer()
    local T = BR.Terminal
    local row = { id = 'x', options = {
        { id = 'site', choices = { 'terminal', 'circle' }, default = 'terminal' },
        { id = 'duration', choices = { '60', '120' }, default = '60' },
    } }
    local o = T.options(row, nil)
    ok(o and o.site == 'terminal' and o.duration == '60', 'nothing chosen: every default')
    o = T.options(row, { site = 'circle' })
    ok(o and o.site == 'circle' and o.duration == '60', 'one chosen: that one, and the other default')
    o = T.options(row, {})
    ok(o and o.site == 'terminal', 'an empty choice set (JSON {}) is the defaults')
    for _, bad in ipairs({
        { site = 'moon' },                 -- not a listed choice
        { site = 1 },                      -- not a string
        { colour = 'red' },                -- not a declared option
        { 'terminal' },                    -- an array, keyed by number
        'terminal',                        -- not a table
        7,
    }) do
        ok(T.options(row, bad) == nil, ('refused whole: %s'):format(type(bad) == 'table'
            and (next(bad) and tostring(next(bad)) or '{}') or tostring(bad)))
    end
    local many = {}
    for i = 1, 9 do many['k' .. i] = 'v' end
    ok(T.options(row, many) == nil, 'more options than any row declares: refused')
    ok(T.options({ id = 'y' }, { a = 'b' }) == nil, 'a row with no options takes none')
    o = T.options({ id = 'y' }, nil)
    ok(o ~= nil and next(o) == nil, 'and runs with none')

    -- ROUND 4: AN OPTION OFFERED ONLY UNDER ANOTHER'S CHOICE (`when`) --
    -- Time & weather's time OR weather, never both.
    local either = { id = 'z', options = {
        { id = 'change', choices = { 'time', 'weather' }, default = 'time' },
        { id = 'time', when = { change = 'time' }, choices = { 'day', 'night' }, default = 'night' },
        { id = 'weather', when = { change = 'weather' }, choices = { 'fog', 'snow' }, default = 'fog' },
    } }
    o = T.options(either, nil)
    ok(o and o.change == 'time' and o.time == 'night' and o.weather == nil,
        "nothing chosen: the default change, its option's default, and the other left out")
    o = T.options(either, { change = 'weather' })
    ok(o and o.weather == 'fog' and o.time == nil, 'the weather chosen: its default, and no time')
    o = T.options(either, { change = 'weather', weather = 'snow' })
    ok(o and o.weather == 'snow' and o.time == nil, 'the weather and its choice')
    o = T.options(either, { time = 'day' })
    ok(o and o.time == 'day' and o.weather == nil, 'a time alone is the default change, time')
    eq(T.options(either, { change = 'weather', time = 'day' }), nil,
        'a choice for the option that does not apply refuses the whole request')
    eq(T.options(either, { weather = 'snow' }), nil, 'and so does a weather under the default change, time')

    -- Through the net event: a bad choice is ANSWERED (the button waits on
    -- it) as bad_option, and nothing is spent.
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    sv(1, 'open')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'storm_reveal', options = { zone = 'north' } })
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'bad_option', 'a run with options its row does not declare: bad_option', r and r.code)
    ok(r and r.state.keyHeld == true and r.state.squadUsed == false, 'and nothing is spent')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'storm_reveal', options = {} })
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == true, 'with an empty choice set it runs', r and r.code)
end

describe('round 4: the spot a run carries -- its shape, and only for a row run at one')
do
    -- Owner, 2026-10-06: Storm control and Supply drop "pick exactly where".
    -- A row with `spot = true` runs at a place set on the big map, carried as
    -- `at = { x, y }`; BR.Terminal.spot takes only that shape.
    bootServer()
    local T = BR.Terminal
    local spotRow, plainRow = { id = 'a', spot = true }, { id = 'b' }
    local s, bad = T.spot(spotRow, { x = 120, y = -45.5 })
    ok(s and s.x == 120.0 and s.y == -45.5 and bad == false, 'two numbers: the spot')
    s, bad = T.spot(plainRow, nil)
    ok(s == nil and bad == false, 'a row run at no spot, and none sent: fine')
    s, bad = T.spot(plainRow, { x = 1, y = 2 })
    ok(s == nil and bad == true, 'a spot sent for a row that takes none: malformed')
    for _, at in ipairs({
        false, 'here', 7, {}, { x = 1 }, { y = 1 }, { x = '1', y = 2 }, { x = 0 / 0, y = 0 },
        { x = math.huge, y = 0 }, { x = 0, y = -math.huge }, { x = 20001, y = 0 }, { x = 0, y = -20001 },
    }) do
        local s2, bad2 = T.spot(spotRow, at)
        ok(s2 == nil and bad2 == true, ('malformed: %s'):format(type(at) == 'table'
            and ('{ x = %s, y = %s }'):format(tostring(at.x), tostring(at.y)) or tostring(at)))
    end
    s, bad = T.spot(spotRow, nil)
    ok(s == nil and bad == true, 'a row run at a spot, sent none: malformed')
    -- EVERY ROW THAT TAKES A SPOT, AND NO OPTION CALLED `at` (the spot reaches
    -- the function as opts.at).
    local spots = {}
    for _, row in ipairs(BR.Config.Terminals.functions) do
        if row.spot == true then spots[#spots + 1] = row.id end
        for _, o in ipairs(row.options or {}) do
            ok(o.id ~= 'at', row.id .. ' declares no option called at')
        end
        ok(row.spot == nil or row.spot == true, row.id .. ': spot is true or absent')
    end
    eq(table.concat(spots, ','), 'storm_control,supply_drop', 'Storm control and Supply drop are run at a spot')

    -- THROUGH THE NET EVENT, on a dev session: no spot, a bad one, a good one.
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    sv(1, 'open volts=500')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'storm_control' })
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'bad_option', 'Storm control with no spot: bad_option', r and r.code)
    ok(r and r.state.keyHeld == true and r.state.volts == 500, 'and nothing is spent')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'storm_control', at = { x = 'n', y = 1 } })
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.code == 'bad_option', 'a spot that is not one: bad_option', r and r.code)
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'storm_reveal', at = { x = 1, y = 1 } })
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.code == 'bad_option', 'a spot sent with Storm reveal: bad_option', r and r.code)
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'storm_control', at = { x = 100.5, y = -20 } })
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == true and r.code == 'running', 'with a spot: accepted', r and r.code)
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == true and r.code == 'done', 'and done', r and r.code)
    eq(r and r.state.volts, 350, 'for its 150 Volts')
end

describe('the panel: pushed to each open computer, to its own player, only while open')
do
    bootServer()
    BR.Terminal.pushInfo()
    eq(#sentTo(nil, BR.Net.TERMINAL_INFO), 0, 'no open computer: nothing is pushed')
    sv(1, 'open')
    sv(2, 'open nokey')
    BR.Terminal.pushInfo()
    local a, b = last(1, BR.Net.TERMINAL_INFO), last(2, BR.Net.TERMINAL_INFO)
    ok(a and a.terminalId == 'dev' and a.state.keyHeld == true and a.state.player == 'Alpha',
        'player 1 is sent their own state')
    ok(b and b.state.keyHeld == false and b.state.player == 'Bravo', 'player 2 theirs')
    eq(#sentTo(nil, BR.Net.TERMINAL_INFO), 2, 'one each')
    sv(1, 'close')
    BR.Terminal.pushInfo()
    eq(#sentTo(1, BR.Net.TERMINAL_INFO), 1, 'a closed computer is sent nothing more')
    eq(#sentTo(2, BR.Net.TERMINAL_INFO), 2, 'while the one still open is sent its own again')
    BR.Season.switch(1)
    BR.Terminal.pushInfo()
    eq(#sentTo(2, BR.Net.TERMINAL_INFO), 2, 'and off Season 2, nobody is')
end

describe('a run that is refused, and one that runs')
do
    bootServer()
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    local req = { terminalId = 'dev', functionId = 'storm_reveal' }

    sv(1, 'open nokey')
    run(1, req)
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'no_key', 'with no key: refused, no_key', r and r.code)
    ok(r and r.state and fnState(r.state, 'storm_reveal').reason == 'no_key', 'and the answer carries the state')

    sv(1, 'open')
    S.clock = S.clock + 1000
    run(1, req)
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == true and r.code == 'running' and r.terminalId == 'dev',
        'with a key: it is accepted, and loads', r and r.code)
    local C = BR.Config.Terminals
    ok(r and type(r.runMs) == 'number' and r.runMs >= C.runMinMs and r.runMs <= C.runMaxMs,
        'for as long as the server picked, inside runMinMs..runMaxMs', r and tostring(r.runMs))
    ok(r and r.state.keyHeld == false and r.state.squadUsed == true,
        'the key and the squad use are spent as it is accepted')
    ok(r and fnState(r.state, 'storm_reveal').reason == 'squad_used',
        'so the answer already lists it as used')
    ok(r and r.state.running and r.state.running.functionId == 'storm_reveal'
            and r.state.running.leftMs == r.runMs,
        'and the state carries the run that is loading')

    local n = #sentTo(1, BR.Net.TERMINAL_RESULT)
    S.clock = S.clock + BR.Config.Terminals.runMinIntervalMs - 1
    run(1, req)
    eq(#sentTo(1, BR.Net.TERMINAL_RESULT), n, 'a second request inside the interval is dropped')
    S.clock = S.clock + 1
    run(1, req)
    eq(#sentTo(1, BR.Net.TERMINAL_RESULT), n, 'and one while the first loads is dropped too')
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == true and r.code == 'done', 'when the loading is over: done', r and r.code)
    ok(r and r.state.running == nil, 'and nothing is loading any more')
    eq(r and r.balance, nil, 'a free function reports no balance')
    S.clock = S.clock + 1000
    run(1, req)
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'squad_used', 'and after it, refused: the squad has used its one',
        r and r.code)
end

describe('every way a session ends')
do
    bootServer()
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    local req = { terminalId = 'dev', functionId = 'storm_reveal' }

    sv(1, 'open')
    fireAs(1, BR.Net.TERMINAL_CLOSED, { terminalId = 'elsewhere' })
    ok(BR.Terminal.session(1) ~= nil, 'a close naming another terminal ends nothing')
    fireAs(2, BR.Net.TERMINAL_CLOSED, { terminalId = 'dev' })
    ok(BR.Terminal.session(1) ~= nil, 'nor does one from another player')
    fireAs(1, BR.Net.TERMINAL_CLOSED, { terminalId = 'dev', why = 'escape' })
    ok(BR.Terminal.session(1) == nil, 'the client closing it ends it')
    run(1, req)
    eq(#sentTo(1, BR.Net.TERMINAL_RESULT), 0, 'and a run after that is dropped')

    sv(1, 'open')
    sv(1, 'close')
    ok(BR.Terminal.session(1) == nil and last(1, BR.Net.TERMINAL_CLOSE) ~= nil,
        'brterminalsv close ends it and tells the client')
    sv(1, 'close')
    ok((last(1, BR.Net.TERMINAL_DEV) or ''):find('no terminal open', 1, true) ~= nil,
        'closing nothing says so')

    sv(1, 'open')
    fireAs(1, 'playerDropped')
    ok(BR.Terminal.session(1) == nil, 'a player dropping ends theirs')

    -- THE SEASON MOVED UNDER AN OPEN SESSION (`brseason 1` on a dev box).
    sv(1, 'open')
    BR.Season.switch(1)
    S.clock = S.clock + 1000
    local closes = #sentTo(1, BR.Net.TERMINAL_CLOSE)
    run(1, req)
    eq(#sentTo(1, BR.Net.TERMINAL_RESULT), 0, 'a run after the season left Season 2 is not answered')
    ok(#sentTo(1, BR.Net.TERMINAL_CLOSE) == closes + 1 and BR.Terminal.session(1) == nil,
        'the computer is closed instead, rather than left waiting')
end

describe('the registry and the copy block agree')
do
    bootServer()
    local C = BR.Config.Terminals
    local copy = C.copy
    local has = function(key) return type(copy[key]) == 'string' and copy[key] ~= '' end
    local cats, seen = {}, {}
    for _, c in ipairs(C.categories) do
        cats[c] = true
        ok(has('category_' .. c), ('category %s has its line'):format(c))
    end
    for _, row in ipairs(C.functions) do
        local id = row.id
        ok(type(id) == 'string' and #id <= 32 and id:match('^[a-z][a-z0-9_]*$') ~= nil,
            ('%s is a well-formed id'):format(tostring(id)))
        ok(not seen[id], ('%s is listed once'):format(id))
        seen[id] = true
        ok(cats[row.category] == true, ('%s is in a listed category (%s)'):format(id, tostring(row.category)))
        ok(row.risk == 'low' or row.risk == 'medium' or row.risk == 'high',
            ('%s has a risk level'):format(id))
        ok(type(row.implemented) == 'boolean', ('%s says whether it is built'):format(id))
        if row.implemented then
            ok(BR.Terminal.FUNCTIONS[id] ~= nil and type(BR.Terminal.FUNCTIONS[id].run) == 'function',
                ('%s is built and has a server entry'):format(id))
        end
        -- THE CARD AND THE PAGE: every line the app draws for a function.
        for _, part in ipairs({ 'name', 'summary', 'what', 'duration', 'affects', 'notified',
                                'done', 'description' }) do
            ok(has(id .. '_' .. part), ('%s has its _%s line'):format(id, part))
        end
        for _, o in ipairs(row.options or {}) do
            ok(type(o.id) == 'string' and o.id:match('^[a-z][a-z0-9_]*$') ~= nil,
                ('%s: option %s is a well-formed id'):format(id, tostring(o.id)))
            ok(type(o.choices) == 'table' and #o.choices >= 2, ('%s.%s offers a choice'):format(id, o.id))
            local listed = false
            for _, ch in ipairs(o.choices or {}) do
                ok(type(ch) == 'string' and ch:match('^[a-z0-9_]+$') ~= nil,
                    ('%s.%s: choice %s is a well-formed string'):format(id, o.id, tostring(ch)))
                ok(has(('%s_opt_%s_%s'):format(id, o.id, ch)),
                    ('%s.%s: choice %s has its line'):format(id, o.id, tostring(ch)))
                if ch == o.default then listed = true end
            end
            ok(listed, ('%s.%s: its default is one of its choices'):format(id, o.id))
            ok(has(('%s_opt_%s'):format(id, o.id)), ('%s.%s has its label'):format(id, o.id))
            -- `when` (round 4) names another option of this row and one of
            -- its choices, or the option could never be offered.
            if o.when ~= nil then
                local good = type(o.when) == 'table' and next(o.when) ~= nil
                for k, v in pairs(type(o.when) == 'table' and o.when or {}) do
                    local other = nil
                    for _, p in ipairs(row.options) do if p.id == k and p ~= o then other = p end end
                    local named = false
                    for _, ch in ipairs(other and other.choices or {}) do if ch == v then named = true end end
                    if not named then good = false end
                end
                ok(good, ('%s.%s: its `when` names another option and one of its choices'):format(id, o.id))
            end
        end
        -- "just don't tell them how it can help them" (owner, 2026-10-05): a
        -- function's own lines describe; they never sell.
        for _, part in ipairs({ 'summary', 'what', 'risks', 'duration', 'affects', 'notified' }) do
            local text = (copy[id .. '_' .. part] or ''):lower()
            for _, word in ipairs({ 'help', 'helps', 'helpful', 'advantage', 'useful', 'benefit',
                                    'edge', 'win', 'winning' }) do
                ok(not (' ' .. text:gsub('[%p]', ' ') .. ' '):find(' ' .. word .. ' ', 1, true),
                    ('%s_%s does not say "%s"'):format(id, part, word))
            end
        end
    end
    -- Every reason the server can give, and every line the desktop and the app
    -- read, and every line the world shows (#396's Gameplay half).
    for _, key in ipairs({
        'no_key', 'squad_used', 'offline', 'unavailable', 'fn_offline', 'bad_option',
        'no_storm', 'no_site', 'ammo_full',
        -- Wave A's (2026-10-06).
        'health_full', 'no_weapons', 'no_keys', 'no_keys_ground', 'no_keys_held', 'key_finder_warned',
        'key_finder_blip', 'pulse_detected', 'pulse_blip', 'no_target', 'contract_protect',
        'contract_target',
        -- Round 4's (2026-10-06): the map pick's step, Storm control's spots.
        'confirm_location', 'storm_spot_land', 'storm_spot_out', 'storm_spot_edge',
        'shell_boot', 'desktop_icon', 'window_title', 'app_title', 'run',
        'address_host', 'path_home', 'path_functions', 'path_howto', 'path_privacy', 'path_login',
        'nav_home', 'nav_howto', 'nav_privacy', 'nav_categories', 'privacy_title', 'privacy_body',
        'status_available', 'status_used', 'status_not_here', 'status_offline',
        'risk_low', 'risk_medium', 'risk_high', 'risk_notice', 'cost_line',
        'howto_title', 'howto_tips_body', 'match_heading',
        'first_pickup', 'already_holding', 'notice_access', 'notice_action',
        'bounty_new', 'bounty_protect', 'scan_blip', 'bounty_blip',
        'key_label', 'terminal_label', 'terminal_use', 'storm_reveal_blip',
    }) do
        ok(has(key), ('copy has %s'):format(key))
    end
    -- THE OWNER'S OWN WORDS (#396, 2026-10-04), verbatim.
    eq(copy.no_key, 'You need a Yubikey to access this system. Search far and wide, and you just might find one.',
        'the login screen is the owner\'s line')
    eq(copy.notice_access, '{playername} has gained access to a match terminal using their Yubikey. 1 special power has been granted to them.',
        'the access notice is the owner\'s line')
    eq(copy.notice_action, '{playername} has redeemed their special power: {description}',
        'the action notice is the owner\'s line')
    eq(copy.bounty_new, 'A new bounty is among us: {playername}.', 'the bounty notice is the owner\'s line')
    eq(copy.bounty_protect, "Protect {playername}! They've got a bounty for the next 10 minutes.",
        'the squad\'s bounty notice is the owner\'s line')
    for k, v in pairs(copy) do
        ok(type(k) == 'string' and type(v) == 'string', ('copy.%s is a string'):format(tostring(k)))
    end
    ok(type(C.runMinIntervalMs) == 'number' and C.runMinIntervalMs > 0, 'the run interval is a positive number')
end

-- =========================================================================
-- PART A, ROUND 2 (owner, 2026-10-05) -- the words, the costs, the squad
-- lines and the loading
-- =========================================================================

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local text = fh:read('a')
    fh:close()
    return text
end

describe('round 4: the cards\' cost and bounty, and Squads! on every squad-wide row')
do
    bootServer()
    local C = BR.Config.Terminals
    local copy = C.copy
    local byId = {}
    for _, row in ipairs(C.functions) do byId[row.id] = row end
    -- "The cards should show cost in volts and bounty": `bounty` is who a run
    -- puts one on, as the card says it.
    for _, row in ipairs(C.functions) do
        ok(row.bounty == nil or row.bounty == 'runner' or row.bounty == 'target',
            ('%s: bounty is runner, target or nothing'):format(row.id), tostring(row.bounty))
        ok(row.squadWide == nil or row.squadWide == true, ('%s: squadWide is true or absent'):format(row.id))
    end
    if byId.scan then eq(byId.scan.bounty, 'runner', 'Scan: the player who runs it gets the bounty') end
    if byId.contract then eq(byId.contract.bounty, 'target', 'Contract: it puts one on another player') end
    local bounties = {}
    for _, row in ipairs(C.functions) do
        if row.bounty then bounties[#bounties + 1] = row.id end
    end
    eq(table.concat(bounties, ','), (byId.scan and 'scan' or '') .. (byId.scan and byId.contract and ',' or '')
        .. (byId.contract and 'contract' or ''), 'and no other row gives a bounty')

    -- "Any tool that can impact the whole squad": every row whose effect is
    -- the squad's -- its affects line is "Your squad", or its marks show on
    -- the squad's maps -- and none other. Reboot is squad-only, Pulse marks
    -- other players on the squad's maps.
    local want = { scan = true, storm_reveal = true, max_ammo = true, reboot = true, ghost = true,
                   key_finder = true, pulse = true, field_medic = true }
    for _, row in ipairs(C.functions) do
        local affects = copy[row.id .. '_affects'] or ''
        local what = copy[row.id .. '_what'] or ''
        local squads = affects == 'Your squad' or what:find("your squad's maps", 1, true) ~= nil
        eq(row.squadWide == true, want[row.id] == true, ('%s: squadWide as its effect says'):format(row.id))
        if row.squadWide then ok(squads, ('%s: its own lines say the squad is affected'):format(row.id), affects) end
        if affects == 'Your squad' then ok(row.squadWide == true, ('%s affects "Your squad", so it is squadWide'):format(row.id)) end
    end

    -- THE OWNER'S WORDS, verbatim, and never outside a squad match.
    eq(copy.squads_link, 'Squads!', 'the link says "Squads!" (owner\'s word)')
    eq(copy.squads_popover, 'This function will apply to your entire squad.', 'and its box, verbatim')
    eq(copy.squads_link_solo, '', 'outside a squad match the link has no words, so it is not drawn')
    eq(copy.squads_popover_solo, '', 'nor its box')
    eq(BR.TerminalSolve.pick(copy, 'squads_link', false), '', 'the solo picker reads it empty')
    eq(BR.TerminalSolve.pick(copy, 'squads_link', true), 'Squads!', 'the squad picker reads it')

    -- THE CARDS' AND THE FILTERS' WORDS.
    for _, key in ipairs({ 'card_cost', 'card_bounty', 'cost_free', 'cost_paid', 'bounty_none', 'bounty_runner',
                           'bounty_target', 'filter_any' }) do
        ok(type(copy[key]) == 'string' and copy[key] ~= '', ('copy has %s'):format(key))
        ok(not copy[key]:lower():find('squad', 1, true), ('%s says no squad'):format(key))
    end
end

describe('round 4: Lockdown and Storm delay are gone (owner, 2026-10-06)')
do
    -- "I don't like the Lockdown tool, please remove it as well. The player
    -- gains nothing from using that." "Storm delay doesn't make sense to have
    -- really. We have to keep the pace of the match." Nothing of either is
    -- left: no row, no line, no server half, no file, no wire, no online rule.
    bootServer()
    local C = BR.Config.Terminals
    for _, id in ipairs({ 'lockdown', 'storm_delay' }) do
        eq(BR.Terminal.row(id), nil, id .. ': no registry row')
        eq(BR.Terminal.FUNCTIONS[id], nil, id .. ': no server half')
        local lines = {}
        for k in pairs(C.copy) do
            if k:sub(1, #id + 1) == id .. '_' then lines[#lines + 1] = k end
        end
        eq(#lines, 0, id .. ': no copy line ' .. table.concat(lines, ', '))
        for _, side in ipairs({ 'server', 'client' }) do
            ok(io.open(ROOT .. 'br_core/' .. side .. '/terminalfx/' .. id .. '.lua', 'rb') == nil,
                ('%s: no %s file'):format(id, side))
        end
    end
    for _, key in ipairs({ 'locked', 'lockdown_none', 'no_hold' }) do
        eq(C.copy[key], nil, ('copy.%s is gone with them'):format(key))
    end
    eq(BR.Net.TERMINAL_LOCKDOWN, nil, 'no TERMINAL_LOCKDOWN on the wire')
    local manifest = readFile(ROOT .. 'br_core/fxmanifest.lua') or ''
    ok(not manifest:find('lockdown.lua', 1, true) and not manifest:find('storm_delay.lua', 1, true),
        'and br_core manifest lists neither')
    -- THE ONE ONLINE RULE IS THE STORM'S ALONE: a fourth argument (the old
    -- Lockdown's `lock`) changes nothing.
    local site = { id = 'hut', x = 0.0, y = 0.0 }
    eq(BR.TerminalSolve.offlineWhy(site, nil, false, { keep = 'tower' }), nil,
        'no storm, not forced: online, whatever else is passed')
end

describe('round 2: the owner\'s words, verbatim, and no thunderstorm')
do
    bootServer()
    local C = BR.Config.Terminals
    local copy = C.copy
    eq(copy.status_offline, 'Not available', '"offline" is "Not available" (owner\'s words)')
    eq(copy.status_not_here, 'Not available at this terminal', '"Not here" is "Not available at this terminal"')
    eq(copy.fn_offline, 'This function is not available.', 'an unbuilt function\'s page line says it too')
    ok(not copy.fn_offline:lower():find('offline', 1, true), 'and never says offline beside that badge')
    eq(copy.offline, 'This terminal is outside the storm and offline.',
        'a TERMINAL outside the storm keeps its wording (a question for the owner)')
    for _, key in ipairs({ 'app_title', 'desktop_icon', 'window_title' }) do
        eq(copy[key], 'Control Tower', ('%s is the app\'s name, "Control Tower"'):format(key))
    end
    eq(copy.match_heading, 'Match stats', 'the match table says "Match stats"')
    eq(copy.address_host, 'https://controltower.blitz', 'the address bar\'s fictional host is controltower.blitz (owner, 2026-10-05)')
    for k, v in pairs(copy) do
        ok(not v:find('Blitz Terminal', 1, true), ('copy.%s no longer names the app Blitz Terminal'):format(k))
        ok(not k:find('thunder', 1, true), ('copy.%s is not a thunderstorm line'):format(k))
    end

    -- NO THUNDERSTORM, AND SINCE ROUND 4 NO RAIN: not a choice, so the
    -- server's option check refuses them.
    local tw = BR.Terminal.row('time_weather')
    local weather
    for _, o in ipairs(tw.options) do if o.id == 'weather' then weather = o end end
    for _, ch in ipairs(weather.choices) do
        ok(ch ~= 'thunder' and ch ~= 'rain', ('weather choice %s is neither thunder nor rain'):format(ch))
    end
    eq(BR.Terminal.options(tw, { change = 'weather', weather = 'thunder' }), nil, 'weather=thunder is not an option')
    eq(BR.Terminal.options(tw, { change = 'weather', weather = 'rain' }), nil, 'nor, since round 4, weather=rain')
    ok(BR.Terminal.options(tw, { change = 'weather', weather = 'fog' }) ~= nil, 'and a listed weather still is')
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    sv(1, 'open')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'time_weather', options = { change = 'weather', weather = 'thunder' } })
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'bad_option', 'a run asking for thunder is refused bad_option', r and r.code)
    ok(r and r.state.keyHeld == true and r.state.squadUsed == false, 'and nothing is spent')

    -- The owner's rule for whoever builds it, where they will read it.
    local src = readFile(ROOT .. 'br_lib/config/terminals.lua') or ''
    ok(src:find('whatever weather they set%s+%-%- is only set while inside the storm') ~= nil
        and src:find("BR.World.want('storm'", 1, true) ~= nil,
        'time_weather\'s row carries the owner\'s rule: the storm\'s weather wins outside the circle')
end

describe('round 3: the plate is the owner\'s, and a press opens the computer')
do
    bootServer()
    local C = BR.Config.Terminals
    local copy = C.copy
    -- VERBATIM (owner, 2026-10-06): 'a DUI should be shown: "Computer system"
    -- "press to open" with the interact key on it'. Case and all.
    eq(copy.terminal_label, 'Computer system', 'the plate\'s title is the owner\'s "Computer system"')
    eq(copy.terminal_use, 'press to open', 'and its hint his "press to open", lower case as he wrote it')
    eq(copy.terminal_label_solo, nil, 'neither has a rewritten twin')
    eq(copy.terminal_use_solo, nil, 'not the hint either')
    -- THE HOLD IS GONE: no hold time, and no line tells a player to hold
    -- interact (holding a Yubikey is another thing, and still said).
    eq(C.holdMs, nil, 'no holdMs: nothing is held')
    local holds = {}
    for k, v in pairs(copy) do
        if v:lower():find('hold interact', 1, true) then holds[#holds + 1] = k end
    end
    eq(table.concat(holds, ', '), '', 'no copy line says "hold interact"')
    ok(copy.howto_terminal_body:find('Walk up to one and press interact to open it.', 1, true) ~= nil,
        'the how-to says press')
    -- The other plates keep their own lines.
    eq(copy.no_key, 'You need a Yubikey to access this system. Search far and wide, and you just might find one.',
        'the no-key plate keeps the owner\'s no_key line')
    eq(copy.squad_used, 'Your squad already used its terminal this match.', 'the squad-used plate keeps its line')
    eq(copy.offline, 'This terminal is outside the storm and offline.',
        'offline keeps its line: the server\'s toast for a press a step behind the storm, and the app\'s reason')
    -- The press goes straight to the server's door, which keeps its interval.
    local src = (readFile(ROOT .. 'br_core/client/yubikey.lua') or ''):gsub('%-%-[^\n]*', '')
    -- ROUND 4 (owner, 2026-10-06: "A terminal outside the storm should have no
    -- blip and no DUI"): the world plate no longer reads the offline line.
    ok(not src:find('copy().offline', 1, true) and not src:find("copy()['offline']", 1, true),
        'client/yubikey.lua reads no offline line: outside the storm there is no plate')
    ok(not src:find('holdMs', 1, true) and not src:find('%f[%w_]ring%f[^%w_]'),
        'client/yubikey.lua sends the plate no ring and no hold time')
    ok(src:find("BR.Keys.on('interact'", 1, true) ~= nil
        and src:find('TriggerServerEvent(BR.Net.TERMINAL_USE, { terminalId = plate.id })', 1, true) ~= nil,
        'and its interact press asks the server for the terminal on the plate')
    local server = (readFile(ROOT .. 'br_core/server/terminal.lua') or ''):gsub('%-%-[^\n]*', '')
    ok(server:find('if last ~= nil and now - last < cfg().runMinIntervalMs then return end\n    lastUseAt[src] = now', 1, true) ~= nil,
        'the server still drops a use sooner than runMinIntervalMs after the last')
end

describe('polish (owner, 2026-10-06): Home, and the Privacy page in his approved words')
do
    bootServer()
    local copy = BR.Config.Terminals.copy
    -- "the functions page should be called Home in the URL, sidebar, and
    -- breadcrumbs" -- his word. The cards' heading keeps its own line.
    eq(copy.nav_home, 'Home', 'the side navigation and the first breadcrumb say Home')
    eq(copy.path_home, 'home', 'and the address says /home')
    eq(copy.nav_functions, nil, 'no line still calls that page Functions')
    eq(copy.functions_heading, 'Functions', 'the cards\' heading stays "Functions"')
    eq(copy.path_functions, 'functions', 'a function\'s own page is still under /functions')
    -- The Privacy page's link, breadcrumb and path: WRITTEN, listed for him.
    eq(copy.nav_privacy, 'Privacy', 'the Privacy link and breadcrumb')
    eq(copy.path_privacy, 'privacy', 'and its path')
    -- VERBATIM: approved word for word ("Perfect"), its title and two
    -- paragraphs, never re-punctuated.
    eq(copy.privacy_title, 'Privacy Policy', 'the title is the approved "Privacy Policy"')
    local P1 = "Control Tower is proudly sponsored by Lifeinvader, the social network that already knows what you had for breakfast. By opening, touching, standing near, or thinking warmly about this terminal, you agree that everything you do here may be collected, stored, analyzed, monetized, re-monetized, printed out, laminated, and left on the dashboard of a stolen sedan in Vespucci. This includes, but is not limited to, your name, your location, your Volts balance, your loadout, your teammates' names (we will be using these), how long you hovered over Run before losing your nerve, and the exact noise you made when the storm caught you. Your data is stored securely on a server somewhere inside the storm and backed up nightly to a USB stick we found on the ground."
    local P2 = "We take your privacy extremely seriously, which is why we guarantee complete privacy to every person who has never used, opened, approached, or heard of Control Tower. If you are reading this, that guarantee no longer applies to you, and we thank you for your contribution. Your information may be shared with Lifeinvader, its affiliates, its affiliates' cousins, the Los Santos Police Department, Merryweather Security, every other player in this match (you may have noticed), and anyone who asks nicely or loudly. You may request a copy of your data at any time by writing to an address we have not disclosed, and we will respond within 90 business years. You may opt out by uninstalling the planet. This policy may change at any time without notice, and probably already has since you started reading. If you made it this far, you have read more of this policy than anyone at Lifeinvader, and you are legally entitled to nothing."
    eq(copy.privacy_body, P1 .. '\n' .. P2, 'the body is the approved two paragraphs, exactly')
    -- No squad in any of it, so no solo sibling (the squad rule above agrees).
    for _, k in ipairs({ 'nav_home', 'path_home', 'nav_privacy', 'path_privacy', 'privacy_title', 'privacy_body' }) do
        eq(copy[k .. '_solo'], nil, ('%s has no solo sibling'):format(k))
        ok(not copy[k]:lower():find('squad', 1, true), ('%s says no squad, so needs none'):format(k))
    end
end

describe('round 2: the boot and the run, each a range in the registry')
do
    bootServer()
    local C = BR.Config.Terminals
    eq(C.bootMinMs, 7000, 'a boot takes at least 7 s ("random between 7 and 10 seconds")')
    eq(C.bootMaxMs, 10000, 'and at most 10 s')
    eq(C.runMinMs, 3000, 'a run loads for at least 3 s ("3-5 seconds (random)")')
    eq(C.runMaxMs, 5000, 'and at most 5 s')
    -- Round 3 (owner, 2026-10-06): "random between 1 and 3 seconds", a page
    -- load in the app's browser (the app picks; ui-src's model test holds it).
    eq(C.pageMinMs, 1000, 'a page loads for at least 1 s')
    eq(C.pageMaxMs, 3000, 'and at most 3 s')

    -- The server picks a run's length in the range, every run anew.
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    local lo, hi, seen = math.huge, -math.huge, {}
    for _ = 1, 60 do
        sv(1, 'open')
        S.clock = S.clock + 1000
        run(1, { terminalId = 'dev', functionId = 'storm_reveal' })
        local r = last(1, BR.Net.TERMINAL_RESULT)
        local ms = r and r.runMs or -1
        lo, hi = math.min(lo, ms), math.max(hi, ms)
        seen[ms] = true
        flush()
    end
    ok(lo >= C.runMinMs and hi <= C.runMaxMs, ('every run loads inside the range (%d..%d)'):format(lo, hi))
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    ok(distinct > 10, 'and a fresh length each time, not one fixed number', distinct)
end

describe('round 2: the Volts -- every cost 0..200, the most powerful ones priced')
do
    bootServer()
    local C = BR.Config.Terminals
    for _, row in ipairs(C.functions) do
        local c = row.cost
        ok(c == nil or (type(c) == 'number' and c == math.floor(c) and c >= 0 and c <= 200),
            ('%s costs 0..200 Volts ("no more than 200"): %s'):format(row.id, tostring(c)))
    end
    local want = { scan = 200, disarm = 200, storm_control = 150, reboot = 150 }
    for _, row in ipairs(C.functions) do
        eq(BR.Terminal.costOf(row), want[row.id] or 0, ('%s costs %d'):format(row.id, want[row.id] or 0))
    end
end

describe('round 2: the Volts in a dev session -- refused short, spent exact, new balance said')
do
    bootServer()
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    local scan = { terminalId = 'dev', functionId = 'scan' }

    -- SHORT: refused after every other reason, with nothing spent.
    sv(1, 'open volts=150')
    eq(last(1, BR.Net.TERMINAL_OPEN).state.volts, 150, 'the state carries the balance (the top bar\'s)')
    local f = fnState(last(1, BR.Net.TERMINAL_OPEN).state, 'scan')
    ok(f and f.available == true, 'Run stays pressable whatever the balance: Scan is listed available')
    S.clock = S.clock + 1000
    run(1, scan)
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'no_volts', 'a run the balance cannot cover: no_volts', r and r.code)
    ok(r and r.cost == 200 and r.balance == 150, 'with the cost and the balance to say', r and (tostring(r.cost) .. ' ' .. tostring(r.balance)))
    ok(r and r.state.keyHeld == true and r.state.squadUsed == false and r.state.volts == 150,
        'and the key, the squad\'s use and the Volts all stay')
    eq(#S.timers, 0, 'nothing loads')

    -- THE OTHER REASONS COME FIRST.
    sv(1, 'open nokey volts=0')
    S.clock = S.clock + 1000
    run(1, scan)
    eq(last(1, BR.Net.TERMINAL_RESULT).code, 'no_key', 'no key and no Volts: no_key, the earlier reason')
    sv(1, 'open used volts=0')
    S.clock = S.clock + 1000
    run(1, scan)
    eq(last(1, BR.Net.TERMINAL_RESULT).code, 'squad_used', 'the squad\'s use spent and no Volts: squad_used')

    -- EXACT: 200 of 200, spent as it is accepted, the new balance said at the end.
    sv(1, 'open volts=200')
    S.clock = S.clock + 1000
    run(1, scan)
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == true and r.code == 'running', 'exactly enough: accepted', r and r.code)
    ok(r and r.state.volts == 0 and r.state.keyHeld == false,
        'the Volts, the key and the use are spent as it is accepted (the top bar moves at once)')
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == true and r.code == 'done' and r.balance == 0, 'done, with the new balance: 0', r and tostring(r.balance))
    eq(BR.Terminal.session(1).facts.volts, 0, 'and the session spent exactly the cost, once')

    -- A FREE FUNCTION behaves as before: nothing about Volts.
    sv(1, 'open volts=0')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'storm_reveal' })
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.code == 'done' and r.balance == nil, 'a free function runs on no Volts and reports no balance')
end

describe('round 2: an effect that can no longer happen gives everything back')
do
    bootServer()
    local C = BR.Config.Terminals
    local T = BR.Terminal
    -- A built, paid function whose effect fails when the loading is over.
    C.functions[#C.functions + 1] = { id = 'paid_test', category = 'intel', risk = 'low',
                                     implemented = true, cost = 120 }
    local verdict = { ok = false, code = 'no_site' }
    T.FUNCTIONS.paid_test = { run = function() return verdict end }
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end

    sv(1, 'open volts=500')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'paid_test' })
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.code == 'running' and r.state.volts == 380 and r.state.keyHeld == false,
        'accepted: 120 Volts, the key and the use spent')
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'no_site', 'the effect could not happen: its reason', r and r.code)
    ok(r and r.state.volts == 500 and r.state.keyHeld == true and r.state.squadUsed == false,
        'and the Volts, the key and the squad\'s use are all given back')

    verdict = { ok = true, code = 'done' }
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'paid_test' })
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.code == 'done' and r.balance == 380 and r.state.volts == 380,
        'the same run, now possible: done, 380 left')
    table.remove(C.functions)
    T.FUNCTIONS.paid_test = nil
end

describe('round 2: closing the computer while a run loads -- it still completes, said as a toast')
do
    bootServer()
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    sv(1, 'open volts=300')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'scan' })
    local before = #sentTo(1, BR.Net.TERMINAL_RESULT)
    fireAs(1, BR.Net.TERMINAL_CLOSED, { terminalId = 'dev', why = 'escape' })
    ok(BR.Terminal.session(1) == nil, 'the computer closed mid-load')
    flush()
    eq(#sentTo(1, BR.Net.TERMINAL_RESULT), before, 'no answer goes to a computer that is gone')
    local n = S.notices[#S.notices]
    local copy = BR.Config.Terminals.copy
    ok(n and n.target == 1 and n.tone == 'success', 'the runner is told by a toast')
    eq(n and n.text, BR.TerminalSolve.pick(copy, 'scan_done', false) .. ' Your new balance is: 100 Volts.',
        'the done line, then the new balance in the owner\'s #239 sentence')
end

-- REVIEW OF ROUND 2: an answer can reach a computer that went away before the
-- server heard (the close still on its way up, the app's window closed, the
-- app still loading). So every LAST WORD the server sends carries `toast`, the
-- very text it would toast itself, for whichever surface cannot show it.
describe('review of round 2: every last word carries the server\'s own toast; running carries none')
do
    bootServer()
    local copy = BR.Config.Terminals.copy
    local TS = BR.TerminalSolve
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    local function ask(facts, d)
        sv(1, 'open ' .. facts)
        S.clock = S.clock + 1000
        run(1, d)
        return last(1, BR.Net.TERMINAL_RESULT)
    end

    -- THE REFUSALS ANSWERED AT ONCE (BR.Terminal.run's own answers).
    local r = ask('nokey', { terminalId = 'dev', functionId = 'storm_reveal' })
    ok(r and r.code == 'no_key' and r.toast == copy.no_key, 'no_key carries the owner\'s login line', r and r.toast)
    r = ask('used', { terminalId = 'dev', functionId = 'storm_reveal' })
    ok(r and r.code == 'squad_used' and r.toast == copy.squad_used_solo,
        'squad_used carries its line, picked for this player: no squad outside a squad match', r and r.toast)
    r = ask('', { terminalId = 'dev', functionId = 'time_weather', options = { weather = 'thunder' } })
    ok(r and r.code == 'bad_option' and r.toast == copy.bad_option, 'bad_option carries its line', r and r.toast)
    r = ask('', { terminalId = 'dev', functionId = 'no_such_function' })
    ok(r and r.code == 'unavailable' and r.toast == copy.unavailable, 'unavailable carries its line', r and r.toast)
    r = ask('volts=150', { terminalId = 'dev', functionId = 'scan' })
    eq(r and r.toast, "You don't have enough Volts. This costs 200 Volts, and your balance is 150 Volts.",
        'no_volts carries its line with the cost and the balance written in')

    -- ACCEPTED, THEN DONE (deliver's answers).
    r = ask('volts=300', { terminalId = 'dev', functionId = 'scan' })
    ok(r and r.code == 'running' and r.toast == nil, '`running` is no last word: no toast')
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    eq(r and r.toast, TS.pick(copy, 'scan_done', false) .. ' Your new balance is: 100 Volts.',
        'done carries the done line and the new balance -- what a closed computer is toasted, word for word')

    -- AN EFFECT THAT COULD NOT HAPPEN, given back.
    local C = BR.Config.Terminals
    C.functions[#C.functions + 1] = { id = 'paid_test', category = 'intel', risk = 'low',
                                     implemented = true, cost = 120 }
    BR.Terminal.FUNCTIONS.paid_test = { run = function() return { ok = false, code = 'no_site' } end }
    ask('volts=500', { terminalId = 'dev', functionId = 'paid_test' })
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.code == 'no_site' and r.toast == copy.no_site, 'a reason after the load carries its line', r and r.toast)
    table.remove(C.functions)
    BR.Terminal.FUNCTIONS.paid_test = nil

    -- THE ONE PICKER, BOTH WAYS: in a squad match the line that says squad.
    local real = BR.Terminal.squadMatch
    BR.Terminal.squadMatch = function() return true end
    r = ask('used', { terminalId = 'dev', functionId = 'storm_reveal' })
    ok(r and r.toast == copy.squad_used and copy.squad_used:lower():find('squad', 1, true) ~= nil,
        'in a squad match, squad_used carries the squad line', r and r.toast)
    ask('', { terminalId = 'dev', functionId = 'storm_reveal' })
    flush()
    r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.code == 'done' and r.toast == copy.storm_reveal_done and copy.storm_reveal_done_solo ~= nil
            and r.toast ~= copy.storm_reveal_done_solo,
        'and a done line picked by the runner\'s fact', r and r.toast)
    BR.Terminal.squadMatch = real
    ask('', { terminalId = 'dev', functionId = 'storm_reveal' })
    flush()
    eq(last(1, BR.Net.TERMINAL_RESULT).toast, copy.storm_reveal_done_solo, 'outside one, its solo sibling')

    -- AND EVERY LAST WORD'S TOAST FITS WHAT THE SHELL WILL HAND BACK (its
    -- TOAST_MAX, 1000): the longest done line or reason, with the balance.
    -- Every line counts but the app's two pages of text, the how-to and the
    -- privacy policy, which the server never says.
    local longest = 0
    for k, v in pairs(copy) do
        if not k:find('^howto_') and not k:find('^privacy_') then longest = math.max(longest, #v) end
    end
    ok(longest + #copy.balance_new + 40 <= 1000, 'the longest possible toast fits the shell\'s 1000', longest)
end

describe('round 2: "squad" only in a squad match -- the copy')
do
    bootServer()
    local C = BR.Config.Terminals
    local copy = C.copy
    -- What is only ever shown in a squad match: a squad-only function's lines,
    -- and a category nothing fills outside one.
    local squadOnlyIds, soloCats = {}, {}
    for _, row in ipairs(C.functions) do
        if row.squadOnly then squadOnlyIds[#squadOnlyIds + 1] = row.id
        else soloCats[row.soloCategory or row.category] = true end
    end
    ok(#squadOnlyIds >= 1, 'some functions are squad-only (Reboot)')
    local function squadOnlyKey(k)
        for _, id in ipairs(squadOnlyIds) do
            if k:sub(1, #id + 1) == id .. '_' then return true end
        end
        local cat = k:match('^category_(.+)$')
        return cat ~= nil and not soloCats[cat]
    end
    for k, v in pairs(copy) do
        if v:lower():find('squad', 1, true) and not k:find('_solo$') then
            local solo = copy[k .. '_solo']
            if squadOnlyKey(k) then
                ok(solo == nil, ('%s is only shown in a squad match, and needs no solo line'):format(k))
            else
                ok(type(solo) == 'string', ('%s says squad, and has a %s_solo sibling'):format(k, k))
                ok(type(solo) == 'string' and not solo:lower():find('squad', 1, true),
                    ('%s_solo does not say squad, in any case or form'):format(k), solo)
            end
        end
        -- (`mode_solo` is the solo mode's own name, not a sibling: there is
        -- no `mode` line.)
        if k:find('_solo$') and copy[k:sub(1, -6)] ~= nil then
            ok(not v:lower():find('squad', 1, true), ('%s does not say squad'):format(k))
        end
    end
    -- THE OWNER'S VERBATIM LINES ARE UNTOUCHED, and have no solo lines.
    for _, k in ipairs({ 'no_key', 'notice_access', 'notice_action', 'bounty_new', 'bounty_protect',
                         'terminal_label', 'terminal_use',
                         'status_offline', 'status_not_here', 'match_heading', 'app_title' }) do
        eq(copy[k .. '_solo'], nil, ('the owner\'s %s has no rewritten twin'):format(k))
    end
    -- The categories: the squad one empties outside a squad match.
    ok(soloCats.squad == nil, 'outside a squad match nothing is listed under Squad')
    eq(BR.Terminal.row('ghost').soloCategory, 'disruption', 'Ghost is listed under Disruption there')
    ok(BR.Terminal.row('reboot').squadOnly == true, 'Reboot is squad-only')
end

describe('round 2: "squad" only in a squad match -- the one Lua picker')
do
    bootServer()
    local TS = BR.TerminalSolve
    local copy = { a = 'Your squad', a_solo = 'You', b = 'Plain', e = 'Squads', e_solo = '' }
    eq(TS.pick(copy, 'a', true), 'Your squad', 'in a squad match: the line')
    eq(TS.pick(copy, 'a', false), 'You', 'outside one: its solo sibling')
    eq(TS.pick(copy, 'a', nil), 'You', 'no answer is not a squad match')
    eq(TS.pick(copy, 'b', false), 'Plain', 'a line with no sibling is itself either way')
    eq(TS.pick(copy, 'e', false), '', 'an empty sibling is empty: the row is not shown')
    eq(TS.pick(copy, 'zz', true), '', 'a key with no line is nothing')
    eq(TS.pick(nil, 'a', true), '', 'and no copy is nothing')

    -- THE READERS: every Lua file that speaks the copy reads a line with a
    -- sibling, or a computed key, only through the picker.
    local real = BR.Config.Terminals.copy
    local readers = { 'br_core/server/terminal.lua', 'br_core/server/terminalfx.lua',
                      'br_core/server/yubikey.lua', 'br_core/client/yubikey.lua',
                      'br_core/client/terminal.lua', 'br_core/client/terminalfx.lua' }
    -- And every function file the manifest lists, both sides (wave A on).
    for _, side in ipairs({ 'server', 'client' }) do
        for _, f in ipairs(fxFiles(side)) do readers[#readers + 1] = f end
    end
    ok(#fxFiles('server') >= 1, 'the manifest lists the wave A function files')
    for _, f in ipairs(readers) do
        local src = (readFile(ROOT .. f) or ''):gsub('%-%-[^\n]*', '')
        ok(src ~= '', ('%s is read'):format(f))
        for key in src:gmatch('copy%(%)%.([%a_][%w_]*)') do
            ok(real[key .. '_solo'] == nil and not (real[key] or ''):lower():find('squad', 1, true),
                ('%s reads copy().%s directly: a line with no squad and no sibling'):format(f, key))
        end
        ok(not src:find('copy%(%)%['), ('%s never indexes the copy by a computed key'):format(f))
        ok(not src:find('Terminals%.copy%['), ('%s never indexes BR.Config.Terminals.copy by key'):format(f))
    end
end

describe('round 2: squad-only functions -- hidden and refused outside a squad match')
do
    bootServer()
    local C = BR.Config.Terminals
    local T = BR.Terminal
    C.functions[#C.functions + 1] = { id = 'squad_test', category = 'squad', risk = 'low',
                                     implemented = true, squadOnly = true }
    T.FUNCTIONS.squad_test = { run = function() return { ok = true, code = 'done' } end }
    local run = function(src, d) fireAs(src, BR.Net.TERMINAL_RUN, d) end
    sv(1, 'open')
    local st = last(1, BR.Net.TERMINAL_OPEN).state
    eq(fnState(st, 'squad_test'), nil, 'a squad-only function is not listed outside a squad match')
    eq(fnState(st, 'reboot'), nil, 'nor is Reboot')
    ok(fnState(st, 'ghost') ~= nil, 'Ghost, which still means something alone, is')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = 'squad_test' })
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'unavailable', 'and asked for anyway, it is refused', r and r.code)
    ok(r and r.state.keyHeld == true and r.state.squadUsed == false, 'spending nothing')
    eq(#S.timers, 0, 'nothing loads')
    table.remove(C.functions)
    T.FUNCTIONS.squad_test = nil
end

-- =========================================================================
-- PART C -- cuchi_computer's shell (before B: B models what C exports)
-- =========================================================================

local C = {}   -- the client world

local function bootShell(opts)
    opts = opts or {}
    C.focus = { held = false, cursor = false, calls = {} }
    C.nui, C.events, C.callbacks, C.exports, C.handlers = {}, {}, {}, {}, {}
    C.invoking = opts.invoking or 'br_core'
    -- FiveM's Citizen.SetTimeout, held for the test to fire (the storm's
    -- close's backstop, round 4). Not the global SetTimeout: PART D's server
    -- shares this Lua state and times its runs with that one.
    C.timers = {}
    Citizen = Citizen or {}
    Citizen.SetTimeout = function(ms, fn) C.timers[#C.timers + 1] = { ms = ms, fn = fn } end

    function GetCurrentResourceName() return 'cuchi_computer' end
    function GetInvokingResource() return C.invoking end
    function SetNuiFocus(held, cursor)
        C.focus.held, C.focus.cursor = held, cursor
        C.focus.calls[#C.focus.calls + 1] = { held, cursor }
    end
    function SendNUIMessage(m) C.nui[#C.nui + 1] = m end
    function RegisterNUICallback(name, fn) C.callbacks[name] = fn end
    function TriggerEvent(name, ...)
        C.events[#C.events + 1] = { name = name, args = { ... } }
        if C.onEvent then C.onEvent(name, ...) end
    end
    function AddEventHandler(name, fn)
        C.handlers[name] = C.handlers[name] or {}
        table.insert(C.handlers[name], fn)
    end
    exports = setmetatable({}, {
        __call = function(_, name, fn) C.exports[name] = fn end,
    })
    loadFile(CUCHI .. 'client/shell.lua')
end

local function cb(name, data)
    local got
    C.callbacks[name](data, function(r) got = r end)
    return got
end

local function eventsNamed(name)
    local out = {}
    for _, e in ipairs(C.events) do
        if e.name == name then out[#out + 1] = e end
    end
    return out
end

local STATE = { terminalId = 'dev', functions = { { id = 'storm_reveal', available = true } },
                keyHeld = true, squadUsed = false }
local COPY = { shell_boot = '[COPY: x]' }

describe('the shell opens nothing before its page is ready')
do
    bootShell()
    local okd, why = C.exports.Open(STATE, COPY)
    ok(okd == false and why == 'page-not-ready', 'Open before NUIOk refuses', tostring(why))
    eq(#C.focus.calls, 0, 'and takes no focus -- a cursor over a page that is not listening is a stuck player')
    eq(#C.nui, 0, 'and sends the page nothing')

    cb('NUIOk', nil)
    okd, why = C.exports.Open({ functions = {} }, COPY)
    ok(okd == false and why == 'bad-state', 'a state with no terminal id is refused', tostring(why))
    eq(#C.focus.calls, 0, 'still no focus')
end

describe('open takes the vote; every way out gives it back')
do
    bootShell()
    cb('NUIOk', nil)
    local okd = C.exports.Open(STATE, COPY)
    ok(okd == true, 'Open after NUIOk opens')
    ok(C.focus.held == true and C.focus.cursor == true, 'SetNuiFocus(true, true): keyboard and cursor')
    local m = C.nui[#C.nui]
    ok(m and m.type == 'br:open' and m.state == STATE and m.copy == COPY,
        'the page gets the state and the copy, as given', m and m.type)
    local opened = eventsNamed('cuchi_computer:opened')
    ok(#opened == 1 and opened[1].args[1] == 'dev', 'br_core hears it opened, on which terminal')
    eq(C.exports.IsOpen(), true, 'IsOpen says so')

    C.exports.Open(STATE, COPY)
    eq(#C.focus.calls, 1, 'opening the same terminal again is a refresh: no second vote')

    -- The page's Escape.
    cb('close', { why = 'escape' })
    ok(C.focus.held == false and C.focus.cursor == false, 'Escape on the page releases focus')
    local closed = eventsNamed('cuchi_computer:closed')
    ok(#closed == 1 and closed[1].args[1] == 'dev' and closed[1].args[2] == 'escape',
        'and br_core hears why')
    ok(C.nui[#C.nui].type ~= 'br:close', 'the page is not told to close what it already closed')
    eq(C.exports.IsOpen(), false, 'IsOpen says so')
    eq(C.exports.Close('x'), false, 'Close with nothing open is a no-op')

    -- The power button, a made-up why, and br_core's Close.
    C.exports.Open(STATE, COPY)
    cb('close', { why = 'exit' })
    eq(eventsNamed('cuchi_computer:closed')[2].args[2], 'exit', 'the power button says exit')
    C.exports.Open(STATE, COPY)
    cb('close', { why = '<script>' })
    eq(eventsNamed('cuchi_computer:closed')[3].args[2], 'page', 'a why the page made up is reported as page')
    C.exports.Open(STATE, COPY)
    eq(C.exports.Close('storm'), true, 'Close from br_core closes')
    ok(C.nui[#C.nui].type == 'br:close' and C.focus.held == false, 'tells the page, and releases focus')
    eq(eventsNamed('cuchi_computer:closed')[4].args[2], 'storm', 'with br_core\'s why')

    -- A different terminal while one is open.
    C.exports.Open(STATE, COPY)
    local other = { terminalId = 'lab', functions = {}, keyHeld = true, squadUsed = false }
    C.exports.Open(other, COPY)
    local cl = eventsNamed('cuchi_computer:closed')
    ok(cl[#cl].args[1] == 'dev' and cl[#cl].args[2] == 'replaced', 'the first is closed as replaced')
    ok(C.focus.held == true and eventsNamed('cuchi_computer:opened')[#eventsNamed('cuchi_computer:opened')].args[1] == 'lab',
        'and the second opens with the vote taken again')
    C.exports.Close('done')
end

-- ROUND 4 (owner, 2026-10-06): "If they're using it while the storm moves and
-- they're now outside the storm, the computer should show a BSOD quickly
-- followed by a CRT-style visual power off." br_core's close for the storm is
-- the one rule's word, 'offline'.
describe('round 4: the storm\'s close plays its screen, then gives the keyboard back')
do
    bootShell()
    cb('NUIOk', nil)
    C.exports.Open(STATE, COPY)
    eq(C.exports.Close('offline'), true, 'br_core closes it for the storm')
    local m = C.nui[#C.nui]
    ok(m and m.type == 'br:close' and m.storm == true, 'the page is told: the storm\'s close, to play out')
    eq(C.focus.held, true, 'the keyboard and the mouse stay the computer\'s while its screen plays')
    eq(#eventsNamed('cuchi_computer:closed'), 0, 'and br_core is not told it closed yet')
    eq(C.exports.IsOpen(), false, 'but it is no longer open')
    eq(C.exports.Result({ functionId = 'scan', ok = true, code = 'done', toast = 'Done.' }), false,
        'an answer landing now is not shown on it -- br_core toasts it, as for any closed computer')
    local r = cb('run', { functionId = 'storm_reveal' })
    ok(r and r.ok == false and #eventsNamed('cuchi_computer:request') == 0, 'and a run asks nothing')
    local nuiBefore = #C.nui
    C.exports.Update(STATE)
    eq(#C.nui, nuiBefore, 'nor is the state pushed to it')
    eq(C.exports.Close('offline'), false, 'a second close does nothing')
    cb('off', {})
    ok(C.focus.held == false and C.focus.cursor == false, 'the page says the screen is dark: focus released')
    local cl = eventsNamed('cuchi_computer:closed')
    ok(#cl == 1 and cl[1].args[1] == 'dev' and cl[1].args[2] == 'offline', 'and br_core hears it closed, for the storm')
    cb('off', {})
    eq(#eventsNamed('cuchi_computer:closed'), 1, '`off` when nothing plays does nothing')

    -- THE BACKSTOP: a page that never says its screen went dark.
    C.exports.Open(STATE, COPY)
    C.exports.Close('offline')
    local t = C.timers[#C.timers]
    ok(t and t.ms == 4000, 'a backstop is set for 4 s', t and t.ms)
    eq(C.focus.held, true, 'the screen plays')
    t.fn()
    ok(C.focus.held == false and #eventsNamed('cuchi_computer:closed') == 2, 'it fires: focus released, br_core told')
    C.exports.Open(STATE, COPY)
    C.exports.Close('offline')
    local t2 = C.timers[#C.timers]
    t.fn()
    eq(C.focus.held, true, 'an earlier close\'s backstop does not end a later one')
    t2.fn()
    eq(C.focus.held, false, 'its own does')

    -- AN OPENING WHILE THE SCREEN PLAYS: the storm's close is said first.
    C.exports.Open(STATE, COPY)
    C.exports.Close('offline')
    local before = #eventsNamed('cuchi_computer:closed')
    local other = { terminalId = 'lab', functions = {}, keyHeld = true, squadUsed = false }
    eq(C.exports.Open(other, COPY), true, 'an opening while the screen plays opens')
    local cl2 = eventsNamed('cuchi_computer:closed')
    ok(#cl2 == before + 1 and cl2[#cl2].args[1] == 'dev' and cl2[#cl2].args[2] == 'offline',
        'after br_core hears the storm\'s close')
    local op = eventsNamed('cuchi_computer:opened')
    ok(C.focus.held == true and op[#op].args[1] == 'lab', 'and the new one holds the vote')
    C.timers[#C.timers].fn()
    eq(C.focus.held, true, 'the old screen\'s backstop does not close the new opening')
    cb('off', {})
    eq(C.focus.held, true, 'nor does a late `off`')
    C.exports.Close('done')

    -- EVERY OTHER CLOSE IS AS IT WAS: at once, and no screen.
    for _, why in ipairs({ 'match', 'state', 'walked', 'season', 'dev', 'storm' }) do
        C.exports.Open(STATE, COPY)
        C.exports.Close(why)
        local last = C.nui[#C.nui]
        ok(last.type == 'br:close' and last.storm == nil and C.focus.held == false,
            ('a close for %s: at once, and no blue screen'):format(why))
    end
    C.exports.Open(STATE, COPY)
    cb('close', { why = 'escape' })
    ok(C.focus.held == false and C.nui[#C.nui].type ~= 'br:close', 'Escape: at once, as ever')

    -- THE RESOURCES STOPPING MID-SCREEN: br_core still hears it closed.
    C.exports.Open(STATE, COPY)
    C.exports.Close('offline')
    local n = #eventsNamed('cuchi_computer:closed')
    for _, fn in ipairs(C.handlers.onResourceStop or {}) do fn('cuchi_computer') end
    local cl3 = eventsNamed('cuchi_computer:closed')
    ok(C.focus.held == false and #cl3 == n + 1 and cl3[#cl3].args[2] == 'offline',
        'this resource stopping mid-screen: released, and br_core told')
    bootShell()
    cb('NUIOk', nil)
    C.exports.Open(STATE, COPY)
    C.exports.Close('offline')
    for _, fn in ipairs(C.handlers.onResourceStop or {}) do fn('br_core') end
    ok(C.focus.held == false and #eventsNamed('cuchi_computer:closed') == 1,
        'the resource that opened it stopping mid-screen: released at once')
    for _, fn in ipairs(C.handlers.onResourceStop or {}) do fn('br_ui') end
    eq(#eventsNamed('cuchi_computer:closed'), 1, 'and some other resource stopping is nothing')
end

describe('the page asks; the shell checks the shape and names the terminal')
do
    bootShell()
    cb('NUIOk', nil)
    local r = cb('run', { functionId = 'storm_reveal' })
    ok(r and r.ok == false and #eventsNamed('cuchi_computer:request') == 0, 'a run with nothing open goes nowhere')

    C.exports.Open(STATE, COPY)
    for _, bad in ipairs({ 'Storm', 'a b', ('x'):rep(33), '9x' }) do
        r = cb('run', { functionId = bad })
        ok(r and r.ok == false, ('a malformed id is refused: %q'):format(bad))
    end
    r = cb('run', { functionId = 7 })
    ok(r and r.ok == false, 'a non-string id is refused')
    eq(#eventsNamed('cuchi_computer:request'), 0, 'and none of them reached br_core')

    r = cb('run', { functionId = 'storm_reveal', terminalId = 'forged' })
    local req = eventsNamed('cuchi_computer:request')
    ok(r and r.ok == true and #req == 1, 'a well-formed run is forwarded')
    ok(req[1] and req[1].args[1] == 'dev' and req[1].args[2].action == 'run'
            and req[1].args[2].functionId == 'storm_reveal' and req[1].args[2].options == nil,
        'as (terminal br_core opened, { action = run, functionId }), never the page\'s terminal')

    -- THE PLAYER'S CHOICES travel shape-checked; the registry is the server's.
    r = cb('run', { functionId = 'supply_drop', options = { site = 'circle' } })
    req = eventsNamed('cuchi_computer:request')
    ok(r and r.ok == true and #req == 2 and req[2].args[2].options.site == 'circle',
        'options travel with the run')
    for _, bad in ipairs({
        'circle', { 'circle' }, { site = 7 }, { site = 'Circle' }, { Site = 'circle' },
        { site = 'a b' }, { site = ('x'):rep(33) },
        { a = 'x', b = 'x', c = 'x', d = 'x', e = 'x', f = 'x', g = 'x', h = 'x', i = 'x' },
    }) do
        r = cb('run', { functionId = 'supply_drop', options = bad })
        ok(r and r.ok == false, ('malformed options refuse the whole run: %s'):format(
            type(bad) == 'table' and tostring(next(bad)) or tostring(bad)))
    end
    eq(#eventsNamed('cuchi_computer:request'), 2, 'and none of them reached br_core')

    local n = #C.nui
    C.exports.Update({ terminalId = 'lab', functions = {} })
    eq(#C.nui, n, 'an update for another terminal is not shown')
    C.exports.Update(STATE)
    eq(C.nui[#C.nui].type, 'br:update', 'an update for this one is')
    C.exports.Result({ functionId = 'storm_reveal', ok = true, code = 'done' })
    eq(C.nui[#C.nui].type, 'br:result', 'and so is a result')
    C.exports.Close('done')
    n = #C.nui
    C.exports.Result({ functionId = 'storm_reveal', ok = true })
    C.exports.Update(STATE)
    eq(#C.nui, n, 'nothing reaches a closed page')
end

describe('round 4: the map pick -- the shell hides and shows, and a run carries its spot')
do
    bootShell()
    cb('NUIOk', nil)
    eq(C.exports.Hide(), false, 'nothing open: nothing to hide')
    local r = cb('pick', { functionId = 'storm_control' })
    ok(r and r.ok == false and #eventsNamed('cuchi_computer:pick') == 0, 'a pick with nothing open goes nowhere')

    C.exports.Open(STATE, COPY)
    for _, bad in ipairs({ 'Storm', ('x'):rep(33), 7 }) do
        r = cb('pick', { functionId = bad })
        ok(r and r.ok == false, ('a pick for a malformed id is refused: %s'):format(tostring(bad)))
    end
    r = cb('pick', { functionId = 'storm_control', terminalId = 'forged' })
    local picks = eventsNamed('cuchi_computer:pick')
    ok(r and r.ok == true and #picks == 1 and picks[1].args[1] == 'dev'
            and picks[1].args[2].functionId == 'storm_control',
        '"Set location" reaches br_core as (terminal br_core opened, { functionId })')

    -- HIDE: the page told, the vote let go, still open.
    eq(C.exports.Hide(), true, 'Hide hides')
    ok(C.nui[#C.nui].type == 'br:hide' and C.focus.held == false and C.focus.cursor == false,
        'the page is told, and the focus is let go so the map has the mouse')
    eq(C.exports.IsOpen(), true, 'still open')
    eq(#eventsNamed('cuchi_computer:closed'), 0, 'and br_core hears no close')
    eq(C.exports.Hide(), false, 'hidden already: a second Hide does nothing')
    r = cb('pick', { functionId = 'storm_control' })
    ok(r and r.ok == false, 'no pick while hidden')
    r = cb('run', { functionId = 'storm_control', at = { x = 1, y = 2 } })
    ok(r and r.ok == false, 'no run while hidden')

    -- SHOW: back, the vote taken again, what was picked handed over, shaped.
    eq(C.exports.Show({ functionId = 'storm_control', at = { x = 120.5, y = -900 }, place = 'Elgin Ave' }), true,
        'Show shows')
    local m = C.nui[#C.nui]
    ok(m.type == 'br:show' and m.picked.functionId == 'storm_control' and m.picked.at.x == 120.5
            and m.picked.at.y == -900 and m.picked.place == 'Elgin Ave',
        'the page gets what was picked')
    ok(C.focus.held == true and C.focus.cursor == true, 'and the focus is taken again')
    eq(C.exports.Show({ functionId = 'storm_control' }), false, 'shown already: a second Show does nothing')
    C.exports.Hide()
    C.exports.Show({ functionId = 'Bad Id', at = { x = 'n', y = 1 }, place = 'x' })
    m = C.nui[#C.nui]
    ok(m.picked.functionId == nil and m.picked.at == nil and m.picked.place == nil,
        'a malformed answer is handed over as no spot, no place, no function')
    C.exports.Hide()
    C.exports.Show({ functionId = 'storm_control', at = { x = 1, y = 1 }, place = ('p'):rep(500) })
    eq(#C.nui[#C.nui].picked.place, 120, 'a place name is cut to 120')

    -- A RUN AT ITS SPOT, shape-checked like its options.
    r = cb('run', { functionId = 'storm_control', at = { x = 120.5, y = -900 } })
    local req = eventsNamed('cuchi_computer:request')
    ok(r and r.ok == true and req[#req].args[2].at and req[#req].args[2].at.x == 120.5
            and req[#req].args[2].at.y == -900,
        'a run carries its spot to br_core')
    local n = #eventsNamed('cuchi_computer:request')
    for _, bad in ipairs({ 'here', { x = 1 }, { x = '1', y = 2 }, { x = 0 / 0, y = 0 }, { x = 1e9, y = 0 } }) do
        r = cb('run', { functionId = 'storm_control', at = bad })
        ok(r and r.ok == false, ('a spot that is not one refuses the whole run: %s'):format(
            type(bad) == 'table' and ('{ x = %s, y = %s }'):format(tostring(bad.x), tostring(bad.y)) or tostring(bad)))
    end
    eq(#eventsNamed('cuchi_computer:request'), n, 'and none of them reached br_core')

    -- CLOSED WHILE HIDDEN: an ordinary close, and nothing hidden left behind.
    C.exports.Hide()
    eq(C.exports.Close('state'), true, 'br_core closes a hidden computer as any other')
    ok(C.focus.held == false and eventsNamed('cuchi_computer:closed')[1].args[2] == 'state', 'released, and said')
    C.exports.Open(STATE, COPY)
    eq(C.exports.Show({ functionId = 'storm_control' }), false, 'the next opening is not hidden')
    ok(C.focus.held == true, 'and holds the focus')
    C.exports.Close('done')
end

describe('round 2: the shell boots with the range and the game time, and relays the clock')
do
    bootShell()
    cb('NUIOk', nil)
    C.exports.Open(STATE, COPY, {}, { bootMinMs = 7000, bootMaxMs = 10000, clock = { h = 12, m = 0 } })
    local m = C.nui[#C.nui]
    ok(m and m.type == 'br:open' and m.desktop and m.desktop.bootMinMs == 7000 and m.desktop.bootMaxMs == 10000,
        'the page gets the boot\'s range')
    ok(m and m.desktop.clock and m.desktop.clock.h == 12 and m.desktop.clock.m == 0, 'and the game\'s time')
    C.exports.Close('done')
    for _, bad in ipairs({ { bootMinMs = 9, bootMaxMs = 3 }, { bootMinMs = 'x', bootMaxMs = 3 },
                           { bootMinMs = -1, bootMaxMs = 3 } }) do
        C.exports.Open(STATE, COPY, {}, bad)
        local d = C.nui[#C.nui].desktop
        ok(d and d.bootMinMs == nil and d.bootMaxMs == nil, 'a range that is not one is not sent')
        C.exports.Close('done')
    end
    C.exports.Open(STATE, COPY, {}, { clock = { h = 24, m = 0 } })
    ok(C.nui[#C.nui].desktop.clock == nil, 'an hour out of range is not sent')
    local n = #C.nui
    C.exports.Clock(18, 5)
    m = C.nui[#C.nui]
    ok(#C.nui == n + 1 and m.type == 'br:clock' and m.h == 18 and m.m == 5, 'Clock(h, m) reaches the page')
    C.exports.Clock(18, 60)
    C.exports.Clock('x', 1)
    eq(#C.nui, n + 1, 'a time out of range does not')
    C.exports.Close('done')
    n = #C.nui
    C.exports.Clock(19, 0)
    eq(#C.nui, n, 'nor does any time once it is closed')
end

describe('review of round 2: the shell says whether an answer was shown, and hands back only what it relayed')
do
    bootShell()
    cb('NUIOk', nil)
    local missedEvents = function() return eventsNamed('cuchi_computer:missed') end
    eq(C.exports.Result({ functionId = 'scan', ok = true, code = 'done', toast = 'Before' }), false,
        'Result with nothing open answers false: br_core toasts it instead')
    C.exports.Open(STATE, COPY)
    eq(C.exports.Result({ functionId = 'scan', ok = true, code = 'done', toast = 'Done line.' }), true,
        'Result while open answers true')
    local m = C.nui[#C.nui]
    ok(m.type == 'br:result' and m.result.toast == 'Done line.', 'and the page gets the answer with its toast')

    -- THE PAGE HANDS BACK A LAST WORD THE APP NEVER SHOWED.
    local r = cb('missed', { toast = 'Something the server never said.' })
    ok(r and r.ok == true and #missedEvents() == 0, 'a text this shell never relayed goes nowhere')
    cb('missed', { toast = 'Before' })
    eq(#missedEvents(), 0, 'nor one offered while it was closed')
    cb('missed', { toast = 'Done line.' })
    local ev = missedEvents()
    ok(#ev == 1 and ev[1].args[1] == 'Done line.' and ev[1].args[2] == true,
        'a relayed one reaches br_core, with the tone of the answer it came with')
    cb('missed', { toast = 'Done line.' })
    eq(#missedEvents(), 1, 'once: the same text again is not a second toast')
    for _, bad in ipairs({ { toast = 7 }, { toast = { 'x' } }, {}, 'Done line.' }) do
        cb('missed', bad)
    end
    C.callbacks.missed(nil, function() end)
    eq(#missedEvents(), 1, 'nothing that is not a string')

    -- AFTER br_core CLOSED IT: the page hands back as it closes, which is
    -- after the shell has shut.
    C.exports.Result({ functionId = 'scan', ok = false, code = 'no_site', toast = 'No spot.' })
    C.exports.Close('storm')
    eq(C.exports.Result({ functionId = 'scan', ok = true, code = 'done', toast = 'Late.' }), false,
        'a result after the close answers false')
    cb('missed', { toast = 'No spot.' })
    ev = missedEvents()
    ok(#ev == 2 and ev[2].args[1] == 'No spot.' and ev[2].args[2] == false,
        'a relayed answer handed back after the close still reaches br_core, as a refusal')
    cb('missed', { toast = 'Late.' })
    eq(#missedEvents(), 2, 'one never relayed (it arrived closed) does not')

    -- AFTER THE PAGE CLOSED IT: the page posts `missed` before `close`, but
    -- two NUI callbacks are two requests, and the close may land first.
    C.exports.Open(STATE, COPY)
    C.exports.Result({ functionId = 'scan', ok = true, code = 'done', toast = 'Escaped.' })
    cb('close', { why = 'escape' })
    cb('missed', { toast = 'Escaped.' })
    ev = missedEvents()
    ok(#ev == 3 and ev[3].args[1] == 'Escaped.' and ev[3].args[2] == true,
        'a relayed answer handed back after the page\'s own close still reaches br_core')

    -- A FEW AT MOST: the newest four.
    C.exports.Open(STATE, COPY)
    for i = 1, 5 do C.exports.Result({ functionId = 'scan', ok = true, code = 'done', toast = 'r' .. i }) end
    cb('missed', { toast = 'r1' })
    eq(#missedEvents(), 3, 'the oldest of five is forgotten')
    cb('missed', { toast = 'r5' })
    eq(#missedEvents(), 4, 'the newest is handed back')
    C.exports.Result({ functionId = 'scan', ok = true, code = 'done', toast = ('x'):rep(1001) })
    cb('missed', { toast = ('x'):rep(1001) })
    eq(#missedEvents(), 4, 'and a text longer than any toast is never one')
    C.exports.Close('done')
end

describe('a resource stopping never strands the vote')
do
    bootShell()
    cb('NUIOk', nil)
    C.exports.Open(STATE, COPY)
    for _, fn in ipairs(C.handlers.onResourceStop or {}) do fn('some_other_resource') end
    eq(C.exports.IsOpen(), true, 'an unrelated resource stopping changes nothing')
    for _, fn in ipairs(C.handlers.onResourceStop or {}) do fn('br_core') end
    ok(C.exports.IsOpen() == false and C.focus.held == false, 'the opener (br_core) stopping closes it and releases focus')
    eq(eventsNamed('cuchi_computer:closed')[1].args[2], 'opener-stopped', 'and says why')

    C.exports.Open(STATE, COPY)
    for _, fn in ipairs(C.handlers.onResourceStop or {}) do fn('cuchi_computer') end
    ok(C.exports.IsOpen() == false and eventsNamed('cuchi_computer:closed')[2].args[2] == 'stopped',
        'this resource stopping tells br_core it went')
end

-- =========================================================================
-- PART B -- br_core's client
-- =========================================================================

local B = {}

local function bootClient(opts)
    opts = opts or {}
    BR = nil
    B.handlers, B.toServer, B.executed, B.commands, B.screens, B.printed = {}, {}, {}, {}, {}, {}
    B.computer = opts.computer ~= false and {
        calls = {},
        openResult = opts.openResult == nil and true or opts.openResult,
    } or nil

    function GetCurrentResourceName() return 'br_core' end
    function IsDuplicityVersion() return false end
    -- br_devMode is what reaches a client (devgate.lua): on, so `brterminal`
    -- runs through the wrap.
    function GetConvar(n, d)
        if n == 'br_devMode' then return opts.devMode == false and 'false' or 'true' end
        return d
    end
    function RegisterNetEvent() end
    function AddEventHandler(name, fn)
        B.handlers[name] = B.handlers[name] or {}
        table.insert(B.handlers[name], fn)
    end
    function TriggerServerEvent(name, data) B.toServer[#B.toServer + 1] = { name = name, data = data } end
    function ExecuteCommand(line) B.executed[#B.executed + 1] = line end
    function RegisterCommand(name, fn) B.commands[name] = fn end
    function GetResourceState(res)
        return (res == 'cuchi_computer' and B.computer) and 'started' or 'missing'
    end
    print = function(s) B.printed[#B.printed + 1] = tostring(s) end
    -- THE GAME'S CLOCK, as the engine would answer it (read only).
    B.clock = { h = 12, m = 0 }
    function GetClockHours() return B.clock.h end
    function GetClockMinutes() return B.clock.m end
    B.loops = {}
    -- THE MAP PICK'S WORLD (round 4): the clock, the events raised, the
    -- waypoint and the sprite-8 blips (squad pings, then the waypoint's), and
    -- the game's names for a place. BOOL natives answer 1/0, as a FiveM one
    -- may. `nativeCalls` counts every map native asked.
    B.map = { events = {}, pings = {}, coords = {}, waypoint = nil, nativeCalls = 0 }
    local Wm = B.map
    local function eights()
        local out = {}
        for _, h in ipairs(Wm.pings) do out[#out + 1] = h end
        if Wm.waypoint then out[#out + 1] = Wm.waypoint.handle end
        return out
    end
    local function asked() Wm.nativeCalls = Wm.nativeCalls + 1 end
    -- The clock is the server's (bootServer's GetGameTimer, S.clock): one
    -- clock for all three halves when PART D wires them. Events are recorded,
    -- and passed on to the shell's own recorder when one is booted.
    local passOn = TriggerEvent
    function TriggerEvent(name, ...)
        Wm.events[#Wm.events + 1] = name
        if passOn then return passOn(name, ...) end
    end
    function IsWaypointActive() asked() return Wm.waypoint ~= nil and 1 or 0 end
    function SetWaypointOff() asked() Wm.waypoint = nil end
    function GetFirstBlipInfoId() asked() Wm.it = 1 return eights()[1] or 0 end
    function GetNextBlipInfoId() asked() Wm.it = Wm.it + 1 return eights()[Wm.it] or 0 end
    function DoesBlipExist(b) asked() return (b ~= nil and b ~= 0) and 1 or 0 end
    function GetBlipInfoIdCoord(b) asked() return Wm.coords[b] end
    function GetGroundZFor_3dCoord() asked() return 1, 30.0 end
    function GetStreetNameAtCoord() asked() return Wm.noNames and 0 or 4242, 0 end
    function GetStreetNameFromHashKey(h) asked() return h == 4242 and 'Elgin Ave' or '' end
    function GetNameOfZone() asked() return Wm.noNames and '' or 'DOWNT' end
    function GetLabelText(z) asked() return z == 'DOWNT' and 'Downtown' or 'NULL' end
    local comp = {}
    for _, name in ipairs({ 'Open', 'Update', 'Result', 'Close', 'Clock', 'Hide', 'Show' }) do
        comp[name] = function(_, ...)
            B.computer.calls[#B.computer.calls + 1] = { name = name, args = { ... } }
            if name == 'Open' then
                if B.computer.openResult == true then return true end
                return false, 'page-not-ready'
            end
            -- The shell's answer: shown, unless the model says it had closed.
            if name == 'Result' then return B.computer.resultShown ~= false end
            if name == 'Hide' then return B.computer.hideResult ~= false end
            return true
        end
    end
    exports = setmetatable({}, { __index = function(_, res)
        if res == 'cuchi_computer' then return comp end
        return nil
    end })

    loadAll({
        'br_lib/shared/devgate.lua',
        'br_lib/shared/enums.lua',
        'br_lib/shared/protocol.lua',
        'br_lib/config/terminals.lua',
        'br_lib/shared/terminal_solve.lua',
    })
    BR.NativeTruthy = function(v) return v == true or v == 1 end
    -- br_ui's map, as client/natives.lua mirrors it (`br:map:frontend`).
    BR.Native = { frontendMap = false }
    BR.Keys = { setExternalScreen = function(name) B.screens[#B.screens + 1] = name or 'none' end }
    BR.Loop = { TICK = 'tick', register = function(_, name, fn) B.loops[name] = fn end }
    -- client/state.lua's BR.Notify: the toasts this client raises itself.
    B.toasts = {}
    BR.Notify = function(text, tone) B.toasts[#B.toasts + 1] = { text = text, tone = tone } end
    loadAll({ 'br_core/client/terminal.lua' })
end

local function fireB(name, ...)
    for _, fn in ipairs(B.handlers[name] or {}) do fn(...) end
end

local function toServer(name)
    local out = {}
    for _, e in ipairs(B.toServer) do
        if e.name == name then out[#out + 1] = e.data end
    end
    return out
end

describe('br_core opens the computer with the state and the one copy block')
do
    bootClient()
    fireB(BR.Net.TERMINAL_OPEN, { state = STATE })
    local call = B.computer.calls[1]
    ok(call and call.name == 'Open' and call.args[1] == STATE, 'Open is called with the server\'s state')
    ok(call and call.args[2] == BR.Config.Terminals.copy, 'and with BR.Config.Terminals.copy, the one block')
    ok(call and type(call.args[3]) == 'table' and call.args[3].functions == BR.Config.Terminals.functions
            and call.args[3].categories == BR.Config.Terminals.categories,
        'and with the catalog: the registry\'s own rows, which the app draws from')
    local pl = call and type(call.args[3]) == 'table' and call.args[3].pageLoad or nil
    ok(type(pl) == 'table' and pl.minMs == BR.Config.Terminals.pageMinMs and pl.maxMs == BR.Config.Terminals.pageMaxMs,
        'and the page-load range the app\'s browser picks in (round 3)')
    eq(#toServer(BR.Net.TERMINAL_CLOSED), 0, 'an open that worked hands nothing back')

    fireB(BR.Net.TERMINAL_OPEN, { state = { functions = {} } })
    eq(#B.computer.calls, 1, 'a payload with no terminal id opens nothing')

    bootClient({ openResult = false })
    fireB(BR.Net.TERMINAL_OPEN, { state = STATE })
    local back = toServer(BR.Net.TERMINAL_CLOSED)
    ok(#back == 1 and back[1].terminalId == 'dev' and back[1].why == 'page-not-ready',
        'a computer that would not open hands the session back, saying why')

    bootClient({ computer = false })
    fireB(BR.Net.TERMINAL_OPEN, { state = STATE })
    back = toServer(BR.Net.TERMINAL_CLOSED)
    ok(#back == 1 and back[1].why == 'not-started', 'and so does a box with no computer at all')
end

describe('br_core relays both ways, and tells the key layer')
do
    bootClient()
    fireB('cuchi_computer:request', 'dev', { action = 'run', functionId = 'storm_reveal' })
    eq(#toServer(BR.Net.TERMINAL_RUN), 0, 'before the computer says it opened, nothing is relayed')

    fireB('cuchi_computer:opened', 'dev')
    eq(B.screens[#B.screens], 'terminal', 'opened: the key layer is told the computer holds the keyboard')
    fireB('cuchi_computer:request', 'dev', { action = 'run', functionId = 'storm_reveal',
                                            options = { zone = 'near' } })
    local up = toServer(BR.Net.TERMINAL_RUN)
    ok(#up == 1 and up[1].terminalId == 'dev' and up[1].functionId == 'storm_reveal'
            and up[1].options and up[1].options.zone == 'near',
        'a run goes up as { terminalId, functionId, options }')

    -- THE PANEL: TERMINAL_INFO updates the computer on that terminal only.
    local before = #B.computer.calls
    fireB(BR.Net.TERMINAL_INFO, { terminalId = 'dev', state = { terminalId = 'dev', functions = {} } })
    ok(#B.computer.calls == before + 1 and B.computer.calls[#B.computer.calls].name == 'Update',
        'the once-a-second push updates the open computer')
    fireB(BR.Net.TERMINAL_INFO, { terminalId = 'lab', state = { terminalId = 'lab' } })
    fireB(BR.Net.TERMINAL_INFO, { terminalId = 'dev' })
    eq(#B.computer.calls, before + 1, 'not for another terminal, nor without a state')
    fireB('cuchi_computer:request', 'lab', { action = 'run', functionId = 'storm_reveal' })
    fireB('cuchi_computer:request', 'dev', { action = 'format', functionId = 'storm_reveal' })
    fireB('cuchi_computer:request', 'dev', 'run')
    eq(#toServer(BR.Net.TERMINAL_RUN), 1, 'another terminal, another action or a bare string goes nowhere')

    local result = { terminalId = 'dev', functionId = 'storm_reveal', ok = true, code = 'done',
                     state = { terminalId = 'dev', functions = {} } }
    fireB(BR.Net.TERMINAL_RESULT, result)
    local n = #B.computer.calls
    ok(B.computer.calls[n - 1].name == 'Update' and B.computer.calls[n - 1].args[1] == result.state,
        'a result updates the state first')
    local res = B.computer.calls[n].args[1]
    ok(B.computer.calls[n].name == 'Result' and res.functionId == 'storm_reveal' and res.ok == true
            and res.code == 'done' and res.state == nil,
        'then hands the page the answer alone')
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'lab', functionId = 'x', ok = true })
    eq(#B.computer.calls, n, 'a result for a terminal not on screen is dropped')

    fireB(BR.Net.TERMINAL_CLOSE, { why = 'storm' })
    ok(B.computer.calls[#B.computer.calls].name == 'Close' and B.computer.calls[#B.computer.calls].args[1] == 'storm',
        'the server closing it closes the computer, with the why')

    fireB('cuchi_computer:closed', 'dev', 'escape')
    eq(B.screens[#B.screens], 'none', 'closed: the key layer gets the keyboard back')
    local closed = toServer(BR.Net.TERMINAL_CLOSED)
    ok(#closed == 1 and closed[1].terminalId == 'dev' and closed[1].why == 'escape',
        'and the server hears the session is over')
    fireB('cuchi_computer:request', 'dev', { action = 'run', functionId = 'storm_reveal' })
    eq(#toServer(BR.Net.TERMINAL_RUN), 1, 'nothing is relayed once it closed')
end

describe('round 2: br_core hands over the boot range, and the game clock while open')
do
    bootClient()
    B.clock = { h = 6, m = 30 }
    fireB(BR.Net.TERMINAL_OPEN, { state = STATE })
    local call = B.computer.calls[#B.computer.calls]
    local desk = call and call.args[4]
    ok(desk and desk.bootMinMs == BR.Config.Terminals.bootMinMs and desk.bootMaxMs == BR.Config.Terminals.bootMaxMs,
        'Open carries the boot\'s range from the registry, with each opening')
    ok(desk and desk.clock and desk.clock.h == 6 and desk.clock.m == 30, 'and the game\'s time now')

    local tick = B.loops['terminal.clock']
    ok(type(tick) == 'function', 'the clock is watched on the TICK band')
    local clocks = function()
        local n = 0
        for _, c in ipairs(B.computer.calls) do if c.name == 'Clock' then n = n + 1 end end
        return n
    end
    tick()
    eq(clocks(), 0, 'nothing is sent before the computer says it opened')
    fireB('cuchi_computer:opened', 'dev')
    tick()
    tick()
    eq(clocks(), 0, 'the minute it opened with is not sent again')
    B.clock.m = 31
    tick()
    tick()
    eq(clocks(), 1, 'a new minute is sent once')
    local last = B.computer.calls[#B.computer.calls]
    ok(last.name == 'Clock' and last.args[1] == 6 and last.args[2] == 31, 'as the hour and the minute')
    B.clock = { h = 7, m = 0 }
    tick()
    eq(clocks(), 2, 'and the next one')
    fireB('cuchi_computer:closed', 'dev', 'escape')
    B.clock.m = 1
    tick()
    eq(clocks(), 2, 'nothing at all once it closed')

    -- The answer's numbers ride through.
    fireB(BR.Net.TERMINAL_OPEN, { state = STATE })
    fireB('cuchi_computer:opened', 'dev')
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = false, code = 'no_volts',
                                    cost = 200, balance = 150, state = { terminalId = 'dev', functions = {} } })
    local res = B.computer.calls[#B.computer.calls].args[1]
    ok(res.code == 'no_volts' and res.cost == 200 and res.balance == 150, 'no_volts carries the cost and the balance')
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = true, code = 'running', runMs = 4200 })
    res = B.computer.calls[#B.computer.calls].args[1]
    ok(res.code == 'running' and res.runMs == 4200, 'running carries how long')
    ok(type(B.computer.calls[1].args[3]) == 'table', 'the catalog is handed over')
end

describe('review of round 2: a last word no computer can show is toasted, in the server\'s words')
do
    bootClient()
    local calls = function() return #B.computer.calls end
    fireB(BR.Net.TERMINAL_OPEN, { state = STATE })
    fireB('cuchi_computer:opened', 'dev')

    -- SHOWN: the computer gets it, toast and all, and nothing is toasted.
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = true, code = 'done',
                                    balance = 100, toast = 'Done. Your new balance is: 100 Volts.' })
    local res = B.computer.calls[calls()]
    ok(res.name == 'Result' and res.args[1].toast == 'Done. Your new balance is: 100 Volts.',
        'the computer is handed the toast with the answer (the desktop may need to hand it back)')
    eq(#B.toasts, 0, 'shown on the computer: no toast')

    -- THE SHELL HAD JUST CLOSED (its closed event not yet here).
    B.computer.resultShown = false
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = false, code = 'no_site',
                                    toast = 'No spot.' })
    ok(#B.toasts == 1 and B.toasts[1].text == 'No spot.' and B.toasts[1].tone == 'warn',
        'a shell that answers it is not up: the server\'s text, toasted as a refusal')
    B.computer.resultShown = nil

    -- CLOSED HERE, NOT YET ON THE SERVER: the latency window.
    fireB('cuchi_computer:closed', 'dev', 'escape')
    local n = calls()
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = true, code = 'done',
                                    toast = 'Late done.', state = { terminalId = 'dev', functions = {} } })
    eq(calls(), n, 'a computer that has closed is handed nothing')
    ok(#B.toasts == 2 and B.toasts[2].text == 'Late done.' and B.toasts[2].tone == 'success',
        'the answer is toasted instead, as a success')
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = true, code = 'running', runMs = 4000 })
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = false, code = 'no_key', toast = '' })
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = false, code = 'no_key', toast = 7 })
    eq(#B.toasts, 2, '`running` (no toast), an empty toast and a toast that is not text raise nothing')

    -- ANOTHER TERMINAL ON SCREEN: the old one's answer is not drawn on it.
    fireB('cuchi_computer:opened', 'lab')
    n = calls()
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = true, code = 'done', toast = 'Old.' })
    ok(calls() == n and B.toasts[3] and B.toasts[3].text == 'Old.', 'an answer for another terminal is toasted, not shown')

    -- THE DESKTOP HANDS ONE BACK.
    fireB('cuchi_computer:missed', 'Held done.', true)
    ok(B.toasts[4] and B.toasts[4].text == 'Held done.' and B.toasts[4].tone == 'success',
        'cuchi_computer:missed is toasted, with its tone')
    fireB('cuchi_computer:missed', 'Held refusal.', false)
    eq(B.toasts[5] and B.toasts[5].tone, 'warn', 'a refusal handed back is a warning')
    fireB('cuchi_computer:missed', nil, true)
    fireB('cuchi_computer:missed', '', true)
    eq(#B.toasts, 5, 'and nothing, or nothing to say, is not toasted')

    -- NO COMPUTER AT ALL.
    bootClient({ computer = false })
    fireB('cuchi_computer:opened', 'dev')
    fireB(BR.Net.TERMINAL_RESULT, { terminalId = 'dev', functionId = 'scan', ok = true, code = 'done', toast = 'Gone.' })
    ok(#B.toasts == 1 and B.toasts[1].text == 'Gone.', 'a box whose computer stopped toasts it too')
end

describe('brterminal types the server command')
do
    bootClient({ devMode = false })
    B.commands.brterminal(nil, {})
    eq(#B.executed, 0, 'with dev mode off, brterminal types nothing')

    bootClient()
    local cmd = B.commands.brterminal
    ok(cmd ~= nil, 'brterminal is registered')
    cmd(nil, {})
    cmd(nil, { 'nokey', 'used' })
    cmd(nil, { 'open', 'offline' })
    cmd(nil, { 'close' })
    eq(B.executed[1], 'brterminalsv open ', 'bare: open with a key')
    eq(B.executed[2], 'brterminalsv open nokey used', 'words become the facts')
    eq(B.executed[3], 'brterminalsv open offline', '"open" is optional')
    eq(B.executed[4], 'brterminalsv close', 'and close closes')
    fireB(BR.Net.TERMINAL_DEV, 'opened terminal "dev"')
    ok(B.printed[#B.printed]:find('opened terminal', 1, true) ~= nil, 'the server\'s answer is printed on F8')
end

describe('round 4: the map pick -- the computer hidden, the big map, the waypoint read, the computer back')
do
    -- Owner, 2026-10-06: "When they click confirm, we should open the big
    -- map for them, wait for them to pick a location, then when they close the
    -- big map we run it."
    bootClient()
    local W = B.map
    local tick = B.loops['terminal.clock']
    local function calls(name)
        local out = {}
        for _, c in ipairs(B.computer.calls) do if c.name == name then out[#out + 1] = c end end
        return out
    end
    fireB('cuchi_computer:opened', 'dev')
    -- A squadmate's ping on the map, and a waypoint of the player's own.
    W.pings = { 501 }
    W.coords[501] = { x = 10.0, y = 10.0, z = 0.0 }
    W.waypoint = { handle = 700, x = -50.0, y = -50.0 }

    fireB('cuchi_computer:pick', 'lab', { functionId = 'storm_control' })
    fireB('cuchi_computer:pick', 'dev', { functionId = 'Not An Id' })
    eq(#calls('Hide'), 0, 'a pick for another terminal, or a malformed function, does nothing')

    fireB('cuchi_computer:pick', 'dev', { functionId = 'storm_control' })
    eq(#calls('Hide'), 1, 'the computer is hidden')
    eq(B.screens[#B.screens], 'none', 'the key layer lets go, so the game has the keyboard')
    eq(W.events[#W.events], 'br:ui:mapToggle', 'the big map opens: br_ui\'s own, the map key\'s')
    eq(W.waypoint, nil, 'the player\'s own waypoint is cleared first: it is not the pick')
    eq(BR.Terminal.picking(), true, 'a pick is under way')
    fireB('cuchi_computer:pick', 'dev', { functionId = 'storm_control' })
    eq(#calls('Hide'), 1, 'and a second one waits for it')

    tick()
    eq(#calls('Show'), 0, 'the map not up yet: it waits')
    BR.Native.frontendMap = true
    tick()
    -- The player sets a waypoint on the map; the ping is listed first.
    W.waypoint = { handle = 800, x = 120.5, y = -900.0 }
    W.coords[800] = { x = 120.5, y = -900.0, z = 0.0 }
    tick()
    eq(#calls('Show'), 0, 'while the map is up, nothing comes back')
    BR.Native.frontendMap = false
    tick()
    local show = calls('Show')[1]
    local got = show and show.args[1]
    ok(got and got.functionId == 'storm_control' and got.at and got.at.x == 120.5 and got.at.y == -900.0,
        'the map closed: the computer is shown again with the waypoint set on it, past the squad ping')
    eq(got and got.place, 'Elgin Ave, Downtown', 'and the game\'s own name for the place, its street and area')
    eq(W.waypoint, nil, 'the waypoint is taken off the map')
    eq(B.screens[#B.screens], 'terminal', 'the key layer is the computer\'s again')
    eq(BR.Terminal.picking(), false, 'and the pick is over')

    -- NO WAYPOINT SET: the box goes back to its first step.
    fireB('cuchi_computer:pick', 'dev', { functionId = 'supply_drop' })
    BR.Native.frontendMap = true
    tick()
    BR.Native.frontendMap = false
    tick()
    got = calls('Show')[2] and calls('Show')[2].args[1]
    ok(got and got.functionId == 'supply_drop' and got.at == nil and got.place == nil,
        'no waypoint when the map closes: shown again with no spot')

    -- A PLACE THE GAME HAS NO NAME FOR.
    W.noNames = true
    fireB('cuchi_computer:pick', 'dev', { functionId = 'supply_drop' })
    BR.Native.frontendMap = true
    tick()
    W.waypoint = { handle = 801, x = 5.0, y = 6.0 }
    W.coords[801] = { x = 5.0, y = 6.0, z = 0.0 }
    BR.Native.frontendMap = false
    tick()
    got = calls('Show')[3] and calls('Show')[3].args[1]
    ok(got and got.at and got.at.x == 5.0 and got.place == '', 'no street or area: the spot, and an empty place', got and got.place)
    W.noNames = false

    -- THE MAP NEVER COMES UP: given up after PICK_RAISE_MS, no spot.
    fireB('cuchi_computer:pick', 'dev', { functionId = 'storm_control' })
    S.clock = S.clock + 4999
    tick()
    eq(#calls('Show'), 3, 'four and a bit seconds with no map: still waiting')
    S.clock = S.clock + 2
    tick()
    got = calls('Show')[4] and calls('Show')[4].args[1]
    ok(got and got.at == nil, 'five seconds and no map: shown again, no spot')

    -- CLOSED WHILE THE MAP IS UP (downed, the storm): nothing comes back, and
    -- the waypoint set for the pick is still taken off.
    fireB('cuchi_computer:pick', 'dev', { functionId = 'storm_control' })
    BR.Native.frontendMap = true
    tick()
    fireB('cuchi_computer:closed', 'dev', 'state')
    W.waypoint = { handle = 802, x = 1.0, y = 1.0 }
    W.coords[802] = { x = 1.0, y = 1.0, z = 0.0 }
    BR.Native.frontendMap = false
    tick()
    eq(#calls('Show'), 4, 'the computer closed meanwhile: nothing is shown')
    eq(W.waypoint, nil, 'and the waypoint is still taken off, not left for a squad ping')
    eq(BR.Terminal.picking(), false, 'the pick is over')

    -- A COMPUTER THAT WOULD NOT HIDE: no map, no pick.
    fireB('cuchi_computer:opened', 'dev')
    B.computer.hideResult = false
    local toggles = 0
    for _, e in ipairs(W.events) do if e == 'br:ui:mapToggle' then toggles = toggles + 1 end end
    fireB('cuchi_computer:pick', 'dev', { functionId = 'storm_control' })
    local after = 0
    for _, e in ipairs(W.events) do if e == 'br:ui:mapToggle' then after = after + 1 end end
    ok(after == toggles and BR.Terminal.picking() == false, 'the shell would not hide: no map, no pick')
    B.computer.hideResult = nil

    -- A RUN CARRIES THE SPOT UP.
    fireB('cuchi_computer:request', 'dev', { action = 'run', functionId = 'storm_control',
                                            at = { x = 120.5, y = -900.0 } })
    local up = toServer(BR.Net.TERMINAL_RUN)
    ok(up[#up] and up[#up].at and up[#up].at.x == 120.5 and up[#up].at.y == -900.0,
        'a run goes up with its spot')

    -- NOTHING PER FRAME: with no pick, the TICK pass asks no map native.
    local n = W.nativeCalls
    for _ = 1, 50 do tick() end
    eq(W.nativeCalls, n, 'fifty passes with no pick ask the map nothing')
end

describe('round 4: a squad ping never takes the waypoint set for a map pick')
do
    -- client/markers.lua consumes any fresh waypoint as a squad ping; while a
    -- pick is under way it stands down, as it does for a rescue and a survey.
    -- Pinned by text: the guard is in the placement pass, before the waypoint
    -- is read.
    local src = readFile(ROOT .. 'br_core/client/markers.lua') or ''
    local body = src:match("BR%.Loop%.register%(BR%.Loop%.TICK, 'markers%.place'(.-)\nend%)")
    ok(body ~= nil, 'the placement pass is found')
    local guard = body and body:find('BR.Terminal.picking()', 1, true)
    local read = body and body:find('GetFirstBlipInfoId(8)', 1, true)
    ok(guard ~= nil and read ~= nil and guard < read, 'it stands down while BR.Terminal.picking(), before reading the waypoint')
end

-- =========================================================================
-- PART D -- one round trip, all three halves
-- =========================================================================

--- PART B's client over PART C's real shell, wired to PART A's server.
--- `toClient` and `toServer` move one direction's queued events alone, so a
--- test can hold one back -- a close still on its way up while the server
--- answers -- and `pump` moves both until they are quiet.
local function wire()
    local W = { inbox = {} }
    -- THE SERVER, with its client events queued for the client below.
    bootServer()
    W.server = { handlers = S.handlers, commands = S.commands }
    W.serverBR = BR
    S.onClient = function(name, target, data) W.inbox[#W.inbox + 1] = { name = name, target = target, data = data } end

    -- THE SHELL.
    bootShell()
    cb('NUIOk', nil)
    W.shell = { exports = C.exports, callbacks = C.callbacks }

    -- BR_CORE'S CLIENT, over the real shell's exports.
    bootClient()
    W.clientBR = BR
    exports = setmetatable({}, { __index = function(_, res)
        if res ~= 'cuchi_computer' then return nil end
        return setmetatable({}, { __index = function(_, fn)
            return function(_, ...) return W.shell.exports[fn](...) end
        end })
    end })
    -- The shell's local events reach br_core's client handlers.
    C.onEvent = function(name, ...) fireB(name, ...) end

    function W.toClient()
        local box = W.inbox
        W.inbox = {}
        for _, e in ipairs(box) do
            BR = W.clientBR
            fireB(e.name, e.data)
        end
        return #box > 0
    end
    function W.toServer()
        local up = B.toServer
        B.toServer = {}
        for _, e in ipairs(up) do
            BR = W.serverBR
            local prev = source
            source = 1
            for _, fn in ipairs(W.server.handlers[e.name] or {}) do fn(e.data) end
            source = prev
        end
        return #up > 0
    end
    -- Server -> client, then client -> server, until both are quiet.
    function W.pump()
        for _ = 1, 10 do
            local a = W.toClient()
            local b = W.toServer()
            if not a and not b then break end
        end
    end
    -- `brterminal <words>` -> `brterminalsv open <words>`, as player 1.
    function W.devOpen(words)
        BR = W.clientBR
        B.commands.brterminal(nil, words or {})
        BR = W.serverBR
        local args = {}
        for w in B.executed[#B.executed]:gmatch('%S+') do args[#args + 1] = w end
        table.remove(args, 1)
        W.server.commands.brterminalsv.fn(1, args, '')
        W.pump()
    end
    -- The page asks for a run.
    function W.run(functionId)
        S.clock = S.clock + 1000
        BR = W.clientBR
        W.shell.callbacks.run({ functionId = functionId }, function() end)
        W.pump()
    end
    return W
end

describe('the dev command to the answer on the page, end to end')
do
    local W = wire()
    W.devOpen({})
    ok(C.focus.held == true, 'the dev command opens the computer and the shell takes focus')
    local opened = C.nui[#C.nui]
    ok(opened and opened.type == 'br:open' and opened.state.terminalId == 'dev'
            and opened.copy.storm_reveal_name == W.serverBR.Config.Terminals.copy.storm_reveal_name,
        'the page opens on the dev terminal, with the copy block')
    eq(B.screens[#B.screens], 'terminal', 'and br_core\'s key layer is told')

    -- The page asks.
    W.run('storm_reveal')
    local upd, res = C.nui[#C.nui - 1], C.nui[#C.nui]
    ok(upd and upd.type == 'br:update' and upd.state.squadUsed == true, 'the page gets the new state')
    ok(res and res.type == 'br:result' and res.result.ok == true and res.result.code == 'running'
            and type(res.result.runMs) == 'number',
        'and the answer: accepted, loading for runMs')
    BR = W.serverBR
    flush()
    W.pump()
    res = C.nui[#C.nui]
    ok(res and res.type == 'br:result' and res.result.ok == true and res.result.code == 'done'
            and res.result.functionId == 'storm_reveal',
        'then, when the server says, the answer: Storm reveal ran')

    -- Escape on the page.
    BR = W.clientBR
    W.shell.callbacks.close({ why = 'escape' }, function() end)
    W.pump()
    ok(C.focus.held == false, 'Escape releases focus')
    eq(B.screens[#B.screens], 'none', 'the key layer gets the keyboard back')
    BR = W.serverBR
    ok(BR.Terminal.session(1) == nil, 'and the server session is over')
    eq(#B.toasts, 0, 'and nothing was toasted: the page showed every answer')
end

describe('round 4: "Set location" to the storm aimed, end to end')
do
    local W = wire()
    W.devOpen({ 'volts=500' })
    ok(C.focus.held == true, 'the computer is open')
    -- The page's "Set location".
    BR = W.clientBR
    W.shell.callbacks.pick({ functionId = 'storm_control' }, function() end)
    ok(C.nui[#C.nui].type == 'br:hide' and C.focus.held == false, 'the page is hidden and the focus let go')
    eq(B.screens[#B.screens], 'none', 'the key layer lets go')
    eq(B.map.events[#B.map.events], 'br:ui:mapToggle', 'the big map is asked for')
    -- The map comes up, a waypoint is set, the map closes.
    BR.Native.frontendMap = true
    B.loops['terminal.clock']()
    B.map.waypoint = { handle = 900, x = 210.0, y = -640.0 }
    B.map.coords[900] = { x = 210.0, y = -640.0, z = 0.0 }
    BR.Native.frontendMap = false
    B.loops['terminal.clock']()
    local shown = C.nui[#C.nui]
    ok(shown.type == 'br:show' and shown.picked.functionId == 'storm_control' and shown.picked.at.x == 210.0
            and shown.picked.at.y == -640.0 and shown.picked.place == 'Elgin Ave, Downtown',
        'the page is shown again with the spot and its place')
    ok(C.focus.held == true and B.screens[#B.screens] == 'terminal', 'with the focus and the key layer back')
    -- Run, at the spot: up through the shell, br_core's client and the server.
    S.clock = S.clock + 1000
    W.shell.callbacks.run({ functionId = 'storm_control', at = shown.picked.at }, function() end)
    W.pump()
    local res = C.nui[#C.nui]
    ok(res and res.type == 'br:result' and res.result.ok == true and res.result.code == 'running',
        'the run at the spot is accepted', res and res.result and res.result.code)
    BR = W.serverBR
    flush()
    W.pump()
    res = C.nui[#C.nui]
    ok(res and res.type == 'br:result' and res.result.code == 'done' and res.result.balance == 350,
        'and done, for 150 Volts', res and res.result and res.result.code)
    BR = W.clientBR
    C.exports.Close('done')
    W.pump()
end

-- REVIEW OF ROUND 2: the answer that lands as the computer goes away.
describe('review of round 2: closed a moment before the answer landed -- toasted once, in the server\'s words')
do
    local W = wire()
    W.devOpen({ 'volts=300' })
    W.run('scan')
    ok(C.nui[#C.nui].result.code == 'running', 'Scan is accepted and loading')

    -- ESCAPE, and the close is still on its way up when the loading ends.
    BR = W.clientBR
    W.shell.callbacks.close({ why = 'escape' }, function() end)
    BR = W.serverBR
    flush()
    ok(BR.Terminal.session(1) ~= nil, 'the server has not heard the close yet')
    local pages = #C.nui
    W.toClient()
    eq(#C.nui, pages, 'the closed page is sent nothing')
    local copy = W.serverBR.Config.Terminals.copy
    local want = W.serverBR.TerminalSolve.pick(copy, 'scan_done', false) .. ' Your new balance is: 100 Volts.'
    ok(#B.toasts == 1 and B.toasts[1].text == want and B.toasts[1].tone == 'success',
        'the player is toasted the done line and the new balance', B.toasts[1] and B.toasts[1].text)
    W.pump()
    BR = W.serverBR
    ok(BR.Terminal.session(1) == nil, 'then the server hears the close')
    eq(#S.notices, 0, 'and toasts nothing itself: it had already answered')
    eq(#B.toasts, 1, 'once')

    -- THE OTHER ORDER: the server heard the close first, and toasts it.
    W = wire()
    W.devOpen({ 'volts=300' })
    W.run('scan')
    BR = W.clientBR
    W.shell.callbacks.close({ why = 'escape' }, function() end)
    W.toServer()
    BR = W.serverBR
    flush()
    W.pump()
    ok(#S.notices == 1 and S.notices[1].text == want and #B.toasts == 0,
        'the same words, from the server, once', S.notices[1] and S.notices[1].text)
end

describe('review of round 2: an answer the page held, handed back as the computer closes')
do
    local W = wire()
    W.devOpen({ 'volts=300' })
    W.run('scan')
    BR = W.serverBR
    flush()
    W.pump()
    local held = C.nui[#C.nui]
    ok(held.type == 'br:result' and held.result.code == 'done' and type(held.result.toast) == 'string',
        'the done answer reaches the page with its toast')
    -- The app was away (its window closed): br.js held it, and the computer
    -- closes -- it hands the toast back, then says the close.
    BR = W.clientBR
    W.shell.callbacks.missed({ toast = held.result.toast }, function() end)
    W.shell.callbacks.close({ why = 'escape' }, function() end)
    W.pump()
    local copy = W.serverBR.Config.Terminals.copy
    ok(#B.toasts == 1 and B.toasts[1].text == W.serverBR.TerminalSolve.pick(copy, 'scan_done', false)
            .. ' Your new balance is: 100 Volts.' and B.toasts[1].tone == 'success',
        'the player is toasted the done line and the new balance', B.toasts[1] and B.toasts[1].text)
    eq(#S.notices, 0, 'and the server toasts nothing: it answered the open session')
    W.shell.callbacks.missed({ toast = held.result.toast }, function() end)
    eq(#B.toasts, 1, 'handed back twice, toasted once')
end

describe('round 4: the storm closes the computer while a run loads -- the screen plays, the run still lands')
do
    -- The storm's close reaches the client (TERMINAL_CLOSE, 'offline') while
    -- Scan loads. The computer plays its blue screen and keeps the keyboard;
    -- the run completes as the door's contract says, and its last word, which
    -- no computer can show now, is toasted once.
    local W = wire()
    W.devOpen({ 'volts=300' })
    W.run('scan')
    ok(C.nui[#C.nui].result.code == 'running', 'Scan is accepted and loading')
    BR = W.clientBR
    fireB(BR.Net.TERMINAL_CLOSE, { why = 'offline' })
    local m = C.nui[#C.nui]
    ok(m.type == 'br:close' and m.storm == true, 'the page plays the storm\'s close')
    eq(C.focus.held, true, 'and the keyboard is still the computer\'s')
    eq(B.screens[#B.screens], 'terminal', 'br_core\'s key layer still says the computer has it')
    BR = W.serverBR
    flush()
    W.toClient()
    local copy = W.serverBR.Config.Terminals.copy
    local want = W.serverBR.TerminalSolve.pick(copy, 'scan_done', false) .. ' Your new balance is: 100 Volts.'
    ok(#B.toasts == 1 and B.toasts[1].text == want, 'the run landed: its done line, toasted',
        B.toasts[1] and B.toasts[1].text)
    eq(C.nui[#C.nui].type, 'br:close', 'and nothing more was sent to the screen')
    BR = W.clientBR
    W.shell.callbacks.off({}, function() end)
    eq(C.focus.held, false, 'the screen dark: focus released')
    eq(B.screens[#B.screens], 'none', 'and the key layer has the keyboard back')
    W.pump()
    eq(#B.toasts, 1, 'toasted once')
end

print = realPrint
realPrint(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end
