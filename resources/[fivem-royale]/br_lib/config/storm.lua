-- Storm configuration.
--
-- Two decisions here are load-bearing and worth understanding before tuning:
--
-- 1. ANCHORS, NOT ONE MAP-WIDE CIRCLE. The Los Santos landmass spans roughly
--    8 km x 11.5 km. A single circle covering all of it needs a radius around
--    5800, which produces 11 km rotations that no battle royale pacing survives.
--    The anchor is a POI picked relative to THIS match's flight (see anchorBand
--    below): one random waypoint of the drawn tour, then one random POI inside
--    a distance band of it. Route-coupled, so the opening circle almost always
--    contains part of the path players actually dropped along; POI-anchored, so
--    it can never sit in the ocean and always centres somewhere nameable. With
--    192 tours x ~49 POIs the outcome never reads as a pattern.
--
-- 2. LATE ZONES MOSTLY SIT INSIDE THE RENDER CEILING. FiveM's default entity
--    culling radius is 424 units, and the natives that would widen it are
--    deprecated with known unfixable issues. Players beyond that distance are not
--    rendered and cannot be shot. A zone is drawn by AREA now and stretched up to
--    3:1 (#344), so what the ceiling is held against is its LONGEST LENGTH rather
--    than a diameter. MEASURED over 3,000 matches: phase 6 (r 110) is 294 m long
--    at the median and 448 m at worst, 0.4 percent of zones past 424; phase 7
--    (r 40) never more than 164 m. Phase 5 (r 260) is 700 m at the median and up
--    to 1028, where its circle was 520 m across and already past the ceiling. The
--    3:1 cap is one number for every phase; a lower cap on the late phases is the
--    lever if a phase-6 fight ever reads as broken.

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Storm = {
    -- How the match anchor is picked from the flight (BR.PickStormAnchor).
    -- A POI between min and max units of a random tour waypoint; if a waypoint
    -- has no POI in the band (a coastal or mountain leg), the band widens by
    -- widenStep until one appears, and the nearest POI is the last resort --
    -- an anchor must ALWAYS exist, a crash here would kill the warmup.
    anchorBand = {
        min       = 500.0,
        max       = 1500.0,
        widenStep = 500.0,
        widenMax  = 4000.0,
    },

    -- The opening zone COVERS THE WHOLE MAP: its radius is computed per match
    -- as the distance from the anchor to the farthest playable-bounds corner
    -- (plus a margin), and it is an exact DISC of that radius -- zone 0 is the
    -- one zone that is not drawn (#344) -- so nobody can land outside it: a far
    -- tour-end jumper starts inside like everyone else, and the first shrink
    -- sweeps the map inward toward the anchor. radius0 is the FLOOR on that
    -- computation, not the radius itself.
    radius0     = 3500.0,
    openMargin  = 200.0,
    -- How far off-centre the next zone may sit, as a fraction of the room it has
    -- on its drawn bearing -- how far it can go and still lie wholly inside the
    -- current zone, by real shape (BR.NextZoneCentre). 1.0 = anywhere the nesting
    -- rule allows -- 0.55 "wasn't moving far enough" (user call, 2026-08-04).
    edgeBiasMax = 1.0,

    -- The FINAL zones hug the edge: for the last edgeHugPhases phases the next
    -- zone is pushed out to within edgeHugM of as far as it can go on its bearing
    -- and still lie inside the current one (containment still wins at small
    -- radii, where the whole room is under 250 m anyway). Endgames resolve as a
    -- run to a place, not a shuffle in the middle.
    edgeHugM      = 250.0,
    edgeHugPhases = 2,

    -- BREAKOUT: the next circle is allowed to leave the current one.
    --
    -- Every circle used to be strictly contained by its predecessor, which is
    -- Fortnite's rule and is safe -- but it means a player sitting at the
    -- centre is never obliged to move, and can hold a building for the whole
    -- match on the hope of a favourable draw. The user has never seen the
    -- centre move outside the current circle, and wants that to be the NORM
    -- rather than the exception (2026-08-06): "this will force ALL players to
    -- move instead of allowing them to hide and hope for the best".
    --
    -- `overhang` is extra offset allowed beyond the nesting limit, as a
    -- fraction of the NEXT radius. The centre lands outside the current circle
    -- whenever the draw exceeds curRadius; at 1.8 the reachable maximum is
    -- curRadius + 0.8 * nextRadius, so that happens often and the two circles
    -- still overlap -- a long run, not a teleport.
    --
    -- THIS IS SAFE ONLY BECAUSE THE WALL SWEEPS. Damage is dealt by where the
    -- wall IS, and the wall travels from the old circle to the new one over
    -- the phase's shrink time, which is itself priced off the furthest
    -- player's run. Nobody is ever damaged for standing where they legally
    -- stood; they are given the sweep to leave.
    -- THE CHANCE RAMPS WITH THE PHASE, from nothing to almost always (user
    -- call, 2026-08-06: "the likelihood ... should increase from a baseline of
    -- 0 in the first phase", "85% chance at phase 8"). The opening circle is
    -- enormous and already holds most of the map -- moving it outside itself
    -- would ask players to cross the island before they have a gun. The late
    -- circles are small, everyone is armed, and a static circle is exactly
    -- where a passive player wins by having picked the right building.
    --
    -- Linear across the 8 phases: 0% at phase 1, 85% at phase 8.
    breakout = {
        chanceStart = 0.0,
        chanceEnd   = 0.85,

        -- THE CIRCLES MAY SEPARATE COMPLETELY, and this is how far apart
        -- (user call, 2026-08-06). The new circle can sit wholly outside the
        -- old one; the GAP between their edges is capped at this fraction of
        -- the predecessor's radius:
        --
        --     d_max = curRadius + nextRadius + gapMax * curRadius
        --
        -- Half a radius of clear ground between the two is a real rotation --
        -- everyone moves, nobody is already there -- without being a sprint
        -- across the county.
        gapMax      = 0.5,

        -- A breakout is only fair if the sweep gives players time to cross it,
        -- and the authored per-phase `shrink` is a CEILING on that time -- it
        -- was written for nested circles, where the furthest anyone can be
        -- from the next circle is one radius. A separated circle can be three
        -- times that, so a breakout phase is allowed a longer sweep. Without
        -- this the wall simply outruns everybody and the breakout stops being
        -- a rotation and becomes a cull.
        shrinkFactor = 2.5,

        -- A floor on the CURRENT radius, kept as a knob and off by default:
        -- the ramp already keeps the early phases still, and the user wants
        -- the endgame to move.
        minRadius   = 0.0,
    },

    -- ═══ A CONJOINED ZONE GROWS INTO ITS DESTINATION, IT DOES NOT POP (#344) ═══
    --
    --   "when the storm finishes moving and the next phase is opened, if they're
    --    conjoined, today the border pops suddenly to cover the whole area. instead
    --    it should grow over a period of 20s to include that new area instead of
    --    popping."                                     -- the owner, 2026-09-23
    --
    -- On a breakout whose destination OVERLAPS the zone the wall stands in, the safe
    -- zone grows from that zone to the two of them together across the first
    -- `seconds` of the hold -- wall, damage and HUD all at once, off one clock
    -- (BR.StormAt's eighth answer; BR.StormZone has the geometry). Never longer than
    -- the hold itself, so it is always over before the wall moves, and a dev time
    -- scale that shortens the hold shortens it too. A destination wholly apart from
    -- the zone still appears at once: the far island is fine as it is. 0 is the old
    -- pop.
    --
    -- THE MAP DOES NOT DRAW THE FRONT. It shows the zone the phase started in under
    -- the destination's own fill -- the ground the growth ends on -- because a
    -- moving front on the map would be the overlay rebuilt while it moves, which is
    -- the hitch 52a7caa removed (#350). Once the zone has grown, the union is the
    -- zone's fill for the rest of the hold, shown by alpha, never rebuilt.
    --
    -- MEASURED over 680 conjoined breakouts (200 matches, phases 2 to 7, every one
    -- forced to break out): the destination reaches 1.0 to 1.3 of its own radius
    -- outside the zone on average and 3.5 at worst, so across twenty seconds the front
    -- moves 81 m/s on average at phase 2 (163 at worst), 62 at phase 3, 31 at 4, 17 at
    -- 5, 7 at 6 and 2 at 7. It is exact -- not one of 5.2 million sampled points on the
    -- wrong side, and its distance from outside off by 1e-9 m at worst -- and it only
    -- ever grows. The wall's zone costs 0.17 ms a frame during a growth, against 0.08
    -- for the whole union, inset included.
    grow = {
        seconds = 20.0,
    },

    -- SHRINK TIME IS PRICED PER PHASE, like the hold: at each phase entry
    -- the furthest in-match player's run to the TARGET's wall sets the
    -- wall's travel time -- everyone already inside means the sweep takes
    -- only minSeconds and the game moves on (the "extra minutes for
    -- gameplay to really begin" complaint); a far straggler gets time to
    -- run. The authored per-phase shrink value is the CEILING. The run is
    -- read off the moving wall itself (#344), which a corner-to-corner morph
    -- can make longer than the distance: BR.StormSweepRun. A 3:1 zone is longer
    -- than its circle, so more sweeps reach the ceilings than before #344 --
    -- phase 3 68% against 54, phase 4 37 against 26 -- and there the furthest
    -- player is no longer covered; docs/match-math.md has the table.
    shrinkPace = {
        metersPerSec = 9.0,   -- same assumed cross-map speed as the hold
        minSeconds   = 40.0,  -- even an uncontested sweep takes this long
    },

    -- THE FREE-LOOT HOLD IS PRICED ON WHERE THE PLAYERS ARE AGAINST CIRCLE 1
    -- (#364). When the match goes live, phase 1's wait is the FURTHEST living
    -- player's distance to circle 1's wall at metersPerSec. Anyone inside its
    -- shape pays nothing, so a lobby that landed in it waits minSeconds, and a
    -- player who dropped at the wrong end of the tour buys time for the run in.
    -- server/storm.lua's BR.Storm.begin is the rule, and it measures against the
    -- same wall the cut below counts against. (Until #364 it measured from the
    -- match anchor.)
    --
    -- startCapSeconds bounds the WAIT: the wall starts moving within three
    -- minutes of PLAYING however wide the drop spread (user call, 2026-08-04),
    -- and what is left of a straggler's run is priced into phase 1's sweep.
    -- maxSeconds caps the priced hold before the start cap does, so while it
    -- sits above startCapSeconds it never binds.
    hold = {
        metersPerSec    = 9.0,   -- assumed cross-map travel speed
        minSeconds      = 60.0,  -- floor: everyone-in-the-circle matches
                                 -- still get ONE minute of free looting,
                                 -- not three (user call, 2026-08-04)
        maxSeconds      = 300.0, -- cap on the priced hold
        startCapSeconds = 180.0, -- cap on the stationary wait

        -- ═══ AND ONCE THE LOBBY IS IN, THE WAIT IS AT MOST 1:30 (#352) ═══
        --
        --   "When >=75% are within the circle, the time is 1:30 till the storm
        --    moves"                                       -- owner, 2026-09-22
        --
        -- The price above is set once, at go-live, by the furthest player. The
        -- first moment capInsidePct of the living players are inside circle 1's
        -- SHAPE, the rest of the hold is cut to capSeconds, and that is latched:
        -- it only ever shortens and never comes back. server/storm.lua's
        -- capFirstHold is the rule; a whole percent, like goLiveLandedPct.
        capInsidePct    = 75,
        capSeconds      = 90.0,
    },

    -- Playable bounds, describing the LAND we want fights to happen on.
    --
    -- The OPENING circle is deliberately allowed to overhang these bounds -- at
    -- radius 3500 most anchors spill onto coastline or ocean, and that is fine:
    -- at phase 0 nobody is forced anywhere, and every later phase clamps inward
    -- onto land. Anchors are checked in the test suite so the overhang stays
    -- bounded rather than accidental.
    --
    -- The phase's budget always beats these bounds. If clamping a zone into the
    -- AABB would push it out of the room the phase drew it in, NextZoneCentre
    -- walks it back instead -- a zone poking into the sea is cosmetic, a zone
    -- further out than the phase priced is a run nobody was given time for. (The
    -- room is wholly inside the current zone, or within the breakout's gap of it
    -- on the phases that roll one.) It is the next zone's EXACT bounding box that
    -- is held inside, not a circle's.
    mapAABB = {
        min = { x = -3600.0, y = -3600.0 },
        max = { x =  4500.0, y =  8000.0 },
    },

    -- radius:  target radius for this phase
    -- wait:    seconds the circle holds static (next circle already visible)
    -- shrink:  seconds spent interpolating to the new circle
    -- dps:     damage per second (DISPLAY units, 0..100 scale) outside the circle
    -- warn:    seconds before shrink starts that the UI raises a warning
    --
    -- Phase 1's wait IS the free-loot hold: the storm clock starts the moment
    -- the match goes live (last landing), the first circle is drawn on the map
    -- immediately, and the wall first moves 120 seconds later (user call,
    -- 2026-08-02: "PLAYING+120s because the map is so big"). Total is roughly
    -- 20 minutes. Tune from playtests, not from theory.
    -- DPS = 100 / kill-seconds. The authored kill times run 100s (phase 1)
    -- down to 15s (phase 8) -- the storm must never kill faster than 15
    -- seconds even at its angriest (user rule, 2026-08-04, superseding the
    -- earlier 10s floor with a gentler one). Damage lands every single
    -- second on the wire: all dps values are >= 1 display, so the whole-
    -- point carry never has to bank across ticks.
    phases = {
        -- The first shrink has been tuned in both directions from live
        -- feel: 150 read as scenery (2026-08-03, cut to 60), 60 read as a
        -- charge ("far too fast -- 50% the current speed", 2026-08-04,
        -- doubled back to 120).
        -- dps column reads as kill time: 100, 80, 60, 45, 35, 25, 20, 15s.
        -- PHASE 1'S SHRINK CEILING IS DELIBERATELY HUGE. The sweep is priced
        -- off the furthest player's run, floored at 40s and capped by this --
        -- and at 120s the cap was doing the deciding rather than the pricing:
        -- a player who dropped at the far end of the tour had 120s to cross
        -- ground that takes three or four minutes, and simply died to circle
        -- one (user, 2026-08-06: "kills me too many times when I'm furthest
        -- away... but when close by, the short timer is perfect").
        --
        -- Raising the ceiling does NOT slow down matches where everyone
        -- landed together: the pricing still returns ~40s when nobody is far.
        -- It only stops the cap from turning a long run into a death sentence.
        -- BOTH KNOBS, NOT ONE (user call, 2026-08-07). The first fix raised
        -- this ceiling from 120s to 360s so the sweep pricing could actually
        -- give a far-end jumper time to cross -- correct, but on its own it
        -- makes every spread-out match drag. Halving the damage instead means
        -- being caught by circle one costs a real bite out of your health
        -- rather than your life, so the pace can stay brisk.
        --
        -- 240s of sweep at 0.5 dps is 120 damage for someone who never moves,
        -- and a player who starts running the moment it closes takes a
        -- fraction of that. Later phases are untouched and still lethal.
        { radius = 2600.0, wait = 120, shrink = 240, dps = 0.5,  warn = 30 },
        { radius = 1600.0, wait = 120, shrink = 120, dps = 1.25, warn = 30 },
        { radius =  950.0, wait =  90, shrink =  90, dps = 1.7,  warn = 20 },
        { radius =  520.0, wait =  75, shrink =  75, dps = 2.2,  warn = 20 },
        { radius =  260.0, wait =  60, shrink =  60, dps = 2.9,  warn = 15 },
        { radius =  110.0, wait =  45, shrink =  50, dps = 4.0,  warn = 15 },
        { radius =   40.0, wait =  40, shrink =  40, dps = 5.0,  warn = 10 },
        { radius =    0.0, wait =  30, shrink =  60, dps = 6.7,  warn = 10 },
    },

    -- REAL WEATHER IN THE STORM, per client. GTA weather is only "global"
    -- when something syncs it -- a client-side override is purely local,
    -- which makes it a legitimate storm effect: caught outside the wall the
    -- sky goes full THUNDER (no gentle-rain tier -- user call, 2026-08-04),
    -- back inside it clears. The engine's overtime blend gives the build
    -- and fade; the NUI vignette fades on the same 5s clock.
    weather = {
        enabled  = true,
        blendSec = 5.0,    -- overtime blend, both directions
        holdMs   = 1000,   -- the state must persist this long before the
                           -- sky moves -- edge-straddlers must not strobe it
    },

    -- Does storm damage chew through shields first, or bypass them?
    -- false = bypass armour and hit health directly (PUBG behaviour).
    damageArmourFirst = false,

    -- ═══ HOW SQUARE THE ZONE IS, AND IT SHIPS AT ZERO (#335) ═══
    --
    --   "The storm border does draw still, and everything is circular. Can you make
    --    the storms squircles instead to prove our new logic?"   -- owner, 2026-09-22
    --
    -- 0 IS A CIRCLE AND IS NOT AN APPROXIMATION OF ONE. At zero the client asks
    -- storm_shape.lua for BR.StormShape.circle, exactly as it did before this knob
    -- existed, and the map gets the one radius descriptor that materialises into the
    -- identical BR.Native.radiusBlip call with the identical arguments.
    -- tools/test_storm.lua's `square.off` block asserts that against the record's own
    -- numbers rather than trusting it.
    --
    -- ABOVE ZERO THE ZONE IS A ROUNDED RECTANGLE of half-extent `r` in both axes
    -- with a corner radius of `r * (1 - squareness)`, so the dial runs from a circle
    -- to a square that CONTAINS it -- a 1.0 square is 4r^2 where the circle was
    -- pi*r^2, about 27 percent more ground. That is deliberate rather than
    -- overlooked: keeping the area equal would shrink the zone's reach in the axes,
    -- and where circles go and how big they are is #335's own "not in scope". Dial
    -- it and look at it; the number to change afterwards is this one.
    --
    -- WHAT IT REACHES IS THE MAP AND ONLY THE MAP. The two map rings and the #327
    -- preview ring are drawn from this, and nothing else is: the WALL and the DAMAGE
    -- TEST take their shape from the `shape` block below instead (#344). So a
    -- squareness above zero shows square rings over a wall that is neither square
    -- nor round. Left at zero, nothing in the game can tell this knob exists.
    squareness = 0.0,

    -- ═══ EVERY ZONE IS A RANDOM SHAPE, DRAWN BY AREA, AND THESE ARE ITS DIALS (#344) ═══
    --
    --   "we're only drawing squircles (quite well though), can we change to random
    --    shapes per phase? There should be a 90% chance of not being a circle, and
    --    when not a circle, there should be equal chances for each vertex to be
    --    rounded, beveled, or cornered."              -- the owner, 2026-09-23
    --   "the storm is still too circular. let's draw it by area now instead of any
    --    consideration for a radius."
    --   "We need more aspect ratio mix."              -- the owner, 2026-09-23
    --
    -- One zone in ten is a plain circle, and every other is the convex hull of its
    -- corner DISCS: a jittered polygon, stretched along a drawn axis up to 3:1, whose
    -- vertices each draw a finish -- a rounded vertex is one disc, a beveled one its
    -- chamfer's two points, a sharp one a point -- scaled to hold `area` of its phase
    -- circle exactly. Drawn from the match's storm seed and the ZONE's index, so the
    -- WALL and the DAMAGE BOUNDARY are both that shape and the hold/sweep timing is
    -- untouched. br_lib/shared/storm_shape.lua's blobUnit carries the geometry and
    -- BR.StormZone is the one place it is asked for.
    --
    -- ZONE 0, THE OPENING ZONE, IS THE MAP DISC on every seed: nobody can land
    -- outside it, and its wall is a clean ring just past the farthest map corner.
    --
    -- A ZONE KEEPS ITS SHAPE FOR ITS WHOLE LIFE: as one phase's target, and then as
    -- the next phase's starting zone until that sweep carries it away. The wall
    -- morphs CORNER TO CORNER across each sweep -- every corner of the zone it leaves
    -- travels to a corner of the zone it closes on, and the destination never moves
    -- or changes -- so it arrives on the target in the target's shape and nothing
    -- changes when the phase does.
    --
    -- ═══ EVERY ZONE FITS INSIDE THE ONE BEFORE IT, AND THE PLACEMENT LEANS ON IT ═══
    --
    -- Zone z is drawn to fit CONCENTRIC inside zone z-1 at the ratio of their phase
    -- radii, every disc at least `fitClear` of r inside -- turned, tamed down a
    -- stretch ladder, or last of all a copy of zone z-1's shape if it does not. That
    -- is what guarantees BR.NextZoneCentre room to place zone z WHOLLY inside zone
    -- z-1 on every phase that does not break out ("the circles still overlap when
    -- they are different shapes", the owner, 2026-09-23). SO RETUNING ONE PHASE'S
    -- RADIUS CAN RESHAPE EVERY LATER ZONE OF A MATCH: the chain is in the ratio.
    --
    -- MEASURED AT THIS CONFIG over 21,000 zones -- 3,000 matches, zones one to seven,
    -- chained exactly as BR.StormUnit builds them (tools/test_shared.lua's
    -- `blob.measure` re-measures a smaller sweep of it rather than trusting this
    -- note). Area is 0.900 of the circle on every draw, exactly, because it is scaled
    -- to be:
    --
    --     longest / narrowest   under 1.5   1.5-2   2-2.5   2.5 and over
    --     share of zones          30.4%     25.7%   23.3%      20.6%
    --     median 1.88, and never past 3.000
    --
    --     zone   circles   stretch tamed   turned to fit   zone before's shape
    --      2      6.5%        17.0%           54.7%              3.2%
    --      3      8.3%        10.4%           54.2%              1.3%
    --      4      9.4%         4.6%           42.8%              0.1%
    --      5      8.3%         1.2%           32.3%              0.03%
    --
    -- Corners: three to six at 12.8 to 13.2 percent of zones each, seven to twelve at
    -- 6.3 to 6.8 each, circles 9.0; vertices 33.2% rounded, 33.4% beveled, 33.3%
    -- cornered. The centre is at least 0.41 of r deep in every zone; the furthest any
    -- corner reaches is 1.40 r on average and 2.64 r at worst.
    --
    -- ═══ WHAT IT COSTS, SAID HERE RATHER THAN LEFT TO BE DISCOVERED ═══
    --
    --   NESTED ZONES MOVE ABOUT HALF AS FAR. A long zone fitted inside another long
    --   zone by its real outline has less room than a circle had inside a circle:
    --   measured over 1,000 matches, the mean offset of a nested phase is 0.13 to
    --   0.27 of the current radius at phases 2 to 7, against 0.25 to 0.40 in the
    --   circle era. `fitClear` buys some of that back; raising it buys more, at the
    --   price of more zones becoming copies of the zone before.
    --
    --   CIRCLES DIP IN THE MIDDLE PHASES, to 6.5 percent at zone 2, because a round
    --   zone of the right area does not fit inside a long one and is drawn as a
    --   polygon instead.
    --
    --   LONG ZONES ARE LONGER THAN THE OLD DIAMETERS -- see point 2 at the top.
    --
    --   THE MAP'S MORPH IS A CROSSFADE. The map may not re-draw a polygon while the
    --   storm moves (#350, 52a7caa), so it shows the wall's morph by placing and fading
    --   shapes it drew while the storm stood still -- exact at both ends of a sweep,
    --   a blend of them in between (`overlay.keyframes` below has the numbers).
    --
    --   A UNIT COSTS ABOUT TWO MILLISECONDS TO BUILD -- 1.7 on average, 5 at the
    --   99th percentile, in plain Lua 5.4 -- and is built once per zone per match: the
    --   client builds every zone of a match ahead of need, one a tick, from the moment
    --   the warmup preview publishes the seed (client/storm.lua's storm.units).
    --
    -- PHASE 8 IS RADIUS 0 AND STAYS A POINT, as it always has: a shape with no
    -- radius is not a shape, and a point is not a circle.
    shape = {
        -- ONE ZONE IN TEN IS A PLAIN CIRCLE -- the owner's "90% chance of not being a
        -- circle". Drawn FIRST off the zone's own stream and every other value read
        -- after it whatever it decided, so retuning this changes which zones are
        -- circles and never what the others look like. A circle holds `area` like
        -- every other shape, so it plays the size they do. One that cannot fit inside
        -- the zone before it is drawn as a polygon instead.
        circle      = 0.10,

        -- HOW MANY CORNERS, DRAWN PER ZONE, and these are the odds.
        --
        --   "We're able to reliably draw squircle storms, but what about random
        --    other shapes of various vertices?"          -- the owner, 2026-09-23
        --   "triangles and squares are okay with me"     -- the owner, 2026-09-23
        --
        -- Each zone rolls its count off the match's storm seed, so a match runs
        -- through several polygons and the next match through different ones. The
        -- weights are relative: 2 is twice as likely as 1, and a count left out is
        -- never drawn.
        --
        -- THREE TO TWELVE, AND THE LOW END COUNTS DOUBLE, so four polygons in seven are
        -- a triangle, a square, a pentagon or a hexagon -- the counts that read as a
        -- named shape from above. Three and four were out while every zone had to stay
        -- inside 1.15 of r; a zone is drawn by area and placed by its real outline now,
        -- so nothing bounds how far a corner reaches, and they are back.
        --
        -- A NUMBER HERE IS ONE COUNT ON EVERY ZONE, which is how #344 shipped (9).
        -- BELOW 3 IS NOT A POLYGON AND IS THE WAY BACK TO CIRCLES -- the whole game
        -- draws exactly what it drew before #344. That is a deliberate edit and not
        -- a default: #335 shipped its shape behind a knob at zero and nothing in the
        -- game ever drew it, which is the mistake this block is not repeating.
        corners     = {
            [3] = 2, [4] = 2, [5] = 2, [6] = 2,
            [7] = 1, [8] = 1, [9] = 1, [10] = 1, [11] = 1, [12] = 1,
        },

        -- WHAT EACH VERTEX IS, and the odds -- equal, which is the owner's rule.
        -- `rounded` is an arc tangent to both edges, `beveled` the corner cut off by a
        -- chamfer, `cornered` the sharp point. Relative weights like `corners`; a
        -- finish weighted at zero is never drawn.
        vertex      = { rounded = 1, beveled = 1, cornered = 1 },

        -- HOW FAR EACH CORNER'S RADIUS WANDERS, as a fraction of the ring's, SYMMETRICALLY
        -- about it -- so 1 + j * U(-1, 1) and not 1 - 2j * U(0, 1). Inward-only jitter
        -- costs 28 to 41 percent of the circle's area, measured.
        --
        -- Higher is lumpier and more often concave, and a concave draw is redrawn;
        -- lower reads more regular. Most of the variety is in `stretch` now.
        jitter      = 0.13,

        -- HOW FAR A CORNER MAY SLIDE AROUND THE RING, in degrees, either way.
        --
        -- DEGREES AND NOT A FRACTION OF THE SLOT, because the slot is not one size:
        -- #344's 0.3 of a slot was 12 degrees at nine corners and 36 at three, which
        -- put the storm's own centre outside the shape on one draw in twenty-two. Nine
        -- degrees is exactly 0.3 of a twelve-corner slot, and storm_shape.lua caps the
        -- slide there on any count whatever is typed here. Higher is a less regular
        -- polygon and more often redrawn.
        slideDeg    = 9,

        -- HOW MUCH OF A CORNER A ROUNDED OR BEVELED VERTEX TAKES, as a fraction of the
        -- shorter half-edge beside it. The arc and the chamfer start the same distance
        -- back along both edges, so the same vertex rounded or beveled differs only by
        -- the bulge of the arc. 1.0 would leave two neighbours meeting in the middle
        -- of their shared edge; 0.5 keeps at least half of every edge straight.
        --
        -- 0.5 AND NOT THE 0.85 THE ROUNDED CORNERS USED: at 0.85 a beveled corner eats
        -- so much of both edges that the chamfer reads as a side of its own. Raise it
        -- for softer corners. A rounded corner's disc is also held inside the polygon
        -- (storm_shape.lua's RHO_FIT), so a near-flat vertex cannot grow a disc that
        -- reaches past the far side of the shape.
        cut         = 0.5,

        -- HOW BIG EVERY SHAPE IS, as a fraction of its phase circle's AREA. Every draw
        -- is scaled to exactly this, so a triangle zone plays the size a twelve-sided
        -- one does, and a long one the size a round one does. 0.90 is what #344's nine
        -- corners measured, and it is what the pacing was tuned on -- the shape is
        -- free, the ground it covers is not.
        area        = 0.90,

        -- HOW STRETCHED A ZONE MAY BE: its longest length over its narrowest width, at
        -- most. The owner's 3:1 -- "3:1 is okay, but I'm assuming this is a maximum".
        -- Measured exactly, off the zone's width in every direction.
        stretch     = 3.0,

        -- HOW THE STRETCH IS DRAWN, up to that maximum. 'uniform' draws the target
        -- evenly across [1, stretch], so a long zone is as common as a round one --
        -- "we need more aspect ratio mix" -- and the shipping mix is the table above.
        -- 'sqrt' leans toward the long end. The zone is stretched as close to the
        -- target as its corners allow and never past it.
        stretchDraw = 'uniform',

        -- HOW MUCH ROOM A ZONE LEAVES INSIDE THE ONE BEFORE IT, as a fraction of r:
        -- every disc of zone z at least this far inside zone z-1 when the two are
        -- concentric at the ratio of their radii. 0 would let a zone fit its
        -- predecessor exactly and leave the next placement no room to move. MEASURED:
        -- at 0.04 the placement's room on a random bearing is 17 to 22 percent wider
        -- than at 0 at phases 2 and 3, and 1 to 15 percent later; the price is that
        -- 3.2 percent of zone 2s become a copy of zone 1's shape, against 0.7 at 0.
        fitClear    = 0.04,
    },

    -- Rendering. A single giant sphere is not an option: marker type 28 is
    -- literally MarkerTypeDebugSphere, markers have no distance parameter, and
    -- huge scale values produce broken geometry with no depth sorting.
    --
    -- ═══ THE WALL IS A QUAD STRIP. THE MARKERS ARE THE A/B BASELINE (#336) ═══
    --
    -- Two marker renderers shipped before this and both are still reachable
    -- behind /brwallstyle, but neither is the wall any more:
    --
    --   'solid'    ONE type-1 cylinder whose side surface is the whole curtain.
    --              Seamless, and a circle by construction, so it cannot draw the
    --              union of two discs the safe zone became in #328.
    --   'columns'  the same cylinder walked along the boundary in slotArc slots.
    --              Draws any shape and STRIPES, which is what #336 is about.
    --
    -- The striping was never a tuning failure. A translucent cylinder seen from
    -- outside is brightest at its silhouette edges, where the line of sight
    -- passes through the most surface, and dimmest through the middle -- so every
    -- column contributes two bright vertical lines, and eighty in a row are a
    -- picket fence ("a bunch of circles which are the wrong height", the owner,
    -- 2026-09-22). The `overlap` note below records the other half of it: widen
    -- the columns until they meet and the doubled alpha where they cross bands the
    -- wall dark instead. There is no value between the two, because two
    -- overlapping translucent tubes are not one surface.
    --
    -- So the shipping renderer is 'strip': the boundary as one continuous quad
    -- strip, two DRAW_POLY triangles per pair of walk points. Everything from
    -- `segments` down to `fallbackZDrop` belongs to the two marker paths and is
    -- left exactly as it was, so the A/B compares like with like.
    render = {
        segments       = 48,     -- MINIMUM columns drawn (and the floor on slot count)
        maxDraw        = 80,     -- ceiling on columns per frame, near or far
        -- The wall stands on FIXED angular slots, one column per slotArc
        -- metres of circumference -- world-anchored, so columns do not slide
        -- along the wall as the player moves (they used to ride the player's
        -- bearing, which read as the whole colonnade rotating).
        slotArc        = 30.0,
        -- How far ALONG the wall to populate slots, in metres of arc either
        -- side of the player's nearest point; widened automatically with
        -- distance so the wall spans the view from far away too. There is NO
        -- proximity cut-off any more -- the old one made the curtain pop out
        -- of existence past 300m.
        wallVisDist    = 700.0,
        height         = 300.0,  -- scaleZ, tall enough to span the visible vertical band
        colour         = { r = 150, g = 70, b = 255 },
        -- THE WALL'S ALPHA AT ITS BASE, of 255 -- the fade below multiplies it down to
        -- nothing at the top, so this is how solid the curtain reads at a player's feet.
        --
        --   "decrease the transparency at the bottom of the storm, or make it more
        --    opaque in other words"                        -- the owner, 2026-09-23
        --
        -- 165, about 65% opaque, from 110, about 43%. The owner gave the direction and
        -- not the number: 165 is a pick to look at, and this is the one to turn. It is
        -- the wall's alone -- the map's fills read the blip alphas.
        alpha          = 165,
        -- Neighbouring cylinders should MEET, barely: heavy overlap doubles
        -- the additive alpha where they cross and renders as dark vertical
        -- banding -- the "stripes" of the first in-game wall.
        overlap        = 1.05,
        -- The marker's translucent surface reads a few metres FATTER than
        -- its logical radius, so the visual wall is drawn slightly inside
        -- the real edge: standing at the curtain is always genuinely safe.
        -- (Live report: "20ft inside" while the HUD correctly said outside.)
        edgeInset      = 6.0,
        -- The wall FADES IN across the last N seconds of the phase-1 hold,
        -- instead of popping into existence when the shrink starts.
        fadeInSec      = 10.0,
        -- The PREVIEW wall's share of `alpha` -- circle 1 drawn during the bus
        -- ride, before any storm exists (#327). The same renderer, the same
        -- colour, deliberately fainter: it marks a place the storm is going to
        -- be, and it must not read as a wall that is already doing something.
        -- Half is the starting point and the number most likely to move after a
        -- playtest from actual bus altitude.
        previewAlpha   = 0.5,
        groundCacheSec = 1.0,    -- GetGroundZFor_3dCoord is slow; sample once per second
        fallbackZDrop  = 150.0,  -- if ground Z is unavailable, anchor below the camera

        -- ═══ THE QUAD STRIP, WHICH IS THE WALL (#336) ═══
        --
        -- A strip picks its own bottom and top instead of inheriting a cylinder's
        -- scale, and that is half of what the owner reported: the columns stood
        -- `height * 3 + 50` metres tall from a base of -100, so their tops were at
        -- world z 850 and the wall reached into the sky over a city whose ground
        -- is around 30.
        strip = {
            -- THE BOTTOM, AND IT IS FIXED ON PURPOSE.
            --
            -- A strip's bottom edge is a hard line, so any ground that pokes above
            -- it shows as a lit band of terrain THROUGH the wall -- a gap under the
            -- curtain on every slope. The obvious fix is a ground probe per point,
            -- and that is exactly what was removed: GetGroundZFor_3dCoord returns
            -- garbage for unloaded cells, which at wall distances is most of the
            -- time, so the fallback (the viewer's own z) is what actually ran and
            -- the wall rode the camera. One probe per boundary point per frame is
            -- not affordable either.
            --
            -- So the bottom goes under everything instead. The lowest ground this
            -- config admits anywhere is 2.0 (the map's own POI table, 120 places
            -- with an authored z), and 'solid' has stood on -100 since 2026-08-03
            -- with no gap ever reported. 150 metres below sea level keeps that and
            -- adds margin for the sea bed, and the extra quad area costs nothing
            -- because it is underground.
            baseZ    = -150.0,

            -- THE TOP, AND THE FADE IS WHAT PAYS FOR IT.
            --
            --   "are you able to make the wall fade bottom to top like the
            --    3dmarker? if so, just make it the same height as the marker
            --    was."                              -- the owner, 2026-09-22
            --
            -- 850 IS THE MARKER'S OWN TOP, read off the call rather than guessed:
            -- client/storm.lua's cylinder stands at z -100 with a scaleZ of
            -- `render.height * 3 + 50`, and render.height is 300, so it is 950
            -- metres tall and tops out at world z 850. This is that number.
            --
            -- A fixed top used to be a trade with no right answer -- it cannot both
            -- stay off the sky over a city whose ground is around 30 and still be
            -- above a player on Mount Chiliad at 780 -- and 400 was where that
            -- trade was opened. THE FADE DISSOLVES IT: the top of the wall is drawn
            -- at `fade.topAlpha`, which is nothing at all, so the height that used
            -- to tower is the height that is invisible. Chiliad's summit is inside
            -- the wall again and the city sees a curtain that thins out above the
            -- rooftops.
            --
            -- THE PREVIEW USES THIS SAME NUMBER, deliberately, and that is the
            -- other thing the fade bought. The #327 bus preview asked for the
            -- cylinder because the bus cruises at 500 and climbs to 892 over the
            -- Chiliad massif (config/map.lua), and a wall topping out at 400 was
            -- entirely below the only viewpoint it is ever seen from. At 850 the
            -- flight passes THROUGH the fade instead of over a band on the ground,
            -- so the preview needs no height of its own -- one wall, one height,
            -- two alphas.
            --
            -- Yours to dial between playtests, as it always was. Lower it if the
            -- wall still reads as a tower from the city; raise it if the northern
            -- high ground looks like it has no wall at all.
            topZ     = 850.0,

            -- HOW ROUND THE STRIP HAS TO BE, in metres of chord sag: the most a
            -- flat quad is allowed to cut the corner off the arc it replaces.
            --
            -- THIS IS WHY THE STRIP DRAWS THE WHOLE BOUNDARY WHERE THE COLUMNS
            -- COULD NOT. A column has to be about as wide as its spacing or the
            -- colonnade gaps, so slotArc pins the count and maxDraw then rations
            -- it -- 15 percent of the ring at phase 1, a curtain stopping in
            -- mid-air. A quad SHARES both of its vertical edges with its
            -- neighbours, so it may be as long as roundness allows and the surface
            -- is still continuous. Sag goes as ds^2 / 8r, so the step is
            -- sqrt(8 * r * chordM) and a 2600m circle closes in about 80 quads at
            -- two metres of sag, which nobody can see from inside it.
            chordM   = 2.0,

            -- The floor on quads per closed loop, for the endgame circles where
            -- the sag rule would happily draw a 40m ring as an octagon.
            minSeg   = 24,

            -- THE CEILING ON POLYS PER FRAME, ALL LOOPS TOGETHER, and it is a hard
            -- one: the per-loop count is the budget divided by the number of loops
            -- AND BY WHAT A QUAD COSTS, before roundness is even consulted, so no
            -- shape can talk its way past it. Where the real per-frame ceiling sits
            -- is a resmon question, not a derivation.
            --
            -- ═══ 1024 RATHER THAN 256, AND IT IS NOW THE NUMBER THAT CLOSES #337 ═══
            --
            -- A BANDED QUAD IS `fade.bands` QUADS, so it costs 2 * bands polys and
            -- not 2. At 256 the banded wall would have been rationed to 21 quads a
            -- loop, which is a 2600m ring drawn as a 21-gon: the budget would have
            -- been deciding the SHAPE of the wall rather than capping its cost.
            --
            -- AND 256 WAS ALREADY BINDING BEFORE THE FADE EXISTED, which is worth
            -- knowing on its own. Measured at the shipping radii: a Venn or disjoint
            -- 2600 + 1600 wants 166 quads for two metres of sag and got 127, so the
            -- worst sag on those shapes was 5.09 m against a chordM of 2.0 -- the
            -- roundness rule quietly overruled on the two widest shapes in the game.
            -- The suite never saw it because its sag block drives nested circles,
            -- which are the shapes the ceiling never reached.
            --
            -- ═══ LEAVE IT HERE. RAISING IT IS NOT THE SMOOTHNESS KNOB, AND LOWERING
            ---    IT PUTS THE WALL BACK INSIDE THE BOUNDARY ═══
            --
            -- The shipping path is the GRADIENT, which is 2 polys per quad flat --
            -- the ramp lives in a texture, so smoothness costs no triangles at all.
            -- Measured through this renderer: the widest shape in the game wants 332
            -- polys against this 1024, every shape stays inside chordM, and NOTHING
            -- IS RATIONED ANYWHERE. That is what closes #337's silent chordM override
            -- as a side effect rather than as a fix: there is no longer a shape the
            -- budget reaches.
            --
            -- SO THERE IS NOTHING TO BUY BY RAISING IT, and the banded fallback is
            -- the reason not to lower it OR to raise `fade.bands`. Measured through
            -- the renderer on the widest shape in the game, a fully separated
            -- 2600 + 1600 breakout -- worst sag, and how far inside the damaging
            -- boundary that puts the curtain once edgeInset is added:
            --
            --     3 bands   148 quads   888 polys    1.98 m sag    7.98 m inside
            --     6 bands    84 quads  1008 polys    7.25 m sag   13.25 m inside
            --     8 bands    64 quads  1024 polys   12.49 m sag   18.49 m inside
            --    12 bands    42 quads  1008 polys   28.97 m sag   34.97 m inside
            --    16 bands    32 quads  1024 polys   49.84 m sag   55.84 m inside
            --
            -- At 16 the 2600m ring is a 32-gon and the wall stands 56 metres inside
            -- the edge that damages -- the live "20ft inside" complaint again, nine
            -- times over, on a curtain that says it is safe to stand at it. The band
            -- count is capped by GEOMETRY, not by frame rate, and this is where that
            -- cap is written down. Past 3 the budget starts trimming quads rather
            -- than the fade getting smoother.
            --
            -- Measured polys per frame, gradient / 3 bands: phase 1 nested 162 / 486,
            -- phase 2 nested 126 / 378, phase 3 nested 98 / 294, phase 4 nested
            -- 72 / 216, phase 5 nested 52 / 156, phase 8 point 48 / 144, the widest
            -- Venn 332 / 888.
            maxPolys = 1024,

            -- ═══ THE FADE, WHICH IS WHAT LETS THE WALL BE AS TALL AS THE MARKER ═══
            --
            --   "are you able to make the wall fade bottom to top like the
            --    3dmarker? if so, just make it the same height as the marker was."
            --   "go with the fallback if no stock texture works. but give me a way
            --    to know whether it fellback."          -- the owner, 2026-09-22
            --   the 3-band wall "reads as three visible steps"
            --                                           -- the owner, playtested
            --
            -- TWO PATHS, AND THE DEFAULT IS NOW THE SMOOTH ONE.
            --
            --   'gradient'  ONE quad, two `DRAW_SPRITE_POLY` triangles, textured with
            --               an alpha ramp baked into a RUNTIME texture at boot. The
            --               gradient comes out of the texture's own 256 alpha levels,
            --               so it is smooth by construction and costs 2 polys a quad
            --               -- the same as a wall with no fade at all.
            --   'bands'     stacked plain DRAW_POLY quads, each flat at its own
            --               alpha. Cannot fail, costs `bands` times the polys, and
            --               SHOWS STEPS -- which is the defect the owner playtested,
            --               so it is a fallback and not a plan.
            --
            -- ═══ WHAT THE PREVIOUS VERSION OF THIS BLOCK GOT WRONG, BECAUSE THE
            ---     DEAD END IS EASY TO RE-DERIVE ═══
            --
            -- It said the gradient was impossible here, and the two facts it rested
            -- on were both TRUE: there is no stock flat-white texture in the game
            -- (every resource that draws textured polys streams its own .ytd or
            -- points the native at a DUI), and this estate ships no streamed assets.
            --
            -- WHAT IT MISSED IS THAT A TEXTURE DOES NOT HAVE TO BE STREAMED. FiveM
            -- makes one at RUNTIME -- CREATE_RUNTIME_TXD, CREATE_RUNTIME_TEXTURE,
            -- SET_RUNTIME_TEXTURE_PIXEL, COMMIT_RUNTIME_TEXTURE -- with no .ytd, no
            -- stream folder, no manifest entry and no RequestStreamedTextureDict. The
            -- no-streamed-assets rule is untouched by it. And the proof was already
            -- in this repo the whole time: br_core/client/dui.lua builds a runtime
            -- texture from a CEF surface and feeds it straight to DrawSpritePoly as
            -- world-space quads, and has been doing so in production for months. It
            -- greps zero for RequestStreamedTextureDict.
            --
            -- So the previous note's error was not either fact. It was concluding
            -- that "no stock texture" plus "we stream nothing" closed the question,
            -- when the third option -- make the texture ourselves, in memory -- was
            -- shipping one directory away. Do not re-derive the dead end.
            --
            -- ═══ AND THE NATIVE CHANGED WITH IT ═══
            --
            -- The gradient used to be spelled `_DRAW_SPRITE_POLY_2`, which takes an
            -- alpha PER VERTEX and has no working call site anywhere in public code.
            -- It is gone. Baking the ramp into the texture means the ordinary
            -- single-colour `DRAW_SPRITE_POLY` is enough -- the native dui.lua has
            -- been shipping since #236 -- so the one unproven thing in the design is
            -- no longer in it. Per-vertex alpha could only express a straight line
            -- anyway; a texture can hold any curve, which is what pays for the kink
            -- at ground level below.
            --
            -- READ THE LINE THE WALL PRINTS on its first frame; /brwallstyle reports
            -- the same thing at any time, and it now names whether the runtime ramp
            -- was actually built and why not if it was not.
            fade = {
                prefer     = 'gradient',

                -- HOW MANY STACKED QUADS THE **FALLBACK** USES, and it is not the
                -- smoothness dial any more -- the gradient is smooth for free, and
                -- this number is only reached when the runtime texture could not be
                -- built at all.
                --
                -- DO NOT RAISE IT. Each band multiplies the wall's poly count, and
                -- maxPolys then rations QUADS to pay for them: measured, 16 bands
                -- draws the widest shape as a 32-gon whose chords stand 55.84 m
                -- inside the damaging boundary. That is the "20ft inside" complaint
                -- again, nine times over, traded for smoothness on the path that is
                -- supposed to be the ugly one. The table beside maxPolys has every
                -- band count measured.
                bands      = 3,

                -- THE RAMP, AS TWO MULTIPLIERS ON render.alpha: full strength at the
                -- bottom, nothing at the top. Raise topAlpha if the wall looks
                -- decapitated from the ground; lower baseAlpha if the base reads as a
                -- solid block.
                baseAlpha  = 1.0,
                topAlpha   = 0.0,

                -- ═══ WHERE THE RAMP STARTS, AND IT IS THE GROUND, NOT baseZ ═══
                --
                -- The geometry's bottom is strip.baseZ, which is -150 so that no gap
                -- can open under the curtain on a slope. The RAMP must not start
                -- there. The lowest ground this config admits anywhere is 2.0, so a
                -- ramp measured from baseZ spends its first 15 percent underground
                -- where nobody can see it -- and the wall at a player's FEET then
                -- draws at 85 percent of render.alpha rather than at render.alpha.
                -- Measured on the 3-band fallback before this existed: alpha 92 where
                -- the config says 110.
                --
                -- So alpha is held FLAT at baseAlpha from baseZ up to here, and only
                -- then ramps to topAlpha at topZ. The underground skirt stays, the
                -- ramp gets the whole visible wall, and the curtain is full strength
                -- at eye level. This is the kink a per-vertex alpha could not express
                -- and a baked texture holds for nothing.
                --
                -- Raise it to keep the wall solid to rooftop height before it starts
                -- to thin; it cannot go below baseZ and is clamped there if it does.
                rampBaseZ  = 0.0,

                -- THE RUNTIME TEXTURE. These are names, not assets: nothing is
                -- streamed and no file exists. br_core/client/storm.lua creates the
                -- dictionary, bakes rampH rows of alpha into the texture and commits
                -- it once, then gates the gradient path on reading the width back.
                --
                -- 8 WIDE RATHER THAN 1 so the u axis is not degenerate -- the draw
                -- samples u 0.5, which is the middle of eight identical columns, so
                -- no edge filtering or clamp rule can enter into it. 256 TALL is one
                -- row per alpha level, which is every level the format has.
                --
                -- THE v AXIS CARRIES INFORMATION AND SO CANNOT BE PINNED LIKE u, which
                -- is why it took a defect to protect. The draw runs v from the centre
                -- of row 0 to the centre of row rampH-1 -- half a texel in at each end
                -- -- instead of 0.0 to 1.0: an edge coordinate of exactly 1.0 filters
                -- across the wrap boundary and a REPEAT sampler reads the opaque
                -- bottom row there, which is the thin bright line #341 reported along
                -- the top of the wall. Changing rampH moves the inset with it; the
                -- client computes it from the height it actually built.
                txd        = 'br_storm_ramp',
                texture    = 'ramp',
                rampW      = 8,
                rampH      = 256,

                -- ═══ HOW MANY NAMES THE RAMP MAY PROBE BEFORE IT GIVES UP ═══
                --
                -- RUNTIME TEXTURES CANNOT BE DESTROYED -- there is no counterpart to
                -- CREATE_RUNTIME_TEXTURE -- so every br_core restart in one client
                -- session strands the texture the previous start made and has to take
                -- a fresh name. The client tries the plain name, then `_2`, `_3`, and
                -- so on, and both the dictionary and the texture name carry the
                -- suffix: FiveM refuses at the DICTIONARY level (see the note in
                -- client/storm.lua), so moving only the texture name retries into the
                -- same refusal.
                --
                -- THIS WAS ONE RETRY AND THAT WAS TOO FEW. The third restart of a
                -- session landed on the banded wall, which inside a playtest loop
                -- reads as the fade having regressed rather than as a slot collision.
                --
                -- THE BOUND IS THE POINT OF THE NUMBER. A client whose
                -- runtime-texture support is broken refuses every name, and an
                -- unbounded probe would spin rather than fall back to bands. 32 costs
                -- at most 256 KiB of stranded texture (8 x 256 x 4 bytes is 8 KiB a
                -- restart) before the fallback, which is more restarts than any
                -- playtest performs and still well clear of the client's own ceiling
                -- on live runtime textures. Failed probes are nearly free -- the
                -- refusal happens before a texture is allocated.
                --
                -- Read the attempt number off the line the wall prints, or
                -- /brwallstyle: "attempt 5 of 32" means br_core has started five
                -- times this session.
                nameTries  = 32,
            },
        },
    },

    -- Screen treatment while outside the circle. postFX pack names are the most
    -- likely thing in this config to be wrong on a given build, so the storm stays
    -- fully readable from the timecycle and the NUI vignette alone -- a missing
    -- postFX name is cosmetic, not gameplay-breaking. Audition names with /brfx.
    fx = {
        timecycle       = 'REDMIST',
        timecycleTarget = 0.7,
        timecycleRampMs = 1500,
        postFx          = 'DeathFailOut',
        useTimecycle    = true,
        usePostFx       = false,  -- opt in once a name is confirmed in-game
    },

    -- Minimap. Radius blips cannot be resized in place; they must be removed and
    -- re-added, so we refresh at a rate that reads as smooth without churning.
    blip = {
        refreshHzShrinking = 4,
        refreshHzHolding   = 0.5,
        currentColour      = 3,    -- blue
        nextColour         = 27,   -- purple
        currentAlpha       = 80,
        nextAlpha          = 110,
    },

    -- ═══ THE REAL SHAPE ON BOTH MAPS, AS A FILLED POLYGON (#350) ═══
    --
    --   "seems every storm is still a circle."             -- owner, 2026-09-22
    --
    -- The wall has been a blob since #344 and the map was still drawing the circle
    -- it replaced -- which is the only place the shape is visible at an early phase,
    -- because at phase 1 the nine corners are 1815 m apart along the boundary and a
    -- player on the ground sees a few hundred metres of it.
    --
    -- ScaleformUI_Assets' MINIMAP_LOADER.gfx fills an arbitrary polygon through
    -- ADD_AREA_OVERLAY, on the radar and on the pause map both, and #347 spiked it
    -- and looked at it. So the two rings are filled polygons of the real boundary
    -- when the overlay is available, and the radius blips above when it is not --
    -- the fallback is not optional, because the overlay sits behind a readiness gate
    -- that can refuse (client/mapoverlay.lua, and the #4167 crash #348 is about).
    --
    -- THE COLOUR IS render.colour, THE WALL'S OWN PURPLE, AND THAT IS ONE VISIBLE
    -- CHANGE. The overlay takes an RGB and a blip takes a palette index, and there
    -- is no bridge between them -- `currentColour = 3` is GTA's blip blue and
    -- nothing on this path can ask the engine what that is in RGB. So both fills are
    -- the storm's purple at the two alphas above, which is the layering the two
    -- rings already had (faint safe zone, stronger target) in one hue instead of
    -- two. If the blue is wanted back it is one RGB in this block.
    overlay = {
        enabled   = true,
        -- Metres of sag allowed between the drawn polygon and the real boundary.
        --
        -- EIGHT IS ABOUT A PIXEL ON THE PAUSE MAP, where the whole 8 km landmass
        -- spans a few hundred pixels. MEASURED at the shipping shape config: a
        -- phase-1 blob closes in 35 points and 577 characters at 8 m, 59 points and
        -- 973 at 2 m, 28 points and 459 at 20 m. Worth a playtest on the RADAR,
        -- which is zoomed in far enough for 8 m to be several pixels -- though at
        -- phase 1 the boundary between two corners is very nearly straight anyway.
        chordM    = 8.0,
        -- Hard ceiling on points per contour, and it is a ceiling on the STRING.
        --
        -- The Scaleform string-parameter cap is UNMEASURED -- there is no documented
        -- limit, which is not the same as there being none. The spike's coordinates
        -- were about 70 characters and a real boundary is several hundred to over a
        -- thousand, so IF A SHAPE EVER DRAWS GARBLED RATHER THAN ABSENT, this is the
        -- number to lower: it is the only lever on the length. 96 is headroom over
        -- what chordM actually asks for (35 to 69 points at the shipping phases), so
        -- today it never bites. BR.MapOverlay.report().chars is where to read the
        -- length that actually went out, and client/storm.lua prints it once.
        maxPoints = 96,
        -- The CEILING on rebuilds per second, whatever asks for one.
        --
        -- Every rebuild is REM_OVERLAY plus ADD_AREA_OVERLAY per contour with a
        -- kilobyte of coordinates marshalled through a Scaleform string -- an order of
        -- magnitude more work than the radius blips' own remove-and-re-add, which is
        -- why this is slower than blip.refreshHzShrinking rather than equal to it.
        -- A MOVING STORM NEVER REBUILDS (#350, 52a7caa): its keyframes are placed and
        -- faded (#344), a breakout's included, and a placement or fade the engine
        -- refuses hands the rest of the sweep to the nominal-radius map blips. So a
        -- phase is ONE rebuild, when its record arrives, and this ceiling is for what
        -- else can ask while the storm stands still: a target edited by a dev command,
        -- a first sight, or a refused picture drawn again.
        rebuildHz = 2,

        -- ═══ HOW MANY KEYFRAMES THE MAP CROSSFADES A SWEEP THROUGH (#344) ═══
        --
        -- The wall morphs corner to corner, and on the map that morph is the solver's
        -- circle times one moving unit shape -- so the map draws that shape at a few
        -- points of the morph and fades from one to the next as the storm moves,
        -- without redrawing anything (client/storm.lua has the argument). 1 is the
        -- sweep's two ends alone: EXACT at both, and a blend of them in between. More
        -- adds keyframes between them, ADDED DURING THE HOLD one every keyframeGapMs and
        -- never while the storm moves -- nor while a conjoined zone is still growing
        -- into its destination, which is a hold that moves.
        --
        -- EACH IS PLACED WHERE IT IS TRUE: the largest copy of itself the wall holds
        -- (BR.StormKeyframePlace), so the map's error runs one way only -- the fill may
        -- stop short of the wall, and is never past it by more than the half-metre the
        -- fit allows, at any count. And the keyframe shown most holds the destination
        -- to 23 m at worst. MEASURED over 240 real sweeps, phases 2 to 7, off the
        -- movie's own arithmetic every second of the nested ones: how far the wall runs
        -- past all the fill the map shows, in metres, mean [worst]. A pause-map pixel
        -- is about 8 m.
        --
        --     phase    keyframes 1    2            4            8
        --       2       310 [1005]   165 [654]     86 [366]     44 [187]
        --       3       209 [558]    115 [368]     61 [215]     32 [118]
        --       4       128 [310]     72 [196]     39 [113]     21 [60]
        --       5        66 [173]     38 [112]     21 [72]      12 [42]
        --       6        34 [92]      20 [73]      12 [57]       8 [37]
        --       7        15 [37]       9 [28]       5 [20]       3 [13]
        --
        -- On the solver's circle instead, as the round before placed them, one pair
        -- painted fill 189 m past the wall on average at phase 2 and 794 at worst --
        -- ground the damage tick was billing -- the wall ran 112 [376] past the fill,
        -- and the destination stood 591 m out of the keyframe shown most.
        --
        -- IT SHIPS AT 1 BECAUSE EACH EXTRA KEYFRAME IS AN ADD_AREA_OVERLAY, which is the
        -- call #350's hitch was traced to. It is spent while the storm stands still and
        -- a couple of seconds apart, but its frame cost inside the movie cannot be
        -- measured off the game box: /brstormhitch reset during a hold -- past the
        -- first grow.seconds of a conjoined phase, where nothing is added -- read
        -- storm.map.keyframe, and raise this if it is well under the 34 ms threshold.
        keyframes = 1,
        -- Milliseconds between two keyframes added during a hold.
        keyframeGapMs = 2000,
    },
}

--- Total planned match length in seconds. Phase 1's wait is the free-loot
--- hold, so nothing needs adding on top. Useful for the lobby's "average match
--- length" display and for sanity-checking tuning changes.
--- @return number
function BR.Config.Storm.TotalSeconds()
    local total = 0
    for _, p in ipairs(BR.Config.Storm.phases) do
        total = total + p.wait + p.shrink
    end
    return total
end
