-- Unit tests for the data center's main gate (#420), the server and the shared
-- rules: three lanes that open from their readers (docs/dcgate.md).
--
-- This file stands up the REAL br_lib/shared/dcgate_solve.lua, the real
-- generated registry (br_lib/config/dcgate_parts.lua) and the real
-- br_core/server/dcgate.lua over a stubbed roster, scheduler, match and OneSync
-- vehicle pool, and:
--
--   PART A  the solve: the pose and its ease, a fold turned back, the lead's
--           turn and the bi-fold's counter-rotation (the follower folds flat
--           against its lead at 90, at every angle on the way), the ratio, the
--           arm's rotation, the reader a player is at, the lane's box at its
--           edges, "near".
--   PART B  the registry: three lanes of four leads, four followers and an
--           arm; every follower where its lead's knuckle puts it; each lane's
--           box holding its gates, their folds and its arm, apart from its
--           neighbors, with both readers outside it; the sources' hashes.
--   PART C  the door, one refusal at a time in its order, and a press that
--           opens a lane: the whole match told, nobody else.
--   PART D  the clock: 20 s, then shut; held by a player standing or downed,
--           by a vehicle of the match's bucket at the box's grown edge, by
--           nobody else; a lane folding shut on somebody opening again and
--           closing the moment it is clear; the vehicle pool read only when a
--           lane is due; two matches apart; Season 1 and a match not played.
--   PART E  the snapshot's view.
--   PART F  the dev command, and the wiring the other files make, by text.
--
-- The client is tools/test_dcgate_client.lua's.
--
-- Run via tools/verify.sh, or directly:  lua tools/test_dcgate.lua

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

local function near(got, want, tol, name)
    ok(type(got) == 'number' and math.abs(got - want) <= tol, name,
        ('got %s, want %s +- %s'):format(tostring(got), tostring(want), tostring(tol)))
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
    'br_lib/shared/season.lua',
    'br_lib/config/seasons.lua',
    'br_lib/config/dcgate.lua',
    'br_lib/config/dcgate_parts.lua',
    'br_lib/shared/dcgate_solve.lua',
})

local GC = BR.Config.DcGate
local GS = BR.DcGateSolve
local P = GC.parts
BR.Season.strict = true

local function season(n)
    BR.Season.boot(function(name)
        return name == 'br_season' and tostring(n) or ''
    end, function() end)
end
season(2)

--- The gate off or on at Season 2, by its row: the season gate's own answer.
local GATE_FROM = BR.Config.Seasons.features.dcgate.from
local function gateOn(on)
    BR.Config.Seasons.features.dcgate.from = on and GATE_FROM or (BR.Config.Seasons.latest + 1)
end

-- ---------------------------------------------------------------- stubs ---

local jobs, handlers = {}, {}
local sent = {}          -- TriggerClientEvent: { event, src, payload }

BR.Sched = { every = function(ms, name, fn) jobs[name] = { ms = ms, fn = fn } end }
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

