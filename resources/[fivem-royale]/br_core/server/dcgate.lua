-- The data center's main gate (#420), Season 2, server half: EVERY LANE IS
-- DECIDED HERE.
--
-- The campus's front gate has three lanes (br_lib/config/dcgate_parts.lua),
-- each a crash arm, an outer bi-fold gate, a trap and an inner bi-fold gate,
-- with a reader at the curb at each end. Each lane is a sally port. The whole
-- contract is docs/dcgate.md. This file holds:
--
--   the lanes     this match's: each lane's cycle and each of its two gates,
--                 open or shut and since when -- on the match, so every match
--                 starts with every lane idle, and two matches at once each
--                 have their own
--   the door      DCGATE_USE, a player at a reader asking for the gate that
--                 reader stands beyond, taken only in its order (below) and
--                 silent otherwise
--   the pass      every running cycle moved on by who is where: the sequence
--                 is br_lib/shared/dcgate_solve.lua's (S.advance), fed here
--                 from the server's own samples
--   who is told   DCGATE_STATE to the whole match on every change, and the
--                 snapshot's view, with each gate's pose, for a late joiner
--                 or a restarted client
--   the dev tools `brgatesv`, typed through `brgate`
--
-- ═══ THE OWNER'S DECISIONS (2026-10-19, 2026-10-24) ═══
--
--   * Standing at a lane's reader shows "Press E to open the gate". A press at
--     the outside reader opens only the outer gate and raises the arm; a press
--     at the inside reader opens only the inner gate.
--   * The first gate closes about 2 s after its swing area and approach are
--     clear once someone is in the trap, or 10 s after it opened with nobody
--     in the trap (the cycle ends). Shut with someone in the trap, the second
--     gate opens; it closes about 2 s after the trap and its swing are clear.
--   * No gate ever closes on a player or a vehicle in its swing area. A press
--     while the lane's cycle runs is not taken. No reader in the trap.
--   * Server-authoritative per match (its routing bucket); clients animate.
--   * Season 2 only; the readers work in a match only.
--
-- ═══ WHO IS WHERE: THE SERVER'S OWN POSITIONS, NOT A CLIENT'S WORD ═══
--
-- A closing gate has to know about everybody, including the players who are
-- nowhere near a client that could report them and the cars nobody sits in. A
-- client report is a claim only about itself (and a modified client could hold
-- a gate open from across the map, or never report the car it parked). The
-- server already has both answers on its own: every player's 4 Hz position
-- sample (server/roster.lua) and, under OneSync, every vehicle's position and
-- routing bucket (GetAllVehicles, the pool server/terminalfx/airstrike.lua
-- reads). So the zone tests run here, and only for a lane whose cycle runs:
-- nothing at all while every lane is idle, and the vehicle pool read once a
-- pass for all of them.
--
-- ═══ NO DECISION HERE READS DEV MODE ═══
--
-- tools/check_net_gates.lua: a net event may not refuse on dev mode. The dev
-- verbs are a command, behind br_lib/shared/devgate.lua's wrap like every other.

BR = BR or {}
BR.DcGate = BR.DcGate or {}

local G = BR.DcGate
local GS = BR.DcGateSolve

local function cfg() return BR.Config.DcGate end
local function parts() return BR.Config.DcGate.parts or {} end

--- The sequence's times: { foldMs, closeDelayMs, abandonMs }.
local function times()
    local c = cfg()
    local y = c.cycle or {}
    return { foldMs = c.foldMs or 4000, closeDelayMs = y.closeDelayMs or 2000, abandonMs = y.abandonMs or 10000 }
end

--- Is the gate on, in the season in force? On this side BR.Season.has is the
--- latched season and a few table reads, so the door and the pass ask it as
--- they go.
--- @return boolean
local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('dcgate') == true
end
G.on = on

--- Who a gate waits for: a player standing or downed.
local HOLDS = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO] = true,
}

--- A match under way: the bus still flying (a player who jumped early is on
--- the ground before the match goes live) or playing. The readers work, and
--- the cycles run, in these.
local UNDER_WAY = {
    [BR.MatchState.BUS] = true,
    [BR.MatchState.PLAYING] = true,
}
local function underWay(m)
    return m ~= nil and UNDER_WAY[m.state] == true
end

