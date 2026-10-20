-- The data center's main gate (#420), Season 2, server half: EVERY LANE IS
-- DECIDED HERE.
--
-- The campus's front gate has three lanes (br_lib/config/dcgate_parts.lua),
-- each a crash arm, an outer bi-fold gate, a trap and an inner bi-fold gate,
-- with a reader at the curb at each end. The whole contract is docs/dcgate.md.
-- This file holds:
--
--   the lanes     this match's: open or shut, since when, until when -- on the
--                 match, so every match starts with every lane shut, and two
--                 matches at once each have their own
--   the door      DCGATE_USE, a player at a reader asking for its lane, taken
--                 only in its order (below) and silent otherwise
--   the clock     a lane open 20 s folds shut, but not while a player or a
--                 vehicle is in it; a lane folding shut on somebody opens again
--   who is told   DCGATE_STATE to the whole match on every change, and the
--                 snapshot's view for a late joiner or a restarted client
--   the dev tools `brgatesv`, typed through `brgate`
--
-- ═══ THE OWNER'S DECISIONS (2026-10-19) ═══
--
--   * Standing at a lane's reader shows "Press E to open the gate"; pressing
--     it opens that whole lane: both gates and the arm.
--   * The lane stays open 20 seconds, then folds shut, but waits while any
--     player or vehicle is still in the lane.
--   * Server-authoritative per match (its routing bucket); clients animate.
--   * Season 2 only; the readers work in a match only.
--
-- ═══ WHO IS IN THE LANE: THE SERVER'S OWN POSITIONS, NOT A CLIENT'S WORD ═══
--
-- A closing gate has to know about everybody, including the players who are
-- nowhere near a client that could report them and the cars nobody sits in. A
-- client report is a claim only about itself (and a modified client could hold
-- a lane open from across the map, or never report the car it parked). The
-- server already has both answers on its own: every player's 4 Hz position
-- sample (server/roster.lua) and, under OneSync, every vehicle's position and
-- routing bucket (GetAllVehicles, the pool server/terminalfx/airstrike.lua
-- reads). So the box test runs here, and only for a lane that is due to close
-- or is closing: nothing at all while every lane is shut, and the vehicle pool
-- read once a pass for all of them.
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

--- Is the gate on, in the season in force? On this side BR.Season.has is the
--- latched season and a few table reads, so the door and the pass ask it as
--- they go.
--- @return boolean
local function on()
    return BR.Season ~= nil and BR.Season.has ~= nil and BR.Season.has('dcgate') == true
end
G.on = on

--- Who a closing lane waits for: a player standing or downed in it.
local HOLDS = {
    [BR.PlayerState.ALIVE] = true,
    [BR.PlayerState.DBNO] = true,
}

--- A match under way: the bus still flying (a player who jumped early is on
--- the ground before the match goes live) or playing. The readers work, and
--- the clock runs, in these.
local UNDER_WAY = {
    [BR.MatchState.BUS] = true,
    [BR.MatchState.PLAYING] = true,
}
local function underWay(m)
    return m ~= nil and UNDER_WAY[m.state] == true
end

