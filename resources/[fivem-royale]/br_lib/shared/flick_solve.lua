-- Flick cameras (#419): THE RULES BOTH SIDES READ.
--
-- PURE, AND IN br_lib, as every solver the two halves share: the server decides
-- by these and the client draws by them, so there is one spelling of each and
-- the suites drive it without a native, a clock or a roster.
--
--   BR.FlickSolve.grid(rows, cellM)     the registry in cells, built once a
--                                       resource start on each side
--   BR.FlickSolve.near(grid, x, y, r, fn)
--                                       every row within r of a point, flat
--   BR.FlickSolve.covers(grid, down, x, y, inVehicle, cfg)
--                                       does a live camera see a player there:
--                                       Scan's rule and the coverage circles'
--   BR.FlickSolve.downed(probe, row, c) has the camera this client reads gone
--                                       down, and why
--   BR.FlickSolve.reach(by, cause, report)
--                                       how far from a camera its reporter may
--                                       stand, by what the report says
--   BR.FlickSolve.validId(id)           an id's shape: a whole number 1..9999
--
-- FLAT (2D) WHEREVER IT SAYS "within": what Scan sends is exactly what the
-- circles on the big map show, and a player on a roof, in the air or in a
-- basement is judged where the map puts them. The one 3D distance is the
-- server's reach, which is about where a body stands to shoot or ram.

BR = BR or {}
BR.FlickSolve = BR.FlickSolve or {}

local FS = BR.FlickSolve

--- A cell's key: two whole numbers in one string, so the grid is one flat table.
local function key(cx, cy)
    return cx .. ':' .. cy
end

--- A number that is a number: not NaN, not either infinity.
local function finite(v)
    return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge
end

--- Is `id` an id the registry can hold? A whole number from 1 to 9999, never
--- the array index -- docs/flick.md, "The registry".
--- @param id any
--- @return boolean
function FS.validId(id)
    if type(id) ~= 'number' then return false end
    local n = math.tointeger(id)
    return n ~= nil and n >= 1 and n <= 9999
end

--- The registry in cells of `cellM`: [key] = { row index, ... }, and `byId`
--- each id's row index. Rows that are not a camera (no finite x and y, an id
--- that is not one) are left out, so no reader trips on one.
--- @param rows table[]  BR.Config.Flick.cameras
--- @param cellM number
--- @return table  { cell, cells, rows, byId, n }
function FS.grid(rows, cellM)
    local cell = tonumber(cellM) or 150.0
    if cell <= 0 then cell = 150.0 end
    local g = { cell = cell, cells = {}, rows = rows or {}, byId = {}, n = 0 }
    for i, r in ipairs(g.rows) do
        local x, y = r.x, r.y
        if FS.validId(r.id) and finite(x) and finite(y) and g.byId[r.id] == nil then
            local k = key(math.floor(x / cell), math.floor(y / cell))
            local list = g.cells[k]
            if not list then
                list = {}
                g.cells[k] = list
            end
            list[#list + 1] = i
            g.byId[r.id] = i
            g.n = g.n + 1
        end
    end
    return g
end

--- The row with this id, or nil.
--- @param g table
--- @param id integer
--- @return table|nil
function FS.row(g, id)
    local i = g and g.byId[id]
    return i and g.rows[i] or nil
end

--- Call fn(row, d2) for every row within `r` of (x, y), flat, in no promised
--- order: a caller that wants the nearest compares d2 itself. Returning true
--- from fn stops the walk.
--- @param g table
--- @param x number
--- @param y number
--- @param r number
--- @param fn fun(row: table, d2: number): boolean|nil
function FS.near(g, x, y, r, fn)
    if not g or g.n == 0 then return end
    local cell = g.cell
    local span = math.ceil(r / cell)
    local cx, cy = math.floor(x / cell), math.floor(y / cell)
    local r2 = r * r
    local rows = g.rows
    for dx = -span, span do
        for dy = -span, span do
            local list = g.cells[key(cx + dx, cy + dy)]
            if list then
                for j = 1, #list do
                    local row = rows[list[j]]
                    local ex, ey = row.x - x, row.y - y
                    local d2 = ex * ex + ey * ey
                    if d2 <= r2 and fn(row, d2) then return end
                end
            end
        end
    end
end

--- The flat distance to the nearest LIVE camera within `r` of (x, y), or nil.
--- `down` is [id] = anything for every camera down; nil is none.
--- @param g table
--- @param down table|nil
--- @param x number
--- @param y number
--- @param r number
--- @return number|nil
function FS.nearestLive(g, down, x, y, r)
    local best = nil
    FS.near(g, x, y, r, function(row, d2)
        if (down == nil or down[row.id] == nil) and (best == nil or d2 < best) then best = d2 end
    end)
    return best and math.sqrt(best) or nil
end

--- DOES A LIVE CAMERA SEE A PLAYER AT (x, y)? One within `cfg.rangeM` (75 m),
--- or within `cfg.vehicleRangeM` (150 m) while they ride a vehicle -- any seat.
---
--- ON FOOT ANSWERS FIRST AND FOR NOTHING. `inVehicle` may be a boolean or a
--- function, and a function is asked only for a player inside the vehicle
--- range of a live camera and outside the foot range of every one: the
--- server's seat read is the dearest thing here, and most players never need
--- it.
--- @param g table
--- @param down table|nil
--- @param x number
--- @param y number
--- @param inVehicle boolean|fun(): boolean
--- @param cfg table|nil  { rangeM, vehicleRangeM }; nil is BR.Config.Flick
--- @return boolean
function FS.covers(g, down, x, y, inVehicle, cfg)
    cfg = cfg or (BR.Config and BR.Config.Flick) or {}
    local foot = tonumber(cfg.rangeM) or 75.0
    local veh = tonumber(cfg.vehicleRangeM) or 150.0
    local d = FS.nearestLive(g, down, x, y, math.max(foot, veh))
    if d == nil then return false end
    if d <= foot then return true end
    if d > veh then return false end
    if type(inVehicle) == 'function' then return inVehicle() == true end
    return inVehicle == true
end

--- HAS THIS CAMERA GONE DOWN, by what this client reads of its own copy?
---
---   broken   HasObjectBeenBroken: a group torn off -- the pole by a car, the
---            camera or its panel by a bullet. THE signal for both causes
---            (PROP.md 6: the ymap's handle stays at the base when the pole
---            snaps, and a shot breaks a part off).
---   tilted   upright by less than cos(c.tiltDownDeg)
---   moved    more than c.movedDownM from its row, flat
---   health   c.healthLossDown or more lost from the health it was first read
---            at, once the prop is measured (off while nil)
---
--- A plain table in and a reason out, so the suites drive it without natives.
--- @param probe table  { broken, upright, x, y, z, health, maxHealth }
--- @param row table    the registry row
--- @param c table|nil  BR.Config.Flick.client
--- @return string|nil  'broken' | 'tilted' | 'moved' | 'health'
function FS.downed(probe, row, c)
    if type(probe) ~= 'table' or type(row) ~= 'table' then return nil end
    c = c or {}
    if probe.broken == true then return 'broken' end
    local up = tonumber(probe.upright)
    local tilt = tonumber(c.tiltDownDeg) or 30.0
    if up and up < math.cos(math.rad(tilt)) then return 'tilted' end
    local x, y = tonumber(probe.x), tonumber(probe.y)
    local moved = tonumber(c.movedDownM) or 0.75
    if x and y then
        local dx, dy = x - row.x, y - row.y
        if dx * dx + dy * dy > moved * moved then return 'moved' end
    end
    local loss = tonumber(c.healthLossDown)
    local hp, max = tonumber(probe.health), tonumber(probe.maxHealth)
    if loss and hp and max and max - hp >= loss then return 'health' end
    return nil
end

--- HOW FAR FROM ITS CAMERA A REPORT MAY COME FROM, 3D, by the server's own
--- sample of the reporter: an `other` report (a bystander who saw it fall) at
--- `reach.other`; a `me` report by its cause -- a ram at `reach.vehicle`, a
--- shot at `reach.weapon`.
--- @param by string      'me' | 'other'
--- @param cause string|nil  'weapon' | 'vehicle'
--- @param report table|nil  BR.Config.Flick.report
--- @return number
function FS.reach(by, cause, report)
    local reach = (report and report.reach) or {}
    if by ~= 'me' then return tonumber(reach.other) or 400.0 end
    if cause == 'vehicle' then return tonumber(reach.vehicle) or 25.0 end
    return tonumber(reach.weapon) or 400.0
end