-- THE ONESYNC POOL: every vehicle the server knows, its bucket and where it is.
local vehicles = {}      -- [handle] = { x, y, z, bucket }
local poolReads = 0
function GetAllVehicles()
    poolReads = poolReads + 1
    local out = {}
    for h in pairs(vehicles) do out[#out + 1] = h end
    table.sort(out)
    return out
end
function GetEntityRoutingBucket(h) return vehicles[h] and vehicles[h].bucket or 0 end
local coordsRead = {}    -- [handle] = how many times its position was read
function GetEntityCoords(h)
    coordsRead[h] = (coordsRead[h] or 0) + 1
    local v = vehicles[h]
    return v and { x = v.x, y = v.y, z = v.z } or { x = 0.0, y = 0.0, z = 0.0 }
end

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
}
BR.Server = {
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

loadAll({ 'br_core/server/dcgate.lua' })

local G = BR.DcGate

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

-- The places, off the real registry.
local LANE = GS.byLane(P)
local R = {}             -- [id] = the reader's index
for i, r in ipairs(P.readers) do R[r.id] = i end
local IN2 = P.readers[R['gate.lane2.reader_in']]
local OUT2 = P.readers[R['gate.lane2.reader_out']]
local BOX2 = LANE[2].box
--- A ped stands about a meter over the grade.
local PED_Z = BOX2.zLow + 1.0

local function newMatch(id, state)
    local m = { id = id, seq = id, bucket = 1000 + id, state = state or BR.MatchState.PLAYING }
    matches[id] = m
    return m
end

local function player(src, m, x, y, state, z)
    roster[src] = {
        src = src, name = 'p' .. src, state = state or BR.PlayerState.ALIVE,
        matchId = m and m.id or nil,
        pos = x and { x = x, y = y, z = z or PED_Z } or nil, posAt = gameMs,
    }
    return roster[src]
end

--- Every sample fresh again: the roster's 4 Hz pass.
local function sample()
    for _, e in pairs(roster) do e.posAt = gameMs end
end

local function reset()
    sent, logs = {}, {}
    roster, matches, vehicles = {}, {}, {}
    poolReads = 0
    gateOn(true)
    season(2)
    gameMs = gameMs + 100000
    for s = 1, 40 do fire('playerDropped', s) end
end

--- One press, as `src` sends it, a second and a half after the last.
local function press(src, d)
    gameMs = gameMs + 1500
    sample()
    return G.use(src, d, gameMs)
end

--- Time moves on, the samples with it, and the pass runs.
local function after(ms)
    gameMs = gameMs + ms
    sample()
    G.pass(gameMs)
end

local function opens(m)
    return lastOf(BR.Net.DCGATE_STATE) and lastOf(BR.Net.DCGATE_STATE).open or nil
end

-- =========================================================================
-- PART A -- the solve
-- =========================================================================

describe('the solve: the pose, its ease, and a fold turned back')
do
    eq(GS.ease(0), 0.0, 'ease 0 is 0')
    eq(GS.ease(1), 1.0, 'ease 1 is 1')
    eq(GS.ease(-3), 0.0, 'and clamped below')
    eq(GS.ease(9), 1.0, 'and above')
    near(GS.ease(0.5), 0.5, 1e-9, 'halfway is halfway')
    local up, prev = true, -1
    for i = 0, 100 do
        local v = GS.ease(i / 100)
        if v < prev then up = false end
        prev = v
    end
    ok(up, 'and it only ever rises')
    ok(GS.ease(0.01) < 0.01 and GS.ease(0.99) > 0.99, 'flat at both ends: it starts and stops gently')
    eq(GS.step(0.0, 1.0, 2000, 4000), 0.5, 'half the fold time is half the pose')
    eq(GS.step(0.9, 1.0, 2000, 4000), 1.0, 'and never past the target')
    eq(GS.step(0.5, 0.0, 1000, 4000), 0.25, 'back down at the same rate')
    eq(GS.step(0.5, 0.5, 1000, 4000), 0.5, 'at the target: still')
    eq(GS.step(0.3, 1.0, 0, 4000), 0.3, 'no time, no move')
    -- A FOLD TURNED BACK RUNS BACK FROM WHERE IT IS: the angle is the pose's.
    local pose, worst, last = 0.0, 0.0, GS.leadTurn(1, 0.0, 90.0)
    for i = 1, 400 do
        pose = GS.step(pose, i <= 150 and 1.0 or 0.0, 16, 4000)
        local a = GS.leadTurn(1, pose, 90.0)
        worst = math.max(worst, math.abs(a - last))
        last = a
    end
    ok(worst < 0.6, 'turned back at 60%, the lead never jumps more than a frame\'s turn', worst)
    eq(pose, 0.0, 'and it ends shut')
end

describe('the solve: the lead\'s turn, the bi-fold, the ratio and the arm')
do
    eq(GS.leadTurn(1, 1.0, 90.0), 90.0, 'a +1 lead open: +90')
    eq(GS.leadTurn(-1, 1.0, 90.0), -90.0, 'a -1 lead open: -90')
    eq(GS.leadTurn(1, 0.0, 90.0), 0.0, 'shut: 0')
    near(GS.wrap180(350.0), -10.0, 1e-9, 'wrap: 350 is -10')
    near(GS.wrap180(-190.0), 170.0, 1e-9, 'wrap: -190 is 170')
    near(GS.followerYaw(45.0, 0.0, -2), -90.0, 1e-9, 'a lead turned 45: its follower -90 on it')
    near(GS.followerYaw(5.0, 355.0, -2), -20.0, 1e-9, 'across north: the turn is 10, not 350')
    near(GS.followerYaw(180.0, 270.0, -2), 180.0, 1e-9, 'a -90 lead (heading 270 to 180): +180 on it')
    -- THE BI-FOLD, at every angle: the follower's own heading is its lead's
    -- placed heading turned the other way by as much (it mirrors the lead about
    -- the gate line), and at 90 the two leaves are flat against each other.
    local worst = 0.0
    for _, sense in ipairs({ 1, -1 }) do
        for deg = 0, 90, 5 do
            local placed = 270.0
            local leadNow = placed + sense * deg
            local own = leadNow + GS.followerYaw(leadNow, placed, -2)
            worst = math.max(worst, math.abs(GS.wrap180(own - (placed - sense * deg))))
        end
    end
    near(worst, 0.0, 1e-9, 'the follower mirrors its lead about the gate line, 0-90, both sides')
    near(math.abs(GS.wrap180((270.0 + 90.0) - (270.0 - 90.0))), 180.0, 1e-9,
        'and at 90 the pair is folded flat, face to face')
    eq(GS.ratio(90.0, 90.0, 1), 1.0, 'ratio: 90 of 90 is 1')
    eq(GS.ratio(-45.0, 90.0, 1), -0.5, 'a -45 turn is -0.5')
    eq(GS.ratio(45.0, 90.0, -1), -0.5, 'and the sign flips it')
    eq(GS.ratio(120.0, 90.0, 1), 1.0, 'kept in -1..1')
    local x, y, z = GS.armRotation({ h = 270.0, axis = 'y', sense = -1 }, 85.0)
    ok(x == 0.0 and y == -85.0 and z == 270.0, 'the arm: about local +y by -raise, under its heading',
        ('%s %s %s'):format(x, y, z))
    x, y, z = GS.armRotation({ h = 10.0, axis = 'x', sense = 1 }, 30.0)
    ok(x == 30.0 and y == 0.0 and z == 10.0, 'an arm about local x: a pitch')
    eq(GS.doorName('gate.lane1.outer.lead_l'), 'brdc_door_gate.lane1.outer.lead_l',
        'a door\'s name is the pack\'s (its DOOR_LOCKS): one door between them, not two')
end

describe('the solve: the reader a player is at, the box at its edges, near')
do
    local readers = { { x = 0.0, y = 0.0, z = 10.0 }, { x = 5.0, y = 0.0, z = 10.0 } }
    eq(GS.readerAt(readers, 0.0, 2.9, 10.0, 3.0, 2.5), 1, '2.9 m flat: at it')
    eq(GS.readerAt(readers, 0.0, 3.1, 10.0, 3.0, 2.5), nil, '3.1 m: not')
    eq(GS.readerAt(readers, 0.0, 1.0, 12.6, 3.0, 2.5), nil, '2.6 m above it: not')
    eq(GS.readerAt(readers, 3.0, 0.0, 10.0, 3.0, 2.5), 2, 'between two: the nearer')
    eq(GS.readerAt(readers, 0 / 0, 0.0, 10.0, 3.0, 2.5), nil, 'a position that is no number: nobody')
    local box = { x = 0.0, y = 0.0, ux = 0.0, uy = 1.0, halfLength = 10.0, halfWidth = 2.0, zLow = 0.0, zHigh = 1.0 }
    ok(GS.inBox(box, 1.9, 9.9, 0.5, 0.0, 1.0, 4.0), 'inside its corner')
    ok(not GS.inBox(box, 2.1, 0.0, 0.5, 0.0, 1.0, 4.0), 'past its width (the box runs along y here)')
    ok(not GS.inBox(box, 0.0, 10.1, 0.5, 0.0, 1.0, 4.0), 'past its length')
    ok(GS.inBox(box, 0.0, 12.4, 0.5, 2.5, 1.0, 4.0), 'grown 2.5: 2.4 past its end is in')
    ok(not GS.inBox(box, 0.0, 12.6, 0.5, 2.5, 1.0, 4.0), 'and 2.6 is not')
    ok(GS.inBox(box, 0.0, 0.0, -0.9, 0.0, 1.0, 4.0) and not GS.inBox(box, 0.0, 0.0, -1.1, 0.0, 1.0, 4.0),
        'a meter under its grade, not more')
    ok(GS.inBox(box, 0.0, 0.0, 4.9, 0.0, 1.0, 4.0) and not GS.inBox(box, 0.0, 0.0, 5.1, 0.0, 1.0, 4.0),
        'four over its highest grade, not more: a helicopter over the gate holds nothing')
    ok(GS.near(P, P.center.x + P.radius + 9.0, P.center.y, 10.0), 'near: within its radius and the extra')
    ok(not GS.near(P, P.center.x + P.radius + 11.0, P.center.y, 10.0), 'and not past them')
end

-- =========================================================================
-- PART B -- the registry
-- =========================================================================

describe('the registry: three lanes, each four leads, four followers and an arm')
do
    eq(#P.lanes, 3, 'three lanes')
    local ids, models = {}, {}
    for i, L in ipairs(P.lanes) do
        eq(L.lane, i, 'lane ' .. i .. ' in its place')
        eq(#L.leads, 4, 'lane ' .. i .. ': four leads (two a gate)')
        eq(#L.follows, 4, 'lane ' .. i .. ': four followers')
        ok(L.arm and L.arm.model == 'brdc_croparm_arm', 'lane ' .. i .. ': its crash arm')
        for _, d in ipairs(L.leads) do
            ids[d.id] = true
            models[d.model] = true
            eq(d.sense, d.model == 'brdc_bifold_lead_l' and 1 or -1, d.id .. ' opens the kit\'s way')
        end
        for _, f in ipairs(L.follows) do
            ids[f.id] = true
            eq(f.turn, -2, f.id .. ' counter-rotates -2 times its lead')
            local lead = L.leads[f.lead]
            ok(lead and lead.id:gsub('lead', 'follow') == f.id, f.id .. ' rides its own lead', lead and lead.id)
            -- WHERE ITS LEAD'S KNUCKLE PUTS IT, recomputed here, not trusted.
            local r = math.rad(lead.h)
            local wx = lead.x + f.ox * math.cos(r) - f.oy * math.sin(r)
            local wy = lead.y + f.ox * math.sin(r) + f.oy * math.cos(r)
            ok(math.abs(wx - f.x) < 0.02 and math.abs(wy - f.y) < 0.02 and f.h == lead.h,
                f.id .. ' stands at its lead\'s knuckle, at its heading')
        end
        ids[L.arm.id] = true
        ok(L.arm.axis == 'y' and L.arm.sense == -1, 'lane ' .. i .. ': the arm rises about local +y by -raise')
    end
    local n = 0
    for _ in pairs(ids) do n = n + 1 end
    eq(n, 27, 'the 24 leaves and 3 arms the gamemode takes over, each once')
    eq(#P.readers, 6, 'six lane readers')
    for i = 1, 3 do
        ok(R['gate.lane' .. i .. '.reader_in'] and R['gate.lane' .. i .. '.reader_out'],
            'lane ' .. i .. ': a reader at each end')
    end
end

describe('the registry: each box holds its gates, their folds and its arm, apart from the others')
do
    local L = GC.lane
    for _, lane in ipairs(P.lanes) do
        local b = lane.box
        for _, d in ipairs(lane.leads) do
            ok(GS.inBox(b, d.x, d.y, nil, 0.01, 0, 0), d.id .. '\'s hinge is in the lane\'s box')
            -- The leaf folds 1.065 m to its local +y: the box holds the fold.
            local r = math.rad(d.h)
            local fx, fy = d.x - 1.065 * math.sin(r), d.y + 1.065 * math.cos(r)
            ok(GS.inBox(b, fx, fy, nil, 0.01, 0, 0), d.id .. ' folds inside it')
        end
        -- The arm's pivot stands in its cabinet beside the lane; its beam lies
        -- across the lane along its local +x.
        local ar = math.rad(lane.arm.h)
        ok(not GS.inBox(b, lane.arm.x, lane.arm.y, nil, 0.0, 0, 0)
           and GS.inBox(b, lane.arm.x + 2.0 * math.cos(ar), lane.arm.y + 2.0 * math.sin(ar), nil, 0.0, 0, 0),
            lane.arm.id .. ': its pivot beside the lane, its beam across it, in the box')
        for _, r in ipairs(P.readers) do
            ok(not GS.inBox(b, r.x, r.y, nil, L.pedMarginM, 0, 0),
                ('lane %d: a player at %s is not in the lane'):format(lane.lane, r.id))
        end
        for _, other in ipairs(P.lanes) do
            if other ~= lane then
                local o = other.box
                ok(not GS.inBox(b, o.x, o.y + (o.y > b.y and -o.halfWidth or o.halfWidth) * 0.9, nil,
                    L.pedMarginM, 0, 0), ('lane %d\'s box is clear of lane %d\'s'):format(lane.lane, other.lane))
            end
        end
        ok(lane.box.zHigh - lane.box.zLow < 0.5, 'lane ' .. lane.lane .. ': a gate at grade, its grade within half a meter')
    end
    local src = readFile(ROOT .. 'br_lib/config/dcgate_parts.lua') or ''
    ok(src:find('WRITTEN BY tools/dcgate_parts.py', 1, true) ~= nil, 'the registry says it is generated')
    local _, hashes = src:gsub('%-%- Source: [%w_.]+%.json, sha256 %x+', '')
    eq(hashes, 2, 'and names both sources with their sha256 (the door table and the kit)')
end

-- =========================================================================
-- PART C -- the door, one refusal at a time, in its order
-- =========================================================================

describe('the door: every refusal, in order, silent and counted')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y + 1.0)
    gateOn(false)
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'season', '1. the gate off: refused')
    gateOn(true)
    for _, bad in ipairs({
        { label = 'no table', d = 'x' },
        { label = 'no reader', d = {} },
        { label = 'a reader that is a string', d = { reader = '3' } },
        { label = 'reader 0', d = { reader = 0 } },
        { label = 'reader 7 (there are six)', d = { reader = 7 } },
        { label = 'a fraction', d = { reader = 2.5 } },
    }) do
        eq(press(1, bad.d), 'shape', '2. ' .. bad.label .. ': shape')
    end
    local rd = R['gate.lane2.reader_in']
    gameMs = gameMs + 1500
    sample()
    eq(G.use(1, { reader = rd }, gameMs), 'open', 'a good press opens the lane')
    eq(G.use(1, { reader = rd }, gameMs + GC.use.minIntervalMs - 1), 'rate', '3. inside use.minIntervalMs: rate')
    ok(GC.use.minIntervalMs * 2 <= GC.client.askMs,
        'the server\'s interval is at most half the client\'s, so jitter never drops a retry a second later')
    G.stateOf(m).lanes[2].open = false
    eq(press(1, { reader = rd }), 'open', 'and a second and a half later it is taken again')
    G.stateOf(m).lanes[2].open = false
    gameMs = gameMs + GC.client.askMs - 250
    sample()
    eq(G.use(1, { reader = rd }, gameMs), 'open', 'a retry that arrives a quarter second early (jitter): taken')
    G.stateOf(m).lanes[2].open = false

    roster[1].matchId = nil
    eq(press(1, { reader = rd }), 'match', '4. in no match: match')
    roster[1].matchId = 1
    m.state = BR.MatchState.WARMUP
    eq(press(1, { reader = rd }), 'match', '4. a match at warmup: match')
    m.state = BR.MatchState.ENDED
    eq(press(1, { reader = rd }), 'match', '4. a match that ended: match')
    m.state = BR.MatchState.BUS
    eq(press(1, { reader = rd }), 'open', '4. the bus still flying (this player jumped early and landed): taken')
    G.stateOf(m).lanes[2].open = false
    m.state = BR.MatchState.PLAYING

    roster[1].state = BR.PlayerState.DBNO
    eq(press(1, { reader = rd }), 'player', '5. downed: player')
    roster[1].state = BR.PlayerState.OUT
    eq(press(1, { reader = rd }), 'player', '5. out: player')
    roster[1].state = BR.PlayerState.ALIVE

    gameMs = gameMs + 1500
    roster[1].posAt = gameMs - 1500
    eq(G.use(1, { reader = rd }, gameMs), 'reach', '6. a sample 1.5 s old: reach')
    local slack = GC.use.reachSlackM
    player(1, m, IN2.x, IN2.y + GC.readerM + slack + 0.2)
    eq(press(1, { reader = rd }), 'reach', '6. past readerM and the slack, flat: reach')
    player(1, m, IN2.x, IN2.y + GC.readerM + slack - 0.2)
    eq(press(1, { reader = rd }), 'open', 'inside them: taken')
    G.stateOf(m).lanes[2].open = false
    player(1, m, IN2.x, IN2.y, nil, IN2.z + GC.readerZM + slack + 0.3)
    eq(press(1, { reader = rd }), 'reach', '6. on a roof over it: reach')
    player(1, m, IN2.x, IN2.y + 0.5)
    eq(press(1, { reader = R['gate.lane3.reader_out'] }), 'reach',
        '6. naming another lane\'s reader from this one: reach -- the server says where the player is')

    eq(press(1, { reader = rd }), 'open', 'at the reader again: open')
    eq(press(1, { reader = rd }), 'open', '7. ...and again while it is open: refused as `open`')
    local st = G.stateOf(m)
    ok(st.lanes[2].open == true and not st.lanes[1].open and not st.lanes[3].open, 'only lane 2 is open')
    eq(st.refused.season, 1, 'every refusal counted on the match: season')
    eq(st.refused.shape, 6, 'shape')
    eq(st.refused.rate, 1, 'rate')
    eq(st.refused.match, 2, 'match (a press from no match has no match to be counted on)')
    eq(st.refused.player, 2, 'player')
    eq(st.refused.reach, 4, 'reach')
    eq(st.refused.open, 1, 'open')
end

describe('the door: a press opens the whole lane, and the whole match is told')
do
    reset()
    local m = newMatch(1)
    local other = newMatch(2)
    player(1, m, OUT2.x, OUT2.y - 0.5)
    player(2, m, 0.0, 0.0)
    player(3, other, OUT2.x, OUT2.y)
    player(4, nil, OUT2.x, OUT2.y)
    eq(press(1, { reader = R['gate.lane2.reader_out'] }), 'open', 'the reader inside the inner gate opens it too')
    local to = {}
    for _, s in ipairs(eventsOf(BR.Net.DCGATE_STATE)) do to[s.src] = (to[s.src] or 0) + 1 end
    ok(to[1] == 1 and to[2] == 1, 'everyone in the match is told, once: across the map too')
    ok(to[3] == nil and to[4] == nil, 'nobody in another match or in none')
    local p = lastOf(BR.Net.DCGATE_STATE, 2)
    ok(p and p.matchId == 1 and p.open[1] == false and p.open[2] == true and p.open[3] == false,
        'the payload: the match, and every lane open or shut')
    ok(logs[#logs]:find('lane 2 open by p1 (1) at gate.lane2.reader_out in match 1', 1, true) ~= nil,
        'one console line', logs[#logs])
    local before = #sent
    eq(press(3, { reader = R['gate.lane2.reader_out'] }), 'open', 'the other match\'s lane 2 is its own')
    eq(#sent - before, 1, 'and only its own player hears of it')
end

-- =========================================================================
-- PART D -- the clock
-- =========================================================================

describe('the clock: 20 seconds, then it folds shut; the vehicle pool read only then')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    eq(GC.openMs, 20000, 'the owner\'s 20 seconds')
    for _ = 1, 5 do after(500) end
    eq(poolReads, 0, 'every lane shut: the pass reads nothing')
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'open', 'opened')
    local s = G.stateOf(m).lanes[2]
    local opened = s.at
    after(19000)
    ok(s.open, '19 s on: still open')
    eq(poolReads, 0, 'and the pool not read while it is inside its time')
    gameMs = opened + 19999
    G.pass(gameMs)
    ok(s.open, '19.999 s: still open')
    gameMs = opened + 20000
    sample()
    G.pass(gameMs)
    ok(not s.open, '20 s, nobody in it: folding shut')
    eq(poolReads, 1, 'the pool read once, for that')
    local p = lastOf(BR.Net.DCGATE_STATE, 1)
    ok(p and p.open[2] == false, 'and the match is told')
    ok(logs[#logs]:find('lane 2 folding shut in match 1 (clear, open 20.0 s)', 1, true) ~= nil, logs[#logs])
    after(GC.foldMs)
    local reads = poolReads
    for _ = 1, 4 do after(500) end
    eq(poolReads, reads, 'shut and still: not looked at again')
end

describe('the clock: a player in the lane holds it -- standing or downed, not out, not stale')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    player(2, m, BOX2.x, BOX2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    local s = G.stateOf(m).lanes[2]
    after(GC.openMs)
    ok(s.open, 'a player standing in the trap: still open at 20 s')
    after(30000)
    ok(s.open, 'and 30 s later')
    roster[2].state = BR.PlayerState.DBNO
    after(500)
    ok(s.open, 'downed in it: still held (a leaf does not fold onto a downed player)')
    roster[2].state = BR.PlayerState.OUT
    after(500)
    ok(not s.open, 'out: nobody holds it, it folds')
    G.open(m, 2, gameMs, 'again')
    roster[2].state = BR.PlayerState.ALIVE
    after(GC.openMs)
    ok(s.open, 'standing again: held')
    gameMs = gameMs + 500
    roster[2].posAt = gameMs - GC.lane.sampleMaxAgeMs - 1
    roster[1].posAt = gameMs
    G.pass(gameMs)
    ok(not s.open, 'a sample older than lane.sampleMaxAgeMs holds nothing')
    G.open(m, 2, gameMs, 'again')
    roster[2].pos = { x = BOX2.x + BOX2.halfLength + GC.lane.pedMarginM - 0.1, y = BOX2.y, z = PED_Z }
    after(GC.openMs)
    ok(s.open, 'a player inside the box\'s grown end: held')
    roster[2].pos.x = BOX2.x + BOX2.halfLength + GC.lane.pedMarginM + 0.1
    after(500)
    ok(not s.open, 'just past it: not')
    G.open(m, 2, gameMs, 'again')
    roster[2].pos = { x = BOX2.x, y = BOX2.y, z = BOX2.zHigh + GC.lane.aboveM + 1.0 }
    after(GC.openMs)
    ok(not s.open, 'a player over the lane (a roof, a helicopter): not in it')
    local held = LANE[1].box
    G.open(m, 2, gameMs, 'again')
    roster[2].pos = { x = held.x, y = held.y, z = PED_Z }
    after(GC.openMs)
    ok(not s.open, 'a player in lane 1 does not hold lane 2')
end

describe('the clock: a vehicle in the lane holds it -- this match\'s bucket only, by its center grown')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    local s = G.stateOf(m).lanes[2]
    -- Parked under the arm, nobody in it.
    vehicles[501] = { x = LANE[2].arm.x, y = BOX2.y, z = BOX2.zLow + 0.6, bucket = m.bucket }
    after(GC.openMs)
    ok(s.open, 'an empty car under the arm: still open')
    vehicles[501].bucket = 7777
    coordsRead = {}
    after(500)
    ok(not s.open, 'the same car in another routing bucket (another match, the lobby): not this lane\'s')
    eq(coordsRead[501], nil, 'and its position is not even read: only the match\'s own bucket\'s are')
    G.open(m, 2, gameMs, 'again')
    local edge = BOX2.x + BOX2.halfLength
    vehicles[501] = { x = edge + GC.lane.vehicleMarginM - 0.1, y = BOX2.y, z = BOX2.zLow + 0.6, bucket = m.bucket }
    after(GC.openMs)
    ok(s.open, ('a car whose center is %.1f m past the box (its bumper under a leaf): held'):format(GC.lane.vehicleMarginM - 0.1))
    vehicles[501].x = edge + GC.lane.vehicleMarginM + 0.1
    after(500)
    ok(not s.open, 'farther: not')
    -- A car waiting at the in-reader is not in the lane.
    G.open(m, 2, gameMs, 'again')
    vehicles[501] = { x = IN2.x + 0.5, y = BOX2.y - 1.0, z = BOX2.zLow + 0.6, bucket = m.bucket }
    after(GC.openMs)
    ok(not s.open, 'a car waiting at the reader outside the arm does not hold it')
    eq(GC.lane.vehicleMarginM, 2.5, 'a car\'s half-length')
    -- One waiting at the out-reader, centered in the lane with its driver's
    -- window at the pedestal, has its nose under the inner gate's fold.
    G.open(m, 2, gameMs, 'again')
    vehicles[501] = { x = OUT2.x - 0.2, y = BOX2.y, z = BOX2.zLow + 0.6, bucket = m.bucket }
    after(GC.openMs)
    ok(s.open, 'a car waiting at the reader inside the inner gate, its nose in the inner gate\'s fold: held')
    -- BESIDE THE LANE: the leaves fold inside the posts.
    vehicles[501] = nil
    after(500)
    G.open(m, 2, gameMs, 'again')
    local b1 = LANE[1].box
    local island = ((b1.y + b1.halfWidth) + (BOX2.y - BOX2.halfWidth)) / 2.0
    vehicles[501] = { x = BOX2.x, y = island, z = BOX2.zLow + 0.6, bucket = m.bucket }
    after(GC.openMs)
    ok(not s.open, 'a car parked on the island between lanes 1 and 2 does not hold lane 2')
    G.open(m, 1, gameMs, 'again')
    after(GC.openMs)
    ok(not G.stateOf(m).lanes[1].open, 'nor lane 1')
    G.open(m, 2, gameMs, 'again')
    local side = BOX2.y - BOX2.halfWidth
    vehicles[501] = { x = BOX2.x, y = side - GC.lane.vehicleSideM + 0.1, z = BOX2.zLow + 0.6, bucket = m.bucket }
    after(GC.openMs)
    ok(s.open, ('a car whose center is %.1f m beside the lane (its side under a leaf): held'):format(GC.lane.vehicleSideM - 0.1))
    vehicles[501].y = side - GC.lane.vehicleSideM - 0.1
    after(500)
    ok(not s.open, 'farther: not')
    eq(GC.lane.vehicleSideM, 1.0, 'a car\'s half-width')
end

describe('the clock: a lane folding shut on somebody opens again, and shuts the moment it is clear')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    local s = G.stateOf(m).lanes[2]
    after(GC.openMs)
    ok(not s.open, 'folding shut')
    vehicles[9] = { x = BOX2.x, y = BOX2.y, z = BOX2.zLow + 0.6, bucket = m.bucket }
    after(1000)
    ok(s.open, 'a car drives in a second into the fold: open again')
    local p = lastOf(BR.Net.DCGATE_STATE, 1)
    ok(p and p.open[2] == true, 'and the match is told')
    ok(logs[#logs]:find('lane 2 open again in match 1: a vehicle in it', 1, true) ~= nil, logs[#logs])
    after(10000)
    ok(s.open, 'held while it is there')
    vehicles[9] = nil
    after(500)
    ok(not s.open, 'gone: shut on the next pass, no new 20 seconds')
    after(GC.foldMs + 1)
    vehicles[9] = { x = BOX2.x, y = BOX2.y, z = BOX2.zLow + 0.6, bucket = m.bucket }
    after(500)
    ok(not s.open, 'a car that drives up to a gate already shut opens nothing')
    vehicles[9] = nil
    G.open(m, 2, gameMs, 'again')
    after(GC.openMs)
    ok(not s.open, 'folding shut once more')
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'open', 'a press while it folds shut: open again')
    ok(s.open, 'and it is')
end

describe('the clock: two matches apart; Season 1; a match not being played')
do
    reset()
    local a, b = newMatch(1), newMatch(2)
    player(1, a, IN2.x, IN2.y)
    player(2, b, IN2.x, IN2.y)
    player(3, b, BOX2.x, BOX2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    press(2, { reader = R['gate.lane2.reader_in'] })
    after(GC.openMs)
    ok(not G.stateOf(a).lanes[2].open, 'match 1\'s lane 2, empty: shut')
    ok(G.stateOf(b).lanes[2].open, 'match 2\'s, with its own player in it: held -- the buckets do not mix')
    roster[3].matchId = 1
    after(500)
    ok(G.stateOf(a).lanes[2].open, 'that player moved to match 1 (same spot): now match 1\'s lane is held')
    ok(not G.stateOf(b).lanes[2].open, 'and match 2\'s is not')

    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    m.state = BR.MatchState.ENDED
    after(GC.openMs + 5000)
    ok(G.stateOf(m).lanes[2].open, 'a match that ended is not looked at (it is going away)')
    m.state = BR.MatchState.BUS
    after(500)
    ok(not G.stateOf(m).lanes[2].open, 'the bus still flying: the clock runs, and the lane folds shut')
    m.state = BR.MatchState.PLAYING
    gateOn(false)
    after(500)
    eq(m.dcgate, nil, 'Season 1: the match forgets its lanes (every client shut them itself)')
    gateOn(true)
end

-- =========================================================================
-- PART E -- the snapshot's view
-- =========================================================================

describe('the snapshot: this player\'s match\'s lanes, nothing outside one or off Season 2')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    player(2, nil, 0.0, 0.0)
    local v = G.viewFor(1)
    ok(v and v.matchId == 1 and v.open[1] == false and v.open[2] == false and v.open[3] == false,
        'in a match with no lane ever opened: every lane shut')
    eq(m.dcgate, nil, 'and asking makes no state')
    press(1, { reader = R['gate.lane2.reader_in'] })
    v = G.viewFor(1)
    ok(v and v.open[2] == true, 'after a press: lane 2 open')
    eq(G.viewFor(2), nil, 'in no match: nil')
    gateOn(false)
    eq(G.viewFor(1), nil, 'Season 1: nil')
    gateOn(true)
    local bc = readFile(ROOT .. 'br_core/server/broadcast.lua') or ''
    ok(bc:find('dcgate%s*=%s*BR%.DcGate and BR%.DcGate%.viewFor and BR%.DcGate%.viewFor%(target%)') ~= nil,
        'BR.Broadcast.snapshot carries it as `dcgate`')
end

-- =========================================================================
-- PART F -- the dev command, and the wiring
-- =========================================================================

describe('the dev command: list, open, close')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    local function sv(src, line)
        local args = {}
        for w in line:gmatch('%S+') do args[#args + 1] = w end
        commands.brgatesv(src, args, 'brgatesv ' .. line)
        return lastOf(BR.Net.DCGATE_DEV, src) or logs[#logs] or ''
    end
    local said = sv(1, 'open 3')
    ok(said:find('lane 3 open in match 1', 1, true) and G.stateOf(m).lanes[3].open, '`brgate open 3`', said)
    said = sv(1, 'list')
    ok(said:find('lane 3 open 0.0 s, closes in 20.0 s', 1, true) and said:find('lane 1 shut', 1, true),
        '`brgate list`', said)
    said = sv(1, 'close all')
    ok(said:find('lane 3 folding shut', 1, true) and not G.stateOf(m).lanes[3].open, '`brgate close all`', said)
    said = sv(1, 'open all')
    ok(G.stateOf(m).lanes[1].open and G.stateOf(m).lanes[2].open and G.stateOf(m).lanes[3].open, '`brgate open all`')
    said = sv(1, 'open 9')
    ok(said:find('no lane "9"', 1, true) ~= nil, 'a lane that is not one', said)
    G.stateOf(m).lanes[2].holdUntil = gameMs
    player(2, m, BOX2.x, BOX2.y)
    said = sv(1, 'list')
    ok(said:find('lane 2 open', 1, true) and said:find('held: a player in it', 1, true), 'list says what holds it', said)
    said = sv(0, 'close 1 1')
    ok(not G.stateOf(m).lanes[1].open, 'from the console, the player id comes last')
    m.state = BR.MatchState.WARMUP
    said = sv(1, 'open 1')
    ok(said:find('a match being played', 1, true) ~= nil, 'not while the match is not being played', said)
    m.state = BR.MatchState.BUS
    said = sv(1, 'open 1')
    ok(said:find('lane 1 open in match 1', 1, true) and G.stateOf(m).lanes[1].open, 'the bus still flying: it is', said)
    m.state = BR.MatchState.PLAYING
    season(1)
    said = sv(1, 'list')
    ok(said:find('Season 2', 1, true) ~= nil, 'Season 1: refused, and why', said)
    season(2)
    ok(BR.Dev ~= nil, 'the dev gate is loaded, and wraps it like every command')
end

describe('the wiring: the season row, the manifest, the wire, the numbers')
do
    eq(BR.Config.Seasons.features.dcgate.from, 2, 'the gate is Season 2 (the `dcgate` row)')
    local srv = readFile(ROOT .. 'br_core/server/dcgate.lua') or ''
    ok(srv:find("BR%.Season%.has%('dcgate'%)") ~= nil, 'the server asks BR.Season.has(\'dcgate\')')
    local man = readFile(ROOT .. 'br_core/fxmanifest.lua') or ''
    local shared = man:match('shared_scripts%s*(%b{})') or ''
    local server = man:match('server_scripts%s*(%b{})') or ''
    local client = man:match('client_scripts%s*(%b{})') or ''
    for _, f in ipairs({ '@br_lib/config/dcgate.lua', '@br_lib/config/dcgate_parts.lua',
                         '@br_lib/shared/dcgate_solve.lua' }) do
        ok(shared:find("'" .. f .. "'", 1, true) ~= nil, 'shared_scripts lists ' .. f)
    end
    ok(server:find("'server/dcgate.lua'", 1, true) ~= nil, 'server_scripts lists server/dcgate.lua')
    local kb = client:find("'client/keybinds.lua'", 1, true)
    local st = client:find("'client/state.lua'", 1, true)
    local cg = client:find("'client/dcgate.lua'", 1, true)
    ok(kb and st and cg and cg > kb and cg > st, 'client/dcgate.lua loads after client/keybinds.lua and client/state.lua')
    eq(BR.Net.DCGATE_USE, 'br:dcgate:use', 'the wire: DCGATE_USE')
    eq(BR.Net.DCGATE_STATE, 'br:dcgate:state', 'DCGATE_STATE')
    eq(BR.Net.DCGATE_DEV, 'br:dcgate:dev', 'DCGATE_DEV')
    ok(jobs['dcgate.pass'] and jobs['dcgate.pass'].ms == GC.lane.checkMs, 'the pass runs every lane.checkMs')
    eq(GC.foldDeg, 90.0, 'the kit\'s fold: 0-90')
    ok(GC.armRaiseDeg >= 85.0 and GC.armRaiseDeg <= 90.0, 'and the arm\'s raise: 85-90')
    ok(not srv:gsub('%-%-[^\n]*', ''):find('BR%.Dev%.on'), 'no decision here reads dev mode')
end

-- ------------------------------------------------------------------ report --

realPrint(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
