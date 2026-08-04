-- Unit tests for br_lib's pure shared modules.
--
-- These modules deliberately have no FiveM dependencies, which means they can be
-- tested outside the game -- the fastest feedback loop available on this project.
-- Run via tools/verify.sh, or directly:  lua tools/test_shared.lua

-- clock.lua reaches for GetGameTimer; stub it so the module loads.
function GetGameTimer() return 0 end

local ROOT = 'resources/[fivem-royale]/br_lib/'
for _, f in ipairs({
    'shared/enums.lua',
    'shared/protocol.lua',
    'shared/rng.lua',
    'shared/geo.lua',
    'shared/clock.lua',
    'config/match.lua',
    'config/storm.lua',
    'config/map.lua',
    'config/weapons.lua',
    'config/loot.lua',
    'shared/storm_solve.lua',
}) do
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        io.write('\27[31mload error\27[0m ', f, ': ', tostring(err), '\n')
        os.exit(1)
    end
    chunk()
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
        io.write('\27[31mFAIL\27[0m ', group, ' > ', name)
        if detail then io.write('\n       ', tostring(detail)) end
        io.write('\n')
    end
end

local function near(a, b, eps)
    return math.abs(a - b) <= (eps or 1e-6)
end

-- -------------------------------------------------------------------- rng ---

describe('rng')
do
    local a, b = BR.Rng(12345), BR.Rng(12345)
    local same = true
    for _ = 1, 200 do
        if a:next() ~= b:next() then same = false break end
    end
    ok(same, 'same seed produces the identical sequence')

    local c, d = BR.Rng(1), BR.Rng(2)
    ok(c:next() ~= d:next(), 'different seeds diverge')

    local r = BR.Rng(99)
    local inRange, allSame, first = true, true, nil
    for _ = 1, 1000 do
        local v = r:int(5, 10)
        if v < 5 or v > 10 then inRange = false end
        if first == nil then first = v elseif v ~= first then allSame = false end
    end
    ok(inRange, 'int() stays within [lo, hi]')
    ok(not allSame, 'int() actually varies')

    local f = BR.Rng(7)
    local lo, hi = 1.0, 0.0
    for _ = 1, 2000 do
        local v = f:float()
        if v < lo then lo = v end
        if v > hi then hi = v end
    end
    ok(lo >= 0.0 and hi < 1.0, 'float() stays in [0, 1)', ('lo=%f hi=%f'):format(lo, hi))
    ok(lo < 0.05 and hi > 0.95, 'float() spans the range')

    -- Weighted picks should respect the weights. A zero-weight entry must never
    -- come up; that is what lets loot tables disable an item without deleting it.
    local entries = {
        { key = 'A', weight = 90 },
        { key = 'B', weight = 10 },
        { key = 'C', weight = 0  },
    }
    local w = BR.Rng(4242)
    local counts = { A = 0, B = 0, C = 0 }
    for _ = 1, 4000 do
        local e = w:weighted(entries)
        counts[e.key] = counts[e.key] + 1
    end
    ok(counts.C == 0, 'weighted() never returns a zero-weight entry')
    ok(counts.A > counts.B * 4, 'weighted() respects relative weights',
        ('A=%d B=%d'):format(counts.A, counts.B))

    -- The sqrt in pointInDisc is the whole reason storm paths vary. Without it,
    -- points cluster toward the centre. For a uniform disc, half the points
    -- should fall outside r/sqrt(2), since that radius encloses half the area.
    local p = BR.Rng(31337)
    local outside, n = 0, 20000
    local R = 100.0
    local half = R / math.sqrt(2)
    local allInside = true
    for _ = 1, n do
        local x, y = p:pointInDisc(0.0, 0.0, R)
        local d = math.sqrt(x * x + y * y)
        if d > R + 1e-9 then allInside = false end
        if d > half then outside = outside + 1 end
    end
    ok(allInside, 'pointInDisc() never escapes the radius')
    local frac = outside / n
    ok(near(frac, 0.5, 0.03), 'pointInDisc() is uniform by area, not centre-clustered',
        ('outside r/sqrt(2) = %.3f, expected ~0.500'):format(frac))

    local s = BR.Rng(8)
    local arr = {}
    for i = 1, 50 do arr[i] = i end
    s:shuffle(arr)
    local sum, moved = 0, false
    for i = 1, 50 do
        sum = sum + arr[i]
        if arr[i] ~= i then moved = true end
    end
    ok(sum == 1275, 'shuffle() preserves every element')
    ok(moved, 'shuffle() actually reorders')
end

-- -------------------------------------------------------------------- geo ---

