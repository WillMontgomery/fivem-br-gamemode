-- Unit tests for Control Tower's wave B functions (#396, 2026-10-06): the four
-- that change the world everybody in the match stands in -- Storm delay,
-- Storm control, Time & weather and Power outage.
--
-- The door in front of them (the session, the key, the squad's one use, the
-- Volts, the 3-5 s load, the lobby's notice, the refund) is
-- tools/test_terminal.lua's and tools/test_terminalfx.lua's. This file stands
-- up the REAL server/terminal.lua, server/terminalfx.lua, server/storm.lua and
-- every `server/terminalfx/` file the manifest lists, over a stubbed roster,
-- key and market, and runs each function at a real terminal, the real way:
--
--   PART A  Storm delay: the hold the page names gets longer, through the
--           storm record's own timing; refused `no_storm` / `no_hold` with
--           nothing spent; everything given back when the hold runs out while
--           it loads; the dev path.
--
-- The storm's own half -- BR.Storm.delay against the real phase job, the 75%
-- cut, a client's countdown -- is tools/test_storm.lua's `delay.*` blocks.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_terminalworld.lua

local realPrint = print
local realExit  = os.exit

local gameMs = 1000000
function GetGameTimer() return gameMs end
function GetCurrentResourceName() return 'br_core' end

local ROOT = 'resources/[fivem-royale]/'
local function loadAll(files)
    for _, f in ipairs(files) do
        local chunk, err = loadfile(ROOT .. f)
        if not chunk then
            realPrint('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
            realExit(1)
        end
        chunk()
    end
end

local function readFile(path)
    local fh = io.open(path, 'rb')
    if not fh then return nil end
    local s = fh:read('a')
    fh:close()
    return s
end

--- The function files br_core's manifest lists under `<side>/terminalfx/`, in
--- its order: a file the manifest forgot is a function this suite finds unbuilt.
--- @param side string  'server' | 'client'
--- @return string[]  paths under ROOT
local function fxFiles(side)
    local text = readFile(ROOT .. 'br_core/fxmanifest.lua') or ''
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

local logs = {}
function print(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
    logs[#logs + 1] = table.concat(parts, ' ')
end

--- A line the code printed that says something threw, or nil.
local function errored()
    for _, l in ipairs(logs) do
        if l:find('errored', 1, true) or l:find('stack traceback', 1, true) then return l end
    end
    return nil
end

-- =========================================================================
-- THE SERVER
-- =========================================================================

local convars = { sv_devMode = 'true', br_season = '2' }
function GetConvar(n, d)
    local v = convars[n]
    if v == nil then return d end
    return v
end
function SetConvarReplicated(n, v) convars[n] = v end

local commands = {}
function RegisterCommand(name, fn) commands[name] = fn end
Citizen = { CreateThread = function() end, Wait = function() end, SetTimeout = function() end }

loadAll({
    'br_lib/shared/devgate.lua',
    'br_lib/shared/enums.lua',
    'br_lib/shared/protocol.lua',
    'br_lib/shared/notice.lua',
    'br_lib/shared/matchtag.lua',
    'br_lib/shared/rng.lua',
    'br_lib/shared/geo.lua',
    'br_lib/shared/polygon.lua',
    'br_lib/shared/clock.lua',
    'br_lib/shared/world.lua',
    'br_lib/shared/sched.lua',
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/audio.lua',
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
    'br_lib/config/terminals.lua',
    'br_lib/shared/storm_solve.lua',
    'br_lib/shared/storm_shape.lua',
    'br_lib/shared/health_solve.lua',
    'br_lib/shared/terminal_solve.lua',
    'br_lib/shared/shop_solve.lua',
})
BR.Config.Market = { currency = 'Volts' }

local CT = BR.Config.Terminals
local COPY = CT.copy
local TS = BR.TerminalSolve
BR.Season.strict = true

local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end
season(2)

-- ---------------------------------------------------------------- stubs ---

local handlers = {}
local timers = {}
function SetTimeout(ms, fn) timers[#timers + 1] = { at = gameMs + ms, fn = fn } end
local sent = {}          -- TriggerClientEvent: { event, src, payload }
local notices = {}       -- BR.Server.notify: { target, text, tone }
local keys = {}          -- [src] = true while holding a Yubikey

function RegisterNetEvent() end
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function TriggerClientEvent(event, src, payload)
    sent[#sent + 1] = { event = event, src = src, payload = payload }
end

local roster, matches = {}, {}
function GetPlayerName(src) return roster[src] and roster[src].name or nil end

BR.Roster = {
    get = function(src) return roster[src] end,
    each = function(pred, fn)
        local order = {}
        for src in pairs(roster) do order[#order + 1] = src end
        table.sort(order)
        for _, src in ipairs(order) do
            local e = roster[src]
            if not pred or pred(e) then fn(src, e) end
        end
    end,
    update = function(src, changes)
        local e = roster[src]
        if not e then return nil end
        for k, v in pairs(changes) do e[k] = v end
        return e
    end,
}
BR.Server = {
    devMode = true,
    matches = matches,
    matchOf = function(src)
        local e = roster[src]
        return e and e.matchId and matches[e.matchId] or nil
    end,
    eachMatch = function(fn)
        local order = {}
        for _, m in pairs(matches) do order[#order + 1] = m end
        table.sort(order, function(a, b) return a.id < b.id end)
        for _, m in ipairs(order) do fn(m) end
    end,
    latestMatch = function()
        local best
        for _, m in pairs(matches) do if not best or m.id > best.id then best = m end end
        return best
    end,
    notify = function(target, text, tone)
        notices[#notices + 1] = { target = target, text = text, tone = tone }
    end,
    isInMatch = function(st)
        return st == BR.PlayerState.ALIVE or st == BR.PlayerState.DBNO
            or st == BR.PlayerState.FREEFALL or st == BR.PlayerState.GLIDE
    end,
}
BR.Broadcast = {
    toMatch = function(m, event, payload)
        local order = {}
        for src, e in pairs(roster) do
            if e.matchId == m.id then order[#order + 1] = src end
        end
        table.sort(order)
        for _, src in ipairs(order) do TriggerClientEvent(event, src, payload) end
    end,
}
BR.Combat = { bleed = function() end, defeat = function() end }
BR.Yubikey = {
    holds = function(src) return keys[src] == true end,
    take = function(src) local had = keys[src] == true; keys[src] = false; return had end,
    push = function() end,
    licenseOf = function(src) return 'license:' .. src end,
    restore = function(lic)
        local src = tonumber(tostring(lic):match('(%d+)$'))
        if not src or keys[src] == true then return false end
        keys[src] = true
        return true
    end,
}
local market = { wallet = {}, charges = {}, refunds = {} }
BR.Market = {
    balanceOf = function(src) return market.wallet[src] or 0 end,
    licenseOf = function(src) return roster[src] and ('license:' .. src) or nil end,
    charge = function(src, cost, reason, done)
        market.charges[#market.charges + 1] = { src = src, cost = cost, reason = reason }
        if (market.wallet[src] or 0) < cost then done(false, 'cannot afford it') return end
        market.wallet[src] = market.wallet[src] - cost
        done(true, nil, market.wallet[src])
    end,
    refund = function(lic, amount)
        market.refunds[#market.refunds + 1] = { lic = lic, amount = amount }
        local src = tonumber(tostring(lic):match('(%d+)$'))
        market.wallet[src] = (market.wallet[src] or 0) + amount
    end,
}

loadAll({
    'br_core/server/storm.lua',
    'br_core/server/terminal.lua',
    'br_core/server/terminalfx.lua',
})
-- WAVE B'S OWN FILES ONLY. Every other built row is a function this suite does
-- not stand up: its row lists as fn_offline here, and its own suite runs it.
local WAVE_B = { 'storm_delay' }
local SERVER_FX = {}
for _, f in ipairs(fxFiles('server')) do
    for _, id in ipairs(WAVE_B) do
        if f == 'br_core/server/terminalfx/' .. id .. '.lua' then SERVER_FX[#SERVER_FX + 1] = f end
    end
end
loadAll(SERVER_FX)

local T = BR.Terminal
-- The other functions' collaborators, which a listing asks about: models with
-- their contract (tools/test_terminalfx.lua holds the real ones' use).
BR.Airdrop = {
    busy = function() return false end,
    candidate = function(_, x, y) return { id = 'poi', x = x, y = y } end,
    call = function() return nil, 'no_site' end,
}
BR.Inv = { ammoRoom = function() return 0 end, fillAmmo = function() return 0 end }
-- The storm's own jobs stand down: every block here sets up the record it
-- means, and steps the phase job itself where it needs one.
BR.Sched.setEnabled('storm.phase', false)
BR.Sched.setEnabled('storm.damage', false)

local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
end

--- Let every pending timer run, the clock moved to each one's time: a run's
--- loading, over.
local function flush()
    for _ = 1, 20 do
        if #timers == 0 then return end
        local due = timers
        timers = {}
        table.sort(due, function(a, b) return a.at < b.at end)
        for _, t in ipairs(due) do
            if t.at > gameMs then gameMs = t.at end
            t.fn()
        end
    end
end

local function eventsOf(name, src)
    local out = {}
    for _, s in ipairs(sent) do
        if s.event == name and (src == nil or s.src == src) then out[#out + 1] = s end
    end
    return out
end

local function lastOf(name, src)
    local e = eventsOf(name, src)
    return e[#e] and e[#e].payload or nil
end

local function textOf(n)
    if type(n.text) == 'table' then return n.text.text end
    return n.text
end

local function noticesTo(src)
    local out = {}
    for _, n in ipairs(notices) do
        local t = n.target
        if t == src then out[#out + 1] = n
        elseif type(t) == 'table' then
            for _, s in ipairs(t) do if s == src then out[#out + 1] = n break end end
        end
    end
    return out
end

-- THE WORLD: a terminal at the middle of a phase-3 circle, a second one far
-- away, and the storm holding around both.
local C0 = { x = 200.0, y = -600.0 }
local SITE = { id = 'tower', x = C0.x, y = C0.y, z = 30.0, h = 0.0 }
CT.sites = { SITE, { id = 'shack', x = C0.x + 400.0, y = C0.y + 300.0, z = 30.0, h = 0.0 } }

local SEED = 4242

--- A match playing phase `phase` (default 3), holding for `waitMs`.
local function newMatch(id, mode, phase, waitMs)
    phase = phase or 3
    local P = BR.Config.Storm.phases
    local r0 = phase > 1 and P[phase - 1].radius or 4000.0
    local m = {
        id = id, seq = id, state = BR.MatchState.PLAYING, mode = mode or 'squad',
        startedAt = gameMs - 300000,
        stormSeed = SEED, stormRng = BR.Rng(SEED + id),
    }
    m.storm = BR.BuildStormRecord(phase, C0.x, C0.y, r0, C0.x + 20.0, C0.y, P[phase].radius,
        gameMs, waitMs or 90000, 90000, P[phase].dps, SEED)
    matches[id] = m
    return m
end

local function player(src, m, squad, at, state)
    roster[src] = {
        src = src, name = 'p' .. src, state = state or BR.PlayerState.ALIVE,
        matchId = m and m.id or nil, squadId = squad,
        pos = at and { x = at.x, y = at.y, z = at.z or 30.0 } or nil,
    }
end

local function reset()
    flush()
    sent, notices, logs = {}, {}, {}
    for k in pairs(roster) do roster[k] = nil end
    for k in pairs(matches) do matches[k] = nil end
    for k in pairs(keys) do keys[k] = nil end
    timers = {}
    market.wallet, market.charges, market.refunds = {}, {}, {}
    gameMs = gameMs + 100000
end

--- Two squads and a solo player: A = 1, 2; B = 3, 4; solo 5. Player 1 stands
--- at the terminal with a key.
local function lobby(mode, phase, waitMs)
    local m = newMatch(1, mode, phase, waitMs)
    local squadA = (mode or 'squad') == 'squad' and 'A' or nil
    local squadB = (mode or 'squad') == 'squad' and 'B' or nil
    player(1, m, squadA, SITE)
    player(2, m, squadA, { x = C0.x + 40.0, y = C0.y })
    player(3, m, squadB, { x = C0.x + 300.0, y = C0.y + 10.0 })
    player(4, m, squadB, { x = C0.x + 310.0, y = C0.y - 10.0 })
    player(5, m, nil, { x = C0.x - 500.0, y = C0.y })
    keys[1] = true
    for src = 1, 5 do market.wallet[src] = 1000 end
    return m
end

--- Open the terminal for `src` the real way and ask to run `id`. With `hold`,
--- the loading is left running (the caller flushes it); otherwise it is let
--- run out and the last word is answered.
local function runAt(src, id, options, hold)
    fire(BR.Net.TERMINAL_USE, src, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, src, { terminalId = 'tower', functionId = id, options = options })
    if not hold then flush() end
    return lastOf(BR.Net.TERMINAL_RESULT, src)
end

--- The terminal's listing of `id` for `src`, as the open computer has it.
local function listed(src, id)
    local st = T.state(src, T.session(src))
    for _, f in ipairs(st.functions) do
        if f.id == id then return f end
    end
    return nil
end

--- Type `brterminalsv <line>` as `src`.
local function sv(src, line)
    local args = {}
    for w in line:gmatch('%S+') do args[#args + 1] = w end
    commands.brterminalsv(src, args)
end

--- Nothing was spent: the key, the squad's use, and every Volt.
local function nothingSpent(src, label)
    eq(keys[src], true, label .. ': the key stays')
    ok(not T.squadUsed(src), label .. ': the squad\'s use stays')
    local paid = 0
    for _, c in ipairs(market.charges) do if c.src == src then paid = paid + c.cost end end
    local back = 0
    for _, r in ipairs(market.refunds) do if r.lic == 'license:' .. src then back = back + r.amount end end
    eq(paid - back, 0, label .. ': no Volts')
end

-- =========================================================================
-- THE REGISTRY: wave B's rows are built and have their server halves
-- =========================================================================

describe('wave B: the four rows are built, each a file the manifest lists')
do
    for _, id in ipairs(WAVE_B) do
        local row = T.row(id)
        ok(row and row.implemented == true, id .. ' is marked built')
        ok(T.FUNCTIONS[id] ~= nil and type(T.FUNCTIONS[id].run) == 'function', id .. ' has a server half')
        local file = 'br_core/server/terminalfx/' .. id .. '.lua'
        local found = false
        for _, f in ipairs(SERVER_FX) do if f == file then found = true end end
        ok(found, id .. "'s server half is its own file, listed in the manifest: " .. file)
    end
end

-- =========================================================================
-- PART A -- Storm delay
-- =========================================================================

describe('Storm delay: the current hold gets longer by the time chosen')
do
    reset()
    local m = lobby('squad', 3, 90000)
    local rec0 = m.storm
    local r = runAt(1, 'storm_delay', { delay = '120' })
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    eq(r and r.toast, COPY.storm_delay_done, 'and says the page\'s done line')
    local rec = m.storm
    eq(rec.tWait, rec0.tWait + 120000, 'two minutes more hold, the record\'s own tWait')
    ok(rec.cx1 == rec0.cx1 and rec.cy1 == rec0.cy1 and rec.r1 == rec0.r1
        and rec.cx0 == rec0.cx0 and rec.tStart == rec0.tStart,
        'the circles and the clock it started on do not move')
    local syncs = {}
    for _, e in ipairs(eventsOf(BR.Net.STORM_SYNC)) do syncs[e.src] = e.payload end
    for src = 1, 5 do
        ok(syncs[src] == rec, ('p%d is sent the delayed record'):format(src))
    end
    eq(keys[1], false, 'the key is spent')
    ok(T.squadUsed(1) and T.squadUsed(2), 'and the squad\'s one use')
    local heard = 0
    for _, n in ipairs(noticesTo(3)) do
        if textOf(n) == 'p1 has redeemed their special power: ' .. COPY.storm_delay_description then
            heard = heard + 1
        end
    end
    eq(heard, 1, 'the lobby hears it once, in the function\'s description')
    ok(errored() == nil, 'clean', errored())
end

describe('Storm delay: closing, the delay goes to the next hold')
do
    reset()
    local m = lobby('squad', 3, 90000)
    -- The hold is over and the wall is moving.
    m.storm.tStart = gameMs - 100000
    local rec0 = m.storm
    local r = runAt(1, 'storm_delay', { delay = '60' })
    ok(r and r.code == 'done', 'it runs while the wall moves', r and r.code)
    ok(m.storm == rec0, 'the sweep in progress is left exactly as it is')
    eq(m.stormDelayNextMs, 60000, 'and the minute waits for the next hold')
    -- The next phase, entered the ordinary way: its hold is a minute longer.
    BR.Sched.setEnabled('storm.phase', true)
    gameMs = rec0.tStart + rec0.tWait + rec0.tShrink + 1000
    BR.Sched.step(gameMs)
    BR.Sched.setEnabled('storm.phase', false)
    eq(m.storm.phase, 4, 'phase 4 is drawn')
    eq(m.storm.tWait, BR.Config.Storm.phases[4].wait * 1000 + 60000, 'its hold is the authored one and a minute')
    ok(errored() == nil, 'clean', errored())
end

describe('Storm delay: no storm, no hold -- refused, nothing spent')
do
    reset()
    local m = lobby('squad', 3)
    local rec = m.storm
    -- THE FINAL CIRCLE CLOSING: no hold left.
    local last = #BR.Config.Storm.phases
    m.storm = BR.BuildStormRecord(last, C0.x, C0.y, 400.0, C0.x, C0.y, 0.0,
        gameMs - 40000, 30000, 600000, 6.7, SEED)
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local f = listed(1, 'storm_delay')
    ok(f and f.available == false and f.reason == 'no_hold', 'the card says no_hold', f and f.reason)
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'storm_delay', options = { delay = '60' } })
    flush()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'no_hold', 'a run is refused no_hold', r and r.code)
    eq(r and r.toast, COPY.no_hold, 'in its own line')
    nothingSpent(1, 'no_hold')
    ok(m.storm.tWait == 30000 and m.stormDelayNextMs == nil, 'and the storm is untouched')

    -- BEFORE THE STORM: no record.
    m.storm = nil
    local f2 = listed(1, 'storm_delay')
    ok(f2 and f2.reason == 'no_storm', 'with no storm yet the card says no_storm', f2 and f2.reason)
    local _ = rec
end

describe('Storm delay: a hold that runs out while it loads gives everything back')
do
    reset()
    local last = #BR.Config.Storm.phases
    local m = lobby('squad', last, 30000)
    -- The final phase holds for two more seconds: the run is accepted, and by
    -- the time the 3 to 5 seconds of loading are over the wall is moving.
    m.storm.tStart = gameMs - 27000
    local r = runAt(1, 'storm_delay', { delay = '120' }, true)
    eq(r and r.code, 'running', 'accepted while the final hold lasts')
    eq(keys[1], false, 'the key is spent as it is accepted')
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'no_hold', 'over, it can no longer happen: no_hold', r and r.code)
    nothingSpent(1, 'given back')
    eq(m.storm.tWait, 30000, 'and the storm was never touched')
end

describe('Storm delay: squad and solo lines')
do
    reset()
    local m = lobby('solo', 3)
    local r = runAt(1, 'storm_delay', { delay = '60' })
    eq(r and r.toast, TS.pick(COPY, 'storm_delay_done', false), 'a solo run says the done line')
    local got
    for _, n in ipairs(noticesTo(5)) do got = textOf(n) end
    eq(got, 'p1 has redeemed their special power: ' .. TS.pick(COPY, 'storm_delay_description', false),
        'and the lobby reads the description')
    for _, key in ipairs({ 'storm_delay_done', 'storm_delay_description', 'no_hold' }) do
        ok(not TS.pick(COPY, key, false):lower():find('squad', 1, true),
            ('%s never says squad outside a squad match'):format(key))
    end
    eq(TS.pick(COPY, 'storm_delay_risks', false), COPY.storm_delay_risks_solo, 'the risks line has its solo sibling')
    local _ = m
end

describe('Storm delay: the dev path, nothing spent and no notice')
do
    reset()
    local m = lobby('squad', 3, 90000)
    keys[1] = false
    sv(1, 'run storm_delay delay=120')
    eq(m.storm.tWait, 90000 + 120000, '`brterminal run storm_delay delay=120` delays the hold')
    eq(#notices, 0, 'with no notice')
    eq(#market.charges, 0, 'and no Volts')
    local before = m.storm.tWait
    sv(1, 'run storm_delay delay=30')
    eq(m.storm.tWait, before, 'a choice the row does not list is refused')
    local said = false
    for _, l in ipairs(logs) do if l:find('does not take those options', 1, true) then said = true end end
    ok(said, 'and said so')
end

realPrint(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
