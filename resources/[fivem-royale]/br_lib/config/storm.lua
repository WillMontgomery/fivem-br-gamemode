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
    edgeBiasMax = 0.55,     -- how far off-centre the next circle may sit (0..1)

    -- The free-loot hold stretches with the match: phase 1's wait is scaled
    -- to how far the FURTHEST player is from the anchor at the moment the
    -- match goes live -- fair to whoever dropped at the wrong end of the
    -- tour. phases[1].wait is the minimum; this is the rate and the cap.
    hold = {
        metersPerSec = 9.0,     -- assumed cross-map travel speed
        maxSeconds   = 300.0,
    },

    -- Playable bounds, describing the LAND we want fights to happen on.
    --
    -- The OPENING circle is deliberately allowed to overhang these bounds -- at
    -- radius 3500 most anchors spill onto coastline or ocean, and that is fine:
    -- at phase 0 nobody is forced anywhere, and every later phase clamps inward
    -- onto land. Anchors are checked in the test suite so the overhang stays
    -- bounded rather than accidental.
    --
    -- Containment always beats these bounds. If clamping a circle into the AABB
    -- would stop it nesting inside its predecessor, NextStormCentre pulls it back
    -- instead -- a circle poking into the sea is cosmetic, a circle that escapes
    -- its predecessor puts players in the storm unfairly.
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
    phases = {
        { radius = 2600.0, wait = 120, shrink = 150, dps =  1.0, warn = 30 },
        { radius = 1600.0, wait = 120, shrink = 120, dps =  2.0, warn = 30 },
        { radius =  950.0, wait =  90, shrink =  90, dps =  5.0, warn = 20 },
        { radius =  520.0, wait =  75, shrink =  75, dps =  8.0, warn = 20 },
        { radius =  260.0, wait =  60, shrink =  60, dps = 10.0, warn = 15 },
        { radius =  110.0, wait =  45, shrink =  50, dps = 12.0, warn = 15 },
        { radius =   40.0, wait =  40, shrink =  40, dps = 15.0, warn = 10 },
        { radius =    0.0, wait =  30, shrink =  60, dps = 20.0, warn = 10 },
    },

    -- Does storm damage chew through shields first, or bypass them?
    -- false = bypass armour and hit health directly (PUBG behaviour).
    damageArmourFirst = false,

    -- Rendering. A single giant sphere is not an option: marker type 28 is
    -- literally MarkerTypeDebugSphere, markers have no distance parameter, and
    -- huge scale values produce broken geometry with no depth sorting. Instead we
    -- draw only the arc nearest the player, out of type-1 vertical cylinders.
    render = {
        wallRenderDist = 300.0,  -- don't draw the wall when the EDGE is beyond this
        segments       = 48,     -- markers per frame; ~0.1ms, bounded regardless of radius
        -- How far ALONG the wall to draw, in metres of arc either side of the
        -- nearest point. The span angle is derived from this per frame
        -- (span = visDist / r), so a big circle gets a shallow arc and a
        -- small one wraps all the way around -- the fixed 120-degree span
        -- visibly ENDED mid-screen inside late circles.
        wallVisDist    = 700.0,
        height         = 300.0,  -- scaleZ, tall enough to span the visible vertical band
        colour         = { r = 150, g = 70, b = 255 },
        alpha          = 110,
        -- Neighbouring cylinders should MEET, barely: heavy overlap doubles
        -- the additive alpha where they cross and renders as dark vertical
        -- banding -- the "stripes" of the first in-game wall.
        overlap        = 1.05,
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
