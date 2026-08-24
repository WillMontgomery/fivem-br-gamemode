-- Unit tests for the CPR kit's routing arithmetic (#191).
--
-- ═══ WHY THIS IS ITS OWN SUITE ═══
--
-- The destination rule is the one part of this feature that is both load-bearing
-- and effectively untestable in game. "Prefer a point that will be inside the
-- storm circle WHEN THE AMBULANCE ARRIVES" only differs from the obvious wrong
-- implementation -- test the circle as it stands NOW -- during a shrink, on a
-- route long enough for the wall to move past a candidate. Producing that in a
-- real match means waiting several minutes into a phase and then dying in the
-- right place, and the failure it would catch is invisible when it happens: the
-- player is simply delivered into the storm, which reads as bad luck.
--
-- So it is driven here instead, against a hand-built storm record and a clock
-- this file owns, where "the circle at dispatch and the circle on arrival
-- disagree" is three lines to set up.
--
-- ═══ WHAT IS NOT HERE ═══
--
-- The server's stuck-versus-destroyed arbitration is a scheduler, a roster and
-- BR.Combat away from pure, and it belongs in tools/test_roster.lua where those
-- already exist. What IS here is the one piece of it that is pure --
-- BR.RescueMoved, the progress threshold -- because the interesting cases are a
-- vehicle creeping along just under the bar and a position that never refreshed,
-- and neither is convenient to stage anywhere else.

function GetGameTimer() return 0 end