--- [n] = the lane's row and [n] = its zones, built once -- and again only if
--- the registry table itself is replaced (a suite's fixture).
local built = { parts = nil, lanes = nil, zones = nil }

local function rebuild()
    local p = parts()
    if built.parts ~= p then
        built.parts = p
        built.lanes = GS.byLane(p)
        built.zones = GS.zones(p)
    end
end

--- @param n integer
--- @return table|nil
local function laneRow(n)
    rebuild()
    return built.lanes[n]
end

--- @return table  [n] = BR.DcGateSolve.laneZones
local function zones()
    rebuild()
    return built.zones
end
G.zones = zones

-- -------------------------------------------------------- the match's lanes ---

--- This match's lanes, made on first use and gone with the match:
---   lanes    [n] = BR.DcGateSolve.newLane(): the cycle's phase, its first
---            gate, and each gate open or shut since when
---   rate     [src] = presses taken this match
---   refused  [reason] = presses dropped for it
--- @param m table
--- @return table
local function stateOf(m)
    local s = m.dcgate
    if not s then
        s = { lanes = {}, rate = {}, refused = {} }
        for _, l in ipairs(parts().lanes or {}) do s.lanes[l.lane] = GS.newLane() end
        m.dcgate = s
    end
    return s
end
G.stateOf = stateOf

--- Presses dropped with no match to count them on, by reason.
local refusedLoose = {}

--- [src] = GetGameTimer() of their last press past its shape.
local lastAt = {}

local function count(m, reason)
    local t = m and stateOf(m).refused or refusedLoose
    t[reason] = (t[reason] or 0) + 1
end

-- -------------------------------------------------------------- who is told ---

--- Every lane's code (BR.DcGateSolve.code): [n] = 1 outer open + 2 inner open
--- + 4 cycle running.
local function codes(st)
    local out = {}
    for _, l in ipairs(parts().lanes or {}) do
        out[l.lane] = GS.code(st and st.lanes[l.lane])
    end
    return out
end

--- The whole match is told: the gate is one place every player can drive up
--- to, and three small numbers are cheaper than deciding who might.
local function send(m, st)
    BR.Broadcast.toMatch(m, BR.Net.DCGATE_STATE, { matchId = m.id, lanes = codes(st) })
end

--- THE SNAPSHOT'S VIEW (BR.Broadcast.snapshot): this player's match's lanes,
--- `{ matchId, lanes, poses }` -- each lane's code, and each gate's pose now
--- ([n] = { outer, inner }, 0 shut to 1 open, to the hundredth), so a late
--- joiner and a restarted client (br:ready raises the snapshot) see each gate
--- where it is. Nil outside a match or off Season 2: the client then holds
--- every gate shut.
--- @param src integer
--- @return table|nil
function G.viewFor(src)
    if not on() then return nil end
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    if not m then return nil end
    local st, now, fold = m.dcgate, GetGameTimer(), cfg().foldMs or 4000
    local poses = {}
    for _, l in ipairs(parts().lanes or {}) do
        local s = st and st.lanes[l.lane]
        local function pose(g)
            return s and math.floor(GS.gatePose(s[g], now, fold) * 100 + 0.5) / 100 or 0.0
        end
        poses[l.lane] = { pose('outer'), pose('inner') }
    end
    return { matchId = m.id, lanes = codes(st), poses = poses }
end

-- ------------------------------------------------------------- a cycle ---

--- Start a lane's cycle: `first` ('outer' or 'inner') opens. Public so the
--- suites and the dev verb can start one.
--- @param m table
--- @param n integer
--- @param first string
--- @param now number
--- @param why string  for the console line
--- @return boolean  it started (false: no such lane, or its cycle runs)
function G.start(m, n, first, now, why)
    local st = stateOf(m)
    local s = st.lanes[n]
    if not s or not GS.press(s, first, now, times()) then return false end
    send(m, st)
    print(('[br_core] dcgate: lane %d %s gate open %s in match %s'):format(n, first, why, tostring(m.id)))
    return true
end

-- --------------------------------------------------------------- the door ---
--
-- ═══ DCGATE_USE, IN THIS ORDER, EVERY REFUSAL SILENT ═══
--
--   1. season   the gate on in the season in force
--   2. shape    `reader` a whole number naming a lane reader
--   3. rate     no sooner than use.minIntervalMs after this player's last
--               press, and use.perMatch a match at most
--   4. match    the player is in a match, and it is under way (BUS or
--               PLAYING): the readers work in a match only (the owner's
--               default, 2026-10-19)
--   5. player   ALIVE, by the roster: a downed player presses nothing
--   6. reach    by this server's own sample, no older than use.sampleMaxAgeMs,
--               within readerM (flat) and readerZM of THAT reader, each plus
--               use.reachSlackM, and in no lane's trap (no reader in the trap,
--               the owner's): the client says which reader, the server says
--               whether the player is at it
--   7. busy     the lane's cycle is not running: a press during one is not
--               taken (owner, 2026-10-24)
--
-- Each refusal is counted per reason on the match, for `brgate list`.

--- Take one press. Public so the suites can step it.
--- @param src integer
--- @param d table
--- @param now number
--- @return string  'open', or the refusal's reason
function G.use(src, d, now)
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    local function no(reason)
        count(m, reason)
        return reason
    end
    if not on() then return no('season') end

    local idx = type(d) == 'table' and type(d.reader) == 'number' and math.tointeger(d.reader) or nil
    local r = idx and (parts().readers or {})[idx] or nil
    local z = r and zones()[r.lane]
    local first = z and z.readers[idx]
    if not r or not laneRow(r.lane) or not first then return no('shape') end

    local U = cfg().use or {}
    local last = lastAt[src]
    if last and now - last < (U.minIntervalMs or 1000) then return no('rate') end
    lastAt[src] = now
    if m then
        local st = stateOf(m)
        local k = (st.rate[src] or 0) + 1
        st.rate[src] = k
        if k > (U.perMatch or 120) then return no('rate') end
    end

    local e = BR.Roster.get(src)
    if not m or not e or e.matchId ~= m.id or not underWay(m) then
        return no('match')
    end

    if e.state ~= BR.PlayerState.ALIVE then return no('player') end

    local p = e.pos
    if type(p) ~= 'table' or now - (e.posAt or 0) > (U.sampleMaxAgeMs or 1000) then
        return no('reach')
    end
    local slack = U.reachSlackM or 3.0
    if not GS.readerAt({ r }, p.x, p.y, p.z, (cfg().readerM or 3.0) + slack,
            (cfg().readerZM or 2.5) + slack) then
        return no('reach')
    end
    if GS.inTrap(zones(), p.x, p.y, p.z, cfg().lane) then return no('reach') end

    if GS.busy(stateOf(m).lanes[r.lane]) then return no('busy') end
    G.start(m, r.lane, first, now, ('by %s (%d) at %s'):format(tostring(e.name), src, r.id))
    return 'open'
end

RegisterNetEvent(BR.Net.DCGATE_USE)
AddEventHandler(BR.Net.DCGATE_USE, function(d)
    local src = tonumber(source)
    if src then G.use(src, d, GetGameTimer()) end
end)

-- ------------------------------------------------------------- who is where ---

--- The vehicles in these routing buckets, read off the OneSync pool once:
--- [bucket] = { { x, y, z } }. Every vehicle counts in a swing or a way -- a
--- car somebody drives, one left parked, a wreck, traffic -- because a leaf
--- folds onto all of them alike. Not in the trap: that holds players only.
--- @param want table  [bucket] = true
--- @return table
local function vehiclesIn(want)
    local out = {}
    if type(GetAllVehicles) ~= 'function' then return out end
    local okAll, all = pcall(GetAllVehicles)
    for _, veh in ipairs(okAll and type(all) == 'table' and all or {}) do
        local okB, bucket = pcall(GetEntityRoutingBucket, veh)
        if okB and want[bucket] then
            local okC, c = pcall(GetEntityCoords, veh)
            if okC and c and GS.finite(c.x) and GS.finite(c.y) then
                local list = out[bucket]
                if not list then
                    list = {}
                    out[bucket] = list
                end
                list[#list + 1] = { x = c.x, y = c.y, z = c.z }
            end
        end
    end
    return out
end

--- The match's players a gate waits for: standing or downed, with a sample no
--- older than lane.sampleMaxAgeMs. { { x, y, z } }.
--- @param m table
--- @param now number
--- @return table[]
local function pedsIn(m, now)
    local out = {}
    local maxAge = (cfg().lane or {}).sampleMaxAgeMs or 3000
    BR.Roster.each(function(e) return e.matchId == m.id end, function(_, e)
        local p = e.pos
        if HOLDS[e.state] and type(p) == 'table' and now - (e.posAt or 0) <= maxAge then
            out[#out + 1] = { x = p.x, y = p.y, z = p.z }
        end
    end)
    return out
end

--- WHAT IS IN LANE n's ZONES for this match now (BR.DcGateSolve.occupancy):
--- { trap, outer = { swing, way }, inner = { swing, way } }, each 'a player',
--- 'a vehicle' or nil (the trap a player or nil: an empty car there holds
--- nothing). Public so the suites and `brgate list` can ask.
--- @param m table
--- @param n integer
--- @param vehicles table[]|nil  the match's vehicles, { x, y, z }
--- @param now number
--- @param peds table[]|nil  the match's players (read here when nil)
--- @return table|nil
function G.occupancy(m, n, vehicles, now, peds)
    local z = zones()[n]
    if not z then return nil end
    return GS.occupancy(z, peds or pedsIn(m, now), vehicles, cfg().lane)
end

-- --------------------------------------------------------------- the pass ---

--- THE PASS, every lane.checkMs: every lane whose cycle runs, in a match under
--- way, moved on by who is in its zones (BR.DcGateSolve.advance), and the
--- match told once a pass if any of its lanes changed. An idle lane is not
--- looked at; a match off Season 2 forgets its lanes (every client shut them
--- itself); a match no longer under way is left as it is (it is going away);
--- and the vehicle pool is read only while a cycle runs. Public so the suites
--- can step it.
--- @param now number
function G.pass(now)
    if not (BR.Server and BR.Server.eachMatch) then return end
    local run, buckets = {}, {}
    BR.Server.eachMatch(function(m)
        local st = m.dcgate
        if not st then return end
        if not on() then
            m.dcgate = nil
            return
        end
        if not underWay(m) then return end
        for _, l in ipairs(parts().lanes or {}) do
            local s = st.lanes[l.lane]
            if GS.busy(s) then
                run[#run + 1] = { m = m, st = st, n = l.lane, s = s }
                if m.bucket ~= nil then buckets[m.bucket] = true end
            end
        end
    end)
    if #run == 0 then return end
    local cars = vehiclesIn(buckets)
    local peds, changed, order = {}, {}, {}
    local T = times()
    for _, r in ipairs(run) do
        local list = peds[r.m]
        if not list then
            list = pedsIn(r.m, now)
            peds[r.m] = list
        end
        local occ = G.occupancy(r.m, r.n, r.m.bucket ~= nil and cars[r.m.bucket] or nil, now, list)
        local what = occ and GS.advance(r.s, occ, now, T)
        if what then
            if not changed[r.m] then
                changed[r.m] = true
                order[#order + 1] = r
            end
            print(('[br_core] dcgate: lane %d in match %s: %s'):format(r.n, tostring(r.m.id), what))
        end
    end
    for _, r in ipairs(order) do send(r.m, r.st) end
end

if BR.Sched and BR.Sched.every then
    BR.Sched.every((cfg().lane or {}).checkMs or 500, 'dcgate.pass', function()
        G.pass(GetGameTimer())
    end)
end

AddEventHandler('playerDropped', function()
    local src = tonumber(source)
    if src then lastAt[src] = nil end
end)

-- ---------------------------------------------------------------- the dev ---
--
-- Dev mode only (br_lib/shared/devgate.lua wraps every command), Season 2 only,
-- typed as `brgate` on F8 (client/dcgate.lua) and run here as `brgatesv`:
--
--   brgatesv [list]                    your match's lanes: each cycle, its
--                                      phase and for how long, who is where,
--                                      refused presses
--   brgatesv open <lane|all> [in|out]  start a cycle as that reader would (the
--                                      outside one by default), whoever is where
--   brgatesv close <lane|all>          end a cycle: its open gate folds shut as
--                                      the last, opening again on anybody in
--                                      its swing or the trap
--
-- From the server console, the player id comes last: `brgatesv open 2 12`.

local USAGE = 'brgate [list] | near | open <lane|all> [in|out] | close <lane|all> | drive <lead|arm> <ratio|rotate>'

--- One line on the requester's F8 (or this console), and nowhere else.
local function tell(src, text)
    print(('[br_core] brgate (client %s): %s'):format(tostring(src), text))
    if src > 0 then TriggerClientEvent(BR.Net.DCGATE_DEV, src, text) end
end

local OPENING = { first = true, firstShut = true }

local function devList(src, m, now)
    if not m then
        tell(src, 'no match: the readers work in a match only')
        return
    end
    local st = m.dcgate
    local cars = nil
    local out = {}
    for _, l in ipairs(parts().lanes or {}) do
        local s = st and st.lanes[l.lane]
        local line
        if not GS.busy(s) then
            line = 'idle'
        else
            local g = OPENING[s.phase] and s.first or s.second
            line = ('%s gate %s %.1f s (%s, %s gate)'):format(g,
                (s.phase == 'first' or s.phase == 'second') and 'open' or 'folding shut',
                (now - s.at) / 1000, s.first == 'outer' and 'inbound' or 'outbound',
                OPENING[s.phase] and 'first' or 'second')
            if cars == nil then cars = vehiclesIn({ [m.bucket or -1] = true }) end
            local occ = G.occupancy(m, l.lane, cars[m.bucket or -1], now)
            local held = {}
            if occ then
                if occ.trap then held[#held + 1] = 'the trap: ' .. occ.trap end
                for _, w in ipairs(GS.GATES) do
                    local who = occ[w].swing or occ[w].way
                    if who then
                        held[#held + 1] = ('the %s %s: %s'):format(w, occ[w].swing and 'swing' or 'approach', who)
                    end
                end
            end
            line = line .. (#held > 0 and (', ' .. table.concat(held, ', ')) or ', all clear')
        end
        out[#out + 1] = ('lane %d %s'):format(l.lane, line)
    end
    local refused = {}
    for reason, k in pairs(st and st.refused or {}) do refused[#refused + 1] = reason .. ' ' .. k end
    table.sort(refused)
    tell(src, ('match %s (%s): %s; refused: %s'):format(tostring(m.id), tostring(m.state),
        table.concat(out, '; '), #refused > 0 and table.concat(refused, ', ') or 'none'))
end

--- The lanes a verb names: one number, or every one for `all`.
local function lanesNamed(word)
    if word == 'all' then
        local out = {}
        for _, l in ipairs(parts().lanes or {}) do out[#out + 1] = l.lane end
        return out
    end
    local n = math.tointeger(tonumber(word))
    if n and laneRow(n) then return { n } end
    return nil
end

RegisterCommand('brgatesv', function(source, args)
    local src = tonumber(source) or 0
    args = args or {}
    local verb = args[1] and args[1]:lower() or 'list'
    local words = {}
    for i = 2, #args do words[#words + 1] = args[i] end

    local target = src
    if src == 0 then
        target = tonumber(words[#words]) or 0
        words[#words] = nil
    end
    if target <= 0 or not GetPlayerName(target) then
        tell(src, 'that needs a player. ' .. USAGE)
        return
    end
    if not on() then
        tell(src, ('the gate is Season 2 and this box runs Season %s -- `brseason 2` first')
            :format(tostring(BR.Season and BR.Season.current and BR.Season.current())))
        return
    end
    local m = BR.Server.matchOf(target)
    local now = GetGameTimer()

    if verb == 'list' then
        devList(src, m, now)
        return
    end
    if verb ~= 'open' and verb ~= 'close' then
        tell(src, USAGE)
        return
    end
    if not underWay(m) then
        tell(src, 'that is for a match being played: the readers work in a match only')
        return
    end
    local lanes = lanesNamed(words[1] and words[1]:lower() or '')
    if not lanes then
        tell(src, ('no lane "%s": 1, 2, 3 or all'):format(tostring(words[1])))
        return
    end
    local way = words[2] and words[2]:lower() or 'in'
    if verb == 'open' and way ~= 'in' and way ~= 'out' then
        tell(src, ('no reader "%s": in (outside, the outer gate first) or out (inside, the inner gate first)')
            :format(way))
        return
    end
    local first = way == 'out' and 'inner' or 'outer'
    local st = stateOf(m)
    local did = {}
    for _, n in ipairs(lanes) do
        if verb == 'open' then
            if G.start(m, n, first, now, '(dev)') then did[#did + 1] = n end
        elseif GS.halt(st.lanes[n], now, times()) then
            did[#did + 1] = n
            print(('[br_core] dcgate: lane %d in match %s: its cycle ending (dev)'):format(n, tostring(m.id)))
        end
    end
    if verb == 'close' and #did > 0 then send(m, st) end
    tell(src, #did > 0
        and ('lane %s %s in match %s'):format(table.concat(did, ', '),
            verb == 'open' and (first .. ' gate open') or 'ending its cycle', tostring(m.id))
        or ('nothing to %s: %s'):format(verb, verb == 'open' and 'its cycle runs' or 'no cycle runs'))
end)
