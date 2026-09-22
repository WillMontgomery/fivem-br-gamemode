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
    -- WHAT IT REACHES TODAY IS THE MAP AND ONLY THE MAP. The two map rings and the
    -- #327 preview ring are drawn from this; the WALL and the DAMAGE TEST still
    -- measure the union of two circles, because the union of two rounded rectangles
    -- is not expressible in the arc-and-segment model and #335 has not settled which
    -- way to pay for that. So a squareness above zero shows square rings over a round
    -- wall until that half lands. Left at zero, nothing in the game can tell this
    -- knob exists.
    squareness = 0.0,

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
            -- ═══ 1024 RATHER THAN 256, AND THE FADE IS ONLY HALF THE REASON ═══
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
            -- At 1024 nothing is rationed on the gradient path (worst 332 polys, and
            -- every shape inside chordM), and the banded path at 3 bands peaks at
            -- 888 with one shape trimmed to 2.88 m of sag. Measured polys per frame,
            -- gradient / 3 bands: phase 1 nested 162 / 486, phase 2 nested 126 / 378,
            -- phase 3 nested 98 / 294, phase 4 nested 72 / 216, phase 5 nested
            -- 52 / 156, phase 8 point 48 / 144, the widest Venn 332 / 888.
            maxPolys = 1024,

            -- ═══ THE FADE, WHICH IS WHAT LETS THE WALL BE AS TALL AS THE MARKER ═══
            --
            --   "are you able to make the wall fade bottom to top like the
            --    3dmarker? if so, just make it the same height as the marker was."
            --   "go with the fallback if no stock texture works. but give me a way
            --    to know whether it fellback."          -- the owner, 2026-09-22
            --
            -- TWO PATHS, AND THE DEFAULT IS THE ONE THAT CANNOT FAIL.
            --
            --   'bands'     stacked plain DRAW_POLY quads, each flat at its own
            --               alpha. Always works, costs `bands` times the polys, and
            --               SHOWS STEPS rather than a smooth ramp -- which is the
            --               banding #336 escaped, so it is a fallback and not a
            --               plan.
            --   'gradient'  `_DRAW_SPRITE_POLY_2` (0x736D7AA1B750856B), Rockstar's
            --               DRAW_TEXTURED_POLY_WITH_THREE_COLOURS, which takes a
            --               colour AND AN ALPHA PER VERTEX: a real gradient at
            --               today's triangle count, for nothing.
            --
            -- THE GRADIENT IS NOT THE DEFAULT BECAUSE IT NEEDS A TEXTURE WE DO NOT
            -- SHIP, and that is a finding rather than a caution. The native is real
            -- -- a GTA V client native, registered in FiveM with 32 arguments,
            -- callable from Lua -- but it is a TEXTURED poly, so the vertex colours
            -- tint something, and a textured poly with no texture draws nothing.
            --
            -- THERE IS NO STOCK FLAT-WHITE TEXTURE. Every shipped resource that
            -- draws textured polys either streams its own .ytd (l2k_gps3d's
            -- `chevrons`; blitz outrun's `blitz_outrun`, which is a translucent quad
            -- wall and the closest analogue in existence) or points the native at a
            -- DUI's runtime texture. Rockstar's own use is tapered laser-beam art.
            -- `deadline`, which the native's own documentation names, is requested by
            -- nobody at all. THIS ESTATE SHIPS NO STREAMED ASSETS, so the one thing
            -- the gradient needs is the one thing we have not got -- and there is no
            -- working call site for the native anywhere in public code either, so it
            -- would be unproven even with a texture.
            --
            -- WHAT THAT COSTS IF IT IS WRONG IS THE WHOLE WALL. A native that
            -- silently draws nothing leaves the storm with no curtain at all, which
            -- is the failure the owner has now reported twice -- and NO TEST IN THIS
            -- TREE CAN SEE IT, because a suite can prove a call was made and cannot
            -- prove a pixel appeared. So the wall ships on bands.
            --
            -- THE GRADIENT IS FULLY WIRED AND WAITING FOR A TEXTURE. Name a resident
            -- dictionary and texture below and set prefer = 'gradient': the wall
            -- requests the dictionary, waits requestFrames for it, uses it if it
            -- arrives and bands if it does not. Two ways to get a texture, neither of
            -- them free: add a 1x1 white .ytd to a resource's stream folder, which
            -- ends this estate's no-streamed-assets rule, or bake the ramp into a DUI
            -- and draw it with the single-colour DRAW_TEXTURED_POLY instead.
            --
            -- READ THE LINE THE WALL PRINTS on its first frame; /brwallstyle reports
            -- the same thing at any time. Two failures look identical from here and
            -- only your eyes tell them apart: the wall MISSING entirely means the
            -- native drew nothing, and the wall in the WRONG COLOUR means the texture
            -- tinted it instead of the other way round.
            fade = {
                prefer     = 'bands',

                -- HOW MANY STACKED QUADS THE BANDED PATH USES, and this is the
                -- smoothness-against-polys dial. Each band multiplies the wall's
                -- poly count: at 3 the phase-1 ring is 486 polys a frame and the
                -- ramp shows as three steps, at 6 it is 972 and twice as smooth.
                -- Raise maxPolys with it or the budget will start trimming quads
                -- and the ring will go polygonal instead.
                bands      = 3,

                -- THE RAMP, AS TWO MULTIPLIERS ON render.alpha: full strength at
                -- baseZ, nothing at topZ. A straight line is all that one colour per
                -- vertex can express -- a wall that stayed solid to head height and
                -- only then faded would need a kink in it, which needs a second
                -- stacked quad and twice the polys on the one path that was supposed
                -- to be free. Raise topAlpha if the wall looks decapitated from the
                -- ground; lower baseAlpha if the base reads as a solid block.
                baseAlpha  = 1.0,
                topAlpha   = 0.0,

                -- The texture the gradient path tints, and BOTH ARE EMPTY BECAUSE NO
                -- STOCK ONE EXISTS -- see above. Empty is read as "band", not as "try
                -- it and see": a textured poly with no texture draws nothing, so
                -- treating an unset dictionary as something to attempt would let a
                -- config typo cost the whole wall in silence.
                --
                -- requestFrames is how long the wall waits for a NAMED dictionary
                -- before giving up and banding. A dictionary that never arrives is a
                -- fallback, not a request every frame forever -- 300 frames is about
                -- five seconds, and the answer is latched for the session.
                dict          = '',
                texture       = '',
                requestFrames = 300,
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
