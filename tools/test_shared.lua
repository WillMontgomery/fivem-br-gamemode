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
    'shared/loot_gen.lua',
    'shared/combat_solve.lua',
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

-- ----------------------------------------------------------------- result ---

io.write(('\n%s%d passed%s'):format('\27[32m', pass, '\27[0m'))
if fail > 0 then
    io.write(('  %s%d failed%s\n'):format('\27[31m', fail, '\27[0m'))
    os.exit(1)
end
io.write('\n')