describe('geo')
do
    ok(BR.Clamp(5, 1, 3) == 3 and BR.Clamp(0, 1, 3) == 1 and BR.Clamp(2, 1, 3) == 2, 'Clamp')
    ok(near(BR.Lerp(0, 10, 0.25), 2.5), 'Lerp')
    ok(near(BR.Dist(0, 0, 3, 4), 5.0), 'Dist is euclidean')
    ok(BR.Dist2(0, 0, 3, 4) == 25, 'Dist2 skips the sqrt')

    ok(BR.InCircle(0, 0, 0, 0, 10), 'InCircle: centre is inside')
    ok(BR.InCircle(10, 0, 0, 0, 10), 'InCircle: edge counts as inside')
    ok(not BR.InCircle(11, 0, 0, 0, 10), 'InCircle: outside is outside')

    ok(near(BR.EdgeDistance(15, 0, 0, 0, 10), 5.0), 'EdgeDistance positive outside')
    ok(near(BR.EdgeDistance(5, 0, 0, 0, 10), -5.0), 'EdgeDistance negative inside')

    local aabb = { min = { x = -100, y = -100 }, max = { x = 100, y = 100 } }
    local cx, cy = BR.ClampCircleToAABB(95, 0, 20, aabb)
    ok(cx == 80, 'ClampCircleToAABB pulls the circle fully inside', ('cx=%s'):format(cx))
    cx, cy = BR.ClampCircleToAABB(0, 0, 500, aabb)
    ok(cx == 0 and cy == 0, 'ClampCircleToAABB centres a circle larger than the box')

    -- Bearing: 0 = north, increasing clockwise.
    ok(near(BR.Bearing(0, 0, 0, 10), 0.0, 1e-4), 'Bearing north = 0')
    ok(near(BR.Bearing(0, 0, 10, 0), 90.0, 1e-4), 'Bearing east = 90')
    ok(near(BR.Bearing(0, 0, 0, -10), 180.0, 1e-4), 'Bearing south = 180')
    ok(near(BR.Bearing(0, 0, -10, 0), 270.0, 1e-4), 'Bearing west = 270')
end

