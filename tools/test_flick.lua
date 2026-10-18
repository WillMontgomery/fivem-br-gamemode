-- Unit tests for the Flick cameras (#419), the server and the shared rules:
-- the cameras that feed the terminal's Scan (docs/flick.md).
--
-- This file stands up the REAL br_lib/shared/flick_solve.lua, the real
-- br_core/server/flick.lua and the edited server/terminal.lua and
-- server/terminalfx.lua over a stubbed roster, scheduler and match, with a
-- registry of its own (a fixture: cameras where each block wants them), and:
--
--   PART A  the solve: the grid against a brute-force walk of every row,
--           "covers" at its edges on foot and in a vehicle, z ignored, a down
--           camera covering nothing; the down rule; the reach rule; and the
--           real registry built whole.
--   PART B  the door, one refusal at a time in its order.
--   PART C  the decision and the credit: 2 a camera, the 16th pays 0, the cap
--           by account across a leave and a rejoin, a bystander's `other` then
--           the shooter's `me`, two `me`, a downed reporter, the dev down, an
--           explosion -- and the path the Volts take to the match's one ADD.
--   PART D  who is told: the players near a down and nobody farther, a
--           spectator by their target, a Scan squad all of it, the 1 s pass,
--           the snapshot's view, two matches apart.
--   PART E  Scan through the cameras: the privacy property over every payload
--           sent, on foot and in a vehicle, a camera downed mid-match, Ghost,
--           `flick = true`, and Scan as it was with Flick off.
--   PART F  the dev command, and the wiring the other files make, by text.
--
-- The client is tools/test_flick_client.lua's.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_flick.lua

local realPrint = print
local realExit  = os.exit

local gameMs = 100000
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
function print(s) logs[#logs + 1] = tostring(s) end

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
    'br_lib/config/match.lua',
    'br_lib/config/storm.lua',
    'br_lib/config/map.lua',
    'br_lib/config/weapons.lua',
    'br_lib/config/vehicles.lua',
    'br_lib/config/loot.lua',
    'br_lib/config/market.lua',
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
    'br_lib/config/terminals.lua',
    'br_lib/config/flick.lua',
    'br_lib/config/flick_cameras.lua',
    'br_lib/shared/storm_solve.lua',
    'br_lib/shared/storm_shape.lua',
    'br_lib/shared/terminal_solve.lua',
    'br_lib/shared/shop_solve.lua',
    'br_lib/shared/flick_solve.lua',
})

local FC = BR.Config.Flick
local FS = BR.FlickSolve
local REAL_CAMERAS = FC.cameras
BR.Season.strict = true

local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end
season(2)

--- Flick off or on at Season 2, by its row: the season gate's own answer.
local FLICK_FROM = BR.Config.Seasons.features.flick.from
local function flickOn(on)
    BR.Config.Seasons.features.flick.from = on and FLICK_FROM or (BR.Config.Seasons.latest + 1)
end

-- ---------------------------------------------------------------- stubs ---

local jobs, handlers = {}, {}
local sent = {}          -- TriggerClientEvent: { event, src, payload }
local notices = {}

BR.Sched = { every = function(_, name, fn) jobs[name] = fn end }
function RegisterNetEvent() end
function AddEventHandler(name, fn)
    handlers[name] = handlers[name] or {}
    table.insert(handlers[name], fn)
