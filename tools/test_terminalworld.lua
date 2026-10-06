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
--   PART B  Storm control: the storm steered to the near, far or center end
--           for 150 Volts, the record on the map untouched, a squad that ran
--           Storm reveal told the new end; refused `no_storm` / `no_circle`
--           with nothing spent (the Volts included); everything given back
--           when the final circle is drawn while it loads; the dev path.
--   PART C  Time & weather: the time through the match clock's own anchor
--           (#394's one writer follows it) and back to the match's running
--           clock when it ends; the weather to the match, and on the REAL
--           client/world.lua claimed only inside the circle, below the
--           storm's THUNDER and over its all-clear; the festive sky's clear
--           and its white ground (#399); ended by its time, the match ending
--           and a season switch.
--   PART D  Power outage: around this terminal (fx.outageRadiusM, the
--           page's 1 km), Los Santos or Blaine County by the storm's city
--           line (#381); on the client, the one writer of the lights turns
--           them off only while the view is inside an area, vehicles left
--           out, and back on outside, at the end, in the lobby, off Season 2
--           and when br_core stops -- on a change only.
--
-- The storm's own half -- BR.Storm.delay against the real phase job, the 75%
-- cut, a client's countdown; BR.Storm.futures and steer over many matches,
-- every later circle the planner's -- is tools/test_storm.lua's `delay.*` and
-- `control.*` blocks.
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
local WAVE_B = { 'storm_delay', 'storm_control', 'time_weather', 'power_outage' }
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

-- =========================================================================
-- PART B -- Storm control
-- =========================================================================

--- Every possible end BR.Storm.futures worked out on its last call, kept by a
--- spy around the real function.
local lastEnds = nil
local seenEnds = {}
do
    local real = BR.Storm.futures
    BR.Storm.futures = function(...)
        local ends, why = real(...)
        lastEnds = ends
        if ends then seenEnds[#seenEnds + 1] = ends end
        return ends, why
    end
end

local function snapshot(rec)
    local out = {}
    for k, v in pairs(rec) do out[k] = v end
    return out
end

local function sameRecord(a, snap)
    for k, v in pairs(snap) do if a[k] ~= v then return false end end
    for k in pairs(a) do if snap[k] == nil then return false end end
    return true
end

for _, zone in ipairs({ 'near', 'far', 'center' }) do
    describe('Storm control: the storm ends at the ' .. zone .. ' circle')
    do
        reset()
        local m = lobby('squad', 3)
        local rec = m.storm
        local snap = snapshot(rec)
        lastEnds = nil
        local r = runAt(1, 'storm_control', { zone = zone })
        ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
        ok(lastEnds ~= nil and #lastEnds == CT.fx.stormControlFutures,
            ('the server worked out fx.stormControlFutures (%d) possible ends'):format(CT.fx.stormControlFutures))
        local three = TS.threeEnds(lastEnds or {}, SITE.x, SITE.y)
        local want = lastEnds and lastEnds[three[zone]]
        local f = BR.Storm.finalCentre(m)
        ok(f and want and f.x == want.x and f.y == want.y,
            'the storm now ends at the ' .. zone .. ' one, measured from this terminal',
            f and want and ('(%.1f, %.1f) vs (%.1f, %.1f)'):format(f.x, f.y, want.x, want.y))
        ok(m.storm == rec and sameRecord(rec, snap), 'the record on the map did not move')
        eq(#eventsOf(BR.Net.STORM_SYNC), 0, 'and nothing about it was published')
        eq(market.wallet[1], 1000 - 150, '150 Volts were spent')
        ok(r and r.toast and r.toast:find(COPY.storm_control_done, 1, true) == 1,
            'the done line, then the new balance', r and r.toast)
        ok(r and r.toast and r.toast:find('850 Volts', 1, true) ~= nil, 'which is 850 Volts', r and r.toast)
        eq(keys[1], false, 'the key is spent')
        ok(errored() == nil, 'clean', errored())
    end
end

describe('Storm control: the three are three different ends')
do
    -- Near 0 m, far 1000 m: halfway is 500 m, and of the rest (100, 71 and
    -- 600 m) the end at 600 m is nearest it.
    local ends = { { x = 0.0, y = 0.0 }, { x = 100.0, y = 0.0 }, { x = 1000.0, y = 0.0 },
                   { x = 50.0, y = 50.0 }, { x = 0.0, y = -600.0 } }
    local three = TS.threeEnds(ends, 0.0, 0.0)
    eq(three.near, 1, 'near: the end at the terminal')
    eq(three.far, 3, 'far: the end farthest from it')
    eq(three.center, 5, 'center: of the rest, the one nearest halfway between them, 500 m out')
    -- Every end the same distance away: near, far and center still three.
    local tie = TS.threeEnds({ { x = 10.0, y = 0.0 }, { x = -10.0, y = 0.0 }, { x = 0.0, y = 10.0 } },
        0.0, 0.0)
    ok(tie.near == 1 and tie.far == 2 and tie.center == 3, 'a tie goes to the earlier end, and all three differ')
    local two = TS.threeEnds({ { x = 1.0, y = 0.0 }, { x = 5.0, y = 0.0 } }, 0.0, 0.0)
    ok(two.near == 1 and two.far == 2 and two.center == 1, 'with only two ends the choices share them')
    local none = TS.threeEnds({}, 0.0, 0.0)
    ok(none.near == nil and none.far == nil and none.center == nil, 'and with none there is nothing to name')
end

describe('Storm control: every zone label is true of the circle it picks')
do
    -- ═══ A LABEL IS A CLAIM, AND THIS IS WHERE IT IS CHECKED ═══
    --
    -- Each zone choice's label says something about the circle it picks. Every
    -- label the page can show is written down here with the claim it makes, and
    -- the claim is checked against BR.TerminalSolve.threeEnds over thousands of
    -- random sets of ends, terminals and next circles, and over the real ends
    -- every run above worked out. A label with no claim here fails: rewording a
    -- choice means saying here what the new words promise.
    --
    -- THE FAILURE THIS CATCHES (the wave B review): center was picked from the
    -- ends near and far left, by distance to the next circle's center, under
    -- "Closest to the next circle's center" -- and about one draw in nine the
    -- end nearest that point had already gone to near or far.
    local function dist(e, x, y) return math.sqrt((e.x - x) ^ 2 + (e.y - y) ^ 2) end
    local CLAIMS = {
        ['Closest to this terminal'] = function(c)
            for _, e in ipairs(c.ends) do
                if dist(e, c.ax, c.ay) < dist(c.ends[c.pick], c.ax, c.ay) then return false end
            end
            return true
        end,
        ['Farthest from this terminal'] = function(c)
            for _, e in ipairs(c.ends) do
                if dist(e, c.ax, c.ay) > dist(c.ends[c.pick], c.ax, c.ay) then return false end
            end
            return true
        end,
        -- Of the three offered, the one between the other two.
        ['Middle distance from this terminal'] = function(c)
            local others = {}
            for zone, i in pairs(c.three) do
                if zone ~= c.zone then others[#others + 1] = i end
            end
            if others[1] == c.pick or others[2] == c.pick then return false end
            local d = dist(c.ends[c.pick], c.ax, c.ay)
            local d1, d2 = dist(c.ends[others[1]], c.ax, c.ay), dist(c.ends[others[2]], c.ax, c.ay)
            return math.min(d1, d2) <= d and d <= math.max(d1, d2)
        end,
    }
    local zones
    for _, o in ipairs(BR.Terminal.row('storm_control').options) do
        if o.id == 'zone' then zones = o.choices end
    end
    ok(zones ~= nil and #zones == 3, 'the row offers three zones')

    -- The draws: a seeded stream, so a failure replays.
    local rng = BR.Rng(396)
    local function coord() return (rng:float() - 0.5) * 8000.0 end
    local sets = {}
    for _ = 1, 3000 do
        local n = 3 + math.floor(rng:float() * 10)
        local ends = {}
        for k = 1, n do ends[k] = { x = coord(), y = coord() } end
        sets[#sets + 1] = { ends = ends, ax = coord(), ay = coord(), cx = coord(), cy = coord() }
    end
    for _, ends in ipairs(seenEnds) do
        sets[#sets + 1] = { ends = ends, ax = SITE.x, ay = SITE.y, cx = C0.x, cy = C0.y }
    end
    ok(#seenEnds >= 3, 'the real ends the runs above worked out are among them', #seenEnds)

    for _, zone in ipairs(zones or {}) do
        local line = COPY['storm_control_opt_zone_' .. zone]
        local claim = CLAIMS[line]
        ok(claim ~= nil, ('the %s label is a claim this test checks'):format(zone), line)
        if claim then
            local wrong, first = 0, nil
            for k, set in ipairs(sets) do
                -- The next circle's center rides along: a rule that measured
                -- from it would be held to the same claims.
                local three = TS.threeEnds(set.ends, set.ax, set.ay, set.cx, set.cy)
                local c = { ends = set.ends, three = three, zone = zone, pick = three[zone],
                            ax = set.ax, ay = set.ay, cx = set.cx, cy = set.cy }
                if not (three.near ~= three.far and three.far ~= three.center
                        and three.near ~= three.center and claim(c)) then
                    wrong = wrong + 1
                    first = first or k
                end
            end
            ok(wrong == 0, ('"%s" is true of the %s circle in all %d draws'):format(line, zone, #sets),
                first and ('wrong in %d, the first at draw %d'):format(wrong, first))
        end
    end
end

describe("Storm control: near is nearer the terminal than the storm's own plan, far farther")
do
    reset()
    local m = lobby('squad', 2)
    local own = BR.Storm.finalCentre(m)
    runAt(1, 'storm_control', { zone = 'near' })
    local near = BR.Storm.finalCentre(m)
    local d = function(p) return math.sqrt((p.x - SITE.x) ^ 2 + (p.y - SITE.y) ^ 2) end
    ok(d(near) <= d(own), 'near ends no farther from this terminal than the storm would have',
        ('%.0f vs %.0f m'):format(d(near), d(own)))
    reset()
    m = lobby('squad', 2)
    own = BR.Storm.finalCentre(m)
    runAt(1, 'storm_control', { zone = 'far' })
    local far = BR.Storm.finalCentre(m)
    ok(d(far) >= d(own), 'far ends no nearer than it would have', ('%.0f vs %.0f m'):format(d(far), d(own)))
end

describe('Storm control: a squad that ran Storm reveal is told the new end')
do
    reset()
    local m = lobby('squad', 3)
    -- Squad B revealed the end earlier this match.
    T.reveal(m, 'squad:B', BR.Storm.finalCentre(m))
    sent = {}
    runAt(1, 'storm_control', { zone = 'far' })
    local f = BR.Storm.finalCentre(m)
    for _, src in ipairs({ 3, 4 }) do
        local p = lastOf(BR.Net.TERMINAL_REVEAL, src)
        ok(p and p.x == f.x and p.y == f.y and p.matchId == m.id,
            ('p%d, of the squad that revealed it, is sent where the storm ends now'):format(src))
    end
    eq(lastOf(BR.Net.TERMINAL_REVEAL, 1), nil, 'and nobody who did not reveal it')
    ok(m.terminals.reveals['squad:B'].x == f.x, 'the reveal a reconnect is re-sent is the new one too')
end

describe('Storm control: no storm, no circle left -- refused, nothing spent')
do
    reset()
    local m = lobby('squad', #BR.Config.Storm.phases)
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local f = listed(1, 'storm_control')
    ok(f and f.available == false and f.reason == 'no_circle', 'the final circle on the map: the card says no_circle',
        f and f.reason)
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'storm_control', options = { zone = 'far' } })
    flush()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.code == 'no_circle', 'a run is refused no_circle', r and r.code)
    eq(r and r.toast, COPY.no_circle, 'in its own line')
    nothingSpent(1, 'no_circle')
    eq(#market.charges, 0, 'the market was never asked for the 150')
    m.storm = nil
    local f2 = listed(1, 'storm_control')
    ok(f2 and f2.reason == 'no_storm', 'with no storm yet the card says no_storm', f2 and f2.reason)
end

describe('Storm control: the final circle drawn while it loads gives everything back')
do
    reset()
    local m = lobby('squad', 7)
    local r = runAt(1, 'storm_control', { zone = 'near' }, true)
    eq(r and r.code, 'running', 'accepted at phase 7')
    eq(market.wallet[1], 850, 'the 150 are spent as it is accepted')
    -- The phase job draws the final circle in those seconds.
    m.storm = BR.BuildStormRecord(#BR.Config.Storm.phases, C0.x, C0.y, 40.0, C0.x, C0.y, 0.0,
        gameMs, 30000, 60000, 6.7, SEED)
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'no_circle', 'over, it can no longer happen: no_circle', r and r.code)
    nothingSpent(1, 'given back')
    eq(market.wallet[1], 1000, 'the 150 are back')
end

describe('Storm control: squad and solo lines')
do
    for _, key in ipairs({ 'storm_control_done', 'storm_control_description', 'no_circle',
                           'storm_control_opt_zone_near', 'storm_control_opt_zone_center',
                           'storm_control_opt_zone_far', 'storm_control_what' }) do
        ok(not TS.pick(COPY, key, false):lower():find('squad', 1, true),
            ('%s never says squad outside a squad match'):format(key))
    end
    eq(TS.pick(COPY, 'storm_control_risks', false), COPY.storm_control_risks_solo,
        'the risks line has its solo sibling')
    eq(COPY.storm_control_opt_zone_center, 'Middle distance from this terminal',
        'center is measured from this terminal, as near and far are')
    reset()
    lobby('solo', 3)
    local r = runAt(1, 'storm_control', { zone = 'center' })
    ok(r and r.toast and not r.toast:lower():find('squad', 1, true), "a solo run's toast says no squad",
        r and r.toast)
end

describe('Storm control: the dev path steers for nothing')
do
    reset()
    local m = lobby('squad', 3)
    keys[1] = false
    lastEnds = nil
    sv(1, 'run storm_control zone=far')
    ok(lastEnds ~= nil, '`brterminal run storm_control zone=far` works the ends out')
    local after = BR.Storm.finalCentre(m)
    local three = TS.threeEnds(lastEnds or {}, roster[1].pos.x, roster[1].pos.y)
    ok(lastEnds and after.x == lastEnds[three.far].x and after.y == lastEnds[three.far].y,
        'and steers to the far one, measured from the player (the dev terminal has no site)')
    eq(#market.charges, 0, 'no Volts')
    eq(#notices, 0, 'no notice')
end

-- =========================================================================
-- PART C -- Time & weather, the server
-- =========================================================================

--- A match clock anchor as server/match.lua stamps it at bus start.
local function stampClock(m, at)
    m.clock = BR.World.anchor(at or (gameMs - 600000))
    return m.clock
end

local function skySends(src)
    return eventsOf(BR.Net.TERMINAL_SKY, src)
end

describe('Time & weather: the time through the match clock, the weather to the match')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    local r = runAt(1, 'time_weather', { time = 'night', weather = 'rain', duration = '180' })
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    eq(r and r.toast, COPY.time_weather_done, 'and says the page\'s done line')
    local a = m.clock
    ok(a ~= base and BR.World.validAnchor(a), 'the match runs from a new clock anchor')
    local h, mi = table.unpack(CT.fx.skyTime.night)
    eq(a.startSec, h * 3600 + mi * 60, 'starting at the night the config names')
    eq(a.msPerMin, base.msPerMin, 'at the match\'s own rate (#394)')
    eq(a.at, gameMs, 'from the moment it ran')
    ok(m.terminalSky and m.terminalSky.base == base, 'and the match\'s own anchor is kept')
    eq(m.terminalSky.untilAt, gameMs + 180000, 'for three minutes')
    for src = 1, 5 do
        local p = skySends(src)[1]
        ok(p and p.payload.weather == CT.fx.skyWeather.rain and p.payload.matchId == m.id,
            ('p%d is told the weather (%s)'):format(src, CT.fx.skyWeather.rain))
    end
    -- THE ONE CLOCK WRITER'S PLAN FOLLOWS THE ANCHOR: one new key, one write.
    local W = BR.World
    local plan = W.clockPlan({ state = BR.PlayerState.ALIVE, anchor = m.clock, now = gameMs + 60000, synced = true })
    eq(plan.mode, 'run', 'a client\'s clock plan runs')
    ok(math.abs(plan.sec - (a.startSec + 60000 * 60 / a.msPerMin)) < 1e-6,
        'from the chosen time, a minute on', plan.sec)
    local was = W.clockPlan({ state = BR.PlayerState.ALIVE, anchor = base, now = gameMs, synced = true })
    ok(plan.key ~= was.key, 'and its key is new, so the writer writes once')
    ok(errored() == nil, 'clean', errored())
end

describe('Time & weather: it ends, and the match\'s own running clock comes back')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    runAt(1, 'time_weather', { time = 'dusk', weather = 'fog', duration = '300' })
    eq(skySends(3)[1].payload.weather, 'FOGGY', 'fog is FOGGY')
    gameMs = gameMs + 299000
    BR.Sched.step(gameMs)
    ok(m.terminalSky ~= nil, 'a second before its five minutes it still holds')
    gameMs = gameMs + 2000
    BR.Sched.step(gameMs)
    eq(m.terminalSky, nil, 'at five minutes it is over')
    ok(m.clock == base, 'the match\'s own anchor is back -- the same one')
    local W = BR.World
    local plan = W.clockPlan({ state = BR.PlayerState.ALIVE, anchor = m.clock, now = gameMs, synced = true })
    ok(math.abs(plan.sec - W.timeAt(base, gameMs)) < 1e-6,
        'so the clock is where the match\'s own time has run to meanwhile, not where it was')
    for src = 1, 5 do
        local p = skySends(src)
        ok(#p == 2 and p[2].payload.weather == nil, ('p%d is told the weather is over'):format(src))
    end
end

describe('Time & weather: clear is the base sky; no thunder')
do
    eq(CT.fx.skyWeather.clear, 'base', 'clear is the match\'s own clear sky, the `base` role')
    ok(BR.World.SKY_ROLE.base ~= nil, 'which is a role the sky knows')
    for choice, w in pairs(CT.fx.skyWeather) do
        ok(w ~= 'THUNDER', ('%s is not a thunderstorm (owner, 2026-10-05)'):format(choice))
        ok(BR.World.WEATHER[w] or BR.World.SKY_ROLE[w], ('%s names a weather or a role (%s)'):format(choice, w))
    end
    local row = T.row('time_weather')
    for _, o in ipairs(row.options) do
        for _, ch in ipairs(o.choices) do
            if o.id == 'time' then ok(CT.fx.skyTime[ch] ~= nil, 'time ' .. ch .. ' has its hour') end
            if o.id == 'weather' then ok(CT.fx.skyWeather[ch] ~= nil, 'weather ' .. ch .. ' has its sky') end
        end
    end
end

describe('Time & weather: the match ending ends it')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    runAt(1, 'time_weather', { time = 'night', weather = 'rain', duration = '300' })
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    eq(m.terminalSky, nil, 'the end screen is not the match: it is over')
    ok(m.clock == base, 'with the match\'s own clock back for the end screen')
    eq(skySends(2)[#skySends(2)].payload.weather, nil, 'and the weather released')
end

describe('Time & weather: a season switch ends it')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    runAt(1, 'time_weather', { time = 'night', weather = 'rain', duration = '300' })
    season(1)
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    season(2)
    eq(m.terminalSky, nil, 'off Season 2 it is over')
    ok(m.clock == base, 'and the clock is the match\'s own')
end

describe('Time & weather: a second run replaces the first, and the match\'s own clock still comes back')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    runAt(1, 'time_weather', { time = 'night', weather = 'rain', duration = '300' })
    -- Squad B's key, the other terminal's reach: run from the same terminal.
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    keys[3] = true
    runAt(3, 'time_weather', { time = 'day', weather = 'fog', duration = '180' })
    local h = CT.fx.skyTime.day[1]
    eq(m.clock.startSec, h * 3600 + CT.fx.skyTime.day[2] * 60, 'the second run\'s time')
    eq(m.terminalSky.weather, 'FOGGY', 'and weather')
    ok(m.terminalSky.base == base, 'with the match\'s own anchor still the one kept')
    gameMs = gameMs + 181000
    BR.Sched.step(gameMs)
    ok(m.clock == base, 'which is what comes back')
end

describe('Time & weather: a client that restarts is told again')
do
    reset()
    local m = lobby('squad', 3)
    stampClock(m)
    runAt(1, 'time_weather', { time = 'night', weather = 'rain', duration = '300' })
    sent = {}
    fire(BR.Net.READY, 4)
    local p = skySends(4)[1]
    ok(p and p.payload.weather == 'RAIN', 'br:ready re-sends the weather while it lasts')
    gameMs = gameMs + 301000
    BR.Sched.step(gameMs)
    sent = {}
    fire(BR.Net.READY, 4)
    eq(#skySends(4), 0, 'and nothing once it is over')
end

describe('Time & weather: refused with no clock, and given back when the match ends while it loads')
do
    reset()
    local m = lobby('squad', 3)
    m.clock = nil
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local f = listed(1, 'time_weather')
    ok(f and f.reason == 'unavailable', 'a match with no clock to run from: unavailable', f and f.reason)
    nothingSpent(1, 'no clock')
    stampClock(m)
    local r = runAt(1, 'time_weather', { time = 'night', weather = 'rain', duration = '180' }, true)
    eq(r and r.code, 'running', 'accepted')
    m.state = BR.MatchState.ENDED
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false, 'over, the match ended: it can no longer happen', r and r.code)
    nothingSpent(1, 'given back')
    eq(m.terminalSky, nil, 'and nothing of it was set')
end

describe('Time & weather: squad and solo lines, and the dev path')
do
    eq(TS.pick(COPY, 'time_weather_risks', false), COPY.time_weather_risks_solo, 'the risks line has its solo sibling')
    for _, key in ipairs({ 'time_weather_done', 'time_weather_description', 'time_weather_what' }) do
        ok(not TS.pick(COPY, key, false):lower():find('squad', 1, true),
            ('%s never says squad outside a squad match'):format(key))
    end
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    keys[1] = false
    sv(1, 'run time_weather time=dusk weather=clear duration=180')
    ok(m.terminalSky and m.terminalSky.weather == 'base' and m.clock ~= base,
        '`brterminal run time_weather time=dusk weather=clear duration=180` sets it')
    eq(#market.charges + #notices, 0, 'for nothing, and with no notice')
end

-- =========================================================================
-- PART C, THE CLIENT -- the sky claim, over the REAL client/world.lua
-- =========================================================================

local SANDBOX_STD = {
    assert = assert, error = error, ipairs = ipairs, next = next,
    pairs = pairs, pcall = pcall, rawequal = rawequal, rawget = rawget,
    rawlen = rawlen, rawset = rawset, select = select, xpcall = xpcall,
    setmetatable = setmetatable, getmetatable = getmetatable,
    tonumber = tonumber, tostring = tostring, type = type,
    math = math, string = string, table = table,
}

--- A client: its own Lua state, the real br_lib shared files and the files
--- named, over modeled natives. `C.natives` records every native call.
local function newClient(files)
    local env = setmetatable({}, { __index = function(_, k) return SANDBOX_STD[k] end })
    env._G = env
    local C = { env = env, natives = {}, handlers = {}, jobs = {}, prints = {}, inside = false,
                at = { x = 0.0, y = 0.0, z = 30.0 } }
    local function native(name)
        env[name] = function(...)
            C.natives[#C.natives + 1] = { name = name, args = { ... } }
        end
    end
    for _, n in ipairs({ 'SetWeatherTypeOvertimePersist', 'SetWeatherTypeNowPersist',
                         'ClearWeatherTypePersist', 'SetRainLevel', 'SetForceVehicleTrails',
                         'SetForcePedFootstepsTracks', 'RequestNamedPtfxAsset', 'RemoveNamedPtfxAsset',
                         'SetArtificialLightsState', 'SetArtificialLightsStateAffectsVehicles' }) do
        native(n)
    end
    env.Citizen = { InvokeNative = function(h, ...)
        C.natives[#C.natives + 1] = { name = ('0x%X'):format(h), args = { ... } }
    end }
    env.print = function(...)
        local parts = {}
        for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
        C.prints[#C.prints + 1] = table.concat(parts, ' ')
    end
    env.GetGameTimer = function() return gameMs end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetConvar = function(n, d) return n == 'br_season' and convars.br_season or d end
    env.RegisterNetEvent = function() end
    env.TriggerEvent = function() end
    env.AddEventHandler = function(name, fn)
        C.handlers[name] = C.handlers[name] or {}
        table.insert(C.handlers[name], fn)
    end
    for _, f in ipairs({ 'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
                         'br_lib/shared/world.lua', 'br_lib/config/match.lua',
                         'br_lib/config/storm.lua', 'br_lib/shared/season.lua',
                         'br_lib/config/seasons.lua', 'br_lib/config/terminals.lua',
                         'br_lib/shared/geo.lua', 'br_lib/shared/terminal_solve.lua' }) do
        local chunk = assert(loadfile(ROOT .. f, 't', env))
        chunk()
    end
    env.BR.Season.boot(function(name) return name == 'br_season' and convars.br_season or '' end,
        function() end)
    env.BR.Loop = {
        SLOW = 'slow', TICK = 'tick', FRAME = 'frame',
        register = function(_, name, fn) C.jobs[name] = fn end,
    }
    env.BR.State = { match = { state = env.BR.MatchState.PLAYING }, me = { state = env.BR.PlayerState.ALIVE } }
    env.BR.Storm = {
        viewInside = function() return C.inside end,
        viewpoint = function() return C.at end,
    }
    for _, f in ipairs(files) do
        local chunk = assert(loadfile(ROOT .. f, 't', env))
        chunk()
    end
    function C.fire(name, ...)
        for _, fn in ipairs(C.handlers[name] or {}) do fn(...) end
    end
    function C.slow()
        for _, fn in pairs(C.jobs) do fn() end
    end
    --- The last weather written, and the ground pass's last state.
    function C.wrote()
        local w, ground = nil, nil
        for _, n in ipairs(C.natives) do
            if n.name == 'SetWeatherTypeOvertimePersist' or n.name == 'SetWeatherTypeNowPersist' then
                w = n.args[1]
            elseif n.name == 'ClearWeatherTypePersist' then
                w = nil
            elseif n.name == '0x6E9EF3A33C8899F8' then
                ground = n.args[1]
            end
        end
        return w, ground
    end
    function C.count(name)
        local k = 0
        for _, n in ipairs(C.natives) do if n.name == name then k = k + 1 end end
        return k
    end
    return C
end

local SKY_FILES = { 'br_core/client/world.lua', 'br_core/client/terminalfx/time_weather.lua' }

describe('Time & weather on a client: the weather only inside the circle')
do
    local C = newClient(SKY_FILES)
    local W = C.env.BR.World
    -- The match's sky: the island's base, as a match stands under.
    C.fire('br:world:island', 'base', 10.0)
    eq((W.sky()), 'EXTRASUNNY', 'a match stands under the base sky')

    C.inside = true
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1, weather = 'RAIN' })
    local name, src = W.sky()
    eq(name, 'RAIN', 'told RAIN with its view inside the circle: RAIN')
    eq(src, 'terminal', 'as the terminal\'s claim')
    eq((C.wrote()), 'RAIN', 'written through client/world.lua')
    ok(C.count('SetRainLevel') >= 1, 'with the rain knob handed back, so it really rains')

    -- OUTSIDE THE CIRCLE, NOT CAUGHT (phase 1's free-loot hold): no claim.
    C.inside = false
    C.slow()
    eq(C.env.BR.TerminalFx.skyClaim(), nil, 'its view outside the circle: no claim')
    eq((W.sky()), 'EXTRASUNNY', 'and the sky is the storm\'s own -- here the base')

    -- CAUGHT: THUNDER, whatever was chosen.
    C.inside = false
    W.want('storm', 'THUNDER', 5.0)
    eq((W.sky()), 'THUNDER', 'caught outside, the storm\'s THUNDER')
    C.inside = true
    C.slow()
    eq((W.sky()), 'THUNDER', 'and THUNDER outranks the terminal even while it claims')

    -- BACK INSIDE: the storm's all-clear is a role, and yields to the choice.
    W.want('storm', 'base', 5.0)
    eq((W.sky()), 'RAIN', 'back inside, the storm\'s all-clear yields to the chosen RAIN')
    W.want('override', 'SMOG', 0.0)
    eq((W.sky()), 'SMOG', 'and a console sky still outranks everything')
    W.want('override', nil)

    -- THE END: the server's word.
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1 })
    eq(C.env.BR.TerminalFx.skyClaim(), nil, 'told it is over: released')
    eq((W.sky()), 'EXTRASUNNY', 'and the match\'s own sky is back')
end

describe('Time & weather on a client: the festive months, and the white ground')
do
    local C = newClient(SKY_FILES)
    local W = C.env.BR.World
    W.setFestive(true)
    C.fire('br:world:island', 'base', 10.0)
    eq((W.sky()), 'XMAS', 'a festive match stands under XMAS')
    local _, ground = C.wrote()
    eq(ground, true, 'with snow on the ground')
    C.inside = true
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1, weather = 'base' })
    eq((W.sky()), 'XMAS', 'clear, in December or January, is the base sky: XMAS')
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1, weather = 'RAIN' })
    eq((W.sky()), 'RAIN', 'rain is RAIN')
    _, ground = C.wrote()
    eq(ground, false, 'and the ground is bare under it: the ground follows the resolved weather (#399)')
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1 })
    _, ground = C.wrote()
    eq(ground, true, 'over, XMAS and the white ground come back')
end

describe('Time & weather on a client: the lobby and a season switch end it')
do
    local C = newClient(SKY_FILES)
    local W = C.env.BR.World
    C.inside = true
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1, weather = 'FOGGY' })
    eq((W.sky()), 'FOGGY', 'fog inside the circle')
    C.env.BR.State.me.state = C.env.BR.PlayerState.LOBBY
    C.slow()
    eq(C.env.BR.TerminalFx.skyClaim(), nil, 'home in the lobby: released, before the server says so')
    C.env.BR.State.me.state = C.env.BR.PlayerState.ALIVE
    C.slow()
    eq(C.env.BR.TerminalFx.skyClaim(), nil, 'and not taken up again from a match that is over')

    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 2, weather = 'FOGGY' })
    eq(C.env.BR.TerminalFx.skyClaim(), 'FOGGY', 'a new run claims again')
    convars.br_season = '1'
    C.env.BR.Season.boot(function(name) return name == 'br_season' and '1' or '' end, function() end)
    C.slow()
    eq(C.env.BR.TerminalFx.skyClaim(), nil, 'off Season 2: released')
    convars.br_season = '2'
    C.env.BR.Season.boot(function(name) return name == 'br_season' and '2' or '' end, function() end)
    C.slow()
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 2, weather = 'nonsense' })
    eq(C.env.BR.TerminalFx.skyClaim(), nil, 'a name that is neither a weather nor a role is no claim')
end

describe('Time & weather on a client: nothing to do costs nothing')
do
    local C = newClient(SKY_FILES)
    local n = #C.natives
    for _ = 1, 60 do C.slow() end
    eq(#C.natives, n, 'a minute of passes with no weather to claim calls no native')
end

-- =========================================================================
-- PART D -- Power outage, the server
-- =========================================================================

local function powerSends(src)
    return eventsOf(BR.Net.TERMINAL_POWER, src)
end

describe('Power outage: around this terminal, to the whole match')
do
    reset()
    local m = lobby('squad', 3)
    local r = runAt(1, 'power_outage', { area = 'here', duration = '120' })
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    eq(r and r.toast, COPY.power_outage_done, 'and says the page\'s done line')
    local list = T.outagesOf(m)
    eq(#list, 1, 'one outage is live')
    local a = list[1] and list[1].area
    ok(a and a.kind == 'radius' and a.x == SITE.x and a.y == SITE.y and a.r == CT.fx.outageRadiusM,
        ('a %.0f m radius around this terminal'):format(CT.fx.outageRadiusM))
    eq(list[1].untilAt, gameMs + 120000, 'for two minutes')
    for src = 1, 5 do
        local p = powerSends(src)[1]
        ok(p and #p.payload.list == 1 and p.payload.list[1].kind == 'radius' and p.payload.matchId == m.id,
            ('p%d is sent the area'):format(src))
    end
    ok(errored() == nil, 'clean', errored())
end

describe('Power outage: Los Santos and Blaine County are the storm\'s city line')
do
    eq(BR.StormCityLine(), BR.Config.Storm.anchorRegion.cityMaxY, 'the line is the anchor\'s own (#381)')
    for _, choice in ipairs({ 'city', 'county' }) do
        reset()
        local m = lobby('squad', 3)
        runAt(1, 'power_outage', { area = choice, duration = '240' })
        local a = T.outagesOf(m)[1].area
        ok(a.kind == choice and a.line == BR.StormCityLine(), choice .. ': by the city line')
        eq(T.outagesOf(m)[1].untilAt, gameMs + 240000, 'for four minutes')
    end
    local line = BR.StormCityLine()
    local city = TS.outageArea('city', nil, nil, 1000.0)
    local county = TS.outageArea('county', nil, nil, 1000.0)
    ok(TS.inOutage(city, 0.0, line - 1.0) and not TS.inOutage(city, 0.0, line),
        'a point below the line is the city, one on it is not')
    ok(TS.inOutage(county, 0.0, line) and not TS.inOutage(county, 0.0, line - 1.0),
        'and one on it or above it is the county, as the anchor\'s draw has it')
    local here = TS.outageArea('here', 100.0, 200.0, 1000.0)
    ok(TS.inOutage(here, 1100.0, 200.0) and not TS.inOutage(here, 1100.5, 200.0),
        'here: within the radius, and not a half meter past it')
    ok(TS.outageArea('here', nil, 200.0, 1000.0) == nil and TS.outageArea('moon', 1, 2, 3) == nil,
        'no area with no point to center on, or for a choice that is not one')
    ok(not TS.inOutage({ kind = 'radius', x = 'a' }, 0, 0) and not TS.inOutage(nil, 0, 0),
        'and a malformed area holds nobody')
end

describe('Power outage: the page\'s 1 km is the config\'s radius')
do
    local km = tonumber(COPY.power_outage_opt_area_here_desc:match('within ([%d%.]+) km'))
    ok(km ~= nil and km * 1000 == CT.fx.outageRadiusM, 'the page says the radius the server uses',
        COPY.power_outage_opt_area_here_desc)
    ok(COPY.power_outage_what:find('for every player inside the area', 1, true) ~= nil
        and COPY.power_outage_what:find('Players outside the area keep their lights.', 1, true) ~= nil,
        'and says who goes dark: the players inside the area, not the district for everyone')
end

describe('Power outage: it ends, one at a time, and with the match and the season')
do
    reset()
    local m = lobby('squad', 3)
    runAt(1, 'power_outage', { area = 'here', duration = '120' })
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    keys[3] = true
    runAt(3, 'power_outage', { area = 'county', duration = '240' })
    eq(#T.outagesOf(m), 2, 'two outages at once')
    eq(#powerSends(2)[#powerSends(2)].payload.list, 2, 'and the match is sent both')
    gameMs = gameMs + 120000
    BR.Sched.step(gameMs)
    eq(#T.outagesOf(m), 1, 'the first ends at its two minutes')
    local last = powerSends(4)[#powerSends(4)].payload.list
    ok(#last == 1 and last[1].kind == 'county', 'and the match is sent the one left')
    gameMs = gameMs + 120000
    BR.Sched.step(gameMs)
    eq(m.terminalPower, nil, 'the second at its four')
    eq(#powerSends(4)[#powerSends(4)].payload.list, 0, 'and an empty list puts the lights back')
    local n = #powerSends(4)
    gameMs = gameMs + 5000
    BR.Sched.step(gameMs)
    eq(#powerSends(4), n, 'then nothing more is sent')

    reset()
    m = lobby('squad', 3)
    runAt(1, 'power_outage', { area = 'city', duration = '240' })
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    eq(m.terminalPower, nil, 'the match ending ends it')
    eq(#powerSends(2)[#powerSends(2)].payload.list, 0, 'with the lights back for everyone')

    reset()
    m = lobby('squad', 3)
    runAt(1, 'power_outage', { area = 'city', duration = '240' })
    season(1)
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    season(2)
    eq(m.terminalPower, nil, 'and a season switch')
end

describe('Power outage: a client that restarts is sent the live areas')
do
    reset()
    lobby('squad', 3)
    runAt(1, 'power_outage', { area = 'here', duration = '120' })
    sent = {}
    fire(BR.Net.READY, 4)
    local p = powerSends(4)[1]
    ok(p and #p.payload.list == 1, 'br:ready re-sends them while they last')
end

describe('Power outage: the match ending while it loads gives everything back; the dev path')
do
    reset()
    local m = lobby('squad', 3)
    local r = runAt(1, 'power_outage', { area = 'here', duration = '120' }, true)
    eq(r and r.code, 'running', 'accepted')
    m.state = BR.MatchState.ENDED
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false, 'over, the match ended: it can no longer happen', r and r.code)
    nothingSpent(1, 'given back')
    eq(m.terminalPower, nil, 'and no outage was started')

    reset()
    m = lobby('squad', 3)
    keys[1] = false
    sv(1, 'run power_outage area=county duration=240')
    local a = T.outagesOf(m)[1]
    ok(a and a.area.kind == 'county', '`brterminal run power_outage area=county duration=240` starts it')
    eq(#market.charges + #notices, 0, 'for nothing, and with no notice')
    eq(TS.pick(COPY, 'power_outage_risks', false), COPY.power_outage_risks_solo,
        'the risks line has its solo sibling')
    for _, key in ipairs({ 'power_outage_done', 'power_outage_description', 'power_outage_what' }) do
        ok(not TS.pick(COPY, key, false):lower():find('squad', 1, true),
            ('%s never says squad outside a squad match'):format(key))
    end
end

-- =========================================================================
-- PART D, THE CLIENT -- the one writer of the lights
-- =========================================================================

local POWER_FILES = { 'br_core/client/terminalfx/power_outage.lua' }

--- The lights writes since `from`: { { state, vehicles } } pairs, as written.
local function lightWrites(C, from)
    local out = {}
    for i = (from or 0) + 1, #C.natives do
        local n = C.natives[i]
        if n.name == 'SetArtificialLightsState' then
            out[#out + 1] = { state = n.args[1] }
        elseif n.name == 'SetArtificialLightsStateAffectsVehicles' then
            if out[#out] then out[#out].vehicles = n.args[1] end
        end
    end
    return out
end

describe('Power outage on a client: dark inside the area, lit outside, written on a change only')
do
    local C = newClient(POWER_FILES)
    local Net = C.env.BR.Net
    C.at = { x = 100.0, y = 100.0, z = 30.0 }
    C.fire(Net.TERMINAL_POWER, { matchId = 1, list = { { kind = 'radius', x = 0.0, y = 0.0, r = 1000.0 } } })
    local w = lightWrites(C)
    ok(#w == 1 and w[1].state == true and w[1].vehicles == false,
        'inside the radius: the lights off, vehicles left out of it (headlights work)')
    eq(C.env.BR.TerminalFx.dark(), true, 'and this client is in the dark')
    local n = #C.natives
    for _ = 1, 10 do C.slow() end
    eq(#lightWrites(C, n), 0, 'ten seconds still inside: nothing written again')

    C.at = { x = 1500.0, y = 0.0, z = 30.0 }
    C.slow()
    w = lightWrites(C, n)
    ok(#w == 1 and w[1].state == false and w[1].vehicles == true, 'outside it: the lights back, as they were')

    -- THE CITY AND THE COUNTY, by the line.
    C.at = { x = 0.0, y = 2000.0, z = 30.0 }
    C.fire(Net.TERMINAL_POWER, { matchId = 1, list = { { kind = 'city', line = 1050.0 } } })
    eq(C.env.BR.TerminalFx.dark(), false, 'up in the county, a city outage leaves the lights on')
    C.fire(Net.TERMINAL_POWER, { matchId = 1, list = { { kind = 'county', line = 1050.0 } } })
    eq(C.env.BR.TerminalFx.dark(), true, 'and a county outage turns them off')

    -- THE END: an empty list.
    C.fire(Net.TERMINAL_POWER, { matchId = 1, list = {} })
    eq(C.env.BR.TerminalFx.dark(), false, 'the server\'s empty list: the lights back')
end

describe('Power outage on a client: the lobby, a season switch and a stop put the lights back')
do
    local C = newClient(POWER_FILES)
    local Net = C.env.BR.Net
    C.at = { x = 0.0, y = 0.0, z = 30.0 }
    local area = { kind = 'radius', x = 0.0, y = 0.0, r = 500.0 }
    C.fire(Net.TERMINAL_POWER, { matchId = 1, list = { area } })
    eq(C.env.BR.TerminalFx.dark(), true, 'dark')
    C.env.BR.State.me.state = C.env.BR.PlayerState.LOBBY
    C.slow()
    eq(C.env.BR.TerminalFx.dark(), false, 'home in the lobby: lit, before the server says so')
    C.env.BR.State.me.state = C.env.BR.PlayerState.ALIVE
    C.slow()
    eq(C.env.BR.TerminalFx.dark(), false, 'and not dark again from a match that is over')

    C.fire(Net.TERMINAL_POWER, { matchId = 2, list = { area } })
    eq(C.env.BR.TerminalFx.dark(), true, 'a new outage')
    C.env.BR.Season.boot(function(name) return name == 'br_season' and '1' or '' end, function() end)
    C.slow()
    eq(C.env.BR.TerminalFx.dark(), false, 'off Season 2: lit')
    C.env.BR.Season.boot(function(name) return name == 'br_season' and '2' or '' end, function() end)
    C.slow()
    eq(C.env.BR.TerminalFx.dark(), true, 'back on Season 2 with the outage still live: dark again')
    C.env.GetCurrentResourceName = function() return 'br_core' end
    C.fire('onResourceStop', 'br_core')
    eq(C.env.BR.TerminalFx.dark(), false, 'br_core stopping puts the lights back: the switch outlives it')
end

describe('Power outage on a client: nothing to do costs nothing')
do
    local C = newClient(POWER_FILES)
    local n = #C.natives
    for _ = 1, 60 do C.slow() end
    eq(#C.natives, n, 'a minute of passes with no outage calls no native')
end

realPrint(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
