-- Unit tests for Control Tower's wave B functions (#396, 2026-10-06): the three
-- that change the world everybody in the match stands in -- Storm control,
-- Time & weather and Power outage. (Wave B's fourth, Storm delay, was removed
-- by the owner on 2026-10-06.)
--
-- The door in front of them (the session, the key, the squad's one use, the
-- Volts, the 3-5 s load, the lobby's notice, the refund) is
-- tools/test_terminal.lua's and tools/test_terminalfx.lua's. This file stands
-- up the REAL server/terminal.lua, server/terminalfx.lua, server/storm.lua and
-- every `server/terminalfx/` file the manifest lists, over a stubbed roster,
-- key and market, and runs each function at a real terminal, the real way:
--
--   PART A  Storm control: the storm steered to the near, far or center end
--           for 150 Volts, the record on the map untouched, a squad that ran
--           Storm reveal told the new end; refused `no_storm` / `no_circle`
--           with nothing spent (the Volts included); everything given back
--           when the final circle is drawn while it loads; the dev path.
--   PART B  Time & weather: the time through the match clock's own anchor
--           (#394's one writer follows it) and back to the match's running
--           clock when it ends; the weather to the match, and on the REAL
--           client/world.lua claimed only inside the circle, below the
--           storm's THUNDER and over its all-clear; the festive sky's clear
--           and its white ground (#399); ended by its time, the match ending
--           and a season switch.
--   PART C  Power outage: around this terminal (fx.outageRadiusM, the
--           page's 1 km), Los Santos or Blaine County by the storm's city
--           line (#381); on the client, the one writer of the lights turns
--           them off only while the view is inside an area, vehicles left
--           out, and back on outside, at the end, in the lobby, off Season 2
--           and when br_core stops -- on a change only.
--
-- The storm's own half -- BR.Storm.futures and steer over many matches, every
-- later circle the planner's -- is tools/test_storm.lua's `control.*` blocks.
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
local WAVE_B = { 'storm_control', 'time_weather', 'power_outage' }
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

--- Open the terminal for `src` the real way and ask to run `id` (at the spot
--- `at`, for a row run at one). With `hold`, the loading is left running (the
--- caller flushes it); otherwise it is let run out and the last word is
--- answered.
local function runAt(src, id, options, hold, at)
    fire(BR.Net.TERMINAL_USE, src, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, src, { terminalId = 'tower', functionId = id, options = options, at = at })
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

describe('wave B: the three rows are built, each a file the manifest lists')
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
-- PART A -- Storm control
-- =========================================================================
--
-- ROUND 4 (owner, 2026-10-06): "we should let them actually pick exactly
-- where they want it". The run carries the spot set on the big map (`at`),
-- and the storm ends EXACTLY on it -- or the run is refused, nothing spent.

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

--- A spot inside the next circle on the map: its center, moved `f` of its
--- radius east.
local function spotIn(m, f)
    local rec = m.storm
    return { x = rec.cx1 + rec.r1 * (f or 0.0), y = rec.cy1 }
end

--- Ask to run Storm control at `at` from the open terminal, and let it finish.
local function controlAt(src, at, hold)
    return runAt(src, 'storm_control', nil, hold, at)
end

describe('Storm control: the row is run at a spot, with no options')
do
    local row = T.row('storm_control')
    ok(row and row.spot == true, 'storm_control is run at a picked spot')
    ok(row.options == nil or #row.options == 0, 'and its zone option is gone')
    local stray = {}
    for k in pairs(COPY) do
        if k:find('^storm_control_opt_') or k:find('^supply_drop_opt_') then stray[#stray + 1] = k end
    end
    eq(#stray, 0, 'no option lines are left for it or Supply drop ' .. table.concat(stray, ', '))
    eq(TS.threeEnds, nil, 'and the three possible ends are gone (no BR.TerminalSolve.threeEnds)')
    eq(CT.fx.stormControlFutures, nil, '(nor fx.stormControlFutures)')
end

for _, f in ipairs({ 0.0, 0.3 }) do
    describe(('Storm control: the storm ends exactly on the spot picked (%.1f of the way out)'):format(f))
    do
        reset()
        local m = lobby('squad', 3)
        local rec = m.storm
        local snap = snapshot(rec)
        local spot = spotIn(m, f)
        local r = controlAt(1, spot)
        ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
        local fin = BR.Storm.finalCentre(m)
        ok(fin and fin.x == spot.x and fin.y == spot.y, 'the storm now ends exactly on the spot',
            fin and ('(%.3f, %.3f) vs (%.3f, %.3f)'):format(fin.x, fin.y, spot.x, spot.y))
        ok(m.stormAim and m.stormAim.x == spot.x and m.stormAim.y == spot.y, 'the match carries the spot')
        ok(m.storm == rec and sameRecord(rec, snap), 'the record on the map did not move')
        eq(#eventsOf(BR.Net.STORM_SYNC), 0, 'and nothing about it was published')
        eq(market.wallet[1], 1000 - 150, '150 Volts were spent')
        ok(r and r.toast and r.toast:find(COPY.storm_control_done, 1, true) == 1,
            'the done line, then the new balance', r and r.toast)
        eq(keys[1], false, 'the key is spent')
        ok(errored() == nil, 'clean', errored())
    end
end

describe('Storm control: a spot the storm cannot end on is refused before anything is spent')
do
    local cases = {
        { label = 'outside the next circle', at = function(m) return spotIn(m, 1.4) end, why = 'storm_spot_out' },
        { label = 'over water', at = function() return { x = -3700.0, y = 0.0 } end, why = 'storm_spot_land' },
        { label = 'outside the play area', at = function() return { x = 7000.0, y = 9000.0 } end, why = 'storm_spot_land' },
    }
    for _, c in ipairs(cases) do
        reset()
        local m = lobby('squad', 3)
        fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
        local f = listed(1, 'storm_control')
        ok(f and f.available == true, c.label .. ': the card is available before a spot is picked', f and f.reason)
        local r = controlAt(1, c.at(m))
        ok(r and r.ok == false and r.code == c.why, c.label .. ': refused ' .. c.why, r and r.code)
        eq(r and r.toast, COPY[c.why], c.label .. ': in its own line')
        nothingSpent(1, c.label)
        eq(#market.charges, 0, c.label .. ': the market was never asked for the 150')
        eq(m.stormAim, nil, c.label .. ': and the storm is not aimed')
    end
    -- A SPOT THE CIRCLES CANNOT ALL HOLD (modeled: the placement stops short).
    reset()
    local m = lobby('squad', 3)
    local real = BR.NextZoneCenterToward
    BR.NextZoneCenterToward = function(_, cx, cy) return cx, cy end
    local r = controlAt(1, spotIn(m, 0.3))
    BR.NextZoneCenterToward = real
    ok(r and r.code == 'storm_spot_edge', 'a spot the circles cannot close on: storm_spot_edge', r and r.code)
    eq(r and r.toast, COPY.storm_spot_edge, 'in its own line')
    nothingSpent(1, 'edge')
    -- NO SPOT, OR THE OLD OPTION: bad_option.
    reset()
    lobby('squad', 3)
    r = controlAt(1, nil)
    ok(r and r.code == 'bad_option', 'no spot: bad_option', r and r.code)
    reset()
    m = lobby('squad', 3)
    r = runAt(1, 'storm_control', { zone = 'far' }, nil, spotIn(m, 0.0))
    ok(r and r.code == 'bad_option', 'the old zone option: bad_option', r and r.code)
    nothingSpent(1, 'bad_option')
end

describe('Storm control: a squad that ran Storm reveal is told the new end')
do
    reset()
    local m = lobby('squad', 3)
    -- Squad B revealed the end earlier this match.
    T.reveal(m, 'squad:B', BR.Storm.finalCentre(m))
    sent = {}
    local spot = spotIn(m, 0.25)
    controlAt(1, spot)
    for _, src in ipairs({ 3, 4 }) do
        local p = lastOf(BR.Net.TERMINAL_REVEAL, src)
        ok(p and p.x == spot.x and p.y == spot.y and p.matchId == m.id,
            ('p%d, of the squad that revealed it, is sent the spot'):format(src))
    end
    eq(lastOf(BR.Net.TERMINAL_REVEAL, 1), nil, 'and nobody who did not reveal it')
    ok(m.terminals.reveals['squad:B'].x == spot.x, 'the reveal a reconnect is re-sent is the new one too')
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
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'storm_control', at = { x = C0.x, y = C0.y } })
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

describe('Storm control: a circle drawn while it loads that no longer holds the spot gives everything back')
do
    reset()
    local m = lobby('squad', 3)
    local spot = spotIn(m, 0.3)
    local r = controlAt(1, spot, true)
    eq(r and r.code, 'running', 'accepted at phase 3')
    eq(market.wallet[1], 850, 'the 150 are spent as it is accepted')
    -- The phase job draws the next circle in those seconds, far from the spot.
    local P = BR.Config.Storm.phases
    m.storm = BR.BuildStormRecord(4, C0.x + 20.0, C0.y, P[3].radius, C0.x - 400.0, C0.y, P[4].radius,
        gameMs, 75000, 75000, P[4].dps, SEED)
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'storm_spot_out', 'over, it can no longer happen: storm_spot_out', r and r.code)
    nothingSpent(1, 'given back')
    eq(market.wallet[1], 1000, 'the 150 are back')
    eq(m.stormAim, nil, 'and the storm is not aimed')
    -- The same for the final circle drawn meanwhile.
    reset()
    m = lobby('squad', 7)
    r = controlAt(1, spotIn(m, 0.0), true)
    eq(r and r.code, 'running', 'accepted at phase 7')
    m.storm = BR.BuildStormRecord(#P, C0.x, C0.y, 40.0, C0.x, C0.y, 0.0, gameMs, 30000, 60000, 6.7, SEED)
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'no_circle', 'the final circle drawn meanwhile: no_circle', r and r.code)
    nothingSpent(1, 'given back, no_circle')
end

describe('Storm control: one spot a match -- a second run is refused, nothing spent, and the first spot holds')
do
    -- ROUND 4'S REVIEW: each squad has its own use, so two squads can both run
    -- it in one match. The first paid 150 Volts for a storm that ends "exactly
    -- on that spot" for "the rest of the match"; a second run must not quietly
    -- make that false. So once the storm is aimed, Storm control is refused
    -- (storm_aimed) -- on the card, at the run and after the load.
    reset()
    local m = lobby('squad', 3)
    local first = spotIn(m, 0.0)
    local r = controlAt(1, first)
    ok(r and r.code == 'done', 'squad A aims the storm', r and r.code)
    keys[3] = true
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    fire(BR.Net.TERMINAL_USE, 3, { terminalId = 'tower' })
    local f = listed(3, 'storm_control')
    ok(f and f.available == false and f.reason == 'storm_aimed', "squad B's card: not available, storm_aimed",
        f and f.reason)
    local charges = #market.charges
    r = controlAt(3, spotIn(m, 0.3))
    ok(r and r.ok == false and r.code == 'storm_aimed', "squad B's run: refused storm_aimed", r and r.code)
    eq(r and r.toast, COPY.storm_aimed, 'in its own line')
    nothingSpent(3, 'storm_aimed')
    eq(#market.charges, charges, 'the market was never asked for the 150')
    local fin = BR.Storm.finalCentre(m)
    ok(fin and fin.x == first.x and fin.y == first.y, 'the storm still ends exactly on the first spot')
    ok(m.stormAim and m.stormAim.x == first.x and m.stormAim.y == first.y, 'and the match still carries it')
    local again, why = BR.Storm.aim(m, first.x + 10.0, first.y)
    ok(again == nil and why == 'storm_aimed', "and the storm's own door refuses a second aim: storm_aimed", why)
    ok(m.stormAim.x == first.x, 'changing nothing')

    -- TWO LOADING AT ONCE: the second to land is refused, everything given back.
    reset()
    m = lobby('squad', 3)
    keys[3] = true
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    local a = spotIn(m, 0.0)
    r = controlAt(1, a, true)
    eq(r and r.code, 'running', 'squad A accepted')
    r = controlAt(3, spotIn(m, 0.25), true)
    eq(r and r.code, 'running', 'squad B accepted too, while A loads')
    flush()
    local ra, rb = lastOf(BR.Net.TERMINAL_RESULT, 1), lastOf(BR.Net.TERMINAL_RESULT, 3)
    ok(ra and ra.code == 'done', 'the first to land aims it', ra and ra.code)
    ok(rb and rb.ok == false and rb.code == 'storm_aimed', 'the second is refused at the end: storm_aimed',
        rb and rb.code)
    nothingSpent(3, 'the second, given back')
    eq(market.wallet[3], 1000, 'its 150 are back')
    fin = BR.Storm.finalCentre(m)
    ok(fin and fin.x == a.x and fin.y == a.y, 'and the storm ends on the first spot')
    ok(errored() == nil, 'clean', errored())
end

describe('Storm control: squad and solo lines')
do
    for _, key in ipairs({ 'storm_control_done', 'storm_control_description', 'no_circle', 'storm_control_what',
                           'storm_control_summary', 'storm_spot_land', 'storm_spot_out', 'storm_spot_edge',
                           'storm_aimed', 'confirm_location' }) do
        ok(TS.pick(COPY, key, false) ~= '', key .. ' has a line')
        ok(not TS.pick(COPY, key, false):lower():find('squad', 1, true),
            ('%s never says squad outside a squad match'):format(key))
    end
    eq(TS.pick(COPY, 'storm_control_risks', false), COPY.storm_control_risks_solo,
        'the risks line has its solo sibling')
    eq(COPY.confirm_location, 'Set location', 'the step\'s button is the owner\'s words, verbatim')
    reset()
    local m = lobby('solo', 3)
    local r = controlAt(1, spotIn(m, 0.0))
    ok(r and r.toast and not r.toast:lower():find('squad', 1, true), "a solo run's toast says no squad",
        r and r.toast)
end

describe('Storm control: the dev path aims for nothing')
do
    reset()
    local m = lobby('squad', 3)
    keys[1] = false
    local spot = spotIn(m, 0.2)
    sv(1, ('run storm_control x=%.3f y=%.3f'):format(spot.x, spot.y))
    local fin = BR.Storm.finalCentre(m)
    ok(fin and math.abs(fin.x - spot.x) < 0.01 and math.abs(fin.y - spot.y) < 0.01,
        '`brterminal run storm_control x=<n> y=<n>` aims the storm at the spot')
    eq(#market.charges, 0, 'no Volts')
    eq(#notices, 0, 'no notice')
    m.stormAim = nil
    sv(1, 'run storm_control')
    eq(m.stormAim, nil, 'without a spot nothing is aimed')
    local said = false
    for _, l in ipairs(logs) do if l:find('needs the spot', 1, true) then said = true end end
    ok(said, 'and it says it needs the spot')
end

-- =========================================================================

-- PART B -- Time & weather, the server
-- =========================================================================

--- A match clock anchor as server/match.lua stamps it at bus start.
local function stampClock(m, at)
    m.clock = BR.World.anchor(at or (gameMs - 600000))
    return m.clock
end

local function skySends(src)
    return eventsOf(BR.Net.TERMINAL_SKY, src)
end

describe('Time & weather: a time run moves the match clock, and touches no weather')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    local r = runAt(1, 'time_weather', { change = 'time', time = 'night' })
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    eq(r and r.toast, COPY.time_weather_done, "and says the page's done line")
    local a = m.clock
    ok(a ~= base and BR.World.validAnchor(a), 'the match runs from a new clock anchor')
    local h, mi = table.unpack(CT.fx.skyTime.night)
    eq(a.startSec, h * 3600 + mi * 60, 'starting at the night the config names')
    eq(a.msPerMin, base.msPerMin, "at the match's own rate (#394)")
    eq(a.at, gameMs, 'from the moment it ran')
    ok(m.terminalSky and m.terminalSky.base == base, "and the match's own anchor is kept")
    eq(m.terminalSky.time, 'night', 'the time chosen is on the record (Power outage asks it)')
    eq(m.terminalSky.weather, nil, 'NOT BOTH: no weather was set')
    eq(m.terminalSky.untilAt, nil, 'and no clock of its own: it lasts the rest of the match')
    for src = 1, 5 do
        local p = skySends(src)[1]
        ok(p and p.payload.weather == nil and p.payload.matchId == m.id,
            ('p%d is told there is no weather of the terminal\'s'):format(src))
    end
    -- THE ONE CLOCK WRITER'S PLAN FOLLOWS THE ANCHOR: one new key, one write.
    local W = BR.World
    local plan = W.clockPlan({ state = BR.PlayerState.ALIVE, anchor = m.clock, now = gameMs + 60000, synced = true })
    eq(plan.mode, 'run', "a client's clock plan runs")
    ok(math.abs(plan.sec - (a.startSec + 60000 * 60 / a.msPerMin)) < 1e-6,
        'from the chosen time, a minute on', plan.sec)
    local was = W.clockPlan({ state = BR.PlayerState.ALIVE, anchor = base, now = gameMs, synced = true })
    ok(plan.key ~= was.key, 'and its key is new, so the writer writes once')
    -- THE REST OF THE MATCH: an hour on, it still holds.
    gameMs = gameMs + 3600000
    BR.Sched.step(gameMs)
    ok(m.terminalSky ~= nil and m.clock == a, 'an hour later the match still runs on its clock')
    ok(errored() == nil, 'clean', errored())
end

describe('Time & weather: a weather run sets the weather, and touches no clock')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    local r = runAt(1, 'time_weather', { change = 'weather', weather = 'snow' })
    ok(r and r.ok == true and r.code == 'done', 'it runs', r and r.code)
    ok(m.clock == base, 'NOT BOTH: the match clock is its own, untouched')
    eq(m.terminalSky.weather, 'SNOW', 'snow is SNOW')
    eq(m.terminalSky.anchor, nil, 'and no time was set')
    for src = 1, 5 do
        local p = skySends(src)[1]
        ok(p and p.payload.weather == 'SNOW', ('p%d is told the weather'):format(src))
    end
    gameMs = gameMs + 3600000
    BR.Sched.step(gameMs)
    eq(m.terminalSky and m.terminalSky.weather, 'SNOW', 'an hour later it still holds: the rest of the match')
    -- A WEATHER RUN ON A MATCH WITH NO CLOCK: the weather needs none.
    reset()
    m = lobby('squad', 3)
    m.clock = nil
    r = runAt(1, 'time_weather', { change = 'weather', weather = 'fog' })
    ok(r and r.ok == true and m.terminalSky and m.terminalSky.weather == 'FOGGY',
        'a match with no clock still takes a weather', r and r.code)
end

describe('Time & weather: either one, never both, on the wire')
do
    reset()
    local m = lobby('squad', 3)
    stampClock(m)
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'time_weather',
        options = { change = 'time', time = 'night', weather = 'snow' } })
    flush()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'bad_option', 'a run asking for a time and a weather: bad_option',
        r and r.code)
    nothingSpent(1, 'both asked')
    eq(m.terminalSky, nil, 'and nothing was set')
    for _, w in ipairs({ 'rain', 'thunder', 'clearing', 'neutral', 'halloween' }) do
        gameMs = gameMs + 1000
        fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'time_weather',
            options = { change = 'weather', weather = w } })
        flush()
        r = lastOf(BR.Net.TERMINAL_RESULT, 1)
        ok(r and r.code == 'bad_option', ('weather=%s is not a choice'):format(w), r and r.code)
    end
    nothingSpent(1, 'the storm\'s weathers asked')
    -- And the default: no choice at all is the time, at night.
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'time_weather' })
    flush()
    ok(m.terminalSky and m.terminalSky.time == 'night' and m.terminalSky.weather == nil,
        'a run with no choices is the defaults: the time, night')
end

describe('Time & weather: the weathers are the engine\'s, less the five that rain')
do
    local W = BR.World
    local offered, n = {}, 0
    for choice, w in pairs(CT.fx.skyWeather) do
        ok(W.WEATHER[w] == true, ('%s names an engine weather (%s)'):format(choice, tostring(w)))
        ok(not W.SKY_ROLE[w], ('%s is not a role: the engine\'s own weather by name'):format(choice))
        offered[w] = true
        n = n + 1
    end
    for _, w in ipairs({ 'RAIN', 'THUNDER', 'CLEARING', 'NEUTRAL', 'HALLOWEEN' }) do
        ok(not offered[w], ('%s is not offered: it rains'):format(w))
    end
    eq(n, #W.WEATHERS - 5, 'every other engine weather is offered')
    local row = T.row('time_weather')
    local seen = 0
    for _, o in ipairs(row.options) do
        for _, ch in ipairs(o.choices) do
            if o.id == 'time' then ok(CT.fx.skyTime[ch] ~= nil, 'time ' .. ch .. ' has its hour') end
            if o.id == 'weather' then
                ok(CT.fx.skyWeather[ch] ~= nil, 'weather ' .. ch .. ' has its engine weather')
                seen = seen + 1
            end
        end
    end
    eq(seen, n, 'and the row offers each of them, once')
    -- THE SERVER'S OWN GUARD: a table that named the storm's two would still
    -- be refused.
    reset()
    local m = lobby('squad', 3)
    CT.fx.skyWeather.fog = 'RAIN'
    ok(not T.startSky(m, { change = 'weather', weather = 'fog' }, gameMs), 'a choice mapped to RAIN is refused')
    CT.fx.skyWeather.fog = 'THUNDER'
    ok(not T.startSky(m, { change = 'weather', weather = 'fog' }, gameMs), 'and to THUNDER')
    CT.fx.skyWeather.fog = 'FOGGY'
    eq(m.terminalSky, nil, 'and neither set anything')
end

describe('Time & weather: one run each, and the second keeps the first')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    runAt(1, 'time_weather', { change = 'time', time = 'night' })
    local night = m.clock
    -- Squad B's key, the other terminal's reach: run from the same terminal.
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    keys[3] = true
    runAt(3, 'time_weather', { change = 'weather', weather = 'fog' })
    ok(m.clock == night, "a weather run keeps the first run's time")
    eq(m.terminalSky.weather, 'FOGGY', 'and sets its weather')
    eq(m.terminalSky.time, 'night', 'the time chosen still on the record')
    ok(m.terminalSky.base == base, "with the match's own anchor still the one kept")
    -- A third squad's time run keeps the weather.
    player(6, m, 'C', SITE)
    keys[6] = true
    market.wallet[6] = 1000
    runAt(6, 'time_weather', { change = 'time', time = 'day' })
    local h = CT.fx.skyTime.day[1]
    eq(m.clock.startSec, h * 3600 + CT.fx.skyTime.day[2] * 60, 'a later time run sets its time')
    eq(m.terminalSky.weather, 'FOGGY', 'and keeps the weather')
    ok(m.terminalSky.base == base, "and the match's own anchor is still the one kept")
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    ok(m.clock == base, 'which is what comes back')
end

describe('Time & weather: the match ending ends it')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    runAt(1, 'time_weather', { change = 'time', time = 'night' })
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    keys[3] = true
    runAt(3, 'time_weather', { change = 'weather', weather = 'overcast' })
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    eq(m.terminalSky, nil, 'the end screen is not the match: it is over')
    ok(m.clock == base, "with the match's own clock back for the end screen")
    eq(skySends(2)[#skySends(2)].payload.weather, nil, 'and the weather released')
end

describe('Time & weather: a season switch ends it')
do
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    runAt(1, 'time_weather', { change = 'time', time = 'night' })
    season(1)
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    season(2)
    eq(m.terminalSky, nil, 'off Season 2 it is over')
    ok(m.clock == base, "and the clock is the match's own")
end

describe('Time & weather: a weather run alone leaves the clock alone at the end')
do
    reset()
    local m = lobby('squad', 3)
    stampClock(m)
    runAt(1, 'time_weather', { change = 'weather', weather = 'smog' })
    -- Something else gave the match a new anchor meanwhile (a `brforce` back
    -- to warmup stamps none; a test stands in): the end must not put back a
    -- clock no time run took.
    local other = BR.World.anchor(gameMs)
    m.clock = other
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    eq(m.terminalSky, nil, 'over')
    ok(m.clock == other, 'and the clock is whatever the match has: a weather run took none')
end

describe('Time & weather: a client that restarts is told again')
do
    reset()
    local m = lobby('squad', 3)
    stampClock(m)
    runAt(1, 'time_weather', { change = 'weather', weather = 'blizzard' })
    sent = {}
    fire(BR.Net.READY, 4)
    local p = skySends(4)[1]
    ok(p and p.payload.weather == 'BLIZZARD', 'br:ready re-sends the weather while it lasts')
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    sent = {}
    fire(BR.Net.READY, 4)
    eq(#skySends(4), 0, 'and nothing once it is over')
    -- A time run alone has no weather to re-send: the clock rides the snapshot.
    reset()
    m = lobby('squad', 3)
    stampClock(m)
    runAt(1, 'time_weather', { change = 'time', time = 'dusk' })
    sent = {}
    fire(BR.Net.READY, 4)
    eq(#skySends(4), 0, 'a time run alone re-sends nothing')
end

describe('Time & weather: a time run refused with no clock, and given back when the match ends while it loads')
do
    reset()
    local m = lobby('squad', 3)
    m.clock = nil
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    local f = listed(1, 'time_weather')
    ok(f and f.available == true, 'the card: available, since a weather run needs no clock', f and f.reason)
    gameMs = gameMs + 1000
    fire(BR.Net.TERMINAL_RUN, 1, { terminalId = 'tower', functionId = 'time_weather',
        options = { change = 'time', time = 'night' } })
    flush()
    local r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'unavailable', 'a time run with no clock to run from: unavailable',
        r and r.code)
    nothingSpent(1, 'no clock')
    stampClock(m)
    r = runAt(1, 'time_weather', { change = 'time', time = 'night' }, true)
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
    for _, key in ipairs({ 'time_weather_done', 'time_weather_description', 'time_weather_what',
                           'time_weather_summary', 'time_weather_duration', 'time_weather_opt_change' }) do
        ok(not TS.pick(COPY, key, false):lower():find('squad', 1, true),
            ('%s never says squad outside a squad match'):format(key))
    end
    -- EVERY LINE THAT NAMES THE WEATHER SAYS IT IS THE WEATHER INSIDE THE
    -- CIRCLE, and none promises a few minutes any more.
    for _, key in ipairs({ 'time_weather_summary', 'time_weather_what' }) do
        ok(COPY[key]:find('inside the circle', 1, true) ~= nil, key .. ' says the weather is inside the circle')
        ok(not COPY[key]:find('a while', 1, true) and not COPY[key]:find('minute', 1, true),
            key .. ' promises no few minutes')
    end
    ok(COPY.time_weather_what:find('not both', 1, true) ~= nil, 'the page says one or the other, not both')
    -- ANOTHER RUN CAN CHANGE IT (round 4's review): another squad's run of the
    -- same kind replaces this one, so every line that says how long it lasts
    -- says so too -- the card, the page, the duration and the done line.
    eq(COPY.time_weather_duration, 'Rest of the match, or until another run changes it',
        'the duration is the rest of the match, or until another run changes it')
    for _, key in ipairs({ 'time_weather_summary', 'time_weather_what', 'time_weather_duration', 'time_weather_done' }) do
        ok(COPY[key]:find('another run changes it', 1, true) ~= nil, key .. ' says another run can change it')
    end
    local durations = {}
    for k in pairs(COPY) do
        if k:find('^time_weather_opt_duration') then durations[#durations + 1] = k end
    end
    eq(#durations, 0, 'and no duration option is left in the copy ' .. table.concat(durations, ', '))
    reset()
    local m = lobby('squad', 3)
    local base = stampClock(m)
    keys[1] = false
    sv(1, 'run time_weather change=time time=dusk')
    ok(m.terminalSky and m.terminalSky.time == 'dusk' and m.clock ~= base,
        '`brterminal run time_weather change=time time=dusk` sets the time')
    sv(1, 'run time_weather change=weather weather=xmas')
    eq(m.terminalSky and m.terminalSky.weather, 'XMAS', '`run time_weather change=weather weather=xmas` the weather')
    local before = m.terminalSky.weather
    sv(1, 'run time_weather time=night weather=snow')
    eq(m.terminalSky.weather, before, 'both at once is refused')
    eq(#market.charges + #notices, 0, 'for nothing, and with no notice')
end

-- =========================================================================
-- PART B, THE CLIENT -- the sky claim, over the REAL client/world.lua
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
    -- client/terminalfx.lua's one SLOW pass, as the function files hook it
    -- (F.onSlow); its own body is test_terminalfx.lua's.
    env.BR.TerminalFx = env.BR.TerminalFx or {}
    env.BR.TerminalFx.onSlow = function(fn) C.jobs['onSlow' .. tostring(fn)] = fn end
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
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1, weather = 'SNOW' })
    local name, src = W.sky()
    eq(name, 'SNOW', 'told SNOW with its view inside the circle: SNOW')
    eq(src, 'terminal', 'as the terminal\'s claim')
    eq((C.wrote()), 'SNOW', 'written through client/world.lua')
    ok(C.count('SetRainLevel') >= 1, 'with the rain knob handed back to the weather written')

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
    eq((W.sky()), 'SNOW', 'back inside, the storm\'s all-clear yields to the chosen SNOW')
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
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1, weather = 'CLEAR' })
    eq((W.sky()), 'CLEAR', 'clear, in December or January too, is the engine\'s CLEAR (round 4)')
    _, ground = C.wrote()
    eq(ground, false, 'and the ground is bare under it: the ground follows the resolved weather (#399)')
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1, weather = 'BLIZZARD' })
    _, ground = C.wrote()
    eq((W.sky()), 'BLIZZARD', 'blizzard is BLIZZARD')
    eq(ground, true, 'with snow on the ground')
    C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1 })
    eq((W.sky()), 'XMAS', 'over, the festive sky comes back')
end

describe('Time & weather on a client: never the storm\'s two, never a role')
do
    local C = newClient(SKY_FILES)
    C.inside = true
    for _, w in ipairs({ 'RAIN', 'THUNDER', 'base', 'lobby' }) do
        C.fire(C.env.BR.Net.TERMINAL_SKY, { matchId = 1, weather = w })
        eq(C.env.BR.TerminalFx.skyClaim(), nil, ('told %s: no claim'):format(w))
    end
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
-- PART C -- Power outage, the server
-- =========================================================================

local function powerSends(src)
    return eventsOf(BR.Net.TERMINAL_POWER, src)
end

--- A night a Time & weather run set (round 4: Power outage works only on
--- one): the match given a clock, then a time run's night. Returns the match.
local function night(m)
    stampClock(m)
    T.startSky(m, { change = 'time', time = 'night' }, gameMs)
    return m
end

describe('Power outage: only on a night a Time & weather run set (round 4)')
do
    -- THE OWNER (2026-10-06): "The power outage tool should only work if
    -- someone else has set it to night time first".
    reset()
    local m = lobby('squad', 3)
    stampClock(m)
    fire(BR.Net.TERMINAL_USE, 1, { terminalId = 'tower' })
    gameMs = gameMs + 1000
    local f = listed(1, 'power_outage')
    ok(f and f.available == false and f.reason == 'no_night',
        "the match's own clock: the card says no_night", f and tostring(f.reason))
    local r = runAt(1, 'power_outage', { area = 'here', duration = '120' })
    ok(r and r.ok == false and r.code == 'no_night', 'and a run is refused no_night', r and r.code)
    eq(r and r.toast, COPY.no_night, 'in its line')
    nothingSpent(1, 'no night')
    eq(m.terminalPower, nil, 'and no outage starts')

    -- A WEATHER RUN IS NO NIGHT; NOR ARE DAY AND DUSK.
    T.startSky(m, { change = 'weather', weather = 'fog' }, gameMs)
    r = runAt(1, 'power_outage', { area = 'here', duration = '120' })
    eq(r and r.code, 'no_night', 'a weather run alone: still no_night')
    for _, t in ipairs({ 'day', 'dusk' }) do
        T.startSky(m, { change = 'time', time = t }, gameMs)
        r = runAt(1, 'power_outage', { area = 'here', duration = '120' })
        eq(r and r.code, 'no_night', t .. ': no_night')
    end
    nothingSpent(1, 'day and dusk')

    -- NIGHT: it runs -- and a weather run after the night keeps it night.
    T.startSky(m, { change = 'time', time = 'night' }, gameMs)
    T.startSky(m, { change = 'weather', weather = 'clear' }, gameMs)
    ok(T.terminalNight(m), 'a weather run after a night keeps the night')
    r = runAt(1, 'power_outage', { area = 'here', duration = '120' })
    ok(r and r.ok == true and r.code == 'done', 'on the night: it runs', r and r.code)
    eq(#T.outagesOf(m), 1, 'and the outage is live')
    -- A LATER DAY DOES NOT END A RUNNING OUTAGE: it is a switch on the lights.
    T.startSky(m, { change = 'time', time = 'day' }, gameMs)
    ok(not T.terminalNight(m), 'a later day run ends the night')
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    eq(#T.outagesOf(m), 1, 'but not the outage already running')

    -- THE NIGHT IS OVER WHEN THE MATCH IS: its own clock comes back.
    reset()
    m = night(lobby('squad', 3))
    ok(T.terminalNight(m), 'night')
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    ok(not T.terminalNight(m), "the match's end puts its own clock back: no night")

    -- AND A CLOCK SOMETHING ELSE STAMPED (a `brforce` back to warmup draws the
    -- match a new one) is no terminal's night, whatever the record still says.
    reset()
    m = night(lobby('squad', 3))
    stampClock(m, gameMs)
    ok(m.terminalSky and m.terminalSky.time == 'night' and not T.terminalNight(m),
        "the record says night, but the match's clock is not that run's: no night")

    -- THE END OF THE LOAD: a day landing while it loads gives everything back.
    reset()
    m = night(lobby('squad', 3))
    r = runAt(1, 'power_outage', { area = 'here', duration = '120' }, true)
    eq(r and r.code, 'running', 'accepted on the night')
    T.startSky(m, { change = 'time', time = 'dusk' }, gameMs)
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false and r.code == 'no_night', 'a dusk run meanwhile: no_night at the end', r and r.code)
    nothingSpent(1, 'refunded')
    eq(m.terminalPower, nil, 'and no outage was started')

    -- THE PAGE SAYS SO.
    -- WHILE IT'S NIGHT (round 4's review): a night a later day run ended is
    -- no night, so neither line says only that someone once made it night.
    local rule = "while it's night because someone ran " .. COPY.time_weather_name
    ok(COPY.power_outage_what:find(rule, 1, true) ~= nil, 'the page says it needs a night from '
        .. COPY.time_weather_name .. ', still going')
    ok(COPY.no_night:find(rule, 1, true) ~= nil, 'and so does the reason')
    ok(COPY.power_outage_summary:find('at night', 1, true) ~= nil, 'and the card')
end

describe('Power outage: around this terminal, to the whole match')
do
    reset()
    local m = night(lobby('squad', 3))
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

describe('Power outage: around the terminal, not the player standing at it')
do
    reset()
    local m = night(lobby('squad', 3))
    roster[1].pos = { x = SITE.x + 2.0, y = SITE.y - 1.0, z = 30.0 }
    local r = runAt(1, 'power_outage', { area = 'here', duration = '120' })
    ok(r and r.ok == true, 'it runs from two meters off', r and r.code)
    local a = T.outagesOf(m)[1] and T.outagesOf(m)[1].area
    ok(a and a.x == SITE.x and a.y == SITE.y, 'the area is centered on the terminal itself',
        a and ('(%.1f, %.1f)'):format(a.x or 0, a.y or 0))
end

describe('Power outage: Los Santos and Blaine County are the storm\'s city line')
do
    eq(BR.StormCityLine(), BR.Config.Storm.anchorRegion.cityMaxY, 'the line is the anchor\'s own (#381)')
    for _, choice in ipairs({ 'city', 'county' }) do
        reset()
        local m = night(lobby('squad', 3))
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

describe('Wave B\'s lines say whose lights go out and where the weather holds')
do
    -- ═══ THE LINES DESCRIBE WHAT WAS BUILT, NOT WHAT WAS FIRST IMAGINED ═══
    --
    -- The engine's blackout is one switch per player for the whole map, so a
    -- Power outage puts the lights out for the players in an area -- someone
    -- outside it sees the area lit. And Time & weather's weather holds only
    -- inside the circle (the owner's rule). The wave B review found the card,
    -- the done line and the lobby's notice still saying the area goes dark and
    -- the match's weather changes. So every line of the two functions (the
    -- option labels aside: those name a choice) is read here: one that puts
    -- the lights out says for whom, and one that names the weather says it is
    -- the weather inside the circle. The function's own name is taken out
    -- first ("Time & weather" names the weather and says nothing about it).
    local function lines(id)
        local out = {}
        for k, v in pairs(COPY) do
            if k:sub(1, #id + 1) == id .. '_' and k ~= id .. '_name'
                and not k:find('_opt_', 1, true) then
                local text = v
                local i, j = text:find(COPY[id .. '_name'], 1, true)
                if i then text = text:sub(1, i - 1) .. text:sub(j + 1) end
                out[#out + 1] = { key = k, text = text:lower() }
            end
        end
        table.sort(out, function(a, b) return a.key < b.key end)
        return out
    end
    local lightLines, weatherLines = 0, 0
    for _, l in ipairs(lines('power_outage')) do
        if l.text:find('light', 1, true) or l.text:find('dark', 1, true)
            or l.text:find('power', 1, true) then
            lightLines = lightLines + 1
            ok(l.text:find('player', 1, true) or l.text:find('squad', 1, true)
                or l.text:find("you're", 1, true),
                ('%s says whose lights go out'):format(l.key), COPY[l.key])
        end
    end
    for _, l in ipairs(lines('time_weather')) do
        if l.text:find('weather', 1, true) then
            weatherLines = weatherLines + 1
            ok(l.text:find('inside the circle', 1, true),
                ('%s says the weather is the weather inside the circle'):format(l.key), COPY[l.key])
        end
    end
    ok(lightLines >= 6, 'the card, the page, the done line, the notice and both risks lines were read',
        lightLines)
    -- (Round 4's done line names neither the time nor the weather: one line
    -- for either choice.)
    ok(weatherLines >= 2, 'the card and the page were read', weatherLines)
end

describe('Power outage: it ends, one at a time, and with the match and the season')
do
    reset()
    local m = night(lobby('squad', 3))
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
    m = night(lobby('squad', 3))
    runAt(1, 'power_outage', { area = 'city', duration = '240' })
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    eq(m.terminalPower, nil, 'the match ending ends it')
    eq(#powerSends(2)[#powerSends(2)].payload.list, 0, 'with the lights back for everyone')

    reset()
    m = night(lobby('squad', 3))
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
    night(lobby('squad', 3))
    runAt(1, 'power_outage', { area = 'here', duration = '120' })
    sent = {}
    fire(BR.Net.READY, 4)
    local p = powerSends(4)[1]
    ok(p and #p.payload.list == 1, 'br:ready re-sends them while they last')
end

describe('Power outage: the match ending while it loads gives everything back; the dev path')
do
    reset()
    local m = night(lobby('squad', 3))
    local r = runAt(1, 'power_outage', { area = 'here', duration = '120' }, true)
    eq(r and r.code, 'running', 'accepted')
    m.state = BR.MatchState.ENDED
    flush()
    r = lastOf(BR.Net.TERMINAL_RESULT, 1)
    ok(r and r.ok == false, 'over, the match ended: it can no longer happen', r and r.code)
    nothingSpent(1, 'given back')
    eq(m.terminalPower, nil, 'and no outage was started')

    reset()
    m = night(lobby('squad', 3))
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
-- THE PERSISTENT NOTICES (round 4) for wave B's three -- each player's rows
-- as the real pass sends them (server/terminalfx.lua's 'terminal.impacts')
-- =========================================================================

--- `src`'s last list as "key@end|...", '' empty, nil never sent.
local function impactRows(src)
    local d = lastOf(BR.Net.TERMINAL_IMPACTS, src)
    if not d then return nil end
    local out = {}
    for _, r in ipairs(d.list or {}) do
        out[#out + 1] = ('%s@%s'):format(r.key, r.endsAt and tostring(r.endsAt) or 'end')
    end
    return table.concat(out, '|')
end
local function hasRow(src, key)
    local d = lastOf(BR.Net.TERMINAL_IMPACTS, src)
    for _, r in ipairs(d and d.list or {}) do if r.key == key then return r end end
    return nil
end

describe('the persistent notices: Time & weather -- everyone but its runner, until the match ends')
do
    reset()
    for s = 1, 8 do T.forgetImpacts(s) end
    local m = lobby('squad', 3)
    stampClock(m)
    runAt(1, 'time_weather', { change = 'time', time = 'night' })
    for _, src in ipairs({ 2, 3, 4, 5 }) do
        eq(impactRows(src), 'impact_time@end', ('p%d: the time of day was changed, for the rest of the match'):format(src))
    end
    local r = hasRow(2, 'impact_time')
    ok(r and r.text == COPY.impact_time and r.tail == COPY.impact_until_end and r.endsAt == nil,
        'in its words, with the tail in place of a clock')
    eq(impactRows(1), nil, 'not the player who ran it')

    -- ANOTHER PLAYER'S WEATHER RUN: its own row, sparing that runner.
    keys[3] = true
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    runAt(3, 'time_weather', { change = 'weather', weather = 'fog' })
    eq(impactRows(1), 'impact_weather@end', 'the time\'s runner now sees the weather\'s row')
    eq(impactRows(3), 'impact_time@end', 'the weather\'s runner, the time\'s row only')
    eq(impactRows(4), 'impact_time@end|impact_weather@end', 'everyone else, both, in key order')
    eq(hasRow(4, 'impact_weather').text, COPY.impact_weather, 'in its words')

    -- THE MATCH ENDING: gone with the sky.
    m.state = BR.MatchState.ENDED
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    ok(impactRows(4) == '' and impactRows(1) == '' and impactRows(3) == '', 'the match over: every list empty')
    ok(errored() == nil, 'clean', errored())
end

describe('the persistent notices: Storm control -- everyone but whoever aimed it, until the match ends')
do
    reset()
    for s = 1, 8 do T.forgetImpacts(s) end
    local m = lobby('squad', 3)
    local r = controlAt(1, spotIn(m, 0.0))
    ok(r and r.code == 'done', 'it runs', r and r.code)
    for _, src in ipairs({ 2, 3, 4, 5 }) do
        eq(impactRows(src), 'impact_storm@end', ('p%d: the storm will end where another player chose'):format(src))
    end
    eq(hasRow(3, 'impact_storm').text, COPY.impact_storm, 'in its words')
    eq(impactRows(1), nil, 'not the player who aimed it')
    -- ONE SPOT A MATCH: another player's Storm control is refused, and the
    -- rows stay as they were.
    keys[3] = true
    roster[3].pos = { x = SITE.x, y = SITE.y, z = 30.0 }
    r = controlAt(3, spotIn(m, 0.0))
    ok(r and r.code == 'storm_aimed', 'a second Storm control is refused', r and r.code)
    ok(impactRows(1) == nil and impactRows(3) == 'impact_storm@end', 'and the row still spares only the first runner')
    ok(errored() == nil, 'clean', errored())
end

describe('the persistent notices: Power outage -- whoever stands in its area, as they walk in and out')
do
    reset()
    for s = 1, 8 do T.forgetImpacts(s) end
    local m = night(lobby('squad', 3))
    roster[5].pos = { x = SITE.x + 5000.0, y = SITE.y, z = 30.0 }    -- far outside the 1 km
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    runAt(1, 'power_outage', { area = 'here', duration = '120' })
    local ends = T.outagesOf(m)[1].untilAt
    for _, src in ipairs({ 2, 3, 4 }) do
        local r = hasRow(src, 'impact_outage')
        ok(r and r.endsAt == ends and r.text == COPY.impact_outage,
            ('p%d, in the area: the lights are out where they are, until it ends'):format(src))
    end
    eq(hasRow(5, 'impact_outage'), nil, 'a player outside the area has no such row')
    eq(hasRow(1, 'impact_outage'), nil, 'nor the player who ran it, though they stand in it')
    -- WALKING OUT, AND BACK IN.
    roster[3].pos = { x = SITE.x + 5000.0, y = SITE.y, z = 30.0 }
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    eq(hasRow(3, 'impact_outage'), nil, 'walked out: the row goes on the next pass')
    roster[5].pos = { x = SITE.x + 10.0, y = SITE.y, z = 30.0 }
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    ok(hasRow(5, 'impact_outage') ~= nil, 'walked in: it comes')
    -- IT ENDS.
    gameMs = ends
    BR.Sched.step(gameMs)
    gameMs = gameMs + 1000
    BR.Sched.step(gameMs)
    ok(hasRow(2, 'impact_outage') == nil and hasRow(5, 'impact_outage') == nil, 'over: gone for everyone')
    ok(errored() == nil, 'clean', errored())
end

-- =========================================================================
-- PART C, THE CLIENT -- the one writer of the lights
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