--- [n] = the lane's row, built once -- and again only if the registry table
--- itself is replaced (a suite's fixture).
local built = { parts = nil, lanes = nil }

--- @param n integer
--- @return table|nil
local function laneRow(n)
    local p = parts()
    if built.parts ~= p then
        built.parts = p
        built.lanes = GS.byLane(p)
    end
    return built.lanes[n]
end

-- -------------------------------------------------------- the match's lanes ---

--- This match's lanes, made on first use and gone with the match:
---   lanes    [n] = { open, at, holdUntil, closingUntil }: open or not, when
---            that last changed, when an open lane may start to close, and
---            until when a shut one is still folding
---   rate     [src] = presses taken this match
---   refused  [reason] = presses dropped for it
--- @param m table
--- @return table
local function stateOf(m)
    local s = m.dcgate
    if not s then
        s = { lanes = {}, rate = {}, refused = {} }
        for _, l in ipairs(parts().lanes or {}) do
            s.lanes[l.lane] = { open = false, at = 0, holdUntil = 0, closingUntil = 0 }
        end
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

--- Every lane, open or shut: [n] = boolean.
local function openList(st)
    local out = {}
    for _, l in ipairs(parts().lanes or {}) do
        local s = st and st.lanes[l.lane]
        out[l.lane] = s ~= nil and s.open == true
    end
    return out
end

local function payload(m, st)
    return { matchId = m.id, open = openList(st) }
end

--- The whole match is told: the gate is one place every player can drive up
--- to, and three booleans are cheaper than deciding who might.
local function send(m, st)
    BR.Broadcast.toMatch(m, BR.Net.DCGATE_STATE, payload(m, st))
end

--- THE SNAPSHOT'S VIEW (BR.Broadcast.snapshot): this player's match's lanes,
--- `{ matchId, open }`, so a late joiner and a restarted client (br:ready
--- raises the snapshot) see an open lane open. Nil outside a match or off
--- Season 2: the client then holds every lane shut.
--- @param src integer
--- @return table|nil
function G.viewFor(src)
    if not on() then return nil end
    local m = BR.Server and BR.Server.matchOf and BR.Server.matchOf(src) or nil
    if not m then return nil end
    return payload(m, m.dcgate)
end

-- ----------------------------------------------------------- open and shut ---

--- Open a lane: both gates and its arm, for openMs. Public so the suites and
--- the dev verb can open one.
--- @param m table
--- @param n integer
--- @param now number
--- @param why string  for the console line
--- @return boolean  it opened (false: no such lane, or open already)
function G.open(m, n, now, why)
    local st = stateOf(m)
    local s = st.lanes[n]
    if not s or s.open then return false end
    s.open, s.at, s.holdUntil, s.closingUntil = true, now, now + (cfg().openMs or 20000), 0
    send(m, st)
    print(('[br_core] dcgate: lane %d open %s in match %s'):format(n, why, tostring(m.id)))
    return true
end

--- Fold a lane shut. It is still folding for foldMs, and the pass opens it
--- again if somebody is in it meanwhile.
local function shut(m, st, n, s, now, why)
    local held = now - s.at
    s.open, s.at, s.closingUntil = false, now, now + (cfg().foldMs or 4000)
    send(m, st)
    print(('[br_core] dcgate: lane %d folding shut in match %s (%s, open %.1f s)')
        :format(n, tostring(m.id), why, held / 1000))
end

--- A lane folding shut on somebody opens again, and closes the moment it is
--- clear: its 20 seconds were had.
local function reopen(m, st, n, s, now, what)
    s.open, s.at, s.holdUntil, s.closingUntil = true, now, now, 0
    send(m, st)
    print(('[br_core] dcgate: lane %d open again in match %s: %s in it'):format(n, tostring(m.id), what))
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
--               use.reachSlackM: the client says which reader, the server
--               says whether the player is at it
--   7. open     the lane is not open already (a lane folding shut opens
--               again: that is a press on a shut lane)
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
    if not r or not laneRow(r.lane) then return no('shape') end

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

    local s = stateOf(m).lanes[r.lane]
    if not s or s.open then return no('open') end
    G.open(m, r.lane, now, ('by %s (%d) at %s'):format(tostring(e.name), src, r.id))
    return 'open'
end

RegisterNetEvent(BR.Net.DCGATE_USE)
AddEventHandler(BR.Net.DCGATE_USE, function(d)
    local src = tonumber(source)
    if src then G.use(src, d, GetGameTimer()) end
end)

-- -------------------------------------------------------- who is in the lane ---

--- The vehicles in these routing buckets, read off the OneSync pool once:
--- [bucket] = { { x, y, z } }. Every vehicle counts -- a car somebody drives,
--- one left parked, a wreck, traffic -- because a leaf folds onto all of them
--- alike.
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

--- WHAT HOLDS THIS LANE OPEN: 'a player' or 'a vehicle', or nil when it is
--- clear. A player standing or downed in the match whose fresh sample is in
--- the lane's box grown by lane.pedMarginM; any vehicle of the match's bucket
--- whose center is in it grown by lane.vehicleMarginM past its ends and
--- lane.vehicleSideM past its sides. Public so the suites and `brgate list`
--- can ask.
--- @param m table
--- @param n integer
--- @param vehicles table[]|nil  the match's vehicles, { x, y, z }
--- @param now number
--- @return string|nil
function G.holder(m, n, vehicles, now)
    local row = laneRow(n)
    if not row then return nil end
    local L = cfg().lane or {}
    local box, below, above = row.box, L.belowM or 1.0, L.aboveM or 4.5
    local who = nil
    BR.Roster.each(function(e) return e.matchId == m.id end, function(_, e)
        if who then return end
        local p = e.pos
        if HOLDS[e.state] and type(p) == 'table' and now - (e.posAt or 0) <= (L.sampleMaxAgeMs or 3000)
           and GS.inBox(box, p.x, p.y, p.z, L.pedMarginM or 0.5, below, above) then
            who = 'a player'
        end
    end)
    if who then return who end
    for _, v in ipairs(vehicles or {}) do
        if GS.inBox(box, v.x, v.y, v.z, L.vehicleMarginM or 2.5, below, above, L.vehicleSideM or 1.0) then
            return 'a vehicle'
        end
    end
    return nil
end

-- --------------------------------------------------------------- the pass ---

--- THE PASS, every lane.checkMs: an open lane past its time folds shut unless
--- somebody is in it; a lane still folding shut opens again if somebody is. A
--- lane open inside its time, or shut and still, is not looked at; a match off
--- Season 2 forgets its lanes (every client shut them itself); and the vehicle
--- pool is read only when a lane is due. Public so the suites can step it.
--- @param now number
function G.pass(now)
    if not (BR.Server and BR.Server.eachMatch) then return end
    local due, buckets = {}, {}
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
            if s and ((s.open and now >= s.holdUntil) or (not s.open and now < s.closingUntil)) then
                due[#due + 1] = { m = m, st = st, n = l.lane, s = s }
                if m.bucket ~= nil then buckets[m.bucket] = true end
            end
        end
    end)
    if #due == 0 then return end
    local cars = vehiclesIn(buckets)
    for _, d in ipairs(due) do
        local what = G.holder(d.m, d.n, d.m.bucket ~= nil and cars[d.m.bucket] or nil, now)
        if d.s.open and not what then
            shut(d.m, d.st, d.n, d.s, now, 'clear')
        elseif not d.s.open and what then
            reopen(d.m, d.st, d.n, d.s, now, what)
        end
    end
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
--   brgatesv [list]            your match's lanes: open or shut, for how long,
--                              what holds an open one, refused presses
--   brgatesv open <lane|all>   open it as a reader would, whoever is where
--   brgatesv close <lane|all>  fold it shut now, as its clock would: it opens
--                              again on anybody in it
--
-- From the server console, the player id comes last: `brgatesv open 2 12`.

local USAGE = 'brgate [list] | near | open <lane|all> | close <lane|all> | drive <lead|arm> <ratio|rotate>'

--- One line on the requester's F8 (or this console), and nowhere else.
local function tell(src, text)
    print(('[br_core] brgate (client %s): %s'):format(tostring(src), text))
    if src > 0 then TriggerClientEvent(BR.Net.DCGATE_DEV, src, text) end
end

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
        if not s or (not s.open and now >= s.closingUntil) then
            line = 'shut'
        elseif not s.open then
            line = 'folding shut'
        else
            line = ('open %.1f s'):format((now - s.at) / 1000)
            if now < s.holdUntil then
                line = line .. (', closes in %.1f s'):format((s.holdUntil - now) / 1000)
            else
                if cars == nil then cars = vehiclesIn({ [m.bucket or -1] = true }) end
                local what = G.holder(m, l.lane, cars[m.bucket or -1], now)
                line = line .. (what and (', held: ' .. what .. ' in it') or ', closing on the next pass')
            end
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
    local st = stateOf(m)
    local did = {}
    for _, n in ipairs(lanes) do
        local s = st.lanes[n]
        if verb == 'open' and G.open(m, n, now, '(dev)') then
            did[#did + 1] = n
        elseif verb == 'close' and s and s.open then
            shut(m, st, n, s, now, 'dev')
            did[#did + 1] = n
        end
    end
    tell(src, #did > 0
        and ('lane %s %s in match %s'):format(table.concat(did, ', '),
            verb == 'open' and 'open' or 'folding shut', tostring(m.id))
        or ('nothing to %s: %s already'):format(verb, verb == 'open' and 'open' or 'shut'))
end)
