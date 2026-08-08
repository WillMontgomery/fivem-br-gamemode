-- Map data: points of interest and battle bus routing.
--
-- COORDINATES ARE A FIRST PASS. They were authored from map knowledge, not
-- surveyed in-game, so centres will be roughly right and radii will need tuning.
-- The /brtp <poi> admin command exists specifically so these can be walked and
-- corrected quickly. Loot IS derived from these centres (a seeded scatter inside
-- each POI's radius, plus filler along BR.Config.Map.Roads below), so a wrong
-- radius shows up as loot in the sea long before anything else complains.
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
    -- THE TWO SOUTHERN HOT DROPS. Both were tier 2 on a 280-300m radius, which
    -- for the two biggest open sites on the map meant early jumpers at the
    -- south end landed on ground with almost nothing on it (user, 2026-08-06).
    -- Tier 3 at a wider radius makes them worth contesting and spreads the
    -- loot far enough that four players can land apart and all find something.
    { id = 'lsia',        name = 'LS International', x = -1037.0, y = -2737.0, z =  20.0, radius = 400.0, tier = 3 },
    { id = 'vespucci',    name = 'Vespucci Beach',   x = -1200.0, y = -1500.0, z =  10.0, radius = 260.0, tier = 2 },
    { id = 'delperro',    name = 'Del Perro Pier',   x = -1850.0, y = -1240.0, z =  13.0, radius = 200.0, tier = 2 },
    -- The beach itself, north of the pier: open sand with the boardwalk and
    -- the apartment blocks behind it. A hot drop by request (user,
    -- 2026-08-07) -- the west coast had a tier-2 pier and nothing else.
    { id = 'delperro_bch', name = 'Del Perro Beach', x = -1550.0, y = -1050.0, z =   3.0, radius = 300.0, tier = 3 },
    { id = 'downtown',    name = 'Legion Square',    x =   200.0, y =  -900.0, z =  30.0, radius = 280.0, tier = 3 },
    { id = 'mirrorpark',  name = 'Mirror Park',      x =  1050.0, y =  -650.0, z =  57.0, radius = 220.0, tier = 2 },
    { id = 'rockford',    name = 'Rockford Hills',   x =  -800.0, y =  -200.0, z =  40.0, radius = 240.0, tier = 2 },
    { id = 'richman',     name = 'Richman',          x = -1400.0, y =   100.0, z =  55.0, radius = 220.0, tier = 1 },
    { id = 'lamesa',      name = 'La Mesa',          x =   800.0, y = -1600.0, z =  30.0, radius = 240.0, tier = 2 },
    { id = 'cypress',     name = 'Cypress Flats',    x =   700.0, y = -2000.0, z =  29.0, radius = 220.0, tier = 2 },
    { id = 'elysian',     name = 'Elysian Island',   x =   200.0, y = -2700.0, z =   6.0, radius = 260.0, tier = 3 },
    -- Added 2026-08-06: the city had a hole between Legion Square and the
    -- eastern industrial belt.
    { id = 'pillbox',     name = 'Pillbox Hill',     x =   -70.0, y =  -600.0, z =  33.0, radius = 220.0, tier = 2 },
    { id = 'arena',       name = 'Maze Bank Arena',  x =  -250.0, y = -1900.0, z =  24.0, radius = 220.0, tier = 2 },
    { id = 'grove',       name = 'Grove Street',     x =   105.0, y = -1885.0, z =  21.0, radius = 200.0, tier = 2 },
    { id = 'terminal',    name = 'Terminal',         x =  1050.0, y = -2500.0, z =   6.0, radius = 380.0, tier = 3 },
    { id = 'buccaneer',   name = 'Buccaneer Way',    x =   500.0, y = -2600.0, z =   5.0, radius = 260.0, tier = 2 },

    -- THE RUNWAY ITSELF, not just the terminal side of the airport (user,
    -- 2026-08-06: "more loot on the runway at LSIA, not just around the
    -- road"). The lsia POI is centred on the terminal, so even at radius 400
    -- the tarmac and the western apron -- the open ground that makes LSIA
    -- worth dropping on -- fell outside it.
    { id = 'lsia_rw',     name = 'LSIA Runway',      x = -1400.0, y = -3100.0, z =  14.0, radius = 300.0, tier = 2 },
    { id = 'lsia_apron',  name = 'LSIA West Apron',  x = -1700.0, y = -2950.0, z =  14.0, radius = 260.0, tier = 2 },

    -- The port strip along the southern waterfront, surveyed in game by the
    -- user (2026-08-06). Tier 2: the south end already has Terminal and
    -- Elysian Island as tier-3 draws, and these fill the ground between them
    -- rather than adding a fourth reason to fight over the same kilometre.
    { id = 'port_w',      name = 'Port of LS West',  x =   198.75, y = -3024.54, z =   6.0, radius = 240.0, tier = 2 },
    { id = 'port_c',      name = 'Port of LS Docks', x =   525.59, y = -3089.33, z =   6.0, radius = 240.0, tier = 2 },
    { id = 'port_e',      name = 'Port of LS East',  x =  1011.77, y = -3118.76, z =   6.0, radius = 240.0, tier = 2 },
    { id = 'murrieta',    name = 'Murrieta Heights', x =  1180.0, y = -1780.0, z =  30.0, radius = 200.0, tier = 1 },
    { id = 'elburro',     name = 'El Burro Heights', x =  1370.0, y = -2100.0, z =  32.0, radius = 200.0, tier = 1 },
    { id = 'littleseoul', name = 'Little Seoul',     x =  -640.0, y = -1100.0, z =  22.0, radius = 220.0, tier = 2 },
    { id = 'morningwood', name = 'Morningwood',      x = -1310.0, y =  -830.0, z =  30.0, radius = 200.0, tier = 1 },
    -- GWC & Golfing Society had TWO tier-1 POIs on top of it (this one and
    -- richman, 351m apart), which made one golf course the densest rural
    -- ground on the map (user, 2026-08-06). Richman keeps it -- the
    -- neighbourhood is the bigger site and the course sits inside it.

    -- Vinewood and the hills
    { id = 'vinewood',    name = 'Vinewood Bowl',    x =   700.0, y =  1200.0, z = 350.0, radius = 220.0, tier = 3 },
    { id = 'vinehills',   name = 'Vinewood Hills',   x =  -100.0, y =   500.0, z = 130.0, radius = 260.0, tier = 1 },
    { id = 'observatory', name = 'Galileo Observatory', x = -410.0, y = 1200.0, z = 330.0, radius = 200.0, tier = 2 },
    { id = 'casino',      name = 'Diamond Casino',   x =   925.0, y =    46.0, z =  80.0, radius = 220.0, tier = 3 },
    { id = 'landact',     name = 'Land Act Dam',     x =  1660.0, y =   -30.0, z = 110.0, radius = 200.0, tier = 1 },
    { id = 'ulsa',        name = 'ULSA Campus',      x = -1750.0, y =   350.0, z =  60.0, radius = 220.0, tier = 1 },

    -- The west coast
    { id = 'kortz',       name = 'Kortz Center',     x = -2245.0, y =   265.0, z = 170.0, radius = 220.0, tier = 2 },
    { id = 'chumash',     name = 'Chumash',          x = -3170.0, y =  1080.0, z =   8.0, radius = 220.0, tier = 2 },
    { id = 'banham',      name = 'Banham Canyon',    x = -2540.0, y =  2320.0, z =  25.0, radius = 220.0, tier = 1 },
    { id = 'hookies',     name = 'Hookies',          x = -2200.0, y =  4290.0, z =   5.0, radius = 200.0, tier = 1 },
    { id = 'raton',       name = 'Raton Canyon',     x = -1450.0, y =  4450.0, z =  20.0, radius = 220.0, tier = 1 },
    -- Added 2026-08-06: the west was thin between Chumash and Banham, which
    -- is a long stretch of coast road with nothing to stop for.
    { id = 'palomino_hw', name = 'Pacific Bluffs',   x = -3060.0, y =   330.0, z =  10.0, radius = 220.0, tier = 1 },
    { id = 'tongva',      name = 'Tongva Hills',     x = -1550.0, y =  2200.0, z =  60.0, radius = 240.0, tier = 1 },

    -- North and county
    { id = 'chaparral',   name = 'Great Chaparral',  x =  -100.0, y =  2000.0, z =  70.0, radius = 260.0, tier = 1 },
    { id = 'route68',     name = 'Route 68',         x =   600.0, y =  1900.0, z = 190.0, radius = 240.0, tier = 2 },
    { id = 'harmony',     name = 'Harmony',          x =   700.0, y =  2700.0, z =  42.0, radius = 200.0, tier = 2 },
    { id = 'sandy',       name = 'Sandy Shores',     x =  1900.0, y =  3700.0, z =  32.0, radius = 320.0, tier = 3 },
    { id = 'stab',        name = 'Stab City',        x =    85.0, y =  3690.0, z =  39.0, radius = 200.0, tier = 2 },
    { id = 'galilee',     name = 'Galilee',          x =  1380.0, y =  4360.0, z =  42.0, radius = 200.0, tier = 1 },
    -- The equestrian estate east of Vinewood. Spelled "La Fuente Blanca" in
    -- game; the request said "Le Fuerta Blanca" and this is the place it
    -- means. Tier 1 (green): a walled compound with a big house and stables,
    -- which is a fine quiet landing and a terrible place to be caught in.
    { id = 'fuenteblanca', name = 'La Fuente Blanca', x = 1395.0, y =  1145.0, z = 114.0, radius = 200.0, tier = 1 },
    { id = 'grapeseed',   name = 'Grapeseed',        x =  1700.0, y =  4800.0, z =  42.0, radius = 260.0, tier = 2 },
    { id = 'paleto',      name = 'Paleto Bay',       x =  -150.0, y =  6300.0, z =  31.0, radius = 300.0, tier = 3 },
    { id = 'sawmill',     name = 'Paleto Forest Sawmill', x = -560.0, y = 5300.0, z = 70.0, radius = 220.0, tier = 2 },
    { id = 'chiliad',     name = 'Mount Chiliad',    x =   450.0, y =  5700.0, z = 780.0, radius = 240.0, tier = 1 },
    { id = 'procopio',    name = 'Procopio Beach',   x =  1450.0, y =  6550.0, z =   2.0, radius = 240.0, tier = 1 },
    { id = 'gordo',       name = 'Mount Gordo',      x =  2870.0, y =  5910.0, z = 340.0, radius = 220.0, tier = 1 },
    { id = 'lighthouse',  name = 'El Gordo Lighthouse', x = 3335.0, y = 5160.0, z =  18.0, radius = 200.0, tier = 1 },
    { id = 'humane',      name = 'Humane Labs',      x =  3600.0, y =  3700.0, z =  30.0, radius = 260.0, tier = 3 },
    { id = 'zancudo',     name = 'Fort Zancudo',     x = -2100.0, y =  3200.0, z =  32.0, radius = 340.0, tier = 3 },

    -- THE MOUNTAINS AND THE NORTH, TRIPLED (user call, 2026-08-06: "there's
    -- especially nothing in the mountains"). Everything north of the city was
    -- a handful of named towns with hundreds of empty metres between them, so
    -- the whole northern third of the map was a place you crossed rather than
    -- fought over. These are deliberately tier 1 -- sparse and worth stopping
    -- at, not a reason to skip Sandy Shores.
    { id = 'chiliad_n',   name = 'Chiliad North Face', x =   150.0, y =  6350.0, z = 320.0, radius = 240.0, tier = 1 },
    { id = 'chiliad_trail', name = 'Chiliad Trailhead', x =   -80.0, y =  4900.0, z = 250.0, radius = 220.0, tier = 1 },
    { id = 'cassidy',     name = 'Cassidy Creek',    x = -1000.0, y =  4400.0, z =  50.0, radius = 240.0, tier = 1 },
    { id = 'tataviam',    name = 'Tataviam Mountains', x =  2600.0, y =  2100.0, z = 150.0, radius = 240.0, tier = 1 },
    { id = 'braddock',    name = 'Braddock Pass',    x =  2050.0, y =  4550.0, z =  40.0, radius = 220.0, tier = 1 },
    { id = 'altruist',    name = 'Altruist Camp',    x = -1150.0, y =  4900.0, z = 220.0, radius = 200.0, tier = 2 },
    { id = 'northchum',   name = 'North Chumash',    x = -2600.0, y =  3100.0, z =  10.0, radius = 220.0, tier = 1 },
    { id = 'catfish',     name = 'Catfish View',     x =  2750.0, y =  3350.0, z =  35.0, radius = 220.0, tier = 1 },
    { id = 'sanchianski', name = 'San Chianski Range', x =  3200.0, y =  2400.0, z =  60.0, radius = 240.0, tier = 1 },

    -- The eastern desert
    { id = 'penitentiary', name = 'Bolingbroke Penitentiary', x = 1690.0, y = 2565.0, z = 45.0, radius = 260.0, tier = 3 },
    { id = 'redwood',     name = 'Redwood Lights Track', x = 1160.0, y = 2555.0, z =  50.0, radius = 220.0, tier = 1 },
    { id = 'quarry',      name = 'Davis Quartz Quarry', x = 2950.0, y = 2780.0, z =  40.0, radius = 260.0, tier = 2 },
    { id = 'palmer',      name = 'Palmer-Taylor Power Station', x = 2780.0, y = 1520.0, z = 32.0, radius = 240.0, tier = 2 },
    { id = 'palomino',    name = 'Palomino Highlands', x = 2400.0, y = 1600.0, z =  40.0, radius = 240.0, tier = 1 },
    { id = 'noose',       name = 'NOOSE HQ',         x =  2535.0, y =  -383.0, z =  93.0, radius = 260.0, tier = 3 },

    -- The derrick fields in the Grand Senora Desert -- open ground with cover,
    -- and nothing on it until now (user, 2026-08-06).
    { id = 'oilfields',   name = 'Oil Fields',       x =  1550.0, y =  1950.0, z =  80.0, radius = 240.0, tier = 1 },
    { id = 'derrick',     name = 'Derrick Road',     x =  1850.0, y =  2250.0, z =  70.0, radius = 220.0, tier = 1 },

    -- THE CITY, DENSIFIED (user call, 2026-08-06: "it's a dense area and
    -- should be densely looted"). Los Santos had eighteen POIs for the
    -- largest continuous built-up area on the map, so whole districts -- Alta,
    -- Burton, Strawberry, Davis -- were blank ground between named ones.
    -- Tier 1, because density here should come from the NUMBER of places
    -- worth stopping at rather than from any one of them being a hot drop:
    -- the city already has Legion Square, Elysian Island and the Terminal.
    { id = 'strawberry',  name = 'Strawberry',       x =   100.0, y = -1500.0, z =  30.0, radius = 220.0, tier = 1 },
    { id = 'davis',       name = 'Davis',            x =   400.0, y = -2150.0, z =  20.0, radius = 220.0, tier = 1 },
    { id = 'elysianfields', name = 'Elysian Fields', x =   750.0, y = -2350.0, z =  10.0, radius = 200.0, tier = 1 },
    { id = 'puertodelsol', name = 'Puerto Del Sol',  x = -1100.0, y = -1850.0, z =   5.0, radius = 220.0, tier = 1 },
    { id = 'burton',      name = 'Burton',           x =  -450.0, y =  -600.0, z =  35.0, radius = 200.0, tier = 1 },
    { id = 'westvinewood', name = 'West Vinewood',   x =  -350.0, y =  -200.0, z =  45.0, radius = 200.0, tier = 1 },
    { id = 'alta',        name = 'Alta',             x =   300.0, y =  -300.0, z =  60.0, radius = 200.0, tier = 1 },
    { id = 'hawick',      name = 'Hawick',           x =   500.0, y =   150.0, z =  85.0, radius = 200.0, tier = 1 },

    -- Requested by name (user, 2026-08-06). Vinewood Hills already had a
    -- tier-1 POI; this is the tier-2 the hills were asked for, sited east of
    -- it rather than on top of it. Banham Canyon Drive is the stretch of road
    -- south of the town, which had nothing on it.
    { id = 'vinehills_e', name = 'Vinewood Hills East', x = 400.0, y =  700.0, z = 180.0, radius = 220.0, tier = 2 },
    { id = 'banhamcanyon', name = 'Banham Canyon Drive', x = -2350.0, y = 1650.0, z = 45.0, radius = 220.0, tier = 1 },

    -- THE BACKCOUNTRY: 25 POIs sited in the gaps BETWEEN the road corridors
    -- (user call, 2026-08-06: "all of your POIs seem centered around roads --
    -- the largest gap we have is the space between the roads").
    --
    -- Everything above grew from the map's named places, and named places in
    -- GTA are on roads, so the authored set inherited the road network's shape:
    -- travel a highway and you cross POI after POI, leave it and there is
    -- nothing for two kilometres. These are chosen the other way round -- from
    -- the empty interiors -- and `tools/check_pois.lua` gates the result on
    -- distance to the nearest road polyline as well as to the nearest POI.
    --
    -- Tier 1 almost throughout: the point is a reason to come off the highway,
    -- not a reason to skip Sandy Shores.

    -- West: the Tongva / Zancudo interior, between the Great Ocean Highway and
    -- Route 68.
    { id = 'mtjosiah',    name = 'Mount Josiah',     x = -1250.0, y =  1850.0, z = 190.0, radius = 220.0, tier = 1 },
    { id = 'baytree',     name = 'Baytree Canyon',   x =  -800.0, y =  1550.0, z = 190.0, radius = 200.0, tier = 1 },
    { id = 'tongva_v',    name = 'Tongva Valley',    x = -1900.0, y =  1350.0, z =  90.0, radius = 220.0, tier = 1 },
    { id = 'pacific_r',   name = 'Pacific Ridge',    x = -2800.0, y =  1350.0, z =  40.0, radius = 200.0, tier = 1 },
    { id = 'banham_w',    name = 'Banham Bluffs',    x = -2900.0, y =  1900.0, z =  25.0, radius = 200.0, tier = 1 },
    { id = 'lagozancudo', name = 'Lago Zancudo',     x = -1750.0, y =  2800.0, z =  20.0, radius = 220.0, tier = 1 },
    { id = 'zancudo_r',   name = 'Zancudo River',    x = -1450.0, y =  3450.0, z =  15.0, radius = 220.0, tier = 1 },

    -- Centre: the Great Chaparral and the hills either side of Vinewood.
    { id = 'hills_e',     name = 'East Vinewood Hills', x = 1150.0, y = 1400.0, z = 160.0, radius = 220.0, tier = 1 },
    { id = 'chaparral_n', name = 'North Chaparral',  x =  -700.0, y =  3000.0, z =  90.0, radius = 240.0, tier = 1 },
    { id = 'harmony_n',   name = 'North Harmony Ridge', x = 300.0, y =  3100.0, z =  90.0, radius = 220.0, tier = 1 },
    { id = 'zancudo_f',   name = 'Zancudo Flats',    x =  -350.0, y =  3950.0, z =  20.0, radius = 220.0, tier = 1 },
    { id = 'dryfields',   name = 'Senora Dry Fields', x = 2450.0, y =  3000.0, z =  50.0, radius = 240.0, tier = 1 },

    -- North-west: the Paleto forest, off the coast road and off Senora.
    { id = 'paleto_f',    name = 'Paleto Forest',    x =  -950.0, y =  5450.0, z = 130.0, radius = 240.0, tier = 1 },
    { id = 'graybeard',   name = 'Graybeard Woods',  x = -1750.0, y =  5150.0, z =  50.0, radius = 220.0, tier = 1 },
    { id = 'raton_n',     name = 'North Raton Canyon', x = -1900.0, y = 4700.0, z =  30.0, radius = 200.0, tier = 1 },
    { id = 'calafia',     name = 'Calafia Bridge',   x = -1000.0, y =  6100.0, z =  35.0, radius = 220.0, tier = 2 },

    -- The Chiliad massif, on every face of it.
    { id = 'chiliad_ridge', name = 'Chiliad Ridge',  x =   150.0, y =  5450.0, z = 400.0, radius = 220.0, tier = 1 },
    { id = 'chiliad_e',   name = 'Chiliad East Slope', x = 1150.0, y =  5350.0, z = 160.0, radius = 220.0, tier = 1 },
    { id = 'alamo_n',     name = 'North Alamo Shore', x =  600.0, y =  4650.0, z =  35.0, radius = 220.0, tier = 1 },
    { id = 'procopio_n',  name = 'Cove Road',        x =   900.0, y =  6300.0, z =  40.0, radius = 200.0, tier = 1 },

    -- North-east: the Gordo massif and the San Chianski coast.
    { id = 'mtgordo_w',   name = 'Gordo Ravine',     x =  2400.0, y =  5400.0, z = 150.0, radius = 220.0, tier = 1 },
    { id = 'gordo_s',     name = 'Mount Gordo South Face', x = 2650.0, y = 4950.0, z = 130.0, radius = 220.0, tier = 1 },
    { id = 'senora_n',    name = 'North Senora Flats', x = 2500.0, y =  4300.0, z =  40.0, radius = 240.0, tier = 2 },
    { id = 'mthaan',      name = 'Mount Haan',       x =  3100.0, y =  4500.0, z = 110.0, radius = 220.0, tier = 2 },
    { id = 'eastbeach',   name = 'East Coast Bluffs', x = 3600.0, y =  4350.0, z =  30.0, radius = 200.0, tier = 1 },
}

--- Where the Battle Bus opens its doors regardless of where it is in the tour.
---
--- The door window was two authored route INDICES, which assumes every tour
--- has the same shape. A flight that crosses the ports or the airport late --
--- past the authored close index -- flew over the best drop on the map with
--- the doors shut (user, 2026-08-06). These zones widen the window instead:
--- doors open at the earlier of the authored point and the first zone entry,
--- and close at the later of the authored point and the last zone exit.
---
--- NOT TOO generous, and the test suite is why. The first draft used 1200 and
--- 1400m radii on the reasoning that "near the ports" is approximate and
--- opening early costs nothing -- and `match.bus` immediately failed: the
--- departure path from Cayo Perico runs out over the ocean SOUTH of Los
--- Santos, clipped the port zone at (792, -4375), and opened the doors over
--- open water seconds after wheels-up. These radii cover the land and stop
--- short of that approach.
BR.Config.Map.DoorZones = {
    { id = 'lsia',  x = -1037.0, y = -2737.0, radius = 900.0 },
    { id = 'ports', x =   600.0, y = -2950.0, radius = 800.0 },
}

--- Major road corridors, as polylines.
---
--- These exist for ONE purpose: sparse loot filler between the POIs. FiveM has
--- no offline road graph -- GetClosestVehicleNode is a client native and loot
--- generation is server-side and must be reproducible from a seed outside the
--- game -- so the corridors players actually travel are authored here instead.
--- Being roughly right is enough: filler is scattered up to `lateralOffset`
--- either side and the client ground-probes each point anyway.
---
--- Same caveat as the POIs: first pass, walk them with /brtp and correct.
BR.Config.Map.Roads = {
    {
        id = 'greatocean', name = 'Great Ocean Highway',
        points = {
            { x = -1800.0, y = -1200.0 }, { x = -2300.0, y =  -400.0 },
            { x = -2600.0, y =   800.0 }, { x = -2400.0, y =  2000.0 },
            { x = -1900.0, y =  3000.0 }, { x = -1100.0, y =  4400.0 },
            { x =  -300.0, y =  5900.0 }, { x =   500.0, y =  6600.0 },
        },
    },
    {
        id = 'route68', name = 'Route 68',
        points = {
            { x = -2200.0, y =  2400.0 }, { x = -1200.0, y =  2100.0 },
            { x =     0.0, y =  2700.0 }, { x =  1200.0, y =  3100.0 },
            { x =  2300.0, y =  3400.0 }, { x =  2900.0, y =  2900.0 },
        },
    },
    {
        id = 'senora', name = 'Senora Freeway',
        points = {
            { x =  2600.0, y =  1400.0 }, { x =  2300.0, y =  2600.0 },
            { x =  1700.0, y =  3400.0 }, { x =   700.0, y =  4200.0 },
            { x =  -200.0, y =  5300.0 }, { x =    50.0, y =  6300.0 },
        },
    },
    {
        id = 'palomino', name = 'Palomino Freeway',
        points = {
            { x =   900.0, y = -1200.0 }, { x =  1600.0, y =  -400.0 },
            { x =  2200.0, y =   500.0 }, { x =  2600.0, y =  1300.0 },
        },
    },
    {
        id = 'lapuerta', name = 'La Puerta Freeway',
        points = {
            { x = -1200.0, y = -2200.0 }, { x =  -600.0, y = -1900.0 },
            { x =   100.0, y = -1400.0 }, { x =   600.0, y =  -800.0 },
            { x =   400.0, y =   200.0 }, { x =  -400.0, y =   800.0 },
        },
    },
    {
        id = 'joshua', name = 'Joshua / Alamo Road',
        points = {
            { x =  1900.0, y =  3800.0 }, { x =  1300.0, y =  4400.0 },
            { x =   800.0, y =  5300.0 }, { x =   200.0, y =  6100.0 },
        },
    },
}

--- Coarse water. Rectangles that are definitely sea or lake.
---
--- This is NOT a precise water map and does not try to be -- the client has
--- GET_WATER_HEIGHT and reports anything that ground-probes into water back to
--- the server, which relocates it. This list only exists to stop generation
--- putting hundreds of items in the Pacific in the first place, so the repair
--- round-trip handles dozens rather than hundreds.
---
--- Author more rectangles here whenever a run reports a cluster in the same
--- stretch of water; `brloot` prints the relocation count.
--- CONSERVATIVE BY CONSTRUCTION. A rectangle here must never contain a POI
--- centre -- the first draft swallowed Chumash, Hookies and Galilee, all
--- coastal towns on dry land, and the generator's inward-shrinking fallback
--- then dropped 67 items on their centre points, in the sea. There is a test
--- pinning that (test_shared, loot.water). When in doubt make a rectangle
--- SMALLER: everything it misses is caught by the client repair round-trip,
--- while everything it wrongly claims is loot deleted from a real location.
BR.Config.Map.Water = {
    -- The Pacific, west of the coast highway (short of Chumash at -3170).
    { minX = -4000.0, minY = -4000.0, maxX = -3350.0, maxY =  2200.0 },
    -- Open ocean south of Los Santos and the airport.
    { minX = -4000.0, minY = -4000.0, maxX =  1600.0, maxY = -3300.0 },
    -- The eastern seaboard past the industrial coast.
    { minX =  2600.0, minY = -3600.0, maxX =  4500.0, maxY = -1600.0 },
    -- North-west coast, past Paleto (short of Hookies at -2200).
    { minX = -4000.0, minY =  4500.0, maxX = -2450.0, maxY =  8000.0 },
    -- The Alamo Sea, inside its shoreline (short of Galilee at 1380).
    { minX =   600.0, minY =  3750.0, maxX =  1300.0, maxY =  4450.0 },
}

--- Rectangles nothing may ever spawn in, for reasons other than water.
---
--- The runway is the whole list so far: the Battle Bus spawns and rolls down
--- it, and a crate sitting on the tarmac is either an obstacle or something we
--- would have to sweep up before every departure. Not spawning there in the
--- first place is one line instead of a cleanup pass (user, 2026-08-05).
BR.Config.Map.NoLoot = {
    -- Cayo Perico airstrip, from the two ends the user surveyed, with a
    -- margin either side for the wings.
    { minX = 3932.59 - 25.0, minY = -4712.51 - 25.0,
      maxX = 4525.47 + 25.0, maxY = -4456.65 + 25.0 },
}

--- Is this point somewhere loot is banned outright?
--- @param x number
--- @param y number
--- @return boolean
function BR.Config.Map.IsNoLoot(x, y)
    for _, r in ipairs(BR.Config.Map.NoLoot) do
        if x >= r.minX and x <= r.maxX and y >= r.minY and y <= r.maxY then
            return true
        end
    end
    return false
end

--- Is this point inside an authored water rectangle?
--- @param x number
--- @param y number
--- @return boolean
function BR.Config.Map.IsWater(x, y)
    for _, w in ipairs(BR.Config.Map.Water) do
        if x >= w.minX and x <= w.maxX and y >= w.minY and y <= w.maxY then
            return true
        end
    end
    return false
end

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

    -- Cruise altitude. Authored waypoints may override z per point (the
    -- northern exits climb to clear Mount Chiliad); everything else uses this.
    altitude     = 500.0,

    -- THE FLIGHT IS AN AUTHORED TOUR. One option is drawn from each leg list
    -- at WARMUP -- so players see the route and plan their drop -- giving
    -- 4 x 4 x 4 x 3 = 192 distinct flights, all over land by construction
    -- (which retired the whole land-scoring machinery). Legs run south
    -- coast -> city belt -> mid-map -> northern exit. An OPTION is an array
    -- of waypoints so an exit can dogleg across the Chiliad massif with
    -- explicit altitudes. Corners are filleted into arcs at build time; the
    -- doors open on arrival at the leg-1 waypoint (the coastline).
    legs = {
        {   -- Leg 1: crossing the southern coast
            { { x = -2598.67, y = -1086.21 } },
            { { x =  -938.81, y = -1781.52 } },
            { { x =   338.61, y = -3363.02 } },
            { { x =  1726.79, y = -2109.79 } },
        },
        {   -- Leg 2: the city belt
            { { x =  1427.70, y =  -357.45 } },
            { { x =   765.43, y =  1219.36 } },
            { { x =  -288.90, y =  -410.69 } },
            { { x = -1152.44, y =  2456.74 } },
        },
        {   -- Leg 3: mid-map
            { { x =  522.49, y = 3249.48 } },
            { { x = 2240.84, y = 1384.38 } },
            { { x = 2002.04, y = 2869.46 } },
            { { x = 2277.24, y = 5014.84 } },
        },
        {   -- Leg 4: northern exits. The explicit z values are NOT
            -- decorative: these overfly the Chiliad massif, and the default
            -- cruise altitude is inside the rock.
            { { x =  1370.50, y = 5849.28, z = 597.94 },
              { x =  -193.45, y = 6425.31, z = 892.0 } },
            { { x = -1254.45, y = 4135.53, z = 598.0 },
              { x =  -632.90, y = 5458.41 } },
            { { x = -2031.09, y = 4913.02 } },
        },
    },

    -- Surveyed in-game by the user. Spawn z is the surveyed 4.19 + 0.8
    -- (two rounds of "raise it a bit" -- the Titan's gear sat in the runway).
    spawn        = { x = 4484.61, y = -4497.98, z = 4.99, heading = 106.12 },
    -- Wheels-up here, straight out. Moved back UP the runway toward the spawn
    -- twice on 2026-08-06: 15.24m (50 ft), then another 22.86m (75 ft) because
    -- the climb-out was still clipping trees off the end (user). 38.1m total
    -- off a 420m roll. The roll is a fixed distance divided by rollSpeed, so
    -- shortening it also shaves a fraction of a second off the tarmac time;
    -- that is intended.
    rotatePoint  = { x = 4126.01, y = -4629.10 },
    climbDist    = 1800.0,  -- metres past rotation to reach cruise altitude
                            -- (2500 originally; cut ~40% for a steeper,
                            -- more take-off-looking climb -- user call)
    turnRadius   = 1000.0,  -- fillet radius: this close to a waypoint, start turning

    -- Wheels-up speed. The roll is uniform acceleration over the fixed
    -- spawn -> rotatePoint distance (~420m), so
    --
    --     rollTime = 2 * distance / rollSpeed
    --
    -- 80 m/s gave ~10.5s on the tarmac; 88 gives ~9.5, which is the second
    -- the user asked to cut (2026-08-06). Raising the speed rather than
    -- moving rotatePoint keeps wheels-up at the real end of the runway.
    rollSpeed    = 88.0,    -- m/s at wheels-up (the roll builds up to this)
    climbSpeed   = 270.0,   -- m/s through the climb and the initial turn
                            -- (150 originally; +80%, user call 2026-08-04 --
                            -- the ascent dragged. Still gradual: depart()'s
                            -- kinematic passes ramp toward this at maxAccel,
                            -- so the plane accelerates continuously from
                            -- wheels-up instead of stepping)
    cruiseSpeed  = 600.0,   -- m/s across the open ocean approach (+50%, user
                            -- call). MUST stay >= climbSpeed: the ascent may
                            -- never be faster than the leg to waypoint 1
    speed        = 185.0,   -- m/s over land: the WHOLE TOUR is the drop zone
    cornerSpeed  = 150.0,   -- m/s through filleted corners
    boardSeconds = 5,       -- parked, engines idling, before the roll begins
    overrunSecs  = 5,       -- flown past the last waypoint before force-eject
    maxAccel     = 9.0,     -- m/s^2 cap smoothing every speed transition
    jumpGrace    = 5,       -- seconds after the route ends before BUS -> PLAYING

    -- Camera orbit distance/height from the plane while riding. The Titan is
    -- ~20m long and the camera must CLEAR the hull -- the first offset
    -- (-14, +3) sat inside the tail, which rendered as a black wedge of
    -- fuselage and, over featureless ocean, read as the game having frozen.
    camDistance  = 44.0,
    camHeight    = 13.0,

    -- Spacing of the route breadcrumbs drawn on the map and minimap.
    crumbSpacing = 350.0,
}

BR.Config.Drop = {
    autoDeployAGL   = 120.0,  -- metres above ground where the glider force-opens
    landedGraceMs   = 500,    -- invincibility after touchdown, absorbs landing edge cases
    parachuteModel  = 'p_parachute1_mp_s',
    smokeTrail      = true,   -- squad-coloured, cheap and very readable
}
