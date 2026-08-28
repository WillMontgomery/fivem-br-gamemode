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

local fakeTime = 0
function GetGameTimer() return fakeTime end

local RES = 'resources/[fivem-royale]/'
local ROOT = RES .. 'br_lib/'
local function loadAt(root, f)
    local chunk, err = loadfile(root .. f)
    if not chunk then
        print('\27[31mload error\27[0m ' .. f .. ': ' .. tostring(err))
        os.exit(1)
    end
    chunk()
end
local function load(f) loadAt(ROOT, f) end
--- A br_core module, by its path under resources/[fivem-royale]/.
local function loadCore(f) loadAt(RES, f) end

for _, f in ipairs({
    'shared/enums.lua',
    'shared/geo.lua',
    -- BR.Net, for the two blocks at the foot of this file that drive real
    -- event handlers rather than pure solvers.
    'shared/protocol.lua',
    'config/match.lua',
    'config/overrides.lua',
    'config/storm.lua',
    'shared/storm_solve.lua',
    'config/map.lua',
    'config/loot.lua',
    -- BR.LootLabel, which server/inventory.lua's public projection calls on
    -- every push.
    'shared/rng.lua',
    'shared/loot_gen.lua',
    -- BR.Config.Fuel.healthMax: the denominator the condition bar uses, and so
    -- the one client/rescue.lua's wreck test measures against.
    'config/fuel.lua',
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
        { id = 'far_inside',  x = 0.0,    y = 0.0 },
        { id = 'near_inside', x = 200.0,  y = 0.0 },
        { id = 'outside',     x = 3000.0, y = 0.0 },
    }

    -- Dispatching from x = 400: `near_inside` is 200m away, `far_inside` is 400m.
    -- Both qualify and both clear minTripM, so the SHORTEST wins.
    --
    -- THE FIXTURE MOVED WHEN minTripM ARRIVED. It used to put `near_inside` 50m
    -- from the dispatch point, which the floor now refuses -- so the case was
    -- asserting the right property with numbers that had stopped being able to
    -- express it. Both candidates are past the floor now and the ordering is
    -- still what is under test.
    local d, dist, inside = BR.RescueDestination(pts, 400.0, 0.0, storm, 0, R)
    ok(d and d.id == 'near_inside',
        'among points inside the circle, the shortest route wins', d and d.id)

    -- ═══ THE PICKUP CANNOT BE THE DESTINATION ═══
    --
    -- Owner, 2026-08-28, on the first ride that ran: "It drove for maybe 30
    -- seconds successfully, but then de-spawned and put me back at the point
    -- where it spawned."
    --
    -- The pickup is one of the same surveyed points the destination is chosen
    -- from, and it is ZERO metres from itself, so it won every time. The ride
    -- was a circle and the delivery was a teleport to where it began.
    local here = { id = 'here', x = 400.0, y = 0.0 }
    local withHere = { here, pts[1], pts[2], pts[3] }
    local d2 = BR.RescueDestination(withHere, 400.0, 0.0, storm, 0, R, here)
    ok(d2 and d2.id ~= 'here',
        'the point the ambulance was built at is never the place it drives to',
        d2 and d2.id)

    -- And the floor covers the same failure without an explicit exclusion: two
    -- surveyed car parks in one forecourt would produce the same non-journey.
    local d3 = BR.RescueDestination(
        { { id = 'next_door', x = 420.0, y = 0.0 }, pts[2] },
        400.0, 0.0, storm, 0, R)
    ok(d3 and d3.id ~= 'next_door',
        'a destination inside minTripM of the pickup is refused', d3 and d3.id)
    ok(inside == true, 'and it is reported as a qualifying pick')
    ok(math.abs(dist - 200.0) < 0.01, 'with the distance it was chosen on', dist)

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
        { id = 'near', x = 200.0,  y = 0.0 },   -- past minTripM; 100 was not
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
    -- ═══ THE READER IS POINTED AT THE OWNER'S OWN SURVEY ═══
    --
    -- He authored 23 points in game on 2026-08-23 with /brcoords, and they live
    -- in config/map.lua as BR.Config.Map.AmbulanceSpawns -- which is where he
    -- will edit them. THIS FILE'S OWN `points` TABLE IS EMPTY on purpose: a
    -- second copy of twenty-three surveyed coordinates would drift from the
    -- first, and the symptom would be ambulances arriving where a point used to
    -- be.
    --
    -- ASSERTED AGAINST THE REAL TABLE RATHER THAN A FIXTURE, because the failure
    -- worth catching is precisely the one that a fixture hides: the reader
    -- naming a table that does not exist. An earlier draft of this feature read
    -- `BR.Config.Map.RescuePoints`, which was a guess at the name and was wrong
    -- -- and against a fixture that injected `RescuePoints` it passed happily
    -- while the shipped feature would have found nothing and refused every
    -- rescue.
    ok(#BR.Config.Rescue.points == 0,
        'this file holds no copy of the surveyed points',
        #BR.Config.Rescue.points)
    ok(type(BR.Config.Map.AmbulanceSpawns) == 'table'
       and #BR.Config.Map.AmbulanceSpawns > 0,
        'config/map.lua carries the owner-surveyed ambulance points',
        BR.Config.Map.AmbulanceSpawns and #BR.Config.Map.AmbulanceSpawns)
    ok(BR.Config.Rescue.Points() == BR.Config.Map.AmbulanceSpawns,
        'and the rescue reads THAT table, not a name nobody writes',
        #BR.Config.Rescue.Points())

    -- Every point has to be routable and placeable: the solver measures against
    -- x/y, and the ambulance is created at z facing `heading`. A row missing any
    -- of the four is a rescue that spawns at the origin or under the map.
    local bad = 0
    for _, p in ipairs(BR.Config.Rescue.Points()) do
        if type(p.x) ~= 'number' or type(p.y) ~= 'number'
           or type(p.z) ~= 'number' or type(p.heading) ~= 'number' then
            bad = bad + 1
        end
    end
    ok(bad == 0, 'every surveyed point carries x, y, z and a heading', bad)

    -- AND THE FEATURE IS INERT, NOT BROKEN, IF THAT TABLE EVER EMPTIES.
    local saved = BR.Config.Map.AmbulanceSpawns
    BR.Config.Map.AmbulanceSpawns = nil
    ok(#BR.Config.Rescue.Points() == 0,
        'with the survey gone the reader answers empty rather than erroring')
    BR.Config.Map.AmbulanceSpawns = saved

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

    -- ═══ THE STRETCHER IS THE OWNER'S MEASUREMENT, NOT A GUESS ═══
    --
    -- Authored in game with /brattach on 2026-08-23 and confirmed by looking at
    -- it. Pinned as literals because the failure they guard against is silent:
    -- a body in the wrong place still rides to the destination, and nobody finds
    -- out until somebody watches a rescue.
    --
    -- THE ROLL IS ZERO ON PURPOSE. The placeholder these replaced carried 90, on
    -- the reasonable-sounding theory that a ped must be rolled onto its back to
    -- lie down. It does not, and this asserts the measured value so that theory
    -- cannot quietly come back.
    local S = R.stretcher
    ok(S and math.abs(S.x - (-0.010)) < 1e-6
         and math.abs(S.y - (-3.100)) < 1e-6
         and math.abs(S.z - 1.690) < 1e-6,
        'the stretcher offset is the one the owner measured',
        S and ('%.3f, %.3f, %.3f'):format(S.x, S.y, S.z))
    ok(S and S.pitch == 0.0 and S.roll == 0.0 and S.yaw == 1.0,
        'and so is the rotation, roll included',
        S and ('%.1f, %.1f, %.1f'):format(S.pitch, S.roll, S.yaw))

    -- EXTRAS 1 AND 2 (owner, 2026-08-23). Asserted as a set rather than by
    -- index, so reordering the list is not a failure but losing one is.
    local want = { [1] = false, [2] = false }
    for _, id in ipairs(R.extras or {}) do want[id] = true end
    ok(want[1] and want[2],
        'extras 1 and 2 are both configured to be enabled',
        table.concat(R.extras or {}, ','))

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

-- ═══════════════════════════════════════════════════════════════════════════
-- THE TWO FAULTS FROM THE 2026-08-23 PLAYTEST
-- ═══════════════════════════════════════════════════════════════════════════
--
-- Owner, testing 876acde:
--
--   "I tried using the CPR kit but upon dying I get no prompt to use the CPR
--    kit. I thought perhaps I should have used it while standing to 'arm it' or
--    something, and seems that was the written (but not acceptable) path(?),
--    and produced this error on the server:
--    @br_core/server/inventory.lua:883: attempt to perform arithmetic on a nil
--    value (field 'useMs')
--
--    To be clear, this item should do absolutely nothing while the player is
--    alive. While they're bleeding out there should be a 'Press [interact key]
--    to use the CPR kit'"
--
-- Two faults, and neither was reachable by anything above this line: everything
-- above is pure arithmetic over config, and both of these are BEHAVIOUR -- an
-- event handler that threw, and a prompt loop whose output nobody had ever
-- counted. So the two blocks below load the real modules against stub natives,
-- which is tools/test_client.lua's arrangement rather than a new idea.
--
-- WHAT THEY CAN AND CANNOT SETTLE. They can settle what was SENT and what was
-- DRAWN and where. They cannot settle whether the player can see it -- and that
-- distinction is the whole story of fault 2, so it is worth being exact about:
-- the prompt was always sent, and it was always drawn, and it was drawn
-- underneath an opaque NUI placard.
--
-- ═══ THE SURFACE THESE ASSERTIONS PIN CHANGED ON 2026-08-24 ═══
--
-- Two native draws were tried and both were invisible, in opposite ways: at the
-- shared prompt position the placard composited on top of it, and on the
-- player's head anchor the ground-level downed camera put it behind the body.
-- The owner's fix removes the contest -- "Why don't we just make it part of the
-- bleed out timer card?" -- so the prompt is now a ROW OF THAT CARD, handed
-- across as one boolean on the downed payload (BR.Dbno.setCpr).
--
-- The four assertions that used to pin the DUI draw now pin that: that nothing
-- is drawn natively AT ALL, that the fact reaches the interface as a bare bit
-- with no key label on it, and that it flips on change rather than per frame.
-- The reasoning is in client/rescue.lua and in DbnoOverlay.tsx.

-- ---------------------------------------------------------------------------
describe('kit.inertWhileAlive')
do
    -- FAULT 1. `cprkit` is a CONSUMABLE with no `useMs`, deliberately -- it is
    -- spent by the prompt while downed, not channelled from the inventory -- and
    -- nothing refused it before `GetGameTimer() + c.useMs`.

    local notes, sent = {}, {}
    local handlers = {}

    local roster = {}
    BR.Roster = {
        get  = function(src) return roster[src] end,
        each = function(pred, fn)
            for src, e in pairs(roster) do
                if not pred or pred(e) then fn(src, e) end
            end
        end,
    }
    BR.Server = {
        matchOf = function() return { state = BR.MatchState.PLAYING } end,
        -- EVERY REFUSAL THIS FILE CAN PRODUCE LANDS HERE, which is what lets the
        -- assertions below say "and it said nothing" rather than assuming it.
        notify  = function(_, msg) notes[#notes + 1] = msg end,
    }
    BR.Sched = { every = function() end }

    _G.RegisterNetEvent = function() end
    _G.AddEventHandler  = function(name, fn) handlers[name] = fn end
    _G.TriggerClientEvent = function(evt, src, d)
        sent[#sent + 1] = { evt = evt, src = src, d = d }
    end

    loadCore('br_core/server/inventory.lua')

    --- Deliver an event the way the platform does: `source` is a global.
    local function fire(evt, src, payload)
        _G.source = src
        local okCall, err = pcall(handlers[evt], payload)
        _G.source = nil
        return okCall, err
    end

    local function player(src)
        roster[src] = { src = src, state = BR.PlayerState.ALIVE,
                        matchId = 1, hp = 100.0, armour = 0.0 }
        BR.Inv.reset(src)
        return BR.Inv.of(src)
    end

    -- ═══ THE CRASH, EXACTLY AS REPORTED ═══
    local inv = player(1)
    BR.Inv.give(1, { item = 'cprkit', kind = BR.ItemKind.CONSUMABLE,
                     rarity = BR.Rarity.LEGENDARY, count = 1 })
    notes, sent = {}, {}

    local okCall, err = fire(BR.Net.INV_USE, 1, { slot = 1 })
    ok(okCall, 'using a CPR kit while alive does not throw -- this is the line '
        .. 'that took the server down (inventory.lua:883)', err)

    -- ═══ ...AND IT DOES NOTHING, WHICH IS THE ACTUAL REQUIREMENT ═══
    --
    -- "this item should do absolutely nothing while the player is alive."
    -- Not crashing is the floor. No channel, no message, no burnt kit.
    ok(inv.using == nil, 'no channel is started',
        inv.using and inv.using.item or 'nil')
    ok(#notes == 0, 'and the player is told nothing at all -- a refusal message '
        .. 'here would be the "AI slop" the owner has objected to',
        notes[1])
    ok(inv.slots[1] and inv.slots[1].item == 'cprkit',
        'and the kit is still in the slot, unspent',
        inv.slots[1] and inv.slots[1].item or 'gone')

    -- ═══ THE CONTROL: AN ORDINARY CONSUMABLE STILL WORKS ═══
    --
    -- Without this the guard could be refusing every consumable in the game and
    -- the three assertions above would still pass.
    inv = player(2)
    BR.Inv.give(2, { item = 'medkit', kind = BR.ItemKind.CONSUMABLE,
                     rarity = BR.Rarity.EPIC, count = 1 })
    roster[2].hp = 10.0
    fire(BR.Net.INV_USE, 2, { slot = 1 })
    ok(inv.using ~= nil and inv.using.item == 'medkit',
        'a med kit still channels -- the guard refuses a class, not the feature',
        inv.using and inv.using.item or 'nothing started')
    ok(inv.using and inv.using.ms == BR.Config.ConsumableById.medkit.useMs,
        'for the duration its config declares',
        inv.using and tostring(inv.using.ms))

    -- ═══ AND THE CLASS, NOT JUST THE KIT ═══
    --
    -- The kit is the item that found this; it is not the last item that could.
    -- A consumable that heals but declares no duration is the same crash with a
    -- different name, and it would reach further into the handler than the kit
    -- ever did -- past the "would this do nothing" refusals, which notify. This
    -- registers exactly that item, drives it, and takes it away again.
    BR.Config.ConsumableById.__probe = {
        id = '__probe', label = 'Probe', kind = BR.ItemKind.CONSUMABLE,
        rarity = BR.Rarity.COMMON, maxStack = 1, carryMax = 1,
        health = 100, healthCap = 100,   -- ...and no useMs
    }
    inv = player(3)
    BR.Inv.give(3, { item = '__probe', kind = BR.ItemKind.CONSUMABLE,
                     rarity = BR.Rarity.COMMON, count = 1 })
    roster[3].hp = 10.0
    notes = {}
    okCall, err = fire(BR.Net.INV_USE, 3, { slot = 1 })
    ok(okCall, 'ANY consumable with no useMs is refused rather than crashing -- '
        .. 'the next one somebody adds is already covered', err)
    ok(inv.using == nil and #notes == 0,
        'silently, on the same rule', notes[1])
    BR.Config.ConsumableById.__probe = nil

    -- The config the guard reads. Asserted so that "the kit has no useMs" stays
    -- a deliberate property of the item rather than something a later edit
    -- papers over with a fake duration -- which is the one fix that would make
    -- the crash go away AND give the kit a channel nothing can start.
    ok(BR.Config.CprKit.useMs == nil,
        'and the kit still declares no useMs, because it is not an inventory '
            .. 'item -- the fix is the guard, not a made-up duration')
end

-- ---------------------------------------------------------------------------
describe('kit.promptWhileDowned')
do
    -- FAULT 2. The prompt that never appeared.

    local sends, screenDraws, worldDraws = {}, {}, {}

    -- The client's own neighbours. BR.Inv is the SERVER model from the block
    -- above; the client's mirror is a different object with a different reader,
    -- so it is stubbed rather than borrowed.
    local slots = {}
    BR.Inv = BR.Inv or {}
    BR.Inv.local_ = function() return { slots = slots } end

    -- ═══ THE SURFACE. One boolean, onto the downed payload. ═══
    --
    -- BR.Dbno.setCpr is client/dbno.lua's merge into the envelope that feeds the
    -- bleed-out card (ui-src/src/hud/DbnoOverlay.tsx). Stubbed rather than
    -- loaded: dbno.lua is also the crawl, the camera and the revive, and none of
    -- that is what this block is about. What is recorded here is the whole of
    -- what rescue.lua now hands the interface.
    --
    -- TWO BITS NOW, NOT ONE. `setRiding` is the second (owner, 2026-08-28: the
    -- HUD goes away in the ambulance, and the bleed-out card with it), and it
    -- travels the same route for the same reason. Recorded separately so the
    -- block below can say which of the two moved.
    local cpr, riding = {}, {}
    -- SEEDED false, because `mine.riding` is. The real BR.Dbno.setRiding
    -- refuses an unchanged answer, and a stub that recorded every call would
    -- make "sixty frames of a ride cost one envelope" untestable -- it would be
    -- measuring the LOOP's discipline rather than the pair's. So the stub keeps
    -- the same latch the real one has, starting where the real one starts.
    local ridingLast = false
    BR.Dbno = {
        setCpr    = function(v) cpr[#cpr + 1] = v end,
        setRiding = function(v)
            if v == ridingLast then return end
            ridingLast = v
            riding[#riding + 1] = v
        end,
    }

    -- STILL STUBBED, AND THAT IS THE POINT: every one of these must stay empty.
    -- The prompt used to go out through `send` and land through `drawScreen` or
    -- `drawWorld`, and a second surface growing back would show up here.
    BR.Dui = {
        page       = function(n) return { name = n } end,
        send       = function(_, m) sends[#sends + 1] = m end,
        ready      = function() return true end,
        drawScreen = function(_, x, y) screenDraws[#screenDraws + 1] = { x = x, y = y } end,
        drawWorld  = function(_, x, y, z) worldDraws[#worldDraws + 1] = { x = x, y = y, z = z } end,
        drawOnEntity = function() end,
    }
    BR.Keys       = { on = function() end, isHeld = function() return false end }
    -- A TRIPWIRE, not a stub with a job. Nothing in this feature may resolve a
    -- key label any more: ui/KeyCap.tsx draws the glyph from the binding the
    -- interface already holds, and a letter sent from Lua is a second copy of
    -- that binding which goes stale the moment the player rebinds interact.
    local askedForKey = false
    BR.Native     = { keyLabelForCommand = function()
        askedForKey = true
        return 'E'
    end }
    BR.Squadmates = { headAnchor = function() return 10.0, 20.0, 30.0 end }
    _G.PlayerPedId     = function() return 1 end
    _G.GetEntityCoords = function() return { x = 10.0, y = 20.0, z = 29.4 } end
    _G.Citizen = { CreateThread = function() end, Wait = function() end }
    _G.RegisterNetEvent = function() end
    -- CAPTURED RATHER THAN DISCARDED, so the ride can actually be STARTED.
    -- `ride` is a local in client/rescue.lua and the only door to it is
    -- BR.Net.RESCUE_BEGIN; without this the block below could assert what the
    -- flag does when there is no ride and nothing else.
    --
    -- Citizen.CreateThread stays a no-op on purpose, so `board` is registered
    -- and never runs: it fades the screen in a loop bounded by GetGameTimer,
    -- and this file's clock only moves when a test moves it -- an inline thread
    -- would spin there for ever. What that costs is exercised below.
    local chandlers = {}
    _G.AddEventHandler  = function(name, fn) chandlers[name] = fn end
    _G.TriggerServerEvent = function() end
    _G.RegisterCommand  = function() end

    loadCore('br_core/client/main.lua')

    BR.State = {
        me     = { src = 1, state = BR.PlayerState.ALIVE },
        match  = { state = BR.MatchState.PLAYING, mode = BR.Mode.SOLO.key },
        roster = {},
    }

    loadCore('br_core/client/rescue.lua')

    local function frame(n)
        for _ = 1, (n or 1) do
            fakeTime = fakeTime + 16
            BR.Loop.step(BR.Loop.FRAME)
        end
    end
    local function shows()
        local n = 0
        for _, v in ipairs(cpr) do if v then n = n + 1 end end
        return n
    end

    -- ═══ INERT WHILE ALIVE ═══
    slots[1] = { id = 'cprkit' }
    frame(30)
    ok(shows() == 0,
        'a living player carrying a kit is offered nothing, for thirty frames',
        shows())

    -- ═══ AND OFFERED, ONCE, WHILE BLEEDING OUT ═══
    BR.State.me.state = BR.PlayerState.DBNO
    cpr, sends, screenDraws, worldDraws = {}, {}, {}, {}
    frame(60)

    ok(shows() == 1,
        'a downed solo carrying a kit gets EXACTLY ONE prompt across sixty '
            .. 'frames -- one notification is the whole rule of this feature, '
            .. 'and the card should not be re-rendered sixty times a second',
        shows())

    ok(cpr[1] == true, 'and it is a show rather than a hide',
        tostring(cpr[1]))

    -- ═══ RE-POINTED FROM THE DUI DRAW: THE PROMPT IS THE CARD ═══
    --
    -- Owner, 2026-08-23: "Why don't we just make it part of the bleed out timer
    -- card?" -- after two native draws that were both invisible. At the shared
    -- prompt position (0.5, 0.78) the sprite went UNDER
    -- ui-src/src/hud/DbnoOverlay.tsx's `absolute inset-x-0 bottom-40`
    -- `.panel-hot` at rgba(8, 9, 14, 0.94), because NUI composites above every
    -- native draw and that placard is on screen at exactly and only the moment
    -- this prompt is. Moved onto the head anchor it went BEHIND the body,
    -- because client/dbno.lua parks the downed camera at ground level.
    --
    -- So the guard is no longer "which native draw" but "no native draw at all".
    -- The three BR.Dui recorders above are still live; all three must be empty.
    ok(#sends == 0 and #screenDraws == 0 and #worldDraws == 0,
        'nothing native is drawn or sent for this prompt any more -- the card '
            .. 'IS the surface, so there is no second one to be hidden behind '
            .. 'or to composite over',
        ('%d send(s), %d screen, %d world')
            :format(#sends, #screenDraws, #worldDraws))

    -- ═══ WHAT CROSSES THE BRIDGE IS ONE BIT, AND NOT A LETTER ═══
    --
    -- The wording ("Use the CPR kit", the owner's 2026-08-23 wording superseding
    -- #191 step 2's "call a medic") lives in the component now, and so does the
    -- key glyph -- ui/KeyCap.tsx resolves `brinteract` from the bindings the
    -- interface already holds. A label sent from here would be a second copy of
    -- the binding, stale the moment the player rebinds interact.
    ok(type(cpr[1]) == 'boolean',
        'it is a bare boolean on the downed payload, not a message with copy '
            .. 'in it -- the card owns the wording',
        type(cpr[1]))
    ok(askedForKey == false,
        'and no key label is resolved in Lua at all: the glyph follows the '
            .. 'binding on the interface side',
        tostring(askedForKey))

    -- ═══ SO THE WORDING IS PINNED WHERE IT NOW LIVES ═══
    --
    -- These three used to be assertions on the DUI message's label/hint/key.
    -- They are the same three claims, re-pointed at the file that owns them now
    -- -- a text read rather than a render, which is all this process can do and
    -- is stated so a pass is not read as more than it is. It is worth keeping:
    -- the wording has been changed by hand twice, and the whole point of writing
    -- it down was that the issue body still carries the superseded sentence.
    local card = io.open('ui-src/src/hud/DbnoOverlay.tsx')
    local cardSrc = card and card:read('a') or ''
    if card then card:close() end

    ok(cardSrc:find('Use the CPR kit', 1, true) ~= nil,
        'the card carries the owner\'s wording, "Use the CPR kit"',
        #cardSrc == 0 and 'DbnoOverlay.tsx did not open' or 'not in the file')
    ok(cardSrc:find('call a medic', 1, true) == nil,
        'and not #191 step 2\'s superseded "call a medic" -- it names the ITEM '
            .. 'the player is holding, not the implementation detail')
    ok(cardSrc:find('KeyCap', 1, true) ~= nil
           and cardSrc:find('brinteract', 1, true) ~= nil,
        'with the interact key drawn as a glyph by the shared KeyCap, which is '
            .. 'how every other key in the interface is drawn')

    -- ═══ AND IT IS POLLED EVERY FRAME, EVEN THOUGH IT IS SENT ONCE ═══
    --
    -- The loop is what notices `ride` starting, the kit going, or the player
    -- getting back up -- nothing events any of those. It used to also carry the
    -- per-frame draw; now it carries only the poll, so the thing worth pinning
    -- is that sixty frames of an unchanged answer cost exactly one call.
    ok(#cpr == 1,
        'sixty frames of the same answer cost exactly one call across the '
            .. 'bridge -- the loop polls, the send is on change',
        #cpr)

    -- ═══ THE THREE WAYS IT MUST GO AWAY ═══
    local function goesAway(what, mutate, restore)
        cpr = {}
        mutate()
        frame(5)
        local hid = false
        for _, v in ipairs(cpr) do if v == false then hid = true end end
        ok(hid and shows() == 0, what, ('%d call(s)'):format(#cpr))
        restore()
        frame(5)
        cpr = {}
    end

    goesAway('a squad player carrying a kit is offered nothing -- the kit is '
                .. 'solos only, and the client asks before the server does',
        function() BR.State.match.mode = BR.Mode.SQUAD.key end,
        function() BR.State.match.mode = BR.Mode.SOLO.key end)

    goesAway('a downed solo who is NOT carrying one is offered nothing',
        function() slots[1] = nil end,
        function() slots[1] = { id = 'cprkit' } end)

    goesAway('and it stops being offered the moment they are back on their feet',
        function() BR.State.me.state = BR.PlayerState.ALIVE end,
        function() BR.State.me.state = BR.PlayerState.DBNO end)

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE RIDE TAKES THE SCREEN WITH IT (owner, 2026-08-28)
    -- ═══════════════════════════════════════════════════════════════════════
    --
    --   "I need you to make the bleed out timer completely go away while in the
    --    ambulance. That time should not be relevant anymore once the ambulance
    --    takes over"
    --   "while in the ambulance, our HUD should be hidden just like in the bus"
    --
    -- ONE FLAG ANSWERS BOTH, because the bleed-out card is drawn inside the HUD
    -- and App.tsx already hides the whole HUD for the Battle Bus. What this
    -- block can settle is the LUA half: that the bit is published when a ride
    -- starts, that it costs one envelope rather than sixty a second, and -- the
    -- one that actually protects the player -- that it is taken back down on a
    -- teardown path that is not an event. It cannot settle that the browser
    -- hides anything; the two text reads at the end of the block pin the rule
    -- to the line that does.

    ok(#riding == 0,
        'a downed player who is NOT on an ambulance costs no riding envelope at '
            .. 'all -- the flag has never been sent up to this point',
        ('%d call(s)'):format(#riding))

    -- ═══ THE RIDE BEGINS ═══
    --
    -- `board` is a no-op here (Citizen.CreateThread is stubbed), which is
    -- exactly the shape worth testing: the flag must ride the HANDLER setting
    -- `ride`, not anything the boarding thread gets round to. A player whose
    -- ambulance model is still streaming is already in the cutscene.
    cpr = {}
    chandlers[BR.Net.RESCUE_BEGIN]({
        pickup = { x = 100.0, y = 200.0, z = 30.0, heading = 90.0 },
        dest   = { id = 'dest', x = 900.0, y = 800.0, z = 30.0 },
    })
    frame(60)

    ok(#riding == 1 and riding[1] == true,
        'the moment a rescue begins the interface is told once, and the HUD '
            .. 'rule in App.tsx has what it needs before the ambulance exists',
        ('%d call(s), first=%s'):format(#riding, tostring(riding[1])))

    ok(#cpr == 1 and cpr[1] == false,
        'and the CPR row is withdrawn in the same beat -- this file\'s one '
            .. 'notification has no surface left to be drawn on',
        ('%d call(s), first=%s'):format(#cpr, tostring(cpr[1])))

    frame(120)
    ok(#riding == 1,
        'and a hundred and eighty frames of an unchanged ride still cost that '
            .. 'one envelope -- the loop polls, the send is on change',
        ('%d call(s)'):format(#riding))

    -- ═══ AND IT COMES BACK DOWN ON A PATH NOTHING EVENTS ═══
    --
    -- THIS IS THE ASSERTION THE WHOLE ARRANGEMENT EXISTS FOR. `cleanup` is
    -- reached from four places and only two of them are messages from the
    -- server; the other two -- the match ending under a ride, and this sanity
    -- sweep -- are the client noticing on its own. A flag pushed from
    -- RESCUE_BEGIN/RESCUE_END would survive both, and the symptom is a player
    -- back on their feet with no HUD and no way to get one back.
    --
    -- The five stubs below are what `cleanup` touches on a ride that never
    -- finished being built: no camera, no vehicle and no driver were made, so
    -- those branches short-circuit on nil before they reach a native.
    _G.IsWaypointActive      = function() return false end
    _G.DetachEntity          = function() end
    _G.ClearPedTasks         = function() end
    _G.SetEntityVisible      = function() end
    _G.FreezeEntityPosition  = function() end
    _G.SetEntityCollision    = function() end

    BR.State.me.state = BR.PlayerState.ALIVE
    BR.Loop.step(BR.Loop.SLOW)
    frame(2)

    ok(#riding == 2 and riding[2] == false,
        'a ride torn down by the sanity sweep -- no RESCUE_END, no message at '
            .. 'all -- gives the HUD straight back, because the flag is polled '
            .. 'off `ride` rather than pushed from the two events',
        ('%d call(s), last=%s'):format(#riding, tostring(riding[#riding])))

    ok(BR.Rescue.riding() == false,
        'and the ride really is over, so a second sweep has nothing to do',
        tostring(BR.Rescue.riding()))

    BR.State.me.state = BR.PlayerState.DBNO
    frame(2)

    -- ═══════════════════════════════════════════════════════════════════════
    -- THE POSE IS PART OF THE OFFSET (owner, 2026-08-28)
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- "please enforce the ped emote in the ambulance as we discussed. It should
    -- be sunbathe"
    --
    -- WHAT MAKES THIS TESTABLE AT ALL is that it is a CONFIG fact with a
    -- cross-file agreement, not a judgement about a body. Whether the ped looks
    -- right on the stretcher is something only an eye in game can settle. What
    -- can be settled here is that the clip named in config is the one the
    -- offsets beside it were measured with, which is the property that makes
    -- those six numbers mean anything -- and it is exactly the agreement a
    -- later "tidy-up" breaks without noticing.

    local P = (R.stretcher or {}).pose or {}
    ok(P.dict == 'amb@world_human_sunbathe@male@back@base' and P.anim == 'base',
        'the stretcher carries the pose its offsets were measured against',
        ('%s / %s'):format(tostring(P.dict), tostring(P.anim)))

    local tuneFh = io.open('resources/[fivem-royale]/br_core/client/attachtune.lua')
    local tuneSrc = tuneFh and tuneFh:read('a') or ''
    if tuneFh then tuneFh:close() end
    ok(tuneSrc:find(P.dict or '\0', 1, true) ~= nil,
        'and it is a pose /brattach itself offers -- the tool the owner authored '
            .. 'the six numbers with, which is the whole reason they agree',
        #tuneSrc == 0 and 'attachtune.lua did not open' or 'not in its POSES')

    local resFh = io.open('resources/[fivem-royale]/br_core/client/rescue.lua')
    local resSrc = resFh and resFh:read('a') or ''
    if resFh then resFh:close() end

    -- THE TRAP THE CONFIG WARNS ABOUT, AS A GATE. A scenario is the obvious way
    -- to reach this pose and it is the wrong one: TaskStartScenarioInPlace is a
    -- TASK, it sites the ped against the ground, and it fights
    -- AttachEntityToEntity for the matrix -- so the body drifts off the offset
    -- with nothing to say it did. attachtune.lua rejected it for that reason
    -- before a single number was measured.
    ok(resSrc:find('TaskPlayAnim', 1, true) ~= nil
           and resSrc:find('TaskStartScenarioInPlace', 1, true) == nil,
        'the ride poses with TaskPlayAnim and never with a scenario -- a '
            .. 'scenario would quietly move the body off the measured offset')

    local posedBand = nil
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 'rescue.pose' then posedBand = s.band end
    end
    ok(posedBand == BR.Loop.TICK,
        'and the pose is RE-ASSERTED on a loop band rather than set once: '
            .. 'client/dbno.lua stops re-posing this ped for the whole ride, so '
            .. 'nothing else would put it back',
        tostring(posedBand))

    -- ═══════════════════════════════════════════════════════════════════════
    -- ...AND THE RULE ON THE OTHER SIDE OF THE BRIDGE
    -- ═══════════════════════════════════════════════════════════════════════
    --
    -- Text reads, on the same terms as the wording assertions above: this
    -- process cannot render App.tsx, and what it is guarding against is not a
    -- rendering fault but a SECOND MECHANISM growing. The owner asked for the
    -- HUD to be hidden "just like in the bus", and the value of that is entirely
    -- in there being one rule -- so the check is that the ride joins the bus's
    -- line, and that the card does not also learn to hide itself.
    local appFh = io.open('ui-src/src/App.tsx')
    local appSrc = appFh and appFh:read('a') or ''
    if appFh then appFh:close() end

    ok(appSrc:find('ridingBus', 1, true) ~= nil
           and appSrc:find('dbno.riding', 1, true) ~= nil,
        'App.tsx hides the HUD for the ambulance on the same `hudUp` line it '
            .. 'already hid it for the bus',
        #appSrc == 0 and 'App.tsx did not open' or 'the ride is not on that rule')

    local cardFh = io.open('ui-src/src/hud/DbnoOverlay.tsx')
    local cardSrc2 = cardFh and cardFh:read('a') or ''
    if cardFh then cardFh:close() end

    ok(cardSrc2:find('dbno.riding', 1, true) == nil,
        'and the card itself has no opinion about the ride -- the whole card '
            .. 'goes with the HUD, so a second test inside it would be half a '
            .. 'switch with its other half in another file')

    -- THE LOOP MUST STILL BE HEALTHY. A callback that throws five times running
    -- is suspended for the rest of the session -- which would present as
    -- exactly the symptom being fixed, and silently.
    for _, s in ipairs(BR.Loop.stats()) do
        if s.name == 'rescue.prompt' then
            ok(s.errors == 0 and not s.suspended,
                'and the prompt loop never threw -- a suspended callback is a '
                    .. 'prompt that stops appearing and says nothing',
                ('%d error(s), suspended=%s'):format(s.errors, tostring(s.suspended)))
        end
    end
end

print(('\n\27[32m%d passed\27[0m'):format(pass))
if fail > 0 then
    print(('\27[31m%d failed\27[0m'):format(fail))
    os.exit(1)
end
