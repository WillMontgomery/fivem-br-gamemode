-- Unit tests for the data center's main gate (#420), the server and the shared
-- rules: three lanes, each a sally port opened from its readers
-- (docs/dcgate.md).
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
--   PART B2 the zones derived from the parts (the gate lines, the trap, each
--           gate's swing and way, the readers' gates) and who is in them; the
--           sequence, pure, through every transition (inbound, outbound,
--           abandoned, reopened, the poses, the dev's stop); the wire's code;
--           the rotation read back.
--   PART C  the door, one refusal at a time in its order (a press from the
--           trap and a press during a cycle among them), and a press that
--           opens only its reader's gate: the whole match told, nobody else.
--   PART D  the sally port on the server's own samples: inbound on foot,
--           outbound by car, an abandoned first gate, a car parked in a swing,
--           a gate reopening on a car, an empty car left in the trap (the trap
--           holds players only), who holds a gate, a player dropped in
--           the trap, a press at every phase, a match ending mid-cycle, two
--           matches apart, Season 1.
--   PART E  the snapshot's view: each gate's pose, for a late joiner.
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
-- PART B2 -- the zones, the sequence and the wire, pure
-- =========================================================================

local Z = GS.zones(P)
local Z2 = Z[2]
local T = { foldMs = GC.foldMs, closeDelayMs = GC.cycle.closeDelayMs, abandonMs = GC.cycle.abandonMs }

--- A point of lane 2: `a` meters along its box from its middle (toward the
--- inner gate), `c` across it, at a ped's height.
local function at(a, c, z)
    return { x = BOX2.x + BOX2.ux * a - BOX2.uy * c, y = BOX2.y + BOX2.uy * a + BOX2.ux * c, z = z or PED_Z }
end
local function alongOf(x, y) return (x - BOX2.x) * BOX2.ux + (y - BOX2.y) * BOX2.uy end
local function acrossOf(x, y) return -(x - BOX2.x) * BOX2.uy + (y - BOX2.y) * BOX2.ux end

-- The places of lane 2, off its zones.
local A_TRAP = 0.0
local A_OUT_SWING = (Z2.outer.swing.a0 + Z2.outer.swing.a1) / 2.0
local A_OUT_WAY = (Z2.outer.way.a0 + Z2.outer.swing.a0) / 2.0
local A_IN_SWING = (Z2.inner.swing.a0 + Z2.inner.swing.a1) / 2.0
local A_IN_WAY = (Z2.inner.way.a1 + Z2.inner.swing.a1) / 2.0
local A_FAR_OUT, A_FAR_IN = -30.0, 30.0

--- An occupancy, by hand: who is in the trap and each gate's swing and way.
local function occ(t)
    t = t or {}
    return {
        trap = t.trap,
        outer = { swing = t.outerSwing, way = t.outerWay or t.outerSwing },
        inner = { swing = t.innerSwing, way = t.innerWay or t.innerSwing },
    }
end

describe('the zones: derived from the parts -- gate lines, leaf lengths, the arm, the readers')
do
    for n, z in pairs(Z) do
        local lane = LANE[n]
        local b = lane.box
        local function al(p) return (p.x - b.x) * b.ux + (p.y - b.y) * b.uy end
        local ol = (al(lane.leads[1]) + al(lane.leads[2])) / 2.0
        local il = (al(lane.leads[3]) + al(lane.leads[4])) / 2.0
        near(z.line.outer, ol, 1e-9, ('lane %d: the outer line is its outer leads\' hinges'):format(n))
        near(z.line.inner, il, 1e-9, ('lane %d: the inner line is its inner leads\''):format(n))
        near(z.trap.a0, ol, 1e-9, ('lane %d: the trap runs from the outer line'):format(n))
        near(z.trap.a1, il, 1e-9, '...to the inner line')
        near(z.outer.swing.a1, ol, 1e-9, 'the outer swing meets the trap at the outer line')
        local leaf = math.sqrt(lane.follows[1].ox ^ 2 + lane.follows[1].oy ^ 2)
        ok(z.outer.swing.a0 <= ol - leaf + 1e-9, 'it reaches past the leaf\'s length, out toward the arm')
        ok(z.outer.swing.a0 <= al(lane.arm) - 0.2, 'and past the arm\'s beam: the arm comes down with the outer gate')
        near(z.inner.swing.a0, il, 1e-9, 'the inner swing meets the trap at the inner line')
        near(z.inner.swing.a1, il + leaf, 1e-6, 'and reaches the leaf\'s length into the campus')
        local rin = P.readers[R['gate.lane' .. n .. '.reader_in']]
        local rout = P.readers[R['gate.lane' .. n .. '.reader_out']]
        near(z.outer.way.a0, al(rin), 1e-9, 'the outer way runs out to the outside reader')
        near(z.inner.way.a1, al(rout), 1e-9, 'the inner way out to the inside one')
        eq(z.readers[R['gate.lane' .. n .. '.reader_in']], 'outer', 'the outside reader opens the outer gate first')
        eq(z.readers[R['gate.lane' .. n .. '.reader_out']], 'inner', 'the inside reader opens the inner gate first')
        ok(not GS.inTrap(Z, rin.x, rin.y, rin.z, GC.lane) and not GS.inTrap(Z, rout.x, rout.y, rout.z, GC.lane),
            ('lane %d: neither reader is in a trap'):format(n))
        eq(z.all.a0, z.outer.way.a0, 'everything worth looking at, from the outside reader...')
        eq(z.all.a1, z.inner.way.a1, '...to the inside one')
    end
    eq(GS.gateOf('gate.lane1.outer.lead_l'), 'outer', 'a part\'s gate is in its id')
    eq(GS.gateOf('gate.lane3.inner.follow_r'), 'inner', 'inner')
    eq(GS.gateOf('gate.lane2.outer_arm.arm'), 'outer', 'the arm is the outer gate\'s')
    eq(GS.gateOf('gate.lane2.reader_in'), nil, 'a reader is no gate\'s part')
    ok(GS.inTrap(Z, at(A_TRAP, 0).x, at(A_TRAP, 0).y, PED_Z, GC.lane), 'the trap\'s middle is in a trap')
    ok(not GS.inTrap(Z, at(A_OUT_SWING, 0).x, at(A_OUT_SWING, 0).y, PED_Z, GC.lane), 'a swing is not')
    -- Occupancy: each zone by itself, players and vehicles by their margins.
    local function o(peds, cars) return GS.occupancy(Z2, peds, cars, GC.lane) end
    local p = at(A_TRAP, 0)
    local r = o({ p })
    ok(r.trap == 'a player' and not r.outer.swing and not r.outer.way and not r.inner.swing, 'a player in the trap: the trap')
    r = o({ at(A_OUT_SWING, 0) })
    ok(r.outer.swing == 'a player' and r.outer.way == 'a player' and not r.trap, 'in the outer swing: its swing and its way')
    r = o({ at(A_OUT_WAY, 0) })
    ok(r.outer.way == 'a player' and not r.outer.swing and not r.trap, 'in the outer approach: its way only')
    r = o({ at(A_IN_SWING, 0) })
    ok(r.inner.swing == 'a player' and not r.trap and not r.outer.way, 'in the inner swing: its swing')
    r = o({ at(A_IN_WAY, 0) })
    ok(r.inner.way == 'a player' and not r.inner.swing, 'in the inner approach: its way only')
    r = o({ at(A_FAR_OUT, 0), at(A_FAR_IN, 0) })
    ok(not r.trap and not r.outer.way and not r.inner.way, 'far off either end: nowhere')
    r = o(nil, { at(Z2.trap.a0 + GC.lane.vehicleMarginM + 0.1, 0, BOX2.zLow + 0.6) })
    ok(not r.trap and not r.outer.swing and not r.inner.swing,
        'an empty car past the outer line by more than its half-length: in nothing -- the trap holds players only')
    r = o(nil, { at(Z2.trap.a0 + GC.lane.vehicleMarginM - 0.1, 0, BOX2.zLow + 0.6) })
    ok(not r.trap and r.outer.swing == 'a vehicle', 'by less: its tail is still in the outer swing')
    r = o({ at(A_TRAP, 0) }, { at(A_TRAP, 0, BOX2.zLow + 0.6) })
    eq(r.trap, 'a player', 'a car in the trap with its driver: the driver holds it')
    r = o(nil, { at(A_TRAP, 0, BOX2.zLow + 0.6) })
    eq(r.trap, nil, 'the same car, empty: holds nothing')
    r = o({ at(A_TRAP, BOX2.halfWidth + GC.lane.pedMarginM + 0.1) })
    ok(not r.trap, 'a player beside the lane, past the posts: not in it')
    r = o(nil, { at(A_OUT_SWING, -(BOX2.halfWidth + GC.lane.vehicleSideM - 0.1), BOX2.zLow + 0.6) })
    ok(r.outer.swing == 'a vehicle', ('a car whose center is %.1f m beside the lane (its side under a leaf): in the swing')
        :format(GC.lane.vehicleSideM - 0.1))
    r = o(nil, { at(A_OUT_SWING, -(BOX2.halfWidth + GC.lane.vehicleSideM + 0.1), BOX2.zLow + 0.6) })
    ok(not r.outer.swing and not r.outer.way, 'farther: not')
    eq(GC.lane.vehicleSideM, 1.0, 'a car\'s half-width')
    -- THE ARM IS THE OUTER GATE'S, WHATEVER THE BOX: a row whose box stops
    -- short of the arm still has the arm in its outer swing.
    local row = {}
    for k, v in pairs(LANE[2]) do row[k] = v end
    row.box = {}
    for k, v in pairs(LANE[2].box) do row.box[k] = v end
    row.box.halfLength = row.box.halfLength - 1.5
    local short = GS.laneZones(row, P.readers)
    local armAt = (LANE[2].arm.x - row.box.x) * row.box.ux + (LANE[2].arm.y - row.box.y) * row.box.uy
    ok(short.outer.swing.a0 <= armAt, 'a box that stops short of the arm: its beam still in the outer swing')
    r = o({ at(A_TRAP, 0, BOX2.zHigh + GC.lane.aboveM + 1.0) })
    ok(not r.trap, 'a player over it (a roof, a helicopter): not in it')
end

describe('the sequence, pure: inbound, every transition')
do
    local s = GS.newLane()
    eq(GS.code(s), 0, 'a new lane: idle, code 0')
    ok(GS.press(s, 'outer', 0, T), 'a press at the outside reader starts a cycle')
    ok(s.phase == 'first' and s.first == 'outer' and s.second == 'inner', 'the outer gate first, the inner second')
    eq(GS.code(s), 5, 'code 5: the outer gate open, the cycle running')
    ok(not GS.press(s, 'inner', 10, T), 'a press while it runs: not taken')
    -- The presser at the reader (the outer way), then into the trap at 1.5 s.
    eq(GS.advance(s, occ({ outerWay = 'a player' }), 1000, T), nil, 'the presser in its approach: nothing')
    eq(GS.advance(s, occ({ trap = 'a player' }), 1500, T), nil, 'in the trap, the gate still folding open: nothing')
    eq(GS.advance(s, occ({ trap = 'a player' }), 5500, T), nil, 'fully open at 4 s, clear 1.5 s since: not yet')
    ok(GS.advance(s, occ({ trap = 'a player' }), 6000, T) ~= nil and s.phase == 'firstShut',
        'clear 2 s since it stood fully open: the outer gate folds shut behind them')
    eq(GS.code(s), 4, 'code 4: no gate open, the cycle running')
    eq(GS.advance(s, occ({ trap = 'a player' }), 9900, T), nil, 'still folding shut')
    ok(GS.advance(s, occ({ trap = 'a player' }), 10000, T) ~= nil and s.phase == 'second', 'fully shut, someone in the trap: the inner gate opens')
    eq(GS.code(s), 6, 'code 6: the inner gate open')
    eq(GS.advance(s, occ({ innerSwing = 'a player' }), 14000, T), nil, 'walking out through its swing: held')
    eq(GS.advance(s, occ({}), 14500, T), nil, 'clear')
    eq(GS.advance(s, occ({}), 16000, T), nil, '1.5 s clear: not yet')
    ok(GS.advance(s, occ({}), 16500, T) ~= nil and s.phase == 'secondShut', '2 s clear: the inner gate folds shut')
    ok(GS.advance(s, occ({}), 20500, T) ~= nil and s.phase == 'idle' and GS.code(s) == 0, 'fully shut: idle')
    ok(s.first == nil and s.second == nil, 'its gates forgotten')
    ok(GS.press(s, 'inner', 21000, T), 'idle again: a press is taken')
end

describe('the sequence, pure: outbound, an abandoned first gate, reopening, the poses')
do
    local s = GS.newLane()
    GS.press(s, 'inner', 0, T)
    ok(s.first == 'inner' and GS.code(s) == 6, 'the inside reader: the inner gate first')
    GS.advance(s, occ({ trap = 'a player' }), 500, T)
    GS.advance(s, occ({ trap = 'a player' }), 6000, T)
    eq(s.phase, 'firstShut', 'the driver in the trap: the inner gate shuts behind the car')
    GS.advance(s, occ({ trap = 'a player' }), 10000, T)
    ok(s.phase == 'second' and GS.code(s) == 5, 'then the outer gate and its arm open')
    -- A gate never closes on anybody in its swing.
    GS.advance(s, occ({ outerSwing = 'a vehicle' }), 16000, T)
    eq(s.phase, 'second', 'the car under the arm: still open at 6 s')
    GS.advance(s, occ({}), 16500, T)
    GS.advance(s, occ({}), 18500, T)
    eq(s.phase, 'secondShut', 'gone 2 s: shutting')
    ok(GS.advance(s, occ({ outerSwing = 'a player' }), 19000, T) ~= nil and s.phase == 'second',
        'somebody steps into its swing while it shuts: open again')
    GS.advance(s, occ({}), 19500, T)
    GS.advance(s, occ({}), 23000, T)
    eq(s.phase, 'second', 'and it stands fully open again before its 2 s count')
    -- Somebody staying in the trap holds the second gate open: it never starts
    -- to shut while they are there.
    s = GS.newLane()
    GS.press(s, 'outer', 0, T)
    GS.advance(s, occ({ trap = 'a player' }), 500, T)
    GS.advance(s, occ({ trap = 'a player' }), 6000, T)
    GS.advance(s, occ({ trap = 'a player' }), 10000, T)
    eq(s.phase, 'second', 'the inner gate open')
    local moved = 0
    for t = 10500, 40000, 500 do
        if GS.advance(s, occ({ trap = 'a player' }), t, T) then moved = moved + 1 end
    end
    eq(moved, 0, 'somebody staying in the trap 30 s: the second gate never starts to shut')
    GS.advance(s, occ({}), 40500, T)
    GS.advance(s, occ({}), 42500, T)
    eq(s.phase, 'secondShut', 'they leave: 2 s later it does')

    -- ABANDONED: nobody comes into the trap.
    s = GS.newLane()
    GS.press(s, 'outer', 0, T)
    GS.advance(s, occ({}), 500, T)
    GS.advance(s, occ({}), 9500, T)
    eq(s.phase, 'first', 'nobody in the trap at 9.5 s: still open')
    ok(GS.advance(s, occ({}), 10000, T) ~= nil and s.phase == 'firstShut', 'at 10 s: it shuts')
    ok(GS.advance(s, occ({}), 14000, T) ~= nil and s.phase == 'idle' and not s.inner.open,
        'fully shut with nobody in the trap: the cycle ends, the inner gate never opened')
    -- Abandoned with a car parked in its swing.
    s = GS.newLane()
    GS.press(s, 'outer', 0, T)
    for t = 500, 30000, 500 do GS.advance(s, occ({ outerSwing = 'a vehicle' }), t, T) end
    eq(s.phase, 'first', 'a car parked under the arm: open 30 s on')
    GS.advance(s, occ({}), 30500, T)
    GS.advance(s, occ({}), 32000, T)
    eq(s.phase, 'first', 'gone 1.5 s: still open')
    GS.advance(s, occ({}), 32500, T)
    eq(s.phase, 'firstShut', 'gone 2 s: it shuts')
    -- Its approach does not hold an abandoned gate, but it does hold one
    -- with someone in the trap.
    s = GS.newLane()
    GS.press(s, 'outer', 0, T)
    GS.advance(s, occ({ outerWay = 'a player' }), 500, T)
    GS.advance(s, occ({ outerWay = 'a player' }), 12500, T)
    eq(s.phase, 'firstShut', 'standing at the reader, nobody in the trap: it shuts at 10 s (and 2 s clear of its swing)')
    s = GS.newLane()
    GS.press(s, 'outer', 0, T)
    for t = 500, 20000, 500 do GS.advance(s, occ({ trap = 'a player', outerWay = 'a player' }), t, T) end
    eq(s.phase, 'first', 'someone in the trap and someone in its approach: held for the second')

    -- THE POSES: each gate's pose a function of the time, from where it was.
    s = GS.newLane()
    GS.press(s, 'outer', 1000, T)
    near(GS.gatePose(s.outer, 3000, T.foldMs), 0.5, 1e-9, 'two seconds into the fold: the outer gate half open')
    eq(GS.gatePose(s.inner, 3000, T.foldMs), 0.0, 'the inner gate shut')
    GS.advance(s, occ({ trap = 'a player' }), 1500, T)
    GS.advance(s, occ({ trap = 'a player' }), 7000, T)
    near(GS.gatePose(s.outer, 8000, T.foldMs), 0.75, 1e-9, 'a second into shutting: three quarters open')
    GS.advance(s, occ({ outerSwing = 'a player' }), 8000, T)
    eq(s.phase, 'first', 'reopened')
    near(GS.gatePose(s.outer, 8000, T.foldMs), 0.75, 1e-9, 'from where it was')
    near(GS.gatePose(s.outer, 9000, T.foldMs), 1.0, 1e-9, 'and open a second later')
end

describe('the sequence, pure: the dev\'s stop, and the wire\'s code')
do
    local s = GS.newLane()
    ok(not GS.halt(s, 0, T), 'an idle lane: nothing to stop')
    GS.press(s, 'outer', 0, T)
    ok(GS.halt(s, 100, T) and s.phase == 'secondShut' and s.second == 'outer' and not s.outer.open,
        'its first gate open: it shuts as the last')
    GS.advance(s, occ({}), 4100, T)
    eq(s.phase, 'idle', 'and the cycle ends with it')
    GS.press(s, 'inner', 5000, T)
    GS.advance(s, occ({ trap = 'a player' }), 5500, T)
    GS.advance(s, occ({ trap = 'a player' }), 11000, T)
    eq(s.phase, 'firstShut', 'shutting behind someone')
    ok(GS.halt(s, 11500, T) and s.phase == 'secondShut' and s.at == 11000, 'stopped while it shuts: it keeps shutting, as the last')
    ok(GS.advance(s, occ({ trap = 'a player' }), 12000, T) ~= nil and s.phase == 'second' and s.inner.open,
        'but somebody in the trap opens it again: nobody is shut in')
    for c = 0, 7 do
        local d = GS.decode(c)
        ok(d and d.outer == (c % 2 == 1) and d.inner == (c % 4 >= 2) and d.busy == (c >= 4), 'code ' .. c .. ' reads back')
    end
    for _, bad in ipairs({ -1, 8, 2.5, '5', true, 0 / 0 }) do
        eq(GS.decode(bad), nil, 'not a code: ' .. tostring(bad))
    end
    near(GS.rotationOff(0.0, -85.0, 270.0, 0.0, -85.0, -90.0), 0.0, 1e-9, 'the rotation read back: 270 is -90')
    near(GS.rotationOff(0.0, -85.0, 270.0, 180.0, 95.0, 90.0), 0.0, 1e-9, 'and the other spelling of the same turn is not off')
    near(GS.rotationOff(0.0, -85.0, 270.0, 0.0, 0.0, 270.0), 85.0, 1e-9, 'an arm lying down when it should stand: 85 off')
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
    local function idle() G.stateOf(m).lanes[2] = GS.newLane() end
    gameMs = gameMs + 1500
    sample()
    eq(G.use(1, { reader = rd }, gameMs), 'open', 'a good press opens the gate')
    eq(G.use(1, { reader = rd }, gameMs + GC.use.minIntervalMs - 1), 'rate', '3. inside use.minIntervalMs: rate')
    ok(GC.use.minIntervalMs * 2 <= GC.client.askMs,
        'the server\'s interval is at most half the client\'s, so jitter never drops a retry a second later')
    idle()
    eq(press(1, { reader = rd }), 'open', 'and a second and a half later it is taken again')
    idle()
    gameMs = gameMs + GC.client.askMs - 250
    sample()
    eq(G.use(1, { reader = rd }, gameMs), 'open', 'a retry that arrives a quarter second early (jitter): taken')
    idle()

    roster[1].matchId = nil
    eq(press(1, { reader = rd }), 'match', '4. in no match: match')
    roster[1].matchId = 1
    m.state = BR.MatchState.WARMUP
    eq(press(1, { reader = rd }), 'match', '4. a match at warmup: match')
    m.state = BR.MatchState.ENDED
    eq(press(1, { reader = rd }), 'match', '4. a match that ended: match')
    m.state = BR.MatchState.BUS
    eq(press(1, { reader = rd }), 'open', '4. the bus still flying (this player jumped early and landed): taken')
    idle()
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
    idle()
    player(1, m, IN2.x, IN2.y, nil, IN2.z + GC.readerZM + slack + 0.3)
    eq(press(1, { reader = rd }), 'reach', '6. on a roof over it: reach')
    player(1, m, IN2.x, IN2.y + 0.5)
    eq(press(1, { reader = R['gate.lane3.reader_out'] }), 'reach',
        '6. naming another lane\'s reader from this one: reach -- the server says where the player is')
    -- NO READER IN THE TRAP: a player in it, within reach of the inside
    -- reader past the inner gate, is at no reader.
    local inTrap = at(Z2.line.inner - 0.3, acrossOf(OUT2.x, OUT2.y))
    ok(math.sqrt((inTrap.x - OUT2.x) ^ 2 + (inTrap.y - OUT2.y) ^ 2) < GC.readerM, 'a spot in the trap within readerM of the inside reader')
    player(1, m, inTrap.x, inTrap.y)
    eq(press(1, { reader = R['gate.lane2.reader_out'] }), 'reach', '6. from the trap: reach -- no reader in the trap')

    player(1, m, IN2.x, IN2.y + 0.5)
    eq(press(1, { reader = rd }), 'open', 'at the reader again: open')
    eq(press(1, { reader = rd }), 'busy', '7. ...and again while its cycle runs: busy')
    local st = G.stateOf(m)
    ok(GS.busy(st.lanes[2]) and not GS.busy(st.lanes[1]) and not GS.busy(st.lanes[3]), 'only lane 2 runs')
    eq(st.refused.season, 1, 'every refusal counted on the match: season')
    eq(st.refused.shape, 6, 'shape')
    eq(st.refused.rate, 1, 'rate')
    eq(st.refused.match, 2, 'match (a press from no match has no match to be counted on)')
    eq(st.refused.player, 2, 'player')
    eq(st.refused.reach, 5, 'reach')
    eq(st.refused.busy, 1, 'busy')
end

describe('the door: the outside reader opens only the outer gate, the inside only the inner; the match told')
do
    reset()
    local m = newMatch(1)
    local other = newMatch(2)
    player(1, m, IN2.x, IN2.y - 0.5)
    player(2, m, 0.0, 0.0)
    player(3, other, OUT2.x, OUT2.y)
    player(4, nil, OUT2.x, OUT2.y)
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'open', 'the outside reader')
    local s = G.stateOf(m).lanes[2]
    ok(s.outer.open and not s.inner.open, 'the outer gate (and its arm) open, the inner gate shut')
    local to = {}
    for _, e in ipairs(eventsOf(BR.Net.DCGATE_STATE)) do to[e.src] = (to[e.src] or 0) + 1 end
    ok(to[1] == 1 and to[2] == 1, 'everyone in the match is told, once: across the map too')
    ok(to[3] == nil and to[4] == nil, 'nobody in another match or in none')
    local p = lastOf(BR.Net.DCGATE_STATE, 2)
    ok(p and p.matchId == 1 and p.lanes[1] == 0 and p.lanes[2] == 5 and p.lanes[3] == 0,
        'the payload: the match, and a code a lane (5: the outer gate open, the cycle running)')
    local n = 0
    for _ in pairs(p) do n = n + 1 end
    eq(n, 2, 'and nothing else: matchId and lanes')
    ok(logs[#logs]:find('lane 2 outer gate open by p1 (1) at gate.lane2.reader_in in match 1', 1, true) ~= nil,
        'one console line', logs[#logs])
    local before = #sent
    eq(press(3, { reader = R['gate.lane2.reader_out'] }), 'open', 'the other match\'s lane 2 is its own')
    eq(#sent - before, 1, 'and only its own player hears of it')
    local o = G.stateOf(other).lanes[2]
    ok(o.inner.open and not o.outer.open and o.first == 'inner', 'the inside reader: only the inner gate')
end

-- =========================================================================
-- PART D -- the sally port, on the server's own samples
-- =========================================================================

--- Put a player of the roster at a point of lane 2.
local function put(src, a, c, z)
    local p = at(a, c or 0.0, z)
    roster[src].pos = { x = p.x, y = p.y, z = p.z }
end
--- A vehicle of a bucket at a point of lane 2 (its center a car's height up).
local function car(h, m, a, c)
    local p = at(a, c or 0.0, BOX2.zLow + 0.6)
    vehicles[h] = { x = p.x, y = p.y, z = p.z, bucket = m and m.bucket or 0 }
end
--- The passes up to `t` ms after `t0`, every lane.checkMs.
local function runTo(t0, t)
    while gameMs + GC.lane.checkMs <= t0 + t do after(GC.lane.checkMs) end
end
local function code2(src) local p = lastOf(BR.Net.DCGATE_STATE, src) return p and p.lanes[2] end

describe('the sally port: inbound on foot -- outer gate, the trap, outer shut, inner open, inner shut')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    player(2, m, 0.0, 0.0)
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'open', 'pressed at the outside reader')
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    eq(code2(2), 5, 'the match told: the outer gate open')
    put(1, alongOf(IN2.x, IN2.y), 0.0)
    runTo(t0, 1000)
    eq(s.phase, 'first', 'standing at the reader, in its approach')
    put(1, A_TRAP)
    runTo(t0, 5500)
    eq(s.phase, 'first', 'in the trap since 1.5 s; the gate fully open at 4 s; 1.5 s since: still open')
    runTo(t0, 6000)
    eq(s.phase, 'firstShut', 'about 2 s after it stood open, its swing and approach clear: the outer gate shuts')
    eq(code2(2), 4, 'the match told')
    ok(logs[#logs]:find('lane 2 in match 1: outer gate shutting behind a player in the trap', 1, true) ~= nil, logs[#logs])
    runTo(t0, 9500)
    eq(s.phase, 'firstShut', 'still folding shut')
    runTo(t0, 10000)
    ok(s.phase == 'second' and s.inner.open and not s.outer.open, 'fully shut, a player in the trap: the inner gate opens')
    eq(code2(2), 6, 'the match told')
    put(1, A_IN_SWING)
    runTo(t0, 15000)
    eq(s.phase, 'second', 'walking out through its swing: held')
    put(1, A_FAR_IN)
    runTo(t0, 17000)
    eq(s.phase, 'second', 'out of it at 15 s, first seen clear at 15.5 s; 1.5 s since: still open')
    runTo(t0, 17500)
    eq(s.phase, 'secondShut', 'about 2 s after the trap and its swing are clear: the inner gate shuts')
    runTo(t0, 21500)
    ok(s.phase == 'idle' and code2(2) == 0, 'fully shut: the cycle is over, and the match told')
    local reads = poolReads
    runTo(t0, 25000)
    eq(poolReads, reads, 'every lane idle: the pass reads nothing')
end

describe('the sally port: outbound by car -- inner gate, the trap, inner shut, outer and arm open, outer shut')
do
    reset()
    local m = newMatch(1)
    player(1, m, OUT2.x, OUT2.y)
    car(501, m, alongOf(OUT2.x, OUT2.y) - 0.2)
    eq(press(1, { reader = R['gate.lane2.reader_out'] }), 'open', 'pressed at the inside reader')
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    ok(s.inner.open and not s.outer.open and code2(1) == 6, 'only the inner gate opens')
    runTo(t0, 8000)
    eq(s.phase, 'first', 'the car waiting at the reader, its nose in the inner gate\'s swing: held open')
    put(1, A_TRAP)
    car(501, m, A_TRAP)
    runTo(t0, 10000)
    eq(s.phase, 'first', 'in the trap, its swing and approach clear 1.5 s')
    runTo(t0, 10500)
    eq(s.phase, 'firstShut', 'clear 2 s: the inner gate shuts behind it')
    runTo(t0, 14500)
    ok(s.phase == 'second' and s.outer.open and code2(1) == 5, 'shut: the outer gate and its arm open')
    car(501, m, A_OUT_SWING)
    put(1, A_OUT_SWING)
    runTo(t0, 30000)
    eq(s.phase, 'second', 'the car stopped under the arm: the outer gate never closes on it')
    car(501, m, A_FAR_OUT)
    put(1, A_FAR_OUT)
    runTo(t0, 32000)
    eq(s.phase, 'second', 'gone 1.5 s')
    runTo(t0, 32500)
    eq(s.phase, 'secondShut', 'gone 2 s: it shuts')
    runTo(t0, 36500)
    eq(s.phase, 'idle', 'and the cycle is over')
end

describe('the sally port: a first gate nobody comes through closes at 10 s, and the cycle ends')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    put(1, A_FAR_OUT)
    runTo(t0, 9500)
    eq(s.phase, 'first', 'nobody in the trap at 9.5 s: open')
    runTo(t0, 10000)
    eq(s.phase, 'firstShut', 'at 10 s: shutting')
    ok(logs[#logs]:find('nobody came into the trap', 1, true) ~= nil, logs[#logs])
    runTo(t0, 14000)
    ok(s.phase == 'idle' and not s.inner.open, 'shut with nobody in it: idle, the inner gate never opened')
    eq(code2(1), 0, 'the match told')
end

describe('the sally port: a car parked in a swing holds that gate; one driving into a closing gate opens it')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    put(1, A_FAR_OUT)
    car(9, m, A_OUT_SWING)
    runTo(t0, 30000)
    eq(s.phase, 'first', 'an empty car parked under the arm: the outer gate open 30 s on')
    vehicles[9].bucket = 7777
    coordsRead = {}
    runTo(t0, 32000)
    eq(s.phase, 'first', 'the same car in another routing bucket, 1.5 s')
    runTo(t0, 32500)
    eq(s.phase, 'firstShut', 'and 2 s: not this match\'s, and the gate shuts')
    eq(coordsRead[9], nil, 'and its position is not even read: only the match\'s own bucket\'s are')
    vehicles[9].bucket = m.bucket
    runTo(t0, 33000)
    eq(s.phase, 'first', 'back in this match, in its swing while it shuts: open again')
    eq(code2(1), 5, 'and the match told')
    ok(logs[#logs]:find('outer gate open again: a vehicle in its swing', 1, true) ~= nil, logs[#logs])
    -- Inbound through, then a car parked in the inner gate's swing.
    vehicles[9] = nil
    put(1, A_TRAP)
    runTo(t0, 39000)
    eq(s.phase, 'firstShut', 'a player in the trap: the outer gate shuts behind them')
    runTo(t0, 43000)
    eq(s.phase, 'second', 'and the inner one opens')
    put(1, A_FAR_IN)
    car(10, m, A_IN_SWING)
    runTo(t0, 70000)
    eq(s.phase, 'second', 'an empty car parked in the inner gate\'s swing: open 27 s on')
    vehicles[10] = nil
    runTo(t0, 72500)
    eq(s.phase, 'secondShut', 'driven off: shut 2 s later')
    -- A CAR DRIVING INTO THE SECOND GATE'S SWING AS IT SHUTS.
    car(11, m, A_IN_SWING)
    runTo(t0, 73000)
    eq(s.phase, 'second', 'a car into the inner gate\'s swing as it shuts: open again')
    vehicles[11] = nil
    runTo(t0, 78500)
    eq(s.phase, 'second', 'it stands fully open (77 s) before its 2 s count')
    runTo(t0, 79000)
    eq(s.phase, 'secondShut', 'then shuts')
    -- Beside the lane, on the island between two: no zone of either.
    reset()
    m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    t0 = gameMs
    s = G.stateOf(m).lanes[2]
    put(1, A_FAR_OUT)
    local b1 = LANE[1].box
    local island = ((b1.y + b1.halfWidth) + (BOX2.y - BOX2.halfWidth)) / 2.0
    vehicles[12] = { x = at(A_OUT_SWING, 0).x, y = island, z = BOX2.zLow + 0.6, bucket = m.bucket }
    runTo(t0, 12500)
    eq(s.phase, 'firstShut', 'a car on the island beside the outer gate holds nothing')
end

describe('the sally port: an empty car left in the trap holds nothing -- the trap holds players')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    car(31, m, A_TRAP)
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'open', 'pressed outside, an empty car parked in the trap')
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    put(1, A_TRAP)
    runTo(t0, 10000)
    eq(s.phase, 'second', 'the presser walks into the trap: outer shut behind them, inner open')
    put(1, A_FAR_IN)
    runTo(t0, 16500)
    eq(s.phase, 'secondShut', 'they walk out: the inner gate shuts 2 s after they are clear, the car notwithstanding')
    runTo(t0, 20500)
    ok(s.phase == 'idle' and code2(1) == 0, 'and the cycle ends')
    player(2, m, IN2.x, IN2.y)
    eq(press(2, { reader = R['gate.lane2.reader_in'] }), 'open', 'the next press is taken')
    -- Abandoned with the car still there: the cycle ends, the inner gate never opens.
    t0 = gameMs
    put(2, A_FAR_OUT)
    runTo(t0, 10000)
    eq(s.phase, 'firstShut', 'nobody walks in: at 10 s the outer gate shuts')
    runTo(t0, 14000)
    ok(s.phase == 'idle' and not s.inner.open, 'and the cycle ends; the inner gate never opened for the empty car')
    -- A car driven into the trap: its driver holds it.
    player(3, m, IN2.x, IN2.y)
    press(3, { reader = R['gate.lane2.reader_in'] })
    t0 = gameMs
    car(32, m, A_TRAP + 3.0)
    put(3, A_TRAP + 3.0)
    runTo(t0, 10000)
    eq(s.phase, 'second', 'a car driven into the trap: its driver counts, the inner gate opens')
    runTo(t0, 40000)
    eq(s.phase, 'second', 'and stays open while the driver waits in the trap')
end

describe('the sally port: who holds a gate -- standing or downed, not out, not stale, not over it')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    player(2, m, 0.0, 0.0)
    press(1, { reader = R['gate.lane2.reader_in'] })
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    put(1, A_FAR_OUT)
    put(2, A_OUT_SWING)
    roster[2].state = BR.PlayerState.DBNO
    runTo(t0, 20000)
    eq(s.phase, 'first', 'a downed player in its swing: held (a leaf does not fold onto a downed player)')
    roster[2].state = BR.PlayerState.OUT
    runTo(t0, 22500)
    eq(s.phase, 'firstShut', 'out: nobody holds it')
    roster[2].state = BR.PlayerState.ALIVE
    runTo(t0, 23000)
    eq(s.phase, 'first', 'standing again, in its swing: open again')
    -- Reopened at 23 s: its abandon clock runs from then.
    local stale = gameMs - GC.lane.sampleMaxAgeMs - 1
    while gameMs < t0 + 33000 do
        gameMs = gameMs + 500
        roster[1].posAt = gameMs
        roster[2].posAt = stale
        G.pass(gameMs)
    end
    eq(s.phase, 'firstShut', 'a sample older than lane.sampleMaxAgeMs holds nothing: shut 10 s after it reopened')
    roster[2].posAt = gameMs
    put(2, A_OUT_SWING, 0, BOX2.zHigh + GC.lane.aboveM + 1.0)
    runTo(t0, 33500)
    eq(s.phase, 'firstShut', 'a player over its swing (a roof, a helicopter): not in it')
    local L1 = LANE[1].box
    roster[2].pos = { x = L1.x, y = L1.y, z = PED_Z }
    runTo(t0, 37000)
    eq(s.phase, 'idle', 'a player in lane 1\'s trap is not in lane 2\'s: lane 2 shut with nobody in its trap, idle')
end

describe('the sally port: a player dropped in the trap gets nothing, and rides out on somebody else\'s cycle')
do
    reset()
    local m = newMatch(1)
    player(2, m, 0.0, 0.0)
    put(2, A_TRAP)
    for _ = 1, 10 do after(500) end
    eq(G.stateOf(m).lanes[2].phase, 'idle', 'a player in the trap with no cycle: nothing moves')
    eq(poolReads, 0, 'and nothing is read')
    local nearIn = at(Z2.line.inner - 0.3, acrossOf(OUT2.x, OUT2.y))
    roster[2].pos = { x = nearIn.x, y = nearIn.y, z = PED_Z }
    eq(press(2, { reader = R['gate.lane2.reader_out'] }), 'reach', 'a press from the trap, by the inside reader: refused')
    eq(press(2, { reader = R['gate.lane2.reader_in'] }), 'reach', 'and by the outside one')
    eq(G.stateOf(m).lanes[2].phase, 'idle', 'still idle')
    -- Somebody presses outside, and walks away.
    player(1, m, IN2.x, IN2.y)
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'open', 'somebody presses at the outside reader')
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    put(1, alongOf(IN2.x, IN2.y))
    runTo(t0, 8000)
    eq(s.phase, 'first', 'while they stand at the reader (its approach), the outer gate waits for them')
    put(1, A_FAR_OUT)
    runTo(t0, 10500)
    eq(s.phase, 'firstShut', 'they walk away: the trap holds someone, so it shuts 2 s later')
    runTo(t0, 14500)
    eq(s.phase, 'second', 'and the inner gate opens for the player in the trap')
end

describe('the sally port: a press during a cycle is not taken, at any phase')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    player(2, m, OUT2.x, OUT2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    eq(press(2, { reader = R['gate.lane2.reader_out'] }), 'busy', 'first gate open: the inside reader is busy')
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'busy', 'and the outside one')
    put(1, A_TRAP)
    runTo(t0, 7500)
    eq(s.phase, 'firstShut', 'first gate shutting')
    eq(press(2, { reader = R['gate.lane2.reader_out'] }), 'busy', 'busy')
    runTo(t0, 11500)
    eq(s.phase, 'second', 'second gate open')
    eq(press(2, { reader = R['gate.lane2.reader_out'] }), 'busy', 'busy')
    put(1, A_FAR_IN)
    runTo(t0, 19500)
    eq(s.phase, 'secondShut', 'second gate shutting')
    eq(press(2, { reader = R['gate.lane2.reader_out'] }), 'busy', 'still busy until it is fully shut')
    runTo(t0, 24000)
    eq(s.phase, 'idle', 'idle')
    eq(press(2, { reader = R['gate.lane2.reader_out'] }), 'open', 'now taken')
    ok(s.first == 'inner', 'the inside reader\'s cycle: the inner gate first')
    ok(not GS.busy(G.stateOf(m).lanes[1]) and not GS.busy(G.stateOf(m).lanes[3]), 'the other lanes never ran')
end

describe('the sally port: a match ending mid-cycle; two matches apart; Season 1')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    local t0 = gameMs
    local s = G.stateOf(m).lanes[2]
    put(1, A_FAR_OUT)
    m.state = BR.MatchState.ENDED
    local before = #sent
    runTo(t0, 30000)
    ok(s.phase == 'first' and #sent == before, 'the match ended mid-cycle: not moved on, nobody told (it is going away)')
    eq(poolReads, 0, 'and nothing read for it')
    eq(press(1, { reader = R['gate.lane2.reader_in'] }), 'match', 'a press in it: match')
    matches[1] = nil
    local m2 = newMatch(2)
    roster[1].matchId = 2
    ok(not GS.busy(G.stateOf(m2).lanes[2]), 'the next match: every lane idle')
    m.state = BR.MatchState.BUS
    matches[1] = m
    runTo(gameMs, 2500)
    eq(s.phase, 'firstShut', 'a match on the bus runs its cycles')

    reset()
    local a, b = newMatch(1), newMatch(2)
    player(1, a, IN2.x, IN2.y)
    player(2, b, IN2.x, IN2.y)
    player(3, b, 0.0, 0.0)
    press(1, { reader = R['gate.lane2.reader_in'] })
    press(2, { reader = R['gate.lane2.reader_in'] })
    t0 = gameMs
    put(1, A_TRAP)
    put(2, A_FAR_OUT)
    put(3, A_FAR_OUT)
    local reads = poolReads
    runTo(t0, 500)
    eq(poolReads - reads, 1, 'two matches\' cycles: the pool read once a pass for both')
    runTo(t0, 7000)
    eq(G.stateOf(a).lanes[2].phase, 'firstShut', 'match 1, its player in the trap: shut behind them')
    eq(G.stateOf(b).lanes[2].phase, 'first', 'match 2, nobody in its trap (the buckets do not mix): still open')

    reset()
    m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    press(1, { reader = R['gate.lane2.reader_in'] })
    gateOn(false)
    after(500)
    eq(m.dcgate, nil, 'Season 1: the match forgets its lanes (every client shut them itself)')
    gateOn(true)
end

-- =========================================================================
-- PART E -- the snapshot's view
-- =========================================================================

describe('the snapshot: each lane\'s code and each gate\'s pose -- for a late joiner')
do
    reset()
    local m = newMatch(1)
    player(1, m, IN2.x, IN2.y)
    player(2, nil, 0.0, 0.0)
    local v = G.viewFor(1)
    ok(v and v.matchId == 1 and v.lanes[1] == 0 and v.lanes[2] == 0 and v.lanes[3] == 0,
        'in a match with no lane ever used: every lane idle')
    ok(v.poses[2][1] == 0.0 and v.poses[2][2] == 0.0, 'every gate shut')
    eq(m.dcgate, nil, 'and asking makes no state')
    press(1, { reader = R['gate.lane2.reader_in'] })
    local t0 = gameMs
    gameMs = t0 + 2000
    v = G.viewFor(1)
    ok(v.lanes[2] == 5 and v.poses[2][1] == 0.5 and v.poses[2][2] == 0.0,
        'a late joiner two seconds into the outer gate\'s fold: code 5, the outer gate half open', v.poses[2][1])
    put(1, A_TRAP)
    runTo(t0, 7000)
    gameMs = t0 + 7000
    v = G.viewFor(1)
    ok(v.lanes[2] == 4 and v.poses[2][1] == 0.75, 'a second into shutting behind them: three quarters open', v.poses[2][1])
    runTo(t0, 12000)
    v = G.viewFor(1)
    ok(v.lanes[2] == 6 and v.poses[2][1] == 0.0 and v.poses[2][2] == 0.5, 'then the inner gate half open, the outer shut',
        ('%s %s'):format(v.poses[2][1], v.poses[2][2]))
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
    ok(said:find('lane 3 outer gate open in match 1', 1, true) and G.stateOf(m).lanes[3].outer.open,
        '`brgate open 3`: the outside reader\'s cycle', said)
    said = sv(1, 'open 1 out')
    ok(said:find('lane 1 inner gate open', 1, true) and G.stateOf(m).lanes[1].inner.open, '`brgate open 1 out`: the inside one\'s', said)
    said = sv(1, 'open 1 sideways')
    ok(said:find('no reader "sideways"', 1, true) ~= nil, 'a reader that is not one', said)
    said = sv(1, 'list')
    ok(said:find('lane 3 outer gate open 0.0 s (inbound, first gate)', 1, true) and said:find('lane 2 idle', 1, true),
        '`brgate list`', said)
    said = sv(1, 'open 3')
    ok(said:find('nothing to open: its cycle runs', 1, true) ~= nil, 'open on a running cycle: nothing', said)
    said = sv(1, 'close all')
    ok(said:find('lane 1, 3 ending its cycle', 1, true) and G.stateOf(m).lanes[3].phase == 'secondShut',
        '`brgate close all`: each running cycle\'s open gate shuts as the last', said)
    eq(lastOf(BR.Net.DCGATE_STATE, 1).lanes[3], 4, 'and the match is told')
    said = sv(1, 'close all')
    ok(said:find('nothing to close', 1, true) ~= nil, 'nothing left to close', said)
    said = sv(1, 'open 9')
    ok(said:find('no lane "9"', 1, true) ~= nil, 'a lane that is not one', said)
    sv(1, 'open 2')
    player(2, m, 0.0, 0.0)
    put(2, A_TRAP)
    said = sv(1, 'list')
    ok(said:find('lane 2 outer gate open', 1, true) and said:find('the trap: a player', 1, true), 'list says who is where', said)
    said = sv(0, 'close 2 1')
    eq(G.stateOf(m).lanes[2].phase, 'secondShut', 'from the console, the player id comes last')
    m.state = BR.MatchState.WARMUP
    said = sv(1, 'open 1')
    ok(said:find('a match being played', 1, true) ~= nil, 'not while the match is not being played', said)
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
    eq(GC.openMs, nil, 'no open time: a gate closes by who is where, not a timer')
    eq(GC.cycle.closeDelayMs, 2000, 'the owner\'s "about 2 s"')
    eq(GC.cycle.abandonMs, 10000, 'and his 10 s')
    eq(GC.client.drive.arm, 'rotate', 'the arm turned by hand by default (owner, 2026-10-24)')
    eq(GC.foldDeg, 90.0, 'the kit\'s fold: 0-90')
    ok(GC.armRaiseDeg >= 85.0 and GC.armRaiseDeg <= 90.0, 'and the arm\'s raise: 85-90')
    ok(not srv:gsub('%-%-[^\n]*', ''):find('BR%.Dev%.on'), 'no decision here reads dev mode')
end

-- ------------------------------------------------------------------ report --

realPrint(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then realExit(1) end
