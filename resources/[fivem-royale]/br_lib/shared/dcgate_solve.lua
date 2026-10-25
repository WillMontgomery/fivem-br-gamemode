-- The data center's main gate (#420): the shared rules. One spelling of "which
-- reader is this player at", "is this point in the lane", the fold's pose and
-- the bi-fold's counter-rotation, each lane's zones (its trap and each gate's
-- swing and approach, derived from the parts), the sally port's sequence and
-- the wire's lane code, for the server, the client and the suites. Pure Lua;
-- it reads nothing at load (BR.Config.DcGate at call time, and only through
-- its arguments). The contract is docs/dcgate.md.

BR = BR or {}
BR.DcGateSolve = BR.DcGateSolve or {}

local S = BR.DcGateSolve

--- The door system's name for one part, as the br_datacenter pack named it
--- (its DOOR_LOCKS: GetHashKey('brdc_door_' .. id)), so a pack that still
--- registers a part and this gamemode talk about one door, not two.
S.DOOR_PREFIX = 'brdc_door_'

--- @param id string
--- @return string
function S.doorName(id)
    return S.DOOR_PREFIX .. tostring(id)
end

local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end
S.finite = finite

--- An angle in degrees brought into -180..180.
--- @param d number
--- @return number
function S.wrap180(d)
    d = (d + 180.0) % 360.0
    if d < 0 then d = d + 360.0 end
    return d - 180.0
end

-- ------------------------------------------------------------- the pose ---
--
-- ═══ A GATE'S POSE IS ONE NUMBER, 0 SHUT TO 1 OPEN ═══
--
-- It moves linearly in time (S.step) and every angle is read from it through
-- S.ease, so a fold starts and stops gently, and a fold turned back halfway
-- runs back from exactly where the leaves are: the angle is a function of the
-- pose alone, so it cannot jump.

--- Smoothstep: 0 at 0, 1 at 1, flat at both ends.
--- @param p number
--- @return number
function S.ease(p)
    if p <= 0 then return 0.0 end
    if p >= 1 then return 1.0 end
    return p * p * (3.0 - 2.0 * p)
end

--- The pose dtMs later, moving toward target (0 or 1) at a whole fold per foldMs.
--- @param pose number
--- @param target number
--- @param dtMs number
--- @param foldMs number
--- @return number
function S.step(pose, target, dtMs, foldMs)
    local d = (tonumber(dtMs) or 0) / math.max(1, tonumber(foldMs) or 1)
    if d <= 0 then return pose end
    if pose < target then
        return math.min(target, pose + d)
    elseif pose > target then
        return math.max(target, pose - d)
    end
    return pose
end

--- How far a lead has turned at this pose, signed the kit's way: +1 leads open
--- by +theta about local +z, -1 leads by -theta.
--- @param sense integer
--- @param pose number
--- @param foldDeg number
--- @return number degrees
function S.leadTurn(sense, pose, foldDeg)
    return (sense or 1) * (foldDeg or 90.0) * S.ease(pose)
end

--- THE BI-FOLD: the follower rides its lead's knuckle and turns `turn` times
--- the lead's own turn (the kit: -2, so its free end stays on the gate line as
--- the knuckle swings out and the two halves fold flat at 90). Read from where
--- the lead REALLY is -- its heading now against its placed heading -- so the
--- pair stays folded together whatever the lead's drive did.
--- @param leadHeadingNow number
--- @param leadHeadingPlaced number
--- @param turn number
--- @return number degrees, the follower's attach rotation about z
function S.followerYaw(leadHeadingNow, leadHeadingPlaced, turn)
    return (turn or -2) * S.wrap180(leadHeadingNow - leadHeadingPlaced)
end

--- The arm's raise at this pose.
--- @param pose number
--- @param raiseDeg number
--- @return number degrees
function S.armRaise(pose, raiseDeg)
    return (raiseDeg or 85.0) * S.ease(pose)
end

--- The door system's open ratio for a turn of `deg`: `sign` * deg / ratioDeg,
--- kept in -1..1.
--- @param deg number
--- @param ratioDeg number
--- @param sign number
--- @return number
function S.ratio(deg, ratioDeg, sign)
    local r = (sign or 1) * deg / math.max(1e-6, ratioDeg or 90.0)
    if r > 1 then return 1.0 end
    if r < -1 then return -1.0 end
    return r
