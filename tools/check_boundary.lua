-- Playable-boundary gate.
--
-- The owner surveyed the map edge by hand on 2026-08-28 -- 67 clicks on the
-- pause map, a closed ring, 51.06 km^2 -- and asked for everything outside it to
-- be removed from gameplay. Eight POIs were. This gate is the half that keeps it
-- removed: a config row authored six months from now, at coordinates nobody
-- checks against a map, fails the build here instead of being discovered as a
-- storm closing over the ocean.
--
-- Run via tools/verify.sh, or directly:  lua tools/check_boundary.lua
--
-- ═══ WHAT IT CHECKS, AND WHY EACH ONE ═══
--
--   1. THE RING ITSELF. Vertex count, no repeated closing vertex, no repeated
--      vertex anywhere, and -- the one that matters -- that the ring is SIMPLE.
--      Ray casting is only meaningful on a shape that does not cross itself, and
--      a survey taken by clicking a map is exactly the input that can produce a
--      figure-eight from two points entered out of order. Inside a pinch the
--      containment answer silently INVERTS: it does not error, it just quietly
--      says "outside" for the middle of the island.
--
--   2. THE SURVEY'S OWN NUMBERS. Perimeter, area and centroid are recomputed
--      from the table and compared to what /brsurveydump printed in game. This
--      is what stops the gate being circular. Without it, anybody who wanted a
--      POI back could widen the boundary until it passed, and every check below
--      would go green on a shape the owner never drew. With it, the boundary is
--      pinned to a survey; changing it means re-surveying and re-pinning the
--      figures deliberately, in the same commit, where a reviewer can see it.
--
--   3. EVERY POI CENTRE IS INSIDE. This is the rule the owner stated.
--
--   4. EVERY AMBULANCE SPAWN IS INSIDE. Same class of hand-authored point, and
--      #191 drives a vehicle to one -- an off-map destination is a rescue into
--      the sea. All 23 pass today; the gate is so that stays true.
--
-- ═══ WHAT IT DELIBERATELY DOES NOT CHECK ═══
--
-- Recorded because these were measured and decided, not missed.
--
--   THE BATTLE BUS TOUR. Three of its fifteen authored waypoints are outside
--   the ring -- leg 1 option 1 by 701m, which is the ocean west of Del Perro,
--   and that is the flight working as designed: the bus comes in over water
--   from Cayo Perico. Gating the tour would fail the build over correct data.
--   The storm anchor is not the waypoint anyway -- BR.PickStormAnchor draws a
--   POI near it, and check 3 above is what keeps THAT on the map.
--
--   THE ROAD CORRIDORS. `greatocean` point 1 (-1800, -1200) is 113m outside,
--   beside the Del Perro pier the survey also cut. Roadside filler scattered
--   there would land off-map -- but filler is already gated twice downstream
--   (loot_gen refuses the water rectangles, and the client ground-probes each
--   item and reports wet ones back for relocation), and moving an authored road
--   vertex is a map-data edit nobody asked for. Reported, not enforced.
--
--   THE POI DISC, as opposed to its centre. A 200m radius on a centre 40m
--   inside scatters loot over the edge. Enforcing whole-disc containment would
--   delete fifteen more POIs including Chumash and the Terminal Docks, which
--   the owner walked himself. See the note above BR.Config.Map.POIs.
--
-- So: this gate proves the AUTHORED POINTS are on the map. It does not prove
-- every metre of every radius is, and it never claimed to.

local ROOT = 'resources/[fivem-royale]/br_lib/'
for _, f in ipairs({ 'shared/enums.lua', 'shared/geo.lua', 'shared/polygon.lua',
                     'config/storm.lua', 'config/map.lua' }) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        io.write('\27[31mload error\27[0m ', f, ': ', tostring(err), '\n')
        os.exit(1)
    end
    chunk()
end

local fails = 0
local function fail(fmt, ...)
    fails = fails + 1
    io.write('\27[31mFAIL\27[0m ', string.format(fmt, ...), '\n')
end

local B = BR.Config.Map.Boundary

-- ═══ WHAT THE OWNER'S TOOL PRINTED, 2026-08-28 ═══
--
-- Straight off /brsurveydump. Tolerances are wide enough to absorb the tool's
-- own rounding (it prints one decimal place and the metres it prints are
-- computed from those rounded coordinates) and nothing else: 10m on a 34 km
-- perimeter, 0.01 km^2 on 51.06, 1m on the centroid. Moving ONE vertex 50m
-- fails all three.
--
-- CHANGE THESE ONLY WITH A FRESH SURVEY IN HAND. They are a checksum on
-- authored data, and re-pinning them to make a check pass converts the gate
-- into a formality.
local SURVEY = {
    points     = 66,       -- 67 clicked; the closing duplicate is not stored
    perimeterM = 34355.0,
    areaM2     = 51057000.0,
    centroidX  = 358.0,
    centroidY  = 1976.3,
}

-- ------------------------------------------------------- 1. the ring itself --

