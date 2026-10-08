-- Storm configuration.
--
-- Two decisions here are load-bearing and worth understanding before tuning:
--
-- 1. ANCHORS, NOT ONE MAP-WIDE CIRCLE. The Los Santos landmass spans roughly
--    8 km x 11.5 km. A single circle covering all of it needs a radius around
--    5800, which produces 11 km rotations that no battle royale pacing survives.
--    The anchor is a POI picked relative to THIS match's flight (see anchorRegion
--    and anchorBand below): city or county first, then one random waypoint of the
--    drawn tour in that region, then one random POI of that region inside a
--    distance band of it. Route-coupled, so the opening circle almost always
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
    -- CITY OR COUNTY, DRAWN BEFORE ANYTHING ELSE (#381).
    --
    --   "What I want is 50% in the city and 50% in the county."
    --                                                  -- owner, 2026-10-03
    --
    -- THE LINE IS THE OWNER'S:
    --
    --   "y = 1050. everything below that is city, everything above is county"
    --                                                  -- owner, 2026-10-03
    --
    -- A point is CITY when its y is below cityMaxY and COUNTY otherwise; that
    -- one line sorts both the waypoints and the POIs. Each match draws city
    -- with probability cityShare, then picks its waypoint and its POI inside
    -- that region, so the ANCHOR is city cityShare of the time. Before this the
    -- waypoint decided, and legs 3 and 4 are always county: over all 192 tours
    -- the anchor was city 37% of the time.
    --
    -- CITYSHARE IS CALIBRATED TO THE MATCH, NOT TO THE ANCHOR. The owner's 50/50
    -- is where matches OPEN and END: circle 1's center and the final zone's. Both
    -- drift off the anchor back toward about 43% city -- circle 1 roams 2.4 km
    -- from it at the median,
    -- and the final zone roams off circle 1 -- so an anchor split 50/50 opened
    -- matches in the city 46% of the time and ended them there 44%. 0.62 is the
    -- share that puts circle 1 and the final zone each as near half as one number
    -- can, and the anchor is then city 62% of the time.
    --
    -- MEASURED through the real bus.lua and storm.lua, whole matches to the last
    -- phase, city by y < 1050. Picked on 12,000 matches (0.62 is the share where
    -- the larger of the two misses is smallest); checked on 4,000 others it never
    -- saw (95% intervals):
    --
    --   cityShare   anchor city          circle 1 city        final zone city
    --     0.50      50.7% (49.2-52.3)    45.9% (44.4-47.4)    43.6% (42.1-45.1)
    --     0.62      62.6% (61.1-64.1)    51.0% (49.5-52.6)    48.0% (46.5-49.6)
    --
    -- Circle 1 runs about three points ahead of the final zone at any share near
    -- this one, because the final zone follows the anchor less closely than
    -- circle 1 does; 0.62 splits that gap, a point or so over half and a point or
    -- so under. Anything that changes how far circle 1 or the later phases roam
    -- moves both numbers. tools/test_storm.lua's storm.anchor.outcome measures
    -- circle 1 through the real server code every run; the final zone it checks
    -- only coarsely (24 matches a side), so a change to the later phases' roaming
    -- needs this table measured again.
    --
    -- At y < 1050, 52 of the 120 POIs are city. The nearest the line on the
    -- city side are South Fuente Ridge and Observatory Ridge (y 835 and 845);
    -- on the county side Chumash (1080), La Fuente Blanca, South Palomino
    -- Ridge, the Vinewood Bowl and the Galileo Observatory (1145 to 1200). No
    -- tour waypoint lies between y 700 and 1219, so any line from 846 to 1080
    -- draws exactly the same anchors.
    --
    -- A share that is not a number in 0..1, or a line that is not a y on the
    -- map (inside mapAABB below), is not used: the picker falls back to these
    -- two values (BR.PickStormAnchor). NaN counts as neither.
    anchorRegion = {
        cityMaxY  = 1050.0,
        cityShare = 0.62,
    },

    -- How the match anchor is picked from the flight (BR.PickStormAnchor).
    -- A POI of the drawn region between min and max units of a random tour
    -- waypoint in it; if a waypoint has no such POI in the band (a coastal or
    -- mountain leg), the band widens by widenStep until one appears, and the
    -- region's nearest POI is the last resort -- an anchor must ALWAYS exist, a
    -- crash here would kill the warmup.
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
    -- (An `overhang` knob, a fraction of the NEXT radius past the nesting limit,
    -- described this once; it is gone. What a breakout may do is gapMax below,
    -- measured between the two zones' real shapes -- BR.NextZoneCentre.)
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

        -- THE ZONES MAY SEPARATE COMPLETELY, and this is how far apart
        -- (user call, 2026-08-06). The new zone can sit wholly outside the
        -- old one; the GAP between their edges -- the two real SHAPES, not
        -- their circles (#344) -- is capped at this fraction of the
        -- predecessor's radius. In the circle era that was
        --
        --     d_max = curRadius + nextRadius + gapMax * curRadius
        --
        -- between centres; a stretched zone reaches further than its circle
        -- on its long axis, so its centre may now sit further out than d_max
        -- while the ground between the edges is still the same half radius.
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
        --
        -- THAT "THREE TIMES" WAS A CIRCLE'S: a separated circle's far rim is at
        -- most (2 + gapMax) * curRadius from the next one. Real zones reach
        -- further -- 3.4 to 4.0 curRadius at worst over 300 forced breakouts a
        -- phase -- so BR.StormSweepCeiling lifts this factor further by however
        -- much the phase's own pair really exceeds the circle's bound, and never
        -- lowers it. A breakout no longer than a circle's gets exactly 2.5.
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
    -- pop, on the wall and on the map.
    --
    -- THE MAP DOES NOT FOLLOW IT (2026-10-04): it shows the zone as the hold began and
    -- the destination, whose own fill covers the ground the zone grows into.
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

    -- ═══ THE MOVING ZONE TAKES THE DESTINATION'S SHAPE BEFORE IT ARRIVES ═══
    --
    --   "the expectation is the shape of the outer (moving) circle will change at
    --    runtime per frame to eventually match the shape of the inner
    --    (stationary/destination) circle when it reaches, say, 15 seconds before
    --    finishing the move."                            -- the owner, 2026-09-27
    --
    -- ONE moving zone. Its outline changes every frame from the zone it leaves to the
    -- destination's, and is the destination's `leadSeconds` before the sweep ends;
    -- from there it is that one outline moved and scaled onto the destination, landing
    -- on it exactly as the sweep ends. The wall and the damage tick read it off the
    -- solver (storm_solve.lua's "one moving zone"); the maps show only the destination
    -- while the wall moves (`overlay.sweepFadeSec`). A sweep shorter than twice this
    -- -- only under a dev time scale, since shrinkPace.minSeconds is 40 -- turns its
    -- shape half way. 0 is the one-leg morph that finishes turning only as it arrives.
    --
    -- THE SWEEP'S PRICE READS IT: a corner that turns by the knee travels its path in
    -- less than the whole sweep, and server/storm.lua prices the sweep at the length it
    -- publishes, so the runner the price is for is still never caught.
    morph = {
        leadSeconds = 15.0,
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
    --   THE MAP DOES NOT SHOW THE MORPH (2026-10-04). The zone fades off both maps as
    --   a sweep sets off and the destination is left; the 3D wall is the only picture
    --   of the moving shape. `overlay.sweepFadeSec` has the owner's call.
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
            --
            -- ═══ 8, NOT 2: THE OWNER'S TRADE FOR FRAME TIME (#393) ═══
            --
            --   "Let's fade the wall past 8km include large pieces"
            --                                         -- the owner, 2026-10-07
            --
            -- A wall draw costs about 3.3 microseconds (the owner's resmon), and 2 m
            -- of sag cost the opening ring 143 pieces where 8 m costs 72. The drawn
            -- wall is never OUTSIDE the line that damages: every piece is a chord of
            -- a convex arc of the inset shape, so it runs inside that arc, and the
            -- inset shape is edgeInset inside the true one. So the curtain stands
            -- between edgeInset and edgeInset + chordM -- 6 to 14 m -- inside the
            -- edge, on the safe side; the HUD, the map and the damage all read the
            -- true shape and none of them moved. tools/test_storm.lua's
            -- `wall.chord` measures it on every phase and shape.
            --
            -- A MOVING WALL DOES NOT JUMP BY IT. client/storm.lua steps each run
            -- from its start at a step that moves only as the shape does
            -- (buildStrip), so a sweep slides the wall and grows a vertex at a run's
            -- end; and where the shape itself changes what it is made of -- a
            -- sweep's start, knee and end, a breakout's whole motion -- the pieces
            -- are split to a quarter of this sag, 2 m (splitRampSec below). Before
            -- both, a moving wall at 8 m jumped by up to 7.9 m, many times a sweep;
            -- now no more than the 2 m it moved at the old chord of 2
            -- (tools/test_storm.lua's wall.sweepjump).
            chordM   = 8.0,

            -- ═══ THE LONGEST A PIECE MAY BE, FOR THE FAR FADE (#393) ═══
            --
            -- The fade below is carried by each piece's two ends, so a piece is cut
            -- no longer than this: a phase-1 blob's straight run can be 9.6 km, its
            -- middle beside the player while both ends are past 3 km. Pieces of one
            -- straight run lie on one line, so this changes no picture. 1500 is the
            -- fade band's own width, which is what lets farFade's texture hold the
            -- far end of any piece the fade can still see (see farFade). MEASURED
            -- over 200 seeds, it costs a 2600 m zone 5.1 pieces on average, phase 1's
            -- sweep half way 6.4, a 1600 m zone 1.9, a 950 m zone 0.5 and smaller
            -- zones none (the straights are shorter than it).
            maxQuadM = 1500.0,

            -- ═══ A WALL IN MOTION IS SPLIT AT ITS PIECES' MIDDLES AROUND THE MOMENTS
            --     ITS SHAPE CHANGES WHAT IT IS MADE OF (#393) ═══
            --
            -- A sweep's start, its knee and its end, and a breakout's whole motion:
            -- there the wall is drawn at a quarter of chordM's sag (2 m), so it
            -- cannot jump further than that, and this is how long the split takes
            -- to ease in before and out after (client/storm.lua's wallSplit).
            splitRampSec = 2.0,

            -- ═══ THE FAR WALL FADES OUT FROM 1.5 TO 3 km, AND IS NOT DRAWN PAST IT
            --     (#393) ═══
            --
            --   "If the wall fade today is 5km, make it 3km"  -- the owner, 2026-10-07
            --
            -- Measured from the viewpoint the wall already faces by (the player, or
            -- the player watched), on the ground, to every end of every piece. Any
            -- piece with both ends inside startM is drawn with exactly the texels it
            -- was drawn with before this existed; past endM a piece is not
            -- submitted at all.
            --
            -- WHY 1.5 TO 3. 3 is the owner's, for frame time; the band keeps the
            -- 1.5 km it had at 6.5 to 8. THE TRADE HE ACCEPTED: a zone wider than
            -- about 3 km fades on its far side, the one a player stands in included.
            -- From phase 3's hold on that zone is phase 2's target or smaller, and
            -- MEASURED over 1000 seeds a 1600 m blob is up to 6.40 km end to end (4.29
            -- on average), so a player near one end of it sees the far end thin out
            -- from 1.5 km and go past 3. Phase 1's ring and circle 1 (up to 10.4 km)
            -- fade the same way, which is where the draws are. And 1.5 km is wide
            -- enough that nothing pops: the fade is a smoothstep, flat at both ends,
            -- carried along each piece by the texture rather than one alpha a piece
            -- (one alpha a piece is a staircase -- the "three visible steps" the
            -- owner played on the vertical fade), so a piece's alpha moves only as
            -- the player does, and the steepest it gets is 1.5x the average: 1
            -- percent of alpha per 10 m.
            --
            -- `cols` is the texture's columns per band: the fade curve is held at 17
            -- points and the sampler blends between them.
            farFade  = { startM = 1500.0, endM = 3000.0, cols = 16 },

            -- THE FLOOR ON ROUNDNESS, for the endgame circles where the sag rule
            -- would happily draw a 40m ring as a pentagon: a loop is drawn at no more
            -- than the chord that closes A CIRCLE AS LONG AS IT in this many pieces
            -- (#393). A circle at the floor is exactly minSeg pieces; a blob's
            -- straights take one each and its tighter corners fewer. It is a chord
            -- rather than a count so that it moves only as the shape does: the count
            -- it was before was shared out between a loop's runs and re-shared in
            -- one frame as they changed, which made the moving wall jump.
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
                -- THE u AXIS IS THE FAR FADE (#393). A band of columns holds the ramp
                -- as it always was, the next band fades it out to nothing, and a third
                -- holds nothing -- a full band either side, so the ends of the longest
                -- piece the fade can see always land on the texture. The width is
                -- 3 * cols + 1 = 49 and comes off strip.farFade rather than a number
                -- here; client/storm.lua's farLayout says why each band is there.
                -- Every u the draw passes is a column's center or between two, so no
                -- edge filtering or clamp rule enters into it, as before. With no
                -- farFade it is 8 identical columns, as it was. 256 TALL is one row
                -- per alpha level, which is every level the format has.
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
                -- at most 1568 KiB of stranded texture (49 x 256 x 4 bytes is 49 KiB a
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
    --
    -- THE GRADE FADES ON weather.blendSec, the sky's clock (client/storm.lua), so
    -- the red, the thunder and the NUI vignette arrive together; there is no
    -- separate ramp to tune here (#399 deleted an unread timecycleRampMs).
    fx = {
        timecycle       = 'REDMIST',
        timecycleTarget = 0.7,
        postFx          = 'DeathFailOut',
        useTimecycle    = true,
        usePostFx       = false,  -- opt in once a name is confirmed in-game
    },

    -- Minimap rings, the overlay's fallback. Radius blips cannot be resized in place;
    -- they must be removed and re-added, so nothing follows the moving wall: the zone's
    -- ring is drawn once a hold (never phase 1's, which is the whole map) and faded out
    -- by alpha as a sweep sets off at refreshHzFading, and otherwise only re-asserted.
    blip = {
        refreshHzFading    = 4,
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
        -- The CEILING on whole rebuilds per second, whatever asks for one: every one
        -- of our areas removed and added again. That happens once per record -- when
        -- it arrives -- and otherwise only for a first sight or a refused picture
        -- drawn again, so this is a ceiling and not a rate. A REFUSED picture is drawn
        -- again three times at most, each twice as far apart, and then waits for the
        -- next change of kind (client/storm.lua's PICTURE_TRIES): retried on this clock
        -- for as long as a refusal lasted, it was an add and a removal twice a second.
        rebuildHz = 2,

        -- ═══ THE MAP DOES NOT MOVE WHILE THE STORM DOES ═══
        --
        --   "when the sweep starts, the old shape fades away and only the new shape is
        --    left. that means the only indicator of the actual current shape of the
        --    storm is looking in the 3d world."            -- the owner, 2026-10-04
        --
        -- While the storm holds, both maps show the zone (as the hold began) and the
        -- destination -- phase 1 the destination alone, circle 1, because its zone is
        -- the whole map. As a sweep sets off the zone fades out over this many seconds --
        -- one alpha write a contour on each of the map band's 10 Hz ticks, nothing
        -- added, removed, moved or resized -- and the destination is all that is left
        -- until the next record's hold draws it again as the zone. The fallback ring
        -- fades on the same clock. 0 takes the zone off on the sweep's first tick.
        --
        -- WHAT WENT WITH THE MOVING SHAPE: the zone's outline moved and scaled onto the
        -- wall every tick (35258d1), redrawn as the sweep set off and at its knee and
        -- fitted inside the wall before it (8bf391e, 3a66284); `morphHz`, the clock that
        -- redrew it at up to 10 Hz (ec19f40); and `stage`, the bank of hidden outlines
        -- added through every hold (8335b17), whose adds were the 2026-10-02 hitch.
        sweepFadeSec = 1.0,
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
