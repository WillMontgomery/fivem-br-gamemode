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
-- 2. LATE CIRCLES SIT INSIDE THE RENDER CEILING. FiveM's default entity culling
--    radius is 424 units, and the natives that would widen it are deprecated with
--    known unfixable issues. Players beyond that distance are not rendered and
--    cannot be shot. From phase 4 down, the circle diameter is at or under that
--    ceiling, so fights stay inside what the engine will actually draw.

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

    -- The opening circle COVERS THE WHOLE MAP: its radius is computed per
    -- match as the distance from the anchor to the farthest playable-bounds
    -- corner (plus a margin), so nobody can land outside circle 1 -- a far
    -- tour-end jumper starts inside like everyone else, and the first shrink
    -- sweeps the map inward toward the anchor. radius0 is the FLOOR on that
    -- computation, not the radius itself.
    radius0     = 3500.0,
    openMargin  = 200.0,
    -- How far off-centre the next circle may sit, as a fraction of the
    -- containment slack. 1.0 = anywhere the nesting rule allows -- 0.55
    -- "wasn't moving far enough" (user call, 2026-08-04).
    edgeBiasMax = 1.0,

    -- The FINAL circles hug the edge: for the last edgeHugPhases phases the
    -- next centre is pushed to within edgeHugM of the current circle's rim
    -- (containment still wins at small radii, where the whole circle is
    -- within 250m of its own circumference anyway). Endgames resolve as a
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

    -- SHRINK TIME IS PRICED PER PHASE, like the hold: at each phase entry
    -- the furthest in-match player's run to the TARGET circle's edge sets
    -- the wall's travel time -- everyone already inside means the sweep
    -- takes only minSeconds and the game moves on (the "extra minutes for
    -- gameplay to really begin" complaint); a far straggler gets time to
    -- run. The authored per-phase shrink value is the CEILING.
    shrinkPace = {
        metersPerSec = 9.0,   -- same assumed cross-map speed as the hold
        minSeconds   = 40.0,  -- even an uncontested sweep takes this long
    },

    -- The free-loot hold stretches with the match: phase 1's wait is scaled
    -- to how far the FURTHEST player is from the anchor at the moment the
    -- match goes live -- fair to whoever dropped at the wrong end of the
    -- tour. phases[1].wait is the minimum; this is the rate and the cap.
    --
    -- startCapSeconds bounds the WAIT alone, not the budget: the wall starts
    -- moving within three minutes of PLAYING no matter how wide the drop
    -- spread, and every second the cap trims off the hold is paid back into
    -- a SLOWER first shrink (user call, 2026-08-04). The far-drop player
    -- gets the same total phase-1 time to make the run -- the wall just
    -- spends more of it visibly creeping instead of parked.
    hold = {
        metersPerSec    = 9.0,   -- assumed cross-map travel speed
        minSeconds      = 60.0,  -- floor: everyone-in-the-circle matches
                                 -- still get ONE minute of free looting,
                                 -- not three (user call, 2026-08-04)
        maxSeconds      = 300.0, -- cap on the TOTAL priced budget
        startCapSeconds = 180.0, -- cap on the stationary wait alone

        -- ═══ AND ONCE THE LOBBY IS IN, THE WAIT IS AT MOST 1:30 (#352) ═══
        --
        --   "When >=75% are within the circle, the time is 1:30 till the storm
        --    moves"                                       -- owner, 2026-09-22
        --
        -- The pricing above measures to the ANCHOR, and circle 1 can be drawn
        -- kilometres off it, so a lobby standing inside circle 1 could still be
        -- priced the full three minutes -- the solo playtest that opened this. The
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
    -- The phase's reach budget always beats these bounds. If clamping a circle
    -- into the AABB would push it further than the budget allows,
    -- NextStormCentre pulls it back instead -- a circle poking into the sea is
    -- cosmetic, a circle further out than the phase priced is a run nobody was
    -- given time for. (The budget is the containment slack, plus the breakout
    -- overhang on the phases that roll one.)
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
        -- doubled back to 120). Note the start-cap payback in
        -- server/storm.lua ADDS trimmed hold seconds on top of this.
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

    -- ═══ EVERY PHASE IS A RANDOM SHAPE, AND THESE ARE ITS TWO DIALS (#344) ═══
    --
    --   "ship something that will draw random shaped storm walls for each phase,
    --    still matching our approximate positioning and size rules, circles are
    --    not allowed."                                -- the owner, 2026-09-22
    --
    -- The shape is a jittered convex polygon with rounded corners, drawn from the
    -- match's storm seed and the phase index, scaled by whatever radius the solver
    -- reports -- so the WALL and the DAMAGE BOUNDARY are both that shape and the
    -- hold/sweep timing is untouched. br_lib/shared/storm_shape.lua's blob()
    -- carries the geometry and BR.StormZone is the one place it is asked for.
    --
    -- MEASURED AT THIS CONFIG, over 20000 draws (tools/test_shared.lua's
    -- `blob.measure` block re-measures it rather than trusting this note):
    --
    --     area             0.898 of the circle it replaces
    --     max extent       1.050 of r on average, 1.117 worst
    --     min/max radius   0.808 on average, 0.686 worst
    --     corner radius    0.391 of r on average, 0.187 worst
    --     convex first try 87.5 percent, worst case 3 attempts, never concave
    --
    -- min/max radius is the "is it a circle" measure -- 1.00 would be one. At 0.81
    -- the radius varies by a fifth, which on the 2600 m phase is a boundary running
    -- between about 2200 and 2800 metres out: a 600 m lump, unmistakable from the
    -- ground and from the map.
    --
    -- ═══ WHAT IT COSTS, SAID HERE RATHER THAN LEFT TO BE DISCOVERED ═══
    --
    --   THE MAP STILL DRAWS A CIRCLE. No GTA native fills an arbitrary outline on
    --   the minimap or the pause map (storm_shape.lua's mapPrimitives has the whole
    --   search, including the Scaleform route and why it is not taken), so the two
    --   rings stay radius blips at r. The ring is exact where the blob reaches r,
    --   over-reports by about a sixth of r where it dents in and under-reports by a
    --   twentieth where it bulges -- measured on one phase-1 draw, a boundary running
    --   2206 to 2789 metres out against a 2600 metre ring. The WALL is drawn on the
    --   real boundary, so a player who can see the curtain is never misled by the
    --   ring; it is the pause map's rotation aid, where a sixth of a kilometre is a
    --   few pixels.
    --
    --   AN OVERLAPPING BREAKOUT DRAWS BOTH BOUNDARIES. The union of two blobs is
    --   not expressible in the arc-and-segment model without a real boolean union,
    --   which is its own piece of work, so on a phase whose two circles CROSS the
    --   wall draws each shape whole and the stretches that run inside the other are
    --   drawn too: curtain visible inside the safe zone. THE DAMAGE IS STILL EXACT
    --   -- a signed distance to a union is the minimum of the two, which holds for
    --   any shapes -- so it is a drawing defect, not a gameplay one. Nested (every
    --   phase that did not break out) and disjoint (a breakout that separated
    --   entirely) are both exact and single-silhouette.
    --
    --   THE SHAPE CHANGES AT A PHASE BOUNDARY. Each phase draws its own blob, so at
    --   the instant one phase hands over to the next the wall is standing still and
    --   changes its lumps. Morphing between two shapes instead would mean
    --   interpolating two convex polygons, which is not convex in general, and the
    --   exact signed distance and inset both require convex.
    --
    -- PHASE 8 IS RADIUS 0 AND STAYS A POINT, as it always has: a shape with no
    -- radius is not a shape, and a point is not a circle.
    shape = {
        -- HOW MANY CORNERS. 9 is the owner's measurement: 7 gives away too much
        -- area (0.84), 11 and 13 are rounder AND far more often concave (at 13 the
        -- first draw fails four times in five), so the retry does most of the work
        -- and the shape it retries into is tamer.
        --
        -- BELOW 3 IS NOT A POLYGON AND IS THE WAY BACK TO CIRCLES -- the whole game
        -- draws exactly what it drew before #344. That is a deliberate edit and not
        -- a default: #335 shipped its shape behind a knob at zero and nothing in the
        -- game ever drew it, which is the mistake this block is not repeating.
        corners     = 9,

        -- HOW FAR EACH CORNER'S RADIUS WANDERS, as a fraction of r, SYMMETRICALLY
        -- about it -- so r * (1 + j * U(-1, 1)) and not r * (1 - 2j * U(0, 1)).
        -- Inward-only jitter costs 28 to 41 percent of the circle's area, measured,
        -- because the polygon and the corner rounding have each taken some already;
        -- jittering about r costs a tenth and keeps the extent near r, which is what
        -- lets every placement rule keep using r as the bound.
        --
        -- THIS IS THE DIAL TO TURN AFTER A PLAYTEST. Higher is lumpier and more
        -- often concave (0.20 fails one draw in two at 9 corners); lower reads
        -- rounder. 0.12 to 0.15 is the measured band where the shape is
        -- unmistakably not a circle and the retry is still rare.
        jitter      = 0.13,

        -- HOW FAR A CORNER MAY SLIDE AROUND THE RING, as a fraction of its own
        -- slot. Bounded at 0.5 by geometry rather than by taste: at half a slot two
        -- neighbours can reach the same angle and the corner ORDER can swap, which
        -- would turn a convex draw into a self-crossing one. 0.3 leaves the order
        -- decided by construction, so the walk is counter-clockwise without being
        -- sorted.
        angleJitter = 0.3,

        -- HOW ROUND THE CORNERS ARE, as a fraction of the tightest corner's own
        -- allowance (the shorter adjacent half-edge, turned into a radius by the
        -- corner's angle). 1.0 would put two fillets tangent to each other and
        -- leave no straight run between them; 0.85 keeps a fifteen percent run on
        -- every edge. Lower it for a shape that reads as a polygon, raise it toward
        -- 1.0 for one that reads as a smooth lump.
        --
        -- ONE RADIUS FOR ALL THE CORNERS, which is what makes the signed distance
        -- and the erosion exact rather than nearly so -- storm_shape.lua's blob
        -- section argues it at length, and the measurement above is of what ships.
        round       = 0.85,
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
        alpha          = 110,
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
        -- Metres the zone's boundary must be able to have moved before a zone that
        -- can only be REBUILT is rebuilt (#350).
        --
        -- A zone that is one blob -- every phase that did not break out -- is never
        -- rebuilt for moving at all: it is placed, see client/storm.lua. This is for
        -- the rest, a breakout's union above all, where the only way to move the
        -- fill is REM_OVERLAY plus ADD_AREA_OVERLAY and every one of those is the
        -- work #350's hitch was traced to.
        --
        -- EQUAL TO chordM, AND THAT IS THE ARGUMENT FOR THE NUMBER. The fill is
        -- already allowed to sit chordM off the boundary between its points; a
        -- boundary that has drifted less than that is inside the error the drawing
        -- was accepted with. MEASURED on breakout sweeps (phases 3 and 5 to 7) at
        -- the real 100 ms tick: 2.00 rebuilds a second on every one before this,
        -- 0.62 to 1.65 after. The price is the fill lagging the zone by up to 7.5 m
        -- between rebuilds where it lagged 1.9 to 5.6 m -- still under the 11.7 m a
        -- phase-1 sweep lagged at 2 Hz on the build the owner signed off.
        -- Raising it is the lever if a late-game breakout still hitches; the price
        -- is the fill stepping further on the radar, where 8 m is several pixels.
        moveM     = 8.0,
        -- The CEILING on rebuilds per second, whatever asks for one.
        --
        -- Every rebuild is REM_OVERLAY plus ADD_AREA_OVERLAY per contour with a
        -- kilobyte of coordinates marshalled through a Scaleform string -- an order of
        -- magnitude more work than the radius blips' own remove-and-re-add, which is
        -- why this is slower than blip.refreshHzShrinking rather than equal to it.
        -- Until #350 this was also the RATE: the map rebuilt twice a second for every
        -- second the storm moved. Now moveM decides when a moving zone is rebuilt, and
        -- this only stops a fast breakout, or the phase-1 fade stepping its alpha,
        -- from asking more often than this.
        rebuildHz = 2,
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