if #B ~= SURVEY.points then
    fail('the boundary has %d points; the survey has %d', #B, SURVEY.points)
end

if #B >= 2 then
    local a, z = B[1], B[#B]
    -- THE CLOSING VERTEX MUST NOT BE STORED. The ring closes implicitly, so a
    -- repeated first point is a zero-length edge -- and a zero-length edge is
    -- the single input BR.PointOnPolygonEdge has to special-case, because the
    -- perpendicular distance to it is 0/0. Keeping it out of the data is
    -- cheaper than trusting the special case.
    if math.abs(a.x - z.x) < 1e-6 and math.abs(a.y - z.y) < 1e-6 then
        fail('point %d repeats point 1 -- the ring closes implicitly, so the ' ..
             'closing vertex must not be stored', #B)
    end
end

for i = 1, #B do
    local p = B[i]
    if type(p.x) ~= 'number' or type(p.y) ~= 'number' then
        fail('boundary point %d is not a pair of numbers', i)
    end
    local q = B[(i % #B) + 1]
    local d = math.sqrt((q.x - p.x) ^ 2 + (q.y - p.y) ^ 2)
    if d < 1.0 then
        fail('boundary points %d and %d are %.3fm apart -- a duplicate vertex ' ..
             'is a degenerate edge', i, (i % #B) + 1, d)
    end
end

local simple, ci, cj = BR.PolygonIsSimple(B)
if not simple then
    fail('the boundary crosses itself: edge %d and edge %d intersect. Ray ' ..
         'casting INVERTS inside a self-crossing ring rather than erroring, so ' ..
         'this must be fixed in the survey, not tolerated', ci, cj)
end

-- ---------------------------------------------- 2. the survey's own numbers --

local per  = BR.PolygonPerimeter(B)
local area = math.abs(BR.PolygonArea(B))

-- Area-weighted centroid, the same figure /brsurveydump prints.
local A2, cx, cy = 0.0, 0.0, 0.0
for i = 1, #B do
    local a = B[i]
    local b = B[(i % #B) + 1]
    local cross = a.x * b.y - b.x * a.y
    A2 = A2 + cross
    cx = cx + (a.x + b.x) * cross
    cy = cy + (a.y + b.y) * cross
end
if A2 ~= 0.0 then
    cx, cy = cx / (3.0 * A2), cy / (3.0 * A2)
end

if math.abs(per - SURVEY.perimeterM) > 10.0 then
    fail('perimeter is %.1fm; the survey reported %.1fm', per, SURVEY.perimeterM)
end
if math.abs(area - SURVEY.areaM2) > 10000.0 then
    fail('area is %.0f m^2; the survey reported %.0f m^2', area, SURVEY.areaM2)
end
if math.abs(cx - SURVEY.centroidX) > 1.0 or math.abs(cy - SURVEY.centroidY) > 1.0 then
    fail('centroid is %.1f, %.1f; the survey reported %.1f, %.1f',
         cx, cy, SURVEY.centroidX, SURVEY.centroidY)
end

-- ------------------------------------------------------------- 3. the POIs --

local poiWorst, poiWorstId = math.huge, '-'
for _, p in ipairs(BR.Config.Map.POIs) do
    local d = BR.Config.Map.BoundaryDistance(p.x, p.y)
    if not BR.Config.Map.InBounds(p.x, p.y) then
        fail('POI %s (%s) at %.1f, %.1f is %.0fm OUTSIDE the surveyed boundary',
             p.id, p.name, p.x, p.y, d)
    elseif d < poiWorst then
        poiWorst, poiWorstId = d, p.id
    end
end

-- --------------------------------------------------- 4. the ambulance spawns --

local ambWorst, ambWorstId = math.huge, '-'
for i, a in ipairs(BR.Config.Map.AmbulanceSpawns or {}) do
    local d = BR.Config.Map.BoundaryDistance(a.x, a.y)
    if not BR.Config.Map.InBounds(a.x, a.y) then
        fail('ambulance spawn %d (%s) at %.1f, %.1f is %.0fm OUTSIDE the ' ..
             'surveyed boundary', i, tostring(a.id), a.x, a.y, d)
    elseif d < ambWorst then
        ambWorst, ambWorstId = d, tostring(a.id)
    end
end

-- ------------------------------------------------------------------ report --

if fails == 0 then
    io.write(string.format(
        '\27[32mok\27[0m   boundary: %d points, simple ring, %.2f km perimeter, %.2f km^2\n',
        #B, per / 1000.0, area / 1000000.0))
    io.write(string.format(
        '     %d POIs and %d ambulance spawns inside; tightest margins %.0fm (%s) and %.0fm (%s)\n',
        #BR.Config.Map.POIs, #(BR.Config.Map.AmbulanceSpawns or {}),
        poiWorst, poiWorstId, ambWorst, ambWorstId))
else
    io.write(string.format('\27[31m%d boundary problem(s)\27[0m\n', fails))
    io.write('     The boundary is HAND-SURVEYED map data (br_lib/config/map.lua).\n')
    io.write('     Move the offending row inside it, or delete it. Do not widen\n')
    io.write('     the ring to fit a coordinate -- that needs a fresh /brsurvey.\n')
end

os.exit(fails == 0 and 0 or 1)
