-- Map data: points of interest and battle bus routing.
--
-- COORDINATES ARE A FIRST PASS. They were authored from map knowledge, not
-- surveyed in-game, so centres will be roughly right and radii will need tuning.
-- The /brtp <poi> admin command exists specifically so these can be walked and
-- corrected quickly, and loot spawn points are authored separately with /lootedit
-- rather than being derived from these centres.
--
-- `tier` drives loot density and quality:
--   3 = hot drop, dense and high quality (contested by design)
--   2 = standard named location
--   1 = sparse filler, rewards rotating through

BR = BR or {}
BR.Config = BR.Config or {}

BR.Config.Map = {}

BR.Config.Map.POIs = {
    -- Los Santos city
    { id = 'lsia',        name = 'LS International', x = -1037.0, y = -2737.0, z =  20.0, radius = 300.0, tier = 2 },
    { id = 'vespucci',    name = 'Vespucci Beach',   x = -1200.0, y = -1500.0, z =  10.0, radius = 260.0, tier = 2 },
    { id = 'delperro',    name = 'Del Perro Pier',   x = -1850.0, y = -1240.0, z =  13.0, radius = 200.0, tier = 2 },
    { id = 'downtown',    name = 'Legion Square',    x =   200.0, y =  -900.0, z =  30.0, radius = 280.0, tier = 3 },
    { id = 'mirrorpark',  name = 'Mirror Park',      x =  1050.0, y =  -650.0, z =  57.0, radius = 220.0, tier = 2 },
    { id = 'rockford',    name = 'Rockford Hills',   x =  -800.0, y =  -200.0, z =  40.0, radius = 240.0, tier = 2 },
    { id = 'richman',     name = 'Richman',          x = -1400.0, y =   100.0, z =  55.0, radius = 220.0, tier = 1 },
    { id = 'lamesa',      name = 'La Mesa',          x =   800.0, y = -1600.0, z =  30.0, radius = 240.0, tier = 2 },
    { id = 'cypress',     name = 'Cypress Flats',    x =   700.0, y = -2000.0, z =  29.0, radius = 220.0, tier = 2 },
    { id = 'elysian',     name = 'Elysian Island',   x =   200.0, y = -2700.0, z =   6.0, radius = 260.0, tier = 3 },

    -- Vinewood and the hills
    { id = 'vinewood',    name = 'Vinewood Bowl',    x =   700.0, y =  1200.0, z = 350.0, radius = 220.0, tier = 3 },
    { id = 'vinehills',   name = 'Vinewood Hills',   x =  -100.0, y =   500.0, z = 130.0, radius = 260.0, tier = 1 },

    -- North and county
    { id = 'chaparral',   name = 'Great Chaparral',  x =  -100.0, y =  2000.0, z =  70.0, radius = 260.0, tier = 1 },
    { id = 'route68',     name = 'Route 68',         x =   600.0, y =  1900.0, z = 190.0, radius = 240.0, tier = 2 },
    { id = 'harmony',     name = 'Harmony',          x =   700.0, y =  2700.0, z =  42.0, radius = 200.0, tier = 2 },
    { id = 'sandy',       name = 'Sandy Shores',     x =  1900.0, y =  3700.0, z =  32.0, radius = 320.0, tier = 3 },
    { id = 'grapeseed',   name = 'Grapeseed',        x =  1700.0, y =  4800.0, z =  42.0, radius = 260.0, tier = 2 },
    { id = 'paleto',      name = 'Paleto Bay',       x =  -150.0, y =  6300.0, z =  31.0, radius = 300.0, tier = 3 },
    { id = 'chiliad',     name = 'Mount Chiliad',    x =   450.0, y =  5700.0, z = 780.0, radius = 240.0, tier = 1 },
    { id = 'humane',      name = 'Humane Labs',      x =  3600.0, y =  3700.0, z =  30.0, radius = 260.0, tier = 3 },
    { id = 'zancudo',     name = 'Fort Zancudo',     x = -2100.0, y =  3200.0, z =  32.0, radius = 340.0, tier = 3 },
    { id = 'palomino',    name = 'Palomino Highlands', x = 2400.0, y = 1600.0, z =  40.0, radius = 240.0, tier = 1 },
}

