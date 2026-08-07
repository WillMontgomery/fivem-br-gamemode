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
        { radius = 2600.0, wait = 120, shrink = 360, dps = 1.0,  warn = 30 },
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

    -- Rendering. A single giant sphere is not an option: marker type 28 is
    -- literally MarkerTypeDebugSphere, markers have no distance parameter, and
    -- huge scale values produce broken geometry with no depth sorting. Instead we
    -- draw only the arc nearest the player, out of type-1 vertical cylinders.
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
        groundCacheSec = 1.0,    -- GetGroundZFor_3dCoord is slow; sample once per second
        fallbackZDrop  = 150.0,  -- if ground Z is unavailable, anchor below the camera
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
