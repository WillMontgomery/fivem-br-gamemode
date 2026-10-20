-- The data center's main gate (#420): the shared rules. One spelling of "which
-- reader is this player at", "is this point in the lane", the fold's pose and
-- the bi-fold's counter-rotation, for the server, the client and the suites.
-- Pure Lua; it reads nothing at load (BR.Config.DcGate at call time, and only
-- through its arguments). The contract is docs/dcgate.md.

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
-- ═══ A LANE'S POSE IS ONE NUMBER, 0 SHUT TO 1 OPEN ═══
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