end
function TriggerClientEvent(event, src, payload)
    sent[#sent + 1] = { event = event, src = src, payload = payload }
end
function SetTimeout() end

local roster, matches = {}, {}
local spectating = {}    -- [src] = the player they watch
local riders = {}        -- [ped] = true: in a vehicle, any seat
local seatAsks = 0
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
    licenseOf = function(src) return roster[src] and roster[src].license or nil end,
}
BR.Server = {
    matchOf = function(src)
        local e = roster[src]
        return e and e.matchId and matches[e.matchId] or nil
    end,
    matchById = function(id) return matches[id] end,
    eachMatch = function(fn)
        local order = {}
        for _, m in pairs(matches) do order[#order + 1] = m end
        table.sort(order, function(a, b) return a.id < b.id end)
        for _, m in ipairs(order) do fn(m) end
    end,
    notify = function(target, text, tone)
        notices[#notices + 1] = { target = target, text = text, tone = tone }
    end,
    isInMatch = function(st)
        return st == BR.PlayerState.ALIVE or st == BR.PlayerState.DBNO
    end,
}
BR.Broadcast = {
    toMatch = function(m, event, payload)
        for src, e in pairs(roster) do
            if e.matchId == m.id then TriggerClientEvent(event, src, payload) end
        end
    end,
}
BR.Spectate = { targetOf = function(src) return spectating[src] end }
BR.Vehicles = {
    ridingIn = function(ped)
        seatAsks = seatAsks + 1
        return riders[ped] and 9000 or nil
    end,
}
BR.Yubikey = { holds = function() return false end, push = function() end }
BR.Market = { balanceOf = function() return 0 end }
BR.Storm = {}

loadAll({
    'br_core/server/terminal.lua',
    'br_core/server/terminalfx.lua',
    'br_core/server/terminalfx/ghost.lua',
    'br_core/server/flick.lua',
})

local T = BR.Terminal
local F = BR.Flick

local function fire(name, src, ...)
    local prev = source
    source = src
    for _, fn in ipairs(handlers[name] or {}) do fn(...) end
    source = prev
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

--- Every camera id a player has been sent this block, as a set.
local function heldBy(src)
    local out = {}
    for _, s in ipairs(eventsOf(BR.Net.FLICK_DOWN, src)) do
        for _, id in ipairs(s.payload.ids or {}) do out[id] = true end
    end
    return out
end

local function setSize(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- THE FIXTURE REGISTRY: cameras where the blocks want them, far apart.
--   7    the door's and the decision's camera, at (1000, 1000)
--   8    2 km north of it, (1000, 3000)
--   9    2 km east, (3000, 1000)
--   101..120  a row 20 m apart at y = -5000, x = 120..500: the cap
local FIX = {
    { id = 7, x = 1000.0, y = 1000.0, z = 30.0, h = 0.0, region = 'fix' },
    { id = 8, x = 1000.0, y = 3000.0, z = 30.0, h = 0.0, region = 'fix' },
    { id = 9, x = 3000.0, y = 1000.0, z = 30.0, h = 0.0, region = 'fix' },
}
for i = 1, 20 do
    FIX[#FIX + 1] = { id = 100 + i, x = 100.0 + 20.0 * i, y = -5000.0, z = 30.0, h = 0.0, region = 'row' }
end
FC.cameras = FIX
local CAM = FIX[1]

local function newMatch(id, state)
    local m = { id = id, seq = id, state = state or BR.MatchState.PLAYING, mode = 'squad' }
    matches[id] = m
    return m
end

local function player(src, m, squad, x, y, state)
    roster[src] = {
        src = src, name = 'p' .. src, state = state or BR.PlayerState.ALIVE,
        matchId = m and m.id or nil, squadId = squad, license = 'license:' .. src,
        pos = x and { x = x, y = y, z = 30.0 } or nil, posAt = gameMs,
        ped = 1000 + src, voltsPickedUp = 0,
    }
    return roster[src]
end

local function reset()
    sent, notices, logs = {}, {}, {}
    roster, matches, spectating, riders = {}, {}, {}, {}
    seatAsks = 0
    flickOn(true)
    season(2)
    gameMs = gameMs + 100000
    -- The door's own interval belongs to the player; a new block is new players.
    for s = 1, 40 do fire('playerDropped', s) end
end

--- One report, as `src` sends it, a second after the last.
local function rep(src, d)
    gameMs = gameMs + 1000
    for _, e in pairs(roster) do e.posAt = gameMs end
    return F.report(src, d, gameMs)
end

-- =========================================================================
-- PART A -- the solve
-- =========================================================================

describe('the solve: the grid finds exactly what a walk of every row finds')
do
    local rows = REAL_CAMERAS
    local g = FS.grid(rows, FC.gridM)
    eq(g.n, #rows, 'every row of the real registry is in the grid')
    local back = 0
    for _, r in ipairs(rows) do
        if FS.row(g, r.id) == r then back = back + 1 end
    end
    eq(back, #rows, 'and every id finds its own row')
    local rng = BR.Rng(4191)
    local function rand(a, b) return a + (b - a) * rng:float() end
    local mismatch, tried = 0, 0
    for _, r in ipairs({ 75.0, 150.0, 500.0 }) do
        for _ = 1, 150 do
            local x, y = rand(-2500.0, 1500.0), rand(-3000.0, 1000.0)
            local want = {}
            for _, row in ipairs(rows) do
                if (row.x - x) ^ 2 + (row.y - y) ^ 2 <= r * r then want[row.id] = true end
            end
            local got = {}
            FS.near(g, x, y, r, function(row) got[row.id] = true end)
            tried = tried + 1
            local same = setSize(want) == setSize(got)
            for id in pairs(want) do if not got[id] then same = false end end
            if not same then mismatch = mismatch + 1 end
        end
    end
    eq(mismatch, 0, ('the grid and a brute-force walk agree at %d points, 75, 150 and 500 m'):format(tried))
    local bad = FS.grid({ { id = 0, x = 1, y = 1 }, { id = 3.5, x = 1, y = 1 }, { id = 4, x = 0 / 0, y = 1 },
        { id = 5, x = 1, y = 1 }, { id = 5, x = 2, y = 2 } }, 150.0)
    eq(bad.n, 1, 'rows that are not cameras are left out, and an id is taken once')
end

describe('the solve: covers -- 75 m on foot, 150 m in a vehicle, flat, a down camera sees nothing')
do
    local g = FS.grid({ { id = 1, x = 0.0, y = 0.0, z = 900.0, h = 0.0 } }, 150.0)
    ok(FS.covers(g, nil, 74.9, 0.0, false, FC), '74.9 m on foot: seen')
    ok(not FS.covers(g, nil, 75.1, 0.0, false, FC), '75.1 m on foot: not')
    ok(FS.covers(g, nil, 0.0, 149.9, true, FC), '149.9 m in a vehicle: seen')
    ok(not FS.covers(g, nil, 0.0, 150.1, true, FC), '150.1 m in a vehicle: not')
    ok(not FS.covers(g, nil, 120.0, 0.0, false, FC), '120 m on foot: not')
    ok(FS.covers(g, nil, 50.0, 0.0, false, FC), 'the camera 900 m up and the player on the ground: z is ignored')
    ok(not FS.covers(g, { [1] = true }, 10.0, 0.0, true, FC), 'a down camera covers nothing')
    local asked = 0
    local function seat() asked = asked + 1 return true end
    FS.covers(g, nil, 40.0, 0.0, seat, FC)
    FS.covers(g, nil, 400.0, 0.0, seat, FC)
    eq(asked, 0, 'the seat is not asked inside 75 m nor past 150 m')
    ok(FS.covers(g, nil, 100.0, 0.0, seat, FC) and asked == 1, 'and asked once between them')
    eq(FC.rangeM, 75.0, 'the owner\'s 75 m')
    eq(FC.vehicleRangeM, 150.0, 'and 150 m')
    eq(FC.gridM >= FC.vehicleRangeM, true, 'the grid\'s cell is at least the widest range')
end

describe('the solve: the down rule, a reason for each, none for a camera untouched')
do
    local row = { id = 1, x = 10.0, y = 20.0, z = 0.0 }
    local c = FC.client
    eq(FS.downed({ upright = 1.0, x = 10.0, y = 20.0, health = 1000, maxHealth = 1000 }, row, c), nil,
        'untouched: up')
    eq(FS.downed({ broken = true, upright = 1.0 }, row, c), 'broken', 'a part torn off: broken')
    eq(FS.downed({ upright = 0.85 }, row, c), 'tilted', 'tilted past 30 degrees')
    eq(FS.downed({ upright = 0.9 }, row, c), nil, 'not yet at 25')
    eq(FS.downed({ upright = 1.0, x = 10.8, y = 20.0 }, row, c), 'moved', 'moved 0.8 m')
    eq(FS.downed({ upright = 1.0, x = 10.5, y = 20.0 }, row, c), nil, 'not at 0.5')
    eq(FS.downed({ upright = 1.0, health = 100, maxHealth = 1000 }, row, c), nil,
        'health is off while healthLossDown is nil')
    local withLoss = { tiltDownDeg = 30.0, movedDownM = 0.75, healthLossDown = 50 }
    eq(FS.downed({ upright = 1.0, health = 940, maxHealth = 1000 }, row, withLoss), 'health',
        'and on once it is set')
end

describe('the solve: the reach rule and an id\'s shape')
do
    local R = FC.report
    eq(FS.reach('other', 'vehicle', R), R.reach.other, 'a bystander\'s: reach.other')
    eq(FS.reach('me', 'vehicle', R), R.reach.vehicle, 'a ram: reach.vehicle')
    eq(FS.reach('me', 'weapon', R), R.reach.weapon, 'a shot: reach.weapon')
    eq(FS.reach('me', nil, R), R.reach.weapon, 'no cause: a shot')
    ok(FS.validId(1) and FS.validId(9999) and FS.validId(117.0), 'whole numbers 1..9999')
    ok(not FS.validId(0) and not FS.validId(10000) and not FS.validId(1.5) and not FS.validId('7')
        and not FS.validId(nil), 'and nothing else')
end

-- =========================================================================
-- PART B -- the door, one refusal at a time, in its order
-- =========================================================================

describe('the door: every refusal, in order, silent and counted')
do
    reset()
    local m = newMatch(1)
    player(1, m, 'A', CAM.x + 10.0, CAM.y)
    flickOn(false)
    eq(rep(1, { id = 7, by = 'me', cause = 'weapon' }), 'season', '1. Flick off: refused')
    flickOn(true)
    for _, bad in ipairs({
        { label = 'no table', d = 'x' },
        { label = 'an id that is a string', d = { id = '7', by = 'me' } },
        { label = 'an id 0', d = { id = 0, by = 'me' } },
        { label = 'a fraction', d = { id = 7.5, by = 'me' } },
        { label = 'an id no row has', d = { id = 4444, by = 'me' } },
        { label = 'by somebody named', d = { id = 7, by = 12 } },
        { label = 'a cause that is not one', d = { id = 7, by = 'me', cause = 'fire' } },
    }) do
        eq(rep(1, bad.d), 'shape', '2. ' .. bad.label .. ': shape')
    end
    gameMs = gameMs + 1000
    F.report(1, { id = 8, by = 'other' }, gameMs)
    eq(F.report(1, { id = 8, by = 'other' }, gameMs + 100), 'rate', '3. 100 ms after the last: rate')
    eq(#eventsOf(BR.Net.FLICK_DOWN), 0, 'and no refusal answers or sends anything')

    reset()
    m = newMatch(1)
    player(1, m, 'A', CAM.x + 10.0, CAM.y)
    for _ = 1, FC.report.perMatch do rep(1, { id = 8, by = 'other' }) end
    eq(rep(1, { id = 7, by = 'me' }), 'rate', '3. past perMatch reports a match: rate')

    for _, st in ipairs({ BR.MatchState.WARMUP, BR.MatchState.BUS, BR.MatchState.ENDED }) do
        reset()
        m = newMatch(1, st)
        player(1, m, 'A', CAM.x + 10.0, CAM.y)
        eq(rep(1, { id = 7, by = 'me' }), 'match', '4. a match in ' .. st .. ': match')
    end
    reset()
    player(1, nil, nil, CAM.x + 10.0, CAM.y, BR.PlayerState.LOBBY)
    eq(rep(1, { id = 7, by = 'me' }), 'match', '4. no match at all: match')

    for _, st in ipairs({ BR.PlayerState.OUT, BR.PlayerState.FREEFALL, BR.PlayerState.GLIDE }) do
        reset()
        m = newMatch(1)
        player(1, m, 'A', CAM.x + 10.0, CAM.y, st)
        eq(rep(1, { id = 7, by = 'me' }), 'player', '5. a player ' .. st .. ': player')
    end

    reset()
    m = newMatch(1)
    local e = player(1, m, 'A', CAM.x + 10.0, CAM.y)
    gameMs = gameMs + 1000
    e.posAt = gameMs - FC.report.sampleMaxAgeMs - 1
    eq(F.report(1, { id = 7, by = 'me', cause = 'weapon' }, gameMs), 'reach', '6. a stale sample: reach')
    e.pos = { x = CAM.x + 30.0, y = CAM.y, z = CAM.z }
    eq(rep(1, { id = 7, by = 'me', cause = 'vehicle' }), 'reach', '6. a ram from 30 m: reach')
    e.pos = { x = CAM.x + 401.0, y = CAM.y, z = CAM.z }
    eq(rep(1, { id = 7, by = 'me', cause = 'weapon' }), 'reach', '6. a shot from 401 m: reach')
    eq(rep(1, { id = 7, by = 'other' }), 'reach', '6. a bystander 401 m off: reach')
    e.pos = { x = CAM.x, y = CAM.y, z = CAM.z + 401.0 }
    eq(rep(1, { id = 7, by = 'me', cause = 'weapon' }), 'reach', '6. 401 m straight up: reach is 3D')
    e.pos = { x = CAM.x + 20.0, y = CAM.y, z = CAM.z }
    eq(rep(1, { id = 7, by = 'me', cause = 'vehicle' }), 'down', 'a ram from 20 m: down')
    eq(rep(1, { id = 7, by = 'me', cause = 'weapon' }), 'duplicate', '7. a camera already down: duplicate')
    local refused = m.flick.refused
    ok(refused.reach == 5 and refused.duplicate == 1, 'each refusal counted on the match, by reason',
        ('reach %s, duplicate %s'):format(tostring(refused.reach), tostring(refused.duplicate)))
end

describe('the door: the net event is the door, and it never reads dev mode')
do
    reset()
    local m = newMatch(1)
    player(1, m, 'A', CAM.x + 5.0, CAM.y)
    gameMs = gameMs + 1000
    roster[1].posAt = gameMs
    fire(BR.Net.FLICK_REPORT, 1, { id = 7, by = 'me', cause = 'weapon' })
    ok(m.flick and m.flick.down[7] ~= nil, 'FLICK_REPORT reaches the door')
    local src = readFile(ROOT .. 'br_core/server/flick.lua') or ''
    local code = src:gsub('%-%-[^\n]*', '')
    ok(not code:find('devMode', 1, true) and not code:find('BR.Dev.on', 1, true),
        'server/flick.lua reads no dev mode')
end

-- =========================================================================
-- PART C -- the decision and the credit
-- =========================================================================

describe('the credit: 2 Volts a camera, 30 a match; the 16th still goes down and pays 0')
do
    reset()
    local m = newMatch(1)
    local e = player(1, m, 'A', 300.0, -5000.0)
    for i = 1, 15 do
        eq(rep(1, { id = 100 + i, by = 'me', cause = 'weapon' }), 'down', ('camera %d down'):format(100 + i))
    end
    eq(e.voltsPickedUp, 30, 'fifteen cameras: 30 Volts found')
    eq(rep(1, { id = 116, by = 'me', cause = 'weapon' }), 'down', 'the 16th goes down')
    eq(e.voltsPickedUp, 30, 'and pays nothing')
    eq(m.flick.down[116].by, 1, 'credited all the same')
    eq(m.flick.paid['license:1'], 30, 'the account\'s 30 on the match')
    local line = logs[#logs] or ''
    ok(line:find('camera 116 down (weapon) by p1 (1), +0 Volts (30/30) in match 1', 1, true) ~= nil,
        'one console line says so', line)
end

describe('the credit: the cap is the account\'s, across a leave and a rejoin')
do
    reset()
    local m = newMatch(1)
    local e = player(1, m, 'A', 300.0, -5000.0)
    for i = 1, 10 do rep(1, { id = 100 + i, by = 'me', cause = 'weapon' }) end
    eq(e.voltsPickedUp, 20, 'ten cameras: 20')
    -- Out of the match (BR.Match.resetPlayer zeroes the counter, the sealed
    -- row carries the 20), and back in on a reconnect: a new server id and a
    -- new roster entry, the same account.
    roster[1] = nil
    fire('playerDropped', 1)
    e = player(11, m, 'A', 300.0, -5000.0)
    e.license = 'license:1'
    for i = 11, 20 do rep(11, { id = 100 + i, by = 'me', cause = 'weapon' }) end
    eq(e.voltsPickedUp, 10, 'back in: only the 10 left of the 30')
    eq(m.flick.paid['license:1'], 30, 'and the account is at the cap')
end

describe('the credit: a bystander\'s other, then the shooter\'s me, inside and outside the window')
do
    reset()
    local m = newMatch(1)
    local shooter = player(1, m, 'A', CAM.x + 50.0, CAM.y)
    player(2, m, 'B', CAM.x + 80.0, CAM.y)
    eq(rep(2, { id = 7, by = 'other', cause = 'weapon' }), 'down', 'the bystander\'s report downs it')
    eq(m.flick.down[7].by, nil, 'with nobody credited')
    gameMs = gameMs + 200
    shooter.posAt = gameMs
    eq(F.report(1, { id = 7, by = 'me', cause = 'weapon' }, gameMs), 'credit',
        '200 ms later the shooter\'s me is the credit')
    eq(shooter.voltsPickedUp, 2, 'and pays them 2')
    eq(m.flick.down[7].by, 1, 'credited to them')

    reset()
    m = newMatch(1)
    shooter = player(1, m, 'A', CAM.x + 50.0, CAM.y)
    player(2, m, 'B', CAM.x + 80.0, CAM.y)
    rep(2, { id = 7, by = 'other' })
    gameMs = gameMs + FC.report.creditWindowMs + 100
    shooter.posAt = gameMs
    eq(F.report(1, { id = 7, by = 'me', cause = 'weapon' }, gameMs), 'duplicate',
        'past the credit window: a duplicate')
    eq(shooter.voltsPickedUp, 0, 'and nobody is paid')

    reset()
    m = newMatch(1)
    local a = player(1, m, 'A', CAM.x + 50.0, CAM.y)
    local b = player(2, m, 'B', CAM.x + 60.0, CAM.y)
    rep(1, { id = 7, by = 'me', cause = 'weapon' })
    gameMs = gameMs + 100
    b.posAt = gameMs
    eq(F.report(2, { id = 7, by = 'me', cause = 'weapon' }, gameMs), 'duplicate', 'two me reports: the second is a duplicate')
    ok(a.voltsPickedUp == 2 and b.voltsPickedUp == 0, 'the first is paid, the second nothing')
end

describe('the credit: a downed reporter downs it and is paid nothing; the dev down pays nothing')
do
    reset()
    local m = newMatch(1)
    local e = player(1, m, 'A', CAM.x + 5.0, CAM.y, BR.PlayerState.DBNO)
    eq(rep(1, { id = 7, by = 'me', cause = 'weapon' }), 'down', 'downed: the camera goes down')
    eq(e.voltsPickedUp, 0, 'and pays nothing')
    eq(m.flick.down[7].by, nil, 'nobody credited')

    reset()
    m = newMatch(1)
    e = player(1, m, 'A', CAM.x + 5.0, CAM.y)
    ok(F.devDown(m, 7, gameMs), 'the dev down takes it down')
    eq(F.devDown(m, 7, gameMs), false, 'once')
    gameMs = gameMs + 100
    e.posAt = gameMs
    eq(F.report(1, { id = 7, by = 'me', cause = 'weapon' }, gameMs), 'duplicate',
        'a me report inside the window after it is no credit')
    eq(e.voltsPickedUp, 0, 'nothing paid')
    ok(m.flick.down[7].dev == true, 'the record says it was the dev tool')
end

describe('the credit: an explosion pays nobody (owner, 2026-10-18)')
do
    reset()
    local m = newMatch(1)
    local e = player(1, m, 'A', CAM.x + 30.0, CAM.y)
    -- The thrower's grenade, heard by the server as it went off beside the
    -- camera, then their own client's report of the camera it took.
    fire('explosionEvent', nil, 1, { posX = CAM.x + 4.0, posY = CAM.y, posZ = CAM.z, explosionType = 0 })
    eq(rep(1, { id = 7, by = 'me', cause = 'weapon' }), 'down', 'the camera goes down')
    eq(e.voltsPickedUp, 0, 'and nobody is paid')
    ok(m.flick.down[7].blast == true, 'the record says an explosion')
    -- Far from the blast, or long after it, a shot pays as ever.
    e.pos = { x = 300.0, y = -5000.0, z = 30.0 }
    fire('explosionEvent', nil, 1, { posX = 300.0, posY = -5000.0, posZ = 30.0, explosionType = 0 })
    gameMs = gameMs + FC.report.blastWindowMs + 100
    e.posAt = gameMs
    eq(F.report(1, { id = 110, by = 'me', cause = 'weapon' }, gameMs), 'down', 'a shot long after a blast')
    eq(e.voltsPickedUp, 2, 'pays')
    fire('explosionEvent', nil, 0, { posX = CAM.x, posY = CAM.y, posZ = CAM.z })
    fire('explosionEvent', nil, 1, { posX = 0 / 0, posY = 0, posZ = 0 })
    ok(#m.flick.blasts <= 2, 'the server\'s own blasts and a malformed one are not noted')
end

describe('the reward: the path to the match\'s one ADD')
do
    -- THE COUNTER IS voltsPickedUp, which the results row carries (a leaver's
    -- sealed row too: it copies the entry), BR.Config.marketPayout adds whole,
    -- and BR.Match.resetPlayer zeroes -- tools/test_roster.lua holds the row
    -- and the reset on the real files; here, the two ends.
    local base = { placement = 4, total = 10, kills = 1, revives = 0 }
    local with = { placement = 4, total = 10, kills = 1, revives = 0, voltsPickedUp = 6 }
    eq(BR.Config.marketPayout(with) - BR.Config.marketPayout(base), 6,
        'marketPayout adds 6 Volts found whole, after the weights')
    local match = readFile(ROOT .. 'br_core/server/match.lua') or ''
    ok(match:find('voltsPickedUp = e.voltsPickedUp or 0', 1, true) ~= nil, 'the results row carries it')
    ok(match:find('e.voltsPickedUp = 0', 1, true) ~= nil, 'and resetPlayer zeroes it')
    local persist = readFile('resources/[fivem-royale]/br_stats/server/persist.lua') or ''
    ok(persist:find('voltsPickedUp', 1, true) ~= nil, 'and br_stats hands it to the payout')
    local flick = (readFile(ROOT .. 'br_core/server/flick.lua') or ''):gsub('%-%-[^\n]*', '')
    ok(not flick:find('statsApply', 1, true) and not flick:find('br:ddb', 1, true)
        and not flick:find('BR.Market.charge', 1, true) and not flick:find('refund', 1, true),
        'server/flick.lua writes no balance of its own')

    reset()
    local m1 = newMatch(1)
    local e = player(1, m1, 'A', CAM.x + 5.0, CAM.y)
    rep(1, { id = 7, by = 'me', cause = 'weapon' })
    local m2 = newMatch(2)
    e.matchId = 2
    eq(m2.flick, nil, 'a new match has no record')
    eq(rep(1, { id = 7, by = 'me', cause = 'weapon' }), 'down', 'every camera is up in it')
    eq(m2.flick.paid['license:1'], 2, 'and its own paid, from nothing')
end

-- =========================================================================
-- PART D -- who is told
-- =========================================================================

describe('who is told: the players near a down, by their view, and nobody farther')
do
    reset()
    local m = newMatch(1)
    player(1, m, 'A', CAM.x + 5.0, CAM.y)
    player(2, m, 'B', CAM.x + FC.showM - 1.0, CAM.y)
    player(3, m, 'B', CAM.x + FC.showM + 1.0, CAM.y)
    player(4, m, 'C', CAM.x + 5000.0, CAM.y, BR.PlayerState.OUT)
    spectating[4] = 2
    player(5, m, 'C', CAM.x + 6000.0, CAM.y)
    rep(1, { id = 7, by = 'me', cause = 'vehicle' })
    local d = lastOf(BR.Net.FLICK_DOWN, 1)
    ok(d and d.matchId == 1 and d.ids[1] == 7 and d.causes[1] == 'vehicle',
        'the reporter is sent it, with its cause')
    ok(heldBy(2)[7], 'a player 499 m off is sent it')
    ok(not heldBy(3)[7], 'a player 501 m off is not')
    ok(heldBy(4)[7], 'a spectator, by the player they watch')
    ok(not heldBy(5)[7], 'nobody else')

    -- AND LATER, WHOEVER COMES NEAR: once.
    roster[3].pos = { x = CAM.x + 100.0, y = CAM.y, z = 30.0 }
    jobs['flick.send']()
    ok(heldBy(3)[7], 'the pass sends it to a player who walked into range')
    local n = #eventsOf(BR.Net.FLICK_DOWN, 3)
    jobs['flick.send']()
    jobs['flick.send']()
    eq(#eventsOf(BR.Net.FLICK_DOWN, 3), n, 'and never again')
end

describe('who is told: a Scan squad holds every down, the backlog once as it starts')
do
    reset()
    local m = newMatch(1)
    player(1, m, 'A', CAM.x + 5.0, CAM.y)
    player(2, m, 'S', CAM.x + 9000.0, CAM.y)
    player(3, m, 'S', CAM.x + 9500.0, CAM.y, BR.PlayerState.OUT)
    rep(1, { id = 7, by = 'me', cause = 'weapon' })
    F.devDown(m, 9, gameMs)
    ok(not heldBy(2)[7] and not heldBy(3)[9], 'far away, the squad holds none yet')
    T.startScan(m, 'squad:S', 2, gameMs)
    ok(heldBy(2)[7] and heldBy(2)[9], 'Scan started: every down so far, to the runner')
    ok(heldBy(3)[7] and heldBy(3)[9], 'and to a member who is out')
    local n = #eventsOf(BR.Net.FLICK_DOWN, 2)
    jobs['flick.send']()
    eq(#eventsOf(BR.Net.FLICK_DOWN, 2), n, 'once')
    F.devDown(m, 8, gameMs)
    ok(heldBy(2)[8] and heldBy(3)[8], 'a fresh down reaches the whole squad wherever they are')
end

describe('who is told: the snapshot\'s view, a restarted client, two matches')
do
    reset()
    local m = newMatch(1)
    local e = player(1, m, 'A', CAM.x + 5.0, CAM.y)
    rep(1, { id = 7, by = 'me', cause = 'weapon' })
    F.devDown(m, 8, gameMs)
    local v = F.viewFor(1)
    ok(v and v.matchId == 1 and #v.ids == 1 and v.ids[1] == 7 and v.causes[1] == 'weapon',
        'the view is the near downs, with their causes')
    -- A RESTART: the client lost everything; br:ready's snapshot is its list.
    e.pos = { x = CAM.x + 5000.0, y = CAM.y, z = 30.0 }
    v = F.viewFor(1)
    eq(#v.ids, 0, 'far from every down, the restarted client is handed none')
    e.pos = { x = CAM.x + 5.0, y = CAM.y, z = 30.0 }
    local n = #eventsOf(BR.Net.FLICK_DOWN, 1)
    jobs['flick.send']()
    eq(#eventsOf(BR.Net.FLICK_DOWN, 1), n + 1, 'back near: the pass sends it again, since the view reset what was sent')
    eq(F.viewFor(99), nil, 'nobody in a match: no view')
    flickOn(false)
    eq(F.viewFor(1), nil, 'and none off Season 2')
    flickOn(true)

    -- THE BROADCAST'S SNAPSHOT CARRIES IT (server/broadcast.lua, by text).
    local bc = readFile(ROOT .. 'br_core/server/broadcast.lua') or ''
    ok(bc:find('flick        = BR.Flick and BR.Flick.viewFor and BR.Flick.viewFor(target) or nil', 1, true) ~= nil,
        'BR.Broadcast.snapshot carries BR.Flick.viewFor(target)')

    reset()
    local m1, m2 = newMatch(1), newMatch(2)
    player(1, m1, 'A', CAM.x + 5.0, CAM.y)
    player(2, m2, 'B', CAM.x + 6.0, CAM.y)
    rep(1, { id = 7, by = 'me', cause = 'weapon' })
    ok(heldBy(1)[7] and not heldBy(2)[7], 'a player in another match beside it is sent nothing')
    eq(m2.flick, nil, 'and that match\'s cameras are untouched')
end

-- =========================================================================
-- PART E -- Scan through the cameras
-- =========================================================================

--- Two squads and a solo player around camera 7: A scans; B's 3 stands 40 m
--- from it, B's 4 in a car 120 m off, solo 5 on foot 120 m off, and B's 6 a
--- kilometer away.
local function scanLobby()
    local m = newMatch(1)
    player(1, m, 'A', CAM.x - 2000.0, CAM.y)
    player(2, m, 'A', CAM.x - 2100.0, CAM.y)
    player(3, m, 'B', CAM.x + 40.0, CAM.y)
    player(4, m, 'B', CAM.x, CAM.y + 120.0)
    riders[1004] = true
    player(5, m, nil, CAM.x - 120.0, CAM.y)
    player(6, m, 'B', CAM.x + 1000.0, CAM.y + 1000.0)
    return m
end

--- Every opponent any TERMINAL_SCAN sent this block, as a set.
local function scanned()
    local out = {}
    for _, s in ipairs(eventsOf(BR.Net.TERMINAL_SCAN)) do
        for _, p in ipairs(s.payload.list or {}) do out[p.s] = true end
    end
    return out
end

describe('Scan: only the opponents a live camera sees, on foot and in a vehicle')
do
    reset()
    local m = scanLobby()
    T.startScan(m, 'squad:A', 1, gameMs)
    local d = lastOf(BR.Net.TERMINAL_SCAN, 1)
    ok(d and d.flick == true, 'the push says flick, so the client draws the coverage')
    local got = {}
    for _, p in ipairs(d and d.list or {}) do got[p.s] = true end
    ok(got[3], '40 m from a camera on foot: seen')
    ok(got[4], '120 m in a vehicle: seen')
    ok(not got[5], '120 m on foot: not')
    ok(not got[6], 'a kilometer from every camera: not')
    ok(not got[1] and not got[2], 'never the squad\'s own')

    -- THE PRIVACY PROPERTY, over every payload sent: an opponent outside every
    -- camera's range is never in any list, ping after ping, as they move.
    for step = 1, 10 do
        roster[5].pos = { x = CAM.x - 76.0 - step * 10.0, y = CAM.y, z = 30.0 }
        roster[6].pos = { x = CAM.x + 1000.0 - step, y = CAM.y + 1000.0, z = 30.0 }
        gameMs = gameMs + 2000
        jobs['terminal.scan']()
    end
    local all = scanned()
    ok(not all[5] and not all[6], 'across ten pings, never an opponent no camera sees')
    ok(eventsOf(BR.Net.TERMINAL_SCAN, 3)[1] == nil, 'and no opponent is sent a Scan')

    -- A CAMERA KNOCKED OUT IS OUT OF THE NEXT PING.
    F.devDown(m, 7, gameMs)
    gameMs = gameMs + 2000
    jobs['terminal.scan']()
    d = lastOf(BR.Net.TERMINAL_SCAN, 1)
    eq(#d.list, 0, 'camera 7 down: nobody near it is seen on the next ping')
end

describe('Scan: the seat is asked only between the two ranges; Ghost still hides a squad')
do
    reset()
    local m = scanLobby()
    seatAsks = 0
    F.seen(m, gameMs)
    eq(seatAsks, 2, 'two players stand between 75 and 150 m of a camera: two seat reads')
    reset()
    m = scanLobby()
    m.terminalFx = { scans = {}, bounties = {}, shown = false, ghosts = { ['squad:B'] = { untilAt = gameMs + 60000 } } }
    T.startScan(m, 'squad:A', 1, gameMs)
    local d = lastOf(BR.Net.TERMINAL_SCAN, 1)
    eq(#d.list, 0, 'a squad under Ghost is not in the list, cameras or not')
end

describe('Scan with Flick off is Scan as it was')
do
    reset()
    flickOn(false)
    local m = scanLobby()
    T.startScan(m, 'squad:A', 1, gameMs)
    local d = lastOf(BR.Net.TERMINAL_SCAN, 1)
    local ids = {}
    for _, p in ipairs(d and d.list or {}) do ids[#ids + 1] = p.s end
    eq(table.concat(ids, ','), '3,4,5,6', 'every opponent, as before')
    eq(d.flick, nil, 'and no flick on the push')
    eq(#eventsOf(BR.Net.FLICK_DOWN), 0, 'and no camera list to anybody')
    flickOn(true)
end

describe('Scan through the cameras: the bounty is unchanged')
do
    reset()
    local m = scanLobby()
    T.startScan(m, 'squad:A', 1, gameMs)
    T.startBounty(m, 1, gameMs)
    local b = lastOf(BR.Net.TERMINAL_BOUNTY, 6)
    ok(b and #b.list == 1 and b.list[1].s == 1, 'the runner\'s bounty is on every opponent\'s map, cameras or not')
end

describe('Scan with Flick on and no camera file: nobody is seen')
do
    reset()
    local m = scanLobby()
    local real = BR.Flick
    BR.Flick = nil
    T.startScan(m, 'squad:A', 1, gameMs)
    BR.Flick = real
    local d = lastOf(BR.Net.TERMINAL_SCAN, 1)
    ok(d and d.flick == true and #d.list == 0, 'a camera file that failed to load never widens Scan')
end

-- =========================================================================
-- PART F -- the dev command, and the wiring
-- =========================================================================

describe('the dev command: list, down, reset')
do
    reset()
    local m = newMatch(1)
    player(1, m, 'A', CAM.x + 5.0, CAM.y)
    local function sv(src, line)
        local args = {}
        for w in line:gmatch('%S+') do args[#args + 1] = w end
        commands.brflicksv(src, args, 'brflicksv ' .. line)
        return lastOf(BR.Net.FLICK_DEV, src) or logs[#logs] or ''
    end
    local said = sv(1, 'down 7')
    ok(said:find('camera 7 is down', 1, true) ~= nil and m.flick.down[7] and not m.flick.down[7].by,
        '`brflick down 7`: down, nobody credited', said)
    eq(roster[1].voltsPickedUp, 0, 'nothing paid')
    said = sv(1, 'list')
    ok(said:find('down (weapon 0, vehicle 0, explosion 0, dev 1)', 1, true) ~= nil, '`brflick list` counts it', said)
    said = sv(1, 'reset')
    eq(m.flick, nil, '`brflick reset`: every camera up again')
    local r = lastOf(BR.Net.FLICK_DOWN, 1)
    ok(r and r.reset == true and r.matchId == 1, 'and every client in the match told to lift its hides')
    said = sv(0, 'down 8 1')
    ok(m.flick and m.flick.down[8], 'from the console, the player id comes last')
    season(1)
    said = sv(1, 'list')
    ok(said:find('Season 2', 1, true) ~= nil, 'Season 1: refused, and why', said)
    season(2)
    ok(BR.Dev ~= nil, 'the dev gate is loaded, and wraps it like every command')
end

describe('the wiring: the season row, the manifest, the copy\'s numbers')
do
    eq(BR.Config.Seasons.features.flick.from, 2, 'Flick is Season 2 (the `flick` row)')
    local man = readFile(ROOT .. 'br_core/fxmanifest.lua') or ''
    local shared = man:match('shared_scripts%s*(%b{})') or ''
    local server = man:match('server_scripts%s*(%b{})') or ''
    local client = man:match('client_scripts%s*(%b{})') or ''
    for _, f in ipairs({ '@br_lib/config/flick.lua', '@br_lib/config/flick_cameras.lua',
                         '@br_lib/shared/flick_solve.lua' }) do
        ok(shared:find("'" .. f .. "'", 1, true) ~= nil, 'shared_scripts lists ' .. f)
    end
    local fxAt = server:find("'server/terminalfx.lua'", 1, true)
    local fAt = server:find("'server/flick.lua'", 1, true)
    ok(fxAt and fAt and fAt > fxAt, 'server/flick.lua loads after server/terminalfx.lua')
    local cfxAt = client:find("'client/terminalfx.lua'", 1, true)
    local cfAt = client:find("'client/flick.lua'", 1, true)
    ok(cfxAt and cfAt and cfAt > cfxAt, 'client/flick.lua loads after client/terminalfx.lua')
    -- THE FIXTURE IS THIS SUITE'S; the registry the game reads is the real one.
    ok(#REAL_CAMERAS >= 250, 'the real registry holds the cameras', #REAL_CAMERAS)
end

FC.cameras = REAL_CAMERAS

-- ------------------------------------------------------------------ report --

realPrint(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
