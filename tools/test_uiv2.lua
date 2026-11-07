-- Unit tests for UI v2 (#436): br_lib/shared/uiv2.lua, its list in
-- br_lib/config/uiv2.lua, the holder br_core/client/uiv2.lua and the console
-- command br_core/server/uiv2.lua.
--
-- Owner, 2026-11-07: "All this UI rework - can we make a server-side toggle
-- for it? One toggle for everything (market, locker v2, HUD, inventory, player
-- list, etc), and also a separate toggle for each component? Let's call
-- everything as a whole UI v2." His decisions the same day: separate from the
-- season, and switched live from the server console, on prod too, as a kill
-- switch -- "players get a change in the lobby or at their next match, never
-- mid-match".
--
-- ═══ WHAT IS WORTH TESTING ═══
--
-- EVERY WRONG ANSWER HERE IS A LEGAL ONE. A switch read as on when it says
-- `of` is a kill switch that does not kill; a client that reads the operator's
-- convar shows Market v2 the moment someone types it, mid-match; a holder that
-- takes an answer at the sweep to the lobby changes a character before the
-- trip home. None of it errors, so all of it is pinned here.
--
-- SEPARATE LUA ENVIRONMENTS for br_core's server, br_core's client (the
-- holder) and br_ui's client (a mirror), each with the module loaded as its
-- own copy, as each resource's Lua state has. The replicated convars are one
-- table between them, and a listener on it fires ONLY WHEN A VALUE CHANGES --
-- the game's rule; a stub that fired on every write could pass where the
-- game never fires. The two client states share one local-event bus, which
-- calls every handler synchronously, as TriggerEvent does on one machine.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_uiv2.lua

local RES = 'resources/[fivem-royale]/'
local MODULE = RES .. 'br_lib/shared/uiv2.lua'
local REGISTRY = RES .. 'br_lib/config/uiv2.lua'
local HOLDER = RES .. 'br_core/client/uiv2.lua'
local COMMAND = RES .. 'br_core/server/uiv2.lua'

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

--- The replicated convars as a client's runtime holds them: a write lands,
--- and every AddConvarChangeListener whose filter names it is called -- ONLY
--- WHEN THE VALUE CHANGED, as OnConvarModified is raised.
--- @return table
local function wire()
    local store, listeners = {}, {}
    local t = setmetatable({}, {
        __index = store,
        __newindex = function(_, k, v)
            if store[k] == v then return end
            store[k] = v
            for _, l in ipairs(listeners) do
                if l.filter == nil or l.filter == k then l.fn(k, '') end
            end
        end,
        __pairs = function() return next, store, nil end,
    })
    return t, listeners
end

--- A fresh environment: _G behind it, a BR table, prints kept, and every
--- GetConvar counted by name.
local function newEnv(st)
    local env = setmetatable({}, { __index = _G })
    env.BR = {}
    st.printed, st.reads = {}, {}
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        st.printed[#st.printed + 1] = table.concat(parts, '\t')
    end
    st.env = env
    return env
end

local function loadInto(env, path)
    assert(loadfile(path, 't', env))()
end

--- One of br_core's server: the module and the list, a convar table it reads
--- and writes (SetConvar), and the replicated table it writes
--- (SetConvarReplicated). Booted unless `boot = false`.
--- @param o table|nil  { cfg = { [name] = value }, wire = table, boot = false }
local function server(o)
    o = o or {}
    local st = { cfg = o.cfg or {}, wire = o.wire or (wire()), sets = {}, served = {} }
    local env = newEnv(st)
    env.IsDuplicityVersion = function() return true end
    env.GetConvar = function(name, default)
        st.reads[name] = (st.reads[name] or 0) + 1
        if st.cfg[name] ~= nil then return st.cfg[name] end
        if st.wire[name] ~= nil then return st.wire[name] end
        return default
    end
    env.SetConvar = function(name, value)
        st.sets[#st.sets + 1] = { name = name, value = value }
        st.cfg[name] = value
    end
    env.SetConvarReplicated = function(name, value)
        st.served[#st.served + 1] = { name = name, value = value }
        st.wire[name] = value
    end
    loadInto(env, MODULE)
    loadInto(env, REGISTRY)
    st.U = env.BR.UIv2
    st.U.strict = true
    if o.boot ~= false then st.banner = st.U.boot() end
    function st.said(needle)
        for i = #st.printed, 1, -1 do
            if st.printed[i]:find(needle, 1, true) then return st.printed[i] end
        end
        return nil
    end
    return st
end

--- The local-event bus of one machine: every resource's handlers, called in
--- the order they were registered, synchronously.
local function bus()
    local b = { handlers = {}, raised = {} }
    function b.add(name, fn)
        b.handlers[name] = b.handlers[name] or {}
        table.insert(b.handlers[name], fn)
    end
    function b.raise(name, ...)
        b.raised[#b.raised + 1] = { name = name, args = { ... } }
        local list = {}
        for i, fn in ipairs(b.handlers[name] or {}) do list[i] = fn end
        for _, fn in ipairs(list) do fn(...) end
    end
    function b.count(name)
        local n = 0
        for _, e in ipairs(b.raised) do if e.name == name then n = n + 1 end end
        return n
    end
    return b
end

--- A client state on one machine. kind 'holder' is br_core's (the module, the
--- list and the real client/uiv2.lua over a stub loop registry, BR.State and
--- BR.LobbyPed); 'mirror' is br_ui's (the module and the list).
--- @param o table  { kind, wire, listeners, bus, listener = false|'raises', state, worldReady,
---                   settled = function|nil, time = table|nil }
local function client(o)
    local st = { ticks = {}, followed = {}, time = o.time or { now = 1000 } }
    local env = newEnv(st)
    env.GetConvar = function(name, default)
        st.reads[name] = (st.reads[name] or 0) + 1
        if o.wire[name] ~= nil then return o.wire[name] end
        return default
    end
    env.GetGameTimer = function() return st.time.now end
    if o.listener == 'raises' then
        env.AddConvarChangeListener = function() error('refused') end
    elseif o.listener ~= false then
        env.AddConvarChangeListener = function(filter, fn)
            o.listeners[#o.listeners + 1] = { filter = filter, fn = fn }
            return #o.listeners
        end
    end
    env.AddEventHandler = function(name, fn) o.bus.add(name, fn) end
    env.TriggerEvent = function(name, ...) o.bus.raise(name, ...) end
    loadInto(env, RES .. 'br_lib/shared/enums.lua')
    loadInto(env, MODULE)
    loadInto(env, REGISTRY)
    st.U = env.BR.UIv2
    st.U.strict = true
    st.U.onChange(function(now, before) st.followed[#st.followed + 1] = { now = now, before = before } end)
    if o.kind == 'holder' then
        local BR = env.BR
        BR.Loop = { TICK = 'tick', register = function(band, name, fn) st.ticks[#st.ticks + 1] = { name = name, fn = fn } end }
        BR.State = { me = { state = o.state or BR.PlayerState.LOBBY }, worldReady = o.worldReady }
        st.settled = true
        BR.LobbyPed = { settled = o.settled or function()
            return BR.State.me.state == BR.PlayerState.LOBBY and st.settled
        end }
        loadInto(env, HOLDER)
        st.BR = BR
        --- One TICK pass, as BR.Loop runs it.
        function st.pass()
            for _, t in ipairs(st.ticks) do t.fn(100) end
        end
        function st.to(state) BR.State.me.state = BR.PlayerState[state] end
    end
    st.BR = env.BR
    function st.f8()
        local out = {}
        for _, l in ipairs(st.printed) do
            if l:find('UI v2 here', 1, true) then out[#out + 1] = l end
        end
        return out
    end
    return st
end

--- A machine: one replicated table, one bus, a holder and (unless `mirror =
--- false`) a mirror loaded after it, as br_ui loads after br_core.
local function machine(o)
    o = o or {}
    local w, listeners = wire()
    for k, v in pairs(o.served and { br_uiv2Served = o.served } or {}) do w[k] = v end
    local b = bus()
    local m = { wire = w, bus = b }
    m.holder = client({ kind = 'holder', wire = w, listeners = listeners, bus = b, listener = o.listener,
                        state = o.state, worldReady = o.worldReady })
    if o.mirror ~= false then
        m.mirror = client({ kind = 'mirror', wire = w, listeners = listeners, bus = b })
    end
    m.listeners = listeners
    return m
end

local function readsOf(st, prefix)
    local n = 0
    for name, c in pairs(st.reads) do
        if name:lower():sub(1, #prefix) == prefix then n = n + c end
    end
    return n
end

-- =========================================================================
-- parse and resolve
-- =========================================================================

describe('uiv2.parse')
do
    local P = server({ boot = false }).U.parse
    for raw, want in pairs({ on = true, off = false, ON = true, [' Off '] = false, ['  on'] = true }) do
        local v, why = P(raw)
        ok(v == want and why == nil, ('%q is %s'):format(raw, tostring(want)))
    end
    for _, raw in ipairs({ '', '   ' }) do
        local v, why = P(raw)
        ok(v == nil and why == nil, ('%q is unset'):format(raw))
    end
    ok(P(nil) == nil and P(1) == nil and P(true) == nil, 'anything not a string is unset')
    for _, raw in ipairs({ 'of', 'true', '1', 'yes', 'onn', 'o n' }) do
        local v, why = P(raw)
        ok(v == false and why == 'bad', ('%q is not on or off: OFF, and says so'):format(raw))
    end
end

describe('uiv2.resolve')
do
    local R = server({ boot = false }).U.resolve
    -- piece | whole | answer | why (design section 3)
    local rows = {
        { 'on', 'off', true, 'piece' }, { 'off', 'on', false, 'piece' }, { 'on', '', true, 'piece' },
        { 'off', 'garbage', false, 'piece' }, { 'ON ', 'off', true, 'piece' },
        { 'of', 'on', false, 'bad' }, { 'maybe', '', false, 'bad' },
        { '', 'on', true, 'whole' }, { '', 'off', false, 'whole' }, { nil, ' On', true, 'whole' },
        { '', 'onn', false, 'bad' },
        { '', '', false, 'default' }, { nil, nil, false, 'default' },
    }
    for _, r in ipairs(rows) do
        local on, why = R(r[2], r[1])
        ok(on == r[3] and why == r[4], ('piece %q, UI v2 %q: %s (%s)'):format(tostring(r[1]), tostring(r[2]),
            tostring(r[3]), r[4]), ('got %s (%s)'):format(tostring(on), tostring(why)))
    end
end

-- =========================================================================
-- br_core's server
-- =========================================================================

describe('uiv2.boot')
do
    local s = server()
    eq(s.wire.br_uiv2Served, 'locker=off,market=off', 'nothing set: every piece off, every piece listed, sorted')
    eq(s.reads.br_uiv2, 1, 'boot reads br_uiv2 once')
    eq(s.reads.br_uiv2_locker, 1, 'and br_uiv2_locker once')
    eq(s.reads.br_uiv2_market, 1, 'and br_uiv2_market once')
    eq(#s.sets, 0, 'it never writes an operator convar')
    ok(s.U.has('locker') == false and s.U.has('market') == false and s.U.known(), 'has() answers the live answer')
    ok(s.banner[1]:find('uiv2', 1, true) and s.banner[1]:find('off (br_uiv2 is not set): locker off, market off', 1, true),
        'the banner says UI v2 is off because it is not set', s.banner[1])

    local s2 = server({ cfg = { br_uiv2 = 'on', br_uiv2_market = 'off' } })
    eq(s2.wire.br_uiv2Served, 'locker=on,market=off', 'br_uiv2 on, br_uiv2_market off: the piece wins')
    eq(s2.banner[1], '[br_core]   uiv2         on (br_uiv2 on): locker on, market off (br_uiv2_market off)',
        'the banner names the switch that decided a piece when it is its own')

    local s3 = server({ cfg = { br_uiv2 = 'on', br_uiv2_market = 'of' } })
    eq(s3.wire.br_uiv2Served, 'locker=on,market=off', 'a garbled piece switch is OFF')
    eq(s3.banner[2], '[br_core]   uiv2         br_uiv2_market "of" is not on or off: market off',
        'and the banner says so on a line of its own')
    local s4 = server({ cfg = { br_uiv2 = 'yes' } })
    eq(s4.wire.br_uiv2Served, 'locker=off,market=off', 'a garbled br_uiv2 is OFF for every piece that follows it')
    ok(s4.banner[2] and s4.banner[2]:find('br_uiv2 "yes" is not on or off: UI v2 off', 1, true), 'and says so', s4.banner[2])

    -- ALWAYS WRITTEN, even unchanged: the value a client reads is this boot's.
    local w = wire()
    w.br_uiv2Served = 'locker=on,market=on'
    local s5 = server({ wire = w })
    eq(#s5.served, 1, 'boot writes the served value every time')
    eq(s5.wire.br_uiv2Served, 'locker=off,market=off', 'and a value left by an earlier run is replaced')

    local pre = server({ boot = false })
    ok(pre.U.has('locker') == false and not pre.U.known(), 'before boot every piece is off')
end

describe('uiv2.recheck')
do
    local s = server({ cfg = { br_uiv2 = 'on' } })
    eq(s.U.recheck(), nil, 'nothing moved: nil')
    eq(#s.served, 1, 'and nothing is written')

    -- A TYPED `set br_uiv2_market off`.
    s.cfg.br_uiv2_market = 'off'
    local lines = s.U.recheck()
    eq(s.wire.br_uiv2Served, 'locker=on,market=off', 'a typed set is applied within one re-read')
    ok(s.U.has('market') == false and s.U.has('locker') == true, 'and the server answers it at once')
    ok(lines and #lines == 1, 'with one line', lines and table.concat(lines, ' | '))
    eq(lines and lines[1], '[br_core] br_uiv2_market is now "off": market off (was on)', 'naming the switch and what moved')
    eq(s.U.recheck(), nil, 'and once applied, nothing more')

    s.cfg.br_uiv2 = 'off'
    lines = s.U.recheck()
    eq(s.wire.br_uiv2Served, 'locker=off,market=off', 'UI v2 off: the follower goes with it')
    ok(lines and #lines == 1 and lines[1]:find('br_uiv2 is now "off": locker off, market off (br_uiv2_market off)', 1, true),
        'one line, every piece and why', lines and lines[1])

    s.cfg.br_uiv2_market = ''
    lines = s.U.recheck()
    ok(lines and lines[1] == '[br_core] br_uiv2_market is now unset: market off, following UI v2 (was off)',
        'a piece switch cleared by hand follows UI v2 again', lines and lines[1])

    -- THE SERVED VALUE SET BY HAND (D25).
    local n = #s.served
    s.wire.br_uiv2Served = 'locker=on,market=on'
    lines = s.U.recheck()
    eq(s.wire.br_uiv2Served, 'locker=off,market=off', 'br_uiv2Served typed by hand is written back')
    eq(#s.served, n + 1, 'in one write')
    ok(lines and #lines == 1 and lines[1] == '[br_core] br_uiv2Served was set by hand -- written back: locker off, market off',
        'with one line', lines and lines[1])
    eq(s.U.recheck(), nil, 'and then nothing')

    -- Cost: 2 + pieces reads a pass.
    local before = 0
    for _, c in pairs(s.reads) do before = before + c end
    s.U.recheck()
    local after = 0
    for _, c in pairs(s.reads) do after = after + c end
    eq(after - before, 4, 'a re-read is four convar reads: br_uiv2, both pieces, and the served value')

    local mirror = client({ kind = 'mirror', wire = (wire()), listeners = {}, bus = bus() })
    eq(mirror.U.recheck(), nil, 'a state that never booted re-reads nothing')
end

describe('uiv2.flip')
do
    local s = server({ cfg = { br_uiv2 = 'on' } })
    local lines = s.U.flip('market', 'off')
    eq(s.cfg.br_uiv2_market, 'off', 'a piece flip writes its switch')
    eq(s.wire.br_uiv2Served, 'locker=on,market=off', 'and applies at once')
    ok(lines and lines[1] == '[br_core] bruiv2: market off (was on, following UI v2)', 'what moved and why it was', lines and lines[1])
    ok(lines and lines[2] == '[br_core] bruiv2: until FXServer restarts; to keep it, in server.cfg: set br_uiv2_market off',
        'and the server.cfg line that keeps it', lines and lines[2])
    eq(s.U.recheck(), nil, 'the re-read after it finds nothing to apply')

    lines = s.U.flip('market', 'off')
    ok(lines and #lines == 1 and lines[1] == '[br_core] bruiv2: market is already off', 'the same flip again: already', lines and lines[1])

    lines = s.U.flip('market', 'auto')
    eq(s.cfg.br_uiv2_market, '', "a piece's auto clears its switch")
    eq(s.wire.br_uiv2Served, 'locker=on,market=on', 'and it follows UI v2 again')
    ok(lines and lines[1] == '[br_core] bruiv2: market follows UI v2 again: on (was off, br_uiv2_market off)', 'said so', lines and lines[1])
    ok(lines and lines[2] == '[br_core] bruiv2: until FXServer restarts; to keep it, take any br_uiv2_market line out of server.cfg',
        'and what keeps it', lines and lines[2])
    lines = s.U.flip('market', 'auto')
    ok(lines and lines[1] == '[br_core] bruiv2: market already follows UI v2', 'auto again: already', lines and lines[1])

    -- A WHOLE FLIP NAMES WHAT ITS OWN SWITCH KEEPS (A8).
    s.U.flip('market', 'on')
    lines = s.U.flip(nil, 'off')
    eq(s.cfg.br_uiv2, 'off', 'a whole flip writes br_uiv2')
    eq(s.wire.br_uiv2Served, 'locker=off,market=on', 'every follower goes, and a piece set on by itself stays')
    ok(lines and lines[1] == '[br_core] bruiv2: UI v2 off (was on)', 'UI v2 off', lines and lines[1])
    ok(lines and lines[2] == '[br_core] bruiv2:   market stays on: br_uiv2_market on', 'and the piece its switch keeps', lines and lines[2])
    ok(lines and lines[3] == '[br_core] bruiv2: until FXServer restarts; to keep it, in server.cfg: set br_uiv2 off', 'and the line', lines and lines[3])

    -- REFUSALS WRITE NOTHING.
    local sets, served = #s.sets, #s.served
    local l1, why1 = s.U.flip(nil, 'auto')
    local l2, why2 = s.U.flip('hud', 'on')
    local l3, why3 = s.U.flip('market', 'maybe')
    local l4, why4 = s.U.flip(nil, nil)
    ok(l1 == nil and why1 == 'usage', 'auto for UI v2 as a whole is refused (D14)')
    ok(l2 == nil and why2 == 'no such piece', 'an id with no row is refused')
    ok(l3 == nil and why3 == 'usage' and l4 == nil and why4 == 'usage', 'a bad word is refused')
    ok(#s.sets == sets and #s.served == served, 'and none of them writes anything')

    -- A TYPED SET SINCE THE LAST RE-READ is applied first, and the flip is
    -- judged against it.
    local t = server({ cfg = { br_uiv2 = 'on' } })
    t.cfg.br_uiv2_market = 'on'
    lines = t.U.flip('market', 'off')
    eq(t.wire.br_uiv2Served, 'locker=on,market=off', 'a flip right after a typed set lands the flip')
    ok(lines and lines[1]:find('br_uiv2_market is now "on"', 1, true) and lines[#lines]:find('set br_uiv2_market off', 1, true),
        'saying what the typed set did first', lines and table.concat(lines, ' | '))

    -- RESTART br_core: the convar holds the flip (D7).
    local w = wire()
    local a = server({ cfg = {}, wire = w })
    a.U.flip(nil, 'on')
    a.U.flip('locker', 'off')
    local b = server({ cfg = a.cfg, wire = w })
    eq(b.wire.br_uiv2Served, 'locker=off,market=on', 'a second boot (restart br_core) keeps every flip: the convars hold them')
    ok(b.banner[1]:find('on (br_uiv2 on): locker off (br_uiv2_locker off), market on', 1, true), 'and its banner shows them', b.banner[1])

    local pre = server({ boot = false })
    local lx, wx = pre.U.flip('market', 'on')
    ok(lx == nil and wx == 'not booted', 'a state that never booted flips nothing')
end

describe('uiv2.status')
do
    local s = server({ cfg = { br_uiv2 = 'on', br_uiv2_market = 'off' } })
    local L = s.U.status()
    eq(L[1], '[br_core] bruiv2: UI v2 on (br_uiv2 on)', 'UI v2 as a whole first')
    eq(L[2], '[br_core] bruiv2:   locker on  -- follows UI v2', 'each piece, its answer and why')
    eq(L[3], '[br_core] bruiv2:   market off -- br_uiv2_market off', 'its own switch when that decides it')
    ok(L[4] and L[4]:find('players take a change standing in the lobby or as their next match starts', 1, true),
        'and when players take a change', L[4])
    local g = server({ cfg = { br_uiv2_locker = 'maybe' } })
    local G = g.U.status()
    ok(G[1] == '[br_core] bruiv2: UI v2 off (br_uiv2 is not set)' and G[2]:find('br_uiv2_locker "maybe" is not on or off', 1, true),
        'a garbled switch is named as one', G[2])
    eq(#s.sets, 0, 'the status writes nothing')
end

-- =========================================================================
-- the holder (br_core's client) and the mirror (br_ui's)
-- =========================================================================

describe('holder.first')
do
    -- THE FIRST ANSWER AT ONCE, IN ANY STATE.
    local m = machine({ served = 'locker=on,market=off', state = 'alive' })
    ok(m.holder.U.has('locker') == true and m.holder.U.has('market') == false, 'the first answer is taken at load, mid-match included')
    eq(#m.holder.f8(), 1, 'one F8 line')
    eq(m.holder.f8()[1], '[br_core] UI v2 here: locker on, market off', 'naming every piece')
    ok(#m.holder.followed == 1 and m.holder.followed[1].before == nil,
        'a follower hears the first answer too, with nothing before it')

    -- NOT LANDED YET: unknown until it does, then at once.
    local n = machine({ state = 'alive' })
    ok(not n.holder.U.known() and n.holder.U.has('locker') == false, 'no served value yet: unknown, every piece off')
    n.wire.br_uiv2Served = 'locker=off,market=on'
    n.holder.pass()
    ok(n.holder.U.has('market') == true, 'the value landing mid-match is still the first answer: taken on the next pass')
    eq(n.bus.count('br:uiv2:held'), 1, 'and every mirror is told')
end

describe('holder.lobby')
do
    local m = machine({ served = 'locker=off,market=off' })
    local H = m.holder
    H.settled = false
    m.wire.br_uiv2Served = 'locker=on,market=on'
    for _ = 1, 5 do H.pass() end
    ok(H.U.has('locker') == false, 'in the lobby with the entrance running (the walk-in): held')
    H.settled = true
    H.pass()
    ok(H.U.has('locker') == true and H.U.has('market') == true, 'standing in the lobby with the entrance over: taken')
    eq(#H.followed, 2, 'followers told once (after the first answer)')
    eq(H.followed[2].now, 'locker=on,market=on', 'with the new text')
    eq(H.followed[2].before, 'locker=off,market=off', 'and the old')
    H.pass()
    H.pass()
    eq(#H.followed, 2, 'and not again while nothing moves')
    eq(#H.f8(), 2, 'one F8 line per move')
end

describe('holder.nextmatch')
do
    -- THE FIRST PASS OUT OF THE LOBBY: a ready-up during the walk-in.
    local m = machine({ served = 'locker=off,market=off' })
    local H = m.holder
    H.settled = false                         -- the walk-in, ARMED then RUNNING
    m.wire.br_uiv2Served = 'locker=on,market=on'
    H.pass()
    H.pass()
    ok(H.U.has('market') == false, 'LOBBY passes with the entrance running: held')
    H.to('WARMUP')
    H.pass()
    ok(H.U.has('market') == true, 'taken on the WARMUP pass: the next match starting, behind its curtain')
    -- HELD THROUGH THE MATCH.
    m.wire.br_uiv2Served = 'locker=off,market=off'
    for _, st in ipairs({ 'WARMUP', 'BUS', 'FREEFALL', 'GLIDE', 'ALIVE', 'DBNO', 'OUT' }) do
        H.to(st)
        H.pass()
        H.pass()
        ok(H.U.has('market') == true, 'held in ' .. st)
    end
    eq(#H.followed, 2, 'nothing moved through the match')
    -- The sweep to the lobby: the teardown, the trip home and the walk-in.
    H.to('LOBBY')
    H.settled = false
    H.pass()
    H.pass()
    ok(H.U.has('market') == true, 'back in the lobby with the entrance running: still held')
    H.settled = true
    H.pass()
    ok(H.U.has('market') == false, 'taken on the first pass standing again')
end

describe('holder.loadingscreen')
do
    local m = machine({ served = 'locker=off,market=off', worldReady = false, state = 'alive' })
    local H = m.holder
    m.wire.br_uiv2Served = 'locker=on,market=off'
    H.pass()
    ok(H.U.has('locker') == true, 'while the loading screen is up, a move is taken in any state')
    H.BR.State.worldReady = true
    m.wire.br_uiv2Served = 'locker=off,market=off'
    H.pass()
    ok(H.U.has('locker') == true, 'once it is down, mid-match, it is held')
end

describe('holder.unknownkept')
do
    local m = machine({ served = 'locker=on,market=on' })
    local H = m.holder
    m.wire.br_uiv2Served = ''
    H.pass()
    ok(H.U.has('locker') == true and H.U.known(), 'an empty served value keeps what is held')
    m.wire.br_uiv2Served = 'garbage'
    H.pass()
    ok(H.U.has('locker') == true, 'so does one that does not decode')
    m.wire.br_uiv2Served = 'locker=off,market=on,hud=on'
    H.pass()
    ok(H.U.has('locker') == false and H.U.has('market') == true, 'a text naming a piece with no row is still read')
    local okRaise = pcall(H.U.has, 'hud')
    ok(not okRaise, 'and asking for that piece is the typo it is (strict raises)')
end

describe('holder.events')
do
    local m = machine({ served = 'locker=off,market=off' })
    local raised = {}
    for _, e in ipairs(m.bus.raised) do if e.name == 'br:uiv2:held' then raised[#raised + 1] = e.args[1] end end
    eq(raised[1], 'locker=off,market=off', 'br:uiv2:held is raised with the text the holder took')
    m.wire.br_uiv2Served = 'locker=on,market=off'
    m.holder.pass()
    eq(m.bus.raised[#m.bus.raised].args[1], 'locker=on,market=off', 'and again on every move')
    eq(m.bus.count('br:uiv2:held'), 3, 'once per move, and once to the mirror that asked as it loaded')
end

describe('holder.nolistener')
do
    local m = machine({ served = 'locker=off,market=off', listener = false, mirror = false })
    local H = m.holder
    m.wire.br_uiv2Served = 'locker=on,market=off'
    local reads = H.reads.br_uiv2Served or 0
    H.pass()
    ok(H.U.has('locker') == false and (H.reads.br_uiv2Served or 0) == reads, 'no listener: no read inside a second')
    H.time.now = H.time.now + 1000
    H.pass()
    ok(H.U.has('locker') == true, 'a second on, the served value is read again and taken')
    local before = H.reads.br_uiv2Served
    for _ = 1, 9 do
        H.time.now = H.time.now + 100
        H.pass()
    end
    ok(H.reads.br_uiv2Served - before <= 1, 'at most once a second', H.reads.br_uiv2Served - before)

    local r = machine({ served = 'locker=on,market=on', listener = 'raises', mirror = false })
    ok(r.holder.U.has('locker') == true, 'a listener that refuses leaves the re-read: the module still loads and holds')
end

describe('holder.cost')
do
    local m = machine({ served = 'locker=on,market=on' })
    local H = m.holder
    local reads = 0
    for _, c in pairs(H.reads) do reads = reads + c end
    for _ = 1, 50 do H.pass() end
    local after = 0
    for _, c in pairs(H.reads) do after = after + c end
    eq(after - reads, 0, 'with the listener, a pass that finds nothing new reads no convar')
end

describe('client.reads')
do
    local m = machine({ served = 'locker=on,market=off' })
    m.wire.br_uiv2Served = 'locker=off,market=on'
    m.holder.pass()
    m.holder.to('WARMUP')
    m.holder.pass()
    for _, st in ipairs({ m.holder, m.mirror }) do
        local direct = 0
        for name, c in pairs(st.reads) do
            local l = name:lower()
            if l == 'br_uiv2' or (l:sub(1, 8) == 'br_uiv2_') then direct = direct + c end
        end
        eq(direct, 0, 'no client state ever reads br_uiv2 or a br_uiv2_<piece>')
    end
    eq(readsOf(m.mirror, 'br_uiv2'), 0, 'and the mirror reads no convar at all')
end

describe('mirror')
do
    -- UNKNOWN UNTIL TOLD; ASKS AT LOAD.
    local w, listeners = wire()
    local b = bus()
    local mir = client({ kind = 'mirror', wire = w, listeners = listeners, bus = b })
    ok(not mir.U.known() and mir.U.has('market') == false, 'a mirror with no holder: unknown, every piece off')
    eq(b.count('br:uiv2:ask'), 1, 'it asked as it loaded')

    -- THE HOLDER ANSWERS ASKS ONLY ONCE IT HOLDS SOMETHING.
    local hol = client({ kind = 'holder', wire = w, listeners = listeners, bus = b })
    ok(not hol.U.known(), 'a holder with nothing served holds nothing')
    b.raise('br:uiv2:ask')
    eq(b.count('br:uiv2:held'), 0, 'and answers no ask')
    w.br_uiv2Served = 'locker=off,market=on'
    hol.pass()
    ok(mir.U.has('market') == true, 'the first answer reaches the mirror')
    eq(#mir.followed, 1, 'and its followers, once')
    b.raise('br:uiv2:ask')
    ok(b.count('br:uiv2:held') == 2 and mir.U.has('market') == true, 'an ask now is answered with what is held')
    eq(#mir.followed, 1, 'and the same text moves nothing in the mirror')

    -- A MIRROR LOADED LATER (br_ui restarted) asks and is told at once.
    local late = client({ kind = 'mirror', wire = w, listeners = listeners, bus = b })
    ok(late.U.has('market') == true and late.U.has('locker') == false, 'a mirror restarted mid-session is told the held answer at load')

    -- THE MIRROR FOLLOWS THE HOLD, NOT THE WIRE.
    hol.to('ALIVE')
    hol.pass()                                -- the match has started
    w.br_uiv2Served = 'locker=on,market=off'
    hol.pass()
    ok(mir.U.has('market') == true, 'mid-match the wire moved and the mirror did not')
    hol.to('LOBBY')
    hol.pass()
    ok(mir.U.has('market') == false and mir.U.has('locker') == true, 'the holder takes it standing in the lobby, and the mirror with it')
    eq(#mir.followed, 2, 'one follower call per move')
    ok(hol.U.has('locker') == true and #hol.followed == 2, 'the holder ignores its own br:uiv2:held')

    -- A garbled or empty text told to a mirror moves nothing.
    b.raise('br:uiv2:held', 'nonsense')
    b.raise('br:uiv2:held', '')
    b.raise('br:uiv2:held', 7)
    ok(mir.U.has('locker') == true and #mir.followed == 2, 'a held text that does not decode moves no mirror')
end

describe('restart br_core')
do
    -- The holder's Lua state goes and comes back; the mirror stays.
    local w, listeners = wire()
    w.br_uiv2Served = 'locker=on,market=on'
    local b = bus()
    client({ kind = 'holder', wire = w, listeners = listeners, bus = b })
    local mir = client({ kind = 'mirror', wire = w, listeners = listeners, bus = b })
    ok(mir.U.has('market') == true, 'precondition: the mirror holds the answer')
    w.br_uiv2Served = 'locker=off,market=off'
    -- A new br_core client: a fresh state on the same bus, first answer at once.
    local fresh = client({ kind = 'holder', wire = w, listeners = listeners, bus = b, state = 'lobby' })
    ok(fresh.U.has('market') == false, 'the fresh holder takes its first answer at once')
    ok(mir.U.has('market') == false, 'and the mirror is told')
end

-- =========================================================================
-- the command, over devgate's real wrap, dev mode OFF
-- =========================================================================

--- A br_core server with `bruiv2` loaded the way the game loads it: the
--- protocol, devgate.lua's wrap in front of RegisterCommand, the UI v2 module
--- and its list, booted, then server/uiv2.lua.
local function commandServer(o)
    o = o or {}
    local s = server({ cfg = o.cfg, boot = false })
    local env = s.env
    s.raw = {}
    s.dev = o.dev == true
    local get = env.GetConvar
    env.GetConvar = function(name, default)
        if name == 'sv_devMode' or name == 'br_devMode' then return s.dev and 'true' or 'false' end
        return get(name, default)
    end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.RegisterCommand = function(name, fn, restricted) s.raw[name] = { fn = fn, restricted = restricted } end
    s.toClients = 0
    env.TriggerClientEvent = function() s.toClients = s.toClients + 1 end
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua', 'br_lib/shared/devgate.lua' }) do
        loadInto(env, RES .. f)
    end
    -- devgate.lua was loaded after the module here, so its wrap is in front of
    -- the command file below, as in the manifest.
    s.U.boot()
    loadInto(env, COMMAND)
    function s.run(src, ...) s.raw.bruiv2.fn(src, { ... }, 'bruiv2') end
    function s.clear() for k in pairs(s.printed) do s.printed[k] = nil end end
    return s
end

describe('bruiv2: on any box, the console only')
do
    local s = commandServer({ dev = false, cfg = { br_uiv2 = 'on' } })
    ok(s.raw.bruiv2 ~= nil, 'bruiv2 reaches the native')
    eq(s.raw.bruiv2 and s.raw.bruiv2.restricted, true, 'registered restricted')
    s.run(0, 'market', 'off')
    eq(s.wire.br_uiv2Served, 'locker=on,market=off', 'dev mode off: the console flips it all the same')
    ok(s.said('is dev-mode only') == nil, 'and the dev gate says nothing: it is exempt')

    -- A PLAYER'S F8, an admin's included.
    s.clear()
    local sets, served = #s.sets, #s.served
    s.run(3, 'market', 'on')
    s.run(3, 'off')
    s.run(3)
    ok(#s.sets == sets and #s.served == served and s.wire.br_uiv2Served == 'locker=on,market=off',
        'from a player nothing is written and nothing moves')
    eq(#s.printed, 3, 'one line a try')
    eq(s.printed[1], '  bruiv2 is server-console only', 'to this console: who may type it')
    eq(s.toClients, 0, 'and nothing is sent to any client, the typer included')

    -- BARE: THE STATUS, AND THE USAGE.
    s.clear()
    s.run(0)
    ok(s.printed[1] == '[br_core] bruiv2: UI v2 on (br_uiv2 on)' and s.said('market off -- br_uiv2_market off') ~= nil,
        'bare: every switch, its answer and why', s.printed[1])
    eq(s.printed[#s.printed], '[br_core] bruiv2: usage: bruiv2 | bruiv2 on|off | bruiv2 <locker|market> on|off|auto',
        'and the usage line')

    -- THE FORMS, AND WHAT IS REFUSED.
    s.clear()
    s.run(0, 'OFF')
    eq(s.cfg.br_uiv2, 'off', 'UI v2 as a whole, any case')
    s.clear()
    sets = #s.sets
    s.run(0, 'auto')
    s.run(0, 'market')
    s.run(0, 'market', 'off', 'now')
    s.run(0, 'locker', 'maybe')
    eq(#s.sets, sets, 'auto alone, a piece with no word, extra words and a bad word write nothing')
    eq(#s.printed, 4, 'one line each')
    ok(s.printed[1]:find('usage: bruiv2', 1, true) and s.printed[4]:find('usage: bruiv2', 1, true), 'the usage line', s.printed[1])
    s.clear()
    s.run(0, 'hud', 'on')
    eq(s.printed[1], '[br_core] bruiv2: "hud" is not a piece of UI v2 -- locker, market', 'a piece with no row names the pieces there are')
    s.clear()
    s.run(0, 'Locker', 'AUTO')
    ok(s.said('locker already follows UI v2') ~= nil, 'a piece and its word in any case')
end

-- =========================================================================
-- the wiring
-- =========================================================================

--- Every quoted entry of one manifest block, in order.
local function entries(manifest, block)
    local body = manifest:match(block .. '%s*(%b{})') or ''
    local out = {}
    for line in body:gmatch('[^\n]+') do
        local e = line:match("^%s*'([^']+)'")
        if e then out[#out + 1] = e end
    end
    return out
end
local function indexOf(list, v)
    for i, x in ipairs(list) do if x == v then return i end end
    return nil
end

describe('uiv2.wiring')
do
    local core = assert(readFile(RES .. 'br_core/fxmanifest.lua'))
    local shared = entries(core, 'shared_scripts')
    local s1, s2 = indexOf(shared, '@br_lib/config/seasons.lua'), indexOf(shared, '@br_lib/shared/uiv2.lua')
    ok(s1 and s2 == s1 + 1 and shared[s2 + 1] == '@br_lib/config/uiv2.lua',
        "br_core's shared scripts load the module and the list right after the season pair")
    local cs = entries(core, 'client_scripts')
    local main, hold, spawn = indexOf(cs, 'client/main.lua'), indexOf(cs, 'client/uiv2.lua'), indexOf(cs, 'client/spawn.lua')
    ok(main and hold == main + 1, 'client/uiv2.lua right after client/main.lua')
    ok(hold and spawn and hold < spawn, "and ahead of client/spawn.lua, so 'uiv2.adopt' runs before 'spawn.gather'")
    local ss = entries(core, 'server_scripts')
    local sea, cmd = indexOf(ss, 'server/season.lua'), indexOf(ss, 'server/uiv2.lua')
    ok(sea and cmd and cmd > sea, 'server/uiv2.lua after server/season.lua')

    local ui = assert(readFile(RES .. 'br_ui/fxmanifest.lua'))
    local ucs = entries(ui, 'client_scripts')
    local u1, u2, mk = indexOf(ucs, '@br_lib/config/seasons.lua'), indexOf(ucs, '@br_lib/shared/uiv2.lua'), indexOf(ucs, 'client/market.lua')
    ok(u1 and u2 == u1 + 1 and ucs[u2 + 1] == '@br_lib/config/uiv2.lua' and mk and mk > u2 + 1,
        "br_ui loads the module and the list right after the season pair, above client/market.lua")

    local main_ = assert(readFile(RES .. 'br_core/server/main.lua'))
    local _, boots = main_:gsub('BR%.UIv2%.boot%(%)', '')
    eq(boots, 1, 'server/main.lua boots UI v2 once')
    local sb, ub = main_:find('BR.Season.boot()', 1, true), main_:find('BR.UIv2.boot()', 1, true)
    ok(sb and ub and ub > sb, 'after the season boots')
    ok(main_:find("BR.Sched.every(5000, 'uiv2.watch'", 1, true) ~= nil, 'and its 5 s re-read beside the season watch')
    ok(main_:find('for _, l in ipairs(uiv2Lines) do print(l) end', 1, true) ~= nil, 'and prints its banner lines')

    local dg = assert(readFile(RES .. 'br_lib/shared/devgate.lua'))
    local line = dg:match('\n(local EXEMPT = {[^\n]*)')
    ok(line ~= nil and line:find('bruiv2 = true', 1, true) ~= nil, "devgate's one-line EXEMPT has bruiv2", line)

    local cfg = assert(readFile('server.cfg.example'))
    local at, ensureAt, live, block = nil, nil, nil, {}
    local n, inBlock = 0, false
    for l in (cfg .. '\n'):gmatch('([^\n]*)\n') do
        n = n + 1
        if l:match('^# UI v2 %(#436%)') then inBlock = true end
        if inBlock then
            if l == '' then inBlock = false else block[#block + 1] = l end
        end
        if l:match('^#%s*set br_uiv2 on%s*$') then at = at or n end
        if l:match('^ensure br_core') then ensureAt = ensureAt or n end
        if l:lower():match('^%s*setr?%s+br_uiv2') then live = live or l end
    end
    ok(at ~= nil and ensureAt ~= nil and at < ensureAt, 'server.cfg.example carries a commented `set br_uiv2 on` above `ensure br_core`')
    ok(live == nil, 'and no uncommented br_uiv2 line', live)
    local text = table.concat(block, '\n')
    ok(#block >= 3 and not text:find(';', 1, true) and not text:find('"', 1, true),
        'and no ; or " in the UI v2 block: FXServer cuts a command at a ; before it knows # is a comment', text)
end

-- ------------------------------------------------------------------ done ---

realPrint(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    realPrint(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