describe('geo.arc')
do
    -- The storm wall's correctness rests on these two properties: every sample
    -- sits exactly on the circle, and the arc is centred on the point nearest
    -- the player (so the wall appears where they are actually looking).
    local buf = {}
    local cx, cy, R = 500.0, -200.0, 1200.0
    local px, py = 1800.0, -200.0   -- due east of centre
    local count = BR.ArcPoints(buf, cx, cy, R, px, py, 40, 120.0)

    ok(count == 40, 'ArcPoints returns the requested count')

    local onCircle = true
    for i = 1, count do
        if not near(BR.Dist(cx, cy, buf[i].x, buf[i].y), R, 1e-6) then onCircle = false end
    end
    ok(onCircle, 'every arc sample lies on the circle')

    -- Player is due east, so the middle sample should be the circle's east point.
    local mid = buf[(count // 2) + 1]
    ok(near(mid.x, cx + R, 60.0) and near(mid.y, cy, 60.0),
        'arc is centred toward the player', ('mid=(%.1f, %.1f)'):format(mid.x, mid.y))

    -- The buffer is reused across frames; a second call must not grow it.
    local before = #buf
    BR.ArcPoints(buf, cx, cy, R, px, py, 40, 120.0)
    ok(#buf == before, 'ArcPoints reuses the buffer (no per-frame allocation)')

    ok(BR.ArcPoints(buf, cx, cy, 0.0, px, py, 40, 120.0) == 0,
        'ArcPoints draws nothing for a collapsed circle')

    -- Segment width must match the gap between samples, or the cylinders either
    -- overlap (ugly alpha banding) or leave gaps in the wall.
    local w = BR.ArcSegmentWidth(R, 40, 120.0)
    local gap = BR.Dist(buf[1].x, buf[1].y, buf[2].x, buf[2].y)
    BR.ArcPoints(buf, cx, cy, R, px, py, 40, 120.0)
    gap = BR.Dist(buf[1].x, buf[1].y, buf[2].x, buf[2].y)
    ok(near(w, gap, 1e-3), 'segment width matches the sample gap',
        ('width=%.4f gap=%.4f'):format(w, gap))
end

describe('geo.path')
do
    -- The bus position function: server (jump/eject coordinates) and every
    -- client (rendering) must compute the same answer from the same waypoint
    -- array, so the interpolation is pinned here once.
    local pts = {
        { x = 0,   y = 0,  z = 5,   t = 1000 },
        { x = 100, y = 0,  z = 5,   t = 2000 },
        { x = 100, y = 80, z = 300, t = 3000 },
    }

    local x, y, z = BR.PathPosAt(pts, 0)
    ok(x == 0 and y == 0 and z == 5, 'before the first timestamp: parked at the start')

    x, y, z = BR.PathPosAt(pts, 1500)
    ok(near(x, 50) and near(y, 0) and near(z, 5), 'midway along the first segment')

    x, y, z = BR.PathPosAt(pts, 2000)
    ok(near(x, 100) and near(y, 0), 'waypoints themselves are exact')

    x, y, z = BR.PathPosAt(pts, 2500)
    ok(near(x, 100) and near(y, 40) and near(z, 152.5),
        'position AND altitude interpolate between waypoints')

    x, y, z = BR.PathPosAt(pts, 99999)
    ok(near(x, 100) and near(y, 80) and near(z, 300),
        'past the end it clamps, never extrapolates')

    local _, _, _, dx, dy = BR.PathPosAt(pts, 1500)
    ok(dx > 0 and near(dy, 0), 'direction follows the active segment')

    -- Compass bearing vs GTA heading run OPPOSITE directions; due east is 90
    -- by compass and 270 to the engine. Conflating them flew the first bus
    -- mirror-imaged to its route.
    ok(near(BR.Bearing(0, 0, 10, 0), 90), 'due east is bearing 90')
    ok(near(BR.GtaHeading(90), 270), 'and GTA heading 270')
    ok(near(BR.GtaHeading(0), 0), 'north is 0 in both conventions')
end

describe('geo.chord')
do
    -- Bus routes must start and end on the boundary of the chord circle, or the
    -- plane appears mid-map.
    local rng = BR.Rng(555)
    local cx, cy, R = 0.0, 0.0, 4500.0
    local allOn, allDistinct = true, true
    for _ = 1, 200 do
        local sx, sy, ex, ey = BR.PickChord(rng, cx, cy, R, 0.5)
        if not near(BR.Dist(cx, cy, sx, sy), R, 1.0) then allOn = false end
        if not near(BR.Dist(cx, cy, ex, ey), R, 1.0) then allOn = false end
        if near(sx, ex, 1.0) and near(sy, ey, 1.0) then allDistinct = false end
    end
    ok(allOn, 'chord endpoints sit on the circle')
    ok(allDistinct, 'chord endpoints are distinct')
end

-- ------------------------------------------------------------------ storm ---

describe('storm.solve')
do
    local rec = BR.BuildStormRecord(1, 0.0, 0.0, 1000.0, 100.0, 0.0, 500.0,
                                    10000, 5000, 10000, 2.0)

    local _, _, r, st, left = BR.StormAt(rec, 10000)
    ok(st == BR.StormPhase.HOLDING and near(r, 1000.0) and near(left, 5000.0),
        'at phase start: holding at the old radius')

    _, _, r, st = BR.StormAt(rec, 14999)
    ok(st == BR.StormPhase.HOLDING and near(r, 1000.0), 'still holding just before the shrink')

    local cx, cy
    cx, cy, r, st, left = BR.StormAt(rec, 20000)  -- halfway through the shrink
    ok(st == BR.StormPhase.SHRINKING, 'shrinking once the hold expires')
    ok(near(r, 750.0), 'radius interpolates linearly', ('r=%.2f expected 750'):format(r))
    ok(near(cx, 50.0) and near(cy, 0.0), 'centre interpolates linearly')
    ok(near(left, 5000.0), 'msLeft counts down the shrink')

    _, _, r, st = BR.StormAt(rec, 25000)
    ok(st == BR.StormPhase.FINISHED and near(r, 500.0), 'finished at the target radius')

    _, _, r, st = BR.StormAt(rec, 99999)
    ok(st == BR.StormPhase.FINISHED and near(r, 500.0), 'stays finished afterwards')

    local pre = BR.BuildStormRecord(0, 0, 0, 3500, 0, 0, 3500, 0, 90000, 0, 0)
    _, _, _, st = BR.StormAt(pre, 1000)
    ok(st == BR.StormPhase.PRE, 'phase 0 reports the pre-storm hold')

    _, _, r, st = BR.StormAt(nil, 0)
    ok(st == BR.StormPhase.PRE and r == 0.0, 'nil record degrades safely')

    ok(near(BR.StormPhaseDuration(rec), 15000.0), 'phase duration is wait + shrink')
end

describe('storm.freeHold')
do
    -- THE FREE-LOOT HOLD IS FREE. Phase 1's wait deals no damage anywhere on
    -- the map (the Fortnite rule: nothing hurts until the first circle locks
    -- in and starts closing) -- a far-end jumper can legitimately land
    -- kilometres outside circle 1 and must not bleed for it. Decided in the
    -- SOLVER so the server's damage tick and the client's vignette cannot
    -- disagree. This is a user-facing rule pinned after a live report:
    -- "as soon as I jumped I was already outside the circle and losing
    -- health" (2026-08-02).
    local p1 = BR.BuildStormRecord(1, 0.0, 0.0, 3500.0, 100.0, 0.0, 2600.0,
                                   0, 120000, 150000, 1.0)

    local _, _, _, st, _, dps = BR.StormAt(p1, 60000)   -- mid-hold
    ok(st == BR.StormPhase.HOLDING and dps == 0.0,
        'phase 1 holding deals NO damage', ('dps=%.1f'):format(dps))

    _, _, _, st, _, dps = BR.StormAt(p1, 130000)        -- mid-shrink
    ok(st == BR.StormPhase.SHRINKING and dps == 1.0,
        'phase 1 shrinking deals its authored dps')

    _, _, _, st, _, dps = BR.StormAt(p1, 999999)        -- collapsed
    ok(st == BR.StormPhase.FINISHED and dps == 1.0,
        'a finished phase keeps hurting until the next record')

    -- LATER holds are not free: from phase 2 on, outside always hurts, wait
    -- or shrink alike.
    local p2 = BR.BuildStormRecord(2, 0.0, 0.0, 2600.0, 0.0, 0.0, 1600.0,
                                   0, 120000, 120000, 2.0)
    _, _, _, st, _, dps = BR.StormAt(p2, 60000)
    ok(st == BR.StormPhase.HOLDING and dps == 2.0,
        'phase 2 holding deals its authored dps')
end

describe('storm.nesting')
do
    -- THE critical invariant. If a new circle is not fully contained by the old
    -- one, a player standing legitimately inside the safe zone can be retroactively
    -- outside it and start taking damage through no fault of their own.
    local rng = BR.Rng(2024)
    local violations, worst = 0, 0.0
    local cx, cy = 0.0, 0.0

    for _ = 1, 5000 do
        local curR  = 200.0 + rng:float() * 3000.0
        local nextR = curR * (0.3 + rng:float() * 0.5)
        local nx, ny = BR.NextStormCentre(rng, cx, cy, curR, nextR, 0.55, nil)
        local slop = BR.Dist(cx, cy, nx, ny) + nextR - curR
        if slop > 1e-6 then
            violations = violations + 1
            if slop > worst then worst = slop end
        end
    end
    ok(violations == 0, 'next circle always nests inside the current one',
        ('%d violations, worst overshoot %.3f'):format(violations, worst))

    -- Degenerate case: no room to move.
    local nx, ny = BR.NextStormCentre(rng, 10.0, 20.0, 100.0, 100.0, 0.55, nil)
    ok(near(nx, 10.0) and near(ny, 20.0), 'zero slack leaves the centre alone')

    -- REGRESSION: nesting must survive AABB clamping.
    --
    -- Clamping to the map bounds can push the new centre further from the old one
    -- than the slack allows -- most easily when the current circle already
    -- overhangs the bounds, which the opening circle routinely does. An earlier
    -- version of NextStormCentre failed this in 38 of 20000 cases with overshoots
    -- up to 162 units, which in-game reads as "I took storm damage while standing
    -- inside the circle" and is essentially undebuggable from a bug report.
    --
    -- Seeded from the real POIs (the anchor candidates) so the regression is
    -- exercised where it bit -- including the map-edge ones like Chumash and
    -- Humane Labs whose opening circles overhang the bounds the most.
    local aabb = BR.Config.Storm.mapAABB
    local anchors = BR.Config.Map.POIs
    violations, worst = 0, 0.0
    for _ = 1, 20000 do
        local a     = anchors[rng:int(1, #anchors)]
        local curR  = 800.0 + rng:float() * 2700.0
        local nextR = curR * (0.3 + rng:float() * 0.5)
        local nx, ny = BR.NextStormCentre(rng, a.x, a.y, curR, nextR, 0.55, aabb)
        local slop = BR.Dist(a.x, a.y, nx, ny) + nextR - curR
        if slop > 1e-6 then
            violations = violations + 1
            if slop > worst then worst = slop end
        end
    end
    ok(violations == 0, 'nesting survives AABB clamping at the map edges',
        ('%d violations, worst overshoot %.1f'):format(violations, worst))

    -- REGRESSION: a config value outside [0,1] must not be able to break
    -- containment. edgeBias = 1.8 previously produced violations in ~69% of rolls.
    violations = 0
    for _ = 1, 5000 do
        local nx, ny = BR.NextStormCentre(rng, 0.0, 0.0, 1000.0, 500.0, 1.8, nil)
        if BR.Dist(0.0, 0.0, nx, ny) + 500.0 - 1000.0 > 1e-6 then
            violations = violations + 1
        end
    end
    ok(violations == 0, 'out-of-range edgeBias is clamped, not trusted',
        ('%d violations'):format(violations))

    -- Bounds are best-effort and yield to containment. Where the current circle
    -- is itself fully inside the map, though, the next one should be too.
    local inBounds = true
    for _ = 1, 5000 do
        local nextR = 200.0 + rng:float() * 800.0
        local curR  = nextR / (0.3 + rng:float() * 0.5)
        -- place the current circle fully inside the bounds
        local bx = aabb.min.x + curR + rng:float() * ((aabb.max.x - aabb.min.x) - 2 * curR)
        local by = aabb.min.y + curR + rng:float() * ((aabb.max.y - aabb.min.y) - 2 * curR)
        local qx, qy = BR.NextStormCentre(rng, bx, by, curR, nextR, 0.55, aabb)
        if qx - nextR < aabb.min.x - 1e-6 or qx + nextR > aabb.max.x + 1e-6
        or qy - nextR < aabb.min.y - 1e-6 or qy + nextR > aabb.max.y + 1e-6 then
            inBounds = false
        end
    end
    ok(inBounds, 'a contained circle keeps its successors inside the bounds')
end

describe('storm.anchor')
do
    -- The anchor scheme: a random tour waypoint, then a random POI inside the
    -- configured band of it. These tests drive the picker with the REAL legs
    -- and the REAL POI table, because that is the pairing that has to work --
    -- a picker that passes on synthetic data and starves on the actual coastal
    -- waypoints would be a vacuous green.
    local band = BR.Config.Storm.anchorBand
    local pois = BR.Config.Map.POIs
    local legs = BR.Config.Bus.legs

    --- Flatten one concrete tour, mirroring bus.plan()'s draw.
    local function drawTour(rng)
        local wps = {}
        for _, options in ipairs(legs) do
            for _, wp in ipairs(options[rng:int(1, #options)]) do
                wps[#wps + 1] = { x = wp.x, y = wp.y }
            end
        end
        return wps
    end

    -- Property, over many seeds: an anchor is ALWAYS produced, is always one
    -- of the authored POIs, and sits within the (possibly widened) reach of
    -- the waypoint it was drawn around.
    local produced, isPoi, inReach = 0, true, true
    local seen = {}
    local worstD = 0.0
    for seed = 1, 500 do
        local rng = BR.Rng(seed)
        local wps = drawTour(rng)
        local poi, wp = BR.PickStormAnchor(rng, wps, pois, band)
        if poi then
            produced = produced + 1
            seen[poi.id] = true
            local found = false
            for _, p in ipairs(pois) do
                if p == poi then found = true break end
            end
            isPoi = isPoi and found
            local d = BR.Dist(wp.x, wp.y, poi.x, poi.y)
            if d > worstD then worstD = d end
            if d > band.widenMax then inReach = false end
        end
    end
    ok(produced == 500, 'an anchor is always produced', ('%d/500'):format(produced))
    ok(isPoi, 'the anchor is always an authored POI')
    ok(inReach, 'the anchor stays within widenMax of its waypoint',
        ('worst distance %.0f'):format(worstD))

    -- Variety: the user's design goal was "could never conceivably have a
    -- regular outcome". 500 matches must spread across a healthy share of the
    -- POI table, not orbit a favoured few.
    local distinct = 0
    for _ in pairs(seen) do distinct = distinct + 1 end
    ok(distinct >= 25, 'anchors spread across the POI table',
        ('%d distinct POIs over 500 seeds'):format(distinct))

    -- The in-band rule is REAL for the real map: most draws must resolve
    -- without widening at all. If this decays, the POI table has thinned out
    -- around the flight legs and the band is quietly always widening.
    local inBand = 0
    for seed = 1, 500 do
        local rng = BR.Rng(seed)
        local wps = drawTour(rng)
        local poi, wp = BR.PickStormAnchor(rng, wps, pois, band)
        local d = BR.Dist(wp.x, wp.y, poi.x, poi.y)
        if d >= band.min and d <= band.max then inBand = inBand + 1 end
    end
    ok(inBand >= 350, 'most anchors resolve inside the un-widened band',
        ('%d/500 in [%d, %d]'):format(inBand, band.min, band.max))

    -- Widening: a waypoint with nothing in band must still anchor. One distant
    -- POI, far outside band.max but inside widenMax, gets found by widening.
    local rng = BR.Rng(7)
    local far = { { id = 'only', x = 3000.0, y = 0.0 } }
    local poi = BR.PickStormAnchor(rng, { { x = 0.0, y = 0.0 } }, far, band)
    ok(poi and poi.id == 'only', 'the band widens until a POI appears')

    -- Last resort: a POI beyond even widenMax is still returned -- a slightly
    -- off-band anchor is a shrug, no anchor is a dead match.
    local beyond = { { id = 'lonely', x = 9000.0, y = 9000.0 } }
    poi = BR.PickStormAnchor(BR.Rng(8), { { x = 0.0, y = 0.0 } }, beyond, band)
    ok(poi and poi.id == 'lonely', 'nearest POI is the fallback beyond widenMax')

    -- Determinism: the same seed draws the same anchor. The whole route/anchor
    -- pipeline hangs off one seeded rng, so tests (and replays later) can pin it.
    local a1 = BR.PickStormAnchor(BR.Rng(42), drawTour(BR.Rng(42)), pois, band)
    local a2 = BR.PickStormAnchor(BR.Rng(42), drawTour(BR.Rng(42)), pois, band)
    ok(a1 == a2, 'the same seed picks the same anchor')

    -- Degenerate inputs degrade to nil rather than erroring inside a
    -- transition.
    ok(BR.PickStormAnchor(BR.Rng(1), {}, pois, band) == nil, 'no waypoints -> nil')
    ok(BR.PickStormAnchor(BR.Rng(1), { { x = 0, y = 0 } }, {}, band) == nil,
        'no POIs -> nil')
end

-- ------------------------------------------------------------------ config ---

describe('config')
do
    ok(BR.Config.Match.maxPlayers <= 48,
        'maxPlayers respects the free OneSync ceiling',
        'above 48 the server fails its heartbeat check and delists')

    local phases = BR.Config.Storm.phases
    local shrinking = true
    for i = 2, #phases do
        if phases[i].radius >= phases[i - 1].radius then shrinking = false end
    end
    ok(shrinking, 'storm phases shrink monotonically')

    local escalating = true
    for i = 2, #phases do
        if phases[i].dps < phases[i - 1].dps then escalating = false end
    end
    ok(escalating, 'storm damage never decreases between phases')

    ok(phases[#phases].radius == 0.0, 'final phase collapses to a point')

    -- THE TEN-SECOND FLOOR (user rule, 2026-08-04): the storm must never
    -- kill a full-health player in under ten seconds, so at 100 display
    -- health no phase may exceed 10 dps. Late phases used to hit 20 -- a
    -- five-second melt.
    local worstDps = 0
    for _, p in ipairs(phases) do
        if p.dps > worstDps then worstDps = p.dps end
    end
    ok(worstDps <= 10.0, 'no phase kills a full-health player in under 10s',
        ('worst dps %.1f'):format(worstDps))

    -- USER DECISION (2026-08-02): the free-loot hold is phase 1's wait, 120
    -- seconds from the moment the match goes live. There is no separate
    -- initialHold field any more -- resurrecting one would double-count.
    ok(phases[1].wait == 120, 'the free-loot hold is 120s (user call)')
    ok(BR.Config.Storm.initialHold == nil, 'initialHold stays retired')

    local total = BR.Config.Storm.TotalSeconds()
    ok(total > 900 and total < 1800,
        'match length lands in a sane 15-30 minute window',
        ('%.0f seconds'):format(total))

    -- Late circles must fit inside the 424-unit entity render ceiling, or players
    -- end the match unable to see each other.
    local lastR = phases[#phases - 1].radius
    ok(lastR * 2 <= 424, 'late-game circle diameter fits the render ceiling',
        ('diameter %.0f vs 424'):format(lastR * 2))

    local ids = {}
    local dupes = false
    for _, p in ipairs(BR.Config.Map.POIs) do
        if ids[p.id] then dupes = true end
        ids[p.id] = true
    end
    ok(not dupes, 'POI ids are unique')
    -- 40+, not the original 20: POIs double as storm-anchor candidates now,
    -- and the anchor scheme's "never a regular outcome" property needs the
    -- density (user call, 2026-08-02).
    ok(#BR.Config.Map.POIs >= 40, 'at least 40 POIs authored',
        ('%d found'):format(#BR.Config.Map.POIs))

    -- Every POI must sit inside the playable bounds, or the storm can never
    -- reach it and its loot is wasted.
    local aabb = BR.Config.Storm.mapAABB
    local outside = {}
    for _, p in ipairs(BR.Config.Map.POIs) do
        if p.x < aabb.min.x or p.x > aabb.max.x or p.y < aabb.min.y or p.y > aabb.max.y then
            outside[#outside + 1] = p.id
        end
    end
    ok(#outside == 0, 'every POI lies inside the playable bounds',
        table.concat(outside, ', '))

    local poi = BR.Config.Map.NearestPOI(1900.0, 3700.0)
    ok(poi and poi.id == 'sandy', 'NearestPOI resolves a known location')
end

describe('health units')
do
    -- Engine health versus display health (0..100). Mixing the two is the most
    -- likely source of a silent balance bug, so the conversion is pinned here.
    --
    -- The floor was VERIFIED IN-GAME on 2026-08-02: player peds on this build
    -- die at engine 0, not at the widely repeated 100-means-dead convention.
    -- The expectations below are written against config, not literals, so a
    -- future floor change fails here only if the arithmetic breaks -- but the
    -- midpoint checks pin today's verified numbers on purpose.
    ok(BR.Config.Match.healthFloor == 0, 'the in-game verified floor is 0')

    ok(BR.ToEngineHp(100) == BR.Config.Match.maxHealth, 'full display maps to max engine hp')
    ok(BR.ToEngineHp(0) == BR.Config.Match.healthFloor, 'zero display maps to the death floor')
    ok(BR.ToEngineHp(50) == 100, 'half display maps to the midpoint (engine 100)')

    ok(near(BR.ToDisplayHp(200), 100.0), 'max engine hp reads as full')
    ok(near(BR.ToDisplayHp(0), 0.0), 'the death floor reads as zero')
    ok(near(BR.ToDisplayHp(100), 50.0), 'midpoint engine hp reads as half')

    local roundTrips = true
    for d = 0, 100 do
        if math.abs(BR.ToDisplayHp(BR.ToEngineHp(d)) - d) > 0.51 then roundTrips = false end
    end
    ok(roundTrips, 'display -> engine -> display round-trips within rounding')

    ok(BR.ToEngineHp(-50) == BR.Config.Match.healthFloor, 'negative display is clamped')
    ok(BR.ToEngineHp(999) == BR.Config.Match.maxHealth, 'excess display is clamped')
    ok(near(BR.ToDisplayHp(-10), 0.0), 'sub-floor engine hp reads as zero, not negative')

    ok(BR.IsDeadHp(0) and BR.IsDeadHp(-1), 'at or below the floor is dead')
    ok(not BR.IsDeadHp(1), 'above the floor is alive')

    -- Consumable numbers are authored in display units; they must stay in range.
    local bad = {}
    for _, c in ipairs(BR.Config.Consumables) do
        if c.health and (c.health > 100 or c.healthCap > 100) then
            bad[#bad + 1] = c.id
        end
    end
    ok(#bad == 0, 'consumables are authored in display units', table.concat(bad, ', '))
end

describe('modes')
do
    ok(BR.ResolveMode('squad') == BR.Mode.SQUAD, 'resolves a known mode key')
    ok(BR.ResolveMode('solo') == BR.Mode.SOLO, 'resolves solo')
    ok(BR.ResolveMode('nonsense') == BR.Mode.SOLO, 'unknown key falls back rather than erroring')
    ok(BR.ResolveMode(nil) == BR.Mode.SOLO, 'nil falls back')

    -- The default in config must actually name a real mode.
    ok(BR.ModeByKey[BR.Config.Match.defaultMode] ~= nil,
        'Config.Match.defaultMode names a real mode',
        tostring(BR.Config.Match.defaultMode))

    ok(BR.Mode.SOLO.dbno == false, 'solo has no downed state -- nobody could revive you')
    ok(BR.Mode.SQUAD.dbno == true, 'squads have a downed state')
    ok(BR.Mode.SQUAD.squadSize <= BR.Config.Match.maxSquadSize,
        'squad size fits the configured maximum')
end

describe('protocol')
do
    -- Lua 5.4 distinguishes integer 5 from float 5.0 and they serialise
    -- differently through SendNUIMessage. Normalising once at the boundary is
    -- what stops the UI receiving inconsistent types.
    local out = BR.NuiNormalise({ hp = 100, nested = { kills = 3 }, name = 'x', flag = true })
    ok(math.type(out.hp) == 'float', 'NuiNormalise floats top-level integers')
    ok(math.type(out.nested.kills) == 'float', 'NuiNormalise recurses')
    ok(out.name == 'x' and out.flag == true, 'NuiNormalise leaves non-numbers alone')

    -- Duplicate event names would mean two systems silently sharing a channel.
    local seen, dupes = {}, {}
    for k, v in pairs(BR.Net) do
        if seen[v] then dupes[#dupes + 1] = v end
        seen[v] = k
    end
    ok(#dupes == 0, 'no duplicate net event names', table.concat(dupes, ', '))
end

-- ---------------------------------------------------------------- weapons ---

describe('weapons')
do
    -- A duplicate hash would silently overwrite an entry in the lookup table and
    -- make one weapon validate as another.
    local seen, dupes = {}, {}
    for _, w in ipairs(BR.Config.Weapons) do
        if seen[w.hash] then dupes[#dupes + 1] = w.id end
        seen[w.hash] = w.id
    end
    for _, t in ipairs(BR.Config.Throwables) do
        if seen[t.hash] then dupes[#dupes + 1] = t.id end
        seen[t.hash] = t.id
    end
    ok(#dupes == 0, 'no duplicate weapon hashes', table.concat(dupes, ', '))

    local ids, idDupes = {}, {}
    for _, w in ipairs(BR.Config.Weapons) do
        if ids[w.id] then idDupes[#idDupes + 1] = w.id end
        ids[w.id] = true
    end
    ok(#idDupes == 0, 'no duplicate weapon ids', table.concat(idDupes, ', '))

    -- The render ceiling again. A weapon whose range exceeds it promises the
    -- player a shot the engine will never let them take.
    local over = {}
    for _, w in ipairs(BR.Config.Weapons) do
        if w.maxRange > 424.0 then over[#over + 1] = w.id end
    end
    ok(#over == 0, 'no weapon out-ranges the 424u entity render ceiling',
        table.concat(over, ', '))

    -- Excluded on purpose: these are the highest-value targets for a weapon
    -- spawning cheat, and keeping them out of the table keeps them off the allowlist.
    for _, banned in ipairs({
        { 'RPG',              0xB1CA77B1 },
        { 'Minigun',          0x42BF8A85 },
        { 'Railgun',          0x6D544C99 },
        { 'Grenade Launcher', 0xA284510B },
    }) do
        ok(not BR.Config.IsAllowedWeapon(banned[2]),
            ('%s is not allowed'):format(banned[1]))
    end

    ok(BR.Config.IsAllowedWeapon(0x1B06D571), 'pistol is allowed')
    ok(BR.Config.IsAllowedWeapon(BR.Config.Gadgets.PARACHUTE), 'parachute gadget is allowed')
    ok(BR.Config.IsAllowedWeapon(BR.Config.Gadgets.UNARMED), 'unarmed is allowed')
    ok(not BR.Config.IsAllowedWeapon(0xDEADBEEF), 'an unknown hash is rejected')

    -- Every weapon must draw from a pool that actually exists, or it can never
    -- be reloaded.
    local badAmmo = {}
    for _, w in ipairs(BR.Config.Weapons) do
        if not BR.Config.AmmoCaps[w.ammo] then badAmmo[#badAmmo + 1] = w.id end
        if not BR.Config.AmmoPickups[w.ammo] then badAmmo[#badAmmo + 1] = w.id .. '(pickup)' end
    end
    ok(#badAmmo == 0, 'every weapon maps to a real ammo pool', table.concat(badAmmo, ', '))

    -- Every rarity tier needs at least one weapon, or a roll for that tier has
    -- nothing to hand out.
    local emptyTiers = {}
    for rarity = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        if #BR.Config.WeaponsOfRarity(rarity) == 0 then
            emptyTiers[#emptyTiers + 1] = tostring(rarity)
        end
    end
    ok(#emptyTiers == 0, 'every rarity tier has weapons', table.concat(emptyTiers, ', '))

    -- Damage model
    local pistol = 0x1B06D571
    local base = BR.Config.ExpectedDamage(pistol, BR.Rarity.COMMON, 1.0)
    local leg  = BR.Config.ExpectedDamage(pistol, BR.Rarity.LEGENDARY, 1.0)
    ok(leg > base, 'rarity increases expected damage')
    ok(near(base, 26 * 1.00, 0.01), 'common damage matches the table')

    local close = BR.Config.ExpectedDamage(pistol, BR.Rarity.COMMON, 1.0)
    local far   = BR.Config.ExpectedDamage(pistol, BR.Rarity.COMMON, 120.0)
    ok(far < close, 'damage falls off with distance')
    ok(far >= close * 0.5, 'falloff is floored, not unbounded',
        ('close=%.2f far=%.2f'):format(close, far))
    ok(BR.Config.ExpectedDamage(0xDEADBEEF, BR.Rarity.COMMON, 10.0) == 0.0,
        'unknown weapon expects zero damage')
end

-- ------------------------------------------------------------------- loot ---

describe('loot')
do
    -- Loot layout is generated from a shared seed on the server and must be
    -- reproducible. RollRarity iterates a hash table internally, and pairs()
    -- order is undefined -- this test is what proves the sort actually fixes it.
    local seqA, seqB = {}, {}
    local ra, rb = BR.Rng(777), BR.Rng(777)
    for i = 1, 500 do
        seqA[i] = BR.Config.RollRarity(ra, 3)
        seqB[i] = BR.Config.RollRarity(rb, 3)
    end
    local identical = true
    for i = 1, 500 do
        if seqA[i] ~= seqB[i] then identical = false break end
    end
    ok(identical, 'RollRarity is deterministic for a given seed')

    local varied, first = false, seqA[1]
    for i = 2, 500 do if seqA[i] ~= first then varied = true break end end
    ok(varied, 'RollRarity actually varies')

    local inRange = true
    for i = 1, 500 do
        if seqA[i] < BR.Rarity.COMMON or seqA[i] > BR.Rarity.LEGENDARY then inRange = false end
    end
    ok(inRange, 'RollRarity stays within the rarity range')

    -- Tier 3 should out-roll tier 1 on average, or contested drops are pointless.
    local function meanRarity(tier, seed)
        local r, sum = BR.Rng(seed), 0
        for _ = 1, 3000 do sum = sum + BR.Config.RollRarity(r, tier) end
        return sum / 3000
    end
    local t1, t3 = meanRarity(1, 42), meanRarity(3, 42)
    ok(t3 > t1, 'higher POI tiers roll better loot',
        ('tier1=%.2f tier3=%.2f'):format(t1, t3))

    local kr = BR.Rng(9)
    local kinds = {}
    for _ = 1, 2000 do
        local k = BR.Config.RollKind(kr)
        kinds[k] = (kinds[k] or 0) + 1
    end
    ok(kinds[BR.ItemKind.WEAPON] and kinds[BR.ItemKind.AMMO]
       and kinds[BR.ItemKind.CONSUMABLE] and kinds[BR.ItemKind.THROWABLE],
       'RollKind produces every item kind')

    -- Consumables must be internally coherent: a potion that heals past its own
    -- cap, or a cap above the engine maximum, would be a silent balance bug.
    local badCaps = {}
    for _, c in ipairs(BR.Config.Consumables) do
        if c.armour and (c.armourCap > BR.Config.Match.maxArmour) then
            badCaps[#badCaps + 1] = c.id .. '(armourCap)'
        end
        if c.health and c.healthCap > 100 then
            badCaps[#badCaps + 1] = c.id .. '(healthCap)'
        end
        if c.useMs <= 0 or c.maxStack <= 0 then
            badCaps[#badCaps + 1] = c.id .. '(useMs/stack)'
        end
    end
    ok(#badCaps == 0, 'consumable caps are coherent', table.concat(badCaps, ', '))

    ok(BR.Config.ConsumableById['medkit'] ~= nil, 'consumable lookup is built')

    -- Budget sanity. This is the number that justifies the local-prop design;
    -- if it ever creeps toward the thousands as networked entities it would be
    -- an instant object-pool blowout.
    local total = BR.Config.TotalLootBudget()
    ok(total > 600 and total < 2000, 'total loot budget is in the planned range',
        ('%d items'):format(total))

    local badTier = {}
    for _, poi in ipairs(BR.Config.Map.POIs) do
        if not BR.Config.Loot.budgetPerTier[poi.tier] then
            badTier[#badTier + 1] = poi.id
        end
        if not BR.Config.RarityWeights[poi.tier] then
            badTier[#badTier + 1] = poi.id .. '(rarity)'
        end
    end
    ok(#badTier == 0, 'every POI tier has a budget and a rarity table',
        table.concat(badTier, ', '))
end

-- ----------------------------------------------------------------- result ---

io.write(('\n%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