local ROOT = 'resources/[fivem-royale]/br_lib/'
local function load(f)
    local chunk, err = loadfile(ROOT .. f)
    if not chunk then
        print('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end

for _, f in ipairs({
    'shared/enums.lua',
    'shared/geo.lua',
    'config/match.lua',
    'config/overrides.lua',
    'config/storm.lua',
    'shared/storm_solve.lua',
    'config/map.lua',
    'config/loot.lua',
    'config/rescue.lua',
    'shared/rescue_solve.lua',
}) do load(f) end

local pass, fail = 0, 0
local group = ''
local function describe(n) group = n end
local function ok(cond, name, detail)
    if cond then pass = pass + 1 else
        fail = fail + 1
        print('\27[31mFAIL\27[0m ' .. group .. ' > ' .. name ..
            (detail and ('\n       ' .. tostring(detail)) or ''))
    end
end

local R = BR.Config.Rescue

-- ---------------------------------------------------------------------------
describe('eta')
do
    -- The estimate is monotonic in distance and never zero, because both of
    -- those are properties the deadline depends on: a deadline that does not
    -- grow with the route is #191's stated failure ("a long route fails a short
    -- timer"), and a zero one would expire on the tick it was set.
    local a = BR.RescueDriveMs(100.0, R)
    local b = BR.RescueDriveMs(1000.0, R)
    ok(a > 0, 'a short drive still takes time', a)
    ok(b > a, 'a longer drive takes longer', ('%.0f vs %.0f'):format(b, a))

    -- ROAD DISTANCE EXCEEDS THE STRAIGHT LINE, which is the whole of what
    -- etaRouteFactor is for -- asserted as an inequality rather than against a
    -- magic number so retuning the factor does not break the test that proves it
    -- is being applied at all.
    local straight = (1000.0 / R.etaSpeed) * 1000.0
    ok(b > straight, 'and it allows for roads being longer than the straight line',
        ('%.0f vs straight %.0f'):format(b, straight))

    -- THE CLAMPS ARE THE POINT OF THE DEADLINE, at BOTH ends.
    ok(BR.RescueDeadlineMs(1.0, R) >= R.etaFloorMs,
        'a trivial route still gets the floor -- a deadline shorter than the '
            .. 'fade would expire before the ride began',
        BR.RescueDeadlineMs(1.0, R))
    -- THE CEILING BOUNDS THE SLACK ON AN ORDINARY ROUTE...
    local ordinary = 600.0
    ok(BR.RescueDeadlineMs(ordinary, R) <= R.etaCeilMs,
        'an ordinary route is bounded by the ceiling',
        BR.RescueDeadlineMs(ordinary, R))

    -- ...AND NEVER AT THE COST OF UNDER-CUTTING THE DRIVE, which is the property
    -- that actually matters and the one a plain clamp got wrong. #191's stated
    -- failure is "a long route fails a short timer"; a ceiling applied without
    -- this guarantee IS a short timer, just one nobody configured on purpose.
    -- Asserted across the whole plausible range rather than at one point,
    -- because the bug only appears past wherever the ceiling happens to bite.
    for _, d in ipairs({ 1.0, 100.0, 600.0, 2000.0, 5000.0, 9000.0 }) do
        ok(BR.RescueDeadlineMs(d, R) > BR.RescueDriveMs(d, R),
            ('the deadline is longer than the drive it is derived from (%.0fm)'):format(d),
            ('deadline %.0f vs drive %.0f')
                :format(BR.RescueDeadlineMs(d, R), BR.RescueDriveMs(d, R)))
    end
end

-- ---------------------------------------------------------------------------
describe('nearest')
do
    local pts = {
        { id = 'a', x = 0.0,    y = 0.0 },
        { id = 'b', x = 500.0,  y = 0.0 },
        { id = 'c', x = 5000.0, y = 0.0 },
    }
    local p, d = BR.RescueNearest(pts, 480.0, 0.0)
    ok(p and p.id == 'b', 'the pickup is the closest authored point',
        p and p.id)
    ok(math.abs(d - 20.0) < 0.01, 'and its distance comes back with it', d)

    local none, nd = BR.RescueNearest({}, 0.0, 0.0)
    ok(none == nil, 'no points means no pickup rather than a crash')
    ok(nd == math.huge, 'and an infinite distance rather than zero -- zero would '
        .. 'read as "it is right here"', nd)
end

-- ---------------------------------------------------------------------------
describe('destination.inCircle')
do
    -- A STATIC circle at the origin, radius 400. Two candidates inside it and
    -- one far outside.
    local storm = {
        phase = 1,
        cx0 = 0.0, cy0 = 0.0, r0 = 400.0,
        cx1 = 0.0, cy1 = 0.0, r1 = 400.0,
        tStart = 0, tWait = 10 * 60 * 1000, tShrink = 1000, dps = 1.0,
    }
    local pts = {
        { id = 'far_inside',  x = 100.0,  y = 0.0 },
        { id = 'near_inside', x = 350.0,  y = 0.0 },
        { id = 'outside',     x = 3000.0, y = 0.0 },
    }

    -- Dispatching from x = 400: `near_inside` is 50m away, `far_inside` is 300m.
    -- Both qualify, so the SHORTEST wins.
    local d, dist, inside = BR.RescueDestination(pts, 400.0, 0.0, storm, 0, R)
    ok(d and d.id == 'near_inside',
        'among points inside the circle, the shortest route wins', d and d.id)
    ok(inside == true, 'and it is reported as a qualifying pick')
    ok(math.abs(dist - 50.0) < 0.01, 'with the distance it was chosen on', dist)

    -- THE FILTER IS NOT A SCORE, AND THIS IS THE ASSERTION THAT PROVES IT.
    -- Dispatch from just outside the wall, where the OUTSIDE point is nearer
    -- than either qualifying one. A weighted score would take it; a filter
    -- followed by a minimum cannot.
    local pts2 = {
        { id = 'inside',       x = 0.0,    y = 0.0 },
        { id = 'closer_but_out', x = 3100.0, y = 0.0 },
    }
    local d2 = BR.RescueDestination(pts2, 3000.0, 0.0, storm, 0, R)
    ok(d2 and d2.id == 'inside',
        'a NEARER point outside the circle never beats a further one inside it '
            .. '-- the rule is a filter, not a trade-off',
        d2 and d2.id)
end

-- ---------------------------------------------------------------------------
describe('destination.predictsTheShrink')
do
    -- ═══ THE TEST THIS SUITE EXISTS FOR ═══
    --
    -- A circle that is about to collapse from 4000m to 200m, centred on the
    -- origin, with the shrink already under way. A candidate sitting at 1500m is
    -- COMFORTABLY INSIDE the wall right now and will be well OUTSIDE it by the
    -- time an ambulance could get there.
    --
    -- An implementation that tests the circle as it stands at dispatch picks it
    -- and delivers the player into the storm. One that solves forward does not.
    local storm = {
        phase = 1,
        cx0 = 0.0, cy0 = 0.0, r0 = 4000.0,
        cx1 = 0.0, cy1 = 0.0, r1 = 200.0,
        tStart = 0, tWait = 0, tShrink = 30000, dps = 5.0,
    }

    local doomed = { id = 'doomed', x = 1500.0, y = 0.0 }
    local safe   = { id = 'safe',   x = 120.0,  y = 0.0 }

    -- Sanity: at dispatch the doomed point really is inside, so the test is
    -- testing what it claims to. Without this the assertion below could pass for
    -- the wrong reason -- a point that was never eligible at all.
    local cx, cy, r = BR.StormAt(storm, 0)
    ok(BR.InCircle(doomed.x, doomed.y, cx, cy, r),
        'the doomed point IS inside the circle at the moment of dispatch',
        ('r now %.0f, point at %.0f'):format(r, doomed.x))

    -- ...and by the time an ambulance drives there from 2000m out, it is not.
    local eta = BR.RescueDriveMs(BR.Dist(2000.0, 0.0, doomed.x, doomed.y), R)
    local _, _, rLater = BR.StormAt(storm, eta)
    ok(rLater < doomed.x,
        'and outside it by the time an ambulance could arrive',
        ('r on arrival %.0f, point at %.0f'):format(rLater, doomed.x))

    local d, _, inside = BR.RescueDestination({ doomed, safe }, 2000.0, 0.0, storm, 0, R)
    ok(d and d.id == 'safe',
        'so the destination is solved against the circle ON ARRIVAL, not the '
            .. 'one at dispatch -- this is the whole rule',
        d and d.id)
    ok(inside == true, 'and the surviving point still qualifies')
end

-- ---------------------------------------------------------------------------
describe('destination.perCandidateTiming')
do
    -- Each candidate is timed SEPARATELY, because a further point is reached
    -- later and meets a smaller circle. A single shared prediction would
    -- systematically over-qualify distant points -- exactly the ones most likely
    -- to be outside the wall on arrival.
    --
    -- Two points at the same bearing, one twice as far. The shrink is tuned so
    -- the near one is still inside on ITS arrival and the far one is not on
    -- ITS. If both were judged against one prediction they would pass or fail
    -- together.
    local storm = {
        phase = 1,
        cx0 = 0.0, cy0 = 0.0, r0 = 3000.0,
        cx1 = 0.0, cy1 = 0.0, r1 = 100.0,
        tStart = 0, tWait = 0, tShrink = 60000, dps = 5.0,
    }
    local near = { id = 'near', x = 400.0,  y = 0.0 }
    local far  = { id = 'far',  x = 1200.0, y = 0.0 }

    local etaNear = BR.RescueDriveMs(BR.Dist(0.0, 0.0, near.x, near.y), R)
    local etaFar  = BR.RescueDriveMs(BR.Dist(0.0, 0.0, far.x,  far.y),  R)
    local _, _, rNear = BR.StormAt(storm, etaNear)
    local _, _, rFar  = BR.StormAt(storm, etaFar)

    ok(rNear > rFar, 'the further candidate is judged against a smaller circle',
        ('near r %.0f, far r %.0f'):format(rNear, rFar))

    local d = BR.RescueDestination({ far, near }, 0.0, 0.0, storm, 0, R)
    ok(d ~= nil, 'a destination is still chosen')
    ok(d.id == 'near' or rFar >= far.x,
        'and a candidate is never qualified by another candidate\'s arrival time',
        d.id)
end

-- ---------------------------------------------------------------------------
describe('destination.fallback')
do
    -- NOTHING QUALIFIES IS A NORMAL CASE, NOT AN ERROR. Late in a match the
    -- circle can be smaller than the gaps between authored points. Refusing the
    -- rescue would burn an ultra-rare item for nothing, and driving into the
    -- wall would be worse, so the fallback is the point nearest the predicted
    -- CENTRE -- the least-bad drop available.
    local storm = {
        phase = 4,
        cx0 = 0.0, cy0 = 0.0, r0 = 50.0,
        cx1 = 0.0, cy1 = 0.0, r1 = 50.0,
        tStart = 0, tWait = 10 * 60 * 1000, tShrink = 1000, dps = 10.0,
    }
    local pts = {
        { id = 'miles_away', x = 6000.0, y = 0.0 },
        { id = 'closest',    x = 900.0,  y = 0.0 },
    }

    local d, _, inside = BR.RescueDestination(pts, 5000.0, 0.0, storm, 0, R)
    ok(d ~= nil, 'a rescue with no qualifying point still gets a destination')
    ok(inside == false, 'and it is reported as NOT qualifying, so the log can '
        .. 'say which of the two happened')
    ok(d.id == 'closest',
        'the fallback is the point nearest the circle centre, not the nearest '
            .. 'to the ambulance -- being close to safety beats being close to '
            .. 'the start',
        d.id)

    -- An empty list is the half-landed-config case: BR.Config.Rescue.points
    -- ships empty on purpose (the owner's 23 authored points had not reached dev
    -- when this was written), and the feature must be inert rather than broken.
    local none = BR.RescueDestination({}, 0.0, 0.0, storm, 0, R)
    ok(none == nil, 'and no points at all yields no destination rather than a crash')
end

-- ---------------------------------------------------------------------------
describe('destination.noStorm')
do
    -- Before the first circle is published there is nothing to be inside of.
    -- Treating that as "nothing qualifies" would send every pre-storm rescue
    -- down the fallback path for no reason.
    local pts = {
        { id = 'near', x = 100.0,  y = 0.0 },
        { id = 'far',  x = 4000.0, y = 0.0 },
    }
    local d, _, inside = BR.RescueDestination(pts, 0.0, 0.0, nil, 0, R)
    ok(d and d.id == 'near',
        'with no storm record the shortest route simply wins', d and d.id)
    ok(inside == true, 'and it counts as qualifying -- there is no constraint to fail')
end

-- ---------------------------------------------------------------------------
describe('moved')
do
    ok(BR.RescueMoved({ x = 0.0, y = 0.0 }, { x = 50.0, y = 0.0 }, R) == true,
        'an ambulance that has driven 50m has moved')
    ok(BR.RescueMoved({ x = 0.0, y = 0.0 }, { x = 0.5, y = 0.0 }, R) == false,
        'one that has shuffled half a metre against a kerb has not')

    -- THE NIL CASES ARE THE ONES THAT MATTER, and both answer "not moving".
    -- `pos` is nil for a player the server has not sampled yet; treating an
    -- absent sample as movement would mean a rescue could never be judged stuck
    -- during the exact window in which it is most likely to be.
    ok(BR.RescueMoved(nil, { x = 99.0, y = 0.0 }, R) == false,
        'no previous sample is not evidence of movement')
    ok(BR.RescueMoved({ x = 0.0, y = 0.0 }, nil, R) == false,
        'and neither is a missing current one')

    -- The boundary, explicitly: the threshold is inclusive, so a vehicle sitting
    -- exactly on the bar counts as moving rather than being recovered forever.
    ok(BR.RescueMoved({ x = 0.0, y = 0.0 }, { x = R.progressM, y = 0.0 }, R) == true,
        'the progress threshold is inclusive at the boundary')
end

-- ---------------------------------------------------------------------------
describe('config')
do
    -- THE POINTS SHIP EMPTY AND THAT IS DELIBERATE. The owner authored 23 in
    -- game on 2026-08-23 and they were landing in config/map.lua by a separate
    -- change; a second copy here would drift from that one. This asserts the
    -- READER rather than the contents, because the contents are somebody else's
    -- to land.
    ok(type(BR.Config.Rescue.Points()) == 'table',
        'the points reader always answers a table, even with nothing authored')

    BR.Config.Map.RescuePoints = { { id = 'x', x = 1.0, y = 2.0, z = 3.0 } }
    ok(#BR.Config.Rescue.Points() == 1,
        'and it prefers the authored list in config/map.lua when there is one')
    BR.Config.Map.RescuePoints = nil
    ok(#BR.Config.Rescue.Points() == #BR.Config.Rescue.points,
        'falling back to its own table when there is not')

    -- THE ITEM IS RESOLVABLE AND UNROLLABLE, which is the airdrop-shelf pattern
    -- and is what keeps the world layout byte-identical. Both halves are
    -- asserted, because either one alone is a different (broken) feature: an
    -- unresolvable id makes the airdrop pool silently drop it, and a bucketed
    -- one puts CPR kits in crates at a weight nobody has chosen.
    ok(BR.Config.ConsumableById['cprkit'] ~= nil,
        'the CPR kit resolves by id, so the airdrop healing pool picks it up')
    local bucketed = false
    for r = BR.Rarity.COMMON, BR.Rarity.LEGENDARY do
        for _, c in ipairs(BR.Config.ConsumablesByRarity[r] or {}) do
            if c.id == 'cprkit' then bucketed = true end
        end
    end
    ok(not bucketed,
        'and is in NO rarity bucket, so no world roll can ever produce it -- '
            .. '#191 says the weight is not yet decided, so none is invented')

    ok(BR.Config.CprKit.maxStack == 1 and BR.Config.CprKit.carryMax == 1,
        'one kit is one life: the stack and the carry cap agree at 1')

    -- THE AMBULANCE IS NOT INVINCIBLE (owner, 2026-08-23), and the config must
    -- not grow a knob that makes it so. This is a guard against the issue body's
    -- "godmode and bulletproof tyres" being re-added from the spec by somebody
    -- reading it without the comment thread.
    ok(R.godmode == nil and R.invincible == nil,
        'there is no invincibility knob -- the owner reversed that and a knob '
            .. 'would be an invitation to turn it back on')

    -- ONE LIST FOR BOTH JOBS. The vehicle the rescue BUILDS must be one of the
    -- models it RECOGNISES, or a rescue ambulance would not count as an
    -- ambulance -- which is the kind of contradiction that only shows up as a
    -- missing blip nobody can explain.
    local built = false
    for _, name in ipairs(R.models or {}) do
        if name == R.model then built = true end
    end
    ok(built, 'the model the rescue spawns is one of the models it recognises',
        R.model)
end

-- ---------------------------------------------------------------------------
describe('discovered.doNotJoinTheRoute')
do
    -- ═══ AMBIENT AMBULANCES ARE BLIPS AND NOTHING ELSE ═══
    --
    -- Owner, 2026-08-23: ambulances spawn naturally, and one a player is seen
    -- driving joins "our list of blips". It must NOT join the list the rescue
    -- routes over: a pickup or drop-off has to be somewhere an ambulance can
    -- stand and drive from, and a vehicle abandoned halfway up a mountain is not.
    -- It would also be an exploit shaped like an invitation -- park an ambulance
    -- somewhere terrible and rescues start routing there.
    --
    -- ASSERTED ON THE READER, which is the only thing that could ever merge
    -- them: BR.Config.Rescue.Points() is what server/rescue.lua routes over, and
    -- discovery writes to a table it does not consult.
    local before = #BR.Config.Rescue.Points()
    BR.Config.Rescue.discovered = { { id = 'stolen', x = 1.0, y = 1.0, z = 1.0 } }
    ok(#BR.Config.Rescue.Points() == before,
        'nothing a player parks can widen the set of points a rescue routes over')
    BR.Config.Rescue.discovered = nil
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
