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

    function GetGameTimer() return S.clock end
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
    })
    BR.Season.strict = true
    BR.Season.boot()
    loadAll({ 'br_core/server/terminal.lua', 'br_core/server/terminalfx.lua' })
end

local function fireAs(src, name, ...)
    local prev = source
    source = src
    for _, fn in ipairs(S.handlers[name] or {}) do fn(...) end
    source = prev
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
    sv(1, 'open')
    local st = last(1, BR.Net.TERMINAL_OPEN).state
    eq(#st.functions, #BR.Config.Terminals.functions, 'one row per registry row, built or not')
    for i, row in ipairs(BR.Config.Terminals.functions) do
        local f = st.functions[i]
        ok(f and f.id == row.id, ('row %d is %s, in the registry\'s order'):format(i, row.id))
        if row.implemented then
            ok(f and f.available == true, ('%s is built and available'):format(row.id))
        else
            ok(f and f.available == false and f.reason == 'fn_offline',
                ('%s is not built: listed, offline'):format(row.id), f and tostring(f.reason))
        end
    end
    -- An unbuilt function is offline before anything else is asked: with no
    -- key and the squad's use spent, it still says fn_offline.
    sv(1, 'open nokey used')
    local unbuilt
    for _, row in ipairs(BR.Config.Terminals.functions) do
        if not row.implemented then unbuilt = row.id break end
    end
    ok(fnState(last(1, BR.Net.TERMINAL_OPEN).state, unbuilt).reason == 'fn_offline',
        'an unbuilt function says fn_offline whatever else is true')
    sv(1, 'open')
    S.clock = S.clock + 1000
    run(1, { terminalId = 'dev', functionId = unbuilt })
    local r = last(1, BR.Net.TERMINAL_RESULT)
    ok(r and r.ok == false and r.code == 'fn_offline', 'its run is refused fn_offline', r and r.code)
    ok(r and r.state.keyHeld == true and r.state.squadUsed == false, 'and nothing is spent')
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
    ok(r and r.ok == true and r.code == 'done' and r.terminalId == 'dev', 'with a key: it runs', r and r.code)
    ok(r and r.state.keyHeld == false and r.state.squadUsed == true,
        'and the key and the squad use are spent')
    ok(r and fnState(r.state, 'storm_reveal').reason == 'squad_used',
        'so the answer already lists it as used')

    local n = #sentTo(1, BR.Net.TERMINAL_RESULT)
    S.clock = S.clock + BR.Config.Terminals.runMinIntervalMs - 1
    run(1, req)
    eq(#sentTo(1, BR.Net.TERMINAL_RESULT), n, 'a second request inside the interval is dropped')
    S.clock = S.clock + 1
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
        'shell_boot', 'desktop_icon', 'window_title', 'app_title', 'run',
        'address_host', 'path_functions', 'path_howto', 'path_login',
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
-- PART C -- cuchi_computer's shell (before B: B models what C exports)
-- =========================================================================

local C = {}   -- the client world

local function bootShell(opts)
    opts = opts or {}
    C.focus = { held = false, cursor = false, calls = {} }
    C.nui, C.events, C.callbacks, C.exports, C.handlers = {}, {}, {}, {}, {}
    C.invoking = opts.invoking or 'br_core'

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
            and req[1].args[2].functionId == 'storm_reveal',
        'as (terminal br_core opened, { action = run, functionId }), never the page\'s terminal')

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
    local comp = {}
    for _, name in ipairs({ 'Open', 'Update', 'Result', 'Close' }) do
        comp[name] = function(_, ...)
            B.computer.calls[#B.computer.calls + 1] = { name = name, args = { ... } }
            if name == 'Open' then
                if B.computer.openResult == true then return true end
                return false, 'page-not-ready'
            end
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
    })
    BR.Keys = { setExternalScreen = function(name) B.screens[#B.screens + 1] = name or 'none' end }
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
    fireB('cuchi_computer:request', 'dev', { action = 'run', functionId = 'storm_reveal' })
    local up = toServer(BR.Net.TERMINAL_RUN)
    ok(#up == 1 and up[1].terminalId == 'dev' and up[1].functionId == 'storm_reveal',
        'a run goes up as { terminalId, functionId }')
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

-- =========================================================================
-- PART D -- one round trip, all three halves
-- =========================================================================

describe('the dev command to the answer on the page, end to end')
do
    -- THE SERVER, with its client events delivered to the client below.
    bootServer()
    local server = { handlers = S.handlers, commands = S.commands }
    local serverBR = BR
    local inbox = {}
    S.onClient = function(name, target, data) inbox[#inbox + 1] = { name = name, target = target, data = data } end

    -- THE SHELL.
    bootShell()
    cb('NUIOk', nil)
    local shell = { exports = C.exports, callbacks = C.callbacks }

    -- BR_CORE'S CLIENT, over the real shell's exports.
    bootClient()
    local clientBR = BR
    exports = setmetatable({}, { __index = function(_, res)
        if res ~= 'cuchi_computer' then return nil end
        return setmetatable({}, { __index = function(_, fn)
            return function(_, ...) return shell.exports[fn](...) end
        end })
    end })
    -- The shell's local events reach br_core's client handlers.
    C.onEvent = function(name, ...) fireB(name, ...) end

    local function pump()
        -- Server -> client, then client -> server, until both are quiet.
        for _ = 1, 10 do
            local moved = false
            local box = inbox
            inbox = {}
            for _, e in ipairs(box) do
                BR = clientBR
                fireB(e.name, e.data)
                moved = true
            end
            local up = B.toServer
            B.toServer = {}
            for _, e in ipairs(up) do
                BR = serverBR
                local prev = source
                source = 1
                for _, fn in ipairs(server.handlers[e.name] or {}) do fn(e.data) end
                source = prev
                moved = true
            end
            if not moved then break end
        end
    end

    -- `brterminal` -> `brterminalsv open`, as player 1.
    BR = clientBR
    B.commands.brterminal(nil, {})
    BR = serverBR
    local args = {}
    for w in B.executed[#B.executed]:gmatch('%S+') do args[#args + 1] = w end
    table.remove(args, 1)
    server.commands.brterminalsv.fn(1, args, '')
    pump()
    ok(C.focus.held == true, 'the dev command opens the computer and the shell takes focus')
    local opened = C.nui[#C.nui]
    ok(opened and opened.type == 'br:open' and opened.state.terminalId == 'dev'
            and opened.copy.storm_reveal_name == serverBR.Config.Terminals.copy.storm_reveal_name,
        'the page opens on the dev terminal, with the copy block')
    eq(B.screens[#B.screens], 'terminal', 'and br_core\'s key layer is told')

    -- The page asks.
    S.clock = S.clock + 1000
    BR = clientBR
    shell.callbacks.run({ functionId = 'storm_reveal' }, function() end)
    pump()
    local upd, res = C.nui[#C.nui - 1], C.nui[#C.nui]
    ok(upd and upd.type == 'br:update' and upd.state.squadUsed == true, 'the page gets the new state')
    ok(res and res.type == 'br:result' and res.result.ok == true and res.result.code == 'done'
            and res.result.functionId == 'storm_reveal',
        'and the answer: Storm reveal ran')

    -- Escape on the page.
    BR = clientBR
    shell.callbacks.close({ why = 'escape' }, function() end)
    pump()
    ok(C.focus.held == false, 'Escape releases focus')
    eq(B.screens[#B.screens], 'none', 'the key layer gets the keyboard back')
    BR = serverBR
    ok(BR.Terminal.session(1) == nil, 'and the server session is over')
end

print = realPrint
realPrint(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end
