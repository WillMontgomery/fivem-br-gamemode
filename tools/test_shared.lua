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
    'shared/names.lua',
    'shared/rng.lua',
    'shared/geo.lua',
    -- BEFORE config/map.lua, whose InBounds wraps it -- and before
    -- shared/storm_solve.lua, which calls InBounds to keep a circle on the map.
    'shared/polygon.lua',
    'shared/clock.lua',
    'shared/sched.lua',
    'shared/outbox.lua',
    'shared/identity.lua',
    'config/match.lua',
    'config/storm.lua',
    'config/map.lua',
    'config/weapons.lua',
    -- AFTER geo.lua, which it calls at LOAD time: BR.NormHash builds its
    -- hash-keyed lookup, and loading it earlier would key every row on nil.
    'config/vehicles.lua',
    'config/loot.lua',
    -- The cue table and the sound catalogue /brsfx browses. Pure data plus three
    -- pure lookups, which is exactly this suite's remit -- and the lookups are
    -- the half of the audition tool that CAN be tested outside the game. What
    -- a sound actually sounds like is a client's business and an ear's; which
    -- rows the search hands the owner to listen to is arithmetic.
    'config/audio.lua',
    -- AFTER config/loot.lua AND config/weapons.lua, as the manifest orders it:
    -- it resolves its payout pools out of their rarity buckets and id lookups
    -- at LOAD time. Here for 'loot.rooftop', which asserts the airdrop crate's
    -- and the Volts pile's drawn sizes against the numbers the owner gave.
    'config/airdrop.lua',
    'shared/storm_solve.lua',
    'shared/loot_gen.lua',
    'shared/combat_solve.lua',
    'shared/health_solve.lua',
    -- AFTER enums.lua, which it does not read at load time but whose
    -- BR.PlayerState the tests below build their views from.
    'shared/spectate_solve.lua',
    'shared/evidence_buf.lua',
    -- AFTER combat_solve, not before: it builds its severity table from
    -- BR.ShotRefusal's values at load time, so loading it first would leave every
    -- key nil and classify nothing -- silently, since a missing severity reads as
    -- "not a countable refusal".
    'shared/incident_build.lua',
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

-- ------------------------------------------------------------- key tokens ---

describe('BR.KeyToken')
do
    -- ═══ WHAT THIS IS FOR ═══
    --
    -- Owner, 2026-08-22 (#209), about the start-of-match voice notice: "we
    -- should make our own glyphs for keys. For example, this message looks too
    -- bland and hard coded: 'Voice chat is set to nearby. Hold N to speak...'"
    --
    -- The wording is composed in Lua and the plate is drawn in TypeScript, so
    -- what crosses the boundary is the sentence with a HOLE in it. This builds
    -- the hole. ui-src/src/ui/KeyCap.tsx parses it; tools/check_key_glyphs.lua
    -- is what checks the two agree, since nothing executes both languages.

    -- IT NAMES THE COMMAND. That is the entire design: a command name cannot go
    -- stale, and a key LABEL substituted at compose time is a photograph of the
    -- binding at that instant. These strings outlive the instant -- a sticky
    -- notice stays up for as long as the big map is open.
    ok(BR.KeyToken('brptt') == '{key:brptt}',
       'builds a hole naming the command', tostring(BR.KeyToken('brptt')))

    -- DIFFERENT COMMANDS ARE DIFFERENT HOLES, which is only worth asserting
    -- because a constant would satisfy the line above.
    ok(BR.KeyToken('brpausemenu') == '{key:brpausemenu}',
       'and a different command gives a different hole',
       tostring(BR.KeyToken('brpausemenu')))
    ok(BR.KeyToken('brptt') ~= BR.KeyToken('brinteract'),
       'two commands never collapse to one token')

    -- IT IS A PURE FUNCTION OF ITS ARGUMENT and reads no key layer at all.
    -- Nothing here resolves a binding: that happens on the page, on every
    -- rebind push. A version that reached for BR.Keys would reintroduce exactly
    -- the compose-time snapshot the token exists to avoid, and it would do so
    -- invisibly because the string would still look right on the day.
    ok(BR.KeyToken('brptt') == BR.KeyToken('brptt'),
       'the same command always gives the same token')

    -- NO CRASH ON A NIL COMMAND. It is a programming error rather than a real
    -- state, but this is called while composing a sentence that is about to go
    -- on screen, and a hard error there costs the whole notice rather than one
    -- glyph. tostring() makes it visible instead: '{key:nil}' draws a dash.
    local okCall, out = pcall(BR.KeyToken, nil)
    ok(okCall and type(out) == 'string',
       'a nil command does not throw mid-sentence', tostring(out))
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

-- ---------------------------------------------------------------- polygon ---

describe('polygon')
do
    -- A UNIT SQUARE FIRST, because every answer in it can be checked by eye. If
    -- the crossing rule is wrong, it is wrong here too, and here the expected
    -- value is not a matter of opinion.
    local sq = {
        { x = 0.0, y = 0.0 }, { x = 10.0, y = 0.0 },
        { x = 10.0, y = 10.0 }, { x = 0.0, y = 10.0 },
    }
    ok(BR.PointInPolygon(5.0, 5.0, sq), 'the middle of a square is inside')
    ok(not BR.PointInPolygon(15.0, 5.0, sq), 'a point beside it is outside')
    ok(not BR.PointInPolygon(5.0, -0.001, sq), 'a millimetre below the base is outside')
    ok(BR.PointInPolygon(0.0, 0.0, sq), 'a corner is inside')
    ok(BR.PointInPolygon(10.0, 10.0, sq), 'the opposite corner is inside')
    ok(BR.PointInPolygon(5.0, 0.0, sq), 'the middle of an edge is inside')
    ok(BR.PointInPolygon(0.0, 5.0, sq), 'and of a VERTICAL edge, which the ray runs along')

    -- The vertex double-count. A ray cast through a vertex meets both edges
    -- that share it; counting both flips the answer for a genuinely interior
    -- point. `(a.y > y) ~= (b.y > y)` is what stops that, and a diamond puts a
    -- vertex on the same horizontal as the point being tested.
    local diamond = {
        { x = 0.0, y = 0.0 }, { x = 10.0, y = -10.0 },
        { x = 20.0, y = 0.0 }, { x = 10.0, y = 10.0 },
    }
    ok(BR.PointInPolygon(10.0, 0.0, diamond),
        'the centre of a diamond is inside, with a vertex either side of it')
    ok(not BR.PointInPolygon(-5.0, 0.0, diamond), 'and a point level with both is not')

    -- Degenerate input degrades to false rather than erroring inside a match
    -- transition, which is where BR.Config.Map.InBounds is called from.
    ok(not BR.PointInPolygon(0.0, 0.0, nil), 'a nil polygon contains nothing')
    ok(not BR.PointInPolygon(0.0, 0.0, {}), 'an empty polygon contains nothing')
    ok(not BR.PointInPolygon(0.0, 0.0, { { x = 0.0, y = 0.0 }, { x = 1.0, y = 1.0 } }),
        'two points are a line, not an area')

    -- Shoelace and perimeter on the same square: 100 m^2 and 40m, counted on
    -- fingers. The area is SIGNED, and this ring is counter-clockwise.
    ok(near(BR.PolygonArea(sq), 100.0), 'square area', BR.PolygonArea(sq))
    ok(near(BR.PolygonPerimeter(sq), 40.0), 'square perimeter', BR.PolygonPerimeter(sq))
    local rev = { sq[4], sq[3], sq[2], sq[1] }
    ok(near(BR.PolygonArea(rev), -100.0), 'walking it the other way flips the sign')
    ok(BR.PointInPolygon(5.0, 5.0, rev), 'but not the containment answer')

    -- A figure-eight must be REFUSED by the simplicity check rather than
    -- silently answered. This is the shape a survey produces from two clicks in
    -- the wrong order, and ray casting reports the crossed lobe as outside.
    local bowtie = {
        { x = 0.0, y = 0.0 }, { x = 10.0, y = 10.0 },
        { x = 0.0, y = 10.0 }, { x = 10.0, y = 0.0 },
    }
    ok(BR.PolygonIsSimple(sq), 'a square is a simple ring')
    ok(not BR.PolygonIsSimple(bowtie), 'a bow tie is not')

    -- Distance to the outline is to the nearest SEGMENT, not the nearest
    -- infinite line: past the end of an edge, the answer is the corner.
    ok(near(BR.DistanceToPolygonEdge(5.0, 15.0, sq), 5.0),
        'distance straight out from an edge')
    ok(near(BR.DistanceToPolygonEdge(13.0, 14.0, sq), 5.0),
        'distance past a corner is measured to the corner')
    ok(near(BR.DistanceToPolygonEdge(5.0, 4.0, sq), 4.0),
        'and it is unsigned -- an inside point still reports a positive distance')
end

describe('polygon.boundary')
do
    -- THE REAL SURVEYED RING, because that is the one POIs were deleted
    -- against. A test on a square proves the algorithm; this proves the
    -- algorithm against the data.
    local B = BR.Config.Map.Boundary
    ok(#B == 66, 'the boundary is the surveyed 66 points', #B)
    ok(BR.PolygonIsSimple(B), 'and it does not cross itself')

    -- CLEARLY INSIDE.
    ok(BR.Config.Map.InBounds(0.0, 0.0), 'Los Santos is on the map')
    ok(BR.Config.Map.InBounds(358.0, 1976.3), 'so is the survey centroid')
    ok(BR.Config.Map.InBounds(1900.0, 3700.0), 'so is Sandy Shores')

    -- CLEARLY OUTSIDE: the four corners of the old rectangle, which is the
    -- whole reason this ring exists. Each is open ocean.
    local A = BR.Config.Storm.mapAABB
    local corners = 0
    for _, c in ipairs({ { A.min.x, A.min.y }, { A.min.x, A.max.y },
                         { A.max.x, A.min.y }, { A.max.x, A.max.y } }) do
        if not BR.Config.Map.InBounds(c[1], c[2]) then corners = corners + 1 end
    end
    ok(corners == 4, 'every corner of mapAABB is off the map', ('%d of 4'):format(corners))

    -- ON A VERTEX and ON AN EDGE. Both must answer INSIDE, deterministically:
    -- a POI is deleted on this verdict, and the crossing count alone has no
    -- defined answer for a point sitting on the line it is counting crossings
    -- of. Every vertex is checked, not a sample -- there are only 66.
    local onVertex, onEdge = 0, 0
    for i = 1, #B do
        local a = B[i]
        local b = B[(i % #B) + 1]
        if BR.Config.Map.InBounds(a.x, a.y) and BR.PointOnPolygonEdge(a.x, a.y, B) then
            onVertex = onVertex + 1
        end
        local mx, my = (a.x + b.x) * 0.5, (a.y + b.y) * 0.5
        if BR.Config.Map.InBounds(mx, my) and BR.PointOnPolygonEdge(mx, my, B) then
            onEdge = onEdge + 1
        end
    end
    ok(onVertex == #B, 'every vertex reads as on the outline and inside', onVertex)
    ok(onEdge == #B, 'so does the midpoint of every edge', onEdge)

    -- INSIDE THE BBOX, OUTSIDE THE SHAPE. The concave bits around the docks and
    -- the airport are exactly this case, and they are the reason a bounding box
    -- was never good enough: (-650, -2900) is 87m south of the shoreline the
    -- owner drew between the LSIA approach and the container terminal, and sits
    -- comfortably inside the bbox on both axes.
    local minX, minY, maxX, maxY = BR.PolygonBounds(B)
    local notch = { { -650.0, -2900.0 }, { -300.0, -3200.0 }, { -1500.0, -3400.0 } }
    local inBox, outShape = 0, 0
    for _, p in ipairs(notch) do
        if p[1] > minX and p[1] < maxX and p[2] > minY and p[2] < maxY then
            inBox = inBox + 1
        end
        if not BR.Config.Map.InBounds(p[1], p[2]) then outShape = outShape + 1 end
    end
    ok(inBox == #notch, 'the notch probes are inside the bounding box', inBox)
    ok(outShape == #notch, 'and outside the shape', outShape)

    -- The survey's own figures, so a silent edit to the table shows up in the
    -- test suite as well as in tools/check_boundary.lua.
    ok(near(BR.PolygonPerimeter(B), 34355.0, 10.0), 'perimeter matches the survey',
        ('%.0fm'):format(BR.PolygonPerimeter(B)))
    ok(near(math.abs(BR.PolygonArea(B)), 51057000.0, 10000.0),
        'area matches the survey',
        ('%.2f km^2'):format(math.abs(BR.PolygonArea(B)) / 1e6))

    -- The rule the owner stated, asserted over the live tables.
    local badPoi, badAmb = 0, 0
    for _, p in ipairs(BR.Config.Map.POIs) do
        if not BR.Config.Map.InBounds(p.x, p.y) then badPoi = badPoi + 1 end
    end
    for _, a in ipairs(BR.Config.Map.AmbulanceSpawns) do
        if not BR.Config.Map.InBounds(a.x, a.y) then badAmb = badAmb + 1 end
    end
    ok(badPoi == 0, 'every POI is inside the surveyed boundary', badPoi)
    ok(badAmb == 0, 'and every ambulance spawn is too', badAmb)
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

describe('combat.melee')
do
    -- MELEE IS VALIDATED LIKE ANYTHING ELSE, and needed two fields to be.
    -- Without a maxRange the range check is skipped entirely, and without a
    -- minInterval so is the rate check -- so a machete could have "hit"
    -- somebody across the street, as fast as the events arrived.
    local cfg = BR.Config.Combat
    for _, m in ipairs(BR.Config.Melee) do
        ok(m.maxRange and m.maxRange > 0 and m.maxRange < 6.0,
            ('%s has a swing reach'):format(m.id), tostring(m.maxRange))
        ok(m.minInterval and m.minInterval > 0,
            ('%s has a swing cycle'):format(m.id), tostring(m.minInterval))
    end

    local machete = BR.Config.WeaponById['machete']
    local function ctx(over)
        local c = {
            sameSrc = false, sameMatch = true, shooterLive = true,
            victimLive = true, sameSquad = false, heldItem = 'machete',
        }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end

    ok(BR.ValidateShot({ weapon = machete.hash, dist = 1.5, sinceLastMs = 600 },
        ctx(), cfg), 'a swing in reach lands')

    local _, why = BR.ValidateShot(
        { weapon = machete.hash, dist = 40.0, sinceLastMs = 600 }, ctx(), cfg)
    ok(why == BR.ShotRefusal.TOO_FAR,
        'a machete cannot reach across the street', tostring(why))

    -- A melee weapon has no magazine, so the ammo check must not refuse it --
    -- `clip` is nil for melee and nil is not "empty".
    ok(BR.ValidateShot({ weapon = machete.hash, dist = 1.5, sinceLastMs = 600 },
        ctx({ clip = nil }), cfg),
        'and having no magazine is not the same as having no ammo')
end

describe('combat.fists')
do
    -- THE PUNCH THAT WAS A CHEAT SIGNAL.
    --
    -- Slot 0 is fists and holds nothing, so a player throwing a punch has an
    -- empty active slot. The validator resolved WEAPON_UNARMED against
    -- WeaponByHash, missed, and refused it as "weapon is not one this gamemode
    -- issues" -- so fists did no damage in a game where everyone lands
    -- unarmed, and a dozen honest swings tripped the anticheat threshold.
    local cfg = BR.Config.Combat

    -- The literal weaponType from the user's /brdamagelog capture, 2026-08-08.
    -- Pinned as the number the engine actually sent rather than as
    -- BR.Config.Fists.hash, so this test proves the two agree.
    local CAPTURED_UNARMED = 2725352035   -- 0xA2719263

    ok(BR.Config.WeaponByHash[BR.NormHash(CAPTURED_UNARMED)] == BR.Config.Fists,
        'the captured unarmed hash resolves to fists')
    ok(BR.Config.Fists.damage and BR.Config.Fists.damage > 0,
        'and fists do damage', tostring(BR.Config.Fists.damage))

    local function ctx(over)
        local c = {
            sameSrc = false, sameMatch = true, shooterLive = true,
            victimLive = true, sameSquad = false, heldItem = 'fists',
        }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end

    ok(BR.ValidateShot(
        { weapon = CAPTURED_UNARMED, dist = 1.2, sinceLastMs = 600 }, ctx(), cfg),
        'a punch in reach lands')

    local _, why = BR.ValidateShot(
        { weapon = CAPTURED_UNARMED, dist = 40.0, sinceLastMs = 600 }, ctx(), cfg)
    ok(why == BR.ShotRefusal.TOO_FAR,
        'and cannot reach across the street', tostring(why))

    -- THE TRAINER HOLE STAYS CLOSED. contextFor now reports 'fists' where it
    -- used to report nil, and the whole point of the nil->'fists' change is
    -- that 'fists' DISAGREES with everything except fists, where nil agreed
    -- with everything.
    local rifle = BR.Config.WeaponById['carbinerifle']
    local _, why2 = BR.ValidateShot(
        { weapon = rifle.hash, dist = 20.0, sinceLastMs = 500 },
        ctx({ clip = 30 }), cfg)
    ok(why2 == BR.ShotRefusal.NOT_HELD,
        'a conjured rifle over an empty slot is still refused', tostring(why2))

    -- WARMUP IS A PRACTICE PAD, NOT A SAFE ZONE (user call, 2026-08-08).
    -- Nothing stops the swing; nothing comes off anybody's health. And it must
    -- read as WARMUP rather than NOT_LIVE, because the two mean different
    -- things in a log: one is a rule, the other is a desync.
    local _, why3 = BR.ValidateShot(
        { weapon = CAPTURED_UNARMED, dist = 1.2, sinceLastMs = 600 },
        ctx({ warmup = true }), cfg)
    ok(why3 == BR.ShotRefusal.WARMUP, 'a warmup punch deals no damage',
        tostring(why3))
    ok(not BR.ShotSuspicious[BR.ShotRefusal.WARMUP],
        'and never counts toward the anticheat threshold')

    -- Either side being on the pad is enough -- otherwise somebody standing
    -- off it could hurt a player on it, which is the one thing it promises.
    local _, why4 = BR.ValidateShot(
        { weapon = BR.Config.WeaponById['carbinerifle'].hash, dist = 20.0 },
        ctx({ warmup = true, heldItem = 'carbinerifle', clip = 30 }), cfg)
    ok(why4 == BR.ShotRefusal.WARMUP, 'and it covers guns too, not just fists',
        tostring(why4))

    -- Fists are not loot and must never appear in anything the layout rolls
    -- against, or they would spawn in crates.
    for _, m in ipairs(BR.Config.Melee) do
        ok(m.id ~= 'fists', 'fists are not in the melee loot list')
    end
    for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        for _, m in ipairs(BR.Config.MeleeByRarity[r] or {}) do
            ok(m.id ~= 'fists', 'and not in any rarity bucket')
        end
    end
end

describe('combat.explosive')
do
    -- THE GRENADE THAT KILLED SOMEBODY FOR NOBODY.
    --
    -- Throwables carried no `damage` field, so ExpectedDamage returned 0.0 and
    -- applyHit bailed on `amount <= 0`. The validator accepted the hit, the
    -- server applied nothing, and the engine's own blast still killed the
    -- victim on their own machine -- an elimination credited to "(unknown)"
    -- in the user's log, 2026-08-08.
    local cfg = BR.Config.Combat

    -- Literal weaponType from the same capture.
    local CAPTURED_GRENADE = 2481070269   -- 0x93E220BD

    local nade = BR.Config.WeaponByHash[BR.NormHash(CAPTURED_GRENADE)]
    ok(nade and nade.id == 'grenade',
        'the captured grenade hash resolves to a grenade')
    ok(nade.explosive and nade.damage and nade.damage > 0,
        'which is explosive and does damage', tostring(nade.damage))

    local function ctx(over)
        local c = {
            sameSrc = false, sameMatch = true, shooterLive = true,
            victimLive = true, sameSquad = false,
            -- The realistic case: the last grenade is gone from the slot by
            -- the time it goes off, so the thrower is holding fists.
            heldItem = 'fists', threwRecently = true,
        }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end

    ok(BR.ValidateShot({ weapon = CAPTURED_GRENADE, dist = 6.0 }, ctx(), cfg),
        'a blast from a grenade you threw lands, with empty hands')

    local _, why = BR.ValidateShot({ weapon = CAPTURED_GRENADE, dist = 6.0 },
        ctx({ threwRecently = false }), cfg)
    ok(why == BR.ShotRefusal.NOT_THROWN,
        'a blast from one you never threw does not', tostring(why))

    -- Still holding them (more than one in the stack) is the other honest case.
    ok(BR.ValidateShot({ weapon = CAPTURED_GRENADE, dist = 6.0 },
        ctx({ heldItem = 'grenade', threwRecently = false }), cfg),
        'and holding the stack is enough on its own')

    -- RANGE IS THROW PLUS BLAST. A victim can be a whole blast radius further
    -- from the thrower than the grenade ever travelled.
    ok(BR.ValidateShot({ weapon = CAPTURED_GRENADE, dist = 50.0 }, ctx(), cfg),
        'a long throw with the victim on the far edge is in bounds')
    local _, why2 = BR.ValidateShot(
        { weapon = CAPTURED_GRENADE, dist = 250.0 }, ctx(), cfg)
    ok(why2 == BR.ShotRefusal.TOO_FAR,
        'but a blast two hundred metres away is not', tostring(why2))

    -- NO RATE CHECK. A cluster of stickies detonates together; every one of
    -- those is a legitimate event in the same millisecond.
    ok(BR.ValidateShot({ weapon = CAPTURED_GRENADE, dist = 6.0, sinceLastMs = 0 },
        ctx(), cfg),
        'two detonations in the same millisecond are both legitimate')

    -- FLAT DAMAGE, and this is the check that would catch falloff creeping
    -- back in. The only distance the server knows is thrower-to-victim, and a
    -- grenade is thrown AWAY from the thrower -- so the victim standing on it
    -- is the FAR one. Falloff would make the direct hit the weakest hit.
    local near = BR.ShotDamage(CAPTURED_GRENADE, BR.Rarity.COMMON, 5.0, 0, cfg)
    local far  = BR.ShotDamage(CAPTURED_GRENADE, BR.Rarity.COMMON, 44.0, 0, cfg)
    ok(near > 0.0 and math.abs(near - far) < 0.001,
        'blast damage does not fall off with distance from the thrower',
        ('%.1f vs %.1f'):format(near, far))

    -- ...and no bone multiplier. hitComponent came back 0 on the capture: a
    -- blast does not land on a head.
    local HEAD = 20
    local _, mult = BR.ShotDamage(CAPTURED_GRENADE, BR.Rarity.COMMON, 5.0,
                                  HEAD, cfg)
    ok(mult == 1.0, 'and no headshot multiplier applies to a blast',
        tostring(mult))
    -- Load-bearing: the same component through a rifle must NOT be 1.0, or
    -- the assertion above is passing because head multipliers do nothing.
    local _, rmult = BR.ShotDamage(BR.Config.WeaponById['carbinerifle'].hash,
                                   BR.Rarity.COMMON, 5.0, HEAD, cfg)
    ok(rmult > 1.0, 'while the same bone through a rifle is a headshot',
        tostring(rmult))

    -- HURTING YOURSELF IS ALLOWED; DOING IT REPEATEDLY IS NOT.
    --
    -- The first version refused self-damage outright, on the reasoning that
    -- you cannot shoot yourself in this game. Too strong, and the user pushed
    -- back on it: you can absolutely stand in your own grenade, and refusing
    -- that makes explosives free to spam at your own feet in a crowd. What
    -- remains a signal is REPETITION, which is a fact about history and
    -- therefore the server's to count -- this function only decides what to do
    -- once it is told.
    ok(BR.ValidateShot({ weapon = CAPTURED_GRENADE, dist = 1.0 },
        ctx({ sameSrc = true }), cfg),
        'catching your own blast hurts you like anybody else would')

    local _, whySelf = BR.ValidateShot({ weapon = CAPTURED_GRENADE, dist = 1.0 },
        ctx({ sameSrc = true, selfRepeat = true }), cfg)
    ok(whySelf == BR.ShotRefusal.SELF,
        'but doing it again and again is refused', tostring(whySelf))
    ok(BR.ShotSuspicious[BR.ShotRefusal.SELF],
        'and that is the one that fires the anticheat response')

    -- THE WORLD'S DAMAGE IS NEVER A REFUSAL. A fall, a fire, drowning, a car:
    -- every one of these arrives as a weaponDamageEvent with a weaponType hash
    -- indistinguishable from a gun's, and every one of them would have been
    -- cancelled and counted as cheating by the old "is it in our weapon table"
    -- rule. This is also the answer to whether NOT_THROWN could block an
    -- ambient car explosion: it cannot, because WEAPON_EXPLOSION never reaches
    -- the validator at all.
    for _, e in ipairs(BR.Config.Environmental) do
        ok(BR.Config.EnvironmentalFor(e.hash) ~= nil,
            ('%s is recognised as the world\'s doing'):format(e.id))
        ok(BR.Config.WeaponByHash[BR.NormHash(e.hash)] == nil,
            ('and %s is never treated as a weapon we issued'):format(e.id))
    end
    -- Signed too: the engine hands these back the same way it hands back
    -- weapon hashes, and half of them have the top bit set.
    local fall = BR.Config.Environmental[1]
    ok(BR.Config.EnvironmentalFor(fall.hash - 0x100000000) ~= nil,
        'and they resolve from the signed form the engine returns')

    -- Smoke resolves as a weapon (so it is never a refusal) and deals nothing.
    local smoke = BR.Config.WeaponById['smoke']
    ok(BR.ValidateShot({ weapon = smoke.hash, dist = 4.0 },
        ctx({ heldItem = 'smoke' }), cfg), 'smoke is never a refusal')
    ok(BR.ShotDamage(smoke.hash, BR.Rarity.COMMON, 4.0, 0, cfg) == 0.0,
        'and does no damage')
end

describe('descent.classify')
do
    -- THE CANOPY IS THE CASE THAT MATTERS. Both altitude nets in match.lua
    -- compared a per-TICK delta of 1.0m at a 250ms tick, which a parachute --
    -- about 2 m/s, so half a metre per tick -- could never trip. So a gliding
    -- player read as stationary, the stuck-lander net promoted them to ALIVE
    -- in mid-air, and the match went live under them (user, 2026-08-06).
    local rate = BR.Config.Match.descendRate

    -- Freefall: never in doubt, then or now.
    ok(BR.ClassifyDescent(500.0, 0, 450.0, 1000, rate) == 'falling',
        'freefall reads as falling')

    -- A PARACHUTE, at the rate that broke it: 2 m/s over a 250ms tick is
    -- 0.5m, which the old 1.0m per-tick test called "not moving".
    ok(BR.ClassifyDescent(300.0, 0, 299.5, 250, rate) == 'falling',
        'and so does a canopy at 2 m/s over a single 250ms tick')

    -- A hung client at a frozen altitude still reads as still, which is the
    -- whole reason the stuck-lander net exists.
    ok(BR.ClassifyDescent(120.0, 0, 120.0, 1000, rate) == 'still',
        'a frozen altitude still reads as still')

    -- Standing on the ground, with the tiny jitter a sampled position has.
    ok(BR.ClassifyDescent(12.0, 0, 11.95, 1000, rate) == 'still',
        'and so does sampling jitter on the ground')

    -- NO FRESH SAMPLE IS NOT AN ANSWER. The tick is 4Hz and positions arrive
    -- at 2Hz, so half of all ticks see the same reading twice -- counting
    -- those as "not moving" is exactly how a falling player accumulated
    -- stillness.
    ok(BR.ClassifyDescent(300.0, 500, 299.0, 500, rate) == nil,
        'two samples with the same timestamp answer nothing')
    ok(BR.ClassifyDescent(nil, nil, 300.0, 500, rate) == nil,
        'and neither does the first sample of all')

    -- Going UP (a glider catching lift, or a lift) is not descending.
    ok(BR.ClassifyDescent(100.0, 0, 105.0, 1000, rate) == 'still',
        'climbing is not descending')
end

describe('combat.validate')
do
    -- M6. Every check here runs against what the SERVER believes -- roster
    -- positions, the inventory it maintains -- never against anything the
    -- shooter reported, so a client that lies about its weapon, its range or
    -- its rate of fire is failing against numbers it does not control.
    local cfg = BR.Config.Combat
    local rifle = BR.Config.WeaponById['carbinerifle']

    local function ctx(over)
        local c = {
            sameSrc = false, sameMatch = true, shooterLive = true,
            victimLive = true, sameSquad = false,
            heldItem = 'carbinerifle', clip = 30,
        }
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end

    local ok1 = BR.ValidateShot(
        { weapon = rifle.hash, dist = 50.0, sinceLastMs = 500 }, ctx(), cfg)
    ok(ok1, 'an ordinary shot is accepted')

    -- THE SIGNED HASH, AGAIN. weaponDamageEvent reports the weapon hash
    -- signed, exactly like GetCurrentPedWeapon -- and carbinerifle is one of
    -- the twenty with the top bit set. Without normalisation inside the
    -- validator, half the arsenal would read as "not a weapon this gamemode
    -- issues", i.e. every carbine hit would be refused as a cheat.
    local signed = rifle.hash - 0x100000000
    local okSigned, whySigned = BR.ValidateShot(
        { weapon = signed, dist = 50.0, sinceLastMs = 500 }, ctx(), cfg)
    ok(okSigned, 'and so is the same shot with the SIGNED hash the engine sends',
        tostring(whySigned))

    -- Refusals.
    local _, why = BR.ValidateShot(
        { weapon = rifle.hash, dist = 50.0, sinceLastMs = 500 },
        ctx({ sameSquad = true }), cfg)
    ok(why == BR.ShotRefusal.SAME_SQUAD, 'a squadmate cannot be shot', tostring(why))

    _, why = BR.ValidateShot(
        { weapon = rifle.hash, dist = 50.0, sinceLastMs = 500 },
        ctx({ heldItem = 'pistol' }), cfg)
    ok(why == BR.ShotRefusal.NOT_HELD,
        'a shot from a weapon the server did not issue is refused', tostring(why))

    -- AN EMPTY SLOT IS AN ANSWER, and this is the trainer case. A weapon
    -- conjured from outside the inventory leaves the slot empty, and the
    -- earlier version skipped the check entirely when it was nil -- so the
    -- shot validated, dealt full damage, and spent no ammo because there was
    -- no slot to spend from.
    -- Built by hand rather than through ctx(): `{ heldItem = nil }` is a table
    -- with no heldItem key at all, so it overrides nothing.
    local empty = ctx()
    empty.heldItem = nil
    _, why = BR.ValidateShot(
        { weapon = rifle.hash, dist = 50.0, sinceLastMs = 500 }, empty, cfg)
    ok(why == BR.ShotRefusal.NOT_HELD,
        'and so is a shot from a player holding nothing the server issued',
        tostring(why))

    _, why = BR.ValidateShot(
        { weapon = rifle.hash, dist = 50.0, sinceLastMs = 500 },
        ctx({ clip = 0 }), cfg)
    ok(why == BR.ShotRefusal.NO_AMMO,
        'and one from an empty magazine', tostring(why))

    _, why = BR.ValidateShot(
        { weapon = rifle.hash, dist = 9000.0, sinceLastMs = 500 }, ctx(), cfg)
    ok(why == BR.ShotRefusal.TOO_FAR, 'a shot from orbit is refused', tostring(why))

    _, why = BR.ValidateShot(
        { weapon = rifle.hash, dist = 50.0, sinceLastMs = 1 }, ctx(), cfg)
    ok(why == BR.ShotRefusal.TOO_FAST,
        'and one faster than the weapon can cycle', tostring(why))

    _, why = BR.ValidateShot(
        { weapon = 0xDEADBEEF, dist = 50.0, sinceLastMs = 500 }, ctx(), cfg)
    ok(why == BR.ShotRefusal.NO_WEAPON,
        'a weapon we never issued is refused', tostring(why))

    -- SLACK MUST NOT REFUSE HONEST PLAY, and this is the assertion that
    -- matters most. Roster positions are sampled at 2Hz, so both players can
    -- be ~4.5m stale at a sprint; a shot at the weapon's nominal maximum has
    -- to survive that or the game is unplayable for the honest player.
    local edge = rifle.maxRange + 20.0
    ok(BR.ValidateShot({ weapon = rifle.hash, dist = edge, sinceLastMs = 500 },
        ctx(), cfg), 'a shot at nominal max range plus sampling lag still lands',
        ('%.0fm vs maxRange %.0f'):format(edge, rifle.maxRange))

    -- Damage is recomputed from OUR tables, never read off the event -- the
    -- payload's own damage figure is precisely the field a multiplier edits.
    local H = BR.Config.HitComponent
    local chest = BR.ShotDamage(rifle.hash, BR.Rarity.COMMON, 10.0, H.CHEST, cfg)
    local head  = BR.ShotDamage(rifle.hash, BR.Rarity.COMMON, 10.0, H.HEAD, cfg)
    local wrist = BR.ShotDamage(rifle.hash, BR.Rarity.COMMON, 10.0, H.LEFT_WRIST, cfg)
    ok(chest > 0.0, 'a hit computes real damage', tostring(chest))
    ok(head > chest and wrist < chest,
        'damage varies by bone: head above chest, wrist below',
        ('head %.1f chest %.1f wrist %.1f'):format(head, chest, wrist))
    ok(BR.ShotDamage(signed, BR.Rarity.COMMON, 10.0, H.CHEST, cfg) == chest,
        'and is identical whether the hash arrives signed or unsigned')

    -- A HEADSHOT IS A CLOSE-RANGE PAYOFF (user call, 2026-08-07). Across a
    -- car park it should reward aim; across the map it should not simply
    -- delete somebody.
    local R = BR.Config.HeadshotRange
    local near = BR.Config.BodyMultFor(H.HEAD, R.full - 5.0)
    local mid  = BR.Config.BodyMultFor(H.HEAD, (R.full + R.fade) * 0.5)
    local far  = BR.Config.BodyMultFor(H.HEAD, R.fade + 200.0)
    ok(near > mid and mid > far,
        'the head multiplier decays with distance',
        ('near %.2f mid %.2f far %.2f'):format(near, mid, far))
    ok(math.abs(near - BR.Config.BodyMult[H.HEAD]) < 1e-6,
        'full strength inside the close band')
    ok(far >= 1.0,
        'and a long headshot is still never worth LESS than a chest hit',
        tostring(far))

    -- Only the head group cares about range. A chest hit is a chest hit.
    ok(BR.Config.BodyMultFor(H.CHEST, 5.0)
        == BR.Config.BodyMultFor(H.CHEST, 500.0),
        'body multipliers other than the head do not vary with range')

    -- A SNIPER IS STILL A SNIPER. The falloff must not quietly turn the
    -- long-range weapons into non-threats: they one-shot through raw damage
    -- to the CHEST, which this never touches.
    local hs = BR.Config.WeaponById['heavysniper']
    ok(BR.ShotDamage(hs.hash, BR.Rarity.COMMON, 300.0, H.CHEST, cfg) > 100.0,
        'a heavy sniper still one-shots centre mass at 300m',
        ('%.0f'):format(BR.ShotDamage(hs.hash, BR.Rarity.COMMON, 300.0, H.CHEST, cfg)))

    -- An UNKNOWN component is worth full damage, never zero. A bone we have
    -- not mapped must not silently delete a hit.
    ok(BR.ShotDamage(rifle.hash, BR.Rarity.COMMON, 10.0, 999, cfg) == chest,
        'an unmapped body part is worth full damage')
    ok(BR.ShotDamage(rifle.hash, BR.Rarity.COMMON, 10.0, nil, cfg) == chest,
        'and so is a missing one')

    -- TWO HEADSHOTS TO KILL, for every weapon that is not a hand cannon
    -- (user call, 2026-08-07). Health is 100, so a headshot has to land in
    -- (50, 100] -- above half, at or under a full bar.
    local twoShot, oneShot = {}, {}
    for _, w in ipairs(BR.Config.Weapons) do
        local d = BR.ShotDamage(w.hash, BR.Rarity.COMMON, 5.0, H.HEAD, cfg)
        if d > 100.0 then
            oneShot[#oneShot + 1] = w.id
        elseif d > 50.0 then
            twoShot[#twoShot + 1] = w.id
        end
    end
    ok(#twoShot > 10, 'most weapons take two headshots to kill',
        ('%d weapons'):format(#twoShot))
    -- The exceptions must be the ones that SHOULD one-shot, and "should" is
    -- expressed as raw damage rather than by matching names: anything hitting
    -- for 60+ to the chest is a sniper, a revolver or a shotgun by
    -- construction, and a name test would quietly pass a future weapon called
    -- something unexpected.
    local surprises = {}
    for _, id in ipairs(oneShot) do
        local w = BR.Config.WeaponById[id]
        if (w.damage or 0) < 60 then surprises[#surprises + 1] = id end
    end
    ok(#surprises == 0,
        'and the only one-shot headshots come from weapons that hit for 60+',
        table.concat(surprises, ', '))
end

describe('combat.refusal.classes')
do
    -- WHAT CAN BECOME AN INCIDENT, PINNED.
    --
    -- BR.Damage.noteRefusal opens with `if not BR.ShotSuspicious[why] then
    -- return end`, so this table alone decides which refusals can ever reach
    -- the Ringmaster feed -- and now, which can ever open an incident somebody
    -- has to review. A reason quietly added to it does not fail anything: it
    -- just starts filing cases. The first warmup scrap of every match would do
    -- it, because since fists became a real weapon EVERY player has the means
    -- to generate rule refusals constantly.
    --
    -- So the classification is asserted from both ends and checked for
    -- exhaustiveness. Adding a reason to BR.ShotRefusal without filing it under
    -- one of these two lists fails here, which is the point: the decision is
    -- forced while the shape is on screen rather than discovered from a queue
    -- full of friendly fire.

    -- RULES. Things an HONEST client does constantly; the game simply declines
    -- them. None of these may ever count, and none may ever file an incident.
    local RULES = {
        'WARMUP', 'SAME_SQUAD', 'NOT_LIVE', 'OTHER_MATCH',
    }
    -- MEANS. A weapon the server never issued, a magazine it never filled, a
    -- range or cadence the weapon does not have. No honest way to produce one.
    local MEANS = {
        'NO_WEAPON', 'NOT_HELD', 'NO_AMMO', 'TOO_FAR', 'TOO_FAST',
        'NOT_THROWN', 'SELF',
    }

    for _, name in ipairs(RULES) do
        local why = BR.ShotRefusal[name]
        ok(why ~= nil, ('%s is a real refusal reason'):format(name))
        ok(not BR.ShotSuspicious[why],
            ('%s is a rule, so it never counts toward the threshold'):format(name))
    end

    for _, name in ipairs(MEANS) do
        local why = BR.ShotRefusal[name]
        ok(why ~= nil, ('%s is a real refusal reason'):format(name))
        ok(BR.ShotSuspicious[why] == true,
            ('%s is a means, so it counts'):format(name))
    end

    -- EXHAUSTIVE, so a new reason cannot arrive unclassified. OK is nil by
    -- construction and therefore never appears in pairs().
    local filed = {}
    for _, name in ipairs(RULES) do filed[name] = true end
    for _, name in ipairs(MEANS) do filed[name] = true end
    local unfiled = {}
    for name in pairs(BR.ShotRefusal) do
        if not filed[name] then unfiled[#unfiled + 1] = name end
    end
    table.sort(unfiled)
    ok(#unfiled == 0,
        'every refusal reason is filed as either a rule or a means',
        table.concat(unfiled, ', '))

    -- And nothing may be suspicious that is not a refusal reason at all -- a
    -- stale string left behind by a rename would count forever against nobody.
    local known = {}
    for _, why in pairs(BR.ShotRefusal) do known[why] = true end
    local orphans = 0
    for why in pairs(BR.ShotSuspicious) do
        if not known[why] then orphans = orphans + 1 end
    end
    ok(orphans == 0, 'nothing counts that is not a live refusal reason')

    -- FRIENDLY FIRE, END TO END. The one the owner asked about by name: a shot
    -- at a squadmate is refused, it is refused AS SAME_SQUAD rather than as
    -- something that reads like cheating, and that reason cannot be counted.
    local cfg = BR.Config.Combat
    local rifle = BR.Config.WeaponById['carbinerifle']
    local _, whyMate = BR.ValidateShot(
        { weapon = rifle.hash, dist = 20.0, sinceLastMs = 500 },
        {
            sameSrc = false, sameMatch = true, warmup = false,
            shooterLive = true, victimLive = true, sameSquad = true,
            heldItem = 'carbinerifle', clip = 30,
        }, cfg)
    ok(whyMate == BR.ShotRefusal.SAME_SQUAD,
        'shooting a squadmate is refused as friendly fire', tostring(whyMate))
    ok(not BR.ShotSuspicious[whyMate],
        'and a squad wipe by accident can never open an incident')
end

describe('evidence.buffer')
do
    -- WHAT A MATCH KNOWS, HELD UNTIL SOMEBODY NEEDS IT. The bugs worth catching
    -- here are the quiet ones: a buffer that stops appending, a departed player
    -- whose record is freed before anybody can report them, or evidence that
    -- ends up filed against whoever inherited a recycled server id.

    local buf = BR.EvidenceBuf.new({ chatMax = 3, killMax = 2 })

    ok(buf ~= nil, 'a buffer can be built')
    local s0 = buf:stats()
    ok(s0.live == 0 and s0.sealed == 0, 'and starts empty')

    -- BOUNDED, DROPPING OLDEST. Unbounded is a memory leak with a nice name.
    for i = 1, 6 do
        buf:noteChat(7, { text = 'line' .. i, at = i },
            { license = 'license:aaa', name = 'Dave', matchId = 41 })
    end
    local r = buf:get(7)
    ok(r ~= nil, 'a note starts tracking the player')
    ok(#r.chat == 3, 'chat is capped', tostring(r and #r.chat))
    ok(r.chat[1].text == 'line4' and r.chat[3].text == 'line6',
        'and keeps the most recent lines, not the first ones',
        r and (r.chat[1].text .. '..' .. r.chat[3].text))

    for i = 1, 4 do
        buf:noteKill(7, { victim = 'V' .. i, at = i })
    end
    ok(#buf:get(7).kills == 2, 'kills are capped independently',
        tostring(#buf:get(7).kills))

    -- METADATA ACCRETES AND NEVER FLICKERS BACK TO UNKNOWN. `license` is filled
    -- lazily by the roster, so a buffer that started before it was known must
    -- still end up with one -- and a later note that happens not to carry it
    -- must not erase it.
    local buf2 = BR.EvidenceBuf.new()
    buf2:noteChat(9, { text = 'hi', at = 1 }, { name = 'Early', matchId = 41 })
    ok(buf2:get(9).license == nil, 'a license we do not have yet is nil')
    buf2:noteChat(9, { text = 'ho', at = 2 }, { license = 'license:bbb' })
    ok(buf2:get(9).license == 'license:bbb', 'and is filled in when it arrives')
    ok(buf2:get(9).name == 'Early', 'without losing what was already known')
    buf2:noteChat(9, { text = 'hum', at = 3 }, { name = nil })
    ok(buf2:get(9).license == 'license:bbb',
        'and a later note carrying nothing does not erase it')

    -- SEALED, NOT DELETED -- the case the owner asked about by name: somebody
    -- causes trouble and leaves immediately.
    local sealed = buf:seal(7, 5000)
    ok(sealed ~= nil, 'a disconnect seals the record')
    ok(buf:get(7) == nil, 'so it is no longer under the server id')
    ok(sealed.leftAt == 5000, 'and remembers when they left',
        tostring(sealed.leftAt))
    ok(#buf:forLicense('license:aaa') == 1,
        'but it is still reachable by license')
    ok(#buf:departed(41) == 1, 'and still reportable as a departed player')
    ok(#buf:forLicense('license:aaa')[1].chat == 3,
        'with their chat intact')

    -- THE WHOLE REASON SEALING IS KEYED ON LICENSE. Server ids are recycled
    -- within the minute, so a record left under `src` would start collecting the
    -- next player's chat -- and an incident built from it would be a record
    -- about the wrong person.
    buf:noteChat(7, { text = 'innocent', at = 6000 },
        { license = 'license:ccc', name = 'Newcomer', matchId = 41 })
    ok(#buf:forLicense('license:aaa')[1].chat == 3,
        'so the departed player gains nothing from the new occupant')
    ok(#buf:forLicense('license:ccc') == 1
       and buf:forLicense('license:ccc')[1].chat[1].text == 'innocent',
        'and the newcomer starts clean')

    -- A reconnect inside one match is TWO sessions, not one merged record.
    ok(#buf:departed(41) == 1, 'sealing is per session')
    buf:seal(7, 7000)
    buf:noteChat(7, { text = 'again', at = 8000 },
        { license = 'license:ccc', name = 'Newcomer', matchId = 41 })
    ok(#buf:forLicense('license:ccc') == 2,
        'so a reconnect produces two records rather than merging them',
        tostring(#buf:forLicense('license:ccc')))

    -- Nothing at all for a license we have never seen. Not an error, not a
    -- fabricated empty record: an absent answer.
    ok(#buf:forLicense('license:nope') == 0, 'an unknown license has no records')
    ok(#buf:forLicense(nil) == 0, 'and neither does a nil one')

    -- THE DISCARD IS THE COST CONTROL. A match with no incident wrote nothing to
    -- DynamoDB and must now cost nothing in memory either.
    local before = buf:stats()
    ok(before.chatRows > 0, 'there is something to discard')
    local dropped = buf:clearMatch(41)
    ok(dropped > 0, 'match end drops the records', tostring(dropped))
    local after = buf:stats()
    ok(after.live == 0 and after.sealed == 0 and after.chatRows == 0,
        'and leaves nothing behind')

    -- Only the match that ended. Concurrent matches are the normal case on this
    -- server, and clearing all of them would destroy a live match's evidence.
    local buf3 = BR.EvidenceBuf.new()
    buf3:noteChat(1, { text = 'a' }, { license = 'l:1', matchId = 41 })
    buf3:noteChat(2, { text = 'b' }, { license = 'l:2', matchId = 42 })
    buf3:clearMatch(41)
    ok(buf3:get(1) == nil, 'the ended match is forgotten')
    ok(buf3:get(2) ~= nil, 'and a concurrent one is untouched')

    ok(buf3:seal(999, 1) == nil, 'sealing an unknown key is a no-op, not a crash')
end

describe('evidence.strips')
do
    -- A WEAPON THE GAMEMODE NEVER ISSUED, TAKEN OUT OF A HAND. It rides the same
    -- buffer as chat and kills for the same reason -- so a match that produces
    -- no incident still writes nothing anywhere -- but it is capped separately,
    -- because the thing it is evidence of is repetition and repetition is
    -- exactly what an offender controls the volume of.

    local buf = BR.EvidenceBuf.new({ stripMax = 3 })
    local meta = { license = 'license:cheat', name = 'Cheater', matchId = 41 }

    for i = 1, 5 do
        buf:noteStrip(7, { at = i * 100, weapon = 0x1B06D571 }, meta)
    end

    local r = buf:get(7)
    ok(r ~= nil, 'a strip starts tracking the player')
    ok(#r.strips == 3, 'strips are capped', r and #r.strips)
    ok(r.strips[1].at == 300 and r.strips[3].at == 500,
        'and the cap drops the OLDEST, which are the ones already on the row',
        r and tostring(r.strips[1].at))

    -- THE COUNT THAT WAS REALLY SEEN SURVIVES THE CAP. A timeline that stops
    -- early and looks complete tells an admin "this is everything they did"
    -- when it is not.
    ok(r.stripsSeen == 5, 'and the buffer still knows how many there were',
        r and tostring(r.stripsSeen))

    local s = buf:stats()
    ok(s.stripRows == 3 and s.stripsSeen == 5 and s.stripsDropped == 2,
        'the counters report the gap the caps produced',
        s.stripRows .. '/' .. s.stripsSeen .. '/' .. s.stripsDropped)

    -- ONE SIDE ONLY, unlike a kill. There is no second participant in a strip.
    local other = BR.EvidenceBuf.new()
    other:noteStrip(1, { at = 1 }, { license = 'l:a', matchId = 41 })
    ok(#other:forLicense('l:a') == 1 and #other:forLicense('l:b') == 0,
        'a strip is recorded against one player and nobody else')

    -- PROMOTION RAISES IT WITH THE REST. Filing a case is what buys the larger
    -- caps, and a strip cap left at the default would quietly become "the last
    -- twenty" for exactly the prolific offender the timeline exists to document.
    local buf2 = BR.EvidenceBuf.new()
    ok(BR.EvidenceBuf.PROMOTED.stripMax > BR.EvidenceBuf.DEFAULTS.stripMax,
        'the promoted strip cap is larger than the default')
    buf2:promote('license:cheat')
    for i = 1, BR.EvidenceBuf.DEFAULTS.stripMax + 10 do
        buf2:noteStrip(3, { at = i }, { license = 'license:cheat', matchId = 41 })
    end
    ok(#buf2:get(3).strips == BR.EvidenceBuf.DEFAULTS.stripMax + 10,
        'a promoted record keeps more strips than the default cap',
        #buf2:get(3).strips)

    -- TWO CAPS FOR ONE NUMBER, PINNED TOGETHER. incident_build.lua carries its
    -- own ceiling as a backstop for a caller that promoted differently -- the
    -- same relationship MAX_TIMELINE_KILLS has with killMax -- and the two
    -- disagreeing means either the buffer holds rows the timeline silently
    -- truncates, or the timeline claims room the buffer never fills.
    ok(BR.IncidentBuild.TIMELINE_LIMITS.MAX_TIMELINE_STRIPS
        == BR.EvidenceBuf.PROMOTED.stripMax,
        'the timeline cap and the promoted buffer cap are the same number',
        BR.IncidentBuild.TIMELINE_LIMITS.MAX_TIMELINE_STRIPS .. ' vs ' ..
        BR.EvidenceBuf.PROMOTED.stripMax)
    ok(BR.IncidentBuild.TIMELINE_LIMITS.MAX_TIMELINE_KILLS
        == BR.EvidenceBuf.PROMOTED.killMax,
        'and so are the kill pair, which is where that rule came from')
end

describe('timeline.strip-truncation')
do
    -- ═══ THE HONESTY FLAG, PINNED ON BOTH HALVES SEPARATELY ═══
    --
    -- A truncated KILL list says so twice: `matchTimelineComplete` goes false
    -- and `matchKillsSeen` states the real number. Strips have only the flag,
    -- and deliberately never will have a counter of their own -- the close write
    -- may touch only the attributes named in the game's IAM grant on
    -- `ringmaster-incidents`, and every one of them had to be added to a policy
    -- before the code writing it could run, so a counter would mean another
    -- round of that for a number the flag already carries.
    --
    -- SO THE FLAG IS THE WHOLE GUARANTEE, and there are two ways to lose it: the
    -- CAP dropping rows on the way onto the timeline, and the BUFFER having
    -- dropped them before the timeline ever saw them. Those are separate
    -- comparisons in separate expressions, and a case that trips both together
    -- passes with either one deleted -- which is exactly what the end-to-end
    -- suite does. These drive the pure functions directly so each is alone.
    local CAP = BR.IncidentBuild.TIMELINE_LIMITS.MAX_TIMELINE_STRIPS

    --- One evidence record holding `n` strips, with `seen` claimed as offered.
    local function records(n, seen)
        local strips = {}
        for i = 1, n do strips[i] = { at = i * 10, weapon = 0x11111111 } end
        return { { license = 'l:x', strips = strips, stripsSeen = seen or n,
                   kills = {}, killsSeen = 0 } }
    end

    -- (1) THE CAP DROPS ROWS. The buffer offered everything it had -- nothing
    --     was lost before this point -- and the timeline's own ceiling is what
    --     truncates.
    local over = BR.IncidentBuild.timelineOpen({
        matchId = 7, matchStartedAt = 0, records = records(CAP + 5),
    })
    local n = 0
    for _, e in ipairs(over.matchTimeline) do
        if e.kind == BR.IncidentBuild.STRIP_KIND then n = n + 1 end
    end
    ok(n == CAP, 'a filing truncates the strips at the timeline cap', n)
    ok(over.matchTimelineComplete == false,
        'and never claims to be complete when its own cap dropped rows',
        tostring(over.matchTimelineComplete))

    -- (2) THE BUFFER DROPPED ROWS FIRST. Everything the timeline was offered
    --     fits, so the cap truncates nothing -- and the record is still not
    --     complete, because rows were lost upstream of it.
    local lost = BR.IncidentBuild.timelineOpen({
        matchId = 7, matchStartedAt = 0, records = records(3, 40),
    })
    ok(lost.matchTimelineComplete == false,
        'and neither when the BUFFER dropped them before the timeline saw them',
        tostring(lost.matchTimelineComplete))

    -- (3) AND IT SAYS TRUE WHEN IT IS TRUE, which is the half that makes the
    --     flag worth reading at all.
    local whole = BR.IncidentBuild.timelineOpen({
        matchId = 7, matchStartedAt = 0, records = records(3),
    })
    ok(whole.matchTimelineComplete == true,
        'a timeline that lost nothing reports itself complete',
        tostring(whole.matchTimelineComplete))

    -- ...AND THE SAME TWO, ON THE CLOSE. It computes its own answer rather than
    -- inheriting the filing's, so the two have to be pinned apart.
    local closeCapped = BR.IncidentBuild.timelineClose({
        matchEndedAt = 9000, filedAtGameMs = 0, records = records(CAP + 5),
    })
    ok(closeCapped.matchTimelineComplete == false,
        'a close truncated by the cap says so too',
        tostring(closeCapped.matchTimelineComplete))

    local closeLost = BR.IncidentBuild.timelineClose({
        matchEndedAt = 9000, filedAtGameMs = 0, records = records(3, 40),
    })
    ok(closeLost.matchTimelineComplete == false,
        'and so does one whose buffer dropped rows',
        tostring(closeLost.matchTimelineComplete))

    local closeWhole = BR.IncidentBuild.timelineClose({
        matchEndedAt = 9000, filedAtGameMs = 0, records = records(3),
    })
    ok(closeWhole.matchTimelineComplete == true,
        'while an intact one still reports itself complete',
        tostring(closeWhole.matchTimelineComplete))

    -- (4) THE CLOSE'S TWO CLAUSES, PRISED APART. With nothing already written
    --     they move together -- rows dropped by the cap are by definition rows
    --     the buffer offered and the write did not take -- so either clause
    --     alone answers `false` and a mutation to one of them survives. A
    --     filing that has already spent part of the budget separates them: the
    --     close's own ceiling truncates while every row the buffer ever held is
    --     still accounted for across the two writes.
    local spentSome = BR.IncidentBuild.timelineClose({
        matchEndedAt = 9000, filedAtGameMs = 0, records = records(CAP),
        priorStrips = 5,
    })
    ok(spentSome.matchTimelineComplete == false,
        'a close whose own cap truncated says so even when nothing was lost upstream',
        tostring(spentSome.matchTimelineComplete))

    -- THE BUDGET THE FILING ALREADY SPENT. A close that ignored `priorStrips`
    -- would let one match write CAP strips twice over.
    local spent = BR.IncidentBuild.timelineClose({
        matchEndedAt = 9000, filedAtGameMs = 0, records = records(CAP),
        priorStrips = CAP,
    })
    local m = 0
    for _, e in ipairs(spent.matchTimeline) do
        if e.kind == BR.IncidentBuild.STRIP_KIND then m = m + 1 end
    end
    ok(m == 0, 'a close whose filing already spent the whole budget adds none', m)
end

describe('timeline.warmup-anchor')
do
    -- ═══ A CASE FILED BEFORE THE MATCH STARTED ═══
    --
    -- `startedAt` is stamped on entering PLAYING and nothing else sets it, so a
    -- weapon-strip case opened on the warmup pad is built with no start at all.
    -- Everything below is about that shape, and the one thing every assertion
    -- guards together is that the creation time NEVER becomes the start: two
    -- facts sharing one field is how a moderation record starts lying quietly.

    local function records(n)
        local strips = {}
        for i = 1, n do strips[i] = { at = i * 10, weapon = 0x11111111 } end
        return { { license = 'l:x', strips = strips, stripsSeen = n,
                   kills = {}, killsSeen = 0 } }
    end

    -- (1) THE WARMUP CASE. Formed, not started.
    local warm = BR.IncidentBuild.timelineOpen({
        matchId = 7, matchCreatedAt = 500, records = records(2),
    })

    ok(warm.matchStartedAt == nil,
        'a case filed during warmup still says the match has not started',
        tostring(warm.matchStartedAt))
    ok(warm.matchCreatedAt == 500,
        'and carries when the match was formed instead',
        tostring(warm.matchCreatedAt))

    -- THE DEADLINE IS NOT DERIVED FROM THE CREATION TIME, and that is a decision
    -- rather than an omission. `matchEndsBy` means "this long after the match
    -- STARTED"; measured from the formation it would fire early on any long
    -- warmup -- `brwarmup hold` holds one for a DAY -- and tell an admin the end
    -- was never reported about a match still sitting on the pad.
    ok(warm.matchEndsByMs == nil,
        'and no deadline, because there is no start to measure one from',
        tostring(warm.matchEndsByMs))

    ok(#warm.matchTimeline > 0,
        'the timeline is not empty, which is what it used to be', #warm.matchTimeline)
    ok(warm.matchTimeline[1] and
        warm.matchTimeline[1].kind == BR.IncidentBuild.MATCH_CREATED_KIND,
        'it is anchored on the formation, under its own kind',
        warm.matchTimeline[1] and tostring(warm.matchTimeline[1].kind))
    ok(warm.matchTimeline[1] and warm.matchTimeline[1].at == 500,
        'at the moment the match was formed',
        warm.matchTimeline[1] and tostring(warm.matchTimeline[1].at))

    -- THE EVIDENCE THE CASE IS ABOUT. A warmup filing used to return the empty
    -- shape, so the strips that opened the case reached the row NOWHERE -- the
    -- evidence records carry chat and kills, and a strip is neither.
    local strips = 0
    for _, e in ipairs(warm.matchTimeline) do
        if e.kind == BR.IncidentBuild.STRIP_KIND then strips = strips + 1 end
    end
    ok(strips == 2, 'and the strips ride it, which they never used to', strips)

    -- (2) THE STARTED CASE IS UNCHANGED. The start wins the anchor when both are
    --     known, so there is exactly one beginning on the list and the console
    --     never has to choose between two entries claiming to be it.
    local live = BR.IncidentBuild.timelineOpen({
        matchId = 7, matchStartedAt = 1000, matchCreatedAt = 500,
        records = records(1),
    })
    ok(live.matchTimeline[1] and live.matchTimeline[1].kind == 'match_start',
        'a case filed after the match started is anchored on the start',
        live.matchTimeline[1] and tostring(live.matchTimeline[1].kind))
    ok(live.matchTimeline[1] and live.matchTimeline[1].at == 1000,
        'at the start time, not the formation time',
        live.matchTimeline[1] and tostring(live.matchTimeline[1].at))
    local formed = 0
    for _, e in ipairs(live.matchTimeline) do
        if e.kind == BR.IncidentBuild.MATCH_CREATED_KIND then formed = formed + 1 end
    end
    ok(formed == 0, 'and carries no second beginning beside it', formed)
    ok(live.matchCreatedAt == 500,
        'the formation time is still on the row as its own field',
        tostring(live.matchCreatedAt))
    ok(live.matchEndsByMs == BR.IncidentBuild.TIMELINE_LIMITS.MATCH_ENDS_BY_MS,
        'and a started match still states its deadline')

    -- (3) NO MATCH AT ALL. `brrefuse` from a console: neither timestamp, so
    --     there is nothing to anchor and inventing one would put a match on the
    --     record that never happened.
    local none = BR.IncidentBuild.timelineOpen({ matchId = 7, records = records(2) })
    ok(#none.matchTimeline == 0,
        'a case whose match the registry has never heard of gets no timeline',
        #none.matchTimeline)
    ok(none.matchCreatedAt == nil, 'and no formation time either')

    -- (4) AND NO matchId. The same empty answer, from the other direction.
    local lobby = BR.IncidentBuild.timelineOpen({ matchCreatedAt = 500, records = records(2) })
    ok(#lobby.matchTimeline == 0, 'nor does one filed with no match id at all',
        #lobby.matchTimeline)
end

describe('timeline.close-carries-the-start')
do
    -- THE OTHER HALF OF THE WARMUP CASE. Its row is written with a null start
    -- and a null deadline; both become known while the case is already durable,
    -- and the close is the write that was going to happen anyway.

    local closed = BR.IncidentBuild.timelineClose({
        matchEndedAt = 9000, matchStartedAt = 1000, filedAtGameMs = 0,
        records = {},
    })
    ok(closed.matchStartedAt == 1000,
        'a close reports when the match started', tostring(closed.matchStartedAt))
    ok(closed.matchEndsByMs == BR.IncidentBuild.TIMELINE_LIMITS.MATCH_ENDS_BY_MS,
        'and the deadline that goes with it, as a duration for br_ringmaster',
        tostring(closed.matchEndsByMs))

    -- A MATCH THAT DISSOLVED ON THE PAD. It ended without ever having begun, and
    -- the close must say nothing about a start rather than invent one from the
    -- end -- a nil key does not travel, so the row keeps its own answer.
    local never = BR.IncidentBuild.timelineClose({
        matchEndedAt = 9000, filedAtGameMs = 0, records = {},
    })
    ok(never.matchStartedAt == nil,
        'a match that never started closes without claiming one',
        tostring(never.matchStartedAt))
    ok(never.matchEndsByMs == nil,
        'and without a deadline it has no start to measure from',
        tostring(never.matchEndsByMs))
    ok(never.matchEndedAt == 9000, 'but it does record that the match ended')
end

describe('bus.doors')
do
    -- THE DOOR WINDOW IS THE UNION, never a replacement. A tour that crosses
    -- the ports after the authored close index used to fly over the best drop
    -- on the map with the doors shut (user, 2026-08-06).
    local zones = { { x = 1000.0, y = 0.0, radius = 200.0 } }
    local pts = {
        { x =    0.0, y = 0.0, t = 1000 },
        { x =  500.0, y = 0.0, t = 2000 },
        { x = 1000.0, y = 0.0, t = 3000 },   -- inside the zone
        { x = 1500.0, y = 0.0, t = 4000 },
    }

    -- A zone crossing LATER than the authored close pushes the close out.
    local o, c = BR.BusDoorWindow(pts, zones, 1500, 2500, nil)
    ok(o == 1500 and c == 3000,
        'a late zone crossing keeps the doors open until it is passed',
        ('open %d close %d'):format(o, c))

    -- A zone crossing EARLIER than the authored open pulls the open in.
    o, c = BR.BusDoorWindow(pts, zones, 3500, 4000, nil)
    ok(o == 3000 and c == 4000,
        'and an early one opens them sooner',
        ('open %d close %d'):format(o, c))

    -- WIDENING ONLY. A zone inside the authored window changes nothing --
    -- it must never make the jumpable stretch shorter than it already was.
    o, c = BR.BusDoorWindow(pts, zones, 1000, 4000, nil)
    ok(o == 1000 and c == 4000, 'a zone inside the window narrows nothing',
        ('open %d close %d'):format(o, c))

    -- NEVER BEFORE WHEELS-UP. LSIA is a door zone and the bus takes off from
    -- an airstrip, so without this the doors could open on the runway.
    o, c = BR.BusDoorWindow(pts, zones, 3500, 4000, 3200)
    ok(o == 3200, 'and never before the aircraft has rotated', tostring(o))

    -- No zones at all leaves the authored window untouched.
    o, c = BR.BusDoorWindow(pts, {}, 1500, 2500, nil)
    ok(o == 1500 and c == 2500, 'no zones means the authored window stands')

    -- The real config must actually cover the two places asked for.
    local function covered(x, y)
        for _, z in ipairs(BR.Config.Map.DoorZones or {}) do
            if (x - z.x) ^ 2 + (y - z.y) ^ 2 <= z.radius ^ 2 then return true end
        end
        return false
    end
    ok(covered(-1037.0, -2737.0), 'LSIA is inside a door zone')
    ok(covered(525.59, -3089.33), 'and so are the port docks')
end

describe('loot.floor')
do
    -- HEALING COMES OUT OF CRATES, NEVER OFF THE FLOOR (user call,
    -- 2026-08-06). Health is what a fight is fought with, so finding it should
    -- cost the exposure of standing at a container -- and later, of driving to
    -- a reboot van. Tripping over a bandage in the street undoes both.
    local layout = BR.BuildLootLayout(31337)

    local floorHeal, chestHeal = 0, 0
    local floorKinds, counts = {}, {}
    for _, e in ipairs(layout) do
        if e.kind == 'chest' then
            local n = 0
            for _, s in ipairs(e.contents or {}) do
                n = n + 1
                if s.item == 'bandage' or s.item == 'medkit' then
                    chestHeal = chestHeal + 1
                end
            end
            counts[n] = (counts[n] or 0) + 1
        else
            floorKinds[e.kind] = (floorKinds[e.kind] or 0) + 1
            if e.item == 'bandage' or e.item == 'medkit' then
                floorHeal = floorHeal + 1
            end
        end
    end

    ok(floorHeal == 0, 'no bandage or med kit ever spawns loose on the ground',
        ('%d found'):format(floorHeal))
    ok(chestHeal > 0, 'but crates carry them', ('%d in crates'):format(chestHeal))

    -- Shields are NOT crate-only -- only the two healing items are, which is
    -- what was actually asked for.
    local floorShield = 0
    for _, e in ipairs(layout) do
        if e.kind ~= 'chest'
           and (e.item == 'shield' or e.item == 'minishield') then
            floorShield = floorShield + 1
        end
    end
    ok(floorShield > 0, 'shields still spawn loose', tostring(floorShield))

    -- LOOSE LOOT IS MOSTLY AMMO. The crate is meant to be the thing worth
    -- crossing open ground for; when a rifle on the floor is as likely as one
    -- in a box, the box is not worth its exposure.
    local floorTotal = 0
    for _, n in pairs(floorKinds) do floorTotal = floorTotal + n end
    local ammoShare = (floorKinds[BR.ItemKind.AMMO] or 0) / math.max(1, floorTotal)
    ok(ammoShare > 0.6, 'most loose ground loot is ammo',
        ('%.0f%%'):format(ammoShare * 100))

    -- CRATE CONTENTS: 2..4, peaking at three, with two and four alike.
    ok((counts[1] or 0) == 0 and (counts[5] or 0) == 0,
        'a crate never holds fewer than 2 or more than 4')
    ok((counts[3] or 0) > (counts[2] or 0) and (counts[3] or 0) > (counts[4] or 0),
        'three is the most common haul',
        ('2:%d 3:%d 4:%d'):format(counts[2] or 0, counts[3] or 0, counts[4] or 0))
    -- Equally probable either side: within 15% of each other over ~2000 crates.
    local lo, hi = counts[2] or 0, counts[4] or 0
    ok(math.abs(lo - hi) / math.max(1, (lo + hi) / 2) < 0.15,
        'two and four are equally likely',
        ('2:%d 4:%d'):format(lo, hi))
end

describe('loot.shields')
do
    -- HOW OFTEN A CRATE PAYS OUT A SHIELD, WHICH IS THE ONLY FORM OF THIS
    -- NUMBER A PLAYER EXPERIENCES.
    --
    -- Owner, 2026-08-17: "seems shield is a very rare item - took me 10 crates
    -- to get one. That should be increased." His ten crates were the table
    -- working as configured, not a bad run: at rarity RARE the Shield sat in a
    -- band worth 27% of consumable rolls while consumables were 17% of crate
    -- items, which is 11.1% of crates holding one -- one in nine.
    --
    -- NOTHING PINNED THAT, WHICH IS WHY IT COULD DRIFT. The block above proves
    -- healing is crate-only and that crates hold 2..4 items; neither notices a
    -- consumable becoming unfindable. So the rate is asserted here as a BAND
    -- rather than a value: the intent is "a crate in three, give or take", not
    -- a particular seed's 28.5%, and a band survives an unrelated retune of the
    -- kind weights while still failing if the Shield falls back off a cliff.
    --
    -- The layout is the same seed the block above builds, so this is the whole
    -- map's ~2200 crates rather than a model of them.
    local layout = BR.BuildLootLayout(31337)

    local crates, withShield, shields = 0, 0, 0
    for _, e in ipairs(layout) do
        if e.kind == 'chest' then
            crates = crates + 1
            local got = false
            for _, s in ipairs(e.contents or {}) do
                if s.item == 'shield' then got = true; shields = shields + 1 end
            end
            if got then withShield = withShield + 1 end
        end
    end

    local rate = withShield / math.max(1, crates)
    ok(rate > 0.22 and rate < 0.38,
        'a crate holds a Shield about one time in three',
        ('%.1f%% of %d crates (1 in %.1f)')
            :format(rate * 100, crates, crates / math.max(1, withShield)))

    -- AND IT IS STILL THE UNCOMMON ITEM IT IS AUTHORED AS. The rate above is
    -- reached by which rarity BANDS the Shield owns (BR.LootPickOfRarity picks
    -- uniformly inside a band), so a future edit that moves it back to RARE --
    -- or that authors a new UNCOMMON consumable beside it, halving its share --
    -- fails this rather than the arithmetic being rediscovered from a playtest.
    ok(BR.Config.ConsumableById['shield'].rarity == BR.Rarity.UNCOMMON,
        'the Shield owns the UNCOMMON consumable band',
        tostring(BR.Config.ConsumableById['shield'].rarity))
    ok(#BR.Config.ConsumablesByRarity[BR.Rarity.UNCOMMON] == 1,
        'and owns it alone',
        ('%d items in the band'):format(#BR.Config.ConsumablesByRarity[BR.Rarity.UNCOMMON]))

    -- HEALING WAS NOT COLLATERAL. Widening the Shield's band takes its share
    -- from the other consumables, so the consumable kind weight was raised to
    -- offset it -- and this is the assertion that says so. Bandages and med
    -- kits must still be a real fraction of what a crate pays out.
    local items, heal = 0, 0
    for _, e in ipairs(layout) do
        if e.kind == 'chest' then
            for _, s in ipairs(e.contents or {}) do
                items = items + 1
                if s.item == 'bandage' or s.item == 'medkit' then heal = heal + 1 end
            end
        end
    end
    local healShare = heal / math.max(1, items)
    ok(healShare > 0.05,
        'and crates still carry a real share of healing',
        ('%.1f%% of crate items'):format(healShare * 100))
end

describe('storm.breakout')
do
    -- THE CIRCLE MUST BE ABLE TO LEAVE THE CIRCLE.
    --
    -- Strict nesting means a player at the centre is never obliged to move and
    -- can hold one building on the hope of a favourable draw. A breakout puts
    -- the next circle partly outside the current one, so everyone runs (user
    -- call, 2026-08-06). This is safe only because the wall SWEEPS to the new
    -- circle over a duration priced off the furthest player's run -- nobody is
    -- damaged for standing where they legally stood.
    local bo = { chance = 0.85, gapMax = 0.5, minRadius = 0.0 }
    local R, r = 1600.0, 950.0

    -- The budget, stated as the geometry: edges touching, plus a gap of at
    -- most half the predecessor's radius.
    local budget = R + r + bo.gapMax * R

    local outside, disjoint, breached, worst = 0, 0, 0, 0.0
    for i = 1, 800 do
        local nx, ny = BR.NextStormCentre(BR.Rng(i), 0.0, 0.0, R, r, 1.0, nil, nil, bo)
        local d = BR.Dist(0.0, 0.0, nx, ny)
        -- The CENTRE outside the current circle is the weaker ask...
        if d > R then outside = outside + 1 end
        -- ...and the WHOLE CIRCLE outside it is the stronger one.
        if d > R + r then disjoint = disjoint + 1 end
        if d > budget + 1e-6 then
            breached = breached + 1
            if d - budget > worst then worst = d - budget end
        end
    end
    ok(outside > 0, 'a breakout can put the next centre outside the current circle',
        ('%d of 800'):format(outside))
    ok(disjoint > 0, 'and can separate the two circles entirely',
        ('%d of 800'):format(disjoint))
    ok(breached == 0, 'but the gap between them never exceeds gapMax * curRadius',
        ('%d breaches, worst %.3f'):format(breached, worst))

    -- The flag has to come back, or the server cannot lengthen the sweep to
    -- match -- and an unreachable circle is a cull, not a rotation.
    local sawFlag = false
    for i = 1, 200 do
        local _, _, broke = BR.NextStormCentre(BR.Rng(i), 0.0, 0.0, R, r, 1.0, nil, nil, bo)
        if broke then sawFlag = true break end
    end
    ok(sawFlag, 'and reports that it broke out, so the sweep can be priced for it')

    -- WITHOUT the config it is the old strict rule, unchanged. Every existing
    -- caller that passes no breakout table keeps exact containment.
    local violations = 0
    for i = 1, 800 do
        local nx, ny = BR.NextStormCentre(BR.Rng(i), 0.0, 0.0, R, r, 1.0, nil)
        if BR.Dist(0.0, 0.0, nx, ny) + r > R + 1e-6 then
            violations = violations + 1
        end
    end
    ok(violations == 0, 'omitting the breakout config keeps strict nesting',
        ('%d violations'):format(violations))

    -- THE FINAL PHASE MUST BE ABLE TO MOVE, and this is what the overhang
    -- being a fraction of the CURRENT radius buys. Phase 8 closes to radius
    -- ZERO; an overhang scaled by the NEXT radius would be zero times
    -- anything, so the one phase that most needs to force a run was the one
    -- phase that mathematically could not.
    local finalMoves = 0
    for i = 1, 400 do
        local nx, ny = BR.NextStormCentre(BR.Rng(i), 0.0, 0.0, 40.0, 0.0, 1.0, nil, nil, bo)
        if BR.Dist(0.0, 0.0, nx, ny) > 40.0 then finalMoves = finalMoves + 1 end
    end
    ok(finalMoves > 0, 'the last phase can still land outside its predecessor',
        ('%d of 400'):format(finalMoves))

    -- THE RAMP: nothing in phase 1, 85% by phase 8.
    local cfg = BR.Config.Storm
    local first = BR.StormBreakoutFor(cfg, 1)
    local last  = BR.StormBreakoutFor(cfg, #cfg.phases)
    ok(first and math.abs(first.chance) < 1e-9,
        'the opening phase never breaks out',
        first and tostring(first.chance))
    ok(last and math.abs(last.chance - 0.85) < 1e-6,
        'and the last phase does 85% of the time',
        last and tostring(last.chance))

    -- Monotonic in between -- a ramp, not a step.
    local prev, monotonic = -1.0, true
    for phase = 1, #cfg.phases do
        local c = BR.StormBreakoutFor(cfg, phase).chance
        if c < prev - 1e-9 then monotonic = false end
        prev = c
    end
    ok(monotonic, 'and the chance never falls as the phases progress')
end

describe('storm.water')
do
    -- THE STORM MUST NOT CLOSE ON OPEN OCEAN.
    --
    -- The anchor is a POI and so is always on land, but nothing used to stop
    -- the per-phase drift from walking seaward one circle at a time -- and
    -- eight phases off a coastal anchor is enough to finish over water, with
    -- nowhere left to stand (user, 2026-08-06).
    --
    -- Sited just inland of the Pacific rectangle (x > -3350) with enough slack
    -- that an unconstrained draw reaches well past it, so a fix that does
    -- nothing shows up immediately.
    local cx, cy = -3200.0, 500.0
    ok(not BR.Config.Map.IsWater(cx, cy), 'the test centre starts on dry land')

    local wet, breaches, worst = 0, 0, 0.0
    for i = 1, 600 do
        local nx, ny = BR.NextStormCentre(BR.Rng(i), cx, cy, 2400.0, 1400.0, 1.0, nil)
        if BR.Config.Map.IsWater(nx, ny) then wet = wet + 1 end
        -- The pull-back must not cost containment: every step of it moves
        -- strictly closer to a centre the circle already nested in.
        local slop = BR.Dist(cx, cy, nx, ny) + 1400.0 - 2400.0
        if slop > 1e-6 then
            breaches = breaches + 1
            if slop > worst then worst = slop end
        end
    end
    ok(wet == 0, 'no drawn centre lands in authored water',
        ('%d of 600 landed wet'):format(wet))
    ok(breaches == 0, 'and pulling one back out of the sea keeps it nested',
        ('%d breaches, worst %.3f'):format(breaches, worst))

    -- A centre that is ALREADY wet has nothing better to offer than itself --
    -- it must still return, not loop.
    local sx, sy = BR.NextStormCentre(BR.Rng(7), -3800.0, 0.0, 2000.0, 1000.0, 1.0, nil)
    ok(type(sx) == 'number' and type(sy) == 'number',
        'a centre already at sea still resolves rather than hanging')
end

describe('storm.bounds')
do
    -- THE OWNER'S ACTUAL REPORT, AS A TEST (2026-08-28): "we have too many
    -- places where the storm can end outside the map and in the ocean."
    --
    -- storm.water above covers the five authored rectangles, which were never a
    -- map outline -- they exist to stop LOOT generating in the Pacific, and the
    -- gaps between them are where the storm went. This drives the WHOLE
    -- sequence, anchor to phase 8, exactly as br_core/server/storm.lua drives
    -- it, and asserts the final circle is somewhere a player can stand.
    --
    -- Before the surveyed boundary became the mask, this test failed on 20.2%
    -- of seeds. That number is the reason it is a full-sequence simulation and
    -- not a single call: one draw off a coastal anchor almost never lands in
    -- the sea, and eight of them compounding is the bug.
    local cfg = BR.Config.Storm
    local pois = BR.Config.Map.POIs

    local wps = {}
    for _, options in ipairs(BR.Config.Bus.legs) do
        for _, opt in ipairs(options) do
            for _, wp in ipairs(opt) do wps[#wps + 1] = { x = wp.x, y = wp.y } end
        end
    end

    local N = 400
    local anchorsOut, endsOut, anyOut, worst = 0, 0, 0, 0.0
    for seed = 1, N do
        local rng = BR.Rng(seed * 7919 + 13)
        local anchor = BR.PickStormAnchor(rng, wps, pois, cfg.anchorBand)
        if not BR.Config.Map.InBounds(anchor.x, anchor.y) then
            anchorsOut = anchorsOut + 1
        end

        -- The opening radius, computed the way server/storm.lua computes it:
        -- far enough to cover every corner of the bounds, so nobody can land
        -- outside circle 1.
        local A = cfg.mapAABB
        local r = cfg.radius0
        for _, c in ipairs({ { A.min.x, A.min.y }, { A.min.x, A.max.y },
                             { A.max.x, A.min.y }, { A.max.x, A.max.y } }) do
            r = math.max(r, BR.Dist(anchor.x, anchor.y, c[1], c[2]))
        end
        r = r + cfg.openMargin

        local cx, cy = anchor.x, anchor.y
        local sawOut = false
        for phase = 1, #cfg.phases do
            local p = cfg.phases[phase]
            local minDist = 0.0
            if phase > #cfg.phases - cfg.edgeHugPhases then
                minDist = math.max(0.0, (r - p.radius) - cfg.edgeHugM)
            end
            cx, cy = BR.NextStormCentre(rng, cx, cy, r, p.radius, cfg.edgeBiasMax,
                cfg.mapAABB, minDist, BR.StormBreakoutFor(cfg, phase))
            r = p.radius
            if not BR.Config.Map.InBounds(cx, cy) then sawOut = true end
        end

        if sawOut then anyOut = anyOut + 1 end
        if not BR.Config.Map.InBounds(cx, cy) then
            endsOut = endsOut + 1
            local d = BR.Config.Map.BoundaryDistance(cx, cy)
            if d > worst then worst = d end
        end
    end

    ok(anchorsOut == 0, 'every match anchor is inside the surveyed boundary',
        ('%d of %d outside'):format(anchorsOut, N))
    ok(endsOut == 0, 'and no match ends with its final circle off the map',
        ('%d of %d, worst %.0fm out'):format(endsOut, N, worst))
    ok(anyOut == 0, 'no phase of any match puts its centre off the map',
        ('%d of %d matches'):format(anyOut, N))

    -- The pull-back is a walk toward the PREVIOUS centre, and the previous
    -- centre is on the map by induction from the anchor. A centre that is
    -- already off the map breaks that induction and must still return rather
    -- than loop -- brforce and the tests both reach it.
    local ox, oy = BR.NextStormCentre(BR.Rng(11), 3900.0, 6900.0, 2000.0, 900.0,
        1.0, nil)
    ok(type(ox) == 'number' and type(oy) == 'number',
        'a centre already off the map still resolves rather than hanging')
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

    -- THE EDGE HUG (2026-08-04): the final phases pass a minimum offset so
    -- the next centre lands within edgeHugM of the current circumference --
    -- endgames run to a place instead of shuffling in the middle. The
    -- minimum must hold, containment must still win, and a minimum larger
    -- than the slack must clamp instead of breaking nesting.
    local hugViol, hugNest = 0, 0
    for _ = 1, 5000 do
        local curR, nextR = 1000.0, 200.0
        local slack   = curR - nextR
        local minDist = slack - 250.0
        local nx2, ny2 = BR.NextStormCentre(rng, 0.0, 0.0, curR, nextR,
            1.0, nil, minDist)
        local off = BR.Dist(0.0, 0.0, nx2, ny2)
        if off < minDist - 1e-6 then hugViol = hugViol + 1 end
        if off + nextR - curR > 1e-6 then hugNest = hugNest + 1 end
    end
    ok(hugViol == 0, 'the edge hug pushes the centre out to its minimum',
        ('%d short draws'):format(hugViol))
    ok(hugNest == 0, 'and containment still wins over the hug',
        ('%d nesting violations'):format(hugNest))

    local hx, hy = BR.NextStormCentre(rng, 0.0, 0.0, 100.0, 60.0, 1.0, nil, 9999.0)
    ok(BR.Dist(0.0, 0.0, hx, hy) + 60.0 - 100.0 <= 1e-6,
        'an oversized minimum clamps to the slack instead of breaking nesting')

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

    -- THE KILL-TIME BAND (user rule, 2026-08-04, superseding the 10s floor
    -- with a gentler one): the storm's fastest kill is 15 seconds (phase 8)
    -- and its slowest is 100 (phase 1) -- dps is authored as 100/killtime.
    local worstDps = 0
    for _, p in ipairs(phases) do
        if p.dps > worstDps then worstDps = p.dps end
    end
    ok(worstDps <= 100.0 / 15.0 + 0.05,
        'no phase kills a full-health player in under 15s',
        ('worst dps %.1f'):format(worstDps))
    -- PHASE 1 IS THE FORGIVING ONE, deliberately. A far-end jumper has a
    -- legitimate several-minute run to circle one, so being caught by it must
    -- cost health rather than the match (user, 2026-08-07). Every later phase
    -- is where the storm is supposed to be frightening.
    ok(100.0 / phases[1].dps >= 150.0,
        'phase 1 takes at least 150s of standing still to kill',
        ('%.0fs at %.2f dps'):format(100.0 / phases[1].dps, phases[1].dps))
    for i = 2, #phases do
        ok(phases[i].dps > phases[1].dps,
            ('phase %d hurts more than phase 1'):format(i))
    end

    -- The free-loot floor: an all-inside drop still gets one full minute
    -- (hold.minSeconds); the priced hold stretches it from there.
    ok(BR.Config.Storm.hold.minSeconds == 60,
        'the free-loot hold floors at one minute (user call, 2026-08-04)')
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
    -- The floor is 100, the GTA convention after all. The old "verified 0"
    -- note misread a corpse -- GetEntityHealth reads 0 only AFTER death, the
    -- living range never dips below 100 -- and the live measurement that
    -- settled it was a player dying with the bar at exactly 50% under the
    -- old 0..200 mapping (2026-08-04). The midpoint checks pin the corrected
    -- numbers on purpose.
    ok(BR.Config.Match.healthFloor == 100, 'the death floor is the engine-100 convention')

    ok(BR.ToEngineHp(100) == BR.Config.Match.maxHealth, 'full display maps to max engine hp')
    ok(BR.ToEngineHp(0) == BR.Config.Match.healthFloor, 'zero display maps to the death floor')
    ok(BR.ToEngineHp(50) == 150, 'half display maps to the live-range midpoint (engine 150)')

    ok(near(BR.ToDisplayHp(200), 100.0), 'max engine hp reads as full')
    ok(near(BR.ToDisplayHp(100), 0.0), 'the death floor reads as zero')
    ok(near(BR.ToDisplayHp(150), 50.0), 'live-range midpoint reads as half')
    ok(near(BR.ToDisplayHp(0), 0.0), 'a post-mortem 0 also reads as zero, not negative')

    local roundTrips = true
    for d = 0, 100 do
        if math.abs(BR.ToDisplayHp(BR.ToEngineHp(d)) - d) > 0.51 then roundTrips = false end
    end
    ok(roundTrips, 'display -> engine -> display round-trips within rounding')

    ok(BR.ToEngineHp(-50) == BR.Config.Match.healthFloor, 'negative display is clamped')
    ok(BR.ToEngineHp(999) == BR.Config.Match.maxHealth, 'excess display is clamped')
    ok(near(BR.ToDisplayHp(-10), 0.0), 'sub-floor engine hp reads as zero, not negative')

    ok(BR.IsDeadHp(100) and BR.IsDeadHp(0) and BR.IsDeadHp(-1),
        'at or below the floor is dead -- including a corpse reading 0')
    ok(not BR.IsDeadHp(101), 'above the floor is alive')

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
    --
    -- THE AIRDROP SHELF IS IN THIS WALK, and it was not until a mutation pass
    -- gave the RPG a 900m range and nothing noticed. Those four are in no rarity
    -- bucket, so every check that walks the loot tables misses them -- which is
    -- exactly why each one has to be asked here by name.
    local over = {}
    for _, list in ipairs({ BR.Config.Weapons, BR.Config.AirdropWeapons }) do
        for _, w in ipairs(list) do
            if w.maxRange > 424.0 then over[#over + 1] = w.id end
        end
    end
    ok(#over == 0, 'no weapon out-ranges the 424u entity render ceiling',
        table.concat(over, ', '))

    -- ALLOWED SINCE #88, AND THE OTHER HALF OF THE PROPERTY IS BELOW.
    --
    -- These four were excluded on anti-cheat grounds -- absent from the table,
    -- therefore absent from the allowlist. The owner reversed it (2026-08-21)
    -- on the argument that the allowlist asks "did we issue this", not "is this
    -- dangerous", and that an airdrop can honestly answer yes. So they are
    -- allowed now, and the invariant worth pinning has MOVED rather than gone:
    -- allowed to CARRY, never rolled into the WORLD.
    for _, w in ipairs({
        { 'RPG',              0xB1CA77B1 },
        { 'Minigun',          0x42BF8A85 },
        { 'Railgun',          0x6D544C99 },
        { 'Grenade Launcher', 0xA284510B },
    }) do
        ok(BR.Config.IsAllowedWeapon(w[2]),
            ('%s is allowed -- an airdrop can issue it'):format(w[1]))
    end

    -- ...and the homing launcher is not, because nothing issues one. Absence is
    -- still refusal here; #88 changed which hashes are written down, not the
    -- shape of the rule.
    ok(not BR.Config.IsAllowedWeapon(0x63AB0442),
        'the homing launcher is still refused -- nothing hands one out')

    -- THE WORLD NEVER PRODUCES ONE. The whole of "ultra rare airdrop loot" is
    -- that they are registered into the id lookups and into no rarity bucket,
    -- which is the only thing BR.RollLootStack rolls against.
    local leaked = {}
    for _, w in ipairs(BR.Config.AirdropWeapons) do
        ok(BR.Config.WeaponById[w.id] == w,
            ('%s resolves by id, so an airdrop pool can name it'):format(w.id))
        for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
            for _, x in ipairs(BR.Config.WeaponsByRarity[r] or {}) do
                if x.id == w.id then leaked[#leaked + 1] = w.id end
            end
        end
    end
    ok(#leaked == 0,
        'no airdrop weapon is in any rarity bucket, so no world roll can '
        .. 'produce one', table.concat(leaked, ', '))

    -- THE MINIGUN'S CYCLE IS THE FASTEST IN THE GAME, AND THAT IS A VALIDATOR
    -- FACT RATHER THAN A BALANCE ONE. BR.ValidateShot refuses anything faster
    -- than `minInterval * intervalSlack` as TOO_FAST, and TOO_FAST is a COUNTED
    -- refusal -- so a minigun given a rifle's 85ms would refuse an honest
    -- player's every round and then open an anticheat case on them for using a
    -- gun the airdrop handed them. The number has to be at or below what the
    -- engine actually does, and nothing offline can measure that; what can be
    -- checked is the claim the config makes about it.
    local fastest, fastestId = math.huge, nil
    for _, w in ipairs(BR.Config.Weapons) do
        if w.minInterval and w.minInterval < fastest then
            fastest, fastestId = w.minInterval, w.id
        end
    end
    local mg = BR.Config.WeaponById.minigun
    ok(mg and mg.minInterval and mg.minInterval < fastest,
        'the minigun cycles faster than anything in the world table',
        ('minigun %s vs %s at %s'):format(
            tostring(mg and mg.minInterval), tostring(fastestId),
            tostring(fastest)))

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

-- --------------------------------------------------------------- loot.grid ---

describe('loot.grid')
do
    local size = BR.Config.Loot.cellSize

    local cx, cy = BR.LootCellOf(0.0, 0.0)
    ok(cx == 0 and cy == 0, 'origin is cell 0,0')

    cx, cy = BR.LootCellOf(size + 1.0, size * 2 + 1.0)
    ok(cx == 1 and cy == 2, 'positive coordinates floor into the right cell')

    -- Negative coordinates are more than half the map (the AABB runs to -3600).
    -- An integer-truncating cell function would put -1.0 and +1.0 in the SAME
    -- cell, silently merging two 256m squares on the Vespucci side of the map.
    cx, cy = BR.LootCellOf(-1.0, -1.0)
    ok(cx == -1 and cy == -1, 'negative coordinates floor DOWN, not toward zero')

    ok(BR.LootCellKeyAt(-1.0, -1.0) == BR.LootCellKey(-1, -1),
        'cell key round-trips through a position')

    local cells = BR.LootCellsAround(4, 7, 1)
    ok(#cells == 9, 'a subscribe radius of 1 is a 3x3 block')

    local seen = {}
    for _, k in ipairs(cells) do seen[k] = true end
    ok(seen[BR.LootCellKey(4, 7)] and seen[BR.LootCellKey(3, 6)]
        and seen[BR.LootCellKey(5, 8)], 'the block is centred and complete')

    -- Order is fixed, because subscription diffs compare two of these.
    local again = BR.LootCellsAround(4, 7, 1)
    local sameOrder = true
    for i = 1, #cells do
        if cells[i] ~= again[i] then sameOrder = false break end
    end
    ok(sameOrder, 'cell order is stable between calls')

    ok(#BR.LootCellsAround(0, 0, 2) == 25, 'radius 2 is a 5x5 block')
end

-- ------------------------------------------------------------- loot.reach ---

-- WHAT THIS PINS IS A SECURITY BOUNDARY, not a convenience.
--
-- The LOOT_CELL handler used to subscribe a player to whatever cell they named.
-- Since the whole reason the layout seed stays server-side is that nobody should
-- be able to derive the map's loot, that made the seed pointless: a client could
-- walk the integer plane and be streamed everything, 9 cells at a time. These
-- cases are the arithmetic of the fix, and the handler around them is glue.
describe('loot.reach')
do
    local size = BR.Config.Loot.cellSize

    -- Stand in the middle of cell 0,0 so nothing here is a boundary artefact.
    local mx, my = size * 0.5, size * 0.5

    ok(BR.LootCellReachable(0, 0, mx, my), 'the cell you are standing in')

    -- All eight neighbours, because the subscription the server itself sends is
    -- the 3x3 block -- refusing a corner would refuse cells we volunteered.
    local corners = 0
    for dx = -1, 1 do
        for dy = -1, 1 do
            if BR.LootCellReachable(dx, dy, mx, my) then corners = corners + 1 end
        end
    end
    ok(corners == 9, 'every cell of the 3x3 block around you is reachable')

    ok(not BR.LootCellReachable(2, 0, mx, my), 'two cells out is refused')
    ok(not BR.LootCellReachable(0, 2, mx, my), 'two cells out on the other axis')
    ok(not BR.LootCellReachable(2, 2, mx, my), 'two cells out diagonally')

    -- The enumeration attack, in one line.
    ok(not BR.LootCellReachable(400, -400, mx, my),
        'a cell across the map is refused -- this is the whole point')

    -- CHEBYSHEV, NOT EUCLIDEAN. A radial test with radius 1 would put the
    -- diagonal at sqrt(2) and refuse it, which would refuse four of the nine
    -- cells the server streams.
    ok(BR.LootCellReachable(1, 1, mx, my),
        'the diagonal neighbour is as adjacent as the orthogonal one')

    -- Negative coordinates are over half the map (the AABB runs to -3600), and
    -- floor-vs-truncate bugs hide here.
    ok(BR.LootCellReachable(-1, -1, -size * 0.5, -size * 0.5),
        'the rule holds on the negative side of the origin')
    ok(not BR.LootCellReachable(1, 1, -size * 0.5, -size * 0.5),
        'and it still refuses two cells away there')

    -- A boundary straddle is the honest worst case the slack exists for: the
    -- sample sits just inside one cell while the player is a metre into the next.
    ok(BR.LootCellReachable(1, 0, size - 0.5, my),
        'standing on a boundary, the cell you are stepping into is reachable')

    -- Junk arguments must be refused rather than erroring or passing. `e.pos` is
    -- nil until the first sample, and the handler checks that itself -- but a nil
    -- reaching here must not be an allow.
    ok(not BR.LootCellReachable(nil, 0, mx, my), 'a nil cell is refused')
    ok(not BR.LootCellReachable(0, 0, nil, nil), 'a nil position is refused')

    -- The tolerance is a parameter so the bound can be tightened without
    -- touching call sites; zero means exactly your own cell.
    ok(BR.LootCellReachable(0, 0, mx, my, 0), 'tolerance 0 allows your own cell')
    ok(not BR.LootCellReachable(1, 0, mx, my, 0),
        'tolerance 0 refuses the neighbour')

    ok(BR.LOOT_CELL_DRIFT == 1,
        'the shipped tolerance is one cell -- 9 reachable, not 4 billion')
end

-- ---------------------------------------------------------------- loot.gen ---

describe('loot.gen')
do
    -- THE contract of this module. A layout that is not reproducible cannot be
    -- reasoned about after the fact: "the chest was here" stops being answerable
    -- and every loot bug becomes a ghost story.
    local a = BR.BuildLootLayout(12345)
    local b = BR.BuildLootLayout(12345)

    ok(#a == #b, 'the same seed produces the same number of entries')

    local identical = #a == #b
    if identical then
        for i = 1, #a do
            local x, y = a[i], b[i]
            if x.id ~= y.id or x.item ~= y.item or x.kind ~= y.kind
                or x.rarity ~= y.rarity or x.count ~= y.count
                or math.abs(x.x - y.x) > 1e-9 or math.abs(x.y - y.y) > 1e-9 then
                identical = false
                break
            end
        end
    end
    ok(identical, 'the same seed produces an identical layout, entry for entry')

    local c = BR.BuildLootLayout(999)
    local differs = #c ~= #a
    if not differs then
        for i = 1, #a do
            if a[i].item ~= c[i].item or math.abs(a[i].x - c[i].x) > 0.01 then
                differs = true
                break
            end
        end
    end
    ok(differs, 'a different seed produces a different layout')

    -- Ids are the claim key. A duplicate would make one claim delete two items.
    local ids, dupe = {}, false
    for _, e in ipairs(a) do
        if ids[e.id] then dupe = true break end
        ids[e.id] = true
    end
    ok(not dupe, 'every entry id is unique')

    local _, stats = BR.BuildLootLayout(12345)
    ok(stats.poi == BR.Config.TotalLootBudget(),
        'POI ground loot matches the authored budget exactly',
        ('%d vs %d'):format(stats.poi, BR.Config.TotalLootBudget()))

    local chestBudget = 0
    for _, poi in ipairs(BR.Config.Map.POIs) do
        chestBudget = chestBudget + (BR.Config.Loot.chestsPerTier[poi.tier] or 0)
    end
    ok(stats.chest == chestBudget, 'chest counts match the authored budget')
    ok(stats.total == #a, 'the stats total is the entry count')

    -- Every rolled item must resolve. An unresolvable id is an invisible prop
    -- and an inventory slot that shows a blank card.
    local bad = {}
    local function checkStack(s, where)
        if s.kind == BR.ItemKind.AMMO then
            if not BR.Config.AmmoPickups[s.item] then bad[#bad + 1] = where .. ':' .. tostring(s.item) end
        elseif s.kind == BR.ItemKind.CONSUMABLE then
            if not BR.Config.ConsumableById[s.item] then bad[#bad + 1] = where .. ':' .. tostring(s.item) end
        elseif s.kind == BR.ItemKind.WEAPON or s.kind == BR.ItemKind.THROWABLE then
            if not BR.Config.WeaponById[s.item] then bad[#bad + 1] = where .. ':' .. tostring(s.item) end
        elseif s.kind ~= 'chest' then
            bad[#bad + 1] = where .. ':kind=' .. tostring(s.kind)
        end
        if (s.count or 0) < 1 then bad[#bad + 1] = where .. ':count' end
    end
    for _, e in ipairs(a) do
        checkStack(e, 'entry')
        for _, s in ipairs(e.contents or {}) do checkStack(s, 'chest') end
    end
    ok(#bad == 0, 'every generated item id resolves in its config table',
        table.concat(bad, ', ', 1, math.min(#bad, 6)))

    -- Chest contents stay inside the authored burst size.
    local chestSizesOk, chestCount = true, 0
    for _, e in ipairs(a) do
        if e.kind == 'chest' then
            chestCount = chestCount + 1
            local n = #(e.contents or {})
            if n < BR.Config.Loot.chestItems.min or n > BR.Config.Loot.chestItems.max then
                chestSizesOk = false
            end
            if e.rarity ~= BR.LootContentsRarity(e.contents) then chestSizesOk = false end
        end
    end
    ok(chestCount > 0 and chestSizesOk,
        'chests hold min..max items and glow with their best one')

    -- Placement. Every POI entry must land inside the POI it belongs to, or the
    -- storm's "loot up at a named location" premise quietly stops holding.
    local outside = 0
    for _, e in ipairs(a) do
        if e.poi then
            local poi = BR.Config.Map.GetPOI(e.poi)
            if BR.Dist(e.x, e.y, poi.x, poi.y) > poi.radius then outside = outside + 1 end
        end
    end
    ok(outside == 0, 'no POI entry lands outside its POI radius',
        ('%d strays'):format(outside))

    -- Filler placement: on a road, off the POIs.
    local fillerSeen, offRoad, tooClose = 0, 0, 0
    for _, e in ipairs(a) do
        if e.road then
            fillerSeen = fillerSeen + 1
            local road, near = nil, math.huge
            for _, r in ipairs(BR.Config.Map.Roads) do
                if r.id == e.road then road = r end
            end
            for i = 2, #road.points do
                local p, q = road.points[i - 1], road.points[i]
                -- Point-to-segment distance.
                local vx, vy = q.x - p.x, q.y - p.y
                local wx, wy = e.x - p.x, e.y - p.y
                local len2 = vx * vx + vy * vy
                local t = len2 > 0 and ((wx * vx + wy * vy) / len2) or 0.0
                t = BR.Clamp(t, 0.0, 1.0)
                local d = BR.Dist(e.x, e.y, p.x + vx * t, p.y + vy * t)
                if d < near then near = d end
            end
            if near > BR.Config.Loot.filler.lateralOffset + 0.5 then offRoad = offRoad + 1 end

            for _, poi in ipairs(BR.Config.Map.POIs) do
                if BR.Dist(e.x, e.y, poi.x, poi.y) < BR.Config.Loot.filler.minPoiDist then
                    tooClose = tooClose + 1
                    break
                end
            end
        end
    end
    ok(fillerSeen > 0, 'filler is generated at all', ('%d points'):format(fillerSeen))
    ok(offRoad == 0, 'filler stays within lateralOffset of its road',
        ('%d strays'):format(offRoad))

    -- ON THE ROAD IS NOT ROADSIDE. The offset used to be a symmetric band
    -- through zero, so a share of every road's filler landed on the tarmac
    -- (user, 2026-08-05). Nothing may sit inside minOffset of a centreline.
    local onTarmac = 0
    for _, e in ipairs(a) do
        if e.road then
            local road
            for _, r in ipairs(BR.Config.Map.Roads) do
                if r.id == e.road then road = r end
            end
            local near = math.huge
            for i = 2, #road.points do
                local p, q = road.points[i - 1], road.points[i]
                local vx, vy = q.x - p.x, q.y - p.y
                local wx, wy = e.x - p.x, e.y - p.y
                local len2 = vx * vx + vy * vy
                local t = len2 > 0 and ((wx * vx + wy * vy) / len2) or 0.0
                t = BR.Clamp(t, 0.0, 1.0)
                local d = BR.Dist(e.x, e.y, p.x + vx * t, p.y + vy * t)
                if d < near then near = d end
            end
            if near < BR.Config.Loot.filler.minOffset - 0.5 then
                onTarmac = onTarmac + 1
            end
        end
    end
    ok(onTarmac == 0, 'no filler lands on the road centreline',
        ('%d on the tarmac'):format(onTarmac))

    -- Authored water is rejected at generation. Not a complete water map by
    -- design -- the client repair round-trip catches the rest -- but nothing
    -- may be generated into a rectangle we have explicitly called sea.
    local inSea = 0
    for _, e in ipairs(a) do
        if BR.Config.Map.IsWater(e.x, e.y) then inSea = inSea + 1 end
    end
    ok(inSea == 0, 'nothing is generated inside authored water',
        ('%d in the sea'):format(inSea))
    ok(tooClose == 0, 'filler keeps clear of the POIs', ('%d too close'):format(tooClose))
    ok(stats.filler <= BR.Config.Loot.filler.count,
        'filler never exceeds its authored count')

    -- Every entry must be findable through the grid, or the streamer will hand
    -- a client a cell that does not contain the items standing in front of them.
    local misfiled = 0
    for _, e in ipairs(a) do
        if BR.LootCellKeyAt(e.x, e.y) ~= BR.LootCellKey(BR.LootCellOf(e.x, e.y)) then
            misfiled = misfiled + 1
        end
    end
    ok(misfiled == 0, 'every entry files into the cell its position implies')
end

-- -------------------------------------------------------------- loot.gates ---

describe('loot.gates')
do
    -- ONE DEFINITION, BOTH SIDES. The client decides whether to ASK for a
    -- cell and the server whether to ANSWER; when those were written out
    -- separately they drifted, and the symptom was no loot anywhere with
    -- nothing in any log -- the client simply never asked, so the shared
    -- warmup zone was never even built (user, 2026-08-05).
    local vis = BR.Config.LootVisibleStates
    local take = BR.Config.LootTakeStates

    ok(vis[BR.PlayerState.WARMUP] == true,
        'the warmup pad is visible -- the whole point of stocking it')
    ok(take[BR.PlayerState.WARMUP] == true, 'and lootable, for practice PVP')
    ok(vis[BR.PlayerState.ALIVE] == true and take[BR.PlayerState.ALIVE] == true,
        'a live player sees and takes')

    -- The vista is a menu with a view. A lobby bystander streaming a match's
    -- items would be reading the map through someone else's game.
    ok(vis[BR.PlayerState.LOBBY] == nil, 'the lobby sees nothing')
    ok(take[BR.PlayerState.LOBBY] == nil, 'and takes nothing')

    -- Falling players see (props have to exist before you land) but cannot
    -- take -- there is nothing to stand on.
    ok(vis[BR.PlayerState.FREEFALL] == true, 'a falling player is streamed loot')
    ok(take[BR.PlayerState.FREEFALL] == nil, 'but cannot pick it up mid-air')
    ok(take[BR.PlayerState.DEAD] == nil, 'and a corpse takes nothing')

    -- Anything takeable must be visible, or the gates contradict each other.
    local contradiction = {}
    for state in pairs(take) do
        if not vis[state] then contradiction[#contradiction + 1] = state end
    end
    ok(#contradiction == 0, 'nothing is takeable but invisible',
        table.concat(contradiction, ', '))
end

-- -------------------------------------------------------------- loot.water ---

describe('loot.water')
do
    -- THE RULE THAT KEEPS THE MASK HONEST. A water rectangle that swallows a
    -- POI is not a conservative approximation, it is loot deleted from a real
    -- place: the generator's fallback walks inward to the POI CENTRE, so a
    -- centre inside water puts that POI's entire budget in the sea. The first
    -- draft did exactly that to Chumash, Hookies and Galilee -- three coastal
    -- towns on dry land -- and dropped 67 items in the Pacific.
    local drowned = {}
    for _, poi in ipairs(BR.Config.Map.POIs) do
        if BR.Config.Map.IsWater(poi.x, poi.y) then
            drowned[#drowned + 1] = poi.id
        end
    end
    ok(#drowned == 0, 'no authored water rectangle contains a POI centre',
        table.concat(drowned, ', '))

    -- The warmup pad is not in the sea either.
    local pad = BR.Config.Match.warmupPos
    ok(not BR.Config.Map.IsWater(pad.x, pad.y), 'the warmup pad is on land')

    -- And the mask actually does something: the middle of the Pacific is water.
    ok(BR.Config.Map.IsWater(-3800.0, 0.0), 'the open Pacific reads as water')
    ok(not BR.Config.Map.IsWater(0.0, 0.0), 'central Los Santos does not')
end

-- ------------------------------------------------------------- loot.crates ---

describe('loot.crates')
do
    -- Containers are ONE model in two states: sealed, then open-and-empty.
    local a = BR.BuildLootLayout(4242)
    local crates, wrongProp = 0, 0
    for _, e in ipairs(a) do
        if e.kind == 'chest' then
            crates = crates + 1
            if e.prop ~= BR.Config.Loot.chestProp then wrongProp = wrongProp + 1 end
            if e.heading == nil then wrongProp = wrongProp + 1 end
        end
    end
    ok(crates > 0 and wrongProp == 0,
        'every crate is the sealed wooden crate, with a heading to sit at')
    ok(BR.Config.Loot.chestOpenProp ~= BR.Config.Loot.chestProp,
        'the husk is a different model from the sealed crate')

    -- Floor loot survives alongside the crates -- the Fortnite shape, not
    -- crates-only (user call, 2026-08-05).
    local floor = 0
    for _, e in ipairs(a) do
        if e.kind == BR.ItemKind.WEAPON then floor = floor + 1 end
    end
    ok(floor > 100, 'weapons still lie on the floor as well',
        ('%d of them'):format(floor))
end

-- ------------------------------------------------------------- loot.warmup ---

describe('loot.warmup')
do
    -- ONE shared layout: the warmup pad is a communal routing bucket, so a
    -- per-match layout would put two players side by side looking at
    -- different crates in the same spot.
    local w1 = BR.BuildWarmupLayout(99)
    local w2 = BR.BuildWarmupLayout(99)
    -- Not the exact authored count: candidates that land on the runway are
    -- dropped rather than forced somewhere else, and the runway cuts straight
    -- through the pad's annulus. Most of them should survive.
    ok(#w1 > BR.Config.Loot.warmup.crates * 0.6
       and #w1 <= BR.Config.Loot.warmup.crates,
        'the pad gets its authored crates, less what the runway rejects',
        ('%d of %d'):format(#w1, BR.Config.Loot.warmup.crates))

    local onRunway = 0
    for _, e in ipairs(w1) do
        if BR.Config.Map.IsNoLoot(e.x, e.y) then onRunway = onRunway + 1 end
    end
    ok(onRunway == 0, 'and none of them are on the runway',
        ('%d on the tarmac'):format(onRunway))

    local same = #w1 == #w2
    for i = 1, #w1 do
        if math.abs(w1[i].x - w2[i].x) > 1e-9 then same = false end
    end
    ok(same, 'and the same seed lays them out identically')

    local pad = BR.Config.Match.warmupPos
    local tooClose, tooFar, notCrate = 0, 0, 0
    for _, e in ipairs(w1) do
        local d = BR.Dist(e.x, e.y, pad.x, pad.y)
        -- An annulus: crates piled on the spawn point would be looted before
        -- anyone had to walk anywhere.
        if d < BR.Config.Loot.warmup.minRadius - 0.5 then
            tooClose = tooClose + 1
        end
        if d > BR.Config.Loot.warmup.radius + 1.0 then tooFar = tooFar + 1 end
        if e.kind ~= 'chest' or not e.warmup then notCrate = notCrate + 1 end
        if not e.contents or #e.contents == 0 then notCrate = notCrate + 1 end
    end
    ok(tooClose == 0, 'no crate spawns on top of the spawn point')
    ok(tooFar == 0, 'and none outside the authored radius')
    ok(notCrate == 0, 'every warmup entry is a crate with contents')

    local ids = {}
    local dupe = false
    for _, e in ipairs(w1) do
        if ids[e.id] then dupe = true end
        ids[e.id] = true
    end
    ok(not dupe, 'warmup ids are unique')
end

-- ------------------------------------------------------------- loot.stacks ---

describe('loot.stacks')
do
    -- LootPickOfRarity walks DOWN to a populated bucket. There is no legendary
    -- consumable, and a nil item here would become a nil-indexed prop lookup on
    -- the client -- an error inside a frame callback, which the loop registry
    -- suspends after five of.
    local rng = BR.Rng(2024)
    local nilPicks = 0
    for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        for _ = 1, 50 do
            if not BR.LootPickOfRarity(rng, BR.Config.ConsumablesByRarity, r) then
                nilPicks = nilPicks + 1
            end
            if not BR.LootPickOfRarity(rng, BR.Config.WeaponsByRarity, r) then
                nilPicks = nilPicks + 1
            end
            if not BR.LootPickOfRarity(rng, BR.Config.ThrowablesByRarity, r) then
                nilPicks = nilPicks + 1
            end
        end
    end
    ok(nilPicks == 0, 'no rarity produces a nil pick from any bucket')

    -- Legendary is authored on weapons only; a legendary consumable roll must
    -- pay out the best consumable that exists, not nothing and not a common.
    local best = BR.LootPickOfRarity(BR.Rng(1), BR.Config.ConsumablesByRarity,
        BR.Rarity.LEGENDARY)
    ok(best ~= nil and best.rarity == BR.Rarity.EPIC,
        'a legendary consumable roll walks down to the epic med kit')

    -- The rarity buckets must agree with the flat tables they were built from.
    local counted = 0
    for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        counted = counted + #BR.Config.WeaponsByRarity[r]
    end
    ok(counted == #BR.Config.Weapons, 'every weapon lands in exactly one bucket')

    ok(BR.Config.WeaponsOfRarity(BR.Rarity.LEGENDARY)[1] ~= nil,
        'WeaponsOfRarity still answers after the rewrite')

    -- FIREARM stacks carry a clip; the HUD reads it and a nil would render "/".
    -- MELEE deliberately does not: a machete has no magazine, and the bar keys
    -- on exactly this to decide whether to draw an ammo counter at all -- so a
    -- clip of 0 would be worse than no clip, printing "0 / 0" under a hatchet.
    local wr = BR.Rng(55)
    local noClip, meleeSeen = 0, 0
    for _ = 1, 400 do
        local s = BR.RollLootStack(wr, 3)
        if s.kind == BR.ItemKind.WEAPON then
            local w = BR.Config.WeaponById[s.item]
            if w and w.melee then
                meleeSeen = meleeSeen + 1
                if s.clip then noClip = noClip + 1 end   -- melee must NOT have one
            elseif not s.clip then
                noClip = noClip + 1
            end
        end
    end
    ok(noClip == 0, 'every firearm stack has a clip and no melee stack does')
    ok(meleeSeen > 0, 'and crates do roll melee', ('%d of 400'):format(meleeSeen))

    ok(BR.LootLabel({ kind = BR.ItemKind.AMMO, item = BR.AmmoType.HEAVY }) == 'Heavy Ammo',
        'LootLabel resolves ammo')
    ok(BR.LootLabel({ kind = BR.ItemKind.CONSUMABLE, item = 'medkit' }) == 'Med Kit',
        'LootLabel resolves consumables')
    ok(BR.LootLabel({ kind = BR.ItemKind.WEAPON, item = 'heavysniper' }) ~= 'Weapon',
        'LootLabel resolves weapons')
end

-- ------------------------------------------------------------------ names ---

describe('names')
do
    local V = BR.ValidateName

    -- ORDINARY NAMES MUST PASS. This is the half that matters most: a filter
    -- that rejects real people is worse than one that lets something through,
    -- because the second gets reported and the first gets uninstalled.
    for _, name in ipairs({
        'Kestrel', 'Rook', 'xX_Vandal_Xx', 'Ember 99', 'MrShifty',
        'Cucumber', 'Scunthorpe', 'Assassin', 'Bassline', 'Analyst',
        'Class', 'Shitake',   -- near-misses on purpose
    }) do
        ok(V(name), ('"%s" is allowed'):format(name))
    end

    -- Empty means "use my platform name" and is legal.
    local emptyOk, _, cleaned = V('   ')
    ok(emptyOk and cleaned == '', 'blank is allowed and means "platform name"')

    ok(not (V('ab')), 'too short is refused')
    ok(not (V(('x'):rep(21))), 'too long is refused')
    ok(not (V('1234')), 'digits alone are refused')

    -- The obvious dodges, which are the only ones worth testing: a literal
    -- wordlist catches nobody.
    for _, bad in ipairs({
        'fuck', 'FUCK', 'FuCk', 'f u c k', 'f.u.c.k', 'f-u-c-k',
        'fuuuuck', 'fvck', 'ph', -- 'ph' is a control: it must NOT be blocked
    }) do
        if bad == 'ph' then
            ok(V(bad .. 'oenix'), 'a word starting "ph" is fine')
        else
            ok(not (V(bad)), ('"%s" is refused'):format(bad))
        end
    end

    ok(not (V('5h1t')), 'leetspeak is folded before matching')
    ok(not (V('P00PMAN')), 'zeroes fold to letters')
    ok(not (V('Admin')), 'impersonating the system is refused')
    ok(not (V('S3rv3r')), 'and so is a leetspoken version of it')

    -- SLURS, HATE AND HARASSMENT. Not a taste question: these are names that
    -- other players cannot mute, because they are printed in the kill feed
    -- and the squad panel.
    for _, bad in ipairs({
        'Retard', 'r3tard', 'F4ggot', 'tr4ny', 'Nazi', 'H1TLER', 'kkk',
        'Wetback', 'Chink', 'Beaner', 'incel', 'MakeMeASandwich',
        'getinthekitchen', 'Rapist', 'Spastic', 'Femoid', 'wh1tepower',
    }) do
        ok(not (V(bad)), ('"%s" is refused'):format(bad))
    end

    -- AND THE WORDS THAT MERELY CONTAIN THEM MUST NOT BE. Every one of these
    -- is caught by an entry above unless INNOCENT rescues it -- which is the
    -- whole reason that list exists and why it grows with the blocklist.
    for _, fine in ipairs({
        'Suspicion', 'Raccoon', 'Tycoon', 'Montenegro', 'Therapist',
        'Grapes', 'Homogeneous', 'Shoes', 'VanDyke', 'Abolish', 'Platoon',
    }) do
        ok(V(fine), ('"%s" is allowed'):format(fine))
    end

    -- The reason is player-facing and specific enough to act on.
    local _, why = V('ab')
    ok(type(why) == 'string' and why:find('3'),
        'a too-short name says what the minimum is', tostring(why))
end

-- ------------------------------------------------------------------ focus ---

describe('focus')
do
    -- FOCUS IS THE WORST BUG THIS INTERFACE CAN PRODUCE. A leak means the
    -- player cannot move, cannot shoot, and cannot recover without
    -- reconnecting -- and it has been got wrong twice, both times by deriving
    -- behaviour from a SUMMARY of the stack rather than from the stack.
    local R = BR.FocusResolve

    ok(R({}).held == false, 'an empty stack holds nothing')
    ok(R({}).screen == 'none', 'and reports no screen')
    ok(R({}).keepInput == false, 'and never keeps input')

    ok(R({ 'lobby' }).held, 'one screen takes focus')
    ok(R({ 'lobby' }).screen == 'lobby', 'and is the screen')

    -- THE 2026-08-09 BUG, in one assertion. Pushing settings onto an
    -- already-focused stack leaves `held` unchanged, which is exactly why the
    -- bridge's old `if want == focusHeld then return end` sent nothing and the
    -- screen never opened. The SCREEN is what changed, and the screen is what
    -- the page renders from.
    local before, after = R({ 'lobby' }), R({ 'lobby', 'settings' })
    ok(before.held == after.held, 'stacking a screen does not change `held`')
    ok(before.screen ~= after.screen, 'but it DOES change the screen -- the bit that matters')
    ok(after.screen == 'settings', 'and the top of the stack is what owns it')

    -- Keep-input is an ALLOWLIST. Every screen not named is a menu, which is
    -- the safe default: the deny-list version silently gave game input to
    -- every screen added after it was written.
    ok(R({ 'inventory' }).keepInput, 'the inventory keeps game input -- it is used mid-fight')

    -- `players` IS IN THE SECOND LIST AND NOT THE FIRST, and it is the only
    -- entry on either that anybody has argued about. It kept game input for one
    -- day so the roster could be read on the move, and the owner reported the
    -- result (2026-08-16): "the pointer is available for use while the menu is
    -- open, but doesn't prevent game control. So moving the mouse still moves
    -- the camera, and I'm able to walk as well while it's open." A panel of
    -- checkboxes and dropdowns whose cursor is also the camera is a panel you
    -- cannot point at (#135). Asserted here so putting it back is a red build
    -- and a decision, rather than a one-word edit to a table.
    for _, s in ipairs({ 'lobby', 'chat', 'settings', 'locker', 'summary', 'squad',
                         'players' }) do
        ok(not R({ s }).keepInput, ('%s does not keep game input'):format(s))
    end

    -- AND `playersReport` IS NOT A SCREEN ANY MORE. It existed only to be
    -- absent from BR.FocusKeepsInput; with view mode absent too, it was a
    -- second name for the same focus. An unknown screen resolving to
    -- keepInput=false is the allowlist behaving correctly -- this asserts the
    -- table does not still carry a special case for a name nothing sends.
    ok(BR.FocusKeepsInput['playersReport'] == nil,
        'the report screen is gone from the keep-input table, not just unused')

    -- A menu OVER the inventory has to take input back, or the player is
    -- reading a slider while running.
    ok(not R({ 'inventory', 'settings' }).keepInput,
        'a menu opened over the inventory takes input back')
    ok(R({ 'settings', 'inventory' }).keepInput,
        'and the inventory opened over a menu gets it again')

    -- Popping back down has to be visible too -- the return trip is how a
    -- screen ever closes.
    ok(R({ 'lobby', 'settings' }).screen ~= R({ 'lobby' }).screen,
        'popping back to the lobby is a change the page can see')
end

-- ----------------------------------------------------------------- outbox ---
--
-- The outbox is what stands between "something outside the game is down" and
-- "the match is down". Every assertion here is one of those two words.

describe('outbox')
do
    -- A batch is only in flight once. A driver polling on a timer must not be
    -- able to send the same events twice by calling take() again.
    local ob = BR.Outbox.new()
    ob:emit('a', { n = 1 }, 0)
    ob:emit('b', { n = 2 }, 0)

    local first = ob:take(0)
    ok(first and #first == 2, 'take returns everything queued')
    ok(ob:take(0) == nil, 'take returns nil while a batch is in flight')

    ob:ack(0)
    ok(ob:stats().sent == 2, 'ack counts what was delivered')
    ok(ob:take(0) == nil, 'take returns nil when the queue is empty')
end

do
    -- Ordering across a retry. A failed batch goes back in FRONT of whatever
    -- was queued while it was in flight, or an audit log reads out of order.
    local ob = BR.Outbox.new()
    ob:emit('a', {}, 0)
    ob:emit('b', {}, 0)
    ob:take(0)
    ob:emit('c', {}, 0)

    ok(ob:nack(0) == true, 'the first failure retries')

    local again = ob:take(99999)
    ok(again and #again == 3, 'the retry picks up the events queued behind it')
    ok(again and again[1].kind == 'a' and again[3].kind == 'c',
        'and oldest-first order survives the retry')
end

do
    -- Giving up. retryMax failures must drop the batch rather than wedge
    -- everything behind it forever -- "queue and drop, do not retry into a
    -- stall".
    local ob = BR.Outbox.new({ retryMax = 2 })
    ob:emit('a', {}, 0)

    local t = 0
    ob:take(t)
    ok(ob:nack(t) == true,  'failure 1 of 2 retries')
    t = 999999; ob:take(t)
    ok(ob:nack(t) == true,  'failure 2 of 2 retries')
    t = 999999 * 2; ob:take(t)
    ok(ob:nack(t) == false, 'failure 3 gives up')

    ok(ob:depth() == 0, 'and the batch is gone rather than queued forever')
    ok(ob:stats().droppedRetry == 1, 'the give-up is counted, not silent')
end

do
    -- Backoff. take() must refuse to hand out work during the backoff window,
    -- or "retry with backoff" is just "retry in a tight loop".
    local ob = BR.Outbox.new({ backoffMs = 1000 })
    ob:emit('a', {}, 0)
    ob:take(0)
    ob:nack(0)

    ok(ob:take(500)  == nil, 'take is silent inside the backoff window')
    ok(ob:take(1000) ~= nil, 'and hands out work once it has passed')
end

do
    -- Backoff grows, and stops growing. An uncapped exponential reaches
    -- "retry next century" after surprisingly few failures.
    local ob = BR.Outbox.new({ backoffMs = 1000, backoffMaxMs = 4000, retryMax = 99 })
    ob:emit('a', {}, 0)

    ob:take(0);     ob:nack(0)
    local first = ob.nextAttempt
    ob:take(first); ob:nack(first)
    local second = ob.nextAttempt - first

    ok(first == 1000, 'first backoff is the base delay')
    ok(second == 2000, 'the second doubles')

    for _ = 1, 6 do
        local t = ob.nextAttempt
        ob:take(t); ob:nack(t)
    end
    local t = ob.nextAttempt
    ob:take(t); ob:nack(t)
    ok(ob.nextAttempt - t == 4000, 'and it caps rather than reaching next century')
end

do
    -- Overflow drops the OLDEST. A full queue means the endpoint is behind,
    -- and the freshest events are the ones still worth having.
    local ob = BR.Outbox.new({ capacity = 3 })
    for i = 1, 5 do ob:emit('e', { n = i }, 0) end

    local batch = ob:take(0)
    ok(#batch == 3, 'the queue never exceeds its capacity')
    ok(batch[1].data.n == 3 and batch[3].data.n == 5,
        'and what survives is the newest, not the oldest')
    ok(ob:stats().droppedFull == 2, 'the overflow is counted')
end

do
    -- No endpoint configured: emit still costs nothing and still counts, so
    -- callers never branch on whether persistence exists.
    local ob = BR.Outbox.new({ enabled = false })
    ok(ob:emit('a', {}, 0) == false, 'a disabled outbox refuses the event')
    ok(ob:depth() == 0, 'and queues nothing')
    ok(ob:stats().droppedOff == 1, 'but still counts what would have been sent')
end

-- --------------------------------------------------------------- identity ---
--
-- These decide who a person IS for bans and admin grants. A wrong answer here
-- files a ban against the wrong human.

describe('identity')
do
    local P = BR.Identity.parse

    -- The prefix trap. `license2` is a DIFFERENT FiveM identifier from
    -- `license`, not a variant, so a `raw:sub(1, 7) == 'license'` style test
    -- would file two people's identifiers under one key.
    local byKind = P({ 'license2:bbb' })
    ok(byKind.license == nil,     'license2 does not satisfy license')
    ok(byKind.license2 == 'bbb',  'and is kept under its own key')

    local both = P({ 'license:aaa', 'license2:bbb' })
    ok(both.license == 'aaa' and both.license2 == 'bbb',
        'the two coexist without colliding')
end

do
    -- IP is refused. This is a deliberate product decision, not an oversight,
    -- so it gets a test that fails loudly if someone "fixes" the allowlist.
    local byKind, ordered, dropped = BR.Identity.parse({
        'license:aaa', 'ip:203.0.113.7', 'discord:123',
    })
    ok(byKind.ip == nil,  'ip is never collected')
    ok(dropped == 1,      'and the refusal is counted')
    ok(#ordered == 2,     'the rest survive')
end

do
    -- An allowlist means anything unanticipated is excluded by construction --
    -- including identifier types FiveM has not invented yet.
    local byKind, _, dropped = BR.Identity.parse({ 'quantumid:xyz', 'license:aaa' })
    ok(byKind.quantumid == nil, 'an unknown identifier type is refused')
    ok(dropped == 1,            'and counted')
end

do
    -- Deterministic order. "Never iterate a hash" applies here as much as it
    -- does to the loot tables: `ordered` follows ALLOWED, not input order.
    local _, ordered = BR.Identity.parse({ 'live:c', 'discord:b', 'license:a' })
    ok(ordered[1].kind == 'license', 'ordered starts at license')
    ok(ordered[2].kind == 'discord', 'then discord')
    ok(ordered[3].kind == 'live',    'then live -- input order is irrelevant')
end

do
    -- Junk in the list must not become junk in the record.
    local byKind, ordered, dropped = BR.Identity.parse({
        'nocolonhere', 'license:', ':aaa', '', 'steam:110000100000000',
    })
    ok(byKind.steam == '110000100000000', 'a good identifier survives the junk')
    ok(#ordered == 1,  'and nothing else does')
    ok(dropped == 4,   'every malformed entry is counted')
end

do
    -- Duplicates: first wins. A second value for the same kind has no better
    -- claim than the first, and picking the later one would let a spoofed
    -- trailing entry override a real leading one.
    local byKind, _, dropped = BR.Identity.parse({ 'discord:first', 'discord:second' })
    ok(byKind.discord == 'first', 'the first value for a kind wins')
    ok(dropped == 1,              'the duplicate is counted')
end

do
    ok(select('#', BR.Identity.parse({})) == 3, 'an empty list is not an error')
    local byKind, ordered, dropped = BR.Identity.parse(nil)
    ok(next(byKind) == nil and #ordered == 0 and dropped == 0,
        'nor is a nil list')
end

do
    -- qualified() exists for exactly one reason, and this is it: br_stats keys
    -- `br_players` on the FULL 'license:abc...' string, and every row already
    -- stored uses it. When profiles.lua became a consumer of this module in M9,
    -- returning parse()'s bare value instead would have silently re-keyed the
    -- entire table -- a migration wearing a refactor's clothes, with no error
    -- anywhere and every returning player looking brand new.
    --
    -- So the round trip is the contract, and it is asserted rather than assumed.
    local raw = 'license:110000112345678'
    local byKind = BR.Identity.parse({ raw })
    ok(BR.Identity.qualified('license', byKind.license) == raw,
        'qualified(parse(x)) reproduces the identifier FiveM reported')

    ok(BR.Identity.qualified('discord', '123') == 'discord:123',
        'and it works for every kind, not just license')

    -- Nil in, nil out, so `qualified(k, licenseOf(src))` needs no guard at the
    -- call site -- a player with no license must stay nil rather than becoming
    -- the string "license:nil", which would be a real key colliding every
    -- licence-less player into one profile.
    ok(BR.Identity.qualified('license', nil) == nil,
        'a missing identifier stays missing rather than becoming "license:nil"')
end

-- ------------------------------------------------------- incident building ---

describe('incident.severity')
do
    local S = BR.IncidentBuild.SEVERITY_OF
    local R = BR.ShotRefusal

    -- EVERY SUSPICIOUS REFUSAL HAS A SEVERITY -- WITH ONE NAMED EXCEPTION --
    -- checked exhaustively rather than by listing the ones I remembered. The
    -- failure this prevents is the quiet one: a refusal with no entry classifies
    -- as "not countable", so adding a new MEANS to BR.ShotSuspicious without
    -- touching the severity table would silently stop filing incidents for it,
    -- and nothing anywhere would log that it had.
    --
    -- The exception is written as an allowlist so that adding a second one is a
    -- decision somebody has to make here, in the open, rather than a nil that
    -- passes.
    local NO_SEVERITY_BY_DESIGN = { [R.SELF] = true }

    local missing = {}
    for reason in pairs(BR.ShotSuspicious) do
        if S[reason] == nil and not NO_SEVERITY_BY_DESIGN[reason] then
            missing[#missing + 1] = tostring(reason)
        end
    end
    ok(#missing == 0,
        'every BR.ShotSuspicious reason has a severity (missing: '
            .. (table.concat(missing, ', ')) .. ')')

    -- And the reverse: nothing here that the anticheat cannot actually produce.
    -- An orphan entry is a rule about a case that never happens, which reads as
    -- coverage and is not.
    local orphans = {}
    for reason in pairs(S) do
        if not BR.ShotSuspicious[reason] then
            orphans[#orphans + 1] = tostring(reason)
        end
    end
    ok(#orphans == 0,
        'no severity is defined for a refusal that never counts (orphans: '
            .. (table.concat(orphans, ', ')) .. ')')

    local BAR = BR.Config.Combat.refusalBar
    local function barOf(reason) return (BR.ShotBarFor(reason, BAR)) end
    local function crosses(tally) return (BR.ShotTallyVerdict(tally, BAR)) end

    -- THE TIERS THEMSELVES. Means the server never issued are the loud ones;
    -- numbers the weapon does not have are the ones with an innocent story
    -- (position sampling plus a bad tick), and repeated self-harm hurts nobody.
    ok(S[R.NO_WEAPON] == 'high', 'a weapon the server never issued is high')
    ok(S[R.NOT_HELD] == 'high', 'a weapon not in their hands is high')
    ok(S[R.NO_AMMO] == 'high', 'a shot from an empty magazine is high')
    ok(S[R.NOT_THROWN] == 'high', 'an explosive they never threw is high')
    ok(S[R.TOO_FAR] == 'normal', 'out of range is normal -- positions are stale')
    ok(S[R.TOO_FAST] == 'normal', 'too fast is normal for the same reason')

    -- SELF IS RECORDED AND NO LONGER COUNTED (owner call, 2026-08-14).
    --
    -- It stays in BR.ShotSuspicious, so it is still refused, still printed, and
    -- still appears in the tally an admin reads. It has no tier, so it contributes
    -- to no bar. While the bar was eight it HAD to count -- otherwise somebody
    -- mixing self-harm with real refusals stayed under it and never tripped. At a
    -- bar of one or two the same reasoning inverts: one self-hit beside one
    -- marginal out-of-range shot would open a case, and a player could manufacture
    -- one against themselves by standing in their own grenades.
    --
    -- The arithmetic behind that: selfLimit = 2 over selfWindowMs = 5000, so the
    -- third self-damage tick in five seconds already reads as repetition, and one
    -- grenade at your own feet lands several ticks well inside it.
    ok(BR.ShotSuspicious[R.SELF] == true,
        'repeated self-harm is still refused and still recorded')
    ok(S[R.SELF] == nil, 'but has no tier, so it counts toward no bar')
    ok(barOf(R.SELF) == nil, 'and asking for its bar says there is not one')

    -- RULES ARE ABSENT ENTIRELY, which is the same guarantee the exclusion test
    -- makes upstream, asserted again here because this table is what a reviewer
    -- would edit.
    ok(S[R.SAME_SQUAD] == nil, 'friendly fire has no severity, because it is not an incident')
    ok(S[R.WARMUP] == nil, 'a warmup scrap has no severity')
    ok(S[R.NOT_LIVE] == nil, 'a shot that raced a match boundary has no severity')
    ok(S[R.OTHER_MATCH] == nil, 'a cross-match shot has no severity')

    -- THE BARS. One for high, two for normal -- and NO_WEAPON held at two despite
    -- being high, which is the one entry that looks inconsistent. It is the
    -- catch-all: it means the hash is in neither our weapon table nor the world's,
    -- so its false-positive rate tracks how complete two lookup tables are rather
    -- than how dishonest the shooter is. Nobody running a conjured weapon fires
    -- exactly once.
    ok(barOf(R.NOT_HELD) == 1, 'a weapon not in their hands files on the first one')
    ok(barOf(R.NO_AMMO) == 1, 'so does a shot from an empty magazine')
    ok(barOf(R.NOT_THROWN) == 1, 'and an explosive they never threw')
    ok(barOf(R.NO_WEAPON) == 2, 'a weapon we do not know at all wants two')
    ok(barOf(R.TOO_FAR) == 2, 'out of range wants two')
    ok(barOf(R.TOO_FAST) == 2, 'and so does too fast')

    -- A MISSING CONFIG MUST NOT MEAN "FILE ON SIGHT". If BR.Config.Combat failed to
    -- load, the safe default is the strictest thing that is still a rule, not zero.
    ok((BR.ShotBarFor(R.TOO_FAR, nil)) == 1,
        'with no config at all the bar defaults to one, never to zero')

    -- CROSSING, which is the question damage.lua actually asks.
    ok(crosses({ [R.NOT_HELD] = 1 }), 'a single not-held crosses immediately')
    ok(not crosses({ [R.NO_WEAPON] = 1 }), 'a single unknown weapon does not')
    ok(crosses({ [R.NO_WEAPON] = 2 }), 'but two of them do')
    ok(not crosses({ [R.TOO_FAR] = 1 }), 'one out-of-range shot is a bad tick')
    ok(crosses({ [R.TOO_FAR] = 2 }), 'two of them is a pattern')
    ok(not crosses({ [R.SELF] = 40 }),
        'no quantity of self-harm crosses anything at all')
    ok(not crosses({ [R.SAME_SQUAD] = 40 }), 'nor does any amount of friendly fire')
    ok(not crosses({}), 'an empty tally crosses nothing')
    ok(not crosses(nil), 'and neither does a missing one')

    -- EACH REASON IS TESTED AGAINST ITS OWN BAR, NOT AGAINST A TOTAL. Two
    -- different reasons that are each one short file nothing -- which is exactly
    -- the case the old count-everything threshold would have filed, and the reason
    -- the bar is per reason rather than a sum.
    ok(not crosses({ [R.TOO_FAR] = 1, [R.NO_WEAPON] = 1 }),
        'two different reasons, each below its own bar, file nothing')

    -- THE WORST REASON WINS, which is the whole reason damage.lua sends a tally.
    -- Before it did, seven conjured-weapon shots followed by one milder refusal
    -- were filed as the milder thing and sorted to the bottom of the queue -- the
    -- exact opposite of what they deserved.
    ok(BR.IncidentBuild.severityOf({ [R.SELF] = 7, [R.NO_WEAPON] = 2 }) == 'high',
        'two conjured-weapon shots among seven self-hits file as high')
    ok(BR.IncidentBuild.severityOf({ [R.TOO_FAR] = 4, [R.NO_AMMO] = 1 }) == 'high',
        'high beats normal')
    ok(BR.IncidentBuild.severityOf({ [R.TOO_FAR] = 4, [R.SELF] = 4 }) == 'normal',
        'and self-hits do not drag a real signal down')
    ok(BR.IncidentBuild.severityOf({ [R.SELF] = 8 }) == nil,
        'a pure self-harm match files nothing -- it is probably two grenades')

    -- BELOW THE BAR THERE IS NO SEVERITY, because there is no case to grade. This
    -- is the property that keeps the filing decision and the severity written on
    -- the row from being two separate traversals that can disagree.
    ok(BR.IncidentBuild.severityOf({ [R.NO_WEAPON] = 1 }) == nil,
        'a reason one short of its bar grades as nothing, not as high')

    -- A tally entry of zero is a reason that never happened.
    ok(BR.IncidentBuild.severityOf({ [R.NO_WEAPON] = 0, [R.TOO_FAR] = 3 }) == 'normal',
        'a zero count does not raise the severity')

    -- Rules in the tally cannot smuggle an incident in either.
    ok(BR.IncidentBuild.severityOf({ [R.SAME_SQUAD] = 20 }) == nil,
        'a match of nothing but friendly fire classifies as nothing')

    -- FALLS BACK TO THE LAST REASON, so an event from a build that predates the
    -- tally still classifies. Same instinct as the console keeping the older
    -- `action` values: one side being a deploy behind must not lose the record.
    ok(BR.IncidentBuild.severityOf(nil, R.NO_AMMO) == 'high',
        'an event with no tally classifies from its last reason')
    ok(BR.IncidentBuild.severityOf(nil, nil) == nil,
        'an event with neither classifies as nothing')
    ok(BR.IncidentBuild.severityOf(nil, R.SELF) == nil,
        'and the SELF exclusion survives the fallback path too')
end

describe('incident.payload')
do
    local R = BR.ShotRefusal
    local LIC = 'license:abc'

    -- A SENTINEL, because `over = { license = nil }` sets no key at all -- pairs()
    -- never sees it and the override silently does nothing. That is the trap this
    -- whole module exists around (a Lua nil is absence, not a value), so the test
    -- helper had better not fall into it: the first version of this block passed
    -- vacuously against the default license.
    local CLEAR = {}
    local function ev(over)
        local e = {
            src = 3, name = 'Someone', license = LIC, matchId = 7,
            count = 8, windowMs = 10000,
            reason = R.NO_WEAPON, reasons = { [R.NO_WEAPON] = 8 },
            action = 'incident', at = 90000,
        }
        for k, v in pairs(over or {}) do
            e[k] = (v ~= CLEAR) and v or nil
        end
        return e
    end

    -- NO LICENSE, NO INCIDENT. The strongest refusal in the file: a case keyed to
    -- a server id is a case about whoever holds that slot next, and it cannot be
    -- withdrawn once a human has read it.
    local p, why = BR.IncidentBuild.fromRefusal(ev({ license = CLEAR }), {})
    ok(p == nil and why == 'no license',
        'a refusal with no license files nothing, and says why')

    ok(select(1, BR.IncidentBuild.fromRefusal(ev({ license = '' }), {})) == nil,
        'an empty license is treated as no license')

    ok(select(1, BR.IncidentBuild.fromRefusal(nil, {})) == nil,
        'no event files nothing rather than throwing')

    -- A window of rules should never have reached here (damage.lua gates it), so
    -- this is the belt to that braces: even if one did, nothing is filed.
    local rulesOnly, ruleWhy = BR.IncidentBuild.fromRefusal(
        ev({ reason = R.SAME_SQUAD, reasons = { [R.SAME_SQUAD] = 9 } }), {})
    ok(rulesOnly == nil and ruleWhy == 'not a countable refusal',
        'friendly fire cannot produce a payload even if it reaches the builder')

    -- A PURE SELF-HARM CLUSTER DOES REACH HERE -- damage.lua counts it, by design
    -- -- and is declined at this layer rather than at the counter. The counter
    -- must not learn to forgive a reason, or somebody mixing self-hits with real
    -- means would fall below the threshold and never trip at all.
    local selfOnly, selfWhy = BR.IncidentBuild.fromRefusal(
        ev({ reason = R.SELF, reasons = { [R.SELF] = 8 } }), {})
    ok(selfOnly == nil and selfWhy == 'not a countable refusal',
        'a window of nothing but self-harm files no incident')

    -- ...and the moment real means cross their own bar, the case is filed at that
    -- severity rather than being softened by the self-hits around it.
    local mixed = BR.IncidentBuild.fromRefusal(
        ev({ reason = R.SELF, reasons = { [R.SELF] = 7, [R.NO_WEAPON] = 2 } }), {})
    ok(mixed ~= nil and mixed.severity == 'high',
        'two conjured-weapon shots among seven self-hits file as high')

    -- ONE SHORT OF THE BAR IS STILL NOTHING, even with self-harm piled around it.
    -- Self-hits used to count toward the threshold, so this tally would have filed;
    -- they no longer do, and NO_WEAPON alone wants two.
    local nearly, nearlyWhy = BR.IncidentBuild.fromRefusal(
        ev({ reason = R.NO_WEAPON, reasons = { [R.SELF] = 7, [R.NO_WEAPON] = 1 } }), {})
    ok(nearly == nil and nearlyWhy == 'not a countable refusal',
        'seven self-hits cannot carry a single unknown weapon over its bar')

    -- The ordinary case.
    local rec = {
        key = 3, license = LIC, name = 'Someone', matchId = 7, squadId = 2,
        openedAt = 30000, leftAt = nil,
        chat = { { text = 'hi', channel = 'all', at = 40000 } },
        kills = { { killer = 'Someone', victim = 'Else', cause = 'shot', at = 50000 } },
    }
    local out = BR.IncidentBuild.fromRefusal(ev(), { rec })

    ok(out ~= nil, 'a countable refusal with a license produces a payload')
    ok(out.kind == 'anticheat', 'it is filed as an anticheat incident')
    ok(out.category == 'system', 'the category is system, not a player category')
    ok(out.state == 'pending_review', 'it opens for review rather than resolved')
    ok(out.severity == 'high', 'severity comes from the tally')
    ok(out.subjectLicense == LIC, 'the subject is the shooter')
    ok(out.subjectName == 'Someone', 'and their name travels with it')
    ok(out.matchId == 7, 'the match is recorded')
    ok(out.atGameMs == 90000,
        'the timestamp leaves as a GAME clock reading -- br_ringmaster realises it')
    ok(out.openedAt == nil,
        'and openedAt is NOT set here: br_core has no clock worth putting in a record')

    -- SQUAD AT INCIDENT TIME. The question the console has to answer about a
    -- report is "were these two on the same team", and squads change between the
    -- incident and anybody reading it.
    ok(out.subjects and #out.subjects == 1, 'there is one subject')
    ok(out.subjects[1].license == LIC, 'subjects[1] mirrors subjectLicense')
    ok(out.subjects[1].squadId == 2, 'the squad at incident time is captured')
    ok(out.subjects[1].left == false, 'and whether they had already gone')

    ok(out.refusal.count == 8, 'the refusal count is on the record')
    ok(out.refusal.reasons[R.NO_WEAPON] == 8, 'so is the per-reason tally')
    ok(out.refusal.action == 'incident', 'and what the server actually did')

    ok(#out.evidence == 1, 'the evidence record is attached')
    ok(out.evidence[1].chat[1].text == 'hi', 'with its chat')
    ok(out.evidence[1].kills[1].victim == 'Else', 'and its kills')
    ok(out.evidence[1].license == LIC, 'keyed to a license')

    -- THE SERVER ID DOES NOT TRAVEL. Sending it would invite exactly the mistake
    -- sealing exists to prevent: treating a recycled slot number as a person.
    ok(out.evidence[1].key == nil, 'the server id is NOT on the wire')

    -- A REPORTER IS ABSENT, NOT NULL, because a Lua key set to nil is not sent.
    -- br_ddb writes the null; this asserts br_core does not pretend to.
    ok(out.reporterLicense == nil, 'the system filed this, so there is no reporter')

    ok(out.summary:find('8 shots refused in 10s', 1, true) ~= nil,
        'the summary reads as a sentence an admin can scan')
    ok(out.summary:find(R.NO_WEAPON, 1, true) ~= nil,
        'and names the reason')

    -- A DEPARTED PLAYER IS STILL FILEABLE, which is the case the seal exists for.
    local sealed = {
        key = 3, license = LIC, name = 'Someone', matchId = 7, squadId = 2,
        openedAt = 30000, leftAt = 88000, chat = {}, kills = {},
    }
    local gone = BR.IncidentBuild.fromRefusal(ev(), { sealed })
    ok(gone ~= nil, 'somebody who already left can still have a case filed')
    ok(gone.evidence[1].left == true, 'and the record says they left')
    ok(gone.subjects[1].left == true, 'as does the subject row')

    -- A RECONNECT IS TWO SESSIONS, and both belong on the case: the evidence does
    -- not stop counting because somebody bounced their client.
    local two = BR.IncidentBuild.fromRefusal(ev(), { sealed, rec })
    ok(#two.evidence == 2, 'two sessions produce two evidence records')
    ok(two.subjects[1].left == false,
        'the subject row reflects the NEWEST session, which is the live one')

    -- No evidence at all is survivable, not a refusal. The buffer may have been
    -- cleared by a restart, and a case with a refusal cluster and no chat is
    -- still worth filing.
    local bare = BR.IncidentBuild.fromRefusal(ev(), nil)
    ok(bare ~= nil, 'an incident with no evidence is still filed')
    ok(#bare.evidence == 0, 'with an empty evidence list')
    ok(bare.subjects[1].squadId == nil, 'and no squad claim it cannot support')
end

-- ==========================================================================
-- A FALL, END TO END. (owner, 2026-08-17: "I tried triggering DBNO by falling
-- from a height but it went straight to dead")
-- ==========================================================================
--
-- WHY THIS IS HERE AND NOT IN A CLIENT SUITE. This is the THIRD round on the
-- same symptom. `ef501ef` fixed it and the owner confirmed it working;
-- `58502b0` re-sequenced the knock and it came back. Neither suite could have
-- caught the return trip, and the reason is the same one `a8b22c7` gave for
-- #115: the question is a RACE, and no suite in this repo lets time pass
-- during one.
--
--   * ef501ef's own coverage (the `dbno.deadPed` block) is entirely SERVER
--     side. It asserts the knock, the dropped `engineHp` sample and the
--     HEALTH_SYNC -- and never loads `client/dbno.lua`, so `enterDowned()`,
--     which is the half that stands the corpse back up, was never executed by
--     anything at all. Rewriting it could not turn that block red.
--
--   * 58502b0's coverage DOES load `client/dbno.lua`, and it is about ORDER,
--     not TIME: `Citizen.CreateThread` collects thunks that the test calls by
--     hand and `Citizen.Wait` is a no-op that only records that it happened.
--     The whole knock therefore occurs in a single instant, with `dead = true`
--     set by hand beforehand. In that world "has the death flag settled yet?"
--     is not a question that can be asked, let alone answered wrongly.
--
-- So this block runs BOTH REAL FILES -- `server/combat.lua` and
-- `client/dbno.lua` -- in two sandboxes wired together with a latency, over
-- REAL coroutines driven by a 16ms pump, with the engine's death modelled the
-- way `a8b22c7` established it for `client/state.lua`:
--
--   1. the death TASK and the `IsEntityDead` FLAG are separate things;
--   2. the flag settles LATE, some frames after the task starts;
--   3. writing health does not cancel a death task, and a settled corpse
--      ignores the write entirely;
--   4. `NetworkResurrectLocalPlayer` clears the task, the flag and the health.
--
-- WHAT THE FALL ACTUALLY IS. `server/damage.lua` reads WEAPON_FALL as
-- environmental and returns, so GTA kills the ped and nothing clamps it. The
-- client's own `gamerules.death` watcher reports that death; the server turns
-- it into a knock. Everything after that is the two halves of one event
-- racing: the ped finishing its death, and the client being told to stand it
-- back up.
--
-- WHAT IT DOES NOT CLAIM: entity ownership, and the exact number of
-- milliseconds GTA takes to settle `IsEntityDead`. That is why the settle time
-- and the round trip are a MATRIX rather than a number -- the fix has to make
-- the outcome timing-independent, which is the only property a test can
-- honestly demand of a race.

local SANDBOX_STD = {
    assert = assert, error = error, ipairs = ipairs, next = next,
    pairs = pairs, pcall = pcall, rawequal = rawequal, rawget = rawget,
    rawlen = rawlen, rawset = rawset, select = select, xpcall = xpcall,
    setmetatable = setmetatable, getmetatable = getmetatable,
    tonumber = tonumber, tostring = tostring, type = type,
    math = math, string = string, table = table,
    coroutine = coroutine, unpack = table.unpack,
}

local RES = 'resources/[fivem-royale]/'

-- Every br_lib file a br_core file expects to have been loaded before it, in
-- fxmanifest order. Each sandbox gets its OWN copy: a client and a server are
-- separate Lua states in the real game and they are separate ones here.
local SANDBOX_LIB = {
    'br_lib/shared/enums.lua', 'br_lib/shared/protocol.lua',
    'br_lib/shared/names.lua', 'br_lib/shared/rng.lua',
    'br_lib/shared/geo.lua', 'br_lib/shared/clock.lua',
    'br_lib/shared/sched.lua', 'br_lib/config/match.lua',
    'br_lib/config/storm.lua', 'br_lib/config/map.lua',
    'br_lib/config/weapons.lua', 'br_lib/config/vehicles.lua',
    'br_lib/config/loot.lua',
    'br_lib/config/audio.lua', 'br_lib/config/peds.lua',
    'br_lib/config/market.lua', 'br_lib/shared/xp.lua',
    'br_lib/shared/storm_solve.lua', 'br_lib/shared/combat_solve.lua',
    'br_lib/shared/loot_gen.lua',
}

--- A fresh sandbox with nothing of the host process in it but SANDBOX_STD.
---
--- Explicit rather than inherited, so a native the production code reaches for
--- and this harness never defined is an immediate "attempt to call a nil value"
--- rather than a silent no-op. A silent no-op is how a suite goes green while
--- the thing it claims to test does nothing.
local function newSandbox()
    local env = setmetatable({}, { __index = function(_, k) return SANDBOX_STD[k] end })
    env._G = env
    return env
end

--- Load real production files into a sandbox, or die loudly.
local function loadInto(env, list)
    for _, f in ipairs(list) do
        local chunk, err = loadfile(RES .. f, 't', env)
        if not chunk then
            io.write('\27[31msandbox load error\27[0m ', f, ': ', tostring(err), '\n')
            os.exit(1)
        end
        local okc, e2 = pcall(chunk)
        if not okc then
            io.write('\27[31msandbox run error\27[0m ', f, ': ', tostring(e2), '\n')
            os.exit(1)
        end
    end
end

-- ---------------------------------------------------------------------------
-- The server: the real server/combat.lua, behind the smallest roster that can
-- hold it up.
-- ---------------------------------------------------------------------------

--- @return table  { env, roster, clientEvents, died(src, data), tick(nowMs) }
local function newServer()
    local env = newSandbox()
    local S = { now = 0, roster = {}, out = {}, notices = {} }

    env.GetGameTimer   = function() return S.now end
    env.print          = function() end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetPlayerName  = function(s) return 'P' .. tostring(s) end
    env.GetPlayers     = function() return {} end
    env.GetPlayerPed   = function() return 0 end
    env.GetHashKey     = function(s) return #tostring(s) end
    env.RegisterNetEvent = function() end
    env.RegisterCommand  = function() end
    env.CancelEvent      = function() end
    env.Citizen = { CreateThread = function() end, Wait = function() end,
                    SetTimeout = function() end }

    local handlers = {}
    env.AddEventHandler = function(n, fn)
        handlers[n] = handlers[n] or {}
        handlers[n][#handlers[n] + 1] = fn
    end
    env.TriggerEvent = function(n, ...)
        for _, fn in ipairs(handlers[n] or {}) do fn(...) end
    end
    env.TriggerClientEvent = function(ev, target, payload)
        S.out[#S.out + 1] = { event = ev, target = target, payload = payload }
    end

    loadInto(env, SANDBOX_LIB)

    -- The roster, reduced to the four verbs combat.lua actually uses. Real
    -- enough that `BR.Roster.each` predicates run: `combat.deathcheck` is one
    -- of the two paths under test and it is a predicate over the whole roster.
    env.BR.Roster = {
        get = function(s) return S.roster[s] end,
        update = function(s, fields)
            local e = S.roster[s]
            if e then for k, v in pairs(fields) do e[k] = v end end
        end,
        setState = function(s, st) if S.roster[s] then S.roster[s].state = st end end,
        each = function(pred, fn)
            for src, e in pairs(S.roster) do
                if pred(e) and fn then fn(src, e) end
            end
        end,
    }
    env.BR.Server = {
        devMode = false, matches = {},
        count = function() return 2 end,
        matchOf = function(s)
            local e = S.roster[s]
            return e and env.BR.Server.matches[e.matchId] or nil
        end,
        notify = function(_, msg) S.notices[#S.notices + 1] = msg end,
        notifyClear = function() end,
        squadsAlive = function() return 2 end,
    }
    env.BR.Broadcast = { delta = function() end, toMatch = function() end }
    env.BR.Evidence  = { noteKill = function() end }
    env.BR.Loot      = { deathBox = function() end }
    env.BR.Damage    = { applyHit = function() end }

    loadInto(env, { 'br_core/server/combat.lua' })

    env.BR.Server.matches[1] = { id = 1, state = env.BR.MatchState.PLAYING,
                                 mode = env.BR.Mode.SQUAD.key,
                                 players = { 1, 2 }, startedAt = 0 }
    for _, src in ipairs({ 1, 2 }) do
        S.roster[src] = { src = src, name = 'P' .. src, matchId = 1, squadId = 'sq1',
                          state = env.BR.PlayerState.ALIVE, hp = 100.0, armour = 0.0,
                          kills = 0, ped = 9000 + src }
    end

    S.env = env
    --- A client's death report, delivered exactly as FiveM delivers one.
    function S.died(src, data)
        env.source = src
        for _, fn in ipairs(handlers[env.BR.Net.PLAYER_DIED] or {}) do fn(data) end
    end
    --- Any client event, from any player, delivered the way FiveM delivers one:
    --- `source` set on the environment and then the handlers run. The revive
    --- handshake is two events from a player who is not the subject, so PLAYER_DIED
    --- on its own stopped being enough.
    function S.fire(event, src, data)
        env.source = src
        for _, fn in ipairs(handlers[event] or {}) do fn(data) end
    end
    --- One scheduler pass: combat.deathcheck and the bleed tick really run.
    function S.tick(nowMs)
        S.now = nowMs
        env.BR.Sched.step(nowMs)
    end
    return S
end

describe('dbno.fall.server')
do
    -- THE ASYMMETRY, WHICH IS THE WHOLE BUG. There are exactly two paths from
    -- "this ped reads dead" to `BR.Combat.defeat`, and `defeat` on a DBNO entry
    -- can only ever eliminate -- `canBeDowned` requires ALIVE, so the knock
    -- branch is unreachable and the fall-through is `eliminate`.
    --
    --   * the SERVER's own health sampler (`combat.deathcheck`), which ef501ef
    --     taught to decline a downed entry;
    --   * the CLIENT's death report (`BR.Net.PLAYER_DIED`), which it did not.
    --
    -- The reason ef501ef gave for the first applies word for word to the
    -- second: a downed player's ped is not evidence about them, because their
    -- health IS the bleed clock. The engine kills that ped down paths the
    -- server never took over -- a fall, a fire, drowning, a car -- and a client
    -- that faithfully reports what its engine did is not lying, it is
    -- describing the very death the knock was the answer to.
    local S = newServer()
    local PS = S.env.BR.PlayerState

    S.died(1, { cause = 'fall' })
    ok(S.roster[1].state == PS.DBNO,
        'a fall knocks a squad player down',
        tostring(S.roster[1].state))

    -- THE HEADLINE. The engine finishes killing the ped a beat after the knock
    -- and the watcher reports it a second time -- which is not a cheat, not a
    -- duplicate and not avoidable from the client: `gamerules.death` re-arms
    -- the moment the ped stops reading dead, and a downed ped that has been
    -- resurrected does exactly that.
    S.died(1, { cause = 'fall' })
    ok(S.roster[1].state == PS.DBNO,
        'AND A SECOND REPORT DOES NOT FINISH THEM -- the ped is not evidence '
        .. 'about a player whose health is a bleed clock',
        tostring(S.roster[1].state))
    ok(S.roster[1].placement == nil,
        'with nothing banked: a knock is not a finishing position',
        tostring(S.roster[1].placement))

    -- ...AND THE TWO PATHS NOW AGREE. The server's own sampler has declined a
    -- downed entry since ef501ef; this is the same reading, arriving by the
    -- other door, getting the same answer.
    S.roster[1].engineHp = 0
    S.tick(1000)
    S.tick(2000)
    ok(S.roster[1].state == PS.DBNO,
        'and the server-observed check still declines the same corpse',
        tostring(S.roster[1].state))

    -- DECLINING IS NOT IMMORTALITY, said with the clock rather than with a
    -- promise. The bleed clock owns this ending and still delivers it.
    S.tick(2000 + S.env.BR.Config.Match.dbnoBleedBase * 1000 + 500)
    ok(S.roster[1].state == PS.DEAD,
        'the bleed clock still finishes them on time',
        tostring(S.roster[1].state))

    -- ...and a report from somebody who is genuinely ALIVE still works, which
    -- is the thing a lazy guard would trade away.
    ok(S.roster[2].state == PS.ALIVE, 'the mate is still standing')
    S.died(2, { cause = 'fall' })
    ok(S.roster[2].state == PS.DEAD,
        'a live player with no standing mate left is still eliminated by their '
        .. 'own report',
        tostring(S.roster[2].state))
end

-- ---------------------------------------------------------------------------
-- The client: the real client/dbno.lua and client/gamerules.lua, on real
-- coroutines, wired to the real server above.
-- ---------------------------------------------------------------------------

--- Boot one FiveM client whose ped can be killed by the world.
--- @param settleMs integer  how long GTA takes to admit the ped is dead
--- @param streamMs integer  how long the crawl dictionary takes to arrive
local function newClient(settleMs, streamMs)
    local env = newSandbox()
    local C = { now = 0, reports = 0, resurrects = 0, knockdowns = 0 }

    env.GetGameTimer = function() return C.now end
    env.print = function() end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetHashKey = function(s) return #tostring(s) end
    env.PlayerId = function() return 0 end
    env.GetPlayerServerId = function() return 1 end

    loadInto(env, SANDBOX_LIB)

    local FLOOR = env.BR.Config.Match.healthFloor
    local MAXHP = env.BR.Config.Match.maxHealth

    -- THE PED. `hp` is the number, `dying` is the task and `dead` is the flag,
    -- and they are three different things on purpose -- see the header.
    local P = { hp = MAXHP, dying = false, dead = false, since = 0,
                x = 0.0, y = 0.0, z = 30.0, h = 0.0, anim = nil, ragdoll = false }
    C.ped = P

    --- One engine frame: the death flag catches up (rule 2), and any task
    --- asked for during the LAST script tick becomes the ped's actual pose.
    ---
    --- RULE 5, AND IT IS THE WHOLE OF THE SECOND PLAYTEST ITEM. TaskPlayAnim
    --- does not pose a ped -- it queues a task, and the engine evaluates the
    --- task tree AFTER the script tick that asked. Until then the ped renders
    --- whatever it currently has, which after a resurrection is a standing
    --- idle. A rig that applies the pose inside TaskPlayAnim is asserting the
    --- thing client/dbno.lua's old note assumed and the owner disproved by
    --- looking at it: "the ped briefly stands between the moment of dying,
    --- reviving, and going to the emote we chose" (owner, 2026-08-18).
    local function pedFrame()
        if P.pending then P.anim, P.pending = P.pending, nil end
        if P.dying and not P.dead and (C.now - P.since) >= settleMs then
            P.dead = true
        end
    end

    -- A REAL VECTOR, because dbno.lua measures with `#(a - b)`.
    local V = {}
    V.__index = V
    V.__sub = function(a, b)
        return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, V)
    end
    V.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
    local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end

    env.PlayerPedId      = function() return 1 end
    env.DoesEntityExist  = function() return true end
    env.GetEntityCoords  = function() return vec(P.x, P.y, P.z) end
    env.GetEntityHeading = function() return P.h end
    env.SetEntityHeading = function(_, h) P.h = h end
    env.GetPedBoneCoords = function() return vec(P.x, P.y, P.z + 0.3) end
    env.GetEntityHealth  = function() return P.dead and 0 or P.hp end
    env.IsEntityDead     = function() return P.dead end
    -- GTA's own threshold, which is what `healthFloor` was chosen to be: a ped
    -- at or under it is on its way out whether or not the flag has caught up.
    env.IsPedFatallyInjured = function() return P.dead or P.hp <= FLOOR end
    env.SetEntityHealth = function(_, v)
        -- Rule 3: a settled corpse ignores the write, and writing health never
        -- cancels a death task that is already running.
        if P.dead then return end
        P.hp = v
        if v <= FLOOR and not P.dying then P.dying, P.since = true, C.now end
    end
    env.NetworkResurrectLocalPlayer = function()
        P.dead, P.dying, P.hp = false, false, MAXHP     -- rule 4
        C.resurrects = C.resurrects + 1
    end
    env.ClearPedTasksImmediately = function()
        if not P.dead then P.dying = false end
        P.anim, P.pending = nil, nil
    end
    env.ClearPedTasks    = function() P.anim, P.pending = nil, nil end
    env.SetPedArmour     = function() end
    env.GetPedArmour     = function() return 0 end
    env.RemoveAllPedWeapons = function() end
    env.SetCurrentPedWeapon = function() end
    env.SetPedCanRagdoll = function() end
    env.IsPedRagdoll     = function() return P.ragdoll end
    env.IsEntityInAir    = function() return false end
    env.ResetPedMovementClipset = function() end
    env.SetPedMoveRateOverride  = function() end
    env.SetPedRelationshipGroupHash = function() end
    env.SetEntityLocallyInvisible   = function() end
    env.SetEntityCoordsNoOffset = function(_, x, y, z) P.x, P.y, P.z = x, y, z end
    env.DisableControlAction    = function() end
    env.GetDisabledControlNormal = function() return 0.0 end
    env.GetControlNormal = function() return 0.0 end
    env.GetFrameTime     = function() return 0.016 end
    env.StartShapeTestRay = function() return 1 end
    env.GetShapeTestResult = function() return 2, false, vec(0.0, 0.0, 0.0) end
    env.GetPedSourceOfDeath = function() return 0 end
    env.GetPedCauseOfDeath  = function() return 0 end
    env.NetworkGetNetworkIdFromEntity = function() return 0 end
    env.GetGamePool = function() return {} end

    -- STREAMING AS A COST, NOT A FLAG. Only the dictionary the owner chose in
    -- game exists, and it is not in memory until something asks -- which is
    -- what puts a yield between the knock arriving and the ped being touched.
    local reqAt = nil
    env.DoesAnimDictExist = function(d) return d == 'move_injured_ground' end
    env.HasAnimDictLoaded = function(d)
        return d == 'move_injured_ground' and reqAt ~= nil
           and (C.now - reqAt) >= streamMs
    end
    env.RequestAnimDict = function(d)
        if d == 'move_injured_ground' and not reqAt then reqAt = C.now end
    end
    env.TaskPlayAnim = function(_, d, a)
        if P.dead then return end       -- a corpse takes no animation
        P.pending = d .. '/' .. a       -- ...and a live one takes it NEXT frame
    end
    env.IsEntityPlayingAnim = function() return P.anim ~= nil end
    env.SetEntityAnimSpeed  = function() end

    env.CreateCamWithParams = function() return 700 end
    env.DoesCamExist  = function() return true end
    env.DestroyCam    = function() end
    env.SetCamActive  = function() end
    env.RenderScriptCams = function() end
    env.SetCamCoord   = function() end
    env.PointCamAtCoord = function() end

    local handlers = {}
    env.AddEventHandler = function(n, fn)
        handlers[n] = handlers[n] or {}
        handlers[n][#handlers[n] + 1] = fn
    end
    env.RegisterNetEvent = function() end
    env.RegisterCommand  = function() end
    env.TriggerEvent = function(n, ...)
        for _, fn in ipairs(handlers[n] or {}) do fn(...) end
    end
    C.toServer = {}
    env.TriggerServerEvent = function(n, d)
        C.toServer[#C.toServer + 1] = { at = C.now, event = n, data = d }
        if n == env.BR.Net.PLAYER_DIED then C.reports = C.reports + 1 end
    end

    -- THREADS ARE MODELLED, NOT MOCKED. This is the whole reason the block
    -- exists: `enterDowned` does its work inside a thread that yields, and a
    -- stub that runs the thunk on the spot removes the only interval in which
    -- anything can go wrong.
    local threads = {}
    env.Citizen = {
        CreateThread = function(fn)
            threads[#threads + 1] = { co = coroutine.create(fn), wake = C.now + 16 }
        end,
        Wait = function(ms) coroutine.yield(ms or 0) end,
        SetTimeout = function() end,
    }

    loadInto(env, { 'br_core/client/main.lua' })

    env.BR.State.me = { src = 1, state = env.BR.PlayerState.ALIVE, squadId = 'sq1' }
    env.BR.State.roster = {}
    env.BR.Sfx  = { play = function() end }
    env.BR.Dui  = { page = function(n) return { name = n } end,
                    send = function() end, drawWorld = function() end,
                    drawScreen = function() end, drawOnEntity = function() end,
                    ready = function() return true end }
    env.BR.Native = env.BR.Native or {}
    env.BR.Native.knockdown = function()
        C.knockdowns = C.knockdowns + 1
        P.ragdoll = true
    end
    env.BR.Native.setDisplayHealth = function(hp)
        env.SetEntityHealth(1, env.BR.ToEngineHp(hp))
    end
    -- The wash a revive performs (owner, 2026-08-28: "any time revive is
    -- processed, please clean the ped"). A no-op here: this harness is about the
    -- crawl, and WHEN the wash is asked for is driven in tools/test_client.lua.
    env.BR.Native.cleanPed = function() end
    env.BR.Native.keyLabelForCommand = function() return 'E' end
    env.BR.Native.applyGameRules = function() end
    env.BR.Native.ALLY_GROUP = 1
    env.BR.Keys  = { isHeld = function() return false end, on = function() end }
    env.BR.Loot  = { suppress = function() end }
    env.BR.Squadmates = { headAnchor = function() return P.x, P.y, P.z + 0.3 end,
                          pedOf = function() return 0 end }

    loadInto(env, { 'br_core/client/dbno.lua', 'br_core/client/gamerules.lua' })

    -- The REAL loop threads, on the REAL intervals. `BR.Loop.step` running
    -- inside a coroutine is not a detail: `dbno.controls` calls `playCrawl`,
    -- which can reach the streaming wait, and where that yield lands is part
    -- of what is being tested.
    env.BR.Loop.start()

    C.env = env
    C.handlers = handlers

    --- Advance the client by `ms`, one 16ms frame at a time.
    function C.pump(ms, onFrame)
        local target = C.now + ms
        while C.now < target do
            C.now = math.min(C.now + 16, target)
            pedFrame()
            if onFrame then onFrame(C.now) end
            for i = #threads, 1, -1 do
                local t = threads[i]
                if C.now >= t.wake and coroutine.status(t.co) == 'suspended' then
                    local okr, waitMs = coroutine.resume(t.co)
                    if not okr then
                        io.write('\27[31mclient thread error\27[0m ',
                                 tostring(waitMs), '\n')
                    end
                    if coroutine.status(t.co) == 'dead' then
                        table.remove(threads, i)
                    else
                        t.wake = C.now + (tonumber(waitMs) or 0)
                    end
                end
            end
        end
    end

    --- The ground arrives. GTA applies the damage locally, before the server
    --- has seen anything -- `server/damage.lua` reads WEAPON_FALL as
    --- environmental and returns, so nothing clamps it.
    function C.fall()
        P.hp, P.dying, P.since = 0, true, C.now
    end

    return C
end

describe('dbno.fall.client')
do
    -- THE MATRIX, and it is a matrix rather than a number because the fix has
    -- to be timing-independent. Every cell is a legitimate configuration of
    -- the same two unknowns: how long GTA takes to admit a ped is dead, and
    -- how long the round trip to the server is. A fix that works in some cells
    -- and not others is the bug, not the fix -- that is what shipped twice.
    local SETTLES = { 32, 96, 200, 320 }
    local RTTS    = { 30, 90 }
    local STREAMS = { 0, 250 }    -- 0 = the crawl clip is already in memory

    local worstState, worstWhere = nil, nil
    local corpses, corpseWhere = 0, nil
    local doubles, doubleWhere = 0, nil
    local unposed, unposedWhere = 0, nil
    local cells = 0

    for _, settle in ipairs(SETTLES) do
    for _, rtt in ipairs(RTTS) do
    for _, stream in ipairs(STREAMS) do
        cells = cells + 1
        local where = ('settle %dms, round trip %dms, streaming %dms')
            :format(settle, rtt, stream)

        local SRV = newServer()
        local CLI = newClient(settle, stream)
        local PS  = CLI.env.BR.PlayerState

        -- The wire. FIFO in both directions, because the order combat.knock
        -- writes -- DBNO_SET and then HEALTH_SYNC -- is load-bearing and says
        -- so in its own comment.
        local wire = {}
        local function drain(now)
            SRV.tick(now)
            for i = 1, #SRV.out do
                local m = SRV.out[i]
                wire[#wire + 1] = { at = now + rtt, event = m.event,
                                    target = m.target, payload = m.payload }
            end
            for i = #SRV.out, 1, -1 do SRV.out[i] = nil end

            -- ADDRESSED, NOT BROADCAST. This used to hand every message to the
            -- one client in the rig whoever it was for, which was invisible
            -- while the only sender was TriggerClientEvent(.., src, ..) to the
            -- player under test -- and stopped being invisible the moment
            -- combat.lua started addressing a player's SQUADMATES as well. A
            -- harness that delivers somebody else's post is not a network.
            while wire[1] and now >= wire[1].at do
                local m = table.remove(wire, 1)
                CLI.env.BR.State.me.state = SRV.roster[1].state
                if m.target == 1 or m.target == -1 then
                    CLI.env.TriggerEvent(m.event, m.payload)
                end
            end

            for i = 1, #CLI.toServer do
                local m = CLI.toServer[i]
                if now >= m.at + rtt then
                    -- The server samples the ped's health the same way
                    -- roster.positions does, off the entity, not off a report.
                    SRV.roster[1].engineHp = CLI.env.GetEntityHealth(1)
                    SRV.died(1, m.data)
                    CLI.toServer[i] = nil
                end
            end
            local kept = {}
            for i = 1, #CLI.toServer do
                if CLI.toServer[i] then kept[#kept + 1] = CLI.toServer[i] end
            end
            CLI.toServer = kept
        end

        -- SIX SECONDS ON THEIR FEET FIRST, because that is what a match is. A
        -- player falls minutes into a round, not on the frame the resource
        -- started -- and that interval is exactly what dbno.lua now uses to get
        -- the downed pose into memory before anybody needs it. Pumping straight
        -- to the fall would model a knock the game cannot produce, and would
        -- hide the warm-up rather than test it.
        CLI.pump(6000, drain)
        CLI.fall()
        CLI.pump(4000, drain)

        if SRV.roster[1].state ~= PS.DBNO then
            worstState, worstWhere = SRV.roster[1].state, where
        end
        if CLI.ped.dead then
            corpses, corpseWhere = corpses + 1, where
        end
        if CLI.reports > 1 then
            doubles, doubleWhere = doubles + 1, where
        end
        if CLI.ped.anim == nil then
            unposed, unposedWhere = unposed + 1, where
        end
    end
    end
    end

    -- THE HEADLINE, and the owner's sentence turned into an assertion.
    ok(worstState == nil,
        'A FALL IS A KNOCK IN EVERY TIMING -- the squad panel never goes '
        .. 'straight to OUT',
        worstWhere and ('state %s at %s'):format(tostring(worstState), worstWhere)
                   or nil)

    -- WHY IT WENT OUT, which is the part a state assertion alone would let
    -- somebody fix in the wrong place. `defeat()` on a DBNO entry can only
    -- eliminate, and the client sends a second report the moment its ped
    -- finishes a death the knock was supposed to have undone.
    ok(doubles == 0,
        'and the client never has to report the same death twice: the body it '
        .. 'was told to stand up is standing',
        doubleWhere and ('%d/%d cells reported twice, e.g. %s')
            :format(doubles, cells, doubleWhere) or nil)

    -- ...AND THE BODY IS ACTUALLY BACK. "Their screen reads 0 health and
    -- they're unable to crawl" is the other half of the same report, and a
    -- corpse in the DBNO state satisfies every state assertion above.
    ok(corpses == 0,
        'the ped is ALIVE on the downed floor rather than a corpse wearing the '
        .. 'downed state',
        corpseWhere and ('%d/%d cells left a corpse, e.g. %s')
            :format(corpses, cells, corpseWhere) or nil)

    ok(unposed == 0,
        'and it is playing the crawl, which a dead ped cannot be told to do',
        unposedWhere and ('%d/%d cells never posed, e.g. %s')
            :format(unposed, cells, unposedWhere) or nil)

    -- THE HEALTH IS THE SERVER'S NUMBER, not whatever a resurrection restored.
    -- One last cell, read rather than counted, so the number is in the output.
    local SRV = newServer()
    local CLI = newClient(200, 0)
    local wire = {}
    local function drain(now)
        SRV.tick(now)
        for i = 1, #SRV.out do
            wire[#wire + 1] = { at = now + 30, event = SRV.out[i].event,
                                target = SRV.out[i].target,
                                payload = SRV.out[i].payload }
        end
        for i = #SRV.out, 1, -1 do SRV.out[i] = nil end
        while wire[1] and now >= wire[1].at do
            local m = table.remove(wire, 1)
            CLI.env.BR.State.me.state = SRV.roster[1].state
            if m.target == 1 or m.target == -1 then
                CLI.env.TriggerEvent(m.event, m.payload)
            end
        end
        for i = 1, #CLI.toServer do
            local m = CLI.toServer[i]
            if m and now >= m.at + 30 then
                SRV.roster[1].engineHp = CLI.env.GetEntityHealth(1)
                SRV.died(1, m.data)
                CLI.toServer[i] = false
            end
        end
    end
    CLI.pump(6000, drain)
    CLI.fall()
    CLI.pump(4000, drain)

    local floorHp = CLI.env.BR.ToEngineHp(CLI.env.BR.Config.Match.dbnoHp)
    ok(CLI.env.GetEntityHealth(1) == floorHp,
        'and it is left on the downed floor the server named, not on whatever '
        .. 'the resurrection restored',
        ('engine health %s, expected %s')
            :format(tostring(CLI.env.GetEntityHealth(1)), tostring(floorHp)))
end

-- ==========================================================================
-- THE DOWNED MATE'S CLOCK, ON THE SQUAD BEACON AND NOWHERE ELSE.
-- ==========================================================================
--
-- The panel half shipped in b944039 and has rendered nothing since, because no
-- Lua ever sent the field. The interesting part of this feature is not the
-- value, it is the AUDIENCE, so that is what is asserted: a bleed-out deadline
-- is a countdown to when it is safe to stop watching a body, and roster.lua's
-- PUBLIC_FIELDS -- the obvious place to add it -- is broadcast to every client
-- in the match, enemies included.

describe('dbno.bleedEndsAt')
do
    local env = newSandbox()
    local now, roster, out = 0, {}, {}

    env.GetGameTimer = function() return now end
    env.print = function() end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetPlayerName = function(s) return 'P' .. tostring(s) end
    env.GetPlayers = function() return {} end
    env.GetHashKey = function(s) return #tostring(s) end
    env.RegisterNetEvent = function() end
    env.RegisterCommand = function() end
    env.AddEventHandler = function() end
    env.TriggerEvent = function() end
    env.TriggerClientEvent = function(ev, target, payload)
        out[#out + 1] = { event = ev, target = target, payload = payload }
    end
    env.Citizen = { CreateThread = function() end, Wait = function() end,
                    SetTimeout = function() end }

    loadInto(env, SANDBOX_LIB)

    env.BR.Roster = {
        get = function(s) return roster[s] end,
        each = function(pred, fn)
            for src, e in pairs(roster) do
                if (pred == nil or pred(e)) and fn then fn(src, e) end
            end
        end,
        clearFields = function() end,
        setMatch = function() end,
        setState = function() end,
    }
    env.BR.Server = {
        devMode = false, matches = {}, parties = {}, roster = roster,
        isInMatch = function(st)
            return st == env.BR.PlayerState.ALIVE or st == env.BR.PlayerState.BUS
                or st == env.BR.PlayerState.FREEFALL or st == env.BR.PlayerState.GLIDE
                or st == env.BR.PlayerState.DBNO or st == env.BR.PlayerState.WARMUP
        end,
        notify = function() end,
    }
    env.BR.Broadcast = { delta = function() end }
    env.BR.Bus = { sendPreview = function() end }
    env.BR.Inv = { reset = function() end }

    loadInto(env, { 'br_core/server/party.lua' })

    env.BR.Server.matches[1] = { id = 1, state = env.BR.MatchState.PLAYING,
                                 mode = env.BR.Mode.SQUAD.key, players = { 1, 2 },
                                 startedAt = 0 }
    local PS = env.BR.PlayerState
    for _, src in ipairs({ 1, 2 }) do
        roster[src] = { src = src, name = 'P' .. src, matchId = 1, squadId = 'sq1',
                        state = PS.ALIVE, pos = { x = src * 1.0, y = 0.0, z = 30.0 } }
    end

    --- One beacon pass, and the member record it produced for `src`.
    local function beaconFor(src)
        out = {}
        now = now + 1000
        env.BR.Sched.step(now)
        for _, m in ipairs(out) do
            if m.event == env.BR.Net.SQUAD_POS then
                for _, member in ipairs(m.payload) do
                    if member.src == src then return member end
                end
            end
        end
        return nil
    end

    local standing = beaconFor(1)
    ok(standing ~= nil, 'a squad member is beaconed to their squad')
    ok(standing and standing.bleedEndsAt == nil,
        'a player on their feet carries no deadline',
        standing and tostring(standing.bleedEndsAt) or 'no member at all')

    -- KNOCKED. The deadline is the raw server clock, unconverted -- the same
    -- number the downed player's own DBNO envelope already carries, so both
    -- ends of one clock reach the client in one set of units.
    roster[1].state = PS.DBNO
    roster[1].dbnoUntil = now + 41000

    local downed = beaconFor(1)
    ok(downed ~= nil,
        'a DOWNED mate is still beaconed -- visibleStates already covers them')
    ok(downed and downed.bleedEndsAt == roster[1].dbnoUntil,
        'and now carries the bleed deadline, raw and unconverted',
        downed and ('%s, entry holds %s')
            :format(tostring(downed.bleedEndsAt), tostring(roster[1].dbnoUntil))
            or 'no member at all')

    -- ...AND IT GOES AWAY AGAIN. `nil` cannot travel in a roster delta, but
    -- this list is rebuilt whole on every push, so leaving the key off IS the
    -- clear -- which is the reason the field lives here rather than there.
    roster[1].state = PS.ALIVE
    local revived = beaconFor(1)
    ok(revived and revived.bleedEndsAt == nil,
        'a revived mate does not keep a stale deadline',
        revived and tostring(revived.bleedEndsAt) or 'no member at all')

    -- THE AUDIENCE, WHICH IS THE POINT. Two guards, because this is the half
    -- that cannot be seen by looking at the panel.
    roster[1].state = PS.DBNO
    beaconFor(1)
    local strangers = 0
    for _, m in ipairs(out) do
        if m.event == env.BR.Net.SQUAD_POS then
            local mate = roster[m.target]
            if not mate or mate.squadId ~= 'sq1' then strangers = strangers + 1 end
        end
    end
    ok(strangers == 0,
        'the deadline reaches the downed player\'s own squad and nobody else',
        ('%d sends went outside the squad'):format(strangers))

    -- AND IT IS NOT ON THE PUBLIC ROSTER, asserted against the real allowlist
    -- rather than by reading it. Adding it there would tell the people who shot
    -- you exactly when to stop watching your body.
    local chunk = loadfile(RES .. 'br_core/server/roster.lua', 't', newSandbox())
    ok(chunk ~= nil, 'server/roster.lua parses')
    local src = io.open(RES .. 'br_core/server/roster.lua', 'r')
    local text = src and src:read('a') or ''
    if src then src:close() end
    local publicList = text:match('local PUBLIC_FIELDS = {(.-)}')
    ok(publicList ~= nil, 'PUBLIC_FIELDS is where it was')
    ok(publicList and not publicList:find('bleedEndsAt', 1, true)
       and not publicList:find('dbnoUntil', 1, true),
        'and the bleed deadline is NOT on it: that list goes to the whole match',
        publicList)
end

-- ==========================================================================
-- A SQUADMATE'S LEVEL, DERIVED FROM XP, ON THE SQUAD BEACON.
-- ==========================================================================
--
-- Owner, 2026-08-22: "We need some way in the squad panel to see the levels of
-- our teammates near their name."
--
-- Two properties carry this feature and neither is visible by looking at the
-- panel. The AUDIENCE: a level was not published to anyone before this, and the
-- obvious home -- roster.lua's PUBLIC_FIELDS -- hands it to every client in the
-- match rather than to the squad the owner asked about. And the SOURCE: the
-- profile row's stored `level` is written at match end and lags the `xp` beside
-- it, so a player who levelled up last game would be shown their old number for
-- the whole of the next one. A Ringmaster commit exists titled "Derive the level
-- from xp, instead of trusting a field that goes stale"; this is that rule
-- applied on this side of the boundary, and asserted rather than commented.

describe('squad.level')
do
    local env = newSandbox()
    local now, roster, out = 0, {}, {}

    env.GetGameTimer = function() return now end
    env.print = function() end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetPlayerName = function(s) return 'P' .. tostring(s) end
    env.GetPlayers = function() return {} end
    env.GetHashKey = function(s) return #tostring(s) end
    env.RegisterNetEvent = function() end
    env.RegisterCommand = function() end
    env.AddEventHandler = function() end
    env.TriggerEvent = function() end
    env.TriggerClientEvent = function(ev, target, payload)
        out[#out + 1] = { event = ev, target = target, payload = payload }
    end
    env.Citizen = { CreateThread = function() end, Wait = function() end,
                    SetTimeout = function() end }

    loadInto(env, SANDBOX_LIB)

    env.BR.Roster = {
        get = function(s) return roster[s] end,
        each = function(pred, fn)
            for src, e in pairs(roster) do
                if (pred == nil or pred(e)) and fn then fn(src, e) end
            end
        end,
        clearFields = function() end,
        setMatch = function() end,
        setState = function() end,
    }
    env.BR.Server = {
        devMode = false, matches = {}, parties = {}, roster = roster,
        isInMatch = function(st)
            return st == env.BR.PlayerState.ALIVE or st == env.BR.PlayerState.BUS
                or st == env.BR.PlayerState.FREEFALL or st == env.BR.PlayerState.GLIDE
                or st == env.BR.PlayerState.DBNO or st == env.BR.PlayerState.WARMUP
        end,
        notify = function() end,
    }
    env.BR.Broadcast = { delta = function() end }
    env.BR.Bus = { sendPreview = function() end }
    env.BR.Inv = { reset = function() end }

    loadInto(env, { 'br_core/server/party.lua' })

    -- THE MARKET IS THE ONLY PLACE LIFETIME XP LIVES on this side, and its
    -- accessor already answers nil for a player whose inventory has not come
    -- back from the database. An absent key here IS that state -- which is why
    -- the "not loaded" case below needs no flag, just a player nobody has set.
    local lifetime = {}
    env.BR.Market = {
        lifetimeXp = function(s) return lifetime[s] end,
    }

    env.BR.Server.matches[1] = { id = 1, state = env.BR.MatchState.PLAYING,
                                 mode = env.BR.Mode.SQUAD.key, players = { 1, 2 },
                                 startedAt = 0 }
    local PS = env.BR.PlayerState
    for _, src in ipairs({ 1, 2 }) do
        roster[src] = { src = src, name = 'P' .. src, matchId = 1, squadId = 'sq1',
                        state = PS.ALIVE, pos = { x = src * 1.0, y = 0.0, z = 30.0 } }
    end

    --- One beacon pass, and the member record it produced for `src`.
    local function beaconFor(src)
        out = {}
        now = now + 1000
        env.BR.Sched.step(now)
        for _, m in ipairs(out) do
            if m.event == env.BR.Net.SQUAD_POS then
                for _, member in ipairs(m.payload) do
                    if member.src == src then return member end
                end
            end
        end
        return nil
    end

    local XP = env.BR.Xp

    -- THE ORDINARY CASE. The xp is placed exactly on level 23's threshold, so
    -- the expected answer is read off the same curve the server uses rather
    -- than hardcoded -- a test that spelled out "23" would have to be edited
    -- every time the curve was retuned, and would then be asserting the edit.
    lifetime[1] = XP.thresholdFor(23)
    local mate = beaconFor(1)
    ok(mate ~= nil, 'a squad member is beaconed to their squad')
    ok(mate and mate.level == 23,
        'and carries the level their lifetime xp puts them on',
        mate and ('level %s for %s xp'):format(tostring(mate.level),
                                               tostring(lifetime[1])) or 'no member')

    -- IT TRACKS THE XP WITH NOTHING RE-STORED. This is the whole of "derived,
    -- not read": no writer ran between these two pushes, and the answer moved.
    lifetime[1] = XP.thresholdFor(24)
    local levelled = beaconFor(1)
    ok(levelled and levelled.level == 24,
        'and follows the xp up a level with no field anywhere rewritten',
        levelled and tostring(levelled.level) or 'no member')

    -- ...AND A STALE STORED LEVEL CANNOT WIN. The profile row really does carry
    -- one, written at match end; if the beacon ever starts reading a field
    -- instead of the curve, this is the assertion that catches it.
    roster[1].level = 99
    local stale = beaconFor(1)
    ok(stale and stale.level == 24,
        'a stale `level` sitting on the roster entry is ignored, not trusted',
        stale and tostring(stale.level) or 'no member')
    roster[1].level = nil

    -- ZERO XP IS A LEVEL, NOT AN ABSENCE. In Lua 0 is truthy, and the bug this
    -- pins is the other spelling: a guard written as `xp and xp > 0` drops the
    -- brand-new account entirely, so the one player whose level is least
    -- interesting is the one whose row silently loses its number.
    lifetime[1] = 0
    local fresh = beaconFor(1)
    ok(fresh and fresh.level == 1,
        'a player with 0 lifetime xp is level 1 -- present, not omitted',
        fresh and tostring(fresh.level) or 'no member')

    -- NOT LOADED IS ABSENT, AND ABSENT IS NOT LEVEL 1. These are different
    -- facts and the panel draws them differently: a number, or nothing at all.
    -- Collapsing them would paint a confident `1` over every squadmate for the
    -- length of the database round trip and then correct itself.
    lifetime[1] = nil
    local unknown = beaconFor(1)
    ok(unknown ~= nil, 'a mate whose profile has not loaded is still beaconed')
    ok(unknown and unknown.level == nil,
        'but carries no level at all -- not 0, and not a placeholder 1',
        unknown and tostring(unknown.level) or 'no member')

    -- THE WHOLE RESOURCE CAN BE MISSING. br_core boots without a market on a
    -- server whose database is down, and a beacon that threw there would take
    -- the squad blips and the bleed clock down with it.
    local market = env.BR.Market
    env.BR.Market = nil
    local nomarket = beaconFor(1)
    ok(nomarket ~= nil and nomarket.level == nil,
        'with no market resource at all the beacon still goes out, levelless',
        nomarket and tostring(nomarket.level) or 'no member -- the push threw')
    env.BR.Market = market

    -- THE AUDIENCE, WHICH IS THE POINT. The owner asked for his TEAMMATES'
    -- levels; this asserts that is who gets them.
    lifetime[1] = XP.thresholdFor(23)
    beaconFor(1)
    local strangers = 0
    for _, m in ipairs(out) do
        if m.event == env.BR.Net.SQUAD_POS then
            local mt = roster[m.target]
            if not mt or mt.squadId ~= 'sq1' then strangers = strangers + 1 end
        end
    end
    ok(strangers == 0,
        'the level reaches that player\'s own squad and nobody else',
        ('%d sends went outside the squad'):format(strangers))

    -- AND IT IS NOT ON THE PUBLIC ROSTER, asserted against the real allowlist.
    -- A level is not positional and reveals nothing tactical -- but the test
    -- that list applies is not "is this harmless", it is "does the whole lobby
    -- need it", and the answer here is no.
    local src = io.open(RES .. 'br_core/server/roster.lua', 'r')
    local text = src and src:read('a') or ''
    if src then src:close() end
    local publicList = text:match('local PUBLIC_FIELDS = {(.-)}')
    ok(publicList ~= nil, 'PUBLIC_FIELDS is where it was')
    ok(publicList and not publicList:find('level', 1, true)
       and not publicList:find('xp', 1, true),
        'and the level is NOT on it: the squad was asked for, not the match',
        publicList)
end

-- ==========================================================================
-- THE REVIVE HOLD IS ONE NUMBER.
-- ==========================================================================

describe('dbno.reviveTime')
do
    local M = BR.Config.Match

    ok(M.dbnoReviveTime == 2.8,
        'the hold is 2.8s -- 65% off the 8.0 that shipped (owner, 2026-08-17)',
        tostring(M.dbnoReviveTime))

    -- THE RING FOLLOWS THE RULE RATHER THAN AGREEING WITH IT.
    --
    -- A hold duration is the classic thing to end up hardcoded twice: once for
    -- what the server measures and once for the picture that draws it. Both
    -- ends are read from the real files here, because "they happen to be equal
    -- today" is exactly the state a second constant starts in.
    local function slurp(path)
        local f = io.open(path, 'r')
        if not f then return '' end
        local s = f:read('a')
        f:close()
        return s
    end

    local client = slurp(RES .. 'br_core/client/dbno.lua')
    ok(client:find('M.dbnoReviveTime', 1, true) ~= nil,
        'the prompt\'s holdMs is computed from dbnoReviveTime')

    local server = slurp(RES .. 'br_core/server/combat.lua')
    ok(server:find('M.dbnoReviveTime', 1, true) ~= nil,
        'and so is the progress the server reports')

    -- The page takes its animation-duration from the message and from nothing
    -- else -- there is no second duration in the DUI to drift out of step.
    local page = slurp(RES .. 'br_ui/dui/prompt.html')
    ok(page:find('animationDuration = (ms', 1, true) ~= nil,
        'and the ring\'s animation-duration comes from that message',
        'br_ui/dui/prompt.html no longer sets animationDuration from its argument')

    -- ...AND THE SERVER REALLY MEASURES AGAINST IT. Read off the live code
    -- path rather than off the constant: pushDbno reports revivePct, and a
    -- hold of exactly half the configured time has to read as half.
    local S = newServer()
    local PS = S.env.BR.PlayerState
    S.died(1, { cause = 'fall' })
    ok(S.roster[1].state == PS.DBNO, 'a mate is down to be picked up')

    S.now = 10000
    S.roster[1].reviverSrc = 2
    S.roster[1].reviveFrom = S.now - (M.dbnoReviveTime * 1000.0) / 2.0

    local out = nil
    for i = #S.out, 1, -1 do S.out[i] = nil end
    S.env.BR.Combat.pushDbno(1)
    for _, m in ipairs(S.out) do
        if m.event == S.env.BR.Net.DBNO_SET and m.target == 1 then out = m.payload end
    end
    ok(out ~= nil and math.abs(out.revivePct - 50.0) < 0.001,
        'half the configured hold reads as half a ring, whatever the number is',
        out and tostring(out.revivePct) or 'no DBNO_SET at all')
end

-- ==========================================================================
-- THE CLOCK STOPS DURING A REVIVE, ON BOTH SIDES OF THE WIRE.
-- ==========================================================================
--
-- "While actively reviving, the DBNO timer does not stop for some reason."
-- (owner, 2026-08-18.)
--
-- IT STOPPED. IT HAD ALWAYS STOPPED. server/combat.lua's stepDowned pushes
-- `dbnoUntil` forward by the length of every tick a hold is progressing through,
-- and that line has been correct and reachable the whole time -- which is
-- exactly why three readings of the server file could not find this.
--
-- THE NUMBER THE PLAYER WATCHES IS A DIFFERENT NUMBER. It is `bleedEndsAt`,
-- carried on DBNO_SET, held by client/dbno.lua and handed to the interface,
-- where ui-src/src/hud/DbnoOverlay.tsx counts down from it on
-- requestAnimationFrame -- continuously, on the browser's own clock, against
-- whatever deadline it was last given. DBNO_SET is sent on EDGES. The last edge
-- before a hold is the hold registering. So for the whole of a revive the
-- browser counted down from a deadline the server had already moved, four times
-- a second, and never mentioned.
--
-- THIS IS THE PROJECT'S SIGNATURE FAILURE AND THIS BLOCK IS SHAPED AGAINST IT:
-- two representations of one clock, each internally consistent, with nothing
-- anywhere asserting they agree. So the assertion is the agreement itself --
-- the client's deadline against the server's entry, read off both live objects
-- rather than off either one's idea of the other.
describe('dbno.revive.clock')
do
    local SRV = newServer()
    local CLI = newClient(96, 0)
    local env = CLI.env
    local PS  = env.BR.PlayerState
    local rtt = 60

    -- WHAT THE INTERFACE WOULD BE COUNTING DOWN FROM. Captured off the real
    -- envelope client/dbno.lua pushes at br_ui, because that is the only place
    -- the player's number exists -- reading the client's own local would be
    -- reading the wrong side of the bridge.
    local shown = nil
    env.AddEventHandler('br:ui:sendLocal', function(kind, payload)
        if kind == env.BR.Nui.DBNO and type(payload) == 'table'
           and payload.downed then
            shown = payload.bleedEndsAt
        end
    end)

    -- The server samples positions itself; a reviver has to be within
    -- dbnoReviveDist + dbnoReviveSlack of the body or reviveAllowed refuses.
    SRV.roster[1].pos = { x = 0.0, y = 0.0, z = 30.0 }
    SRV.roster[2].pos = { x = 0.5, y = 0.0, z = 30.0 }

    local holding, lastAsk = false, -10000
    local wire = {}
    local function drain(now)
        -- THE REVIVER'S CLIENT, REDUCED TO THE ONE THING IT DOES: re-assert the
        -- hold every ASK_EVERY_MS. The server expires a revive it has not heard
        -- about in dbnoReviveBeatMs, so a rig that asked once would be testing
        -- the expiry instead of the pause.
        if holding and now - lastAsk >= 250 then
            lastAsk = now
            SRV.fire(SRV.env.BR.Net.REVIVE_START, 2, { target = 1 })
        end
        SRV.tick(now)
        for i = 1, #SRV.out do
            local m = SRV.out[i]
            wire[#wire + 1] = { at = now + rtt, event = m.event,
                                target = m.target, payload = m.payload }
        end
        for i = #SRV.out, 1, -1 do SRV.out[i] = nil end
        while wire[1] and now >= wire[1].at do
            local m = table.remove(wire, 1)
            env.BR.State.me.state = SRV.roster[1].state
            if m.target == 1 or m.target == -1 then
                env.TriggerEvent(m.event, m.payload)
            end
        end
        for i = 1, #CLI.toServer do
            local m = CLI.toServer[i]
            if m and now >= m.at + rtt then
                SRV.roster[1].engineHp = env.GetEntityHealth(1)
                SRV.died(1, m.data)
                CLI.toServer[i] = false
            end
        end
    end

    CLI.pump(6000, drain)
    CLI.fall()
    CLI.pump(2000, drain)

    ok(SRV.roster[1].state == PS.DBNO, 'the player is down and bleeding',
        tostring(SRV.roster[1].state))
    ok(shown ~= nil and shown == SRV.roster[1].dbnoUntil,
        'and the deadline the interface would count down from is the server\'s '
        .. 'own, to the millisecond',
        ('interface %s, server %s')
            :format(tostring(shown), tostring(SRV.roster[1].dbnoUntil)))

    --- What DbnoOverlay would be putting on screen right now, in ms.
    local function remaining() return (shown or 0) - CLI.now end

    -- ------------------------------------------------- the control first ---
    -- IT HAS TO BE ABLE TO GO DOWN. An assertion that a number did not move is
    -- satisfied by a number that never moves, which is precisely how a fix that
    -- froze the clock outright would pass the headline below and lose the mode.
    local beforeIdle = remaining()
    CLI.pump(3000, drain)
    local idleDrop = beforeIdle - remaining()
    ok(idleDrop >= 2800 and idleDrop <= 3200,
        'with nobody on them the timer runs, second for second',
        ('%dms lost over 3000ms of lying there'):format(idleDrop))

    -- ------------------------------------------------------- the headline ---
    holding = true
    local heldFrom      = CLI.now
    local beforeHold    = remaining()
    local serverBefore  = SRV.roster[1].dbnoUntil
    local worstDip      = 0

    -- SHORT OF dbnoReviveTime ON PURPOSE. A completed revive clears dbnoUntil
    -- outright, and "the deadline is nil" would satisfy any comparison at all.
    local HOLD_MS = 2000
    local target = CLI.now + HOLD_MS
    while CLI.now < target do
        CLI.pump(64, drain)
        local dip = beforeHold - remaining()
        if dip > worstDip then worstDip = dip end
    end
    holding = false

    ok(SRV.roster[1].reviverSrc == nil or SRV.roster[1].state == PS.DBNO,
        'the hold ran without completing, so there is still a deadline to read',
        tostring(SRV.roster[1].state))

    local serverMoved = (SRV.roster[1].dbnoUntil or 0) - serverBefore
    ok(serverMoved >= HOLD_MS - 300,
        'the server pauses for essentially the whole hold',
        ('deadline moved %dms over a %dms hold'):format(serverMoved, HOLD_MS))

    ok(shown == SRV.roster[1].dbnoUntil,
        'AND THE INTERFACE IS LOOKING AT THAT SAME NUMBER -- the two '
        .. 'representations of one clock are asserted against each other, which '
        .. 'is the thing nothing was doing',
        ('interface %s, server %s')
            :format(tostring(shown), tostring(SRV.roster[1].dbnoUntil)))

    -- THE OWNER'S SENTENCE, IN MILLISECONDS. Before this, the browser counted
    -- down from a deadline nothing was updating, so a two-second hold cost two
    -- seconds of visible clock. What is left is the wire: the client is always
    -- one round trip and up to one 250ms tick behind the pause, and that is a
    -- floor rather than a bug.
    ok(worstDip <= 250 + rtt + 100,
        'SO THE TIMER THE PLAYER SEES STOPS TOO -- it never falls further '
        .. 'behind than one server tick plus the round trip. BEFORE: it fell '
        .. 'by the entire length of the hold',
        ('worst dip %dms over a %dms hold (tick 250 + rtt %d)')
            :format(worstDip, HOLD_MS, rtt))

    -- ...AND IT STARTS AGAIN WHEN THE HAND COMES OFF. A pause that never ends
    -- is immortality, and the bleed clock is the only thing that ends a knock
    -- nobody answers.
    CLI.pump(400, drain)               -- let the release land
    local afterRelease = remaining()
    CLI.pump(3000, drain)
    local resumedDrop = afterRelease - remaining()
    ok(resumedDrop >= 2800 and resumedDrop <= 3200,
        'and it resumes the moment the hold stops: a pause, not a reprieve',
        ('%dms lost over 3000ms after the release'):format(resumedDrop))

    -- --------------------------------------------------------------------
    -- WHERE THE PAUSE STARTS, ON A CLOCK NOTHING ELSE IS DRIVING.
    -- --------------------------------------------------------------------
    --
    -- The end-to-end run above cannot say this and it is worth being explicit
    -- about why, because a suite that pretended otherwise would be measuring
    -- luck. `reviveTickAt` used to be stamped by the FIRST scheduler pass after
    -- the hold registered rather than by the hold registering, so the interval
    -- between the two ran off the clock. That interval is anywhere from zero to
    -- one full 250ms tick depending on where the ask happens to land in the
    -- scheduler's phase -- so end to end it hides inside the tolerance, and in
    -- the rig's own alignment it came out at 32ms.
    --
    -- Driven directly instead: hold at a known instant, tick at a known instant,
    -- and the deadline must have moved by exactly the difference.
    do
        local S = newServer()
        local PS2 = S.env.BR.PlayerState
        S.roster[1].pos = { x = 0.0, y = 0.0, z = 30.0 }
        S.roster[2].pos = { x = 0.5, y = 0.0, z = 30.0 }

        S.tick(10000)
        S.died(1, { cause = 'fall' })
        ok(S.roster[1].state == PS2.DBNO, 'a player is down on the server rig',
            tostring(S.roster[1].state))

        local D0 = S.roster[1].dbnoUntil
        S.fire(S.env.BR.Net.REVIVE_START, 2, { target = 1 })
        ok(S.roster[1].reviverSrc == 2, 'and a mate has hold of them',
            tostring(S.roster[1].reviverSrc))

        -- ONE SCHEDULER PASS, and it is the FIRST one this hold has seen. The
        -- pass at 10000 above is what puts the scheduler on a known phase, so
        -- the next one is exactly a period later and the interval under test --
        -- hold registered at 10000, first look at 10250 -- is the whole 250ms.
        S.tick(10250)
        local moved = (S.roster[1].dbnoUntil or 0) - D0
        ok(moved == 250,
            'THE PAUSE STARTS WHEN THE HOLD REGISTERS, not when the scheduler '
            .. 'next looks -- the first tick pays for the interval before it. '
            .. 'BEFORE: it paid 0 and that quarter second was gone',
            ('the deadline moved %dms over the first 250ms of a hold')
                :format(moved))

        -- ...AND IT IS THE HOLD DOING IT. A downed player nobody is touching
        -- must lose that time, or the fix is immortality with extra steps.
        S.fire(S.env.BR.Net.REVIVE_STOP, 2, nil)
        local D1 = S.roster[1].dbnoUntil
        S.tick(10500)
        ok((S.roster[1].dbnoUntil or 0) == D1,
            'and a released body\'s deadline stops moving again immediately',
            ('moved %dms after the release')
                :format((S.roster[1].dbnoUntil or 0) - D1))
    end
end

-- ==========================================================================
-- TWO MINUTES ON THE FLOOR.
-- ==========================================================================
--
-- Owner, playtest: "The DBNO bleed out timer seems awfully short. We should
-- probably double it at least. It should be 2 minutes minimum."
--
-- The number is asserted, and then the two things that MOVE WITH IT are
-- asserted -- because the failure mode of a config change like this is not a
-- wrong constant, it is three constants that used to describe one rule and now
-- describe three.

describe('dbno.bleed')
do
    local M = BR.Config.Match

    ok(M.dbnoBleedBase >= 120,
        'a first knock lasts at least two minutes (owner, playtest)',
        tostring(M.dbnoBleedBase))

    -- THE ESCALATION IS A SHAPE, and this is what stops the base being raised
    -- on its own. dbnoBleedStep is an absolute number of seconds, so leaving it
    -- at -8 against a 120s base would have turned an 18%-per-knock penalty into
    -- a 7% one: the same three keys, a different rule, and nothing anywhere
    -- would have said so.
    local secondKnockFraction = (M.dbnoBleedBase + M.dbnoBleedStep) / M.dbnoBleedBase
    ok(math.abs(secondKnockFraction - 0.825) < 0.02,
        'and a second knock still costs the same FRACTION it always did (~17.5%)',
        ('%.1f%% of the first'):format(secondKnockFraction * 100.0))
    ok(M.dbnoBleedMin / M.dbnoBleedBase > 0.3
       and M.dbnoBleedMin < M.dbnoBleedBase,
        'and the floor is still a floor, in proportion',
        ('%s of %s'):format(M.dbnoBleedMin, M.dbnoBleedBase))

    -- ...AND SO IS SHOOTING A DOWNED PLAYER. dbnoBleedPerDamage converts damage
    -- into SECONDS, so it is denominated in the number that just tripled. Its
    -- own note in config/match.lua states the design as a ROUND COUNT -- "four
    -- rounds finish it" -- which is the thing that has to survive, and which a
    -- base change silently breaks in the direction of "nobody can ever finish
    -- anybody".
    local rifleRound   = 30.0
    local roundsToKill = M.dbnoBleedBase / (rifleRound * M.dbnoBleedPerDamage)
    ok(roundsToKill >= 3.0 and roundsToKill <= 5.5,
        'and four rifle rounds still finish a fresh knock, whatever the clock is',
        ('%.1f rounds of %.0f damage'):format(roundsToKill, rifleRound))

    -- THE ONE THING THAT DELIBERATELY DID NOT MOVE. attributedKiller expires at
    -- assistWindowMs, and a bleed has always outlived it -- which is the entire
    -- reason `downedBy` exists and does not expire (see BR.Combat.knock). If a
    -- bleed ever became SHORTER than the assist window, that field would become
    -- dead weight and nobody would notice.
    ok(M.dbnoBleedMin * 1000 > M.assistWindowMs,
        'and even the shortest bleed still outlives the assist window, which is '
        .. 'why downedBy exists',
        ('%ds bleed vs %dms window'):format(M.dbnoBleedMin, M.assistWindowMs))

    -- The real ledger, on the real clock: knock, wait the configured time, and
    -- see the player go out -- and NOT go out a beat early.
    local S = newServer()
    local PS = S.env.BR.PlayerState
    S.env.BR.Combat.knock(1, 2)
    ok(S.roster[1].state == PS.DBNO, 'a knock puts them down')

    S.tick(M.dbnoBleedBase * 1000 - 2000)
    ok(S.roster[1].state == PS.DBNO,
        'two seconds before the deadline they are still bleeding',
        tostring(S.roster[1].state))

    S.tick(M.dbnoBleedBase * 1000 + 500)
    ok(S.roster[1].state == PS.DEAD,
        'and the clock still finishes them, on the new number',
        tostring(S.roster[1].state))
end

-- ==========================================================================
-- A HOLD IS A LEVEL. (owner, playtest: "Reviving a player twice doesn't seem
-- to work. I can hold the input, the ring fills up, but then nothing happens.")
-- ==========================================================================
--
-- WHY THIS BLOCK EXISTS IN THIS SHAPE. The ring is a lie, and it is a lie by
-- construction rather than by accident: br_ui/dui/prompt.html starts a ONE-SHOT
-- CSS animation from a single "a hold began, it lasts N ms" message and fills on
-- schedule whatever the server thinks. So the only instrument that can answer
-- "did the revive happen" is the server's own roster, driven by the REAL client
-- over a REAL latency -- which is what this builds. The same reasoning, and the
-- same rig, as dbno.fall.client above.
--
-- THE BUG, once it is written down, is not timing-dependent at all: `holding`
-- was created in exactly ONE place, the key-DOWN listener, and cleared in five.
-- Anything that ended a hold left the player leaning on a key that no longer
-- meant anything. A COMPLETED REVIVE is one of those five, which is why the
-- symptom is "the second one" -- and why no amount of watching the ring could
-- find it.

--- One squadmate's client, standing over a downed mate with the real
--- client/dbno.lua and the real dbno.revive frame loop.
--- @param mySrc integer
--- @param mateSrc integer
--- @param peds table  ped handle -> { x, y, z }; shared with the rig
local function newReviver(mySrc, mateSrc, peds)
    local env = newSandbox()
    local C = { now = 0, toServer = {}, held = false }

    env.GetGameTimer = function() return C.now end
    env.print = function() end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.GetHashKey = function(s) return #tostring(s) end
    env.PlayerId = function() return 0 end
    env.GetPlayerServerId = function() return mySrc end

    loadInto(env, SANDBOX_LIB)

    local V = {}
    V.__index = V
    V.__sub = function(a, b)
        return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, V)
    end
    V.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
    local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
    local function at(p) return peds[p] or peds[5000 + mySrc] end

    env.PlayerPedId = function() return 5000 + mySrc end
    env.DoesEntityExist = function() return true end
    env.GetEntityCoords = function(p) local q = at(p) return vec(q.x, q.y, q.z) end
    env.GetPedBoneCoords = function(p) local q = at(p) return vec(q.x, q.y, q.z + 0.3) end
    env.GetEntityHeading = function() return 0.0 end
    env.SetEntityHeading = function() end
    env.GetEntityHealth = function() return env.BR.Config.Match.maxHealth end
    env.IsEntityDead = function() return false end
    env.IsPedFatallyInjured = function() return false end
    env.SetEntityHealth = function() end
    env.NetworkResurrectLocalPlayer = function() end
    env.ClearPedTasksImmediately = function() end
    env.ClearPedTasks = function() end
    env.SetPedArmour = function() end
    env.GetPedArmour = function() return 0 end
    env.RemoveAllPedWeapons = function() end
    env.SetCurrentPedWeapon = function() end
    env.SetPedCanRagdoll = function() end
    env.IsPedRagdoll = function() return false end
    env.IsEntityInAir = function() return false end
    env.ResetPedMovementClipset = function() end
    env.SetPedMoveRateOverride = function() end
    env.SetEntityCoordsNoOffset = function() end
    -- The cover over the resurrection's standing frame. Present in the rig
    -- because a build WITHOUT it is a real configuration -- client/dbno.lua
    -- guards the call -- and the tests that measure the cover replace this with
    -- a recorder.
    env.SetEntityLocallyInvisible = function() end
    env.DisableControlAction = function() end
    env.GetDisabledControlNormal = function() return 0.0 end
    env.GetControlNormal = function() return 0.0 end
    env.GetFrameTime = function() return 0.016 end
    env.StartShapeTestRay = function() return 1 end
    env.GetShapeTestResult = function() return 2, false, vec(0, 0, 0) end
    env.GetPedSourceOfDeath = function() return 0 end
    env.GetPedCauseOfDeath = function() return 0 end
    env.NetworkGetNetworkIdFromEntity = function() return 0 end
    env.GetGamePool = function() return {} end
    -- TWO DICTIONARIES MATTER ON THIS PED NOW, and only these two exist: the
    -- downed pose this player could end up in themselves, and the CPR clip they
    -- play over a mate (owner, 2026-08-29). Anything else answers "no such
    -- dictionary", which is what makes a typo in either name a failure here
    -- rather than a silent no-op in the game.
    local ANIMS = {
        ['move_injured_ground']    = true,
        ['mini@cpr@char_a@cpr_str'] = true,
    }
    env.DoesAnimDictExist = function(d) return ANIMS[d] == true end
    env.HasAnimDictLoaded = function(d) return ANIMS[d] == true end
    env.RequestAnimDict = function() end

    -- WHAT THIS PED IS PLAYING, BECAUSE THE EMOTE HAS NO OTHER OBSERVABLE.
    -- It sends no message, pushes no envelope and writes no roster field --
    -- the only evidence it exists is a task on a ped, so the rig keeps that
    -- task. A fixture that threw it away could not tell a working emote from
    -- no emote at all, which is the failure mode this project keeps shipping
    -- green suites through.
    --
    -- StopAnimTask IS MODELLED AS THE NATIVE REALLY BEHAVES: it names the
    -- dictionary and the clip, so it only clears the pose if that is what is
    -- running. A stop aimed at the wrong clip therefore leaves the emote up
    -- here, exactly as it would in the game.
    C.anim = nil
    env.TaskPlayAnim = function(_, d, a) C.anim = d .. '/' .. a end
    env.StopAnimTask = function(_, d, a)
        if C.anim == d .. '/' .. a then C.anim = nil end
    end
    env.ClearPedTasks = function() C.anim = nil end
    env.IsEntityPlayingAnim = function() return true end
    env.SetEntityAnimSpeed = function() end
    env.RequestClipSet = function() end
    env.HasClipSetLoaded = function() return false end
    env.CreateCamWithParams = function() return 700 end
    env.DoesCamExist = function() return true end
    env.DestroyCam = function() end
    env.SetCamActive = function() end
    env.RenderScriptCams = function() end
    env.SetCamCoord = function() end
    env.PointCamAtCoord = function() end

    local handlers = {}
    env.AddEventHandler = function(n, fn)
        handlers[n] = handlers[n] or {}
        handlers[n][#handlers[n] + 1] = fn
    end
    env.RegisterNetEvent = function() end
    env.RegisterCommand = function() end
    env.TriggerEvent = function(n, ...)
        for _, fn in ipairs(handlers[n] or {}) do fn(...) end
    end
    env.TriggerServerEvent = function(n, d)
        C.toServer[#C.toServer + 1] = { at = C.now, event = n, data = d }
    end
    local threads = {}
    env.Citizen = {
        CreateThread = function(fn)
            threads[#threads + 1] = { co = coroutine.create(fn), wake = C.now + 16 }
        end,
        Wait = function(ms) coroutine.yield(ms or 0) end,
        SetTimeout = function() end,
    }

    loadInto(env, { 'br_core/client/main.lua' })

    env.BR.State.me = { src = mySrc, state = env.BR.PlayerState.ALIVE, squadId = 'sq1' }
    env.BR.State.roster = {
        [mateSrc] = { src = mateSrc, name = 'P' .. mateSrc, squadId = 'sq1',
                      state = env.BR.PlayerState.ALIVE },
        [mySrc]   = { src = mySrc, name = 'P' .. mySrc, squadId = 'sq1',
                      state = env.BR.PlayerState.ALIVE },
    }
    env.BR.Sfx = { play = function() end }
    env.BR.Dui = { page = function(n) return { name = n } end, send = function() end,
                   drawWorld = function() end, drawScreen = function() end,
                   drawOnEntity = function() end, ready = function() return true end }
    env.BR.Native = env.BR.Native or {}
    env.BR.Native.knockdown = function() end
    env.BR.Native.setDisplayHealth = function() end
    env.BR.Native.cleanPed = function() end
    env.BR.Native.keyLabelForCommand = function() return 'E' end
    env.BR.Native.applyGameRules = function() end
    env.BR.Native.ALLY_GROUP = 1

    -- THE KEY LAYER IS A PHYSICAL KEY HERE, and that is the point: isHeld is a
    -- LEVEL that answers honestly on every frame, which is what keybinds.lua's
    -- raw sampler was rewritten to guarantee (#129). The bug under test is what
    -- dbno.lua does with that level, not whether the level is right.
    local listeners = {}
    env.BR.Keys = {
        isHeld = function() return C.held end,
        on = function(action, fn)
            listeners[action] = listeners[action] or {}
            listeners[action][#listeners[action] + 1] = fn
        end,
    }
    function C.press(down)
        C.held = down
        for _, fn in ipairs(listeners.interact or {}) do fn(down) end
    end
    env.BR.Loot = { suppress = function() end }
    env.BR.Squadmates = {
        headAnchor = function(p) local q = at(p) return q.x, q.y, q.z + 0.3 end,
        pedOf = function(s) return 5000 + s end,
    }

    -- THE ENVELOPES THIS CLIENT PUSHES AT THE INTERFACE, kept whole. The squad
    -- cue (item 4) is one of them and it has no other observable.
    C.ui = {}
    env.AddEventHandler('br:ui:sendLocal', function(kind, payload)
        C.ui[#C.ui + 1] = { kind = kind, d = payload }
    end)

    loadInto(env, { 'br_core/client/dbno.lua' })

    C.env = env
    function C.frame()
        for i = #threads, 1, -1 do
            local t = threads[i]
            if C.now >= t.wake and coroutine.status(t.co) == 'suspended' then
                local okr, err = coroutine.resume(t.co)
                if not okr then
                    io.write('\27[31mreviver thread error\27[0m ', tostring(err), '\n')
                end
                if coroutine.status(t.co) == 'dead' then table.remove(threads, i)
                else t.wake = C.now + (tonumber(err) or 0) end
            end
        end
        env.BR.Loop.step(env.BR.Loop.FRAME)
    end
    return C
end

--- Player 1 gets knocked; player 2 stands over them holding the key.
---
--- TWO SETS OF COORDINATES, AND THAT IS THE POINT OF THIS RIG AFTER #164.
---
--- `truth` is where the bodies actually are: the server samples it, because
--- server/roster.lua reads GetEntityCoords on the machine that owns the ped.
--- `peds` is the REVIVER'S OWN COPY -- what client/dbno.lua measures its 1.5m
--- reach against, through BR.Squadmates.pedOf.
---
--- They used to be one table, which quietly asserted that every client sees the
--- same body in the same place. #164 is the report that they do not: the downed
--- ped is pinned on its owner's machine and the clone on everybody else's crawls
--- away, because the two things that pin it (TaskPlayAnim's lock flags and
--- SetEntityAnimSpeed) are both local-only. A rig with one table cannot express
--- that, which is exactly why 57 green cycles sat on top of a revive nobody
--- could perform.
--- @param rtt integer  one-way latency, ms
local function newReviveRig(rtt)
    local truth = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                    [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
    local peds  = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                    [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
    local SRV = newServer()
    local CLI = newReviver(2, 1, peds)
    local PS  = SRV.env.BR.PlayerState
    local wire = {}
    local H = { srv = SRV, cli = CLI }

    -- Metres per second the downed mate's CLONE walks away from where the body
    -- really is, on the reviver's machine only. 0.0 is a build where #164 is
    -- fixed; the clip's own mover is worth about a third of a metre a second
    -- (client/dbno.lua's note, measured at 1.05m over three seconds).
    H.ghostSpeed = 0.0

    function H.pump(ms, onFrame)
        local target = CLI.now + ms
        while CLI.now < target do
            CLI.now = math.min(CLI.now + 16, target)
            local now = CLI.now
            SRV.tick(now)

            -- The clone crawls; the body does not. The reviver stands still and
            -- watches a ped leave a circle it never actually left.
            --
            -- AWAY FROM THE REVIVER, who is at +x. A clone that wandered
            -- TOWARDS them would be a rig that proves nothing -- which is worth
            -- saying, because that is what the first cut of this did and it
            -- passed against the broken build.
            peds[5001].x = peds[5001].x - H.ghostSpeed * 0.016

            -- roster.positions, reduced to what it produces: reviveAllowed
            -- measures from the SERVER's own samples and from nothing a client
            -- said, so the rig has to keep them fed -- from the TRUTH.
            for _, s in ipairs({ 1, 2 }) do
                local q = truth[5000 + s]
                SRV.roster[s].pos = { x = q.x, y = q.y, z = q.z }
            end

            for i = 1, #SRV.out do
                local m = SRV.out[i]
                wire[#wire + 1] = { at = now + rtt, event = m.event,
                                    target = m.target, payload = m.payload }
            end
            for i = #SRV.out, 1, -1 do SRV.out[i] = nil end
            while wire[1] and now >= wire[1].at do
                local m = table.remove(wire, 1)
                if m.target == 2 then CLI.env.TriggerEvent(m.event, m.payload) end
            end

            -- The roster delta, which is how a client learns a mate went down.
            CLI.env.BR.State.roster[1].state = SRV.roster[1].state

            if onFrame then onFrame(now) end
            CLI.frame()

            local kept = {}
            for i = 1, #CLI.toServer do
                local m = CLI.toServer[i]
                if now >= m.at + rtt then SRV.fire(m.event, 2, m.data)
                else kept[#kept + 1] = m end
            end
            CLI.toServer = kept
        end
    end

    function H.knock()
        -- A fresh knock re-pins the clone: the crawl is tasked again, so
        -- whatever the last one had wandered to is not inherited.
        peds[5001].x = truth[5001].x
        SRV.env.BR.Combat.knock(1, 3)
    end
    function H.press(down) CLI.press(down) end
    --- The reviver really walks: both the truth and their own view move.
    function H.moveTo(x) peds[5002].x, truth[5002].x = x, x end
    function H.up() return SRV.roster[1].state == PS.ALIVE end

    --- Pump up to `ms` waiting for player 1 to come back up.
    function H.revived(ms)
        local done = false
        H.pump(ms, function()
            if SRV.roster[1].state == PS.ALIVE then done = true end
        end)
        return done
    end

    H.pump(2000)
    return H
end

describe('dbno.hold.rearm')
do
    -- THREE ROUND TRIPS, because "it works on my connection" is what the last
    -- three rounds on this file each turned out to mean. Every sequence below
    -- failed on its SECOND cycle at all three before the fix and at none after,
    -- which is how a bug is shown to be a rule rather than a race.
    local RTTS = { 20, 40, 120 }

    local plans = {
        {
            name = 'press, hold, release -- three times',
            run = function(H)
                local out = {}
                for i = 1, 3 do
                    H.knock(); H.pump(500)
                    H.press(true)
                    out[i] = H.revived(6000)
                    H.press(false); H.pump(500)
                end
                return out
            end,
        },
        {
            -- THE OWNER'S SENTENCE, as a sequence. Nobody lets go of a key
            -- between one revive and the next knock ten seconds later.
            name = 'never lets go of the key between knocks',
            run = function(H)
                local out = {}
                H.press(true)
                for i = 1, 3 do
                    H.knock()
                    out[i] = H.revived(6000)
                    H.pump(800)
                end
                H.press(false)
                return out
            end,
        },
        {
            name = 'presses before the mate is down',
            run = function(H)
                local out = {}
                for i = 1, 3 do
                    H.press(true); H.pump(400)
                    H.knock()
                    out[i] = H.revived(6000)
                    H.press(false); H.pump(500)
                end
                return out
            end,
        },
        {
            -- The reach test drops the hold, and walking back into reach used
            -- to be no way to get it back.
            name = 'steps out of reach mid-hold and steps back',
            run = function(H)
                local out = {}
                for i = 1, 3 do
                    H.knock(); H.pump(300)
                    H.press(true); H.pump(600)
                    H.moveTo(9.0); H.pump(600)
                    H.moveTo(0.8)
                    out[i] = H.revived(6000)
                    H.press(false); H.pump(500)
                end
                return out
            end,
        },
        {
            name = 'mate goes down again under the same held key',
            run = function(H)
                local out = {}
                H.knock(); H.pump(300)
                H.press(true)
                out[1] = H.revived(6000)
                H.pump(400)
                H.knock()
                out[2] = H.revived(6000)
                H.press(false)
                return out
            end,
        },
    }

    for _, plan in ipairs(plans) do
        local failures, where = 0, nil
        for _, rtt in ipairs(RTTS) do
            local res = plan.run(newReviveRig(rtt))
            for i, up in ipairs(res) do
                if not up then
                    failures = failures + 1
                    where = where or ('cycle %d at %dms'):format(i, rtt)
                end
            end
        end
        ok(failures == 0,
            'every revive lands: ' .. plan.name,
            where and ('%d failed, first %s'):format(failures, where) or nil)
    end
end

-- ==========================================================================
-- #163, ROUND THREE: "the ring fills up when I hold the button, but nothing
-- happens." STILL.
-- ==========================================================================
--
-- WHAT THE 57 CYCLES ABOVE COULD NOT REACH. Every one of them measured its 1.5m
-- reach against a ped that was exactly where the server said it was, because the
-- rig had one coordinate table. The real reviver measures against the CLONE, and
-- #164 is the report that the clone crawls away at about 0.35 m/s while the body
-- lies still.
--
-- The arithmetic is the whole bug and it does not need a race:
--
--   the reviver stands 0.8m from the body and holds the key;
--   the clone leaves the 1.5m circle after (1.5 - 0.8) / 0.35 = 2.0 SECONDS;
--   a revive takes dbnoReviveTime = 2.8 SECONDS.
--
-- The old client turned that into REVIVE_STOP, which is a HARD cancel: the
-- server throws `reviveFrom` away, there is no pause and no resume, and the next
-- ask starts a fresh 2.8 seconds. So the hold is destroyed at 2.0s, forever,
-- 0.8s short, at every latency, on every attempt.
--
-- AND THE RING SHOWS NONE OF IT, which is why three rounds died here.
-- setPrompt() is a send-on-change keyed on (target, duration); a refuse-and-
-- re-arm changes neither, so no message is sent, and the ONE-SHOT CSS fill
-- started by the first arm runs to completion over an interaction that is
-- failing four times a second. A full ring and a working revive are the same
-- pixels. The counters in the client's ledger are what tell them apart.
--
-- THE SERVER WOULD HAVE ALLOWED IT ALL ALONG -- it measures 2.5m from its own
-- samples of the real bodies, which never moved. The client was overruling the
-- authority with a worse measurement of a ghost.

describe('dbno.hold.ghost')
do
    local RTTS = { 20, 40, 120 }
    -- The clip's own mover, as client/dbno.lua measured it: 1.05m in 3s.
    local GHOST_MPS = 0.35

    --- Stand over a downed mate and hold the key. Nothing else happens: no
    --- walking away, no second reviver, no damage. The only moving part is the
    --- clone.
    local function holdThrough(rtt, ghost)
        local H = newReviveRig(rtt)
        H.ghostSpeed = ghost
        H.knock()
        H.pump(500)
        H.press(true)
        -- Twice the hold's own length. If it has not landed in 5.6s while the
        -- player never let go and never moved, it is not going to.
        local up = H.revived(6000)
        H.press(false)
        return up, H
    end

    local still, drifting = 0, 0
    local firstFail = nil
    for _, rtt in ipairs(RTTS) do
        for _ = 1, 3 do
            if holdThrough(rtt, 0.0) then still = still + 1 end
            local up = holdThrough(rtt, GHOST_MPS)
            if up then drifting = drifting + 1
            elseif not firstFail then firstFail = ('%dms'):format(rtt) end
        end
    end

    ok(still == 9,
        'a hold over a body that stays put lands, every time (the case the '
        .. 'old rig could express)',
        ('%d of 9'):format(still))

    -- THE HEADLINE. Before: 0 of 9 -- the clone crosses 1.5m at 2.0s and the
    -- client hard-cancels a 2.8s hold, at all three round trips, which is a
    -- rule and not a race. After: 9 of 9.
    ok(drifting == 9,
        'AND SO DOES ONE OVER A BODY THAT IS CRAWLING AWAY ON THIS CLIENT '
        .. 'ONLY -- the server measures the real bodies and is the authority',
        ('%d of 9, first failure at %s'):format(drifting,
                                                tostring(firstFail)))

    -- ...AND THE CLIENT NOTICED IT HAPPENING. The ledger is the deliverable:
    -- "lost sight of the body for N frames while still holding" is the reading
    -- that points at #164 instead of at the server.
    local _, H = holdThrough(40, GHOST_MPS)
    local led = H.cli.env.BR.Dbno and H.cli.env.BR.Dbno.ledger or nil
    ok(led ~= nil, 'the revive ledger is reachable for /brdbno')
    ok(led and led.asks > 0,
        'the request did leave -- so "nothing happened" is not this',
        led and tostring(led.asks) or nil)
    ok(led and led.blind > 0,
        'and the client counted the frames it could not see the body it was '
        .. 'holding, which is the fingerprint of the drifting clone',
        led and tostring(led.blind) or nil)
    ok(led and led.dones == 1,
        'and the server finished it anyway',
        led and tostring(led.dones) or nil)
end

-- A LEGITIMATE WALK-OFF STILL CANCELS, and it has to: the point above is that
-- the SERVER decides, not that nobody does.
describe('dbno.hold.walkaway')
do
    local H = newReviveRig(40)
    H.knock(); H.pump(500)
    H.press(true); H.pump(600)
    H.moveTo(40.0)
    local up = H.revived(4000)
    ok(not up,
        'walking away from a body really does end the hold -- from the '
        .. 'server\'s own samples',
        up and 'they were revived from forty metres' or nil)
    ok((H.srv.roster[1].reviveStops or 0) > 0
       and tostring(H.srv.roster[1].reviveStopWhy):find('apart', 1, true),
        'and the server says how far apart they were, not "notallowed"',
        tostring(H.srv.roster[1].reviveStopWhy))

    -- ...and walking back in picks it up again, with no re-press.
    H.moveTo(0.8)
    ok(H.revived(6000),
        'and stepping back over them resumes it without letting go of the key')
    H.press(false)
end

-- ==========================================================================
-- THE REVIVER'S CPR EMOTE, AND EVERY WAY A HOLD CAN END
-- ==========================================================================
--
-- "Also, adding to our roll of emotes: in squads, while holding E to revive a
--  squadmate, the one reviving should play the "CPR" emote and clear once the
--  revive is processed, or after 10 seconds, whichever comes first."
-- (owner, 2026-08-29.)
--
-- WHY IT IS TESTED HERE AND NOT BY LOOKING AT IT. The emote is one TaskPlayAnim
-- on one ped; it sends nothing, pushes no envelope and writes no roster field,
-- so the only thing a playtest can report about it is "it looked right" -- and
-- the failure this is written against is not something a playtest ever sees.
-- A hold can end in nine different ways and only one of them (the revive
-- landing) happens in front of the player who was watching. The other eight are
-- a refusal four times a second, a release, a switch to a nearer mate, the
-- reviver being shot, the reviver being killed, the mate being picked up by
-- somebody else, a match ending and a resource restart -- and an emote that
-- survives ANY of them is a player performing chest compressions on thin air
-- for the rest of the match, which is a bug the owner would report as
-- "sometimes my ped gets stuck" a week later with nothing to reproduce.
--
-- SO EVERY ENDING IS DRIVEN, and the assertion is always the same one: the task
-- is off the ped. The rig is the one the revive already uses -- the real
-- client/dbno.lua and the real server/combat.lua over a real latency -- because
-- most of these endings are the SERVER's decision and a client-only rig would
-- have to invent them.
describe('dbno.cpr')
do
    -- The pair taken from the emote list the owner browsed; see the block above
    -- the constants in client/dbno.lua for the citation. Spelled out here
    -- rather than read back out of the client, deliberately: a test that asked
    -- the file under test what it was playing would pass for a typo.
    local CPR = 'mini@cpr@char_a@cpr_str/cpr_pumpchest'

    --- A knocked mate and a reviver standing over them with the key down.
    --- @param rtt integer|nil
    local function stoodOver(rtt)
        local H = newReviveRig(rtt or 40)
        H.knock()
        H.pump(500)
        H.press(true)
        H.pump(200)
        return H
    end

    -- ── 1. IT STARTS ON THE HOLD, AND ONLY ON THE HOLD ──────────────────────
    do
        local H = newReviveRig(40)
        H.knock()
        H.pump(500)
        ok(H.cli.anim == nil,
            'standing over a downed mate with nothing pressed plays no emote',
            tostring(H.cli.anim))

        H.press(true)
        H.pump(200)
        ok(H.cli.anim == CPR,
            'and holding the interact key puts the reviver into CPR',
            tostring(H.cli.anim))
        H.press(false)
    end

    -- ── 2. IT CLEARS ONCE THE REVIVE IS PROCESSED ───────────────────────────
    --
    -- THE KEY IS STILL DOWN AT THE END OF THIS, which is the case worth having:
    -- nobody lets go on the frame their mate stands up, and `holding` is
    -- cleared by the server's `done` while the key is still held. An emote hung
    -- off the KEY rather than off the hold would run until the player noticed.
    do
        local H = stoodOver(40)
        ok(H.cli.anim == CPR, 'the emote is up during the hold',
           tostring(H.cli.anim))
        ok(H.revived(6000), 'the revive lands')
        ok(H.cli.anim == nil,
            'and the emote clears once the revive is processed, without the '
            .. 'player letting go of the key', tostring(H.cli.anim))
        H.press(false)
    end

    -- ── 3. THE TEN-SECOND CEILING ───────────────────────────────────────────
    --
    -- A HOLD THAT IS ACCEPTED AND NEVER FINISHES. dbnoReviveTime is 2.8s, so
    -- there is no such thing in a real match -- which is exactly why the
    -- ceiling needs a rig to be observed at all. The server's copy of the
    -- number is stretched to a minute; everything else is a perfectly ordinary
    -- hold, progressing, with the reviver in reach and the key down throughout.
    do
        local H = newReviveRig(40)
        H.srv.env.BR.Config.Match.dbnoReviveTime = 60.0
        H.knock()
        H.pump(500)
        H.press(true)
        H.pump(200)
        ok(H.cli.anim == CPR, 'a hold that will not finish starts the emote',
           tostring(H.cli.anim))

        H.pump(9000)
        ok(H.cli.anim == CPR,
            'and it is STILL up at nine seconds -- the ceiling is a ceiling, '
            .. 'not a duration the emote waits out', tostring(H.cli.anim))

        H.pump(1500)
        ok(H.cli.anim == nil,
            'and it clears at ten seconds with the key still down and the '
            .. 'hold still running', tostring(H.cli.anim))

        -- ...AND IT DOES NOT COME STRAIGHT BACK. A ceiling that re-armed on the
        -- next frame would be a stutter rather than a limit, and the ped would
        -- be doing CPR again a sixtieth of a second later.
        H.pump(3000)
        ok(H.cli.anim == nil,
            'and it stays cleared for as long as the key stays down',
            tostring(H.cli.anim))

        -- THE HOLD IS UNTOUCHED. The ceiling is on the ANIMATION; the revive is
        -- the server's business and this number is not shared with it.
        ok(H.srv.roster[1].reviverSrc == 2,
            'and the revive itself is still running -- the ceiling ends the '
            .. 'emote, never the hold',
            tostring(H.srv.roster[1].reviverSrc))

        -- ...AND A SPENT CEILING IS SPENT FOR THAT RUN AND NOT FOR THE MATCH.
        -- The stamp the ceiling is measured from is dropped when the hold ends,
        -- so the next hold gets its own ten seconds. Left standing, a player
        -- who once held a key for ten seconds would never see the emote again.
        H.press(false)
        H.pump(400)
        H.press(true)
        H.pump(300)
        ok(H.cli.anim == CPR,
            'and letting go and pressing again starts a fresh emote -- the '
            .. 'ceiling is per hold, not per match', tostring(H.cli.anim))
        H.press(false)
    end

    -- ── 3b. THE CEILING UNDER A HOLD THE SERVER REFUSES FOUR TIMES A SECOND ─
    --
    -- THIS IS THE ONE THAT MATTERS, and it is the case an obvious
    -- implementation gets wrong. `holding` is not a stable object: a refused
    -- REVIVE_START clears it, and dbno.revive re-arms it from the key's LEVEL
    -- on the very next frame with a brand new `from` stamp -- four times a
    -- second, for as long as the player leans on the key. A ceiling measured
    -- from `holding.from` is therefore reset four times a second and NEVER
    -- FIRES, on precisely the interaction it was written for: one that is
    -- failing silently and could otherwise run for the rest of the match.
    --
    -- The refusal is a squad the server does not agree with. The reviver's own
    -- client still sees a squadmate on the floor at 0.8m, so it arms, asks, is
    -- refused, and arms again -- forever.
    do
        local H = newReviveRig(40)
        H.knock()
        H.pump(300)
        H.srv.roster[1].squadId = 'sq2'
        H.press(true)
        H.pump(200)
        ok(H.cli.anim == CPR,
            'a hold the server is refusing still starts the emote -- the '
            .. 'client cannot tell yet, and neither can the ring',
            tostring(H.cli.anim))

        H.pump(11000)
        local led = H.cli.env.BR.Dbno.ledger
        ok(led.refusals > 20,
            'the server refused it over and over, which is what rebuilds '
            .. '`holding` under the emote', tostring(led.refusals))
        ok(H.cli.anim == nil,
            'AND THE EMOTE STILL CLEARED AT TEN SECONDS -- the ceiling '
            .. 'survives `holding` being destroyed and rebuilt four times a '
            .. 'second', tostring(H.cli.anim))
        H.press(false)
    end

    -- ── 4. THE KEY COMES UP ─────────────────────────────────────────────────
    do
        local H = stoodOver(40)
        ok(H.cli.anim == CPR, 'the emote is up', tostring(H.cli.anim))
        H.press(false)
        H.pump(100)
        ok(H.cli.anim == nil, 'letting go of the key clears it',
           tostring(H.cli.anim))
    end

    -- ── 5. THE REVIVER WALKS OFF ────────────────────────────────────────────
    --
    -- Nobody let go of anything here: the SERVER ends this one, from its own
    -- position samples, and the client hears about it a round trip later.
    do
        local H = stoodOver(40)
        ok(H.cli.anim == CPR, 'the emote is up', tostring(H.cli.anim))
        H.moveTo(40.0)
        H.pump(2000)
        ok(H.srv.roster[1].reviverSrc == nil, 'the server ended the hold',
           tostring(H.srv.roster[1].reviverSrc))
        ok(H.cli.anim == nil,
            'and walking out of the server\'s reach clears the emote, with the '
            .. 'key still down', tostring(H.cli.anim))
        H.press(false)
    end

    -- ── 6. THE REVIVER IS KNOCKED DOWN MID-HOLD ─────────────────────────────
    --
    -- `holding` DELIBERATELY OUTLIVES THIS for up to a round trip plus the
    -- server's 250ms step: #163 moved the authority over a hold to the server
    -- on purpose, and this client no longer ends one for anything it is not the
    -- sole witness to. That is right for the REQUEST and wrong for the
    -- ANIMATION -- a body on the floor doing chest compressions is the exact
    -- picture the whole block exists to prevent -- so the emote, and only the
    -- emote, is gated on still being upright.
    do
        local H = stoodOver(40)
        ok(H.cli.anim == CPR, 'the emote is up', tostring(H.cli.anim))
        H.cli.env.BR.State.me.state = H.cli.env.BR.PlayerState.DBNO
        H.pump(50)
        ok(H.cli.anim == nil,
            'a reviver knocked down mid-hold stops doing CPR on the frame '
            .. 'their OWN client knows, not a round trip later',
            tostring(H.cli.anim))
        ok(H.srv.roster[1].reviverSrc == 2,
            'and the hold itself is still the server\'s to end -- nothing here '
            .. 'reached for it', tostring(H.srv.roster[1].reviverSrc))
        H.press(false)
    end

    -- ── 7. THE MATCH ENDS MID-HOLD ──────────────────────────────────────────
    --
    -- ON THE EVENT AND NOT ON THE NEXT FRAME. A match ending is the one moment
    -- a leftover frame of this is guaranteed to be looked at, so forgetAll
    -- calls the same teardown by hand rather than waiting for the frame band.
    do
        local H = stoodOver(40)
        ok(H.cli.anim == CPR, 'the emote is up', tostring(H.cli.anim))
        H.cli.env.TriggerEvent(H.cli.env.BR.Net.STATE,
                               { state = H.cli.env.BR.MatchState.ENDED })
        ok(H.cli.anim == nil,
            'a match that ends mid-hold takes the emote with it, on the event '
            .. 'itself', tostring(H.cli.anim))
        H.press(false)
    end

    -- ── 8. THE RESOURCE STOPS MID-HOLD ──────────────────────────────────────
    --
    -- THE ONE ENDING THE FRAME LOOP CANNOT COVER, because the frame loop is
    -- what is being stopped. `restart br_core` while somebody is holding would
    -- otherwise leave a tasked animation on a ped with nothing left running to
    -- take it off -- the same class as the movement clipset two lines above it
    -- in that handler.
    do
        local H = stoodOver(40)
        ok(H.cli.anim == CPR, 'the emote is up', tostring(H.cli.anim))
        H.cli.env.TriggerEvent('onClientResourceStop', 'br_core')
        ok(H.cli.anim == nil,
            'and stopping the resource mid-hold clears it too',
            tostring(H.cli.anim))
        H.press(false)
    end

    -- ── 9. NOTHING DOWN, NOTHING PLAYED ─────────────────────────────────────
    --
    -- WHICH IS EVERY FRAME OF A SOLO MATCH. BR.Mode.SOLO.dbno is false
    -- (asserted at the top of this file), so no solo player is ever in the
    -- state the emote is gated on, and every solo is their own squad besides.
    -- The emote is unreachable there by construction rather than by a mode
    -- check -- and this is the assertion that says so: the interact key held
    -- down over nobody plays nothing at all, which is also the loot crate case
    -- and the empty-hands case.
    do
        local H = newReviveRig(40)
        H.press(true)
        H.pump(1500)
        ok(H.cli.anim == nil,
            'holding the interact key with nobody down plays no emote',
            tostring(H.cli.anim))
        H.press(false)
    end

    -- ── 10. A DICTIONARY THAT IS NOT THERE ──────────────────────────────────
    --
    -- `0` IS TRUTHY IN LUA and HasAnimDictLoaded is declared BOOL, so a build
    -- that hands numbers back answers the NUMBER ZERO for "not loaded" -- which
    -- passes `if HasAnimDictLoaded(d) then`. Read raw, the emote would be
    -- tasked on a dictionary that is not resident: nothing plays, and the
    -- client believes it did, so it never asks the streamer again and the hold
    -- runs its whole length with the ped standing there. This project has
    -- shipped that read nine times.
    do
        local H = newReviveRig(40)
        local asked = 0
        H.cli.env.HasAnimDictLoaded = function() return 0 end
        H.cli.env.RequestAnimDict = function(d)
            if d == 'mini@cpr@char_a@cpr_str' then asked = asked + 1 end
        end
        H.knock()
        H.pump(500)
        H.press(true)
        H.pump(300)
        ok(H.cli.anim == nil,
            'a build whose HasAnimDictLoaded answers the NUMBER 0 gets no '
            .. 'emote tasked on a dictionary that is not there',
            tostring(H.cli.anim))
        ok(asked > 0,
            'and it goes on asking the streamer for it instead of giving up',
            tostring(asked))
        H.press(false)
    end
end

describe('dbno.refusal')
do
    -- A REFUSAL THE CLIENT NEVER HEARS IS THE RING'S ALIBI. The prompt page runs
    -- a one-shot CSS fill from one message, so a hold the server silently
    -- declined looks exactly like a hold that is working -- for the full
    -- duration, and then forever. Every refused REVIVE_START now answers.
    local S = newServer()
    local Net = S.env.BR.Net
    S.env.BR.Combat.knock(1, 3)
    for _, src in ipairs({ 1, 2 }) do
        S.roster[src].pos = { x = (src - 1) * 0.5, y = 0.0, z = 30.0 }
    end

    --- @return table|nil the REVIVE_PROGRESS sent to `to`, if any
    local function askAs(who, target, to)
        for i = #S.out, 1, -1 do S.out[i] = nil end
        S.fire(Net.REVIVE_START, who, { target = target })
        for _, m in ipairs(S.out) do
            if m.event == Net.REVIVE_PROGRESS and m.target == to then
                return m.payload
            end
        end
        return nil
    end

    -- Out of reach: the client's own 1.5m test would normally stop this, but a
    -- client is not something the server gets to rely on.
    S.roster[2].pos = { x = 40.0, y = 0.0, z = 30.0 }
    local far = askAs(2, 1, 2)
    ok(far ~= nil and far.cancelled == true,
        'a refused hold answers the holder instead of leaving the ring running',
        far and tostring(far.reason) or 'nothing was sent at all')

    -- ...and an ALLOWED one still says nothing on the START itself: the progress
    -- ticks are what report it, and an extra cancel here would kill the hold it
    -- just accepted.
    S.roster[2].pos = { x = 0.5, y = 0.0, z = 30.0 }
    local near = askAs(2, 1, 2)
    ok(near == nil,
        'and an accepted hold is NOT answered with a cancel',
        near and tostring(near.reason) or nil)
    ok(S.roster[1].reviverSrc == 2, 'the accepted hold is on the books')

    -- SECOND HAND ON LOSES, AND IS TOLD. This is the refusal that used to be
    -- indistinguishable from a working hold for the mate who pressed second.
    S.roster[3] = { src = 3, name = 'P3', matchId = 1, squadId = 'sq1',
                    state = S.env.BR.PlayerState.ALIVE, hp = 100.0, armour = 0.0,
                    pos = { x = 0.5, y = 0.0, z = 30.0 } }
    -- THE REASON CARRIES ITS WORKING NOW (#163). It is read back by /brdbno on
    -- both ends, so what is pinned is the prefix -- the machine-readable half --
    -- rather than the sentence, which is allowed to say more.
    local second = askAs(3, 1, 3)
    ok(second ~= nil and second.cancelled == true
       and tostring(second.reason):sub(1, 5) == 'taken',
        'and the mate who pressed second is told the body is taken',
        second and tostring(second.reason) or 'nothing was sent at all')
    ok(second ~= nil and tostring(second.reason):find('2', 1, true) ~= nil,
        'and told WHO has it -- a refusal that names nobody is a refusal '
        .. 'nobody can act on',
        second and tostring(second.reason) or nil)

    -- ...AND THE SERVER WROTE IT DOWN. The client's ledger can say "the server
    -- refused"; only this side can say which refusal, and /brdbno reads these.
    ok(S.roster[1].reviveRefusals == 2,
        'every refusal is counted on the body it was about',
        tostring(S.roster[1].reviveRefusals))
    ok(type(S.roster[1].reviveRefuseWhy) == 'string'
       and S.roster[1].reviveRefuseWhy ~= 'notallowed',
        'and the last one is kept in words rather than as one flat token',
        tostring(S.roster[1].reviveRefuseWhy))

    -- THE OUT-OF-REACH REFUSAL CARRIES THE NUMBER, which is the one refusal
    -- that is a measurement rather than a state. "40.00m apart" ends an
    -- argument that "notallowed" could only start.
    ok(tostring(far.reason):find('m apart', 1, true) ~= nil,
        'and being out of reach says HOW far, and what the reach was',
        tostring(far.reason))
    ok(S.roster[1].reviverSrc == 2,
        'without disturbing the hold that was already running',
        tostring(S.roster[1].reviverSrc))
end

-- ==========================================================================
-- #164: THE DOWNED PED DRIFTS ON EVERYONE ELSE'S SCREEN.
-- ==========================================================================
--
-- "When DBNO - the ped is not moving on the DBNO player's screen, but on others'
-- they are." (owner, 2026-08-18.)
--
-- WHAT CAN AND CANNOT BE ASSERTED FROM OUTSIDE THE GAME. Nothing here can watch
-- a clone on a second machine -- there is no engine in this process. What CAN be
-- asserted is the thing whose absence is the fault: whether this client ever
-- does anything that CROSSES THE WIRE while a downed player lies still.
--
-- Before this change the answer was "nothing, ever". Both of the mechanisms
-- that hold the body still are local-only -- TaskPlayAnim's lock flags and
-- SetEntityAnimSpeed -- and stayPut() only writes a position when the LOCAL ped
-- has drifted past a centimetre, which it never does, because the lock flags
-- work. So a downed player is, to the network, an entity that has not moved
-- since the knock, and a clone replaying a locomotion clip is left to walk off
-- on its own.
--
-- The count below is therefore the honest measurement: position writes per
-- second of lying still. 0.0 before the first fix, and now ONE PAIR PER CRAWL
-- TASK rather than one pair every 500ms -- which is the follow-on below.
--
-- ==========================================================================
-- #164 FOLLOW-ON: THE CORRECTION ITSELF BECAME THE DRIFT.
-- ==========================================================================
--
-- "DBNO is kinda fixed - they're inching forward extremely slowly in steps, but
-- they are synced. If we can play that step exactly once and only once - we're
-- clear." (owner, 2026-08-18.)
--
-- WHAT A BEAT COSTS, counted rather than argued. The pair is TWO FRAMES: one
-- that moves the body ~9mm and one that puts it back. Both of those are real
-- position writes, so both are things other machines can sample -- and the
-- network samples on its own cadence, not on ours, so every beat is a chance
-- for a watcher to catch the body mid-pair. config/match.lua bleeds for 40
-- seconds at the floor and 120 at the base; at 500ms that is 80 to 240 chances
-- per knock, forever, for a correction that only ever had one thing to cancel.
--
-- AND A PAIR THAT LOSES ITS SECOND HALF KEEPS THE STEP. dbno.controls drops
-- `hold` on any frame reading IsPedRagdoll or IsEntityInAir, and the `back`
-- half refuses to run without it -- so stayPut re-anchors AT THE STEPPED-OUT
-- POSITION and 9mm is never given back. That is modelled below, because it is
-- the mechanism that turns "a twitch" into "inching forward", and because it is
-- the difference between an error that happens once and an error that
-- accumulates twice a second for two minutes.
--
-- THE CONTRACT AFTER THE FIX IS NOT A RATE. It is: one step per crawl TASK,
-- because a task is the only thing that creates the mover the step cancels.

describe('dbno.clone.sync')
do
    local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                   [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
    -- This client IS the downed one, which is the machine the fix lives on.
    local CLI = newReviver(1, 2, peds)
    local env = CLI.env

    -- THE PED'S POSITION IS REAL HERE, and that is the change this block needed
    -- to be able to say anything about creep at all: the rig used to throw
    -- every write away and count them, which can measure a beat and cannot
    -- measure a metre.
    local coordWrites, rateWrites = 0, 0
    env.SetEntityCoordsNoOffset = function(_, x, y, z)
        coordWrites = coordWrites + 1
        peds[5001].x, peds[5001].y, peds[5001].z = x, y, z
    end
    env.SetEntityAnimSpeed = function() rateWrites = rateWrites + 1 end

    -- THE CRAWL TASK IS A REAL OBJECT TOO. `playCrawl` only issues one when the
    -- clip is not already running, and the whole re-arm now hangs off that --
    -- so a rig that answers "yes, always" to IsEntityPlayingAnim cannot see a
    -- re-task and cannot see the watchdog.
    local tasks, anim = 0, nil
    env.TaskPlayAnim = function(_, d, a) tasks = tasks + 1 anim = d .. '/' .. a end
    env.IsEntityPlayingAnim = function() return anim ~= nil end

    local startX = peds[5001].x

    env.TriggerEvent(env.BR.Net.DBNO_SET,
        { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })

    -- A FULL BLEED AT THE FLOOR, not three seconds. The old window was shorter
    -- than the fault: a beat is only a problem in the aggregate, and 40 seconds
    -- is the SHORTEST knock config/match.lua can produce (dbnoBleedMin).
    local SECONDS = 40
    for _ = 1, SECONDS * 62 do
        CLI.now = CLI.now + 16
        CLI.frame()
    end

    ok(env.BR.Dbno.ledger ~= nil, 'the dbno readings are published')

    -- TWO TASKS, AND BOTH OF THEM ARE REAL. dbno.controls' watchdog tasks the
    -- crawl on the first downed frame, because the ped is not playing it yet;
    -- the live-knock path then re-tasks it when the knockdown lands, from where
    -- the body actually came to rest. A quiet 40 seconds adds nothing to that.
    ok(tasks == 2,
        'a knock that nothing interrupts settles on two crawl tasks and then '
        .. 'stops asking',
        ('%d tasks'):format(tasks))

    -- ONE PAIR EACH. Two writes per pair: the step out and the step back.
    --
    -- THIS IS THE CONTRACT, and it is deliberately written as an equation
    -- against `tasks` rather than as a number. A count would pass for the wrong
    -- reason the moment anything changed how many times the pose is issued; the
    -- claim being made is "once per task, and never on a clock".
    ok(coordWrites == tasks * 2,
        'and the clone resync is played exactly ONCE for each of them -- '
        .. 'BEFORE: 152 writes over the SHORTEST knock the config can produce, '
        .. 'and it scales with the bleed rather than with the cause',
        ('%d writes for %d tasks in %ds'):format(coordWrites, tasks, SECONDS))
    ok(rateWrites <= tasks * 2 + 2,
        'and the clip rate is cycled with it, not twice a second -- BEFORE: '
        .. '153 rate writes over the same 40 seconds',
        ('%d rate writes'):format(rateWrites))

    -- THE STEP IS GIVEN BACK. Measured on the ped rather than asserted from
    -- the code: the pair ends where it started.
    ok(math.abs(peds[5001].x - startX) < 1e-9,
        'and the body is exactly where it was put down, not one step further '
        .. 'forward',
        ('%.6fm from the anchor'):format(peds[5001].x - startX))

    -- IT MUST NOT COST THE PLAYER THEIR OWN CRAWL. One frame of dbnoCrawlSpeed
    -- is under a centimetre and it is put straight back, so a watching player
    -- sees nothing -- but the guard that matters is that a real input takes the
    -- frame outright.
    local M = env.BR.Config.Match
    local step = (M.dbnoCrawlSpeed or 0.55) * 0.016
    ok(step < 0.01,
        'the step moves the body less than a centimetre before putting it back',
        ('%.4fm'):format(step))

    -- ...AND A RE-TASK IS THE THING THAT BUYS ANOTHER ONE. Something cancels
    -- the clip -- a car, a blast, a scripted task, the list dbno.controls'
    -- watchdog exists for -- and the watchdog puts it back. That new task is a
    -- new mover on every clone, so it is owed a new step and gets exactly one.
    local before = coordWrites
    anim = nil
    for _ = 1, 120 do
        CLI.now = CLI.now + 16
        CLI.frame()
    end
    ok(tasks == 3, 'the watchdog re-tasks a cancelled crawl',
        ('%d tasks'):format(tasks))
    ok(coordWrites - before == 2,
        'and a re-task -- a FRESH mover on every clone -- buys exactly one '
        .. 'more step, which is what makes the arm an event and not a clock',
        ('%d writes for the re-task'):format(coordWrites - before))

    -- ...AND IT STOPS DEAD WHEN THEY STAND UP.
    before = coordWrites
    env.TriggerEvent(env.BR.Net.DBNO_SET, { downed = false })
    for _ = 1, 120 do
        CLI.now = CLI.now + 16
        CLI.frame()
    end
    ok(coordWrites == before,
        'and a player who is back on their feet is not being written at all',
        ('%d more writes after standing up'):format(coordWrites - before))
end

-- THE CREEP ITSELF, IN METRES.
--
-- The frame that loses half a pair is not a hypothetical: dbno.controls drops
-- `hold` and returns on any frame reading IsPedRagdoll or IsEntityInAir, and a
-- downed body on a slope, a staircase, a kerb or a rock reads in-air
-- intermittently. Modelled here as one frame in thirty -- and the model is
-- stated rather than hidden, because the NUMBER depends on it and the SHAPE
-- does not: on a beat the leak is paid twice a second for the whole bleed, and
-- on a one-shot it can be paid at most once per task, whatever the frequency.
describe('dbno.clone.creep')
do
    local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                   [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
    local CLI = newReviver(1, 2, peds)
    local env = CLI.env

    env.SetEntityCoordsNoOffset = function(_, x, y, z)
        peds[5001].x, peds[5001].y, peds[5001].z = x, y, z
    end
    local anim = nil
    env.TaskPlayAnim = function(_, d, a) anim = d .. '/' .. a end
    env.IsEntityPlayingAnim = function() return anim ~= nil end

    -- ONE FRAME IN THIRTY, FROM THE FIRST FRAME OF THE WINDOW. Not tuned to
    -- miss the pair and not tuned to hit it: 30 frames and the old 500ms beat
    -- (~31 frames) are close enough to be out of phase with each other, so the
    -- leak lands where it lands. Both builds face exactly this hazard, from the
    -- same moment, for the same 40 seconds.
    local frames = 0
    env.IsEntityInAir = function() return frames > 0 and frames % 30 == 0 end

    env.TriggerEvent(env.BR.Net.DBNO_SET,
        { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })

    local SECONDS = 40
    for _ = 1, SECONDS * 62 do
        frames = frames + 1
        CLI.now = CLI.now + 16
        CLI.frame()
    end

    local drift = math.sqrt(peds[5001].x ^ 2 + peds[5001].y ^ 2)
    -- One step is 9.2mm. A one-shot can leak at most that, once.
    ok(drift <= 0.02,
        'a body that loses a frame mid-step gives up one step and no more -- '
        .. 'BEFORE: 0.026m over the SHORTEST knock the config can produce, '
        .. 'because the beat re-offered the leak 76 times and this one-shot '
        .. 'offers it twice',
        ('%.3fm over %ds'):format(drift, SECONDS))
end

-- ==========================================================================
-- A FIVEM NATIVE DECLARED BOOL CAN ANSWER `1`, AND IN LUA `0` IS TRUTHY.
-- ==========================================================================
--
-- client/dbno.lua turns TWO things on IsEntityPlayingAnim -- the watchdog that
-- puts a cancelled crawl back, and the cover over the resurrection's standing
-- frame -- and both read it raw. On a build that hands numbers back:
--
--     if not force and IsEntityPlayingAnim(...) then return end
--
-- reads `not 0` as FALSE, so the watchdog decides the clip is running and
-- returns, every frame, forever. A car knocks the pose off a downed player and
-- nothing ever puts it back: they lie there in whatever the collision left them
-- in for the rest of the bleed, and the clone resync -- which is armed by
-- playCrawl and by nothing else -- is never armed again either.
--
-- THIS IS THE THIRD TIME THIS EXACT MISTAKE HAS BEEN MADE IN THIS CODEBASE
-- (client/natives.lua on the shape test, client/spawn.lua on the screen fade,
-- and dbno.lua's own `didHit` was written for the first one). Every rig in this
-- file answered `true`/`false`, which is why none of them could see it.
--
-- IT IS ASSERTED HERE RATHER THAN IN dbno.cover, and that distinction is the
-- point: with a settle on the cover, the numeric bug only moves the moment of
-- confirmation by one frame and the cover still covers. The watchdog is where
-- it is load-bearing, so the watchdog is where the axis lives.
describe('dbno.crawl.watchdog')
do
    local SHAPES = {
        { name = 'true/false', yes = true, no = false },
        { name = '1/0',        yes = 1,    no = 0     },
    }

    for _, shape in ipairs(SHAPES) do
        local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                       [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
        local CLI = newReviver(1, 2, peds)
        local env = CLI.env

        local tasks, anim = 0, nil
        env.TaskPlayAnim = function(_, d, a) tasks = tasks + 1 anim = d .. '/' .. a end
        env.IsEntityPlayingAnim = function()
            return anim ~= nil and shape.yes or shape.no
        end
        local steps = 0
        env.SetEntityCoordsNoOffset = function(_, x, y, z)
            steps = steps + 1
            peds[5001].x, peds[5001].y, peds[5001].z = x, y, z
        end

        local function run(n)
            for _ = 1, n do CLI.now = CLI.now + 16 CLI.frame() end
        end

        env.TriggerEvent(env.BR.Net.DBNO_SET,
            { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })
        run(120)

        local settled = tasks
        ok(settled > 0,
            ('a knock poses the body when the native answers %s'):format(shape.name),
            ('%d tasks'):format(settled))

        -- ...AND THE CLIP IS THEN CANCELLED BY SOMETHING THAT IS NOT US: a car,
        -- a blast, a scripted task. The list dbno.controls' watchdog exists for.
        anim = nil
        local beforeSteps = steps
        run(120)

        ok(tasks == settled + 1,
            ('AND THE WATCHDOG PUTS IT BACK when the native answers %s -- '
             .. 'BEFORE: `not 0` is false, so a build answering numbers left a '
             .. 'downed player in whatever pose the car left them in for the '
             .. 'rest of the bleed'):format(shape.name),
            ('%d tasks after the clip was cancelled'):format(tasks - settled))

        -- ...AND THE CLONES ARE TOLD, which is the same failure wearing its
        -- other face: resyncArm is called by playCrawl and by nothing else, so
        -- a watchdog that never fires is also a clone that is never corrected.
        ok(steps - beforeSteps == 2,
            ('and the re-task buys exactly one clone-resync pair on %s')
                :format(shape.name),
            ('%d writes'):format(steps - beforeSteps))
    end
end

-- ==========================================================================
-- #164 REGRESSION: A KNOCKED BODY WALKS OFF WITH NOBODY DRIVING IT.
-- ==========================================================================
--
-- "there's a bug again where DBNO players move immediately after going DBNO
-- when not being commanded to, and that translates to desync in their ped's
-- location between screens." (owner, 2026-08-19, playtested.)
--
-- WHY EVERY RIG ABOVE IS BLIND TO IT, which is the whole reason this is a new
-- block and not another assertion inside dbno.clone.sync. All of them stub the
-- engine like this:
--
--     env.TaskPlayAnim        = function(_, d, a) anim = d .. '/' .. a end
--     env.IsEntityPlayingAnim = function() return anim ~= nil end
--
-- The clip is confirmed running ON THE SAME FRAME IT WAS TASKED. That is not a
-- simplification, it is the one thing client/dbno.lua's own comments say cannot
-- happen -- "A task issued this tick has not been evaluated yet, so
-- IsEntityPlayingAnim on the same frame is answering about the pose we are
-- trying to hide" -- and it is why that file budgets a FULL SECOND of cover for
-- the transition (POSE_SETTLE_MS, citizenfx/fivem#2236). With the latency
-- stubbed to zero the watchdog can never fire more than once, so the fault
-- below is unreachable in every fixture that exists.
--
-- WHAT THE LATENCY BUYS. `playCrawl(false)` is called from dbno.controls on the
-- FRAME band and has no rate limit of its own, so for as long as the engine has
-- not admitted the clip, it issues a task per frame. Every task calls
-- resyncArm(), and resyncArm sets `resyncPhase = 0` -- which does not just arm a
-- new step, it ABANDONS the half of the pending pair that puts the body back.
-- The next frame's `phase 1` then measures its step from `c`, the ped's CURRENT
-- position, which already contains the step before it. So the body advances one
-- frame of dbnoCrawlSpeed per frame -- the full crawl speed, in the direction it
-- is facing, with nothing pressed -- for the whole of the transition window.
-- Every one of those steps is a real SetEntityCoordsNoOffset on a networked
-- entity, which is the second half of the owner's sentence.
--
-- THE ASSERTION IS AN INVARIANT AND NOT A BUDGET, because a budget is how this
-- area has produced five rounds of green over a moving body: while the player
-- presses nothing, EVERY position this file writes must be within one crawl
-- step of the spot they were put down on. One step is what the clone resync is
-- allowed to spend and there is nothing else in the file entitled to move them.
-- It is measured off the ped the rig actually keeps, not off a call count.
describe('dbno.quiet.body')
do
    -- HOW MANY FRAMES THE ENGINE TAKES TO ADMIT THE CLIP IS ON THE PED.
    --
    -- 1 is the floor and it is not a guess -- holdCover is built on the task not
    -- being evaluated within its own tick. 62 is one POSE_SETTLE_MS at the
    -- rig's frame rate, which is client/dbno.lua's own estimate of the far side
    -- of the transition. `false` is the build where the pose never lands at all:
    -- a downed ped with no clip is a real configuration this file handles
    -- deliberately (`crawl == false`), and it must not be a moving one.
    for _, LAT in ipairs({ 1, 8, 62, 'never' }) do
        local label = tostring(LAT)
        local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                       [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
        local CLI = newReviver(1, 2, peds)
        local env = CLI.env

        -- THE ENGINE'S ANSWER ARRIVES LATE. Nothing else about the stub
        -- changes: the task is accepted, the dictionary loads, the ped poses.
        local frames, taskedAt = 0, nil
        env.TaskPlayAnim = function() taskedAt = frames end
        env.IsEntityPlayingAnim = function()
            if LAT == 'never' then return false end
            return taskedAt ~= nil and (frames - taskedAt) >= LAT
        end

        -- A REAL PED. Writes land on it and the worst excursion is kept --
        -- the FINAL position is not the measurement, because the pair puts the
        -- body back and a test that only looked at the end would call a body
        -- that crawled half a metre and returned "stationary".
        local worst, writes = 0.0, 0
        env.SetEntityCoordsNoOffset = function(_, x, y, z)
            writes = writes + 1
            peds[5001].x, peds[5001].y, peds[5001].z = x, y, z
            local d = math.sqrt(x * x + y * y)
            if d > worst then worst = d end
        end

        env.TriggerEvent(env.BR.Net.DBNO_SET,
            { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })

        -- NOTHING IS TOUCHED FOR FORTY SECONDS. GetDisabledControlNormal is
        -- the rig's own 0.0 on both axes throughout -- no forward, no turn --
        -- and 40s is dbnoBleedMin, the shortest knock config/match.lua can
        -- produce.
        local SECONDS = 40
        for _ = 1, SECONDS * 62 do
            frames = frames + 1
            CLI.now = CLI.now + 16
            CLI.frame()
        end

        local M    = env.BR.Config.Match
        local STEP = (M.dbnoCrawlSpeed or 0.55) * 0.016

        ok(worst <= STEP * 1.5,
            ('a knocked player who presses nothing does not travel, with the '
             .. 'pose confirmed %s frame(s) late -- BEFORE: the watchdog tasked '
             .. 'the crawl every frame of the transition, each task abandoned '
             .. 'the step-back and re-armed a step measured from the stepped-out '
             .. 'position, so the body crawled at full speed with nobody '
             .. 'driving it'):format(label),
            ('%.3fm from the anchor, one step is %.4fm (%d position writes)')
                :format(worst, STEP, writes))

        -- ...AND IT ENDS WHERE IT STARTED. The invariant above already implies
        -- this, but the owner's report has two halves and this is the one they
        -- can see on their own screen.
        local restX, restY = peds[5001].x, peds[5001].y
        ok(math.sqrt(restX * restX + restY * restY) <= STEP * 1.5,
            ('and it comes to rest on the spot it was put down on (%s)')
                :format(label),
            ('%.3fm'):format(math.sqrt(restX * restX + restY * restY)))
    end

    -- AND THE TASK STORM ITSELF, counted rather than inferred. The body being
    -- still is the report; sixty TaskPlayAnims a second is the cause, and it is
    -- worth an assertion of its own because it is also sixty fresh movers a
    -- second on every clone -- which is the "desync between screens" half.
    do
        local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                       [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
        local CLI = newReviver(1, 2, peds)
        local env = CLI.env

        local tasks = 0
        env.TaskPlayAnim = function() tasks = tasks + 1 end
        -- The pose never lands. This is the build client/dbno.lua's `crawl ==
        -- false` branch exists for, arrived at from the other direction.
        env.IsEntityPlayingAnim = function() return false end
        env.SetEntityCoordsNoOffset = function(_, x, y, z)
            peds[5001].x, peds[5001].y, peds[5001].z = x, y, z
        end

        env.TriggerEvent(env.BR.Net.DBNO_SET,
            { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })

        local SECONDS = 10
        for _ = 1, SECONDS * 62 do
            CLI.now = CLI.now + 16
            CLI.frame()
        end

        -- FOUR A SECOND IS THE CEILING, and the number is not invented here:
        -- RETASK_EVERY_MS is already the file's own answer to "a spin cannot
        -- re-task per frame" and this is the same limit applied to the watchdog,
        -- which never had one. Read out of the file rather than copied, because
        -- copying a constant is how this repo has produced green over broken
        -- code before.
        local f = io.open(RES .. 'br_core/client/dbno.lua', 'r')
        local src = f and f:read('a') or ''
        if f then f:close() end
        local every = tonumber(src:match('local RETASK_EVERY_MS%s*=%s*(%d+)'))
        ok(every ~= nil, 'RETASK_EVERY_MS is readable out of client/dbno.lua',
            tostring(every))
        local ceiling = math.ceil((SECONDS * 1000) / (every or 250)) + 2
        ok(tasks <= ceiling,
            'a clip that never confirms is re-posed on the file\'s own retask '
            .. 'interval, not once per frame -- BEFORE: 620 tasks in 10s, one '
            .. 'per frame, each one a fresh mover on every clone',
            ('%d tasks in %ds, ceiling %d'):format(tasks, SECONDS, ceiling))
    end

    -- A RATE LIMIT IS NOT A BOUND, AND THIS IS THE HALF THAT ASSERTS THE BOUND.
    --
    -- RETASK_EVERY_MS stops the arm firing sixty times a second. It does NOT say
    -- anything about what one arm is allowed to do to the body, and the reason
    -- the regression was 21.8 metres rather than 9mm is that the step was
    -- RELATIVE -- measured from wherever the ped had already been pushed to --
    -- and that a fresh arm THREW AWAY the half of the pair that puts the body
    -- back. Both of those are still wrong on a build where the throttle never
    -- bites, and a suite that only owned the throttle would go green over them.
    --
    -- SO THE CLOCK IS TURNED UP UNTIL THE THROTTLE STOPS BITING. Every frame
    -- here is longer than RETASK_EVERY_MS, so every frame is allowed to re-task
    -- and every frame arms a step -- which is the exact per-frame arm the
    -- regression had. This is not a contrivance for the sake of one: a FiveM
    -- client hitching into single-digit frame rates while the streamer catches
    -- up is ordinary, and a knock is one of the moments it happens.
    --
    -- On a build where the step is measured from the ANCHOR and a pending pair
    -- is finished rather than abandoned, the body cannot travel however often
    -- the arm fires. That is the claim, and it is the claim the owner's
    -- sentence actually needs.
    --
    -- WHAT EACH OF THE TWO IS WORTH, priced against the real file one revert at
    -- a time rather than asserted, because they are NOT worth the same and a
    -- comment that implied they were would be the next round's wrong turn:
    --
    --   step from `c`,    pair abandoned   33.000 m   the regression, unbounded
    --   step from `c`,    pair finished     0.165 m   one step -- the pair's own
    --   step from `hold`, pair abandoned    0.330 m   two steps -- bounded
    --   step from `hold`, pair finished     0.165 m   one step -- shipped
    --
    -- SO: FINISHING THE PAIR IS THE FIX. Measuring the step from the anchor
    -- fixes nothing on top of it -- both bottom rows are one step, which is the
    -- excursion the resync exists to make. What it buys is the THIRD row: if
    -- anything ever re-introduces an arm that abandons a pair, the cost is two
    -- steps instead of thirty-three metres. That is a bound, not a fix, and it
    -- is written down as one. Only the assertion below is load-bearing on it,
    -- and only in company with the abandon -- which is exactly why the
    -- both-reverted row is the one this block is aimed at.
    do
        local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                       [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
        local CLI = newReviver(1, 2, peds)
        local env = CLI.env

        -- A HITCHING CLIENT: one frame every 300ms, and GetFrameTime says so.
        -- Leaving the frame time at 0.016 would be a rig lying to the code
        -- about its own clock, and the step length is computed from it.
        local FRAME_MS = 300
        env.GetFrameTime = function() return FRAME_MS / 1000.0 end

        env.TaskPlayAnim = function() end
        env.IsEntityPlayingAnim = function() return false end

        local worst = 0.0
        env.SetEntityCoordsNoOffset = function(_, x, y, z)
            peds[5001].x, peds[5001].y, peds[5001].z = x, y, z
            local d = math.sqrt(x * x + y * y)
            if d > worst then worst = d end
        end

        env.TriggerEvent(env.BR.Net.DBNO_SET,
            { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })

        for _ = 1, 200 do
            CLI.now = CLI.now + FRAME_MS
            CLI.frame()
        end

        local M    = env.BR.Config.Match
        local STEP = (M.dbnoCrawlSpeed or 0.55) * (FRAME_MS / 1000.0)
        ok(worst <= STEP * 1.5,
            'and an arm that fires on EVERY frame still cannot walk the body: '
            .. 'a pending pair is finished rather than abandoned, so the step '
            .. 'back is never dropped, and the step out is measured from the '
            .. 'anchor, so nothing it does can compound -- BEFORE: 33m in 60s',
            ('%.3fm from the anchor over %d frames, one step is %.3fm')
                :format(worst, 200, STEP))
    end

    -- AND THE ANCHOR ITSELF IS NOT DROPPED BY A NATIVE ANSWERING `0`.
    --
    -- dbno.controls drops `hold` and returns on any frame reading IsPedRagdoll
    -- or IsEntityInAir, and both were read RAW. On a build that answers numbers
    -- that branch is taken on EVERY frame -- `0` is truthy -- so `hold` never
    -- exists, stayPut is never reached, and the one thing in this file that
    -- measures the ped's position and puts it back is switched off for the whole
    -- bleed. Same shape as the shape test, the screen fade and the crawl
    -- watchdog before it; this is the fourth.
    for _, shape in ipairs({ { name = 'true/false', yes = true, no = false },
                             { name = '1/0',        yes = 1,    no = 0     } }) do
        local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                       [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
        local CLI = newReviver(1, 2, peds)
        local env = CLI.env

        env.IsPedRagdoll  = function() return shape.no end
        env.IsEntityInAir = function() return shape.no end
        env.SetEntityCoordsNoOffset = function(_, x, y, z)
            peds[5001].x, peds[5001].y, peds[5001].z = x, y, z
        end

        -- THE CLIP'S OWN MOVER, WHICH IS WHAT THE ANCHOR IS FOR. client/dbno.lua
        -- measured it at 1.05m over three seconds and says in as many words that
        -- whether the lock flags suppress it "is the engine's answer". So the
        -- rig gives the worst case -- flags that do nothing -- and the anchor has
        -- to be what stops the body.
        local drift = (0.35 * 0.016)
        env.TriggerEvent(env.BR.Net.DBNO_SET,
            { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })

        for _ = 1, 20 * 62 do
            peds[5001].y = peds[5001].y + drift
            CLI.now = CLI.now + 16
            CLI.frame()
        end

        local M    = env.BR.Config.Match
        local STEP = (M.dbnoCrawlSpeed or 0.55) * 0.016
        local away = math.sqrt(peds[5001].x ^ 2 + peds[5001].y ^ 2)
        ok(away <= STEP * 1.5 + drift,
            ('the anchor holds a body the clip is dragging when the ragdoll '
             .. 'natives answer %s -- BEFORE: `0` is truthy, so `hold` was '
             .. 'cleared on every frame and nothing ever put the body back')
                :format(shape.name),
            ('%.3fm over 20s of a mover the lock flags did not stop'):format(away))
    end
end

-- ==========================================================================
-- #164, SECOND HALF: A CRAWLING BODY TURNS AND THE CLONES DO NOT.
-- ==========================================================================
--
-- "When DBNO and a player crawls, their ped position is not synced with anyone
-- else's screen ... if they go forward, they go forward on everyone's screen.
-- But if they turn, they're still moving forward on other player's screens."
-- (owner, 2026-08-18.)
--
-- WHAT THIS RIG CAN AND CANNOT SEE, SAID FIRST, because the temptation here is
-- to write an assertion about "replication" that no sandbox can honestly make.
-- There is no second machine in this process and there is no engine. What there
-- IS, and what the whole fix turns on, is the record of WHAT WAS PUT ON THE
-- WIRE: a crawl task is the only thing that reaches a clone, client/dbno.lua's
-- own model says so, and the clone crawls along the heading it was holding when
-- it got one. So the question a test can answer exactly is:
--
--     when the body has finished turning, does the last crawl task the clones
--     were given match the direction the body is now facing?
--
-- Before the fix that difference is the whole of the turn -- nothing re-tasks on
-- a heading change, so the last task is the one from the knock. A ninety-degree
-- turn leaves ninety degrees of disagreement, which is exactly the owner's
-- sentence with a number on it.
--
-- AND THE TRAP ON THE OTHER SIDE, which is why the second half of this block is
-- as long as the first: the cure for #164's first half was killing a 500ms beat,
-- because every beat was a 9mm step other machines saw as a twitch. A re-task on
-- a heading change is a beat in disguise unless something stops it firing when
-- nobody turned. So the creep guard is asserted as hard as the fix.
describe('dbno.heading')
do
    local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                   [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
    local CLI = newReviver(1, 2, peds)
    local env = CLI.env
    local M   = env.BR.Config.Match

    -- A REAL HEADING. The reviver rig pins it at 0.0 and stubs the setter,
    -- which is exactly the shape that cannot see this bug: with the heading
    -- constant, "the task is stale by ninety degrees" is unrepresentable.
    local heading = 0.0
    env.GetEntityHeading = function() return heading end
    env.SetEntityHeading = function(_, h) heading = h % 360.0 end

    -- THE TURN AXIS, DRIVEN. controls 30/31 are DISABLED for a downed player
    -- and read back through GetDisabledControlNormal, which is the only reader
    -- there is -- so this IS the player's hand on the stick.
    local lr, ud = 0.0, 0.0
    env.GetDisabledControlNormal = function(_, c)
        if c == 30 then return lr end
        if c == 31 then return ud end
        return 0.0
    end

    -- WHAT THE CLONES WERE TOLD, and when. Every crawl task is recorded with
    -- the heading the body had at the moment it was issued, because that is the
    -- direction the clone will carry the clip's mover along.
    local tasks, anim = {}, nil
    env.TaskPlayAnim = function(_, d, a)
        tasks[#tasks + 1] = { at = CLI.now, h = heading }
        anim = d .. '/' .. a
    end
    env.IsEntityPlayingAnim = function() return anim ~= nil end

    local steps = 0
    env.SetEntityCoordsNoOffset = function(_, x, y, z)
        steps = steps + 1
        peds[5001].x, peds[5001].y, peds[5001].z = x, y, z
    end

    local function run(frames)
        for _ = 1, frames do
            CLI.now = CLI.now + 16
            CLI.frame()
        end
    end

    --- The shortest angle between two headings, the same way dbno.lua measures.
    local function gap(a, b)
        local d = (a - b) % 360.0
        if d > 180.0 then d = 360.0 - d end
        return d
    end

    local function lastTold() return tasks[#tasks] and tasks[#tasks].h or nil end

    env.TriggerEvent(env.BR.Net.DBNO_SET,
        { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })
    run(120)                                   -- settle: the knock's own tasks

    local settledTasks, settledSteps = #tasks, steps
    ok(settledTasks > 0 and gap(heading, lastTold()) < 0.001,
        'a body that has not turned is pointing exactly where the clones were '
        .. 'last told it was pointing',
        ('facing %.1f, told %.1f'):format(heading, lastTold() or -1))

    -- ---------------------------------------------------------------- turn ---
    -- A QUARTER TURN, at the rate the config actually gives a downed player,
    -- and then the stick goes back to centre. dbnoTurnRate is degrees per
    -- second, so this is however many frames that takes and not a magic number.
    local turnFrames = math.ceil((90.0 / (M.dbnoTurnRate or 90.0)) / 0.016)
    lr = -1.0                                  -- negative lr turns clockwise
    run(turnFrames)
    lr = 0.0
    run(60)                                    -- let the settle fire

    ok(gap(heading, 90.0) < 15.0,
        'the player turns about ninety degrees, which is what the rest of this '
        .. 'block is about',
        ('%.1f degrees'):format(heading))

    -- THE HEADLINE. This is the owner's sentence as an equation.
    ok(gap(heading, lastTold()) <= 2.0,
        'AND THE CLONES WERE TOLD ABOUT IT -- the last crawl task on the wire '
        .. 'points the way the body now points. BEFORE: the last task is the '
        .. 'one from the knock, so this gap is the whole of the turn',
        ('facing %.1f, last task said %.1f, gap %.1f')
            :format(heading, lastTold() or -1, gap(heading, lastTold() or 0)))

    -- ...AND IT WENT THROUGH THE MECHANISM THAT WAS ALREADY THERE. One task,
    -- one step: a second resync living beside the first is the thing the #164
    -- follow-on explicitly refused, and this is the equation that catches it.
    ok(steps - settledSteps == (#tasks - settledTasks) * 2,
        'and every task it issued bought exactly one clone-resync pair -- no '
        .. 'second mechanism beside resyncArm',
        ('%d writes for %d tasks')
            :format(steps - settledSteps, #tasks - settledTasks))

    -- ...AND IT IS NOT A CLIP RESTARTED PER FRAME. That bug has shipped here
    -- once already, at 59 re-tasks in 60 frames.
    ok(#tasks - settledTasks <= math.ceil(90.0 / 20.0) + 1,
        'and a ninety-degree sweep costs a handful of tasks, not one per frame',
        ('%d tasks for %d frames of turning')
            :format(#tasks - settledTasks, turnFrames))

    -- --------------------------------------------------------- the guard ---
    -- NOBODY TOUCHED ANYTHING FOR FORTY SECONDS. This is the creep test from
    -- dbno.clone.sync pointed at the new arm: the crawl clip has a rotational
    -- mover of its own, so an arm that watched the ANGLE rather than the HAND
    -- would re-task four times a second forever, and every one of those is a
    -- 9mm step other machines see as a twitch.
    local quietTasks, quietSteps = #tasks, steps
    run(40 * 62)
    ok(#tasks == quietTasks,
        'A QUIET BODY IS NEVER RE-TASKED -- forty seconds, the shortest knock '
        .. 'the config can produce, and nothing is asked of the clones at all',
        ('%d tasks in 40s of nothing'):format(#tasks - quietTasks))
    ok(steps == quietSteps,
        'and no steps either: the arm is the player\'s hand, not a clock',
        ('%d writes'):format(steps - quietSteps))

    -- ...AND A TWITCH OF THE STICK IS NOT A TASK. Below the settle threshold
    -- there is nothing worth telling anybody about, and a body that re-tasked
    -- on a degree would be back on a beat the moment somebody rested a thumb
    -- on an analogue stick.
    local tinyTasks = #tasks
    lr = -0.15                                 -- just past the 0.1 deadzone
    run(2)                                     -- ~0.3 degrees
    lr = 0.0
    run(60)
    ok(#tasks == tinyTasks,
        'and a nudge under the settle threshold is not worth a task',
        ('%d tasks for %.2f degrees')
            :format(#tasks - tinyTasks, gap(heading, 90.0)))

    -- ------------------------------------------------------------- wrap ---
    -- 359 AND 1 ARE TWO DEGREES APART. A gap computed without the wrap is 358
    -- there, which is over every threshold in the file -- so a body steered
    -- across north would re-task on every frame of it, forever, and the creep
    -- would come back in the one place nobody would think to look.
    heading = 350.0
    lr = -0.15
    run(2)
    lr = 0.0
    run(60)                                    -- re-align: the clones are told 350

    local wrapTasks, wrapFrames = #tasks, 40
    lr = -1.0
    run(wrapFrames)                            -- a long sweep across 0/360
    lr = 0.0
    run(60)
    ok(#tasks - wrapTasks <= math.ceil(
            (wrapFrames * 0.016 * (M.dbnoTurnRate or 90.0)) / 20.0) + 1,
        'and steering across north costs one task per twenty degrees, not one '
        .. 'per frame: the gap is the SHORT way round, so 359 and 1 are two '
        .. 'degrees apart and not three hundred and fifty-eight',
        ('%d tasks for %d frames of turning, now facing %.1f')
            :format(#tasks - wrapTasks, wrapFrames, heading))
    ok(gap(heading, lastTold()) <= 2.0,
        'and the clones are still told the truth across the wrap',
        ('facing %.1f, told %.1f'):format(heading, lastTold() or -1))

    -- ...AND STANDING UP ENDS IT. A revived player owes the clones nothing,
    -- and a stale taskHeading would re-task the first crawl of the NEXT knock.
    local upTasks = #tasks
    env.TriggerEvent(env.BR.Net.DBNO_SET, { downed = false })
    lr = -1.0
    run(120)
    ok(#tasks == upTasks,
        'and a player on their feet is not tasked by the turn watchdog at all',
        ('%d tasks after standing up'):format(#tasks - upTasks))
end

-- ==========================================================================
-- THE STANDING FRAME BETWEEN DYING AND THE DOWNED POSE.
-- ==========================================================================
--
-- "When going from alive -> DBNO the ped briefly stands between the moment of
-- dying, reviving, and going to the emote we chose. During that period we
-- should have the ped be briefly invisible instead." (owner, 2026-08-18.)
--
-- THIS IS THE SECOND ATTEMPT AT THIS FRAME AND THE FIRST ONE'S ARGUMENT IS THE
-- REASON IT NEEDS A TEST. floorTheBody() carried a note saying the frame could
-- not exist: "NOTHING YIELDS INSIDE THIS. Nothing is rendered in the middle of a
-- tick, so the standing idle a resurrection restores is overwritten before it
-- can be drawn once." Every word of that is true and the conclusion does not
-- follow -- TaskPlayAnim QUEUES a task, the engine evaluates the task tree after
-- the tick, and the ped renders the pose it already has until then. The rig now
-- models that (see pedFrame, rule 5), which is what lets this block fail against
-- the ordering-only build and pass against the cover.
--
-- WHAT IS ASSERTED IS THE OWNER'S SENTENCE AND NOT THE MECHANISM: across a fall
-- in every timing the matrix above uses, there is no frame on which a downed
-- player's ped is standing (resurrected, no downed clip) AND visible.
-- THE COVER'S OWN NUMBERS, READ OUT OF THE FILE THAT OWNS THEM.
--
-- They are file-locals, so a suite that wanted them had exactly two choices:
-- copy them, or read them. Copying is how this repo has produced green runs
-- over broken code before -- the test re-encodes the assumption the code makes
-- and the pair agree with each other about something that is not true. Read
-- here, retuning the cover in dbno.lua retunes what the assertions expect,
-- while the one thing that is a JUDGEMENT rather than a mechanism -- "about a
-- second" -- is asserted against a literal below, where changing it is visible.
local COVER_SETTLE_MS, COVER_CAP_MS
do
    local f = io.open(RES .. 'br_core/client/dbno.lua', 'r')
    local text = f and f:read('a') or ''
    if f then f:close() end
    COVER_SETTLE_MS = tonumber(text:match('local POSE_SETTLE_MS = (%d+)'))
    COVER_CAP_MS    = tonumber(text:match('local HIDE_MAX_MS = (%d+)'))
end

describe('dbno.cover')
do
    ok(COVER_SETTLE_MS ~= nil and COVER_CAP_MS ~= nil,
        'the cover\'s settle and cap are readable from client/dbno.lua',
        ('settle %s, cap %s'):format(tostring(COVER_SETTLE_MS),
                                     tostring(COVER_CAP_MS)))
    COVER_SETTLE_MS = COVER_SETTLE_MS or 0
    COVER_CAP_MS    = COVER_CAP_MS or 0

    -- THE OWNER'S NUMBER, AS A NUMBER. "Let's just make the invisibility time
    -- like 1 more second or so -- should be enough for their ped to be in the
    -- crawl position by then" (2026-08-18). The mechanism is asserted below;
    -- this is the only place the SIZE of it is written down twice on purpose,
    -- because shrinking it back to a frame is the regression that would leave
    -- every mechanical assertion green and the owner still watching a ped stand.
    ok(COVER_SETTLE_MS >= 750,
        'the cover outlives the clip landing by about a second, which is the '
        .. 'owner\'s own instruction and not something the engine reports',
        ('%dms'):format(COVER_SETTLE_MS))
    ok(COVER_CAP_MS > COVER_SETTLE_MS,
        'and the cap is longer than the settle, or the settle could never run',
        ('cap %dms vs settle %dms'):format(COVER_CAP_MS, COVER_SETTLE_MS))

    local SETTLES = { 32, 96, 200, 320 }
    local STREAMS = { 0, 250 }
    local rtt = 60

    -- A FIVEM NATIVE DECLARED BOOL CAN ANSWER `1`, AND IN LUA `0` IS TRUTHY.
    --
    -- Every cell in the matrix that shipped the cover ran against a rig whose
    -- IsEntityPlayingAnim returned a Lua BOOLEAN, so the shape the natives
    -- actually vary in was never exercised at all. It is a cell now.
    --
    -- WHAT THIS AXIS DOES AND DOES NOT CATCH, because an axis that cannot fail
    -- is worse than no axis -- it reads as coverage. WITH the settle in place,
    -- reading the native raw only moves the moment of confirmation by one frame
    -- and the cover still covers: none of the assertions below can tell the two
    -- builds apart, and the revert check says so. The place that read is
    -- load-bearing is the crawl WATCHDOG (`not 0` is false, so it returns and
    -- never re-poses), and that is asserted in dbno.crawl.watchdog, which does
    -- fail on the raw read. This axis is here because both builds must behave
    -- identically and it costs one table to say so.
    local BOOLS = {
        { name = 'boolean', yes = true, no = false },
        { name = 'number',  yes = 1,    no = 0     },
    }

    local exposed, exposedWhere = 0, nil
    local cells = 0
    local neverCovered, neverCoveredWhere = 0, nil
    local droppedAtOnce, droppedWhere = 0, nil
    local overCap, overCapWhere = 0, nil
    local stuckHidden, stuckWhere = 0, nil
    local settleLow, settleHigh, settleWhere = nil, nil, nil

    for _, settle in ipairs(SETTLES) do
    for _, stream in ipairs(STREAMS) do
    for _, bool in ipairs(BOOLS) do
        cells = cells + 1
        local where = ('settle %dms, streaming %dms, BOOL as %s')
            :format(settle, stream, bool.name)

        local SRV = newServer()
        local CLI = newClient(settle, stream)
        local env = CLI.env
        local P   = CLI.ped

        env.IsEntityPlayingAnim = function()
            return P.anim ~= nil and bool.yes or bool.no
        end

        -- HIDDEN IS A FRAME, NOT A PROPERTY, and the rig has to hold it the
        -- same way the engine does: set during this tick, gone by the next.
        local hiddenNow = false
        env.SetEntityLocallyInvisible = function() hiddenNow = true end

        -- WHEN THE POSE LANDED AND WHEN THE COVER CAME DOWN. The gap between
        -- them is the fix: it used to be zero by construction.
        --
        -- PER EPISODE, and that is not bookkeeping pedantry. A knock can raise
        -- the cover TWICE -- the resurrection is one, and a live knock's ragdoll
        -- releasing into a getup is the other -- and measuring first-raise to
        -- last-hidden across both reports a single 2.4s cover that never
        -- happened. Each window is stamped and capped on its own.
        local posedAt, coverUpAt, lastHiddenAt = nil, nil, nil
        local coveredFrames, episodes = 0, 0
        local worstSpan, worstHeld, bestHeld = 0, nil, nil

        local function closeEpisode()
            if not coverUpAt then return end
            episodes = episodes + 1
            local span = lastHiddenAt - coverUpAt
            if span > worstSpan then worstSpan = span end
            if posedAt then
                local held = lastHiddenAt - posedAt
                if not worstHeld or held > worstHeld then worstHeld = held end
                if not bestHeld  or held < bestHeld  then bestHeld  = held end
            end
            posedAt, coverUpAt, lastHiddenAt = nil, nil, nil
        end

        local wire = {}
        local function drain(now)
            hiddenNow = false          -- before the tick, every tick
            SRV.tick(now)
            for i = 1, #SRV.out do
                local m = SRV.out[i]
                wire[#wire + 1] = { at = now + rtt, event = m.event,
                                    target = m.target, payload = m.payload }
            end
            for i = #SRV.out, 1, -1 do SRV.out[i] = nil end
            while wire[1] and now >= wire[1].at do
                local m = table.remove(wire, 1)
                env.BR.State.me.state = SRV.roster[1].state
                if m.target == 1 or m.target == -1 then
                    env.TriggerEvent(m.event, m.payload)
                end
            end
            for i = 1, #CLI.toServer do
                local m = CLI.toServer[i]
                if now >= m.at + rtt then
                    SRV.roster[1].engineHp = env.GetEntityHealth(1)
                    SRV.died(1, m.data)
                    CLI.toServer[i] = nil
                end
            end
            local kept = {}
            for i = 1, #CLI.toServer do
                if CLI.toServer[i] then kept[#kept + 1] = CLI.toServer[i] end
            end
            CLI.toServer = kept
        end

        -- THE VERDICT IS TAKEN AT THE END OF THE TICK, which is why this is a
        -- registered callback and not the pump's onFrame hook: onFrame runs
        -- BEFORE the frame band, and the whole question is what dbno.controls
        -- did during it. Registration order is execution order (BR.Loop), so
        -- appending here puts this after every dbno callback.
        local run = 0
        env.BR.Loop.register(env.BR.Loop.FRAME, 'test.cover', function()
            run = run + 1
            if SRV.roster[1].state ~= env.BR.PlayerState.DBNO then return end

            -- STANDING: RESURRECTED, alive, and wearing no downed clip. All
            -- three, and the first one is the one that makes this the owner's
            -- frame rather than a different one. Before the resurrection the
            -- ped is dying on the floor -- GTA's own death animation, which is
            -- what a player who just fell off a building is supposed to see and
            -- is not what "the ped briefly stands" describes. The frame under
            -- test is the one AFTER NetworkResurrectLocalPlayer has put a
            -- standing idle back on a body that is about to be re-posed.
            local standing = CLI.resurrects > 0 and not P.dead
                             and P.anim == nil
            if standing and not hiddenNow then
                exposed = exposed + 1
                exposedWhere = exposedWhere or where
            end
            if hiddenNow then
                coveredFrames = coveredFrames + 1
                coverUpAt     = coverUpAt or CLI.now
                lastHiddenAt  = CLI.now
                -- THE POSE LANDING IS A MOMENT, and it is the one the settle is
                -- measured from. Only while a cover is actually up, so a clip
                -- still running an hour later is not mistaken for one.
                if P.anim ~= nil and not posedAt then posedAt = CLI.now end
            else
                closeEpisode()
            end
        end)

        CLI.pump(6000, drain)
        CLI.fall()
        CLI.pump(4000, drain)
        closeEpisode()

        if coveredFrames == 0 then
            neverCovered, neverCoveredWhere = neverCovered + 1,
                                              neverCoveredWhere or where
        end
        if hiddenNow then
            stuckHidden, stuckWhere = stuckHidden + 1, stuckWhere or where
        end
        if worstSpan > COVER_CAP_MS + 32 then
            overCap, overCapWhere = overCap + 1,
                overCapWhere or ('%s (%dms across %d episodes)')
                    :format(where, worstSpan, episodes)
        end
        -- THE ASSERTION THE OLD BUILD CANNOT PASS. It uncovered on the frame
        -- the clip was confirmed, so this difference was one frame -- 16ms --
        -- in every cell. It is now the settle.
        if bestHeld then
            if bestHeld <= 32 then
                droppedAtOnce, droppedWhere = droppedAtOnce + 1,
                                              droppedWhere or where
            end
            if not settleLow or bestHeld < settleLow then
                settleLow, settleWhere = bestHeld, where
            end
            if not settleHigh or worstHeld > settleHigh then
                settleHigh = worstHeld
            end
        end
    end
    end
    end

    -- THE HEADLINE, and the owner's sentence turned into an assertion.
    ok(exposed == 0,
        'A RESURRECTED PED IS NEVER SEEN STANDING -- across every settle, '
        .. 'streaming and BOOL-shape cell, no frame renders a downed player '
        .. 'upright and visible',
        exposedWhere and ('%d frames, e.g. %s'):format(exposed, exposedWhere)
                     or nil)

    ok(neverCovered == 0,
        'and the cover really was raised in EVERY cell -- including the builds '
        .. 'where IsEntityPlayingAnim answers 1/0 rather than true/false, on '
        .. 'which the raw read uncovered on its first look because 0 is truthy',
        neverCoveredWhere and ('%d/%d cells never covered, e.g. %s')
            :format(neverCovered, cells, neverCoveredWhere) or nil)

    -- ...AND THE CLIP RUNNING IS NOT THE BODY BEING DOWN (owner, 2026-08-18:
    -- "I do still see the DBNO player stand briefly"). TaskPlayAnim makes a ped
    -- leave its current state before entering the clip (citizenfx/fivem#2236),
    -- so confirmation is the start of the transition. The cover has to outlive
    -- it.
    ok(droppedAtOnce == 0,
        'AND THE COVER OUTLIVES THE CLIP LANDING -- confirmation starts the '
        .. 'settle rather than ending the cover, which is the frame the owner '
        .. 'could still see',
        droppedWhere and ('%d/%d cells uncovered within a frame of the pose, '
                          .. 'e.g. %s'):format(droppedAtOnce, cells, droppedWhere)
                     or ('held %d-%dms past the pose, settle is %dms')
                          :format(settleLow or -1, settleHigh or -1,
                                  COVER_SETTLE_MS))

    -- ...AND IT IS STILL A COVER, NOT A DISAPPEARANCE. An invisible downed
    -- player is the worse bug, and it is the one that reads as an exploit.
    ok(stuckHidden == 0,
        'and nothing is left invisible: every cell ends with a visible body',
        stuckWhere and ('%d cells, e.g. %s'):format(stuckHidden, stuckWhere)
                   or nil)
    ok(overCap == 0,
        ('and no cell holds the cover past the %dms cap'):format(COVER_CAP_MS),
        overCapWhere and ('%d cells, e.g. %s'):format(overCap, overCapWhere)
                     or nil)
    ok(settleHigh ~= nil and settleHigh <= COVER_SETTLE_MS + 32,
        'and the thing that ends it is the settle rather than the cap -- a '
        .. 'cover that runs to the cap in the ordinary case is a confirmation '
        .. 'that never fired',
        ('longest hold past the pose %sms, settle %dms')
            :format(tostring(settleHigh), COVER_SETTLE_MS))
end

-- ==========================================================================
-- THE OTHER STANDING FRAME: A LIVE KNOCK'S RAGDOLL LETTING GO.
-- ==========================================================================
--
-- The cover shipped hung off floorTheBody, so only the FALL path ever had one.
-- A live knock -- shot, not killed -- never resurrects: it ragdolls for
-- 1200-1600ms and then re-poses. A ped coming out of a ragdoll runs a GETUP,
-- which is the engine standing the body up in front of everybody, and the crawl
-- is tasked over the top of it. That is the same frame the owner is describing
-- ("the ped briefly stands ... and going to the emote we chose") arriving down
-- the other road, and being SHOT is by far the commoner way to be knocked down.
--
-- THE RAGDOLL ITSELF IS DELIBERATELY NOT COVERED and this block asserts that
-- too: falling over is the knock, and it is the one part of this the whole
-- state exists to let an enemy across the street see.
describe('dbno.cover.knockdown')
do
    local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                   [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
    local CLI = newReviver(1, 2, peds)
    local env = CLI.env

    -- A REAL RAGDOLL, because the branch under test is the beat it lands on.
    local ragdollUntil = nil
    env.BR.Native.knockdown = function(ms) ragdollUntil = CLI.now + (ms or 1200) end
    env.IsPedRagdoll = function()
        return ragdollUntil ~= nil and CLI.now < ragdollUntil
    end

    local tasks, anim = {}, nil
    env.TaskPlayAnim = function(_, d, a)
        tasks[#tasks + 1] = CLI.now
        anim = d .. '/' .. a
    end
    env.IsEntityPlayingAnim = function() return anim ~= nil end

    local hidden = {}
    env.SetEntityLocallyInvisible = function() hidden[#hidden + 1] = CLI.now end

    local function run(n)
        for _ = 1, n do CLI.now = CLI.now + 16 CLI.frame() end
    end

    -- A KNOCK THAT LEAVES THE PED ALIVE. IsEntityDead and IsPedFatallyInjured
    -- both answer false in this rig, so enterDowned takes the LIVE branch --
    -- which is the one with the knockdown in it and the one that had no cover.
    env.TriggerEvent(env.BR.Net.DBNO_SET,
        { downed = true, bleedEndsAt = 120000, revivePct = 0.0 })

    local knockAt = CLI.now
    run(40)                              -- ~640ms: mid-ragdoll
    local duringRagdoll = #hidden

    run(90)                              -- past the 1200ms landing
    local landed = tasks[#tasks]

    ok(#tasks >= 2,
        'the knockdown lands and the crawl is re-tasked from where the body '
        .. 'came to rest',
        ('%d tasks'):format(#tasks))

    local afterLanding = 0
    for _, t in ipairs(hidden) do
        if landed and t >= landed - 32 then afterLanding = afterLanding + 1 end
    end
    ok(afterLanding > 0,
        'AND THAT RE-POSE IS COVERED -- BEFORE: the cover hung off '
        .. 'floorTheBody, so a player who was SHOT rather than killed by the '
        .. 'world had no cover at all over the getup between the ragdoll '
        .. 'releasing and the crawl landing',
        ('%d covered frames at or after the re-task'):format(afterLanding))

    ok(duringRagdoll == 0,
        'and the ragdoll itself is NOT covered: falling over is the knock, and '
        .. 'it is the signal the whole state exists to send',
        ('%d covered frames during the ragdoll'):format(duringRagdoll))

    -- ...AND IT COMES DOWN AGAIN. Everything else about the cover is asserted
    -- in dbno.cover; this is only that the second raise is not a leak. Run well
    -- past the settle first -- the assertion is that it ENDS, not that it has
    -- already ended at some arbitrary frame.
    run(150)                             -- 2400ms: past settle and past the cap
    local before = #hidden
    run(200)
    ok(#hidden == before,
        'and the cover comes down after the settle, exactly like the other one',
        ('%d more covered frames three seconds later'):format(#hidden - before))
    ok(before > afterLanding,
        'having actually held it for a while first, rather than for one frame',
        ('%d covered frames in total'):format(before))
end

-- A BUILD WITHOUT THE NATIVE STILL PLAYS. client/dbno.lua guards the call, and
-- the guard is the difference between "the standing frame is visible on this
-- build" and "the frame callback that also keeps the player on the floor threw
-- five times and was suspended".
describe('dbno.cover.absent')
do
    local SRV = newServer()
    local CLI = newClient(96, 0)
    local env = CLI.env
    env.SetEntityLocallyInvisible = nil

    local wire = {}
    local function drain(now)
        SRV.tick(now)
        for i = 1, #SRV.out do
            local m = SRV.out[i]
            wire[#wire + 1] = { at = now + 40, event = m.event,
                                target = m.target, payload = m.payload }
        end
        for i = #SRV.out, 1, -1 do SRV.out[i] = nil end
        while wire[1] and now >= wire[1].at do
            local m = table.remove(wire, 1)
            env.BR.State.me.state = SRV.roster[1].state
            if m.target == 1 or m.target == -1 then
                env.TriggerEvent(m.event, m.payload)
            end
        end
        for i = 1, #CLI.toServer do
            local m = CLI.toServer[i]
            if now >= m.at + 40 then
                SRV.roster[1].engineHp = env.GetEntityHealth(1)
                SRV.died(1, m.data)
                CLI.toServer[i] = nil
            end
        end
        local kept = {}
        for i = 1, #CLI.toServer do
            if CLI.toServer[i] then kept[#kept + 1] = CLI.toServer[i] end
        end
        CLI.toServer = kept
    end

    CLI.pump(6000, drain)
    CLI.fall()
    CLI.pump(4000, drain)

    ok(SRV.roster[1].state == env.BR.PlayerState.DBNO,
        'a build with no SET_ENTITY_LOCALLY_INVISIBLE still knocks rather '
        .. 'than suspending the callback that keeps the player down',
        tostring(SRV.roster[1].state))
    ok(CLI.ped.anim ~= nil,
        'and still ends up wearing the downed pose',
        tostring(CLI.ped.anim))
end

-- ==========================================================================
-- THE SQUAD HEARS IT; THE SUBJECT DOES NOT.
-- ==========================================================================
--
-- Owner: "When a squad player goes from alive to DBNO and DBNO to out, a sound
-- effect should be played that all squadmates can hear, except the one which is
-- down. They have their own sounds for this phase."
--
-- THE AUDIENCE IS THE ONLY INTERESTING PART, and it is the part that cannot be
-- seen by playing -- a two-machine playtest with the subject's own cue also
-- firing sounds exactly like a correct one. So the audience is what is asserted,
-- on both edges, against the real server.

describe('dbno.squadcue')
do
    local S = newServer()
    local Net = S.env.BR.Net
    local PS  = S.env.BR.PlayerState

    -- A third mate, and a stranger in the same match who must hear nothing.
    S.roster[3] = { src = 3, name = 'P3', matchId = 1, squadId = 'sq1',
                    state = PS.ALIVE, hp = 100.0, armour = 0.0, kills = 0 }
    S.roster[4] = { src = 4, name = 'P4', matchId = 1, squadId = 'sq2',
                    state = PS.ALIVE, hp = 100.0, armour = 0.0, kills = 0 }

    --- Every DBNO_SET carrying a `mate` envelope, by recipient.
    local function cues()
        local out = {}
        for _, m in ipairs(S.out) do
            if m.event == Net.DBNO_SET and type(m.payload) == 'table'
               and type(m.payload.mate) == 'table' then
                out[m.target] = m.payload.mate
            end
        end
        return out
    end

    for i = #S.out, 1, -1 do S.out[i] = nil end
    S.env.BR.Combat.knock(1, 4)
    local down = cues()

    ok(down[2] ~= nil and down[3] ~= nil,
        'a knock is heard by every squadmate')
    ok(down[1] == nil,
        'and NOT by the player it happened to -- they have their own cue',
        down[1] and 'the subject was sent one' or nil)
    ok(down[4] == nil,
        'and not by the squad that shot them',
        down[4] and 'an enemy was sent one' or nil)
    ok(down[2] and down[2].phase == 'down' and down[2].src == 1
       and down[2].name == 'P1',
        'and it names the phase and who it happened to',
        down[2] and (tostring(down[2].phase) .. ' ' .. tostring(down[2].src)) or nil)

    -- ...AND THE SECOND EDGE. The bleed runs out with nobody on them.
    for i = #S.out, 1, -1 do S.out[i] = nil end
    S.tick(S.roster[1].dbnoUntil + 500)
    local out = cues()

    ok(S.roster[1].state == PS.DEAD, 'the bleed clock finishes them')
    ok(out[2] ~= nil and out[2].phase == 'out',
        'and DBNO -> out is its own cue to the squad',
        out[2] and tostring(out[2].phase) or 'nothing was sent')
    ok(out[1] == nil,
        'still not to the subject',
        out[1] and 'the subject was sent one' or nil)

    -- A DEATH THAT WAS NEVER A KNOCK IS NOT THIS EVENT. Being shot dead outright
    -- is what the kill feed is for; firing the downed-to-out cue for it would
    -- tell a squad somebody had just bled out when nobody ever took a knee.
    for i = #S.out, 1, -1 do S.out[i] = nil end
    S.env.BR.Combat.eliminate(3, 'admin', nil)
    ok(next(cues()) == nil,
        'and a straight elimination -- never downed -- plays neither',
        'a cue went out for a player who was never on the floor')

    -- ...AND THE THIRD PHASE, WHICH IS THE ONLY GOOD ONE (owner, 2026-08-18:
    -- "when a player is revived all squad mates should hear a success sound").
    --
    -- KNOCKED AND PICKED UP, on the same channel and with the same audience
    -- rule. Player 2 is the reviver and hears it as a mate -- they are one --
    -- and the subject does not, because they are being told in words instead.
    S.roster[1].state = PS.ALIVE
    S.env.BR.Combat.knock(1, 4)
    for i = #S.out, 1, -1 do S.out[i] = nil end
    S.env.BR.Combat.revive(1, 2)
    local up = cues()

    ok(S.roster[1].state == PS.ALIVE, 'a revive puts them back on their feet')
    ok(up[2] ~= nil and up[2].phase == 'up',
        'and DBNO -> up is its own cue, on the same envelope as the other two',
        up[2] and tostring(up[2].phase) or 'nothing was sent')
    ok(up[3] ~= nil and up[3].phase == 'up',
        'heard by every mate and not only by the one who did it',
        up[3] and tostring(up[3].phase) or 'the third mate heard nothing')
    ok(up[1] == nil,
        'and never by the player it happened to -- the same rule as the other '
        .. 'two phases, and the reason the SERVER owns the audience',
        up[1] and 'the subject was sent one' or nil)
    ok(up[4] == nil,
        'and not by the squad that put them there',
        up[4] and 'an enemy was sent one' or nil)
    ok(up[2] and up[2].src == 1 and up[2].name == 'P1',
        'and it names who came back up',
        up[2] and tostring(up[2].src) or nil)

    -- THE ADMIN PATH RAISES IT TOO, and that is why it is sent from
    -- BR.Combat.revive rather than from the hold that usually causes one.
    -- `/brrevive` runs the same function precisely so it cannot drift from the
    -- player-facing path, and a cue wired to the hold would have been the
    -- drift.
    S.env.BR.Combat.knock(1, 4)
    for i = #S.out, 1, -1 do S.out[i] = nil end
    S.env.BR.Combat.revive(1, nil)
    local admin = cues()
    ok(admin[2] ~= nil and admin[2].phase == 'up',
        'and a revive with no reviver -- /brrevive -- is still a revive the '
        .. 'squad hears',
        admin[2] and tostring(admin[2].phase) or 'nothing was sent')
end

-- The client half of the same feature: the second shape on DBNO_SET is answered
-- and, crucially, does NOT fall through into the receiver's own downed state.
describe('dbno.squadcue.client')
do
    local peds = { [5001] = { x = 0.0, y = 0.0, z = 30.0 },
                   [5002] = { x = 0.8, y = 0.0, z = 30.0 } }
    local CLI = newReviver(2, 1, peds)
    local env = CLI.env

    --- The last envelope of a kind this client pushed at the interface.
    local function lastUi(kind)
        for i = #CLI.ui, 1, -1 do
            if CLI.ui[i].kind == kind then return CLI.ui[i].d end
        end
        return nil
    end

    env.TriggerEvent(env.BR.Net.DBNO_SET,
        { mate = { src = 1, name = 'P1', phase = 'down' } })
    local c = lastUi('squadcue')
    ok(c ~= nil and c.cue == 'squad.down',
        'a mate going down reaches the interface as a cue',
        c and tostring(c.cue) or 'nothing was pushed')

    env.TriggerEvent(env.BR.Net.DBNO_SET,
        { mate = { src = 1, name = 'P1', phase = 'out' } })
    c = lastUi('squadcue')
    ok(c ~= nil and c.cue == 'squad.out',
        'and going out is a DIFFERENT cue -- two events, two sounds',
        c and tostring(c.cue) or 'nothing was pushed')

    -- THE CUE NAME IS THE DELIVERABLE HERE, and it is asserted rather than
    -- described because it is a string that has to match one in
    -- ui-src/src/audio/cues.ts. Nothing in Lua can check the far side, so the
    -- least this side can do is fail loudly if the name it sends ever moves.
    env.TriggerEvent(env.BR.Net.DBNO_SET,
        { mate = { src = 1, name = 'P1', phase = 'up' } })
    c = lastUi('squadcue')
    ok(c ~= nil and c.cue == 'squad.revived',
        'and being picked up is a THIRD cue -- squad.revived, the success '
        .. 'sound the owner asked for',
        c and tostring(c.cue) or 'nothing was pushed')
    ok(c ~= nil and c.src == 1 and c.name == 'P1',
        'carrying who it was, so the interface can say the name',
        c and tostring(c.name) or nil)

    -- THE TRAP THIS EXISTS FOR. `mate` envelopes carry no `downed` field, so a
    -- handler that fell through would read nil, decide we are not down, and
    -- stand a downed player up on the strength of somebody else's news.
    local dbno = lastUi(env.BR.Nui.DBNO)
    ok(dbno == nil,
        'and a cue about somebody else never writes our own downed state',
        'the DBNO envelope was rewritten by a message about a mate')

    -- An unknown phase is dropped rather than guessed at.
    env.TriggerEvent(env.BR.Net.DBNO_SET,
        { mate = { src = 1, name = 'P1', phase = 'sideways' } })
    local n = 0
    for _, e in ipairs(CLI.ui) do if e.kind == 'squadcue' then n = n + 1 end end
    ok(n == 3, 'an unrecognised phase plays nothing', ('%d cues'):format(n))
end

-- ==========================================================================
-- THE COURTESY BLIPS ARE ONCE PER MATCH.
-- ==========================================================================
--
-- "It runs exactly once per match, at most. That's it. There's no logic to say
-- we restart the courtesy blips, ever" (owner, 2026-08-18) -- after two rounds
-- of fixes built on a per-LIFE latch, which is a lifecycle this mode does not
-- have. The only way back onto your feet in a battle royale is a revive, so the
-- per-life reset was really the between-MATCHES reset wearing the wrong hat,
-- and the DBNO special case existed solely to defend against it.
--
-- WHAT THIS BLOCK HAS TO PIN, because each one has shipped broken:
--
--   * they arm ONCE and never re-arm (user, 2026-08-07: "courtesy loot blips
--     don't remove after 1 minute" -- the arming test `now - landedAt >=
--     afterMs` stays true forever, so the expiry was undone on the next pass);
--   * they do NOT fire on the frame a revived player gets their weapon back
--     (owner, 2026-08-18) -- the grace clock used to run through the bleed;
--   * but a player knocked BEFORE the window opened still gets them afterwards
--     if the map really is empty. That is the cost the old DBNO special case
--     charged, and it is the thing being removed;
--   * player state moves the BLIPS and nothing else -- no state transition
--     reopens the window;
--   * a new match, and only a new match, does.
--
-- THE REAL CALLBACK, LIFTED OUT OF THE REAL FILE. `mercy` is a file-local and
-- there is no accessor, so the only honest way to drive it is to load
-- client/loot.lua into a sandbox and pull the registered SLOW callbacks back
-- out of BR.Loop -- which also means a rename or a deletion of the band fails
-- this block loudly rather than silently testing nothing. The blips themselves
-- are counted through the blip natives for the same reason: `mercy.on` is not
-- reachable from here, so the assertion is made on what the player would
-- actually see on their map.
describe('loot.mercy')
do
    --- One client with the real client/loot.lua in it, and nothing else.
    local function newLootClient()
        local env = newSandbox()
        -- NOT ZERO, and it is not decoration. `mercy.landedAt == 0` is how the
        -- band says "I have not stamped a landing yet", so a rig whose clock
        -- starts at 0 re-stamps the landing on every pass and the grace period
        -- can never expire -- a green run over a feature that does nothing.
        -- GetGameTimer is milliseconds since the game started and is never 0 by
        -- the time anybody has landed.
        local C = { now = 5000, ui = {} }

        env.GetGameTimer = function() return C.now end
        env.print = function() end
        env.GetCurrentResourceName = function() return 'br_core' end
        env.GetHashKey = function(s) return #tostring(s) end
        env.PlayerId = function() return 0 end
        env.GetPlayerServerId = function() return 1 end

        loadInto(env, SANDBOX_LIB)

        local V = {}
        V.__index = V
        V.__sub = function(a, b)
            return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, V)
        end
        V.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
        local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end

        env.PlayerPedId       = function() return 1 end
        env.DoesEntityExist   = function() return true end
        env.GetEntityCoords   = function() return vec(0.0, 0.0, 30.0) end
        env.GetEntityHeading  = function() return 0.0 end
        env.IsPedInAnyVehicle = function() return false end
        env.GetFrameTime      = function() return 0.016 end
        env.RegisterNetEvent  = function() end
        env.RegisterCommand   = function() end

        -- LIVE BLIP HANDLES, not a constant. The old rig answered 1 to
        -- AddBlipForCoord and true to DoesBlipExist forever, which makes "are
        -- the blips on the map right now" unanswerable -- and that is exactly
        -- the question "player state controls drawing only" is a claim about.
        local live, nextBlip = {}, 0
        env.AddBlipForCoord = function()
            nextBlip = nextBlip + 1
            live[nextBlip] = true
            return nextBlip
        end
        env.DoesBlipExist = function(b) return live[b] == true end
        env.RemoveBlip    = function(b) live[b] = nil end
        env.SetBlipSprite = function() end
        env.SetBlipScale  = function() end
        env.SetBlipColour = function() end
        env.SetBlipAsShortRange = function() end

        local handlers = {}
        env.AddEventHandler = function(n, fn)
            handlers[n] = handlers[n] or {}
            handlers[n][#handlers[n] + 1] = fn
        end
        env.TriggerEvent = function(n, ...)
            for _, fn in ipairs(handlers[n] or {}) do fn(...) end
        end
        env.TriggerServerEvent = function() end
        env.Citizen = { CreateThread = function() end, Wait = function() end,
                        SetTimeout = function() end }

        loadInto(env, { 'br_core/client/main.lua' })

        env.BR.State.me = { src = 1, state = env.BR.PlayerState.ALIVE,
                            squadId = 'sq1' }
        env.BR.State.roster = {}
        env.BR.Inv    = { lastGainAt = 0, count = function() return 0 end }
        env.BR.Sfx    = { play = function() end }
        env.BR.Keys   = { isHeld = function() return false end,
                          on = function() end }
        env.BR.Dui    = { page = function(n) return { name = n } end,
                          send = function() end, drawWorld = function() end,
                          drawScreen = function() end,
                          drawOnEntity = function() end,
                          ready = function() return true end }
        env.BR.Native = env.BR.Native or {}
        env.BR.Native.keyLabelForCommand = function() return 'E' end
        env.BR.Native.blipName = function() end
        env.BR.Native.setDisplayHealth = function() end

        env.AddEventHandler('br:ui:sendLocal', function(kind, payload)
            C.ui[#C.ui + 1] = { kind = kind, d = payload }
        end)

        loadInto(env, { 'br_core/client/loot.lua' })

        C.env = env
        --- One SLOW pass, `ms` after the last one.
        function C.slow(ms)
            C.now = C.now + (ms or 1000)
            env.BR.Loop.step(env.BR.Loop.SLOW)
        end
        --- Where the player is: `C.be(PS.DBNO)`.
        function C.be(st) env.BR.State.me.state = st end
        --- A match transition off the wire.
        function C.match(st) env.TriggerEvent(env.BR.Net.STATE, { state = st }) end
        --- Two crates within reach of the map, so there is something to blip.
        function C.crates()
            env.TriggerEvent(env.BR.Net.LOOT_ADD, {
                { id = 'c1', kind = 'chest', x = 10.0, y = 10.0, z = 30.0,
                  prop = 'prop_box_ammo04a' },
                { id = 'c2', kind = 'chest', x = 20.0, y = 20.0, z = 30.0,
                  prop = 'prop_box_ammo04a' },
            })
        end
        --- How many blips are on the map right now.
        function C.blips()
            local n = 0
            for _ in pairs(live) do n = n + 1 end
            return n
        end
        --- How many "crates are marked on your map" toasts have been raised.
        function C.toasts()
            local n = 0
            for _, e in ipairs(C.ui) do
                if type(e.d) == 'table' and type(e.d.text) == 'string'
                   and e.d.text:find('Crates are marked', 1, true) then
                    n = n + 1
                end
            end
            return n
        end
        return C
    end

    local cfg = BR.Config.Loot.mercyBlips
    ok(cfg ~= nil and cfg.enabled,
        'the courtesy blips are switched on, or none of this means anything',
        cfg and tostring(cfg.enabled) or 'no mercyBlips config at all')
    local AFTER = (cfg and cfg.afterMs) or 60000
    local SHOWN = (cfg and cfg.minShownMs) or 60000

    -- 1. THE CONTROL AT THE TOP, not at the bottom: a player who is never
    --    touched still gets the help, because a fix that simply disabled the
    --    feature would pass every assertion below. And it arms ONCE -- the
    --    2026-08-07 report was the expiry being undone on the very next pass,
    --    which a rig that stops stepping at the expiry cannot see.
    do
        local C  = newLootClient()
        local PS = C.env.BR.PlayerState
        C.crates()
        C.be(PS.ALIVE)
        C.slow(0)
        C.slow(AFTER + 1000)
        ok(C.toasts() == 1,
            'an empty-handed player who is never touched is offered the '
            .. 'courtesy blips',
            ('%d toasts'):format(C.toasts()))
        ok(C.blips() == 2, 'and the crates near them go on the map',
            ('%d blips'):format(C.blips()))

        C.slow(SHOWN + 1000)
        ok(C.blips() == 0, 'they come off the map when the window expires',
            ('%d blips'):format(C.blips()))

        for _ = 1, 20 do C.slow(30000) end
        ok(C.toasts() == 1 and C.blips() == 0,
            'AND THEY NEVER COME BACK -- ten minutes of passes past the expiry '
            .. 'and the arming test, which stays true forever, re-arms nothing',
            ('%d toasts, %d blips'):format(C.toasts(), C.blips()))
    end

    -- 2. KNOCKED BEFORE THE WINDOW EVER OPENED. Both halves of this are the
    --    point, and they used to be traded off against each other: the old
    --    answer closed the window outright on a knock, which killed the second
    --    half to buy the first.
    do
        local C  = newLootClient()
        local PS = C.env.BR.PlayerState
        C.crates()
        C.be(PS.ALIVE)
        C.slow(0)
        C.slow(20000)                       -- 20s in, nothing found yet
        ok(C.toasts() == 0,
            'nothing has been offered yet -- the grace period is still running',
            ('%d toasts'):format(C.toasts()))

        C.be(PS.DBNO)
        C.slow(1000)
        C.slow(AFTER)                       -- a long bleed and a long revive
        ok(C.toasts() == 0 and C.blips() == 0,
            'a downed player is offered nothing and shown nothing',
            ('%d toasts, %d blips'):format(C.toasts(), C.blips()))

        C.be(PS.ALIVE)                      -- picked up
        C.slow(1000)
        ok(C.toasts() == 0,
            'AND NOTHING FIRES ON THE FRAME THEY ARE PICKED UP (owner, '
            .. '2026-08-18) -- the grace clock counts time on your feet, so '
            .. 'the bleed and the revive did not spend it',
            ('%d toasts on the revive pass'):format(C.toasts()))

        C.slow(AFTER)
        ok(C.toasts() == 1 and C.blips() == 2,
            'BUT THEY STILL GET THE HELP once they have genuinely spent the '
            .. 'grace period on their feet with nothing -- the old DBNO special '
            .. 'case charged them their whole match for being knocked early',
            ('%d toasts, %d blips'):format(C.toasts(), C.blips()))
    end

    -- 3. KNOCKED WHILE THE BLIPS ARE ON SCREEN. The window is OPEN, so the
    --    blips must come off the map and back on with the player -- and the
    --    clock underneath must not restart, or a knock buys a fresh minute of
    --    wallhack every time.
    do
        local C  = newLootClient()
        local PS = C.env.BR.PlayerState
        C.crates()
        C.be(PS.ALIVE)
        C.slow(0)
        C.slow(AFTER + 1000)
        ok(C.toasts() == 1 and C.blips() == 2, 'the blips are offered once',
            ('%d toasts, %d blips'):format(C.toasts(), C.blips()))

        C.be(PS.DBNO)
        C.slow(1000)
        ok(C.blips() == 0, 'a knock takes them off the map',
            ('%d blips'):format(C.blips()))

        C.be(PS.ALIVE)
        C.slow(1000)
        ok(C.toasts() == 1 and C.blips() == 2,
            'and a revive puts them back WITHOUT a second toast -- the window '
            .. 'never closed, so it was never reopened',
            ('%d toasts, %d blips'):format(C.toasts(), C.blips()))

        C.slow(SHOWN)
        ok(C.blips() == 0 and C.toasts() == 1,
            'and the window still expires on its own clock, which the knock '
            .. 'did not rewind',
            ('%d toasts, %d blips'):format(C.toasts(), C.blips()))
    end

    -- 4. NO PLAYER-STATE TRANSITION REOPENS THE WINDOW. This is the assertion
    --    the old per-life model fails, and it is the whole of the owner's
    --    point: there is no second life to reset for. A DEATH is not a new
    --    match -- what follows a death in this mode is the lobby.
    do
        local C  = newLootClient()
        local PS = C.env.BR.PlayerState
        C.crates()
        C.be(PS.ALIVE)
        C.slow(0)
        C.slow(AFTER + 1000)
        C.slow(SHOWN + 1000)
        ok(C.toasts() == 1, 'offered once, and expired',
            ('%d'):format(C.toasts()))

        C.be(PS.DEAD)
        C.slow(1000)
        C.be(PS.ALIVE)
        C.slow(1000)
        C.slow(AFTER + 1000)
        C.slow(AFTER + 1000)
        ok(C.toasts() == 1,
            'a death and a return to their feet does NOT re-arm them -- the '
            .. 'latch is per MATCH, and nothing about a player state says a '
            .. 'match began',
            ('%d toasts after a death'):format(C.toasts()))

        C.be(PS.DBNO)
        C.slow(1000)
        C.be(PS.DEAD)                       -- bled out
        C.slow(1000)
        C.be(PS.LOBBY)                      -- and back to the menu
        C.slow(1000)
        C.be(PS.ALIVE)
        C.slow(AFTER + 1000)
        ok(C.toasts() == 1,
            'nor does a bleed-out, nor a trip through the lobby',
            ('%d toasts'):format(C.toasts()))
    end

    -- 5. A NEW MATCH DOES. The teardown transition is the one this file already
    --    drops its entries on, and the one client/state.lua replays locally off
    --    the digest and the snapshot so a scoped broadcast cannot miss it.
    --    Case 4 above is what makes this case mean something: without it, a
    --    green run here could be the lobby transition doing the work.
    do
        local C  = newLootClient()
        local PS = C.env.BR.PlayerState
        local MS = C.env.BR.MatchState
        C.crates()
        C.be(PS.ALIVE)
        C.slow(0)
        C.slow(AFTER + 1000)
        C.slow(SHOWN + 1000)
        ok(C.toasts() == 1, 'used up in the first match', ('%d'):format(C.toasts()))

        C.match(MS.ENDED)                   -- the round is over
        C.be(PS.LOBBY)
        C.slow(1000)
        C.match(MS.WAITING)                 -- released to the lobby
        C.slow(1000)
        ok(C.toasts() == 1, 'the lobby is offered nothing',
            ('%d toasts'):format(C.toasts()))

        C.crates()                          -- a new layout streams in
        C.be(PS.WARMUP)
        C.slow(1000)
        C.be(PS.ALIVE)                      -- landed in the new match
        C.slow(1000)
        ok(C.toasts() == 1,
            'and the new match does not start by offering them either -- the '
            .. 'grace period runs from the landing, not from the reset',
            ('%d toasts'):format(C.toasts()))

        C.slow(AFTER)
        ok(C.toasts() == 2 and C.blips() == 2,
            'THE NEW MATCH RE-ARMS THE LATCH -- the courtesy blips are once '
            .. 'per match, not once per session',
            ('%d toasts, %d blips'):format(C.toasts(), C.blips()))
    end

    -- 6. THE SAME CLAIM WITH THE PLAYER STATE HELD STILL. Case 5 walks a
    --    realistic path -- lobby, warmup, landing -- and every one of those is
    --    a transition the OLD per-life reset also fired on, so on its own it
    --    cannot say which signal did the work. Here the player never leaves
    --    ALIVE and the match transition is the only thing that happens, so a
    --    second offer can have come from nowhere else.
    do
        local C  = newLootClient()
        local PS = C.env.BR.PlayerState
        local MS = C.env.BR.MatchState
        C.crates()
        C.be(PS.ALIVE)
        C.slow(0)
        C.slow(AFTER + 1000)
        C.slow(SHOWN + 1000)
        ok(C.toasts() == 1, 'used up once', ('%d'):format(C.toasts()))

        C.match(MS.WAITING)
        C.crates()
        C.slow(1000)
        C.slow(AFTER)
        ok(C.toasts() == 2,
            'the match transition ALONE reopens the window -- no player state '
            .. 'was touched between the two offers',
            ('%d toasts'):format(C.toasts()))
    end
end

-- ------------------------------------------------ airdrops on roofs (#88) ---
--
-- Owner, 2026-08-22: "Somehow these airdrops can happen on top of buildings
-- where peds otherwise cannot access. Any tips on how to address that?"
--
-- ═══ THE CAUSE IS THE GROUND PROBE, NOT THE SITING ═══
--
-- The server picks an authored POI, which is a street-level landmark. The
-- client then resolves the height with GetGroundZFor_3dCoord starting hundreds
-- of metres up -- and that native is documented to return the highest ground
-- "directly beneath" the start point, which over a building is the ROOF, every
-- time, exactly as designed.
--
-- ═══ AND THE FIX IS THE MACHINERY THAT ALREADY EXISTS ═══
--
-- Since the same playtest removed the auto-open, the airdrop crate IS an
-- ordinary loot registry entry -- so it inherits the repair round-trip that has
-- relocated drowned and buried loot since 2026-08-06: the client probes, finds
-- the point impossible, proposes somewhere better, and the server (which has no
-- map at all) accepts it under a 30m bound. All that is added is a second
-- reason to call a point impossible.
--
-- THIS BLOCK IS IN test_shared BECAUSE IT NEEDS THE DRAIN WORKER. The full
-- client suite stubs Citizen.CreateThread to a no-op and CreateObjectNoOffset to
-- 0, so no prop is ever built there and the probe path is never walked. Here the
-- thread runs synchronously and objects are real handles, which is the only way
-- to see what the client actually SENDS.

describe('loot.rooftop')
do
    --- One client with the real client/loot.lua in it, a ground probe that can
    --- be told there is a roof at a given point, and a synchronous spawn worker.
    local function newProbeClient()
        local env = newSandbox()
        local C = { now = 5000, sent = {}, objects = {}, scaled = {},
                    scaleAsks = {} }

        --- ['x,y'] = the height the probe answers there. Absent means clean
        --- ground at 30.
        C.groundAt = {}
        --- ['x,y'] = why a ped could not be there. Absent means they could.
        C.roofAt = {}
        local function key(x, y) return ('%.1f,%.1f'):format(x, y) end
        C.key = key

        env.GetGameTimer = function() return C.now end
        env.print = function() end
        env.GetCurrentResourceName = function() return 'br_core' end
        env.GetHashKey = function(s) return s end
        env.PlayerId = function() return 0 end
        env.GetPlayerServerId = function() return 1 end

        loadInto(env, SANDBOX_LIB)
        loadInto(env, { 'br_lib/config/airdrop.lua' })

        local V = {}
        V.__index = V
        local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end

        env.PlayerPedId       = function() return 1 end
        env.GetEntityCoords   = function() return vec(0.0, 0.0, 30.0) end
        env.GetEntityHeading  = function() return 0.0 end
        env.IsPedInAnyVehicle = function() return false end
        env.GetFrameTime      = function() return 0.016 end
        env.RegisterNetEvent  = function() end
        env.RegisterCommand   = function() end

        -- THE PROBE. Answers a height for any point and a DIFFERENT height for
        -- a point a test has put a building on -- which is what the real native
        -- does over a roof.
        -- WHAT THE PROBE'S BOOL ANSWERS WITH. A FiveM native declared BOOL may
        -- hand back 1 or 0 rather than true or false, and 0 IS TRUTHY IN LUA --
        -- five shipped bugs on this project. Driven, so both shapes are walked.
        C.probeOk = true

        -- ═══ THE COLLISION STREAM, WHICH IS WHAT A CRATE FALLS THROUGH ═══
        --
        -- Owner, 2026-08-23: an airdrop on a building "falls through the top of
        -- the building as if it doesn't have collisions", and the crate then
        -- "spawn[s] at ground level inside a building".
        --
        -- MODELLED RATHER THAN ASSERTED ABOUT, because the two halves of that
        -- bug are one sequence: map collision arrives LATE, and until it does
        -- the ground probe answers off the terrain that arrived first -- a
        -- perfectly confident answer about the street under the building. So
        -- `collisionAfter` says how many checks the building takes to stream in,
        -- and `lateGroundAt` is a surface that does not exist until it has.
        --
        -- THE 1/0 SHAPE IS THE DEFAULT AND NOT AN EDGE CASE. A FiveM native
        -- declared BOOL hands back 1 and 0, and 0 IS TRUTHY IN LUA -- six
        -- shipped bugs. A rig that answered `true`/`false` here would pass a
        -- wait that never waits.
        C.collisionAsked   = {}
        C.collisionChecks  = 0
        C.collisionAfter   = nil     -- nil: already streamed, as it usually is
        C.collisionLoaded  = 1
        C.lateGroundAt     = {}
        local function collisionIn()
            return C.collisionAfter == nil
                or C.collisionChecks > C.collisionAfter
        end
        C.collisionIn = collisionIn
        env.RequestCollisionAtCoord = function(x, y, z)
            C.collisionAsked[#C.collisionAsked + 1] = { x = x, y = y, z = z }
        end
        env.HasCollisionLoadedAroundEntity = function()
            C.collisionChecks = C.collisionChecks + 1
            if not collisionIn() then return 0 end
            return C.collisionLoaded
        end

        env.GetGroundZFor_3dCoord = function(x, y)
            local k = key(x, y)
            -- A ROOF IS NOT THERE UNTIL ITS COLLISION IS. Before that the probe
            -- finds the terrain and says so, which is exactly how a crate comes
            -- to be created at street level inside a building.
            if C.lateGroundAt[k] and collisionIn() then
                return C.probeOk, C.lateGroundAt[k]
            end
            return C.probeOk, C.groundAt[k] or 30.0
        end
        env.GetWaterHeight = function() return false, 0.0 end

        -- Real handles, so "was a prop built" is answerable. The whole point of
        -- this rig.
        local nextObj = 0
        env.CreateObjectNoOffset = function(model, x, y, z)
            nextObj = nextObj + 1
            C.objects[nextObj] = { model = model, x = x, y = y, z = z }
            return nextObj
        end
        env.CreateObject = env.CreateObjectNoOffset
        env.DoesEntityExist = function(e) return C.objects[e] ~= nil end
        env.DeleteEntity = function(e) C.objects[e] = nil end
        env.IsModelValid = function() return true end
        env.RequestModel = function() end
        env.HasModelLoaded = function() return true end
        env.SetModelAsNoLongerNeeded = function() end
        for _, n in ipairs({
            'SetEntityCollision', 'FreezeEntityPosition', 'SetEntityHeading',
            'SetEntityCoords', 'SetEntityCoordsNoOffset', 'SetEntityRotation',
            'SetEntityDynamic', 'SetEntityHasGravity', 'SetObjectPhysicsParams',
            'ActivatePhysics', 'SetEntityAsMissionEntity',
            'PlaceObjectOnGroundProperly', 'SetEntityVelocity',
            'SetEntityDrawOutline', 'SetEntityDrawOutlineColor',
            'SetEntityDrawOutlineShader', 'PlaySoundFrontend',
            'AddBlipForCoord', 'RemoveBlip', 'SetBlipSprite', 'SetBlipScale',
            'SetBlipColour', 'SetBlipAsShortRange', 'N_0x2c2b3493fbf51c71',
        }) do env[n] = function() end end

        -- ═══ THE HANDOVER TO PHYSICS, IN ORDER ═══
        --
        -- "Collision was requested" and "collision was requested BEFORE the box
        -- was let go" are different claims and only the second one is the fix,
        -- so these four are recorded in sequence rather than counted. A crate
        -- released to gravity above a roof that has not streamed is a crate on
        -- the street inside the building, and the ordering is the whole of what
        -- stops it.
        C.calls = {}
        local function note(name)
            return function(...) C.calls[#C.calls + 1] = { name, ... } end
        end
        env.FreezeEntityPosition = note('freeze')
        env.SetEntityDynamic     = note('dynamic')
        env.ActivatePhysics      = note('physics')
        local noteAsk = env.RequestCollisionAtCoord
        env.RequestCollisionAtCoord = function(x, y, z)
            C.calls[#C.calls + 1] = { 'collision', x, y, z }
            noteAsk(x, y, z)
        end
        -- WHERE THE PROP ACTUALLY ENDED UP. The re-seat after the collision
        -- arrives is the half that stops a crate being BUILT inside a building
        -- rather than falling into one, and it is invisible unless the rig moves
        -- the recorded object with it.
        env.SetEntityCoordsNoOffset = function(e, x, y, z)
            C.calls[#C.calls + 1] = { 'move', e, x, y, z }
            local o = C.objects[e]
            if o then o.x, o.y, o.z = x, y, z end
        end
        --- Every recorded call of one name, in order.
        function C.only(name)
            local out = {}
            for _, c in ipairs(C.calls) do
                if c[1] == name then out[#out + 1] = c end
            end
            return out
        end
        --- The index of the first call of `name`, or nil.
        function C.firstAt(name)
            for i, c in ipairs(C.calls) do
                if c[1] == name then return i end
            end
        end

        env.GetEntityVelocity = function() return vec(0.0, 0.0, 0.0) end
        env.GetEntityRotation = function() return vec(0.0, 0.0, 0.0) end
        env.DoesBlipExist = function() return false end

        local handlers = {}
        env.AddEventHandler = function(n, fn)
            handlers[n] = handlers[n] or {}
            handlers[n][#handlers[n] + 1] = fn
        end
        env.TriggerEvent = function(n, ...)
            for _, fn in ipairs(handlers[n] or {}) do fn(...) end
        end
        env.TriggerServerEvent = function(n, ...)
            C.sent[#C.sent + 1] = { name = n, args = { ... } }
        end
        -- SYNCHRONOUS, so the spawn worker finishes inside the pass that
        -- queued it. Nothing here is testing concurrency.
        env.Citizen = { CreateThread = function(fn) fn() end,
                        Wait = function() end, SetTimeout = function() end }

        loadInto(env, { 'br_core/client/main.lua' })

        env.BR.State.me = { src = 1, state = env.BR.PlayerState.ALIVE }
        env.BR.State.roster = {}
        env.BR.Inv    = { lastGainAt = 0, count = function() return 0 end }
        env.BR.Sfx    = { play = function() end }
        env.BR.Keys   = { isHeld = function() return false end, on = function() end }
        env.BR.Dui    = { page = function(n) return { name = n } end,
                          send = function() end, drawWorld = function() end,
                          drawScreen = function() end,
                          drawOnEntity = function() end,
                          ready = function() return true end }
        env.BR.Native = {
            keyLabelForCommand = function() return 'E' end,
            blipName = function() end,
            setDisplayHealth = function() end,
            -- `scaled` MIRRORS THE REAL NATIVE: 1.0 is the absence of a scale,
            -- not a scale of one, and BR.Native.propScale writes no matrix for
            -- it. `scaleAsks` counts the CALL regardless, which is the only way
            -- to tell "the crate is at authored size" apart from "the pass that
            -- would have scaled it stopped running".
            propScale = function(obj, k)
                if obj then C.scaleAsks[obj] = (C.scaleAsks[obj] or 0) + 1 end
                if obj and k and k ~= 1.0 then C.scaled[obj] = k end
            end,
            -- THE ROOFTOP ORACLE. The real one is a navmesh query; here a test
            -- says where a ped could not be.
            pedReachable = function(x, y)
                local why = C.roofAt[key(x, y)]
                if why then return false, why end
                return true, 'ok'
            end,
        }

        loadInto(env, { 'br_core/client/loot.lua' })

        C.env = env
        function C.slow(ms)
            C.now = C.now + (ms or 1000)
            env.BR.Loop.step(env.BR.Loop.SLOW)
        end
        function C.add(e)
            env.TriggerEvent(env.BR.Net.LOOT_ADD, { e })
        end
        --- Every LOOT_FIX this client has proposed.
        function C.fixes()
            local out = {}
            for _, s in ipairs(C.sent) do
                if s.name == env.BR.Net.LOOT_FIX then out[#out + 1] = s.args[1] end
            end
            return out
        end
        --- How many props exist right now.
        function C.props()
            local n = 0
            for _ in pairs(C.objects) do n = n + 1 end
            return n
        end
        return C
    end

    local A = BR.Config.Airdrop

    --- A sealed airdrop crate, exactly as server/airdrop.lua lays one.
    local function crateAt(x, y)
        return { id = 1, kind = 'chest', item = 'airdrop', prop = A.crateProp,
                 x = x, y = y, z = 30.0, rarity = BR.Rarity.LEGENDARY, count = 1 }
    end

    -- 1. CLEAN GROUND CHANGES NOTHING AT ALL.
    do
        local C = newProbeClient()
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)
        ok(#C.fixes() == 0, 'a reachable crate proposes no move')
        ok(C.props() > 0, 'and its prop is built')
    end

    -- 2. A ROOFTOP CRATE ASKS TO BE MOVED.
    do
        local C = newProbeClient()
        C.roofAt[C.key(5.0, 5.0)] = 'snapped 34.0m in z'
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)
        local f = C.fixes()
        ok(#f == 1, 'a rooftop crate proposes exactly one move', #f)
        if f[1] then
            local d = math.sqrt((f[1].x - 5.0) ^ 2 + (f[1].y - 5.0) ^ 2)
            ok(d > 0.5, 'somewhere else...', ('%.1fm'):format(d))
            -- INSIDE THE SERVER'S OWN BOUND. server/loot.lua refuses a repair
            -- further than FIX_RADIUS, so a suggestion past it is a suggestion
            -- that is silently dropped -- which looks exactly like no bug.
            ok(d <= 30.0, '...and inside the server\'s 30m bound',
                ('%.1fm'):format(d))
        end
    end

    -- 3. ═══ AND THE PROP IS STILL BUILT. THIS IS THE ONE THAT MATTERS. ═══
    --
    -- `gzOk` (dry and solid) and `reachOk` (a ped could be here) are two
    -- different answers and only the first may withhold a prop. Folding them
    -- together is the obvious implementation, and it would mean a rooftop
    -- airdrop with no better point within 28m gets NO PROP AT ALL -- an
    -- invisible, unopenable crate holding the best loot in the match, in
    -- exactly the scenario the owner reported. The check runs on an untested
    -- navmesh native against a curated flag set that says "no" about plenty of
    -- good rural ground, so a false negative must cost a wasted suggestion and
    -- nothing else.
    do
        local C = newProbeClient()
        C.roofAt[C.key(5.0, 5.0)] = 'roof'
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)
        ok(C.props() > 0,
            'an unreachable crate is STILL BUILT -- the worst case of this '
            .. 'feature is the behaviour that shipped without it')
    end

    -- 4. AND WHEN EVERYWHERE NEARBY IS A ROOF, NOTHING IS PROPOSED AND THE
    --    CRATE STILL EXISTS. A suggestion that is no better than the original
    --    would burn the server's cooldown to move a crate from one roof to
    --    another.
    do
        local C = newProbeClient()
        setmetatable(C.roofAt, { __index = function() return 'roof' end })
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)
        ok(#C.fixes() == 0, 'no candidate clears the bar, so nothing is sent')
        ok(C.props() > 0, 'and the crate is still there to be opened')
    end

    -- 5. ═══ IT IS ASKED OF THE AIRDROP CRATE AND OF NOTHING ELSE ═══
    --
    -- The narrowness is deliberate and load-bearing. ~3,200 generated entries
    -- behind an untested navmesh native is a map with no loot on it if the
    -- native misbehaves at scale -- the worst failure client/loot.lua has.
    do
        local C = newProbeClient()
        -- ONLY THE CRATE'S OWN POINT IS A ROOF, so there IS somewhere better
        -- within the search ring. Marking the whole world unreachable would
        -- make this pass for the wrong reason: the search would find nothing,
        -- send nothing, and the assertion could not tell that apart from the
        -- question never being asked. A mutation pass proved exactly that.
        C.roofAt[C.key(5.0, 5.0)] = 'roof'
        C.add({ id = 2, kind = 'chest', item = 'chest',
                prop = BR.Config.Loot.chestProp,
                x = 5.0, y = 5.0, z = 30.0, rarity = BR.Rarity.COMMON, count = 1 })
        C.slow(1000)
        ok(#C.fixes() == 0,
            'an ordinary crate on the same roof is not asked the question, '
            .. 'even though a reachable point is right there')

        -- ...and the airdrop crate on that identical point IS. Same rig, same
        -- roof, same neighbours -- the only difference is the item id, which is
        -- what makes this a statement about the narrowness rather than about
        -- the rig.
        local D = newProbeClient()
        D.roofAt[D.key(5.0, 5.0)] = 'roof'
        D.add(crateAt(5.0, 5.0))
        D.slow(1000)
        ok(#D.fixes() == 1,
            'and the airdrop crate on that exact point is')
    end

    -- 6. THE SEA STILL WITHHOLDS THE PROP, which is what gzOk has always meant
    --    and must keep meaning.
    do
        local C = newProbeClient()
        C.groundAt[C.key(5.0, 5.0)] = -12.0     -- a seabed
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)
        ok(C.props() == 0, 'a drowned entry builds no prop, as it always did')
        ok(#C.fixes() == 1, 'and asks to be moved')
    end

    -- 6b. ═══ 0 IS TRUTHY IN LUA, AND THIS LINE WAS THE SIXTH TIME ═══
    --
    -- GetGroundZFor_3dCoord is declared BOOL and a FiveM native may answer 1 or
    -- 0 rather than true or false. `if not ok then` is FALSE for a native that
    -- failed with a zero, so the guard never fired -- and it has been survivable
    -- only because a failed probe ALSO hands back z = 0, which the sea-level
    -- rule below it catches. A guard working by accident is not a guard, and the
    -- rooftop check now reads that height before the accident saves it.
    --
    -- The case that tells them apart: a failed probe that returns a PLAUSIBLE
    -- height. Nothing may be built on an answer the native said it did not have.
    do
        local C = newProbeClient()
        C.probeOk = 0                            -- failed, in the 1/0 shape
        C.groundAt[C.key(5.0, 5.0)] = 42.0       -- ...with a believable height
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)
        ok(C.props() == 0,
            'a probe that failed with a ZERO builds nothing, even when the '
            .. 'height it handed back looks fine')
    end

    -- 7. ═══ THE AIRDROP CRATE IS DRAWN AT AUTHORED SIZE, AND THAT IS THE FIX
    --        (owner, 2026-08-23) ═══
    --
    -- "we need to tweak how the prop scaling works for the crate as it currently
    -- clips. We may need to drop scaling altogether."
    --
    -- A matrix scale grows a model about its ORIGIN. A landed crate is a DYNAMIC
    -- physics object whose height comes from resting on the ground with a 1x
    -- collider, so at 2x the bottom half of the box is drawn underneath the
    -- floor it is standing on -- and the obvious repair, lifting it by the extra
    -- half-height, is undone by gravity on the next simulation step. There is no
    -- number that fixes it; only a different MODEL would.
    --
    -- 1.0 IS THE ABSENCE OF A SCALE AND NOT A SCALE OF ONE, in the real
    -- BR.Native.propScale and in the stub above alike: neither writes a matrix
    -- for it. So the assertion is that nothing was applied.
    do
        local C = newProbeClient()
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)
        local obj = next(C.objects)
        ok(A.crateScale == 1.0, 'crateScale is 1.0', tostring(A.crateScale))
        ok(C.scaled[obj] == nil,
            'so no matrix scale is written to the crate at all',
            tostring(C.scaled[obj]))

        -- AND THE 10Hz RE-ASSERTION IS STILL WIRED UP, which is a different
        -- claim from "the crate is at authored size" and has to be checked
        -- separately: /brpropscale can put a scale back on a live crate, and it
        -- is the ruler the owner is asked to use. A container is a physics
        -- object and physics owns the transform matrix, so a scale applied once
        -- at spawn is one the next simulation step may throw away; the hover
        -- pass that re-asserts it for loose items skips containers by design.
        C.scaleAsks = {}
        C.env.BR.Loop.step(C.env.BR.Loop.TICK)
        ok((C.scaleAsks[obj] or 0) > 0,
            'and the crate pass still asks for the size on every container, so '
            .. 'putting a scale back is one config line',
            tostring(C.scaleAsks[obj]))
    end

    -- 8. AND SO IS THE VOLTS PILE, which is a loose item and therefore rides
    --    the hover pass instead.
    do
        local C = newProbeClient()
        C.add({ id = 3, kind = 'volts', item = 'volts', prop = A.voltsProp,
                x = 5.0, y = 5.0, z = 30.0, rarity = BR.Rarity.LEGENDARY,
                count = A.voltsAmount })
        C.slow(1000)
        local obj = next(C.objects)
        ok(C.scaled[obj] == A.voltsScale,
            'the Volts pile is drawn at voltsScale', tostring(C.scaled[obj]))
    end

    -- 9. ═══ NO CRATE IS HANDED TO PHYSICS BEFORE THE GROUND UNDER IT EXISTS
    --        (owner, 2026-08-23) ═══
    --
    -- "when it lands on top of a building the loot crate falls through the top
    -- of the building as if it doesn't have collisions. This leads to (when the
    -- chute is removed) the actual crate prop spawning at ground level inside a
    -- building."
    --
    -- A container is the ONE prop this file gives to the simulation: created
    -- dynamic, unfrozen, gravity-bound, ActivatePhysics'd, because "drive into
    -- one and it moves" (user, 2026-08-05). Map collision streams
    -- asynchronously, so a crate released above a roof that has not arrived
    -- falls through it and settles on the terrain -- and stays, because the 10Hz
    -- pass then records that sunken pose and the husk inherits it.
    --
    -- ORDER, NOT PRESENCE. "RequestCollisionAtCoord was called" is satisfied by
    -- calling it after the box has already been let go.
    do
        local C = newProbeClient()
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)

        local asked = C.only('collision')
        ok(#asked > 0, 'a crate asks for the collision under it', #asked)
        if asked[1] then
            ok(asked[1][2] == 5.0 and asked[1][3] == 5.0,
                'at its own point, not the player\'s',
                ('%.1f, %.1f'):format(asked[1][2], asked[1][3]))
        end

        local firstAsk = C.firstAt('collision')
        local physics  = C.firstAt('physics')
        ok(firstAsk and physics and firstAsk < physics,
            'and it is asked for BEFORE gravity is switched on',
            ('collision at %s, physics at %s'):format(tostring(firstAsk),
                                                      tostring(physics)))
        -- FROZEN ACROSS THE WAIT. The wait yields, which is the only place in
        -- the spawn worker where the simulation gets a step before the prop is
        -- configured -- so a crate that fell through the roof DURING its own
        -- collision wait would be a very funny bug to have written.
        local freezes = C.only('freeze')
        ok(#freezes >= 2 and freezes[1][3] == true,
            'the crate is frozen before the wait', #freezes)
        ok(freezes[#freezes][3] == false,
            'and released after it')
    end

    -- 10. ═══ AND THE PROBE IS TAKEN AGAIN AFTERWARDS, WHICH IS THE OTHER HALF
    --         ═══
    --
    -- Before the building's collision arrives the ground probe is not wrong so
    -- much as answering a different question: it finds the terrain, confidently,
    -- and a crate placed on that is BUILT at street level inside the building
    -- rather than falling into it. Waiting for collision without re-probing
    -- fixes the fall and leaves the spawn.
    do
        local C = newProbeClient()
        C.collisionAfter = 3                       -- the roof streams in late
        C.lateGroundAt[C.key(5.0, 5.0)] = 64.0     -- ...and it is 34m up
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)

        local obj = next(C.objects)
        ok(obj ~= nil, 'the crate is built')
        if obj then
            ok(C.objects[obj].z > 60.0,
                'and ends up on the roof that streamed in, not on the terrain '
                .. 'the first probe found',
                ('%.1f'):format(C.objects[obj].z))
        end
        ok(#C.only('move') > 0,
            'because the re-probe moved it once the collision was really there')
    end

    -- 11. THE WAIT IS BOUNDED, AND A NATIVE THAT NEVER SAYS YES DOES NOT COST
    --     THE MATCH ITS LOOT. Worst case is the behaviour that shipped before
    --     any of this: a crate released exactly as it always was.
    do
        local C = newProbeClient()
        C.collisionLoaded = 0                      -- never, in the 1/0 shape
        C.add(crateAt(5.0, 5.0))
        C.slow(1000)
        ok(C.props() > 0, 'the crate is still built')
        ok(C.firstAt('physics') ~= nil,
            'and still handed to physics when the budget runs out')
        local freezes = C.only('freeze')
        ok(freezes[#freezes] and freezes[#freezes][3] == false,
            'and not left frozen in mid-air for the rest of the match')
    end

    -- 12. A LOOSE ITEM PAYS NONE OF IT. Rifles and bandages are frozen and
    --     cannot fall through anything, and 3,200 of them each opening a
    --     streaming request would be a real cost for no gain.
    do
        local C = newProbeClient()
        C.add({ id = 4, kind = 'consumable', item = 'bandage',
                prop = 'prop_ld_health_pack',
                x = 5.0, y = 5.0, z = 30.0, rarity = BR.Rarity.COMMON,
                count = 1 })
        C.slow(1000)
        ok(C.props() > 0, 'the item is built')
        ok(#C.only('collision') == 0,
            'and nothing asked for a collision stream on its behalf',
            #C.only('collision'))
    end
end

-- -------------------------------------------------------- spectate policy ---
--
-- THE INFORMATION LEAK, ASSERTED (#192). A dead player with a working voice
-- channel who can see an enemy is a spotter, so the target set is their own
-- squad for as long as any of that squad is standing. These are the tests that
-- have to fail if that ever stops being true -- which is why the rule lives in a
-- pure function rather than in a server file that can only be exercised by
-- playing a match.

describe('spectate.squadRule')
do
    local S = BR.SpectateSolve

    --- Four players, two squads of two. Everyone alive unless named in `dead`.
    local function world(dead)
        dead = dead or {}
        local out = {}
        for _, r in ipairs({
            { src = 1, squadId = 'sq1', name = 'Me' },
            { src = 2, squadId = 'sq1', name = 'Mate' },
            { src = 3, squadId = 'sq2', name = 'Enemy1' },
            { src = 4, squadId = 'sq2', name = 'Enemy2' },
        }) do
            r.living = not dead[r.src]
            out[#out + 1] = r
        end
        return out
    end

    local function names(list)
        local out = {}
        for _, p in ipairs(list) do out[#out + 1] = p.name end
        return table.concat(out, ',')
    end

    -- 1. THE WHOLE POINT. Dead, one squadmate alive, two enemies alive -- and
    --    `free` ON, which is the strongest form of the claim: even with the
    --    widening explicitly allowed, it must not be reachable.
    local t, policy = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = true, players = world({ [1] = true }),
    })
    ok(#t == 1 and t[1].src == 2,
        'a dead player sees ONLY their living squadmate, even with free spectate on',
        names(t))
    ok(policy == 'squad', 'and the policy says so', policy)

    -- 2. The same with free OFF, which must be identical -- the flag has no say
    --    while a squadmate lives, and a test that only covered the off case
    --    could not tell the two apart.
    t = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = false, players = world({ [1] = true }),
    })
    ok(#t == 1 and t[1].src == 2, 'the free flag changes nothing while a mate lives',
        names(t))

    -- 3. A DEAD SQUADMATE IS NOT A TARGET. The wheel is living squadmates, not
    --    squad membership -- otherwise the first thing a dead player sees is
    --    another corpse.
    t = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = true,
        players = world({ [1] = true, [2] = true }),
    })
    ok(#t == 2, 'once the whole squad is out, the set widens', names(t))
    ok(t[1].src == 3 and t[2].src == 4, 'to the living players outside it', names(t))

    -- 4. AND ONLY IF IT IS ALLOWED TO. Same wiped squad, free off: nothing.
    local none
    t, none = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = false,
        players = world({ [1] = true, [2] = true }),
    })
    ok(#t == 0, 'refusing free spectate leaves a wiped squad with nobody to watch',
        names(t))
    ok(none == 'none', 'and says none rather than pretending it is a squad', none)

    -- 5. NEVER MYSELF, on either branch.
    t = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = true,
        players = world({ [1] = true, [2] = true }),
    })
    for _, p in ipairs(t) do
        ok(p.src ~= 1, 'the spectator is never on their own list')
    end

    -- 6. SOLOS FALL OUT FOR FREE. No squadId means the squad list is empty on
    --    the first pass, so a solo lands on the wider branch with no mode check
    --    anywhere -- #192: "in solos this is moot".
    t, policy = S.playerTargets({
        mySrc = 1, squadId = nil, free = true,
        players = {
            { src = 1, living = false, name = 'Me' },
            { src = 2, living = true,  name = 'Other' },
        },
    })
    ok(#t == 1 and t[1].src == 2 and policy == 'free',
        'a solo player reaches the wider set with no squad check to satisfy',
        policy)

    -- 7. A SQUAD OF ONE IS STILL A SQUAD, and it is empty the moment its only
    --    member dies. This is the case a `squadId ~= nil` guard alone would get
    --    wrong -- the id is set, and there is still nobody to watch.
    t, policy = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = false,
        players = { { src = 1, squadId = 'sq1', living = false, name = 'Me' } },
    })
    ok(#t == 0 and policy == 'none', 'a one-player squad wiped has no targets', policy)

    -- 8. AN EMPTY WORLD IS NOT AN ERROR.
    t = S.playerTargets({ mySrc = 1, squadId = 'sq1', free = true, players = {} })
    ok(#t == 0, 'no players at all is an empty list, not a crash')
    ok(#S.playerTargets({}) == 0, 'and neither is an empty view')
end

-- ------------------------------------------------------- spectate: killer ---
--
-- "If in solos, the default spectate target should be the killer (if there was
-- one)." -- the owner, 2026-08-22.
--
-- The claims worth pinning are not "the killer appears somewhere". They are:
-- SOLOS ONLY, FIRST rather than merely present, a NO-KILLER path that is the old
-- answer unchanged, and -- the one that would actually leak -- that this cannot
-- reach past the squad rule.

describe('spectate.killerFirst')
do
    local S = BR.SpectateSolve

    local function names(list)
        local out = {}
        for _, p in ipairs(list) do out[#out + 1] = p.name end
        return table.concat(out, ',')
    end

    -- A solo world: me (dead), and three living strangers. src order is 2,3,4,
    -- so `bySrc` alone would always answer 2 -- which is what makes 4 the
    -- interesting killer to name.
    local function solos(killerSrc, free)
        return {
            mySrc = 1, squadId = nil, free = free, killerSrc = killerSrc,
            players = {
                { src = 1, living = false, name = 'Me' },
                { src = 2, living = true,  name = 'Alpha' },
                { src = 3, living = true,  name = 'Bravo' },
                { src = 4, living = true,  name = 'Killer' },
            },
        }
    end

    -- ═══ 1. THE SHIPPED CONFIGURATION, AND SOLOS ARE NOT SUBJECT TO IT ═══
    --
    -- An earlier version made the killer the WHOLE list when free spectate was
    -- off. The owner rejected that (2026-08-22): "I'm not asking for their
    -- killer to be the sole spectate option, just the first one they see. If
    -- there are other players in the match available to spectate, they should
    -- still be able to select between those."
    --
    -- So `free` no longer reaches a solo at all. It governs the case it was
    -- written for -- a SQUAD player whose squad has been wiped -- and case 9
    -- below is the leak test for that.
    local t, policy = S.playerTargets(solos(4, false))
    ok(#t == 3, 'a dead solo is offered every living player, free spectate or not',
        names(t))
    ok(t[1].src == 4, 'with the one who killed them first', names(t))
    ok(t[2].src == 2 and t[3].src == 3,
        'and the rest in src order behind them', names(t))
    ok(policy == 'free',
        'the policy says free, because a widened set is what they got',
        policy)

    -- 2. AND CYCLING REACHES THE OTHERS, which is the whole of the correction:
    --    the earlier list of one could not be walked off.
    ok(S.step(t, 4, 1).src == 2 and S.step(t, 4, -1).src == 3,
        'and the arrows walk off the killer onto the rest of the lobby')

    -- 3. NO KILLER IS NOT NO TARGETS ANY MORE. The storm, a fall, a car with
    --    nobody in it (#194) all arrive as nil -- and a solo who died to the
    --    storm still gets the lobby, just in plain src order.
    t, policy = S.playerTargets(solos(nil, false))
    ok(#t == 3 and policy == 'free',
        'a solo killed by the storm still watches somebody', policy)
    ok(t[1].src == 2, 'in src order, with nobody promoted', names(t))

    -- 4. A KILLER WHO HAS SINCE DIED IS NOT PROMOTED. Same `living` test every
    --    other candidate passes -- the killer is the front of a set, not an
    --    exception to what may be in one. The set itself is unaffected.
    local view = solos(4, false)
    view.players[4].living = false
    t, policy = S.playerTargets(view)
    ok(#t == 2 and t[1].src == 2,
        'a dead killer is not promoted, and the living rest remain', names(t))

    -- 5. A KILLER WHO HAS LEFT. The server resolves a licence to a live id and
    --    gets nothing, so the solver is handed an id that is on no row.
    t, policy = S.playerTargets(solos(99, false))
    ok(#t == 3 and t[1].src == 2,
        'a killer who is gone is not invented, and promotes nobody', names(t))

    -- 6. WITH FREE SPECTATE ON, NOTHING ABOUT A SOLO CHANGES. It used to be the
    --    branch that widened them; now they were never narrowed, so the flag is
    --    inert here and this asserts that rather than assuming it.
    t, policy = S.playerTargets(solos(4, true))
    ok(#t == 3, 'free spectate still offers everyone', names(t))
    ok(t[1].src == 4, 'with the killer first', names(t))
    ok(t[2].src == 2 and t[3].src == 3,
        'and the rest still in src order behind them', names(t))
    ok(policy == 'free',
        'the policy still says free, because free is what admitted the list',
        policy)

    -- 7. FIRST IS WHAT "DEFAULT" MEANS. step() with no current target returns
    --    list[1], so this is the assertion that the owner's word is satisfied
    --    rather than the list merely being ordered.
    ok(S.step(t, nil, 0).src == 4, 'so opening a session lands on the killer')

    -- 8. AND CYCLING STILL WORKS off that front position.
    ok(S.step(t, 4, 1).src == 2, 'next steps off the killer normally')

    -- 9. THE SQUAD RULE IS NOT REACHABLE FROM HERE, WHICH IS THE LEAK TEST.
    --    A squad player killed by an enemy, one mate still standing, free ON --
    --    every knob turned the wrong way at once. The answer must still be the
    --    mate and only the mate.
    t, policy = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = true, killerSrc = 4,
        players = {
            { src = 1, squadId = 'sq1', living = false, name = 'Me' },
            { src = 2, squadId = 'sq1', living = true,  name = 'Mate' },
            { src = 4, squadId = 'sq2', living = true,  name = 'Killer' },
        },
    })
    ok(#t == 1 and t[1].src == 2 and policy == 'squad',
        'a killer cannot be spectated past a living squadmate', names(t))

    -- 10. SQUAD BEHAVIOUR IS UNCHANGED EVEN WHEN THE SQUAD IS WIPED. The owner
    --     said solos; a squad player whose squad is gone gets the set they got
    --     yesterday, in the order they got it, killer or no killer.
    local base = {
        { src = 1, squadId = 'sq1', living = false, name = 'Me' },
        { src = 2, squadId = 'sq1', living = false, name = 'Mate' },
        { src = 3, squadId = 'sq2', living = true,  name = 'Other' },
        { src = 4, squadId = 'sq2', living = true,  name = 'Killer' },
    }
    local withKiller = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = true, killerSrc = 4, players = base })
    local without = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = true, players = base })
    ok(names(withKiller) == names(without) and names(without) == 'Other,Killer',
        'a wiped SQUAD is not reordered by who killed them', names(withKiller))

    -- 11. ...AND A WIPED SQUAD WITH FREE OFF STILL GETS NOTHING, rather than
    --     picking up a killer-cam through the solos branch.
    t, policy = S.playerTargets({
        mySrc = 1, squadId = 'sq1', free = false, killerSrc = 4, players = base })
    ok(#t == 0 and policy == 'none',
        'and free-off keeps a wiped squad with nobody to watch', policy)

    -- 12. NEVER MYSELF, even if something upstream managed to name me. The
    --     server guards it twice already (attributedKiller refuses a self-hit
    --     and eliminate writes the licence only when killerSrc ~= src); this is
    --     the third place it cannot happen.
    t = S.playerTargets({
        mySrc = 1, squadId = nil, free = false, killerSrc = 1,
        players = { { src = 1, living = true, name = 'Me' } } })
    ok(#t == 0, 'a player is never handed their own camera as a killer-cam')

    -- 13. SERVER ID 0 IS A REAL ID AND `nil` IS THE ONLY "NO KILLER". In Lua 0
    --     is truthy, so a `if view.killerSrc then` would behave identically here
    --     -- but the same expression written as a truth test elsewhere is how
    --     this repo has shipped that bug four times. Pinned from both ends.
    t, policy = S.playerTargets({
        mySrc = 1, squadId = nil, free = false, killerSrc = 0,
        players = {
            { src = 0, living = true,  name = 'Zero' },
            { src = 1, living = false, name = 'Me' },
        } })
    ok(#t == 1 and t[1].src == 0 and policy == 'free',
        'a killer holding server id 0 is still promoted to the front', policy)

    -- 14. AND AN ABSENT killerSrc IS NOT A KILLER AT ALL -- the view every
    --     existing caller built before this field existed.
    t, policy = S.playerTargets({
        mySrc = 1, squadId = nil, free = true,
        players = {
            { src = 2, living = true,  name = 'Alpha' },
            { src = 1, living = false, name = 'Me' },
        } })
    ok(#t == 1 and t[1].src == 2 and policy == 'free',
        'a view with no killerSrc behaves exactly as it did before', policy)
end

describe('spectate.adminPolicy')
do
    local S = BR.SpectateSolve
    local everyone = {
        { src = 1, name = 'Admin' },
        { src = 5, name = 'Suspect' },
    }

    -- AN ADMIN IS NOT SUBJECT TO THE SQUAD RULE, and that is the whole reason
    -- this is a second function rather than a flag on the first: the rule
    -- protects players from each other, not players from moderation.
    local t, policy = S.adminTargets({ want = 5, players = everyone })
    ok(#t == 1 and t[1].src == 5 and policy == 'admin',
        'an admin gets the person they named', policy)

    -- ...BUT ONLY IF THAT PERSON IS HERE. A server id nobody is holding is the
    -- recycled-id hazard, and the answer is nothing rather than a guess.
    local miss
    t, miss = S.adminTargets({ want = 9, players = everyone })
    ok(#t == 0 and miss == 'none', 'and nobody at all when they are not connected',
        miss)
    ok(#S.adminTargets({}) == 0, 'an empty view is empty, not an error')

    -- THE TWO POLICIES CANNOT BE CONFUSED FOR ONE ANOTHER. Handing the admin
    -- view to the player policy is not a way to widen anything: it has no
    -- squadId and no `living`, so it comes back empty rather than permissive.
    ok(#S.playerTargets({ want = 5, players = everyone }) == 0,
        'the player policy refuses an admin-shaped view rather than opening up')
end

describe('spectate.step')
do
    local S = BR.SpectateSolve
    local list = {
        { src = 2, name = 'B' }, { src = 4, name = 'D' }, { src = 7, name = 'G' },
    }

    ok(S.step(list, 2, 1).src == 4, 'next walks forward')
    ok(S.step(list, 7, 1).src == 2, 'and wraps at the end')
    ok(S.step(list, 2, -1).src == 7, 'previous wraps at the start')
    ok(S.step(list, 4, -1).src == 2, 'and walks back otherwise')

    -- 0 IS HOLD. In Lua `0` is truthy, so a careless `if dir then` would move on
    -- a re-resolve -- and this is the direction the 4 Hz feed sends on every
    -- single push. Getting it wrong is a camera that cycles targets four times
    -- a second.
    ok(S.step(list, 4, 0).src == 4, 'dir 0 holds the current target')
    ok(S.step(list, 4).src == 4, 'and so does no direction at all')

    -- A TARGET THAT IS NO LONGER ON THE LIST LANDS SOMEWHERE, rather than
    -- ending the session. This is the path every death of a watched player
    -- takes.
    ok(S.step(list, 99, 1).src == 2, 'a lost target falls to the first candidate')
    ok(S.step(list, 99, -1).src == 7, 'or the last one, going the other way')
    ok(S.step(list, 99, 0).src == 2, 'and holding nothing lands on the first')

    ok(S.step({}, 2, 1) == nil, 'an empty list has no next')
    ok(S.step(nil, 2, 1) == nil, 'and neither does no list')

    local one = { { src = 3, name = 'C' } }
    ok(S.step(one, 3, 1).src == 3, 'a single candidate is its own next')
    ok(S.step(one, 3, -1).src == 3, 'and its own previous')
end

-- --------------------------------------------------------- vehicles (#193) ---

describe('vehicles.allowlist')
do
    local V = BR.Config.VehicleRefusal

    -- THE POLARITY, ASSERTED FIRST, because it is the one thing about this table
    -- that is the opposite of weapons.lua's and the one thing a careless edit
    -- inverts. Absence is PERMISSION here.
    ok(BR.Config.IsAllowedVehicle(0x00000001) == true,
        'a model nobody wrote down is allowed')

    local allowed, why = BR.Config.IsAllowedVehicle(0x2EA68690)   -- rhino
    ok(allowed == false and why == V.TANK,
        'a tank is refused, and #215 gave tanks their own half of the rule')

    local _, ay = BR.Config.IsAllowedVehicle(0xB5EF4C33)          -- vigilante
    ok(ay == V.ARMED, 'an armed car is refused on the weapons half')

    local _, hy = BR.Config.IsAllowedVehicle(0x39D6E83F)          -- hydra
    ok(hy == V.FLIES, 'a jet is refused, on the flight half')

    -- THE SIGNED-HASH TRAP, AND IT IS THE BUG THIS PROJECT HAS SHIPPED FOUR
    -- TIMES. GetEntityModel reports signed; the table authors positive. Sixty-
    -- five of the hundred and thirty-two rows have the top bit set, so
    -- unnormalised this whole feature would refuse nothing that matters and look
    -- fine doing it.
    ok(BR.Config.IsAllowedVehicle(0x2EA68690 - 0x100000000) == false,
        'a tank is still refused when the hash arrives signed')
    ok(BR.Config.IsAllowedVehicle(0xB39B0AE6 - 0x100000000) == false,
        'and so is a fighter jet, whose hash has the top bit set')

    -- ZERO IS TRUTHY IN LUA, so BR.NormHash(0) answers 0 rather than nil and 0
    -- is in no row. A model the engine could not report must read as ordinary
    -- rather than as a cheat.
    ok(BR.Config.IsAllowedVehicle(0) == true, 'model 0 is allowed, not refused')
    ok(BR.Config.IsAllowedVehicle(nil) == true, 'and so is no model at all')

    -- THE BATTLE BUS. It is an aircraft, the rule refuses it, and that is safe
    -- only because client/bus.lua never networks it. If this ever flips, the
    -- reason is in config/vehicles.lua's header and the fix is not here.
    ok(BR.Config.IsAllowedVehicle(0x761E2AD3) == false,
        'the Battle Bus model is refused by the rule, as an aircraft')

    -- Every authored row resolves, in both hash forms, to its own reason. The
    -- gate proves this too; asserting it here means a broken table fails the
    -- suite as well as the gate.
    local rows, bad = 0, 0
    for _, v in ipairs(BR.Config.RefusedVehicles) do
        rows = rows + 1
        local a1, w1 = BR.Config.IsAllowedVehicle(v.hash)
        local signed = (v.hash & 0x80000000) ~= 0 and (v.hash - 0x100000000) or v.hash
        local a2, w2 = BR.Config.IsAllowedVehicle(signed)
        if a1 or a2 or w1 ~= v.why or w2 ~= v.why then bad = bad + 1 end
    end
    ok(rows > 0 and bad == 0,
        'every refused row resolves to its own reason, signed and unsigned',
        ('%d of %d rows did not'):format(bad, rows))

    -- THE SECOND SIGNAL. Two of GetVehicleType's eight values mean flight.
    ok(BR.Config.IsFlyingVehicleType('heli') == true,  'heli flies')
    ok(BR.Config.IsFlyingVehicleType('plane') == true, 'plane flies')
    ok(BR.Config.IsFlyingVehicleType('automobile') == false, 'a car does not')
    ok(BR.Config.IsFlyingVehicleType('boat') == false,
        'and neither does a boat -- the owner\'s rule does not reach them')
    ok(BR.Config.IsFlyingVehicleType('submarine') == false, 'nor a submarine')
    -- THE NATIVE ANSWERS nil FOR A NON-VEHICLE, and indexing a table with a nil
    -- key is an error in Lua rather than a miss -- which is why this is a
    -- function and not a bare lookup.
    ok(BR.Config.IsFlyingVehicleType(nil) == false, 'no type does not fly')
    ok(BR.Config.IsFlyingVehicleType(42) == false, 'and neither does a number')
end

-- ------------------------------------------------- vehicles: #215's widening --

describe('vehicles.widening')
do
    local V = BR.Config.VehicleRefusal

    -- THE THREE TANKS, BY NAME, BECAUSE "GTA HAS THREE" IS THE CLAIM THE TABLE
    -- MAKES AND A DELETED ROW WOULD NOT OTHERWISE SHOW UP: every other assertion
    -- about this table is about ROWS THAT ARE THERE.
    local tanks = { [0x2EA68690] = 'rhino', [0xAA6F980A] = 'khanjali',
                    [0xB53C6C52] = 'minitank' }
    local missing = {}
    for h, n in pairs(tanks) do
        local a, w = BR.Config.IsAllowedVehicle(h)
        if a or w ~= V.TANK then missing[#missing + 1] = n end
    end
    ok(#missing == 0, 'all three tanks are refused as tanks',
        table.concat(missing, ', '))

    -- ARENA WAR. Three spot checks rather than thirty-six, chosen for the three
    -- ways the block can be got wrong: a stem whose base name IS the contender,
    -- a stem whose base name is a road car, and the last variant of a stem --
    -- the one a list truncated at "2" would drop.
    ok(select(1, BR.Config.IsAllowedVehicle(0x20314B42)) == false,
        'zr380 is refused -- a stem whose base name is itself a contender')
    ok(select(1, BR.Config.IsAllowedVehicle(0x669EB40A)) == false,
        'monster3 is refused -- the arena variant of a road-car stem')
    ok(select(1, BR.Config.IsAllowedVehicle(0xA7DCC35C)) == false,
        'zr3803 is refused -- the Nightmare variant, which a short list drops')

    -- AND THE OTHER HALF OF THE ARENA WAR DLC IS STILL ALLOWED. The owner's rule
    -- is about weapons, not about which box a car came in; refusing an Itali GTO
    -- would be this file inventing a rule. This is the assertion that fails if
    -- somebody ever pastes "the Arena War vehicle list" in wholesale.
    ok(BR.Config.IsAllowedVehicle(0xEC3E3404) == true,
        'italigto -- an ordinary Arena War road car -- is allowed')
    ok(BR.Config.IsAllowedVehicle(0xEEF345EC) == true,
        'and so is the rcbandito')
    ok(BR.Config.IsAllowedVehicle(0x83070B62) == true,
        'and so is the plain impaler, whose stem the contenders share')

    -- The plain insurgent's rule, restated for the five class-19 exemptions:
    -- armoured is not armed.
    ok(BR.Config.IsAllowedVehicle(0xCEEA3F4B) == true,
        'a barracks is not in the refused table')

    -- Every exemption row resolves, in both hash forms. The gate proves this
    -- too; asserting it here means a broken exemption fails the suite as well.
    local exBad, exRows = 0, 0
    for _, v in ipairs(BR.Config.ClassNetExempt) do
        exRows = exRows + 1
        local signed = (v.hash & 0x80000000) ~= 0 and (v.hash - 0x100000000) or v.hash
        if BR.Config.ClassNetExemptByHash[BR.NormHash(v.hash)] == nil
           or BR.Config.ClassNetExemptByHash[BR.NormHash(signed)] == nil then
            exBad = exBad + 1
        end
    end
    ok(exRows > 0 and exBad == 0,
        'every class-net exemption resolves from both hash forms',
        ('%d of %d did not'):format(exBad, exRows))
end

-- --------------------------------------------- vehicles: the single asker ----

describe('vehicles.refusalFor')
do
    local V = BR.Config.VehicleRefusal
    local R = BR.Config.VehicleRefusalFor

    local function sig(t, c, seen)
        return {
            typeOf  = t ~= false and function() if seen then seen.type = true end return t end or nil,
            classOf = c ~= false and function() if seen then seen.class = true end return c end or nil,
        }
    end

    -- THE MODEL TABLE IS FIRST AND ITS ANSWER IS THE ANSWER. A Rhino is a tank
    -- and not merely "class 19 military", and that distinction is the whole
    -- reason the table runs before the nets.
    local why, signal = R(0x2EA68690, sig('automobile', 19))
    ok(why == V.TANK and signal == 'model',
        'the model table rules first, and says which half', tostring(signal))

    -- AND IT IS ASKED WITH THE HASH THE ENGINE ACTUALLY REPORTS.
    ok(select(1, R(0x2EA68690 - 0x100000000, sig(nil, nil))) == V.TANK,
        'and it answers the same from a signed hash')

    -- THE NETS ARE NOT PAID FOR WHEN THE TABLE HAS ALREADY REFUSED. This is the
    -- reason the signals arrive as functions rather than values, and the only
    -- way to see it is to watch whether they were called.
    local seen = {}
    R(0x2EA68690, sig('heli', 19, seen))
    ok(not seen.type and not seen.class,
        'a model the table names costs no native reads at all')

    -- THE TYPE NET, for an aircraft nobody wrote down.
    local w2, s2 = R(0x00000001, sig('heli', 0))
    ok(w2 == V.FLIES and s2 == 'type', 'an unlisted heli is caught by its type')

    -- ...and the class net only when the type net had nothing to say.
    local seen2 = {}
    R(0x00000001, sig('heli', 19, seen2))
    ok(seen2.type and not seen2.class,
        'the class read is skipped once the type has already refused')

    -- THE CLASS NET, which is the only signal that reaches the WEAPONS half.
    local w3, s3 = R(0x00000001, sig('automobile', 19))
    ok(w3 == V.ARMED and s3 == 'class',
        'unlisted military hardware is caught by its class')
    ok(select(2, R(0x00000001, sig('automobile', 15))) == 'class',
        'and class 15 is an aircraft even when the type says otherwise')

    -- AN ORDINARY CAR, WHICH IS EVERY CAR IN EVERY MATCH.
    local w4, s4 = R(0x00000001, sig('automobile', 4))
    ok(w4 == nil and s4 == nil, 'an ordinary car is allowed by all three')

    -- CLASS 0 IS COMPACTS AND `0` IS TRUTHY IN LUA. An implementation that wrote
    -- `if c then` would agree with this test; one that wrote `if not c then
    -- return end` would refuse nothing in a Compact and nobody would notice.
    -- What is asserted is the pair: 0 is read, and 0 is allowed.
    ok(R(0x00000001, sig('automobile', 0)) == nil, 'class 0 is Compacts, allowed')

    -- THE EXEMPTIONS. A Barracks IS class 19 and the class net must not take it.
    ok(R(0xCEEA3F4B, sig('automobile', 19)) == nil,
        'a barracks is class 19 and is still allowed')
    ok(R(0x780FFBD2 - 0x100000000, sig('automobile', 19)) == nil,
        'and from the signed hash the engine reports')
    -- ...and the exemption is checked BEFORE the class, so it costs no read.
    local seen3 = {}
    R(0xCEEA3F4B, sig('automobile', 19, seen3))
    ok(not seen3.class, 'and it costs no class read to find that out')

    -- THE EXEMPTION IS FOR THE CLASS NET ONLY. If somebody ever adds a refused
    -- model to it hoping to un-ban it, the model table still wins.
    ok(select(1, R(0x2EA68690, sig(nil, nil))) == V.TANK,
        'an exemption could not un-ban a table row even if one were added')

    -- NO SIGNALS AT ALL is the shape a caller that could not read the natives
    -- passes, and it must be "no opinion" rather than "refused".
    ok(R(0x00000001, nil) == nil, 'no signals means no opinion')
    ok(R(0x00000001, {}) == nil, 'and neither does an empty signal table')
    ok(R(nil, sig('heli', 19)) == V.FLIES,
        'a model the engine could not report still gets the nets')

    -- A PROVIDER THAT ANSWERED NOTHING. pcall'd natives return nil on a stale
    -- handle, and a nil KEY is an error in Lua rather than a miss -- which is
    -- the whole reason this is a guarded lookup and not a bare index.
    ok(R(0x00000001, sig(nil, nil)) == nil, 'providers that answer nil refuse nothing')
    ok(R(0x00000001, sig(false, nil)) == nil, 'nor a missing type provider')
    -- '19' AND NOT 'nineteen', AND THAT IS THE WHOLE TEST. `math.tointeger('19')`
    -- IS 19 in Lua 5.4 -- numeric strings coerce -- so a guard written as
    -- `if c ~= nil` would believe a native that answered a string and would
    -- refuse a vehicle on a value that was never a class. 'nineteen' passes
    -- either way and proves nothing; mutation testing said so.
    ok(R(0x00000001, sig(nil, '19')) == nil,
        'nor a class that came back as the STRING "19"')
    ok(R(0x00000001, sig(nil, 'nineteen')) == nil,
        'nor one that came back as prose')
end

-- ---------------------------------------------------------------------------
-- The strip payload, which had no coverage at all until 2026-08-22.
-- ---------------------------------------------------------------------------
--
-- WHY THAT GAP MATTERED MORE THAN A MISSING TEST USUALLY DOES.
-- `BR.IncidentBuild.fromStrip` and `.fromVehicle` return the SAME payload block
-- verbatim apart from one line, and `fromVehicle` is the one that was written
-- second, by copying. So `fromStrip` was the specification for a function that
-- had tests, while itself having none -- and every property the vehicle cases
-- below assert was, on this side, merely believed.
--
-- IT IS ALSO THE HALF THAT DECIDES WHAT AN ADMIN READS. The two summaries are
-- deliberately different sentences (see the note above `stripSummaryOf`): a
-- strip says a weapon appeared in a hand, a refused vehicle says a vehicle
-- appeared in the match, and the day those two converge is the day a moderation
-- record describes one finding as the other. The owner reported exactly that
-- failure on the corroboration channel on 2026-08-22; these cases pin the door
-- it did NOT come through, so that it stays shut.
--
-- MUTATION TESTED. Each was broken on purpose and this suite watched to fail by
-- name; the counts are what was observed rather than what was expected:
--
--   `fromStrip` reuses `summaryOf`                     2 cases
--   `fromStrip` reuses `vehicleSummaryOf`              2 cases
--   `fromStrip` drops the license guard                2 cases
--   `stripSummaryOf` loses its singular/plural rule    1 case
--   `fromStrip` grows a reporter                       1 case
--   the strip severity becomes a hardcoded 'high'      1 case
--   the vehicle severity becomes a hardcoded 'high'    1 case
--   `fromStrip` reads the OLDEST evidence record       2 cases
--
-- TWO OF THOSE SURVIVED THE FIRST PASS AND BOTH ARE WORTH KNOWING. Hardcoding
-- 'high' failed NOTHING, because `out.severity == BR.ShotTier[NO_WEAPON]`
-- compares a value against the lookup that produced it -- the pre-existing
-- vehicle case had the identical blind spot. Re-grading the table and watching
-- the payload move is what closes it, and both blocks now do that. Reading
-- `evidence[1]` instead of the newest record also failed nothing, because the
-- case handed the builder ONE record; it now hands it two with different squads.

describe('incident.strip')
do
    local LIC = 'license:hand'
    local CLEAR = {}
    local function ev(over)
        local e = {
            src = 4, name = 'Palmer', license = LIC, matchId = 9,
            count = 2, seq = 1, at = 55000,
        }
        for k, v in pairs(over or {}) do
            e[k] = (v ~= CLEAR) and v or nil
        end
        return e
    end

    ok(select(1, BR.IncidentBuild.fromStrip(nil, {})) == nil,
        'no event files nothing rather than throwing')

    local p, why = BR.IncidentBuild.fromStrip(ev({ license = CLEAR }), {})
    ok(p == nil and why == 'no license',
        'a strip with no license files nothing, and says why')
    ok(select(1, BR.IncidentBuild.fromStrip(ev({ license = '' }), {})) == nil,
        'an empty license is treated as no license')

    local out = BR.IncidentBuild.fromStrip(ev(), {})
    ok(out ~= nil, 'a licensed event files')
    ok(out.kind == 'anticheat' and out.category == 'system',
        'it reuses the anticheat shape rather than inventing a third')
    ok(out.state == 'pending_review', 'and lands in the review queue')
    ok(out.subjectLicense == LIC and out.subjectName == 'Palmer',
        'the subject is the player whose hand it was in')
    ok(out.matchId == 9 and out.atGameMs == 55000,
        'the match and the GAME clock ride along -- br_ringmaster realises the clock')
    ok(out.openedAt == nil,
        'and openedAt is NOT set here: br_core has no clock worth putting in a record')

    -- SEVERITY IS READ, NOT SPELLED, exactly as the vehicle cases below assert.
    ok(out.severity == BR.ShotTier[BR.ShotRefusal.NO_WEAPON],
        'severity comes from the taxonomy, not from a literal here')

    -- ...AND THAT ASSERTION ALONE PROVES NOTHING, WHICH IS WORTH KNOWING.
    -- `BR.ShotTier[NO_WEAPON]` is 'high' today, so the line above passes
    -- identically against a hardcoded 'high' -- verified by making that
    -- substitution and watching the whole suite stay green. Comparing a value
    -- against the lookup that produced it cannot tell a lookup from a copy of
    -- its answer.
    --
    -- SO THE TAXONOMY IS RE-GRADED AND THE PAYLOAD HAS TO FOLLOW. The tier is
    -- read at CALL time, not captured at load, which is the property the claim
    -- actually rests on: re-grade NO_WEAPON and every producer moves with it
    -- instead of one of them disagreeing. Restored immediately -- this table is
    -- global to the suite and every case after this one reads it.
    local realTier = BR.ShotTier[BR.ShotRefusal.NO_WEAPON]
    BR.ShotTier[BR.ShotRefusal.NO_WEAPON] = 'low'
    local regraded = BR.IncidentBuild.fromStrip(ev(), {})
    BR.ShotTier[BR.ShotRefusal.NO_WEAPON] = realTier
    ok(regraded and regraded.severity == 'low',
        're-grading the taxonomy re-grades the case, so it is genuinely read',
        regraded and tostring(regraded.severity))
    ok(BR.ShotTier[BR.ShotRefusal.NO_WEAPON] == realTier,
        'and the table is put back for every case after this one')

    -- NO REPORTER AT ALL -- absent rather than null, which is how the console
    -- reads "the system filed this". A sentinel here would make an anticheat
    -- filing look like a player report from nobody.
    ok(out.reporterLicense == nil and out.reporterName == nil,
        'no reporter key is set, so the console reads it as system-filed')

    -- NO REFUSAL BLOCK. That field carries `count` and `windowMs` from the shot
    -- validator and the console renders it as refused shots; a strip has neither
    -- number, and inventing them would dress up the finding.
    ok(out.refusal == nil, 'no refusal block is invented for a case with no shots')

    -- ═══ THE SENTENCE, WHICH IS THE WHOLE POINT OF NOT REUSING summaryOf ═══
    ok(BR.IncidentBuild.stripSummaryOf(1)
        == '1 unissued weapon taken out of the hand this match',
        'the summary is singular at one')
    ok(BR.IncidentBuild.stripSummaryOf(2)
        == '2 unissued weapons taken out of the hand this match',
        'and plural above it')
    ok(out.summary == BR.IncidentBuild.stripSummaryOf(2),
        'the payload carries that summary rather than a second spelling of it')
    -- NO SHOT WAS FIRED. `summaryOf` says "%d shots refused"; putting a number
    -- of shots on a case that has none is the small lie this sentence exists to
    -- avoid, and it is asserted as an absence so a re-wording cannot reintroduce
    -- it.
    ok(not out.summary:find('shot'),
        'and it never claims a shot was refused', out.summary)
    -- ...AND IT IS NOT THE VEHICLE ONE EITHER. The two functions are one copy
    -- apart; this is the assertion that fails if they are ever collapsed.
    ok(out.summary ~= BR.IncidentBuild.vehicleSummaryOf(2, nil)
        and not out.summary:find('vehicle'),
        'nor the refused-vehicle sentence', out.summary)

    -- Rubbish in the count must not reach a moderation record as "nil".
    ok(BR.IncidentBuild.stripSummaryOf(nil):find('^0 unissued weapons'),
        'a missing count reads as zero rather than as nil')

    -- ═══ THE SUBJECT ROW IS BUILT FROM THE NEWEST EVIDENCE RECORD ═══
    --
    -- It is what carries the squad the console needs to answer "were these two
    -- on a team", and squads change during a match. TWO RECORDS RATHER THAN ONE,
    -- with different squads, because a single record makes `evidence[#evidence]`
    -- and `evidence[1]` the same value -- verified by making that substitution
    -- and watching a one-record case stay green.
    local older = {
        key = 4, license = LIC, name = 'Palmer', matchId = 9, squadId = 2,
        openedAt = 10000, leftAt = nil, chat = {}, kills = {},
    }
    local newer = {
        key = 4, license = LIC, name = 'Palmer', matchId = 9, squadId = 5,
        openedAt = 30000, leftAt = 40000, chat = {}, kills = {},
    }
    local withEv = BR.IncidentBuild.fromStrip(ev(), { older, newer })
    ok(withEv.subjects and #withEv.subjects == 1, 'there is one subject')
    ok(withEv.subjects[1].squadId == 5,
        'the squad comes from the NEWEST record, not the first one in the list',
        withEv.subjects[1] and tostring(withEv.subjects[1].squadId))
    ok(withEv.subjects[1].left == true,
        'and so does whether they had already gone',
        withEv.subjects[1] and tostring(withEv.subjects[1].left))
    ok(#withEv.evidence == 2, 'both evidence records are attached', #withEv.evidence)
    ok(withEv.evidence[1].key == nil and withEv.evidence[2].key == nil,
        'and the server id is on neither of them')

    -- NO EVIDENCE IS NOT AN ERROR. A strip during warmup can precede anything
    -- the buffer holds, and the case must still open.
    ok(out.subjects and out.subjects[1] and out.subjects[1].squadId == nil,
        'with no records the squad is absent rather than invented')
    ok(out.subjects[1].left == false, 'and "already gone" is false rather than nil')
end

describe('incident.vehicle')
do
    local LIC = 'license:veh'
    local V = BR.Config.VehicleRefusal
    local CLEAR = {}
    local function ev(over)
        local e = {
            src = 5, name = 'Driver', license = LIC, matchId = 3,
            count = 2, seq = 1, why = V.FLIES, at = 60000,
        }
        for k, v in pairs(over or {}) do
            e[k] = (v ~= CLEAR) and v or nil
        end
        return e
    end

    ok(select(1, BR.IncidentBuild.fromVehicle(nil, {})) == nil,
        'no event files nothing rather than throwing')

    local p, why = BR.IncidentBuild.fromVehicle(ev({ license = CLEAR }), {})
    ok(p == nil and why == 'no license',
        'a refused vehicle with no license files nothing, and says why')
    ok(select(1, BR.IncidentBuild.fromVehicle(ev({ license = '' }), {})) == nil,
        'an empty license is treated as no license')

    local ok1 = BR.IncidentBuild.fromVehicle(ev(), {})
    ok(ok1 ~= nil, 'a licensed event files')
    ok(ok1.kind == 'anticheat' and ok1.category == 'system',
        'it reuses the anticheat shape rather than inventing a third')
    ok(ok1.state == 'pending_review', 'and lands in the review queue')
    ok(ok1.subjectLicense == LIC and ok1.subjectName == 'Driver',
        'the subject is the owning player')
    ok(ok1.matchId == 3 and ok1.atGameMs == 60000, 'the match and clock ride along')

    -- SEVERITY IS READ, NOT SPELLED. Comparing against the taxonomy rather than
    -- against 'high' is the whole point: if somebody re-grades NO_WEAPON, this
    -- follows instead of disagreeing.
    ok(ok1.severity == BR.ShotTier[BR.ShotRefusal.NO_WEAPON],
        'severity comes from the taxonomy, not from a literal here')

    -- ...PROVED THE ONLY WAY IT CAN BE. See the identical note in
    -- `incident.strip` above: the line above survives a hardcoded 'high'
    -- verbatim, because it compares a value against the lookup that produced
    -- it. Re-grading the table and watching the payload move is what makes the
    -- claim testable at all.
    local realTier = BR.ShotTier[BR.ShotRefusal.NO_WEAPON]
    BR.ShotTier[BR.ShotRefusal.NO_WEAPON] = 'low'
    local regraded = BR.IncidentBuild.fromVehicle(ev(), {})
    BR.ShotTier[BR.ShotRefusal.NO_WEAPON] = realTier
    ok(regraded and regraded.severity == 'low',
        're-grading the taxonomy re-grades the case, so it is genuinely read',
        regraded and tostring(regraded.severity))
    ok(BR.ShotTier[BR.ShotRefusal.NO_WEAPON] == realTier,
        'and the table is put back for every case after this one')

    -- NO REPORTER AT ALL -- absent rather than null, which is how the console
    -- reads "the system filed this".
    ok(ok1.reporterLicense == nil and ok1.reporterName == nil,
        'no reporter key is set, so the console reads it as system-filed')
    -- NO REFUSAL BLOCK: that field carries shot counts and this case has none.
    ok(ok1.refusal == nil, 'no refusal block is invented for a case with no shots')

    -- The one line an admin reads. Singular and plural both, because the bar is
    -- two and the corroborations climb from there -- a summary reading
    -- "1 refused vehicles" is exactly the small lie the strip path avoided.
    ok(BR.IncidentBuild.vehicleSummaryOf(1, V.FLIES)
        == '1 refused vehicle this match -- vehicle flies',
        'the summary is singular at one')
    ok(BR.IncidentBuild.vehicleSummaryOf(3, V.ARMED)
        == '3 refused vehicles this match -- vehicle has built-in weapons',
        'and plural above it, carrying the rule\'s own words')
    ok(ok1.summary == BR.IncidentBuild.vehicleSummaryOf(2, V.FLIES),
        'the payload carries that summary rather than a second spelling of it')

    -- Rubbish in the count must not reach a moderation record as "nil".
    ok(BR.IncidentBuild.vehicleSummaryOf(nil, V.FLIES):find('^0 refused vehicles'),
        'a missing count reads as zero rather than as nil')
end

-- ---------------------------------------------------------------------------
-- The detector itself, not just the functions under it.
-- ---------------------------------------------------------------------------
--
-- THIS REPO HAS TWICE HAD A MUTATION PASS BECAUSE EVERY PURE FUNCTION STAYED
-- CORRECT WHILE THE CALLER WIRED THEM WRONGLY. `IsAllowedVehicle` being right is
-- worth nothing if the handler tests it against the wrong entity, forgets the
-- population guard, or files on the first offence. So the real
-- br_core/server/vehicles.lua is loaded here and driven through the same event
-- FiveM raises.

--- @return table  a loaded server/vehicles.lua and the levers to drive it
local function newVehicleServer()
    local env = newSandbox()
    -- THE CLOCK DOES NOT START AT ZERO, AND THAT IS NOT ARBITRARY. The throttle
    -- uses `rec.at ~= 0` as its "never counted yet" sentinel -- server/strip.lua's
    -- idiom, kept deliberately identical -- so a test clock at 0 makes the first
    -- counted offence indistinguishable from no offence and the window never
    -- opens. GetGameTimer() is milliseconds since the process started and is
    -- never 0 by the time a player is in a match, so starting here is what the
    -- real server looks like rather than a workaround.
    local S = { now = 50000, roster = {}, filed = {}, cancels = 0, ents = {} }

    env.GetGameTimer = function() return S.now end
    env.print        = function() end
    env.GetCurrentResourceName = function() return 'br_core' end
    env.RegisterNetEvent = function() end
    env.RegisterCommand  = function() end
    -- COUNTED RATHER THAN STUBBED AWAY. The owner said "don't stop them", so a
    -- cancel appearing in this file is a behaviour change and the suite should
    -- say so rather than silently tolerate it.
    env.CancelEvent = function() S.cancels = S.cancels + 1 end
    env.Citizen = { CreateThread = function() end, Wait = function() end }

    local handlers = {}
    env.AddEventHandler = function(n, fn)
        handlers[n] = handlers[n] or {}
        handlers[n][#handlers[n] + 1] = fn
    end
    env.TriggerEvent = function(n, ...)
        if n == 'br:core:vehicle' then
            local a = { ... }
            S.filed[#S.filed + 1] = a[1]
        end
        for _, fn in ipairs(handlers[n] or {}) do fn(...) end
    end

    -- The entity, as the engine would answer for it.
    local function e(h) return S.ents[h] or {} end
    env.DoesEntityExist         = function(h) return e(h).exists end
    env.GetEntityType           = function(h) return e(h).etype or 0 end
    env.GetEntityModel          = function(h) return e(h).model or 0 end
    env.GetEntityPopulationType = function(h) return e(h).pop end
    env.GetVehicleType          = function(h)
        local v = e(h)
        if v.throws then error('Tried to access invalid entity') end
        return v.vtype
    end
    env.NetworkGetEntityOwner   = function(h) return e(h).owner end

    loadInto(env, SANDBOX_LIB)
    env.BR.Roster = {
        get      = function(s) return S.roster[s] end,
        licenseOf = function(s)
            local r = S.roster[s]
            return r and r.license or nil
        end,
        -- THE ROADKILL LEDGER'S TWO VERBS, and they are here because that half of
        -- the file registers a scheduler job at LOAD time -- so without them this
        -- sandbox cannot load the detector either. The ledger itself is driven in
        -- tools/test_roster.lua against the real roster, real positions and real
        -- combat; what it needs here is only to not explode.
        each = function(pred, fn)
            for s, e in pairs(S.roster) do
                if not pred or pred(e) then fn(s, e) end
            end
        end,
        sampleIntervalMs = function() return 250 end,
    }
    loadInto(env, { 'br_core/server/vehicles.lua' })

    --- Raise `entityCreating` exactly as the platform raises it.
    function S.create(handle, spec)
        S.ents[handle] = spec
        for _, fn in ipairs(handlers['entityCreating'] or {}) do fn(handle) end
    end
    function S.drop(src)
        env.source = src
        for _, fn in ipairs(handlers['playerDropped'] or {}) do fn() end
    end
    S.env = env
    S.stats = function() return env.BR.Vehicles.stats() end
    return S
end

describe('vehicles.detector')
do
    local RHINO = 0x2EA68690
    local ADDER = 0xB779A091           -- an ordinary supercar; in no refused row
    local MISSION, AMBIENT = 7, 5

    local function alive(S, src)
        S.roster[src] = { src = src, name = 'P' .. src, matchId = 1,
                          state = S.env.BR.PlayerState.ALIVE,
                          license = 'license:p' .. src }
    end

    local function scripted(model, owner, vtype)
        return { exists = true, etype = 2, model = model, pop = MISSION,
                 owner = owner, vtype = vtype or 'automobile' }
    end

    -- An ordinary car costs nothing and files nothing. This is every vehicle in
    -- every match under Option A, so it is the path that must stay silent.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, scripted(ADDER, 1))
        S.create(11, scripted(ADDER, 1))
        ok(#S.filed == 0, 'an allowed model never files')
        ok(S.stats().allowed == 2, 'and is counted as allowed')
    end

    -- THE BAR IS TWO, AND THE FIRST IS SILENT. Same cadence as strip.lua, for a
    -- reason specific to this detector: one refused vehicle rests on one
    -- ownership read, and ownership migrates by proximity.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, scripted(RHINO, 1))
        ok(#S.filed == 0, 'the first refused vehicle is recorded and announced to nobody')
        S.now = S.now + 1000
        S.create(11, scripted(RHINO, 1))
        ok(#S.filed == 1, 'the second opens the case')

        local f = S.filed[1]
        ok(f.count == 2 and f.seq == 1, 'carrying the offence count and the first seq')
        ok(f.license == 'license:p1' and f.matchId == 1, 'and the subject and match')
        ok(f.why == BR.Config.VehicleRefusal.TANK, 'and which half of the rule it tripped')
        ok(f.model == RHINO, 'and the model, normalised, for the server log')

        -- EVERY ONE AFTER IT ANNOUNCES, climbing by one, so a gap means a lost
        -- message rather than quiet offences.
        S.now = S.now + 1000
        S.create(12, scripted(RHINO, 1))
        ok(#S.filed == 2 and S.filed[2].count == 3 and S.filed[2].seq == 2,
            'and every one after it corroborates, climbing by one')

        ok(S.cancels == 0,
            'nothing is ever cancelled -- the owner said do not stop them')
    end

    -- THE THROTTLE IS THE ONLY REAL BOUND ON A PATH THE ATTACKER CHOOSES THE
    -- VOLUME OF. Two inside the window is one counted offence.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, scripted(RHINO, 1))
        S.now = S.now + 100
        S.create(11, scripted(RHINO, 1))
        ok(#S.filed == 0, 'a second inside the throttle window does not reach the bar')
        ok(S.stats().throttled == 1, 'and is counted as throttled')
        S.now = S.now + 900
        S.create(12, scripted(RHINO, 1))
        ok(#S.filed == 1, 'the next one outside the window does')
    end

    -- THE GUARD THAT MATTERS MOST UNDER OPTION A. The map is full of vehicles
    -- the engine placed; blaming a player for one would be the worst false
    -- positive available here.
    do
        local S = newVehicleServer(); alive(S, 1)
        for h = 10, 14 do
            S.now = S.now + 1000
            S.create(h, { exists = true, etype = 2, model = RHINO,
                          pop = AMBIENT, owner = 1, vtype = 'automobile' })
        end
        ok(#S.filed == 0, 'a refused model the ENGINE placed files nothing')
        ok(S.stats().ambient == 5, 'but is counted, because it is also the bypass signal')
        ok(S.stats().models[RHINO] == 5, 'and the model is listed for a human to read')
    end

    -- THE SECOND SIGNAL: an aircraft config/vehicles.lua does not name is still
    -- caught, because the engine knows it is a plane. This is what stops the
    -- deny-list rotting into uniform permission.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, scripted(0x1234ABCD, 1, 'plane'))
        S.now = S.now + 1000
        S.create(11, scripted(0x1234ABCD, 1, 'heli'))
        ok(#S.filed == 1, 'an unnamed aircraft is refused on its class alone')
        ok(S.filed[1].why == BR.Config.VehicleRefusal.FLIES, 'as flight, not as weapons')
        ok(S.stats().byType == 2, 'and is counted as a gap in the model table')
    end

    -- A NAMED MODEL KEEPS THE TABLE'S REASON. The class cannot tell "armed" from
    -- "flies", so the table must win where it has an opinion.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, scripted(RHINO, 1, 'plane'))
        S.now = S.now + 1000
        S.create(11, scripted(RHINO, 1, 'plane'))
        ok(S.filed[1].why == BR.Config.VehicleRefusal.TANK,
            'a named model keeps its authored reason even when the class disagrees')
    end

    -- The native throws on a stale handle rather than answering. An uncaught
    -- throw here would take the model check down with it.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, { exists = true, etype = 2, model = ADDER, pop = MISSION,
                       owner = 1, throws = true })
        ok(S.stats().allowed == 1,
            'a throwing GetVehicleType is caught, and the model check still ran')
    end

    -- Things that are not this file's business.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, { exists = false, etype = 2, model = RHINO, pop = MISSION, owner = 1 })
        ok(S.stats().vehicles == 0, 'an entity that does not exist is not examined')
        S.create(11, { exists = true, etype = 1, model = RHINO, pop = MISSION, owner = 1 })
        ok(S.stats().vehicles == 0, 'and neither is a ped')
    end

    -- ═══ THE NUMERIC BOOL, WHICH IS THIS CODEBASE'S MOST EXPENSIVE RECURRING
    --     BUG AND HAS SHIPPED FIVE TIMES ═══
    --
    -- A FiveM native declared BOOL hands Lua a NUMBER on some builds. In Lua
    -- `0` is TRUTHY, so `if DoesEntityExist(e) then` is TRUE for an entity that
    -- does not exist. Testing only with `true`/`false` cannot see this: a
    -- mutation replacing didHit with plain truthiness stayed green until these
    -- two cases existed.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, { exists = 0, etype = 2, model = RHINO, pop = MISSION, owner = 1 })
        ok(S.stats().vehicles == 0,
            'DoesEntityExist answering the NUMBER 0 is still "no"')
        S.now = S.now + 1000
        S.create(11, { exists = 1, etype = 2, model = RHINO, pop = MISSION, owner = 1 })
        ok(S.stats().vehicles == 1,
            'and answering the NUMBER 1 is still "yes"')
    end

    -- A COUNT BELONGS TO A MATCH, NOT TO A CONNECTION. The same player carried
    -- into the next round starts clean -- otherwise one offence last match plus
    -- one this match opens a case about a round in which they did it once.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, scripted(RHINO, 1))
        S.roster[1].matchId = 2
        S.now = S.now + 1000
        S.create(11, scripted(RHINO, 1))
        ok(#S.filed == 0, 'a count does not carry across a match boundary')
        S.now = S.now + 1000
        S.create(12, scripted(RHINO, 1))
        ok(#S.filed == 1 and S.filed[1].matchId == 2,
            'the new match opens its own case at its own second offence')
    end

    -- SOURCE 0 IS THE SERVER CONSOLE AND `0` IS TRUTHY. A bare `if owner then`
    -- would accept it and go looking for a roster entry that cannot exist.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, { exists = true, etype = 2, model = RHINO, pop = MISSION, owner = 0 })
        S.create(11, { exists = true, etype = 2, model = RHINO, pop = MISSION, owner = -1 })
        ok(S.stats().unowned == 2, 'owner 0 and owner -1 are both "nobody"')
        ok(#S.filed == 0, 'and neither files')
    end

    -- Outside a match there is no timeline to put this on.
    do
        local S = newVehicleServer()
        S.roster[1] = { src = 1, name = 'P1', matchId = nil,
                        state = S.env.BR.PlayerState.LOBBY, license = 'license:p1' }
        S.create(10, scripted(RHINO, 1))
        S.now = S.now + 1000
        S.create(11, scripted(RHINO, 1))
        ok(#S.filed == 0, 'a player in the lobby draws no case')
    end

    -- SERVER IDS ARE RECYCLED WITHIN THE MINUTE. A count left behind is
    -- inherited by whoever lands in that slot next.
    do
        local S = newVehicleServer(); alive(S, 1)
        S.create(10, scripted(RHINO, 1))
        S.drop(1)
        alive(S, 1)
        S.now = S.now + 1000
        S.create(11, scripted(RHINO, 1))
        ok(#S.filed == 0, 'a disconnect clears the count rather than passing it on')
    end
end

-- ---------------------------------------------------------------------------
-- Mad drivers: WHERE the pass measures "near the player" from.
--
-- "The NPC drivers are all too calm now, did something change?" -- the owner,
-- 2026-08-22, one day after spectating went live.
--
-- Something had. client/gamerules.lua maddens ambient drivers within
-- erraticRange of a point, and that point was PlayerPedId()'s coordinates. A
-- spectator's ped is a corpse where they fell -- client/spectate.lua never
-- moves it, deliberately, because an ADMIN spectator may be alive and
-- mid-match -- while SET_FOCUS_ENTITY drags the streaming volume onto the
-- target, so the traffic that populates and renders is the traffic around the
-- TARGET. Every vehicle in the shot sat hundreds of metres outside the range
-- test, none of them was ever re-tasked, and every driver the spectator could
-- see was a calm commuter.
--
-- Both directions are pinned below, because only fixing one of them is how
-- this comes back: a living player's anchor must STILL be their own ped.
-- ---------------------------------------------------------------------------

describe('mad drivers / anchor')
do
    local V = {}
    V.__index = V
    V.__sub = function(a, b)
        return setmetatable({ x = a.x - b.x, y = a.y - b.y, z = a.z - b.z }, V)
    end
    V.__len = function(a) return math.sqrt(a.x * a.x + a.y * a.y + a.z * a.z) end
    local function vec(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end

    local PED = 1

    --- One client with a vehicle pool, the real gamerules.lua on the real loop.
    --- @param pos table  [handle] = {x,y,z} for the ped and every vehicle
    local function newDriverClient(pos)
        local env = newSandbox()
        local C = { now = 1000, tasked = {}, pos = pos }

        env.GetGameTimer = function() return C.now end
        env.print = function() end
        env.GetCurrentResourceName = function() return 'br_core' end
        env.GetHashKey = function(s) return #tostring(s) end
        env.PlayerId = function() return 0 end
        env.GetPlayerServerId = function() return 1 end
        env.AddEventHandler = function() end
        env.RegisterNetEvent = function() end
        env.RegisterCommand = function() end
        env.TriggerServerEvent = function() end
        env.Citizen = { CreateThread = function() end, Wait = function() end,
                        SetTimeout = function() end }

        loadInto(env, SANDBOX_LIB)

        env.PlayerPedId     = function() return PED end
        env.DoesEntityExist = function(e) return C.pos[e] ~= nil end
        env.GetEntityCoords = function(e)
            local p = C.pos[e] or { x = 0.0, y = 0.0, z = 0.0 }
            return vec(p.x, p.y, p.z)
        end

        -- THE POOL IS EVERY VEHICLE, wherever it is. That is the real
        -- GetGamePool contract and it is what makes the range test the only
        -- thing deciding who gets treated -- which is the whole subject here.
        env.GetGamePool = function(kind)
            if kind ~= 'CVehicle' then return {} end
            local out = {}
            for h in pairs(C.pos) do
                if h ~= PED then out[#out + 1] = h end
            end
            table.sort(out)
            return out
        end

        -- Every vehicle has a driver, and none of them is a player. Returning a
        -- real Lua `false` is this build's contract; /brdrivers prints the raw
        -- value precisely because another build may not honour it.
        env.GetPedInVehicleSeat = function(veh) return veh + 100 end
        env.IsPedAPlayer = function() return false end

        env.SetDriverAbility        = function() end
        env.SetDriverAggressiveness = function() end
        env.SetPedKeepTask          = function() end
        env.SetDriveTaskMaxCruiseSpeed = function() end
        env.SetDriveTaskDrivingStyle   = function() end
        env.SetDriverRacingModifier    = function() end
        env.TaskVehicleDriveWander = function(_, veh)
            C.tasked[veh] = (C.tasked[veh] or 0) + 1
        end

        loadInto(env, { 'br_core/client/main.lua' })
        env.BR.Native = env.BR.Native or {}
        env.BR.Native.applyGameRules = function() end
        env.BR.State.me.state = env.BR.PlayerState.ALIVE

        loadInto(env, { 'br_core/client/gamerules.lua' })

        C.env = env
        --- Run one SLOW pass, the band madDrivers is registered into.
        function C.pass()
            env.BR.Loop.step(env.BR.Loop.SLOW)
            return env.BR.Gamerules.driverStats()
        end
        return C
    end

    -- A vehicle beside the ped, and one most of a kilometre away. erraticRange
    -- is 250m, so exactly one of them is in range of whichever anchor wins.
    local function layout()
        return {
            [PED] = { x = 0.0,   y = 0.0, z = 0.0 },   -- the ped / the corpse
            [10]  = { x = 10.0,  y = 0.0, z = 0.0 },   -- next to the ped
            [20]  = { x = 900.0, y = 0.0, z = 0.0 },   -- next to the target
        }
    end

    -- ALIVE: unchanged, and that is half the point of the fix.
    do
        local C = newDriverClient(layout())
        local S = C.pass()

        ok(S.ran, 'an alive player runs the pass')
        ok(S.anchorFrom == 'ped',
           'with no spectate session the anchor is the local ped, as it always was')
        ok(S.anchorOffPed < 0.001,
           'and it is the ped exactly, not near it', S.anchorOffPed)
        ok(C.tasked[10] == 1, 'the vehicle beside the player is re-tasked')
        ok(C.tasked[20] == nil, 'the vehicle 900m away is left alone')
        ok(S.treated == 1, 'one driver treated', S.treated)
    end

    -- SPECTATING: the anchor follows the shot, which is the regression.
    do
        local C = newDriverClient(layout())
        -- The session client/spectate.lua would be running: the ped has not
        -- moved and must not, and the camera is on somebody 900m away.
        C.env.BR.Spectate = {
            active = function() return true end,
            watchPoint = function() return vec(900.0, 0.0, 0.0) end,
        }
        C.env.BR.State.me.state = C.env.BR.PlayerState.SPECTATING

        local S = C.pass()

        ok(S.anchorFrom == 'spectate',
           'a running session moves the anchor onto the point being watched')
        ok(S.anchorOffPed > 800.0,
           'which is nowhere near the spectator own ped', S.anchorOffPed)
        ok(C.tasked[20] == 1,
           'THE REGRESSION: the driver on screen is re-tasked. Before the fix '
           .. 'this was nil -- nothing visible was ever in range')
        ok(C.tasked[10] == nil,
           'and the traffic around the corpse nobody is looking at is left alone')
        ok(S.treated == 1, 'still exactly one driver treated', S.treated)
    end

    -- A session with no eased point yet (the first frames, before the feed
    -- lands) must fall back rather than throw or anchor on nothing.
    do
        local C = newDriverClient(layout())
        C.env.BR.Spectate = {
            active = function() return true end,
            watchPoint = function() return nil end,
        }
        local S = C.pass()
        ok(S.anchorFrom == 'ped',
           'a session with no point yet falls back to the ped rather than throwing')
        ok(C.tasked[10] == 1, 'and still treats what is near the ped')
    end

    -- ═══ THE BUILD THAT ANSWERS 1 AND 0, WHICH NOTHING HERE USED TO COVER ═══
    --
    -- Every other case in this block stubs IsPedAPlayer to a real Lua `false`,
    -- which is this build's contract -- and that is precisely why neither the
    -- bare `not` nor the normaliser could be told apart by any assertion above.
    -- Both mutants survived. On a build that answers `0` for "not a player",
    -- `not 0` is FALSE and the pass treats NOBODY: it finds the cars, walks
    -- them, refuses every one, and every commuter stays calm forever, looking
    -- exactly like the feature being switched off.
    --
    -- This is the fifth time this repo has met that trap, so it gets a test
    -- rather than a comment.
    do
        local C = newDriverClient(layout())
        C.env.IsPedAPlayer = function(ped) return ped == 999 and 1 or 0 end
        local S = C.pass()
        ok(S.treated == 1,
           'a build answering 1/0 still treats the driver in range',
           S.treated)
        ok(C.tasked[10] == 1,
           'and the car beside the player is actually re-tasked on it',
           tostring(C.tasked[10]))
    end

    -- AND THE PLAYER IS STILL EXCLUDED ON THAT BUILD, which is the half a
    -- careless normaliser breaks: `yes(1)` must read as "this IS a player" and
    -- skip them, or the pass starts re-tasking human drivers.
    do
        local C = newDriverClient(layout())
        C.env.IsPedAPlayer = function() return 1 end
        local S = C.pass()
        ok(S.treated == 0,
           'and a driver the engine calls a player with 1 is left alone',
           S.treated)
    end

    -- The two gates, which /brdrivers exists to tell apart from "nothing in range".
    do
        local C = newDriverClient(layout())
        C.env.BR.Config.Ambient.erratic = false
        local S = C.pass()
        ok(not S.ran and S.why:find('erratic'),
           'erratic off is reported as erratic off, not as an empty pass')
        ok(C.tasked[10] == nil, 'and nothing is touched')
    end

    do
        local C = newDriverClient(layout())
        C.env.BR.State.me.state = C.env.BR.PlayerState.WARMUP
        local S = C.pass()
        ok(not S.ran and S.why:find('warmup'),
           'the warmup gate names the state that closed it')
        ok(C.tasked[10] == nil, 'the island stays a stage')
    end

    -- The readout has to survive being read before the first pass, because the
    -- first thing anybody will do is type /brdrivers.
    do
        local C = newDriverClient(layout())
        local S = C.env.BR.Gamerules.driverStats()
        ok(S ~= nil and not S.ran and S.why == 'not run yet',
           'the readout answers before the first pass instead of erroring')
    end
end

-- ---------------------------------------------------------------------------
-- The storm: WHOSE BODY the client reads it from.
--
-- "Storms are not synced between screens when spectating" -- the owner,
-- two-player playtest, 2026-08-23 (#225).
--
-- NOTHING HAD DESYNCED. The record goes to every src in the match with no state
-- filter, and BR.StormAt is pure over (record, synced clock), so both screens
-- solve the identical circle to the millisecond -- which is exactly why the
-- purple curtain and the two map rings, drawn at absolute world coordinates,
-- agreed on both. Everything else in client/storm.lua measured from
-- GetEntityCoords(PlayerPedId()): a corpse lying wherever the spectator died.
--
-- BOTH DIRECTIONS OF THE REPORT ARE PINNED BELOW, because answering only one of
-- them is how this comes back:
--
--   * watch somebody SAFE from a corpse out in the storm and the screen must
--     stop being red and raining;
--   * watch somebody CAUGHT from a corpse safe inside and the sky must go
--     thunderous -- which "no storm effects for a ghost" would NOT do, and
--     which is the second half the owner filed;
--   * and a LIVING viewer -- including an admin spectating while mid-fight in
--     their own match -- must still read their own body, or the fix trades one
--     silent death for another.
--
-- All three bands are covered separately: the 10Hz readout, the per-frame
-- distance push, and the column wall. A fix applied to one of them would be
-- overwritten by the next.
-- ---------------------------------------------------------------------------

describe('storm / viewpoint')
do
    local function pt(x, y, z) return { x = x, y = y, z = z or 30.0 } end

    local PED = 1

    --- One client with the real client/storm.lua on the real loop.
    local function newStormClient()
        local env = newSandbox()
        local C = {
            now = 100000,
            envelopes = {}, weather = {}, tc = {}, blips = {},
            markers = {}, prints = {},
            pedAt = pt(0.0, 0.0),
        }

        env.GetGameTimer = function() return C.now end
        env.print = function(...)
            local parts = {}
            for i = 1, select('#', ...) do parts[i] = tostring((select(i, ...))) end
            C.prints[#C.prints + 1] = table.concat(parts, ' ')
        end
        env.GetCurrentResourceName = function() return 'br_core' end
        env.GetHashKey       = function(s) return #tostring(s) end
        env.PlayerId         = function() return 0 end
        env.GetPlayerServerId = function() return 1 end
        env.AddEventHandler  = function() end
        env.RegisterNetEvent = function() end
        env.RegisterCommand  = function() end
        env.TriggerServerEvent = function() end
        env.Citizen = { CreateThread = function() end, Wait = function() end,
                        SetTimeout = function() end }

        loadInto(env, SANDBOX_LIB)

        -- THE CORPSE NEVER MOVES ITSELF. client/spectate.lua leaves the body
        -- where it fell on purpose, so this native answers the same point all
        -- session long -- which is the whole shape of the bug.
        env.PlayerPedId = function() return PED end
        env.GetEntityCoords = function()
            return pt(C.pedAt.x, C.pedAt.y, C.pedAt.z)
        end

        -- The HUD envelope is the only wire this file speaks on.
        env.TriggerEvent = function(name, key, payload)
            if name == 'br:ui:sendLocal' and key == env.BR.Nui.STORM then
                C.envelopes[#C.envelopes + 1] = payload
            end
        end

        -- The colour grade.
        env.SetTimecycleModifier         = function(n) C.tc.name = n end
        env.SetTimecycleModifierStrength = function(v) C.tc.strength = v end
        env.ClearTimecycleModifier       = function() C.tc.name = nil end
        env.AnimpostfxPlay = function() end
        env.AnimpostfxStop = function() end

        -- The sky. Only the overtime blend is a decision about who is being
        -- watched; the rest is the drying schedule.
        env.SetWeatherTypeOvertimePersist = function(w)
            C.weather[#C.weather + 1] = w
        end
        env.SetWeatherTypeNowPersist = function() end
        env.ClearWeatherTypePersist  = function() end
        env.SetRainLevel             = function() end

        env.DrawMarker = function(_, x, y, z)
            C.markers[#C.markers + 1] = { x = x, y = y, z = z }
        end
        env.GetGroundZFor_3dCoord = function() return false, 0.0 end

        -- Blips are tagged by the native that made them, so the arrow can be
        -- told from the two radius rings without matching display text.
        local handle = 100
        local function newBlip(kind, x, y)
            handle = handle + 1
            C.blips[handle] = { kind = kind, x = x, y = y, exists = true }
            return handle
        end
        env.AddBlipForCoord     = function(x, y) return newBlip('arrow', x, y) end
        env.RemoveBlip          = function(h)
            if C.blips[h] then C.blips[h].exists = false end
        end
        env.DoesBlipExist       = function(h)
            return C.blips[h] ~= nil and C.blips[h].exists
        end
        env.SetBlipSprite       = function() end
        env.SetBlipColour       = function() end
        env.SetBlipScale        = function() end
        env.SetBlipAsShortRange = function() end
        env.SetBlipCoords       = function(h, x, y)
            if C.blips[h] then C.blips[h].x, C.blips[h].y = x, y end
        end
        env.SetBlipRotation     = function(h, rot)
            if C.blips[h] then C.blips[h].rot = rot end
        end

        loadInto(env, { 'br_core/client/main.lua' })
        env.BR.Native = env.BR.Native or {}
        env.BR.Native.radiusBlip = function(h, x, y)
            if h and C.blips[h] and C.blips[h].exists then
                C.blips[h].x, C.blips[h].y = x, y
                return h
            end
            return newBlip('radius', x, y)
        end
        env.BR.Native.blipName = function(h, name)
            if C.blips[h] then C.blips[h].name = name end
        end

        loadInto(env, { 'br_core/client/storm.lua' })

        env.BR.State.match.state = env.BR.MatchState.PLAYING
        env.BR.State.me.state    = env.BR.PlayerState.ALIVE
        -- A PHASE-2 HOLD, deliberately: the free-loot rule that zeroes dps is
        -- `phase <= 1`, so a later phase's hold is the one shape where the
        -- storm is both stationary and genuinely hurting. Nothing in these
        -- cases then depends on how long the suite takes to run.
        env.BR.State.storm = {
            phase = 2,
            cx0 = 0.0, cy0 = 0.0, r0 = 200.0,
            cx1 = 0.0, cy1 = 0.0, r1 = 200.0,
            tStart = 0, tWait = 600000, tShrink = 60000,
            dps = 4.0,
        }

        C.env = env

        --- Run TICK passes 1.5s apart -- past the sky's holdMs hysteresis, so a
        --- settled decision has actually reached the weather.
        function C.tick(n)
            for _ = 1, (n or 1) do
                C.now = C.now + 1500
                env.BR.Loop.step(env.BR.Loop.TICK)
            end
        end

        function C.frame()
            C.now = C.now + 16
            env.BR.Loop.step(env.BR.Loop.FRAME)
        end

        --- Put a session on this client. `point` is what the eased camera is
        --- looking at; nil is the first frames, before the feed lands.
        function C.spectate(point)
            env.BR.Spectate = {
                active     = function() return true end,
                watchPoint = function() return point end,
            }
        end

        function C.last() return C.envelopes[#C.envelopes] end

        function C.arrow()
            for _, b in pairs(C.blips) do
                if b.exists and b.kind == 'arrow' then return b end
            end
            return nil
        end

        --- BR.Loop.step pcalls every callback and prints the failure, so a
        --- storm callback that threw would leave a green suite behind it.
        function C.errored()
            for _, line in ipairs(C.prints) do
                if line:find('errored', 1, true) then return line end
            end
            return nil
        end

        return C
    end

    local REDMIST = BR.Config.Storm.fx.timecycle

    -- A LIVING PLAYER IS UNCHANGED, and that is half the point of the fix.
    do
        local C = newStormClient()
        C.pedAt = pt(900.0, 0.0)
        C.tick(3)

        local e = C.last()
        ok(C.errored() == nil, 'the storm callbacks run clean', C.errored())
        ok(e ~= nil and near(e.edgeDistance, 700.0, 0.5),
           'a living player 900m out from a 200m circle reads 700m outside',
           e and e.edgeDistance)
        ok(C.arrow() ~= nil, 'and gets the way-home arrow')
        ok(C.weather[#C.weather] == 'THUNDER', 'and a thunderstorm',
           tostring(C.weather[#C.weather]))
        ok(C.tc.name == REDMIST, 'and the storm colour grade',
           tostring(C.tc.name))
    end

    -- THE REPORT, FIRST HALF: red and raining while the person on screen is
    -- standing in the sun.
    do
        local C = newStormClient()
        C.env.BR.State.me.state = C.env.BR.PlayerState.DEAD
        C.pedAt = pt(900.0, 0.0)          -- the corpse, out in the storm
        C.spectate(pt(0.0, 0.0))          -- the squadmate, dead centre
        C.tick(3)

        local e = C.last()
        ok(C.errored() == nil, 'the spectating pass runs clean', C.errored())
        ok(e ~= nil and near(e.edgeDistance, -200.0, 0.5),
           'the HUD counts metres from the WATCHED player -- 200m inside, '
           .. 'where they are actually standing -- not 700m out at the corpse',
           e and e.edgeDistance)
        ok(C.arrow() == nil,
           'and there is no way-home arrow, because the person on screen is '
           .. 'already home')
        ok(C.weather[#C.weather] ~= 'THUNDER',
           'the sky over the shot stays clear', tostring(C.weather[#C.weather]))
        ok(C.tc.name == nil,
           'and no REDMIST grade is laid over a player standing in the sun',
           tostring(C.tc.name))
    end

    -- THE REPORT, SECOND HALF: "watch a squadmate die in the storm and your sky
    -- stays clear". This is the case that rules out fixing it by switching a
    -- spectator's storm off -- the effects have to move, not vanish.
    do
        local C = newStormClient()
        C.env.BR.State.me.state = C.env.BR.PlayerState.DEAD
        C.pedAt = pt(0.0, 0.0)            -- the corpse, safe in the middle
        C.spectate(pt(900.0, 0.0))        -- the squadmate, out in it
        C.tick(3)

        local e = C.last()
        ok(e ~= nil and near(e.edgeDistance, 700.0, 0.5),
           'the readout is the watched player 700m outside, not the corpse '
           .. 'safe at the centre', e and e.edgeDistance)
        ok(C.arrow() ~= nil, 'the way-home arrow appears for them')
        ok(C.weather[#C.weather] == 'THUNDER',
           'the sky over the shot goes thunderous',
           tostring(C.weather[#C.weather]))
        ok(C.tc.name == REDMIST,
           'and the grade comes with it', tostring(C.tc.name))
    end

    -- ═══ THE EFFECTS GATE IS THE SESSION, NOT THE PLAYER STATE ═══
    --
    -- Today a spectator falls through storm.state's `affected` test as DEAD,
    -- because BR.PlayerState.SPECTATING is read in six places and assigned in
    -- none (client/state.lua:503 says so, and grep agrees). #233 is the rework
    -- that finally assigns it -- and on the day it lands, a gate spelled
    -- "ALIVE or DBNO or DEAD" would silently switch the spectator's sky and
    -- grade back off, re-filing half of #225 with nothing to point at.
    --
    -- So the case is pinned NOW, against the state #233 will produce. It is
    -- the assertion that makes gating on the session load-bearing rather than
    -- merely better-worded.
    do
        local C = newStormClient()
        C.env.BR.State.me.state = C.env.BR.PlayerState.SPECTATING
        C.pedAt = pt(0.0, 0.0)
        C.spectate(pt(900.0, 0.0))
        C.tick(3)

        local e = C.last()
        ok(e ~= nil and near(e.edgeDistance, 700.0, 0.5),
           'a viewer already carrying #233 state reads the watched player',
           e and e.edgeDistance)
        ok(C.weather[#C.weather] == 'THUNDER',
           'and keeps the sky over the shot -- the session decides this, not '
           .. 'a list of player states that SPECTATING is not on',
           tostring(C.weather[#C.weather]))
        ok(C.tc.name == REDMIST, 'and the grade with it', tostring(C.tc.name))
    end

    -- BOTH BODIES OUTSIDE, IN DIFFERENT DIRECTIONS. Everything above could in
    -- principle pass on a client that merely switched the storm off while
    -- spectating; this cannot. The arrow parks at the nearest safe point just
    -- inside the target edge, so its coordinates name the body the bearing was
    -- taken from.
    do
        local C = newStormClient()
        C.env.BR.State.me.state = C.env.BR.PlayerState.DEAD
        C.pedAt = pt(900.0, 0.0)          -- corpse: due EAST of the circle
        C.spectate(pt(0.0, 900.0))        -- watched: due NORTH of it
        C.tick(3)

        local a = C.arrow()
        ok(a ~= nil, 'both bodies are outside, so there is an arrow either way')
        ok(a ~= nil and near(a.x, 0.0, 0.5) and near(a.y, 175.0, 0.5),
           'and it points home from the WATCHED player north of the circle, '
           .. 'not from the corpse east of it',
           a and (tostring(a.x) .. ', ' .. tostring(a.y)))
    end

    -- AN ADMIN SPECTATOR IS STILL IN THEIR OWN MATCH. server/spectate.lua's
    -- adminStart asks only that they be in game, so their body may be alive,
    -- armed and outside the wall taking the server's damage for it. Moving
    -- their readout onto the shot would be this same bug pointed the other
    -- way: a HUD saying safe while the ledger bleeds them out.
    do
        local C = newStormClient()
        C.pedAt = pt(900.0, 0.0)          -- their own body, out in the storm
        C.spectate(pt(0.0, 0.0))          -- watching a suspect, safe inside
        C.tick(3)

        local e = C.last()
        ok(e ~= nil and near(e.edgeDistance, 700.0, 0.5),
           'a LIVING viewer keeps their own distance while spectating',
           e and e.edgeDistance)
        ok(C.weather[#C.weather] == 'THUNDER',
           'and their own weather, because their own body really is in it',
           tostring(C.weather[#C.weather]))
    end

    -- The first frames of a session, before the 4Hz feed has landed a point.
    do
        local C = newStormClient()
        C.env.BR.State.me.state = C.env.BR.PlayerState.DEAD
        C.pedAt = pt(900.0, 0.0)
        C.spectate(nil)
        C.tick(3)

        local e = C.last()
        ok(C.errored() == nil,
           'a session with no eased point yet does not throw', C.errored())
        ok(e ~= nil and near(e.edgeDistance, 700.0, 0.5),
           'it falls back to the ped rather than measuring from nothing',
           e and e.edgeDistance)
    end

    -- ═══ THE FRAME BAND IS A SECOND READ, PINNED SEPARATELY ═══
    --
    -- storm.edge re-reads the position every frame -- that is the entire reason
    -- it exists, the 10Hz number having "read as laggy" at a sprint -- so a fix
    -- applied only to the 10Hz band would be overwritten by the next frame.
    do
        local C = newStormClient()
        C.env.BR.State.me.state = C.env.BR.PlayerState.DEAD
        C.pedAt = pt(0.0, 0.0)
        local watched = pt(900.0, 0.0)
        C.spectate(watched)
        C.tick(1)
        ok(near(C.last().edgeDistance, 700.0, 0.5),
           'the tick band sets the baseline at the watched player',
           C.last().edgeDistance)

        -- A corpse cannot walk, but prove the frame band ignores it anyway.
        C.pedAt = pt(1200.0, 0.0)
        local before = #C.envelopes
        C.frame()
        ok(#C.envelopes == before,
           'a frame that moves only the corpse pushes nothing at all',
           #C.envelopes - before)

        watched.x = 910.0
        C.frame()
        local e = C.last()
        ok(#C.envelopes > before and near(e.edgeDistance, 710.0, 0.5),
           'the watched player moving 10m moves the readout 10m, per frame',
           e and e.edgeDistance)
    end

    -- ═══ AND THE COLUMN WALL, THE THIRD READ ═══
    --
    -- 'solid' ships and draws one cylinder at the circle's own coordinates,
    -- which is precisely why the curtain agreed across both screens. The
    -- column renderer behind /brwallstyle centres its arc on the viewer's
    -- bearing and probes the ground beneath them, so it is the one part of the
    -- wall that could disagree.
    do
        local C = newStormClient()
        C.env.BR.State.me.state = C.env.BR.PlayerState.DEAD
        C.env.BR.Storm.wallStyle = 'columns'
        -- Wide enough that the arc is a slice of the ring rather than all of
        -- it: at r=200 every slot is drawn and centring cannot be observed.
        C.env.BR.State.storm.r0 = 2000.0
        C.env.BR.State.storm.r1 = 2000.0
        C.pedAt = pt(2100.0, 0.0)         -- corpse just outside, due EAST
        C.spectate(pt(0.0, 2100.0))       -- watched just outside, due NORTH
        C.frame()

        local north, east = 0, 0
        for _, m in ipairs(C.markers) do
            if m.y > 1000.0 then north = north + 1 end
            if m.x > 1000.0 then east  = east + 1 end
        end
        ok(C.errored() == nil, 'the column renderer runs clean', C.errored())
        ok(#C.markers > 0, 'the column renderer drew something', #C.markers)
        ok(north == #C.markers and east == 0,
           'every column stands on the arc the CAMERA is looking at, not the '
           .. 'arc above the corpse',
           ('north %d / east %d of %d'):format(north, east, #C.markers))
    end
end

-- ═══════════════════════════════════════════════════════════════════════════
describe('audio.catalogue')
-- ═══════════════════════════════════════════════════════════════════════════
--
--   "Can you make me something which plays GTA sounds with a console command
--    so I can pick which one sounds good?"      -- owner, 2026-08-22
--
-- ═══ WHAT A TEST CAN REACH HERE, AND WHAT IT CANNOT ═══
--
-- IT CANNOT PROVE A SOUND PLAYS, and no test ever will: a wrong sound SET is
-- silent rather than erroneous, which is the whole reason /brsfx exists and the
-- whole reason two fuel-cue picks have now been rejected. Only a client with a
-- person attached settles that.
--
-- WHAT IT DOES REACH is the half that decides what the person is ever shown. If
-- the search hands back the wrong rows, the owner auditions the wrong sounds
-- and the tool has failed at the only job it has -- and unlike the audio, that
-- is arithmetic. So the filters are tested hard here and the sounds are not
-- tested at all.
do
    local A = BR.Config.Audio

    ok(type(A.catalogue) == 'table' and #A.catalogue > 0,
       'the catalogue exists and is a non-empty ARRAY',
       tostring(type(A.catalogue)) .. ' / ' .. tostring(#(A.catalogue or {})))

    -- ------------------------------------------------------------ shape ---
    local badShape, totalPairs, dupName = nil, 0, nil
    local seenSet = {}
    for _, entry in ipairs(A.catalogue) do
        if type(entry.set) ~= 'string' or entry.set == '' then
            badShape = 'a set with no name'
        elseif type(entry.names) ~= 'table' or #entry.names == 0 then
            badShape = entry.set .. ' has no names'
        end
        if seenSet[entry.set] then badShape = entry.set .. ' appears twice' end
        seenSet[entry.set] = true

        local seenName = {}
        for _, n in ipairs(entry.names or {}) do
            if type(n) ~= 'string' or n == '' then
                badShape = entry.set .. ' has an empty name'
            end
            if seenName[n] then dupName = entry.set .. ' lists ' .. n .. ' twice' end
            seenName[n] = true
            totalPairs = totalPairs + 1
        end
    end
    ok(badShape == nil, 'every row is a set name and a non-empty list of names', badShape)
    ok(dupName == nil, 'and no set lists the same sound twice', dupName)

    -- ═══ NO DLC BANKS, AND THIS IS THE ASSERTION WITH TEETH ═══
    --
    -- Pit_Stop_Complete was the on-theme candidate for fuel.done and was
    -- rejected because it lives in DLC_H3_Circuit_Racing_Sounds -- a script
    -- audio bank this gamemode never requests, so it would have played nothing
    -- while looking perfectly correct in the config. Every DLC_*/dlc_* set was
    -- filtered out of this catalogue for that reason. A catalogue that let one
    -- back in would be a browsing tool that offers the owner sounds which
    -- cannot play, which is worse than no tool: it manufactures exactly the
    -- ambiguity the [silent?] marker exists to resolve.
    local dlc = nil
    for _, entry in ipairs(A.catalogue) do
        if string.lower(entry.set):sub(1, 4) == 'dlc_' then dlc = entry.set end
    end
    ok(dlc == nil,
       'no DLC audio bank is offered for browsing -- those are silent unless '
           .. 'something requests them, and nothing here does', dlc)

    -- ═══ THE ORDER IS FIXED IN THE SOURCE, NOT LEFT TO pairs() ═══
    --
    -- This list is something a person reads down, hears, and comes back to. Lua
    -- does not specify `pairs()` order and it genuinely varies between runs, so
    -- an unordered catalogue would reshuffle under the owner between two
    -- invocations of the same command. The three sets at the top are the three
    -- this codebase has HEARD -- a silence in one of those is a wrong NAME
    -- rather than an absent bank, which is a different and much cheaper bug.
    ok(A.catalogue[1].set == 'HUD_FRONTEND_DEFAULT_SOUNDSET'
       and A.catalogue[2].set == 'HUD_AWARDS'
       and A.catalogue[3].set == 'HUD_MINI_GAME_SOUNDSET',
       'the three sets this codebase has actually heard sort first, in order',
       A.catalogue[1].set .. ', ' .. A.catalogue[2].set .. ', ' .. A.catalogue[3].set)

    local outOfOrder = nil
    for i = 5, #A.catalogue do
        local prev, cur = A.catalogue[i - 1].set:lower(), A.catalogue[i].set:lower()
        if prev > cur then outOfOrder = prev .. ' before ' .. cur end
    end
    ok(outOfOrder == nil,
       'and everything after them is alphabetical, so the same command twice '
           .. 'prints the same list twice', outOfOrder)

    -- ---------------------------------------------------------- sets() ---
    ok(#A.sets() == #A.catalogue, 'sets() with no query is every set',
       ('%d vs %d'):format(#A.sets(), #A.catalogue))
    ok(#A.sets('') == #A.catalogue, 'and an empty query is the same as none')

    local hud = A.sets('HUD')
    ok(#hud > 0 and #hud < #A.catalogue, 'sets("HUD") narrows without emptying',
       ('%d of %d'):format(#hud, #A.catalogue))
    local notHud = nil
    for _, s in ipairs(hud) do
        if not s.set:find('HUD', 1, true) then notHud = s.set end
    end
    ok(notHud == nil, 'and every row it returns really contains the query', notHud)

    -- CASE-INSENSITIVE, and asserted by EQUALITY of the two result sets rather
    -- than by "lowercase finds something". A query typed the way the owner
    -- reads it off the screen -- SHOUTING, because GTA's set names are -- must
    -- find the same rows as one typed in a hurry.
    ok(#A.sets('hud') == #A.sets('HUD') and #A.sets('hUd') == #A.sets('HUD'),
       'sets() is case-insensitive in both directions',
       ('%d / %d / %d'):format(#A.sets('hud'), #A.sets('HUD'), #A.sets('hUd')))

    local awards = A.sets('HUD_AWARDS')
    ok(#awards == 1 and awards[1].n == #A.namesIn('HUD_AWARDS'),
       'and the count it reports is the real number of names in that set',
       #awards == 1 and tostring(awards[1].n) or ('%d rows'):format(#awards))

    ok(#A.sets('no such set anywhere') == 0, 'a query that matches nothing is empty')

    -- ---------------------------------------------------------- find() ---
    ok(#A.find() == totalPairs, 'find() with no query is every pair',
       ('%d vs %d'):format(#A.find(), totalPairs))

    local sel = A.find('SELECT')
    ok(#sel > 0, 'find() by name returns something')
    local wrongName = nil
    for _, r in ipairs(sel) do
        if not r.name:upper():find('SELECT', 1, true) then wrongName = r.name end
    end
    ok(wrongName == nil, 'and every row really matches the name query', wrongName)
    ok(#A.find('select') == #A.find('SELECT'), 'find() is case-insensitive too',
       ('%d vs %d'):format(#A.find('select'), #A.find('SELECT')))

    -- ═══ THE TWO FILTERS ARE ANDed, NOT ORed ═══
    --
    -- "narrow it by set, by substring, or both" was the ask, and BOTH is the
    -- case that matters: `find complete HUD` is how somebody looks for a
    -- confirmation chime inside the sets this codebase has heard, which is the
    -- search that would have settled fuel.done two rounds ago. An OR here would
    -- return every HUD sound plus every "complete" sound -- a longer list that
    -- looks like it is working.
    local both = A.find('SELECT', 'HUD_AWARDS')
    ok(#both == 0,
       'find("SELECT", "HUD_AWARDS") is empty -- HUD_AWARDS has no SELECT, and '
           .. 'an ORed implementation would have returned dozens of rows',
       ('%d'):format(#both))

    local go = A.find('GO', 'MINI')
    ok(#go > 0 and #go < #A.find('GO'),
       'and a set filter really cuts a name search down',
       ('%d of %d'):format(#go, #A.find('GO')))
    local outsideSet = nil
    for _, r in ipairs(go) do
        if not r.set:upper():find('MINI', 1, true) then outsideSet = r.set end
    end
    ok(outsideSet == nil, 'with nothing from outside the named set', outsideSet)

    ok(#A.find(nil, 'HUD_AWARDS') == #A.namesIn('HUD_AWARDS'),
       'find(nil, set) is the whole of one set',
       ('%d vs %d'):format(#A.find(nil, 'HUD_AWARDS'), #A.namesIn('HUD_AWARDS')))

    -- ═══ THE QUERY IS TEXT, NOT A LUA PATTERN ═══
    --
    -- Every sound name in this catalogue contains an underscore and the owner
    -- will be typing them, so the search runs through string.find's PLAIN mode.
    -- Without it `%` and `(` throw ("malformed pattern") and `.` matches
    -- everything -- a search box that errors on a punctuation character, in a
    -- tool whose entire job is to be typed into quickly.
    local okPct, resPct = pcall(A.find, '%')
    ok(okPct, 'a query containing % does not throw', not okPct and tostring(resPct) or nil)
    ok(okPct and #resPct == 0, 'and finds nothing, because no name contains one')

    local okParen = pcall(A.find, '(')
    ok(okParen, 'nor does one containing an unclosed bracket')

    -- `.` IS THE ONE THAT WOULD PASS QUIETLY. A pattern-mode `.` matches any
    -- character, so it would return all the rows and look like a working
    -- wildcard rather than a bug -- until somebody searched for `10_SEC` and
    -- got a list that ignored the underscore.
    ok(#A.find('.') == 0,
       'and a lone dot matches nothing rather than everything -- it is a '
           .. 'character to look for, not a wildcard', ('%d'):format(#A.find('.')))
    ok(#A.find('_') > 0, 'while a real underscore matches the many names with one')

    -- -------------------------------------------------------- namesIn() ---
    --
    -- EXACT, and deliberately not a substring match. This is what the
    -- sequential audition walks, and a substring that matched two sets would
    -- play through both -- leaving the owner with a sound they liked and no way
    -- to know which set to write down, which is the one fact they need.
    ok(A.namesIn('HUD_AWARDS') ~= nil, 'namesIn() finds a set by its exact name')
    ok(A.namesIn('HUD_AWARD') == nil,
       'and a near-miss returns nil rather than the set it nearly named')
    ok(A.namesIn('hud_awards') == nil,
       'and it is case-SENSITIVE, unlike the searches -- this one is an '
           .. 'identifier being resolved, not a query being matched')
    ok(A.namesIn('') == nil, 'an empty name resolves to no set')

    -- ------------------------------------------------------ resolveSet() ---
    --
    --   "It seems I have no way to list all sfx within a given set."
    --                                             -- owner, 2026-08-23
    --
    -- What `brsfx sounds <SET>` resolves its argument with, and the reason it
    -- can be forgiving where namesIn() must not be: this hands back the
    -- CATALOGUE'S OWN SPELLING and the command prints it, so a loose match is
    -- announced rather than acted on quietly. namesIn() has no such channel --
    -- it returns names, and an audition that quietly walked the wrong set would
    -- leave somebody with a sound they liked and no idea what to write down.
    local r, near = A.resolveSet('HUD_AWARDS')
    ok(r == 'HUD_AWARDS', 'resolveSet() takes an exact set name', tostring(r))
    ok(#near == 1, 'and offers exactly itself as the candidate list',
       ('%d'):format(#near))

    -- CASE-BLIND, WHICH IS THE HALF namesIn() REFUSES. GTA's set names SHOUT
    -- and HUD_FRONTEND_WEAPONS_PICKUPS_SOUNDSET is 37 characters; requiring
    -- them in caps is requiring a copy-paste from a list the owner is reading
    -- off a console.
    ok(A.resolveSet('hud_awards') == 'HUD_AWARDS',
       'and the same name in lower case, unlike namesIn()',
       tostring(A.resolveSet('hud_awards')))
    ok(A.resolveSet('Hud_AwArDs') == 'HUD_AWARDS', 'in any mixture of cases')

    -- ═══ A SUBSTRING RESOLVES ONLY WHEN IT IS UNAMBIGUOUS ═══
    --
    -- This is the whole design of the thing. `awards` means one set, so it is
    -- an answer. `HUD` means thirteen, and picking the first would be this tool
    -- GUESSING -- about the exact question it exists to stop people guessing
    -- about, in a command whose failure mode is silence.
    ok(A.resolveSet('awards') == 'HUD_AWARDS',
       'a substring matching ONE set resolves to that set, spelled the '
           .. 'catalogue\'s way so it can be pasted into `brsfx play`',
       tostring(A.resolveSet('awards')))

    local amb, hudNear = A.resolveSet('HUD')
    ok(amb == nil, 'a substring matching several sets resolves to nothing',
       tostring(amb))
    ok(#hudNear > 1, 'and hands back every set it could have meant instead, '
           .. 'because "no such set" and "which of these thirteen" are '
           .. 'different answers and only one of them is useful',
       ('%d'):format(#hudNear))
    local strayNear = nil
    for _, s in ipairs(hudNear) do
        if not s:upper():find('HUD', 1, true) then strayNear = s end
    end
    ok(strayNear == nil, 'with nothing in it that does not contain the query',
       strayNear)

    -- ═══ EXACT BEATS CASE-BLIND BEATS SUBSTRING, AND THE FIXTURE FOR THAT HAS
    --     TO BE INJECTED ═══
    --
    -- NO SET NAME IN TODAY'S CATALOGUE IS A SUBSTRING OF ANOTHER -- checked,
    -- not assumed -- so every real query that matches exactly also matches
    -- exactly one substring, and the three passes agree on every one of the 84.
    -- That makes the ORDER of the passes untested by the real data: an
    -- implementation that ran the substring pass first would be green on all 84
    -- sets and wrong the day somebody adds `HUD_AWARDS_EXTRA`, at which point
    -- typing the perfectly correct `HUD_AWARDS` would come back "could mean 2
    -- sets". So the collision is built here and torn down after.
    table.insert(A.catalogue, { set = 'ZZ_ORDER_TEST', names = { 'A' } })
    table.insert(A.catalogue, { set = 'ZZ_ORDER_TEST_LONGER', names = { 'B' } })

    ok(A.resolveSet('ZZ_ORDER_TEST') == 'ZZ_ORDER_TEST',
       'a name typed EXACTLY resolves to itself even when it is also a '
           .. 'substring of another set -- or a perfectly correct name starts '
           .. 'being answered with "did you mean"',
       tostring(A.resolveSet('ZZ_ORDER_TEST')))
    -- THIS IS THE ASSERTION THAT PINS THE ORDER, and the one above is not.
    -- A mutant that deletes the exact pass survives, because equality implies
    -- case-blind equality -- see the comment on resolveSet, which says so. A
    -- mutant that deletes the CASE-BLIND pass dies here: `zz_order_test`
    -- matches two sets as a substring, so without it a name typed correctly
    -- but in lower case comes back ambiguous.
    ok(A.resolveSet('zz_order_test') == 'ZZ_ORDER_TEST',
       'and a name typed correctly in the wrong CASE beats the substring pass '
           .. 'too, rather than coming back as a "did you mean" over the two '
           .. 'sets it is a substring of',
       tostring(A.resolveSet('zz_order_test')))
    local twoWay, twoNear = A.resolveSet('ZZ_ORDER')
    ok(twoWay == nil and #twoNear == 2,
       'while a substring of BOTH of them is still ambiguous, so the pass '
           .. 'order is a precedence and not a short-circuit that ate the '
           .. 'ambiguity check', ('%s / %d'):format(tostring(twoWay), #twoNear))

    table.remove(A.catalogue)
    table.remove(A.catalogue)
    ok(A.resolveSet('ZZ_ORDER_TEST') == nil,
       'and the injected sets are gone again, so nothing below sees them')

    local no, noNear = A.resolveSet('nothing_is_called_this')
    ok(no == nil and #noNear == 0,
       'a query matching nothing resolves to nothing, with an EMPTY candidate '
           .. 'list -- which is what lets the command tell the two cases apart')

    -- ═══ THE EMPTY STRING IS THE ONE THAT WOULD PASS QUIETLY ═══
    --
    -- contains() treats '' as "matches everything" -- deliberately, so that
    -- `sets()` and `sets('')` agree -- so a resolveSet that just forwarded to
    -- sets() would answer all 84 for an empty argument, and `#near == 1` being
    -- false would make that read as "ambiguous" rather than "you typed
    -- nothing". Harmless-looking, and it is how `brsfx sounds ''` would come
    -- back with a wall of set names instead of the usage line.
    local blank, blankNear = A.resolveSet('')
    ok(blank == nil and #blankNear == 0,
       'an empty query resolves to nothing and offers NO candidates, rather '
           .. 'than inheriting contains()\'s "empty matches everything"',
       ('%s / %d'):format(tostring(blank), #blankNear))

    local nilR, nilNear = A.resolveSet(nil)
    ok(nilR == nil and #nilNear == 0, 'and so does a missing argument')
    local okNum, numR = pcall(A.resolveSet, 42)
    ok(okNum and numR == nil, 'and a non-string answers rather than throwing, '
           .. 'because this is reached straight off a console command line',
       not okNum and tostring(numR) or nil)

    -- PLAIN TEXT, NOT A LUA PATTERN, for the same reason find() is: every set
    -- name in here has underscores in it and the owner is typing them.
    local okPat, patR = pcall(A.resolveSet, 'HUD_%')
    ok(okPat and patR == nil, 'a query containing % does not throw',
       not okPat and tostring(patR) or nil)

    -- AND EVERY SET IN THE CATALOGUE RESOLVES TO ITSELF. The listing verb is
    -- reached from `brsfx sets`, so anything that command can print must be
    -- something this one accepts -- otherwise step 1 of the three-step flow
    -- offers a name step 2 rejects.
    local unresolvable = nil
    for _, entry in ipairs(A.catalogue) do
        if A.resolveSet(entry.set) ~= entry.set then unresolvable = entry.set end
    end
    ok(unresolvable == nil,
       'every set `brsfx sets` prints is one `brsfx sounds` accepts, so step 1 '
           .. 'of the browse flow cannot offer a name step 2 refuses',
       unresolvable)

    -- --------------------------------------------------- the cues agree ---
    --
    -- The catalogue is what the tool offers; the cue table is what the game
    -- plays. They are two tables in one file and nothing but this makes them
    -- agree.
    -- ═══ EVERY CUE IS A PAIR, AND THE WHOLE PAIR IS IN THE CATALOGUE ═══
    --
    -- Set-level would be the softer rule and it is not enough: the two failures
    -- this project has actually had were WIN and LOSER, which are perfectly good
    -- names in a set that does not contain them. A pair-level check is the only
    -- one that would have caught that, and every cue in the table today passes
    -- it -- these are all calls GTA's own scripts make.
    --
    -- IF THE OWNER'S THIRD FUEL PICK IS NOT IN THE CATALOGUE, THIS FAILS, AND
    -- THAT IS THE INTENDED WORKFLOW RATHER THAN AN OBSTACLE. Everything /brsfx
    -- can browse is in here, so a sound chosen with the tool passes on the way
    -- in. A pair from anywhere else is one nobody has evidence for, and the fix
    -- is one line: add it to the catalogue, having HEARD it. The failure message
    -- says so rather than leaving somebody to guess.
    local strayCue = nil
    local byPair = {}
    for _, entry in ipairs(A.catalogue) do
        for _, n in ipairs(entry.names) do byPair[entry.set .. '/' .. n] = true end
    end
    for cue, def in pairs(A.cues) do
        if not byPair[tostring(def.set) .. '/' .. tostring(def.name)] then
            strayCue = ('%s plays %s / %s, which the catalogue does not list -- '
                .. 'if you have HEARD it, add it there'):format(cue, def.set, def.name)
        end
    end
    ok(strayCue == nil,
       'every configured cue is a pair GTA\'s own scripts play, so it can be '
           .. 're-chosen with the same tool that found it', strayCue)
    ok(seenSet['HUD_AWARDS'] == true,
       'and the catalogue really is what that was checked against',
       tostring(seenSet['HUD_AWARDS']))

    -- AND storm.move IS ONE OF THEM. The cue the wall's first movement plays;
    -- server/storm.lua sends this exact key and never looks it up.
    local move = A.cues['storm.move']
    ok(type(move) == 'table' and type(move.set) == 'string'
       and type(move.name) == 'string',
       'the storm-movement cue exists and names both halves of a sound',
       move and (tostring(move.set) .. '/' .. tostring(move.name)) or 'nil')
    local moveListed = false
    for _, n in ipairs(A.namesIn(move.set) or {}) do
        if n == move.name then moveListed = true end
    end
    ok(moveListed,
       'and the exact pair it names is one the catalogue lists -- so it is a '
           .. 'call GTA\'s own scripts make, not a name off a wiki',
       move.set .. ' / ' .. move.name)
end

describe('health.audit')
do
    -- THE EXPLOIT THIS MEASURES, in one sentence: server/roster.lua samples the
    -- ped's health four times a second and writes it into the same `entry.hp`
    -- the damage arithmetic subtracts from, and the ped's health belongs to the
    -- owning client -- so a modified client restores its own ledger 250ms after
    -- every hit. These assertions are about the DETECTOR, which counts that and
    -- changes nothing; the fix is a separate, playtested change.
    local A = BR.Config.Combat.healthAudit
    local ALIVE = { now = 10000, state = BR.PlayerState.ALIVE }

    local function ctx(over)
        local c = {}
        for k, v in pairs(ALIVE) do c[k] = v end
        for k, v in pairs(over or {}) do c[k] = v end
        return c
    end

    -- ═══ THE SIGNAL ═══
    local gain, excuse = BR.HealthUnexplainedGain(30.0, 100.0, ctx(), A)
    ok(gain == 70.0 and excuse == BR.HealthExcuse.COUNTED,
        'a ped that reads a full bar over the ledger, with nothing to explain '
            .. 'it, is counted in full',
        ('%s / %s'):format(tostring(gain), tostring(excuse)))

    -- ═══ AND EVERY HONEST WAY TO READ HIGH, ONE AT A TIME ═══
    --
    -- Each of these is a REAL path in the running game, and if any of them ever
    -- starts counting, the detector is broken and an honest player is about to
    -- be accused. They are asserted separately rather than as one "no false
    -- positives" case so that a failure names which window closed.

    -- The world hurting somebody. The engine still owns falls, fire, drowning
    -- and cars -- the server models none of them -- so the ledger FOLLOWS the
    -- ped down. Wrong direction; never counted.
    gain, excuse = BR.HealthUnexplainedGain(100.0, 30.0, ctx(), A)
    ok(gain == 0.0 and excuse == BR.HealthExcuse.NONE,
        'a fall, a fire or a car reads BELOW the ledger and is never the signal',
        ('%s / %s'):format(tostring(gain), tostring(excuse)))

    -- The single largest source of honest divergence: the server subtracted
    -- from the ledger and the client has not applied HIT_DAMAGE yet.
    gain, excuse = BR.HealthUnexplainedGain(30.0, 100.0,
        ctx({ lastHitAt = 10000 - (A.hurtGraceMs - 100) }), A)
    ok(gain == 0.0 and excuse == BR.HealthExcuse.HURT,
        'damage still in flight to the client is excused, which is the window a '
            .. 'bad ping lives in',
        ('%s / %s'):format(tostring(gain), tostring(excuse)))

    -- ...AND THE GRACE ENDS. A window that never closed would excuse the whole
    -- match for anybody who had been shot once.
    gain, excuse = BR.HealthUnexplainedGain(30.0, 100.0,
        ctx({ lastHitAt = 10000 - (A.hurtGraceMs + 100) }), A)
    ok(gain == 70.0 and excuse == BR.HealthExcuse.COUNTED,
        'and once the round trip is over the same reading counts',
        ('%s / %s'):format(tostring(gain), tostring(excuse)))

    -- A med kit or shield. The server ISSUES the target and the client walks
    -- its ped up to it, so the sampler reads the rise on the way past. This is
    -- the one legitimate upward path the ledger does not already own, and it is
    -- the reason a naive "refuse every rise" fix would break healing.
    gain, excuse = BR.HealthUnexplainedGain(30.0, 100.0,
        ctx({ healUntil = 10000 + 500 }), A)
    ok(gain == 0.0 and excuse == BR.HealthExcuse.HEALING,
        'a med kit the SERVER issued is not a client inventing health',
        ('%s / %s'):format(tostring(gain), tostring(excuse)))

    -- A revive or a respawn: here the LEDGER leads and the ped follows, so the
    -- usual direction is reversed and the crossover can spike the other way.
    gain, excuse = BR.HealthUnexplainedGain(30.0, 100.0,
        ctx({ settleUntil = 10000 + 500 }), A)
    ok(gain == 0.0 and excuse == BR.HealthExcuse.SETTLING,
        'a revive the server wrote is excused while the ped catches up',
        ('%s / %s'):format(tostring(gain), tostring(excuse)))

    -- #191, AND IT LANDED THE SAME WEEK AS THIS DETECTOR. A downed player rides
    -- an ambulance to a drop-off and BR.Combat.revive hands their health back on
    -- arrival. A detector that cried wolf on the feature shipping beside it
    -- would have been switched off in its first playtest.
    gain, excuse = BR.HealthUnexplainedGain(30.0, 100.0,
        ctx({ rescue = { id = 1 } }), A)
    ok(gain == 0.0 and excuse == BR.HealthExcuse.RESCUE,
        'a player being rescued (#191) is never the signal',
        ('%s / %s'):format(tostring(gain), tostring(excuse)))

    -- Only a player who can be SHOT is worth defending. A dead player's ped gets
    -- resurrected for the spectator camera; a lobby ped is whatever the lobby
    -- left it on. Both would read high forever and neither means anything.
    for _, st in ipairs({ BR.PlayerState.DEAD, BR.PlayerState.LOBBY,
                          BR.PlayerState.BUS, BR.PlayerState.DBNO }) do
        gain, excuse = BR.HealthUnexplainedGain(30.0, 100.0,
            ctx({ state = st }), A)
        ok(gain == 0.0 and excuse == BR.HealthExcuse.NOT_LIVE,
            ('a %s player is not audited'):format(tostring(st)),
            ('%s / %s'):format(tostring(gain), tostring(excuse)))
    end

    -- Rounding. Two float pipelines, both floored.
    gain, excuse = BR.HealthUnexplainedGain(30.0, 30.0 + A.toleranceHp, ctx(), A)
    ok(gain == 0.0 and excuse == BR.HealthExcuse.TOLERANCE,
        'a point of float disagreement is arithmetic, not evidence',
        ('%s / %s'):format(tostring(gain), tostring(excuse)))

    -- ═══ AND THE ARITHMETIC CANNOT BE DISABLED BY A BAD NUMBER ═══
    --
    -- `nan > x` is false for every x, so a NaN sliding through would read as "no
    -- gain" and silently switch the detector off for that player -- which is the
    -- one failure mode an anticheat must not have.
    local nan = 0.0 / 0.0
    gain, excuse = BR.HealthUnexplainedGain(nan, 100.0, ctx(), A)
    ok(gain == 0.0, 'a NaN ledger does not throw', tostring(gain))
    gain, excuse = BR.HealthUnexplainedGain(30.0, nan, ctx(), A)
    ok(gain == 0.0, 'nor a NaN sample', tostring(gain))
    gain = BR.HealthUnexplainedGain(nil, 100.0, ctx(), A)
    ok(gain == 0.0, 'and a player with no ledger yet has no opinion to contradict',
        tostring(gain))

    -- ═══ THE TALLY ═══
    --
    -- CUMULATIVE, because that is what makes this a good signal: the excuses
    -- above absorb every legitimate rise, so honest play sits at zero, while the
    -- exploit has to repeat the lie four times a second to keep working.
    local t = nil
    t = BR.HealthTally(t, 70.0, BR.HealthExcuse.COUNTED)
    t = BR.HealthTally(t, 40.0, BR.HealthExcuse.COUNTED)
    ok(t.hp == 110.0 and t.samples == 2 and t.peak == 70.0,
        'the tally accumulates, counts samples and remembers the worst one',
        ('%s / %s / %s'):format(tostring(t.hp), tostring(t.samples),
            tostring(t.peak)))

    -- The excuse breakdown is the false-positive audit -- it is what `/brhealth`
    -- prints beside the totals so an operator can see WHAT was thrown away.
    t = BR.HealthTally(t, 0.0, BR.HealthExcuse.HURT)
    t = BR.HealthTally(t, 0.0, BR.HealthExcuse.HURT)
    t = BR.HealthTally(t, 0.0, BR.HealthExcuse.HEALING)
    ok(t.excused[BR.HealthExcuse.HURT] == 2
       and t.excused[BR.HealthExcuse.HEALING] == 1,
        'and it records which excuse absorbed each sample',
        ('%s / %s'):format(tostring(t.excused[BR.HealthExcuse.HURT]),
            tostring(t.excused[BR.HealthExcuse.HEALING])))

    -- ...BUT NOT `NONE`, which is every ordinary sample of every honest player.
    -- 48 players at 4Hz is two hundred a second, and a counter that ticked on all
    -- of them would be a number nobody could read anything out of.
    local before = t.excused[BR.HealthExcuse.NONE]
    t = BR.HealthTally(t, 0.0, BR.HealthExcuse.NONE)
    ok(before == nil and t.excused[BR.HealthExcuse.NONE] == nil,
        'the ordinary case is not tallied at all', tostring(before))

    -- Totals unchanged by the excused samples: an excuse must not be able to
    -- move the number the bar is measured against.
    ok(t.hp == 110.0, 'an excused sample never adds to the total',
        tostring(t.hp))

    -- ═══ THE BAR, AND WHY IT FIRES ONCE ═══
    ok(BR.HealthShouldReport({ hp = A.reportHp }, A),
        'a whole bar of unissued health earns an operator line')
    ok(not BR.HealthShouldReport({ hp = A.reportHp - 1 }, A),
        'and one point short of it does not')
    ok(not BR.HealthShouldReport({ hp = A.reportHp * 10, reportedAt = 1 }, A),
        'a player already reported is not reported again -- a working exploit '
            .. 'crosses the bar on EVERY sample after the first, and four console '
            .. 'lines a second is the same as no detector')
    ok(not BR.HealthShouldReport(nil, A), 'and an untouched player is not reported')
end

-- ----------------------------------------------------------------- result ---

io.write(('\n%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