--- Look up a POI by id.
--- @param id string
--- @return table|nil
function BR.Config.Map.GetPOI(id)
    for _, poi in ipairs(BR.Config.Map.POIs) do
        if poi.id == id then return poi end
    end
    return nil
end

--- Nearest POI to a world position, for the "you are at X" HUD label and for
--- kill-feed location context.
--- @param x number
--- @param y number
--- @return table|nil poi
--- @return number distance
function BR.Config.Map.NearestPOI(x, y)
    local best, bestD2 = nil, math.huge
    for _, poi in ipairs(BR.Config.Map.POIs) do
        local d2 = BR.Dist2(x, y, poi.x, poi.y)
        if d2 < bestD2 then
            best, bestD2 = poi, d2
        end
    end
    return best, math.sqrt(bestD2)
end

BR.Config.Bus = {
    -- Titan: chosen over cargoplane (buggy collision and interior), the blimps
    -- (too slow, wrong altitude) and volatol (oversized). The model is only ever
    -- spawned locally and non-networked, so handling is irrelevant -- it is
    -- driven by direct coordinate writes, not by physics.
    model        = 'titan',

    -- Cruise altitude. Raised from 340 after the plane clipped terrain --
    -- Los Santos has 700m+ peaks, but the chord anchors keep it out of the
    -- Chiliad massif and 500 clears everything a scored chord crosses.
    altitude     = 500.0,
    chordRadius  = 4000.0,  -- entry/exit points sit on a circle this size around the anchor
    chordOffset  = 0.5,     -- 0..1, how far off-centre the flight path may sit

    -- THE FLIGHT IS A PATH, NOT TWO LINES: spawn parked on the runway, roll,
    -- rotate at the committed point, climb straight ahead, one banked turn
    -- onto the heading for the chord, accelerate across the ocean, slow over
    -- the drop chord. The server bakes the whole thing into timestamped
    -- waypoints; clients interpolate. Surveyed in-game by the user:
    -- z is the surveyed 4.19 + 0.5: at exactly 4.19 the Titan's gear sat in
    -- the runway surface.
    spawn        = { x = 4484.61, y = -4497.98, z = 4.69, heading = 106.12 },
    rotatePoint  = { x = 4090.23, y = -4642.18 },  -- wheels-up here, straight out
    climbDist    = 2500.0,  -- metres past rotation to reach cruise altitude
    turnRadius   = 1000.0,  -- the banked turn onto the chord heading

    rollSpeed    = 80.0,    -- m/s at wheels-up (the roll builds up to this)
    climbSpeed   = 150.0,   -- m/s through the climb and the turn
    cruiseSpeed  = 400.0,   -- m/s reached across the open ocean
    speed        = 185.0,   -- m/s along the drop chord
    boardSeconds = 5,       -- parked, engines idling, before the roll begins
    jumpGrace    = 5,       -- seconds after the route ends before BUS -> PLAYING

    -- Camera orbit distance/height from the plane while riding. The Titan is
    -- ~20m long and the camera must CLEAR the hull -- the first offset
    -- (-14, +3) sat inside the tail, which rendered as a black wedge of
    -- fuselage and, over featureless ocean, read as the game having frozen.
    camDistance  = 44.0,
    camHeight    = 13.0,

    -- Route selection: candidate chords are scored by how much of the drop
    -- leg overflies LAND (proximity to authored POIs is the proxy -- they
    -- blanket the landmass). Best of N wins; pure water-to-water routes were
    -- a real and miserable outcome of unscored randomness.
    chordTries   = 16,
    landRadius   = 1400.0,  -- a sample point within this range of a POI counts as land
    minLandScore = 0.45,    -- keep drawing candidates until one clears this (best kept regardless)
}

BR.Config.Drop = {
    autoDeployAGL   = 120.0,  -- metres above ground where the glider force-opens
    landedGraceMs   = 500,    -- invincibility after touchdown, absorbs landing edge cases
    parachuteModel  = 'p_parachute1_mp_s',
    smokeTrail      = true,   -- squad-coloured, cheap and very readable
}
