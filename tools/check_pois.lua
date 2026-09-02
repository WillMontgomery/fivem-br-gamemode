-- POI siting gate.
--
-- The POI list is hand-authored map data, and hand-authored map data goes wrong
-- in ways no other check here catches: a duplicated id silently shadows a
-- location, a typo'd coordinate drops a named town in the Pacific, and two
-- centres 80 metres apart make one POI's loot look like the other's.
--
-- It also enforces the SITING rule that produced the backcountry set. Every POI
-- authored before 2026-08-06 came from a named place on the map, and named
-- places sit on roads -- so the whole set inherited the road network's shape and
-- the space between highways had nothing in it (user: "all of your POIs seem
-- centered around roads -- the largest gap we have is the space between the
-- roads"). The fix is only durable if it is measured, so anything in the
-- BACKCOUNTRY set below has to stay a real distance from every road corridor.
--
-- Run via tools/verify.sh, or directly:  lua tools/check_pois.lua

local ROOT = 'resources/[fivem-royale]/br_lib/'
for _, f in ipairs({ 'shared/enums.lua', 'config/map.lua' }) do
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

local POIS = BR.Config.Map.POIs

-- The POIs sited FROM the gaps rather than from a place name. These are the
-- ones the road-distance rule applies to; the older set is on roads on purpose
-- (a town is on a road) and grandfathering it is the honest thing to do.
local BACKCOUNTRY = {}
for _, id in ipairs({
    'mtjosiah', 'baytree', 'tongva_v', 'pacific_r', 'banham_w', 'lagozancudo',
    'zancudo_r', 'hills_e', 'chaparral_n', 'harmony_n', 'zancudo_f',
    -- `graybeard` and `calafia` were here until 2026-08-28, when the surveyed
    -- boundary removed them (51m and 45m outside). Nothing else in the set moved.
    'dryfields', 'paleto_f', 'raton_n', 'chiliad_ridge',
    'chiliad_e', 'alamo_n', 'procopio_n', 'mtgordo_w', 'gordo_s',
    'senora_n', 'mthaan', 'eastbeach',
}) do BACKCOUNTRY[id] = true end

-- How close two POI centres may sit. The dense city blocks already run to ~355m
-- (Grove Street and the Maze Bank Arena), so this is set below that: it is a
-- gross-error catch, not a spacing policy.
local MIN_SEPARATION = 300.0

-- How far a backcountry POI must be from a road corridor. Roadside filler
-- scatters within BR.Config.Loot.filler.minOffset of the polyline, so anything
-- inside that is not "between the roads" in any useful sense; 150m is a POI you
-- have to leave the tarmac to reach.
local MIN_ROAD = 150.0

-- ------------------------------------------------------------------ helpers --

--- Distance from a point to a line SEGMENT (not the infinite line: the corridor
--- ends where the polyline ends, and an infinite line puts Route 68 in the sea).
local function distToSegment(px, py, ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    local len2 = dx * dx + dy * dy
    if len2 <= 0.0 then
        return math.sqrt((px - ax) ^ 2 + (py - ay) ^ 2)
    end
    local t = ((px - ax) * dx + (py - ay) * dy) / len2
    t = math.max(0.0, math.min(1.0, t))
    local cx, cy = ax + t * dx, ay + t * dy
    return math.sqrt((px - cx) ^ 2 + (py - cy) ^ 2)
end

--- Distance to the nearest point on any authored road corridor.
local function distToNearestRoad(x, y)
    local best, bestId = math.huge, '?'
    for _, road in ipairs(BR.Config.Map.Roads) do
        local pts = road.points
        for i = 1, #pts - 1 do
            local d = distToSegment(x, y, pts[i].x, pts[i].y, pts[i + 1].x, pts[i + 1].y)
            if d < best then best, bestId = d, road.id end
        end
    end
    return best, bestId
end

-- -------------------------------------------------------------------- checks --

-- 1. Ids are unique. A duplicate does not error anywhere -- the second entry
--    just shadows the first in every id-keyed lookup.
local seen = {}
for _, p in ipairs(POIS) do
    if seen[p.id] then
        fail('duplicate POI id %q', p.id)
    end
    seen[p.id] = true
end

-- 2. Nothing in the sea, and nothing on the runway.
for _, p in ipairs(POIS) do
    if BR.Config.Map.IsWater(p.x, p.y) then
        fail('%s (%s) is inside an authored water rectangle', p.id, p.name)
    end
    if BR.Config.Map.IsNoLoot(p.x, p.y) then
        fail('%s (%s) is inside a no-loot rectangle', p.id, p.name)
    end
end

-- 3. Tiers are real, and radii are sane.
for _, p in ipairs(POIS) do
    if p.tier ~= 1 and p.tier ~= 2 and p.tier ~= 3 then
        fail('%s has tier %s, which is not 1..3', p.id, tostring(p.tier))
    end
    if not p.radius or p.radius < 50.0 or p.radius > 500.0 then
        fail('%s has radius %s', p.id, tostring(p.radius))
    end
end

-- 4. No two centres on top of each other.
local closest, closestPair = math.huge, ''
for i = 1, #POIS do
    for j = i + 1, #POIS do
        local a, b = POIS[i], POIS[j]
        local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
        if d < closest then
            closest, closestPair = d, a.id .. ' / ' .. b.id
        end
        if d < MIN_SEPARATION then
            fail('%s and %s are only %.0fm apart (min %.0f)', a.id, b.id, d, MIN_SEPARATION)
        end
    end
end

-- 5. The backcountry set is actually off-road.
local roadWorst, roadWorstId = math.huge, ''
local backcountryCount = 0
for _, p in ipairs(POIS) do
    if BACKCOUNTRY[p.id] then
        backcountryCount = backcountryCount + 1
        local d, road = distToNearestRoad(p.x, p.y)
        if d < roadWorst then roadWorst, roadWorstId = d, p.id .. ' (' .. road .. ')' end
        if d < MIN_ROAD then
            fail('backcountry POI %s is only %.0fm from the %s corridor (min %.0f)',
                 p.id, d, road, MIN_ROAD)
        end
    end
end
for id in pairs(BACKCOUNTRY) do
    if not seen[id] then
        fail('BACKCOUNTRY lists %q, which is not in the POI table', id)
    end
end

-- 6. The ambulance spawns (#191, #219). These are hand-typed surveyed points
--    that NOTHING READS YET, which means no other check in this tree and no
--    test would notice a transposed digit in one -- the value has no behaviour
--    to go wrong. Same gross-error catch the POIs get, and for the same reason.
local AMB = BR.Config.Map.AmbulanceSpawns or {}
local ambClosest, ambPair = math.huge, '-'
for i, a in ipairs(AMB) do
    if BR.Config.Map.IsWater(a.x, a.y) then
        fail('ambulance spawn %d is inside an authored water rectangle', i)
    end
    if BR.Config.Map.IsNoLoot(a.x, a.y) then
        fail('ambulance spawn %d is inside a no-loot rectangle', i)
    end
    -- A heading is a compass bearing, and a vehicle spawned on a nil one faces
    -- north silently rather than erroring.
    if type(a.heading) ~= 'number' or a.heading < 0.0 or a.heading >= 360.0 then
        fail('ambulance spawn %d has heading %s', i, tostring(a.heading))
    end
    for j = i + 1, #AMB do
        local b = AMB[j]
        local d = math.sqrt((a.x - b.x) ^ 2 + (a.y - b.y) ^ 2)
        if d < ambClosest then ambClosest, ambPair = d, i .. ' / ' .. j end
        -- Two spawns on the same car park is a copy-paste, and #191 picks the
        -- point NEAREST the death -- so a duplicate is a coin flip between two
        -- identical answers rather than a second destination.
        if d < 50.0 then
            fail('ambulance spawns %d and %d are only %.0fm apart', i, j, d)
        end
    end
end

-- ------------------------------------------------------------------- report --

local north, tiers = 0, { 0, 0, 0 }
for _, p in ipairs(POIS) do
    if p.y > 500.0 then north = north + 1 end
    tiers[p.tier] = (tiers[p.tier] or 0) + 1
end

if fails == 0 then
    io.write(string.format(
        '\27[32mok\27[0m   %d POIs (%d north of the city, %d backcountry) ' ..
        'T1/T2/T3 %d/%d/%d\n',
        #POIS, north, backcountryCount, tiers[1], tiers[2], tiers[3]))
    io.write(string.format(
        '     closest pair %.0fm (%s); backcountry nearest road %.0fm (%s)\n',
        closest, closestPair, roadWorst, roadWorstId))
    io.write(string.format(
        '     %d ambulance spawns, closest pair %.0fm (%s)\n',
        #AMB, ambClosest == math.huge and 0.0 or ambClosest, ambPair))
else
    io.write(string.format('\27[31m%d POI problem(s)\27[0m\n', fails))
end

os.exit(fails == 0 and 0 or 1)