end

--- The rotation (x, y, z degrees, GTA's rotation order 2) that turns the arm
--- about its local `axis` by `sense` times the raise -- the 'rotate' drive's.
--- Order 2 turns about local y, then x, then the heading about z, so a turn
--- about local x or y is a pitch or a roll under the placed heading.
--- @param arm table  { h, axis, sense }
--- @param raise number
--- @return number, number, number
function S.armRotation(arm, raise)
    local a = (arm.sense or -1) * raise
    if arm.axis == 'x' then return a, 0.0, arm.h end
    if arm.axis == 'z' then return 0.0, 0.0, arm.h + a end
    return 0.0, a, arm.h
end

-- --------------------------------------------------------------- places ---

--- The reader a player at (x, y, z) stands at: the nearest within rM flat and
--- zM of its height. Nil when none is.
--- @param readers table[]
--- @return integer|nil index, table|nil row
function S.readerAt(readers, x, y, z, rM, zM)
    if not (finite(x) and finite(y)) then return nil end
    local best, bestI, bestD = nil, nil, rM * rM
    for i, r in ipairs(readers or {}) do
        local dx, dy = x - r.x, y - r.y
        local d2 = dx * dx + dy * dy
        if d2 <= bestD and (not finite(z) or math.abs(z - r.z) <= zM) then
            best, bestI, bestD = r, i, d2
        end
    end
    return bestI, best
end

--- Is (x, y, z) in a lane's box, grown by margin along it (past its ends) and
--- by side across it (past its sides; margin when nil), from below under its
--- grade to above over it?
--- @param box table  { x, y, ux, uy, halfLength, halfWidth, zLow, zHigh }
--- @return boolean
function S.inBox(box, x, y, z, margin, below, above, side)
    if not (finite(x) and finite(y)) then return false end
    local dx, dy = x - box.x, y - box.y
    local along = dx * box.ux + dy * box.uy
    local across = -dx * box.uy + dy * box.ux
    margin = margin or 0
    if side == nil then side = margin end
    if math.abs(along) > box.halfLength + margin or math.abs(across) > box.halfWidth + side then
        return false
    end
    if finite(z) and (z < box.zLow - (below or 0) or z > box.zHigh + (above or 0)) then
        return false
    end
    return true
end

--- Is (x, y) within `extra` of the gate, flat: inside its radius from its
--- middle, plus extra?
--- @param parts table  BR.Config.DcGate.parts
--- @return boolean
function S.near(parts, x, y, extra)
    local c = parts and parts.center
    if not c or not (finite(x) and finite(y)) then return false end
    local r = (parts.radius or 0) + (extra or 0)
    local dx, dy = x - c.x, y - c.y
    return dx * dx + dy * dy <= r * r
end

--- The lanes, by number: [n] = the lane's row. Built per call; the callers
--- keep it.
--- @param parts table
--- @return table
function S.byLane(parts)
    local out = {}
    for _, l in ipairs(parts and parts.lanes or {}) do out[l.lane] = l end
    return out
end

--- How far a rotation read back (GetEntityRotation, order 2) is from the one
--- set, in degrees: the worst of its three angles, each wrapped. A turn has two
--- spellings in Euler angles -- (x, y, z) and (180 - x, y + 180, z + 180) under
--- order 2, whose middle turn is x -- so the nearer of the two is taken: a part
--- the engine hands back spelled the other way is not off.
--- @return number degrees
function S.rotationOff(wx, wy, wz, gx, gy, gz)
    local function worst(ax, ay, az)
        return math.max(math.abs(S.wrap180(ax - gx)), math.abs(S.wrap180(ay - gy)), math.abs(S.wrap180(az - gz)))
    end
    return math.min(worst(wx, wy, wz), worst(180.0 - wx, wy + 180.0, wz + 180.0))
end

-- ------------------------------------------------------------ the gates ---
--
-- ═══ A LANE IS TWO GATES AND A TRAP (owner, 2026-10-24) ═══
--
-- The outer gate (its crash arm outside it) and the inner gate, the trap
-- between them. A part's gate is in its id, which tools/dcgate_parts.py writes
-- and refuses a table without: gate.lane<n>.<outer|inner>.<role>, and the arm
-- gate.lane<n>.outer_arm.arm -- the outer gate's.

S.GATES = { 'outer', 'inner' }
S.OTHER = { outer = 'inner', inner = 'outer' }

--- The gate a part moves with: 'outer' or 'inner' (nil for an id of neither).
--- @param id string
--- @return string|nil
function S.gateOf(id)
    local w = tostring(id):match('^gate%.lane%d+%.(%a+)')
    if w == 'outer' or w == 'inner' then return w end
    return nil
end

-- ------------------------------------------------------------ the zones ---
--
-- ═══ EVERY ZONE IS A STRIP OF THE LANE, DERIVED FROM THE PARTS ═══
--
-- Along the lane's box (its direction ux, uy runs from the outer gate to the
-- inner one), post to post across it, at its grade. Nothing here is a typed
-- coordinate:
--
--   the gate lines   each gate's two lead hinges, along the lane
--   the trap         from the outer gate's line to the inner gate's
--   a gate's swing   from its line out past its fold -- the leaf's length (the
--                    followers' knuckle offset) to the side its leads fold to
--                    (their local +y) -- to the box's end on that side, and for
--                    the outer gate past its arm's beam: the arm comes down
--                    with that gate
--   a gate's way     its swing and the approach beyond it, out to the reader
--                    on that side of it: the ground a first gate waits on
--
-- A gate folds away from the trap (the generator refuses one that does not),
-- so the trap and the swings meet at the gate lines and never overlap.

--- A strip of the box b from a0 to a1 along it, as a box S.inBox reads.
local function strip(b, a0, a1)
    if a0 > a1 then a0, a1 = a1, a0 end
    local mid = (a0 + a1) / 2.0
    return { x = b.x + b.ux * mid, y = b.y + b.uy * mid, ux = b.ux, uy = b.uy,
             halfLength = (a1 - a0) / 2.0, halfWidth = b.halfWidth, zLow = b.zLow, zHigh = b.zHigh,
             a0 = a0, a1 = a1 }
end

--- One lane's zones and its readers' gates, from its row and the readers:
---   line     [gate] = the gate's line, along the box (meters from its middle)
---   trap     the strip between the two lines
---   outer, inner   { swing, way }: strips
---   all      one strip over every zone: the ground worth looking at
---   readers  [reader index] = the gate a press there opens first: the gate
---            the reader stands beyond
--- Nil for a row without a lead of each gate.
--- @param row table  a lane of BR.Config.DcGate.parts
--- @param readers table[]  BR.Config.DcGate.parts.readers
--- @return table|nil
function S.laneZones(row, readers)
    local b = row and row.box
    if not b then return nil end
    local function along(x, y) return (x - b.x) * b.ux + (y - b.y) * b.uy end
    local sum, k, side, leaf = { outer = 0.0, inner = 0.0 }, { outer = 0, inner = 0 }, {}, { outer = 0.0, inner = 0.0 }
    for _, l in ipairs(row.leads or {}) do
        local g = S.gateOf(l.id)
        if g then
            sum[g], k[g] = sum[g] + along(l.x, l.y), k[g] + 1
            if side[g] == nil then
                -- The leaf's local +y in the world, against the lane's direction.
                local r = math.rad(l.h or 0.0)
                side[g] = (-math.sin(r) * b.ux + math.cos(r) * b.uy) >= 0 and 1 or -1
            end
        end
    end
    for _, f in ipairs(row.follows or {}) do
        local l = row.leads and row.leads[f.lead]
        local g = l and S.gateOf(l.id)
        if g then leaf[g] = math.max(leaf[g], math.sqrt((f.ox or 0) ^ 2 + (f.oy or 0) ^ 2)) end
    end
    local z = { line = {}, readers = {} }
    for _, g in ipairs(S.GATES) do
        if k[g] == 0 then return nil end
        z.line[g] = sum[g] / k[g]
    end
    z.trap = strip(b, z.line.outer, z.line.inner)
    local lo, hi = math.huge, -math.huge
    for _, g in ipairs(S.GATES) do
        local line, s = z.line[g], side[g]
        local reach = { line, line + s * leaf[g], s * b.halfLength }
        if row.arm and S.gateOf(row.arm.id) == g then reach[#reach + 1] = along(row.arm.x, row.arm.y) end
        local a0, a1 = math.huge, -math.huge
        for _, a in ipairs(reach) do a0, a1 = math.min(a0, a), math.max(a1, a) end
        local w0, w1 = a0, a1
        for i, r in ipairs(readers or {}) do
            if r.lane == row.lane then
                local a = along(r.x, r.y)
                if (a - line) * s > 0 then
                    z.readers[i] = g
                    w0, w1 = math.min(w0, a), math.max(w1, a)
                end
            end
        end
        z[g] = { swing = strip(b, a0, a1), way = strip(b, w0, w1) }
        lo, hi = math.min(lo, w0), math.max(hi, w1)
    end
    z.all = strip(b, lo, hi)
    return z
end

--- Every lane's zones: [n] = S.laneZones. Built per call; the callers keep it.
--- @param parts table
--- @return table
function S.zones(parts)
    local out = {}
    for _, row in ipairs(parts and parts.lanes or {}) do
        out[row.lane] = S.laneZones(row, parts.readers)
    end
    return out
end

--- Is (x, y, z) in any lane's trap -- between its gate lines, post to post,
--- from L.belowM under its grade to L.aboveM over it? No reader is in reach
--- from there (the owner, 2026-10-19: no reader in the trap).
--- @param zones table  S.zones
--- @param L table|nil  BR.Config.DcGate.lane
--- @return boolean
function S.inTrap(zones, x, y, z, L)
    L = L or {}
    for _, lz in pairs(zones or {}) do
        if lz.trap and S.inBox(lz.trap, x, y, z, 0, L.belowM or 1.0, L.aboveM or 4.5) then return true end
    end
    return false
end

--- WHAT IS IN A LANE'S ZONES, from the server's own samples: { trap, outer =
--- { swing, way }, inner = { swing, way } }, each 'a player', 'a vehicle' or
--- nil. A player's point counts within L.pedMarginM of a zone; a vehicle's
--- center within L.vehicleMarginM past its ends (a car's half-length, so a
--- bumper under a leaf counts) and L.vehicleSideM past its sides (its
--- half-width); both from L.belowM under the grade to L.aboveM over it.
---
--- THE TRAP HOLDS PLAYERS ONLY (the owner's "the trap holds someone"): a car
--- left or wrecked in a trap would otherwise hold that lane's second gate open
--- and refuse its readers for the rest of the match. A driver counts by their
--- own sample. Vehicles still count in every swing and way, so no gate closes
--- on a car.
--- @param z table  S.laneZones
--- @param peds table[]|nil  { x, y, z }: the match's players who hold a gate
--- @param vehicles table[]|nil  { x, y, z }: the match's vehicles
--- @param L table|nil  BR.Config.DcGate.lane
--- @return table
function S.occupancy(z, peds, vehicles, L)
    L = L or {}
    local pm, vm, vs = L.pedMarginM or 0.5, L.vehicleMarginM or 2.5, L.vehicleSideM or 1.0
    local below, above = L.belowM or 1.0, L.aboveM or 4.5
    local P, V = {}, {}
    for _, p in ipairs(peds or {}) do
        if S.inBox(z.all, p.x, p.y, p.z, pm, below, above) then P[#P + 1] = p end
    end
    for _, v in ipairs(vehicles or {}) do
        if S.inBox(z.all, v.x, v.y, v.z, vm, below, above, vs) then V[#V + 1] = v end
    end
    local function held(box, playersOnly)
        for _, p in ipairs(P) do
            if S.inBox(box, p.x, p.y, p.z, pm, below, above) then return 'a player' end
        end
        if playersOnly then return nil end
        for _, v in ipairs(V) do
            if S.inBox(box, v.x, v.y, v.z, vm, below, above, vs) then return 'a vehicle' end
        end
        return nil
    end
    local out = { trap = held(z.trap, true) }
    for _, g in ipairs(S.GATES) do
        out[g] = { swing = held(z[g].swing), way = held(z[g].way) }
    end
    return out
end

-- ------------------------------------------------------- the sally port ---
--
-- ═══ THE SEQUENCE (owner, 2026-10-24), ONE LANE ═══
--
--   idle        both gates shut. A press at a reader opens the gate it stands
--               beyond (the outside reader: the outer gate and its arm; the
--               inside one: the inner gate) -> first
--   first       the first gate open. Once it is fully open (foldMs):
--                 someone in the trap, and its swing and approach clear for
--                 closeDelayMs -> firstShut
--                 nobody in the trap abandonMs after it opened, and its swing
--                 clear for closeDelayMs -> firstShut (the cycle will end)
--   firstShut   the first gate folding shut. Anybody in its swing -> first,
--               open again. Fully shut (foldMs): someone in the trap ->
--               second; nobody -> idle
--   second      the second gate open. Once it is fully open: the trap and its
--               swing clear for closeDelayMs -> secondShut
--   secondShut  the second gate folding shut. Anybody in its swing or the trap
--               -> second, open again. Fully shut -> idle
--
-- "Someone in the trap" is a player (S.occupancy): an empty car there holds
-- nothing. A gate never closes on a player or a vehicle in its swing; a press
-- while the cycle runs (any phase but idle) is not taken. A clear spell is counted from
-- when its zone went clear but never from before the gate was fully open, so a
-- gate always stands fully open for closeDelayMs before it starts back.
--
-- Each gate keeps { open, at, from }: open or shut, since when, and its pose
-- then, so its pose at any moment is S.gatePose -- for a late joiner.

S.PHASES = { 'idle', 'first', 'firstShut', 'second', 'secondShut' }

--- A lane at rest: idle, both gates shut.
--- @return table
function S.newLane()
    return {
        phase = 'idle', first = nil, second = nil, at = 0,
        wayAt = nil, swingAt = nil, clearAt = nil,
        outer = { open = false, at = 0, from = 0.0 },
        inner = { open = false, at = 0, from = 0.0 },
    }
end

--- A gate's pose now: moving from where it was when it last changed toward
--- open or shut, a whole fold per foldMs.
--- @param g table  { open, at, from }
--- @param now number
--- @param foldMs number
--- @return number
function S.gatePose(g, now, foldMs)
    return S.step(g.from or 0.0, g.open and 1.0 or 0.0, now - (g.at or 0), foldMs)
end

local function setGate(s, which, open, now, foldMs)
    local g = s[which]
    if g.open == open then return end
    g.from = S.gatePose(g, now, foldMs)
    g.open, g.at = open, now
end

--- Into a phase: its gate open and the other shut, the clear spells forgotten.
local function enter(s, phase, now, T)
    s.phase, s.at = phase, now
    s.wayAt, s.swingAt, s.clearAt = nil, nil, nil
    local open = {}
    if phase == 'first' then
        open[s.first] = true
    elseif phase == 'second' then
        open[s.second] = true
    end
    for _, w in ipairs(S.GATES) do setGate(s, w, open[w] == true, now, T.foldMs or 4000) end
    if phase == 'idle' then s.first, s.second = nil, nil end
end

--- Is the lane's cycle running (any phase but idle)?
--- @param s table
--- @return boolean
function S.busy(s)
    return s ~= nil and s.phase ~= 'idle'
end

--- A PRESS: an idle lane opens `gate` first. False (nothing changed) while
--- the cycle runs, or for a gate that is not one.
--- @param s table
--- @param gate string  'outer' or 'inner'
--- @param now number
--- @param T table  { foldMs, closeDelayMs, abandonMs }
--- @return boolean
function S.press(s, gate, now, T)
    if S.busy(s) or not S.OTHER[gate] then return false end
    s.first, s.second = gate, S.OTHER[gate]
    enter(s, 'first', now, T)
    return true
end

--- A clear spell: since when `held` stopped, kept while it stays clear; nil
--- while held.
local function spell(since, held, now)
    if held then return nil end
    return since or now
end

--- How long a spell has run, counted from no earlier than `ready`; -1 for none.
local function lasted(since, ready, now)
    if since == nil then return -1 end
    return now - math.max(since, ready)
end

--- ONE STEP OF THE SEQUENCE: the lane moved on by what is in its zones now
--- (S.occupancy). The words for the console line when it changed; nil when
--- it did not.
--- @param s table
--- @param occ table
--- @param now number
--- @param T table  { foldMs, closeDelayMs, abandonMs }
--- @return string|nil
function S.advance(s, occ, now, T)
    if not S.busy(s) then return nil end
    local fold, delay = T.foldMs or 4000, T.closeDelayMs or 2000
    local trap = occ.trap
    if s.phase == 'first' then
        local g = s.first
        local z = occ[g] or {}
        s.wayAt = spell(s.wayAt, z.swing or z.way, now)
        s.swingAt = spell(s.swingAt, z.swing, now)
        local ready = s.at + fold
        if now < ready then return nil end
        if trap and lasted(s.wayAt, ready, now) >= delay then
            enter(s, 'firstShut', now, T)
            return ('%s gate shutting behind %s in the trap'):format(g, trap)
        end
        if not trap and now - s.at >= (T.abandonMs or 10000) and lasted(s.swingAt, ready, now) >= delay then
            enter(s, 'firstShut', now, T)
            return ('%s gate shutting: nobody came into the trap'):format(g)
        end
    elseif s.phase == 'firstShut' then
        local g = s.first
        local z = occ[g] or {}
        if z.swing then
            enter(s, 'first', now, T)
            return ('%s gate open again: %s in its swing'):format(g, z.swing)
        end
        if now - s.at >= fold then
            if trap then
                local h = s.second
                enter(s, 'second', now, T)
                return ('%s gate shut, %s gate open: %s in the trap'):format(g, h, trap)
            end
            enter(s, 'idle', now, T)
            return ('%s gate shut, nobody in the trap: the cycle is over'):format(g)
        end
    elseif s.phase == 'second' then
        local g = s.second
        local z = occ[g] or {}
        s.clearAt = spell(s.clearAt, trap or z.swing, now)
        local ready = s.at + fold
        if now >= ready and lasted(s.clearAt, ready, now) >= delay then
            enter(s, 'secondShut', now, T)
            return ('%s gate shutting: the trap and its swing are clear'):format(g)
        end
    elseif s.phase == 'secondShut' then
        local g = s.second
        local z = occ[g] or {}
        local who = z.swing or trap
        if who then
            enter(s, 'second', now, T)
            return ('%s gate open again: %s in %s'):format(g, who, z.swing and 'its swing' or 'the trap')
        end
        if now - s.at >= fold then
            enter(s, 'idle', now, T)
            return ('%s gate shut: the cycle is over'):format(g)
        end
    end
    return nil
end

--- THE DEV'S STOP: whatever gate is open or folding shut folds shut as the
--- cycle's last, so the cycle ends once it is (it still opens again on
--- anybody in its swing or the trap). False for a lane idle or already ending.
--- @param s table
--- @param now number
--- @param T table
--- @return boolean
function S.halt(s, now, T)
    if s.phase == 'first' or s.phase == 'firstShut' then
        local g = s.first
        s.first, s.second = S.OTHER[g], g
        if s.phase == 'first' then
            enter(s, 'secondShut', now, T)
        else
            s.phase = 'secondShut'
        end
        return true
    elseif s.phase == 'second' then
        enter(s, 'secondShut', now, T)
        return true
    end
    return false
end

-- ------------------------------------------------------------- the wire ---
--
-- ═══ ONE SMALL NUMBER A LANE ═══
--
-- DCGATE_STATE and the snapshot carry each lane as 1 (the outer gate open) +
-- 2 (the inner gate open) + 4 (its cycle running): 0 idle, 5 an inbound
-- cycle's outer gate open, 4 a gate folding shut mid-cycle, and so on.

--- @param s table|nil
--- @return integer
function S.code(s)
    if not s then return 0 end
    return (s.outer.open and 1 or 0) + (s.inner.open and 2 or 0) + (S.busy(s) and 4 or 0)
end

--- A lane's code read back: { outer, inner, busy }, or nil for anything that
--- is not a whole number 0-7.
--- @param c any
--- @return table|nil
function S.decode(c)
    local n = type(c) == 'number' and math.tointeger(c) or nil
    if not n or n < 0 or n > 7 then return nil end
    return { outer = n % 2 == 1, inner = (n // 2) % 2 == 1, busy = (n // 4) % 2 == 1 }
end
